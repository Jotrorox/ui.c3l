// Minimal local X11 client. Wire integers are explicitly little endian.
// Protocol: https://www.x.org/releases/current/doc/xproto/x11protocol.html
module ui::backend @feat(LINUX);
import libc, std::io::file, std::os::env;

struct UnixAddress
{
	ushort family;
	char[108] path;
}

extern fn int socket(int domain, int type, int protocol);
extern fn int connect(int fd, UnixAddress* address, uint length);
extern fn sz recv(int fd, void* buffer, sz length, int flags);
extern fn sz send(int fd, void* buffer, sz length, int flags);
extern fn int close(int fd);
extern fn int gethostname(char* buffer, sz length);

struct XConnection
{
	int fd;
	ushort sequence;
}

// Count requests, not send() fragments; replies carry the low 16 bits.
fn void? XConnection.request(&self, char[] header)
{
	self.sequence = (ushort)((uint)self.sequence + 1);
	return send_all(self.fd, header);
}

struct Display
{
	uint number;
	uint screen;
}

struct Setup
{
	uint window;
	uint root;
	uint white_pixel;
	uint black_pixel;
	uint resource_base;
	uint resource_mask;
	char min_keycode;
	char max_keycode;
	uint colormap;
}

fn ushort read16(char[] data, sz offset) @private => (ushort)((uint)data[offset] | (uint)data[offset + 1] << 8);
fn uint read32(char[] data, sz offset) @private => (uint)read16(data, offset) | (uint)read16(data, offset + 2) << 16;
fn void write16(char[] data, sz offset, uint value) @private
{
	data[offset] = (char)value;
	data[offset + 1] = (char)(value >> 8);
}
fn void write32(char[] data, sz offset, uint value) @private
{
	write16(data, offset, value);
	write16(data, offset + 2, value >> 16);
}
fn sz padded(sz length) @private => (length + 3) & ~(sz)3;

fn uint? decimal(String value) @private
{
	if (!value.len) return ui::UNSUPPORTED_DISPLAY~;
	uint number;
	foreach (c : value)
	{
		if (c < '0' || c > '9' || number > 6553) return ui::UNSUPPORTED_DISPLAY~;
		number = number * 10 + c - '0';
		if (number > 65535) return ui::UNSUPPORTED_DISPLAY~;
	}
	return number;
}

fn Display? parse_display(String value) @private
{
	if (value.starts_with("unix/")) value = value[5..];
	if (value.starts_with("unix:")) value = value[4..];
	if (!value.starts_with(":")) return ui::UNSUPPORTED_DISPLAY~;
	value = value[1..];
	foreach (i, c : value)
	{
		if (c == '.') return { decimal(value[:i])!, decimal(value[i + 1..])! };
	}
	return { decimal(value)!, 0 };
}

fn void? send_all(int fd, char[] data) @private
{
	while (data.len)
	{
		sz count = send(fd, data.ptr, data.len, 0x4000); // MSG_NOSIGNAL
		if (count < 0 && libc::errno() == EINTR) continue;
		if (count <= 0) return ui::CONNECTION_FAILED~;
		data = data[count..];
	}
}

fn void? receive_all(int fd, char[] data) @private
{
	while (data.len)
	{
		sz count = recv(fd, data.ptr, data.len, 0);
		if (count < 0 && libc::errno() == EINTR) continue;
		if (count <= 0) return ui::CONNECTION_FAILED~;
		data = data[count..];
	}
}

// Xauthority fields have big-endian lengths, independently of X11 byte order.
fn char[]? auth_field(char[]* remaining) @private
{
	char[] data = *remaining;
	if (data.len < 2) return ui::AUTHENTICATION_FAILED~;
	sz length = (sz)data[0] << 8 | data[1];
	if (length > data.len - 2) return ui::AUTHENTICATION_FAILED~;
	*remaining = data[2 + length..];
	return data[2:length];
}

fn char[]? find_cookie(char[] data, String number, String hostname) @private
{
	while (data.len)
	{
		if (data.len < 2) return ui::AUTHENTICATION_FAILED~;
		uint family = (uint)data[0] << 8 | data[1];
		data = data[2..];
		char[] address = auth_field(&data)!;
		char[] display = auth_field(&data)!;
		char[] name = auth_field(&data)!;
		char[] cookie = auth_field(&data)!;
		if ((family == 65535 || (family == 256 && (String)address == hostname)) &&
			(String)display == number && (String)name == "MIT-MAGIC-COOKIE-1" && cookie.len == 16) return cookie;
	}
	return {};
}

