module ui::backend @feat(WIN32);
import std::os::win32;

extern fn Win32_BOOL clipboard_open(Win32_HWND owner) @cname("OpenClipboard");
extern fn Win32_BOOL clipboard_close() @cname("CloseClipboard");
extern fn Win32_BOOL clipboard_empty() @cname("EmptyClipboard");
extern fn void* clipboard_set(uint format, void* data) @cname("SetClipboardData");
extern fn void* clipboard_get(uint format) @cname("GetClipboardData");
extern fn void* clipboard_alloc(uint flags, usz bytes) @cname("GlobalAlloc");
extern fn void* clipboard_free(void* data) @cname("GlobalFree");
extern fn void* clipboard_lock(void* data) @cname("GlobalLock");
extern fn Win32_BOOL clipboard_unlock(void* data) @cname("GlobalUnlock");
extern fn usz clipboard_size(void* data) @cname("GlobalSize");

fn bool win_clipboard_write(void* context, String text) @private => @pool()
{
	WinWindow* window = context;
	Char16[] units = text.to_temp_utf16()!!;
	void* data = clipboard_alloc(2, (usz)(units.len + 1) * 2); // GMEM_MOVEABLE
	if (!data) return false;
	bool transferred;
	defer { if (!transferred) (void)clipboard_free(data); }
	Char16* buffer = clipboard_lock(data);
	if (!buffer) return false;
	buffer[:units.len] = units[..];
	buffer[units.len] = 0;
	(void)clipboard_unlock(data);
	if (!clipboard_open(window.canvas.hwnd)) return false;
	defer (void)clipboard_close();
	if (!clipboard_empty()) return false;
	transferred = clipboard_set(13, data) != null; // CF_UNICODETEXT; system owns data on success.
	return transferred;
}

fn void win_clipboard_read(void* context, ClipboardRequest request) @private => @pool()
{
	WinWindow* window = context;
	String text;
	{
		if (!clipboard_open(window.canvas.hwnd)) return;
		defer (void)clipboard_close();
		void* data = clipboard_get(13);
		if (!data) return;
		usz size = clipboard_size(data) / 2;
		Char16* units = clipboard_lock(data);
		if (!units) return;
		defer (void)clipboard_unlock(data);
		usz length;
		while (length < size && length <= (usz)ui::TEXT_FIELD_LIMIT && units[length]) length++;
		if (length == size || length > (usz)ui::TEXT_FIELD_LIMIT) return;
		String? decoded = string::from_utf16(tmem, units[:length]);
		if (catch decoded) return;
		text = decoded;
	}
	// Decode before calling the editor; malformed surrogate pairs are rejected.
	window.text_surrogate = 0;
	window.view.paste_text(text, request);
}
