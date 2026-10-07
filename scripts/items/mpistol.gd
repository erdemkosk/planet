extends "res://scripts/items/weapon_base.gd"
## Makineli Tabanca (item id "mpistol"; a sidearm, loadout slot B: Balance.LOADOUT_B). A select-fire
## machine pistol: a hose up close, poor at range, a fierce muzzle climb.
##   Fire      Balance.MPISTOL_RATE rounds/s in SERİ, MPISTOL_DAMAGE up to MPISTOL_FALLOFF_START m,
##             falling (smoothstep) to × MPISTOL_FALLOFF_MIN at MPISTOL_FALLOFF_END. Spread blooms fast;
##             the kick climbs steeply over a string (recoil_climb) with a random chatter.
##   Mode      B: TEK (semi) ↔ SERİ (full auto); the HUD panel title shows it.
##   Handling  MPISTOL_MAG rounds in an extended magazine, R reloads in MPISTOL_RELOAD s (the left hand
##             leaves the fold-down front grip, swaps the magazine; empty: racks the slide overhand).
##             Fast draw / holster like every sidearm.
##   Hold      two-handed: the right hand on the raked grip, the left on the fold-down vertical front
##             grip under the dust cover (its hand frame is set on the LeftGrip node itself: the
##             attachment kit clears grip_left descriptors that are not a fitted Ön Tutamak).
##   Sound     the 5.56 recording pitched high and cut very short, a fast slide clatter.
## Attachments (scripts/items/attachments.gd): muzzle (Susturucu: replaces the ported compensator) and
## optic (Refleks on the slide).

const Balance := preload("res://scripts/war/balance.gd")
const VMHand := preload("res://scripts/player/vm_hand.gd")

const WEIGHT := 1.06
const BORE_Y := 0.03
const SIGHT_Y := 0.0525
const REAR_Z := 0.022
const FRONT_Z := -0.156
const GRIP_RAKE := -0.3
const SLIDE_TRAVEL := 0.03
const CYCLE_BACK := 0.016
const CYCLE_FWD := 0.03
const FRONT_GRIP := Vector3(0.0, -0.014, -0.112)        # top of the fold-down grip (gun frame)
## The left hand on the front grip (vm_hand.gd grip_left fields; applied to LeftGrip's transform).
const SUPPORT := {"at": Vector3(0.0, -0.0175, -0.1122), "axis": Vector3(0.0, 0.9986, 0.0535),
		"palm": Vector3(-0.984, 0.0, 0.173), "r": 0.0128}

enum { FIRE_SEMI, FIRE_AUTO, FIRE_BURST }
const FIRE_MODE_NAMES := ["TEK", "SERİ", "ÜÇLÜ"]

var fire_mode := FIRE_AUTO
var panel_name := "Makineli Tabanca · SERİ"
var handling_len := 0.55
var grip_right := {"at": Vector3(0.0, -0.00497, 0.00154), "axis": Vector3(0.0, 0.95534, -0.29552),
		"palm": Vector3(0.866, 0.1478, 0.4777), "r": 0.026, "trig_y": -0.0075,
		"trig_c": Vector3(0.0, -0.0075, -0.043), "trig_hd": 0.003, "trig_hh": 0.011}

var _slide: Node3D
var _mag: Node3D
var _mag_grab: Node3D
var _rack_pt: Node3D
var _selector: Node3D
var _round_i := 0
var _cyc := 9.0
var _locked := false


