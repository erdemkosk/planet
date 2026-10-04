extends CanvasLayer
## On-screen UI (Turkish), deliberately small:
##   - crosshair (scripts/ui/crosshair.gd): tinted by the drill mode, ring over interactables, the
##     jetpack fuel arc while it burns or refills; guns hide it and draw their own
##   - interact prompt (bottom centre) and toast messages (top centre)
##   - right panel: MALZEME (material, m³), the held item, the gun's "mag / reserve" and the price
##     of a round in material, or the drill's mode and brush radius
##   - health (bottom left) and the red damage flash (scripts/ui/damage_ui.gd)
##   - a black fade for respawns
## API used by the game: set_prompt(text), show_message(text, seconds), on_player_damaged(amount,
## from_pos), fade_to_black(t) / fade_from_black(t) -> Tween, blocks_input(), `crosshair`.

const UI := preload("res://scripts/ui/ui_style.gd")
const Crosshair := preload("res://scripts/ui/crosshair.gd")
const DamageUi := preload("res://scripts/ui/damage_ui.gd")

const PANEL_W := 250.0

var crosshair: Control
var damage: Control
var _root: Control
var _panel: Control
var _prompt: Label
var _toast: Label
var _hint: RichTextLabel
var _fade: ColorRect
var _toast_t := 0.0
var _font: Font
var _font_b: Font
var _key := ""
var _mat_pulse := 0.0
var _last_mat := 0.0


func _ready() -> void:
	layer = 5
	_font = UI.font(500)
	_font_b = UI.font(700)
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UI.make_theme()
	add_child(_root)

	damage = DamageUi.new()
	damage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(damage)

	crosshair = Crosshair.new()
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(crosshair)

	_panel = Control.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.draw.connect(_draw_panel)
	_root.add_child(_panel)

	_prompt = _label(18, Control.PRESET_CENTER_BOTTOM, -150.0)
	_toast = _label(20, Control.PRESET_CENTER_TOP, 70.0)
	_toast.modulate.a = 0.0

	_hint = RichTextLabel.new()
	_hint.bbcode_enabled = true
	_hint.fit_content = true
	_hint.scroll_active = false
	_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_font_override("normal_font", _font)
	_hint.add_theme_font_override("bold_font", _font_b)
	_hint.add_theme_font_size_override("normal_font_size", 15)
	_hint.add_theme_font_size_override("bold_font_size", 15)
	_hint.add_theme_constant_override("outline_size", 4)
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.offset_left = -420.0
	_hint.offset_right = 420.0
	_hint.offset_top = -46.0
	_hint.offset_bottom = -20.0
	_root.add_child(_hint)

	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_fade)


func _label(size: int, preset: Control.LayoutPreset, y: float) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", _font_b)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", UI.TEXT)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.65))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.set_anchors_and_offsets_preset(preset)
	l.offset_left = -500.0
	l.offset_right = 500.0
	l.offset_top = y
	l.offset_bottom = y + 30.0
	_root.add_child(l)
	return l


# --- API ------------------------------------------------------------------------------------------

func set_prompt(text: String) -> void:
	if _prompt.text != text:
		_prompt.text = ("[F] " + text) if text != "" else ""


func show_message(text: String, seconds := 2.5) -> void:
	_toast.text = text
	_toast_t = seconds
	_toast.modulate.a = 1.0


func on_player_damaged(amount: float, from_pos: Vector3) -> void:
	damage.hit(amount, from_pos)


## The pause menu (and later other panels) owns the mouse.
func blocks_input() -> bool:
	return Game.ui_panel_open()


func fade_to_black(t := 0.6) -> Tween:
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, t)
	return tw


func fade_from_black(t := 0.8) -> Tween:
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 0.0, t)
	return tw


# --- Per frame ------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t < 0.4:
			_toast.modulate.a = clampf(_toast_t / 0.4, 0.0, 1.0)
	if Game.material > _last_mat + 0.001:
		_mat_pulse = 1.0
	_last_mat = Game.material
	_mat_pulse = maxf(_mat_pulse - delta * 3.0, 0.0)
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return
	var it = p.items[p.current_item] if p.items.size() > p.current_item else null
	var on_foot: bool = p.vehicle == null and not p.is_ragdolled()
	# Crosshair: the drill's colour and state, the interact ring, the jetpack fuel arc.
	crosshair.visible = on_foot
	if it != null:
		crosshair.color = it.crosshair_color() if it.has_method("crosshair_color") else it.accent_color()
		crosshair.using = it.using
		crosshair.valid = it.get("aim_valid") != false
	crosshair.has_target = p.interact_target != null
	crosshair.fuel = p.jet_fuel_frac()
	crosshair.jetting = p.jetting
	# Drill hint line (mode, radius, controls).
	var hint := ""
	if on_foot and it != null and it.equipped and str(it.item_id) in ["terrain", "build"]:
		hint = "[center]%s[/center]" % it.hud_hint()
	if _hint.text != hint:
		_hint.text = hint
	# Redraw the panel when something shown changed.
	var key := "%d|%d|%s|%d|%d|%d|%.2f" % [int(Game.material), int(p.hp), str(it.item_id) if it != null else "",
			_mag(it), _reserve(it), int(it.get("radius") * 10.0) if it != null and it.get("radius") != null else 0,
			_mat_pulse]
	if key != _key or (it != null and (it.get("reloading") == true or it.has_method("hud_panel_lines"))):
		_key = key
		_panel.queue_redraw()


