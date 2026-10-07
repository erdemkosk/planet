extends RefCounted
## The local player while downed (scripts/war/downed.gd): first person on the ground. Static; player.gd
## hands its frame to process() / physics() while active() (see PATCHES: its _process / _physics_process
## return right after), downed.gd calls begin / begin_rise / rise_step / end_for_death.
##   The body: the downed pose (scripts/war/downed_pose.gd) on the shadow-only astronaut, an army crawl
##     at DN_CRAWL_SPEED with WASD (backwards slower), pulled along by a dragger's strap; the movement
##     capsule lies along the body (hits land on the lying body).
##   The view: the eye at the helmet's visor ~0.5 m above the ground, the pitch kept between
##     PITCH_MIN and PITCH_MAX (above the stance's own-body view), a slow heavy sway with the breath,
##     a jolt per hit; the guns and the arms are put away.
##   The screen (a CanvasLayer under the HUD): desaturates and closes in from the edges (blur, a dark
##     but never black vignette, a faint red) as the bleed-out runs down, a heartbeat pulse in it.
##   The sound: the world muffled (feel_fx.gd muffle_hit, held), the helmet's panic breathing comes
##     by itself (helmet_fx.gd: hp 0 = low-health stress).
##   Space held DN_GIVEUP_HOLD s: give up (Downed.gave_up).
##   Knocked over at the lethal hit (player.gd's ragdoll running): the ragdoll lies on until it
##     settles, then from_ragdoll() takes the body from where it lies (player.gd _end_ragdoll hook).
##   Revived: begin_rise -> rise_step (from the downed pose onto one knee and up, the eye rising,
##     DN_GETUP_TIME s), then the guns come back; Downed.speed_cap staggers the walk a moment.
##   Confirmed dead: end_for_death puts the camera / capsule back, player.gd _die does the rest.

const Downed := preload("res://scripts/war/downed.gd")
const Pose := preload("res://scripts/war/downed_pose.gd")
const Balance := preload("res://scripts/war/balance.gd")

const CAP_R := 0.3
const PITCH_MIN := -0.27               # (the stance shows the own-body view below -0.3)
const PITCH_MAX := 0.6
const EYE_OFF := Vector3(0.0, 0.2, -0.1)   # head-bone space: the visor
const VIEW_IN := 0.55                  # s the eye takes to drop to the ground
const LAYER := 1                       # over the 3D view, under the visor crack (2) and the HUD (5)
const FEEL_PATH := "res://scripts/ui/feel_fx.gd"

