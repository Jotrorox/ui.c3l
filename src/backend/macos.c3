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

extern fn bool add_mac_ivar(ObjcClass cls, ZString name, usz size, char alignment, ZString types) @cname("class_addIvar");
extern fn void dispose_mac_class(ObjcClass cls) @cname("objc_disposeClassPair");
extern fn int mac_main_thread() @cname("pthread_main_np");
extern fn bool mac_key_held(int source, ushort key) @cname("CGEventSourceKeyState");
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
fn void mac_pointer(View* view, long type, int x, int y) @private
{
	switch (type)
	{
		case 1: view.pointer_down(x, y);
		case 2: view.pointer_up(x, y);
		case 5:
		case 6:
		case 8: view.pointer_move(x, y);
		case 9:
			if (!view.scroll_pressed) view.pointer_move(-1, -1);
		default:
	}
}

fn void mac_key(View* view, bool down, ushort key, bool repeat, ulong modifiers) @private
{
	if (key >= 256) return;
	if (!down) { view.key_up((char)key); return; }
	bool shortcut = (modifiers & ((1 << 18) | (1 << 19) | (1 << 20))) != 0;
	view.key_down((char)key, shortcut ? NONE : (key == 48 ? TAB :
		(key == 36 || key == 76 || key == 49 ? ACTIVATE : NONE)), repeat, (modifiers & (1 << 17)) != 0);
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

fn void mac_input(void* object, ObjcSelector selector, void* event) @private
{
	MacWindow* window = mac_context(object);
	if (!window || window.closed || mac_shortcut(object, selector, event) || !window.view) return;
	long type = objc::msg_send(event, MacInteger, "type");
	if (type == 10 || type == 11)
	{
		ushort key = objc::msg_send(event, MacKeyCode, "keyCode");
		ulong modifiers = (ulong)objc::msg_send(event, MacInteger, "modifierFlags");
		mac_key(window.view, type == 10, key, type == 10 && objc::msg_send(event, MacBool, "isARepeat"), modifiers);
	}
	else
	{
		CGPoint point = objc::msg_send(event, MacPoint, "locationInWindow");
		point = objc::msg_send(object, MacConvertPoint, "convertPoint:fromView:", point, null);
		int x = (int)math::floor(point.x);
		int y = (int)math::floor(point.y);
		if (type == 22)
		{
			mac_wheel(window.view, &window.wheel_remainder, x, y,
				objc::msg_send(event, MacDelta, "scrollingDeltaY"), objc::msg_send(event, MacBool, "hasPreciseScrollingDeltas"));
		}
		else { mac_pointer(window.view, type, x, y); }
	}
	flush_mac_window(window);
}

fn ObjcClass? init_mac_class() @private
{
	if (mac_view_class) return mac_view_class;
	ObjcClass cls = objc::allocateClassPair(objc::getClass("NSView"), "UIC3View", 0);
	if (!cls) return ui::PLATFORM_ERROR~;
	defer catch dispose_mac_class(cls);
	if (!add_mac_ivar(cls, "ui_context", void*::size, 3, "^v")) return ui::PLATFORM_ERROR~;
	ZString bool_encoding = env::AARCH64 ? "B@:" : "c@:";
	if (!objc::class_addMethod(cls, objc::sel_getUid("isFlipped"), &mac_yes, bool_encoding) ||
		!objc::class_addMethod(cls, objc::sel_getUid("acceptsFirstResponder"), &mac_yes, bool_encoding) ||
		!objc::class_addMethod(cls, objc::sel_getUid("isOpaque"), &mac_yes, bool_encoding) ||
		!objc::class_addMethod(cls, objc::sel_getUid("drawRect:"), &draw_mac_view, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}")) return ui::PLATFORM_ERROR~;
	if (!objc::class_addMethod(cls, objc::sel_getUid("performKeyEquivalent:"), &mac_shortcut,
		env::AARCH64 ? "B@:@" : "c@:@")) return ui::PLATFORM_ERROR~;
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
		defer window.canvas.dispose();
		window.application = objc::msg_send(objc::getClass("NSApplication"), MacObject, "sharedApplication");
		if (!window.application) return ui::DISPLAY_UNAVAILABLE~;
		long policy = objc::msg_send(window.application, MacInteger, "activationPolicy");
		if (policy == 2) (void)objc::msg_send(window.application, MacBoolInteger, "setActivationPolicy:", 0L);
		defer { if (policy == 2) (void)objc::msg_send(window.application, MacBoolInteger, "setActivationPolicy:", policy); }
		if (!mac_launched && !objc::msg_send(window.application, MacBool, "isRunning"))
		{
			objc::msg_send(window.application, MacVoid, "finishLaunching");
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
