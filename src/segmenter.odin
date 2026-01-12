package tempo

import "core:fmt"

// Segment types from Phase 1 segmentation
Segment :: union {
    Package_Segment,
    Import_Segment,
    Odin_Segment,
    Templ_Segment,
    CSS_Segment,
    Script_Segment,
}

Package_Segment :: struct {
    name:  string,
    range: Range,
}

Import_Segment :: struct {
    text:  string,
    range: Range,
}

Odin_Segment :: struct {
    name:  string,
    code:  string,
    range: Range,
}

Templ_Segment :: struct {
    name:       string,
    params:     string,
    body:       string,
    range:      Range,
    body_range: Range,
}

CSS_Segment :: struct {
    name:   string,
    params: string,
    body:   string,
    range:  Range,
}

Script_Segment :: struct {
    name:   string,
    params: string,
    body:   string,
    range:  Range,
}

// Error context for good error messages
Block_Kind :: enum {
    Templ,
    CSS,
    Script,
    Proc,
    Struct,
    Enum,
    Union,
    If,
    For,
    Switch,
    Anonymous,
}

Block_Context :: struct {
    kind:     Block_Kind,
    name:     string,
    open_pos: Pos,
    decl_pos: Pos,
}

Error_Context :: struct {
    stack: [dynamic]Block_Context,
}

Parse_Error :: struct {
    msg:      string,
    pos:      Pos,
    hint:     string,
    hint_pos: Pos,
    notes:    [dynamic]Note,
}

Note :: struct {
    msg: string,
    pos: Pos,
}

Segmenter :: struct {
    scanner:   Scanner,
    errors:    [dynamic]Parse_Error,
    err_ctx:   Error_Context,
}

// Main entry point
segment_file :: proc(src: string) -> (segments: []Segment, errors: []Parse_Error) {
    s := Segmenter{
        scanner = scanner_make(src),
    }

    result: [dynamic]Segment

    // 1. Package declaration
    if pkg, ok := scan_package(&s); ok {
        append(&result, pkg)
    } else {
        return result[:], s.errors[:]
    }

    // 2. Imports
    for {
        scanner_skip_whitespace(&s.scanner)
        if imp, ok := scan_import(&s); ok {
            append(&result, imp)
        } else {
            break
        }
    }

    // 3. Declarations
    for !scanner_eof(&s.scanner) {
        skip_whitespace_and_comments(&s)
        if scanner_eof(&s.scanner) do break

        if seg, ok := scan_declaration(&s); ok {
            append(&result, seg)
        } else if len(s.errors) > 0 {
            break
        }
    }

    return result[:], s.errors[:]
}

// Package declaration: package name
scan_package :: proc(s: ^Segmenter) -> (Segment, bool) {
    scanner_skip_whitespace(&s.scanner)
    start := scanner_pos(&s.scanner)

    if !scanner_match(&s.scanner, "package") {
        add_error(s, "expected 'package' declaration", start)
        return nil, false
    }

    scanner_skip_horizontal_whitespace(&s.scanner)

    name := scanner_take_while(&s.scanner, is_ident_char)
    if name == "" {
        add_error(s, "expected package name", scanner_pos(&s.scanner))
        return nil, false
    }

    return Package_Segment{
        name  = name,
        range = range_make(start, scanner_pos(&s.scanner)),
    }, true
}

// Import statement: import "path" or import name "path" or import ( ... )
scan_import :: proc(s: ^Segmenter) -> (Segment, bool) {
    start := scanner_pos(&s.scanner)

    if !scanner_check_keyword(&s.scanner, "import") {
        return nil, false
    }

    scanner_match(&s.scanner, "import")
    scanner_skip_horizontal_whitespace(&s.scanner)

    // Check for import group: import ( ... )
    if scanner_check(&s.scanner, '(') {
        scanner_match(&s.scanner, "(")
        _ = scan_balanced_content(&s.scanner, '(', ')')
        scanner_match(&s.scanner, ")")

        text := s.scanner.src[start.offset:s.scanner.pos]
        return Import_Segment{
            text  = text,
            range = range_make(start, scanner_pos(&s.scanner)),
        }, true
    }

    // Single import
    // Optional alias
    if is_ident_start(scanner_peek_rune(&s.scanner)) {
        scanner_take_while(&s.scanner, is_ident_char)
        scanner_skip_horizontal_whitespace(&s.scanner)
    }

    // Path
    if scanner_check(&s.scanner, '"') {
        scanner_advance(&s.scanner)
        scanner_take_until(&s.scanner, '"')
        scanner_match(&s.scanner, "\"")
    }

    text := s.scanner.src[start.offset:s.scanner.pos]
    return Import_Segment{
        text  = text,
        range = range_make(start, scanner_pos(&s.scanner)),
    }, true
}