const SCREEN_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float desat = 0.0;
uniform float close = 0.0;       // 0 open .. 1 closed in to a small window
uniform float blur = 0.0;
uniform float red = 0.0;
uniform float flash = 0.0;
void fragment() {
	vec2 q = SCREEN_UV - 0.5;
	q.x *= SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float r = length(q);
	float inner = mix(0.62, 0.16, close);
	float outer = inner + mix(0.35, 0.28, close);
	float v = 1.0 - smoothstep(inner, outer, r);          // 1 centre .. 0 edge
	float lod = blur * (1.0 - v) * 3.5;
	vec3 c = textureLod(screen_tex, SCREEN_UV, lod).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(l), desat * mix(0.7, 1.0, 1.0 - v));
	c *= mix(0.22, 1.0, v);                              // dark edges, never black
	c = mix(c, c * vec3(1.0, 0.5, 0.45) + vec3(0.06, 0.0, 0.0), red * (1.0 - v));
	c += vec3(0.12, 0.02, 0.01) * flash * (1.0 - v * 0.6);
	COLOR = vec4(c, 1.0);
}
"""

static var _v := {}                    # the view's own state (one local player)
static var _layer: CanvasLayer = null
static var _rect: ColorRect = null
static var _mat: ShaderMaterial = null
static var _fx := 0.0                  # screen effect strength 0..1
static var _eye_h := -1.0


## Downed or getting up: player.gd hands its frame over.
static func active(p) -> bool:
	return Downed.is_downed(p) or Downed.is_rising(p)


## Space held (0..1) for the HUD.
static func giveup_frac(p) -> float:
	return Downed.giveup_frac(p)


# =================================================================================================
# Down
# =================================================================================================

static func begin(p, st) -> void:
	_v = {"cam_from": p.head.position, "view_k": 0.0}
	_screen(true)
	if p.get("_ragdoll") != null:
		_v["pending_rag"] = true            # knocked over: player.gd's ragdoll lies on, then from_ragdoll
		return
	_setup_body(p, st)


static func _setup_body(p, st) -> void:
	var ha = p.get("hand_action")
	if ha != null and is_instance_valid(ha):
		ha.cancel()
	var stn = p.get("stance")
	if stn != null and is_instance_valid(stn):
		stn.reset()
	p.interact_target = null
	if Game.hud != null and Game.hud.has_method("set_prompt"):
		Game.hud.set_prompt("")
	for it in p.items:
		it.set_active(false)
	p.viewmodel.visible = false
	p.jetting = false
	p.velocity = Vector3.ZERO
	var col: CollisionShape3D = p.get("_col")
	if col != null and not _v.has("cap_shape"):
		_v["cap_shape"] = col.shape
		_v["cap_xf"] = col.transform
		var cap := CapsuleShape3D.new()
		cap.radius = CAP_R
		cap.height = Downed.LYING_CAP_H
		col.shape = cap
		col.transform = Downed.LYING_CAP_XF
		col.disabled = false
	var a = p.astronaut
	a.set_first_person(true)
	a.set_held("")
	a.set_legs_view(0.0)
	p.set("_held_icon", "")
	a.transform = Transform3D.IDENTITY
	if st != null:
		st.from = Pose.capture(a)
		st.fold = 0.0
		st.last_pos = (p as Node3D).global_position
	_v.erase("pending_rag")


## player.gd _end_ragdoll while downed: the knockdown ragdoll settled at pos (pelvis), the chest
## toward fwd. The body lies on from there (blended into the downed pose).
static func from_ragdoll(p, pos: Vector3, fwd: Vector3) -> void:
	var st = Downed.state_of(p)
	if st == null:
		return
	var a = p.astronaut
	var locals := Pose.capture(a)
	var hips_g: Transform3D = a.hips.global_transform
	var up: Vector3 = Downed._up_at(pos)
	var feet: Vector3 = Downed._ground(pos, up, p)
	var hd: Vector3 = (a.head.global_position as Vector3) - (a.hips.global_position as Vector3)
	hd -= up * hd.dot(up)
	if hd.length_squared() < 1e-3:
		hd = fwd - up * fwd.dot(up)
	if hd.length_squared() < 1e-4:
		hd = up.cross(Vector3.RIGHT)
	var z := -hd.normalized()
	var x := up.cross(z).normalized()
	var b := Basis(x, up, x.cross(up)).orthonormalized()
	p.global_transform = Transform3D(b, feet - b * Vector3(0.0, 0.0, Pose.HIPS_AT.z))
	a.transform = Transform3D.IDENTITY
	locals[a.hips] = a.global_transform.affine_inverse() * hips_g
	var rag = p.get("_ragdoll")
	if rag != null and is_instance_valid(rag):
		rag.queue_free()
	p.set("_ragdoll", null)
	p.set("_getup_t", -1.0)
	p.camera.current = true
	p.set("_pitch", 0.0)
	p.head.rotation.x = 0.0
	p.camera.rotation = Vector3.ZERO
	_v["cam_from"] = p.to_local(a.head.global_position)
	_v["view_k"] = 0.0
	_setup_body(p, st)
	st.from = locals
	st.fold = 0.0


## Every frame while active (player.gd _process returns after it).
static func process(p, delta: float) -> void:
	_screen_step(p, delta)
	var st = Downed.state_of(p)
	if st == null or _v.get("pending_rag", false):
		return                                   # (rising: downed.gd's ticker runs rise_step)
	var up: Vector3 = (p as Node3D).global_transform.basis.y
	var vel: Vector3 = p.velocity
	var hs := (vel - up * vel.dot(up)).length()
	Downed.pose_step(p, delta, hs)
	var a = p.astronaut
	a.set_lamp(bool(p.get("_lamp_on")), 1.0 if bool(p.get("_lamp_on")) else 0.0)
	# The eye at the visor of the lying body.
	var vk := minf(float(_v.get("view_k", 0.0)) + delta / VIEW_IN, 1.0)
	_v["view_k"] = vk
	var eye_w: Vector3 = (a.head.global_transform as Transform3D) * EYE_OFF
	var eye_l: Vector3 = (p as Node3D).to_local(eye_w)
	var from: Vector3 = _v.get("cam_from", eye_l)
	p.head.position = from.lerp(eye_l, Pose.smooth(vk))
	var pitch := clampf(float(p.get("_pitch")), PITCH_MIN, PITCH_MAX)
	p.set("_pitch", pitch)
	p.head.rotation.x = pitch
	# Heavy, slow sway with the breath; the crawl rocks it; a hit jolts it.
	var t: float = st.pose_t
	var weak := 1.0 - Downed.bleed_frac(p)
	var cr: float = st.move * sin(st.ph * TAU * 2.0)
	p.camera.rotation = Vector3(sin(t * 2.4) * (0.006 + 0.01 * weak) + st.hit_k * 0.05 + absf(cr) * 0.01,
			sin(t * 0.7) * 0.012 * weak, sin(t * 0.9) * (0.015 + 0.02 * weak) + cr * 0.035)
	# Give up: Space held.
	var hold := Input.is_action_pressed("jump") and not Game.ui_panel_open() \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if hold:
		st.giveup_t += delta
		if st.giveup_t >= Balance.DN_GIVEUP_HOLD:
			st.giveup_t = 0.0
			Downed.gave_up(p)
			return
	else:
		st.giveup_t = maxf(st.giveup_t - delta * 3.0, 0.0)
	# The world muffled (feel_fx.gd's hit muffle, held while down).
	if Game.has_meta("feel_fx"):
		var ff = Game.get_meta("feel_fx")
		if is_instance_valid(ff) and ff.has_method("muffle_hit"):
			ff.muffle_hit(0.35 + 0.35 * weak)


## Every physics frame while active (player.gd _physics_process returns after it): the crawl, the
## drag, gravity; still while getting up.
static func physics(p, delta: float) -> void:
	var body := p as CharacterBody3D
	if _v.get("pending_rag", false) or p.get("_ragdoll") != null:
		return
	var g: Vector3 = Game.gravity_at(body.global_position + body.global_transform.basis.y * 0.3)
	var gl := g.length()
	if gl < 0.05:
		body.velocity *= 0.99
		body.move_and_slide()
		return
	var up := -g / gl
	if p.has_method("_align_up"):
		p._align_up(up, delta * 8.0)
	body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	body.up_direction = up
	var b := body.global_transform.basis
	var v_up := up * body.velocity.dot(up)
	var v_h := body.velocity - v_up
	var target := Vector3.ZERO
	if Downed.is_downed(p):
		var to := Downed.drag_point(p)
		if to != Vector3.INF:
			var mv := to - body.global_position
			mv -= up * mv.dot(up)
			var d := mv.length()
			if d > 0.05:
				target = mv / d * minf(d * 5.0, Balance.DN_DRAG_SPEED * 1.6)
			var dr = Downed.dragger_of(p)
			if dr != null:
				var hd: Vector3 = (dr as Node3D).global_position - body.global_position
				hd -= up * hd.dot(up)
				if hd.length_squared() > 0.01:
					var fwd := -b.z
					var ang := fwd.signed_angle_to(hd.normalized(), up)
					body.rotate(up, clampf(ang, -3.0 * delta, 3.0 * delta))
		elif not Game.ui_panel_open():
			var inp := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
			var wish := b.x * inp.x + b.z * inp.y
			wish -= up * wish.dot(up)
			if wish.length_squared() > 1.0:
				wish = wish.normalized()
			target = wish * Balance.DN_CRAWL_SPEED * (0.6 if inp.y > 0.3 else 1.0)
	v_h = v_h.move_toward(target, 8.0 * delta)
	v_up += g * delta
	body.velocity = v_h + v_up
	body.move_and_slide()
	p.set("_last_vel", body.velocity)


## Confirmed dead (downed.gd, right before player.gd _die): the camera and the capsule back; the
## body stays in the downed pose (the death's ragdoll starts from it).
static func end_for_death(p) -> void:
	_restore_capsule(p)
	p.head.position = Vector3(0.0, _eye(p), 0.0)
	p.camera.rotation = Vector3.ZERO
	_v.clear()
	_screen(false)


# =================================================================================================
# Get-up
# =================================================================================================

static func begin_rise(p) -> void:
	_v["rise_cam"] = p.head.position
	_v.erase("pending_rag")
	var rag = p.get("_ragdoll")
	if rag != null and is_instance_valid(rag):
		rag.queue_free()                         # (revived before the knockdown ragdoll settled)
		p.set("_ragdoll", null)
		p.camera.current = true
		_setup_body(p, null)


## One frame of the get-up at t s (downed.gd's ticker): true when done (control is back).
static func rise_step(p, t: float, from: Dictionary) -> bool:
	var a = p.astronaut
	Downed.rise_pose(a, t, from)
	var T := maxf(Balance.DN_GETUP_TIME, 0.1)
	var k := Pose.smooth(t / T)
	var c0: Vector3 = _v.get("rise_cam", p.head.position)
	p.head.position = c0.lerp(Vector3(0.0, _eye(p), 0.0), k)
	p.camera.rotation = Vector3(sin(t * 7.0) * 0.012 * (1.0 - k), 0.0, 0.04 * (1.0 - k))
	if t < T:
		return false
	_finish(p)
	return true


static func _finish(p) -> void:
	_restore_capsule(p)
	var a = p.astronaut
	a.transform = Transform3D.IDENTITY
	a.reset_pose()
	a.set_first_person(true)
	p.viewmodel.visible = true
	for it in p.items:
		it.set_active(true)
		it.set_equipped(false)
	var ci := int(p.get("current_item"))
	p.set("_pending_equip", ci)
	if ci >= 0 and ci < p.items.size():
		p.viewmodel.swap_to(p.items[ci], Callable())
	p.camera.rotation = Vector3.ZERO
	p.camera.current = true
	p.head.position = Vector3(0.0, _eye(p), 0.0)
	p.set("_rag_cooldown", 1.0)
	p.set("_last_vel", Vector3.ZERO)
	p.set("_since_hit", 0.0)
	p.velocity = Vector3.ZERO
	_v.clear()
	_screen(false)
	if Game.sfx != null and Game.sfx.has_method("play"):
		Game.sfx.play("servo", -12.0, 0.85)


static func _restore_capsule(p) -> void:
	var col: CollisionShape3D = p.get("_col")
	if col != null and _v.has("cap_shape"):
		col.shape = _v["cap_shape"]
		col.transform = _v["cap_xf"]
	_v.erase("cap_shape")
	_v.erase("cap_xf")


static func _eye(p) -> float:
	if _eye_h < 0.0:
		_eye_h = 1.72
		var s = (p as Object).get_script()
		if s != null:
			_eye_h = float((s as Script).get_script_constant_map().get("EYE_H", 1.72))
	return _eye_h


# =================================================================================================
# Screen
# =================================================================================================

static func _screen(on: bool) -> void:
	if on and (_layer == null or not is_instance_valid(_layer)):
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null or tree.root == null:
			return
		_layer = CanvasLayer.new()
		_layer.name = "DownedScreen"
		_layer.layer = LAYER
		_layer.add_to_group("gameplay_overlay")
		_rect = ColorRect.new()
		_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sh := Shader.new()
		sh.code = SCREEN_SHADER
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_rect.material = _mat
		_layer.add_child(_rect)
		tree.root.add_child.call_deferred(_layer)
	if _rect != null and is_instance_valid(_rect):
		_rect.visible = on or _fx > 0.01


## The bleed-out on screen: fades in as it goes down, out on the get-up.
static func _screen_step(p, delta: float) -> void:
	if _mat == null or _rect == null or not is_instance_valid(_rect):
		return
	var st = Downed.state_of(p)
	var want := 1.0 if st != null else 0.0
	_fx = move_toward(_fx, want, delta * (1.5 if want > _fx else 1.2))
	_rect.visible = _fx > 0.01
	if not _rect.visible:
		return
	var left := Downed.bleed_frac(p) if st != null else 1.0
	var weak := 1.0 - left
	var t := float(Time.get_ticks_msec()) / 1000.0
	var beat := pow(maxf(sin(t * TAU * lerpf(1.1, 1.9, weak)), 0.0), 8.0)
	_mat.set_shader_parameter("desat", _fx * lerpf(0.45, 0.95, weak))
	_mat.set_shader_parameter("close", _fx * clampf(lerpf(0.15, 0.85, weak) + beat * 0.06, 0.0, 1.0))
	_mat.set_shader_parameter("blur", _fx * lerpf(0.3, 1.0, weak))
	_mat.set_shader_parameter("red", _fx * (0.35 + 0.25 * beat))
	_mat.set_shader_parameter("flash", _fx * (float(st.hit_k) if st != null else 0.0))
