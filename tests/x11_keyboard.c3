module ui::backend @feat(LINUX);
import std::core::test;

fn void xkey(XCanvas* canvas, View* view, uint kind, char code, uint time, bool shift = false) @private
{
	char[32] event;
	event[0] = (char)kind;
	event[1] = code;
	write32(event[..], 4, time);
	write32(event[..], 12, canvas.setup.window);
	write16(event[..], 28, shift ? 1 : 0);
	canvas.event(view, event[..])!!;
}

fn void x11_scroll_keys_repeat_pairs_and_keypad_navigation() @test
{
	uint[8] symbols = { 0xff56, 0xff55, 0xff57, 0xff50, 0xff9b, 0xff9a, 0xff9c, 0xff95 };
	char[32] keys;
	foreach (i, symbol : symbols) write32(keys[..], i * 4, symbol);
	XCanvas canvas = { .setup = { .window = 77, .min_keycode = 20, .max_keycode = 27 },
		.keymap = keys[..], .keysyms_per_key = 1 };
	View view;
	defer view.free();
	view.resize(300, 200);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.button("tall").set_layout({ .height = 240 });
	view.focus_next();
	for (char base = 20; base <= 24; base += 4)
	{
		xkey(&canvas, &view, 2, base, 100);
		test::eq(panel.scroll_offset(), 50);
		xkey(&canvas, &view, 3, base, 110);
		xkey(&canvas, &view, 2, base, 110); // Core autorepeat still scrolls.
		test::eq(panel.scroll_offset(), 100);
		xkey(&canvas, &view, 3, base, 120);
		test::eq(view.held_keys[base], false);
		xkey(&canvas, &view, 2, base + 1, 130);
		test::eq(panel.scroll_offset(), 50);
		xkey(&canvas, &view, 2, base + 2, 140);
		test::eq(panel.scroll_offset(), 190);
		xkey(&canvas, &view, 2, base + 3, 150);
		test::eq(panel.scroll_offset(), 0);
	}
}

fn void x11_repeat_pairs_real_cycles_focus_and_mapping_identity() @test
{
	char[16] keys;
	write32(keys[..], 0, 0xff09);
	write32(keys[..], 4, 0x20);
	write32(keys[..], 8, 0xff0d);
	XCanvas canvas = { .setup = { .window = 77, .min_keycode = 20, .max_keycode = 23 },
		.keymap = keys[..], .keysyms_per_key = 1 };
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* first = view.checkbox("first");
	Widget* second = view.checkbox("second");
	xkey(&canvas, &view, 2, 20, 100);
	xkey(&canvas, &view, 3, 20, 101);
	xkey(&canvas, &view, 2, 21, 110);
	xkey(&canvas, &view, 2, 21, 120); // Detectable-style repeat (no release).
	xkey(&canvas, &view, 3, 21, 130);
	xkey(&canvas, &view, 2, 21, 130); // Core repeat pair.
	test::eq(first.is_checked(), true);
	xkey(&canvas, &view, 3, 21, 140);
	xkey(&canvas, &view, 2, 21, 150); // Real release/new press.
	test::eq(first.is_checked(), false);
	xkey(&canvas, &view, 2, 20, 160);
	xkey(&canvas, &view, 3, 21, 170);
	xkey(&canvas, &view, 2, 21, 170);
	test::eq(second.is_checked(), false);
	// A mapping edit while held does not change the physical key's lifetime.
	write32(keys[..], 4, 0xff0d);
	xkey(&canvas, &view, 2, 21, 180);
	test::eq(second.is_checked(), false);
	xkey(&canvas, &view, 3, 21, 190);
	xkey(&canvas, &view, 2, 21, 200);
	test::eq(second.is_checked(), true);
	char[32] focus;
	focus[0] = 10;
	write32(focus[..], 4, 77);
	canvas.event(&view, focus[..])!!;
	test::eq(view.focused == null && !view.held_keys[21], true);
	focus = {};
	focus[0] = 11; // Held-key bitmap delivered on refocus.
	focus[21 / 8] = 1 << (21 % 8);
	canvas.event(&view, focus[..])!!;
	view.focus_next();
	xkey(&canvas, &view, 2, 21, 210);
	test::eq(first.is_checked(), false);
	xkey(&canvas, &view, 3, 21, 220);
	xkey(&canvas, &view, 2, 21, 230);
	test::eq(first.is_checked(), true);
	xkey(&canvas, &view, 2, 20, 240, true);
	test::eq(view.focused, second);
}

