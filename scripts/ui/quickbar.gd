extends Control
## The quickbar (scripts/ui/hud.gd adds it; the user: "aşağıda quickbarda silahları göster, çok güzel
## olsun, oyun temasına uygun, ne kadar kaldı onu da göster"). A small bar at the bottom centre, laid
## out for 1080p and scaled with the window height:
##   [Q tarama]  [1 Matkap] [2 İnşa]  [3 gun] [4 gun] [5 gun] …  [G bomba] [Tab ikmal]
## 2026-10-06 ("2 silah sınırı da kalksın"): every carried gun has a slot (Game.carried_guns(): the
## loadout's guns + loot guns in Game.GUN_ORDER, keys 3, 4, … 9, 0); the bar grows with pickups. Up to
## FULL_MAX guns the slots are wide (thumbnail, name, magazine / reserve, mode); with more they turn
## compact (the thumbnail as an icon, the ammo under it) and the held gun's name, mode and tags float
## over its slot; the slot width eases between the two. No gun yet: one dimmed "boş" slot.
## Look: each slot is a little wrist-computer screen (scripts/player/wrist_display.gd: dark teal glass,
## faint scanlines) in a suit-white frame; the held slot lifts, the suit's orange strip on top and an
## accent line under it; a switch pops the new slot; a newly carried gun flashes.
## What is left, per slot:
##   guns     the rendered thumbnail (the Silahlık card's, scripts/war/build_preview.gd), the short name,
##            magazine (big) / reserve, a thin magazine bar (cyan, amber when low, red when nearly
##            empty), the fire mode (mode_text(): TEK / SERİ / ÜÇLÜ, the railgun's charge %), the
##            material price of a round once the reserve is gone (round_cost()), the reload progress;
##            the Kinetik İtici: its capacitor charges as pips (the recharging one filling) and the m³
##            a blast costs; the railgun: the charge (and the cooldown) in the bar; "GANİMET" (compact:
##            an amber corner) for a loot gun (picked up, never made: lost on death); a small weight
##            icon when it slows you (WEIGHT)
##   Matkap   the drill's mode (KAZ / YÜKSELT / DÜZLE) in its colour and the brush radius; its heat
##            bar (heat_info(): orange → white-hot, the vent window's amber zone / white sweet spot /
##            cyan marker, SÜPER KAZI ripples, red when locked), whose state replaces that line
##            ("R: SOĞUT", "SÜPER KAZI 5", "AŞIRI ISINDI" / "TIKANDI"); the tier after the name
##   İnşa     the selected build entry and its price (red when you cannot pay it)
##   Q        the tunnel scanner: a radial fill while it recharges, the seconds left
##   G        the grenade count (dimmed at 0)
##   Tab      İkmal kapsülü (scripts/war/supply_pod.gd, menu supply_menu.gd): a pod icon; the call
##            cooldown as a radial fill with the seconds left, a pod coming: its seconds in cyan
## (The F hold ring of a gun on the ground fills around the prompt's key: scripts/ui/hud.gd.)
## Hidden in a vehicle, while dead, while a UI panel is open (Game.ui_panel_open()), while the tree is
## paused and once the match is over (Game.match_over). HUD density Sade (scripts/ui/hud_mode.gd): only
## for REVEAL_S s after a switch, the wheel, Tab, a slot / G / Q key or a new gun, and while Alt is held.
## Look: the design system (scripts/ui/ui_style.gd): chamfered glass slots (UI.draw_glass), key caps,
## outlined text, tabular figures for the counts.

const UI := preload("res://scripts/ui/ui_style.gd")
const BuildPreview := preload("res://scripts/war/build_preview.gd")
const Craft := preload("res://scripts/war/craft.gd")
const WeaponDrop := preload("res://scripts/war/weapon_drop.gd")
const Balance := preload("res://scripts/war/balance.gd")
const HudMode := preload("res://scripts/ui/hud_mode.gd")

const REVEAL_S := 2.2                      # Sade: the bar stays this long after a switch / key
const REVEAL_ACTIONS := ["slot_1", "slot_2", "slot_3", "slot_4", "slot_5", "slot_6", "slot_7", "slot_8", "slot_9",
		"slot_10", "tool_drill", "tool_build", "throw_grenade", "scan_pulse", "supply_call"]
const H := 62.0
const W_GUN := 170.0                       # a wide gun slot (up to FULL_MAX guns)
const W_GUN_C := 84.0                      # a compact one
const FULL_MAX := 3
const W_TOOL := 122.0
const W_SIDE := 62.0
const W_SUPPLY := 66.0                     # the Tab İkmal slot
const GAP := 6.0
const SIDE_GAP := 14.0
const BOTTOM := 10.0
const LIFT := 7.0
# Palette: the suit (white shell, orange bands), the wrist screen (dark teal glass, cyan text).
const SUIT_WHITE := UI.SUIT_WHITE
const SUIT_ORANGE := UI.SUIT_ORANGE
const GLASS := UI.GLASS
const SCREEN_CYAN := UI.SCREEN_CYAN
const LOW := UI.WARN
const CRIT := UI.CRIT
const LOOT := Color(1.0, 0.68, 0.28)
const DRILL_SUPER := Color(0.45, 1.0, 0.95)    # the drill's SÜPER KAZI (terrain_tool.gd SUPER_COL)
const DRILL_MARKER := Color(0.4, 1.0, 1.0)     # its vent window marker
const SHORT := {"rifle": "Tüfek", "shotgun": "Pompalı", "sniper": "Keskin", "pusher": "İtici", "rocket": "Roketatar",
		"rail": "Raylı Tüfek", "smg": "Hafif Mak.", "dirt": "Toprak Topu", "plasma": "Plazma", "mortar": "Havan",
		"pistol": "Tabanca", "revolver": "Altıpatlar", "mpistol": "Mak. Tabanca"}

