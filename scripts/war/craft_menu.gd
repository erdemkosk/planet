extends CanvasLayer
## The Silahlık's panel (F at an armory, scripts/war/armory.gd), in the design system's look
## (scripts/ui/ui_style.gd): a dimmed screen, a centred chamfered glass panel with the suit's orange
## strip, "SİLAHLIK · <tab>", the tabs and the material on the right. 2026-10-06 (the user: crafting
## guns slowed the game down): no guns are made here and every purchase is INSTANT (no craft times).
## Cards: a rendered thumbnail of the thing's own model (scripts/war/build_preview.gd; upgrades: a
## vector icon) in a dark well with a spotlight (it lifts and turns a little under the mouse), the name,
## the price, a tag, a line of text and three stats; the state: owned ("SAHİPSİN"), affordable
## ("SATIN AL" / "ÇAĞIR") or why not (Craft.blocked / SupplyPod.blocked: "Yetersiz malzeme: NN m³
## eksik", "Önce Matkap Mk II gerekli"). Click a card (G: grenades) to buy. Esc / F closes; it closes by
## itself when you walk away, die or the armory goes.
## Tabs (click, or Tab to cycle) are data (_tabs: {name, title, keys, node}):
##   KALICI GELİŞMELER  Craft.shop(): the next drill tier (drill_tiers.gd), the next İkmal İndirimi, the
##              next Bomba Kemeri (each line's top level, owned, once maxed) and the grenade stack;
##              rebuilt when a line moves on
##   İKMAL      the İkmal kapsülü price list (Balance.SUPPLY_GUNS, SupplyPod.cost): click calls one in
##              right here (scripts/war/supply_pod.gd; in the field: Tab)
##   YÜKLEME    scripts/war/loadout_panel.gd (MODE_ARMORY): slot A / slot B, applied at once
##   EKLENTİLER scripts/war/attachments_panel.gd (the Attachments API, scripts/items/attachments.gd),
##              added only when that page script loads. Another page drops in the same way: a Control
##              with set_page_size(Vector2) (it gets the grid's size, so every tab keeps one panel
##              size) and optionally cancel_drag(); append it in _ready with _add_tab().
## (The old closed-panel pill of running crafts stays for a timed craft, which nothing starts now.)
## Registered in Game.ui_panels while open (the mouse is free, the player stands still).
##   CraftMenu.open_for(armory) -> the menu (one per scene)

const UI := preload("res://scripts/ui/ui_style.gd")
const BuildPreview := preload("res://scripts/war/build_preview.gd")
const Craft := preload("res://scripts/war/craft.gd")
const LoadoutPanel := preload("res://scripts/war/loadout_panel.gd")
const SupplyPod := preload("res://scripts/war/supply_pod.gd")
const Balance := preload("res://scripts/war/balance.gd")
const TAB_NAMES := ["KALICI GELİŞMELER", "İKMAL", "YÜKLEME"]
const ATTACH_PAGE := "res://scripts/war/attachments_panel.gd"

static var _last_tab := 0                 # the tab shown last (kept between openings)

const CARD_W := 214.0
const CARD_H := 352.0
const THUMB_INSET := Vector2(16.0, 14.0)     # the model inside its well (cropped to its pixels)
const ACCENT := Color(0.4, 0.92, 1.0)
const COST_COL := Color(1.0, 0.66, 0.3)
const BAD := Color(1.0, 0.42, 0.36)
const GOOD := Color(0.45, 0.95, 0.62)
const AWAY := 7.5                         # m from the armory before the panel closes

var armory: Node3D
var _open := false
var _shown := 0.0
var _root: Control
var _dim: ColorRect
var _holder: Control
var _panel: PanelContainer
var _mat_label: Label
var _foot: Label
var _ring: Control
var _pill: Control
var _cards: Array = []                    # {id, card, thumb, cost, state, hover, key, lift, price}
var _font: Font
var _font_b: Font
var _font_n: Font
var _t := 0.0
var _tab := 0
var _tabs: Array = []                     # {name, title, keys, node}
var _grid: GridContainer                  # KALICI GELİŞMELER (Craft.shop())
var _shop_ids: Array = []                 # the ids its cards show (rebuilt when they change)
var _pod_grid: GridContainer              # İKMAL (one card per Balance.SUPPLY_GUNS)
var _pod_cards: Array = []
var _page: Control                        # loadout_panel.gd (the YÜKLEME tab)
var _tab_btns: Array = []
var _tab_row: HBoxContainer
var _kicker: Label
var _title: Label
var _keys: HBoxContainer
var _mat_i := -1


