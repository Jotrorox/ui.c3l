module ui;
import std::core::test;

struct ScrollbarProbe @private
{
	State{bool} tall;
	int evaluations;
	int measurements;
	Rect clip;
	Rect cleared;
	char[12000] pixels;
}

fn Size scrollbar_metrics(void* context, String text) @private
{
	ScrollbarProbe* probe = context;
	probe.measurements++;
	return { (int)text.len * 8, text == "tall" ? 200 : text == "short" ? 64 : 16 };
}

fn String scrollbar_label(void* context) @private
{
	ScrollbarProbe* probe = context;
	probe.evaluations++;
	return probe.tall.get() ? "tall" : "short";
}

fn void? scrollbar_paint_clip(void* context, Rect rect) @private
{
	ScrollbarProbe* probe = context;
	probe.clip = rect;
}

fn void? scrollbar_paint_fill(void* context, Rect rect, Ink ink) @private
{
	ScrollbarProbe* probe = context;
	if (ink == PAPER) probe.cleared = rect;
	Rect visible = rect.intersect(probe.clip).intersect({ 0, 0, 120, 100 });
	for (int y = visible.y; y < visible.y + visible.height; y++)
	{
		for (int x = visible.x; x < visible.x + visible.width; x++)
		{
			probe.pixels[y * 120 + x] = DEFAULT_THEME.colors[ink].red == 0 ? 1 : 0;
		}
	}
}

fn void? scrollbar_paint_text(void* context, String text, int x, int y, Ink ink) @private =>
	scrollbar_paint_fill(context, { x, y, (int)text.len * 8, 16 }, ink);

fn void scrollbar_covers(Rect damage, Rect target) @private
{
	test::eq(rect_equal(damage.intersect(target), target), true);
}

fn void scrollbar_drag_page_and_toggle_reuse_cached_text_and_binding_results() @test
{
	View view;
	defer view.free();
	ScrollbarProbe probe;
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	view.set_measurer(&scrollbar_metrics, &probe);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	Widget* label = panel.text();
	label.bind(&scrollbar_label, &probe);
	panel.text("footer");
	panel.set_scrollbar();
	view.update();
	test::eq(probe.measurements, 2);
	test::eq(probe.evaluations, 1);
	view.pointer_down(90, 10);
	for (int y = 10; y < 30; y++) view.pointer_move(90, y);
	view.pointer_up(90, 29);
	view.pointer_down(90, 0);
	view.pointer_up(90, 0);
	panel.scroll_to(5);
	panel.scroll_by(5);
	panel.set_scrollbar(false);
	view.update();
	panel.set_scrollbar();
	view.update();
	test::eq(probe.measurements, 2);
	test::eq(probe.evaluations, 1);
	Binding* binding = label.binding;
	probe.tall.set(true);
	probe.tall.set(false);
	probe.tall.set(true);
	view.update();
	test::eq(label.binding, binding);
	test::eq(probe.evaluations, 2);
	test::eq(probe.measurements, 3);
	test::eq(panel.scroll_extent(), 166);
}

fn void scrollbar_reactive_content_changes_cancel_before_stale_pointer_motion() @test
{
	for (int direction = 0; direction < 2; direction++)
	{
		View view;
		defer view.free();
		ScrollbarProbe probe;
		probe.tall.set(direction != 0);
		view.resize(200, 200);
		view.set_root_spacing(0, 0);
		view.set_measurer(&scrollbar_metrics, &probe);
		Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
		panel.set_scrollbar();
		Widget* label = panel.text();
		label.bind(&scrollbar_label, &probe);
		panel.text("footer");
		view.pointer_down(90, 10);
		test::eq(view.scroll_dragging, true);
		probe.tall.set(direction == 0);
		// pointer_move flushes the queued binding before using the old anchor.
		view.pointer_move(90, 40);
		test::eq(panel.scroll_offset(), 0);
		test::eq(panel.scroll_extent(), direction == 0 ? 166 : 30);
		test::eq(view.scroll_dragging, false);
		test::eq(view.scroll_pressed == null && view.scroll_press_active, true);
		test::eq(probe.evaluations, 2);
		test::eq(probe.measurements, 3);
		view.pointer_up(1, 1);
	}
}

fn void scrollbar_reactive_shrink_clears_track_and_clamps_offset_while_hidden() @test
{
	View view;
	defer view.free();
	ScrollbarProbe probe;
	probe.tall.set(true);
	view.resize(200, 200);
	view.set_root_spacing(0, 0);
	view.set_measurer(&scrollbar_metrics, &probe);
	Widget* panel = view.scroll_column({ .width = 100, .height = 100 });
	panel.set_scrollbar();
	Widget* label = panel.text();
	label.bind(&scrollbar_label, &probe);
	panel.scroll_to(100);
	test::eq(panel.scroll_thumb.y, 50);
	view.pointer_down(90, 60);
	panel.set_visible(false);
	probe.tall.set(false);
	view.update();
	test::eq(view.scroll_pressed == null, true);
	test::eq(panel.scroll_track.empty() && panel.scroll_thumb.empty(), true);
	test::eq(probe.measurements, 1);
	panel.set_visible(true);
	view.update();
	test::eq(panel.scroll_offset(), 0);
	test::eq(panel.scroll_extent(), 0);
	test::eq(panel.scroll_track.empty() && panel.scroll_thumb.empty(), true);
	test::eq(probe.measurements, 2);
	view.pointer_up(90, 60);
}

