This example builds a Checkbox and a nested counter section once, using `@` modifiers. **Show counter**
collapses or restores the section. **Increment** changes its reactive label;
**Reset** is reactively disabled at zero. Use **Tab** / **Shift+Tab** to focus
controls and **Enter** / **Space** to activate them. Both keys toggle Checkboxes.

From the repository root:

```sh
c3c run --path examples/window
```

Requires C3 0.8.4 and a Windows desktop or a local X11/XWayland display on Linux.
Close the window to exit and release its widgets and bindings.

## Modifiers

Widgets are created by plain methods (`text()`, `button()`, `checkbox()`,
`row()`, `column()`) and configured by `@` modifiers. A modifier changes the
widget it is called on and returns it, so modifiers chain:

```c3
struct Counter
{
    State{int} count;
    State{bool} shown;
}

Counter app = { .count.value = 5, .shown.value = true };
view.checkbox("Show counter").@checked(&app.shown);
view.@column({ .gap = 8, .max_width = 360 }; Widget* counter)
{
    counter.@visible(&app.shown);
    counter.text().@text(&app.count, "Count: %s");
    counter.@row({ .gap = 8 }; Widget* actions)
    {
        actions.button("Increment").@on_click(&app.count, fn (c) => c.set(c.get() + 1));
        actions.button("Reset")
            .@on_click(&app.count, fn (c) => c.set(0))
            .@enabled(&app.count, fn (c) => c.get() != 0);
    };
};
```

Every modifier takes a context pointer first. Lambda parameters are inferred
from it, so `fn (c) => ...` receives a `State{int}*` above, or a `Counter*` when
given `&app`. Lambdas cannot capture locals; reach state through the context.

| Modifier | Forms |
| --- | --- |
| `@text` | `(&state)` shows the value; `(&state, "Count: %s")` formats it; `(&ctx, fn (c) => String)` computes it. |
| `@visible`, `@enabled` | `(&bool_state)` or `(&ctx, fn (c) => bool)`. |
| `@checked` | `(&bool_state)` binds a Checkbox **both ways**; `(&ctx, fn (c) => bool)` only reads. |
| `@on_click` | `(&ctx, fn (c) { ... })` on Buttons. |
| `@on_change` | `(&ctx, fn (c, checked) { ... })` on Checkboxes; replaces the `@checked(&state)` writer. |

`@row` and `@column` on a View or container take a trailing body with the new
container, then return it. Format strings must be compile-time constants.
Wrong context or lambda types are compile errors. Modifiers are thin macros over
the `void*` API below and follow the same binding, ownership, and lifetime rules.

## Building a tree

`View.text()` and `View.button()` still add children to an implicit root Column.
`View.row()` and `View.column()` return stable `Widget*` container handles.
Containers expose the same creation methods, including `checkbox()`. The Button
handler is optional, which lets `@on_click` attach it. The underlying
callback API takes `void*` contexts:

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
`checkbox.@checked(&shown)` installs exactly this accepting pair. Written by hand:

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
## Keyboard behavior

Space and Enter activate a focused Button or toggle a focused Checkbox on the
**initial eligible press**. Holding either key produces no further activations;
a release followed by a new press allows another activation. Each physical key
has its own lifetime. A key pressed without an eligible target is still tracked.
Changing widget focus, hiding/disabling/clipping a control, or removing it does
not let the held key activate a replacement control. Callback self-removal and
bound Checkbox proposals follow the ownership rules above.

Tab and Shift+Tab traverse eligible controls in depth-first order and wrap.
**Tab repeats intentionally**, including while an activation key remains held.
`view.activate_focused()` is an explicit programmatic action: each call can
activate, independently of native key state. Native adapters use `key_down()` /
`key_up()`; these methods take a native key identity and the small `ControlKey`
action enum, rather than exposing a text-input API.

Blur clears widget input references and keyboard bookkeeping. Refocus reconciles
held activation keys using Win32 key state or X11 KeymapNotify. Opening/reopening
a native window resets the input lifetime; widgets and application State remain.
Windows honors WM_KEYDOWN's previous-state bit and consumes releases. X11 handles
both repeated presses and core autorepeat release/press pairs by matching the
keycode and server timestamp, without socket-peek timing assumptions. Core X11
cannot distinguish an actual release/repress of the same key within the same
server millisecond from such a repeat pair; that pair is conservatively suppressed.

