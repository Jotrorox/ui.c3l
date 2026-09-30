module ui;
import std::core::test;

struct PropertyProbe
{
	State{int} shared;
	int[4] calls;
}

fn String property_label(void* context) @private
{
	PropertyProbe* probe = context;
	probe.calls[0]++;
	return probe.shared.get() % 2 ? "odd" : "even";
}
fn bool property_enabled(void* context) @private
{
	PropertyProbe* probe = context;
	probe.calls[1]++;
	return probe.shared.get() >= 0;
}
fn bool property_visible(void* context) @private
{
	PropertyProbe* probe = context;
	probe.calls[2]++;
	return probe.shared.get() >= 0;
}
fn bool property_checked(void* context) @private
{
	PropertyProbe* probe = context;
	probe.calls[3]++;
	// The duplicate read still creates only one edge for this property.
	return probe.shared.get() % 2 != 0 && probe.shared.get() > 0;
}
fn bool bool_value(void* context) @private
{
	State{bool}* value = context;
	return value.get();
}
fn int subscription_count(Signal* signal) @private
{
	int count;
	for (Dependency* edge = signal.subscribers; edge; edge = edge.source_next) count++;
	return count;
}
fn void bind_properties(Widget* widget, PropertyProbe* probe) @private
{
	widget.bind(&property_label, probe);
	widget.bind_enabled(&property_enabled, probe);
	widget.bind_visible(&property_visible, probe);
	widget.bind_checked(&property_checked, probe);
}

fn void properties_share_state_but_coalesce_independently() @test
{
	PropertyProbe probe;
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* check = view.checkbox();
	bind_properties(check, &probe);
	view.update();
	test::eq(subscription_count(&probe.shared.signal), 4);
	probe.shared.set(1);
	probe.shared.set(3);
	view.update();
	foreach (calls : probe.calls) test::eq(calls, 2);
	test::eq(view.first, check);
	test::eq(check.get_text(), "odd");
	test::eq(check.is_checked() && check.is_enabled() && check.is_visible(), true);
	test::eq(subscription_count(&probe.shared.signal), 4);
	probe.shared.set(3);
	view.update();
	foreach (calls : probe.calls) test::eq(calls, 2);
}

fn void property_setters_and_unbinds_only_detach_their_own_pending_work() @test
{
	for (int mode = 0; mode < 2; mode++)
	{
		for (int property = 0; property < 4; property++)
		{
			PropertyProbe probe;
			View view;
			defer view.free();
			Widget* check = view.checkbox();
			bind_properties(check, &probe);
			probe.shared.set(3);
			// All setters use the current value: equality must not prevent detach.
			switch (property)
			{
				case 0: if (mode) { check.unbind(); } else { check.set_text("even"); }
				case 1: if (mode) { check.unbind_enabled(); } else { check.set_enabled(true); }
				case 2: if (mode) { check.unbind_visible(); } else { check.set_visible(true); }
				case 3: if (mode) { check.unbind_checked(); } else { check.set_checked(false); }
			}
			test::eq(subscription_count(&probe.shared.signal), 3);
			view.update();
			for (int index = 0; index < 4; index++) test::eq(probe.calls[index], index == property ? 1 : 2);
			test::eq(check.get_text(), property == 0 ? "even" : "odd");
			test::eq(check.is_checked(), property != 3);
			test::eq(view.pending_head == null && view.pending_tail == null, true);
			probe.shared.set(5);
			view.free();
			test::eq(probe.shared.signal.subscribers == null, true);
		}
	}
}

fn void replacing_a_boolean_binding_leaves_the_other_properties_subscribed() @test
{
	PropertyProbe probe;
	State{bool} enabled;
	View view;
	defer view.free();
	Widget* check = view.checkbox();
	bind_properties(check, &probe);
	probe.shared.set(1);
	check.bind_enabled(&bool_value, &enabled);
	view.update();
	test::eq(subscription_count(&probe.shared.signal), 3);
	test::eq(subscription_count(&enabled.signal), 1);
	test::eq(probe.calls[1], 1);
	test::eq(check.is_enabled(), false);
	test::eq(check.get_text(), "odd");
	test::eq(check.is_checked(), true);
	enabled.set(true);
	view.update();
	test::eq(check.is_enabled(), true);
}

