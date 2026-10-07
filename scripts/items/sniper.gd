extends "res://scripts/items/weapon_base.gd"
## Keskin Nişancı Tüfeği ("Keskin", key 5): a heavy bolt-action with a big scope.
## Firing goes through exactly the rifle / shotgun path (weapon_base.gd fire() → _fire_shot() →
## fx.bullet() → rifle_fx.gd → bullet_hit() → gun_feel.gd body_hit → Game.damage_target +
## Game.shot_fired), so multiplayer hit claims and events pick it up unchanged.
##   Round      .338 class: 2400 m/s (≈3× the rifle), drops under Game.gravity_at like every bullet,
##              BODY_DMG 110 to the body (a one-shot kill on a 100 hp bot or player: 2026-10-05 the user
##              found the guns weak, "silahlar güçsüz"; was 82 = two body shots), ×3 in the head (330),
##              penetrates nothing, launches the
##              body on a kill. A bright, fat tracer.
##   Bolt       after every shot a visible ~1.3 s bolt cycle: the right hand leaves the grip, lifts the
##              handle, pulls the bolt back (the case flies out), pushes it home and returns. A shot
##              taken in the scope drops out of it for the cycle and comes back if RMB is still held.
##   Magazine   5 rounds, R reloads (3.0 s, 3.5 s empty with a bolt cycle); reserve "ammo_sniper"
##              bought from material at Game.AMMO_COST (0.6 m³ / round).
##   Scope      hold RMB: the camera FOV eases to 4× or 6× magnification (mouse wheel / B while
##              scoped), mouse look scales with the zoom, the view model hides when fully
##              scoped and the overlay (scripts/items/sniper_scope.gd, a CanvasLayer under the HUD)
##              shows the lens, duplex mil-dot reticle, rangefinder and breath bar. The view sways
##              (less standing still, much less crouched, more moving / airborne / after a shot);
##              hold Shift to hold the breath (~4 s steady, then out of breath for a moment).
##   Glint      `glint` 0..1 while scoped: the third-person model has a lens glint others see
##              (set_glint()); bots kept in the crosshair notice it and react (help_call).
## Multiplayer state to sync: glint / scoped, bolt_t (bolt cycle), reloading. Remote avatars can
## build this gun's third-person model with Sniper.build_tp_on(astronaut) and drive the glint with
## Sniper.set_glint(astronaut, k).

const SniperScope := preload("res://scripts/items/sniper_scope.gd")
const HelmetFx := preload("res://scripts/ui/helmet_fx.gd")       # the breath hold's sounds (_breath_sfx)

const WEIGHT := 0.9                        # mobility factor while held (item.gd carry_weight; loadout)
const BORE_Y := 0.058
const SCOPE_Y := 0.134                     # scope axis height in the gun frame
const EYEPIECE_Z := 0.125                  # rear face of the eyecup
const MUZZLE_V := 2400.0                   # m/s (the rifle's standard round: 780)
const BODY_DMG := 140.0                     # one body shot kills AI_HP 135 (was 82: two; 2026-10-06 tok: 110 -> 140)
const HEAD_X := 3.0                        # 420 in the head: always a kill (an armoured dummy too)
const BOLT_T := 1.3                        # s, the bolt cycle after a shot
const BOLT_TRAVEL := 0.085
const BOLT_LIFT := 1.05                    # rad the handle turns up
const BOLT_REST := -PI * 0.5 - 0.35        # handle angle about the bore at rest (pointing right, drooped)
const BOLT_ARM_Z := 0.026                  # handle root along the bolt
const KNOB := Vector3(0.0, 0.064, 0.014)   # knob centre in handle space (handle along +Y)
const ZOOMS := [4.0, 6.0]
const BREATH_MAX := 4.0                    # s of held breath
const BREATH_RECOVER := 1.8                # s out of breath after running out
const SWAY := 0.0032                       # rad of scope sway standing still
const MAG_REST := Vector3(0.0, 0.0, -0.125)          # ahead of the trigger guard (the trigger finger fits behind it)
const MAG_AXIS := Vector3(0.0, -0.993, -0.12)
const FOREARM := Vector3(0.4, -0.32, 0.86)
const WATCH_TIME := 0.8                    # s a bot must sit in the crosshair before it sees the glint
const WATCH_CONE := 0.03                   # rad
const WATCH_RANGE := 450.0

const GLINT_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform float strength = 0.0;
varying float v_k;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 axis = normalize((MODEL_MATRIX * vec4(0.0, 0.0, -1.0, 0.0)).xyz);
	vec3 to_cam = CAMERA_POSITION_WORLD - origin;
	float d = length(to_cam);
	float face = max(dot(axis, to_cam / max(d, 0.001)), 0.0);
	v_k = pow(face, 6.0) * strength;
	float s = (1.0 + d * 0.035) * (0.25 + 0.75 * v_k);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * s, INV_VIEW_MATRIX[1] * s, INV_VIEW_MATRIX[2] * s, MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float core = exp(-r * r * 16.0);
	float star = exp(-abs(p.y) * 38.0) * exp(-abs(p.x) * 2.2) + exp(-abs(p.x) * 38.0) * exp(-abs(p.y) * 2.2);
	float a = (core + star * 0.55) * v_k;
	ALBEDO = vec3(1.0, 0.95, 0.85) * a * 5.0;
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

static var _glint_shader: Shader

# --- State (read by the HUD / multiplayer) ---------------------------------------------------------
var panel_name := "Keskin Nişancı"         # the HUD's right panel title
var zoom_i := 0
var scoped := false                       # fully in the scope (overlay up, view model hidden)
var glint := 0.0                          # 0..1 lens glint others see
var bolt_t := 9.0                         # s since the last shot (bolt cycle while < BOLT_T)
var breath := BREATH_MAX
var holding_breath := false
var range_m := -1.0

var _gasp := 0.0
var _mag_s := 4.0                          # smoothed magnification
var _ss_t := 0.0
var _ss_amp := SWAY
var _ss := Vector2.ZERO
var _ss_prev := Vector2.ZERO
var _vm_hidden := false
var _scope
var _bolt: Node3D
var _bolt_arm: Node3D
var _mag: Node3D
var _mag_grab: Node3D
var _brake_flash: Node3D
var _hand_xf := Transform3D()
var _hand_w := 0.0
var _bolt_ev := 0
var _bolt_out := false                     # the last shot was taken scoped: drop out for the bolt
var _echo_t := -1.0
var _range_t := 0.0
var _watch := {}                           # bot instance id -> s in the crosshair
var _watch_cd := {}                        # bot instance id -> msec until it may react again
var _watch_t := 0.0
var _reload_queued := false
var _glare := 0.0


