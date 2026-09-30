module ui;
import std::math;

const int SCROLLBAR_WIDTH = 12;
const int SCROLLBAR_MIN_THUMB = 16;

// Reserve the gutter even without overflow. Measurement never depends on
// placement or scrollbar visibility, including under stretch/max constraints.
fn bool Widget.set_scrollbar(&self, bool enabled = true)
{
	assert(!active_binding, "Bindings cannot configure scrollbars");
	if (self.kind != SCROLL_COLUMN) return false;
	if (self.scrollbar == enabled) return true;
	self.owner.cancel_scrollbar_subtree(self);
	self.owner.invalidate(self.visible);
	self.scrollbar = enabled;
	self.request_size();
	self.request_layout();
	return true;
}

// Placement, clipping, and keyboard reveal share this content rectangle.
fn Rect Widget.content_rect(&self)
{
	Rect content = inset(self.bounds, self.layout.padding, self.scroll_space);
	if (self.scrollbar) content.width = math::max(0, content.width - SCROLLBAR_WIDTH);
	return content;
}

fn void View.cancel_scrollbar(&self)
{
	self.scroll_pressed = null;
	self.scroll_dragging = false;
	// Keep scroll_press_active until release. No dangling handle is needed to
	// remember that this press must never activate a widget underneath it.
}

fn void View.cancel_scrollbar_subtree(&self, Widget* subtree)
{
	for (Widget* node = self.scroll_pressed; node; node = node.parent)
	{
		if (node == subtree) { self.cancel_scrollbar(); return; }
	}
}

fn void Widget.place_scrollbar(&self, Rect old_visible)
{
	Rect track;
	Rect thumb;
	Rect padded = inset(self.bounds, self.layout.padding, true);
	if (self.scrollbar && self.scroll_max && !padded.empty())
	{
		int width = math::min(SCROLLBAR_WIDTH, padded.width);
		track = { coordinate((long)padded.x + padded.width - width), padded.y, width, padded.height };
		int length = math::min(track.height, math::max(SCROLLBAR_MIN_THUMB,
			(int)((long)track.height * padded.height / self.content_height)));
		int travel = track.height - length;
		int top = (int)(((long)self.scroll_y * travel + self.scroll_max / 2) / self.scroll_max);
		thumb = { track.x, coordinate((long)track.y + top), track.width, length };
	}
	if (self.owner.scroll_pressed == self && (!rect_equal(track, self.scroll_track) ||
		!rect_equal(track.intersect(self.visible), self.scroll_track.intersect(old_visible)) ||
		thumb.height != self.scroll_thumb.height)) self.owner.cancel_scrollbar();
	if (!rect_equal(track, self.scroll_track) || !rect_equal(thumb, self.scroll_thumb) ||
		!rect_equal(old_visible, self.visible))
	{
		self.owner.invalidate(self.scroll_track.intersect(old_visible));
		self.owner.invalidate(track.intersect(self.visible));
	}
	self.scroll_track = track;
	self.scroll_thumb = thumb;
}

fn bool View.press_scrollbar(&self, int x, int y)
{
	Widget* target;
	int depth = -1;
	for (Widget* widget = self.first; widget; widget = widget.next_in_tree())
	{
		if (!widget.is_visible() || !widget.scroll_track.intersect(widget.visible).contains(x, y)) continue;
		int candidate_depth;
		for (Widget* node = widget.parent; node; node = node.parent) candidate_depth++;
		if (candidate_depth > depth) { target = widget; depth = candidate_depth; }
	}
	if (!target) return false;
	self.scroll_press_active = true;
	if (target.is_enabled())
	{
		self.scroll_pressed = target;
		self.scroll_dragging = target.scroll_thumb.contains(x, y);
		self.scroll_anchor_y = y;
		self.scroll_anchor_offset = target.scroll_y;
		if (!self.scroll_dragging)
		{
			int page = target.content_rect().height;
			long next = (long)target.scroll_y + (long)(y < target.scroll_thumb.y ? -page : page);
			set_scroll_offset(target, (int)math::clamp(next, 0L, (long)target.scroll_max));
		}
	}
	self.update();
	return true;
}

fn void View.move_scrollbar(&self, int y)
{
	Widget* target = self.scroll_pressed;
	if (!target || !self.scroll_dragging) return;
	int travel = target.scroll_track.height - target.scroll_thumb.height;
	if (!travel) return;
	// Delta anchoring preserves the exact offset at zero movement, even when
	// several content pixels map to one thumb pixel. Signed ties round away
	// from zero. int endpoints multiplied by COORD_LIMIT still fit in long.
	long scaled = ((long)y - self.scroll_anchor_y) * target.scroll_max;
	long delta = scaled >= 0 ? (scaled + travel / 2) / travel : -((-scaled + travel / 2) / travel);
	int offset = (int)math::clamp((long)self.scroll_anchor_offset + delta, 0L, (long)target.scroll_max);
	set_scroll_offset(target, offset);
	self.update();
}

// All public scroll operations flush queued bindings/layout first. Queries on
// ordinary widgets return zero; mutations reject them without side effects.
fn int Widget.scroll_offset(&self)
{
	if (self.kind != SCROLL_COLUMN) return 0;
	self.owner.update();
	return self.scroll_y;
}