static func open_for(a: Node3D) -> Node:
	if a == null or not is_instance_valid(a):
		return null
	var m = null
	if Game.has_meta("craft_menu"):
		m = Game.get_meta("craft_menu")
	if m == null or not is_instance_valid(m):
		var tree := a.get_tree()
		if tree == null:
			return null
		m = load("res://scripts/war/craft_menu.gd").new()
		m.name = "CraftMenu"
		var scene: Node = tree.current_scene if tree.current_scene != null else tree.root
		scene.add_child(m)
		Game.set_meta("craft_menu", m)
	m.open(a)
	return m


func is_open() -> bool:
	return _open


func _ready() -> void:
	layer = 7
	_font = UI.font(500)
	_font_b = UI.font(700)
	_font_n = UI.font_num(700)
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UI.make_theme()
	_root.visible = false
	add_child(_root)
	_dim = ColorRect.new()
	_dim.color = Color(0.0, 0.015, 0.025, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_dim)
	_holder = Control.new()
	_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_holder)
	_panel = PanelContainer.new()
	var sb := UI.chamfer_box(Color(UI.GLASS, 0.9), Color(UI.SUIT_WHITE, 0.22), 1, 18.0, 24.0)
	sb.shadow_color = Color(0.0, 0.02, 0.03, 0.5)
	sb.shadow_size = 22
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.draw.connect(_draw_panel_deco)
	_holder.add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 18)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(head)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(tv)
	_kicker = _label(tv, 13, UI.SUIT_ORANGE.lightened(0.15), UI.font_caps(700, 3))
	_kicker.text = "SİLAHLIK  ·  KALICI GELİŞMELER"
	_title = _label(tv, 30, UI.TEXT, _font_b)
	_title.text = "Kalıcı gelişmeler"
	# Tabs (data: _tabs; Tab cycles them).
	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", 6)
	_tab_row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tab_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_tab_row)
	# The material.
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", -2)
	mv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(mv)
	var ml := _label(mv, 11, UI.DIM, UI.font_caps(700, 2))
	ml.text = "MALZEME"
	ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mat_label = _label(mv, 24, UI.SUIT_ORANGE.lightened(0.15), _font_n)
	_mat_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var rule := ColorRect.new()
	rule.color = Color(UI.SUIT_WHITE, 0.12)
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(rule)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(grid)
	_grid = grid
	_pod_grid = GridContainer.new()
	_pod_grid.columns = 4
	_pod_grid.add_theme_constant_override("h_separation", 14)
	_pod_grid.add_theme_constant_override("v_separation", 14)
	_pod_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pod_grid.visible = false
	v.add_child(_pod_grid)
	_page = LoadoutPanel.new()
	_page.visible = false
	v.add_child(_page)
	_add_tab("KALICI GELİŞMELER", "Kalıcı gelişmeler", [["Tıkla", "satın al (anında)"], ["G", "bomba"], ["Tab", "sekme"],
			["Esc / F", "kapat"]], _grid)
	_add_tab("İKMAL", "İkmal kapsülü çağır", [["Tıkla", "çağır"], ["Sahada", "Tab"], ["Tab", "sekme"], ["Esc / F", "kapat"]],
			_pod_grid)
	_add_tab("YÜKLEME", "Doğuş silahları", [["Tıkla / 1 2", "seç"], ["Tab", "sekme"], ["Esc / F", "kapat"]], _page)
	# EKLENTİLER: the attachments page, when its script loads (scripts/items/attachments.gd, another
	# session's API).
	if ResourceLoader.exists(ATTACH_PAGE):
		var ps = load(ATTACH_PAGE)
		if ps is Script and (ps as Script).can_instantiate():
			var ap: Control = ps.new()
			if ap != null:
				ap.visible = false
				v.add_child(ap)
				_add_tab("EKLENTİLER", "Eklenti satın al", [["Tıkla", "satın al (anında)"], ["Orta tık (oyunda)", "tak"],
						["Tab", "sekme"], ["Esc / F", "kapat"]], ap)
	var entries: Array = _build_shop()
	for g in Balance.SUPPLY_GUNS:
		var gr := Craft.recipe(str(g))
		var pr := {"id": "pod_" + str(g), "name": str(gr.get("name", SupplyPod.gun_name(str(g)))), "key": "",
				"cost": SupplyPod.cost(str(g)), "tag": "~%d SN" % int(roundf(Balance.SUPPLY_DELAY)),
				"thumb_id": str(gr.get("thumb_id", "craft_" + str(g))), "desc": str(gr.get("desc", "")),
				"stats": gr.get("stats", [])}
		_pod_cards.append(_make_card(_pod_grid, pr))
		if gr.has("item_script"):
			entries.append({"id": pr["thumb_id"], "item_script": gr["item_script"]})
	BuildPreview.request_thumbs(get_tree(), entries)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 12)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(foot)
	_ring = Control.new()
	_ring.custom_minimum_size = Vector2(34, 34)
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.draw.connect(_draw_ring)
	foot.add_child(_ring)
	_foot = _label(foot, 15, UI.TEXT, _font_b)
	_foot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_foot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_keys = HBoxContainer.new()
	_keys.add_theme_constant_override("separation", 6)
	_keys.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.add_child(_keys)
	_set_tab(_last_tab, false)
	# The pill shown while closed.
	_pill = Control.new()
	_pill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pill.draw.connect(_draw_pill)
	_pill.add_to_group("gameplay_overlay")       # hidden on the end screen / menus (overlay_guard.gd)
	add_child(_pill)


