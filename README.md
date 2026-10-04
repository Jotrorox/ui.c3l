# ui.c3l

A small reactive retained-mode UI library for macOS, Windows, and Linux (Wayland and X11/XWayland),
with text, buttons, checkboxes, single-line text fields, nested rows and columns,
and vertical scrollbars.
Requires C3 0.8.4 or newer.

```c3
view.set_root_alignment(START, STRETCH);
view.@scroll_column({ .fill = true, .min_height = 64, .padding = 8, .gap = 8,
	.cross_align = STRETCH }; Widget* list)
{
	list.set_scrollbar();
	list.text().@text(&app.count, "Count: %s");
	for (int i = 0; i < 12; i++)
	{
		list.button("Increment").@on_click(&app.count, fn (c) => c.set(c.get() + 1));
	}
};
```

`set_scrollbar()` opts a scroll column into a reserved gutter with a proportional
thumb while overflowing. Drag the thumb, click the track to move one page, or
use the wheel; nested lists bubble wheel input at their ends. PageUp/PageDown
move one viewport, and Home/End move to its limits outside a text field, starting at the focused
control's nearest scroll container and bubbling at boundaries. Tab reveals
offscreen controls. Scroll container handles expose `scroll_to(y)`, `scroll_by(dy)`,
`scroll_offset()`, and `scroll_extent()` for programmatic scrolling. Rows and
columns retain start, center, and end alignment, plus cross-axis stretch for
automatic sizes. A child with `Layout.fill = true` takes the remaining main-axis
space after preferred-size siblings, padding, and gaps, respecting its min/max
constraints. This lets a scroll viewport follow the window's available height.
The implicit root keeps its existing non-scrolling behavior. See the
[scrolling contract](examples/window/README.md#vertical-scrolling) for sizing,
clipping, input, and clamping rules.

Run the [nested scrollbar example](examples/window), including reactive content
changes and Top/Bottom controls:

```sh
c3c run --path examples/window
```

## Theme and style

Each view starts with `DEFAULT_THEME`. Copy it (or call `get_theme()`), edit the
palette and metrics, then apply it before opening or from an event callback:

```c3
Theme theme = view.get_theme();
theme.colors[Ink.PAPER] = { 24, 28, 36 }; // Window background, opaque sRGB.
theme.colors[Ink.INK] = { 235, 239, 245 }; // Text and checked marks.
theme.colors[Ink.SURFACE] = { 40, 46, 58 };
theme.colors[Ink.HOVER] = { 54, 62, 76 };
theme.colors[Ink.BORDER] = { 105, 117, 138 };
theme.colors[Ink.FOCUS] = { 100, 180, 255 };
theme.font_size = 18;
theme.padding = 20;
theme.gap = 10;
theme.control_padding_x = 14;
theme.control_padding_y = 10;
bool applied = view.set_theme(theme);
```

`set_theme()` validates atomically and returns `false` for invalid metrics.
Font sizes range from 1 to 256 pixels (logical points on macOS). Root padding
and gaps range from 0 to 65535; control padding ranges from 0 to 32767.
`get_theme()` returns a copy. Palette-only changes repaint without remeasuring
text; equal assignments do nothing. Font changes refresh text, caret, and layout
metrics, including hidden content when it is restored. Each view owns its theme.

| Palette role | Use |
| --- | --- |
| `PAPER`, `INK` | Window background; text, checked marks, caret, and scrollbar thumb |
| `SURFACE`, `BORDER` | Control/track background and outline |
| `HOVER` | Enabled Button/Checkbox hover background |
| `PRESSED`, `PRESSED_TEXT` | Pressed background and contrasting text/mark |
| `DISABLED`, `DISABLED_SURFACE` | Inherited disabled text/outline/mark and background |
| `FOCUS` | Keyboard focus ring, distinct from hover |
| `SELECTION`, `SELECTION_TEXT` | Focused TextField selection and its text |

The default font size is 14, with root padding 16, gap 8, and Button padding
12 horizontally and 8 vertically. TextFields use `control_padding_y` on all
sides; Checkboxes use half that padding and `gap` between the box and label.
Checkbox size, preferred TextField width, scrollbar width, and minimum thumb
length scale with font size. Explicit `Layout` sizing and container spacing
remain authoritative. `set_root_spacing()` pins an explicit root override,
including when called with the defaults.

Native backends use their system font families at the requested size. X11 asks
for a core fixed font at that pixel size and falls back to the server's `fixed`
font when the requested strike is unavailable; layout uses the actual metrics.
X11 allocates palette colors through the server colormap. Its font selection
follows the [X Logical Font Description conventions](https://www.x.org/releases/X11R7.7/doc/xorg-docs/xlfd/xlfd.pdf).
Custom `Renderer` callbacks receive an `Ink` role and resolve its RGB value with
`view.get_theme().colors[ink]`. Custom `set_measurer()` callbacks should read the
view's current `font_size` and use the same font as their drawing callbacks.
The headless fallback scales its deterministic metrics with the font size.

## TextField

```c3
Widget* query = view.text_field("initial query")
	.@on_text_change(&app, fn (a, text) { /* copy text to retain it */ });
```

`View.text_field()` and `Widget.text_field()` create an editor with owned UTF-8
storage. Initial strings and `set_text()` arguments are copied. `get_text()`
borrows the current string until the next change or removal. With the default
theme, text fields have a preferred width of 160 and text-height-plus-16 height; sizing constraints, root
stretch, and clipping work as for other controls. Typing keeps the preferred width
fixed, with horizontal scrolling to reveal the caret.

`View.text_input(String)` delivers committed text independently of
`key_down(identity, action, repeat, reverse)`. Physical keys navigate or delete;
they never infer printable characters. A commit replaces the selection and
collapses it after the inserted text. Invalid UTF-8, control characters, line
separators, empty commits, and edits exceeding 4096 bytes are rejected atomically.
`text_input()` returns whether a focused, enabled, visible field consumed the
commit. Input flushes pending state/layout before choosing its target.

`selection()` returns `{ anchor, caret }` in UTF-8 byte offsets. `select(anchor,
caret)` rejects offsets outside the string or inside a scalar's encoding.
Left/Right and Backspace/Delete operate on Unicode scalars; combining marks can
be selected/deleted individually. Unshifted arrows collapse a selection to its
corresponding edge, Shift extends from the anchor, Home/End move within the field,
and Ctrl-A (Command-A on macOS) selects all. Mouse clicks place the caret,
Shift-click extends from the anchor, and captured dragging extends selection,
including outside the control. Focused selection uses inverted text and a steady
caret. Tab reveals fields in scroll
containers; PageUp/PageDown retain the existing scroll behavior. Enter is consumed
without inserting a line or activating the field; Space arrives as committed text.

User content changes call `TextChangeHandler(void*, String)` or the typed
`@on_text_change(context, fn (c, text) { ... })` after updating the field. The
callback receives an independent, borrowed snapshot valid throughout the call,
including after reentrant `set_text()` or subtree removal. Copy it to retain it.
Equal-content edits, selection changes, and programmatic `set_text()` are silent.
A changed programmatic value moves the caret to its end. Fields always own their
values: label bindings (`bind()` / `@text`) are rejected for text fields. Mirror
application state explicitly in the change callback and programmatic setter.
Generic `State{String}` retains its existing application-owned slice semantics.

macOS uses AppKit text interpretation and committed `insertText` callbacks;
Windows consumes `WM_CHAR` UTF-16, including surrogate pairs and repeats. Wayland
uses xkbcommon UTF-8 and locale Compose/dead-key sequences. Native partial text
is discarded on focus changes. X11's core adapter resolves Shift, Latin-1
CapsLock, and Mod5's second group, then converts Latin-1/Unicode keysyms; XIM,
Compose, and legacy non-Latin keysyms are not supported there yet. Composition
preview is not drawn in this milestone, and Wayland text-input/IME protocols,
clipboard commands, undo, word/grapheme navigation, and bidirectional caret
layout remain future work.

Native input references: [AppKit text interpretation](https://developer.apple.com/documentation/appkit/nsresponder/interpretkeyevents(_:)),
[Windows character messages](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-char),
and [xkbcommon Compose](https://xkbcommon.org/doc/current/group__compose.html).

Run the complete [searchable-list example](examples/search):

```sh
c3c run --path examples/search
```

## Native backends

macOS uses AppKit windows and drawing through C3's Objective-C runtime bindings.
It links only system frameworks, with no bridge library or additional runtime
dependencies. Call `open_window()` or `View.open()` on the main thread. Dimensions
and input coordinates use logical points; AppKit supplies Retina rendering.
Mouse capture, nested wheel/trackpad and keyboard scrolling, Tab/Shift+Tab,
Enter/Space, and Command-W are supported on Apple Silicon and Intel.
When the backend launches a command-line application's AppKit session, it keeps
the regular activation policy for that session so reopened windows retain focus.

Linux chooses its backend at runtime. `auto` prefers Wayland when
`WAYLAND_DISPLAY`, `WAYLAND_SOCKET`, or `XDG_SESSION_TYPE=wayland` advertises it,
and tries the default Wayland socket when only `XDG_RUNTIME_DIR` is available.
If the connection, required protocols, or libraries are unavailable during
initialization, it falls back to X11. Errors after initialization are returned
to the caller. Set `UI_BACKEND=wayland` or `UI_BACKEND=x11` to force a backend;
`UI_BACKEND=auto` (or unset) restores automatic selection.

Wayland uses stable `xdg-shell`, shared-memory buffers, Cairo text rendering,
and xkbcommon keyboard maps. Install the runtime libraries `libwayland-client0`,
`libcairo2`, and `libxkbcommon0` (Debian/Ubuntu package names) for retained views.
They are loaded dynamically; X11 requires no additional linked libraries.
Pointer capture, wheel and keyboard scrolling, Tab/Shift+Tab, and Enter/Space
work on both backends.
Wayland requests server decorations where available; compositors requiring
client decorations currently show a borderless window, controlled through
their window-management shortcuts. Buffer scale is currently 1.
Tests cover presentation on outputs at scales 1 and 2 and the borderless
fallback when a compositor selects client decoration mode. Drawing at the
output's native resolution and client-side window controls remain unsupported.

## Testing

C3 0.8.4 and Python 3.12 or newer are required; Windows ARM64 uses Python 3.13
or newer. Keep this checkout named `ui.c3l` so the compiler can resolve the
library through the parent directory.

```sh
c3c test
c3c test -O3 --build-dir build/release --output-dir build/release
python3 -m unittest discover -s tests -p test_x11.py -v
python3 -m unittest discover -s tests -p test_wayland.py -v
python3 scripts/test-xvfb.py
python3 scripts/test-wayland.py
```

The Python suites exercise both Linux protocols, rendering, input, and backend
selection without using your desktop. The scripts use isolated Xvfb and headless
Weston instances for native checks.
Install `xvfb`, `xfonts-base`, `libx11-6`, and `libxtst6` for the desktop tests.
Install `weston`, the Wayland runtime libraries above, and `xkb-data` for Wayland tests.
On Windows, use `python scripts/test-windows.py`; it reports a skip if no input
desktop is available.

On macOS, `c3c test` also exercises AppKit text metrics, native view lifetime,
keyboard and pointer metadata, fractional trackpad scrolling, and bitmap drawing
with independent widget clips. These tests do not open desktop windows.
Run `python3 scripts/test-macos.py` in a graphical login session for automated
AppKit window checks: client resizing and relayout, focus loss, drag capture
outside the content view, pixels, input, closing, and reopening in one process.
The runner uses the system `clang` to build a test-only helper for each fixture.
It sends synthetic events through `NSWindow`, observes native focus notifications,
and reads view bitmaps; no Accessibility or screen-recording permission is needed.
Run `c3c run --path examples/window` for additional interactive checks.
Use `--target macos-x64 --linker=cc` to test Intel binaries under Rosetta on
Apple Silicon. The system linker supports newer Apple SDK formats than the
compiler's bundled cross-linker.

Set `UI_TEST_OPTIMIZATION=release` to compile the Python integration fixtures and
example with `-O3` (the default is `debug`, using `-O0`). CI runs both profiles on
native Linux and Windows x64 and ARM64 runners, plus a macOS Apple Silicon runner
testing ARM64 and Intel targets (the latter under Rosetta), with explicit compiler targets.
The macOS matrix also runs the automated AppKit desktop suite for both targets.
Each matrix job reports independently. C3 tests in `tests/*.c3` are discovered
automatically; window fixtures remain in `tests/fixtures/`.

The Linux and Windows x64 jobs use the pinned C3 setup action. Windows ARM64 uses the official
archive verified by SHA-256; Linux ARM64 builds the pinned C3 0.8.4 source with
LLVM/LLD 19 and caches the compiler. `scripts/install-c3.py --dest <new-directory>`
also supports these native installations locally, including macOS ARM64.

## License

[BSD 2-Clause](LICENSE) (SPDX: `BSD-2-Clause`).
