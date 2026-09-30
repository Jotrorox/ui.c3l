module ui;
import std::core::test;

// Check focus eligibility against actual geometry for every possible pair of
// offsets. This oracle does not use the reveal algorithm's projected clips.
fn void scrolling_focus_matches_exhaustive_reachable_geometry() @test
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

fn void scrolling_rectangle_endpoints_use_wide_arithmetic() @test
{
	Rect positive = { int::max - 10, int::max - 10, 100, 100 };
	test::eq(positive.contains(int::max, int::max), true);
	Rect clipped = positive.intersect({ int::max - 5, int::max - 5, 20, 20 });
	test::eq(clipped.width, 20);
	test::eq(clipped.height, 20);
	Rect negative = { int::min, int::min, 100, 100 };
	test::eq(negative.intersect(positive).empty(), true);
	test::eq(negative.contains(int::min, int::min), true);
	View view;
	view.resize(100, 100);
	view.take_damage();
	view.invalidate(positive);
	view.invalidate(negative);
	test::eq(view.take_damage().empty(), true);
	view.invalidate({ -20, -20, 30, 30 });
	clipped = view.take_damage();
	test::eq(clipped.x, 0);
	test::eq(clipped.y, 0);
	test::eq(clipped.width, 10);
	test::eq(clipped.height, 10);
	view.free();
}
