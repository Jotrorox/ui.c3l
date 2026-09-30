module window;

import ui, std::io;

fn int main()
{
	if (catch error = ui::open_window("Native C3 window"))
	{
		io::eprintfn("Could not open window: %s", error);
		return 1;
	}
	return 0;
}
