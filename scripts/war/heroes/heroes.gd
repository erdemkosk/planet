extends Node
## Kahramanlar (2026-10-07; the user: "karakterler süper güç versin, düşman takıma göktaşı yağdırmak
## gibi, hepsi farklı"): every player and bot plays a character (scripts/war/heroes/hero_data.gd) with
## one ULTIMATE and one small passive. One node "Heroes", child of the War (war.gd), on every machine;
## tunables: balance.gd "Heroes / ultimates" (HERO_*).
##
## The local player: the character picked at the loadout picker (hero_picker.gd -> Heroes.pick(id),
## applied at once while dead / riding the respawn ship, else at the next spawn). The ultimate's
## charge (0..1) fills over HERO_CHARGE_TIME × the hero's charge_k s, plus kills (combat_hud stats),
## assists (an enemy dies within HERO_ASSIST_R m), zone captures (control_points.gd) and the drill
## biting soil (a chained Dig.amount_hook). Kept through death. Ready: a priority-1 alert + a chime and
## the HUD ring (hero_hud.gd, a child of combat_hud.gd) says HAZIR.
## Key: action "hero_ult" = E (bound in game.gd _setup_input; here too if missing). Not while the build
## tool or the Mk IV drill's bore (both use E) is held, in a vehicle or with a panel open. Aimed ones
## (Topçu, Mühendis): E held shows a ring where it lands, release fires (aim at the sky = cancel).
## Passives (local player, here): Topçu × reload of the cannon you sit at, Gözcü × the scanner's
## recharge, Muhafız × the entrench cooldown (+ revive_mult for downed.gd), Kazıcı × dig strength
## (the dig hook), Avcı × the bots' hearing (noise_mult, read by cache_buffs.gd), Mühendis +1 grenade
## per spawn.
## Bots (host / single player): bot_tick(bot, dt, ctx) from ai_rival.gd's think (one-line hook, see
## PATCHES.md) registers the bot with a character (hero_ai.gd pick_hero), charges it and lets
## hero_ai.gd decide when to fire.
##
## Multiplayer (host authoritative; single player never touches it). Ultimates are claims to the host:
##   Heroes.events() -> Events
##     hero_picked(hero)                     any machine: the local player's character changed
##                                           (other machine: Heroes.net_hero(his avatar, hero))
##     ult_claimed(hero, data)               CLIENT: its player fired one (charge already spent) ->
##                                           host: Heroes.net_claim(the client's avatar, hero, data)
##     ult_started(fx_id, caster, team, hero, data)
##                                           HOST: one runs (any caster) -> client:
##                                           Heroes.net_started(fx_id, caster', team', hero, data)
##                                           (caster' = the same unit on the client: the host's
##                                           player -> his avatar, the client's avatar -> Game.player,
##                                           bots -> puppets; team' = Net.local_team(abs side))
##     ult_ended(fx_id, why)                 the owner (host; a client for his own cloak) ended one
##                                           early / on time -> other machine: Heroes.net_ended(fx_id)
##     ult_ready(hero) / charge_gained(amount, why)   local UI only
##   data (world space; planets as nodes, like MeteorShower's events: convert with Net.body_index /
##   body-local positions on the wire): "pos" Vector3, "body" planet node, "up" Vector3, "far" bool,
##   "from" Vector3 (the throw's start).
##   The world changes ride existing channels: meteors = meteor_shower.gd events, craters / cave-ins =
##   terrain ops + cave_in.gd events, damage = host hp.
## Static API (hooks for other files; all cheap, safe with no Heroes node):
##   Heroes.inst() -> Node      hero_of(unit) -> String     charge_of(unit) -> float
##   Heroes.pick(id)            local_pick (static String)  state() -> Dictionary (HUD)
##   Heroes.hidden_from(target, eye) -> bool   a cloaked unit farther than HERO_CLOAK_SEE_R from eye
##   Heroes.dome_blocks(from, to) -> Node      the dome that stops a shot from -> to (null: none)
##   Heroes.speed_mult(unit) -> float          × move speed (the cloak)
##   Heroes.revive_mult(unit) -> float         × revive speed of `unit` reviving (Muhafız)
##   Heroes.noise_mult() -> float              × the bots' hearing of the local player (Avcı)
##   Heroes.bot_tick(bot, dt, ctx)             ai_rival.gd think (host)
##   Heroes.area_hit(centre, r, dmg, impulse, team, caster, weapon)   host: enemies of `team` only

