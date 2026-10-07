extends RefCounted
## Weapon attachments (eklentiler; 2026-10-05, the user: "mouse'un orta tuşu ile attachment
## takabilelim silahlarımıza: tüfeklere susturucu, geri tepme azaltıcı, dürbün, refleks vb…").
## Definitions, global ownership, per-gun fitting (Kit), the stats layer, the first-person models,
## the third-person parts and the fit animation. Fitted on the move with the middle mouse button
## radial (scripts/ui/attachment_radial.gd); unlocked by crafting at the Silahlık (the armory
## panel's EKLENTİLER tab, scripts/war/craft.gd, another session) through the API below.
##
## Slots: NAMLU "muzzle" · NİŞANGAH "optic" (empty = the gun's own sight) · ALT NAMLU "under".
##   rifle, smg   muzzle + optic + under        shotgun   muzzle (susturucu / şok) + optic + under
##   sniper       muzzle (susturucu) + optic     rail      optic only        pusher / launchers: none
##   pistol, mpistol  muzzle (susturucu) + optic (refleks, on the slide)     revolver  optic (refleks) only
## The attachments (stats are multipliers, applied by the gun every shot / frame):
##   suppressor  Susturucu            ses ×0.35 (report through the low-passed WeaponsSup bus, no crack
##                                    layer / punch / outdoor tail), alev ×0.15, no muzzle light,
##                                    dikey tepme ×0.95, mermi hızı ×0.92, menzil ×0.9, nişan ×0.95
##   compensator Geri Tepme Azaltıcı  dikey tepme ×0.7, sarsıntı ×0.8, alev ×1.3 + side port flash
##   flash_hider Alev Gizleyici       alev ×0.45, ışık ×0.5, dikey tepme ×0.92
##   choke       Şok Daraltıcı        (shotgun) saçma dağılımı ×0.72, menzil ×1.2, dikey tepme ×1.05
##   reflex      Refleks              red dot, ADS zoom ×1.08 over the irons, nişan ×1.0
##   holo        Holografik           65 MOA ring + 1 MOA dot, ADS zoom ×1.15, nişan ×0.94
##                                    (both collimated: VM.reticle_lens draws the reticle at infinity
##                                    along the bore in the glass's shader; aimed, the gun comes back
##                                    until the window is OPTIC_EYE ahead of the eye, Kit.sight_z)
##   scope4      Dürbün 4×            4× (tan-space zoom, optic_scope.gd: the whole scope picture in one
##                                    shader, chevron + bullet-drop post, an eye-box shadow that slides
##                                    with recoil / sway, the scope body round the eyepiece; the view
##                                    model hides once it is opaque), nişan ×0.78, sallantı ×1.1
##   foregrip    Ön Tutamak           yatay tepme ×0.65, sallantı ×0.8, nişan ×0.97; the left hand moves
##                                    onto it (grip_left descriptor, viewmodel.gd refresh_grip)
##   laser       Lazer                belden dağılım ×0.75, nişan ×1.06, a visible beam + dot
##
## API (static; ownership is global: unlock once, fit to any compatible gun)
##   Attachments.list() -> Array[Dictionary]   one per attachment, in display order: id, name, desc,
##        slot, slot_name, cost (m³), time (s), guns (item ids), color, stats (raw multipliers),
##        stats_text ([[label, "−30 %", good: bool], ...]), owned, icon (= id, for draw_icon)
##   Attachments.def(id) -> Dictionary          the raw definition ({} when unknown)
##   Attachments.unlock(id)                     owned from now on (emits events().unlocked(id))
##   Attachments.owned(id) -> bool              FREE (the reflex) and the gun's own parts always are
##   Attachments.compatible(id, item_id) -> bool
##   Attachments.unlock_all() / reset()         training mode (Game.unlock_all_weapons) / a new match
##   Attachments.events()                       signal hub: unlocked(id), reset_done (static, like
##        WeaponDrop.events(); connect a Node's method, which is dropped when the node is freed, not a
##        capturing lambda: one that outlives its owner crashed a headless probe at exit)
##   Attachments.draw_icon(ci, id, centre, half_size, colour)   the silhouette, Control drawing
##        (id "" + slot via draw_empty_icon(ci, slot, ...): the gun's own part)
##   Attachments.slots_of(item_id) / options(item_id, slot)     what the radial lists
##   Attachments.save_data() -> Dictionary / load_data(d)       ownership, for a save system
##   Attachments.cost_of(id) / time_of(id)      the craft price (m³) / time (s): Balance.ATT_CRAFT_COST /
##        ATT_CRAFT_TIME["att_<id>"]; list() entries carry them and "recipe" ("att_<id>")
## Crafting: scripts/war/craft.gd attachment_recipes() ("att_<id>", found by Craft.recipe / owned /
##   blocked); the armory's EKLENTİLER tab (scripts/war/attachments_panel.gd) starts them, a finished
##   one is Craft.grant -> Attachments.unlock(id). Game.reset_state() resets the ownership (a new
##   match), Game.unlock_all_weapons() (training) unlocks everything.
## Per gun (rifle.gd, weapon_base.gd): `att_kit` (Kit below), get_attachments() -> {slot: id},
##   set_attachments(d), signal attachments_changed(state), attachment_text() ("Susturucu · Refleks",
##   a HUD line for the HUD session), save_state()["att"] (a dropped gun carries what it had fitted;
##   weapon_drop.gd shows it on the ground model).
## Multiplayer: Attachments.dress_tp(prop_root, item_id, state) shows the fitted parts on any
##   third-person prop of that gun (remote avatars, dropped guns); feed it the gun's
##   attachments_changed state.

const VM := preload("res://scripts/player/vm_parts.gd")
const Settings := preload("res://scripts/save/settings.gd")
const OpticScope := preload("res://scripts/items/optic_scope.gd")
const Balance := preload("res://scripts/war/balance.gd")   # ATT_CRAFT_COST / ATT_CRAFT_TIME ("att_<id>")

const SLOTS := ["muzzle", "optic", "under"]
const SLOT_NAMES := {"muzzle": "NAMLU", "optic": "NİŞANGAH", "under": "ALT NAMLU"}
## The empty slot in the radial (the gun's own part).
const EMPTY_NAMES := {"muzzle": "Standart namlu", "optic": "Kendi nişangahı", "under": "Boş"}
const EMPTY_DESC := {"muzzle": "Silahın kendi namlu ağzı.", "optic": "Silahın kendi nişangahı (gez-arpacık / dürbün).",
		"under": "Alt namluda bir şey yok."}
const GUN_SLOTS := {
	"rifle": ["muzzle", "optic", "under"],
	"smg": ["muzzle", "optic", "under"],
	"shotgun": ["muzzle", "optic", "under"],
	"sniper": ["muzzle", "optic"],
	"rail": ["optic"],
	"pistol": ["muzzle", "optic"],          # sidearms (2026-10-07): a can + a slide-mounted reflex
	"mpistol": ["muzzle", "optic"],
	"revolver": ["optic"],                  # (a revolver leaks gas at the cylinder gap: no muzzle device)
}
## Owned from the start (the dev / default set; a gun's own sight and muzzle are always there).
const FREE := ["reflex"]
const FIT_T := 0.75                      # s of the fit animation (the swap at FIT_SWAP of it)
const FIT_SWAP := 0.48
const SUP_BUS := "WeaponsSup"
## Aimed with a reflex / holo the gun comes back until the window is OPTIC_EYE m ahead of the eye
## (at most OPTIC_PULL m closer than the irons' spot): a big, MW-like sight picture on every gun.
const OPTIC_EYE := 0.17
const OPTIC_PULL := 0.075
const OCULAR_R := 0.0166                 # the 4×'s eyepiece glass radius (build_scope4)

