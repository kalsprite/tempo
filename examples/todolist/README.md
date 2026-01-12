# Todo List Example

Demonstrates tempo templating features.

## Run

```bash
./build.sh
# Open index.html in browser
```

## Features Shown

- **Layout with slots** - `layout.templ`
- **Component composition** - `@layout() { ... }`, `@todo_item(todo)`
- **For loops** - `for todo in data.todos { ... }`
- **Conditionals** - `if/else`, `switch`
- **Dynamic classes** - `templ.classes()`, `templ.class_if()`
- **Boolean attrs** - `checked?={ todo.completed }`
- **Conditional attrs** - `if todo.completed { disabled }`
- **Style with `{{ }}`** - `--primary-color: {{ data.theme_color }};`
- **Odin blocks** - `{{ stats := calc_stats(data.todos) }}`
