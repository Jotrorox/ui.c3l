module ui;

enum WidgetKind { TEXT, BUTTON, ROW, COLUMN }
alias ClickHandler = fn void(void* context);

// Handles stay at the same address until remove() or View.free(). All storage,
// including copied labels and dependency edges, is owned by the View. Tree,
// geometry and dirty fields are read-only to callers; use the methods to edit.
struct Widget
{
	WidgetKind kind;
	View* owner;
	Widget* parent; // null means the View's implicit root Column
	Widget* next;
	Widget* previous;
	Widget* first;
	Widget* last;
	String content;
	Layout layout;
	Rect bounds;
	Rect visible; // bounds intersected with every ancestor's content clip
	Size desired;
	Size text_size;
	Binding* binding;
	ClickHandler on_click;
	void* click_context;
	bool disabled;
	bool measure_dirty;
	bool text_dirty;
	bool layout_dirty;
	bool subtree_layout_dirty;
}

fn bool Widget.is_container(&self) => self.kind == ROW || self.kind == COLUMN;

fn Widget* Widget.next_in_tree(&self)
{
	if (self.first) return self.first;
	for (Widget* node = self; node; node = node.parent)
	{
		if (node.next) return node.next;
	}
	return null;
}

fn void Widget.children_changed(&self)
{
	self.request_size();
	self.request_layout();
}

fn void unlink_widget(Widget* self) @private
{
	View* view = self.owner;
	// Reparenting can change inherited enabled state without changing geometry.
	view.invalidate(self.visible);
	if (self.previous) { self.previous.next = self.next; }
	else if (self.parent) { self.parent.first = self.next; }
	else { view.first = self.next; }
	if (self.next) { self.next.previous = self.previous; }
	else if (self.parent) { self.parent.last = self.previous; }
	else { view.last = self.previous; }
	if (self.parent) { self.parent.children_changed(); }
	else { view.layout_dirty = true; }
}

fn void attach_widget(Widget* self, Widget* parent) @private
{
	View* view = self.owner;
	self.parent = parent;
	self.next = null;
	self.previous = parent ? parent.last : view.last;
	if (self.previous) { self.previous.next = self; }
	else if (parent) { parent.first = self; }
	else { view.first = self; }
	if (parent)
	{
		parent.last = self;
		parent.children_changed();
	}
	else { view.last = self; view.layout_dirty = true; }
	// Moving a dirty subtree must mark its new ancestry, even if its own flags
	// were already set under the old parent.
	for (Widget* node = parent; node; node = node.parent) node.measure_dirty = true;
	view.measure_dirty = true;
	self.request_layout();
}

// Append moves an existing subtree to the end, without changing its ownership.
// Invalid attachments are rejected atomically. Handles must still be alive.
fn bool Widget.append(&self, Widget* child)
{
	assert(!active_binding, "Bindings cannot mutate the widget tree");
	if (!self.is_container() || !child || child.owner != self.owner) return false;
	for (Widget* node = self; node; node = node.parent) if (node == child) return false;
	if (child.parent == self && self.last == child) return true;
	unlink_widget(child);
	attach_widget(child, self);
	return true;
}

fn bool View.append(&self, Widget* child)
{
	assert(!active_binding, "Bindings cannot mutate the widget tree");
	if (!child || child.owner != self) return false;
	if (!child.parent && self.last == child) return true;
	unlink_widget(child);
	attach_widget(child, null);
	return true;
}

fn Widget* add_widget(View* self, WidgetKind kind, String text, Widget* parent = null) @private
{
	assert(!active_binding, "Bindings cannot mutate the widget tree");
	assert(!parent || (parent.owner == self && parent.is_container()), "Children need a container in this View");
	Widget* widget = mem::new(Widget, { .kind = kind, .owner = self });
	attach_widget(widget, parent);
	if (!widget.is_container())
	{
		widget.assign_text(text);
		widget.request_measure();
	}
	else { widget.request_size(); }
	return widget;
}

fn Widget* View.text(&self, String text = "") => add_widget(self, TEXT, text);
fn Widget* Widget.text(&self, String text = "") => add_widget(self.owner, TEXT, text, self);

fn Widget* View.button(&self, String label, ClickHandler on_click, void* context = null)
{
	Widget* widget = add_widget(self, BUTTON, label);
	widget.on_click = on_click;
	widget.click_context = context;
	return widget;
}

fn Widget* Widget.button(&self, String label, ClickHandler on_click, void* context = null)
{
	Widget* widget = add_widget(self.owner, BUTTON, label, self);
	widget.on_click = on_click;
	widget.click_context = context;
	return widget;
}

fn Widget* add_container(View* self, WidgetKind kind, Layout layout, Widget* parent = null) @private
{
	assert(layout.valid(), "Invalid container layout");
	Widget* widget = add_widget(self, kind, "", parent);
	bool valid = widget.set_layout(layout);
	assert(valid);
	return widget;
}

