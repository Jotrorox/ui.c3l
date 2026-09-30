module ui::backend @feat(WIN32);
import std::core::test;

fn void windows_wheel_signed_detents_partial_pixels_and_window_remainders() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* scroll = view.scroll_column({ .width = 200, .height = 80 });
	scroll.text("content").set_layout({ .height = 400 });
	view.update();
	int first_remainder;
	int other_remainder;
	win_wheel(&view, &first_remainder, 30, 30, -120);
	test::eq(scroll.scroll_offset(), 40);
	win_wheel(&view, &first_remainder, 30, 30, 60);
	test::eq(scroll.scroll_offset(), 20);
	win_wheel(&view, &first_remainder, 30, 30, -1);
	win_wheel(&view, &first_remainder, 30, 30, -1);
	test::eq(scroll.scroll_offset(), 20);
	test::eq(first_remainder, 80);
	win_wheel(&view, &other_remainder, 30, 30, -1);
	test::eq(other_remainder, 40);
	test::eq(scroll.scroll_offset(), 20);
	win_wheel(&view, &first_remainder, 30, 30, -1);
	test::eq(scroll.scroll_offset(), 21);
	test::eq(first_remainder, 0);
	win_wheel(&view, &first_remainder, 30, 30, 1);
	win_wheel(&view, &first_remainder, 30, 30, -1);
	test::eq(first_remainder, 0);
	test::eq(scroll.scroll_offset(), 21);
	win_wheel(&view, &first_remainder, -5, 30, -120);
	test::eq(scroll.scroll_offset(), 21);
	win_wheel(&view, &first_remainder, 30, 30, 32767);
	test::eq(scroll.scroll_offset(), 0);
}
