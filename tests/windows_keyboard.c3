module ui::backend @feat(WIN32);
import std::core::test;

fn void windows_scroll_keys_repeat_and_release() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.button("tall").set_layout({ .height = 240 });
	view.focus_next();
	win_key(&view, true, 34, 1, false);
	test::eq(panel.scroll_offset(), 50);
	win_key(&view, true, 34, 0x40000001, false);
	test::eq(panel.scroll_offset(), 100);
	win_key(&view, false, 34, (sz)0xc0000001, false);
	test::eq(view.held_keys[34], false);
	win_key(&view, true, 33, 1, false);
	test::eq(panel.scroll_offset(), 50);
	win_key(&view, true, 35, 1, false);
	test::eq(panel.scroll_offset(), 190);
	win_key(&view, true, 36, 1, false);
	test::eq(panel.scroll_offset(), 0);
}

fn void windows_keyboard_repeat_metadata_and_keyup() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* check = view.checkbox("check");
	Widget* next = view.checkbox("next");
	win_key(&view, true, 9, 1, false);
	win_key(&view, false, 9, (sz)0xc0000001, false);
	win_key(&view, true, 32, 3, false); // Initial message can have repeat count > 1.
	test::eq(check.is_checked(), true);
	win_key(&view, true, 32, 0x40000002, false);
	test::eq(check.is_checked(), true);
	win_key(&view, true, 9, 1, false);
	win_key(&view, true, 32, 0x40000001, false);
	test::eq(next.is_checked(), false);
	win_key(&view, false, 32, (sz)0xc0000001, false);
	win_key(&view, true, 32, 1, false);
	test::eq(next.is_checked(), true);
	view.blur();
	win_key(&view, true, 9, 1, false);
	win_key(&view, true, 13, 0x40000001, false);
	test::eq(check.is_checked(), true);
	win_key(&view, false, 13, (sz)0xc0000001, false);
	win_key(&view, true, 13, 1, false);
	test::eq(check.is_checked(), false);
	win_key(&view, true, 9, 0x40000001, true);
	test::eq(view.focused, next);
}
