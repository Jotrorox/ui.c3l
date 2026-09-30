module window;

import ui, std::io;

struct Counter
{
	State{int} count;
	State{bool} extra;
	Widget* list;
}

fn int main()
{
	Counter app = { .extra.value = true };
	View view;
	defer view.free();

	view.set_root_alignment(START, STRETCH);
	view.text("Wheel over a list; Tab reveals its offscreen controls.");
	view.text().@text(&app.count, "Count: %s");
	view.@row({ .gap = 8 }; Widget* controls)
	{
		controls.checkbox("Show extra rows").@checked(&app.extra);
		controls.button("Top").@on_click(&app, fn (c) { c.list.scroll_to(0); });
		controls.button("Bottom").@on_click(&app, fn (c) { c.list.scroll_to(c.list.scroll_extent()); });
		controls.button("Reset")
			.@on_click(&app.count, fn (c) => c.set(0))
			.@enabled(&app.count, fn (c) => c.get() != 0);
	};
	view.@scroll_column({ .height = 360, .padding = 8, .gap = 8, .cross_align = STRETCH }; Widget* list)
	{
		app.list = list;
		@pool()
		{
			for (int i = 1; i <= 3; i++)
			{
				list.button(string::tformat("Outer item %s (+1)", i))
					.@on_click(&app.count, fn (c) => c.set(c.get() + 1));
			}
		};
		list.text("Nested list: its wheel bubbles at either end.");
		list.@scroll_column({ .height = 128, .padding = 8, .gap = 4, .cross_align = STRETCH }; Widget* nested)
		{
			@pool()
			{
				for (int i = 1; i <= 8; i++)
				{
					nested.button(string::tformat("Nested item %s (+10)", i))
						.@on_click(&app.count, fn (c) => c.set(c.get() + 10));
				}
			};
		};
		list.@column({ .gap = 8, .cross_align = STRETCH }; Widget* extra)
		{
			extra.@visible(&app.extra);
			@pool()
			{
				for (int i = 1; i <= 8; i++)
				{
					extra.button(string::tformat("Extra item %s (+1)", i))
						.@on_click(&app.count, fn (c) => c.set(c.get() + 1));
				}
			};
		};
		list.button("Last item (+1)").@on_click(&app.count, fn (c) => c.set(c.get() + 1));
	};

	if (catch error = view.open("Native C3 scrolling", width: 640, height: 520))
	{
		io::eprintfn("Could not open window: %s", error);
		return 1;
	}
	return 0;
}