func _init() -> void:
	item_id = "sniper"
	item_name = "Keskin Nişancı Tüfeği"
	item_desc = "Sol tık: ateş (her atıştan sonra sürgü) · Sağ tık basılı: dürbün · teker / B: 4× ↔ 6× · Shift: nefesini tut · R: şarjör · Orta tık basılı: eklentiler (susturucu, refleks, holo)."
	icon = "sniper"
	slot_key = 0                               # the loadout (keys 1 / 2) carries it
	short_name = "Keskin"
	accent = Color(0.5, 0.88, 1.0)
	ammo_id = "ammo_sniper"
	ammo_title = ".338 · KESKİN NİŞANCI"
	base_mag = 5
	reload_kind = "mag"
	reload_time = 3.0
	reload_empty_time = 3.5
	fire_rate = 1.0 / (BOLT_T + 0.05)
	sight_rear = Vector3(0.0, SCOPE_Y, EYEPIECE_Z)
	ads_eye = Vector3(0.0, 0.0, -0.09)
	hip_pos = Vector3(0.17, -0.225, -0.36)
	hip_bore_y = BORE_Y
	hip_converge = 14.0
	sprint_pos = Vector3(0.14, -0.17, -0.38)
	sprint_rot = Vector3(-0.22, 0.6, 0.32)
	reload_pos = Vector3(0.12, -0.19, -0.4)
	reload_rot = Vector3(0.22, 0.25, 0.4)
	recoil_pivot = Vector3(0.0, 0.05, 0.3)
	aim_speed = 0.38
	spread_hip = 0.05                     # no-scope shots are a gamble
	spread_ads = 0.0
	bloom_add = 0.02
	bloom_max = 0.03
	kick_pitch = 0.14                     # recoil pass: a huge single kick
	recoil_view = 0.6
	kick_yaw = 0.025
	kick_roll = 0.03
	gun_kick = 16.0
	shake_amt = 0.9
	fov_punch_amt = -3.0
	noise_radius = 150.0
	crosshair_style = "ticks"
	hit_big = 0.9
	hit_punch = 2.0
	muzzle_energy = 24.0
	punch_db = -2.0
	impact_cal = 2.2                      # a .338 round: big dust jets, sparks and holes
	tail_db = -7.0
	flash_long = 1.3                      # the long muzzle jet
	recoil_climb = 0.0
	recoil_h = PackedFloat32Array([0.6, -0.4, 0.5, -0.6])
	recoil_hold = 0.12
	recoil_recover = 0.55                 # a heavy gun settles slowly
	head_mult = HEAD_X
	kill_launch = 8.5
	ads_k = 72.0                          # a big gun comes up to the eye a little slower
	ads_c = 12.5
	draw_time = 0.85
	holster_time = 0.5


func _ready() -> void:
	super._ready()
	_scope = SniperScope.new()
	add_child(_scope)


func mode_text() -> String:
	if not _has_scope():
		return "REFLEKS" if att_kit.optic() == "reflex" else "HOLO"
	return "%d×" % int(ZOOMS[zoom_i])


## The gun's own scope is on (no reflex / holo attachment in its place, attachments.gd): zoom,
## overlay, breath hold, rangefinder, glint.
func _has_scope() -> bool:
	return att_kit.optic() == ""


## B: the other zoom level.
func toggle_mode() -> void:
	if not _has_scope():
		super.toggle_mode()
		return
	_set_zoom(1 - zoom_i)


func _set_zoom(i: int) -> void:
	i = clampi(i, 0, ZOOMS.size() - 1)
	if i == zoom_i:
		return
	zoom_i = i
	_play("selector", -12.0, 0.8 if i == 0 else 0.95)


func _unhandled_input(event: InputEvent) -> void:
	# Mouse wheel while scoped: zoom level (otherwise the wheel stays free for others).
	if event is InputEventMouseButton and event.is_pressed() and ads > 0.5 and can_operate() and _has_scope():
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 0)
			get_viewport().set_input_as_handled()
			return
	super._unhandled_input(event)


func reload() -> void:
	# Never in the middle of the bolt cycle: finish it, then change the magazine.
	if bolt_t < BOLT_T:
		_reload_queued = mag < mag_capacity()
		return
	super.reload()


func _on_state_changed() -> void:
	super._on_state_changed()
	if not active or not equipped:
		_reload_queued = false
		holding_breath = false
		_set_vm_hidden(false)


# =================================================================================================
# Firing
# =================================================================================================

func _trigger(trig: bool, pressed: bool, alt: bool, delta: float) -> void:
	# A shot taken in the scope drops out of it for the bolt work, back in if RMB is still held.
	if _bolt_out and bolt_t > 0.08 and bolt_t < BOLT_T - 0.1:
		_ads_want = false
	elif bolt_t >= BOLT_T - 0.1:
		_bolt_out = false
	super._trigger(trig, pressed, alt, delta)


func fire() -> void:
	var e := _smooth(clampf(ads, 0.0, 1.0))
	# Scoped, the same kick in degrees would be a huge zoom punch: keep it small.
	fov_punch_amt = lerpf(-3.0, -0.5, e)
	_bolt_out = ads > 0.5
	super.fire()
	_cooldown = maxf(_cooldown, BOLT_T + 0.05)
	bolt_t = 0.0
	_bolt_ev = 0
	_glare = 1.0 if e > 0.8 and _has_scope() and not att_kit.suppressed() else 0.0
	if holding_breath:
		breath = maxf(breath - 0.6, 0.0)      # the shot costs a little of the held breath


func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var dir := _spread_dir(fwd, cb, current_spread())
	fx.bullet(eye, dir * MUZZLE_V * att_kit.stat("velocity") + player.velocity, muzzle, 0, Color(0.7, 0.95, 1.0), false, 0, 2.2)


