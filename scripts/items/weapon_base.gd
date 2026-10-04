extends "res://scripts/items/item.gd"
## Shared machinery of the guns other than the rifle (the pump shotgun), built the same way as the
## rifle (scripts/items/rifle.gd) so they feel alike: the gun computes its whole camera-space pose
## (`pose_override`: hip / aim / sprint / reload, bob, mouse sway, recoil spring about the stock) and
## the view model only adds the swap lowering; aiming is a spring with a small overshoot; camera
## recoil snaps in and recovers on a slower spring; every shot is layered sound on the "Weapons"
## bus; bullets / pellets fly through a RifleFx instance (tracers, impacts, casings).
## Hits: anything in group "damageable" takes Game.damage_target(...) (the AI rival bot later, the
## player when the bot shoots); HitFeel shows the markers. Terrain hits are impact effects only.
## Ammo: a magazine plus the reserve in Game (Game.take_ammo buys the shortfall from material).
## Reloads are either a whole magazine (reload_kind "mag") or round by round ("shell": start,
## insert × n, end; firing interrupts). Subclasses set the tunables in _init and override
## build_model(), _fire_shot(), _fire_sound(), _animate_model() and the reload event hooks.

const Settings := preload("res://scripts/save/settings.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const RifleFx := preload("res://scripts/items/rifle_fx.gd")
const WeaponHud := preload("res://scripts/items/weapon_hud.gd")
const WeaponAudio := preload("res://scripts/items/weapon_audio.gd")
const ArsenalAudio := preload("res://scripts/items/arsenal_audio.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")

# --- Tunables (subclasses set these in _init) ----------------------------------------------------
var hip_fov := 75.0
var ads_fov := 60.0
var sight_rear := Vector3(0.0, 0.12, 0.03)     # sight line point that sits on the camera axis (gun frame)
var optic_y := 0.14                            # sight line height with the holographic optic
var ads_eye := Vector3(0.0, 0.0, -0.26)
var hip_pos := Vector3(0.165, -0.215, -0.4)
var hip_bore_y := 0.062
var hip_converge := 11.0
var hip_cant := 0.07
var sprint_pos := Vector3(0.15, -0.16, -0.4)
var sprint_rot := Vector3(-0.2, 0.62, 0.3)
var reload_pos := Vector3(0.15, -0.2, -0.4)
var reload_rot := Vector3(0.1, 0.2, 0.3)
var recoil_pivot := Vector3(0.0, 0.05, 0.24)
var aim_speed := 0.5
var can_ads := true
var auto_fire := false
var fire_rate := 2.0                          # shots per second
var ammo_id := ""
var base_mag := 6
var reload_kind := "mag"
var reload_time := 2.5
var reload_empty_time := 3.0
var shell_start := 0.4
var shell_each := 0.5
var shell_end := 0.35
var shell_end_empty := 0.7
var spread_hip := 0.02
var spread_ads := 0.006
var bloom_add := 0.006
var bloom_max := 0.03
var kick_pitch := 0.05
var kick_yaw := 0.015
var gun_kick := 5.0
var shake_amt := 0.3
var fov_punch_amt := -2.0
var noise_radius := 50.0
var sprint_to_fire := 0.25
var accent := Color(1.0, 0.6, 0.25)
var ammo_title := "MERMİ"
var crosshair_style := "ticks"                 # "ticks", "circle", "launcher", "minigun"
var hit_big := 0.3                             # shake / hit-stop weight of one hit
var hit_punch := 1.0                           # creature hit reaction (knockback / flinch / stagger) per hit
var armor_pierce := 0.15                       # share of a creature's armor one bullet ignores
var kick_roll := 0.01                          # camera roll kick per shot (rad)
var muzzle_energy := 6.0                       # muzzle light flash
var punch_db := -4.0                           # sub-bass "punch" layer under the shot (-80 = none)

# --- Read by the view model ------------------------------------------------------------------------
var pose_override := Transform3D()
var draw_time := 0.7
var holster_time := 0.4
var sway_scale := 1.5
var left_reach := Vector3.ZERO
var left_reach_w := 0.0
var left_reach_elbow := Vector3(-0.3, -0.8, 0.52)

# --- State -----------------------------------------------------------------------------------------
var mag := 0
var reloading := false
var ads := 0.0
var fx
var hud
var shots_fired := 0
var hits := 0
var last_impact := Vector3.INF
var debug_trigger := false
var debug_ads := false
var debug_ignore_input := false
var debug_sprint := false
var debug_audio_log := false
var audio_log: Array = []

var _ads_vel := 0.0
var _ads_want := false
var _cooldown := 0.0
var _trigger_prev := false
var _trig := false
var _bloom := 0.0
var _use_t := 0.0
var _recoil := Vector2.ZERO
var _recoil_target := Vector2.ZERO
var _roll := 0.0                               # camera roll kick (spring)
var _roll_v := 0.0
var _trauma := 0.0
var _fov_punch := 0.0
var _t := 0.0
var _cam_dirty := false
var _flash_t := 0.0
var _rk := Vector4.ZERO
var _rk_vel := Vector4.ZERO
var _sprint_w := 0.0
var _bob_amt := 0.0
var _bob_ph := 0.0
var _sway := Vector2.ZERO
var _sway_vel := Vector2.ZERO
var _vy := 0.0
var _look_acc := Vector2.ZERO
var _since_shot := 9.0
var _sprint := false
var _since_sprint := 9.0
var _reload_w := 0.0
# Magazine reload.
var _reload_t := 0.0
var _reload_total := 1.0
var _reload_empty := false
var _reload_ev := 0
# Shell-by-shell reload.
var _shell_phase := -1                         # 0 start, 1 inserting, 2 end
var _shell_t := 0.0
var _shell_need := 1
var _shell_done := 0
var _shell_interrupt := false
var _shell_ev := 0

# Model parts (subclasses fill these).
var _gun: Node3D
var _muzzle: Node3D
var _eject: Node3D
var _flash_root: Node3D
var _flash_mat: ShaderMaterial
var _tp_tip: Node3D                            # muzzle of the prop on the astronaut body (ragdoll / bot)

# Audio.
var _gun_audio: Array = []
var _gun_audio_i := 0
var _aux_audio: Array = []
var _aux_i := 0
var _fades: Array = []
const FADE_LEN := 0.07
var _snd := {}
static var _synth := {}
static var _synth_task := -1
static var _synth_ready := {}
static var _synth_mutex := Mutex.new()


func _ready() -> void:
	mag = mag_capacity()
	fx = RifleFx.new()
	fx.rifle = self
	add_child(fx)
	hud = WeaponHud.new()
	hud.weapon = self
	add_child(hud)
	_setup_audio()
	call_deferred("_build_tp_prop")


func _exit_tree() -> void:
	if _synth_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_finish_synth()


# =================================================================================================
# Item interface / HUD queries
# =================================================================================================

func accent_color() -> Color:
	return accent


func status_text() -> String:
	return "%d/%d" % [mag, reserve_count()]


func mag_capacity() -> int:
	return maxi(int(roundf(float(base_mag) * 1.0)), 1)


## Rounds a reload can still get (reserve + what the material can buy).
func reserve_count() -> int:
	return Game.ammo_available(ammo_id)


## The reserve itself (HUD: "mag / reserve").
func reserve_stock() -> int:
	return Game.ammo_reserve(ammo_id)


## Material per round when the reserve runs out (m³).
func round_cost() -> float:
	return float(Game.AMMO_COST.get(ammo_id, 0.0))


func mode_text() -> String:
	return ""


func hud_title() -> String:
	return ammo_title


func reload_label() -> String:
	return "DOLDURULUYOR" if reload_kind == "shell" else "ŞARJÖR DEĞİŞİYOR"


## Basis for a left-hand grip node: the glove's forearm points along `forearm` and the fist wraps
## around `grip_axis` (both in the parent's frame). The hand model's own forearm runs along
## HAND_FOREARM with the fist around its +Y axis (scripts/player/viewmodel.gd).
const HAND_FOREARM := Vector3(-0.4, -0.32, 0.86)
const Viewmodel := preload("res://scripts/player/viewmodel.gd")

static func hand_basis(forearm: Vector3, grip_axis: Vector3) -> Basis:
	return Viewmodel._map_basis(HAND_FOREARM, Vector3.UP, forearm, grip_axis)


func reload_progress() -> float:
	if not reloading:
		return 0.0
	if reload_kind == "mag":
		return clampf(_reload_t / maxf(_reload_total, 0.01), 0.0, 1.0)
	var per := 1.0 / float(maxi(_shell_need, 1))
	var u := 0.0
	if _shell_phase == 1:
		u = clampf(_shell_t / _shell_each(), 0.0, 1.0)
	elif _shell_phase == 2:
		return 1.0
	return clampf((float(_shell_done) + u) * per, 0.0, 1.0)


func hud_visible() -> bool:
	if player == null or not equipped or not active or player.vehicle != null:
		return false
	return true


func muzzle_world() -> Vector3:
	return _vm_world(_muzzle)


func _on_state_changed() -> void:
	if not active or not equipped:
		_ads_want = false
		_trig = false
		if reloading and not equipped:
			_cancel_reload()
		_restore_camera()
	elif equipped:
		_rk_vel += Vector4(-1.0, randf_range(-0.6, 0.6), randf_range(-0.5, 0.5), 0.0)


func _cancel_reload() -> void:
	reloading = false
	left_reach_w = 0.0
	_shell_phase = -1


## Per-weapon save data (scripts/player/player.gd stores it under "item_<id>").
func save_state() -> Dictionary:
	return {"mag": mag}


func load_state(d: Dictionary) -> void:
	mag = clampi(int(d.get("mag", mag)), 0, mag_capacity())


# =================================================================================================
# Input
# =================================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if debug_ignore_input or not can_operate():
		return
	var middle := event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE
	if (middle and event.is_pressed()) or (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == KEY_B):
		toggle_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tool_mode") and not middle:
		reload()
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and equipped and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look_acc += (event as InputEventMouseMotion).relative


## B / middle mouse: weapon-specific mode (launcher fuse mode). Default: nothing.
func toggle_mode() -> void:
	if Game.sfx:
		Game.sfx.play("error", -14.0)


func reload() -> void:
	if reloading or mag >= mag_capacity():
		return
	if reserve_count() <= 0:
		hud.empty_flash()
		if Game.sfx:
			Game.sfx.play("error", -12.0)
		return
	reloading = true
	_reload_empty = mag <= 0
	_ads_want = false
	if reload_kind == "mag":
		_reload_t = 0.0
		_reload_total = reload_empty_time if _reload_empty else reload_time
		_reload_ev = 0
	else:
		_shell_phase = 0
		_shell_t = 0.0
		_shell_done = 0
		_shell_need = mini(mag_capacity() - mag, reserve_count())
		_shell_interrupt = false
		_shell_ev = 0
	_on_reload_start()


func _on_reload_start() -> void:
	pass


func _shell_each() -> float:
	return shell_each


# =================================================================================================
# Firing
# =================================================================================================

func _physics_process(delta: float) -> void:
	_cooldown -= delta
	if not can_operate() or player == null or player.vehicle != null:
		_trigger_prev = false
		_trig = false
		_ads_want = false
		_idle_tick(delta)
		return
	var real := not debug_ignore_input and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var trig := (real and Input.is_action_pressed("tool_use")) or debug_trigger
	# just_pressed also catches a click shorter than one physics tick.
	var pressed := (trig and not _trigger_prev) or (real and Input.is_action_just_pressed("tool_use"))
	_trigger_prev = trig
	_trig = trig
	var up: Vector3 = player.global_transform.basis.y
	var hv: Vector3 = player.velocity - up * player.velocity.dot(up)
	# Sprint pose follows the player's run (kept through a hop), not is_on_floor().
	_sprint = (debug_sprint or (real and Input.is_action_pressed("sprint"))) and hv.length() > 5.0 \
			and (float(player.get("_sprint_k")) > 0.5 or debug_sprint) and ads < 0.2 and _sprint_allowed()
	_since_sprint = 0.0 if _sprint else _since_sprint + delta
	var alt := (real and Input.is_action_pressed("tool_alt")) or debug_ads
	_ads_want = alt and can_ads and not _sprint and not reloading
	_trigger(trig, pressed, alt, delta)


func _sprint_allowed() -> bool:
	return true


func _idle_tick(_delta: float) -> void:
	pass


## Default trigger: semi / full auto. Subclasses may replace it (minigun spin-up).
func _trigger(trig: bool, pressed: bool, _alt: bool, _delta: float) -> void:
	if reloading:
		if reload_kind == "shell" and pressed and mag > 0:
			_shell_interrupt = true
		return
	if _cooldown > 0.0 or _since_sprint < sprint_to_fire:
		return
	if not player.viewmodel.is_raised():
		return
	if not trig or (not auto_fire and not pressed):
		return
	if mag <= 0:
		if pressed:
			_dry_fire()
		return
	fire()


func _dry_fire() -> void:
	if Game.sfx:
		Game.sfx.play("click", -4.0, 1.3)
	_play("dry", -6.0, 1.0)
	hud.empty_flash()
	if reserve_count() > 0:
		reload()


## One trigger pull's worth: ammo, cooldown, recoil, flash, sound, noise; _fire_shot() does the rest.
func fire() -> void:
	mag -= 1
	_cooldown = 1.0 / fire_rate
	shots_fired += 1
	var cam: Camera3D = player.camera
	var cb := cam.global_transform.basis
	var fwd := -cb.z
	var up: Vector3 = player.global_transform.basis.y
	var muzzle := muzzle_world()
	_fire_shot(player.aim_origin(), fwd, cb, muzzle)
	Game.shot_fired.emit(player.aim_origin(), fwd, "home")     # rival bots react (ai_rival.gd)
	_bloom = minf(_bloom + bloom_add, bloom_max)
	var aim := clampf(ads, 0.0, 1.0)
	var rec := 1.0
	var aim_k := (1.0 - aim * 0.35) * rec
	_recoil_target += Vector2(kick_pitch * randf_range(0.85, 1.2), randf_range(-1.0, 1.0) * kick_yaw) * aim_k
	_recoil_target.x = minf(_recoil_target.x, 0.22)
	# The kick snaps in (camera recoil + a little roll) and recovers fast (see _process).
	_recoil = _recoil.lerp(_recoil_target, 0.35)
	_roll_v += randf_range(-1.0, 1.0) * kick_roll * 60.0 * aim_k
	_trauma = minf(_trauma + shake_amt * aim_k, 1.0)
	_fov_punch += fov_punch_amt * rec
	var gk := gun_kick * rec
	var hip_k := 1.0 - aim * 0.55
	_rk_vel += Vector4(gk * 0.95 * hip_k, randf_range(-1.0, 1.0) * gk * 0.14 * hip_k,
			randf_range(-1.0, 1.0) * gk * 0.12 * hip_k, gk * 0.6 * lerpf(1.0, 0.45, aim))
	_since_shot = 0.0
	_use_t = 0.09
	_muzzle_fx(muzzle, fwd, up, cb)
	_fire_sound()
	if mag == 0 and reserve_count() > 0:
		_cooldown = maxf(_cooldown, 0.3)


## Fires the projectile(s) of one shot. Default: one bullet through the fx.
func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var dir := _spread_dir(fwd, cb, current_spread())
	fx.bullet(eye, dir * 700.0 + player.velocity, muzzle, 0, accent, false, 0)


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, _cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(1.0)
	fx.muzzle_light(muzzle + fwd * 0.9, Color(1.0, 0.72, 0.38), muzzle_energy, 0.045, 12.0)
	fx.muzzle_smoke(muzzle + fwd * 0.15, fwd, up)


func _fire_sound() -> void:
	pass


## Shared gunshot weight: the sub-bass punch and, outdoors, the terrain slap-back.
func _shot_body(space: int, pitch := 1.0, echo_db := -13.0) -> void:
	if punch_db > -60.0:
		_play("punch", punch_db, pitch * randf_range(0.95, 1.05), true)
	if space == 2 and echo_db > -60.0:
		_play("echo", echo_db, randf_range(0.9, 1.05) * pitch, true)


func _spread_dir(fwd: Vector3, cb: Basis, spread: float) -> Vector3:
	if spread <= 0.0:
		return fwd
	var ang := randf() * TAU
	var r := sqrt(randf()) * spread
	return (fwd + cb.x * cos(ang) * r + cb.y * sin(ang) * r).normalized()


func current_spread() -> float:
	var aim := clampf(ads, 0.0, 1.0)
	var mv := 0.0
	if player != null:
		var up: Vector3 = player.global_transform.basis.y
		var hv: Vector3 = player.velocity - up * player.velocity.dot(up)
		mv = clampf(hv.length() / 6.0, 0.0, 1.0) * 0.014 + (0.0 if player.is_on_floor() else 0.016)
	var base := lerpf(spread_hip, spread_ads, aim) * 1.0
	return base + _bloom * (1.0 - aim * 0.6) + mv * (1.0 - aim * 0.6)


## Damage of one bullet / pellet that hit at `p` (subclasses add falloff).
func _hit_damage(_p: Vector3, _ammo: int) -> float:
	return 20.0 * 1.0


func _hit_impulse(_ammo: int) -> float:
	return 6.0


## Called by the fx node for every bullet / pellet hit. Returns true when it stops.
## info["type"]: "body" (a damageable: info["target"]), "terrain", "metal".
func bullet_hit(info: Dictionary, dir: Vector3, ammo: int, _pierced: int) -> bool:
	var p: Vector3 = info["point"]
	var n: Vector3 = info["normal"]
	last_impact = p
	var src: Vector3 = player.global_position if player != null else p - dir * 30.0
	match info["type"]:
		"body":
			var t = info["target"]
			var dmg := _hit_damage(p, ammo)
			var r := Game.damage_target(t, dmg, src, dir * _hit_impulse(ammo) * 0.15, "home")
			fx.impact_metal(p, n, dir, false)
			hits += 1
			HitFeel.inst().target_hit(t, r, dmg, p, {"big": hit_big})
		"terrain":
			fx.impact_terrain(p, n, dir, _ground_color(p, n), false, hit_big > 0.4)
		"metal":
			fx.impact_metal(p, n, dir, false)
	return true


# =================================================================================================
# Per-frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	var on := player != null and equipped and active and player.vehicle == null
	using = _use_t > 0.0
	_use_t = maxf(_use_t - delta, 0.0)
	var dt := minf(delta, 0.033)
	var want := _ads_want and on
	var k := 110.0 if want else 170.0
	var c := 13.5 if want else 25.0
	_ads_vel += (((1.0 if want else 0.0) - ads) * k - _ads_vel * c) * dt
	ads = clampf(ads + _ads_vel * dt, -0.05, 1.1)
	sway_scale = lerpf(_hip_sway(), 0.45, clampf(ads, 0.0, 1.0))
	if reloading:
		_tick_reload(delta)
	_recoil = _recoil.lerp(_recoil_target, 1.0 - exp(-60.0 * delta))
	var rec := lerpf(10.5, 12.5, clampf(ads, 0.0, 1.0))
	_recoil_target = _recoil_target.lerp(Vector2.ZERO, 1.0 - exp(-rec * delta))
	_roll_v += (-_roll * 420.0 - _roll_v * 26.0) * dt
	_roll += _roll_v * dt
	_trauma = maxf(_trauma - delta * 2.6, 0.0)
	_fov_punch = lerpf(_fov_punch, 0.0, 1.0 - exp(-12.0 * delta))
	_since_shot += delta
	if _since_shot > 0.15:
		_bloom = maxf(_bloom - delta * bloom_max * 1.5, 0.0)
	# Shots set _flash_t = 1 in the physics step; let that frame render at full strength first
	# (decaying it here right away hid the flash at 60 fps and below).
	_flash_t = maxf(_flash_t - delta / 0.05, 0.0) if _flash_t < 1.0 else 0.999
	_rk_vel += (-_rk * 280.0 - _rk_vel * 21.0) * dt
	_rk += _rk_vel * dt
	_reload_w = move_toward(_reload_w, 1.0 if (reloading and _reload_pose_wanted()) else 0.0, dt / 0.22)
	_update_fades(delta)
	_tick(delta, on)
	if on:
		_apply_camera()
	else:
		_restore_camera()
	_update_pose(dt, on)
	_animate_model(delta)


func _hip_sway() -> float:
	return 1.6


## Extra per-frame logic (heat, spin...).
func _tick(_delta: float, _on: bool) -> void:
	pass


func _reload_pose_wanted() -> bool:
	if reload_kind == "mag":
		var u := reload_progress()
		return u < 0.9
	return _shell_phase >= 0 and _shell_phase < 2 or (_shell_phase == 2 and _shell_t < _shell_end_time() * 0.5)


func _shell_end_time() -> float:
	return shell_end_empty if _reload_empty else shell_end


func _tick_reload(delta: float) -> void:
	if reload_kind == "mag":
		_reload_t += delta
		_reload_events(reload_progress())
		if _reload_t >= _reload_total:
			_finish_mag_reload()
		return
	_shell_t += delta
	match _shell_phase:
		0:
			_shell_events(0, clampf(_shell_t / shell_start, 0.0, 1.0))
			if _shell_t >= shell_start:
				_shell_t = 0.0
				_shell_ev = 0
				_shell_phase = 2 if (_shell_interrupt or _shell_need <= 0) else 1
		1:
			_shell_events(1, clampf(_shell_t / _shell_each(), 0.0, 1.0))
			if _shell_t >= _shell_each():
				_shell_t = 0.0
				_shell_ev = 0
				if reserve_count() > 0 and mag < mag_capacity():
					mag += Game.take_ammo(ammo_id, 1)
					_shell_done += 1
				if _shell_interrupt or mag >= mag_capacity() or reserve_count() <= 0 or _shell_done >= _shell_need:
					_shell_phase = 2
		2:
			_shell_events(2, clampf(_shell_t / _shell_end_time(), 0.0, 1.0))
			if _shell_t >= _shell_end_time():
				reloading = false
				_shell_phase = -1
				left_reach_w = 0.0
				_on_reload_done()


func _finish_mag_reload() -> void:
	reloading = false
	left_reach_w = 0.0
	var take := mini(mag_capacity() - mag, reserve_count())
	if take > 0:
		mag += Game.take_ammo(ammo_id, take)
	_on_reload_done()


func _on_reload_done() -> void:
	pass


## Magazine reload sound / kick events (u = 0..1). Default: rifle-like magazine foley.
func _reload_events(u: float) -> void:
	var marks := [0.06, 0.15, 0.25, 0.62, 0.7, 0.82, 0.9]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -16.0, randf_range(0.9, 1.1))
			1:
				_play("mag_release", -9.0, 0.85)
			2:
				_play("mag_out", -8.0, 0.85)
			3:
				_play("mag_in", -6.0, 0.85)
				_rk_vel.w += 0.25
			4:
				_play("mag_slap", -5.0, 0.9)
				_rk_vel.x += 0.6
			5:
				if _reload_empty:
					_play("bolt_back", -6.0, 0.85)
			6:
				if _reload_empty:
					_play("bolt_fwd", -4.0, 0.85)
					_rk_vel += Vector4(0.8, 0.0, 0.0, 0.3)
		_reload_ev += 1


