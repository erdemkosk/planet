extends "res://scripts/items/weapon_base.gd"
## Altıpatlar (item id "revolver"; a sidearm, loadout slot B: Balance.LOADOUT_B). A heavy six-shot
## double-action magnum: big damage, slow fire, a hard kick with roll.
##   Fire      one round per click up to Balance.REVOLVER_RATE /s, REVOLVER_DAMAGE up to
##             REVOLVER_FALLOFF_START m, falling (smoothstep) to × REVOLVER_FALLOFF_MIN at
##             REVOLVER_FALLOFF_END. Head × REVOLVER_HEAD_MULT: a head shot kills at close range.
##             The hammer falls on the shot, then cocks again as the cylinder turns to the next chamber.
##   Reload    round by round (reload_kind "shell"): the left hand swings the cylinder out and the
##             ejector throws the empties (shell_start), thumbs a cartridge into each chamber
##             (shell_each, the cylinder turned one chamber each), swings it shut (shell_end). Firing
##             during the reload stops it after the round in hand.
##   Hold      one-handed like the Tabanca (pistol.gd ONE_HAND): the left hand rests out of view and
##             comes in for the reload, the inspect (Y: it checks the cylinder) and an attachment fit.
##   Sound     the dense 7.62 report (weap/ar_heavy) a touch higher with the chest body and the sub
##             punch, the rolling outdoor tail; the hammer cocking and the cylinder's click.
## Attachments (scripts/items/attachments.gd): optic only (Refleks on the top strap); a revolver's
## cylinder gap leaks gas, so no muzzle device.

const Balance := preload("res://scripts/war/balance.gd")

const WEIGHT := 1.05
const BORE_Y := 0.046
const SIGHT_Y := 0.0705
const REAR_Z := -0.004
const FRONT_Z := -0.157
const GRIP_RAKE := -0.35
const CYL_Y := BORE_Y - 0.0125           # the cylinder's axis (the top chamber on the bore)
const CYL_Z := -0.033
const CYL_R := 0.0195
const CHAMBER_R := 0.0125                # chambers on this circle
const CRANE_P := Vector3(-0.012, 0.01, CYL_Z)   # the crane's hinge (parallel to the bore, low left)
const SWING := 1.45                      # rad the cylinder swings out to the left
const POUCH := Vector3(-0.2, -0.36, -0.3)       # camera space: where the left hand takes a cartridge
const LEFT_REST := Vector3(-0.34, -0.43, -0.48)
const LEFT_REST_ELBOW := Vector3(-0.5, -0.45, 0.74)
const ONE_HAND := true
const COCK_DELAY := 0.16                 # s after a shot before the hammer cocks again...
const COCK_TIME := 0.16                  # ...over this long (the cylinder turns with it)

var panel_name := "Altıpatlar"
var handling_len := 0.55
var grip_right := {"at": Vector3(0.0, -0.00423, 0.00154), "axis": Vector3(0.0, 0.93937, -0.3429),
		"palm": Vector3(0.866, 0.1715, 0.4697), "r": 0.025, "trig_y": -0.009,
		"trig_c": Vector3(0.0, -0.009, -0.04), "trig_hd": 0.0035, "trig_hh": 0.0105}

var _crane: Node3D
var _cyl: Node3D
var _star: Node3D                         # the ejector star with the cartridge rims
var _rims: Array = []
var _hammer: Node3D
var _load_pt: Node3D
var _swing_pt: Node3D
var _hand_round: Node3D
var _cock_t := 9.0                        # s since the hammer fell
var _cyl_idx := 0                         # chambers turned (cylinder angle = idx × 60°)
var _cyl_ang := 0.0
var _ejected := false