## A tab: its name, the panel title, the key hints of the footer and the page node.
func _add_tab(name_s: String, title: String, keys: Array, node: Control) -> void:
	var i := _tabs.size()
	_tabs.append({"name": name_s, "title": title, "keys": keys, "node": node})
	var b := Button.new()
	b.text = name_s
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(128, 38)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", UI.font_caps(700, 2))
	b.add_theme_font_size_override("font_size", 14)
	b.pressed.connect(_set_tab.bind(i))
	_tab_row.add_child(b)
	_tab_btns.append(b)


func _label(parent: Node, size: int, c: Color, f: Font) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	l.add_theme_constant_override("outline_size", 0)
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 0)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## The panel's orange strip along the top edge (the suit's band) and a faint corner tick.
func _draw_panel_deco() -> void:
	var s := _panel.size
	_panel.draw_rect(Rect2(Vector2(28.0, 0.0), Vector2(160.0, 3.0)), UI.SUIT_ORANGE)
	_panel.draw_rect(Rect2(Vector2(s.x - 60.0, s.y - 3.0), Vector2(40.0, 3.0)), Color(UI.SUIT_WHITE, 0.35))


func _card_style(hover: bool, ok: bool, owned: bool) -> StyleBoxFlat:
	var bc := GOOD if owned else (UI.SUIT_ORANGE if ok else BAD)
	var s := UI.chamfer_box(Color(UI.GLASS_HI, 0.92) if hover else Color(UI.GLASS, 0.78),
			Color(bc, 0.95) if hover else Color(bc, 0.3) if owned or not ok else Color(UI.SUIT_WHITE, 0.16), 2 if hover else 1, 12.0, 10.0)
	s.shadow_color = Color(bc, 0.22) if hover else Color(0.0, 0.02, 0.03, 0.35)
	s.shadow_size = 12 if hover else 5
	return s


