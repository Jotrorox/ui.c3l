module ui;
import std::core::test;

fn void scrollbar_rect(Rect rect, int x, int y, int width, int height) @private
{
	test::eq(rect.x, x);
	test::eq(rect.y, y);
	test::eq(rect.width, width);
	test::eq(rect.height, height);
}

fn void scrollbar_opt_in_reserves_gutter_without_changing_default_layout() @test
{
	View view;
	defer view.free();
	view.resize(240, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 60,
		.padding = 5, .cross_align = STRETCH });
	Widget* child = panel.text("a");
	view.update();
	test::eq(panel.scrollbar, false);
	scrollbar_rect(child.bounds, 5, 5, 90, 16);
	test::eq(panel.scroll_track.empty() && panel.scroll_thumb.empty(), true);
	test::eq(panel.set_scrollbar(), true);
	view.update();
	test::eq(panel.scrollbar, true);
	scrollbar_rect(panel.content_rect(), 5, 5, 78, 50);
	scrollbar_rect(child.bounds, 5, 5, 78, 16);
	test::eq(panel.scroll_track.empty() && panel.scroll_thumb.empty(), true);
	child.set_layout({ .height = 100 });
	view.update();
	scrollbar_rect(child.visible, 5, 5, 78, 50);
	scrollbar_rect(panel.scroll_track, 83, 5, 12, 50);
	scrollbar_rect(panel.scroll_thumb, 83, 5, 12, 25);
	test::eq(panel.set_scrollbar(false), true);
	view.update();
	scrollbar_rect(child.visible, 5, 5, 90, 50);
	test::eq(panel.scroll_track.empty() && panel.scroll_thumb.empty(), true);
}

fn void scrollbar_intrinsic_width_includes_reserved_gutter_and_respects_constraints() @test
{
	View view;
	defer view.free();
	view.resize(240, 200);
	view.set_root_spacing(0, 0);
	Widget* natural = view.scroll_column({ .padding = 3 });
	natural.text("ab");
	Widget* capped = view.scroll_column({ .padding = 3, .max_width = 25 });
	capped.text("ab");
	Widget* empty = view.scroll_column({ .padding = 3 });
	foreach (Widget* panel : { natural, capped, empty }) panel.set_scrollbar();
	view.update();
	test::eq(natural.desired.width, 34); // 16 text + 6 padding + 12 gutter.
	test::eq(natural.desired.height, 22);
	test::eq(capped.desired.width, 25);
	test::eq(capped.content_rect().width, 7);
	test::eq(empty.desired.width, 18);
	test::eq(empty.desired.height, 6);
	test::eq(natural.scroll_track.empty() && capped.scroll_track.empty() && empty.scroll_track.empty(), true);
	natural.set_scrollbar(false);
	view.update();
	test::eq(natural.desired.width, 22);
}

fn void scrollbar_padding_alignment_and_stretch_use_reduced_content_width() @test
{
	Alignment[4] aligns = { START, CENTER, END, STRETCH };
	int[4] positions = { 5, 36, 67, 5 };
	foreach (index, cross : aligns)
	{
		View view;
		defer view.free();
		view.resize(200, 200);
		view.set_root_spacing(0, 0);
		Widget* panel = view.scroll_column({ .width = 100, .height = 100, .padding = 5,
			.main_align = END, .cross_align = cross });
		panel.set_scrollbar();
		Widget* item = panel.text("ab");
		view.update();
		scrollbar_rect(item.bounds, positions[index], 79, cross == STRETCH ? 78 : 16, 16);
		panel.column({ .height = 100 });
		view.update();
		test::eq(item.bounds.y, 5); // Overflow stays top anchored.
		test::eq(panel.scroll_extent(), 26);
		scrollbar_rect(panel.scroll_track, 83, 5, 12, 90);
	}
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 32, .padding = 5, .cross_align = STRETCH });
	panel.set_scrollbar();
	Widget* fixed = panel.text("fixed");
	fixed.set_layout({ .width = 120 });
	Widget* capped = panel.text("capped");
	capped.set_layout({ .max_width = 40 });
	view.update();
	test::eq(fixed.bounds.width, 78);
	test::eq(fixed.visible.width, 78);
	test::eq(capped.bounds.width, 40);
}

