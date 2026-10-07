extends Node3D
## Uçaksavar: an anti-aircraft gun built on your own planet (İnşa Aracı, Balance.FLAK_COST). Not a
## cannon: a jacked steel plinth, a fast armoured turret with ammunition drums, a twin-barrel
## autocannon on a cradle, a spinning radar dish on a mast and a sensor pod beside the guns.
## Groups "damageable", "war_structure", "war_flak". It fires FlakRound (scripts/war/flak_round.gd):
## fast proximity-fused rounds that burst in the air (no crater).
##
## Automatic (any team, while nobody mans it): it sees an ENEMY skiff (group "skiff" whose
## Game.team_of differs from its own; aimed at the hull centre global_position + basis.y * 0.9)
## when it is airborne, within FLAK_RANGE and in line of sight (planet.raycast_density: the planets
## hide it), opens fire after a 1-2 s reaction, leads it with Ballistics.intercept (the skiff's
## velocity and its smoothed acceleration) and fires fast. Its aim error shrinks while the target
## flies steadily and resets when it jinks, so evasive flying makes it miss. `tracking` is true
## while it engages (HUD: "RAKİP SENİ GÖRDÜ" for the rival's). Enemy drop pods in flight
## (scripts/war/drop_pod.gd, group "war_drop_pod") are engaged the same way (nearest target first).
##
## Player (team "home"): F mans it (seat API), first person behind the guns. Mouse = aim, LMB held
## = fire (FLAK_ROUND_COST material per round), F = leave. While manned nothing is automatic: the
## sight brackets the incoming enemy cannon shell or enemy skiff nearest the sight line, shows the
## lead marker and sets the rounds' fuse to the intercept time (point defence: a burst within
## FLAK_SHELL_KILL_R destroys a shell).
##   Flak.spawn(parent, body, xf, team, animate := true) -> the Uçaksavar
##   Flak.rival_tracking(tree) -> bool: a rival Uçaksavar is engaging the skiff now

