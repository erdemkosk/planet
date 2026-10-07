extends Control
## The Silahlık's EKLENTİLER page (a tab of scripts/war/craft_menu.gd, added when this script loads),
## fed by the Attachments API of scripts/items/attachments.gd (another session: list(), owned(),
## draw_icon(); loaded at runtime, so this page waits quietly while that file is not ready). Drawn in
## the design system's look (scripts/ui/ui_style.gd), laid out at the crafting grid's size
## (set_page_size), five cards a row:
##   a card   the attachment's silhouette (Attachments.draw_icon) on a spotlight in a dark well (it
##            lifts under the mouse), the slot chip (NAMLU / NİŞANGAH / ALT NAMLU), the name, the
##            price, the role (two lines), up to three stat lines (green better, red worse),
##            the guns it fits, and the state: "SAHİPSİN · orta tık ile tak", "SATIN AL · 120 m³",
##            "Yetersiz malzeme: NN m³ eksik"
##   click    buys it at once at this armory (craft_menu._try -> armory.start_craft: pays, Craft.grant;
##            recipe id = the attachment id, or "att_" + id); until such a recipe exists the toast says
##            so. Unlocking itself is the API's (Attachments.unlock, via Craft.grant).
## Contract with craft_menu.gd: set_page_size(Vector2), cancel_drag().

const UI := preload("res://scripts/ui/ui_style.gd")
const Craft := preload("res://scripts/war/craft.gd")
const API_PATH := "res://scripts/items/attachments.gd"
const COLS := 5
const GAP := 12.0
const GUN_SHORT := {"rifle": "Tüfek", "smg": "HMK", "shotgun": "Pompalı", "sniper": "Keskin", "rail": "Raylı",
		"pusher": "İtici", "rocket": "Roketatar", "pistol": "Tabanca", "revolver": "Altıpatlar", "mpistol": "Mak. Tab."}

var page_size := Vector2(898, 650)
var _api = null
var _api_t := 0.0
var _list: Array = []
var _list_t := 0.0
var _hover := -1
var _lift: Array = []
var _mouse := Vector2(-1e5, -1e5)
var _t := 0.0
var _font: Font
var _font_b: Font
var _font_n: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = UI.font(500)
	_font_b = UI.font(700)
	_font_n = UI.font_num(700)
	custom_minimum_size = page_size


func set_page_size(s: Vector2) -> void:
	if s.x > 10.0 and s.y > 10.0 and s != page_size:
		page_size = s
		custom_minimum_size = s


func cancel_drag() -> void:
	pass


## The Attachments script, once it loads (retried every 2 s).
func _get_api():
	if _api != null:
		return _api
	if _api_t > 0.0 or not ResourceLoader.exists(API_PATH):
		return null
	_api_t = 2.0
	var s = load(API_PATH)
	if s is Script and (s as Script).can_instantiate():
		_api = s
	return _api


## The recipe of attachment `id` in scripts/war/craft.gd ("" when there is none yet).
func _recipe_id(id: String) -> String:
	if not Craft.recipe(id).is_empty():
		return id
	if not Craft.recipe("att_" + id).is_empty():
		return "att_" + id
	return ""


func _menu():
	if Game.has_meta("craft_menu"):
		var m = Game.get_meta("craft_menu")
		if m != null and is_instance_valid(m):
			return m
	return null


func _card_rect(i: int) -> Rect2:
	var rows := maxi(int(ceilf(float(_list.size()) / COLS)), 1)
	var w := (page_size.x - GAP * (COLS - 1)) / COLS
	var h := minf((page_size.y - 34.0 - GAP * (rows - 1)) / rows, 330.0)
	return Rect2(Vector2((i % COLS) * (w + GAP), 30.0 + (i / COLS) * (h + GAP)), Vector2(w, h))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse = (event as InputEventMouseMotion).position
		accept_event()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_mouse = (event as InputEventMouseButton).position
		for i in _list.size():
			if _card_rect(i).has_point(_mouse):
				_click(_list[i])
				break
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_mouse = Vector2(-1e5, -1e5)


func _click(e: Dictionary) -> void:
	var id := str(e.get("id", ""))
	if bool(e.get("owned", false)):
		if Game.hud:
			Game.hud.show_message("%s sende var: oyunda orta tıkla tak" % str(e.get("name", "")), 2.0)
		if Game.sfx:
			Game.sfx.play("click", -12.0, 1.3)
		return
	var rid := _recipe_id(id)
	var m = _menu()
	if rid == "" or m == null:
		if Game.hud:
			Game.hud.show_message("Bu eklenti henüz satışta değil", 2.0)
		if Game.sfx:
			Game.sfx.play("error", -12.0)
		return
	m.call("_try", rid)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_t += delta
	_api_t = maxf(_api_t - delta, 0.0)
	_list_t -= delta
	var api = _get_api()
	if api != null and _list_t <= 0.0:
		_list_t = 0.5
		var l = api.call("list")
		_list = l if l is Array else []
	if _lift.size() != _list.size():
		_lift.resize(_list.size())
		_lift.fill(0.0)
	_hover = -1
	for i in _list.size():
		var on := _card_rect(i).has_point(_mouse)
		if on:
			_hover = i
		_lift[i] = move_toward(float(_lift[i]), 1.0 if on else 0.0, delta * 7.0)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover >= 0 else Control.CURSOR_ARROW
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2(0, 6), Vector2(3, 14)), UI.SUIT_ORANGE)
	var cf := UI.font_caps(700, 2)
	UI.draw_text(self, cf, Vector2(10, 18), "EKLENTİLER", 14, UI.SUIT_WHITE, 0)
	UI.draw_text(self, _font, Vector2(10 + UI.text_w(cf, "EKLENTİLER", 14) + 12.0, 18), "bir kez satın al, uyan her silaha tak  ·  oyunda orta tık: takma halkası",
			14, UI.DIM, 0)
	if _get_api() == null or _list.is_empty():
		UI.draw_text_c(self, _font, page_size * 0.5, "Eklentiler hazırlanıyor…", 16, UI.DIM, 0)
		return
	for i in _list.size():
		_draw_card(_list[i], _card_rect(i), UI.smooth(float(_lift[i])))