// Main declaration scanner
scan_declaration :: proc(s: ^Segmenter) -> (Segment, bool) {
    start := scanner_pos(&s.scanner)

    // Scan identifier
    name := scanner_take_while(&s.scanner, is_ident_char)
    if name == "" {
        return nil, false
    }

    scanner_skip_horizontal_whitespace(&s.scanner)

    // Expect first :
    if !scanner_match(&s.scanner, ":") {
        add_error(s, "expected ':' after identifier", scanner_pos(&s.scanner))
        return nil, false
    }

    // Check for :: (constant) vs := (variable) vs : Type : or : Type =
    if scanner_match(&s.scanner, ":") {
        // :: - untyped constant
        return scan_constant_decl(s, name, start)
    } else if scanner_match(&s.scanner, "=") {
        // := - inferred variable, always Odin
        return scan_odin_variable(s, name, start)
    } else {
        // : Type : or : Type =
        scanner_skip_whitespace(&s.scanner)
        scan_type_annotation(s)
        scanner_skip_whitespace(&s.scanner)

        if scanner_match(&s.scanner, ":") {
            // : Type : - typed constant
            return scan_constant_decl(s, name, start)
        } else if scanner_match(&s.scanner, "=") {
            // : Type = - typed variable, always Odin
            return scan_odin_variable(s, name, start)
        } else {
            add_error(s, "expected ':' or '=' after type", scanner_pos(&s.scanner))
            return nil, false
        }
    }
}

// Scan what follows :: for constants
scan_constant_decl :: proc(s: ^Segmenter, name: string, start: Pos) -> (Segment, bool) {
    scanner_skip_whitespace(&s.scanner)

    keyword := scanner_take_while(&s.scanner, is_ident_char)

    switch keyword {
    case "templ":
        return scan_templ_body(s, name, start)
    case "css":
        return scan_css_body(s, name, start)
    case "script":
        return scan_script_body(s, name, start)
    case:
        return scan_odin_decl(s, name, keyword, start)
    }
}

// Template body: templ(params) { ... }
scan_templ_body :: proc(s: ^Segmenter, name: string, start: Pos) -> (Segment, bool) {
    scanner_skip_whitespace(&s.scanner)
    decl_pos := scanner_pos(&s.scanner)

    // Parameters
    if !scanner_check(&s.scanner, '(') {
        add_error(s, "expected '(' after 'templ'", scanner_pos(&s.scanner))
        return nil, false
    }

    params := scan_balanced_with_delim(&s.scanner, '(', ')')

    scanner_skip_whitespace(&s.scanner)

    // Body
    if !scanner_check(&s.scanner, '{') {
        add_error(s, "expected '{' after templ signature", scanner_pos(&s.scanner))
        return nil, false
    }

    open_pos := scanner_pos(&s.scanner)
    push_block(&s.err_ctx, .Templ, name, decl_pos, open_pos)

    scanner_match(&s.scanner, "{")
    body_start := scanner_pos(&s.scanner)

    body, ok := scan_balanced_body(s, '{', '}')
    if !ok {
        return nil, false
    }

    body_end := scanner_pos(&s.scanner)
    scanner_match(&s.scanner, "}")

    pop_block(&s.err_ctx)

    return Templ_Segment{
        name       = name,
        params     = params,
        body       = body,
        range      = range_make(start, scanner_pos(&s.scanner)),
        body_range = range_make(body_start, body_end),
    }, true
}

// CSS body: css(params) { ... }
scan_css_body :: proc(s: ^Segmenter, name: string, start: Pos) -> (Segment, bool) {
    scanner_skip_whitespace(&s.scanner)
    decl_pos := scanner_pos(&s.scanner)

    // Parameters
    if !scanner_check(&s.scanner, '(') {
        add_error(s, "expected '(' after 'css'", scanner_pos(&s.scanner))
        return nil, false
    }

    params := scan_balanced_with_delim(&s.scanner, '(', ')')

    scanner_skip_whitespace(&s.scanner)

    // Body
    if !scanner_check(&s.scanner, '{') {
        add_error(s, "expected '{' after css signature", scanner_pos(&s.scanner))
        return nil, false
    }

    open_pos := scanner_pos(&s.scanner)
    push_block(&s.err_ctx, .CSS, name, decl_pos, open_pos)

    scanner_match(&s.scanner, "{")

    body, ok := scan_balanced_body(s, '{', '}')
    if !ok {
        return nil, false
    }

    scanner_match(&s.scanner, "}")

    pop_block(&s.err_ctx)

    return CSS_Segment{
        name   = name,
        params = params,
        body   = body,
        range  = range_make(start, scanner_pos(&s.scanner)),
    }, true
}

