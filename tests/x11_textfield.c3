module ui::backend @feat(LINUX);
import std::core::test;

fn void field_xkey(XCanvas* canvas, View* view, char code, ushort modifiers = 0) @private
{
	char[32] event;
	event[0] = 2;
	event[1] = code;
	write32(event[..], 12, canvas.setup.window);
	write16(event[..], 28, modifiers);
	canvas.event(view, event[..])!!;
}

fn void x11_textfield_shift_caps_unicode_and_control_commands() @test
{
	char[64] keys;
	uint[16] symbols = { 'a', 'A', 0, 0, '1', '!', 0, 0,
		0xe9, 0xc9, 0x01004e16, 0x01004e16, 0xff08, 0xff08, 0, 0 };
	foreach (i, symbol : symbols) write32(keys[..], i * 4, symbol);
	XCanvas canvas = { .setup = { .window = 77, .min_keycode = 20, .max_keycode = 23 },
		.keymap = keys[..], .keysyms_per_key = 4 };
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field();
	view.focus_next();
	field_xkey(&canvas, &view, 20);
	field_xkey(&canvas, &view, 20, 1);
	field_xkey(&canvas, &view, 20, 2);
	field_xkey(&canvas, &view, 20, 3);
	field_xkey(&canvas, &view, 21, 1);
	field_xkey(&canvas, &view, 22);
	field_xkey(&canvas, &view, 22, 128);
	test::eq(field.get_text(), "aAAa!é世");
	field_xkey(&canvas, &view, 21, 4); // Shortcut cannot insert text.
	field_xkey(&canvas, &view, 21, 8);
	test::eq(field.get_text(), "aAAa!é世");
	field_xkey(&canvas, &view, 20, 4); // Ctrl-A selects all.
	test::eq(field.selection().anchor, 0);
	test::eq(field.selection().caret, 10);
	field_xkey(&canvas, &view, 23);
	test::eq(field.get_text(), "");
}