func _init() -> void:
	item_id = "mpistol"
	item_name = "Makineli Tabanca"
	item_desc = "Sol tık: ateş · B: tek ↔ seri · Sağ tık: nişan · R: şarjör. Yakında çok hızlı, uzakta zayıf."
	icon = "mpistol"
	slot_key = 0
	short_name = "Mak. Tabanca"
	accent = Color(1.0, 0.8, 0.36)
	ammo_id = "ammo_pistol"
	ammo_title = "9 MM · MAKİNELİ TABANCA"
	base_mag = Balance.MPISTOL_MAG
	reload_kind = "mag"
	reload_time = Balance.MPISTOL_RELOAD
	reload_empty_time = Balance.MPISTOL_RELOAD_EMPTY
	auto_fire = true
	fire_rate = Balance.MPISTOL_RATE
	ads_fov = 66.0
	sight_rear = Vector3(0.0, SIGHT_Y, REAR_Z)
	optic_y = SIGHT_Y + 0.03
	ads_eye = Vector3(0.0, 0.0, -0.28)
	hip_pos = Vector3(0.1, -0.17, -0.33)
	hip_bore_y = BORE_Y
	hip_converge = 8.0
	hip_cant = 0.07
	sprint_pos = Vector3(0.09, -0.23, -0.28)
	sprint_rot = Vector3(-0.7, 0.45, 0.35)
	reload_pos = Vector3(0.07, -0.15, -0.3)
	reload_rot = Vector3(0.3, 0.3, 0.5)
	recoil_pivot = Vector3(0.0, -0.05, 0.07)
	aim_speed = 0.95
	sprint_to_fire = 0.11
	spread_hip = 0.028
	spread_ads = 0.011
	bloom_add = 0.005
	bloom_max = 0.055
	first_shot_k = 0.5
	# Fierce climb: a modest first round, then each round of a string kicks harder (recoil_climb,
	# capped at the 6th), most of it climbing the view; a random chatter on top.
	kick_pitch = 0.014
	kick_yaw = 0.011
	kick_roll = 0.006
	gun_kick = 3.4
	recoil_view = 0.8
	recoil_first = 1.1
	recoil_climb = 1.0
	recoil_jitter = 0.004
	recoil_h = PackedFloat32Array([0.5, -0.6, 0.7, -0.4, 0.8, -0.7, 0.3, -0.5])
	recoil_hold = 0.04
	recoil_recover = 1.1
	shake_amt = 0.08
	fov_punch_amt = -0.4
	noise_radius = 40.0
	crosshair_style = "ticks"
	hit_big = 0.14
	hit_punch = 0.5
	armor_pierce = 0.04
	muzzle_energy = 6.0
	punch_db = -10.0
	head_mult = Balance.MPISTOL_HEAD_MULT
	kill_launch = 3.0
	ads_k = 170.0
	ads_c = 18.0
	impact_cal = 0.6
	flash_long = 0.55
	tail_db = -18.0
	draw_time = 0.33
	holster_time = 0.24


func mode_text() -> String:
	return FIRE_MODE_NAMES[effective_fire_mode()]


func mode_available(m: int) -> bool:
	return m == FIRE_SEMI or m == FIRE_AUTO


func effective_fire_mode() -> int:
	return fire_mode if mode_available(fire_mode) else FIRE_SEMI


func reload_label() -> String:
	return "ŞARJÖR DEĞİŞİYOR"


func _hip_sway() -> float:
	return 1.25


func save_state() -> Dictionary:
	var d := super.save_state()
	d["fire_mode"] = fire_mode
	return d


func load_state(d: Dictionary) -> void:
	super.load_state(d)
	fire_mode = clampi(int(d.get("fire_mode", fire_mode)), FIRE_SEMI, FIRE_BURST)
	if not mode_available(fire_mode):
		fire_mode = FIRE_AUTO
	auto_fire = fire_mode == FIRE_AUTO
	_locked = mag <= 0
	_update_panel()


## B (weapon_base.gd): TEK ↔ SERİ.
func toggle_mode() -> void:
	set_fire_mode(FIRE_SEMI if effective_fire_mode() == FIRE_AUTO else FIRE_AUTO)


