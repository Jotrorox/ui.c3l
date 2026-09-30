module ui::backend @feat(LINUX);
import std::core::test;

fn void xscrollbar_event(XCanvas* canvas, View* view, uint type, int x = 0, int y = 0,
	uint mode = 0, uint window = 77) @private
{
	char[32] event;
	event[0] = (char)type;
	event[1] = 1;
	write32(event[..], type == 18 ? 8 : (type == 10 ? 4 : 12), window);
	write16(event[..], 24, (uint)x);
	write16(event[..], 26, (uint)y);
	event[30] = (char)mode;
	canvas.event(view, event[..])!!;
}

fn void x11_scrollbar_capture_preserves_outside_motion_and_release_identity() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* scroll = view.scroll_column({ .width = 200, .height = 100 });
	scroll.set_scrollbar();
	Widget* check = scroll.checkbox("check");
	scroll.text("content").set_layout({ .height = 400 });
	view.update();
	XCanvas canvas = { .setup.window = 77 };
	int x = scroll.scroll_thumb.x + 2;
	int y = scroll.scroll_thumb.y + 2;
	xscrollbar_event(&canvas, &view, 4, x, y);
	test::eq(view.scroll_pressed, scroll);
	test::eq(view.scroll_dragging, true);
	xscrollbar_event(&canvas, &view, 6, x, y + 20);
	int offset = scroll.scroll_offset();
	test::eq(offset > 0, true);
	xscrollbar_event(&canvas, &view, 8, -1, -1); // Leave cannot synthesize a drag to zero.
	xscrollbar_event(&canvas, &view, 7, -1, -1, 1); // Nor a NotifyGrab crossing.
	test::eq(scroll.scroll_offset(), offset);
	xscrollbar_event(&canvas, &view, 6, -100, 2000, 0, 78);
	test::eq(scroll.scroll_offset(), offset);
	xscrollbar_event(&canvas, &view, 6, -100, 2000);
	test::eq(scroll.scroll_offset(), scroll.scroll_extent());
	xscrollbar_event(&canvas, &view, 5, -100, 2000);
	test::eq(view.scroll_press_active || view.scroll_dragging, false);
	test::eq(check.is_checked(), false);
	view.pointer_move(x, y);
	test::eq(scroll.scroll_offset(), scroll.scroll_extent());
}

fn void x11_scrollbar_ungrab_blur_and_unmap_cancel_without_retargeting() @test
{
	foreach (int type : { 7, 8, 10, 18 })
	{
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* scroll = view.scroll_column({ .width = 200, .height = 100 });
		scroll.set_scrollbar();
		Widget* check = scroll.checkbox("check");
		scroll.text("content").set_layout({ .height = 400 });
		view.update();
		XCanvas canvas = { .setup.window = 77 };
		int x = scroll.scroll_thumb.x + 2;
		int y = scroll.scroll_thumb.y + 2;
		xscrollbar_event(&canvas, &view, 4, x, y);
		xscrollbar_event(&canvas, &view, (uint)type, 0, 0, 2, 78);
		test::eq(view.scroll_dragging, true); // Other windows cannot cancel this drag.
		xscrollbar_event(&canvas, &view, (uint)type, 0, 0, 2);
		test::eq(view.scroll_pressed == null && !view.scroll_dragging, true);
		xscrollbar_event(&canvas, &view, 6, x, 2000);
		test::eq(scroll.scroll_offset(), 0);
		xscrollbar_event(&canvas, &view, 5, check.visible.x + 2, check.visible.y + 2);
		test::eq(check.is_checked(), false);
		test::eq(view.scroll_press_active, false);
	}
}
