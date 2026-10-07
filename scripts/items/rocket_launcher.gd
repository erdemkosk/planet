extends "res://scripts/items/weapon_base.gd"
## Roketatar (key 7): a shoulder-fired, single-shot rocket tube in the white / orange / dark kit.
## Model: a white tube with orange bands and a ribbed cheek sleeve, a flared rear blast cone, a
## perforated heat shield on the right, a vertical front grip (left hand), a shoulder pad, an arming
## LED (green loaded, amber loading, red empty) and, on the left, a holographic sight over a laser
## range finder whose LED range bar lights one segment per 25 m (1-6, the last blinks past 150 m).
## The loaded rocket's fuze nose sticks out of the black bore face.
## Fire (LMB): a rocket (scripts/items/rockets.gd: boost to Balance.ROCKET_MAX_SPEED, coast, gravity,
## smoke, a blast with a crater) leaves the muzzle on a line that converges with the eye ray; a heavy
## backblast behind the right shoulder (fire, a smoke cone, ground dust, a light flash); big kick,
## camera shake, FOV punch and a small shove back (ROCKET_KICK); a layered report (recorded RPG
## launch, synthesized body / punch, a gas hiss, the outdoor tail) while the rocket carries its own
## 3D roar away. Point blank into a wall it goes off at once (you take ROCKET_SELF_MULT of it).
## ADS (RMB): a slight zoom through the holo sight; the HUD reads the range finder (the distance to
## what the crosshair is on: physics + the planets' density, so the other planet reads too), marks
## the predicted impact point and a drop ladder for 25 / 50 / 75 / 100 m (at the hip only the ladder,
## faint). Reload (R, or by itself after a shot): ROCKET_RELOAD s. The tube swings off the shoulder
## across the body, muzzle to the left; the left hand fetches a rocket from the hip pouch, lines its
## tail up with the muzzle and slides it in (scrape, seat clunk, fuze arm click), and the tube goes
## back on the shoulder (lock click). Mag 1, reserve "ammo_rocket" (Game.AMMO_COST: 8 m³ each).
## Multiplayer: rocket_launched(pos, vel, cfg) fires for every rocket (cfg = Rockets.default_cfg():
## radius, damage, impulse, crater, self_mult, direct). Replay it with rockets.gd launch(pos, vel,
## team, cfg). On a client the local rocket is the look only (no direct hit, Explosion skips damage
## and craters there); the host's replay is the real one.

signal rocket_launched(pos: Vector3, vel: Vector3, cfg: Dictionary)

const WEIGHT := 0.86                      # mobility factor while held (item.gd carry_weight; loadout)
const Balance := preload("res://scripts/war/balance.gd")
const Rockets := preload("res://scripts/items/rockets.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")

const BY := 0.098                                   # bore axis above the grip
const TUBE_R := 0.05
const FRONT_Z := -0.62
const REAR_Z := 0.4
const OPTIC := Vector3(-0.1, 0.146, -0.1)           # holo window centre = the sight line (left of the tube)
const SEAT := Vector3(0.0, BY, FRONT_Z - 0.045)     # loaded rocket's nose tip (out of the bore face)
const RKT_LEN := 0.42
const INS := RKT_LEN - 0.045 + 0.03                 # slide from "tail at the muzzle" to seated
const RKT_HOLD := Vector3(-0.036, -0.03, 0.05)      # where the fist holds the rocket (rocket frame)
const POUCH := Vector3(-0.27, -0.47, -0.16)         # camera space: the rocket pouch on the left hip
const WRIST := Vector3(-0.035, -0.085, 0.05)        # wrist target relative to what the hand holds
const RANGE_MAX := 500.0
const LADDER := [25.0, 50.0, 75.0, 100.0]

var rockets                                         # rockets.gd manager (world space)
var range_m := -1.0                                 # range finder: distance to the crosshair target (-1 none)
var ladder: Array = []                              # [Vector2(m, rad below the line of sight)] for the HUD
var _preview := Vector3.INF
var _measure_t := 0.0
var _auto_reload_t := -1.0
var _rl_w := 0.0                                    # slower reload swing (replaces the base blend)
var _rkt: Node3D
var _rear: Node3D
var _arm_mat: ShaderMaterial
var _led_mats: Array = []


