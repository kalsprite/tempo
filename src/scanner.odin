package tempo

import "core:unicode/utf8"

Scanner :: struct {
    src:    string,
    pos:    int,    // current byte offset
    line:   u32,
    column: u32,
}

// Create scanner from source
scanner_make :: proc(src: string) -> Scanner {
    return Scanner{
        src    = src,
        pos    = 0,
        line   = 1,
        column = 1,
    }
}

// Current position as Pos
scanner_pos :: proc(s: ^Scanner) -> Pos {
    return Pos{
        offset = s.pos,
        line   = s.line,
        column = s.column,
    }
}

// Check if at end
scanner_eof :: proc(s: ^Scanner) -> bool {
    return s.pos >= len(s.src)
}

// Peek at current character without advancing
scanner_peek :: proc(s: ^Scanner) -> (r: rune, size: int, ok: bool) {
    if s.pos >= len(s.src) {
        return 0, 0, false
    }
    r, size = utf8.decode_rune_in_string(s.src[s.pos:])
    return r, size, true
}

// Peek at current rune only
scanner_peek_rune :: proc(s: ^Scanner) -> rune {
    if s.pos >= len(s.src) {
        return 0
    }
    r, _ := utf8.decode_rune_in_string(s.src[s.pos:])
    return r
}

// Peek at next rune (one rune ahead)
scanner_peek_next :: proc(s: ^Scanner) -> rune {
    if s.pos >= len(s.src) {
        return 0
    }
    _, size := utf8.decode_rune_in_string(s.src[s.pos:])
    if s.pos + size >= len(s.src) {
        return 0
    }
    r, _ := utf8.decode_rune_in_string(s.src[s.pos + size:])
    return r
}

// Peek n bytes ahead (returns string slice)
scanner_peek_n :: proc(s: ^Scanner, n: int) -> (str: string, ok: bool) {
    if s.pos + n > len(s.src) {
        return "", false
    }
    return s.src[s.pos:s.pos + n], true
}

// Check if current position starts with given string
scanner_check_ahead :: proc(s: ^Scanner, expected: string) -> bool {
    if s.pos + len(expected) > len(s.src) {
        return false
    }
    return s.src[s.pos:s.pos + len(expected)] == expected
}

// Check if current rune equals given rune
scanner_check :: proc(s: ^Scanner, expected: rune) -> bool {
    return scanner_peek_rune(s) == expected
}

// Advance by one rune, updating position
scanner_advance :: proc(s: ^Scanner) -> (r: rune, ok: bool) {
    if s.pos >= len(s.src) {
        return 0, false
    }

    size: int
    r, size = utf8.decode_rune_in_string(s.src[s.pos:])
    s.pos += size

    if r == '\n' {
        s.line += 1
        s.column = 1
    } else {
        s.column += 1
    }

    return r, true
}

// Advance by n bytes
scanner_advance_n :: proc(s: ^Scanner, n: int) {
    for i := 0; i < n && s.pos < len(s.src); {
        _, size := utf8.decode_rune_in_string(s.src[s.pos:])
        r := s.src[s.pos]
        s.pos += size
        i += size

        if r == '\n' {
            s.line += 1
            s.column = 1
        } else {
            s.column += 1
        }
    }
}

// Match and consume exact string
scanner_match :: proc(s: ^Scanner, expected: string) -> bool {
    if !scanner_check_ahead(s, expected) {
        return false
    }
    scanner_advance_n(s, len(expected))
    return true
}

// Match and consume if current char is given rune
scanner_match_rune :: proc(s: ^Scanner, expected: rune) -> bool {
    if scanner_peek_rune(s) != expected {
        return false
    }
    scanner_advance(s)
    return true
}

// Match and consume if current char is in set
scanner_match_one_of :: proc(s: ^Scanner, chars: string) -> (r: rune, ok: bool) {
    current := scanner_peek_rune(s)
    for c in chars {
        if current == c {
            scanner_advance(s)
            return current, true
        }
    }
    return 0, false
}

// Read while predicate is true, return content
scanner_take_while :: proc(s: ^Scanner, pred: proc(rune) -> bool) -> string {
    start := s.pos

    for !scanner_eof(s) {
        r := scanner_peek_rune(s)
        if !pred(r) {
            break
        }
        scanner_advance(s)
    }

    return s.src[start:s.pos]
}

// Read until delimiter rune, return content (delimiter not consumed)
scanner_take_until :: proc(s: ^Scanner, delimiter: rune) -> string {
    start := s.pos

    for !scanner_eof(s) {
        if scanner_peek_rune(s) == delimiter {
            break
        }
        scanner_advance(s)
    }

    return s.src[start:s.pos]
}

// Read until any of the delimiter chars, return content (delimiter not consumed)
scanner_take_until_any :: proc(s: ^Scanner, delimiters: string) -> string {
    start := s.pos

    outer: for !scanner_eof(s) {
        current := scanner_peek_rune(s)
        for d in delimiters {
            if current == d {
                break outer
            }
        }
        scanner_advance(s)
    }

    return s.src[start:s.pos]
}

// Skip while predicate is true, return skipped content
scanner_skip_while :: proc(s: ^Scanner, pred: proc(rune) -> bool) -> string {
    return scanner_take_while(s, pred)
}

// Skip whitespace (space, tab, newline)
scanner_skip_whitespace :: proc(s: ^Scanner) -> string {
    return scanner_take_while(s, is_whitespace)
}

// Skip horizontal whitespace only (space, tab)
scanner_skip_horizontal_whitespace :: proc(s: ^Scanner) -> string {
    return scanner_take_while(s, is_horizontal_whitespace)
}

// Helper predicates
is_whitespace :: proc(r: rune) -> bool {
    return r == ' ' || r == '\t' || r == '\n' || r == '\r'
}

is_horizontal_whitespace :: proc(r: rune) -> bool {
    return r == ' ' || r == '\t'
}

is_alpha :: proc(r: rune) -> bool {
    return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

is_digit :: proc(r: rune) -> bool {
    return r >= '0' && r <= '9'
}

is_alnum :: proc(r: rune) -> bool {
    return is_alpha(r) || is_digit(r)
}

is_ident_start :: proc(r: rune) -> bool {
    return is_alpha(r) || r == '_'
}

is_ident_char :: proc(r: rune) -> bool {
    return is_alnum(r) || r == '_'
}

is_tag_name_char :: proc(r: rune) -> bool {
    return is_alnum(r) || r == '-' || r == '_' || r == ':'
}

is_attr_name_char :: proc(r: rune) -> bool {
    return is_alnum(r) || r == '-' || r == '_' || r == ':' || r == '@'
}

is_unquoted_attr_char :: proc(r: rune) -> bool {
    return !is_whitespace(r) && r != '"' && r != '\'' && r != '=' && r != '<' && r != '>' && r != '`'
}

// Check if we're at a keyword followed by non-ident char
scanner_check_keyword :: proc(s: ^Scanner, keyword: string) -> bool {
    if !scanner_check_ahead(s, keyword) {
        return false
    }
    // Make sure it's not a prefix of a longer identifier
    if s.pos + len(keyword) < len(s.src) {
        next_char, _ := utf8.decode_rune_in_string(s.src[s.pos + len(keyword):])
        if is_ident_char(next_char) {
            return false
        }
    }
    return true
}
