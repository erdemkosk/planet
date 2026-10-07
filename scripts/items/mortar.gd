extends "res://scripts/items/weapon_base.gd"
## Havan (item id "mortar"): a portable mortar tube for indirect fire. The planets are small, so a
## lob comes down behind a hill or over the horizon: mark the enemy with the scanner, lock on, and hit
## him without ever seeing him. A POWER weapon (heavy: WEIGHT, slower still in Topçu modu).
## Model: a gunmetal tube with orange bands rising from a pistol-grip trigger housing (the right
## hand) to the mouth, a ribbed white sleeve where the left hand holds it, a round baseplate with
## spikes under the breech, a folding bipod on a collar (it swings down in Topçu modu), a carry
## handle, and on the left a sight box (bubble level, an 8-LED range bar, the lock LED, the ready
## LED). The next shell rests in the mouth, fins in, nose up.
## Fire (LMB): the shell is let go and slides down the tube (a scrape, the "thunk" on the firing pin
## after DROP_TIME) and leaves with the "whump": a big muzzle thump, a smoke ring, the tube recoiling
## into its baseplate, camera kick and shake. The shell (scripts/items/mortar_shell.gd) flies under
## the real gravity of both planets with the same fixed steps the sight predicted, whistles on the
## way down and explodes with a crater (between a grenade and a cannon shell).
## Topçu modu (hold RMB): the tube is planted at its elevation, the bipod comes down; the predicted
## arc, the landing point (a ring the size of the blast and a beam, drawn through the terrain) and the
## readout (range, elevation, flight time) show; the mouse wheel sets the range (RANGE_STEP m), the
## body's facing the azimuth (scripts/items/mortar_aim.gd).
## T: lock onto the nearest MARKED target (enemies the wrist scanner revealed, kept at their last
## known position for a while after the reveal; the build tool's team pings), T again the next one,
## after the last the lock opens. Locked, the tube solves the azimuth and the charge itself, climbs
## over a hill in the way, and the HUD reads "HEDEF KİLİTLİ · 87 m"; turn within LOCK_CONE of the
## bearing to fire. The wheel takes the tube back to manual.
## Reload (R, or by itself after a shot): RELOAD s: the left hand fetches a shell from the hip pouch
## and seats it in the mouth. Mag 1, reserve "ammo_mortar" (Game.AMMO_COST once registered).
## Multiplayer: mortar_fired(pos, vel, cfg) for every shell (cfg = MortarShell.default_cfg() + "nid");
## the other machine replays it (scripts/net/net_players.gd, the Havan section): the shell, the tube's
## blast seen from outside, the whistle, the impact. Damage and the crater are the host's.

signal mortar_fired(pos: Vector3, vel: Vector3, cfg: Dictionary)

const WEIGHT := 0.8                       # mobility factor while held (item.gd carry_weight)
const Ballistics := preload("res://scripts/items/ballistics.gd")
const MortarShell := preload("res://scripts/items/mortar_shell.gd")
const MortarAim := preload("res://scripts/items/mortar_aim.gd")
const UI := preload("res://scripts/ui/ui_style.gd")

# --- Tuning (handling; the shell's numbers: mortar_shell.gd, the sight's: mortar_aim.gd) ----------
const RELOAD := 1.6                       # s: a shell from the pouch into the mouth
const DROP_TIME := 0.32                   # s from the click to the launch (the shell slides down)
const THUNK_AT := 0.22                    # s: the shell hits the firing pin
const AUTO_RELOAD := 0.55                 # s after the shot before the next shell comes by itself
const KICK_PUSH := 0.8                    # m/s the shot shoves the carrier back (horizontal)
const SLIDE_KICK := 3.2                   # m/s: the tube recoils into its baseplate...
const SLIDE_MAX := 0.045                  # ...at most this far
const AIM_SPEED := 0.3                    # walk speed share in Topçu modu
const BIPOD_TIME := 0.35                  # s for the bipod to swing down / up
const LED_N := 8
const ACCENT := Color(1.0, 0.62, 0.26)

# --- Model (gun frame: the pistol grip at the origin, -Z forward) -----------------------------------
const TILT := 0.62                        # tube rise in the gun frame (rad)
const TUBE_D := Vector3(0.0, 0.5810, -0.8139)       # (0, sin TILT, -cos TILT)
const BASE := Vector3(0.0, 0.075, 0.05)   # breech (tube base) centre
const TUBE_LEN := 0.6
const TUBE_R := 0.036
const SH_LEN := 0.2                       # view-model shell: tail at its origin, nose at -Z SH_LEN
const SH_R := 0.03
const SEAT_IN := 0.06                     # m of the loaded shell's tail inside the mouth
const SH_HOLD := Vector3(-0.03, -0.025, -0.13)       # where the fist holds a shell (shell frame)
const POUCH := Vector3(-0.27, -0.47, -0.14)          # camera space: the shell pouch on the left hip
const WRIST := Vector3(-0.035, -0.085, 0.05)
const HIP_ROT := Vector3(-0.3, -0.24, -0.05)
const ADS_POS := Vector3(0.3, -0.5, -0.64)

## Carried like the rocket tube when running (gun_feel.gd sprint styles).
var sprint_style := "shoulder"
var handling_len := 0.85                  # handling.gd: wall pull-back length
var panel_name := "Havan"
## Right hand on the trigger grip (vm_hand.gd descriptor; the left one is set in _init).
var grip_right := {"trig_y": -0.006, "spread": [0.0, -0.24, -0.07, 0.08, 0.12]}

var shells                                # mortar_shell.gd manager (world space)
var aim                                   # mortar_aim.gd fire control
var fired := 0

var _drop_t := -1.0                       # s left of the drop (< 0: none)
var _drop_ev := 0
var _auto_reload_t := -1.0
var _slide := 0.0
var _slide_v := 0.0
var _bipod := 0.0
var _bipod_down := false
var _last_dir := Vector3.UP
var _tube: Node3D
var _shell_vm: Node3D
var _legs: Array = []                     # [node, folded Basis, deployed Basis]
var _led_mats: Array = []
var _lock_mat: ShaderMaterial
var _ready_mat: ShaderMaterial
var _bubble_mat: ShaderMaterial


