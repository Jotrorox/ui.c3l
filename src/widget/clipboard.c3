module ui;
import std::math;

struct ClipboardRequest { ulong focus_epoch; ulong edit_epoch; }
alias ClipboardWrite = fn bool(void* context, String text);
alias ClipboardRead = fn void(void* context, ClipboardRequest request);

// Native windows install providers for their lifetime. Custom event loops may
// install their own; reads can complete asynchronously via paste_text().
fn void View.set_clipboard(&self, ClipboardWrite write, ClipboardRead read, void* context = null)
{
	assert(!active_binding, "Bindings cannot change clipboard providers");
	self.edit_epoch++;
	self.clipboard_write = write;
	self.clipboard_read = read;
	self.clipboard_context = context;
}

fn bool View.paste_text(&self, String text, ClipboardRequest request)
{
	self.update();
	if (request.focus_epoch != self.focus_epoch || request.edit_epoch != self.edit_epoch) return false;
	return self.text_input(text);
}

fn bool View.clipboard_command(&self, ControlKey action)
{
	assert(!active_binding, "Bindings cannot dispatch clipboard commands");
	self.update();
	Widget* field = self.focused;
	if (!field || field.kind != TEXT_FIELD || !field.interactive()) return false;
	ClipboardRequest request = { self.focus_epoch, self.edit_epoch };
	if (action == PASTE)
	{
		if (!self.clipboard_read) return false;
		self.clipboard_read(self.clipboard_context, request);
		return true;
	}
	if (action != COPY && action != CUT) return false;
	sz start = math::min(field.text_selection.anchor, field.text_selection.caret);
	sz end = math::max(field.text_selection.anchor, field.text_selection.caret);
	if (start == end || !self.clipboard_write) return false;
	// Own a snapshot across provider callbacks, which may edit/remove the field.
	String text = field.content[start:end - start].copy(mem);
	defer text.free(mem);
	if (!self.clipboard_write(self.clipboard_context, text)) return false;
	self.update();
	if (action == CUT && request.focus_epoch == self.focus_epoch && request.edit_epoch == self.edit_epoch)
	{
		replace_field_selection(self.focused, "");
	}
	return true;
}
