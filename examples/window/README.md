This example builds an outer scroll column that fills the remaining window
height (with a 64-pixel minimum) and a 128-pixel nested scroll column once, using
`@` modifiers. Both opt into vertical scrollbars.
Drag a thumb, click above or below it to move one page, or scroll with the mouse
wheel. Dragging continues outside the window until release. **Tab** /
**Shift+Tab** reveals and focuses offscreen controls. The nested list consumes
wheel input until it reaches the requested end; the next wheel event can move
the outer list. **Enter** / **Space** activates a focused control.

The toolbar is a content-sized column above the list and keeps its natural
height when the window resizes. The outer list alone uses `fill = true`, so its
scroll extent uses the allocated viewport height after padding.
**Top** and **Bottom** use the programmatic
scrolling API. Item buttons change the reactive counter; **Reset** is disabled
at zero. **Show extra rows** changes both lists' content heights without
recreating widgets. Try hiding those rows while scrolled to the bottom: offsets
clamp, the outer thumb grows, and the nested scrollbar disappears when only one
row remains. The reserved gutters keep child widths stable. Resize the window
to see automatic widths stretch and the outer viewport fill the remaining
height while the nested viewport stays fixed.

From the repository root:

```sh
c3c run --path examples/window
```

Requires C3 0.8.4 and a Windows desktop or a Wayland/X11/XWayland display on Linux.
Linux selects the backend at runtime; set `UI_BACKEND=wayland` or `UI_BACKEND=x11`
to force one. Wayland retained views load libwayland-client, Cairo, and xkbcommon.
Close the window to exit and release its widgets and bindings.

## Modifiers

Widgets are created by plain methods (`text()`, `button()`, `checkbox()`,
`row()`, `column()`, `scroll_column()`) and configured by `@` modifiers. A modifier
changes the widget it is called on and returns it, so modifiers chain:

