module ui;

enum WidgetKind { TEXT, BUTTON }
alias ClickHandler = fn void(void* context);

// Handles stay at the same address until remove() or View.free(). All storage,
// including copied labels and dependency edges, is owned by the View.
struct Widget
{
	WidgetKind kind;
	View* owner;
	Widget* next;
	Widget* previous;
	String content;
	Rect bounds;
	Size desired;
	Size text_size;
	Binding* binding;
	ClickHandler on_click;
	void* click_context;
	bool disabled;
	bool measure_dirty;
	Widget* measure_next;
}

fn Widget* View.add(&self, WidgetKind kind, String text)
{
	assert(!active_binding, "Bindings cannot mutate the widget tree");
	Widget* widget = mem::new(Widget, { .kind = kind, .owner = self, .previous = self.last });
	if (self.last) { self.last.next = widget; }
	else { self.first = widget; }
	self.last = widget;
	widget.assign_text(text);
	widget.request_measure();
	self.layout_dirty = true;
	return widget;
}

fn Widget* View.text(&self, String text = "") => self.add(TEXT, text);

fn Widget* View.button(&self, String label, ClickHandler on_click, void* context = null)
{
	Widget* widget = self.add(BUTTON, label);
	widget.on_click = on_click;
	widget.click_context = context;
	return widget;
}

fn void Widget.request_measure(&self)
{
	if (self.measure_dirty) return;
	self.measure_dirty = true;
	self.measure_next = self.owner.measure_head;
	self.owner.measure_head = self;
}

fn void Widget.assign_text(&self, String text)
{
	if (self.content == text) return;
	assert(text.len <= 4096, "Widget labels are limited to 4096 UTF-8 bytes");
	@pool()
	{
		if (catch text.to_temp_utf16()) unreachable("Widget labels must be valid UTF-8");
	};
	foreach (c : text) assert(c >= 32, "Widget labels must be single-line text without control bytes");
	String copy = text.copy(mem);
	self.content.free(mem);
	self.content = copy;
	self.request_measure();
	self.owner.invalidate(self.bounds);
}

// An explicit assignment replaces any reactive binding on this property.
fn void Widget.set_text(&self, String text)
{
	self.unbind();
	self.assign_text(text);
}

fn String Widget.get_text(&self) => self.content;

fn void Widget.set_enabled(&self, bool enabled)
{
	assert(!active_binding, "Bindings cannot mutate widgets");
	if (self.disabled == !enabled) return;
	self.disabled = !enabled;
	View* view = self.owner;
	if (!enabled)
	{
		if (view.focused == self) view.focused = null;
		if (view.hovered == self) view.hovered = null;
		if (view.pressed == self) view.pressed = null;
	}
	view.invalidate(self.bounds);
}

fn void Widget.remove(&self)
{
	self.unbind();
	View* view = self.owner;
	view.invalidate(self.bounds);
	if (view.focused == self) view.focused = null;
	if (view.hovered == self) view.hovered = null;
	if (view.pressed == self) view.pressed = null;
	Widget** link = &view.measure_head;
	while (*link)
	{
		if (*link == self) { *link = self.measure_next; break; }
		link = &(*link).measure_next;
	}
	if (self.previous) { self.previous.next = self.next; }
	else { view.first = self.next; }
	if (self.next) { self.next.previous = self.previous; }
	else { view.last = self.previous; }
	view.layout_dirty = true;
	self.content.free(mem);
	mem::free(self);
}

fn Widget* View.hit_test(&self, int x, int y)
{
	if (x < 0 || y < 0 || x >= self.width || y >= self.height) return null;
	for (Widget* widget = self.first; widget; widget = widget.next)
	{
		if (widget.kind == BUTTON && !widget.disabled && widget.bounds.contains(x, y)) return widget;
	}
	return null;
}

fn void View.pointer_move(&self, int x, int y)
{
	Widget* hit = self.hit_test(x, y);
	if (hit == self.hovered) return;
	if (self.hovered) self.invalidate(self.hovered.bounds);
	self.hovered = hit;
	if (hit) self.invalidate(hit.bounds);
}

fn void View.pointer_down(&self, int x, int y)
{
	self.cancel_press();
	self.pointer_move(x, y);
	if (self.focused) self.invalidate(self.focused.bounds);
	self.focused = self.hovered;
	self.pressed = self.hovered;
	if (self.pressed) self.invalidate(self.pressed.bounds);
}

fn void View.pointer_up(&self, int x, int y)
{
	self.pointer_move(x, y);
	Widget* pressed = self.pressed;
	self.cancel_press();
	// Clear capture first: callbacks may remove the widget that was clicked.
	if (pressed && pressed == self.hovered && !pressed.disabled && pressed.on_click)
	{
		pressed.on_click(pressed.click_context);
	}
}

fn void View.cancel_press(&self)
{
	if (self.pressed) self.invalidate(self.pressed.bounds);
	self.pressed = null;
}

fn void View.focus_next(&self, bool reverse = false)
{
	self.cancel_press();
	Widget* start = self.focused;
	Widget* widget = start;
	if (start) self.invalidate(start.bounds);
	while (true)
	{
		widget = reverse ? (widget ? widget.previous : self.last) : (widget ? widget.next : self.first);
		if (!widget) widget = reverse ? self.last : self.first;
		if (!widget) break;
		if (widget.kind == BUTTON && !widget.disabled) break;
		// A full pass is also bounded when no widget currently has focus.
		if (widget == start || (!start && widget == (reverse ? self.first : self.last))) { widget = null; break; }
	}
	self.focused = widget;
	if (widget) self.invalidate(widget.bounds);
}

fn void View.activate_focused(&self)
{
	Widget* widget = self.focused;
	if (widget && !widget.disabled && widget.on_click) widget.on_click(widget.click_context);
}

fn void View.blur(&self)
{
	self.cancel_press();
	self.pointer_move(-1, -1);
	if (self.focused) self.invalidate(self.focused.bounds);
	self.focused = null;
}