func _init() -> void:
	item_id = "rocket"
	item_name = "Roketatar"
	item_desc = "Sol tık: roket · Sağ tık: nişan + menzil ölçer · R: roket yükle (atıştan sonra kendiliğinden)."
	icon = "rocket"
	slot_key = 0                          # the loadout (keys 1 / 2) carries it
	accent = Color(1.0, 0.45, 0.2)
	ammo_id = "ammo_rocket"
	ammo_title = "ROKET"
	base_mag = 1
	reload_kind = "mag"
	reload_time = Balance.ROCKET_RELOAD
	reload_empty_time = Balance.ROCKET_RELOAD
	fire_rate = 1.0
	ads_fov = 62.0                     # a slight zoom only
	aim_speed = 0.6
	short_name = "Roketatar"
	head_mult = 0.0
	sight_rear = OPTIC
	optic_y = OPTIC.y
	ads_eye = Vector3(0.0, 0.0, -0.2)
	hip_pos = Vector3(0.19, -0.205, -0.33)
	hip_bore_y = BY
	hip_converge = 30.0
	hip_cant = 0.03
	sprint_pos = Vector3(0.17, -0.25, -0.36)
	sprint_rot = Vector3(-0.32, 0.55, 0.35)
	reload_pos = Vector3(0.2, -0.3, -0.38)
	reload_rot = Vector3(0.25, 1.25, 0.15)     # muzzle swung to the left, across the body
	recoil_pivot = Vector3(0.0, 0.1, 0.22)     # the shoulder contact
	spread_hip = 0.012
	spread_ads = 0.002
	bloom_add = 0.0
	bloom_max = 0.0
	first_shot_k = 1.0
	kick_pitch = 0.12
	kick_yaw = 0.02
	kick_roll = 0.035
	gun_kick = 15.0
	shake_amt = 0.9
	fov_punch_amt = -8.0
	recoil_climb = 0.0
	recoil_h = PackedFloat32Array([0.0, 0.6, -0.5])
	recoil_hold = 0.1
	recoil_recover = 0.7
	noise_radius = 90.0
	crosshair_style = "rocket"
	hit_big = 0.8
	hit_punch = 2.0
	muzzle_energy = 20.0
	punch_db = 0.0
	tail_db = -8.0                     # open air: the rolling outdoor tail (weapon_base _shot_body)
	ads_k = 90.0
	ads_c = 12.5
	draw_time = 0.85
	holster_time = 0.5


func _ready() -> void:
	super._ready()
	rockets = Rockets.new()
	rockets.name = "Rockets"
	rockets.launcher = self
	add_child(rockets)
	_snd["rpg"] = Snd.set_of("weap/rpg")
	# Own overlay: rocket reticle, drop ladder, range finder readout, "ROKET YOK".
	if hud != null:
		hud.queue_free()
	hud = RocketHud.new()
	hud.weapon = self
	add_child(hud)


func reload_label() -> String:
	return "ROKET YÜKLENİYOR"


func _hip_sway() -> float:
	return 2.1


## A heavy tube: a little slower even at the hip.
func _move_mult(e: float) -> float:
	return lerpf(0.9, aim_speed, e)


## Predicted impact point while aimed (HUD), else INF.
func impact_preview() -> Vector3:
	return _preview if ads > 0.3 else Vector3.INF


# =================================================================================================
# Firing
# =================================================================================================

func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var dir := _spread_dir(fwd, cb, current_spread())
	var ex: Array = [player.get_rid()]
	var lp := _launch_params(eye, dir, muzzle)
	var start: Vector3 = lp[0]
	var vel: Vector3 = lp[1]
	# Muzzle already inside a wall (point blank): the rocket starts at the eye and goes off on it.
	if not Ballistics.segment_hit(eye, start, get_world_3d().direct_space_state, ex).is_empty():
		start = eye
	var cfg := Rockets.default_cfg()
	rockets.launch(start, vel, "home", cfg, ex, player)
	rocket_launched.emit(start, vel, cfg)
	_backblast(eye, fwd, cb)
	player.velocity -= fwd * Balance.ROCKET_KICK
	_auto_reload_t = 0.75


## [start, velocity] of a rocket fired along dir: from the visible muzzle, converging with the eye
## ray ~30 m out, plus the shooter's own motion.
func _launch_params(eye: Vector3, dir: Vector3, muzzle: Vector3) -> Array:
	var aim_p := eye + dir * 30.0
	var d2 := (aim_p - muzzle).normalized().lerp(dir, 0.5).normalized()
	return [muzzle, d2 * Balance.ROCKET_SPEED + player.velocity]