// Script body: script(params) { ... }
scan_script_body :: proc(s: ^Segmenter, name: string, start: Pos) -> (Segment, bool) {
    scanner_skip_whitespace(&s.scanner)
    decl_pos := scanner_pos(&s.scanner)

    // Parameters
    if !scanner_check(&s.scanner, '(') {
        add_error(s, "expected '(' after 'script'", scanner_pos(&s.scanner))
        return nil, false
    }

    params := scan_balanced_with_delim(&s.scanner, '(', ')')

    scanner_skip_whitespace(&s.scanner)

    // Body
    if !scanner_check(&s.scanner, '{') {
        add_error(s, "expected '{' after script signature", scanner_pos(&s.scanner))
        return nil, false
    }

    open_pos := scanner_pos(&s.scanner)
    push_block(&s.err_ctx, .Script, name, decl_pos, open_pos)

    scanner_match(&s.scanner, "{")

    body, ok := scan_balanced_body(s, '{', '}')
    if !ok {
        return nil, false
    }

    scanner_match(&s.scanner, "}")

    pop_block(&s.err_ctx)

    return Script_Segment{
        name   = name,
        params = params,
        body   = body,
        range  = range_make(start, scanner_pos(&s.scanner)),
    }, true
}

// Odin declaration (proc, struct, enum, etc.)
scan_odin_decl :: proc(s: ^Segmenter, name: string, keyword: string, start: Pos) -> (Segment, bool) {
    decl_pos := scanner_pos(&s.scanner)

    switch keyword {
    case "proc":
        // proc(...) { } or proc(...) -> T { }
        scanner_skip_whitespace(&s.scanner)
        if scanner_check(&s.scanner, '(') {
            scan_balanced_with_delim(&s.scanner, '(', ')')
        }
        scanner_skip_whitespace(&s.scanner)
        if scanner_match(&s.scanner, "->") {
            scanner_skip_whitespace(&s.scanner)
            scan_type(&s.scanner)
        }
        scanner_skip_whitespace(&s.scanner)
        if scanner_check(&s.scanner, '{') {
            open_pos := scanner_pos(&s.scanner)
            push_block(&s.err_ctx, .Proc, name, decl_pos, open_pos)
            scan_balanced_with_delim(&s.scanner, '{', '}')
            pop_block(&s.err_ctx)
        }

    case "struct", "enum", "union", "bit_field":
        kind := block_kind_from_keyword(keyword)
        // Optional parameters
        scanner_skip_whitespace(&s.scanner)
        if scanner_check(&s.scanner, '(') {
            scan_balanced_with_delim(&s.scanner, '(', ')')
        }
        scanner_skip_whitespace(&s.scanner)
        if scanner_check(&s.scanner, '{') {
            open_pos := scanner_pos(&s.scanner)
            push_block(&s.err_ctx, kind, name, decl_pos, open_pos)
            scan_balanced_with_delim(&s.scanner, '{', '}')
            pop_block(&s.err_ctx)
        }

    case:
        // Simple value: NAME :: value or NAME :: expr
        scan_until_declaration_end(&s.scanner)
    }

    code := s.scanner.src[start.offset:s.scanner.pos]

    return Odin_Segment{
        name  = name,
        code  = code,
        range = range_make(start, scanner_pos(&s.scanner)),
    }, true
}

// Variable declaration (:= or : T =)
scan_odin_variable :: proc(s: ^Segmenter, name: string, start: Pos) -> (Segment, bool) {
    scan_until_declaration_end(&s.scanner)

    code := s.scanner.src[start.offset:s.scanner.pos]

    return Odin_Segment{
        name  = name,
        code  = code,
        range = range_make(start, scanner_pos(&s.scanner)),
    }, true
}

// Scan type annotation (everything until : or =)
scan_type_annotation :: proc(s: ^Segmenter) -> string {
    start := s.scanner.pos

    for !scanner_eof(&s.scanner) {
        r := scanner_peek_rune(&s.scanner)

        switch r {
        case ':', '=':
            return s.scanner.src[start:s.scanner.pos]

        case '(':
            scan_balanced_with_delim(&s.scanner, '(', ')')

        case '[':
            scan_balanced_with_delim(&s.scanner, '[', ']')

        case:
            scanner_advance(&s.scanner)
        }
    }

    return s.scanner.src[start:s.scanner.pos]
}

