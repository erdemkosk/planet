extends "res://scripts/items/weapon_base.gd"
## Hafif Makineli (item id "smg"; an Uzi-style submachine gun, crafted at the Silahlık; the loadout
## picks its key; WEIGHT 1.05 = a little quicker on your feet than empty-handed balance).
##   Fire      Balance.SMG_RATE rounds/s, SMG_DAMAGE a round up to SMG_FALLOFF_START m, then falling
##             (smoothstep) to × SMG_FALLOFF_MIN at SMG_FALLOFF_END: it out-kills the rifle up close and
##             is weak past ~20 m. Spread blooms fast in sustained fire; the first round of a burst is
##             tight. Pistol-calibre rounds at SMG_SPEED m/s, a tracer every SMG_TRACER_EVERY-th round
##             (the others draw only a hairline), a case out of the right-hand port every shot.
##   Mode      B: TEK (semi) ↔ SERİ (full auto); the HUD panel title shows it
##             ("HAFİF MAKİNELİ · SERİ").
##   Handling  magazine SMG_MAG through the pistol grip, R reloads in SMG_RELOAD s (the left hand
##             drops the magazine out of the grip and slaps a new one in; empty: racks the top cocking
##             knob), quick aim (iron sights), little move penalty, light recoil per round with a quick
##             climb (gun_feel.gd pattern).
##   Sound     the recorded 5.56 report pitched up and cut short, a mechanical bolt clatter, the punch;
##             in vacuum only the suit-borne thump.
## Hits go through weapon_base.gd bullet_hit -> gun_feel.gd body_hit (markers, reactions, kill feed
## "Hafif Mak."), Game.shot_fired for the bots and the multiplayer shot replay (icon "smg").
## Hand anchors (the hands rig): the right hand on "PistolGrip" (model origin, the magazine runs
## through it), the index finger on "Trigger"; the support hand on "LeftGrip" (item.left_grip: under
## the polymer handguard at the receiver front, the rifle's basis), or "Foregrip" (a short vertical
## grip under the handguard, hidden: forward_grip.visible = true to use it).
## Attachments (middle mouse radial, scripts/items/attachments.gd): every slot. The muzzle devices
## screw onto the barrel crown, the optics clamp on the top cover behind the cocking knob, the "Ön
## Tutamak" attachment hangs through the folded stock's butt plate (the left hand moves onto it), the
## laser under the barrel; a suppressor also costs 10 % of the falloff range and 8 % velocity.

const Balance := preload("res://scripts/war/balance.gd")

const WEIGHT := 1.05                     # mobility factor while carried (the loadout applies it)
const BORE_Y := 0.052
const SIGHT_Y := 0.093
const REAR_Z := 0.07
const MAG_REST := Vector3(0.0, -0.02, 0.006)
const MAG_AXIS := Vector3(0.0, -0.9988, 0.05)
const GRIP_RAKE := -0.05                 # rad: the grip's bottom leans back a little
const KNOB_REST := Vector3(0.0, 0.085, -0.115)
const KNOB_TRAVEL := 0.1

## Fire modes: the rifle's API (rifle.gd), so the HUD / quickbar read every gun alike. The SMG has
## TEK and SERİ (no ÜÇLÜ).
enum { FIRE_SEMI, FIRE_AUTO, FIRE_BURST }
const FIRE_MODE_NAMES := ["TEK", "SERİ", "ÜÇLÜ"]

var fire_mode := FIRE_AUTO
var panel_name := "Hafif Makineli · SERİ"
var handling_len := 0.55                  # handling.gd: wall pull-back length (a short gun)
var forward_grip: Node3D                  # optional vertical foregrip (hidden by default)
var grip_point: Node3D                    # hand anchors (build_model)
var trigger_point: Node3D

var _round_i := 0
var _mag: Node3D
var _mag_grab: Node3D
var _knob: Node3D
var _selector: Node3D


