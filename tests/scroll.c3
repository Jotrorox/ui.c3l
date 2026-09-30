module ui;
import std::core::test;

fn void scroll_rect(Rect actual, int x, int y, int width, int height) @private
{
	test::eq(actual.x, x);
	test::eq(actual.y, y);
	test::eq(actual.width, width);
	test::eq(actual.height, height);
}

fn void scrolling_extent_padding_gaps_and_clamped_programmatic_offsets() @test
{
	View view;
	defer view.free();
	view.resize(240, 160);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 60, .padding = 5, .gap = 3 });
	Widget* first = panel.button("a");
	Widget* second = panel.button("b");
	Widget* third = panel.button("c");
	test::eq(panel.scroll_extent(), 52); // 3 * 32 + 2 * 3 - 50.
	test::eq(panel.scroll_offset(), 0);
	scroll_rect(panel.bounds, 0, 0, 100, 60);
	scroll_rect(first.bounds, 5, 5, 32, 32);
	scroll_rect(second.visible, 5, 40, 32, 15);
	test::eq(third.visible.empty(), true);
	test::eq(panel.scroll_to(41), true);
	test::eq(panel.scroll_offset(), 41);
	scroll_rect(first.bounds, 5, -36, 32, 32);
	test::eq(first.visible.empty(), true);
	scroll_rect(second.bounds, 5, -1, 32, 32);
	scroll_rect(second.visible, 5, 5, 32, 26);
	scroll_rect(third.visible, 5, 34, 32, 21);
	test::eq(view.hit_test(6, 4) == null, true); // Stationary top padding.
	test::eq(view.hit_test(6, 5), second);
	test::eq(view.hit_test(6, 55) == null, true); // Stationary bottom padding.
	test::eq(panel.scroll_to(1000000), true);
	test::eq(panel.scroll_offset(), 52);
	scroll_rect(third.visible, 5, 23, 32, 32);
	test::eq(panel.scroll_by(-20), true);
	test::eq(panel.scroll_offset(), 32);
	test::eq(panel.scroll_to(-100), true);
	test::eq(panel.scroll_offset(), 0);
	test::eq(panel.scroll_by(-2147483647 - 1), true);
	test::eq(panel.scroll_offset(), 0);
	test::eq(panel.scroll_by(2147483647), true);
	test::eq(panel.scroll_offset(), 52);
	test::eq(panel.scroll_by(2147483647), true); // Addition must not overflow.
	test::eq(panel.scroll_offset(), 52);
}

fn void scrolling_intrinsic_size_maximum_and_unchanged_ordinary_overflow() @test
{
	View view;
	defer view.free();
	view.resize(300, 300);
	view.set_root_spacing(0, 0);
	Widget* natural = view.scroll_column({ .padding = 3, .gap = 2 });
	natural.text("a");
	natural.text("b");
	Widget* bounded = view.scroll_column({ .max_height = 30, .padding = 3, .gap = 2 });
	bounded.text("a");
	bounded.text("b");
	Widget* ordinary = view.column({ .height = 16 });
	ordinary.text("a");
	Widget* clipped = ordinary.button("b");
	view.update();
	test::eq(natural.desired.width, 14);
	test::eq(natural.desired.height, 40);
	test::eq(natural.scroll_extent(), 0);
	test::eq(bounded.desired.height, 30);
	test::eq(bounded.scroll_extent(), 10);
	test::eq(ordinary.bounds.height, 16);
	test::eq(clipped.visible.empty(), true);
	test::eq(ordinary.scroll_to(12), false);
	test::eq(ordinary.scroll_by(12), false);
	test::eq(clipped.scroll_to(12), false);
	test::eq(clipped.scroll_by(12), false);
	test::eq(clipped.scroll_offset(), 0);
	test::eq(ordinary.scroll_extent(), 0);
	test::eq(ordinary.scroll_offset(), 0);
	view.focus_next();
	test::eq(view.focused == null, true); // Root and ordinary columns do not scroll.
}

