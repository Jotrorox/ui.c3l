module ui;
import std::core::test;

struct CounterTest
{
	State{int} count;
	State{int} unrelated;
	State{bool} alternate;
	int calls;
}

fn String counter_text(void* context) @private
{
	CounterTest* counter = context;
	counter.calls++;
	return string::tformat("Count: %s", counter.count.get());
}

fn String conditional_text(void* context) @private
{
	CounterTest* counter = context;
	counter.calls++;
	if (counter.alternate.get()) return string::tformat("%s", counter.unrelated.get());
	// Repeated reads must only create one edge.
	return string::tformat("%s", counter.count.get() + counter.count.get());
}

fn void automatic_dependencies_keep_identity_and_coalesce_writes() @test
{
	CounterTest state = { .count.value = 5 };
	View view;
	defer view.free();
	view.resize(800, 600);
	Widget* text = view.text();
	text.bind(&counter_text, &state);
	Widget* other = view.text("untouched");
	view.update();
	view.take_damage();
	test::eq(text.get_text(), "Count: 5");
	state.count.set(5);
	state.unrelated.set(1);
	view.update();
	test::eq(state.calls, 1);
	test::eq(view.take_damage().empty(), true);
	state.count.set(6);
	state.count.set(7);
	view.update();
	test::eq(state.calls, 2);
	test::eq(view.first, text);
	test::eq(text.next, other);
	test::eq(text.get_text(), "Count: 7");
	test::eq(view.take_damage().height, text.bounds.height);
}

fn void conditional_bindings_replace_old_dependencies() @test
{
	CounterTest state;
	View view;
	defer view.free();
	Widget* text = view.text();
	text.bind(&conditional_text, &state);
	test::eq(state.count.signal.subscribers.source_next == null, true);
	state.alternate.set(true);
	view.update();
	test::eq(state.count.signal.subscribers == null, true);
	state.count.set(4);
	view.update();
	test::eq(state.calls, 2);
	state.unrelated.set(9);
	view.update();
	test::eq(state.calls, 3);
	test::eq(text.get_text(), "9");
}

fn void pending_bindings_can_be_replaced_removed_and_freed() @test
{
	CounterTest state;
	View view;
	Widget* first = view.text();
	Widget* second = view.text();
	first.bind(&counter_text, &state);
	second.bind(&counter_text, &state);
	state.count.set(1);
	second.remove();
	first.set_text("manual");
	view.update();
	test::eq(first.get_text(), "manual");
	test::eq(state.calls, 2);
	test::eq(state.count.signal.subscribers == null, true);
	first.bind(&counter_text, &state);
	state.count.set(2);
	view.free();
	test::eq(state.count.signal.subscribers == null, true);
	state.count.set(3); // No stale subscribers after disposal.
}

fn void state_can_feed_multiple_views() @test
{
	CounterTest state;
	View first, second;
	defer first.free();
	defer second.free();
	Widget* a = first.text();
	Widget* b = second.text();
	a.bind(&counter_text, &state);
	b.bind(&counter_text, &state);
	state.count.set(6);
	first.update();
	test::eq(a.get_text(), "Count: 6");
	test::eq(b.get_text(), "Count: 0");
	second.update();
	test::eq(b.get_text(), "Count: 6");
}

struct MetricsTest { int measurements; int fills; int texts; }

fn Size test_measure(void* context, String text) @private
{
	MetricsTest* metrics = context;
	metrics.measurements++;
	return { (int)text.len * 8, text == "tall" ? 32 : 16 };
}

fn void? test_fill(void* context, Rect rect, Ink ink) @private
{
	MetricsTest* metrics = context;
	metrics.fills++;
}
fn void? test_text(void* context, String text, int x, int y, Ink ink) @private
{
	MetricsTest* metrics = context;
	metrics.texts++;
}
fn void? test_clip(void* context, Rect rect) @private {}

fn void measurement_is_cached_and_only_size_changes_move_siblings() @test
{
	View view;
	defer view.free();
	MetricsTest metrics;
	view.set_measurer(&test_measure, &metrics);
	view.resize(800, 600);
	Widget* text = view.text("one");
	Widget* button = view.button("OK", null);
	view.update();
	view.take_damage();
	int y = button.bounds.y;
	test::eq(metrics.measurements, 2);
	view.pointer_move(button.bounds.x + 1, y + 1);
	view.update();
	test::eq(metrics.measurements, 2);
	view.take_damage();
	text.set_text("two");
	view.update();
	test::eq(button.bounds.y, y);
	test::eq(metrics.measurements, 3);
	Renderer renderer = { &metrics, &test_fill, &test_text, &test_clip };
	view.paint(&renderer, view.take_damage())!!;
	test::eq(metrics.texts, 1); // The unaffected button is not painted.
	text.set_text("tall");
	view.update();
	test::eq(button.bounds.y, y + 16);
	view.take_damage();
	view.resize(60, 100);
	view.update();
	test::eq(text.bounds.width, 28);
	test::eq(metrics.measurements, 4); // Resize reuses measured content.
}

