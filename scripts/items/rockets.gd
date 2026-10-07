extends Node3D
## Rockets in flight for the Roketatar (scripts/items/rocket_launcher.gd owns one manager; it sits at
## the world origin, top_level). Each rocket is a small node (inner class Rocket, group "war_rocket":
## team, vel, is_live(), shot_down(by_pos)) that this manager steps every physics frame:
##   flight   leaves the tube at Balance.ROCKET_SPEED, the motor pushes it along its heading up to
##            ROCKET_MAX_SPEED over ROCKET_BURN s, then it coasts; Game.gravity_at pulls throughout.
##            advance() is the one motion rule, shared with predict() (the launcher's sight)
##   wobble   a slight corkscrew: the drawn body circles the true path and settles with time; the hit
##            test always follows the true path, so the aim stays fair
##   hits     Ballistics.segment_hit every step: physics (terrain, structures, the skiff on layer 4,
##            characters) and the planets' density field (the far planet has no collision); the
##            shooter's RIDs are excluded
##   impact   Explosion.spawn (radius / damage / impulse / crater: Balance.ROCKET_*, self_mult
##            ROCKET_SELF_MULT; it emits Game.blast); a direct hit on a damageable also takes
##            ROCKET_DIRECT through Game.damage_target (+ a HitFeel marker for the local player)
##   timeout  after ROCKET_LIFE s it bursts in the air (no crater, ROCKET_AIRBURST of the blast);
##            shot_down() (enemy flak, later) does the same at once
##   looks    white body, orange band, fins; an additive motor flame + flickering OmniLight while the
##            motor burns; a continuous world-space smoke ribbon with billowing puffs and embers on
##            top (the motor stops smoking at burnout); a halo that keeps it visible far away
##   sound    3D motor roar (recorded jet roar + synthesized crackle) and a whistle, both with a cheap
##            doppler shift; the roar dies at burnout, the whistle carries on; a departing whoosh
## The manager also draws one-shot bursts and light flashes for the launcher (backblast, muzzle
## smoke, dust): puff() is static so the Kinetik İtici uses it as well.
##   rockets.launch(pos, vel, team, cfg = {}, exclude_rids = [], shooter = null) -> Rocket
##       cfg: "radius", "damage", "impulse", "crater", "self_mult", "direct" (Balance.ROCKET_* when
##       missing) and "player_owned" (HitFeel markers + self_mult on Game.player; default: shooter
##       is null or Game.player). team: the firing side ("home" / "rival"), so a replayed enemy
##       rocket hits us and spares its own side's structures (Balance.FRIENDLY_FIRE)
##   rockets.flash_light(pos, color, energy, dur, range)
##   Rockets.advance(p, v, age, dt) -> [new_p, new_v]                 one motion step
##   Rockets.predict(from, vel, space, exclude, max_t) -> {} | {"position", "normal", "body", "time"}
##   Rockets.puff(parent, pos, dir, cfg) -> GPUParticles3D              one-shot, frees itself
## Multiplayer: a rocket is fully described by (pos, vel, team, cfg): the launcher emits
## rocket_launched(pos, vel, cfg) and the other machine replays it with launch() on any manager
## (launcher may stay null). Damage is host-authoritative: on a client the direct hit is skipped (the
## host's replay deals it) and Explosion.spawn already skips damage and craters there.

