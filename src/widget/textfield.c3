module ui;
import std::math;

const int TEXT_FIELD_WIDTH = 160;
const int TEXT_FIELD_PADDING = 8;
const sz TEXT_FIELD_LIMIT = 4096;

// Offsets are bytes, not glyph indices. Movement/deletion use Unicode scalars,
// including combining marks individually. anchor stays fixed during Shift/drag.
struct TextSelection { sz anchor; sz caret; }

fn Widget* add_text_field(View* view, String text, TextChangeHandler on_change,
	void* context, Widget* parent = null) @private
{
	Widget* widget = add_widget(view, TEXT_FIELD, text, parent);
	widget.on_text_change = on_change;
	widget.text_change_context = context;
	return widget;
}

fn Widget* View.text_field(&self, String text = "", TextChangeHandler on_change = null, void* context = null) =>
	add_text_field(self, text, on_change, context);
fn Widget* Widget.text_field(&self, String text = "", TextChangeHandler on_change = null, void* context = null) =>
	add_text_field(self.owner, text, on_change, context, self);

fn bool valid_field_text(String text) @private => @pool()
{
	if (text.len > TEXT_FIELD_LIMIT) return false;
	Char32[]? codes = text.to_temp_utf32();
	if (catch codes) return false;
	foreach (code : codes)
	{
		if (code < 32 || (code >= 127 && code <= 159) || code == 0x2028 || code == 0x2029) return false;
	}
	return true;
}

fn bool text_boundary(String text, sz position) @private =>
	position >= 0 && position <= text.len && (position == text.len || (text[position] & 0xc0) != 0x80);

fn sz text_previous(String text, sz position) @private
{
	if (!position) return 0;
	position--;
	while (position && (text[position] & 0xc0) == 0x80) position--;
	return position;
}

fn sz text_next(String text, sz position) @private
{
	if (position == text.len) return position;
	position++;
	while (position < text.len && (text[position] & 0xc0) == 0x80) position++;
	return position;
}

fn TextSelection Widget.selection(&self)
{
	assert(self.kind == TEXT_FIELD, "Only TextFields have a text selection");
	return self.text_selection;
}

// Invalid offsets leave the selection intact. Programmatic selection is silent.
fn bool Widget.select(&self, sz anchor, sz caret)
{
	assert(!active_binding, "Bindings cannot change selections");
	assert(self.kind == TEXT_FIELD, "Only TextFields have a text selection");
	if (!text_boundary(self.content, anchor) || !text_boundary(self.content, caret)) return false;
	if (self.text_selection.anchor == anchor && self.text_selection.caret == caret) return true;
	self.text_selection = { anchor, caret };
	self.reveal_caret();
	self.owner.invalidate(self.visible);
	return true;
}

fn Rect Widget.field_rect(&self) => inset(self.bounds, self.owner.get_theme().control_padding_y, true);

fn int Widget.text_prefix_width(&self, sz position)
{
	View* view = self.owner;
	String prefix = self.content[:position];
	Size size = view.text_metrics(prefix);
	return math::clamp(size.width, 0, LAYOUT_LIMIT);
}

fn void Widget.reveal_caret(&self)
{
	int width = self.field_rect().width;
	int caret = self.text_prefix_width(self.text_selection.caret);
	int total = self.text_prefix_width(self.content.len);
	int offset = math::clamp(self.text_scroll_x, 0, math::max(0, total + 1 - width));
	if (caret < offset) offset = caret;
	if (caret >= offset + width) offset = math::max(0, caret + 1 - width);
	if (offset == self.text_scroll_x) return;
	self.text_scroll_x = offset;
	self.owner.invalidate(self.visible);
}

// Search measured prefixes at scalar boundaries. Use the same native metrics
// for hit testing, selection ink, and caret reveal, including proportional text.
fn sz Widget.text_position_at(&self, int x)
{
	long target = (long)x - self.field_rect().x + self.text_scroll_x;
	if (target <= 0) return 0;
	sz low;
	sz high = self.content.len;
	while (low < high)
	{
		sz middle = (low + high) / 2;
		while (middle > low && !text_boundary(self.content, middle)) middle--;
		if (self.text_prefix_width(middle) < target) { low = text_next(self.content, middle); }
		else { high = middle; }
	}
	if (!low) return 0;
	sz previous = text_previous(self.content, low);
	return target * 2 < (long)self.text_prefix_width(previous) + self.text_prefix_width(low) ? previous : low;
}

