module ui::backend @feat(WIN32);
import std::core::test;

fn void windows_scrollbar_pointer_capture_leave_cancel_and_outside_release() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* scroll = view.scroll_column({ .width = 200, .height = 100 });
	scroll.set_scrollbar();
	Widget* check = scroll.checkbox("check");
	scroll.text("content").set_layout({ .height = 400 });
	view.update();
	int x = scroll.scroll_thumb.x + 2;
	int y = scroll.scroll_thumb.y + 2;
	win_pointer(&view, 0x201, x, y);
	test::eq(view.scroll_pressed, scroll);
	win_pointer(&view, 0x200, x, y + 20);
	int offset = scroll.scroll_offset();
	test::eq(offset > 0, true);
	win_pointer(&view, 0x2a3);
	test::eq(scroll.scroll_offset(), offset);
	win_pointer(&view, 0x200, -100, 2000);
	test::eq(scroll.scroll_offset(), scroll.scroll_extent());
	win_pointer(&view, 0x202, -100, 2000);
	test::eq(view.scroll_press_active || view.scroll_dragging, false);
	foreach (int message : { 0x215, 0x1f })
	{
		scroll.scroll_to(0);
		view.update();
		win_pointer(&view, 0x201, x, y);
		win_pointer(&view, (uint)message);
		test::eq(view.scroll_pressed == null && !view.scroll_dragging, true);
		win_pointer(&view, 0x200, x, 2000);
		test::eq(scroll.scroll_offset(), 0);
		win_pointer(&view, 0x202, check.visible.x + 2, check.visible.y + 2);
		test::eq(check.is_checked(), false);
	}
}
