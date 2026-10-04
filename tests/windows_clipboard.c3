module ui::backend @feat(WIN32);
import std::core::test;

struct WinClipboardProbe { String text; ClipboardRequest request; int writes; int reads; }
fn bool win_probe_copy(void* context, String text) @private
{
	WinClipboardProbe* probe = context;
	probe.text.free(mem);
	probe.text = text.copy(mem);
	probe.writes++;
	return true;
}
fn void win_probe_paste(void* context, ClipboardRequest request) @private
{
	WinClipboardProbe* probe = context;
	probe.request = request;
	probe.reads++;
}

fn void windows_clipboard_shortcuts_require_control_and_suppress_repeat_and_characters() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("é👋");
	view.focus_next();
	field.select(6, 0);
	WinClipboardProbe probe;
	defer probe.text.free(mem);
	view.set_clipboard(&win_probe_copy, &win_probe_paste, &probe);
	WinWindow window = { .view = &view };
	win_key(&view, true, 67, 1, false, true, true); // Ctrl-Alt is not copy.
	win_key(&view, false, 67, 1, false);
	test::eq(probe.writes, 0);
	win_key(&view, true, 67, 1, false, true);
	win_key(&view, true, 67, 1 << 30, false, true);
	win_key(&view, false, 67, 1, false);
	win_char(&window, 3); // TranslateMessage's Ctrl-C character cannot insert.
	test::eq(probe.writes, 1);
	test::eq(probe.text, "é👋");
	test::eq(field.get_text(), "é👋");
	win_key(&view, true, 88, 1, false, true);
	win_key(&view, false, 88, 1, false);
	test::eq(field.get_text(), "");
	win_key(&view, true, 86, 1, false, true);
	win_key(&view, true, 86, 1 << 30, false, true);
	win_char(&window, 22);
	test::eq(probe.reads, 1);
	test::eq(view.paste_text(probe.text, probe.request), true);
	test::eq(field.get_text(), "é👋");
}
