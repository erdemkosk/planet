extends Control
## YÜKLEME, the loadout picker (2026-10-06, the user: start armed, pick on the respawn ride like CoD).
## Repurposed from the Silahlık's read-only CEPHANELİK page. Everyone spawns with slot A
## (Balance.LOADOUT_A: ANA SİLAH, the primary: Tüfek / Hafif Makineli / Pompalı) and slot B (one of
## Balance.LOADOUT_B: YAN SİLAH, a sidearm or utility: Tabanca / Altıpatlar / Makineli Tabanca /
## Toprak Topu); power weapons come by İkmal kapsülü (scripts/war/supply_pod.gd, Tab). Drawn in the
## design system's look (scripts/ui/ui_style.gd): two columns (2026-10-07), slot A's on the left, slot
## B's on the right, one row card per choice with its key, the rendered thumbnail
## (scripts/war/build_preview.gd), the Turkish name, a one-line role (ROLE) and a stats line
## (scripts/war/craft.gd recipe data); the pick has the orange frame and "SEÇİLİ". Hover lifts a card.
## Click a card, or keys: Q / E cycle slot A, 1, 2, 3, 4 pick slot B in order, ← / → the character (the
## KARAKTER strip under the cards, scripts/war/heroes/hero_picker.gd: Heroes.pick) (the column headers and
## the footer show them).
## Modes (setup(mode)):
##   MODE_ARMORY  a tab of scripts/war/craft_menu.gd (laid out at the crafting grid's size): a pick
##                applies at once (Game.set_loadout: you stand at your Silahlık)
##   MODE_RIDE    the respawn dropship ride (scripts/war/respawn_ship.gd hosts it in a gameplay
##                overlay layer): the pick waits in pick_a / pick_b, the landing applies it
##   MODE_START   once at the match start (respawn_ship.gd; modal: in Game.ui_panels while open, so
##                is_open()); a pick applies at once; Enter / Space / Esc or HAZIR closes it (`done`)
## Ride / start are framed: the panel draws its own glass plate and title at FRAMED_SIZE (the host
## scales and places it).
##   set_page_size(Vector2)   cancel_drag()   (craft_menu.gd contract)
##   setup(mode)   key_pick(n)   cycle_a(dir)   is_open()   signal picked(a, b)   signal done

const UI := preload("res://scripts/ui/ui_style.gd")
const Balance := preload("res://scripts/war/balance.gd")
const BuildPreview := preload("res://scripts/war/build_preview.gd")
const Craft := preload("res://scripts/war/craft.gd")
const WeaponDrop := preload("res://scripts/war/weapon_drop.gd")

const MODE_ARMORY := 0
const MODE_RIDE := 1
const MODE_START := 2
const HeroPicker := preload("res://scripts/war/heroes/hero_picker.gd")   # the KARAKTER strip under the cards
const HERO_STRIP := 164.0               # its height + the gap over it (HeroPicker.SIZE.y + 14)
const FRAMED_SIZE := Vector2(860, 480 + 164)
const GAP := 14.0
const GROUP_GAP := 36.0
const ROW_GAP := 8.0                     # between the row cards of a column
## One line per choice: what it is for (the card's role line).
const ROLE := {
	"rifle": "Her mesafede güvenilir: tek atış ya da seri.",
	"smg": "Yakın dövüş: çok hızlı ateş, uzakta zayıf.",
	"shotgun": "Dar alanda yıkıcı, menzili kısa.",
	"pistol": "Çok hızlı çekilir, isabetli: şarjör bitince kurtarır.",
	"revolver": "Ağır ve yavaş: yakında kafaya tek atış.",
	"mpistol": "Yakında mermi yağmuru, sert yukarı teper.",
	"dirt": "Kazdığın toprağı atar: tümsek, siper, tıkaç.",
}

signal picked(a: String, b: String)
signal done

var mode := MODE_ARMORY
var page_size := Vector2(898, 650)       # set by craft_menu.gd (the crafting grid's size) / FRAMED_SIZE
var pick_a := ""
var pick_b := ""
var modal_open := false                  # MODE_START: registered in Game.ui_panels
var _font: Font
var _font_b: Font
var _font_n: Font
var _lift := {}                          # "a:<id>" / "b:<id>" -> eased hover 0..1
var _mouse := Vector2(-100000.0, -100000.0)
var _t := 0.0
var _thumbs_asked := false
var _pop := {}                           # card key -> a pick's pop 0..1
var _hero: Control                       # the KARAKTER strip (scripts/war/heroes/hero_picker.gd)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = UI.font(500)
	_font_b = UI.font(700)
	_font_n = UI.font_num(700)
	custom_minimum_size = page_size
	_sync_from_game()
	_hero = HeroPicker.new()
	_hero.name = "HeroPicker"
	add_child(_hero)
	_place_hero()