fn char[]? load_cookie(uint number) @private
{
	String path = env::tget_var("XAUTHORITY") ?? "";
	if (!path.len)
	{
		String home = env::tget_var("HOME") ?? "";
		if (!home.len) return {};
		path = string::tformat("%s/.Xauthority", home);
	}
	// A missing file is valid for displays that allow unauthenticated clients.
	if (!file::exists(path)) return {};
	char[] buffer = ((char*)mem::tmalloc(65536))[:65536];
	char[] data = (file::load_buffer(path, buffer) ?? ui::AUTHENTICATION_FAILED~)!;
	char[256] host;
	if (gethostname(&host, host.len - 1) != 0) return ui::AUTHENTICATION_FAILED~;
	sz length;
	while (length < host.len && host[length]) length++;
	return find_cookie(data, string::tformat("%s", number), (String)host[:length]);
}

fn Setup? parse_setup(char[] data, uint screen) @private
{
	if (data.len < 32 || screen >= data[20]) return ui::PROTOCOL_ERROR~;
	uint base = read32(data, 4);
	uint mask = read32(data, 8);
	if (!mask || (base & mask)) return ui::PROTOCOL_ERROR~;
	sz offset = 32 + padded(read16(data, 16)) + (sz)data[21] * 8;
	for (uint index = 0; index <= screen; index++)
	{
		if (offset > data.len || data.len - offset < 40) return ui::PROTOCOL_ERROR~;
		if (index == screen)
		{
			return { base | (mask & (~mask + 1)), read32(data, offset), read32(data, offset + 8),
				read32(data, offset + 12), base, mask, data[26], data[27], read32(data, offset + 4) };
		}
		uint depths = data[offset + 39];
		offset += 40;
		for (uint depth = 0; depth < depths; depth++)
		{
			if (offset > data.len || data.len - offset < 8) return ui::PROTOCOL_ERROR~;
			sz size = 8 + (sz)read16(data, offset + 2) * 24;
			if (size > data.len - offset) return ui::PROTOCOL_ERROR~;
			offset += size;
		}
	}
	return ui::PROTOCOL_ERROR~;
}

fn Setup? handshake(int fd, Display display) @private
{
	char[] cookie = load_cookie(display.number)!;
	String name = cookie.len ? "MIT-MAGIC-COOKIE-1" : "";
	char[48] request;
	request[0] = 'l';
	write16(request[..], 2, 11);
	write16(request[..], 6, (uint)name.len);
	write16(request[..], 8, (uint)cookie.len);
	request[12:name.len] = ((char[])name)[..];
	request[12 + padded(name.len):cookie.len] = cookie[..];
	send_all(fd, request[:12 + padded(name.len) + padded(cookie.len)])!;
	char[8] header;
	receive_all(fd, header[..])!;
	if (header[0] != 1) return ui::AUTHENTICATION_FAILED~;
	if (read16(header[..], 2) != 11) return ui::PROTOCOL_ERROR~;
	sz length = (sz)read16(header[..], 6) * 4;
	char[] data = ((char*)mem::tmalloc(length))[:length];
	receive_all(fd, data)!;
	return parse_setup(data, display.screen);
}

fn void? discard_payload(int fd, uint words) @private
{
	ulong remaining = (ulong)words * 4;
	char[4096] buffer;
	while (remaining)
	{
		sz count = remaining > buffer.len ? buffer.len : (sz)remaining;
		receive_all(fd, buffer[:count])!;
		remaining -= (ulong)count;
	}
}

// Consume complete messages, including variable-length extension events.
fn char[32]? receive_message(int fd) @private
{
	char[32] message;
	receive_all(fd, message[..])!;
	uint type = message[0] & 0x7f;
	if (type == 0) return ui::PROTOCOL_ERROR~;
	if (type == 1 || type == 35)
	{
		discard_payload(fd, read32(message[..], 4))!;
	}
	return message;
}

fn uint? intern_atom(XConnection* connection, String name) @private
{
	char[64] request;
	request[0] = 16;
	write16(request[..], 2, (uint)(8 + padded(name.len)) / 4);
	write16(request[..], 4, (uint)name.len);
	request[8:name.len] = ((char[])name)[..];
	connection.request(request[:8 + padded(name.len)])!;
	char[32] reply = receive_message(connection.fd)!;
	if (reply[0] != 1 || !read32(reply[..], 8)) return ui::PROTOCOL_ERROR~;
	return read32(reply[..], 8);
}

