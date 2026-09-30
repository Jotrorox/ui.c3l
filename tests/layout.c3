module ui;
import std::core::test;

struct LayoutProbe
{
	State{int} state;
	int evaluations;
	int measurements;
	int clicks;
	Rect clip;
	Rect text_clip;
	Rect cleared;
	int texts;
}

fn Size layout_metrics(void* context, String text) @private
{
	LayoutProbe* probe = context;
	probe.measurements++;
	return { (int)text.len * 8, text == "tall" ? 32 : 16 };
}

fn String growing_label(void* context) @private
{
	LayoutProbe* probe = context;
	probe.evaluations++;
	return probe.state.get() ? "tall" : "a";
}

fn void layout_click(void* context) @private
{
	LayoutProbe* probe = context;
	probe.clicks++;
}

fn void? layout_clip(void* context, Rect clip) @private
{
	LayoutProbe* probe = context;
	probe.clip = clip;
}

fn void? layout_fill(void* context, Rect rect, Ink ink) @private
{
	LayoutProbe* probe = context;
	if (ink == PAPER) probe.cleared = rect;
}

fn void? layout_text(void* context, String text, int x, int y, Ink ink) @private
{
	LayoutProbe* probe = context;
	probe.texts++;
	probe.text_clip = probe.clip;
}

fn void expect_rect(Rect actual, int x, int y, int width, int height) @private
{
	test::eq(actual.x, x);
	test::eq(actual.y, y);
	test::eq(actual.width, width);
	test::eq(actual.height, height);
}

fn void nested_content_measurement_and_placement() @test
{
	View view;
	defer view.free();
	LayoutProbe probe;
	view.set_measurer(&layout_metrics, &probe);
	view.resize(400, 300);
	Widget* column = view.column({ .padding = 4, .gap = 6 });
	Widget* heading = column.text("tall");
	Widget* row = column.row({ .padding = 3, .gap = 5 });
	Widget* text = row.text("ab");
	Widget* button = row.button("x", null);
	Widget* footer = view.text("end");
	view.update();
	expect_rect(column.bounds, 16, 16, 67, 84);
	expect_rect(heading.bounds, 20, 20, 32, 32);
	expect_rect(row.bounds, 20, 58, 59, 38);
	expect_rect(text.bounds, 23, 61, 16, 16);
	expect_rect(button.bounds, 44, 61, 32, 32);
	expect_rect(footer.bounds, 16, 108, 24, 16);
	test::eq(probe.measurements, 4);
	test::eq(text.owner, &view);
	test::eq(text.parent, row);
	test::eq(column.parent == null, true);
	Widget* empty = view.column({ .padding = 5, .gap = 99 });
	view.update();
	test::eq(empty.desired.width, 10);
	test::eq(empty.desired.height, 10); // No leading/trailing gap, even when empty.
}

fn void dimensions_constraints_and_overflow_are_deterministic() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* row = view.row({ .width = 100, .height = 90, .min_width = 120,
		.max_width = 140, .max_height = 80, .padding = 10, .gap = 12 });
	Widget* large = row.button("large", null);
	test::eq(large.set_layout({ .width = 200, .height = 100, .min_height = 90 }), true);
	Widget* overflow = row.button("overflow", null);
	view.update();
	expect_rect(row.bounds, 16, 16, 120, 80);
	expect_rect(large.bounds, 26, 26, 200, 60); // Available cross-axis space wins.
	expect_rect(large.visible, 26, 26, 100, 60);
	test::eq(overflow.visible.empty(), true);
	test::eq(view.hit_test(large.visible.x + 1, large.visible.y + 1), large);
	test::eq(view.hit_test(large.visible.x + large.visible.width, large.visible.y) == null, true);
	view.focus_next();
	test::eq(view.focused, large);
	view.focus_next();
	test::eq(view.focused, large); // Invisible overflow is skipped.
	test::eq(row.set_layout({ .min_width = 50, .max_width = 40 }), false);
	test::eq(row.layout.width, 100);
	test::eq(row.set_layout({ .width = -1 }), false);
	test::eq(row.set_layout({ .padding = LAYOUT_LIMIT + 1 }), false);
	test::eq(large.set_layout({ .gap = 1 }), false);
	test::eq(view.set_root_spacing(-1), false);
	view.resize(100, 100);
	view.update();
	test::eq(row.bounds.width, 68);
	test::eq(large.visible.width, 48);
}

