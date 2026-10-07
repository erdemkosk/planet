extends RefCounted
## THE design system of every 2D UI in the game (HUD, overlays, panels, menus). One look: the
## astronaut's suit (white shell, orange bands) and its wrist computer (scripts/player/wrist_display.gd:
## dark teal glass, faint scanlines, cyan read-outs, an orange header strip), with No Man's Sky-like
## polish: glass plates with one cut (chamfered) corner pair, thin suit-white frames, orange accents on
## whatever is active, caps labels with a little letter spacing, outlined text, tabular numbers.
## Never pure black or pure white (the user's lighting rule): darks are teal-black glass at < 0.85
## alpha, lights are the suit's off-white.
##
## Tokens (1080p pixels; HUDs multiply by k = scale_k(viewport size), menus are laid out at 1080p):
##   colours     SUIT_WHITE · SUIT_ORANGE · GLASS (+ GLASS_A) · SCREEN_CYAN · INK · OUTLINE · TEXT · DIM ·
##               FAINT · GOOD · WARN · BAD · CRIT · HOME (our core, violet) · RIVAL (theirs, red) · ALLY ·
##               BUILD (the build tool's holo green) · the older BG / LINE / ACCENT / CYAN set
##   type        FS_TINY 11 · FS_SMALL 13 · FS_BODY 15 · FS_LEAD 18 · FS_TITLE 24 · FS_BIG 34 · FS_HUGE 64;
##               font(weight) (Bahnschrift → Segoe UI → … system chain), font_num(weight) (tabular
##               figures: counters do not jitter), font_caps(weight, spacing) (letter-spaced labels)
##   geometry    CUT (chamfer) · RADIUS · PAD · GAP · STROKE · SCAN_STEP (scanline pitch)
##   motion      T_FAST · T_MED · T_SLOW (s) · PULSE_HZ (low health) · BLINK (warning period) ·
##               TRAIL_HOLD / TRAIL_RATE (damage trail) · smooth(), approach()
## Widgets
##   styleboxes  box() (rounded, as before) · chamfer_box() · glass_box() · panel_box() · make_theme()
##               (Label, RichTextLabel, Button, LineEdit, HSlider, CheckButton, PanelContainer, tooltip)
##   nodes       label() · rich() · bar() · keycap() · hbox() · vbox() · panel() · rule() · section_title()
##   drawing     (static, on any CanvasItem, no node per call) draw_text / _r / _c · draw_glass ·
##               draw_chamfer · draw_seg_bar · draw_key · draw_ring · draw_hazard · draw_corners ·
##               draw_alert_icon · text_w
## Turkish: upper_tr() (i → İ, ı → I).

# --- Palette ----------------------------------------------------------------------------------------

## The suit and its wrist computer.
const SUIT_WHITE := Color(0.92, 0.93, 0.94)
const SUIT_ORANGE := Color(1.0, 0.55, 0.18)
const GLASS := Color(0.015, 0.045, 0.06)
const GLASS_A := 0.8
const GLASS_HI := Color(0.03, 0.085, 0.105)
const SCREEN_CYAN := Color(0.4, 0.92, 1.0)
const INK := Color(0.035, 0.045, 0.055)              # dark text on the light plates (key caps, tags)
const OUTLINE := Color(0.0, 0.02, 0.035, 0.62)        # text outline (never pure black)
## Status.
const TEXT := Color(0.92, 0.95, 0.97)
const DIM := Color(0.6, 0.71, 0.79)
const FAINT := Color(0.43, 0.52, 0.59)
const GOOD := Color(0.45, 0.95, 0.62)
const WARN := Color(1.0, 0.76, 0.34)
const BAD := Color(1.0, 0.42, 0.36)
const CRIT := Color(1.0, 0.3, 0.26)
## Sides.
const HOME := Color(0.68, 0.52, 1.0)                  # our core (violet plasma)
const RIVAL := Color(1.0, 0.34, 0.36)                 # theirs (red plasma)
const ALLY := Color(0.42, 0.95, 0.8)
const BUILD := Color(0.42, 1.0, 0.66)                 # the build tool's holo green
## The older names (kept: many panels use them).
const BG := Color(0.015, 0.045, 0.06, 0.8)
const BG_SOFT := Color(0.015, 0.045, 0.06, 0.6)
const BG_CARD := Color(0.03, 0.075, 0.095, 0.86)
const BG_CARD_HI := Color(0.05, 0.12, 0.15, 0.94)
const LINE := Color(0.92, 0.93, 0.94, 0.16)
const LINE_HI := Color(0.4, 0.92, 1.0, 0.7)
const ACCENT := Color(1.0, 0.56, 0.2)
const CYAN := Color(0.4, 0.9, 1.0)
## Iron, copper, crystal, soil.
const RES_COLORS := [Color(0.92, 0.45, 0.32), Color(1.0, 0.66, 0.32), Color(0.76, 0.52, 1.0), Color(0.78, 0.6, 0.42)]
const RES_ICONS := ["iron", "copper", "crystal", "soil"]