## In display order. stats: multipliers (see the header); "zoom" for optics (×, the scope's absolute).
const DEFS := [
	{"id": "suppressor", "name": "Susturucu", "slot": "muzzle", "cost": 110.0, "time": 6.0,
		"color": Color(0.62, 0.66, 0.72), "guns": ["rifle", "smg", "shotgun", "sniper", "pistol", "mpistol"],
		"desc": "Atışı boğar: çatlama sesi ve uzun yankı gider, alev ve ışık neredeyse yok; düşman zor duyar. Mermi biraz yavaşlar.",
		"stats": {"noise": 0.35, "flash": 0.15, "light": 0.0, "climb": 0.95, "velocity": 0.92, "range": 0.9, "ads_speed": 0.95}},
	{"id": "compensator", "name": "Geri Tepme Azaltıcı", "slot": "muzzle", "cost": 80.0, "time": 5.0,
		"color": Color(1.0, 0.6, 0.25), "guns": ["rifle", "smg"],
		"desc": "Gazı yukarı ve yanlara verir: namlu daha az kalkar, kamera daha az sarsılır; yanlara büyük alev.",
		"stats": {"climb": 0.7, "shake": 0.8, "flash": 1.3}},
	{"id": "flash_hider", "name": "Alev Gizleyici", "slot": "muzzle", "cost": 50.0, "time": 4.0,
		"color": Color(0.85, 0.5, 0.3), "guns": ["rifle", "smg"],
		"desc": "Namlu alevini kırpar, gece seni ele vermez; tepmeyi de biraz yumuşatır.",
		"stats": {"flash": 0.45, "light": 0.5, "climb": 0.92}},
	{"id": "choke", "name": "Şok Daraltıcı", "slot": "muzzle", "cost": 60.0, "time": 4.0,
		"color": Color(0.95, 0.75, 0.35), "guns": ["shotgun"],
		"desc": "Pompalının namlusunu daraltır: saçma deseni sıkılaşır, daha uzağa öldürür; tepme biraz artar.",
		"stats": {"spread": 0.72, "range": 1.2, "climb": 1.05}},
	{"id": "reflex", "name": "Refleks", "slot": "optic", "cost": 70.0, "time": 4.0,
		"color": Color(1.0, 0.32, 0.25), "guns": ["rifle", "smg", "shotgun", "sniper", "rail", "pistol", "mpistol", "revolver"],
		"desc": "Açık çerçeveli kırmızı nokta: temiz, hızlı nişan, gezden biraz daha yakın.",
		"stats": {"zoom": 1.08}},
	{"id": "holo", "name": "Holografik", "slot": "optic", "cost": 90.0, "time": 5.0,
		"color": Color(1.0, 0.45, 0.22), "guns": ["rifle", "smg", "shotgun", "sniper", "rail"],
		"desc": "Halkalı holografik vizör: halka hedefi hızla toplar, biraz yakınlaştırır; nişan biraz yavaş.",
		"stats": {"zoom": 1.15, "ads_speed": 0.94}},
	{"id": "scope4", "name": "Dürbün 4×", "slot": "optic", "cost": 140.0, "time": 7.0,
		"color": Color(0.45, 0.85, 1.0), "guns": ["rifle", "smg"],
		"desc": "Dört kat prizmatik dürbün: uzak hedefler için. Nişan yavaş, sallantı artar, tam nişanda görüş merceğe daralır.",
		"stats": {"zoom": 4.0, "ads_speed": 0.78, "sway": 1.1}},
	{"id": "foregrip", "name": "Ön Tutamak", "slot": "under", "cost": 60.0, "time": 4.0,
		"color": Color(0.55, 0.95, 0.6), "guns": ["rifle", "smg", "shotgun"],
		"desc": "Dikey ön tutamak: sol el onu kavrar; namlu yana daha az kaçar, silah daha az sallanır.",
		"stats": {"horiz": 0.65, "sway": 0.8, "ads_speed": 0.97}},
	{"id": "laser", "name": "Lazer", "slot": "under", "cost": 70.0, "time": 4.0,
		"color": Color(1.0, 0.25, 0.22), "guns": ["rifle", "smg", "shotgun"],
		"desc": "Taktik lazer: belden atış toplanır, nişana daha hızlı girilir; görünür kırmızı ışın ve nokta.",
		"stats": {"hip": 0.75, "ads_speed": 1.06}},
]

## Stat labels for the UI: [label, lower is better].
const STAT_LABELS := {
	"climb": ["Dikey tepme", true], "horiz": ["Yatay tepme", true], "shake": ["Sarsıntı", true],
	"sway": ["Sallantı", true], "hip": ["Belden dağılım", true], "spread": ["Saçma dağılımı", true],
	"ads_speed": ["Nişan hızı", false], "flash": ["Namlu alevi", true], "noise": ["Ses", true],
	"velocity": ["Mermi hızı", false], "range": ["Menzil", false],
}
const STAT_ORDER := ["zoom", "noise", "climb", "horiz", "shake", "spread", "hip", "sway", "ads_speed", "flash",
		"velocity", "range"]

## Suppressed report per gun (weapon_base.gd / rifle.gd _fire_sound_sup): the report set, its level,
## pitch and cut (s), the low body, the action's clack (close, not muffled).
const SUP_SOUND := {
	"rifle": {"rep": "shot", "db": -13.0, "pitch": 0.92, "cut": 0.16, "thump": -12.0, "tpitch": 1.1, "action": -11.0, "apitch": 1.0},
	"smg": {"rep": "shot", "db": -15.0, "pitch": 1.25, "cut": 0.09, "thump": -14.0, "tpitch": 1.4, "action": -10.0, "apitch": 1.8},
	"shotgun": {"rep": "shotgun", "db": -12.0, "pitch": 0.95, "cut": 0.22, "thump": -9.0, "tpitch": 0.85, "action": -14.0, "apitch": 0.9},
	"sniper": {"rep": "heavy", "db": -11.0, "pitch": 0.8, "cut": 0.25, "thump": -8.0, "tpitch": 0.8, "action": -12.0, "apitch": 0.8},
	"pistol": {"rep": "shot", "db": -16.0, "pitch": 1.4, "cut": 0.08, "thump": -15.0, "tpitch": 1.5, "action": -11.0, "apitch": 2.1},
	"mpistol": {"rep": "shot", "db": -17.0, "pitch": 1.45, "cut": 0.065, "thump": -16.0, "tpitch": 1.55, "action": -11.0, "apitch": 2.2},
}

## Third-person mount points (prop space: grip at the origin, -Z forward), same for the player's prop,
## remote avatars and dropped guns: muzzle start + can radius / length, rail top, underbarrel.
const TP_MOUNTS := {
	"rifle": {"muzzle": Vector3(0, 0.062, -0.585), "mr": 0.019, "ml": 0.17, "rail": Vector3(0, 0.095, -0.06),
		"under": Vector3(0, 0.03, -0.3), "laser": Vector3(0, 0.03, -0.37)},
	"smg": {"muzzle": Vector3(0, 0.052, -0.296), "mr": 0.0165, "ml": 0.15, "rail": Vector3(0, 0.078, 0.03),
		"under": Vector3(0, -0.008, -0.165), "laser": Vector3(0, 0.041, -0.265)},
	"shotgun": {"muzzle": Vector3(0, 0.074, -0.607), "mr": 0.024, "ml": 0.2, "rail": Vector3(0, 0.1, -0.07),
		"under": Vector3(0, 0.009, -0.335), "laser": Vector3(0, 0.0225, -0.5)},
	"sniper": {"muzzle": Vector3(0, 0.058, -0.968), "mr": 0.024, "ml": 0.21},
	"rail": {},
	"pistol": {"muzzle": Vector3(0, 0.03, -0.158), "mr": 0.0135, "ml": 0.13, "rail": Vector3(0, 0.0466, 0.006)},
	"mpistol": {"muzzle": Vector3(0, 0.03, -0.1715), "mr": 0.0135, "ml": 0.13, "rail": Vector3(0, 0.0466, 0.006)},
	"revolver": {"rail": Vector3(0, 0.0646, -0.032)},
}

static var _owned := {}
static var _events: Events
static var _index := {}
static var _tp_mats := {}
static var radial_gun = null              # the gun whose radial is open (attachment_radial.gd); it holds fire


class Events extends RefCounted:
	signal unlocked(id: String)
	signal reset_done


# =================================================================================================
# Definitions, ownership
# =================================================================================================

static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


static func def(id: String) -> Dictionary:
	if _index.is_empty():
		for d in DEFS:
			_index[str(d["id"])] = d
	return _index.get(id, {})


## Craft price (m³) / time (s) of attachment id: Balance.ATT_CRAFT_COST / _TIME["att_<id>"] (the
## definition's own numbers as the fallback). The craft recipe is "att_<id>" (scripts/war/craft.gd).
static func cost_of(id: String) -> float:
	return float(Balance.ATT_CRAFT_COST.get("att_" + id, def(id).get("cost", 0.0)))


static func time_of(id: String) -> float:
	return float(Balance.ATT_CRAFT_TIME.get("att_" + id, def(id).get("time", 0.0)))


static func list() -> Array:
	var out: Array = []
	for d in DEFS:
		var e: Dictionary = (d as Dictionary).duplicate(true)
		var id := str(e["id"])
		e["cost"] = cost_of(id)
		e["time"] = time_of(id)
		e["recipe"] = "att_" + id
		e["slot_name"] = SLOT_NAMES.get(str(e["slot"]), "")
		e["owned"] = owned(id)
		e["stats_text"] = stats_text(id)
		e["icon"] = id
		out.append(e)
	return out


static func unlock(id: String) -> void:
	if def(id).is_empty() or _owned.has(id):
		return
	_owned[id] = true
	events().unlocked.emit(id)


static func owned(id: String) -> bool:
	return id == "" or id in FREE or _owned.has(id)


static func compatible(id: String, item_id: String) -> bool:
	if id == "":
		return true
	var d := def(id)
	return not d.is_empty() and item_id in (d["guns"] as Array) and str(d["slot"]) in (GUN_SLOTS.get(item_id, []) as Array)


static func unlock_all() -> void:
	for d in DEFS:
		unlock(str(d["id"]))


static func reset() -> void:
	_owned = {}
	events().reset_done.emit()


static func save_data() -> Dictionary:
	return {"owned": _owned.keys()}


static func load_data(d: Dictionary) -> void:
	var o = d.get("owned")
	if o is Array:
		for id in o:
			if not def(str(id)).is_empty():
				_owned[str(id)] = true


static func slots_of(item_id: String) -> Array:
	return GUN_SLOTS.get(item_id, [])


## "" (the gun's own part) first, then every compatible attachment of the slot.
static func options(item_id: String, slot: String) -> Array:
	var out: Array = [""]
	for d in DEFS:
		if str(d["slot"]) == slot and item_id in (d["guns"] as Array):
			out.append(str(d["id"]))
	return out