struct ConditionalBool
{
	State{bool} alternate;
	State{bool} first;
	State{bool} second;
	int calls;
}
fn bool conditional_bool(void* context) @private
{
	ConditionalBool* probe = context;
	probe.calls++;
	return probe.alternate.get() ? probe.second.get() : probe.first.get();
}
fn void boolean_dependencies_rebuild_even_when_the_output_is_equal() @test
{
	ConditionalBool probe;
	View view;
	defer view.free();
	Widget* check = view.checkbox();
	check.bind_checked(&conditional_bool, &probe);
	probe.alternate.set(true);
	view.update();
	test::eq(probe.calls, 2);
	test::eq(probe.first.signal.subscribers == null, true);
	probe.first.set(true);
	view.update();
	test::eq(probe.calls, 2);
	probe.second.set(true);
	probe.second.set(false);
	probe.second.set(true);
	view.update();
	test::eq(probe.calls, 3);
	test::eq(check.is_checked(), true);
}

fn void equal_property_results_leave_metrics_layout_and_damage_clean() @test
{
	PropertyProbe probe;
	MetricsTest metrics;
	View view;
	defer view.free();
	view.resize(400, 300);
	view.set_measurer(&test_measure, &metrics);
	Widget* parent = view.column({ .padding = 4 });
	Widget* check = parent.checkbox();
	bind_properties(check, &probe);
	view.update();
	view.take_damage();
	probe.shared.set(2);
	view.update();
	foreach (calls : probe.calls) test::eq(calls, 2);
	test::eq(metrics.measurements, 1);
	test::eq(view.take_damage().empty(), true);
	test::eq(view.measure_dirty || view.layout_dirty || view.subtree_layout_dirty, false);
	check.set_enabled(false);
	check.set_checked(true);
	test::eq(parent.measure_dirty || parent.layout_dirty || parent.subtree_layout_dirty, false);
	test::eq(check.measure_dirty || check.layout_dirty || check.text_dirty, false);
	test::eq(view.measure_dirty || view.layout_dirty || view.subtree_layout_dirty, false);
	view.update();
	test::eq(metrics.measurements, 1);
	test::eq(view.take_damage().empty(), false);
}

fn void multiple_pending_properties_are_cleaned_across_subtrees_and_views() @test
{
	PropertyProbe probe;
	View first, second;
	defer first.free();
	defer second.free();
	Widget* branch = first.column();
	Widget* a = branch.row().checkbox();
	Widget* b = branch.checkbox();
	Widget* survivor = first.checkbox();
	Widget* other = second.checkbox();
	bind_properties(a, &probe);
	bind_properties(b, &probe);
	bind_properties(survivor, &probe);
	bind_properties(other, &probe);
	test::eq(subscription_count(&probe.shared.signal), 16);
	probe.shared.set(1);
	branch.remove();
	test::eq(subscription_count(&probe.shared.signal), 8);
	first.update();
	foreach (calls : probe.calls) test::eq(calls, 5);
	test::eq(survivor.is_checked(), true);
	test::eq(other.is_checked(), false);
	first.free();
	test::eq(subscription_count(&probe.shared.signal), 4);
	second.update();
	test::eq(other.is_checked(), true);
	probe.shared.set(2);
	second.free();
	test::eq(probe.shared.signal.subscribers == null, true);
	probe.shared.set(3);
}