# --- Type, geometry, motion -------------------------------------------------------------------------

const FS_TINY := 11
const FS_SMALL := 13
const FS_BODY := 15
const FS_LEAD := 18
const FS_TITLE := 24
const FS_BIG := 34
const FS_HUGE := 64

const CUT := 10.0                 # chamfer of a plate's cut corners (top-left, bottom-right)
const RADIUS := 3                 # the other corners
const PAD := 12.0
const GAP := 8.0
const STROKE := 1.0               # frame width
const SCAN_STEP := 3.0            # scanline pitch (the wrist screen's)

const T_FAST := 0.12
const T_MED := 0.22
const T_SLOW := 0.45
const PULSE_HZ := 1.6             # low-health pulse (the wrist screen's)
const BLINK := 0.7                # warning blink period
const TRAIL_HOLD := 0.35          # a damage trail waits this long...
const TRAIL_RATE := 0.55          # ...then drains this share per second

static var _fonts := {}
static var _num := {}
static var _caps := {}
static var _sb: StyleBoxFlat                         # draw_glass's style (mutated per call)
static var _sb2: StyleBoxFlat                        # draw_chamfer's
static var _tex := {}
static var _used := {}                               # texture instance id -> its used rect (tex_used_rect)


# =================================================================================================
# Scale, fonts
# =================================================================================================

## HUD scale: laid out at 1080p, scaled with the window height.
static func scale_k(vs: Vector2) -> float:
	return clampf(vs.y / 1080.0, 0.7, 2.0)


## A font size designed at 1080p, scaled by k (never below 10 px).
static func fs(size: float, k: float) -> int:
	return maxi(int(roundf(size * k)), 10)


static func font(weight := 400) -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Roboto", "Noto Sans", "DejaVu Sans", "Sans-Serif"])
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	f.hinting = TextServer.HINTING_LIGHT
	f.multichannel_signed_distance_field = false
	_fonts[weight] = f
	return f


## Tabular figures (every digit the same width): counters and timers do not jitter.
static func font_num(weight := 700) -> Font:
	if _num.has(weight):
		return _num[weight]
	var v := FontVariation.new()
	v.base_font = font(weight)
	var ts := TextServerManager.get_primary_interface()
	if ts != null:
		v.opentype_features = {ts.name_to_tag("tnum"): 1}
	_num[weight] = v
	return v


## Letter-spaced font for caps labels ("MALZEME", "YURT ÇEKİRDEĞİ"): spacing in px.
static func font_caps(weight := 700, spacing := 2) -> Font:
	var key := weight * 100 + clampi(spacing, -9, 40)
	if _caps.has(key):
		return _caps[key]
	var v := FontVariation.new()
	v.base_font = font(weight)
	v.spacing_glyph = spacing
	_caps[key] = v
	return v


# =================================================================================================
# Styleboxes and the theme
# =================================================================================================

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