## Backblast behind the right shoulder: a fire jet, a rolling smoke cone, a light flash and dust off
## the ground behind and around the feet.
func _backblast(eye: Vector3, fwd: Vector3, cb: Basis) -> void:
	var up: Vector3 = player.global_transform.basis.y
	var rear := eye + cb.x * 0.2 - cb.y * 0.08 + cb.z * 0.6
	var back := (cb.z * 0.92 + cb.x * 0.12).normalized()
	var g: Vector3 = Game.gravity_at(rear)
	Rockets.puff(rockets, rear, back, {"amount": 26, "life": 3.2, "vmin": 4.0, "vmax": 16.0, "damp": 3.2,
			"spread": 20.0, "size": 1.2, "scale": [0.4, 1.6, 3.4], "radius": 0.2, "explosive": 0.88, "gravity": -g * 0.05,
			"ramp": [[0.0, Color(0.9, 0.86, 0.8, 0.0)], [0.06, Color(0.86, 0.84, 0.8, 0.7)],
				[0.5, Color(0.72, 0.71, 0.7, 0.4)], [1.0, Color(0.7, 0.7, 0.7, 0.0)]]})
	Rockets.puff(rockets, rear, back, {"amount": 20, "life": 0.22, "vmin": 9.0, "vmax": 22.0, "damp": 6.0,
			"spread": 15.0, "size": 0.75, "scale": [0.6, 1.5, 2.0], "radius": 0.08, "add": true, "color": Color(2.5, 2.5, 2.5),
			"ramp": [[0.0, Color(1.0, 0.95, 0.8, 1.0)], [0.35, Color(1.0, 0.6, 0.25, 0.9)], [1.0, Color(0.6, 0.15, 0.05, 0.0)]]})
	rockets.flash_light(rear + back * 0.8, Color(1.0, 0.62, 0.3), 10.0, 0.18, 10.0)
	var space := get_world_3d().direct_space_state
	var ex: Array = [player.get_rid()]
	for probe in [[rear, (back * 0.75 - up * 0.65).normalized(), 5.0, 1.0], [eye, -up, 2.6, 0.55]]:
		var a: Vector3 = probe[0]
		var q := PhysicsRayQueryParameters3D.create(a, a + (probe[1] as Vector3) * float(probe[2]), Game.LAYER_TERRAIN, ex)
		var h := space.intersect_ray(q)
		if h.is_empty():
			continue
		var hp: Vector3 = h["position"]
		var hn: Vector3 = h["normal"]
		var col := _ground_color(hp, hn)
		var k := float(probe[3])
		Rockets.puff(rockets, hp, (hn + back * 0.8).normalized(), {"amount": int(22.0 * k), "life": 2.4, "vmin": 1.5,
				"vmax": 7.0 * k, "damp": 2.5, "spread": 55.0, "size": k + 0.3, "scale": [0.4, 1.4, 2.6], "radius": 0.3,
				"gravity": g * 0.04, "ramp": [[0.0, Color(col, 0.0)], [0.08, Color(col, 0.7)], [1.0, Color(col.lightened(0.15), 0.0)]]})


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, _cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(1.0)
	fx.muzzle_light(muzzle + fwd * 0.8, Color(1.0, 0.66, 0.35), muzzle_energy, 0.1, 18.0)
	ScreenPunch.kick(0.6)
	var g: Vector3 = Game.gravity_at(muzzle)
	Rockets.puff(rockets, muzzle + fwd * 0.25, (fwd + up * 0.15).normalized(), {"amount": 14, "life": 1.8, "vmin": 1.0,
			"vmax": 6.0, "damp": 3.0, "spread": 28.0, "size": 0.55, "scale": [0.4, 1.3, 2.4], "radius": 0.06,
			"gravity": -g * 0.04, "ramp": [[0.0, Color(0.9, 0.88, 0.85, 0.0)], [0.08, Color(0.88, 0.87, 0.85, 0.55)],
				[1.0, Color(0.75, 0.75, 0.75, 0.0)]]})
	Rockets.puff(rockets, muzzle + fwd * 0.1, fwd, {"amount": 10, "life": 0.12, "vmin": 3.0, "vmax": 9.0, "damp": 8.0,
			"spread": 25.0, "size": 0.35, "scale": [0.7, 1.3, 1.6], "radius": 0.03, "add": true, "color": Color(2.5, 2.5, 2.5),
			"ramp": [[0.0, Color(1.0, 0.92, 0.75, 1.0)], [1.0, Color(1.0, 0.45, 0.15, 0.0)]]})


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		# Vacuum: no report, only the blow through the suit.
		_play("boom_body", -3.0, 0.8, true)
		_play("thump", -5.0, 0.6, true)
		_shot_body(space, 0.7, -80.0)
		return
	_play("rpg", 0.0, randf_range(0.95, 1.03), true)
	_play("boom_body", -5.0, randf_range(0.85, 0.95), true)
	_play("thump", -7.0, 0.62, true)
	_play("hiss", -12.0, 1.3)
	_shot_body(space, 0.72, -9.0)
	if space == 2 and (_snd.get("gtail", []) as Array).is_empty():
		_play("tail", -11.0, 0.8, true)
	elif space == 1:
		_play("tail", -15.0, 1.05, true, 0.4)


# =================================================================================================
# Per frame: range finder, reload swing, auto reload
# =================================================================================================

