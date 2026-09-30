# ui.c3l

A small reactive retained-mode UI library for Windows and Linux (X11/XWayland),
with text, buttons, checkboxes, nested rows and columns, and vertical scrollbars.
Requires C3 0.8.4 or newer.

```c3
view.set_root_alignment(START, STRETCH);
view.@scroll_column({ .height = 240, .padding = 8, .gap = 8, .cross_align = STRETCH }; Widget* list)
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
automatic sizes.
The implicit root keeps its existing non-scrolling behavior. See the
[scrolling contract](examples/window/README.md#vertical-scrolling) for sizing,
clipping, input, and clamping rules.

Run the [nested scrollbar example](examples/window), including reactive content
changes and Top/Bottom controls:

```sh
c3c run --path examples/window
```

## License

[BSD 2-Clause](LICENSE) (SPDX: `BSD-2-Clause`).
