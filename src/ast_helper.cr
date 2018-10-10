require "redomi"
require "compiler/crystal/syntax"
require "compiler/crystal/formatter"

record TokenLogEntry, token : Crystal::Token, backtrace : Array(String)

# extend lexer with logger
class Crystal::Lexer
  getter emitted_tokens = Array(TokenLogEntry).new

  def next_token
    previous_def.tap do |res|
      emitted_tokens << TokenLogEntry.new(res.clone, caller)
    end
  end
end

class Crystal::Formatter
  def self.debug_format(source, filename = nil)
    parser = Parser.new(source)
    parser.filename = filename
    nodes = parser.parse

    formatter = new(source)
    formatter.skip_space_or_newline
    nodes.accept formatter
    {formatter.finish, formatter.@lexer}
  end
end

class Crystal::Token
  def_clone
end

class Crystal::VirtualFile
  def_clone
end

class Crystal::Location
  def_clone
end

class IO::Memory
  def clone
    nil # used for Token#@doc_buffer
  end
end

class DumpVisitor < Crystal::Visitor
  @ui_context : NamedTuple(root_node: Redomi::Node, props_node: Redomi::Node?)

  def initialize(root : Redomi::Node)
    @ui_context = {root_node: root, props_node: nil}
  end

  def visit(node)
    with_ui_context create_ui_node(@ui_context[:root_node], node) do
      append_properties(node)
    end
    false
  end

  def append_properties(node)
  end

  def append_properties(node : Crystal::Call)
    append_property "obj", node.obj
    append_property "name", node.name
    append_property "args", node.args
  end

  def append_properties(node : Crystal::Expressions)
    append_property "expressions", node.expressions
  end

  def append_properties(node : Crystal::Case)
    append_property "cond", node.cond
    append_property "whens", node.whens
    append_property "else", node.else
  end

  def append_properties(node : Crystal::When)
    append_property "conds", node.conds
    append_property "body", node.body
  end

  def append_property(name, value)
    render_value(create_ui_property_node(name)[:value_node], value)
  end

  def create_ui_property_node(name)
    item = Redomi::Node.append_to("li", @ui_context[:props_node].not_nil!)
    label = Redomi::Node.append_to("span", item)
    label.text_content = "#{name} "
    value = Redomi::Node.append_to("span", item)
    {value_node: value}
  end

  def render_value(container, value : Crystal::ASTNode)
    ul = Redomi::Node.append_to("ul", container)

    with_ui_context({root_node: ul, props_node: nil}) do
      value.accept self
    end
  end

  def render_value(container, value : Array(Crystal::ASTNode))
    ul = Redomi::Node.append_to("ul", container)
    value.each do |v|
      li = Redomi::Node.append_to("li", ul)
      render_value(li, v)
    end
  end

  def render_value(container, value : Nil)
    container.text_content = "nil"
  end

  def render_value(container, value)
    container.text_content = value.to_s
  end

  def short_description(node)
    "#{node.class}: #{node.to_s}"
  end

  def create_ui_node(container, node)
    ui_node = Redomi::Node.append_to("li", container)

    description = Redomi::Node.append_to("span", ui_node)
    description.text_content = short_description(node)

    props_node = Redomi::Node.append_to("ul", ui_node)
    {root_node: ui_node, props_node: props_node}
  end

  def with_ui_context(new_ui_context)
    old_ui_context = @ui_context
    @ui_context = new_ui_context
    yield
    @ui_context = old_ui_context
  end
end

def remove_all_children(node)
  while first = node.first_child
    node.remove_child first
  end
end

def render_tokens(container, tokens : Array(TokenLogEntry))
  tokens.each do |token_log_entry|
    token = token_log_entry.token
    ui_token = Redomi::Node.append_to("div", container)
    ui_token.class_name = "token"
    text_value = token.value.to_s || ""
    ui_token["style"] = "min-width: #{text_value.size + 5}ch;"
    Redomi::Node.append_to("div", ui_token).text_content = token.type.to_s
    Redomi::Node.append_to("div", ui_token).text_content = text_value

    app = ui_token.app
    ui_token.on_click do |node|
      app.eval("alert(%s)", token_log_entry.backtrace.map { |s| s.sub(%r(^.*/crystal/syntax), "..crystal/syntax").sub(%r(^.*/crystal/tools), "..crystal/tools") }.join("\n"))
    end
  end