var _font: Font
var _font_b: Font
var _font_n: Font
var _alpha := 0.0
var _mode_a := 1.0                         # HUD density: Sade fades the bar between reveals
var _mode_held := "?"
var _guns: Array = []                      # Game.carried_guns() (key order)
var _lift_t := [0.0, 0.0]                  # drill, build tool (eased 0..1)
var _pop_t := [0.0, 0.0]
var _lift_g := {}                          # gun id -> eased 0..1
var _pop_g := {}                           # gun id -> a switch pop
var _flash_g := {}                         # gun id -> a newly carried gun's flash
var _held := ""                            # "t0" / "t1" (drill / build tool), "g:<id>", "" none
var _gw := W_GUN                           # the gun slot width (eased between wide and compact)
var _t := 0.0
var _k := 1.0
var _drawn := false
var _glow: GradientTexture2D                # the thumbnails' backlight


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UI.font(500)
	_font_b = UI.font(700)
	_font_n = UI.font_num(700)
	_guns = Game.carried_guns()
	_gw = W_GUN if _guns.size() <= FULL_MAX else W_GUN_C
	if Game.has_signal("loadout_changed"):
		Game.loadout_changed.connect(_on_loadout)
	_on_loadout()


## The carried guns changed: thumbnails for them, a flash on a gun that just joined.
func _on_loadout() -> void:
	var now := Game.carried_guns()
	var entries: Array = []
	for id in now:
		if not _guns.has(id) and is_inside_tree():
			_flash_g[id] = 1.0
			HudMode.reveal("quickbar", REVEAL_S + 1.0)
		var r := Craft.recipe(str(id))
		if r.has("item_script"):
			entries.append({"id": str(r.get("thumb_id", "craft_" + str(id))), "item_script": r["item_script"]})
	for id in _lift_g.keys():
		if not now.has(id):
			_lift_g.erase(id)
			_pop_g.erase(id)
			_flash_g.erase(id)
	_guns = now
	if not entries.is_empty() and is_inside_tree():
		BuildPreview.request_thumbs(get_tree(), entries)


func _wanted() -> bool:
	var p = Game.player
	if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
		return false
	if p.get("vehicle") != null or (p.has_method("is_dead") and p.is_dead()):
		return false
	if get_tree().paused:
		return false
	if Game.has_method("ui_panel_open") and Game.ui_panel_open():
		return false
	if Game.get("match_over") == true:
		return false
	return true


func _process(delta: float) -> void:
	_t += delta
	var want := _wanted()
	_alpha = move_toward(_alpha, 1.0 if want else 0.0, delta * (6.0 if want else 9.0))
	var p = Game.player
	var held := ""
	if p != null and is_instance_valid(p) and p.has_method("current"):
		var it = p.current()
		var hid := str(it.item_id) if it != null else ""
		if hid == "terrain":
			held = "t0"
		elif hid == "build":
			held = "t1"
		elif hid != "" and _guns.has(hid):
			held = "g:" + hid
	if held != _held:
		_held = held
		if held == "t0" or held == "t1":
			_pop_t[int(held.right(1))] = 1.0
		elif held != "":
			_pop_g[held.substr(2)] = 1.0
	for i in 2:
		_lift_t[i] = move_toward(float(_lift_t[i]), 1.0 if held == "t%d" % i else 0.0, delta * 7.0)
		_pop_t[i] = maxf(float(_pop_t[i]) - delta * 3.2, 0.0)
	for id in _guns:
		_lift_g[id] = move_toward(float(_lift_g.get(id, 0.0)), 1.0 if held == "g:" + str(id) else 0.0, delta * 7.0)
		_pop_g[id] = maxf(float(_pop_g.get(id, 0.0)) - delta * 3.2, 0.0)
		_flash_g[id] = maxf(float(_flash_g.get(id, 0.0)) - delta * 1.6, 0.0)
	_gw = move_toward(_gw, W_GUN if _guns.size() <= FULL_MAX else W_GUN_C, delta * 520.0)
	# HUD density (scripts/ui/hud_mode.gd): Sade shows the bar only for a moment after a switch, Tab,
	# the wheel, a slot / grenade / scanner key or a new gun (and while Alt is held), then fades it.
	if held != _mode_held:
		_mode_held = held
		HudMode.reveal("quickbar", REVEAL_S)
	if Game.has_meta("supply_menu") and is_instance_valid(Game.get_meta("supply_menu")) \
			and bool((Game.get_meta("supply_menu") as Node).get("_open")):
		HudMode.reveal("quickbar", 1.0)
	var on := HudMode.shown("quickbar")
	_mode_a = move_toward(_mode_a, 1.0 if on else 0.0, delta * (6.0 if on else 1.4))
	modulate.a = _alpha * UI.smooth(_mode_a)
	var vis := _alpha * _mode_a
	if vis > 0.001 or _drawn:
		_drawn = vis > 0.001                   # (one more redraw clears it once hidden)
		queue_redraw()


## Sade: a key that touches the bar brings it up for a moment (nothing is consumed).
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and (event as InputEventMouseButton).button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		HudMode.reveal("quickbar", REVEAL_S)
	elif event is InputEventKey and event.pressed and not event.echo:
		for a in REVEAL_ACTIONS:
			if InputMap.has_action(a) and event.is_action(a):
				HudMode.reveal("quickbar", REVEAL_S)
				return


# =================================================================================================
# Drawing
# =================================================================================================

func _draw() -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return
	var vs := size
	_k = clampf(vs.y / 1080.0, 0.7, 2.0)
	var k := _k
	if _alpha * _mode_a <= 0.001:
		return
	var n := _guns.size()
	var gw := (_gw if n > 0 else W_GUN_C) * k
	var gun_span := float(maxi(n, 1)) * gw + float(maxi(n, 1) - 1) * GAP * k
	var total := (W_SIDE * 2.0 + SIDE_GAP * 3.0 + W_TOOL * 2.0 + GAP + W_SUPPLY + GAP) * k + gun_span
	var x := vs.x * 0.5 - total * 0.5
	var y0 := vs.y - (BOTTOM + H) * k
	var h := H * k
	_draw_scan(p, Rect2(x, y0, W_SIDE * k, h))
	x += (W_SIDE + SIDE_GAP) * k
	for i in 2:
		_draw_tool(p, i, Rect2(x, y0 - _ease(float(_lift_t[i])) * LIFT * k, W_TOOL * k, h))
		x += (W_TOOL + (GAP if i == 0 else 0.0)) * k
	x += SIDE_GAP * k
	if n == 0:
		_draw_empty(Rect2(x, y0, gw, h))
	var label_at := Rect2()
	var label_id := ""
	for gi in n:
		var id := str(_guns[gi])
		var r := Rect2(x, y0 - _ease(float(_lift_g.get(id, 0.0))) * LIFT * k, gw, h)
		if gw >= (W_GUN_C + W_GUN) * 0.5 * k:
			_draw_gun(p, gi, id, r)
		else:
			_draw_gun_compact(p, gi, id, r)
			if _held == "g:" + id:
				label_at = r
				label_id = id
		x += gw + GAP * k
	x += maxf(gun_span - float(n) * (gw + GAP * k), 0.0) + (SIDE_GAP - GAP) * k + (GAP * k if n == 0 else 0.0)
	_draw_grenades(Rect2(x, y0, W_SIDE * k, h))
	_draw_supply(Rect2(x + (W_SIDE + GAP) * k, y0, W_SUPPLY * k, h))
	if label_id != "":
		_draw_held_label(p, label_id, label_at)


