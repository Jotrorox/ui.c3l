module ui::backend @feat(LINUX);
import std::core::test;

extern fn int clipboard_socketpair(int domain, int type, int protocol, int[2]* fds) @cname("socketpair");

fn void clip_property_reply(int fd, ushort sequence, uint type, char format, char[] bytes, uint after = 0) @private
{
	char[32] header;
	header[0] = 1;
	header[1] = format;
	write16(header[..], 2, sequence);
	write32(header[..], 4, (uint)padded(bytes.len) / 4);
	write32(header[..], 8, type);
	write32(header[..], 12, after);
	write32(header[..], 16, format ? (uint)bytes.len / ((uint)format / 8) : 0);
	send_all(fd, header[..])!!;
	send_all(fd, bytes)!!;
	char[3] padding;
	send_all(fd, padding[:padded(bytes.len) - bytes.len])!!;
}

fn void x11_clipboard_direct_utf8_latin1_and_invalid_properties() @test
{
	foreach (i, String value : { "é👋", "\xe9", "\xff", "line\nbreak", "x" })
	{
		int[2] fds;
		test::eq(clipboard_socketpair(1, 1, 0, &fds), 0);
		defer (void)close(fds[0]);
		defer (void)close(fds[1]);
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* field = view.text_field("before");
		view.focus_next();
		field.select(6, 0);
		XConnection connection = { .fd = fds[0] };
		uint target = i == 1 ? 31 : 103;
		XCanvas canvas = { .view = &view, .connection = &connection, .setup.window = 77,
			.clipboard = { .pending = true, .property = 108, .target = target,
				.request = { view.focus_epoch, view.edit_epoch } } };
		defer canvas.dispose();
		clip_property_reply(fds[1], 1, target, 8, (char[])value, i == 4 ? 4 : 0);
		canvas.clipboard_property()!!;
		test::eq(field.get_text(), i == 0 ? "é👋" : i == 1 ? "é" : "before");
		if (i >= 2) test::eq(field.selection().anchor, 6);
		char[36] requests;
		receive_all(fds[1], requests[..])!!;
		test::eq(requests[0], (char)20);
		test::eq(requests[1], (char)0);
		test::eq(read32(requests[..], 20), 1024u);
		test::eq(requests[24], (char)19); // Explicit property cleanup.
	}
}

fn void x11_clipboard_incremental_split_utf8_is_atomic_and_bounded() @test
{
	for (int mode = 0; mode < 3; mode++)
	{
		int[2] fds;
		test::eq(clipboard_socketpair(1, 1, 0, &fds), 0);
		defer (void)close(fds[0]);
		defer (void)close(fds[1]);
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* field = view.text_field("old");
		view.focus_next();
		field.select(0, 3);
		XConnection connection = { .fd = fds[0] };
		XCanvas canvas = { .view = &view, .connection = &connection, .setup.window = 77,
			.clipboard = { .pending = true, .incr = 107, .property = 108, .target = 103,
				.request = { view.focus_epoch, view.edit_epoch } } };
		defer canvas.dispose();
		char[4] size;
		write32(size[..], 0, mode == 1 ? 4097 : 2);
		clip_property_reply(fds[1], 1, 107, 32, size[..]);
		canvas.clipboard_property()!!;
		test::eq(canvas.clipboard.incremental, true);
		if (mode == 2) field.select(3, 3); // A changed selection cancels the eventual edit.
		clip_property_reply(fds[1], 3, 103, 8, (char[])"\xc3");
		canvas.clipboard_property()!!;
		test::eq(field.get_text(), "old");
		clip_property_reply(fds[1], 4, 103, 8, (char[])"\xa9");
		canvas.clipboard_property()!!;
		test::eq(field.get_text(), "old");
		clip_property_reply(fds[1], 5, 103, 8, {});
		canvas.clipboard_property()!!;
		test::eq(canvas.clipboard.pending, false);
		test::eq(field.get_text(), mode == 0 ? "é" : "old");
		char[108] requests;
		receive_all(fds[1], requests[..])!!;
		test::eq(requests[1], (char)0); // Read INCR header without deleting twice.
		test::eq(requests[24], (char)19);
		test::eq(requests[37], (char)1); // Subsequent GetProperty acknowledges chunks.
	}
}

fn void x11_clipboard_ownership_serves_targets_and_unicode_after_cut() @test
{
	int[2] fds;
	test::eq(clipboard_socketpair(1, 1, 0, &fds), 0);
	defer (void)close(fds[0]);
	defer (void)close(fds[1]);
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("é👋");
	view.focus_next();
	field.select(6, 0);
	XConnection connection = { .fd = fds[0] };
	XCanvas canvas = { .view = &view, .connection = &connection, .setup.window = 77,
		.clipboard = { .selection = 104, .utf8 = 103, .targets = 105, .timestamp = 106, .time = 50 } };
	defer canvas.dispose();
	view.set_clipboard(&x11_clipboard_write, &x11_clipboard_read, &canvas);
	char[32] owner;
	owner[0] = 1;
	write16(owner[..], 2, 2);
	write32(owner[..], 8, 77);
	send_all(fds[1], owner[..])!!;
	test::eq(view.clipboard_command(CUT), true);
	test::eq(field.get_text(), "");
	char[24] ownership;
	receive_all(fds[1], ownership[..])!!;
	char[32] event;
	event[0] = 30;
	write32(event[..], 4, 60);
	write32(event[..], 8, 77);
	write32(event[..], 12, 88);
	write32(event[..], 16, 104);
	write32(event[..], 20, 103);
	write32(event[..], 24, 109);
	canvas.clipboard_event(event[..])!!;
	char[76] transfer;
	receive_all(fds[1], transfer[..])!!;
	test::eq(transfer[0], (char)18);
	test::eq((String)transfer[24:6], "é👋");
	test::eq(transfer[32], (char)25);
	test::eq(read32(transfer[..], 64), 109u);
	write32(event[..], 20, 105);
	canvas.clipboard_event(event[..])!!;
	char[80] targets;
	receive_all(fds[1], targets[..])!!;
	test::eq(read32(targets[..], 20), 3u); // Unicode content cannot be represented as STRING.
	test::eq(read32(targets[..], 32), 103u);
	write32(event[..], 20, 999);
	canvas.clipboard_event(event[..])!!;
	char[44] rejected;
	receive_all(fds[1], rejected[..])!!;
	test::eq(read32(rejected[..], 32), 0u);
}

fn void x11_clipboard_requestor_disappearance_does_not_close_the_window() @test
{
	int[2] fds;
	test::eq(clipboard_socketpair(1, 1, 0, &fds), 0);
	defer (void)close(fds[0]);
	defer (void)close(fds[1]);
	XConnection connection = { .fd = fds[0], .sequence = 17 };
	XCanvas canvas = { .connection = &connection };
	defer canvas.dispose();
	canvas.track_clipboard_request();
	char[32] error;
	error[1] = 3; // BadWindow for our selection response.
	write16(error[..], 2, 17);
	error[10] = 18;
	send_all(fds[1], error[..])!!;
	char[32] expose;
	expose[0] = 12;
	send_all(fds[1], expose[..])!!;
	char[32] next = canvas.next_event()!!;
	test::eq(next[0], (char)12);
	test::eq(canvas.clipboard_error(error[..]), false); // Only the recorded error is ignored.
}
