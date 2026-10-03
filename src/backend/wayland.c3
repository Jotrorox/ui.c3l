// Native Wayland toplevels using stable xdg-shell and wl_shm buffers.
// Protocol/API: https://wayland.freedesktop.org/docs/html/apb.html
module ui::backend @feat(LINUX);
import libc, std::math;

struct WaylandWindow
{
	WApi api;
	WShell shell;
	WXkb xkb;
	WCanvas canvas;
	View* view;
	void* display;
	void* registry;
	void* compositor;
	void* shm;
	void* base;
	void* decoration_manager;
	void* decoration;
	void* seat;
	void* pointer;
	void* keyboard;
	void* surface;
	void* xsurface;
	void* toplevel;
	void* frame;
	void* cursor_surface;
	WBuffer cursor;
	WBuffer[3] buffers;
	uint compositor_name;
	uint shm_name;
	uint base_name;
	uint seat_name;
	int width;
	int height;
	int pending_width;
	int pending_height;
	bool configured;
	bool redraw;
	bool closed;
	bool xrgb;
	bool pointer_inside;
	int pointer_x;
	int pointer_y;
	int axis_fixed;
	int axis_discrete;
	int wheel_remainder;
	uint depressed;
	uint latched;
	uint locked;
	uint group;
	int repeat_rate;
	int repeat_delay;
	uint repeat_key;
	long repeat_at;
	bool repeating;
	ulong repeat_epoch;
	bool repeat_text;
	fault failure;
}

fn void WaylandWindow.request(&self, void* proxy, uint opcode, WArg[] args)
{
	(void)self.api.marshal(proxy, opcode, null, self.api.version(proxy), 0, args.ptr);
}

fn void*? WaylandWindow.construct(&self, void* proxy, uint opcode, WInterface* iface, uint version, WArg[] args)
{
	void* result = self.api.marshal(proxy, opcode, iface, version, 0, args.ptr);
	if (!result) return ui::PLATFORM_ERROR~;
	return result;
}

fn void WaylandWindow.destroy_request(&self, void* proxy, uint opcode)
{
	(void)self.api.marshal(proxy, opcode, null, self.api.version(proxy), 1, null);
}

fn void? WaylandWindow.listen(&self, void* proxy)
{
	if (self.api.listen(proxy, &wayland_dispatch, self, null)) return ui::PLATFORM_ERROR~;
}

fn void*? WaylandWindow.bind(&self, uint name, WInterface* iface, uint version)
{
	WArg[4] args = { { .u = name }, { .s = iface.name }, { .u = version }, { .o = null } };
	void* proxy = self.construct(self.registry, 0, iface, version, args[..])!;
	defer catch self.api.destroy(proxy);
	self.listen(proxy)!;
	return proxy;
}

fn void? WaylandWindow.check(&self)
{
	if (self.failure) return self.failure~;
	int error = self.api.get_error(self.display);
	if (error) return error == 71 ? ui::PROTOCOL_ERROR~ : ui::CONNECTION_FAILED~; // EPROTO
}

fn void? WaylandWindow.init(&self)
{
	self.api.load()!;
	self.shell.init(&self.api);
	self.display = self.api.connect(null); // Honors WAYLAND_DISPLAY / WAYLAND_SOCKET.
	if (!self.display) return ui::DISPLAY_UNAVAILABLE~;
	WArg[1] args;
	self.registry = self.construct(self.display, 1, self.api.registry, 1, args[..])!;
	self.listen(self.registry)!;
	(void)self.api.roundtrip(self.display);
	self.check()!;
	if (!self.compositor || !self.shm || !self.base) return ui::DISPLAY_UNAVAILABLE~;
	if (self.view)
	{
		self.canvas.load()!;
		self.xkb.load()!;
	}
	// Receive shm formats, seat capabilities and the initial keymap.
	(void)self.api.roundtrip(self.display);
	self.check()!;
	if (!self.xrgb) return ui::DISPLAY_UNAVAILABLE~;
}

fn void WaylandWindow.dispose(&self)
{
	// Destroy every local proxy before disconnecting, also after partial init.
	if (self.api.destroy)
	{
		foreach (&buffer : self.buffers) buffer.dispose(&self.api);
		self.cursor.dispose(&self.api);
		foreach (proxy : (void*[14]){ self.frame, self.decoration, self.decoration_manager, self.toplevel, self.xsurface, self.surface,
			self.cursor_surface, self.pointer, self.keyboard, self.seat, self.base,
			self.shm, self.compositor, self.registry })
		{
			if (proxy) self.api.destroy(proxy);
		}
	}
	if (self.display) self.api.disconnect(self.display);
	self.canvas.dispose();
	self.xkb.dispose();
	if (self.api.library) (void)libc::dlclose(self.api.library);
	*self = {};
}