func _tick(delta: float, on: bool) -> void:
	# A heavier swing off the shoulder than the base blend (0.22 s).
	var want := 1.0 if (reloading and reload_progress() < 0.86) else 0.0
	_rl_w = move_toward(_rl_w, want, delta / 0.36)
	_reload_w = _rl_w
	# Load the next rocket by itself shortly after a shot.
	if _auto_reload_t > 0.0:
		_auto_reload_t -= delta
		if _auto_reload_t <= 0.0 and on and mag <= 0 and not reloading and reserve_count() > 0 and can_operate():
			reload()
	_measure_t -= delta
	if on and _measure_t <= 0.0:
		_measure_t = 0.1
		_measure()


## Range finder ray, the drop ladder and (aimed) the predicted impact point, 10 times a second.
func _measure() -> void:
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var cb := cam.global_transform.basis
	var fwd := -cb.z
	var space := get_world_3d().direct_space_state
	var ex: Array = [player.get_rid()]
	var h := Ballistics.segment_hit(eye, eye + fwd * RANGE_MAX, space, ex)
	range_m = eye.distance_to(h["position"]) if not h.is_empty() else -1.0
	var lp := _launch_params(eye, fwd, muzzle_world())
	_calc_ladder(eye, cb, lp[0], lp[1])
	_preview = Vector3.INF
	if ads > 0.3:
		var pr := Rockets.predict(lp[0], lp[1], space, ex, 4.0)
		if not pr.is_empty():
			_preview = pr["position"]


## Where a rocket fired straight ahead crosses 25 / 50 / 75 / 100 m, as angles below the view axis.
func _calc_ladder(eye: Vector3, cb: Basis, p0: Vector3, v0: Vector3) -> void:
	ladder.clear()
	var fwd := -cb.z
	var p := p0
	var v := v0
	var t := 0.0
	var dt := 1.0 / 60.0
	var mi := 0
	while t < 3.0 and mi < LADDER.size():
		var res := Rockets.advance(p, v, t, dt)
		p = res[0]
		v = res[1]
		t += dt
		var rel := p - eye
		var along := rel.dot(fwd)
		if along >= float(LADDER[mi]):
			ladder.append(Vector2(float(LADDER[mi]), atan2(-rel.dot(cb.y), along)))
			mi += 1


# =================================================================================================
# Reload choreography
# =================================================================================================

func _on_reload_start() -> void:
	_auto_reload_t = -1.0


## Sounds and kicks along the reload (u = 0..1).
func _reload_events(u: float) -> void:
	var marks := [0.03, 0.17, 0.3, 0.55, 0.7, 0.76, 0.86, 0.93]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -14.0, randf_range(0.9, 1.05))          # off the shoulder
			1:
				_play("mag_out", -9.0, 0.7)                            # rocket out of the pouch
			2:
				_play("cloth", -16.0, 1.15)
			3:
				_play("mag_in", -6.0, 0.62)                            # tail into the bore: scrape
				_rk_vel += Vector4(0.15, 0.0, 0.06, 0.03)
			4:
				_play("mag_slap", -4.0, 0.7)                           # seated
				_rk_vel += Vector4(0.45, 0.0, 0.1, 0.06)
			5:
				_play("selector", -6.0, 0.8)                           # fuze armed
				_play("cyl_click", -9.0, 0.75)
			6:
				_play("cloth", -14.0, 0.95)
			7:
				_play("bolt_fwd", -6.0, 0.75)                          # back on the shoulder, locked
				_rk_vel += Vector4(0.6, 0.0, 0.0, 0.04)
		_reload_ev += 1


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _rkt == null:
		return
	var rk := Transform3D(Basis(), SEAT)
	var vis := mag > 0
	if reloading and player != null:
		var u := reload_progress()
		var gun := pose_override                  # the gun frame in camera space, this frame
		var fore: Vector3 = gun * left_grip.position + WRIST
		left_reach_elbow = Vector3(-0.38, -0.78, 0.5)
		if u < 0.2:
			# Left hand off the front grip, down to the pouch.
			left_reach_w = _seg(u, 0.0, 0.07)
			left_reach = fore.lerp(POUCH + WRIST, _seg(u, 0.02, 0.18))
			vis = false
		else:
			vis = true
			if u < 0.5:
				# Out of the pouch (nose up), lined up in front of the muzzle, tail first.
				var pb := Basis.looking_at(Vector3(-0.3, 0.85, -0.45).normalized(), Vector3.BACK)
				var pouch_cam := Transform3D(pb, POUCH - pb * RKT_HOLD)
				var align := Transform3D(Basis(), SEAT - Vector3(0.0, 0.0, INS))
				rk = _blend(gun.affine_inverse() * pouch_cam, align, _seg(u, 0.24, 0.5))
			elif u < 0.72:
				# Slid down the bore.
				rk = Transform3D(Basis(), SEAT - Vector3(0.0, 0.0, INS * (1.0 - _seg(u, 0.5, 0.7))))
			else:
				# Seated; the palm presses it home.
				var press := sin(clampf((u - 0.72) / 0.06, 0.0, 1.0) * PI) * 0.008
				rk = Transform3D(Basis(), SEAT + Vector3(0.0, 0.0, press))
			var hold: Vector3 = gun * (rk * RKT_HOLD) + WRIST
			left_reach_w = 1.0 - _seg(u, 0.84, 0.95)
			left_reach = hold if u < 0.78 else hold.lerp(fore, _seg(u, 0.78, 0.9))
	else:
		left_reach_w = 0.0
	_rkt.transform = rk
	_rkt.visible = vis
	# Arming LED: green loaded, amber loading, slow red blink empty.
	var arm_col := Color(0.3, 1.0, 0.4)
	var arm_e := 3.0
	if reloading:
		arm_col = Color(1.0, 0.7, 0.2)
	elif mag <= 0:
		arm_col = Color(1.0, 0.2, 0.15)
		arm_e = 3.0 if fmod(_t, 1.0) < 0.5 else 0.3
	_arm_mat.set_shader_parameter("color", arm_col)
	_arm_mat.set_shader_parameter("energy", arm_e)
	# Range bar: one segment per 25 m; the last blinks past 150 m.
	var lit := clampi(int(ceilf(range_m / 25.0)), 1, 6) if range_m >= 0.0 else 0
	var over := range_m > 150.0
	for i in _led_mats.size():
		var on := i < lit and (i < 5 or not over or fmod(_t, 0.5) < 0.3)
		(_led_mats[i] as ShaderMaterial).set_shader_parameter("energy", 4.0 if on else 0.22)


