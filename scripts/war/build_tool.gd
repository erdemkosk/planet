extends "res://scripts/items/item.gd"
## İnşa Aracı (key 2): builds structures from material.
## Entries: "Top" (scripts/war/cannon.gd), "Uçaksavar" (scripts/war/flak.gd), "Delici Top" (bunker
## buster, scripts/war/buster.gd; its entry carries "script" so a multiplayer client's build request
## names it), "Silahlık" (armory, scripts/war/armory.gd: permanent upgrades and attachments, F), "Sondaj
## Kulesi" (scripts/war/torpedo_rig.gd: lowers the drilling torpedo into the ENEMY planet, which
## then burrows to its core), "Otomatik Kazıcı" (scripts/war/auto_miner.gd: digs its own shaft and
## pays its builder; anywhere) and, once the shuttle exists, "Mekik" (res://scripts/craft/skiff.gd, loaded at runtime
## only: const BUILD_COST, DISPLAY_NAME, HP_MAX, static footprint() -> half extents, place(body, xf)
## after add_child).
## Selection UI (scripts/war/build_menu.gd): a bar of cards at the bottom while the tool is held:
## a thumbnail of the real model (rendered once, scripts/war/build_preview.gd), name, cost, hull
## points, role; unaffordable cards dimmed with the shortfall.
## Placement: a HOLOGRAM of the real model on a footprint projected onto the ground, with a grid,
## contours, dimensions and a rotation gizmo, plus a scan beam from the tool (all drawn by
## scripts/war/build_holo.gd; the print on a build: scripts/war/build_fx.gd assemble). Cyan-white
## when it can be built (on a planet it may stand on, flat enough, clear of other structures and of
## you, enough material), amber when it is fixable here, red when blocked; the reason under the
## crosshair. Where each entry may stand: Balance.BUILD_SITE / build_site_reason() (shared with
## the multiplayer host's check): Silahlık, Top, Delici Top only on our planet ("Sadece kendi
## gezegenine kurulur"); Uçaksavar and both skiffs anywhere (a foothold, a way home); the Sondaj
## Kulesi only on the enemy planet ("Sadece düşman gezegenine kurulur"). Built there it is still OURS
## (team "home"): the rival bots go for it (scripts/war/rival_team.gd "Enemy footholds").
## Guns (Top, Delici Top) also show the arc of a default shot (45°, middle charge) toward the
## other planet.
## Controls: mouse wheel cycles the entries; R / middle mouse turns the ghost 45° (smoothly); right
## mouse held + mouse sideways turns it freely; LMB builds: the material is spent (the HUD counter
## ticks down), the hologram collapses into the ground and the structure is printed there. A refused
## click shakes the ghost and flashes what blocks it (refuse_k pulses 1 -> 0 for the UI).
## (R used to cycle the entries too: the wheel does that now.)
## BASE BUILDING (2026-10-05, scripts/war/base_kit.gd): the base pieces Otomatik Taret, Takviyeli
## Duvar, Zırhlı Kapı, Sığınak Modülü, Işık Direği, Radar Kulesi, Çekirdek Kalkanı (scripts/war/
## base_piece.gd subclasses; Balance "BASE BUILDING").
## MENU (2026-10-06, the user: "çok seçmek gerekiyor"): 3 categories (`categories`: Savunma, Üs,
## Saldırı; `category` = the current one) and 10 CARDS, some with VARIANTS: Top (Standart / Delici),
## Uçaksavar, Taret · Sığınak (Modül / Duvar / Kapı / Işık), Çekirdek Kalkanı, Radar, Silahlık,
## Otomatik Kazıcı · Mekik (Silahsız / Silahlı), Sondaj Kulesi. `entries` = ALL cards (the UI filters
## by "cat"); a card IS its active variant's entry plus "card", "card_name", "cat", "variants",
## "variant" (see `entries`), so the ghost, the cost, the checks and the build (kind ids, script paths:
## BaseKit, BUILD_SITE, the multiplayer request) are the variant's. `index` = the selected card, always
## in the current category; `variant_index`, variant_name(), variant_names(). Q / E: category (signal
## category_changed), wheel: card, T (Shift+T back) / Shift + wheel: variant (signal variant_changed).
## The last category, the last card per category and the variant per card are remembered (static,
## for the whole run): re-equipping the tool comes back to the last pick, and a build keeps the same
## piece selected (chain modules / walls). `rot_deg` = the ghost's yaw for a rotation read-out.
## EASY BUILDING (2026-10-06; the user: "herkes anlayabilsin, kullanım kolaylığı olmalı"):
##   guide       the first time the tool is held in a run, scripts/war/build_guide.gd lists the six
##               steps (GUIDE_STEPS) and ticks them off as they are done (guide_steps, guide_open);
##               H opens / closes it (not in the Eğitim Alanı: H is its panel there)
##   cards       each variant entry has "what": a plain "NE İŞE YARAR" line (WHAT)
##   recommend   recommend_card / recommend_reason ("ÖNERİLEN" badge, the reason line), card_category()
##   facing      AUTO_FACE kinds (cannon, buster, flak, turret) face the other planet / the nearest
##               threat by default; R / RMB turn from there
##   reasons     plain_reason(): what is wrong and how to fix it
##   undo        Z within Balance.UNDO_TIME s: the last build back, full price (undo_left, undo_name)
##   sell        X held SELL_HOLD s on an own structure: taken down (BaseKit.deconstruct), SELL_REFUND
##               of its price back (sell_target, sell_text, sell_ok, sell_k)
##   ping        middle click / B: "BURAYA KUR" (scripts/war/build_intent.gd)
##   co-op       the build intent goes out through BuildIntent.set_local (multiplayer only); built
##               structures carry the metas build_cost / built_ms / builder
## UNDERGROUND: soil straight over the aimed spot = a covered cavity (BaseKit.cover_above); aimed at a
## cavity wall / ceiling the spot drops to the floor under it. Only Balance.BUILD_UNDERGROUND entries may
## stand there ("Yeraltına kurulamaz — açık gökyüzü gerekir"); the 9 footprint samples then measure the
## cavity floor (BaseKit.cavity_fit: "Yer dar — biraz daha kaz" when the box reaches into a wall) and
## the ceiling must clear the structure ("Tavan çok alçak — biraz daha kaz"). Modular pieces (module,
## wall, door) SNAP to the side's modules / walls near the aim (BaseKit.snap: doorway to doorway, wall
## end to end or at a corner, a wall plugging / flanking a doorway, a door into a doorway); a snapped
## ghost ignores the rotation keys. Overlaps: BaseKit.overlap_reason (exact boxes between modular
## pieces, a turret / light may stand inside a module). Per-piece rules: BaseKit.rule_reason (the core
## shield near our own core, one per side). The visuals read the data below (snap_pairs, headroom) and
## get it through BuildFx.snap_guides / headroom_box / mark_blockers every frame.

