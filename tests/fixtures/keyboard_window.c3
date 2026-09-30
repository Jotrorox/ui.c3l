module keyboard_window_test;
import ui, std::io, std::os::env;

struct Scenario
{
	View view;
	State{bool} checked;
	Widget* inspector;
	Widget* button;
	Widget* check;
	int clicks;
	int changes;
	int generation;
}
fn bool value(void* context)
{
	Scenario* state = context;
	return state.checked.get();
}
fn String rect_json(Rect rect) => string::tformat("[%s,%s,%s,%s]", rect.x, rect.y, rect.width, rect.height);
fn void inspect(void* context) => @pool()
{
	Scenario* state = context;
	state.view.update();
	io::printfn("{\"generation\":%s,\"clicks\":%s,\"changes\":%s,\"checked\":%s,\"inspect\":%s,\"button\":%s,\"check\":%s}",
		state.generation, state.clicks, state.changes, state.checked.get(),
		rect_json(state.inspector.visible), rect_json(state.button.visible), rect_json(state.check.visible));
}
fn void clicked(void* context) { Scenario* state = context; state.clicks++; }
fn void changed(void* context, bool checked)
{
	Scenario* state = context;
	state.changes++;
	state.checked.set(checked);
}
fn int main() => @pool()
{
	Scenario state;
	defer state.view.free();
	state.inspector = state.view.button("Inspect", &inspect, &state);
	state.button = state.view.button("Button", &clicked, &state);
	state.check = state.view.checkbox("Check", on_change: &changed, context: &state);
	state.check.bind_checked(&value, &state);
	int windows = (env::tget_var("UI_TEST_REOPEN") ?? "") == "1" ? 2 : 1;
	for (int index = 0; index < windows; index++)
	{
		state.generation = index;
		if (catch error = state.view.open(string::tformat("ui keyboard test %s", index)))
		{
			io::eprintfn("Could not open keyboard fixture: %s", error);
			return 1;
		}
	}
	return 0;
}
