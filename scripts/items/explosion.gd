extends Node3D
## Explosion (kept for the phase-2 cannonballs): area damage with falloff + a shove to everything in
## group "damageable" (Game.damage_target: the player, the AI rival bot, later the cores), impulses on
## loose rigid bodies, a crater in the planet (planet.gd crater(), carved over a few frames); and the
## show: white core flash, fireball, sparks, flying debris chunks that bounce, a dust ring and a
## shock ring along the ground, a rising smoke column, a scorch decal, a light flash, distance-delayed
## sound (crunch + low boom + synthesized body) and camera shake by distance.
## Explosion.spawn(pos, normal, {"radius", "damage", "impulse", "self_mult", "crater", "player_owned",
## "ground", "team"}): crater = crater radius in m (0 = none); team = the side that fired it (own
## structures take Balance.FRIENDLY_FIRE). Emits Game.blast(pos, radius, team).

const RifleFx := preload("res://scripts/items/rifle_fx.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")
const ArsenalAudio := preload("res://scripts/items/arsenal_audio.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")

const LIFE := 7.0
const DECAL_LIFE := 40.0
const SOUND_SPEED := 340.0

static var _tex_soft: Texture2D
static var _tex_scorch: Texture2D
static var _tex_ring: Texture2D
static var _ogg := {}
static var _boom_streams := {}
static var _boom_task := -1
static var _boom_mutex := Mutex.new()
static var _boom_pending := {}

var radius := 5.0
var damage := 140.0
var impulse := 14.0
var self_mult := 0.5
var crater := 1.6
var player_owned := true
var team := ""                   # source side for friendly fire (Game.damage_target), cfg "team"
var normal := Vector3.UP
var ground := Color(0.42, 0.36, 0.27)
var kills := 0
var hits := 0

var _t := 0.0
var _light: OmniLight3D
var _core: MeshInstance3D
var _core_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _decal: Decal
var _debris: Array = []          # {mi, vel, spin, t}
var _sounds: Array = []          # [delay, player]


## Spawns an explosion at world `pos` (normal = surface normal or up). Returns the node.
static func spawn(pos: Vector3, n: Vector3, cfg := {}) -> Node3D:
	var tree := Engine.get_main_loop() as SceneTree
	var e: Node3D = load("res://scripts/items/explosion.gd").new()
	e.radius = float(cfg.get("radius", 5.0))
	e.damage = float(cfg.get("damage", 140.0))
	e.impulse = float(cfg.get("impulse", 14.0))
	e.self_mult = float(cfg.get("self_mult", 0.5))
	e.crater = float(cfg.get("crater", 1.6))
	e.player_owned = bool(cfg.get("player_owned", true))
	e.team = str(cfg.get("team", ""))
	e.normal = n.normalized() if n.length_squared() > 0.01 else _up_at(pos)
	e.ground = cfg.get("ground", Color(0.42, 0.36, 0.27))
	var parent: Node = tree.current_scene if tree.current_scene != null else tree.root
	parent.add_child(e)
	e.global_transform = Transform3D(Basis(), pos)
	e.detonate()
	return e


## "Up" of the world (planet or moon) under pos; worlds are not at the scene origin (floating origin).
static func _up_at(pos: Vector3) -> Vector3:
	var b := Game.body_at(pos)
	var u := pos - (b.global_position if b != null else Game.planet_center())
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


## Builds the synthesized boom layers on a worker thread (call early to avoid a hitch).
static func prewarm() -> void:
	if _boom_task >= 0 or not _boom_streams.is_empty():
		return
	_boom_task = WorkerThreadPool.add_task(_build_booms, false, "explosion_audio")


static func _build_booms() -> void:
	var gen := ArsenalAudio.new()
	var out := {"boom": gen.make("boom"), "boom_far": gen.make("boom_far"), "bounce": gen.make("bounce")}
	_boom_mutex.lock()
	_boom_pending = out
	_boom_mutex.unlock()


