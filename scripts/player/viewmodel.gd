extends Node3D
## First-person arms: astronaut suit sleeves, gloved hands, a wrist computer on the left arm and
## the held item in the right hand. Handles bob, sway, breathing, recoil and the swap animation.

const VM := preload("res://scripts/player/vm_parts.gd")
const WristDisplay := preload("res://scripts/player/wrist_display.gd")

const RIGHT_POS := Vector3(0.3, -0.195, -0.53)
const RIGHT_ROT := Vector3(-0.05, 0.15, 0.0)
const LEFT_WRIST := Vector3(-0.34, -0.43, -0.48)       # camera space, idle (one-handed items: lowered)
const LEFT_ELBOW_DIR := Vector3(-0.5, -0.45, 0.74)
const LOWER_TIME := 0.25
const RAISE_TIME := 0.38

var player
var right_rig: Node3D
var right_hand: Node3D
var left_rig: Node3D
var left_hand: Node3D

var _models := {}            # item -> model root
var _current = null          # item whose model is shown
var _pending = null          # item to show after lowering
var _on_mid: Callable
var _swap := 1.0             # 0 = raised, 1 = lowered (start lowered, raise on spawn)
var _swap_dir := -1          # +1 lowering, -1 raising, 0 idle
var _t := 0.0
var _bob_phase := 0.0
var _bob_amt := 0.0
var _sway := Vector2.ZERO
var _look := Vector2.ZERO
var _vy := 0.0
var _sprint := 0.0
var _use := 0.0
var _kick := 0.0
var _kick_vel := 0.0
var _lw_h := Vector3.ZERO      # left wrist, forearm dir, screen normal and screen center in hand frame
var _ldir_h := Vector3.BACK
var _ln_h := Vector3.UP
var _lscreen_h := Vector3.ZERO
var _lgrip := 0.0
var _hold := Vector3.ZERO
var _swim := 0.0
var _swim_ph := 0.0
var _last_grip_xf := Transform3D()
var _jitter := Vector3.ZERO

# Wrist computer.
var _wrist_timer := 0.0
var _wrist_vp: SubViewport
var _wrist_ui


func setup(p, items: Array) -> void:
	player = p
	right_rig = VM.node(self)
	right_hand = VM.node(right_rig)
	_build_hand(right_hand, 1.0)
	_build_arm(right_hand, 1.0)
	VM.bake(right_hand)
	left_rig = VM.node(self)
	left_hand = VM.node(left_rig)
	_build_hand(left_hand, -1.0)
	_build_arm(left_hand, -1.0)
	_build_wrist_computer(left_hand)
	VM.bake(left_hand)
	for it in items:
		var m: Node3D = it.build_model()
		m.visible = false
		right_hand.add_child(m)
		_models[it] = m
	_apply(0.0)


## Registers an item added after setup (research-gated weapons): builds its hidden model.
func add_item(it) -> void:
	if _models.has(it):
		return
	var m: Node3D = it.build_model()
	m.visible = false
	right_hand.add_child(m)
	_models[it] = m


func remove_item(it) -> void:
	if not _models.has(it):
		return
	(_models[it] as Node3D).queue_free()
	_models.erase(it)
	if _current == it:
		_current = null
	if _pending == it:
		_pending = null


## Starts the lower → switch → raise animation. on_mid is called when the arm is fully down.
func swap_to(item, on_mid: Callable) -> void:
	_pending = item
	_on_mid = on_mid
	if _current == null and _swap >= 1.0:
		_swap_dir = 1  # already lowered: switch immediately on next frame
	elif _swap_dir != 1:
		_swap_dir = 1


## Usable a moment before the raise fully settles (the smoothstep tail is slow and reads as lag).
func is_raised() -> bool:
	return (_swap_dir == 0 and _swap <= 0.0) or (_swap_dir == -1 and _swap <= 0.12)


func add_look(rel: Vector2) -> void:
	_look += rel