```c3
struct Counter
{
    State{int} count;
    State{bool} shown;
}

Counter app = { .count.value = 5, .shown.value = true };
view.set_root_alignment(CENTER, STRETCH);
view.@row({ .main_align = CENTER }; Widget* header)
{
    header.checkbox("Show counter").@checked(&app.shown);
};
view.@column({ .padding = 12, .gap = 12, .cross_align = STRETCH }; Widget* counter)
{
    counter.@visible(&app.shown);
    counter.@row({ .main_align = CENTER }; Widget* summary)
    {
        summary.text().@text(&app.count, "Count: %s");
    };
    counter.@row({ .gap = 8, .main_align = END }; Widget* actions)
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

`@row`, `@column`, and `@scroll_column` on a View or container take a trailing
body with the new container, then return it. Format strings must be compile-time constants.
Wrong context or lambda types are compile errors. Modifiers are thin macros over
the `void*` API below and follow the same binding, ownership, and lifetime rules.

## Building a tree

`View.text()` and `View.button()` still add children to an implicit root Column.
`View.row()`, `View.column()`, and `View.scroll_column()` return stable `Widget*`
container handles. Containers expose the same creation methods, including `checkbox()`. The Button
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
valid options. Unspecified size and spacing fields are zero; both alignment
fields default to `START`, and `fill` defaults to `false`.

C3 positional struct initializers require every field: existing positional
`Layout` initializers need trailing `START, START, false` for alignment and fill.
Designated initializers and default layouts keep their existing behavior.

| Fields | Meaning |
| --- | --- |
| `width`, `height` | Preferred dimensions; zero selects content sizing. |
| `min_width`, `min_height` | Lower bounds on preferred dimensions. |
| `max_width`, `max_height` | Upper bounds; zero means no explicit upper bound. |
| `padding` | Equal inset on all four sides of a container. |
| `gap` | Space between visible children; no leading or trailing space. |
| `main_align` | `START`, `CENTER`, or `END` for the group of visible children. |
| `cross_align` | `START`, `CENTER`, `END`, or `STRETCH` for each visible child. |
| `fill` | Opt a child into its parent's remaining main-axis space. |

Dimension and spacing values must be between 0 and 65535. A nonzero maximum must
be at least its minimum. Preferred dimensions and ordinary layout coordinates
saturate at 65535; scroll content extent is tracked separately, and descendant
coordinates within scroll subtrees may be negative.
Padding and gap must be zero on Text, Button, and Checkbox widgets, and both alignment fields must be
`START` on these leaves. Leaves can still have size constraints and are aligned
by their parent. Alignment values come from `ui::Alignment`; `STRETCH` is invalid
for `main_align`, and unknown enum values are rejected. Zero is the automatic
dimension sentinel; there is no separate explicit-zero-size sentinel.

Measurement runs from children to parents. A Row sums child widths and takes
the tallest height; a Column sums heights and takes the widest width. Padding
and gaps contribute to content size. An empty container measures twice its
padding on each axis. Explicit dimensions replace content size, then min/max
limits clamp the result. Labels remain single-line; buttons add their existing
12-pixel horizontal and 8-pixel vertical text insets. Checkboxes use a 16-pixel
box, 4-pixel outer insets, and an 8-pixel gap before a nonempty label.

Placement runs from parents to children inside their padded content rectangles.
A Row's main axis is horizontal and its cross axis vertical; a Column reverses
those axes. Padding is removed before computing available space. Main-axis
alignment positions the whole group of visible children, whose extent is the
sum of their allocated main-axis sizes plus intervening gaps. `START` adds no
offset, `CENTER` adds half the nonnegative remaining space rounded down, and
`END` adds all of it. Children without `fill` keep their preferred main-axis sizes.
When the group overflows, all three choices anchor it at the start, with no negative
offset or proportional shrinking. Hidden children add neither size nor gaps.

Set `.fill = true` on a child to use the remaining width in a Row or height in
a Column, including the implicit root. Placement first subtracts the parent's
padding, all visible non-filling siblings' constrained preferred main-axis sizes,
and the gaps between visible children. The remaining nonnegative space replaces
the filling child's preferred main-axis size, including a nonzero `width` or
`height`, then its main-axis min/max constraints clamp the result. It can shrink
below its preferred size; its minimum may overflow the parent when space is
insufficient. Other siblings keep their sizes. Its cross-axis sizing and cached
preferred size remain unchanged.

Multiple visible filling children receive equal shares, with remainder pixels
assigned in child order. Each share is clamped independently; space left by
maximum caps is not redistributed. Main-axis alignment uses the final allocated
group size, so a maximum-capped group can still be centered or end-aligned.
An automatic-size parent still measures its children's preferred sizes; fill
only allocates the space the parent receives during placement.

```c3
view.set_root_alignment(START, STRETCH);
view.text("Heading");
Widget* list = view.scroll_column({ .fill = true, .min_height = 64, .gap = 8 });
list.button("Item");
view.button("Footer");
```

The heading and footer keep their preferred heights. The list uses the remaining
height after root padding and gaps, and updates its scroll extent when resized.

Cross-axis `START`, `CENTER`, and `END` first cap each child's constrained
preferred size to the available content space, then apply the same offset rule
to that child. Cross-axis `STRETCH` fills available space for a child with an
automatic cross-axis size: `width == 0` in a Column, or `height == 0` in a Row.
A nonzero maximum still caps its stretched size. A nonzero explicit cross-axis
size opts out of stretch: the child keeps its constrained preferred size,
capped by available space, at the start edge. Maximum-capped stretched children
also stay at the start edge. Available cross-axis space always wins over a
minimum, including when no space remains. Stretch does not alter a child's
main-axis size or its cached preferred size. Empty containers still measure
their padding; alignment adds no intrinsic size.

All alignment defaults are `START`, preserving the original top-left geometry.
There is no weighted growth, wrapping, or proportional shrinking.
Overflow is clipped to **every ancestor's padded content rectangle**, excluding
any reserved scrollbar gutter. Partly
visible controls accept clicks only in their visible portion. Hidden or disabled
controls are skipped during depth-first keyboard focus traversal. Fully clipped
controls are also skipped unless scrolling can reveal them, as described below.
Disabling a container also disables its descendants.

The implicit root is always a non-scrolling Column that fills the viewport, with
padding 16, gap 8, and `START` alignment on both axes for compatibility.
`view.set_root_spacing(padding = 16, gap = 8)` changes its spacing independently
of `view.set_root_alignment(main_align = START, cross_align = START)`.
Both return `false` without changing anything for invalid options. The root
accepts no explicit dimensions, min/max constraints, or orientation change.
Its alignment follows the same rules as any Column:

```c3
view.set_root_alignment(CENTER, STRETCH);
Widget* panel = view.column({ .padding = 12, .cross_align = STRETCH });
Widget* actions = panel.row({ .gap = 8, .main_align = END });
actions.button("Save");
```

Here the root vertically centers `panel` and fills its automatic width. The
panel stretches the automatic-width action row, whose button sits at its end.
Setting `panel`'s explicit width would opt it out of root stretch; setting only
its maximum width would cap that stretch.

Changing only fill, alignment, root spacing, or viewport size requires placement
and clipping updates, reusing intrinsic sizes and text metrics. Widget size
constraints, padding, and gaps invalidate intrinsic measurements through their
ancestors but still reuse unchanged text metrics. Alignment never changes
intrinsic measurement. Runtime changes damage the old and new visible geometry
and reconcile hover, pressed controls, and keyboard focus after layout.

## Vertical scrolling

`View.scroll_column(layout = {})` and `Widget.scroll_column(layout = {})`
create explicit vertical scrolling containers. Their matching `@scroll_column`
macros take the same trailing body as `@column`. They accept every valid
container `Layout` option and expose the same child creation, reparenting,
visibility, and enabled APIs as Rows and Columns.

```c3
Widget* list = view.scroll_column({ .height = 180, .padding = 8, .gap = 4 });
list.set_scrollbar();                // Optional; reserves a gutter on the right.
for (int i = 0; i < 20; i++) list.button("Another item");
list.scroll_to(80);                  // Absolute pixels from the top.
list.scroll_by(-40);                 // Negative moves toward the top.
int offset = list.scroll_offset();   // Current clamped offset.
int extent = list.scroll_extent();   // Maximum offset, not content height.
list.scroll_to(extent);              // Move to the bottom.
```

The viewport's preferred size is measured like a Column: sum visible children's
preferred heights and intervening gaps, take the largest preferred width, add
padding and the optional scrollbar gutter, then apply explicit sizes and min/max.
Its parent places the viewport with the existing cross-axis cap and stretch
rules and optional main-axis fill. Set `height` or
`max_height` to bound the viewport, or `fill = true` to use its parent's remaining
height; an automatic non-filling height grows with content up to
the dimension limit. Ordinary ancestors can further clip a viewport without
resizing it or changing its extent. The implicit root never starts scrolling
automatically.

Content height is the sum of the immediate visible children's constrained
preferred heights plus one gap between each pair. A nested scroll column
contributes its preferred viewport height to this sum. Direct children of a
scroll column retain their preferred heights even with `fill = true`, because
the scrolling main axis is unbounded. Rows and ordinary Columns inside scroll
content still allocate fill within their own bounds. The maximum offset is
`max(0, content_height - max(0, viewport_height - 2 * padding))`. It can exceed
65535 even though individual layout dimensions and spacing cannot. Padding
stays stationary: scrolling subtracts the offset from child positions inside
the viewport's padded content rectangle, and each ancestor's clipping still
applies. Content can have negative coordinates when scrolled above the viewport.
Scroll content sums saturate at 1,073,741,823 pixels, with signed descendant
coordinates clamped to plus or minus that limit. Offsets and relative deltas use
wider intermediate arithmetic to avoid overflow. The limit is a deterministic
arithmetic bound, not support for arbitrarily large content or virtualized lists.

`main_align` places short content at the start, center, or end of the available
padded height with offset zero. Overflow starts at the top before subtracting
the scroll offset, regardless of alignment. `cross_align` uses the normal Column
rules within the width left after any scrollbar gutter, including automatic-width
stretch, explicit-width opt-out, maximum caps, and available width winning over
minimum width. Neither alignment nor scrolling
changes cached preferred sizes.

Hidden children contribute neither height nor gaps. An empty list has extent
zero and measures its padding plus any enabled scrollbar gutter before
constraints. Short content also has extent zero. If padding consumes the
viewport's height, the available height is
zero and extent equals content height, but descendants remain clipped. A
zero-width or zero-height visible region cannot receive wheel input or reveal
controls. Scrolling does not bypass clipping or create additional space.

Offsets start at zero. `scroll_to(int)` and `scroll_by(int)` clamp requests to
`[0, scroll_extent()]`, including negative requests and very large deltas.
Both return `true` for accepted calls on scroll columns, including clamped
requests and no-ops; on every other widget they return `false` without changes.
`scroll_offset()` and `scroll_extent()` return zero on non-scrolling widgets.
There are no corresponding root-scrolling methods on `View`.

On scroll columns, these methods flush pending reactive and layout work before
accessing geometry; scroll mutations place the result immediately. Calls on
other widgets return without flushing or changing the View. Scroll operations
and geometry queries cannot run inside binding callbacks, which must remain
pure reads of application state. Visible containers reclamp after resize,
content growth or shrinkage, child visibility changes, removal, and
reparenting. Offsets belong to the container and stay with its stable handle
when it moves. Hidden scroll containers retain their offset and cached extent;
clamping to changed content waits until restoration. Removing a container
destroys its scroll state with the rest of its subtree.
Explicit scroll calls on a hidden container are accepted and clamp against its
cached extent; restoration then clamps again against the current content.

Offset changes require placement, clipping, input reconciliation, and painting,
and reuse cached text and intrinsic measurements. Pending content or constraint
changes still perform their usual measurements before scrolling. Both old and
new visible content and scrollbar geometry are damaged, so repaint clears
exposed areas. Damage remains a single union rectangle.

### Optional vertical scrollbars

`Widget.set_scrollbar(bool enabled = true)` opts an explicit scroll column into
scrollbar display; `set_scrollbar(false)` restores its original geometry. It
returns `true` on scroll columns, including unchanged assignments. On Text,
Button, Checkbox, Row, and ordinary Column widgets it returns `false` without
changes, even when passed `false`. The implicit root has no scrollbar option.
There is no always-visible mode, additional widget, or separate scrollbar
binding. Existing scroll columns default to scrollbars disabled and keep their
previous geometry and behavior.

Enabling the option always adds `SCROLLBAR_WIDTH` (12 pixels) to the intrinsic
width before explicit width and min/max constraints. This is independent of
overflow and available space, so displaying the track cannot change measurement
or feed back into stretch. The gutter stays reserved when the track is absent.
Changing the option invalidates intrinsic size through ancestors and placement,
while reusing unchanged text metrics. Scrolling, dragging, and page clicks
require placement and paint only; they reuse intrinsic and text measurements.

First remove the container's padding. The gutter occupies the rightmost
`min(12, padded_width)` pixels of that rectangle, immediately inside the right
padding. The child content rectangle occupies the remaining width and all of
the padded height. All descendants are clipped to this narrower rectangle, so
they cannot paint or accept clicks in the gutter. Alignment, stretch, and
maximum-width constraints operate on this remaining child width. A nested
scrollbar is also clipped by every ancestor's child content rectangle.

The track spans the gutter's full padded height. Track and thumb appear only
when the option is enabled, the content overflows vertically, and padded width
and height are both positive. Ancestor clipping can further hide all or part of
them. Empty or short content has zero extent and no track. Padding that consumes
an axis produces no track or thumb. A viewport at most 12 pixels wide after
padding can devote its entire width to the gutter, leaving no visible children.
An overflowing track at most 16 pixels tall has a thumb filling its whole height:
it has no drag travel, but wheel and programmatic scrolling still work.

Let `V` be padded viewport height, `C` content height, `T` track height (`T = V`),
and `E = max(0, C - V)` maximum scroll offset. For an overflowing track:

```text
thumb_height = min(T, max(SCROLLBAR_MIN_THUMB, floor(T * V / C)))
travel = T - thumb_height
thumb_top = track_top + round_nearest(scroll_offset * travel / E)
```

`SCROLLBAR_MIN_THUMB` is 16 pixels. Nonnegative position ties round upward. The
top and bottom offsets map exactly to the corresponding ends of the track;
zero travel always positions the thumb at the top. Products and divisions use
64-bit intermediates, including at the separate large-content arithmetic limit.
Tracks and thumbs use the existing monochrome rendering.

After `view.update()`, `Widget.scrollbar` reports the enabled option, and
`Widget.scroll_track` / `Widget.scroll_thumb` expose their client-coordinate
rectangles. Treat these fields as read-only; mutate through `set_scrollbar()`
and the scroll methods. Both geometry rectangles are empty when there is no
displayed scrollbar; rendering and targeting additionally intersect them with
ancestor clipping.

### Thumb dragging and track clicks

A left press first targets the innermost visible scrollbar under the pointer.
An enabled scrollbar starts dragging on a press within its thumb. The anchor records the
pointer's initial client Y coordinate and the original scroll offset, preserving
the grab position without jumping. Each movement computes:

```text
new_offset = clamp(anchor_offset +
                   round_nearest((pointer_y - anchor_y) * E / travel), 0, E)
