module ui::backend @feat(MACOS);
import std::core::test;
import std::os::macos::objc, std::os::macos::cf;

extern void* mac_rgb_space @cname("NSDeviceRGBColorSpace");
extern fn void mac_translate(void* context, double x, double y) @cname("CGContextTranslateCTM");
extern fn void mac_scale(void* context, double x, double y) @cname("CGContextScaleCTM");
alias MacBitmap = fn void*(void*, ObjcSelector, void*, long, long, long, long, bool, bool, void*, long, long);
alias MacPixel = fn void*(void*, ObjcSelector, long, long);
alias MacFlippedContext = fn void*(void*, ObjcSelector, void*, bool);

fn double mac_red(void* bitmap, int x, int y) @private
{
	void* color = objc::msg_send(bitmap, MacPixel, "colorAtX:y:", (long)x * 2, (long)y * 2);
	return objc::msg_send(color, MacDelta, "redComponent");
}

fn void macos_keyboard_repeat_shift_shortcuts_and_keyup() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* first = view.checkbox("first");
	Widget* second = view.checkbox("second");
	mac_key(&view, true, 48, false, 0);
	mac_key(&view, false, 48, false, 0);
	mac_key(&view, true, 49, false, 0);
	test::eq(first.is_checked(), true);
	mac_key(&view, true, 49, true, 0);
	test::eq(first.is_checked(), true);
	mac_key(&view, true, 48, false, 0);
	mac_key(&view, true, 49, true, 0);
	test::eq(second.is_checked(), false);
	mac_key(&view, false, 49, false, 0);
	mac_key(&view, true, 49, false, 0);
	test::eq(second.is_checked(), true);
	mac_key(&view, false, 48, false, 0);
	mac_key(&view, true, 48, false, 1 << 17);
	test::eq(view.focused, first);
	mac_key(&view, true, 36, false, 1 << 20); // Command-Return isn't activation.
	test::eq(first.is_checked(), true);
	mac_key(&view, false, 36, false, 0);
	mac_key(&view, true, 76, false, 0); // Keypad Enter.
	test::eq(first.is_checked(), false);
	view.blur();
	mac_key(&view, true, 48, false, 0);
	mac_key(&view, true, 36, true, 0);
	test::eq(first.is_checked(), false);
	mac_key(&view, false, 36, false, 0);
	mac_key(&view, true, 36, false, 0);
	test::eq(first.is_checked(), true);
	mac_key(&view, true, 256, false, 0);
}

fn void macos_scroll_keys_repeat_release_and_shortcuts() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.button("tall").set_layout({ .height = 240 });
	view.focus_next();
	mac_key(&view, true, 121, false, 0); // Page Down.
	test::eq(panel.scroll_offset(), 50);
	mac_key(&view, true, 121, true, 0);
	test::eq(panel.scroll_offset(), 100);
	mac_key(&view, false, 121, false, 0);
	test::eq(view.held_keys[121], false);
	mac_key(&view, true, 116, false, 0); // Page Up.
	test::eq(panel.scroll_offset(), 50);
	mac_key(&view, true, 119, false, 0); // End.
	test::eq(panel.scroll_offset(), 190);
	mac_key(&view, true, 115, false, 1 << 20); // Command-Home remains a shortcut.
	test::eq(panel.scroll_offset(), 190);
	mac_key(&view, false, 115, false, 0);
	mac_key(&view, true, 115, false, 0); // Home.
	test::eq(panel.scroll_offset(), 0);
}

