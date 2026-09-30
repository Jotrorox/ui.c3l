module window;

import ui, std::io;

fn String count_label(void* context)
{
	State{int}* count = context;
	return string::tformat("Count: %s", count.get());
}

fn void increment(void* context)
{
	State{int}* count = context;
	count.set(count.get() + 1);
}

fn void reset(void* context)
{
	State{int}* count = context;
	count.set(0);
}

fn int main()
{
	State{int} count = { .value = 5 };
	View view;
	defer view.free();
	Widget* counter = view.column({ .gap = 8, .max_width = 360 });
	Widget* label = counter.text();
	label.bind(&count_label, &count);
	Widget* actions = counter.row({ .gap = 8 });
	actions.button("Increment", &increment, &count);
	actions.button("Reset", &reset, &count);
	if (catch error = view.open("Native C3 window"))
	{
		io::eprintfn("Could not open window: %s", error);
		return 1;
	}
	return 0;
}