func _init() -> void:
	item_id = "revolver"
	item_name = "Altıpatlar"
	item_desc = "Sol tık: ateş · Sağ tık: nişan · R: fişek fişek doldur (ateş edince durur). Ağır, yavaş, öldürücü."
	icon = "revolver"
	slot_key = 0
	short_name = "Altıpatlar"
	accent = Color(1.0, 0.56, 0.26)
	ammo_id = "ammo_magnum"
	ammo_title = ".44 MAGNUM · ALTIPATLAR"
	base_mag = Balance.REVOLVER_MAG
	reload_kind = "shell"
	shell_start = Balance.REVOLVER_SHELL_START
	shell_each = Balance.REVOLVER_SHELL_EACH
	shell_end = Balance.REVOLVER_SHELL_END
	shell_end_empty = Balance.REVOLVER_SHELL_END
	auto_fire = false
	fire_rate = Balance.REVOLVER_RATE
	ads_fov = 64.0
	sight_rear = Vector3(0.0, SIGHT_Y, REAR_Z)
	optic_y = SIGHT_Y + 0.03
	ads_eye = Vector3(0.0, 0.0, -0.31)
	hip_pos = Vector3(0.12, -0.175, -0.33)
	hip_bore_y = BORE_Y
	hip_converge = 8.0
	hip_cant = 0.05
	sprint_pos = Vector3(0.1, -0.25, -0.27)
	sprint_rot = Vector3(-0.85, 0.3, 0.25)
	reload_pos = Vector3(0.05, -0.12, -0.3)
	reload_rot = Vector3(0.75, 0.3, 0.55)        # muzzle up, cylinder toward the off hand
	recoil_pivot = Vector3(0.0, -0.06, 0.07)
	aim_speed = 0.85
	sprint_to_fire = 0.14
	spread_hip = 0.024
	spread_ads = 0.003
	bloom_add = 0.012
	bloom_max = 0.03
	first_shot_k = 0.35
	first_shot_rest = 0.45
	# A heavy single kick: a big flip with roll about the wrist, most of it back on its own.
	kick_pitch = 0.08
	kick_yaw = 0.02
	kick_roll = 0.035
	gun_kick = 13.0
	recoil_view = 0.5
	recoil_first = 1.0
	recoil_climb = 0.0
	recoil_h = PackedFloat32Array([0.4, -0.3, 0.5, -0.45, 0.35, -0.25])
	recoil_hold = 0.07
	recoil_recover = 0.85
	shake_amt = 0.7
	fov_punch_amt = -4.0
	noise_radius = 65.0
	crosshair_style = "circle"
	hit_big = 0.45
	hit_punch = 1.5
	armor_pierce = 0.25
	muzzle_energy = 14.0
	punch_db = -3.0
	head_mult = Balance.REVOLVER_HEAD_MULT
	kill_launch = 6.5
	ads_k = 150.0
	ads_c = 17.0
	impact_cal = 1.3
	flash_long = 0.8
	tail_db = -9.0
	draw_time = 0.38
	holster_time = 0.25


func reload_label() -> String:
	return "DOLDURULUYOR"


func _hip_sway() -> float:
	return 1.25


## The inspect (Y) checks the cylinder.
func _inspect_point() -> Vector3:
	return Vector3(-0.03, CYL_Y - 0.005, CYL_Z)


# =================================================================================================
# Firing
# =================================================================================================

func fire() -> void:
	super.fire()
	_cock_t = 0.0


func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var dir := _spread_dir(fwd, cb, current_spread())
	fx.bullet(eye, dir * Balance.REVOLVER_SPEED * randf_range(0.98, 1.02) * att_kit.stat("velocity") + player.velocity,
			muzzle, 0, Color(1.0, 0.7, 0.36), false, 0, 1.2)


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(randf_range(1.15, 1.4))
	fx.muzzle_light(muzzle + fwd * 0.6, Color(1.0, 0.68, 0.34), muzzle_energy, 0.06, 15.0)
	fx.muzzle_smoke(muzzle + fwd * 0.12, fwd, up, 1.3)
	# Gas out of the cylinder gap: a little puff at each side.
	if _cyl != null and player != null:
		var gap := _vm_world(_crane) + up * 0.02 - fwd * 0.02
		fx.muzzle_smoke(gap + cb.x * 0.02, up, cb.x, 0.5)
		fx.muzzle_smoke(gap - cb.x * 0.02, up, -cb.x, 0.5)
	ScreenPunch.kick(0.35 * (1.0 - clampf(ads, 0.0, 1.0) * 0.4))


func _hit_damage(p: Vector3, _ammo: int) -> float:
	var d := 0.0
	if player != null:
		d = (player.global_position as Vector3).distance_to(p) / att_kit.stat("range")
	var k := 1.0 - (1.0 - Balance.REVOLVER_FALLOFF_MIN) * smoothstep(Balance.REVOLVER_FALLOFF_START, Balance.REVOLVER_FALLOFF_END, d)
	return Balance.REVOLVER_DAMAGE * k


