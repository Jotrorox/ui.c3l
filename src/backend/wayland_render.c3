module ui::backend @feat(LINUX);
import libc, std::math;

struct CTextExtents { double x_bearing; double y_bearing; double width; double height; double x_advance; double y_advance; }
struct CFontExtents { double ascent; double descent; double height; double max_x_advance; double max_y_advance; }
alias CSurface = fn void*(void*, int, int, int, int);
alias CFont = fn void(void*, ZString, int, int);
alias CDouble = fn void(void*, double);
alias CColor = fn void(void*, double, double, double);
alias CRect = fn void(void*, double, double, double, double);
alias CPoint = fn void(void*, double, double);
alias CText = fn void(void*, ZString);
alias CExtents = fn void(void*, ZString, CTextExtents*);
alias CFontMetrics = fn void(void*, CFontExtents*);

struct WCanvas
{
	void* library;
	CSurface image;
	XState create;
	WVoid destroy;
	WVoid surface_destroy;
	WVoid surface_flush;
	WInt status;
	WInt surface_status;
	CFont select_font;
	CDouble font_size;
	CColor color;
	CRect rectangle;
	WVoid fill;
	WVoid reset_clip;
	WVoid clip;
	CPoint move;
	CText show_text;
	CExtents text_extents;
	CFontMetrics font_extents;
	void* metric_surface;
	void* metrics;
	void* drawing;
	uint metric_pixel;
	int ascent;
	int height;
}

fn void? WCanvas.load(&self)
{
	self.library = libc::dlopen("libcairo.so.2", libc::RTLD_NOW | libc::RTLD_LOCAL);
	if (!self.library) return ui::DISPLAY_UNAVAILABLE~;
	@load_symbol(self.image, self.library, "cairo_image_surface_create_for_data")!;
	@load_symbol(self.create, self.library, "cairo_create")!;
	@load_symbol(self.destroy, self.library, "cairo_destroy")!;
	@load_symbol(self.surface_destroy, self.library, "cairo_surface_destroy")!;
	@load_symbol(self.surface_flush, self.library, "cairo_surface_flush")!;
	@load_symbol(self.status, self.library, "cairo_status")!;
	@load_symbol(self.surface_status, self.library, "cairo_surface_status")!;
	@load_symbol(self.select_font, self.library, "cairo_select_font_face")!;
	@load_symbol(self.font_size, self.library, "cairo_set_font_size")!;
	@load_symbol(self.color, self.library, "cairo_set_source_rgb")!;
	@load_symbol(self.rectangle, self.library, "cairo_rectangle")!;
	@load_symbol(self.fill, self.library, "cairo_fill")!;
	@load_symbol(self.reset_clip, self.library, "cairo_reset_clip")!;
	@load_symbol(self.clip, self.library, "cairo_clip")!;
	@load_symbol(self.move, self.library, "cairo_move_to")!;
	@load_symbol(self.show_text, self.library, "cairo_show_text")!;
	@load_symbol(self.text_extents, self.library, "cairo_text_extents")!;
	@load_symbol(self.font_extents, self.library, "cairo_font_extents")!;
	self.metric_surface = self.image(&self.metric_pixel, 1, 1, 1, 4); // CAIRO_FORMAT_RGB24
	self.metrics = self.create(self.metric_surface);
	self.font(self.metrics);
	CFontExtents extents;
	self.font_extents(self.metrics, &extents);
	if (self.status(self.metrics)) return ui::PLATFORM_ERROR~;
	self.ascent = (int)math::ceil(extents.ascent);
	self.height = (int)math::ceil(extents.ascent + extents.descent);
}

fn void WCanvas.font(&self, void* context)
{
	self.select_font(context, "sans", 0, 0);
	self.font_size(context, 14);
}

fn void WCanvas.dispose(&self)
{
	if (self.metrics) self.destroy(self.metrics);
	if (self.metric_surface) self.surface_destroy(self.metric_surface);
	if (self.library) (void)libc::dlclose(self.library);
}

fn Size measure_wayland_text(void* context, String text) @private => @pool()
{
	WCanvas* canvas = context;
	CTextExtents extents;
	canvas.text_extents(canvas.metrics, text.zstr_tcopy(), &extents);
	return { (int)math::ceil(math::max(extents.x_advance, extents.x_bearing + extents.width)), canvas.height };
}

fn void? clip_wayland_rect(void* context, ui::Rect rect) @private
{
	WCanvas* canvas = context;
	canvas.reset_clip(canvas.drawing);
	canvas.rectangle(canvas.drawing, rect.x, rect.y, rect.width, rect.height);
	canvas.clip(canvas.drawing);
}

fn void? fill_wayland_rect(void* context, ui::Rect rect, Ink ink) @private
{
	if (rect.empty()) return;
	WCanvas* canvas = context;
	double color = ink == PAPER ? 1 : 0;
	canvas.color(canvas.drawing, color, color, color);
	canvas.rectangle(canvas.drawing, rect.x, rect.y, rect.width, rect.height);
	canvas.fill(canvas.drawing);
}

