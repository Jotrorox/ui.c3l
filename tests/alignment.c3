module ui;
import std::core::test;

fn Size alignment_metrics(void* context, String text) @private
{
	if (text == "first") return { 17, 13 };
	if (text == "second") return { 29, 21 };
	return { 11, 9 };
}

fn void alignment_rect(Rect actual, int x, int y, int width, int height) @private
{
	test::eq(actual.x, x);
	test::eq(actual.y, y);
	test::eq(actual.width, width);
	test::eq(actual.height, height);
}

fn void alignment_size(Size actual, int width, int height) @private
{
	test::eq(actual.width, width);
	test::eq(actual.height, height);
}

fn void alignment_row_and_column_axis_matrix() @test
{
	Alignment[3] main_values = { START, CENTER, END };
	Alignment[4] cross_values = { START, CENTER, END, STRETCH };
	// Expected offsets are intentionally tabulated independently of placement.
	int[3] row_main = { 0, 19, 38 };
	int[3] column_main = { 0, 12, 24 };
	int[4] row_first_cross = { 0, 26, 52, 0 };
	int[4] row_second_cross = { 0, 22, 44, 0 };
	int[4] column_first_cross = { 0, 37, 74, 0 };
	int[4] column_second_cross = { 0, 31, 62, 0 };
	for (int orientation = 0; orientation < 2; orientation++)
	{
		View view;
		defer view.free();
		view.resize(300, 200);
		view.set_root_spacing(0, 0);
		view.set_measurer(&alignment_metrics);
		Layout layout = { .width = 101, .height = 75, .padding = 5, .gap = 7 };
		Widget* container = orientation == 0 ? view.row(layout) : view.column(layout);
		Widget* first = container.text("first");
		Widget* second = container.text("second");
		foreach (main_index, main_value : main_values)
		{
			foreach (cross_index, cross_value : cross_values)
			{
				layout.main_align = main_value;
				layout.cross_align = cross_value;
				test::eq(container.set_layout(layout), true);
				view.update();
				alignment_rect(container.bounds, 0, 0, 101, 75);
				alignment_size(container.desired, 101, 75);
				alignment_size(first.desired, 17, 13);
				alignment_size(second.desired, 29, 21);
				if (orientation == 0)
				{
					alignment_rect(first.bounds, 5 + row_main[main_index],
						5 + row_first_cross[cross_index], 17, cross_value == STRETCH ? 65 : 13);
					alignment_rect(second.bounds, 29 + row_main[main_index],
						5 + row_second_cross[cross_index], 29, cross_value == STRETCH ? 65 : 21);
				}
				else
				{
					alignment_rect(first.bounds, 5 + column_first_cross[cross_index],
						5 + column_main[main_index], cross_value == STRETCH ? 91 : 17, 13);
					alignment_rect(second.bounds, 5 + column_second_cross[cross_index],
						25 + column_main[main_index], cross_value == STRETCH ? 91 : 29, 21);
				}
			}
		}
	}
}