func setup(m: int) -> void:
	mode = m
	if mode != MODE_ARMORY:
		page_size = FRAMED_SIZE
		custom_minimum_size = page_size
		size = page_size
	_sync_from_game()
	_place_hero()


func set_page_size(s: Vector2) -> void:
	if mode == MODE_ARMORY and s.x > 10.0 and s.y > 10.0 and s != page_size:
		page_size = s
		custom_minimum_size = s
		_place_hero()


## The KARAKTER strip: under the cards, above the footer, the cards' width.
func _place_hero() -> void:
	if _hero == null:
		return
	var pad := 22.0 if _framed() else 0.0
	var bottom := 54.0 if _framed() else 30.0
	_hero.position = Vector2(pad, page_size.y - bottom - HeroPicker.SIZE.y)
	_hero.size = Vector2(page_size.x - pad * 2.0, HeroPicker.SIZE.y)


func cancel_drag() -> void:
	pass


## Game.ui_panels contract (MODE_START).
func is_open() -> bool:
	return modal_open


func _sync_from_game() -> void:
	pick_a = Game.loadout_pick_a()
	pick_b = Game.loadout_pick_b()


func _framed() -> bool:
	return mode != MODE_ARMORY


## Pick the n-th (0-based) choice of slot B.
func key_pick(n: int) -> void:
	var lb: Array = Balance.LOADOUT_B
	if n >= 0 and n < lb.size():
		_pick("b", str(lb[n]))


func cycle_a(dir: int) -> void:
	var la: Array = Balance.LOADOUT_A
	if la.size() < 2:
		return
	var i := maxi(la.find(pick_a), 0)
	_pick("a", str(la[posmod(i + dir, la.size())]))


func _pick(slot: String, id: String) -> void:
	var changed := false
	if slot == "a" and id != pick_a:
		pick_a = id
		changed = true
	elif slot == "b" and id != pick_b:
		pick_b = id
		changed = true
	_pop[slot + ":" + id] = 1.0
	if Game.sfx:
		Game.sfx.play("select" if changed else "click", -10.0, 1.05 if slot == "a" else 1.15)
	if not changed:
		return
	if mode != MODE_RIDE:
		Game.set_loadout(pick_a, pick_b)
		if Game.hud and mode == MODE_ARMORY:
			Game.hud.show_message("Yükleme: %s + %s" % [_name(pick_a), _name(pick_b)], 2.0)
	picked.emit(pick_a, pick_b)


# =================================================================================================
# Input
# =================================================================================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse = (event as InputEventMouseMotion).position
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_mouse = (event as InputEventMouseButton).position
		for c in _cards():
			if (c["rect"] as Rect2).has_point(_mouse):
				_pick(str(c["slot"]), str(c["id"]))
				accept_event()
				return
		if mode == MODE_START and _ready_rect().has_point(_mouse):
			done.emit()
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_mouse = Vector2(-100000.0, -100000.0)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if mode == MODE_RIDE and Game.overlays_hidden():
		return
	var kc := (event as InputEventKey).physical_keycode
	var n := kc - KEY_1
	if n >= 0 and n < (Balance.LOADOUT_B as Array).size():
		key_pick(n)
		get_viewport().set_input_as_handled()
	elif (kc == KEY_Q or kc == KEY_E) and (Balance.LOADOUT_A as Array).size() > 1:
		cycle_a(1 if kc == KEY_E else -1)
		get_viewport().set_input_as_handled()
	elif mode == MODE_START and (kc == KEY_ENTER or kc == KEY_KP_ENTER or kc == KEY_SPACE or kc == KEY_ESCAPE):
		done.emit()
		get_viewport().set_input_as_handled()


# =================================================================================================
# Layout, per frame
# =================================================================================================

func _top() -> float:
	return 78.0 if _framed() else 30.0


