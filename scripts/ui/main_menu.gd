extends Control
## The start menu (scenes/menu.tscn, the project's main scene): Tek Oyuncu · Eğitim Alanı · Çok
## Oyunculu · Ayarlar · Çıkış. Tek Oyuncu loads scenes/main.tscn exactly as before; Eğitim Alanı
## loads it with the training mode on (scripts/training/training.gd).
## Çok Oyunculu (scripts/net/net.gd): your name; "Oda Kur" (pick Birlikte / Karşı Karşıya, the room
## code big with a copy button, waiting for the friend — or start now and the friend joins later);
## "Odaya Katıl" (type the code or pick a room from the live list); connection status and errors.
## Two players per room: a third gets "Oda dolu".

const UI := preload("res://scripts/ui/ui_style.gd")
const Kit := preload("res://scripts/save/menu_kit.gd")
const SettingsScreen := preload("res://scripts/save/settings_screen.gd")
const MpConfig := preload("res://scripts/net/mp_config.gd")
const Relay := preload("res://scripts/net/net_relay.gd")
const GAME_SCENE := "res://scenes/main.tscn"
## Loaded with the menu (scripts compile up front; the single-player start stays instant).
const _GAME_PACKED := preload("res://scenes/main.tscn")
## Eğitim Alanı: the same world with dummies and every gun (scripts/training/training.gd).
const Training := preload("res://scripts/training/training.gd")

const BG_SHADER := """
shader_type canvas_item;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec3 planet(vec2 uv, vec2 c, float r, vec3 col, vec3 rim, vec2 light) {
	vec2 d = uv - c;
	float l = length(d);
	if (l > r * 1.25) return vec3(0.0);
	float body = smoothstep(r, r - 0.003, l);
	vec3 n = vec3(d / r, sqrt(max(1.0 - dot(d, d) / (r * r), 0.0)));
	float lit = clamp(dot(n, normalize(vec3(light, 0.6))), 0.0, 1.0);
	float glow = smoothstep(r * 1.25, r, l) * (1.0 - body) * 0.35;
	return col * body * (0.08 + lit * 0.92) + rim * glow;
}
void fragment() {
	vec2 px = FRAGCOORD.xy;
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = px / res.y;
	vec3 c = mix(vec3(0.012, 0.018, 0.035), vec3(0.03, 0.045, 0.08), 1.0 - SCREEN_UV.y);
	float h = hash(floor(px / 2.0));
	float tw = 0.6 + 0.4 * sin(TIME * 1.7 + h * 60.0);
	float ax = res.x / res.y;
	// Stars only where no planet disc covers the sky (the discs are opaque).
	float body = max(smoothstep(0.2, 0.197, length(uv - vec2(ax * 0.74, 0.55))),
			smoothstep(0.075, 0.072, length(uv - vec2(ax * 0.93, 0.2))));
	if (h > 0.9965) c += vec3(0.85, 0.9, 1.0) * (h - 0.9965) * 280.0 * tw * (1.0 - body);
	c += planet(uv, vec2(ax * 0.74, 0.55), 0.2, vec3(0.42, 0.45, 0.35), vec3(0.4, 0.86, 1.0), vec2(-0.6, 0.5));
	c += planet(uv, vec2(ax * 0.93, 0.2), 0.075, vec3(0.76, 0.42, 0.24), vec3(1.0, 0.4, 0.25), vec2(-0.7, 0.4));
	COLOR = vec4(c, 1.0);
}
"""

var _root: Control
var _pages := {}
var _settings: Control
var _status: Label
var _name: LineEdit
var _mode := 0
var _mode_btns: Array = []
var _code_big: Label
var _host_status: Label
var _start_now: Button
var _code_edit: LineEdit
var _join_status: Label
var _room_list: VBoxContainer
var _rooms_note: Label
var _mp_buttons: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UI.make_theme()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	Training.end()                       # back from the Eğitim Alanı (or never there): the mode is off
	if not Game.ui_panels.has(self):
		Game.ui_panels.append(self)
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = BG_SHADER
	sm.shader = sh
	bg.material = sm
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_main()
	_build_mp()
	_build_host()
	_build_join()
	_settings = SettingsScreen.new()
	_settings.visible = false
	add_child(_settings)
	_settings.closed.connect(func() -> void: _show("main"))
	Net.status.connect(_on_status)
	Net.failed.connect(_on_failed)
	Net.rooms.rooms_changed.connect(_on_rooms)
	Net.rooms.rooms_failed.connect(func(r: String) -> void: _rooms_note.text = r)
	if Net.last_message != "":
		_show("mp")
		_set_status(_status, Net.last_message, UI.WARN)
		Net.last_message = ""
	else:
		_show("main")


