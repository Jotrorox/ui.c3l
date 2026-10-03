module ui;
import std::core::test;

struct FieldProbe
{
	Widget* field;
	Widget* remove;
	String saved;
	int changes;
	bool rewrite;
	bool observed;
}

fn void field_changed(void* context, String text) @private
{
	FieldProbe* probe = context;
	probe.changes++;
	probe.observed = probe.field.get_text() == text;
	if (probe.rewrite) probe.field.set_text("normalized");
	if (probe.remove) probe.remove.remove();
	// Snapshot remains readable after reentrant assignment and subtree removal.
	probe.saved.free(mem);
	probe.saved = text.copy(mem);
}

fn void textfield_copies_initial_and_programmatic_text_and_emits_only_edits() @test
{
	FieldProbe probe;
	defer probe.saved.free(mem);
	View view;
	defer view.free();
	view.resize(400, 300);
	@pool() { probe.field = view.text_field(string::tformat("value %s", 1), &field_changed, &probe); };
	view.focus_next();
	test::eq(probe.field.get_text(), "value 1");
	test::eq(probe.field.selection().caret, 7);
	view.key_down(30, NONE); // A physical key never inserts a character itself.
	view.key_down(32, ACTIVATE); // Space must arrive through committed text.
	view.activate_focused();
	test::eq(probe.changes, 0);
	test::eq(probe.field.get_text(), "value 1");
	test::eq(view.text_input(" 世界"), true);
	test::eq(probe.saved, "value 1 世界");
	test::eq(probe.observed, true);
	test::eq(probe.changes, 1);
	probe.field.set_text("reset");
	test::eq(probe.changes, 1);
	test::eq(probe.field.selection().anchor, 5);
	test::eq(probe.field.selection().caret, 5);
	test::eq(view.text_input(" "), true);
	test::eq(probe.field.get_text(), "reset ");
}

fn void textfield_scalar_navigation_shift_selection_and_repeat_delete() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("aé👋z");
	view.focus_next();
	view.key_down(1, LEFT);
	test::eq(field.selection().caret, 7);
	view.key_down(1, LEFT, repeat: true, reverse: true);
	test::eq(field.selection().anchor, 7);
	test::eq(field.selection().caret, 3);
	view.key_down(1, LEFT, repeat: true, reverse: true);
	test::eq(field.selection().caret, 1);
	test::eq(view.text_input("世界"), true);
	test::eq(field.get_text(), "a世界z");
	test::eq(field.selection().caret, 7);
	view.key_down(2, BACKSPACE);
	test::eq(field.get_text(), "a世z");
	view.key_down(2, BACKSPACE, repeat: true);
	test::eq(field.get_text(), "az");
	view.key_down(3, DELETE);
	test::eq(field.get_text(), "a");
	view.key_down(3, DELETE, repeat: true); // End of text is a no-op.
	test::eq(field.get_text(), "a");
	view.key_down(4, SCROLL_HOME);
	view.key_down(2, BACKSPACE);
	test::eq(field.get_text(), "a");
	view.key_down(5, SELECT_ALL);
	test::eq(field.selection().anchor, 0);
	test::eq(field.selection().caret, 1);
	view.key_down(2, BACKSPACE);
	test::eq(field.get_text(), "");
}

fn void textfield_selection_direction_boundaries_and_collapse() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("é👋z");
	view.focus_next();
	test::eq(field.select(6, 0), true);
	view.key_down(1, RIGHT);
	test::eq(field.selection().anchor, 6);
	test::eq(field.selection().caret, 6);
	field.select(0, 6);
	view.key_down(2, LEFT);
	test::eq(field.selection().caret, 0);
	test::eq(field.select(1, 2), false);
	test::eq(field.select(0, 4), false);
	test::eq(field.select(-1, 0), false);
	test::eq(field.select(0, 8), false);
	test::eq(field.selection().caret, 0);
	field.select(6, 2);
	test::eq(view.text_input("X"), true);
	test::eq(field.get_text(), "éXz");
}

