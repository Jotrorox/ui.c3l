module ui;
import std::core::test;

struct AlignmentUpdateProbe
{
	State{int} value;
	int evaluations;
	int measurements;
	int clicks;
}

fn Size alignment_update_metrics(void* context, String text) @private
{
	AlignmentUpdateProbe* probe = context;
	probe.measurements++;
	return { (int)text.len * 8, text == "tall" ? 32 : 16 };
}

fn String alignment_update_label(void* context) @private
{
	AlignmentUpdateProbe* probe = context;
	probe.evaluations++;
	return probe.value.get() ? "tall" : "a";
}

fn void alignment_update_click(void* context) @private
{
	AlignmentUpdateProbe* probe = context;
	probe.clicks++;
}

fn void alignment_update_rect(Rect rect, int x, int y, int width, int height) @private
{
	test::eq(rect.x, x);
	test::eq(rect.y, y);
	test::eq(rect.width, width);
	test::eq(rect.height, height);
}

fn void alignment_update_damage(Rect damage, Rect visible) @private
{
	Rect covered = damage.intersect(visible);
	alignment_update_rect(covered, visible.x, visible.y, visible.width, visible.height);
}

fn void alignment_only_updates_and_resizing_skip_measurement() @test
{
	View view;
	defer view.free();
	AlignmentUpdateProbe probe;
	view.resize(400, 300);
	view.set_root_spacing(0, 0);
	view.set_measurer(&alignment_update_metrics, &probe);
	Widget* outer = view.column({ .width = 300, .height = 160 });
	Widget* row = outer.row({ .width = 200, .height = 80, .padding = 2, .gap = 4 });
	Widget* label = row.text("a");
	Widget* button = row.button("b");
	view.update();
	view.take_damage();
	alignment_update_rect(label.bounds, 2, 2, 8, 16);
	alignment_update_rect(button.bounds, 14, 2, 32, 32);

	Layout layout = row.layout;
	layout.main_align = CENTER;
	layout.cross_align = END;
	test::eq(row.set_layout(layout), true);
	test::eq(view.measure_dirty || outer.measure_dirty || row.measure_dirty ||
		label.measure_dirty || button.measure_dirty || label.text_dirty || button.text_dirty, false);
	view.update();
	alignment_update_rect(label.bounds, 78, 62, 8, 16);
	alignment_update_rect(button.bounds, 90, 46, 32, 32);
	test::eq(row.desired.width, 200);
	test::eq(row.desired.height, 80);

	layout = outer.layout;
	layout.main_align = END;
	layout.cross_align = CENTER;
	test::eq(outer.set_layout(layout), true);
	test::eq(view.measure_dirty || outer.measure_dirty || row.measure_dirty, false);
	view.update();
	alignment_update_rect(label.bounds, 128, 142, 8, 16);
	alignment_update_rect(button.bounds, 140, 126, 32, 32);
	test::eq(view.set_root_alignment(END, END), true);
	test::eq(view.measure_dirty || outer.measure_dirty || row.measure_dirty, false);
	view.update();
	alignment_update_rect(outer.bounds, 100, 140, 300, 160);
	alignment_update_rect(label.bounds, 228, 282, 8, 16);
	alignment_update_rect(button.bounds, 240, 266, 32, 32);
	view.resize(500, 400);
	test::eq(view.measure_dirty || outer.measure_dirty || row.measure_dirty, false);
	view.update();
	alignment_update_rect(outer.bounds, 200, 240, 300, 160);
	test::eq(probe.measurements, 2);

	// Spacing and alignment setters preserve one another's independent state.
	test::eq(view.set_root_spacing(10, 3), true);
	view.update();
	alignment_update_rect(outer.bounds, 190, 230, 300, 160);
	test::eq(view.set_root_alignment(), true);
	view.update();
	alignment_update_rect(outer.bounds, 10, 10, 300, 160);
	view.take_damage();
	test::eq(view.set_root_alignment(), true);
	test::eq(row.set_layout(row.layout), true);
	test::eq(outer.set_layout(outer.layout), true);
	test::eq(view.layout_dirty || view.subtree_layout_dirty || view.measure_dirty, false);
	view.update();
	test::eq(view.take_damage().empty(), true);
	test::eq(probe.measurements, 2);
}