const Balance := preload("res://scripts/war/balance.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const FlakRound := preload("res://scripts/war/flak_round.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const Settings := preload("res://scripts/save/settings.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const Foundation := preload("res://scripts/war/foundation.gd")

const PIVOT_Y := 1.6                 # cradle pivot height above the plinth base
const BARREL_LEN := 2.9
const BARREL_X := 0.24                # half spacing of the twin barrels
const MOUSE_SENS := 0.0018
const FIRE_CONE := deg_to_rad(2.0)    # barrels within this of the solution: fire
# Gunner's eye (cradle-local, on the line through the ring sight parallel to the barrels; _eye_pos).
# It used to sit fixed 0.75 m behind the trunnions, so above ~30° elevation it swung down into the
# turret housing (the user: "uçaksavara binince yerine değil altına giriyor").
const SIGHT_Z := -0.45                # the ring sight (its centre 0.42 above the bore axis)
const EYE_UP := 0.44                  # the eye just over the ring's centre
const EYE_BACK := 1.2                 # ...this far behind the ring when nothing is in the way
const EYE_MIN_UP := 0.12              # never lower than this over the trunnion pivot (turret roof: pivot - 0.05)
const EYE_MAX_BACK := 0.68            # never further back than this behind it (radar mast: pivot + 0.9)
const VIS_GUNNER_HIDE := 1 << 15      # visual layer the gunner's camera skips: the radar over his head

signal destroyed(flak: Node3D)

var team := "home"
var body: Node3D
var hp := Balance.FLAK_HP
var hp_max := Balance.FLAK_HP
var pilot = null
var yaw := 0.0
var pitch := deg_to_rad(25.0)
var is_destroyed := false
var tracking := false                 # rival: engaging the skiff (after the reaction time)

var _yaw_t := 0.0
var _pitch_t := deg_to_rad(25.0)
var _rest_yaw := 0.0
var _turret: Node3D
var _cradle: Node3D
var _recoil: Array = []               # the two barrel groups (recoil along +z)
var _muzzles: Array = []
var _kick := [0.0, 0.0]
var _next_barrel := 0
var _cool := 0.0
var _dish: Node3D
var _lens: StandardMaterial3D
var _body: StaticBody3D
var _cam: Camera3D
var _cam_kick := 0.0
var _flash: OmniLight3D
var _flash_t := 0.0
var _gun_audio: AudioStreamPlayer3D
var _turn_audio: AudioStreamPlayer3D
var _turning := 0.0
var _hit_t := 0.0
var _paint: StandardMaterial3D
var _build_t := -1.0
var _parts: Array = []
var _ground_check := false
var _foundation: Node3D               # jack extensions down to the real ground (scripts/war/foundation.gd)
var _rng := RandomNumberGenerator.new()
var _t := 0.0
# Fire control (rival).
var _target: Node3D
var _tgt_vel := Vector3.ZERO
var _prev_vel := Vector3.ZERO
var _have_prev := false
var _acc_fast := Vector3.ZERO
var _acc_slow := Vector3.ZERO
var _steady_t := 0.0
var _seen_t := 0.0
var _lost_t := 0.0
var _react := 1.5
var _sense_t := 0.0
var _in_sight := false
var _sol_dir := Vector3.ZERO
var _sol_time := 0.0
var _sol_miss := INF
var _err_ang := 0.0
var _err_roll := 0.0
# Manned (player).
var _firing := false
var _lead_target: Node3D
var _lead := {}
var _overlay: CanvasLayer
var _ov: Control
var _font: Font
var _font_b: Font


static func spawn(parent: Node, p_body: Node3D, xf: Transform3D, p_team: String, animate := true) -> Node3D:
	var f: Node3D = load("res://scripts/war/flak.gd").new()
	f.team = p_team
	f.body = p_body
	f.name = "Flak_" + p_team
	f.transform = xf
	parent.add_child(f)
	if animate:
		f.begin_assembly()
	return f


static func rival_tracking(tree: SceneTree) -> bool:
	for f in tree.get_nodes_in_group("war_flak"):
		if str(f.team) == "rival" and f.tracking and not f.is_destroyed:
			return true
	return false


func _ready() -> void:
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_structure")
	add_to_group("war_flak")
	set_meta("footprint_r", Balance.FLAK_FOOTPRINT)
	_rng.randomize()
	_react = _rng.randf_range(Balance.FLAK_REACT_MIN, Balance.FLAK_REACT_MAX)
	_build_model()
	if body != null and not has_meta("build_preview"):
		_foundation = Foundation.create(self, body, PackedVector3Array(), _foundation_piles(), Color.GRAY)
		_parts.append([_foundation, _foundation.transform, 0.0])
	_build_audio()
	_font = UI.font(500)
	_font_b = UI.font(700)
	var other: Node3D = Game.rival if team == "home" else Game.planet
	if other != null:
		aim_dir((other.global_position - global_position).normalized())
		_rest_yaw = _yaw_t
		_pitch_t = deg_to_rad(25.0)
		yaw = _yaw_t
	if body != null and body.has_signal("brush_applied"):
		body.brush_applied.connect(_on_brush)


# =================================================================================================
# Model
# =================================================================================================

func _mat(c: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	return m


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


## Cylinder along local "y", "x" or "z" (toward -z), centred at pos.
func _cyl(parent: Node3D, pos: Vector3, r_top: float, r_bot: float, h: float, mat: Material, axis := "y", seg := 16) -> MeshInstance3D:
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
	if axis == "z":
		mi.rotation = Vector3(-PI * 0.5, 0, 0)
	elif axis == "x":
		mi.rotation = Vector3(0, 0, PI * 0.5)
	parent.add_child(mi)
	return mi


func _build_model() -> void:
	var steel := _mat(Color(0.22, 0.23, 0.24), 0.85, 0.36)
	var dark := _mat(Color(0.08, 0.08, 0.09), 0.6, 0.5)
	var rubber := _mat(Color(0.05, 0.05, 0.05), 0.0, 0.9)
	var paint_col := Color(0.31, 0.34, 0.3) if team == "home" else Color(0.32, 0.24, 0.21)
	_paint = _mat(paint_col, 0.4, 0.55)
	var accent := Color(0.35, 0.85, 1.0) if team == "home" else Color(0.95, 0.25, 0.15)
	var stripe := _mat(accent, 0.1, 0.5)
	stripe.emission_enabled = true
	stripe.emission = accent
	stripe.emission_energy_multiplier = 0.7
	var hazard := _mat(Color(0.85, 0.62, 0.12), 0.1, 0.6)

	# --- Plinth: an octagonal steel base on four hydraulic jacks, with a cable box.
	var base := Node3D.new()
	add_child(base)
	_cyl(base, Vector3(0, 0.32, 0), 1.25, 1.45, 0.5, steel, "y", 8)
	_cyl(base, Vector3(0, 0.6, 0), 1.05, 1.15, 0.08, hazard, "y", 8)
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		var jack := Node3D.new()
		jack.rotation.y = a
		base.add_child(jack)
		_box(jack, Vector3(0, 0.3, -1.55), Vector3(0.28, 0.22, 0.9), _paint)
		_cyl(jack, Vector3(0, 0.2, -2.0), 0.07, 0.07, 0.45, steel)
		_cyl(jack, Vector3(0, 0.03, -2.0), 0.28, 0.32, 0.07, rubber, "y", 12)
	_box(base, Vector3(1.15, 0.3, 0.75), Vector3(0.45, 0.35, 0.5), dark)
	_parts.append([base, base.transform, 0.0])

	# --- Turret (yaw): a low armoured drum + housing with chamfered front, ammo drums, radar mast.
	_turret = Node3D.new()
	_turret.position = Vector3(0, 0.64, 0)
	add_child(_turret)
	_cyl(_turret, Vector3(0, 0.12, 0), 0.95, 1.0, 0.24, steel, "y", 24)
	_box(_turret, Vector3(0, 0.55, 0.25), Vector3(1.5, 0.62, 1.5), _paint)
	_box(_turret, Vector3(0, 0.62, -0.62), Vector3(1.5, 0.48, 0.45), _paint, Vector3(-0.55, 0, 0))
	_box(_turret, Vector3(0, 0.88, 0.25), Vector3(1.52, 0.06, 1.4), stripe)
	for sx in [-1.0, 1.0]:
		# Cheek plates carrying the cradle trunnions.
		_box(_turret, Vector3(0.55 * sx, PIVOT_Y - 0.64, -0.05), Vector3(0.12, 0.85, 0.8), _paint)
		_cyl(_turret, Vector3(0.62 * sx, PIVOT_Y - 0.64, -0.05), 0.16, 0.16, 0.08, steel, "x")
		# Ammunition drums on the flanks.
		_cyl(_turret, Vector3(0.98 * sx, 0.6, 0.35), 0.36, 0.36, 0.42, dark, "x", 20)
		_cyl(_turret, Vector3(1.2 * sx, 0.6, 0.35), 0.3, 0.3, 0.04, steel, "x", 20)
		# Feed chutes up to the guns.
		_box(_turret, Vector3(0.78 * sx, 0.95, 0.05), Vector3(0.16, 0.5, 0.18), steel, Vector3(0.3, 0, 0.35 * sx))
	# Radar mast at the back with a spinning dish.
	var mast := _cyl(_turret, Vector3(0, 1.25, 0.85), 0.05, 0.07, 1.2, steel)
	_dish = Node3D.new()
	_dish.position = Vector3(0, 1.9, 0.85)
	_turret.add_child(_dish)
	var dm := CylinderMesh.new()
	dm.top_radius = 0.55
	dm.bottom_radius = 0.12
	dm.height = 0.18
	dm.radial_segments = 24
	dm.rings = 1
	var dish_mi := MeshInstance3D.new()
	dish_mi.mesh = dm
	dish_mi.material_override = _mat(Color(0.75, 0.77, 0.78), 0.5, 0.35)
	dish_mi.rotation = Vector3(-PI * 0.5 + 0.35, 0, 0)
	dish_mi.position = Vector3(0, 0, -0.08)
	_dish.add_child(dish_mi)
	_cyl(_dish, Vector3(0, 0, -0.32), 0.03, 0.03, 0.42, steel, "z", 8)
	_box(_dish, Vector3(0, 0, -0.08), Vector3(0.14, 0.14, 0.14), dark)
	# The gunner's camera skips the radar (it stands right over his head: aiming high, the spinning
	# dish swept across the sight); everyone else sees it, and its shadow stays.
	mast.layers = VIS_GUNNER_HIDE
	for mi in _dish.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).layers = VIS_GUNNER_HIDE
	_parts.append([_turret, _turret.transform, 0.25])

	# --- Cradle (pitch): receivers and the twin barrels with cooling jackets and flash hiders.
	_cradle = Node3D.new()
	_cradle.position = Vector3(0, PIVOT_Y - 0.64, -0.05)
	_turret.add_child(_cradle)
	_box(_cradle, Vector3(0, 0, 0.1), Vector3(0.82, 0.42, 1.1), _paint)
	_cyl(_cradle, Vector3(0, 0, 0), 0.12, 0.12, 1.14, steel, "x")
	for i in 2:
		var sx := -1.0 if i == 0 else 1.0
		var rc := Node3D.new()
		rc.position = Vector3(BARREL_X * sx, 0.06, 0)
		_cradle.add_child(rc)
		_box(rc, Vector3(0, 0, -0.1), Vector3(0.2, 0.26, 0.9), steel)
		_cyl(rc, Vector3(0, 0.02, -0.55 - 0.55), 0.095, 0.095, 1.1, dark, "z", 14)
		_cyl(rc, Vector3(0, 0.02, -0.55 - BARREL_LEN * 0.5), 0.055, 0.06, BARREL_LEN, steel, "z", 14)
		_cyl(rc, Vector3(0, 0.02, -0.55 - BARREL_LEN - 0.1), 0.08, 0.075, 0.26, dark, "z", 10)
		var mz := Node3D.new()
		mz.position = Vector3(0, 0.02, -0.55 - BARREL_LEN - 0.3)
		rc.add_child(mz)
		_recoil.append(rc)
		_muzzles.append(mz)
	# Sensor pod beside the guns (moves with them): a lens that glows while tracking.
	_box(_cradle, Vector3(-0.62, 0.22, -0.25), Vector3(0.22, 0.24, 0.5), dark)
	_lens = StandardMaterial3D.new()
	_lens.albedo_color = Color(0.05, 0.05, 0.05)
	_lens.emission_enabled = true
	_lens.emission = accent
	_lens.emission_energy_multiplier = 0.4
	_cyl(_cradle, Vector3(-0.62, 0.22, -0.51), 0.075, 0.075, 0.03, _lens, "z", 14)
	# Ring sight above the receivers.
	var tm := TorusMesh.new()
	tm.inner_radius = 0.11
	tm.outer_radius = 0.13
	tm.rings = 24
	tm.ring_segments = 6
	var ring := MeshInstance3D.new()
	ring.mesh = tm
	ring.material_override = steel
	ring.rotation = Vector3(PI * 0.5, 0, 0)
	ring.position = Vector3(0, 0.42, -0.45)
	_cradle.add_child(ring)
	_cyl(_cradle, Vector3(0, 0.32, -0.45), 0.012, 0.012, 0.2, steel)
	_parts.append([_cradle, _cradle.transform, 0.5])

	for mi in find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	_body = StaticBody3D.new()
	_body.collision_layer = Game.LAYER_SHIP
	_body.collision_mask = 0
	_body.set_meta("interact_target", self)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(2.1, 2.1, 2.2)
	cs.shape = bs
	cs.position = Vector3(0, 1.05, 0.1)
	_body.add_child(cs)
	add_child(_body)

	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.72, 0.4)
	_flash.omni_range = 12.0
	_flash.light_energy = 0.0
	_flash.shadow_enabled = false
	_cradle.add_child(_flash)
	_flash.position = Vector3(0, 0.1, -0.55 - BARREL_LEN - 0.4)

	# Gunner's eye behind the ring sight (pitches with the guns; _eye_pos keeps it out of the turret).
	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = Game.CAM_FAR
	_cam.fov = Settings.fov
	_cam.cull_mask = 0xFFFFF & ~VIS_GUNNER_HIDE
	_cradle.add_child(_cam)
	_cam.position = _eye_pos(pitch)


