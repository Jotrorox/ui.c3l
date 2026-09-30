module ui;

// Semantic colors allow backends to select pixels without assuming an X11
// visual's channel masks. The initial palette is intentionally monochrome.
enum Ink { PAPER, INK }
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
				renderer.border(widget.scroll_track, INK)!;
				renderer.fill(renderer.context, widget.scroll_thumb, INK)!;
			}
			continue;
		}
		renderer.clip(renderer.context, widget.visible.intersect(clip))!;
		Rect rect = widget.bounds;
		Ink foreground = INK;
		int x = rect.x;
		int y = rect.y;
		if (widget.kind == BUTTON)
		{
			bool down = self.pressed == widget && self.hovered == widget;
			if (down)
			{
				renderer.fill(renderer.context, rect, INK)!;
				foreground = PAPER;
			}
			renderer.border(rect, INK)!;
			if (self.focused == widget || self.hovered == widget)
			{
				renderer.border({ rect.x + 3, rect.y + 3, rect.width - 6, rect.height - 6 }, foreground)!;
			}
			x += 12;
			y += 8;
		}
		else if (widget.kind == CHECKBOX)
		{
			Rect box = { x + CHECKBOX_PADDING, y + (rect.height - CHECKBOX_SIZE) / 2,
				CHECKBOX_SIZE, CHECKBOX_SIZE };
			bool down = self.pressed == widget && self.hovered == widget;
			if (down) renderer.fill(renderer.context, box, INK)!;
			renderer.border(box, INK)!;
			if (widget.checked) renderer.fill(renderer.context, inset(box, 4), down ? PAPER : INK)!;
			if (self.focused == widget || self.hovered == widget)
			{
				renderer.border(rect, INK)!;
			}
			x += CHECKBOX_PADDING + CHECKBOX_SIZE + CHECKBOX_GAP;
			y += (rect.height - widget.text_size.height) / 2;
		}
		renderer.text(renderer.context, widget.content, x, y, foreground)!;
		if (!widget.is_enabled())
		{
			renderer.fill(renderer.context, { x, y + widget.text_size.height / 2, widget.text_size.width, 1 }, foreground)!;
		}
	}
}