fn void invalid_alignment_edits_leave_options_geometry_and_dirty_flags_unchanged() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(5, 7);
	view.set_root_alignment(END, END);
	Widget* row = view.row({ .width = 100, .height = 60, .padding = 3,
		.gap = 2, .main_align = CENTER, .cross_align = END });
	Widget* text = row.text("a");
	Widget* button = row.button("b");
	Widget* check = row.checkbox("c");
	view.update();
	Rect before = row.bounds;
	view.take_damage();
	Layout bad = row.layout;
	bad.width = 90;
	bad.padding = 7;
	bad.main_align = STRETCH;
	test::eq(row.set_layout(bad), false);
	test::eq(row.layout.width, 100);
	test::eq(row.layout.padding, 3);
	test::eq(row.layout.gap, 2);
	test::eq(row.layout.main_align, Alignment.CENTER);
	test::eq(row.layout.cross_align, Alignment.END);
	test::eq(view.set_root_alignment(STRETCH, START), false);
	// bitcast copies the enum's underlying storage without the checked
	// integer-to-enum conversion trapping before the setters can validate it.
	foreach (int value : { -1, 4, int::max })
	{
		$Typefrom(Alignment::inner) raw = value;
		Alignment unknown = bitcast(raw, Alignment);
		bad = row.layout;
		bad.main_align = unknown;
		test::eq(row.set_layout(bad), false);
		bad = row.layout;
		bad.cross_align = unknown;
		test::eq(row.set_layout(bad), false);
		test::eq(view.set_root_alignment(unknown, START), false);
		test::eq(view.set_root_alignment(START, unknown), false);
	}
	test::eq(row.layout.main_align, Alignment.CENTER);
	test::eq(row.layout.cross_align, Alignment.END);
	test::eq(view.root_main_align, Alignment.END);
	test::eq(view.root_cross_align, Alignment.END);
	foreach (Widget* leaf : { text, button, check })
	{
		foreach (Alignment alignment : { CENTER, END, STRETCH })
		{
			test::eq(leaf.set_layout({ .width = 90, .main_align = alignment }), false);
			test::eq(leaf.set_layout({ .height = 90, .cross_align = alignment }), false);
			test::eq(leaf.layout.width, 0);
			test::eq(leaf.layout.height, 0);
			test::eq(leaf.layout.main_align, Alignment.START);
			test::eq(leaf.layout.cross_align, Alignment.START);
			test::eq(leaf.measure_dirty || leaf.layout_dirty || leaf.text_dirty, false);
		}
	}
	test::eq(view.measure_dirty || view.layout_dirty || view.subtree_layout_dirty, false);
	test::eq(row.measure_dirty || row.layout_dirty || row.subtree_layout_dirty, false);
	view.update();
	alignment_update_rect(row.bounds, before.x, before.y, before.width, before.height);
	test::eq(view.take_damage().empty(), true);
	view.resize(320, 220);
	view.update();
	alignment_update_rect(row.bounds, 215, 155, 100, 60);
}

fn void stretch_replaces_equal_desired_explicit_and_maximum_sizes_in_both_axes() @test
{
	for (int axis = 0; axis < 2; axis++)
	{
		View view;
		defer view.free();
		AlignmentUpdateProbe probe;
		view.resize(300, 300);
		view.set_root_spacing(0, 0);
		view.set_measurer(&alignment_update_metrics, &probe);
		Widget* fixed = view.column({ .width = 200, .height = 200 });
		Layout parent_layout = { .width = 100, .height = 100, .cross_align = STRETCH };
		Widget* parent = axis ? fixed.column(parent_layout) : fixed.row(parent_layout);
		Widget* label = parent.text("a");
		Layout explicit_size;
		if (axis) { explicit_size.width = 8; } else { explicit_size.height = 16; }
		test::eq(label.set_layout(explicit_size), true);
		view.update();
		alignment_update_rect(label.bounds, 0, 0, 8, 16);
		view.take_damage();
		test::eq(label.set_layout({}), true);
		view.update();
		alignment_update_rect(label.bounds, 0, 0, axis ? 100 : 8, axis ? 16 : 100);
		test::eq(label.desired.width, 8);
		test::eq(label.desired.height, 16);
		test::eq(view.take_damage().empty(), false);
		Layout capped;
		if (axis) { capped.max_width = 40; } else { capped.max_height = 40; }
		test::eq(label.set_layout(capped), true);
		view.update();
		alignment_update_rect(label.bounds, 0, 0, axis ? 40 : 8, axis ? 16 : 40);
		test::eq(label.desired.width, 8);
		test::eq(label.desired.height, 16);
		if (axis) { capped.width = 8; } else { capped.height = 16; }
		test::eq(label.set_layout(capped), true);
		view.update();
		alignment_update_rect(label.bounds, 0, 0, 8, 16);
		test::eq(probe.measurements, 1);
	}
}

