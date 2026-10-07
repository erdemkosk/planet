extends Node3D
## Physical ragdoll for an astronaut body (the player, later the AI rival bot). Built from the
## astronaut model's bones: one RigidBody3D per body part joined with limited Generic6DOF joints
## (rest pose = joint zero), per-part gravity (Game.gravity_at), impact thuds and a follow camera.
## The model's bones are driven from the bodies every frame. When the body has settled,
## `finished(pelvis_pos, forward)` tells the owner to stand up there.
## start(owner, vel, min_time) needs owner.astronaut (astronaut.gd) and owner.camera (the view it
## takes over from); a bot without a camera can pass a dummy Camera3D.

signal finished(pelvis_pos: Vector3, forward: Vector3)

const MASK := 1 | 2 | 4        # terrain | ship | vehicles (Game.LAYER_*)
const LOW_G := 0.3            # m/s² — below this the ragdoll recovers floating, no get-up
const ZERO_G_TUMBLE := 0.85
const LIMB_REL_MAX := 15.0    # m/s: a limb's speed relative to the pelvis (keeps the joints together;
							  # 15 leaves room for hit_reactor's torso kick at the hit point)
const DEG := PI / 180.0
const TORSO_SPIN_K := 1.4     # rad/s per (m/s × m of lever): kick_torso's topple / twist spin
const TORSO_SPIN_MAX := 4.0   # rad/s cap of that spin (2026-10-06 tok: 5 -> 4)
const ANG_MAX := 22.0         # rad/s: any part spinning faster is clamped (a solver blow-up never launches it)
const SPEED_MAX := 30.0       # m/s: pelvis speed cap unless `escape` (a corpse flung into space on purpose)
## 2026-10-06 tok: heavier bodies (they fall and slump instead of flying and bouncing): linear damping
## (was 0.05), torso / limb angular damping (was 0.9 / 0.4), bounce (was 0.12), friction (was 0.8), and
## the random start spin per m/s of launch (was 0.25, at most 6 rad/s).
const LIN_DAMP := 0.35
const ANG_DAMP_TORSO := 1.3
const ANG_DAMP_LIMB := 0.6
const BOUNCE := 0.05
const FRICTION := 1.0
const SPIN_PER_MS := 0.18
const SPIN_MAX := 4.0
## I / m (m²) of each part about a cross axis (from its shapes), for kick_part's spin.
const PART_K2 := {"pelvis": 0.018, "chest": 0.035, "head": 0.012, "uarm0": 0.012, "uarm1": 0.012,
		"farm0": 0.016, "farm1": 0.016, "thigh0": 0.02, "thigh1": 0.02, "shin0": 0.02, "shin1": 0.02}

var player
var astronaut
var cam: Camera3D
var bodies := {}                # name -> RigidBody3D
var _bone_of := {}              # name -> bone Node3D
var _fixed: Array = []          # bones kept at their rest local transform (spine, hands, feet)
var _prev_v := {}
var _t := 0.0
var _min_t := 2.5
var _max_t := 7.0
var _settle := 0.0
var _thud_cd := 0.0
var _shake := 0.0
var _cam_yaw := 0.0
var _cam_pos := Vector3.ZERO
var _cam_fwd := Vector3.FORWARD
var _done := false
var _getup_t := -1.0
var zero_g_end := false        # finished by the weightless quick-recovery path
var no_float_recover := false  # e.g. while dead: stay limp
var _getup_len := 1.4
var _speed_cap := SPEED_MAX     # start(): max(SPEED_MAX, the launch speed × 1.3)
var _blend_to: Camera3D
## Render interpolation (perf pass 2026-10-07): the bodies move at the 60 Hz physics rate, the screen
## runs faster (144 Hz here), so the model / follow camera are drawn between the part transforms of the
## last two physics ticks (Engine.get_physics_interpolation_fraction) instead of stepping 2-3 frames
## per tick ("ölünce kare kare"). name -> Transform3D seen at the previous / last tick.
var _rx_prev := {}
var _rx_cur := {}
## A dead body (no_float_recover) that has settled is put to sleep (Jolt: no solver / CCD cost, no
## script loop, no bone drive while asleep); anything that sets a velocity wakes it again.
const DEAD_REST_MIN := 1.5      # s after the launch...
const DEAD_REST_SETTLE := 1.0   # ...and this long settled (the _settle clock)
var _resting := false
var _rest_posed := false
var _rest_posed_for = null
var _cam_t := 0.0


