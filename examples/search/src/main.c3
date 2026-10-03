module search;
import ui, std::io;

const String[16] ITEMS = { "Apple", "Apricot", "Avocado", "Banana", "Blackberry", "Blueberry",
	"Cherry", "Coconut", "Grape", "Kiwi", "Lemon", "Mango", "Orange", "Peach", "Pear", "Strawberry" };

struct Search
{
	String query; // Application-owned copy; callback text is borrowed.
	State{int} revision;
	State{String} chosen; // Values are static labels from ITEMS.
	Widget* input;
	Widget* list;
}
struct Item { Search* app; String label; }

fn bool matches(String label, String query) => @pool()
{
	return label.to_lower_tcopy().contains(query.to_lower_tcopy());
}

fn void Search.set_query(&self, String text)
{
	if (self.query == text) return;
	String copy = text.copy(mem);
	self.query.free(mem);
	self.query = copy;
	self.revision.set(self.revision.get() + 1);
	// Filtering recomputes visible rows and clamps the retained scrollbar.
	self.list.scroll_to(0);
}

fn int Search.match_count(&self)
{
	self.revision.get();
	int count;
	foreach (label : ITEMS) if (matches(label, self.query)) count++;
	return count;
}

fn int main()
{
	Search app = { .chosen.value = "Choose a fruit" };
	defer app.query.free(mem);
	Item[16] items; // Typed modifier contexts keep stable addresses.
	View view;
	defer view.free();
	view.set_root_alignment(START, STRETCH);
	view.text("Search fruit (case insensitive). Click a result to select it.");
	app.input = view.text_field().@on_text_change(&app, fn (a, text) => a.set_query(text));
	view.@row({ .gap = 12 }; Widget* toolbar)
	{
		toolbar.button("Clear").@on_click(&app, fn (a) {
			a.input.set_text(""); // Silent assignment; synchronize application state explicitly.
			a.set_query("");
		});
		toolbar.text().@text(&app, fn (a) => string::tformat("%s results", a.match_count()));
	};
	view.text().@text(&app.chosen, "Selected: %s");
	app.list = view.scroll_column({ .fill = true, .min_height = 64, .padding = 8,
		.gap = 4, .cross_align = STRETCH });
	app.list.set_scrollbar();
	foreach (i, label : ITEMS)
	{
		items[i] = { &app, label };
		app.list.button(label)
			.@visible(&items[i], fn (item) {
				item.app.revision.get();
				return matches(item.label, item.app.query);
			})
			.@on_click(&items[i], fn (item) => item.app.chosen.set(item.label));
	}
	app.list.text("No matching fruit").@visible(&app, fn (a) => a.match_count() == 0);
	if (catch error = view.open("Native C3 searchable list", width: 520, height: 480))
	{
		io::eprintfn("Could not open window: %s", error);
		return 1;
	}
	return 0;
}
