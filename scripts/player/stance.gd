extends Node
## Crouch and slide for the on-foot player (player.gd owns one: `stance`, hooked into its movement,
## head bob, footsteps, camera and body animation).
##   Crouch  hold Left Ctrl ("crouch") or toggle with C ("crouch_toggle"); the same keys are the
##           shuttle's "descend", ignored here while seated. The eye drops EYE_CROUCH (eased ~0.15 s),
##           the capsule shrinks to CROUCH_H, you move at CROUCH_SPEED of the walk with quieter steps
##           and a smaller head bob, and cannot sprint: sprint (when not holding Ctrl), jump and the
##           jetpack stand you up. Standing needs headroom (a sphere cast along the local up), so in
##           a tunnel you stay down ("Ayağa kalkmak için yer yok" only when you try).
##   Slide   crouch while sprinting on the ground above SLIDE_MIN of the sprint speed: a burst
##           (SLIDE_BOOST, capped at SLIDE_MAX) that friction eats in ~0.9 s, longer and faster
##           downhill / shorter uphill (gravity along the floor normal, local up), steerable a little
##           (mouse / A-D). Jumping out keeps the momentum (slide-hop, capped at HOP_MAX, cooldown
##           SLIDE_COOLDOWN). It ends crouched, or standing if the crouch key is released and there is
##           room. Camera EYE_SLIDE low with a slight roll into the steer, a small FOV kick and ground
##           rumble; your own body is in view (astronaut.set_legs_view: the whole suit minus helmet and arms,
##           neck under the eye, dissolving near the eye);
##           heel dust in the ground colour, clods on dug soil, a scrape loop pitched by speed (a soft
##           suit-borne scrape in vacuum) and faint speed lines.
##   Looking down (any stance) also shows your own body (body awareness).
## Exposed on the player (weapons, multiplayer): crouching, crouch_k, sliding, slide_k, fov_kick.
## Hooks (player.gd): pre_move(), speed_mult(), blocks_sprint(), slide_step(), on_jump() /
## jump_mult(), eye_drop(), bob_mult(), cam_rot(), step_db(), reset().

const Settings := preload("res://scripts/save/settings.gd")
const WeaponAudio := preload("res://scripts/items/weapon_audio.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")

const STAND_H := 1.8
const CROUCH_H := 1.35                  # capsule; the crouched eye (1.25 m) stays 0.1 m under its top
const RADIUS := 0.35
const EYE_CROUCH := 0.47                # matched to the crouch pose (astronaut.gd): the eye 0.12 m over the neck
const EYE_SLIDE := 0.74                 # matched to the reclined slide pose
const EASE_T := 0.05                       # eye drop smoothing constant (~0.15 s to settle)
const CROUCH_SPEED := 0.45
const SLIDE_MIN := 0.7                     # × player SPRINT speed to start a slide
# 2026-10-06 tok ("oyun daha yavaş, tok hissettirmeli"): a smaller burst that carries (less friction),
# steers less, comes less often; a softer FOV kick.
const SLIDE_BOOST := 1.25                  # (tok: 1.35 -> 1.25)
const SLIDE_MAX := 8.8                     # m/s (was 9.5 with the old 6.2 m/s sprint; tok: 11.5 -> 8.8)
const SLIDE_FRICTION := 4.0                # m/s² (tok: 5.0 -> 4.0)
const SLIDE_DRAG := 0.3                    # 1/s (tok: 0.35 -> 0.3)
const SLIDE_SLOPE := 1.0                   # share of the gravity along the floor that acts
const SLIDE_STEER := 1.1                   # rad/s the slide turns toward the look / A-D (tok: 1.5 -> 1.1)
const SLIDE_END := 2.2                     # m/s: slower ends the slide
const SLIDE_MAX_T := 1.4                   # s (longer only while it keeps its speed downhill)
const SLIDE_COOLDOWN := 0.9                # (tok: 0.6 -> 0.9)
const HOP_MAX := 7.0                       # m/s horizontal after a slide-hop (tok: 8.0 -> 7.0)
const FOV_KICK := 5.0                      # degrees at full slide speed (tok: 7.0 -> 5.0)
const HINT := "Ayağa kalkmak için yer yok"
const PLAYER_SPRINT := 6.8                 # player.gd SPRINT (m/s) (tok: 8.2 -> 6.8)

