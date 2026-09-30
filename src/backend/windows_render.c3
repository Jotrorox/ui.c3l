module ui::backend @feat(WIN32);
import std::os::win32;

extern fn Win32_HDC get_dc(Win32_HWND hwnd) @cname("GetDC");
extern fn int release_dc(Win32_HWND hwnd, Win32_HDC dc) @cname("ReleaseDC");
extern fn Win32_HGDIOBJ get_stock_object(int object) @cname("GetStockObject");
extern fn Win32_HGDIOBJ select_object(Win32_HDC dc, Win32_HGDIOBJ object) @cname("SelectObject");
extern fn Win32_BOOL get_text_extent(Win32_HDC dc, Win32_LPCWSTR text, int length, Win32_SIZE* size) @cname("GetTextExtentPoint32W");
extern fn int fill_rect(Win32_HDC dc, Win32_RECT* rect, Win32_HBRUSH brush) @cname("FillRect");
extern fn int select_clip(Win32_HDC dc, Win32_HANDLE region) @cname("SelectClipRgn");
extern fn int intersect_clip(Win32_HDC dc, int left, int top, int right, int bottom) @cname("IntersectClipRect");
extern fn Win32_BOOL invalidate_rect(Win32_HWND hwnd, Win32_RECT* rect, Win32_BOOL erase) @cname("InvalidateRect");
extern fn Win32_HWND set_capture(Win32_HWND hwnd) @cname("SetCapture");
extern fn Win32_BOOL release_capture() @cname("ReleaseCapture");
extern fn Win32_HWND set_focus(Win32_HWND hwnd) @cname("SetFocus");
extern fn short get_key_state(int key) @cname("GetKeyState");
extern fn Win32_BOOL screen_to_client(Win32_HWND hwnd, Win32_POINT* point) @cname("ScreenToClient");

struct TrackMouseEvent
{
	uint size;
	uint flags;
	Win32_HWND hwnd;
	uint hover_time;
}
extern fn Win32_BOOL track_mouse(TrackMouseEvent* event) @cname("TrackMouseEvent");

struct WinCanvas
{
	Win32_HWND hwnd;
	Win32_HDC paint_dc;
	fault failure;
}

fn Size measure_wintext(void* context, String text) @private => @pool()
{
	WinCanvas* canvas = context;
	Win32_HDC dc = get_dc(canvas.hwnd);
	if (!dc) { canvas.failure = ui::PLATFORM_ERROR; return {}; }
	defer (void)release_dc(canvas.hwnd, dc);
	Win32_HGDIOBJ old_font = select_object(dc, get_stock_object(17)); // DEFAULT_GUI_FONT
	defer (void)select_object(dc, old_font);
	Char16[] chars = (text.len ? text : "M").to_temp_utf16()!!;
	Win32_SIZE size;
	if (!get_text_extent(dc, chars.ptr, (int)chars.len, &size)) canvas.failure = ui::PLATFORM_ERROR;
	return { text.len ? size.cx : 0, size.cy };
}

fn void? clip_winrect(void* context, Rect rect) @private
{
	WinCanvas* canvas = context;
	// This resets only the application clip. BeginPaint's update region remains.
	if (!select_clip(canvas.paint_dc, null) ||
		!intersect_clip(canvas.paint_dc, rect.x, rect.y, rect.x + rect.width, rect.y + rect.height)) return ui::PLATFORM_ERROR~;
}

fn void? fill_winrect(void* context, Rect rect, Ink ink) @private
{
	if (rect.empty()) return;
	WinCanvas* canvas = context;
	Win32_RECT native = { rect.x, rect.y, rect.x + rect.width, rect.y + rect.height };
	Win32_HBRUSH brush = (Win32_HBRUSH)get_stock_object(ink == PAPER ? 0 : 4);
	if (!fill_rect(canvas.paint_dc, &native, brush)) return ui::PLATFORM_ERROR~;
}

fn void? draw_wintext(void* context, String text, int x, int y, Ink ink) @private => @pool()
{
	WinCanvas* canvas = context;
	Char16[] chars = text.to_temp_utf16()!!;
	if (!chars.len) return;
	win32::setTextColor(canvas.paint_dc, ink == PAPER ? 0xffffff : 0);
	if (!win32::textOut(canvas.paint_dc, x, y, chars.ptr, (int)chars.len)) return ui::PLATFORM_ERROR~;
}

fn void flush_window(WinWindow* window) @private
{
	window.view.update();
	Rect damage = window.view.take_damage();
	if (!damage.empty())
	{
		Win32_RECT rect = { damage.x, damage.y, damage.x + damage.width, damage.y + damage.height };
		if (!invalidate_rect(window.canvas.hwnd, &rect, 0)) window.canvas.failure = ui::PLATFORM_ERROR;
	}
	if (window.canvas.failure && !window.closing && !window.closed)
	{
		// DestroyWindow sends focus/capture messages synchronously.
		window.closing = true;
		(void)destroy_window(window.canvas.hwnd);
	}
}

