module ui;

struct WindowOptions
{
	String title;
	int width;
	int height;
}

excuse
	INVALID_OPTIONS,
	DISPLAY_UNAVAILABLE,
	UNSUPPORTED_DISPLAY,
	AUTHENTICATION_FAILED,
	CONNECTION_FAILED,
	PROTOCOL_ERROR,
	PLATFORM_ERROR;

<*
 Opens a blank native window and processes events until it is closed.
 Call on the main thread. Width and height are initial client-area dimensions
 in pixels. The title must be UTF-8, without NUL bytes, at most 4096 bytes.
 Linux requires a local X11 display (XWayland is supported).
 All native resources are released before returning, including on failure.
*>
fn void? open_window(String title = "ui", int width = 800, int height = 600)
{
	WindowOptions options = { title, width, height };
	validate_options(options)!;
	return backend::open(options);
}

fn void? validate_options(WindowOptions options) @private
{
	if (options.width < 1 || options.width > 65535 ||
		options.height < 1 || options.height > 65535 || options.title.len > 4096) return INVALID_OPTIONS~;
	foreach (c : options.title) if (c == 0) return INVALID_OPTIONS~;
	@pool()
	{
		if (catch options.title.to_temp_utf16()) return INVALID_OPTIONS~;
	};
}
