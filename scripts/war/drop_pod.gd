extends Node3D
## Çıkarma kapsülü: a troop pod the rival fires from one of its cannons at our planet (rival_team.gd
## "Drop-pod raids" launches it with its crew aboard; the bots ride hidden inside, ai_rival.gd
## "Drop-pod raids"). A dark armoured capsule with a scorched heat shield in front, red rival bands,
## three door panels and four retro nozzles; a smoke / ember trail and a halo that stays visible
## from the other planet; a low roar in flight.
##   Flight: the shell's update under Game.gravity_at (same as Ballistics / shell.gd), tested every
##     step against the planets' density field and physics bodies (the firing cannon excluded).
##     Within POD_GUIDE_RANGE of its landing spot it steers toward it (at most POD_GUIDE_ACCEL
##     sideways: it soaks up the aim error); descending below POD_RETRO_ALT faster than its braking
##     curve allows, the retro-thrusters flare (light, flame jets, exhaust, roar) and bring it down
##     along that curve to POD_LAND_SPEED over the landing spot (_thrust).
##   Touchdown: a hard thump (POD_LAND_DAMAGE area damage, Game.blast, camera shake), dust and
##     clods, a small dent (no crater); the pod stands upright, a collider makes it cover. After
##     POD_DOOR_DELAY the doors blow off and `doors_open` lets the team put the crew out. The empty
##     pod stays POD_WRECK_TIME s, then sinks away.
##   Air defence: group "war_shell" (team / vel / is_live() / shot_down(pos): our Uçaksavar bursts
##     and point defence, the armed skiff's gun, the Kinetik İtici's deflection) and "war_drop_pod"
##     (our unmanned Uçaksavar engages it like a skiff; it reads linear_velocity). POD_HITS hits
##     destroy it: a big airburst, `destroyed` (the crew die). Lost (also `destroyed`) after
##     POD_LIFE s without hitting anything.
## Signals: landed(pod, pos, up), doors_open(pod, pos, up), destroyed(pod, pos). Damage, the dent
## and the signals only on the host / single player.
## Multiplayer: the team runs on the host and reports its pods through RivalTeam.events()
## (pod_fired / pod_landed / pod_destroyed). A client may show one with DropPod.puppet(parent, id,
## from, vel): it flies the same ballistics and retro burn (no guidance), stops where it touches
## down and waits for net_land(pos) (the host's touchdown; it lands there itself after 2 s without
## word) or net_destroy(pos).
##   DropPod.fire(parent, from, vel, team, exclude_rids, target) -> the pod