fn void textfield_rejects_invalid_multiline_and_over_limit_commits_atomically() @test
{
	FieldProbe probe;
	defer probe.saved.free(mem);
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("safe", &field_changed, &probe);
	probe.field = field;
	view.focus_next();
	field.select(0, 4);
	foreach (String invalid : { "", "\n", "\r", "\t", "\0", "a\nb", "\x7f", "\xc2\x85", "\xe2\x80\xa8", "\xe2\x80\xa9", "\xff", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80" })
	{
		test::eq(view.text_input(invalid), false);
		test::eq(field.get_text(), "safe");
		test::eq(field.selection().anchor, 0);
		test::eq(field.selection().caret, 4);
	}
	char[4096] full;
	full[..] = 'x';
	field.set_text((String)full[..]);
	test::eq(view.text_input("é"), false);
	test::eq(field.get_text().len, 4096);
	field.select(4094, 4096);
	test::eq(view.text_input("é"), true);
	test::eq(field.get_text().len, 4096);
	test::eq(field.get_text()[4094..], "é");
	test::eq(probe.changes, 1);
	field.select(4094, 4096);
	test::eq(view.text_input("é"), true); // Consumed, but same content is silent.
	test::eq(probe.changes, 1);
	test::eq(field.selection().anchor, 4096);
}

fn void textfield_callbacks_keep_snapshot_alive_after_assignment_and_removal() @test
{
	for (int mode = 0; mode < 3; mode++)
	{
		FieldProbe probe = { .rewrite = true };
		defer probe.saved.free(mem);
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* parent = view.column();
		probe.field = parent.text_field("a", &field_changed, &probe);
		probe.remove = mode == 1 ? probe.field : mode == 2 ? parent : null;
		view.focus_next();
		if (mode == 1) { view.key_down(8, BACKSPACE); }
		else { test::eq(view.text_input("b"), true); }
		test::eq(probe.saved, mode == 1 ? "" : "ab");
		test::eq(probe.changes, 1);
		test::eq(probe.observed, true);
		if (!mode) { test::eq(probe.field.get_text(), "normalized"); }
		else { test::eq(view.focused == null && view.pressed == null, true); }
		view.update();
	}
}

fn void textfield_typed_modifier_and_owned_state_copy() @test
{
	FieldProbe probe;
	defer probe.saved.free(mem);
	View view;
	defer view.free();
	view.resize(400, 300);
	probe.field = view.text_field().@on_text_change(&probe, fn (p, text) {
		p.saved.free(mem);
		p.saved = text.copy(mem);
		p.changes++;
	});
	view.focus_next();
	view.text_input("query");
	test::eq(probe.saved, "query");
	test::eq(probe.changes, 1);
}

fn void textfield_disabled_hidden_clipped_and_blurred_fields_reject_text() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	State{bool} enabled = { .value = true };
	Widget* parent = view.column().@enabled(&enabled);
	Widget* field = parent.text_field("safe");
	view.focus_next();
	enabled.set(false);
	test::eq(view.text_input("ignored"), false); // Flush pending binding first.
	test::eq(view.focused == null, true);
	enabled.set(true);
	view.focus_next();
	parent.set_visible(false);
	test::eq(view.text_input("ignored"), false);
	parent.set_visible(true);
	view.focus_next();
	parent.set_layout({ .width = 1, .padding = 1 });
	test::eq(view.text_input("ignored"), false);
	parent.set_layout({});
	view.focus_next();
	view.blur();
	test::eq(view.text_input("ignored"), false);
	test::eq(field.get_text(), "safe");
}

fn void textfield_tab_reveals_scrolled_field_and_home_end_edit_in_place() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* list = view.scroll_column({ .width = 200, .height = 64 });
	list.text("filler").set_layout({ .height = 120 });
	Widget* field = list.text_field("abc");
	Widget* button = view.button("next");
	view.focus_next();
	test::eq(view.focused, field);
	int offset = list.scroll_offset();
	test::eq(offset > 0, true);
	view.key_down(1, SCROLL_HOME);
	test::eq(field.selection().caret, 0);
	test::eq(list.scroll_offset(), offset);
	view.key_down(2, SCROLL_END, reverse: true);
	test::eq(field.selection().anchor, 0);
	test::eq(field.selection().caret, 3);
	view.key_down(9, TAB);
	test::eq(view.focused, button);
	view.key_down(9, TAB, reverse: true);
	test::eq(view.focused, field);
}

