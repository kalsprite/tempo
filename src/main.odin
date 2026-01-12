package tempo

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

main :: proc() {
    if len(os.args) < 2 {
        print_usage()
        os.exit(1)
    }

    command := os.args[1]

    switch command {
    case "generate", "gen":
        cmd_generate_batch()

    case "parse":
        if len(os.args) < 3 {
            fmt.eprintln("Usage: tempo parse <file.templ>")
            os.exit(1)
        }
        cmd_parse(os.args[2])

    case "help", "-h", "--help":
        print_usage()

    case:
        // Default: treat as filename for backwards compatibility
        if strings.has_suffix(command, ".templ") {
            cmd_parse(command)
        } else {
            fmt.eprintfln("Unknown command: %s", command)
            print_usage()
            os.exit(1)
        }
    }
}

print_usage :: proc() {
    fmt.println("tempo - HTML templating for Odin")
    fmt.println("")
    fmt.println("Usage:")
    fmt.println("  tempo generate [path...] [options]")
    fmt.println("                           Generate Odin code from templates")
    fmt.println("  tempo parse <file.templ> Parse and show AST (debug)")
    fmt.println("  tempo help               Show this help")
    fmt.println("")
    fmt.println("Generate options:")
    fmt.println("  -runtime=<path>   Import path for tempo runtime (default: \"tempo\")")
    fmt.println("  -o=<file>         Output file (single file mode only)")
    fmt.println("  -stdout           Write to stdout instead of files")
    fmt.println("  -v, -verbose      Show files being processed")
    fmt.println("")
    fmt.println("Examples:")
    fmt.println("  tempo generate                      # All .templ files in current dir")
    fmt.println("  tempo generate ./views              # All .templ files in views/")
    fmt.println("  tempo generate index.templ          # Single file -> index_gen.odin")
    fmt.println("  tempo generate *.templ              # Multiple files (shell glob)")
    fmt.println("  tempo generate -runtime=../tempo    # Custom runtime path")
}

// Batch generate command
cmd_generate_batch :: proc() {
    // Parse arguments
    runtime_pkg := "tempo"
    output_file := ""
    use_stdout := false
    verbose := false
    paths: [dynamic]string

    for i := 2; i < len(os.args); i += 1 {
        arg := os.args[i]

        if strings.has_prefix(arg, "-runtime=") {
            runtime_pkg = arg[9:]
        } else if strings.has_prefix(arg, "--runtime=") {
            runtime_pkg = arg[10:]
        } else if strings.has_prefix(arg, "-o=") {
            output_file = arg[3:]
        } else if strings.has_prefix(arg, "--output=") {
            output_file = arg[9:]
        } else if arg == "-stdout" || arg == "--stdout" {
            use_stdout = true
        } else if arg == "-v" || arg == "-verbose" || arg == "--verbose" {
            verbose = true
        } else if !strings.has_prefix(arg, "-") {
            append(&paths, arg)
        }
    }

    // Default to current directory if no paths specified
    if len(paths) == 0 {
        append(&paths, ".")
    }

    // Collect all .templ files
    files: [dynamic]string
    for path in paths {
        collect_templ_files(path, &files)
    }

    if len(files) == 0 {
        fmt.eprintln("No .templ files found")
        os.exit(1)
    }

    // Single file with -o flag
    if output_file != "" && len(files) != 1 {
        fmt.eprintln("Error: -o flag can only be used with a single input file")
        os.exit(1)
    }

    // Process each file
    errors_count := 0
    for file in files {
        if verbose {
            fmt.printfln("Processing: %s", file)
        }

        success := process_templ_file(file, runtime_pkg, output_file, use_stdout)
        if !success {
            errors_count += 1
        }
    }

    if verbose && !use_stdout {
        fmt.printfln("Generated %d file(s)", len(files) - errors_count)
    }

    if errors_count > 0 {
        os.exit(1)
    }
}