## Every card: {"slot", "id", "key", "rect"}: two columns, slot A's (the primaries) on the left and
## slot B's (sidearms / utility) on the right, one row card per choice from the top.
func _cards() -> Array:
	var la: Array = Balance.LOADOUT_A
	var lb: Array = Balance.LOADOUT_B
	var pad := 22.0 if _framed() else 0.0
	var top := _top() + 26.0
	var bottom := (54.0 if _framed() else 30.0) + HERO_STRIP     # (the KARAKTER strip under the cards)
	var rows := maxi(maxi(la.size(), lb.size()), 1)
	var cw := (page_size.x - pad * 2.0 - GROUP_GAP) * 0.5
	var ch := minf((page_size.y - top - bottom - ROW_GAP * float(rows - 1)) / float(rows), 92.0)
	var out: Array = []
	for i in la.size():
		out.append({"slot": "a", "id": str(la[i]), "key": "",
				"rect": Rect2(Vector2(pad, top + (ch + ROW_GAP) * float(i)), Vector2(cw, ch))})
	var xb := pad + cw + GROUP_GAP
	for i in lb.size():
		out.append({"slot": "b", "id": str(lb[i]), "key": str(i + 1) if i < 9 else "",
				"rect": Rect2(Vector2(xb, top + (ch + ROW_GAP) * float(i)), Vector2(cw, ch))})
	return out


func _ready_rect() -> Rect2:
	var w := 150.0
	return Rect2(Vector2(page_size.x - 22.0 - w, page_size.y - 46.0), Vector2(w, 32.0))


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_t += delta
	if not _thumbs_asked:
		_thumbs_asked = true
		var entries: Array = []
		for id in (Balance.LOADOUT_A as Array) + (Balance.LOADOUT_B as Array):
			var r := Craft.recipe(str(id))
			if r.has("item_script"):
				entries.append({"id": str(r.get("thumb_id", "craft_" + str(id))), "item_script": r["item_script"]})
		if not entries.is_empty():
			BuildPreview.request_thumbs(get_tree(), entries)
	if mode != MODE_RIDE:
		_sync_from_game()                  # (the loadout may change elsewhere)
	for c in _cards():
		var key := str(c["slot"]) + ":" + str(c["id"])
		var hov := (c["rect"] as Rect2).has_point(_mouse)
		_lift[key] = move_toward(float(_lift.get(key, 0.0)), 1.0 if hov else 0.0, delta * 8.0)
		_pop[key] = maxf(float(_pop.get(key, 0.0)) - delta * 3.0, 0.0)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hovering() else Control.CURSOR_ARROW
	queue_redraw()


func _hovering() -> bool:
	for c in _cards():
		if (c["rect"] as Rect2).has_point(_mouse):
			return true
	return mode == MODE_START and _ready_rect().has_point(_mouse)


# =================================================================================================
# Drawing
# =================================================================================================

