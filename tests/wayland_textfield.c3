module ui::backend @feat(LINUX);
import std::core::test;

struct FieldXkb { uint symbol; bool control; }
fn uint field_keysym(void* context, uint key) @private { FieldXkb* state = context; return state.symbol; }
fn int field_modifier(void* context, ZString name, uint mask) @private
{
	FieldXkb* state = context;
	return name.str_view() == "Control" && state.control ? 1 : 0;
}
fn int field_utf8(void* context, uint key, char* buffer, usz size) @private
{
	FieldXkb* state = context;
	if (state.symbol == 0x20) { buffer[0] = ' '; buffer[1] = 0; return 1; }
	buffer[0] = 0xc3;
	buffer[1] = 0xa9;
	buffer[2] = 0;
	return 2;
}
fn int field_compose_status(void* context) @private { int* status = context; return *status; }
fn void field_compose_reset(void* context) @private { int* status = context; *status = 0; }

fn void wayland_backspace_cancels_compose_before_deleting_committed_text() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("a");
	Widget* next = view.text_field("b");
	view.focus_next();
	FieldXkb state = { .symbol = 0xff08 };
	int composing = 1;
	WaylandWindow window = { .view = &view, .repeat_rate = 25,
		.xkb = { .state = &state, .sym = &field_keysym, .mod_active = &field_modifier,
			.compose_state = &composing, .compose_status = &field_compose_status,
			.compose_reset = &field_compose_reset, .compose_epoch = view.focus_epoch } };
	window.key(14, true);
	test::eq(field.get_text(), "a");
	test::eq(composing, 0);
	test::eq(window.repeating, false);
	window.key(14, false);
	window.key(14, true);
	test::eq(field.get_text(), "");
	composing = 1;
	view.focus_next();
	window.key(14, true); // Old composition is discarded, so this deletes "b".
	test::eq(next.get_text(), "");
}

fn void wayland_textfield_commits_layout_text_and_stops_repeat_after_focus_change() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field();
	Widget* next = view.text_field();
	view.focus_next();
	FieldXkb state = { .symbol = 0xe9 };
	WaylandWindow window = { .view = &view, .repeat_rate = 25, .repeat_delay = 500,
		.xkb = { .state = &state, .sym = &field_keysym, .mod_active = &field_modifier, .utf8 = &field_utf8 } };
	window.key(18, true);
	window.key(18, true, true);
	test::eq(field.get_text(), "éé");
	test::eq(window.repeating, true);
	view.focus_next();
	window.key(18, true, true);
	test::eq(next.get_text(), "");
	test::eq(window.repeating, false);
	window.key(18, false);
	state.symbol = 0x20;
	window.key(57, true);
	test::eq(next.get_text(), " ");
	state.control = true;
	state.symbol = 'a';
	window.key(30, true);
	test::eq(next.selection().anchor, 0);
	test::eq(next.selection().caret, 1);
	state.control = false;
	state.symbol = 0xff08;
	window.key(14, true);
	test::eq(next.get_text(), "");
}

fn void wayland_compose_keeps_preedit_out_of_committed_text() @test
{
	WXkb xkb;
	xkb.load()!!;
	defer xkb.dispose();
	if (!xkb.compose_state) return;
	(void)xkb.compose_feed(xkb.compose_state, 0xfe51); // dead_acute.
	test::eq(xkb.compose_status(xkb.compose_state), 1);
	(void)xkb.compose_feed(xkb.compose_state, 'e');
	test::eq(xkb.compose_status(xkb.compose_state), 2);
	char[8] buffer;
	int length = xkb.compose_utf8(xkb.compose_state, &buffer[0], @sizeof(buffer));
	test::eq((String)buffer[:length], "é");
}
