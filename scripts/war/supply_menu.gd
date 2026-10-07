extends CanvasLayer
## The İkmal kapsülü menu (2026-10-06): Tab on foot (Game._unhandled_input, action "supply_call")
## opens a compact list at the right of the screen, the design system's look (scripts/ui/ui_style.gd):
## one row per power weapon (Balance.SUPPLY_GUNS: its key 1, 2, …, the rendered thumbnail of the gun
## (scripts/war/build_preview.gd, the Silahlık card's), the name, the price after the Silahlık's
## İkmal indirimi and why it cannot be called now), the material, the call cooldown as a ring and the
## pods already coming. A number key calls that gun in (scripts/war/supply_pod.gd SupplyPod.call_in)
## and closes it; Tab / Esc close it. The mouse stays captured (looking goes on; the number keys are
## taken while it is open). Closes itself on death, in a vehicle, when a panel opens or the match ends.
## In group "gameplay_overlay" (scripts/ui/overlay_guard.gd). Also runs SupplyPod.tick() every frame.
##   SupplyMenu.toggle()   SupplyMenu.close_menu()   SupplyMenu.is_open() -> bool

const UI := preload("res://scripts/ui/ui_style.gd")
const Balance := preload("res://scripts/war/balance.gd")
const BuildPreview := preload("res://scripts/war/build_preview.gd")
const Craft := preload("res://scripts/war/craft.gd")
const SupplyPod := preload("res://scripts/war/supply_pod.gd")

const W := 380.0                         # px at 1080p
const ROW_H := 58.0
const RIGHT := 28.0

var _open := false
var _k := 0.0
var _t := 0.0
var _root: Control
var _f: Font
var _f_b: Font
var _f_n: Font
var _f_caps: Font
var _flash := {}                         # gun -> a refused key's red flash 0..1


static func inst() -> Node:
	if Game.has_meta("supply_menu"):
		var m = Game.get_meta("supply_menu")
		if m != null and is_instance_valid(m) and (m as Node).is_inside_tree():
			return m
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var n: Node = load("res://scripts/war/supply_menu.gd").new()
	n.name = "SupplyMenu"
	tree.current_scene.add_child(n)
	Game.set_meta("supply_menu", n)
	return n


static func toggle() -> void:
	var m = inst()
	if m != null:
		m.call("_toggle")


static func close_menu() -> void:
	if Game.has_meta("supply_menu"):
		var m = Game.get_meta("supply_menu")
		if m != null and is_instance_valid(m):
			m.call("_close")


static func is_open() -> bool:
	if not Game.has_meta("supply_menu"):
		return false
	var m = Game.get_meta("supply_menu")
	return m != null and is_instance_valid(m) and bool(m.get("_open"))


func _ready() -> void:
	layer = 7
	add_to_group("gameplay_overlay")
	_f = UI.font(500)
	_f_b = UI.font(700)
	_f_n = UI.font_num(700)
	_f_caps = UI.font_caps(700, 2)
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	_root.draw.connect(_draw_menu)
	add_child(_root)


func _exit_tree() -> void:
	if Game.has_meta("supply_menu") and Game.get_meta("supply_menu") == self:
		Game.remove_meta("supply_menu")


func _usable() -> bool:
	var p = Game.player
	if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
		return false
	if p.get("vehicle") != null or (p.has_method("is_dead") and p.is_dead()):
		return false
	if p.has_method("is_ragdolled") and p.is_ragdolled():
		return false
	return not Game.match_over and not Game.ui_panel_open()


func _toggle() -> void:
	if _open:
		_close()
		return
	if not _usable():
		return
	_open = true
	var entries: Array = []
	for g in Balance.SUPPLY_GUNS:
		var r := Craft.recipe(str(g))
		if r.has("item_script"):
			entries.append({"id": str(r.get("thumb_id", "craft_" + str(g))), "item_script": r["item_script"]})
	if not entries.is_empty():
		BuildPreview.request_thumbs(get_tree(), entries)
	if Game.sfx:
		Game.sfx.play("open", -12.0, 1.2)


func _close() -> void:
	if not _open:
		return
	_open = false
	if Game.sfx:
		Game.sfx.play("close", -14.0, 1.2)


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("supply_call") or event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var kc := (event as InputEventKey).physical_keycode
		var i := kc - KEY_1
		if i >= 0 and i < mini(Balance.SUPPLY_GUNS.size(), 9):
			_call(str(Balance.SUPPLY_GUNS[i]))
			get_viewport().set_input_as_handled()


