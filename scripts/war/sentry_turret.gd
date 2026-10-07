extends "res://scripts/war/base_piece.gd"
## Otomatik Taret (sentry turret), İnşa Aracı (Savunma; Balance.TURRET_*), on the surface, in a tunnel
## or inside a Sığınak Modülü. A steel base plate with anchor feet and a pedestal; on the slewing ring an
## armoured head (yaw, `_turret`) with side ammo boxes and feed chutes, a sensor dome with a red eye on
## top; in its cradle (pitch, `_cradle`) twin machine guns with perforated jackets and flash hiders.
##
## Fire control (host / single player): every TURRET_SENSE s the nearest ENEMY in TURRET_RANGE m that
## it can see (terrain collision AND the density field, friendly bodies block the line): rival bots /
## pod crews (group "war_ai"), the enemy player / remote player ("net_player"), drop pods still
## descending ("war_drop_pod", is_live()). Allies are never targets (team filter: friendly "home" bots,
## the co-op partner) and a burst is held while a friend is in the line of fire. After TURRET_REACT s of
## sight it turns (TURRET_TURN_RATE) and fires bursts once it points within TURRET_FIRE_CONE_DEG: each
## round a real ray with TURRET_SPREAD_DEG scatter; a body it hits takes TURRET_DAMAGE through
## Game.damage_target(..., team, hit point) (friendly fire rules stay Game's). A pod takes one POD_HITS
## hit per TURRET_POD_DAMAGE of rounds. A burst costs its owner TURRET_BURST_COST m³ (Balance header).
## No target: a slow search sweep.
## Signals: fired(from, to) every round (host; for a multiplayer replay); destroyed.
## Multiplayer structure state: _yaw_t / _pitch_t = the aim (local yaw about its up, pitch above the
## horizon), tracking = a burst is firing. A client turns to the aim and, while tracking, shows rounds
## (tracers, flashes, sound; no damage) at TURRET_RATE along its barrels. Group "war_turret".

const Snd := preload("res://scripts/audio/snd_lib.gd")

const RING_Y := 1.0
const HEAD_Y := 1.12
const BARREL_L := 0.78
const GUN_X := 0.13
const TRACERS := 8
const TRACER_SPEED := 520.0
const TRACER_LEN := 2.4

signal fired(from: Vector3, to: Vector3)
## Multiplayer host: a burst of a client-built turret to be paid by that client (net_world.gd).
signal burst_cost(peer: int, amount: float)

var peer_broke := false                # (host) the owning client could not pay the last burst

var yaw := 0.0
var pitch := 0.0
var _turret: Node3D
var _cradle: Node3D
var _muzzles: Array = []
var _barrel := 0
var _target: Node3D = null
var _in_sight := false
var _seen := 0.0
var _lost := 0.0
var _sense_t := 0.0
var _burst_left := 0
var _shot_t := 0.0
var _pause_t := 0.0
var _starved := false
var _pod_dmg := 0.0
var _rest_yaw := 0.0
var _rng := RandomNumberGenerator.new()
var _recoil := [0.0, 0.0]
var _barrel_nodes: Array = []
var _eye_mat: StandardMaterial3D
var _flash: OmniLight3D
var _flash_t := 0.0
var _flash_meshes: Array = []
var _tracers: Array = []               # {mi, from, to, t, len}
var _tracer_mat: StandardMaterial3D
var _gun_audio: AudioStreamPlayer3D
var _was_tracking := false


static func footprint() -> Vector3:
	return Vector3(1.0, 0.85, 1.0)


func piece_kind() -> String:
	return "sentry_turret"


func piece_name() -> String:
	return "Otomatik Taret"


func piece_group() -> String:
	return "war_turret"


func piece_hp() -> float:
	return Balance.TURRET_HP


func footprint_r() -> float:
	return Balance.TURRET_FOOTPRINT


func blast_mult() -> float:
	return Balance.TURRET_BLAST_MULT


func shelter_point() -> Vector3:
	return global_position + global_transform.basis.y.normalized() * HEAD_Y


func _foundation_shape() -> Array:
	return [Foundation.polygon(10, 0.62, 0.0), [], Color(0.33, 0.33, 0.34)]


