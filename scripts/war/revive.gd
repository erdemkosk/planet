extends RefCounted
## Reviving and dragging downed teammates (scripts/war/downed.gd holds the states). Static; driven by
## downed.gd's ticker (tick) and the revive target on a downed teammate (Downed.ReviveArea: player.gd's
## interact ray finds it, F calls on_interact, its prompt comes from prompt()).
##
## The local player, F on a downed teammate (the normal interact path: interact_target):
##   tap F  (let go within DN_TAP_MAX s)   grab the shoulder strap: drag it (Downed.begin_drag); the
##                                         walk is capped at DN_DRAG_SPEED (player.gd asks
##                                         Downed.speed_cap); F again (anywhere) lets go; too far, a
##                                         grenade / scan or the jetpack: it slips
##   hold F (longer)                       the revive: within DN_REVIVE_RANGE m for DN_REVIVE_TIME s
##                                         (let go, walk off, fire or a big hit: broken)
## In first person the left hand reaches down to the strap / the chest (hand_action.gd's left arm
## targets, the held item dipped); nothing third person. Multiplayer client: the same locally (the
## bar is predicted) plus Downed.events().claim -> the host decides.
## Bots (host / single player): once a second the nearest free teammate bot (its ai_rival.gd
## _dn_medic_free()) is picked as the medic of a downed unit that waited DN_MEDIC_DELAY s and was not
## hit for DN_MEDIC_SAFE s (DN_MEDIC_CHANCE per down, DN_MEDICS_MAX per team); its "Downed / revive"
## section walks over (medic_task), crouches and begins an auto revive; it lets go when shot at or
## something shows up (medic_release), or after DN_MEDIC_GIVEUP s.
##
## API: on_interact(p, unit), prompt(unit), tick(delta); UI: local_revive_unit(), local_drag_unit(),
## local_press(); bots: medic_task(bot) -> downed unit or null, medic_release(bot), medics() (debug).

const Downed := preload("res://scripts/war/downed.gd")
const Balance := preload("res://scripts/war/balance.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")

## Left wrist (camera space) reaching down for the strap / the chest; forearm toward the elbow.
const HAND_DOWN := Vector3(-0.16, -0.5, -0.42)
const HAND_ELBOW := Vector3(-0.3, -0.45, 0.6)
const HAND_REACH := 0.62               # m: the wrist never further from the eye than this

static var _press_unit: Node = null    # the downed teammate F went down on
static var _press_t := 0.0
static var _press_mode := ""           # "", "pending" (tap or hold?), "revive"
static var _claimed_revive: Node = null
static var _hand_k := 0.0
static var _medic_t := 0.0
static var _medics := {}               # bot instance id -> {"bot", "unit", "t0"}
static var _deny_ms := 0


# =================================================================================================
# The local player
# =================================================================================================

## F went down on a downed teammate's revive target (player.gd -> Downed.ReviveArea.interact).
static func on_interact(p, unit) -> void:
	if p != Game.player or not is_instance_valid(unit) or not Downed.is_downed(unit):
		return
	if Downed.dragged_by(p) != null:
		return                                   # (dragging: tick() lets go on this press)
	_press_unit = unit
	_press_t = 0.0
	_press_mode = "pending"


## The prompt over a downed teammate.
static func prompt(unit) -> String:
	if not is_instance_valid(unit):
		return ""
	var p = Game.player
	var nm := str(Downed._name_of(unit))
	if p != null and Downed.dragger_of(unit) == p:
		return "[F] Bırak — %s" % nm
	var r := Downed.reviver_of(unit)
	if r != null and r != p:
		return "%s — %s kaldırıyor…" % [nm, Downed._name_of(r)]
	var near: bool = p != null and Downed.in_reach(unit, p)
	return "[F basılı tut] %s — ayağa kaldır  ·  [F] sürükle%s" % [nm, "" if near else "  (yaklaş)"]


static func local_revive_unit() -> Node:
	var p = Game.player
	return Downed.reviving_by(p) if p != null else null


static func local_drag_unit() -> Node:
	var p = Game.player
	return Downed.dragged_by(p) if p != null else null


## "pending" while F is down on a teammate before it counts as a hold.
static func local_press() -> String:
	return _press_mode


static func _end_press() -> void:
	_press_unit = null
	_press_t = 0.0
	_press_mode = ""