fn void macos_wheel_lines_precise_fractions_reversal_and_nested_bubbling() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* outer = view.scroll_column({ .width = 240, .height = 160 });
	Widget* inner = outer.scroll_column({ .width = 200, .height = 80 });
	inner.text("content").set_layout({ .height = 400 });
	outer.text("tail").set_layout({ .height = 400 });
	view.update();
	double remainder;
	mac_wheel(&view, &remainder, 30, 30, -1, false);
	test::eq(inner.scroll_offset(), 40);
	test::eq(outer.scroll_offset(), 0);
	mac_wheel(&view, &remainder, 30, 30, -0.25, true);
	mac_wheel(&view, &remainder, 30, 30, -0.25, true);
	mac_wheel(&view, &remainder, 30, 30, -0.5, true);
	test::eq(inner.scroll_offset(), 41);
	test::eq(remainder, 0.0);
	mac_wheel(&view, &remainder, 30, 30, 0.5, true);
	mac_wheel(&view, &remainder, 30, 30, -0.5, true);
	test::eq(inner.scroll_offset(), 41);
	test::eq(remainder, 0.0);
	double other;
	mac_wheel(&view, &other, 30, 30, -0.5, true);
	test::eq(other, 0.5);
	test::eq(remainder, 0.0);
	inner.scroll_to(inner.scroll_extent());
	mac_wheel(&view, &remainder, 30, 30, -1, false);
	test::eq(outer.scroll_offset(), 40);
	mac_wheel(&view, &remainder, -5, 30, -1, false);
	test::eq(outer.scroll_offset(), 40);
}

fn void macos_pointer_capture_leave_signed_coordinates_and_cancel() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* scroll = view.scroll_column({ .width = 200, .height = 100 });
	scroll.set_scrollbar();
	Widget* check = scroll.checkbox("check");
	scroll.text("content").set_layout({ .height = 400 });
	view.update();
	int x = scroll.scroll_thumb.x + 2;
	int y = scroll.scroll_thumb.y + 2;
	mac_pointer(&view, 1, x, y);
	mac_pointer(&view, 6, x, y + 20);
	int offset = scroll.scroll_offset();
	test::eq(offset > 0, true);
	mac_pointer(&view, 9, -1, -1);
	test::eq(scroll.scroll_offset(), offset);
	mac_pointer(&view, 6, -100, 2000);
	test::eq(scroll.scroll_offset(), scroll.scroll_extent());
	mac_pointer(&view, 2, -100, 2000);
	test::eq(view.scroll_press_active || view.scroll_dragging, false);
	scroll.scroll_to(0);
	view.update();
	mac_pointer(&view, 1, x, y);
	view.blur();
	mac_pointer(&view, 6, x, 2000);
	test::eq(scroll.scroll_offset(), 0);
	mac_pointer(&view, 2, check.visible.x + 2, check.visible.y + 2);
	test::eq(check.is_checked(), false);
}

fn void macos_checkbox_click_once_and_release_outside() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* check = view.checkbox("check");
	view.update();
	int x = check.visible.x + 2;
	int y = check.visible.y + 2;
	mac_pointer(&view, 1, x, y);
	test::eq(check.is_checked(), false);
	mac_pointer(&view, 2, x, y);
	test::eq(check.is_checked(), true);
	mac_pointer(&view, 2, x, y);
	test::eq(check.is_checked(), true);
	mac_pointer(&view, 1, x, y);
	mac_pointer(&view, 2, -1, -1);
	test::eq(check.is_checked(), true);
}

fn void macos_native_class_context_bounds_and_close_cleanup() @test
{
	objc::@autoreleasepool()
	{
		ObjcClass cls = init_mac_class()!!;
		test::eq(init_mac_class()!!, cls);
		void* native = objc::msg_send(objc::alloc(cls), MacFrame, "initWithFrame:", (CGRect){ {}, { 321, 234 } });
		defer objc::release(native);
		View view;
		defer view.free();
		view.resize(400, 300);
		view.checkbox("check");
		MacWindow window = { .view = &view, .native_view = native, .wheel_remainder = 0.5 };
		objc::setInstanceVariable(native, "ui_context", &window);
		defer objc::setInstanceVariable(native, "ui_context", null);
		test::eq(mac_context(native), &window);
		test::eq(objc::msg_send(native, MacBool, "isFlipped"), true);
		mac_resize(native, (ObjcSelector)null, null);
		test::eq(view.width, 321);
		test::eq(view.height, 234);
		mac_key(&view, true, 48, false, 0);
		mac_close(native, (ObjcSelector)null, null);
		test::eq(window.closed, true);
		test::eq(window.wheel_remainder, 0.0);
		test::eq(view.focused, null);
		test::eq(view.held_keys[48], false);
	};
}