fn void scrollbar_old_new_content_and_thumb_damage_clear_exposed_pixels() @test
{
	View view;
	defer view.free();
	ScrollbarProbe probe;
	view.resize(120, 100);
	view.set_root_spacing(0, 0);
	Widget* panel = view.scroll_column({ .width = 100, .height = 50 });
	panel.set_scrollbar();
	Widget* first = panel.text("abcdefghijklmnop");
	first.set_layout({ .height = 50 });
	panel.text("b").set_layout({ .height = 50 });
	Renderer renderer = { &probe, &scrollbar_paint_fill, &scrollbar_paint_text, &scrollbar_paint_clip };
	view.update();
	view.paint(&renderer, view.take_damage())!!;
	test::eq(probe.pixels[10 * 120 + 90], (char)1);
	Rect old_thumb = panel.scroll_thumb;
	Rect old_content = first.visible;
	panel.scroll_to(50);
	Rect damage = view.take_damage();
	scrollbar_covers(damage, old_thumb);
	scrollbar_covers(damage, panel.scroll_thumb);
	scrollbar_covers(damage, old_content);
	scrollbar_covers(damage, panel.last.visible);
	view.paint(&renderer, damage)!!;
	test::eq(rect_equal(probe.cleared, damage), true);
	test::eq(probe.pixels[10 * 120 + 90], (char)0); // Vacated thumb interior.
	test::eq(probe.pixels[35 * 120 + 90], (char)1);
	test::eq(probe.pixels[10 * 120 + 88], (char)1); // Track border remains.
	test::eq(probe.pixels[10 * 120 + 40], (char)0); // Old wide text cleared.
	panel.scroll_to(50);
	panel.scroll_by(0);
	view.update();
	test::eq(view.take_damage().empty(), true);
	panel.set_scrollbar(false);
	view.update();
	view.paint(&renderer, view.take_damage())!!;
	test::eq(probe.pixels[35 * 120 + 90], (char)0);
	test::eq(probe.pixels[10 * 120 + 88], (char)0);
}

fn void scrollbar_renderer_clips_track_thumb_and_descendants_through_ancestors() @test
{
	View view;
	defer view.free();
	ScrollbarProbe probe;
	view.resize(120, 100);
	view.set_root_spacing(0, 0);
	Widget* ancestor = view.column({ .width = 100, .height = 25 });
	Widget* panel = ancestor.scroll_column({ .width = 100, .height = 100 });
	panel.set_scrollbar();
	Widget* label = panel.text("abcdefghijklmnopqrst");
	label.set_layout({ .height = 400 });
	view.update();
	Renderer renderer = { &probe, &scrollbar_paint_fill, &scrollbar_paint_text, &scrollbar_paint_clip };
	view.paint(&renderer, view.take_damage())!!;
	test::eq(probe.pixels[10 * 120 + 87], (char)1);
	test::eq(probe.pixels[10 * 120 + 90], (char)1);
	test::eq(probe.pixels[25 * 120 + 90], (char)0);
	test::eq(probe.pixels[99 * 120 + 90], (char)0);
	panel.scroll_to(100);
	view.paint(&renderer, view.take_damage())!!;
	test::eq(probe.pixels[10 * 120 + 90], (char)0);
	test::eq(probe.pixels[10 * 120 + 88], (char)1);
	test::eq(probe.pixels[25 * 120 + 90], (char)0);
	view.paint(&renderer, { 90, 5, 2, 10 })!!;
	test::eq(probe.pixels[10 * 120 + 88], (char)1); // Partial repaint preserves neighbors.
}

fn void scrollbar_pointer_down_flushes_stale_geometry_and_pending_bindings() @test
{
	View view;
	defer view.free();
	ScrollbarProbe probe;
	view.resize(240, 200);
	view.set_root_spacing(0, 0);
	view.set_measurer(&scrollbar_metrics, &probe);
	Widget* panel = view.scroll_column({ .width = 100, .height = 100 });
	panel.set_scrollbar();
	panel.text().bind(&scrollbar_label, &probe);
	view.update();
	test::eq(panel.scroll_track.empty(), true);
	probe.tall.set(true);
	view.pointer_down(90, 10);
	test::eq(view.scroll_dragging, true);
	view.pointer_up(90, 10);
	view.set_root_alignment(START, END);
	view.pointer_down(90, 10); // Old track coordinate is no longer inside the panel.
	test::eq(view.scroll_press_active, false);
	test::eq(panel.scroll_track.x, 228);
	view.pointer_up(90, 10);
	view.pointer_down(230, 10);
	test::eq(view.scroll_dragging, true);
	view.pointer_up(230, 10);
	probe.tall.set(false);
	view.pointer_down(230, 10); // Pending shrink removes the track before targeting.
	test::eq(view.scroll_press_active, false);
	test::eq(panel.scroll_track.empty(), true);
	view.pointer_up(230, 10);
}