## The signature plate: top-left and bottom-right corners cut at 45° (`cut` px), the other two
## nearly square.
static func chamfer_box(bg: Color, border := Color(0, 0, 0, 0), border_w := 0, cut := CUT, margin := 12.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_content_margin_all(margin)
	_cut(s, cut)
	return s


static func _cut(s: StyleBoxFlat, cut: float) -> void:
	var c := maxi(int(roundf(cut)), 0)
	s.corner_radius_top_left = c
	s.corner_radius_bottom_right = c
	s.corner_radius_top_right = mini(RADIUS, c)
	s.corner_radius_bottom_left = mini(RADIUS, c)
	s.corner_detail = 1                               # one segment per corner: a straight cut
	s.anti_aliasing = true
	s.anti_aliasing_size = 0.8


## Wrist-screen glass in a thin suit-white frame (`border` overrides the frame).
static func glass_box(margin := 12.0, border := LINE, cut := CUT, alpha := GLASS_A) -> StyleBoxFlat:
	return chamfer_box(Color(GLASS, alpha), border, 1, cut, margin)


static func panel_box(margin := 14.0) -> StyleBoxFlat:
	var s := chamfer_box(Color(GLASS, 0.86), Color(SUIT_WHITE, 0.2), 1, 16.0, margin)
	s.shadow_color = Color(0.0, 0.02, 0.03, 0.45)
	s.shadow_size = 14
	return s


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font(400)
	t.default_font_size = FS_BODY
	# Label / RichTextLabel: a soft dark outline (legible over sky and snow, never a black box).
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_shadow_color", "Label", Color(OUTLINE, 0.5))
	t.set_constant("shadow_offset_x", "Label", 1)
	t.set_constant("shadow_offset_y", "Label", 1)
	t.set_color("font_outline_color", "Label", OUTLINE)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_font("bold_font", "RichTextLabel", font(700))
	t.set_color("font_outline_color", "RichTextLabel", OUTLINE)
	# Button: glass plate; hover: cyan frame; pressed: orange; focus: a white frame.
	var bn := chamfer_box(Color(GLASS, 0.62), Color(SUIT_WHITE, 0.16), 1, 8.0, 0)
	_margins(bn, 16, 8)
	var bh := chamfer_box(Color(GLASS_HI, 0.9), Color(SCREEN_CYAN, 0.7), 1, 8.0, 0)
	_margins(bh, 16, 8)
	bh.border_width_left = 3
	bh.border_color = Color(SUIT_ORANGE, 0.9)
	var bp := chamfer_box(Color(SUIT_ORANGE, 0.26), Color(SUIT_ORANGE, 0.95), 1, 8.0, 0)
	_margins(bp, 16, 8)
	bp.border_width_left = 3
	var bf := chamfer_box(Color(0, 0, 0, 0), Color(SUIT_WHITE, 0.55), 1, 8.0, 0)
	bf.draw_center = false
	var bd := chamfer_box(Color(GLASS, 0.3), Color(SUIT_WHITE, 0.07), 1, 8.0, 0)
	_margins(bd, 16, 8)
	t.set_stylebox("normal", "Button", bn)
	t.set_stylebox("hover", "Button", bh)
	t.set_stylebox("pressed", "Button", bp)
	t.set_stylebox("hover_pressed", "Button", bp)
	t.set_stylebox("focus", "Button", bf)
	t.set_stylebox("disabled", "Button", bd)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color(1.0, 0.99, 0.97))
	t.set_color("font_pressed_color", "Button", Color(1.0, 0.97, 0.92))
	t.set_color("font_hover_pressed_color", "Button", Color(1.0, 0.97, 0.92))
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", FAINT)
	t.set_font("font", "Button", font(600))
	# LineEdit (the chat line, names, room codes).
	var le := chamfer_box(Color(GLASS, 0.82), Color(SUIT_WHITE, 0.2), 1, 7.0, 0)
	_margins(le, 12, 6)
	var lf := chamfer_box(Color(GLASS_HI, 0.9), Color(SCREEN_CYAN, 0.75), 1, 7.0, 0)
	_margins(lf, 12, 6)
	lf.border_width_bottom = 2
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", lf)
	t.set_stylebox("read_only", "LineEdit", le)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(FAINT, 0.9))
	t.set_color("caret_color", "LineEdit", SUIT_ORANGE)
	t.set_color("selection_color", "LineEdit", Color(SCREEN_CYAN, 0.3))
	t.set_color("font_selected_color", "LineEdit", Color(1.0, 0.99, 0.97))
	# HSlider: a thin track, the filled part orange, a round suit-white knob.
	var tr := StyleBoxFlat.new()
	tr.bg_color = Color(SUIT_WHITE, 0.12)
	tr.set_corner_radius_all(2)
	tr.content_margin_top = 2
	tr.content_margin_bottom = 2
	var ga := tr.duplicate() as StyleBoxFlat
	ga.bg_color = Color(SUIT_ORANGE, 0.85)
	var gh := tr.duplicate() as StyleBoxFlat
	gh.bg_color = Color(1.0, 0.66, 0.32)
	t.set_stylebox("slider", "HSlider", tr)
	t.set_stylebox("grabber_area", "HSlider", ga)
	t.set_stylebox("grabber_area_highlight", "HSlider", gh)
	t.set_icon("grabber", "HSlider", _knob_tex(false))
	t.set_icon("grabber_highlight", "HSlider", _knob_tex(true))
	t.set_icon("grabber_disabled", "HSlider", _knob_tex(false))
	# CheckButton: a toggle (orange track when on).
	t.set_icon("checked", "CheckButton", _toggle_tex(true, false))
	t.set_icon("unchecked", "CheckButton", _toggle_tex(false, false))
	t.set_icon("checked_disabled", "CheckButton", _toggle_tex(true, true))
	t.set_icon("unchecked_disabled", "CheckButton", _toggle_tex(false, true))
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		t.set_stylebox(st, "CheckButton", empty)
	t.set_stylebox("focus", "CheckButton", bf)
	# Panels, tooltips.
	t.set_stylebox("panel", "PanelContainer", glass_box(12.0))
	var tip := chamfer_box(Color(GLASS, 0.94), Color(SUIT_WHITE, 0.25), 1, 6.0, 8.0)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", TEXT)
	return t


