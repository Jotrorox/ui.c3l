// CLIPBOARD selection ownership and bounded UTF8_STRING/STRING/INCR transfers.
// https://www.x.org/releases/X11R7.7/doc/xorg-docs/icccm/icccm.html#Selections
module ui::backend @feat(LINUX);

struct XClipboard
{
	uint selection;
	uint utf8;
	uint targets;
	uint timestamp;
	uint incr;
	uint property;
	uint time;
	uint owner_time;
	String owned;
	bool owns;
	bool pending;
	bool incremental;
	bool overflow;
	uint target;
	uint request_time;
	ClipboardRequest request;
	char[4096] bytes;
	sz length;
	long deadline;
	ushort[32] served_sequences;
	bool[32] served_requests;
}

fn ControlKey clipboard_keysym(uint symbol)
{
	switch (symbol)
	{
		case 'a': case 'A': return SELECT_ALL;
		case 'c': case 'C': return COPY;
		case 'x': case 'X': return CUT;
		case 'v': case 'V': return PASTE;
		default: return NONE;
	}
}

fn void XCanvas.track_clipboard_request(&self)
{
	uint index = self.connection.sequence % 32;
	self.clipboard.served_sequences[index] = self.connection.sequence;
	self.clipboard.served_requests[index] = true;
}

// A requestor can disappear between SelectionRequest and our response. Ignore
// only BadWindow/BadAtom errors belonging to clipboard replies we just sent.
fn bool XCanvas.clipboard_error(&self, char[] error)
{
	ushort sequence = read16(error, 2);
	uint index = sequence % 32;
	if (error[0] || (error[1] != 3 && error[1] != 5) || (error[10] != 18 && error[10] != 25) ||
		!self.clipboard.served_requests[index] || self.clipboard.served_sequences[index] != sequence) return false;
	self.clipboard.served_requests[index] = false;
	return true;
}

fn void? XCanvas.offer_property(&self, uint window, uint property, uint type, char format, char[] bytes)
{
	change_property(self.connection, window, property, type, format, bytes)!;
	self.track_clipboard_request();
}

fn void? XCanvas.init_clipboard(&self)
{
	self.clipboard.selection = intern_atom(self.connection, "CLIPBOARD")!;
	self.clipboard.utf8 = intern_atom(self.connection, "UTF8_STRING")!;
	self.clipboard.targets = intern_atom(self.connection, "TARGETS")!;
	self.clipboard.timestamp = intern_atom(self.connection, "TIMESTAMP")!;
	self.clipboard.incr = intern_atom(self.connection, "INCR")!;
	self.clipboard.property = intern_atom(self.connection, "UI_C3_CLIPBOARD")!;
}

fn bool x11_clipboard_write(void* context, String text) @private
{
	XCanvas* canvas = context;
	if (catch failure = canvas.own_clipboard(text)) { canvas.failure = failure; return false; }
	return canvas.clipboard.owns;
}

fn void? XCanvas.own_clipboard(&self, String text)
{
	char[16] owner;
	owner[0] = 22; // SetSelectionOwner
	write16(owner[..], 2, 4);
	write32(owner[..], 4, self.setup.window);
	write32(owner[..], 8, self.clipboard.selection);
	write32(owner[..], 12, self.clipboard.time);
	self.connection.request(owner[..])!;
	char[8] get;
	get[0] = 23; // GetSelectionOwner: do not cut before ownership succeeds.
	write16(get[..], 2, 2);
	write32(get[..], 4, self.clipboard.selection);
	self.connection.request(get[..])!;
	char[] reply = self.read_reply(0)!;
	defer mem::free(reply.ptr);
	if (read32(reply, 8) != self.setup.window) { self.clipboard.owns = false; return; }
	String copy = text.copy(mem);
	self.clipboard.owned.free(mem);
	self.clipboard.owned = copy;
	self.clipboard.owns = true;
	self.clipboard.owner_time = self.clipboard.time;
}

fn void? XCanvas.delete_clipboard_property(&self)
{
	char[12] data;
	data[0] = 19; // DeleteProperty, also acknowledges each INCR chunk.
	write16(data[..], 2, 3);
	write32(data[..], 4, self.setup.window);
	write32(data[..], 8, self.clipboard.property);
	self.connection.request(data[..])!;
}

fn void? XCanvas.convert_clipboard(&self, uint target)
{
	self.clipboard.target = target;
	char[24] data;
	data[0] = 24; // ConvertSelection
	write16(data[..], 2, 6);
	write32(data[..], 4, self.setup.window);
	write32(data[..], 8, self.clipboard.selection);
	write32(data[..], 12, target);
	write32(data[..], 16, self.clipboard.property);
	write32(data[..], 20, self.clipboard.request_time);
	self.connection.request(data[..])!;
}

fn void x11_clipboard_read(void* context, ClipboardRequest request) @private
{
	XCanvas* canvas = context;
	if (canvas.clipboard.pending) return;
	canvas.clipboard.request = request;
	canvas.clipboard.request_time = canvas.clipboard.time;
	canvas.clipboard.pending = true;
	canvas.clipboard.incremental = canvas.clipboard.overflow = false;
	canvas.clipboard.length = 0;
	canvas.clipboard.deadline = wayland_time() + 5000;
	if (catch failure = canvas.convert_clipboard(canvas.clipboard.utf8)) canvas.failure = failure;
}

