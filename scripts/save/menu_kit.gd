extends RefCounted
## Widgets for the pause / start / slot menus (same palette and fonts as scripts/ui/ui_style.gd):
## wide menu buttons with a sliding accent bar, slot rows with thumbnails, a frosted backdrop,
## letter-spaced headings and Turkish time / duration formatting.

const UI := preload("res://scripts/ui/ui_style.gd")

const BLUR_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 1.0) = 1.0;
uniform float side_dark = 1.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 sharp = texture(screen_tex, uv).rgb;
	vec3 soft = textureLod(screen_tex, uv, 2.5).rgb * 0.45 + textureLod(screen_tex, uv, 4.0).rgb * 0.55;
	vec3 c = mix(sharp, soft, amount);
	float lum = dot(c, vec3(0.3, 0.59, 0.11));
	c = mix(c, vec3(lum) * vec3(0.62, 0.8, 1.0), 0.4 * amount);
	c *= mix(1.0, 0.5, amount);
	float side = smoothstep(0.66, 0.0, uv.x) * side_dark;
	c *= mix(1.0, 0.5, side * amount);
	float vig = smoothstep(1.2, 0.3, length((uv - 0.5) * vec2(1.3, 1.0)));
	c *= mix(1.0, mix(0.55, 1.0, vig), amount);
	COLOR = vec4(c, 1.0);
}
"""

static var _thumbs := {}       # path -> [modified time, ImageTexture]
static var _spaced := {}


## Bold font with extra letter spacing for headings.
static func spaced_font(weight: int, spacing: int) -> Font:
	return UI.font_caps(weight, spacing)          # (the design system's cache)


static func heading(parent: Node, text: String, size: int, color: Color, spacing := 3, weight := 700) -> Label:
	var l := UI.label(parent, text, size, color, weight)
	l.add_theme_font_override("font", spaced_font(weight, spacing))
	return l


static func backdrop(parent: Node) -> ColorRect:
	var r := ColorRect.new()
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_STOP
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = BLUR_SHADER
	m.shader = sh
	r.material = m
	parent.add_child(r)
	return r


## The design system's plate (scripts/ui/ui_style.gd chamfer_box: the top-left and bottom-right
## corners cut by `radius`) with an accent bar along the left edge.
static func _sb(bg: Color, bar: Color, bar_w: int, radius := 8) -> StyleBoxFlat:
	var s := UI.chamfer_box(bg, bar, 0, float(radius), 0)
	s.border_width_left = bar_w
	return s


## Wide menu button: title, optional second line and key hint. `danger` tints the accent red.
## Glass plate; hover / focus: brighter glass, the suit's orange bar on the left (danger: red).
static func menu_button(parent: Node, title: String, key := "", sub := "", width := 380.0, danger := false) -> Button:
	var accent: Color = UI.BAD if danger else UI.SUIT_ORANGE
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(width, 66.0 if sub != "" else 50.0)
	b.add_theme_stylebox_override("normal", _sb(Color(UI.GLASS, 0.42), accent, 0))
	b.add_theme_stylebox_override("hover", _sb(Color(UI.GLASS_HI, 0.88), accent, 3))
	b.add_theme_stylebox_override("pressed", _sb(Color(accent.darkened(0.55), 0.9), accent, 3))
	b.add_theme_stylebox_override("hover_pressed", _sb(Color(accent.darkened(0.55), 0.9), accent, 3))
	b.add_theme_stylebox_override("focus", _sb(Color(UI.GLASS_HI, 0.0), accent, 3))
	b.add_theme_stylebox_override("disabled", _sb(Color(UI.GLASS, 0.22), accent, 0))
	var hb := UI.hbox(b, 10)
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 22
	hb.offset_right = -16
	var vb := UI.vbox(hb, 1)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tl := UI.label(vb, title, 19, UI.TEXT, 600)
	var sl: Label = null
	if sub != "":
		sl = UI.label(vb, sub, 13, UI.DIM)
		sl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sl.custom_minimum_size.x = 60
	if key != "":
		var kc := UI.keycap(hb, key, 12)
		kc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		kc.modulate.a = 0.75
	b.set_meta("title", tl)
	b.set_meta("sub", sl)
	b.set_meta("sub_text", sub)
	b.set_meta("box", hb)
	var lit := func(on: bool) -> void:
		if not is_instance_valid(b) or b.disabled:
			return
		tl.add_theme_color_override("font_color", Color(1.0, 0.99, 0.97) if on else UI.TEXT)
		var tw := b.create_tween()
		tw.tween_property(hb, "offset_left", 30.0 if on else 22.0, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	b.focus_entered.connect(lit.bind(true))
	b.focus_exited.connect(lit.bind(false))
	# Mouse hover moves keyboard focus, so only one button ever looks selected.
	b.mouse_entered.connect(func() -> void:
		if not b.disabled:
			b.grab_focus())
	if parent:
		parent.add_child(b)
	return b


## Changes a menu button's second line (e.g. confirmation prompts); "" restores the original.
static func set_sub(b: Button, text: String, color := UI.DIM) -> void:
	var sl = (b.get_meta("sub") if b.has_meta("sub") else null)
	if sl == null:
		return
	(sl as Label).text = text if text != "" else str(b.get_meta("sub_text", ""))
	(sl as Label).add_theme_color_override("font_color", color)


## Rounded thumbnail frame (texture or a placeholder glyph).
static func thumb(parent: Node, tex: Texture2D, size: Vector2, placeholder := "") -> PanelContainer:
	var p := UI.panel(parent, UI.box(Color(0.02, 0.035, 0.055, 0.9), 6, UI.LINE, 1, 1))
	p.custom_minimum_size = size
	p.clip_contents = true
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.custom_minimum_size = size - Vector2(2, 2)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(tr)
	else:
		var c := CenterContainer.new()
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(c)
		UI.label(c, placeholder, int(size.y * 0.3), UI.FAINT, 300)
	return p


## Thumbnail texture of a save (cached while the file is unchanged).
static func load_thumb(path: String) -> Texture2D:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var mt := FileAccess.get_modified_time(path)
	var c = _thumbs.get(path)
	if c != null and int(c[0]) == mt:
		return c[1]
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	var tex := ImageTexture.create_from_image(img)
	_thumbs[path] = [mt, tex]
	return tex


static func forget_thumb(path: String) -> void:
	_thumbs.erase(path)


## Row button for the slot screen (thumbnail, title, location, date · play time, action hint).
static func slot_row(parent: Node, meta: Dictionary, action: String, empty := false) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 122)
	b.add_theme_stylebox_override("normal", _sb(Color(0.06, 0.09, 0.13, 0.6), UI.CYAN, 0, 10))
	b.add_theme_stylebox_override("hover", _sb(Color(0.1, 0.16, 0.23, 0.92), UI.CYAN, 3, 10))
	b.add_theme_stylebox_override("pressed", _sb(Color(0.15, 0.24, 0.32, 0.95), UI.CYAN, 3, 10))
	b.add_theme_stylebox_override("focus", _sb(Color(0, 0, 0, 0), UI.CYAN, 3, 10))
	var hb := UI.hbox(b, 18)
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 10
	hb.offset_top = 7
	hb.offset_bottom = -7
	hb.offset_right = -20
	var tex: Texture2D = null if empty else load_thumb(str(meta.get("thumb_path", "")))
	var tp := thumb(hb, tex, Vector2(192, 108), "+" if empty else "")
	tp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var vb := UI.vbox(hb, 3)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.label(vb, str(meta.get("title", "")), 19, UI.TEXT, 700)
	if empty:
		UI.label(vb, "Boş yuva", 15, UI.FAINT)
	else:
		var loc := str(meta.get("location", ""))
		var dl := str(meta.get("daylight", ""))
		UI.label(vb, loc + ("  ·  " + dl if dl != "" else ""), 15, UI.TEXT)
		var when := int(meta.get("saved_at", 0))
		UI.label(vb, "%s  ·  %s  ·  %s oynandı" % [date_text(when), ago(when), duration(float(meta.get("play_time", 0.0)))],
				13, UI.DIM)
	var al := heading(hb, action, 13, UI.CYAN, 2)
	al.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.set_meta("action", al)
	b.set_meta("action_text", action)
	b.mouse_entered.connect(func() -> void: b.grab_focus())
	if parent:
		parent.add_child(b)
	return b


static func set_action(b: Button, text: String, color := UI.CYAN) -> void:
	var al = (b.get_meta("action") if b.has_meta("action") else null)
	if al == null:
		return
	(al as Label).text = text if text != "" else str(b.get_meta("action_text", ""))
	(al as Label).add_theme_color_override("font_color", color)


## "az önce", "12 dk önce", "3 sa önce", "dün", "4 gün önce" or the date.
static func ago(unix: int) -> String:
	if unix <= 0:
		return "—"
	var d := int(Time.get_unix_time_from_system()) - unix
	if d < 60:
		return "az önce"
	if d < 3600:
		return "%d dk önce" % (d / 60)
	if d < 86400:
		return "%d sa önce" % (d / 3600)
	if d < 172800:
		return "dün"
	if d < 7 * 86400:
		return "%d gün önce" % (d / 86400)
	return date_text(unix)


static func date_text(unix: int) -> String:
	if unix <= 0:
		return "—"
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var t := Time.get_datetime_dict_from_unix_time(unix + bias * 60)
	return "%02d.%02d.%d %02d:%02d" % [t["day"], t["month"], t["year"], t["hour"], t["minute"]]


static func duration(sec: float) -> String:
	var m := int(sec / 60.0)
	if m < 1:
		return "1 dk'dan az"
	if m < 60:
		return "%d dk" % m
	return "%d sa %d dk" % [m / 60, m % 60]
