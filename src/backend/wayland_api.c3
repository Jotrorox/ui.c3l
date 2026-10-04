// ABI bindings loaded only when Wayland is selected. No Linux link dependency.
module ui::backend @feat(LINUX);
import std::os::env;
import libc;

struct WArray { usz size; usz alloc; void* data; }
union WArg { int i; uint u; ZString s; void* o; WArray* a; }
struct WMessage { ZString name; ZString signature; WInterface** types; }
struct WInterface
{
	ZString name;
	int version;
	int method_count;
	WMessage* methods;
	int event_count;
	WMessage* events;
}

alias WConnect = fn void*(ZString);
alias WVoid = fn void(void*);
alias WInt = fn int(void*);
alias WVersion = fn uint(void*);
alias WDispatch = fn int(void*, void*, uint, WMessage*, WArg*);
alias WListen = fn int(void*, WDispatch, void*, void*);
alias WMarshal = fn void*(void*, uint, WInterface*, uint, uint, WArg*);

macro void? @load_symbol(#field, void* handle, ZString name)
{
	#field = libc::dlsym(handle, name);
	if (!#field) return ui::DISPLAY_UNAVAILABLE~;
}

struct WApi
{
	void* library;
	WConnect connect;
	WVoid disconnect;
	WInt roundtrip;
	WInt dispatch_pending;
	WInt prepare_read;
	WInt read_events;
	WVoid cancel_read;
	WInt flush;
	WInt get_fd;
	WInt get_error;
	WVersion version;
	WVoid destroy;
	WListen listen;
	WMarshal marshal;
	WInterface* registry;
	WInterface* compositor;
	WInterface* surface;
	WInterface* shm;
	WInterface* pool;
	WInterface* buffer;
	WInterface* callback;
	WInterface* seat;
	WInterface* pointer;
	WInterface* keyboard;
}

fn void? WApi.load(&self)
{
	self.library = libc::dlopen("libwayland-client.so.0", libc::RTLD_NOW | libc::RTLD_LOCAL);
	if (!self.library) return ui::DISPLAY_UNAVAILABLE~;
	@load_symbol(self.connect, self.library, "wl_display_connect")!;
	@load_symbol(self.disconnect, self.library, "wl_display_disconnect")!;
	@load_symbol(self.roundtrip, self.library, "wl_display_roundtrip")!;
	@load_symbol(self.dispatch_pending, self.library, "wl_display_dispatch_pending")!;
	@load_symbol(self.prepare_read, self.library, "wl_display_prepare_read")!;
	@load_symbol(self.read_events, self.library, "wl_display_read_events")!;
	@load_symbol(self.cancel_read, self.library, "wl_display_cancel_read")!;
	@load_symbol(self.flush, self.library, "wl_display_flush")!;
	@load_symbol(self.get_fd, self.library, "wl_display_get_fd")!;
	@load_symbol(self.get_error, self.library, "wl_display_get_error")!;
	@load_symbol(self.version, self.library, "wl_proxy_get_version")!;
	@load_symbol(self.destroy, self.library, "wl_proxy_destroy")!;
	@load_symbol(self.listen, self.library, "wl_proxy_add_dispatcher")!;
	@load_symbol(self.marshal, self.library, "wl_proxy_marshal_array_flags")!;
	@load_symbol(self.registry, self.library, "wl_registry_interface")!;
	@load_symbol(self.compositor, self.library, "wl_compositor_interface")!;
	@load_symbol(self.surface, self.library, "wl_surface_interface")!;
	@load_symbol(self.shm, self.library, "wl_shm_interface")!;
	@load_symbol(self.pool, self.library, "wl_shm_pool_interface")!;
	@load_symbol(self.buffer, self.library, "wl_buffer_interface")!;
	@load_symbol(self.callback, self.library, "wl_callback_interface")!;
	@load_symbol(self.seat, self.library, "wl_seat_interface")!;
	@load_symbol(self.pointer, self.library, "wl_pointer_interface")!;
	@load_symbol(self.keyboard, self.library, "wl_keyboard_interface")!;
}

// Stable xdg-shell v1 metadata, matching wayland-protocols/xdg-shell.xml.
// Only toplevel windows are constructed; positioner/popup requests are unused.
struct WShell
{
	WInterface base;
	WInterface surface;
	WInterface toplevel;
	WInterface decoration_manager;
	WInterface decoration;
	WMessage[4] base_requests;
	WMessage[1] base_events;
	WMessage[5] surface_requests;
	WMessage[1] surface_events;
	WMessage[14] top_requests;
	WMessage[2] top_events;
	WInterface*[2] surface_types;
	WInterface*[1] top_types;
	WMessage[2] manager_requests;
	WMessage[3] decoration_requests;
	WMessage[1] decoration_events;
	WInterface*[2] decoration_types;
}

fn void WShell.init(&self, WApi* api)
{
	self.surface_types = { &self.surface, api.surface };
	self.top_types = { &self.toplevel };
	self.base_requests = {
		{ "destroy", "", null }, { "create_positioner", "n", null },
		{ "get_xdg_surface", "no", &self.surface_types }, { "pong", "u", null }
	};
	self.base_events = { { "ping", "u", null } };
	self.surface_requests = {
		{ "destroy", "", null }, { "get_toplevel", "n", &self.top_types },
		{ "get_popup", "n?oo", null }, { "set_window_geometry", "iiii", null },
		{ "ack_configure", "u", null }
	};
	self.surface_events = { { "configure", "u", null } };
	self.top_requests = {
		{ "destroy", "", null }, { "set_parent", "?o", null },
		{ "set_title", "s", null }, { "set_app_id", "s", null },
		{ "show_window_menu", "ouii", null }, { "move", "ou", null },
		{ "resize", "ouu", null }, { "set_max_size", "ii", null },
		{ "set_min_size", "ii", null }, { "set_maximized", "", null },
		{ "unset_maximized", "", null }, { "set_fullscreen", "?o", null },
		{ "unset_fullscreen", "", null }, { "set_minimized", "", null }
	};
	self.top_events = { { "configure", "iia", null }, { "close", "", null } };
	self.base = { "xdg_wm_base", 1, 4, &self.base_requests, 1, &self.base_events };
	self.surface = { "xdg_surface", 1, 5, &self.surface_requests, 1, &self.surface_events };
	self.toplevel = { "xdg_toplevel", 1, 14, &self.top_requests, 2, &self.top_events };
	// Optional xdg-decoration v1: request compositor-provided window controls.
	self.decoration_types = { &self.decoration, &self.toplevel };
	self.manager_requests = {
		{ "destroy", "", null }, { "get_toplevel_decoration", "no", &self.decoration_types }
	};
	self.decoration_requests = {
		{ "destroy", "", null }, { "set_mode", "u", null }, { "unset_mode", "", null }
	};
	self.decoration_events = { { "configure", "u", null } };
	self.decoration_manager = { "zxdg_decoration_manager_v1", 1, 2, &self.manager_requests, 0, null };
	self.decoration = { "zxdg_toplevel_decoration_v1", 1, 3, &self.decoration_requests, 1, &self.decoration_events };
}

alias XContext = fn void*(int);
alias XKeymap = fn void*(void*, ZString, int, int);
alias XState = fn void*(void*);
alias XMask = fn uint(void*, uint, uint, uint, uint, uint, uint);
alias XSym = fn uint(void*, uint);
alias XMod = fn int(void*, ZString, uint);
alias XUtf8 = fn int(void*, uint, char*, usz);
alias XRepeats = fn int(void*, uint);
alias XComposeTable = fn void*(void*, ZString, int);
alias XComposeState = fn void*(void*, int);
alias XComposeStatus = fn int(void*);
alias XComposeUtf8 = fn int(void*, char*, usz);
struct WXkb
{
	void* library;
	XContext context_new;
	XKeymap keymap_new;
	XState state_new;
	WVoid context_unref;
	WVoid keymap_unref;
	WVoid state_unref;
	XMask update_mask;
	XSym sym;
	XMod mod_active;
	XUtf8 utf8;
	XRepeats repeats;
	XComposeTable compose_table_new;
	XComposeState compose_state_new;
	XRepeats compose_feed;
	XComposeStatus compose_status;
	XComposeUtf8 compose_utf8;
	WVoid compose_reset;
	WVoid compose_state_unref;
	WVoid compose_table_unref;
	void* context;
	void* keymap;
	void* state;
	void* compose_table;
	void* compose_state;
	ulong compose_epoch;
}

fn void? WXkb.load(&self)
{
	self.library = libc::dlopen("libxkbcommon.so.0", libc::RTLD_NOW | libc::RTLD_LOCAL);
	if (!self.library) return ui::DISPLAY_UNAVAILABLE~;
	@load_symbol(self.context_new, self.library, "xkb_context_new")!;
	@load_symbol(self.keymap_new, self.library, "xkb_keymap_new_from_string")!;
	@load_symbol(self.state_new, self.library, "xkb_state_new")!;
	@load_symbol(self.context_unref, self.library, "xkb_context_unref")!;
	@load_symbol(self.keymap_unref, self.library, "xkb_keymap_unref")!;
	@load_symbol(self.state_unref, self.library, "xkb_state_unref")!;
	@load_symbol(self.update_mask, self.library, "xkb_state_update_mask")!;
	@load_symbol(self.sym, self.library, "xkb_state_key_get_one_sym")!;
	@load_symbol(self.mod_active, self.library, "xkb_state_mod_name_is_active")!;
	@load_symbol(self.utf8, self.library, "xkb_state_key_get_utf8")!;
	@load_symbol(self.repeats, self.library, "xkb_keymap_key_repeats")!;
	@load_symbol(self.compose_table_new, self.library, "xkb_compose_table_new_from_locale")!;
	@load_symbol(self.compose_state_new, self.library, "xkb_compose_state_new")!;
	@load_symbol(self.compose_feed, self.library, "xkb_compose_state_feed")!;
	@load_symbol(self.compose_status, self.library, "xkb_compose_state_get_status")!;
	@load_symbol(self.compose_utf8, self.library, "xkb_compose_state_get_utf8")!;
	@load_symbol(self.compose_reset, self.library, "xkb_compose_state_reset")!;
	@load_symbol(self.compose_state_unref, self.library, "xkb_compose_state_unref")!;
	@load_symbol(self.compose_table_unref, self.library, "xkb_compose_table_unref")!;
	self.context = self.context_new(0);
	if (!self.context) return ui::PLATFORM_ERROR~;
	@pool()
	{
		String locale = "C.UTF-8";
		foreach (String name : { "LC_ALL", "LC_CTYPE", "LANG" })
		{
			String value = env::tget_var(name) ?? "";
			if (value.len) { locale = value; break; }
		}
		self.compose_table = self.compose_table_new(self.context, locale.zstr_tcopy(), 0);
		if (self.compose_table) self.compose_state = self.compose_state_new(self.compose_table, 0);
	};
}

fn void WXkb.dispose(&self)
{
	if (self.compose_state) self.compose_state_unref(self.compose_state);
	if (self.compose_table) self.compose_table_unref(self.compose_table);
	if (self.state) self.state_unref(self.state);
	if (self.keymap) self.keymap_unref(self.keymap);
	if (self.context) self.context_unref(self.context);
	if (self.library) (void)libc::dlclose(self.library);
}

fn bool WXkb.commit(&self, View* view, uint key, uint symbol)
{
	if (!self.state || !self.utf8) return false;
	char[4097] buffer;
	int length;
	if (self.compose_state)
	{
		if (self.compose_epoch != view.focus_epoch) self.compose_reset(self.compose_state);
		self.compose_epoch = view.focus_epoch;
		(void)self.compose_feed(self.compose_state, symbol);
		int status = self.compose_status(self.compose_state);
		if (status == 1) return false; // composing: no committed text yet.
		if (status == 3) { self.compose_reset(self.compose_state); return false; }
		if (status == 2)
		{
			length = self.compose_utf8(self.compose_state, &buffer[0], @sizeof(buffer));
			self.compose_reset(self.compose_state);
		}
		else { length = self.utf8(self.state, key, &buffer[0], @sizeof(buffer)); }
	}
	else { length = self.utf8(self.state, key, &buffer[0], @sizeof(buffer)); }
	return length > 0 && length < (int)@sizeof(buffer) && view.text_input((String)buffer[:length]);
}

extern fn void* mmap(void*, usz, int, int, int, iptr);
extern fn int munmap(void*, usz);
extern fn int memfd_create(ZString, uint);
extern fn int ftruncate(int, iptr);
extern fn iptr lseek(int, iptr, int);
struct WPollFd { int fd; short events; short revents; }
extern fn int poll(WPollFd*, usz, int);
struct WTime { iptr seconds; iptr nanoseconds; }
extern fn int clock_gettime(int, WTime*);

fn long wayland_time() @private
{
	WTime time;
	(void)clock_gettime(1, &time); // CLOCK_MONOTONIC
	return (long)time.seconds * 1000 + (long)time.nanoseconds / 1000000;
}