end

def render(tree, ui_tokens, text_area, error_container, formatted, formatted_tokens_container, source)
  parser = Crystal::Parser.new(source)

  begin
    ast = parser.parse

    text_area.class_name = ""
    formatted.text_content = ""
    formatted.class_name = ""
    error_container.text_content = ""
    remove_all_children ui_tokens
    remove_all_children formatted_tokens_container
    remove_all_children tree

    ast.accept(DumpVisitor.new(tree))
    render_tokens(ui_tokens, parser.emitted_tokens)
  rescue e : Crystal::SyntaxException
    text_area.class_name = "error"
    error_container.text_content = e.to_s
    return
  end

  begin
    formatted_source, formatter_lexer = Crystal::Formatter.debug_format(source)
    formatted.text_content = formatted_source
    render_tokens(formatted_tokens_container, formatter_lexer.emitted_tokens)
  rescue e
    formatted.class_name = "error"
    error_container.text_content = e.to_s
  end
end

mutex = Mutex.new

server = Redomi::Server.setup do |app|
  app.embed_stylesheet %(
    html { font-size: 18px; }
    body { font-size: 1em; }

    textarea {
      width: 50vw;
      height: 10em;
      font-size: inherit;
      font-family: monospace;
    }

    .error {
      color: #FF2600;
    }

    textarea.error {
      border-color: #FF2600;
    }

    .tokens-container {
      display: flex;
      flex-direction: row;
      flex-wrap: nowrap;
      align-items: flex-start;
      justify-content: flex-start;
    }

    .token {
      font-family: monospace;
      font-size: 0.7em;
      margin-left: 5px;
      border: 1px solid #eee;

      flex: none;

      display: flex;
      flex-direction: column;
      align-items: center;
      align-content: center;
    }

    .token:first-child {
      margin-left: 0px;
    }
  )

  app.eval %(
    window.hasStorage = function() {
      if (typeof(Storage) !== 'undefined') {
        try {
          localStorage.setItem('feature_test', 'yes');
          if (localStorage.getItem('feature_test') === 'yes') {
            localStorage.removeItem('feature_test');
            return true;
          }
        } catch (e) {
          return false;
        }
      }

      return false;
    }

    window.getLastCode = function() {
      var h = hasStorage();
      return (h ? sessionStorage.lastCode : null) || (h ? localStorage.lastCode : null) || "";
    }

    window.setLastCode = function(value) {
      if (hasStorage()) {
        localStorage.lastCode = sessionStorage.lastCode = value;
      }
    }
  )

  text_area = Redomi::UI::TextArea.append_to(app.root)
  formatted = Redomi::Node.append_to("pre", app.root)
  formatted["id"] = "formatted"

  error_container = Redomi::Node.append_to("pre", app.root)
  error_container.class_name = "error"
  Redomi::Node.append_to("h3", app.root).text_content = "Tokens as seen by parser"
  tokens_container = Redomi::Node.append_to("div", app.root)
  tokens_container.class_name = "tokens-container"
  Redomi::Node.append_to("h3", app.root).text_content = "Tokens as seen by formatter"
  formatted_tokens_container = Redomi::Node.append_to("div", app.root)
  formatted_tokens_container.class_name = "tokens-container"
  Redomi::Node.append_to("h3", app.root).text_content = "AST returned by parser"
  tree = Redomi::Node.append_to("ul", app.root)

  text_area.on_value_change do |_, value|
    mutex.synchronize do
      app.eval("setLastCode(%s)", value)
      render(tree, tokens_container, text_area, error_container, formatted, formatted_tokens_container, value)
    end
  end

  text_area.value = source = app.eval_sync("getLastCode()").as(String)
  render(tree, tokens_container, text_area, error_container, formatted, formatted_tokens_container, source)
end

server.bind "tcp://127.0.0.1:9090"
puts "Ready"
server.listen