func _make_card(parent: Node, r: Dictionary) -> Dictionary:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.add_theme_stylebox_override("panel", _card_style(false, true, false))
	parent.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var tb := Panel.new()
	tb.custom_minimum_size = Vector2(0, 132)
	tb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tb.clip_contents = true
	tb.add_theme_stylebox_override("panel", UI.chamfer_box(Color(0.01, 0.035, 0.045, 0.75), Color(UI.SUIT_WHITE, 0.06), 1, 7.0, 0))
	v.add_child(tb)
	var glow := TextureRect.new()
	var gt := GradientTexture2D.new()
	var g := Gradient.new()
	g.set_color(0, Color(0.45, 0.85, 1.0, 0.28))
	g.set_color(1, Color(0.45, 0.85, 1.0, 0.0))
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.62)
	gt.fill_to = Vector2(0.5, 0.0)
	glow.texture = gt
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tb.add_child(glow)
	var thumb := TextureRect.new()
	thumb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	thumb.offset_left = THUMB_INSET.x
	thumb.offset_right = -THUMB_INSET.x
	thumb.offset_top = THUMB_INSET.y
	thumb.offset_bottom = -THUMB_INSET.y
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tb.add_child(thumb)
	# Upgrades (drill tiers, İkmal İndirimi, Bomba Kemeri) have no model: a vector icon in the well.
	var icon := ""
	if r.has("drill_tier"):
		icon = "drill"
	elif r.has("icon"):
		icon = str(r["icon"])
	if icon != "":
		var ic := Control.new()
		ic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icol: Color = r.get("color", ACCENT)
		var tier := int(r.get("drill_tier", int(r.get("level", 0))))
		ic.draw.connect(_draw_icon.bind(ic, icon, icol, tier))
		tb.add_child(ic)
	var key := Label.new()
	key.text = str(r["key"])
	key.visible = key.text != ""              # (guns: their key comes from the carried order, Game.carried_guns())
	key.add_theme_font_override("font", _font_b)
	key.add_theme_font_size_override("font_size", 13)
	key.add_theme_color_override("font_color", UI.INK)
	key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	key.add_theme_stylebox_override("normal", UI.chamfer_box(Color(UI.SUIT_WHITE, 0.9), Color(0, 0, 0, 0), 0, 5.0, 0))
	key.position = Vector2(6, 6)
	key.size = Vector2(24, 22)
	key.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tb.add_child(key)
	var nm := _label(v, 18, UI.TEXT, _font_b)
	nm.text = str(r["name"])
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(row)
	var cost := _label(row, 20, COST_COL, _font_n)
	cost.text = "%d m³" % int(r["cost"])
	cost.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tm := _label(row, 11, UI.DIM, UI.font_caps(700, 1))
	# A tag (no craft times any more): the pod's delivery, "+5" for grenades, else "KALICI".
	var tag := str(r.get("tag", ""))
	if tag == "":
		tag = ("+%d" % Balance.GRENADE_STACK) if bool(r.get("grenade", false)) else "KALICI"
	tm.text = tag
	tm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tm.add_theme_stylebox_override("normal", UI.chamfer_box(Color(UI.SUIT_WHITE, 0.06), Color(UI.SUIT_WHITE, 0.2), 1, 4.0, 3.0))
	var desc := _label(v, 12, UI.DIM, _font)
	desc.text = str(r["desc"])
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(CARD_W - 20, 34)
	desc.max_lines_visible = 2                                    # (two lines, an ellipsis after)
	desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# The stats as rows: the caps label on the left, the value on the right (never overlapping;
	# a long value is ellipsized).
	var stats := VBoxContainer.new()
	stats.add_theme_constant_override("separation", 1)
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(stats)
	for st in r["stats"]:
		var row2 := HBoxContainer.new()
		row2.add_theme_constant_override("separation", 6)
		row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stats.add_child(row2)
		var a := _label(row2, 10, UI.FAINT, UI.font_caps(700, 1))
		a.text = UI.upper_tr(str(st[0]))
		a.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var b := _label(row2, 13, UI.TEXT, _font_n)
		b.text = str(st[1])
		b.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(spacer)
	var state := _label(v, 12, GOOD, UI.font_caps(700, 1))
	state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	state.custom_minimum_size = Vector2(CARD_W - 20, 0)
	var c := {"id": str(r["id"]), "card": card, "thumb": thumb, "cost": cost, "state": state, "hover": false,
			"key": str(r.get("key", "")), "price": float(r["cost"]), "thumb_id": str(r.get("thumb_id", "")),
			"style": "", "lift": 0.0}
	card.mouse_entered.connect(func() -> void: c["hover"] = true)
	card.mouse_exited.connect(func() -> void: c["hover"] = false)
	card.gui_input.connect(_on_card_input.bind(c))
	return c


func _on_card_input(event: InputEvent, c: Dictionary) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_try(str(c["id"]))


## Buys `id` at once (armory.start_craft: pays, grants), or calls an İkmal kapsülü ("pod_<gun>": it lands
## by you here; the panel closes so you see it come).
func _try(id: String) -> void:
	if armory == null or not is_instance_valid(armory):
		return
	var why := ""
	if id.begins_with("pod_"):
		why = SupplyPod.call_in(id.substr(4))
		if why == "":
			close()
			return
	else:
		why = armory.start_craft(id)
	if why != "":
		if Game.sfx:
			Game.sfx.play("error", -10.0)
		if Game.hud:
			Game.hud.alert(why, 1, "craft", 1.8)
	elif Game.sfx:
		Game.sfx.play("click", -8.0, 1.1)


