package tempo

import "core:strings"

// Template parser state
Template_Parser :: struct {
    src:      string,
    base_pos: Pos,
    scanner:  Scanner,
    errors:   [dynamic]Parse_Error,
}

// Create parser from template segment
make_template_parser :: proc(seg: Templ_Segment) -> Template_Parser {
    return Template_Parser{
        src      = seg.body,
        base_pos = seg.body_range.start,
        scanner  = scanner_make(seg.body),
    }
}

// Main entry point - parse a template segment
parse_template :: proc(seg: Templ_Segment) -> (Template_Decl, bool) {
    p := make_template_parser(seg)

    body := parse_nodes(&p)

    return Template_Decl{
        name   = seg.name,
        params = seg.params,
        body   = body,
        range  = seg.range,
    }, len(p.errors) == 0
}

// Parse nodes until end or closing brace
parse_nodes :: proc(p: ^Template_Parser) -> []Node {
    nodes: [dynamic]Node

    for !scanner_eof(&p.scanner) {
        skip_insignificant_whitespace(p)

        if scanner_eof(&p.scanner) do break

        if node, ok := parse_node(p); ok {
            append(&nodes, node)
        } else {
            // Error recovery: skip character
            scanner_advance(&p.scanner)
        }
    }

    return nodes[:]
}

// Parse nodes until closing brace
parse_nodes_until_brace :: proc(p: ^Template_Parser) -> []Node {
    nodes: [dynamic]Node

    for !scanner_eof(&p.scanner) && !scanner_check(&p.scanner, '}') {
        skip_insignificant_whitespace(p)

        if scanner_eof(&p.scanner) || scanner_check(&p.scanner, '}') do break

        if node, ok := parse_node(p); ok {
            append(&nodes, node)
        } else {
            break
        }
    }

    return nodes[:]
}

// Parse a single node
parse_node :: proc(p: ^Template_Parser) -> (Node, bool) {
    // < - HTML element or comment
    if scanner_check(&p.scanner, '<') {
        if scanner_check_ahead(&p.scanner, "<!--") {
            return parse_html_comment(p)
        }
        if scanner_check_ahead(&p.scanner, "</") {
            // Unexpected close tag - handled by parent
            return nil, false
        }
        if scanner_check_ahead(&p.scanner, "<!") {
            return parse_doctype(p)
        }
        return parse_element(p)
    }

    // {{ - Odin code block
    if scanner_check_ahead(&p.scanner, "{{") {
        return parse_odin_block(p)
    }

    // { - Expression or slot
    if scanner_check(&p.scanner, '{') {
        return parse_expr_or_slot(p)
    }

    // @ - Template call
    if scanner_check(&p.scanner, '@') {
        return parse_call(p)
    }

    // // or /* - Odin comment
    if scanner_check_ahead(&p.scanner, "//") {
        return parse_line_comment(p)
    }
    if scanner_check_ahead(&p.scanner, "/*") {
        return parse_block_comment(p)
    }

    // Keywords at statement position
    if at_statement_position(p) {
        if scanner_check_keyword(&p.scanner, "if") {
            return parse_if(p)
        }
        if scanner_check_keyword(&p.scanner, "for") {
            return parse_for(p)
        }
        if scanner_check_keyword(&p.scanner, "switch") {
            return parse_switch(p)
        }
    }

    // Text content
    return parse_text(p)
}