const Balance := preload("res://scripts/war/balance.gd")
const HeroData := preload("res://scripts/war/heroes/hero_data.gd")
const HeroFx := preload("res://scripts/war/heroes/hero_fx.gd")
const HeroAI := preload("res://scripts/war/heroes/hero_ai.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")
const Dig := preload("res://scripts/player/dig.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const ULTS := {
	"topcu": preload("res://scripts/war/heroes/ult_meteor.gd"),
	"gozcu": preload("res://scripts/war/heroes/ult_scan.gd"),
	"muhafiz": preload("res://scripts/war/heroes/ult_dome.gd"),
	"kazici": preload("res://scripts/war/heroes/ult_quake.gd"),
	"avci": preload("res://scripts/war/heroes/ult_cloak.gd"),
	"muhendis": preload("res://scripts/war/heroes/ult_well.gd"),
}
const GROUP := "heroes"
const ACTION := "hero_ult"
const POLL := 0.5
const AIM_DT := 1.0 / 15.0


class Events:
	extends RefCounted
	signal hero_picked(hero: String)
	signal ult_claimed(hero: String, data: Dictionary)
	signal ult_started(fx_id: int, caster: Node, team: String, hero: String, data: Dictionary)
	signal ult_ended(fx_id: int, why: String)
	signal ult_ready(hero: String)
	signal charge_gained(amount: float, why: String)


static var _events: Events
static var _inst: Node = null
## The local player's chosen character (the picker); survives matches.
static var local_pick := HeroData.DEFAULT

var hero := ""                           # the local player's character now
var charge := 0.0                        # 0..1
var aiming := false
var aim := {}                            # while aiming: {"ok", "pos", "body", "far", "dist", "hit"}
var reveal := {}                         # Gözcü's reveal for our side: {"until" ms, "team", "body"}
var pending_note := ""                   # "next spawn: X" (HUD)
var _fx := {}                            # fx_id -> ult node
var _next_fx := 1
var _bots := {}                          # instance id -> {"node", "hero", "charge", "think"}
var _remote := {}                        # instance id -> hero (the other player's avatar)
var _cloaked := {}                       # instance id -> the cloak ult node
var _alive := {}                         # instance id -> bool (death polling)
var _kills_seen := -1
var _zones := {}                         # zone key -> owner
var _poll_t := 0.0
var _hook_t := 0.0
var _aim_t := 0.0
var _dig_ms := -100000
var _hook_prev := Callable()
var _hook_mine := Callable()
var _was_dead := true
var _ready_said := false
var _deny_ms := 0
var _clock := 0.0
var _marker: MeshInstance3D


static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


static func inst() -> Node:
	if _inst != null and is_instance_valid(_inst) and _inst.is_inside_tree():
		return _inst
	return null


func _ready() -> void:
	name = "Heroes"
	add_to_group(GROUP)
	_inst = self
	hero = local_pick if HeroData.has(local_pick) else HeroData.DEFAULT
	if not InputMap.has_action(ACTION):
		InputMap.add_action(ACTION)
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_E
		InputMap.action_add_event(ACTION, ev)
	_hook_mine = _dig_amount
	_hook_check()
	if not Game.shot_fired.is_connected(_on_shot):
		Game.shot_fired.connect(_on_shot)
	HeroFx.prewarm()


func _exit_tree() -> void:
	if Dig.amount_hook == _hook_mine:
		Dig.amount_hook = _hook_prev if _hook_prev.is_valid() else Callable()
	if _inst == self:
		_inst = null
	if _marker != null and is_instance_valid(_marker):
		_marker.queue_free()
	HeroFx.clear_cache()


# =================================================================================================
# Static API
# =================================================================================================

## The picker: the local player's character from now on (at once while dead / riding the respawn
## ship / before the first spawn, else at the next spawn).
static func pick(id: String) -> void:
	if not HeroData.has(id):
		return
	var changed := id != local_pick
	local_pick = id
	if changed:
		events().hero_picked.emit(id)
	var me := inst()
	if me != null:
		me._on_pick()


