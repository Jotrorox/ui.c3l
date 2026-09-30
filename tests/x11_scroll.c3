module ui::backend @feat(LINUX);
import std::core::test;

fn void xwheel(XCanvas* canvas, View* view, uint type, uint button, int x, int y, uint window = 77) @private
{
	char[32] event;
	event[0] = (char)type;
	event[1] = (char)button;
	write32(event[..], 12, window);
	write16(event[..], 24, (uint)x);
	write16(event[..], 26, (uint)y);
	canvas.event(view, event[..])!!;
}

fn void x11_wheel_buttons_scroll_press_only_and_never_activate() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* outer = view.scroll_column({ .width = 200, .height = 100 });
	Widget* inner = outer.scroll_column({ .width = 150, .height = 60 });
	Widget* check = inner.checkbox("check");
	inner.text("content").set_layout({ .height = 160 });
	outer.text("outer").set_layout({ .height = 200 });
	view.update();
	XCanvas canvas = { .setup.window = 77 };
	xwheel(&canvas, &view, 4, 5, 30, 30);
	test::eq(inner.scroll_offset(), 40);
	test::eq(outer.scroll_offset(), 0);
	test::eq(view.pressed == null && view.focused == null, true);
	test::eq(check.is_checked(), false);
	xwheel(&canvas, &view, 5, 5, 30, 30);
	test::eq(inner.scroll_offset(), 40);
	xwheel(&canvas, &view, 4, 4, 30, 30);
	test::eq(inner.scroll_offset(), 0);
	xwheel(&canvas, &view, 5, 4, 30, 30);
	test::eq(inner.scroll_offset(), 0);
	xwheel(&canvas, &view, 4, 5, -1, 30);
	xwheel(&canvas, &view, 4, 5, 30, 30, 78);
	xwheel(&canvas, &view, 4, 6, 30, 30);
	test::eq(inner.scroll_offset(), 0);
	inner.scroll_to(int::max);
	int extent = inner.scroll_extent();
	xwheel(&canvas, &view, 4, 5, 30, 30);
	test::eq(inner.scroll_offset(), extent);
	test::eq(outer.scroll_offset(), 40);
	test::eq(check.is_checked(), false);
}

fn void x11_scrolled_text_does_not_wrap_negative_wire_coordinates() @test
{
	// Offscreen text must not emit requests, even without a live connection.
	XCanvas canvas = { .ascent = 10, .height = 13, .clip = { 0, 0, 200, 100 } };
	draw_xtext(&canvas, "above", 10, -65536, INK)!!;
	draw_xtext(&canvas, "below", 10, 65536, INK)!!;
	draw_xtext(&canvas, "just above", 10, -13, INK)!!;
	draw_xtext(&canvas, "just below", 10, 100, INK)!!;
	canvas.clip = {};
	draw_xtext(&canvas, "empty clip", 0, 0, INK)!!;
}

fn void x11_scrolled_fills_and_text_encode_only_clipped_representable_positions() @test
{
	int[2] sockets;
	test::eq(socketpair(1, 1, 0, &sockets), 0);
	defer (void)close(sockets[0]);
	defer (void)close(sockets[1]);
	XConnection connection = { .fd = sockets[0] };
	char[60] font;
	write16(font[..], 12, 6);
	write16(font[..], 40, 32);
	write16(font[..], 42, 126);
	write16(font[..], 44, '?');
	XCanvas canvas = { .connection = &connection, .setup.window = 77, .gc = 78,
		.font_data = font[..], .ascent = 10, .height = 13, .clip = { 0, 0, 200, 100 } };
	fill_xrect(&canvas, { -65500, -65500, 65535, 65535 }, INK)!!;
	char[36] fill;
	receive_all(sockets[1], fill[..])!!;
	test::eq(fill[16], 70);
	test::eq(read16(fill[..], 28), 0);
	test::eq(read16(fill[..], 30), 0);
	test::eq(read16(fill[..], 32), 35);
	test::eq(read16(fill[..], 34), 35);
	draw_xtext(&canvas, "visible", -4, -2, INK)!!;
	char[48] visible;
	receive_all(sockets[1], visible[..])!!;
	test::eq(visible[16], 75);
	test::eq((short)read16(visible[..], 28), -4);
	test::eq((short)read16(visible[..], 30), 8);
	// A long left-hand prefix is advanced before narrowing x. The remaining
	// character starts at -2, rather than wrapping an unrepresentable origin.
	write16(font[..], 12, 32767);
	draw_xtext(&canvas, "abc", -65536, 0, INK)!!;
	char[36] suffix;
	receive_all(sockets[1], suffix[..])!!;
	test::eq(suffix[16], 75);
	test::eq((short)read16(suffix[..], 28), -2);
	test::eq(suffix[32], 1);
	test::eq(suffix[35], 'c');
}
