extends RigidBody3D
## A magazine dropped free on an empty reload (rifle.gd _drop_mag, reload_anim.gd MAG_DROPPED).
## Cosmetic and local only, never networked. A copy of the view-model magazine's mesh with world
## materials (the view-model shaders squeeze it into the near depth slice), started where the view
## model draws it, falling under the planets' pull the project's way (gravity_scale 0 + constant_force
## = Game.gravity_at · mass each step, as skiff_wreck.gd / ragdoll.gd), colliding with the terrain and
## structures (not characters). One clatter on its first impact (the "clunk" foley set at the spot, plus
## an optional metal stream from the gun). Gone after LIFE s (it shrinks away); at most MAX_ALIVE at
## once, the oldest goes first.

const LIFE := 25.0
const SHRINK := 0.6
const MAX_ALIVE := 6

static var _alive: Array = []
static var _mats := {}                 # view-model ShaderMaterial id -> world StandardMaterial3D

var _t := 0.0
var _hit := false
var _mesh: MeshInstance3D
var _mesh_b := Basis()
var _clatter: AudioStream


## Spawns a dropped magazine under `parent`: `src` the view-model magazine's (baked) mesh instance,
## `xf` its world transform, `scale` (the view model's fov_scale: same size on screen), the collision
## box (magazine space: centre, size, basis), the start velocities and an optional clatter stream.
static func spawn(parent: Node, src: MeshInstance3D, xf: Transform3D, scale: float, vel: Vector3, spin: Vector3,
		box_c: Vector3, box_s: Vector3, box_b := Basis(), clatter: AudioStream = null) -> RigidBody3D:
	if parent == null or src == null or src.mesh == null:
		return null
	var keep: Array = []
	for b in _alive:
		if is_instance_valid(b) and not (b as Node).is_queued_for_deletion():
			keep.append(b)
	_alive = keep
	while _alive.size() >= MAX_ALIVE:
		var old = _alive.pop_front()
		if is_instance_valid(old):
			(old as Node).queue_free()
	var m: RigidBody3D = load("res://scripts/items/mag_drop.gd").new()
	m.call("_build", src, scale, box_c, box_s, box_b, clatter)
	parent.add_child(m)
	m.global_transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
	m.linear_velocity = vel
	m.angular_velocity = spin
	_alive.append(m)
	return m


func _build(src: MeshInstance3D, scale: float, box_c: Vector3, box_s: Vector3, box_b: Basis, clatter: AudioStream) -> void:
	_clatter = clatter
	mass = 0.45
	gravity_scale = 0.0
	collision_layer = 0
	collision_mask = Game.LAYER_TERRAIN | Game.LAYER_SHIP
	continuous_cd = true
	linear_damp = 0.05
	angular_damp = 0.5
	contact_monitor = true
	max_contacts_reported = 2
	var pm := PhysicsMaterial.new()
	pm.friction = 0.75
	pm.bounce = 0.22
	physics_material_override = pm
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = box_s * scale
	cs.shape = bx
	cs.transform = Transform3D(box_b, box_c * scale)
	add_child(cs)
	_mesh = MeshInstance3D.new()
	_mesh.mesh = src.mesh
	_mesh_b = Basis().scaled(Vector3.ONE * scale) * src.transform.basis
	_mesh.transform = Transform3D(_mesh_b, src.transform.origin * scale)
	for i in src.mesh.get_surface_count():
		var sm: Material = src.get_surface_override_material(i)
		if sm == null:
			sm = src.mesh.surface_get_material(i)
		_mesh.set_surface_override_material(i, _world_mat(sm))
	add_child(_mesh)
	body_entered.connect(_on_body_entered)


## World stand-in for a view-model material (vm_parts.gd: lit "albedo / roughness / metallic", glow
## "color / energy"); read defensively (the shaders may change).
static func _world_mat(m: Material) -> Material:
	if not (m is ShaderMaterial):
		return m
	var sm := m as ShaderMaterial
	var gc = sm.get_shader_parameter("color")
	if gc is Color:
		var g := StandardMaterial3D.new()          # a glow strip: its current colour, not cached
		g.albedo_color = Color(0.05, 0.05, 0.05)
		g.emission_enabled = true
		g.emission = gc
		var en = sm.get_shader_parameter("energy")
		g.emission_energy_multiplier = clampf(float(en) * 0.6 if en != null else 1.5, 0.5, 4.0)
		return g
	var key := sm.get_instance_id()
	if _mats.has(key):
		return _mats[key]
	var s := StandardMaterial3D.new()
	var a = sm.get_shader_parameter("albedo")
	var r = sm.get_shader_parameter("roughness")
	var mt = sm.get_shader_parameter("metallic")
	s.albedo_color = a if a is Color else Color(0.3, 0.31, 0.33)
	s.roughness = float(r) if r != null else 0.5
	s.metallic = float(mt) if mt != null else 0.3
	_mats[key] = s
	return s


func _physics_process(delta: float) -> void:
	_t += delta
	if not sleeping:
		constant_force = Game.gravity_at(global_position) * mass
	if _t > 3.0 and linear_velocity.length() > 40.0:
		queue_free()                               # fell through ground without collision
		return
	if _t > LIFE:
		var k := 1.0 - (_t - LIFE) / SHRINK
		if k <= 0.0:
			queue_free()
			return
		_mesh.transform.basis = _mesh_b * k


func _on_body_entered(_body: Node) -> void:
	if _hit:
		return
	_hit = true
	var lvl := linear_to_db(clampf(linear_velocity.length() / 4.0, 0.25, 1.2))
	if Game.sfx != null and is_instance_valid(Game.sfx) and Game.sfx.has_method("play_at"):
		Game.sfx.play_at("clunk", global_position, -10.0 + lvl, randf_range(1.12, 1.3), 4.0)
	if _clatter != null:
		var p := AudioStreamPlayer3D.new()
		p.stream = _clatter
		p.volume_db = -12.0 + lvl
		p.pitch_scale = randf_range(0.55, 0.7)
		p.unit_size = 3.0
		p.max_distance = 40.0
		add_child(p)
		p.play()
		p.finished.connect(p.queue_free)


func _exit_tree() -> void:
	_alive.erase(self)
