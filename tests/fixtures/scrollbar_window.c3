module scrollbar_window_test;
import ui, std::io, std::os::env;

struct Scenario
{
	View view;
	State{bool} expanded;
	Widget* inspector;
	Widget* resetter;
	Widget* toggle;
	Widget* outer;
	Widget* inner;
	Widget* first;
	Widget* last;
	int clicks;
	int generation;
}
fn bool expanded(void* context) { Scenario* state = context; return state.expanded.get(); }
fn String rect_json(Rect rect) => string::tformat("[%s,%s,%s,%s]", rect.x, rect.y, rect.width, rect.height);
fn void report(Scenario* state, String source) => @pool()
{
	state.view.update();
	io::printfn("{\"source\":\"%s\",\"generation\":%s,\"clicks\":%s,\"expanded\":%s,\"outer_offset\":%s,\"inner_offset\":%s,\"outer_extent\":%s,\"inner_extent\":%s,\"dragging\":%s,\"scroll_press\":%s,\"inspect\":%s,\"reset\":%s,\"toggle\":%s,\"outer\":%s,\"inner\":%s,\"outer_track\":%s,\"outer_thumb\":%s,\"inner_track\":%s,\"inner_thumb\":%s,\"first\":%s,\"last\":%s}",
		source, state.generation, state.clicks, state.expanded.get(),
		state.outer.scroll_offset(), state.inner.scroll_offset(),
		state.outer.scroll_extent(), state.inner.scroll_extent(),
		state.view.scroll_dragging, state.view.scroll_press_active,
		rect_json(state.inspector.visible), rect_json(state.resetter.visible), rect_json(state.toggle.visible),
		rect_json(state.outer.visible), rect_json(state.inner.visible),
		rect_json(state.outer.scroll_track), rect_json(state.outer.scroll_thumb),
		rect_json(state.inner.scroll_track), rect_json(state.inner.scroll_thumb),
		rect_json(state.first.visible), rect_json(state.last.visible));
}
fn void inspect(void* context) => report(context, "inspect");
fn void reset(void* context)
{
	Scenario* state = context;
	state.expanded.set(true);
	state.inner.scroll_to(0);
	state.outer.scroll_to(0);
	report(state, "reset");
}
fn void toggle(void* context)
{
	Scenario* state = context;
	state.expanded.set(!state.expanded.get());
	report(state, "toggle");
}
fn void clicked(void* context) { Scenario* state = context; state.clicks++; }
fn int main() => @pool()
{
	Scenario state;
	state.expanded.value = true;
	defer state.view.free();
	Widget* controls = state.view.row({ .gap = 8 });
	state.inspector = controls.button("Inspect", &inspect, &state);
	state.resetter = controls.button("Reset", &reset, &state);
	state.toggle = controls.button("Toggle", &toggle, &state);
	for (Widget* child = controls.first; child; child = child.next) child.set_layout({ .width = 90, .height = 32 });
	state.outer = state.view.scroll_column({ .width = 360, .height = 180, .padding = 8, .gap = 8 });
	state.outer.set_scrollbar();
	state.inner = state.outer.scroll_column({ .width = 300, .height = 100, .padding = 6, .gap = 4 });
	state.inner.set_scrollbar();
	state.first = state.inner.button("First", &clicked, &state);
	state.first.set_layout({ .width = 400, .height = 32 });
	Widget* filler = state.inner.text("Inner filler");
	filler.set_layout({ .height = 160 });
	filler.bind_visible(&expanded, &state);
	state.last = state.inner.button("Last", &clicked, &state);
	state.last.set_layout({ .width = 400, .height = 32 });
	state.outer.text("Outer filler").set_layout({ .height = 180 });
	int windows = (env::tget_var("UI_TEST_REOPEN") ?? "") == "1" ? 2 : 1;
	for (int index = 0; index < windows; index++)
	{
		state.generation = index;
		if (catch error = state.view.open(string::tformat("ui scrollbar test %s", index)))
		{
			io::eprintfn("Could not open scrollbar fixture: %s", error);
			return 1;
		}
		report(&state, "closed");
	}
	return 0;
}
