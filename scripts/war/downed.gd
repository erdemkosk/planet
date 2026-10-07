extends Node
## Downed / revive / drag (2026-10-07, the user: "ölünce takım arkadaşı yerde canlandırabilsin; pes
## edebilelim; yerdeki sürüklenebilsin; vazgeçmediyse kaldırabiliriz"). The per-unit state machine,
## static: one registry for every unit that can go down, one ticker node (an instance of this script
## under the tree root, made on first use) that runs the bleed-outs, the revives, the drags and the
## pose of the downed bodies it drives.
##
## Units ("kinds"): "player" (Game.player, scripts/player/player.gd: its view is
## scripts/player/downed_view.gd), "remote" (the other player's avatar, scripts/net/remote_avatar.gd,
## group "net_player"), "bot" (scripts/war/ai_rival.gd, rival and ally bots: their "Downed / revive"
## section), "other" (a multiplayer mirror such as a client's bot puppet: pose only).
##
## States: ALIVE -> DOWN (try_down at a lethal, non-overkill hit) -> either
##   REVIVED   a teammate held the revive DN_REVIVE_TIME s: up at DN_REVIVE_HP × hp_max after a
##             DN_GETUP_TIME get-up (is_rising) and a short stagger (speed_cap)
##   CONFIRMED bled out (bleed-out at 0), gave up (gave_up: Space held DN_GIVEUP_HOLD s) or finished
##             (hurt_downed drained it): events().confirmed, then _enter_respawn() = the owner's
##             normal death (ragdoll from the lying pose, corpse, respawn flow)
## A downed unit is NOT dead: is_dead() stays false (the respawn waves may count it as 0.5 with
## is_downed()). It counts as dead from the moment `confirmed` fires (its owner's _die runs right
## after, in the same call).
##
## Overkill (no down, the old death): a single hit >= DN_OVERKILL_HIT, damage beyond the hp left >=
## DN_OVERKILL_EXCESS, a head hit >= DN_HEAD_KILL, a shove >= DN_OVERKILL_IMPULSE m/s, more than
## DN_SPACE_ALT m above the ground, in a vehicle / aboard, or force_kill set by the caller.
##
## Static API
##   is_downed(unit) -> bool              cheap, safe for any value (null / freed -> false)
##   is_rising(unit) -> bool              the get-up after a revive (not downed, not in control yet)
##   try_down(unit, amount, from_pos, impulse, hp_before = -1) -> bool
##                                        the owner's take_damage at a lethal hit (host / single
##                                        player): true = it went down instead of dying
##   hurt_downed(unit, amount, from_pos, impulse) -> Dictionary   take_damage on a downed unit:
##                                        {"dmg", "killed"} (killed = finished: confirmed)
##   gave_up(unit) / bled_out(unit) / finish(unit, by = null)     confirm the death now
##   revive(unit, by)                     up now (the revive completed)
##   begin_revive(unit, by, auto) / hold_revive(unit, by) / stop_revive(unit, by)
##                                        a reviver starts / keeps (players: every frame while F is
##                                        held; auto = bots and host-side claims, held until stopped) /
##                                        lets go; revive_progress(unit) 0..1, reviver_of(unit)
##   begin_drag(unit, by) / stop_drag(unit) / dragger_of(unit) / dragged_by(by)
##   drag_point(unit) -> Vector3          where the dragged body is pulled toward (the strap in hand)
##   speed_cap(unit) -> float             m/s cap for a player (dragging / staggering; INF = none)
##   bleed_left(unit), bleed_frac(unit), giveup_frac(unit), state_of(unit), units()
##   aim_point(unit)                      the lying chest (bots aim there)
##   target_ok(unit, shooter) -> bool     may an enemy bot keep shooting this downed unit (finisher)
##   pose_step(unit, delta, speed = -1)   drive the downed pose of `unit.astronaut` (bots / mirrors)
##   crawl_goal(unit) -> Vector3          a bot's crawl target (INF = lie still)
##   net_apply(unit, what, data = {})     multiplayer: apply the host's decision on a machine without
##                                        authority ("down", "revive", "dead", "drag", "undrag",
##                                        "bleed", "revive_start", "revive_stop")
##   host_claim(what, unit, by)           multiplayer host: a client's claim ("revive_start",
##                                        "revive_stop", "drag_start", "drag_stop", "give_up")
##   force_kill                           one-shot: the next lethal hit kills outright
##
## Events (events(), host / single player unless noted; the multiplayer layer syncs them):
##   downed(unit, info)          info: {"bleed", "by", "by_team", "pos", "kind"}
##   revived(unit, by)
##   confirmed(unit, cause, info)  cause "bled_out" / "gave_up" / "finished"; info {"by", "by_team"}
##   revive_started(unit, by) / revive_stopped(unit, by)
##   drag_started(unit, by) / drag_stopped(unit, by)
##   claim(what, unit)           a CLIENT's request to the host (its own revive / drag / give up)
##   bleed(unit, left)           ~1 Hz while down (host: for the client's bar)

const Balance := preload("res://scripts/war/balance.gd")
const Pose := preload("res://scripts/war/downed_pose.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")
const VIEW_PATH := "res://scripts/player/downed_view.gd"   # (load()ed at use: it preloads this script)
const REVIVE_PATH := "res://scripts/war/revive.gd"         # (load()ed at use: it preloads this script)
const HIT_FEEL_PATH := "res://scripts/items/hit_feel.gd"

const KIND_PLAYER := "player"
const KIND_REMOTE := "remote"
const KIND_BOT := "bot"
const KIND_OTHER := "other"
const COLLAPSE_TIME := 0.45            # s the body takes to fold down into the downed pose
const AREA_META := "dn_revive_area"
## A hit capsule (axis = its local Y) lying along a downed body (unit space): bots' and avatars'
## hit capsules take this transform and LYING_CAP_H while down.
const LYING_CAP_XF := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 0.28, 0.25))
const LYING_CAP_H := 1.7
## Multiplayer client: a lethal hurt from the host without its verdict yet lies down provisionally
## this long, then dies (an older host that never sends one).
const PROVISIONAL_MS := 700