// Parse HTML element
parse_element :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)

    if !scanner_match(&p.scanner, "<") {
        return nil, false
    }

    // Tag name
    tag := scanner_take_while(&p.scanner, is_tag_name_char)
    if tag == "" {
        parser_error(p, "expected tag name")
        return nil, false
    }

    // Attributes
    attrs := parse_attributes(p)

    // Self-closing />
    scanner_skip_whitespace(&p.scanner)
    if scanner_match(&p.scanner, "/>") {
        return Element{
            tag        = tag,
            attributes = attrs,
            self_close = true,
            range      = range_to(p, start),
        }, true
    }

    // >
    if !scanner_match(&p.scanner, ">") {
        parser_error(p, "expected '>' or '/>'")
        return nil, false
    }

    // Void element - no children, no close tag
    if is_void_element(tag) {
        return Element{
            tag        = tag,
            attributes = attrs,
            void       = true,
            range      = range_to(p, start),
        }, true
    }

    // Special handling for style/script - raw content with {{ expr }} only
    children: []Node
    if tag == "style" || tag == "script" {
        children = parse_raw_element_content(p, tag)
    } else {
        // Children until </tag>
        children = parse_children(p, tag)
    }

    // Close tag </tag>
    if !scanner_match(&p.scanner, "</") {
        parser_error(p, strings.concatenate({"expected '</", tag, ">'"}))
        return nil, false
    }

    close_tag := scanner_take_while(&p.scanner, is_tag_name_char)
    if close_tag != tag {
        parser_error(p, strings.concatenate({"mismatched close tag: expected '", tag, "', got '", close_tag, "'"}))
    }

    if !scanner_match(&p.scanner, ">") {
        parser_error(p, "expected '>'")
    }

    return Element{
        tag        = tag,
        attributes = attrs,
        children   = children,
        range      = range_to(p, start),
    }, true
}

// Parse children of an element
parse_children :: proc(p: ^Template_Parser, parent: string) -> []Node {
    children: [dynamic]Node

    for !scanner_eof(&p.scanner) {
        // Check for close tag
        if scanner_check_ahead(&p.scanner, "</") {
            break
        }

        skip_insignificant_whitespace(p)

        if scanner_eof(&p.scanner) || scanner_check_ahead(&p.scanner, "</") {
            break
        }

        if node, ok := parse_node(p); ok {
            append(&children, node)
        } else {
            break
        }
    }

    return children[:]
}

// Parse raw element content (for style/script) - only {{ expr }} is recognized
// Single { } are treated as literal text
parse_raw_element_content :: proc(p: ^Template_Parser, tag: string) -> []Node {
    nodes: [dynamic]Node
    close_tag := strings.concatenate({"</", tag})

    for !scanner_eof(&p.scanner) {
        // Check for close tag
        if scanner_check_ahead(&p.scanner, close_tag) {
            break
        }

        // Check for {{ expression }} - treat as Expr, not Odin_Block
        if scanner_check_ahead(&p.scanner, "{{") {
            if node, ok := parse_raw_expr(p); ok {
                append(&nodes, node)
            }
            continue
        }

        // Otherwise, consume raw text until {{ or close tag
        start := current_pos(p)
        text_start := p.scanner.pos

        for !scanner_eof(&p.scanner) {
            // Stop at {{ or close tag
            if scanner_check_ahead(&p.scanner, "{{") {
                break
            }
            if scanner_check_ahead(&p.scanner, close_tag) {
                break
            }
            scanner_advance(&p.scanner)
        }

        text := p.src[text_start:p.scanner.pos]
        if text != "" {
            append(&nodes, Text{
                value = text,
                range = range_to(p, start),
            })
        }
    }

    return nodes[:]
}

// Parse {{ expr }} as a raw expression (for style/script context)
// Unlike parse_odin_block which treats content as statements,
// this treats {{ expr }} like {! expr } - outputs unescaped expression value
parse_raw_expr :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "{{")

    expr_start := p.scanner.pos
    depth := 0

    for !scanner_eof(&p.scanner) {
        if scanner_check_ahead(&p.scanner, "}}") && depth == 0 {
            break
        }

        r := scanner_peek_rune(&p.scanner)
        switch r {
        case '{':
            depth += 1
            scanner_advance(&p.scanner)
        case '}':
            depth -= 1
            scanner_advance(&p.scanner)
        case '"', '\'', '`':
            skip_string(&p.scanner, r)
        case:
            scanner_advance(&p.scanner)
        }
    }

    expr := strings.trim_space(p.src[expr_start:p.scanner.pos])
    scanner_match(&p.scanner, "}}")

    trailing := capture_trailing_space(p)

    // Return Raw_Expr for unescaped output in style/script blocks
    return Raw_Expr{
        value          = expr,
        trailing_space = trailing,
        range          = range_to(p, start),
    }, true
}

