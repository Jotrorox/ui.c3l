module ui;
import std::core::test;

struct CheckProbe
{
	State{bool} value;
	Widget* widget;
	Widget* remove;
	int changes;
	bool proposed;
	bool accept;
	bool observed;
}
fn void changed_check(void* context, bool checked) @private
{
	CheckProbe* probe = context;
	probe.changes++;
	probe.proposed = checked;
	probe.observed = probe.widget.is_checked();
	if (probe.accept) probe.value.set(checked);
	if (probe.remove) probe.remove.remove();
}
fn void click_check(View* view, Widget* widget) @private
{
	view.update();
	int x = widget.visible.x + widget.visible.width / 2;
	int y = widget.visible.y + widget.visible.height / 2;
	view.pointer_down(x, y);
	view.pointer_up(x, y);
}

fn void checkbox_owns_unbound_state_and_emits_only_user_changes() @test
{
	CheckProbe probe;
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* check = view.row({ .padding = 5 }).checkbox("choice", false, &changed_check, &probe);
	probe.widget = check;
	view.update();
	check.set_checked(true);
	view.update();
	test::eq(probe.changes, 0);
	click_check(&view, check);
	test::eq(probe.changes, 1);
	test::eq(probe.proposed || probe.observed || check.is_checked(), false);
	view.activate_focused(); // Shared Space / Enter activation path.
	test::eq(probe.changes, 2);
	test::eq(probe.proposed && probe.observed && check.is_checked(), true);
	view.pointer_down(check.visible.x, check.visible.y);
	view.pointer_up(399, 299);
	test::eq(probe.changes, 2);
	Widget* owned = view.checkbox("no callback");
	view.focus_next();
	test::eq(view.focused, owned);
	view.activate_focused();
	test::eq(owned.is_checked(), true);
}

fn void bound_checkbox_proposes_without_overwriting_state_or_detaching() @test
{
	CheckProbe probe;
	MetricsTest metrics;
	View view;
	defer view.free();
	view.resize(400, 300);
	view.set_measurer(&test_measure, &metrics);
	Widget* check = view.checkbox("bound", false, &changed_check, &probe);
	probe.widget = check;
	check.bind_checked(&bool_value, &probe.value);
	view.update();
	Binding* binding = check.checked_binding;
	click_check(&view, check);
	test::eq(probe.changes, 1);
	test::eq(probe.proposed, true);
	test::eq(probe.observed || probe.value.get() || check.is_checked(), false);
	view.update(); // Application rejected the proposal by leaving State unchanged.
	test::eq(check.is_checked(), false);
	test::eq(check.checked_binding, binding);
	probe.accept = true;
	view.activate_focused();
	test::eq(probe.changes, 2);
	test::eq(probe.value.get(), true);
	test::eq(check.is_checked(), false); // Accepted state is applied on update.
	view.update();
	test::eq(check.is_checked(), true);
	test::eq(check.checked_binding, binding);
	probe.value.set(false);
	view.update();
	test::eq(probe.changes, 2); // Binding and programmatic updates are silent.
	test::eq(metrics.measurements, 1);
	check.unbind_checked();
	view.activate_focused();
	test::eq(check.is_checked(), true);
	test::eq(probe.observed, true); // Unbound state is applied before the callback.
}

fn void checkbox_visibility_cancels_input_and_reconciles_hover_on_moved_siblings() @test
{
	CheckProbe probe;
	View view;
	defer view.free();
	view.resize(400, 300);
	bool spacing = view.set_root_spacing(0, 0);
	test::eq(spacing, true);
	Widget* branch = view.column();
	Widget* nested = branch.row();
	Widget* check = nested.checkbox("first", false, &changed_check, &probe);
	probe.widget = check;
	Widget* next = view.checkbox("second");
	view.update();
	int x = check.visible.x + 1;
	int y = check.visible.y + 1;
	view.pointer_down(x, y);
	test::eq(view.focused == check && view.pressed == check && view.hovered == check, true);
	branch.set_visible(false);
	test::eq(view.focused == null && view.pressed == null && view.hovered == null, true);
	view.update();
	test::eq(view.hovered, next);
	view.pointer_up(x, y);
	test::eq(probe.changes, 0);
	test::eq(next.is_checked(), false);
	view.focus_next();
	test::eq(view.focused, next);
	branch.set_visible(true);
	view.update();
	test::eq(view.hovered, check);
	view.focus_next(reverse: true);
	test::eq(view.focused, check);
	view.pointer_down(x, y);
	branch.set_visible(false);
	branch.set_visible(true); // Even a transient imperative hide cancels the press.
	view.pointer_up(x, y);
	test::eq(probe.changes, 0);
}

