module ui::backend @feat(LINUX);
import std::core::test;

fn char[] theme_request(int fd, char[] buffer) @private
{
	receive_all(fd, buffer[:4])!!;
	sz length = (sz)read16(buffer, 2) * 4;
	receive_all(fd, buffer[4:length - 4])!!;
	return buffer[:length];
}

fn void x11_theme_uses_server_colormap_pixels_and_releases_old_allocations() @test
{
	int[2] sockets;
	test::eq(socketpair(1, 1, 0, &sockets[0]), 0);
	defer (void)close(sockets[0]);
	defer (void)close(sockets[1]);
	View view;
	defer view.free();
	XConnection connection = { .fd = sockets[0] };
	XCanvas canvas = { .connection = &connection, .view = &view,
		.setup = { .white_pixel = 17, .black_pixel = 23, .colormap = 77 } };
	defer canvas.dispose();
	char[32] event;
	event[0] = 12;
	send_all(sockets[1], event[..])!!;
	for (uint sequence = 1; sequence <= 4; sequence++)
	{
		char[32] reply;
		reply[0] = 1;
		write16(reply[..], 2, sequence);
		write32(reply[..], 16, 1000 + sequence); // Deliberately unrelated to packed RGB.
		send_all(sockets[1], reply[..])!!;
	}
	canvas.sync_colors()!!;
	test::eq(canvas.pixels[Ink.PAPER], 17u);
	test::eq(canvas.pixels[Ink.INK], 23u);
	test::eq(canvas.pixels[Ink.FOCUS], 1004u);
	test::eq(canvas.queued_events, 1u);
	char[128] buffer;
	for (int index = 0; index < 4; index++)
	{
		char[] request = theme_request(sockets[1], buffer[..]);
		test::eq(request[0], (char)84);
		test::eq(read32(request, 4), 77u);
		if (index == 3)
		{
			test::eq(read16(request, 10), (ushort)(95 * 257));
			test::eq(read16(request, 12), (ushort)(204 * 257));
		}
	}
	canvas.sync_colors()!!;
	test::eq(connection.sequence, (ushort)4); // Same palette has no wire traffic.
	Theme theme = view.get_theme();
	theme.colors[Ink.INK] = { 12, 34, 56 };
	view.set_theme(theme);
	for (uint sequence = 5; sequence <= 9; sequence++)
	{
		char[32] reply;
		reply[0] = 1;
		write16(reply[..], 2, sequence);
		write32(reply[..], 16, 1000 + sequence);
		send_all(sockets[1], reply[..])!!;
	}
	canvas.sync_colors()!!;
	test::eq(canvas.pixels[Ink.INK], 1005u);
	for (int index = 0; index < 5; index++) theme_request(sockets[1], buffer[..]);
	char[] freed = theme_request(sockets[1], buffer[..]);
	test::eq(freed[0], (char)88);
	test::eq(freed.len, 28);
	test::eq(read32(freed, 12), 1001u);
	test::eq(read32(freed, 24), 1004u);
}

fn void x11_theme_selects_font_at_requested_size_and_refreshes_gc_and_metrics() @test
{
	int[2] sockets;
	test::eq(socketpair(1, 1, 0, &sockets[0]), 0);
	defer (void)close(sockets[0]);
	defer (void)close(sockets[1]);
	View view;
	defer view.free();
	XConnection connection = { .fd = sockets[0] };
	XCanvas canvas = { .connection = &connection, .view = &view, .font = 22, .gc = 33 };
	defer canvas.dispose();
	for (int pass = 0; pass < 2; pass++)
	{
		Theme theme = view.get_theme();
		theme.font_size = pass ? 28 : 18;
		view.set_theme(theme);
		char[40] names;
		names[0] = 1;
		write16(names[..], 2, (uint)connection.sequence + 1);
		write32(names[..], 4, 2);
		write16(names[..], 8, 1);
		names[32] = 6;
		names[33:6] = ((char[])"chosen")[..];
		send_all(sockets[1], names[..])!!;
		char[60] metrics;
		metrics[0] = 1;
		write16(metrics[..], 2, (uint)connection.sequence + (pass ? 4 : 3));
		write32(metrics[..], 4, 7);
		write16(metrics[..], 12, (uint)theme.font_size / 2);
		write16(metrics[..], 40, 32);
		write16(metrics[..], 42, 126);
		write16(metrics[..], 52, (uint)theme.font_size - 3);
		write16(metrics[..], 54, 3);
		send_all(sockets[1], metrics[..])!!;
		canvas.sync_font()!!;
		test::eq(canvas.height, theme.font_size);
		test::eq(measure_xtext(&canvas, "AB").width, theme.font_size);
		char[128] buffer;
		char[] list = theme_request(sockets[1], buffer[..]);
		test::eq(list[0], (char)49);
		if (pass) test::eq(theme_request(sockets[1], buffer[..])[0], (char)46);
		char[] open = theme_request(sockets[1], buffer[..]);
		test::eq(open[0], (char)45);
		test::eq((String)open[12:6], "chosen");
		test::eq(theme_request(sockets[1], buffer[..])[0], (char)47);
		if (pass)
		{
			char[] gc = theme_request(sockets[1], buffer[..]);
			test::eq(gc[0], (char)56);
			test::eq(read32(gc, 8), 1u << 14);
		}
	}
}