## Scoped the view model is hidden: the tracer starts just under the eye instead.
func muzzle_world() -> Vector3:
	if ads > 0.85 and player != null and _vm_hidden:
		var cam: Camera3D = player.camera
		var cb := cam.global_transform.basis
		return cam.global_position - cb.z * 0.7 - cb.y * 0.07 + cb.x * 0.03
	return super.muzzle_world()


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(1.9)
	fx.muzzle_light(muzzle + fwd * 0.9, Color(1.0, 0.7, 0.36), muzzle_energy, 0.08, 20.0)
	fx.muzzle_smoke(muzzle + fwd * 0.15, fwd, up, 1.5)
	fx.muzzle_smoke(muzzle + fwd * 0.45, fwd, up, 1.4)
	fx.muzzle_smoke(muzzle + fwd * 0.8, fwd, up, 1.2)
	# Brake: side jets of smoke.
	fx.muzzle_smoke(muzzle - fwd * 0.03, cb.x, up, 1.3)
	fx.muzzle_smoke(muzzle - fwd * 0.03, -cb.x, up, 1.3)
	# The heavy shot jolts the picture (less inside the scope, where the view is already magnified).
	ScreenPunch.kick(lerpf(0.75, 0.4, clampf(ads, 0.0, 1.0)))


func _hit_damage(_p: Vector3, _ammo: int) -> float:
	return BODY_DMG


func _hit_impulse(_ammo: int) -> float:
	return 14.0                           # a survivor (armoured dummy) is shoved ~2 m/s: a stagger


func _hit_spec(p: Vector3, ammo: int) -> Dictionary:
	var s := super._hit_spec(p, ammo)
	s["heavy"] = true
	return s


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		# Vacuum: no report, only the heavy blow through the suit.
		_play("boom_body", -3.0, randf_range(0.82, 0.9), true)
		_play("thump", -3.0, 0.72, true)
		_shot_body(space, 0.75, -80.0)
		return
	# A heavy report: the dense 7.62 report (weap/ar_heavy) pitched down with its own decay, a lower
	# crack under it, a deep body, the punch, the slap-back and (outdoors) the rolling tail with a
	# distant echo rolling back a moment later.
	if _new_heavy:
		_play("heavy", -2.0, randf_range(0.84, 0.88), true, 1.0)
	else:
		_play("heavy", -1.0, randf_range(0.8, 0.85), true, 0.55)
	_play("shot", -12.0, randf_range(0.7, 0.75), true, 0.3)
	_play("boom_body", -4.0, randf_range(0.86, 0.92), true)
	_play("thump", -6.0, 0.8, true)
	_shot_body(space, 0.78, -9.0)
	if space == 2:
		if (_snd.get("gtail", []) as Array).is_empty():
			_play("tail", -9.0, randf_range(0.72, 0.8), true)
		_echo_t = 0.42
	elif space == 1:
		_play("tail", -15.0, 1.0, true, 0.4)


# =================================================================================================
# Per frame: bolt, breath, sway, zoom, scope, glint
# =================================================================================================

func _tick(delta: float, on: bool) -> void:
	bolt_t += delta
	_bolt_events()
	if _reload_queued and bolt_t >= BOLT_T and not reloading:
		_reload_queued = false
		super.reload()
	if _echo_t > 0.0:
		_echo_t -= delta
		if _echo_t <= 0.0:
			_play("echo", -10.0, randf_range(0.6, 0.66), true)
			if (_snd.get("gtail", []) as Array).is_empty():
				_play("tail", -17.0, 0.6, true)
			else:
				_play("gtail", -13.0, randf_range(0.74, 0.8), true)     # the far valley answering
	_glare = maxf(_glare - delta * 9.0, 0.0)
	_mag_s = lerpf(_mag_s, float(ZOOMS[zoom_i]), 1.0 - exp(-10.0 * delta))
	_update_breath(delta, on)
	_update_sway(delta, on)
	_bolt_pose()
	var e := clampf(ads, 0.0, 1.0)
	var sc := _has_scope()
	scoped = on and e > 0.88 and sc
	glint = smoothstep(0.5, 0.95, e) if on and sc else 0.0
	_set_vm_hidden(on and e > 0.9 and sc)
	if on and scoped:
		_range_t -= delta
		if _range_t <= 0.0:
			_range_t = 0.15
			range_m = _rangefind()
		_watch_bots(delta)
	_update_scope(delta, on)


## Hold Shift while scoped to hold the breath (steady); it runs out after BREATH_MAX s and leaves
## you out of breath (more sway) for BREATH_RECOVER s; it refills while breathing normally.
func _update_breath(delta: float, on: bool) -> void:
	_gasp = maxf(_gasp - delta, 0.0)
	var want := on and ads > 0.8 and not debug_ignore_input and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and Input.is_action_pressed("sprint") and _gasp <= 0.0 and breath > 0.0
	if want and not holding_breath:
		holding_breath = true
		_breath_sfx("in", "breath_in", -16.0, randf_range(0.95, 1.05))
	elif not want and holding_breath:
		holding_breath = false
		_breath_sfx("out" if breath > 0.0 else "gasp", "breath_out", -15.0 if breath > 0.0 else -10.0, randf_range(0.95, 1.05))
		if breath <= 0.0:
			_gasp = BREATH_RECOVER
	if holding_breath:
		breath = maxf(breath - delta, 0.0)
		if breath <= 0.0:
			holding_breath = false
			_gasp = BREATH_RECOVER
			_breath_sfx("gasp", "breath_out", -9.0, 0.9)
	elif _gasp <= 0.0:
		breath = minf(breath + delta * 1.0, BREATH_MAX)


## The breath hold's sounds go to the helmet's one breathing voice (scripts/ui/helmet_fx.gd
## sniper_breath: "in" / "out" / "gasp"; it also falls silent while the breath is held); the
## synthesized `fallback` plays only when that is not ready.
func _breath_sfx(kind: String, fallback: String, db: float, pitch: float) -> void:
	var h = HelmetFx.peek()
	if h != null and h.sniper_breath(kind):
		return
	_play(fallback, db, pitch)