func _build_hand(h: Node3D, side: float) -> void:
	var g := VM.glove()
	var pad := VM.glove_pad()
	var orange := VM.suit_orange()
	var s := side
	# Back of hand / palm: a puffy glove shell on the outer side of the grip.
	VM.ellipsoid(h, Vector3(0.034 * s, -0.022, 0.016), Vector3(0.024, 0.052, 0.046), g, Basis(Vector3.FORWARD, 0.12 * s))
	VM.ellipsoid(h, Vector3(0.018 * s, -0.03, 0.03), Vector3(0.024, 0.046, 0.026), g)
	# Knuckle guard (armored pad) on the back of the hand.
	VM.ellipsoid(h, Vector3(0.047 * s, -0.026, -0.006), Vector3(0.011, 0.044, 0.02), pad, Basis(Vector3.FORWARD, 0.1 * s))
	VM.box(h, Vector3(0.056 * s, -0.026, 0.012), Vector3(0.004, 0.05, 0.012), orange)
	# Four fingers wrapping around the grip (index on top, pinky smallest).
	var ys := [0.0, -0.022, -0.043, -0.062]
	var rs := [0.0125, 0.0128, 0.0122, 0.0105]
	var fist := side < 0.0      # left hand: closed fist (no grip inside)
	for i in 4:
		var y: float = ys[i]
		var r: float = rs[i]
		var k := 1.0 if i < 3 else 0.88
		var p0 := Vector3(0.03 * s, y, -0.02)
		var p1 := Vector3(0.012 * s, y - 0.002, -0.044 * k)
		var p2 := Vector3(-0.016 * s, y - 0.003, -0.036 * k)
		var p3 := Vector3(-0.027 * s, y - 0.002, -0.012 * k)
		if fist:
			p1 = Vector3(0.016 * s, y - 0.002, -0.04 * k)
			p2 = Vector3(0.0, y - 0.006, -0.034 * k)
			p3 = Vector3(0.004 * s, y - 0.008, -0.014 * k)
		VM.capsule(h, p0, p1, r, g, 10)
		VM.capsule(h, p1, p2, r * 0.95, g, 10)
		VM.capsule(h, p2, p3, r * 0.9, g, 10)
	# Fill between the fingers so the glove reads as one padded surface, not separate beads.
	var f1 := Vector3(0.016 * s, 0.0, -0.04) if fist else Vector3(0.012 * s, -0.002, -0.044)
	var f2 := Vector3(0.0, -0.006, -0.034) if fist else Vector3(-0.016 * s, -0.003, -0.036)
	VM.capsule(h, f1, f1 + Vector3(0, -0.058, 0.004), 0.0108, g, 12)
	VM.capsule(h, f2, f2 + Vector3(0, -0.056, 0.004), 0.0102, g, 12)
	# Armored knuckle strip across the first finger joints.
	VM.capsule(h, Vector3(0.027 * s, 0.006, -0.03), Vector3(0.025 * s, -0.064, -0.026), 0.0085, pad, 10)
	VM.box(h, Vector3(0.034 * s, -0.029, -0.028), Vector3(0.004, 0.062, 0.01), orange)
	# Thumb over the top of the grip.
	var t0 := Vector3(0.024 * s, -0.012, 0.03)
	var t1 := Vector3(0.0, 0.012, 0.022)
	var t2 := Vector3(-0.022 * s, 0.02, 0.0)
	var t3 := Vector3(-0.026 * s, 0.014, -0.02)
	VM.capsule(h, t0, t1, 0.0135, g, 10)
	VM.capsule(h, t1, t2, 0.0125, g, 10)
	VM.capsule(h, t2, t3, 0.0115, g, 10)
	VM.ellipsoid(h, t2 + Vector3(0, 0.008, 0.002), Vector3(0.008, 0.005, 0.012), pad)