const LINES_SHADER := """
shader_type canvas_item;
uniform float k = 0.0;
uniform float t = 0.0;
uniform float aspect = 1.777;

float hash(float x) { return fract(sin(x * 91.17) * 43758.5453); }

void fragment() {
	vec2 p = (UV - 0.5) * vec2(aspect, 1.0);
	float r = length(p);
	float a = atan(p.y, p.x);
	float id = floor(a * 38.0);
	float h = hash(id);
	float streak = step(0.72, h) * smoothstep(0.38, 0.75, r);
	float flow = fract(r * 2.2 - t * (1.8 + h * 1.6) + h * 7.0);
	streak *= smoothstep(0.0, 0.2, flow) * (1.0 - smoothstep(0.35, 0.6, flow));
	float edge = smoothstep(0.42, 0.9, r);
	COLOR = vec4(vec3(0.92, 0.95, 1.0), (streak * 0.35 + edge * 0.08) * k);
}
"""

var p                                      # player.gd
var want_toggle := false
var crouched := false                      # the small capsule is in use (crouch or slide)
var sliding := false
var crouch_k := 0.0                        # eased 0..1 (crouch or slide)
var slide_k := 0.0                         # eased 0..1
var legs_a := 0.0

var _col: CollisionShape3D
var _shape: CapsuleShape3D
var _probe: SphereShape3D
var _eye := 0.0
var _slide_t := 0.0
var _slide_cd := 0.0
var _air_t := 0.0
var _roll := 0.0
var _turn := 0.0
var _prev_yaw := Vector3.ZERO
var _hint_t := 0.0
var _t := 0.0
var _fov_kick := 0.0
var _fov_applied := false
var _jump_small := false
var _speed := 0.0
# Effects.
var _dust: GPUParticles3D
var _clods: GPUParticles3D
var _scrape: AudioStreamPlayer
var _scrape_task := -1
var _scrape_stream: AudioStream
var _scrape_vol := 0.0
var _lines_layer: CanvasLayer
var _lines: ColorRect
var _lines_mat: ShaderMaterial
var _ground_col := Color(0.45, 0.38, 0.26)
var _ground_t := 0.0
var _dug := false


func setup(player, col: CollisionShape3D) -> void:
	p = player
	_col = col
	_shape = col.shape as CapsuleShape3D
	_probe = SphereShape3D.new()
	_probe.radius = 0.3


func _ready() -> void:
	_build_fx()
	_scrape_task = WorkerThreadPool.add_task(_build_scrape, false, "slide_scrape")


func _exit_tree() -> void:
	if _scrape_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_scrape_task)
		_scrape_task = -1


func _build_scrape() -> void:
	_scrape_stream = WeaponAudio.new().make("scrape")


# =================================================================================================
# Movement hooks (called from player.gd _move_gravity, physics step)
# =================================================================================================

## Input and state changes before the movement: crouch hold / toggle, slide start / end, standing
## up for sprint / jetpack.
func pre_move(delta: float, on_floor: bool) -> void:
	_slide_cd = maxf(_slide_cd - delta, 0.0)
	_hint_t = maxf(_hint_t - delta, 0.0)
	var input_ok: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not Game.ui_panel_open() \
			and not (p.has_method("is_dead") and p.is_dead())
	var hold := input_ok and Input.is_action_pressed("crouch")
	var pressed := input_ok and (Input.is_action_just_pressed("crouch") or Input.is_action_just_pressed("crouch_toggle"))
	if input_ok and Input.is_action_just_pressed("crouch_toggle"):
		want_toggle = not want_toggle
		if not want_toggle and crouched and not sliding:
			_try_stand(true)
	if input_ok and Input.is_action_just_pressed("crouch"):
		want_toggle = false               # hold takes over from the toggle
	var up: Vector3 = p.global_transform.basis.y
	var hv: Vector3 = p.velocity - up * p.velocity.dot(up)
	var sprinting: bool = input_ok and Input.is_action_pressed("sprint")
	# Slide: crouch pressed while running fast on the ground.
	if pressed and not sliding and on_floor and _slide_cd <= 0.0 and not p.jetting \
			and (float(p.get("_sprint_k")) > 0.5 or sprinting) and hv.length() > SLIDE_MIN * PLAYER_SPRINT:
		_start_slide(hv, up)
		return
	if sliding:
		_air_t = _air_t + delta if not on_floor else 0.0
		_slide_t += delta
		var down_ok := _slide_t < SLIDE_MAX_T or (_speed > PLAYER_SPRINT and _slide_t < SLIDE_MAX_T * 1.8)
		if _speed < SLIDE_END or not down_ok or _air_t > 0.25 or p.jetting:
			_end_slide(hold or want_toggle)
		return
	var want := hold or want_toggle
	if want and not crouched:
		_set_crouched(true)
	elif not want and crouched:
		_try_stand(false)
	# Sprinting stands you up (unless Ctrl is held down, or Shift is the scope's breath hold while
	# aiming); so does the jetpack.
	if crouched and not hold and float(p.move_speed_mult) >= 0.9:
		var inp := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if sprinting and inp.y < -0.3:
			if _try_stand(true):
				want_toggle = false
	if crouched and p.jetting:
		if _try_stand(false):
			want_toggle = false