func _draw() -> void:
	if _framed():
		var r := Rect2(Vector2.ZERO, page_size)
		UI.draw_chamfer(self, r, 18.0, Color(UI.GLASS, 0.55))
		UI.draw_glass(self, r, 1.0, UI.SUIT_ORANGE, 0.55, 1.0, true, 18.0)
		draw_rect(Rect2(Vector2(28, 0), Vector2(160, 3)), UI.SUIT_ORANGE)
		var kick := "YENİDEN DOĞUŞ  ·  YÜKLEME" if mode == MODE_RIDE else "MAÇ BAŞLIYOR  ·  YÜKLEME"
		UI.draw_text(self, UI.font_caps(700, 3), Vector2(24, 30), kick, 13, UI.SUIT_ORANGE.lightened(0.15), 0)
		var title := "İnişte bu silahlarla doğacaksın" if mode == MODE_RIDE else "Silahlarını seç"
		UI.draw_text(self, _font_b, Vector2(24, 60), title, 24, UI.TEXT, 2)
	else:
		draw_rect(Rect2(Vector2(0, 6), Vector2(3, 14)), UI.SUIT_ORANGE)
		var cf := UI.font_caps(700, 2)
		UI.draw_text(self, cf, Vector2(10, 18), "YÜKLEME", 14, UI.SUIT_WHITE, 0)
		UI.draw_text(self, _font, Vector2(10 + UI.text_w(cf, "YÜKLEME", 14) + 12.0, 18),
				"her doğuşta bu iki silahla inersin  ·  seçim hemen geçerli", 14, UI.DIM, 0)
	var cards := _cards()
	# The group labels over slot A's and slot B's cards.
	var la_n := (Balance.LOADOUT_A as Array).size()
	if not cards.is_empty():
		var ra: Rect2 = cards[0]["rect"]
		_group_label(Vector2(ra.position.x, ra.position.y - 10.0), "A", "ANA SİLAH",
				"Q / E" if la_n > 1 else "", ra.size.x)
		if cards.size() > la_n:
			var rb: Rect2 = cards[la_n]["rect"]
			var nb := cards.size() - la_n
			_group_label(Vector2(rb.position.x, rb.position.y - 10.0), "B", "YAN SİLAH",
					("1 – %d" % mini(nb, 9)) if nb > 1 else "1", rb.size.x)
			var sx := rb.position.x - GROUP_GAP * 0.5
			var bottom_y: float = maxf((cards[cards.size() - 1]["rect"] as Rect2).end.y, (cards[la_n - 1]["rect"] as Rect2).end.y) \
					if la_n > 0 else rb.end.y
			draw_line(Vector2(sx, rb.position.y + 10.0), Vector2(sx, bottom_y - 10.0), Color(UI.SUIT_WHITE, 0.12), 1.0)
	for c in cards:
		var sel: bool = (str(c["id"]) == pick_a) if str(c["slot"]) == "a" else (str(c["id"]) == pick_b)
		_draw_card(c, sel)
	# The footer.
	var fy := page_size.y - (22.0 if _framed() else 6.0)
	var hint := ""
	var keys := "Q / E: ana silah  ·  1 – %d: yan silah  ·  ← / →: karakter" % mini((Balance.LOADOUT_B as Array).size(), 9)
	match mode:
		MODE_RIDE:
			hint = keys + "  ·  güç silahları: Tab › İkmal kapsülü"
		MODE_START:
			hint = keys + "  ·  güç silahları: Tab"
		_:
			hint = keys + "  ·  güç silahları sahada: Tab › İkmal kapsülü"
	UI.draw_text(self, _font, Vector2(24.0 if _framed() else 0.0, fy), hint, 14, Color(0.66, 0.74, 0.82, 0.95), 0)
	if mode == MODE_START:
		var br := _ready_rect()
		var hov := br.has_point(_mouse)
		UI.draw_chamfer(self, br, 7.0, Color(UI.SUIT_ORANGE, 0.95 if hov else 0.82), Color(UI.SUIT_WHITE, 0.5 if hov else 0.0))
		var f := UI.font_caps(700, 2)
		UI.draw_text_c(self, f, Vector2(br.get_center().x - 18.0, br.get_center().y + 5.0), "HAZIR", 14, UI.INK, 0)
		UI.draw_key(self, Vector2(br.end.x - 52.0, br.position.y + 6.0), "Enter", 0.85, false, 0.95, 11)


