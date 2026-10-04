module ui;

// Edges belong to bindings, so destroying a widget also unsubscribes its state.
struct Signal
{
	Dependency* subscribers;
}

struct Dependency @private
{
	Signal* source;
	Binding* binding;
	Dependency* source_next;
	Dependency* source_previous;
	Dependency* binding_next;
}

alias TextBinding = fn String(void* context);
alias BoolBinding = fn bool(void* context);

enum Property @private { LABEL, ENABLED, VISIBLE, CHECKED }

struct Binding @private
{
	Widget* widget;
	Property property;
	TextBinding evaluate;
	BoolBinding evaluate_bool;
	void* context;
	Dependency* dependencies;
	Binding* pending_next;
	bool pending;
}

// All UI and state operations run on the main thread. Bindings are pure reads.
Binding* active_binding @private;

fn void Signal.track(&self)
{
	if (!active_binding) return;
	for (Dependency* edge = active_binding.dependencies; edge; edge = edge.binding_next)
	{
		if (edge.source == self) return;
	}
	Dependency* edge = mem::new(Dependency, {
		.source = self, .binding = active_binding,
		.source_next = self.subscribers, .binding_next = active_binding.dependencies,
	});
	if (self.subscribers) self.subscribers.source_previous = edge;
	self.subscribers = edge;
	active_binding.dependencies = edge;
}

fn void Signal.notify(&self)
{
	assert(!active_binding, "Bindings must only read state");
	for (Dependency* edge = self.subscribers; edge; edge = edge.source_next)
	{
		Binding* binding = edge.binding;
		if (binding.pending) continue;
		View* view = binding.widget.owner;
		binding.pending = true;
		if (view.pending_tail) { view.pending_tail.pending_next = binding; }
		else { view.pending_head = binding; }
		view.pending_tail = binding;
	}
}

fn void Binding.unsubscribe(&self)
{
	while (self.dependencies)
	{
		Dependency* edge = self.dependencies;
		self.dependencies = edge.binding_next;
		if (edge.source_previous) { edge.source_previous.source_next = edge.source_next; }
		else { edge.source.subscribers = edge.source_next; }
		if (edge.source_next) edge.source_next.source_previous = edge.source_previous;
		mem::free(edge);
	}
}

fn void Binding.run(&self) => @pool()
{
	assert(!active_binding, "Bindings cannot be evaluated recursively");
	self.unsubscribe();
	active_binding = self;
	defer active_binding = null;
	// Apply internally while the purity guard is still active. Public setters
	// would detach the binding and must remain forbidden inside callbacks.
	switch (self.property)
	{
		case LABEL: // Copy before the callback's temporary strings expire.
			assign_text(self.widget, self.evaluate(self.context));
		case ENABLED: assign_enabled(self.widget, self.evaluate_bool(self.context));
		case VISIBLE: assign_visible(self.widget, self.evaluate_bool(self.context));
		case CHECKED: assign_checked(self.widget, self.evaluate_bool(self.context));
	}
}

fn Binding** binding_slot(Widget* self, Property property) @private
{
	switch (property)
	{
		case LABEL: return &self.binding;
		case ENABLED: return &self.enabled_binding;
		case VISIBLE: return &self.visible_binding;
		case CHECKED: return &self.checked_binding;
	}
}

fn void unbind_property(Widget* self, Property property) @private
{
	assert(!active_binding, "Bindings cannot mutate the widget tree");
	Binding** slot = binding_slot(self, property);
	Binding* binding = *slot;
	if (!binding) return;
	View* view = self.owner;
	Binding* previous;
	for (Binding* item = view.pending_head; item; item = item.pending_next)
	{
		if (item == binding)
		{
			if (previous) { previous.pending_next = item.pending_next; }
			else { view.pending_head = item.pending_next; }
			if (view.pending_tail == item) view.pending_tail = previous;
			break;
		}
		previous = item;
	}
	*slot = null;
	binding.unsubscribe();
	mem::free(binding);
}

// Unbind only this property, retaining its last value. Subtree disposal uses
// dispose_bindings(), not the public, text-only unbind() compatibility API.
fn void Widget.unbind(&self) => unbind_property(self, LABEL);
fn void Widget.unbind_enabled(&self) => unbind_property(self, ENABLED);
fn void Widget.unbind_visible(&self) => unbind_property(self, VISIBLE);
fn void Widget.unbind_checked(&self) => unbind_property(self, CHECKED);

fn void dispose_bindings(Widget* self) @private
{
	self.unbind();
	self.unbind_enabled();
	self.unbind_visible();
	self.unbind_checked();
}

// Bind Text content, a Button label, or a Checkbox label. Reads of State.get() inside
// evaluate subscribe automatically, including reads in helper functions.
fn void Widget.bind(&self, TextBinding evaluate, void* context = null)
{
	assert(!self.is_container(), "Only leaf widgets have labels");
	assert(self.kind != TEXT_FIELD, "TextFields own their text; use set_text and on_text_change to synchronize state");
	assert(evaluate != null);
	self.unbind();
	self.binding = mem::new(Binding, { .widget = self, .evaluate = evaluate, .context = context });
	self.binding.run();
}

fn void bind_bool(Widget* self, Property property, BoolBinding evaluate, void* context) @private
{
	assert(evaluate != null);
	assert(property != CHECKED || self.kind == CHECKBOX, "Only Checkboxes have checked state");
	unbind_property(self, property);
	Binding* binding = mem::new(Binding, {
		.widget = self, .property = property, .evaluate_bool = evaluate, .context = context,
	});
	*binding_slot(self, property) = binding;
	binding.run();
}

fn void Widget.bind_enabled(&self, BoolBinding evaluate, void* context = null) =>
	bind_bool(self, ENABLED, evaluate, context);
fn void Widget.bind_visible(&self, BoolBinding evaluate, void* context = null) =>
	bind_bool(self, VISIBLE, evaluate, context);
fn void Widget.bind_checked(&self, BoolBinding evaluate, void* context = null) =>
	bind_bool(self, CHECKED, evaluate, context);