// Parse attributes
parse_attributes :: proc(p: ^Template_Parser) -> []Attribute {
    attrs: [dynamic]Attribute

    for {
        scanner_skip_whitespace(&p.scanner)

        // End of attributes
        if scanner_check(&p.scanner, '>') || scanner_check_ahead(&p.scanner, "/>") {
            break
        }

        if attr, ok := parse_attribute(p); ok {
            append(&attrs, attr)
        } else {
            break
        }
    }

    return attrs[:]
}

// Parse a single attribute
parse_attribute :: proc(p: ^Template_Parser) -> (Attribute, bool) {
    start := current_pos(p)

    // Spread attribute: { attrs... }
    if scanner_check(&p.scanner, '{') {
        return parse_spread_attribute(p)
    }

    // Conditional attribute: if cond { ... }
    if scanner_check_keyword(&p.scanner, "if") {
        return parse_cond_attribute(p)
    }

    // Attribute name
    name := scanner_take_while(&p.scanner, is_attr_name_char)
    if name == "" {
        return nil, false
    }

    scanner_skip_whitespace(&p.scanner)

    // Boolean expression: name?={ expr }
    if scanner_check_ahead(&p.scanner, "?=") {
        scanner_match(&p.scanner, "?=")
        scanner_skip_whitespace(&p.scanner)
        if scanner_match(&p.scanner, "{") {
            expr := capture_odin_expr(p)
            scanner_match(&p.scanner, "}")
            return Bool_Expr_Attr{
                key   = name,
                expr  = expr,
                range = range_to(p, start),
            }, true
        }
    }

    // Boolean attribute (no =)
    if !scanner_check(&p.scanner, '=') {
        return Bool_Attr{
            key   = name,
            range = range_to(p, start),
        }, true
    }

    scanner_match(&p.scanner, "=")
    scanner_skip_whitespace(&p.scanner)

    // Expression attribute: name={ expr }
    if scanner_check(&p.scanner, '{') {
        scanner_match(&p.scanner, "{")
        expr := capture_odin_expr(p)
        scanner_match(&p.scanner, "}")
        return Expr_Attr{
            key   = name,
            expr  = expr,
            range = range_to(p, start),
        }, true
    }

    // String value: name="value" or name='value'
    quote := scanner_peek_rune(&p.scanner)
    if quote == '"' || quote == '\'' {
        scanner_advance(&p.scanner)
        value := scanner_take_until(&p.scanner, quote)
        scanner_match_rune(&p.scanner, quote)

        return Const_Attr{
            key          = name,
            value        = value,
            single_quote = quote == '\'',
            range        = range_to(p, start),
        }, true
    }

    // Unquoted value
    value := scanner_take_while(&p.scanner, is_unquoted_attr_char)
    return Const_Attr{
        key   = name,
        value = value,
        range = range_to(p, start),
    }, true
}

// Parse spread attribute: { attrs... }
parse_spread_attribute :: proc(p: ^Template_Parser) -> (Attribute, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "{")

    expr := capture_odin_expr(p)

    scanner_match(&p.scanner, "}")

    return Spread_Attr{
        expr  = expr,
        range = range_to(p, start),
    }, true
}

// Parse conditional attribute: if cond { ... }
parse_cond_attribute :: proc(p: ^Template_Parser) -> (Attribute, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "if")

    scanner_skip_whitespace(&p.scanner)
    cond := capture_until_brace(p)

    scanner_match(&p.scanner, "{")
    then_attrs := parse_attributes_until_brace(p)
    scanner_match(&p.scanner, "}")

    else_attrs: []Attribute
    scanner_skip_whitespace(&p.scanner)
    if scanner_check_keyword(&p.scanner, "else") {
        scanner_match(&p.scanner, "else")
        scanner_skip_whitespace(&p.scanner)
        scanner_match(&p.scanner, "{")
        else_attrs = parse_attributes_until_brace(p)
        scanner_match(&p.scanner, "}")
    }

    return Cond_Attr{
        cond  = strings.trim_space(cond),
        then_ = then_attrs,
        else_ = else_attrs,
        range = range_to(p, start),
    }, true
}

