module ui;
import std::core::test;

struct FillProbe @private
{
	int measurements;
}

fn Size fill_metrics(void* context, String text) @private
{
	FillProbe* probe = context;
	probe.measurements++;
	return { (int)text.len * 8, text == "tall" ? 32 : 16 };
}

fn void fill_rect(Rect rect, int x, int y, int width, int height) @private
{
	test::eq(rect.x, x);
	test::eq(rect.y, y);
	test::eq(rect.width, width);
	test::eq(rect.height, height);
}

fn void fill_rows_and_columns_reserve_siblings_padding_and_visible_gaps() @test
{
	for (int orientation = 0; orientation < 2; orientation++)
	{
		View view;
		defer view.free();
		view.resize(200, 200);
		view.set_root_spacing(0, 0);
		Layout layout = { .width = 120, .height = 120, .padding = 5, .gap = 7 };
		Widget* container = orientation == 0 ? view.row(layout) : view.column(layout);
		Widget* first = container.text("first");
		first.set_layout({ .width = 20, .height = 20 });
		Widget* hidden = container.column({ .width = 100, .height = 100, .fill = true });
		hidden.set_visible(false);
		Widget* filling = container.text("fill");
		filling.set_layout({ .width = 24, .height = 24, .fill = true });
		Widget* last = container.text("last");
		last.set_layout({ .width = 30, .height = 30 });
		view.update();
		fill_rect(first.bounds, 5, 5, 20, 20);
		fill_rect(filling.bounds, orientation == 0 ? 32 : 5, orientation == 0 ? 5 : 32,
			orientation == 0 ? 46 : 24, orientation == 0 ? 24 : 46);
		fill_rect(last.bounds, orientation == 0 ? 85 : 5, orientation == 0 ? 5 : 85, 30, 30);
		test::eq(filling.desired.width, 24);
		test::eq(filling.desired.height, 24);
		test::eq(hidden.visible.empty(), true);

		last.set_visible(false);
		view.update();
		test::eq(orientation == 0 ? filling.bounds.width : filling.bounds.height, 83);
		first.set_visible(false);
		view.update();
		fill_rect(filling.bounds, 5, 5, orientation == 0 ? 110 : 24, orientation == 0 ? 24 : 110);
	}
}

fn void fill_constraints_and_alignment_use_allocated_group_size() @test
{
	for (int orientation = 0; orientation < 2; orientation++)
	{
		View view;
		defer view.free();
		view.resize(200, 200);
		view.set_root_spacing(0, 0);
		Layout layout = { .width = 120, .height = 120, .padding = 5, .gap = 7 };
		Widget* container = orientation == 0 ? view.row(layout) : view.column(layout);
		Widget* first = container.column({ .width = 20, .height = 20 });
		Widget* filling = container.column({ .width = 20, .height = 20,
			.min_width = 12, .min_height = 12, .max_width = 40, .max_height = 40, .fill = true });
		Widget* last = container.column({ .width = 30, .height = 30 });
		Alignment[3] alignments = { START, CENTER, END };
		int[3] offsets = { 0, 3, 6 };
		foreach (index, alignment : alignments)
		{
			layout.main_align = alignment;
			container.set_layout(layout);
			view.update();
			int offset = offsets[index];
			fill_rect(first.bounds, orientation == 0 ? 5 + offset : 5,
				orientation == 0 ? 5 : 5 + offset, 20, 20);
			fill_rect(filling.bounds, orientation == 0 ? 32 + offset : 5,
				orientation == 0 ? 5 : 32 + offset, orientation == 0 ? 40 : 20,
				orientation == 0 ? 20 : 40);
			fill_rect(last.bounds, orientation == 0 ? 79 + offset : 5,
				orientation == 0 ? 5 : 79 + offset, 30, 30);
		}
		// Minimums may overflow; preferred siblings are never shrunk.
		layout.width = 50;
		layout.height = 50;
		container.set_layout(layout);
		view.update();
		fill_rect(first.bounds, 5, 5, 20, 20);
		fill_rect(filling.bounds, orientation == 0 ? 32 : 5, orientation == 0 ? 5 : 32,
			orientation == 0 ? 12 : 20, orientation == 0 ? 20 : 12);
		fill_rect(last.bounds, orientation == 0 ? 51 : 5, orientation == 0 ? 5 : 51, 30, 30);
		test::eq(last.visible.empty(), true);
		filling.set_layout({ .width = 20, .height = 20, .fill = true });
		view.update();
		test::eq(orientation == 0 ? filling.bounds.width : filling.bounds.height, 0);
		test::eq(filling.visible.empty(), true);
		layout.padding = 30;
		container.set_layout(layout);
		view.update();
		test::eq(filling.bounds.width, 0);
		test::eq(filling.bounds.height, 0);
	}
}

