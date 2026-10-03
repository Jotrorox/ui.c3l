module ui::backend @feat(WIN32);
import std::os::win32;

extern fn Win32_BOOL destroy_window(Win32_HWND hwnd) @cname("DestroyWindow");
extern fn Win32_BOOL unregister_class(Win32_LPCWSTR name, Win32_HINSTANCE instance) @cname("UnregisterClassW");
extern fn Win32_BOOL adjust_window_rect(Win32_RECT* rect, Win32_DWORD style, Win32_BOOL menu) @cname("AdjustWindowRect");

const uint WM_DESTROY = 2;
const uint WM_NCDESTROY = 0x82;

struct WinWindow
{
	bool closed;
	bool closing;
	View* view;
	WinCanvas canvas;
	int wheel_remainder;
	ushort text_surrogate;
	ulong text_epoch;
}

fn Win32_LRESULT window_proc(Win32_HWND hwnd, uint message, Win32_WPARAM wparam, Win32_LPARAM lparam) @private
{
	WinWindow* window = (WinWindow*)win32::getWindowLongPtrW(hwnd, win32::GWLP_USERDATA);
	if (message == WM_DESTROY)
	{
		if (window) window.closed = true;
		return 0;
	}
	if (message == WM_NCDESTROY) win32::setWindowLongPtrW(hwnd, win32::GWLP_USERDATA, 0);
	if (window && window.view && dispatch_widget_message(window, message, wparam, lparam)) return 0;
	return win32::defWindowProcW(hwnd, message, wparam, lparam);
}

fn void? open(WindowOptions options, View* view = null) => @pool()
{
	Win32_HINSTANCE instance = (Win32_HINSTANCE)win32::getModuleHandleW(null);
	WString class_name = "ui.c3l.window".to_temp_wstring()!;
	Win32_WNDCLASSEXW window_class = {
		.cbSize = Win32_WNDCLASSEXW::size,
		.lpfnWndProc = &window_proc,
		.hInstance = instance,
		.hCursor = win32::loadCursorW(null, (Win32_LPCWSTR)32512), // IDC_ARROW
		.hbrBackground = (Win32_HBRUSH)6, // COLOR_WINDOW + 1
		.lpszClassName = class_name,
	};
	if (!win32::registerClassExW(&window_class)) return ui::PLATFORM_ERROR~;
	defer (void)unregister_class(class_name, instance);

	Win32_RECT rect = { .right = options.width, .bottom = options.height };
	if (!adjust_window_rect(&rect, win32::WS_OVERLAPPEDWINDOW, 0)) return ui::PLATFORM_ERROR~;
	Win32_HWND hwnd = win32::createWindowExW(0, class_name, options.title.to_temp_wstring()!,
		win32::WS_OVERLAPPEDWINDOW, int::min, int::min,
		rect.right - rect.left, rect.bottom - rect.top, null, null, instance, null);
	if (!hwnd) return ui::PLATFORM_ERROR~;
	WinWindow window = { .view = view, .canvas.hwnd = hwnd };
	defer { if (!window.closed) (void)destroy_window(hwnd); }
	win32::setWindowLongPtrW(hwnd, win32::GWLP_USERDATA, (Win32_LONG_PTR)&window);
	if (view)
	{
		view.set_measurer(&measure_wintext, &window.canvas);
		view.update();
		view.invalidate({ 0, 0, view.width, view.height });
		flush_window(&window);
	}
	win32::showWindow(hwnd, 5); // SW_SHOW
	win32::updateWindow(hwnd);
	while (!window.closed)
	{
		Win32_MSG message;
		int result = win32::getMessageW(&message, null, 0, 0);
		if (result == -1) return ui::PLATFORM_ERROR~;
		if (result == 0)
		{
			// Preserve a quit request belonging to the calling application.
			win32::postQuitMessage((int)message.wParam);
			break;
		}
		win32::translateMessage(&message);
		win32::dispatchMessage(&message);
	}
	if (window.canvas.failure) return window.canvas.failure~;
}
