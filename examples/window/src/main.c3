module window;

import ui, std::io;

struct Counter
{
	State{int} count;
	State{bool} shown;
}

fn int main()
{
	Counter app = { .count.value = 5, .shown.value = true };
	View view;
	defer view.free();

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

	if (catch error = view.open("Native C3 window"))
	{
		io::eprintfn("Could not open window: %s", error);
		return 1;
	}
	return 0;
}