fn void scrollbar_thumb_rounding_proportions_and_programmatic_endpoints() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 60, .padding = 5 });
	panel.set_scrollbar();
	panel.column({ .height = 100 });
	test::eq(panel.scroll_extent(), 50);
	scrollbar_rect(panel.scroll_thumb, 83, 5, 12, 25);
	panel.scroll_to(1);
	test::eq(panel.scroll_thumb.y, 6); // Half a thumb pixel rounds toward the bottom.
	panel.scroll_by(24);
	test::eq(panel.scroll_thumb.y, 18);
	panel.scroll_to(int::max);
	scrollbar_rect(panel.scroll_thumb, 83, 30, 12, 25);
	panel.scroll_by(int::min);
	scrollbar_rect(panel.scroll_thumb, 83, 5, 12, 25);
	panel.first.set_layout({ .height = 1000 });
	view.update();
	test::eq(panel.scroll_thumb.height, 16);
	panel.scroll_to(int::max);
	test::eq(panel.scroll_thumb.y + panel.scroll_thumb.height, 55);
}

fn void scrollbar_proportional_arithmetic_uses_wide_products() @test
{
	View view;
	defer view.free();
	view.resize(100, LAYOUT_LIMIT);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = LAYOUT_LIMIT });
	panel.set_scrollbar();
	panel.column({ .height = LAYOUT_LIMIT });
	panel.column({ .height = LAYOUT_LIMIT });
	test::eq(panel.scroll_extent(), 65535);
	scrollbar_rect(panel.scroll_thumb, 88, 0, 12, 32767);
	panel.scroll_to(32768);
	test::eq(panel.scroll_thumb.y, 16384);
	panel.scroll_to(65534);
	test::eq(panel.scroll_thumb.y, 32767);
	panel.scroll_to(65535);
	test::eq(panel.scroll_thumb.y, 32768);
	view.pointer_down(90, 40000);
	test::eq(view.scroll_dragging, true);
	view.pointer_move(int::min, int::min);
	test::eq(panel.scroll_offset(), 0);
	view.pointer_move(int::max, int::max);
	test::eq(panel.scroll_offset(), 65535);
	view.pointer_up(int::max, int::max);
	test::eq(view.scroll_press_active, false);
}

fn void scrollbar_empty_zero_and_tiny_viewports_have_bounded_geometry() @test
{
	View view;
	defer view.free();
	view.resize(100, 100);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 8, .height = 8 });
	panel.set_scrollbar();
	view.update();
	test::eq(panel.scroll_extent(), 0);
	test::eq(panel.scroll_track.empty(), true);
	scrollbar_rect(panel.content_rect(), 0, 0, 0, 8);
	Widget* child = panel.button("a");
	view.update();
	scrollbar_rect(panel.scroll_track, 0, 0, 8, 8);
	scrollbar_rect(panel.scroll_thumb, 0, 0, 8, 8);
	test::eq(child.visible.empty(), true);
	view.pointer_down(1, 1);
	view.pointer_move(1, 100);
	test::eq(panel.scroll_offset(), 0); // No thumb travel: wheel/API remain available.
	view.pointer_up(1, 100);
	panel.scroll_to(12);
	test::eq(panel.scroll_offset(), 12);
	panel.set_layout({ .width = 8, .height = 8, .padding = 4 });
	view.update();
	test::eq(panel.scroll_track.empty() && panel.scroll_thumb.empty(), true);
	test::eq(panel.scroll_extent(), 32);
	panel.set_layout({ .width = 8, .height = 8, .padding = 9 });
	view.update();
	test::eq(panel.content_rect().empty() && panel.scroll_track.empty(), true);
	view.resize(0, 0);
	view.update();
	test::eq(view.take_damage().empty(), true);
	view.pointer_down(1, 1);
	test::eq(view.scroll_press_active, false);
}

fn void scrollbar_invalid_targets_and_idempotent_updates_have_no_side_effects() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	Widget* row = view.row();
	Widget* column = view.column();
	Widget* text = view.text("text");
	Widget* button = view.button("button");
	Widget* check = view.checkbox("check");
	Widget* panel = view.scroll_column({ .height = 20 });
	panel.text("a");
	panel.set_scrollbar();
	view.update();
	view.take_damage();
	foreach (Widget* target : { row, column, text, button, check })
	{
		test::eq(target.set_scrollbar(), false);
		test::eq(target.set_scrollbar(false), false);
		test::eq(target.scrollbar, false);
		test::eq(target.measure_dirty || target.layout_dirty, false);
	}
	test::eq(panel.set_scrollbar(), true);
	test::eq(view.measure_dirty || view.layout_dirty || view.subtree_layout_dirty, false);
	view.update();
	test::eq(view.take_damage().empty(), true);
}