func _exit_tree() -> void:
	Game.ui_panels.erase(self)
	if Net.rooms != null and not Net.active:
		Net.rooms.stop()


## Always "open": a click in the menu never captures the mouse (game.gd).
func is_open() -> bool:
	return is_inside_tree()


# =================================================================================================
# Pages
# =================================================================================================

func _page(id: String) -> VBoxContainer:
	var holder := Control.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	holder.offset_left = 0
	holder.offset_right = 640
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(holder)
	var hb := UI.hbox(holder, 26)
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 74
	var line := ColorRect.new()
	line.color = Color(UI.SUIT_ORANGE, 0.85)                  # the suit's band (scripts/ui/ui_style.gd)
	line.custom_minimum_size = Vector2(3, 420)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(line)
	var col := UI.vbox(hb, 8)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pages[id] = holder
	return col


func _gap(parent: Node, h: float) -> void:
	var g := Control.new()
	g.custom_minimum_size.y = h
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(g)


func _show(id: String) -> void:
	for k in _pages:
		(_pages[k] as Control).visible = k == id
	_settings.visible = false
	if id == "join":
		Net.rooms.start()
	elif not Net.active:
		Net.rooms.stop()
	var page: Control = _pages.get(id)
	if page != null:
		var b := _first_button(page)
		if b != null:
			b.call_deferred("grab_focus")


func _first_button(n: Node) -> Button:
	for c in n.get_children():
		if c is Button and not (c as Button).disabled:
			return c
		var r := _first_button(c)
		if r != null:
			return r
	return null


func _build_main() -> void:
	var col := _page("main")
	Kit.heading(col, "İKİ GEZEGEN · BİR ÇEKİRDEK", 13, UI.CYAN, 4)
	var title := Kit.heading(col, "UZAY SINIRI", 58, UI.SUIT_WHITE, 6)
	title.add_theme_constant_override("outline_size", 6)
	title.add_theme_color_override("font_outline_color", UI.OUTLINE)
	UI.label(col, "Kaz, kur, ateş et: rakibin çekirdeğini yok et.", 15, UI.DIM)
	_gap(col, 26)
	var bx := UI.vbox(col, 8)
	Kit.menu_button(bx, "Tek Oyuncu", "", "Yapay zekâ rakibe karşı").pressed.connect(_single)
	Kit.menu_button(bx, "Eğitim Alanı", "", "Tüm silahlar açık: hedef mankenlerde dene").pressed.connect(_training)
	Kit.menu_button(bx, "Çok Oyunculu", "", "Bir arkadaşınla: birlikte ya da karşı karşıya").pressed.connect(func() -> void: _show("mp"))
	Kit.menu_button(bx, "Ayarlar", "", "Fare, görüş alanı, ses, ekran").pressed.connect(_open_settings)
	Kit.menu_button(bx, "Çıkış", "", "Masaüstüne dön", 380.0, true).pressed.connect(func() -> void: get_tree().quit())