fn void alignment_stretch_respects_explicit_sizes_and_cross_constraints() @test
{
	for (int orientation = 0; orientation < 2; orientation++)
	{
		View view;
		defer view.free();
		view.resize(500, 500);
		view.set_root_spacing(0, 0);
		view.set_measurer(&alignment_metrics);
		Layout container_layout = { .width = orientation == 0 ? 400 : 60,
			.height = orientation == 0 ? 60 : 400, .padding = 5, .gap = 3,
			.cross_align = STRETCH };
		Widget* container = orientation == 0 ? view.row(container_layout) : view.column(container_layout);
		int[7] explicit_cross = { 0, 12, 0, 0, 0, 90, 90 };
		int[7] minimum_cross = { 0, 16, 0, 20, 80, 0, 0 };
		int[7] maximum_cross = { 0, 18, 7, 27, 90, 0, 35 };
		int[7] expected_cross = { 50, 16, 7, 27, 50, 50, 35 };
		int[7] expected_desired = { orientation == 0 ? 13 : 17, 16, 7, 20, 80, 90, 35 };
		Widget*[7] children;
		for (int index = 0; index < 7; index++)
		{
			Widget* child = children[index] = container.text("first");
			Layout child_layout;
			if (orientation == 0)
			{
				child_layout.height = explicit_cross[index];
				child_layout.min_height = minimum_cross[index];
				child_layout.max_height = maximum_cross[index];
			}
			else
			{
				child_layout.width = explicit_cross[index];
				child_layout.min_width = minimum_cross[index];
				child_layout.max_width = maximum_cross[index];
			}
			test::eq(child.set_layout(child_layout), true);
		}
		view.update();
		for (int index = 0; index < 7; index++)
		{
			Widget* child = children[index];
			if (orientation == 0)
			{
				alignment_rect(child.bounds, 5 + index * 20, 5, 17, expected_cross[index]);
				alignment_size(child.desired, 17, expected_desired[index]);
			}
			else
			{
				alignment_rect(child.bounds, 5, 5 + index * 16, expected_cross[index], 13);
				alignment_size(child.desired, expected_desired[index], 13);
			}
		}
		// Center/end position the final capped size; a minimum above the
		// available cross space must never create a negative offset.
		container_layout.cross_align = CENTER;
		container.set_layout(container_layout);
		view.update();
		test::eq(orientation == 0 ? children[4].bounds.y : children[4].bounds.x, 5);
		test::eq(orientation == 0 ? children[6].bounds.y : children[6].bounds.x, 12);
		container_layout.cross_align = END;
		container.set_layout(container_layout);
		view.update();
		test::eq(orientation == 0 ? children[4].bounds.y : children[4].bounds.x, 5);
		test::eq(orientation == 0 ? children[6].bounds.y : children[6].bounds.x, 20);
	}
}

fn void alignment_implicit_root_axis_matrix() @test
{
	View view;
	defer view.free();
	view.resize(101, 75);
	view.set_root_spacing(5, 7);
	view.set_measurer(&alignment_metrics);
	Widget* first = view.text("first");
	Widget* second = view.text("second");
	Alignment[3] main_values = { START, CENTER, END };
	Alignment[4] cross_values = { START, CENTER, END, STRETCH };
	int[3] main_offsets = { 0, 12, 24 };
	int[4] first_offsets = { 0, 37, 74, 0 };
	int[4] second_offsets = { 0, 31, 62, 0 };
	foreach (main_index, main_value : main_values)
	{
		foreach (cross_index, cross_value : cross_values)
		{
			test::eq(view.set_root_alignment(main_value, cross_value), true);
			view.update();
			alignment_rect(first.bounds, 5 + first_offsets[cross_index],
				5 + main_offsets[main_index], cross_value == STRETCH ? 91 : 17, 13);
			alignment_rect(second.bounds, 5 + second_offsets[cross_index],
				25 + main_offsets[main_index], cross_value == STRETCH ? 91 : 29, 21);
			alignment_size(first.desired, 17, 13);
			alignment_size(second.desired, 29, 21);
		}
	}
}

fn void alignment_root_resizing_constraints_and_independent_spacing() @test
{
	View view;
	defer view.free();
	view.resize(200, 120);
	view.set_measurer(&alignment_metrics);
	view.set_root_alignment(END, STRETCH);
	Widget* automatic = view.column({ .height = 20, .min_width = 100, .max_width = 140 });
	Widget* explicit = view.column({ .width = 30, .height = 10 });
	view.update();
	alignment_rect(automatic.bounds, 16, 66, 140, 20);
	alignment_rect(explicit.bounds, 16, 94, 30, 10);
	alignment_size(automatic.desired, 100, 20);
	view.resize(90, 90);
	view.update();
	alignment_rect(automatic.bounds, 16, 36, 58, 20);
	alignment_rect(explicit.bounds, 16, 64, 30, 10);
	alignment_size(automatic.desired, 100, 20);
	test::eq(view.set_root_spacing(3, 5), true);
	view.update();
	alignment_rect(automatic.bounds, 3, 52, 84, 20);
	alignment_rect(explicit.bounds, 3, 77, 30, 10);
	view.set_root_alignment(CENTER, CENTER);
	view.update();
	alignment_rect(automatic.bounds, 3, 27, 84, 20);
	alignment_rect(explicit.bounds, 30, 52, 30, 10);
	// Resetting alignment retains the custom spacing.
	view.set_root_alignment();
	view.update();
	alignment_rect(automatic.bounds, 3, 3, 84, 20);
	alignment_rect(explicit.bounds, 3, 28, 30, 10);
}