## Ground speed multiplier (crouch walk).
func speed_mult() -> float:
	return CROUCH_SPEED if crouched and not sliding else 1.0


func blocks_sprint() -> bool:
	return crouched


## The slide's horizontal velocity for this step (replaces the walk acceleration).
func slide_step(v_h: Vector3, up: Vector3, _wish: Vector3, delta: float) -> Vector3:
	var b: Basis = p.global_transform.basis
	# Gravity along the floor: downhill speeds up, uphill slows down.
	var n: Vector3 = p.get_floor_normal() if p.is_on_floor() else up
	var g: Vector3 = p.gravity_vec
	var g_t := g - n * g.dot(n)
	var g_h := g_t - up * g_t.dot(up)
	v_h += g_h * SLIDE_SLOPE * delta
	var sp := v_h.length()
	if sp < 0.01:
		_speed = 0.0
		return Vector3.ZERO
	var dir := v_h / sp
	sp = maxf(sp - (SLIDE_FRICTION + SLIDE_DRAG * sp) * delta, 0.0)
	# Steer a little toward where you look, A / D lean it sideways.
	var inp := Input.get_vector("move_left", "move_right", "move_forward", "move_back") \
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Vector2.ZERO
	var want: Vector3 = -b.z + b.x * inp.x * 0.7
	want -= up * want.dot(up)
	if want.length_squared() > 1e-4:
		want = want.normalized()
		var ang := dir.signed_angle_to(want, up)
		var step := clampf(ang, -SLIDE_STEER * delta, SLIDE_STEER * delta)
		dir = dir.rotated(up, step)
		_turn = lerpf(_turn, clampf(ang, -1.0, 1.0), 1.0 - exp(-6.0 * delta))
	_speed = sp
	return dir * sp


## Jump pressed: out of a slide keeps the momentum (capped); from a crouch stands up first (or a
## small hop under a low ceiling).
func on_jump() -> void:
	_jump_small = false
	if sliding:
		# The hop keeps the slide's speed (already capped at SLIDE_MAX; hop_cap() trims it).
		_end_slide(false)
		_slide_cd = SLIDE_COOLDOWN
		if crouched:
			_jump_small = true
		return
	if crouched:
		if not _try_stand(true):
			_jump_small = true
		else:
			want_toggle = false


func jump_mult() -> float:
	return 0.6 if _jump_small else 1.0


## Horizontal speed after a jump this step: a slide-hop keeps at most HOP_MAX.
func hop_cap(v_h: Vector3) -> Vector3:
	return v_h.limit_length(HOP_MAX) if _slide_cd > SLIDE_COOLDOWN - 0.05 else v_h


# =================================================================================================
# View hooks (player.gd _process / head bob / footsteps)
# =================================================================================================

## How far below the standing eye the camera sits (m).
func eye_drop() -> float:
	return _eye


func bob_mult() -> float:
	return lerpf(1.0, 0.45, crouch_k) * (1.0 - slide_k)