## Part definitions: name, bone getter, mass, shapes [[type, size, offset]] in bone space.
func _parts() -> Array:
	var a = astronaut
	var out := [
		["pelvis", a.hips, 14.0, [["box", Vector3(0.34, 0.32, 0.27), Vector3(0, -0.03, 0)]]],
		["chest", a.chest, 22.0, [["box", Vector3(0.44, 0.5, 0.3), Vector3(0, 0.2, -0.01)],
				["box", Vector3(0.4, 0.52, 0.2), Vector3(0, 0.2, 0.23)]]],
		["head", a.head, 6.0, [["sphere", 0.17, Vector3(0, 0.15, 0)]]],
	]
	for i in 2:
		var s := str(i)
		out.append(["uarm" + s, a.shoulder[i], 3.0, [["capsule", Vector2(0.07, 0.36), Vector3(0, -0.15, 0)]]])
		out.append(["farm" + s, a.elbow[i], 2.5, [["capsule", Vector2(0.06, 0.42), Vector3(0, -0.2, 0)]]])
		out.append(["thigh" + s, a.thigh[i], 7.0, [["capsule", Vector2(0.095, 0.46), Vector3(0, -0.19, 0)]]])
		out.append(["shin" + s, a.shin[i], 5.0, [["capsule", Vector2(0.08, 0.4), Vector3(0, -0.17, 0)],
				["box", Vector3(0.14, 0.12, 0.3), Vector3(0, -0.45, -0.04)]]])
	return out


## Joints: parent, child, angular limits in degrees [x_lo, x_hi, y_lo, y_hi, z_lo, z_hi] around the
## child's rest axes (x: + forward swing for hips/shoulders, + elbow bend, - knee bend).
func _joints() -> Array:
	var out := [
		["pelvis", "chest", [-30, 40, -30, 30, -25, 25]],
		["chest", "head", [-40, 40, -60, 60, -30, 30]],
	]
	for i in 2:
		var s := str(i)
		var side := -1.0 if i == 0 else 1.0
		var zo := [-10, 110] if side > 0.0 else [-110, 10]     # arm abduction (out only)
		var zl := [-10, 50] if side > 0.0 else [-50, 10]       # leg abduction
		out.append(["chest", "uarm" + s, [-70, 170, -60, 60, zo[0], zo[1]]])
		out.append(["uarm" + s, "farm" + s, [0, 145, -5, 5, -5, 5]])
		out.append(["pelvis", "thigh" + s, [-40, 110, -30, 30, zl[0], zl[1]]])
		out.append(["thigh" + s, "shin" + s, [-150, 0, -3, 3, -3, 3]])
	return out


