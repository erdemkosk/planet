extends CanvasLayer
## Pause menu (Esc): Devam · Ayarlar · Çıkış, drawn over the paused game. There is no save system
## yet. Game._unhandled_input opens it (Game.pause_menu); Esc or "Devam" closes it. Runs while the
## tree is paused (process_mode ALWAYS). Look: scripts/ui/ui_style.gd + menu_kit.gd.

const UI := preload("res://scripts/ui/ui_style.gd")
const Kit := preload("res://scripts/save/menu_kit.gd")
const SettingsScreen := preload("res://scripts/save/settings_screen.gd")

var _root: Control
var _bg_mat: ShaderMaterial
var _menu: Control
var _buttons: VBoxContainer
var _settings: Control              # settings_screen.gd
var _sfx: AudioStreamPlayer


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = UI.make_theme()
	_root.visible = false
	add_child(_root)
	var bg := Kit.backdrop(_root)
	_bg_mat = bg.material
	_build_menu()
	_settings = SettingsScreen.new()
	_settings.visible = false
	_root.add_child(_settings)
	_settings.closed.connect(_on_settings_closed)
	_sfx = AudioStreamPlayer.new()
	_sfx.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_sfx)
	get_viewport().size_changed.connect(_fit)
	_fit()


## Laid out at 1080p and scaled with the window height (the design system's rule): the root is
## sized to the window / k and scaled by k.
func _fit() -> void:
	var vs := get_viewport().get_visible_rect().size
	var k := clampf(vs.y / 1080.0, 0.75, 2.0)
	_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_root.position = Vector2.ZERO
	_root.size = vs / k
	_root.scale = Vector2(k, k)

func _build_menu() -> void:
	_menu = Control.new()
	_menu.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	_menu.offset_left = 0
	_menu.offset_right = 540
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_menu)
	var hb := UI.hbox(_menu, 26)
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 74
	var line := ColorRect.new()
	line.color = Color(UI.SUIT_ORANGE, 0.85)                  # the suit's band (scripts/ui/ui_style.gd)
	line.custom_minimum_size = Vector2(3, 360)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(line)
	var col := UI.vbox(hb, 0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	Kit.heading(col, "OYUN SÜRÜYOR · ÇOK OYUNCULU" if Net.active else "DURAKLATILDI", 13, UI.CYAN, 4)
	var title := Kit.heading(col, "UZAY SINIRI", 52, UI.SUIT_WHITE, 6)
	title.add_theme_constant_override("outline_size", 6)
	title.add_theme_color_override("font_outline_color", UI.OUTLINE)
	UI.label(col, "İki gezegen, bir kazı aracı ve rakip.", 15, UI.DIM)
	var gap := Control.new()
	gap.custom_minimum_size.y = 26
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)
	_buttons = UI.vbox(col, 8)
	Kit.menu_button(_buttons, "Devam", "Esc").pressed.connect(close)
	Kit.menu_button(_buttons, "Ayarlar", "", "Fare, görüş alanı, ses, ekran").pressed.connect(_open_settings)
	if Net.active:
		Kit.menu_button(_buttons, "Odadan Ayrıl", "", "Ana menüye dön (oyun durmaz)", 380.0, true).pressed.connect(_leave_room)
	if Game.has_meta("training"):
		Kit.menu_button(_buttons, "Ana Menü", "", "Eğitim alanından çık", 380.0, true).pressed.connect(_training_exit)
	Kit.menu_button(_buttons, "Çıkış", "", "Masaüstüne dön", 380.0, true).pressed.connect(_quit)
	var gap2 := Control.new()
	gap2.custom_minimum_size.y = 18
	gap2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap2)
	var keys := UI.hbox(col, 8)
	for k in [["WASD", "yürü"], ["Boşluk", "zıpla / basılı: jetpack"], ["F11", "tam ekran"]]:
		UI.keycap(keys, k[0], 12)
		UI.label(keys, k[1], 13, UI.FAINT)


func is_open() -> bool:
	return _root.visible


## Pauses the game and shows the menu (frees the mouse).
func open() -> void:
	if _root.visible:
		return
	get_tree().paused = not Net.active          # multiplayer: the world keeps running
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_root.visible = true
	_menu.visible = true
	_settings.visible = false
	_bg_mat.set_shader_parameter("side_dark", 0.85)
	_bg_mat.set_shader_parameter("amount", 0.0)
	var tw := create_tween().set_parallel()
	tw.tween_method(func(v: float) -> void: _bg_mat.set_shader_parameter("amount", v), 0.0, 1.0, 0.22)
	_menu.modulate.a = 0.0
	_menu.position.x = -24.0
	tw.tween_property(_menu, "modulate:a", 1.0, 0.22)
	tw.tween_property(_menu, "position:x", 0.0, 0.3).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	var first: Button = _buttons.get_child(0) if _buttons.get_child_count() > 0 else null
	if first != null:
		first.call_deferred("grab_focus")
	_ui_sound("open")


## Back to the game.
func close() -> void:
	if not _root.visible:
		return
	_root.visible = false
	_settings.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_ui_sound("close")


func _open_settings() -> void:
	_menu.visible = false
	_settings.open()
	_ui_sound("open")


func _on_settings_closed() -> void:
	_menu.visible = true
	var first: Button = _buttons.get_child(0) if _buttons.get_child_count() > 0 else null
	if first != null:
		first.call_deferred("grab_focus")
	_ui_sound("close")


func _quit() -> void:
	get_tree().paused = false
	if Net.active:
		Net.quit_game()          # tells the other player first
	else:
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if not _root.visible or _settings.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## UI sounds that also play while the tree is paused (sfx.gd's players pause with it).
func _ui_sound(name: String, db := -12.0) -> void:
	var sfx = Game.sfx
	if sfx == null or not is_instance_valid(sfx) or not sfx.has_method("pick"):
		return
	var s: AudioStream = sfx.pick(name)
	if s == null:
		return
	_sfx.stream = s
	_sfx.volume_db = db
	_sfx.play()


## Eğitim Alanı: back to the main menu (scripts/training/training.gd to_menu).
func _training_exit() -> void:
	_root.visible = false
	var tr = get_tree().get_first_node_in_group("training")
	if tr != null and tr.has_method("to_menu"):
		tr.to_menu()


## Multiplayer: leave the room (back to the main menu).
func _leave_room() -> void:
	_root.visible = false
	Net.leave("")