## Scope sway (camera, rad): a slow figure-eight plus breathing; still < moving < airborne; crouched
## much less; held breath almost none; out of breath and right after a shot more.
func _update_sway(delta: float, on: bool) -> void:
	_ss_t += delta
	var amp := SWAY
	if player != null and on:
		var up: Vector3 = player.global_transform.basis.y
		var hv: Vector3 = player.velocity - up * player.velocity.dot(up)
		amp *= lerpf(1.0, 2.6, clampf(hv.length() / 3.0, 0.0, 1.0))
		if not player.is_on_floor():
			amp *= 3.0
		amp *= lerpf(1.0, 0.32, GunFeel.crouch_k(player))
	if holding_breath:
		amp *= 0.12
	elif _gasp > 0.0:
		amp *= 1.0 + 1.8 * clampf(_gasp / BREATH_RECOVER, 0.0, 1.0)
	amp *= 1.0 + clampf(1.0 - bolt_t, 0.0, 1.0) * 0.6
	_ss_amp = lerpf(_ss_amp, amp, 1.0 - exp(-4.0 * delta))
	var t := _ss_t
	var s := Vector2(sin(t * 0.83) + 0.45 * sin(t * 2.11 + 0.7), sin(t * 1.27 + 1.3) * 0.8 + 0.4 * sin(t * 0.51))
	var breathe := 0.0 if holding_breath else sin(t * (1.6 + 1.4 * clampf(_gasp, 0.0, 1.0))) * 0.7
	_ss_prev = _ss
	_ss = (s + Vector2(0.0, breathe)) * _ss_amp


func _cam_extra() -> Vector3:
	var e := _smooth(clampf(ads, 0.0, 1.0))
	return Vector3(_ss.y, _ss.x, 0.0) * e * (1.0 if _has_scope() else 0.4)


## Hip → a mild narrowing while the gun comes up, then into the scope (tan-space blend, so the zoom
## feels even) as it reaches the eye.
func _cam_fov(e: float) -> float:
	if not _has_scope():
		return super._cam_fov(e)                 # a reflex / holo: the attachment's ADS FOV
	var base: float = Settings.fov
	var t1 := _smooth(e / 0.6)
	var pre := base - 8.0 * t1
	var t2 := _smooth((e - 0.6) / 0.4)
	var zt := tan(deg_to_rad(base) * 0.5) / maxf(_mag_s, 1.0)
	var pt := tan(deg_to_rad(pre) * 0.5)
	return rad_to_deg(2.0 * atan(lerpf(pt, zt, t2)))


## Mouse look scales with the magnification.
func _cam_look(e: float) -> float:
	if not _has_scope():
		return super._cam_look(e)
	var f := _cam_fov(e)
	return clampf(tan(deg_to_rad(f) * 0.5) / tan(deg_to_rad(Settings.fov) * 0.5), 0.08, 1.0)


func _update_scope(delta: float, on: bool) -> void:
	if _scope == null:
		return
	var k := smoothstep(0.72, 0.97, clampf(ads, 0.0, 1.0)) if on and _has_scope() else 0.0
	_scope.k = k
	_scope.zoom = float(ZOOMS[zoom_i])
	_scope.range_m = range_m
	_scope.breath = breath / BREATH_MAX
	_scope.holding = holding_breath
	_scope.gasp = clampf(_gasp / BREATH_RECOVER, 0.0, 1.0)
	_scope.flash = _glare
	# Eye-box shadow: the scope lags behind the view when it moves or kicks.
	var sv := (_ss - _ss_prev) / maxf(delta, 0.001)
	var target := Vector2(-sv.x, sv.y) * 0.9 + Vector2(_recoil.y, -_recoil.x) * 2.5
	_scope.shadow = _scope.shadow.lerp(target.limit_length(0.35), 1.0 - exp(-8.0 * delta))
	_scope.update(delta)


func _set_vm_hidden(h: bool) -> void:
	if h == _vm_hidden or player == null:
		return
	_vm_hidden = h
	var vm = player.get("viewmodel")
	if vm == null:
		return
	if h:
		vm.visible = false
	elif not player.is_ragdolled() and not (player.has_method("is_dead") and player.is_dead()):
		vm.visible = true


