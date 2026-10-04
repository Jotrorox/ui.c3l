module ui;

// Callbacks receive semantic palette roles; resolve them through get_theme().
alias FillRect = fn void?(void* context, Rect rect, Ink ink);
alias DrawText = fn void?(void* context, String text, int x, int y, Ink ink);
alias SetClip = fn void?(void* context, Rect rect);

struct Renderer
{
	void* context;
	FillRect fill;
	DrawText text;
	SetClip clip;
}

fn void? Renderer.border(&self, Rect rect, Ink ink)
{
	if (rect.empty()) return;
	self.fill(self.context, { rect.x, rect.y, rect.width, 1 }, ink)!;
	self.fill(self.context, { rect.x, rect.y + rect.height - 1, rect.width, 1 }, ink)!;
	self.fill(self.context, { rect.x, rect.y, 1, rect.height }, ink)!;
	self.fill(self.context, { rect.x + rect.width - 1, rect.y, 1, rect.height }, ink)!;
}

// Backends clip drawing to this damage rectangle. Unchanged measurements and
// widget identities survive both paint and layout passes.
fn void? View.paint(&self, Renderer* renderer, Rect clip)
{
	clip = clip.intersect({ 0, 0, self.width, self.height });
	if (clip.empty()) return;
	Theme theme = self.get_theme();
	renderer.clip(renderer.context, clip)!;
	renderer.fill(renderer.context, clip, PAPER)!;
	for (Widget* widget = self.first; widget; widget = widget.next_in_tree())
	{
		if (!widget.is_visible() || widget.visible.intersect(clip).empty()) continue;
		if (widget.is_container())
		{
			Rect track_clip = widget.scroll_track.intersect(widget.visible).intersect(clip);
			if (!track_clip.empty())
			{
				renderer.clip(renderer.context, track_clip)!;
				Ink ink = widget.is_enabled() ? INK : DISABLED;
				renderer.fill(renderer.context, widget.scroll_track, widget.is_enabled() ? SURFACE : DISABLED_SURFACE)!;
				renderer.border(widget.scroll_track, widget.is_enabled() ? BORDER : DISABLED)!;
				renderer.fill(renderer.context, widget.scroll_thumb, ink)!;
			}
			continue;
		}
		renderer.clip(renderer.context, widget.visible.intersect(clip))!;
		if (widget.kind == TEXT_FIELD)
		{
			paint_text_field(widget, renderer, clip)!;
			continue;
		}
		Rect rect = widget.bounds;
		bool enabled = widget.is_enabled();
		Ink foreground = enabled ? INK : DISABLED;
		int x = rect.x;
		int y = rect.y;
		if (widget.kind == BUTTON)
		{
			bool down = enabled && self.pressed == widget && self.hovered == widget;
			renderer.fill(renderer.context, rect, !enabled ? DISABLED_SURFACE :
				down ? PRESSED : self.hovered == widget ? HOVER : SURFACE)!;
			if (down) foreground = PRESSED_TEXT;
			renderer.border(rect, enabled ? BORDER : DISABLED)!;
			if (enabled && self.focused == widget)
			{
				renderer.border(inset(rect, 3, true), FOCUS)!;
			}
			x += theme.control_padding_x;
			y += theme.control_padding_y;
		}
		else if (widget.kind == CHECKBOX)
		{
			int size = theme.scaled(CHECKBOX_SIZE);
			int padding = theme.control_padding_y / 2;
			Rect box = { x + padding, y + (rect.height - size) / 2, size, size };
			bool down = enabled && self.pressed == widget && self.hovered == widget;
			renderer.fill(renderer.context, box, !enabled ? DISABLED_SURFACE :
				down ? PRESSED : self.hovered == widget ? HOVER : SURFACE)!;
			renderer.border(box, enabled ? BORDER : DISABLED)!;
			if (widget.checked) renderer.fill(renderer.context, inset(box, size / 4, true), down ? PRESSED_TEXT : foreground)!;
			if (enabled && self.focused == widget)
			{
				renderer.border(rect, FOCUS)!;
			}
			x += padding + size + theme.gap;
			y += (rect.height - widget.text_size.height) / 2;
		}
		renderer.text(renderer.context, widget.content, x, y, foreground)!;
	}
}
