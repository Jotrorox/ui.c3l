module ui;
import std::core::test;

fn void scrolling_wheel_routes_once_to_innermost_viewport_and_bubbles_at_edges() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* outer = view.scroll_column({ .width = 100, .height = 100, .padding = 5, .gap = 5 });
	Widget* inner = outer.scroll_column({ .width = 90, .height = 60, .padding = 3 });
	for (int i = 0; i < 4; i++) inner.button("item");
	outer.column({ .width = 90, .height = 100 });
	test::eq(inner.scroll_extent(), 74);
	test::eq(outer.scroll_extent(), 75);
	test::eq(view.scroll_wheel(9, 9, 64), true);
	test::eq(inner.scroll_offset(), 64);
	test::eq(outer.scroll_offset(), 0);
	test::eq(view.scroll_wheel(9, 9, 20), true);
	test::eq(inner.scroll_offset(), 74);
	test::eq(outer.scroll_offset(), 0); // No remainder forwarded from the same event.
	test::eq(view.scroll_wheel(9, 9, 20), true);
	test::eq(inner.scroll_offset(), 74);
	test::eq(outer.scroll_offset(), 20);
	test::eq(view.scroll_wheel(9, 9, -10), true);
	test::eq(inner.scroll_offset(), 64);
	test::eq(outer.scroll_offset(), 20);
	inner.scroll_to(0);
	test::eq(view.scroll_wheel(9, 9, -50), true);
	test::eq(inner.scroll_offset(), 0);
	test::eq(outer.scroll_offset(), 0);
	test::eq(view.scroll_wheel(9, 9, -50), false);
	test::eq(view.scroll_wheel(9, 9, 0), false);
	test::eq(view.scroll_wheel(150, 9, 40), false);
	test::eq(view.scroll_wheel(-1, 9, 40), false);
	test::eq(view.scroll_wheel(100, 9, 40), false); // Half-open viewport bounds.
}

fn void scrolling_wheel_padding_disabled_hidden_and_current_geometry() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* outer = view.scroll_column({ .width = 100, .height = 100, .padding = 5 });
	Widget* inner = outer.scroll_column({ .width = 90, .height = 50, .padding = 5 });
	for (int i = 0; i < 3; i++) inner.button("item");
	outer.column({ .width = 90, .height = 100 });
	test::eq(view.scroll_wheel(6, 6, 10), true); // Inner viewport padding targets inner.
	test::eq(inner.scroll_offset(), 10);
	test::eq(outer.scroll_offset(), 0);
	test::eq(view.scroll_wheel(1, 1, 10), true); // Outer padding targets outer.
	test::eq(inner.scroll_offset(), 10);
	test::eq(outer.scroll_offset(), 10);
	inner.set_enabled(false);
	test::eq(view.scroll_wheel(11, 11, 10), true);
	test::eq(inner.scroll_offset(), 10);
	test::eq(outer.scroll_offset(), 20);
	outer.set_enabled(false);
	test::eq(view.scroll_wheel(11, 11, 10), false);
	test::eq(outer.scroll_offset(), 20);
	outer.set_enabled(true);
	inner.set_enabled(true);
	inner.set_visible(false);
	test::eq(view.scroll_wheel(11, 11, 100), false); // Pending shrink clamps to the boundary first.
	test::eq(outer.scroll_offset(), 10);
	test::eq(inner.scroll_offset(), 10);
	outer.set_visible(false);
	test::eq(view.scroll_wheel(11, 11, -10), false);
	outer.set_visible(true);
	inner.set_visible(true);
	view.update();
	test::eq(inner.scroll_offset(), 10);
	test::eq(view.scroll_wheel(11, 11, -10), true);
	test::eq(inner.scroll_offset(), 0);
}

fn void scrolling_wheel_cannot_target_viewport_clipped_by_ordinary_ancestor() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* clip = view.column({ .width = 100, .height = 30, .padding = 5 });
	Widget* panel = clip.scroll_column({ .width = 90, .height = 80 });
	for (int i = 0; i < 4; i++) panel.button("item");
	view.update();
	test::eq(panel.visible.height, 20);
	test::eq(view.scroll_wheel(10, 26, 20), false);
	test::eq(panel.scroll_offset(), 0);
	test::eq(view.scroll_wheel(10, 10, 20), true);
	test::eq(panel.scroll_offset(), 20);
	clip.set_layout({ .width = 100, .height = 8, .padding = 5 });
	test::eq(view.scroll_wheel(10, 10, 20), false);
	test::eq(panel.scroll_offset(), 20);
}

fn void scroll_input_click(void* context) @private { int* clicks = context; (*clicks)++; }

