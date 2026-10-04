extends RefCounted
## Shared look for the HUD: palette, fonts, panel styles and small widget helpers.

const BG := Color(0.03, 0.045, 0.07, 0.8)
const BG_SOFT := Color(0.03, 0.05, 0.08, 0.6)
const BG_CARD := Color(0.07, 0.1, 0.14, 0.85)
const BG_CARD_HI := Color(0.1, 0.16, 0.22, 0.95)
const LINE := Color(0.45, 0.75, 0.95, 0.22)
const LINE_HI := Color(0.45, 0.85, 1.0, 0.7)
const ACCENT := Color(1.0, 0.58, 0.2)
const CYAN := Color(0.4, 0.86, 1.0)
const TEXT := Color(0.9, 0.95, 1.0)
const DIM := Color(0.58, 0.67, 0.76)
const FAINT := Color(0.42, 0.5, 0.58)
const GOOD := Color(0.45, 0.95, 0.6)
const WARN := Color(1.0, 0.78, 0.35)
const BAD := Color(1.0, 0.42, 0.36)
## Iron, copper, crystal, soil.
const RES_COLORS := [Color(0.92, 0.45, 0.32), Color(1.0, 0.66, 0.32), Color(0.76, 0.52, 1.0), Color(0.78, 0.6, 0.42)]
const RES_ICONS := ["iron", "copper", "crystal", "soil"]

static var _fonts := {}


static func font(weight := 400) -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Roboto", "Noto Sans", "DejaVu Sans", "Sans-Serif"])
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	_fonts[weight] = f
	return f


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font(400)
	t.default_font_size = 15
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.6))
	t.set_constant("shadow_offset_x", "Label", 1)
	t.set_constant("shadow_offset_y", "Label", 1)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_font("bold_font", "RichTextLabel", font(700))
	return t


static func box(bg: Color, radius := 10, border := Color(0, 0, 0, 0), border_w := 0, margin := 12.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_content_margin_all(margin)
	s.anti_aliasing = true
	s.corner_detail = 6
	return s


static func panel_box(margin := 14.0) -> StyleBoxFlat:
	var s := box(BG, 12, LINE, 1, margin)
	s.shadow_color = Color(0, 0, 0, 0.35)
	s.shadow_size = 8
	return s


static func label(parent: Node, text := "", size := 15, color := TEXT, weight := 400) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if weight != 400:
		l.add_theme_font_override("font", font(weight))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent:
		parent.add_child(l)
	return l


static func rich(parent: Node, size := 15) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	r.add_theme_font_override("bold_font", font(700))
	r.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	r.add_theme_constant_override("shadow_offset_x", 1)
	r.add_theme_constant_override("shadow_offset_y", 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent:
		parent.add_child(r)
	return r


static func bar(parent: Node, fill: Color, w := 160.0, h := 8.0) -> ProgressBar:
	var b := ProgressBar.new()
	b.max_value = 1.0
	b.step = 0.0
	b.show_percentage = false
	b.custom_minimum_size = Vector2(w, h)
	var bg := box(Color(1, 1, 1, 0.08), int(h * 0.5), Color(0, 0, 0, 0), 0, 0)
	var fg := box(fill, int(h * 0.5), Color(0, 0, 0, 0), 0, 0)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent:
		parent.add_child(b)
	return b


## Small rounded "key cap" label, e.g. [1] or [Tab].
static func keycap(parent: Node, key: String, size := 12) -> Label:
	var l := label(parent, key, size, TEXT, 700)
	var s := box(Color(1, 1, 1, 0.1), 4, Color(1, 1, 1, 0.28), 1, 0)
	s.content_margin_left = 5
	s.content_margin_right = 5
	s.content_margin_top = 0
	s.content_margin_bottom = 1
	l.add_theme_stylebox_override("normal", s)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


static func hbox(parent: Node, sep := 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent:
		parent.add_child(h)
	return h


static func vbox(parent: Node, sep := 6) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent:
		parent.add_child(v)
	return v


static func panel(parent: Node, style: StyleBox) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", style)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent:
		parent.add_child(p)
	return p


## Thin horizontal separator line.
static func rule(parent: Node, color := LINE) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	return r


static func section_title(parent: Node, text: String, color := CYAN) -> HBoxContainer:
	var h := hbox(parent, 8)
	var dot := ColorRect.new()
	dot.color = color
	dot.custom_minimum_size = Vector2(3, 14)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(dot)
	label(h, text, 13, color, 700)
	return h


## Turkish-aware upper case (i -> İ, ı -> I).
static func upper_tr(s: String) -> String:
	return s.replace("i", "İ").replace("ı", "I").to_upper()
