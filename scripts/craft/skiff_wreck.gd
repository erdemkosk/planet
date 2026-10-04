extends Node3D
## Wreck of a destroyed Mekik (skiff.gd): the scorched lower hull tumbling away, a spray of torn
## hull plates, fire and a smoke column, all under Game.gravity_at. Pieces that sink into ground
## without collision (far from the camera) stop there (density check). After LIFE seconds the
## pieces shrink away and the node frees itself.

const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")

const LIFE := 45.0
const FIRE_TIME := 12.0

var _pieces: Array = []             # RigidBody3D
var _t := 0.0
var _check_t := 0.0
var _fire_light: OmniLight3D
var _smoke: GPUParticles3D
var _fire: GPUParticles3D
var _hulk: RigidBody3D
var _hulk_mat: ShaderMaterial


## xf: the ship's transform; vel: its velocity; hulls: the hull and cabin meshes; hull_mat: a hull
## material of its own (it gets scorched).
static func spawn(parent: Node, xf: Transform3D, vel: Vector3, hulls: Array, hull_mat: ShaderMaterial) -> Node3D:
	var w: Node3D = load("res://scripts/craft/skiff_wreck.gd").new()
	parent.add_child(w)
	w.global_transform = Transform3D(Basis(), xf.origin)
	w.call("_build", xf, vel, hulls, hull_mat)
	return w


func _build(xf: Transform3D, vel: Vector3, hulls: Array, hull_mat: ShaderMaterial) -> void:
	var up := xf.basis.y.normalized()
	# The hulk: the hull itself, charred, glowing cracks that cool down.
	_hulk_mat = hull_mat
	_hulk_mat.set_shader_parameter("scorch", 1.0)
	_hulk_mat.set_shader_parameter("ember", 1.0)
	_hulk = _piece(xf, vel + up * 4.0, 650.0)
	for hm: Mesh in hulls:
		var mi := MeshInstance3D.new()
		mi.mesh = hm
		mi.material_override = _hulk_mat
		_hulk.add_child(mi)
	var cap := CollisionShape3D.new()
	var cs := CapsuleShape3D.new()
	cs.radius = 0.62
	cs.height = 4.3
	cap.shape = cs
	cap.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 1.05, 0.1))
	_hulk.add_child(cap)
	_hulk.angular_velocity = Vector3(randf_range(-1.5, 1.5), randf_range(-1.0, 1.0), randf_range(-1.5, 1.5))
	# Torn hull plates.
	var scrap := DebrisMesh.scrap_mesh()
	var smat := DebrisMesh.rock_material(Color(0.22, 0.21, 0.2), Color(0.34, 0.33, 0.31), true, true)
	for i in 9:
		var dir := (up * randf_range(0.6, 1.4) + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))).normalized()
		var s := randf_range(0.45, 1.1)
		var px := Transform3D(Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU)), xf * Vector3(0.0, 1.0, 0.0) + dir * 0.8)
		var rb := _piece(px, vel * 0.6 + dir * randf_range(6.0, 13.0), 30.0 * s)
		var m := MeshInstance3D.new()
		m.mesh = scrap
		m.material_override = smat
		m.scale = Vector3.ONE * s
		rb.add_child(m)
		var col := CollisionShape3D.new()
		var bx := BoxShape3D.new()
		bx.size = Vector3(1.0, 0.2, 0.8) * s
		col.shape = bx
		rb.add_child(col)
		rb.angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))
	_build_fire()


func _piece(xf: Transform3D, vel: Vector3, mass_kg: float) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.mass = mass_kg
	rb.collision_layer = 0
	rb.collision_mask = Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE
	rb.gravity_scale = 0.0
	rb.linear_damp = 0.05
	rb.angular_damp = 0.6
	rb.continuous_cd = true
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.15
	rb.physics_material_override = pm
	add_child(rb)
	rb.global_transform = xf
	rb.linear_velocity = vel
	_pieces.append(rb)
	return rb


