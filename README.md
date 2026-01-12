# Tempo

HTML templating for Odin. Inspired by Go's [templ](https://templ.guide/). Project is WIP, but thus far has been meeting my needs. I may change the extension to .tempo to not collide with go-templ's extension.

## Install

```bash
odin build src -out:tempo
```

## Usage

Place tempo on your PATH, or just run it as a normal executable pointed at target paths.

```bash
# Generate all .templ files in a directory
tempo generate ./views

# Options
tempo generate ./views -runtime=path/to/runtime  # Custom runtime path
tempo generate ./views -v                        # Verbose output
tempo generate file.templ -o=output.odin         # Single file with custom output
tempo generate file.templ -stdout                # Output generated Odin to stdout
```

## Template Syntax

```
package views

import "core:fmt"

// Template definition
page :: templ(title: string, items: []Item) {
    <!DOCTYPE html>
    <html>
    <head>
        <title>{ title }</title>
        <style>
            .highlight { color: {{ theme_color }}; }
        </style>
    </head>
    <body>
        // Conditionals
        if len(items) == 0 {
            <p>No items</p>
        } else {
            <ul>
                // Loops
                for item in items {
                    <li class={ templ.classes("item", templ.class_if(item.active, "active")) }>
                        { item.name }
                    </li>
                }
            </ul>
        }

        // Component calls
        @footer()

        // Raw HTML (unescaped)
        {! raw_html_string }

        // Odin code blocks
        {{ count := len(items) }}
        <span>{ fmt.tprintf("%d items", count) }</span>
    </body>
    </html>
}

// Components
footer :: templ() {
    <footer>Copyright 2024</footer>
}
```

## Features

- **Expressions**: `{ expr }` - HTML escaped, `{! expr }` - raw output
- **Style/Script blocks**: Use `{{ expr }}` inside `<style>` and `<script>` tags
- **Conditionals**: `if/else`, `switch`
- **Loops**: `for item in items { }`, `for i in 0..<10 { }`
- **Components**: `@component_name(args)`
- **Layouts with slots**: `{#slot}`, `{#slot name}`, `#name { content }`
- **Dynamic classes**: `templ.classes()`, `templ.class_if()`
- **Boolean attributes**: `checked?={ is_checked }`
- **Conditional attributes**: `if condition { disabled }`
- **CSS components**: `name :: css() { ... }` generates class name + `name_css` constant
- **Script components**: `name :: script() { ... }` generates function name + `name_js` constant

## Templating TL;DR

  - { expr } - escaped output
  - {! expr } - raw output (unescaped)
  - {{ code }} - Odin code block (statements, outside style/script)
  - {{ expr }} - raw expression (inside style/script blocks only)

## Example

See [examples/todolist](examples/todolist) for a complete example demonstrating all features.

```bash
cd examples/todolist
./build.sh
# Open index.html in browser
```

## Runtime

Templates require the tempo runtime. Copy `runtime/templ.odin` to your project or reference it via import path.

## License

BSD-3