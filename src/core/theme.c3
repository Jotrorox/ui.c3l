module ui;
import std::math;

// Opaque sRGB channels. Backends translate colors to their native pixel format.
struct Color { char red; char green; char blue; }

// PAPER and INK retain their original meanings for custom renderers. The other
// roles distinguish interaction states without changing the drawing callbacks.
enum Ink { PAPER, INK, SURFACE, HOVER, PRESSED, PRESSED_TEXT, BORDER,
	DISABLED, DISABLED_SURFACE, FOCUS, SELECTION, SELECTION_TEXT }
const int INK_COUNT = 12;

struct Theme
{
	Color[INK_COUNT] colors;
	int font_size; // Pixels; logical points on macOS. Native font family.
	int padding; // Implicit root inset; explicit Layout spacing takes precedence.
	int gap; // Implicit root gap and Checkbox label gap.
	int control_padding_x; // Button label inset.
	int control_padding_y; // Button/field inset; half this for Checkbox padding.
}

const Theme DEFAULT_THEME = {
	.colors = {
		{ 255, 255, 255 }, { 0, 0, 0 }, { 255, 255, 255 }, { 240, 240, 240 },
		{ 0, 0, 0 }, { 255, 255, 255 }, { 0, 0, 0 }, { 128, 128, 128 },
		{ 245, 245, 245 }, { 0, 95, 204 }, { 0, 0, 0 }, { 255, 255, 255 }
	},
	.font_size = 14, .padding = 16, .gap = 8,
	.control_padding_x = 12, .control_padding_y = 8,
};

fn bool Theme.valid(self) => self.font_size >= 1 && self.font_size <= 256 &&
	self.padding >= 0 && self.padding <= LAYOUT_LIMIT &&
	self.gap >= 0 && self.gap <= LAYOUT_LIMIT &&
	self.control_padding_x >= 0 && self.control_padding_x <= LAYOUT_LIMIT / 2 &&
	self.control_padding_y >= 0 && self.control_padding_y <= LAYOUT_LIMIT / 2;

fn bool Theme.same_colors(self, Theme other)
{
	foreach (index, color : self.colors)
	{
		Color next = other.colors[index];
		if (color.red != next.red || color.green != next.green || color.blue != next.blue) return false;
	}
	return true;
}

fn bool Theme.same_metrics(self, Theme other) => self.font_size == other.font_size &&
	self.padding == other.padding && self.gap == other.gap &&
	self.control_padding_x == other.control_padding_x && self.control_padding_y == other.control_padding_y;

fn Theme View.get_theme(&self) => self.custom_theme ? self.theme : DEFAULT_THEME;

// Invalid themes leave the view intact. Equal assignments are silent. Palette
// edits repaint only; metrics edits invalidate the relevant measurement caches.
fn bool View.set_theme(&self, Theme theme)
{
	assert(!active_binding, "Bindings cannot change themes");
	if (!theme.valid()) return false;
	Theme old = self.get_theme();
	bool metrics = !old.same_metrics(theme);
	if (!metrics && old.same_colors(theme)) return true;
	self.theme = theme;
	self.custom_theme = true;
	self.theme_epoch++;
	self.invalidate({ 0, 0, self.width, self.height });
	if (!metrics) return true;
	self.cancel_scrollbar();
	self.layout_dirty = true;
	for (Widget* widget = self.first; widget; widget = widget.next_in_tree())
	{
		widget.request_size();
		widget.request_layout();
		if (old.font_size != theme.font_size && !widget.is_container()) widget.text_dirty = true;
	}
	return true;
}

// Scale glyph-sized controls with the font. Explicit Layout sizes still win.
fn int Theme.scaled(self, int size) => math::max(1, (size * self.font_size + 7) / 14);

fn Size View.text_metrics(&self, String text)
{
	if (self.measure_text) return self.measure_text(self.measure_context, text);
	Theme theme = self.get_theme();
	Size size = measure_default(null, text);
	return { (int)math::min((long)LAYOUT_LIMIT, ((long)size.width * theme.font_size + 7) / 14),
		theme.scaled(size.height) };
}
