module scroll_window_test;
import ui, std::io;

struct Scenario
{
	View view;
	Widget* inspector;
	Widget* resetter;
	Widget* outer;
	Widget* inner;
	Widget* first;
	Widget* last;
	Widget* tail;
	int first_clicks;
	int last_clicks;
	int tail_clicks;
}

fn String rect_json(Rect rect) => string::tformat("[%s,%s,%s,%s]", rect.x, rect.y, rect.width, rect.height);
fn void report(Scenario* state, String source) => @pool()
{
	state.view.update();
	io::printfn("{\"source\":\"%s\",\"first_clicks\":%s,\"last_clicks\":%s,\"tail_clicks\":%s,\"outer_offset\":%s,\"inner_offset\":%s,\"outer_extent\":%s,\"inner_extent\":%s,\"focused_last\":%s,\"focused_tail\":%s,\"inspect\":%s,\"reset\":%s,\"outer\":%s,\"inner\":%s,\"first\":%s,\"last\":%s,\"tail\":%s}",
		source, state.first_clicks, state.last_clicks, state.tail_clicks,
		state.outer.scroll_offset(), state.inner.scroll_offset(),
		state.outer.scroll_extent(), state.inner.scroll_extent(),
		state.view.focused == state.last, state.view.focused == state.tail,
		rect_json(state.inspector.visible), rect_json(state.resetter.visible),
		rect_json(state.outer.visible), rect_json(state.inner.visible),
		rect_json(state.first.visible), rect_json(state.last.visible), rect_json(state.tail.visible));
}
fn void inspect(void* context) => report(context, "inspect");
fn void reset(void* context)
{
	Scenario* state = context;
	state.inner.scroll_to(0);
	state.outer.scroll_to(0);
	report(state, "reset");
}
fn void first_clicked(void* context)
{
	Scenario* state = context;
	state.first_clicks++;
	report(state, "first");
}
fn void last_clicked(void* context)
{
	Scenario* state = context;
	state.last_clicks++;
	report(state, "last");
}
fn void tail_clicked(void* context)
{
	Scenario* state = context;
	state.tail_clicks++;
	report(state, "tail");
}
fn int main()
{
	Scenario state;
	defer state.view.free();
	Widget* controls = state.view.row({ .gap = 8 });
	state.inspector = controls.button("Inspect", &inspect, &state);
	state.resetter = controls.button("Reset scroll", &reset, &state);
	state.outer = state.view.scroll_column({ .width = 360, .height = 180, .padding = 8, .gap = 8 });
	state.inner = state.outer.scroll_column({ .width = 300, .height = 100, .padding = 6, .gap = 4 });
	state.first = state.inner.button("First", &first_clicked, &state);
	state.first.set_layout({ .width = 200, .height = 32 });
	state.inner.text("Inner filler").set_layout({ .height = 160 });
	state.last = state.inner.button("Last", &last_clicked, &state);
	state.last.set_layout({ .width = 200, .height = 32 });
	state.outer.text("Outer filler").set_layout({ .height = 180 });
	state.tail = state.outer.button("Tail", &tail_clicked, &state);
	state.tail.set_layout({ .width = 200, .height = 32 });
	if (catch error = state.view.open("ui scroll test"))
	{
		io::eprintfn("Could not open scroll fixture: %s", error);
		return 1;
	}
	return 0;
}
