package tempo

import "core:fmt"

// A position in source code
Pos :: struct {
    offset: int,   // byte offset from start of file
    line:   u32,   // 1-indexed line number
    column: u32,   // 1-indexed column (byte offset from start of line)
}

// A range in source code
Range :: struct {
    start: Pos,
    end:   Pos,
}

// Source file info
Source :: struct {
    filename: string,
    content:  string,
}

// Create a position
pos_make :: proc(offset: int, line, column: u32) -> Pos {
    return Pos{offset = offset, line = line, column = column}
}

// Check if position is valid
pos_valid :: proc(p: Pos) -> bool {
    return p.line > 0 && p.column > 0
}

// Format position for error messages: "file.templ:10:5"
pos_string :: proc(src: Source, p: Pos, allocator := context.allocator) -> string {
    if src.filename != "" {
        return fmt.aprintf("%s:%d:%d", src.filename, p.line, p.column, allocator = allocator)
    }
    return fmt.aprintf("%d:%d", p.line, p.column, allocator = allocator)
}

// Create a range
range_make :: proc(start, end: Pos) -> Range {
    return Range{start = start, end = end}
}

// Get the text content of a range
range_text :: proc(src: Source, r: Range) -> string {
    if r.start.offset < 0 || r.end.offset > len(src.content) {
        return ""
    }
    return src.content[r.start.offset:r.end.offset]
}

// Check if a range is valid
range_valid :: proc(r: Range) -> bool {
    return pos_valid(r.start) && pos_valid(r.end) && r.start.offset <= r.end.offset
}

// Check if a position is within a range
pos_in_range :: proc(p: Pos, r: Range) -> bool {
    return p.offset >= r.start.offset && p.offset < r.end.offset
}

// Get the length of a range in bytes
range_len :: proc(r: Range) -> int {
    return r.end.offset - r.start.offset
}