## (Re)builds the KALICI GELİŞMELER cards from Craft.shop() (a line that moved on shows its next level).
## Returns the thumbnail entries for the caller's ONE request_thumbs call (two in one frame trip the
## renderer, build_preview.gd: the second enqueues before its node is in the tree).
func _build_shop() -> Array:
	for c in _cards:
		var n = c.get("card")
		if n is Node and is_instance_valid(n):
			(n as Node).queue_free()
	_cards = []
	_shop_ids = []
	var entries: Array = []
	for r in Craft.shop():
		_cards.append(_make_card(_grid, r))
		_shop_ids.append(str(r["id"]))
		if r.has("item_script"):
			entries.append({"id": str(r["thumb_id"]), "item_script": r["item_script"]})
		elif bool(r.get("grenade", false)):
			entries.append({"id": str(r["thumb_id"]), "grenade": true})
	return entries


## An upgrade card's icon in its well: the drill (tier bands), a supply pod, a grenade belt.
func _draw_icon(ic: Control, kind: String, col: Color, level: int) -> void:
	var c := ic.size * 0.5 + Vector2(0, 4)
	var s := minf(ic.size.x, ic.size.y) * 0.3
	ic.draw_circle(c, s * 1.5, Color(col, 0.08))
	match kind:
		"drill":
			ic.draw_rect(Rect2(c + Vector2(-s * 1.3, -s * 0.36), Vector2(s * 1.2, s * 0.72)), Color(UI.SUIT_WHITE, 0.92))
			ic.draw_rect(Rect2(c + Vector2(-s * 1.0, s * 0.36), Vector2(s * 0.4, s * 0.7)), Color(UI.SUIT_WHITE, 0.92))
			ic.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.1 * s, -s * 0.32), c + Vector2(s * 1.35, 0.0),
					c + Vector2(-0.1 * s, s * 0.32)]), col)
			for i in clampi(level, 0, 4):
				ic.draw_rect(Rect2(c + Vector2(-s * 1.2 + i * s * 0.28, -s * 0.36), Vector2(s * 0.14, s * 0.72)), col)
		"pod":
			ic.draw_colored_polygon(PackedVector2Array([c + Vector2(-s * 0.45, -s * 0.95), c + Vector2(s * 0.45, -s * 0.95),
					c + Vector2(s * 0.6, s * 0.7), c + Vector2(-s * 0.6, s * 0.7)]), Color(UI.SUIT_WHITE, 0.92))
			ic.draw_rect(Rect2(c + Vector2(-s * 0.55, -s * 0.15), Vector2(s * 1.1, s * 0.16)), col)
			ic.draw_colored_polygon(PackedVector2Array([c + Vector2(-s * 0.6, s * 0.7), c + Vector2(s * 0.6, s * 0.7),
					c + Vector2(s * 0.3, s * 1.0), c + Vector2(-s * 0.3, s * 1.0)]), Color(0.25, 0.18, 0.12))
			for dx in [-0.35, 0.35]:
				ic.draw_line(c + Vector2(s * dx, s * 1.05), c + Vector2(s * dx * 1.3, s * 1.6), Color(col, 0.8), maxf(2.0, s * 0.12), true)
		"pouch":
			ic.draw_rect(Rect2(c + Vector2(-s * 1.4, -s * 0.12), Vector2(s * 2.8, s * 0.3)), Color(UI.SUIT_WHITE, 0.6))
			for i in 3:
				var gc := c + Vector2((float(i) - 1.0) * s * 0.85, s * 0.05)
				ic.draw_circle(gc, s * 0.36, col if i < level + 1 else Color(UI.SUIT_WHITE, 0.85))
				ic.draw_rect(Rect2(gc + Vector2(-s * 0.12, -s * 0.56), Vector2(s * 0.24, s * 0.2)), Color(UI.SUIT_WHITE, 0.85))