// Scan type (for return types, etc.)
scan_type :: proc(s: ^Scanner) {
    // Handle pointers, arrays, etc.
    for scanner_check(s, '^') || scanner_check(s, '[') {
        if scanner_check(s, '^') {
            scanner_advance(s)
        } else if scanner_check(s, '[') {
            scan_balanced_with_delim(s, '[', ']')
        }
    }

    // Type name
    scanner_take_while(s, is_ident_char)

    // Generic params
    if scanner_check(s, '(') {
        scan_balanced_with_delim(s, '(', ')')
    }
}

// Scan until we reach the end of a declaration
scan_until_declaration_end :: proc(s: ^Scanner) {
    for !scanner_eof(s) {
        r := scanner_peek_rune(s)

        switch r {
        case '\n':
            scanner_advance(s)
            scanner_skip_horizontal_whitespace(s)
            if looks_like_declaration_start(s) {
                return
            }

        case '{':
            scan_balanced_with_delim(s, '{', '}')

        case '(':
            scan_balanced_with_delim(s, '(', ')')

        case '[':
            scan_balanced_with_delim(s, '[', ']')

        case '"':
            skip_string(s, '"')

        case '\'':
            skip_string(s, '\'')

        case '`':
            skip_string(s, '`')

        case '/':
            if scanner_peek_next(s) == '/' {
                skip_line_comment(s)
            } else if scanner_peek_next(s) == '*' {
                skip_block_comment(s)
            } else {
                scanner_advance(s)
            }

        case:
            scanner_advance(s)
        }
    }
}

// Check if current position looks like start of new declaration
looks_like_declaration_start :: proc(s: ^Scanner) -> bool {
    saved_pos := s.pos
    saved_line := s.line
    saved_col := s.column

    ident := scanner_take_while(s, is_ident_char)
    scanner_skip_horizontal_whitespace(s)
    is_decl := scanner_match(s, "::")

    // Restore
    s.pos = saved_pos
    s.line = saved_line
    s.column = saved_col

    return ident != "" && is_decl
}

// Scan balanced delimiters, returning content (including delimiters)
scan_balanced_with_delim :: proc(s: ^Scanner, open, close: rune) -> string {
    if !scanner_match_rune(s, open) {
        return ""
    }

    start := s.pos - 1  // Include the opening delimiter
    depth := 1

    for !scanner_eof(s) && depth > 0 {
        r := scanner_peek_rune(s)

        switch {
        case r == open:
            depth += 1
            scanner_advance(s)

        case r == close:
            depth -= 1
            if depth > 0 {
                scanner_advance(s)
            }

        case r == '"' || r == '\'' || r == '`':
            skip_string(s, r)

        case r == '/' && scanner_peek_next(s) == '/':
            skip_line_comment(s)

        case r == '/' && scanner_peek_next(s) == '*':
            skip_block_comment(s)

        case:
            scanner_advance(s)
        }
    }

    scanner_match_rune(s, close)
    return s.src[start:s.pos]
}

// Scan balanced body, returning content (excluding delimiters)
scan_balanced_body :: proc(s: ^Segmenter, open, close: rune) -> (string, bool) {
    start := s.scanner.pos
    depth := 1

    for !scanner_eof(&s.scanner) && depth > 0 {
        r := scanner_peek_rune(&s.scanner)

        switch {
        case r == open:
            depth += 1
            scanner_advance(&s.scanner)

        case r == close:
            depth -= 1
            if depth > 0 {
                scanner_advance(&s.scanner)
            }

        // Note: Don't treat single quotes as string delimiters in template bodies
        // because they're commonly used in text (e.g., "haven't", "it's")
        case r == '"' || r == '`':
            skip_string(&s.scanner, r)

        case r == '/' && scanner_peek_next(&s.scanner) == '/':
            skip_line_comment(&s.scanner)

        case r == '/' && scanner_peek_next(&s.scanner) == '*':
            skip_block_comment(&s.scanner)

        case:
            scanner_advance(&s.scanner)
        }
    }

    if depth > 0 {
        report_unclosed_with_context(s, scanner_pos(&s.scanner))
        return "", false
    }

    return s.scanner.src[start:s.scanner.pos], true
}