# =================================================================================================
# Model
# =================================================================================================

## White tube with orange bands, ribbed cheek sleeve, rear blast cone, heat shield, front grip,
## shoulder pad, side holo sight over a laser range finder (LED range bar), arming LED, and the
## loaded rocket (a separate node the reload moves).
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
	# Pistol grip, trigger and guard, the fire-control housing up to the tube, safety lever.
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.023, -0.022), Vector3(0, -0.023, -0.072), 0.0045, steel)      # low: room for the trigger finger
	VM.capsule(_gun, Vector3(0, -0.023, -0.072), Vector3(0, 0.022, -0.084), 0.0045, steel)
	VM.soft_box(_gun, Vector3(0, 0.03, -0.035), Vector3(0.042, 0.05, 0.13), 0.01, gray)
	VM.box(_gun, Vector3(0.0215, 0.03, -0.035), Vector3(0.003, 0.012, 0.1), orange)
	VM.box(_gun, Vector3(-0.024, 0.035, -0.005), Vector3(0.004, 0.008, 0.022), orange, Basis(Vector3.RIGHT, -0.3))
	# The tube, a top stripe, bands.
	VM.seg(_gun, Vector3(0, BY, REAR_Z - 0.06), Vector3(0, BY, FRONT_Z + 0.05), TUBE_R, TUBE_R, white, 24)
	VM.box(_gun, Vector3(0, BY + TUBE_R - 0.001, -0.14), Vector3(0.016, 0.006, 0.46), orange)
	VM.ring(_gun, Vector3(0, BY, -0.42), Vector3.FORWARD, TUBE_R + 0.004, 0.009, orange)
	VM.ring(_gun, Vector3(0, BY, -0.09), Vector3.FORWARD, TUBE_R + 0.003, 0.006, dark)
	VM.ring(_gun, Vector3(0, BY, 0.3), Vector3.FORWARD, TUBE_R + 0.004, 0.009, orange)
	for i in 3:
		VM.ring(_gun, Vector3(0, BY, 0.315 + i * 0.016), Vector3.FORWARD, TUBE_R + 0.002, 0.004, dark)
	# Ribbed rubber sleeve where the cheek and shoulder rest.
	VM.seg(_gun, Vector3(0, BY, 0.02), Vector3(0, BY, 0.26), TUBE_R + 0.006, TUBE_R + 0.006, rubber, 24)
	for i in 6:
		VM.ring(_gun, Vector3(0, BY, 0.04 + i * 0.04), Vector3.BACK, TUBE_R + 0.0085, 0.004, dark)
	# Perforated heat shield on the right.
	VM.soft_box(_gun, Vector3(TUBE_R + 0.004, BY + 0.005, -0.3), Vector3(0.012, 0.05, 0.24), 0.004, dark)
	for i in 5:
		VM.box(_gun, Vector3(TUBE_R + 0.0105, BY + 0.005, -0.39 + i * 0.045), Vector3(0.003, 0.03, 0.02), black)
	# Muzzle: dark collar, lip, orange ring, the black bore face (the loaded fuze sticks out of it).
	VM.seg(_gun, Vector3(0, BY, FRONT_Z + 0.07), Vector3(0, BY, FRONT_Z + 0.005), TUBE_R + 0.008, TUBE_R + 0.01, dark, 24)
	VM.ring(_gun, Vector3(0, BY, FRONT_Z + 0.004), Vector3.FORWARD, TUBE_R + 0.011, 0.012, dark)
	VM.ring(_gun, Vector3(0, BY, FRONT_Z + 0.055), Vector3.FORWARD, TUBE_R + 0.011, 0.005, orange)
	VM.seg(_gun, Vector3(0, BY, FRONT_Z + 0.006), Vector3(0, BY, FRONT_Z + 0.002), TUBE_R - 0.004, TUBE_R - 0.004, black, 24)
	_muzzle = VM.node(_gun, Vector3(0, BY, FRONT_Z - 0.02))
	# Rear blast cone (venturi) with a dark throat.
	VM.seg(_gun, Vector3(0, BY, REAR_Z - 0.07), Vector3(0, BY, REAR_Z + 0.06), TUBE_R + 0.004, TUBE_R + 0.026, dark, 24)
	VM.ring(_gun, Vector3(0, BY, REAR_Z + 0.06), Vector3.BACK, TUBE_R + 0.027, 0.006, steel)
	VM.seg(_gun, Vector3(0, BY, REAR_Z + 0.058), Vector3(0, BY, REAR_Z + 0.062), TUBE_R + 0.018, TUBE_R + 0.018, black, 24)
	VM.ring(_gun, Vector3(0, BY, REAR_Z - 0.06), Vector3.BACK, TUBE_R + 0.008, 0.008, orange)
	_rear = VM.node(_gun, Vector3(0, BY, REAR_Z + 0.08))
	# Front grip under the tube (left hand), shoulder pad, sling loop.
	VM.soft_box(_gun, Vector3(0, BY - TUBE_R - 0.008, -0.3), Vector3(0.026, 0.022, 0.06), 0.006, dark)
	VM.capsule(_gun, Vector3(0, -0.07, -0.298), Vector3(0, 0.025, -0.302), 0.018, rubber)
	for i in 3:
		VM.ring(_gun, Vector3(0, -0.05 + i * 0.022, -0.299), Vector3.UP, 0.0192, 0.004, dark)
	VM.seg(_gun, Vector3(0, -0.094, -0.297), Vector3(0, -0.08, -0.298), 0.021, 0.02, orange)
	left_grip = VM.node(_gun, Vector3(0, -0.02, -0.3), hand_basis(Vector3(-0.42, -0.62, 0.66), Vector3(0, 1, 0)))
	VM.soft_box(_gun, Vector3(0, BY - TUBE_R - 0.012, 0.16), Vector3(0.03, 0.028, 0.16), 0.008, rubber)
	VM.ring(_gun, Vector3(0, BY - TUBE_R - 0.004, -0.52), Vector3.RIGHT, 0.012, 0.003, steel)
	# Side sight: bracket, holo sight, laser range finder with its LED range bar facing the eye.
	var rail_y := OPTIC.y - 0.03
	VM.soft_box(_gun, Vector3(-0.072, rail_y - 0.004, OPTIC.z + 0.005), Vector3(0.05, 0.01, 0.07), 0.003, dark)
	var so := VM.node(_gun, Vector3(OPTIC.x, 0.0, 0.0))
	VM.holo_sight(so, OPTIC.z + 0.01, rail_y, OPTIC.y, Color(1.0, 0.45, 0.15))
	VM.soft_box(_gun, Vector3(OPTIC.x, rail_y - 0.022, OPTIC.z - 0.01), Vector3(0.034, 0.03, 0.07), 0.006, gray)
	VM.seg(_gun, Vector3(OPTIC.x, rail_y - 0.022, OPTIC.z - 0.045), Vector3(OPTIC.x, rail_y - 0.022, OPTIC.z - 0.05), 0.009, 0.009, black, 14)
	VM.sphere(_gun, Vector3(OPTIC.x, rail_y - 0.022, OPTIC.z - 0.051), 0.0035, VM.glow(Color(1.0, 0.2, 0.15), 3.0))
	_led_mats.clear()
	for i in 6:
		var lc := Color(0.35, 1.0, 0.45) if i < 2 else (Color(1.0, 0.75, 0.2) if i < 4 else Color(1.0, 0.3, 0.2))
		var lm := VM.glow(lc, 0.22)
		_led_mats.append(lm)
		VM.box(_gun, Vector3(OPTIC.x - 0.0125 + i * 0.005, rail_y - 0.013, OPTIC.z + 0.0262), Vector3(0.0035, 0.004, 0.002), lm)
	# Arming LED on top of the tube.
	_arm_mat = VM.glow(Color(0.3, 1.0, 0.4), 3.0)
	VM.sphere(_gun, Vector3(0.014, BY + TUBE_R + 0.002, 0.03), 0.0042, _arm_mat)
	# The loaded rocket (moved by the reload).
	_rkt = _build_vm_rocket(_gun)
	_rkt.transform = Transform3D(Basis(), SEAT)
	_make_flash(_gun, Vector3(0, BY, FRONT_Z - 0.06), 2.2, Color(1.0, 0.6, 0.25))
	var skip: Array = [_rkt, _flash_root, _muzzle, _rear, left_grip]
	VM.bake(_gun, skip)
	VM.bake(_rkt)
	return model


