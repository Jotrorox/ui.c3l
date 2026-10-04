module ui::backend @feat(MACOS);
import std::os::macos::objc, std::os::macos::cf;
import std::math;

// Only the message signatures used by this adapter. No Objective-C bridge or
// third-party runtime is needed; AppKit owns the native view and event routing.
alias MacObject = fn void*(void*, ObjcSelector);
alias MacVoid = fn void(void*, ObjcSelector);
alias MacObjectArg = fn void*(void*, ObjcSelector, void*);
alias MacVoidArg = fn void(void*, ObjcSelector, void*);
alias MacBool = fn bool(void*, ObjcSelector);
alias MacBoolArg = fn void(void*, ObjcSelector, bool);
alias MacBoolObject = fn bool(void*, ObjcSelector, void*);
alias MacBoolInteger = fn bool(void*, ObjcSelector, long);
alias MacInteger = fn long(void*, ObjcSelector);
alias MacIntegerArg = fn void(void*, ObjcSelector, long);
alias MacFrame = fn void*(void*, ObjcSelector, CGRect);
alias MacRect = fn CGRect(void*, ObjcSelector);
alias MacRectArg = fn void(void*, ObjcSelector, CGRect);
alias MacPoint = fn CGPoint(void*, ObjcSelector);
alias MacConvertPoint = fn CGPoint(void*, ObjcSelector, CGPoint, void*);
alias MacWindowInit = fn void*(void*, ObjcSelector, CGRect, ulong, ulong, bool);
alias MacNextEvent = fn void*(void*, ObjcSelector, ulong, void*, void*, bool);
alias MacArray = fn void*(void*, ObjcSelector, void**, usz);
alias MacUTF8 = fn ZString(void*, ObjcSelector);
alias ConvertRect = fn CGRect(void*, ObjcSelector, CGRect, void*);
alias ScreenRect = fn CGRect(void*, ObjcSelector, CGRect);
alias ConvertStret = fn void(CGRect*, void*, ObjcSelector, CGRect, void*);
alias ScreenStret = fn void(CGRect*, void*, ObjcSelector, CGRect);
const usz MAC_NOT_FOUND = (usz)sz::max; // Foundation NSNotFound is NSIntegerMax.
struct MacRange { usz location; usz length; }

extern fn bool add_mac_ivar(ObjcClass cls, ZString name, usz size, char alignment, ZString types) @cname("class_addIvar");
extern fn void dispose_mac_class(ObjcClass cls) @cname("objc_disposeClassPair");
extern fn int mac_main_thread() @cname("pthread_main_np");
extern fn bool mac_key_held(int source, ushort key) @cname("CGEventSourceKeyState");
extern fn void* mac_protocol(ZString name) @cname("objc_getProtocol");
extern fn bool mac_add_protocol(ObjcClass cls, void* protocol) @cname("class_addProtocol");
extern void* mac_default_mode @cname("NSDefaultRunLoopMode");
extern fn void mac_rect_stret(CGRect* result, void* object, ObjcSelector selector) @feat(X86_64) @cname("objc_msgSend_stret");

ObjcClass mac_view_class;
bool mac_launched;

struct MacWindow
{
	void* application;
	void* window;
	void* native_view;
	View* view;
	MacCanvas canvas;
	double wheel_remainder;
	bool closed;
	String marked_text; // Input-method preedit stays separate from committed text.
	MacRange marked_selection;
	usz marked_location;
	ulong text_epoch;
	ushort text_key;
	bool text_repeat;
}

fn CGRect mac_bounds(void* object) @private
{
	// CGRect uses the hidden-result message entry point on Intel, but the
	// ordinary entry point on Apple Silicon. CGSize/CGPoint need neither.
	$if env::X86_64:
		CGRect result;
		mac_rect_stret(&result, object, objc::sel_getUid("bounds"));
		return result;
	$else
		return objc::msg_send(object, MacRect, "bounds");
	$endif
}

fn CGRect mac_rect(ui::Rect rect) @private => { { rect.x, rect.y }, { rect.width, rect.height } };

fn MacWindow* mac_context(void* object) @private
{
	MacWindow* window;
	objc::getInstanceVariable(object, "ui_context", &window);
	return window;
}

fn bool mac_yes(void* object, ObjcSelector selector) @private => true;