fn void scrolling_cancels_stale_press_even_when_pressed_control_remains_visible() @test
{
	View view;
	defer view.free();
	int clicks;
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 32 });
	Widget* first = panel.button("first", &scroll_input_click, &clicks);
	Widget* second = panel.button("second", &scroll_input_click, &clicks);
	view.pointer_down(1, 1);
	test::eq(view.pressed, first);
	test::eq(view.scroll_wheel(1, 1, 8), true);
	test::eq(view.pressed == null, true);
	test::eq(view.hovered, first);
	test::eq(view.focused, first);
	view.pointer_up(1, 1);
	test::eq(clicks, 0);
	view.pointer_down(1, 1);
	panel.scroll_to(32);
	view.update();
	test::eq(view.pressed == null, true);
	test::eq(view.hovered, second); // Reconciled without another pointer-move event.
	test::eq(view.focused == null, true);
	view.pointer_up(1, 1);
	test::eq(clicks, 0);
	view.pointer_down(1, 1);
	view.pointer_up(1, 1);
	test::eq(clicks, 1);
	test::eq(view.focused, second);
	view.pointer_down(1, 1);
	test::eq(view.scroll_wheel(1, 1, 20), false); // A boundary no-op keeps the valid press.
	view.pointer_up(1, 1);
	test::eq(clicks, 2);
}

fn void scrolling_tab_reveals_depth_first_candidates_and_wraps_in_both_directions() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 32, .gap = 8 });
	Widget* first = panel.button("first");
	Widget* disabled = panel.button("disabled");
	disabled.set_enabled(false);
	Widget* hidden = panel.button("hidden");
	hidden.set_visible(false);
	Widget* second = panel.column().button("second");
	Widget* last = view.button("last");
	view.focus_next();
	test::eq(view.focused, first);
	test::eq(panel.scroll_offset(), 0);
	view.focus_next();
	test::eq(view.focused, second);
	test::eq(panel.scroll_offset(), 80);
	test::eq(second.visible.height, 32);
	view.focus_next();
	test::eq(view.focused, last);
	view.focus_next();
	test::eq(view.focused, first);
	test::eq(panel.scroll_offset(), 0);
	view.focus_next(reverse: true);
	test::eq(view.focused, last);
	view.focus_next(reverse: true);
	test::eq(view.focused, second);
	test::eq(panel.scroll_offset(), 80);
	view.focus_next(reverse: true);
	test::eq(view.focused, first);
	test::eq(panel.scroll_offset(), 0);
}

fn void scrolling_nested_focus_reveal_adjusts_all_necessary_ancestors() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* outer = view.scroll_column({ .width = 100, .height = 50 });
	outer.column({ .height = 60 });
	Widget* inner = outer.scroll_column({ .width = 100, .height = 40 });
	Widget* first = inner.button("first");
	Widget* second = inner.button("second");
	Widget* outside = view.button("outside");
	view.update();
	test::eq(first.visible.empty() && second.visible.empty(), true);
	view.focus_next();
	test::eq(view.focused, first);
	test::eq(first.visible.height, 32);
	test::eq(outer.scroll_offset() > 0, true);
	test::eq(inner.scroll_offset(), 0);
	view.focus_next();
	test::eq(view.focused, second);
	test::eq(second.visible.height, 32);
	test::eq(inner.scroll_offset(), 24);
	test::eq(outer.scroll_offset(), 50);
	view.focus_next();
	test::eq(view.focused, outside);
	view.focus_next(reverse: true);
	test::eq(view.focused, second);
	test::eq(second.visible.height, 32);
	view.focus_next(reverse: true);
	test::eq(view.focused, first);
	test::eq(first.visible.height, 32);
	test::eq(inner.scroll_offset(), 0);
}

fn void scrolling_focus_skips_controls_unreachable_through_ordinary_clips() @test
{
	View view;
	defer view.free();
	view.resize(300, 250);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 32 });
	Widget* first = panel.button("first");
	Widget* ordinary = panel.column({ .height = 16 });
	ordinary.text("spacer");
	Widget* unreachable = ordinary.button("unreachable");
	Widget* final = panel.button("final");
	Widget* outside = view.button("outside");
	view.focus_next();
	test::eq(view.focused, first);
	view.focus_next();
	test::eq(view.focused, final);
	test::eq(unreachable.visible.empty(), true);
	test::eq(final.visible.height, 32);
	view.focus_next();
	test::eq(view.focused, outside);
	view.focus_next(reverse: true);
	test::eq(view.focused, final);
	view.focus_next(reverse: true);
	test::eq(view.focused, first);
	// A scroll viewport itself cannot be revealed through a non-scrolling clip.
	Widget* clip = view.column({ .width = 100, .height = 16 });
	clip.text("spacer");
	Widget* clipped_scroll = clip.scroll_column({ .height = 32 });
	clipped_scroll.button("hidden by ordinary parent");
	view.focus_next(reverse: true);
	test::eq(view.focused, outside);
}