// Parse attributes until closing brace (for conditional attributes)
parse_attributes_until_brace :: proc(p: ^Template_Parser) -> []Attribute {
    attrs: [dynamic]Attribute

    for !scanner_eof(&p.scanner) && !scanner_check(&p.scanner, '}') {
        scanner_skip_whitespace(&p.scanner)

        if scanner_check(&p.scanner, '}') do break

        if attr, ok := parse_attribute(p); ok {
            append(&attrs, attr)
        } else {
            break
        }
    }

    return attrs[:]
}

// Capture Odin expression between { }
capture_odin_expr :: proc(p: ^Template_Parser) -> string {
    start := p.scanner.pos
    depth := 0

    for !scanner_eof(&p.scanner) {
        r := scanner_peek_rune(&p.scanner)

        switch r {
        case '{':
            depth += 1
            scanner_advance(&p.scanner)

        case '}':
            if depth == 0 {
                // End of expression (don't consume)
                end := p.scanner.pos
                return strings.trim_space(p.src[start:end])
            }
            depth -= 1
            scanner_advance(&p.scanner)

        case '"', '\'', '`':
            skip_string(&p.scanner, r)

        case '/':
            if scanner_peek_next(&p.scanner) == '/' {
                skip_line_comment(&p.scanner)
            } else if scanner_peek_next(&p.scanner) == '*' {
                skip_block_comment(&p.scanner)
            } else {
                scanner_advance(&p.scanner)
            }

        case:
            scanner_advance(&p.scanner)
        }
    }

    end := p.scanner.pos
    return strings.trim_space(p.src[start:end])
}

// Capture until opening brace
capture_until_brace :: proc(p: ^Template_Parser) -> string {
    start := p.scanner.pos

    for !scanner_eof(&p.scanner) && !scanner_check(&p.scanner, '{') {
        scanner_advance(&p.scanner)
    }

    return p.src[start:p.scanner.pos]
}

// Parse { expr } or {! raw_expr } or {#slot} or {#slot name}
parse_expr_or_slot :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "{")

    // Check for {! raw_expr } - no whitespace skip before !
    is_raw := scanner_check(&p.scanner, '!')
    if is_raw {
        scanner_match(&p.scanner, "!")
    }

    scanner_skip_whitespace(&p.scanner)

    // Check for {#slot} or {#slot name}
    if scanner_check(&p.scanner, '#') {
        scanner_match(&p.scanner, "#")

        if scanner_check_keyword(&p.scanner, "slot") {
            scanner_match(&p.scanner, "slot")
            scanner_skip_whitespace(&p.scanner)

            // Check for optional slot name
            slot_name: Maybe(string)
            if !scanner_check(&p.scanner, '}') {
                name := scanner_take_while(&p.scanner, is_ident_char)
                if name != "" {
                    slot_name = name
                }
            }

            scanner_skip_whitespace(&p.scanner)
            scanner_match(&p.scanner, "}")

            return Slot{
                name  = slot_name,
                range = range_to(p, start),
            }, true
        } else {
            parser_error(p, "expected 'slot' after '#'")
            return nil, false
        }
    }

    // Expression (escaped or raw)
    expr := capture_odin_expr(p)
    scanner_match(&p.scanner, "}")

    trailing := capture_trailing_space(p)

    if is_raw {
        return Raw_Expr{
            value          = expr,
            trailing_space = trailing,
            range          = range_to(p, start),
        }, true
    }

    return Expr{
        value          = expr,
        trailing_space = trailing,
        range          = range_to(p, start),
    }, true
}

