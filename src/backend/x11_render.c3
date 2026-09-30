module ui::backend @feat(LINUX);
import std::math;

// Core X11 fonts provide a dependency-free first renderer. Glyph metrics are
// loaded once. Complex shaping and font fallback can replace this adapter later.
struct XCanvas
{
	XConnection* connection;
	Setup setup;
	uint font;
	uint gc;
	char[] font_data;
	char[] keymap;
	uint keysyms_per_key;
	uint[256] release_time;
	bool[256] release_seen;
	XQueuedEvent* first_event;
	XQueuedEvent* last_event;
	uint queued_events;
	int ascent;
	int height;
	ui::Rect clip;
}

struct XQueuedEvent
{
	char[32] data;
	XQueuedEvent* next;
}

fn void XCanvas.dispose(&self)
{
	mem::free(self.keymap.ptr);
	while (self.first_event)
	{
		XQueuedEvent* event = self.first_event;
		self.first_event = event.next;
		mem::free(event);
	}
}

fn char[32]? XCanvas.next_event(&self)
{
	if (!self.first_event) return receive_message(self.connection.fd);
	XQueuedEvent* event = self.first_event;
	char[32] result = event.data;
	self.first_event = event.next;
	if (!self.first_event) self.last_event = null;
	self.queued_events--;
	mem::free(event);
	return result;
}

// Read one full frame without losing events that arrive before our reply.
// No other reply-producing request is outstanding on this connection. Unknown
// replies/errors are protocol failures, never mistaken for keyboard data.
fn void? XCanvas.refresh_keymap(&self)
{
	if (self.setup.min_keycode < 8 || self.setup.max_keycode < self.setup.min_keycode) return ui::PROTOCOL_ERROR~;
	uint count = (uint)self.setup.max_keycode - self.setup.min_keycode + 1;
	char[8] request;
	request[0] = 101;
	write16(request[..], 2, 2);
	request[4] = self.setup.min_keycode;
	request[5] = (char)count;
	self.connection.request(request[..])!;
	while (true)
	{
		char[32] header;
		receive_all(self.connection.fd, header[..])!;
		uint type = header[0] & 0x7f;
		if (type == 0) return ui::PROTOCOL_ERROR~;
		if (type == 1)
		{
			if (header[0] != 1 || read16(header[..], 2) != self.connection.sequence ||
				!header[1] || read32(header[..], 4) != count * (uint)header[1]) return ui::PROTOCOL_ERROR~;
			// At most 248 * 255 keysyms. Replace only after a complete valid reply;
			// repeated refreshes do not accumulate allocations in open()'s pool.
			sz length = (sz)count * header[1] * 4;
			char[] keys = ((char*)mem::malloc(length))[:length];
			defer catch mem::free(keys.ptr);
			receive_all(self.connection.fd, keys)!;
			mem::free(self.keymap.ptr);
			self.keymap = keys;
			self.keysyms_per_key = header[1];
			return;
		}
		if (type == 35) // Generic extension event: consume its trailing payload.
		{
			discard_payload(self.connection.fd, read32(header[..], 4))!;
			continue;
		}
		// Bound memory use if a broken server floods events without replying.
		if (self.queued_events == 4096) return ui::PROTOCOL_ERROR~;
		XQueuedEvent* event = mem::new(XQueuedEvent, { .data = header });
		if (self.last_event) { self.last_event.next = event; }
		else { self.first_event = event; }
		self.last_event = event;
		self.queued_events++;
	}
}

fn uint? resource_id(Setup setup, uint index) @private
{
	uint result = setup.resource_base;
	for (uint bit = 1; bit; bit <<= 1)
	{
		if (!(setup.resource_mask & bit)) continue;
		if (index & 1) result |= bit;
		index >>= 1;
	}
	if (index) return ui::PROTOCOL_ERROR~;
	return result;
}

// Used only before mapping the window: no input/exposure events can interleave.
fn char[]? read_initial_reply(int fd, uint limit) @private
{
	char[32] header;
	receive_all(fd, header[..])!;
	if (header[0] != 1 || read32(header[..], 4) > limit / 4) return ui::PROTOCOL_ERROR~;
	sz length = 32 + (sz)read32(header[..], 4) * 4;
	char[] data = ((char*)mem::tmalloc(length))[:length];
	data[:32] = header[..];
	receive_all(fd, data[32..])!;
	return data;
}

