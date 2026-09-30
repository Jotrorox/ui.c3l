module nested_window_test;
import ui, std::io;

struct Scenario
{
	View view;
	State{int} count;
	Widget* inspect;
	Widget* branch;
	Widget* action;
	Widget* label;
	Widget* hidden;
	Widget* remover;
	int hidden_clicks;
}

fn String label(void* context)
{
	Scenario* state = context;
	return string::tformat("Count: %s", state.count.get());
}

fn void increment(void* context)
{
	Scenario* state = context;
	state.count.set(state.count.get() + 1);
	inspect(context); // Acknowledge input while the descendant still has focus.
}

fn void hidden_click(void* context)
{
	Scenario* state = context;
	state.hidden_clicks++;
}

fn void remove_branch(void* context)
{
	Scenario* state = context;
	if (!state.branch) return;
	state.count.set(state.count.get() + 1); // Queue a descendant before disposal.
	state.branch.remove();
	state.branch = null;
	state.action = null;
	state.label = null;
}

fn String rect_json(Rect rect) => string::tformat("[%s,%s,%s,%s]", rect.x, rect.y, rect.width, rect.height);

fn void inspect(void* context) => @pool()
{
	Scenario* state = context;
	state.view.update();
	io::printfn("{\"count\":%s,\"hidden_clicks\":%s,\"alive\":%s,\"subscribed\":%s,\"pending\":%s,\"label\":\"%s\",\"viewport\":[%s,%s],\"inspect\":%s,\"action\":%s,\"action_bounds\":%s,\"hidden\":%s,\"remove\":%s}",
		state.count.get(), state.hidden_clicks, state.branch != null,
		state.count.signal.subscribers != null, state.view.pending_head != null,
		state.label ? state.label.get_text() : "", state.view.width, state.view.height,
		rect_json(state.inspect.visible), rect_json(state.action ? state.action.visible : (Rect){}),
		rect_json(state.action ? state.action.bounds : (Rect){}), rect_json(state.hidden.bounds), rect_json(state.remover.visible));
}

fn int main()
{
	Scenario state;
	defer state.view.free();
	Widget* panel = state.view.column({ .width = 260, .height = 170, .padding = 6, .gap = 8 });
	Widget* row = panel.row({ .gap = 10 });
	state.inspect = row.button("Inspect", &inspect, &state);
	state.branch = row.column({ .gap = 4 });
	state.action = state.branch.button("Increment", &increment, &state);
	state.label = state.branch.text();
	state.label.bind(&label, &state);
	Widget* clipped = panel.column({ .width = 1, .height = 1 });
	Widget* overflow = clipped.row({ .height = 32, .padding = 2 });
	state.hidden = overflow.button("Hidden", &hidden_click, &state);
	state.remover = panel.button("Remove subtree", &remove_branch, &state);
	if (catch error = state.view.open("ui nested test", width: 400, height: 300))
	{
		io::eprintfn("Could not open test window: %s", error);
		return 1;
	}
	return 0;
}