// Collect all .templ files from a path (file or directory)
collect_templ_files :: proc(path: string, files: ^[dynamic]string) {
    // Check if it's a file or directory
    info, err := os.stat(path)

    if err != os.ERROR_NONE {
        // Try as a glob pattern or just report error
        fmt.eprintfln("Warning: cannot access '%s'", path)
        return
    }

    mode := u32(info.mode)
    if os.S_ISREG(mode) {
        // Single file
        if strings.has_suffix(path, ".templ") {
            append(files, path)
        }
    } else if os.S_ISDIR(mode) {
        // Directory - walk recursively
        walk_directory(path, files)
    }
}

// Recursively walk directory for .templ files
walk_directory :: proc(dir: string, files: ^[dynamic]string) {
    handle, err := os.open(dir)
    if err != os.ERROR_NONE {
        return
    }
    defer os.close(handle)

    entries, read_err := os.read_dir(handle, -1)
    if read_err != os.ERROR_NONE {
        return
    }

    for entry in entries {
        full_path := filepath.join({dir, entry.name})

        if entry.is_dir {
            // Skip hidden directories
            if !strings.has_prefix(entry.name, ".") {
                walk_directory(full_path, files)
            }
        } else if strings.has_suffix(entry.name, ".templ") {
            append(files, full_path)
        }
    }
}

// Process a single .templ file
process_templ_file :: proc(filename: string, runtime_pkg: string, output_file: string, use_stdout: bool) -> bool {
    data, ok := os.read_entire_file(filename)
    if !ok {
        fmt.eprintfln("Error: could not read file '%s'", filename)
        return false
    }

    src := string(data)
    segments, errors := segment_file(src)

    if len(errors) > 0 {
        fmt.eprintfln("Errors in %s:", filename)
        print_errors(errors, filename)
        return false
    }

    // Generate Odin code
    output := generate_from_segments(segments, filename, runtime_pkg)

    if use_stdout {
        fmt.print(output)
        return true
    }

    // Determine output filename
    out_path: string
    if output_file != "" {
        out_path = output_file
    } else {
        // foo.templ -> foo_gen.odin
        out_path = templ_to_gen_path(filename)
    }

    // Write to file
    write_ok := os.write_entire_file(out_path, transmute([]u8)output)
    if !write_ok {
        fmt.eprintfln("Error: could not write file '%s'", out_path)
        return false
    }

    return true
}

// Convert foo.templ to foo_gen.odin
templ_to_gen_path :: proc(path: string) -> string {
    if strings.has_suffix(path, ".templ") {
        base := path[:len(path) - 6]  // Remove ".templ"
        return strings.concatenate({base, "_gen.odin"})
    }
    return strings.concatenate({path, "_gen.odin"})
}

cmd_parse :: proc(filename: string) {
    data, ok := os.read_entire_file(filename)
    if !ok {
        fmt.eprintfln("Error: could not read file '%s'", filename)
        os.exit(1)
    }

    src := string(data)
    segments, errors := segment_file(src)

    if len(errors) > 0 {
        print_errors(errors, filename)
        os.exit(1)
    }

    fmt.printfln("Parsed %d segments:", len(segments))
    for seg in segments {
        switch s in seg {
        case Package_Segment:
            fmt.printfln("  Package: %s", s.name)
        case Import_Segment:
            fmt.printfln("  Import: %s", s.text)
        case Odin_Segment:
            fmt.printfln("  Odin: %s", s.name)
        case Templ_Segment:
            fmt.printfln("  Template: %s%s", s.name, s.params)
            template, parse_ok := parse_template(s)
            if parse_ok {
                print_template_body(template.body, 2)
            }
        case CSS_Segment:
            fmt.printfln("  CSS: %s%s", s.name, s.params)
        case Script_Segment:
            fmt.printfln("  Script: %s%s", s.name, s.params)
        }
    }
}

print_errors :: proc(errors: []Parse_Error, filename := "") {
    for err in errors {
        if filename != "" {
            fmt.eprintfln("%s:%d:%d: error: %s", filename, err.pos.line, err.pos.column, err.msg)
        } else {
            fmt.eprintfln("error: %s at %d:%d", err.msg, err.pos.line, err.pos.column)
        }
        for note in err.notes {
            fmt.eprintfln("  note: %s at %d:%d", note.msg, note.pos.line, note.pos.column)
        }
    }
}

// Print template body with indentation
print_template_body :: proc(nodes: []Node, indent: int) {
    for node in nodes {
        print_node(node, indent)
    }
}

