extends "res://scripts/items/weapon_base.gd"
## Pompalı (pump shotgun, key 3): 9 pellets per shell in a cone, brutal up close
## (17 per pellet, full damage to 8 m, 35 % at 30 m), each pellet shoves the target a little.
## Every shot is followed by a visible pump stroke: the left hand drags the ribbed forend back (the
## red hull flies out of the port) and slams it home. Reloads shell by shell (R): the gun cants to
## show the loading port, the left hand fetches a shell and thumbs it in, again and again (fire to
## stop early); an empty gun gets racked at the end. Tube of 6.

const PUMP_TRAVEL := 0.075
const PUMP_Z := -0.335
const BORE_Y := 0.074
const PELLETS := 9
const PELLET_DMG := 17.0          # 153 per shell up close
const PELLET_SPEED := 380.0
const FULL_DMG_DIST := 8.0        # full damage to 8 m, then down to 35 % at 30 m
const PORT := Vector3(0.0, 0.006, -0.13)

var _pump: Node3D
var _port: Node3D
var _hand_shell: Node3D
var _pump_k := 0.0                # 0 home .. 1 fully back
var _cycle_t := 9.0               # time since the last shot (pump stroke)
var _cycle_ev := 0
var _rack_k := 0.0


func _init() -> void:
	item_id = "shotgun"
	item_name = "Pompalı"
	item_desc = "Sol tık: ateş (her atıştan sonra pompalar) · Sağ tık: nişan · R: fişek fişek doldur (ateş edince durur)."
	icon = "shotgun"
	accent = Color(1.0, 0.5, 0.22)
	ammo_id = "ammo_shell"
	ammo_title = "SAÇMA · 12 KALİBRE"
	base_mag = 6
	reload_kind = "shell"
	shell_start = 0.42
	shell_each = 0.52
	shell_end = 0.38
	shell_end_empty = 0.85
	fire_rate = 1.35
	ads_fov = 62.0
	sight_rear = Vector3(0.0, 0.112, 0.02)
	optic_y = 0.132
	ads_eye = Vector3(0.0, 0.0, -0.25)
	hip_pos = Vector3(0.17, -0.22, -0.38)
	hip_bore_y = BORE_Y
	reload_pos = Vector3(0.1, -0.16, -0.42)
	reload_rot = Vector3(0.3, 0.3, -0.7)
	recoil_pivot = Vector3(0.0, 0.05, 0.25)
	spread_hip = 0.062               # ~0.37 m pattern at 6 m: most pellets land on a knee-high bug
	spread_ads = 0.045
	bloom_add = 0.01
	bloom_max = 0.02
	kick_pitch = 0.135
	kick_yaw = 0.03
	kick_roll = 0.03
	gun_kick = 11.5
	shake_amt = 0.72
	fov_punch_amt = -5.5
	noise_radius = 70.0
	crosshair_style = "circle"
	hit_big = 0.45
	hit_punch = 1.4
	armor_pierce = 0.1
	muzzle_energy = 9.0
	punch_db = -3.0
	draw_time = 0.65
	holster_time = 0.4


func mode_text() -> String:
	return "%d SAÇMA" % PELLETS


func _shell_each() -> float:
	return shell_each


## Pump cycle length.
func _cycle_len() -> float:
	return 0.5


func fire() -> void:
	super.fire()
	_cooldown = maxf(1.0 / fire_rate, _cycle_len() + 0.12)
	_cycle_t = 0.0
	_cycle_ev = 0


