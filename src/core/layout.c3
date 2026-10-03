module ui;
import std::math;

// All sizes are pixels. Zero width/height means content size, and zero
// maximum means unbounded. Limits clamp the preferred size before placement.
// Spacing and alignment apply to containers only. Fill opts a child into its
// parent's remaining main-axis space without changing its preferred size.
// START preserves the default geometry; STRETCH is cross-axis only.
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
	bool fill; // Allocate remaining space on the parent's main axis.
}

const int LAYOUT_LIMIT = 65535;
// Leave headroom for native int rectangle endpoints and rendering insets.
// Scroll content and signed positions are independent of layout dimensions.
const int COORD_LIMIT = 0x3fffffff;
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

fn int coordinate(long value) @private => (int)math::clamp(value, -(long)COORD_LIMIT, (long)COORD_LIMIT);
fn int position_add(int a, int b, bool scrolling) @private =>
	scrolling ? coordinate((long)a + b) : layout_add(a, b);

fn Rect inset(Rect rect, int padding, bool scrolling = false) @private => {
	position_add(rect.x, padding, scrolling), position_add(rect.y, padding, scrolling),
	math::max(0, rect.width - padding * 2), math::max(0, rect.height - padding * 2),
};

fn int constrain(int natural, int explicit_size, int minimum, int maximum) @private =>
	math::clamp(explicit_size ? explicit_size : natural, minimum, maximum ? maximum : LAYOUT_LIMIT);

fn bool rect_equal(Rect a, Rect b) @private =>
	a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;