fn void collapsed_children_leave_no_padding_sizes_or_phantom_gaps() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	bool spacing = view.set_root_spacing(0, 5);
	test::eq(spacing, true);
	Widget* row = view.row({ .padding = 2, .gap = 3 });
	Widget* first = row.column({ .width = 10, .height = 10 });
	Widget* middle = row.column({ .padding = 7, .min_width = 30, .min_height = 40 });
	Widget* nested = middle.column({ .padding = 9 });
	nested.text("a");
	Widget* last = row.column({ .width = 10, .height = 10 });
	Widget* footer = view.text("footer");
	view.update();
	Size initial = row.desired;
	Rect middle_before = middle.visible;
	view.take_damage();
	middle.set_visible(false);
	view.update();
	test::eq(row.desired.width, 27);
	test::eq(row.desired.height, 14);
	test::eq(last.bounds.x, 15);
	test::eq(footer.bounds.y, 19);
	test::eq(nested.visible.empty() && !nested.is_visible(), true);
	test::eq(view.take_damage().intersect(middle_before).height, middle_before.height);
	first.set_visible(false);
	view.update();
	test::eq(last.bounds.x, 2);
	test::eq(row.desired.width, 14);
	last.set_visible(false);
	view.update();
	test::eq(row.desired.width, 4); // Only the still-visible parent's own padding.
	row.set_visible(false);
	view.update();
	test::eq(footer.bounds.y, 0); // No root gap for the hidden first child.
	middle.set_visible(true);
	nested.set_visible(true);
	view.update();
	test::eq(nested.is_visible(), false); // Cannot override the hidden ancestor.
	first.set_visible(true);
	last.set_visible(true);
	row.set_visible(true);
	view.update();
	test::eq(row.desired.width, initial.width);
	test::eq(row.desired.height, initial.height);
	test::eq(nested.is_visible(), true);
}

fn void hidden_updates_keep_subscriptions_and_measure_latest_content_on_restore() @test
{
	PropertyProbe probe;
	MetricsTest metrics;
	State{bool} shown = { .value = true };
	View view;
	defer view.free();
	view.resize(400, 300);
	view.set_measurer(&test_measure, &metrics);
	Widget* branch = view.column({ .gap = 3 });
	branch.bind_visible(&bool_value, &shown);
	Widget* nested = branch.row();
	Widget* check = nested.checkbox();
	bind_properties(check, &probe);
	Widget* below = view.text("below");
	view.update();
	int below_y = below.bounds.y;
	int measurements = metrics.measurements;
	shown.set(false);
	view.update();
	probe.shared.set(1);
	view.update();
	probe.shared.set(3); // Ancestors may already be clean despite dirty hidden leaves.
	view.update();
	test::eq(check.get_text(), "odd");
	test::eq(check.is_checked(), true);
	test::eq(check.is_visible(), false);
	test::eq(metrics.measurements, measurements);
	test::eq(subscription_count(&probe.shared.signal), 4);
	MetricsTest paint;
	Renderer renderer = { &paint, &test_fill, &test_text, &test_clip };
	view.paint(&renderer, { 0, 0, 400, 300 })!!;
	test::eq(paint.texts, 1);
	shown.set(true);
	view.update();
	test::eq(check.is_visible(), true);
	test::eq(check.visible.empty(), false);
	test::eq(check.text_size.width, 24);
	test::eq(metrics.measurements, measurements + 1);
	test::eq(below.bounds.y, below_y);
	shown.set(false);
	view.update();
	shown.set(true);
	view.update();
	test::eq(metrics.measurements, measurements + 1); // Unchanged restore reuses text metrics.
}

fn void reparenting_dirty_hidden_content_restores_measurement_and_placement() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* hidden = view.column();
	Widget* row = hidden.row();
	Widget* text = row.text("a");
	Widget* shown = view.column();
	view.update();
	hidden.set_visible(false);
	text.set_text("longer");
	view.update();
	bool moved = shown.append(row);
	test::eq(moved, true);
	view.update();
	test::eq(text.bounds.width, 48);
	test::eq(text.visible.empty(), false);
	test::eq(shown.desired.width, 48);
	moved = hidden.append(row);
	test::eq(moved, true);
	view.update();
	test::eq(text.visible.empty(), true);
}
