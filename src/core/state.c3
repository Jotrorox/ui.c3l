module ui <Type>;

// Keep state at a stable address until all views that read it have been freed.
// Type must support ==. Reference/slice values remain owned by the application.
struct State
{
	Type value;
	Signal signal;
}

fn Type State.get(&self)
{
	self.signal.track();
	return self.value;
}

fn void State.set(&self, Type value)
{
	assert(!active_binding, "Bindings must only read state");
	if (self.value == value) return;
	self.value = value;
	self.signal.notify();
}