## A column's header: the slot letter plate, its label and (right-aligned over the column) its keys.
func _group_label(pos: Vector2, slot: String, label: String, keys := "", width := 0.0) -> void:
	var r := Rect2(pos + Vector2(0, -13), Vector2(18, 18))
	UI.draw_chamfer(self, r, 4.0, Color(UI.SUIT_WHITE, 0.9))
	var sw := _font_b.get_string_size(slot, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(_font_b, r.position + Vector2(9.0 - sw * 0.5, 14.0), slot, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UI.INK)
	UI.draw_text(self, UI.font_caps(700, 2), pos + Vector2(26, 1), label, 12, UI.DIM, 0)
	if keys != "" and width > 0.0:
		UI.draw_text_r(self, UI.font_caps(700, 1), pos.x + width - 4.0, pos.y + 1.0, "TUŞ  " + keys, 11, UI.FAINT, 0)


func _draw_card(c: Dictionary, sel: bool) -> void:
	var id := str(c["id"])
	var key := str(c["slot"]) + ":" + id
	var lift := _ease(float(_lift.get(key, 0.0)))
	var pop := float(_pop.get(key, 0.0))
	var r: Rect2 = c["rect"]
	r.position.y -= 4.0 * lift
	r = r.grow(pop * 3.0)
	var bc := Color(UI.SUIT_WHITE, 0.16).lerp(Color(UI.SCREEN_CYAN, 0.95), lift)
	if sel:
		bc = Color(UI.SUIT_ORANGE, 0.95)
	var sb := UI.chamfer_box(Color(UI.GLASS_HI, 0.92) if lift > 0.01 or sel else Color(UI.GLASS, 0.82), bc,
			2 if lift > 0.5 or sel else 1, 12.0, 0)
	sb.shadow_color = Color(UI.SUIT_ORANGE if sel else UI.SCREEN_CYAN, 0.22 if sel else 0.25 * lift)
	sb.shadow_size = 14 if sel else int(12.0 * lift)
	draw_style_box(sb, r)
	var y := r.position.y + 4.0
	while y < r.end.y - 4.0:
		draw_rect(Rect2(Vector2(r.position.x + 3.0, y), Vector2(r.size.x - 6.0, 1.0)), Color(0.3, 0.8, 1.0, 0.025))
		y += 3.0
	if sel:
		draw_rect(Rect2(Vector2(r.position.x + 20.0, r.position.y), Vector2(r.size.x * 0.4, 3.0)), Color(UI.SUIT_ORANGE, 0.95))
	# Row layout: [key] [thumbnail] name / role / stats [SEÇİLİ].
	var k := str(c["key"])
	var lx := r.position.x + 10.0
	if k != "":
		lx += UI.draw_key(self, Vector2(lx, r.position.y + r.size.y * 0.5 - 11.0), k, 1.0, sel, 1.0, 13) + 8.0
	var badge_w := 0.0
	if sel:
		var tf := UI.font_caps(700, 1)
		var tw := tf.get_string_size("SEÇİLİ", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 12.0
		var pr := Rect2(Vector2(r.end.x - 10.0 - tw, r.position.y + 9.0), Vector2(tw, 19.0))
		UI.draw_chamfer(self, pr, 4.0, Color(UI.SUIT_ORANGE, 0.92))
		draw_string(tf, pr.position + Vector2(6.0, 14.0), "SEÇİLİ", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UI.INK)
		badge_w = tw + 8.0
	# The thumbnail on a soft spotlight (the gun's own model, rendered).
	var th := r.size.y - 14.0
	var tb := Rect2(Vector2(lx, r.position.y + 7.0), Vector2(minf(th * 1.75, r.size.x * 0.34), th))
	UI.draw_chamfer(self, tb, 7.0, Color(0.01, 0.035, 0.045, 0.75), Color(UI.SUIT_WHITE, 0.06))
	draw_circle(tb.get_center(), tb.size.y * 0.42, Color(UI.SCREEN_CYAN, 0.07 + 0.05 * lift))
	_thumb(id, tb.grow(-2.0), 1.0 if sel or lift > 0.01 else 0.85)
	# The name, the one-line role, the stats on one line.
	var rc := Craft.recipe(id)
	var x0 := tb.end.x + 12.0
	var tw2 := r.end.x - 10.0 - x0
	var ty := r.position.y + minf(23.0, r.size.y * 0.32)
	UI.draw_text(self, _font_b, Vector2(x0, ty), UI.ellipsize(_font_b, _name(id), 17, tw2 - badge_w), 17, UI.TEXT, 0)
	ty += 18.0
	var role := str(ROLE.get(id, rc.get("desc", "")))
	UI.draw_text(self, _font, Vector2(x0, ty), UI.ellipsize(_font, role, 12, tw2), 12, UI.DIM, 0)
	var stats = rc.get("stats", [])
	if stats is Array and ty + 18.0 < r.end.y - 4.0:
		var parts := PackedStringArray()
		for st in stats:
			if parts.size() >= 3 or not (st is Array) or (st as Array).size() < 2:
				continue
			parts.append("%s %s" % [UI.upper_tr(str(st[0])), str(st[1])])
		ty += 18.0
		UI.draw_text(self, UI.font_caps(700, 1), Vector2(x0, ty), UI.ellipsize(UI.font_caps(700, 1), "  ·  ".join(parts), 10, tw2),
				10, UI.FAINT.lerp(UI.TEXT, 0.35), 0)


# --- Helpers ---------------------------------------------------------------------------------------

func _name(id: String) -> String:
	var r := Craft.recipe(id)
	return str(r.get("name", WeaponDrop.item_name(id)))


func _thumb(id: String, rect: Rect2, a: float) -> void:
	var r := Craft.recipe(id)
	var tex = BuildPreview.thumbs.get(str(r.get("thumb_id", "craft_" + id)))
	if not (tex is Texture2D) or tex is PlaceholderTexture2D:
		return
	# Only the model's pixels (the render's empty margin cropped), filling the well.
	var src := UI.tex_used_rect(tex)
	if src.size.x <= 0.0 or src.size.y <= 0.0:
		return
	var fit := rect.grow(-rect.size.y * 0.08)
	var s := minf(fit.size.x / src.size.x, fit.size.y / src.size.y)
	var sz := src.size * s
	draw_texture_rect_region(tex, Rect2(rect.get_center() - sz * 0.5, sz), src, Color(1, 1, 1, a))


static func _ease(v: float) -> float:
	var x := clampf(v, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)