fn void? WaylandWindow.run(&self, WindowOptions options) => @pool()
{
	WArg[1] args;
	self.surface = self.construct(self.compositor, 0, self.api.surface, self.api.version(self.compositor), args[..])!;
	self.listen(self.surface)!;
	WArg[2] xargs = { { .o = null }, { .o = self.surface } };
	self.xsurface = self.construct(self.base, 2, &self.shell.surface, 1, xargs[..])!;
	self.listen(self.xsurface)!;
	self.toplevel = self.construct(self.xsurface, 1, &self.shell.toplevel, 1, args[..])!;
	self.listen(self.toplevel)!;
	if (self.decoration_manager)
	{
		WArg[2] decoration = { { .o = null }, { .o = self.toplevel } };
		self.decoration = self.construct(self.decoration_manager, 1, &self.shell.decoration, 1, decoration[..])!;
		self.listen(self.decoration)!;
		WArg[1] mode = { { .u = 2 } }; // server_side
		self.request(self.decoration, 1, mode[..]);
	}
	WArg[1] title = { { .s = options.title.zstr_tcopy() } };
	self.request(self.toplevel, 2, title[..]);
	WArg[1] app_id = { { .s = "ui.c3l" } };
	self.request(self.toplevel, 3, app_id[..]);
	if (self.view)
	{
		self.view.set_measurer(&measure_wayland_text, &self.canvas);
		self.view.update();
	}
	self.redraw = true;
	// The first commit is bufferless. Wait for xdg_surface.configure and ack it.
	self.request(self.surface, 6, {});
	while (!self.closed)
	{
		self.check()!;
		self.paint()!;
		while (self.api.prepare_read(self.display) != 0)
		{
			if (self.api.dispatch_pending(self.display) < 0) self.check()!;
			self.check()!;
			if (self.closed) return;
			self.paint()!;
		}
		int flushed = self.api.flush(self.display);
		bool blocked = flushed < 0 && libc::errno() == EAGAIN;
		if (flushed < 0 && !blocked)
		{
			self.api.cancel_read(self.display);
			return ui::CONNECTION_FAILED~;
		}
		WPollFd fd = { self.api.get_fd(self.display), (short)(1 | (blocked ? 4 : 0)), 0 };
		int timeout = self.repeating ? (int)math::clamp(self.repeat_at - wayland_time(), 0L, (long)int::max) : -1;
		int ready = poll(&fd, 1, timeout);
		if (ready < 0)
		{
			self.api.cancel_read(self.display);
			if (libc::errno() == EINTR) continue;
			return ui::CONNECTION_FAILED~;
		}
		if (fd.revents & (1 | 8 | 16))
		{
			if (self.api.read_events(self.display) < 0) self.check()!;
		}
		else { self.api.cancel_read(self.display); }
		if (self.api.dispatch_pending(self.display) < 0) self.check()!;
		self.check()!;
		if (self.repeating && !self.closed && wayland_time() >= self.repeat_at)
		{
			self.key(self.repeat_key, true, true);
			self.repeat_at = wayland_time() + math::max(1, 1000 / self.repeat_rate);
		}
	}
}

fn void? WaylandWindow.global(&self, uint name, String iface, uint version)
{
	if (!version) return ui::PROTOCOL_ERROR~;
	if (iface == "wl_compositor" && !self.compositor)
	{
		self.compositor = self.bind(name, self.api.compositor, math::min(version, 4u))!;
		self.compositor_name = name;
	}
	else if (iface == "wl_shm" && !self.shm)
	{
		self.shm = self.bind(name, self.api.shm, 1)!;
		self.shm_name = name;
	}
	else if (iface == "xdg_wm_base" && !self.base)
	{
		self.base = self.bind(name, &self.shell.base, 1)!;
		self.base_name = name;
	}
	else if (iface == "wl_seat" && !self.seat && self.view)
	{
		self.seat = self.bind(name, self.api.seat, math::min(version, 5u))!;
		self.seat_name = name;
	}
	else if (iface == "zxdg_decoration_manager_v1" && !self.decoration_manager)
	{
		self.decoration_manager = self.bind(name, &self.shell.decoration_manager, 1)!;
	}
}

