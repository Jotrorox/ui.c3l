module ui::backend @feat(LINUX);
import std::core::test;

fn void linux_selects_from_runtime_environment_and_accepts_explicit_overrides() @test
{
	test::eq(linux_backend("")!!, LinuxBackend.AUTO);
	test::eq(linux_backend("auto")!!, LinuxBackend.AUTO);
	test::eq(linux_backend("x11")!!, LinuxBackend.X11);
	test::eq(linux_backend("wayland")!!, LinuxBackend.WAYLAND);
	test::@error(linux_backend("invalid"), ui::INVALID_OPTIONS);
	test::eq(prefer_wayland("wayland-0", "", "", "", ":0"), true);
	test::eq(prefer_wayland("", "3", "", "", ":0"), true);
	test::eq(prefer_wayland("", "", "wayland", "", ":0"), true);
	test::eq(prefer_wayland("", "", "", "/run/user/1000", ""), true);
	test::eq(prefer_wayland("", "", "x11", "/run/user/1000", ":0"), false);
	test::eq(prefer_wayland("", "", "", "", ""), false);
}
