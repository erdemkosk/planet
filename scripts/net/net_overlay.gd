extends CanvasLayer
## Multiplayer in-game overlay (child "Overlay" of the Net autoload, only shown in a session):
##   - top right: ping, mode and the other player's name (or "Arkadaşın bekleniyor")
##   - chat: Enter opens a line at the bottom left, Enter sends, Esc closes; the last lines fade out
##   - toasts (joins, leaves, restarts), a "Dünya eşitleniyor…" loading cover while the client syncs
##   - the PvP "Rakip ayrıldı" dialog: continue against the AI or go back to the menu
## While the chat, the loading cover or a dialog is up it counts as an open panel (Game.ui_panels):
## the player does not walk, shoot or dig.

const UI := preload("res://scripts/ui/ui_style.gd")
const Kit := preload("res://scripts/save/menu_kit.gd")
const CHAT_KEEP := 10.0
const CHAT_LINES := 7

var _root: Control
var _info: Label
var _toast: Label
var _toast_t := 0.0
var _chat_box: VBoxContainer
var _chat_lines: Array = []          # [Label, age]
var _line: LineEdit
var _chat_open := false
var _cover: ColorRect
var _cover_label: Label
var _loading := false
var _dialog: PanelContainer
var _dialog_open := false
var _shown := false


func _ready() -> void:
	layer = 55
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UI.make_theme()
	add_child(_root)
	_info = UI.label(_root, "", 13, UI.DIM, 500)
	_info.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_info.offset_left = -420
	_info.offset_right = -18
	_info.offset_top = 10
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_info.add_theme_constant_override("outline_size", 4)
	_info.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_toast = UI.label(_root, "", 17, UI.TEXT, 600)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_toast.offset_left = -520
	_toast.offset_right = -18
	_toast.offset_top = 32
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_toast.add_theme_constant_override("outline_size", 5)
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_toast.modulate.a = 0.0
	_chat_box = UI.vbox(_root, 2)
	_chat_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_box.offset_left = 22
	_chat_box.offset_right = 560
	_chat_box.offset_top = -330
	_chat_box.offset_bottom = -170
	_chat_box.alignment = BoxContainer.ALIGNMENT_END
	_chat_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_line = LineEdit.new()
	_line.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_line.offset_left = 22
	_line.offset_right = 520
	_line.offset_top = -162
	_line.offset_bottom = -130
	_line.placeholder_text = "Mesaj yaz — Enter gönder, Esc kapat"
	_line.max_length = 160
	_line.visible = false
	_line.text_submitted.connect(_on_submit)
	_root.add_child(_line)
	_cover = ColorRect.new()
	_cover.color = Color(0.01, 0.02, 0.04, 0.88)
	_cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_cover.visible = false
	_root.add_child(_cover)
	_cover_label = UI.label(_cover, "", 26, UI.TEXT, 600)
	_cover_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_cover_label.offset_left = -400
	_cover_label.offset_right = 400
	_cover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	visible = false


## Panels the player must not play through (Game.ui_panel_open()).
func is_open() -> bool:
	return visible and (_chat_open or _loading or _dialog_open)


func show_game() -> void:
	_shown = true
	visible = true
	if not Game.ui_panels.has(self):
		Game.ui_panels.append(self)


func hide_game() -> void:
	_shown = false
	_close_chat()
	loading(false, "")
	_close_dialog()
	visible = false
	for l in _chat_lines:
		(l[0] as Node).queue_free()
	_chat_lines.clear()
	Game.ui_panels.erase(self)


func loading(on: bool, text: String) -> void:
	_loading = on
	_cover.visible = on
	_cover_label.text = text


func toast(text: String, seconds := 3.0) -> void:
	_toast.text = text
	_toast_t = seconds
	_toast.modulate.a = 1.0
	if not _shown and Game.hud != null and is_instance_valid(Game.hud):
		Game.hud.show_message(text, seconds)


func add_chat(who: String, text: String, mine: bool) -> void:
	var l := UI.label(_chat_box, "", 15, UI.TEXT, 500)
	l.text = "%s: %s" % [who, text]
	l.add_theme_color_override("font_color", Color(0.55, 0.92, 1.0) if mine else Color(1.0, 0.86, 0.55))
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 520
	_chat_lines.append([l, 0.0])
	while _chat_lines.size() > CHAT_LINES:
		(_chat_lines.pop_front()[0] as Node).queue_free()
	if not mine and Game.sfx:
		Game.sfx.play("blip", -14.0, 1.2)


func _process(delta: float) -> void:
	if not visible:
		return
	var t := ""
	if Net.active:
		var mode_s: String = Net.MODE_NAMES[clampi(Net.mode, 0, 1)]
		if Net.other_id != 0 and Net.welcomed:
			t = "%s  ·  %s  ·  ping %s" % [mode_s, Net.other_name, ("%d ms" % Net.rtt_ms) if Net.rtt_ms >= 0 else "—"]
		elif Net.is_server:
			t = "%s  ·  oda %s  ·  arkadaşın bekleniyor" % [mode_s, Net.room_code]
		else:
			t = mode_s
	_info.text = t
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t / 0.5, 0.0, 1.0)
	for e in _chat_lines:
		e[1] = float(e[1]) + delta
		var a := 1.0 if _chat_open else clampf((CHAT_KEEP - float(e[1])) / 1.5, 0.0, 1.0)
		(e[0] as Control).modulate.a = a


func _input(event: InputEvent) -> void:
	if not visible or not _chat_open:
		return
	if event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).keycode == KEY_ESCAPE:
		_close_chat()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _chat_open or _loading or _dialog_open or not Net.active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		if (k == KEY_ENTER or k == KEY_KP_ENTER) and not Game.ui_panel_open():
			_open_chat()
			get_viewport().set_input_as_handled()


func _open_chat() -> void:
	_chat_open = true
	_line.visible = true
	_line.text = ""
	_line.grab_focus()


func _close_chat() -> void:
	_chat_open = false
	if _line != null:
		_line.release_focus()
		_line.visible = false


func _on_submit(text: String) -> void:
	Net.send_chat(text)
	_close_chat()


# --- Dialog ------------------------------------------------------------------------------------------

## PvP host: the rival player left. Continue against the AI, or back to the menu.
func ask_continue_vs_ai(text: String) -> void:
	_close_dialog()
	_dialog_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_dialog = UI.panel(_root, UI.panel_box(24))
	_dialog.mouse_filter = Control.MOUSE_FILTER_STOP
	_dialog.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_dialog.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_dialog.grow_vertical = Control.GROW_DIRECTION_BOTH
	_dialog.custom_minimum_size = Vector2(520, 0)
	var v := UI.vbox(_dialog, 12)
	Kit.heading(v, "RAKİP AYRILDI", 13, UI.WARN, 3)
	var l := UI.label(v, text, 20, UI.TEXT, 600)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UI.label(v, "Maça yapay zekâya karşı devam edebilirsin.", 14, UI.DIM)
	var b1 := Kit.menu_button(v, "Yapay zekâya karşı devam et", "", "Rakip tarafını botlar devralır", 470.0)
	b1.pressed.connect(_on_continue_ai)
	Kit.menu_button(v, "Ana menüye dön", "", "Odadan ayrıl", 470.0, true).pressed.connect(_on_leave)
	b1.call_deferred("grab_focus")


func _close_dialog() -> void:
	_dialog_open = false
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null


func _on_continue_ai() -> void:
	_close_dialog()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Net.continue_vs_ai()


func _on_leave() -> void:
	_close_dialog()
	Net.leave("")
