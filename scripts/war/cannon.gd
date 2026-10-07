extends Node3D
## Heavy artillery piece built on your own planet: a concrete pad with outriggers, a turret ring
## (yaw) with side plates and a gun shield, a cradle (pitch) carrying a long barrel with a muzzle
## brake, recoil cylinders and a breech. Groups "damageable", "war_structure", "war_cannon".
##
## Player (team "home"): F mans it (seat API, scripts/player/player.gd), first person behind the
## breech. Mouse = yaw / pitch, wheel = charge (muzzle speed), LMB = fire (SHELL_COST material),
## F = leave. While manned it shows the arc (Ballistics.trace), the impact ring and a readout.
## AI (team "rival"): aim_dir(dir, speed), aligned(), ready_to_fire(), fire(true) (already paid).
##   Cannon.spawn(parent, body, xf, team, animate := true) -> cannon
##   take_damage(amount, from_pos, impulse) -> {"dmg", "killed"}; destroyed when hp reaches 0.

const Balance := preload("res://scripts/war/balance.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Shell := preload("res://scripts/war/shell.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const Settings := preload("res://scripts/save/settings.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const Foundation := preload("res://scripts/war/foundation.gd")

const TRUNNION_Y := 1.75             # pivot height of the cradle above the pad
const BARREL_LEN := 5.6
const TURN_RATE := deg_to_rad(40.0)   # rad/s the turret and cradle can turn
const MOUSE_SENS := 0.0016

signal destroyed(cannon: Node3D)

var team := "home"
var body: Node3D                      # the planet it stands on
var hp := Balance.CANNON_HP
var hp_max := Balance.CANNON_HP
var pilot = null
var yaw := 0.0                        # current, rad (about the pad's up)
var pitch := deg_to_rad(45.0)         # current, rad above the horizon
var charge := 0.55                    # 0..1 between CANNON_SPEED_MIN and MAX
var reload_t := 0.0
var is_destroyed := false
## Free shells (2026-10-06 "küçük vergileri kaldır"): one more every CANNON_FREE_RELOAD s, up to
## CANNON_FREE_MAX; a player's shot uses one before it pays SHELL_COST (end of file).
var free_shells := Balance.CANNON_FREE_MAX
var _free_t := 0.0

var _yaw_t := 0.0
var _pitch_t := deg_to_rad(45.0)
var _turret: Node3D
var _cradle: Node3D
var _recoil: Node3D
var _muzzle: Node3D
var _body: StaticBody3D
var _cam: Camera3D
var _cam_kick := 0.0
var _cam_kick_v := 0.0
var _recoil_z := 0.0
var _recoil_v := 0.0
var _arc: MeshInstance3D
var _arc_mesh: ImmediateMesh
var _ring: MeshInstance3D
var _halo: MeshInstance3D
var _preview := {}
var _preview_t := 0.0
var _overlay: CanvasLayer
var _ov: Control
var _font: Font
var _font_b: Font
var _audio: AudioStreamPlayer3D
var _boom_low: AudioStreamPlayer3D
var _turn_audio: AudioStreamPlayer3D
var _flash: OmniLight3D
var _flash_t := 0.0
var _hit_t := 0.0
var _paint: StandardMaterial3D
var _build_t := -1.0
var _parts: Array = []                # [node, rest transform, delay] for the assembly animation
var _ground_check := false
var _turning := 0.0
var _foundation: Node3D               # skirt / piles down to the real ground (scripts/war/foundation.gd)


## Builds a cannon of `team` on `body` at `xf` (basis y = up), under `parent`.
static func spawn(parent: Node, p_body: Node3D, xf: Transform3D, p_team: String, animate := true) -> Node3D:
	var c: Node3D = load("res://scripts/war/cannon.gd").new()
	c.team = p_team
	c.body = p_body
	c.name = "Cannon_" + p_team
	c.transform = xf                  # (parent is the scene root at the identity: local = world)
	parent.add_child(c)
	if animate:
		c.begin_assembly()
	return c


func _ready() -> void:
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_structure")
	add_to_group("war_cannon")
	set_meta("footprint_r", Balance.CANNON_FOOTPRINT)
	_build_model()
	if body != null and not has_meta("build_preview"):
		var fs := _foundation_shape()
		_foundation = Foundation.create(self, body, fs[0], fs[1], fs[2])
		_parts.append([_foundation, _foundation.transform, 0.0])
	_build_audio()
	_font = UI.font(500)
	_font_b = UI.font(700)
	# Face the other planet by default.
	var other: Node3D = Game.rival if team == "home" else Game.planet
	if other != null:
		aim_dir((other.global_position - global_position).normalized(), 60.0)
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


## Cylinder along the local axis `axis` ("y" or "z") centred at pos.
func _cyl(parent: Node3D, pos: Vector3, r_top: float, r_bot: float, h: float, mat: Material, axis := "y", seg := 20) -> MeshInstance3D:
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
		mi.rotation = Vector3(-PI * 0.5, 0, 0)     # +Y of the mesh -> -Z
	parent.add_child(mi)
	return mi


func _build_model() -> void:
	var concrete := _mat(Color(0.36, 0.35, 0.33), 0.0, 0.92)
	var steel := _mat(Color(0.2, 0.21, 0.22), 0.85, 0.38)
	var dark := _mat(Color(0.09, 0.09, 0.1), 0.6, 0.5)
	var paint_col := Color(0.34, 0.37, 0.31) if team == "home" else Color(0.33, 0.25, 0.22)
	_paint = _mat(paint_col, 0.35, 0.62)
	var stripe := _mat(Color(0.35, 0.85, 1.0) if team == "home" else Color(0.95, 0.25, 0.15), 0.1, 0.5)
	stripe.emission_enabled = true
	stripe.emission = stripe.albedo_color
	stripe.emission_energy_multiplier = 0.6

	# --- Pad: an octagonal footing with anchor bolts and four outrigger legs with spades.
	var pad := Node3D.new()
	add_child(pad)
	_cyl(pad, Vector3(0, 0.15, 0), 2.3, 2.5, 0.7, concrete, "y", 8)
	for i in 8:
		var a := TAU * (float(i) + 0.5) / 8.0
		_cyl(pad, Vector3(cos(a) * 2.0, 0.53, sin(a) * 2.0), 0.07, 0.07, 0.12, steel, "y", 8)
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		var leg := Node3D.new()
		leg.rotation.y = a
		pad.add_child(leg)
		_box(leg, Vector3(0, 0.38, -2.6), Vector3(0.32, 0.26, 1.6), _paint)
		_box(leg, Vector3(0, 0.12, -3.35), Vector3(0.9, 0.5, 0.12), steel, Vector3(0.35, 0, 0))
	_parts.append([pad, pad.transform, 0.0])

	# --- Turret (yaw): ring, side plates with trunnions, gun shield with the team stripe, crate.
	_turret = Node3D.new()
	_turret.position = Vector3(0, 0.5, 0)
	add_child(_turret)
	_cyl(_turret, Vector3(0, 0.16, 0), 1.45, 1.55, 0.32, steel, "y", 28)
	_cyl(_turret, Vector3(0, 0.36, 0), 1.25, 1.35, 0.12, dark, "y", 28)
	for sx in [-1.0, 1.0]:
		_box(_turret, Vector3(0.62 * sx, 0.95, 0.15), Vector3(0.16, 1.3, 1.9), _paint)
		var tr := _cyl(_turret, Vector3(0.72 * sx, TRUNNION_Y - 0.5, 0.0), 0.22, 0.22, 0.12, steel, "y", 16)
		tr.rotation = Vector3(0, 0, PI * 0.5)
		_box(_turret, Vector3(0.62 * sx, 0.52, 1.0), Vector3(0.18, 0.5, 0.7), _paint, Vector3(0.6, 0, 0))
	# Shield: two angled plates in front of the trunnions with a sight window.
	_box(_turret, Vector3(-0.85, 1.2, -1.05), Vector3(1.3, 1.5, 0.08), _paint, Vector3(0.12, 0.25, 0))
	_box(_turret, Vector3(0.85, 1.2, -1.05), Vector3(1.3, 1.5, 0.08), _paint, Vector3(0.12, -0.25, 0))
	_box(_turret, Vector3(-0.85, 1.75, -1.11), Vector3(1.32, 0.12, 0.1), stripe, Vector3(0.12, 0.25, 0))
	_box(_turret, Vector3(0.85, 1.75, -1.11), Vector3(1.32, 0.12, 0.1), stripe, Vector3(0.12, -0.25, 0))
	# Ammunition crate and the loader's step behind the breech.
	_box(_turret, Vector3(1.05, 0.62, 1.45), Vector3(0.8, 0.55, 0.6), _mat(Color(0.3, 0.27, 0.2), 0.1, 0.8))
	_box(_turret, Vector3(1.05, 0.92, 1.45), Vector3(0.82, 0.06, 0.62), steel)
	_box(_turret, Vector3(0, 0.42, 1.9), Vector3(1.2, 0.08, 0.7), dark)
	_parts.append([_turret, _turret.transform, 0.25])

	# --- Cradle (pitch) with the recoiling barrel group.
	_cradle = Node3D.new()
	_cradle.position = Vector3(0, TRUNNION_Y - 0.5, 0)
	_turret.add_child(_cradle)
	_box(_cradle, Vector3(0, -0.05, -0.2), Vector3(0.9, 0.45, 2.2), _paint)
	var axle := _cyl(_cradle, Vector3(0, 0, 0), 0.24, 0.24, 1.6, steel, "y", 16)
	axle.rotation = Vector3(0, 0, PI * 0.5)
	# Recoil cylinders under the barrel.
	for sx in [-0.17, 0.17]:
		_cyl(_cradle, Vector3(sx, -0.3, -1.1), 0.09, 0.09, 2.2, steel, "z", 12)
	_recoil = Node3D.new()
	_cradle.add_child(_recoil)
	# Barrel: thick jacket, tapering tube, muzzle brake with ports.
	_cyl(_recoil, Vector3(0, 0.05, -1.2), 0.3, 0.3, 1.8, steel, "z", 24)
	_cyl(_recoil, Vector3(0, 0.05, -1.2 - 0.9 - BARREL_LEN * 0.5 + 0.9), 0.17, 0.23, BARREL_LEN - 1.8, steel, "z", 24)
	var mz := -0.3 - BARREL_LEN
	_cyl(_recoil, Vector3(0, 0.05, mz), 0.27, 0.27, 0.55, dark, "z", 16)
	for sx in [-1.0, 1.0]:
		_box(_recoil, Vector3(0.24 * sx, 0.05, mz), Vector3(0.08, 0.22, 0.32), _mat(Color(0.02, 0.02, 0.02), 0.2, 0.8))
	_cyl(_recoil, Vector3(0, 0.05, -0.55 - BARREL_LEN * 0.55), 0.2, 0.2, 0.12, stripe, "z", 20)
	# Breech block with its lever.
	_box(_recoil, Vector3(0, 0.05, 0.45), Vector3(0.62, 0.62, 0.6), steel)
	_box(_recoil, Vector3(0.36, 0.2, 0.62), Vector3(0.06, 0.06, 0.4), dark, Vector3(0.6, 0, 0))
	_muzzle = Node3D.new()
	_muzzle.position = Vector3(0, 0.05, mz - 0.35)
	_recoil.add_child(_muzzle)
	_parts.append([_cradle, _cradle.transform, 0.5])

	# Shadows on everything; the stripe glows a little.
	for mi in find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Collision (terrain-like obstacle on the ship layer) + interaction.
	_body = StaticBody3D.new()
	_body.collision_layer = Game.LAYER_SHIP
	_body.collision_mask = 0
	_body.set_meta("interact_target", self)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(3.2, 2.4, 3.4)
	cs.shape = bs
	cs.position = Vector3(0, 1.2, 0)
	_body.add_child(cs)
	var cs2 := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 2.5
	cyl.height = 0.7
	cs2.shape = cyl
	cs2.position = Vector3(0, 0.15, 0)
	_body.add_child(cs2)
	add_child(_body)

	# Muzzle flash light.
	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.7, 0.4)
	_flash.omni_range = 22.0
	_flash.light_energy = 0.0
	_flash.shadow_enabled = false
	_muzzle.add_child(_flash)

	# First-person sight camera behind the breech (follows yaw; tilts with part of the pitch).
	_cam = Camera3D.new()
	_cam.near = 0.1
	_cam.far = Game.CAM_FAR
	_cam.fov = Settings.fov
	_turret.add_child(_cam)