static func hero_of(unit: Object) -> String:
	var me := inst()
	if me == null or unit == null or not is_instance_valid(unit):
		return ""
	if unit == Game.player:
		return me.hero
	var id := unit.get_instance_id()
	if me._bots.has(id):
		return str(me._bots[id]["hero"])
	return str(me._remote.get(id, ""))


static func charge_of(unit: Object) -> float:
	var me := inst()
	if me == null or unit == null or not is_instance_valid(unit):
		return 0.0
	if unit == Game.player:
		return me.charge
	var e = me._bots.get(unit.get_instance_id())
	return float(e["charge"]) if e is Dictionary else 0.0


## A cloaked unit farther than HERO_CLOAK_SEE_R m from `eye` cannot be seen (ai_rival.gd sight hook).
static func hidden_from(target: Object, eye: Vector3) -> bool:
	var me := inst()
	if me == null or me._cloaked.is_empty() or target == null or not is_instance_valid(target) or not (target is Node3D):
		return false
	var c = me._cloaked.get(target.get_instance_id())
	if c == null or not is_instance_valid(c):
		return false
	return (target as Node3D).global_position.distance_to(eye) > Balance.HERO_CLOAK_SEE_R


static func is_cloaked(unit: Object) -> bool:
	var me := inst()
	if me == null or unit == null or not is_instance_valid(unit):
		return false
	var c = me._cloaked.get(unit.get_instance_id())
	return c != null and is_instance_valid(c)


## The dome a shot from -> to stops on (outside in), or null. (ai_rival.gd _shoot_update hook.)
static func dome_blocks(from: Vector3, to: Vector3) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	for d in tree.get_nodes_in_group("hero_dome"):
		if is_instance_valid(d) and d.has_method("blocks") and d.blocks(from, to):
			return d
	return null


static func speed_mult(unit: Object) -> float:
	return Balance.HERO_CLOAK_SPEED if is_cloaked(unit) else 1.0


## × revive speed while `unit` revives a teammate (Muhafız's passive; downed.gd / revive.gd read it).
static func revive_mult(unit: Object) -> float:
	return Balance.HERO_MUHAFIZ_REVIVE_K if hero_of(unit) == "muhafiz" else 1.0


## × the bots' hearing of the local player's shots (Avcı's passive; cache_buffs.gd noise_mult).
static func noise_mult() -> float:
	var me := inst()
	return Balance.HERO_AVCI_NOISE_K if me != null and me.hero == "avci" else 1.0


## ai_rival.gd _think (host / single player), see PATCHES.md. ctx: "target" (Node), "visible" (bool),
## "threat" (Vector3, INF = none), "combat" (bool), "under_fire" (bool), "eye" (Vector3).
static func bot_tick(bot: Node3D, dt: float, ctx := {}) -> void:
	var me := inst()
	if me != null and not Net.is_client():
		me._bot_tick(bot, dt, ctx)


## Host: the client's player fired `hero` (data as he sent it).
static func net_claim(caster: Node3D, hr: String, data: Dictionary) -> void:
	var me := inst()
	if me == null or Net.is_client() or not ULTS.has(hr) or caster == null or not is_instance_valid(caster):
		return
	if str(ULTS[hr].prepare(me, caster, data)) != "":
		return
	me._launch(caster, Game.team_of(caster), hr, data)


## Client: the host says one runs.
static func net_started(fx_id: int, caster: Node3D, team: String, hr: String, data: Dictionary) -> void:
	var me := inst()
	if me != null and ULTS.has(hr) and not me._fx.has(fx_id):
		me._spawn(fx_id, caster, team, hr, data)


## Either machine: the other one ended fx_id.
static func net_ended(fx_id: int, why := "net") -> void:
	var me := inst()
	if me == null:
		return
	var n = me._fx.get(fx_id)
	me._fx.erase(fx_id)
	if n != null and is_instance_valid(n) and not bool(n.ended):
		n.stop_remote(why)


## The other machine's player picked `hr` (his avatar here).
static func net_hero(unit: Node, hr: String) -> void:
	var me := inst()
	if me != null and unit != null and is_instance_valid(unit) and HeroData.has(hr):
		me._remote[unit.get_instance_id()] = hr