static func _local(delta: float) -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
		_end_press()
		return
	var off: bool = Downed.is_downed(p) or Downed.is_rising(p) or p.is_dead() or p.get("vehicle") != null \
			or (p.has_method("is_ragdolled") and p.is_ragdolled())
	var dragging := Downed.dragged_by(p)
	var reviving := Downed.reviving_by(p)
	if off:
		if dragging != null:
			_stop_drag(p, dragging)
		if reviving != null:
			_stop_revive(p, reviving)
		_end_press()
		_hands(p, delta, Vector3.INF)
		return
	var f_down := Input.is_action_pressed("interact") and not Game.ui_panel_open()
	var ha = p.get("hand_action")
	var hands_used: bool = ha != null and str(ha.get("state")) != ""
	# Dragging: F again (anywhere), the left hand needed (grenade / scan) or the jetpack: let go.
	if dragging != null and _press_mode == "":
		if Input.is_action_just_pressed("interact") or hands_used or p.get("jetting") == true:
			_stop_drag(p, dragging)
			dragging = null
	if _press_mode != "":
		var u := _press_unit
		if not is_instance_valid(u) or not Downed.is_downed(u):
			_end_press()
		elif f_down:
			_press_t += delta
			if _press_mode == "pending" and _press_t >= Balance.DN_TAP_MAX:
				_press_mode = "revive"
			if _press_mode == "revive":
				var firing := Input.is_action_pressed("tool_use") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
				if firing or hands_used:
					_stop_revive(p, u)
					_end_press()
				elif Downed.reviving_by(p) == u:
					Downed.hold_revive(u, p)
				elif not Downed.begin_revive(u, p, false):
					_deny(u, p)
				elif Net.is_client() and _claimed_revive != u:
					_claimed_revive = u
					Downed.events().claim.emit("revive_start", u)
		else:
			if _press_mode == "pending":
				_toggle_drag(p, u)
			elif _press_mode == "revive" and Downed.reviving_by(p) == u:
				_stop_revive(p, u)
			_end_press()
	if _claimed_revive != null and Downed.reviving_by(p) != _claimed_revive:
		if is_instance_valid(_claimed_revive) and Net.is_client():
			Downed.events().claim.emit("revive_stop", _claimed_revive)
		_claimed_revive = null
	var tgt := Vector3.INF
	var held := Downed.dragged_by(p)
	if held != null:
		tgt = Downed.body_center(held) + (held as Node3D).global_transform.basis.y * 0.1
		var a = held.get("astronaut")
		if a != null and is_instance_valid(a) and a.chest != null:
			tgt = (a.chest as Node3D).global_position
	else:
		var rv := Downed.reviving_by(p)
		if rv != null:
			tgt = Downed.body_center(rv)
	_hands(p, delta, tgt)


static func _deny(u, p) -> void:
	var now := Time.get_ticks_msec()
	if now - _deny_ms < 1500:
		return
	_deny_ms = now
	var r := Downed.reviver_of(u)
	if r != null and r != p:
		HudLevel.alert("%s zaten kaldırıyor" % Downed._name_of(r), 0, "dn_deny", 1.4)
	elif not Downed.in_reach(u, p):
		HudLevel.alert("Yaklaş — %.0f m içinde" % Balance.DN_REVIVE_RANGE, 1, "dn_deny", 1.4)


static func _toggle_drag(p, u) -> void:
	if Downed.dragger_of(u) == p:
		_stop_drag(p, u)
		return
	if Downed.begin_drag(u, p):
		if Net.is_client():
			Downed.events().claim.emit("drag_start", u)
		HudLevel.alert("Sürüklüyorsun — [F] bırak", 0, "dn_drag", 1.8)
	else:
		_deny(u, p)


static func _stop_drag(p, u) -> void:
	if Downed.dragger_of(u) == p:
		Downed.stop_drag(u)
		if Net.is_client():
			Downed.events().claim.emit("drag_stop", u)


static func _stop_revive(p, u) -> void:
	if Downed.reviving_by(p) == u:
		Downed.stop_revive(u, p)
	if Net.is_client() and _claimed_revive == u:
		Downed.events().claim.emit("revive_stop", u)
		_claimed_revive = null


