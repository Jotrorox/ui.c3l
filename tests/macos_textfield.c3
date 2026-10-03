module ui::backend @feat(MACOS);
import std::core::test;
import std::os::macos::objc, std::os::macos::cf;

alias MacKeyEvent = fn void*(void*, ObjcSelector, long, CGPoint, ulong, double, long, void*, void*, void*, bool, ushort);

fn void send_mac_field_key(void* native, ushort key, String value, ulong modifiers = 0) @private
{
	void* chars = mac_string(value);
	defer objc::release(chars);
	void* event = objc::msg_send(objc::getClass("NSEvent"), MacKeyEvent,
		"keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:",
		10L, (CGPoint){}, modifiers, 0.0, 0L, null, chars, chars, false, key);
	mac_input(native, (ObjcSelector)null, event);
}

fn void macos_textfield_commits_utf8_and_translates_utf16_replacement_ranges() @test
{
	objc::@autoreleasepool()
	{
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* field = view.text_field("a👋b");
		view.focus_next();
		void* native = objc::msg_send(objc::alloc(init_mac_class()!!), MacFrame, "initWithFrame:", (CGRect){ {}, { 400, 300 } });
		defer objc::release(native);
		MacWindow window = { .view = &view, .native_view = native };
		defer window.marked_text.free(mem);
		objc::setInstanceVariable(native, "ui_context", &window);
		defer objc::setInstanceVariable(native, "ui_context", null);
		MacRange selected = mac_selected_range(native, (ObjcSelector)null);
		test::eq(selected.location, (usz)4);
		void* replacement = mac_string("é");
		defer objc::release(replacement);
		mac_insert_text(native, (ObjcSelector)null, replacement, { 2, 1 }); // Split surrogate.
		test::eq(field.get_text(), "a👋b");
		void* invalid = mac_string("\n");
		defer objc::release(invalid);
		mac_insert_text(native, (ObjcSelector)null, invalid, { 0, 1 });
		test::eq(field.get_text(), "a👋b");
		test::eq(field.selection().caret, 6);
		mac_insert_text(native, (ObjcSelector)null, replacement, { 1, 2 });
		test::eq(field.get_text(), "aéb");
		test::eq(field.selection().caret, 3);
		void* marked = mac_string("preedit");
		defer objc::release(marked);
		mac_mark_text(native, (ObjcSelector)null, marked, { 0, 7 }, { MAC_NOT_FOUND, 0 });
		test::eq(mac_has_marked(native, (ObjcSelector)null), true);
		test::eq(field.get_text(), "aéb"); // Preedit is never committed by physical keys.
		MacRange mark_range = mac_marked_range(native, (ObjcSelector)null);
		test::eq(mark_range.location, (usz)2);
		test::eq(mark_range.length, (usz)7);
		// An input method can replace the virtual marked range with a commit.
		mac_insert_text(native, (ObjcSelector)null, replacement, mark_range);
		test::eq(field.get_text(), "aééb");
		test::eq(mac_has_marked(native, (ObjcSelector)null), false);
		mac_mark_text(native, (ObjcSelector)null, marked, { 0, 7 }, { MAC_NOT_FOUND, 0 });
		mac_unmark(native, (ObjcSelector)null); // Confirmation commits marked text once.
		test::eq(field.get_text(), "aéépreeditb");
		mac_mark_text(native, (ObjcSelector)null, marked, { 0, 7 }, { MAC_NOT_FOUND, 0 });
		view.blur();
		test::eq(mac_has_marked(native, (ObjcSelector)null), false);
	};
}

fn void macos_textfield_interprets_printable_key_events_once_and_handles_commands() @test
{
	objc::@autoreleasepool()
	{
		objc::msg_send(objc::getClass("NSApplication"), MacObject, "sharedApplication");
		View view;
		defer view.free();
		view.resize(400, 300);
		Widget* field = view.text_field();
		view.focus_next();
		void* native = objc::msg_send(objc::alloc(init_mac_class()!!), MacFrame, "initWithFrame:", (CGRect){ {}, { 400, 300 } });
		defer objc::release(native);
		void* shell = objc::msg_send(objc::alloc(objc::getClass("NSWindow")), MacWindowInit,
			"initWithContentRect:styleMask:backing:defer:", (CGRect){ {}, { 400, 300 } }, 15UL, 2UL, false);
		defer objc::release(shell);
		objc::msg_send(shell, MacBoolArg, "setReleasedWhenClosed:", false);
		objc::msg_send(shell, MacVoidArg, "setContentView:", native);
		objc::msg_send(shell, MacBoolObject, "makeFirstResponder:", native);
		MacWindow window = { .view = &view, .native_view = native, .window = shell };
		defer window.marked_text.free(mem);
		objc::setInstanceVariable(native, "ui_context", &window);
		defer objc::setInstanceVariable(native, "ui_context", null);
		void* input_context = objc::msg_send(native, MacObject, "inputContext");
		objc::msg_send(input_context, MacVoid, "activate");
		defer objc::msg_send(input_context, MacVoid, "deactivate");
		foreach (String value : { "a", " ", "é", "👋" })
		{
			send_mac_field_key(native, 0, value);
		}
		test::eq(field.get_text(), "a é👋");
		send_mac_field_key(native, 123, "\xef\x9c\x82"); // NSLeftArrowFunctionKey.
		test::eq(field.selection().caret, 4);
		send_mac_field_key(native, 123, "\xef\x9c\x82", 1 << 17);
		test::eq(field.selection().anchor, 4);
		test::eq(field.selection().caret, 2);
		send_mac_field_key(native, 51, "\x7f");
		test::eq(field.get_text(), "a 👋");
		send_mac_field_key(native, 36, "\r");
		test::eq(field.get_text(), "a 👋");
		mac_key(&view, true, 0, false, 1 << 20); // Command-A.
		test::eq(field.selection().anchor, 0);
		test::eq(field.selection().caret, 6);
		mac_key(&view, true, 51, false, 0);
		test::eq(field.get_text(), "");
	};
}
