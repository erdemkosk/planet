extends Control
## KARAKTER, the character strip of the loadout picker (scripts/war/loadout_panel.gd embeds it; see
## scripts/war/heroes/PATCHES.md): one chip per character (scripts/war/heroes/hero_data.gd) with its
## icon, name and ultimate; the pick has the orange frame and "SEÇİLİ"; under the strip the pick's
## ultimate and passive in a line each. Click a chip, or ← / → while it is visible. A pick goes to
## Heroes.pick(id) (heroes.gd: at once while dead / riding the respawn ship, else at the next spawn).
## In the design system's look (scripts/ui/ui_style.gd), drawn in _draw (no child controls).
##   size: SIZE (the host may set another width; the chips share it)
##   signal hero_picked(id)    pick(id)    cycle(dir)

const UI := preload("res://scripts/ui/ui_style.gd")
const HeroData := preload("res://scripts/war/heroes/hero_data.gd")
const Heroes := preload("res://scripts/war/heroes/heroes.gd")

const SIZE := Vector2(756, 150)
const GAP := 8.0
const CHIP_H := 64.0
const TOP := 24.0

signal hero_picked(id: String)

var _font: Font
var _font_b: Font
var _lift := {}
var _pop := {}
var _mouse := Vector2(-100000.0, -100000.0)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = UI.font(500)
	_font_b = UI.font(700)
	if size.x < 10.0:
		size = SIZE
	custom_minimum_size = Vector2(0.0, SIZE.y)


func pick(id: String) -> void:
	if not HeroData.has(id):
		return
	var changed := id != Heroes.local_pick
	Heroes.pick(id)
	_pop[id] = 1.0
	if Game.sfx:
		Game.sfx.play("select" if changed else "click", -10.0, 1.1)
	if changed:
		hero_picked.emit(id)


func cycle(dir: int) -> void:
	var ids: Array = HeroData.IDS
	var i := maxi(ids.find(Heroes.local_pick), 0)
	pick(str(ids[posmod(i + dir, ids.size())]))


func _chips() -> Array:
	var ids: Array = HeroData.IDS
	var n := ids.size()
	var w := (size.x - GAP * float(n - 1)) / float(n)
	var out: Array = []
	for i in n:
		out.append({"id": str(ids[i]), "rect": Rect2(Vector2(float(i) * (w + GAP), TOP), Vector2(w, CHIP_H))})
	return out


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse = (event as InputEventMouseMotion).position
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_mouse = (event as InputEventMouseButton).position
		for c in _chips():
			if (c["rect"] as Rect2).has_point(_mouse):
				pick(str(c["id"]))
				break
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_mouse = Vector2(-100000.0, -100000.0)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var host := get_parent()
	if host != null and host.get("mode") == 1 and Game.overlays_hidden():    # (loadout_panel MODE_RIDE behind a menu)
		return
	var kc := (event as InputEventKey).physical_keycode
	if kc == KEY_LEFT or kc == KEY_RIGHT:
		cycle(1 if kc == KEY_RIGHT else -1)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var hov := false
	for c in _chips():
		var id := str(c["id"])
		var h := (c["rect"] as Rect2).has_point(_mouse)
		hov = hov or h
		_lift[id] = move_toward(float(_lift.get(id, 0.0)), 1.0 if h else 0.0, delta * 8.0)
		_pop[id] = maxf(float(_pop.get(id, 0.0)) - delta * 3.0, 0.0)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hov else Control.CURSOR_ARROW
	queue_redraw()