## No gun carried yet: one dimmed "boş" slot under key 3.
func _draw_empty(r: Rect2) -> void:
	var k := _k
	_glass(r, 0.35, 0.0, Color.WHITE, 0.0, 0.0)
	_dashed(r.grow(-3.0 * k), Color(SUIT_WHITE, 0.22), 6.0 * k)
	_badge(r.position + Vector2(6, 6) * k, Game.key_label(0), false, 0.5)
	var t := "boş"
	var fs := int(15 * k)
	var tw := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_txt(r.get_center() + Vector2(-tw * 0.5, fs * 0.45), t, fs, Color(UI.FAINT, 0.95), _font)


## A wide gun slot: thumbnail, name, tags, magazine / reserve and the mode.
func _draw_gun(p, gi: int, id: String, r: Rect2) -> void:
	var k := _k
	var held := _ease(float(_lift_g.get(id, 0.0)))
	var key := Game.key_label(gi)
	var i := int(p.item_index(id)) if p.has_method("item_index") else -1
	var it = p.items[i] if i >= 0 else null
	var col: Color = it.accent_color() if it != null and it.has_method("accent_color") else SCREEN_CYAN
	_glass(r, 1.0, held, col, float(_flash_g.get(id, 0.0)), float(_pop_g.get(id, 0.0)))
	if key != "":
		_badge(r.position + Vector2(6, 6) * k, key, held > 0.5, 1.0)
	# Thumbnail (the Silahlık card's render of the gun's own model), left and middle.
	var tex := _thumb_tex(id)
	var tr := Rect2(r.position + Vector2(6.0, 22.0) * k, Vector2(r.size.x * 0.56, r.size.y - 30.0 * k))
	if tex != null:
		_thumb(tr, tex, lerpf(0.82, 1.0, held))
	# Top row: the name; tags on the right (GANİMET, the weight, the fire mode).
	var nm := str(SHORT.get(id, it.item_name if it != null else id))
	_txt(r.position + Vector2(29.0, 18.0) * k, nm, int(13 * k), Color(SUIT_WHITE, lerpf(0.85, 1.0, held)), _font_b)
	var tx := r.end.x - 6.0 * k
	if Game.is_loot_gun(id):
		var tag := "GANİMET"
		var tfs := int(10 * k)
		var tw := _font_b.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs).x + 8.0 * k
		var pr := Rect2(Vector2(tx - tw, r.position.y + 6.0 * k), Vector2(tw, 14.0 * k))
		draw_style_box(UI.box(Color(LOOT, 0.9), int(3 * k), Color(0, 0, 0, 0), 0, 0), pr)
		draw_string(_font_b, pr.position + Vector2(4.0 * k, 11.0 * k), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, Color(0.1, 0.06, 0.02))
		tx = pr.position.x - 4.0 * k
	if it != null and it.has_method("carry_weight") and float(it.carry_weight()) < 0.995:
		tx = _heavy_tag(tx, r.position.y + 6.0 * k, 0.9) - 4.0 * k
	if it == null:
		return
	# Right block: what is left.
	var right := r.end.x - 8.0 * k
	var bar_r := Rect2(r.position + Vector2(6.0 * k, r.size.y - 5.0 * k), Vector2(r.size.x - 12.0 * k, 2.5 * k))
	var mt := str(it.mode_text()) if it.has_method("mode_text") else ""
	if it.has_method("max_charges"):
		_pusher_block(it, r, right, bar_r)
		if mt != "":
			var mfs := int(10 * k)
			var mw := _font_b.get_string_size(mt, HORIZONTAL_ALIGNMENT_LEFT, -1, mfs).x
			_txt(Vector2(tx - mw, r.position.y + 17.0 * k), mt, mfs, Color(SCREEN_CYAN, 0.95), _font_b)
	else:
		_ammo_block(it, r, right, bar_r, col, mt)