func _init() -> void:
	item_id = "mortar"
	item_name = "Havan"
	item_desc = "Sol tık: mermi bırak · Sağ tık basılı: topçu modu (yörünge + düşüş noktası, teker: menzil) · T: işaretli hedefe kilitlen (tarayıcı / işaret) · R: mermi yükle."
	icon = "mortar"
	slot_key = 0                          # the loadout decides its key
	short_name = "Havan"
	accent = ACCENT
	ammo_id = "ammo_mortar"
	ammo_title = "HAVAN MERMİSİ"
	base_mag = 1
	reload_kind = "mag"
	reload_time = RELOAD
	reload_empty_time = RELOAD
	fire_rate = 1.2
	ads_fov = 70.0                        # no zoom to speak of: the sight is the arc
	aim_speed = AIM_SPEED
	hip_pos = Vector3(0.23, -0.33, -0.43)
	sprint_pos = Vector3(0.17, -0.27, -0.36)
	sprint_rot = Vector3(-0.3, 0.55, 0.35)
	reload_pos = Vector3(0.14, -0.31, -0.44)
	reload_rot = Vector3(0.3, 0.55, 0.22)       # the mouth swung toward the left hand
	recoil_pivot = BASE
	spread_hip = 0.0
	spread_ads = 0.0
	bloom_add = 0.0
	bloom_max = 0.0
	first_shot_k = 1.0
	kick_pitch = 0.09
	kick_yaw = 0.015
	kick_roll = 0.03
	gun_kick = 13.0
	shake_amt = 0.75
	fov_punch_amt = -6.0
	recoil_climb = 0.0
	recoil_h = PackedFloat32Array([0.0, 0.5, -0.4])
	recoil_hold = 0.1
	recoil_recover = 0.7
	recoil_view = 0.4
	noise_radius = 90.0
	crosshair_style = "launcher"
	hit_big = 0.9
	hit_punch = 2.0
	head_mult = 0.0
	muzzle_energy = 9.0
	punch_db = 0.0
	tail_db = -9.0
	ads_k = 70.0
	ads_c = 12.0
	draw_time = 0.9
	holster_time = 0.5
	# Left hand on the sleeve: palm under and left of the tube, index finger toward the mouth.
	grip_left = {"at": BASE + TUBE_D * 0.35, "axis": TUBE_D, "palm": Vector3(-0.35, -0.765, -0.546).normalized(),
			"r": TUBE_R + 0.008}


func _ready() -> void:
	super._ready()
	shells = MortarShell.new()
	shells.name = "MortarShells"
	add_child(shells)
	aim = MortarAim.new()
	aim.name = "MortarAim"
	aim.weapon = self
	add_child(aim)
	_snd["cannon"] = Snd.set_of("weap/cannon")
	_snd["fthump"] = Snd.set_of("feel/thump")
	if hud != null:
		hud.queue_free()
	hud = MortarHud.new()
	hud.weapon = self
	add_child(hud)


func reload_label() -> String:
	return "MERMİ YÜKLENİYOR"


func mode_text() -> String:
	if aim == null:
		return ""
	if not aim.locked.is_empty():
		return "KİLİT"
	return "%d m" % int(aim.range_set)


func _hip_sway() -> float:
	return 2.2


func _move_mult(e: float) -> float:
	return lerpf(0.92, aim_speed, e)


## Topçu modu: RMB held (the sight, the arc, the wheel's range).
func artillery() -> bool:
	return equipped and active and ads > 0.35


## The predicted landing point while in Topçu modu, else INF.
func aim_point() -> Vector3:
	if artillery() and aim != null and aim.preview.has("position"):
		return aim.preview["position"]
	return Vector3.INF


func _on_state_changed() -> void:
	super._on_state_changed()
	if not active or not equipped:
		_drop_t = -1.0


# =================================================================================================
# Input: wheel (range, Topçu modu), T (lock)
# =================================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if debug_ignore_input or not can_operate() or aim == null:
		super._unhandled_input(event)
		return
	if event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).physical_keycode == KEY_T:
		lock_next()
		get_viewport().set_input_as_handled()
		return
	if artillery() and (event.is_action_pressed("brush_up") or event.is_action_pressed("brush_down")):
		aim.step_range(1 if event.is_action_pressed("brush_up") else -1)
		if Game.sfx:
			Game.sfx.play("click", -14.0, 0.7 + aim.range_set / MortarAim.RANGE_MAX * 0.6)
		get_viewport().set_input_as_handled()
		return
	super._unhandled_input(event)


## T: the next marked target (the nearest first; after the last one the lock opens).
func lock_next() -> void:
	var msg: String = aim.cycle_lock()
	if not aim.locked.is_empty():
		if Game.sfx:
			Game.sfx.play("blip", -6.0, 1.35)
		_play("selector", -8.0, 1.2)
	else:
		if Game.sfx:
			Game.sfx.play("click", -10.0, 0.8)
		if msg != "":
			MortarShell.toast(msg, 0, "mortar_lock", 2.0)


# =================================================================================================
# Firing: the drop, then the shot
# =================================================================================================

func _trigger(_trig: bool, pressed: bool, _alt: bool, delta: float) -> void:
	if _drop_t >= 0.0:
		_drop_t -= delta
		if _drop_ev == 0 and DROP_TIME - _drop_t >= THUNK_AT:
			_drop_ev = 1
			_play("mag_slap", -5.0, 0.5, true)                  # the thunk on the firing pin
			_rk_vel += Vector4(0.0, 0.0, 0.0, 0.25)
		if _drop_t <= 0.0:
			_drop_t = -1.0
			fire()
		return
	if reloading or _cooldown > 0.0 or _since_sprint < sprint_to_fire:
		return
	if not player.viewmodel.is_raised() or not pressed:
		return
	if mag <= 0:
		_dry_fire()
		return
	var why: String = aim.fire_block()
	if why != "":
		_cooldown = 0.4
		if Game.sfx:
			Game.sfx.play("error", -10.0)
		MortarShell.toast("Havan: " + why.to_lower(), 1, "mortar_block", 1.2)
		hud.empty_flash()
		return
	# Let the shell go: it slides down the tube.
	_drop_t = DROP_TIME
	_drop_ev = 0
	_play("shell_in", -7.0, 0.62)
	_play("cloth", -16.0, 1.1)