fn int Widget.scroll_extent(&self)
{
	if (self.kind != SCROLL_COLUMN) return 0;
	self.owner.update();
	return self.scroll_max;
}

fn void set_scroll_offset(Widget* self, int offset) @private
{
	if (offset == self.scroll_y) return;
	self.owner.cancel_widget_press();
	self.owner.invalidate(self.visible);
	self.scroll_y = offset;
	self.request_layout();
}

fn bool Widget.scroll_to(&self, int offset)
{
	assert(!active_binding, "Bindings cannot scroll widgets");
	if (self.kind != SCROLL_COLUMN) return false;
	self.owner.update();
	int next = math::clamp(offset, 0, self.scroll_max);
	if (next != self.scroll_y) self.owner.cancel_scrollbar();
	set_scroll_offset(self, next);
	self.owner.update();
	return true;
}

fn bool Widget.scroll_by(&self, int delta)
{
	assert(!active_binding, "Bindings cannot scroll widgets");
	if (self.kind != SCROLL_COLUMN) return false;
	self.owner.update();
	int next = (int)math::clamp((long)self.scroll_y + delta, 0L, (long)self.scroll_max);
	if (next != self.scroll_y) self.owner.cancel_scrollbar();
	set_scroll_offset(self, next);
	self.owner.update();
	return true;
}

// Pointer routing starts at the deepest viewport under the pointer (padding
// included). Only that viewport's ancestors may receive a boundary event.
// One viewport consumes the entire event; an unused remainder never bubbles.
fn bool View.scroll_wheel(&self, int x, int y, int delta)
{
	assert(!active_binding, "Bindings cannot dispatch wheel input");
	// Wheel coordinates select a viewport, but are not captured drag motion.
	// In particular a zero/boundary wheel event must not move a held thumb.
	self.pointer_x = x;
	self.pointer_y = y;
	self.pointer_known = true;
	self.update();
	if (!delta) return false;
	Widget* target;
	int depth = -1;
	for (Widget* widget = self.first; widget; widget = widget.next_in_tree())
	{
		if (widget.kind != SCROLL_COLUMN || !widget.is_visible() || !widget.is_enabled() ||
			!widget.visible.contains(x, y)) continue;
		int candidate_depth;
		for (Widget* node = widget.parent; node; node = node.parent) candidate_depth++;
		if (candidate_depth > depth) { target = widget; depth = candidate_depth; }
	}
	for (Widget* node = target; node; node = node.parent)
	{
		if (node.kind != SCROLL_COLUMN || !node.is_enabled()) continue;
		int offset = (int)math::clamp((long)node.scroll_y + delta, 0L, (long)node.scroll_max);
		if (offset == node.scroll_y) continue;
		self.cancel_scrollbar();
		set_scroll_offset(node, offset);
		self.update();
		return true;
	}
	return false;
}

fn Rect View.root_clip(&self) => inset({ 0, 0, self.width, self.height },
	self.custom_root_spacing ? self.root_padding : 16);

// The part of this content rectangle which ancestors can expose. Transform
// each parent's reachable viewport back through its allowed scroll offsets.
// Considering the whole ancestry matters when an outer scroll viewport is
// itself clipped and cannot move far enough: the inner one must move farther.
fn Rect reveal_clip(Widget* widget) @private
{
	Rect clip = widget.content_rect();
	Widget* parent = widget.parent;
	if (!parent) return clip.intersect(widget.owner.root_clip());
	Rect allowed = reveal_clip(parent);
	if (allowed.empty()) return allowed;
	if (parent.kind == SCROLL_COLUMN)
	{
		allowed.y = coordinate((long)allowed.y - parent.scroll_y);
		allowed.height += parent.scroll_max;
	}
	return clip.intersect(allowed);
}

// Evaluate in current coordinates without changing the tree. A second pass on
// the chosen candidate installs all offsets together, then focus_next flushes
// placement and assigns focus. Rejected candidates cause no scroll or damage.
fn bool reveal_candidate(Widget* widget, bool apply) @private
{
	if ((widget.kind != BUTTON && widget.kind != CHECKBOX) ||
		!widget.is_enabled() || !widget.is_visible()) return false;
	Rect target = widget.bounds;
	if (target.empty()) return false;
	for (Widget* node = widget.parent; node; node = node.parent)
	{
		Rect clip = node.content_rect();
		if (node.kind == SCROLL_COLUMN)
		{
			clip = reveal_clip(node);
			if (clip.empty()) return false;
			long offset = node.scroll_y;
			// Reveal the nearest edge. Oversized targets use their top edge.
			if (target.height > clip.height || target.y < clip.y)
			{
				offset += (long)target.y - clip.y;
			}
			else if ((long)target.y + target.height > (long)clip.y + clip.height)
			{
				offset += (long)target.y + target.height - clip.y - clip.height;
			}
			int next = (int)math::clamp(offset, 0L, (long)node.scroll_max);
			target.y = coordinate((long)target.y + node.scroll_y - next);
			if (apply) set_scroll_offset(node, next);
		}
		target = target.intersect(clip);
		if (target.empty()) return false;
	}
	return !target.intersect(widget.owner.root_clip()).empty();
}
