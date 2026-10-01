module ui;
import std::core::test;

// A repeatable mutation stream checks incremental invalidation against a full
// measure/place pass. Coordinate expectations live in the geometry tests; this
// catches stale caches across combinations of hiding, sizing and reparenting.
fn uint alignment_random(uint* seed) @private
{
	*seed = (uint)(((ulong)*seed * 48271) % 2147483647);
	return *seed;
}

struct AlignmentSnapshot @private
{
	Rect bounds;
	Rect visible;
	Size desired;
}

fn void alignment_incremental_mutations_match_full_layout() @test
{
	View view;
	defer view.free();
	State{int} count;
	view.resize(240, 180);
	view.set_root_alignment(CENTER, STRETCH);
	Widget* first = view.column({ .padding = 3, .gap = 5, .cross_align = STRETCH });
	Widget* second = view.row({ .height = 75, .padding = 4, .gap = 7, .cross_align = CENTER });
	Widget* branch = first.row({ .padding = 2, .gap = 3, .main_align = END });
	Widget* nested = second.column({ .width = 90, .cross_align = STRETCH });
	Widget* label = branch.text().@text(&count, "Value: %s");
	Widget* button = branch.button("Action");
	Widget* check = nested.checkbox("Check");
	Widget* footer = first.text("Footer");
	Widget*[8] widgets = { first, second, branch, nested, label, button, check, footer };
	Alignment[4] alignments = { START, CENTER, END, STRETCH };
	uint seed = 173;
	for (int step = 0; step < 384; step++)
	{
		// Coalesce several mutations before the incremental flush, including
		// pending reactive edits while a subtree is hidden or moved.
		for (int edit = 0; edit < 3; edit++)
		{
			Widget* target = widgets[alignment_random(&seed) % widgets.len];
			Layout layout = target.layout;
			switch (alignment_random(&seed) % 10)
			{
				case 0:
					if (target.is_container())
					{
						layout.main_align = alignments[alignment_random(&seed) % 3];
						layout.cross_align = alignments[alignment_random(&seed) % 4];
						test::eq(target.set_layout(layout), true);
					}
				case 1:
					layout.width = alignment_random(&seed) % 2 ? 0 : (int)(alignment_random(&seed) % 160);
					layout.height = alignment_random(&seed) % 2 ? 0 : (int)(alignment_random(&seed) % 100);
					test::eq(target.set_layout(layout), true);
				case 2:
					layout.max_width = (int)(alignment_random(&seed) % 120);
					layout.max_height = (int)(alignment_random(&seed) % 70);
					test::eq(target.set_layout(layout), true);
				case 3:
					target.set_visible(target.hidden);
				case 4:
					view.resize((int)(alignment_random(&seed) % 320), (int)(alignment_random(&seed) % 220));
				case 5:
					view.set_root_alignment(alignments[alignment_random(&seed) % 3], alignments[alignment_random(&seed) % 4]);
					view.set_root_spacing((int)(alignment_random(&seed) % 20), (int)(alignment_random(&seed) % 12));
				case 6:
					count.set((int)(alignment_random(&seed) % 100000));
				case 7:
					// Invalid cycles are harmless, valid moves preserve all handles.
					widgets[alignment_random(&seed) % 4].append(target);
				case 8:
					if (target.is_container())
					{
						layout.padding = (int)(alignment_random(&seed) % 15);
						layout.gap = (int)(alignment_random(&seed) % 10);
						test::eq(target.set_layout(layout), true);
					}
				case 9:
					layout.fill = !layout.fill;
					test::eq(target.set_layout(layout), true);
			}
		}
		view.update();
		AlignmentSnapshot[8] snapshots;
		foreach (index, widget : widgets)
		{
			snapshots[index] = { widget.bounds, widget.visible, widget.desired };
			widget.request_size();
			widget.request_layout();
		}
		view.layout_dirty = true;
		view.update();
		foreach (index, widget : widgets)
		{
			AlignmentSnapshot before = snapshots[index];
			test::eq(rect_equal(widget.bounds, before.bounds), true);
			test::eq(rect_equal(widget.visible, before.visible), true);
			test::eq(widget.desired.width, before.desired.width);
			test::eq(widget.desired.height, before.desired.height);
		}
	}
}