## The rocket in view-model space: fuze tip at the origin, body along +Z (tail), folded fins.
func _build_vm_rocket(parent: Node3D) -> Node3D:
	var r := VM.node(parent)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var steel := VM.metal()
	var dark := VM.mat(Color(0.2, 0.21, 0.23), 0.35, 0.6)
	VM.seg(r, Vector3(0, 0, 0.0), Vector3(0, 0, 0.012), 0.004, 0.007, steel, 12)
	VM.seg(r, Vector3(0, 0, 0.012), Vector3(0, 0, 0.1), 0.007, 0.041, dark, 18)
	VM.seg(r, Vector3(0, 0, 0.1), Vector3(0, 0, 0.118), 0.042, 0.042, orange, 18)
	VM.seg(r, Vector3(0, 0, 0.118), Vector3(0, 0, 0.36), 0.04, 0.04, white, 18)
	VM.box(r, Vector3(0, 0.0405, 0.24), Vector3(0.006, 0.002, 0.16), orange)
	VM.seg(r, Vector3(0, 0, 0.36), Vector3(0, 0, RKT_LEN), 0.034, 0.028, dark, 14)
	for k in 4:
		var a := PI * 0.25 + k * PI * 0.5
		VM.box(r, Vector3(cos(a), sin(a), 0.0) * 0.0445 + Vector3(0, 0, 0.385), Vector3(0.003, 0.009, 0.07), dark,
				Basis(Vector3.BACK, a - PI * 0.5))
	return r