fn void root_stretch_replaces_equal_desired_explicit_and_maximum_sizes() @test
{
	View view;
	defer view.free();
	AlignmentUpdateProbe probe;
	view.resize(200, 100);
	view.set_root_spacing(0, 0);
	view.set_root_alignment(END, STRETCH);
	view.set_measurer(&alignment_update_metrics, &probe);
	Widget* label = view.text("a");
	test::eq(label.set_layout({ .width = 8 }), true);
	view.update();
	alignment_update_rect(label.bounds, 0, 84, 8, 16);
	test::eq(label.set_layout({}), true);
	view.update();
	alignment_update_rect(label.bounds, 0, 84, 200, 16);
	test::eq(label.set_layout({ .max_width = 40 }), true);
	view.update();
	alignment_update_rect(label.bounds, 0, 84, 40, 16);
	test::eq(label.desired.width, 8);
	view.resize(20, 100);
	view.update();
	alignment_update_rect(label.bounds, 0, 84, 20, 16);
	test::eq(label.set_layout({ .width = 8, .max_width = 40 }), true);
	view.update();
	alignment_update_rect(label.bounds, 0, 84, 8, 16);
	test::eq(probe.measurements, 1);
}

fn void reactive_sizes_recenter_fixed_ancestors_and_hidden_children_leave_no_gaps() @test
{
	View view;
	defer view.free();
	AlignmentUpdateProbe probe;
	view.resize(400, 200);
	view.set_root_spacing(0, 0);
	view.set_measurer(&alignment_update_metrics, &probe);
	Widget* row = view.row({ .width = 200, .height = 80, .padding = 4, .gap = 6,
		.main_align = CENTER, .cross_align = CENTER });
	Widget* label = row.text();
	label.bind(&alignment_update_label, &probe);
	Widget* button = row.button("b");
	Widget* footer = view.column({ .width = 20, .height = 20 });
	view.update();
	alignment_update_rect(label.bounds, 77, 32, 8, 16);
	alignment_update_rect(button.bounds, 91, 24, 32, 32);
	view.take_damage();
	Rect old_label = label.visible;
	Rect old_button = button.visible;
	probe.value.set(1);
	probe.value.set(2);
	view.update();
	alignment_update_rect(label.bounds, 65, 24, 32, 32);
	alignment_update_rect(button.bounds, 103, 24, 32, 32);
	alignment_update_rect(footer.bounds, 0, 80, 20, 20);
	test::eq(probe.evaluations, 2);
	test::eq(probe.measurements, 3);
	Rect damage = view.take_damage();
	alignment_update_damage(damage, old_label);
	alignment_update_damage(damage, old_button);
	alignment_update_damage(damage, label.visible);
	alignment_update_damage(damage, button.visible);
	label.set_visible(false);
	view.update();
	alignment_update_rect(button.bounds, 84, 24, 32, 32);
	probe.value.set(0);
	view.update();
	test::eq(probe.evaluations, 3);
	test::eq(probe.measurements, 3);
	label.set_visible(true);
	view.update();
	alignment_update_rect(label.bounds, 77, 32, 8, 16);
	alignment_update_rect(button.bounds, 91, 24, 32, 32);
	test::eq(probe.measurements, 4);
}