fn void macos_native_utf8_metrics_and_canvas_lifetime() @test
{
	objc::@autoreleasepool()
	{
		MacCanvas canvas;
		canvas.init()!!;
		defer canvas.dispose();
		Size empty = measure_mactext(&canvas, "");
		Size latin = measure_mactext(&canvas, "C3");
		Size unicode = measure_mactext(&canvas, "Grüße — 世界 👋");
		test::eq(empty.width, 0);
		test::eq(empty.height > 0, true);
		test::eq(latin.width > 0, true);
		test::eq(unicode.width > latin.width, true);
		test::eq(unicode.height >= latin.height, true);
		test::eq((bool)canvas.failure, false);
		canvas.dispose();
		test::eq(canvas.attributes[0], null);
		test::eq(canvas.attributes[1], null);
	};
}

fn void macos_native_rendering_checkbox_scrollbar_and_independent_clips() @test
{
	objc::@autoreleasepool()
	{
		void* bitmap = objc::msg_send(objc::alloc(objc::getClass("NSBitmapImageRep")), MacBitmap,
			"initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:",
			null, 640L, 480L, 8L, 4L, true, false, mac_rgb_space, 2560L, 32L);
		test::eq(bitmap != null, true);
		defer objc::release(bitmap);
		void* graphics = objc::msg_send(objc::getClass("NSGraphicsContext"), MacObjectArg, "graphicsContextWithBitmapImageRep:", bitmap);
		objc::msg_send(objc::getClass("NSGraphicsContext"), MacVoid, "saveGraphicsState");
		defer objc::msg_send(objc::getClass("NSGraphicsContext"), MacVoid, "restoreGraphicsState");
		objc::msg_send(objc::getClass("NSGraphicsContext"), MacVoidArg, "setCurrentContext:", graphics);
		void* cg = objc::msg_send(graphics, MacObject, "CGContext");
		mac_translate(cg, 0, 480);
		mac_scale(cg, 2, -2);
		graphics = objc::msg_send(objc::getClass("NSGraphicsContext"), MacFlippedContext, "graphicsContextWithCGContext:flipped:", cg, true);
		objc::msg_send(objc::getClass("NSGraphicsContext"), MacVoidArg, "setCurrentContext:", graphics);
		MacCanvas canvas;
		canvas.init()!!;
		defer canvas.dispose();
		View view;
		defer view.free();
		view.resize(320, 240);
		view.set_measurer(&measure_mactext, &canvas);
		State{bool} checked = { .value = true };
		view.text("Heading");
		view.text("Count: 0");
		Widget* check = view.checkbox("Grüße — 世界").@checked(&checked);
		Widget* scroll = view.scroll_column({ .width = 200, .height = 100 });
		scroll.set_scrollbar();
		scroll.text("filler").set_layout({ .height = 400 });
		view.update();
		void* native = objc::msg_send(objc::alloc(init_mac_class()!!), MacFrame, "initWithFrame:", (CGRect){ {}, { 320, 240 } });
		defer objc::release(native);
		MacWindow window = { .view = &view, .native_view = native, .canvas = canvas };
		objc::setInstanceVariable(native, "ui_context", &window);
		defer objc::setInstanceVariable(native, "ui_context", null);
		draw_mac_view(native, (ObjcSelector)null, (CGRect){ {}, { 320, 240 } });
		test::eq((bool)window.canvas.failure, false);
		int cx = check.bounds.x + ui::CHECKBOX_PADDING + ui::CHECKBOX_SIZE / 2;
		int cy = check.bounds.y + check.bounds.height / 2;
		test::eq(mac_red(bitmap, cx, cy) < 0.1, true);
		test::eq(mac_red(bitmap, 1, 1) > 0.9, true);
		ui::Rect thumb = scroll.scroll_thumb;
		test::eq(mac_red(bitmap, thumb.x + 2, thumb.y + 2) < 0.1, true);
		ui::Rect track = scroll.scroll_track;
		test::eq(mac_red(bitmap, track.x + 2, track.y + track.height - 3) > 0.9, true);
		checked.set(false);
		draw_mac_view(native, (ObjcSelector)null, (CGRect){ {}, { 320, 240 } });
		test::eq(mac_red(bitmap, cx, cy) > 0.9, true);
	};
}
