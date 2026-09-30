This example builds a Checkbox and a nested counter section once. **Show counter**
collapses or restores the section. **Increment** changes its reactive label;
**Reset** is reactively disabled at zero. Use **Tab** / **Shift+Tab** to focus
controls and **Enter** / **Space** to activate them. Both keys toggle Checkboxes.

From the repository root:

```sh
c3c run --path examples/window
```

Requires C3 0.8.4 and a Windows desktop or a local X11/XWayland display on Linux.
Close the window to exit and release its widgets and bindings.

## Building a tree

`View.text()` and `View.button()` still add children to an implicit root Column.
`View.row()` and `View.column()` return stable `Widget*` container handles.
Containers expose the same creation methods, including `checkbox()`:

```c3
Widget* panel = view.column({ .padding = 12, .gap = 8, .max_width = 360 });
Widget* label = panel.text();
label.bind(&count_label, &count);
Widget* actions = panel.row({ .gap = 8 });
actions.button("Increment", &increment, &count);
actions.button("Reset", &reset, &count);
```

`container.append(widget)` moves an existing subtree to the end of the
container. `view.append(widget)` moves it to the end of the root. Both return
`false` without changing the tree for invalid attachments: null handles,
a different owning View, a leaf as parent, or a cycle. Appending a child already
at the end is a no-op. Reparenting preserves widget addresses and bindings.
There are no detached, application-owned widgets.

`widget.remove()` destroys the entire subtree. All its handles become invalid.
Removal unsubscribes bindings, removes pending evaluations, clears affected
hover/press/focus references, and damages the old visible area. Click and Checkbox
change callbacks may remove their own widget or an ancestor. `view.free()` destroys
everything; call it after the native window has closed.

## Layout rules

A `Layout` is a small value object. Containers accept one on creation; use
`widget.set_layout(layout)` to replace it later. The setter returns `false`
without changing anything for invalid options. Container constructors require
valid options. Unspecified fields are zero.

| Fields | Meaning |
| --- | --- |
| `width`, `height` | Preferred dimensions; zero selects content sizing. |
| `min_width`, `min_height` | Lower bounds on preferred dimensions. |
| `max_width`, `max_height` | Upper bounds; zero means no explicit upper bound. |
| `padding` | Equal inset on all four sides of a container. |
| `gap` | Space between visible children; no leading or trailing space. |

Values must be between 0 and 65535. A nonzero maximum must be at least its
minimum. Layout sums and coordinates saturate at 65535. Padding and gap must be
zero on Text, Button, and Checkbox widgets. Zero is the automatic dimension
sentinel; there is no separate explicit-zero-size sentinel.

Measurement runs from children to parents. A Row sums child widths and takes
the tallest height; a Column sums heights and takes the widest width. Padding
and gaps contribute to content size. An empty container measures twice its
padding on each axis. Explicit dimensions replace content size, then min/max
limits clamp the result. Labels remain single-line; buttons add their existing
12-pixel horizontal and 8-pixel vertical text insets. Checkboxes use a 16-pixel
box, 4-pixel outer insets, and an 8-pixel gap before a nonempty label.

Placement runs from parents to children, aligned to the top left. Children
retain their preferred size along the container's main axis. On its cross axis,
the parent's available content space caps the child's size, even below a
minimum. There is no stretching, wrapping, proportional shrinking, or scrolling.
Overflow is clipped to **every ancestor's padded content rectangle**. Partly
visible controls accept clicks only in their visible portion. Fully clipped,
hidden, or disabled controls are skipped during depth-first keyboard focus traversal.
Disabling a container also disables its descendants.

The implicit root fills the viewport, with padding 16 and gap 8 for compatibility.
`view.set_root_spacing(padding, gap)` changes those values and returns `false`
for invalid spacing. Resize changes placement and clipping using cached metrics.

## Reactive properties and visibility

`bind(fn String(void*), context)` binds Text content or a Button/Checkbox label.
`bind_enabled(fn bool(void*), context)` and `bind_visible(fn bool(void*), context)`
work on every widget. `bind_checked(fn bool(void*), context)` works on Checkboxes.
Bindings evaluate immediately on installation, then when their dependencies
change. A widget can have all applicable bindings simultaneously.

| Property | Imperative setter | Detach binding, keep current value |
| --- | --- | --- |
| Label | `set_text(text)` | `unbind()` (text only, for compatibility) |
| Enabled | `set_enabled(enabled)` | `unbind_enabled()` |
| Visible | `set_visible(visible)` | `unbind_visible()` |
| Checked | `set_checked(checked)` | `unbind_checked()` |

A setter or replacement binding detaches **only that property's** old edges and
queued evaluation, even when assigning the same value. Removal and View disposal
clean up all bindings. Equal labels avoid text measurement and repaint;
enabled and checked changes only affect input/paint, without layout or measurement.

Widgets start visible and enabled. `set_visible(false)` collapses the whole
subtree: it contributes no size, padding, or adjacent gap to its parent. A visible
empty container still contributes its own padding. A descendant cannot override
a hidden or disabled ancestor. Hiding/disabling cancels affected focus and presses;
hidden widgets cannot paint, hover, activate, or take keyboard focus.