func _build_fire() -> void:
	_fire_light = OmniLight3D.new()
	_fire_light.light_color = Color(1.0, 0.55, 0.25)
	_fire_light.omni_range = 9.0
	_fire_light.light_energy = 2.5
	_fire_light.position = Vector3(0.0, 1.4, 0.0)
	_hulk.add_child(_fire_light)
	_fire = _particles(30, 0.9, Color(1.0, 0.62, 0.25), true, 0.9, 2.5)
	_smoke = _particles(36, 5.0, Color(0.3, 0.29, 0.28), false, 1.6, 1.4)


func _particles(amount: int, life: float, col: Color, additive: bool, sz: float, speed: float) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.amount = amount
	e.lifetime = life
	e.local_coords = false
	e.visibility_aabb = AABB(Vector3(-20, -20, -20), Vector3(40, 40, 40))
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.7
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = speed * 0.5
	pm.initial_velocity_max = speed
	pm.damping_min = 0.4
	pm.damping_max = 0.9
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.6
	pm.scale_max = 1.3
	var cv := Curve.new()
	cv.max_value = 4.0
	cv.add_point(Vector2(0.0, 0.5))
	cv.add_point(Vector2(1.0, 2.6 if not additive else 0.4))
	var ct := CurveTexture.new()
	ct.curve = cv
	pm.scale_curve = ct
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	g.colors = PackedColorArray([Color(col, 0.0), Color(col, 0.8 if additive else 0.6), Color(col.lightened(0.2), 0.0)])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	e.process_material = pm
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = DigFx.soft_texture()
	if additive:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.albedo_color = Color(2.0, 2.0, 2.0)
	else:
		mat.roughness = 1.0
	var q := QuadMesh.new()
	q.size = Vector2.ONE * sz
	q.material = mat
	e.draw_pass_1 = q
	_hulk.add_child(e)
	e.position = Vector3(0.0, 1.3, 0.0)
	e.emitting = true
	return e


func _physics_process(delta: float) -> void:
	_t += delta
	_check_t -= delta
	var check := _check_t <= 0.0
	if check:
		_check_t = 0.25
	for rb: RigidBody3D in _pieces:
		if not is_instance_valid(rb) or rb.freeze:
			continue
		var p := rb.global_position
		var g := Game.gravity_at(p)
		rb.constant_force = g * rb.mass
		if check:
			# Sunk into ground that has no collision here: stop it where it is.
			var b = Bodies.nearest(p)
			if b != null and b.has_method("density_fast") and float(b.density_fast(p)) < -0.6:
				rb.freeze = true
	# Particles rise against the local gravity.
	if _hulk != null and is_instance_valid(_hulk):
		var up := -Game.gravity_at(_hulk.global_position).normalized()
		for e: GPUParticles3D in [_fire, _smoke]:
			if e != null:
				(e.process_material as ParticleProcessMaterial).direction = _hulk.global_transform.basis.inverse() * up
				(e.process_material as ParticleProcessMaterial).gravity = up * (1.5 if e == _smoke else 2.5)


func _process(_delta: float) -> void:
	var fk := clampf(1.0 - _t / FIRE_TIME, 0.0, 1.0)
	if _fire_light != null:
		_fire_light.light_energy = 2.5 * fk * randf_range(0.8, 1.1)
		_fire_light.visible = fk > 0.01
	if _fire != null:
		_fire.emitting = fk > 0.05
	if _smoke != null:
		_smoke.emitting = _t < LIFE - 10.0
	if _hulk_mat != null:
		_hulk_mat.set_shader_parameter("ember", fk)
	if _t > LIFE:
		var s := clampf(1.0 - (_t - LIFE) / 3.0, 0.0, 1.0)
		for rb: RigidBody3D in _pieces:
			if not is_instance_valid(rb):
				continue
			for c in rb.get_children():
				if c is MeshInstance3D:
					var mi := c as MeshInstance3D
					if not mi.has_meta("s0"):
						mi.set_meta("s0", mi.scale.x)
					mi.scale = Vector3.ONE * maxf(float(mi.get_meta("s0")) * s, 0.01)
		if s <= 0.0:
			queue_free()