func _build_mp() -> void:
	var col := _page("mp")
	Kit.heading(col, "ÇOK OYUNCULU", 13, UI.CYAN, 4)
	Kit.heading(col, "İki oyuncu", 44, UI.TEXT, 3)
	UI.label(col, "Oda kur ve kodu arkadaşına ver, ya da onun odasına katıl.", 15, UI.DIM)
	_gap(col, 14)
	var nr := UI.hbox(col, 10)
	var nl := UI.label(nr, "Adın", 15, UI.DIM, 600)
	nl.custom_minimum_size.x = 60
	_name = LineEdit.new()
	_name.text = MpConfig.player_name()
	_name.max_length = 18
	_name.custom_minimum_size = Vector2(300, 38)
	_name.text_changed.connect(func(t: String) -> void: MpConfig.set_player_name(t))
	nr.add_child(_name)
	_gap(col, 10)
	var bx := UI.vbox(col, 8)
	var b1 := Kit.menu_button(bx, "Oda Kur", "", "Mod seç, kodu paylaş, arkadaşını bekle")
	b1.pressed.connect(func() -> void: _show("host"))
	var b2 := Kit.menu_button(bx, "Odaya Katıl", "", "Kodu yaz ya da açık odalardan seç")
	b2.pressed.connect(func() -> void: _show("join"))
	Kit.menu_button(bx, "Geri", "Esc", "", 380.0).pressed.connect(func() -> void: _show("main"))
	_mp_buttons = [b1, b2]
	_status = UI.label(col, "", 15, UI.DIM, 500)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 480
	var why := Relay.blocker()
	if why != "":
		for b in _mp_buttons:
			(b as Button).disabled = true
		_set_status(_status, why, UI.BAD)


func _build_host() -> void:
	var col := _page("host")
	Kit.heading(col, "ODA KUR", 13, UI.CYAN, 4)
	UI.label(col, "Mod", 15, UI.DIM, 600)
	var mb := UI.vbox(col, 6)
	var m0 := Kit.menu_button(mb, "Birlikte", "", "İkiniz Yurt'tasınız, rakip yapay zekâ takımı", 460.0)
	var m1 := Kit.menu_button(mb, "Karşı Karşıya", "", "Sen Yurt, arkadaşın Rakip gezegeni: aynı malzemeyle başlarsınız", 460.0)
	m0.pressed.connect(_pick_mode.bind(0))
	m1.pressed.connect(_pick_mode.bind(1))
	_mode_btns = [m0, m1]
	_pick_mode(0)
	_gap(col, 6)
	var open := Kit.menu_button(col, "Odayı Aç", "", "Kod oluşturulur, sunucuda oda açılır", 460.0)
	open.pressed.connect(_host_open)
	UI.label(col, "Oda kodu", 14, UI.DIM, 600)
	var cr := UI.hbox(col, 12)
	_code_big = Kit.heading(cr, "—", 54, UI.ACCENT, 8)
	var copy := Button.new()
	copy.text = "Kopyala"
	copy.custom_minimum_size = Vector2(110, 40)
	copy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	copy.pressed.connect(_copy_code)
	cr.add_child(copy)
	_host_status = UI.label(col, "Odayı açınca kodu arkadaşına gönder.", 15, UI.DIM, 500)
	_host_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_host_status.custom_minimum_size.x = 480
	_start_now = Kit.menu_button(col, "Şimdi başla", "", "Arkadaşın sonra da katılabilir", 460.0)
	_start_now.pressed.connect(_host_start_now)
	_start_now.disabled = true
	Kit.menu_button(col, "İptal", "Esc", "", 460.0, true).pressed.connect(_cancel)


func _build_join() -> void:
	var col := _page("join")
	Kit.heading(col, "ODAYA KATIL", 13, UI.CYAN, 4)
	UI.label(col, "Oda kodu", 14, UI.DIM, 600)
	var r := UI.hbox(col, 10)
	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = "örn. K7QX2"
	_code_edit.max_length = 16
	_code_edit.custom_minimum_size = Vector2(240, 44)
	_code_edit.add_theme_font_size_override("font_size", 24)
	_code_edit.text_submitted.connect(func(_t: String) -> void: _join_code())
	r.add_child(_code_edit)
	var jb := Button.new()
	jb.text = "Katıl"
	jb.custom_minimum_size = Vector2(120, 44)
	jb.pressed.connect(_join_code)
	r.add_child(jb)
	_join_status = UI.label(col, "", 15, UI.DIM, 500)
	_join_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_join_status.custom_minimum_size.x = 480
	_gap(col, 6)
	UI.label(col, "Açık odalar", 14, UI.DIM, 600)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(470, 190)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(sc)
	_room_list = UI.vbox(sc, 4)
	_room_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rooms_note = UI.label(col, "Liste yükleniyor…", 13, UI.FAINT)
	Kit.menu_button(col, "Geri", "Esc", "", 460.0).pressed.connect(_cancel)