X11 refreshes the full server keyboard mapping on MappingKeyboard and
MappingModifier notifications, retaining physical held-key identities. It ignores
MappingPointer. Refresh validates ranges, reply sequence, stride, and length,
replaces storage only after a complete reply, and frees previous storage. Input,
focus, exposure, and close events arriving during refresh are queued in order and
processed with the new map; extension payloads are consumed. Errors, unexpected
replies, truncated traffic, or more than 4096 queued events fail the window open
operation and release its resources. Normal disconnects still report
`CONNECTION_FAILED`.

Only the supported control keysyms in the first mapping column and the core Shift
mask are interpreted. Full keyboard groups, text input, IME, and accessibility
remain future work. No X11 client library or toolkit is required at runtime.

## Validation

Run from a checkout directory named **ui.c3l**. Both project files resolve the
library through `..`. Install C3 **0.8.4** and Python **3.12+** on PATH. For a fresh
compiler installation on Linux or Windows x64:

```sh
python3 scripts/install-c3.py --dest /path/to/new/c3
```

Use `python` on Windows. Add the destination directory to PATH. The installer
uses the [official v0.8.4 release](https://github.com/c3lang/c3c/releases/tag/v0.8.4),
pins the Linux static/Windows archive SHA-256 digests published in its release
metadata, rejects a mismatched download, and verifies the executable's version.
It requires a new destination and never overwrites an existing installation.

```sh
c3c test
c3c test -O3 --build-dir /tmp/ui-c3-release-test --output-dir /tmp/ui-c3-release-test
c3c build --path examples/window
python3 -m unittest discover -s tests -v
```

C3 tests cover bindings, typed modifiers, independent property cleanup, layout, shared keyboard
lifecycle, callback removal, X11 event translation, and (when built on Windows)
Win32 repeat metadata. The default Python suite runs simulated X11 tests on
Linux and skips desktop tests. Simulation includes complete key cycles, explicit
repeat pairs, mapping changes with changed strides, fragmented/interleaved
traffic, malformed replies, and disconnect cleanup.

Desktop tests remain opt-in. On Linux install `xvfb`, the core fixed font (usually
`xfonts-base`), and `libX11.so.6` **for the Python test driver only**, then run:

```sh
python3 scripts/test-xvfb.py
```

This starts its own Xvfb using `-displayfd`, supplies a fresh DISPLAY, enables the
native suite, reports startup/test failures, and stops the server even on failure.
The mapping test swaps/restores Return and Space on that isolated server.
`UI_TEST_ISOLATED_X11` is reserved for this runner; do not set it for a desktop.
No script depends on a temporary Xvfb installation path.

For an existing desktop (without keyboard-map edits):

```sh
UI_NATIVE_TESTS=1 python3 -m unittest discover -s tests -v
```

On Windows PowerShell, set `$env:UI_NATIVE_TESTS = '1'` then run
`python -m unittest discover -s tests -v`. Alternatively,
`python scripts/test-windows.py` checks for an accessible input desktop and
explicitly reports a skip if unavailable; test failures otherwise fail the run.
A window manager must allow test-window resize, so isolated Xvfb is preferred on
Linux. Fixtures report geometry for mouse targeting; X11 keycodes are queried
from the server on every cycle. Drivers inject X11 events / Win32 messages with
complete press/release cycles and explicit repeat metadata. These validate native
backend dispatch and rendering, not physical keyboard hardware or IME behavior.

[CI](../../.github/workflows/test.yml) configures Linux and Windows C3 tests,
optimized tests, and example builds. Linux additionally runs simulation and the
isolated native suite; Windows runs desktop tests when its input desktop is
available. Each job checks out into `ui.c3l` and verifies the pinned compiler.
A workflow definition is not evidence of a successful hosted CI run.

Linux can also check Windows compilation (this does not execute Windows code):

```sh
mkdir -p /tmp/ui-c3-win-check
c3c compile-only examples/window/src/main.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c compile-only tests/fixtures/nested_window.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c compile-only tests/fixtures/checkbox_window.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c compile-only tests/fixtures/keyboard_window.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c test --target windows-x64 -C --suppress-run
```

The last command checks Windows test semantics without running or linking them.
Native Windows execution must be reported separately from these checks.

This example is covered by the repository's [BSD 2-Clause License](../../LICENSE).