func _call(g: String) -> void:
	var why := SupplyPod.call_in(g)
	if why == "":
		_close()
		return
	_flash[g] = 1.0
	if Game.sfx:
		Game.sfx.play("error", -10.0)
	if Game.hud:
		Game.hud.alert(why, 1, "supply", 1.8)


func _process(delta: float) -> void:
	_t += delta
	SupplyPod.tick()
	if _open and not _usable():
		_close()
	_k = move_toward(_k, 1.0 if _open else 0.0, delta / (UI.T_FAST if _open else UI.T_FAST * 0.8))
	for g in _flash.keys():
		_flash[g] = maxf(float(_flash[g]) - delta * 2.5, 0.0)
	_root.visible = _k > 0.001
	if _root.visible:
		_root.queue_redraw()


# =================================================================================================
# Drawing
# =================================================================================================

func _draw_menu() -> void:
	var vs := _root.size
	var k := UI.scale_k(vs)
	var e := UI.smooth(_k)
	var a := e
	var guns: Array = Balance.SUPPLY_GUNS
	var w := W * k
	var head := 62.0 * k
	var foot := 40.0 * k
	var h := head + ROW_H * k * guns.size() + foot
	var x := vs.x - (RIGHT * k + w) + (1.0 - e) * 30.0 * k
	var y := vs.y * 0.42 - h * 0.5
	var r := Rect2(Vector2(x, y), Vector2(w, h))
	UI.draw_chamfer(_root, r, 12.0 * k, Color(UI.GLASS, 0.6 * a))
	UI.draw_glass(_root, r, k, UI.SUIT_ORANGE, 0.6, a)
	# Header: the title, the Tab key, the material and the cooldown.
	var px := x + 14.0 * k
	UI.draw_text(_root, _f_caps, Vector2(px, y + 24.0 * k), "İKMAL KAPSÜLÜ", UI.fs(14, k), Color(UI.SUIT_WHITE, a), 2)
	var kw := UI.text_w(_f, "kapat", UI.fs(11, k))
	UI.draw_text_r(_root, _f, x + w - 12.0 * k, y + 23.0 * k, "kapat", UI.fs(11, k), Color(UI.DIM, a), 2)
	_key_cap(Vector2(x + w - 18.0 * k - kw - 30.0 * k, y + 10.0 * k), "Tab", k, false, a)
	var cl := SupplyPod.cooldown_left()
	var line := "Malzeme %d m³" % int(floorf(Game.material + 0.0001))
	var sub := ""
	var sub_col := UI.GOOD
	if SupplyPod.waiting():
		sub = "istek gönderildi…"
		sub_col = UI.WARN
	elif cl > 0.05:
		sub = "hazırlanıyor  %d sn" % ceili(cl)
		sub_col = UI.WARN
	else:
		sub = "hazır"
	UI.draw_text(_root, _f_n, Vector2(px, y + 46.0 * k), line, UI.fs(13, k), Color(UI.SUIT_ORANGE.lightened(0.15), a), 2)
	var lw := UI.text_w(_f_n, line, UI.fs(13, k))
	var rc := Vector2(px + lw + 18.0 * k, y + 41.5 * k)
	var frac := 1.0 - clampf(cl / maxf(SupplyPod.cooldown_total(), 0.01), 0.0, 1.0)
	UI.draw_ring(_root, rc, 6.0 * k, frac, Color(sub_col, a), maxf(2.0 * k, 1.5))
	UI.draw_text(_root, _f_b, Vector2(rc.x + 12.0 * k, y + 46.0 * k), sub, UI.fs(12, k), Color(sub_col, a), 2)
	# Rows.
	var ry := y + head
	for i in guns.size():
		_draw_row(Rect2(Vector2(x + 8.0 * k, ry), Vector2(w - 16.0 * k, ROW_H * k - 6.0 * k)), i, str(guns[i]), k, a)
		ry += ROW_H * k
	# Footer: what is coming, else how it works.
	var inc := SupplyPod.mine_incoming()
	var ft := "~%d sn'de yanına iner  ·  düşman görür, uçaksavar vurabilir  ·  ölünce gider" % int(roundf(Balance.SUPPLY_DELAY))
	var fc := Color(UI.FAINT.lerp(UI.TEXT, 0.3), a)
	if not inc.is_empty():
		var parts := PackedStringArray()
		for d in inc:
			parts.append("%s %d sn" % [SupplyPod.gun_name(str(d["gun"])), ceili(float(d["left"]))])
		ft = "Kapsül yolda: " + ", ".join(parts)
		fc = Color(UI.SCREEN_CYAN, a)
	UI.draw_text(_root, _f, Vector2(px, y + h - 15.0 * k), UI.ellipsize(_f, ft, UI.fs(11, k), w - 28.0 * k), UI.fs(11, k), fc, 2)


func _draw_row(r: Rect2, i: int, g: String, k: float, a: float) -> void:
	var why := SupplyPod.blocked(g)
	var ok := why == ""
	var fl := float(_flash.get(g, 0.0))
	var edge := Color(UI.BAD, 0.9 * fl * a) if fl > 0.01 else Color(UI.SUIT_WHITE, (0.2 if ok else 0.1) * a)
	UI.draw_chamfer(_root, r, 7.0 * k, Color(UI.GLASS_HI if ok else UI.GLASS, (0.85 if ok else 0.6) * a), edge)
	var dim := 1.0 if ok else 0.55
	_key_cap(r.position + Vector2(8.0, r.size.y * 0.5 / k - 10.0) * k, str(i + 1), k, ok, a * (1.0 if ok else 0.6))
	# The thumbnail.
	var tr := Rect2(r.position + Vector2(38.0 * k, 4.0 * k), Vector2(96.0 * k, r.size.y - 8.0 * k))
	var tex = BuildPreview.thumbs.get(str(Craft.recipe(g).get("thumb_id", "craft_" + g)))
	if tex is Texture2D and not (tex is PlaceholderTexture2D):
		var src := UI.tex_used_rect(tex)
		if src.size.x > 0.0 and src.size.y > 0.0:
			var s := minf(tr.size.x / src.size.x, tr.size.y / src.size.y)
			var sz := src.size * s
			_root.draw_texture_rect_region(tex, Rect2(tr.get_center() - sz * 0.5, sz), src, Color(1, 1, 1, a * dim))
	# Name, price, the state.
	var nx := tr.end.x + 10.0 * k
	UI.draw_text(_root, _f_b, Vector2(nx, r.position.y + 22.0 * k), SupplyPod.gun_name(g), UI.fs(15, k), Color(UI.TEXT, a * dim), 2)
	var c := SupplyPod.cost(g)
	var afford := Game.material + 0.001 >= c
	var cs := "%d m³" % int(c)
	UI.draw_text_r(_root, _f_n, r.end.x - 10.0 * k, r.position.y + 22.0 * k, cs, UI.fs(15, k),
			Color(UI.SUIT_ORANGE.lightened(0.15) if afford else UI.BAD, a), 2)
	var st := "çağır" if ok else why
	var sc := UI.SCREEN_CYAN if ok else (UI.BAD if not afford else UI.DIM)
	UI.draw_text(_root, _f, Vector2(nx, r.position.y + 41.0 * k), UI.ellipsize(_f, st, UI.fs(12, k), r.end.x - nx - 10.0 * k),
			UI.fs(12, k), Color(sc, a), 2)
	if SupplyPod.discount() > 0.001:
		var full := "%d" % int(float(Balance.SUPPLY_COST.get(g, 0.0)))
		var fw := UI.text_w(_f_n, cs, UI.fs(15, k))
		var ox := r.end.x - 14.0 * k - fw - UI.text_w(_f, full, UI.fs(11, k))
		UI.draw_text(_root, _f, Vector2(ox, r.position.y + 21.0 * k), full, UI.fs(11, k), Color(UI.FAINT, a), 0)
		var lw := UI.text_w(_f, full, UI.fs(11, k))
		_root.draw_line(Vector2(ox, r.position.y + 17.0 * k), Vector2(ox + lw, r.position.y + 17.0 * k), Color(UI.FAINT, a), 1.0)


func _key_cap(pos: Vector2, key: String, k: float, on: bool, a: float) -> void:
	UI.draw_key(_root, pos, key, k, on, a, 12)
