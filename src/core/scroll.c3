module ui;
import std::math;

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
	self.owner.cancel_press();
	self.owner.invalidate(self.visible);
	self.scroll_y = offset;
	self.request_layout();
}

fn bool Widget.scroll_to(&self, int offset)
{
	assert(!active_binding, "Bindings cannot scroll widgets");
	if (self.kind != SCROLL_COLUMN) return false;
	self.owner.update();
	set_scroll_offset(self, math::clamp(offset, 0, self.scroll_max));
	self.owner.update();
	return true;
}

fn bool Widget.scroll_by(&self, int delta)
{
	assert(!active_binding, "Bindings cannot scroll widgets");
	if (self.kind != SCROLL_COLUMN) return false;
	self.owner.update();
	set_scroll_offset(self, (int)math::clamp((long)self.scroll_y + delta, 0L, (long)self.scroll_max));
	self.owner.update();
	return true;
}

// Pointer routing starts at the deepest viewport under the pointer (padding
// included). Only that viewport's ancestors may receive a boundary event.
// One viewport consumes the entire event; an unused remainder never bubbles.
fn bool View.scroll_wheel(&self, int x, int y, int delta)
{
	assert(!active_binding, "Bindings cannot dispatch wheel input");
	self.pointer_move(x, y);
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
	Rect clip = inset(widget.bounds, widget.layout.padding, widget.scroll_space);
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
		Rect clip = inset(node.bounds, node.layout.padding, node.scroll_space);
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