## A compact gun slot (many guns): the key, the thumbnail as an icon, the ammo under it, the bar;
## an amber corner for a loot gun, the weight icon. The held one's name / mode float over it.
func _draw_gun_compact(p, gi: int, id: String, r: Rect2) -> void:
	var k := _k
	var held := _ease(float(_lift_g.get(id, 0.0)))
	var key := Game.key_label(gi)
	var i := int(p.item_index(id)) if p.has_method("item_index") else -1
	var it = p.items[i] if i >= 0 else null
	var col: Color = it.accent_color() if it != null and it.has_method("accent_color") else SCREEN_CYAN
	_glass(r, 1.0, held, col, float(_flash_g.get(id, 0.0)), float(_pop_g.get(id, 0.0)))
	var loot := Game.is_loot_gun(id)
	if loot:
		var c := 13.0 * k
		draw_colored_polygon(PackedVector2Array([Vector2(r.end.x - c, r.position.y + 1.0), Vector2(r.end.x - 1.0, r.position.y + 1.0),
				Vector2(r.end.x - 1.0, r.position.y + c)]), Color(LOOT, 0.92))
	if key != "":
		_badge(r.position + Vector2(5, 5) * k, key, held > 0.5, 1.0)
	if it != null and it.has_method("carry_weight") and float(it.carry_weight()) < 0.995:
		_heavy_tag(r.end.x - (16.0 if loot else 5.0) * k, r.position.y + 5.0 * k, 0.9)
	var tex := _thumb_tex(id)
	if tex != null:
		_thumb(Rect2(r.position + Vector2(3.0, 20.0) * k, Vector2(r.size.x - 6.0 * k, r.size.y - 41.0 * k)), tex, lerpf(0.85, 1.0, held))
	if it == null:
		return
	var bar_r := Rect2(r.position + Vector2(6.0 * k, r.size.y - 5.0 * k), Vector2(r.size.x - 12.0 * k, 2.5 * k))
	var cx := r.get_center().x
	var base := r.end.y - 9.0 * k
	if it.has_method("max_charges"):
		# The pusher: "2/2" like the guns' ammo, a "ŞARJ" label, the bar in one segment per charge
		# (the recharging one filling).
		var nn := clampi(int(it.max_charges()), 1, 6)
		var have := int(it.get("mag")) if it.get("mag") != null else 0
		var part: float = float(it.charge_frac()) if it.has_method("charge_frac") else 0.0
		var pc := UI.SCREEN_CYAN
		var hs := str(have)
		var ns := "/%d" % nn
		var hfs := int(15 * k)
		var nfs := int(11 * k)
		var lf := UI.font_caps(700, 1)
		var lfs := int(9 * k)
		var hw := _font_n.get_string_size(hs, HORIZONTAL_ALIGNMENT_LEFT, -1, hfs).x
		var nw := _font.get_string_size(ns, HORIZONTAL_ALIGNMENT_LEFT, -1, nfs).x
		var lw := UI.text_w(lf, "ŞARJ", lfs)
		var tx1 := cx - (hw + nw + lw + 6.0 * k) * 0.5
		_txt(Vector2(tx1, base), hs, hfs, SUIT_WHITE if have > 0 else CRIT, _font_n)
		_txt(Vector2(tx1 + hw + 1.0 * k, base), ns, nfs, Color(UI.DIM, 0.95), _font)
		_txt(Vector2(tx1 + hw + nw + 5.0 * k, base - 1.0 * k), "ŞARJ", lfs, Color(pc, 0.9), lf)
		var f := (float(have) + (part if have < nn else 0.0)) / float(nn)
		UI.draw_seg_bar(self, bar_r, nn, clampf(f, 0.0, 1.0), Color(pc, 0.9), 2.0 * k)
		return
	var st := _ammo_state(it, col)
	if st.is_empty():
		return
	var mfs := int(15 * k)
	var sfs := int(11 * k)
	var ms := str(int(st["mag"]))
	var rs := ("/%d" % int(st["reserve"])) if int(st["reserve"]) >= 0 else ""
	var mw := _font_n.get_string_size(ms, HORIZONTAL_ALIGNMENT_LEFT, -1, mfs).x
	var rw := _font.get_string_size(rs, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x if rs != "" else 0.0
	var tx0 := cx - (mw + rw + (2.0 * k if rs != "" else 0.0)) * 0.5
	var mc: Color = st["mc"]
	_txt(Vector2(tx0, base), ms, mfs, mc, _font_n)
	if rs != "":
		_txt(Vector2(tx0 + mw + 2.0 * k, base), rs, sfs, Color(UI.DIM, 0.95), _font)
	var bc: Color = st["bc"]
	draw_rect(bar_r, Color(1, 1, 1, 0.08))
	draw_rect(Rect2(bar_r.position, Vector2(bar_r.size.x * float(st["fill"]), bar_r.size.y)), bc)


## Compact mode: the held gun's name, mode / reload and GANİMET over its slot.
func _draw_held_label(p, id: String, r: Rect2) -> void:
	var k := _k
	var a := _ease(float(_lift_g.get(id, 0.0)))
	if a <= 0.01:
		return
	var i := int(p.item_index(id)) if p.has_method("item_index") else -1
	var it = p.items[i] if i >= 0 else null
	var parts: Array = [str(SHORT.get(id, it.item_name if it != null else id))]
	if it != null:
		if it.get("reloading") == true:
			parts.append("DOLUYOR")
		elif it.has_method("mode_text") and str(it.mode_text()) != "":
			parts.append(str(it.mode_text()))
	if Game.is_loot_gun(id):
		parts.append("GANİMET")
	var s := "  ·  ".join(parts)
	var fs := int(12 * k)
	var w := _font_b.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	# On a glass pill: readable over the view model's arms and the wrist screen.
	var pr := Rect2(Vector2(r.get_center().x - w * 0.5 - 8.0 * k, r.position.y - 23.0 * k), Vector2(w + 16.0 * k, 19.0 * k))
	UI.draw_chamfer(self, pr, 5.0 * k, Color(GLASS, 0.88 * a), Color(SUIT_WHITE, 0.2 * a))
	_txt(Vector2(r.get_center().x - w * 0.5, r.position.y - 9.0 * k), s, fs, Color(SUIT_WHITE, 0.95 * a), _font_b)


func _thumb_tex(id: String) -> Texture2D:
	var rc := Craft.recipe(id)
	var tex = BuildPreview.thumbs.get(str(rc.get("thumb_id", "craft_" + id)))
	if tex is Texture2D and not (tex is PlaceholderTexture2D):
		return tex
	return null


## Magazine, capacity, reserve and the bar of a gun: {mag, cap, frac, reserve (-1: none), mc (the
## count's colour), fill, bc (the bar: the magazine, the reload, the railgun's charge / cooldown)}.
func _ammo_state(it, col: Color) -> Dictionary:
	var mag := _mag(it)
	if mag < 0:
		return {}
	var cap := maxi(int(it.call("mag_capacity")), 1) if it.has_method("mag_capacity") else maxi(mag, 1)
	var frac := clampf(float(mag) / float(cap), 0.0, 1.0)
	var ammo := WeaponDrop.gun_ammo_id(it)
	var reserve := Game.ammo_reserve(ammo) if ammo != "" else -1
	var mc := SUIT_WHITE if frac > 0.34 else (LOW if frac > 0.15 and mag > 0 else CRIT)
	var fill := frac
	var bc := SCREEN_CYAN if frac > 0.34 else (LOW if frac > 0.15 and mag > 0 else CRIT)
	if it.get("reloading") == true and it.has_method("reload_progress"):
		fill = clampf(float(it.reload_progress()), 0.0, 1.0)
		bc = SUIT_ORANGE
	elif it.get("charging") == true and it.get("charge") != null:
		fill = clampf(float(it.charge), 0.0, 1.0)
		bc = col.lerp(Color.WHITE, 0.3)
	elif it.get("cool") != null and float(it.cool) > 0.0 and it.get("cool_total") != null:
		fill = 1.0 - clampf(float(it.cool) / maxf(float(it.cool_total), 0.01), 0.0, 1.0)
		bc = Color(col, 0.6)
	return {"mag": mag, "cap": cap, "frac": frac, "reserve": reserve, "mc": mc, "fill": fill, "bc": bc}


## Magazine (big) / reserve, the bar; the middle row: reloading, else the fire mode (the railgun's
## charge), else the round price once the reserve is gone.
func _ammo_block(it, r: Rect2, right: float, bar_r: Rect2, col: Color, mt: String) -> void:
	var k := _k
	var st := _ammo_state(it, col)
	if st.is_empty():
		return
	var mag := int(st["mag"])
	var reserve := int(st["reserve"])
	var mfs := int(21 * k)
	var sub := ("/ %d" % reserve) if reserve >= 0 else ""
	var sfs := int(12 * k)
	var sw := _font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x if sub != "" else 0.0
	var mc: Color = st["mc"]
	_txt_r(right - sw - (3.0 * k if sub != "" else 0.0), r.position.y + 52.0 * k, str(mag), mfs, mc, _font_n)
	if sub != "":
		_txt_r(right, r.position.y + 52.0 * k, sub, sfs, Color(UI.DIM, 0.95), _font)
	var cost: float = float(it.round_cost()) if it.has_method("round_cost") else 0.0
	var mid := ""
	var mid_col := Color(SCREEN_CYAN, 0.95)
	if it.get("reloading") == true:
		mid = "DOLUYOR"
		mid_col = Color(SUIT_ORANGE, 0.75 + 0.25 * sin(_t * 9.0))
	elif mt != "":
		mid = mt
	elif reserve == 0 and cost > 0.0:
		mid = "mermi %s m³" % String.num(cost, 2)          # (the next reload buys from material)
		mid_col = Color(LOW, 0.95)
	if mid != "":
		_txt_r(right, r.position.y + 33.0 * k, mid, int(10 * k), mid_col, _font_b)
	var bc: Color = st["bc"]
	draw_rect(bar_r, Color(1, 1, 1, 0.08))
	draw_rect(Rect2(bar_r.position, Vector2(bar_r.size.x * float(st["fill"]), bar_r.size.y)), bc)


## The Kinetik İtici: its capacitor charges as pips, the recharging one filling; the m³ per blast.
func _pusher_block(it, r: Rect2, right: float, bar_r: Rect2) -> void:
	var k := _k
	var n := clampi(int(it.max_charges()), 1, 6)
	var have := int(it.get("mag")) if it.get("mag") != null else 0
	var part: float = float(it.charge_frac()) if it.has_method("charge_frac") else 0.0
	var pw := 13.0 * k
	var ph := 9.0 * k
	var gap := 4.0 * k
	var x0 := right - n * pw - (n - 1) * gap
	var y := r.position.y + 40.0 * k
	var pc := Color(0.55, 0.85, 1.0)
	for i in n:
		var pr := Rect2(Vector2(x0 + i * (pw + gap), y), Vector2(pw, ph))
		draw_rect(pr, Color(1, 1, 1, 0.1))
		if i < have:
			draw_rect(pr, pc)
		elif i == have:
			draw_rect(Rect2(pr.position, Vector2(pw * part, ph)), Color(pc, 0.55))
	var cost: float = float(it.shot_cost()) if it.has_method("shot_cost") else 0.0
	if cost > 0.0:
		_txt_r(right, r.position.y + 33.0 * k, "%s m³/atış" % String.num(cost, 0), int(10 * k), Color(UI.DIM, 0.95), _font_b)
	draw_rect(bar_r, Color(1, 1, 1, 0.08))
	var f := (float(have) + (part if have < n else 0.0)) / float(n)
	draw_rect(Rect2(bar_r.position, Vector2(bar_r.size.x * clampf(f, 0.0, 1.0), bar_r.size.y)), Color(pc, 0.9))


func _draw_tool(p, i: int, r: Rect2) -> void:
	var k := _k
	var id := "terrain" if i == 0 else "build"
	var j := int(p.item_index(id)) if p.has_method("item_index") else -1
	var it = p.items[j] if j >= 0 else null
	var held := _ease(float(_lift_t[i]))
	var col := SCREEN_CYAN
	var line := ""
	var line_col := Color(UI.DIM, 0.95)
	if i == 0 and it != null:
		var mc = it.MODE_COLORS[it.work_mode] if it.get("MODE_COLORS") != null and it.get("work_mode") != null else null
		if mc is Color:
			col = mc
		var mn := str(it.mode_name()).to_upper() if it.has_method("mode_name") else ""
		var rad = it.get("radius")
		line = mn
		if rad != null:
			line += ("  ·  " if line != "" else "") + "%s m" % String.num(float(rad), 1)
		line_col = col.lightened(0.3)
	elif it != null:
		if it.has_method("accent_color"):
			col = it.accent_color()
		var e = it.call("current_entry") if it.has_method("current_entry") else null
		if e is Dictionary and not (e as Dictionary).is_empty():
			var price := float((e as Dictionary).get("cost", 0.0))
			line = "%s  %d" % [str((e as Dictionary).get("name", "")), int(price)]
			line_col = Color(UI.DIM, 0.95) if Game.material + 0.001 >= price else Color(CRIT, 0.95)
	_glass(r, 1.0, held, col, 0.0, float(_pop_t[i]))
	_badge(r.position + Vector2(6, 6) * k, "Z" if i == 0 else "X", held > 0.5, 1.0)      # tools off the number row (game.gd)
	_txt(r.position + Vector2(29.0, 18.0) * k, "Matkap" if i == 0 else "İnşa", int(13 * k), Color(SUIT_WHITE, lerpf(0.85, 1.0, held)), _font_b)
	if i == 0 and it != null and it.get("tier") != null and int(it.get("tier")) > 0:
		# The drill's upgrade tier (Mk II-IV): one small pip per tier left of the icon, in its colour.
		var hi: Dictionary = it.heat_info() if it.has_method("heat_info") else {}
		var tc: Color = hi.get("tier_col", SUIT_ORANGE)
		for n in int(it.get("tier")):
			draw_rect(Rect2(r.end.x - (33.0 + n * 5.0) * k, r.position.y + 9.0 * k, 3.0 * k, 9.0 * k), Color(tc, 0.95))
	var ic := Vector2(r.end.x - 20.0 * k, r.position.y + 14.0 * k)
	if i == 0:
		_icon_drill(ic, 9.0 * k, Color(col.lightened(0.2), lerpf(0.75, 1.0, held)))
	else:
		_icon_build(ic, 8.0 * k, Color(col.lightened(0.2), lerpf(0.75, 1.0, held)))
	if i == 0 and it != null and it.has_method("heat_info"):
		var st := _drill_heat(it, r)
		if st != "":
			line = st
			line_col = Color.WHITE
			var hi: Dictionary = it.heat_info()
			if bool(hi.get("locked", false)):
				line_col = Color(CRIT, 1.0 if fmod(_t * 3.0, 1.0) >= 0.5 else 0.6)
			elif float(hi.get("boost", 0.0)) > 0.0:
				line_col = DRILL_SUPER
			elif fmod(_t, 0.5) >= 0.28:
				line_col = LOW
	if line != "":
		var fs := int(12 * k)
		_txt(r.position + Vector2(8.0 * k, r.size.y - 12.0 * k), _fit(line, _font_b, fs, r.size.x - 16.0 * k), fs, line_col, _font_b)


## The drill's heat bar (terrain_tool.gd heat_info(): heat, the vent window, SÜPER KAZI, a lockout)
## across the slot under its name; returns the state line that replaces mode · radius ("" = none):
## "R: SOĞUT" in a vent window, "SÜPER KAZI 5", "AŞIRI ISINDI" / "TIKANDI".
func _drill_heat(it, r: Rect2) -> String:
	var k := _k
	var hi: Dictionary = it.heat_info()
	var h := clampf(float(hi.get("heat", 0.0)), 0.0, 1.0)
	var window := bool(hi.get("window", false))
	var locked := bool(hi.get("locked", false))
	var boost := float(hi.get("boost", 0.0))
	var b := Rect2(r.position + Vector2(8.0, 27.0) * k, Vector2(r.size.x - 16.0 * k, 5.0 * k))
	draw_rect(b, Color(0.0, 0.02, 0.03, 0.55))
	var hot := Color(1.0, 0.34, 0.08).lerp(Color(1.0, 0.62, 0.2), clampf(h / 0.6, 0.0, 1.0)) if h < 0.6 \
			else Color(1.0, 0.62, 0.2).lerp(Color(1.0, 0.96, 0.86), clampf((h - 0.6) / 0.4, 0.0, 1.0))
	if locked:
		hot = CRIT
	if h > 0.003:
		draw_rect(Rect2(b.position, Vector2(b.size.x * h, b.size.y)), Color(hot, 0.35 if window else 0.95))
	draw_rect(Rect2(b.position.x + b.size.x * 0.6 - 0.5 * k, b.position.y - 1.0 * k, 1.0 * k, b.size.y + 2.0 * k), Color(SUIT_WHITE, 0.3))
	var state := ""
	if window and not locked:
		var gd: Vector2 = hi.get("good", Vector2(0.45, 0.79))
		var sw: Vector2 = hi.get("sweet", Vector2(0.55, 0.68))
		draw_rect(Rect2(b.position.x + b.size.x * gd.x, b.position.y, b.size.x * (gd.y - gd.x), b.size.y), Color(1.0, 0.7, 0.28, 0.65))
		draw_rect(Rect2(b.position.x + b.size.x * sw.x, b.position.y, b.size.x * (sw.y - sw.x), b.size.y), Color(1, 1, 1, 0.95))
		var mx := b.position.x + b.size.x * clampf(float(hi.get("marker", 0.0)), 0.0, 1.0)
		draw_rect(Rect2(mx - 1.5 * k, b.position.y - 3.0 * k, 3.0 * k, b.size.y + 6.0 * k), DRILL_MARKER)
		state = "R: SOĞUT"
	elif locked:
		state = "TIKANDI" if int(hi.get("lock_kind", 0)) == 1 else "AŞIRI ISINDI"
	elif boost > 0.0:
		for n in 5:
			var u := fmod(_t * 0.9 + n / 5.0, 1.0)
			draw_rect(Rect2(b.position.x + b.size.x * u - 2.0 * k, b.position.y, 4.0 * k, b.size.y), Color(DRILL_SUPER, 0.5 * boost))
		state = "SÜPER KAZI %d" % ceili(float(hi.get("boost_s", 0.0)))
	var fl := float(hi.get("flash", 0.0))
	if fl > 0.0:
		var fk := int(hi.get("flash_kind", 0))
		var fc := Color.WHITE if fk == 1 else (LOW if fk == 2 else CRIT)
		draw_rect(b.grow(1.0 * k), Color(fc, 0.5 * fl))
	return state


func _draw_scan(p, r: Rect2) -> void:
	var k := _k
	var ha = p.get("hand_action")
	var sc = ha.get("scanner") if ha != null else null
	var left := float(sc.cooldown_left()) if sc != null and sc.has_method("cooldown_left") else 0.0
	var ok := left <= 0.05
	var col := Color(0.45, 1.0, 0.75)
	_glass(r, 0.85, 0.0, col, 0.0, 0.0)
	_badge(r.position + Vector2(5, 5) * k, "Q", false, 0.95 if ok else 0.55)
	var c := r.get_center() + Vector2(3.0, 5.0) * k
	var rr := 15.0 * k
	if not ok:
		var frac := 1.0 - clampf(left / maxf(Balance.SCAN_COOLDOWN, 0.01), 0.0, 1.0)
		# Radial fill: a pie sector growing clockwise from the top.
		var pts := PackedVector2Array([c])
		var seg := 28
		for n in seg + 1:
			var a := -PI * 0.5 + TAU * frac * float(n) / float(seg)
			pts.append(c + Vector2(cos(a), sin(a)) * rr)
		if frac > 0.01:
			draw_colored_polygon(pts, Color(col, 0.16))
		draw_arc(c, rr, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, Color(col, 0.75), 2.0 * k, true)
		_icon_scan(c, 10.0 * k, Color(col, 0.4))
		_txt_r(r.end.x - 5.0 * k, r.end.y - 5.0 * k, "%d s" % ceili(left), int(11 * k), Color(UI.DIM, 0.95), _font_b)
	else:
		draw_arc(c, rr, 0.0, TAU, 32, Color(col, 0.35 + 0.15 * sin(_t * 2.5)), 1.5 * k, true)
		_icon_scan(c, 10.0 * k, Color(col, 0.95))


func _draw_grenades(r: Rect2) -> void:
	var k := _k
	var n := Game.grenades
	var col := SUIT_ORANGE
	_glass(r, 0.85, 0.0, col, 0.0, 0.0)
	_badge(r.position + Vector2(5, 5) * k, "G", false, 0.95 if n > 0 else 0.5)
	_icon_grenade(r.get_center() + Vector2(-9.0, 6.0) * k, 8.0 * k, Color(col, 0.95 if n > 0 else 0.3))
	_txt_r(r.end.x - 6.0 * k, r.end.y - 9.0 * k, "%d" % n, int(20 * k), Color(SUIT_WHITE, 0.98) if n > 0 else Color(UI.FAINT, 0.8), _font_n)


## Tab: İkmal kapsülü (scripts/war/supply_pod.gd): the cooldown as a radial fill, a pod coming.
func _draw_supply(r: Rect2) -> void:
	var k := _k
	var sp = _supply_api()
	var left: float = float(sp.cooldown_left()) if sp != null else 0.0
	var total: float = float(sp.cooldown_total()) if sp != null else 1.0
	var inc: Array = sp.mine_incoming() if sp != null else []
	var ok := left <= 0.05 and inc.is_empty()
	var col := Color(1.0, 0.62, 0.25)
	_glass(r, 0.85, 0.0, col, 0.0, 0.0)
	UI.draw_key(self, r.position + Vector2(5, 5) * k, "Tab", k * 0.8, false, 0.95 if ok else 0.55, 12)
	var c := r.get_center() + Vector2(-8.0, 7.0) * k
	var rr := 13.0 * k
	if not inc.is_empty():
		_icon_pod(c, 8.0 * k, Color(UI.SCREEN_CYAN, 0.6 + 0.4 * sin(_t * 8.0)))
		_txt_r(r.end.x - 5.0 * k, r.end.y - 6.0 * k, "%d s" % ceili(float(inc[0]["left"])), int(12 * k), UI.SCREEN_CYAN, _font_b)
	elif not ok:
		var frac := 1.0 - clampf(left / maxf(total, 0.01), 0.0, 1.0)
		var pts := PackedVector2Array([c])
		for n in 29:
			var a := -PI * 0.5 + TAU * frac * float(n) / 28.0
			pts.append(c + Vector2(cos(a), sin(a)) * rr)
		if frac > 0.01:
			draw_colored_polygon(pts, Color(col, 0.16))
		draw_arc(c, rr, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, Color(col, 0.75), 2.0 * k, true)
		_icon_pod(c, 7.0 * k, Color(col, 0.4))
		_txt_r(r.end.x - 5.0 * k, r.end.y - 5.0 * k, "%d s" % ceili(left), int(11 * k), Color(UI.DIM, 0.95), _font_b)
	else:
		draw_arc(c, rr, 0.0, TAU, 32, Color(col, 0.35 + 0.15 * sin(_t * 2.5)), 1.5 * k, true)
		_icon_pod(c, 7.0 * k, Color(col, 0.95))
		_txt_r(r.end.x - 5.0 * k, r.end.y - 6.0 * k, "ikmal", int(10 * k), Color(UI.DIM, 0.95), _font_b)


## The supply pod script once it is loaded (Game.reset_state / the menu load it; never preloaded here).
func _supply_api():
	if ResourceLoader.has_cached("res://scripts/war/supply_pod.gd"):
		var s = load("res://scripts/war/supply_pod.gd")
		if s is Script and (s as Script).can_instantiate():
			return s
	return null


## A small supply pod: the capsule, a band, the shield.
func _icon_pod(c: Vector2, s: float, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([c + Vector2(-s * 0.5, -s), c + Vector2(s * 0.5, -s), c + Vector2(s * 0.68, s * 0.7),
			c + Vector2(-s * 0.68, s * 0.7)]), col)
	draw_rect(Rect2(c + Vector2(-s * 0.62, -s * 0.12), Vector2(s * 1.24, s * 0.2)), Color(GLASS, col.a * 0.8))
	draw_colored_polygon(PackedVector2Array([c + Vector2(-s * 0.68, s * 0.78), c + Vector2(s * 0.68, s * 0.78),
			c + Vector2(s * 0.34, s * 1.1), c + Vector2(-s * 0.34, s * 1.1)]), col)


# --- Helpers ---------------------------------------------------------------------------------------

## A slot: wrist-screen glass with faint scanlines in a suit-white frame; held: the frame goes white,
## the suit's orange strip on top, an accent line under it, a soft glow. fl: a flash (a new gun),
## pop: the switch pop.
func _glass(r: Rect2, a: float, held: float, col: Color, fl: float, pop: float) -> void:
	var k := _k
	# The design system's plate: chamfered glass, scanlines, the orange strip on top when held; a
	# darker underlay so the view model's arms behind it do not show through.
	UI.draw_chamfer(self, r, 8.0 * k, Color(GLASS, 0.55 * a))
	UI.draw_glass(self, r, k, col, held, a, true, 8.0)
	if fl > 0.0:
		UI.draw_chamfer(self, r, 8.0 * k, Color(col, 0.1 * fl), Color(col.lightened(0.4), 0.9 * fl), 2)
	if held > 0.01:
		var w := (r.size.x - 20.0 * k) * held
		draw_rect(Rect2(Vector2(r.get_center().x - w * 0.35, r.end.y + 3.0 * k), Vector2(w * 0.7, 2.0 * k)), Color(col, 0.85 * held))
	if pop > 0.01:
		var g := r.grow((1.0 - pop) * 7.0 * k)
		UI.draw_chamfer(self, g, (8.0 + (1.0 - pop) * 5.0) * k, Color(0, 0, 0, 0), Color(SUIT_WHITE, 0.5 * pop), 2)


## The key: a little white suit plate (held: orange) with the key in dark.
func _badge(pos: Vector2, key: String, on: bool, a: float) -> void:
	var k := _k
	var r := Rect2(pos, Vector2(17, 17) * k)
	UI.draw_chamfer(self, r, 4.0 * k, Color(SUIT_ORANGE, 0.95 * a) if on else Color(SUIT_WHITE, 0.85 * a))
	var fs := int(12 * k)
	var w := _font_b.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font_b, pos + Vector2(r.size.x * 0.5 - w * 0.5, 13.0 * k), key, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			Color(UI.INK, a))