fn void flush_mac_window(MacWindow* window) @private
{
	if (!window.view || window.closed) return;
	window.view.update();
	ui::Rect damage = window.view.take_damage();
	if (!damage.empty()) objc::msg_send(window.native_view, MacRectArg, "setNeedsDisplayInRect:", mac_rect(damage));
}

fn void mac_resize(void* object, ObjcSelector selector, void* notification) @private
{
	MacWindow* window = mac_context(object);
	if (!window || !window.view || window.closed) return;
	CGRect bounds = mac_bounds(object);
	window.view.resize((int)bounds.size.width, (int)bounds.size.height);
	flush_mac_window(window);
}

fn void mac_blur(void* object, ObjcSelector selector, void* notification) @private
{
	MacWindow* window = mac_context(object);
	if (!window || !window.view) return;
	window.view.blur();
	mac_text_field(object);
	window.wheel_remainder = 0;
	flush_mac_window(window);
}

fn void mac_focus(void* object, ObjcSelector selector, void* notification) @private
{
	MacWindow* window = mac_context(object);
	if (!window || !window.view) return;
	// Keys held in another window must not activate controls on refocus.
	foreach (ushort key : { (ushort)36, (ushort)48, (ushort)49, (ushort)76 })
	{
		window.view.held_keys[key] = mac_key_held(0, key);
	}
}

fn void mac_close(void* object, ObjcSelector selector, void* notification) @private
{
	MacWindow* window = mac_context(object);
	if (!window) return;
	mac_blur(object, selector, notification);
	window.closed = true;
}

// AppKit routes drag/up to the view that received down, including outside
// coordinates. Exiting its tracking area must not move a captured thumb.
fn void mac_pointer(View* view, long type, int x, int y, bool extend = false) @private
{
	switch (type)
	{
		case 1: view.pointer_down(x, y, extend);
		case 2: view.pointer_up(x, y);
		case 5:
		case 6:
		case 8: view.pointer_move(x, y);
		case 9:
			if (!view.has_pointer_capture()) view.pointer_move(-1, -1);
		default:
	}
}

fn void mac_key(View* view, bool down, ushort key, bool repeat, ulong modifiers) @private
{
	if (key >= 256) return;
	if (!down) { view.key_up((char)key); return; }
	bool shortcut = (modifiers & ((1 << 18) | (1 << 19) | (1 << 20))) != 0;
	ControlKey action = NONE;
	if (!shortcut) switch (key)
	{
		case 48: action = TAB;
		case 36:
		case 76:
		case 49: action = ACTIVATE;
		case 116: action = PAGE_UP;
		case 121: action = PAGE_DOWN;
		case 115: action = SCROLL_HOME;
		case 119: action = SCROLL_END;
		case 123: action = LEFT;
		case 124: action = RIGHT;
		case 51: action = BACKSPACE;
		case 117: action = DELETE;
		default:
	}
	if (view.focused && view.focused.kind == TEXT_FIELD &&
		(modifiers & (1 << 20)) && !(modifiers & ((1 << 18) | (1 << 19))))
	{
		if (key == 0) action = SELECT_ALL; // Command-A.
		if (key == 123) action = SCROLL_HOME;
		if (key == 124) action = SCROLL_END;
	}
	view.key_down((char)key, action, repeat, (modifiers & (1 << 17)) != 0);
}

fn void mac_wheel(View* view, double* remainder, int x, int y, double delta, bool precise) @private
{
	// Precise trackpad deltas are points; ordinary wheels are lines. Retain
	// subpixel motion per window, including reversals, without integer overflow.
	double scaled = *remainder - math::clamp(delta * (precise ? 1.0 : 40.0), -65535.0, 65535.0);
	int pixels = (int)scaled;
	*remainder = scaled - pixels;
	if (pixels) view.scroll_wheel(x, y, pixels);
}

alias MacKeyCode = fn ushort(void*, ObjcSelector);
alias MacDelta = fn double(void*, ObjcSelector);

fn bool mac_shortcut(void* object, ObjcSelector selector, void* event) @private
{
	MacWindow* window = mac_context(object);
	if (!window || window.closed || objc::msg_send(event, MacInteger, "type") != 10 ||
		objc::msg_send(event, MacKeyCode, "keyCode") != 13 ||
		!(objc::msg_send(event, MacInteger, "modifierFlags") & (1 << 20))) return false;
	objc::msg_send(window.window, MacVoidArg, "performClose:", null);
	return true;
}

