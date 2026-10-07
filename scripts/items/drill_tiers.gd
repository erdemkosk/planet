extends RefCounted
## Drill upgrades (matkap yükseltmeleri, 2026-10-06): the Kazı Aracı (scripts/player/terrain_tool.gd)
## comes as Mk I; Mk II, Mk III and Mk IV are made at the Silahlık (craft.gd recipes "drill_mk2" ..
## "drill_mk4", Balance.DRILL_CRAFT_COST / DRILL_CRAFT_TIME), each needing the one before. Per match
## like the attachments: Game.reset_state() resets the tier (a new match), Game.unlock_all_weapons()
## (training) gives Mk IV.
##   Mk II   dig rate ×1.2, brush to 5.5 m, heat 115, cooling ×1.25
##   Mk III  ×1.4, 6 m, 130, ×1.5, + auto-collect (crater soil nearby credited at 35 %)
##   Mk IV   ×1.65, 6.25 m, 150, ×1.8, auto-collect 50 %, + the burst bore (hold E: a 3 m tunnel)
## (the numbers live in Balance "Drill heat and upgrades").
##
## API (static; the tier is the local player's)
##   DrillTiers.tier() -> int            0 Mk I .. 3 Mk IV
##   DrillTiers.unlock(t)                the tier is at least t from now on (events().changed(tier))
##   DrillTiers.reset() / unlock_all()   a new match / training
##   DrillTiers.stats(t) -> Dictionary   rate, radius_max, heat_max, cool, sweep, auto_share,
##                                       auto_radius, bore
##   DrillTiers.tier_name(t)             "Mk I" .. "Mk IV"
##   DrillTiers.recipe_id(t) / tier_of(recipe_id)    "drill_mk2" <-> 1 ...
##   DrillTiers.recipe_list() -> Array   the craft cards (craft.gd drill_recipes() wraps it)
##   DrillTiers.save_data() / load_data(d)
##   DrillTiers.events()                 signal hub: changed(tier) (connect a Node method)

const Balance := preload("res://scripts/war/balance.gd")

const MAX_TIER := 3
const NAMES := ["Mk I", "Mk II", "Mk III", "Mk IV"]
const RECIPES := ["", "drill_mk2", "drill_mk3", "drill_mk4"]
## Colour band each tier adds to the model (and its card / wrist accent).
const COLORS := [Color(1.0, 0.55, 0.15), Color(0.35, 0.85, 1.0), Color(1.0, 0.78, 0.3), Color(0.78, 0.5, 1.0)]
const DESC := [
	"Standart kazı aracı.",
	"Güçlendirilmiş bobinler: daha hızlı kazar, fırça büyür, daha iyi soğur.",
	"Emme ağızlı: yakındaki patlamaların ve kraterlerin saçtığı toprağı da toplar.",
	"Delici uçlu: E basılı tut, önüne 3 m'lik düz bir tünel aç. En hızlı, en serin matkap.",
]

static var _tier := 0
static var _events: Events


class Events extends RefCounted:
	signal changed(tier: int)


static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


static func tier() -> int:
	return _tier


static func tier_name(t: int) -> String:
	return NAMES[clampi(t, 0, MAX_TIER)]


static func recipe_id(t: int) -> String:
	return RECIPES[clampi(t, 0, MAX_TIER)]


## The tier a "drill_mk*" recipe makes (-1: not a drill recipe).
static func tier_of(id: String) -> int:
	var i := RECIPES.find(id)
	return i if i > 0 else -1


static func unlock(t: int) -> void:
	t = clampi(t, 0, MAX_TIER)
	if t <= _tier:
		return
	_tier = t
	events().changed.emit(_tier)


static func unlock_all() -> void:
	unlock(MAX_TIER)


static func reset() -> void:
	if _tier == 0:
		return
	_tier = 0
	events().changed.emit(_tier)


static func save_data() -> Dictionary:
	return {"tier": _tier}


static func load_data(d: Dictionary) -> void:
	unlock(int(d.get("tier", 0)))


## The numbers of tier t (Balance "Drill heat and upgrades").
static func stats(t: int) -> Dictionary:
	t = clampi(t, 0, MAX_TIER)
	return {
		"rate": float(Balance.DRILL_TIER_RATE[t]),
		"radius_max": float(Balance.DRILL_TIER_RADIUS[t]),
		"heat_max": float(Balance.DRILL_HEAT_MAX[t]),
		"cool": float(Balance.DRILL_TIER_COOL[t]),
		"sweep": float(Balance.DRILL_VENT_SWEEP[t]),
		"auto_share": float(Balance.DRILL_AUTO_SHARE[t]),
		"auto_radius": float(Balance.DRILL_AUTO_RADIUS[t]),
		"bore": t >= 3,
	}


static func cost_of(t: int) -> float:
	return float(Balance.DRILL_CRAFT_COST.get(recipe_id(t), 0.0))


static func time_of(t: int) -> float:
	return float(Balance.DRILL_CRAFT_TIME.get(recipe_id(t), 8.0))


## Card lines of tier t against the one before: [[label, value], ...].
static func stats_text(t: int) -> Array:
	var s := stats(t)
	var out: Array = [
		["Kazı hızı", "×%s" % _num(float(s["rate"]))],
		["Fırça", "%s m" % _num(float(s["radius_max"]))],
		["Isı / soğuma", "%d · ×%s" % [int(s["heat_max"]), _num(float(s["cool"]))]],
	]
	if float(s["auto_share"]) > 0.0:
		out.append(["Oto-toplama", "%%%d · %d m" % [int(roundf(float(s["auto_share"]) * 100.0)), int(s["auto_radius"])]])
	if bool(s["bore"]):
		out.append(["Delici sonda", "E · %s m" % String.num(Balance.DRILL_BORE_LEN, 0)])
	return out


## A card number with the Turkish decimal comma ("1,65"; whole numbers without decimals).
static func _num(v: float) -> String:
	return String.num(v, 2).replace(".", ",")


## One craft card per upgrade tier (Mk II .. Mk IV), in order: id ("drill_mk2"), name, key "",
## drill_tier, cost, time, thumb_id, desc, stats, color, requires ("" or the previous recipe).
static func recipe_list() -> Array:
	var out: Array = []
	for t in range(1, MAX_TIER + 1):
		out.append({"id": recipe_id(t), "name": "Matkap %s" % tier_name(t), "key": "", "drill_tier": t,
				"cost": cost_of(t), "time": time_of(t), "thumb_id": recipe_id(t), "desc": DESC[t],
				"stats": stats_text(t), "color": COLORS[t], "requires": recipe_id(t - 1) if t > 1 else ""})
	return out