fn void textfield_pointer_hit_testing_drag_outside_and_cancellation() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("aé👋z");
	view.update();
	Rect content = field.field_rect();
	view.pointer_down(content.x + 8, content.y + 1);
	test::eq(field.selection().caret, 1);
	view.pointer_move(content.x + 24, content.y + 1);
	test::eq(field.selection().anchor, 1);
	test::eq(field.selection().caret, 7);
	view.pointer_up(-1000, -1000);
	test::eq(field.selection().caret, 0);
	test::eq(view.pressed == null && view.focused == field, true);
	view.pointer_down(content.x + 16, content.y + 1);
	view.pointer_up(content.x + 16, content.y + 1);
	view.pointer_down(content.x + 32, content.y + 1, extend: true);
	test::eq(field.selection().anchor, 3);
	test::eq(field.selection().caret, 8);
	view.cancel_press();
	view.pointer_move(10000, 10000);
	test::eq(field.selection().caret, 8);
	view.pointer_down(field.bounds.x - 1, field.bounds.y);
	test::eq(view.focused == null, true);
}

fn Size proportional_field_metrics(void* context, String text) @private => @pool()
{
	int width;
	foreach (code : text.to_temp_utf32()!!) width += code == 'W' ? 20 : code == 'i' ? 2 : 12;
	return { width, 16 };
}

fn void textfield_pointer_uses_native_prefix_widths_at_scalar_boundaries() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	view.set_measurer(&proportional_field_metrics);
	Widget* field = view.text_field("Wié");
	view.update();
	Rect content = field.field_rect();
	int[5] positions = { 9, 11, 21, 26, 29 };
	sz[5] expected = { 0, 1, 2, 2, 4 };
	foreach (i, position : positions)
	{
		view.pointer_down(content.x + position, content.y);
		view.pointer_up(content.x + position, content.y);
		test::eq(field.selection().caret, expected[i]);
	}
}

struct FieldPaint
{
	Rect clip;
	Rect content;
	Rect selected;
	Rect caret;
	int inverse;
	int text_x;
}
fn void? field_clip(void* context, Rect clip) @private { FieldPaint* paint = context; paint.clip = clip; }
fn void? field_fill(void* context, Rect rect, Ink ink) @private
{
	FieldPaint* paint = context;
	if (ink != INK || !rect_equal(paint.clip, paint.content)) return;
	if (rect.width == 1 && rect.height == paint.content.height) { paint.caret = rect; }
	else if (rect.height == paint.content.height) { paint.selected = rect; }
}
fn void? field_text(void* context, String text, int x, int y, Ink ink) @private
{
	FieldPaint* paint = context;
	paint.text_x = x;
	if (ink == PAPER) paint.inverse++;
}

fn void textfield_paint_selection_caret_and_horizontal_reveal_keep_fixed_geometry() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("abcdefghijklmnop");
	field.set_layout({ .width = 64 });
	Widget* sibling = view.text("unchanged");
	view.focus_next();
	Rect before = sibling.bounds;
	FieldPaint paint = { .content = field.field_rect().intersect(field.visible) };
	Renderer renderer = { &paint, &field_fill, &field_text, &field_clip };
	view.paint(&renderer, view.take_damage())!!;
	test::eq(field.text_scroll_x > 0, true);
	test::eq(paint.content.contains(paint.caret.x, paint.caret.y), true);
	test::eq(paint.text_x < paint.content.x, true);
	field.select(2, 0);
	view.paint(&renderer, view.take_damage())!!;
	test::eq(field.text_scroll_x, 0);
	test::eq(paint.selected.width, 16);
	test::eq(paint.inverse, 1);
	view.text_input("é");
	view.update();
	test::eq(rect_equal(sibling.bounds, before), true);
	test::eq(field.bounds.width, 64);
	field.set_layout({ .width = 220 });
	view.update();
	test::eq(field.text_scroll_x, 0);
}