func _build_piece() -> void:
	_rng.randomize()
	var home := team == "home"
	_paint = _mat(Color(0.82, 0.83, 0.82) if home else Color(0.21, 0.2, 0.2), 0.25 if home else 0.55, 0.45)
	var stripe := _mat(Color(0.95, 0.42, 0.08) if home else Color(0.72, 0.12, 0.08), 0.0, 0.5)
	var steel := _mat(Color(0.34, 0.35, 0.37), 0.85, 0.38)
	var gun := _mat(Color(0.08, 0.085, 0.09), 0.8, 0.32)
	var dark := _mat(Color(0.14, 0.145, 0.15), 0.6, 0.45)
	var olive := _mat(Color(0.27, 0.29, 0.22), 0.3, 0.6)
	var brass := _mat(Color(0.86, 0.66, 0.3), 0.9, 0.3)
	var bolt := _mat(Color(0.55, 0.56, 0.58), 0.9, 0.3)
	var haz := hazard()
	# --- Base plate, anchor feet, pedestal.
	var base := _part(0.0)
	_cyl(base, Vector3(0, 0.04, 0), 0.6, 0.64, 0.08, steel, Vector3.ZERO, 10)
	_cyl(base, Vector3(0, 0.085, 0), 0.62, 0.62, 0.012, haz, Vector3.ZERO, 10)
	for k in 3:
		var a := TAU * float(k) / 3.0 + 0.4
		var d := Vector3(cos(a), 0, sin(a))
		_box(base, d * 0.75 + Vector3(0, 0.05, 0), Vector3(0.42, 0.1, 0.16), dark, Vector3(0, -a, 0))
		_cyl(base, d * 0.88 + Vector3(0, 0.12, 0), 0.03, 0.03, 0.1, bolt, Vector3.ZERO, 6)
	for k in 8:
		var a := TAU * float(k) / 8.0
		_cyl(base, Vector3(cos(a) * 0.5, 0.095, sin(a) * 0.5), 0.025, 0.025, 0.03, bolt, Vector3.ZERO, 6)
	var ped := _part(0.15)
	_cyl(ped, Vector3(0, 0.5, 0), 0.15, 0.2, 0.84, _paint, Vector3.ZERO, 14)
	_cyl(ped, Vector3(0, 0.7, 0), 0.165, 0.165, 0.04, stripe, Vector3.ZERO, 14)
	_cyl(ped, Vector3(0, RING_Y - 0.04, 0), 0.3, 0.26, 0.1, dark, Vector3.ZERO, 18)
	_seg(ped, Vector3(0.12, 0.12, 0.14), Vector3(0.14, 0.75, 0.1), 0.025, gun, 6)      # cable
	_box(ped, Vector3(0, 0.42, 0.2), Vector3(0.22, 0.3, 0.08), dark)                     # junction box
	_lamp(ped, Vector3(0.06, 0.5, 0.245), _col_team, 0.02, 2.0)
	_col_box(Vector3(0, 0.5, 0), Vector3(0.4, 1.0, 0.4))
	_col_box(Vector3(0, 0.05, 0), Vector3(1.2, 0.1, 1.2))
	# --- Head (yaw).
	var head_part := _part(0.3)
	_turret = Node3D.new()
	_turret.position = Vector3(0, HEAD_Y, 0)
	head_part.add_child(_turret)
	_cyl(_turret, Vector3(0, -0.06, 0), 0.28, 0.3, 0.06, steel, Vector3.ZERO, 18)
	# Armoured housing: a box with chamfered edges (slanted plates).
	_box(_turret, Vector3(0, 0.14, 0.05), Vector3(0.56, 0.3, 0.62), _paint)
	_box(_turret, Vector3(0, 0.3, 0.02), Vector3(0.46, 0.06, 0.5), _paint, Vector3(0.08, 0, 0))
	for sx: float in [1.0, -1.0]:
		_box(_turret, Vector3(sx * 0.3, 0.19, 0.05), Vector3(0.06, 0.18, 0.6), _paint, Vector3(0, 0, -sx * 0.35))
		# Ammo boxes and feed chutes.
		_box(_turret, Vector3(sx * 0.42, 0.06, 0.12), Vector3(0.18, 0.26, 0.4), olive)
		_box(_turret, Vector3(sx * 0.42, 0.2, 0.12), Vector3(0.19, 0.025, 0.41), dark)
		_box(_turret, Vector3(sx * 0.513, 0.06, 0.12), Vector3(0.006, 0.1, 0.2), stripe)
		_seg(_turret, Vector3(sx * 0.36, 0.17, -0.02), Vector3(sx * 0.2, 0.17, -0.2), 0.03, gun, 6)
	_box(_turret, Vector3(0, 0.14, 0.37), Vector3(0.5, 0.22, 0.08), dark)                # rear hatch
	_box(_turret, Vector3(0, 0.27, 0.36), Vector3(0.5, 0.025, 0.09), stripe)
	# Sensor dome with the eye.
	_cyl(_turret, Vector3(0, 0.38, -0.05), 0.09, 0.11, 0.1, dark, Vector3.ZERO, 14)
	var dome := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.1
	sm.height = 0.2
	sm.radial_segments = 16
	sm.rings = 8
	dome.mesh = sm
	dome.material_override = gun
	dome.position = Vector3(0, 0.45, -0.05)
	_turret.add_child(dome)
	_eye_mat = _lamp(_turret, Vector3(0, 0.45, -0.14), Color(1.0, 0.18, 0.12), 0.035, 3.0)
	_seg(_turret, Vector3(0.18, 0.3, 0.25), Vector3(0.2, 0.62, 0.3), 0.008, steel, 5)       # whip antenna
	# --- Cradle (pitch) with the twin guns.
	_cradle = Node3D.new()
	_cradle.position = Vector3(0, 0.14, -0.22)
	_turret.add_child(_cradle)
	_box(_cradle, Vector3(0, 0, 0.0), Vector3(0.38, 0.2, 0.22), dark)
	_box(_cradle, Vector3(0, 0.0, -0.12), Vector3(0.44, 0.24, 0.04), _paint)                # mantlet
	for sx: float in [-1.0, 1.0]:
		var b := Node3D.new()
		b.position = Vector3(sx * GUN_X, 0.0, -0.1)
		_cradle.add_child(b)
		_barrel_nodes.append(b)
		_box(b, Vector3(0, 0, 0.02), Vector3(0.09, 0.11, 0.26), gun)                       # receiver
		_cyl(b, Vector3(0, 0, -BARREL_L * 0.5), 0.022, 0.022, BARREL_L, gun, Vector3(PI * 0.5, 0, 0), 10)
		_cyl(b, Vector3(0, 0, -0.26), 0.045, 0.045, 0.34, dark, Vector3(PI * 0.5, 0, 0), 12)     # jacket
		for k in 5:
			_cyl(b, Vector3(0, 0, -0.13 - k * 0.065), 0.047, 0.047, 0.012, steel, Vector3(PI * 0.5, 0, 0), 12)
		_cyl(b, Vector3(0, 0, -BARREL_L - 0.03), 0.03, 0.026, 0.07, steel, Vector3(PI * 0.5, 0, 0), 8)   # flash hider
		_box(b, Vector3(0, -0.07, 0.02), Vector3(0.02, 0.05, 0.08), brass)                     # brass in the feed
		var mz := Node3D.new()
		mz.position = Vector3(0, 0, -BARREL_L - 0.08)
		b.add_child(mz)
		_muzzles.append(mz)
		# Muzzle flash: a star of two crossed quads, hidden between rounds.
		var fm := _mat(Color(1.0, 0.72, 0.35), 0.0, 1.0, 6.0)
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		fm.cull_mode = BaseMaterial3D.CULL_DISABLED
		fm.albedo_color = Color(1.0, 0.7, 0.35, 0.85)
		var fl := Node3D.new()
		mz.add_child(fl)
		for r in 2:
			var q := QuadMesh.new()
			q.size = Vector2(0.14, 0.36)
			var qm := MeshInstance3D.new()
			qm.mesh = q
			qm.material_override = fm
			qm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			qm.rotation = Vector3(PI * 0.5, float(r) * PI * 0.5, 0)
			qm.position = Vector3(0, 0, -0.14)
			fl.add_child(qm)
		fl.visible = false
		_flash_meshes.append(fl)
	_col_box(Vector3(0, HEAD_Y + 0.15, 0), Vector3(0.7, 0.45, 0.75))
	# Light, tracers, sound.
	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.7, 0.4)
	_flash.omni_range = 6.0
	_flash.light_energy = 0.0
	_flash.shadow_enabled = false
	_flash.position = Vector3(0, HEAD_Y + 0.15, -1.0)
	add_child(_flash)
	_tracer_mat = StandardMaterial3D.new()
	_tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tracer_mat.albedo_color = Color(1.0, 0.72, 0.4)
	_tracer_mat.emission_enabled = true
	_tracer_mat.emission = Color(1.0, 0.62, 0.3)
	_tracer_mat.emission_energy_multiplier = 6.0
	var tm := CylinderMesh.new()
	tm.top_radius = 0.012
	tm.bottom_radius = 0.02
	tm.height = 1.0
	tm.radial_segments = 6
	tm.rings = 1
	for i in TRACERS:
		var mi := MeshInstance3D.new()
		mi.mesh = tm
		mi.material_override = _tracer_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.top_level = true
		mi.visible = false
		add_child(mi)
		_tracers.append({"mi": mi, "from": Vector3.ZERO, "to": Vector3.ZERO, "t": 99.0, "len": 0.0})
	_gun_audio = AudioStreamPlayer3D.new()
	_gun_audio.stream = Snd.rand("weap/mg", 1.08, 1.5)
	_gun_audio.unit_size = 9.0
	_gun_audio.max_distance = 120.0
	_gun_audio.max_polyphony = 4
	_gun_audio.volume_db = -3.0
	_gun_audio.position = Vector3(0, HEAD_Y + 0.15, -0.4)
	add_child(_gun_audio)