func _hit_impulse(_ammo: int) -> float:
	return 9.0


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		_play("boom_body", -6.0, randf_range(1.1, 1.2), true)
		_play("thump", -7.0, 0.9, true)
		_shot_body(space, 0.95, -80.0)
		return
	# The magnum: the dense heavy report a little higher and shorter than the sniper's, the chest
	# body under it, the sub punch, the slap-back and the rolling tail (_shot_body).
	_play("heavy", -1.0, randf_range(1.02, 1.1), true, 0.34)
	_play("boom_body", -9.0, randf_range(1.2, 1.3), true)
	_play("thump", -7.0, randf_range(0.9, 0.98), true)
	_shot_body(space, 0.95, -11.0)
	if space == 1:
		_play("tail", -18.0, 1.2, true, 0.3)


# =================================================================================================
# Hammer, cylinder, the shell reload
# =================================================================================================

func _tick(delta: float, _on: bool) -> void:
	var was := _cock_t
	_cock_t += delta
	if was < COCK_DELAY + COCK_TIME * 0.6 and _cock_t >= COCK_DELAY + COCK_TIME * 0.6:
		_cyl_idx += 1                             # the hand turns the next chamber under the hammer
		_play("cyl_click", -16.0, randf_range(1.15, 1.25))


func _on_reload_start() -> void:
	_ejected = false
	_ensure_hand_round()


func _shell_events(phase: int, u: float) -> void:
	match phase:
		0:
			if _shell_ev == 0 and u > 0.08:
				_play("cloth", -16.0, randf_range(1.0, 1.1))
				_shell_ev = 1
			elif _shell_ev == 1 and u > 0.32:
				_play("cyl_click", -9.0, 0.8)             # the latch, the cylinder swings out
				_rk_vel += Vector4(0.2, 0.0, -0.3, 0.0)
				_shell_ev = 2
			elif _shell_ev == 2 and u > 0.66:
				_eject_empties()
				_shell_ev = 3
		1:
			if _shell_ev == 0 and u > 0.62:
				_play("shell_in", -8.0, randf_range(1.5, 1.65))
				_rk_vel += Vector4(0.12, 0.0, 0.05, 0.03)
				_shell_ev = 1
			elif _shell_ev == 1 and u > 0.8:
				_cyl_idx += 1                         # thumbed round to the next empty chamber
				_shell_ev = 2
		2:
			if _shell_ev == 0 and u > 0.6:
				_play("cyl_click", -4.0, 0.92)            # swung shut
				_play("bolt_fwd", -14.0, 1.6)
				_rk_vel += Vector4(0.45, 0.0, 0.35, 0.1)
				_shell_ev = 1


## The ejector throws the spent cases (the empty chambers) out of the open cylinder.
func _eject_empties() -> void:
	_ejected = true
	var n := mag_capacity() - mag
	for i in mini(n, 3):
		_play("tink", -18.0 - i * 2.0, randf_range(1.6, 2.0))
	if player == null or _star == null:
		return
	var cb: Basis = player.camera.global_transform.basis
	var up: Vector3 = player.global_transform.basis.y
	var p := _vm_world(_star)
	for i in n:
		fx.shell(p + cb.x * randf_range(-0.01, 0.01), -up * randf_range(0.6, 1.4) + cb.x * randf_range(-0.5, 0.3)
				+ cb.z * randf_range(0.3, 0.9) + player.velocity, false, false, true)