func set_fire_mode(m: int) -> void:
	fire_mode = m if mode_available(m) else FIRE_SEMI
	auto_fire = fire_mode == FIRE_AUTO
	if Game.sfx:
		Game.sfx.play("click", -8.0, 1.15 if auto_fire else 1.0)
	_play("selector", -10.0, 1.35 if auto_fire else 1.15)
	_rk_vel += Vector4(0.0, 0.0, 0.15, 0.0)
	if hud != null and hud.has_method("mode_switched"):
		hud.mode_switched()
	_update_panel()
	if Game.hud:
		Game.hud.show_message("Atış modu: %s" % mode_text(), 1.0)


func _update_panel() -> void:
	panel_name = "Makineli Tabanca · " + mode_text()


# =================================================================================================
# Firing
# =================================================================================================

func fire() -> void:
	super.fire()
	_cyc = 0.0
	_locked = mag <= 0


func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var dir := _spread_dir(fwd, cb, current_spread())
	_round_i += 1
	var tracer := _round_i % 4 == 0
	fx.bullet(eye, dir * Balance.MPISTOL_SPEED * randf_range(0.98, 1.02) * att_kit.stat("velocity") + player.velocity,
			muzzle, 0, Color(1.0, 0.8, 0.45), false, 0, 0.6 if tracer else 0.02)


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(randf_range(0.7, 0.95))
	fx.muzzle_light(muzzle + fwd * 0.4, Color(1.0, 0.72, 0.38), muzzle_energy, 0.03, 10.0)
	if _round_i % 4 == 0:
		fx.muzzle_smoke(muzzle + fwd * 0.08, fwd, up, 0.5)
	if _eject != null:
		fx.shell(_vm_world(_eject), cb.x * randf_range(1.5, 2.4) + up * randf_range(1.3, 2.1) + fwd * 0.2 + player.velocity,
				false, false, true)


func _hit_damage(p: Vector3, _ammo: int) -> float:
	var d := 0.0
	if player != null:
		d = (player.global_position as Vector3).distance_to(p) / att_kit.stat("range")
	var k := 1.0 - (1.0 - Balance.MPISTOL_FALLOFF_MIN) * smoothstep(Balance.MPISTOL_FALLOFF_START, Balance.MPISTOL_FALLOFF_END, d)
	return Balance.MPISTOL_DAMAGE * k


func _hit_impulse(_ammo: int) -> float:
	return 1.8


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		_play("thump", -11.0, randf_range(1.45, 1.6), true)
		_shot_body(space, 1.5, -80.0)
		return
	_play("shot", -5.0, randf_range(1.5, 1.62), true, 0.075)
	_play("action", -14.0, randf_range(2.2, 2.45), true, 0.05)
	if _round_i % 3 == 0:
		_play("tink", -27.0, randf_range(1.8, 2.2))
	_shot_body(space, 1.5, -19.0)


# =================================================================================================
# Reload, slide, the support hand
# =================================================================================================

func _reload_events(u: float) -> void:
	var marks := [0.04, 0.1, 0.16, 0.56, 0.62, 0.79, 0.85]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -17.0, randf_range(1.05, 1.2))
			1:
				_play("mag_release", -9.0, 1.35)
			2:
				_play("mag_out", -9.0, 1.3)
			3:
				_play("mag_in", -7.0, 1.3)
				_rk_vel.w += 0.15
			4:
				_play("mag_slap", -6.0, 1.35)
				_rk_vel.x += 0.45
			5:
				if _reload_empty:
					_play("bolt_back", -9.0, 1.5)
			6:
				if _reload_empty:
					_play("bolt_fwd", -6.0, 1.45)
					_rk_vel += Vector4(0.5, 0.0, 0.0, 0.2)
					_locked = false
		_reload_ev += 1


func _on_reload_done() -> void:
	_locked = false