func _piece_ready() -> void:
	if has_meta("build_preview"):
		return
	# Rest facing: toward the other planet (where the trouble comes from).
	var other: Node3D = Game.rival if body == Game.planet else Game.planet
	if other != null and is_instance_valid(other):
		var l := global_transform.basis.inverse() * (other.global_position - global_position)
		_rest_yaw = atan2(-l.x, -l.z)
	yaw = _rest_yaw
	_yaw_t = _rest_yaw
	_apply_pose()


func _apply_pose() -> void:
	_turret.rotation = Vector3(0, yaw, 0)
	_cradle.rotation = Vector3(pitch, 0, 0)
	for i in _barrel_nodes.size():
		(_barrel_nodes[i] as Node3D).position.z = -0.1 + float(_recoil[i]) * 0.06


func _eye() -> Vector3:
	return global_transform * Vector3(0, HEAD_Y + 0.3, 0)


func barrel_dir() -> Vector3:
	return -(_cradle.global_transform.basis.z.normalized())


# =================================================================================================
# Fire control (host / single player)
# =================================================================================================

func _tick(delta: float) -> void:
	_sense_t -= delta
	if _sense_t <= 0.0:
		_sense_t = Balance.TURRET_SENSE * _rng.randf_range(0.85, 1.15)
		_sense()
	var have := _target != null and is_instance_valid(_target)
	if have and _in_sight:
		_seen += delta
		_lost = 0.0
	else:
		_seen = 0.0
		_lost += delta
		if _lost > 1.2:
			_target = null
			have = false
	if have:
		var ap := _aim_point(_target)
		var v = _target.get("linear_velocity") if _target.is_in_group("war_drop_pod") else _target.get("velocity")
		if v is Vector3:
			ap += (v as Vector3) * (_muzzle_pos(0).distance_to(ap) / TRACER_SPEED)
		_aim_at(ap)
	else:
		_yaw_t = wrapf(_rest_yaw + sin(_t * 0.35) * 1.1, -PI, PI)
		_pitch_t = deg_to_rad(4.0 + 3.0 * sin(_t * 0.6))
	_turn(delta)
	# Bursts.
	_pause_t -= delta
	if _burst_left <= 0 and have and _in_sight and _seen >= Balance.TURRET_REACT and _pause_t <= 0.0:
		var want := (_aim_point(_target) - _muzzle_pos(0)).normalized()
		if barrel_dir().angle_to(want) < deg_to_rad(Balance.TURRET_FIRE_CONE_DEG) and not _friend_in_line(_aim_point(_target)):
			_starved = not _pay_burst()
			_burst_left = Balance.TURRET_BURST
			_shot_t = 0.0
	if _burst_left > 0:
		_shot_t -= delta
		while _shot_t <= 0.0 and _burst_left > 0:
			_fire_round(true)
			_burst_left -= 1
			_shot_t += 1.0 / Balance.TURRET_RATE
		if _burst_left <= 0:
			_pause_t = Balance.TURRET_PAUSE * (3.0 if _starved else 1.0) * _rng.randf_range(0.85, 1.2)
	tracking = _burst_left > 0


