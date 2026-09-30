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

	if (catch error = view.open("Native C3 window"))
	{
		io::eprintfn("Could not open window: %s", error);
		return 1;
	}
	return 0;
}