## What the HUD shows.
static func state() -> Dictionary:
	var me := inst()
	if me == null:
		return {}
	var active := 0.0
	for id in me._fx:
		var n = me._fx[id]
		if is_instance_valid(n) and n.caster == Game.player and not bool(n.ended):
			active = maxf(active, 1.0 - float(n.t) / maxf(float(n.life), 0.01))
	return {"hero": me.hero, "charge": me.charge, "aiming": me.aiming, "aim": me.aim, "active": active,
			"note": me.pending_note, "reveal": me.reveal, "cloaked": is_cloaked(Game.player)}


## Host: damage + shove to everything of the OTHER side within r of centre (falloff), never cores;
## own side × HERO_FRIENDLY_K. caster == the local player: hit markers / kill credit (hit_feel.gd).
static func area_hit(centre: Vector3, r: float, dmg: float, impulse: float, team: String, caster: Node = null,
		weapon := "") -> int:
	if Net.is_client() or r <= 0.0:
		return 0
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return 0
	var hf = null
	if caster != null and is_instance_valid(caster) and caster == Game.player:
		var hfs = load("res://scripts/items/hit_feel.gd")
		hf = hfs.inst() if hfs != null else null
	var hits := 0
	var first := true
	for n in tree.get_nodes_in_group(Game.DAMAGEABLE):
		if not (n is Node3D) or not n.has_method("take_damage") or n.is_in_group("war_core"):
			continue
		if n.has_method("is_dead") and n.is_dead():
			continue
		var k := 1.0
		if team != "" and Game.team_of(n) == team:
			k = Balance.HERO_FRIENDLY_K
			if k <= 0.0:
				continue
		var c: Vector3 = (n as Node3D).global_position + (n as Node3D).global_transform.basis.y * 0.9
		var d := centre.distance_to(c)
		if d > r:
			continue
		var f := 1.0 - d / r
		f = f * f * 0.5 + f * 0.5
		var b := Game.dominant_body(c)
		var up := (c - b.global_position).normalized() if b != null else Vector3.UP
		var dir := ((c - centre).normalized() + up * 0.7).normalized()
		var amount := dmg * f * k
		var res := Game.damage_target(n, amount, centre, dir * impulse * f, team)
		hits += 1
		if hf != null and n != Game.player:
			hf.target_hit(n, res, amount, c, {"big": f, "quiet": not first, "weapon": weapon})
			first = false
	return hits


# =================================================================================================
# Per frame
# =================================================================================================

func my_team() -> String:
	var pl = Game.player
	return Game.team_of(pl) if pl != null and is_instance_valid(pl) else "home"


static func enemy_of(tm: String) -> String:
	return "rival" if tm == "home" else "home"


func _process(delta: float) -> void:
	_clock += delta
	_hook_t -= delta
	if _hook_t <= 0.0:
		_hook_t = 1.0
		_hook_check()
	var pl = Game.player
	var alive: bool = pl != null and is_instance_valid(pl) and not pl.is_dead()
	if alive and _was_dead:
		_on_spawn()
	_was_dead = not alive
	if Balance.HERO_ENABLED and alive and not Game.match_over and hero != "":
		var k := HeroData.charge_k(hero)
		var rate := 1.0 / maxf(Balance.HERO_CHARGE_TIME * k, 1.0)
		if Time.get_ticks_msec() - _dig_ms < 150:
			rate += Balance.HERO_CHARGE_DIG
		if Game.has_meta("training"):
			rate *= Balance.HERO_TRAINING_K
		_add_charge(rate * delta, "")
		_passives(pl, delta)
	_poll_t -= delta
	if _poll_t <= 0.0:
		_poll_t = POLL
		_poll()
	if aiming:
		_aim_tick(delta)


func _add_charge(amount: float, why: String) -> void:
	if amount <= 0.0 or hero == "":
		return
	var before := charge
	charge = minf(charge + amount, 1.0)
	if why != "" and charge > before:
		events().charge_gained.emit(charge - before, why)
	if charge >= 1.0 and not _ready_said:
		_ready_said = true
		events().ult_ready.emit(hero)
		HudLevel.alert("ULTİ HAZIR — [E] %s" % HeroData.ult_name(hero), 1, "hero_ready", 3.0, false)
		HeroFx.play2d("ready", -8.0)