func _tick(delta: float, _on: bool) -> void:
	_cyc += delta


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _mag == null:
		return
	var k := 0.0
	if _cyc < CYCLE_BACK:
		k = _cyc / CYCLE_BACK
	elif _cyc < CYCLE_BACK + CYCLE_FWD:
		k = 1.0 - _smooth((_cyc - CYCLE_BACK) / CYCLE_FWD)
	if _locked and _cyc >= CYCLE_BACK:
		k = 1.0
	var u := reload_progress() if reloading else 0.0
	var drop := 0.0
	var vis := true
	var slap := 0.0
	var w_mag := 0.0
	var w_rack := 0.0
	if reloading:
		w_mag = _seg(u, 0.03, 0.14) * (1.0 - _seg(u, 0.64, 0.72))
		if u < 0.32:
			drop = lerpf(0.0, 0.03, _seg(u, 0.1, 0.15)) + lerpf(0.0, 0.32, _seg(u, 0.15, 0.3))
		else:
			drop = lerpf(0.22, 0.012, _seg(u, 0.34, 0.54)) * (1.0 - _seg(u, 0.54, 0.58))
		vis = u < 0.29 or u > 0.33
		slap = sin(clampf((u - 0.6) / 0.05, 0.0, 1.0) * PI)
		if _reload_empty:
			w_rack = _seg(u, 0.67, 0.75) * (1.0 - _seg(u, 0.87, 0.96))
			var pull := _seg(u, 0.77, 0.83) * (1.0 - _seg(u, 0.84, 0.86))
			if u < 0.85:
				k = 1.0 + 0.1 * pull
			else:
				k = 1.0 - _smooth((u - 0.85) / 0.02)
	_slide.position = Vector3(0.0, 0.0, SLIDE_TRAVEL * k)
	_mag.position = Basis(Vector3.RIGHT, GRIP_RAKE) * Vector3(0.0, -drop, 0.0)
	var tumble := clampf((drop - 0.08) / 0.22, 0.0, 1.0) if u < 0.32 else 0.0
	_mag.rotation = Vector3(GRIP_RAKE + tumble * 0.6, 0.0, tumble * 0.4)
	_mag.visible = vis
	_selector.rotation.x = lerp_angle(_selector.rotation.x, 0.5 if auto_fire else -0.2, 1.0 - exp(-20.0 * delta))
	_gun.transform = Transform3D(Basis.from_euler(Vector3(slap * 0.035, 0.0, 0.0)), Vector3(0.0, slap * 0.005, 0.0))
	if player != null and (w_mag > 0.0 or w_rack > 0.0):
		var cam_inv: Transform3D = player.camera.global_transform.affine_inverse()
		if w_rack > w_mag:
			left_reach = cam_inv * _rack_pt.global_position + Vector3(-0.035, -0.035, 0.06)
			left_reach_w = w_rack
			left_reach_elbow = Vector3(-0.35, -0.75, 0.55)
		else:
			left_reach = cam_inv * _mag_grab.global_position + Vector3(0.0, 0.02 * slap, 0.0)
			left_reach_w = w_mag
			left_reach_elbow = Vector3(-0.3, -0.85, 0.45)
	else:
		left_reach_w = 0.0


# =================================================================================================
# Model
# =================================================================================================