# =================================================================================================
# Actions
# =================================================================================================

func _single() -> void:
	Net.cancel()
	Game.reset_state()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().change_scene_to_file(GAME_SCENE)


## Eğitim Alanı: single player, every gun, dummies, no rival team (scripts/training/training.gd).
func _training() -> void:
	Net.cancel()
	Training.begin()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().change_scene_to_file(GAME_SCENE)


func _open_settings() -> void:
	for k in _pages:
		(_pages[k] as Control).visible = false
	_settings.open()


func _pick_mode(m: int) -> void:
	_mode = m
	for i in _mode_btns.size():
		var b: Button = _mode_btns[i]
		Kit.set_sub(b, ("(seçili)  " if i == m else "") + str(b.get_meta("sub_text", "")), UI.GOOD if i == m else UI.DIM)
		b.modulate = Color(1, 1, 1, 1.0 if i == m else 0.7)


func _host_open() -> void:
	MpConfig.set_player_name(_name.text)
	Net.host_room(_mode)
	_code_big.text = Net.room_code
	_start_now.disabled = false
	_set_status(_host_status, "Oda açılıyor…", UI.DIM)


func _host_start_now() -> void:
	if Net.is_host():
		Net.start_game()


func _copy_code() -> void:
	if Net.room_code != "":
		DisplayServer.clipboard_set(Net.room_code)
		_set_status(_host_status, "Kod kopyalandı: %s" % Net.room_code, UI.GOOD)


func _join_code() -> void:
	var code := MpConfig.normalize_code(_code_edit.text)
	if not MpConfig.code_valid(code):
		_set_status(_join_status, "Geçerli bir oda kodu yaz (örn. K7QX2).", UI.BAD)
		return
	MpConfig.set_player_name(_name.text)
	_set_status(_join_status, "Bağlanılıyor…", UI.DIM)
	Net.join_room(code)


func _join_room_code(code: String) -> void:
	_code_edit.text = code
	_join_code()


func _cancel() -> void:
	Net.cancel()
	_start_now.disabled = true
	_code_big.text = "—"
	_set_status(_host_status, "Odayı açınca kodu arkadaşına gönder.", UI.DIM)
	_show("mp")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _settings.visible:
			return
		if (_pages["host"] as Control).visible or (_pages["join"] as Control).visible:
			_cancel()
		elif (_pages["mp"] as Control).visible:
			_show("main")
		get_viewport().set_input_as_handled()


# =================================================================================================
# Net events
# =================================================================================================

func _set_status(l: Label, text: String, col: Color) -> void:
	l.text = text
	l.add_theme_color_override("font_color", col)


func _on_status(text: String) -> void:
	if (_pages["host"] as Control).visible:
		_set_status(_host_status, text, UI.TEXT)
	elif (_pages["join"] as Control).visible:
		_set_status(_join_status, text, UI.TEXT)
	else:
		_set_status(_status, text, UI.TEXT)


func _on_failed(reason: String) -> void:
	if (_pages["host"] as Control).visible:
		_start_now.disabled = true
		_code_big.text = "—"
		_set_status(_host_status, reason, UI.BAD)
	elif (_pages["join"] as Control).visible:
		_set_status(_join_status, reason, UI.BAD)
	else:
		_show("mp")
		_set_status(_status, reason, UI.BAD)


func _on_rooms(rooms: Array) -> void:
	for c in _room_list.get_children():
		c.queue_free()
	_rooms_note.text = "" if not rooms.is_empty() else "Şu an açık oda yok."
	for r in rooms:
		var code := str(r.get("code", ""))
		var full := bool(r.get("full", false))
		var b := Button.new()
		b.text = "%s    %d/2%s" % [code, int(r.get("players", 0)), "  · dolu" if full else ""]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(450, 36)
		b.disabled = full
		b.pressed.connect(_join_room_code.bind(code))
		_room_list.add_child(b)
