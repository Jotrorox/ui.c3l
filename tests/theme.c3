module ui;
import std::core::test;

struct ThemeProbe
{
	int measurements;
	int[INK_COUNT] fills;
	int[INK_COUNT] texts;
	Rect clip;
	Rect selected;
	int text_x;
	int text_y;
}

fn Size theme_metrics(void* context, String text) @private
{
	ThemeProbe* probe = context;
	probe.measurements++;
	return { (int)text.len * 8, 16 };
}
fn void? theme_fill(void* context, Rect rect, Ink ink) @private
{
	ThemeProbe* probe = context;
	probe.fills[ink]++;
	if (ink == SELECTION) probe.selected = rect;
}
fn void? theme_text(void* context, String text, int x, int y, Ink ink) @private
{
	ThemeProbe* probe = context;
	probe.texts[ink]++;
	probe.text_x = x;
	probe.text_y = y;
}
fn void? theme_clip(void* context, Rect rect) @private { ThemeProbe* probe = context; probe.clip = rect; }

fn void theme_defaults_invalid_values_and_equal_assignments_are_atomic() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	view.button("Save");
	view.update();
	view.take_damage();
	Theme original = view.get_theme();
	test::eq(original.same_metrics(DEFAULT_THEME) && original.same_colors(DEFAULT_THEME), true);
	test::eq(view.set_theme(DEFAULT_THEME), true);
	test::eq(view.theme_epoch, 0UL);
	for (int index = 0; index < 7; index++)
	{
		Theme invalid = original;
		switch (index)
		{
			case 0: invalid.font_size = 0;
			case 1: invalid.font_size = 257;
			case 2: invalid.padding = -1;
			case 3: invalid.gap = LAYOUT_LIMIT + 1;
			case 4: invalid.control_padding_x = LAYOUT_LIMIT / 2 + 1;
			case 5: invalid.control_padding_y = -1;
			case 6: invalid.padding = LAYOUT_LIMIT + 1;
		}
		test::eq(view.set_theme(invalid), false);
		test::eq(view.get_theme().same_metrics(original), true);
		test::eq(view.theme_epoch, 0UL);
		test::eq(view.measure_dirty || view.layout_dirty || view.subtree_layout_dirty, false);
		test::eq(view.take_damage().empty(), true);
	}
	// get_theme returns a copy and never exposes mutable palette storage.
	original.colors[Ink.PAPER] = { 12, 34, 56 };
	test::eq(view.get_theme().colors[Ink.PAPER].red, (char)255);
}

fn void theme_palette_repaints_without_measurement_and_spacing_reuses_metrics() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	ThemeProbe probe;
	view.set_measurer(&theme_metrics, &probe);
	Widget* button = view.button("Save");
	view.focus_next();
	view.take_damage();
	test::eq(probe.measurements, 1);
	Theme theme = view.get_theme();
	theme.colors[Ink.PAPER] = { 20, 30, 40 };
	theme.colors[Ink.FOCUS] = { 240, 200, 0 };
	test::eq(view.set_theme(theme), true);
	test::eq(view.measure_dirty || view.layout_dirty || view.subtree_layout_dirty, false);
	test::eq(rect_equal(view.take_damage(), { 0, 0, 400, 300 }), true);
	view.update();
	test::eq(probe.measurements, 1);
	test::eq(view.focused, button);
	ulong epoch = view.theme_epoch;
	test::eq(view.set_theme(theme), true);
	test::eq(view.theme_epoch, epoch);
	test::eq(view.take_damage().empty(), true);
	theme.control_padding_x = 20;
	theme.control_padding_y = 10;
	theme.padding = 24;
	theme.gap = 12;
	view.set_theme(theme);
	view.update();
	test::eq(probe.measurements, 1);
	test::eq(button.bounds.x, 24);
	test::eq(button.bounds.y, 24);
	test::eq(button.bounds.width, 72);
	test::eq(button.bounds.height, 36);
	Renderer renderer = { &probe, &theme_fill, &theme_text, &theme_clip };
	view.paint(&renderer, view.take_damage())!!;
	test::eq(probe.text_x, button.bounds.x + 20);
	test::eq(probe.text_y, button.bounds.y + 10);
}