## The left hand reaches down toward `world` (INF: lets go, hand_action.gd eases it back by itself).
static func _hands(p, delta: float, world: Vector3) -> void:
	var ha = p.get("hand_action")
	if ha == null or not is_instance_valid(ha) or str(ha.get("state")) != "":
		_hand_k = 0.0
		return
	var on := world != Vector3.INF
	_hand_k = move_toward(_hand_k, 1.0 if on else 0.0, delta * 3.5)
	if _hand_k <= 0.0:
		return
	var cam = p.get("camera")
	var wrist := HAND_DOWN
	if on and cam is Camera3D:
		var loc: Vector3 = (cam as Camera3D).global_transform.affine_inverse() * world
		if loc.z < -0.05:
			wrist = loc.limit_length(HAND_REACH)
			wrist.x = minf(wrist.x, 0.05)               # (the left hand stays left of the centre)
	ha.set("left_target", (ha.get("left_target") as Vector3).lerp(wrist, 1.0 - exp(-10.0 * delta)) if ha.get("left_target") is Vector3 else wrist)
	ha.set("left_elbow", HAND_ELBOW)
	ha.set("left_w", maxf(float(ha.get("left_w")), _smooth(_hand_k)))
	ha.set("right_lower", maxf(float(ha.get("right_lower")), 0.85 * _hand_k))


static func _smooth(v: float) -> float:
	var k := clampf(v, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


# =================================================================================================
# Bots: medics
# =================================================================================================

static func tick(delta: float) -> void:
	_local(delta)
	if Net.is_client():
		return
	_medic_t -= delta
	if _medic_t > 0.0:
		return
	_medic_t = 1.0
	_assign_medics()


## The downed unit `bot` should go and revive (null: none / not any more).
static func medic_task(bot) -> Node:
	if _medics.is_empty() or not is_instance_valid(bot):
		return null
	var id := (bot as Object).get_instance_id()
	var m: Dictionary = _medics.get(id, {})
	if m.is_empty():
		return null
	var u = m.get("unit", null)
	if not is_instance_valid(u) or not Downed.is_downed(u):
		medic_release(bot)
		return null
	return u


## `bot` stops being a medic (done, shot at, gave up): its revive (if any) ends.
static func medic_release(bot) -> void:
	if not is_instance_valid(bot):
		return
	var id := (bot as Object).get_instance_id()
	var m: Dictionary = _medics.get(id, {})
	_medics.erase(id)
	if m.is_empty():
		return
	var u = m.get("unit", null)
	if is_instance_valid(u):
		var st = Downed.state_of(u)
		if st != null and st.medic == bot:
			st.medic = null
			st.last_hit_ms = maxi(st.last_hit_ms, Time.get_ticks_msec() - int(Balance.DN_MEDIC_SAFE * 500.0))   # (not straight back)
		if Downed.reviver_of(u) == bot:
			Downed.stop_revive(u, bot)
	if bot.has_method("_dn_medic_end"):
		bot.call("_dn_medic_end")


static func medics() -> Dictionary:
	return _medics


static func _assign_medics() -> void:
	var now := Time.get_ticks_msec()
	var per_team := {}
	for id in _medics.keys():
		var m: Dictionary = _medics[id]
		var b = m.get("bot", null)
		var u = m.get("unit", null)
		var stale: bool = not is_instance_valid(b) or not is_instance_valid(u) or not Downed.is_downed(u) \
				or Downed.is_downed(b) or (b.has_method("is_dead") and b.call("is_dead")) \
				or now - int(m["t0"]) > int(Balance.DN_MEDIC_GIVEUP * 1000.0)
		if stale:
			if is_instance_valid(b):
				medic_release(b)
			else:
				_medics.erase(id)
			continue
		var t := Game.team_of(b)
		per_team[t] = int(per_team.get(t, 0)) + 1
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for u in Downed.units():
		var st = Downed.state_of(u)
		if st == null or st.mirror or not st.medic_roll or (st.medic != null and is_instance_valid(st.medic)):
			continue
		if st.since < Balance.DN_MEDIC_DELAY or now - st.last_hit_ms < int(Balance.DN_MEDIC_SAFE * 1000.0):
			continue
		if st.reviver != null and is_instance_valid(st.reviver):
			continue
		if int(per_team.get(st.team, 0)) >= Balance.DN_MEDICS_MAX:
			continue
		var c := Downed.body_center(u)
		var best: Node3D = null
		var bd := Balance.DN_MEDIC_RANGE
		for b in tree.get_nodes_in_group("war_ai"):
			if b == u or not is_instance_valid(b) or Game.team_of(b) != st.team or not b.has_method("_dn_medic_free"):
				continue
			if _medics.has((b as Object).get_instance_id()) or Downed.is_downed(b) or Downed.is_rising(b):
				continue
			if b.has_method("is_dead") and b.call("is_dead"):
				continue
			var d := (b as Node3D).global_position.distance_to(c)
			if d >= bd or not b.call("_dn_medic_free"):
				continue
			bd = d
			best = b
		if best == null:
			continue
		_medics[best.get_instance_id()] = {"bot": best, "unit": u, "t0": now}
		st.medic = best
		per_team[st.team] = int(per_team.get(st.team, 0)) + 1