func _draw_card(e: Dictionary, r: Rect2, lift: float) -> void:
	var id := str(e.get("id", ""))
	var owned := bool(e.get("owned", false))
	var cost := float(e.get("cost", 0.0))
	var rid := _recipe_id(id)
	var afford := Game.material + 0.001 >= cost
	var col: Color = e.get("color", UI.SCREEN_CYAN)
	r.position.y -= 4.0 * lift
	var bc := UI.GOOD if owned else (UI.SUIT_ORANGE if afford else UI.BAD)
	var sb := UI.chamfer_box(Color(UI.GLASS_HI, 0.92) if lift > 0.01 else Color(UI.GLASS, 0.8),
			Color(bc, lerpf(0.3, 0.95, lift)) if owned or lift > 0.01 else Color(UI.SUIT_WHITE, 0.16), 2 if lift > 0.5 else 1, 12.0, 0)
	sb.shadow_color = Color(bc, 0.22 * lift)
	sb.shadow_size = int(12.0 * lift)
	draw_style_box(sb, r)
	if owned:
		draw_rect(Rect2(r.position + Vector2(20.0, 0.0), Vector2(r.size.x * 0.4, 3.0)), Color(UI.GOOD, 0.9))
	# The icon well.
	var tb := Rect2(r.position + Vector2(8, 8), Vector2(r.size.x - 16.0, 78.0))
	UI.draw_chamfer(self, tb, 7.0, Color(0.01, 0.035, 0.045, 0.75), Color(UI.SUIT_WHITE, 0.06))
	draw_circle(tb.get_center(), tb.size.y * 0.45, Color(col, 0.08 + 0.06 * lift))
	var api = _get_api()
	if api != null:
		var ic := tb.get_center() + Vector2(0.0, -2.0 * lift)
		api.call("draw_icon", self, id, ic, tb.size.y * (0.36 + 0.04 * lift), Color(col, 1.0 if owned or afford else 0.6))
	# The slot chip.
	var sn := str(e.get("slot_name", ""))
	if sn != "":
		var sf := UI.font_caps(700, 1)
		var sw := UI.text_w(sf, sn, 10) + 10.0
		var srr := Rect2(tb.position + Vector2(5, 5), Vector2(sw, 15))
		UI.draw_chamfer(self, srr, 4.0, Color(UI.SCREEN_CYAN, 0.16), Color(UI.SCREEN_CYAN, 0.5))
		draw_string(sf, srr.position + Vector2(5, 11), sn, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UI.SCREEN_CYAN.lightened(0.3))
	var x := r.position.x + 10.0
	var y := tb.end.y + 22.0
	UI.draw_text(self, _font_b, Vector2(x, y), str(e.get("name", "")), 16, UI.TEXT, 0)
	y += 22.0
	var cs := "%d" % int(cost)
	UI.draw_text(self, _font_n, Vector2(x, y), cs, 18, UI.SUIT_ORANGE.lightened(0.15) if afford or owned else UI.BAD, 0)
	UI.draw_text(self, _font, Vector2(x + UI.text_w(_font_n, cs, 18) + 3.0, y), "m³", 12, UI.DIM, 0)
	y += 6.0
	draw_multiline_string(_font, Vector2(x, y + 12.0), str(e.get("desc", "")), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20.0, 11, 2, UI.DIM)
	y += 38.0
	var st = e.get("stats_text", [])
	if st is Array:
		var n := 0
		for line in st:
			if n >= 3 or not (line is Array) or (line as Array).size() < 3:
				continue
			n += 1
			var good := bool(line[2])
			UI.draw_text(self, _font, Vector2(x, y), str(line[0]), 11, Color(UI.TEXT, 0.8), 0)
			UI.draw_text_r(self, _font_n, r.end.x - 10.0, y, str(line[1]), 11, UI.GOOD if good else UI.BAD, 0)
			y += 15.0
	# The guns it fits.
	var guns = e.get("guns", [])
	if guns is Array:
		var parts := PackedStringArray()
		for g in guns:
			parts.append(str(GUN_SHORT.get(str(g), str(g))))
		var gs := " · ".join(parts)
		UI.draw_text(self, _font, Vector2(x, r.end.y - 30.0), gs, 10, Color(UI.FAINT, 0.95), 0)
	# The state.
	var txt := ""
	var sc := UI.SCREEN_CYAN
	if owned:
		txt = "SAHİPSİN  ·  orta tık ile tak"
		sc = UI.GOOD
	elif not afford:
		txt = "Yetersiz malzeme: %d m³ eksik" % int(ceilf(cost - Game.material))
		sc = UI.BAD
	elif rid == "":
		txt = "Yakında satışta"
		sc = UI.DIM
	else:
		txt = "SATIN AL  ·  %d m³" % int(cost)
	UI.draw_text(self, UI.font_caps(700, 1), Vector2(x, r.end.y - 11.0), txt, 11, sc, 0)