## Extra camera rotation: the slide's roll into the steer and the ground rumble.
func cam_rot() -> Vector3:
	if slide_k <= 0.001:
		return Vector3.ZERO
	var a := 0.0025 * clampf(_speed / SLIDE_MAX, 0.0, 1.0) * slide_k
	return Vector3(sin(_t * 53.0) * a, sin(_t * 47.0 + 1.0) * a * 0.6, _roll * slide_k + sin(_t * 31.0) * a * 0.5)


## Footstep volume offset (dB) and whether steps play at all.
func step_db() -> float:
	return -7.0 if crouched else 0.0


func steps_on() -> bool:
	return not sliding


## Ragdoll, death, a vehicle: back to standing at once (the ragdoll starts from the pose).
func reset() -> void:
	sliding = false
	want_toggle = false
	_slide_t = 0.0
	_jump_small = false
	if crouched:
		_set_crouched(false)
	_eye = 0.0
	crouch_k = 0.0
	slide_k = 0.0
	legs_a = 0.0
	_fov_kick = 0.0
	_publish()
	if p != null and p.astronaut != null:
		p.astronaut.set_legs_view(0.0)


# =================================================================================================
# State
# =================================================================================================

func _set_crouched(on: bool) -> void:
	crouched = on
	var h := CROUCH_H if on else STAND_H
	_shape.height = h
	_col.position = Vector3(0.0, h * 0.5, 0.0)
	if Game.sfx:
		Game.sfx.play("step", -20.0 if on else -22.0, 1.05 if on else 0.95)


## Stands up if there is room above (sphere cast along the local up). hint: say why when blocked.
func _try_stand(hint: bool) -> bool:
	if not crouched:
		return true
	if not _headroom():
		if hint and _hint_t <= 0.0 and Game.hud != null:
			Game.hud.show_message(HINT, 1.3)
			_hint_t = 2.0
		return false
	_set_crouched(false)
	return true


func _headroom() -> bool:
	var up: Vector3 = p.global_transform.basis.y
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _probe
	q.transform = Transform3D(Basis(), (p.global_position as Vector3) + up * (CROUCH_H - _probe.radius - 0.03))
	q.motion = up * (STAND_H - CROUCH_H + 0.05)
	q.collision_mask = Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE
	q.exclude = [p.get_rid()]
	var r: PackedFloat32Array = p.get_world_3d().direct_space_state.cast_motion(q)
	return r.size() < 1 or r[0] >= 0.999


func _start_slide(hv: Vector3, up: Vector3) -> void:
	sliding = true
	_slide_t = 0.0
	_air_t = 0.0
	if not crouched:
		_set_crouched(true)
	var sp := hv.length()
	# A burst over the sprint speed, capped; never slower than you came in.
	var boosted := maxf(minf(maxf(sp, PLAYER_SPRINT) * SLIDE_BOOST, SLIDE_MAX), sp)
	var v_up: Vector3 = up * p.velocity.dot(up)
	p.velocity = hv.normalized() * boosted + v_up
	_speed = boosted
	_turn = 0.0
	if p.get("hand_action") != null and p.hand_action != null and p.hand_action.has_method("cancel"):
		p.hand_action.cancel()          # no grenade cooking mid-slide
	if Game.sfx:
		Game.sfx.play("whoosh", -12.0, 1.1)
		Game.sfx.play("step", -8.0, 0.75)


func _end_slide(stay_down: bool) -> void:
	sliding = false
	_slide_cd = maxf(_slide_cd, SLIDE_COOLDOWN)
	if stay_down:
		return
	if not _try_stand(false):
		want_toggle = true                # no room: stay down until there is


