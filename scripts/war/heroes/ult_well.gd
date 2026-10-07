extends "res://scripts/war/heroes/ult_base.gd"
## Mühendis — Yerçekimi Kuyusu. A singularity lobbed from the caster's hand ("from") to the aimed point
## ("pos", HERO_WELL_FLIGHT s, an arc), where it opens for HERO_WELL_TIME s: bent light (a lens sphere
## over the screen), dust spiralling in, a rushing hum. It pulls enemies within HERO_WELL_R m toward a
## point HOLD_H m over it (HERO_WELL_PULL m/s² at the edge, × 2 at the centre; in this low gravity that
## lifts you off your feet): each machine pulls its own player, the host the bots (small shoves through
## Game.damage_target) and loose rigid bodies (wrecks, debris). Then it pops (an Explosion for the look,
## HERO_WELL_POP_DMG to the caster's enemies within HERO_WELL_POP_R m, a small crater on the host).

const Explosion := preload("res://scripts/items/explosion.gd")

const HOLD_H := 2.5
const BOT_SHOVE_DT := 0.25

var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _up := Vector3.UP
var _body: Node3D
var _orb: Node3D
var _lens: MeshInstance3D
var _lens_mat: ShaderMaterial
var _swirl: GPUParticles3D
var _light: OmniLight3D
var _hum: AudioStreamPlayer3D
var _open := false
var _popped := false
var _shove_t := 0.0
var _warned := false


static func prepare(_heroes, caster: Node3D, data: Dictionary) -> String:
	var body = data.get("body")
	if not (data.get("pos") is Vector3) or not (body is Node3D) or not is_instance_valid(body):
		return "Hedef yok"
	if caster == null or not is_instance_valid(caster):
		return "Atılamadı"
	var pos: Vector3 = data["pos"]
	if caster.global_position.distance_to(pos) > Balance.HERO_WELL_RANGE + 6.0:
		return "Hedef menzil dışında"
	var up := (pos - (body as Node3D).global_position).normalized()
	data["up"] = up
	if not (data.get("from") is Vector3):
		var cu := (caster.global_position - (body as Node3D).global_position).normalized()
		data["from"] = caster.global_position + cu * 1.5
	return ""


func _begin() -> void:
	_body = data.get("body")
	_to = data.get("pos", Vector3.ZERO)
	_from = data.get("from", _to)
	_up = data.get("up", up_at(_to))
	if _body == null or not is_instance_valid(_body):
		life = 0.0
		return
	life = Balance.HERO_WELL_FLIGHT + Balance.HERO_WELL_TIME + 1.0
	var col := HeroData.color("muhendis")
	_orb = Node3D.new()
	add_child(_orb)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.32
	sm.height = 0.64
	sm.radial_segments = 16
	sm.rings = 8
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.02, 0.01, 0.04)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 0.6
	m.rim_enabled = true
	m.rim = 1.0
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_orb.add_child(mi)
	_light = OmniLight3D.new()
	_light.light_color = col
	_light.omni_range = 6.0
	_light.light_energy = 1.2
	_light.shadow_enabled = false
	_orb.add_child(_light)
	_orb.global_position = _from
	if Game.sfx:
		Game.sfx.play("whoosh", -6.0, 0.8)


func _centre() -> Vector3:
	return _to + _up * HOLD_H


func _open_well() -> void:
	_open = true
	var c := _centre()
	_orb.global_position = c
	_lens = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 32
	sm.rings = 16
	_lens.mesh = sm
	_lens_mat = HeroFx.lens_material()
	_lens_mat.set_shader_parameter("tint", HeroData.color("muhendis"))
	_lens.material_override = _lens_mat
	_lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_orb.add_child(_lens)
	_lens.scale = Vector3.ONE * 0.1
	_swirl = _make_swirl()
	_orb.add_child(_swirl)
	var st := HeroFx.sound("suck")
	if st != null:
		_hum = AudioStreamPlayer3D.new()
		_hum.stream = st
		_hum.unit_size = 10.0
		_hum.max_distance = 120.0
		_hum.volume_db = -4.0
		_orb.add_child(_hum)
		_hum.play()
	if not is_friend() and my_dist(c) < Balance.HERO_WELL_R + 10.0:
		HudLevel.alert("YERÇEKİMİ KUYUSU — uzaklaş!", 2, "hero_well", 2.5)


