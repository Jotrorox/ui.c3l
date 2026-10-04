module ui::backend @feat(LINUX);
import std::os::env;

enum LinuxBackend { AUTO, X11, WAYLAND }

// X11 and xkbcommon use the same control keysyms, including keypad navigation.
fn ControlKey keysym_control(uint symbol) @private
{
	switch (symbol)
	{
		case 0xff09:
		case 0xfe20: return TAB;
		case 0xff0d:
		case 0xff8d:
		case 0x20: return ACTIVATE;
		case 0xff55:
		case 0xff9a: return PAGE_UP;
		case 0xff56:
		case 0xff9b: return PAGE_DOWN;
		case 0xff50:
		case 0xff95: return SCROLL_HOME;
		case 0xff57:
		case 0xff9c: return SCROLL_END;
		case 0xff51:
		case 0xff96: return LEFT;
		case 0xff53:
		case 0xff98: return RIGHT;
		case 0xff08: return BACKSPACE;
		case 0xffff:
		case 0xff9f: return DELETE;
		default: return NONE;
	}
}

fn LinuxBackend? linux_backend(String override) @private
{
	if (!override.len || override == "auto") return AUTO;
	if (override == "x11") return X11;
	if (override == "wayland") return WAYLAND;
	return ui::INVALID_OPTIONS~;
}

fn bool prefer_wayland(String display, String socket, String session, String runtime, String xdisplay) @private =>
	display.len != 0 || socket.len != 0 || session == "wayland" || (!xdisplay.len && runtime.len != 0);

fn void? open(WindowOptions options, View* view = null) => @pool()
{
	LinuxBackend backend = linux_backend(env::tget_var("UI_BACKEND") ?? "")!;
	if (backend == X11) return open_x11(options, view);
	bool wayland = backend == WAYLAND || prefer_wayland(
		env::tget_var("WAYLAND_DISPLAY") ?? "", env::tget_var("WAYLAND_SOCKET") ?? "",
		env::tget_var("XDG_SESSION_TYPE") ?? "", env::tget_var("XDG_RUNTIME_DIR") ?? "",
		env::tget_var("DISPLAY") ?? "");
	if (wayland)
	{
		WaylandWindow window = { .view = view, .width = options.width, .height = options.height };
		defer window.dispose();
		if (catch failure = window.init())
		{
			// Only startup unavailability permits fallback. Never reopen a visible
			// window on another display after a disconnect or protocol error.
			if (backend == WAYLAND || failure != ui::DISPLAY_UNAVAILABLE) return failure~;
			window.dispose();
		}
		else { return window.run(options); }
	}
	return open_x11(options, view);
}