fn void? WaylandWindow.capabilities(&self, uint capabilities)
{
	WArg[1] args;
	if ((capabilities & 1) && !self.pointer)
	{
		self.pointer = self.construct(self.seat, 0, self.api.pointer, self.api.version(self.seat), args[..])!;
		self.listen(self.pointer)!;
	}
	else if (!(capabilities & 1) && self.pointer)
	{
		if (self.api.version(self.pointer) >= 3) { self.destroy_request(self.pointer, 1); }
		else { self.api.destroy(self.pointer); }
		self.pointer = null;
		self.pointer_inside = false;
		self.axis_fixed = self.axis_discrete = self.wheel_remainder = 0;
		if (self.view) { self.view.cancel_press(); self.view.pointer_move(-1, -1); }
	}
	if ((capabilities & 2) && !self.keyboard)
	{
		self.keyboard = self.construct(self.seat, 1, self.api.keyboard, self.api.version(self.seat), args[..])!;
		self.listen(self.keyboard)!;
	}
	else if (!(capabilities & 2) && self.keyboard)
	{
		if (self.api.version(self.keyboard) >= 3) { self.destroy_request(self.keyboard, 0); }
		else { self.api.destroy(self.keyboard); }
		self.keyboard = null;
		self.repeating = false;
		if (self.view) self.view.blur();
	}
}

fn void? WaylandWindow.keymap(&self, uint format, int fd, uint size)
{
	defer (void)close(fd);
	if (!self.view || !self.xkb.context) return;
	if (self.xkb.compose_state) self.xkb.compose_reset(self.xkb.compose_state);
	if (format == 0) // wl_keyboard.keymap_format.no_keymap
	{
		if (self.xkb.state) self.xkb.state_unref(self.xkb.state);
		if (self.xkb.keymap) self.xkb.keymap_unref(self.xkb.keymap);
		self.xkb.state = self.xkb.keymap = null;
		self.repeating = false;
		return;
	}
	if (format != 1 || !size || size > 16 * 1024 * 1024) return ui::PROTOCOL_ERROR~;
	if (lseek(fd, 0, 2) < (iptr)size) return ui::PROTOCOL_ERROR~; // Avoid SIGBUS on a truncated keymap fd.
	void* mapping = mmap(null, size, 1, 2, fd, 0); // PROT_READ, MAP_PRIVATE
	if (mapping == (void*)(uptr)-1) return ui::PLATFORM_ERROR~;
	defer (void)munmap(mapping, size);
	if (((char*)mapping)[size - 1] != 0) return ui::PROTOCOL_ERROR~;
	void* keymap = self.xkb.keymap_new(self.xkb.context, (ZString)mapping, 1, 0);
	if (!keymap) return ui::PROTOCOL_ERROR~;
	void* state = self.xkb.state_new(keymap);
	if (!state) { self.xkb.keymap_unref(keymap); return ui::PLATFORM_ERROR~; }
	if (self.xkb.state) self.xkb.state_unref(self.xkb.state);
	if (self.xkb.keymap) self.xkb.keymap_unref(self.xkb.keymap);
	self.xkb.keymap = keymap;
	self.xkb.state = state;
	(void)self.xkb.update_mask(state, self.depressed, self.latched, self.locked, 0, 0, self.group);
	self.repeating = false;
}