func _fire_shot(eye: Vector3, _fwd: Vector3, _cb: Basis, muzzle: Vector3) -> void:
	var sol: Dictionary = aim.solution(true)
	if sol.is_empty():
		return
	var p0: Vector3 = sol["p0"]
	var v0: Vector3 = sol["v0"]
	var ex: Array = [player.get_rid()]
	# The launch point in a wall (the tube against a bank): from the eye.
	if not Ballistics.segment_hit(eye, p0, get_world_3d().direct_space_state, ex).is_empty():
		p0 = eye
	var cfg := MortarShell.default_cfg()
	cfg["nid"] = MortarShell.new_nid()
	shells.launch(p0, v0, "home", cfg, ex, player, muzzle)
	mortar_fired.emit(p0, v0, cfg)
	fired += 1
	_last_dir = v0.normalized()
	var up: Vector3 = player.global_transform.basis.y
	var back := -_last_dir
	back -= up * back.dot(up)
	player.velocity += back.normalized() * KICK_PUSH if back.length_squared() > 1e-4 else Vector3.ZERO
	_slide_v += SLIDE_KICK
	_auto_reload_t = AUTO_RELOAD


func _muzzle_fx(muzzle: Vector3, _fwd: Vector3, _up: Vector3, _cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(1.0)
	fx.muzzle_light(muzzle + _last_dir * 0.6, Color(1.0, 0.7, 0.4), muzzle_energy, 0.09, 16.0)
	ScreenPunch.kick(0.5)
	MortarShell.muzzle_smoke(shells, muzzle + _last_dir * 0.9, _last_dir, 0.55)     # (ahead of the eye: smaller, fainter)
	if player.has_method("add_trauma"):
		player.add_trauma(0.35)


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		# Vacuum: only the blow through the suit.
		_play("boom_body", -3.0, 0.65, true)
		_play("thump", -4.0, 0.5, true)
		_shot_body(space, 0.6, -80.0)
		return
	_play("cannon", -1.0, randf_range(1.12, 1.2), true)
	_play("launch", -2.0, randf_range(0.66, 0.72), true)
	_play("boom_body", -4.0, randf_range(0.7, 0.78), true)
	_play("thump", -6.0, 0.5, true)
	_play("fthump", -8.0, randf_range(0.9, 1.0))
	_shot_body(space, 0.62, -9.0)
	if space == 1:
		_play("tail", -14.0, 0.95, true, 0.5)


# =================================================================================================
# Per frame: the sight, the auto reload, the bipod, the LEDs
# =================================================================================================

func _tick(delta: float, on: bool) -> void:
	if aim != null:
		aim.tick(delta, on and can_operate(), on and ads > 0.35)
	if _auto_reload_t > 0.0:
		_auto_reload_t -= delta
		if _auto_reload_t <= 0.0 and on and mag <= 0 and not reloading and reserve_count() > 0 and can_operate():
			reload()
	# The tube's recoil into the baseplate (a stiff spring).
	_slide_v += (-_slide * 900.0 - _slide_v * 38.0) * minf(delta, 0.033)
	_slide = clampf(_slide + _slide_v * minf(delta, 0.033), -0.005, SLIDE_MAX)
	# The bipod comes down in Topçu modu.
	var want := on and ads > 0.5 and not reloading
	_bipod = move_toward(_bipod, 1.0 if want else 0.0, delta / BIPOD_TIME)
	if want != _bipod_down and (_bipod >= 1.0 or _bipod <= 0.0):
		_bipod_down = want
		_play("selector", -10.0, 0.62 if want else 0.75)


func _on_reload_start() -> void:
	_auto_reload_t = -1.0


func _reload_events(u: float) -> void:
	var marks := [0.04, 0.18, 0.5, 0.66, 0.74, 0.9]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -14.0, randf_range(0.9, 1.05))          # off the tube
			1:
				_play("mag_out", -9.0, 0.72)                            # a shell out of the pouch
			2:
				_play("cloth", -16.0, 1.15)
			3:
				_play("shell_in", -6.0, 0.78)                           # fins into the mouth
				_rk_vel += Vector4(0.15, 0.0, 0.05, 0.03)
			4:
				_play("cyl_click", -9.0, 0.7)                           # resting on the catch
				_rk_vel += Vector4(0.3, 0.0, 0.06, 0.04)
			5:
				_play("cloth", -14.0, 0.95)                             # the hand back on the sleeve
		_reload_ev += 1


# =================================================================================================
# Poses: the hip carry, Topçu modu (planted at the elevation, turned toward a locked bearing)
# =================================================================================================

func _hip_pose() -> Transform3D:
	return Transform3D(Basis.from_euler(HIP_ROT), hip_pos)


func _ads_pose() -> Transform3D:
	var elev := deg_to_rad(float(aim.preview.get("elev", MortarAim.table_elev(aim.range_set)))) if aim != null \
			else TILT + 0.3
	var pitch := float(player.get("_pitch")) if player != null and player.get("_pitch") != null else 0.0
	var rel := clampf(elev - pitch, 0.2, 1.1)
	var yaw := -0.22
	if aim != null and not aim.locked.is_empty():
		yaw += clampf(float(aim.off_angle), -0.5, 0.5)
	return Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, rel - TILT), ADS_POS)


# =================================================================================================
# Model animation: the drop, the reload choreography, the bipod, the tube's recoil, the LEDs
# =================================================================================================

