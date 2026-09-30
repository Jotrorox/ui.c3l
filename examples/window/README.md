This counter builds a Column containing a reactive label and a Row of buttons.
Click **Increment** or **Reset**, or use **Tab** / **Shift+Tab** and
**Enter** / **Space**. State changes update the existing label; the widget tree
is built once.

From the repository root:

```sh
c3c run --path examples/window
```

Requires C3 0.8.4 and a Windows desktop or a local X11/XWayland display on Linux.
Close the window to exit and release its widgets and bindings.

## Building a tree

`View.text()` and `View.button()` still add children to an implicit root Column.
`View.row()` and `View.column()` return stable `Widget*` container handles.
Containers expose the same four creation methods:

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
hover/press/focus references, and damages the old visible area. Click callbacks
may remove their own widget or an ancestor. `view.free()` destroys everything;
call it after the native window has closed.

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
| `gap` | Space between children; no space before the first or after the last. |

Values must be between 0 and 65535. A nonzero maximum must be at least its
minimum. Layout sums and coordinates saturate at 65535. Padding and gap must be
zero on Text and Button widgets. Zero is the automatic dimension sentinel;
there is no separate explicit-zero-size or visibility property yet.

Measurement runs from children to parents. A Row sums child widths and takes
the tallest height; a Column sums heights and takes the widest width. Padding
and gaps contribute to content size. An empty container measures twice its
padding on each axis. Explicit dimensions replace content size, then min/max
limits clamp the result. Labels remain single-line; buttons add their existing
12-pixel horizontal and 8-pixel vertical text insets.

Placement runs from parents to children, aligned to the top left. Children
retain their preferred size along the container's main axis. On its cross axis,
the parent's available content space caps the child's size, even below a
minimum. There is no stretching, wrapping, proportional shrinking, or scrolling.
Overflow is clipped to **every ancestor's padded content rectangle**. Partly
visible buttons accept clicks only in their visible portion. Fully clipped or
disabled buttons are skipped during depth-first keyboard focus traversal.
Disabling a container also disables its descendants.

The implicit root fills the viewport, with padding 16 and gap 8 for compatibility.
`view.set_root_spacing(padding, gap)` changes those values and returns `false`
for invalid spacing. Resize changes placement and clipping using cached metrics.

## Updates and ownership

Keep the View, State values, and callback contexts at stable addresses. State
and callback contexts must outlive their widgets. All operations are on the UI
thread. The View owns widgets, copied labels, bindings, and subscriptions;
referenced data inside state values remains application-owned. Treat the tree,
geometry, and dirty fields as read-only and use the methods for changes.

`State.get()` inside a binding records dependencies automatically. Writes
coalesce until `view.update()`, and unchanged bindings are not evaluated again.
Bindings must only read state, without changing state, widgets, or the tree.
`set_text()` replaces the label binding; an equal label avoids measurement and
paint work. `set_enabled()` changes input and painting without layout work.

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

## Validation

Run from the repository root:

```sh
c3c test
c3c build --path examples/window
python3 -m unittest discover -s tests -v
UI_NATIVE_TESTS=1 python3 -m unittest discover -s tests -v
```

The last command opens desktop test windows. Its nested-layout fixture reports
native geometry so the driver can test mouse input, keyboard focus, resize,
clipping, and removal without assuming a font's measurements or X11 keycodes.
The test driver uses OS libraries through Python's `ctypes`; the library's
runtime dependency footprint is unchanged.

Linux can also check Windows compilation (this does not run Windows code):

```sh
mkdir -p /tmp/ui-c3-win-check
c3c compile-only examples/window/src/main.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
```

This example is covered by the repository's [BSD 2-Clause License](../../LICENSE).