## Shell reload events: phase 0 start, 1 one shell (u 0..1), 2 end.
func _shell_events(_phase: int, _u: float) -> void:
	pass


func _apply_camera() -> void:
	var cam: Camera3D = player.camera
	var e := _smooth(clampf(ads, 0.0, 1.0))
	cam.fov = lerpf(Settings.fov, ads_fov * 1.0, e) + _fov_punch
	var sh := _trauma * _trauma
	var shake := Vector3(sin(_t * 67.0) + sin(_t * 29.0) * 0.6, sin(_t * 59.0 + 1.3) + sin(_t * 19.0) * 0.5,
			sin(_t * 43.0 + 0.7)) * sh * 0.016
	var breath := Vector2(sin(_t * 1.1) * 0.0018 + sin(_t * 0.43) * 0.001, sin(_t * 0.8 + 1.0) * 0.0024) * e * 1.0
	cam.rotation += Vector3(_recoil.x + shake.x + breath.y, _recoil.y + shake.y + breath.x, shake.z + _roll)
	if Game.hud != null and Game.hud.get("crosshair") != null:
		Game.hud.crosshair.modulate.a = 0.0
	if "move_speed_mult" in player:
		player.set("move_speed_mult", _move_mult(e))
	if "look_scale" in player:
		player.set("look_scale", lerpf(1.0, 0.75, e))
	_cam_dirty = true


