# Searchable list

```sh
c3c run --path examples/search
```

Click the field or press Tab to focus it. Type to filter sixteen fruit buttons,
then choose a result or clear the query. The result count and empty state update
with the filter, and the list keeps a proportional scrollbar as the window resizes.
Search ignores ASCII case. Each modifier context lives at a stable address until
the view has been freed.

The field owns its UTF-8 text. Its change callback copies the borrowed snapshot
into application storage, then notifies reactive visibility/count bindings.
`set_text()` is silent, so Clear explicitly updates both the field and application
state. This avoids retaining a string that points into a widget or temporary event.

Use Left/Right, Home/End, Backspace/Delete, Shift with navigation to select,
Ctrl-A (Command-A on macOS), and mouse dragging. Long text scrolls horizontally
to keep the caret visible. Tab/Shift-Tab move between the field and result buttons;
Enter/Space activate a focused result. In the field, Space inserts committed text
and Enter leaves the single line unchanged.

See the [TextField contract](../../README.md#textfield) for ownership, Unicode,
native input support, and the initial milestone's limitations.