## The nearest visible enemy in range (pods first while they come down).
func _sense() -> void:
	var eye := _eye()
	var best: Node3D = null
	var best_d := Balance.TURRET_RANGE
	for p in get_tree().get_nodes_in_group("war_drop_pod"):
		if not (p is Node3D) or Game.team_of(p) == team or not (p.has_method("is_live") and p.is_live()):
			continue
		var d := eye.distance_to((p as Node3D).global_position)
		if d < best_d and _visible(eye, p):
			best_d = d
			best = p
	if best == null:
		var cands: Array = get_tree().get_nodes_in_group("war_ai") + get_tree().get_nodes_in_group("net_player")
		var pl = Game.player
		if pl != null and is_instance_valid(pl):
			cands.append(pl)
		for n in cands:
			if not (n is Node3D) or not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
				continue
			if Game.team_of(n) == team or (n.has_method("is_dead") and n.is_dead()):
				continue
			var d := eye.distance_to(_aim_point(n))
			if d < best_d and _visible(eye, n):
				best_d = d
				best = n
	if best != _target:
		_target = best
		_seen = 0.0
		if best != null and Game.sfx:
			Game.sfx.play_at("servo", global_position + global_transform.basis.y * HEAD_Y, -8.0, 1.25, 10.0)
	_in_sight = best != null