func _draw() -> void:
	var sel := Heroes.local_pick
	# The title.
	draw_rect(Rect2(Vector2(0, 4), Vector2(3, 14)), UI.SUIT_ORANGE)
	var cf := UI.font_caps(700, 2)
	UI.draw_text(self, cf, Vector2(10, 16), "KARAKTER", 13, UI.SUIT_WHITE, 0)
	var x := 10.0 + UI.text_w(cf, "KARAKTER", 13) + 12.0
	x += UI.draw_key(self, Vector2(x, 1.0), "←", 1.0, false, 1.0, 11) + 4.0
	x += UI.draw_key(self, Vector2(x, 1.0), "→", 1.0, false, 1.0, 11) + 8.0
	UI.draw_text(self, _font, Vector2(x, 16), "ya da karta tıkla", 13, UI.DIM, 0)
	# Right: how the ultimate works.
	var rt := "sahada ultiyi kullan · zamanla, leşle, bölgeyle, kazarak dolar"
	var rw := UI.text_w(_font, rt, 12)
	UI.draw_text(self, _font, Vector2(size.x - rw, 16), rt, 12, UI.FAINT, 0)
	UI.draw_key(self, Vector2(size.x - rw - 26.0, 1.0), "E", 1.0, true, 1.0, 11)
	for c in _chips():
		_draw_chip(c, str(c["id"]) == sel)
	# The pick's ultimate and passive.
	var d := HeroData.info(sel)
	var y := TOP + CHIP_H + 22.0
	var col: Color = d["col"]
	var ult := "ULTİ  %s" % str(d["ult"])
	UI.draw_text(self, UI.font_caps(700, 1), Vector2(0, y), UI.upper_tr(ult), 12, col.lightened(0.15), 0)
	var uw := UI.text_w(UI.font_caps(700, 1), UI.upper_tr(ult), 12) + 10.0
	UI.draw_text(self, _font, Vector2(uw, y), UI.ellipsize(_font, str(d["desc"]), 13, size.x - uw), 13, UI.TEXT, 0)
	y += 20.0
	UI.draw_text(self, UI.font_caps(700, 1), Vector2(0, y), "PASİF", 12, UI.DIM, 0)
	var pw := UI.text_w(UI.font_caps(700, 1), "PASİF", 12) + 10.0
	UI.draw_text(self, _font, Vector2(pw, y), UI.ellipsize(_font, str(d["passive"]), 13, size.x - pw), 13, UI.DIM, 0)


func _draw_chip(c: Dictionary, sel: bool) -> void:
	var id := str(c["id"])
	var lift := float(_lift.get(id, 0.0))
	lift = lift * lift * (3.0 - 2.0 * lift)
	var pop := float(_pop.get(id, 0.0))
	var r: Rect2 = c["rect"]
	r.position.y -= 3.0 * lift
	r = r.grow(pop * 2.0)
	var col := HeroData.color(id)
	var bc := Color(UI.SUIT_WHITE, 0.16).lerp(Color(UI.SCREEN_CYAN, 0.95), lift)
	if sel:
		bc = Color(UI.SUIT_ORANGE, 0.95)
	var sb := UI.chamfer_box(Color(UI.GLASS_HI, 0.92) if lift > 0.01 or sel else Color(UI.GLASS, 0.82), bc,
			2 if lift > 0.5 or sel else 1, 9.0, 0)
	sb.shadow_color = Color(UI.SUIT_ORANGE if sel else UI.SCREEN_CYAN, 0.22 if sel else 0.25 * lift)
	sb.shadow_size = 10 if sel else int(9.0 * lift)
	draw_style_box(sb, r)
	if sel:
		draw_rect(Rect2(Vector2(r.position.x + 14.0, r.position.y), Vector2(r.size.x * 0.4, 3.0)), Color(UI.SUIT_ORANGE, 0.95))
	var ic := Vector2(r.position.x + 26.0, r.get_center().y)
	draw_circle(ic, 18.0, Color(col, 0.12 + 0.08 * lift))
	draw_arc(ic, 18.0, 0.0, TAU, 32, Color(col, 0.55 if sel else 0.3), 1.5, true)
	HeroData.draw_icon(self, id, ic, 12.0, col if sel or lift > 0.01 else col.lerp(UI.DIM, 0.3), 1.8)
	var x := ic.x + 26.0
	var tw := r.end.x - x - 6.0
	UI.draw_text(self, _font_b, Vector2(x, r.position.y + 27.0), UI.ellipsize(_font_b, HeroData.hero_name(id), 15, tw), 15, UI.TEXT, 0)
	UI.draw_text(self, _font, Vector2(x, r.position.y + 46.0), UI.ellipsize(_font, HeroData.ult_name(id), 12, tw), 12,
			col.lightened(0.1) if sel else UI.DIM, 0)
	if sel:
		var tf := UI.font_caps(700, 1)
		UI.draw_text_r(self, tf, r.end.x - 7.0, r.end.y - 6.0, "SEÇİLİ", 9, UI.SUIT_ORANGE, 0)
