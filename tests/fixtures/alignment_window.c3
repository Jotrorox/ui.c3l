module alignment_window_test;
import ui, std::io;

struct Scenario
{
	View view;
	State{int} count;
	Widget* inspector;
	Widget* aligner;
	Widget* panel;
	Widget* summary;
	Widget* label;
	Widget* actions;
	Widget* action;
	bool aligned_start;
}

fn String label(void* context)
{
	Scenario* state = context;
	int count = state.count.get();
	return count ? string::tformat("Value has grown after %s activations", count) : "Value: 0";
}

fn String rect_json(Rect rect) => string::tformat("[%s,%s,%s,%s]", rect.x, rect.y, rect.width, rect.height);

fn void report(void* context, String source) => @pool()
{
	Scenario* state = context;
	state.view.update();
	io::printfn("{\"source\":\"%s\",\"count\":%s,\"aligned_start\":%s,\"focused_action\":%s,\"label\":\"%s\",\"viewport\":[%s,%s],\"inspect\":%s,\"align\":%s,\"panel\":%s,\"summary\":%s,\"text\":%s,\"actions\":%s,\"action\":%s}",
		source, state.count.get(), state.aligned_start, state.view.focused == state.action,
		state.label.get_text(), state.view.width, state.view.height,
		rect_json(state.inspector.visible), rect_json(state.aligner.visible), rect_json(state.panel.visible),
		rect_json(state.summary.visible), rect_json(state.label.visible), rect_json(state.actions.visible),
		rect_json(state.action.visible));
}

fn void inspect(void* context) => report(context, "inspect");

fn void increment(void* context)
{
	Scenario* state = context;
	state.count.set(state.count.get() + 1);
	report(context, "action");
}

fn void align_start(void* context)
{
	Scenario* state = context;
	Layout layout = state.actions.layout;
	layout.main_align = START;
	bool valid = state.actions.set_layout(layout);
	assert(valid);
	state.aligned_start = true;
	report(context, "align");
}

fn int main()
{
	Scenario state;
	defer state.view.free();
	state.view.set_root_alignment(CENTER, STRETCH);
	Widget* controls = state.view.row({ .gap = 8 });
	state.inspector = controls.button("Inspect", &inspect, &state);
	state.aligner = controls.button("Align start", &align_start, &state);
	state.panel = state.view.column({ .padding = 7, .gap = 9, .cross_align = STRETCH });
	state.summary = state.panel.row({ .main_align = CENTER });
	state.label = state.summary.text();
	state.label.bind(&label, &state);
	state.actions = state.panel.row({ .main_align = END });
	state.action = state.actions.button("Increment", &increment, &state);
	if (catch error = state.view.open("ui alignment test", width: 480, height: 260))
	{
		io::eprintfn("Could not open test window: %s", error);
		return 1;
	}
	return 0;
}
