module ui;
import std::core::test;

fn void scrollbar_zero_wheel_does_not_replay_drag_motion() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.set_scrollbar();
	panel.column({ .height = 125 });
	view.pointer_down(90, 10);
	test::eq(view.scroll_dragging, true);
	// Wheel coordinates locate the event; they are not a captured motion event.
	// Replaying this Y through the drag formula would move the offset to 25.
	test::eq(view.scroll_wheel(90, 20, 0), false);
	test::eq(panel.scroll_offset(), 0);
	test::eq(view.scroll_dragging, true);
	view.pointer_move(90, 20);
	test::eq(panel.scroll_offset(), 25);
	view.pointer_up(90, 20);
}

fn void scrollbar_wheel_coordinates_preserve_nested_consumer_and_boundary_bubbling() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* outer = view.scroll_column({ .width = 100, .height = 100 });
	outer.set_scrollbar();
	Widget* inner = outer.scroll_column({ .width = 88, .height = 50 });
	inner.set_scrollbar();
	inner.column({ .height = 125 });
	outer.column({ .height = 100 });
	view.pointer_down(80, 10);
	test::eq(view.scroll_pressed, inner);
	// A motion to Y=49 would first drag to the end and wrongly bubble the wheel.
	test::eq(view.scroll_wheel(80, 49, 10), true);
	test::eq(inner.scroll_offset(), 10);
	test::eq(outer.scroll_offset(), 0);
	test::eq(view.scroll_dragging, false);
	test::eq(view.scroll_press_active, true);
	view.pointer_up(80, 49);

	inner.scroll_to(75);
	view.pointer_down(80, 35);
	test::eq(view.scroll_pressed, inner);
	// A motion to Y=0 would incorrectly pull the inner list off its boundary.
	test::eq(view.scroll_wheel(80, 0, 10), true);
	test::eq(inner.scroll_offset(), 75);
	test::eq(outer.scroll_offset(), 10);
	test::eq(view.scroll_dragging, false);
	view.pointer_up(80, 0);

	inner.scroll_to(0);
	view.pointer_down(80, 2); // The inner thumb is partly clipped by the outer list.
	test::eq(view.scroll_pressed, inner);
	test::eq(view.scroll_wheel(80, 35, -10), true);
	test::eq(inner.scroll_offset(), 0);
	test::eq(outer.scroll_offset(), 0);
	test::eq(view.scroll_dragging, false);
	view.pointer_up(80, 35);
}

fn void scrollbar_cancelled_capture_restores_hover_but_consumes_release() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.set_scrollbar();
	panel.column({ .height = 125 });
	Widget* check = view.checkbox("check");
	view.pointer_down(90, 10);
	view.pointer_move(1, 51);
	test::eq(view.hovered == null, true); // An active drag owns pointer interaction.
	view.cancel_press(); // The native window loses capture; release may never arrive.
	view.update();
	test::eq(view.scroll_pressed == null, true);
	test::eq(view.scroll_press_active, true);
	test::eq(view.hovered, check);
	view.pointer_up(1, 51);
	test::eq(check.is_checked(), false);
	test::eq(view.scroll_press_active, false);
	test::eq(view.hovered, check);
	view.pointer_down(1, 51);
	view.pointer_up(1, 51);
	test::eq(check.is_checked(), true);
}