fn void? change_property(XConnection* connection, uint window, uint property, uint type, char format, char[] data) @private
{
	char[24] header;
	header[0] = 18;
	write16(header[..], 2, (uint)(24 + padded(data.len)) / 4);
	write32(header[..], 4, window);
	write32(header[..], 8, property);
	write32(header[..], 12, type);
	header[16] = format;
	write32(header[..], 20, (uint)data.len / ((uint)format / 8));
	connection.request(header[..])!;
	send_all(connection.fd, data)!;
	char[3] padding;
	send_all(connection.fd, padding[:padded(data.len) - data.len])!;
}

fn bool is_close_event(char[] message, uint window, uint protocols, uint delete_window) @private
{
	uint type = message[0] & 0x7f;
	if (type == 17) return read32(message, 8) == window; // DestroyNotify
	return type == 33 && message[1] == 32 && read32(message, 4) == window &&
		read32(message, 8) == protocols && read32(message, 12) == delete_window;
}

fn void? open_x11(WindowOptions options, View* view = null) => @pool()
{
	String value = (env::tget_var("DISPLAY") ?? ui::DISPLAY_UNAVAILABLE~)!;
	if (!value.len) return ui::DISPLAY_UNAVAILABLE~;
	Display display = parse_display(value)!;
	int fd = socket(1, 1 | 0x80000, 0); // AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC
	if (fd < 0) return ui::DISPLAY_UNAVAILABLE~;
	defer (void)close(fd); // Disconnecting destroys every resource owned by this client.
	String path = string::tformat("/tmp/.X11-unix/X%s", display.number);
	UnixAddress address = { .family = 1 };
	address.path[:path.len] = ((char[])path)[..];
	if (connect(fd, &address, (uint)(2 + path.len + 1)) != 0)
	{
		// Linux also supports X servers listening only in the abstract namespace.
		address.path = {};
		address.path[1:path.len] = ((char[])path)[..];
		if (connect(fd, &address, (uint)(3 + path.len)) != 0) return ui::DISPLAY_UNAVAILABLE~;
	}
	Setup setup = handshake(fd, display)!;
	XConnection connection = { .fd = fd };
	uint protocols = intern_atom(&connection, "WM_PROTOCOLS")!;
	uint delete_window = intern_atom(&connection, "WM_DELETE_WINDOW")!;
	uint net_name = intern_atom(&connection, "_NET_WM_NAME")!;
	uint utf8 = intern_atom(&connection, "UTF8_STRING")!;
	XCanvas canvas = { .connection = &connection, .setup = setup, .view = view };
	defer canvas.dispose();
	if (view)
	{
		canvas.init()!;
		canvas.init_clipboard()!;
		view.set_clipboard(&x11_clipboard_write, &x11_clipboard_read, &canvas);
	}
	char[40] create;
	create[0] = 1; // CreateWindow; depth and visual inherit from the root.
	write16(create[..], 2, 10);
	write32(create[..], 4, setup.window);
	write32(create[..], 8, setup.root);
	write16(create[..], 16, (uint)options.width);
	write16(create[..], 18, (uint)options.height);
	write16(create[..], 22, 1); // InputOutput
	write32(create[..], 28, 2 | 0x800); // background-pixel, event-mask
	write32(create[..], 32, setup.white_pixel);
	// Structure, exposure, mouse, keyboard and focus events for retained views.
	write32(create[..], 36, view ? 0x62c07f : 1 << 17); // Includes PropertyChange for INCR.
	connection.request(create[..])!;
	char[4] atom;
	write32(atom[..], 0, delete_window);
	change_property(&connection, setup.window, protocols, 4, 32, atom[..])!; // ATOM
	change_property(&connection, setup.window, 39, 31, 8, (char[])options.title)!; // WM_NAME / STRING
	change_property(&connection, setup.window, net_name, utf8, 8, (char[])options.title)!;
	char[8] map;
	map[0] = 8;
	write16(map[..], 2, 2);
	write32(map[..], 4, setup.window);
	connection.request(map[..])!;
	if (view)
	{
		view.set_measurer(&measure_xtext, &canvas);
		view.update();
		view.invalidate({ 0, 0, view.width, view.height });
		canvas.paint(view)!;
	}
	while (true)
	{
		char[32] message = view ? canvas.next_event()! : receive_message(fd)!;
		if (is_close_event(message[..], setup.window, protocols, delete_window)) return;
		if (view)
		{
			canvas.event(view, message[..])!;
			view.update();
			canvas.paint(view)!;
		}
	}
}