fn Widget* mac_text_field(void* object) @private
{
	MacWindow* window = mac_context(object);
	if (!window || !window.view || window.closed) return null;
	window.view.update();
	if (window.text_epoch != window.view.focus_epoch)
	{
		window.text_epoch = window.view.focus_epoch;
		window.marked_text.free(mem);
		window.marked_text = {};
		void* context = objc::msg_send(object, MacObject, "inputContext");
		if (context) objc::msg_send(context, MacVoid, "discardMarkedText");
	}
	Widget* field = window.view.focused;
	return field && field.kind == TEXT_FIELD && field.interactive() ? field : null;
}

fn String mac_input_string(void* text) @private
{
	if (objc::msg_send(text, MacBoolObject, "isKindOfClass:", (void*)objc::getClass("NSAttributedString")))
	{
		text = objc::msg_send(text, MacObject, "string");
	}
	ZString utf8 = objc::msg_send(text, MacUTF8, "UTF8String");
	return utf8 ? utf8.str_view() : "";
}

fn MacRange mac_selected_range(void* object, ObjcSelector selector) @private => @pool()
{
	Widget* field = mac_text_field(object);
	if (!field) return { MAC_NOT_FOUND, 0 };
	MacWindow* window = mac_context(object);
	if (window.marked_text.len)
	{
		return { window.marked_location + window.marked_selection.location, window.marked_selection.length };
	}
	TextSelection selected = field.selection();
	sz start = math::min(selected.anchor, selected.caret);
	sz end = math::max(selected.anchor, selected.caret);
	return { (usz)field.content[:start].to_temp_utf16()!!.len,
		(usz)field.content[start:end - start].to_temp_utf16()!!.len };
}

fn bool mac_has_marked(void* object, ObjcSelector selector) @private =>
	mac_text_field(object) && mac_context(object).marked_text.len != 0;

fn MacRange mac_marked_range(void* object, ObjcSelector selector) @private => @pool()
{
	if (!mac_has_marked(object, selector)) return { MAC_NOT_FOUND, 0 };
	MacWindow* window = mac_context(object);
	return { window.marked_location, (usz)window.marked_text.to_temp_utf16()!!.len };
}

fn void mac_discard_marked(void* object) @private
{
	MacWindow* window = mac_context(object);
	if (!window) return;
	window.marked_text.free(mem);
	window.marked_text = {};
}

fn void mac_unmark(void* object, ObjcSelector selector) @private
{
	if (!mac_text_field(object)) return;
	MacWindow* window = mac_context(object);
	if (!window.marked_text.len) return;
	String text = window.marked_text.copy(mem);
	defer text.free(mem);
	mac_discard_marked(object);
	window.view.text_input(text);
	flush_mac_window(window);
}

// Input method replacement ranges use UTF-16, while the retained editor uses
// UTF-8 byte boundaries. A range splitting a surrogate pair is rejected.
fn bool mac_replace_range(Widget* field, MacRange range) @private => @pool()
{
	if (range.location == MAC_NOT_FOUND) return true;
	Char16[] units = field.content.to_temp_utf16()!!;
	if (range.location > (usz)units.len || range.length > (usz)units.len - range.location) return false;
	String? prefix = string::from_utf16(tmem, units[:range.location]);
	String? selected = string::from_utf16(tmem, units[range.location:range.length]);
	if (catch prefix) return false;
	if (catch selected) return false;
	return field.select(prefix.len, prefix.len + selected.len);
}

fn bool mac_replace_input_range(void* object, Widget* field, MacRange range) @private => @pool()
{
	MacWindow* window = mac_context(object);
	if (window.marked_text.len && range.location != MAC_NOT_FOUND)
	{
		usz length = (usz)window.marked_text.to_temp_utf16()!!.len;
		if (range.location >= window.marked_location && range.location - window.marked_location <= length &&
			range.length <= length - (range.location - window.marked_location)) return true;
	}
	return mac_replace_range(field, range);
}

