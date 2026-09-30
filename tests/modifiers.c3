module ui;
import std::core::test;

struct ModifierApp
{
	State{int} count;
	State{bool} shown;
	State{bool} flag;
	int clicks;
	int changes;
	bool proposed;
}

fn void modifiers_bind_text_from_state_format_and_lambda() @test
{
	ModifierApp app = { .count.value = 5 };
	View view;
	defer view.free();
	Widget* plain = view.text().@text(&app.count);
	Widget* formatted = view.text().@text(&app.count, "Count: %s");
	Widget* computed = view.button("").@text(&app, fn (a) => string::tformat("%s/%s", a.count.get(), a.clicks));
	test::eq(plain.get_text(), "5");
	test::eq(formatted.get_text(), "Count: 5");
	test::eq(computed.get_text(), "5/0");
	app.count.set(7);
	view.update();
	test::eq(plain.get_text(), "7");
	test::eq(formatted.get_text(), "Count: 7");
	test::eq(computed.get_text(), "7/0");
}

fn void modifiers_bind_visible_and_enabled_from_state_or_lambda() @test
{
	ModifierApp app = { .shown.value = true };
	View view;
	defer view.free();
	Widget* panel = view.column().@visible(&app.shown);
	Widget* button = panel.button("Reset").@enabled(&app.count, fn (c) => c.get() != 0);
	test::eq(panel.is_visible(), true);
	test::eq(button.is_enabled(), false);
	app.shown.set(false);
	app.count.set(1);
	view.update();
	test::eq(panel.is_visible(), false);
	test::eq(button.is_enabled(), true);
	panel.@enabled(&app.shown);
	test::eq(button.is_enabled(), false);
}

fn void modifier_checked_state_is_two_way() @test
{
	ModifierApp app;
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* check = view.checkbox("Show").@checked(&app.shown);
	view.update();
	view.focus_next();
	view.activate_focused();
	test::eq(app.shown.get(), true);
	view.update();
	test::eq(check.is_checked(), true);
	app.shown.set(false);
	view.update();
	test::eq(check.is_checked(), false);
}

fn void modifier_checked_lambda_only_reads_until_on_change_accepts() @test
{
	ModifierApp app;
	View view;
	defer view.free();
	view.resize(400, 300);
	Widget* check = view.checkbox("Inverse").@checked(&app.flag, fn (c) => !c.get());
	test::eq(check.is_checked(), true);
	view.focus_next();
	view.activate_focused();
	view.update();
	test::eq(app.flag.get(), false); // No writer: the proposal is dropped.
	test::eq(check.is_checked(), true);
	check.@on_change(&app, fn (a, checked) { a.changes++; a.proposed = checked; a.flag.set(!checked); });
	view.activate_focused();
	view.update();
	test::eq(app.changes, 1);
	test::eq(app.proposed, false);
	test::eq(app.flag.get(), true);
	test::eq(check.is_checked(), false);
}

fn void modifier_on_click_receives_typed_context() @test
{
	ModifierApp app;
	View view;
	defer view.free();
	view.resize(400, 300);
	view.button("Increment").@on_click(&app, fn (a) { a.clicks++; a.count.set(a.count.get() + 2); });
	view.focus_next();
	view.activate_focused();
	view.activate_focused();
	test::eq(app.clicks, 2);
	test::eq(app.count.get(), 4);
}

fn void trailing_body_containers_nest_and_return_their_widget() @test
{
	View view;
	defer view.free();
	Widget* inner;
	Widget* outer = view.@column({ .gap = 4 }; Widget* column)
	{
		column.text("title");
		inner = column.@row({ .gap = 2 }; Widget* row)
		{
			row.button("a");
			row.button("b");
		};
	};
	test::eq(outer.kind, WidgetKind.COLUMN);
	test::eq(outer.layout.gap, 4);
	test::eq(inner.kind, WidgetKind.ROW);
	test::eq(inner.parent, outer);
	test::eq(outer.last, inner);
	test::eq(inner.first.get_text(), "a");
	test::eq(inner.last.get_text(), "b");
}
