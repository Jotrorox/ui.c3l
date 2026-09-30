module checkbox_window_test;
import ui, std::io;

struct Scenario
{
	View view;
	State{bool} shown;
	State{bool} enabled;
	State{bool} checked;
	State{int} count;
	Widget* inspector;
	Widget* show;
	Widget* enable;
	Widget* mutate;
	Widget* branch;
	Widget* bound;
	Widget* owned;
	Widget* remover;
	Widget* clipped;
	Widget* footer;
	int changes;
	int own_changes;
	int clipped_changes;
}
fn bool value(void* context)
{
	State{bool}* state = context;
	return state.get();
}
fn String label(void* context)
{
	Scenario* state = context;
	return string::tformat("Value: %s", state.count.get());
}
fn String rect_json(Rect rect) => string::tformat("[%s,%s,%s,%s]", rect.x, rect.y, rect.width, rect.height);
fn Rect geometry(Widget* widget) => widget ? widget.visible : (Rect){};

fn void inspect(void* context) => @pool()
{
	Scenario* state = context;
	state.view.update();
	io::printfn("{\"shown\":%s,\"enabled\":%s,\"checked\":%s,\"owned_checked\":%s,\"changes\":%s,\"own_changes\":%s,\"clipped_changes\":%s,\"count\":%s,\"label\":\"%s\",\"alive\":%s,\"pending\":%s,\"inspect\":%s,\"show\":%s,\"enable\":%s,\"mutate\":%s,\"bound\":%s,\"owned\":%s,\"remove\":%s,\"clipped\":%s,\"clipped_bounds\":%s,\"footer\":%s}",
		state.shown.get(), state.enabled.get(), state.bound ? state.bound.is_checked() : false,
		state.owned ? state.owned.is_checked() : false, state.changes, state.own_changes, state.clipped_changes,
		state.count.get(), state.bound ? state.bound.get_text() : "", state.branch != null,
		state.view.pending_head != null, rect_json(state.inspector.visible), rect_json(state.show.visible),
		rect_json(state.enable.visible), rect_json(state.mutate.visible), rect_json(geometry(state.bound)),
		rect_json(geometry(state.owned)), rect_json(geometry(state.remover)), rect_json(geometry(state.clipped)),
		rect_json(state.clipped ? state.clipped.bounds : (Rect){}), rect_json(state.footer.visible));
}
fn void show_changed(void* context, bool checked)
{
	Scenario* state = context;
	state.shown.set(checked);
	inspect(context);
}
fn void enable_changed(void* context, bool checked)
{
	Scenario* state = context;
	state.enabled.set(checked);
	inspect(context);
}
fn void bound_changed(void* context, bool checked)
{
	Scenario* state = context;
	state.changes++;
	state.checked.set(checked);
	inspect(context);
}
fn void owned_changed(void* context, bool checked)
{
	Scenario* state = context;
	state.own_changes++;
	inspect(context);
}
fn void clipped_changed(void* context, bool checked)
{
	Scenario* state = context;
	state.clipped_changes++;
}
fn void mutate(void* context)
{
	Scenario* state = context;
	state.count.set(state.count.get() + 1);
	state.checked.set(!state.checked.get());
	inspect(context);
}
fn void remove_branch(void* context, bool checked)
{
	Scenario* state = context;
	// Queue several properties on descendants, then remove their ancestor.
	state.count.set(state.count.get() + 1);
	state.checked.set(!state.checked.get());
	state.enabled.set(false);
	state.shown.set(false);
	state.branch.remove();
	state.branch = null;
	state.bound = null;
	state.owned = null;
	state.remover = null;
	state.clipped = null;
	inspect(context);
}

fn int main()
{
	Scenario state = { .shown.value = true, .enabled.value = true };
	defer state.view.free();
	state.inspector = state.view.button("Inspect", &inspect, &state);
	Widget* controls = state.view.row({ .gap = 8 });
	state.show = controls.checkbox("Show", on_change: &show_changed, context: &state);
	state.show.bind_checked(&value, &state.shown);
	state.enable = controls.checkbox("Enable", on_change: &enable_changed, context: &state);
	state.enable.bind_checked(&value, &state.enabled);
	state.mutate = controls.button("Change state", &mutate, &state);
	state.branch = state.view.column({ .padding = 6, .gap = 7 });
	state.branch.bind_visible(&value, &state.shown);
	state.branch.bind_enabled(&value, &state.enabled);
	Widget* row = state.branch.row({ .gap = 8 });
	state.bound = row.checkbox("", on_change: &bound_changed, context: &state);
	state.bound.bind(&label, &state);
	state.bound.bind_checked(&value, &state.checked);
	state.bound.bind_enabled(&value, &state.enabled);
	state.bound.bind_visible(&value, &state.shown);
	state.owned = row.checkbox("Owned", on_change: &owned_changed, context: &state);
	state.remover = state.branch.checkbox("Remove subtree", on_change: &remove_branch, context: &state);
	Widget* clip = state.branch.column({ .width = 1, .height = 1, .padding = 1 });
	state.clipped = clip.checkbox("Clipped", on_change: &clipped_changed, context: &state);
	state.footer = state.view.text("Footer");
	if (catch error = state.view.open("ui checkbox test", width: 500, height: 360))
	{
		io::eprintfn("Could not open test window: %s", error);
		return 1;
	}
	return 0;
}