```

Signed drag ties round away from zero, using 64-bit intermediate arithmetic.
Zero travel leaves the offset unchanged. Movement depends on the anchored
vertical delta, not on the pointer's horizontal location or its current position
within the thumb. Native capture continues motion and release outside the
viewport and window: Windows uses `SetCapture`, and X11 uses the server's
automatic button grab. An outside release ends the interaction. Native crossing
events alone do not move the thumb.

A left press on the track above the thumb subtracts exactly `V` pixels; below
the thumb it adds exactly `V`, clamped to `[0, E]`. Page size uses the full
padded viewport height, even when an ancestor clips part of it. This happens
once on press, without autorepeat or a second step on release. It may move the
thumb beyond the clicked point; it does not stop early at that point. Pressing
the thumb never pages. A fully clipped scrollbar cannot be targeted; a disabled
scrollbar consumes its press without dragging or paging. Scrollbar interactions
never activate Buttons or Checkboxes beneath
them, and do not assign widget focus. Existing focus remains while the control
is still partly visible.

An active drag cancels when the View's viewport resizes, or the target's track,
clipped track geometry, content extent, or thumb length changes. It also cancels on an
external offset change (including wheel input or programmatic scrolling); Tab
or Shift+Tab traversal, even without an offset change; hiding, disabling,
removing, or reparenting the target or an ancestor;
disabling its scrollbar; blur or capture loss; and native window close/reopen.
Reactive changes follow these same rules. The updated layout is still applied
and its offset clamped. Further pointer movement cannot resume a canceled drag;
a fresh thumb press is required.

The identity of a scrollbar press remains reserved until release after target
cancellation or removal. Hover resumes once the target is canceled, even if
capture loss prevents a release from arriving. A later release remains consumed
and cannot become a widget click. Blur and native window close/reopen reset the
whole input lifetime, clearing all pending presses; stale releases remain inert.
Hover, pending widget presses, and focus reconcile after scrolling; held
activation keys retain their physical-key lifetime until blur or a window
lifetime reset. Tab traversal and wheel boundary bubbling keep the rules below
when scrollbars are enabled.

### Wheel routing and pointer state

`view.scroll_wheel(x, y, delta)` accepts client-coordinate pointer positions
and signed vertical pixels: positive scrolls down, negative scrolls up. It
returns `true` only if an offset moved. Pending changes are flushed before
targeting. The innermost logically visible and enabled scroll viewport under
the pointer that can move in the requested direction receives the event; when
it cannot move, its scroll ancestors are tried. The hit region includes the
viewport's padding, intersected with ancestor clipping. Disabled ancestors
disable wheel targeting as well as their controls.

Exactly one viewport consumes an event. If it reaches its end partway through
the delta, the unused delta is discarded; it does not also scroll an ancestor.
Further input in that direction can bubble to an ancestor. No movement means no
consumption. Wheel events never count as Button or Checkbox press/release.

X11 Button 4 scrolls up 40 pixels and Button 5 scrolls down 40 pixels. Windows
`WM_MOUSEWHEEL` converts a positive delta of 120 to 40 pixels upward, and a
negative delta to downward movement. Partial Windows deltas accumulate the
fractional pixel remainder across events for that native window's lifetime;
they are not rounded to full wheel notches. The remainder resets when the native
window closes or reopens. This is a fixed pixel step, independent of the OS
lines-per-notch preference. Horizontal wheel input is outside this milestone.

Moving a scroll offset cancels a pending mouse press, recomputes hover at the
last pointer position, and drops focus if the focused control becomes fully
clipped. A still-partly-visible focused control stays focused. A release at an
old pre-scroll position cannot activate a control. Held activation keys keep
their existing physical-key lifetime across scrolling and focus changes.

Horizontal scrolling, smooth animation, touch gestures, wheel acceleration,
wrapping, weighted growth, theming, text input, virtualization, and keyboard
PageUp/PageDown/Home/End navigation remain future work. Page navigation in this
milestone means track clicks only.

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
Changed sizes invalidate affected ancestors; alignment changes only invalidate
placement. Placement updates moved siblings and descendants, and clean subtrees
reuse their caches. Old and new visible bounds
are damaged when geometry changes. Hover is reconciled from the last pointer
position after layout and resize.

Native event loops update automatically. Headless callers use `view.resize()`
and `view.update()` before reading geometry, then `view.take_damage()` and
`view.paint()` to draw. Input methods flush pending updates before targeting
widgets. Damage remains one union rectangle and painting scans the tree.

The backends use core X11 `fixed` font with missing-glyph substitution on X11,
Cairo's sans font on Wayland, and GDI on Windows, with single-line UTF-8 labels
up to 4096 bytes, and no general shaping, font fallback, or accessibility API.
The X11 renderer clips drawing to the top-left 32767 by 32767 pixels to stay
within core protocol coordinate limits. Large scroll offsets still work because
visible descendants are translated into viewport coordinates before drawing;
offscreen coordinates are never narrowed by wrapping into that visible area.

## Keyboard behavior

Space and Enter activate a focused Button or toggle a focused Checkbox on the
**initial eligible press**. Holding either key produces no further activations;
a release followed by a new press allows another activation. Each physical key
has its own lifetime. A key pressed without an eligible target is still tracked.
Changing widget focus, hiding/disabling/clipping a control, or removing it does
not let the held key activate a replacement control. Callback self-removal and
bound Checkbox proposals follow the ownership rules above.

Tab and Shift+Tab traverse eligible controls in depth-first order and wrap.
An enabled, logically visible Button or Checkbox outside a scroll viewport can
be a candidate if scrolling can reveal it. Before assigning focus, traversal
reveals the candidate through its scroll ancestors, from inner to outer.
It moves the minimum distance to the nearer necessary edge: an item above the
viewport aligns its top, and an item below aligns its bottom. A control taller
than the available height aligns its top when chosen by traversal. Ordinary
ancestor clips still apply: a control that remains fully clipped by a non-scrolling ancestor,
or has no visible width or height after revealing, is skipped. Scrolling does
not make hidden or disabled controls eligible.

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
c3c test --sanitize=address --build-dir /tmp/ui-c3-asan-test --output-dir /tmp/ui-c3-asan-test
c3c build --path examples/window
python3 -m unittest discover -s tests -v
```