fn void mac_insert_text(void* object, ObjcSelector selector, void* text, MacRange range) @private
{
	Widget* field = mac_text_field(object);
	if (!field) return;
	TextSelection original = field.selection();
	int offset = field.text_scroll_x;
	if (!mac_replace_input_range(object, field, range)) return;
	mac_discard_marked(object);
	MacWindow* window = mac_context(object);
	if (!window.view.text_input(mac_input_string(text)))
	{
		// Rejected input has no callback and cannot remove the field. Restore
		// selection and horizontal position as well as the unchanged buffer.
		field.select(original.anchor, original.caret);
		field.text_scroll_x = offset;
	}
	flush_mac_window(window);
}

fn void mac_insert_legacy(void* object, ObjcSelector selector, void* text) @private =>
	mac_insert_text(object, selector, text, { MAC_NOT_FOUND, 0 });

fn void mac_mark_text(void* object, ObjcSelector selector, void* text, MacRange selected, MacRange replacement) @private => @pool()
{
	Widget* field = mac_text_field(object);
	if (!field || !mac_replace_input_range(object, field, replacement)) return;
	String value = mac_input_string(text);
	if (value.len > ui::TEXT_FIELD_LIMIT) return;
	usz length = (usz)value.to_temp_utf16()!!.len;
	if (selected.location > length || selected.length > length - selected.location) return;
	MacWindow* window = mac_context(object);
	if (!window.marked_text.len) window.marked_location = mac_selected_range(object, selector).location;
	String copy = value.copy(mem);
	window.marked_text.free(mem);
	window.marked_text = copy;
	window.marked_selection = selected;
}

fn void* mac_mark_attributes(void* object, ObjcSelector selector) @private =>
	objc::msg_send(objc::getClass("NSArray"), MacObject, "array");
fn void* mac_input_substring(void* object, ObjcSelector selector, MacRange range, MacRange* actual) @private
{
	if (actual) *actual = { MAC_NOT_FOUND, 0 };
	return null;
}
fn usz mac_input_index(void* object, ObjcSelector selector, CGPoint point) @private => MAC_NOT_FOUND;
fn CGRect mac_input_rect(void* object, ObjcSelector selector, MacRange range, MacRange* actual) @private
{
	if (actual) *actual = range;
	Widget* field = mac_text_field(object);
	if (!field) return {};
	ui::Rect content = field.field_rect();
	CGRect caret = mac_rect({ content.x + field.text_prefix_width(field.selection().caret) - field.text_scroll_x,
		content.y, 1, content.height });
	// NSTextInputClient candidate coordinates are in screen space, unflipped.
	$if env::X86_64:
		// Returning large structs through objc_msgSend needs its stret entry point.
		CGRect converted;
		((ConvertStret)&mac_rect_stret)(&converted, object, objc::sel_getUid("convertRect:toView:"), caret, null);
		((ScreenStret)&mac_rect_stret)(&caret, mac_context(object).window, objc::sel_getUid("convertRectToScreen:"), converted);
	$else
		caret = objc::msg_send(object, ConvertRect, "convertRect:toView:", caret, null);
		caret = objc::msg_send(mac_context(object).window, ScreenRect, "convertRectToScreen:", caret);
	$endif
	return caret;
}
fn void mac_text_command(void* object, ObjcSelector selector, ObjcSelector command) @private
{
	if (!mac_text_field(object)) return;
	MacWindow* window = mac_context(object);
	ControlKey action = NONE;
	bool extend;
	if (command == objc::sel_getUid("moveLeft:") || command == objc::sel_getUid("moveBackward:")) action = LEFT;
	if (command == objc::sel_getUid("moveRight:") || command == objc::sel_getUid("moveForward:")) action = RIGHT;
	if (command == objc::sel_getUid("moveLeftAndModifySelection:") || command == objc::sel_getUid("moveBackwardAndModifySelection:"))
	{
		action = LEFT; extend = true;
	}
	if (command == objc::sel_getUid("moveRightAndModifySelection:") || command == objc::sel_getUid("moveForwardAndModifySelection:"))
	{
		action = RIGHT; extend = true;
	}
	if (command == objc::sel_getUid("moveToBeginningOfLine:") || command == objc::sel_getUid("scrollToBeginningOfDocument:")) action = SCROLL_HOME;
	if (command == objc::sel_getUid("moveToEndOfLine:") || command == objc::sel_getUid("scrollToEndOfDocument:")) action = SCROLL_END;
	if (command == objc::sel_getUid("moveToBeginningOfLineAndModifySelection:") || command == objc::sel_getUid("moveToBeginningOfDocumentAndModifySelection:"))
	{
		action = SCROLL_HOME; extend = true;
	}
	if (command == objc::sel_getUid("moveToEndOfLineAndModifySelection:") || command == objc::sel_getUid("moveToEndOfDocumentAndModifySelection:"))
	{
		action = SCROLL_END; extend = true;
	}
	if (command == objc::sel_getUid("deleteBackward:")) action = BACKSPACE;
	if (command == objc::sel_getUid("deleteForward:")) action = DELETE;
	if (command == objc::sel_getUid("selectAll:")) action = SELECT_ALL;
	if (command == objc::sel_getUid("pageUp:") || command == objc::sel_getUid("scrollPageUp:")) action = PAGE_UP;
	if (command == objc::sel_getUid("pageDown:") || command == objc::sel_getUid("scrollPageDown:")) action = PAGE_DOWN;
	if (action != NONE) window.view.key_down((char)window.text_key, action, window.text_repeat, extend);
	flush_mac_window(window);
}