fn void spacing_and_constraint_edits_reuse_text_metrics() @test
{
	View view;
	defer view.free();
	LayoutProbe probe;
	view.resize(300, 300);
	view.set_measurer(&layout_metrics, &probe);
	Widget* row = view.row({ .width = 140, .height = 80, .gap = 4 });
	Widget* first = row.text("a");
	Widget* second = row.button("b", null);
	view.update();
	view.take_damage();
	int old_x = second.bounds.x;
	test::eq(row.set_layout({ .width = 140, .height = 80, .gap = 12, .padding = 3 }), true);
	view.update();
	test::eq(first.bounds.x, 19);
	test::eq(second.bounds.x, old_x + 11);
	test::eq(probe.measurements, 2);
	test::eq(view.set_root_spacing(2, 1), true);
	view.update();
	test::eq(first.bounds.x, 5);
	test::eq(second.set_layout({ .width = 90, .height = 40 }), true);
	view.update();
	test::eq(second.bounds.width, 90);
	test::eq(probe.measurements, 2);
}

fn void nested_reactivity_moves_siblings_and_reuses_clean_subtrees() @test
{
	View view;
	defer view.free();
	LayoutProbe changing, clean;
	view.resize(500, 400);
	view.set_measurer(&layout_metrics, &changing);
	Widget* row = view.row({ .gap = 7 });
	Widget* column = row.column({ .gap = 3 });
	Widget* label = column.text();
	label.bind(&growing_label, &changing);
	Widget* below = column.button("below", null);
	Widget* right = row.column();
	Widget* other = right.text();
	other.bind(&growing_label, &clean);
	view.update();
	view.take_damage();
	int old_y = below.bounds.y;
	int old_right = right.bounds.x;
	changing.state.set(1);
	changing.state.set(2);
	view.update();
	test::eq(changing.evaluations, 2);
	test::eq(clean.evaluations, 1);
	test::eq(changing.measurements, 4);
	test::eq(below.bounds.y, old_y + 16);
	test::eq(right.bounds.x, old_right); // The wider button still determines width.
	test::eq(column.first, label);
	below.set_text("b");
	view.update();
	test::eq(right.bounds.x < old_right, true);
	test::eq(changing.evaluations, 2);
	test::eq(clean.evaluations, 1);
	view.take_damage();
	view.resize(90, 90);
	view.update();
	test::eq(changing.measurements, 5);
	test::eq(changing.evaluations, 2);
	test::eq(clean.evaluations, 1);
}

fn void fixed_ancestor_still_places_changed_descendants() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* fixed = view.column({ .width = 200, .height = 120 });
	Widget* row = fixed.row({ .gap = 2 });
	Widget* text = row.text("a");
	Widget* moved = row.column();
	Widget* button = moved.button("ok", null);
	Widget* root_sibling = view.button("outside", null);
	view.update();
	int old_x = button.bounds.x;
	int old_y = root_sibling.bounds.y;
	text.set_text("aaaa");
	view.update();
	test::eq(button.bounds.x, old_x + 24);
	test::eq(root_sibling.bounds.y, old_y);
	test::eq(fixed.desired.height, 120);
}

fn void nested_paint_clips_and_clears_previous_bounds() @test
{
	View view;
	defer view.free();
	LayoutProbe probe;
	view.resize(300, 200);
	Widget* outer = view.column({ .width = 70, .height = 44, .padding = 4 });
	Widget* row = outer.row({ .width = 200, .height = 80, .padding = 3 });
	Widget* text = row.text("a long label");
	row.text("fully clipped");
	view.update();
	Renderer renderer = { &probe, &layout_fill, &layout_text, &layout_clip };
	view.paint(&renderer, view.take_damage())!!;
	test::eq(probe.texts, 1);
	expect_rect(probe.text_clip, 23, 23, 56, 16);
	Rect old_visible = text.visible;
	text.set_text("x");
	view.update();
	Rect damage = view.take_damage();
	test::eq(damage.intersect(old_visible).width, old_visible.width);
	probe.texts = 0;
	view.paint(&renderer, damage)!!;
	test::eq(probe.cleared.width >= old_visible.width, true);
	test::eq(text.bounds.width, 8);
	view.take_damage();
	outer.remove();
	view.update();
	test::eq(view.take_damage().empty(), false);
}