fn void alignment_nested_stretch_padding_and_end_aligned_row() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(5, 0);
	view.set_root_alignment(START, STRETCH);
	view.set_measurer(&alignment_metrics);
	Widget* outer = view.column({ .height = 120, .padding = 7, .gap = 9, .cross_align = STRETCH });
	Widget* row = outer.row({ .height = 50, .padding = 3, .gap = 4,
		.main_align = END, .cross_align = CENTER });
	Widget* first = row.text("first");
	Widget* second = row.text("second");
	view.update();
	alignment_rect(outer.bounds, 5, 5, 190, 120);
	alignment_rect(row.bounds, 12, 12, 176, 50);
	alignment_rect(first.bounds, 135, 30, 17, 13);
	alignment_rect(second.bounds, 156, 26, 29, 21);
	alignment_size(row.desired, 56, 50);
	alignment_size(outer.desired, 70, 120);
	view.resize(120, 200);
	view.update();
	alignment_rect(row.bounds, 12, 12, 96, 50);
	alignment_rect(first.bounds, 55, 30, 17, 13);
	alignment_rect(second.bounds, 76, 26, 29, 21);
	alignment_size(row.desired, 56, 50);
	alignment_size(outer.desired, 70, 120);
}

fn void alignment_hidden_children_contribute_neither_size_nor_gaps() @test
{
	View view;
	defer view.free();
	view.resize(200, 150);
	view.set_root_spacing(0, 0);
	view.set_measurer(&alignment_metrics);
	Widget* row = view.row({ .width = 101, .height = 75, .padding = 5,
		.gap = 7, .main_align = CENTER, .cross_align = END });
	Widget* first = row.text("first");
	Widget* middle = row.text("second");
	Widget* last = row.text("last");
	first.set_visible(false);
	last.set_visible(false);
	view.update();
	alignment_rect(middle.bounds, 36, 49, 29, 21);
	test::eq(first.visible.empty() && last.visible.empty(), true);
	first.set_visible(true);
	middle.set_visible(false);
	last.set_visible(true);
	view.update();
	alignment_rect(first.bounds, 33, 57, 17, 13);
	alignment_rect(last.bounds, 57, 61, 11, 9);
	test::eq(middle.visible.empty(), true);
	first.set_visible(false);
	last.set_visible(false);
	view.update();
	test::eq(first.visible.empty() && middle.visible.empty() && last.visible.empty(), true);
	middle.set_visible(true);
	view.update();
	alignment_rect(middle.bounds, 36, 49, 29, 21);
}

fn void alignment_empty_containers_and_hidden_only_content_keep_intrinsic_size() @test
{
	View view;
	defer view.free();
	view.resize(100, 100);
	view.set_root_spacing(0, 0);
	view.set_root_alignment(END, END);
	view.set_measurer(&alignment_metrics);
	Widget* column = view.column({ .padding = 4, .gap = LAYOUT_LIMIT,
		.main_align = CENTER, .cross_align = STRETCH });
	view.update();
	alignment_size(column.desired, 8, 8);
	alignment_rect(column.bounds, 92, 92, 8, 8);
	Widget* first = column.text("first");
	Widget* second = column.text("second");
	first.set_visible(false);
	second.set_visible(false);
	view.update();
	alignment_size(column.desired, 8, 8);
	alignment_rect(column.bounds, 92, 92, 8, 8);
	first.set_visible(true);
	view.update();
	alignment_size(column.desired, 25, 21);
	alignment_rect(column.bounds, 75, 79, 25, 21);
	alignment_rect(first.bounds, 79, 83, 17, 13);
	test::eq(second.visible.empty(), true);
}