fn void mac_input(void* object, ObjcSelector selector, void* event) @private
{
	MacWindow* window = mac_context(object);
	if (!window || window.closed || mac_shortcut(object, selector, event) || !window.view) return;
	long type = objc::msg_send(event, MacInteger, "type");
	if (type == 10 || type == 11)
	{
		ushort key = objc::msg_send(event, MacKeyCode, "keyCode");
		ulong modifiers = (ulong)objc::msg_send(event, MacInteger, "modifierFlags");
		bool was_field = mac_text_field(object) != null;
		bool repeat = type == 10 && objc::msg_send(event, MacBool, "isARepeat");
		if (type == 10 && was_field)
		{
			if (key == 48 || (modifiers & ((1 << 18) | (1 << 20))))
			{
				mac_discard_marked(object);
				void* context = objc::msg_send(object, MacObject, "inputContext");
				if (context) objc::msg_send(context, MacVoid, "discardMarkedText");
				mac_key(window.view, true, key, repeat, modifiers);
			}
			else
			{
				// Let the input method consume editing keys during composition. Its
				// commands reach mac_text_command once; only insertText commits text.
				window.text_key = key;
				window.text_repeat = repeat;
				if (key < 256) window.view.key_down((char)key, NONE, repeat);
				void*[1] events = { event };
				void* array = objc::msg_send(objc::getClass("NSArray"), MacArray, "arrayWithObjects:count:", &events[0], (usz)1);
				objc::msg_send(object, MacVoidArg, "interpretKeyEvents:", array);
			}
		}
		else { mac_key(window.view, type == 10, key, repeat, modifiers); }
	}
	else
	{
		CGPoint point = objc::msg_send(event, MacPoint, "locationInWindow");
		point = objc::msg_send(object, MacConvertPoint, "convertPoint:fromView:", point, null);
		int x = (int)math::floor(point.x);
		int y = (int)math::floor(point.y);
		if (type == 1)
		{
			mac_discard_marked(object);
			void* context = objc::msg_send(object, MacObject, "inputContext");
			if (context) objc::msg_send(context, MacVoid, "discardMarkedText");
		}
		if (type == 22)
		{
			mac_wheel(window.view, &window.wheel_remainder, x, y,
				objc::msg_send(event, MacDelta, "scrollingDeltaY"), objc::msg_send(event, MacBool, "hasPreciseScrollingDeltas"));
		}
		else { mac_pointer(window.view, type, x, y,
			((ulong)objc::msg_send(event, MacInteger, "modifierFlags") & (1 << 17)) != 0); }
	}
	mac_text_field(object); // Clear native preedit immediately after pointer focus changes.
	flush_mac_window(window);
}