## Builds the ragdoll in the astronaut's rest pose (so joint limits are relative to rest), then
## moves every body to the current animated pose and launches it with `vel` (+ spin).
func start(p, vel: Vector3, min_time: float, exclude: Array = [], follow_cam := true) -> void:
	player = p
	astronaut = p.astronaut
	# Stay down longer after harder hits (2.5-4 s), like a real person catching their breath.
	_min_t = maxf(min_time, clampf(2.5 + vel.length() / 12.0, 2.5, 4.0))
	_max_t = _min_t + 4.0
	# A deliberate launch (e.g. the pusher's into-space fling) keeps its speed; anything faster than
	# that (or than SPEED_MAX) can only come from a physics blow-up and is clamped.
	_speed_cap = maxf(SPEED_MAX, vel.length() * 1.3)
	top_level = true
	# Current (animated) bone transforms.
	var parts := _parts()
	var anim := {}
	for d in parts:
		anim[d[0]] = (d[1] as Node3D).global_transform
	# Rest pose transforms: temporarily reset the pose and read them.
	var saved: Dictionary = astronaut.save_pose()
	astronaut.reset_pose()
	var rest := {}
	for d in parts:
		rest[d[0]] = (d[1] as Node3D).global_transform
	astronaut.load_pose(saved)

	for d in parts:
		var b := RigidBody3D.new()
		b.name = d[0]
		b.mass = d[2]
		b.collision_layer = 0
		b.collision_mask = MASK
		b.continuous_cd = true
		b.linear_damp = LIN_DAMP
		# Limbs and head swing loosely (they flop and trail); the torso turns heavier.
		b.angular_damp = ANG_DAMP_TORSO if d[0] in ["pelvis", "chest"] else ANG_DAMP_LIMB
		b.can_sleep = false
		var pm := PhysicsMaterial.new()
		pm.friction = FRICTION
		pm.bounce = BOUNCE
		b.physics_material_override = pm
		for s in d[3]:
			var cs := CollisionShape3D.new()
			match s[0]:
				"box":
					var bs := BoxShape3D.new()
					bs.size = s[1]
					cs.shape = bs
				"sphere":
					var ss := SphereShape3D.new()
					ss.radius = s[1]
					cs.shape = ss
				"capsule":
					var cp := CapsuleShape3D.new()
					cp.radius = s[1].x
					cp.height = s[1].y
					cs.shape = cp
			cs.position = s[2]
			b.add_child(cs)
		add_child(b)
		b.global_transform = rest[d[0]]
		for e in exclude:
			if e is PhysicsBody3D:
				b.add_collision_exception_with(e)
		bodies[d[0]] = b
		_bone_of[d[0]] = d[1]
	for j in _joints():
		_joint(bodies[j[0]], bodies[j[1]], j[2])
	_fixed = [astronaut.spine] + astronaut.hand + astronaut.foot
	# Jump to the animated pose and launch.
	var spin := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * clampf(vel.length() * SPIN_PER_MS, 1.0, SPIN_MAX)
	var center: Vector3 = anim["pelvis"].origin
	for n in bodies:
		var b: RigidBody3D = bodies[n]
		b.global_transform = anim[n]
		b.linear_velocity = vel + spin.cross(b.global_position - center) * 0.5
		b.angular_velocity = spin * 0.5
		# A corpse goes limp at once: its limbs and head get a little loose spin of their own, so it
		# crumples instead of keeping the last animated pose like a statue.
		if no_float_recover and not (n in ["pelvis", "chest"]):
			b.angular_velocity += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 2.5
		_prev_v[n] = b.linear_velocity
		_rx_prev[n] = anim[n]
		_rx_cur[n] = anim[n]

	# Follow camera (the player's; an AI body passes follow_cam = false).
	if not follow_cam:
		return
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.far = Game.CAM_FAR
	cam.near = 0.05
	add_child(cam)
	var pc: Camera3D = p.camera
	var up := _up(center)
	var f := -pc.global_transform.basis.z
	f = (f - up * f.dot(up))
	_cam_fwd = f.normalized() if f.length_squared() > 1e-4 else -p.global_transform.basis.z
	_cam_pos = pc.global_position
	cam.global_position = _cam_pos
	cam.current = true
	_shake = clampf(vel.length() / 20.0, 0.2, 1.0)