static func _margins(s: StyleBoxFlat, h: float, v: float) -> void:
	s.content_margin_left = h
	s.content_margin_right = h
	s.content_margin_top = v
	s.content_margin_bottom = v


## Procedural 20 px slider knob: a suit-white disc with an orange core (hover: a brighter rim).
static func _knob_tex(hi: bool) -> Texture2D:
	var key := "knob_%s" % hi
	if _tex.has(key):
		return _tex[key]
	var n := 20
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(n, n) * 0.5
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			var a := clampf(8.6 - d, 0.0, 1.0)
			var col := SUIT_WHITE if not hi else Color(1.0, 0.98, 0.95)
			if d < 3.6:
				col = col.lerp(SUIT_ORANGE, clampf(3.6 - d, 0.0, 1.0))
			img.set_pixel(x, y, Color(col, a))
	var tex := ImageTexture.create_from_image(img)
	_tex[key] = tex
	return tex


## Procedural 44 × 22 toggle: a rounded track and a knob (on: orange track, knob right).
static func _toggle_tex(on: bool, disabled: bool) -> Texture2D:
	var key := "tog_%s_%s" % [on, disabled]
	if _tex.has(key):
		return _tex[key]
	var w := 44
	var h := 22
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var r := h * 0.5 - 1.0
	var kc := Vector2(w - h * 0.5, h * 0.5) if on else Vector2(h * 0.5, h * 0.5)
	var track := Color(SUIT_ORANGE, 0.9) if on else Color(SUIT_WHITE, 0.16)
	var knob := Color(1.0, 0.98, 0.95) if on else DIM
	if disabled:
		track.a *= 0.4
		knob.a *= 0.5
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5)
			# Capsule distance.
			var qx := clampf(p.x, h * 0.5, w - h * 0.5)
			var dt := p.distance_to(Vector2(qx, h * 0.5)) - r
			var ta := clampf(0.5 - dt, 0.0, 1.0)
			var dk := p.distance_to(kc) - (r - 3.0)
			var ka := clampf(0.5 - dk, 0.0, 1.0)
			var col := Color(track, track.a * ta)
			if ka > 0.0:
				col = Color(track.lerp(knob, ka), maxf(track.a * ta, knob.a * ka))
			img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_tex[key] = tex
	return tex


# =================================================================================================
# Node widgets
# =================================================================================================

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
	r.add_theme_color_override("font_shadow_color", Color(OUTLINE, 0.5))
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
	var bg := box(Color(SUIT_WHITE, 0.09), 1, Color(0, 0, 0, 0), 0, 0)
	var fg := box(fill, 1, Color(0, 0, 0, 0), 0, 0)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent:
		parent.add_child(b)
	return b


## Small "key cap" label, e.g. [1] or [Tab]: a suit-white plate with dark text.
static func keycap(parent: Node, key: String, size := 12) -> Label:
	var l := label(parent, key, size, INK, 700)
	var s := chamfer_box(Color(SUIT_WHITE, 0.88), Color(0, 0, 0, 0), 0, 4.0, 0)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 1
	s.content_margin_bottom = 2
	l.add_theme_stylebox_override("normal", s)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
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