func _move_mult(e: float) -> float:
	return lerpf(1.0, aim_speed, e)


func _restore_camera() -> void:
	if not _cam_dirty or player == null:
		return
	_cam_dirty = false
	var cam: Camera3D = player.camera
	# Ease out of the aim instead of snapping the view (swapping while aimed / mid-recoil).
	if absf(cam.fov - Settings.fov) > 0.5:
		cam.create_tween().tween_property(cam, "fov", Settings.fov, 0.18)
	else:
		cam.fov = Settings.fov
	if "_punch" in player:
		player._punch += Vector3(cam.rotation.x, cam.rotation.y, 0.0)
	cam.rotation = Vector3.ZERO
	if Game.hud != null and Game.hud.get("crosshair") != null:
		Game.hud.crosshair.modulate.a = 1.0
	if "move_speed_mult" in player:
		player.set("move_speed_mult", 1.0)
	if "look_scale" in player:
		player.set("look_scale", 1.0)
	_recoil = Vector2.ZERO
	_recoil_target = Vector2.ZERO
	_roll = 0.0
	_roll_v = 0.0
	ads = 0.0
	_ads_vel = 0.0


static func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


static func _seg(u: float, a: float, b: float) -> float:
	return _smooth((u - a) / (b - a))


func _hip_pose() -> Transform3D:
	var bore := hip_pos + Vector3(0.0, hip_bore_y, 0.0)
	var d := (Vector3(0.0, 0.0, -hip_converge) - bore).normalized()
	var b := Basis.looking_at(d, Vector3.UP) * Basis(Vector3.BACK, hip_cant)
	return Transform3D(b, hip_pos)