fn void alignment_zero_sized_visible_children_still_separate_gaps() @test
{
	for (int orientation = 0; orientation < 2; orientation++)
	{
		View view;
		defer view.free();
		view.resize(20, 20);
		view.set_root_spacing(0, 0);
		Layout layout = { .width = 20, .height = 20, .gap = 5,
			.main_align = END, .cross_align = STRETCH };
		Widget* container = orientation == 0 ? view.row(layout) : view.column(layout);
		Widget* first = container.column();
		Widget* middle = container.text();
		middle.set_layout({ .width = 4, .height = 4 });
		Widget* last = container.row();
		view.update();
		alignment_size(first.desired, 0, 0);
		alignment_size(last.desired, 0, 0);
		if (orientation == 0)
		{
			alignment_rect(first.bounds, 6, 0, 0, 20);
			alignment_rect(middle.bounds, 11, 0, 4, 4);
			alignment_rect(last.bounds, 20, 0, 0, 20);
		}
		else
		{
			alignment_rect(first.bounds, 0, 6, 20, 0);
			alignment_rect(middle.bounds, 0, 11, 4, 4);
			alignment_rect(last.bounds, 0, 20, 20, 0);
		}
		first.set_visible(false);
		last.set_visible(false);
		view.update();
		alignment_rect(middle.bounds, orientation == 0 ? 16 : 0,
			orientation == 0 ? 0 : 16, 4, 4);
	}
}

fn void alignment_overflow_stays_at_start_and_clips_on_both_axes() @test
{
	Alignment[3] main_values = { START, CENTER, END };
	Alignment[4] cross_values = { START, CENTER, END, STRETCH };
	int[4] small_cross = { 3, 8, 14, 3 };
	for (int orientation = 0; orientation < 2; orientation++)
	{
		View view;
		defer view.free();
		view.resize(100, 100);
		view.set_root_spacing(0, 0);
		Layout layout = { .width = orientation == 0 ? 50 : 20,
			.height = orientation == 0 ? 20 : 50, .padding = 3, .gap = 7 };
		Widget* container = orientation == 0 ? view.row(layout) : view.column(layout);
		Widget* large = container.text();
		Widget* small = container.text();
		large.set_layout({ .width = orientation == 0 ? 60 : 40,
			.height = orientation == 0 ? 40 : 60 });
		small.set_layout({ .width = orientation == 0 ? 10 : 3,
			.height = orientation == 0 ? 3 : 10 });
		foreach (main_value : main_values)
		{
			foreach (cross_index, cross_value : cross_values)
			{
				layout.main_align = main_value;
				layout.cross_align = cross_value;
				container.set_layout(layout);
				view.update();
				if (orientation == 0)
				{
					alignment_rect(large.bounds, 3, 3, 60, 14);
					alignment_rect(large.visible, 3, 3, 44, 14);
					alignment_rect(small.bounds, 70, small_cross[cross_index], 10, 3);
				}
				else
				{
					alignment_rect(large.bounds, 3, 3, 14, 60);
					alignment_rect(large.visible, 3, 3, 14, 44);
					alignment_rect(small.bounds, small_cross[cross_index], 70, 3, 10);
				}
				test::eq(small.visible.empty(), true);
			}
		}
	}
}

fn void alignment_zero_available_space_and_oversized_root_padding() @test
{
	for (int orientation = 0; orientation < 2; orientation++)
	{
		View view;
		defer view.free();
		view.resize(100, 100);
		view.set_root_spacing(0, 0);
		view.set_measurer(&alignment_metrics);
		Layout layout = { .width = 31, .height = 19, .padding = 20,
			.main_align = END, .cross_align = STRETCH };
		Widget* container = orientation == 0 ? view.row(layout) : view.column(layout);
		Widget* child = container.text("first");
		view.update();
		alignment_rect(child.bounds, 20, 20, orientation == 0 ? 17 : 0,
			orientation == 0 ? 0 : 13);
		test::eq(child.visible.empty(), true);
		alignment_size(child.desired, 17, 13);
		view.set_root_spacing(100, 0);
		view.set_root_alignment(END, END);
		view.update();
		alignment_rect(container.bounds, 100, 100, 0, 19);
		test::eq(container.visible.empty() && child.visible.empty(), true);
		view.resize(0, 0);
		view.update();
		test::eq(view.take_damage().empty(), true);
	}
}

