module native_window_test;
import ui, std::io;

fn int main()
{
	// Reopening in one process also tests native resource/class cleanup.
	for (int index = 0; index < 2; index++)
	{
		String title = index == 0 ? "ui native test 0 — 世界" : "ui native test 1 — 世界";
		if (catch error = ui::open_window(title, width: 321, height: 234))
		{
			io::eprintfn("Could not open test window: %s", error);
			return 1;
		}
	}
	return 0;
}