## Gun-frame point that the aim pose puts on the camera axis.
func sight_point() -> Vector3:
	return sight_rear


func _ads_pose() -> Transform3D:
	return Transform3D(Basis(), ads_eye - sight_point())


static func _pose_from(origin: Vector3, euler: Vector3) -> Transform3D:
	return Transform3D(Basis.from_euler(euler), origin)


static func _blend(a: Transform3D, b: Transform3D, w: float) -> Transform3D:
	var q := Quaternion(a.basis.orthonormalized()).slerp(Quaternion(b.basis.orthonormalized()), clampf(w, 0.0, 1.0))
	return Transform3D(Basis(q), a.origin.lerp(b.origin, w))


## Extra pose offset (camera space) on top of the blended pose: subclasses (pump kick, spin shake).
func _pose_extra() -> Transform3D:
	return Transform3D()


func _update_pose(dt: float, on: bool) -> void:
	if player == null:
		return
	var aim := clampf(ads, 0.0, 1.0)
	var up: Vector3 = player.global_transform.basis.y
	var vel: Vector3 = player.velocity
	var v_up := vel.dot(up)
	var hspeed := (vel - up * v_up).length()
	var grounded: bool = player.is_on_floor()
	var rate := 1.0 - exp(-10.0 * dt)
	_sprint_w = move_toward(_sprint_w, 1.0 if (_sprint and on) else 0.0, dt / 0.22)
	var hip := _hip_pose()
	var pose := _blend(hip, _ads_pose(), aim)
	if ads > 1.0:
		pose.origin = hip.origin.lerp(_ads_pose().origin, ads)
	pose = _blend(pose, _pose_from(sprint_pos, sprint_rot), _smooth(_sprint_w))
	pose = _blend(pose, _pose_from(reload_pos, reload_rot), _smooth(_reload_w))
	var bob_target := clampf(hspeed / 4.5, 0.0, 1.6) if grounded else 0.0
	_bob_amt = lerpf(_bob_amt, bob_target, rate * 0.6)
	if grounded and player.get("astronaut") != null:
		_bob_ph = float(player.astronaut._phase) * TAU + PI * 0.5     # the body's gait: dip as a foot plants
	var bk := _bob_amt * (1.0 - aim * 0.85) * (1.0 + _sprint_w * 0.6)
	var bob := Vector3(cos(_bob_ph) * 0.011, -absf(sin(_bob_ph)) * 0.014, 0.0) * bk
	var bob_rot := Vector3(-absf(sin(_bob_ph)) * 0.01, cos(_bob_ph) * 0.012, cos(_bob_ph) * 0.022) * bk
	var look := _look_acc * (1.0 / 60.0) / maxf(dt, 0.001)     # per-frame mouse counts → 60 fps units
	_look_acc = Vector2.ZERO
	var sk := lerpf(1.0, 0.25, aim) * (0.6 if reloading else 1.0) * clampf(_hip_sway() / 1.6, 0.5, 1.6)
	var sway_target := Vector2(clampf(-look.x * 0.0013, -0.07, 0.07), clampf(-look.y * 0.0013, -0.06, 0.06)) * sk
	_sway_vel += ((sway_target - _sway) * 160.0 - _sway_vel * 17.0) * dt
	_sway += _sway_vel * dt
	_vy = lerpf(_vy, clampf(-v_up * 0.006, -0.04, 0.05), rate * 0.5)
	var breathe := Vector3(0.0, sin(_t * 1.6) * 0.0025, 0.0) * (1.0 - aim)
	var off := bob + breathe + Vector3(_sway.x * 0.12, _sway.y * 0.1 + _vy * (1.0 - aim * 0.6), 0.0)
	var rot := bob_rot + Vector3(_sway.y * 0.9, _sway.x * 1.1, _sway.x * 0.7)
	var xf := Transform3D(Basis.from_euler(rot) * pose.basis, pose.origin + off)
	var rk_rot := Basis.from_euler(Vector3(_rk.x, _rk.y, _rk.z))
	var rk_xf := Transform3D(Basis(), recoil_pivot) * Transform3D(rk_rot, Vector3.ZERO) * Transform3D(Basis(), -recoil_pivot)
	rk_xf.origin += Vector3(0.0, 0.0, _rk.w)
	pose_override = _pose_extra() * xf * rk_xf