func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var spread := current_spread()
	for i in PELLETS:
		# Even ring + center: a readable, fair pattern rather than pure noise.
		var dir: Vector3
		if i == 0:
			dir = _spread_dir(fwd, cb, spread * 0.25)
		else:
			var ang := TAU * float(i - 1) / float(PELLETS - 1) + randf_range(-0.3, 0.3)
			var r := spread * randf_range(0.3, 1.0)
			dir = (fwd + cb.x * cos(ang) * r + cb.y * sin(ang) * r).normalized()
		fx.bullet(eye, dir * PELLET_SPEED * randf_range(0.95, 1.05) + player.velocity, muzzle, 0,
				Color(1.0, 0.7, 0.35), false, 0)


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, _cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(1.5)
	fx.muzzle_light(muzzle + fwd * 0.9, Color(1.0, 0.68, 0.32), muzzle_energy, 0.06, 14.0)
	fx.muzzle_smoke(muzzle + fwd * 0.15, fwd, up)
	fx.muzzle_smoke(muzzle + fwd * 0.4, fwd, up)
	fx.muzzle_smoke(muzzle + fwd * 0.7, fwd, up)


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	# Recorded 12 gauge (TS Sound) at its own pitch, with its natural tail; the synthesized body
	# layers only add a little weight under it.
	_play("shotgun", -2.0, randf_range(0.96, 1.04), true, 0.9)
	_play("boom_body", -6.0, randf_range(0.95, 1.05), true)
	_play("thump", -8.0, 0.78, true)
	_shot_body(space, 0.82, -12.0)
	if space == 2:
		_play("tail", -13.0, randf_range(0.85, 0.95), true)
	elif space == 1:
		_play("tail", -18.0, 1.15, true, 0.3)


func _hit_damage(p: Vector3, _ammo: int) -> float:
	var fall := 1.0 - clampf((_dist(p) - FULL_DMG_DIST) / 22.0, 0.0, 1.0) * 0.65
	return PELLET_DMG * fall


func _dist(p: Vector3) -> float:
	return p.distance_to(player.global_position) if player != null else 10.0


## Each pellet shoves; up close the whole blast (9 pellets) throws small bugs off their feet.
func _hit_impulse(_ammo: int) -> float:
	return 4.2


## A killing pellet throws the body like the whole blast would (less from far away).
func _death_push(p: Vector3) -> float:
	return lerpf(24.0, 10.0, clampf((_dist(p) - 4.0) / 18.0, 0.0, 1.0))


# =================================================================================================
# Animation
# =================================================================================================

func _tick(delta: float, _on: bool) -> void:
	_cycle_t += delta
	var L := _cycle_len()
	var t0 := 0.16 * L / 0.5
	# Pump stroke after a shot: back fast, eject, forward.
	var k := 0.0
	if _cycle_t < L:
		var u := _cycle_t / L
		k = _seg(u, 0.28, 0.55) * (1.0 - _seg(u, 0.62, 0.92))
		var marks := [t0, t0 + 0.08 * L / 0.5, t0 + 0.2 * L / 0.5]
		while _cycle_ev < marks.size() and _cycle_t >= float(marks[_cycle_ev]):
			match _cycle_ev:
				0:
					_play("pump_back", -5.0, randf_range(0.95, 1.05))
				1:
					_eject_hull()
				2:
					_play("pump_fwd", -4.0, randf_range(0.95, 1.05))
					_rk_vel += Vector4(0.6, 0.0, 0.0, -0.15)
			_cycle_ev += 1
	_pump_k = maxf(k, _rack_k)


func _eject_hull() -> void:
	if player == null or _eject == null:
		return
	var cb: Basis = player.camera.global_transform.basis
	var up: Vector3 = player.global_transform.basis.y
	fx.shell(_vm_world(_eject), cb.x * randf_range(2.0, 3.0) + up * randf_range(1.8, 2.8) - (-cb.z) * 0.3 + player.velocity, true, true)


func _pose_extra() -> Transform3D:
	# The whole gun rocks slightly with the pump stroke.
	var k := _pump_k
	return Transform3D(Basis.from_euler(Vector3(-0.025 * k, 0.02 * k, -0.04 * k)), Vector3(0.0, -0.006 * k, 0.012 * k))


func _on_reload_start() -> void:
	_ensure_hand_shell()