## Tab i (see _tabs). The pages keep the grid's size.
func _set_tab(i: int, sound := true) -> void:
	_tab = clampi(i, 0, maxi(_tabs.size() - 1, 0))
	_last_tab = _tab
	for j in _tabs.size():
		var node = _tabs[j]["node"]
		if node is Control and is_instance_valid(node):
			(node as Control).visible = j == _tab
			if j != _tab and (node as Control).has_method("cancel_drag"):
				node.call("cancel_drag")
	if _kicker != null and _tab < _tabs.size():
		_kicker.text = "SİLAHLIK  ·  " + str(_tabs[_tab]["name"])
		_title.text = str(_tabs[_tab]["title"])
	if _keys != null and _tab < _tabs.size():
		for ch in _keys.get_children():
			ch.queue_free()
		for kv in _tabs[_tab]["keys"]:
			UI.keycap(_keys, str(kv[0]), 11)
			var l := UI.label(_keys, str(kv[1]), 12, UI.DIM, 500)
			l.add_theme_constant_override("shadow_offset_x", 0)
			l.add_theme_constant_override("shadow_offset_y", 0)
			var sp := Control.new()
			sp.custom_minimum_size = Vector2(6, 0)
			sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_keys.add_child(sp)
	for b in _tab_btns.size():
		_style_tab(_tab_btns[b], b == _tab)
	if sound and Game.sfx:
		Game.sfx.play("click", -10.0, 1.1 + 0.15 * _tab)


func _style_tab(b: Button, on: bool) -> void:
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var hov: bool = st == "hover" or st == "hover_pressed"
		var bg := Color(UI.SUIT_ORANGE, 0.92) if on else (Color(UI.GLASS_HI, 0.95) if hov else Color(UI.GLASS, 0.7))
		var bc := Color(UI.SUIT_ORANGE, 1.0) if on else Color(UI.SCREEN_CYAN if hov else UI.SUIT_WHITE, 0.7 if hov else 0.18)
		var s := UI.chamfer_box(bg, bc, 1, 8.0, 6.0)
		if st == "focus":
			s.draw_center = false
			s.border_color = Color(0, 0, 0, 0)
		b.add_theme_stylebox_override(st, s)
	var fc := UI.INK if on else UI.TEXT
	for cn in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(cn, fc)


# =================================================================================================
# Open / close
# =================================================================================================

func open(a: Node3D) -> void:
	armory = a
	if _open:
		return
	_open = true
	if not Game.ui_panels.has(self):
		Game.ui_panels.append(self)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if Game.sfx:
		Game.sfx.play("open", -8.0)


func close() -> void:
	if not _open:
		return
	_open = false
	Game.ui_panels.erase(self)
	if not Game.ui_panel_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if Game.sfx:
		Game.sfx.play("close", -10.0)