func _ensure_hand_round() -> void:
	if _hand_round != null or player == null or player.viewmodel == null:
		return
	var lh: Node3D = player.viewmodel.left_hand
	_hand_round = VM.node(lh, Vector3(-0.004, 0.012, -0.006), Basis(Vector3.RIGHT, -0.4))
	VM.seg(_hand_round, Vector3(0, -0.012, 0), Vector3(0, 0.02, 0), 0.0058, 0.0058, VM.mat(Color(0.82, 0.63, 0.3), 0.28, 0.9))
	VM.seg(_hand_round, Vector3(0, 0.02, 0), Vector3(0, 0.027, 0), 0.0058, 0.0035, VM.mat(Color(0.55, 0.42, 0.3), 0.35, 0.7))
	VM.seg(_hand_round, Vector3(0, -0.0135, 0), Vector3(0, -0.012, 0), 0.0068, 0.0068, VM.mat(Color(0.82, 0.63, 0.3), 0.28, 0.9))
	_hand_round.visible = false


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _cyl == null:
		return
	# Hammer: down on the shot, cocked again a moment later (the cylinder turns with it).
	var cock := _seg(_cock_t, COCK_DELAY, COCK_DELAY + COCK_TIME) if _cock_t < COCK_DELAY + COCK_TIME else 1.0
	_hammer.rotation.x = 0.62 * cock
	var swing := 0.0
	var star := 0.0
	var round_vis := false
	var shown := mag
	var w := 0.0
	var tgt := POUCH
	var elbow := Vector3(-0.3, -0.85, 0.42)
	if reloading and player != null:
		var cam_inv: Transform3D = player.camera.global_transform.affine_inverse()
		var side_c: Vector3 = cam_inv * _swing_pt.global_position + Vector3(-0.03, -0.08, 0.05)
		var load_c: Vector3 = cam_inv * _load_pt.global_position + Vector3(-0.035, -0.085, 0.05)
		match _shell_phase:
			0:
				var k0 := clampf(_shell_t / shell_start, 0.0, 1.0)
				swing = SWING * _seg(k0, 0.22, 0.5)
				star = _seg(k0, 0.6, 0.68) * (1.0 - _seg(k0, 0.76, 0.88))
				w = _seg(k0, 0.0, 0.25)
				tgt = side_c if k0 < 0.78 else side_c.lerp(POUCH, _seg(k0, 0.78, 1.0))
				if _ejected:
					shown = mag
			1:
				var k1 := clampf(_shell_t / _shell_each(), 0.0, 1.0)
				swing = SWING
				w = 1.0
				if k1 < 0.25:
					tgt = POUCH
				elif k1 < 0.62:
					tgt = POUCH.lerp(load_c, _seg(k1, 0.25, 0.62))
				elif k1 < 0.74:
					tgt = load_c + Vector3(0.0, 0.0, -0.012 * _seg(k1, 0.62, 0.72))
				else:
					tgt = load_c.lerp(POUCH, _seg(k1, 0.76, 1.0))
				round_vis = k1 > 0.12 and k1 < 0.64
				shown = mag + (1 if k1 >= 0.64 else 0)
			2:
				var k2 := clampf(_shell_t / _shell_end_time(), 0.0, 1.0)
				swing = SWING * (1.0 - _seg(k2, 0.4, 0.62))
				w = 1.0 - _seg(k2, 0.68, 1.0)
				tgt = POUCH.lerp(side_c, _seg(k2, 0.0, 0.4))
	if not reloading or _shell_phase == 0 and not _ejected:
		shown = mag_capacity()                      # (spent cases stay in their chambers until ejected)
	left_reach = tgt
	left_reach_w = w
	left_reach_elbow = elbow
	if _hand_round != null:
		_hand_round.visible = round_vis
	_crane.rotation.z = swing
	_star.position = Vector3(0.0, 0.0, 0.017 * star)
	for i in _rims.size():
		(_rims[i] as Node3D).visible = i < shown
	var want := float(_cyl_idx) * TAU / 6.0
	_cyl_ang = lerpf(_cyl_ang, want, 1.0 - exp(-30.0 * delta))
	_cyl.rotation.z = -_cyl_ang


## One-handed: every reach blends from the out-of-view rest (pistol.gd _process).
func _process(delta: float) -> void:
	super._process(delta)
	if ONE_HAND:
		var w := clampf(left_reach_w, 0.0, 1.0)
		left_reach = LEFT_REST.lerp(left_reach, w) if w > 0.0 else LEFT_REST
		left_reach_elbow = LEFT_REST_ELBOW.lerp(left_reach_elbow, w) if w > 0.0 else LEFT_REST_ELBOW
		left_reach_w = 1.0


# =================================================================================================
# Model
# =================================================================================================