func _build_tp(p: Node3D) -> Node3D:
	var white := _tp_mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tp_mat(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _tp_mat(Color(0.16, 0.17, 0.19), 0.4, 0.6)
	var rubber := _tp_mat(Color(0.08, 0.08, 0.09), 0.9, 0.0)
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.03, -0.035), Vector3(0.042, 0.05, 0.13), dark)
	VM.seg(p, Vector3(0, BY, REAR_Z - 0.06), Vector3(0, BY, FRONT_Z), TUBE_R, TUBE_R, white, 12)
	VM.seg(p, Vector3(0, BY, REAR_Z - 0.07), Vector3(0, BY, REAR_Z + 0.06), TUBE_R + 0.004, TUBE_R + 0.026, dark, 12)
	VM.seg(p, Vector3(0, BY, 0.02), Vector3(0, BY, 0.26), TUBE_R + 0.006, TUBE_R + 0.006, rubber, 12)
	VM.ring(p, Vector3(0, BY, -0.42), Vector3.FORWARD, TUBE_R + 0.004, 0.01, orange)
	VM.ring(p, Vector3(0, BY, 0.3), Vector3.FORWARD, TUBE_R + 0.004, 0.01, orange)
	VM.seg(p, Vector3(0, BY, FRONT_Z + 0.07), Vector3(0, BY, FRONT_Z), TUBE_R + 0.008, TUBE_R + 0.01, dark, 12)
	VM.box(p, Vector3(OPTIC.x, OPTIC.y - 0.01, OPTIC.z), Vector3(0.036, 0.05, 0.08), dark)
	VM.capsule(p, Vector3(0, -0.07, -0.3), Vector3(0, 0.025, -0.3), 0.018, rubber)
	return VM.node(p, Vector3(0, BY, FRONT_Z - 0.02))


# =================================================================================================
# HUD overlay: rocket reticle, drop ladder, range finder readout, the predicted impact
# =================================================================================================

