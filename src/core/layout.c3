module ui;
import std::math;

// All sizes are pixels. Zero width/height means content size, and zero
// maximum means unbounded. Limits clamp the preferred size before placement.
// Spacing and alignment apply to containers only. There is no wrapping or
// flexing. START preserves the default geometry; STRETCH is cross-axis only.
enum Alignment { START, CENTER, END, STRETCH }

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
	Alignment main_align;
	Alignment cross_align;
}

const int LAYOUT_LIMIT = 65535;
const int CHECKBOX_SIZE = 16;
const int CHECKBOX_PADDING = 4;
const int CHECKBOX_GAP = 8;

fn bool Layout.valid(self)
{
	foreach (value : (int[8]){ self.width, self.height, self.min_width, self.min_height,
		self.max_width, self.max_height, self.padding, self.gap })
	{
		if (value < 0 || value > LAYOUT_LIMIT) return false;
	}
	return valid_alignment(self.main_align, self.cross_align) &&
		(!self.max_width || self.min_width <= self.max_width) &&
		(!self.max_height || self.min_height <= self.max_height);
}

fn bool valid_alignment(Alignment main_align, Alignment cross_align) @private =>
	(int)main_align >= 0 && (int)main_align <= (int)Alignment.END &&
	(int)cross_align >= 0 && (int)cross_align <= (int)Alignment.STRETCH;

fn int layout_add(int a, int b) @private => math::min(LAYOUT_LIMIT, a + b);

fn Rect inset(Rect rect, int padding) @private => {
	layout_add(rect.x, padding), layout_add(rect.y, padding),
	math::max(0, rect.width - padding * 2), math::max(0, rect.height - padding * 2),
};

fn int constrain(int natural, int explicit_size, int minimum, int maximum) @private =>
	math::clamp(explicit_size ? explicit_size : natural, minimum, maximum ? maximum : LAYOUT_LIMIT);

fn bool rect_equal(Rect a, Rect b) @private =>
	a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;

// Invalid options leave the previous layout intact. Leaves only accept sizes.
fn bool Widget.set_layout(&self, Layout layout)
{
	assert(!active_binding, "Bindings cannot mutate widgets");
	if (!layout.valid() || (!self.is_container() && (layout.padding || layout.gap ||
		layout.main_align != START || layout.cross_align != START))) return false;
	Layout old = self.layout;
	bool size_changed = old.width != layout.width || old.height != layout.height ||
		old.min_width != layout.min_width || old.min_height != layout.min_height ||
		old.max_width != layout.max_width || old.max_height != layout.max_height ||
		old.padding != layout.padding || old.gap != layout.gap;
	bool alignment_changed = old.main_align != layout.main_align || old.cross_align != layout.cross_align;
	if (!size_changed && !alignment_changed) return true;
	self.layout = layout;
	if (size_changed)
	{
		self.request_size();
		// Explicit/auto sizes and maximums affect stretch even when the cached
		// preferred size remains identical. The parent must place this child.
		if (self.parent) { self.parent.request_layout(); }
		else { self.owner.layout_dirty = true; }
	}
	if (alignment_changed || old.padding != layout.padding || old.gap != layout.gap) self.request_layout();
	return true;
}

// The implicit root always occupies the viewport. Spacing and alignment are
// independent; neither setter changes intrinsic measurements.
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

fn bool View.set_root_alignment(&self, Alignment main_align = START, Alignment cross_align = START)
{
	assert(!active_binding, "Bindings cannot mutate widgets");
	if (!valid_alignment(main_align, cross_align)) return false;
	if (main_align == self.root_main_align && cross_align == self.root_cross_align) return true;
	self.root_main_align = main_align;
	self.root_cross_align = cross_align;
	self.layout_dirty = true;
	return true;
}

fn void Widget.request_size(&self)
{
	for (Widget* widget = self; widget; widget = widget.parent)
	{
		// Hidden subtrees can retain dirty caches after ancestors are measured.
		// Always propagate through them when another property changes.
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
		widget.subtree_layout_dirty = true;
	}
	self.owner.subtree_layout_dirty = true;
}