fn void x11_mapping_notify_validates_range_and_ignores_pointer_changes() @test
{
	XCanvas canvas = { .setup = { .min_keycode = 8, .max_keycode = 255 } };
	View view;
	char[32] event;
	event[0] = 34;
	event[4] = 2; // No connection needed for pointer mappings.
	canvas.event(&view, event[..])!!;
	event[4] = 3;
	test::@error(canvas.event(&view, event[..]), ui::PROTOCOL_ERROR);
	event[4] = 1;
	event[5] = 7;
	event[6] = 1;
	test::@error(canvas.event(&view, event[..]), ui::PROTOCOL_ERROR);
	event[5] = 8;
	event[6] = 0;
	test::@error(canvas.event(&view, event[..]), ui::PROTOCOL_ERROR);
	event[5] = 255;
	event[6] = 2;
	test::@error(canvas.event(&view, event[..]), ui::PROTOCOL_ERROR);
}

extern fn int socketpair(int domain, int type, int protocol, int* sockets);

fn void x11_live_mapping_storage_queue_sequence_wrap_and_failure_cleanup() @test
{
	for (int mode = 0; mode < 3; mode++)
	{
		int[2] sockets;
		int result = socketpair(1, 1, 0, &sockets[0]);
		test::eq(result, 0);
		defer (void)close(sockets[0]);
		defer (void)close(sockets[1]);
		XConnection connection = { .fd = sockets[0], .sequence = 65535 };
		XCanvas canvas = { .connection = &connection, .setup = { .min_keycode = 20, .max_keycode = 22 },
			.keysyms_per_key = 1, .keymap = ((char*)mem::malloc(12))[:12] };
		defer canvas.dispose();
		write32(canvas.keymap, 0, 0xff09);
		char* old = canvas.keymap.ptr;
		// Two core events and a variable-length extension before the reply.
		char[32] event;
		event[0] = 12;
		send_all(sockets[1], event[..])!!;
		event[0] = 10;
		send_all(sockets[1], event[..])!!;
		char[36] extension;
		extension[0] = 35;
		write32(extension[..], 4, 1);
		send_all(sockets[1], extension[..])!!;
		char[56] reply;
		reply[0] = 1;
		reply[1] = 2;
		write32(reply[..], 4, 6);
		write32(reply[..], 32, 0x20);
		if (mode == 1) reply[1] = 0;
		if (mode == 2) write16(reply[..], 2, 65535); // Wrong request, not keyboard data.
		send_all(sockets[1], reply[..])!!;
		if (mode)
		{
			test::@error(canvas.refresh_keymap(), ui::PROTOCOL_ERROR);
			test::eq(canvas.keymap.ptr, old);
			test::eq(read32(canvas.keymap, 0), 0xff09u);
			// dispose() frees both the original mapping and the pending events.
		}
		else
		{
			canvas.refresh_keymap()!!;
			test::eq(connection.sequence, (ushort)0);
			test::eq(canvas.keysyms_per_key, 2u);
			test::eq(canvas.keymap.len, 24);
			test::eq(read32(canvas.keymap, 0), 0x20u);
			test::eq(canvas.queued_events, 2u);
			char[32] first = canvas.next_event()!!;
			char[32] second = canvas.next_event()!!;
			test::eq(first[0], (char)12);
			test::eq(second[0], (char)10);
			test::eq(canvas.queued_events, 0u);
		}
	}
}