## First-person model: a heavy double-action magnum. A gunmetal frame (recoil shield, top strap with
## a notch rear sight, the cylinder latch on the left, side-plate screws, an orange pinstripe), a
## six-shot fluted cylinder on a crane that swings out to the left (ejector rod under it, an ejector
## star with the cartridge rims), a full-lug barrel with a vented top rib, white lug panels over a
## glow strip, a ramp front sight with an orange insert and a tritium dot, a crowned muzzle; a
## spurred hammer, a smooth wide trigger in a round guard, a raked rubber grip with finger grooves,
## stippled panels and an orange inlay.
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var gm := VM.mat(Color(0.33, 0.335, 0.345), 0.38, 0.72)
	var gm2 := VM.mat(Color(0.25, 0.255, 0.265), 0.46, 0.65)
	var inset := VM.mat(Color(0.15, 0.155, 0.16), 0.66, 0.45)
	var steel := VM.mat(Color(0.48, 0.49, 0.51), 0.26, 0.9)
	var rubber := VM.mat(Color(0.1, 0.098, 0.096), 0.9, 0.0)
	var stip := VM.mat(Color(0.075, 0.074, 0.072), 0.97, 0.0)
	var black := VM.mat(Color(0.05, 0.05, 0.055), 0.6, 0.2)
	var brass := VM.mat(Color(0.8, 0.62, 0.3), 0.28, 0.9)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var by := BORE_Y
	var rake := Basis(Vector3.RIGHT, GRIP_RAKE)
	# --- Frame ---
	VM.soft_box(_gun, Vector3(0, 0.033, 0.0025), Vector3(0.03, 0.058, 0.019), 0.004, gm)        # recoil shield / rear
	VM.box(_gun, Vector3(0, 0.0612, -0.03), Vector3(0.024, 0.0068, 0.06), gm)                    # top strap
	VM.box(_gun, Vector3(0, 0.0085, -0.03), Vector3(0.026, 0.009, 0.064), gm)                    # under the cylinder
	VM.soft_box(_gun, Vector3(0, 0.036, -0.0625), Vector3(0.028, 0.056, 0.012), 0.004, gm)      # frame front
	VM.box(_gun, Vector3(0, 0.012, 0.018), Vector3(0.024, 0.03, 0.014), gm2)                     # grip frame tang
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0122 * sx, 0.0605, -0.03), Vector3(0.0008, 0.002, 0.05), orange)
		VM.box(_gun, Vector3(0.0151 * sx, 0.024, 0.002), Vector3(0.001, 0.026, 0.012), inset)    # side plate seam
	for p in [Vector3(0.0153, 0.04, 0.0), Vector3(0.0153, 0.012, 0.006), Vector3(0.0142, 0.0085, -0.05)]:
		VM.seg(_gun, p, p + Vector3(0.0012, 0, 0), 0.0022, 0.0022, steel, 10)                   # screws (right)
	VM.box(_gun, Vector3(-0.0158, 0.04, 0.003), Vector3(0.0032, 0.0065, 0.013), steel)           # cylinder latch
	for k in 3:
		VM.box(_gun, Vector3(-0.0176, 0.04, -0.002 + k * 0.004), Vector3(0.0006, 0.0055, 0.0012), inset)
	# Rear sight: a notch in the top strap.
	var irons := VM.node(_gun)
	VM.box(irons, Vector3(0, 0.0655, REAR_Z), Vector3(0.02, 0.0025, 0.009), black)
	for sx in [-1.0, 1.0]:
		VM.box(irons, Vector3(0.0055 * sx, 0.0675, REAR_Z), Vector3(0.007, 0.006, 0.008), black)
	# --- Barrel: full lug, vented rib, ramp front sight ---
	VM.seg(_gun, Vector3(0, by, -0.068), Vector3(0, by, -0.168), 0.0088, 0.0088, gm, 20)
	VM.soft_box(_gun, Vector3(0, by - 0.0135, -0.115), Vector3(0.018, 0.019, 0.094), 0.004, gm)
	VM.box(_gun, Vector3(0, by + 0.0102, -0.116), Vector3(0.012, 0.004, 0.096), gm2)
	for k in 7:
		VM.box(_gun, Vector3(0, by + 0.0123, -0.076 - k * 0.012), Vector3(0.0125, 0.0008, 0.005), black)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0092 * sx, by - 0.012, -0.12), Vector3(0.0012, 0.011, 0.062), white)
		VM.box(_gun, Vector3(0.0093 * sx, by - 0.0205, -0.115), Vector3(0.0009, 0.0016, 0.08), VM.glow(accent, 2.0))
	VM.ring(_gun, Vector3(0, by, -0.1685), Vector3.FORWARD, 0.0089, 0.0028, steel)               # crown
	VM.seg(_gun, Vector3(0, by, -0.1682), Vector3(0, by, -0.1688), 0.0055, 0.0055, black, 12)
	var fh := SIGHT_Y - (by + 0.0122)
	VM.box(irons, Vector3(0, by + 0.0122 + fh * 0.5, FRONT_Z), Vector3(0.003, fh, 0.011), black, Basis(Vector3.RIGHT, 0.0))
	VM.box(irons, Vector3(0, by + 0.0122 + fh * 0.62, FRONT_Z + 0.0002), Vector3(0.0034, fh * 0.45, 0.004), orange)
	var fd := VM.sphere(irons, Vector3(0, SIGHT_Y - 0.0016, FRONT_Z + 0.0045), 0.0011, VM.glow(Color(0.45, 1.0, 0.55), 5.0))
	fd.set_meta("no_bake", true)
	_muzzle = VM.node(_gun, Vector3(0, by, -0.172))
	# --- Hammer (pivot behind the recoil shield) ---
	_hammer = VM.node(_gun, Vector3(0, 0.034, 0.014))
	VM.box(_hammer, Vector3(0, 0.012, 0.002), Vector3(0.0068, 0.026, 0.008), steel)
	VM.box(_hammer, Vector3(0, 0.0255, 0.0085), Vector3(0.0085, 0.005, 0.014), gm2, Basis(Vector3.RIGHT, -0.25))
	for k in 3:
		VM.box(_hammer, Vector3(0, 0.0282, 0.004 + k * 0.004), Vector3(0.0088, 0.0007, 0.001), black, Basis(Vector3.RIGHT, -0.25))
	# --- Trigger guard (a round bar loop, open to the frame and the grip), trigger ---
	var guard := [Vector3(0, 0.006, -0.066), Vector3(0, -0.012, -0.067), Vector3(0, -0.026, -0.058),
			Vector3(0, -0.0305, -0.042), Vector3(0, -0.028, -0.022), Vector3(0, -0.023, -0.009)]
	for k in guard.size() - 1:
		VM.capsule(_gun, guard[k], guard[k + 1], 0.0024, gm, 10)
	VM.box(_gun, Vector3(0, -0.009, -0.04), Vector3(0.0075, 0.02, 0.006), steel, Basis(Vector3.RIGHT, 0.25))
	# --- Grip: raked rubber, finger grooves, stippled panels, an orange inlay, the metal back strap ---
	VM.soft_box(_gun, rake * Vector3(0, -0.05, 0.004), Vector3(0.031, 0.1, 0.044), 0.009, rubber, rake)
	for k in 3:
		VM.capsule(_gun, rake * Vector3(-0.011, -0.032 - k * 0.021, -0.0195), rake * Vector3(0.011, -0.032 - k * 0.021, -0.0195),
				0.0055, rubber, 10)
	for sx in [-1.0, 1.0]:
		for row in 5:
			for col in 3:
				VM.box(_gun, rake * Vector3(0.0156 * sx, -0.045 - row * 0.011, -0.006 + col * 0.0115),
						Vector3(0.0012, 0.0075, 0.008), stip, rake)
		VM.box(_gun, rake * Vector3(0.0157 * sx, -0.024, 0.006), Vector3(0.0012, 0.014, 0.016), orange, rake)
	VM.box(_gun, rake * Vector3(0, -0.04, 0.0262), Vector3(0.011, 0.08, 0.003), gm2, rake)
	VM.capsule(_gun, rake * Vector3(-0.012, -0.099, 0.004), rake * Vector3(0.012, -0.099, 0.004), 0.008, rubber, 10)
	# --- Crane, cylinder, ejector ---
	_crane = VM.node(_gun, CRANE_P)
	var cc := Vector3(0, CYL_Y, CYL_Z) - CRANE_P                    # the cylinder's centre from the hinge
	VM.box(_crane, Vector3(cc.x * 0.5, cc.y * 0.5, -0.0225), Vector3(0.008, cc.length() + 0.006, 0.005), gm2,
			Basis(Vector3.BACK, atan2(-cc.x, cc.y)))                    # the yoke
	VM.seg(_crane, cc + Vector3(0, 0, -0.02), cc + Vector3(0, 0, -0.066), 0.0032, 0.0032, steel, 10)   # ejector rod
	VM.seg(_crane, cc + Vector3(0, 0, -0.066), cc + Vector3(0, 0, -0.07), 0.0042, 0.0042, inset, 10)
	_cyl = VM.node(_crane, cc)
	VM.seg(_cyl, Vector3(0, 0, 0.02), Vector3(0, 0, -0.02), CYL_R, CYL_R, gm, 30)
	VM.seg(_cyl, Vector3(0, 0, -0.02), Vector3(0, 0, -0.0215), CYL_R - 0.0015, CYL_R - 0.003, gm, 30)
	for i in 6:
		var a := TAU * float(i) / 6.0 + PI * 0.5
		var af := a + TAU / 12.0
		VM.box(_cyl, Vector3(cos(af), sin(af), 0.0) * (CYL_R - 0.0012), Vector3(0.0035, 0.0055, 0.025), inset,
				Basis(Vector3.BACK, af))                                 # flutes
		VM.seg(_cyl, Vector3(cos(a), sin(a), 0.0) * CHAMBER_R + Vector3(0, 0, -0.0213),
				Vector3(cos(a), sin(a), 0.0) * CHAMBER_R + Vector3(0, 0, -0.0218), 0.0048, 0.0048, black, 12)   # mouths
		VM.box(_cyl, Vector3(cos(a), sin(a), 0.0) * (CYL_R + 0.0002) + Vector3(0, 0, 0.012), Vector3(0.0015, 0.003, 0.004),
				black, Basis(Vector3.BACK, a))                           # bolt notches
	_star = VM.node(_cyl)
	VM.seg(_star, Vector3(0, 0, 0.0198), Vector3(0, 0, 0.0212), 0.0042, 0.0042, steel, 12)
	for i in 6:
		var a := TAU * float(i) / 6.0 + PI * 0.5
		var rim := VM.node(_star, Vector3(cos(a), sin(a), 0.0) * CHAMBER_R)
		VM.seg(rim, Vector3(0, 0, 0.0199), Vector3(0, 0, 0.0213), 0.0058, 0.0058, brass, 14)
		VM.seg(rim, Vector3(0, 0, 0.0212), Vector3(0, 0, 0.0215), 0.0018, 0.0018, steel, 8)        # primer
		_rims.append(rim)
	_load_pt = VM.node(_cyl, Vector3(0, -CHAMBER_R, 0.028))
	_swing_pt = VM.node(_crane, cc + Vector3(-0.022, -0.004, 0.0))
	_make_flash(_gun, Vector3(0, by, -0.176), 1.05)
	# Bakes: the frame; the moving parts each on their own.
	left_grip = VM.node(_gun, rake * Vector3(0, -0.13, 0.0))
	left_grip.name = "LeftGrip"
	VM.bake(_gun, [_crane, _hammer, irons, _flash_root, _muzzle, left_grip])
	VM.bake(irons)
	VM.bake(_hammer)
	VM.bake(_crane, [_cyl, _swing_pt])
	VM.bake(_cyl, [_star, _load_pt])
	VM.bake(_star, _rims)
	for r in _rims:
		VM.bake(r)
	# Attachment mount: a reflex on the top strap.
	att_kit.build(self, _gun, {
		"optic": {"y": 0.0646, "z": -0.032, "irons": SIGHT_Y, "default": irons},
	})
	return model