Hidden widgets and bindings remain alive and subscribed. Their properties keep
updating; dirty measurements wait until restoration, while unchanged text metrics
are reused. Restoration lays out the latest values and damages old/new sibling
positions. `is_visible()` reports inherited logical visibility, `is_enabled()`
reports inherited enabled state, and `is_checked()` reports a Checkbox's value.
`Widget.visible` remains a **Rect** for clipped geometry, empty while hidden or
fully clipped. Hidden `bounds` and `desired` can retain cached values; do not use
them as evidence that a widget is displayed.

## Checkboxes and application state

`view.checkbox(label = "", checked = false, on_change = null, context = null)`
creates a root child. Containers expose the same signature. The optional
`CheckHandler` callback has signature `fn void(void* context, bool checked)`.
Click anywhere in the visible control or use Space/Enter while focused to toggle.
Mouse activation requires a press followed by release over that same control.

Without a checked binding, a Checkbox owns its checked state and updates it
before notifying the callback. With a checked binding, activation only **proposes**
the next value. The application may accept it by setting State, reject it by
leaving State unchanged, or apply it later. Activation preserves the binding.
Programmatic and binding updates never emit user-change callbacks.

```c3
fn bool shown_value(void* context)
{
    State{bool}* shown = context;
    return shown.get();
}
fn void changed(void* context, bool checked)
{
    State{bool}* shown = context;
    shown.set(checked);
}

// Keep shown and view at stable addresses until view.free().
State{bool} shown = { .value = true };
Widget* toggle = view.checkbox("Show details", on_change: &changed, context: &shown);
toggle.bind_checked(&shown_value, &shown);
Widget* details = view.column({ .padding = 8, .gap = 4 });
details.bind_visible(&shown_value, &shown);
details.text("These objects survive hiding and showing.");
```

Callbacks borrow their context; the View never frees it. A change callback can
mutate State, widgets, or the tree, including removing itself or an ancestor.
Binding callbacks are pure reads and cannot perform these mutations. Do not
access a removed handle after its callback returns.

## Updates and ownership

Keep the View, State values, and callback contexts at stable addresses. State
and callback contexts must outlive their widgets. All operations are on the UI
thread. The View owns widgets, copied labels, bindings, and subscriptions;
referenced data inside state values remains application-owned. Treat the tree,
geometry, and dirty fields as read-only and use the methods for changes.

`State.get()` inside a binding records dependencies automatically. Writes
coalesce until `view.update()`, and unchanged bindings are not evaluated again.
Bindings must only read state, without changing state, widgets, or the tree.
Each property has its own binding, dependency edges, and pending evaluation.
The same State can feed multiple properties and multiple Views. Equal outputs
skip property work while still rebuilding conditional dependencies.

Text metrics and container measurements are cached separately from placement.
Changed sizes invalidate affected ancestors; placement updates moved siblings
and descendants. Clean subtrees reuse their caches. Old and new visible bounds
are damaged when geometry changes. Hover is reconciled from the last pointer
position after layout and resize.

Native event loops update automatically. Headless callers use `view.resize()`
and `view.update()` before reading geometry, then `view.take_damage()` and
`view.paint()` to draw. Input methods flush pending updates before targeting
widgets. Damage remains one union rectangle and painting scans the tree.

The backends retain their existing text limitations: core X11 `fixed` font with
missing-glyph substitution on Linux, GDI on Windows, single-line UTF-8 labels
up to 4096 bytes, and no general shaping, font fallback, or accessibility API.
X11 currently activates on each relevant KeyPress and only loads the keyboard
mapping at startup; MappingNotify refresh and repeat/key-release handling remain
follow-ups. Windows suppresses repeated activation keydowns.

## Validation

Run from the repository root:

```sh
c3c test
c3c build --path examples/window
python3 -m unittest discover -s tests -v
UI_NATIVE_TESTS=1 python3 -m unittest discover -s tests -v
c3c test -O3 --build-dir /tmp/ui-c3-release-test --output-dir /tmp/ui-c3-release-test
```

The `UI_NATIVE_TESTS=1` command opens desktop test windows. Its fixtures report
native geometry so the driver can test mouse input, keyboard focus, resize,
clipping, checkbox properties, and removal without assuming font measurements
or X11 keycodes. The display must allow test windows to resize; an isolated Xvfb
display is useful when a desktop window manager overrides resize requests.
The test driver uses OS libraries through Python's `ctypes`; the library's
runtime dependency footprint is unchanged.

Linux can also check Windows compilation (this does not run Windows code):

```sh
mkdir -p /tmp/ui-c3-win-check
c3c compile-only examples/window/src/main.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c compile-only tests/fixtures/nested_window.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c compile-only tests/fixtures/checkbox_window.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
```

Windows runtime behavior still needs native validation.

This example is covered by the repository's [BSD 2-Clause License](../../LICENSE).
