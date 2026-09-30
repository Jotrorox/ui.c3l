# ui.c3l

A small reactive retained-mode UI library for Windows and Linux (X11/XWayland),
with text, buttons, checkboxes, and nested rows and columns. Requires C3 0.8.4 or newer.

```c3
view.checkbox("Show counter").@checked(&app.shown);
view.@column({ .gap = 8 }; Widget* counter)
{
	counter.@visible(&app.shown);
	counter.text().@text(&app.count, "Count: %s");
	counter.button("Reset")
		.@on_click(&app.count, fn (c) => c.set(0))
		.@enabled(&app.count, fn (c) => c.get() != 0);
};
```

Run the [counter example](examples/window):

```sh
c3c run --path examples/window
```

## License

[BSD 2-Clause](LICENSE) (SPDX: `BSD-2-Clause`).