// Parse {{ code }}
parse_odin_block :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "{{")

    code_start := p.scanner.pos
    depth := 0

    for !scanner_eof(&p.scanner) {
        if scanner_check_ahead(&p.scanner, "}}") && depth == 0 {
            break
        }

        r := scanner_peek_rune(&p.scanner)
        switch r {
        case '{':
            depth += 1
            scanner_advance(&p.scanner)
        case '}':
            depth -= 1
            scanner_advance(&p.scanner)
        case '"', '\'', '`':
            skip_string(&p.scanner, r)
        case:
            scanner_advance(&p.scanner)
        }
    }

    code := strings.trim_space(p.src[code_start:p.scanner.pos])
    scanner_match(&p.scanner, "}}")

    trailing := capture_trailing_space(p)

    return Odin_Block{
        code           = code,
        trailing_space = trailing,
        range          = range_to(p, start),
    }, true
}

// Parse if/else if/else
parse_if :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "if")

    cond := capture_until_brace(p)

    scanner_match(&p.scanner, "{")
    then_body := parse_nodes_until_brace(p)
    scanner_match(&p.scanner, "}")

    else_ifs: [dynamic]Else_If
    else_body: []Node

    // else if / else
    for {
        scanner_skip_whitespace(&p.scanner)

        if !scanner_check_keyword(&p.scanner, "else") {
            break
        }

        scanner_match(&p.scanner, "else")
        scanner_skip_whitespace(&p.scanner)

        if scanner_check_keyword(&p.scanner, "if") {
            scanner_match(&p.scanner, "if")
            ei_cond := capture_until_brace(p)
            scanner_match(&p.scanner, "{")
            ei_body := parse_nodes_until_brace(p)
            scanner_match(&p.scanner, "}")

            append(&else_ifs, Else_If{
                cond  = strings.trim_space(ei_cond),
                then_ = ei_body,
            })
        } else {
            scanner_match(&p.scanner, "{")
            else_body = parse_nodes_until_brace(p)
            scanner_match(&p.scanner, "}")
            break
        }
    }

    return If_Node{
        cond     = strings.trim_space(cond),
        then_    = then_body,
        else_ifs = else_ifs[:],
        else_    = else_body,
        range    = range_to(p, start),
    }, true
}

// Parse for loop
parse_for :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "for")

    clause := capture_until_brace(p)

    scanner_match(&p.scanner, "{")
    body := parse_nodes_until_brace(p)
    scanner_match(&p.scanner, "}")

    return For_Node{
        clause = strings.trim_space(clause),
        body   = body,
        range  = range_to(p, start),
    }, true
}

// Parse switch/case
parse_switch :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "switch")

    expr := capture_until_brace(p)

    scanner_match(&p.scanner, "{")

    cases: [dynamic]Case_Clause

    for !scanner_eof(&p.scanner) && !scanner_check(&p.scanner, '}') {
        scanner_skip_whitespace(&p.scanner)

        if scanner_check(&p.scanner, '}') do break

        if scanner_check_keyword(&p.scanner, "case") {
            case_start := current_pos(p)
            scanner_match(&p.scanner, "case")

            case_expr := capture_until_colon(p)
            scanner_match(&p.scanner, ":")

            case_body := parse_case_body(p)

            append(&cases, Case_Clause{
                expr  = strings.trim_space(case_expr),
                body  = case_body,
                range = range_to(p, case_start),
            })
        } else {
            break
        }
    }

    scanner_match(&p.scanner, "}")

    return Switch_Node{
        expr  = strings.trim_space(expr),
        cases = cases[:],
        range = range_to(p, start),
    }, true
}

// Capture until colon
capture_until_colon :: proc(p: ^Template_Parser) -> string {
    start := p.scanner.pos

    for !scanner_eof(&p.scanner) && !scanner_check(&p.scanner, ':') {
        scanner_advance(&p.scanner)
    }

    return p.src[start:p.scanner.pos]
}