func _build_audio() -> void:
	_gun_audio = AudioStreamPlayer3D.new()
	_gun_audio.unit_size = 22.0
	_gun_audio.max_distance = 1500.0
	_gun_audio.max_polyphony = 4
	_gun_audio.stream = Snd.rand("weap/mg", 1.05, 1.5)
	add_child(_gun_audio)
	_turn_audio = AudioStreamPlayer3D.new()
	_turn_audio.unit_size = 5.0
	_turn_audio.stream = Snd.loop("foley/motor_loop")
	_turn_audio.volume_db = -80.0
	add_child(_turn_audio)


func begin_assembly() -> void:
	# The print (build_fx.gd) measures the whole model first, then the parts drop in through it.
	BuildFx.assemble(get_parent(), global_transform, Vector3(1.9, 1.4, 1.9), BuildFx.AUTO, self)
	_build_t = 0.0
	for p in _parts:
		var n: Node3D = p[0]
		n.transform = (p[1] as Transform3D).translated_local(Vector3(0, 2.0, 0))
		n.scale = Vector3.ONE * 0.6
		n.visible = false


# =================================================================================================
# Aiming and firing
# =================================================================================================

func barrel_dir() -> Vector3:
	return -_cradle.global_transform.basis.z.normalized()


## Between the two muzzles (where the fire control solves from).
func muzzle_position() -> Vector3:
	return ((_muzzles[0] as Node3D).global_position + (_muzzles[1] as Node3D).global_position) * 0.5