static func synth(name: String) -> AudioStream:
	if _boom_task >= 0 and WorkerThreadPool.is_task_completed(_boom_task):
		WorkerThreadPool.wait_for_task_completion(_boom_task)
		_boom_task = -1
		_boom_mutex.lock()
		_boom_streams = _boom_pending
		_boom_mutex.unlock()
	return _boom_streams.get(name)


func detonate() -> void:
	var pos := global_position
	top_level = true
	_apply_damage(pos)
	Game.blast.emit(pos, radius, team)
	_dig(pos)
	_build_fx(pos)
	_play_sounds(pos)


# =================================================================================================
# Damage
# =================================================================================================

## Every damageable (group "damageable": the player, the AI rival bot, later cores) in the radius
## takes damage with falloff and a shove away from the blast (Game.damage_target). The shooter's own
## blast hurts it less (self_mult). Loose rigid bodies get an impulse; the camera shakes by distance.
func _apply_damage(pos: Vector3) -> void:
	var hf = HitFeel.inst() if player_owned else null
	var first := true
	var pl = Game.player
	for n in get_tree().get_nodes_in_group(Game.DAMAGEABLE):
		if not (n is Node3D) or not n.has_method("take_damage"):
			continue
		if n.has_method("is_dead") and n.is_dead():
			continue
		var c: Vector3 = (n as Node3D).global_position + (n as Node3D).global_transform.basis.y * 0.9
		var d := pos.distance_to(c)
		var rr := radius * 1.1
		if d > rr:
			continue
		var f := 1.0 - d / rr
		f = f * f * 0.55 + f * 0.45
		var dir := ((c - pos).normalized() + _up_at(c) * 0.6).normalized()
		var mult := self_mult if (n == pl and player_owned) else 1.0
		var dmg := damage * f * mult
		var r := Game.damage_target(n, dmg, pos, dir * impulse * f, team)
		hits += 1
		if r.get("killed", false):
			kills += 1
		if hf != null and n != pl:
			hf.target_hit(n, r, dmg, c, {"big": f, "quiet": not first})
			first = false
	# Loose rigid bodies (vehicles, debris).
	var sq := PhysicsShapeQueryParameters3D.new()
	var sph := SphereShape3D.new()
	sph.radius = radius
	sq.shape = sph
	sq.transform = Transform3D(Basis(), pos)
	sq.collision_mask = Game.LAYER_VEHICLE
	for h in get_world_3d().direct_space_state.intersect_shape(sq, 8):
		var rb = h.get("collider")
		if rb is RigidBody3D:
			var b := rb as RigidBody3D
			var d2 := b.global_position.distance_to(pos)
			b.apply_central_impulse((b.global_position - pos).normalized() * impulse * b.mass * 0.25 * (1.0 - d2 / radius))
	# Camera shake by distance.
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var dp := pos.distance_to(pl.global_position)
		var shake := clampf(1.0 - dp / (radius * 9.0), 0.0, 1.0)
		if shake > 0.0:
			pl.add_trauma(0.25 + shake * shake * 0.75)


## A crater in the planet under the blast (planet.gd crater(): carved over a few frames, radius
## capped at CRATER_MAX_R). `crater` is its radius in m; 0 = none.
func _dig(pos: Vector3) -> void:
	if crater <= 0.0:
		return
	var body = Bodies.nearest(pos)
	if body != null and body.has_method("crater"):
		body.crater(pos, crater)


# =================================================================================================
# Visuals
# =================================================================================================