## A caps section label after a short orange tick.
static func section_title(parent: Node, text: String, color := CYAN) -> HBoxContainer:
	var h := hbox(parent, 8)
	var dot := ColorRect.new()
	dot.color = SUIT_ORANGE
	dot.custom_minimum_size = Vector2(3, 14)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(dot)
	var l := label(h, text, 13, color, 700)
	l.add_theme_font_override("font", font_caps(700, 2))
	return h


## Turkish-aware upper case (i -> İ, ı -> I).
static func upper_tr(s: String) -> String:
	return s.replace("i", "İ").replace("ı", "I").to_upper()


# =================================================================================================
# Drawing helpers (static: call them from any _draw / draw signal with the CanvasItem)
# =================================================================================================

static func smooth(v: float) -> float:
	var x := clampf(v, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## Frame-rate independent approach of `cur` to `target` (rate ~ 1 / time constant).
static func approach(cur: float, target: float, rate: float, delta: float) -> float:
	return lerpf(cur, target, 1.0 - exp(-rate * delta))


## Health colour: green → amber below 60 % → red below 35 % (the wrist screen's).
static func hp_color(frac: float) -> Color:
	return GOOD.lerp(WARN, smoothstep(0.6, 0.35, frac)).lerp(BAD, smoothstep(0.35, 0.15, frac))


static func text_w(f: Font, s: String, size: int) -> float:
	return f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## The part of a (transparent-background) texture that holds pixels: thumbnails are rendered with a
## wide empty margin, so small slots draw only this region (draw_texture_rect_region). Cached per
## texture; the whole texture when it has no alpha to go by.
static func tex_used_rect(tex: Texture2D) -> Rect2:
	if tex == null:
		return Rect2()
	var id := tex.get_instance_id()
	if _used.has(id):
		return _used[id]
	var r := Rect2(Vector2.ZERO, tex.get_size())
	var img := tex.get_image()
	if img != null and not img.is_empty():
		var u := img.get_used_rect()
		if u.size.x > 2 and u.size.y > 2:
			r = Rect2(Vector2(u.position) - Vector2(2, 2), Vector2(u.size) + Vector2(4, 4)).intersection(r)
	_used[id] = r
	return r


## `s` cut to `max_w` px with "…" when it does not fit.
static func ellipsize(f: Font, s: String, size: int, max_w: float) -> String:
	if text_w(f, s, size) <= max_w:
		return s
	var t := s
	while t.length() > 1 and text_w(f, t.strip_edges() + "…", size) > max_w:
		t = t.left(t.length() - 1)
	return t.strip_edges() + "…"


## `s` word-wrapped into at most `max_lines` lines of `width` px; the last one ends in "…" when the
## text goes on. (Call it when the text or the size changes and keep the result.)
static func wrap_lines(f: Font, s: String, size: int, width: float, max_lines: int) -> PackedStringArray:
	var out := PackedStringArray()
	var words := s.split(" ", false)
	var line := ""
	var i := 0
	while i < words.size():
		var w: String = words[i]
		var cand := w if line == "" else line + " " + w
		if text_w(f, cand, size) <= width or line == "":
			line = cand
			i += 1
			continue
		if out.size() >= max_lines - 1:
			# The last line: it and the rest of the text, ellipsized.
			out.append(ellipsize(f, line + " " + " ".join(words.slice(i)), size, width))
			return out
		out.append(ellipsize(f, line, size, width))
		line = ""
	if line != "":
		out.append(ellipsize(f, line, size, width))
	return out


## Outlined text (baseline at pos.y). ol: outline px (0: a soft 1 px shadow instead).
static func draw_text(ci: CanvasItem, f: Font, pos: Vector2, s: String, size: int, col: Color, ol := 3) -> void:
	if s == "" or col.a <= 0.003:
		return
	if ol > 0:
		ci.draw_string_outline(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, ol, Color(OUTLINE, OUTLINE.a * col.a))
	else:
		ci.draw_string(f, pos + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(OUTLINE, 0.5 * col.a))
	ci.draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


## Right-aligned at `right`.
static func draw_text_r(ci: CanvasItem, f: Font, right: float, baseline: float, s: String, size: int, col: Color, ol := 3) -> float:
	var w := text_w(f, s, size)
	draw_text(ci, f, Vector2(right - w, baseline), s, size, col, ol)
	return w


## Centred on pos.x.
static func draw_text_c(ci: CanvasItem, f: Font, pos: Vector2, s: String, size: int, col: Color, ol := 3) -> float:
	var w := text_w(f, s, size)
	draw_text(ci, f, Vector2(pos.x - w * 0.5, pos.y), s, size, col, ol)
	return w


## A chamfered plate (fill, optional frame): the cut corners top-left and bottom-right.
static func draw_chamfer(ci: CanvasItem, r: Rect2, cut: float, fill: Color, border := Color(0, 0, 0, 0), bw := 1) -> void:
	if _sb2 == null:
		_sb2 = StyleBoxFlat.new()
	_sb2.bg_color = fill
	_sb2.draw_center = fill.a > 0.003
	_sb2.border_color = border
	_sb2.set_border_width_all(bw if border.a > 0.003 else 0)
	_sb2.shadow_size = 0
	_sb2.set_content_margin_all(0)
	_cut(_sb2, minf(cut, minf(r.size.x, r.size.y) * 0.5))
	ci.draw_style_box(_sb2, r)


## The HUD plate: wrist-screen glass (alpha a), faint scanlines, a thin suit-white frame; `hi` 0..1
## (active): the frame brightens toward `accent`, a soft glow and the suit's orange strip along the
## top edge. k: the HUD scale.
static func draw_glass(ci: CanvasItem, r: Rect2, k: float, accent := SCREEN_CYAN, hi := 0.0, a := 1.0, scan := true,
		cut := CUT) -> void:
	if _sb == null:
		_sb = StyleBoxFlat.new()
	var c := cut * k
	_sb.bg_color = Color(GLASS.lerp(GLASS_HI, hi * 0.6), lerpf(GLASS_A, 0.86, hi) * a)
	_sb.draw_center = true
	_sb.border_color = Color(SUIT_WHITE, lerpf(0.16, 0.5, hi) * a).lerp(Color(accent, 0.9 * a), hi * 0.55)
	_sb.set_border_width_all(1)
	_sb.shadow_color = Color(accent, 0.2 * hi * a)
	_sb.shadow_size = int(12.0 * k * hi)
	_sb.set_content_margin_all(0)
	_cut(_sb, minf(c, minf(r.size.x, r.size.y) * 0.5))
	ci.draw_style_box(_sb, r)
	if scan:
		var step := maxf(SCAN_STEP * k, 2.0)
		var y := r.position.y + step
		var sc := Color(0.3, 0.8, 1.0, 0.03 * a)
		while y < r.end.y - 2.0:
			ci.draw_rect(Rect2(r.position.x + 2.0, y, r.size.x - 4.0, 1.0), sc)
			y += step
	if hi > 0.01:
		var w := (r.size.x - c * 2.0 - 8.0 * k) * hi
		ci.draw_rect(Rect2(r.get_center().x - w * 0.5, r.position.y, w, maxf(2.0 * k, 2.0)), Color(SUIT_ORANGE, 0.95 * hi * a))


## Segmented bar: n segments over r (gap px between), the share `frac` lit in col; `trail` (> frac):
## the damage trail drawn light over the segments it covers; `heal` (< frac): the healed part.
static func draw_seg_bar(ci: CanvasItem, r: Rect2, n: int, frac: float, col: Color, gap := 2.0, trail := -1.0,
		trail_col := Color(1.0, 0.92, 0.86, 0.85), right_to_left := false) -> void:
	n = maxi(n, 1)
	var sw := (r.size.x - gap * (n - 1)) / n
	if sw <= 0.5:
		return
	var off := Color(col, 0.12 * col.a + 0.02)
	for i in n:
		var i0 := float(i) / n
		var i1 := float(i + 1) / n
		var x := r.position.x + i * (sw + gap)
		if right_to_left:
			x = r.end.x - (i + 1) * sw - i * gap
		var seg := Rect2(x, r.position.y, sw, r.size.y)
		# The lit part of this segment (partial at the edge), then the trail part.
		var lit := clampf((frac - i0) / (i1 - i0), 0.0, 1.0)
		ci.draw_rect(seg, off)
		if lit > 0.0:
			var lw := sw * lit
			ci.draw_rect(Rect2(seg.position.x + (sw - lw if right_to_left else 0.0), seg.position.y, lw, seg.size.y), col)
		if trail > frac:
			var t0 := clampf((frac - i0) / (i1 - i0), 0.0, 1.0)
			var t1 := clampf((trail - i0) / (i1 - i0), 0.0, 1.0)
			if t1 > t0:
				var tx := sw * t0
				var tw := sw * (t1 - t0)
				var px := seg.position.x + (sw - tx - tw if right_to_left else tx)
				ci.draw_rect(Rect2(px, seg.position.y, tw, seg.size.y), trail_col)


## A key cap: a suit-white chamfered plate with the key in dark (on: orange plate). Returns its width.
static func draw_key(ci: CanvasItem, pos: Vector2, key: String, k: float, on := false, a := 1.0, size := 12) -> float:
	var f := font(700)
	var fsz := fs(size, k)
	var tw := text_w(f, key, fsz)
	var h := roundf(fsz * 1.45)
	var w := maxf(tw + 10.0 * k, h)
	var r := Rect2(pos, Vector2(w, h))
	draw_chamfer(ci, r, 4.0 * k, Color(SUIT_ORANGE, 0.95 * a) if on else Color(SUIT_WHITE, 0.88 * a))
	ci.draw_string(f, Vector2(pos.x + (w - tw) * 0.5, pos.y + h * 0.5 + fsz * 0.36), key, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz,
			Color(INK, a))
	return w


## A progress ring: a dark track and the arc from 12 o'clock clockwise.
static func draw_ring(ci: CanvasItem, c: Vector2, r: float, frac: float, col: Color, w := 3.0, track := true) -> void:
	if track:
		ci.draw_arc(c, r, 0.0, TAU, 48, Color(OUTLINE, 0.5 * col.a), w + 2.5, true)
		ci.draw_arc(c, r, 0.0, TAU, 48, Color(SUIT_WHITE, 0.14 * col.a), maxf(w * 0.5, 1.0), true)
	if frac > 0.002:
		ci.draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * clampf(frac, 0.0, 1.0), 48, col, w, true)


