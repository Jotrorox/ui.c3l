module ui;
import std::core::test;

fn void accepts_valid_options() @test
{
	validate_options({ "", 1, 1 })!!;
	validate_options({ "Hello — 世界", 800, 600 })!!;
	validate_options({ "ui", 65535, 65535 })!!;
}

fn void rejects_invalid_dimensions_before_opening() @test
{
	foreach (int value : { -1, 0, 65536, int::max })
	{
		test::@error(open_window(width: value), INVALID_OPTIONS);
		test::@error(open_window(height: value), INVALID_OPTIONS);
	}
}

fn void rejects_invalid_titles_before_opening() @test
{
	test::@error(open_window("embedded\0nul"), INVALID_OPTIONS);
	test::@error(open_window("\xff"), INVALID_OPTIONS);
	char[4097] title;
	title[..] = 'a';
	test::@error(open_window((String)title[..]), INVALID_OPTIONS);
	validate_options({ (String)title[:4096], 800, 600 })!!;
}