func _build_audio() -> void:
	_audio = AudioStreamPlayer3D.new()
	_audio.unit_size = 40.0
	_audio.max_distance = 2500.0
	_audio.max_db = 6.0
	_audio.stream = Snd.one("weap/cannon_01")
	add_child(_audio)
	_boom_low = AudioStreamPlayer3D.new()
	_boom_low.unit_size = 60.0
	_boom_low.max_distance = 2500.0
	_boom_low.stream = Snd.rand("expl/explosion", 1.02, 1.0)
	add_child(_boom_low)
	_turn_audio = AudioStreamPlayer3D.new()
	_turn_audio.unit_size = 6.0
	_turn_audio.stream = Snd.loop("foley/motor_loop")
	_turn_audio.volume_db = -80.0
	add_child(_turn_audio)


## Parts drop / rise into place over ~1.4 s (spawned by the build tool or the AI).
func begin_assembly() -> void:
	# The print (build_fx.gd) measures the whole model first, then the parts drop in through it.
	BuildFx.assemble(get_parent(), global_transform, Vector3(2.4, 1.6, 2.4), BuildFx.AUTO, self)
	_build_t = 0.0
	for p in _parts:
		var n: Node3D = p[0]
		n.transform = (p[1] as Transform3D).translated_local(Vector3(0, 2.5, 0))
		n.scale = Vector3.ONE * 0.6
		n.visible = false


