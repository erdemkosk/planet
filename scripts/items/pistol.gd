extends "res://scripts/items/weapon_base.gd"
## Tabanca (item id "pistol"; the default sidearm, loadout slot B: Balance.LOADOUT_B). A striker-fired
## polymer-frame pistol: semi-automatic, accurate, quick to draw and to aim, a light crisp kick.
##   Fire      one round per click up to Balance.PISTOL_RATE /s, PISTOL_DAMAGE up to
##             PISTOL_FALLOFF_START m, falling (smoothstep) to × PISTOL_FALLOFF_MIN at PISTOL_FALLOFF_END:
##             a backup, weaker than the rifle at range. A tight first shot; the slide cycles on
##             every round and locks back on the last one.
##   Handling  magazine PISTOL_MAG through the grip, R reloads in PISTOL_RELOAD s (the left hand drops
##             the magazine and seats a new one; empty: the slide is locked back, the left hand racks
##             it overhand), PISTOL_RELOAD_EMPTY s. Draw / holster are the fastest of the guns
##             (draw_time / holster_time: switching to it beats reloading the primary).
##   Hold      one-handed (the right hand on the grip, the index on the trigger): the left hand rests
##             out of view and only comes in for the reload, the inspect (Y) and an attachment fit
##             (_process: their reach blends from that rest, not from a grip). The view model's
##             left-hand solve does not know the right glove, so a thumb-over-thumb hold would put the
##             left fingers through the right ones (see the report / ONE_HAND).
##   Sound     the recorded 5.56 report pitched up and cut short (a smaller, snappier crack), the
##             slide's clack, a light punch; in vacuum the suit-borne thump only.
## Attachments (scripts/items/attachments.gd): muzzle (Susturucu on the barrel crown) and optic
## (Refleks on the slide, riding with it like a pistol red dot).

const Balance := preload("res://scripts/war/balance.gd")

const WEIGHT := 1.08                     # mobility factor while held (item.gd carry_weight)
const BORE_Y := 0.03
const SIGHT_Y := 0.0525                  # tops of the rear notch and the front post
const REAR_Z := 0.022
const FRONT_Z := -0.146
const GRIP_RAKE := -0.3                  # rad: the grip's bottom leans back (~17°)
const SLIDE_TRAVEL := 0.03               # m the slide runs back on a shot
const CYCLE_BACK := 0.022                # s: slide back...
const CYCLE_FWD := 0.055                 # ...and home again
## The off hand at rest (camera space; viewmodel.gd LEFT_WRIST: one-handed items lower it out of view).
const LEFT_REST := Vector3(-0.34, -0.43, -0.48)
const LEFT_REST_ELBOW := Vector3(-0.5, -0.45, 0.74)
const ONE_HAND := true

var panel_name := "Tabanca"
var handling_len := 0.5                   # handling.gd: a short gun (wall pull-back)
## Right hand on the raked grip (scripts/player/vm_hand.gd grip_right): its axis, the palm toward the
## back-right, the trigger blade 4.3 cm ahead of the grip axis.
var grip_right := {"at": Vector3(0.0, -0.00497, 0.00154), "axis": Vector3(0.0, 0.95534, -0.29552),
		"palm": Vector3(0.866, 0.1478, 0.4777), "r": 0.026, "trig_y": -0.0075,
		"trig_c": Vector3(0.0, -0.0075, -0.043), "trig_hd": 0.003, "trig_hh": 0.011}

var _slide: Node3D
var _mag: Node3D
var _mag_grab: Node3D
var _rack_pt: Node3D
var _cyc := 9.0                           # s since the last shot (slide cycle)
var _slide_k := 0.0
var _locked := false                      # the slide held back on an empty magazine