fn void WaylandWindow.key(&self, uint key, bool down, bool repeat = false)
{
	// View's native identities are 8-bit. Linux control keys fit this range;
	// ignore extended keys instead of aliasing them onto held activation keys.
	if (!self.view || key >= 256) return;
	if (!down)
	{
		self.view.key_up((char)key);
		if (self.repeating && self.repeat_key == key) self.repeating = false;
		return;
	}
	self.view.update();
	if (repeat && self.repeat_text && self.repeat_epoch != self.view.focus_epoch) { self.repeating = false; return; }
	ulong epoch = self.view.focus_epoch;
	if (self.xkb.compose_state && self.xkb.compose_epoch != epoch) self.xkb.compose_reset(self.xkb.compose_state);
	uint sym = self.xkb.state ? self.xkb.sym(self.xkb.state, key + 8) : 0;
	ControlKey action = keysym_control(sym);
	bool shift = self.xkb.state && self.xkb.mod_active(self.xkb.state, "Shift", 1 << 3) > 0;
	bool control = self.xkb.state && self.xkb.mod_active(self.xkb.state, "Control", 1 << 3) > 0;
	bool shortcut = control || (self.xkb.state && (self.xkb.mod_active(self.xkb.state, "Mod1", 1 << 3) > 0 ||
		self.xkb.mod_active(self.xkb.state, "Mod4", 1 << 3) > 0));
	if (shortcut) action = control && (sym == 'a' || sym == 'A') ? SELECT_ALL : NONE;
	if (self.view.focused && self.view.focused.kind == TEXT_FIELD && action == BACKSPACE &&
		self.xkb.compose_state && self.xkb.compose_status(self.xkb.compose_state) == 1)
	{
		self.xkb.compose_reset(self.xkb.compose_state);
		self.view.key_down((char)key, NONE, repeat, shift);
		self.repeating = false;
		return;
	}
	self.view.key_down((char)key, action, repeat, shift);
	bool committed;
	bool field = self.view.focused && self.view.focused.kind == TEXT_FIELD;
	if (!shortcut && epoch == self.view.focus_epoch && field && (action == NONE || sym == 0x20))
	{
		committed = self.xkb.commit(self.view, key + 8, sym);
	}
	else if (self.xkb.compose_state) { self.xkb.compose_reset(self.xkb.compose_state); }
	if (!repeat)
	{
		self.repeat_text = field && action != TAB && action != PAGE_UP && action != PAGE_DOWN;
		self.repeating = (action == TAB || action == PAGE_UP || action == PAGE_DOWN ||
			action == SCROLL_HOME || action == SCROLL_END || (field && (committed ||
			action == LEFT || action == RIGHT || action == BACKSPACE || action == DELETE))) && self.repeat_rate > 0;
		if (self.xkb.keymap && self.xkb.repeats && !self.xkb.repeats(self.xkb.keymap, key + 8)) self.repeating = false;
		if (self.repeating)
		{
			self.repeat_key = key;
			self.repeat_epoch = epoch;
			self.repeat_at = wayland_time() + self.repeat_delay;
		}
	}
}

fn void WaylandWindow.wheel(&self)
{
	if (self.view && self.pointer_inside)
	{
		int pixels;
		if (self.axis_discrete)
		{
			pixels = (int)math::clamp((long)self.axis_discrete * 40, (long)int::min, (long)int::max);
			self.wheel_remainder = 0;
		}
		else
		{
			// Wayland's continuous axis unit is 10 surface units per wheel step.
			long scaled = (long)self.axis_fixed + self.wheel_remainder;
			pixels = (int)(scaled / 64);
			self.wheel_remainder = (int)(scaled % 64);
		}
		if (pixels) self.view.scroll_wheel(self.pointer_x, self.pointer_y, pixels);
	}
	self.axis_fixed = self.axis_discrete = 0;
}

fn void? WaylandWindow.show_cursor(&self, uint serial)
{
	if (!self.cursor_surface)
	{
		WArg[1] args;
		self.cursor_surface = self.construct(self.compositor, 0, self.api.surface, self.api.version(self.compositor), args[..])!;
		self.listen(self.cursor_surface)!;
		self.cursor.init(self, 24, 24, 0)!; // ARGB8888 with a transparent background.
		uint[] pixels = ((uint*)self.cursor.pixels)[:24 * 24];
		for (int y = 0; y < 20; y++)
		{
			for (int x = 0; x <= y / 2; x++) pixels[y * 24 + x] = x == 0 || x == y / 2 || y == 19 ? 0xff000000 : 0xffffffff;
		}
		WArg[3] attach = { { .o = self.cursor.proxy }, { .i = 0 }, { .i = 0 } };
		self.request(self.cursor_surface, 1, attach[..]);
		WArg[4] damage = { { .i = 0 }, { .i = 0 }, { .i = 24 }, { .i = 24 } };
		self.request(self.cursor_surface, 2, damage[..]);
		self.request(self.cursor_surface, 6, {});
	}
	WArg[4] cursor = { { .u = serial }, { .o = self.cursor_surface }, { .i = 0 }, { .i = 0 } };
	self.request(self.pointer, 0, cursor[..]);
}