func _init() -> void:
	item_id = "smg"
	item_name = "Hafif Makineli"
	item_desc = "Sol tık: ateş · B: tek ↔ seri · Sağ tık: nişan · R: şarjör · Orta tık basılı: eklentiler."
	icon = "smg"
	slot_key = 0                         # the loadout (Silahlık) decides its key
	short_name = "Hafif Mak."
	accent = Color(1.0, 0.72, 0.32)
	ammo_id = "ammo_smg"
	ammo_title = "9 MM · HAFİF MAKİNELİ"
	base_mag = Balance.SMG_MAG
	reload_kind = "mag"
	reload_time = Balance.SMG_RELOAD
	reload_empty_time = Balance.SMG_RELOAD + 0.3
	auto_fire = true
	fire_rate = Balance.SMG_RATE
	ads_fov = 64.0
	sight_rear = Vector3(0.0, SIGHT_Y, REAR_Z)
	ads_eye = Vector3(0.0, 0.0, -0.21)
	hip_pos = Vector3(0.15, -0.19, -0.33)
	hip_bore_y = BORE_Y
	hip_converge = 9.0
	hip_cant = 0.09
	sprint_pos = Vector3(0.13, -0.17, -0.34)
	sprint_rot = Vector3(-0.25, 0.55, 0.35)
	reload_pos = Vector3(0.11, -0.16, -0.34)
	reload_rot = Vector3(0.18, 0.3, 0.55)
	recoil_pivot = Vector3(0.0, 0.03, 0.08)
	aim_speed = 0.85
	sprint_to_fire = 0.14
	spread_hip = 0.022
	spread_ads = 0.007
	bloom_add = 0.0045
	bloom_max = 0.045
	first_shot_k = 0.45
	# Recoil pass (2026-10-05): faster and jittery, less climb than the rifle: ~0.37° of view climb a
	# round aimed, ~12° over a 32-round magazine if not pulled down (rifle ~27°), an alternating
	# sideways pattern plus a random chatter (recoil_jitter) you cannot learn away.
	kick_pitch = 0.0105
	kick_yaw = 0.009
	kick_roll = 0.004
	gun_kick = 2.6
	recoil_first = 1.3
	recoil_view = 0.7
	recoil_jitter = 0.0024
	shake_amt = 0.07
	fov_punch_amt = -0.35
	noise_radius = 45.0
	crosshair_style = "ticks"
	hit_big = 0.16
	hit_punch = 0.55
	armor_pierce = 0.05
	muzzle_energy = 7.0
	punch_db = -9.0
	recoil_climb = 0.3                    # a little steeper as the burst runs (was 0.9)
	recoil_h = PackedFloat32Array([0.35, -0.5, 0.6, -0.3, 0.55, -0.65, 0.25, -0.4, 0.7, -0.55])
	recoil_hold = 0.04
	recoil_recover = 1.3
	head_mult = Balance.SMG_HEAD_MULT
	kill_launch = 3.5
	ads_k = 150.0
	ads_c = 17.0
	impact_cal = 0.7
	flash_long = 0.7
	tail_db = -16.0
	draw_time = 0.5
	holster_time = 0.32


func mode_text() -> String:
	return FIRE_MODE_NAMES[effective_fire_mode()]


func mode_available(m: int) -> bool:
	return m == FIRE_SEMI or m == FIRE_AUTO


func effective_fire_mode() -> int:
	return fire_mode if mode_available(fire_mode) else FIRE_SEMI


func reload_label() -> String:
	return "ŞARJÖR DEĞİŞİYOR"


func _hip_sway() -> float:
	return 1.3


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
	_update_panel()


## B (weapon_base.gd): the next mode, TEK ↔ SERİ.
func toggle_mode() -> void:
	toggle_fire_mode()


func toggle_fire_mode() -> void:
	var m := effective_fire_mode()
	for i in 3:
		m = (m + 1) % 3
		if mode_available(m):
			break
	set_fire_mode(m)


## Selects fire mode `m` (FIRE_SEMI / FIRE_AUTO): the selector click, the panel title, a short note.
func set_fire_mode(m: int) -> void:
	fire_mode = m if mode_available(m) else FIRE_SEMI
	auto_fire = fire_mode == FIRE_AUTO
	if Game.sfx:
		Game.sfx.play("click", -8.0, 1.1 if auto_fire else 0.95)
	_play("selector", -9.0, 1.2 if auto_fire else 1.0)
	_rk_vel += Vector4(0.0, 0.0, 0.18, 0.0)
	if hud != null and hud.has_method("mode_switched"):
		hud.mode_switched()
	_update_panel()
	if Game.hud:
		Game.hud.show_message("Atış modu: %s" % mode_text(), 1.0)