fn void? XCanvas.init(&self)
{
	self.font = resource_id(self.setup, 2)!;
	self.gc = resource_id(self.setup, 3)!;
	char[20] open_font;
	open_font[0] = 45;
	write16(open_font[..], 2, 5);
	write32(open_font[..], 4, self.font);
	write16(open_font[..], 8, 5);
	open_font[12:5] = ((char[])"fixed")[..];
	self.connection.request(open_font[..])!;
	char[8] query;
	query[0] = 47;
	write16(query[..], 2, 2);
	write32(query[..], 4, self.font);
	self.connection.request(query[..])!;
	self.font_data = read_initial_reply(self.connection.fd, 1048576)!;
	char[] data = self.font_data;
	if (data.len < 60 || read16(data, 40) > read16(data, 42) || data[49] > data[50] ||
		read32(data, 56) > 65536 || 60 + (ulong)read16(data, 46) * 8 + (ulong)read32(data, 56) * 12 > (ulong)data.len)
	{
		return ui::PROTOCOL_ERROR~;
	}
	self.ascent = (short)read16(data, 52);
	self.height = self.ascent + (short)read16(data, 54);
	if (self.ascent < 0 || (short)read16(data, 54) < 0 || self.height <= 0 || self.height > 4096) return ui::PROTOCOL_ERROR~;
	// Use the same framed, sequence-checked mapping reader at startup and live.
	self.refresh_keymap()!;
	char[24] gc;
	gc[0] = 55; // CreateGC against the root (same depth as our window).
	write16(gc[..], 2, 6);
	write32(gc[..], 4, self.gc);
	write32(gc[..], 8, self.setup.root);
	write32(gc[..], 12, (1 << 14) | (1 << 16)); // font, graphics-exposures
	write32(gc[..], 16, self.font);
	self.connection.request(gc[..])!;
}

fn int XCanvas.glyph_width(&self, uint code)
{
	char[] data = self.font_data;
	uint low = data[50] ? code & 255 : code;
	uint high = data[50] ? code >> 8 : 0;
	if (high < data[49] || high > data[50] || low < read16(data, 40) || low > read16(data, 42)) return -1;
	if (!read32(data, 56)) return (short)read16(data, 12);
	uint index = (high - data[49]) * (read16(data, 42) - read16(data, 40) + 1) + low - read16(data, 40);
	if (index >= read32(data, 56)) return -1;
	sz offset = 60 + (sz)read16(data, 46) * 8 + (sz)index * 12;
	int width = (short)read16(data, offset + 4);
	return width > 0 ? width : -1;
}

fn ushort XCanvas.glyph(&self, uint code)
{
	if (code <= 65535 && self.glyph_width(code) >= 0) return (ushort)code;
	if (self.glyph_width('?') >= 0) return '?';
	return read16(self.font_data, 44);
}

fn Size measure_xtext(void* context, String text) @private => @pool()
{
	XCanvas* canvas = context;
	int width;
	foreach (code : text.to_temp_utf32()!!) width += math::max(0, canvas.glyph_width(canvas.glyph(code)));
	return { width, canvas.height };
}

fn void? clip_xrect(void* context, ui::Rect rect) @private
{
	XCanvas* canvas = context;
	canvas.clip = rect.intersect({ 0, 0, 32767, 32767 });
	char[20] request;
	request[0] = 59;
	write16(request[..], 2, 5);
	write32(request[..], 4, canvas.gc);
	write16(request[..], 12, (uint)canvas.clip.x);
	write16(request[..], 14, (uint)canvas.clip.y);
	write16(request[..], 16, (uint)canvas.clip.width);
	write16(request[..], 18, (uint)canvas.clip.height);
	return canvas.connection.request(request[..]);
}

fn void? XCanvas.ink(&self, Ink ink)
{
	char[16] request;
	request[0] = 56;
	write16(request[..], 2, 4);
	write32(request[..], 4, self.gc);
	write32(request[..], 8, 1 << 2); // foreground
	write32(request[..], 12, ink == PAPER ? self.setup.white_pixel : self.setup.black_pixel);
	return self.connection.request(request[..]);
}

fn void? fill_xrect(void* context, ui::Rect rect, Ink ink) @private
{
	XCanvas* canvas = context;
	rect = rect.intersect(canvas.clip);
	if (rect.empty()) return;
	canvas.ink(ink)!;
	char[20] request;
	request[0] = 70;
	write16(request[..], 2, 5);
	write32(request[..], 4, canvas.setup.window);
	write32(request[..], 8, canvas.gc);
	write16(request[..], 12, (uint)rect.x);
	write16(request[..], 14, (uint)rect.y);
	write16(request[..], 16, (uint)rect.width);
	write16(request[..], 18, (uint)rect.height);
	return canvas.connection.request(request[..]);
}

fn void? draw_xtext(void* context, String text, int x, int y, Ink ink) @private => @pool()
{
	XCanvas* canvas = context;
	// Descendants of scroll viewports can be far above the window. Check the
	// full signed baseline before narrowing it to the X11 INT16 wire format.
	long baseline = (long)y + canvas.ascent;
	if (canvas.clip.empty() || (long)y + canvas.height <= canvas.clip.y ||
		y >= canvas.clip.y + canvas.clip.height || baseline < -32768 || baseline > 32767) return;
	Char32[] codes = text.to_temp_utf32()!!;
	// Skip unrepresentable left-hand glyph origins without wrapping them into
	// the visible window. Remaining glyphs retain their true advance positions.
	while (codes.len && x < -32768)
	{
		x += math::max(0, canvas.glyph_width(canvas.glyph(codes[0])));
		codes = codes[1..];
	}
	if (!codes.len || x >= canvas.clip.x + canvas.clip.width) return;
	canvas.ink(ink)!;
	while (codes.len && x < canvas.clip.x + canvas.clip.width)
	{
		sz count = math::min(codes.len, (sz)254);
		char[528] request;
		request[0] = 75; // PolyText16, transparent background.
		write16(request[..], 2, (uint)padded(18 + count * 2) / 4);
		write32(request[..], 4, canvas.setup.window);
		write32(request[..], 8, canvas.gc);
		write16(request[..], 12, (uint)x);
		write16(request[..], 14, (uint)baseline);
		request[16] = (char)count;
		for (sz index = 0; index < count; index++)
		{
			ushort glyph = canvas.glyph(codes[index]);
			// CHAR2B is always high byte first, independently of wire byte order.
			request[18 + index * 2] = (char)(glyph >> 8);
			request[19 + index * 2] = (char)glyph;
			x += math::max(0, canvas.glyph_width(glyph));
		}
		canvas.connection.request(request[:padded(18 + count * 2)])!;
		codes = codes[count..];
	}
}

