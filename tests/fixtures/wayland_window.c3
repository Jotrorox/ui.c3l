module wayland_window_test;
import ui, std::io;

struct App { View* view; Widget* button; Widget* toggle; Widget* list; int clicks; int changes; }
fn void snapshot(App* app)
{
	io::printfn("{\"clicks\":%s,\"changes\":%s,\"checked\":%s,\"offset\":%s,\"width\":%s,\"height\":%s}",
		app.clicks, app.changes, app.toggle.checked, app.list.scroll_offset(), app.view.width, app.view.height);
}
fn void click(void* context) { App* app = context; app.clicks++; snapshot(app); }
fn void change(void* context, bool checked) { App* app = context; app.changes++; snapshot(app); }

fn int main()
{
	View view;
	defer view.free();
	App app = { .view = &view };
	app.button = view.button("Hello 世界", on_click: &click, context: &app);
	app.toggle = view.checkbox("Check", on_change: &change, context: &app);
	app.list = view.scroll_column({ .width = 220, .height = 90, .cross_align = STRETCH });
	app.list.set_scrollbar();
	for (int i = 0; i < 12; i++) app.list.text("Scrollable content");
	if (catch error = view.open("Wayland C3 — 世界", 321, 234))
	{
		io::eprintfn("Could not open window: %s", error);
		return 1;
	}
	snapshot(&app);
	return 0;
}