# =================================================================================================
# Aiming and firing
# =================================================================================================

func speed() -> float:
	return lerpf(Balance.CANNON_SPEED_MIN, Balance.CANNON_SPEED_MAX, charge)


## World direction the barrel points.
func barrel_dir() -> Vector3:
	return -_cradle.global_transform.basis.z.normalized()


func muzzle_position() -> Vector3:
	return _muzzle.global_position


## Turns toward world direction `dir` (turret yaw + cradle pitch, clamped) with muzzle `spd`.
func aim_dir(dir: Vector3, spd: float) -> void:
	var l := global_transform.basis.orthonormalized().inverse() * dir.normalized()
	_yaw_t = atan2(-l.x, -l.z)
	_pitch_t = clampf(atan2(l.y, Vector2(l.x, l.z).length()), deg_to_rad(Balance.CANNON_PITCH_MIN),
			deg_to_rad(Balance.CANNON_PITCH_MAX))
	charge = clampf(inverse_lerp(Balance.CANNON_SPEED_MIN, Balance.CANNON_SPEED_MAX, spd), 0.0, 1.0)


## True when the barrel has reached the commanded direction.
func aligned() -> bool:
	return absf(angle_difference(yaw, _yaw_t)) < 0.004 and absf(pitch - _pitch_t) < 0.004