fn void checkbox_inherited_disabled_state_and_clipping_cancel_pending_activation() @test
{
	State{bool} enabled = { .value = true };
	State{bool} shown = { .value = true };
	CheckProbe probe;
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* branch = view.column();
	branch.bind_enabled(&bool_value, &enabled);
	branch.bind_visible(&bool_value, &shown);
	Widget* check = branch.row().checkbox("choice", false, &changed_check, &probe);
	probe.widget = check;
	view.update();
	int x = check.visible.x + 1;
	int y = check.visible.y + 1;
	view.pointer_down(x, y);
	enabled.set(false);
	view.pointer_up(x, y); // Flushes Boolean bindings before targeting the release.
	test::eq(probe.changes, 0);
	test::eq(view.focused == null && view.pressed == null && view.hovered == null, true);
	check.set_enabled(true);
	test::eq(check.is_enabled(), false);
	enabled.set(true);
	view.focus_next();
	test::eq(view.focused, check);
	shown.set(false);
	view.activate_focused();
	test::eq(probe.changes, 0);
	shown.set(true);
	view.update();
	bool valid = branch.set_layout({ .width = 10 });
	test::eq(valid, true);
	view.update();
	test::eq(check.visible.width, 10);
	view.pointer_down(check.bounds.x + 11, y);
	view.pointer_up(check.bounds.x + 11, y);
	test::eq(probe.changes, 0);
	click_check(&view, check); // A partly clipped Checkbox can activate in its clip.
	test::eq(probe.changes, 1);
	view.pointer_down(x, y);
	valid = branch.set_layout({ .width = 1, .padding = 1 });
	test::eq(valid, true);
	view.pointer_up(x, y);
	view.focus_next();
	view.activate_focused();
	test::eq(probe.changes, 1);
	test::eq(view.focused == null, true);
}

fn void checkbox_callbacks_can_remove_self_or_ancestors_with_pending_bindings() @test
{
	for (int mode = 0; mode < 2; mode++)
	{
		CheckProbe probe = { .accept = true };
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* parent = view.column();
		Widget* check = parent.checkbox("remove", false, &changed_check, &probe);
		probe.widget = check;
		probe.remove = mode ? parent : check;
		check.bind_checked(&bool_value, &probe.value);
		check.bind_enabled(&bool_value, &probe.value);
		check.bind_visible(&bool_value, &probe.value);
		probe.value.set(true);
		view.update();
		if (mode) { view.focus_next(); view.activate_focused(); }
		else { click_check(&view, check); }
		test::eq(probe.changes, 1);
		test::eq(probe.value.signal.subscribers == null, true);
		test::eq(view.pending_head == null && view.pending_tail == null, true);
		test::eq(view.focused == null && view.pressed == null && view.hovered == null, true);
		view.update();
	}
}

struct CheckPaint
{
	Rect clip;
	Rect expected;
	int marks;
	int texts;
}
fn void? check_clip(void* context, Rect rect) @private
{
	CheckPaint* paint = context;
	paint.clip = rect;
}
fn void? check_fill(void* context, Rect rect, Ink ink) @private
{
	CheckPaint* paint = context;
	if (ink == INK && rect_equal(rect, paint.expected)) paint.marks++;
}
fn void? check_text(void* context, String text, int x, int y, Ink ink) @private
{
	CheckPaint* paint = context;
	paint.texts++;
}
fn void checkbox_shared_renderer_draws_checked_mark_and_respects_hidden_geometry() @test
{
	View view;
	defer view.free();
	MetricsTest metrics;
	view.resize(400, 300);
	view.set_measurer(&test_measure, &metrics);
	Widget* check = view.checkbox("choice");
	view.update();
	Rect before = check.bounds;
	CheckPaint paint = { .expected = { before.x + 8, before.y + (before.height - 16) / 2 + 4, 8, 8 } };
	Renderer renderer = { &paint, &check_fill, &check_text, &check_clip };
	view.paint(&renderer, view.take_damage())!!;
	test::eq(paint.marks, 0);
	check.set_checked(true);
	test::eq(view.measure_dirty || view.layout_dirty || view.subtree_layout_dirty, false);
	view.paint(&renderer, view.take_damage())!!;
	test::eq(paint.marks, 1);
	test::eq(rect_equal(check.bounds, before), true);
	test::eq(rect_equal(paint.clip, check.visible), true);
	test::eq(metrics.measurements, 1);
	check.set_visible(false);
	view.update();
	paint.texts = 0;
	view.paint(&renderer, view.take_damage())!!;
	test::eq(paint.texts, 0);
	check.set_visible(true);
	view.update();
	view.paint(&renderer, view.take_damage())!!;
	test::eq(paint.marks, 2);
	test::eq(metrics.measurements, 1);
}
