module reactive_window_test;
import ui, std::io;

struct Counter
{
	State{int} count;
	Widget* label;
	Widget* button;
}

fn String label_text(void* context)
{
	Counter* counter = context;
	return string::tformat("Count: %s", counter.count.get());
}

fn void increment(void* context)
{
	Counter* counter = context;
	counter.count.set(counter.count.get() + 1);
	Rect rect = counter.button.visible;
	io::printfn("[%s,%s,%s,%s]", rect.x, rect.y, rect.width, rect.height);
}

fn int main()
{
	Counter counter;
	View view;
	defer view.free();
	counter.button = view.button("Increment", &increment, &counter);
	counter.label = view.text();
	counter.label.bind(&label_text, &counter);
	if (catch error = view.open("ui reactive test", width: 321, height: 234))
	{
		io::eprintfn("Could not open test window: %s", error);
		return 1;
	}
	if (counter.count.get() != 2 || counter.label.get_text() != "Count: 2") return 2;
	return 0;
}