print_indent :: proc(indent: int) {
    for _ in 0..<indent {
        fmt.print("  ")
    }
}

print_node :: proc(node: Node, indent: int) {
    switch n in node {
    case Element:
        print_indent(indent)
        if n.self_close {
            fmt.printfln("<Element: %s (self-close) attrs=%d>", n.tag, len(n.attributes))
        } else if n.void {
            fmt.printfln("<Element: %s (void) attrs=%d>", n.tag, len(n.attributes))
        } else {
            fmt.printfln("<Element: %s attrs=%d>", n.tag, len(n.attributes))
        }
        for attr in n.attributes {
            print_attribute(attr, indent + 1)
        }
        print_template_body(n.children, indent + 1)

    case Text:
        if len(n.value) > 0 {
            print_indent(indent)
            text := n.value
            if len(text) > 30 {
                text = fmt.tprintf("%s...", text[:30])
            }
            fmt.printfln("<Text: %q>", text)
        }

    case Whitespace:
        // Skip

    case Expr:
        print_indent(indent)
        fmt.printfln("<Expr: {{ %s }}>", n.value)

    case Raw_Expr:
        print_indent(indent)
        fmt.printfln("<RawExpr: {{! %s }}>", n.value)

    case Odin_Block:
        print_indent(indent)
        fmt.printfln("<OdinBlock: {{{{ %s }}}}>", n.code)

    case If_Node:
        print_indent(indent)
        fmt.printfln("<If: %s>", n.cond)
        print_indent(indent + 1)
        fmt.println("<Then>")
        print_template_body(n.then_, indent + 2)
        for ei in n.else_ifs {
            print_indent(indent + 1)
            fmt.printfln("<ElseIf: %s>", ei.cond)
            print_template_body(ei.then_, indent + 2)
        }
        if len(n.else_) > 0 {
            print_indent(indent + 1)
            fmt.println("<Else>")
            print_template_body(n.else_, indent + 2)
        }

    case For_Node:
        print_indent(indent)
        fmt.printfln("<For: %s>", n.clause)
        print_template_body(n.body, indent + 1)

    case Switch_Node:
        print_indent(indent)
        fmt.printfln("<Switch: %s>", n.expr)
        for c in n.cases {
            print_indent(indent + 1)
            fmt.printfln("<Case: %s>", c.expr)
            print_template_body(c.body, indent + 2)
        }

    case Call:
        print_indent(indent)
        has_slots := len(n.default_slot) > 0 || len(n.named_slots) > 0
        if has_slots {
            fmt.printfln("<Call: @%s with slots>", n.expr)
            if len(n.default_slot) > 0 {
                print_indent(indent + 1)
                fmt.println("<DefaultSlot>")
                print_template_body(n.default_slot, indent + 2)
            }
            for ns in n.named_slots {
                print_indent(indent + 1)
                fmt.printfln("<Slot: #%s>", ns.name)
                print_template_body(ns.body, indent + 2)
            }
        } else {
            fmt.printfln("<Call: @%s>", n.expr)
        }

    case Slot:
        print_indent(indent)
        if name, ok := n.name.?; ok {
            fmt.printfln("<Slot: #slot %s>", name)
        } else {
            fmt.println("<Slot: #slot>")
        }

    case Comment:
        print_indent(indent)
        if n.html {
            fmt.printfln("<HTMLComment: %s>", n.text)
        } else {
            fmt.printfln("<OdinComment: %s>", n.text)
        }
    }
}

print_attribute :: proc(attr: Attribute, indent: int) {
    print_indent(indent)
    switch a in attr {
    case Const_Attr:
        fmt.printfln("@attr: %s=%q", a.key, a.value)
    case Expr_Attr:
        fmt.printfln("@attr: %s={{ %s }}", a.key, a.expr)
    case Bool_Attr:
        fmt.printfln("@attr: %s (bool)", a.key)
    case Bool_Expr_Attr:
        fmt.printfln("@attr: %s?={{ %s }}", a.key, a.expr)
    case Cond_Attr:
        fmt.printfln("@attr: if %s {{ ... }}", a.cond)
    case Spread_Attr:
        fmt.printfln("@attr: {{ %s }}", a.expr)
    }
}