fn void theme_font_scales_headless_controls_scroll_gutters_and_caret_metrics() @test
{
	View view;
	defer view.free();
	view.resize(800, 800);
	Widget* button = view.button("AB");
	Widget* check = view.checkbox("AB");
	Widget* field = view.text_field("AB");
	Widget* panel = view.scroll_column({ .width = 200, .height = 80 });
	panel.set_scrollbar();
	panel.text("body").set_layout({ .height = 300 });
	view.update();
	Theme theme = view.get_theme();
	theme.font_size = 28;
	view.set_theme(theme);
	view.update();
	test::eq(button.text_size.width, 32);
	test::eq(button.text_size.height, 32);
	test::eq(button.desired.width, 56);
	test::eq(button.desired.height, 48);
	test::eq(check.desired.width, 80);
	test::eq(check.desired.height, 40);
	test::eq(field.desired.width, 320);
	test::eq(field.text_prefix_width(1), 16);
	test::eq(field.text_position_at(field.field_rect().x + 15), 1);
	test::eq(panel.scroll_track.width, 24);
	test::eq(panel.scroll_thumb.height >= 32, true);
	test::eq(panel.content_rect().width, 176);
	field.set_layout({ .width = 64 });
	view.update();
	test::eq(field.bounds.width, 64);
}

fn void theme_preserves_explicit_root_and_container_spacing_and_other_views() @test
{
	View view, other;
	defer view.free();
	defer other.free();
	view.resize(400, 300);
	view.set_root_spacing(); // Even default values pin an explicit override.
	Widget* panel = view.column({ .padding = 3, .gap = 5 });
	Widget* first = panel.text("A");
	Widget* second = panel.text("B");
	Theme theme = view.get_theme();
	theme.padding = 40;
	theme.gap = 30;
	view.set_theme(theme);
	view.update();
	test::eq(panel.bounds.x, 16);
	test::eq(panel.bounds.y, 16);
	test::eq(first.bounds.x, 19);
	test::eq(second.bounds.y - first.bounds.y, 21);
	test::eq(other.get_theme().same_metrics(DEFAULT_THEME), true);
}

fn void theme_hidden_font_changes_are_deferred_and_survive_restoration() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* parent = view.column();
	Widget* text = parent.text("AB");
	view.update();
	parent.set_visible(false);
	view.update();
	Theme theme = view.get_theme();
	theme.font_size = 28;
	view.set_theme(theme);
	view.update();
	test::eq(text.text_size.width, 16);
	test::eq(text.text_dirty, true);
	parent.set_visible(true);
	view.update();
	test::eq(text.text_size.width, 32);
	test::eq(text.text_dirty, false);
}

fn void theme_renderer_distinguishes_hover_focus_press_and_inherited_disabled_state() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* button = view.button("Save");
	Widget* parent = view.column();
	parent.text("Label");
	parent.checkbox("Check", true);
	parent.text_field("Value");
	parent.set_enabled(false);
	view.update();
	ThemeProbe probe;
	Renderer renderer = { &probe, &theme_fill, &theme_text, &theme_clip };
	view.pointer_move(button.bounds.x + 1, button.bounds.y + 1);
	view.paint(&renderer, { 0, 0, 400, 300 })!!;
	test::eq(probe.fills[Ink.HOVER], 1);
	test::eq(probe.fills[Ink.FOCUS], 0);
	test::eq(probe.fills[Ink.DISABLED_SURFACE], 2);
	test::eq(probe.texts[Ink.DISABLED], 3);
	probe = {};
	view.focus_next();
	view.paint(&renderer, { 0, 0, 400, 300 })!!;
	test::eq(probe.fills[Ink.FOCUS], 4);
	probe = {};
	view.pointer_down(button.bounds.x + 1, button.bounds.y + 1);
	view.paint(&renderer, { 0, 0, 400, 300 })!!;
	test::eq(probe.fills[Ink.PRESSED], 1);
	test::eq(probe.texts[Ink.PRESSED_TEXT], 1);
	test::eq(probe.fills[Ink.FOCUS], 4);
	button.set_enabled(false);
	probe = {};
	view.paint(&renderer, { 0, 0, 400, 300 })!!;
	test::eq(view.focused, null);
	test::eq(probe.fills[Ink.FOCUS], 0);
	test::eq(probe.fills[Ink.PRESSED], 0);
	test::eq(probe.texts[Ink.DISABLED], 4);
}

fn void theme_selection_roles_and_runtime_metrics_preserve_editing_state() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("abcdefghijklmnop");
	field.set_layout({ .width = 80 });
	view.focus_next();
	field.select(2, 0);
	Theme theme = view.get_theme();
	theme.font_size = 28;
	theme.control_padding_y = 4;
	view.set_theme(theme);
	view.update();
	ThemeProbe probe;
	Renderer renderer = { &probe, &theme_fill, &theme_text, &theme_clip };
	view.paint(&renderer, view.take_damage())!!;
	test::eq(field.selection().anchor, 2);
	test::eq(field.selection().caret, 0);
	test::eq(view.focused, field);
	test::eq(probe.selected.width, 32);
	test::eq(probe.texts[Ink.SELECTION_TEXT], 1);
	test::eq(probe.fills[Ink.FOCUS], 4);
	test::eq(field.field_rect().width, 72);
	view.text_input("é");
	test::eq(field.get_text(), "écdefghijklmnop");
}