## First-person model: a select-fire machine pistol on the Tabanca's layout. A longer gunmetal slide
## (serrations, a white side insert over a glow strip, the ejection port on the right, a selector
## lever at the rear left), a ported compensator past the slide (the gun's own muzzle: a fitted
## Susturucu replaces it), a polymer frame with a fold-down vertical front grip under the dust cover
## (the left hand's), a squared trigger guard, a raked stippled grip, an extended 20-round magazine
## with an orange base pad out of the grip.
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var gm := VM.mat(Color(0.29, 0.295, 0.305), 0.42, 0.65)
	var gm2 := VM.mat(Color(0.23, 0.235, 0.245), 0.5, 0.6)
	var inset := VM.mat(Color(0.15, 0.155, 0.16), 0.66, 0.45)
	var steel := VM.mat(Color(0.42, 0.43, 0.45), 0.3, 0.85)
	var poly := VM.mat(Color(0.13, 0.128, 0.125), 0.8, 0.04)
	var stip := VM.mat(Color(0.095, 0.094, 0.092), 0.95, 0.0)
	var black := VM.mat(Color(0.05, 0.05, 0.055), 0.6, 0.2)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var by := BORE_Y
	var rake := Basis(Vector3.RIGHT, GRIP_RAKE)
	# --- Frame ---
	VM.soft_box(_gun, Vector3(0, 0.011, -0.073), Vector3(0.027, 0.014, 0.17), 0.004, poly)
	VM.soft_box(_gun, Vector3(0, 0.006, 0.018), Vector3(0.026, 0.014, 0.03), 0.005, poly)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0137 * sx, 0.0115, -0.13), Vector3(0.0008, 0.0022, 0.04), orange)
	VM.box(_gun, Vector3(0, -0.031, -0.0455), Vector3(0.012, 0.005, 0.064), poly)
	VM.box(_gun, Vector3(0, -0.0135, -0.0775), Vector3(0.012, 0.036, 0.005), poly, Basis(Vector3.RIGHT, 0.08))
	VM.box(_gun, Vector3(0, -0.0075, -0.043), Vector3(0.006, 0.022, 0.006), steel, Basis(Vector3.RIGHT, 0.25))
	VM.box(_gun, Vector3(-0.0142, 0.0135, -0.04), Vector3(0.0022, 0.004, 0.02), gm2)
	VM.box(_gun, Vector3(-0.0142, -0.004, -0.0115), Vector3(0.0028, 0.007, 0.006), black)
	# Fold-down front grip: the hinge block under the dust cover and the ribbed grip.
	VM.box(_gun, Vector3(0, -0.0005, FRONT_GRIP.z), Vector3(0.018, 0.009, 0.02), gm2)
	VM.seg(_gun, Vector3(-0.0095, -0.002, FRONT_GRIP.z), Vector3(0.0095, -0.002, FRONT_GRIP.z), 0.0035, 0.0035, steel, 10)
	VM.capsule(_gun, FRONT_GRIP + Vector3(0, 0.002, 0), FRONT_GRIP + Vector3(0, -0.054, 0.003), 0.0125, poly, 14)
	for k in 4:
		VM.ring(_gun, FRONT_GRIP + Vector3(0, -0.012 - k * 0.011, 0.0007 + k * 0.0006), Vector3(0, 1, 0.054), 0.013, 0.0022, stip)
	VM.seg(_gun, FRONT_GRIP + Vector3(0, -0.058, 0.003), FRONT_GRIP + Vector3(0, -0.064, 0.0033), 0.0128, 0.011, orange, 14)
	# --- Grip ---
	VM.soft_box(_gun, rake * Vector3(0, -0.054, 0.0), Vector3(0.03, 0.104, 0.048), 0.008, poly, rake)
	for sx in [-1.0, 1.0]:
		for row in 6:
			for col in 3:
				VM.box(_gun, rake * Vector3(0.0151 * sx, -0.022 - row * 0.0125, -0.0135 + col * 0.0135),
						Vector3(0.0012, 0.0085, 0.0095), stip, rake)
	for k in 6:
		VM.box(_gun, rake * Vector3(0, -0.03 - k * 0.0115, 0.0242), Vector3(0.022, 0.0026, 0.0022), stip, rake)
	VM.box(_gun, rake * Vector3(0, -0.103, 0.0015), Vector3(0.0326, 0.006, 0.051), poly, rake)
	# --- Barrel crown and the ported compensator (the default muzzle part) ---
	VM.seg(_gun, Vector3(0, by, -0.158), Vector3(0, by, -0.1715), 0.0068, 0.0068, steel, 16)
	var comp := VM.node(_gun)
	VM.soft_box(comp, Vector3(0, by - 0.002, -0.186), Vector3(0.0235, 0.024, 0.028), 0.005, gm2)
	for k in 3:
		VM.box(comp, Vector3(0, by + 0.0102, -0.178 - k * 0.0075), Vector3(0.012, 0.0012, 0.0035), black)
	for sx in [-1.0, 1.0]:
		VM.box(comp, Vector3(0.0119 * sx, by, -0.188), Vector3(0.0012, 0.009, 0.014), black)
	VM.seg(comp, Vector3(0, by, -0.1995), Vector3(0, by, -0.2003), 0.0045, 0.0045, black, 12)
	VM.box(comp, Vector3(0, by - 0.0145, -0.186), Vector3(0.0238, 0.0025, 0.02), orange)
	_muzzle = VM.node(_gun, Vector3(0, by, -0.203))
	# --- Slide ---
	_slide = VM.node(_gun)
	VM.soft_box(_slide, Vector3(0, 0.031, -0.068), Vector3(0.0255, 0.03, 0.2), 0.0035, gm)
	VM.box(_slide, Vector3(0, 0.0462, -0.068), Vector3(0.0135, 0.0012, 0.16), inset)
	for sx in [-1.0, 1.0]:
		for k in 7:
			VM.box(_slide, Vector3(0.0129 * sx, 0.0315, 0.026 - k * 0.0045), Vector3(0.0012, 0.022, 0.0018), inset)
		VM.box(_slide, Vector3(0.0129 * sx, 0.0345, -0.1), Vector3(0.0013, 0.014, 0.06), white)
		for k in 3:
			VM.box(_slide, Vector3(0.013 * sx, 0.0345, -0.084 - k * 0.016), Vector3(0.0014, 0.008, 0.007), black)   # vent cuts
		VM.box(_slide, Vector3(0.0131 * sx, 0.0222, -0.08), Vector3(0.0009, 0.0018, 0.1), VM.glow(accent, 2.2))
	VM.box(_slide, Vector3(0.0124, 0.0405, -0.028), Vector3(0.0018, 0.0105, 0.032), black)
	VM.box(_slide, Vector3(0.0131, 0.0425, -0.0055), Vector3(0.0008, 0.003, 0.012), steel)
	VM.box(_slide, Vector3(0, 0.031, 0.0322), Vector3(0.021, 0.025, 0.0012), gm2)
	VM.box(_slide, Vector3(0, 0.03, 0.033), Vector3(0.008, 0.012, 0.001), orange)
	_selector = VM.node(_slide, Vector3(-0.0135, 0.026, 0.02))
	VM.seg(_selector, Vector3.ZERO, Vector3(-0.003, 0, 0), 0.004, 0.004, gm2, 10)
	VM.box(_selector, Vector3(-0.003, 0.0, -0.007), Vector3(0.0022, 0.004, 0.012), orange)
	_eject = VM.node(_slide, Vector3(0.016, 0.041, -0.028))
	_rack_pt = VM.node(_slide, Vector3(-0.006, 0.035, 0.012))
	var irons := VM.node(_slide)
	VM.box(irons, Vector3(0, 0.0475, REAR_Z), Vector3(0.021, 0.003, 0.0075), black)
	for sx in [-1.0, 1.0]:
		VM.box(irons, Vector3(0.0062 * sx, 0.0492, REAR_Z), Vector3(0.0085, 0.0066, 0.007), black)
		var rd := VM.sphere(irons, Vector3(0.0062 * sx, 0.0497, REAR_Z + 0.0036), 0.0011, VM.glow(Color(0.45, 1.0, 0.55), 4.0))
		rd.set_meta("no_bake", true)
	VM.box(irons, Vector3(0, 0.0475, FRONT_Z), Vector3(0.006, 0.003, 0.007), black)
	VM.box(irons, Vector3(0, 0.0492, FRONT_Z), Vector3(0.0032, 0.0066, 0.0055), black)
	var fd := VM.sphere(irons, Vector3(0, 0.0505, FRONT_Z + 0.0029), 0.0012, VM.glow(Color(0.45, 1.0, 0.55), 5.0))
	fd.set_meta("no_bake", true)
	# --- Extended magazine (20 rounds: it stands out of the grip) ---
	_mag = VM.node(_gun, Vector3.ZERO, rake)
	VM.box(_mag, Vector3(0, -0.075, 0.0), Vector3(0.0215, 0.14, 0.033), gm2)
	for sx in [-1.0, 1.0]:
		VM.box(_mag, Vector3(0.011 * sx, -0.128, 0.0), Vector3(0.0012, 0.03, 0.004), inset)
	VM.seg(_mag, Vector3(0, -0.0045, 0.006), Vector3(0, -0.0045, -0.012), 0.0045, 0.004, VM.mat(Color(0.78, 0.6, 0.3), 0.3, 0.9), 10)
	VM.box(_mag, Vector3(0, -0.149, 0.003), Vector3(0.028, 0.008, 0.044), orange)
	_mag_grab = VM.node(_mag, Vector3(-0.022, -0.135, 0.018))
	# The left hand's frame on the front grip (the descriptor applied here once: see the header).
	left_grip = VM.node(_gun)
	left_grip.name = "LeftGrip"
	var r := float(SUPPORT["r"])
	left_grip.transform = VMHand.frame_of(SUPPORT, -1.0) \
			* Transform3D(Basis(), VMHand.palm_offset(-1.0, r) - VMHand.palm_offset(-1.0, VMHand.R_DEFAULT))
	_make_flash(_gun, Vector3(0, by, -0.207), 0.6)
	VM.bake(_gun, [_slide, _mag, comp, _flash_root, _muzzle, left_grip])
	VM.bake(comp)
	VM.bake(_slide, [irons, _eject, _rack_pt, _selector])
	VM.bake(_selector)
	VM.bake(irons)
	VM.bake(_mag, [_mag_grab])
	att_kit.build(self, _gun, {
		"muzzle": {"at": Vector3(0, by, -0.1715), "r": 0.0068, "tip": -0.203, "sup_r": 0.0135, "sup_len": 0.13,
			"shift": [_muzzle, _flash_root], "default": comp},
		"optic": {"y": 0.0466, "z": 0.006, "irons": SIGHT_Y, "default": irons, "parent": _slide},
	})
	return model


