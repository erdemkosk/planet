extends Node3D
## A cannonball in flight: a big glowing ball with an ember / smoke trail and a halo that stays a
## few pixels wide from the other planet (~350 m) and beyond. It flies under Game.gravity_at (both planets, same update
## as Ballistics.predict) for up to Balance.SHELL_LIFE s and tests every step against the planets'
## density field (no collision needed on the far planet) and physics bodies (cannons, characters).
## On impact:
##   - a crater: planet.crater(), radius SHELL_CRATER_R, carved over a few frames
##   - the explosion effects and area damage: scripts/items/explosion.gd
##   - core damage: Core.blast_all
##   - big dirt clods in the planet's soil colour
##   - on_impact.call(point, body) so the AI can correct its aim
## Group "war_shell": an enemy Uçaksavar burst close by destroys it in the air (shot_down(), no
## crater; scripts/war/flak_round.gd). team / vel / is_live() are read by the flak fire control.
##   Shell.fire(parent, from, vel, team, exclude_rids, on_impact) -> the shell

const Balance := preload("res://scripts/war/balance.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const Core := preload("res://scripts/war/core.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const FlakRound := preload("res://scripts/war/flak_round.gd")

var team := "home"
var vel := Vector3.ZERO
var exclude: Array = []          # RIDs the physics test ignores (the firing cannon)
var on_impact: Callable
var _life := 0.0
var _trail: GPUParticles3D
var _embers: GPUParticles3D
var _light: OmniLight3D
var _ball: MeshInstance3D
var _done := false


static func fire(parent: Node, from: Vector3, v: Vector3, p_team: String, p_exclude: Array = [],
		p_on_impact := Callable()) -> Node3D:
	var s: Node3D = load("res://scripts/war/shell.gd").new()
	s.team = p_team
	s.vel = v
	s.exclude = p_exclude
	s.on_impact = p_on_impact
	parent.add_child(s)
	s.global_position = from
	return s


func _ready() -> void:
	top_level = true
	add_to_group("war_shell")
	var col := Color(1.0, 0.62, 0.25) if team == "home" else Color(1.0, 0.3, 0.2)
	var sm := SphereMesh.new()
	sm.radius = 0.55
	sm.height = 1.1
	sm.radial_segments = 16
	sm.rings = 8
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.12, 0.1, 0.09)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 2.6
	m.roughness = 0.6
	sm.material = m
	_ball = MeshInstance3D.new()
	_ball.mesh = sm
	_ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ball)
	var halo := MeshInstance3D.new()
	halo.mesh = DebrisMesh.quad_mesh()
	halo.material_override = DebrisMesh.halo_material(col, 3.2, 0.007, 9.0)
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halo.custom_aabb = AABB(Vector3.ONE * -50.0, Vector3.ONE * 100.0)
	add_child(halo)
	_light = OmniLight3D.new()
	_light.light_color = col
	_light.omni_range = 10.0
	_light.light_energy = 2.0
	_light.shadow_enabled = false
	add_child(_light)
	_trail = _make_trail(Color(0.55, 0.52, 0.5, 0.5), 2.6, 0.9, 64)
	_embers = _make_trail(col, 0.7, 0.25, 40)
	(_embers.process_material as ParticleProcessMaterial).color = Color(col.r * 2.0, col.g * 2.0, col.b * 2.0)


## World-space particle trail (left behind as the shell moves).
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
	sc.add_point(Vector2(1, 1.6))
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


func _physics_process(delta: float) -> void:
	if _done:
		return
	_life += delta
	var p := global_position
	var g: Vector3 = Game.gravity_at(p)
	var np := p + vel * delta + g * (delta * delta * 0.5)     # same update as Ballistics.predict
	vel += g * delta
	var hit := Ballistics.segment_hit(p, np, get_world_3d().direct_space_state, exclude)
	if not hit.is_empty():
		_impact(hit["position"], hit["normal"])
		return
	global_position = np
	_ball.rotate_object_local(Vector3(0.3, 1.0, 0.2).normalized(), delta * 4.0)
	if _life > Balance.SHELL_LIFE:
		_finish()


func _impact(point: Vector3, normal: Vector3) -> void:
	_done = true
	global_position = point
	var body: Node3D = Game.dominant_body(point)
	var up: Vector3 = (point - body.global_position).normalized() if body != null else normal
	# The crater: centred a little below the surface so it bites deeper than it spreads.
	if body != null and body.has_method("crater"):
		body.crater(point - up * 1.5, Balance.SHELL_CRATER_R, Balance.SHELL_CRATER_DEPTH)
	var ground: Color = Rifle.ground_color(point, normal)
	Explosion.spawn(point + normal * 0.2, normal, {"radius": Balance.SHELL_BLAST_R, "damage": Balance.SHELL_DAMAGE,
			"impulse": Balance.SHELL_IMPULSE, "self_mult": 1.0, "crater": 0.0, "player_owned": team == "home",
			"ground": ground, "team": team})
	Core.blast_all(get_tree(), point, Balance.SHELL_CRATER_R, Balance.CORE_SHELL_DAMAGE)
	var soil: Color = body.get("soil_color") if body != null and body.get("soil_color") != null else ground
	_clods(point, up, soil)
	if on_impact.is_valid():
		on_impact.call(point, body)
	_finish()


## Big dirt clods thrown out of the crater (one-shot, world space).
func _clods(point: Vector3, up: Vector3, col: Color) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 40
	p.lifetime = 3.2
	p.explosiveness = 0.95
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 0.4, 0.45)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	bm.material = mat
	p.mesh = bm
	p.direction = up
	p.spread = 50.0
	p.initial_velocity_min = 8.0
	p.initial_velocity_max = 22.0
	p.gravity = -up * 7.8
	p.scale_amount_min = 0.5
	p.scale_amount_max = 2.2
	p.angular_velocity_min = -300.0
	p.angular_velocity_max = 300.0
	p.particle_flag_rotate_y = true
	p.color = col
	p.visibility_aabb = AABB(Vector3.ONE * -120.0, Vector3.ONE * 240.0)
	var parent: Node = get_tree().current_scene if get_tree().current_scene != null else get_parent()
	parent.add_child(p)
	p.global_position = point + up * 0.5
	p.emitting = true
	p.finished.connect(p.queue_free)


## Still flying (not burst, not landed).
func is_live() -> bool:
	return not _done


## Destroyed in the air by an enemy flak burst at `by_pos`: a bigger airburst, no crater, no damage
## on the ground (the AI does not learn from it).
func shot_down(_by_pos: Vector3) -> void:
	if _done:
		return
	_done = true
	FlakRound.burst_fx(get_parent(), global_position, 1.8)
	if Game.hud and team == "rival":
		Game.hud.show_message("Düşman mermisi havada vuruldu!", 1.6)
	_finish()


## Hides the ball, lets the trail fade, then frees the node.
func _finish() -> void:
	_done = true
	remove_from_group("war_shell")
	_ball.visible = false
	_light.visible = false
	for c in get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).visible = false
	_trail.emitting = false
	_embers.emitting = false
	set_physics_process(false)
	await get_tree().create_timer(3.0).timeout
	queue_free()