const Balance := preload("res://scripts/war/balance.gd")
const BaseKit := preload("res://scripts/war/base_kit.gd")
const Cannon := preload("res://scripts/war/cannon.gd")
const Flak := preload("res://scripts/war/flak.gd")
const Buster := preload("res://scripts/war/buster.gd")
const Armory := preload("res://scripts/war/armory.gd")
const TorpedoRig := preload("res://scripts/war/torpedo_rig.gd")
const AutoMiner := preload("res://scripts/war/auto_miner.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const BuildHolo := preload("res://scripts/war/build_holo.gd")
const BuildPreview := preload("res://scripts/war/build_preview.gd")
const BuildMenu := preload("res://scripts/war/build_menu.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const SKIFF_PATH := "res://scripts/craft/skiff.gd"
const ARMED_SKIFF_PATH := "res://scripts/craft/armed_skiff.gd"
const OK_COL := BuildHolo.VALID_COL       # (the hologram's colours: the 2D and 3D sides agree)
const BAD_COL := BuildHolo.BLOCK_COL
const WARN_COL := BuildHolo.FIX_COL
const MENU_TUCK := Vector3(0.17, -0.15, 0.08)   # hold_offset while the card bar is shown (camera space)
const ROT_STEP := PI / 4.0
const ROT_MOUSE := 0.006
const ARC_PERIOD := 0.3
const Foundation := preload("res://scripts/war/foundation.gd")
## Placement (_validate): how much the ground may vary under the footprint box (m, lowest to highest
## sample; scripts/war/foundation.gd skirts / piles fill the low side), and where the base sits in
## that range (0 = on the lowest sample: the rig, the miner and the skiffs measure their own ground
## from there; the pads are raised so their uphill side is not buried; the armory's bay floor stays
## clear of the ground).
const STEP_TOL := {"armory": 1.4, "cannon": 2.0, "buster": 2.0, "flak": 1.8, "torpedo_rig": 2.2,
		"auto_miner": 1.6, "skiff": 1.8, "armed_skiff": 1.8}
const BASE_K := {"armory": 0.65, "cannon": 0.4, "buster": 0.4, "flak": 0.4}
const BuildGuide := preload("res://scripts/war/build_guide.gd")
const BuildIntent := preload("res://scripts/war/build_intent.gd")
## EASY BUILDING (2026-10-06; the user: "herkes anlayabilsin, kullanım kolaylığı olmalı"):
## "NE İŞE YARAR": one plain line per build kind (each variant entry's "what"; the card shows it).
const WHAT := {"cannon": "Rakip gezegeni döver, çekirdeğine çukur açar.",
		"buster": "Toprağa gömülüp derinde patlar: sığınak deler.",
		"flak": "Gelen mekik, kapsül ve top mermisini vurur.",
		"sentry_turret": "Yakına gelen düşmanı kendiliğinden vurur.",
		"bunker_module": "Sağlam beton oda: patlamalardan korur.",
		"armor_wall": "Ucuz siper: mermiyi ve patlamayı durdurur.",
		"blast_door": "Bizimkilere açılır, düşmana kapalı kalır.",
		"light_post": "Tüneli ve sığınağı aydınlatır.",
		"core_shield": "Çekirdeğimize gelen hasarı %60 azaltır.",
		"radar_tower": "Yakındaki düşmanı, toprak altında bile gösterir.",
		"armory": "Kalıcı gelişme, eklenti ve el bombası satar (yanına git, F).",
		"auto_miner": "Kendi kendine kazar, sana malzeme getirir.",
		"skiff": "İki kişilik araç: karşı gezegene uçarsın.",
		"armed_skiff": "Silahlı araç: top ve roketle saldırır.",
		"torpedo_rig": "Düşman gezegenine kur: torpido çekirdeğe kazar."}
## Kinds that face the enemy planet by default (the turret: the nearest threat); R / RMB turn on top.
const AUTO_FACE := ["cannon", "buster", "flak", "sentry_turret"]
## The first-time guide's steps (scripts/war/build_guide.gd ROWS): Q / E, wheel, T, R, LMB, RMB + mouse.
const GUIDE_STEPS := ["cat", "pick", "variant", "rotate", "build", "free"]
const PING_GAP := 0.4                     # s between two pings

## Card categories (the UI filters `entries` by "cat"). Q / E change `category`.
const CATEGORIES := ["Savunma", "Üs", "Saldırı"]
## The cards, in category order: [card id, card name, category, variant ids (build kinds, the
## BaseKit / BUILD_SITE / net ids), variant labels (the pips; "" = the card's name)]. T or Shift +
## wheel cycles the variant of the selected card.
const CARDS := [
	["top", "Top", "Savunma", ["cannon", "buster"], ["Standart", "Delici"]],
	["flak", "Uçaksavar", "Savunma", ["flak"], [""]],
	["turret", "Taret", "Savunma", ["sentry_turret"], [""]],
	["shelter", "Sığınak", "Üs", ["bunker_module", "armor_wall", "blast_door", "light_post"], ["Modül", "Duvar", "Kapı", "Işık"]],
	["core_shield", "Çekirdek Kalkanı", "Üs", ["core_shield"], [""]],
	["radar", "Radar", "Üs", ["radar_tower"], [""]],
	["armory", "Silahlık", "Üs", ["armory"], [""]],
	["miner", "Otomatik Kazıcı", "Üs", ["auto_miner"], [""]],
	["skiff", "Mekik", "Saldırı", ["skiff", "armed_skiff"], ["Silahsız", "Silahlı"]],
	["rig", "Sondaj Kulesi", "Saldırı", ["torpedo_rig"], [""]]]

signal category_changed(index: int)
signal variant_changed(index: int)

## The CARDS of every category (the UI filters by "cat"). A card is its ACTIVE variant's entry
## (id, name, cost, half, radius, hp, desc, under, modular, [script]: what the ghost, the cost, the
## placement checks and the build use) plus "card" (card id), "card_name", "cat", "short" (the active
## variant's label), "variants" (Array of variant entries, the same shape, each with its "short"
## label) and "variant" (int, the active one).
var entries: Array = []
var index := 0                    # into entries, always inside the current category
var categories: Array = CATEGORIES.duplicate()
var category := 0
## The active variant of the selected card.
var variant_index: int:
	get:
		return int(current_entry().get("variant", 0))
## Remembered picks, for the whole run (a respawned player's new tool too): the last category, the
## last card per category, the last variant per card.
static var _mem_category := -1
static var _mem_card := {}        # category index -> card id
static var _mem_variant := {}     # card id -> variant index
var rot_deg := 0.0                # the ghost's yaw (degrees, 0..360) for a read-out
var underground := false          # the last checked spot is covered (a cavity)
var snapped := false              # the ghost is snapped to another piece
## Visual data of the last check (for the hologram; also sent to BuildFx every frame):
var snap_pairs: Array = []        # [[ghost joint, target joint], ...] world points
var headroom := {}                # {"xf", "aabb" (in xf's frame), "ok"} underground, else {}
var blockers: Array = []          # structures in the way
var _snap_xf := Transform3D()
var _fx_has := {}
## Easy building: the guide (build_guide.gd reads guide_steps / guide_open), the recommendation (the
## card UI: an "ÖNERİLEN" badge on recommend_card, recommend_reason as its line), sell (an own
## structure under the crosshair: sell_target, sell_text, sell_k = X held 0..1), undo (undo_left s
## left for Z, undo_name).
static var _guide_mem := {}               # step -> true once done (for the whole run)
static var _guide_seen := false           # the guide opened by itself once this run
static var _guide_open_mem := false
var guide_steps: Dictionary = _guide_mem
var guide_open := false
var recommend_card := ""
var recommend_reason := ""
var sell_target: Node3D = null
var sell_text := ""
var sell_ok := false
var sell_k := 0.0
var undo_left := 0.0
var undo_name := ""
var _last_build: Node3D = null            # host / single player: the last structure built here
var _last_build_pos := Vector3.INF        # (a multiplayer client: where its request went)
var _last_build_kind := ""
var _reco_t := 0.0
var _income: Array = []                   # m³ gained per second, the last 60 s (the low-income check)
var _mat_prev := -1.0
var _inc_t := 0.0
var _free_px := 0.0
var _guide: CanvasLayer
var _guide_done_t := -1.0
var _ping_t := 0.0
var _sell_lost := 0.0
var _intent_on := false
var aim_valid := false
var can_build := false
var reason := ""

## In-world visuals (scripts/war/build_holo.gd): the ghost, the projected footprint / grid / gizmo,
## the scan beam, the gun arc, blockers, snap guides, headroom. `emitter` = its view-model emitter.
var holo: Node3D
var emitter := {}
var refuse_k := 0.0               # 1 on a refused click, decays (~0.4 s): for pulsing the reason text
var _ghost_on := false            # the ghost is wanted this frame (holo draws it, cached per kind)
var _ghost: Node3D                # the current hologram root (holo.ghost_root)
var _ghost_kind := ""
var _arc_t := 0.0                 # set 0 to refresh the gun arc now (build_holo.gd counts it down)
var _xf := Transform3D()
var _base_b := Basis()
var _base_o := Vector3.ZERO
var _up := Vector3.UP
var _rot := 0.0                   # shown rotation of the ghost about its up (rad)
var _rot_t := 0.0                 # target rotation
var _check_t := 0.0
var _use_t := 0.0
var _screen: ShaderMaterial
var _t := 0.0
var _menu: CanvasLayer


func _init() -> void:
	item_id = "build"
	item_name = "İnşa Aracı"
	item_desc = "Savunma (top / delici top, uçaksavar, taret), Üs (sığınak: modül / duvar / kapı / ışık, çekirdek kalkanı, radar, silahlık, otomatik kazıcı), Saldırı (mekik / silahlı mekik, sondaj kulesi). Kazdığın tünellere de kurulur. Q / E: kategori · Teker: seç · T: çeşit · R / sağ tık + fare: döndür · Sol tık: kur."
	icon = "build"
	slot_key = 0                          # (no number key: X selects the build tool, player.gd _tool_key_input)


func _ready() -> void:
	_restore_pick()
	_refresh_entries()
	_menu = BuildMenu.new()
	_menu.tool = self
	add_child(_menu)
	holo = BuildHolo.new()
	holo.name = "BuildHolo"
	holo.tool = self
	add_child(holo)
	guide_steps = _guide_mem
	guide_open = _guide_open_mem
	_guide = BuildGuide.new()
	_guide.tool = self
	add_child(_guide)
	# Thumbnails of every variant in the background a moment after the start (cached for the run).
	get_tree().create_timer(1.5).timeout.connect(func() -> void: BuildPreview.request_thumbs(get_tree(), variant_entries()))


## The cards (CARDS, the variants that exist), the remembered variant on each, `index` on the card
## selected before (else the remembered one of the category).
func _refresh_entries() -> void:
	var keep := str(current_entry().get("card", "")) if not entries.is_empty() else ""
	var defs := _variant_defs()
	entries = []
	for row in CARDS:
		var ids: Array = row[3]
		var labels: Array = row[4]
		var vs: Array = []
		for k in ids.size():
			if not defs.has(str(ids[k])):
				continue
			var v: Dictionary = defs[str(ids[k])]
			v["short"] = str(labels[k]) if str(labels[k]) != "" else str(row[1])
			v["card"] = str(row[0])
			vs.append(v)
		if vs.is_empty():
			continue
		var vi := clampi(int(_mem_variant.get(str(row[0]), 0)), 0, vs.size() - 1)
		entries.append(_card_entry(str(row[0]), str(row[1]), str(row[2]), vs, vi))
	index = -1
	for i in entries.size():
		if str(entries[i].get("card", "")) == keep:
			index = i
			break
	_fit_index()


## A card: its active variant's entry + the card fields (see `entries`).
static func _card_entry(cid: String, cname: String, cat: String, variants: Array, vi: int) -> Dictionary:
	var c: Dictionary = (variants[vi] as Dictionary).duplicate()
	c["card"] = cid
	c["card_name"] = cname
	c["cat"] = cat
	c["variants"] = variants
	c["variant"] = vi
	return c


## Every variant of every card (flat; the thumbnails).
func variant_entries() -> Array:
	var out: Array = []
	for e in entries:
		out.append_array(e.get("variants", [e]))
	return out


## The active variant's label ("Delici", "Duvar", "Silahlı"…); "" on a single-variant card.
func variant_name() -> String:
	var e := current_entry()
	return str(e.get("short", "")) if (e.get("variants", []) as Array).size() > 1 else ""


## The selected card's variant labels (for the pips).
func variant_names() -> Array:
	var out: Array = []
	for v in current_entry().get("variants", []):
		out.append(str((v as Dictionary).get("short", "")))
	return out


## The remembered category (a new tool of a respawned player starts where the last one left off).
func _restore_pick() -> void:
	if _mem_category >= 0 and _mem_category < categories.size():
		category = _mem_category


func _remember() -> void:
	_mem_category = category
	var e := current_entry()
	if not e.is_empty():
		_mem_card[category] = str(e.get("card", ""))
		_mem_variant[str(e.get("card", ""))] = int(e.get("variant", 0))


## Every buildable kind (variant) by id: today's entry shape {"id", "name", "cost", "half", "radius",
## "hp", "desc", "under", "modular", ["script"]} (the shuttles once scripts/craft/skiff.gd exists).
func _variant_defs() -> Dictionary:
	var list: Array = [{"id": "armory", "name": "Silahlık", "cost": Balance.ARMORY_COST, "half": Vector3(3.0, 1.8, 2.6),
			"radius": Balance.ARMORY_FOOTPRINT, "hp": Balance.ARMORY_HP, "script": Armory,
			"desc": "Kalıcı gelişmeler (matkap, ikmal indirimi, bomba kemeri), eklentiler ve el bombası; yükleme seçimi ve İkmal kapsülü (F)."},
			{"id": "cannon", "name": "Top", "cost": Balance.CANNON_COST, "half": Vector3(2.5, 1.7, 2.5),
			"radius": Balance.CANNON_FOOTPRINT, "hp": Balance.CANNON_HP,
			"desc": "Ağır top: rakip gezegeni döver, çekirdeğe krater açar."},
			{"id": "flak", "name": "Uçaksavar", "cost": Balance.FLAK_COST, "half": Vector3(1.9, 1.4, 1.9),
			"radius": Balance.FLAK_FOOTPRINT, "hp": Balance.FLAK_HP,
			"desc": "Mermileri ve mekikleri havada vurur. Düşman gezegenine de kurulur."},
			{"id": "buster", "name": "Delici Top", "cost": Balance.BUSTER_COST, "half": Vector3(2.7, 1.6, 2.7),
			"radius": Balance.BUSTER_FOOTPRINT, "hp": Balance.BUSTER_HP, "script": Buster,
			"desc": "Toprağa gömülüp derinde patlayan delici mermi atar."},
			{"id": "torpedo_rig", "name": "Sondaj Kulesi", "cost": Balance.TORPEDO_RIG_COST, "half": TorpedoRig.footprint(),
			"radius": Balance.TORPEDO_RIG_FOOTPRINT, "hp": Balance.TORPEDO_RIG_HP, "script": TorpedoRig,
			"desc": "Yalnız düşman gezegenine. Torpidoyu toprağa indirir; torpido çekirdeğe kazar."},
			{"id": "auto_miner", "name": "Otomatik Kazıcı", "cost": Balance.MINER_COST, "half": AutoMiner.footprint(),
			"radius": Balance.MINER_FOOTPRINT, "hp": Balance.MINER_HP, "script": AutoMiner,
			"desc": "Kendi kuyusunu kazar, sana malzeme üretir. Düşman gezegenine de (orada daha verimli)."}]
	if ResourceLoader.exists(SKIFF_PATH):
		var s = load(SKIFF_PATH)
		if s is Script and (s as Script).can_instantiate():
			var half := Vector3(3.0, 1.5, 4.0)
			for m in (s as Script).get_script_method_list():
				if str(m.get("name", "")) == "footprint":
					half = s.call("footprint")
					break
			var consts: Dictionary = (s as Script).get_script_constant_map()
			var cost := float(consts.get("BUILD_COST", Balance.SHUTTLE_COST_HINT))
			var nm := str(consts.get("DISPLAY_NAME", "Mekik"))
			list.append({"id": "skiff", "name": nm, "cost": cost, "half": half, "radius": maxf(half.x, half.z),
					"script": s, "hp": float(consts.get("HP_MAX", 180.0)),
					"desc": "İki kişilik araç: karşıya uç, in, kaz. Düşman gezegenine de kurulur."})
	# The Silahlı Mekik (scripts/craft/armed_skiff.gd, extends skiff.gd): its values come from
	# build_info() (a subclass cannot redeclare BUILD_COST / DISPLAY_NAME).
	if ResourceLoader.exists(ARMED_SKIFF_PATH):
		var a = load(ARMED_SKIFF_PATH)
		if a is Script and (a as Script).can_instantiate():
			var info: Dictionary = a.call("build_info")
			var ah: Vector3 = a.call("footprint")
			list.append({"id": "armed_skiff", "name": str(info.get("name", "Silahlı Mekik")),
					"cost": float(info.get("cost", 600.0)), "half": ah, "radius": maxf(ah.x, ah.z), "script": a,
					"hp": float(info.get("hp", 240.0)),
					"desc": "Mekik + burun altında çift döner top (ısınır) ve 4'lü roket salvosu."})
	# Base building (scripts/war/base_kit.gd).
	var pieces := [
		["sentry_turret", "Otomatik Taret", Balance.TURRET_COST, Balance.TURRET_HP,
				"35 m içinde gördüğü düşmanı çift makineliyle vurur. Tünele de kurulur."],
		["armor_wall", "Takviyeli Duvar", Balance.WALL_COST, Balance.WALL_HP,
				"Ucuz siper: mermiyi ve patlamayı keser, mazgallı. Duvarlara ve sığınağa yapışır."],
		["blast_door", "Zırhlı Kapı", Balance.DOOR_COST, Balance.DOOR_HP,
				"Sığınak kapısına ya da tünele. Bizimkilere açılır, düşman kırmak zorunda."],
		["bunker_module", "Sığınak Modülü", Balance.BUNKER_COST, Balance.BUNKER_HP,
				"Betonarme oda (4×4 m), iki kapı, kendi lambası. Kapıdan kapıya eklenir; patlamaya dayanıklı."],
		["light_post", "Işık Direği", Balance.LIGHT_COST, Balance.LIGHT_HP,
				"Tünelleri ve sığınakları sıcak beyaz ışıkla aydınlatır."],
		["radar_tower", "Radar Kulesi", Balance.RADAR_COST, Balance.RADAR_HP,
				"60 m içindeki düşmanları, yeraltındaki kazıcıları bile gösterir."],
		["core_shield", "Çekirdek Kalkanı", Balance.CORE_SHIELD_COST, Balance.CORE_SHIELD_HP,
				"Çekirdeğinin 8 m yakınına kaz ve kur: çekirdek hasarı %40'a iner. Tek tane."]]
	for pc in pieces:
		var id := str(pc[0])
		var path := str(BaseKit.PIECES.get(id, ""))
		if path == "" or not ResourceLoader.exists(path):
			continue
		var s = load(path)
		if not (s is Script) or not (s as Script).can_instantiate():
			continue
		list.append({"id": id, "name": str(pc[1]), "cost": float(pc[2]), "half": BaseKit.half_of(id),
				"radius": BaseKit.radius_of(id), "hp": float(pc[3]), "script": s, "desc": str(pc[4])})
	var out := {}
	for e in list:
		var id := str(e.get("id", ""))
		var sp := (e["script"] as Script).resource_path if e.get("script") is Script else ""
		e["under"] = Balance.build_underground(id, sp)
		e["modular"] = id in BaseKit.MODULAR
		e["what"] = str(WHAT.get(id, e.get("desc", "")))
		out[id] = e
	return out


## The entry indices of category `c`.
func category_indices(c: int) -> Array:
	var out: Array = []
	if c < 0 or c >= categories.size():
		return out
	for i in entries.size():
		if str(entries[i].get("cat", "")) == str(categories[c]):
			out.append(i)
	return out


func category_name() -> String:
	return str(categories[category]) if category >= 0 and category < categories.size() else ""


## Keeps `index` inside the current category (the last pick there, else its first entry); an empty
## category gives way to the next non-empty one.
func _fit_index() -> void:
	if entries.is_empty():
		index = 0
		return
	var idx := category_indices(category)
	if idx.is_empty():
		for k in categories.size():
			var c := posmod(category + k, categories.size())
			if not category_indices(c).is_empty():
				category = c
				break
		idx = category_indices(category)
	if idx.has(index):
		return
	var pick := str(_mem_card.get(category, ""))
	for i in idx:
		if str(entries[i].get("card", "")) == pick:
			index = i
			return
	index = int(idx[0]) if not idx.is_empty() else clampi(index, 0, entries.size() - 1)


## Q / E: the next / previous non-empty category (on its remembered card).
func _cycle_category(step: int) -> void:
	_refresh_entries()
	for k in categories.size():
		category = posmod(category + step, categories.size())
		if not category_indices(category).is_empty():
			break
	_fit_index()
	_remember()
	_guide_tick("cat")
	kick = maxf(kick, 0.15)
	_check_t = 0.0
	_arc_t = 0.0
	category_changed.emit(category)
	if Game.sfx:
		Game.sfx.play("switch", -10.0, 1.0 + category * 0.06)


## T / Shift + wheel: the next / previous variant of the selected card (Top: Standart / Delici;
## Sığınak: Modül / Duvar / Kapı / Işık; Mekik: Silahsız / Silahlı). Remembered per card.
func _cycle_variant(step: int) -> void:
	var e := current_entry()
	var vs: Array = e.get("variants", [])
	if vs.size() < 2:
		if Game.sfx:
			Game.sfx.play("click", -18.0, 0.7)
		return
	var vi := posmod(int(e.get("variant", 0)) + step, vs.size())
	_mem_variant[str(e.get("card", ""))] = vi
	_refresh_entries()
	_remember()
	_guide_tick("variant")
	kick = maxf(kick, 0.15)
	_check_t = 0.0
	_arc_t = 0.0
	variant_changed.emit(vi)
	if Game.sfx:
		Game.sfx.play("toggle", -11.0, 1.0 + vi * 0.08)


## The selected card (= its active variant's entry, see `entries`).
func current_entry() -> Dictionary:
	return entries[index] if index >= 0 and index < entries.size() else {}


## build_menu.gd: show the card bar now.
func menu_wanted() -> bool:
	if not active or not equipped or player == null or not is_instance_valid(player):
		return false
	if player.vehicle != null or player.is_ragdolled() or player.is_dead():
		return false
	return not Game.ui_panel_open()


# =================================================================================================
# Model (view model: a handheld constructor with a screen and an emitter fork)
# =================================================================================================

func build_model() -> Node3D:
	model = Node3D.new()
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	VM.grip(model, orange)
	VM.soft_box(model, Vector3(0, 0.06, -0.06), Vector3(0.11, 0.07, 0.2), 0.015, white)
	VM.box(model, Vector3(0, 0.1, -0.05), Vector3(0.09, 0.008, 0.15), dark)
	_screen = VM.glow(OK_COL, 2.0)
	VM.box(model, Vector3(0, 0.105, -0.05), Vector3(0.075, 0.004, 0.12), _screen)
	for sx in [-1.0, 1.0]:
		VM.seg(model, Vector3(0.04 * sx, 0.06, -0.16), Vector3(0.05 * sx, 0.06, -0.26), 0.008, 0.005, steel, 8)
		VM.sphere(model, Vector3(0.05 * sx, 0.06, -0.265), 0.008, VM.glow(Color(0.4, 0.9, 1.0), 4.0))
	VM.box(model, Vector3(0, 0.03, -0.16), Vector3(0.05, 0.03, 0.04), orange)
	# Rubber handle for the left hand (long enough for the whole hand, under the housing).
	VM.soft_box(model, Vector3(0, -0.0215, -0.13), Vector3(0.03, 0.03, 0.093), 0.008, VM.rubber(), Basis(Vector3.RIGHT, PI * 0.5))
	left_grip = VM.node(model, Vector3(0, 0.0, -0.14), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	# The holo-projector at the fork: lens, gimbal rings, light cone, the beam's start (build_holo.gd).
	emitter = BuildHolo.make_emitter(model)
	VM.bake(model, [left_grip])
	return model


func accent_color() -> Color:
	return Color(0.4, 0.9, 1.0)


func crosshair_color() -> Color:
	return OK_COL if can_build else (BAD_COL if aim_valid else Color(0.8, 0.85, 0.9))


func status_text() -> String:
	return str(current_entry().get("name", ""))


## Right-panel lines for the HUD (scripts/ui/hud.gd): [title, detail, detail colour].
func hud_panel_lines() -> Array:
	var e := current_entry()
	var title := "%s  ·  %d m³" % [str(e.get("name", "")), int(e.get("cost", 0.0))]
	var detail := reason if reason != "" else "Sol tık: kur"
	return [title, detail, OK_COL if can_build else BAD_COL]


## The bottom hint line of the HUD: the card bar carries the controls now.
func hud_hint() -> String:
	return ""


func _on_state_changed() -> void:
	if active and equipped:
		_restore_pick()                      # back to the last category / card / variant
		_refresh_entries()
	else:
		_hide_ghost()


## Q / E change the card category, T the variant (before the player's Q = scanner sees it: _input
## runs first; T is only the rifle's ammo key, and no gun is held now).
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo() or not can_operate():
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or Game.ui_panel_open():
		return
	var k := (event as InputEventKey).physical_keycode
	if k == KEY_Q or k == KEY_E:
		_cycle_category(1 if k == KEY_E else -1)
		get_viewport().set_input_as_handled()
	elif k == KEY_T:
		_cycle_variant(-1 if (event as InputEventKey).shift_pressed else 1)
		get_viewport().set_input_as_handled()
	elif k == KEY_Z and (event as InputEventKey).ctrl_pressed:          # Ctrl+Z (plain Z: the drill, player.gd)
		_undo()
		get_viewport().set_input_as_handled()
	elif k == KEY_B:
		_ping()
		get_viewport().set_input_as_handled()
	elif k == KEY_H and not Game.has_meta("training"):          # (H is the Eğitim Alanı's panel there)
		_toggle_guide()
		get_viewport().set_input_as_handled()
	elif k == KEY_X and (event as InputEventKey).ctrl_pressed:          # Ctrl+X held: sell (plain X: back to the gun)
		get_viewport().set_input_as_handled()                    # (held: _tick_sell)


func _unhandled_input(event: InputEvent) -> void:
	if not can_operate():
		return
	if (event.is_action_pressed("brush_up") or event.is_action_pressed("brush_down")) and Input.is_key_pressed(KEY_SHIFT):
		_cycle_variant(1 if event.is_action_pressed("brush_down") else -1)      # Shift + wheel: variant
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("brush_up"):
		_cycle(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("brush_down"):
		_cycle(-1)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE:
		_ping()                                                  # middle click: "BURAYA KUR" (R turns)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tool_mode"):
		_rot_t = snappedf(_rot_t, ROT_STEP) + ROT_STEP
		_guide_tick("rotate")
		kick = maxf(kick, 0.12)
		if Game.sfx:
			Game.sfx.play("toggle", -14.0, 1.15)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and Input.is_action_pressed("tool_alt") \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and aim_valid:
		# Right mouse held: the mouse turns the ghost instead of the view.
		_rot_t -= (event as InputEventMouseMotion).relative.x * ROT_MOUSE
		_rot = _rot_t
		_free_px += absf((event as InputEventMouseMotion).relative.x)
		if _free_px > 60.0:
			_guide_tick("free")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tool_use") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_build()
		get_viewport().set_input_as_handled()


func _cycle(step: int) -> void:
	_refresh_entries()
	var idx := category_indices(category)          # the wheel stays inside the category
	if idx.is_empty():
		index = posmod(index + step, entries.size())
	else:
		var at := idx.find(index)
		index = int(idx[posmod(at + step, idx.size())]) if at >= 0 else int(idx[0])
	_remember()
	_guide_tick("pick")
	kick = maxf(kick, 0.2)
	_check_t = 0.0
	_arc_t = 0.0
	if Game.sfx:
		Game.sfx.play("click", -10.0, 1.0 + index * 0.1)


# =================================================================================================
# Placement
# =================================================================================================

func _physics_process(delta: float) -> void:
	_check_t -= delta
	if not can_operate():
		aim_valid = false
		can_build = false
		_hide_ghost()
		return
	var cam := get_parent() as Camera3D
	var from: Vector3 = player.aim_origin()
	var dir := -cam.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * Balance.BUILD_RANGE, Game.LAYER_TERRAIN)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	_sense_sell(from, dir, hit)
	if hit.is_empty():
		aim_valid = false
		can_build = false
		reason = "Zemine nişan al — en çok %d m uzağa kurulur" % int(Balance.BUILD_RANGE)
		_hide_ghost()
		return
	aim_valid = true
	var e := current_entry()
	_ensure_ghost(e)
	if _check_t <= 0.0:
		_check_t = 0.1
		_validate(hit["position"], hit["normal"], dir, e)
		reason = plain_reason(reason)
		if Net.active:
			_intent_on = true
			BuildIntent.set_local({"on": true, "id": str(e.get("id", "")), "name": str(e.get("name", "")),
					"xf": _xf.orthonormalized(), "ok": can_build})
	if _screen != null:
		_screen.set_shader_parameter("color", OK_COL if can_build else BAD_COL)


func _process(delta: float) -> void:
	_t += delta
	_use_t = maxf(_use_t - delta, 0.0)
	using = _use_t > 0.0
	_rot = lerp_angle(_rot, _rot_t, 1.0 - exp(-14.0 * delta))
	refuse_k = maxf(refuse_k - delta * 2.5, 0.0)
	rot_deg = fposmod(rad_to_deg(_rot), 360.0)
	_tick_easy(delta)
	# While the card bar is up (build_menu.gd) the tool is carried low at the right, clear of the
	# cards (the view model eases hold_offset in; the left hand stays on its handle).
	hold_offset = MENU_TUCK if menu_wanted() else Vector3.ZERO
	if not _ghost_on or holo == null:
		return
	# The ghost follows the validated spot every frame, with the (smoothed) rotation; a snapped piece
	# sits exactly on its joint.
	_xf = _snap_xf if snapped else Transform3D(Basis(_up, _rot) * _base_b, _base_o)
	_base_visuals()
	# Everything in-world is drawn by build_holo.gd (it runs right after this, as our child).
	holo.show_ghost(current_entry(), _xf, _up, _base_b, _rot, _rot_t, _ghost_state(), reason)


## 0 can build (cyan-white), 1 fixable here (amber: slope, uneven, too close), 2 blocked (red).
func _ghost_state() -> int:
	if can_build:
		return 0
	if reason.begins_with("Yetersiz") or reason.begins_with("Malzeme") or reason.begins_with("Sadece") \
			or reason.begins_with("Gezegen"):
		return 2
	return 1


## Base-building visual data to the hologram every frame (BuildFx clears them ~0.15 s after the last
## call): the snap joint lines, the free joints of nearby modular pieces, the underground headroom box,
## the structure in the way.
func _base_visuals() -> void:
	if not snap_pairs.is_empty():
		_fx("snap_guides", [snap_pairs])
	if bool(current_entry().get("modular", false)):
		var pts := PackedVector3Array()
		for s in get_tree().get_nodes_in_group("war_base"):
			if s is Node3D and not s.has_meta("build_preview") and Game.team_of(s) == "home" \
					and (s as Node3D).global_position.distance_to(_xf.origin) < 12.0 and s.has_method("doorways"):
				for d in s.doorways():
					pts.append(d)
		if not pts.is_empty():
			_fx("snap_points", [pts])
	if not headroom.is_empty():
		_fx("headroom_box", [headroom["xf"], headroom["aabb"], bool(headroom["ok"])])
	if not blockers.is_empty():
		_fx("mark_blockers", [blockers])


## Calls a BuildFx build-mode helper when it exists (scripts/war/build_fx.gd owns the visuals).
func _fx(fn: String, args: Array) -> void:
	if not _fx_has.has(fn):
		var ok := false
		for m in (BuildFx as Script).get_script_method_list():
			if str(m.get("name", "")) == fn:
				ok = true
				break
		_fx_has[fn] = ok
	if bool(_fx_has[fn]):
		var fx: Script = BuildFx
		fx.callv(fn, args)


## Placement transform and validity for entry `e` at ground point p (normal n), looking along dir.
func _validate(p: Vector3, n: Vector3, dir: Vector3, e: Dictionary) -> void:
	can_build = false
	snapped = false
	snap_pairs = []
	headroom = {}
	blockers = []
	var body: Node3D = Game.dominant_body(p)
	var up: Vector3 = body.up_at(p) if body != null else n
	# Underground (scripts/war/base_kit.gd): soil straight over the spot = a covered cavity. Aimed at a
	# cavity wall or its ceiling, the spot drops to the floor under it.
	var cover := BaseKit.cover_above(body, p, up) if body != null else INF
	underground = not is_inf(cover)
	if body != null and underground and n.dot(up) < 0.5:
		var fl := BaseKit.floor_below(body, p + n * 0.45, up)
		if not fl.is_empty():
			p = fl["position"]
			n = fl["normal"]
			up = body.up_at(p)
			underground = not is_inf(BaseKit.cover_above(body, p, up))
	var fwd := dir - up * dir.dot(up)
	# Guns and turrets face the enemy planet (the turret: the nearest threat) by default.
	if str(e.get("id", "")) in AUTO_FACE and body != null:
		var ft := _face_target(p, str(e.get("id", "")), body)
		if ft != Vector3.INF:
			var f2 := ft - p
			f2 -= up * f2.dot(up)
			if f2.length_squared() > 1e-3:
				fwd = f2
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(Vector3.RIGHT)
	var z := -fwd.normalized()
	var x := up.cross(z).normalized()
	var b := Basis(x, up, x.cross(up))
	var r: float = float(e.get("radius", 3.0))
	# Footprint samples: the exact ground (Foundation.ground_offset: the terrain collision, else the
	# full density) relative to p along up, at the corners, edge middles and centre of the rotated
	# footprint box. (A circle at 0.8 r of the cheap height field missed the slab corners and the
	# ±1.3 m detail noise: structures hung over the low side.) Spread allowed per kind: STEP_TOL.
	var id := str(e.get("id", ""))
	var half: Vector3 = e.get("half", Vector3(r, 1.5, r))
	var rb := Basis(up, _rot_t) * b
	var po := p
	# Modular pieces snap to the side's modules / walls near the aim (BaseKit.snap).
	if body != null and bool(e.get("modular", false)):
		var sn := BaseKit.snap(id, p, "home", get_tree())
		if not sn.is_empty():
			snapped = true
			_snap_xf = sn["xf"]
			rb = _snap_xf.basis
			po = _snap_xf.origin
			up = rb.y.normalized()
			var g: Array = sn.get("guides", [])
			if g.size() >= 2:
				snap_pairs = [[g[1], g[0]]]
	var step_tol := float(STEP_TOL.get(id, BaseKit.step_tol(id)))
	var need := half.y * 2.0 + Balance.HEADROOM_MARGIN
	var lowest := INF
	var highest := -INF
	var ceiling := INF
	var flat_ok := body != null
	var fit_why := ""
	if body != null and underground:
		# The cavity floor under the footprint, its walls and its ceiling (BaseKit.cavity_fit).
		var fit := BaseKit.cavity_fit(self, body, po, up, rb, half, need)
		flat_ok = bool(fit["ok"])
		fit_why = str(fit["reason"])
		lowest = float(fit["lowest"])
		highest = float(fit["highest"])
		ceiling = float(fit["ceiling"])
	elif body != null:
		for i in 9:
			var lp := Vector3(float(i % 3 - 1) * half.x, 0.0, float(floori(i / 3.0) - 1) * half.z)
			var off := Foundation.ground_offset(self, body, po + rb * lp, up, 4.0, 6.0)
			if is_inf(off):
				flat_ok = false
				break
			lowest = minf(lowest, off)
			highest = maxf(highest, off)
	if not flat_ok:
		lowest = 0.0
		highest = 0.0
	_up = up
	_base_b = b
	var base_off := 0.0 if snapped else lerpf(lowest, highest, float(BASE_K.get(id, BaseKit.base_k(id))))
	_base_o = po + up * base_off
	_xf = _snap_xf if snapped else Transform3D(Basis(up, _rot) * b, _base_o)
	if underground and body != null:
		headroom = {"xf": Transform3D(rb, _base_o), "aabb": AABB(Vector3(-half.x, 0.0, -half.z), Vector3(half.x * 2.0, need, half.z * 2.0)),
				"ok": flat_ok and ceiling - base_off >= need}
	# Where it may stand (Balance.BUILD_SITE: own planet only / anywhere / enemy planet only).
	var sp := (e["script"] as Script).resource_path if e.get("script") is Script else ""
	var site_why := Balance.build_site_reason(str(e.get("id", "")), sp, body == Game.planet)
	if body == null or (body != Game.planet and body != Game.rival):
		site_why = "Gezegen üzerinde değil"
	if site_why != "":
		reason = site_why
		return
	if underground and not bool(e.get("under", false)):
		reason = "Yeraltına kurulamaz — açık gökyüzü gerekir"
		return
	if not snapped and n.dot(up) < cos(deg_to_rad(Balance.BUILD_MAX_SLOPE_DEG)):
		reason = "Çok eğimli"
		return
	if fit_why != "":
		reason = fit_why
		return
	if snapped:
		# Joined to another piece: its floor level is fixed; soil may not rise into it, and it may not
		# hang far over a hole (the foundation fills a little).
		if not flat_ok or highest > step_tol * 0.6 or lowest < -3.0:
			reason = "Zemin düz değil"
			return
	elif not flat_ok or highest - lowest > step_tol:
		reason = "Zemin düz değil"
		return
	if underground and ceiling - base_off < need:
		reason = "Tavan çok alçak — biraz daha kaz"
		return
	var rule := BaseKit.rule_reason(id, _xf, "home", get_tree())
	if rule != "":
		reason = rule
		return
	var ov := BaseKit.overlap_reason(id, _xf.orthonormalized(), r, get_tree(), player.global_position)
	if ov != "":
		reason = ov
		if BaseKit.last_blocker != null and is_instance_valid(BaseKit.last_blocker):
			blockers = [BaseKit.last_blocker]
		return
	if Game.material + 0.001 < float(e.get("cost", 0.0)):
		reason = "Yetersiz malzeme: %d m³ eksik" % int(ceilf(float(e.get("cost", 0.0)) - Game.material))
		return
	reason = ""
	can_build = true


func _build() -> void:
	var e := current_entry()
	if e.is_empty():
		return
	if not can_build:
		if Game.sfx:
			Game.sfx.play("error", -10.0)
		if Game.hud and reason != "":
			Game.hud.alert(reason, 1, "build", 1.8)
		refuse_k = 1.0
		if holo != null:
			holo.refuse()                      # the ghost shakes, its edges and the blockers flash, a buzz
		return
	if not Game.spend_material(float(e["cost"])):
		return
	var xf := _snap_xf.orthonormalized() if snapped else Transform3D(Basis(_up, _rot) * _base_b, _base_o)
	_snap_fx(xf)
	_guide_tick("build")
	undo_left = Balance.UNDO_TIME
	undo_name = str(e["name"])
	_last_build_pos = xf.origin
	_last_build_kind = str(e["id"])
	_last_build = null
	if Net.is_client():
		# Multiplayer: the host builds it (scripts/net/net_world.gd); a refusal pays the cost back.
		var sp := (e["script"] as Script).resource_path if e.get("script") is Script else ""
		Net.world.request_build(str(e["id"]), sp, xf, float(e["cost"]))
		_use_t = 0.35
		kick = maxf(kick, 0.4)
		can_build = false
		_check_t = 0.0
		if Game.hud:
			Game.hud.alert("%s kuruluyor… (-%d m³)  ·  Ctrl+Z: geri al" % [e["name"], int(e["cost"])], 0, "build", 2.0)
		return
	var scene: Node = get_tree().current_scene
	# The planet it stands on (ours, or the enemy's for a foothold); it keeps OUR team either way.
	var on_body: Node3D = Game.dominant_body(xf.origin)
	var built: Node3D = null
	match str(e["id"]):
		"cannon":
			built = Cannon.spawn(scene, on_body, xf, "home", true)
		"flak":
			built = Flak.spawn(scene, on_body, xf, "home", true)
		"buster":
			built = Buster.spawn(scene, on_body, xf, "home", true)
		"armory":
			built = Armory.spawn(scene, on_body, xf, "home", true)
		"torpedo_rig":
			built = TorpedoRig.spawn(scene, on_body, xf, "home", true)
		"auto_miner":
			built = AutoMiner.spawn(scene, on_body, xf, "home", true)      # owner_peer 0: pays this machine's player
		"bunker_module", "armor_wall", "blast_door", "sentry_turret", "core_shield", "radar_tower", "light_post":
			built = BaseKit.spawn(str(e["id"]), "home", xf, on_body, true)  # (base pieces: scripts/war/base_kit.gd)
		"skiff", "armed_skiff":
			var sk: Node3D = (e["script"] as Script).new()
			sk.transform = xf
			scene.add_child(sk)
			sk.add_to_group("war_structure")
			sk.set_meta("footprint_r", float(e["radius"]))
			if sk.has_method("place"):
				sk.place(on_body, xf)
			BuildFx.assemble(scene, xf, e["half"], BuildFx.AUTO, sk)
			built = sk
	if built != null and is_instance_valid(built):
		# Who built it and for how much (undo / sell refunds; the partner's notification).
		built.set_meta("build_cost", float(e["cost"]))
		built.set_meta("built_ms", Time.get_ticks_msec())
		built.set_meta("builder", Net.my_name if Net.active else "")
		_last_build = built
	_use_t = 0.35
	kick = maxf(kick, 0.4)
	can_build = false
	_check_t = 0.0
	if Game.hud:
		Game.hud.alert("%s kuruldu (-%d m³)  ·  Ctrl+Z: geri al" % [e["name"], int(e["cost"])], 0, "build", 2.0)


## The build went through at `xf`: the ghost collapses into the ground, the beam pulses, the chime,
## a small camera kick (build_holo.gd confirm); the structure's own begin_assembly() then runs the
## print (BuildFx.assemble: build volume, fabrication front, sparks, shockwave, sound).
func _snap_fx(xf: Transform3D) -> void:
	if holo != null:
		holo.confirm(xf)


# =================================================================================================
# Hologram ghost (drawn by scripts/war/build_holo.gd)
# =================================================================================================

func _hide_ghost() -> void:
	_ghost_on = false
	if holo != null:
		holo.hide_all()
	if _intent_on:
		_intent_on = false
		BuildIntent.set_local({"on": false})


## The hologram for the current entry: the real model, cached per kind in build_holo.gd.
func _ensure_ghost(e: Dictionary) -> void:
	_ghost_on = true
	var kind := str(e.get("id", ""))
	if holo != null and (_ghost_kind != kind or _ghost == null or not is_instance_valid(_ghost)):
		if kind != _ghost_kind and kind in AUTO_FACE:
			_rot_t = 0.0                           # (faces the enemy planet / the threat; R turns from there)
			_rot = 0.0
		_ghost_kind = kind
		_ghost = holo.ghost_root(e)
		_arc_t = 0.0


# =================================================================================================
# Easy building (2026-10-06): plain reasons, auto-facing, the guide, the recommendation, undo / sell,
# pings (and the co-op intent: scripts/war/build_intent.gd)
# =================================================================================================

## The placement reason in plain words: what is wrong and how to fix it. (BaseKit / the network keep
## the short forms; the hologram looks for "eğim" / "düz" / "yapı" / "yakınsın" in it.)
static func plain_reason(r: String) -> String:
	if r.begins_with("Yetersiz malzeme"):
		var n := r.get_slice(":", 1).strip_edges().get_slice(" ", 0)
		return ("Malzeme: %s m³ eksik — kazmaya devam" % n) if n != "" else "Malzeme yetmiyor — kazmaya devam"
	match r:
		"Çok eğimli":
			return "Çok eğimli — daha düz bir yer seç"
		"Zemin düz değil":
			return "Zemin engebeli — biraz daha düz bir yer seç"
		"Tavan çok alçak — biraz daha kaz":
			return "Tavan alçak: biraz daha kaz"
		"Yer dar — biraz daha kaz":
			return "Yer dar: yanları biraz daha kaz"
		"Başka bir yapıya çok yakın":
			return "Başka bir yapıya çok yakın — biraz öteye nişan al"
		"Başka bir yapıyla çakışıyor":
			return "Başka bir yapıyla çakışıyor — biraz öteye nişan al"
		"Sadece kendi gezegenine kurulur":
			return "Sadece kendi gezegenine kurulur — evine dön"
		"Sadece düşman gezegenine kurulur":
			return "Sadece düşman gezegenine kurulur — mekikle karşıya geç"
		"Gezegen üzerinde değil":
			return "Gezegen üzerinde değil — zemine nişan al"
	return r


## Where a gun / turret built at p faces by default: the other planet; a turret: the nearest live
## threat within 1.5 × its range (a drop pod, an enemy bot / player), else the other planet.
func _face_target(p: Vector3, id: String, body: Node3D) -> Vector3:
	if id == "sentry_turret":
		var best := Vector3.INF
		var best_d := Balance.TURRET_RANGE * 1.5
		var cands: Array = get_tree().get_nodes_in_group("war_ai") + get_tree().get_nodes_in_group("war_drop_pod") \
				+ get_tree().get_nodes_in_group("net_player")
		for n in cands:
			if not (n is Node3D) or Game.team_of(n) == "home" or (n.has_method("is_dead") and n.is_dead()) \
					or n.is_in_group("training_dummy"):
				continue
			var d := (n as Node3D).global_position.distance_to(p)
			if d < best_d:
				best_d = d
				best = (n as Node3D).global_position
		if best != Vector3.INF:
			return best
	var other: Node3D = Game.rival if body == Game.planet else Game.planet
	return other.global_position if other != null and is_instance_valid(other) else Vector3.INF


## Per frame: the undo window, the income samples, the recommendation, the guide, the sell hold.
func _tick_easy(delta: float) -> void:
	if undo_left > 0.0:
		undo_left = maxf(undo_left - delta, 0.0)
		if not Net.is_client() and (_last_build == null or not is_instance_valid(_last_build) or _last_build.has_meta("deconstructed")):
			undo_left = 0.0
	_ping_t = maxf(_ping_t - delta, 0.0)
	# Income: m³ gained per second over the last minute (runs while the tool is not held too).
	_inc_t -= delta
	if _inc_t <= 0.0:
		_inc_t = 1.0
		if _mat_prev >= 0.0:
			_income.append(maxf(Game.material - _mat_prev, 0.0))
			if _income.size() > 60:
				_income.pop_front()
		_mat_prev = Game.material
	var shown := menu_wanted()
	if shown:
		_reco_t -= delta
		if _reco_t <= 0.0:
			_reco_t = 1.0
			_update_reco()
		# The guide opens by itself the first time the tool is held in a run; it closes ~2.5 s after
		# the last step is done.
		if not _guide_seen:
			_guide_seen = true
			_set_guide(true)
		if guide_open and _guide_all_done():
			if _guide_done_t < 0.0:
				_guide_done_t = 2.5
			_guide_done_t -= delta
			if _guide_done_t <= 0.0:
				_set_guide(false)
		else:
			_guide_done_t = -1.0
	_tick_sell(delta, shown)


func _set_guide(on: bool) -> void:
	guide_open = on
	_guide_open_mem = on
	_guide_done_t = -1.0


func _guide_all_done() -> bool:
	for s in GUIDE_STEPS:
		if not bool(guide_steps.get(s, false)):
			return false
	return true


func _guide_tick(step: String) -> void:
	if not bool(guide_steps.get(step, false)):
		guide_steps[step] = true
		if guide_open and Game.sfx:
			Game.sfx.play("ding", -14.0, 1.2)


## H: the guide open / closed (opened again with everything done: the ticks start over).
func _toggle_guide() -> void:
	if guide_open:
		_set_guide(false)
	else:
		if _guide_all_done():
			guide_steps.clear()
		_free_px = 0.0
		_set_guide(true)
	if Game.sfx:
		Game.sfx.play("click", -12.0, 1.1)


# --- The recommendation ---------------------------------------------------------------------------

func _own_count(group: String) -> int:
	var n := 0
	for s in get_tree().get_nodes_in_group(group):
		if Game.team_of(s) == "home" and s.get("is_destroyed") != true and not s.has_meta("build_preview") \
				and not s.has_meta("deconstructed"):
			n += 1
	return n


func _has_card(cid: String) -> bool:
	for e in entries:
		if str(e.get("card", "")) == cid:
			return true
	return false


## The "ÖNERİLEN" card and why, from the situation (first match wins): enemies on our planet ->
## Taret; an enemy skiff / drop pods coming -> Uçaksavar (Taret when there is one); our core hurt and
## no shield -> Çekirdek Kalkanı; no cannon -> Top; no armory -> Silahlık; a low income and no miner
## -> Otomatik Kazıcı; no radar -> Radar.
func _update_reco() -> void:
	var card := ""
	var why := ""
	var home: Node3D = Game.planet
	var raid := 0
	for b in get_tree().get_nodes_in_group("war_ai"):
		if not (b is Node3D) or Game.team_of(b) == "home" or b.is_in_group("training_dummy"):
			continue
		if b.has_method("is_dead") and b.is_dead():
			continue
		if home != null and Game.dominant_body((b as Node3D).global_position) == home:
			raid += 1
	var pods := 0
	for p in get_tree().get_nodes_in_group("war_drop_pod"):
		if Game.team_of(p) != "home" and p.has_method("is_live") and p.is_live():
			pods += 1
	var skiffs := 0
	for s in get_tree().get_nodes_in_group("skiff"):
		if not (s is Node3D) or Game.team_of(s) == "home" or s.get("landed") == true or home == null:
			continue
		if (s as Node3D).global_position.distance_to(home.global_position) < float(home.get("radius")) + 120.0:
			skiffs += 1
	var core := BaseKit.own_core("home", get_tree())
	var core_hurt: bool = core != null and float(core.get("hp")) < float(core.get("hp_max")) * Balance.RECO_CORE_HP
	var income := 0.0
	for v in _income:
		income += float(v)
	var low_income := _income.size() >= 30 and income / float(_income.size()) < Balance.RECO_LOW_INCOME
	if raid > 0:
		card = "turret"
		why = "Gezegenimizde düşman var — taret kendiliğinden vurur"
	elif skiffs > 0 or pods > 0:
		card = "flak" if _own_count("war_flak") == 0 else "turret"
		why = "Rakip mekik geliyor" if skiffs > 0 else "Çıkarma kapsülleri geliyor"
	elif core_hurt and _own_count("war_core_shield") == 0:
		card = "core_shield"
		why = "Çekirdeğimiz hasar aldı — kalkanla koru"
	elif _own_count("war_cannon") == 0:
		card = "top"
		why = "Henüz topun yok — rakibi dövmeye başla"
	elif _own_count("war_armory") == 0:
		card = "armory"
		why = "Kalıcı gelişmeler ve eklentiler için bir Silahlık kur"
	elif low_income and _own_count("war_miner") == 0:
		card = "miner"
		why = "Malzeme geliri düşük — kazıcı senin için kazsın"
	elif _own_count("war_radar") == 0:
		card = "radar"
		why = "Düşmanı erken görmek için radar kur"
	if card != "" and not _has_card(card):
		card = ""
		why = ""
	recommend_card = card
	recommend_reason = why


## Category index of a card (-1: unknown); the UI marks the tab of the recommended card.
func card_category(cid: String) -> int:
	for e in entries:
		if str(e.get("card", "")) == cid:
			return categories.find(str(e.get("cat", "")))
	return -1


# --- Undo (Z) and sell (X held) ---------------------------------------------------------------------

## Z: the last build back for the full price, within Balance.UNDO_TIME s.
func _undo() -> void:
	if undo_left <= 0.0:
		if Game.hud:
			Game.hud.alert("Geri alınacak yapı yok (kurduktan sonra %d sn içinde Z)" % int(Balance.UNDO_TIME), 1, "build", 2.0)
		return
	var n: Node3D = _last_build
	if Net.is_client():
		n = _find_built(_last_build_pos, _last_build_kind)
		if n == null:
			if Game.hud:
				Game.hud.alert("Yapı henüz kurulmadı — bir an bekle", 1, "build", 1.6)
			return
		_request_unbuild(n, 1.0)
		undo_left = 0.0
		return
	var why := BaseKit.unbuild_reason(n, 1.0, "home")
	if why != "":
		if Game.hud:
			Game.hud.alert(why, 1, "build", 1.8)
		if Game.sfx:
			Game.sfx.play("error", -10.0)
		return
	var back := BaseKit.refund_of(n, 1.0)
	BaseKit.deconstruct(n)
	Game.add_material(back)
	undo_left = 0.0
	_last_build = null
	_check_t = 0.0
	if Game.hud:
		Game.hud.alert("%s geri alındı (+%d m³)" % [undo_name, int(roundf(back))], 0, "build", 2.0)
	if Game.sfx:
		Game.sfx.play("toggle", -8.0, 0.8)


## A war structure of `kind` standing within 0.8 m of p (a client finds the host's copy of its build).
func _find_built(p: Vector3, kind: String) -> Node3D:
	for s in get_tree().get_nodes_in_group("war_structure"):
		if s is Node3D and (s as Node3D).global_position.distance_to(p) < 0.8 and BaseKit.kind_of(s) == kind:
			return s
	return null


## Multiplayer client: the host takes it down (net_world.gd request_unbuild, the MP agent's).
func _request_unbuild(n: Node3D, refund_k: float) -> void:
	if Net.world != null and Net.world.has_method("request_unbuild"):
		Net.world.call("request_unbuild", int(n.get_meta("net_id")) if n.has_meta("net_id") else 0, refund_k)
		if Game.hud:
			Game.hud.alert("%s sökülüyor…" % BaseKit.display_name(BaseKit.kind_of(n)), 0, "build", 1.6)
	elif Game.hud:
		Game.hud.alert("Çok oyunculuda sökme henüz yok", 1, "build", 1.8)


## The own structure under the crosshair (the ship / vehicle layers, nearer than the ground) and the
## sell line for it.
func _sense_sell(from: Vector3, dir: Vector3, ground: Dictionary) -> void:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * Balance.BUILD_RANGE, Game.LAYER_SHIP | Game.LAYER_VEHICLE)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var s: Node3D = null
	if not hit.is_empty():
		var gd := from.distance_to(ground["position"]) if not ground.is_empty() else INF
		if from.distance_to(hit["position"]) <= gd + 0.3:
			s = BaseKit.structure_of(hit.get("collider"))
	if s != null and (Game.team_of(s) != "home" or s.has_meta("deconstructed")):
		s = null
	# Sticky for a moment: a frame between two colliders (or X held over a thin part) keeps the target.
	if s == null and sell_target != null and is_instance_valid(sell_target) and not sell_target.has_meta("deconstructed") \
			and _sell_lost < 0.35:
		_sell_lost += get_physics_process_delta_time()
		return
	_sell_lost = 0.0
	if s != sell_target:
		sell_target = s
		sell_k = 0.0
	if s == null:
		sell_text = ""
		sell_ok = false
		return
	var why := BaseKit.unbuild_reason(s, Balance.SELL_REFUND, "home")
	sell_ok = why == ""
	var nm := BaseKit.display_name(BaseKit.kind_of(s))
	var by := str(s.get_meta("builder")) if s.has_meta("builder") else ""
	if by != "" and Net.active and by != Net.my_name:
		nm += " (%s kurdu)" % by
	if sell_ok:
		var pct := int(roundf(Balance.SELL_REFUND * 100.0))
		var back := int(roundf(BaseKit.refund_of(s, Balance.SELL_REFUND)))
		sell_text = "[Ctrl+X basılı tut] Sök: " + nm + " — %" + str(pct) + " iade (+" + str(back) + " m³)"
	else:
		sell_text = "%s · %s" % [nm, why]


func _tick_sell(delta: float, shown: bool) -> void:
	var holding := shown and sell_ok and sell_target != null and is_instance_valid(sell_target) \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_physical_key_pressed(KEY_X) and Input.is_key_pressed(KEY_CTRL) and can_operate()
	if not holding:
		sell_k = move_toward(sell_k, 0.0, delta * 4.0)
		return
	sell_k = minf(sell_k + delta / maxf(Balance.SELL_HOLD, 0.1), 1.0)
	if sell_k >= 1.0:
		sell_k = 0.0
		_sell(sell_target)


func _sell(n: Node3D) -> void:
	if Net.is_client():
		_request_unbuild(n, Balance.SELL_REFUND)
		return
	var why := BaseKit.unbuild_reason(n, Balance.SELL_REFUND, "home")
	if why != "":
		if Game.hud:
			Game.hud.alert(why, 1, "build", 1.8)
		return
	var nm := BaseKit.display_name(BaseKit.kind_of(n))
	var back := BaseKit.refund_of(n, Balance.SELL_REFUND)
	if n == _last_build:
		undo_left = 0.0
	BaseKit.deconstruct(n)
	Game.add_material(back)
	sell_target = null
	sell_text = ""
	sell_ok = false
	_check_t = 0.0
	if Game.hud:
		Game.hud.alert("%s söküldü (+%d m³)" % [nm, int(roundf(back))], 0, "build", 2.0)


# --- Pings (middle click / B) ----------------------------------------------------------------------

## "BURAYA KUR: <yapı>" where the ghost stands (else where the crosshair meets the ground): both
## players see it (scripts/war/build_intent.gd).
func _ping() -> void:
	if _ping_t > 0.0:
		return
	var pos := Vector3.INF
	if _ghost_on and aim_valid:
		pos = _xf.origin
	else:
		var cam := get_parent() as Camera3D
		if cam != null and player != null:
			var from: Vector3 = player.aim_origin()
			var dir := -cam.global_transform.basis.z
			var q := PhysicsRayQueryParameters3D.create(from, from + dir * 60.0, Game.LAYER_TERRAIN)
			var hit := get_world_3d().direct_space_state.intersect_ray(q)
			if not hit.is_empty():
				pos = hit["position"]
	if pos == Vector3.INF:
		if Game.hud:
			Game.hud.alert("İşaret için zemine nişan al", 1, "build", 1.4)
		return
	_ping_t = PING_GAP
	var who := Net.my_name if Net.active and Net.my_name != "" else "Sen"
	BuildIntent.ping(pos, str(current_entry().get("name", "Yapı")), who, true)