func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _tube == null:
		return
	_tube.position = -TUBE_D * _slide
	var seat_b := Basis.looking_at(TUBE_D, Vector3.UP)
	var mouth := BASE + TUBE_D * TUBE_LEN
	var sx := Transform3D(seat_b, mouth - TUBE_D * SEAT_IN)
	var vis := mag > 0
	if _drop_t >= 0.0:
		# Let go: it slides down the bore, faster and faster.
		var k := clampf((DROP_TIME - _drop_t) / (THUNK_AT * 0.8), 0.0, 1.0)
		sx.origin = mouth - TUBE_D * (SEAT_IN + (SH_LEN + 0.03 - SEAT_IN) * k * k)
		vis = k < 1.0
	if reloading and player != null:
		var u := reload_progress()
		var tube_cam: Transform3D = pose_override * _tube.transform
		var fore: Vector3 = tube_cam * left_grip.position + WRIST
		left_reach_elbow = Vector3(-0.38, -0.78, 0.5)
		if u < 0.2:
			left_reach_w = _seg(u, 0.0, 0.07)
			left_reach = fore.lerp(POUCH + WRIST, _seg(u, 0.02, 0.18))
			vis = false
		else:
			vis = true
			var align := Transform3D(seat_b, mouth + TUBE_D * 0.04)
			if u < 0.55:
				var pb := Basis.looking_at(Vector3(-0.25, 0.9, -0.35).normalized(), Vector3.BACK)
				var pouch_cam := Transform3D(pb, POUCH - pb * SH_HOLD)
				sx = _blend(tube_cam.affine_inverse() * pouch_cam, align, _seg(u, 0.22, 0.55))
			elif u < 0.72:
				sx = Transform3D(seat_b, (mouth + TUBE_D * 0.04).lerp(mouth - TUBE_D * SEAT_IN, _seg(u, 0.55, 0.7)))
			var hold: Vector3 = tube_cam * (sx * SH_HOLD) + WRIST
			left_reach_w = 1.0 - _seg(u, 0.8, 0.94)
			left_reach = hold if u < 0.76 else hold.lerp(fore, _seg(u, 0.76, 0.9))
	else:
		left_reach_w = 0.0
	_shell_vm.transform = sx
	_shell_vm.visible = vis
	# Bipod legs: folded along the tube, swung down in Topçu modu.
	var bw := _smooth(_bipod)
	for l in _legs:
		var q := Quaternion((l[1] as Basis)).slerp(Quaternion((l[2] as Basis)), bw)
		(l[0] as Node3D).basis = Basis(q)
	# LEDs: the range bar (one segment per RANGE_MAX / LED_N), the lock, ready / loading / empty.
	var rng: float = float(aim.preview.get("land_m", aim.range_set)) if (aim != null and not aim.locked.is_empty()) \
			else (aim.range_set if aim != null else 0.0)
	var lit := clampi(int(ceilf(rng / MortarAim.RANGE_MAX * LED_N)), 1, LED_N)
	for i in _led_mats.size():
		(_led_mats[i] as ShaderMaterial).set_shader_parameter("energy", 3.6 if i < lit else 0.2)
	var lc := Color(0.2, 0.2, 0.2)
	var le := 0.2
	if aim != null and not aim.locked.is_empty():
		lc = Color(0.35, 1.0, 0.5) if aim.lock_status == "hit" else Color(1.0, 0.7, 0.2)
		le = 3.5 if (aim.lock_status == "hit" or fmod(_t, 0.4) < 0.2) else 0.4
	_lock_mat.set_shader_parameter("color", lc)
	_lock_mat.set_shader_parameter("energy", le)
	var rc := Color(0.3, 1.0, 0.4)
	var re := 3.0
	if reloading or _drop_t >= 0.0:
		rc = Color(1.0, 0.7, 0.2)
	elif mag <= 0:
		rc = Color(1.0, 0.2, 0.15)
		re = 3.0 if fmod(_t, 1.0) < 0.5 else 0.3
	_ready_mat.set_shader_parameter("color", rc)
	_ready_mat.set_shader_parameter("energy", re)
	_bubble_mat.set_shader_parameter("energy", 1.6 + 0.6 * sin(_t * 2.0))


# =================================================================================================
# Model
# =================================================================================================