fn void scrolling_short_content_alignment_and_overflow_anchor() @test
{
	Alignment[3] mains = { START, CENTER, END };
	Alignment[4] crosses = { START, CENTER, END, STRETCH };
	int[3] short_y = { 5, 26, 47 };
	int[4] short_x = { 5, 42, 79, 5 };
	foreach (main_index, main : mains)
	{
		foreach (cross_index, cross : crosses)
		{
			View view;
			defer view.free();
			view.resize(200, 200);
			view.set_root_spacing(0, 0);
			Widget* panel = view.scroll_column({ .width = 100, .height = 100,
				.padding = 5, .gap = 7, .main_align = main, .cross_align = cross });
			Widget* item = panel.text("ab");
			item.set_layout({ .height = 48 });
			view.update();
			scroll_rect(item.bounds, short_x[cross_index], short_y[main_index],
				cross == STRETCH ? 90 : 16, 48);
			test::eq(panel.scroll_extent(), 0);
			test::eq(panel.scroll_to(10), true);
			test::eq(panel.scroll_offset(), 0);
			Widget* overflow = panel.text("cd");
			overflow.set_layout({ .height = 60 });
			view.update();
			test::eq(item.bounds.y, 5);
			test::eq(overflow.bounds.y, 60);
			test::eq(panel.scroll_extent(), 25);
			panel.scroll_to(25);
			view.update();
			test::eq(item.bounds.y, -20);
			test::eq(overflow.bounds.y, 35);
		}
	}
}

fn void scrolling_cross_axis_stretch_constraints_and_explicit_sizes() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 40,
		.padding = 5, .cross_align = STRETCH });
	Widget* automatic = panel.text("a");
	Widget* capped = panel.text("b");
	capped.set_layout({ .max_width = 40 });
	Widget* fixed = panel.text("c");
	fixed.set_layout({ .width = 25 });
	Widget* minimum = panel.text("d");
	minimum.set_layout({ .min_width = 120 });
	view.update();
	test::eq(automatic.bounds.width, 90);
	test::eq(capped.bounds.width, 40);
	test::eq(fixed.bounds.width, 25);
	test::eq(minimum.desired.width, 120);
	test::eq(minimum.bounds.width, 90);
	test::eq(panel.scroll_extent(), 34);
	panel.scroll_to(34);
	view.update();
	scroll_rect(minimum.visible, 5, 19, 90, 16);
	test::eq(minimum.bounds.height, 16);
}

fn void scrolling_empty_hidden_and_zero_available_content() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 30, .height = 8, .padding = 4, .gap = 9 });
	test::eq(panel.scroll_extent(), 0);
	Widget* first = panel.text("a");
	Widget* second = panel.text("b");
	test::eq(panel.scroll_extent(), 41); // Empty viewport still has real content.
	panel.scroll_to(41);
	view.update();
	test::eq(first.visible.empty() && second.visible.empty(), true);
	view.focus_next();
	test::eq(view.focused == null, true);
	first.set_visible(false);
	test::eq(panel.scroll_extent(), 16); // No gap for one remaining child.
	test::eq(panel.scroll_offset(), 16);
	second.set_visible(false);
	test::eq(panel.scroll_extent(), 0);
	test::eq(panel.scroll_offset(), 0);
	first.set_visible(true);
	view.resize(0, 0);
	view.update();
	test::eq(panel.visible.empty() && first.visible.empty(), true);
	test::eq(view.take_damage().empty(), true);
	test::eq(view.scroll_wheel(0, 0, 20), false);
}

fn void scrolling_extent_exceeds_dimension_limit_and_retains_negative_coordinates() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 100, .gap = 7 });
	Widget* first = panel.column({ .width = 100, .height = LAYOUT_LIMIT });
	Widget* second = panel.column({ .width = 100, .height = LAYOUT_LIMIT });
	Widget* last = second.button("end");
	test::eq(panel.scroll_extent(), 130977);
	test::eq(panel.desired.height, 100);
	test::eq(first.bounds.y, 0);
	test::eq(second.bounds.y, 65542); // Coordinates do not use dimension saturation.
	panel.scroll_to(65542);
	view.update();
	test::eq(first.bounds.y, -65542);
	test::eq(second.bounds.y, 0);
	test::eq(view.hit_test(1, 1), last);
	scroll_rect(last.visible, 0, 0, 48, 32);
	panel.scroll_to(2147483647);
	view.update();
	test::eq(panel.scroll_offset(), 130977);
	test::eq(second.bounds.y, -65435);
	scroll_rect(second.visible, 0, 0, 100, 100);
	test::eq(last.visible.empty(), true);
}