func _make_swirl() -> GPUParticles3D:
	var g := GPUParticles3D.new()
	g.amount = 160
	g.lifetime = 1.2
	g.local_coords = false
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.visibility_aabb = AABB(Vector3.ONE * -15.0, Vector3.ONE * 30.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	pm.emission_sphere_radius = Balance.HERO_WELL_R * 0.8
	pm.gravity = Vector3.ZERO
	pm.radial_accel_min = -22.0
	pm.radial_accel_max = -14.0
	pm.tangential_accel_min = 6.0
	pm.tangential_accel_max = 10.0
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	var gr := Gradient.new()
	gr.set_color(0, Color(0.6, 0.5, 0.45, 0.0))
	gr.set_color(1, Color(0.8, 0.55, 1.0, 0.0))
	gr.add_point(0.4, Color(0.65, 0.55, 0.6, 0.6))
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	pm.color_ramp = gt
	g.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.25, 0.25)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	qm.vertex_color_use_as_albedo = true
	q.material = qm
	g.draw_pass_1 = q
	g.emitting = true
	return g


func _tick(delta: float) -> void:
	if _body == null or not is_instance_valid(_body):
		finish("gone")
		return
	var fl := Balance.HERO_WELL_FLIGHT
	if t < fl:
		var k := t / fl
		_orb.global_position = _from.lerp(_to, k) + _up * (4.0 * k * (1.0 - k) * 4.0 + HOLD_H * k)
		return
	if not _open:
		_open_well()
	var act := t - fl
	if act < Balance.HERO_WELL_TIME:
		var grow := clampf(act / 0.4, 0.0, 1.0)
		var wob := 1.0 + 0.06 * sin(t * 17.0)
		_lens.scale = Vector3.ONE * 2.6 * grow * wob
		_lens_mat.set_shader_parameter("k", grow)
		_light.light_energy = 1.2 + 1.5 * grow
		_pull(delta)
		return
	if not _popped:
		_pop()
	var after := act - Balance.HERO_WELL_TIME
	if _lens != null:
		_lens.scale = Vector3.ONE * maxf(2.6 * (1.0 - after * 6.0), 0.01)
	if _light != null:
		_light.light_energy = maxf(3.0 * (1.0 - after * 3.0), 0.0)


func _pull(delta: float) -> void:
	var c := _centre()
	var R := Balance.HERO_WELL_R
	# Our own player, if he is on the other side (every machine pulls its own).
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and not pl.is_dead() and pl.get("vehicle") == null and not is_friend():
		var to: Vector3 = c - (pl as Node3D).global_position
		var d := to.length()
		if d < R and d > 0.3:
			var a := Balance.HERO_WELL_PULL * (2.0 - d / R)
			pl.velocity += to / d * a * delta
			if not _warned:
				_warned = true
				if pl.has_method("add_trauma"):
					pl.add_trauma(0.3)
	if not authority():
		return
	_shove_t -= delta
	if _shove_t <= 0.0:
		_shove_t = BOT_SHOVE_DT
		var foe: String = heroes.enemy_of(team)
		for n in heroes.units():
			if n == Game.player or n.is_in_group("net_player") or not is_instance_valid(n) or n.is_dead():
				continue
			if Game.team_of(n) != foe:
				continue
			var to: Vector3 = c - (n as Node3D).global_position
			var d := to.length()
			if d < R and d > 0.4:
				var v := to / d * Balance.HERO_WELL_PULL * (2.0 - d / R) * BOT_SHOVE_DT * 1.6
				Game.damage_target(n, 1.0, c, v, team)
		var space := get_world_3d().direct_space_state
		var q := PhysicsShapeQueryParameters3D.new()
		var sph := SphereShape3D.new()
		sph.radius = R
		q.shape = sph
		q.transform = Transform3D(Basis(), c)
		q.collision_mask = Game.LAYER_VEHICLE
		for h in space.intersect_shape(q, 12):
			var rb = h.get("collider")
			if rb is RigidBody3D and not (rb as Node).is_in_group("skiff"):
				var b := rb as RigidBody3D
				var to2 := c - b.global_position
				var d2 := maxf(to2.length(), 0.5)
				b.apply_central_impulse(to2 / d2 * b.mass * Balance.HERO_WELL_PULL * BOT_SHOVE_DT * (2.0 - minf(d2 / R, 1.0)))


func _pop() -> void:
	_popped = true
	var c := _centre()
	if _swirl != null:
		_swirl.emitting = false
	if _hum != null:
		_hum.stop()
	Explosion.spawn(c, _up, {"radius": Balance.HERO_WELL_POP_R, "damage": 0.0, "impulse": Balance.HERO_WELL_POP_IMPULSE,
			"crater": 1.2, "player_owned": false, "team": team, "ground": Color(0.6, 0.45, 0.9)})
	if authority():
		heroes.area_hit(c, Balance.HERO_WELL_POP_R * Balance.BLAST_RADIUS_SCALE, Balance.HERO_WELL_POP_DMG,
				Balance.HERO_WELL_POP_IMPULSE, team, caster if caster_ok() else null, "Yerçekimi Kuyusu")
