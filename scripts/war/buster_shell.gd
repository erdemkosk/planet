extends "res://scripts/war/shell.gd"
## Delici mermi: the Delici Top's penetrator (scripts/war/buster.gd). It flies like a cannon shell
## (shell.gd: same update, Ballistics.segment_hit every step, Balance.SHELL_LIFE, the halo, the
## smoke / ember trail, group "war_shell" so an Uçaksavar can burst it: shot_down()), but it is a
## spinning drill-nosed slug instead of a ball.
## On terrain it does not burst: it keeps boring along its velocity (bent toward the planet centre
## when it came in shallow) for Balance.BUSTER_PENETRATE m over BUSTER_BORE_TIME s (stopping short
## of a core), carving a shaft with Dig.dig_at(..., team) (logged for the enemy's Tünel tarayıcı),
## throwing a dust / clod geyser out of the entry hole with a deep grinding sound, then explodes down
## there: planet.crater(deep point, BUSTER_CRATER_R, BUSTER_CRATER_DEPTH), Explosion.spawn (BUSTER_DAMAGE
## / BUSTER_BLAST_R, team) and Core.blast_all(tree, deep point, BUSTER_CRATER_R, BUSTER_CORE_DAMAGE);
## the ground heaves above it and dust gouts out of the hole. On a structure / character it bursts
## on contact (a buster-sized shell hit). on_impact(entry point, body) like shell.gd's (AI aim).
##   BusterShell.fire(parent, from, vel, team, exclude_rids, on_impact) -> the penetrator
## Multiplayer: fire() reports to Net.world.on_shell_fired like a shell; the HOST (or single player)
## bores, carves, craters and damages the core and sends its impact (Net.world.on_shell_impact); a
## client's copy (net_puppet) waits for that and net_impact() plays the same bore and blast for the
## look only (the terrain comes through the terrain sync, explosion.gd skips damage on a client).