// Intrinsic measurement is independent of available space: labels are single
// line. A clean subtree is pruned, and layout-only edits reuse text metrics.
fn void Widget.measure(&self)
{
	if (self.hidden || !self.measure_dirty) return;
	self.measure_dirty = false;
	Size size;
	if (self.is_container())
	{
		bool preceding;
		for (Widget* child = self.first; child; child = child.next)
		{
			if (child.hidden) continue;
			child.measure();
			if (self.kind == ROW)
			{
				size.width = layout_add(size.width, child.desired.width);
				if (preceding) size.width = layout_add(size.width, self.layout.gap);
				size.height = math::max(size.height, child.desired.height);
			}
			else
			{
				size.height = layout_add(size.height, child.desired.height);
				if (preceding) size.height = layout_add(size.height, self.layout.gap);
				size.width = math::max(size.width, child.desired.width);
			}
			preceding = true;
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
		else if (self.kind == CHECKBOX)
		{
			size.width = layout_add(CHECKBOX_SIZE + CHECKBOX_PADDING * 2,
				self.content.len ? layout_add(CHECKBOX_GAP, size.width) : 0);
			size.height = layout_add(math::max(CHECKBOX_SIZE, size.height), CHECKBOX_PADDING * 2);
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

// Alignment only distributes nonnegative remaining space. Odd center pixels
// stay at the end, and an overflowing group remains anchored at the start.
fn int alignment_offset(Alignment alignment, int available, int used) @private
{
	int remaining = math::max(0, available - used);
	if (alignment == CENTER) return remaining / 2;
	return alignment == END ? remaining : 0;
}

fn int cross_size(Widget* child, bool row, int available, Alignment alignment) @private
{
	Layout layout = child.layout;
	int preferred = row ? child.desired.height : child.desired.width;
	int explicit_size = row ? layout.height : layout.width;
	if (alignment == STRETCH && !explicit_size)
	{
		int maximum = row ? layout.max_height : layout.max_width;
		return math::min(available, maximum ? maximum : LAYOUT_LIMIT);
	}
	return math::min(preferred, available);
}

// Shared by explicit containers and the implicit root Column. Main-axis sizes
// keep their preferred size on overflow. Available cross space wins over min.
fn void place_children(Widget* first, bool row, Rect content, Rect clip, int gap,
	Alignment main_align, Alignment cross_align, bool changed) @private
{
	int used;
	if (changed && main_align != START)
	{
		bool preceding;
		for (Widget* child = first; child; child = child.next)
		{
			if (child.hidden) continue;
			if (preceding) used = layout_add(used, gap);
			used = layout_add(used, row ? child.desired.width : child.desired.height);
			preceding = true;
		}
	}
	int cursor = layout_add(row ? content.x : content.y,
		alignment_offset(main_align, row ? content.width : content.height, used));
	for (Widget* child = first; child; child = child.next)
	{
		if (child.hidden) { collapse_geometry(child); continue; }
		Rect rect = child.bounds;
		if (changed)
		{
			int available = row ? content.height : content.width;
			int cross = cross_size(child, row, available, cross_align);
			int offset = alignment_offset(cross_align, available, cross);
			rect = row ? (Rect) { cursor, layout_add(content.y, offset), child.desired.width, cross } :
				(Rect) { layout_add(content.x, offset), cursor, cross, child.desired.height };
		}
		child.place(rect, clip);
		cursor = layout_add(cursor, layout_add(row ? child.desired.width : child.desired.height, gap));
	}
}

// Every ancestor clips descendants to its padded content rectangle.
fn void Widget.place(&self, Rect bounds, Rect ancestor_clip)
{
	if (self.hidden) { collapse_geometry(self); return; }
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
		place_children(self.first, self.kind == ROW, content, clip, self.layout.gap,
			self.layout.main_align, self.layout.cross_align, changed || self.layout_dirty);
	}
	self.layout_dirty = false;
	self.subtree_layout_dirty = false;
}