## Trigger housing on a pistol grip, the baseplate under the breech, the tube (a separate node: it
## recoils into the plate) with its sleeve, bands, collar, handle, bipod and sight box, the loaded
## shell in the mouth.
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	var rubber := VM.rubber()
	var gun_m := VM.mat(Color(0.2, 0.21, 0.22), 0.38, 0.75)
	var gray := VM.mat(Color(0.3, 0.32, 0.35), 0.45, 0.4)
	var black := VM.mat(Color(0.03, 0.03, 0.035), 0.6, 0.2)
	var D := TUBE_D
	var side := Vector3.RIGHT
	var down := (Vector3.DOWN - D * Vector3.DOWN.dot(D)).normalized()      # perpendicular to the tube, down
	# Pistol grip, trigger and guard, the housing up to the breech.
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.023, -0.022), Vector3(0, -0.023, -0.072), 0.0045, steel)
	VM.capsule(_gun, Vector3(0, -0.023, -0.072), Vector3(0, 0.022, -0.084), 0.0045, steel)
	VM.soft_box(_gun, Vector3(0, 0.03, -0.02), Vector3(0.044, 0.05, 0.11), 0.01, gray)
	VM.box(_gun, Vector3(0.0225, 0.03, -0.02), Vector3(0.003, 0.012, 0.08), orange)
	VM.soft_box(_gun, Vector3(0, 0.062, 0.045), Vector3(0.05, 0.04, 0.07), 0.01, dark)
	# Baseplate: a round plate across the tube's axis under the breech, a rim, three spikes.
	var plate := BASE - D * 0.05
	VM.seg(_gun, plate - D * 0.008, plate + D * 0.008, 0.068, 0.068, white, 28)
	VM.ring(_gun, plate + D * 0.006, D, 0.07, 0.007, orange)
	VM.ring(_gun, plate + D * 0.009, D, 0.055, 0.005, dark)
	VM.seg(_gun, plate + D * 0.008, plate + D * 0.03, 0.05, 0.042, dark, 20)
	for i in 3:
		var a := PI * 0.5 + i * TAU / 3.0
		var rim := plate + (side * cos(a) + down * sin(a)) * 0.05
		VM.seg(_gun, rim - D * 0.008, rim - D * 0.04, 0.008, 0.001, steel, 8)
	# The tube (recoils along its axis into the plate).
	_tube = VM.node(_gun)
	var mouth := BASE + D * TUBE_LEN
	VM.seg(_tube, BASE - D * 0.03, BASE + D * 0.05, TUBE_R + 0.009, TUBE_R + 0.009, steel, 24)      # breech cap
	for i in 4:
		VM.ring(_tube, BASE + D * (0.06 + i * 0.018), D, TUBE_R + 0.006, 0.004, dark)              # cooling rings
	VM.seg(_tube, BASE, mouth - D * 0.01, TUBE_R, TUBE_R, gun_m, 24)
	VM.ring(_tube, BASE + D * 0.16, D, TUBE_R + 0.004, 0.008, orange)
	VM.ring(_tube, mouth - D * 0.09, D, TUBE_R + 0.004, 0.008, orange)
	VM.box(_tube, BASE + D * 0.4 + (Vector3.UP - D * Vector3.UP.dot(D)).normalized() * (TUBE_R - 0.001), Vector3(0.014, 0.005, 0.2), white,
			Basis.looking_at(D, Vector3.UP))
	# Sleeve where the left hand holds it (ribbed white composite).
	VM.seg(_tube, BASE + D * 0.24, BASE + D * 0.37, TUBE_R + 0.007, TUBE_R + 0.007, white, 24)
	for i in 5:
		VM.ring(_tube, BASE + D * (0.25 + i * 0.027), D, TUBE_R + 0.0095, 0.0035, rubber)
	# Mouth: a thick lip, the dark bore.
	VM.seg(_tube, mouth - D * 0.035, mouth, TUBE_R + 0.006, TUBE_R + 0.008, dark, 24)
	VM.ring(_tube, mouth, D, TUBE_R + 0.008, 0.006, steel)
	VM.seg(_tube, mouth - D * 0.004, mouth - D * 0.001, TUBE_R - 0.004, TUBE_R - 0.004, black, 24)
	_muzzle = VM.node(_tube, mouth + D * 0.02)
	# Collar, carry handle on top.
	var collar := BASE + D * 0.43
	VM.seg(_tube, collar - D * 0.02, collar + D * 0.02, TUBE_R + 0.008, TUBE_R + 0.008, dark, 20)
	var top := (Vector3.UP - D * Vector3.UP.dot(D)).normalized()
	VM.capsule(_tube, BASE + D * 0.12 + top * (TUBE_R + 0.004), BASE + D * 0.12 + top * (TUBE_R + 0.03), 0.005, dark)
	VM.capsule(_tube, BASE + D * 0.21 + top * (TUBE_R + 0.004), BASE + D * 0.21 + top * (TUBE_R + 0.03), 0.005, dark)
	VM.capsule(_tube, BASE + D * 0.12 + top * (TUBE_R + 0.03), BASE + D * 0.21 + top * (TUBE_R + 0.03), 0.007, rubber)
	# Sight box on the left: bubble level, the range bar and LEDs on its back face (toward the eye).
	var sb_c := BASE + D * 0.1 - side * (TUBE_R + 0.03) + top * 0.01
	var sb := Basis.looking_at(D, top)
	VM.soft_box(_tube, sb_c, Vector3(0.036, 0.034, 0.075), 0.006, gray, sb)
	VM.box(_tube, BASE + D * 0.1 - side * (TUBE_R + 0.006), Vector3(0.016, 0.012, 0.04), dark, sb)
	VM.seg(_tube, sb_c + top * 0.017, sb_c + top * 0.03, 0.009, 0.009, black, 12)                   # elevation drum
	_bubble_mat = VM.glow(Color(0.5, 1.0, 0.55), 1.6)
	VM.ellipsoid(_tube, sb_c + top * 0.019 - D * 0.02, Vector3(0.006, 0.003, 0.012), _bubble_mat, sb)
	var face := sb_c - D * 0.0385
	_led_mats.clear()
	for i in LED_N:
		var lcol := Color(0.35, 1.0, 0.45) if i < 3 else (Color(1.0, 0.75, 0.2) if i < 6 else Color(1.0, 0.32, 0.2))
		var lm := VM.glow(lcol, 0.2)
		_led_mats.append(lm)
		VM.box(_tube, face + side * (-0.0122 + i * 0.0035) + top * 0.006, Vector3(0.0026, 0.004, 0.002), lm, sb)
	_lock_mat = VM.glow(Color(0.2, 0.2, 0.2), 0.2)
	VM.sphere(_tube, face + side * -0.008 - top * 0.007, 0.0035, _lock_mat)
	_ready_mat = VM.glow(Color(0.3, 1.0, 0.4), 3.0)
	VM.sphere(_tube, face + side * 0.008 - top * 0.007, 0.0035, _ready_mat)
	# Bipod: two legs hinged on the collar, folded back along the tube.
	_legs.clear()
	for s: float in [-1.0, 1.0]:
		var hinge := collar + side * s * (TUBE_R + 0.012) - top * 0.01
		var folded := VM.basis_y((-D + side * s * 0.06).normalized())
		var deployed := VM.basis_y((side * s * 0.45 + Vector3.DOWN * 0.85 - D * 0.2 + Vector3.FORWARD * 0.15).normalized())
		var leg := VM.node(_tube, hinge, folded)
		VM.sphere(leg, Vector3.ZERO, 0.009, dark)
		VM.seg(leg, Vector3.ZERO, Vector3(0, 0.3, 0), 0.0065, 0.0055, white, 10)
		VM.seg(leg, Vector3(0, 0.1, 0), Vector3(0, 0.12, 0), 0.008, 0.008, orange, 10)
		VM.seg(leg, Vector3(0, 0.3, 0), Vector3(0, 0.33, 0), 0.006, 0.012, rubber, 10)
		VM.bake(leg)
		_legs.append([leg, folded, deployed])
	left_grip = VM.node(_tube, BASE + D * 0.35)
	# The loaded shell (moved by the drop and the reload).
	_shell_vm = _build_vm_shell(_tube)
	var fp := VM.node(_tube, mouth, Basis.looking_at(D, Vector3.UP))
	_make_flash(fp, Vector3(0, 0, -0.05), 1.7, Color(1.0, 0.62, 0.3))
	var leg_nodes: Array = []
	for l in _legs:
		leg_nodes.append(l[0])
	var skip: Array = [_tube]
	VM.bake(_gun, skip)
	var skip_t: Array = [_shell_vm, fp, _muzzle, left_grip] + leg_nodes
	VM.bake(_tube, skip_t)
	VM.bake(_shell_vm)
	return model


