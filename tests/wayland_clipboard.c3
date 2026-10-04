module ui::backend @feat(LINUX);
import std::core::test, libc;

struct ClipboardWire
{
	uint serial;
	void* selected;
	uint next_id;
	int writer;
	String mime;
	int destroys;
}
ClipboardWire* clipboard_wire;
fn uint clipboard_version(void* proxy) @private => 1;
fn void clipboard_destroy(void* proxy) @private { clipboard_wire.destroys++; }
fn int clipboard_listen(void* proxy, WDispatch dispatch, void* context, void* data) @private => 0;
fn void* clipboard_marshal(void* proxy, uint opcode, WInterface* iface, uint version, uint flags, WArg* args) @private
{
	if (iface) return (void*)(uptr)++clipboard_wire.next_id;
	if (flags) { clipboard_wire.destroys++; return null; }
	if (proxy == (void*)2 && opcode == 1)
	{
		clipboard_wire.selected = args[0].o;
		clipboard_wire.serial = args[1].u;
	}
	if (proxy == (void*)3 && opcode == 1)
	{
		clipboard_wire.writer = clipboard_fcntl(args[1].i, 1030, 0); // F_DUPFD_CLOEXEC, like libwayland.
		clipboard_wire.mime = args[0].s.str_view();
	}
	return null;
}

fn void wayland_clipboard_publishes_with_serial_serves_snapshot_and_handles_closed_pipe() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("é👋");
	view.focus_next();
	field.select(6, 0);
	ClipboardWire wire = { .next_id = 100 };
	clipboard_wire = &wire;
	defer clipboard_wire = null;
	WInterface source_interface;
	WaylandWindow window = { .view = &view, .api = { .marshal = &clipboard_marshal,
		.version = &clipboard_version, .listen = &clipboard_listen, .destroy = &clipboard_destroy,
		.data_source = &source_interface }, .clipboard = { .manager = (void*)1, .device = (void*)2 } };
	defer window.dispose_clipboard();
	view.set_clipboard(&wayland_clipboard_write, &wayland_clipboard_read, &window);
	test::eq(view.clipboard_command(CUT), false); // A valid input serial is required.
	test::eq(field.get_text(), "é👋");
	window.clipboard.serial = 42;
	test::eq(view.clipboard_command(CUT), true);
	test::eq(field.get_text(), "");
	test::eq(wire.serial, 42u);
	test::eq(wire.selected, window.clipboard.sources.proxy);
	int[2] fds;
	test::eq(clipboard_pipe(&fds, 0x80000), 0);
	defer (void)close(fds[0]);
	WArg[2] send = { { .s = "text/plain;charset=utf-8" }, { .i = fds[1] } };
	window.clipboard_event(window.clipboard.sources.proxy, 1, &send)!!;
	window.send_clipboard();
	char[8] bytes;
	test::eq(libc::read(fds[0], &bytes[0], 8), 6);
	test::eq((String)bytes[:6], "é👋");
	test::eq(libc::read(fds[0], &bytes[0], 8), 0); // Source closes its end after sending.
	test::eq(window.clipboard.send_count, 0u);
	int[2] broken;
	test::eq(clipboard_pipe(&broken, 0x80000), 0);
	(void)close(broken[0]);
	send[1].i = broken[1];
	window.clipboard_event(window.clipboard.sources.proxy, 1, &send)!!;
	window.send_clipboard(); // Must survive EPIPE without changing SIGPIPE handling.
	test::eq(window.clipboard.send_count, 0u);
	window.clipboard_event(window.clipboard.sources.proxy, 2, null)!!;
	test::eq(window.clipboard.sources, (WSource*)null);
}

fn void wayland_clipboard_offer_transfer_waits_for_eof_and_rejects_invalid_or_stale_data() @test
{
	for (int mode = 0; mode < 5; mode++)
	{
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* field = view.text_field("old");
		view.focus_next();
		field.select(3, 0);
		ClipboardWire wire;
		clipboard_wire = &wire;
		defer clipboard_wire = null;
		WaylandWindow window = { .view = &view, .api = { .marshal = &clipboard_marshal,
			.version = &clipboard_version, .listen = &clipboard_listen, .destroy = &clipboard_destroy },
			.clipboard.device = (void*)2 };
		defer window.dispose_clipboard();
		view.set_clipboard(null, &wayland_clipboard_read, &window);
		WArg[1] offer = { { .o = (void*)3 } };
		window.event((void*)2, 0, &offer)!!;
		WArg[1] mime = { { .s = "text/plain;charset=UTF-8" } };
		window.event((void*)3, 0, &mime)!!;
		window.event((void*)2, 5, &offer)!!;
		view.clipboard_command(PASTE);
		test::eq(wire.mime, "text/plain;charset=UTF-8");
		test::eq(window.clipboard.reading, true);
		test::eq(libc::write(wire.writer, (void*)"\xc3", 1), 1);
		window.read_clipboard();
		test::eq(field.get_text(), "old");
		if (mode == 1) field.select(0, 0);
		if (mode == 2) window.clipboard.deadline = wayland_time() - 1;
		if (mode == 3)
		{
			char[4096] large;
			large[..] = 'x';
			test::eq(libc::write(wire.writer, &large[0], 4096), 4096);
		}
		else { test::eq(libc::write(wire.writer, (void*)(mode == 4 ? "\n" : "\xa9"), 1), 1); }
		(void)close(wire.writer);
		window.read_clipboard();
		test::eq(window.clipboard.reading, false);
		test::eq(field.get_text(), mode == 0 ? "é" : "old");
		if (mode >= 2) test::eq(field.selection().anchor, 3);
		offer[0].o = null;
		window.event((void*)2, 5, &offer)!!;
		test::eq(window.clipboard.offers, (WOffer*)null);
	}
}