fn void fill_toggles_and_equal_preferred_constraints_invalidate_only_placement() @test
{
	View view;
	defer view.free();
	FillProbe probe;
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	view.set_measurer(&fill_metrics, &probe);
	Widget* outer = view.column({ .width = 120, .height = 60 });
	Widget* row = outer.row({ .width = 120, .height = 60, .gap = 5 });
	Widget* first = row.text("a");
	first.set_layout({ .width = 20 });
	Widget* filling = row.text("b");
	filling.set_layout({ .width = 20 });
	Widget* last = row.text("c");
	last.set_layout({ .width = 30 });
	view.update();
	view.take_damage();
	fill_rect(last.bounds, 50, 0, 30, 16);
	Layout layout = filling.layout;
	layout.fill = true;
	test::eq(filling.set_layout(layout), true);
	test::eq(view.measure_dirty || outer.measure_dirty || row.measure_dirty || filling.measure_dirty, false);
	view.update();
	fill_rect(filling.bounds, 25, 0, 60, 16);
	fill_rect(last.bounds, 90, 0, 30, 16);
	test::eq(filling.desired.width, 20);
	test::eq(view.take_damage().empty(), false);
	test::eq(filling.set_layout(layout), true);
	view.update();
	test::eq(view.take_damage().empty(), true);
	layout.max_width = 20;
	filling.set_layout(layout);
	view.update();
	fill_rect(last.bounds, 50, 0, 30, 16);
	test::eq(filling.desired.width, 20);
	layout.max_width = 0;
	layout.fill = false;
	filling.set_layout(layout);
	view.update();
	fill_rect(last.bounds, 50, 0, 30, 16);
	test::eq(probe.measurements, 3);
}

fn void fill_root_and_nested_containers_resize_without_changing_measurements() @test
{
	View view;
	defer view.free();
	FillProbe probe;
	view.resize(240, 200);
	view.set_measurer(&fill_metrics, &probe);
	view.set_root_alignment(START, STRETCH);
	Widget* header = view.text("heading");
	Widget* body = view.column({ .padding = 3, .gap = 4, .cross_align = STRETCH, .fill = true });
	Widget* top = body.column({ .height = 12 });
	Widget* row = body.row({ .padding = 2, .gap = 5, .fill = true });
	Widget* fixed = row.text("ab");
	Widget* filling = row.text("x");
	filling.set_layout({ .fill = true });
	body.column({ .height = 16 });
	Widget* footer = view.button("end");
	view.update();
	fill_rect(header.bounds, 16, 16, 208, 16);
	fill_rect(body.bounds, 16, 40, 208, 104);
	fill_rect(top.bounds, 19, 43, 202, 12);
	fill_rect(row.bounds, 19, 59, 202, 62);
	fill_rect(fixed.bounds, 21, 61, 16, 16);
	fill_rect(filling.bounds, 42, 61, 177, 16);
	fill_rect(footer.bounds, 16, 152, 208, 32);
	Size desired = body.desired;
	view.resize(260, 250);
	view.update();
	fill_rect(body.bounds, 16, 40, 228, 154);
	fill_rect(row.bounds, 19, 59, 222, 112);
	fill_rect(filling.bounds, 42, 61, 197, 16);
	fill_rect(footer.bounds, 16, 202, 228, 32);
	test::eq(body.desired.width, desired.width);
	test::eq(body.desired.height, desired.height);
	test::eq(probe.measurements, 4);
	// A root fill edit must also trigger placement with unchanged preferred size.
	Layout layout = body.layout;
	layout.fill = false;
	body.set_layout(layout);
	test::eq(view.measure_dirty, false);
	view.update();
	test::eq(body.bounds.height, desired.height);
	test::eq(footer.bounds.y, 40 + desired.height + 8);
}

fn void fill_reactive_siblings_change_allocation_even_under_fixed_ancestors() @test
{
	View view;
	defer view.free();
	FillProbe probe;
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	view.set_measurer(&fill_metrics, &probe);
	Widget* outer = view.column({ .width = 120, .height = 100 });
	Widget* column = outer.column({ .width = 120, .height = 100, .gap = 5 });
	State{bool} tall;
	Widget* header = column.text().@text(&tall, fn (s) => s.get() ? "tall" : "a");
	Widget* filling = column.column({ .min_height = 1, .fill = true });
	Widget* footer = column.button("end");
	view.update();
	test::eq(filling.bounds.height, 42);
	test::eq(footer.bounds.y, 68);
	tall.set(true);
	view.update();
	test::eq(header.bounds.height, 32);
	test::eq(filling.bounds.y, 37);
	test::eq(filling.bounds.height, 26);
	test::eq(footer.bounds.y, 68);
	test::eq(probe.measurements, 3);
	header.remove();
	view.update();
	test::eq(filling.bounds.y, 0);
	test::eq(filling.bounds.height, 63);
	test::eq(footer.bounds.y, 68);
}

