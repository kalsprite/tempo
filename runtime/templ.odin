package templ

import "core:strings"
import "core:fmt"
import "core:crypto"
import "core:encoding/base64"

// Attribute map type
Attributes :: map[string]any

// Write HTML-escaped string to builder
write_escaped :: proc(w: ^strings.Builder, s: string) {
    for r in s {
        switch r {
        case '&':
            strings.write_string(w, "&amp;")
        case '<':
            strings.write_string(w, "&lt;")
        case '>':
            strings.write_string(w, "&gt;")
        case '"':
            strings.write_string(w, "&quot;")
        case '\'':
            strings.write_string(w, "&#39;")
        case:
            strings.write_rune(w, r)
        }
    }
}

// Write multiple attributes from a map
write_attrs :: proc(w: ^strings.Builder, attrs: Attributes) {
    for key, value in attrs {
        // Handle different value types
        switch v in value {
        case string:
            strings.write_string(w, " ")
            strings.write_string(w, key)
            strings.write_string(w, `="`)
            write_escaped(w, v)
            strings.write_string(w, `"`)
        case bool:
            // Boolean attribute - only write key if true
            if v {
                strings.write_string(w, " ")
                strings.write_string(w, key)
            }
        case int:
            strings.write_string(w, " ")
            strings.write_string(w, key)
            strings.write_string(w, `="`)
            fmt.sbprintf(w, "%d", v)
            strings.write_string(w, `"`)
        case:
            // Skip unknown types
        }
    }
}

// KV helper for conditional class names
KV :: struct {
    value:     string,
    condition: bool,
}

kv :: proc(value: string, condition: bool) -> KV {
    return KV{value = value, condition = condition}
}

// Write class attribute with multiple values and conditionals
write_classes :: proc(w: ^strings.Builder, classes: ..any) {
    strings.write_string(w, ` class="`)
    first := true

    for class in classes {
        switch c in class {
        case string:
            if c != "" {
                if !first {
                    strings.write_string(w, " ")
                }
                write_escaped(w, c)
                first = false
            }
        case KV:
            if c.condition && c.value != "" {
                if !first {
                    strings.write_string(w, " ")
                }
                write_escaped(w, c.value)
                first = false
            }
        }
    }

    strings.write_string(w, `"`)
}

// Class helpers for use in class={ } expressions
// Similar to templ's Classes() and Class()

// Returns class name if condition is true, empty string otherwise
// Usage: class={ templ.classes("btn", templ.class_if(is_active, "active")) }
class_if :: proc(condition: bool, name: string) -> string {
    return condition ? name : ""
}

// Join multiple class names, filtering out empty strings
// Usage: class={ templ.classes("btn", "primary", templ.class_if(is_active, "active")) }
classes :: proc(names: ..string) -> string {
    b: strings.Builder
    strings.builder_init(&b)
    first := true

    for name in names {
        if name != "" {
            if !first {
                strings.write_string(&b, " ")
            }
            strings.write_string(&b, name)
            first = false
        }
    }

    return strings.to_string(b)
}

// Render a template to string
render_to_string :: proc(template: proc(w: ^strings.Builder)) -> string {
    b: strings.Builder
    strings.builder_init(&b)
    template(&b)
    return strings.to_string(b)
}

// Render a template with a parameter to string
render_to_string_1 :: proc($T: typeid, template: proc(w: ^strings.Builder, arg: T), arg: T) -> string {
    b: strings.Builder
    strings.builder_init(&b)
    template(&b, arg)
    return strings.to_string(b)
}

// =============================================================================
// URL Sanitization
// =============================================================================

// Dangerous URL protocols that could execute code
@(private)
UNSAFE_PROTOCOLS :: []string{
    "javascript:",
    "vbscript:",
    "data:",
    "blob:",
}

// Safe URL protocols
@(private)
SAFE_PROTOCOLS :: []string{
    "http://",
    "https://",
    "mailto:",
    "tel:",
    "sms:",
    "ftp://",
    "ftps://",
    "file://",
    "/",   // Relative URLs starting with /
    "#",   // Fragment-only URLs
    "?",   // Query-only URLs
}

// URL sanitizes a URL string, returning "#" if the URL uses a dangerous protocol.
// Use this for user-provided URLs in href, src, and other URL attributes.
// Usage: <a href={ templ.url(user_link) }>
url :: proc(s: string) -> string {
    trimmed := strings.trim_left_space(s)
    lower := strings.to_lower(trimmed)
    defer delete(lower)

    // Check for dangerous protocols
    for protocol in UNSAFE_PROTOCOLS {
        if strings.has_prefix(lower, protocol) {
            return "#ZtemploUnsafeURL"
        }
    }

    // Allow safe protocols and relative URLs
    for protocol in SAFE_PROTOCOLS {
        if strings.has_prefix(lower, protocol) {
            return s
        }
    }

    // If no protocol specified, check if it looks like a relative URL
    // (doesn't contain ":" before first "/" or starts with alphanumeric)
    colon_idx := strings.index(lower, ":")
    slash_idx := strings.index(lower, "/")

    if colon_idx == -1 {
        // No protocol at all - relative URL, safe
        return s
    }

    if slash_idx != -1 && slash_idx < colon_idx {
        // Slash comes before colon - relative URL with port-like segment, safe
        return s
    }

    // Unknown protocol - block it
    return "#ZtemploUnsafeURL"
}

