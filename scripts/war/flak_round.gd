extends Node3D
## One anti-aircraft round from an Uçaksavar (scripts/war/flak.gd): a short glowing tracer that
## flies under Game.gravity_at (same update as Ballistics) and bursts in the air.
##   - Proximity fuse: it bursts at its closest pass when that is within Balance.FLAK_FUSE_R of a
##     target: an enemy skiff (group "skiff" whose Game.team_of differs, at its hull centre
##     global_position + basis.y * 0.9) and, for our rounds, also incoming enemy cannon shells
##     (group "war_shell", point defence).
##   - A burst within 30 m of a skiff calls its ai_under_fire(pos) hook (scripts/craft/skiff.gd,
##     when present); the rival team hears about bursts near its own skiff (raid retreat).
##   - Time fuse: it bursts at `fuse_time` s (the fire-control's intercept time) or at
##     Balance.FLAK_ROUND_LIFE, so a miss does not rain onto a planet.
##   - Ground or a structure: a small burst there, no crater.
## The burst: area damage (Game.area_damage, FLAK_BLAST_R / FLAK_DAMAGE: ~37 at 3 m, a skiff with
## 180 hp takes 4-6), enemy cannon shells within FLAK_SHELL_KILL_R are destroyed, and the show:
## a flash, a fireball, shrapnel sparks, a black smoke puff and a sharp crack.
##   FlakRound.fire(parent, from, vel, team, exclude_rids, fuse_time) -> the round