## Gauntlet, cuff and sleeve running from the wrist back toward the (off-screen) elbow.
func _build_arm(h: Node3D, side: float) -> void:
	var s := side
	var w := Vector3(0.026 * s, -0.07, 0.05)
	var dir := Vector3(0.4 * s, -0.32, 0.86).normalized()
	var g := VM.glove()
	var white := VM.suit_white()
	var orange := VM.suit_orange()
	var gray := VM.suit_gray()
	var steel := VM.metal()
	# Glove gauntlet flaring into the cuff.
	VM.seg(h, w - dir * 0.02, w + dir * 0.07, 0.032, 0.05, g)
	VM.ring(h, w + dir * 0.066, dir, 0.053, 0.007, orange)
	# Metal wrist bearing.
	VM.seg(h, w + dir * 0.072, w + dir * 0.098, 0.054, 0.054, steel)
	VM.ring(h, w + dir * 0.085, dir, 0.0565, 0.004, VM.dark_metal())
	# Sleeve with accordion joints and an orange band.
	VM.seg(h, w + dir * 0.098, w + dir * 0.6, 0.056, 0.074, white, 22)
	for d in [0.125, 0.148, 0.171]:
		VM.ring(h, w + dir * d, dir, 0.06 + d * 0.02, 0.012, gray)
	VM.seg(h, w + dir * 0.26, w + dir * 0.305, 0.067, 0.069, orange, 22)
	VM.ring(h, w + dir * 0.26, dir, 0.069, 0.004, VM.dark_metal())
	VM.ring(h, w + dir * 0.305, dir, 0.0705, 0.004, VM.dark_metal())
	for d in [0.42, 0.45, 0.48]:
		VM.ring(h, w + dir * d, dir, 0.074 + d * 0.01, 0.013, gray)
	# Small control pad / pocket on top of the forearm.
	var up := (Vector3.UP - dir * dir.dot(Vector3.UP)).normalized()
	var across := dir.cross(up).normalized()
	var b := Basis(across, up, dir)
	if side > 0.0:
		var pc := w + dir * 0.21 + up * 0.058 - across * 0.012
		VM.soft_box(h, pc, Vector3(0.045, 0.014, 0.06), 0.005, gray, b)
		var led := VM.glow(Color(0.3, 1.0, 0.5), 3.0)
		for i in 3:
			VM.box(h, pc + b * Vector3(-0.012 + i * 0.012, 0.008, -0.016), Vector3(0.007, 0.003, 0.007),
					led if i == 0 else VM.glow(Color(1.0, 0.55, 0.15), 2.0 + i), b)


## Wrist computer on the left forearm: bars for jetpack fuel and material, plus a small readout.
func _build_wrist_computer(h: Node3D) -> void:
	var w := Vector3(-0.026, -0.07, 0.05)
	var dir := Vector3(-0.4, -0.32, 0.86).normalized()
	var up := (Vector3.UP - dir * dir.dot(Vector3.UP)).normalized()
	# Rotate the screen around the forearm toward the view center.
	up = up.rotated(dir, -0.55).normalized()
	var across := up.cross(dir).normalized()
	var b := Basis(across, up, dir)
	var c := w + dir * 0.115 + up * 0.058
	_lw_h = w
	_ldir_h = dir
	_ln_h = up
	_lscreen_h = c
	var root := VM.node(h, c, b)
	var dark := VM.mat(Color(0.12, 0.13, 0.15), 0.4, 0.5)
	VM.soft_box(root, Vector3.ZERO, Vector3(0.082, 0.024, 0.104), 0.008, dark)
	VM.box(root, Vector3(0, -0.012, 0), Vector3(0.092, 0.01, 0.05), VM.suit_orange())
	VM.box(root, Vector3(0, 0.0125, 0), Vector3(0.07, 0.002, 0.09), VM.mat(Color(0.01, 0.02, 0.03), 0.15, 0.1, 0.0, 0.6))
	# Screen: a SubViewport texture on a plane (local XZ, +Y faces the viewer, -Z toward the hand).
	_wrist_vp = SubViewport.new()
	_wrist_vp.size = Vector2i(256, 312)
	_wrist_vp.transparent_bg = false
	_wrist_vp.disable_3d = true
	_wrist_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_wrist_vp)
	_wrist_ui = WristDisplay.new()
	_wrist_ui.size = Vector2(256, 312)
	_wrist_vp.add_child(_wrist_ui)
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.068, 0.083)
	var scr := VM.mesh_inst(root, pm, VM.screen_mat(_wrist_vp.get_texture(), 1.5))
	scr.position = Vector3(0, 0.0138, 0)