C3 tests cover bindings, typed modifiers, independent property cleanup, layout,
alignment and stretch, scroll extents and clamping, scrollbar gutter and thumb
geometry, drag/page input and cancellation, nested routing and focus reveal,
negative coordinates and clipping, reactive resize and reparenting,
cached placement and damage, shared keyboard lifecycle, callback removal,
X11 event translation, and (when built on Windows) Win32 repeat metadata and
partial wheel deltas. AddressSanitizer requires a supported compiler/runtime.
The default Python suite runs simulated X11 tests on Linux and skips desktop
tests. Simulation includes complete key cycles, explicit
repeat pairs, mapping changes with changed strides, fragmented/interleaved
traffic, malformed replies, and disconnect cleanup.

Desktop tests remain opt-in. On Linux install `xvfb`, the core fixed font (usually
`xfonts-base`), and `libX11.so.6` **for the Python test driver only**. Install
`libXtst.so.6` (usually `libxtst6`) to also verify actual pointer capture with
XTEST; that test reports an explicit skip when the library is unavailable.
Neither test-driver library is a runtime dependency of ui.c3l. Then run:

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
Directed X11 events do not create a server pointer grab. On isolated Xvfb, a
separate XTEST test creates a real button press and moves/releases outside the
window, verifying the server's automatic capture and release delivery. That
test runs only through the isolated runner; ordinary desktop tests use directed
events and do not verify actual server capture.
The alignment fixture checks centered content and stretched containers with native
font metrics, resized and runtime-moved action targets, and reactive label growth.
The scrolling fixture checks native wheel dispatch, nested boundary bubbling,
clipped mouse targets, and keyboard reveal with native text metrics. The
scrollbar fixture adds native thumb dragging, page clicks, cancellation, and
scrollbar rendering. These
fixtures are regression checks; cross-compilation alone does not run them.

[CI](../../.github/workflows/test.yml) configures Linux and Windows C3 tests,
optimized tests, and example builds. Linux additionally runs simulation and the
isolated native suite, installing `libxtst6` for the actual capture test; Windows
runs desktop tests when its input desktop is
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
c3c compile-only tests/fixtures/alignment_window.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c compile-only tests/fixtures/scroll_window.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c compile-only tests/fixtures/scrollbar_window.c3 --libdir .. --lib ui \
  --target windows-x64 --obj-out /tmp/ui-c3-win-check
c3c test --target windows-x64 -C --suppress-run
```

The last command checks Windows test semantics without running or linking them.
Native Windows execution must be reported separately from these checks.

This example is covered by the repository's [BSD 2-Clause License](../../LICENSE).