func _exit_tree() -> void:
	Game.ui_panels.erase(self)


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("interact"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var kc := (event as InputEventKey).physical_keycode
		if kc == KEY_TAB:
			_set_tab((_tab + 1) % maxi(_tabs.size(), 1))
			get_viewport().set_input_as_handled()
			return
		# (G buys a grenade stack on the KALICI GELİŞMELER tab.)
		if kc == KEY_G and _tab == 0:
			for c in _cards:
				if str(c["key"]) == "G":
					_try(str(c["id"]))
					break
			get_viewport().set_input_as_handled()


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	if _open:
		var pl = Game.player
		var gone: bool = armory == null or not is_instance_valid(armory) or bool(armory.get("is_destroyed"))
		var away := false
		if not gone and pl != null and is_instance_valid(pl):
			away = (pl as Node3D).global_position.distance_to(armory.global_position) > AWAY \
					or pl.vehicle != null or pl.is_ragdolled() or pl.is_dead()
		if gone or away:
			close()
	_shown = move_toward(_shown, 1.0 if _open else 0.0, delta * (8.0 if _open else 10.0))
	_root.visible = _shown > 0.001
	_root.modulate.a = _shown
	if _root.visible:
		_layout()
		_update_cards(delta)
		_update_foot()
		_ring.queue_redraw()
	_pill.queue_redraw()


func _layout() -> void:
	var vs := _root.get_viewport_rect().size
	if _grid != null and _grid.visible:
		var gs := _grid.get_combined_minimum_size()
		for tb in _tabs:
			var node = tb["node"]
			if node != _grid and node is Control and is_instance_valid(node) and (node as Control).has_method("set_page_size"):
				node.call("set_page_size", gs)                    # (the tabs keep one size)
	var need := _panel.get_combined_minimum_size()
	var k := clampf(vs.y / 1080.0, 0.6, 2.2)
	k = minf(k, minf((vs.x - 40.0) / maxf(need.x, 1.0), (vs.y - 30.0) / maxf(need.y, 1.0)))   # (fits the window)
	_panel.size = need
	_holder.size = need
	_holder.pivot_offset = need * 0.5
	_holder.scale = Vector2.ONE * k * lerpf(0.96, 1.0, UI.smooth(_shown))
	_holder.position = vs * 0.5 - need * 0.5 + Vector2(0.0, (1.0 - UI.smooth(_shown)) * 18.0)


func _update_cards(delta: float) -> void:
	var mi := int(floorf(Game.material + 0.0001))
	if mi != _mat_i:
		_mat_i = mi
		_mat_label.text = "%d m³" % mi
	# KALICI GELİŞMELER: a line that moved on (bought) shows its next level.
	var ids: Array = []
	for r in Craft.shop():
		ids.append(str(r["id"]))
	if ids != _shop_ids:
		var te := _build_shop()
		if not te.is_empty():
			BuildPreview.request_thumbs(get_tree(), te)
	for c in _cards:
		_update_card(c, delta, false)
	for c in _pod_cards:
		_update_card(c, delta, true)


## One card's state (owned / buyable / why not), price colour, style and the thumbnail's hover lift.
func _update_card(c: Dictionary, delta: float, pod: bool) -> void:
	var card = c.get("card")
	if not (card is Control) or not is_instance_valid(card) or (card as Node).is_queued_for_deletion():
		return
	var id := str(c["id"])
	var owned := false
	var why := ""
	if pod:
		var g := id.substr(4)
		why = SupplyPod.blocked(g)
		var p := SupplyPod.cost(g)
		if p != float(c["price"]):
			c["price"] = p
			(c["cost"] as Label).text = "%d m³" % int(p)
	else:
		owned = Craft.owned(id)
		why = Craft.blocked(id)
	var ok := why == ""
	var txt := ""
	var col := GOOD
	if owned:
		txt = "SAHİPSİN  ·  kalıcı"
	elif not ok:
		txt = why
		col = BAD if Game.material + 0.001 < float(c["price"]) else UI.WARN
	elif pod:
		txt = "ÇAĞIR  ·  ~%d sn'de yanına iner" % int(roundf(Balance.SUPPLY_DELAY))
		col = UI.SCREEN_CYAN
	else:
		txt = "SATIN AL  ·  anında"
		if id == "grenade":
			txt = "SATIN AL   (elde %d / %d)" % [Game.grenades, Game.grenade_max()]
		col = UI.SCREEN_CYAN
	var st := c["state"] as Label
	if st.text != txt:
		st.text = txt
	st.add_theme_color_override("font_color", col)
	(c["cost"] as Label).add_theme_color_override("font_color", COST_COL if Game.material + 0.001 >= float(c["price"]) or owned else BAD)
	var hover := bool(c["hover"])
	var key := "%s|%s|%s" % [hover, ok, owned]
	if key != str(c["style"]):
		c["style"] = key
		(c["card"] as PanelContainer).add_theme_stylebox_override("panel", _card_style(hover, ok, owned))
		(c["card"] as Control).modulate = Color(1, 1, 1, 1) if (ok or owned) else Color(0.72, 0.72, 0.75, 0.92)
	# Hover: the model lifts a little and turns gently.
	c["lift"] = move_toward(float(c["lift"]), 1.0 if hover else 0.0, delta * 6.0)
	var lk := UI.smooth(float(c["lift"]))
	var tr := c["thumb"] as TextureRect
	tr.pivot_offset = tr.size * 0.5
	tr.scale = Vector2.ONE * (1.0 + 0.07 * lk)
	tr.rotation = 0.035 * sin(_t * 1.6) * lk
	# (offsets, not position: the inset must hold before the well has its size)
	tr.offset_left = THUMB_INSET.x
	tr.offset_right = -THUMB_INSET.x
	tr.offset_top = THUMB_INSET.y - 3.0 * lk
	tr.offset_bottom = -THUMB_INSET.y - 3.0 * lk
	if tr.texture == null and BuildPreview.thumbs.has(str(c["thumb_id"])):
		# Only the model's pixels (the render's empty margin cropped): the gun fills the well.
		var src = BuildPreview.thumbs[str(c["thumb_id"])]
		if src is Texture2D and not (src is PlaceholderTexture2D):
			var at := AtlasTexture.new()
			at.atlas = src
			at.region = UI.tex_used_rect(src)
			tr.texture = at
		else:
			tr.texture = src
		tr.modulate.a = 0.0
		create_tween().tween_property(tr, "modulate:a", 1.0, 0.35)


func _update_foot() -> void:
	if armory == null or not is_instance_valid(armory):
		_foot.text = ""
		return
	var t := ""
	if not bool(armory.call("is_ready")):
		t = "Silahlık kuruluyor…"
	else:
		var nm := str(_tabs[_tab]["name"]) if _tab < _tabs.size() else ""
		match nm:
			"İKMAL":
				var cl := SupplyPod.cooldown_left()
				t = ("İkmal hazırlanıyor: %d sn" % ceili(cl)) if cl > 0.05 else \
						"Kapsül ~%d sn'de yanına iner  ·  düşman görür, uçaksavar vurabilir  ·  silah ölünce gider" \
						% int(roundf(Balance.SUPPLY_DELAY))
			"YÜKLEME":
				t = "Yükleme: %s + %s  ·  her doğuşta bunlarla inersin" % [str(Craft.recipe(Game.loadout_pick_a()).get("name", "")),
						str(Craft.recipe(Game.loadout_pick_b()).get("name", ""))]
			"EKLENTİLER":
				t = "Eklentiler anında senin  ·  oyunda orta tık: tak"
			_:
				t = "Alımlar anında  ·  kalıcı gelişmeler maç sonuna kadar sürer"
	if _foot.text != t:
		_foot.text = t


## The footer ring: the İkmal cooldown on that tab, else an idle sweep.
func _draw_ring() -> void:
	var c := _ring.size * 0.5
	var r := 13.0
	var cl := SupplyPod.cooldown_left()
	if _tab < _tabs.size() and str(_tabs[_tab]["name"]) == "İKMAL" and cl > 0.05:
		UI.draw_ring(_ring, c, r, 1.0 - cl / maxf(SupplyPod.cooldown_total(), 0.01), UI.WARN, 3.0)
	else:
		UI.draw_ring(_ring, c, r, 0.0, UI.SCREEN_CYAN, 3.0)
		_ring.draw_arc(c, r, -PI * 0.5 + _t * 2.0, -PI * 0.5 + _t * 2.0 + 0.6, 12, Color(UI.SCREEN_CYAN, 0.45), 2.0, true)


## Closed: a pill per running craft of ours, right-aligned under the HUD's material plate.
func _draw_pill() -> void:
	if _open:
		return
	var vs := _pill.size
	var k := UI.scale_k(vs)
	var y := 104.0 * k
	if Game.hud != null and is_instance_valid(Game.hud) and Game.hud.has_method("right_column_y"):
		y = float(Game.hud.call("right_column_y", false))
	y = maxf(y, load("res://scripts/ui/minimap.gd").call("bottom_y", vs))   # (under the radar)
	var right := vs.x - 24.0 * k
	var f := UI.font_caps(700, 1)
	for a in get_tree().get_nodes_in_group("war_armory"):
		if not bool(a.get("crafting")):
			continue
		var j: Dictionary = a.get("job")
		if not bool(j.get("local", false)):
			continue
		var kk := float(a.get("craft_k"))
		var nm := UI.upper_tr(str(j.get("name", "")))
		var fsz := UI.fs(12, k)
		var pct := "%d%%" % int(kk * 100.0)
		var w := UI.text_w(f, "ÜRETİLİYOR", UI.fs(10, k)) + UI.text_w(_font_b, nm, fsz) + UI.text_w(_font_n, pct, fsz) + 70.0 * k
		var h := 28.0 * k
		var rect := Rect2(Vector2(right - w, y), Vector2(w, h))
		UI.draw_glass(_pill, rect, k, UI.SUIT_ORANGE, 0.0, 1.0, false, 7.0)
		var cc := rect.position + Vector2(16.0 * k, h * 0.5)
		UI.draw_ring(_pill, cc, 7.0 * k, kk, UI.SUIT_ORANGE, maxf(2.0 * k, 1.5))
		var x := rect.position.x + 32.0 * k
		var by := rect.get_center().y + fsz * 0.36
		UI.draw_text(_pill, f, Vector2(x, by - 1.0), "ÜRETİLİYOR", UI.fs(10, k), UI.DIM, 2)
		x += UI.text_w(f, "ÜRETİLİYOR", UI.fs(10, k)) + 8.0 * k
		UI.draw_text(_pill, _font_b, Vector2(x, by), nm, fsz, UI.TEXT, 2)
		UI.draw_text_r(_pill, _font_n, rect.end.x - 12.0 * k, by, pct, fsz, UI.SUIT_ORANGE.lightened(0.2), 2)
		y += h + 6.0 * k
