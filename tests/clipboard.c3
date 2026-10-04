module ui;
import std::core::test;

struct ClipboardProbe
{
	View* view;
	String written;
	ClipboardRequest request;
	int reads;
	int writes;
	bool fail;
	bool remove;
}
fn bool probe_clipboard_write(void* context, String text) @private
{
	ClipboardProbe* probe = context;
	probe.writes++;
	probe.written.free(mem);
	probe.written = text.copy(mem);
	if (probe.remove) probe.view.focused.remove();
	// The snapshot remains valid even if the provider removes the editor.
	test::eq(text, probe.written);
	return !probe.fail;
}
fn void probe_clipboard_read(void* context, ClipboardRequest request) @private
{
	ClipboardProbe* probe = context;
	probe.reads++;
	probe.request = request;
}

fn void clipboard_copy_cut_and_paste_preserve_utf8_selection_and_callbacks() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	FieldProbe changes;
	defer changes.saved.free(mem);
	Widget* field = view.text_field("aé👋z", &field_changed, &changes);
	changes.field = field;
	ClipboardProbe probe = { .view = &view };
	defer probe.written.free(mem);
	view.set_clipboard(&probe_clipboard_write, &probe_clipboard_read, &probe);
	view.focus_next();
	field.select(7, 1);
	view.key_down(1, COPY);
	test::eq(probe.written, "é👋");
	test::eq(field.get_text(), "aé👋z");
	test::eq(field.selection().anchor, 7);
	test::eq(changes.changes, 0);
	view.key_down(1, COPY, true);
	test::eq(probe.writes, 1);
	probe.fail = true;
	test::eq(view.clipboard_command(CUT), false);
	test::eq(field.get_text(), "aé👋z");
	test::eq(field.selection().caret, 1);
	probe.fail = false;
	test::eq(view.clipboard_command(CUT), true);
	test::eq(field.get_text(), "az");
	test::eq(field.selection().caret, 1);
	test::eq(changes.changes, 1);
	view.clipboard_command(COPY); // Empty selection leaves the clipboard alone.
	test::eq(probe.written, "é👋");
	field.select(1, 2);
	view.key_down(2, PASTE);
	view.key_down(2, PASTE, true);
	test::eq(probe.reads, 1);
	test::eq(view.paste_text("世界", probe.request), true);
	test::eq(field.get_text(), "a世界");
	test::eq(field.selection().anchor, 7);
	test::eq(changes.changes, 2);
	test::eq(view.paste_text("again", probe.request), false); // One completion only.
	field.set_enabled(false);
	test::eq(view.clipboard_command(PASTE), false);
}

fn void clipboard_rejects_invalid_and_over_limit_pastes_atomically() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* field = view.text_field("safe");
	ClipboardProbe probe = { .view = &view };
	view.set_clipboard(null, &probe_clipboard_read, &probe);
	view.focus_next();
	field.select(4, 0);
	foreach (String invalid : { "", "\xff", "\xc0\x80", "\xed\xa0\x80", "\0x", "\n", "a\rb", "\t", "\xe2\x80\xa8" })
	{
		view.clipboard_command(PASTE);
		test::eq(view.paste_text(invalid, probe.request), false);
		test::eq(field.get_text(), "safe");
		test::eq(field.selection().anchor, 4);
		test::eq(field.selection().caret, 0);
	}
	char[4097] text;
	text[..] = 'x';
	view.clipboard_command(PASTE);
	test::eq(view.paste_text((String)text[..], probe.request), false);
	field.set_text((String)text[:4096]);
	field.select(4095, 4096);
	view.clipboard_command(PASTE);
	test::eq(view.paste_text("é", probe.request), false);
	test::eq(field.selection().anchor, 4095);
	field.select(4094, 4096);
	view.clipboard_command(PASTE);
	test::eq(view.paste_text("é", probe.request), true);
	test::eq(field.get_text().len, 4096);
	test::eq(field.get_text()[4094..], "é");
}

fn void clipboard_delayed_pastes_cancel_on_edits_selection_focus_or_removal() @test
{
	for (int mode = 0; mode < 6; mode++)
	{
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* field = view.text_field("first");
		Widget* second = view.text_field("second");
		ClipboardProbe probe = { .view = &view };
		view.set_clipboard(null, &probe_clipboard_read, &probe);
		view.focus_next();
		view.clipboard_command(PASTE);
		switch (mode)
		{
			case 0: field.set_text("edited");
			case 1: field.select(0, 5);
			case 2: view.focus_next();
			case 3: field.remove(); view.focus_next();
			case 4: field.set_visible(false);
			case 5: field.set_enabled(false);
		}
		test::eq(view.paste_text("late", probe.request), false);
		test::eq(second.get_text(), "second");
	}
}

fn void clipboard_cut_provider_and_text_change_callbacks_may_remove_the_field() @test
{
	View view;
	defer view.free();
	view.resize(400, 300);
	ClipboardProbe probe = { .view = &view, .remove = true };
	defer probe.written.free(mem);
	view.set_clipboard(&probe_clipboard_write, null, &probe);
	Widget* field = view.text_field("snapshot");
	view.focus_next();
	field.select(0, 8);
	test::eq(view.clipboard_command(CUT), true);
	test::eq(view.first, (Widget*)null);
	test::eq(probe.written, "snapshot");
	probe.remove = false;
	FieldProbe changes;
	defer changes.saved.free(mem);
	changes.field = view.text_field("remove", &field_changed, &changes);
	changes.remove = changes.field;
	view.focus_next();
	changes.field.select(0, 6);
	test::eq(view.clipboard_command(CUT), true);
	test::eq(view.first, (Widget*)null);
	test::eq(changes.saved, "");
	test::eq(changes.changes, 1);
}
