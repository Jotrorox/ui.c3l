module ui;
import std::core::test;

fn void scrollbar_clicked(void* context) @private { int* clicks = context; (*clicks)++; }

fn void scrollbar_drag_preserves_grab_anchor_and_rounds_signed_deltas() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.set_scrollbar();
	panel.column({ .height = 125 });
	panel.scroll_to(11);
	test::eq(panel.scroll_thumb.y, 4);
	view.pointer_down(90, 15); // Grab away from the thumb's top edge.
	test::eq(view.scroll_pressed, panel);
	test::eq(view.scroll_dragging, true);
	test::eq(view.pressed == null, true);
	view.pointer_move(90, 15);
	test::eq(panel.scroll_offset(), 11); // No jump to a rounded thumb-derived offset.
	view.pointer_move(90, 16);
	test::eq(panel.scroll_offset(), 14); // 75/30 = 2.5 rounds away from zero.
	view.pointer_move(90, 14);
	test::eq(panel.scroll_offset(), 8);
	view.pointer_move(-200, 15);
	test::eq(panel.scroll_offset(), 11); // Horizontal movement is irrelevant.
	view.pointer_move(-200, 1000);
	test::eq(panel.scroll_offset(), 75);
	view.pointer_move(-200, -1000);
	test::eq(panel.scroll_offset(), 0);
	view.pointer_move(-200, 15);
	test::eq(panel.scroll_offset(), 11); // End clamps do not replace the original anchor.
	view.pointer_up(-200, 45);
	test::eq(panel.scroll_offset(), 75); // Release uses its own final coordinates.
	test::eq(view.scroll_pressed == null && !view.scroll_dragging && !view.scroll_press_active, true);
	view.pointer_move(90, 0);
	test::eq(panel.scroll_offset(), 75);
}

fn void scrollbar_track_pages_once_and_can_pass_the_click_position() @test
{
	View view;
	defer view.free();
	int clicks;
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 60, .padding = 5 });
	panel.set_scrollbar();
	Widget* child = panel.button("a", &scrollbar_clicked, &clicks);
	child.set_layout({ .width = 100, .height = 125 });
	view.update();
	view.pointer_down(90, 26); // Just below initial thumb [5,25).
	test::eq(panel.scroll_offset(), 50);
	test::eq(panel.scroll_thumb.y, 25);
	test::eq(view.scroll_press_active, true);
	test::eq(view.scroll_dragging, false);
	test::eq(view.pressed == null, true);
	view.pointer_move(90, 26);
	view.update();
	test::eq(panel.scroll_offset(), 50);
	view.pointer_up(6, 6);
	test::eq(clicks, 0);
	test::eq(view.scroll_press_active, false);
	view.pointer_down(90, 5);
	test::eq(panel.scroll_offset(), 0);
	view.pointer_up(90, 5);
	view.pointer_down(90, 54);
	test::eq(panel.scroll_offset(), 50);
	view.pointer_up(90, 54);
	view.pointer_down(90, 54);
	test::eq(panel.scroll_offset(), 75);
	view.pointer_up(90, 54);
	view.pointer_down(90, 15);
	test::eq(panel.scroll_offset(), 25);
	view.pointer_up(90, 15);
	view.pointer_down(6, 6);
	view.pointer_up(6, 6);
	test::eq(clicks, 1);
}

fn void scrollbar_gutter_never_targets_oversized_controls_or_padding() @test
{
	View view;
	defer view.free();
	int clicks;
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 60, .padding = 5 });
	panel.set_scrollbar();
	Widget* button = panel.button("a", &scrollbar_clicked, &clicks);
	button.set_layout({ .width = 150, .height = 100 });
	view.update();
	test::eq(view.hit_test(82, 6), button);
	test::eq(view.hit_test(83, 6) == null, true);
	foreach (int[2] point : { { 90, 4 }, { 95, 6 }, { 90, 55 } })
	{
		view.pointer_down(point[0], point[1]);
		test::eq(view.scroll_press_active, false);
		view.pointer_up(6, 6);
	}
	test::eq(clicks, 0);
	panel.set_enabled(false);
	view.pointer_down(90, 40);
	test::eq(view.scroll_press_active, true);
	test::eq(view.scroll_dragging, false);
	test::eq(panel.scroll_offset(), 0);
	panel.set_enabled(true);
	view.pointer_move(90, 50);
	view.pointer_up(6, 6);
	test::eq(panel.scroll_offset(), 0);
	test::eq(clicks, 0);
}