fn void fill_multiple_children_share_pixels_and_clamp_independently() @test
{
	View view;
	defer view.free();
	view.resize(200, 100);
	view.set_root_spacing(0, 0);
	Widget* row = view.row({ .width = 101, .height = 30, .gap = 3, .main_align = END });
	Widget* fixed = row.column({ .width = 20, .height = 20 });
	Widget* first = row.column({ .height = 20, .fill = true });
	Widget* second = row.column({ .height = 20, .fill = true });
	view.update();
	fill_rect(fixed.bounds, 0, 0, 20, 20);
	fill_rect(first.bounds, 23, 0, 38, 20);
	fill_rect(second.bounds, 64, 0, 37, 20);
	first.set_layout({ .height = 20, .max_width = 10, .fill = true });
	view.update();
	fill_rect(fixed.bounds, 28, 0, 20, 20);
	fill_rect(first.bounds, 51, 0, 10, 20);
	fill_rect(second.bounds, 64, 0, 37, 20);
	first.set_visible(false);
	view.update();
	fill_rect(fixed.bounds, 0, 0, 20, 20);
	fill_rect(second.bounds, 23, 0, 78, 20);
}

fn void fill_scroll_viewport_keeps_unbounded_content_and_updates_scroll_extent() @test
{
	View view;
	defer view.free();
	FillProbe probe;
	view.resize(120, 160);
	view.set_root_spacing(4, 6);
	view.set_root_alignment(START, STRETCH);
	view.set_measurer(&fill_metrics, &probe);
	Widget* header = view.text("heading");
	header.set_layout({ .height = 20 });
	Widget* panel = view.scroll_column({ .padding = 3, .gap = 5, .min_height = 24,
		.cross_align = STRETCH, .fill = true });
	panel.set_scrollbar();
	// Fill in an unbounded vertical scroll group retains its preferred height.
	Widget* first = panel.button("one");
	first.set_layout({ .fill = true });
	Widget* row = panel.row({ .height = 32, .gap = 2, .cross_align = STRETCH });
	row.text("ab");
	Widget* nested_fill = row.text("x");
	nested_fill.set_layout({ .fill = true });
	panel.button("three");
	Widget* footer = view.text("end");
	footer.set_layout({ .height = 18 });
	view.update();
	fill_rect(panel.bounds, 4, 30, 112, 102);
	fill_rect(first.bounds, 7, 33, 94, 32);
	fill_rect(nested_fill.bounds, 25, 70, 76, 32);
	test::eq(panel.content_height, 106);
	test::eq(panel.scroll_extent(), 10);
	test::eq(panel.scroll_track.empty(), false);
	view.resize(120, 100);
	view.update();
	test::eq(panel.bounds.height, 42);
	test::eq(panel.scroll_extent(), 70);
	panel.scroll_to(70);
	test::eq(first.bounds.y, -37);
	view.resize(120, 200);
	view.update();
	test::eq(panel.bounds.height, 142);
	test::eq(panel.scroll_extent(), 0);
	test::eq(panel.scroll_offset(), 0);
	test::eq(panel.scroll_track.empty(), true);
	test::eq(probe.measurements, 6);
}

fn void fill_large_siblings_and_gaps_do_not_wrap_the_remaining_budget() @test
{
	View view;
	defer view.free();
	view.resize(LAYOUT_LIMIT, LAYOUT_LIMIT);
	view.set_root_spacing(0, 0);
	Widget* row = view.row({ .width = LAYOUT_LIMIT, .height = 20, .gap = LAYOUT_LIMIT,
		.main_align = END });
	Widget* first = row.column({ .width = LAYOUT_LIMIT, .height = 20 });
	Widget* filling = row.column({ .min_width = 3, .height = 20, .fill = true });
	Widget* last = row.column({ .width = LAYOUT_LIMIT, .height = 20 });
	view.update();
	fill_rect(first.bounds, 0, 0, LAYOUT_LIMIT, 20);
	fill_rect(filling.bounds, LAYOUT_LIMIT, 0, 3, 20);
	fill_rect(last.bounds, LAYOUT_LIMIT, 0, LAYOUT_LIMIT, 20);
	test::eq(filling.visible.empty() && last.visible.empty(), true);
	view.resize(0, 0);
	view.update();
	test::eq(first.visible.empty() && filling.visible.empty(), true);
}
