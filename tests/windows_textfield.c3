module ui::backend @feat(WIN32);
import std::core::test;

fn void windows_textfield_utf16_commits_repeat_and_surrogate_focus_lifetime() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field();
	Widget* next = view.text_field();
	view.focus_next();
	WinWindow window = { .view = &view };
	win_key(&view, true, 65, 1, false);
	test::eq(field.get_text(), ""); // WM_KEYDOWN is not text.
	win_char(&window, 'A');
	win_char(&window, 0xe9, 2);
	win_char(&window, 0xd83d);
	win_char(&window, 0xdc4b);
	test::eq(field.get_text(), "Aéé👋");
	win_char(&window, '\r');
	win_char(&window, '\t');
	win_char(&window, 1);
	test::eq(field.get_text(), "Aéé👋");
	win_char(&window, 0xd83d);
	view.focus_next();
	win_char(&window, 0xdc4b); // Never complete a surrogate in a different field.
	test::eq(next.get_text(), "");
	win_char(&window, 0xd83d);
	win_char(&window, 'x'); // Malformed pending pair is discarded.
	win_char(&window, 0xdc4b);
	test::eq(next.get_text(), "x");
	win_key(&view, true, 65, 1, false, true); // Ctrl-A.
	win_key(&view, true, 8, 1, false);
	test::eq(next.get_text(), "");
	win_char(&window, ' ');
	test::eq(next.get_text(), " ");
}