func _process(delta: float) -> void:
	if player == null:
		return
	_t += delta
	_update_swap(delta)
	_apply(delta)
	# Nothing carried ("Boş eller"): no arms in view, unless a hand action (grenade, medkit) uses them.
	var empty: bool = _current != null and str(_current.get("item_id")) == "hands"
	var busy: bool = player.has_method("hands_busy") and player.hands_busy()
	var show_arms := not empty or busy
	if right_rig != null and right_rig.visible != show_arms:
		right_rig.visible = show_arms
		left_rig.visible = show_arms
	_wrist_timer -= delta
	if _wrist_timer <= 0.0:
		_wrist_timer = 0.2
		_update_wrist()


func _update_swap(delta: float) -> void:
	if _swap_dir == 1:
		# Items may set holster_time / draw_time (e.g. a rifle takes longer than a hand tool).
		var lt: float = LOWER_TIME
		if _current != null and _current.get("holster_time") != null:
			lt = float(_current.get("holster_time"))
		lt *= 0.6        # swaps were 0.9-1.5 s in total; putting away is the part nobody wants to watch
		_swap = minf(_swap + delta / maxf(lt, 0.01), 1.0)
		if _swap >= 1.0:
			if _current != null and _models.has(_current):
				_models[_current].visible = false
			_current = _pending
			_pending = null
			if _current != null and _models.has(_current):
				_models[_current].visible = true
			if _on_mid.is_valid():
				_on_mid.call()
			_swap_dir = -1
	elif _swap_dir == -1:
		var rt: float = RAISE_TIME
		if _current != null and _current.get("draw_time") != null:
			rt = float(_current.get("draw_time"))
		rt *= 0.75
		_swap = maxf(_swap - delta / maxf(rt, 0.01), 0.0)
		if _swap <= 0.0:
			_swap_dir = 0