## The stats of an attachment as UI lines: [label, value text, good].
static func stats_text(id: String) -> Array:
	var st: Dictionary = def(id).get("stats", {})
	var out: Array = []
	for k in STAT_ORDER:
		if not st.has(k):
			continue
		var v := float(st[k])
		if k == "zoom":
			out.append(["Yakınlaştırma", ("%.2f×" % v).replace(".", ",").replace(",00×", "×").replace("0×", "×"), true])
			continue
		if not STAT_LABELS.has(k) or is_equal_approx(v, 1.0):
			continue
		var lab: Array = STAT_LABELS[k]
		var pct := int(roundf((v - 1.0) * 100.0))
		var good: bool = (pct < 0) == bool(lab[1])
		out.append([str(lab[0]), ("+%d %%" % pct) if pct > 0 else ("−%d %%" % -pct), good])
	return out


## Merged multipliers of the fitted ids.
static func merge_stats(ids: Array) -> Dictionary:
	var out := {}
	for id in ids:
		var st: Dictionary = def(str(id)).get("stats", {})
		for k in st:
			if k == "zoom":
				out[k] = float(st[k])
			else:
				out[k] = float(out.get(k, 1.0)) * float(st[k])
	return out


static func sup_sound(item_id: String) -> Dictionary:
	return SUP_SOUND.get(item_id, SUP_SOUND["rifle"])


## The suppressed guns' bus: a low-pass (the crack's top end gone) and a little low weight, into the
## Weapons bus (its compressor / room reverb / limiter; Master if that is not up yet).
static func sup_bus() -> String:
	if AudioServer.get_bus_index(SUP_BUS) >= 0:
		return SUP_BUS
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, SUP_BUS)
	AudioServer.set_bus_send(idx, "Weapons" if AudioServer.get_bus_index("Weapons") >= 0 else "Master")
	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = 1700.0
	lp.resonance = 0.55
	AudioServer.add_bus_effect(idx, lp)
	var eq := AudioEffectEQ6.new()
	eq.set_band_gain_db(0, 1.5)
	eq.set_band_gain_db(1, 2.5)
	eq.set_band_gain_db(4, -3.0)
	AudioServer.add_bus_effect(idx, eq)
	return SUP_BUS


## The radial is open on gun g: it holds fire / aim.
static func radial_on(g) -> bool:
	return radial_gun != null and is_instance_valid(radial_gun) and radial_gun == g


# =================================================================================================
# Icons (Control drawing): silhouettes for the radial and the armory tab
# =================================================================================================

## Silhouette of attachment `id` centred on c, `s` = half size (px), in colour col.
static func draw_icon(ci: CanvasItem, id: String, c: Vector2, s: float, col: Color) -> void:
	var dk := Color(col.r * 0.25, col.g * 0.25, col.b * 0.28, col.a)
	var w := maxf(1.5, s * 0.09)
	match id:
		"suppressor":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.95, -s * 0.18), Vector2(s * 0.3, s * 0.36)), col.darkened(0.25))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.68, -s * 0.3), Vector2(s * 1.55, s * 0.6)), col)
			ci.draw_rect(Rect2(c + Vector2(-s * 0.35, -s * 0.31), Vector2(s * 0.12, s * 0.62)), Color(1.0, 0.55, 0.18, col.a))
			for i in 4:
				ci.draw_line(c + Vector2(-s * 0.9 + i * s * 0.06, -s * 0.18), c + Vector2(-s * 0.9 + i * s * 0.06, s * 0.18), dk, 1.0)
			ci.draw_circle(c + Vector2(s * 0.87, 0.0), s * 0.1, dk)
		"compensator":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.95, -s * 0.12), Vector2(s * 0.6, s * 0.24)), col.darkened(0.3))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.4, -s * 0.38), Vector2(s * 1.2, s * 0.76)), col)
			for i in 3:
				ci.draw_rect(Rect2(c + Vector2(-s * 0.2 + i * s * 0.32, -s * 0.38), Vector2(s * 0.13, s * 0.3)), dk)
				ci.draw_rect(Rect2(c + Vector2(-s * 0.2 + i * s * 0.32, s * 0.12), Vector2(s * 0.13, s * 0.26)), dk)
		"flash_hider":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.95, -s * 0.12), Vector2(s * 0.6, s * 0.24)), col.darkened(0.3))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.4, -s * 0.3), Vector2(s * 0.35, s * 0.6)), col)
			for i in 4:
				var y := -s * 0.3 + i * s * 0.2
				ci.draw_rect(Rect2(c + Vector2(-s * 0.05, y), Vector2(s * 0.9, s * 0.1)), col)
		"choke":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.95, -s * 0.2), Vector2(s * 0.5, s * 0.4)), col.darkened(0.3))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.45, -s * 0.26), Vector2(s * 1.3, s * 0.52)), col)
			for i in 3:
				ci.draw_line(c + Vector2(-s * 0.3 + i * s * 0.12, -s * 0.26), c + Vector2(-s * 0.3 + i * s * 0.12, s * 0.26), dk, 1.5)
			ci.draw_rect(Rect2(c + Vector2(s * 0.25, -s * 0.27), Vector2(s * 0.12, s * 0.54)), Color(1.0, 0.55, 0.18, col.a))
		"reflex":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.85, s * 0.45), Vector2(s * 1.7, s * 0.28)), col.darkened(0.35))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.7, s * 0.15), Vector2(s * 1.2, s * 0.32)), col.darkened(0.15))
			ci.draw_arc(c + Vector2(s * 0.1, -s * 0.2), s * 0.55, 0.0, TAU, 32, col, w * 1.6, true)
			ci.draw_circle(c + Vector2(s * 0.1, -s * 0.2), s * 0.12, Color(1.0, 0.25, 0.2, col.a))
		"holo":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.9, s * 0.45), Vector2(s * 1.8, s * 0.26)), col.darkened(0.35))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.8, -s * 0.62), Vector2(s * 1.6, s * 1.1)), col, false, w * 1.6)
			ci.draw_arc(c + Vector2(0, -s * 0.07), s * 0.3, 0.0, TAU, 28, Color(1.0, 0.35, 0.2, col.a), w, true)
			ci.draw_circle(c + Vector2(0, -s * 0.07), s * 0.06, Color(1.0, 0.35, 0.2, col.a))
		"scope4":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.55, -s * 0.32), Vector2(s * 1.1, s * 0.5)), col)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(s * 0.55, -s * 0.3), c + Vector2(s * 0.98, -s * 0.48),
					c + Vector2(s * 0.98, s * 0.34), c + Vector2(s * 0.55, s * 0.16)]), col)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-s * 0.55, -s * 0.28), c + Vector2(-s * 0.95, -s * 0.36),
					c + Vector2(-s * 0.95, s * 0.22), c + Vector2(-s * 0.55, s * 0.14)]), col.darkened(0.15))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.4, s * 0.18), Vector2(s * 0.8, s * 0.32)), col.darkened(0.35))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.3, -s * 0.42), Vector2(s * 0.6, s * 0.09)), Color(1.0, 0.55, 0.18, col.a))
		"foregrip":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.55, -s * 0.9), Vector2(s * 1.1, s * 0.28)), col.darkened(0.35))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.28, -s * 0.62), Vector2(s * 0.56, s * 1.3)), col)
			for i in 4:
				ci.draw_line(c + Vector2(-s * 0.28, -s * 0.38 + i * s * 0.24), c + Vector2(s * 0.28, -s * 0.38 + i * s * 0.24), dk, 1.5)
			ci.draw_rect(Rect2(c + Vector2(-s * 0.33, s * 0.66), Vector2(s * 0.66, s * 0.22)), Color(1.0, 0.55, 0.18, col.a))
		"laser":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.9, -s * 0.32), Vector2(s * 0.95, s * 0.6)), col.darkened(0.2))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.6, -s * 0.5), Vector2(s * 0.4, s * 0.18)), col.darkened(0.45))
			ci.draw_line(c + Vector2(s * 0.08, -s * 0.02), c + Vector2(s * 0.98, -s * 0.02), Color(1.0, 0.2, 0.15, col.a), w * 1.3, true)
			ci.draw_circle(c + Vector2(s * 0.98, -s * 0.02), s * 0.1, Color(1.0, 0.3, 0.25, col.a))
		_:
			ci.draw_arc(c, s * 0.6, 0.0, TAU, 24, col, w, true)


## The empty slot's icon (the gun's own part): a plain barrel end, iron sights, a dashed rail.
static func draw_empty_icon(ci: CanvasItem, slot: String, c: Vector2, s: float, col: Color) -> void:
	var w := maxf(1.5, s * 0.09)
	match slot:
		"muzzle":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.95, -s * 0.14), Vector2(s * 1.6, s * 0.28)), col)
			ci.draw_rect(Rect2(c + Vector2(s * 0.55, -s * 0.22), Vector2(s * 0.3, s * 0.44)), col.darkened(0.2))
		"optic":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.95, s * 0.3), Vector2(s * 1.9, s * 0.2)), col.darkened(0.3))
			ci.draw_rect(Rect2(c + Vector2(-s * 0.85, -s * 0.25), Vector2(s * 0.14, s * 0.55)), col)
			ci.draw_rect(Rect2(c + Vector2(-s * 0.55, -s * 0.25), Vector2(s * 0.14, s * 0.55)), col)
			ci.draw_rect(Rect2(c + Vector2(s * 0.7, -s * 0.35), Vector2(s * 0.1, s * 0.65)), col)
		_:
			for i in 5:
				ci.draw_line(c + Vector2(-s * 0.9 + i * s * 0.4, 0.0), c + Vector2(-s * 0.72 + i * s * 0.4, 0.0), col, w, true)