// Kept separate from painting so native message metadata can be tested without
// an HWND. A repeated message can arrive without a prior down after refocus.
fn void win_key(View* view, bool down, uint key, sz flags, bool shift) @private
{
	if (key >= 256) return;
	if (!down) { view.key_up((char)key); return; }
	view.key_down((char)key, key == 9 ? TAB : (key == 13 || key == 32 ? ACTIVATE : NONE),
		(flags & (1 << 30)) != 0, shift);
}

// Wheel deltas are signed multiples/fractions of 120. Keep the fractional
// pixel remainder per open window so fine wheels neither stall nor drift.
fn void win_wheel(View* view, int* remainder, int x, int y, short delta) @private
{
	int scaled = *remainder - (int)delta * 40;
	int pixels = scaled / 120;
	*remainder = scaled % 120;
	if (pixels) view.scroll_wheel(x, y, pixels);
}

// Separate pointer metadata from HWND operations so cancellation and signed
// captured coordinates are exercised by both native dispatch and unit tests.
fn void win_pointer(View* view, uint message, int x = 0, int y = 0) @private
{
	switch (message)
	{
		case 0x201: view.pointer_down(x, y);
		case 0x202: view.pointer_up(x, y);
		case 0x200: view.pointer_move(x, y);
		case 0x2a3: // Leave is not captured motion; do not move an active thumb.
			if (!view.scroll_pressed) view.pointer_move(-1, -1);
		case 0x215: // Capture loss and cancel mode preserve the press identity.
		case 0x1f:
			view.cancel_press();
		default:
	}
}

fn bool dispatch_widget_message(WinWindow* window, uint message, Win32_WPARAM wparam, Win32_LPARAM lparam) @private
{
	View* view = window.view;
	Win32_HWND hwnd = window.canvas.hwnd;
	int x = (short)(lparam & 0xffff);
	int y = (short)((lparam >> 16) & 0xffff);
	switch (message)
	{
		case 0x0f: // WM_PAINT
			Win32_PAINTSTRUCT paint;
			Win32_HDC dc = win32::beginPaint(hwnd, &paint);
			if (dc)
			{
				Win32_HGDIOBJ old_font = select_object(dc, get_stock_object(17));
				win32::setBkMode(dc, 1); // TRANSPARENT
				window.canvas.paint_dc = dc;
				Renderer renderer = { &window.canvas, &fill_winrect, &draw_wintext, &clip_winrect };
				Win32_RECT rect = paint.rcPaint;
				if (catch failure = view.paint(&renderer, { rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top }))
				{
					window.canvas.failure = failure;
				}
				(void)select_object(dc, old_font);
			}
			else { window.canvas.failure = ui::PLATFORM_ERROR; }
			win32::endPaint(hwnd, &paint);
		case 0x14: // WM_ERASEBKGND: paint handles the background.
			return true;
		case 5: // WM_SIZE
			view.resize((int)(lparam & 0xffff), (int)((lparam >> 16) & 0xffff));
		case 0x201: // WM_LBUTTONDOWN
			(void)set_focus(hwnd);
			(void)set_capture(hwnd);
			win_pointer(view, message, x, y);
		case 0x202:
			win_pointer(view, message, x, y);
			(void)release_capture();
		case 0x200: // WM_MOUSEMOVE
			win_pointer(view, message, x, y);
			TrackMouseEvent track = { TrackMouseEvent::size, 2, hwnd, 0 }; // TME_LEAVE
			(void)track_mouse(&track);
		case 0x20a: // WM_MOUSEWHEEL carries signed SCREEN coordinates.
			Win32_POINT point = { x, y };
			if (!screen_to_client(hwnd, &point)) { window.canvas.failure = ui::PLATFORM_ERROR; }
			else { win_wheel(view, &window.wheel_remainder, point.x, point.y, (short)((wparam >> 16) & 0xffff)); }
		case 0x2a3: // WM_MOUSELEAVE
		case 0x215: // WM_CAPTURECHANGED
			win_pointer(view, message);
		case 0x1f: // WM_CANCELMODE (menus, modal dialogs, native cancellation).
			win_pointer(view, message);
			(void)release_capture();
		case 0x18: // WM_SHOWWINDOW: hiding must end a native interaction.
			if (wparam) return false;
			view.blur();
			(void)release_capture();
		case 8: // WM_KILLFOCUS
			view.blur();
			(void)release_capture();
		case 7: // WM_SETFOCUS: suppress keys already held when focus arrives.
			view.held_keys[13] = get_key_state(13) < 0;
			view.held_keys[32] = get_key_state(32) < 0;
		case 0x100: // WM_KEYDOWN; bit 30 survives even a lost initial press.
			win_key(view, true, (uint)wparam, lparam, get_key_state(16) < 0);
		case 0x101: // WM_KEYUP
			win_key(view, false, (uint)wparam, lparam, false);
		case 0x105: // WM_SYSKEYUP: Alt pressed during a hold can change release type.
			win_key(view, false, (uint)wparam, lparam, false);
			return false; // Preserve DefWindowProc's system-key behavior.
		default:
			return false;
	}
	flush_window(window);
	return true;
}