func _build_fx(pos: Vector3) -> void:
	_ensure_textures()
	var basis_n := RifleFx._basis_y(normal)
	# Light flash.
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.62, 0.3)
	_light.omni_range = radius * 6.0
	_light.light_energy = 18.0
	_light.shadow_enabled = false
	_light.position = normal * 1.2
	add_child(_light)
	# White-hot core.
	_core = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 16
	sm.rings = 8
	_core.mesh = sm
	_core_mat = _add_mat(Color(1.0, 0.82, 0.5, 1.0), 4.0)
	_core.material_override = _core_mat
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_core.position = normal * 0.5
	_core.scale = Vector3.ONE * 0.3
	add_child(_core)
	# Shock ring along the ground.
	_ring = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(2, 2)
	qm.orientation = PlaneMesh.FACE_Y
	_ring.mesh = qm
	_ring_mat = _add_mat(Color(1.0, 0.9, 0.75, 0.6), 2.0)
	_ring_mat.albedo_texture = _tex_ring
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.transform = Transform3D(basis_n, normal * 0.15)
	_ring.scale = Vector3.ONE * 0.2
	add_child(_ring)
	var g := Game.gravity_at(pos)
	# Fireball: hot additive core puffs, then dark billows that the fire leaves behind.
	_particles({"amount": 36, "life": 0.95, "shape_r": radius * 0.14, "vmin": 1.5, "vmax": radius * 1.5,
			"damp": 5.5, "spread": 180.0, "dir": normal, "size": radius * 0.5, "scale": [0.6, 1.5, 2.2],
			"ramp": [[0.0, Color(1, 1, 0.92, 1)], [0.12, Color(1.0, 0.82, 0.4, 1)], [0.35, Color(1.0, 0.45, 0.12, 0.95)],
				[0.65, Color(0.45, 0.14, 0.04, 0.6)], [1.0, Color(0.1, 0.08, 0.07, 0)]],
			"add": true, "gravity": -g * 0.2, "pos": normal * 0.7})
	_particles({"amount": 16, "life": 2.4, "shape_r": radius * 0.2, "vmin": 1.0, "vmax": radius * 0.9,
			"damp": 3.0, "spread": 120.0, "dir": normal, "size": radius * 0.55, "scale": [0.5, 1.4, 2.0], "explosive": 0.9,
			"ramp": [[0.0, Color(0.12, 0.1, 0.09, 0)], [0.12, Color(0.14, 0.12, 0.11, 0.85)], [0.6, Color(0.24, 0.23, 0.22, 0.55)],
				[1.0, Color(0.3, 0.3, 0.3, 0)]], "lit": true, "gravity": -g * 0.12, "pos": normal * 0.9})
	# Sparks.
	_particles({"amount": 44, "life": 0.9, "shape_r": 0.2, "vmin": 8.0, "vmax": 24.0, "damp": 1.5, "spread": 75.0,
			"dir": normal, "size": 0.0, "streak": true, "gravity": g * 0.8,
			"ramp": [[0.0, Color(1, 0.95, 0.7, 1)], [0.6, Color(1.0, 0.55, 0.2, 1)], [1.0, Color(0.8, 0.2, 0.05, 0)]],
			"add": true, "pos": normal * 0.4, "color_mult": 3.0})
	# Rising smoke column.
	_particles({"amount": 24, "life": 5.0, "shape_r": radius * 0.25, "vmin": 1.2, "vmax": 4.0, "damp": 1.2,
			"spread": 40.0, "dir": normal, "size": radius * 0.6, "scale": [0.6, 2.2, 3.6], "explosive": 0.75,
			"ramp": [[0.0, Color(0.3, 0.28, 0.26, 0)], [0.08, Color(0.32, 0.3, 0.28, 0.8)], [0.5, Color(0.48, 0.47, 0.46, 0.5)],
				[1.0, Color(0.55, 0.55, 0.55, 0)]], "lit": true, "gravity": -g * 0.06, "pos": normal * 0.8})
	# Dust ring sweeping outward along the ground.
	_particles({"amount": 26, "life": 1.6, "shape_r": radius * 0.25, "ring": true, "vmin": radius * 1.2, "vmax": radius * 2.2,
			"damp": 5.0, "spread": 12.0, "dir": normal, "size": radius * 0.35, "scale": [0.5, 1.5, 2.2], "radial": true,
			"ramp": [[0.0, Color(ground, 0)], [0.1, Color(ground, 0.7)], [1.0, Color(ground.lightened(0.15), 0)]],
			"lit": true, "gravity": g * 0.05, "pos": normal * 0.25})
	# Debris chunks (CPU, they bounce on the ground).
	var bm := BoxMesh.new()
	bm.size = Vector3(0.12, 0.09, 0.14)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = ground.darkened(0.2)
	dm.roughness = 0.95
	var hot := StandardMaterial3D.new()
	hot.albedo_color = Color(0.15, 0.1, 0.08)
	hot.emission_enabled = true
	hot.emission = Color(1.0, 0.45, 0.15)
	hot.emission_energy_multiplier = 2.5
	var t1 := basis_n.x
	var t2 := basis_n.z
	for i in 12:
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.material_override = hot if i % 4 == 0 else dm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		var a := randf() * TAU
		var side := (t1 * cos(a) + t2 * sin(a)) * randf_range(0.3, 1.0)
		var v := (normal * randf_range(0.8, 1.6) + side).normalized() * randf_range(6.0, 15.0)
		var s := randf_range(0.5, 1.5)
		mi.global_transform = Transform3D(Basis().scaled(Vector3.ONE * s), global_position + normal * 0.3 + side * 0.3)
		_debris.append({"mi": mi, "vel": v, "spin": Vector3(randf_range(-12, 12), randf_range(-12, 12), randf_range(-12, 12)),
				"t": 0.0, "s": s, "life": randf_range(2.2, 3.6)})
	# Scorch mark.
	_decal = Decal.new()
	_decal.texture_albedo = _tex_scorch
	_decal.modulate = Color(0.05, 0.04, 0.035, 0.92)
	_decal.size = Vector3(radius * 1.15, 0.9, radius * 1.15)
	_decal.upper_fade = 0.3
	_decal.lower_fade = 0.3
	_decal.normal_fade = 0.55
	_decal.transform = Transform3D(basis_n.rotated(normal, randf() * TAU), Vector3.ZERO)
	add_child(_decal)