func _update_panel() -> void:
	panel_name = "Hafif Makineli · " + mode_text()


# =================================================================================================
# Firing
# =================================================================================================

func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var dir := _spread_dir(fwd, cb, current_spread())
	_round_i += 1
	var tracer := _round_i % maxi(Balance.SMG_TRACER_EVERY, 1) == 0
	fx.bullet(eye, dir * Balance.SMG_SPEED * randf_range(0.98, 1.02) * att_kit.stat("velocity") + player.velocity, muzzle, 0,
			Color(1.0, 0.76, 0.42), false, 0, 0.75 if tracer else 0.02)


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(randf_range(0.8, 1.05))
	fx.muzzle_light(muzzle + fwd * 0.5, Color(1.0, 0.7, 0.36), muzzle_energy, 0.035, 12.0)
	if _round_i % 4 == 0:
		fx.muzzle_smoke(muzzle + fwd * 0.1, fwd, up, 0.6)
	# A case out of the right-hand port every round.
	if _eject != null:
		fx.shell(_vm_world(_eject), cb.x * randf_range(1.4, 2.3) + up * randf_range(1.0, 1.9) + fwd * 0.3 + player.velocity, false, false, true)


func _hit_damage(p: Vector3, _ammo: int) -> float:
	var d := 0.0
	if player != null:
		d = (player.global_position as Vector3).distance_to(p) / att_kit.stat("range")   # (a suppressor: −10 % range)
	var k := 1.0 - (1.0 - Balance.SMG_FALLOFF_MIN) * smoothstep(Balance.SMG_FALLOFF_START, Balance.SMG_FALLOFF_END, d)
	return Balance.SMG_DAMAGE * k


func _hit_impulse(_ammo: int) -> float:
	return 2.0


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		# Vacuum: only the knock through the suit.
		_play("thump", -10.0, randf_range(1.3, 1.45), true)
		_shot_body(space, 1.4, -80.0)
		return
	# A short, high, punchy report and the bolt's clatter on top.
	_play("shot", -4.0, randf_range(1.3, 1.42), true, 0.12)
	_play("action", -14.0, randf_range(1.75, 2.0), true, 0.08)
	if _round_i % 3 == 0:
		_play("tink", -26.0, randf_range(1.6, 2.0))
	_shot_body(space, 1.35, -17.0)


# =================================================================================================
# Reload and model animation
# =================================================================================================