## Model animation (parts, flash, reload choreography). Subclasses extend.
func _animate_model(_delta: float) -> void:
	if _flash_root != null:
		_flash_root.visible = _flash_t > 0.0
		if _flash_t > 0.0:
			_flash_mat.set_shader_parameter("energy", 12.0 * _flash_t)


func _randomize_flash(size: float) -> void:
	if _flash_root == null:
		return
	_flash_root.scale = Vector3.ONE * randf_range(0.85, 1.3) * size
	_flash_root.rotation.z = randf() * TAU
	_flash_mat.set_shader_parameter("seed", randf() * 10.0)


func _vm_world(n: Node3D) -> Vector3:
	var cam: Camera3D = player.camera
	if n == null:
		return cam.global_position - cam.global_transform.basis.z * 0.6
	return VM.vm_to_world(cam, n.global_position)


func _ground_color(p: Vector3, n: Vector3) -> Color:
	return Rifle.ground_color(p, n)


## Muzzle flash quads (same star shader as the rifle), parented at `pos` in the gun frame.
func _make_flash(parent: Node3D, pos: Vector3, size: float, col := Color(1.0, 0.62, 0.22)) -> void:
	_flash_root = VM.node(parent, pos)
	var fs := Shader.new()
	fs.code = VM.prep(Rifle.FLASH_SHADER)
	_flash_mat = ShaderMaterial.new()
	_flash_mat.shader = fs
	_flash_mat.set_shader_parameter("color", col)
	var q := QuadMesh.new()
	q.size = Vector2(0.17, 0.17) * size
	var front := VM.mesh_inst(_flash_root, q, _flash_mat)
	front.position = Vector3(0, 0, -0.02)
	var side := QuadMesh.new()
	side.size = Vector2(0.09, 0.26) * size
	for k in 2:
		var mi := VM.mesh_inst(_flash_root, side, _flash_mat)
		mi.transform = Transform3D(Basis(Vector3.FORWARD, k * PI * 0.5) * Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 0, -0.11 * size))
	_flash_root.visible = false