func _particles(o: Dictionary) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.one_shot = true
	e.amount = int(o["amount"])
	e.lifetime = float(o["life"])
	e.explosiveness = float(o.get("explosive", 0.97))
	e.randomness = 0.4
	e.local_coords = false
	e.visibility_aabb = AABB(Vector3.ONE * -radius * 6.0, Vector3.ONE * radius * 12.0)
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	var dir: Vector3 = o["dir"]
	pm.direction = dir
	pm.spread = float(o["spread"])
	pm.initial_velocity_min = float(o["vmin"])
	pm.initial_velocity_max = float(o["vmax"])
	pm.damping_min = float(o["damp"]) * 0.7
	pm.damping_max = float(o["damp"])
	pm.gravity = o.get("gravity", Vector3.ZERO)
	if o.get("ring", false):
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		pm.emission_ring_axis = dir
		pm.emission_ring_radius = float(o["shape_r"])
		pm.emission_ring_inner_radius = float(o["shape_r"]) * 0.5
		pm.emission_ring_height = 0.1
	else:
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = float(o["shape_r"])
	if o.get("radial", false):
		pm.radial_velocity_min = float(o["vmin"])
		pm.radial_velocity_max = float(o["vmax"])
		pm.initial_velocity_min = 0.2
		pm.initial_velocity_max = 0.6
	var g := Gradient.new()
	var ramp: Array = o["ramp"]
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for k in ramp:
		offs.append(float(k[0]))
		cols.append(k[1])
	g.offsets = offs
	g.colors = cols
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = Color.WHITE * float(o.get("color_mult", 1.0))
	if o.has("scale"):
		var sc: Array = o["scale"]
		var cv := Curve.new()
		cv.max_value = 4.0
		cv.add_point(Vector2(0.0, float(sc[0])))
		cv.add_point(Vector2(0.25, float(sc[1])))
		cv.add_point(Vector2(1.0, float(sc[2])))
		var ct := CurveTexture.new()
		ct.curve = cv
		pm.scale_curve = ct
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if o.get("streak", false):
		pm.particle_flag_align_y = true
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		mat.billboard_keep_scale = true
		var qs := QuadMesh.new()
		qs.size = Vector2(0.03, 0.32)
		qs.material = mat
		e.draw_pass_1 = qs
	else:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.albedo_texture = _tex_soft
		if o.get("add", false):
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		elif o.get("lit", false):
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 1.0
		var q := QuadMesh.new()
		q.size = Vector2.ONE * float(o["size"])
		q.material = mat
		e.draw_pass_1 = q
	e.process_material = pm
	add_child(e)
	e.position = o.get("pos", Vector3.ZERO)
	e.emitting = true
	return e


