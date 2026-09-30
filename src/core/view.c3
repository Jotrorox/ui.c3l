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

// The View owns every node in a tree with an implicit, viewport-sized Column.
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
	Rect damage;
	int width;
	int height;
	bool layout_dirty;
	bool subtree_layout_dirty;
	bool measure_dirty;
	bool custom_root_spacing;
	int root_padding;
	int root_gap;
	int pointer_x;
	int pointer_y;
	bool pointer_known;
	bool opened;
	bool[256] held_keys; // Native key identities, independent of widget lifetimes.
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
	assert(!active_binding, "Bindings cannot resize views");
	if (self.width == width && self.height == height) return;
	self.width = math::max(0, width);
	self.height = math::max(0, height);
	self.layout_dirty = true;
	self.invalidate({ 0, 0, self.width, self.height });
}

fn void View.set_measurer(&self, MeasureText measure, void* context = null)
{
	assert(!active_binding, "Bindings cannot change text metrics");
	self.measure_text = measure;
	self.measure_context = context;
	for (Widget* widget = self.first; widget; widget = widget.next_in_tree())
	{
		if (widget.is_container()) continue;
		widget.request_measure();
		self.invalidate(widget.visible);
	}
}

// Deterministic fallback for headless use; each native backend supplies metrics.
fn Size measure_default(void* context, String text) @private => @pool()
{
	return { (int)text.to_temp_utf32()!!.len * 8, 16 };
}

// Native event loops flush after each event; input also flushes before targeting.
// Repeated state writes coalesce. No clean binding is reevaluated.
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
	if (self.measure_dirty)
	{
		for (Widget* widget = self.first; widget; widget = widget.next) widget.measure();
		self.measure_dirty = false;
	}
	if (self.layout_dirty || self.subtree_layout_dirty)
	{
		int padding = self.custom_root_spacing ? self.root_padding : 16;
		int gap = self.custom_root_spacing ? self.root_gap : 8;
		Rect content = inset({ 0, 0, self.width, self.height }, padding);
		int y = content.y;
		for (Widget* widget = self.first; widget; widget = widget.next)
		{
			if (widget.hidden) { collapse_geometry(widget); continue; }
			Rect bounds = self.layout_dirty ? (Rect) { content.x, y,
				math::min(widget.desired.width, content.width), widget.desired.height } : widget.bounds;
			widget.place(bounds, content);
			y = layout_add(y, layout_add(widget.desired.height, gap));
		}
		self.layout_dirty = false;
		self.subtree_layout_dirty = false;
	}
	self.reconcile_input();
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
	self.blur(); // A reopened window starts a new native input lifetime.
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