# =================================================================================================
# Third-person model
# =================================================================================================

func _build_tp(p: Node3D) -> Node3D:
	return build_tp_model(p)


static func build_tp_model(p: Node3D) -> Node3D:
	var gm := _mat3(Color(0.2, 0.205, 0.215), 0.5, 0.7)
	var poly := _mat3(Color(0.08, 0.078, 0.075), 0.85, 0.05)
	var orange := _mat3(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var rake := Basis(Vector3.RIGHT, GRIP_RAKE)
	VM.box(p, Vector3(0, 0.031, -0.068), Vector3(0.026, 0.03, 0.2), gm)
	VM.box(p, Vector3(0, BORE_Y - 0.002, -0.186), Vector3(0.024, 0.024, 0.028), gm)
	VM.box(p, Vector3(0, 0.008, -0.073), Vector3(0.027, 0.02, 0.17), poly)
	VM.box(p, rake * Vector3(0, -0.054, 0.0), Vector3(0.03, 0.104, 0.048), poly, rake)
	VM.box(p, rake * Vector3(0, -0.14, 0.003), Vector3(0.022, 0.03, 0.034), gm, rake)
	VM.box(p, rake * Vector3(0, -0.153, 0.003), Vector3(0.028, 0.008, 0.044), orange, rake)
	VM.box(p, FRONT_GRIP + Vector3(0, -0.027, 0.0015), Vector3(0.024, 0.056, 0.024), poly)
	return VM.node(p, Vector3(0, BORE_Y, -0.203))


static func _mat3(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m
