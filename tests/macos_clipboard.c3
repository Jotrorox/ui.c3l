module ui::backend @feat(MACOS);
import std::core::test, std::os::macos::objc, std::os::macos::cf;

fn void macos_native_clipboard_roundtrip_commands_and_atomic_rejection() @test
{
	objc::@autoreleasepool()
	{
		objc::msg_send(objc::getClass("NSApplication"), MacObject, "sharedApplication");
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* field = view.text_field("aé👋z");
		view.focus_next();
		void* board = objc::msg_send(objc::getClass("NSPasteboard"), MacObject, "pasteboardWithUniqueName");
		test::eq(board != null, true);
		defer objc::msg_send(board, MacVoid, "releaseGlobally");
		void* native = objc::msg_send(objc::alloc(init_mac_class()!!), MacFrame, "initWithFrame:", (CGRect){ {}, { 400, 300 } });
		defer objc::release(native);
		MacWindow window = { .view = &view, .pasteboard = board, .native_view = native };
		objc::setInstanceVariable(native, "ui_context", &window);
		defer objc::setInstanceVariable(native, "ui_context", null);
		view.set_clipboard(&mac_clipboard_write, &mac_clipboard_read, &window);
		field.select(7, 1);
		send_mac_field_key(native, 8, "c", 1 << 20); // Command-C through AppKit dispatch.
		mac_key(&view, false, 8, false, 0);
		test::eq(field.get_text(), "aé👋z");
		field.select(0, 8);
		send_mac_field_key(native, 9, "v", 1 << 20); // Command-V replaces selection.
		mac_key(&view, false, 9, false, 0);
		test::eq(field.get_text(), "é👋");
		test::eq(field.selection().caret, 6);
		field.select(6, 0);
		send_mac_field_key(native, 7, "x", 1 << 20); // Command-X.
		mac_key(&view, false, 7, false, 0);
		test::eq(field.get_text(), "");
		view.clipboard_command(PASTE);
		test::eq(field.get_text(), "é👋");
		field.select(6, 0);
		foreach (String invalid : { "line\nbreak", "embedded\0nul" })
		{
			test::eq(mac_clipboard_write(&window, invalid), true);
			view.clipboard_command(PASTE);
			test::eq(field.get_text(), "é👋");
			test::eq(field.selection().anchor, 6);
			test::eq(field.selection().caret, 0);
		}
		char[4097] large;
		large[..] = 'x';
		mac_clipboard_write(&window, (String)large[..]);
		view.clipboard_command(PASTE);
		test::eq(field.get_text(), "é👋");
	};
}
