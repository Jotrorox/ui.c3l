module ui::backend @feat(MACOS);
import std::os::macos::objc;

extern void* mac_pasteboard_string @cname("NSPasteboardTypeString");
alias MacPasteboardSet = fn bool(void*, ObjcSelector, void*, void*);
alias MacStringLength = fn usz(void*, ObjcSelector, usz);

fn void* mac_clipboard_board(void* context) @private
{
	MacWindow* window = context;
	return window.pasteboard ? window.pasteboard :
		objc::msg_send(objc::getClass("NSPasteboard"), MacObject, "generalPasteboard");
}

fn bool mac_clipboard_write(void* context, String text) @private
{
	void* value = mac_string(text);
	if (!value) return false;
	defer objc::release(value);
	void* board = mac_clipboard_board(context);
	if (!board) return false;
	(void)objc::msg_send(board, MacInteger, "clearContents");
	return objc::msg_send(board, MacPasteboardSet, "setString:forType:", value, mac_pasteboard_string);
}

fn void mac_clipboard_read(void* context, ClipboardRequest request) @private
{
	MacWindow* window = context;
	void* board = mac_clipboard_board(context);
	void* value = objc::msg_send(board, MacObjectArg, "stringForType:", mac_pasteboard_string);
	if (!value) return;
	usz length = objc::msg_send(value, MacStringLength, "lengthOfBytesUsingEncoding:", (usz)4); // NSUTF8StringEncoding
	if (!length || length > (usz)ui::TEXT_FIELD_LIMIT) return;
	ZString bytes = objc::msg_send(value, MacUTF8, "UTF8String");
	if (bytes) window.view.paste_text((String)((char*)bytes)[:length], request);
}

fn void mac_clipboard_action(void* object, ObjcSelector selector, void* sender) @private
{
	if (!mac_text_field(object)) return;
	MacWindow* window = mac_context(object);
	mac_discard_marked(object);
	void* input = objc::msg_send(object, MacObject, "inputContext");
	if (input) objc::msg_send(input, MacVoid, "discardMarkedText");
	ControlKey action = selector == objc::sel_getUid("copy:") ? COPY :
		selector == objc::sel_getUid("cut:") ? CUT : PASTE;
	window.view.clipboard_command(action);
	flush_mac_window(window);
}