func ready_to_fire() -> bool:
	return reload_t <= 0.0 and not is_destroyed and _build_t < 0.0


## Fires one shell. paid = the material was already taken (the AI pays from its own pool); the
## player's cannons take SHELL_COST from Game.material. Returns true when it fired.
func fire(paid := false, on_impact := Callable()) -> bool:
	if not ready_to_fire():
		if pilot != null and Game.sfx:
			Game.sfx.play("click", -8.0, 0.7)
		return false
	var free := not paid and free_shells > 0      # a free shell first (end of file)
	if free:
		free_shells -= 1
	elif not paid and not Game.spend_material(Balance.SHELL_COST):
		if pilot != null:
			if Game.hud:
				Game.hud.show_message("Yetersiz malzeme — mermi %d m³ (bedava mermi %d sn sonra)" % [int(Balance.SHELL_COST), int(ceilf(free_shell_wait()))], 2.0)
			if Game.sfx:
				Game.sfx.play("error", -10.0)
		return false
	reload_t = Balance.CANNON_RELOAD
	var dir := barrel_dir()
	Shell.fire(get_tree().current_scene, muzzle_position() + dir * 0.4, dir * speed(), team, [_body.get_rid()], on_impact)
	# Recoil, flash, smoke, boom, camera kick.
	_recoil_v = 7.5
	_flash_t = 1.0
	_cam_kick_v += 3.5
	_muzzle_smoke(muzzle_position(), dir)
	BuildFx.dust(get_parent(), global_position, global_transform.basis.y, 3.0, Color(0.55, 0.5, 0.42))
	_audio.pitch_scale = randf_range(0.92, 1.02)
	_audio.play()
	_boom_low.pitch_scale = randf_range(0.55, 0.65)
	_boom_low.volume_db = -4.0
	_boom_low.play()
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pilot == null and pl.has_method("add_trauma"):
		var d: float = pl.global_position.distance_to(global_position)
		if d < 60.0:
			pl.add_trauma(0.4 * (1.0 - d / 60.0))
	return true