## Hit-located launch (hit_reactor.gd, net puppets): dv × the whole body's mass goes into the torso
## (chest + pelvis, split by mass so both gain the same speed) through their centres, plus a BOUNDED
## spin about (lever × dv) from where it was hit, so the body topples / twists by the hit location and
## the limbs (started with only the uniform share of the launch) trail and flop. (Applying the whole
## momentum off-centre spun the light torso at ~200 rad/s and blew the joints up: corpses shot off into
## space.) point INF: no spin. Call right after start().
## The momentum goes in as a velocity change, not apply_central_impulse(): in the frame start() made the
## bodies the physics server has not taken their mass in yet and an impulse acts on a 1 kg body (2026-10-07
## probe: a 2.6 m/s kick threw the corpse at ~50 m/s, a 22× too strong chest; two frames later right).
func kick_torso(dv: Vector3, point := Vector3.INF) -> void:
	if bodies.is_empty() or dv.length_squared() < 1e-6:
		return
	var total := 0.0
	for b in bodies.values():
		total += (b as RigidBody3D).mass
	var tm: float = (bodies["chest"] as RigidBody3D).mass + (bodies["pelvis"] as RigidBody3D).mass
	var torso_dv := dv * (total / tm)          # (the whole body's momentum, chest + pelvis alike)
	for n in ["chest", "pelvis"]:
		var rb: RigidBody3D = bodies[n]
		rb.linear_velocity += torso_dv
		if point != Vector3.INF:
			var at := (point - rb.global_position).limit_length(0.6)
			var axis := at.cross(dv)
			if axis.length_squared() > 1e-6:
				var w := minf(dv.length() * at.length() * TORSO_SPIN_K, TORSO_SPIN_MAX)
				rb.angular_velocity += axis.normalized() * w


## Impulse `j` (N·s, world) on ragdoll part `rb` at `offset` (world, from the part's origin), as a
## direct velocity change: j / mass, and a spin of offset × j over the part's inertia (PART_K2; capped
## at ANG_MAX). Use this instead of apply_impulse() on ragdoll parts: right after start() the physics
## server has not taken the parts' masses in yet and apply_impulse() acts on a 1 kg body (see
## kick_torso). Every caller (hit_reactor.gd, net_react.gd) goes through here.
static func kick_part(rb: RigidBody3D, j: Vector3, offset := Vector3.ZERO) -> void:
	if rb == null or not is_instance_valid(rb) or not j.is_finite() or not offset.is_finite():
		return
	var m := maxf(rb.mass, 0.1)
	rb.linear_velocity += j / m
	if offset.length_squared() > 1e-8:
		var k2: float = float(PART_K2.get(str(rb.name), 0.02))
		var w := offset.limit_length(0.6).cross(j) / (m * k2)
		rb.angular_velocity = (rb.angular_velocity + w).limit_length(ANG_MAX)


func _joint(a: RigidBody3D, b: RigidBody3D, lim: Array) -> void:
	var j := Generic6DOFJoint3D.new()
	add_child(j)
	j.global_transform = b.global_transform     # child's rest frame
	for ax in 3:
		var lo: float = lim[ax * 2] * DEG
		var hi: float = lim[ax * 2 + 1] * DEG
		match ax:
			0:
				j.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
				j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
				j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)
			1:
				j.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
				j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
				j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)
			2:
				j.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
				j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
				j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)
	j.exclude_nodes_from_collision = true
	j.node_a = j.get_path_to(a)
	j.node_b = j.get_path_to(b)


func _up(pos: Vector3) -> Vector3:
	var g: Vector3 = Game.gravity_at(pos)
	if g.length_squared() > 0.01:
		return -g.normalized()
	# Weightless: "up" of the nearest world (worlds are not at the scene origin).
	var b := Game.body_at(pos)
	var rel := pos - (b.global_position if b != null else Game.planet_center())
	return rel.normalized() if rel.length_squared() > 1.0 else Vector3.UP


func pelvis() -> RigidBody3D:
	return bodies["pelvis"]


func pelvis_velocity() -> Vector3:
	return pelvis().linear_velocity if not bodies.is_empty() else Vector3.ZERO


func orbit(dx: float) -> void:
	_cam_yaw -= dx


