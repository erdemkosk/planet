extends "res://scripts/items/item.gd"
## Tüfek (key 2) firing real bullets: ballistic projectiles with drop (Game.gravity_at) and tracers.
## Ammo types (each keeps its own loaded magazine in the gun; reserves live in Game.ammo and a
## reload buys any shortfall from material, Game.take_ammo):
##   STANDART      full-metal-jacket (single shot or 3-round burst)
##   DELİCİ        armor-piercing, heavy hit, punches through one target
## Timing is deliberately realistic: 0.6 s draw, ~0.3 s raise to the iron sights (spring with a
## small overshoot), 0.25 s sprint-to-fire, 2.4 s tactical / 3.0 s empty reload, and switching
## ammo means a magazine change. LMB fires, RMB aims (rear notch + front post on the screen
## center, mild zoom, half walking speed), R reloads, T switches ammo, B / middle mouse burst.
## Each shot: recorded gunshot + low body + sub-bass punch + bolt clack + outdoor tail and terrain
## slap-back, camera kick (with a little roll) that snaps in and recovers fast, 6-8 cm kickback and
## muzzle climb, bolt cycling, muzzle flash, light, smoke and brass. Hits on anything in group
## "damageable" go through Game.damage_target (the AI rival bot later). During reloads the left
## hand really fetches and seats the magazine.

