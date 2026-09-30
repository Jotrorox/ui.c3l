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

struct Binding @private
{
	Widget* widget;
	TextBinding evaluate;
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
	// Copy the result while the callback's temporary strings are still alive.
	self.widget.assign_text(self.evaluate(self.context));
}

fn void Widget.unbind(&self)
{
	assert(!active_binding, "Bindings cannot mutate the widget tree");
	Binding* binding = self.binding;
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
	self.binding = null;
	binding.unsubscribe();
	mem::free(binding);
}

// Bind either a Text's content or a Button's label. Reads of State.get() inside
// evaluate subscribe automatically, including reads in helper functions.
fn void Widget.bind(&self, TextBinding evaluate, void* context = null)
{
	assert(!self.is_container(), "Only Text and Button widgets have labels");
	assert(evaluate != null);
	self.unbind();
	self.binding = mem::new(Binding, { .widget = self, .evaluate = evaluate, .context = context });
	self.binding.run();
}
