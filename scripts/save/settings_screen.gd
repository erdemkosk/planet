extends Control
## Ayarlar (opened from the pause and start menus): mouse sensitivity, invert Y, field of view,
## master volume, fullscreen and V-Sync. Changes apply at once and are written when the screen
## closes (Esc / "Geri"). Values live in settings.gd.

signal closed

const UI := preload("res://scripts/ui/ui_style.gd")
const Kit := preload("res://scripts/save/menu_kit.gd")
const Settings := preload("res://scripts/save/settings.gd")

var _panel: PanelContainer
var _back: Button
var _rows: VBoxContainer
var _first: Control
var _full: CheckButton


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = UI.panel(self, UI.panel_box(24))
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(640, 0)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.draw.connect(func() -> void: _panel.draw_rect(Rect2(Vector2(30, 0), Vector2(150, 3)), UI.SUIT_ORANGE))
	var v := UI.vbox(_panel, 12)
	var head := UI.hbox(v, 12)
	var hv := UI.vbox(head, 2)
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	Kit.heading(hv, "OYUN", 12, UI.SUIT_ORANGE.lightened(0.15), 3)
	UI.label(hv, "Ayarlar", 30, UI.TEXT, 700)
	_back = Kit.menu_button(head, "Geri", "Esc", "", 150)
	_back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_back.pressed.connect(close)
	UI.rule(v)
	_rows = UI.vbox(v, 14)
	UI.section_title(_rows, "KONTROL")
	_first = _slider("Fare hassasiyeti", 0.3, 2.5, 0.05, Settings.mouse_sens, _set_sens, _fmt_mult)
	_check("Y eksenini ters çevir", Settings.invert_y, _set_invert)
	UI.section_title(_rows, "GÖRÜNTÜ")
	_slider("Görüş alanı (FOV)", 60.0, 100.0, 1.0, Settings.fov, _set_fov, _fmt_deg)
	_slider("Hareket bulanıklığı", 0.0, 2.0, 1.0, float(Settings.motion_blur), _set_motion_blur, _fmt_blur)
	_slider("Kask efektleri", 0.0, 2.0, 1.0, float(Settings.helmet_fx), _set_helmet_fx, _fmt_helmet)
	_slider("Arka plan savaşı", 0.0, 2.0, 1.0, float(Settings.space_battle), _set_space_battle, _fmt_space_battle)
	_full = _check("Tam ekran  (F11)", DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN, _set_full)
	_check("Dikey senkron (V-Sync)", Settings.vsync, _set_vsync)
	_slider("HUD", 0.0, 2.0, 1.0, float(Settings.hud_mode), _set_hud_mode, _fmt_hud)
	UI.label(_rows, "Sade: nişangâh, can, cephane; gerisi gerektiğinde. Alt basılı: hepsi.", 12, UI.FAINT)
	_check("Hasar sayıları", Settings.damage_numbers, _set_damage_numbers)
	UI.section_title(_rows, "SES")
	_slider("Ana ses", 0.0, 1.0, 0.01, Settings.master_volume, _set_volume, _fmt_pct)
	UI.rule(v)
	var foot := UI.label(v, "Değişiklikler hemen uygulanır ve kaydedilir.", 13, UI.FAINT)
	foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _set_sens(x: float) -> void:
	Settings.mouse_sens = x


func _set_throttle_hold(on: bool) -> void:
	Settings.throttle_hold = on


func _set_invert(on: bool) -> void:
	Settings.invert_y = on


func _set_fov(x: float) -> void:
	Settings.fov = x
	Settings.apply(false)


func _set_full(on: bool) -> void:
	Settings.set_fullscreen(on)


func _set_damage_numbers(on: bool) -> void:
	Settings.damage_numbers = on


## HUD density: Sade / Normal / Detaylı (scripts/ui/hud_mode.gd; the widgets follow at once).
func _set_hud_mode(x: float) -> void:
	Settings.set_hud_mode(roundi(x))


func _fmt_hud(x: float) -> String:
	return ["Sade", "Normal", "Detaylı"][clampi(roundi(x), 0, 2)]


## Camera motion blur level (scripts/ui/motion_blur.gd reads it every frame).
func _set_motion_blur(x: float) -> void:
	Settings.motion_blur = clampi(roundi(x), 0, 2)


func _fmt_blur(x: float) -> String:
	return ["Kapalı", "Düşük", "Orta"][clampi(roundi(x), 0, 2)]


## Inside-the-helmet effects (scripts/ui/helmet_fx.gd reads it every frame): visor, helmet
## acoustics, suit sounds, breath camera.
func _set_helmet_fx(x: float) -> void:
	Settings.helmet_fx = clampi(roundi(x), 0, 2)


func _fmt_helmet(x: float) -> String:
	return ["Kapalı", "Düşük", "Orta"][clampi(roundi(x), 0, 2)]


## Cosmetic far-off space battle (scripts/fx/space_battle.gd rebuilds itself when this changes).
func _set_space_battle(x: float) -> void:
	Settings.space_battle = clampi(roundi(x), 0, 2)


func _fmt_space_battle(x: float) -> String:
	return ["Kapalı", "Düşük", "Yüksek"][clampi(roundi(x), 0, 2)]


func _set_vsync(on: bool) -> void:
	Settings.vsync = on
	Settings.apply(false)


func _set_volume(x: float) -> void:
	Settings.master_volume = x
	Settings.apply(false)


func _fmt_mult(x: float) -> String:
	return "%.2f×" % x


func _fmt_deg(x: float) -> String:
	return "%d°" % int(x)


func _fmt_pct(x: float) -> String:
	return "%%%d" % int(round(x * 100.0))


func open() -> void:
	visible = true
	# F11 may have changed the window since this screen was built.
	_full.set_pressed_no_signal(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN)
	_panel.reset_size()
	_panel.offset_left = -_panel.size.x * 0.5
	_panel.offset_right = _panel.size.x * 0.5
	_panel.offset_top = -_panel.size.y * 0.5
	_panel.offset_bottom = _panel.size.y * 0.5
	_panel.modulate.a = 0.0
	create_tween().tween_property(_panel, "modulate:a", 1.0, 0.16)
	if _first != null:
		_first.call_deferred("grab_focus")


func close() -> void:
	Settings.save()
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## Label · slider · value text. Returns the slider (keyboard focus).
func _slider(title: String, lo: float, hi: float, step: float, value: float, on_change: Callable,
		fmt: Callable) -> HSlider:
	var row := UI.hbox(_rows, 14)
	var l := UI.label(row, title, 15, UI.TEXT, 600)
	l.custom_minimum_size.x = 230
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(260, 24)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(s)
	var vl := UI.label(row, fmt.call(value), 15, UI.SUIT_ORANGE.lightened(0.2), 700)
	vl.add_theme_font_override("font", UI.font_num(700))
	vl.custom_minimum_size.x = 64
	vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.value_changed.connect(_on_slider.bind(on_change, fmt, vl))
	return s


func _on_slider(x: float, on_change: Callable, fmt: Callable, vl: Label) -> void:
	on_change.call(x)
	vl.text = fmt.call(x)


func _check(title: String, on: bool, on_change: Callable) -> CheckButton:
	var row := UI.hbox(_rows, 14)
	var l := UI.label(row, title, 15, UI.TEXT, 600)
	l.custom_minimum_size.x = 230
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var c := CheckButton.new()
	c.button_pressed = on
	c.focus_mode = Control.FOCUS_ALL
	row.add_child(c)
	c.toggled.connect(on_change)
	return c
