# ui.c3l

A small reactive retained-mode UI library for Windows and Linux (X11/XWayland),
with text, buttons, checkboxes, and nested rows and columns. Requires C3 0.8.4 or newer.

```c3
view.set_root_alignment(CENTER, STRETCH);
view.@column({ .gap = 8, .cross_align = STRETCH }; Widget* counter)
{
	counter.@row({ .main_align = CENTER }; Widget* summary)
	{
		summary.text().@text(&app.count, "Count: %s");
	};
	counter.@row({ .main_align = END }; Widget* actions)
	{
		actions.button("Reset")
			.@on_click(&app.count, fn (c) => c.set(0))
			.@enabled(&app.count, fn (c) => c.get() != 0);
	};
};
```

Rows and columns support start, center, and end alignment, plus cross-axis
stretch for children with automatic sizes. The root above centers its content
vertically and stretches the counter across the viewport. See the
[layout contract](examples/window/README.md#layout-rules) for sizing and clipping.

Run the [counter example](examples/window):

```sh
c3c run --path examples/window
```

## License

[BSD 2-Clause](LICENSE) (SPDX: `BSD-2-Clause`).