## Multiplayer: the other peer fired this cannon; the look and sound of it (the shell comes as its
## own event, scripts/net/net_world.gd).
func net_fire_fx() -> void:
	reload_t = Balance.CANNON_RELOAD
	var dir := barrel_dir()
	_recoil_v = 7.5
	_flash_t = 1.0
	_muzzle_smoke(muzzle_position(), dir)
	BuildFx.dust(get_parent(), global_position, global_transform.basis.y, 3.0, Color(0.55, 0.5, 0.42))
	_audio.pitch_scale = randf_range(0.92, 1.02)
	_audio.play()
	_boom_low.pitch_scale = randf_range(0.55, 0.65)
	_boom_low.volume_db = -4.0
	_boom_low.play()
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var d: float = pl.global_position.distance_to(global_position)
		if d < 60.0:
			pl.add_trauma(0.4 * (1.0 - d / 60.0))


func _muzzle_smoke(pos: Vector3, dir: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 28
	p.lifetime = 3.5
	p.explosiveness = 0.95
	var q := QuadMesh.new()
	q.size = Vector2(2.2, 2.2)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	p.mesh = q
	p.direction = dir
	p.spread = 25.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 14.0
	p.damping_min = 3.0
	p.damping_max = 6.0
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 0.8
	p.scale_amount_max = 2.6
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.08, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.75, 0.4, 0.9), Color(0.6, 0.58, 0.55, 0.55), Color(0.5, 0.5, 0.5, 0.0)])
	p.color_ramp = g
	get_parent().add_child(p)
	p.global_position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)


func _process(delta: float) -> void:
	_free_regen(delta)
	# Assembly.
	if _build_t >= 0.0:
		_build_t += delta
		var done := true
		for p in _parts:
			var n: Node3D = p[0]
			var k := clampf((_build_t - float(p[2])) / 0.7, 0.0, 1.0)
			n.visible = k > 0.0
			var e := 1.0 - pow(1.0 - k, 3.0)
			n.transform = (p[1] as Transform3D).translated_local(Vector3(0, 2.5 * (1.0 - e), 0)).scaled_local(Vector3.ONE * lerpf(0.6, 1.0, e))
			if k < 1.0:
				done = false
		if done:
			_build_t = -1.0
			for p in _parts:
				(p[0] as Node3D).transform = p[1]
			if Game.sfx:
				Game.sfx.play_at("impact", global_position, -4.0, 0.7, 14.0)
	reload_t = maxf(reload_t - delta, 0.0)
	# Turn toward the targets at a heavy, limited rate.
	var dy := angle_difference(yaw, _yaw_t)
	var dp := _pitch_t - pitch
	var step := TURN_RATE * delta
	yaw += clampf(dy, -step, step)
	pitch += clampf(dp, -step, step)
	_turning = move_toward(_turning, 1.0 if (absf(dy) > 0.002 or absf(dp) > 0.002) else 0.0, delta * 6.0)
	_turn_audio.volume_db = linear_to_db(maxf(_turning * 0.35, 0.0001))
	if _turning > 0.01 and not _turn_audio.playing:
		_turn_audio.play()
	elif _turning <= 0.01 and _turn_audio.playing:
		_turn_audio.stop()
	_turret.rotation.y = yaw
	_cradle.rotation.x = pitch
	# Barrel recoil spring (+z = back toward the breech).
	_recoil_v += (-_recoil_z * 60.0 - _recoil_v * 9.0) * delta
	_recoil_z += _recoil_v * delta
	_recoil.position.z = clampf(_recoil_z, 0.0, 0.9)
	_flash_t = maxf(_flash_t - delta * 8.0, 0.0)
	_flash.light_energy = 14.0 * _flash_t
	_hit_t = maxf(_hit_t - delta * 3.0, 0.0)
	_paint.emission_enabled = _hit_t > 0.0
	if _hit_t > 0.0:
		_paint.emission = Color(1.0, 0.35, 0.1) * _hit_t
	if pilot != null:
		_update_manned(delta)


# =================================================================================================
# Manned (player)
# =================================================================================================

func get_interact_prompt() -> String:
	if team != "home":
		return ""
	if _build_t >= 0.0:
		return "Top kuruluyor…"
	if has_meta("net_busy"):
		return "Top dolu — arkadaşın kullanıyor"
	return "Topa geç"