func _reload_events(u: float) -> void:
	var marks := [0.04, 0.1, 0.16, 0.48, 0.56, 0.8, 0.88]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -17.0, randf_range(1.0, 1.15))
			1:
				_play("mag_release", -9.0, 1.2)
			2:
				_play("mag_out", -8.0, 1.2)
			3:
				_play("mag_in", -6.0, 1.15)
				_rk_vel.w += 0.2
			4:
				_play("mag_slap", -5.0, 1.2)
				_rk_vel.x += 0.5
			5:
				if _reload_empty:
					_play("bolt_back", -7.0, 1.3)
			6:
				if _reload_empty:
					_play("bolt_fwd", -5.0, 1.3)
					_rk_vel += Vector4(0.6, 0.0, 0.0, 0.25)
		_reload_ev += 1


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _mag == null:
		return
	var u := reload_progress() if reloading else 0.0
	var drop := 0.0
	var vis := true
	var slap := 0.0
	var knob := 0.0
	if reloading:
		var w_mag := _seg(u, 0.03, 0.12) * (1.0 - _seg(u, 0.6, 0.68))
		drop = lerpf(0.0, 0.04, _seg(u, 0.12, 0.18)) + lerpf(0.0, 0.35, _seg(u, 0.18, 0.32))
		if u > 0.36:
			drop = lerpf(0.4, 0.02, _seg(u, 0.36, 0.5)) * (1.0 - _seg(u, 0.5, 0.56))
		vis = u < 0.33 or u > 0.37
		slap = sin(clampf((u - 0.55) / 0.06, 0.0, 1.0) * PI)
		var w_knob := 0.0
		if _reload_empty:
			w_knob = _seg(u, 0.68, 0.76) * (1.0 - _seg(u, 0.93, 0.99))
			knob = _seg(u, 0.78, 0.84) * (1.0 - _seg(u, 0.86, 0.9))
		if player != null:
			var cam_inv: Transform3D = player.camera.global_transform.affine_inverse()
			if w_knob > w_mag:
				left_reach = cam_inv * _knob.global_position + Vector3(-0.03, -0.06, 0.04)
				left_reach_w = w_knob
			else:
				left_reach = cam_inv * _mag_grab.global_position + Vector3(0.0, 0.03 * slap, 0.0)
				left_reach_w = w_mag
			left_reach_elbow = Vector3(-0.3, -0.85, 0.45)
	else:
		left_reach_w = 0.0
	_mag.position = MAG_REST + MAG_AXIS * drop
	var tumble := clampf((drop - 0.1) / 0.3, 0.0, 1.0)
	_mag.rotation = Vector3(GRIP_RAKE + tumble * 0.5, 0.0, tumble * 0.35)
	_mag.visible = vis
	_knob.position = KNOB_REST + Vector3(0.0, 0.0, KNOB_TRAVEL * knob)
	_selector.rotation.z = lerp_angle(_selector.rotation.z, -0.6 if auto_fire else 0.4, 1.0 - exp(-20.0 * delta))
	_gun.transform = Transform3D(Basis.from_euler(Vector3(slap * 0.03, 0.0, 0.0)), Vector3(0.0, slap * 0.006, 0.0))


# =================================================================================================
# Model
# =================================================================================================