func _apply(delta: float) -> void:
	var p = player
	var vel: Vector3 = p.velocity
	var up: Vector3 = p.global_transform.basis.y
	var v_up := vel.dot(up)
	var h_speed := (vel - up * v_up).length()
	var grounded: bool = p.is_on_floor() and not p.zero_g
	var rate := 1.0 - exp(-10.0 * delta)

	# Walking bob: one full sway cycle per two steps.
	var target_bob := clampf(h_speed / 5.0, 0.0, 1.7) if grounded else 0.0
	_bob_amt = lerpf(_bob_amt, target_bob, rate * 0.6)
	# On the body's gait clock (player.gd footsteps / head bob): lowest when a foot plants.
	if grounded and p.get("astronaut") != null:
		_bob_phase = float(p.astronaut._phase) * TAU + PI * 0.5
	else:
		_bob_phase += delta * 1.0
	var sprinting: bool = grounded and h_speed > 5.0 and Input.is_action_pressed("sprint")
	_sprint = lerpf(_sprint, 1.0 if sprinting else 0.0, rate * 0.7)

	# Mouse sway (arms lag behind the view, then spring back). Heavy items (sway_scale > 1) lag
	# more and settle slower; an aimed rifle sets a small scale.
	var inertia := 1.0
	if _current != null and _current.get("sway_scale") != null:
		inertia = clampf(float(_current.get("sway_scale")), 0.2, 3.0)
	var lim := Vector2(0.07, 0.06) * inertia
	var lk := _look * (1.0 / 60.0) / maxf(delta, 0.001)      # per-frame mouse counts → 60 fps units
	var sway_target := Vector2(clampf(lk.x * 0.0011 * inertia, -lim.x, lim.x), clampf(lk.y * 0.0011 * inertia, -lim.y, lim.y))
	_sway = _sway.lerp(sway_target, rate / maxf(inertia, 1.0))
	_look = Vector2.ZERO
	_vy = lerpf(_vy, clampf(-v_up * 0.005, -0.035, 0.045), rate * 0.5)

	# Tool use: steady shake + pushback. Kick: spring impulse (scan pulse, mode switch, beacon).
	var it = _current
	var using: bool = it != null and it.using
	_use = lerpf(_use, 1.0 if using else 0.0, rate)
	if it != null and it.kick > 0.0:
		_kick_vel += it.kick * 9.0
		it.kick = 0.0
	_kick_vel += (-_kick * 220.0 - _kick_vel * 22.0) * delta
	_kick += _kick_vel * delta
	_jitter = _jitter.lerp(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)), rate * 2.0)


	var breathe := sin(_t * 1.7)
	var zero_g_drift := Vector3(sin(_t * 0.6), sin(_t * 0.83), 0.0) * (0.006 if p.zero_g else 0.0)
	var bob := Vector3(cos(_bob_phase) * 0.011, -absf(sin(_bob_phase)) * 0.013, 0.0) * _bob_amt
	var common := bob + zero_g_drift + Vector3(-_sway.x * 0.35, _sway.y * 0.3 + breathe * 0.0022 + _vy, 0.0)

	# Swap curve: ease in/out.
	var e := _swap * _swap * (3.0 - 2.0 * _swap)
	if it != null:
		_hold = _hold.lerp(it.hold_offset, 1.0 - exp(-12.0 * delta)) if _swap < 0.999 else it.hold_offset
	var rp := RIGHT_POS + common + _hold
	rp += Vector3(0.03, -0.04, 0.03) * _sprint
	rp += Vector3(0.0, -0.26, 0.06) * e
	var buzz := Vector3(sin(_t * 71.0), sin(_t * 63.0 + 1.0), 0.0) * 0.0018 * _use
	rp += Vector3(0, 0, 0.014 * _use + _kick * 0.05) + _jitter * 0.0035 * _use + buzz
	var rr := RIGHT_ROT + Vector3(_sway.y * 1.2 + breathe * 0.006, _sway.x * 1.4, -_sway.x * 0.8)
	rr += Vector3(-0.35, 0.55, 0.2) * _sprint
	rr += Vector3(-0.95, 0.15, 0.25) * e
	rr += Vector3(_kick * 0.6 + _use * 0.03, 0, 0) + _jitter * 0.02 * _use
	rr.z += cos(_bob_phase) * 0.02 * _bob_amt
	# Swimming: breaststroke — the tool hand reaches forward and sweeps out.
	var swimming: bool = p.get("swimming") == true
	_swim = lerpf(_swim, 1.0 if swimming else 0.0, rate * 0.4)
	_swim_ph += delta * (1.5 + vel.length() * 0.9)
	if _swim > 0.01:
		var sw := _swim_ph
		rp += Vector3(0.06 * maxf(0.0, cos(sw)), -0.06 + 0.03 * sin(sw), -0.1 * sin(sw)) * _swim
		rr += Vector3(0.25 * sin(sw) - 0.2, -0.35 * maxf(0.0, cos(sw)), 0.2) * _swim
	right_rig.transform = Transform3D(Basis.from_euler(rr), rp)
	# Items may move the whole hand+item rig (e.g. a rifle raised to the sights) so the hand
	# stays locked on the grip instead of the item sliding out of the hand.
	if it != null and it.get("rig_offset") is Transform3D:
		right_rig.transform = right_rig.transform * (it.get("rig_offset") as Transform3D)
	# Items with their own full pose (camera space: hip / aim / sprint / reload / recoil / bob /
	# sway all computed by the item) only get the swap lowering from here.
	if it != null and it.get("pose_override") is Transform3D and _swim < 0.01:
		var po: Transform3D = it.get("pose_override")
		var lower := Basis.from_euler(Vector3(-0.95, 0.15, 0.25) * e)
		right_rig.transform = Transform3D(lower * po.basis, po.origin + Vector3(0.0, -0.26, 0.06) * e)

	# Left arm: solve the rig from camera-space targets (wrist position, forearm direction and
	# the wrist screen facing the eye), so the pose is easy to tune and always readable.
	# Items with a second handle (left_grip) get a two-handed hold; otherwise the left arm rests
	# low, out of the way.
	var lcommon := Vector3(-common.x, common.y * 0.9, 0) + Vector3(0, -0.03 * e, 0) + Vector3(0, -0.04, 0.02) * _sprint
	var idle_xf := _left_pose(LEFT_WRIST + lcommon, LEFT_ELBOW_DIR, 0.25)
	var has_grip: bool = it != null and it.left_grip != null and _models.has(it) and _models[it].visible
	if has_grip:
		_last_grip_xf = right_rig.transform * (right_hand.global_transform.affine_inverse() * it.left_grip.global_transform)
	_lgrip = move_toward(_lgrip, 1.0 if has_grip else 0.0, delta * 4.0)
	var gk := _lgrip * _lgrip * (3.0 - 2.0 * _lgrip) * (1.0 - _swim)
	if _swim > 0.01:
		var sw2 := _swim_ph
		var swim_xf := _left_pose(Vector3(-0.2 - 0.07 * maxf(0.0, cos(sw2)), -0.2 + 0.03 * sin(sw2), -0.5 - 0.1 * sin(sw2)) + lcommon, Vector3(-0.35, -0.3, 0.88), 0.2)
		idle_xf = idle_xf.interpolate_with(swim_xf, _swim)
	var lxf := idle_xf.interpolate_with(_last_grip_xf, gk) if gk > 0.0 else idle_xf
	# Items can pull the left hand off its grip (e.g. a magazine change): left_reach is the
	# camera-space wrist target, left_reach_w the blend and left_reach_elbow the forearm direction.
	# Solving the pose from camera-space targets keeps the sleeve pointing out of view.
	if has_grip and it.get("left_reach_w") != null:
		var rw := clampf(float(it.get("left_reach_w")), 0.0, 1.0)
		if rw > 0.001:
			var elbow: Vector3 = LEFT_ELBOW_DIR
			if it.get("left_reach_elbow") != null:
				elbow = it.get("left_reach_elbow")
			var reach_xf := _left_pose(it.get("left_reach") + lcommon * 0.5, elbow, 0.3)
			lxf = lxf.interpolate_with(reach_xf, rw)
	# Optional hand actions (player.hand_action, none in this game yet) take the left arm and
	# dip the held item out of the way.
	var ha = p.get("hand_action")
	if ha != null:
		var hw := clampf(float(ha.left_w), 0.0, 1.0)
		if hw > 0.001:
			lxf = lxf.interpolate_with(_left_pose(ha.left_target + lcommon * 0.5, ha.left_elbow, 0.3), hw)
		var rl := clampf(float(ha.right_lower), 0.0, 1.0)
		if rl > 0.001:
			right_rig.transform = Transform3D(Basis.from_euler(Vector3(-0.5, 0.25, 0.15) * rl), Vector3(0.04, -0.11, 0.05) * rl) * right_rig.transform
	left_rig.transform = lxf


