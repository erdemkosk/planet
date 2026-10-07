extends Node
## Mantling: ledge grab and climb for the on-foot player, in the style of Apex Legends, Titanfall 2
## and Modern Warfare. Jump at a crater rim, a tunnel mouth or a structure: the hands grab the edge
## and the body pulls up and over in one fluid move. player.gd owns one (`mantle`, the child right
## after `stance`). Hooks: _physics_process (physics() replaces _move_gravity while it runs),
## _process (cam_rot()) and hands_busy() (busy()). The view model asks vm_on(), vm_left(),
## vm_right(), vm_left_pose() and vm_left_w.
##   Trigger   On the ground: jump pressed (or buffered) facing a ledge MANTLE_MIN_H..MAX_H above the
##             feet. A slide into it does a slide-to-mantle. In the air: forward or jump held while
##             moving toward a ledge MANTLE_AIR_MIN_H..MAX_H above the feet (below MANTLE_MIN_H only
##             with forward held at a run), and not falling faster than MANTLE_MAX_FALL. Never in a
##             vehicle, ragdolled, dead, waiting for the ground or with a UI panel open.
##   Detection Physics rays on Game.LAYER_TERRAIN | LAYER_SHIP, so terrain and structures alike.
##             Forward rays at FWD_H find a wall: normal steeper than ~41°, facing us, within reach.
##             The first clear ray above the wall hits is the head-plus ray; the ray at 2.25 m must be
##             clear for anything to count. A ray down past the wall face finds the top, which must be
##             walkable (within MANTLE_MAX_SLOPE of up). Rays stepping back find the edge. The standing
##             capsule must fit on top: an intersect test, then a cast down onto the real floor, tried
##             twice (lower for tunnel mouths). The path must be free: capsule casts up the wall and
##             then level over the edge, retried once with more lift.
##   Motion    A scripted curve, not physics. Phase 1 pulls up along the wall: cubic Hermite, matched
##             to the run-in velocity and kept monotone, so it never bulges into the wall or rises
##             above the top. Phase 2 rolls over onto the top and leaves at MANTLE_KEEP_SPEED of the
##             run-in speed, so a sprint mantle comes out running. The body moves through
##             move_and_slide: collision-safe, and the floor state stays true. The climb aborts
##             cleanly (physics takes over with a sane velocity) when blocked (> ABORT_DEV off the
##             curve for 2 steps), knocked (MANTLE_HIT_ABORT) or ragdolled.
##   View      A pitch dip and a roll toward the leading (left) hand (cam_rot()), a small head bob (a
##             camera.position delta, like melee.gd) and an FOV ease (added to player.fov_kick). A
##             catch kicks the view by the speed it cost.
##   Hands     The left glove reaches out and plants on the edge, world-locked inside a reach envelope
##             so the body rises past it. Its fingers hook over a high edge and lie flat on a low one.
##             A full mantle plants the gun hand on the right too. The held item tucks down out of
##             view and comes back up after. Items can't be used meanwhile (player.hands_busy()). A
##             grenade already in the left hand keeps it (that hand doesn't plant); a wrist scan is
##             dropped.
##   Sound     The grab (glove on dirt or metal plus a kit rattle), the boot on the wall, a scrape on a
##             high climb, the body rolling over, the landing step. helmet_fx.gd exertion goes up, so
##             an effort breath follows.
## Multiplayer: player.mantled(from, to, height) fires at the start with the start and end feet
## positions and the ledge height over the start.

const Balance := preload("res://scripts/war/balance.gd")
const Settings := preload("res://scripts/save/settings.gd")
const VMParts := preload("res://scripts/player/vm_parts.gd")
const VMHand := preload("res://scripts/player/vm_hand.gd")