## Distance to whatever is under the reticle (physics; far terrain without collision reads "---").
func _rangefind() -> float:
	var cam: Camera3D = player.camera
	var from := cam.global_position
	var to := from - cam.global_transform.basis.z * 1500.0
	var q := PhysicsRayQueryParameters3D.create(from, to, Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE | Game.LAYER_PLAYER,
			[player.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return -1.0 if hit.is_empty() else from.distance_to(hit["position"])


## Bots kept in the crosshair for WATCH_TIME see the lens glint and react (they take it as a threat
## from here: ai_rival.gd help_call). 4 Hz, cheap even with 70 bots.
func _watch_bots(delta: float) -> void:
	_watch_t -= delta
	if _watch_t > 0.0:
		return
	var step := 0.25 - _watch_t
	_watch_t = 0.25
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var now := Time.get_ticks_msec()
	for b in get_tree().get_nodes_in_group("war_ai"):
		if not (b is Node3D) or not b.has_method("help_call"):
			continue
		if b.has_method("is_dead") and b.is_dead():
			continue
		var id: int = b.get_instance_id()
		var c: Vector3 = (b as Node3D).global_position + (b as Node3D).global_transform.basis.y * 1.3
		var to := c - eye
		var d := to.length()
		if d > WATCH_RANGE or d < 5.0 or fwd.dot(to / d) < cos(WATCH_CONE + 1.5 / d):
			_watch.erase(id)
			continue
		var w := float(_watch.get(id, 0.0)) + step
		_watch[id] = w
		if w >= WATCH_TIME and now >= int(_watch_cd.get(id, 0)):
			_watch_cd[id] = now + 8000
			var q := PhysicsRayQueryParameters3D.create(eye, c, Game.LAYER_TERRAIN, [player.get_rid()])
			if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
				b.help_call(player.global_position + player.global_transform.basis.y * 1.2)


# =================================================================================================
# Bolt and reload animation
# =================================================================================================

## Bolt cycle sounds and the case ejection, timed to the animation.
func _bolt_events() -> void:
	if bolt_t > BOLT_T + 0.5:
		return
	var u := bolt_t / BOLT_T
	var marks := [0.3, 0.43, 0.56, 0.7, 0.86]
	while _bolt_ev < marks.size() and u >= float(marks[_bolt_ev]):
		match _bolt_ev:
			0:
				_play("bolt_lift", -8.0, randf_range(0.88, 0.95))
			1:
				_play("bolt_back", -5.0, randf_range(0.78, 0.84))
				_rk_vel += Vector4(0.0, 0.0, 0.3, 0.15)
			2:
				_eject_case()
			3:
				_play("bolt_fwd", -4.0, randf_range(0.78, 0.84))
				_rk_vel += Vector4(0.5, 0.0, -0.2, -0.2)
			4:
				_play("bolt_drop", -7.0, randf_range(0.88, 0.95))
				_rk_vel += Vector4(0.25, 0.0, 0.0, 0.0)
		_bolt_ev += 1


func _eject_case() -> void:
	if player == null or _eject == null or fx == null:
		return
	var cb: Basis = player.camera.global_transform.basis
	var up: Vector3 = player.global_transform.basis.y
	fx.shell(_vm_world(_eject), cb.x * randf_range(1.6, 2.4) + up * randf_range(1.6, 2.4) - (-cb.z) * 0.4 + player.velocity, true)


## Hand-on-bolt weight, handle lift (0..1) and bolt travel (0..1) at this moment: after a shot, or
## at the end of an empty reload.
func _bolt_amounts() -> Vector3:
	var hw := 0.0
	var lift := 0.0
	var trav := 0.0
	if bolt_t < BOLT_T:
		var u := bolt_t / BOLT_T
		hw = _seg(u, 0.12, 0.28) * (1.0 - _seg(u, 0.88, 1.0))
		lift = _seg(u, 0.28, 0.38) * (1.0 - _seg(u, 0.82, 0.9))
		trav = _seg(u, 0.42, 0.56) * (1.0 - _seg(u, 0.64, 0.78))
	elif reloading and _reload_empty:
		var r := reload_progress()
		hw = _seg(r, 0.72, 0.78) * (1.0 - _seg(r, 0.94, 0.99))
		lift = _seg(r, 0.78, 0.81) * (1.0 - _seg(r, 0.9, 0.92))
		trav = _seg(r, 0.81, 0.85) * (1.0 - _seg(r, 0.86, 0.9))
	return Vector3(hw, lift, trav)


## Poses the bolt and puts the right hand on its knob: the hand frame H (gun space) moves the hand
## rig, and the gun is shifted by H⁻¹ inside the hand so it stays where it was (_update_pose /
## _animate_model).
func _bolt_pose() -> void:
	if _bolt == null:
		return
	var a := _bolt_amounts()
	_hand_w = a.x
	_bolt.position = Vector3(0.0, BORE_Y, a.z * BOLT_TRAVEL)
	_bolt_arm.transform = Transform3D(Basis(Vector3(0, 0, 1), BOLT_REST + a.y * BOLT_LIFT), Vector3(0, 0, BOLT_ARM_Z))
	if _hand_w <= 0.001:
		_hand_xf = Transform3D()
		return
	var knob: Vector3 = _bolt.transform * (_bolt_arm.transform * KNOB)
	var f := FOREARM.normalized()
	var hb := Basis(Vector3(0, 0, 1), a.y * BOLT_LIFT * 0.55) * Basis(f, -1.15)
	var full := Transform3D(hb, knob + hb * Vector3(0.0, 0.028, 0.0))
	_hand_xf = Transform3D().interpolate_with(full, _hand_w)


func _pose_extra() -> Transform3D:
	# While the bolt is worked the gun rolls toward the shooter and comes up a little.
	var w := _smooth(_hand_w)
	return Transform3D(Basis.from_euler(Vector3(0.05 * w, 0.06 * w, 0.2 * w)), Vector3(-0.015 * w, 0.02 * w, 0.015 * w))


func _update_pose(dt: float, on: bool) -> void:
	super._update_pose(dt, on)
	pose_override = pose_override * _hand_xf


func _reload_events(u: float) -> void:
	var marks := [0.05, 0.14, 0.22, 0.6, 0.68, 0.81, 0.87]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -16.0, randf_range(0.9, 1.1))
			1:
				_play("mag_release", -9.0, 0.8)
			2:
				_play("mag_out", -8.0, 0.8)
			3:
				_play("mag_in", -6.0, 0.8)
				_rk_vel.w += 0.25
			4:
				_play("mag_slap", -5.0, 0.85)
				_rk_vel.x += 0.6
			5:
				if _reload_empty:
					_play("bolt_lift", -8.0, 0.9)
					_play("bolt_back", -6.0, 0.8)
			6:
				if _reload_empty:
					_play("bolt_fwd", -4.0, 0.8)
					_play("bolt_drop", -8.0, 0.92)
					_rk_vel += Vector4(0.8, 0.0, 0.0, 0.3)
		_reload_ev += 1


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null:
		return
	if _brake_flash != null:
		_brake_flash.visible = _flash_t > 0.0 and att_kit.muzzle_device() == ""   # (no ports on a suppressor)
	# Magazine: the left hand pulls it, takes it away, brings a new one and seats it.
	var u := reload_progress() if reloading else 0.0
	var drop := 0.0
	var vis := true
	var slap := 0.0
	if reloading:
		left_reach_w = _seg(u, 0.03, 0.13) * (1.0 - _seg(u, 0.74, 0.84))
		drop = lerpf(0.0, 0.05, _seg(u, 0.13, 0.22)) + lerpf(0.0, 0.4, _seg(u, 0.22, 0.38))
		if u > 0.44:
			drop = lerpf(0.45, 0.03, _seg(u, 0.46, 0.6)) * (1.0 - _seg(u, 0.6, 0.67))
		vis = u < 0.4 or u > 0.47
		slap = sin(clampf((u - 0.67) / 0.07, 0.0, 1.0) * PI)
		if left_reach_w > 0.0 and player != null:
			var cam_inv: Transform3D = player.camera.global_transform.affine_inverse()
			left_reach = cam_inv * _mag_grab.global_position + Vector3(0.0, 0.03 * slap, 0.0)
			left_reach_elbow = Vector3(-0.3, -0.85, 0.45)
	else:
		left_reach_w = 0.0
	_mag.position = MAG_REST + MAG_AXIS * drop
	var tumble := clampf((drop - 0.1) / 0.3, 0.0, 1.0)
	_mag.rotation = Vector3(tumble * 0.5, 0.0, tumble * 0.35)
	_mag.visible = vis
	# The hand on the bolt: shift the gun inside the hand so it stays put on screen.
	var slap_xf := Transform3D(Basis.from_euler(Vector3(slap * 0.025, 0.0, 0.0)), Vector3(0.0, slap * 0.005, 0.0))
	_gun.transform = _hand_xf.affine_inverse() * slap_xf


# =================================================================================================
# Model
# =================================================================================================

## First-person model, NMS-like white / orange / gunmetal like the rifle: chassis with a pistol grip
## and a skeleton stock (orange cheek riser), round action with an animated bolt (handle + knob),
## detachable 5-round magazine, long octagonal handguard with a hand stop, heavy fluted barrel,
## three-port muzzle brake, a folded bipod, and a big scope (rings, turrets, parallax knob, power
## ring, sunshade, lens glass at both ends).
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
	var gun := VM.mat(Color(0.12, 0.13, 0.14), 0.3, 0.8)
	var by := BORE_Y
	# Grip, trigger and guard.
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.0235, -0.02), Vector3(0, -0.0235, -0.075), 0.0045, steel)      # low: room for the trigger finger
	VM.capsule(_gun, Vector3(0, -0.0235, -0.075), Vector3(0, 0.018, -0.088), 0.0045, steel)
	# Chassis (white) under the action, orange side bands, magazine well.
	VM.soft_box(_gun, Vector3(0, 0.03, -0.07), Vector3(0.052, 0.046, 0.31), 0.012, white)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0265 * sx, 0.026, -0.08), Vector3(0.003, 0.01, 0.25), orange)
		for i in 3:
			VM.box(_gun, Vector3(0.0268 * sx, 0.038, 0.02 - i * 0.03), Vector3(0.003, 0.008, 0.016), dark)
	VM.box(_gun, Vector3(0, 0.006, -0.123), Vector3(0.034, 0.008, 0.078), gray)
	# Round action (receiver) with the ejection port; bolt shroud at the back.
	VM.seg(_gun, Vector3(0, by, 0.06), Vector3(0, by, -0.205), 0.0215, 0.0215, gun, 22)
	VM.ring(_gun, Vector3(0, by, -0.205), Vector3.FORWARD, 0.0225, 0.004, orange)
	VM.box(_gun, Vector3(0.019, by + 0.006, -0.03), Vector3(0.006, 0.017, 0.058), black)
	_eject = VM.node(_gun, Vector3(0.03, by + 0.008, -0.03))
	# Scope rail on the action.
	VM.box(_gun, Vector3(0, by + 0.027, -0.07), Vector3(0.022, 0.008, 0.26), dark)
	for i in 10:
		VM.box(_gun, Vector3(0, by + 0.032, 0.04 - i * 0.024), Vector3(0.024, 0.004, 0.009), dark)
	# Bolt: body inside the action (shows when pulled), shroud with an orange cap, handle + knob.
	_bolt = VM.node(_gun, Vector3(0, by, 0))
	VM.seg(_bolt, Vector3(0, 0, 0.07), Vector3(0, 0, -0.1), 0.0135, 0.0135, steel, 14)
	VM.seg(_bolt, Vector3(0, 0, 0.06), Vector3(0, 0, 0.098), 0.0172, 0.0155, gun, 16)
	VM.seg(_bolt, Vector3(0, 0, 0.098), Vector3(0, 0, 0.104), 0.0155, 0.012, orange, 16)
	_bolt_arm = VM.node(_bolt, Vector3(0, 0, BOLT_ARM_Z), Basis(Vector3(0, 0, 1), BOLT_REST))
	VM.seg(_bolt_arm, Vector3(0, 0.008, 0), Vector3(0, 0.02, 0.002), 0.008, 0.0065, steel, 12)
	VM.capsule(_bolt_arm, Vector3(0, 0.02, 0.002), Vector3(0, 0.056, 0.012), 0.0045, steel, 10)
	VM.sphere(_bolt_arm, KNOB, 0.0115, orange)
	VM.ring(_bolt_arm, KNOB - Vector3(0, 0.006, 0.0015), Vector3(0, 1, 0.25), 0.0105, 0.0025, dark)
	# Magazine (the left hand pulls it on reload).
	_mag = VM.node(_gun, MAG_REST)
	var mb := Basis(Vector3.RIGHT, 0.12)
	VM.soft_box(_mag, Vector3(0, -0.022, -0.002), Vector3(0.03, 0.06, 0.07), 0.008, dark, mb)
	VM.box(_mag, mb * Vector3(0, -0.055, 0.0) + Vector3(0, 0, -0.002), Vector3(0.034, 0.012, 0.075), orange, mb)
	for sx in [-1.0, 1.0]:
		VM.box(_mag, mb * Vector3(0.0155 * sx, -0.02, 0.0), Vector3(0.002, 0.03, 0.012), VM.glow(accent, 2.5), mb)
	_mag_grab = VM.node(_mag, mb * Vector3(-0.03, -0.1, 0.02))
	# Skeleton stock: top bar, orange cheek riser, rear plate, rubber pad, lower strut, monopod knob.
	VM.soft_box(_gun, Vector3(0, 0.062, 0.19), Vector3(0.04, 0.03, 0.22), 0.011, white)
	VM.soft_box(_gun, Vector3(0, 0.084, 0.2), Vector3(0.034, 0.022, 0.13), 0.009, orange)
	VM.box(_gun, Vector3(0, 0.097, 0.2), Vector3(0.026, 0.004, 0.11), rubber)
	VM.soft_box(_gun, Vector3(0, 0.03, 0.29), Vector3(0.042, 0.13, 0.034), 0.011, white)
	VM.soft_box(_gun, Vector3(0, 0.03, 0.312), Vector3(0.044, 0.138, 0.014), 0.005, rubber)
	VM.capsule(_gun, Vector3(0, 0.016, 0.08), Vector3(0, -0.026, 0.28), 0.0105, dark)
	VM.seg(_gun, Vector3(0, -0.04, 0.24), Vector3(0, -0.06, 0.24), 0.008, 0.008, dark, 10)
	VM.sphere(_gun, Vector3(0, -0.062, 0.24), 0.01, rubber)
	# Handguard: long octagonal tube with slots, top rail, glow strips under it, hand stop.
	VM.seg(_gun, Vector3(0, by, -0.2), Vector3(0, by, -0.6), 0.031, 0.029, white, 8)
	for i in 8:
		for sx in [-1.0, 1.0]:
			VM.box(_gun, Vector3(0.0285 * sx, by, -0.235 - i * 0.045), Vector3(0.006, 0.014, 0.026), dark)
	VM.box(_gun, Vector3(0, by + 0.031, -0.4), Vector3(0.016, 0.006, 0.36), dark)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.018 * sx, by - 0.027, -0.42), Vector3(0.003, 0.004, 0.3), VM.glow(accent, 2.0))
	VM.ring(_gun, Vector3(0, by, -0.6), Vector3.FORWARD, 0.031, 0.006, orange)
	VM.ring(_gun, Vector3(0, by, -0.205), Vector3.FORWARD, 0.033, 0.005, dark)
	VM.soft_box(_gun, Vector3(0, 0.024, -0.34), Vector3(0.022, 0.016, 0.05), 0.006, dark)
	VM.capsule(_gun, Vector3(0, -0.05, -0.338), Vector3(0, 0.01, -0.342), 0.0165, rubber)
	VM.seg(_gun, Vector3(0, -0.074, -0.336), Vector3(0, -0.062, -0.337), 0.019, 0.018, orange)
	left_grip = VM.node(_gun, Vector3(0, 0.004, -0.342), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	# Heavy fluted barrel.
	VM.seg(_gun, Vector3(0, by, -0.6), Vector3(0, by, -0.975), 0.0148, 0.013, steel, 18)
	for k in 6:
		var ang := TAU * float(k) / 6.0
		var off := Vector3(cos(ang), sin(ang), 0.0) * 0.0138
		VM.box(_gun, Vector3(0, by, -0.785) + off, Vector3(0.004, 0.004, 0.3), dark, Basis(Vector3.BACK, ang))
	# Three-port muzzle brake (its own node: a fitted suppressor replaces it).
	var brake := VM.node(_gun)
	VM.soft_box(brake, Vector3(0, by, -1.01), Vector3(0.036, 0.032, 0.075), 0.009, gun)
	for i in 3:
		for sx in [-1.0, 1.0]:
			VM.box(brake, Vector3(0.0175 * sx, by, -0.988 - i * 0.02), Vector3(0.004, 0.02, 0.009), black)
	VM.ring(brake, Vector3(0, by, -1.048), Vector3.FORWARD, 0.013, 0.004, steel)
	_muzzle = VM.node(_gun, Vector3(0, by, -1.055))
	# Bipod, folded forward under the handguard.
	VM.soft_box(_gun, Vector3(0, by - 0.04, -0.56), Vector3(0.03, 0.014, 0.03), 0.005, dark)
	for sx in [-1.0, 1.0]:
		VM.capsule(_gun, Vector3(0.012 * sx, by - 0.046, -0.57), Vector3(0.013 * sx, by - 0.046, -0.83), 0.0055, dark, 10)
		VM.ring(_gun, Vector3(0.0125 * sx, by - 0.046, -0.7), Vector3.FORWARD, 0.0072, 0.002, orange)
		VM.sphere(_gun, Vector3(0.013 * sx, by - 0.046, -0.838), 0.009, rubber)
	# Scope: rings, tube, power ring + eyecup, objective bell + sunshade, turrets, glass (its own node:
	# a fitted reflex / holo replaces it; the rail stays).
	var scope := VM.node(_gun)
	var sy := SCOPE_Y
	for z in [0.02, -0.15]:
		VM.box(scope, Vector3(0, (by + 0.031 + sy - 0.017) * 0.5, z), Vector3(0.016, sy - 0.017 - by - 0.031 + 0.004, 0.018), dark)
		VM.ring(scope, Vector3(0, sy, z), Vector3.FORWARD, 0.0195, 0.0045, dark)
		VM.box(scope, Vector3(0.016, sy - 0.006, z), Vector3(0.008, 0.008, 0.014), steel)
	VM.seg(scope, Vector3(0, sy, 0.075), Vector3(0, sy, -0.24), 0.0165, 0.0165, gun, 22)
	VM.seg(scope, Vector3(0, sy, 0.075), Vector3(0, sy, 0.105), 0.0172, 0.0215, gun, 22)
	VM.seg(scope, Vector3(0, sy, 0.04), Vector3(0, sy, 0.07), 0.0182, 0.0182, rubber, 22)
	VM.box(scope, Vector3(0, sy + 0.0185, 0.055), Vector3(0.004, 0.002, 0.012), orange)
	VM.seg(scope, Vector3(0, sy, 0.105), Vector3(0, sy, EYEPIECE_Z), 0.0225, 0.023, rubber, 22)
	VM.seg(scope, Vector3(0, sy, -0.24), Vector3(0, sy, -0.3), 0.0165, 0.0305, gun, 24)
	VM.seg(scope, Vector3(0, sy, -0.3), Vector3(0, sy, -0.36), 0.0305, 0.031, gun, 24)
	VM.ring(scope, Vector3(0, sy, -0.3), Vector3.FORWARD, 0.0315, 0.004, orange)
	VM.ring(scope, Vector3(0, sy, -0.36), Vector3.FORWARD, 0.0312, 0.003, dark)
	# Elevation turret (top), windage (right), parallax (left).
	VM.seg(scope, Vector3(0, sy + 0.015, -0.07), Vector3(0, sy + 0.034, -0.07), 0.0125, 0.0125, gun, 18)
	VM.seg(scope, Vector3(0, sy + 0.034, -0.07), Vector3(0, sy + 0.04, -0.07), 0.0125, 0.0115, orange, 18)
	for i in 3:
		VM.ring(scope, Vector3(0, sy + 0.019 + i * 0.005, -0.07), Vector3.UP, 0.0132, 0.0014, dark)
	VM.seg(scope, Vector3(0.015, sy, -0.07), Vector3(0.034, sy, -0.07), 0.0115, 0.0115, gun, 18)
	VM.seg(scope, Vector3(0.034, sy, -0.07), Vector3(0.039, sy, -0.07), 0.0115, 0.0105, orange, 18)
	VM.seg(scope, Vector3(-0.015, sy, -0.035), Vector3(-0.03, sy, -0.035), 0.0105, 0.0105, gun, 16)
	VM.box(scope, Vector3(-0.031, sy + 0.007, -0.035), Vector3(0.002, 0.004, 0.004), orange)
	# Lens glass: the objective catches a cool coating tint, the ocular is dark.
	var g1 := VM.seg(scope, Vector3(0, sy, -0.345), Vector3(0, sy, -0.347), 0.0285, 0.0285, VM.glass(Color(0.25, 0.55, 0.85, 0.35)), 24)
	g1.set_meta("no_bake", true)
	var g2 := VM.ring(scope, Vector3(0, sy, -0.346), Vector3.FORWARD, 0.0255, 0.0015, VM.glow(Color(0.35, 0.85, 1.0), 1.2))
	g2.set_meta("no_bake", true)
	var g3 := VM.seg(scope, Vector3(0, sy, EYEPIECE_Z - 0.006), Vector3(0, sy, EYEPIECE_Z - 0.004), 0.0195, 0.0195, VM.glass(Color(0.05, 0.12, 0.16, 0.6)), 24)
	g3.set_meta("no_bake", true)
	# Muzzle flash: the face star plus side plumes out of the brake ports.
	_make_flash(_gun, Vector3(0, by, -1.065), 1.9)
	_brake_flash = VM.node(_gun, Vector3(0, by, -1.008))
	var bq := QuadMesh.new()
	bq.size = Vector2(0.12, 0.06)
	for sx in [-1.0, 1.0]:
		var mi := VM.mesh_inst(_brake_flash, bq, _flash_mat)
		mi.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.07 * sx, 0, 0))
	_brake_flash.visible = false
	VM.bake(_gun, [_bolt, _mag, _flash_root, _brake_flash, _muzzle, _eject, left_grip, brake, scope])
	VM.bake(_bolt, [_bolt_arm])
	VM.bake(_bolt_arm)
	VM.bake(_mag, [_mag_grab])
	VM.bake(brake)
	VM.bake(scope)
	# Attachment mounts (attachments.gd): the suppressor in place of the brake, a reflex / holo on the
	# scope rail in place of the scope (no zoom, overlay or glint then; _has_scope()).
	att_kit.build(self, _gun, {
		"muzzle": {"at": Vector3(0, by, -0.968), "r": 0.013, "tip": -1.05, "sup_r": 0.022, "sup_len": 0.21,
			"shift": [_muzzle, _flash_root], "default": brake},
		"optic": {"y": by + 0.034, "z": -0.03, "irons": 0.0, "default": scope},
	})
	return model