## Commands the turret toward world direction `dir`. False when the pitch had to be clamped.
func aim_dir(dir: Vector3) -> bool:
	var l := global_transform.basis.orthonormalized().inverse() * dir.normalized()
	_yaw_t = atan2(-l.x, -l.z)
	var want := atan2(l.y, Vector2(l.x, l.z).length())
	_pitch_t = clampf(want, deg_to_rad(Balance.FLAK_PITCH_MIN), deg_to_rad(Balance.FLAK_PITCH_MAX))
	return absf(want - _pitch_t) < 0.001


func ready_to_fire() -> bool:
	return _cool <= 0.0 and not is_destroyed and _build_t < 0.0


## One round from the next barrel. fuse_time 0 = the life limit only. The player pays per round.
func fire_round(fuse_time := 0.0) -> bool:
	if not ready_to_fire():
		return false
	if team == "home" and not Game.spend_material(Balance.FLAK_ROUND_COST):
		_firing = false
		if Game.hud:
			Game.hud.show_message("Yetersiz malzeme — uçaksavar mermisi %d m³" % int(Balance.FLAK_ROUND_COST), 2.0)
		if Game.sfx:
			Game.sfx.play("error", -10.0)
		return false
	_cool = Balance.FLAK_INTERVAL
	var i := _next_barrel
	_next_barrel = 1 - _next_barrel
	var dir := barrel_dir()
	var from: Vector3 = (_muzzles[i] as Node3D).global_position + dir * 0.2
	FlakRound.fire(get_tree().current_scene, from, dir * Balance.FLAK_SPEED, team, [_body.get_rid()], fuse_time)
	_kick[i] = 0.28
	_flash.position = Vector3(BARREL_X * (-1.0 if i == 0 else 1.0), 0.1, -0.55 - BARREL_LEN - 0.4)
	_flash_t = 1.0
	_cam_kick = minf(_cam_kick + 0.5, 1.0)
	_gun_audio.pitch_scale = _rng.randf_range(0.58, 0.68)
	_gun_audio.play()
	_puff(from, dir)
	return true


## Multiplayer: the other peer fired a round from this gun; recoil, flash, sound, smoke (the round
## comes as its own event, scripts/net/net_world.gd).
func net_fire_fx() -> void:
	_cool = Balance.FLAK_INTERVAL
	var i := _next_barrel
	_next_barrel = 1 - _next_barrel
	var dir := barrel_dir()
	var from: Vector3 = (_muzzles[i] as Node3D).global_position + dir * 0.2
	_kick[i] = 0.28
	_flash.position = Vector3(BARREL_X * (-1.0 if i == 0 else 1.0), 0.1, -0.55 - BARREL_LEN - 0.4)
	_flash_t = 1.0
	_gun_audio.pitch_scale = _rng.randf_range(0.58, 0.68)
	_gun_audio.play()
	_puff(from, dir)


## A small muzzle smoke puff.
func _puff(pos: Vector3, dir: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 8
	p.lifetime = 1.4
	p.explosiveness = 1.0
	var q := QuadMesh.new()
	q.size = Vector2(0.8, 0.8)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	p.mesh = q
	p.direction = dir
	p.spread = 18.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 9.0
	p.damping_min = 4.0
	p.damping_max = 7.0
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.8
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.1, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.75, 0.4, 0.9), Color(0.55, 0.53, 0.5, 0.45), Color(0.5, 0.5, 0.5, 0.0)])
	p.color_ramp = g
	get_parent().add_child(p)
	p.global_position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)