struct ScrollMeasureProbe @private
{
	State{bool} tall;
	int evaluations;
	int measurements;
	int texts;
	Rect clip;
	Rect cleared;
	Rect painted_clip;
}

fn Size scroll_measure(void* context, String text) @private
{
	ScrollMeasureProbe* probe = context;
	probe.measurements++;
	return { (int)text.len * 8, text == "tall" ? 72 : 16 };
}

fn String scroll_bound_label(void* context) @private
{
	ScrollMeasureProbe* probe = context;
	probe.evaluations++;
	return probe.tall.get() ? "tall" : "short";
}

fn void? scroll_paint_clip(void* context, Rect rect) @private
{
	ScrollMeasureProbe* probe = context;
	probe.clip = rect;
}

fn void? scroll_paint_fill(void* context, Rect rect, Ink ink) @private
{
	ScrollMeasureProbe* probe = context;
	if (ink == PAPER) probe.cleared = rect;
}

fn void? scroll_paint_text(void* context, String text, int x, int y, Ink ink) @private
{
	ScrollMeasureProbe* probe = context;
	probe.texts++;
	probe.painted_clip = probe.clip;
}

fn void scrolling_reuses_measurements_and_damages_exposed_content() @test
{
	ScrollMeasureProbe probe;
	View view;
	defer view.free();
	view.resize(200, 160);
	view.set_root_spacing(0, 0);
	view.set_measurer(&scroll_measure, &probe);
	Widget* panel = view.scroll_column({ .width = 80, .height = 45, .padding = 5, .gap = 25 });
	Widget* first = panel.text();
	first.bind(&scroll_bound_label, &probe);
	Widget* second = panel.text("b");
	view.update();
	test::eq(panel.scroll_extent(), 22);
	test::eq(probe.measurements, 2);
	test::eq(probe.evaluations, 1);
	Rect old_visible = first.visible;
	view.take_damage();
	panel.scroll_to(22);
	view.update();
	test::eq(first.visible.empty(), true);
	scroll_rect(second.visible, 5, 24, 8, 16);
	test::eq(probe.measurements, 2);
	test::eq(probe.evaluations, 1);
	Rect damage = view.take_damage();
	test::eq(rect_equal(damage.intersect(old_visible), old_visible), true);
	test::eq(rect_equal(damage.intersect(second.visible), second.visible), true);
	Renderer renderer = { &probe, &scroll_paint_fill, &scroll_paint_text, &scroll_paint_clip };
	view.paint(&renderer, damage)!!;
	test::eq(probe.texts, 1);
	test::eq(rect_equal(probe.cleared, damage), true);
	test::eq(rect_equal(probe.painted_clip, second.visible), true);
	panel.scroll_to(22);
	panel.scroll_by(0);
	view.update();
	test::eq(view.take_damage().empty(), true);
	Layout alignment = panel.layout;
	alignment.main_align = END;
	alignment.cross_align = END;
	panel.set_layout(alignment);
	view.update();
	test::eq(probe.measurements, 2);
	test::eq(probe.evaluations, 1);
}