const Balance := preload("res://scripts/war/balance.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

const WOBBLE_R := 0.11            # m: corkscrew radius right after launch...
const WOBBLE_MIN := 0.02          # ...settling to this
const WOBBLE_RATE := 11.0         # rad/s around the path
const RIBBON_LIFE := 2.6          # s a smoke ribbon point lives
const SOUND_C := 340.0            # m/s (doppler)
const SMOKE := Color(0.8, 0.79, 0.77)

## One rocket in flight (stepped by the manager). Group "war_rocket".
class Rocket extends Node3D:
	var manager                      # the rockets.gd node stepping it
	var team := "home"
	var vel := Vector3.ZERO
	var age := 0.0
	var exclude: Array = []
	var shooter: Node3D = null
	var cfg: Dictionary = {}
	var owned := true                # fired by this machine's player (markers, self_mult)
	var done := false
	var spin := 0.0
	var burning := true
	var body_node: Node3D
	var flame: Node3D
	var light: OmniLight3D
	var halo: MeshInstance3D
	var puffs: GPUParticles3D
	var embers: GPUParticles3D
	var roar: AudioStreamPlayer3D
	var crackle: AudioStreamPlayer3D
	var whistle: AudioStreamPlayer3D
	var ribbon: Dictionary = {}
	var fade := 1.0

	## Still flying (not exploded).
	func is_live() -> bool:
		return not done

	## Destroyed in the air (an enemy flak burst, later): an airburst without a crater.
	func shot_down(_by_pos: Vector3) -> void:
		if not done and manager != null and is_instance_valid(manager):
			manager.airburst(self)


var launcher                      # rocket_launcher.gd: synthesized loops (synth_stream)
var launched := 0
var detonations := 0
var last_impact := Vector3.INF
var _list: Array = []             # live Rocket nodes
var _dead: Array = []             # [Rocket, seconds until freed] (their smoke still fading)
var _ribbons: Array = []          # {"mi", "mesh", "pts": [{p, t, drift, w, a}], "live"}
var _flashes: Array = []          # [OmniLight3D, t, dur, energy]
var _t := 0.0
static var _ribbon_mat: StandardMaterial3D
static var _roar_rec: AudioStream
static var _whoosh_rec: AudioStream


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	Explosion.prewarm()


func in_flight() -> int:
	return _list.size()


# =================================================================================================
# Motion (shared with the launcher's sight)
# =================================================================================================

## One step of a rocket's flight: motor thrust along the velocity while it burns, gravity always.
static func advance(p: Vector3, v: Vector3, age: float, dt: float) -> Array:
	var acc: Vector3 = Game.gravity_at(p)
	if age < Balance.ROCKET_BURN and v.length_squared() > 0.01:
		acc += v.normalized() * ((Balance.ROCKET_MAX_SPEED - Balance.ROCKET_SPEED) / Balance.ROCKET_BURN)
	return [p + v * dt + acc * (0.5 * dt * dt), v + acc * dt]


## Where a rocket launched from `from` at `vel` hits (same rule as the flight, coarser steps):
## {} or {"position", "normal", "body", "time"}.
static func predict(from: Vector3, vel: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array = [],
		max_t := 4.0, dt := 1.0 / 30.0) -> Dictionary:
	var p := from
	var v := vel
	var t := 0.0
	while t < max_t:
		var res := advance(p, v, t, dt)
		var np: Vector3 = res[0]
		var hit := Ballistics.segment_hit(p, np, space, exclude)
		if not hit.is_empty():
			hit["time"] = t
			return hit
		p = np
		v = res[1]
		t += dt
	return {}


# =================================================================================================
# Launch / impact
# =================================================================================================

## The launcher's numbers (rocket_launched cfg; launch() fills in whatever a replay leaves out).
static func default_cfg() -> Dictionary:
	return {"radius": Balance.ROCKET_RADIUS, "damage": Balance.ROCKET_DAMAGE, "impulse": Balance.ROCKET_IMPULSE,
			"crater": Balance.ROCKET_CRATER, "self_mult": Balance.ROCKET_SELF_MULT, "direct": Balance.ROCKET_DIRECT}


## Fires a rocket from `pos` (world) with velocity `vel` for side `p_team`. cfg: see the header.
## exclude_rids: physics RIDs it flies through (the shooter's collider); shooter: the firing
## character (damage source; markers when it is Game.player).
func launch(pos: Vector3, vel: Vector3, p_team: String, cfg: Dictionary = {}, exclude_rids: Array = [],
		shooter: Node3D = null) -> Node3D:
	var r := Rocket.new()
	r.manager = self
	r.team = p_team
	r.vel = vel
	r.exclude = exclude_rids
	r.shooter = shooter
	r.cfg = default_cfg()
	r.cfg.merge(cfg, true)
	r.owned = bool(r.cfg.get("player_owned", shooter == null or shooter == Game.player))
	r.spin = randf() * TAU
	add_child(r)
	r.global_transform = Transform3D(_look(vel), pos)
	r.add_to_group("war_rocket")
	_build_rocket(r)
	_list.append(r)
	launched += 1
	return r


func _impact(r: Rocket, point: Vector3, n: Vector3, dir: Vector3, collider) -> void:
	r.global_position = point
	_blast(r, point, n, dir, collider)
	_finish(r)


## Direct hit (if `collider` belongs to a damageable) + the explosion.
func _blast(r: Rocket, point: Vector3, n: Vector3, dir: Vector3, collider) -> void:
	var c: Dictionary = r.cfg
	var t: Node = Game.damageable_of(collider) if collider is Object else null
	var direct := float(c.get("direct", 0.0))
	# Multiplayer client: the host's replay of this rocket deals the direct hit.
	if t != null and t != r.shooter and direct > 0.0 and not Net.is_client():
		var src: Vector3 = r.shooter.global_position if r.shooter != null and is_instance_valid(r.shooter) else point - dir * 10.0
		var res := Game.damage_target(t, direct, src, dir * 9.0, r.team, point)
		if r.owned and not res.is_empty():
			HitFeel.inst().target_hit(t, res, direct, point, {"big": 0.8, "weapon": "Roketatar"})
	# On a body the blast faces back along the flight; on the ground it faces out of the surface.
	var nn := n.normalized() if (t == null and n.length_squared() > 0.01) else -dir.normalized()
	Explosion.spawn(point + nn * 0.2, nn, {"radius": float(c["radius"]), "damage": float(c["damage"]),
			"impulse": float(c["impulse"]), "crater": float(c["crater"]), "self_mult": float(c["self_mult"]),
			"player_owned": r.owned, "ground": Rifle.ground_color(point, nn), "team": r.team})
	last_impact = point
	detonations += 1


## Bursts in the air (timed out, or shot down): a smaller blast, no crater.
func airburst(r: Rocket) -> void:
	if r.done:
		return
	var p := r.global_position
	var c: Dictionary = r.cfg
	var k := Balance.ROCKET_AIRBURST
	Explosion.spawn(p, Explosion._up_at(p), {"radius": float(c["radius"]) * k, "damage": float(c["damage"]) * k,
			"impulse": float(c["impulse"]) * k, "crater": 0.0, "self_mult": float(c["self_mult"]),
			"player_owned": r.owned, "ground": Color(0.55, 0.55, 0.56), "team": r.team})
	detonations += 1
	_finish(r)


## Stops a rocket: hides it, stops its motor and sounds, lets its smoke fade, frees it later.
func _finish(r: Rocket) -> void:
	if r.done:
		return
	r.done = true
	r.remove_from_group("war_rocket")
	_list.erase(r)
	r.body_node.visible = false
	r.halo.visible = false
	r.light.visible = false
	r.puffs.emitting = false
	r.embers.emitting = false
	for p in [r.roar, r.crackle, r.whistle]:
		if p != null:
			(p as AudioStreamPlayer3D).stop()
	r.ribbon["live"] = false
	_dead.append([r, r.puffs.lifetime + 0.3])


# =================================================================================================
# Per frame
# =================================================================================================

func _physics_process(delta: float) -> void:
	for i in range(_dead.size() - 1, -1, -1):
		_dead[i][1] = float(_dead[i][1]) - delta
		if float(_dead[i][1]) <= 0.0:
			var dn = _dead[i][0]
			if is_instance_valid(dn):
				(dn as Node).queue_free()
			_dead.remove_at(i)
	if _list.is_empty():
		return
	var space := get_world_3d().direct_space_state
	for r in _list.duplicate():
		if not is_instance_valid(r):
			_list.erase(r)
			continue
		_step(r as Rocket, delta, space)


func _step(r: Rocket, delta: float, space: PhysicsDirectSpaceState3D) -> void:
	var p := r.global_position
	var res := advance(p, r.vel, r.age, delta)
	var np: Vector3 = res[0]
	var hit := Ballistics.segment_hit(p, np, space, r.exclude)
	r.age += delta
	if not hit.is_empty():
		_impact(r, hit["position"], hit["normal"], (np - p).normalized(), hit.get("body"))
		return
	r.vel = res[1]
	r.global_transform = Transform3D(_look(r.vel), np)
	if r.burning:
		_ribbon_point(r.ribbon, np + r.global_transform.basis.z * 0.3, r.vel)
		if r.age >= Balance.ROCKET_BURN:
			r.burning = false
			r.puffs.emitting = false
			r.embers.emitting = false
	if r.age >= Balance.ROCKET_LIFE:
		airburst(r)


func _process(delta: float) -> void:
	_t += delta
	var cam := get_viewport().get_camera_3d()
	var cam_pos: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	for r in _list:
		if is_instance_valid(r):
			_animate(r as Rocket, delta, cam_pos)
	for i in range(_ribbons.size() - 1, -1, -1):
		if not _draw_ribbon(_ribbons[i], cam_pos):
			(_ribbons[i]["mi"] as Node).queue_free()
			_ribbons.remove_at(i)
	for i in range(_flashes.size() - 1, -1, -1):
		var f: Array = _flashes[i]
		f[1] = float(f[1]) + delta
		var l: OmniLight3D = f[0]
		var k := 1.0 - float(f[1]) / float(f[2])
		if k <= 0.0:
			l.queue_free()
			_flashes.remove_at(i)
			continue
		l.light_energy = float(f[3]) * k * k


## Wobble, flame flicker, burnout fades, doppler.
func _animate(r: Rocket, delta: float, cam_pos: Vector3) -> void:
	r.spin += delta * WOBBLE_RATE
	var wr := WOBBLE_MIN + (WOBBLE_R - WOBBLE_MIN) * exp(-r.age * 1.2)
	r.body_node.position = Vector3(cos(r.spin), sin(r.spin), 0.0) * wr
	r.body_node.rotation = Vector3(sin(r.spin) * wr * 0.6, -cos(r.spin) * wr * 0.6, r.spin * 0.5)
	if not r.burning:
		r.fade = maxf(r.fade - delta / 0.3, 0.0)
	var f := r.fade
	var flick := randf_range(0.85, 1.15)
	r.flame.scale = Vector3(flick, flick, randf_range(0.75, 1.25)) * maxf(f, 0.001)
	r.flame.visible = f > 0.0
	r.light.light_energy = 3.6 * f * flick
	r.light.visible = f > 0.0
	r.halo.visible = f > 0.0
	# Doppler (the bus has none): pitch by the speed toward the listener.
	var to_cam := cam_pos - r.global_position
	var rad := r.vel.dot(to_cam.normalized()) if to_cam.length_squared() > 0.01 else 0.0
	var dop := clampf(SOUND_C / maxf(SOUND_C - rad, 90.0), 0.6, 1.8)
	var spd := clampf(r.vel.length() / Balance.ROCKET_MAX_SPEED, 0.0, 1.2)
	if r.roar != null:
		r.roar.pitch_scale = (1.3 + 0.25 * spd) * dop
		r.roar.volume_db = 2.0 + linear_to_db(maxf(f, 0.001))
		if f <= 0.0 and r.roar.playing:
			r.roar.stop()
	if r.crackle != null:
		r.crackle.pitch_scale = (0.9 + 0.2 * spd) * dop
		r.crackle.volume_db = -3.0 + linear_to_db(maxf(f, 0.001))
		if f <= 0.0 and r.crackle.playing:
			r.crackle.stop()
	if r.whistle != null:
		r.whistle.pitch_scale = (0.8 + 0.35 * spd) * dop
		r.whistle.volume_db = lerpf(-8.0, -15.0, f)


# =================================================================================================
# Building a rocket
# =================================================================================================

func _build_rocket(r: Rocket) -> void:
	r.body_node = Node3D.new()
	r.add_child(r.body_node)
	var white := _mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var dark := _mat(Color(0.18, 0.19, 0.21), 0.35, 0.65)
	var orange := _mat(Color(0.95, 0.42, 0.08), 0.5, 0.0)
	var steel := _mat(Color(0.62, 0.64, 0.68), 0.3, 0.85)
	# Nose at -Z: fuze, warhead cone, band, motor body, nozzle, deployed fins.
	_cyl(r.body_node, 0.008, 0.004, 0.015, steel, -0.255)
	_cyl(r.body_node, 0.045, 0.008, 0.11, dark, -0.192)
	_cyl(r.body_node, 0.046, 0.046, 0.02, orange, -0.127)
	_cyl(r.body_node, 0.044, 0.044, 0.27, white, 0.018)
	_cyl(r.body_node, 0.03, 0.038, 0.06, dark, 0.183)
	for k in 4:
		var a := PI * 0.25 + k * PI * 0.5
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.004, 0.05, 0.09)
		mi.mesh = bm
		mi.material_override = dark
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.transform = Transform3D(Basis(Vector3.BACK, a - PI * 0.5), Vector3(cos(a), sin(a), 0.0) * 0.066 + Vector3(0, 0, 0.15))
		r.body_node.add_child(mi)
	# Motor flame (additive cones, wide at the nozzle), light and a far halo.
	r.flame = Node3D.new()
	r.flame.position = Vector3(0, 0, 0.215)
	r.body_node.add_child(r.flame)
	_flame_cone(r.flame, 0.065, 0.85, Color(1.0, 0.55, 0.22), 4.0)
	_flame_cone(r.flame, 0.035, 0.42, Color(1.0, 0.9, 0.7), 7.0)
	r.light = OmniLight3D.new()
	r.light.light_color = Color(1.0, 0.62, 0.32)
	r.light.omni_range = 11.0
	r.light.light_energy = 3.6
	r.light.shadow_enabled = false
	r.light.position = Vector3(0, 0, 0.7)
	r.body_node.add_child(r.light)
	r.halo = MeshInstance3D.new()
	r.halo.mesh = DebrisMesh.quad_mesh()
	r.halo.material_override = DebrisMesh.halo_material(Color(1.0, 0.65, 0.35), 0.9, 0.0045, 0.0)
	r.halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	r.halo.custom_aabb = AABB(Vector3.ONE * -50.0, Vector3.ONE * 100.0)
	r.halo.position = Vector3(0, 0, 0.35)
	r.body_node.add_child(r.halo)
	# Smoke: billowing puffs (world space) over the continuous ribbon, embers out of the nozzle.
	var g: Vector3 = Game.gravity_at(r.global_position)
	r.puffs = _trail_emitter(r, 130, 2.1, 0.75, false, -g * 0.03)
	r.embers = _trail_emitter(r, 36, 0.28, 0.07, true, g * 0.2)
	r.ribbon = _new_ribbon()
	# Sound: recorded roar + synthesized crackle and whistle, and a departing whoosh.
	if _roar_rec == null:
		_roar_rec = Snd.loop("ship/jetpack")
		_whoosh_rec = Snd.rand("whoosh/rocket", 1.05, 1.0)
	r.roar = _audio(r, _roar_rec, 2.0, 12.0)
	r.crackle = _audio(r, _synth("rocket_roar"), -3.0, 9.0)
	r.whistle = _audio(r, _synth("rocket_whistle"), -15.0, 7.0)
	var wh := _audio(r, _whoosh_rec, -2.0, 10.0)
	if wh != null:
		wh.finished.connect(wh.queue_free)