func interact(p) -> void:
	if team != "home" or _build_t >= 0.0 or is_destroyed or has_meta("net_busy"):
		return
	p.enter_vehicle(self)


func set_pilot(p) -> void:
	pilot = p
	if p != null:
		_pitch_t = pitch
		_yaw_t = yaw
		_cam.current = true
		_cam.fov = Settings.fov
		_make_overlay()
		_make_preview_nodes()
		_preview_t = 0.0
		if Game.sfx:
			Game.sfx.play("select", -10.0, 0.8)
	else:
		_cam.current = false
		if _overlay != null:
			_overlay.queue_free()
			_overlay = null
		if _arc != null:
			_arc.queue_free()
			_ring.queue_free()
			_halo.queue_free()
			_arc = null


func get_exit_transform() -> Transform3D:
	# Behind the breech, on the pad's side, standing up.
	var b := global_transform.basis.orthonormalized()
	var back := (b * Basis(Vector3.UP, yaw)) * Vector3(0, 0, 3.6)
	return Transform3D(b * Basis(Vector3.UP, yaw), global_position + back + b.y * 0.6)


func get_exit_velocity() -> Vector3:
	return Vector3.ZERO


func hud_velocity() -> Vector3:
	return Vector3.ZERO


func hud_name() -> String:
	return "Top"


func hud_extra() -> String:
	return ""


func _unhandled_input(event: InputEvent) -> void:
	if pilot == null or Game.ui_panel_open():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var lk := Settings.look((event as InputEventMouseMotion).relative)
		_yaw_t = wrapf(_yaw_t - lk.x * MOUSE_SENS, -PI, PI)
		_pitch_t = clampf(_pitch_t - lk.y * MOUSE_SENS, deg_to_rad(Balance.CANNON_PITCH_MIN), deg_to_rad(Balance.CANNON_PITCH_MAX))
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("brush_up"):
		charge = clampf(charge + 0.02, 0.0, 1.0)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("brush_down"):
		charge = clampf(charge - 0.02, 0.0, 1.0)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tool_use") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		fire()
		get_viewport().set_input_as_handled()


func _update_manned(delta: float) -> void:
	# Sight camera: behind and above the breech, looking along the barrel's yaw, tilted with most
	# of the pitch so the arc and the target stay in view.
	_cam_kick_v += (-_cam_kick * 90.0 - _cam_kick_v * 12.0) * delta
	_cam_kick += _cam_kick_v * delta
	var tilt := pitch * 0.82
	_cam.transform = Transform3D(Basis(Vector3.RIGHT, tilt + _cam_kick * 0.03),
			Vector3(0.0, TRUNNION_Y + 0.55, 3.3 + _cam_kick * 0.25))
	# Trajectory preview (~8 Hz).
	_preview_t -= delta
	if _preview_t <= 0.0:
		_preview_t = 0.15
		var dir := barrel_dir()
		_preview = Ballistics.trace(muzzle_position() + dir * 0.4, dir * speed(), Balance.SHELL_LIFE, 0.08)
		_draw_preview()
	if _ov != null:
		_ov.queue_redraw()


