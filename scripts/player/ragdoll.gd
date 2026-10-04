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
const DEG := PI / 180.0

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
var _blend_to: Camera3D


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
		b.linear_damp = 0.05
		b.angular_damp = 1.2
		b.can_sleep = false
		var pm := PhysicsMaterial.new()
		pm.friction = 0.8
		pm.bounce = 0.12
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
	var spin := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * clampf(vel.length() * 0.25, 1.0, 6.0)
	var center: Vector3 = anim["pelvis"].origin
	for n in bodies:
		var b: RigidBody3D = bodies[n]
		b.global_transform = anim[n]
		b.linear_velocity = vel + spin.cross(b.global_position - center) * 0.5
		b.angular_velocity = spin * 0.5
		_prev_v[n] = b.linear_velocity

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
	if bodies.is_empty() or _done:
		return
	_t += delta
	_thud_cd = maxf(_thud_cd - delta, 0.0)
	var max_dv := 0.0
	for n in bodies:
		var b: RigidBody3D = bodies[n]
		var pos := b.global_position
		b.constant_force = Game.gravity_at(pos) * b.mass
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
	if (_t > _min_t and _settle > 0.9) or _t > _max_t:
		_finish()


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
	var up := _up(pelvis().global_position)
	var fwd := -c.global_transform.basis.z
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-4:
		fwd = _cam_fwd
	finished.emit(pelvis().global_position, fwd.normalized())


func _process(delta: float) -> void:
	if _getup_t >= 0.0:
		_getup_t += delta
		_update_camera(delta)
		return
	if bodies.is_empty():
		return
	# Drive the model from the bodies.
	astronaut.transform = Transform3D.IDENTITY
	for n in ["pelvis", "chest", "head", "uarm0", "uarm1", "farm0", "farm1", "thigh0", "thigh1", "shin0", "shin1"]:
		(_bone_of[n] as Node3D).global_transform = (bodies[n] as RigidBody3D).global_transform
	for b in _fixed:
		b.transform = astronaut.rest_local(b)
	_update_camera(delta)


## Spring-arm follow camera behind/above the pelvis (orbit with the mouse), avoids terrain.
func _update_camera(delta: float) -> void:
	if cam == null:
		return
	var target: Vector3 = astronaut.hips.global_position if bodies.is_empty() else pelvis().global_position
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
	var sh := Vector3(sin(_t * 61.0), sin(_t * 53.0 + 1.0), sin(_t * 47.0 + 2.0)) * 0.06 * _shake
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