func _process(delta: float) -> void:
	_t += delta
	if _build_t >= 0.0:
		_build_t += delta
		var done := true
		for p in _parts:
			var n: Node3D = p[0]
			var k := clampf((_build_t - float(p[2])) / 0.6, 0.0, 1.0)
			n.visible = k > 0.0
			var e := 1.0 - pow(1.0 - k, 3.0)
			n.transform = (p[1] as Transform3D).translated_local(Vector3(0, 2.0 * (1.0 - e), 0)).scaled_local(Vector3.ONE * lerpf(0.6, 1.0, e))
			if k < 1.0:
				done = false
		if done:
			_build_t = -1.0
			for p in _parts:
				(p[0] as Node3D).transform = p[1]
			if Game.sfx:
				Game.sfx.play_at("impact", global_position, -6.0, 0.9, 12.0)
	_cool = maxf(_cool - delta, 0.0)
	# Quick traverse (faster still when a gunner drives it).
	var rate := deg_to_rad(Balance.FLAK_TURN_RATE) * (2.5 if pilot != null else 1.0) * delta
	var dy := angle_difference(yaw, _yaw_t)
	var dp := _pitch_t - pitch
	yaw += clampf(dy, -rate, rate)
	pitch += clampf(dp, -rate, rate)
	_turning = move_toward(_turning, 1.0 if (absf(dy) > 0.003 or absf(dp) > 0.003) else 0.0, delta * 8.0)
	_turn_audio.volume_db = linear_to_db(maxf(_turning * 0.3, 0.0001))
	if _turning > 0.01 and not _turn_audio.playing:
		_turn_audio.play()
	elif _turning <= 0.01 and _turn_audio.playing:
		_turn_audio.stop()
	_turret.rotation.y = yaw
	_cradle.rotation.x = pitch
	# Radar: spins while searching, faster while tracking.
	_dish.rotation.y += delta * (5.0 if tracking else 1.6)
	_lens.emission_energy_multiplier = (2.5 + 1.5 * sin(_t * 18.0)) if tracking else 0.4
	if team == "rival":
		_lens.emission = Color(1.0, 0.15, 0.1) if tracking else Color(0.95, 0.25, 0.15)
	# Barrel recoil and the flash.
	for i in 2:
		_kick[i] = move_toward(float(_kick[i]), 0.0, delta * 2.2)
		var rn: Node3D = _recoil[i]
		rn.position.z = float(_kick[i])
	_flash_t = maxf(_flash_t - delta * 14.0, 0.0)
	_flash.light_energy = 9.0 * _flash_t
	_hit_t = maxf(_hit_t - delta * 3.0, 0.0)
	_paint.emission_enabled = _hit_t > 0.0
	if _hit_t > 0.0:
		_paint.emission = Color(1.0, 0.35, 0.1) * _hit_t
	if pilot != null:
		_update_manned(delta)


func _physics_process(delta: float) -> void:
	if is_destroyed or _build_t >= 0.0:
		return
	if pilot == null and (Net.is_client() or has_meta("net_busy")):
		return            # multiplayer: the host's copy runs the fire control / the other player mans it
	if pilot != null:
		if tracking or _target != null:
			_target = null
			_reset_track()
		return
	_fire_control(delta)


# =================================================================================================
# Fire control (automatic, while unmanned)
# =================================================================================================

func _fire_control(delta: float) -> void:
	_sense_t -= delta
	if _sense_t <= 0.0:
		_sense_t = 0.25
		_sense()
	if _target == null or not is_instance_valid(_target):
		_target = null
		if tracking or _seen_t > 0.0:
			_reset_track()
		_idle_scan()
		return
	# Target motion: velocity and a fast / slow smoothed acceleration (their gap = jinking).
	var v = _target.get("linear_velocity")
	_tgt_vel = v if v is Vector3 else Vector3.ZERO
	if _have_prev and delta > 0.0:
		var a_raw := (_tgt_vel - _prev_vel) / delta
		_acc_fast = _acc_fast.lerp(a_raw, 1.0 - exp(-delta / 0.25))
		_acc_slow = _acc_slow.lerp(a_raw, 1.0 - exp(-delta / 1.2))
	_prev_vel = _tgt_vel
	_have_prev = true
	if (_acc_fast - _acc_slow).length() > Balance.FLAK_EVADE_ACCEL:
		_steady_t = 0.0
	else:
		_steady_t += delta
	if _in_sight:
		_seen_t += delta
		_lost_t = 0.0
	else:
		_lost_t += delta
		if _lost_t > Balance.FLAK_LOSE_TIME:
			_reset_track()
			_idle_scan()
			return
	tracking = _seen_t >= _react
	if not tracking:
		_idle_scan()
		return
	# Lead: one shooting-method pass per frame, warm-started from the last solution.
	var hull := _hull(_target)
	var acc := _acc_fast.limit_length(25.0)
	var r := Ballistics.intercept(muzzle_position(), Balance.FLAK_SPEED, hull, _tgt_vel, acc, _sol_dir, 1,
			Balance.FLAK_ROUND_LIFE, 0.08)
	_sol_dir = r["dir"]
	_sol_time = float(r["time"])
	_sol_miss = float(r["miss"])
	var aim := _with_error(_sol_dir)
	var reachable := aim_dir(aim)
	if not reachable or _sol_miss > 25.0 or not _in_sight:
		return
	if barrel_dir().angle_to(aim) < FIRE_CONE and ready_to_fire():
		fire_round(_sol_time + 0.25)
		_new_error()