## A synthesized loop from the arsenal cache (weapon_base.gd synth_stream); a replay manager without a
## launcher borrows any of the local player's guns.
func _synth(name: String) -> AudioStream:
	var src = launcher
	if src == null or not is_instance_valid(src):
		src = null
		var pl = Game.player
		if pl != null and is_instance_valid(pl) and pl.get("items") is Array:
			for it in pl.items:
				if it != null and it.has_method("synth_stream"):
					src = it
					break
	if src != null and src.has_method("synth_stream"):
		return src.synth_stream(name)
	return null


func _audio(r: Rocket, st: AudioStream, vol: float, unit: float) -> AudioStreamPlayer3D:
	if st == null:
		return null
	var p := AudioStreamPlayer3D.new()
	p.stream = st
	p.volume_db = vol
	p.unit_size = unit
	p.max_distance = 600.0
	p.max_db = 4.0
	p.position = Vector3(0, 0, 0.3)
	r.add_child(p)
	p.play(randf() * 0.5 if st is AudioStreamWAV and (st as AudioStreamWAV).loop_mode != AudioStreamWAV.LOOP_DISABLED else 0.0)
	return p


func _mat(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


## Cylinder along the rocket's axis (top_radius toward the nose, -Z), centred at z.
func _cyl(parent: Node3D, r_tail: float, r_nose: float, h: float, m: Material, z: float) -> void:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r_tail
	cm.top_radius = r_nose
	cm.height = h
	cm.radial_segments = 16
	cm.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 0, z))
	parent.add_child(mi)