// Scan balanced content (excluding outer delimiters) - simple version
scan_balanced_content :: proc(s: ^Scanner, open, close: rune) -> string {
    start := s.pos
    depth := 1

    for !scanner_eof(s) && depth > 0 {
        r := scanner_peek_rune(s)

        switch {
        case r == open:
            depth += 1
            scanner_advance(s)

        case r == close:
            depth -= 1
            if depth > 0 {
                scanner_advance(s)
            }

        case r == '"' || r == '\'' || r == '`':
            skip_string(s, r)

        case r == '/' && scanner_peek_next(s) == '/':
            skip_line_comment(s)

        case r == '/' && scanner_peek_next(s) == '*':
            skip_block_comment(s)

        case:
            scanner_advance(s)
        }
    }

    return s.src[start:s.pos]
}

// Skip whitespace and comments
skip_whitespace_and_comments :: proc(s: ^Segmenter) {
    for !scanner_eof(&s.scanner) {
        scanner_skip_whitespace(&s.scanner)

        if scanner_check_ahead(&s.scanner, "//") {
            skip_line_comment(&s.scanner)
        } else if scanner_check_ahead(&s.scanner, "/*") {
            skip_block_comment(&s.scanner)
        } else {
            break
        }
    }
}

// Skip a string literal
skip_string :: proc(s: ^Scanner, quote: rune) {
    scanner_match_rune(s, quote)

    for !scanner_eof(s) {
        r := scanner_peek_rune(s)
        if r == quote {
            scanner_advance(s)
            return
        }
        if r == '\\' {
            scanner_advance(s)
            if !scanner_eof(s) {
                scanner_advance(s)
            }
        } else {
            scanner_advance(s)
        }
    }
}

// Skip line comment
skip_line_comment :: proc(s: ^Scanner) {
    for !scanner_eof(s) {
        if scanner_peek_rune(s) == '\n' {
            scanner_advance(s)
            return
        }
        scanner_advance(s)
    }
}

// Skip block comment
skip_block_comment :: proc(s: ^Scanner) {
    scanner_match(s, "/*")

    for !scanner_eof(s) {
        if scanner_check_ahead(s, "*/") {
            scanner_match(s, "*/")
            return
        }
        scanner_advance(s)
    }
}

// Error context helpers
push_block :: proc(ctx: ^Error_Context, kind: Block_Kind, name: string, decl_pos, open_pos: Pos) {
    append(&ctx.stack, Block_Context{
        kind     = kind,
        name     = name,
        decl_pos = decl_pos,
        open_pos = open_pos,
    })
}

pop_block :: proc(ctx: ^Error_Context) {
    if len(ctx.stack) > 0 {
        pop(&ctx.stack)
    }
}

current_block :: proc(ctx: ^Error_Context) -> (Block_Context, bool) {
    if len(ctx.stack) == 0 {
        return {}, false
    }
    return ctx.stack[len(ctx.stack) - 1], true
}

block_kind_from_keyword :: proc(keyword: string) -> Block_Kind {
    switch keyword {
    case "struct": return .Struct
    case "enum":   return .Enum
    case "union":  return .Union
    case "proc":   return .Proc
    case:          return .Anonymous
    }
}

block_kind_string :: proc(kind: Block_Kind) -> string {
    switch kind {
    case .Templ:     return "template"
    case .CSS:       return "css block"
    case .Script:    return "script block"
    case .Proc:      return "procedure"
    case .Struct:    return "struct"
    case .Enum:      return "enum"
    case .Union:     return "union"
    case .If:        return "if block"
    case .For:       return "for block"
    case .Switch:    return "switch block"
    case .Anonymous: return "block"
    }
    return "block"
}

// Error reporting
add_error :: proc(s: ^Segmenter, msg: string, pos: Pos) {
    append(&s.errors, Parse_Error{
        msg = msg,
        pos = pos,
    })
}

report_unclosed_with_context :: proc(s: ^Segmenter, current_pos: Pos) {
    if len(s.err_ctx.stack) == 0 {
        add_error(s, "unexpected end of file", current_pos)
        return
    }

    inner := s.err_ctx.stack[len(s.err_ctx.stack) - 1]

    err := Parse_Error{
        msg = fmt.tprintf(
            "missing '}' to close %s '%s'",
            block_kind_string(inner.kind),
            inner.name,
        ),
        pos = current_pos,
    }

    // Add notes for each level of nesting
    for i := len(s.err_ctx.stack) - 1; i >= 0; i -= 1 {
        block := s.err_ctx.stack[i]
        append(&err.notes, Note{
            msg = fmt.tprintf(
                "%s '%s' opened here",
                block_kind_string(block.kind),
                block.name,
            ),
            pos = block.open_pos,
        })
    }

    append(&s.errors, err)
}