## Every 0.25 s: the nearest enemy skiff, whether it is airborne, in range and in line of sight.
func _sense() -> void:
	var best: Node3D = null
	var best_d := INF
	var eye := global_position + global_transform.basis.y * 2.4
	# (also enemy drop pods in flight: scripts/war/drop_pod.gd, group "war_drop_pod", is_live())
	for s in get_tree().get_nodes_in_group("skiff") + get_tree().get_nodes_in_group("war_drop_pod"):
		if not (s is Node3D) or not is_instance_valid(s) or not (s as Node3D).is_inside_tree():
			continue
		if Game.team_of(s) == team or (s.has_method("is_live") and not s.is_live()):
			continue
		var d := eye.distance_to(_hull(s))
		if d < best_d:
			best_d = d
			best = s
	if best != _target:
		_reset_track()
		_target = best
	_in_sight = false
	if _target == null or best_d > Balance.FLAK_RANGE:
		return
	var hull := _hull(_target)
	var b: Node3D = Game.dominant_body(hull)
	var alt: float = float(b.density_at(hull)) if b != null and b.has_method("density_at") else 99.0
	var v = _target.get("linear_velocity")
	var spd: float = (v as Vector3).length() if v is Vector3 else 0.0
	if alt < Balance.FLAK_MIN_ALT and spd < 3.0:
		return                            # parked / landed: not an air target
	var to := hull - eye
	var los := Ballistics.segment_hit(eye, hull - to.normalized() * 2.0)
	_in_sight = los.is_empty()


static func _hull(n: Node3D) -> Vector3:
	if n.is_in_group("war_drop_pod"):
		return n.global_position             # (a drop pod's origin is its centre)
	return n.global_position + n.global_transform.basis.y * 0.9


func _reset_track() -> void:
	tracking = false
	_seen_t = 0.0
	_lost_t = 0.0
	_steady_t = 0.0
	_have_prev = false
	_acc_fast = Vector3.ZERO
	_acc_slow = Vector3.ZERO
	_sol_dir = Vector3.ZERO
	_sol_miss = INF
	_react = _rng.randf_range(Balance.FLAK_REACT_MIN, Balance.FLAK_REACT_MAX)
	_new_error()


## Aim error for the next round: large on a fresh or jinking target, small after steady tracking.
func _new_error() -> void:
	var err := Balance.FLAK_ERR_MIN + (Balance.FLAK_ERR_START - Balance.FLAK_ERR_MIN) * exp(-_steady_t / Balance.FLAK_SETTLE)
	_err_ang = deg_to_rad(err) * sqrt(_rng.randf())
	_err_roll = _rng.randf() * TAU


func _with_error(dir: Vector3) -> Vector3:
	var ref := dir.cross(Vector3.UP)
	if ref.length_squared() < 1e-4:
		ref = dir.cross(Vector3.RIGHT)
	var axis := ref.normalized().rotated(dir, _err_roll)
	return dir.rotated(axis, _err_ang)


## No target: the turret sweeps slowly around its rest direction.
func _idle_scan() -> void:
	if pilot != null:
		return
	_yaw_t = wrapf(_rest_yaw + sin(_t * 0.25) * 1.0, -PI, PI)
	_pitch_t = deg_to_rad(25.0 + 10.0 * sin(_t * 0.4))


# =================================================================================================
# Manned (player)
# =================================================================================================

func get_interact_prompt() -> String:
	if team != "home":
		return ""
	if _build_t >= 0.0:
		return "Uçaksavar kuruluyor…"
	if has_meta("net_busy"):
		return "Uçaksavar dolu — arkadaşın kullanıyor"
	return "Uçaksavara geç"


func interact(p) -> void:
	if team != "home" or _build_t >= 0.0 or is_destroyed or has_meta("net_busy"):
		return
	p.enter_vehicle(self)


func set_pilot(p) -> void:
	pilot = p
	_firing = false
	if p != null:
		_pitch_t = pitch
		_yaw_t = yaw
		_cam.current = true
		_cam.fov = Settings.fov
		_make_overlay()
		if Game.sfx:
			Game.sfx.play("select", -10.0, 1.0)
	else:
		_cam.current = false
		_lead = {}
		_lead_target = null
		if _overlay != null:
			_overlay.queue_free()
			_overlay = null


func get_exit_transform() -> Transform3D:
	var b := global_transform.basis.orthonormalized()
	var back := (b * Basis(Vector3.UP, yaw)) * Vector3(0, 0, 2.6)
	return Transform3D(b * Basis(Vector3.UP, yaw), global_position + back + b.y * 0.6)


func get_exit_velocity() -> Vector3:
	return Vector3.ZERO


func hud_velocity() -> Vector3:
	return Vector3.ZERO


func hud_name() -> String:
	return "Uçaksavar"


func hud_extra() -> String:
	return ""


func _unhandled_input(event: InputEvent) -> void:
	if pilot == null or Game.ui_panel_open():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var lk := Settings.look((event as InputEventMouseMotion).relative)
		_yaw_t = wrapf(_yaw_t - lk.x * MOUSE_SENS, -PI, PI)
		_pitch_t = clampf(_pitch_t - lk.y * MOUSE_SENS, deg_to_rad(Balance.FLAK_PITCH_MIN), deg_to_rad(Balance.FLAK_PITCH_MAX))
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tool_use") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_firing = true
		get_viewport().set_input_as_handled()
	elif event.is_action_released("tool_use"):
		_firing = false
		get_viewport().set_input_as_handled()