fn void? WaylandWindow.event(&self, void* target, uint opcode, WArg* args)
{
	if (target == self.registry)
	{
		if (opcode == 0) return self.global(args[0].u, args[1].s.str_view(), args[2].u);
		uint name = args[0].u;
		if (name == self.seat_name && self.seat)
		{
			self.capabilities(0)!;
			self.api.destroy(self.seat);
			self.seat = null;
			self.seat_name = 0;
		}
		else if (name == self.compositor_name || name == self.shm_name || name == self.base_name)
		{
			return ui::DISPLAY_UNAVAILABLE~;
		}
	}
	else if (target == self.shm)
	{
		if (args[0].u == 1) self.xrgb = true;
	}
	else if (target == self.base)
	{
		WArg[1] pong = { { .u = args[0].u } };
		self.request(self.base, 3, pong[..]);
	}
	else if (target == self.toplevel)
	{
		if (opcode == 1) { self.closed = true; return; }
		if (args[0].i < 0 || args[1].i < 0 || args[0].i > 65535 || args[1].i > 65535) return ui::PROTOCOL_ERROR~;
		self.pending_width = args[0].i;
		self.pending_height = args[1].i;
	}
	else if (target == self.xsurface)
	{
		WArg[1] ack = { { .u = args[0].u } };
		self.request(self.xsurface, 4, ack[..]);
		if (self.pending_width) self.width = self.pending_width;
		if (self.pending_height) self.height = self.pending_height;
		self.configured = true;
		self.redraw = true;
		if (self.view) self.view.resize(self.width, self.height);
	}
	else if (target == self.frame)
	{
		self.api.destroy(self.frame);
		self.frame = null;
	}
	else if (target == self.seat)
	{
		if (opcode == 0) return self.capabilities(args[0].u);
	}
	else if (target == self.pointer)
	{
		switch (opcode)
		{
			case 0: // enter
				if (args[1].o != self.surface) return;
				self.pointer_inside = true;
				self.pointer_x = args[2].i / 256;
				self.pointer_y = args[3].i / 256;
				self.show_cursor(args[0].u)!;
				if (self.view) self.view.pointer_move(self.pointer_x, self.pointer_y);
			case 1: // leave: compositor's implicit grab ends before leave.
				self.pointer_inside = false;
				self.axis_fixed = self.axis_discrete = self.wheel_remainder = 0;
				if (self.view) { self.view.cancel_press(); self.view.pointer_move(-1, -1); }
			case 2: // motion, including signed coordinates during an implicit grab.
				self.pointer_x = args[1].i / 256;
				self.pointer_y = args[2].i / 256;
				if (self.view && self.pointer_inside) self.view.pointer_move(self.pointer_x, self.pointer_y);
			case 3: // BTN_LEFT
				if (!self.view || !self.pointer_inside || args[2].u != 0x110) return;
				if (args[3].u == 1) { self.view.pointer_down(self.pointer_x, self.pointer_y,
					self.xkb.state && self.xkb.mod_active(self.xkb.state, "Shift", 1 << 3) > 0); }
				else { self.view.pointer_up(self.pointer_x, self.pointer_y); }
			case 4: // vertical axis
				if (args[1].u == 0) self.axis_fixed = (int)math::clamp((long)self.axis_fixed + args[2].i, (long)int::min, (long)int::max);
				if (self.api.version(self.pointer) < 5) self.wheel();
			case 5: self.wheel(); // frame: discrete and continuous represent the same motion.
			case 7: if (args[1].u == 0) self.wheel_remainder = 0; // axis_stop
			case 8:
				if (args[0].u == 0) self.axis_discrete = (int)math::clamp((long)self.axis_discrete + args[1].i, (long)int::min, (long)int::max);
			default:
		}
	}
	else if (target == self.keyboard)
	{
		switch (opcode)
		{
			case 0: return self.keymap(args[0].u, args[1].i, args[2].u);
			case 1: // enter: reconcile keys held while another window had focus.
				if (!self.view || args[1].o != self.surface) return;
				if (args[2].a.size % 4) return ui::PROTOCOL_ERROR~;
				self.view.held_keys = {};
				uint[] keys = ((uint*)args[2].a.data)[:args[2].a.size / 4];
				foreach (key : keys) if (key < 256) self.view.held_keys[key] = true;
				self.repeating = false;
			case 2: self.repeating = false; if (self.view) self.view.blur();
			case 3: self.key(args[2].u, args[3].u != 0);
			case 4:
				self.depressed = args[1].u;
				self.latched = args[2].u;
				self.locked = args[3].u;
				self.group = args[4].u;
				if (self.xkb.state) (void)self.xkb.update_mask(self.xkb.state, self.depressed, self.latched, self.locked, 0, 0, self.group);
			case 5:
				self.repeat_rate = math::clamp(args[0].i, 0, 1000);
				self.repeat_delay = math::max(0, args[1].i);
				if (!self.repeat_rate) self.repeating = false;
			default:
		}
	}
	else
	{
		foreach (&buffer : self.buffers) if (target == buffer.proxy) buffer.busy = false;
	}
}

fn int wayland_dispatch(void* context, void* target, uint opcode, WMessage* message, WArg* args) @private
{
	WaylandWindow* window = context;
	// keymap descriptors must be consumed/closed even if an earlier event failed.
	if (window.failure)
	{
		if (target == window.keyboard && opcode == 0) (void)close(args[1].i);
		return 0;
	}
	if (catch failure = window.event(target, opcode, args)) window.failure = failure;
	return 0;
}