# =================================================================================================
# Third-person model
# =================================================================================================

func _build_tp(p: Node3D) -> Node3D:
	return build_tp_model(p)


static func build_tp_model(p: Node3D) -> Node3D:
	var gm := _mat3(Color(0.22, 0.225, 0.235), 0.42, 0.75)
	var rubber := _mat3(Color(0.07, 0.068, 0.066), 0.9, 0.0)
	var rake := Basis(Vector3.RIGHT, GRIP_RAKE)
	VM.box(p, Vector3(0, 0.036, -0.03), Vector3(0.03, 0.058, 0.075), gm)
	VM.seg(p, Vector3(0, CYL_Y, -0.013), Vector3(0, CYL_Y, -0.053), CYL_R, CYL_R, gm, 10)
	VM.seg(p, Vector3(0, BORE_Y, -0.068), Vector3(0, BORE_Y, -0.168), 0.0095, 0.0095, gm, 8)
	VM.box(p, Vector3(0, BORE_Y - 0.0135, -0.115), Vector3(0.018, 0.019, 0.094), gm)
	VM.box(p, rake * Vector3(0, -0.05, 0.004), Vector3(0.031, 0.1, 0.044), rubber, rake)
	return VM.node(p, Vector3(0, BORE_Y, -0.172))


static func _mat3(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m