# =================================================================================================
# First-person models (vm_parts primitives; each part baked on its own so the hands' solve sees it)
# =================================================================================================

static func _gm() -> ShaderMaterial:
	return VM.mat(Color(0.12, 0.13, 0.14), 0.3, 0.8)


static func _knurl() -> ShaderMaterial:
	return VM.mat(Color(0.2, 0.21, 0.23), 0.55, 0.6)


static func _black() -> ShaderMaterial:
	return VM.mat(Color(0.03, 0.03, 0.035), 0.6, 0.2)


static func _no_bake(mi: Node) -> Node:
	mi.set_meta("no_bake", true)
	return mi


## Suppressor screwed on at `at` (bore axis, its rear end), outer radius r, length L along -Z.
static func build_suppressor(parent: Node3D, at: Vector3, r: float, L: float) -> Node3D:
	var n := VM.node(parent, at)
	var gm := _gm()
	var steel := VM.metal()
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	# Rear collar (steel, knurled) and its bevel up to the can.
	VM.seg(n, Vector3(0, 0, 0.004), Vector3(0, 0, -0.03), r * 0.8, r * 0.84, steel, 20)
	for i in 5:
		VM.ring(n, Vector3(0, 0, -0.005 - i * 0.0055), Vector3.FORWARD, r * 0.855, 0.0012, _knurl())
	VM.seg(n, Vector3(0, 0, -0.03), Vector3(0, 0, -0.038), r * 0.84, r, gm, 24)
	# The can, a white sleeve over its middle with an orange band and three grip grooves.
	VM.seg(n, Vector3(0, 0, -0.038), Vector3(0, 0, -L + 0.014), r, r, gm, 24)
	VM.seg(n, Vector3(0, 0, -0.062), Vector3(0, 0, -L + 0.042), r + 0.0012, r + 0.0012, white, 24)
	VM.seg(n, Vector3(0, 0, -0.062), Vector3(0, 0, -0.07), r + 0.0016, r + 0.0016, orange, 24)
	for i in 3:
		VM.ring(n, Vector3(0, 0, -L + 0.05 + i * 0.008), Vector3.FORWARD, r + 0.0014, 0.0009, gm)
	# Front bevel, the steel end cap and the bore.
	VM.seg(n, Vector3(0, 0, -L + 0.014), Vector3(0, 0, -L + 0.004), r, r * 0.86, gm, 24)
	VM.seg(n, Vector3(0, 0, -L + 0.004), Vector3(0, 0, -L), r * 0.86, r * 0.8, steel, 24)
	VM.seg(n, Vector3(0, 0, -L - 0.0003), Vector3(0, 0, -L - 0.0007), r * 0.32, r * 0.32, _black(), 14)
	VM.ring(n, Vector3(0, 0, -L - 0.0005), Vector3.FORWARD, r * 0.44, 0.0016, steel)
	VM.bake(n)
	return n


## Compensator (ported block); returns [root, side flash node] (the flash quads use the gun's flash
## material, shown on a shot by the Kit).
static func build_compensator(parent: Node3D, at: Vector3, r: float, flash_mat: Material) -> Array:
	var n := VM.node(parent, at)
	var gm := _gm()
	var steel := VM.metal()
	var bk := _black()
	VM.seg(n, Vector3(0, 0, 0.003), Vector3(0, 0, -0.007), r * 0.6, r * 0.62, steel, 16)
	VM.soft_box(n, Vector3(0, 0, -0.032), Vector3(r * 1.55, r * 1.45, 0.052), 0.005, gm)
	VM.box(n, Vector3(0, 0, -0.009), Vector3(r * 1.6, r * 1.5, 0.004), VM.suit_orange())
	for i in 3:
		VM.box(n, Vector3(0, r * 0.725, -0.019 - i * 0.012), Vector3(r * 0.85, 0.0022, 0.0055), bk)
	for sx in [-1.0, 1.0]:
		for i in 2:
			VM.box(n, Vector3(r * 0.775 * sx, 0.0, -0.025 - i * 0.014), Vector3(0.0022, r * 0.8, 0.0065), bk)
	VM.ring(n, Vector3(0, 0, -0.058), Vector3.FORWARD, r * 0.5, 0.003, steel)
	VM.seg(n, Vector3(0, 0, -0.0583), Vector3(0, 0, -0.0587), r * 0.3, r * 0.3, bk, 12)
	var side := VM.node(n, Vector3(0, 0, -0.032))
	var q := QuadMesh.new()
	q.size = Vector2(0.11, 0.05)
	for sx in [-1.0, 1.0]:
		var mi := VM.mesh_inst(side, q, flash_mat)
		mi.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.065 * sx, 0, 0))
	side.visible = false
	VM.bake(n, [side])
	return [n, side]


static func build_flash_hider(parent: Node3D, at: Vector3, r: float) -> Node3D:
	var n := VM.node(parent, at)
	var gm := _gm()
	var steel := VM.metal()
	VM.seg(n, Vector3(0, 0, 0.003), Vector3(0, 0, -0.009), r * 0.62, r * 0.64, steel, 16)
	VM.seg(n, Vector3(0, 0, -0.009), Vector3(0, 0, -0.05), r * 0.72, r * 0.72, gm, 20)
	for k in 5:
		var a := TAU * float(k) / 5.0
		VM.box(n, Vector3(cos(a), sin(a), 0.0) * r * 0.72 + Vector3(0, 0, -0.036), Vector3(0.0028, 0.0028, 0.026), _black(),
				Basis(Vector3.BACK, a))
	VM.ring(n, Vector3(0, 0, -0.0095), Vector3.FORWARD, r * 0.74, 0.0018, VM.suit_orange())
	VM.ring(n, Vector3(0, 0, -0.05), Vector3.FORWARD, r * 0.72, 0.0016, steel)
	VM.bake(n)
	return n


static func build_choke(parent: Node3D, at: Vector3, r: float) -> Node3D:
	var n := VM.node(parent, at)
	var steel := VM.metal()
	var gm := _gm()
	VM.seg(n, Vector3(0, 0, 0.002), Vector3(0, 0, -0.062), r, r * 0.96, steel, 22)
	for i in 4:
		VM.ring(n, Vector3(0, 0, -0.006 - i * 0.005), Vector3.FORWARD, r * 1.02, 0.0012, _knurl())
	VM.ring(n, Vector3(0, 0, -0.03), Vector3.FORWARD, r * 1.03, 0.002, VM.suit_orange())
	for i in 3:
		VM.box(n, Vector3(0, r * 0.95, -0.038 - i * 0.008), Vector3(r * 0.7, 0.002, 0.004), _black())
	VM.seg(n, Vector3(0, 0, -0.062), Vector3(0, 0, -0.066), r * 0.96, r * 0.84, gm, 22)
	VM.bake(n)
	return n


## Open reflex (red dot) on a rail top at (0, y, z), its window on the sight line sy (gun frame): a
## hoop on the housing round a collimated 2 MOA dot (VM.reticle_lens: projected at infinity along the
## bore, never glued to the glass). Meta "window_z": the glass's z (the Kit's eye distance).
static func build_reflex(parent: Node3D, y: float, z: float, sy: float) -> Node3D:
	var n := VM.node(parent, Vector3(0, y, z))
	var h := sy - y
	var gm := _gm()
	var dark := VM.dark_metal()
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var steel := VM.metal()
	# Clamp base with a cross bolt; the housing (gunmetal, white top cover, orange buttons).
	VM.soft_box(n, Vector3(0, 0.005, 0.004), Vector3(0.026, 0.01, 0.046), 0.003, dark)
	VM.seg(n, Vector3(-0.013, 0.004, 0.014), Vector3(-0.0168, 0.004, 0.014), 0.0034, 0.0034, steel, 10)
	VM.soft_box(n, Vector3(0, 0.0125, 0.009), Vector3(0.028, 0.009, 0.034), 0.004, gm)
	VM.soft_box(n, Vector3(0, 0.0172, 0.013), Vector3(0.0262, 0.0036, 0.024), 0.0016, white)
	for k in 2:
		VM.box(n, Vector3(0.0146, 0.0125, 0.017 - k * 0.0095), Vector3(0.0024, 0.0042, 0.0055), orange)
	# The window hoop round the sight line (a thin tube rim), posts down to the housing, an orange trim.
	var wz := -0.011
	var rr := 0.0185
	VM.ring(n, Vector3(0, h, wz), Vector3.BACK, rr, 0.0032, gm)
	VM.ring(n, Vector3(0, h, wz + 0.0028), Vector3.BACK, rr - 0.0008, 0.001, orange)
	var post_top := h - rr * 0.68
	if post_top > 0.016:
		for sx in [-1.0, 1.0]:
			VM.box(n, Vector3(sx * rr * 0.7, (0.016 + post_top) * 0.5, wz), Vector3(0.0048, post_top - 0.016 + 0.003, 0.007), gm)
	# The collimated glass (coating, reflection, vignette and the dot all in its shader).
	VM.reticle_lens(n, Vector3(0, h, wz - 0.0004), Vector2.ONE * (rr - 0.0025), 1.0, 0, Color(1.0, 0.08, 0.04), 2.0)
	n.set_meta("window_z", z + wz)
	VM.bake(n)
	return n