func _physics_process(delta: float) -> void:
	_rx_snap()
	if bodies.is_empty() or _done:
		return
	if _resting:
		_t += delta
		if not _rest_awake():
			if _t > _max_t:
				_finish()
			return                            # asleep: no per-part work at all
		_resting = false                      # something woke it (a shove, a dead hit): simulate again
		_settle = 0.0
	_t += delta
	_thud_cd = maxf(_thud_cd - delta, 0.0)
	var max_dv := 0.0
	_finite_guard()
	# Safety: a joint-solver blow-up (bodies starting interpenetrated, a huge off-centre kick) must
	# never fling the body away: the whole ragdoll is slowed to the cap, keeping its shape.
	var ps := pelvis().linear_velocity.length()
	if ps > _speed_cap:
		var k := _speed_cap / ps
		for n in bodies:
			(bodies[n] as RigidBody3D).linear_velocity *= k
	var pel_v := pelvis().linear_velocity
	for n in bodies:
		var b: RigidBody3D = bodies[n]
		var pos := b.global_position
		b.constant_force = Game.gravity_at(pos) * b.mass
		# A limb never races away from the pelvis faster than LIMB_REL_MAX (a shove that reached only
		# one limb would otherwise pull the joints apart before the solver catches up).
		if n != "pelvis":
			var rel := b.linear_velocity - pel_v
			if rel.length_squared() > LIMB_REL_MAX * LIMB_REL_MAX:
				b.linear_velocity = pel_v + rel.limit_length(LIMB_REL_MAX)
		if b.angular_velocity.length_squared() > ANG_MAX * ANG_MAX:
			b.angular_velocity = b.angular_velocity.limit_length(ANG_MAX)
		var v := b.linear_velocity
		var dv: float = (v - _prev_v[n]).length()
		_prev_v[n] = v
		if n in ["pelvis", "chest", "head", "shin0", "shin1"]:
			max_dv = maxf(max_dv, dv)
	if max_dv > 3.0 and _thud_cd <= 0.0 and Game.sfx:
		_thud_cd = 0.12
		var k := clampf((max_dv - 3.0) / 12.0, 0.0, 1.0)
		Game.sfx.play("impact" if k > 0.55 else "impact_light", lerpf(-16.0, -2.0, k), randf_range(0.85, 1.1))
		if k > 0.3:
			Game.sfx.play("step", -6.0, 0.6)
		_shake = maxf(_shake, k)
	_keep_above_ground()
	# Settle detection.
	var pv := pelvis().linear_velocity.length()
	var cv: float = bodies["chest"].linear_velocity.length()
	if pv < 0.6 and cv < 0.8:
		_settle += delta
	else:
		_settle = maxf(_settle - delta * 0.5, 0.0)
	# Weightless: no lying down / getting up — tumble briefly, spin bleeding off, then the
	# player takes over again in the floating EVA state with the momentum kept.
	var low_g: bool = Game.gravity_at(pelvis().global_position).length() < LOW_G
	if low_g:
		for n in bodies:
			var b: RigidBody3D = bodies[n]
			b.angular_damp = 2.2
		if _t > ZERO_G_TUMBLE and not no_float_recover:
			zero_g_end = true
			_finish()
			return
	if no_float_recover and not low_g and _t > DEAD_REST_MIN and _settle > DEAD_REST_SETTLE:
		_rest()
	if (_t > _min_t and _settle > 0.9) or _t > _max_t:
		_finish()


## Interpolation: remember the part transforms of the last two physics ticks (see _rx_prev).
func _rx_snap() -> void:
	for n in bodies:
		var c: Transform3D = (bodies[n] as RigidBody3D).global_transform
		_rx_prev[n] = _rx_cur.get(n, c)
		_rx_cur[n] = c


## Part `n`'s transform for drawing this frame: between the last two ticks (the live one as a fallback).
func _rx(n: String) -> Transform3D:
	var live: Transform3D = (bodies[n] as RigidBody3D).global_transform
	if not _rx_cur.has(n) or not _rx_prev.has(n):
		return live
	var f := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	var x: Transform3D = (_rx_prev[n] as Transform3D).interpolate_with(_rx_cur[n], f)
	if not x.origin.is_finite() or not x.basis.x.is_finite():
		return live
	return x


