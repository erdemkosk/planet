extends Node
## Camera motion blur (Esc › Ayarlar › "Hareket bulanıklığı": Kapalı / Düşük / Orta =
## Settings.motion_blur 0 / 1 / 2, default Düşük). Subtle on purpose: only the camera's own motion
## smears the picture (fast turns, sprinting, the skiff at speed); a still view stays sharp.
##
## How: a full-screen quad (drawn at the near plane, first in the transparent pass) reads the opaque
## screen and the depth buffer. Each pixel rebuilds its view-space point from the depth, moves it
## into last frame's camera space (cam_delta = previous camera⁻¹ · current camera, set here every
## frame) and projects it again; the difference to SCREEN_UV is that pixel's screen motion. It is
## scaled to a fixed exposure (SHUTTER × one 60 fps frame, so the look does not change with the
## frame rate), clamped to MAX_LEN screen widths and averaged over 8 taps along it (jittered start).
##   • What rides with the camera stays sharp and is never sampled (no smear, no bleed into the
##     background): anything nearer than near_dist (on foot NEAR_FOOT: the view model, which
##     vm_parts.gd squeezes into the [0.92, 1] reverse-Z depth slice, is always inside), the player's
##     own first-person body (a capsule under the eye), and in a seat the vehicle's meshes (cockpit,
##     gun shield, the chase view's hull: near_dist = their farthest corner from the camera).
##   • Transparent things (particles, flashes, glass) draw after the quad and stay sharp; the HUD
##     (CanvasLayers) is never touched.
##   • Follows the viewport's current camera. A camera switch, a teleport-sized jump, a hitch or the
##     player's (re)spawn resets the history, so no blur spike shows.
##   • Off, or too little camera motion to show this frame: the quad is hidden (no screen copy, no
##     pass at all).
## Created by main.gd (one node for the world).

const Settings := preload("res://scripts/save/settings.gd")

## Per level (index = Settings.motion_blur): the share of a 60 fps frame's screen motion that is
## smeared, and the longest smear in screen widths.
const SHUTTER := [0.0, 0.3, 0.42]
const MAX_LEN := [0.0, 0.015, 0.025]
const NEAR_FOOT := 0.6        # m, own camera on foot: the view model (arms, gun) is nearer
const NEAR_OTHER := 5.5       # m, other cameras outside a seat (the ragdoll cam orbits the body ~4 m out)
const NEAR_SEAT := 6.0        # m, a seat whose vehicle has no meshes to measure
const BODY_R := 0.6           # m, radius of the first-person body capsule (legs swing, the body shifts)
const JUMP := 8.0             # m moved in one frame (and 4× the last frame's move): a teleport
const SNAP := 1.0             # rad turned in one frame: a cut

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform mat4 cam_delta;           // this frame's camera space -> last frame's camera space
uniform float shutter = 0.3;      // share of the frame's screen motion that is smeared
uniform float max_len = 0.015;    // longest smear, in screen widths
uniform float near_dist = 0.6;    // m: nearer pixels neither blur nor get sampled
uniform vec3 body_a;              // the player's own body: a capsule in view space from body_a...
uniform vec3 body_b;              // ...to body_b...
uniform float body_r = 0.0;       // ...of this radius (0: none)