## The shell in view-model space: the tail (fins) at the origin, the nose along -Z.
func _build_vm_shell(parent: Node3D) -> Node3D:
	var r := VM.node(parent)
	var olive := VM.mat(Color(0.27, 0.31, 0.2), 0.55, 0.2)
	var dark := VM.mat(Color(0.12, 0.13, 0.12), 0.45, 0.6)
	var band := VM.mat(Color(0.85, 0.2, 0.12), 0.5, 0.0)
	var steel := VM.metal()
	VM.seg(r, Vector3(0, 0, 0.0), Vector3(0, 0, -0.06), SH_R * 0.32, SH_R * 0.32, dark, 12)          # tail boom
	for k in 6:
		var a := k * TAU / 6.0
		VM.box(r, Vector3(-sin(a), cos(a), 0.0) * SH_R * 0.6 + Vector3(0, 0, -0.03), Vector3(0.003, SH_R * 0.75, 0.05), dark,
				Basis(Vector3.BACK, a))
	VM.seg(r, Vector3(0, 0, -0.06), Vector3(0, 0, -0.09), SH_R * 0.4, SH_R, olive, 16)
	VM.seg(r, Vector3(0, 0, -0.09), Vector3(0, 0, -0.14), SH_R, SH_R, olive, 16)
	VM.seg(r, Vector3(0, 0, -0.1), Vector3(0, 0, -0.108), SH_R + 0.001, SH_R + 0.001, band, 16)
	VM.seg(r, Vector3(0, 0, -0.14), Vector3(0, 0, -0.185), SH_R, SH_R * 0.32, olive, 16)
	VM.seg(r, Vector3(0, 0, -0.185), Vector3(0, 0, -SH_LEN), SH_R * 0.3, SH_R * 0.12, steel, 10)    # fuze
	return r


func _build_tp(p: Node3D) -> Node3D:
	var gun_m := _tp_mat(Color(0.2, 0.21, 0.22), 0.4, 0.7)
	var white := _tp_mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tp_mat(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _tp_mat(Color(0.16, 0.17, 0.19), 0.4, 0.6)
	var D := TUBE_D
	var mouth := BASE + D * TUBE_LEN
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.035, -0.0), Vector3(0.044, 0.05, 0.11), dark)
	VM.seg(p, BASE - D * 0.058, BASE - D * 0.042, 0.068, 0.068, white, 16)
	VM.seg(p, BASE - D * 0.03, mouth, TUBE_R + 0.002, TUBE_R + 0.002, gun_m, 12)
	VM.seg(p, BASE + D * 0.24, BASE + D * 0.37, TUBE_R + 0.008, TUBE_R + 0.008, white, 12)
	VM.ring(p, BASE + D * 0.16, D, TUBE_R + 0.006, 0.01, orange)
	VM.ring(p, mouth - D * 0.09, D, TUBE_R + 0.006, 0.01, orange)
	VM.seg(p, mouth - D * 0.035, mouth, TUBE_R + 0.008, TUBE_R + 0.01, dark, 12)
	for s: float in [-1.0, 1.0]:
		var hinge := BASE + D * 0.43 + Vector3.RIGHT * s * (TUBE_R + 0.012)
		VM.seg(p, hinge, hinge - D * 0.3 + Vector3.RIGHT * s * 0.02, 0.007, 0.006, white, 8)
	return VM.node(p, mouth + D * 0.02)


# =================================================================================================
# HUD: the reticle, the landing marker, the marks, the Topçu readout (own overlay, ui_style.gd)
# =================================================================================================