## The gun's thumbnail filling `rect`: only the model's pixels (the render's empty margin is cropped,
## UI.tex_used_rect), backlit by a soft cyan glow.
func _thumb(rect: Rect2, tex: Texture2D, a: float) -> void:
	var src := UI.tex_used_rect(tex)
	if src.size.x <= 0.0 or src.size.y <= 0.0:
		return
	var s := minf(rect.size.x / src.size.x, rect.size.y / src.size.y)
	var sz := src.size * s
	var dst := Rect2(rect.get_center() - sz * 0.5, sz)
	if _glow == null:
		_glow = _radial_glow()
	draw_texture_rect(_glow, dst.grow_individual(sz.x * 0.08, sz.y * 0.9, sz.x * 0.08, sz.y * 0.9), false, Color(1, 1, 1, 0.8 * a))
	draw_texture_rect_region(tex, dst, src, Color(1, 1, 1, a))


static func _radial_glow() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(0.45, 0.85, 1.0, 0.32))
	g.set_color(1, Color(0.45, 0.85, 1.0, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 64
	gt.height = 64
	return gt


## "AĞIR" (the gun slows you while held): a small amber caps tag right-aligned at `right`; returns its
## left edge.
func _heavy_tag(right: float, top: float, a: float) -> float:
	var k := _k
	var f := UI.font_caps(700, 1)
	var fs := int(9 * k)
	var w := UI.text_w(f, "AĞIR", fs) + 8.0 * k
	var r := Rect2(Vector2(right - w, top), Vector2(w, 13.0 * k))
	UI.draw_chamfer(self, r, 3.0 * k, Color(UI.WARN, 0.18 * a), Color(UI.WARN, 0.65 * a))
	draw_string(f, r.position + Vector2(4.0 * k, 10.0 * k), "AĞIR", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(UI.WARN.lightened(0.3), a))
	return r.position.x


func _dashed(r: Rect2, col: Color, dash: float) -> void:
	var pts := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), r.position]
	for i in 4:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var dist := a.distance_to(b)
		var dir := (b - a) / maxf(dist, 0.001)
		var d := 0.0
		while d < dist:
			draw_line(a + dir * d, a + dir * minf(d + dash, dist), col, 1.0, true)
			d += dash * 2.0


func _txt(pos: Vector2, s: String, sz: int, col: Color, f: Font) -> void:
	UI.draw_text(self, f, pos, s, sz, col, 2)


func _txt_r(right: float, baseline: float, s: String, sz: int, col: Color, f: Font) -> void:
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	_txt(Vector2(right - w, baseline), s, sz, col, f)


## `s` cut to max_w px (with "…").
func _fit(s: String, f: Font, sz: int, max_w: float) -> String:
	if f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x <= max_w:
		return s
	var t := s
	while t.length() > 1 and f.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x > max_w:
		t = t.left(t.length() - 1)
	return t + "…"


func _mag(it) -> int:
	if it == null:
		return -1
	if it.has_method("mag_count"):
		return int(it.mag_count())
	if it.get("mag") != null:
		return int(it.mag)
	return -1


static func _ease(v: float) -> float:
	var x := clampf(v, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


# --- Icons (vector, scaled) ------------------------------------------------------------------------

## A drill: a body with a grip and a pointed, grooved bit (pointing right).
func _icon_drill(c: Vector2, s: float, col: Color) -> void:
	draw_rect(Rect2(c + Vector2(-s, -s * 0.38), Vector2(s * 1.0, s * 0.76)), col)
	draw_rect(Rect2(c + Vector2(-s * 0.7, s * 0.38), Vector2(s * 0.36, s * 0.62)), col)
	var tip := PackedVector2Array([c + Vector2(0.0, -s * 0.3), c + Vector2(s * 1.05, 0.0), c + Vector2(0.0, s * 0.3)])
	draw_colored_polygon(tip, col)
	for g in 2:
		var gx := s * (0.25 + g * 0.3)
		draw_line(c + Vector2(gx, -s * 0.24 * (1.0 - gx / (s * 1.05))), c + Vector2(gx + s * 0.12, s * 0.2 * (1.0 - gx / (s * 1.05))),
				Color(GLASS, col.a), maxf(1.0, s * 0.1), true)


## A build crate: an isometric cube outline.
func _icon_build(c: Vector2, s: float, col: Color) -> void:
	var top := c + Vector2(0, -s)
	var l := c + Vector2(-s * 0.87, -s * 0.5)
	var rr := c + Vector2(s * 0.87, -s * 0.5)
	var bl := c + Vector2(-s * 0.87, s * 0.5)
	var br := c + Vector2(s * 0.87, s * 0.5)
	var bot := c + Vector2(0, s)
	var w := maxf(1.5, s * 0.16)
	draw_polyline(PackedVector2Array([top, rr, br, bot, bl, l, top]), col, w, true)
	draw_polyline(PackedVector2Array([l, c, rr]), col, w, true)
	draw_line(c, bot, col, w, true)


## A grenade: a round body, the spoon and the pin ring.
func _icon_grenade(c: Vector2, s: float, col: Color) -> void:
	draw_circle(c, s, col)
	draw_rect(Rect2(c + Vector2(-s * 0.35, -s * 1.45), Vector2(s * 0.7, s * 0.55)), col)
	draw_line(c + Vector2(s * 0.3, -s * 1.2), c + Vector2(s * 0.95, -s * 0.4), col, maxf(1.0, s * 0.18), true)
	draw_arc(c + Vector2(-s * 0.75, -s * 1.25), s * 0.38, 0.0, TAU, 16, col, maxf(1.0, s * 0.14), true)
	draw_line(c + Vector2(-s * 0.85, -s * 0.05), c + Vector2(s * 0.85, -s * 0.05), Color(GLASS, col.a * 0.7), maxf(1.0, s * 0.12), true)


## The scanner: a dot and three widening arcs (a radar pulse).
func _icon_scan(c: Vector2, s: float, col: Color) -> void:
	var o := c + Vector2(-s * 0.6, s * 0.45)
	draw_circle(o, s * 0.16, col)
	for i in 3:
		var rr := s * (0.42 + i * 0.36)
		draw_arc(o, rr, -PI * 0.5, 0.0, 14, Color(col, col.a * (1.0 - i * 0.22)), maxf(1.2, s * 0.13), true)


## A small kettlebell: the gun slows you while held.
func _icon_weight(c: Vector2, s: float, col: Color) -> void:
	var body := PackedVector2Array([c + Vector2(-s * 0.62, -s * 0.15), c + Vector2(s * 0.62, -s * 0.15),
			c + Vector2(s * 0.85, s * 0.85), c + Vector2(-s * 0.85, s * 0.85)])
	draw_colored_polygon(body, col)
	draw_arc(c + Vector2(0, -s * 0.2), s * 0.45, PI, TAU, 12, col, maxf(1.0, s * 0.22), true)