func _add_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = Color(col.r, col.g, col.b)
	m.emission_energy_multiplier = energy
	return m


func _process(delta: float) -> void:
	_t += delta
	var t := _t
	if _light != null:
		var k := clampf(1.0 - t / 0.45, 0.0, 1.0)
		_light.light_energy = 18.0 * k * k * randf_range(0.85, 1.1)
		_light.visible = k > 0.0
	if _core != null:
		var u := clampf(t / 0.12, 0.0, 1.0)
		_core.scale = Vector3.ONE * lerpf(0.3, radius * 0.32, sqrt(u))
		_core_mat.albedo_color.a = (1.0 - u) * (1.0 - u)
		_core.visible = u < 1.0
	if _ring != null:
		var u2 := clampf(t / 0.32, 0.0, 1.0)
		_ring.scale = Vector3.ONE * lerpf(0.3, radius * 1.7, 1.0 - (1.0 - u2) * (1.0 - u2))
		_ring_mat.albedo_color.a = 0.65 * (1.0 - u2)
		_ring.visible = u2 < 1.0
	if _decal != null:
		_decal.albedo_mix = clampf((DECAL_LIFE - t) / 6.0, 0.0, 1.0)
	for s in _sounds:
		if float(s[0]) > 0.0:
			s[0] = float(s[0]) - delta
			if float(s[0]) <= 0.0:
				(s[1] as Node).call("play")
	if t > DECAL_LIFE:
		queue_free()


func _physics_process(delta: float) -> void:
	if _debris.is_empty():
		return
	var space := get_world_3d().direct_space_state
	var keep: Array = []
	for d in _debris:
		var mi: MeshInstance3D = d["mi"]
		var t: float = float(d["t"]) + delta
		d["t"] = t
		if t > float(d["life"]):
			mi.queue_free()
			continue
		var v: Vector3 = d["vel"]
		var p := mi.global_position
		v += Game.gravity_at(p) * delta
		var np := p + v * delta
		if v.length_squared() > 0.05:
			var q := PhysicsRayQueryParameters3D.create(p, np, Game.LAYER_TERRAIN | Game.LAYER_SHIP)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				var n: Vector3 = hit["normal"]
				v = v.bounce(n) * 0.3
				np = (hit["position"] as Vector3) + n * 0.05
				d["spin"] = (d["spin"] as Vector3) * 0.5
				if v.length() < 0.6:
					v = Vector3.ZERO
		d["vel"] = v
		var sp: Vector3 = d["spin"]
		var b := mi.global_transform.basis.orthonormalized()
		if sp.length_squared() > 0.01:
			b = b.rotated(sp.normalized(), sp.length() * delta)
		var sc: float = float(d["s"]) * clampf((float(d["life"]) - t) * 2.0, 0.0, 1.0)
		mi.global_transform = Transform3D(b.scaled(Vector3.ONE * maxf(sc, 0.01)), np)
		keep.append(d)
	_debris = keep