func _update_manned(delta: float) -> void:
	_cam_kick = move_toward(_cam_kick, 0.0, delta * 6.0)
	# (the recoil shoves the eye back up to 6 cm: inside the margins _eye_pos keeps)
	_cam.position = _eye_pos(pitch) + Vector3(_rng.randf_range(-1.0, 1.0) * 0.01 * _cam_kick, 0.0, _cam_kick * 0.06)
	_update_lead()
	if _firing and ready_to_fire():
		var fuse: float = float(_lead.get("time", 0.0)) + 0.2 if not _lead.is_empty() else 0.0
		fire_round(fuse)
	if _ov != null:
		_ov.queue_redraw()


## The gunner's eye at elevation `p` (cradle-local): EYE_BACK behind the ring sight, drawn in along
## the sight line as the guns rise so that, seen from the turret, it stays EYE_MIN_UP above the
## trunnions (clear of the housing, which the old fixed eye sank into above ~30°) and no more than
## EYE_MAX_BACK behind them (clear of the radar mast). At 88° it is ~0.35 m behind the ring.
static func _eye_pos(p: float) -> Vector3:
	var z := SIGHT_Z + EYE_BACK
	var s := sin(p)
	var c := cos(p)
	if s > 0.001:
		z = minf(z, (EYE_UP * c - EYE_MIN_UP) / s)     # turret-frame height EYE_UP*c - z*s >= EYE_MIN_UP
	if c > 0.001:
		z = minf(z, (EYE_MAX_BACK - EYE_UP * s) / c)   # turret-frame back  EYE_UP*s + z*c <= EYE_MAX_BACK
	return Vector3(0.0, EYE_UP, z)


## The lead marker: the incoming enemy shell or enemy skiff nearest to the sight line, solved like
## the automatic fire control does.
func _update_lead() -> void:
	var from := muzzle_position()
	var aim := barrel_dir()
	var best: Node3D = null
	var best_a := deg_to_rad(35.0)
	var cands: Array = []
	for s in get_tree().get_nodes_in_group("war_shell"):
		if is_instance_valid(s) and str(s.team) != team and s.is_live():
			cands.append(s)
	for s in get_tree().get_nodes_in_group("skiff"):
		if s is Node3D and is_instance_valid(s) and Game.team_of(s) != team:
			cands.append(s)
	for s in cands:
		var p: Vector3 = _lead_point(s)
		if p.distance_to(from) > Balance.FLAK_RANGE:
			continue
		var a := aim.angle_to(p - from)
		if a < best_a:
			best_a = a
			best = s
	if best != _lead_target:
		_lead_target = best
		_lead = {}
	if best == null:
		return
	var sp: Vector3 = _lead_point(best)
	var tv := Vector3.ZERO
	var ta := Vector3.ZERO
	if best.is_in_group("war_shell"):
		tv = best.vel
		ta = Game.gravity_at(sp)
	else:
		var v = best.get("linear_velocity")
		tv = v if v is Vector3 else Vector3.ZERO
	var prev: Vector3 = _lead.get("dir", Vector3.ZERO)
	_lead = Ballistics.intercept(from, Balance.FLAK_SPEED, sp, tv, ta, prev, 1, Balance.FLAK_ROUND_LIFE, 0.08)


## Where to aim at a lead target: a shell's centre, a skiff's hull centre.
static func _lead_point(n: Node3D) -> Vector3:
	if n.is_in_group("war_shell"):
		return n.global_position
	return _hull(n)


func _make_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.add_to_group("gameplay_overlay")     # hidden on the end screen / menus (overlay_guard.gd)
	_overlay.layer = 7
	add_child(_overlay)
	_ov = Control.new()
	_ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ov.draw.connect(_draw_overlay)
	_overlay.add_child(_ov)