// Invalid options leave the previous layout intact. Leaves only accept sizing.
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
	bool fill_changed = old.fill != layout.fill;
	if (!size_changed && !alignment_changed && !fill_changed) return true;
	self.layout = layout;
	if (size_changed || fill_changed)
	{
		if (size_changed) self.request_size();
		// Explicit/auto sizes and maximums affect stretch even when the cached
		// preferred size remains identical. Fill only affects parent placement.
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
		int content_height;
		for (Widget* child = self.first; child; child = child.next)
		{
			if (child.hidden) continue;
			child.measure();
			if (self.kind == SCROLL_COLUMN)
			{
				content_height = coordinate((long)content_height + child.desired.height +
					(preceding ? self.layout.gap : 0));
			}
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
		if (self.kind == SCROLL_COLUMN && self.content_height != content_height)
		{
			if (self.owner.scroll_pressed == self) self.owner.cancel_scrollbar();
			self.content_height = content_height;
			self.request_layout(); // A fixed viewport can have a changing extent.
		}
		size.width = layout_add(size.width, self.layout.padding * 2);
		if (self.scrollbar) size.width = layout_add(size.width, SCROLLBAR_WIDTH);
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
			if (self.kind == TEXT_FIELD) self.reveal_caret();
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
		else if (self.kind == TEXT_FIELD)
		{
			// Editing does not grow the control or move its siblings.
			size.width = TEXT_FIELD_WIDTH;
			size.height = layout_add(math::max(16, size.height), TEXT_FIELD_PADDING * 2);
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
fn int alignment_offset(Alignment alignment, int available, long used) @private
{
	int remaining = (int)math::max(0L, (long)available - used);
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

fn int main_size(Widget* child, bool row, int fill_space) @private
{
	if (fill_space < 0 || !child.layout.fill) return row ? child.desired.width : child.desired.height;
	Layout layout = child.layout;
	return constrain(fill_space, 0, row ? layout.min_width : layout.min_height,
		row ? layout.max_width : layout.max_height);
}

// Shared by explicit containers and the implicit root Column. Main-axis sizes
// keep their preferred size unless opted into fill. Direct scroll-column
// children retain preferred heights in their unbounded content space.
// Available cross space wins over min; fill respects main-axis min/max.
fn void place_children(Widget* first, bool row, Rect content, Rect clip, int gap,
	Alignment main_align, Alignment cross_align, bool changed, bool scrolling = false,
	int scroll_offset = 0, int scroll_content = -1) @private
{
	long used;
	int fill_space = -1;
	int fill_remainder;
	if (changed)
	{
		int fills;
		bool preceding;
		for (Widget* child = first; child; child = child.next)
		{
			if (child.hidden) continue;
			if (preceding) used += gap;
			if (scroll_content < 0 && child.layout.fill) { fills++; }
			else { used += row ? child.desired.width : child.desired.height; }
			preceding = true;
		}
		if (fills)
		{
			int remaining = (int)math::max(0L, (long)(row ? content.width : content.height) - used);
			fill_space = remaining / fills;
			fill_remainder = remaining % fills;
			// Equal shares are clamped independently; maximum caps leave slack
			// for alignment, and minimums can overflow without shrinking siblings.
			int remainder = fill_remainder;
			for (Widget* child = first; child; child = child.next)
			{
				if (child.hidden || !child.layout.fill) continue;
				used += main_size(child, row, fill_space + (remainder > 0 ? 1 : 0));
				if (remainder) remainder--;
			}
		}
	}
	if (scroll_content >= 0) used = scroll_content;
	// Keep the untransformed cursor separate: scrolling a long list must not
	// saturate early and lose the position of its later children.
	long cursor = (long)(row ? content.x : content.y) - scroll_offset +
		alignment_offset(main_align, row ? content.width : content.height, used);
	for (Widget* child = first; child; child = child.next)
	{
		if (child.hidden) { collapse_geometry(child); continue; }
		Rect rect = child.bounds;
		if (changed)
		{
			int main = main_size(child, row, fill_space < 0 ? -1 : fill_space + (fill_remainder > 0 ? 1 : 0));
			if (child.layout.fill && fill_remainder) fill_remainder--;
			int available = row ? content.height : content.width;
			int cross = cross_size(child, row, available, cross_align);
			int offset = alignment_offset(cross_align, available, cross);
			int main_position = scrolling ? coordinate(cursor) : (int)math::min(cursor, (long)LAYOUT_LIMIT);
			rect = row ? (Rect) { main_position, position_add(content.y, offset, scrolling), main, cross } :
				(Rect) { position_add(content.x, offset, scrolling), main_position, cross, main };
		}
		child.place(rect, clip, scrolling);
		cursor = scrolling ? math::min((long)COORD_LIMIT, cursor + (row ? rect.width : rect.height) + gap) :
			math::min((long)LAYOUT_LIMIT, cursor + layout_add(row ? rect.width : rect.height, gap));
	}
}

// Every ancestor clips descendants to its padded content rectangle.
fn void Widget.place(&self, Rect bounds, Rect ancestor_clip, bool scrolling = false)
{
	if (self.hidden) { collapse_geometry(self); return; }
	Rect visible = bounds.intersect(ancestor_clip);
	Rect old_visible = self.visible;
	scrolling = scrolling || self.kind == SCROLL_COLUMN;
	bool changed = !rect_equal(bounds, self.bounds) || !rect_equal(visible, self.visible) || self.scroll_space != scrolling;
	if (!changed && !self.layout_dirty && !self.subtree_layout_dirty) return;
	if (changed && !self.is_container())
	{
		self.owner.invalidate(self.visible);
		self.owner.invalidate(visible);
	}
	self.bounds = bounds;
	self.visible = visible;
	self.scroll_space = scrolling;
	if (self.kind == TEXT_FIELD) self.reveal_caret();
	if (self.is_container())
	{
		Rect content = self.content_rect();
		Rect clip = content.intersect(visible);
		if (self.kind == SCROLL_COLUMN)
		{
			int extent = math::max(0, self.content_height - content.height);
			if (self.owner.scroll_pressed == self && extent != self.scroll_max) self.owner.cancel_scrollbar();
			self.scroll_max = extent;
			set_scroll_offset(self, math::min(self.scroll_y, self.scroll_max));
			self.place_scrollbar(old_visible);
		}
		place_children(self.first, self.kind == ROW, content, clip, self.layout.gap,
			self.layout.main_align, self.layout.cross_align, changed || self.layout_dirty, scrolling,
			self.scroll_y, self.kind == SCROLL_COLUMN ? self.content_height : -1);
	}
	self.layout_dirty = false;
	self.subtree_layout_dirty = false;
}