func _init() -> void:
	item_id = "pistol"
	item_name = "Tabanca"
	item_desc = "Sol tık: ateş · Sağ tık: nişan · R: şarjör. Yedek silah: çok hızlı çekilir."
	icon = "pistol"
	slot_key = 0                         # the loadout decides its key
	short_name = "Tabanca"
	accent = Color(0.5, 0.86, 1.0)
	ammo_id = "ammo_pistol"
	ammo_title = "9 MM · TABANCA"
	base_mag = Balance.PISTOL_MAG
	reload_kind = "mag"
	reload_time = Balance.PISTOL_RELOAD
	reload_empty_time = Balance.PISTOL_RELOAD_EMPTY
	auto_fire = false
	fire_rate = Balance.PISTOL_RATE
	ads_fov = 66.0
	sight_rear = Vector3(0.0, SIGHT_Y, REAR_Z)
	optic_y = SIGHT_Y + 0.03
	ads_eye = Vector3(0.0, 0.0, -0.3)
	hip_pos = Vector3(0.12, -0.165, -0.34)
	hip_bore_y = BORE_Y
	hip_converge = 8.0
	hip_cant = 0.06
	sprint_pos = Vector3(0.1, -0.24, -0.27)
	sprint_rot = Vector3(-0.85, 0.3, 0.25)       # low ready: muzzle down, turned in
	reload_pos = Vector3(0.07, -0.15, -0.3)
	reload_rot = Vector3(0.32, 0.28, 0.5)        # tipped up and toward the off hand
	recoil_pivot = Vector3(0.0, -0.06, 0.07)     # the wrist: the muzzle flips about it
	aim_speed = 1.0
	sprint_to_fire = 0.1
	spread_hip = 0.017
	spread_ads = 0.0035
	bloom_add = 0.0045
	bloom_max = 0.022
	first_shot_k = 0.4
	first_shot_rest = 0.3
	# A light, crisp kick: a visible flip that snaps home fast, a little camera climb.
	kick_pitch = 0.024
	kick_yaw = 0.008
	kick_roll = 0.008
	gun_kick = 6.0
	recoil_view = 0.5
	recoil_first = 1.0
	recoil_climb = 0.1
	recoil_h = PackedFloat32Array([0.3, -0.25, 0.4, -0.35, 0.2, -0.3])
	recoil_hold = 0.03
	recoil_recover = 1.6
	shake_amt = 0.22
	fov_punch_amt = -1.2
	noise_radius = 40.0
	crosshair_style = "ticks"
	hit_big = 0.22
	hit_punch = 0.75
	armor_pierce = 0.08
	muzzle_energy = 6.5
	punch_db = -8.0
	head_mult = Balance.PISTOL_HEAD_MULT
	kill_launch = 3.5
	ads_k = 190.0
	ads_c = 19.0
	impact_cal = 0.65
	flash_long = 0.55
	tail_db = -18.0
	draw_time = 0.3
	holster_time = 0.22


func reload_label() -> String:
	return "ŞARJÖR DEĞİŞİYOR"


func _hip_sway() -> float:
	return 1.15


func load_state(d: Dictionary) -> void:
	super.load_state(d)
	_locked = mag <= 0


# =================================================================================================
# Firing
# =================================================================================================

func fire() -> void:
	super.fire()
	_cyc = 0.0
	_locked = mag <= 0


func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var dir := _spread_dir(fwd, cb, current_spread())
	fx.bullet(eye, dir * Balance.PISTOL_SPEED * randf_range(0.98, 1.02) * att_kit.stat("velocity") + player.velocity,
			muzzle, 0, Color(0.75, 0.92, 1.0), false, 0, 0.45)


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(randf_range(0.75, 0.95))
	fx.muzzle_light(muzzle + fwd * 0.4, Color(1.0, 0.72, 0.4), muzzle_energy, 0.035, 10.0)
	fx.muzzle_smoke(muzzle + fwd * 0.08, fwd, up, 0.5)
	if _eject != null:
		fx.shell(_vm_world(_eject), cb.x * randf_range(1.6, 2.4) + up * randf_range(1.4, 2.2) + fwd * 0.2 + player.velocity,
				false, false, true)


func _hit_damage(p: Vector3, _ammo: int) -> float:
	var d := 0.0
	if player != null:
		d = (player.global_position as Vector3).distance_to(p) / att_kit.stat("range")
	var k := 1.0 - (1.0 - Balance.PISTOL_FALLOFF_MIN) * smoothstep(Balance.PISTOL_FALLOFF_START, Balance.PISTOL_FALLOFF_END, d)
	return Balance.PISTOL_DAMAGE * k


func _hit_impulse(_ammo: int) -> float:
	return 3.0


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		_play("thump", -9.0, randf_range(1.35, 1.5), true)
		_shot_body(space, 1.45, -80.0)
		return
	# A smaller, snappier report than the rifle's: the 5.56 recording pitched up and cut short, the
	# slide's clack right on it, a light thump for the body.
	_play("shot", -3.0, randf_range(1.42, 1.55), true, 0.1)
	_play("thump", -13.0, randf_range(1.5, 1.65), true)
	_play("action", -13.0, randf_range(2.1, 2.35), true, 0.06)
	_shot_body(space, 1.45, -17.0)