// SafeURL marks a URL as safe without sanitization.
// Only use this for URLs you trust completely (hardcoded or from trusted sources).
// Usage: <a href={ templ.safe_url(known_safe_link) }>
Safe_URL :: distinct string

safe_url :: proc(s: string) -> Safe_URL {
    return Safe_URL(s)
}

// Write a Safe_URL without additional escaping
write_safe_url :: proc(w: ^strings.Builder, s: Safe_URL) {
    strings.write_string(w, string(s))
}

// =============================================================================
// JSON Helpers
// =============================================================================

// Escape a string for safe embedding in JSON within HTML.
// Escapes: \ " < > & and control characters
json_escape :: proc(s: string) -> string {
    b: strings.Builder
    strings.builder_init(&b)

    for r in s {
        switch r {
        case '\\':
            strings.write_string(&b, "\\\\")
        case '"':
            strings.write_string(&b, "\\\"")
        case '\n':
            strings.write_string(&b, "\\n")
        case '\r':
            strings.write_string(&b, "\\r")
        case '\t':
            strings.write_string(&b, "\\t")
        case '<':
            // Prevent closing </script> or HTML injection
            strings.write_string(&b, "\\u003c")
        case '>':
            strings.write_string(&b, "\\u003e")
        case '&':
            // Prevent HTML entity injection
            strings.write_string(&b, "\\u0026")
        case:
            if r < 0x20 {
                // Other control characters
                fmt.sbprintf(&b, "\\u%04x", int(r))
            } else {
                strings.write_rune(&b, r)
            }
        }
    }

    return strings.to_string(b)
}

// Create a JSON string value (with quotes) safe for HTML embedding.
// Usage: <div data-config={ templ.json_string(config_json) }>
json_string :: proc(s: string) -> string {
    escaped := json_escape(s)
    return fmt.tprintf(`"%s"`, escaped)
}

// Write a JSON script element with the given ID and content.
// Usage: {{ templ.json_script(w, "config", config_json) }}
// Output: <script type="application/json" id="config">...</script>
json_script :: proc(w: ^strings.Builder, id: string, json_content: string) {
    strings.write_string(w, `<script type="application/json" id="`)
    write_escaped(w, id)
    strings.write_string(w, `">`)
    // JSON content - escape < > & to prevent breaking out of script
    for r in json_content {
        switch r {
        case '<':
            strings.write_string(w, "\\u003c")
        case '>':
            strings.write_string(w, "\\u003e")
        case '&':
            strings.write_string(w, "\\u0026")
        case:
            strings.write_rune(w, r)
        }
    }
    strings.write_string(w, "</script>")
}

// =============================================================================
// Script Safety
// =============================================================================

// Escape a string for safe use as a JavaScript string literal.
// This escapes characters that could break out of a JS string context.
js_escape :: proc(s: string) -> string {
    b: strings.Builder
    strings.builder_init(&b)

    for r in s {
        switch r {
        case '\\':
            strings.write_string(&b, "\\\\")
        case '\'':
            strings.write_string(&b, "\\'")
        case '"':
            strings.write_string(&b, "\\\"")
        case '`':
            strings.write_string(&b, "\\`")
        case '\n':
            strings.write_string(&b, "\\n")
        case '\r':
            strings.write_string(&b, "\\r")
        case '\t':
            strings.write_string(&b, "\\t")
        case '<':
            // Prevent </script> injection
            strings.write_string(&b, "\\x3c")
        case '>':
            strings.write_string(&b, "\\x3e")
        case '/':
            // Prevent </script> and --> injection
            strings.write_string(&b, "\\/")
        case '\u2028':
            // Line separator - invalid in JS strings
            strings.write_string(&b, "\\u2028")
        case '\u2029':
            // Paragraph separator - invalid in JS strings
            strings.write_string(&b, "\\u2029")
        case:
            if r < 0x20 {
                fmt.sbprintf(&b, "\\x%02x", int(r))
            } else {
                strings.write_rune(&b, r)
            }
        }
    }

    return strings.to_string(b)
}