## Additive flame cone trailing backward (+Z) from the nozzle.
func _flame_cone(parent: Node3D, r: float, length: float, col: Color, energy: float) -> void:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r
	cm.top_radius = 0.0
	cm.height = length
	cm.radial_segments = 12
	cm.rings = 1
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(col.r, col.g, col.b, 0.85)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, 0, length * 0.5))
	parent.add_child(mi)


## World-space trail emitter at the nozzle: smoke puffs (lit, growing) or embers (additive sparks).
func _trail_emitter(r: Rocket, amount: int, life: float, size: float, hot: bool, gravity: Vector3) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.amount = amount
	e.lifetime = life
	e.local_coords = false
	e.randomness = 0.3
	e.visibility_aabb = AABB(Vector3.ONE * -400.0, Vector3.ONE * 800.0)
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0, 1)
	pm.spread = 18.0 if hot else 30.0
	pm.initial_velocity_min = 5.0 if hot else 0.4
	pm.initial_velocity_max = 13.0 if hot else 2.2
	pm.damping_min = 2.0 if hot else 1.0
	pm.damping_max = 4.0 if hot else 2.0
	pm.gravity = gravity
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.03 if hot else 0.08
	pm.scale_min = 0.6
	pm.scale_max = 1.3
	var cv := Curve.new()
	cv.max_value = 4.0
	if hot:
		cv.add_point(Vector2(0.0, 1.0))
		cv.add_point(Vector2(1.0, 0.2))
	else:
		cv.add_point(Vector2(0.0, 0.35))
		cv.add_point(Vector2(0.3, 1.4))
		cv.add_point(Vector2(1.0, 3.2))
	var ct := CurveTexture.new()
	ct.curve = cv
	pm.scale_curve = ct
	var gr := Gradient.new()
	if hot:
		gr.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
		gr.colors = PackedColorArray([Color(1.0, 0.92, 0.7, 1.0), Color(1.0, 0.55, 0.2, 0.9), Color(0.8, 0.2, 0.05, 0.0)])
	else:
		gr.offsets = PackedFloat32Array([0.0, 0.05, 0.25, 1.0])
		gr.colors = PackedColorArray([Color(1.0, 0.8, 0.55, 0.0), Color(0.95, 0.9, 0.84, 0.55),
				Color(SMOKE, 0.4), Color(SMOKE, 0.0)])
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	pm.color_ramp = gt
	pm.color = Color(3.0, 3.0, 3.0) if hot else Color.WHITE
	e.process_material = pm
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_texture = DigFx.soft_texture()
	if hot:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	else:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		m.roughness = 1.0
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = m
	e.draw_pass_1 = q
	e.position = Vector3(0, 0, 0.3)
	r.add_child(e)
	e.emitting = true
	return e