func _on_spawn() -> void:
	if local_pick != hero:
		_apply_pick()
	pending_note = ""
	if hero == "muhendis" and Game.grenades < Game.grenade_max():
		Game.grenades += 1
		Game.loadout_changed.emit()


func _on_pick() -> void:
	var pl = Game.player
	var dead: bool = pl == null or not is_instance_valid(pl) or pl.is_dead()
	if dead or _clock < 3.0:
		_apply_pick()
		pending_note = ""
	elif local_pick != hero:
		pending_note = "Sonraki doğuşta: %s" % HeroData.hero_name(local_pick)
		HudLevel.alert("Karakter değişimi bir sonraki doğuşta: %s" % HeroData.hero_name(local_pick), 0, "hero_pick", 2.5)
	else:
		pending_note = ""


func _apply_pick() -> void:
	if local_pick == hero or not HeroData.has(local_pick):
		return
	if hero != "":
		charge *= Balance.HERO_SWAP_KEEP
	hero = local_pick
	_ready_said = charge >= 1.0
	_cancel_aim()


## The passives that need a hand every frame (the local player).
func _passives(pl: Node, delta: float) -> void:
	match hero:
		"topcu":
			for c in get_tree().get_nodes_in_group("war_cannon"):
				if is_instance_valid(c) and c.get("pilot") == pl:
					var r = c.get("reload_t")
					if (r is float or r is int) and float(r) > 0.0:
						c.set("reload_t", maxf(float(r) - delta * (Balance.HERO_TOPCU_RELOAD_K - 1.0), 0.0))
		"gozcu":
			var ha = pl.get("hand_action")
			var sc = ha.get("scanner") if ha != null and is_instance_valid(ha) else null
			if sc != null and is_instance_valid(sc):
				var c = sc.get("_cool")
				if (c is float or c is int) and float(c) > 0.002:
					sc.set("_cool", maxf(float(c) - delta * (Balance.HERO_GOZCU_SCANNER_K - 1.0), 0.001))
		"muhafiz":
			var en = pl.get("_entrench")
			if en != null and is_instance_valid(en):
				var cd = en.get("_cd")
				if (cd is float or cd is int) and float(cd) > 0.0:
					en.set("_cd", maxf(float(cd) - delta * (Balance.HERO_MUHAFIZ_ENTRENCH_K - 1.0), 0.0))


# --- The dig hook (charge from digging; Kazıcı's passive) ----------------------------------------

func _hook_check() -> void:
	if Dig.amount_hook == _hook_mine:
		return
	_hook_prev = Dig.amount_hook
	Dig.amount_hook = _hook_mine


func _dig_amount(point: Vector3, mode: int, amount: float, plane_point: Vector3, tm: String) -> float:
	var a := amount
	if _hook_prev.is_valid():
		a = float(_hook_prev.call(point, mode, amount, plane_point, tm))
	if mode != Dig.MODE_DIG or tm == "":
		return a
	var p = Game.player
	if p == null or not is_instance_valid(p) or not plane_point.is_equal_approx((p as Node3D).global_position):
		return a
	_dig_ms = Time.get_ticks_msec()
	if hero == "kazici":
		a *= Balance.HERO_KAZICI_DIG_K
	return a


# --- Polling: kills, deaths (assists), zone captures ----------------------------------------------

func units() -> Array:
	var out: Array = []
	var pl = Game.player
	if pl != null and is_instance_valid(pl):
		out.append(pl)
	for g in ["war_ai", "net_player"]:
		for n in get_tree().get_nodes_in_group(g):
			if n is Node3D and n.has_method("is_dead") and not out.has(n) and not n.is_in_group("training_dummy"):
				out.append(n)
	return out