# =================================================================================================
# Third-person model (the player's body, remote avatars)
# =================================================================================================

func _build_tp(p: Node3D) -> Node3D:
	return build_tp_model(p)


## Simplified model under prop root `p` (grip at the origin, -Z forward) with a lens glint (meta
## "glint_mat"). Returns the muzzle node.
static func build_tp_model(p: Node3D) -> Node3D:
	var white := _mat3(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _mat3(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _mat3(Color(0.14, 0.15, 0.17), 0.35, 0.7)
	var rubber := _mat3(Color(0.08, 0.08, 0.09), 0.9, 0.0)
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.032, -0.07), Vector3(0.052, 0.046, 0.31), white)
	VM.seg(p, Vector3(0, BORE_Y, 0.06), Vector3(0, BORE_Y, -0.2), 0.021, 0.021, dark, 10)
	VM.box(p, Vector3(0, 0.062, 0.19), Vector3(0.04, 0.03, 0.22), white)
	VM.box(p, Vector3(0, 0.084, 0.2), Vector3(0.034, 0.022, 0.13), orange)
	VM.box(p, Vector3(0, 0.03, 0.3), Vector3(0.044, 0.13, 0.04), white)
	VM.box(p, Vector3(0, -0.025, -0.085), Vector3(0.03, 0.06, 0.07), dark)
	VM.seg(p, Vector3(0, BORE_Y, -0.2), Vector3(0, BORE_Y, -0.6), 0.03, 0.029, white, 8)
	VM.seg(p, Vector3(0, BORE_Y, -0.6), Vector3(0, BORE_Y, -0.975), 0.015, 0.013, dark, 10)
	VM.box(p, Vector3(0, BORE_Y, -1.01), Vector3(0.036, 0.032, 0.075), dark)
	VM.seg(p, Vector3(0, SCOPE_Y, 0.11), Vector3(0, SCOPE_Y, -0.24), 0.018, 0.018, dark, 12)
	VM.seg(p, Vector3(0, SCOPE_Y, -0.24), Vector3(0, SCOPE_Y, -0.36), 0.018, 0.031, dark, 12)
	VM.ring(p, Vector3(0, SCOPE_Y, -0.3), Vector3.FORWARD, 0.0315, 0.004, orange)
	VM.box(p, Vector3(0, SCOPE_Y + 0.025, -0.07), Vector3(0.024, 0.02, 0.024), rubber)
	# Lens glint: a billboard at the objective that flares when its axis points at the viewer.
	if _glint_shader == null:
		_glint_shader = Shader.new()
		_glint_shader.code = GLINT_SHADER
	var gm := ShaderMaterial.new()
	gm.shader = _glint_shader
	gm.set_shader_parameter("strength", 0.0)
	var gq := QuadMesh.new()
	gq.size = Vector2(0.5, 0.5)
	var gi := MeshInstance3D.new()
	gi.mesh = gq
	gi.material_override = gm
	gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi.position = Vector3(0, SCOPE_Y, -0.37)
	gi.set_meta("no_bake", true)
	p.add_child(gi)
	p.set_meta("glint_mat", gm)
	return VM.node(p, Vector3(0, BORE_Y, -1.06))


static func _mat3(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


## Builds and registers this gun's third-person prop on any astronaut (remote avatars):
## props["sniper"] / prop_tips["sniper"], hidden until set_held("sniper").
static func build_tp_on(ast) -> Node3D:
	if ast == null or not ("props" in ast) or not ("hand" in ast):
		return null
	if ast.props.has("sniper"):
		return ast.props["sniper"]
	var hands: Array = ast.hand
	if hands.size() < 2 or hands[1] == null:
		return null
	var p := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
	var tip := build_tp_model(p)
	p.visible = false
	ast.props["sniper"] = p
	ast.prop_tips["sniper"] = tip
	return p


## Lens glint strength (0..1) on an astronaut's sniper prop (remote players' `glint` state).
static func set_glint(ast, k: float) -> void:
	if ast == null or not ("props" in ast):
		return
	var p = ast.props.get("sniper")
	if p is Node and (p as Node).has_meta("glint_mat"):
		((p as Node).get_meta("glint_mat") as ShaderMaterial).set_shader_parameter("strength", clampf(k, 0.0, 1.0))