fn void replace_field_selection(Widget* self, String text) @private
{
	sz start = math::min(self.text_selection.anchor, self.text_selection.caret);
	sz end = math::max(self.text_selection.anchor, self.text_selection.caret);
	sz length = self.content.len - (end - start) + text.len;
	if (length > TEXT_FIELD_LIMIT) return; // Never truncate a commit or split UTF-8.
	char[4096] buffer;
	buffer[:start] = ((char[])self.content)[:start];
	buffer[start:text.len] = ((char[])text)[..];
	buffer[start + text.len:length - start - text.len] = ((char[])self.content)[end..];
	String next = (String)buffer[:length];
	bool changed = next != self.content;
	assign_text(self, next);
	self.text_selection = { start + text.len, start + text.len };
	self.reveal_caret();
	self.owner.invalidate(self.visible);
	if (!changed || !self.on_text_change) return;
	// Independent storage makes reentrant set_text/removal safe for the callback.
	String snapshot = self.content.copy(mem);
	defer snapshot.free(mem);
	TextChangeHandler handler = self.on_text_change;
	void* context = self.text_change_context;
	handler(context, snapshot);
	// Do not touch self after a callback: it may have removed this subtree.
}

// Committed text is distinct from physical keys. Native adapters/input methods
// may deliver whole strings here. Invalid/empty/over-limit commits are rejected
// atomically. Returns true if an eligible field consumed the commit.
fn bool View.text_input(&self, String text)
{
	assert(!active_binding, "Bindings cannot dispatch text input");
	self.update();
	Widget* field = self.focused;
	if (!field || field.kind != TEXT_FIELD || !field.interactive() || !text.len || !valid_field_text(text)) return false;
	sz selected = math::max(field.text_selection.anchor, field.text_selection.caret) -
		math::min(field.text_selection.anchor, field.text_selection.caret);
	if (field.content.len - selected + text.len > TEXT_FIELD_LIMIT) return false;
	replace_field_selection(field, text);
	return true;
}

fn bool field_key(Widget* field, ControlKey action, bool extend) @private
{
	TextSelection selection = field.text_selection;
	sz start = math::min(selection.anchor, selection.caret);
	sz end = math::max(selection.anchor, selection.caret);
	sz caret = selection.caret;
	switch (action)
	{
		case LEFT: caret = !extend && start != end ? start : text_previous(field.content, caret);
		case RIGHT: caret = !extend && start != end ? end : text_next(field.content, caret);
		case SCROLL_HOME: caret = 0;
		case SCROLL_END: caret = field.content.len;
		case SELECT_ALL: field.select(0, field.content.len); return true;
		case BACKSPACE:
		case DELETE:
			if (start == end)
			{
				start = action == BACKSPACE ? text_previous(field.content, start) : start;
				end = action == DELETE ? text_next(field.content, end) : end;
			}
			if (start != end)
			{
				field.text_selection = { start, end };
				replace_field_selection(field, "");
			}
			return true;
		case ACTIVATE: return true; // Enter is single-line; Space arrives as text.
		default: return false;
	}
	field.select(extend ? selection.anchor : caret, caret);
	return true;
}

fn void? paint_text_field(Widget* field, Renderer* renderer, Rect clip) @private
{
	Rect bounds = field.bounds;
	bool enabled = field.is_enabled();
	Ink foreground = enabled ? INK : DISABLED;
	renderer.fill(renderer.context, bounds, enabled ? SURFACE : DISABLED_SURFACE)!;
	renderer.border(bounds, enabled ? BORDER : DISABLED)!;
	bool focused = enabled && field.owner.focused == field;
	if (focused) renderer.border(inset(bounds, 3, true), FOCUS)!;
	Rect content = field.field_rect();
	Rect text_clip = content.intersect(field.visible).intersect(clip);
	if (text_clip.empty()) return;
	renderer.clip(renderer.context, text_clip)!;
	int x = coordinate((long)content.x - field.text_scroll_x);
	int y = coordinate((long)bounds.y + (long)(bounds.height - field.text_size.height) / 2);
	TextSelection selection = field.text_selection;
	int start = field.text_prefix_width(math::min(selection.anchor, selection.caret));
	int end = field.text_prefix_width(math::max(selection.anchor, selection.caret));
	Rect selected = { coordinate((long)x + start), content.y, end - start, content.height };
	if (focused && end > start) renderer.fill(renderer.context, selected, SELECTION)!;
	renderer.text(renderer.context, field.content, x, y, foreground)!;
	if (focused && end > start)
	{
		// Redraw the full shaped run through the selection clip to retain kerning.
		renderer.clip(renderer.context, selected.intersect(text_clip))!;
		renderer.text(renderer.context, field.content, x, y, SELECTION_TEXT)!;
		renderer.clip(renderer.context, text_clip)!;
	}
	if (focused)
	{
		int caret = field.text_prefix_width(selection.caret);
		renderer.fill(renderer.context, { coordinate((long)x + caret), content.y, 1, content.height }, INK)!;
	}
}