func _poll() -> void:
	if not Balance.HERO_ENABLED:
		return
	var killed_now := false
	var st = _combat_stats()
	if st is Dictionary:
		var kills := int((st as Dictionary).get("kills", 0))
		if _kills_seen < 0 or kills < _kills_seen:
			_kills_seen = kills
		elif kills > _kills_seen:
			if not Game.match_over:
				_add_charge(Balance.HERO_CHARGE_KILL * float(kills - _kills_seen), "kill")
			_kills_seen = kills
			killed_now = true
	var seen := {}
	for n in units():
		var id: int = n.get_instance_id()
		var dead: bool = n.is_dead()
		seen[id] = not dead
		if _alive.get(id, false) and dead:
			_on_death(n, killed_now)
	_alive = seen
	_poll_zones()
	# Forget freed bots.
	for id in _bots.keys():
		if not is_instance_valid(_bots[id]["node"]):
			_bots.erase(id)


func _combat_stats():
	var hfs = load("res://scripts/items/hit_feel.gd")
	var hf = hfs.inst() if hfs != null else null
	if hf == null or not is_instance_valid(hf):
		return null
	var h = hf.get("hud")
	return h.get("stats") if h != null and is_instance_valid(h) else null


func _on_death(victim: Node3D, killed_now: bool) -> void:
	if Game.match_over:
		return
	var vt := Game.team_of(victim)
	var vp := victim.global_position
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and victim != pl and not pl.is_dead() and not killed_now \
			and vt != my_team() and (pl as Node3D).global_position.distance_to(vp) < Balance.HERO_ASSIST_R:
		_add_charge(Balance.HERO_CHARGE_ASSIST, "assist")
	if Net.is_client():
		return
	for id in _bots:
		var e: Dictionary = _bots[id]
		var b = e["node"]
		if not is_instance_valid(b) or b == victim or b.is_dead() or Game.team_of(b) == vt:
			continue
		if (b as Node3D).global_position.distance_to(vp) < Balance.HERO_ASSIST_R:
			e["charge"] = minf(float(e["charge"]) + Balance.HERO_CHARGE_ASSIST, 1.0)


func _poll_zones() -> void:
	var cp := get_tree().get_first_node_in_group("control_points")
	if cp == null:
		return
	var zs = cp.get("zones")
	if not (zs is Array):
		return
	for z in zs:
		if not (z is Dictionary):
			continue
		var key := "%s|%s" % [str(z.get("preset", "")), str(z.get("i", ""))]
		var own := str(z.get("owner", ""))
		var old = _zones.get(key)
		_zones[key] = own
		if old == null or own == "" or own == str(old) or Game.match_over:
			continue
		var body = z.get("body")
		if body == null or not is_instance_valid(body) or not cp.has_method("zone_at"):
			continue
		var pl = Game.player
		if pl != null and is_instance_valid(pl) and not pl.is_dead() and my_team() == own and _in_zone(cp, body, z, pl):
			_add_charge(Balance.HERO_CHARGE_CAPTURE, "capture")
		if not Net.is_client():
			for id in _bots:
				var e: Dictionary = _bots[id]
				var b = e["node"]
				if is_instance_valid(b) and not b.is_dead() and Game.team_of(b) == own and _in_zone(cp, body, z, b):
					e["charge"] = minf(float(e["charge"]) + Balance.HERO_CHARGE_CAPTURE, 1.0)


func _in_zone(cp: Node, body: Node3D, z: Dictionary, unit: Node3D) -> bool:
	var at = cp.zone_at(body, unit.global_position)
	return at is Dictionary and not (at as Dictionary).is_empty() and at.get("i") == z.get("i") \
			and at.get("body") == body


# =================================================================================================
# Input and firing (the local player)
# =================================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not InputMap.has_action(ACTION) or not event.is_action_pressed(ACTION) or event.is_echo():
		return
	if _try_begin():
		get_viewport().set_input_as_handled()


## Whether E is ours right now (the build tool and the Mk IV bore keep it while held).
func _key_free(pl: Node) -> bool:
	if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.get("vehicle") != null:
		return false
	if Game.ui_panel_open() or Game.match_over or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return false
	if pl.has_method("is_ragdolled") and pl.is_ragdolled():
		return false
	var it = pl.current() if pl.has_method("current") else null
	if it != null:
		var id := str(it.get("item_id"))
		if id == "build":
			return false
		if id == "terrain":
			var st = it.get("_stats")
			if st is Dictionary and bool((st as Dictionary).get("bore", false)):
				return false
	return true