fn void layout_resize_and_enable_reconcile_stationary_pointer() @test
{
	View view;
	defer view.free();
	LayoutProbe probe;
	view.set_measurer(&layout_metrics, &probe);
	view.resize(300, 200);
	Widget* column = view.column();
	Widget* spacer = column.text("a");
	Widget* button = column.button("click", &layout_click, &probe);
	view.update();
	int x = button.visible.x + 1;
	int y = button.visible.y + 1;
	view.pointer_down(x, y);
	test::eq(view.hovered, button);
	spacer.set_text("tall");
	view.update();
	test::eq(view.hovered == null, true);
	view.pointer_up(x, y);
	test::eq(probe.clicks, 0);
	spacer.set_text("a");
	view.update();
	test::eq(view.hovered, button);
	view.pointer_down(x, y);
	view.resize(x, y);
	view.update();
	test::eq(view.hovered == null, true);
	test::eq(view.pressed == null, true);
	test::eq(view.focused == null, true);
	view.resize(300, 200);
	view.update();
	test::eq(view.hovered, button);
	view.pointer_up(x, y);
	test::eq(probe.clicks, 0);
	view.take_damage();
	column.set_enabled(false);
	view.update();
	test::eq(view.hovered == null, true);
	test::eq(view.layout_dirty || view.measure_dirty || view.subtree_layout_dirty, false);
	test::eq(probe.measurements, 4);
	column.set_enabled(true);
	view.update();
	test::eq(view.hovered, button);
	test::eq(probe.measurements, 4);
}

fn void nested_focus_order_reparenting_and_invalid_attachments() @test
{
	View view, other;
	defer view.free();
	defer other.free();
	view.resize(500, 500);
	Widget* row = view.row({ .gap = 4 });
	Widget* first = row.button("first", null);
	Widget* column = row.column();
	column.text("heading");
	Widget* second = column.button("second", null);
	Widget* disabled = column.button("disabled", null);
	disabled.set_enabled(false);
	Widget* last = view.button("last", null);
	Widget* foreign = other.column();
	test::eq(column.append(row), false);
	test::eq(row.append(row), false);
	test::eq(first.append(last), false);
	test::eq(row.append(foreign), false);
	test::eq(view.append(foreign), false);
	test::eq(row.append(null), false);
	test::eq(view.first, row);
	test::eq(row.parent == null, true);
	view.focus_next();
	test::eq(view.focused, first);
	view.focus_next();
	test::eq(view.focused, second);
	view.focus_next();
	test::eq(view.focused, last);
	view.focus_next();
	test::eq(view.focused, first);
	view.focus_next(reverse: true);
	test::eq(view.focused, last);
	test::eq(column.append(first), true);
	view.focus_next(reverse: true);
	test::eq(view.focused, first);
	view.focus_next(reverse: true);
	test::eq(view.focused, second);
	test::eq(view.append(column), true);
	view.update();
	test::eq(column.parent == null, true);
	test::eq(view.last, column);
	test::eq(first.parent, column);
}

fn void moving_a_dirty_subtree_preserves_queued_bindings() @test
{
	View view;
	defer view.free();
	LayoutProbe probe;
	view.resize(500, 500);
	Widget* from = view.column();
	Widget* to = view.column();
	Widget* row = from.row();
	Widget* label = row.text();
	label.bind(&growing_label, &probe);
	view.update();
	probe.state.set(1);
	label.set_layout({ .min_width = 90 });
	test::eq(to.append(row), true);
	view.update();
	test::eq(probe.evaluations, 2);
	test::eq(row.first, label);
	test::eq(to.desired.width, 90);
	test::eq(from.desired.height, 0);
	test::eq(label.get_text(), "tall");
}

fn void removing_subtree_clears_pending_work_input_and_subscriptions() @test
{
	View view;
	LayoutProbe removed, kept;
	view.resize(400, 400);
	Widget* root = view.column();
	Widget* row = root.row();
	Widget* first = row.button("", &layout_click, &removed);
	first.bind(&growing_label, &removed);
	Widget* second = row.text();
	second.bind(&growing_label, &removed);
	Widget* survivor = view.text();
	survivor.bind(&growing_label, &kept);
	view.update();
	int x = first.visible.x + 1;
	int y = first.visible.y + 1;
	view.pointer_down(x, y);
	view.take_damage();
	removed.state.set(1);
	kept.state.set(1);
	root.remove();
	test::eq(view.hovered == null, true);
	test::eq(view.pressed == null, true);
	test::eq(view.focused == null, true);
	test::eq(removed.state.signal.subscribers == null, true);
	view.pointer_up(x, y); // Also flushes the surviving queued binding.
	test::eq(removed.clicks, 0);
	test::eq(removed.evaluations, 2);
	test::eq(kept.evaluations, 2);
	test::eq(view.first, survivor);
	test::eq(view.pending_head == null && view.pending_tail == null, true);
	test::eq(view.take_damage().empty(), false);
	removed.state.set(2);
	kept.state.set(2);
	view.free();
	test::eq(kept.state.signal.subscribers == null, true);
	kept.state.set(3);
}