const Balance := preload("res://scripts/war/balance.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

static var _burst_snd: AudioStream
static var _tracer_mesh: Mesh

var team := "rival"
var vel := Vector3.ZERO
var exclude: Array = []
var fuse_time := 0.0                   # 0 = only the life limit
var _life := 0.0
var _done := false
## Multiplayer (scripts/net/net_world.gd): a client's rounds only show (the host's bursts do the
## damage, the shell kills and the skiff notices).
var net_puppet := false


static func fire(parent: Node, from: Vector3, v: Vector3, p_team: String, p_exclude: Array = [],
		p_fuse_time := 0.0) -> Node3D:
	var r: Node3D = load("res://scripts/war/flak_round.gd").new()
	r.team = p_team
	r.vel = v
	r.exclude = p_exclude
	r.fuse_time = p_fuse_time
	parent.add_child(r)
	r.global_position = from
	if Net.active:
		Net.world.on_flak_fired(r)
	return r


func _ready() -> void:
	top_level = true
	var col := Color(1.0, 0.75, 0.35) if team == "home" else Color(1.0, 0.4, 0.25)
	if _tracer_mesh == null:
		var cm := CapsuleMesh.new()
		cm.radius = 0.07
		cm.height = 2.2
		cm.radial_segments = 6
		cm.rings = 1
		_tracer_mesh = cm
	var streak := MeshInstance3D.new()
	streak.mesh = _tracer_mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(col.r * 3.0, col.g * 3.0, col.b * 3.0)
	streak.material_override = m
	streak.rotation = Vector3(-PI * 0.5, 0, 0)       # capsule +Y -> -Z (along the flight)
	streak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(streak)
	var halo := MeshInstance3D.new()
	halo.mesh = DebrisMesh.quad_mesh()
	halo.material_override = DebrisMesh.halo_material(col, 1.2, 0.004)
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halo.custom_aabb = AABB(Vector3.ONE * -20.0, Vector3.ONE * 40.0)
	add_child(halo)
	_orient()


func _orient() -> void:
	if vel.length_squared() > 1.0:
		var f := vel.normalized()
		var upv := Vector3.UP if absf(f.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
		global_basis = Basis.looking_at(f, upv)


func _physics_process(delta: float) -> void:
	if _done:
		return
	_life += delta
	var p := global_position
	var g: Vector3 = Game.gravity_at(p)
	var np := p + vel * delta + g * (delta * delta * 0.5)
	vel += g * delta
	# Proximity fuse: closest pass to a target within this step.
	var fz := _fuse_check(p, np, delta)
	if not fz.is_empty():
		_burst(fz["position"])
		return
	var hit := Ballistics.segment_hit(p, np, get_world_3d().direct_space_state, exclude)
	if not hit.is_empty():
		_burst((hit["position"] as Vector3) + (hit["normal"] as Vector3) * 0.4)
		return
	global_position = np
	_orient()
	if (fuse_time > 0.0 and _life >= fuse_time) or _life >= Balance.FLAK_ROUND_LIFE:
		_burst(np)


## {"position"} where the round passes closest to a target, when that is within the fuse radius and
## inside this step (the distance grows after it); {} otherwise.
func _fuse_check(p: Vector3, np: Vector3, dt: float) -> Dictionary:
	var best_d := Balance.FLAK_FUSE_R
	var out := {}
	for t in _fuse_targets():
		var tp: Vector3 = t[0]
		var tv: Vector3 = t[1]
		var ra := p - tp
		var rb := np - (tp + tv * dt)
		var seg := rb - ra
		var ll := seg.length_squared()
		var u := 0.0
		if ll > 1e-6:
			u = clampf(-ra.dot(seg) / ll, 0.0, 1.0)
		var d := (ra + seg * u).length()
		# Burst at the closest pass (u < 1), or right away when very close.
		if d < best_d and (u < 1.0 or d < 1.5):
			best_d = d
			out = {"position": p.lerp(np, u)}
	return out


## [position, velocity] of everything this round's fuse reacts to.
func _fuse_targets() -> Array:
	var out: Array = []
	for s in get_tree().get_nodes_in_group("skiff"):
		if s is Node3D and is_instance_valid(s) and Game.team_of(s) != team:
			var n := s as Node3D
			var v = n.get("linear_velocity")
			out.append([n.global_position + n.global_transform.basis.y * 0.9, v if v is Vector3 else Vector3.ZERO])
	if team == "home":
		for s in get_tree().get_nodes_in_group("war_shell"):
			if is_instance_valid(s) and str(s.team) != team and s.is_live():
				out.append([(s as Node3D).global_position, s.vel])
	return out


func _burst(pos: Vector3) -> void:
	_done = true
	global_position = pos
	if net_puppet or Net.is_client():
		burst_fx(get_parent(), pos, 1.0)
		queue_free()
		return
	Game.area_damage(pos, Balance.FLAK_BLAST_R, Balance.FLAK_DAMAGE, Balance.FLAK_IMPULSE, null, team)
	Game.blast.emit(pos, Balance.FLAK_BLAST_R, team)
	# Skiffs nearby notice the fire (autopilot evasion / the rival raid's retreat).
	for s in get_tree().get_nodes_in_group("skiff"):
		if s is Node3D and is_instance_valid(s) and Game.team_of(s) != team \
				and (s as Node3D).global_position.distance_to(pos) < 30.0:
			if s.has_method("ai_under_fire"):
				s.ai_under_fire(pos)
			for t in get_tree().get_nodes_in_group("war_rival_team"):
				if t.has_method("skiff_under_fire"):
					t.skiff_under_fire(s, pos)
	# Point defence: enemy cannon shells caught in the burst.
	for s in get_tree().get_nodes_in_group("war_shell"):
		if is_instance_valid(s) and str(s.team) != team and s.is_live() \
				and (s as Node3D).global_position.distance_to(pos) < Balance.FLAK_SHELL_KILL_R:
			s.shot_down(pos)
	burst_fx(get_parent(), pos, 1.0)
	queue_free()


## The look and sound of a flak burst at `pos` (`size` 1 = a round; the shot-down shell uses more).
static func burst_fx(parent: Node, pos: Vector3, size := 1.0) -> void:
	var root := Node3D.new()
	parent.add_child(root)
	root.global_position = pos
	# Flash.
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.7, 0.4)
	light.omni_range = 16.0 * size
	light.light_energy = 7.0
	light.shadow_enabled = false
	root.add_child(light)
	# Fireball: a quick bright sphere that swells and fades.
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 12
	sm.rings = 6
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fm.albedo_color = Color(2.4, 1.4, 0.6, 1.0)
	var ball := MeshInstance3D.new()
	ball.mesh = sm
	ball.material_override = fm
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ball.scale = Vector3.ONE * 0.6 * size
	root.add_child(ball)
	var halo := MeshInstance3D.new()
	halo.mesh = DebrisMesh.quad_mesh()
	var hm := DebrisMesh.halo_material(Color(1.0, 0.6, 0.3), 4.0 * size, 0.01)
	halo.material_override = hm
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(halo)
	# Shrapnel sparks and the black smoke puff.
	root.add_child(_particles(28, 0.5, 0.18, Color(1.0, 0.75, 0.4), 18.0 * size, 40.0 * size, 0.0, true))
	root.add_child(_particles(16, 4.5, 2.6 * size, Color(0.09, 0.085, 0.08, 0.85), 1.0, 4.5 * size, 1.5, false))
	# A sharp crack (distance-attenuated).
	if _burst_snd == null:
		_burst_snd = Snd.rand("expl/far", 1.12, 2.0)
	if _burst_snd != null:
		var a := AudioStreamPlayer3D.new()
		a.stream = _burst_snd
		a.unit_size = 30.0 * size
		a.max_distance = 1500.0
		a.pitch_scale = randf_range(1.15, 1.4) / sqrt(size)
		root.add_child(a)
		a.play()
	var tw := root.create_tween()
	tw.set_parallel(true)
	tw.tween_property(light, "light_energy", 0.0, 0.25)
	tw.tween_property(ball, "scale", Vector3.ONE * 2.6 * size, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(fm, "albedo_color:a", 0.0, 0.3)
	tw.tween_property(hm, "shader_parameter/base_size", 0.0, 0.35)
	tw.tween_property(hm, "shader_parameter/px", 0.0, 0.35)
	tw.chain().tween_interval(4.6)
	tw.chain().tween_callback(root.queue_free)


static func _particles(n: int, life: float, size: float, col: Color, v_min: float, v_max: float,
		damp: float, sparks: bool) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = n
	p.lifetime = life
	p.explosiveness = 1.0
	p.local_coords = false
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	if sparks:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	q.material = m
	p.mesh = q
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = v_min
	p.initial_velocity_max = v_max
	p.damping_min = damp
	p.damping_max = damp * 1.6
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var g := Gradient.new()
	if sparks:
		g.colors = PackedColorArray([Color(col.r * 3.0, col.g * 3.0, col.b * 3.0, 1.0), Color(col.r, col.g * 0.6, col.b * 0.4, 0.0)])
	else:
		g.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
		g.colors = PackedColorArray([Color(0.5, 0.35, 0.2, 0.9), col, Color(col.r, col.g, col.b, 0.0)])
		var sc := Curve.new()
		sc.add_point(Vector2(0, 0.5))
		sc.add_point(Vector2(1, 1.8))
		p.scale_amount_curve = sc
	p.color_ramp = g
	p.emitting = true
	return p