class Events:
	extends RefCounted
	signal downed(unit: Node, info: Dictionary)
	signal revived(unit: Node, by: Node)
	signal confirmed(unit: Node, cause: String, info: Dictionary)
	signal revive_started(unit: Node, by: Node)
	signal revive_stopped(unit: Node, by: Node)
	signal drag_started(unit: Node, by: Node)
	signal drag_stopped(unit: Node, by: Node)
	signal claim(what: String, unit: Node)
	signal bleed(unit: Node, left: float)


## One downed unit.
class State:
	extends RefCounted
	var unit: Node
	var kind := ""
	var team := ""
	var mirror := false                # no authority here (multiplayer client): never confirms / revives
	var bleed := 0.0
	var bleed_max := 1.0
	var since := 0.0                   # s down
	var by_name := ""                  # who put it down (feed / credit)
	var by_team := ""
	var by_node: WeakRef = null
	var cause_pos := Vector3.INF
	var last_hit_ms := -100000
	var reviver: Node = null
	var revive_t := 0.0
	var revive_auto := false           # held until stopped (bots, host-side claims)
	var revive_hold_ms := -100000      # players: held while this is fresh
	var reviver_hp := -1.0             # the reviver's hp at the start (a big hit breaks the revive)
	var dragger: Node = null
	var medic: Node = null             # the bot on its way (revive.gd)
	var medic_roll := true
	var finisher: Node = null          # the one enemy bot that may keep shooting it
	var giveup_t := 0.0                # the local player's Space hold (s)
	var provisional_ms := -1           # client: down without the host's verdict yet (dies after this)
	var hit_k := 0.0                   # 1 on a hit, fades (the view's flash)
	var sync_t := 0.0
	# Pose.
	var ph := 0.0
	var move := 0.0
	var drag_k := 0.0
	var pose_t := 0.0
	var fold := 0.0                    # 0..1 collapse blend
	var from: Dictionary = {}
	var last_pos := Vector3.INF
	var crawled := 0.0                 # m a bot crawled so far
	var area: Area3D = null
	var hidden_areas: Array = []       # [Area3D, layer] the unit's own interact areas switched off meanwhile
	var extra: Dictionary = {}         # the owner's own bits (downed_view.gd keeps its view state here)


## The revive / drag target on a downed teammate: player.gd's interact ray finds it (layer INTERACT,
## interact(p) on F, get_interact_prompt()); revive.gd does the rest.
class ReviveArea:
	extends Area3D
	var unit: Node

	func interact(p) -> void:
		var rv = load(REVIVE_PATH)
		if rv != null:
			rv.on_interact(p, unit)

	func get_interact_prompt() -> String:
		var rv = load(REVIVE_PATH)
		return rv.prompt(unit) if rv != null else ""


static var _events: Events
static var _st := {}                   # unit instance id -> State
static var _rise := {}                 # unit instance id -> {"unit", "t", "from", "kind"}
static var _stagger := {}              # unit instance id -> msec the stagger ends
static var _downs := {}                # unit instance id -> downs since its last death
static var _ticker: Node = null
static var _rv_script = null
## One-shot: the next lethal hit kills outright (set it right before the damage: a fall into the core,
## a fling into space).
static var force_kill := false


static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


# =================================================================================================
# Queries
# =================================================================================================

## Down right now (not dead, not up). Safe for anything; no allocation.
static func is_downed(unit) -> bool:
	if _st.is_empty() or not is_instance_valid(unit):
		return false
	return _st.has((unit as Object).get_instance_id())


## Anyone down or getting up at all (cheap: the HUD's per-frame gate).
static func any() -> bool:
	return not _st.is_empty() or not _rise.is_empty()


## Getting up after a revive (no control yet; not downed).
static func is_rising(unit) -> bool:
	if _rise.is_empty() or not is_instance_valid(unit):
		return false
	return _rise.has((unit as Object).get_instance_id())


static func state_of(unit) -> State:
	if _st.is_empty() or not is_instance_valid(unit):
		return null
	return _st.get((unit as Object).get_instance_id(), null)


## Every downed unit (valid ones).
static func units() -> Array:
	var out: Array = []
	for id in _st:
		var st: State = _st[id]
		if is_instance_valid(st.unit):
			out.append(st.unit)
	return out


static func bleed_left(unit) -> float:
	var st := state_of(unit)
	return st.bleed if st != null else 0.0


static func bleed_frac(unit) -> float:
	var st := state_of(unit)
	return clampf(st.bleed / maxf(st.bleed_max, 0.01), 0.0, 1.0) if st != null else 0.0


static func giveup_frac(unit) -> float:
	var st := state_of(unit)
	return clampf(st.giveup_t / maxf(Balance.DN_GIVEUP_HOLD, 0.05), 0.0, 1.0) if st != null else 0.0


static func revive_progress(unit) -> float:
	var st := state_of(unit)
	return clampf(st.revive_t / maxf(Balance.DN_REVIVE_TIME, 0.05), 0.0, 1.0) if st != null else 0.0


static func reviver_of(unit) -> Node:
	var st := state_of(unit)
	return st.reviver if st != null and is_instance_valid(st.reviver) else null


static func dragger_of(unit) -> Node:
	var st := state_of(unit)
	return st.dragger if st != null and is_instance_valid(st.dragger) else null


## The unit `by` is dragging (null: none).
static func dragged_by(by) -> Node:
	if _st.is_empty() or not is_instance_valid(by):
		return null
	for id in _st:
		var st: State = _st[id]
		if st.dragger == by and is_instance_valid(st.unit):
			return st.unit
	return null


## The unit `by` is reviving (null: none).
static func reviving_by(by) -> Node:
	if _st.is_empty() or not is_instance_valid(by):
		return null
	for id in _st:
		var st: State = _st[id]
		if st.reviver == by and is_instance_valid(st.unit):
			return st.unit
	return null