// Create a safe JavaScript string literal (with quotes).
// Usage: onclick={ fmt.tprintf("handleClick('%s')", templ.safe_script(user_input)) }
safe_script :: proc(s: string) -> string {
    return fmt.tprintf("'%s'", js_escape(s))
}

// Write a safe JavaScript function call with string arguments.
// Usage: {{ templ.js_call(w, "handleClick", user_id, user_name) }}
// Output: handleClick('escaped_id', 'escaped_name')
js_call :: proc(w: ^strings.Builder, func_name: string, args: ..string) {
    strings.write_string(w, func_name)
    strings.write_string(w, "(")

    for arg, i in args {
        if i > 0 {
            strings.write_string(w, ", ")
        }
        strings.write_string(w, "'")
        escaped := js_escape(arg)
        strings.write_string(w, escaped)
        strings.write_string(w, "'")
    }

    strings.write_string(w, ")")
}

// =============================================================================
// CSP Nonce Support
// =============================================================================

// Nonce is a cryptographically random value for Content Security Policy.
// Each request should generate a new nonce and use it for all inline
// scripts/styles, then include it in the CSP header.
Nonce :: distinct string

// Generate a new cryptographically random nonce (16 bytes = 128 bits).
// Call this once per request and reuse for all inline scripts/styles.
generate_nonce :: proc() -> Nonce {
    bytes: [16]u8
    crypto.rand_bytes(bytes[:])
    encoded := base64.encode(bytes[:])
    return Nonce(encoded)
}

// Get the nonce as a string for use in CSP headers.
nonce_string :: proc(n: Nonce) -> string {
    return string(n)
}

// Generate the CSP header value with the given nonce.
// Usage: http.set_header(res, "Content-Security-Policy", templ.csp_header(nonce))
// Returns: "default-src 'self'; script-src 'self' 'nonce-XXX'; style-src 'self' 'nonce-XXX' 'unsafe-inline'"
csp_header :: proc(n: Nonce, extra_directives := "") -> string {
    nonce_str := string(n)
    if extra_directives != "" {
        return fmt.tprintf(
            "default-src 'self'; script-src 'self' 'nonce-%s'; style-src 'self' 'nonce-%s' 'unsafe-inline'; %s",
            nonce_str, nonce_str, extra_directives,
        )
    }
    return fmt.tprintf(
        "default-src 'self'; script-src 'self' 'nonce-%s'; style-src 'self' 'nonce-%s' 'unsafe-inline'",
        nonce_str, nonce_str,
    )
}

// Generate just the nonce directive for custom CSP headers.
// Usage: fmt.tprintf("script-src 'self' %s", templ.nonce_directive(nonce))
// Returns: 'nonce-XXX'
nonce_directive :: proc(n: Nonce) -> string {
    return fmt.tprintf("'nonce-%s'", string(n))
}

// Write a nonce attribute to the builder.
// Usage: <script {{ templ.nonce_attr(w, nonce) }}>
nonce_attr :: proc(w: ^strings.Builder, n: Nonce) {
    strings.write_string(w, ` nonce="`)
    strings.write_string(w, string(n))
    strings.write_string(w, `"`)
}

// Write an opening script tag with nonce.
// Usage: {{ templ.script_open(w, nonce) }} ... {{ templ.script_close(w) }}
script_open :: proc(w: ^strings.Builder, n: Nonce) {
    strings.write_string(w, `<script nonce="`)
    strings.write_string(w, string(n))
    strings.write_string(w, `">`)
}

script_close :: proc(w: ^strings.Builder) {
    strings.write_string(w, "</script>")
}

// Write an opening style tag with nonce.
// Usage: {{ templ.style_open(w, nonce) }} ... {{ templ.style_close(w) }}
style_open :: proc(w: ^strings.Builder, n: Nonce) {
    strings.write_string(w, `<style nonce="`)
    strings.write_string(w, string(n))
    strings.write_string(w, `">`)
}

style_close :: proc(w: ^strings.Builder) {
    strings.write_string(w, "</style>")
}

// Write a complete inline script with nonce.
// Usage: {{ templ.inline_script(w, nonce, "console.log('hello')") }}
inline_script :: proc(w: ^strings.Builder, n: Nonce, code: string) {
    script_open(w, n)
    // Escape </script> in the code
    for r in code {
        switch r {
        case '<':
            strings.write_string(w, "\\x3c")
        case:
            strings.write_rune(w, r)
        }
    }
    script_close(w)
}

// Write a complete inline style with nonce.
// Usage: {{ templ.inline_style(w, nonce, ".foo { color: red; }") }}
inline_style :: proc(w: ^strings.Builder, n: Nonce, css: string) {
    style_open(w, n)
    // Escape </style> in the CSS
    for r in css {
        switch r {
        case '<':
            strings.write_string(w, "\\3c ")
        case:
            strings.write_rune(w, r)
        }
    }
    style_close(w)
}