## Diagonal hazard stripes inside r (alert plates).
static func draw_hazard(ci: CanvasItem, r: Rect2, col: Color, step := 8.0, t := 0.0) -> void:
	var x := r.position.x - r.size.y + fmod(t * step * 2.0, step * 2.0) - step * 2.0
	while x < r.end.x:
		var x0 := maxf(x, r.position.x)
		var x1 := minf(x + step, r.end.x)
		if x1 > x0:
			# A parallelogram clipped to the rect (approximated by a quad per stripe).
			var a := Vector2(x0, r.end.y)
			var b := Vector2(x1, r.end.y)
			var c := Vector2(minf(x1 + r.size.y, r.end.x), r.position.y)
			var d := Vector2(minf(x0 + r.size.y, r.end.x), r.position.y)
			if c.x > d.x + 0.5:
				ci.draw_colored_polygon(PackedVector2Array([a, b, c, d]), col)
		x += step * 2.0


## Corner brackets around r (a target frame), arms of `arm` px.
static func draw_corners(ci: CanvasItem, r: Rect2, arm: float, col: Color, w := 2.0) -> void:
	var pts := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	var sx := [1.0, -1.0, -1.0, 1.0]
	var sy := [1.0, 1.0, -1.0, -1.0]
	for i in 4:
		var p: Vector2 = pts[i]
		ci.draw_line(p, p + Vector2(arm * float(sx[i]), 0.0), col, w, true)
		ci.draw_line(p, p + Vector2(0.0, arm * float(sy[i])), col, w, true)


## A warning triangle with "!" (centre c, size s).
static func draw_alert_icon(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var tri := PackedVector2Array([c + Vector2(0, -s), c + Vector2(s * 1.05, s * 0.8), c + Vector2(-s * 1.05, s * 0.8)])
	ci.draw_colored_polygon(tri, col)
	var ink := Color(INK, col.a)
	ci.draw_line(c + Vector2(0, -s * 0.42), c + Vector2(0, s * 0.22), ink, maxf(1.5, s * 0.2), true)
	ci.draw_circle(c + Vector2(0, s * 0.52), maxf(1.0, s * 0.12), ink)