static func kind_of(unit) -> String:
	if not is_instance_valid(unit):
		return ""
	if unit == Game.player:
		return KIND_PLAYER
	var n := unit as Node
	if n.is_in_group("net_player"):
		return KIND_REMOTE
	if n.is_in_group("war_ai") and n.has_method("pod_phase"):
		return KIND_BOT
	return KIND_OTHER


## m/s cap of a player's walk (player.gd _move_gravity): dragging someone, or staggering after a
## revive. INF = none.
static func speed_cap(unit) -> float:
	var cap := INF
	if not _stagger.is_empty() and is_instance_valid(unit):
		var id := (unit as Object).get_instance_id()
		if _stagger.has(id):
			if Time.get_ticks_msec() < int(_stagger[id]):
				cap = Balance.DN_STAGGER_SPEED
			else:
				_stagger.erase(id)
	if dragged_by(unit) != null:
		cap = minf(cap, Balance.DN_DRAG_SPEED)
	return cap


## Where bots aim at a downed unit: the lying chest.
static func aim_point(unit) -> Vector3:
	var n := unit as Node3D
	if n == null:
		return Vector3.ZERO
	var a = n.get("astronaut")
	if a != null and is_instance_valid(a) and a.chest != null:
		return (a.chest as Node3D).global_position
	return n.global_position + n.global_transform.basis.y * 0.25


## May enemy bot `shooter` keep shooting downed `unit`? Only its one finisher (rolled at the down).
static func target_ok(unit, shooter) -> bool:
	var st := state_of(unit)
	if st == null:
		return true
	return st.finisher != null and st.finisher == shooter


# =================================================================================================
# Going down
# =================================================================================================

## The owner's take_damage at a lethal hit (host / single player; a client never decides). True =
## the unit is down now (the owner keeps it alive: hp 0, not dead). hp_before: its hp before this
## hit (-1 unknown: the excess rule is skipped).
static func try_down(unit, amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO, hp_before := -1.0) -> bool:
	if not Balance.DN_ENABLED or not is_instance_valid(unit) or Net.is_client():
		force_kill = false
		return false
	if force_kill:
		force_kill = false
		return false
	if is_downed(unit):
		return false
	var k := kind_of(unit)
	if k == KIND_OTHER or k == "":
		return false
	if unit.get("vehicle") != null or unit.get("in_vehicle") == true:
		return false
	if k == KIND_BOT and (unit.call("is_aboard") or (unit.has_method("pod_phase") and str(unit.call("pod_phase")) in ["aboard", "flight"])):
		return false
	if is_overkill(unit, amount, impulse, hp_before):
		return false
	if Game.altitude((unit as Node3D).global_position) > Balance.DN_SPACE_ALT:
		return false
	_begin(unit, k, from_pos, false, Balance.DN_BLEED_TIME)
	return true


## Multiplayer CLIENT, its own player: the host's hurt brought hp to 0 (player.gd net_hurt / its
## take_damage under _net_auth). True = do not die here: lie down provisionally and wait for the
## host's verdict (net_apply "down" keeps it, "dead" kills; none within PROVISIONAL_MS: dead).
## False (single player / host / downed off): die as before.
static func client_lethal(unit) -> bool:
	if not Balance.DN_ENABLED or not Net.is_client() or not is_instance_valid(unit):
		return false
	if unit.get("vehicle") != null:
		return false
	if is_downed(unit):
		return true
	var st := _begin(unit, kind_of(unit), Vector3.INF, true, Balance.DN_BLEED_TIME)
	st.provisional_ms = Time.get_ticks_msec() + PROVISIONAL_MS
	return true


## The lethal hit is too much to survive down (see the header).
static func is_overkill(unit, amount: float, impulse := Vector3.ZERO, hp_before := -1.0) -> bool:
	if amount >= Balance.DN_OVERKILL_HIT:
		return true
	if hp_before >= 0.0 and amount - hp_before >= Balance.DN_OVERKILL_EXCESS:
		return true
	if impulse.length() >= Balance.DN_OVERKILL_IMPULSE:
		return true
	if amount >= Balance.DN_HEAD_KILL and Game.hit_pos != Vector3.INF:
		var a = unit.get("astronaut")
		if a != null and is_instance_valid(a) and a.has_method("part_at") and str(a.part_at(Game.hit_pos)) == "head":
			return true
	return false


static func _begin(unit, k: String, from_pos: Vector3, mirror: bool, bleed: float) -> State:
	var id := (unit as Object).get_instance_id()
	var st := State.new()
	st.unit = unit
	st.kind = k
	st.team = Game.team_of(unit)
	st.mirror = mirror
	var n := int(_downs.get(id, 0))
	_downs[id] = n + 1
	st.bleed_max = maxf(Balance.DN_BLEED_MIN, bleed * pow(Balance.DN_BLEED_REPEAT, float(n))) if not mirror else bleed
	st.bleed = st.bleed_max
	st.cause_pos = from_pos
	var who := _who(from_pos, unit)
	st.by_name = str(who.get("name", ""))
	st.by_team = str(who.get("team", ""))
	if who.get("node") != null:
		st.by_node = weakref(who["node"])
	st.medic_roll = randf() < Balance.DN_MEDIC_CHANCE
	if not mirror and randf() < Balance.DN_FINISH_CHANCE:
		st.finisher = _nearest_enemy_bot(unit, 40.0)
	var a = unit.get("astronaut")
	if a != null and is_instance_valid(a):
		st.from = Pose.capture(a)
	st.last_pos = (unit as Node3D).global_position
	_rise.erase(id)
	_st[id] = st
	_ensure_ticker()
	_add_area(st)
	# The owner's own setup.
	if k == KIND_PLAYER:
		_view().begin(unit, st)
	elif unit.has_method("_dn_on_down"):
		unit.call("_dn_on_down")
	if not mirror:
		events().downed.emit(unit, {"bleed": st.bleed, "by": st.by_name, "by_team": st.by_team,
				"pos": (unit as Node3D).global_position, "kind": k})
	_announce_down(st)
	return st