func _make_preview_nodes() -> void:
	_arc_mesh = ImmediateMesh.new()
	_arc = MeshInstance3D.new()
	_arc.mesh = _arc_mesh
	_arc.top_level = true
	_arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arc.custom_aabb = AABB(Vector3.ONE * -5000.0, Vector3.ONE * 10000.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_arc.material_override = m
	add_child(_arc)
	_arc.global_transform = Transform3D.IDENTITY
	# Impact ring (crater size) and a small always-visible marker.
	var tm := TorusMesh.new()
	tm.inner_radius = Balance.SHELL_CRATER_R * Balance.CRATER_SCALE - 0.6     # the carved size
	tm.outer_radius = Balance.SHELL_CRATER_R * Balance.CRATER_SCALE
	tm.rings = 48
	tm.ring_segments = 6
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.no_depth_test = true
	rm.albedo_color = Color(1.0, 0.55, 0.2, 0.75)
	tm.material = rm
	_ring = MeshInstance3D.new()
	_ring.mesh = tm
	_ring.top_level = true
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.visible = false
	add_child(_ring)
	_halo = MeshInstance3D.new()
	_halo.mesh = DebrisMesh.quad_mesh()
	_halo.material_override = DebrisMesh.halo_material(Color(1.0, 0.55, 0.2), 2.0, 0.012, 5.0)
	_halo.top_level = true
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.visible = false
	add_child(_halo)


func _draw_preview() -> void:
	if _arc == null:
		return
	_arc_mesh.clear_surfaces()
	var pts: PackedVector3Array = _preview.get("points", PackedVector3Array())
	if pts.size() >= 2:
		var col := Color(0.45, 0.9, 1.0)
		var kind := _target_kind()
		if kind == "self":
			col = Color(1.0, 0.6, 0.2)
		elif kind == "miss":
			col = Color(1.0, 0.35, 0.3)
		_arc_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		var n := pts.size()
		for i in range(0, n - 1):
			if (i / 3) % 2 == 1:
				continue                 # dashes
			var a := 0.85 * (1.0 - float(i) / float(n) * 0.6)
			_arc_mesh.surface_set_color(Color(col.r, col.g, col.b, a))
			_arc_mesh.surface_add_vertex(pts[i])
			_arc_mesh.surface_set_color(Color(col.r, col.g, col.b, a))
			_arc_mesh.surface_add_vertex(pts[i + 1])
		_arc_mesh.surface_end()
	if _preview.has("position"):
		var p: Vector3 = _preview["position"]
		var n2: Vector3 = _preview["normal"]
		_ring.visible = true
		_ring.global_transform = Transform3D(_basis_y(n2), p + n2 * 0.6)
		_halo.visible = true
		_halo.global_position = p + n2 * 1.0
	else:
		_ring.visible = false
		_halo.visible = false


static func _basis_y(up: Vector3) -> Basis:
	var y := up.normalized()
	var rf := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := rf.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


## "rival" (lands on the other planet), "self" (falls back on our own), "miss" (lost in space).
func _target_kind() -> String:
	if not _preview.has("position"):
		return "miss"
	var b = _preview.get("body")
	var mine: Node3D = Game.planet if team == "home" else Game.rival
	if b == mine:
		return "self"
	return "rival"


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
	# Sight reticle.
	var rc := Color(1.0, 0.85, 0.55, 0.85)
	_ov.draw_arc(c, 22.0, 0, TAU, 48, Color(0, 0, 0, 0.4), 3.0, true)
	_ov.draw_arc(c, 22.0, 0, TAU, 48, rc, 1.5, true)
	for d in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var dv: Vector2 = d
		_ov.draw_line(c + dv * 30.0, c + dv * 46.0, rc, 2.0, true)
	# Readout panel (bottom centre).
	var w := 520.0
	var h := 112.0
	var o := Vector2(c.x - w * 0.5, vs.y - h - 28.0)
	_ov.draw_style_box(UI.box(Color(0.03, 0.05, 0.08, 0.7), 12, Color(0.4, 0.86, 1.0, 0.35), 1, 0), Rect2(o, Vector2(w, h)))
	var line1 := "AÇI %d°   ·   YÖN %d°   ·   BARUT %d m/s" % [int(round(rad_to_deg(pitch))),
			int(round(fposmod(rad_to_deg(-yaw), 360.0))), int(round(speed()))]
	_text(o + Vector2(18, 28), line1, 17, UI.TEXT, _font_b)
	var kind := _target_kind()
	var l2 := ""
	var c2 := UI.GOOD
	match kind:
		"rival":
			var p: Vector3 = _preview["position"]
			l2 = "İSABET: RAKİP GEZEGEN  ·  %d m  ·  uçuş %d sn" % [int(p.distance_to(global_position)), int(round(float(_preview.get("time", 0.0))))]
		"self":
			l2 = "DİKKAT: mermi kendi gezegenimize düşer"
			c2 = UI.WARN
		_:
			l2 = "ISKA: mermi gezegeni kaçırıyor"
			c2 = UI.BAD
	_text(o + Vector2(18, 56), l2, 15, c2, _font_b)
	var rl := "HAZIR" if reload_t <= 0.0 else "DOLDURULUYOR %.1f sn" % reload_t
	var ammo_s := "bedava mermi %d/%d" % [free_shells, Balance.CANNON_FREE_MAX] if free_shells > 0 \
			else "bedava mermi %d sn · şimdi %d m³" % [int(ceilf(free_shell_wait())), int(Balance.SHELL_COST)]
	_text(o + Vector2(18, 82), "%s   ·   %s   ·   malzeme %d m³" % [rl, ammo_s, int(Game.material)],
			13, UI.DIM if reload_t > 0.0 else UI.TEXT, _font)
	var bar := Rect2(o + Vector2(18, 90), Vector2(w - 36, 4))
	_ov.draw_rect(bar, Color(1, 1, 1, 0.08))
	_ov.draw_rect(Rect2(bar.position, Vector2(bar.size.x * (1.0 - reload_t / Balance.CANNON_RELOAD), bar.size.y)), Color(1.0, 0.7, 0.35))
	_text(o + Vector2(18, h - 6), "Fare: nişan  ·  Teker: barut  ·  Sol tık: ateş  ·  F: in", 11, UI.FAINT, _font)
	# Barrel health.
	_text(Vector2(vs.x - 220, vs.y - 40), "TOP %d / %d" % [int(ceilf(hp)), int(hp_max)], 13,
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
	if pilot != null and is_instance_valid(pilot):
		pilot.exit_vehicle()
	destroyed.emit(self)
	Explosion.spawn(global_position + global_transform.basis.y * 1.5, global_transform.basis.y,
			{"radius": 5.0, "damage": 30.0, "impulse": 8.0, "crater": 0.0, "player_owned": false})
	if Game.hud and team == "home":
		Game.hud.show_message("Topumuz yok edildi!", 2.5)
	remove_from_group("war_structure")
	remove_from_group("war_cannon")
	remove_from_group(Game.DAMAGEABLE)
	queue_free()


## The ground under the pad was dug away (a crater or a drill): settle onto what is left.
func _on_brush(center: Vector3, r: float) -> void:
	if is_destroyed or _ground_check:
		return
	if center.distance_to(global_position) < r + Balance.CANNON_FOOTPRINT + 2.0:
		_ground_check = true
		_settle.call_deferred()


## It sinks only when under a quarter of its base still has ground (Foundation.support_drop; never up: the
## old centre-only probe lifted a pad placed on a slope onto the uphill ground at the first dig
## nearby, leaving its low side in the air); the foundation then refits to the new ground.
func _settle() -> void:
	await get_tree().create_timer(1.2).timeout      # let the crater finish carving
	_ground_check = false
	if is_destroyed or body == null or not is_inside_tree():
		return
	var up: Vector3 = global_transform.basis.y.normalized()
	var fs := _foundation_shape()
	var pts: PackedVector3Array = fs[0]
	pts.append(Vector3(0, -0.2, 0))
	var drop := Foundation.support_drop(self, body, pts)
	if drop > 0.4:
		var land := func() -> void:
			BuildFx.dust(get_parent(), global_position, up, 3.0, Color(0.5, 0.45, 0.38))
			_refit_foundation()
		var tw := create_tween()
		tw.tween_property(self, "global_position", global_position - up * drop, clampf(sqrt(drop) * 0.3, 0.2, 1.2)).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(land)
	else:
		_refit_foundation()


## Foundation (scripts/war/foundation.gd): [outline the skirt hangs from, [pile point, radius]...,
## skirt colour], local. The cannon: the octagonal footing (inside its bottom edge) and a pile under
## each outrigger spade. The buster overrides it.
func _foundation_shape() -> Array:
	var piles: Array = []
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		piles.append([Vector3(-3.35 * sin(a), -0.08, -3.35 * cos(a)), 0.12])
	return [Foundation.polygon(8, 2.44, -0.15), piles, Color(0.36, 0.35, 0.33)]


func _refit_foundation() -> void:
	if _foundation != null and is_instance_valid(_foundation):
		_foundation.refit(true)


# =================================================================================================
# Free shells (2026-10-06 "küçük vergileri kaldır"; balance.gd CANNON_FREE_*): fire() uses one before
# it pays SHELL_COST; one comes back every CANNON_FREE_RELOAD s. (The AI fires paid shells from its
# pool, as before; the Delici Top overrides fire() and keeps its own price.)
# =================================================================================================

func _free_regen(delta: float) -> void:
	if free_shells >= Balance.CANNON_FREE_MAX:
		_free_t = 0.0
		return
	_free_t += delta
	if _free_t >= Balance.CANNON_FREE_RELOAD:
		_free_t = 0.0
		free_shells += 1


## Seconds until the next free shell (0 when full).
func free_shell_wait() -> float:
	return 0.0 if free_shells >= Balance.CANNON_FREE_MAX else maxf(Balance.CANNON_FREE_RELOAD - _free_t, 0.0)