## First-person model: an Uzi-like stamped-steel receiver (weathered gunmetal, worn edges, pressed side
## panels, a top cover with a cocking knob in its slot, flip aperture rear sight, a hooded front post
## with a tritium dot), a black polymer pistol grip with the magazine running through it and a grip
## safety, a stamped trigger guard, a fire selector on the left, the polymer handguard at the front, a
## knurled barrel nut and a short barrel with a crowned muzzle, the folding wire stock folded under the
## receiver (its butt plate under the handguard).
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	# Gunmetal ~0.25-0.3 and polymer ~0.12 (at 0.16-0.19 / 0.075 the gun drew as a black block in
	# shade, a wall over the view when aiming).
	var gm := VM.mat(Color(0.3, 0.305, 0.315), 0.5, 0.6)
	var gm2 := VM.mat(Color(0.25, 0.255, 0.265), 0.46, 0.62)
	var inset := VM.mat(Color(0.17, 0.175, 0.18), 0.62, 0.5)
	var worn := VM.mat(Color(0.55, 0.56, 0.57), 0.36, 0.8)
	var steel := VM.mat(Color(0.4, 0.41, 0.43), 0.34, 0.8)
	var poly := VM.mat(Color(0.12, 0.118, 0.115), 0.78, 0.05)
	var black := VM.mat(Color(0.06, 0.06, 0.065), 0.6, 0.2)
	var orange := VM.suit_orange()
	var by := BORE_Y
	var rake := Basis(Vector3.RIGHT, GRIP_RAKE)
	# Receiver: a stamped box with pressed side panels, worn top edges, a darker top cover.
	VM.soft_box(_gun, Vector3(0, 0.045, -0.06), Vector3(0.05, 0.066, 0.3), 0.005, gm)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0252 * sx, 0.042, -0.115), Vector3(0.0015, 0.034, 0.13), inset)
		VM.box(_gun, Vector3(0.0252 * sx, 0.042, 0.04), Vector3(0.0015, 0.03, 0.06), inset)
		for k in 3:
			VM.box(_gun, Vector3(0.0256 * sx, 0.042, -0.035 + k * 0.012), Vector3(0.0012, 0.026, 0.003), worn)
		VM.box(_gun, Vector3(0.0235 * sx, 0.0775, -0.06), Vector3(0.003, 0.0025, 0.29), worn)
		VM.box(_gun, Vector3(0.0235 * sx, 0.0125, -0.06), Vector3(0.003, 0.0025, 0.29), worn)
	VM.box(_gun, Vector3(0, 0.0805, -0.055), Vector3(0.044, 0.006, 0.27), gm2)
	VM.box(_gun, Vector3(0, 0.0838, -0.06), Vector3(0.007, 0.0012, 0.13), black)
	for k in 6:
		VM.box(_gun, Vector3(0, 0.0838, 0.03 + k * 0.007), Vector3(0.036, 0.0012, 0.0025), inset)   # grip ribs on the cover
	# End cap on the receiver's back (what the eye sees aimed): a plate with a recessed panel and four
	# worn screw heads, so the face reads as machined steel, not a flat slab.
	VM.box(_gun, Vector3(0, 0.046, 0.0912), Vector3(0.04, 0.052, 0.0025), gm2)
	VM.box(_gun, Vector3(0, 0.046, 0.0926), Vector3(0.026, 0.03, 0.001), inset)
	for sx in [-1.0, 1.0]:
		for sy in [0.027, 0.065]:
			VM.seg(_gun, Vector3(0.0145 * sx, sy, 0.091), Vector3(0.0145 * sx, sy, 0.0935), 0.0022, 0.002, worn, 10)
	# Cocking knob in its slot (racked on an empty reload): a low mushroom, its top 4 mm under the
	# sight line (the old 14.5 mm knob stood on the sight line and filled the aperture, ridges and all).
	_knob = VM.node(_gun, KNOB_REST)
	VM.seg(_knob, Vector3(0, -0.002, 0), Vector3(0, 0.0018, 0), 0.0075, 0.0085, steel, 12)
	VM.seg(_knob, Vector3(0, 0.0018, 0), Vector3(0, 0.0035, 0), 0.0085, 0.0068, worn, 12)
	for k in 4:
		VM.box(_knob, Vector3(0, 0.0004, 0), Vector3(0.018, 0.003, 0.0016), black, Basis(Vector3.UP, PI * 0.25 * k))
	# Sights: flip aperture at the rear (a thin ring on a short leaf between two slim guard ears: aimed,
	# the front hood sits inside the ring and the target shows round it), hooded post with a tritium
	# dot at the front (their own node: hidden while an optic is fitted, attachments.gd).
	var irons := VM.node(_gun)
	var ap_r := 0.0068                       # aperture ring outer radius (the hole: 5.5 mm)
	var cover := 0.0835                      # top cover surface
	# (Low guard shoulders under the ring's centre and a round front hood: full-height ears read as
	# stray vertical lines in the sight picture.)
	for sx in [-1.0, 1.0]:
		VM.box(irons, Vector3(0.0118 * sx, (cover + SIGHT_Y - 0.003) * 0.5, REAR_Z), Vector3(0.003, SIGHT_Y - 0.003 - cover, 0.01), gm2)
	VM.ring(irons, Vector3(0, SIGHT_Y - 0.0015, -0.195), Vector3.BACK, 0.0072, 0.0018, gm2)
	VM.box(irons, Vector3(0, (cover + SIGHT_Y - ap_r) * 0.5, REAR_Z), Vector3(0.004, SIGHT_Y - ap_r - cover + 0.001, 0.003), gm2)
	var ap := TorusMesh.new()
	ap.inner_radius = ap_r - 0.0013
	ap.outer_radius = ap_r
	ap.rings = 36
	ap.ring_segments = 8
	VM.mesh_inst(irons, ap, gm2).transform = Transform3D(VM.basis_y(Vector3.BACK), Vector3(0, SIGHT_Y, REAR_Z))
	# (The tritium dot's centre exactly on the sight line, the post's tip just under it: it sat 2.8 mm
	# high, ~20 MOA over the point of impact.)
	VM.box(irons, Vector3(0, SIGHT_Y - 0.0075, -0.195), Vector3(0.003, 0.013, 0.004), black)
	var dot := VM.sphere(irons, Vector3(0, SIGHT_Y, -0.1928), 0.0013, VM.glow(Color(0.4, 1.0, 0.5), 5.0))
	dot.set_meta("no_bake", true)
	# Ejection port on the right, the case leaves here.
	VM.box(_gun, Vector3(0.0255, 0.06, -0.075), Vector3(0.002, 0.016, 0.045), black)
	_eject = VM.node(_gun, Vector3(0.03, 0.062, -0.075))
	# Barrel nut (knurled) and the short barrel.
	VM.seg(_gun, Vector3(0, by, -0.205), Vector3(0, by, -0.236), 0.02, 0.02, gm2, 18)
	for k in 10:
		var a := TAU * float(k) / 10.0
		VM.box(_gun, Vector3(cos(a) * 0.0203, by + sin(a) * 0.0203, -0.2205), Vector3(0.0025, 0.0025, 0.028), inset)
	VM.seg(_gun, Vector3(0, by, -0.236), Vector3(0, by, -0.3), 0.0105, 0.0102, steel, 14)
	VM.ring(_gun, Vector3(0, by, -0.3), Vector3.FORWARD, 0.0106, 0.003, worn)
	_muzzle = VM.node(_gun, Vector3(0, by, -0.305))
	# Polymer handguard at the receiver front (the support hand's place).
	VM.soft_box(_gun, Vector3(0, 0.004, -0.155), Vector3(0.054, 0.024, 0.1), 0.006, poly)
	for sx in [-1.0, 1.0]:
		for k in 4:
			VM.box(_gun, Vector3(0.0272 * sx, 0.004, -0.12 - k * 0.022), Vector3(0.0012, 0.014, 0.006), black)
	# Pistol grip (the magazine runs through it), grip safety, trigger and the stamped guard.
	VM.soft_box(_gun, Vector3(0, -0.04, 0.006), Vector3(0.034, 0.1, 0.046), 0.009, poly, rake)
	for sx in [-1.0, 1.0]:
		for k in 4:
			VM.box(_gun, rake * Vector3(0.0172 * sx, -0.07 + k * 0.016, 0.006), Vector3(0.0012, 0.004, 0.034), black, rake)
	VM.box(_gun, rake * Vector3(0, -0.028, 0.031), Vector3(0.018, 0.05, 0.006), gm, rake)
	VM.box(_gun, Vector3(0, -0.004, -0.032), Vector3(0.006, 0.022, 0.007), steel, Basis(Vector3.RIGHT, 0.25))
	VM.box(_gun, Vector3(0, -0.027, -0.05), Vector3(0.012, 0.004, 0.052), gm)
	VM.box(_gun, Vector3(0, -0.012, -0.076), Vector3(0.012, 0.032, 0.004), gm)
	# Fire selector on the left (turns with the mode) and a sling loop.
	_selector = VM.node(_gun, Vector3(-0.026, 0.004, 0.008))
	VM.seg(_selector, Vector3(0, 0, 0), Vector3(-0.004, 0, 0), 0.006, 0.006, gm2, 10)
	VM.box(_selector, Vector3(-0.004, 0.008, 0.0), Vector3(0.003, 0.016, 0.006), worn)
	VM.ring(_gun, Vector3(-0.026, 0.02, -0.19), Vector3.RIGHT, 0.008, 0.002, steel)
	# Folding wire stock, folded: hinge at the rear, arms along the lower sides, butt plate under the
	# handguard.
	VM.box(_gun, Vector3(0, 0.018, 0.098), Vector3(0.046, 0.022, 0.016), inset)
	for sx in [-1.0, 1.0]:
		VM.capsule(_gun, Vector3(0.0275 * sx, 0.018, 0.098), Vector3(0.0275 * sx, 0.016, -0.06), 0.003, worn, 8)
		VM.capsule(_gun, Vector3(0.0275 * sx, 0.016, -0.06), Vector3(0.026 * sx, -0.012, -0.115), 0.003, worn, 8)
	VM.box(_gun, Vector3(0, -0.014, -0.15), Vector3(0.056, 0.004, 0.07), gm)
	VM.box(_gun, Vector3(0, -0.014, -0.118), Vector3(0.058, 0.006, 0.006), orange)
	# Magazine (through the grip; the left hand swaps it).
	_mag = VM.node(_gun, MAG_REST, rake)
	VM.box(_mag, Vector3(0, -0.07, 0), Vector3(0.026, 0.16, 0.032), gm2)
	for sx in [-1.0, 1.0]:
		VM.box(_mag, Vector3(0.0132 * sx, -0.12, 0.0), Vector3(0.0012, 0.05, 0.004), inset)
	VM.box(_mag, Vector3(0, -0.152, 0), Vector3(0.03, 0.01, 0.038), black)
	_mag_grab = VM.node(_mag, Vector3(-0.025, -0.13, 0.02))
	# Hand anchors (the hands rig): right hand "PistolGrip" at the origin, "Trigger"; the support hand
	# under the handguard ("LeftGrip" = item.left_grip, the rifle's basis) or on the optional vertical
	# "Foregrip" (hidden; its anchor is the grip's centre, the fist around its axis).
	grip_point = VM.node(_gun, Vector3.ZERO, rake)
	grip_point.name = "PistolGrip"
	trigger_point = VM.node(_gun, Vector3(0, -0.004, -0.032))
	trigger_point.name = "Trigger"
	left_grip = VM.node(_gun, Vector3(0, -0.028, -0.155), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	left_grip.name = "LeftGrip"
	forward_grip = VM.node(_gun, Vector3(0, -0.05, -0.17))
	forward_grip.name = "Foregrip"
	VM.capsule(forward_grip, Vector3(0, -0.03, 0), Vector3(0, 0.032, 0), 0.014, poly, 10)
	forward_grip.visible = false
	# Muzzle flash: short and bright.
	_make_flash(_gun, Vector3(0, by, -0.312), 0.85)
	VM.bake(_gun, [_mag, _knob, _selector, _flash_root, _muzzle, _eject, left_grip, grip_point, trigger_point,
			forward_grip, irons])
	VM.bake(_mag, [_mag_grab])
	VM.bake(_knob)
	VM.bake(_selector)
	VM.bake(irons)
	# Attachment mounts (attachments.gd; every compatible part built hidden): a device on the barrel
	# crown, optics on the top cover behind the cocking knob's travel, the foregrip through the folded
	# stock's butt plate, the laser under the barrel.
	att_kit.build(self, _gun, {
		"muzzle": {"at": Vector3(0, by, -0.296), "r": 0.0105, "tip": -0.3, "sup_r": 0.0165, "sup_len": 0.15,
			"shift": [_muzzle, _flash_root]},
		"optic": {"y": 0.0838, "z": 0.03, "irons": SIGHT_Y, "default": irons},
		"under": {"grip": Vector3(0, -0.016, -0.165), "laser": Vector3(0, 0.0415, -0.265)},
	})
	return model


# =================================================================================================
# Third-person model (the player's body, remote avatars)
# =================================================================================================

func _build_tp(p: Node3D) -> Node3D:
	return build_tp_model(p)


## Simplified model under prop root `p` (grip at the origin, -Z forward). Returns the muzzle node.
static func build_tp_model(p: Node3D) -> Node3D:
	var gm := _mat3(Color(0.19, 0.2, 0.21), 0.58, 0.72)
	var poly := _mat3(Color(0.075, 0.072, 0.07), 0.82, 0.05)
	var steel := _mat3(Color(0.3, 0.31, 0.33), 0.35, 0.85)
	VM.box(p, Vector3(0, 0.045, -0.06), Vector3(0.05, 0.066, 0.3), gm)
	VM.box(p, Vector3(0, -0.04, 0.006), Vector3(0.034, 0.1, 0.046), poly)
	VM.box(p, Vector3(0, -0.13, 0.01), Vector3(0.026, 0.09, 0.032), gm)
	VM.box(p, Vector3(0, 0.004, -0.155), Vector3(0.054, 0.024, 0.1), poly)
	VM.seg(p, Vector3(0, BORE_Y, -0.205), Vector3(0, BORE_Y, -0.236), 0.02, 0.02, gm, 10)
	VM.seg(p, Vector3(0, BORE_Y, -0.236), Vector3(0, BORE_Y, -0.3), 0.011, 0.011, steel, 8)
	return VM.node(p, Vector3(0, BORE_Y, -0.305))


static func _mat3(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m