const int SAMPLES = 8;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Distance from view-space point p to the body capsule's axis.
float body_dist(vec3 p) {
	vec3 ab = body_b - body_a;
	float t = clamp(dot(p - body_a, ab) / max(dot(ab, ab), 0.000001), 0.0, 1.0);
	return length(p - (body_a + ab * t));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float depth = textureLod(depth_tex, uv, 0.0).r;
	// Reverse-Z (larger = nearer): the depth value at near_dist. The view model's slice [0.92, 1]
	// is always masked.
	vec4 mc = PROJECTION_MATRIX * vec4(0.0, 0.0, -near_dist, 1.0);
	float mask_z = min(mc.z / mc.w, 0.9);
	if (depth >= mask_z) {
		discard;
	}
	vec4 view = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec3 p = view.xyz / view.w;
	float k = smoothstep(near_dist, near_dist * 1.6, -p.z);
	if (body_r > 0.0) {
		float bd = body_dist(p);
		if (bd < body_r) {
			discard;
		}
		k *= smoothstep(body_r, body_r + 0.25, bd);
	}
	// Where this point was on screen last frame (homogeneous: the sky works too).
	vec4 prev = PROJECTION_MATRIX * (cam_delta * view);
	if (prev.w <= 0.0) {
		discard;
	}
	vec2 vel = (uv - (prev.xy / prev.w * 0.5 + 0.5)) * shutter * k;
	float len = length(vel * vec2(1.0, VIEWPORT_SIZE.y / VIEWPORT_SIZE.x));
	if (len > max_len) {
		vel *= max_len / len;
		len = max_len;
	}
	if (len * VIEWPORT_SIZE.x < 0.6) {
		discard;
	}
	float jit = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	vec3 acc = textureLod(screen_tex, uv, 0.0).rgb;
	float wsum = 1.0;
	for (int i = 0; i < SAMPLES; i++) {
		vec2 suv = uv + vel * ((float(i) + jit) / float(SAMPLES) - 0.5);
		float sd = textureLod(depth_tex, suv, 0.0).r;
		float w = 1.0 - step(mask_z, sd);
		if (body_r > 0.0) {
			vec4 sv = INV_PROJECTION_MATRIX * vec4(suv * 2.0 - 1.0, sd, 1.0);
			w *= step(body_r, body_dist(sv.xyz / sv.w));
		}
		acc += textureLod(screen_tex, suv, 0.0).rgb * w;
		wsum += w;
	}
	ALBEDO = acc / wsum;
	ALPHA = 1.0;
}
"""

var _quad: MeshInstance3D
var _mat: ShaderMaterial
var _cam_id := 0
var _prev := Transform3D()
var _last_move := 0.0
var _last_us := 0
var _was_waiting := false
var _carrier: Node3D = null       # the vehicle carrying the current camera (its meshes stay sharp)
var _carrier_box := AABB()        # their bounds in _carrier's space (empty: none found)


func _ready() -> void:
	process_priority = 1000                     # after everything that moves cameras this frame
	process_mode = Node.PROCESS_MODE_ALWAYS     # paused: the view is still, so the quad hides
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.render_priority = Material.RENDER_PRIORITY_MIN   # first transparent: particles, glass draw over it
	var q := QuadMesh.new()
	q.size = Vector2(2.0, 2.0)
	_quad = MeshInstance3D.new()
	_quad.name = "MotionBlurQuad"
	_quad.mesh = q
	_quad.material_override = _mat
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_quad.extra_cull_margin = 16384.0
	_quad.ignore_occlusion_culling = true
	_quad.visible = false
	add_child(_quad)


func _process(delta: float) -> void:
	# The frame's own (vsync-smoothed) step with the hit-stop's time scale undone: the clock the camera
	# motion was made with. (Perf pass 2026-10-07: the raw wall clock jitters a few ms frame to frame
	# under vsync while the motion does not, so the smear length pumped with it.)
	var now := Time.get_ticks_usec()
	var dt := delta / maxf(Engine.time_scale, 0.01) if _last_us > 0 else 0.0
	_last_us = now
	var level := clampi(int(Settings.motion_blur), 0, SHUTTER.size() - 1)
	var cam := get_viewport().get_camera_3d()
	if level == 0 or cam == null:
		_quad.visible = false
		_cam_id = 0
		return
	var xf := cam.get_camera_transform()
	var cam_changed := cam.get_instance_id() != _cam_id
	if cam_changed:
		_cam_id = cam.get_instance_id()
		_find_carrier(cam)
	var d := _prev.affine_inverse() * xf         # this frame's camera space -> last frame's
	var move := d.origin.length()
	var turn := d.basis.get_rotation_quaternion().get_angle()
	var spawning := _spawning()                 # (every frame: it tracks the drop's edge)
	var reset := cam_changed or spawning or dt <= 0.0 or dt > 0.25 \
			or (move > JUMP and move > _last_move * 4.0) or turn > SNAP
	_prev = xf
	_last_move = 0.0 if reset else move
	if reset:
		_quad.visible = false
		return
	var shutter := clampf(float(SHUTTER[level]) / (60.0 * dt), 0.0, 2.0)
	if cam.has_meta("motion_blur_k"):                # a camera may damp its own smear (dropship.gd walk-out)
		shutter *= clampf(float(cam.get_meta("motion_blur_k")), 0.0, 1.0)
	var pl = Game.player
	var on_foot: bool = is_instance_valid(pl) and cam == pl.get("camera")
	var near := _near_dist(cam, on_foot)
	# Rough upper bound of the smear in pixels: under half a pixel nothing would show.
	var f_px := get_viewport().get_visible_rect().size.y * 0.5 / tan(deg_to_rad(cam.fov) * 0.5)
	if (turn * 2.0 + move / near) * f_px * shutter < 0.5:
		_quad.visible = false
		return
	_quad.global_position = xf.origin
	_mat.set_shader_parameter("cam_delta", Projection(d))
	_mat.set_shader_parameter("shutter", shutter)
	_mat.set_shader_parameter("max_len", float(MAX_LEN[level]))
	_mat.set_shader_parameter("near_dist", near)
	if on_foot:
		# First-person body (legs, belly; astronaut.gd set_legs_view): from just above the feet,
		# straight under the eye, up to the neck.
		var up: Vector3 = pl.global_transform.basis.y
		var feet: Vector3 = pl.global_position
		var h := (xf.origin - feet).dot(up)
		var inv := xf.affine_inverse()
		_mat.set_shader_parameter("body_a", inv * (xf.origin - up * maxf(h - 0.35, 0.2)))
		_mat.set_shader_parameter("body_b", inv * (xf.origin - up * 0.2))
		_mat.set_shader_parameter("body_r", BODY_R)
	else:
		_mat.set_shader_parameter("body_r", 0.0)
	_quad.visible = true


## The player (re)spawning: held still until the ground is built, then dropped onto it (player.gd
## waiting_ground). True while waiting and on the frame of the drop.
func _spawning() -> bool:
	var pl = Game.player
	var w := false
	if is_instance_valid(pl):
		var wg = pl.get("waiting_ground")
		w = wg is bool and wg
	var r := w or _was_waiting
	_was_waiting = w
	return r


## On a camera switch: what carries it. On foot (the player's own camera) and on the ragdoll cam
## nothing does; in a seat it is the vehicle (the co-op passenger seat: the other player's skiff).
## Its meshes' bounds are kept in its own space (aim arcs and the like, top-level or huge, skipped).
func _find_carrier(cam: Camera3D) -> void:
	_carrier = null
	_carrier_box = AABB()
	var pl = Game.player
	if not is_instance_valid(pl) or cam == pl.get("camera"):
		return
	var v = pl.get("vehicle")
	if not is_instance_valid(v) or not (v is Node3D):
		return
	var s = v.get("skiff")
	_carrier = s if is_instance_valid(s) and s is Node3D else v
	var inv := _carrier.global_transform.affine_inverse()
	var first := true
	for n in _carrier.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or mi.top_level or not mi.is_visible_in_tree():
			continue
		var b: AABB = (inv * mi.global_transform) * mi.get_aabb()
		if b.get_longest_axis_size() > 30.0:
			continue
		_carrier_box = b if first else _carrier_box.merge(b)
		first = false


## How near a pixel may be and still blur (m).
func _near_dist(cam: Camera3D, on_foot: bool) -> float:
	if on_foot:
		return NEAR_FOOT
	if not is_instance_valid(_carrier):
		return NEAR_OTHER
	if _carrier_box.size == Vector3.ZERO:
		return NEAR_SEAT
	var p := _carrier.global_transform.affine_inverse() * cam.global_position
	var far := 0.0
	for i in 8:
		far = maxf(far, p.distance_to(_carrier_box.get_endpoint(i)))
	return clampf(far, 1.5, 16.0)