class RocketHud extends "res://scripts/items/weapon_hud.gd":
	func _draw_top() -> void:
		var vs := _top.size
		var c := vs * 0.5
		var col: Color = weapon.accent_color()
		_draw_crosshair(c, col)
		if weapon.reloading:
			var p: float = weapon.reload_progress()
			_top.draw_arc(c, 26.0, -PI * 0.5, -PI * 0.5 + TAU, 48, Color(0, 0, 0, 0.35), 4.0, true)
			_top.draw_arc(c, 26.0, -PI * 0.5, -PI * 0.5 + TAU * p, 48, Color(col, 0.95), 3.0, true)
			_text_c(c + Vector2(0, 52), weapon.reload_label(), 13, Color(col.lightened(0.3), 0.9), _font_b)
		elif weapon.mag <= 0:
			var blink := 0.55 + 0.45 * sin(_t * 9.0)
			var msg := "BOŞ  ·  R" if weapon.reserve_count() > 0 else "ROKET YOK  ·  kazıp malzeme topla"
			_text_c(c + Vector2(0, 46), msg, 14, Color(1.0, 0.42, 0.36, blink), _font_b)

	func _draw_crosshair(c: Vector2, col: Color) -> void:
		var w = weapon
		var aim := clampf(float(w.ads), 0.0, 1.0)
		var a := (1.0 - aim) * (1.0 - float(w.get("_sprint_w"))) * (0.4 if w.reloading else 1.0)
		var cam: Camera3D = w.player.camera if w.player != null else null
		var fov := deg_to_rad(cam.fov if cam != null else 75.0)
		var half := _top.size.y * 0.5
		var tf := tan(fov * 0.5)
		var tc := Color(0.95, 0.97, 1.0, 0.9 * a)
		var shadow := Color(0, 0, 0, 0.55 * a)
		if a > 0.02:
			# Hip: four corner arcs sized by the spread, a centre dot.
			var r := clampf(tan(float(w.current_spread())) / tf * half, 9.0, 60.0) + 4.0
			for k in 4:
				var s := k * PI * 0.5 + PI * 0.25 - 0.5
				_top.draw_arc(c + Vector2(1, 1), r, s, s + 1.0, 12, shadow, 3.0, true)
				_top.draw_arc(c, r, s, s + 1.0, 12, tc, 1.8, true)
			_top.draw_circle(c + Vector2(1, 1), 1.9, shadow)
			_top.draw_circle(c, 1.5, Color(col.lightened(0.4), a))
		# Drop ladder: where a rocket fired now crosses 25 / 50 / 75 / 100 m.
		var la := maxf(a * 0.55, aim * 0.95)
		if la > 0.02:
			var i := 0
			for e in w.ladder:
				var v: Vector2 = e
				var y := tan(v.y) / tf * half
				if y > 7.0:
					var hw := 9.0 - i * 1.5
					_top.draw_line(c + Vector2(-hw + 1.0, y + 1.0), c + Vector2(hw + 1.0, y + 1.0), Color(0, 0, 0, 0.5 * la), 2.6, true)
					_top.draw_line(c + Vector2(-hw, y), c + Vector2(hw, y), Color(1.0, 0.8, 0.6, 0.85 * la), 1.6, true)
					_text(c + Vector2(hw + 4.0, y + 4.0), "%d" % int(v.x), 10, Color(1.0, 0.85, 0.7, 0.75 * la), _font)
				i += 1
		# Aimed: the range finder readout and the predicted impact.
		if aim > 0.3:
			var ka := clampf((aim - 0.3) / 0.4, 0.0, 1.0)
			var rm: float = w.range_m
			var txt := "%d m" % int(roundf(rm)) if rm >= 0.0 else "--- m"
			var p := c + Vector2(30, -40)
			_top.draw_rect(Rect2(p, Vector2(78, 34)), Color(0.02, 0.03, 0.05, 0.5 * ka), true)
			_top.draw_rect(Rect2(p, Vector2(2, 34)), Color(col, 0.9 * ka), true)
			_text(p + Vector2(8, 12), "MENZİL", 9, Color(1, 1, 1, 0.6 * ka), _font_b)
			_text(p + Vector2(8, 29), txt, 16, Color(col.lightened(0.35), ka), _font_b)
			var ip: Vector3 = w.impact_preview()
			if ip != Vector3.INF and cam != null and not cam.is_position_behind(ip):
				var sp := cam.unproject_position(ip)
				var pulse := 0.6 + 0.4 * sin(_t * 6.0)
				_top.draw_arc(sp, 9.0, 0, TAU, 28, Color(1.0, 0.5, 0.2, 0.9 * pulse * ka), 2.0, true)
				_top.draw_circle(sp, 1.8, Color(1.0, 0.65, 0.35, 0.9 * ka))
				_text(sp + Vector2(12, 4), "%d m" % int(cam.global_position.distance_to(ip)), 10,
						Color(1.0, 0.75, 0.5, 0.85 * ka), _font_b)
		if w.player != null and w.player.get("interact_target") != null:
			_top.draw_arc(c, 18.0, 0, TAU, 40, Color(1.0, 0.85, 0.45, 0.9 * a), 2.0, true)