# =================================================================================================
# Per frame: eased values, camera, legs, effects
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	if p == null:
		return
	var on_foot: bool = p.vehicle == null and not p.is_ragdolled()
	if not on_foot:
		if crouched or sliding or legs_a > 0.0:
			reset()
		_effects(delta, false)
		_apply_fov(delta)
		return
	var k := 1.0 - exp(-delta / EASE_T)
	var target_eye := EYE_SLIDE if sliding else (EYE_CROUCH if crouched else 0.0)
	_eye = lerpf(_eye, target_eye, k)
	crouch_k = lerpf(crouch_k, 1.0 if crouched else 0.0, k)
	slide_k = lerpf(slide_k, 1.0 if sliding else 0.0, 1.0 - exp(-delta / 0.06))
	var steer := 0.0
	if sliding:
		var inp := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		steer = clampf(-inp.x * 0.05 - _turn * 0.04, -0.07, 0.07)
	_roll = lerpf(_roll, steer, 1.0 - exp(-8.0 * delta))
	var kick_target := FOV_KICK * clampf((_speed - 2.0) / 6.5, 0.0, 1.0) if sliding else 0.0
	_fov_kick = lerpf(_fov_kick, kick_target, 1.0 - exp(-(10.0 if kick_target > _fov_kick else 4.0) * delta))
	# Own body in view: while sliding, and whenever the view tips down far enough that it could show
	# (from ~17° down; the body only enters the frame below ~65°, so the fade is never seen).
	var look_down: bool = float(p.get("_pitch")) < -0.3
	var la := 1.0 if (sliding or look_down) else 0.0
	legs_a = move_toward(legs_a, la, delta / 0.15)
	if p.astronaut != null:
		# The eye in the body's space: the body view puts its neck there (astronaut.gd).
		var eye: Vector3 = (p.astronaut.transform as Transform3D).affine_inverse() * (p.head.position as Vector3)
		p.astronaut.set_legs_view(legs_a, eye, delta, float(p.get("_pitch")))
	_publish()
	_effects(delta, sliding)
	_apply_fov(delta)


func _publish() -> void:
	if p == null:
		return
	p.set("crouching", crouched)
	p.set("crouch_k", crouch_k)
	p.set("sliding", sliding)
	p.set("slide_k", slide_k)
	p.set("fov_kick", _fov_kick)


## Guns add fov_kick to their own FOV; with any other item in hand the kick is applied here.
func _apply_fov(_delta: float) -> void:
	var cam: Camera3D = p.camera
	if cam == null:
		return
	var it = p.items[p.current_item] if p.items.size() > p.current_item else null
	var gun: bool = it != null and it.get("pose_override") != null and it.equipped
	if gun:
		_fov_applied = false
		return
	if _fov_kick > 0.02:
		cam.fov = Settings.fov + _fov_kick
		_fov_applied = true
	elif _fov_applied:
		cam.fov = Settings.fov
		_fov_applied = false


func _build_fx() -> void:
	_dust = GPUParticles3D.new()
	_dust.top_level = true
	_dust.amount = 40
	_dust.lifetime = 0.9
	_dust.local_coords = false
	_dust.emitting = false
	_dust.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.12
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 45.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.2
	pm.damping_min = 2.0
	pm.damping_max = 3.5
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.6
	pm.scale_max = 1.5
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.4))
	sc.add_point(Vector2(1, 1.6))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.12, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.5), Color(1, 1, 1, 0)])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	_dust.process_material = pm
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.roughness = 1.0
	m.albedo_texture = DigFx.soft_texture()
	var q := QuadMesh.new()
	q.size = Vector2(0.45, 0.45)
	q.material = m
	_dust.draw_pass_1 = q
	add_child(_dust)
	_clods = GPUParticles3D.new()
	_clods.top_level = true
	_clods.amount = 16
	_clods.lifetime = 0.9
	_clods.local_coords = false
	_clods.emitting = false
	_clods.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	_clods.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pc := ParticleProcessMaterial.new()
	pc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pc.emission_sphere_radius = 0.1
	pc.direction = Vector3(0, 1, 0)
	pc.spread = 35.0
	pc.initial_velocity_min = 1.5
	pc.initial_velocity_max = 3.5
	pc.angular_velocity_min = -500.0
	pc.angular_velocity_max = 500.0
	pc.scale_min = 0.6
	pc.scale_max = 1.3
	_clods.process_material = pc
	var bm := BoxMesh.new()
	bm.size = Vector3(0.04, 0.03, 0.045)
	var dm := StandardMaterial3D.new()
	dm.vertex_color_use_as_albedo = true
	dm.roughness = 0.95
	bm.material = dm
	_clods.draw_pass_1 = bm
	add_child(_clods)
	_scrape = AudioStreamPlayer.new()
	_scrape.volume_db = -80.0
	add_child(_scrape)
	_lines_layer = CanvasLayer.new()
	_lines_layer.layer = 3
	add_child(_lines_layer)
	_lines = ColorRect.new()
	_lines.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = LINES_SHADER
	_lines_mat = ShaderMaterial.new()
	_lines_mat.shader = sh
	_lines.material = _lines_mat
	_lines.visible = false
	_lines_layer.add_child(_lines)