# =================================================================================================
# Hits while down, giving up, bleeding out
# =================================================================================================

## take_damage on a downed unit: each hit drains the bleed-out (DN_FINISH_FLAT + damage ×
## DN_FINISH_PER_HP s; a huge one ends it). {"dmg", "killed"}: killed = finished (confirmed here).
static func hurt_downed(unit, amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO) -> Dictionary:
	var st := state_of(unit)
	if st == null or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	st.last_hit_ms = Time.get_ticks_msec()
	st.hit_k = 1.0
	var drain := Balance.DN_FINISH_FLAT + amount * Balance.DN_FINISH_PER_HP
	if amount >= Balance.DN_OVERKILL_HIT:
		drain = INF
	st.bleed -= drain
	if st.mirror or Net.is_client():
		st.bleed = maxf(st.bleed, 0.05)            # (the host decides; this is only the bar)
		return {"dmg": amount, "killed": false}
	if st.bleed <= 0.0:
		var who := _who(from_pos, unit)
		_confirm(st, "finished", impulse, who)
		return {"dmg": amount, "killed": true}
	return {"dmg": amount, "killed": false, "downed": true}


## The unit gives up (the player held Space): dead now. A client sends a claim instead.
static func gave_up(unit) -> void:
	var st := state_of(unit)
	if st == null:
		return
	if st.mirror or Net.is_client():
		events().claim.emit("give_up", unit)
		return
	_confirm(st, "gave_up", Vector3.ZERO, {})


## Bled out: dead now.
static func bled_out(unit) -> void:
	var st := state_of(unit)
	if st != null and not st.mirror:
		_confirm(st, "bled_out", Vector3.ZERO, {})


## Finished off (by `by`, may be null): dead now.
static func finish(unit, by = null) -> void:
	var st := state_of(unit)
	if st != null and not st.mirror:
		var who := {}
		if is_instance_valid(by):
			who = {"name": _name_of(by), "team": Game.team_of(by), "node": by}
		_confirm(st, "finished", Vector3.ZERO, who)


static func _confirm(st: State, cause: String, impulse: Vector3, who: Dictionary) -> void:
	var u := st.unit
	if not is_instance_valid(u):
		_drop(st)
		return
	var info := {"by": st.by_name, "by_team": st.by_team, "kind": st.kind}
	if cause == "finished" and str(who.get("name", "")) != "":
		info["by"] = str(who["name"])
		info["by_team"] = str(who.get("team", ""))
	_drop(st)
	_downs.erase(u.get_instance_id())
	events().confirmed.emit(u, cause, info)
	_announce_dead(u, st.kind, cause, info, who)
	_enter_respawn(u, st.kind, impulse, cause)


## THE single call site into the death / respawn flow for a downed unit that died for real (gave up,
## bled out, finished). Today: the owner's normal death (player.gd / ai_rival.gd _die: the ragdoll
## from the lying pose, the corpse, the dropship respawn; the other player's avatar: dead, its
## owner is told through events().confirmed by the multiplayer layer). When the respawn waves
## expose their entry point (e.g. RespawnShip.enqueue_dead(unit)), only this function changes.
static func _enter_respawn(unit, kind: String, impulse: Vector3, _cause: String) -> void:
	if not is_instance_valid(unit):
		return
	match kind:
		KIND_PLAYER:
			_view().end_for_death(unit)
			if unit.has_method("_die"):
				unit.call("_die", impulse)
		KIND_BOT:
			if unit.has_method("_dn_on_dead"):
				unit.call("_dn_on_dead")
			if unit.has_method("_die"):
				unit.call("_die", impulse)
		KIND_REMOTE:
			unit.set("dead", true)


# =================================================================================================
# Revive
# =================================================================================================

## A reviver starts (players: then hold_revive every frame while F is held; auto = held until
## stop_revive: bots and the host's copy of a client's revive). False: someone else is on it / out
## of range / not a teammate.
static func begin_revive(unit, by, auto := false) -> bool:
	var st := state_of(unit)
	if st == null or not is_instance_valid(by) or by == unit:
		return false
	if st.reviver != null and is_instance_valid(st.reviver) and st.reviver != by:
		return false
	if Game.team_of(by) != st.team or is_downed(by):
		return false
	if not in_reach(unit, by, 0.4):
		return false
	var fresh: bool = st.reviver != by
	st.reviver = by
	st.revive_auto = auto
	st.revive_hold_ms = Time.get_ticks_msec()
	st.reviver_hp = float(by.get("hp")) if by.get("hp") != null else -1.0
	if fresh:
		st.revive_t = 0.0
		if not st.mirror:
			events().revive_started.emit(unit, by)
	return true


## A player reviver keeps holding (every frame while F is down).
static func hold_revive(unit, by) -> void:
	var st := state_of(unit)
	if st != null and st.reviver == by:
		st.revive_hold_ms = Time.get_ticks_msec()


static func stop_revive(unit, by = null) -> void:
	var st := state_of(unit)
	if st == null or st.reviver == null:
		return
	if by != null and st.reviver != by:
		return
	var r := st.reviver
	st.reviver = null
	st.revive_t = 0.0
	st.revive_auto = false
	if not st.mirror:
		events().revive_stopped.emit(unit, r)


## Within revive range of the body (plus `slack` m).
static func in_reach(unit, by, slack := 0.0) -> bool:
	if not is_instance_valid(unit) or not is_instance_valid(by):
		return false
	var c := body_center(unit)
	var p := (by as Node3D).global_position
	var up := _up_at(c)
	var rel := p - c
	var h := rel.dot(up)
	return (rel - up * h).length() <= Balance.DN_REVIVE_RANGE + slack and absf(h) < 2.2