fn void scrollbar_nested_targeting_keeps_wheel_boundary_bubbling() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* outer = view.scroll_column({ .width = 100, .height = 100, .padding = 5, .gap = 5 });
	outer.set_scrollbar();
	Widget* inner = outer.scroll_column({ .width = 78, .height = 60, .padding = 3 });
	inner.set_scrollbar();
	for (int i = 0; i < 4; i++) inner.button("item");
	outer.column({ .height = 100 });
	view.update();
	scrollbar_rect(outer.scroll_track, 83, 5, 12, 90);
	scrollbar_rect(inner.scroll_track, 68, 8, 12, 54);
	view.pointer_down(70, 9);
	test::eq(view.scroll_pressed, inner);
	view.pointer_move(90, 30); // Crossing the outer gutter retains the inner drag.
	test::eq(inner.scroll_offset() > 0, true);
	test::eq(outer.scroll_offset(), 0);
	view.pointer_up(90, 30);
	inner.scroll_to(int::max);
	test::eq(view.scroll_wheel(70, 10, 10), true);
	test::eq(inner.scroll_offset(), 74);
	test::eq(outer.scroll_offset(), 10);
	outer.scroll_to(0);
	view.pointer_down(90, 6);
	test::eq(view.scroll_pressed, outer);
	view.pointer_move(70, 16);
	test::eq(outer.scroll_offset() > 0, true);
	test::eq(inner.scroll_offset(), 74);
	view.pointer_up(70, 16);
}

fn void scrollbar_cancelled_press_never_retargets_after_mutation_or_capture_loss() @test
{
	// Every iteration starts a fresh native-style press lifetime. Target and
	// ancestor mutations must discard pointers before any subtree can be freed.
	for (int reason = 0; reason < 16; reason++)
	{
		View view;
		defer view.free();
		int clicks;
		view.resize(300, 400);
		view.set_root_spacing(0, 0);
		Widget* ancestor = view.column({ .width = 100, .height = 100 });
		Widget* panel = ancestor.scroll_column({ .width = 100, .height = 50 });
		panel.set_scrollbar();
		panel.column({ .height = 125 });
		Widget* destination = view.column({ .width = 100, .height = 100 });
		Widget* survivor = view.button("survivor", &scrollbar_clicked, &clicks);
		view.pointer_down(90, 10);
		test::eq(view.scroll_dragging, true);
		bool removed;
		switch (reason)
		{
			case 0: panel.set_visible(false);
			case 1: ancestor.set_visible(false);
			case 2: panel.set_enabled(false);
			case 3: ancestor.set_enabled(false);
			case 4: panel.remove(); removed = true;
			case 5: ancestor.remove(); removed = true;
			case 6: destination.append(panel);
			case 7: destination.append(ancestor);
			case 8: panel.set_scrollbar(false);
			case 9: view.resize(320, 400);
			case 10: view.cancel_press(); // Native capture loss.
			case 11: view.blur();
			case 12: panel.set_layout({ .width = 100, .height = 60 });
			case 13: panel.first.set_layout({ .height = 126 });
			case 14: panel.scroll_to(15);
			case 15: ancestor.set_layout({ .width = 100, .height = 25 });
		}
		view.update();
		test::eq(view.scroll_pressed == null && !view.scroll_dragging, true);
		if (reason != 11) test::eq(view.scroll_press_active, true);
		int offset = removed ? 0 : panel.scroll_offset();
		view.pointer_move(90, 40);
		if (!removed) test::eq(panel.scroll_offset(), offset);
		view.pointer_up(survivor.visible.x + 1, survivor.visible.y + 1);
		test::eq(clicks, 0);
		test::eq(view.scroll_press_active, false);
		view.pointer_down(survivor.visible.x + 1, survivor.visible.y + 1);
		view.pointer_up(survivor.visible.x + 1, survivor.visible.y + 1);
		test::eq(clicks, 1);
	}
}

fn void scrollbar_noop_programmatic_scroll_keeps_drag_but_external_change_cancels() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.set_scrollbar();
	panel.column({ .height = 125 });
	view.pointer_down(90, 10);
	panel.scroll_to(-100);
	panel.scroll_by(0);
	panel.set_scrollbar();
	panel.set_layout(panel.layout);
	view.update();
	test::eq(view.scroll_dragging, true);
	view.pointer_move(90, 20);
	test::eq(panel.scroll_offset(), 25);
	panel.scroll_by(1);
	test::eq(view.scroll_dragging, false);
	view.pointer_up(90, 40);
	test::eq(panel.scroll_offset(), 26);
}

fn void scrollbar_focus_reveal_and_drag_preserve_activation_key_lifetime() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 24 });
	panel.set_scrollbar();
	Widget* first = panel.checkbox("first");
	Widget* second = panel.checkbox("second");
	view.focus_next();
	test::eq(view.focused, first);
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), true);
	view.key_down(9, TAB);
	test::eq(view.focused, second);
	test::eq(panel.scroll_offset(), 24);
	test::eq(panel.scroll_thumb.y, 8);
	view.key_down(32, ACTIVATE, repeat: true);
	test::eq(second.is_checked(), false);
	view.pointer_down(90, 12);
	view.pointer_move(90, -100);
	test::eq(panel.scroll_offset(), 0);
	test::eq(view.held_keys[32], true);
	view.pointer_up(90, -100);
	view.focus_next();
	test::eq(view.focused, first);
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), true);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), false);
	view.focus_next(reverse: true);
	test::eq(view.focused, second);
	test::eq(panel.scroll_offset(), 24);
}

fn void scrollbar_clipped_track_uses_ancestor_clip_for_pointer_targeting() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* ancestor = view.column({ .width = 100, .height = 25 });
	Widget* panel = ancestor.scroll_column({ .width = 100, .height = 100 });
	panel.set_scrollbar();
	panel.column({ .height = 400 });
	view.pointer_down(90, 30);
	test::eq(view.scroll_press_active, false);
	view.pointer_up(90, 30);
	view.pointer_down(90, 10);
	test::eq(view.scroll_dragging, true);
	view.pointer_move(90, 35);
	test::eq(panel.scroll_offset(), 100); // Drag may leave its initial ancestor clip.
	view.pointer_up(90, 35);
	ancestor.set_layout({ .width = 80, .height = 25 });
	view.pointer_down(90, 10);
	test::eq(view.scroll_press_active, false);
	view.pointer_up(90, 10);
}

fn void scrollbar_wheel_noops_do_not_move_drag_using_wheel_coordinates() @test
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
	test::eq(view.scroll_wheel(90, 40, 0), false);
	test::eq(panel.scroll_offset(), 0);
	test::eq(view.scroll_wheel(90, 40, -10), false);
	test::eq(panel.scroll_offset(), 0);
	test::eq(view.scroll_dragging, true);
	test::eq(view.scroll_wheel(90, 40, 10), true);
	test::eq(panel.scroll_offset(), 10);
	test::eq(view.scroll_dragging, false);
	test::eq(view.scroll_press_active, true);
	view.pointer_up(90, 45);
	test::eq(panel.scroll_offset(), 10);
}

fn void scrollbar_focused_callback_can_remove_drag_target_and_pending_bindings() @test
{
	View view;
	defer view.free();
	ScrollRemovalProbe probe;
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	probe.remove = view.scroll_column({ .width = 100, .height = 24 });
	probe.remove.set_scrollbar();
	probe.remove.text("spacer");
	Widget* check = probe.remove.checkbox("remove", on_change: &scroll_remove_callback, context: &probe);
	check.bind_checked(&scroll_removal_checked, &probe);
	Widget* survivor = view.checkbox("survivor");
	view.focus_next();
	test::eq(view.focused, check);
	test::eq(probe.remove.scroll_offset(), 16);
	view.pointer_down(90, 12);
	test::eq(view.focused, check); // A scrollbar press does not steal keyboard focus.
	test::eq(view.scroll_dragging, true);
	view.key_down(32, ACTIVATE);
	test::eq(probe.callbacks, 1);
	test::eq(probe.checked.signal.subscribers == null, true);
	test::eq(view.pending_head == null && view.pending_tail == null, true);
	test::eq(view.scroll_pressed == null && !view.scroll_dragging && view.scroll_press_active, true);
	test::eq(view.focused == null && view.pressed == null, true);
	view.update();
	view.pointer_up(survivor.visible.x + 1, survivor.visible.y + 1);
	test::eq(survivor.is_checked(), false);
	view.focus_next();
	test::eq(view.focused, survivor);
	view.key_down(32, ACTIVATE);
	test::eq(survivor.is_checked(), false);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(survivor.is_checked(), true);
}