func _effects(delta: float, on: bool) -> void:
	var sp := _speed if on else 0.0
	var f := clampf((sp - 1.5) / (SLIDE_MAX - 1.5), 0.0, 1.0)
	var on_floor: bool = p.is_on_floor() if p != null else false
	var up: Vector3 = p.global_transform.basis.y
	var vel: Vector3 = p.velocity
	var hv := vel - up * vel.dot(up)
	var dir := hv.normalized() if hv.length_squared() > 0.01 else -(p.global_transform.basis.z as Vector3)
	var dust_on := on and on_floor and f > 0.05
	if dust_on:
		_ground_t -= delta
		if _ground_t <= 0.0:
			_ground_t = 0.25
			var foot: Vector3 = (p.global_position as Vector3) + dir * 0.6
			_ground_col = Rifle.ground_color(foot, up)
			_dug = _is_dug(foot)
		var heel: Vector3 = (p.global_position as Vector3) + dir * 0.7 + up * 0.05
		var bas := Transform3D(_basis_y((up * 0.7 + dir * 0.45).normalized()), heel)
		_dust.global_transform = bas
		(_dust.process_material as ParticleProcessMaterial).color = _ground_col.lightened(0.1)
		(_dust.process_material as ParticleProcessMaterial).gravity = Game.gravity_at(heel) * 0.08
		_dust.amount_ratio = clampf(f * 1.2, 0.15, 1.0)
		_clods.global_transform = bas
		(_clods.process_material as ParticleProcessMaterial).color = _ground_col.darkened(0.25)
		(_clods.process_material as ParticleProcessMaterial).gravity = Game.gravity_at(heel)
		_clods.amount_ratio = clampf(f, 0.2, 1.0)
	if _dust.emitting != dust_on:
		_dust.emitting = dust_on
	var clods_on := dust_on and _dug
	if _clods.emitting != clods_on:
		_clods.emitting = clods_on
	# Scrape loop: louder and higher with speed; through the suit only in vacuum.
	if _scrape_task >= 0 and WorkerThreadPool.is_task_completed(_scrape_task):
		WorkerThreadPool.wait_for_task_completion(_scrape_task)
		_scrape_task = -1
		_scrape.stream = _scrape_stream
	var want_vol := f * (1.0 if on_floor else 0.3) if on else 0.0
	_scrape_vol = lerpf(_scrape_vol, want_vol, 1.0 - exp(-(14.0 if want_vol > _scrape_vol else 6.0) * delta))
	if _scrape.stream != null:
		var vac: bool = Game.sfx != null and float(Game.sfx.get("listener_air")) < 0.05
		_scrape.bus = "VacSuit" if vac else "Master"
		if _scrape_vol > 0.01:
			if not _scrape.playing:
				_scrape.play(randf() * 0.8)
			_scrape.volume_db = linear_to_db(_scrape_vol) - (10.0 if vac else 4.0)
			_scrape.pitch_scale = lerpf(0.75, 1.25, f)
		elif _scrape.playing:
			_scrape.stop()
	# Speed lines.
	var lk := slide_k * f
	_lines.visible = lk > 0.02
	if _lines.visible:
		var vs := _lines.size
		_lines_mat.set_shader_parameter("k", lk)
		_lines_mat.set_shader_parameter("t", _t)
		_lines_mat.set_shader_parameter("aspect", vs.x / maxf(vs.y, 1.0))


## The ground under `w` was dug (planet edit cells, like the bots' check).
func _is_dug(w: Vector3) -> bool:
	var body: Node3D = Game.dominant_body(w)
	if body == null:
		return false
	var ed = body.get("edits")
	if not (ed is Dictionary) or (ed as Dictionary).is_empty():
		return false
	var v := Vector3i((w - body.global_position).floor())
	return (ed as Dictionary).has(Vector3i(v.x >> 4, v.y >> 4, v.z >> 4))


static func _basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)