## The middle of the lying body (world).
static func body_center(unit) -> Vector3:
	var n := unit as Node3D
	if n == null:
		return Vector3.ZERO
	var a = n.get("astronaut")
	if a != null and is_instance_valid(a) and a.spine != null and is_downed(unit):
		return (a.spine as Node3D).global_position
	return n.global_position


## Up now: hp DN_REVIVE_HP × hp_max, the get-up, then the stagger. A client's revive of the host's
## units is a claim (revive.gd); this runs where the authority is (or from net_apply).
static func revive(unit, by = null) -> void:
	var st := state_of(unit)
	if st == null:
		return
	var u := st.unit
	var k := st.kind
	_drop(st)
	var hpm: float = float(u.get("hp_max")) if u.get("hp_max") != null else 100.0
	if not st.mirror or k == KIND_PLAYER:
		u.set("hp", hpm * Balance.DN_REVIVE_HP)
	_rise[u.get_instance_id()] = {"unit": u, "t": 0.0, "from": Pose.capture(u.get("astronaut")) if u.get("astronaut") != null else {}, "kind": k}
	if k == KIND_PLAYER:
		_view().begin_rise(u)
	elif u.has_method("_dn_on_revived"):
		u.call("_dn_on_revived")
	if not st.mirror:
		events().revived.emit(u, by)
	_announce_revive(u, by)


# =================================================================================================
# Drag
# =================================================================================================

## `by` grabs the shoulder strap. False: someone else holds it / not a teammate / out of reach.
static func begin_drag(unit, by) -> bool:
	var st := state_of(unit)
	if st == null or not is_instance_valid(by) or by == unit or is_downed(by):
		return false
	if st.dragger != null and is_instance_valid(st.dragger) and st.dragger != by:
		return false
	if Game.team_of(by) != st.team or not in_reach(unit, by, 0.6):
		return false
	var prev := dragged_by(by)
	if prev != null and prev != unit:
		stop_drag(prev)
	if st.reviver == by:
		stop_revive(unit, by)
	st.dragger = by
	if not st.mirror:
		events().drag_started.emit(unit, by)
	return true


static func stop_drag(unit) -> void:
	var st := state_of(unit)
	if st == null or st.dragger == null:
		return
	var d := st.dragger
	st.dragger = null
	if not st.mirror:
		events().drag_stopped.emit(unit, d)


## Where the dragged body's shoulders are pulled toward: DN_DRAG_DIST m in front of the dragger's
## feet, on its side of the body (world). INF when not dragged.
static func drag_point(unit) -> Vector3:
	var d := dragger_of(unit)
	if d == null:
		return Vector3.INF
	var dp := (d as Node3D).global_position
	var up := _up_at(dp)
	var me := (unit as Node3D).global_position
	var to := me - dp
	to -= up * to.dot(up)
	if to.length_squared() < 1e-4:
		to = -(d as Node3D).global_transform.basis.z
		to -= up * to.dot(up)
	return dp + to.normalized() * Balance.DN_DRAG_DIST


# =================================================================================================
# Pose (bots, mirrors; the local player's own view: downed_view.gd)
# =================================================================================================

## One pose step of a downed unit's astronaut (`speed`: its crawl / drag speed, -1 = measured from
## the position change). The caller syncs the skeleton if it syncs itself (bots).
static func pose_step(unit, delta: float, speed := -1.0) -> void:
	var st := state_of(unit)
	if st == null:
		return
	var a = unit.get("astronaut")
	if a == null or not is_instance_valid(a):
		return
	var p := (unit as Node3D).global_position
	var sp := speed
	if sp < 0.0:
		sp = p.distance_to(st.last_pos) / maxf(delta, 1e-4) if st.last_pos != Vector3.INF else 0.0
		if sp > 6.0:
			sp = 0.0                              # a teleport / resync
	st.last_pos = p
	var dragged: bool = st.dragger != null and is_instance_valid(st.dragger)
	st.pose_t += delta
	st.fold = minf(st.fold + delta / COLLAPSE_TIME, 1.0)
	st.drag_k = move_toward(st.drag_k, 1.0 if dragged else 0.0, delta * 3.0)
	var crawl := 0.0 if dragged else clampf(sp / maxf(Balance.DN_CRAWL_SPEED, 0.1), 0.0, 1.0)
	st.move = move_toward(st.move, crawl, delta * 4.0)
	if not dragged:
		st.ph = fmod(st.ph + sp * delta / Pose.CRAWL_STRIDE, 1.0)
	a.transform = Transform3D.IDENTITY
	Pose.apply(a, Pose.target(a, st.ph, st.move, st.drag_k, st.pose_t), st.from, Pose.smooth(st.fold))


## A bot's crawl target: toward its medic when one is coming, else a few metres away from the threat
## that put it down (DN_BOT_CRAWL_MAX m in all). INF = lie still.
static func crawl_goal(unit) -> Vector3:
	var st := state_of(unit)
	if st == null or st.mirror or (st.dragger != null and is_instance_valid(st.dragger)):
		return Vector3.INF
	if st.reviver != null and is_instance_valid(st.reviver):
		return Vector3.INF
	if st.crawled >= Balance.DN_BOT_CRAWL_MAX:
		return Vector3.INF
	var p := (unit as Node3D).global_position
	var up := _up_at(p)
	var dir := Vector3.ZERO
	if st.medic != null and is_instance_valid(st.medic):
		dir = (st.medic as Node3D).global_position - p
		if dir.length() < Balance.DN_REVIVE_RANGE:
			return Vector3.INF
	elif st.cause_pos != Vector3.INF and st.cause_pos != Vector3.ZERO:
		dir = p - st.cause_pos
	else:
		return Vector3.INF
	dir -= up * dir.dot(up)
	if dir.length_squared() < 1e-4:
		return Vector3.INF
	return p + dir.normalized() * 1.5


## The bot reports how far it crawled (its sim step).
static func add_crawled(unit, d: float) -> void:
	var st := state_of(unit)
	if st != null:
		st.crawled += d


