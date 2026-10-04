module clipboard_window_test;
import ui, std::io;

fn void changed(void* context, String text)
{
	int* changes = context;
	(*changes)++;
	io::printfn("{\"text\":\"%s\",\"changes\":%s}", text, *changes);
}

fn int main()
{
	View view;
	defer view.free();
	int changes;
	Widget* field = view.text_field("aé👋z", &changed, &changes);
	if (catch error = view.open("ui clipboard test", 400, 300))
	{
		io::eprintfn("Clipboard fixture: %s", error);
		return 1;
	}
	io::printfn("{\"text\":\"%s\",\"anchor\":%s,\"caret\":%s,\"changes\":%s}",
		field.get_text(), field.selection().anchor, field.selection().caret, changes);
	return 0;
}