func _try_begin() -> bool:
	if not Balance.HERO_ENABLED or hero == "" or aiming:
		return false
	var pl = Game.player
	if not _key_free(pl):
		return false
	if charge < 1.0:
		var now := Time.get_ticks_msec()
		if now - _deny_ms > 900:
			_deny_ms = now
			HudLevel.alert("%s dolmadı — %%%d" % [HeroData.ult_name(hero), int(charge * 100.0)], 0, "hero_deny", 1.2)
			HeroFx.play2d("deny", -14.0)
		return true
	for id in _fx:
		var n = _fx[id]
		if is_instance_valid(n) and n.caster == pl and n.hero == hero and not bool(n.ended):
			return true                    # (still running: the cloak, the dome)
	if HeroData.aims(hero):
		aiming = true
		aim = {}
		_aim_t = 0.0
		_aim_tick(0.0)
		return true
	_fire_local({})
	return true


func _aim_tick(delta: float) -> void:
	var pl = Game.player
	if not _key_free(pl):
		_cancel_aim()
		return
	if not Input.is_action_pressed(ACTION):
		var a := aim
		_cancel_aim()
		if bool(a.get("ok", false)):
			_fire_local({"pos": a["pos"], "body": a["body"], "far": bool(a.get("far", false))})
		else:
			HudLevel.alert("Hedef yok — iptal (menzil %d m)" % int(_aim_range(bool(a.get("far", false)))), 0, "hero_aim", 1.5)
			HeroFx.play2d("deny", -14.0)
		return
	_aim_t -= delta
	if _aim_t <= 0.0:
		_aim_t = AIM_DT
		aim = _aim_ray(pl)
	_update_marker()


func _aim_range(far: bool) -> float:
	if hero == "topcu" and far:
		return Balance.HERO_METEOR_RANGE_FAR
	return HeroData.range_of(hero)


## Where the aim ray meets the ground (both planets; density, no physics).
func _aim_ray(pl: Node) -> Dictionary:
	var cam: Camera3D = pl.get("camera")
	if cam == null:
		return {}
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	var reach := HeroData.range_of(hero)
	if hero == "topcu":
		reach = maxf(reach, Balance.HERO_METEOR_RANGE_FAR)
	var h := Ballistics.segment_hit(from, from + dir * reach)
	if h.is_empty() or not (h.get("body") is Node3D) or not h["body"].has_method("crater"):
		return {"ok": false, "hit": false}
	var body: Node3D = h["body"]
	var pos: Vector3 = h["position"]
	var d := from.distance_to(pos)
	var own := Game.dominant_body((pl as Node3D).global_position)
	var far := body != own
	var ok := d <= HeroData.range_of(hero) or (far and hero == "topcu" and d <= Balance.HERO_METEOR_RANGE_FAR)
	return {"ok": ok, "hit": true, "pos": pos, "body": body, "far": far, "dist": d}


func _update_marker() -> void:
	if not bool(aim.get("hit", false)):
		if _marker != null and is_instance_valid(_marker):
			_marker.visible = false
		return
	var r := Balance.HERO_METEOR_SPREAD_FAR if bool(aim.get("far", false)) else Balance.HERO_METEOR_SPREAD
	if hero == "muhendis":
		r = Balance.HERO_WELL_R
	var col: Color = HeroData.color(hero) if bool(aim.get("ok", false)) else Color(0.5, 0.55, 0.6)
	if _marker == null or not is_instance_valid(_marker):
		_marker = HeroFx.ring(self, col, 1.0)
		_marker.top_level = true
	_marker.visible = true
	var m := _marker.material_override as ShaderMaterial
	m.set_shader_parameter("col", col)
	m.set_shader_parameter("danger", 1.0 if hero == "topcu" else 0.0)
	var body: Node3D = aim["body"]
	var pos: Vector3 = aim["pos"]
	HeroFx.place(_marker, pos, (pos - body.global_position).normalized(), 0.3)
	_marker.scale = Vector3(r, 1.0, r)


func _cancel_aim() -> void:
	aiming = false
	if _marker != null and is_instance_valid(_marker):
		_marker.visible = false