fn void? XCanvas.paint(&self, View* view)
{
	Renderer renderer = { self, &fill_xrect, &draw_xtext, &clip_xrect };
	return view.paint(&renderer, view.take_damage());
}

fn void? XCanvas.event(&self, View* view, char[] event)
{
	uint type = event[0] & 0x7f;
	int x = (short)read16(event, 24);
	int y = (short)read16(event, 26);
	switch (type)
	{
		case 12: // Expose
			if (read32(event, 4) == self.setup.window)
			{
				view.invalidate({ read16(event, 8), read16(event, 10), read16(event, 12), read16(event, 14) });
			}
		case 22: // ConfigureNotify
			if (read32(event, 8) == self.setup.window) view.resize(read16(event, 20), read16(event, 22));
		case 4: // ButtonPress; the X server implicitly captures until release.
			if (read32(event, 12) != self.setup.window) return;
			if (event[1] == 4 || event[1] == 5) { view.scroll_wheel(x, y, event[1] == 4 ? -40 : 40); }
			else if (event[1] == 1) { view.pointer_down(x, y); }
		case 5:
			if (read32(event, 12) == self.setup.window && event[1] == 1) view.pointer_up(x, y);
		case 6: // Captured MotionNotify keeps signed coordinates outside the window.
			if (read32(event, 12) == self.setup.window) view.pointer_move(x, y);
		case 7: // EnterNotify / LeaveNotify carry the grab mode at byte 30.
		case 8:
			if (read32(event, 12) != self.setup.window) return;
			if (event[30] == 2) view.cancel_press(); // NotifyUngrab: capture ended.
			// Crossing events are not drag motion. In particular, a synthetic
			// (-1,-1) leave would jump a captured thumb to the top endpoint.
			if (!view.scroll_pressed) view.pointer_move(type == 7 ? x : -1, type == 7 ? y : -1);
		case 18: // UnmapNotify ends both pointer and keyboard interactions.
			if (read32(event, 8) == self.setup.window)
			{
				view.blur();
				self.release_seen = {};
			}
		case 10: // FocusOut
			if (read32(event, 4) == self.setup.window)
			{
				view.blur();
				self.release_seen = {};
			}
		case 11: // KeymapNotify follows FocusIn/EnterNotify (KeymapStateMask).
			// Keys held outside the window must not activate on refocus. This
			// bitmap is physical state, unrelated to the keysym mapping below.
			for (uint key = 8; key < 256; key++) view.held_keys[key] = (event[key / 8] & (1 << (key % 8))) != 0;
		case 34: // MappingNotify: pointer mappings do not affect our control keys.
			if (event[4] == 2) return;
			if (event[4] > 2) return ui::PROTOCOL_ERROR~;
			if (event[4] == 1 && (!event[6] || event[5] < self.setup.min_keycode ||
				(uint)event[5] + event[6] - 1 > self.setup.max_keycode)) return ui::PROTOCOL_ERROR~;
			// Refresh the full range, including a changed keysyms-per-keycode.
			// MappingModifier also refreshes; Shift uses the core event mask.
			self.refresh_keymap()!;
		case 3: // KeyRelease
			if (read32(event, 12) != self.setup.window) return;
			view.key_up(event[1]);
			self.release_time[event[1]] = read32(event, 4);
			self.release_seen[event[1]] = true;
		case 2: // KeyPress
			if (read32(event, 12) != self.setup.window ||
				event[1] < self.setup.min_keycode || event[1] > self.setup.max_keycode) return;
			// Core autorepeat releases/presses have the same keycode and server
			// timestamp. Remember releases instead of peeking at the socket:
			// fragmented traffic and interleaved replies cannot break detection.
			bool repeat = self.release_seen[event[1]] && self.release_time[event[1]] == read32(event, 4);
			self.release_seen[event[1]] = false;
			uint symbol = read32(self.keymap, (sz)(event[1] - self.setup.min_keycode) * self.keysyms_per_key * 4);
			view.key_down(event[1], symbol == 0xff09 || symbol == 0xfe20 ? TAB :
				(symbol == 0xff0d || symbol == 0x20 ? ACTIVATE : NONE), repeat,
				(read16(event, 28) & 1) != 0);
		default:
	}
}