func _shell_events(phase: int, u: float) -> void:
	match phase:
		0:
			if _shell_ev == 0 and u > 0.1:
				_play("cloth", -15.0, randf_range(0.9, 1.1))
				_shell_ev = 1
		1:
			if _shell_ev == 0 and u > 0.66:
				_play("shell_in", -5.0, randf_range(0.92, 1.08))
				_rk_vel += Vector4(0.25, 0.0, 0.1, 0.05)
				_shell_ev = 1
		2:
			if _reload_empty:
				if _shell_ev == 0 and u > 0.42:
					_play("pump_back", -4.0, 0.95)
					_shell_ev = 1
				elif _shell_ev == 1 and u > 0.72:
					_play("pump_fwd", -3.0, 0.95)
					_rk_vel += Vector4(0.8, 0.0, 0.0, -0.2)
					_shell_ev = 2


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null:
		return
	# Left hand: on the pump normally; during the reload it travels pouch -> port -> pouch.
	var shell_vis := false
	_rack_k = 0.0
	if reloading and player != null:
		var cam_inv: Transform3D = player.camera.global_transform.affine_inverse()
		var port_c: Vector3 = cam_inv * _port.global_position
		var pump_c: Vector3 = cam_inv * left_grip.global_position
		var pouch := Vector3(-0.2, -0.36, -0.3)
		var at_port := port_c + Vector3(-0.035, -0.085, 0.05)
		var at_pump := pump_c + Vector3(-0.03, -0.08, 0.06)
		var u := _shell_t
		match _shell_phase:
			0:
				var k0 := clampf(u / shell_start, 0.0, 1.0)
				left_reach_w = _seg(k0, 0.05, 0.6)
				left_reach = at_pump.lerp(pouch, _seg(k0, 0.1, 0.9))
				left_reach_elbow = Vector3(-0.35, -0.85, 0.4)
			1:
				var k1 := clampf(u / _shell_each(), 0.0, 1.0)
				left_reach_w = 1.0
				if k1 < 0.25:
					left_reach = pouch
				elif k1 < 0.62:
					left_reach = pouch.lerp(at_port, _seg(k1, 0.25, 0.62))
				elif k1 < 0.74:
					left_reach = at_port + Vector3(0.0, 0.025 * _seg(k1, 0.62, 0.72), -0.01)
				else:
					left_reach = at_port.lerp(pouch, _seg(k1, 0.76, 1.0))
				shell_vis = k1 > 0.12 and k1 < 0.7
				left_reach_elbow = Vector3(-0.3, -0.85, 0.42)
			2:
				var k2 := clampf(u / _shell_end_time(), 0.0, 1.0)
				if _reload_empty:
					left_reach_w = 1.0 - _seg(k2, 0.25, 0.4)
					left_reach = pouch.lerp(at_pump, _seg(k2, 0.0, 0.3))
					_rack_k = _seg(k2, 0.4, 0.58) * (1.0 - _seg(k2, 0.68, 0.86))
				else:
					left_reach_w = 1.0 - _seg(k2, 0.2, 0.9)
					left_reach = pouch.lerp(at_pump, _seg(k2, 0.0, 0.85))
	else:
		left_reach_w = 0.0
	if _hand_shell != null:
		_hand_shell.visible = shell_vis
	_pump.position = Vector3(0.0, 0.0, PUMP_Z + _pump_k * PUMP_TRAVEL)


func _ensure_hand_shell() -> void:
	if _hand_shell != null or player == null or player.viewmodel == null:
		return
	var lh: Node3D = player.viewmodel.left_hand
	_hand_shell = VM.node(lh, Vector3(-0.004, 0.012, -0.006), Basis(Vector3.RIGHT, -0.4))
	VM.seg(_hand_shell, Vector3(0, -0.02, 0), Vector3(0, 0.05, 0), 0.0105, 0.0105, VM.mat(Color(0.85, 0.16, 0.12), 0.45, 0.0))
	VM.seg(_hand_shell, Vector3(0, -0.026, 0), Vector3(0, -0.012, 0), 0.0112, 0.0112, VM.mat(Color(0.86, 0.66, 0.3), 0.25, 0.9))
	_hand_shell.visible = false


# =================================================================================================
# Model
# =================================================================================================