const RADIUS := 0.35                       # the player capsule (stance.gd RADIUS / STAND_H)
const STAND_H := 1.8
const EYE_H := 1.72                        # player.gd EYE_H
## Forward ray heights over the feet. The last one is the head-plus ray: it must be clear.
const FWD_H := [0.25, 0.6, 1.0, 1.4, 1.8, 2.25]
const WALL_UP := 0.75                      # a wall's normal · up below this (steeper than ~41°)
const TOP_COLUMNS := 3                     # columns (MANTLE_LEDGE_IN apart) the top is looked for in
const GAP := 0.05                          # m the capsule keeps off the wall while it rises
const LIFT := 0.07                         # m the feet clear the top going over
const LIFT_RETRY := 0.2
const END_IN := 0.12                       # m the capsule's back stands past the edge at the end
const STEP_UPS := [0.3, 0.1]               # m over the top the end capsule is tested from (tunnel mouths: low)
const EDGE_STEP := 0.075                   # m between the rays that walk back to the edge
const ABORT_DEV := 0.22                    # m off the curve (blocked)
const ABORT_RISE := 1.5                    # m/s upward kept at most when the hands let go
const V1Y := 0.35                          # m/s still rising at the top of the pull
const RECOVER := 0.35                      # s the view and hands take to settle after the end
const RAISE_T := 0.26                      # s the held item takes to come back up
const HAND_SIDE := 0.2                     # m left / right of the centre where the hands plant
# Hand frames (scripts/player/vm_hand.gd): the palm's contact point (the rubber pad's crown, palm
# normal ±X) and the bottom of the right fist round its grip.
const PALM_L := Vector3(-0.0165, -0.046, 0.025)
const FIST_R := Vector3(0.025, -0.086, 0.02)
# Reach envelopes (view model space: camera space before the arms' FOV scale): the sleeve stays on
# the arm. The bottom of the frame is near y = -0.7 × depth there.
const LEFT_MIN := Vector3(-0.45, -0.52, -0.62)
const LEFT_MAX := Vector3(-0.05, 0.12, -0.24)
const RIGHT_MIN := Vector3(0.06, -0.52, -0.62)
const RIGHT_MAX := Vector3(0.45, 0.12, -0.26)
const VIS_Y := Vector2(-0.24, -0.5)        # the plant's lowest y at the grab .. once pressed (_plant_target)
# The held item tucked away (camera space, about the eye; like hand_action.gd right_lower, deeper).
const TUCK_ROT := Vector3(-0.55, 0.3, 0.3)
const TUCK_POS := Vector3(0.05, -0.17, 0.07)
const GUN_YAW := 0.35                      # rad the planted gun hand turns the barrel in (left)
const GUN_PITCH := 0.12                    # rad muzzle down
# Glove poses ([spread, flex1, flex2, flex3] per digit, vm_hand.gd): a flat palm push (fingers spread
# and lying on the top) and a hook (palm on the lip, fingers curled over the edge).
const PLANT := [0.14, 0.26, 0.1, 0.05, 0.03, 0.26, 0.1, 0.05, -0.08, 0.27, 0.1, 0.05, -0.2, 0.28, 0.1, 0.05,
		0.35, 0.12, 0.1, 0.0]
const HOOK := [0.08, 0.95, 0.75, 0.35, 0.0, 1.0, 0.8, 0.38, -0.05, 1.02, 0.8, 0.38, -0.12, 1.05, 0.8, 0.36,
		0.25, 0.35, 0.3, 0.0]

var p                                      # player.gd
var active := false                        # the climb runs (the movement is ours)
var height := 0.0                          # m: the ledge over the start feet (current / last mantle)
var mantles := 0                           # count (probes, stats)
var vm_left_w := 0.0                       # left plant weight shown this frame (the fingers)

var _cd := 0.0
var _probe_cd := 0.0
var _probe_fail_deep := false              # the last probe found a wall (the expensive part ran)
var _cast: CapsuleShape3D                  # the standing capsule, a hair slimmer (path / room casts)
var _space: PhysicsDirectSpaceState3D
# The path: start feet, frame (up, in), local targets along `_fwd` (x) and `_up` (y).
var _p0 := Vector3.ZERO
var _up := Vector3.UP
var _fwd := Vector3.FORWARD
var _x1 := 0.0
var _y1 := 0.0
var _x2 := 0.0
var _y2 := 0.0
var _x_edge := 0.0
var _t1 := 0.3
var _t2 := 0.2
var _m0x := 0.0
var _m0y := 0.0
var _v1x := 0.0
var _v_exit := 0.0
var _t := 0.0                              # physics time into the climb
var _blocked := 0
var _vel_set := Vector3.ZERO               # the velocity we left on the body (a change: an outside push)
var _jump_out := false
var _high := 0.0                           # 0 quick vault .. 1 full two-handed mantle
var _edge_l := Vector3.ZERO                # world plant points of the hands
var _edge_r := Vector3.ZERO
var _metal := false
# Visuals (render time: they run on through the recovery after the climb).
var _vis := false
var _vt := 0.0
var _end_vt := INF                         # visual time the climb ended / aborted
var _aborted := false
var _hook := 0.0
var _sfx_q: Array = []                     # [visual time, name, dB, pitch]
var _cam_off := Vector3.ZERO               # what this node added to camera.position
var _fov := 0.0
var _fov_applied := false


func setup(player) -> void:
	p = player
	_cast = CapsuleShape3D.new()
	_cast.radius = RADIUS - 0.01
	_cast.height = STAND_H - 0.02


static func _mask_probe() -> int:
	return Game.LAYER_TERRAIN | Game.LAYER_SHIP


static func _mask_body() -> int:
	return Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE


# =================================================================================================
# Hooks (player.gd)
# =================================================================================================

## Physics step (player.gd _physics_process, instead of _move_gravity): runs the climb or looks for a
## ledge to start one. True when it moved the body this step (the walk is skipped).
func physics(delta: float) -> bool:
	_cd = maxf(_cd - delta, 0.0)
	_probe_cd = maxf(_probe_cd - delta, 0.0)
	if active:
		return _step(delta)
	if _cd > 0.0 or not _can_start() or not _try_start():
		return false
	return _step(delta)


## The hands are on the ledge / the item is tucked (player.hands_busy(): items can't be used). The
## tail of the item coming back up is free.
func busy() -> bool:
	return active or (_vis and _w_tuck() > 0.35)