fn void scrolling_focus_reveal_handles_oversized_and_horizontally_clipped_controls() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 80, .height = 24 });
	panel.text("spacer");
	Widget* oversized = panel.button("large");
	oversized.set_layout({ .height = 70 });
	Widget* row = panel.row({ .width = 80, .height = 32 });
	row.column({ .width = 80 });
	Widget* clipped = row.button("clipped horizontally");
	Widget* last = panel.button("last");
	view.focus_next();
	test::eq(view.focused, oversized);
	test::eq(oversized.visible.height, 24);
	view.focus_next();
	test::eq(view.focused, last);
	test::eq(clipped.visible.empty(), true);
	view.focus_next(reverse: true);
	test::eq(view.focused, oversized);
	test::eq(oversized.visible.height, 24);
}

fn void scrolling_focus_reveal_uses_ordinary_ancestor_clip_without_mutating_failed_candidates() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* ordinary = view.column({ .width = 100, .height = 30 });
	Widget* panel = ordinary.scroll_column({ .width = 100, .height = 100 });
	panel.column({ .height = 100 });
	Widget* reachable = panel.button("reachable");
	reachable.set_layout({ .height = 20 });
	panel.column({ .height = 60 });
	Widget* blocked = panel.button("blocked");
	blocked.set_layout({ .height = 20 });
	Widget* outside = view.button("outside");
	view.focus_next();
	test::eq(view.focused, reachable);
	test::eq(reachable.visible.height, 20);
	test::eq(panel.scroll_extent(), 100);
	int offset = panel.scroll_offset();
	view.focus_next();
	test::eq(view.focused, outside);
	test::eq(blocked.visible.empty(), true);
	test::eq(panel.scroll_offset(), offset); // Rejected reveal attempts have no side effects.
	view.focus_next(reverse: true);
	test::eq(view.focused, reachable);
	test::eq(reachable.visible.height, 20);
	test::eq(panel.scroll_offset(), offset);
	ordinary.set_layout({ .width = 100, .height = 4, .padding = 2 });
	view.focus_next();
	test::eq(view.focused, outside);
}

fn void scrolling_nested_focus_reveal_uses_the_root_clip_when_outer_has_no_extent() @test
{
	View view;
	defer view.free();
	view.resize(200, 50);
	view.set_root_spacing(0, 0);
	Widget* outer = view.scroll_column({ .width = 100, .height = 100 });
	Widget* inner = outer.scroll_column({ .width = 100, .height = 100 });
	inner.column({ .height = 100 });
	Widget* target = inner.button("target");
	target.set_layout({ .height = 20 });
	inner.column({ .height = 80 });
	view.focus_next();
	test::eq(view.focused, target);
	test::eq(outer.scroll_extent(), 0);
	test::eq(outer.scroll_offset(), 0);
	test::eq(inner.scroll_extent(), 100);
	test::eq(inner.scroll_offset(), 70);
	test::eq(target.visible.y, 30);
	test::eq(target.visible.height, 20);
}

fn void scrolling_and_focus_reveal_preserve_held_activation_keys() @test
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
	view.key_down(9, TAB);
	test::eq(view.focused, second);
	test::eq(panel.scroll_offset(), 24);
	view.key_down(32, ACTIVATE);
	view.key_down(32, ACTIVATE, repeat: true);
	test::eq(second.is_checked(), false);
	test::eq(view.held_keys[32], true);
	panel.scroll_to(0);
	view.update();
	test::eq(view.focused == null, true);
	test::eq(view.held_keys[32], true);
	view.focus_next();
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), true);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), false);
	view.key_down(9, TAB, repeat: true);
	test::eq(view.focused, second);
	view.key_down(32, ACTIVATE);
	test::eq(second.is_checked(), false);
}

struct ScrollRemovalProbe @private
{
	Widget* remove;
	State{bool} checked;
	int callbacks;
}

fn bool scroll_removal_checked(void* context) @private
{
	ScrollRemovalProbe* probe = context;
	return probe.checked.get();
}

fn void scroll_remove_callback(void* context, bool checked) @private
{
	ScrollRemovalProbe* probe = context;
	probe.callbacks++;
	probe.checked.set(checked);
	probe.remove.remove();
}

fn void scrolling_revealed_callback_can_remove_scroll_ancestor_and_pending_binding() @test
{
	View view;
	defer view.free();
	ScrollRemovalProbe probe;
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	probe.remove = view.scroll_column({ .width = 100, .height = 24 });
	probe.remove.text("spacer");
	Widget* check = probe.remove.checkbox("remove", on_change: &scroll_remove_callback, context: &probe);
	check.bind_checked(&scroll_removal_checked, &probe);
	Widget* survivor = view.checkbox("survivor");
	view.focus_next();
	test::eq(view.focused, check);
	test::eq(probe.remove.scroll_offset(), 16);
	view.key_down(32, ACTIVATE);
	test::eq(probe.callbacks, 1);
	test::eq(probe.checked.get(), true);
	test::eq(probe.checked.signal.subscribers == null, true);
	test::eq(view.pending_head == null && view.pending_tail == null, true);
	test::eq(view.focused == null && view.pressed == null, true);
	view.focus_next();
	test::eq(view.focused, survivor);
	view.key_down(32, ACTIVATE);
	test::eq(survivor.is_checked(), false);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(survivor.is_checked(), true);
}