fn void? draw_wayland_text(void* context, String text, int x, int y, Ink ink) @private => @pool()
{
	WCanvas* canvas = context;
	double color = ink == PAPER ? 1 : 0;
	canvas.color(canvas.drawing, color, color, color);
	canvas.move(canvas.drawing, x, (double)y + canvas.ascent);
	canvas.show_text(canvas.drawing, text.zstr_tcopy());
}

struct WBuffer
{
	void* proxy;
	void* pixels;
	usz size;
	int width;
	int height;
	bool busy;
}

fn void WBuffer.dispose(&self, WApi* api)
{
	if (self.proxy) api.destroy(self.proxy);
	if (self.pixels) (void)munmap(self.pixels, self.size);
	*self = {};
}

fn void? WBuffer.init(&self, WaylandWindow* window, int width, int height, uint format = 1)
{
	// wl_shm uses signed 32-bit sizes/strides; cap allocations before multiplying.
	long bytes = (long)width * height * 4;
	if (width <= 0 || height <= 0 || bytes > 256 * 1024 * 1024) return ui::PLATFORM_ERROR~;
	int fd = memfd_create("ui-wayland", 1); // MFD_CLOEXEC; no persistent files.
	if (fd < 0) return ui::PLATFORM_ERROR~;
	defer (void)close(fd);
	if (ftruncate(fd, (iptr)bytes)) return ui::PLATFORM_ERROR~;
	void* pixels = mmap(null, (usz)bytes, 3, 1, fd, 0); // PROT_READ|WRITE, MAP_SHARED
	if (pixels == (void*)(uptr)-1) return ui::PLATFORM_ERROR~;
	self.pixels = pixels;
	self.size = (usz)bytes;
	self.width = width;
	self.height = height;
	WArg[3] pool_args = { { .o = null }, { .i = fd }, { .i = (int)bytes } };
	void* pool = window.construct(window.shm, 0, window.api.pool, 1, pool_args[..])!;
	defer window.destroy_request(pool, 1);
	WArg[6] buffer_args = { { .o = null }, { .i = 0 }, { .i = width }, { .i = height },
		{ .i = width * 4 }, { .u = format } };
	self.proxy = window.construct(pool, 0, window.api.buffer, 1, buffer_args[..])!;
	window.listen(self.proxy)!;
}

fn void? WaylandWindow.paint(&self)
{
	if (!self.configured || self.frame || self.closed) return;
	if (self.view)
	{
		self.view.update();
		if (!self.redraw && self.view.damage.empty()) return;
	}
	else if (!self.redraw) { return; }
	WBuffer* buffer;
	foreach (&candidate : self.buffers)
	{
		if (!candidate.busy) { buffer = candidate; break; }
	}
	// Retain damage until a compositor releases a buffer. Never write busy shm.
	if (!buffer) return;
	if (buffer.width != self.width || buffer.height != self.height)
	{
		if (buffer.proxy) self.destroy_request(buffer.proxy, 0);
		buffer.proxy = null;
		buffer.dispose(&self.api);
		buffer.init(self, self.width, self.height)!;
	}
	if (self.view)
	{
		void* surface = self.canvas.image(buffer.pixels, 1, self.width, self.height, self.width * 4);
		defer self.canvas.surface_destroy(surface);
		self.canvas.drawing = self.canvas.create(surface);
		defer { self.canvas.destroy(self.canvas.drawing); self.canvas.drawing = null; }
		self.canvas.font(self.canvas.drawing);
		Renderer renderer = { &self.canvas, &fill_wayland_rect, &draw_wayland_text, &clip_wayland_rect };
		// Each released buffer can contain an older frame. Repaint all pixels.
		self.view.paint(&renderer, { 0, 0, self.width, self.height })!;
		if (self.canvas.status(self.canvas.drawing) || self.canvas.surface_status(surface)) return ui::PLATFORM_ERROR~;
		self.canvas.surface_flush(surface);
		(void)self.view.take_damage();
	}
	else
	{
		uint[] pixels = ((uint*)buffer.pixels)[:buffer.size / 4];
		foreach (&pixel : pixels) *pixel = 0xffffffff;
	}
	WArg[1] frame_args;
	self.frame = self.construct(self.surface, 3, self.api.callback, 1, frame_args[..])!;
	self.listen(self.frame)!;
	WArg[3] attach = { { .o = buffer.proxy }, { .i = 0 }, { .i = 0 } };
	self.request(self.surface, 1, attach[..]);
	WArg[4] damage = { { .i = 0 }, { .i = 0 }, { .i = self.width }, { .i = self.height } };
	self.request(self.surface, 2, damage[..]);
	self.request(self.surface, 6, {});
	buffer.busy = true;
	self.redraw = false;
}
