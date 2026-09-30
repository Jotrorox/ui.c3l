module ui;
import std::math;

struct Size { int width; int height; }
struct Rect { int x; int y; int width; int height; }

fn bool Rect.empty(self) => self.width <= 0 || self.height <= 0;
fn bool Rect.contains(self, int x, int y) =>
	x >= self.x && y >= self.y && x < self.x + self.width && y < self.y + self.height;

fn Rect Rect.intersect(self, Rect other)
{
	int x = math::max(self.x, other.x);
	int y = math::max(self.y, other.y);
	return { x, y, math::max(0, math::min(self.x + self.width, other.x + other.width) - x),
		math::max(0, math::min(self.y + self.height, other.y + other.height) - y) };
}

alias MeasureText = fn Size(void* context, String text);

// The root owns a persistent list of leaf widgets, arranged vertically. More
// container kinds can later reuse Widget, the dependency graph and Renderer.
// Zero initialization is sufficient. Do not copy a View after adding widgets.
struct View
{
	Widget* first;
	Widget* last;
	Widget* hovered;
	Widget* pressed;
	Widget* focused;
	Binding* pending_head;
	Binding* pending_tail;
	Widget* measure_head;
	Rect damage;
	int width;
	int height;
	bool layout_dirty;
	bool opened;
	MeasureText measure_text;
	void* measure_context;
}

fn void View.invalidate(&self, Rect rect)
{
	if (rect.empty()) return;
	if (self.damage.empty()) { self.damage = rect; return; }
	int x = math::min(self.damage.x, rect.x);
	int y = math::min(self.damage.y, rect.y);
	self.damage = { x, y, math::max(self.damage.x + self.damage.width, rect.x + rect.width) - x,
		math::max(self.damage.y + self.damage.height, rect.y + rect.height) - y };
}

fn void View.resize(&self, int width, int height)
{
	if (self.width == width && self.height == height) return;
	self.width = math::max(0, width);
	self.height = math::max(0, height);
	self.layout_dirty = true;
	self.invalidate({ 0, 0, self.width, self.height });
}

fn void View.set_measurer(&self, MeasureText measure, void* context = null)
{
	self.measure_text = measure;
	self.measure_context = context;
	for (Widget* widget = self.first; widget; widget = widget.next)
	{
		widget.request_measure();
		self.invalidate(widget.bounds);
	}
}

// Deterministic fallback for headless use; each native backend supplies metrics.
fn Size measure_default(void* context, String text) @private => @pool()
{
	return { (int)text.to_temp_utf32()!!.len * 8, 16 };
}

// Native event loops flush once after each input event, coalescing repeated sets.
// Headless callers can flush explicitly; no clean binding is reevaluated.
fn void View.update(&self)
{
	assert(!active_binding, "Bindings cannot recursively update a view");
	while (self.pending_head)
	{
		Binding* binding = self.pending_head;
		self.pending_head = binding.pending_next;
		if (!self.pending_head) self.pending_tail = null;
		binding.pending = false;
		binding.pending_next = null;
		binding.run();
	}
	while (self.measure_head)
	{
		Widget* widget = self.measure_head;
		self.measure_head = widget.measure_next;
		widget.measure_next = null;
		widget.measure_dirty = false;
		Size size = self.measure_text ? self.measure_text(self.measure_context, widget.content) :
			measure_default(null, widget.content);
		widget.text_size = size;
		if (widget.kind == BUTTON) { size.width += 24; size.height += 16; }
		if (size.width != widget.desired.width || size.height != widget.desired.height)
		{
			widget.desired = size;
			self.layout_dirty = true;
		}
	}
	if (!self.layout_dirty) return;
	self.layout_dirty = false;
	int y = 16;
	for (Widget* widget = self.first; widget; widget = widget.next)
	{
		Rect bounds = { 16, y, math::min(widget.desired.width, math::max(0, self.width - 32)), widget.desired.height };
		if (bounds.x != widget.bounds.x || bounds.y != widget.bounds.y ||
			bounds.width != widget.bounds.width || bounds.height != widget.bounds.height)
		{
			self.invalidate(widget.bounds);
			widget.bounds = bounds;
			self.invalidate(bounds);
		}
		y = math::min(65535, y + widget.desired.height + 8);
	}
}

fn Rect View.take_damage(&self)
{
	Rect result = self.damage.intersect({ 0, 0, self.width, self.height });
	self.damage = {};
	return result;
}

fn void? View.open(&self, String title = "ui", int width = 800, int height = 600)
{
	WindowOptions options = { title, width, height };
	validate_options(options)!;
	assert(!self.opened, "A View can only have one native window");
	self.opened = true;
	defer self.opened = false;
	defer self.blur();
	self.resize(width, height);
	defer self.set_measurer(null); // Native metric context is scoped to open().
	return backend::open(options, self);
}

fn void View.free(&self)
{
	assert(!self.opened, "Free the view after its window has closed");
	assert(!active_binding, "Bindings cannot destroy views");
	while (self.first) self.first.remove();
	*self = {};
}