## Extra camera rotation (player.gd _process): the dip and the roll toward the leading hand.
func cam_rot() -> Vector3:
	if not _vis:
		return Vector3.ZERO
	var u := _vt / maxf(_t1 + _t2, 0.05)
	var k := lerpf(0.55, 1.0, _high) * _fade()
	return Vector3(-Balance.MANTLE_CAM_DIP * k * _bump(u, 0.0, 0.4, 0.95), 0.0,
			Balance.MANTLE_CAM_ROLL * k * _bump(u, 0.05, 0.38, 1.0))


# =================================================================================================
# Start: the trigger and the ledge probe
# =================================================================================================

func _can_start() -> bool:
	if p == null or p.vehicle != null or p.is_ragdolled() or p.is_dead() or p.waiting_ground or p.zero_g:
		return false
	return not Game.ui_panel_open()


func _try_start() -> bool:
	var g: Vector3 = p.gravity_vec
	if g.length_squared() < 1e-4:
		return false
	var up := -g.normalized()
	var fwd: Vector3 = -(p.global_transform.basis.z as Vector3)
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-4:
		return false
	fwd = fwd.normalized()
	var inp := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var v: Vector3 = p.velocity
	var vy := v.dot(up)
	var vh := v - up * vy
	var run_in := vh.dot(fwd)
	var floor_now: bool = p.is_on_floor()
	var coyote := float(p.get("_coyote")) if p.get("_coyote") != null else 0.0
	var buf := float(p.get("_jump_buf")) if p.get("_jump_buf") != null else 0.0
	var fwd_held := inp.y < -0.3
	var ground := false
	if (floor_now or coyote > 0.0) and (Input.is_action_just_pressed("jump") or buf > 0.0) and vy < 1.5:
		if inp.y > 0.3:
			return false                    # backing off: a plain jump
		ground = true
	elif not floor_now:
		if not (fwd_held or Input.is_action_pressed("jump")):
			return false
		if vy < -Balance.MANTLE_MAX_FALL or run_in < -0.5 or _probe_cd > 0.0:
			return false
	else:
		return false
	var r := _probe(p.global_position, up, fwd, maxf(run_in, 0.0),
			Balance.MANTLE_MIN_H if ground else Balance.MANTLE_AIR_MIN_H)
	if r.is_empty():
		if not ground and _probe_fail_deep:
			_probe_cd = 0.05                # a wall but no ledge: look again in a few steps
		return false
	# A low lip in the air: only running at it with forward held (a hop over bumpy ground is no vault).
	if not ground and float(r["h"]) < Balance.MANTLE_MIN_H and not (fwd_held and run_in > 1.0):
		return false
	_begin(r, v, up, fwd)
	return true