func _mag(it) -> int:
	if it == null:
		return -1
	if it.has_method("mag_count"):
		return int(it.mag_count())
	if it.get("mag") != null:
		return int(it.mag)
	return -1


func _reserve(it) -> int:
	if it != null and it.has_method("reserve_stock"):
		return int(it.reserve_stock())
	return -1


# --- Drawing --------------------------------------------------------------------------------------

func _draw_panel() -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return
	var vs := _panel.size
	var x := vs.x - PANEL_W - 24.0
	var y := 26.0
	var w := PANEL_W
	# --- Material
	var sb := UI.box(Color(0.03, 0.05, 0.08, 0.62), 12, Color(UI.ACCENT, 0.35 + 0.4 * _mat_pulse), 1, 0)
	_panel.draw_style_box(sb, Rect2(Vector2(x, y), Vector2(w, 74)))
	_panel.draw_rect(Rect2(Vector2(x, y + 14), Vector2(3, 46)), Color(UI.ACCENT, 0.9))
	_text(Vector2(x + 16, y + 24), "MALZEME", 13, UI.DIM, _font_b)
	var amount := "%d" % int(floorf(Game.material + 0.0001))
	var big := int(34.0 + 4.0 * _mat_pulse)
	_text(Vector2(x + 16, y + 62), amount, big, UI.TEXT.lerp(UI.ACCENT, _mat_pulse * 0.6), _font_b)
	var aw := _font_b.get_string_size(amount, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
	_text(Vector2(x + 22 + aw, y + 62), "m³", 17, UI.DIM, _font)
	y += 84.0
	# --- Held item
	var it = p.items[p.current_item] if p.items.size() > p.current_item else null
	if it != null:
		var col: Color = it.accent_color()
		var h := 70.0
		var sb2 := UI.box(Color(0.03, 0.05, 0.08, 0.55), 12, Color(col, 0.35), 1, 0)
		_panel.draw_style_box(sb2, Rect2(Vector2(x, y), Vector2(w, h)))
		_panel.draw_rect(Rect2(Vector2(x, y + 12), Vector2(3, h - 24)), Color(col, 0.9))
		_text(Vector2(x + 16, y + 22), UI.upper_tr(str(it.item_name)), 13, col.lightened(0.25), _font_b)
		var mag := _mag(it)
		if mag >= 0:
			# Gun: "mag / reserve", the round price below it.
			var mc := Color(0.92, 0.96, 1.0) if mag > 0 else UI.BAD
			_text(Vector2(x + 16, y + 52), str(mag), 28, mc, _font_b)
			var mw := _font_b.get_string_size(str(mag), HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
			_text(Vector2(x + 22 + mw, y + 52), "/ %d" % _reserve(it), 17, UI.DIM, _font)
			var cost: float = float(it.round_cost()) if it.has_method("round_cost") else 0.0
			if cost > 0.0:
				var ct := "yedek bitince: %s m³/mermi" % String.num(cost, 2)
				_text(Vector2(x + 16, y + h - 4), ct, 11, UI.FAINT, _font)
			if it.get("reloading") == true:
				_text(Vector2(x + w - 92, y + 22), "DOLDURULUYOR", 10, col.lightened(0.3), _font_b)
		elif it.get("radius") != null:
			# Drill: mode and brush radius.
			_text(Vector2(x + 16, y + 50), str(it.mode_name()), 22, col, _font_b)
			_text(Vector2(x + 16, y + h - 4), "fırça %s m" % String.num(float(it.radius), 1), 12, UI.DIM, _font)
		elif it.has_method("hud_panel_lines"):
			# Items with their own lines (build tool: [title, detail, detail colour]).
			var ln: Array = it.hud_panel_lines()
			_text(Vector2(x + 16, y + 48), str(ln[0]), 18, UI.TEXT, _font_b)
			_text(Vector2(x + 16, y + h - 4), str(ln[1]), 11, ln[2] if ln.size() > 2 else UI.DIM, _font)
		y += h + 10.0
	_text(Vector2(x + 16, y + 12), "1 Kazı  ·  2 Tüfek  ·  3 Pompalı  ·  4 İnşa  ·  L fener", 11, UI.FAINT, _font)
	# --- Health (bottom left)
	var hp: float = float(p.hp)
	var hpmax: float = maxf(float(p.hp_max), 1.0)
	var hx := 24.0
	var hy := vs.y - 46.0
	var hw := 220.0
	var frac := clampf(hp / hpmax, 0.0, 1.0)
	var hc := UI.GOOD.lerp(UI.WARN, smoothstep(0.6, 0.35, frac)).lerp(UI.BAD, smoothstep(0.35, 0.15, frac))
	_panel.draw_style_box(UI.box(Color(0.03, 0.05, 0.08, 0.55), 10, Color(hc, 0.3), 1, 0), Rect2(Vector2(hx, hy - 22), Vector2(hw, 40)))
	_text(Vector2(hx + 12, hy - 4), "CAN", 12, UI.DIM, _font_b)
	_text(Vector2(hx + hw - 44, hy - 4), "%d" % int(ceilf(hp)), 15, hc, _font_b)
	_panel.draw_rect(Rect2(Vector2(hx + 48, hy - 12), Vector2(hw - 100, 6)), Color(1, 1, 1, 0.1))
	_panel.draw_rect(Rect2(Vector2(hx + 48, hy - 12), Vector2((hw - 100) * frac, 6)), hc)


func _text(pos: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	_panel.draw_string(f, pos + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.55 * col.a))
	_panel.draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