fn Widget* View.row(&self, Layout layout = {}) => add_container(self, ROW, layout);
fn Widget* View.column(&self, Layout layout = {}) => add_container(self, COLUMN, layout);
fn Widget* Widget.row(&self, Layout layout = {}) => add_container(self.owner, ROW, layout, self);
fn Widget* Widget.column(&self, Layout layout = {}) => add_container(self.owner, COLUMN, layout, self);

fn void Widget.assign_text(&self, String text)
{
	assert(!self.is_container(), "Only Text and Button widgets have labels");
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
	self.owner.invalidate(self.visible);
}

// An explicit assignment replaces any reactive binding on this property.
fn void Widget.set_text(&self, String text)
{
	self.unbind();
	self.assign_text(text);
}

fn String Widget.get_text(&self) => self.content;

fn bool Widget.is_enabled(&self)
{
	for (Widget* node = self; node; node = node.parent) if (node.disabled) return false;
	return true;
}

fn bool Widget.interactive(&self) =>
	self.kind == BUTTON && self.is_enabled() && !self.visible.empty();

fn void Widget.set_enabled(&self, bool enabled)
{
	assert(!active_binding, "Bindings cannot mutate widgets");
	if (self.disabled == !enabled) return;
	self.disabled = !enabled;
	// Containers have no ink; their visible bounds cover all descendant ink.
	self.owner.invalidate(self.visible);
	self.owner.reconcile_input();
}

// Removes the whole subtree, including queued bindings, before freeing any
// parent allocation. No measurement queue can retain a freed widget pointer.
fn void Widget.remove(&self)
{
	assert(!active_binding, "Bindings cannot mutate the widget tree");
	while (self.first) self.first.remove();
	self.unbind();
	View* view = self.owner;
	if (view.focused == self) view.focused = null;
	if (view.hovered == self) view.hovered = null;
	if (view.pressed == self) view.pressed = null;
	unlink_widget(self);
	self.content.free(mem);
	mem::free(self);
}

fn Widget* View.hit_test_current(&self, int x, int y)
{
	for (Widget* widget = self.first; widget; widget = widget.next_in_tree())
	{
		if (widget.interactive() && widget.visible.contains(x, y)) return widget;
	}
	return null;
}

fn Widget* View.hit_test(&self, int x, int y)
{
	self.update();
	return self.hit_test_current(x, y);
}

fn void View.reconcile_input(&self)
{
	if (self.focused && !self.focused.interactive())
	{
		self.invalidate(self.focused.visible);
		self.focused = null;
	}
	if (self.pressed && !self.pressed.interactive()) self.cancel_press();
	Widget* hit = self.pointer_known ? self.hit_test_current(self.pointer_x, self.pointer_y) : null;
	if (hit == self.hovered) return;
	if (self.hovered) self.invalidate(self.hovered.visible);
	self.hovered = hit;
	if (hit) self.invalidate(hit.visible);
}

fn void View.pointer_move(&self, int x, int y)
{
	self.pointer_x = x;
	self.pointer_y = y;
	self.pointer_known = true;
	self.update();
}

fn void View.pointer_down(&self, int x, int y)
{
	self.cancel_press();
	self.pointer_move(x, y);
	if (self.focused) self.invalidate(self.focused.visible);
	self.focused = self.hovered;
	self.pressed = self.hovered;
	if (self.pressed) self.invalidate(self.pressed.visible);
}

fn void View.pointer_up(&self, int x, int y)
{
	self.pointer_move(x, y);
	Widget* pressed = self.pressed;
	self.cancel_press();
	// Clear capture first: callbacks may remove the widget or its ancestors.
	if (pressed && pressed == self.hovered && pressed.interactive() && pressed.on_click)
	{
		pressed.on_click(pressed.click_context);
	}
}

fn void View.cancel_press(&self)
{
	if (self.pressed) self.invalidate(self.pressed.visible);
	self.pressed = null;
}

fn void View.focus_next(&self, bool reverse = false)
{
	self.update();
	self.cancel_press();
	Widget* first;
	Widget* last;
	Widget* previous;
	Widget* next;
	bool passed = self.focused == null;
	for (Widget* widget = self.first; widget; widget = widget.next_in_tree())
	{
		if (!widget.interactive()) continue;
		if (!first) first = widget;
		last = widget;
		if (widget == self.focused) { passed = true; continue; }
		if (!passed) { previous = widget; }
		else if (!next) { next = widget; }
	}
	if (self.focused) self.invalidate(self.focused.visible);
	self.focused = reverse ? (previous ? previous : last) : (next ? next : first);
	if (self.focused) self.invalidate(self.focused.visible);
}

fn void View.activate_focused(&self)
{
	self.update();
	Widget* widget = self.focused;
	if (widget && widget.interactive() && widget.on_click) widget.on_click(widget.click_context);
}

fn void View.blur(&self)
{
	self.cancel_press();
	self.pointer_known = false;
	if (self.hovered) self.invalidate(self.hovered.visible);
	self.hovered = null;
	if (self.focused) self.invalidate(self.focused.visible);
	self.focused = null;
}
