package todolist

import "core:fmt"
import "core:os"
import "core:strings"
import "views"

main :: proc() {
    // Sample data
    todos := []views.Todo{
        {id = 1, text = "Learn Odin programming", completed = true, priority = .Normal},
        {id = 2, text = "Build something with tempo", completed = false, priority = .High},
        {id = 3, text = "Write documentation", completed = false, priority = .Normal},
        {id = 4, text = "Add more examples", completed = false, priority = .Low},
        {id = 5, text = "Fix critical bug", completed = false, priority = .Urgent},
        {id = 6, text = "Review pull requests", completed = true, priority = .Normal},
    }

    // Render template to string
    b: strings.Builder
    strings.builder_init(&b)

    views.todo_list_page(&b, views.Todo_Page{
        todos       = todos,
        filter      = .All,
        theme_color = "#3498db",
    })

    // Write to index.html
    html := strings.to_string(b)
    if os.write_entire_file("index.html", transmute([]u8)html) {
        fmt.println("Generated: index.html")
    } else {
        fmt.eprintln("Error writing index.html")
    }
}