// Parse case body until next case or }
parse_case_body :: proc(p: ^Template_Parser) -> []Node {
    nodes: [dynamic]Node

    for !scanner_eof(&p.scanner) {
        scanner_skip_whitespace(&p.scanner)

        // Stop at next case or closing brace
        if scanner_check(&p.scanner, '}') {
            break
        }
        if scanner_check_keyword(&p.scanner, "case") {
            break
        }

        if node, ok := parse_node(p); ok {
            append(&nodes, node)
        } else {
            break
        }
    }

    return nodes[:]
}

// Parse template call: @name(args) or @name(args) { slots }
parse_call :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "@")

    expr := capture_call_expr(p)

    call := Call{
        expr  = expr,
        range = range_to(p, start),
    }

    // Optional slot content block
    scanner_skip_whitespace(&p.scanner)
    if scanner_match(&p.scanner, "{") {
        default_nodes: [dynamic]Node
        named_slots: [dynamic]Named_Slot

        for !scanner_eof(&p.scanner) && !scanner_check(&p.scanner, '}') {
            skip_insignificant_whitespace(p)

            if scanner_eof(&p.scanner) || scanner_check(&p.scanner, '}') {
                break
            }

            // Check for #name { ... } named slot
            if scanner_check(&p.scanner, '#') {
                slot_start := current_pos(p)
                scanner_match(&p.scanner, "#")

                slot_name := scanner_take_while(&p.scanner, is_ident_char)
                if slot_name == "" {
                    parser_error(p, "expected slot name after '#'")
                    break
                }

                scanner_skip_whitespace(&p.scanner)
                if !scanner_match(&p.scanner, "{") {
                    parser_error(p, "expected '{' after slot name")
                    break
                }

                slot_body := parse_nodes_until_brace(p)
                scanner_match(&p.scanner, "}")

                append(&named_slots, Named_Slot{
                    name  = slot_name,
                    body  = slot_body,
                    range = range_to(p, slot_start),
                })
            } else {
                // Regular content goes to default slot
                if node, ok := parse_node(p); ok {
                    append(&default_nodes, node)
                } else {
                    break
                }
            }
        }

        scanner_match(&p.scanner, "}")

        call.default_slot = default_nodes[:]
        call.named_slots = named_slots[:]
        call.range = range_to(p, start)
    }

    return call, true
}

// Capture call expression: name, name(args), pkg.name(args)
capture_call_expr :: proc(p: ^Template_Parser) -> string {
    start := p.scanner.pos

    // Name (possibly dotted)
    for {
        scanner_take_while(&p.scanner, is_ident_char)
        if !scanner_match(&p.scanner, ".") {
            break
        }
    }

    // Optional (args)
    if scanner_check(&p.scanner, '(') {
        scanner_match(&p.scanner, "(")
        capture_balanced(p, '(', ')')
        scanner_match(&p.scanner, ")")
    }

    return p.src[start:p.scanner.pos]
}

// Capture balanced delimiters
capture_balanced :: proc(p: ^Template_Parser, open, close: rune) {
    depth := 1

    for !scanner_eof(&p.scanner) && depth > 0 {
        r := scanner_peek_rune(&p.scanner)

        switch {
        case r == open:
            depth += 1
            scanner_advance(&p.scanner)
        case r == close:
            depth -= 1
            if depth > 0 {
                scanner_advance(&p.scanner)
            }
        case r == '"' || r == '\'' || r == '`':
            skip_string(&p.scanner, r)
        case:
            scanner_advance(&p.scanner)
        }
    }
}

// Parse text content
// Stops at: < { @ } // /* (control characters and comment starts)
parse_text :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    text_start := p.scanner.pos

    // Scan until we hit a control character or comment start
    for !scanner_eof(&p.scanner) {
        current := scanner_peek_rune(&p.scanner)

        // Stop at control characters
        if current == '<' || current == '{' || current == '@' || current == '}' {
            break
        }

        // Stop at comment starts
        if current == '/' {
            next := scanner_peek_next(&p.scanner)
            if next == '/' || next == '*' {
                break
            }
        }

        scanner_advance(&p.scanner)
    }

    text := p.src[text_start:p.scanner.pos]

    if text == "" {
        return nil, false
    }

    trailing := capture_trailing_space(p)

    return Text{
        value          = text,
        trailing_space = trailing,
        range          = range_to(p, start),
    }, true
}