## Left rig transform from a camera-space wrist position and forearm direction, with the wrist
## screen turned toward the eye.
func _left_pose(wc: Vector3, elbow_dir: Vector3, up_bias: float) -> Transform3D:
	var dc := elbow_dir.normalized()
	dc = dc.rotated(Vector3.UP, -_sway.x * 0.6).rotated(Vector3.RIGHT, _sway.y * 0.5)
	var screen_c := wc + dc * 0.115
	var nc := (-screen_c).normalized().lerp(Vector3.UP, up_bias)
	nc = nc.rotated(dc, cos(_bob_phase) * 0.03 * _bob_amt)
	var bl := _map_basis(_ldir_h, _ln_h, dc, nc)
	return Transform3D(bl, wc - bl * _lw_h)


## Rotation that maps (dir_a, up_a) onto (dir_b, up_b) (ups are orthogonalized to the dirs).
static func _map_basis(dir_a: Vector3, up_a: Vector3, dir_b: Vector3, up_b: Vector3) -> Basis:
	var da := dir_a.normalized()
	var ua := (up_a - da * up_a.dot(da)).normalized()
	var db := dir_b.normalized()
	var ub := (up_b - db * up_b.dot(db)).normalized()
	var ba := Basis(da, ua, da.cross(ua))
	var bb := Basis(db, ub, db.cross(ub))
	return bb * ba.inverse()


func _update_wrist() -> void:
	var p = player
	var fuel: float = clampf(p.jet_fuel_frac(), 0.0, 1.0)
	var it = _current
	var nm: String = it.item_name if it != null else ""
	var col: Color = it.accent_color() if it != null else Color.WHITE
	var blink := fmod(_t, 0.8) < 0.4
	if _wrist_ui.set_values(fuel, Game.material, 200.0, p.gravity_vec.length() / 9.81, nm, col, blink, 1.0, p.lamp_on()):
		_wrist_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