## Looks for a ledge in front of the feet. Returns {} or the path: h (top over the feet), h_edge,
## edge_d (distance to the edge along fwd), x1, y1, x2, y2, edge_l, edge_r, metal.
func _probe(feet: Vector3, up: Vector3, fwd: Vector3, run_in: float, min_h: float) -> Dictionary:
	_probe_fail_deep = false
	_space = p.get_world_3d().direct_space_state
	var mask := _mask_probe()
	var reach := RADIUS + Balance.MANTLE_REACH + run_in * Balance.MANTLE_REACH_LEAD
	var ray_len := reach + Balance.MANTLE_LEDGE_IN * TOP_COLUMNS + 0.2
	# A low ceiling over us: forward rays from inside its rock would see nothing.
	var ceil_h := INF
	var ch := _ray(feet + up * 1.0, feet + up * 2.4, mask)
	if not ch.is_empty():
		ceil_h = ((ch["position"] as Vector3) - feet).dot(up) - 0.08
	var d_min := INF
	var d_top := -1.0
	var h_wall := -1.0
	var h_clear := -1.0
	var d_clear := INF                     # how far the clear ray got (its hit, if any)
	for hs: float in FWD_H:
		if hs > ceil_h:
			break
		var from := feet + up * hs
		var hit := _ray(from, from + fwd * ray_len, mask)
		var d := INF
		var n := Vector3.UP
		if not hit.is_empty():
			d = ((hit["position"] as Vector3) - from).dot(fwd)
			n = hit["normal"]
		if d <= reach and n.dot(up) < WALL_UP and n.dot(-fwd) > Balance.MANTLE_WALL_FACING:
			d_min = minf(d_min, d)
			d_top = d
			h_wall = hs
			h_clear = -1.0
		elif h_wall >= 0.0 and d > d_top + Balance.MANTLE_LEDGE_IN + 0.1:
			h_clear = hs                    # open above the wall, past the column the top is probed in
			d_clear = d
			break
	if h_wall < 0.0 or h_clear < 0.0:
		return {}                          # no wall, or a wall too high (the head-plus ray is blocked)
	_probe_fail_deep = true
	# The top: straight down past the wall face, from the clear height. Still on the steep face (a
	# sloped crater rim leans back past the reach): a column further in.
	var cos_max := cos(deg_to_rad(Balance.MANTLE_MAX_SLOPE))
	var dc := d_top
	var top := {}
	for k in range(1, TOP_COLUMNS + 1):
		dc = d_top + Balance.MANTLE_LEDGE_IN * k
		if dc + 0.1 > d_clear:
			break
		var hit := _ray(feet + up * h_clear + fwd * dc, feet + up * (min_h - 0.08) + fwd * dc, mask)
		if hit.is_empty():
			break                           # a thin wall or a gap behind the face: no vault over it
		if (hit["normal"] as Vector3).dot(up) >= cos_max:
			top = hit
			break
	if top.is_empty():
		return {}
	var tp: Vector3 = top["position"]
	var h := (tp - feet).dot(up)
	if h < min_h or h > Balance.MANTLE_MAX_H or h < h_wall - 0.05:
		return {}
	# The edge: walk back toward the wall while the top is still there at about the same height.
	var edge_d := dc
	var edge := tp
	var start_h := minf(h + 0.3, h_clear)
	for k in range(1, mini(ceili((dc - d_top) / EDGE_STEP) + 1, 13)):
		var dk := dc - EDGE_STEP * k
		if dk < d_min - 0.2:
			break
		var e := _ray(feet + up * start_h + fwd * dk, feet + up * (h - 0.3) + fwd * dk, mask)
		if e.is_empty() or absf(((e["position"] as Vector3) - feet).dot(up) - h) > 0.15 \
				or (e["normal"] as Vector3).dot(up) < cos_max:
			break
		edge_d = dk
		edge = e["position"]
	var h_edge := (edge - feet).dot(up)
	# Room on top: the standing capsule past the edge, cast down onto the real floor.
	var x2 := edge_d + RADIUS + END_IN
	var foot2 := Vector3.INF
	for su: float in STEP_UPS:
		var c := feet + fwd * x2 + up * (h + su + STAND_H * 0.5)
		if _overlaps(c, up):
			continue
		var drop := su + 0.45
		var f := _cast_frac(c, -up * drop, up)
		if f >= 0.999:
			return {}                      # no floor: a drop behind the lip
		foot2 = c - up * (drop * f + _cast.height * 0.5 - 0.02)   # the cast capsule's bottom, a hair over it
		break
	if foot2 == Vector3.INF:
		return {}                          # no headroom up there (a low tunnel)
	var y2 := (foot2 - feet).dot(up)
	if y2 > Balance.MANTLE_MAX_H + 0.3 or y2 < h - 0.5:
		return {}
	var fl := _ray(foot2 + up * 0.25, foot2 - up * 0.4, mask)
	if not fl.is_empty() and (fl["normal"] as Vector3).dot(up) < cos_max:
		return {}
	# The path: up the wall (kept GAP off its nearest point), then level over the edge.
	var x1 := maxf(d_min - RADIUS - GAP, 0.0)
	var c0 := feet + up * (STAND_H * 0.5 + 0.03)
	var y1 := -1.0
	for lift: float in [LIFT, LIFT_RETRY]:
		var yy := maxf(h_edge, y2) + lift
		var c1 := feet + fwd * x1 + up * (yy + STAND_H * 0.5)
		var c2 := feet + fwd * x2 + up * (yy + STAND_H * 0.5)
		if _cast_frac(c0, c1 - c0, up) >= 0.999 and _cast_frac(c1, c2 - c1, up) >= 0.999:
			y1 = yy
			break
	if y1 < 0.0:
		return {}
	# Where the hands go: the edge left (and right) of the centre, snapped onto the top there.
	var left := up.cross(fwd).normalized()
	var col = top.get("collider")
	var metal: bool = col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & Game.LAYER_SHIP) != 0
	return {"h": h, "h_edge": h_edge, "edge_d": edge_d, "x1": x1, "y1": y1, "x2": x2, "y2": y2,
			"edge_l": _snap(edge + left * HAND_SIDE, up, mask), "edge_r": _snap(edge - left * HAND_SIDE, up, mask),
			"metal": metal}


func _ray(from: Vector3, to: Vector3, mask: int) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, [p.get_rid()])
	q.hit_back_faces = false
	return _space.intersect_ray(q)


## A hand point on the top surface near `w` (the centre line's edge height elsewhere).
func _snap(w: Vector3, up: Vector3, mask: int) -> Vector3:
	var hit := _ray(w + up * 0.3, w - up * 0.3, mask)
	if hit.is_empty() or (hit["normal"] as Vector3).dot(up) < 0.5:
		return w
	return hit["position"]


func _shape_query(center: Vector3, up: Vector3) -> PhysicsShapeQueryParameters3D:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _cast
	q.transform = Transform3D(_basis_up(up), center)
	q.collision_mask = _mask_body()
	q.exclude = [p.get_rid()]
	return q


func _overlaps(center: Vector3, up: Vector3) -> bool:
	return not _space.intersect_shape(_shape_query(center, up), 1).is_empty()


## Share of `motion` the standing capsule at `center` moves before it touches anything (1 = free).
func _cast_frac(center: Vector3, motion: Vector3, up: Vector3) -> float:
	var q := _shape_query(center, up)
	q.motion = motion
	var r := _space.cast_motion(q)
	return 1.0 if r.size() < 1 else float(r[0])


static func _basis_up(up: Vector3) -> Basis:
	var y := up.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


## Sets up the climb from a probe result and the run-in velocity.
func _begin(r: Dictionary, v: Vector3, up: Vector3, fwd: Vector3) -> void:
	active = true
	mantles += 1
	_t = 0.0
	_blocked = 0
	_jump_out = false
	_p0 = p.global_position
	_up = up
	_fwd = fwd
	_x1 = float(r["x1"])
	_y1 = float(r["y1"])
	_x2 = float(r["x2"])
	_y2 = float(r["y2"])
	_x_edge = float(r["edge_d"])
	_edge_l = r["edge_l"]
	_edge_r = r["edge_r"]
	_metal = bool(r["metal"])
	height = float(r["h"])
	_high = smoothstep(Balance.MANTLE_VAULT_H - 0.15, Balance.MANTLE_VAULT_H + 0.45, height)
	# Durations by height: the pull keeps up with a body already rising fast, stretches for a long
	# approach to the wall.
	var kh := clampf(inverse_lerp(Balance.MANTLE_AIR_MIN_H, Balance.MANTLE_MAX_H, _y1), 0.0, 1.0)
	var vx0 := v.dot(fwd)
	var vy0 := v.dot(up)
	_t1 = lerpf(Balance.MANTLE_T_RISE.x, Balance.MANTLE_T_RISE.y, kh)
	if vy0 > 0.5:
		_t1 = clampf(minf(_t1, _y1 / vy0 * 1.15), Balance.MANTLE_T_RISE.x, Balance.MANTLE_T_RISE.y)
	if _x1 > 0.05:
		_t1 = clampf(maxf(_t1, _x1 / maxf(vx0, 2.5)), Balance.MANTLE_T_RISE.x, Balance.MANTLE_T_RISE.y + 0.12)
	_t2 = lerpf(Balance.MANTLE_T_OVER.x, Balance.MANTLE_T_OVER.y, kh)
	# Speed kept out onto the top.
	var hs_in := (v - up * vy0).length()
	var d2 := maxf(_x2 - _x1, 0.05)
	_v_exit = clampf(hs_in * lerpf(Balance.MANTLE_KEEP_SPEED.x, Balance.MANTLE_KEEP_SPEED.y, _high),
			Balance.MANTLE_EXIT_SPEED.x, Balance.MANTLE_EXIT_SPEED.y)
	_v_exit = minf(_v_exit, 2.8 * d2 / _t2)
	# Hermite tangents, capped so each axis is monotone (Fritsch-Carlson: ≤ 3× the secant).
	_m0x = clampf(vx0, 0.0, 2.6 * _x1 / _t1) * _t1 if _x1 > 0.001 else 0.0
	_m0y = clampf(vy0, 0.0, 2.6 * _y1 / _t1) * _t1
	# Speed at the top of the pull: a run-in keeps most of its pace through a vault.
	_v1x = minf(maxf(d2 / _t2 * 0.55, minf(vx0, _v_exit) * 0.8), minf(2.6 * _x1 / _t1, 2.6 * d2 / _t2)) \
			if _x1 > 0.001 else 0.0
	# The catch: the hands stop what the curve can't keep (a fall, a run into the wall).
	var lost := maxf(vx0 - _m0x / _t1, 0.0) + maxf(-vy0, 0.0)
	var pk = p.get("_punch")
	if pk is Vector3:
		p.set("_punch", (pk as Vector3) + Vector3(-0.012 - 0.004 * minf(lost, 6.0), 0.0, 0.006))
	# Out of a slide / a crouch (standing room was checked by the path casts).
	var st = p.get("stance")
	if st != null and (st.sliding or st.crouched):
		st.on_jump()
	var ha = p.get("hand_action")
	if ha != null and str(ha.get("state")) == "scan":
		ha.cancel()                         # the wrist scan is dropped, a grenade stays in the hand
	p.jetting = false
	p.set("_jet_power", 0.0)
	p.set("_jump_buf", 0.0)
	_vel_set = v
	# Visuals from the start.
	_vis = true
	_vt = 0.0
	_end_vt = INF
	_aborted = false
	_queue_sounds()
	var hf := _helmet()
	if hf != null:
		hf.exertion = minf(float(hf.exertion) + lerpf(Balance.MANTLE_EXERTION.x, Balance.MANTLE_EXERTION.y, _high), 1.0)
		if "intensity" in hf:
			hf.intensity = maxf(float(hf.intensity), lerpf(0.15, 0.32, _high))
	if p.has_signal("mantled"):
		p.mantled.emit(_p0, _pos_at(_t1 + _t2), height)


# =================================================================================================
# The climb
# =================================================================================================

## One physics step of the climb. False when it aborted before moving (the walk runs this step).
func _step(delta: float) -> bool:
	if p.vehicle != null or p.is_ragdolled() or p.is_dead():
		_abort(Vector3.ZERO)
		return false
	# An outside push since our last step (a hit's knockback, a blast): the grab is lost.
	if ((p.velocity as Vector3) - _vel_set).length() > Balance.MANTLE_HIT_ABORT:
		_abort(p.velocity)
		return false
	if _t > (_t1 + _t2) * 0.6 and Input.is_action_just_pressed("jump"):
		_jump_out = true                    # jump again near the end: off the top at once
	_t += delta
	var total := _t1 + _t2
	var done := _t >= total
	var tt := minf(_t, total)
	var target := _pos_at(tt)
	var vel := _vel_at(tt)
	if done:
		# Out onto the top at the kept speed, nudged down so the floor takes the body this step.
		vel = _fwd * _v_exit
		target += (vel - _up * 1.5) * delta
	p.velocity = (target - (p.global_position as Vector3)) / maxf(delta, 1e-4)
	p.move_and_slide()
	if (p.global_position as Vector3).distance_to(target) > ABORT_DEV:
		_blocked += 1
		if _blocked >= 2:
			_abort(vel.limit_length(4.0))  # blocked: physics takes over where we are
			return true
	else:
		_blocked = 0
	p.velocity = vel
	_vel_set = vel
	if done:
		_finish()
	return true


## Landed on the top: the walk takes over with the kept speed (a jump pressed at the end goes now).
func _finish() -> void:
	active = false
	_cd = Balance.MANTLE_COOLDOWN
	_end_vt = minf(_end_vt, maxf(_vt, _t1 + _t2 - 0.02))   # (render time may trail the physics)
	var on_floor: bool = p.is_on_floor()
	p.velocity = _fwd * _v_exit + (Vector3.ZERO if on_floor else -_up * 1.0)
	_vel_set = p.velocity
	p.set("_jump_hold", 0.0)
	p.set("_jump_buf", 0.12 if _jump_out else 0.0)
	p.set("_coyote", 0.12 if on_floor else 0.0)
	p.set("_last_fall", 0.0)
	p.set("_was_on_floor", on_floor)
	var lv = p.get("_land_vel")
	if lv != null:
		p.set("_land_vel", float(lv) - lerpf(0.12, 0.22, _high))   # a small landing dip (player.gd spring)


## Drops the climb (blocked, knocked, ragdolled): the body keeps `vel`, the hands let go (so no
## more of the pull's rise than ABORT_RISE carries on).
func _abort(vel: Vector3) -> void:
	if not active:
		return
	active = false
	_aborted = true
	_cd = Balance.MANTLE_COOLDOWN * 0.5
	_end_vt = minf(_end_vt, _vt)
	_sfx_q.clear()
	var vu := vel.dot(_up)
	if vu > ABORT_RISE:
		vel -= _up * (vu - ABORT_RISE)
	if p != null and is_instance_valid(p) and p.vehicle == null and not p.is_ragdolled():
		p.velocity = vel
	_vel_set = vel


## Feet position on the climb at time tt (world).
func _pos_at(tt: float) -> Vector3:
	var x: float
	var y: float
	if tt < _t1:
		var s := tt / _t1
		x = _herm(0.0, _x1, _m0x, _v1x * _t1, s)
		y = _herm(0.0, _y1, _m0y, V1Y * _t1, s)
	else:
		var s := clampf((tt - _t1) / _t2, 0.0, 1.0)
		x = _herm(_x1, _x2, _v1x * _t2, _v_exit * _t2, s)
		# Level over the lip (with the last of the rise), down onto the top once the capsule's round
		# bottom is past the edge.
		var drop := smoothstep(_x_edge + RADIUS * 0.5, _x2, x)
		y = _y1 + V1Y * _t2 * s * (1.0 - s) * (1.0 - s) + (_y2 - _y1) * drop
	return _p0 + _fwd * x + _up * y


func _vel_at(tt: float) -> Vector3:
	var total := _t1 + _t2
	var a := maxf(tt - 0.004, 0.0)
	var b := minf(tt + 0.004, total)
	if b - a < 1e-4:
		return Vector3.ZERO
	return (_pos_at(b) - _pos_at(a)) / (b - a)


## Cubic Hermite from a to b over s 0..1 with end tangents m0 / m1 (already × the duration).
static func _herm(a: float, b: float, m0: float, m1: float, s: float) -> float:
	var s2 := s * s
	var s3 := s2 * s
	return (2.0 * s3 - 3.0 * s2 + 1.0) * a + (s3 - 2.0 * s2 + s) * m0 + (-2.0 * s3 + 3.0 * s2) * b + (s3 - s2) * m1


# =================================================================================================
# Per frame: the view, the sounds
# =================================================================================================

func _process(delta: float) -> void:
	if p == null:
		return
	var on_foot: bool = p.vehicle == null and not p.is_ragdolled() and not p.is_dead()
	if not on_foot:
		if active:
			_abort(Vector3.ZERO)
		if _vis:
			_vis = false
			_sfx_q.clear()
			vm_left_w = 0.0
		_apply_view(0.0, Vector3.ZERO)
		return
	if not _vis:
		_apply_view(0.0, Vector3.ZERO)
		return
	_vt += delta
	_play_due()
	var total := maxf(_t1 + _t2, 0.05)
	if not active and _vt > minf(total, _end_vt) + RECOVER:
		_vis = false
		vm_left_w = 0.0
		_apply_view(0.0, Vector3.ZERO)
		return
	var u := _vt / total
	var k := lerpf(0.55, 1.0, _high) * _fade()
	# Head: a give as the hands take the weight, a lift as the arms press, a lean over the top.
	var off := Vector3(0.0, -0.018 * k * _bump(u, 0.08, 0.22, 0.5) + 0.012 * k * _bump(u, 0.45, 0.7, 0.95),
			-0.02 * k * _bump(u, 0.5, 0.8, 1.05))
	_apply_view(Balance.MANTLE_FOV * k * _bump(u, 0.2, 0.65, 1.15), off)


## Fades the view effects out fast after an abort.
func _fade() -> float:
	if not _aborted:
		return 1.0
	return 1.0 - clampf((_vt - _end_vt) / 0.2, 0.0, 1.0)


## Applies the FOV ease (on top of the stance's kick in player.fov_kick; guns add it themselves, other
## items get it here) and the head offset (a delta on camera.position).
func _apply_view(fov: float, off: Vector3) -> void:
	var cam: Camera3D = p.camera
	if cam == null:
		return
	_fov = fov
	if _fov > 0.01:
		p.fov_kick = float(p.fov_kick) + _fov
	var it = p.items[p.current_item] if p.current_item < p.items.size() else null
	var gun: bool = it != null and it.get("pose_override") != null and it.equipped
	if gun:
		_fov_applied = false
	elif _fov > 0.01:
		cam.fov = Settings.fov + float(p.fov_kick)
		_fov_applied = true
	elif _fov_applied:
		cam.fov = Settings.fov + float(p.fov_kick)
		_fov_applied = false
	if off != _cam_off:
		cam.position += off - _cam_off
		_cam_off = off


## 0 before a, up to 1 at b, back to 0 at c (smoothsteps).
static func _bump(u: float, a: float, b: float, c: float) -> float:
	if u <= a or u >= c:
		return 0.0
	if u < b:
		return smoothstep(a, b, u)
	return 1.0 - smoothstep(b, c, u)