func _fire_local(data: Dictionary) -> void:
	var pl = Game.player
	var why := str(ULTS[hero].prepare(self, pl, data))
	if why != "":
		HudLevel.alert(why, 1, "hero_deny", 2.0)
		HeroFx.play2d("deny", -10.0)
		return
	charge = 0.0
	_ready_said = false
	if Net.is_client():
		events().ult_claimed.emit(hero, data)
		return
	_launch(pl, my_team(), hero, data)


# =================================================================================================
# Running ultimates
# =================================================================================================

func _launch(caster: Node3D, tm: String, hr: String, data: Dictionary) -> int:
	var id := _next_fx
	_next_fx += 1
	_spawn(id, caster, tm, hr, data)
	events().ult_started.emit(id, caster, tm, hr, data)
	return id


func _spawn(id: int, caster: Node3D, tm: String, hr: String, data: Dictionary) -> void:
	var n: Node = ULTS[hr].new()
	n.setup(self, id, caster, tm, hr, data)
	_fx[id] = n
	add_child(n)


## The owner ended one (ult_base.gd finish).
func announce_end(fx_id: int, why: String) -> void:
	_fx.erase(fx_id)
	events().ult_ended.emit(fx_id, why)


## The cloak registers its caster (null: it ended).
func set_cloak(unit: Node, node: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var id := unit.get_instance_id()
	if node == null:
		_cloaked.erase(id)
	else:
		_cloaked[id] = node


## A shot fired by a cloaked unit (its side, from where it stands) ends its cloak.
func _on_shot(from: Vector3, _dir: Vector3, tm: String) -> void:
	if _cloaked.is_empty():
		return
	for id in _cloaked.keys():
		var c = _cloaked[id]
		if c == null or not is_instance_valid(c) or bool(c.ended):
			_cloaked.erase(id)
			continue
		if tm != "" and tm != str(c.team):
			continue
		var u = c.caster
		if u != null and is_instance_valid(u) and (u as Node3D).global_position.distance_to(from) < 2.4:
			c.finish("fired")


# --- Bots ------------------------------------------------------------------------------------------

func _bot_tick(bot: Node3D, dt: float, ctx: Dictionary) -> void:
	if not Balance.HERO_ENABLED or bot == null or not is_instance_valid(bot):
		return
	var id := bot.get_instance_id()
	var e = _bots.get(id)
	if e == null:
		e = {"node": bot, "hero": HeroAI.pick_hero(bot), "charge": randf() * 0.35, "think": randf() * Balance.HERO_BOT_THINK}
		_bots[id] = e
	if Game.match_over or (bot.has_method("is_dead") and bot.is_dead()):
		return
	var hr := str(e["hero"])
	var rate := 1.0 / maxf(Balance.HERO_CHARGE_TIME * HeroData.charge_k(hr), 1.0) * Balance.HERO_BOT_CHARGE_K
	e["charge"] = minf(float(e["charge"]) + rate * dt, 1.0)
	e["think"] = float(e["think"]) - dt
	if float(e["charge"]) < 1.0 or float(e["think"]) > 0.0 or _clock < Balance.HERO_BOT_FIRST:
		return
	e["think"] = Balance.HERO_BOT_THINK
	for fid in _fx:
		var n = _fx[fid]
		if is_instance_valid(n) and n.caster == bot and not bool(n.ended):
			return
	var data: Dictionary = HeroAI.decide(self, bot, hr, ctx)
	if data.is_empty():
		return
	if str(ULTS[hr].prepare(self, bot, data)) != "":
		return
	e["charge"] = 0.0
	_launch(bot, Game.team_of(bot), hr, data)


## Bot entries (tests / debug): instance id -> {"node", "hero", "charge", "think"}.
func bots() -> Dictionary:
	return _bots


## Debug / tests / the training panel: fire `hr` for `caster` now (host), skipping the charge.
func debug_fire(caster: Node3D, hr: String, data := {}) -> int:
	if Net.is_client() or not ULTS.has(hr) or caster == null:
		return -1
	if str(ULTS[hr].prepare(self, caster, data)) != "":
		return -1
	return _launch(caster, Game.team_of(caster), hr, data)


func running() -> Dictionary:
	return _fx