class MortarHud extends Node:
	var weapon
	var _layer: CanvasLayer
	var _top: Control
	var _t := 0.0
	var _empty_t := 0.0
	var _font: Font
	var _font_b: Font
	var _font_n: Font

	func _ready() -> void:
		_font = UI.font(500)
		_font_b = UI.font(700)
		_font_n = UI.font_num(700)
		_layer = CanvasLayer.new()
		_layer.add_to_group("gameplay_overlay")       # hidden on the end screen / menus (overlay_guard.gd)
		_layer.layer = 11
		add_child(_layer)
		_top = Control.new()
		_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_top.draw.connect(_draw_top)
		_layer.add_child(_top)

	func empty_flash() -> void:
		_empty_t = 1.0

	func mode_switched() -> void:
		pass

	func _process(delta: float) -> void:
		_t += delta
		_empty_t = maxf(_empty_t - delta, 0.0)
		_top.visible = weapon != null and weapon.hud_visible()
		if _top.visible:
			_top.queue_redraw()

	func _draw_top() -> void:
		var w = weapon
		var vs := _top.size
		var c := (vs * 0.5).round()
		var k := UI.scale_k(vs)
		var col: Color = w.accent_color()
		var art := clampf((float(w.ads) - 0.2) / 0.4, 0.0, 1.0)
		var a: Dictionary = w.aim.preview if w.aim != null else {}
		_reticle(c, k, col, art)
		if art > 0.02:
			_marks(k, art)
			_landing(c, k, art, a)
			_panel(c, vs, k, art, a)
		else:
			_hip_line(c, k, col)
		# Reload ring, empty, a refused shot.
		if w.reloading:
			UI.draw_ring(_top, c, 26.0 * k, float(w.reload_progress()), Color(col.lerp(UI.SUIT_ORANGE, 0.35), 0.95), maxf(3.0 * k, 2.0))
			UI.draw_text_c(_top, UI.font_caps(700, 2), c + Vector2(0, 54.0 * k), str(w.reload_label()), UI.fs(12, k),
					Color(col.lightened(0.3), 0.92), 3)
		elif w.mag <= 0:
			var blink := 0.55 + 0.45 * sin(_t * 9.0)
			var msg := "BOŞ  ·  R" if w.reserve_count() > 0 else "HAVAN MERMİSİ YOK"
			UI.draw_text_c(_top, _font_b, c + Vector2(0, 48.0 * k), msg, UI.fs(14, k), Color(UI.CRIT.lightened(0.1), blink), 3)
		elif _empty_t > 0.0 and w.aim != null and w.aim.fire_block() != "":
			UI.draw_text_c(_top, _font_b, c + Vector2(0, 48.0 * k), str(w.aim.fire_block()), UI.fs(14, k),
					Color(UI.BAD, _empty_t), 3)

	## A mortar reticle: a short level line with a centre post (the azimuth), faint corner ticks.
	func _reticle(c: Vector2, k: float, col: Color, art: float) -> void:
		var al := (0.4 if weapon.reloading else 1.0) * (1.0 - float(weapon.get("_sprint_w")))
		if al < 0.02:
			return
		var ol := Color(UI.OUTLINE, 0.7 * al)
		var tc := Color(0.95, 0.97, 0.98, 0.9 * al)
		var lw := maxf(2.0 * k, 1.5)
		var hw := lerpf(12.0, 26.0, art) * k
		_top.draw_line(c + Vector2(-hw, 0), c + Vector2(-5.0 * k, 0), ol, lw + 2.0, true)
		_top.draw_line(c + Vector2(5.0 * k, 0), c + Vector2(hw, 0), ol, lw + 2.0, true)
		_top.draw_line(c + Vector2(-hw, 0), c + Vector2(-5.0 * k, 0), tc, lw, true)
		_top.draw_line(c + Vector2(5.0 * k, 0), c + Vector2(hw, 0), tc, lw, true)
		_top.draw_line(c + Vector2(0, -12.0 * k), c + Vector2(0, -4.0 * k), ol, lw + 2.0, true)
		_top.draw_line(c + Vector2(0, -12.0 * k), c + Vector2(0, -4.0 * k), Color(col.lightened(0.3), al), lw, true)
		_top.draw_circle(c, 2.2 * k, ol)
		_top.draw_circle(c, 1.4 * k, Color(col.lightened(0.4), al))

	## At the hip (lean: the Topçu overlay is RMB only): the range setting, or the lock, under the reticle.
	func _hip_line(c: Vector2, k: float, col: Color) -> void:
		var w = weapon
		if w.aim == null or w.reloading:
			return
		var s := "%d m" % int(w.aim.range_set)
		var sc := Color(col.lightened(0.3), 0.7)
		if not w.aim.locked.is_empty():
			s = "KİLİT"
			sc = Color(UI.GOOD, 0.85)
		UI.draw_text_c(_top, UI.font_caps(700, 1), c + Vector2(0, 36.0 * k), s, UI.fs(10, k), sc, 3)

	## The marks T can lock onto: a diamond each (red enemies, amber pings), the locked one framed.
	func _marks(k: float, art: float) -> void:
		var w = weapon
		var cam: Camera3D = w.player.camera
		var lk: Dictionary = w.aim.locked
		var vs := _top.size
		for m in w.aim.candidates():
			var p: Vector3 = m["pos"]
			var up: Vector3 = _up_at(p)
			var sp3 := p + up * 1.4
			var on_lock: bool = not lk.is_empty() and MortarAim._same(m, lk)
			var mc := UI.WARN if str(m["kind"]) == "ping" else UI.RIVAL
			if bool(m.get("last", false)):
				mc = mc.lerp(UI.DIM, 0.45)
			if on_lock:
				mc = UI.GOOD if str(w.aim.lock_status) in ["hit", "near", ""] else UI.BAD
			var behind := cam.is_position_behind(sp3)
			var sp := cam.unproject_position(sp3)
			var inside := not behind and Rect2(Vector2.ZERO, vs).grow(-20.0 * k).has_point(sp)
			if not inside:
				if not on_lock:
					continue
				# The locked one off screen: an arrow on the edge toward it.
				var dir := (sp - vs * 0.5) * (-1.0 if behind else 1.0)
				if dir.length_squared() < 1.0:
					dir = Vector2.UP
				var e := vs * 0.5 + dir.normalized() * minf(vs.x, vs.y) * 0.42
				var n := dir.normalized()
				var tri := PackedVector2Array([e + n * 14.0 * k, e + n.rotated(2.5) * 10.0 * k, e + n.rotated(-2.5) * 10.0 * k])
				_top.draw_colored_polygon(tri, Color(mc, art))
				UI.draw_text_c(_top, _font_n, e - n * 16.0 * k + Vector2(0, 4.0 * k), "%d m" % int(m["dist"]), UI.fs(11, k), Color(mc, art), 3)
				continue
			var s := 7.0 * k
			var pts := PackedVector2Array([sp + Vector2(0, -s), sp + Vector2(s, 0), sp + Vector2(0, s), sp + Vector2(-s, 0)])
			_top.draw_colored_polygon(pts, Color(mc, 0.35 * art))
			pts.append(pts[0])
			_top.draw_polyline(pts, Color(mc, 0.95 * art), maxf(1.5 * k, 1.2), true)
			var lbl := "%s · %d m" % [str(m["label"]), int(m["dist"])]
			if bool(m.get("last", false)):
				lbl += " · son konum"
			if on_lock:
				var fr := Rect2(sp - Vector2(16, 16) * k, Vector2(32, 32) * k)
				var pulse := 0.7 + 0.3 * sin(_t * 8.0)
				UI.draw_corners(_top, fr, 8.0 * k, Color(mc, pulse * art), maxf(2.0 * k, 1.5))
				UI.draw_text_c(_top, UI.font_caps(800, 2), sp + Vector2(0, -24.0 * k), "HEDEF KİLİTLİ · %d m" % int(m["dist"]),
						UI.fs(12, k), Color(mc.lightened(0.2), art), 3)
				UI.draw_text_c(_top, _font, sp + Vector2(0, 30.0 * k), lbl, UI.fs(10, k), Color(UI.TEXT, 0.85 * art), 3)
			else:
				UI.draw_text_c(_top, _font, sp + Vector2(0, -12.0 * k), lbl, UI.fs(10, k), Color(mc.lightened(0.3), 0.85 * art), 3)

	## The predicted landing point (seen through the ground): a ring, the distance and the flight time.
	func _landing(c: Vector2, k: float, art: float, a: Dictionary) -> void:
		var w = weapon
		var cam: Camera3D = w.player.camera
		var lc: Color = w.aim.sight_color()
		if not a.has("position"):
			return
		var p: Vector3 = a["position"]
		var vs := _top.size
		if cam.is_position_behind(p):
			return
		var sp := cam.unproject_position(p)
		if not Rect2(Vector2.ZERO, vs).has_point(sp):
			# Off screen (below the view, over the horizon): a caret at the edge.
			var e := Vector2(clampf(sp.x, 30.0 * k, vs.x - 30.0 * k), clampf(sp.y, 30.0 * k, vs.y - 30.0 * k))
			_top.draw_circle(e, 5.0 * k, Color(lc, 0.85 * art))
			return
		var pulse := 0.65 + 0.35 * sin(_t * 6.0)
		var lw := maxf(2.0 * k, 1.5)
		_top.draw_arc(sp, 11.0 * k, 0, TAU, 32, Color(UI.OUTLINE, 0.5 * art), lw + 2.0, true)
		_top.draw_arc(sp, 11.0 * k, 0, TAU, 32, Color(lc, 0.95 * pulse * art), lw, true)
		_top.draw_line(sp + Vector2(-16, 0) * k, sp + Vector2(-7, 0) * k, Color(lc, 0.9 * art), lw, true)
		_top.draw_line(sp + Vector2(7, 0) * k, sp + Vector2(16, 0) * k, Color(lc, 0.9 * art), lw, true)
		_top.draw_circle(sp, 2.0 * k, Color(lc.lightened(0.2), art))
		var txt := "%d m · %.1f sn" % [int(float(a.get("land_m", 0.0))), float(a.get("time", 0.0))]
		UI.draw_text(_top, _font_n, sp + Vector2(18.0, 4.0) * k, txt.replace(".", ","), UI.fs(11, k), Color(lc.lightened(0.3), 0.95 * art), 3)
		if sp.distance_to(c) > 40.0 * k:
			_top.draw_dashed_line(c, sp, Color(lc, 0.18 * art), 1.0, 6.0 * k)

	## The Topçu readout (bottom centre): range / elevation / flight, the lock or the hint, the keys.
	func _panel(c: Vector2, vs: Vector2, k: float, art: float, a: Dictionary) -> void:
		var w = weapon
		var ai = w.aim
		var pw := 460.0 * k
		var ph := 84.0 * k
		var r := Rect2(Vector2(c.x - pw * 0.5, vs.y - 200.0 * k), Vector2(pw, ph))
		var lc: Color = ai.sight_color()
		UI.draw_glass(_top, r, k, lc, 0.35, art)
		var x := r.position.x + 16.0 * k
		UI.draw_text(_top, UI.font_caps(800, 2), Vector2(x, r.position.y + 20.0 * k), "TOPÇU MODU", UI.fs(11, k), Color(lc.lightened(0.3), art), 2)
		var rng := float(a.get("land_m", ai.range_set))
		var l1 := "MENZİL %d m   ·   AÇI %d°   ·   UÇUŞ %s sn" % [int(round(rng)), int(round(float(a.get("elev", 0.0)))),
				("%.1f" % float(a.get("time", 0.0))).replace(".", ",") if a.has("time") else "—"]
		UI.draw_text(_top, _font_n, Vector2(x, r.position.y + 42.0 * k), l1, UI.fs(15, k), Color(UI.TEXT, art), 2)
		var l2 := ""
		var c2: Color = UI.DIM
		if not ai.locked.is_empty():
			match str(ai.lock_status):
				"hit", "near", "":
					l2 = "HEDEF KİLİTLİ · %d m  ·  %s" % [int(ai.locked.get("dist", rng)), str(ai.locked.get("label", ""))]
					c2 = UI.GOOD
				"blocked":
					l2 = "ENGEL — mermi hedeften önce düşüyor"
					c2 = UI.BAD
				"reach":
					l2 = "MENZİL DIŞI — hedef çok uzak"
					c2 = UI.BAD
			if absf(float(ai.off_angle)) > MortarAim.LOCK_CONE:
				var left := float(ai.off_angle) > 0.0
				var deg := int(round(rad_to_deg(absf(float(ai.off_angle)))))
				var tx := ("«  HEDEFE DÖN  %d°" if left else "HEDEFE DÖN  %d°  »") % deg
				var blink := 0.6 + 0.4 * sin(_t * 8.0)
				UI.draw_text_c(_top, UI.font_caps(800, 2), c + Vector2(0, -60.0 * k), tx, UI.fs(16, k), Color(UI.WARN, blink * art), 3)
		elif not a.is_empty() and not bool(a.get("ok", true)):
			l2 = "Menzil dışı — teker ile kısalt"
			c2 = UI.BAD
		else:
			var n: int = ai.candidates().size()
			l2 = "%d işaretli hedef — T ile kilitlen" % n if n > 0 else "İşaretli hedef yok — Q tarayıcı · İnşa Aracı işareti"
		UI.draw_text(_top, _font_b, Vector2(x, r.position.y + 62.0 * k), l2, UI.fs(12, k), Color(c2, art), 2)
		UI.draw_text(_top, _font, Vector2(x, r.end.y - 6.0 * k), "Teker: menzil  ·  T: hedef  ·  Sol tık: ateş", UI.fs(10, k),
				Color(UI.FAINT, 0.9 * art), 2)

	static func _up_at(p: Vector3) -> Vector3:
		var b := Game.body_at(p)
		var u := p - (b.global_position if b != null else Game.planet_center())
		return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP
