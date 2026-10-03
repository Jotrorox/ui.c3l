module ui;
import std::core::test;

fn void scrolling_keys_use_content_height_clamp_and_repeat_after_focus_is_clipped() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 70, .padding = 5 });
	Widget* first = panel.button("first");
	first.set_layout({ .height = 90 });
	panel.text("tail").set_layout({ .height = 160 });
	view.focus_next();
	view.pointer_move(200, 100); // Pointer position does not override widget focus.
	view.key_down(34, PAGE_DOWN);
	test::eq(panel.scroll_offset(), 60);
	test::eq(view.focused, first); // Partial clipping retains focus.
	view.key_down(34, PAGE_DOWN, repeat: true);
	test::eq(panel.scroll_offset(), 120);
	test::eq(view.focused == null, true); // Full clipping clears focus.
	view.key_down(34, PAGE_DOWN, repeat: true);
	test::eq(panel.scroll_offset(), 180);
	view.key_down(34, PAGE_DOWN, repeat: true);
	test::eq(panel.scroll_offset(), 190);
	view.key_down(34, PAGE_DOWN, repeat: true);
	test::eq(panel.scroll_offset(), 190);
	view.key_down(33, PAGE_UP);
	test::eq(panel.scroll_offset(), 130);
	view.key_down(36, SCROLL_HOME);
	test::eq(panel.scroll_offset(), 0);
	test::eq(view.focused == null, true); // Scrolling never assigns replacement focus.
	view.key_down(35, SCROLL_END);
	test::eq(panel.scroll_offset(), 190);
	panel.set_layout({ .width = 100, .height = 90, .padding = 5 });
	view.key_down(33, PAGE_UP, repeat: true);
	test::eq(panel.scroll_offset(), 90); // Flush resize: clamp to 170, then page by 80.
}

fn void scrolling_keys_bubble_only_to_ancestors_and_consume_one_viewport_per_event() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* row = view.row();
	Widget* outer = row.scroll_column({ .width = 100, .height = 100, .padding = 5, .gap = 5 });
	Widget* inner = outer.scroll_column({ .width = 90, .height = 60, .padding = 3 });
	Widget* control = inner.column().button("tall");
	control.set_layout({ .height = 200 }); // Stays partially visible at inner boundaries.
	outer.column({ .height = 100 });
	Widget* sibling = row.scroll_column({ .width = 100, .height = 100 });
	sibling.text("tail").set_layout({ .height = 300 });
	view.focus_next();
	view.pointer_move(110, 10);
	view.key_down(34, PAGE_DOWN);
	test::eq(inner.scroll_offset(), 54);
	view.key_down(34, PAGE_DOWN, repeat: true);
	view.key_down(34, PAGE_DOWN, repeat: true);
	test::eq(inner.scroll_offset(), 146);
	test::eq(outer.scroll_offset(), 0); // A partial page has no forwarded remainder.
	view.key_down(34, PAGE_DOWN, repeat: true);
	test::eq(outer.scroll_offset(), 75); // Uses the outer content height (90).
	test::eq(sibling.scroll_offset(), 0);
	test::eq(view.focused == null, true);
	view.key_down(33, PAGE_UP);
	test::eq(outer.scroll_offset(), 0); // Continue from the last consuming viewport.
	test::eq(inner.scroll_offset(), 146);
	view.focus_next();
	view.key_down(35, SCROLL_END);
	test::eq(inner.scroll_offset(), 146);
	test::eq(outer.scroll_offset(), 0);
	view.key_down(35, SCROLL_END, repeat: true);
	test::eq(outer.scroll_offset(), 75);
	view.key_down(36, SCROLL_HOME);
	test::eq(outer.scroll_offset(), 0);
	view.pointer_down(9, 9);
	view.pointer_up(9, 9);
	view.key_down(36, SCROLL_HOME);
	test::eq(inner.scroll_offset(), 0);
	outer.scroll_to(10);
	view.key_down(36, SCROLL_HOME, repeat: true);
	test::eq(outer.scroll_offset(), 0); // Inner Home at its boundary bubbles upward.
	outer.scroll_to(20);
	view.key_down(33, PAGE_UP);
	test::eq(outer.scroll_offset(), 0); // Page Up bubbles at the inner top as well.
	test::eq(sibling.scroll_offset(), 0);
}

fn void scrolling_keys_cancel_press_reconcile_hover_and_preserve_held_activation() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 24 });
	Widget* first = panel.checkbox("first");
	Widget* second = panel.checkbox("second");
	view.focus_next();
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), true);
	view.pointer_down(1, 1);
	view.key_down(34, PAGE_DOWN);
	test::eq(view.pressed == null && view.focused == null, true);
	test::eq(view.hovered, second);
	view.pointer_up(1, 1);
	test::eq(second.is_checked(), false);
	view.key_down(32, ACTIVATE, repeat: true);
	view.focus_next(reverse: true);
	test::eq(view.focused, second);
	view.key_down(32, ACTIVATE, repeat: true);
	test::eq(second.is_checked(), false);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(second.is_checked(), true);
	view.pointer_down(1, 1);
	view.key_down(35, SCROLL_END); // Boundary no-op keeps the valid press and focus.
	test::eq(view.pressed, second);
	test::eq(view.focused, second);
	view.pointer_up(1, 1);
	test::eq(second.is_checked(), false);
}

fn void scrolling_keys_click_target_tab_outside_and_blur() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50, .padding = 5 });
	panel.text("content").set_layout({ .height = 200 });
	Widget* outside = view.button("outside");
	view.key_down(34, PAGE_DOWN);
	view.pointer_move(1, 1);
	view.key_down(34, PAGE_DOWN);
	test::eq(panel.scroll_offset(), 0); // Hover alone does not select a keyboard receiver.
	view.pointer_down(1, 1); // Padding can select a viewport without a focusable child.
	view.pointer_up(1, 1);
	view.key_down(34, PAGE_DOWN);
	test::eq(panel.scroll_offset(), 40);
	view.focus_next();
	test::eq(view.focused, outside);
	view.key_down(35, SCROLL_END);
	test::eq(panel.scroll_offset(), 40);
	view.pointer_down(1, 1);
	view.pointer_up(1, 1);
	view.blur();
	view.key_down(35, SCROLL_END);
	test::eq(panel.scroll_offset(), 40);
}

fn void scrolling_keys_drop_detached_hidden_disabled_or_fully_clipped_receivers() @test
{
	for (int reason = 0; reason < 6; reason++)
	{
		View view;
		defer view.free();
		view.resize(300, 200);
		view.set_root_spacing(0, 0);
		Widget* ancestor = view.column({ .width = 100, .height = 80 });
		Widget* panel = ancestor.scroll_column({ .width = 100, .height = 50 });
		panel.text("content").set_layout({ .height = 200 });
		view.pointer_down(1, 1);
		view.pointer_up(1, 1);
		view.key_down(34, PAGE_DOWN);
		switch (reason)
		{
			case 0: ancestor.set_visible(false);
			case 1: ancestor.set_enabled(false);
			case 2: ancestor.set_layout({ .width = 100, .height = 1, .padding = 1 });
			case 3: view.append(ancestor); // Already last: no actual detachment.
				test::eq(view.keyboard_scroll, panel);
				view.column().append(ancestor);
			case 4: panel.remove();
			case 5: ancestor.remove();
		}
		view.key_down(35, SCROLL_END);
		test::eq(view.keyboard_scroll == null, true);
		if (reason < 4) test::eq(panel.scroll_offset(), 50);
	}
}

fn void scrolling_keys_cancel_thumb_drag_only_when_an_offset_changes() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.set_scrollbar();
	panel.text("content").set_layout({ .height = 200 });
	view.pointer_down(90, 1);
	view.key_down(36, SCROLL_HOME);
	test::eq(view.scroll_dragging, true);
	view.key_down(34, PAGE_DOWN);
	test::eq(panel.scroll_offset(), 50);
	test::eq(view.scroll_dragging, false);
	test::eq(view.scroll_press_active, true);
	view.pointer_up(90, 1);
	test::eq(view.scroll_press_active, false);
}
