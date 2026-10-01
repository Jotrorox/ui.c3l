# ui.c3l

A small reactive retained-mode UI library for Windows and Linux (X11/XWayland),
with text, buttons, checkboxes, nested rows and columns, and vertical scrollbars.
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
use the wheel; nested lists bubble wheel input at their ends. Tab reveals
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

## Testing

C3 0.8.4 and Python 3.12 or newer are required; Windows ARM64 uses Python 3.13
or newer. Keep this checkout named `ui.c3l` so the compiler can resolve the
library through the parent directory.

```sh
c3c test
c3c test -O3 --build-dir build/release --output-dir build/release
python3 -m unittest discover -s tests -p test_x11.py -v
python3 scripts/test-xvfb.py
```

The last two commands exercise the Linux X11 protocol and an isolated desktop.
Install `xvfb`, `xfonts-base`, `libx11-6`, and `libxtst6` for the desktop tests.
On Windows, use `python scripts/test-windows.py`; it reports a skip if no input
desktop is available.

Set `UI_TEST_OPTIMIZATION=release` to compile the Python integration fixtures and
example with `-O3` (the default is `debug`, using `-O0`). CI runs both profiles on
native Linux and Windows x64 and ARM64 runners, with explicit compiler targets.
Each matrix job reports independently. C3 tests in `tests/*.c3` are discovered
automatically; window fixtures remain in `tests/fixtures/`.

The x64 jobs use the pinned C3 setup action. Windows ARM64 uses the official
archive verified by SHA-256; Linux ARM64 builds the pinned C3 0.8.4 source with
LLVM/LLD 19 and caches the compiler. `scripts/install-c3.py --dest <new-directory>`
also supports these native installations locally.

## License

[BSD 2-Clause](LICENSE) (SPDX: `BSD-2-Clause`).