# =================================================================================================
# Reload, slide and the off hand
# =================================================================================================

func _reload_events(u: float) -> void:
	var marks := [0.04, 0.1, 0.16, 0.58, 0.64, 0.79, 0.85]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -18.0, randf_range(1.05, 1.2))
			1:
				_play("mag_release", -10.0, 1.4)
			2:
				_play("mag_out", -10.0, 1.4)
			3:
				_play("mag_in", -7.0, 1.35)
				_rk_vel.w += 0.15
			4:
				_play("mag_slap", -7.0, 1.4)
				_rk_vel.x += 0.45
			5:
				if _reload_empty:
					_play("bolt_back", -10.0, 1.55)
			6:
				if _reload_empty:
					_play("bolt_fwd", -6.0, 1.5)
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
	# Slide: a shot's cycle; held back on an empty magazine until the reload racks it.
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
		# Out: the magazine falls free; in: the hand brings a new one up the grip and seats it.
		w_mag = _seg(u, 0.12, 0.3) * (1.0 - _seg(u, 0.66, 0.74))
		if u < 0.32:
			drop = lerpf(0.0, 0.03, _seg(u, 0.1, 0.15)) + lerpf(0.0, 0.3, _seg(u, 0.15, 0.3))
		else:
			drop = lerpf(0.2, 0.012, _seg(u, 0.34, 0.56)) * (1.0 - _seg(u, 0.56, 0.6))
		vis = u < 0.29 or u > 0.33
		slap = sin(clampf((u - 0.62) / 0.05, 0.0, 1.0) * PI)
		if _reload_empty:
			w_rack = _seg(u, 0.68, 0.76) * (1.0 - _seg(u, 0.87, 0.97))
			var pull := _seg(u, 0.77, 0.83) * (1.0 - _seg(u, 0.84, 0.86))
			if u < 0.85:
				k = 1.0 + 0.1 * pull
			else:
				k = 1.0 - _smooth((u - 0.85) / 0.02)
	_slide_k = k
	_slide.position = Vector3(0.0, 0.0, SLIDE_TRAVEL * _slide_k)
	_mag.position = Basis(Vector3.RIGHT, GRIP_RAKE) * Vector3(0.0, -drop, 0.0)
	var tumble := clampf((drop - 0.08) / 0.22, 0.0, 1.0) if u < 0.32 else 0.0
	_mag.rotation = Vector3(GRIP_RAKE + tumble * 0.6, 0.0, tumble * 0.4)
	_mag.visible = vis
	_gun.transform = Transform3D(Basis.from_euler(Vector3(slap * 0.035, 0.0, 0.0)), Vector3(0.0, slap * 0.005, 0.0))
	# The off hand (camera space): the magazine, then (empty) the slide overhand.
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


## After the base frame (its inspect / attachment-fit hooks write the left hand's reach as if it held
## a grip): one-handed, every reach blends from the out-of-view rest instead.
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