fn void scrolling_flushes_reactive_growth_shrinkage_resize_and_hidden_restore() @test
{
	ScrollMeasureProbe probe;
	View view;
	defer view.free();
	view.resize(200, 150);
	view.set_root_spacing(0, 0);
	view.set_measurer(&scroll_measure, &probe);
	Widget* row = view.row({ .width = 100, .height = 70, .cross_align = STRETCH });
	Widget* panel = row.scroll_column({ .width = 100, .padding = 5, .gap = 4 });
	Widget* label = panel.text();
	label.bind(&scroll_bound_label, &probe);
	Widget* footer = panel.button("end");
	test::eq(panel.scroll_extent(), 0);
	probe.tall.set(true);
	test::eq(panel.scroll_extent(), 48); // Getter flushes bindings and layout.
	panel.scroll_to(48);
	test::eq(panel.scroll_offset(), 48);
	test::eq(probe.evaluations, 2);
	test::eq(probe.measurements, 3);
	row.set_layout({ .width = 100, .height = 50, .cross_align = STRETCH });
	test::eq(panel.scroll_extent(), 68);
	test::eq(panel.scroll_offset(), 48); // Growing extent does not move offset.
	row.set_layout({ .width = 100, .height = 90, .cross_align = STRETCH });
	test::eq(panel.scroll_extent(), 28);
	test::eq(panel.scroll_offset(), 28);
	panel.set_visible(false);
	view.update();
	test::eq(panel.scroll_offset(), 28);
	probe.tall.set(false);
	view.update();
	test::eq(probe.measurements, 3); // Hidden metrics remain deferred.
	panel.set_visible(true);
	test::eq(panel.scroll_extent(), 0);
	test::eq(panel.scroll_offset(), 0);
	test::eq(probe.measurements, 4);
	test::eq(footer.visible.empty(), false);
}

fn void scrolling_clamps_after_child_hiding_removal_and_subtree_reparenting() @test
{
	View view;
	defer view.free();
	view.resize(300, 200);
	view.set_root_spacing(0, 0);
	Widget* row = view.row({ .gap = 20 });
	Widget* from = row.scroll_column({ .width = 100, .height = 48, .gap = 4 });
	Widget* to = row.scroll_column({ .width = 100, .height = 48, .gap = 4 });
	Widget* first = from.button("a");
	Widget* branch = from.column();
	Widget* descendant = branch.button("b");
	Widget* last = from.button("c");
	test::eq(from.scroll_extent(), 56);
	from.scroll_to(56);
	branch.set_visible(false);
	test::eq(from.scroll_extent(), 20);
	test::eq(from.scroll_offset(), 20);
	branch.set_visible(true);
	test::eq(from.scroll_extent(), 56);
	test::eq(from.scroll_offset(), 20);
	from.scroll_to(56);
	test::eq(to.append(branch), true);
	test::eq(from.scroll_extent(), 20);
	test::eq(from.scroll_offset(), 20);
	test::eq(to.scroll_extent(), 0);
	test::eq(descendant.parent, branch);
	test::eq(descendant.owner, &view);
	scroll_rect(descendant.visible, 120, 0, 32, 32);
	last.remove();
	test::eq(from.scroll_extent(), 0);
	test::eq(from.scroll_offset(), 0);
	test::eq(from.first, first);
	test::eq(from.last, first);
	test::eq(from.append(branch), true);
	test::eq(from.scroll_extent(), 20);
	test::eq(to.scroll_extent(), 0);
	test::eq(descendant.parent, branch);
	test::eq(descendant.owner, &view);
}

fn void scrolling_trailing_body_and_invalid_layout_leave_state_intact() @test
{
	View view;
	defer view.free();
	view.resize(200, 200);
	Widget* nested;
	Widget* panel = view.@scroll_column({ .height = 30, .padding = 2 }; Widget* column)
	{
		column.text("heading");
		nested = column.@scroll_column({ .height = 20 }; Widget* inner)
		{
			inner.button("a");
			inner.button("b");
		};
	};
	test::eq(panel.is_container(), true);
	test::eq(nested.parent, panel);
	test::eq(nested.scroll_extent(), 44);
	test::eq(panel.scroll_extent(), 10);
	panel.scroll_to(7);
	test::eq(panel.set_layout({ .height = -1 }), false);
	test::eq(panel.set_layout({ .gap = LAYOUT_LIMIT + 1 }), false);
	test::eq(panel.set_layout({ .min_height = 40, .max_height = 20 }), false);
	test::eq(panel.set_layout({ .main_align = STRETCH }), false);
	test::eq(panel.layout.height, 30);
	test::eq(panel.layout.padding, 2);
	test::eq(panel.scroll_offset(), 7);
	test::eq(panel.scroll_extent(), 10);
}

struct ScrollSnapshot @private
{
	Rect bounds;
	Rect visible;
	Size desired;
	int offset;
	int extent;
}