fn void clipping_before_release_or_keyboard_activation_prevents_clicks() @test
{
	View view;
	defer view.free();
	LayoutProbe probe;
	view.resize(300, 200);
	Widget* column = view.column();
	Widget* button = column.button("click", &layout_click, &probe);
	view.update();
	int x = button.visible.x + 1;
	int y = button.visible.y + 1;
	view.pointer_down(x, y);
	column.set_layout({ .width = 1 });
	view.pointer_up(x, y); // Flushes layout before consulting the previous press.
	test::eq(probe.clicks, 0);
	column.set_layout({ .width = 1, .padding = 1 });
	view.activate_focused();
	test::eq(probe.clicks, 0);
	test::eq(view.focused == null, true);
	column.set_layout({});
	view.focus_next();
	test::eq(view.focused, button);
	column.set_enabled(false);
	view.activate_focused();
	test::eq(probe.clicks, 0);
}

fn void reparenting_at_identical_bounds_repaints_inherited_enabled_state() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* disabled = view.column();
	Widget* button = disabled.button("move", null);
	disabled.set_enabled(false);
	view.update();
	Rect before = button.bounds;
	view.take_damage();
	test::eq(view.append(button), true);
	view.update();
	expect_rect(button.bounds, before.x, before.y, before.width, before.height);
	test::eq(button.is_enabled(), true);
	test::eq(view.take_damage().empty(), false);
	test::eq(view.hit_test(before.x, before.y), button);
}

fn void nested_paint_only_changes_do_not_dirty_layout_or_metrics() @test
{
	View view;
	defer view.free();
	LayoutProbe probe;
	view.set_measurer(&layout_metrics, &probe);
	view.resize(300, 200);
	Widget* column = view.column({ .padding = 4 });
	Widget* row = column.row({ .gap = 3 });
	Widget* button = row.button("click", &layout_click, &probe);
	view.update();
	view.take_damage();
	view.pointer_move(button.visible.x, button.visible.y);
	view.focus_next();
	column.set_enabled(false);
	test::eq(view.measure_dirty || view.layout_dirty || view.subtree_layout_dirty, false);
	test::eq(column.measure_dirty || column.layout_dirty || column.subtree_layout_dirty, false);
	test::eq(row.measure_dirty || row.layout_dirty || row.subtree_layout_dirty, false);
	view.update();
	test::eq(probe.measurements, 1);
	test::eq(probe.clicks, 0);
	view.take_damage();
	column.set_layout(column.layout);
	row.append(button); // Already last: no invalidation.
	view.update();
	test::eq(view.take_damage().empty(), true);
	test::eq(probe.measurements, 1);
}

fn void remove_clicked_ancestor(void* context) @private
{
	Widget* container = context;
	container.remove();
}

fn void nested_callbacks_can_remove_their_ancestors() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	Widget* column = view.column();
	Widget* row = column.row();
	Widget* button = row.button("remove", &remove_clicked_ancestor, column);
	view.update();
	int x = button.visible.x;
	int y = button.visible.y;
	view.pointer_down(x, y);
	view.pointer_up(x, y);
	view.update();
	test::eq(view.first == null && view.last == null, true);
	test::eq(view.focused == null && view.hovered == null && view.pressed == null, true);
}

fn void extreme_layout_sizes_saturate_and_zero_viewports_clip_everything() @test
{
	View view;
	defer view.free();
	view.resize(LAYOUT_LIMIT, LAYOUT_LIMIT);
	view.set_root_spacing(0, 0);
	Widget* row = view.row({ .gap = LAYOUT_LIMIT, .padding = LAYOUT_LIMIT });
	Widget* first = row.button("first", null);
	Widget* second = row.button("second", null);
	first.set_layout({ .width = LAYOUT_LIMIT, .height = LAYOUT_LIMIT });
	second.set_layout({ .width = LAYOUT_LIMIT, .height = LAYOUT_LIMIT });
	view.update();
	test::eq(row.desired.width, LAYOUT_LIMIT);
	test::eq(row.desired.height, LAYOUT_LIMIT);
	test::eq(second.bounds.x, LAYOUT_LIMIT);
	test::eq(first.visible.empty() && second.visible.empty(), true);
	view.resize(0, 0);
	view.update();
	test::eq(row.visible.empty(), true);
	test::eq(view.take_damage().empty(), true);
	view.focus_next();
	test::eq(view.focused == null, true);
}