const Balance := preload("res://scripts/war/balance.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # toasts: key "droppod" (hit 0, shot down 1)
const FlakRound := preload("res://scripts/war/flak_round.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

const GROUP := "war_drop_pod"
const HALF_H := 1.3                    # capsule centre to the shield / the hatch
const RADIUS := 0.85                   # at the shield
const SINK := 0.3                      # m the landed pod sits in its dent
const RETRO_K := 0.5                   # share of the retro's net deceleration the braking curve plans with

signal landed(pod: Node3D, pos: Vector3, up: Vector3)
signal doors_open(pod: Node3D, pos: Vector3, up: Vector3)
signal destroyed(pod: Node3D, pos: Vector3)

var team := "rival"
var vel := Vector3.ZERO
var exclude: Array = []                # RIDs the physics test ignores (the firing cannon)
var target := Vector3.INF              # the landing spot it steers toward (INF: none)
var crew: Array = []                   # the bots aboard (the team's bookkeeping)
var net_id := 0
var net_puppet := false
## Our unmanned Uçaksavar reads a target's velocity as linear_velocity (flak.gd _fire_control).
var linear_velocity: Vector3:
	get:
		return vel

var _life := 0.0
var _done := false                     # landed, destroyed or lost: no longer an air target
var _landed := false
var _wait_host := false                # puppet: touched down, waiting for the host's word
var _hits := 0
var _retro := false
var _spin := 0.0
var _vis: Node3D
var _doors: Array = []                 # door pivots (each holds its panel)
var _jets: Array = []                  # retro flame meshes
var _jet_p: CPUParticles3D
var _trail: GPUParticles3D
var _embers: GPUParticles3D
var _light: OmniLight3D
var _halo: MeshInstance3D
var _roar: AudioStreamPlayer3D
var _burn: AudioStreamPlayer3D
var _accent: StandardMaterial3D
var _col: StaticBody3D


static func fire(parent: Node, from: Vector3, v: Vector3, p_team: String, p_exclude: Array = [],
		p_target := Vector3.INF) -> Node3D:
	var p: Node3D = load("res://scripts/war/drop_pod.gd").new()
	p.team = p_team
	p.vel = v
	p.exclude = p_exclude
	p.target = p_target
	parent.add_child(p)
	p.global_position = from
	return p


## A client's look-only copy of a host pod (see the header).
static func puppet(parent: Node, id: int, from: Vector3, v: Vector3, p_team := "rival") -> Node3D:
	var p: Node3D = fire(parent, from, v, p_team)
	p.net_id = id
	p.net_puppet = true
	return p


func _ready() -> void:
	top_level = true
	add_to_group("war_shell")
	add_to_group(GROUP)
	_build_model()
	_build_fx()
	_build_audio()
	_orient(1.0)


## Still flying (an air target).
func is_live() -> bool:
	return not _done


# =================================================================================================
# Model
# =================================================================================================

func _mat(c: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	return m


func _cyl(parent: Node3D, pos: Vector3, r_top: float, r_bot: float, h: float, mat: Material, seg := 20) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


## The capsule along local +Y (hatch up, heat shield down = forward in flight).
func _build_model() -> void:
	_vis = Node3D.new()
	add_child(_vis)
	var hull := _mat(Color(0.21, 0.2, 0.2), 0.55, 0.45)
	var dark := _mat(Color(0.07, 0.07, 0.08), 0.5, 0.55)
	var scorch := _mat(Color(0.15, 0.1, 0.07), 0.15, 0.9)
	var col := Color(1.0, 0.25, 0.15) if team != "home" else Color(0.35, 0.85, 1.0)
	_accent = _mat(col, 0.1, 0.5)
	_accent.emission_enabled = true
	_accent.emission = col
	_accent.emission_energy_multiplier = 1.2
	# Body: a truncated cone wide at the shield, bands, the top cap and hatch housing.
	_cyl(_vis, Vector3(0, -0.1, 0), 0.62, RADIUS, 2.0, hull)
	_cyl(_vis, Vector3(0, -1.18, 0), RADIUS + 0.05, RADIUS - 0.12, 0.2, scorch)
	_cyl(_vis, Vector3(0, -1.34, 0), RADIUS - 0.14, 0.32, 0.14, scorch)
	_cyl(_vis, Vector3(0, 0.98, 0), 0.4, 0.62, 0.2, dark, 16)
	_cyl(_vis, Vector3(0, 1.16, 0), 0.17, 0.28, 0.16, dark, 12)
	_cyl(_vis, Vector3(0, 0.62, 0), 0.665, 0.675, 0.08, _accent)
	_cyl(_vis, Vector3(0, -0.7, 0), 0.805, 0.815, 0.06, dark)
	# Three door panels (blown off on landing), proud of the hull between the bands.
	for i in 3:
		var d := Node3D.new()
		d.rotation.y = TAU * float(i) / 3.0
		_vis.add_child(d)
		var panel := Node3D.new()
		panel.position = Vector3(0, -0.05, 0.745)
		panel.rotation.x = -0.115              # follows the cone
		d.add_child(panel)
		_box(panel, Vector3.ZERO, Vector3(0.6, 1.05, 0.07), hull)
		_box(panel, Vector3(0, 0, 0.04), Vector3(0.07, 0.9, 0.02), _accent)
		_box(panel, Vector3(0.22, 0.3, 0.04), Vector3(0.1, 0.06, 0.03), dark)
		_doors.append(panel)
	# Four retro nozzles on the shoulder of the shield, firing forward (-Y) to brake.
	var flame := StandardMaterial3D.new()
	flame.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flame.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flame.albedo_color = Color(2.2, 1.3, 0.55, 0.85)
	flame.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		var dir := Vector3(cos(a), 0.0, sin(a))
		_cyl(_vis, dir * 0.74 + Vector3(0, -0.9, 0), 0.06, 0.1, 0.22, dark, 10)
		var f := _cyl(_vis, dir * 0.76 + Vector3(0, -1.65, 0), 0.09, 0.015, 1.3, flame, 10)
		f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		f.visible = false
		_jets.append(f)
	for mi in _vis.find_children("*", "MeshInstance3D", true, false):
		if not _jets.has(mi):
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _build_fx() -> void:
	var col := Color(1.0, 0.45, 0.25) if team != "home" else Color(0.5, 0.85, 1.0)
	_halo = MeshInstance3D.new()
	_halo.mesh = DebrisMesh.quad_mesh()
	_halo.material_override = DebrisMesh.halo_material(col, 3.6, 0.008, 6.0)
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.custom_aabb = AABB(Vector3.ONE * -50.0, Vector3.ONE * 100.0)
	add_child(_halo)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.6, 0.35)
	_light.omni_range = 12.0
	_light.light_energy = 1.2
	_light.shadow_enabled = false
	add_child(_light)
	_trail = _make_trail(Color(0.5, 0.48, 0.46, 0.5), 3.0, 1.5, 72)
	_embers = _make_trail(col, 0.7, 0.32, 40)
	(_embers.process_material as ParticleProcessMaterial).color = Color(col.r * 2.0, col.g * 2.0, col.b * 2.0)
	# Retro exhaust: hot gas blown ahead of the shield (forward in flight, down when landing).
	_jet_p = CPUParticles3D.new()
	_jet_p.emitting = false
	_jet_p.amount = 48
	_jet_p.lifetime = 0.6
	_jet_p.local_coords = false
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 0.9)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	_jet_p.mesh = q
	_jet_p.direction = Vector3.DOWN
	_jet_p.spread = 22.0
	_jet_p.initial_velocity_min = 10.0
	_jet_p.initial_velocity_max = 18.0
	_jet_p.damping_min = 6.0
	_jet_p.damping_max = 10.0
	_jet_p.gravity = Vector3.ZERO
	_jet_p.scale_amount_min = 0.6
	_jet_p.scale_amount_max = 1.6
	_jet_p.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_jet_p.emission_ring_axis = Vector3.UP
	_jet_p.emission_ring_radius = 0.75
	_jet_p.emission_ring_inner_radius = 0.6
	_jet_p.emission_ring_height = 0.1
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.75, 0.4, 0.9), Color(0.8, 0.4, 0.2, 0.45), Color(0.3, 0.28, 0.26, 0.0)])
	_jet_p.color_ramp = g
	_jet_p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vis.add_child(_jet_p)
	_jet_p.position = Vector3(0, -1.1, 0)