## A settled dead body goes to sleep (see DEAD_REST_MIN); _physics_process wakes the loop again when
## any part is moving.
func _rest() -> void:
	_resting = true
	_rest_posed = false
	for b in bodies.values():
		var rb := b as RigidBody3D
		rb.can_sleep = true
		rb.constant_force = Vector3.ZERO      # (a held force could keep it awake; the loop puts gravity
		rb.sleeping = true                    # back the tick anything wakes)
	# Ground dug away under a sleeping body: wake it so it drops into the hole (Jolt does not wake a
	# sleeper when the static terrain shape under it changes).
	var w = Game.body_at(pelvis().global_position)
	if w != null and is_instance_valid(w) and (w as Object).has_signal("brush_applied") \
			and not w.brush_applied.is_connected(_on_ground_edit):
		w.brush_applied.connect(_on_ground_edit)


func _on_ground_edit(center: Vector3, radius: float) -> void:
	if not _resting or bodies.is_empty():
		return
	if pelvis().global_position.distance_to(center) > radius + 2.0:
		return
	for b in bodies.values():
		(b as RigidBody3D).sleeping = false


func _rest_awake() -> bool:
	for b in bodies.values():
		if not (b as RigidBody3D).sleeping:
			return true
	return false


## Safety (2026-10-07): a non-finite part (a solver blow-up) must never reach the owner, whose get-up /
## corpse reads the bones (a bot stood up at a NaN position and stayed there). Every part with a
## non-finite position goes back to the last finite pelvis position, non-finite velocities stop.
var _last_ok := Vector3.INF
func _finite_guard() -> void:
	var pel := pelvis()
	if pel.global_position.is_finite() and pel.linear_velocity.is_finite():
		_last_ok = pel.global_position
	for b in bodies.values():
		var rb := b as RigidBody3D
		if not rb.global_position.is_finite() or not rb.global_transform.basis.x.is_finite():
			if _last_ok == Vector3.INF:
				continue
			rb.global_transform = Transform3D(Basis(), _last_ok)
			rb.linear_velocity = Vector3.ZERO
			rb.angular_velocity = Vector3.ZERO
		elif not rb.linear_velocity.is_finite() or not rb.angular_velocity.is_finite():
			rb.linear_velocity = Vector3.ZERO
			rb.angular_velocity = Vector3.ZERO


## Safety: if the pelvis tunnelled into solid rock (the edited density field, so dug tunnels and
## craters count as air), push the whole ragdoll back out along "up".
func _keep_above_ground() -> void:
	var p := pelvis().global_position
	var body := Game.body_at(p)
	if body == null or not body.has_method("density_at"):
		return
	if float(body.density_at(p)) < -1.5:
		var lift: Vector3 = body.up_at(p) * 0.5
		for n in bodies:
			var b: RigidBody3D = bodies[n]
			b.global_position += lift
			b.linear_velocity *= 0.2


func _finish() -> void:
	if _done:
		return
	_done = true
	var c: RigidBody3D = bodies["chest"]
	var pp := pelvis().global_position
	if not pp.is_finite() and _last_ok != Vector3.INF:
		pp = _last_ok                          # (never hand a non-finite spot to the owner)
	var up := _up(pp)
	var fwd := -c.global_transform.basis.z
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-4 or not fwd.is_finite():
		fwd = _cam_fwd
	finished.emit(pp, fwd.normalized())