static func _look(dir: Vector3) -> Basis:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.FORWARD
	var ref := Vector3.UP if absf(d.y) < 0.97 else Vector3.RIGHT
	return Basis.looking_at(d, ref)


static func _basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.UP
	var ref := Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


# =================================================================================================
# Smoke ribbon: a continuous camera-facing strip along the burn (the puffs alone leave gaps at
# 80 m/s); it widens, drifts and fades over RIBBON_LIFE s.
# =================================================================================================

func _new_ribbon() -> Dictionary:
	if _ribbon_mat == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
		var tex := GradientTexture2D.new()
		tex.gradient = g
		tex.fill_from = Vector2(0.0, 0.0)
		tex.fill_to = Vector2(0.0, 1.0)
		tex.width = 4
		tex.height = 64
		_ribbon_mat = StandardMaterial3D.new()
		_ribbon_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ribbon_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_ribbon_mat.vertex_color_use_as_albedo = true
		_ribbon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		_ribbon_mat.roughness = 1.0
		_ribbon_mat.metallic_specular = 0.0
		_ribbon_mat.albedo_texture = tex
	var im := ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = _ribbon_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var rb := {"mi": mi, "mesh": im, "pts": [], "live": true}
	_ribbons.append(rb)
	return rb


func _ribbon_point(rb: Dictionary, p: Vector3, v: Vector3) -> void:
	if rb.is_empty():
		return
	var up := Explosion._up_at(p)
	var rnd := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.3
	var drift := rnd + up * 0.12 - v.normalized() * 0.6
	(rb["pts"] as Array).append({"p": p, "t": _t, "drift": drift, "w": randf_range(0.8, 1.25), "a": randf_range(0.7, 1.0)})


