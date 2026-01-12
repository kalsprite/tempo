package tempo

// A complete .templ file
File :: struct {
    source:   Source,
    package_: Package_Decl,
    imports:  []Import_Decl,
    decls:    []Decl,
}

Package_Decl :: struct {
    name:  string,
    range: Range,
}

Import_Decl :: struct {
    path:  string,
    alias: Maybe(string),
    range: Range,
}

// Top-level declaration
Decl :: union {
    Template_Decl,
    CSS_Decl,
    Script_Decl,
    Odin_Decl,
}

Template_Decl :: struct {
    name:   string,
    params: string,   // Raw "(name: string, count: int)"
    body:   []Node,
    range:  Range,
}

CSS_Decl :: struct {
    name:       string,
    params:     string,
    properties: []CSS_Property,
    range:      Range,
}

Script_Decl :: struct {
    name:   string,
    params: string,
    body:   string,   // Raw JS with embedded {{ odin }}
    range:  Range,
}

Odin_Decl :: struct {
    code:  string,   // Raw Odin code
    range: Range,
}

// A node inside a template body
Node :: union {
    Element,
    Text,
    Whitespace,
    Expr,
    Raw_Expr,
    Odin_Block,
    If_Node,
    For_Node,
    Switch_Node,
    Call,
    Slot,
    Comment,
}

// HTML Element: <div class="foo">...</div>
Element :: struct {
    tag:         string,
    attributes:  []Attribute,
    children:    []Node,
    self_close:  bool,
    void:        bool,   // <br>, <hr>, etc.
    range:       Range,
}

// Raw text content
Text :: struct {
    value:          string,
    trailing_space: Trailing_Space,
    range:          Range,
}

// Whitespace between nodes (may be significant)
Whitespace :: struct {
    value: string,
    range: Range,
}

// Expression: { some_expr }
Expr :: struct {
    value:          string,   // Raw Odin expression
    trailing_space: Trailing_Space,
    range:          Range,
}

// Raw expression (no escaping): {! some_expr }
Raw_Expr :: struct {
    value:          string,   // Raw Odin expression
    trailing_space: Trailing_Space,
    range:          Range,
}

// Odin code block: {{ stmt; stmt; }}
Odin_Block :: struct {
    code:           string,
    trailing_space: Trailing_Space,
    range:          Range,
}

// if condition { ... } else if { ... } else { ... }
If_Node :: struct {
    cond:     string,   // Raw condition expression
    then_:    []Node,
    else_ifs: []Else_If,
    else_:    []Node,
    range:    Range,
}

Else_If :: struct {
    cond:  string,
    then_: []Node,
    range: Range,
}

// for clause { ... }
For_Node :: struct {
    clause: string,   // Raw "i in 0..<10"
    body:   []Node,
    range:  Range,
}

// switch expr { case: ... }
Switch_Node :: struct {
    expr:  string,   // Raw switch expression
    cases: []Case_Clause,
    range: Range,
}

Case_Clause :: struct {
    expr:  string,   // "case x:" or "case:"
    body:  []Node,
    range: Range,
}

// Template call: @other_template(args)
Call :: struct {
    expr:          string,       // Raw "other_template(args)"
    default_slot:  []Node,       // Bare content goes to default slot
    named_slots:   []Named_Slot, // #name { ... } blocks
    range:         Range,
}

// Named slot content in a call
Named_Slot :: struct {
    name:  string,
    body:  []Node,
    range: Range,
}

// Slot insertion point: {#slot} or {#slot name}
Slot :: struct {
    name:  Maybe(string),  // nil = default slot
    range: Range,
}

// HTML or Odin comment
Comment :: struct {
    text:      string,
    html:      bool,   // <!-- --> vs // or /* */
    multiline: bool,
    range:     Range,
}

Trailing_Space :: enum {
    None,
    Horizontal,   // space or tab
    Vertical,     // newline
}

// Attribute types
Attribute :: union {
    Const_Attr,       // class="foo"
    Expr_Attr,        // href={ build_url(id) }
    Bool_Attr,        // disabled
    Bool_Expr_Attr,   // disabled?={ condition }
    Cond_Attr,        // if active { class="selected" }
    Spread_Attr,      // { ..attrs }
}

Const_Attr :: struct {
    key:          string,
    value:        string,
    single_quote: bool,
    range:        Range,
}

Expr_Attr :: struct {
    key:   string,
    expr:  string,   // Raw Odin expression
    range: Range,
}

Bool_Attr :: struct {
    key:   string,
    range: Range,
}

Bool_Expr_Attr :: struct {
    key:   string,
    expr:  string,   // Must evaluate to bool
    range: Range,
}

Cond_Attr :: struct {
    cond:  string,
    then_: []Attribute,
    else_: []Attribute,
    range: Range,
}

Spread_Attr :: struct {
    expr:  string,   // Expression starting with ".."
    range: Range,
}

// CSS types
CSS_Property :: union {
    Const_CSS_Prop,
    Expr_CSS_Prop,
}

Const_CSS_Prop :: struct {
    name:  string,
    value: string,
    range: Range,
}

Expr_CSS_Prop :: struct {
    name:  string,
    expr:  string,
    range: Range,
}