## First-person model: a striker-fired service pistol. Machined gunmetal slide (rear and front cocking
## serrations, a white polymer side insert over a thin glow strip, the ejection port and extractor on
## the right, a matte anti-glare top, a notch rear sight and a post front sight with tritium dots),
## a dark polymer frame with an accessory rail under the dust cover and an orange pinstripe, a raked
## stippled grip with finger grooves and a ribbed back strap, a beavertail, a squared trigger guard,
## the slide stop and the magazine release on the left, an orange magazine base plate.
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var gm := VM.mat(Color(0.3, 0.305, 0.315), 0.42, 0.65)
	var gm2 := VM.mat(Color(0.24, 0.245, 0.255), 0.5, 0.6)
	var inset := VM.mat(Color(0.15, 0.155, 0.16), 0.66, 0.45)
	var steel := VM.mat(Color(0.42, 0.43, 0.45), 0.3, 0.85)
	var poly := VM.mat(Color(0.13, 0.128, 0.125), 0.8, 0.04)
	var stip := VM.mat(Color(0.095, 0.094, 0.092), 0.95, 0.0)
	var black := VM.mat(Color(0.05, 0.05, 0.055), 0.6, 0.2)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var by := BORE_Y
	var rake := Basis(Vector3.RIGHT, GRIP_RAKE)
	# --- Frame (polymer) ---
	VM.soft_box(_gun, Vector3(0, 0.011, -0.068), Vector3(0.027, 0.014, 0.16), 0.004, poly)
	VM.soft_box(_gun, Vector3(0, 0.006, 0.018), Vector3(0.026, 0.014, 0.03), 0.005, poly)   # beavertail
	for k in 3:
		VM.box(_gun, Vector3(0, 0.0032, -0.103 - k * 0.015), Vector3(0.022, 0.0026, 0.007), black)   # rail slots
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0137 * sx, 0.0115, -0.105), Vector3(0.0008, 0.0022, 0.06), orange)
	# Trigger guard (squared front, a serrated face) and the trigger.
	VM.box(_gun, Vector3(0, -0.031, -0.0455), Vector3(0.012, 0.005, 0.064), poly)
	VM.box(_gun, Vector3(0, -0.0135, -0.0775), Vector3(0.012, 0.036, 0.005), poly, Basis(Vector3.RIGHT, 0.08))
	for k in 3:
		VM.box(_gun, Vector3(0, -0.024 + k * 0.0075, -0.0802), Vector3(0.011, 0.0018, 0.0012), stip)
	VM.box(_gun, Vector3(0, -0.0075, -0.043), Vector3(0.006, 0.022, 0.006), steel, Basis(Vector3.RIGHT, 0.25))
	VM.box(_gun, Vector3(0, -0.0055, -0.043), Vector3(0.0018, 0.012, 0.0062), black, Basis(Vector3.RIGHT, 0.25))   # safety blade
	# Slide stop and magazine release (left), the takedown lever.
	VM.box(_gun, Vector3(-0.0142, 0.0135, -0.04), Vector3(0.0022, 0.004, 0.02), gm2)
	VM.box(_gun, Vector3(-0.0142, -0.004, -0.0115), Vector3(0.0028, 0.007, 0.006), black)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0137 * sx, 0.0125, -0.062), Vector3(0.0012, 0.004, 0.008), steel)
	# --- Grip: raked, stippled sides, finger grooves on the front strap, a ribbed back strap ---
	VM.soft_box(_gun, rake * Vector3(0, -0.054, 0.0), Vector3(0.03, 0.104, 0.048), 0.008, poly, rake)
	for sx in [-1.0, 1.0]:
		for row in 6:
			for col in 3:
				VM.box(_gun, rake * Vector3(0.0151 * sx, -0.022 - row * 0.0125, -0.0135 + col * 0.0135),
						Vector3(0.0012, 0.0085, 0.0095), stip, rake)
	for k in 3:
		VM.box(_gun, rake * Vector3(0, -0.032 - k * 0.0205, -0.0242), Vector3(0.024, 0.004, 0.0024), stip, rake)
	for k in 6:
		VM.box(_gun, rake * Vector3(0, -0.03 - k * 0.0115, 0.0242), Vector3(0.022, 0.0026, 0.0022), stip, rake)
	VM.box(_gun, rake * Vector3(0, -0.103, 0.0015), Vector3(0.0326, 0.006, 0.051), poly, rake)       # magwell flare
	# --- Barrel crown at the slide's front (fixed: the slide runs back over it) ---
	VM.seg(_gun, Vector3(0, by, -0.148), Vector3(0, by, -0.1592), 0.0068, 0.0068, steel, 16)
	VM.seg(_gun, Vector3(0, by, -0.159), Vector3(0, by, -0.1596), 0.0043, 0.0043, black, 12)
	VM.seg(_gun, Vector3(0, 0.0085, -0.147), Vector3(0, 0.0085, -0.1505), 0.0042, 0.0042, gm2, 10)   # guide rod
	_muzzle = VM.node(_gun, Vector3(0, by, -0.162))
	# --- Slide (its own node: cycles on each shot, locks back empty) ---
	_slide = VM.node(_gun)
	VM.soft_box(_slide, Vector3(0, 0.031, -0.063), Vector3(0.0255, 0.03, 0.19), 0.0035, gm)
	VM.box(_slide, Vector3(0, 0.0462, -0.063), Vector3(0.0135, 0.0012, 0.15), inset)        # anti-glare top
	for k in 10:
		VM.box(_slide, Vector3(0, 0.0469, -0.13 + k * 0.0145), Vector3(0.0125, 0.0006, 0.0012), black)
	for sx in [-1.0, 1.0]:
		for k in 7:
			VM.box(_slide, Vector3(0.0129 * sx, 0.0315, 0.026 - k * 0.0045), Vector3(0.0012, 0.022, 0.0018), inset)
		for k in 4:
			VM.box(_slide, Vector3(0.0129 * sx, 0.0335, -0.126 - k * 0.0045), Vector3(0.0012, 0.018, 0.0018), inset)
		VM.box(_slide, Vector3(0.0129 * sx, 0.0345, -0.088), Vector3(0.0013, 0.014, 0.05), white)
		VM.box(_slide, Vector3(0.0131 * sx, 0.0222, -0.075), Vector3(0.0009, 0.0018, 0.085), VM.glow(accent, 2.0))
	VM.box(_slide, Vector3(0.0124, 0.0405, -0.028), Vector3(0.0018, 0.0105, 0.032), black)    # ejection port
	VM.box(_slide, Vector3(0.0131, 0.0425, -0.0055), Vector3(0.0008, 0.003, 0.012), steel)    # extractor
	VM.box(_slide, Vector3(0, 0.031, 0.0322), Vector3(0.021, 0.025, 0.0012), gm2)            # rear plate
	VM.box(_slide, Vector3(0, 0.03, 0.033), Vector3(0.008, 0.012, 0.001), orange)            # striker cover
	_eject = VM.node(_slide, Vector3(0.016, 0.041, -0.028))
	_rack_pt = VM.node(_slide, Vector3(-0.006, 0.035, 0.012))
	# Sights (their own node: hidden while an optic is fitted): a notch rear with two dots, a post front
	# with one, the tops on the sight line.
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
	# --- Magazine (through the grip; its orange base plate shows under the magwell) ---
	_mag = VM.node(_gun, Vector3.ZERO, rake)
	VM.box(_mag, Vector3(0, -0.055, 0.0), Vector3(0.0215, 0.1, 0.033), gm2)
	VM.seg(_mag, Vector3(0, -0.0045, 0.006), Vector3(0, -0.0045, -0.012), 0.0045, 0.004, VM.mat(Color(0.78, 0.6, 0.3), 0.3, 0.9), 10)
	VM.box(_mag, Vector3(0, -0.1095, 0.003), Vector3(0.029, 0.007, 0.047), orange)
	_mag_grab = VM.node(_mag, Vector3(-0.022, -0.1, 0.018))
	# The left grip node: the view model needs one for the reload / inspect reach (one-handed: the
	# reach blends from the rest, never onto this point; under the magwell, out of the way).
	left_grip = VM.node(_gun, rake * Vector3(0, -0.13, 0.0))
	left_grip.name = "LeftGrip"
	_make_flash(_gun, Vector3(0, by, -0.166), 0.62)
	VM.bake(_gun, [_slide, _mag, _flash_root, _muzzle, left_grip])
	VM.bake(_slide, [irons, _eject, _rack_pt])
	VM.bake(irons)
	VM.bake(_mag, [_mag_grab])
	# Attachment mounts: a can on the barrel crown, a reflex on the slide (it rides with the slide).
	att_kit.build(self, _gun, {
		"muzzle": {"at": Vector3(0, by, -0.158), "r": 0.0068, "tip": -0.162, "sup_r": 0.0135, "sup_len": 0.13,
			"shift": [_muzzle, _flash_root]},
		"optic": {"y": 0.0466, "z": 0.006, "irons": SIGHT_Y, "default": irons, "parent": _slide},
	})
	return model