## Rebuilds one ribbon for this frame; false once it has faded out completely (and its rocket is gone).
func _draw_ribbon(rb: Dictionary, cam_pos: Vector3) -> bool:
	var pts: Array = rb["pts"]
	while not pts.is_empty() and _t - float(pts[0]["t"]) > RIBBON_LIFE:
		pts.pop_front()
	var im: ImmediateMesh = rb["mesh"]
	im.clear_surfaces()
	if pts.size() < 2:
		return rb["live"] or not pts.is_empty()
	var n := pts.size()
	var pos := PackedVector3Array()
	pos.resize(n)
	for i in n:
		var pt: Dictionary = pts[i]
		pos[i] = (pt["p"] as Vector3) + (pt["drift"] as Vector3) * (_t - float(pt["t"]))
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in n:
		var pt: Dictionary = pts[i]
		var age := _t - float(pt["t"])
		var k := clampf(age / RIBBON_LIFE, 0.0, 1.0)
		var p := pos[i]
		var tan := pos[mini(i + 1, n - 1)] - pos[maxi(i - 1, 0)]
		var to_cam := cam_pos - p
		var side := tan.cross(to_cam)
		if side.length_squared() < 1e-6:
			side = tan.cross(Vector3.UP) if absf(tan.normalized().y) < 0.9 else tan.cross(Vector3.RIGHT)
		side = side.normalized()
		var w := lerpf(0.1, 1.5, sqrt(k)) * float(pt["w"])
		# Fade in behind the nozzle, out with age; warm right at the flame.
		var a := clampf(age / 0.06, 0.0, 1.0) * pow(1.0 - k, 1.6) * 0.5 * float(pt["a"])
		var col := Color(1.0, 0.78, 0.5).lerp(SMOKE, clampf(age / 0.12, 0.0, 1.0))
		col.a = a
		var nrm := to_cam.normalized() if to_cam.length_squared() > 1e-6 else Vector3.UP
		im.surface_set_normal(nrm)
		im.surface_set_color(col)
		im.surface_set_uv(Vector2(k, 0.0))
		im.surface_add_vertex(p - side * w)
		im.surface_set_normal(nrm)
		im.surface_set_color(col)
		im.surface_set_uv(Vector2(k, 1.0))
		im.surface_add_vertex(p + side * w)
	im.surface_end()
	return true