# =================================================================================================
# Multiplayer
# =================================================================================================

## Apply the host's decision on a machine without authority (the multiplayer layer calls it).
##   "down"   {"bleed": s} (unit: Game.player = I am down; an avatar / puppet: show it down)
##   "bleed"  {"left": s}     "revive" {}     "dead" {"cause", "by"}
##   "drag" {"by": node}     "undrag" {}     "revive_start" {"by": node}     "revive_stop" {}
static func net_apply(unit, what: String, data := {}) -> void:
	if not is_instance_valid(unit):
		return
	var st := state_of(unit)
	match what:
		"down":
			if st == null:
				var k := kind_of(unit)
				_begin(unit, k if k != "" else KIND_OTHER, Vector3.INF, true, float(data.get("bleed", Balance.DN_BLEED_TIME)))
			else:
				st.provisional_ms = -1                 # the host confirms the provisional down
				st.bleed_max = float(data.get("bleed", st.bleed_max))
				st.bleed = st.bleed_max
		"bleed":
			if st != null:
				st.bleed = float(data.get("left", st.bleed))
		"revive":
			if st != null:
				revive(unit, data.get("by", null))
		"dead":
			if st != null:
				var k2 := st.kind
				_drop(st)
				_announce_dead(unit, k2, str(data.get("cause", "")), {"by": str(data.get("by", ""))}, {})
				if k2 == KIND_PLAYER:
					_view().end_for_death(unit)
					if unit.has_method("_die"):
						unit.call("_die", Vector3.ZERO)
		"drag":
			if st != null and is_instance_valid(data.get("by", null)):
				st.dragger = data["by"]
		"undrag":
			if st != null:
				st.dragger = null
		"revive_start":
			if st != null and is_instance_valid(data.get("by", null)):
				st.reviver = data["by"]
				st.revive_auto = true
				st.revive_t = 0.0
		"revive_stop":
			if st != null:
				st.reviver = null
				st.revive_t = 0.0


## Host: a client's claim about its own actions (`by` = that client's avatar here).
static func host_claim(what: String, unit, by) -> void:
	if Net.is_client():
		return
	match what:
		"revive_start":
			begin_revive(unit, by, true)
		"revive_stop":
			stop_revive(unit, by)
		"drag_start":
			begin_drag(unit, by)
		"drag_stop":
			if dragger_of(unit) == by:
				stop_drag(unit)
		"give_up":
			if unit == by:
				gave_up(unit)


# =================================================================================================
# Ticker
# =================================================================================================

static func _ensure_ticker() -> void:
	if _ticker != null and is_instance_valid(_ticker) and _ticker.is_inside_tree():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var t: Node = load("res://scripts/war/downed.gd").new()
	t.name = "DownedTicker"
	_ticker = t
	tree.root.add_child.call_deferred(t)


func _ready() -> void:
	process_priority = -5                  # before the bodies pose themselves


func _exit_tree() -> void:
	if _ticker == self:
		_ticker = null


func _process(delta: float) -> void:
	step(delta)