static func _ease(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


func _queue_sounds() -> void:
	_sfx_q.clear()
	var reach := _reach_t()
	var total := _t1 + _t2
	_sfx_q.append([0.0, "cloth", -17.0, 1.1])
	# The grab: glove on dirt or metal, the kit rattling.
	_sfx_q.append([reach, "grip", -10.0, 1.0])
	if _metal:
		_sfx_q.append([reach, "tap", -14.0, 1.05])
		_sfx_q.append([reach + 0.02, "clunk", -22.0, 1.15])
	else:
		_sfx_q.append([reach, "melee_dirt", -21.0, 1.25])
	_sfx_q.append([reach + 0.03, "rattle", -21.0, 0.95])
	if _high > 0.5:
		_sfx_q.append([reach + 0.08, "grip", -14.0, 0.92])         # the gun hand lands too
		_sfx_q.append([_t1 * 0.6, "slide_in", -23.0, 1.25])        # boots scraping up the face
	_sfx_q.append([_t1 * 0.4, "step", -19.0, 1.05])                # a boot on the wall
	_sfx_q.append([_t1 + _t2 * 0.25, "cloth_long" if _high > 0.5 else "cloth", -22.0, 1.05])
	_sfx_q.append([total, "step", -13.0, 0.98])                    # the landing step
	_sfx_q.append([total + 0.02, "gear", -22.0, 1.0])


func _play_due() -> void:
	if _sfx_q.is_empty():
		return
	for i in range(_sfx_q.size() - 1, -1, -1):
		var e: Array = _sfx_q[i]
		if _vt >= float(e[0]):
			_sfx_q.remove_at(i)
			if Game.sfx != null and is_instance_valid(Game.sfx):
				Game.sfx.play(str(e[1]), float(e[2]), float(e[3]))


static func _helmet() -> Node:
	if Game.has_meta("helmet_fx"):
		var h = Game.get_meta("helmet_fx")
		if is_instance_valid(h):
			return h
	return null


# =================================================================================================
# Hands (scripts/player/viewmodel.gd _apply / _update_fingers)
# =================================================================================================

func vm_on() -> bool:
	return _vis


func _reach_t() -> float:
	return clampf(_t1 * 0.45, 0.07, 0.15)


## The left plant: reached out, held while the body rises past it, let go early in the roll over.
func _w_left() -> float:
	var up := smoothstep(0.0, _reach_t(), _vt)
	var rel := minf(_t1 + _t2 * 0.3, _end_vt)
	return minf(up, 1.0 - smoothstep(rel, rel + 0.16, _vt))


## The gun hand's plant (full mantles), a beat after the left, off sooner.
func _w_right() -> float:
	var a := 0.05
	var up := smoothstep(a, a + _reach_t() + 0.03, _vt)
	var rel := minf(_t1 + _t2 * 0.1, _end_vt)
	return minf(up, 1.0 - smoothstep(rel, rel + 0.14, _vt)) * _high


## The held item tucked away: down at once, back up as the feet find the top.
func _w_tuck() -> float:
	var up := smoothstep(0.0, 0.1, _vt)
	var e := minf(_t1 + _t2, _end_vt) - 0.06
	return minf(up, 1.0 - smoothstep(e, e + RAISE_T, _vt))


## Left rig transform (camera space) with the plant blended in. A grenade in the left fist keeps it.
func vm_left(lxf: Transform3D) -> Transform3D:
	vm_left_w = 0.0
	if not _vis or p.camera == null:
		return lxf
	var w := _w_left()
	var ha = p.get("hand_action")
	if ha != null:
		w *= 1.0 - clampf(float(ha.left_w), 0.0, 1.0)
	if w <= 0.001:
		return lxf
	vm_left_w = w
	return lxf.interpolate_with(_plant_xf(_edge_l), _ease(w))


## Right rig transform (camera space; arm_xf: the glove's frame in the hand, viewmodel right_arm)
## with the tuck and, on a full mantle, the gun hand pressed onto the ledge.
func vm_right(rxf: Transform3D, arm_xf := Transform3D()) -> Transform3D:
	if not _vis or p.camera == null:
		return rxf
	var out := rxf
	var wt := _w_tuck()
	if wt > 0.001:
		var e := _ease(wt) * lerpf(0.8, 1.0, _high)
		out = Transform3D(Basis.from_euler(TUCK_ROT * e), TUCK_POS * e) * out
	var wr := _w_right()
	if wr > 0.001:
		out = out.interpolate_with(_gun_plant_xf(arm_xf), _ease(wr))
	return out


## The left glove's fingers on the edge: hooked over a high lip, flat on a low top.
func vm_left_pose() -> PackedFloat32Array:
	return VMHand.lerp_pose(VMHand.pose_of(PLANT), VMHand.pose_of(HOOK), _hook)


## A world point and direction in view model space (camera space with the arms' narrower FOV:
## vm_parts.gd fov_scale).
func _to_vm(w: Vector3) -> Vector3:
	var lp: Vector3 = (p.camera as Camera3D).global_transform.affine_inverse() * w
	var k := VMParts.fov_scale()
	return Vector3(lp.x / k, lp.y / k, lp.z)


func _dir_vm(d: Vector3) -> Vector3:
	var lp: Vector3 = (p.camera as Camera3D).global_transform.basis.inverse() * d
	var k := VMParts.fov_scale()
	return Vector3(lp.x / k, lp.y / k, lp.z).normalized()


## How far the press has gone: 0 at the grab .. 1 as the hands let go.
func _push() -> float:
	return smoothstep(_reach_t(), _t1 + _t2 * 0.3, _vt)


## A plant target in view model space: on the world point while that is in view (a high edge, or
## looking down), else no lower than a line that starts at the bottom of the frame at the grab and
## sinks out of view as the arms press (a chest-high edge is below the 75° view at the grab: the
## hand still lands in view, then pushes down past the frame), inside the reach envelope.
func _plant_target(w: Vector3, lo: Vector3, hi: Vector3) -> Vector3:
	var tgt := _to_vm(w)
	tgt.y = maxf(tgt.y, lerpf(VIS_Y.x, VIS_Y.y, _push()))
	return tgt.clamp(lo, hi)


## The left glove planted on world point w: palm down on the top (back of the hand up, fingers in
## over the ledge), pitched up into a hook while the edge is still high in view (and a little at the
## grab, the forearm more level as it reaches).
func _plant_xf(w: Vector3) -> Transform3D:
	var tgt := _plant_target(w, LEFT_MIN, LEFT_MAX)
	var u := _dir_vm(_up)
	var f := _dir_vm(_fwd)
	f = (f - u * f.dot(u)).normalized()
	var r := f.cross(u).normalized()
	_hook = clampf(inverse_lerp(-0.32, -0.02, tgt.y), 0.0, 1.0)
	# Left hand frame: the palm faces +X, the index side +Y, the fingers -Z.
	var b := Basis(r, lerpf(-0.08, 0.62, maxf(_hook, (1.0 - _push()) * 0.5))) * Basis(-u, r, -f)
	var at := tgt + f * lerpf(0.06, 0.0, _hook) + u * 0.004
	return Transform3D(b, at - b * PALM_L)


## The gun hand pressed onto the ledge right of the centre: the fist's bottom on the top, the grip
## upright, the barrel turned in a little and down over the ledge.
func _gun_plant_xf(arm_xf: Transform3D) -> Transform3D:
	var tgt := _plant_target(_edge_r, RIGHT_MIN, RIGHT_MAX)
	var u := _dir_vm(_up)
	var f := _dir_vm(_fwd)
	f = (f - u * f.dot(u)).normalized().rotated(u, GUN_YAW)
	var r := f.cross(u).normalized()
	var b := Basis(r, -GUN_PITCH) * Basis(r, u, -f)
	return Transform3D(b, tgt + u * 0.003 - b * (arm_xf * FIST_R))