# =================================================================================================
# One-shot bursts and light flashes (launcher backblast, muzzle smoke, dust; the Kinetik İtici)
# =================================================================================================

## A short light flash at pos that decays over dur s.
func flash_light(pos: Vector3, col: Color, energy: float, dur: float, light_range: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.omni_range = light_range
	l.shadow_enabled = false
	add_child(l)
	l.global_position = pos
	_flashes.append([l, 0.0, maxf(dur, 0.02), energy])


## One-shot GPU particle burst at world pos, aimed along dir (frees itself when done). cfg:
## amount, life, vmin, vmax, damp, spread (deg), size, scale [start, 25 %, end], ramp [[offset,
## Color], ...], color (multiplier), add (additive glow) or lit smoke, gravity (world m/s²),
## radius (emission sphere), explosive.
static func puff(parent: Node, pos: Vector3, dir: Vector3, o: Dictionary) -> GPUParticles3D:
	if parent == null or not parent.is_inside_tree():
		return null
	var e := GPUParticles3D.new()
	e.one_shot = true
	e.amount = maxi(int(o.get("amount", 16)), 1)
	e.lifetime = float(o.get("life", 1.5))
	e.explosiveness = float(o.get("explosive", 0.92))
	e.randomness = 0.4
	e.local_coords = false
	e.visibility_aabb = AABB(Vector3.ONE * -30.0, Vector3.ONE * 60.0)
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = float(o.get("spread", 30.0))
	pm.initial_velocity_min = float(o.get("vmin", 1.0))
	pm.initial_velocity_max = float(o.get("vmax", 4.0))
	pm.damping_min = float(o.get("damp", 2.0)) * 0.7
	pm.damping_max = float(o.get("damp", 2.0))
	pm.gravity = o.get("gravity", Vector3.ZERO)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = float(o.get("radius", 0.1))
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	var sc: Array = o.get("scale", [0.5, 1.2, 2.0])
	var cv := Curve.new()
	cv.max_value = 4.0
	cv.add_point(Vector2(0.0, float(sc[0])))
	cv.add_point(Vector2(0.25, float(sc[1])))
	cv.add_point(Vector2(1.0, float(sc[2])))
	var ct := CurveTexture.new()
	ct.curve = cv
	pm.scale_curve = ct
	var ramp: Array = o.get("ramp", [[0.0, Color(1, 1, 1, 0.6)], [1.0, Color(1, 1, 1, 0)]])
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for k in ramp:
		offs.append(float(k[0]))
		cols.append(k[1])
	var g := Gradient.new()
	g.offsets = offs
	g.colors = cols
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = o.get("color", Color.WHITE)
	e.process_material = pm
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_texture = DigFx.soft_texture()
	if o.get("add", false):
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	else:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		m.roughness = 1.0
	var q := QuadMesh.new()
	q.size = Vector2.ONE * float(o.get("size", 0.5))
	q.material = m
	e.draw_pass_1 = q
	parent.add_child(e)
	e.global_transform = Transform3D(_basis_y(dir), pos)
	e.emitting = true
	e.finished.connect(e.queue_free)
	return e
