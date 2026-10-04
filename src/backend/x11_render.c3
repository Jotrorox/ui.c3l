module ui::backend @feat(LINUX);
import std::math, libc;

// Core X11 fonts provide a dependency-free first renderer. Glyph metrics are
// loaded once. Complex shaping and font fallback can replace this adapter later.
struct XCanvas
{
	XConnection* connection;
	XClipboard clipboard;
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
	View* view;
	int font_size;
	bool font_owned;
	fault failure;
	bool palette_ready;
	Theme palette;
	uint[ui::INK_COUNT] pixels;
	bool[ui::INK_COUNT] allocated;
}

struct XQueuedEvent
{
	char[32] data;
	XQueuedEvent* next;
}

fn void XCanvas.dispose(&self)
{
	self.clipboard.owned.free(mem);
	if (self.font_owned) mem::free(self.font_data.ptr);
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
	if (!self.first_event)
	{
		if (self.clipboard.pending)
		{
			WPollFd fd = { self.connection.fd, 1, 0 };
			int timeout = (int)math::clamp(self.clipboard.deadline - wayland_time(), 0L, 5000L);
			int ready = poll(&fd, 1, timeout);
			if (!ready)
			{
				self.clipboard.pending = false;
				self.delete_clipboard_property()!;
			}
			else if (ready < 0 && libc::errno() != EINTR) return ui::CONNECTION_FAILED~;
		}
		while (true)
		{
			char[32] message;
			receive_all(self.connection.fd, message[..])!;
			uint type = message[0] & 0x7f;
			if (!type)
			{
				if (self.clipboard_error(message[..])) continue;
				return ui::PROTOCOL_ERROR~;
			}
			if (type == 1 || type == 35) discard_payload(self.connection.fd, read32(message[..], 4))!;
			return message;
		}
	}
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
		if (type == 0)
		{
			if (self.clipboard_error(header[..])) continue;
			return ui::PROTOCOL_ERROR~;
		}
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

// Theme/font replies can arrive while the window is mapped. Preserve events
// just as keyboard-map refresh does, and reject unexpected reply sequences.
fn char[]? XCanvas.read_reply(&self, uint limit)
{
	while (true)
	{
		char[32] header;
		receive_all(self.connection.fd, header[..])!;
		uint type = header[0] & 0x7f;
		if (type == 0)
		{
			if (self.clipboard_error(header[..])) continue;
			return ui::PROTOCOL_ERROR~;
		}
		if (type == 1)
		{
			uint words = read32(header[..], 4);
			if (header[0] != 1 || read16(header[..], 2) != self.connection.sequence || words > limit / 4)
			{
				return ui::PROTOCOL_ERROR~;
			}
			sz length = 32 + (sz)words * 4;
			char[] data = ((char*)mem::malloc(length))[:length];
			defer catch mem::free(data.ptr);
			data[:32] = header[..];
			receive_all(self.connection.fd, data[32..])!;
			return data;
		}
		if (type == 35) { discard_payload(self.connection.fd, read32(header[..], 4))!; continue; }
		if (self.queued_events == 4096) return ui::PROTOCOL_ERROR~;
		XQueuedEvent* event = mem::new(XQueuedEvent, { .data = header });
		if (self.last_event) { self.last_event.next = event; }
		else { self.first_event = event; }
		self.last_event = event;
		self.queued_events++;
	}
}

fn void? XCanvas.sync_font(&self) => @pool()
{
	int size = (self.view ? self.view.get_theme() : ui::DEFAULT_THEME).font_size;
	if (self.font_size == size) return;
	// Core servers may only offer bitmap strikes. Request an XLFD pixel size,
	// retaining the dependency-free fixed-font fallback when it is unavailable.
	String pattern = string::tformat("-*-fixed-medium-r-*-*-%s-*-*-*-*-*-*-*", size);
	char[128] list;
	list[0] = 49; // ListFonts
	write16(list[..], 2, (uint)padded(8 + pattern.len) / 4);
	write16(list[..], 4, 1);
	write16(list[..], 6, (uint)pattern.len);
	list[8:pattern.len] = ((char[])pattern)[..];
	self.connection.request(list[:padded(8 + pattern.len)])!;
	char[] names = self.read_reply(65536)!;
	defer mem::free(names.ptr);
	String name = "fixed";
	if (read16(names, 8))
	{
		if (names.len < 33 || !names[32] || (sz)names[32] > names.len - 33) return ui::PROTOCOL_ERROR~;
		name = (String)names[33:names[32]];
	}
	if (self.font_size)
	{
		char[8] close_font;
		close_font[0] = 46;
		write16(close_font[..], 2, 2);
		write32(close_font[..], 4, self.font);
		self.connection.request(close_font[..])!;
	}
	char[272] open_font;
	open_font[0] = 45;
	write16(open_font[..], 2, (uint)padded(12 + name.len) / 4);
	write32(open_font[..], 4, self.font);
	write16(open_font[..], 8, (uint)name.len);
	open_font[12:name.len] = ((char[])name)[..];
	self.connection.request(open_font[:padded(12 + name.len)])!;
	char[8] query;
	query[0] = 47;
	write16(query[..], 2, 2);
	write32(query[..], 4, self.font);
	self.connection.request(query[..])!;
	char[] data = self.read_reply(1048576)!;
	defer catch mem::free(data.ptr);
	if (data.len < 60 || read16(data, 40) > read16(data, 42) || data[49] > data[50] ||
		read32(data, 56) > 65536 || 60 + (ulong)read16(data, 46) * 8 + (ulong)read32(data, 56) * 12 > (ulong)data.len)
	{
		return ui::PROTOCOL_ERROR~;
	}
	int ascent = (short)read16(data, 52);
	int height = ascent + (short)read16(data, 54);
	if (ascent < 0 || (short)read16(data, 54) < 0 || height <= 0 || height > 4096) return ui::PROTOCOL_ERROR~;
	if (self.font_size)
	{
		char[16] change;
		change[0] = 56;
		write16(change[..], 2, 4);
		write32(change[..], 4, self.gc);
		write32(change[..], 8, 1 << 14);
		write32(change[..], 12, self.font);
		self.connection.request(change[..])!;
	}
	if (self.font_owned) mem::free(self.font_data.ptr);
	self.font_data = data;
	self.font_owned = true;
	self.ascent = ascent;
	self.height = height;
	self.font_size = size;
}

fn void? XCanvas.free_colors(&self, uint[ui::INK_COUNT] pixels, bool[ui::INK_COUNT] allocated)
{
	char[60] request;
	request[0] = 88; // FreeColors; one reference for each allocated role.
	write32(request[..], 4, self.setup.colormap);
	uint count;
	foreach (index, used : allocated)
	{
		if (used) { write32(request[..], 12 + (sz)count * 4, pixels[index]); count++; }
	}
	if (!count) return;
	write16(request[..], 2, 3 + count);
	self.connection.request(request[:12 + (sz)count * 4])!;
}

fn void? XCanvas.sync_colors(&self)
{
	Theme theme = self.view ? self.view.get_theme() : ui::DEFAULT_THEME;
	if (self.palette_ready && self.palette.same_colors(theme)) return;
	uint[ui::INK_COUNT] pixels;
	bool[ui::INK_COUNT] allocated;
	defer catch { if (catch self.free_colors(pixels, allocated)) {} }
	foreach (index, color : theme.colors)
	{
		if (color.red == 255 && color.green == 255 && color.blue == 255) { pixels[index] = self.setup.white_pixel; continue; }
		if (!color.red && !color.green && !color.blue) { pixels[index] = self.setup.black_pixel; continue; }
		char[16] request;
		request[0] = 84; // AllocColor resolves the server visual/colormap masks.
		write16(request[..], 2, 4);
		write32(request[..], 4, self.setup.colormap);
		write16(request[..], 8, (uint)color.red * 257);
		write16(request[..], 10, (uint)color.green * 257);
		write16(request[..], 12, (uint)color.blue * 257);
		self.connection.request(request[..])!;
		char[] reply = self.read_reply(0)!;
		defer mem::free(reply.ptr);
		pixels[index] = read32(reply, 16);
		allocated[index] = true;
	}
	if (self.palette_ready) self.free_colors(self.pixels, self.allocated)!;
	self.pixels = pixels;
	self.allocated = allocated;
	self.palette = theme;
	self.palette_ready = true;
}

fn void? XCanvas.init(&self)
{
	self.font = resource_id(self.setup, 2)!;
	self.gc = resource_id(self.setup, 3)!;
	self.sync_font()!;
	self.refresh_keymap()!;
	char[24] gc;
	gc[0] = 55; // CreateGC against the root (same depth as our window).
	write16(gc[..], 2, 6);
	write32(gc[..], 4, self.gc);
	write32(gc[..], 8, self.setup.root);
	write32(gc[..], 12, (1 << 14) | (1 << 16)); // font, graphics-exposures
	write32(gc[..], 16, self.font);
	self.connection.request(gc[..])!;
	self.sync_colors()!;
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
	if (canvas.view)
	{
		if (catch failure = canvas.sync_font()) { canvas.failure = failure; return {}; }
	}
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
	write32(request[..], 12, self.palette_ready ? self.pixels[ink] : ink == PAPER ? self.setup.white_pixel : self.setup.black_pixel);
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
	if (self.failure) return self.failure~;
	self.sync_colors()!;
	Renderer renderer = { self, &fill_xrect, &draw_xtext, &clip_xrect };
	return view.paint(&renderer, view.take_damage());
}

fn uint XCanvas.key_symbol(&self, char code, uint modifiers)
{
	sz offset = (sz)(code - self.setup.min_keycode) * self.keysyms_per_key * 4;
	uint level = (modifiers & 128) && self.keysyms_per_key >= 4 ? 2 : 0; // Mod5 / group 2.
	uint lower = read32(self.keymap, offset + (sz)level * 4);
	uint upper = level + 1 < self.keysyms_per_key ? read32(self.keymap, offset + (sz)(level + 1) * 4) : 0;
	// Core maps may omit the shifted symbol for alphabetic keys.
	if (!upper && ((lower >= 'a' && lower <= 'z') || (lower >= 0xe0 && lower <= 0xfe && lower != 0xf7))) upper = lower - 32;
	bool shift = (modifiers & 1) != 0;
	bool letter = ((lower >= 'a' && lower <= 'z') || (lower >= 0xe0 && lower <= 0xfe && lower != 0xf7)) && upper == lower - 32;
	if (letter && (modifiers & 2)) shift = !shift; // CapsLock.
	return shift && upper ? upper : lower;
}

// Core X11 has keysyms, not committed character messages. This minimal adapter
// translates printable Latin-1/Unicode keysyms after layout/modifier resolution.
// XIM and Compose/preedit are intentionally left to a future input adapter.
fn void x11_commit(View* view, uint symbol) @private => @pool()
{
	uint code = symbol;
	if (symbol >= 0x01000100 && symbol <= 0x0110ffff) { code = symbol & 0xffffff; }
	else if (symbol > 255) { return; }
	if (code >= 0xd800 && code <= 0xdfff) return;
	Char32[1] chars = { code };
	view.text_input(string::from_utf32(tmem, chars[..])!!);
}

fn void? XCanvas.event(&self, View* view, char[] event)
{
	uint type = event[0] & 0x7f;
	if (type >= 28 && type <= 31) return self.clipboard_event(event);
	if (type >= 2 && type <= 8) self.clipboard.time = read32(event, 4);
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
			else if (event[1] == 1) { view.pointer_down(x, y, (read16(event, 28) & 1) != 0); }
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
			if (!view.has_pointer_capture()) view.pointer_move(type == 7 ? x : -1, type == 7 ? y : -1);
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
			view.update();
			ulong epoch = view.focus_epoch;
			uint modifiers = read16(event, 28);
			uint symbol = self.key_symbol(event[1], modifiers);
			ControlKey action = keysym_control(symbol);
			bool shortcut = (modifiers & (4 | 8 | 64)) != 0; // Ctrl, Alt, Super.
			if (shortcut) action = (modifiers & 4) && !(modifiers & (8 | 64)) ? clipboard_keysym(symbol) : NONE;
			view.key_down(event[1], action, repeat, (modifiers & 1) != 0);
			if (!shortcut && epoch == view.focus_epoch) x11_commit(view, symbol);
		default:
	}
}