func _aim_point(n: Node3D) -> Vector3:
	if n.is_in_group("war_drop_pod"):
		return n.global_position
	var up: Vector3 = n.global_transform.basis.y.normalized()
	if body != null and is_instance_valid(body) and body.has_method("up_at"):
		up = body.up_at(n.global_position)
	return n.global_position + up * 1.1


## Line of sight from the eye to n: the density field (no hit before it) and the physics ray (terrain,
## structures, vehicles, characters: the first body hit must be n itself, or nothing).
func _visible(eye: Vector3, n: Node3D) -> bool:
	var ap := _aim_point(n)
	if body != null and is_instance_valid(body) and body.has_method("raycast_density"):
		if not (body.raycast_density(eye, ap.move_toward(eye, 0.6), 0.6, true) as Dictionary).is_empty():
			return false
	var q := PhysicsRayQueryParameters3D.create(eye, ap, 1 | 2 | 4 | 8, [_sb.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return true
	var d := Game.damageable_of(hit.get("collider"))
	return d == n or (hit["position"] as Vector3).distance_to(ap) < 0.8


## A friendly body in the line of fire (the burst waits).
func _friend_in_line(ap: Vector3) -> bool:
	var from := _muzzle_pos(0)
	var q := PhysicsRayQueryParameters3D.create(from, ap, 2 | 4 | 8, [_sb.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	var d := Game.damageable_of(hit.get("collider"))
	return d != null and d != self and Game.team_of(d) == team


func _aim_at(p: Vector3) -> void:
	var l := global_transform.basis.inverse() * (p - (global_transform * Vector3(0, HEAD_Y + 0.14, 0)))
	_yaw_t = atan2(-l.x, -l.z)
	_pitch_t = clampf(atan2(l.y, Vector2(l.x, l.z).length()), deg_to_rad(-25.0), deg_to_rad(70.0))


func _turn(delta: float) -> void:
	var rate := deg_to_rad(Balance.TURRET_TURN_RATE) * delta
	yaw = wrapf(yaw + clampf(wrapf(_yaw_t - yaw, -PI, PI), -rate, rate), -PI, PI)
	pitch = move_toward(pitch, _pitch_t, rate * 0.7)


## Pays a burst from the owner's pool; false = could not (the turret then trickles slowly).
## A multiplayer client's turret (owner_peer > 0, on the host): burst_cost asks net_world to charge
## that client's Game.material on its machine; peer_broke = its last answer was "could not pay".
func _pay_burst() -> bool:
	if Game.has_meta("training"):
		return true
	if owner_peer > 0 and not Game.shared_pool:          # (co-op: the host's material is the team pool)
		burst_cost.emit(owner_peer, Balance.TURRET_BURST_COST)
		return not peer_broke
	var pl = Game.player
	var local_team := Game.team_of(pl) if pl != null and is_instance_valid(pl) else "home"
	if team == local_team:
		return Game.spend_material(Balance.TURRET_BURST_COST)
	for n in get_tree().get_nodes_in_group("war_rival_team"):
		if str(n.get("team")) == team and n.has_method("spend"):
			return bool(n.spend(Balance.TURRET_BURST_COST))
	return true


func _muzzle_pos(i: int) -> Vector3:
	return (_muzzles[i % _muzzles.size()] as Node3D).global_position


## One round from the next barrel. real: the host's round (damage); else a client's look-alike.
func _fire_round(real: bool) -> void:
	var i := _barrel
	_barrel = (_barrel + 1) % 2
	var from := _muzzle_pos(i)
	var dir := barrel_dir()
	var spread := deg_to_rad(Balance.TURRET_SPREAD_DEG) * sqrt(_rng.randf())
	var ref := dir.cross(Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT).normalized()
	dir = dir.rotated(ref.rotated(dir, _rng.randf() * TAU), spread)
	var reach := Balance.TURRET_RANGE + 6.0
	var to := from + dir * reach
	if body != null and is_instance_valid(body) and body.has_method("raycast_density"):
		var dh: Dictionary = body.raycast_density(from, to, 0.6, true)
		if not dh.is_empty():
			to = dh["position"]
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | 2 | 4 | 8, [_sb.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var end := to
	if not hit.is_empty():
		end = hit["position"]
		if real:
			var n := Game.damageable_of(hit.get("collider"))
			if n != null and n != self and Game.team_of(n) != team:
				Game.damage_target(n, Balance.TURRET_DAMAGE, from, dir * 0.6, team, end)
	if real and _target != null and is_instance_valid(_target) and _target.is_in_group("war_drop_pod"):
		var pc := (_target as Node3D).global_position
		var t := clampf((pc - from).dot(dir), 0.0, from.distance_to(end))
		if (from + dir * t).distance_to(pc) < 1.3:
			_pod_dmg += Balance.TURRET_DAMAGE
			if _pod_dmg >= Balance.TURRET_POD_DAMAGE and _target.has_method("shot_down"):
				_pod_dmg -= Balance.TURRET_POD_DAMAGE
				_target.shot_down(from)
	if real:
		fired.emit(from, end)
	_round_fx(i, from, end, not hit.is_empty())


## Muzzle flash, light, recoil, sound, a tracer every other round, an impact spark.
func _round_fx(i: int, from: Vector3, end: Vector3, hit_something: bool) -> void:
	_recoil[i] = 1.0
	(_flash_meshes[i] as Node3D).visible = true
	(_flash_meshes[i] as Node3D).rotation.z = _rng.randf() * TAU
	_flash_t = 0.045
	_flash.global_position = from
	_flash.light_energy = 1.4
	if _gun_audio != null and _gun_audio.is_inside_tree():
		_gun_audio.play()
	if i == 0:
		for tr in _tracers:
			if float(tr["t"]) >= float(tr["len"]):
				tr["from"] = from
				tr["to"] = end
				tr["t"] = 0.0
				tr["len"] = from.distance_to(end) / TRACER_SPEED
				break
	if hit_something and _rng.randf() < 0.35 and Game.sfx:
		Game.sfx.play_at("impact_light", end, -16.0, _rng.randf_range(1.2, 1.6), 6.0)


# =================================================================================================
# Client copy, looks
# =================================================================================================

func _tick_client(delta: float) -> void:
	_turn(delta)
	if tracking:
		if not _was_tracking:
			_shot_t = 0.0
		_shot_t -= delta
		while _shot_t <= 0.0:
			_fire_round(false)
			_shot_t += 1.0 / Balance.TURRET_RATE
	_was_tracking = tracking


func _animate(delta: float) -> void:
	if has_meta("build_preview"):
		return
	_flash_t -= delta
	if _flash_t <= 0.0:
		for f in _flash_meshes:
			(f as Node3D).visible = false
		_flash.light_energy = move_toward(_flash.light_energy, 0.0, delta * 30.0)
	for i in 2:
		_recoil[i] = move_toward(float(_recoil[i]), 0.0, delta * 9.0)
	_apply_pose()
	# Tracers: a streak running from the muzzle to the end point.
	for tr in _tracers:
		var mi: MeshInstance3D = tr["mi"]
		var ln := float(tr["len"])
		if float(tr["t"]) >= ln:
			mi.visible = false
			continue
		tr["t"] = float(tr["t"]) + delta
		var a: Vector3 = tr["from"]
		var b: Vector3 = tr["to"]
		var k := clampf(float(tr["t"]) / maxf(ln, 0.001), 0.0, 1.0)
		var head := a.lerp(b, k)
		var tail := head.move_toward(a, TRACER_LEN)
		if head.distance_to(tail) < 0.05:
			mi.visible = false
			continue
		mi.visible = true
		mi.global_transform = Transform3D(_seg_basis(tail, head) * Basis.from_scale(Vector3(1.0, head.distance_to(tail), 1.0)),
				(head + tail) * 0.5)
	# The eye: bright while it has a target, a slow glow searching.
	var on := _build_t < 0.0 and not is_destroyed
	var lock := tracking or (_target != null and _in_sight)
	_eye_mat.emission_energy_multiplier = (4.5 if lock else 1.2 + 0.8 * sin(_t * 3.0)) if on else 0.2
