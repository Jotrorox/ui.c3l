module ui::backend @feat(LINUX);
import std::core::test;

fn uint scroll_test_keysym(void* state, uint code) @private { uint* symbol = state; return *symbol; }
fn int scroll_test_modifier(void* state, ZString name, uint mask) @private => 0;

fn void wayland_scroll_keys_schedule_repeat_and_stop_on_release() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.button("tall").set_layout({ .height = 240 });
	view.focus_next();
	uint symbol;
	WaylandWindow window = { .view = &view, .repeat_rate = 25, .repeat_delay = 500,
		.xkb = { .state = &symbol, .sym = &scroll_test_keysym, .mod_active = &scroll_test_modifier } };
	uint[8] symbols = { 0xff56, 0xff55, 0xff57, 0xff50, 0xff9b, 0xff9a, 0xff9c, 0xff95 };
	foreach (i, current : symbols)
	{
		symbol = current;
		window.key(109, true);
		test::eq(window.repeating, true);
		test::eq(window.repeat_key, 109u);
		if (i % 4 == 0)
		{
			test::eq(panel.scroll_offset(), 50);
			window.key(109, true, true);
			test::eq(panel.scroll_offset(), 100);
		}
		else if (i % 4 == 1) { test::eq(panel.scroll_offset(), 50); }
		else if (i % 4 == 2) { test::eq(panel.scroll_offset(), 190); }
		else { test::eq(panel.scroll_offset(), 0); }
		window.key(109, false);
		test::eq(window.repeating || view.held_keys[109], false);
	}
	window.repeat_rate = 0;
	symbol = 0xff56;
	window.key(109, true);
	test::eq(window.repeating, false);
}

fn void wayland_wheel_frames_preserve_fractional_pixels_and_count_detents_once() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* scroll = view.scroll_column({ .width = 200, .height = 80 });
	scroll.text("content").set_layout({ .height = 400 });
	view.update();
	WaylandWindow window = { .view = &view, .pointer_inside = true, .pointer_x = 30, .pointer_y = 30 };
	window.axis_fixed = 32;
	window.wheel();
	test::eq(scroll.scroll_offset(), 0);
	test::eq(window.wheel_remainder, 32);
	window.axis_fixed = 32;
	window.wheel();
	test::eq(scroll.scroll_offset(), 1);
	window.axis_fixed = 10 * 256;
	window.axis_discrete = 1;
	window.wheel();
	test::eq(scroll.scroll_offset(), 41);
	test::eq(window.axis_fixed, 0);
	test::eq(window.axis_discrete, 0);
	window.axis_fixed = -32;
	window.wheel();
	window.axis_fixed = -32;
	window.wheel();
	test::eq(scroll.scroll_offset(), 40);
	window.pointer_inside = false;
	window.axis_discrete = 1;
	window.wheel();
	test::eq(scroll.scroll_offset(), 40);
}

fn void wayland_keyboard_focus_enter_reconciles_held_keys_and_leave_blurs() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* button = view.button("Button");
	view.update();
	view.focus_next();
	WaylandWindow window = { .view = &view, .surface = (void*)1, .keyboard = (void*)2 };
	uint[3] keys = { 28, 57, 300 };
	WArray held = { .size = @sizeof(keys), .data = &keys };
	WArg[3] enter = { { .u = 1 }, { .o = window.surface }, { .a = &held } };
	window.event(window.keyboard, 1, &enter)!!;
	test::eq(view.held_keys[28], true);
	test::eq(view.held_keys[57], true);
	window.key(28, false);
	test::eq(view.held_keys[28], false);
	test::eq(view.focused, button);
	window.repeating = true;
	window.event(window.keyboard, 2, &enter)!!;
	test::eq(window.repeating, false);
	test::eq(view.focused, (Widget*)null);
	test::eq(view.held_keys[57], false);
}