## Holographic sight on a rail (gun frame), its reticle dot on the line y = optic_y.
func _make_optic(parent: Node3D, z: float, rail_y: float, col := Color(1.0, 0.25, 0.2)) -> Node3D:
	return VM.holo_sight(parent, z, rail_y, optic_y, col)


# =================================================================================================
# Third-person prop
# =================================================================================================

func _build_tp_prop() -> void:
	if player == null:
		return
	var ast = player.get("astronaut")
	if ast == null or not ("props" in ast) or not ("hand" in ast):
		return
	if ast.props.has(icon):
		_tp_tip = ast.prop_tips.get(icon)
		return
	var hands: Array = ast.hand
	if hands.size() < 2 or hands[1] == null:
		return
	var p := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
	_tp_tip = _build_tp(p)
	p.visible = false
	ast.props[icon] = p
	ast.prop_tips[icon] = _tp_tip
	var list = ast.get("_meshes")
	for mi in p.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).layers = 2
		if list is Array:
			list.append(mi)
	if ast.has_method("set_first_person"):
		ast.set_first_person(not player.is_ragdolled())


## Builds the simplified third-person model under `p` (grip at the origin, -Z forward); returns the
## muzzle node.
func _build_tp(p: Node3D) -> Node3D:
	return VM.node(p, Vector3(0, 0.06, -0.6))