fn void alignment_center_rounding_uses_the_lower_pixel() @test
{
	View view;
	defer view.free();
	view.resize(10, 10);
	view.set_root_spacing(0, 0);
	view.set_root_alignment(CENTER, CENTER);
	Widget* child = view.text();
	child.set_layout({ .width = 3, .height = 5 });
	view.update();
	alignment_rect(child.bounds, 3, 2, 3, 5);
	view.resize(11, 11);
	view.update();
	alignment_rect(child.bounds, 4, 3, 3, 5);
	view.resize(12, 12);
	view.update();
	alignment_rect(child.bounds, 4, 3, 3, 5);
	view.resize(2, 4);
	view.update();
	alignment_rect(child.bounds, 0, 0, 2, 5);
	alignment_rect(child.visible, 0, 0, 2, 4);
}

fn void alignment_default_and_explicit_start_geometry_match() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_measurer(&alignment_metrics);
	Widget* row = view.row({ .padding = 2, .gap = 3 });
	Widget* first = row.text("first");
	Widget* second = row.text("second");
	Widget* footer = view.text("footer");
	view.update();
	alignment_rect(row.bounds, 16, 16, 53, 25);
	alignment_rect(first.bounds, 18, 18, 17, 13);
	alignment_rect(second.bounds, 38, 18, 29, 21);
	alignment_rect(footer.bounds, 16, 49, 11, 9);
	view.take_damage();
	test::eq(row.set_layout({ .padding = 2, .gap = 3, .main_align = START, .cross_align = START }), true);
	test::eq(view.set_root_alignment(START, START), true);
	view.update();
	alignment_rect(first.bounds, 18, 18, 17, 13);
	alignment_rect(second.bounds, 38, 18, 29, 21);
	alignment_rect(footer.bounds, 16, 49, 11, 9);
	test::eq(view.take_damage().empty(), true);
	// The original eight positional fields keep their order; C3 requires
	// positional initializers to supply alignment and fill fields as well.
	Layout positional = { 10, 20, 1, 2, 30, 40, 3, 4, START, START, false };
	test::eq(positional.main_align, Alignment.START);
	test::eq(positional.cross_align, Alignment.START);
	test::eq(positional.valid(), true);
}

fn void alignment_limit_sizes_saturate_without_wrapping() @test
{
	View view;
	defer view.free();
	view.resize(LAYOUT_LIMIT, LAYOUT_LIMIT);
	view.set_root_spacing(0, 0);
	view.set_root_alignment(END, STRETCH);
	Widget* row = view.row({ .height = LAYOUT_LIMIT, .gap = LAYOUT_LIMIT,
		.main_align = END, .cross_align = STRETCH });
	Widget* first = row.text();
	Widget* last = row.text();
	first.set_layout({ .width = LAYOUT_LIMIT, .max_height = LAYOUT_LIMIT });
	last.set_layout({ .width = LAYOUT_LIMIT, .min_height = LAYOUT_LIMIT });
	view.update();
	alignment_size(row.desired, LAYOUT_LIMIT, LAYOUT_LIMIT);
	alignment_rect(first.bounds, 0, 0, LAYOUT_LIMIT, LAYOUT_LIMIT);
	alignment_rect(last.bounds, LAYOUT_LIMIT, 0, LAYOUT_LIMIT, LAYOUT_LIMIT);
	test::eq(last.visible.empty(), true);
	row.set_layout({ .height = LAYOUT_LIMIT, .padding = LAYOUT_LIMIT,
		.gap = LAYOUT_LIMIT, .main_align = CENTER, .cross_align = END });
	view.update();
	alignment_rect(first.bounds, LAYOUT_LIMIT, LAYOUT_LIMIT, LAYOUT_LIMIT, 0);
	alignment_rect(last.bounds, LAYOUT_LIMIT, LAYOUT_LIMIT, LAYOUT_LIMIT, 0);
	test::eq(first.visible.empty() && last.visible.empty(), true);
}