const Torpedo := preload("res://scripts/war/torpedo.gd")
const Dig := preload("res://scripts/player/dig.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

const BORE_STEP := 0.55              # m between shaft brushes
const BORE_AMOUNT := 16.0            # density per brush (deep rock is clamped to -4: two passes carve it)
const CORE_KEEP := 0.8               # m it stops short of a core's surface

var _bore_t := -1.0                  # >= 0 while boring
var _bore_from := Vector3.ZERO
var _bore_dir := Vector3.DOWN
var _bore_len := 1.0
var _bore_done := 0.0                # m of shaft carved so far
var _bore_body: Node3D
var _auth := true                    # this copy does the terrain / core work
var _entry_up := Vector3.UP
var _soil := Color(0.45, 0.35, 0.24)
var _hit_body = null
var _slug: Node3D
var _spin := 0.0
var _crunch_t := 0.0
var _grind: AudioStreamPlayer3D
var _crunch: AudioStreamPlayer3D
var _geyser: Array = []


static func fire(parent: Node, from: Vector3, v: Vector3, p_team: String, p_exclude: Array = [],
		p_on_impact := Callable()) -> Node3D:
	var s: Node3D = load("res://scripts/war/buster_shell.gd").new()
	s.team = p_team
	s.vel = v
	s.exclude = p_exclude
	s.on_impact = p_on_impact
	parent.add_child(s)
	s.global_position = from
	if Net.active:
		Net.world.on_shell_fired(s, from, v)
	return s


func _ready() -> void:
	super._ready()
	# The ball becomes the pivot of a drill-nosed slug (oriented along the flight, spinning).
	_ball.mesh = null
	_slug = Node3D.new()
	_ball.add_child(_slug)
	_build_slug()
	_ball.basis = _look(vel)
	_grind = _audio3d(Snd.loop("shuttle/rumble"), 18.0, 320.0, 8.0)
	_crunch = _audio3d(Snd.rand("dig/mine", 1.1, 2.0), 14.0, 260.0, 4.0)


func _audio3d(st: AudioStream, unit: float, max_d: float, vol: float) -> AudioStreamPlayer3D:
	var a := AudioStreamPlayer3D.new()
	a.stream = st
	a.unit_size = unit
	a.max_distance = max_d
	a.max_db = 6.0
	a.volume_db = vol
	add_child(a)
	return a


func _mat(c: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	return m


## Cylinder along -Z (r_front at the -Z end) centred at z.
func _zcyl(z: float, r_front: float, r_back: float, h: float, mat: Material) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r_front
	c.bottom_radius = r_back
	c.height = h
	c.radial_segments = 20
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.rotation = Vector3(-PI * 0.5, 0, 0)
	mi.position = Vector3(0, 0, z)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_slug.add_child(mi)
	return mi


## Slug along -Z: fluted drill nose, carbide collar, heavy body with the glowing team band and a
## hazard ring, stubby fins and a hot tracer at the base.
func _build_slug() -> void:
	var col := Color(1.0, 0.62, 0.25) if team == "home" else Color(1.0, 0.3, 0.2)
	var body := _mat(Color(0.17, 0.17, 0.18), 0.75, 0.38)
	var steel := _mat(Color(0.62, 0.64, 0.68), 0.92, 0.24)
	steel.cull_mode = BaseMaterial3D.CULL_DISABLED
	var carbide := _mat(Color(0.12, 0.12, 0.13), 0.8, 0.3)
	var hazard := _mat(Color(0.95, 0.72, 0.1), 0.2, 0.5)
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(col.r * 2.6, col.g * 2.6, col.b * 2.6)
	var drill := MeshInstance3D.new()
	drill.mesh = Torpedo.drill_mesh(0.55, 0.31)
	drill.material_override = steel
	drill.position = Vector3(0, 0, -0.2)
	drill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_slug.add_child(drill)
	_zcyl(-0.17, 0.33, 0.32, 0.07, carbide)
	_zcyl(0.18, 0.3, 0.3, 0.7, body)
	_zcyl(0.06, 0.31, 0.31, 0.08, glow)
	_zcyl(0.32, 0.305, 0.305, 0.06, hazard)
	_zcyl(0.58, 0.24, 0.3, 0.1, carbide)
	_zcyl(0.64, 0.2, 0.2, 0.02, glow)
	for i in 4:
		var a := TAU * (float(i) + 0.5) / 4.0
		var fb := BoxMesh.new()
		fb.size = Vector3(0.16, 0.03, 0.24)
		var mi := MeshInstance3D.new()
		mi.mesh = fb
		mi.material_override = body
		mi.transform = Transform3D(Basis(Vector3.BACK, a), Vector3(cos(a) * 0.36, sin(a) * 0.36, 0.48))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_slug.add_child(mi)


static func _look(v: Vector3) -> Basis:
	if v.length_squared() < 1e-6:
		return Basis()
	var d := v.normalized()
	return Basis.looking_at(d, Vector3.UP if absf(d.y) < 0.98 else Vector3.RIGHT)


# =================================================================================================
# Flight
# =================================================================================================

func _physics_process(delta: float) -> void:
	if _bore_t >= 0.0:
		_bore(delta)
		return
	if _done:
		return
	_life += delta
	var p := global_position
	var g: Vector3 = Game.gravity_at(p)
	var np := p + vel * delta + g * (delta * delta * 0.5)     # same update as Ballistics.predict
	vel += g * delta
	var hit := Ballistics.segment_hit(p, np, get_world_3d().direct_space_state, exclude)
	if not hit.is_empty():
		_hit_body = hit.get("body")
		_impact(hit["position"], hit["normal"])
		return
	global_position = np
	_ball.basis = _look(vel)
	_spin += delta * 9.0
	_slug.rotation.z = _spin
	if _life > Balance.SHELL_LIFE:
		_finish()


## It struck (host / single player decide; a client's copy waits for the host's net_impact).
func _impact(point: Vector3, normal: Vector3) -> void:
	_done = true
	remove_from_group("war_shell")
	global_position = point
	if net_puppet:
		_ball.visible = false
		_light.visible = false
		get_tree().create_timer(1.2).timeout.connect(net_impact.bind(point, normal))
		return
	_auth = not Net.is_client()
	var body: Node3D = Game.dominant_body(point)
	if Torpedo._is_ground(_hit_body) and body != null:
		_start_bore(point, body)
	else:
		_contact_blast(point, normal, body)
	if on_impact.is_valid():
		on_impact.call(point, body)
	if Net.is_host():
		Net.world.on_shell_impact(self, point, normal)


## Multiplayer client: the host's impact (or the fallback): the same show, no terrain / damage work.
func net_impact(point: Vector3, normal: Vector3) -> void:
	if _net_fx_done or not is_inside_tree():
		return
	_net_fx_done = true
	_done = true
	_auth = false
	remove_from_group("war_shell")
	global_position = point
	_ball.visible = true
	_light.visible = true
	var body: Node3D = Game.dominant_body(point)
	# Ground under the point (not a structure it hit): bore.
	if body != null and body.has_method("density_at") and float(body.density_at(point - normal * 0.4)) < 0.0:
		_start_bore(point, body)
	else:
		_contact_blast(point, normal, body)


## A structure / character in the way: a buster-sized burst at the surface.
func _contact_blast(point: Vector3, normal: Vector3, body: Node3D) -> void:
	var up: Vector3 = (point - body.global_position).normalized() if body != null else normal
	if _auth:
		if body != null and body.has_method("crater"):
			body.crater(point - up * 1.0, Balance.BUSTER_CRATER_R, Balance.BUSTER_CRATER_DEPTH * 0.6)
		Core.blast_all(get_tree(), point, Balance.BUSTER_CRATER_R, Balance.BUSTER_CORE_DAMAGE)
	var ground: Color = Rifle.ground_color(point, normal)
	Explosion.spawn(point + normal * 0.2, normal, {"radius": Balance.BUSTER_BLAST_R, "damage": Balance.BUSTER_DAMAGE,
			"impulse": Balance.BUSTER_IMPULSE, "self_mult": 1.0, "crater": 0.0, "player_owned": team == "home",
			"ground": ground, "team": team})
	_clods(point, up, body.get("soil_color") if body != null and body.get("soil_color") is Color else ground)
	_finish()


# =================================================================================================
# Boring
# =================================================================================================

func _start_bore(point: Vector3, body: Node3D) -> void:
	_bore_body = body
	_entry_up = (point - body.global_position).normalized()
	if body.get("soil_color") is Color:
		_soil = body.get("soil_color")
	var down := -_entry_up
	var dir := vel.normalized() if vel.length_squared() > 0.01 else down
	var d := dir.dot(down)
	if d < -0.5:
		dir = down
	elif d < 0.75:
		dir = dir.slerp(down, clampf(0.75 - d, 0.0, 1.0)).normalized()     # came in shallow: bend down
	_bore_dir = dir
	_bore_from = point
	_bore_len = _bore_length(point, dir, body)
	_bore_t = 0.0
	_bore_done = 0.0
	_done = true
	# No more flight trail / halo; the slug drives on in.
	_trail.emitting = false
	_embers.emitting = false
	for c in get_children():
		if c is MeshInstance3D and c != _ball:
			(c as MeshInstance3D).visible = false
	_light.light_color = Color(1.0, 0.6, 0.3)
	_ball.basis = _look(_bore_dir)
	if _auth:
		_carve(0.0)
	# The strike: a burst of dirt and sparks, a heavy clang, then the geyser and the grind.
	var scene := get_parent()
	Torpedo._burst(scene, point, _entry_up, _soil, 1.7)
	Torpedo._burst(scene, point, _entry_up, Color(1.0, 0.7, 0.35), 0.7, true)
	_geyser = [_geyser_dust(point), _geyser_clods(point)]
	if Game.sfx:
		Game.sfx.play_at("impact", point, 6.0, 0.5, 40.0)
		Game.sfx.play_at("explosion_crunch", point, 0.0, 0.8, 30.0)
	_grind.pitch_scale = 0.5
	_grind.play()
	_shake(point, 0.45, 50.0)


## Bore length: Balance.BUSTER_PENETRATE, stopped CORE_KEEP m short of any core on the way.
func _bore_length(from: Vector3, dir: Vector3, body: Node3D) -> float:
	var length := Balance.BUSTER_PENETRATE
	for c in get_tree().get_nodes_in_group(Core.GROUP):
		if c.get("body") != body:
			continue
		var cp: Vector3 = (c as Node3D).global_position
		var s := 0.0
		while s < length:
			if (from + dir * s).distance_to(cp) < Balance.CORE_RADIUS + CORE_KEEP:
				length = maxf(s - 0.25, 0.5)
				break
			s += 0.25
	return length


func _bore(delta: float) -> void:
	_bore_t += delta
	var k := clampf(_bore_t / Balance.BUSTER_BORE_TIME, 0.0, 1.0)
	var e := 1.0 - pow(1.0 - k, 1.6)                 # hits hard, slows as it goes
	var dist := _bore_len * e
	if _auth:
		while _bore_done + BORE_STEP <= dist:
			_carve(_bore_done + BORE_STEP)
	global_position = _bore_from + _bore_dir * dist
	_spin += delta * (30.0 * (1.0 - k) + 6.0)
	_slug.rotation.z = _spin
	_light.light_energy = 3.0 * randf_range(0.6, 1.0)
	_grind.pitch_scale = lerpf(0.55, 0.38, k)
	_crunch_t -= delta
	if _crunch_t <= 0.0:
		_crunch_t = randf_range(0.06, 0.11)
		_crunch.pitch_scale = randf_range(0.45, 0.6)
		_crunch.play()
	if k >= 1.0:
		_detonate()


## One brush of the shaft at `s` m along the bore (host / single player only).
func _carve(s: float) -> void:
	_bore_done = s
	Dig.dig_at(_bore_body, _bore_from + _bore_dir * s, Balance.BUSTER_BORE_RADIUS, Dig.MODE_DIG, BORE_AMOUNT,
			Vector3.ZERO, Vector3.UP, -1.0, team)


func _detonate() -> void:
	_bore_t = -1.0
	var deep := global_position
	var body := _bore_body
	for g in _geyser:
		_stop_emitter(g)
	_geyser = []
	_grind.stop()
	if _auth and body != null and is_instance_valid(body):
		if body.has_method("crater"):
			body.crater(deep, Balance.BUSTER_CRATER_R, Balance.BUSTER_CRATER_DEPTH)
		Core.blast_all(get_tree(), deep, Balance.BUSTER_CRATER_R, Balance.BUSTER_CORE_DAMAGE)
	# (On a multiplayer client the explosion is only the look.)
	Explosion.spawn(deep, _entry_up, {"radius": Balance.BUSTER_BLAST_R, "damage": Balance.BUSTER_DAMAGE,
			"impulse": Balance.BUSTER_IMPULSE, "self_mult": 1.0, "crater": 0.0, "player_owned": team == "home",
			"ground": _soil, "team": team})
	_heave(deep, body)
	_shake(deep, 0.75, 70.0)
	_finish()


## Above ground: a dust ring heaves up over the blast and the shaft spits dirt and smoke.
func _heave(deep: Vector3, body: Node3D) -> void:
	var scene := get_parent()
	var up := _entry_up
	var entry := _bore_from + up * 0.3
	var soil := _soil
	# A deep, late thump (the sound travels through the rock).
	var boom := AudioStreamPlayer3D.new()
	boom.stream = Snd.rand("expl/explosion", 1.04, 1.5)
	boom.unit_size = 45.0
	boom.max_distance = 900.0
	boom.pitch_scale = randf_range(0.5, 0.58)
	boom.volume_db = 4.0
	scene.add_child(boom)
	boom.global_position = deep
	boom.play()
	boom.finished.connect(boom.queue_free)
	var top := entry
	if body != null and is_instance_valid(body) and body.has_method("raycast_density"):
		var b_up: Vector3 = (deep - body.global_position).normalized()
		# (from above the terrain shell: a blast BUSTER_PENETRATE m under an old crater is deeper than 20 m)
		var sky: Vector3 = body.global_position + b_up * (float(body.radius) + float(body.max_height) + 2.0)
		var hit: Dictionary = body.raycast_density(sky, deep, 0.5, true)
		if not hit.is_empty():
			top = hit["position"]
	var tw := scene.create_tween()
	tw.tween_interval(0.12)
	tw.tween_callback(func() -> void:
		Torpedo._burst(scene, entry, up, soil, 2.6)
		Torpedo._burst(scene, entry, up, Color(0.28, 0.27, 0.26), 2.0)
		Torpedo._burst(scene, top, up, soil, 2.2))


func _shake(at: Vector3, amount: float, reach: float) -> void:
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var d: float = (pl as Node3D).global_position.distance_to(at)
		if d < reach:
			pl.add_trauma(amount * (1.0 - d / reach))


## The geyser out of the entry hole while it bores (world vectors: the nodes are not rotated).
func _geyser_dust(at: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 60
	p.lifetime = 2.2
	p.local_coords = false
	var q := QuadMesh.new()
	q.size = Vector2(1.6, 1.6)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	p.mesh = q
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.6
	p.direction = _entry_up
	p.spread = 18.0
	p.initial_velocity_min = 6.0
	p.initial_velocity_max = 16.0
	p.damping_min = 1.5
	p.damping_max = 2.5
	p.gravity = -_entry_up * 3.0
	p.scale_amount_min = 0.8
	p.scale_amount_max = 2.6
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.5))
	sc.add_point(Vector2(1, 1.8))
	p.scale_amount_curve = sc
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.12, 1.0])
	g.colors = PackedColorArray([Color(_soil.r, _soil.g, _soil.b, 0.0), Color(_soil.r, _soil.g, _soil.b, 0.7),
			Color(_soil.r * 1.2, _soil.g * 1.2, _soil.b * 1.2, 0.0)])
	p.color_ramp = g
	p.visibility_aabb = AABB(Vector3.ONE * -60.0, Vector3.ONE * 120.0)
	get_parent().add_child(p)
	p.global_position = at + _entry_up * 0.4
	p.emitting = true
	return p


func _geyser_clods(at: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 30
	p.lifetime = 2.0
	p.local_coords = false
	var bm := BoxMesh.new()
	bm.size = Vector3(0.24, 0.18, 0.2)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	bm.material = mat
	p.mesh = bm
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.4
	p.direction = _entry_up
	p.spread = 22.0
	p.initial_velocity_min = 5.0
	p.initial_velocity_max = 14.0
	p.gravity = -_entry_up * 7.8
	p.angular_velocity_min = -300.0
	p.angular_velocity_max = 300.0
	p.particle_flag_rotate_y = true
	p.scale_amount_min = 0.5
	p.scale_amount_max = 2.0
	p.color = _soil.darkened(0.15)
	p.visibility_aabb = AABB(Vector3.ONE * -60.0, Vector3.ONE * 120.0)
	get_parent().add_child(p)
	p.global_position = at + _entry_up * 0.3
	p.emitting = true
	return p


func _stop_emitter(e) -> void:
	if e == null or not is_instance_valid(e):
		return
	var p := e as CPUParticles3D
	p.emitting = false
	var tw := p.create_tween()
	tw.tween_interval(p.lifetime + 0.5)
	tw.tween_callback(p.queue_free)
