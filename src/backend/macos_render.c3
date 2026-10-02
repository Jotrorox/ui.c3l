module ui::backend @feat(MACOS);
import std::os::macos::objc, std::os::macos::cf;
import std::math;

extern fn void fill_mac_rect(CGRect rect) @cname("NSRectFill");
extern fn void clip_mac_rect(CGRect rect) @cname("NSRectClip");
extern void* mac_font_attribute @cname("NSFontAttributeName");
extern void* mac_color_attribute @cname("NSForegroundColorAttributeName");

alias MacStringInit = fn void*(void*, ObjcSelector, void*, usz, ulong);
alias MacFont = fn void*(void*, ObjcSelector, double);
alias MacDictionary = fn void*(void*, ObjcSelector, void**, void**, usz);
alias MacTextSize = fn CGSize(void*, ObjcSelector, void*);
alias MacTextDraw = fn void(void*, ObjcSelector, CGPoint, void*);

struct MacCanvas
{
	void*[2] colors;
	void*[2] attributes;
	fault failure;
}

fn void* mac_string(String text) @private =>
	objc::msg_send(objc::alloc(objc::getClass("NSString")), MacStringInit,
		"initWithBytes:length:encoding:", text.ptr, (usz)text.len, 4UL); // NSUTF8StringEncoding

fn void? MacCanvas.init(&self)
{
	void* font = objc::msg_send(objc::getClass("NSFont"), MacFont, "systemFontOfSize:", 13.0);
	self.colors = {
		objc::msg_send(objc::getClass("NSColor"), MacObject, "whiteColor"),
		objc::msg_send(objc::getClass("NSColor"), MacObject, "blackColor")
	};
	if (!font || !self.colors[0] || !self.colors[1]) return ui::PLATFORM_ERROR~;
	void*[2] keys = { mac_font_attribute, mac_color_attribute };
	for (usz index = 0; index < 2; index++)
	{
		void*[2] values = { font, self.colors[index] };
		self.attributes[index] = objc::msg_send(objc::alloc(objc::getClass("NSDictionary")), MacDictionary,
			"initWithObjects:forKeys:count:", &values[0], &keys[0], (usz)2);
		if (!self.attributes[index]) { self.dispose(); return ui::PLATFORM_ERROR~; }
	}
}

fn void MacCanvas.dispose(&self)
{
	foreach (attributes : self.attributes) if (attributes) objc::release(attributes);
	self.attributes = {};
}

fn Size measure_mactext(void* context, String text) @private
{
	MacCanvas* canvas = context;
	void* native = mac_string(text.len ? text : "M");
	if (!native) { canvas.failure = ui::PLATFORM_ERROR; return {}; }
	defer objc::release(native);
	CGSize size = objc::msg_send(native, MacTextSize, "sizeWithAttributes:", canvas.attributes[1]);
	return { text.len ? (int)math::ceil(size.width) : 0, (int)math::ceil(size.height) };
}

fn void? clip_macrect(void* context, ui::Rect rect) @private
{
	void* graphics = (void*)objc::getClass("NSGraphicsContext");
	// Restore the drawRect damage clip before each widget's independent clip.
	objc::msg_send(graphics, MacVoid, "restoreGraphicsState");
	objc::msg_send(graphics, MacVoid, "saveGraphicsState");
	clip_mac_rect(mac_rect(rect));
}

fn void? fill_macrect(void* context, ui::Rect rect, Ink ink) @private
{
	if (rect.empty()) return;
	MacCanvas* canvas = context;
	objc::msg_send(canvas.colors[ink], MacVoid, "setFill");
	fill_mac_rect(mac_rect(rect));
}

fn void? draw_mactext(void* context, String text, int x, int y, Ink ink) @private
{
	if (!text.len) return;
	MacCanvas* canvas = context;
	void* native = mac_string(text);
	if (!native) return ui::PLATFORM_ERROR~;
	defer objc::release(native);
	objc::msg_send(native, MacTextDraw, "drawAtPoint:withAttributes:", (CGPoint){ x, y }, canvas.attributes[ink]);
}

fn void draw_mac_view(void* object, ObjcSelector selector, CGRect dirty) @private
{
	MacWindow* window = mac_context(object);
	if (!window || window.closed) return;
	if (!window.view)
	{
		objc::msg_send(objc::msg_send(objc::getClass("NSColor"), MacObject, "whiteColor"), MacVoid, "setFill");
		fill_mac_rect(dirty);
		return;
	}
	mac_resize(object, selector, null);
	window.view.update();
	int x = (int)math::floor(dirty.origin.x);
	int y = (int)math::floor(dirty.origin.y);
	ui::Rect clip = { x, y, (int)math::ceil(dirty.origin.x + dirty.size.width) - x,
		(int)math::ceil(dirty.origin.y + dirty.size.height) - y };
	void* graphics = (void*)objc::getClass("NSGraphicsContext");
	objc::msg_send(graphics, MacVoid, "saveGraphicsState");
	defer objc::msg_send(graphics, MacVoid, "restoreGraphicsState");
	Renderer renderer = { &window.canvas, &fill_macrect, &draw_mactext, &clip_macrect };
	if (catch failure = window.view.paint(&renderer, clip)) window.canvas.failure = failure;
}