func _draw_overlay() -> void:
	var vs := _ov.size
	var c := vs * 0.5
	var rc := Color(1.0, 0.85, 0.55, 0.85)
	# Gunsight: a ring with range ticks.
	_ov.draw_arc(c, 34.0, 0, TAU, 64, Color(0, 0, 0, 0.4), 3.0, true)
	_ov.draw_arc(c, 34.0, 0, TAU, 64, rc, 1.5, true)
	_ov.draw_circle(c, 2.5, rc)
	for i in 12:
		var a := TAU * float(i) / 12.0
		var d := Vector2(cos(a), sin(a))
		_ov.draw_line(c + d * 34.0, c + d * (40.0 if i % 3 == 0 else 37.0), rc, 1.5, true)
	# Lead: the target bracket and where to aim.
	var tline := "Hedef yok — gelen düşman mermisi ya da mekiği yok"
	var tcol := UI.DIM
	if _lead_target != null and is_instance_valid(_lead_target) and not _lead.is_empty():
		var tp: Vector3 = _lead_point(_lead_target)
		var from := muzzle_position()
		var aimp: Vector3 = from + (_lead["dir"] as Vector3) * 400.0
		var red := Color(1.0, 0.35, 0.3, 0.95)
		if not _cam.is_position_behind(tp):
			var s := _cam.unproject_position(tp)
			var k := 14.0
			for q in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				var qv: Vector2 = q
				_ov.draw_line(s + qv * k, s + Vector2(qv.x * k * 0.45, qv.y * k), red, 2.0, true)
				_ov.draw_line(s + qv * k, s + Vector2(qv.x * k, qv.y * k * 0.45), red, 2.0, true)
		if not _cam.is_position_behind(aimp):
			var l := _cam.unproject_position(aimp)
			var on := l.distance_to(c) < 10.0
			var lc := UI.GOOD if on else Color(1.0, 0.8, 0.3, 0.95)
			_ov.draw_arc(l, 9.0, 0, TAU, 24, Color(0, 0, 0, 0.5), 3.5, true)
			_ov.draw_arc(l, 9.0, 0, TAU, 24, lc, 2.0, true)
			_ov.draw_line(c, l, Color(lc.r, lc.g, lc.b, 0.35), 1.0, true)
		var what := "düşman mermisi" if _lead_target.is_in_group("war_shell") else "rakip mekiği"
		tline = "HEDEF: %s  ·  %d m  ·  vuruş %.1f sn" % [what, int(tp.distance_to(from)), float(_lead.get("time", 0.0))]
		tcol = UI.WARN
	var w := 520.0
	var h := 112.0
	var o := Vector2(c.x - w * 0.5, vs.y - h - 28.0)
	_ov.draw_style_box(UI.box(Color(0.03, 0.05, 0.08, 0.7), 12, Color(0.4, 0.86, 1.0, 0.35), 1, 0), Rect2(o, Vector2(w, h)))
	_text(o + Vector2(18, 28), "UÇAKSAVAR   ·   AÇI %d°   ·   YÖN %d°" % [int(round(rad_to_deg(pitch))),
			int(round(fposmod(rad_to_deg(-yaw), 360.0)))], 17, UI.TEXT, _font_b)
	_text(o + Vector2(18, 56), tline, 15, tcol, _font_b)
	_text(o + Vector2(18, 82), "%s   ·   mermi %d m³   ·   malzeme %d m³" % ["ATEŞ" if _firing else "HAZIR",
			int(Balance.FLAK_ROUND_COST), int(Game.material)], 13, UI.TEXT, _font)
	_text(o + Vector2(18, h - 6), "Fare: nişan  ·  Sol tık (basılı): ateş  ·  Halkayı sarı işarete getir  ·  F: in", 11, UI.FAINT, _font)
	_text(Vector2(vs.x - 260, vs.y - 40), "UÇAKSAVAR %d / %d" % [int(ceilf(hp)), int(hp_max)], 13,
			UI.BAD if hp < hp_max * 0.35 else UI.DIM, _font_b)


func _text(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	_ov.draw_string(f, p + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.55 * col.a))
	_ov.draw_string(f, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


# =================================================================================================
# Damage, ground
# =================================================================================================

func take_damage(amount: float, _from_pos := Vector3.ZERO, _impulse := Vector3.ZERO) -> Dictionary:
	if is_destroyed or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	hp = maxf(hp - amount, 0.0)
	_hit_t = 1.0
	if hp <= 0.0:
		_destroy()
		return {"dmg": amount, "killed": true}
	return {"dmg": amount, "killed": false}


func is_dead() -> bool:
	return is_destroyed


func _destroy() -> void:
	is_destroyed = true
	tracking = false
	if pilot != null and is_instance_valid(pilot):
		pilot.exit_vehicle()
	destroyed.emit(self)
	Explosion.spawn(global_position + global_transform.basis.y * 1.2, global_transform.basis.y,
			{"radius": 4.0, "damage": 25.0, "impulse": 6.0, "crater": 0.0, "player_owned": false})
	if Game.hud:
		Game.hud.show_message("Uçaksavarımız yok edildi!" if team == "home" else "Rakibin uçaksavarı yok edildi!", 2.5)
	remove_from_group("war_structure")
	remove_from_group("war_flak")
	remove_from_group(Game.DAMAGEABLE)
	queue_free()


func _on_brush(center: Vector3, r: float) -> void:
	if is_destroyed or _ground_check:
		return
	if center.distance_to(global_position) < r + Balance.FLAK_FOOTPRINT + 2.0:
		_ground_check = true
		_settle.call_deferred()


## Sinks only when its jacks and plinth lost the ground (Foundation.support_drop, never up), then the
## jack extensions refit to the new ground.
func _settle() -> void:
	await get_tree().create_timer(1.2).timeout
	_ground_check = false
	if is_destroyed or body == null or not is_inside_tree():
		return
	var up: Vector3 = global_transform.basis.y.normalized()
	var pts := PackedVector3Array([Vector3.ZERO])
	for pl in _foundation_piles():
		pts.append(pl[0])
	var drop := Foundation.support_drop(self, body, pts)
	if drop > 0.4:
		var land := func() -> void:
			BuildFx.dust(get_parent(), global_position, up, 2.5, Color(0.5, 0.45, 0.38))
			if _foundation != null and is_instance_valid(_foundation):
				_foundation.refit(true)
		var tw := create_tween()
		tw.tween_property(self, "global_position", global_position - up * drop, clampf(sqrt(drop) * 0.3, 0.2, 1.2)).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(land)
	elif _foundation != null and is_instance_valid(_foundation):
		_foundation.refit(true)


## Foundation (scripts/war/foundation.gd): a pile under each hydraulic jack's foot (local).
func _foundation_piles() -> Array:
	var piles: Array = []
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		piles.append([Vector3(-2.0 * sin(a), 0.0, -2.0 * cos(a)), 0.14])
	return piles
