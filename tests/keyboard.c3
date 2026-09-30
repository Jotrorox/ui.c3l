module ui;
import std::core::test;

fn void key_click(void* context) @private { int* count = context; (*count)++; }

fn void keyboard_initial_press_repeat_release_and_explicit_activation() @test
{
	View view;
	defer view.free();
	int clicks;
	view.resize(400, 300);
	view.button("button", &key_click, &clicks);
	Widget* check = view.checkbox("check");
	view.focus_next();
	view.key_down(13, ACTIVATE);
	view.key_down(13, ACTIVATE);
	view.key_down(13, ACTIVATE, repeat: true);
	test::eq(clicks, 1);
	view.key_up(13);
	view.key_down(13, ACTIVATE);
	test::eq(clicks, 2);
	view.focus_next(); // Holding Return must not activate the new focus.
	view.key_down(13, ACTIVATE);
	test::eq(check.is_checked(), false);
	view.key_up(13);
	view.key_down(13, ACTIVATE);
	view.key_down(13, ACTIVATE, repeat: true);
	test::eq(check.is_checked(), true);
	view.key_up(13);
	view.key_down(13, ACTIVATE);
	test::eq(check.is_checked(), false);
	view.key_down(32, ACTIVATE); // Space and Return have independent lifetimes.
	test::eq(check.is_checked(), true);
	view.activate_focused(); // Explicit activation does not depend on native keys.
	test::eq(check.is_checked(), false);
}

fn void held_keys_survive_ineligible_controls_and_widget_focus_changes() @test
{
	for (int mode = 0; mode < 3; mode++)
	{
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* branch = view.column();
		Widget* check = branch.checkbox("first");
		Widget* next = view.checkbox("second");
		view.focus_next();
		view.key_down(32, ACTIVATE);
		if (mode == 0) branch.set_enabled(false);
		if (mode == 1) branch.set_visible(false);
		if (mode == 2)
		{
			bool valid = branch.set_layout({ .width = 1, .padding = 1 });
			test::eq(valid, true);
		}
		view.key_down(32, ACTIVATE);
		test::eq(view.focused == null, true);
		view.focus_next();
		test::eq(view.focused, next);
		view.key_down(32, ACTIVATE);
		test::eq(next.is_checked(), false);
		view.key_up(32);
		view.key_down(32, ACTIVATE);
		test::eq(next.is_checked(), true);
		test::eq(check.is_checked(), true);
	}
}

fn void keyboard_blur_missing_initial_press_and_tab_repeat() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* first = view.checkbox("first");
	Widget* second = view.checkbox("second");
	view.key_down(9, TAB);
	test::eq(view.focused, first);
	view.key_down(9, TAB, repeat: true);
	test::eq(view.focused, second);
	view.key_down(9, TAB, repeat: true, reverse: true);
	test::eq(view.focused, first);
	view.key_down(32, ACTIVATE);
	view.blur();
	test::eq(view.held_keys[32], false);
	view.focus_next();
	view.key_down(32, ACTIVATE, repeat: true); // Native repeat metadata after refocus.
	test::eq(first.is_checked(), true);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), false);
	view.blur(); // A release outside the window cannot leave stale held state.
	view.focus_next();
	view.key_down(32, ACTIVATE);
	test::eq(first.is_checked(), true);
}

fn void keyboard_bound_checkbox_preserves_state_ownership_and_cleanup() @test
{
	CheckProbe probe;
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* branch = view.column();
	probe.widget = branch.checkbox("bound", on_change: &changed_check, context: &probe);
	probe.widget.bind_checked(&bool_value, &probe.value);
	Binding* binding = probe.widget.checked_binding;
	view.focus_next();
	view.key_down(32, ACTIVATE);
	view.key_down(32, ACTIVATE);
	test::eq(probe.changes, 1);
	test::eq(probe.widget.is_checked(), false);
	test::eq(probe.widget.checked_binding, binding);
	probe.accept = true;
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	view.update();
	test::eq(probe.widget.is_checked(), true);
	test::eq(probe.widget.checked_binding, binding);
	probe.remove = branch;
	view.key_up(32);
	view.key_down(32, ACTIVATE); // Removes ancestor and queued checked binding.
	test::eq(probe.changes, 3);
	test::eq(view.focused == null && view.pending_head == null && probe.value.signal.subscribers == null, true);
	Widget* replacement = view.checkbox("replacement");
	view.focus_next();
	view.key_down(32, ACTIVATE);
	test::eq(replacement.is_checked(), false);
	view.key_up(32);
	view.key_down(32, ACTIVATE);
	test::eq(replacement.is_checked(), true);
}

fn void key_remove(void* context) @private { Widget** widget = context; (*widget).remove(); }

fn void keyboard_button_callback_can_remove_itself() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* button;
	button = view.button("remove", &key_remove, &button);
	Widget* next = view.checkbox("next");
	view.focus_next();
	view.key_down(13, ACTIVATE);
	test::eq(view.focused == null, true);
	view.focus_next();
	view.key_down(13, ACTIVATE);
	test::eq(next.is_checked(), false);
	view.key_up(13);
	view.key_down(13, ACTIVATE);
	test::eq(next.is_checked(), true);
}
