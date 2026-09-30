module ui;
import std::core::test;

fn void scrollbar_saturated_content_keeps_thumb_and_drag_arithmetic_bounded() @test
{
	View view;
	defer view.free();
	view.set_root_spacing(0, 0);
	view.resize(100, 101);
	Widget* panel = view.scroll_column({ .width = 100, .height = 101 });
	panel.set_scrollbar();
	// Actual measured content crosses the documented signed-coordinate limit.
	for (int index = 0; index < 16386; index++) panel.column({ .height = LAYOUT_LIMIT });
	view.update();
	test::eq(panel.content_height, COORD_LIMIT);
	test::eq(panel.scroll_extent(), COORD_LIMIT - 101);
	test::eq(panel.scroll_thumb.height, SCROLLBAR_MIN_THUMB);
	panel.scroll_to(panel.scroll_extent());
	test::eq(panel.scroll_thumb.y, 85);
	view.pointer_down(90, 90);
	view.pointer_move(int::min, int::min);
	test::eq(panel.scroll_offset(), 0);
	view.pointer_move(int::max, int::max);
	test::eq(panel.scroll_offset(), COORD_LIMIT - 101);
	view.pointer_up(int::max, int::max);
	test::eq(panel.scroll_thumb.y + panel.scroll_thumb.height, 101);
	Rect damage = view.take_damage();
	test::eq(damage.x, 0);
	test::eq(damage.y, 0);
	test::eq(damage.width, 100);
	test::eq(damage.height, 101);
}

struct ScrollbarSnapshot @private
{
	Rect bounds;
	Rect visible;
	Size desired;
	int offset;
	int extent;
	Rect track;
	Rect thumb;
}

fn uint scrollbar_random(uint* seed) @private
{
	*seed = (uint)(((ulong)*seed * 48271) % 2147483647);
	return *seed;
}

fn void scrollbar_incremental_mutations_match_full_measurement_and_placement() @test
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
			Widget* target = widgets[scrollbar_random(&seed) % widgets.len];
			Layout layout = target.layout;
			switch (scrollbar_random(&seed) % 14)
			{
				case 0:
					if (target.is_container())
					{
						layout.main_align = alignments[scrollbar_random(&seed) % 3];
						layout.cross_align = alignments[scrollbar_random(&seed) % 4];
						test::eq(target.set_layout(layout), true);
					}
				case 1:
					layout.width = scrollbar_random(&seed) % 2 ? 0 : (int)(scrollbar_random(&seed) % 160);
					layout.height = scrollbar_random(&seed) % 2 ? 0 : (int)(scrollbar_random(&seed) % 100);
					test::eq(target.set_layout(layout), true);
				case 2:
					layout.max_width = (int)(scrollbar_random(&seed) % 120);
					layout.max_height = (int)(scrollbar_random(&seed) % 70);
					test::eq(target.set_layout(layout), true);
				case 3:
					target.set_visible(target.hidden);
				case 4:
					view.resize((int)(scrollbar_random(&seed) % 320), (int)(scrollbar_random(&seed) % 220));
				case 5:
					view.set_root_alignment(alignments[scrollbar_random(&seed) % 3], alignments[scrollbar_random(&seed) % 4]);
					view.set_root_spacing((int)(scrollbar_random(&seed) % 20), (int)(scrollbar_random(&seed) % 12));
				case 6:
					probe.tall.set(!probe.tall.get());
				case 7:
					widgets[scrollbar_random(&seed) % 4].append(target);
				case 8:
					if (target.is_container())
					{
						layout.padding = (int)(scrollbar_random(&seed) % 15);
						layout.gap = (int)(scrollbar_random(&seed) % 10);
						test::eq(target.set_layout(layout), true);
					}
				case 9:
					target.scroll_to((int)(scrollbar_random(&seed) % 220) - 20);
				case 10:
					target.scroll_by((int)(scrollbar_random(&seed) % 160) - 80);
				case 12:
					target.set_scrollbar(!target.scrollbar);
				case 13:
					view.pointer_down(target.scroll_thumb.x + 1, target.scroll_thumb.y + 1);
					view.pointer_move((int)(scrollbar_random(&seed) % 400) - 100, (int)(scrollbar_random(&seed) % 400) - 100);
					view.pointer_up(-1, -1);
				case 11:
					view.focus_next(reverse: scrollbar_random(&seed) % 2 != 0);
			}
		}
		view.update();
		ScrollbarSnapshot[8] snapshots;
		foreach (index, widget : widgets)
		{
			snapshots[index] = { widget.bounds, widget.visible, widget.desired,
				widget.scroll_offset(), widget.scroll_extent(), widget.scroll_track, widget.scroll_thumb };
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
			ScrollbarSnapshot before = snapshots[index];
			test::eq(rect_equal(widget.bounds, before.bounds), true);
			test::eq(rect_equal(widget.visible, before.visible), true);
			test::eq(widget.desired.width, before.desired.width);
			test::eq(widget.desired.height, before.desired.height);
			test::eq(widget.scroll_offset(), before.offset);
			test::eq(widget.scroll_extent(), before.extent);
			test::eq(rect_equal(widget.scroll_track, before.track), true);
			test::eq(rect_equal(widget.scroll_thumb, before.thumb), true);
		}
	}
}

// Check focus eligibility against actual geometry for every possible pair of
// offsets. This oracle does not use the reveal algorithm's projected clips.
fn void scrollbar_focus_matches_exhaustive_reachable_geometry() @test
{
	for (int sample = 0; sample < 96; sample++)
	{
		View view;
		defer view.free();
		view.set_root_spacing(0, 0);
		view.resize(40, 3 + sample % 13);
		Widget* outer = view.scroll_column({ .width = 30, .height = 4 + sample % 9, .padding = sample % 2 });
		outer.column({ .height = sample % 7 });
		Widget* ordinary = outer.column({ .height = sample % 3 ? 0 : 3 + sample % 6, .padding = sample % 2 });
		Widget* inner = ordinary.scroll_column({ .width = 20, .height = 3 + sample % 11, .padding = sample % 2 });
		outer.set_scrollbar(sample % 3 != 0);
		inner.set_scrollbar(sample % 3 != 1);
		inner.column({ .height = sample % 8 });
		Widget* target = inner.button("x");
		target.set_layout({ .width = 5, .height = 2 + sample % 3 });
		inner.column({ .height = sample % 6 });
		outer.column({ .height = sample % 5 });
		int outer_extent = outer.scroll_extent();
		int inner_extent = inner.scroll_extent();
		bool reachable;
		for (int first = 0; first <= outer_extent; first++)
		{
			outer.scroll_to(first);
			for (int second = 0; second <= inner_extent; second++)
			{
				inner.scroll_to(second);
				if (!target.visible.empty()) reachable = true;
			}
		}
		outer.scroll_to(outer_extent / 2);
		inner.scroll_to(inner_extent / 2);
		int before_outer = outer.scroll_offset();
		int before_inner = inner.scroll_offset();
		view.focus_next();
		test::eq(view.focused == target, reachable);
		if (reachable) { test::eq(target.visible.empty(), false); }
		else
		{
			test::eq(outer.scroll_offset(), before_outer);
			test::eq(inner.scroll_offset(), before_inner);
		}
	}
}