func _tp_mat(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


# =================================================================================================
# Audio (same Weapons bus as the rifle; synthesized layers shared by every arsenal weapon)
# =================================================================================================

func _setup_audio() -> void:
	var bus := Rifle._weapons_bus()
	for i in 12:
		var p := AudioStreamPlayer.new()
		p.bus = bus
		add_child(p)
		_gun_audio.append(p)
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_aux_audio.append(p)
	# Recorded shots (assets/audio/sonniss/weap): 5.56 / 7.62 rifles, 12 gauge, .30 cal MG.
	_snd["shot"] = Snd.set_of("weap/rifle_shot")
	_snd["heavy"] = Snd.set_of("weap/rifle_heavy")
	_snd["shotgun"] = Snd.set_of("weap/shotgun")
	_snd["mg"] = Snd.set_of("weap/mg")
	if _synth.is_empty() and _synth_task < 0:
		_synth_task = WorkerThreadPool.add_task(_build_synth, false, "arsenal_audio")


func _build_synth() -> void:
	var gen := ArsenalAudio.new()
	var out := {}
	for n in WeaponAudio.NAMES + ArsenalAudio.ARSENAL_NAMES:
		out[n] = [gen.make(n)]
	_synth_mutex.lock()
	_synth_ready = out
	_synth_mutex.unlock()


static func _finish_synth() -> void:
	_synth_task = -1
	_synth_mutex.lock()
	_synth = _synth_ready
	_synth_mutex.unlock()


func _load_set(pattern: String, n: int) -> Array:
	var out: Array = []
	for i in n:
		var path := pattern % i if pattern.contains("%") else pattern
		if ResourceLoader.exists(path):
			var s = load(path)
			if s != null:
				out.append(s)
	return out


func synth_stream(name: String) -> AudioStream:
	return _stream(name)


func _stream(name: String) -> AudioStream:
	if _synth_task >= 0 and WorkerThreadPool.is_task_completed(_synth_task):
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_finish_synth()
	var arr: Array = _snd.get(name, [])
	if arr.is_empty():
		arr = _synth.get(name, [])
	if arr.is_empty():
		return null
	return arr[randi() % arr.size()]


func _play(name: String, vol := 0.0, pitch := 1.0, weapons_bus := false, cut := 0.0) -> AudioStreamPlayer:
	var st := _stream(name)
	if st == null:
		return null
	var p: AudioStreamPlayer
	if weapons_bus:
		p = _gun_audio[_gun_audio_i]
		_gun_audio_i = (_gun_audio_i + 1) % _gun_audio.size()
	else:
		p = _aux_audio[_aux_i]
		_aux_i = (_aux_i + 1) % _aux_audio.size()
	p.stream = st
	p.volume_db = vol
	p.pitch_scale = pitch
	p.play()
	for f in _fades:
		if f[0] == p:
			_fades.erase(f)
			break
	if cut > 0.0:
		_fades.append([p, cut, vol])
	if debug_audio_log:
		audio_log.append(name)
	return p


func _update_fades(delta: float) -> void:
	if _fades.is_empty():
		return
	var keep: Array = []
	for f in _fades:
		var p: AudioStreamPlayer = f[0]
		f[1] = float(f[1]) - delta
		if float(f[1]) > 0.0:
			keep.append(f)
			continue
		var k := clampf(1.0 + float(f[1]) / FADE_LEN, 0.0, 1.0)
		if k <= 0.0 or not p.playing:
			p.stop()
			continue
		p.volume_db = float(f[2]) + linear_to_db(maxf(k * k, 0.0001))
		keep.append(f)
	_fades = keep


## Open air / tunnel for the reverb (same rules as the rifle).
func _space_kind() -> int:
	if player == null:
		return 2
	var hd: Vector3 = player.camera.global_position
	var upv: Vector3 = player.global_transform.basis.y
	var q := PhysicsRayQueryParameters3D.create(hd, hd + upv * 25.0, Game.LAYER_TERRAIN | Game.LAYER_SHIP)
	if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return 1
	return 2


func _set_space(kind: int) -> void:
	var idx := AudioServer.get_bus_index("Weapons")
	if idx < 0:
		return
	for e in AudioServer.get_bus_effect_count(idx):
		var rv := AudioServer.get_bus_effect(idx, e) as AudioEffectReverb
		if rv == null:
			continue
		match kind:
			0:
				rv.room_size = 0.25
				rv.wet = 0.05
				rv.predelay_msec = 12.0
			1:
				rv.room_size = 0.6
				rv.wet = 0.18
				rv.predelay_msec = 35.0
			_:
				rv.room_size = 0.85
				rv.wet = 0.14
				rv.predelay_msec = 70.0
