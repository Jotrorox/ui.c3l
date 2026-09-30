module ui;
import std::math;

// All sizes are pixels. Zero width/height means content size, and zero
// maximum means unbounded. Limits clamp the preferred size before placement.
// Padding and gap apply to containers only. There is no wrapping or flexing.
struct Layout
{
	int width;
	int height;
	int min_width;
	int min_height;
	int max_width;
	int max_height;
	int padding;
	int gap;
}

const int LAYOUT_LIMIT = 65535;

fn bool Layout.valid(self)
{
	foreach (value : (int[8]){ self.width, self.height, self.min_width, self.min_height,
		self.max_width, self.max_height, self.padding, self.gap })
	{
		if (value < 0 || value > LAYOUT_LIMIT) return false;
	}
	return (!self.max_width || self.min_width <= self.max_width) &&
		(!self.max_height || self.min_height <= self.max_height);
}

fn int layout_add(int a, int b) @private => math::min(LAYOUT_LIMIT, a + b);

fn Rect inset(Rect rect, int padding) @private => {
	layout_add(rect.x, padding), layout_add(rect.y, padding),
	math::max(0, rect.width - padding * 2), math::max(0, rect.height - padding * 2),
};

fn int constrain(int natural, int explicit_size, int minimum, int maximum) @private =>
	math::clamp(explicit_size ? explicit_size : natural, minimum, maximum ? maximum : LAYOUT_LIMIT);

fn bool rect_equal(Rect a, Rect b) @private =>
	a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;

// Invalid options leave the previous layout intact. A leaf cannot have spacing.
fn bool Widget.set_layout(&self, Layout layout)
{
	assert(!active_binding, "Bindings cannot mutate widgets");
	if (!layout.valid() || (!self.is_container() && (layout.padding || layout.gap))) return false;
	Layout old = self.layout;
	if (old.width == layout.width && old.height == layout.height &&
		old.min_width == layout.min_width && old.min_height == layout.min_height &&
		old.max_width == layout.max_width && old.max_height == layout.max_height &&
		old.padding == layout.padding && old.gap == layout.gap) return true;
	self.layout = layout;
	self.request_size();
	if (old.padding != layout.padding || old.gap != layout.gap) self.request_layout();
	return true;
}

// The implicit root always occupies the viewport; only its spacing is settable.
fn bool View.set_root_spacing(&self, int padding = 16, int gap = 8)
{
	assert(!active_binding, "Bindings cannot mutate widgets");
	if (padding < 0 || padding > LAYOUT_LIMIT || gap < 0 || gap > LAYOUT_LIMIT) return false;
	if (padding == (self.custom_root_spacing ? self.root_padding : 16) &&
		gap == (self.custom_root_spacing ? self.root_gap : 8)) return true;
	self.custom_root_spacing = true;
	self.root_padding = padding;
	self.root_gap = gap;
	self.layout_dirty = true;
	return true;
}

fn void Widget.request_size(&self)
{
	for (Widget* widget = self; widget; widget = widget.parent)
	{
		if (widget.measure_dirty) break;
		widget.measure_dirty = true;
	}
	self.owner.measure_dirty = true;
}

fn void Widget.request_measure(&self)
{
	self.text_dirty = true;
	self.request_size();
}

fn void Widget.request_layout(&self)
{
	self.layout_dirty = true;
	for (Widget* widget = self.parent; widget; widget = widget.parent)
	{
		if (widget.subtree_layout_dirty) break;
		widget.subtree_layout_dirty = true;
	}
	self.owner.subtree_layout_dirty = true;
}

// Intrinsic measurement is independent of available space: labels are single
// line. A clean subtree is pruned, and layout-only edits reuse text metrics.
fn void Widget.measure(&self)
{
	if (!self.measure_dirty) return;
	self.measure_dirty = false;
	Size size;
	if (self.is_container())
	{
		for (Widget* child = self.first; child; child = child.next)
		{
			child.measure();
			if (self.kind == ROW)
			{
				size.width = layout_add(size.width, child.desired.width);
				if (child.previous) size.width = layout_add(size.width, self.layout.gap);
				size.height = math::max(size.height, child.desired.height);
			}
			else
			{
				size.height = layout_add(size.height, child.desired.height);
				if (child.previous) size.height = layout_add(size.height, self.layout.gap);
				size.width = math::max(size.width, child.desired.width);
			}
		}
		size.width = layout_add(size.width, self.layout.padding * 2);
		size.height = layout_add(size.height, self.layout.padding * 2);
	}
	else
	{
		if (self.text_dirty)
		{
			View* view = self.owner;
			self.text_size = view.measure_text ? view.measure_text(view.measure_context, self.content) :
				measure_default(null, self.content);
			self.text_size.width = math::clamp(self.text_size.width, 0, LAYOUT_LIMIT);
			self.text_size.height = math::clamp(self.text_size.height, 0, LAYOUT_LIMIT);
			self.text_dirty = false;
		}
		size = self.text_size;
		if (self.kind == BUTTON)
		{
			size.width = layout_add(size.width, 24);
			size.height = layout_add(size.height, 16);
		}
	}
	Layout layout = self.layout;
	size.width = constrain(size.width, layout.width, layout.min_width, layout.max_width);
	size.height = constrain(size.height, layout.height, layout.min_height, layout.max_height);
	if (size.width == self.desired.width && size.height == self.desired.height) return;
	self.desired = size;
	if (self.parent) { self.parent.request_layout(); }
	else { self.owner.layout_dirty = true; }
}

// Main-axis sizes stay at their preferred size, even on overflow. Cross-axis
// sizes are capped by available space (which wins over minimum constraints).
// Every ancestor clips descendants to its padded content rectangle.
fn void Widget.place(&self, Rect bounds, Rect ancestor_clip)
{
	Rect visible = bounds.intersect(ancestor_clip);
	bool changed = !rect_equal(bounds, self.bounds) || !rect_equal(visible, self.visible);
	if (!changed && !self.layout_dirty && !self.subtree_layout_dirty) return;
	if (changed && !self.is_container())
	{
		self.owner.invalidate(self.visible);
		self.owner.invalidate(visible);
	}
	self.bounds = bounds;
	self.visible = visible;
	if (self.is_container())
	{
		Rect content = inset(bounds, self.layout.padding);
		Rect clip = content.intersect(visible);
		int x = content.x;
		int y = content.y;
		for (Widget* child = self.first; child; child = child.next)
		{
			Rect rect = child.bounds;
			if (changed || self.layout_dirty)
			{
				rect = { x, y, self.kind == ROW ? child.desired.width : math::min(child.desired.width, content.width),
					self.kind == COLUMN ? child.desired.height : math::min(child.desired.height, content.height) };
			}
			child.place(rect, clip);
			if (self.kind == ROW) { x = layout_add(x, layout_add(child.desired.width, self.layout.gap)); }
			else { y = layout_add(y, layout_add(child.desired.height, self.layout.gap)); }
		}
	}
	self.layout_dirty = false;
	self.subtree_layout_dirty = false;
}