## One frame of every downed / rising unit (the ticker; tests call it directly).
static func step(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for id in _st.keys():
		var st: State = _st.get(id, null)
		if st == null:
			continue
		if not is_instance_valid(st.unit) or not (st.unit as Node).is_inside_tree():
			_drop(st)
			continue
		if st.unit.has_method("is_dead") and st.unit.call("is_dead"):
			_drop(st)                              # died some other way (respawned / freed)
			continue
		st.since += delta
		st.hit_k = maxf(st.hit_k - delta * 2.5, 0.0)
		_tick_revive(st, delta, now)
		if not _st.has(id):
			continue
		_tick_drag(st, delta)
		if not st.mirror:
			if not (st.reviver != null and is_instance_valid(st.reviver)):
				st.bleed -= delta
			st.sync_t += delta
			if st.sync_t >= 1.0:
				st.sync_t = 0.0
				events().bleed.emit(st.unit, st.bleed)
			if st.bleed <= 0.0:
				_confirm(st, "bled_out", Vector3.ZERO, {})
				continue
		else:
			st.bleed = maxf(st.bleed - delta * (0.0 if st.reviver != null else 1.0), 0.05)
			if st.provisional_ms > 0 and now > st.provisional_ms:
				net_apply(st.unit, "dead", {"cause": "overkill"})    # no verdict from the host: dead as before
				continue
		if st.kind == KIND_OTHER and st.unit.get("astronaut") != null:
			pose_step(st.unit, delta)              # (a mirror puppet: nobody else poses it)
	for id in _rise.keys():
		_tick_rise(id, delta)
	if _rv_script == null:
		_rv_script = load(REVIVE_PATH)
	if _rv_script != null:
		_rv_script.tick(delta)


static func _tick_revive(st: State, delta: float, now: int) -> void:
	var r := st.reviver
	if r == null:
		return
	if not is_instance_valid(r) or is_downed(r) or (r.has_method("is_dead") and r.call("is_dead")):
		stop_revive(st.unit)
		return
	if not st.revive_auto and now - st.revive_hold_ms > 250:
		stop_revive(st.unit)                       # F let go
		return
	if not in_reach(st.unit, r, 0.5):
		stop_revive(st.unit)                       # moved away
		return
	if st.reviver_hp >= 0.0 and r.get("hp") != null:
		var hp := float(r.get("hp"))
		if st.reviver_hp - hp >= Balance.DN_REVIVE_BREAK_DMG:
			stop_revive(st.unit)                   # a big hit breaks it
			return
		st.reviver_hp = maxf(st.reviver_hp, hp)
	if st.dragger != null:
		stop_drag(st.unit)
	st.revive_t += delta
	if st.revive_t >= Balance.DN_REVIVE_TIME and not st.mirror:
		revive(st.unit, r)


## The body follows the strap (bots / avatars / puppets are moved here; a dragged local player moves
## itself in downed_view.gd physics). Too far: it slips.
static func _tick_drag(st: State, delta: float) -> void:
	var d := st.dragger
	if d == null:
		return
	if not is_instance_valid(d) or is_downed(d) or (d.has_method("is_dead") and d.call("is_dead")) \
			or (d.get("vehicle") != null):
		stop_drag(st.unit)
		return
	var u := st.unit as Node3D
	var gap := (d as Node3D).global_position.distance_to(u.global_position)
	if gap > Balance.DN_DRAG_BREAK and not st.mirror:
		stop_drag(st.unit)
		if d == Game.player:
			HudLevel.alert("Askı elinden kaydı", 1, "dn_drag", 1.6)
		return
	if st.kind == KIND_PLAYER or st.kind == KIND_REMOTE:
		return                                     # (the owner's own machine moves that body)
	var to := drag_point(u)
	if to == Vector3.INF:
		return
	var p := u.global_position
	var up := _up_at(p)
	var mv := to - p
	mv -= up * mv.dot(up)
	var step_len := minf(mv.length(), Balance.DN_DRAG_SPEED * 1.6 * delta)
	if step_len > 1e-4:
		p += mv.normalized() * step_len
	p = _ground(p, up, u)
	# Head first toward the dragger: -Z along the pull.
	var head_dir := (d as Node3D).global_position - p
	head_dir -= up * head_dir.dot(up)
	var b := u.global_transform.basis
	if head_dir.length_squared() > 1e-4:
		var z := -head_dir.normalized()
		var x := up.cross(z).normalized()
		var want := Basis(x, up, x.cross(up)).orthonormalized()
		b = Basis(b.get_rotation_quaternion().slerp(want.get_rotation_quaternion(), 1.0 - exp(-6.0 * delta)))
	u.global_transform = Transform3D(b, p)


static func _tick_rise(id: int, delta: float) -> void:
	var r: Dictionary = _rise.get(id, {})
	var u = r.get("unit", null)
	if not is_instance_valid(u):
		_rise.erase(id)
		return
	var t := float(r["t"]) + delta
	r["t"] = t
	var k := str(r.get("kind", ""))
	if k == KIND_PLAYER:
		if _view().rise_step(u, t, r["from"]):
			_rise.erase(id)
			_stagger[id] = Time.get_ticks_msec() + int(Balance.DN_STAGGER_TIME * 1000.0)
		return
	var a = u.get("astronaut")
	if a != null and is_instance_valid(a):
		rise_pose(a, t, r["from"])
	if t >= Balance.DN_GETUP_TIME:
		_rise.erase(id)
		if a != null and is_instance_valid(a):
			a.transform = Transform3D.IDENTITY
			a.reset_pose()
		if u.has_method("_dn_on_up"):
			u.call("_dn_on_up")


## The get-up pose at `t` s: from the downed pose up onto one knee, then standing (the last frames
## hand back to the owner's animation from the rest pose).
static func rise_pose(a, t: float, from: Dictionary) -> void:
	var T := maxf(Balance.DN_GETUP_TIME, 0.1)
	var t1 := T * 0.55
	var kn := kneel(a)
	if t < t1:
		Pose.apply(a, kn, from, Pose.smooth(t / t1))
	else:
		Pose.apply(a, Pose.rest(a), kn, Pose.smooth((t - t1) / (T - t1)))


## Kneeling on one knee (the middle of the get-up; player.gd's get-up key pose 2).
static func kneel(a) -> Dictionary:
	var d := Pose.rest(a)
	var spec := {a.hips: [Vector3(0, 0.52, 0.05), Vector3(-0.22, 0, 0)], a.chest: Vector3(-0.05, 0, 0),
			a.head: Vector3(0.18, 0, 0), a.shoulder[0]: Vector3(0.55, 0, -0.18), a.shoulder[1]: Vector3(0.85, 0, 0.15),
			a.elbow[0]: Vector3(0.6, 0, 0), a.elbow[1]: Vector3(0.7, 0, 0),
			a.thigh[0]: Vector3(1.55, 0, -0.05), a.thigh[1]: Vector3(0.15, 0, 0.05),
			a.shin[0]: Vector3(-1.5, 0, 0), a.shin[1]: Vector3(-1.55, 0, 0)}
	for b in spec:
		var r: Transform3D = a.rest_local(b)
		if spec[b] is Array:
			d[b] = Transform3D(Basis.from_euler(spec[b][1]), spec[b][0])
		else:
			d[b] = Transform3D(Basis.from_euler(spec[b]), r.origin)
	return d


# =================================================================================================
# Helpers
# =================================================================================================

## Removes the state (no death, no revive): the revive area off, the unit's own areas back.
static func _drop(st: State) -> void:
	if st.unit != null and is_instance_valid(st.unit):
		_st.erase((st.unit as Object).get_instance_id())
	else:
		for id in _st.keys():
			if _st[id] == st:
				_st.erase(id)
	if st.area != null and is_instance_valid(st.area):
		st.area.queue_free()
	st.area = null
	for e in st.hidden_areas:
		var ar = e[0]
		if is_instance_valid(ar):
			(ar as Area3D).collision_layer = int(e[1])
	st.hidden_areas.clear()
	st.reviver = null
	st.dragger = null
	st.medic = null


## The revive target on a downed teammate of the local player (not on the local player himself).
static func _add_area(st: State) -> void:
	var u := st.unit as Node3D
	if u == null or u == Game.player:
		return
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or Game.team_of(pl) != st.team:
		return
	# The unit's own interact areas (an ally's "Command" button) step aside while it is down.
	for c in u.get_children():
		if c is Area3D and ((c as Area3D).collision_layer & Game.LAYER_INTERACT) != 0:
			st.hidden_areas.append([c, (c as Area3D).collision_layer])
			(c as Area3D).collision_layer = 0
	var ar := ReviveArea.new()
	ar.name = "DownedRevive"
	ar.unit = u
	ar.collision_layer = Game.LAYER_INTERACT
	ar.collision_mask = 0
	ar.monitoring = false
	ar.monitorable = true
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.75
	cs.shape = sh
	ar.add_child(cs)
	ar.position = Vector3(0, 0.35, -0.05)
	ar.set_meta(AREA_META, true)
	u.add_child(ar)
	st.area = ar


## Who fired from `from_pos` (a muzzle / eye within 3 m of a unit): {"name", "team", "node", "mine"}.
static func _who(from_pos: Vector3, victim) -> Dictionary:
	if from_pos == Vector3.ZERO or from_pos == Vector3.INF:
		return {}
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return {}
	var best: Node3D = null
	var bd := 3.0
	var cands: Array = []
	if Game.player != null and is_instance_valid(Game.player):
		cands.append(Game.player)
	cands.append_array(tree.get_nodes_in_group("net_player"))
	cands.append_array(tree.get_nodes_in_group("war_ai"))
	for c in cands:
		if c == victim or not (c is Node3D) or not is_instance_valid(c):
			continue
		var d := (c as Node3D).global_position.distance_to(from_pos)
		if d > 4.0:
			continue
		var e := ((c as Node3D).global_position + (c as Node3D).global_transform.basis.y * 1.5).distance_to(from_pos)
		d = minf(d, e)
		if d < bd:
			bd = d
			best = c
	if best == null:
		return {}
	return {"name": _name_of(best), "team": Game.team_of(best), "node": best, "mine": best == Game.player}


static func _name_of(n) -> String:
	if not is_instance_valid(n):
		return ""
	if n == Game.player:
		return "Sen"
	var hf = load(HIT_FEEL_PATH)
	if hf != null:
		return str(hf.display_name(n))
	return "Hedef"


static func _nearest_enemy_bot(unit, rng: float) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var p := (unit as Node3D).global_position
	var t := Game.team_of(unit)
	var best: Node = null
	var bd := rng
	for b in tree.get_nodes_in_group("war_ai"):
		if not is_instance_valid(b) or Game.team_of(b) == t or (b.has_method("is_dead") and b.call("is_dead")) or is_downed(b):
			continue
		var d := (b as Node3D).global_position.distance_to(p)
		if d < bd:
			bd = d
			best = b
	return best


static func _up_at(p: Vector3) -> Vector3:
	var b := Game.dominant_body(p)
	var c: Vector3 = b.global_position if b != null else Game.planet_center()
	var u := p - c
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


## Onto the ground under p (physics, then the density field).
static func _ground(p: Vector3, up: Vector3, skip: Node3D) -> Vector3:
	var w := skip.get_world_3d() if skip != null and skip.is_inside_tree() else null
	if w != null:
		var ex: Array = []
		if skip is CollisionObject3D:
			ex.append((skip as CollisionObject3D).get_rid())
		var q := PhysicsRayQueryParameters3D.create(p + up * 1.2, p - up * 2.5, Game.LAYER_TERRAIN, ex)
		var hit := w.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			return hit["position"]
	var b := Game.dominant_body(p)
	if b != null and b.has_method("raycast_density"):
		var h: Dictionary = b.raycast_density(p + up * 1.2, p - up * 2.5, 0.3, false)
		if not h.is_empty():
			return h["position"]
	return p


static func _view():
	return load(VIEW_PATH)


static func _hud_feed(killer: String, victim: String, detail: String, mine: bool) -> void:
	if not Game.has_meta("hit_feel"):
		return
	var hf = Game.get_meta("hit_feel")
	if not is_instance_valid(hf) or hf.get("hud") == null:
		return
	hf.hud.feed(killer, victim, detail, mine)


static func _announce_down(st: State) -> void:
	var u := st.unit
	var me: bool = u == Game.player
	var victim := "Sen" if me else _name_of(u)
	var mine: bool = me or st.by_name == "Sen"
	_hud_feed(st.by_name if st.by_name != "" else "—", victim, "YERE SERİLDİ", mine)
	if me:
		HudLevel.alert("YERE SERİLDİN — yardım bekle · [Space basılı tut] vazgeç", 2, "dn_self", 3.0)
		return
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and Game.team_of(pl) == st.team and st.kind != KIND_OTHER:
		var d := (pl as Node3D).global_position.distance_to((u as Node3D).global_position)
		HudLevel.alert("%s yere serildi · %d m" % [victim, int(d)], 1, "dn_mate", 2.5)


static func _announce_dead(u, kind: String, cause: String, info: Dictionary, who: Dictionary) -> void:
	if not is_instance_valid(u) or cause == "overkill":
		return
	var me: bool = u == Game.player
	var victim := "Sen" if me else _name_of(u)
	var by := str(info.get("by", ""))
	var detail := "kan kaybı"
	match cause:
		"gave_up":
			detail = "vazgeçti"
		"finished":
			detail = "işi bitirildi"
	# (Finished by our own shot: hit_feel.gd already printed the kill line for that hit.)
	if cause == "finished" and bool(who.get("mine", false)):
		return
	_hud_feed(by if by != "" else "—", victim, detail, me or by == "Sen")
	if me and cause == "bled_out":
		HudLevel.alert("Kan kaybından öldün", 2, "dn_self", 2.5)
	elif kind != KIND_OTHER and not me:
		var pl = Game.player
		if pl != null and is_instance_valid(pl) and Game.team_of(pl) == Game.team_of(u):
			HudLevel.alert("%s öldü (%s)" % [victim, detail], 1, "dn_mate", 2.0)


static func _announce_revive(u, by) -> void:
	if u == Game.player:
		var who := _name_of(by) if is_instance_valid(by) else ""
		HudLevel.alert("Ayağa kaldırıldın" + (" — " + who if who != "" and who != "Sen" else ""), 1, "dn_self", 2.0)
	elif by == Game.player:
		HudLevel.alert("%s ayağa kalktı" % _name_of(u), 0, "dn_mate", 1.8)