# =================================================================================================
# Sound
# =================================================================================================

## Recorded blasts (assets/audio/sonniss/expl: Gamemaster, David Dumais, Bluezone) at their own
## pitch: the blast and its debris positional, plus a distant-blast layer for far explosions (the
## 3D falloff alone loses them). Vacuum rules: sfx.gd routes the 3D players; the far layer follows
## route_for() (silent in vacuum unless you stand on the same ground).
func _play_sounds(pos: Vector3) -> void:
	if _ogg.is_empty():
		_ogg["main"] = Snd.rand("expl/explosion", 1.04, 1.5)
		_ogg["debris"] = Snd.rand("expl/debris", 1.05, 1.5)
		_ogg["far"] = Snd.rand("expl/far", 1.04, 1.5)
	var cam := get_viewport().get_camera_3d()
	var d := cam.global_position.distance_to(pos) if cam != null else 30.0
	var delay := d / SOUND_SPEED
	if _ogg["main"] != null:
		_sound3d(_ogg["main"], 0.0, randf_range(0.95, 1.04), delay, 30.0)
	if _ogg["debris"] != null:
		_sound3d(_ogg["debris"], -5.0, randf_range(0.92, 1.05), delay, 18.0)
	var far: AudioStream = _ogg["far"]
	if far != null and d > 70.0:
		var route := 0
		if Game.sfx != null and Game.sfx.has_method("route_for"):
			route = int(Game.sfx.route_for(pos, null))
		if route != 3:
			var p2 := AudioStreamPlayer.new()
			p2.stream = far
			p2.bus = ["Master", "VacHull", "VacGround", "VacMute"][route]
			p2.volume_db = lerpf(-8.0, -26.0, clampf((d - 70.0) / 400.0, 0.0, 1.0))
			p2.pitch_scale = randf_range(0.95, 1.05)
			add_child(p2)
			_sounds.append([delay, p2])
			if delay <= 0.0:
				p2.play()


func _sound3d(st: AudioStream, vol: float, pitch: float, delay: float, unit: float) -> void:
	var p := AudioStreamPlayer3D.new()
	p.stream = st
	p.volume_db = vol
	p.pitch_scale = pitch
	p.unit_size = unit
	p.max_distance = 900.0
	p.max_db = 2.0
	add_child(p)
	if Game.sfx != null and Game.sfx.has_method("route_player"):
		Game.sfx.route_player(p)
	_sounds.append([delay, p])
	if delay <= 0.0:
		p.play()


# =================================================================================================
# Textures
# =================================================================================================

static func _ensure_textures() -> void:
	if _tex_soft != null:
		return
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 64
	t.height = 64
	_tex_soft = t
	var gr := Gradient.new()
	gr.offsets = PackedFloat32Array([0.0, 0.7, 0.86, 0.95, 1.0])
	gr.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 0), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.3), Color(1, 1, 1, 0)])
	var tr := GradientTexture2D.new()
	tr.gradient = gr
	tr.fill = GradientTexture2D.FILL_RADIAL
	tr.fill_from = Vector2(0.5, 0.5)
	tr.fill_to = Vector2(0.5, 0.0)
	tr.width = 128
	tr.height = 128
	_tex_ring = tr
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 404
	noise.frequency = 0.05
	for y in n:
		for x in n:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(n) * 2.0 - Vector2.ONE
			var ang := atan2(u.y, u.x)
			var r := u.length() * (1.0 + 0.22 * sin(ang * 7.0) + 0.3 * noise.get_noise_2d(x, y))
			var a := clampf(1.0 - smoothstep(0.25, 0.95, r), 0.0, 1.0)
			a *= 0.75 + 0.25 * noise.get_noise_2d(x * 3.0, y * 3.0)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	_tex_scorch = ImageTexture.create_from_image(img)