# =================================================================================================
# Third-person model (the player's body, remote avatars, dropped guns)
# =================================================================================================

func _build_tp(p: Node3D) -> Node3D:
	return build_tp_model(p)


## Simplified model under prop root `p` (grip at the origin, -Z forward). Returns the muzzle node.
static func build_tp_model(p: Node3D) -> Node3D:
	var gm := _mat3(Color(0.2, 0.205, 0.215), 0.5, 0.7)
	var poly := _mat3(Color(0.08, 0.078, 0.075), 0.85, 0.05)
	var orange := _mat3(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var rake := Basis(Vector3.RIGHT, GRIP_RAKE)
	VM.box(p, Vector3(0, 0.031, -0.063), Vector3(0.026, 0.03, 0.19), gm)
	VM.box(p, Vector3(0, 0.008, -0.068), Vector3(0.027, 0.02, 0.16), poly)
	VM.box(p, rake * Vector3(0, -0.054, 0.0), Vector3(0.03, 0.104, 0.048), poly, rake)
	VM.box(p, rake * Vector3(0, -0.109, 0.003), Vector3(0.029, 0.007, 0.047), orange, rake)
	VM.box(p, Vector3(0, -0.028, -0.045), Vector3(0.012, 0.006, 0.06), poly)
	return VM.node(p, Vector3(0, BORE_Y, -0.162))


static func _mat3(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m
