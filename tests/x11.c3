module ui::backend @feat(LINUX);
import std::core::test;

fn void wire_integers_use_little_endian_at_unaligned_offsets() @test
{
	// X11 packets have a fixed byte layout on both x64 and ARM64.
	char[10] buffer = { 0xaa, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xbb };
	char[] bytes = buffer[..];
	test::eq(read16(bytes, 1), (ushort)0x2301);
	test::eq(read32(bytes, 1), 0x67452301u);
	test::eq(read32(bytes, 5), 0xefcdab89u);
	write32(bytes, 3, 0xfedcba98u);
	test::eq(bytes[2], (char)0x23);
	test::eq(bytes[3], (char)0x98);
	test::eq(bytes[4], (char)0xba);
	test::eq(bytes[5], (char)0xdc);
	test::eq(bytes[6], (char)0xfe);
	test::eq(bytes[7], (char)0xcd);
	test::eq(read32(bytes, 3), 0xfedcba98u);
	write16(bytes, 7, 0xffff);
	test::eq(read16(bytes, 7), (ushort)0xffff);
	test::eq(bytes[6], (char)0xfe);
	test::eq(bytes[9], (char)0xbb);
}

fn void parses_local_displays() @test
{
	Display display = parse_display(":0")!!;
	test::eq(display.number, 0u);
	test::eq(display.screen, 0u);
	display = parse_display("unix:12.3")!!;
	test::eq(display.number, 12u);
	test::eq(display.screen, 3u);
	display = parse_display("unix/:65535.2")!!;
	test::eq(display.number, 65535u);
	test::eq(display.screen, 2u);
}

fn void rejects_invalid_or_remote_displays() @test
{
	foreach (String value : { "", ":", ":-1", ":0.", ":.1", ":0.1.2", ":65536", ":999999999999999", "localhost:0", "host:1", ":0junk" })
	{
		test::@error(parse_display(value), ui::UNSUPPORTED_DISPLAY);
	}
}

fn void parses_screens_and_resource_ids() @test
{
	char[144] data;
	write32(data[..], 4, 0x100000);
	write32(data[..], 8, 0xffff0); // IDs need not have bit zero available.
	data[20] = 2;
	write32(data[..], 32, 17);
	write32(data[..], 40, 0xffffff);
	data[71] = 1; // One depth with one visual on screen zero.
	write16(data[..], 74, 1);
	write32(data[..], 104, 23);
	Setup setup = parse_setup(data[..], 0)!!;
	test::eq(setup.window, 0x100010u);
	test::eq(setup.root, 17u);
	test::eq(setup.white_pixel, 0xffffffu);
	setup = parse_setup(data[..], 1)!!;
	test::eq(setup.root, 23u);
	test::@error(parse_setup(data[..], 2), ui::PROTOCOL_ERROR);
	for (sz length = 0; length < data.len; length++)
	{
		test::@error(parse_setup(data[:length], 1), ui::PROTOCOL_ERROR);
	}
	write32(data[..], 8, 0);
	test::@error(parse_setup(data[..], 0), ui::PROTOCOL_ERROR);
}

fn void matches_only_our_close_events() @test
{
	char[32] event;
	event[0] = 0x80 | 33; // SendEvent bit must be ignored.
	event[1] = 32;
	write32(event[..], 4, 10);
	write32(event[..], 8, 20);
	write32(event[..], 12, 30);
	test::eq(is_close_event(event[..], 10, 20, 30), true);
	test::eq(is_close_event(event[..], 11, 20, 30), false);
	test::eq(is_close_event(event[..], 10, 21, 30), false);
	test::eq(is_close_event(event[..], 10, 20, 31), false);
	event[1] = 8;
	test::eq(is_close_event(event[..], 10, 20, 30), false);
	event[0] = 17;
	write32(event[..], 8, 10);
	test::eq(is_close_event(event[..], 10, 20, 30), true);
	test::eq(is_close_event(event[..], 11, 20, 30), false);
}

fn void bounds_checks_authority_records() @test
{
	// FamilyWild, empty address, display "0", MIT cookie.
	char[] record = x"ffff 0000 0001 30 0012 4d49542d4d414749432d434f4f4b49452d31 0010 000102030405060708090a0b0c0d0e0f";
	char[] cookie = find_cookie(record, "0", "host")!!;
	test::eq(cookie.len, 16);
	test::eq(cookie[15], (char)15);
	test::eq(find_cookie(record, "1", "host")!!.len, 0);
	for (sz length = 1; length < record.len; length++)
	{
		test::@error(find_cookie(record[:length], "0", "host"), ui::AUTHENTICATION_FAILED);
	}
}