## World-space particle trail (left behind as the pod moves), like a shell's.
func _make_trail(col: Color, lifetime: float, size: float, amount: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3.ONE * -2000.0, Vector3.ONE * 4000.0)
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 180.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.8
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.5
	pm.damping_max = 1.0
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.5))
	sc.add_point(Vector2(1, 1.7))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, col.a))
	g.set_color(1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = col
	p.process_material = pm
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = DigFx.soft_texture()
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = mat
	p.draw_pass_1 = q
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	p.emitting = true
	return p


func _build_audio() -> void:
	_roar = AudioStreamPlayer3D.new()
	_roar.stream = Snd.loop("shuttle/reentry_roar")
	_roar.unit_size = 12.0
	_roar.max_distance = 700.0
	_roar.volume_db = -8.0
	add_child(_roar)
	if _roar.stream != null:
		_roar.play()
	_burn = AudioStreamPlayer3D.new()
	_burn.stream = Snd.loop("shuttle/vtol")
	_burn.unit_size = 18.0
	_burn.max_distance = 600.0
	add_child(_burn)


## A one-shot positional sound at the pod (the pod outlives it).
func _oneshot(stream: AudioStream, unit: float, vol_db: float, pitch := 1.0) -> void:
	if stream == null:
		return
	var a := AudioStreamPlayer3D.new()
	a.stream = stream
	a.unit_size = unit
	a.max_distance = 500.0
	a.volume_db = vol_db
	a.pitch_scale = pitch
	add_child(a)
	a.play()
	a.finished.connect(a.queue_free)


# =================================================================================================
# Flight
# =================================================================================================

func _physics_process(delta: float) -> void:
	if _done:
		return
	_life += delta
	var p := global_position
	var g: Vector3 = Game.gravity_at(p)
	var acc := g + _thrust(p, g)
	var np := p + vel * delta + acc * (delta * delta * 0.5)     # the shell's update (+ its thrust)
	vel += acc * delta
	# (the physics test from 0.4 s on: clear of the cannon and the crew mustered around it)
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state if _life > 0.4 else null
	var hit := Ballistics.segment_hit(p, np, space, exclude)
	if not hit.is_empty():
		_touchdown(hit["position"], hit["normal"])
		return
	global_position = np
	_orient(delta)
	if _life > Balance.POD_LIFE:
		_lost()


## The guidance and retro thrust on top of gravity (m/s²).
func _thrust(p: Vector3, g: Vector3) -> Vector3:
	var out := Vector3.ZERO
	var spd := vel.length()
	if spd < 0.5:
		return out
	var f := vel / spd
	# Steering toward the landing spot (sideways to the flight only): the miss it would make coasting
	# on under the local gravity, closed over the time left. (The retro burn below steers itself.)
	if target != Vector3.INF and _life > 1.0 and not _retro:
		var to := target - p
		var d := to.length()
		if d < Balance.POD_GUIDE_RANGE and d > 2.5:
			var tgo := maxf(d / spd, 0.4)
			var zem := to - vel * tgo - g * (0.5 * tgo * tgo)
			var lat := zem - f * zem.dot(f)
			out += (lat * (2.0 / (tgo * tgo))).limit_length(Balance.POD_GUIDE_ACCEL)
	# Retro burn: close to the ground of the planet below. A planned braking curve, v_ok(alt) =
	# sqrt(LAND² + 2 · a · alt) with a = RETRO_K × (RETRO_DECEL - g): the burn lights when the pod comes
	# down faster than that (descending, under POD_RETRO_ALT) and then tracks a velocity of v_ok
	# straight down plus the sideways speed that still carries it to the landing spot (braked to it the
	# same way; no spot: none), so it touches down at about POD_LAND_SPEED on the spot. (2026-10-06,
	# R 60: arrivals are faster and more oblique; the old "brake along the flight from POD_RETRO_ALT to
	# POD_LAND_SPEED" stopped ~30 m up with the sideways speed left and the pod glided ~100 m.)
	var b: Node3D = Game.dominant_body(p)
	if b == null or _life < 2.0:
		return out
	var c: Vector3 = b.global_position
	var up := (p - c).normalized()
	var alt := maxf(p.distance_to(c) - float(b.radius) - float(b.surface_height_at(p)), 0.0)
	if not _retro and (vel.dot(up) >= -1.0 or alt >= Balance.POD_RETRO_ALT):
		return out
	var a_plan := maxf(Balance.POD_RETRO_DECEL - g.length(), 1.0) * RETRO_K
	var v_ok := sqrt(Balance.POD_LAND_SPEED * Balance.POD_LAND_SPEED + 2.0 * a_plan * alt)
	if not _retro:
		if spd <= v_ok:
			return out
		_start_retro()
	var side_want := Vector3.ZERO
	if target != Vector3.INF:
		var to := target - p
		var ts := to - up * to.dot(up)
		var d := ts.length()
		if d > 0.5:
			var cap := minf(v_ok, sqrt(2.0 * a_plan * d))
			side_want = ts / d * minf(d * v_ok / maxf(alt, 1.0), cap)
	# (tracking gain 4 / s, plus the curve's own deceleration fed forward)
	out += ((side_want - up * v_ok - vel) * 4.0 + up * a_plan - g).limit_length(Balance.POD_RETRO_DECEL)
	return out


func _start_retro() -> void:
	_retro = true
	for j in _jets:
		(j as Node3D).visible = true
	_jet_p.emitting = true
	_light.light_energy = 6.0
	_light.omni_range = 18.0
	if _burn.stream != null:
		_burn.play()
	_oneshot(Snd.one("shuttle/boost"), 16.0, 0.0, 0.85)


## Shield first along the flight, slowly spinning; the retro flames flicker.
func _orient(delta: float) -> void:
	if vel.length_squared() < 0.25:
		return
	_spin += delta * (0.4 if _retro else 1.3)
	var y := -vel.normalized()
	var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := y.cross(ref).normalized()
	var z := x.cross(y)
	_vis.basis = Basis(x, y, z).rotated(y, _spin)
	if _retro:
		var k := 0.8 + 0.4 * randf()
		for j in _jets:
			(j as Node3D).scale = Vector3(1.0, k, 1.0)
		_light.light_energy = 5.0 + 2.0 * randf()


# =================================================================================================
# Touchdown, doors
# =================================================================================================

func _touchdown(point: Vector3, normal: Vector3) -> void:
	_done = true
	remove_from_group("war_shell")
	var b: Node3D = Game.dominant_body(point)
	var up: Vector3 = (point - b.global_position).normalized() if b != null else normal
	if b != null:
		# (it may have struck a character or a structure: stand on the ground under that point)
		var gh: Dictionary = b.raycast_density(point + up * 3.0, point - up * 8.0, 0.3, false)
		if not gh.is_empty() and float(gh.get("distance", 0.0)) > 0.01:
			point = gh["position"]
			normal = gh["normal"]
	var stand := up
	if normal.dot(up) > 0.5:
		stand = (up * 0.75 + normal * 0.25).normalized()
	if net_puppet and not _landed:
		# Client: the host decides where it lands; wait there for its word (or land after 2 s).
		_wait_host = true
		global_position = point + stand * (HALF_H - SINK)
		_vis.basis = _basis_up(stand)
		_burn_off()
		get_tree().create_timer(2.0).timeout.connect(_host_silent.bind(point, stand, b))
		return
	_land_at(point, stand, b)


## Puppet: no word from the host after its touchdown: land where it touched down.
func _host_silent(point: Vector3, up: Vector3, b: Node3D) -> void:
	if _wait_host and not _landed and is_inside_tree():
		_land_at(point, up, b)


## Client puppet: the host's touchdown at `pos`.
func net_land(pos: Vector3) -> void:
	if _landed or not is_inside_tree():
		return
	_done = true
	remove_from_group("war_shell")
	var b: Node3D = Game.dominant_body(pos)
	var up: Vector3 = (pos - b.global_position).normalized() if b != null else Vector3.UP
	_land_at(pos, up, b)


## Client puppet: the host's pod was destroyed in the air at `pos`.
func net_destroy(pos: Vector3) -> void:
	if _landed or not is_inside_tree():
		return
	global_position = pos
	_destroy(pos)


func _land_at(point: Vector3, up: Vector3, b: Node3D) -> void:
	_landed = true
	_wait_host = false
	_done = true
	var xf := Transform3D(_basis_up(up), point + up * (HALF_H - SINK))
	global_transform = xf
	_vis.transform = Transform3D.IDENTITY
	_burn_off()
	_roar.stop()
	_trail.emitting = false
	_embers.emitting = false
	_halo.visible = false
	var tw := create_tween()
	tw.tween_property(_light, "light_energy", 0.0, 0.6)
	# The thump: sound, dust and clods, the camera.
	_oneshot(Snd.rand("impact/thud", 1.05, 1.0), 20.0, 4.0, 0.7)
	_oneshot(Snd.one("impact/metal_heavy_01"), 16.0, 0.0, 0.8)
	var ground := Rifle.ground_color(point, up)
	var soil: Color = b.get("soil_color") if b != null and b.get("soil_color") is Color else ground
	var scene: Node = get_parent()
	BuildFx.dust(scene, point, up, 3.5, soil)
	BuildFx.dust(scene, point, up, 1.6, soil.lightened(0.15))
	_clods(scene, point, up, soil)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var dpl: float = (pl as Node3D).global_position.distance_to(point)
		if dpl < 45.0:
			pl.add_trauma(0.55 * (1.0 - dpl / 45.0))
	# Cover for whoever fights around it.
	_col = StaticBody3D.new()
	_col.collision_layer = Game.LAYER_SHIP
	_col.collision_mask = 0
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = RADIUS - 0.1
	sh.height = HALF_H * 2.0
	cs.shape = sh
	_col.add_child(cs)
	add_child(_col)
	if not net_puppet and not Net.is_client():
		if b != null and b.has_method("crater"):
			b.crater(point - up * 0.3, Balance.POD_DENT_R, Balance.POD_DENT_DEPTH)
		Game.area_damage(point + up * 0.5, Balance.POD_LAND_RADIUS, Balance.POD_LAND_DAMAGE, Balance.POD_LAND_IMPULSE, null, team)
		Game.blast.emit(point, Balance.POD_LAND_RADIUS * 2.0, team)
		landed.emit(self, point, up)
	get_tree().create_timer(Balance.POD_DOOR_DELAY).timeout.connect(_open_doors.bind(point, up))
	get_tree().create_timer(Balance.POD_WRECK_TIME).timeout.connect(_sink_away)


## The doors blow off (spinning away, falling flat), a decompression puff; the crew may come out.
func _open_doors(point: Vector3, up: Vector3) -> void:
	if not is_inside_tree():
		return
	for i in _doors.size():
		var d: Node3D = _doors[i]
		var tw := d.create_tween()
		tw.set_parallel(true)
		var out := d.position + Vector3(randf_range(-0.3, 0.3), -0.9, randf_range(2.2, 3.2))
		tw.tween_property(d, "position", d.position + Vector3(0, 0.5, 1.2), 0.15).set_ease(Tween.EASE_OUT)
		tw.tween_property(d, "rotation", Vector3(-1.45, randf_range(-0.6, 0.6), randf_range(-0.4, 0.4)), 0.5)
		tw.chain().tween_property(d, "position", out, 0.35).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	_oneshot(Snd.one("shuttle/decompress"), 12.0, 2.0, 1.1)
	_oneshot(Snd.one("shuttle/ramp_open"), 10.0, -4.0, 1.3)
	BuildFx.dust(get_parent(), point + up * 1.0, up, 1.4, Color(0.75, 0.75, 0.75))
	if not net_puppet and not Net.is_client():
		doors_open.emit(self, point, up)


func _burn_off() -> void:
	_retro = false
	for j in _jets:
		(j as Node3D).visible = false
	_jet_p.emitting = false
	_burn.stop()


func _basis_up(up: Vector3) -> Basis:
	var ref := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := up.cross(ref).normalized()
	return Basis(x, up, x.cross(up)).rotated(up, randf() * TAU)


## Clods kicked up by the touchdown (smaller than a shell's).
func _clods(parent: Node, point: Vector3, up: Vector3, col: Color) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 22
	p.lifetime = 1.8
	p.explosiveness = 0.95
	var bm := BoxMesh.new()
	bm.size = Vector3(0.3, 0.24, 0.28)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	bm.material = mat
	p.mesh = bm
	p.direction = up
	p.spread = 70.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 8.0
	p.gravity = -up * 7.8
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.6
	p.angular_velocity_min = -300.0
	p.angular_velocity_max = 300.0
	p.particle_flag_rotate_y = true
	p.color = col
	parent.add_child(p)
	p.global_position = point + up * 0.3
	p.emitting = true
	p.finished.connect(p.queue_free)


## The empty pod sinks into the ground and goes.
func _sink_away() -> void:
	if not is_inside_tree():
		return
	if _col != null:
		_col.queue_free()
		_col = null
	var tw := create_tween()
	tw.tween_property(self, "global_position", global_position - global_transform.basis.y * (HALF_H * 2.0 + 0.5), 4.0) \
			.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(queue_free)


# =================================================================================================
# Air defence
# =================================================================================================

## Hit in the air by an enemy flak burst / point defence / skiff gun at `by_pos`: POD_HITS of them
## destroy it (the first only scorches it and sets it smoking).
func shot_down(_by_pos: Vector3) -> void:
	if _done or net_puppet:
		return
	_hits += 1
	if _hits < Balance.POD_HITS:
		FlakRound.burst_fx(get_parent(), global_position, 0.6)
		var pm := _trail.process_material as ParticleProcessMaterial
		if pm != null:
			pm.color = Color(0.08, 0.075, 0.07, 0.75)
		_accent.emission_energy_multiplier = 0.3
		if Game.hud and team != "home":
			HudLevel.alert("Çıkarma kapsülü isabet aldı!", 0, "droppod", 1.4)
		return
	_destroy(global_position)


func _destroy(pos: Vector3) -> void:
	_done = true
	FlakRound.burst_fx(get_parent(), pos, 2.2)
	_debris(get_parent(), pos)
	if Game.hud and team != "home" and not net_puppet:
		HudLevel.alert("Düşman çıkarma kapsülü havada vuruldu!", 1, "droppod", 2.2)
	if not net_puppet and not Net.is_client():
		destroyed.emit(self, pos)
	_finish()


## Flew on past everything: lost with its crew.
func _lost() -> void:
	_done = true
	if not net_puppet and not Net.is_client():
		destroyed.emit(self, global_position)
	_finish()


## Hull fragments of a pod blown up in the air.
func _debris(parent: Node, pos: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 26
	p.lifetime = 3.5
	p.explosiveness = 1.0
	p.local_coords = false
	var bm := BoxMesh.new()
	bm.size = Vector3(0.35, 0.06, 0.25)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.19, 0.19)
	mat.metallic = 0.5
	mat.roughness = 0.5
	bm.material = mat
	p.mesh = bm
	p.direction = vel.normalized() if vel.length_squared() > 0.01 else Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 4.0
	p.initial_velocity_max = 14.0
	p.gravity = Game.gravity_at(pos)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.8
	p.angular_velocity_min = -400.0
	p.angular_velocity_max = 400.0
	p.particle_flag_rotate_y = true
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)


## Hides the pod, lets the trail fade, then frees it.
func _finish() -> void:
	_done = true
	remove_from_group("war_shell")
	remove_from_group(GROUP)
	_vis.visible = false
	_halo.visible = false
	_light.visible = false
	_burn_off()
	_roar.stop()
	_trail.emitting = false
	_embers.emitting = false
	set_physics_process(false)
	await get_tree().create_timer(3.5).timeout
	queue_free()