fn uint scroll_random(uint* seed) @private
{
	*seed = (uint)(((ulong)*seed * 48271) % 2147483647);
	return *seed;
}

fn void scrolling_incremental_mutations_match_full_measurement_and_placement() @test
{
	View view;
	defer view.free();
	ScrollMeasureProbe probe;
	view.resize(240, 220);
	view.set_measurer(&scroll_measure, &probe);
	Widget* first = view.scroll_column({ .width = 180, .height = 80, .padding = 3, .gap = 5 });
	Widget* second = view.scroll_column({ .width = 180, .height = 90, .padding = 4, .gap = 7 });
	Widget* branch = first.column({ .padding = 2, .gap = 3 });
	Widget* nested = second.scroll_column({ .height = 40, .cross_align = STRETCH });
	Widget* label = branch.text();
	label.bind(&scroll_bound_label, &probe);
	Widget* button = branch.button("action");
	Widget* check = nested.checkbox("check");
	Widget* footer = first.text("footer");
	Widget*[8] widgets = { first, second, branch, nested, label, button, check, footer };
	Alignment[4] alignments = { START, CENTER, END, STRETCH };
	uint seed = 761;
	for (int step = 0; step < 512; step++)
	{
		for (int edit = 0; edit < 3; edit++)
		{
			Widget* target = widgets[scroll_random(&seed) % widgets.len];
			Layout layout = target.layout;
			switch (scroll_random(&seed) % 12)
			{
				case 0:
					if (target.is_container())
					{
						layout.main_align = alignments[scroll_random(&seed) % 3];
						layout.cross_align = alignments[scroll_random(&seed) % 4];
						test::eq(target.set_layout(layout), true);
					}
				case 1:
					layout.width = scroll_random(&seed) % 2 ? 0 : (int)(scroll_random(&seed) % 160);
					layout.height = scroll_random(&seed) % 2 ? 0 : (int)(scroll_random(&seed) % 100);
					test::eq(target.set_layout(layout), true);
				case 2:
					layout.max_width = (int)(scroll_random(&seed) % 120);
					layout.max_height = (int)(scroll_random(&seed) % 70);
					test::eq(target.set_layout(layout), true);
				case 3:
					target.set_visible(target.hidden);
				case 4:
					view.resize((int)(scroll_random(&seed) % 320), (int)(scroll_random(&seed) % 220));
				case 5:
					view.set_root_alignment(alignments[scroll_random(&seed) % 3], alignments[scroll_random(&seed) % 4]);
					view.set_root_spacing((int)(scroll_random(&seed) % 20), (int)(scroll_random(&seed) % 12));
				case 6:
					probe.tall.set(!probe.tall.get());
				case 7:
					widgets[scroll_random(&seed) % 4].append(target);
				case 8:
					if (target.is_container())
					{
						layout.padding = (int)(scroll_random(&seed) % 15);
						layout.gap = (int)(scroll_random(&seed) % 10);
						test::eq(target.set_layout(layout), true);
					}
				case 9:
					target.scroll_to((int)(scroll_random(&seed) % 220) - 20);
				case 10:
					target.scroll_by((int)(scroll_random(&seed) % 160) - 80);
				case 11:
					view.focus_next(reverse: scroll_random(&seed) % 2 != 0);
			}
		}
		view.update();
		ScrollSnapshot[8] snapshots;
		foreach (index, widget : widgets)
		{
			snapshots[index] = { widget.bounds, widget.visible, widget.desired,
				widget.scroll_offset(), widget.scroll_extent() };
		}
		foreach (widget : widgets)
		{
			widget.request_size();
			widget.request_layout();
		}
		view.layout_dirty = true;
		view.update();
		foreach (index, widget : widgets)
		{
			ScrollSnapshot before = snapshots[index];
			test::eq(rect_equal(widget.bounds, before.bounds), true);
			test::eq(rect_equal(widget.visible, before.visible), true);
			test::eq(widget.desired.width, before.desired.width);
			test::eq(widget.desired.height, before.desired.height);
			test::eq(widget.scroll_offset(), before.offset);
			test::eq(widget.scroll_extent(), before.extent);
		}
	}
}