fn ObjcClass? init_mac_class() @private
{
	if (mac_view_class) return mac_view_class;
	ObjcClass cls = objc::allocateClassPair(objc::getClass("NSView"), "UIC3View", 0);
	if (!cls) return ui::PLATFORM_ERROR~;
	defer catch dispose_mac_class(cls);
	void* text_protocol = mac_protocol("NSTextInputClient");
	if (!text_protocol || !mac_add_protocol(cls, text_protocol)) return ui::PLATFORM_ERROR~;
	if (!add_mac_ivar(cls, "ui_context", void*::size, 3, "^v")) return ui::PLATFORM_ERROR~;
	ZString bool_encoding = env::AARCH64 ? "B@:" : "c@:";
	if (!objc::class_addMethod(cls, objc::sel_getUid("isFlipped"), &mac_yes, bool_encoding) ||
		!objc::class_addMethod(cls, objc::sel_getUid("acceptsFirstResponder"), &mac_yes, bool_encoding) ||
		!objc::class_addMethod(cls, objc::sel_getUid("isOpaque"), &mac_yes, bool_encoding) ||
		!objc::class_addMethod(cls, objc::sel_getUid("drawRect:"), &draw_mac_view, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}")) return ui::PLATFORM_ERROR~;
	if (!objc::class_addMethod(cls, objc::sel_getUid("performKeyEquivalent:"), &mac_shortcut,
		env::AARCH64 ? "B@:@" : "c@:@")) return ui::PLATFORM_ERROR~;
	if (!objc::class_addMethod(cls, objc::sel_getUid("insertText:"), &mac_insert_legacy, "v@:@") ||
		!objc::class_addMethod(cls, objc::sel_getUid("insertText:replacementRange:"), &mac_insert_text, "v@:@{_NSRange=QQ}") ||
		!objc::class_addMethod(cls, objc::sel_getUid("setMarkedText:selectedRange:replacementRange:"), &mac_mark_text, "v@:@{_NSRange=QQ}{_NSRange=QQ}") ||
		!objc::class_addMethod(cls, objc::sel_getUid("unmarkText"), &mac_unmark, "v@:") ||
		!objc::class_addMethod(cls, objc::sel_getUid("hasMarkedText"), &mac_has_marked, bool_encoding) ||
		!objc::class_addMethod(cls, objc::sel_getUid("markedRange"), &mac_marked_range, "{_NSRange=QQ}@:") ||
		!objc::class_addMethod(cls, objc::sel_getUid("selectedRange"), &mac_selected_range, "{_NSRange=QQ}@:") ||
		!objc::class_addMethod(cls, objc::sel_getUid("validAttributesForMarkedText"), &mac_mark_attributes, "@@:") ||
		!objc::class_addMethod(cls, objc::sel_getUid("attributedSubstringForProposedRange:actualRange:"), &mac_input_substring, "@@:{_NSRange=QQ}^{_NSRange=QQ}") ||
		!objc::class_addMethod(cls, objc::sel_getUid("characterIndexForPoint:"), &mac_input_index, "Q@:{CGPoint=dd}") ||
		!objc::class_addMethod(cls, objc::sel_getUid("firstRectForCharacterRange:actualRange:"), &mac_input_rect, "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}") ||
		!objc::class_addMethod(cls, objc::sel_getUid("doCommandBySelector:"), &mac_text_command, "v@::")) return ui::PLATFORM_ERROR~;
	foreach (ZString name : { "mouseDown:", "mouseUp:", "mouseMoved:", "mouseDragged:", "mouseEntered:", "mouseExited:",
		"keyDown:", "keyUp:", "scrollWheel:" })
	{
		if (!objc::class_addMethod(cls, objc::sel_getUid(name), &mac_input, "v@:@")) return ui::PLATFORM_ERROR~;
	}
	if (!objc::class_addMethod(cls, objc::sel_getUid("windowWillClose:"), &mac_close, "v@:@") ||
		!objc::class_addMethod(cls, objc::sel_getUid("windowDidResize:"), &mac_resize, "v@:@") ||
		!objc::class_addMethod(cls, objc::sel_getUid("windowDidResignKey:"), &mac_blur, "v@:@") ||
		!objc::class_addMethod(cls, objc::sel_getUid("windowDidMiniaturize:"), &mac_blur, "v@:@") ||
		!objc::class_addMethod(cls, objc::sel_getUid("windowDidBecomeKey:"), &mac_focus, "v@:@")) return ui::PLATFORM_ERROR~;
	objc::registerClassPair(cls);
	mac_view_class = cls;
	return cls;
}

alias MacTrackingInit = fn void*(void*, ObjcSelector, CGRect, ulong, void*, void*);

fn void? open(WindowOptions options, View* view = null)
{
	if (!mac_main_thread()) return ui::PLATFORM_ERROR~;
	objc::@autoreleasepool()
	{
		MacWindow window = { .view = view };
		defer window.marked_text.free(mem);
		defer window.canvas.dispose();
		window.application = objc::msg_send(objc::getClass("NSApplication"), MacObject, "sharedApplication");
		if (!window.application) return ui::DISPLAY_UNAVAILABLE~;
		long policy = objc::msg_send(window.application, MacInteger, "activationPolicy");
		if (policy == 2) (void)objc::msg_send(window.application, MacBoolInteger, "setActivationPolicy:", 0L);
		defer
		{
			if (policy == 2 && !mac_launched)
			{
				(void)objc::msg_send(window.application, MacBoolInteger, "setActivationPolicy:", policy);
			}
		}
		if (!mac_launched && !objc::msg_send(window.application, MacBool, "isRunning"))
		{
			objc::msg_send(window.application, MacVoid, "finishLaunching");
			// An application launched by this backend stays eligible for focus.
			// Restoring prohibited policy between windows queues a deactivation
			// that can steal key status from the next window after it opens.
			mac_launched = true;
		}
		ObjcClass cls = init_mac_class()!;
		CGRect frame = { {}, { options.width, options.height } };
		window.window = objc::msg_send(objc::alloc(objc::getClass("NSWindow")), MacWindowInit,
			"initWithContentRect:styleMask:backing:defer:", frame, 15UL, 2UL, false);
		if (!window.window) return ui::PLATFORM_ERROR~;
		defer objc::release(window.window);
		objc::msg_send(window.window, MacBoolArg, "setReleasedWhenClosed:", false);
		defer
		{
			objc::msg_send(window.window, MacVoidArg, "setDelegate:", null);
			if (!window.closed) objc::msg_send(window.window, MacVoid, "close");
		}
		void* title = mac_string(options.title);
		if (!title) return ui::PLATFORM_ERROR~;
		defer objc::release(title);
		objc::msg_send(window.window, MacVoidArg, "setTitle:", title);
		objc::msg_send(window.window, MacIntegerArg, "setTabbingMode:", 2L); // Independent windows.
		window.native_view = objc::msg_send(objc::alloc(cls), MacFrame, "initWithFrame:", frame);
		if (!window.native_view) return ui::PLATFORM_ERROR~;
		defer objc::release(window.native_view);
		objc::setInstanceVariable(window.native_view, "ui_context", &window);
		defer objc::setInstanceVariable(window.native_view, "ui_context", null);
		objc::msg_send(window.window, MacVoidArg, "setContentView:", window.native_view);
		objc::msg_send(window.window, MacVoidArg, "setDelegate:", window.native_view);
		if (view)
		{
			window.canvas.init()!;
			void* tracking = objc::msg_send(objc::alloc(objc::getClass("NSTrackingArea")), MacTrackingInit,
				"initWithRect:options:owner:userInfo:", frame, 0x623UL, window.native_view, null);
			if (!tracking) return ui::PLATFORM_ERROR~;
			objc::msg_send(window.native_view, MacVoidArg, "addTrackingArea:", tracking);
			objc::release(tracking);
			view.set_measurer(&measure_mactext, &window.canvas);
			view.invalidate({ 0, 0, view.width, view.height });
			flush_mac_window(&window);
		}
		(void)objc::msg_send(window.window, MacBoolObject, "makeFirstResponder:", window.native_view);
		objc::msg_send(window.window, MacVoid, "center");
		objc::msg_send(window.window, MacVoidArg, "makeKeyAndOrderFront:", null);
		objc::msg_send(window.application, MacBoolArg, "activateIgnoringOtherApps:", true);
		while (!window.closed && !window.canvas.failure)
		{
			// Bound autoreleased NSEvents and native drawing objects to one turn.
			objc::@autoreleasepool()
			{
				void* future = objc::msg_send(objc::getClass("NSDate"), MacObject, "distantFuture");
				void* event = objc::msg_send(window.application, MacNextEvent,
					"nextEventMatchingMask:untilDate:inMode:dequeue:", ulong::max, future, mac_default_mode, true);
				if (event) objc::msg_send(window.application, MacVoidArg, "sendEvent:", event);
				flush_mac_window(&window);
				objc::msg_send(window.application, MacVoid, "updateWindows");
			};
		}
		if (window.canvas.failure) return window.canvas.failure~;
	};
}