fn void count_click(void* context) @private
{
	int* clicks = context;
	(*clicks)++;
}

fn void buttons_capture_cancel_disable_and_support_focus() @test
{
	View view;
	defer view.free();
	int clicks;
	Widget* button = view.button("OK", &count_click, &clicks);
	view.resize(800, 600);
	view.update();
	view.pointer_up(20, 20);
	test::eq(clicks, 0);
	view.pointer_down(20, 20);
	view.pointer_up(200, 200);
	test::eq(clicks, 0);
	view.pointer_down(20, 20);
	view.pointer_move(200, 200);
	view.pointer_up(20, 20);
	test::eq(clicks, 1);
	view.pointer_down(20, 20);
	button.set_enabled(false);
	view.pointer_up(20, 20);
	view.focus_next();
	view.activate_focused();
	test::eq(clicks, 1);
	test::eq(view.focused == null, true);
	button.set_enabled(true);
	view.focus_next();
	view.activate_focused();
	test::eq(clicks, 2);
	view.pointer_down(20, 20);
	view.blur();
	view.pointer_up(20, 20);
	test::eq(clicks, 2);
}

fn void remove_clicked(void* context) @private
{
	Widget* widget = context;
	widget.remove();
}

fn void click_callbacks_may_remove_their_button() @test
{
	View view;
	defer view.free();
	Widget* button = view.button("Remove", &remove_clicked);
	button.click_context = button;
	view.resize(800, 600);
	view.update();
	view.pointer_down(20, 20);
	view.pointer_up(20, 20);
	test::eq(view.first == null, true);
	test::eq(view.pressed == null, true);
	test::eq(view.focused == null, true);
	view.update();
}

fn String parity_text(void* context) @private
{
	State{int}* value = context;
	return value.get() % 2 == 0 ? "even" : "odd";
}

fn void equal_binding_results_skip_measurement_and_paint() @test
{
	State{int} value;
	View view;
	defer view.free();
	MetricsTest metrics;
	view.set_measurer(&test_measure, &metrics);
	view.resize(800, 600);
	Widget* button = view.button("", null);
	button.bind(&parity_text, &value);
	view.update();
	view.take_damage();
	value.set(2);
	view.update();
	test::eq(button.get_text(), "even");
	test::eq(metrics.measurements, 1);
	test::eq(view.take_damage().empty(), true);
	value.set(3);
	view.update();
	test::eq(button.get_text(), "odd");
	test::eq(metrics.measurements, 2);
	test::eq(view.take_damage().empty(), false);
}

fn void text_owns_its_storage_and_shrinking_erases_old_bounds() @test
{
	View view;
	defer view.free();
	char[6] buffer = { 's', 't', 'a', 'b', 'l', 'e' };
	Widget* text = view.text((String)buffer[..]);
	buffer[0] = 'X';
	test::eq(text.get_text(), "stable");
	view.resize(800, 600);
	view.update();
	int old_width = text.bounds.width;
	view.take_damage();
	text.set_text(text.get_text()[:1]); // Source may alias the widget's own storage.
	view.update();
	test::eq(text.get_text(), "s");
	test::eq(view.take_damage().width, old_width);
	text.set_text("世界");
	view.update();
	test::eq(text.get_text(), "世界");
	test::eq(text.bounds.width, 16);
}

fn void focus_wraps_in_both_directions_and_skips_non_buttons() @test
{
	View view;
	defer view.free();
	view.resize(800, 600); // Fully clipped widgets are not focusable.
	view.text("heading");
	Widget* first = view.button("first", null);
	Widget* disabled = view.button("disabled", null);
	disabled.set_enabled(false);
	Widget* last = view.button("last", null);
	view.text("footer");
	view.focus_next();
	test::eq(view.focused, first);
	view.focus_next();
	test::eq(view.focused, last);
	view.focus_next();
	test::eq(view.focused, first);
	view.focus_next(reverse: true);
	test::eq(view.focused, last);
	last.remove();
	first.remove();
	view.focus_next(reverse: true);
	test::eq(view.focused == null, true);
}
