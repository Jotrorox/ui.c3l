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

fn bool counter_visible(void* context)
{
	State{bool}* shown = context;
	return shown.get();
}

fn void show_counter(void* context, bool checked)
{
	State{bool}* shown = context;
	shown.set(checked);
}

fn bool can_reset(void* context)
{
	State{int}* count = context;
	return count.get() != 0;
}

fn int main()
{
	State{int} count = { .value = 5 };
	State{bool} shown = { .value = true };
	View view;
	defer view.free();
	Widget* toggle = view.checkbox("Show counter", on_change: &show_counter, context: &shown);
	toggle.bind_checked(&counter_visible, &shown);
	Widget* counter = view.column({ .gap = 8, .max_width = 360 });
	counter.bind_visible(&counter_visible, &shown);
	Widget* label = counter.text();
	label.bind(&count_label, &count);
	Widget* actions = counter.row({ .gap = 8 });
	actions.button("Increment", &increment, &count);
	Widget* reset_button = actions.button("Reset", &reset, &count);
	reset_button.bind_enabled(&can_reset, &count);
	if (catch error = view.open("Native C3 window"))
	{
		io::eprintfn("Could not open window: %s", error);
		return 1;
	}
	return 0;
}