const Settings := preload("res://scripts/save/settings.gd")
const RifleFx := preload("res://scripts/items/rifle_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const RifleHud := preload("res://scripts/items/rifle_hud.gd")
const WeaponAudio := preload("res://scripts/items/weapon_audio.gd")
const Viewmodel := preload("res://scripts/player/viewmodel.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")

const HIP_FOV := 75.0
const ADS_FOV := 58.0
const SIGHT_Y := 0.118                               # sight line height in the gun frame
const SIGHT_REAR := Vector3(0.0, SIGHT_Y, 0.03)      # rear sight notch (gez)
const SIGHT_FRONT_Z := -0.43                         # front sight post (arpacık)
const ADS_EYE := Vector3(0.0, 0.0, -0.26)            # rear notch position in camera space when aiming
# Weapon poses in camera space (the grip is the rig origin, the gun points along its -Z).
const HIP_POS := Vector3(0.165, -0.215, -0.4)        # grip at the hip: low right, stock to the shoulder
const HIP_CONVERGE := 11.0                            # bore aims at the crosshair this far ahead (m)
const HIP_CANT := 0.07                                # slight inward roll
const SPRINT_POS := Vector3(0.15, -0.16, -0.4)
const SPRINT_ROT := Vector3(-0.2, 0.62, 0.3)          # lowered, muzzle across the body, canted
const RELOAD_POS := Vector3(0.15, -0.2, -0.4)
const RELOAD_ROT := Vector3(0.1, 0.2, 0.3)            # tilted to show the magazine well
const RECOIL_PIVOT := Vector3(0.0, 0.05, 0.24)        # the gun rotates about the stock
const AIM_SPEED := 0.5                               # walking speed multiplier while aiming
const SPRINT_TO_FIRE := 0.25
const MAG_REST := Vector3(0.0, 0.02, -0.085)
const MAG_AXIS := Vector3(0.0, -0.993, -0.12)        # magazine slides out along this (model space)

## dmg per round (player hp 100); impulse = shove on a hit body (x 0.15, m/s); pierce = bodies an
## AP round passes through; roll = camera roll kick. "punch" / "armor" / "stun" are unused for now.
const AMMO := [
	{"id": "ammo_std", "name": "STANDART", "short": "STD", "title": "Standart Mermi (FMJ)",
		"color": Color(1.0, 0.78, 0.38), "dmg": 38.0, "rate": 5.5, "auto": false, "mag": 30, "burst_rate": 11.0,
		"reload": 2.4, "reload_empty": 3.0, "speed": 780.0, "spread": 0.0105, "ads_spread": 0.0003,
		"kick_pitch": 0.058, "kick_yaw": 0.014, "roll": 0.012, "vm_kick": 0.75, "gun_kick": 6.0, "shake": 0.38,
		"fov_punch": -2.4, "stun": 0.0, "impulse": 7.0, "punch": 1.0, "armor": 0.15, "noise": 50.0, "pierce": 0,
		"dart": false, "sound": "shot", "flash": 1.0, "sub": -7.0},
	{"id": "ammo_ap", "name": "DELİCİ", "short": "DLC", "title": "Delici Mermi (AP)",
		"color": Color(1.0, 0.45, 0.3), "dmg": 88.0, "rate": 2.2, "auto": false, "mag": 10,
		"reload": 2.5, "reload_empty": 3.1, "speed": 850.0, "spread": 0.008, "ads_spread": 0.0002,
		"kick_pitch": 0.085, "kick_yaw": 0.02, "roll": 0.02, "vm_kick": 1.3, "gun_kick": 8.5, "shake": 0.65,
		"fov_punch": -3.6, "stun": 0.0, "impulse": 12.0, "punch": 1.6, "armor": 0.7, "noise": 65.0, "pierce": 1,
		"dart": false, "sound": "heavy", "flash": 1.5, "sub": -4.0},
]

const FLASH_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, depth_test_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.8, 0.4, 1.0);
uniform float energy = 4.0;
uniform float seed = 0.0;

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.95);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float ang = atan(p.y, p.x);
	float star = 0.35 + 0.65 * pow(abs(cos(ang * 2.5 + seed)), 6.0);
	float a = 1.0 - smoothstep(0.0, 1.0, r / star);
	a = a * a;
	float core = 1.0 - smoothstep(0.0, 0.3, r);
	ALBEDO = (color.rgb * a + vec3(1.0, 0.95, 0.85) * core) * energy;
	ALPHA = clamp(a + core, 0.0, 1.0);
}
"""

# Read by the view model.
var pose_override := Transform3D()  # full camera-space pose of the hand + gun rig (view model)
var draw_time := 0.6
var holster_time := 0.35
var sway_scale := 1.5
var left_reach := Vector3.ZERO
var left_reach_w := 0.0
var left_reach_elbow := Vector3(-0.3, -0.8, 0.52)

var ammo_type := 0
var mags := [30, 10]
var reloading := false
var burst_mode := false            # Standart: 3-round burst instead of single shots
var _burst_left := 0
var last_impact := Vector3.INF     # tests: where the last bullet landed
var ads := 0.0                     # 0 hip .. 1 aiming down the sights (spring, may overshoot)
var debug_trigger := false         # test hooks
var debug_ads := false
var debug_ignore_input := false    # tests: ignore real mouse / keyboard input
var debug_sprint := false
var fx
var hud
var shots_fired := 0
var hits := 0

var _ads_vel := 0.0
var _reload_t := 0.0
var _reload_total := 1.0
var _reload_to := 0
var _reload_switch := false
var _reload_empty := false
var _reload_ev := 0
var _cooldown := 0.0
var _trigger_prev := false
var _ads_want := false
var _bloom := 0.0
var _use_t := 0.0
var _recoil := Vector2.ZERO        # camera pitch / yaw offset (rad)
var _recoil_target := Vector2.ZERO
var _roll := 0.0                   # camera roll kick (spring)
var _roll_v := 0.0
var _trauma := 0.0
var _fov_punch := 0.0
var _t := 0.0
var _cam_dirty := false
var _heat := 0.0
var _flash_t := 0.0
var _rk := Vector4.ZERO            # gun recoil spring: pitch, yaw, roll (rad), kickback (m)
var _rk_vel := Vector4.ZERO
var _sprint_w := 0.0
var _bob_amt := 0.0
var _bob_ph := 0.0
var _sway := Vector2.ZERO
var _sway_vel := Vector2.ZERO
var _vy := 0.0
var _look_acc := Vector2.ZERO
var _since_shot := 9.0
var _bolt_t := 9.0                 # time since the last shot (charging handle cycle)
var _sprint := false
var _since_sprint := 9.0

# Model parts.
var _gun: Node3D
var _muzzle: Node3D
var _eject: Node3D
var _bolt: Node3D
var _mag: Node3D
var _mag_grab: Node3D
var _flash_root: Node3D
var _flash_mat: ShaderMaterial
var _accent_glow: ShaderMaterial
var _mag_glow: ShaderMaterial
var _led_mat: ShaderMaterial
var _led_off: ShaderMaterial
var _leds: Array = []
var _tp_tip: Node3D

# Audio.
var _gun_audio: Array = []
var _gun_audio_i := 0
var _aux_audio: Array = []
var _aux_i := 0
var debug_audio_log := false      # tests: record every sound started
var _fades: Array = []             # [player, seconds until fade, base volume]
const FADE_LEN := 0.07
var audio_log: Array = []
var _snd := {}
var _synth := {}
var _synth_task := -1
var _synth_ready := {}
var _synth_mutex := Mutex.new()


func _init() -> void:
	item_id = "rifle"
	item_name = "Tüfek"
	item_desc = "Sol tık: ateş · Sağ tık: gez-arpacıkla nişan al · R: şarjör · T: mermi türü (Standart, Delici) · B / orta tık: tek ↔ 3'lü seri."
	icon = "rifle"


func _ready() -> void:
	fx = RifleFx.new()
	fx.rifle = self
	add_child(fx)
	hud = RifleHud.new()
	hud.rifle = self
	add_child(hud)
	_setup_audio()
	call_deferred("_build_tp_prop")


func _exit_tree() -> void:
	if _synth_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_synth_task = -1


# =================================================================================================
# Item interface
# =================================================================================================

func accent_color() -> Color:
	return ammo_color()


func status_text() -> String:
	return "%d/%d" % [mag_count(), reserve_count()]


func hud_hint() -> String:
	return "[color=#%s][b]%s[/b][/color]  [color=#dfefff]%d[/color][color=#8fa3b5]/%d · Sağ tık: nişan · R: şarjör · T: mermi[/color]" % [
		ammo_color().to_html(false), ammo_name(), mag_count(), reserve_count()]


func _on_state_changed() -> void:
	if not active or not equipped:
		_ads_want = false
		if reloading and not equipped:
			reloading = false     # put away mid-reload: start over next time
			left_reach_w = 0.0
		_restore_camera()
	elif equipped:
		# Freshly raised: a little settle wobble.
		_rk_vel += Vector4(-1.0, randf_range(-0.6, 0.6), randf_range(-0.5, 0.5), 0.0)


# =================================================================================================
# HUD / query helpers
# =================================================================================================

func ammo_types() -> int:
	return AMMO.size()


func _ai(i: int) -> int:
	return ammo_type if i < 0 else i


func ammo_color(i := -1) -> Color:
	return AMMO[_ai(i)]["color"]


func ammo_name(i := -1) -> String:
	return AMMO[_ai(i)]["name"]


func ammo_short(i := -1) -> String:
	return AMMO[_ai(i)]["short"]


func ammo_title(i := -1) -> String:
	return AMMO[_ai(i)]["title"]


func mag_count(i := -1) -> int:
	return mags[_ai(i)]


func mag_capacity(i := -1) -> int:
	return int(roundf(float(AMMO[_ai(i)]["mag"]) * 1.0))


## Rounds a reload of this ammo type can still get (reserve + what the material can buy).
func reserve_count(i := -1) -> int:
	return Game.ammo_available(AMMO[_ai(i)]["id"])


## The reserve itself (HUD: "mag / reserve").
func reserve_stock(i := -1) -> int:
	return Game.ammo_reserve(AMMO[_ai(i)]["id"])


## Material per round of the current type when the reserve runs out (m³).
func round_cost() -> float:
	return float(Game.AMMO_COST.get(AMMO[ammo_type]["id"], 0.0))


func reload_progress() -> float:
	return clampf(_reload_t / maxf(_reload_total, 0.01), 0.0, 1.0)


func switching() -> bool:
	return reloading and _reload_switch


func hud_visible() -> bool:
	if player == null or not equipped or not active or player.vehicle != null:
		return false
	return true


## Muzzle position in the world (first person: where the view-model muzzle appears on screen).
func muzzle_world() -> Vector3:
	return _vm_world(_muzzle)


# =================================================================================================
# Input
# =================================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if debug_ignore_input or not can_operate():
		return
	var middle := event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE
	if (middle and event.is_pressed()) or (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == KEY_B):
		toggle_fire_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tool_mode") and not middle:
		reload()
		get_viewport().set_input_as_handled()
	# (No mouse wheel here: a stray scroll used to start a full magazine change mid-fight. T only.)
	elif event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).physical_keycode == KEY_T:
		switch_ammo(1)
		get_viewport().set_input_as_handled()


## Standart rounds: single shot <-> 3-round burst (B or middle mouse button).
func toggle_fire_mode() -> void:
	if not AMMO[ammo_type].has("burst_rate"):
		if Game.sfx:
			Game.sfx.play("error", -14.0)
		return
	burst_mode = not burst_mode
	_burst_left = 0
	if Game.sfx:
		Game.sfx.play("click", -8.0, 0.8 if burst_mode else 1.1)
	_play("selector", -10.0, 0.9 if burst_mode else 1.1)
	hud.ammo_switched()


func reload() -> void:
	if reloading:
		return
	if mags[ammo_type] >= mag_capacity():
		return
	if reserve_count() <= 0:
		hud.empty_flash()
		if Game.sfx:
			Game.sfx.play("error", -12.0)
		return
	_start_reload(ammo_type, false)


## Switches to the next ammo type (step ±1): that is a full magazine change.
func switch_ammo(step: int) -> void:
	if reloading:
		return
	var n := AMMO.size()
	var to := (ammo_type + step + n) % n
	if mags[to] <= 0 and reserve_count(to) <= 0:
		hud.empty_flash()
		if Game.sfx:
			Game.sfx.play("error", -12.0)
		return
	_start_reload(to, true)
	_play("selector", -8.0, 0.85)
	hud.ammo_switched()


func _start_reload(to: int, is_switch: bool) -> void:
	var a: Dictionary = AMMO[to]
	_reload_empty = mags[ammo_type] <= 0
	reloading = true
	_reload_t = 0.0
	_reload_total = float(a["reload_empty"] if _reload_empty else a["reload"])
	_reload_to = to
	_reload_switch = is_switch
	_reload_ev = 0
	_ads_want = false


func _finish_reload() -> void:
	reloading = false
	left_reach_w = 0.0
	ammo_type = _reload_to
	var a: Dictionary = AMMO[ammo_type]
	var take := mini(int(a["mag"]) - mags[ammo_type], reserve_count())
	if take > 0:
		mags[ammo_type] += Game.take_ammo(a["id"], take)
	_set_colors()


# =================================================================================================
# Firing
# =================================================================================================

func _physics_process(delta: float) -> void:
	_cooldown -= delta
	if not can_operate() or player == null or player.vehicle != null:
		_trigger_prev = false
		_ads_want = false
		return
	var real := not debug_ignore_input and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var trig := (real and Input.is_action_pressed("tool_use")) or debug_trigger
	# just_pressed also catches a click shorter than one physics tick.
	var pressed := (trig and not _trigger_prev) or (real and Input.is_action_just_pressed("tool_use"))
	_trigger_prev = trig
	var up: Vector3 = player.global_transform.basis.y
	var hv: Vector3 = player.velocity - up * player.velocity.dot(up)
	# Sprint pose follows the player's run (kept through a hop), not is_on_floor().
	_sprint = (debug_sprint or (real and Input.is_action_pressed("sprint"))) and hv.length() > 5.0 \
			and (float(player.get("_sprint_k")) > 0.5 or debug_sprint) and ads < 0.2
	_since_sprint = 0.0 if _sprint else _since_sprint + delta
	_ads_want = ((real and Input.is_action_pressed("tool_alt")) or debug_ads) and not _sprint and not reloading
	var a: Dictionary = AMMO[ammo_type]
	var bursting := burst_mode and a.has("burst_rate")
	if bursting and pressed and _burst_left <= 0 and _cooldown <= 0.0:
		_burst_left = 3
	if reloading or _cooldown > 0.0 or _since_sprint < SPRINT_TO_FIRE:
		return
	if not player.viewmodel.is_raised():
		return
	if bursting:
		if _burst_left <= 0:
			return
		_burst_left -= 1
	elif not trig or (not a["auto"] and not pressed):
		return
	if mags[ammo_type] <= 0:
		if pressed:
			if Game.sfx:
				Game.sfx.play("click", -4.0, 1.3)
			_play("dry", -6.0, 1.0)
			hud.empty_flash()
			if reserve_count() > 0:
				reload()
		return
	fire()


## Fires one round of the current ammo type.
func fire() -> void:
	var a: Dictionary = AMMO[ammo_type]
	mags[ammo_type] -= 1
	_cooldown = 1.0 / float(a["rate"])
	if burst_mode and a.has("burst_rate"):
		# Burst cadence inside the burst, then a pause before the next trigger pull counts.
		_cooldown = 1.0 / float(a["burst_rate"]) if _burst_left > 0 else 0.3
	shots_fired += 1
	var aim := clampf(ads, 0.0, 1.0)
	var cam: Camera3D = player.camera
	var eye: Vector3 = player.aim_origin()
	var cb := cam.global_transform.basis
	var fwd := -cb.z
	var up: Vector3 = player.global_transform.basis.y
	var dir := _spread_dir(fwd, cb, current_spread())
	_bloom = minf(_bloom + float(a["spread"]) * 0.45, float(a["spread"]) * 2.5)
	var muzzle := muzzle_world()
	fx.bullet(eye, dir * float(a["speed"]) + player.velocity, muzzle, ammo_type, a["color"], a["dart"], int(a["pierce"]))
	Game.shot_fired.emit(eye, dir, "home")         # rival bots it passes near react (ai_rival.gd)
	# Recoil. Camera: kicks up 1.5-2.5 deg with a random yaw and recovers on a spring (less while
	# aiming). Gun: rotates up about the stock and slides back, then settles (springs in _process).
	var aim_k := (1.0 - aim * 0.35) * 1.0
	kick = 0.0
	_recoil_target += Vector2(float(a["kick_pitch"]) * randf_range(0.85, 1.2),
			randf_range(-1.0, 1.0) * float(a["kick_yaw"])) * aim_k
	_recoil_target.x = minf(_recoil_target.x, 0.18)
	_recoil = _recoil.lerp(_recoil_target, 0.35)      # the kick snaps in on the next frame
	_roll_v += randf_range(-1.0, 1.0) * float(a["roll"]) * 60.0 * aim_k
	_trauma = minf(_trauma + float(a["shake"]) * aim_k, 1.0)
	_fov_punch += float(a["fov_punch"]) * 1.0
	var gk: float = float(a["gun_kick"]) * 1.0
	var hip_k := 1.0 - aim * 0.55
	_rk_vel += Vector4(gk * 0.95 * hip_k, randf_range(-1.0, 1.0) * gk * 0.14 * hip_k,
			randf_range(-1.0, 1.0) * gk * 0.12 * hip_k, gk * 0.6 * lerpf(1.0, 0.45, aim))
	_since_shot = 0.0
	_bolt_t = 0.0
	_heat = minf(_heat + 0.07, 1.0)
	_use_t = 0.09
	var fl: float = a["flash"]
	if fl > 0.0:
		_flash_t = 1.0
		_randomize_flash(fl * 1.1)
		fx.muzzle_light(muzzle + fwd * 0.9, Color(1.0, 0.75, 0.4), 6.0 * fl, 0.045, 12.0)
		fx.muzzle_smoke(muzzle + fwd * 0.15, fwd, up)
		var side: Vector3 = cb.x
		fx.shell(_vm_world(_eject), side * randf_range(2.2, 3.2) + up * randf_range(1.4, 2.4) - fwd * 0.5 + player.velocity,
				ammo_type == 1)
	else:
		fx.muzzle_puff(muzzle + fwd * 0.1, fwd)
	_fire_sound()
	if mags[ammo_type] == 0 and reserve_count() > 0:
		_cooldown = maxf(_cooldown, 0.25)


func _spread_dir(fwd: Vector3, cb: Basis, spread: float) -> Vector3:
	if spread <= 0.0:
		return fwd
	var ang := randf() * TAU
	var r := sqrt(randf()) * spread
	return (fwd + cb.x * cos(ang) * r + cb.y * sin(ang) * r).normalized()


## A bullet hit something (called by the fx node). info: type ("body" with info["target"] = a
## damageable, "terrain", "metal"), point, normal, collider. Returns true when the bullet should stop
## (false = an AP round pierces on through a body).
func bullet_hit(info: Dictionary, dir: Vector3, ammo: int, pierced: int) -> bool:
	var a: Dictionary = AMMO[ammo]
	var p: Vector3 = info["point"]
	var n: Vector3 = info["normal"]
	last_impact = p
	var src: Vector3 = player.global_position if player != null else p - dir * 30.0
	match info["type"]:
		"body":
			var t = info["target"]
			var dmg: float = float(a["dmg"]) * (0.6 if pierced > 0 else 1.0)
			var r := Game.damage_target(t, dmg, src, dir * float(a["impulse"]) * 0.15, "home")
			fx.impact_metal(p, n, dir, false)
			hits += 1
			# Markers, confirm sounds, hit-stop and shake: scripts/items/hit_feel.gd (shared by all guns).
			HitFeel.inst().target_hit(t, r, dmg, p, {"big": 0.55 if ammo == 1 else 0.2})
			return pierced >= int(a["pierce"])
		"terrain":
			fx.impact_terrain(p, n, dir, _ground_color(p, n), false, ammo == 1)
		"metal":
			fx.impact_metal(p, n, dir, false)
	return true


# =================================================================================================
# Per-frame: aim, camera, weapon pose (hip / aim / sprint / reload + recoil, bob, sway)
# =================================================================================================

## Current cone half-angle of fire (rad): base spread (hip or aimed) + bloom + movement.
func current_spread() -> float:
	var a: Dictionary = AMMO[ammo_type]
	var aim := clampf(ads, 0.0, 1.0)
	var mv := 0.0
	if player != null:
		var up: Vector3 = player.global_transform.basis.y
		var hv: Vector3 = player.velocity - up * player.velocity.dot(up)
		mv = clampf(hv.length() / 6.0, 0.0, 1.0) * 0.016 + (0.0 if player.is_on_floor() else 0.018)
	return lerpf(float(a["spread"]), float(a["ads_spread"]), aim) * 1.0 + _bloom * (1.0 - aim * 0.6) + mv * (1.0 - aim * 0.6)


func _input(event: InputEvent) -> void:
	# Mouse look feeds the weapon sway (read only, never consumed).
	if event is InputEventMouseMotion and equipped and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look_acc += (event as InputEventMouseMotion).relative


func _process(delta: float) -> void:
	_t += delta
	var on := player != null and equipped and active and player.vehicle == null
	using = _use_t > 0.0
	_use_t = maxf(_use_t - delta, 0.0)
	var dt := minf(delta, 0.033)
	# Raise to the sights: a spring with a slight overshoot (~0.3 s in, ~0.25 s out).
	var want := _ads_want and on
	var k := 110.0 if want else 170.0
	var c := 13.5 if want else 25.0
	_ads_vel += (((1.0 if want else 0.0) - ads) * k - _ads_vel * c) * dt
	ads = clampf(ads + _ads_vel * dt, -0.05, 1.1)
	sway_scale = lerpf(1.6, 0.45, clampf(ads, 0.0, 1.0))
	if reloading:
		_reload_t += delta
		_reload_events()
		if _reload_t >= _reload_total:
			_finish_reload()
	# Camera recoil: the kick snaps in, the view settles back fast; a little roll on a stiff spring.
	_recoil = _recoil.lerp(_recoil_target, 1.0 - exp(-60.0 * delta))
	var rec := lerpf(10.5, 12.5, clampf(ads, 0.0, 1.0))
	_recoil_target = _recoil_target.lerp(Vector2.ZERO, 1.0 - exp(-rec * delta))
	_roll_v += (-_roll * 420.0 - _roll_v * 26.0) * dt
	_roll += _roll_v * dt
	_trauma = maxf(_trauma - delta * 2.6, 0.0)
	_fov_punch = lerpf(_fov_punch, 0.0, 1.0 - exp(-12.0 * delta))
	# Bloom recovers after a short pause (fast follow-ups keep it open).
	_since_shot += delta
	if _since_shot > 0.15:
		_bloom = maxf(_bloom - delta * 0.04, 0.0)
	_heat = maxf(_heat - delta * 0.3, 0.0)
	# Shots set _flash_t = 1 in the physics step; let that frame render at full strength first.
	_flash_t = maxf(_flash_t - delta / 0.05, 0.0) if _flash_t < 1.0 else 0.999
	# Gun recoil spring (pitch, yaw, roll, kickback): fast kick, damped settle ~0.25 s.
	_rk_vel += (-_rk * 280.0 - _rk_vel * 21.0) * dt
	_rk += _rk_vel * dt
	_bolt_t += delta
	_update_fades(delta)
	if on:
		_apply_camera()
	else:
		_restore_camera()
	_update_pose(dt, on)
	_animate_model()


func _apply_camera() -> void:
	var cam: Camera3D = player.camera
	var e := _smooth(clampf(ads, 0.0, 1.0))
	cam.fov = lerpf(Settings.fov, ADS_FOV * 1.0, e) + _fov_punch
	var sh := _trauma * _trauma
	var shake := Vector3(sin(_t * 67.0) + sin(_t * 29.0) * 0.6, sin(_t * 59.0 + 1.3) + sin(_t * 19.0) * 0.5,
			sin(_t * 43.0 + 0.7)) * sh * 0.016
	# Slight breathing sway while aiming.
	var breath := Vector2(sin(_t * 1.1) * 0.0018 + sin(_t * 0.43) * 0.001, sin(_t * 0.8 + 1.0) * 0.0024) * e * 1.0
	# Added on top of the player's own camera rotation (damage punches), which it resets each frame.
	cam.rotation += Vector3(_recoil.x + shake.x + breath.y, _recoil.y + shake.y + breath.x, shake.z + _roll)
	# The rifle draws its own crosshair (spread brackets) in rifle_hud.
	if Game.hud != null and Game.hud.get("crosshair") != null:
		Game.hud.crosshair.modulate.a = 0.0
	if "move_speed_mult" in player:
		player.set("move_speed_mult", lerpf(1.0, AIM_SPEED, e))
	if "look_scale" in player:
		player.set("look_scale", lerpf(1.0, 0.75, e))
	_cam_dirty = true


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


## Smooth 0..1 ramp of u between a and b.
static func _seg(u: float, a: float, b: float) -> float:
	return _smooth((u - a) / (b - a))


## Hip pose (camera space): grip low on the right, stock toward the shoulder, the bore converging
## on the crosshair a few meters ahead, a slight inward cant.
static func _hip_pose() -> Transform3D:
	var bore := HIP_POS + Vector3(0.0, 0.062, 0.0)
	var d := (Vector3(0.0, 0.0, -HIP_CONVERGE) - bore).normalized()
	var b := Basis.looking_at(d, Vector3.UP) * Basis(Vector3.BACK, HIP_CANT)
	return Transform3D(b, HIP_POS)


## Aim pose: gun straight ahead, rear notch on the camera axis.
func _ads_pose() -> Transform3D:
	return Transform3D(Basis(), ADS_EYE - SIGHT_REAR)


static func _pose_from(origin: Vector3, euler: Vector3) -> Transform3D:
	return Transform3D(Basis.from_euler(euler), origin)


static func _blend(a: Transform3D, b: Transform3D, w: float) -> Transform3D:
	var q := Quaternion(a.basis.orthonormalized()).slerp(Quaternion(b.basis.orthonormalized()), clampf(w, 0.0, 1.0))
	return Transform3D(Basis(q), a.origin.lerp(b.origin, w))


## Full camera-space pose of the hand + gun rig, read by the view model (`pose_override`).
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
	# Sprint (lowered, canted), reload and aim weights.
	_sprint_w = move_toward(_sprint_w, 1.0 if (_sprint and on) else 0.0, dt / 0.22)
	var u := reload_progress() if reloading else 0.0
	var rp := 0.0
	if reloading:
		rp = _seg(u, 0.0, 0.1) * (1.0 - _seg(u, 0.84, 0.97))
	var hip := _hip_pose()
	var pose := _blend(hip, _ads_pose(), aim)
	if ads > 1.0:
		pose.origin = hip.origin.lerp(_ads_pose().origin, ads)
	pose = _blend(pose, _pose_from(SPRINT_POS, SPRINT_ROT), _smooth(_sprint_w))
	pose = _blend(pose, _pose_from(RELOAD_POS, RELOAD_ROT), rp)
	# Walk / run bob: a figure-eight, bigger when sprinting, nearly none when aiming.
	var bob_target := clampf(hspeed / 4.5, 0.0, 1.6) if grounded else 0.0
	_bob_amt = lerpf(_bob_amt, bob_target, rate * 0.6)
	if grounded and player.get("astronaut") != null:
		_bob_ph = float(player.astronaut._phase) * TAU + PI * 0.5     # the body's gait: dip as a foot plants
	var bk := _bob_amt * (1.0 - aim * 0.85) * (1.0 + _sprint_w * 0.6)
	var bob := Vector3(cos(_bob_ph) * 0.011, -absf(sin(_bob_ph)) * 0.014, 0.0) * bk
	var bob_rot := Vector3(-absf(sin(_bob_ph)) * 0.01, cos(_bob_ph) * 0.012, cos(_bob_ph) * 0.022) * bk
	# Mouse sway: the gun lags behind turns on a soft spring (much less when aiming).
	var look := _look_acc * (1.0 / 60.0) / maxf(dt, 0.001)     # per-frame mouse counts → 60 fps units
	_look_acc = Vector2.ZERO
	var sk := lerpf(1.0, 0.25, aim) * (0.6 if reloading else 1.0)
	var sway_target := Vector2(clampf(-look.x * 0.0013, -0.07, 0.07), clampf(-look.y * 0.0013, -0.06, 0.06)) * sk
	_sway_vel += ((sway_target - _sway) * 160.0 - _sway_vel * 17.0) * dt
	_sway += _sway_vel * dt
	# Landing / jumping: the gun dips and rises with vertical speed.
	_vy = lerpf(_vy, clampf(-v_up * 0.006, -0.04, 0.05), rate * 0.5)
	var breathe := Vector3(0.0, sin(_t * 1.6) * 0.0025, 0.0) * (1.0 - aim)
	var off := bob + breathe + Vector3(_sway.x * 0.12, _sway.y * 0.1 + _vy * (1.0 - aim * 0.6), 0.0)
	var rot := bob_rot + Vector3(_sway.y * 0.9, _sway.x * 1.1, _sway.x * 0.7)
	var xf := Transform3D(Basis.from_euler(rot) * pose.basis, pose.origin + off)
	# Recoil in the gun frame: rotate up about the stock, slide back along the bore.
	var rk_rot := Basis.from_euler(Vector3(_rk.x, _rk.y, _rk.z))
	var rk_xf := Transform3D(Basis(), RECOIL_PIVOT) * Transform3D(rk_rot, Vector3.ZERO) * Transform3D(Basis(), -RECOIL_PIVOT)
	rk_xf.origin += Vector3(0.0, 0.0, _rk.w)
	pose_override = xf * rk_xf


func _animate_model() -> void:
	if model == null:
		return
	# Reload choreography (u = 0..1): the left hand leaves the foregrip, pulls the magazine, takes it
	# away, brings a new one, seats it, slaps it and returns (the pose tilt comes from RELOAD_ROT).
	var u := reload_progress() if reloading else 0.0
	var drop := 0.0
	var mag_vis := true
	var slap := 0.0
	var pull := 0.0
	if reloading:
		left_reach_w = _seg(u, 0.03, 0.13) * (1.0 - _seg(u, 0.78, 0.9))
		drop = lerpf(0.0, 0.06, _seg(u, 0.13, 0.22)) + lerpf(0.0, 0.42, _seg(u, 0.22, 0.38))
		if u > 0.44:
			drop = lerpf(0.48, 0.04, _seg(u, 0.46, 0.62)) * (1.0 - _seg(u, 0.62, 0.69))
		mag_vis = u < 0.4 or u > 0.47
		slap = sin(clampf((u - 0.69) / 0.07, 0.0, 1.0) * PI)
		if _reload_empty:
			pull = _seg(u, 0.8, 0.85) * (1.0 - _seg(u, 0.88, 0.92))
	else:
		left_reach_w = 0.0
	hold_offset = Vector3.ZERO
	_gun.transform = Transform3D(Basis.from_euler(Vector3(slap * 0.03, 0.0, 0.0)), Vector3(0.0, slap * 0.006, 0.0))
	_mag.position = MAG_REST + MAG_AXIS * drop
	var tumble := clampf((drop - 0.1) / 0.3, 0.0, 1.0)
	_mag.rotation = Vector3(tumble * 0.5, 0.0, tumble * 0.35)
	_mag.visible = mag_vis
	if reloading and _reload_switch and u > 0.44:
		_mag_glow.set_shader_parameter("color", ammo_color(_reload_to))
	if left_reach_w > 0.0 and player != null:
		var cam_inv: Transform3D = player.camera.global_transform.affine_inverse()
		left_reach = cam_inv * _mag_grab.global_position + Vector3(0.0, 0.03 * slap, 0.0)
	# Charging handle: snaps back in 0.04 s and springs home in 0.08 s per shot; pulled on empty reloads.
	var cyc := _smooth(_bolt_t / 0.04) if _bolt_t < 0.04 else 1.0 - _smooth((_bolt_t - 0.04) / 0.08)
	_bolt.position = Vector3(0.03, 0.082, maxf(cyc, pull) * 0.06)
	# Muzzle flash, heat strips, ammo counter LEDs.
	_flash_root.visible = _flash_t > 0.0
	if _flash_t > 0.0:
		_flash_mat.set_shader_parameter("energy", 12.0 * _flash_t)
	var col := ammo_color()
	_accent_glow.set_shader_parameter("energy", 2.5 + _heat * 5.0)
	var frac := float(mags[ammo_type]) / float(mag_capacity())
	for i in _leds.size():
		var lit := frac > (float(i) + 0.5) / _leds.size()
		(_leds[i] as MeshInstance3D).material_override = _led_mat if lit else _led_off
	_led_mat.set_shader_parameter("color", col)


## Reload foley + small kicks, timed to the animation (u = progress 0..1).
func _reload_events() -> void:
	var u := reload_progress()
	var marks := [0.06, 0.13, 0.22, 0.64, 0.7, 0.82, 0.9]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -16.0, randf_range(0.9, 1.1))
			1:
				_play("mag_release", -9.0, randf_range(0.95, 1.05))
			2:
				_play("mag_out", -8.0, randf_range(0.95, 1.05))
			3:
				_play("mag_in", -6.0, randf_range(0.95, 1.05))
				_rk_vel.w += 0.25
			4:
				_play("mag_slap", -5.0, randf_range(0.95, 1.05))
				_rk_vel.x += 0.6
			5:
				if _reload_empty:
					_play("bolt_back", -6.0, 1.0)
			6:
				if _reload_empty:
					_play("bolt_fwd", -4.0, 1.0)
					_rk_vel += Vector4(0.8, 0.0, 0.0, 0.3)
		_reload_ev += 1


func _randomize_flash(size: float) -> void:
	if _flash_root == null:
		return
	_flash_root.scale = Vector3.ONE * randf_range(0.85, 1.3) * size
	_flash_root.rotation.z = randf() * TAU
	_flash_mat.set_shader_parameter("seed", randf() * 10.0)


func _set_colors() -> void:
	var col := ammo_color()
	if _accent_glow:
		_accent_glow.set_shader_parameter("color", col)
		_mag_glow.set_shader_parameter("color", col)
		_led_mat.set_shader_parameter("color", col)


## World position of a view-model node (as it appears on screen).
func _vm_world(n: Node3D) -> Vector3:
	var cam: Camera3D = player.camera
	if n == null:
		return cam.global_position - cam.global_transform.basis.z * 0.6
	return VM.vm_to_world(cam, n.global_position)


func _ground_color(p: Vector3, n: Vector3) -> Color:
	return ground_color(p, n)


## Dust colour of a bullet impact at p (normal n): the planet's ground colour on open ground, its
## rock colour on steep walls (shared by every gun and projectiles.gd).
static func ground_color(p: Vector3, n: Vector3) -> Color:
	var body: Node3D = Game.body_at(p)
	if body == null:
		return Color(0.45, 0.38, 0.26)
	var up := (p - body.global_position).normalized()
	var cfg: Dictionary = body.get("cfg") if body.get("cfg") is Dictionary else {}
	if n.dot(up) < 0.55:
		return cfg.get("col_rock", Color(0.42, 0.4, 0.38))
	return cfg.get("col_low", Color(0.45, 0.38, 0.26))


# =================================================================================================
# Audio. Every gunshot is 4 layers on a dedicated "Weapons" bus (EQ -> compressor -> reverb sized
# to the surroundings -> limiter):
#   crack   the recorded shot, trimmed to its first ~0.2 s by a fast fade (no ringing / echo copy)
#   body    short synthesized low thump (65-110 Hz)
#   action  bolt clack, dry and close (plain bus)
#   tail    soft dark outdoor tail (none inside the ship, short in caves)
# Reload foley is synthesized and timed to the animation.
# =================================================================================================

## Recorded shots (HK416 / L85 on-gun, AKM close: assets/audio/sonniss/weap) keep their own first
## reflections; the fade trims them before the next burst shot would have started.
const CRACK_LEN := {"shot": 0.3, "heavy": 0.4}

func _setup_audio() -> void:
	var bus := _weapons_bus()
	for i in 12:
		var p := AudioStreamPlayer.new()
		p.bus = bus
		add_child(p)
		_gun_audio.append(p)
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_aux_audio.append(p)
	_snd["shot"] = Snd.set_of("weap/rifle_shot")
	_snd["heavy"] = Snd.set_of("weap/rifle_heavy")
	_snd["tick"] = Snd.set_of("hit/tick")
	_snd["kill"] = Snd.set_of("hit/kill")
	_synth_task = WorkerThreadPool.add_task(_build_synth, false, "weapon_audio")


func _build_synth() -> void:
	var gen := WeaponAudio.new()
	var out := {}
	for n in WeaponAudio.NAMES:
		out[n] = [gen.make(n)]
	_synth_mutex.lock()
	_synth_ready = out
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


## "Weapons" bus: tame the harsh 2-5 kHz, add low weight, glue with a compressor, a reverb that is
## re-sized to the surroundings per shot, and a limiter so nothing clips.
static func _weapons_bus() -> String:
	var name := "Weapons"
	var idx := AudioServer.get_bus_index(name)
	if idx >= 0:
		return name
	AudioServer.add_bus()
	idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, name)
	AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(idx, -3.0)
	var eq := AudioEffectEQ6.new()       # bands: 32, 100, 320, 1000, 3200, 10000 Hz
	eq.set_band_gain_db(0, 2.5)
	eq.set_band_gain_db(1, 4.5)
	eq.set_band_gain_db(2, 0.5)
	eq.set_band_gain_db(3, -1.0)
	eq.set_band_gain_db(4, -4.0)
	eq.set_band_gain_db(5, -2.0)
	AudioServer.add_bus_effect(idx, eq)
	# A slower attack lets each shot's transient through before the compressor clamps the body.
	var comp := AudioEffectCompressor.new()
	comp.threshold = -15.0
	comp.ratio = 3.5
	comp.attack_us = 2500.0
	comp.release_ms = 120.0
	comp.gain = 2.0
	AudioServer.add_bus_effect(idx, comp)
	var rv := AudioEffectReverb.new()
	rv.predelay_msec = 60.0
	rv.predelay_feedback = 0.2
	rv.room_size = 0.85
	rv.damping = 0.7
	rv.spread = 1.0
	rv.hipass = 0.2
	rv.wet = 0.16
	rv.dry = 1.0
	AudioServer.add_bus_effect(idx, rv)
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = -1.5
	AudioServer.add_bus_effect(idx, lim)
	return name


## 0 = small room (almost dry, unused for now), 1 = tunnel / overhang, 2 = open air.
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


func _stream(name: String) -> AudioStream:
	if _synth_task >= 0 and WorkerThreadPool.is_task_completed(_synth_task):
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_synth_task = -1
		_synth_mutex.lock()
		_synth = _synth_ready
		_synth_mutex.unlock()
	var arr: Array = _snd.get(name, [])
	if arr.is_empty():
		arr = _synth.get(name, [])
	if arr.is_empty():
		return null
	return arr[randi() % arr.size()]


## Plays on the Weapons bus (gunshot layers) or the plain aux players. `cut` > 0 fades the sound
## out after that many seconds (used to trim the recorded crack).
func _play(name: String, vol := 0.0, pitch := 1.0, weapons_bus := false, cut := 0.0) -> AudioStream:
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
	return st


## Trims sounds: after `cut` seconds the player fades to silence over FADE_LEN and stops.
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


func _fire_sound() -> void:
	var a: Dictionary = AMMO[ammo_type]
	var sname: String = a["sound"]
	var pitch := randf_range(0.96, 1.04)
	if sname == "dart":
		_play("dart", -6.0, pitch)
		_play("action", -20.0, 1.3)
		return
	var space := _space_kind()
	_set_space(space)
	var heavy := sname == "heavy"
	_play(sname, -4.0 if not heavy else -2.5, pitch, true, float(CRACK_LEN.get(sname, 0.3)))
	_play("thump", -8.0 if not heavy else -5.0, pitch * (0.9 if heavy else 1.0), true)
	_play("punch", -6.0 if not heavy else -3.5, pitch * (0.9 if heavy else 1.0), true)
	_play("action", -21.0, randf_range(0.95, 1.08))
	if space == 2:
		_play("tail", -17.0 if not heavy else -14.0, randf_range(0.92, 1.05), true)
		_play("echo", -15.0 if not heavy else -12.0, randf_range(0.92, 1.04), true)
	elif space == 1:
		_play("tail", -21.0, 1.25, true, 0.25)


## Synthesized sound for the fx node (casing tink).
func synth_stream(name: String) -> AudioStream:
	return _stream(name)


# =================================================================================================
# Model
# =================================================================================================

## First-person model: white/orange rifle with iron sights (rear notch + hooded front post with a
## glowing dot), hex handguard, glow strips, magazine (animated on reload), charging handle,
## ammo LEDs and a star-shaped muzzle flash (view-model space).
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
	var col := ammo_color()
	_accent_glow = VM.glow(col, 2.5)
	_mag_glow = VM.glow(col, 3.0)
	_led_mat = VM.glow(col, 4.0)
	_led_off = VM.glow(Color(0.1, 0.12, 0.14), 1.0)
	var by := 0.062                         # bore line height

	VM.grip(_gun, orange)
	# Trigger and guard.
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.02, -0.022), Vector3(0, -0.02, -0.072), 0.0045, steel)
	VM.capsule(_gun, Vector3(0, -0.02, -0.072), Vector3(0, 0.024, -0.084), 0.0045, steel)
	# Receiver: dark lower, white upper shell, orange side bands, vents.
	VM.soft_box(_gun, Vector3(0, 0.04, -0.04), Vector3(0.05, 0.05, 0.27), 0.012, gray)
	VM.soft_box(_gun, Vector3(0, 0.08, -0.05), Vector3(0.054, 0.036, 0.32), 0.014, white)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0275 * sx, 0.07, -0.05), Vector3(0.003, 0.01, 0.26), orange)
	for i in 4:
		VM.box(_gun, Vector3(-0.0285, 0.086, -0.13 - i * 0.02), Vector3(0.004, 0.014, 0.009), dark)
	# Stock: top bar, strut, rear plate, rubber butt pad.
	VM.soft_box(_gun, Vector3(0, 0.074, 0.165), Vector3(0.04, 0.03, 0.15), 0.012, white)
	VM.box(_gun, Vector3(0, 0.0905, 0.165), Vector3(0.03, 0.004, 0.12), orange)
	VM.capsule(_gun, Vector3(0, 0.03, 0.09), Vector3(0, 0.0, 0.245), 0.011, dark)
	VM.soft_box(_gun, Vector3(0, 0.04, 0.25), Vector3(0.036, 0.105, 0.035), 0.012, white)
	VM.soft_box(_gun, Vector3(0, 0.04, 0.273), Vector3(0.038, 0.112, 0.014), 0.006, rubber)
	# Handguard: hexagonal shroud with cut-outs, glowing under-strips.
	VM.seg(_gun, Vector3(0, by, -0.17), Vector3(0, by, -0.41), 0.033, 0.03, white, 6)
	for i in 5:
		for sx in [-1.0, 1.0]:
			VM.box(_gun, Vector3(0.029 * sx, by, -0.2 - i * 0.042), Vector3(0.008, 0.016, 0.024), dark)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.019 * sx, by - 0.027, -0.29), Vector3(0.004, 0.004, 0.19), _accent_glow)
	VM.box(_gun, Vector3(0, by + 0.03, -0.29), Vector3(0.014, 0.005, 0.22), dark)
	VM.ring(_gun, Vector3(0, by, -0.41), Vector3.FORWARD, 0.033, 0.006, orange)
	VM.ring(_gun, Vector3(0, by, -0.175), Vector3.FORWARD, 0.035, 0.005, dark)
	# Barrel, gas block and muzzle brake.
	VM.seg(_gun, Vector3(0, by, -0.41), Vector3(0, by, -0.56), 0.0115, 0.0115, steel, 12)
	VM.soft_box(_gun, Vector3(0, by + 0.004, -0.445), Vector3(0.024, 0.03, 0.03), 0.006, dark)
	VM.soft_box(_gun, Vector3(0, by, -0.575), Vector3(0.028, 0.026, 0.045), 0.008, dark)
	for z in [-0.565, -0.585]:
		for sx in [-1.0, 1.0]:
			VM.box(_gun, Vector3(0.0145 * sx, by, z), Vector3(0.004, 0.016, 0.007), black)
	VM.ring(_gun, Vector3(0, by, -0.598), Vector3.FORWARD, 0.011, 0.0035, steel)
	_muzzle = VM.node(_gun, Vector3(0, by, -0.605))
	# Receiver top rail (stays below the sight line).
	VM.box(_gun, Vector3(0, 0.1, -0.075), Vector3(0.02, 0.006, 0.17), dark)
	for i in 7:
		VM.box(_gun, Vector3(0, 0.1035, -0.005 - i * 0.022), Vector3(0.022, 0.004, 0.008), dark)
	# Rear sight (gez): base block, two ears with white dots and a notch between them.
	var rz := SIGHT_REAR.z
	VM.soft_box(_gun, Vector3(0, 0.103, rz), Vector3(0.03, 0.012, 0.022), 0.004, dark)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0085 * sx, SIGHT_Y - 0.0065, rz), Vector3(0.0105, 0.017, 0.008), dark)
		VM.box(_gun, Vector3(0.0085 * sx, SIGHT_Y - 0.004, rz - 0.0045), Vector3(0.0028, 0.0028, 0.001), VM.glow(Color(0.95, 0.95, 0.9), 1.6))
	VM.box(_gun, Vector3(0, SIGHT_Y - 0.0125, rz), Vector3(0.007, 0.005, 0.008), dark)
	# Front sight (arpacık): tower on the gas block, thin post, protective hood ears, glowing dot.
	var fz := SIGHT_FRONT_Z
	VM.box(_gun, Vector3(0, (by + 0.02 + SIGHT_Y - 0.02) * 0.5 + 0.004, fz), Vector3(0.012, SIGHT_Y - 0.02 - by - 0.012, 0.016), dark)
	VM.box(_gun, Vector3(0, SIGHT_Y - 0.0085, fz), Vector3(0.0035, 0.017, 0.006), black)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0115 * sx, SIGHT_Y - 0.008, fz), Vector3(0.003, 0.022, 0.014), dark)
	VM.sphere(_gun, Vector3(0, SIGHT_Y - 0.0012, fz + 0.0035), 0.0019, VM.glow(Color(0.45, 1.0, 0.55), 4.0))
	# Foregrip for the left hand.
	VM.soft_box(_gun, Vector3(0, 0.028, -0.3), Vector3(0.022, 0.016, 0.05), 0.006, dark)
	VM.capsule(_gun, Vector3(0, -0.05, -0.298), Vector3(0, 0.01, -0.302), 0.0165, rubber)
	VM.seg(_gun, Vector3(0, -0.074, -0.296), Vector3(0, -0.062, -0.297), 0.019, 0.018, orange)
	left_grip = VM.node(_gun, Vector3(0, 0.004, -0.302), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	# Ejection port and charging handle (right side).
	VM.box(_gun, Vector3(0.0275, 0.082, -0.06), Vector3(0.004, 0.016, 0.04), black)
	_eject = VM.node(_gun, Vector3(0.036, 0.083, -0.06))
	_bolt = VM.node(_gun, Vector3(0.03, 0.082, 0.0))
	VM.capsule(_bolt, Vector3.ZERO, Vector3(0.02, 0.0, 0.004), 0.0055, steel)
	VM.sphere(_bolt, Vector3(0.022, 0.0, 0.004), 0.0085, orange)
	VM.box(_bolt, Vector3(-0.003, 0.0, -0.06), Vector3(0.004, 0.012, 0.035), steel)
	# Magazine (the left hand pulls it on reload; window glows in the ammo color).
	_mag = VM.node(_gun, MAG_REST)
	var mb := Basis(Vector3.RIGHT, 0.12)
	VM.soft_box(_mag, Vector3(0, -0.045, -0.004), Vector3(0.03, 0.1, 0.05), 0.01, dark, mb)
	VM.box(_mag, mb * Vector3(0, -0.088, 0.0) + Vector3(0, 0, -0.004), Vector3(0.034, 0.014, 0.055), orange, mb)
	for sx in [-1.0, 1.0]:
		VM.box(_mag, mb * Vector3(0.0158 * sx, -0.04, 0.0) + Vector3(0, 0, -0.004), Vector3(0.002, 0.05, 0.014), _mag_glow, mb)
	# Where the left wrist goes when it holds the magazine (just below and left of its base).
	_mag_grab = VM.node(_mag, mb * Vector3(-0.03, -0.13, 0.02))
	# Ammo counter LEDs on the left side.
	for i in 10:
		_leds.append(VM.box(_gun, Vector3(-0.0289, 0.047, 0.04 - i * 0.012), Vector3(0.002, 0.006, 0.008), _led_mat))
	# Muzzle flash: a face-on star plus two crossed side plumes (additive, view-model space).
	_flash_root = VM.node(_gun, Vector3(0, by, -0.61))
	var fs := Shader.new()
	fs.code = VM.prep(FLASH_SHADER)
	_flash_mat = ShaderMaterial.new()
	_flash_mat.shader = fs
	_flash_mat.set_shader_parameter("color", Color(1.0, 0.62, 0.22))
	var q := QuadMesh.new()
	q.size = Vector2(0.17, 0.17)
	var front := VM.mesh_inst(_flash_root, q, _flash_mat)
	front.position = Vector3(0, 0, -0.02)
	var side := QuadMesh.new()
	side.size = Vector2(0.09, 0.26)
	for k in 2:
		var mi := VM.mesh_inst(_flash_root, side, _flash_mat)
		mi.transform = Transform3D(Basis(Vector3.FORWARD, k * PI * 0.5) * Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 0, -0.11))
	_flash_root.visible = false
	VM.bake(_gun, [_mag, _bolt, _flash_root, _muzzle, _eject, left_grip] + _leds)
	VM.bake(_mag, [_mag_grab])
	VM.bake(_bolt)
	return model


# =================================================================================================
# Third-person prop (registered in the astronaut's held-item table)
# =================================================================================================

func _build_tp_prop() -> void:
	if player == null:
		return
	var ast = player.get("astronaut")
	if ast == null or not ("props" in ast) or not ("hand" in ast):
		return
	if ast.props.has("rifle"):
		_tp_tip = ast.prop_tips.get("rifle")
		return
	var hands: Array = ast.hand
	if hands.size() < 2 or hands[1] == null:
		return
	var white := _tp_mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tp_mat(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _tp_mat(Color(0.16, 0.17, 0.19), 0.4, 0.6)
	var p := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.06, -0.05), Vector3(0.05, 0.07, 0.3), white)
	VM.box(p, Vector3(0, 0.05, 0.17), Vector3(0.036, 0.09, 0.15), white)
	VM.box(p, Vector3(0.027, 0.065, -0.05), Vector3(0.004, 0.012, 0.26), orange)
	VM.seg(p, Vector3(0, 0.062, -0.2), Vector3(0, 0.062, -0.41), 0.032, 0.03, white, 6)
	VM.seg(p, Vector3(0, 0.062, -0.41), Vector3(0, 0.062, -0.6), 0.012, 0.012, dark, 10)
	VM.box(p, Vector3(0, 0.1, -0.43), Vector3(0.012, 0.04, 0.016), dark)
	VM.box(p, Vector3(0, -0.03, -0.085), Vector3(0.03, 0.1, 0.05), dark)
	_tp_tip = VM.node(p, Vector3(0, 0.062, -0.61))
	p.visible = false
	ast.props["rifle"] = p
	ast.prop_tips["rifle"] = _tp_tip
	# Join the astronaut's first-person hiding (shadow-only body meshes) and its visual layer.
	var list = ast.get("_meshes")
	for mi in p.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).layers = 2
		if list is Array:
			list.append(mi)
	if ast.has_method("set_first_person"):
		ast.set_first_person(not player.is_ragdolled())


func _tp_mat(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m