func _process(delta: float) -> void:
	if _getup_t >= 0.0:
		_getup_t += delta
		_update_camera(delta)
		return
	if bodies.is_empty():
		return
	# Asleep and already posed at rest (for this astronaut: a corpse may have adopted us): nothing moves.
	if _resting and _rest_posed and _rest_posed_for == astronaut:
		_update_camera(delta)
		return
	# Drive the model from the bodies: the pelvis takes its body's whole transform, every other
	# bone only its body's ROTATION and sits where its parent bone's rest offset puts it. A joint
	# the solver lets drift apart (a hard shove, a fast impact) then never stretches the suit's
	# arms and legs; parents are posed before their children. Transforms drawn between the last two
	# physics ticks (_rx).
	astronaut.transform = Transform3D.IDENTITY
	(_bone_of["pelvis"] as Node3D).global_transform = _rx("pelvis")
	astronaut.spine.transform = astronaut.rest_local(astronaut.spine)
	for n in ["chest", "head", "uarm0", "uarm1", "farm0", "farm1", "thigh0", "thigh1", "shin0", "shin1"]:
		var bone: Node3D = _bone_of[n]
		var par := bone.get_parent() as Node3D
		var at: Vector3 = par.global_transform * astronaut.rest_local(bone).origin
		bone.global_transform = Transform3D(_rx(n).basis.orthonormalized(), at)
	for b in _fixed:
		b.transform = astronaut.rest_local(b)
	# Resting: once both remembered ticks hold the rest pose, this pose is final until something wakes it.
	var rp: Transform3D = _rx_prev.get("pelvis", Transform3D())
	if _resting and rp.is_equal_approx(_rx_cur.get("pelvis", Transform3D())):
		_rest_posed = true
		_rest_posed_for = astronaut
	_update_camera(delta)


## Spring-arm follow camera behind/above the pelvis (orbit with the mouse), avoids terrain.
func _update_camera(delta: float) -> void:
	if cam == null:
		return
	var target: Vector3 = astronaut.hips.global_position if bodies.is_empty() else _rx("pelvis").origin
	var up := _up(target)
	var f := _cam_fwd - up * _cam_fwd.dot(up)
	if f.length_squared() < 1e-4:
		f = up.cross(Vector3.RIGHT)
	_cam_fwd = f.normalized()          # keep the reference tangent to the ground
	f = _cam_fwd.rotated(up, _cam_yaw)
	var dir := (f * cos(0.38) - up * sin(0.38)).normalized()   # looking slightly down
	var look_at_p := target + up * 0.35
	var want := look_at_p - dir * 4.0
	var q := PhysicsRayQueryParameters3D.create(look_at_p, want, MASK)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		want = look_at_p.lerp(hit["position"], 0.85)
	_cam_pos = _cam_pos.lerp(want, 1.0 - exp(-6.0 * delta))
	_shake = maxf(_shake - delta * 2.5, 0.0)
	_cam_t += delta                    # (frame clock: _t only steps at the physics rate)
	var sh := Vector3(sin(_cam_t * 61.0), sin(_cam_t * 53.0 + 1.0), sin(_cam_t * 47.0 + 2.0)) * 0.06 * _shake
	cam.global_position = _cam_pos + sh
	if cam.global_position.distance_to(look_at_p) > 0.05:
		cam.look_at(look_at_p, up)
	# Get-up: during the last part, ease the camera into the player's own camera.
	if _getup_t >= 0.0 and _blend_to != null:
		var k := clampf((_getup_t - (_getup_len - 0.55)) / 0.55, 0.0, 1.0)
		k = k * k * (3.0 - 2.0 * k)
		if k > 0.0:
			cam.global_transform = cam.global_transform.interpolate_with(_blend_to.global_transform, k)
			cam.fov = lerpf(70.0, _blend_to.fov, k)


## The body has settled: drop the physics (the player animates the get-up on the model) and keep
## the camera orbiting, then blend it into `to_cam` over the last ~0.55 s of `duration`.
func begin_getup(to_cam: Camera3D, duration: float) -> void:
	for n in bodies:
		bodies[n].queue_free()
	for c in get_children():
		if c is Joint3D:
			c.queue_free()
	bodies.clear()
	_blend_to = to_cam
	_getup_len = duration
	_getup_t = 0.0