## Holographic sight (EOTech-like: a hood over a rectangular window) on a rail top at (0, y, z): a
## collimated 65 MOA ring + 1 MOA dot with 3 / 6 / 9 / 12 ticks and a hologram shimmer
## (VM.reticle_lens). Meta "window_z": the glass's z (the Kit's eye distance).
static func build_holo(parent: Node3D, y: float, z: float, sy: float) -> Node3D:
	var n := VM.node(parent, Vector3(0, y, z))
	var h := sy - y
	var gm := _gm()
	var dark := VM.dark_metal()
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	VM.soft_box(n, Vector3(0, 0.005, 0.0), Vector3(0.028, 0.01, 0.07), 0.003, dark)
	VM.box(n, Vector3(-0.0155, 0.0055, 0.013), Vector3(0.003, 0.006, 0.026), orange)          # QD lever
	var wb := h - 0.0175                                                                        # window bottom
	VM.soft_box(n, Vector3(0, (0.009 + wb) * 0.5, 0.002), Vector3(0.033, maxf(wb - 0.009, 0.006), 0.064), 0.004, gm)
	for k in 2:
		# (Small brightness buttons: at the eye they read big; the old 6 mm blocks were two orange slabs.)
		VM.box(n, Vector3(-0.0075 + k * 0.015, (0.009 + wb) * 0.5 - 0.002, 0.0342), Vector3(0.0032, 0.0024, 0.0016), orange)
	# Hood: white side walls and top plate, an orange stripe.
	var wz := -0.008
	for sx in [-1.0, 1.0]:
		VM.soft_box(n, Vector3(sx * 0.0188, h + 0.001, wz), Vector3(0.005, 0.038, 0.034), 0.002, white)
	VM.soft_box(n, Vector3(0, h + 0.0195, wz), Vector3(0.0426, 0.005, 0.034), 0.002, white)
	VM.box(n, Vector3(0, h + 0.0225, wz + 0.004), Vector3(0.012, 0.0014, 0.016), orange)
	# The collimated window filling the hood's opening (between the walls, the top plate and the body).
	VM.reticle_lens(n, Vector3(0, h - 0.0002, wz - 0.004), Vector2(0.0162, 0.0171), 0.0022, 1, Color(1.0, 0.12, 0.06), 1.0, 65.0)
	n.set_meta("window_z", z + wz - 0.004)
	VM.bake(n)
	return n


## Prismatic 4× scope (ACOG-like) on a rail top at (0, y, z), its axis at sy.
static func build_scope4(parent: Node3D, y: float, z: float, sy: float) -> Node3D:
	var n := VM.node(parent, Vector3(0, y, z))
	var h := sy - y
	var gm := _gm()
	var dark := VM.dark_metal()
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var rubber := VM.rubber()
	VM.soft_box(n, Vector3(0, 0.005, 0.0), Vector3(0.026, 0.01, 0.06), 0.003, dark)
	VM.soft_box(n, Vector3(0, (0.009 + h - 0.011) * 0.5, 0.0), Vector3(0.02, maxf(h - 0.02, 0.004), 0.05), 0.003, gm)
	# Housing round the axis, a white top cover with the fibre-optic strip, a windage turret.
	VM.soft_box(n, Vector3(0, h - 0.002, 0.0), Vector3(0.03, 0.028, 0.07), 0.008, gm)
	VM.soft_box(n, Vector3(0, h + 0.0115, 0.002), Vector3(0.0245, 0.004, 0.05), 0.0018, white)
	VM.box(n, Vector3(0, h + 0.0138, 0.0), Vector3(0.005, 0.0014, 0.044), VM.glow(Color(1.0, 0.5, 0.15), 2.2))
	VM.seg(n, Vector3(0.0148, h, -0.014), Vector3(0.0235, h, -0.014), 0.0068, 0.0068, gm, 16)
	VM.seg(n, Vector3(0.0235, h, -0.014), Vector3(0.026, h, -0.014), 0.0068, 0.006, orange, 16)
	# Objective bell + sunshade (orange ring), ocular + rubber eyecup.
	VM.seg(n, Vector3(0, h, -0.035), Vector3(0, h, -0.05), 0.0155, 0.0205, gm, 24)
	VM.seg(n, Vector3(0, h, -0.05), Vector3(0, h, -0.064), 0.0205, 0.0208, gm, 24)
	VM.ring(n, Vector3(0, h, -0.05), Vector3.FORWARD, 0.0212, 0.0025, orange)
	VM.seg(n, Vector3(0, h, 0.035), Vector3(0, h, 0.048), 0.0155, 0.0175, gm, 24)
	VM.seg(n, Vector3(0, h, 0.048), Vector3(0, h, 0.062), 0.0182, 0.019, rubber, 24)
	_no_bake(VM.seg(n, Vector3(0, h, -0.0636), Vector3(0, h, -0.0646), 0.0186, 0.0186, VM.glass(Color(0.3, 0.55, 0.9, 0.35)), 24))
	_no_bake(VM.ring(n, Vector3(0, h, -0.064), Vector3.FORWARD, 0.0168, 0.0012, VM.glow(Color(0.35, 0.85, 1.0), 1.1)))
	_no_bake(VM.seg(n, Vector3(0, h, 0.0603), Vector3(0, h, 0.0613), 0.0166, 0.0166, VM.glass(Color(0.05, 0.12, 0.16, 0.55)), 24))
	# The eyepiece glass's centre: the overlay's lens matches its size on screen while aiming in.
	n.set_meta("ocular", VM.node(n, Vector3(0, h, 0.0613)))
	VM.bake(n)
	return n


## Vertical foregrip; `top` = where its clamp meets the underside (gun / pump frame).
static func build_foregrip(parent: Node3D, top: Vector3) -> Node3D:
	var n := VM.node(parent, top)
	VM.soft_box(n, Vector3(0, -0.004, 0), Vector3(0.024, 0.01, 0.038), 0.003, VM.dark_metal())
	VM.seg(n, Vector3(-0.012, -0.004, 0.009), Vector3(-0.0155, -0.004, 0.009), 0.003, 0.003, VM.metal(), 10)
	VM.seg(n, Vector3(0, -0.009, 0), Vector3(0, -0.016, 0), 0.0136, 0.0158, VM.plastic_white(), 18)
	VM.capsule(n, Vector3(0, -0.02, 0), Vector3(0, -0.078, 0.003), 0.0158, VM.rubber(), 16)
	for i in 4:
		VM.ring(n, Vector3(0, -0.03 - i * 0.013, 0.0005 + i * 0.0006), Vector3(0, 1, -0.05), 0.0164, 0.0016, VM.dark_metal())
	VM.seg(n, Vector3(0, -0.078, 0.003), Vector3(0, -0.088, 0.0035), 0.0172, 0.0166, VM.suit_orange(), 18)
	VM.bake(n)
	return n


## The left hand on a foregrip built at `top` (vm_hand.gd descriptor, the parent's frame).
static func foregrip_desc(top: Vector3) -> Dictionary:
	return {"at": top + Vector3(0, -0.019, 0.0006), "axis": Vector3(0, 1, -0.05), "palm": Vector3(-0.984, 0, 0.173), "r": 0.0158}


## Laser module hung under `top`; returns [root, emitter node].
static func build_laser(parent: Node3D, top: Vector3) -> Array:
	var n := VM.node(parent, top)
	var gm := _gm()
	VM.box(n, Vector3(0, -0.002, 0.0), Vector3(0.016, 0.004, 0.03), VM.dark_metal())
	VM.soft_box(n, Vector3(0, -0.013, 0), Vector3(0.024, 0.02, 0.05), 0.004, gm)
	VM.soft_box(n, Vector3(0, -0.0045, 0.002), Vector3(0.02, 0.004, 0.04), 0.0015, VM.plastic_white())
	VM.box(n, Vector3(-0.0125, -0.013, 0.01), Vector3(0.0025, 0.006, 0.012), VM.suit_orange())
	VM.ring(n, Vector3(-0.003, -0.013, -0.0252), Vector3.FORWARD, 0.0062, 0.0016, VM.metal())
	VM.sphere(n, Vector3(-0.003, -0.013, -0.0254), 0.0034, VM.glow(Color(1.0, 0.12, 0.08), 3.0))
	VM.seg(n, Vector3(0.0065, -0.013, -0.025), Vector3(0.0065, -0.013, -0.0256), 0.0028, 0.0028, _black(), 12)
	var em := VM.node(n, Vector3(-0.003, -0.013, -0.027))
	VM.bake(n, [em])
	return [n, em]


# =================================================================================================
# Third-person parts (StandardMaterial3D: lit like the props, cast shadows)
# =================================================================================================

static func _tpm(c: Color, rough := 0.4, metal := 0.6) -> StandardMaterial3D:
	var key := c.to_html() + "%.2f%.2f" % [rough, metal]
	if _tp_mats.has(key):
		return _tp_mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	_tp_mats[key] = m
	return m