fn void aligned_reparenting_preserves_bindings_and_remeasures_only_changed_text() @test
{
	View view;
	defer view.free();
	AlignmentUpdateProbe probe;
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	view.set_measurer(&alignment_update_metrics, &probe);
	Widget* source = view.column({ .width = 100, .height = 80, .cross_align = END });
	Widget* destination = view.column({ .width = 200, .height = 80,
		.main_align = END, .cross_align = STRETCH });
	Widget* branch = source.column({ .gap = 2 });
	Widget* label = branch.text();
	label.bind(&alignment_update_label, &probe);
	Widget* button = branch.button("b");
	Binding* binding = label.binding;
	view.update();
	alignment_update_rect(branch.bounds, 68, 0, 32, 50);
	Rect old_button = button.visible;
	view.take_damage();
	test::eq(destination.append(branch), true);
	view.update();
	alignment_update_rect(branch.bounds, 0, 110, 200, 50);
	alignment_update_rect(label.bounds, 0, 110, 8, 16);
	alignment_update_rect(button.bounds, 0, 128, 32, 32);
	test::eq(branch.desired.width, 32);
	test::eq(label.binding, binding);
	test::eq(probe.evaluations, 1);
	test::eq(probe.measurements, 2);
	Rect damage = view.take_damage();
	alignment_update_damage(damage, old_button);
	alignment_update_damage(damage, button.visible);
	probe.value.set(1);
	test::eq(source.append(branch), true);
	view.update();
	alignment_update_rect(branch.bounds, 68, 0, 32, 66);
	alignment_update_rect(label.bounds, 68, 0, 32, 32);
	alignment_update_rect(button.bounds, 68, 34, 32, 32);
	test::eq(label.binding, binding);
	test::eq(probe.evaluations, 2);
	test::eq(probe.measurements, 3);
	test::eq(view.pending_head == null && view.pending_tail == null, true);
}

fn void alignment_moves_mouse_targets_and_damage_without_resetting_held_keys() @test
{
	View view;
	defer view.free();
	AlignmentUpdateProbe probe;
	view.resize(240, 120);
	view.set_root_spacing(0, 0);
	Widget* button = view.button("a", &alignment_update_click, &probe);
	Widget* check = view.checkbox("b");
	view.update();
	view.pointer_down(1, 1);
	test::eq(view.focused, button);
	view.key_down(32, ACTIVATE);
	test::eq(probe.clicks, 1);
	Rect old_button = button.visible;
	view.take_damage();
	test::eq(view.set_root_alignment(END, END), true);
	view.update();
	alignment_update_rect(button.bounds, 208, 64, 32, 32);
	test::eq(view.hovered == null, true);
	test::eq(view.focused, button);
	test::eq(view.hit_test(1, 1) == null, true);
	test::eq(view.hit_test(209, 65), button);
	Rect damage = view.take_damage();
	alignment_update_damage(damage, old_button);
	alignment_update_damage(damage, button.visible);
	view.pointer_up(1, 1);
	test::eq(probe.clicks, 1);
	view.key_down(32, ACTIVATE, repeat: true);
	test::eq(probe.clicks, 1);
	view.focus_next();
	test::eq(view.focused, check);
	view.key_down(32, ACTIVATE);
	test::eq(check.is_checked(), false);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(check.is_checked(), true);
	view.pointer_down(209, 65);
	view.pointer_up(209, 65);
	test::eq(probe.clicks, 2);
}

fn void alignment_clipping_cancels_pointer_and_focus_but_preserves_key_lifetime() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* viewport = view.row({ .width = 100, .height = 32 });
	Widget* oversized = viewport.row({ .width = 200, .height = 32 });
	Widget* first = oversized.checkbox("a");
	Widget* next = view.checkbox("b");
	view.update();
	view.pointer_down(1, 1);
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), true);
	Rect old_visible = first.visible;
	view.take_damage();
	Layout layout = oversized.layout;
	layout.main_align = END;
	test::eq(oversized.set_layout(layout), true);
	test::eq(view.measure_dirty || oversized.measure_dirty || viewport.measure_dirty, false);
	view.update();
	test::eq(first.visible.empty(), true);
	test::eq(view.hovered == null && view.pressed == null && view.focused == null, true);
	alignment_update_damage(view.take_damage(), old_visible);
	view.pointer_up(1, 1);
	test::eq(first.is_checked(), true);
	view.focus_next();
	test::eq(view.focused, next);
	view.key_down(32, ACTIVATE);
	test::eq(next.is_checked(), false);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(next.is_checked(), true);
	layout.main_align = START;
	test::eq(oversized.set_layout(layout), true);
	view.update();
	test::eq(view.hovered, first);
	view.focus_next(reverse: true);
	test::eq(view.focused, first);
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), true);
}