## White / orange pump gun: dark receiver with a white shell, perforated heat shield over the
## barrel, tube magazine underneath, ribbed rubber forend (the pump, animated), ghost-ring rear
## sight + glowing front bead, loading port, ejection port, shell carrier on the stock.
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	var rubber := VM.rubber()
	var gray := VM.mat(Color(0.3, 0.32, 0.35), 0.45, 0.4)
	var black := VM.mat(Color(0.03, 0.03, 0.035), 0.6, 0.2)
	var by := BORE_Y
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.02, -0.022), Vector3(0, -0.02, -0.072), 0.0045, steel)
	VM.capsule(_gun, Vector3(0, -0.02, -0.072), Vector3(0, 0.022, -0.084), 0.0045, steel)
	# Receiver.
	VM.soft_box(_gun, Vector3(0, 0.038, -0.07), Vector3(0.054, 0.05, 0.25), 0.012, gray)
	VM.soft_box(_gun, Vector3(0, 0.078, -0.07), Vector3(0.058, 0.04, 0.27), 0.014, white)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0295 * sx, 0.062, -0.07), Vector3(0.003, 0.012, 0.24), orange)
	# Loading port (bottom) and ejection port (right).
	VM.box(_gun, Vector3(0, 0.012, -0.13), Vector3(0.024, 0.004, 0.07), black)
	_port = VM.node(_gun, PORT)
	VM.box(_gun, Vector3(0.0295, 0.072, -0.08), Vector3(0.004, 0.022, 0.05), black)
	_eject = VM.node(_gun, Vector3(0.04, 0.072, -0.08))
	# Stock with a side shell carrier (four red hulls).
	VM.soft_box(_gun, Vector3(0, 0.068, 0.16), Vector3(0.044, 0.036, 0.16), 0.012, white)
	VM.box(_gun, Vector3(0, 0.087, 0.16), Vector3(0.032, 0.004, 0.13), orange)
	VM.capsule(_gun, Vector3(0, 0.03, 0.09), Vector3(0, 0.0, 0.245), 0.012, dark)
	VM.soft_box(_gun, Vector3(0, 0.035, 0.25), Vector3(0.04, 0.115, 0.036), 0.012, white)
	VM.soft_box(_gun, Vector3(0, 0.035, 0.274), Vector3(0.042, 0.122, 0.016), 0.006, rubber)
	var red := VM.mat(Color(0.82, 0.15, 0.11), 0.45, 0.0)
	var brass := VM.mat(Color(0.86, 0.66, 0.3), 0.25, 0.9)
	VM.soft_box(_gun, Vector3(-0.026, 0.06, 0.17), Vector3(0.008, 0.04, 0.1), 0.003, dark)
	for i in 4:
		var z := 0.13 + i * 0.024
		VM.seg(_gun, Vector3(-0.034, 0.042, z), Vector3(-0.034, 0.08, z), 0.0095, 0.0095, red, 10)
		VM.seg(_gun, Vector3(-0.034, 0.036, z), Vector3(-0.034, 0.044, z), 0.0101, 0.0101, brass, 10)
	# Barrel with a perforated heat shield.
	VM.seg(_gun, Vector3(0, by, -0.2), Vector3(0, by, -0.63), 0.0135, 0.0135, steel, 14)
	VM.seg(_gun, Vector3(0, by + 0.004, -0.21), Vector3(0, by + 0.004, -0.5), 0.022, 0.021, white, 6)
	for i in 6:
		for sx in [-1.0, 1.0]:
			VM.box(_gun, Vector3(0.019 * sx, by + 0.008, -0.235 - i * 0.042), Vector3(0.008, 0.012, 0.022), dark)
	VM.ring(_gun, Vector3(0, by + 0.004, -0.5), Vector3.FORWARD, 0.022, 0.005, orange)
	# Muzzle brake / shroud.
	VM.soft_box(_gun, Vector3(0, by, -0.625), Vector3(0.034, 0.032, 0.05), 0.009, dark)
	for z in [-0.612, -0.635]:
		for sx in [-1.0, 1.0]:
			VM.box(_gun, Vector3(0.017 * sx, by, z), Vector3(0.004, 0.018, 0.008), black)
	_muzzle = VM.node(_gun, Vector3(0, by, -0.655))
	# Tube magazine with an orange end cap and a barrel clamp.
	VM.seg(_gun, Vector3(0, 0.035, -0.19), Vector3(0, 0.035, -0.585), 0.0125, 0.0125, dark, 12)
	VM.seg(_gun, Vector3(0, 0.035, -0.585), Vector3(0, 0.035, -0.6), 0.0135, 0.011, orange, 12)
	VM.soft_box(_gun, Vector3(0, 0.054, -0.555), Vector3(0.018, 0.05, 0.016), 0.005, dark)
	# Sights: ghost ring on the receiver, front bead on a post.
	VM.soft_box(_gun, Vector3(0, 0.1, 0.02), Vector3(0.026, 0.008, 0.02), 0.003, dark)
	VM.ring(_gun, Vector3(0, sight_rear.y, 0.02), Vector3.BACK, 0.009, 0.0028, dark)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.012 * sx, sight_rear.y - 0.002, 0.02), Vector3(0.004, 0.02, 0.008), dark)
	VM.box(_gun, Vector3(0, 0.1, -0.075), Vector3(0.018, 0.005, 0.16), dark)
	VM.box(_gun, Vector3(0, (by + 0.022 + sight_rear.y) * 0.5, -0.6), Vector3(0.006, sight_rear.y - by - 0.02, 0.01), dark)
	VM.sphere(_gun, Vector3(0, sight_rear.y - 0.001, -0.6), 0.0026, VM.glow(Color(1.0, 0.55, 0.2), 4.0))
	# The pump: ribbed rubber forend riding on the tube, orange belly strip, steel action bars.
	_pump = VM.node(_gun, Vector3(0, 0, PUMP_Z))
	VM.seg(_pump, Vector3(0, 0.034, 0.065), Vector3(0, 0.034, -0.065), 0.025, 0.025, white, 12)
	for i in 6:
		VM.ring(_pump, Vector3(0, 0.034, -0.05 + i * 0.02), Vector3.FORWARD, 0.0268, 0.0045, rubber)
	VM.box(_pump, Vector3(0, 0.0085, 0.0), Vector3(0.016, 0.005, 0.12), orange)
	VM.ring(_pump, Vector3(0, 0.034, 0.064), Vector3.FORWARD, 0.026, 0.005, orange)
	VM.ring(_pump, Vector3(0, 0.034, -0.064), Vector3.FORWARD, 0.026, 0.005, orange)
	for sx in [-1.0, 1.0]:
		VM.box(_pump, Vector3(0.018 * sx, 0.05, 0.09), Vector3(0.003, 0.006, 0.12), steel)
	left_grip = VM.node(_pump, Vector3(-0.004, 0.026, -0.03), hand_basis(Vector3(-0.45, -0.83, 0.32), Vector3(0, 0, -1)))
	_make_flash(_gun, Vector3(0, by, -0.665), 1.35)
	var skip: Array = [_pump, _flash_root, _muzzle, _eject, _port]
	VM.bake(_gun, skip)
	VM.bake(_pump, [left_grip])
	return model


func _build_tp(p: Node3D) -> Node3D:
	var white := _tp_mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tp_mat(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _tp_mat(Color(0.16, 0.17, 0.19), 0.4, 0.6)
	var rubber := _tp_mat(Color(0.08, 0.08, 0.09), 0.9, 0.0)
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.06, -0.07), Vector3(0.056, 0.08, 0.27), white)
	VM.box(p, Vector3(0.029, 0.062, -0.07), Vector3(0.004, 0.012, 0.24), orange)
	VM.box(p, Vector3(0, 0.05, 0.17), Vector3(0.04, 0.09, 0.15), white)
	VM.seg(p, Vector3(0, 0.074, -0.2), Vector3(0, 0.074, -0.5), 0.022, 0.021, white, 6)
	VM.seg(p, Vector3(0, 0.074, -0.5), Vector3(0, 0.074, -0.65), 0.015, 0.015, dark, 10)
	VM.seg(p, Vector3(0, 0.035, -0.2), Vector3(0, 0.035, -0.58), 0.012, 0.012, dark, 8)
	VM.seg(p, Vector3(0, 0.034, -0.27), Vector3(0, 0.034, -0.4), 0.025, 0.025, rubber, 10)
	return VM.node(p, Vector3(0, 0.074, -0.66))