## Builds every compatible part of gun `item_id` under prop root p (node "AttTP", hidden parts);
## returns it (already there: the old one).
static func build_tp(p: Node3D, item_id: String) -> Node3D:
	var old := p.get_node_or_null("AttTP") as Node3D
	if old != null:
		return old
	var root := Node3D.new()
	root.name = "AttTP"
	p.add_child(root)
	var m: Dictionary = TP_MOUNTS.get(item_id, {})
	var dark := _tpm(Color(0.12, 0.13, 0.14), 0.35, 0.75)
	var white := _tpm(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tpm(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var rubber := _tpm(Color(0.08, 0.08, 0.09), 0.9, 0.0)
	for id in _all_ids_for(item_id):
		var part := Node3D.new()
		part.name = id
		part.visible = false
		root.add_child(part)
		match id:
			"suppressor":
				var a: Vector3 = m["muzzle"]
				var r := float(m["mr"])
				var l := float(m["ml"])
				VM.seg(part, a, a + Vector3(0, 0, -l), r, r, dark, 14)
				VM.seg(part, a + Vector3(0, 0, -0.062), a + Vector3(0, 0, -0.07), r + 0.0015, r + 0.0015, orange, 14)
			"compensator":
				VM.box(part, (m["muzzle"] as Vector3) + Vector3(0, 0, -0.03), Vector3(0.03, 0.028, 0.058), dark)
			"flash_hider":
				var a2: Vector3 = m["muzzle"]
				VM.seg(part, a2, a2 + Vector3(0, 0, -0.05), 0.0135, 0.0135, dark, 10)
			"choke":
				var a3: Vector3 = m["muzzle"]
				VM.seg(part, a3, a3 + Vector3(0, 0, -0.064), 0.017, 0.016, _tpm(Color(0.6, 0.62, 0.66), 0.3, 0.85), 12)
			"reflex":
				var r1: Vector3 = m["rail"]
				VM.box(part, r1 + Vector3(0, 0.002, 0.005), Vector3(0.026, 0.024, 0.045), dark)
				VM.ring(part, r1 + Vector3(0, 0.03, -0.01), Vector3.BACK, 0.016, 0.004, dark)
			"holo":
				var r2: Vector3 = m["rail"]
				VM.box(part, r2 + Vector3(0, 0.008, 0.0), Vector3(0.032, 0.026, 0.066), dark)
				VM.box(part, r2 + Vector3(0, 0.03, -0.008), Vector3(0.042, 0.04, 0.034), white)
			"scope4":
				var r3: Vector3 = m["rail"]
				VM.box(part, r3 + Vector3(0, 0.008, 0.0), Vector3(0.022, 0.026, 0.05), dark)
				VM.seg(part, r3 + Vector3(0, 0.036, 0.062), r3 + Vector3(0, 0.036, -0.064), 0.017, 0.02, dark, 12)
			"foregrip":
				var u: Vector3 = m["under"]
				VM.capsule(part, u + Vector3(0, -0.02, 0), u + Vector3(0, -0.08, 0.003), 0.016, rubber, 10)
				VM.seg(part, u + Vector3(0, -0.08, 0.003), u + Vector3(0, -0.09, 0.0035), 0.017, 0.017, orange, 10)
			"laser":
				VM.box(part, (m["laser"] as Vector3) + Vector3(0, -0.012, 0), Vector3(0.024, 0.022, 0.05), dark)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return root


## Every id that has a third-person part on gun item_id (the sniper / railgun keep their own scope
## in third person: no optic parts there).
static func _all_ids_for(item_id: String) -> Array:
	var m: Dictionary = TP_MOUNTS.get(item_id, {})
	var out: Array = []
	for d in DEFS:
		var id := str(d["id"])
		if not compatible(id, item_id):
			continue
		var slot := str(d["slot"])
		if (slot == "muzzle" and m.has("muzzle")) or (slot == "optic" and m.has("rail")) \
				or (slot == "under" and m.has("under")):
			out.append(id)
	return out


## Shows the parts of `state` ({slot: id}) on a third-person prop of gun item_id (built if missing):
## the player's own prop, remote avatars' props (multiplayer), dropped guns.
static func dress_tp(p: Node3D, item_id: String, state) -> void:
	if p == null or not is_instance_valid(p) or not TP_MOUNTS.has(item_id):
		return
	var root := build_tp(p, item_id)
	var want: Array = (state as Dictionary).values() if state is Dictionary else []
	for c in root.get_children():
		(c as Node3D).visible = want.has(str(c.name))


# =================================================================================================
# Kit: one gun's fitted attachments
# =================================================================================================

class Kit extends RefCounted:
	const Attachments := preload("res://scripts/items/attachments.gd")   # (the outer statics)
	var gun = null                       # the owning gun (rifle.gd / weapon_base.gd)
	var item_id := ""
	var fitted := {}                     # slot -> attachment id
	var st := {}                         # merged stats of what is fitted (Attachments.merge_stats)
	var parts := {}                      # id -> first-person model root (shown while fitted)
	var defaults := {}                   # slot -> the gun's own part a fitted one replaces (irons, brake)
	var mounts := {}                     # slot -> the mount spec the gun gave build()
	var optic_y := {}                    # optic id -> its sight line height (gun frame)
	var optic_wz := {}                   # reflex / holo id -> its window's z (gun frame; sight_z)
	var reach_pts := {}                  # slot -> node the left hand reaches to while fitting
	var fit_t := -1.0                    # s into the fit animation (-1: none)
	var fit_slot := ""
	var fit_id := ""
	var reach_w := 0.0                   # left hand on the part being fitted (0..1)
	var _fit_w := 0.0                    # the gun turned to show the mount (0..1)
	var _swapped := false
	var _shift: Array = []               # [node, base position] pushed out by a muzzle device
	var _side_flash: Node3D
	var _emit: Node3D
	var _beam: MeshInstance3D
	var _dot: MeshInstance3D
	var _scope
	var _ocular: Node3D                  # the 4×'s eyepiece centre (build_scope4 meta)
	var _ocular_pt := Vector3.ZERO       # ... in the gun frame
	var _vm_hidden := false
	var _tp: Node3D
	var _tp_tip: Node3D
	var _tp_tip0 := Vector3.ZERO

	# --- Queries -------------------------------------------------------------------------------

	func stat(k: String, def_v := 1.0) -> float:
		return float(st.get(k, def_v))

	func state() -> Dictionary:
		return fitted.duplicate()

	func optic() -> String:
		return str(fitted.get("optic", ""))

	func muzzle_device() -> String:
		return str(fitted.get("muzzle", ""))

	func suppressed() -> bool:
		return muzzle_device() == "suppressor"

	func is_scope() -> bool:
		return optic() == "scope4"

	## The gun's slots that have a mount (what the radial shows).
	func slots() -> Array:
		var out: Array = []
		for s in Attachments.slots_of(item_id):
			if mounts.has(s):
				out.append(s)
		return out

	func has_slots() -> bool:
		return not slots().is_empty()

	func options(slot: String) -> Array:
		return Attachments.options(item_id, slot)

	func current(slot: String) -> String:
		return str(fitted.get(slot, ""))

	## Sight line height of the fitted optic (gun frame), -1 with the gun's own sight.
	func sight_y() -> float:
		return float(optic_y.get(optic(), -1.0))

	## Gun-frame z the aim pose puts at the eye's distance (rifle.gd _ads_pose, weapon_base.gd
	## sight_point): with a reflex / holo the gun comes back until the window is OPTIC_EYE ahead of
	## the eye (at most OPTIC_PULL; never pushed away); sp_z (the gun's own rear sight spot) otherwise.
	## eye_z: the aim pose's eye point (ADS_EYE.z / ads_eye.z, camera space).
	func sight_z(sp_z: float, eye_z: float) -> float:
		if not optic_wz.has(optic()):
			return sp_z
		var want := eye_z + float(optic_wz[optic()]) + Attachments.OPTIC_EYE
		return clampf(want, sp_z - Attachments.OPTIC_PULL, sp_z)

	## ADS FOV with the fitted optic: irons_fov (the gun's own) narrowed by the optic's zoom.
	func ads_fov(irons_fov: float) -> float:
		var z := stat("zoom", 1.0)
		if is_scope() or z <= 1.001:
			return irons_fov
		return rad_to_deg(2.0 * atan(tan(deg_to_rad(irons_fov) * 0.5) / z))

	## Camera FOV at aim weight e: the hip FOV to the optic's; the 4× in tan space (a mild narrowing
	## while the gun comes up, then into the zoom as it reaches the eye, like the sniper's scope).
	func cam_fov(e: float, irons_fov: float) -> float:
		var base: float = Settings.fov
		if not is_scope():
			return lerpf(base, ads_fov(irons_fov), e)
		var t1 := _sm(e / 0.6)
		var pre := base - 6.0 * t1
		var t2 := _sm((e - 0.6) / 0.4)
		var zt := tan(deg_to_rad(base) * 0.5) / maxf(stat("zoom", 4.0), 1.0)
		var pt := tan(deg_to_rad(pre) * 0.5)
		return rad_to_deg(2.0 * atan(lerpf(pt, zt, t2)))

	## Mouse-look multiplier at aim weight e (the 4× scales with the zoom).
	func cam_look(e: float, irons_fov: float) -> float:
		if not is_scope():
			return lerpf(1.0, 0.75, e)
		var f := cam_fov(e, irons_fov)
		return clampf(tan(deg_to_rad(f) * 0.5) / tan(deg_to_rad(Settings.fov) * 0.5), 0.15, 1.0)

	## Aim-in speed (the gun's ADS spring: stiffness × s², damping × s).
	func ads_speed() -> float:
		return stat("ads_speed")

	## One HUD line ("Susturucu · Refleks · Ön Tutamak"; "" with nothing fitted).
	func text() -> String:
		var names: Array = []
		for s in Attachments.SLOTS:
			var id := current(s)
			if id != "":
				names.append(str(Attachments.def(id).get("name", id)))
		return " · ".join(names)

	func busy() -> bool:
		return fit_t >= 0.0

	# --- Building (from the gun's build_model) ------------------------------------------------

	## Builds every compatible part (hidden) on the gun's mounts. spec per slot:
	##   "muzzle": {"at": Vector3 bore point where a device starts, "r": barrel radius, "tip": the
	##             default muzzle end z, "sup_r" / "sup_len": the can, "shift": [nodes to push out
	##             (the muzzle node, the flash)], "default": the gun's own brake (hidden by a device)}
	##   "optic":  {"y": rail top, "z": optic centre, "irons": the gun's sight line, "default": its
	##             own sight (hidden by an optic)}
	##   "under":  {"grip": Vector3 foregrip top, "grip_parent": node (the shotgun's pump), "laser":
	##             Vector3 laser top, "laser_parent": node}
	## root: the gun node the parts hang under (rifle / weapon_base `_gun`).
	func build(g, root: Node3D, spec: Dictionary) -> void:
		gun = g
		item_id = str(g.get("item_id"))
		mounts = spec
		parts = {}
		_shift = []
		for slot in Attachments.slots_of(item_id):
			if not spec.has(slot):
				continue
			var m: Dictionary = spec[slot]
			if m.get("default") is Node3D:
				defaults[slot] = m["default"]
			for id in Attachments.options(item_id, slot):
				if id != "":
					parts[id] = _build_part(id, root, m)
		if spec.has("muzzle"):
			for nd in (spec["muzzle"] as Dictionary).get("shift", []):
				if nd is Node3D:
					_shift.append([nd, (nd as Node3D).position])
		_apply_visuals()

	func _build_part(id: String, root: Node3D, m: Dictionary) -> Node3D:
		match id:
			"suppressor":
				var at: Vector3 = m["at"]
				reach_pts["muzzle"] = VM.node(root, at + Vector3(0, 0, -0.03))
				return Attachments.build_suppressor(root, at, float(m.get("sup_r", 0.019)), float(m.get("sup_len", 0.17)))
			"compensator":
				var r := Attachments.build_compensator(root, m["at"], float(m.get("r", 0.012)) * 1.45, gun.get("_flash_mat"))
				_side_flash = r[1]
				return r[0]
			"flash_hider":
				return Attachments.build_flash_hider(root, m["at"], float(m.get("r", 0.012)) * 1.4)
			"choke":
				return Attachments.build_choke(root, m["at"], float(m.get("r", 0.0135)) * 1.15)
			"reflex", "holo", "scope4":
				var y := float(m["y"])
				var irons := float(m.get("irons", y + 0.03))
				var sy: float
				if id == "scope4":
					sy = y + 0.0365
				else:
					sy = maxf(irons, y + (0.031 if id == "reflex" else 0.033))
				optic_y[id] = sy
				var par: Node3D = m.get("parent", root)
				if not reach_pts.has("optic"):
					reach_pts["optic"] = VM.node(par, Vector3(0, y + 0.02, float(m["z"])))
				var o: Node3D
				if id == "reflex":
					o = Attachments.build_reflex(par, y, float(m["z"]), sy)
				elif id == "holo":
					o = Attachments.build_holo(par, y, float(m["z"]), sy)
				else:
					o = Attachments.build_scope4(par, y, float(m["z"]), sy)
					_ocular = o.get_meta("ocular", null)
					if _ocular != null:
						_ocular_pt = o.position + _ocular.position
				if o.has_meta("window_z"):
					optic_wz[id] = float(o.get_meta("window_z"))
				return o
			"foregrip":
				var gp: Node3D = m.get("grip_parent", root)
				reach_pts["under"] = VM.node(gp, (m["grip"] as Vector3) + Vector3(0, -0.04, 0))
				return Attachments.build_foregrip(gp, m["grip"])
			"laser":
				var lp: Node3D = m.get("laser_parent", root)
				if not reach_pts.has("under"):
					reach_pts["under"] = VM.node(lp, (m["laser"] as Vector3) + Vector3(0, -0.015, 0))
				var r2 := Attachments.build_laser(lp, m["laser"])
				_emit = r2[1]
				return r2[0]
		return null

	## Third-person parts on the gun's prop (rifle.gd / weapon_base.gd _build_tp_prop) and its muzzle
	## tip (pushed out by a muzzle device). The new meshes join the astronaut's first-person hiding.
	func build_tp(p: Node3D, tip: Node3D, ast) -> void:
		if p == null or not Attachments.TP_MOUNTS.has(item_id):
			return
		var had := p.get_node_or_null("AttTP") != null
		_tp = Attachments.build_tp(p, item_id)
		_tp_tip = tip
		if tip != null:
			_tp_tip0 = tip.position
		if not had and ast != null:
			var list = ast.get("_meshes")
			for mi in _tp.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).layers = 2
				if list is Array:
					list.append(mi)
			if ast.has_method("set_first_person") and gun.player != null:
				ast.set_first_person(not gun.player.is_ragdolled())
		_apply_tp()

	func _apply_tp() -> void:
		if _tp == null or not is_instance_valid(_tp):
			return
		Attachments.dress_tp(_tp.get_parent(), item_id, fitted)
		if _tp_tip != null and is_instance_valid(_tp_tip):
			var m: Dictionary = Attachments.TP_MOUNTS.get(item_id, {})
			var dev := muzzle_device()
			_tp_tip.position = _tp_tip0
			if dev != "" and m.has("muzzle"):
				var l := float(m["ml"]) if dev == "suppressor" else (0.064 if dev == "choke" else 0.056)
				_tp_tip.position.z = minf(_tp_tip0.z, (m["muzzle"] as Vector3).z - l - 0.006)

	# --- Fitting -------------------------------------------------------------------------------

	## The owning gun (the guns call it from _ready / the accessors: a load_state may come before
	## build_model).
	func bind(g) -> void:
		if gun == null:
			gun = g
		if item_id == "" and g != null:
			item_id = str(g.get("item_id"))

	## Sets the whole state ({slot: id}; unknown / incompatible ids are skipped; ownership is not
	## checked: a picked-up gun keeps what it had). Emits the gun's attachments_changed.
	func set_state(d: Dictionary, emit := true) -> void:
		var nf := {}
		for slot in d:
			var id := str(d[slot])
			if id == "" or not Attachments.compatible(id, item_id):
				continue
			if str(Attachments.def(id).get("slot", "")) == str(slot):
				nf[str(slot)] = id
		if nf == fitted:
			return
		fitted = nf
		_apply(emit)

	## The radial's choice: starts the fit animation (the left hand reaches to the mount, the part
	## swaps half way with foley). False when it cannot now (reloading, already fitting, not owned).
	func fit(slot: String, id: String) -> bool:
		if busy() or gun == null or bool(gun.get("reloading")):
			return false
		if id != "" and (not Attachments.owned(id) or not Attachments.compatible(id, item_id)):
			return false
		if current(slot) == id:
			return false
		fit_slot = slot
		fit_id = id
		fit_t = 0.0
		_swapped = false
		_sfx("grip", -14.0, randf_range(0.95, 1.05))
		_sfx("cloth", -18.0, randf_range(0.9, 1.1))
		return true

	func _do_swap() -> void:
		_swapped = true
		if fit_id == "":
			fitted.erase(fit_slot)
		else:
			fitted[fit_slot] = fit_id
		_apply(true)
		match fit_slot:
			"muzzle":
				_sfx("clunk", -12.0, randf_range(1.05, 1.15))
				_sfx_later("tick", 0.07, -14.0, 1.2)
			"optic":
				_sfx("tick", -10.0, randf_range(0.95, 1.05))
				_sfx_later("tick", 0.09, -12.0, 1.15)
				_sfx_later("clunk", 0.16, -18.0, 1.3)
			_:
				_sfx("grip", -10.0, 1.1)
				_sfx_later("clunk", 0.06, -15.0, 1.2)
		if gun.get("_rk_vel") is Vector4:
			gun._rk_vel += Vector4(0.35, randf_range(-0.2, 0.2), 0.25, 0.04)

	func _apply(emit: bool) -> void:
		_apply_visuals()
		_apply_tp()
		if gun != null and gun.get("player") != null and gun.player.get("viewmodel") != null \
				and gun.player.viewmodel.has_method("refresh_grip"):
			gun.player.viewmodel.refresh_grip(gun)
		if emit and gun != null and gun.has_signal("attachments_changed"):
			gun.emit_signal("attachments_changed", state())

	## Parts shown / hidden, stats merged, the muzzle node and flash pushed out by a device, the
	## left hand's descriptor (foregrip).
	func _apply_visuals() -> void:
		st = Attachments.merge_stats(fitted.values())
		var on: Array = fitted.values()
		for id in parts:
			if parts[id] is Node3D:
				(parts[id] as Node3D).visible = on.has(id)
		for slot in defaults:
			if is_instance_valid(defaults[slot]):
				(defaults[slot] as Node3D).visible = not fitted.has(slot)
		var push := 0.0
		var dev := muzzle_device()
		if dev != "" and mounts.has("muzzle"):
			var m: Dictionary = mounts["muzzle"]
			var l := 0.0
			match dev:
				"suppressor":
					l = float(m.get("sup_len", 0.17))
				"compensator":
					l = 0.059
				"flash_hider":
					l = 0.051
				"choke":
					l = 0.066
			push = ((m["at"] as Vector3).z - l) - float(m.get("tip", (m["at"] as Vector3).z))
		for e in _shift:
			if is_instance_valid(e[0]):
				(e[0] as Node3D).position = (e[1] as Vector3) + Vector3(0, 0, push)
		if gun != null and "grip_left" in gun:
			if current("under") == "foregrip" and mounts.has("under"):
				gun.grip_left = Attachments.foregrip_desc((mounts["under"] as Dictionary)["grip"])
			else:
				gun.grip_left = null

	# --- Per frame (the gun's _process) --------------------------------------------------------

	## on: the gun is held and raised. Fit animation, the laser, the compensator's port flash, the
	## 4× overlay and the view model hiding.
	func tick(delta: float, on: bool) -> void:
		if gun == null:
			return
		if fit_t >= 0.0:
			if not on:
				if not _swapped:
					_do_swap()
				fit_t = -1.0
			else:
				fit_t += delta
				var u := fit_t / Attachments.FIT_T
				if not _swapped and u >= Attachments.FIT_SWAP:
					_do_swap()
				if u >= 1.0:
					fit_t = -1.0
		var u2 := fit_t / Attachments.FIT_T if fit_t >= 0.0 else 1.0
		_fit_w = _seg(u2, 0.0, 0.25) * (1.0 - _seg(u2, 0.7, 1.0)) if fit_t >= 0.0 else 0.0
		reach_w = _seg(u2, 0.12, 0.34) * (1.0 - _seg(u2, 0.62, 0.86)) if fit_t >= 0.0 else 0.0
		if _side_flash != null and is_instance_valid(_side_flash):
			_side_flash.visible = muzzle_device() == "compensator" and float(gun.get("_flash_t")) > 0.0
		_laser(on)
		_scope_tick(delta, on)

	## Pose hook (end of the gun's _update_pose): the gun turns to show the mount being fitted.
	func pose(p: Transform3D) -> Transform3D:
		if _fit_w <= 0.001:
			return p
		var w := _sm(_fit_w)
		var rot := Vector3(-0.1, 0.3, -0.85)
		var off := Vector3(-0.03, 0.04, 0.05)
		match fit_slot:
			"muzzle":
				rot = Vector3(0.06, 0.55, 0.35)
				off = Vector3(-0.05, 0.02, 0.13)
			"optic":
				rot = Vector3(0.15, 0.25, 0.75)
				off = Vector3(-0.04, 0.05, 0.06)
		return Transform3D(Basis.from_euler(rot * w) * p.basis, p.origin + off * w)

	## After the gun's _animate_model (and the inspect hook): the left hand reaches to the mount.
	func post() -> void:
		if reach_w <= 0.001 or gun.player == null:
			return
		var pt = reach_pts.get(fit_slot)
		if not (pt is Node3D) or not (pt as Node3D).is_inside_tree():
			return
		if reach_w > float(gun.left_reach_w):
			var cam_inv: Transform3D = gun.player.camera.global_transform.affine_inverse()
			gun.left_reach = cam_inv * (pt as Node3D).global_position + Vector3(-0.03, -0.075, 0.06)
			gun.left_reach_w = reach_w
			gun.left_reach_elbow = Vector3(-0.32, -0.82, 0.47)

	func _laser(on: bool) -> void:
		var want: bool = on and current("under") == "laser" and _emit != null and gun.player != null \
				and not bool(gun.get("reloading")) and float(gun.get("_sprint_w")) < 0.3 and not busy() \
				and not _vm_hidden
		if not want:
			if _beam != null:
				_beam.visible = false
				_dot.visible = false
			return
		if _beam == null:
			_make_laser()
		var cam: Camera3D = gun.player.camera
		var from := VM.vm_to_world(cam, _emit.global_position)
		var eye := cam.global_position
		var fwd := -cam.global_transform.basis.z
		var q := PhysicsRayQueryParameters3D.create(eye, eye + fwd * 150.0,
				Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE | Game.LAYER_PLAYER, [gun.player.get_rid()])
		var hit: Dictionary = (gun as Node3D).get_world_3d().direct_space_state.intersect_ray(q)
		var to: Vector3 = hit["position"] if not hit.is_empty() else eye + fwd * 90.0
		var d := to - from
		var len := d.length()
		if len < 0.05:
			_beam.visible = false
			_dot.visible = false
			return
		_beam.visible = true
		_beam.global_transform = Transform3D(VM.basis_y(d) * Basis.from_scale(Vector3(1.0, len, 1.0)), from + d * 0.5)
		_dot.visible = not hit.is_empty()
		if _dot.visible:
			var dist := eye.distance_to(to)
			var n: Vector3 = hit["normal"]
			_dot.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * (0.012 + dist * 0.0016)), to + n * 0.01)

	func _make_laser() -> void:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.albedo_color = Color(1.0, 0.12, 0.08, 0.3)
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0016
		cm.bottom_radius = 0.0016
		cm.height = 1.0
		cm.radial_segments = 6
		cm.rings = 1
		cm.cap_top = false
		cm.cap_bottom = false
		_beam = MeshInstance3D.new()
		_beam.mesh = cm
		_beam.material_override = m
		_beam.top_level = true
		_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(gun as Node).add_child(_beam)
		var dm := StandardMaterial3D.new()
		dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		dm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		dm.no_depth_test = false
		dm.albedo_color = Color(1.0, 0.18, 0.12, 0.95)
		var sm := SphereMesh.new()
		sm.radius = 1.0
		sm.height = 2.0
		sm.radial_segments = 10
		sm.rings = 5
		_dot = MeshInstance3D.new()
		_dot.mesh = sm
		_dot.material_override = dm
		_dot.top_level = true
		_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(gun as Node).add_child(_dot)

	## The 4× overlay (optic_scope.gd) follows the aim; once it is opaque the view model hides.
	func _scope_tick(delta: float, on: bool) -> void:
		var sc := is_scope()
		var e := clampf(float(gun.get("ads")), 0.0, 1.0)
		if sc and _scope == null:
			_scope = Attachments.OpticScope.new()
			(gun as Node).add_child(_scope)
		if _scope != null:
			_scope.k = smoothstep(0.72, 0.97, e) if (on and sc) else 0.0
			_scope.zoom = stat("zoom", 4.0)
			# Eye-box shadow (lens radii): the camera kick, plus the gun's sway off the aim pose (the
			# eyepiece's offset from the eye line and the axis's tilt: walking, recoil, landing).
			var rc = gun.get("_recoil")
			var target := Vector2.ZERO
			if rc is Vector2:
				target = Vector2((rc as Vector2).y, -(rc as Vector2).x) * 3.0
			var po = gun.get("pose_override")
			if po is Transform3D and gun.has_method("_ads_pose") and _ocular != null:
				var ap: Transform3D = gun._ads_pose()
				var d: Vector3 = (po as Transform3D) * _ocular_pt - ap * _ocular_pt
				var axis: Vector3 = (po as Transform3D).basis * Vector3.FORWARD
				target += Vector2(d.x, -d.y) * 30.0 + Vector2(axis.x, -axis.y) * 4.0
			_scope.shadow = (_scope.shadow as Vector2).lerp(target.limit_length(0.35), 1.0 - exp(-8.0 * delta))
			_scope.flash = clampf(float(gun.get("_flash_t")), 0.0, 1.0) * (0.0 if suppressed() else 1.0)
			# While aiming in, the lens takes the 3D eyepiece's size on screen (no double eyepiece).
			_scope.radius_from = -1.0
			var cam: Camera3D = gun.player.camera if gun.player != null else null
			if cam != null and _ocular != null and is_instance_valid(_ocular) and _ocular.is_inside_tree():
				var lc: Vector3 = cam.global_transform.affine_inverse() * _ocular.global_position
				if lc.z < -0.02:
					_scope.radius_from = (Attachments.OCULAR_R / -lc.z) / tan(deg_to_rad(cam.fov) * 0.5) \
							* VM.fov_scale() * 0.5
			_scope.update(delta)
		_set_vm_hidden(on and sc and _scope != null and float(_scope.k) > 0.6)

	func _set_vm_hidden(h: bool) -> void:
		if h == _vm_hidden or gun.player == null:
			return
		_vm_hidden = h
		var vm = gun.player.get("viewmodel")
		if vm == null:
			return
		if h:
			vm.visible = false
		elif not gun.player.is_ragdolled() and not (gun.player.has_method("is_dead") and gun.player.is_dead()):
			vm.visible = true

	# --- Helpers -------------------------------------------------------------------------------

	func _sfx(n: String, db: float, pitch: float) -> void:
		if Game.sfx != null and is_instance_valid(Game.sfx):
			Game.sfx.play(n, db, pitch)

	func _sfx_later(n: String, delay: float, db: float, pitch: float) -> void:
		if Game.sfx != null and is_instance_valid(Game.sfx) and Game.sfx.has_method("play_later"):
			Game.sfx.play_later(n, delay, db, pitch)

	static func _sm(x: float) -> float:
		x = clampf(x, 0.0, 1.0)
		return x * x * (3.0 - 2.0 * x)

	static func _seg(u: float, a: float, b: float) -> float:
		return _sm((u - a) / (b - a))
