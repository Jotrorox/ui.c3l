module ui::handler <Context>;

// Typed callback shapes. Modifiers assign lambdas to these, which lets C3 infer
// lambda parameters from the context pointer: `fn (c) => c.get() != 0`.
alias Click = fn void(Context);
alias Change = fn void(Context, bool);
alias Text = fn String(Context);
alias Predicate = fn bool(Context);

module ui;

// Modifiers configure the widget they are called on and return it, so they
// chain. Each takes a context pointer with a stable address (usually a State or
// an application struct) and either reads a State directly or calls a lambda.
// Contexts must outlive the widget, exactly like the void* callback API.
//
//     view.checkbox("Show counter").@checked(&app.shown);
//     label.@text(&app.count, "Count: %s");
//     button.@on_click(&app.count, fn (c) => c.set(0))
//         .@enabled(&app.count, fn (c) => c.get() != 0);

typedef StateValue @private = int;
// Default argument meaning "read the context as a State".
const StateValue STATE_VALUE @private = (StateValue)0;

macro @require_context(context) @private
{
	$assert $Typeof(context)::kind == POINTER : "Pass a pointer to state or context with a stable address";
}

macro @predicate(context, #when) @private
{
	@require_context(context);
	$if $defined(handler::Predicate{$Typeof(context)} probe = #when):
		handler::Predicate{$Typeof(context)} evaluate = #when;
	$else
		$assert $Typeof(#when) == StateValue && $defined(context.get()) && $Typeof(context.get()) == bool
			: "Expected a State{bool}* or a fn (context) => bool lambda";
		handler::Predicate{$Typeof(context)} evaluate = fn (c) => c.get();
	$endif
	return (BoolBinding)evaluate;
}

<*
 Binds Text content or a Button/Checkbox label. `@text(&state)` shows a State's
 value, `@text(&state, "Count: %s")` formats it with a constant format string,
 and `@text(&context, fn (c) => string::tformat(...))` computes it. Lambdas may
 return temporary strings; the label is copied.
*>
macro Widget* Widget.@text(&self, context, #text = "%s")
{
	@require_context(context);
	$if $defined(handler::Text{$Typeof(context)} probe = #text):
		handler::Text{$Typeof(context)} evaluate = #text;
	$else
		var $format = #text;
		handler::Text{$Typeof(context)} evaluate = fn (c) => string::tformat($format, c.get());
	$endif
	self.bind((TextBinding)evaluate, context);
	return self;
}

<*
 Shows the widget while `@visible(&state)` holds true, or while the lambda in
 `@visible(&context, fn (c) => bool)` returns true.
*>
macro Widget* Widget.@visible(&self, context, #when = STATE_VALUE)
{
	self.bind_visible(@predicate(context, #when), context);
	return self;
}

<*
 Enables the widget while `@enabled(&state)` holds true, or while the lambda in
 `@enabled(&context, fn (c) => bool)` returns true.
*>
macro Widget* Widget.@enabled(&self, context, #when = STATE_VALUE)
{
	self.bind_enabled(@predicate(context, #when), context);
	return self;
}

<*
 `@checked(&state)` connects a Checkbox to a State{bool} in both directions: the
 State drives the box and toggling writes the State. With a lambda,
 `@checked(&context, fn (c) => bool)` only reads; pair it with @on_change.
*>
macro Widget* Widget.@checked(&self, context, #when = STATE_VALUE)
{
	self.bind_checked(@predicate(context, #when), context);
	$if !$defined(handler::Predicate{$Typeof(context)} probe = #when):
		handler::Change{$Typeof(context)} write = fn (c, checked) => c.set(checked);
		self.on_change = (CheckHandler)write;
		self.change_context = context;
	$endif
	return self;
}

<*
 Calls `fn (c) { ... }` with the context when the Button is activated.
*>
macro Widget* Widget.@on_click(&self, context, #handler)
{
	@require_context(context);
	assert(self.kind == BUTTON, "Only Buttons have click handlers");
	handler::Click{$Typeof(context)} on_click = #handler;
	self.on_click = (ClickHandler)on_click;
	self.click_context = context;
	return self;
}

<*
 Calls `fn (c, checked) { ... }` with the context and the proposed value when
 the Checkbox is toggled. This replaces the writer installed by @checked(&state).
*>
macro Widget* Widget.@on_change(&self, context, #handler)
{
	@require_context(context);
	assert(self.kind == CHECKBOX, "Only Checkboxes have change handlers");
	handler::Change{$Typeof(context)} on_change = #handler;
	self.on_change = (CheckHandler)on_change;
	self.change_context = context;
	return self;
}

// Trailing-body containers make the tree shape visible in the source:
//
//     view.@column({ .gap = 8 }; Widget* panel)
//     {
//         panel.text("Hello");
//     };
macro Widget* View.@row(&self, Layout layout = {}; @body(Widget* row))
{
	Widget* row = self.row(layout);
	@body(row);
	return row;
}

macro Widget* View.@column(&self, Layout layout = {}; @body(Widget* column))
{
	Widget* column = self.column(layout);
	@body(column);
	return column;
}

macro Widget* Widget.@row(&self, Layout layout = {}; @body(Widget* row))
{
	Widget* row = self.row(layout);
	@body(row);
	return row;
}

macro Widget* Widget.@column(&self, Layout layout = {}; @body(Widget* column))
{
	Widget* column = self.column(layout);
	@body(column);
	return column;
}