// Parse HTML comment: <!-- ... -->
parse_html_comment :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "<!--")

    text_start := p.scanner.pos

    for !scanner_eof(&p.scanner) {
        if scanner_check_ahead(&p.scanner, "-->") {
            break
        }
        scanner_advance(&p.scanner)
    }

    text := p.src[text_start:p.scanner.pos]
    scanner_match(&p.scanner, "-->")

    return Comment{
        text      = text,
        html      = true,
        multiline = strings.contains(text, "\n"),
        range     = range_to(p, start),
    }, true
}

// Parse DOCTYPE
parse_doctype :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)

    // Scan until >
    text_start := p.scanner.pos
    for !scanner_eof(&p.scanner) && !scanner_check(&p.scanner, '>') {
        scanner_advance(&p.scanner)
    }
    scanner_match(&p.scanner, ">")

    text := p.src[text_start:p.scanner.pos - 1]

    return Text{
        value = p.src[start.offset - int(p.base_pos.offset):p.scanner.pos],
        range = range_to(p, start),
    }, true
}

// Parse // comment
parse_line_comment :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "//")

    text_start := p.scanner.pos

    for !scanner_eof(&p.scanner) && !scanner_check(&p.scanner, '\n') {
        scanner_advance(&p.scanner)
    }

    text := p.src[text_start:p.scanner.pos]

    return Comment{
        text      = text,
        html      = false,
        multiline = false,
        range     = range_to(p, start),
    }, true
}

// Parse /* */ comment
parse_block_comment :: proc(p: ^Template_Parser) -> (Node, bool) {
    start := current_pos(p)
    scanner_match(&p.scanner, "/*")

    text_start := p.scanner.pos

    for !scanner_eof(&p.scanner) {
        if scanner_check_ahead(&p.scanner, "*/") {
            break
        }
        scanner_advance(&p.scanner)
    }

    text := p.src[text_start:p.scanner.pos]
    scanner_match(&p.scanner, "*/")

    return Comment{
        text      = text,
        html      = false,
        multiline = strings.contains(text, "\n"),
        range     = range_to(p, start),
    }, true
}

// Position helpers
current_pos :: proc(p: ^Template_Parser) -> Pos {
    pos := scanner_pos(&p.scanner)
    return Pos{
        offset = p.base_pos.offset + pos.offset,
        line   = p.base_pos.line + pos.line - 1,
        column = pos.line == 1 ? p.base_pos.column + pos.column - 1 : pos.column,
    }
}

range_to :: proc(p: ^Template_Parser, start: Pos) -> Range {
    return Range{
        start = start,
        end   = current_pos(p),
    }
}

// Skip insignificant whitespace (preserving some for later)
skip_insignificant_whitespace :: proc(p: ^Template_Parser) {
    scanner_skip_whitespace(&p.scanner)
}

// Capture trailing space type
capture_trailing_space :: proc(p: ^Template_Parser) -> Trailing_Space {
    if scanner_eof(&p.scanner) {
        return .None
    }

    r := scanner_peek_rune(&p.scanner)
    switch r {
    case '\n', '\r':
        return .Vertical
    case ' ', '\t':
        return .Horizontal
    case:
        return .None
    }
}

// Check if we're at a position where a statement keyword is valid
at_statement_position :: proc(p: ^Template_Parser) -> bool {
    // Keywords are valid at start of content or after whitespace
    return true
}

// Check if tag is a void element
is_void_element :: proc(tag: string) -> bool {
    switch tag {
    case "area", "base", "br", "col", "command", "embed", "hr", "img",
         "input", "keygen", "link", "meta", "param", "source", "track", "wbr":
        return true
    }
    return false
}

// Error helpers
parser_error :: proc(p: ^Template_Parser, msg: string) {
    append(&p.errors, Parse_Error{
        msg = msg,
        pos = current_pos(p),
    })
}