// Use read_reply with a bounded GetProperty length. bytes_after rejects larger
// direct properties without allocation or truncation; INCR chunks are drained.
fn void? XCanvas.clipboard_property(&self)
{
	char[24] get;
	get[0] = 20; // GetProperty, delete after reading.
	get[1] = self.clipboard.incremental ? 1 : 0;
	write16(get[..], 2, 6);
	write32(get[..], 4, self.setup.window);
	write32(get[..], 8, self.clipboard.property);
	write32(get[..], 20, 1024);
	self.connection.request(get[..])!;
	char[] reply = self.read_reply(4096)!;
	defer mem::free(reply.ptr);
	uint type = read32(reply, 8);
	uint length = read32(reply, 16);
	if (!self.clipboard.incremental && type == self.clipboard.incr)
	{
		if (reply[1] != 32 || length != 1 || reply.len != 36)
		{
			self.clipboard.pending = false;
			self.delete_clipboard_property()!;
			return;
		}
		self.clipboard.incremental = true;
		self.clipboard.overflow = read32(reply, 32) > 4096;
		self.delete_clipboard_property()!;
		return;
	}
	bool valid = type == self.clipboard.target && reply[1] == 8 && length <= (uint)reply.len - 32;
	if (!valid || read32(reply, 12) || length > (uint)(4096 - self.clipboard.length)) self.clipboard.overflow = true;
	if (!self.clipboard.overflow)
	{
		self.clipboard.bytes[self.clipboard.length:length] = reply[32:length];
		self.clipboard.length += length;
	}
	if (!self.clipboard.incremental || read32(reply, 12)) self.delete_clipboard_property()!;
	if (self.clipboard.incremental && length) return;
	self.clipboard.pending = false;
	if (self.clipboard.overflow || !self.view) return;
	@pool()
	{
		String text = (String)self.clipboard.bytes[:self.clipboard.length];
		if (self.clipboard.target == 31) // STRING is ISO-8859-1, never UTF-8.
		{
			Char32[] codes = ((Char32*)mem::tmalloc(text.len * 4))[:text.len];
			foreach (i, c : text) codes[i] = c;
			text = string::from_utf32(tmem, codes)!!;
		}
		self.view.paste_text(text, self.clipboard.request);
	};
}

fn void? XCanvas.clipboard_event(&self, char[] event)
{
	XClipboard* clip = &self.clipboard;
	switch (event[0] & 0x7f)
	{
		case 29: // SelectionClear: keep storage only while serving our selection.
			if (read32(event, 8) == self.setup.window && read32(event, 12) == clip.selection)
			{
				if (clip.owner_time && (int)(read32(event, 4) - clip.owner_time) < 0) return;
				clip.owns = false;
				clip.owned.free(mem);
				clip.owned = {};
			}
		case 30: // SelectionRequest
			if (read32(event, 8) != self.setup.window || read32(event, 16) != clip.selection) return;
			uint requestor = read32(event, 12);
			uint target = read32(event, 20);
			uint property = read32(event, 24);
			if (!property) property = target; // ICCCM compatibility with old clients.
			uint time = read32(event, 4);
			bool supported = clip.owns && (!time || !clip.owner_time || (int)(time - clip.owner_time) >= 0);
			if (supported && target == clip.targets)
			{
				char[16] targets;
				foreach (i, atom : (uint[3]){ clip.targets, clip.timestamp, clip.utf8 }) write32(targets[..], i * 4, atom);
				sz length = 12;
				@pool()
				{
					bool latin = true;
					foreach (code : clip.owned.to_temp_utf32()!!) if (code > 255) { latin = false; break; }
					if (latin) { write32(targets[..], 12, 31); length = 16; }
				};
				self.offer_property(requestor, property, 4, 32, targets[:length])!;
			}
			else if (supported && target == clip.timestamp)
			{
				char[4] timestamp;
				write32(timestamp[..], 0, clip.owner_time);
				self.offer_property(requestor, property, 19, 32, timestamp[..])!; // INTEGER
			}
			else if (supported && target == clip.utf8)
			{
				self.offer_property(requestor, property, target, 8, (char[])clip.owned)!;
			}
			else if (supported && target == 31)
			{
				@pool()
				{
					Char32[] codes = clip.owned.to_temp_utf32()!!;
					char[4096] latin;
					foreach (i, code : codes)
					{
						if (code > 255) { supported = false; break; }
						latin[i] = (char)code;
					}
					if (supported) self.offer_property(requestor, property, 31, 8, latin[:codes.len])!;
				};
			}
			else { supported = false; }
			char[44] notify;
			notify[0] = 25; // SendEvent
			write16(notify[..], 2, 11);
			write32(notify[..], 4, requestor);
			notify[12] = 31; // SelectionNotify
			write32(notify[..], 16, read32(event, 4));
			write32(notify[..], 20, requestor);
			write32(notify[..], 24, clip.selection);
			write32(notify[..], 28, target);
			write32(notify[..], 32, supported ? property : 0);
			self.connection.request(notify[..])!;
			self.track_clipboard_request();
		case 31: // SelectionNotify
			if (!clip.pending || clip.incremental || read32(event, 8) != self.setup.window ||
				read32(event, 12) != clip.selection || read32(event, 16) != clip.target ||
				read32(event, 4) != clip.request_time) return;
			uint property = read32(event, 20);
			if (!property)
			{
				if (clip.target == clip.utf8) { self.convert_clipboard(31)!; }
				else { clip.pending = false; }
			}
			else if (property == clip.property) { self.clipboard_property()!; }
		case 28: // PropertyNotify: read INCR chunks only after the initial notify.
			if (clip.pending && clip.incremental && read32(event, 4) == self.setup.window &&
				read32(event, 8) == clip.property && event[16] == 0) self.clipboard_property()!;
		default:
	}
}
