extends Node3D
## Visual effects for the terrain tool: curved energy beam with helix strands, debris stream
## (sucked into the tool when digging, sprayed out when raising), dirt spray, dust puffs, sparks,
## a glowing hot spot with light and the ground-projected brush footprint (FOOT_SHADER) with a radius
## read-out. Everything lives in world space (top_level) and is driven each frame by whoever digs:
## the player's terrain tool (tip_is_vm = true: the nozzle is in the view model) or, later, the AI
## rival (tip_node = its nozzle, tip_is_vm = false; skip show_preview).

const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform vec3 p0;
uniform vec3 p1;
uniform vec3 p2;
uniform vec4 color : source_color = vec4(1.0);
uniform float radius = 0.02;
uniform float radius_end = 0.06;
uniform float wobble = 0.03;
uniform float flow = 1.0;
uniform float helix = 0.0;
uniform float phase = 0.0;
uniform float intensity = 1.0;
uniform float core_white = 0.8;

varying float v_t;

vec3 bez(float t) { float u = 1.0 - t; return u * u * p0 + 2.0 * u * t * p1 + t * t * p2; }
vec3 bez_d(float t) { return 2.0 * (1.0 - t) * (p1 - p0) + 2.0 * t * (p2 - p1); }

void vertex() {
	float t = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	vec2 rd = VERTEX.xz;
	vec3 P = bez(t);
	vec3 T = normalize(bez_d(t) + vec3(1e-5));
	vec3 rf = abs(T.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 N = normalize(cross(rf, T));
	vec3 B = cross(T, N);
	float env = sin(t * 3.14159);
	float w1 = sin(t * 17.0 - TIME * 23.0 * flow + phase) * 0.6 + sin(t * 31.0 + TIME * 37.0 + phase * 2.0) * 0.4;
	float w2 = cos(t * 13.0 - TIME * 19.0 * flow + phase * 1.3);
	vec3 off = (N * w1 + B * w2) * wobble * env;
	if (helix > 0.0) {
		float a = t * 26.0 - TIME * 16.0 * flow + phase;
		off += (N * cos(a) + B * sin(a)) * helix * (0.25 + 0.75 * env);
	}
	float r = mix(radius, radius_end, t);
	vec3 world = P + off + (N * rd.x + B * rd.y) * r;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(N * rd.x + B * rd.y, 0.0)).xyz);
	v_t = t;
}

void fragment() {
	float fres = abs(dot(NORMAL, VIEW));
	float core = pow(fres, 2.5);
	float stream = 0.75 + 0.25 * sin(v_t * 46.0 - TIME * 34.0 * flow + phase);
	float ends = smoothstep(0.0, 0.05, v_t) * (1.0 - smoothstep(0.92, 1.0, v_t));
	// Alpha-blended HDR color: reads on bright snow as well as in dark caves (bloom kicks in).
	ALBEDO = mix(color.rgb * 1.3, vec3(1.7), pow(fres, 9.0) * core_white);
	ALPHA = clamp((core * 0.95 + 0.12) * stream * ends * intensity * color.a, 0.0, 1.0);
}
"""

## Brush footprint: a deferred decal. The back faces of a box around the aim point are drawn without
## a depth test; each pixel rebuilds the scene point behind it from the depth buffer and draws the
## pattern in the brush's own frame (metres, +Y = brush up), so it lies flat on whatever ground,
## rock or cave wall is inside the box. One draw call, one depth read per pixel.
## Pattern: a crisp ring with tick marks, a centre crosshair, a faint fill, and per mode
##   0 dig      contour rings sinking towards the centre (a funnel going down)
##   1 raise    contour rings rising out of the centre to the rim
##   2 flatten  a metre grid inside the footprint + the line where the target plane cuts the ground
## Pixels closer than 0.9 m to the eye (view model arms) and outside the box are discarded.
const FOOT_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 color : source_color = vec4(1.0);
uniform float radius = 2.0;
uniform float half_h = 2.0;
uniform float mode = 0.0;
uniform float active = 0.0;
uniform float flat_h = 0.0;
uniform float fade_in = 1.0;

varying vec3 v_c;
varying vec3 v_x;
varying vec3 v_y;
varying vec3 v_z;

void vertex() {
	v_c = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_x = normalize((MODELVIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz);
	v_y = normalize((MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	v_z = normalize((MODELVIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
}

float line(float d, float w, float aa) {
	return 1.0 - smoothstep(w, w + aa, abs(d));
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 p = vp.xyz / vp.w;
	if (-p.z < 0.9) {
		discard;
	}
	vec3 d = p - v_c;
	vec3 l = vec3(dot(d, v_x), dot(d, v_y), dot(d, v_z));
	float r = length(l.xz);
	if (r > radius * 1.3 + 0.3 || abs(l.y) > half_h) {
		discard;
	}
	// Pixel footprint in metres (clamped: depth edges must not smear the lines).
	float aa = clamp(fwidth(r), 0.004, radius * 0.06);
	float t = TIME;
	float act = clamp(active, 0.0, 1.0);
	float rn = r / max(radius, 0.01);

	// Rim: crisp line + a soft outer halo.
	float rim = line(r - radius, aa * 0.75, aa * 1.2);
	float halo = exp(-max(r - radius, 0.0) / (0.12 + radius * 0.03)) * step(radius, r) * 0.35;
	// Ticks: 32 minor + 4 major, pointing inwards from the rim.
	float ang = atan(l.z, l.x);
	float n_t = 32.0;
	float seg = (fract(ang / 6.2831853 * n_t + 0.5) - 0.5) * 6.2831853 / n_t * r;
	float qseg = (fract(ang / 6.2831853 * 4.0 + 0.5) - 0.5) * 6.2831853 / 4.0 * r;
	float tick_len = radius * 0.07 + 0.05;
	float in_band = step(radius - tick_len, r) * step(r, radius);
	float tick = line(seg, aa * 0.6, aa) * in_band * 0.75;
	float big_band = step(radius - tick_len * 2.2, r) * step(r, radius + tick_len * 0.6);
	tick = max(tick, line(qseg, aa * 1.1, aa) * big_band);
	// Centre crosshair: four short arms with a gap, and a dot.
	float cs = clamp(radius * 0.12, 0.12, 0.45);
	float gap = cs * 0.35;
	float arm_x = line(l.z, aa * 0.7, aa) * step(gap, abs(l.x)) * step(abs(l.x), cs);
	float arm_z = line(l.x, aa * 0.7, aa) * step(gap, abs(l.z)) * step(abs(l.z), cs);
	float dot_c = 1.0 - smoothstep(cs * 0.08, cs * 0.08 + aa, r);
	float cr = max(max(arm_x, arm_z), dot_c);

	// Mode layer.
	float layer = 0.0;
	float speed = 0.35 + act * 0.9;
	float kw = aa * 3.0 / max(radius, 0.01);
	if (mode < 0.5) {
		// Dig: rings flow inwards and fade, like soil drawn down into a funnel.
		float k = fract(rn * 3.0 + t * speed);
		layer = line(k - 0.5, 0.025 + kw * 0.6, kw * 1.5) * (0.15 + 0.6 * rn) * step(rn, 1.0);
	} else if (mode < 1.5) {
		// Raise: rings swell outwards from the centre to the rim.
		float k = fract(rn * 3.0 - t * speed);
		layer = line(k - 0.5, 0.025 + kw * 0.6, kw * 1.5) * (0.75 - 0.6 * rn) * step(rn, 1.0);
	} else {
		// Flatten: a 0.5 m grid inside the footprint, the line where the target plane meets the
		// ground, and a faint band around it (what the tool will level).
		vec2 g = abs(fract(l.xz * 2.0 + 0.5) - 0.5) / 2.0;
		float grid = max(line(g.x, aa * 0.5, aa), line(g.y, aa * 0.5, aa)) * 0.45 * step(rn, 1.0);
		float hd = l.y - flat_h;
		float haa = clamp(fwidth(hd), 0.004, 0.25);
		float contour = line(hd, haa * 0.8, haa * 1.5) * step(rn, 1.0);
		layer = grid + contour + (1.0 - smoothstep(0.0, 0.6, abs(hd))) * 0.12 * step(rn, 1.0);
	}

	float fill = step(rn, 1.0) * (0.035 + 0.05 * smoothstep(0.55, 1.0, rn)) * (1.0 + act);
	float pulse = 0.85 + 0.15 * sin(t * (3.0 + act * 9.0));
	float a = rim * (0.9 * pulse) + halo * 0.5 + tick * 0.8 + cr * 0.7 + layer * (0.45 + 0.35 * act) + fill;
	// Fade the projection out towards the top / bottom of the box (no hard cut on steep ground).
	a *= 1.0 - smoothstep(half_h * 0.7, half_h, abs(l.y));
	a *= fade_in;
	vec3 c = color.rgb;
	ALBEDO = mix(c * 1.15, vec3(1.0), rim * 0.25 + cr * 0.2);
	ALPHA = clamp(a, 0.0, 0.92);
}
"""

const VM := preload("res://scripts/player/vm_parts.gd")
const BEAM_INT := [1.4, 0.28, 1.1, 1.1]
const SOIL := Color(0.45, 0.35, 0.24)     # default debris colour

var _beams: Array = []          # [MeshInstance3D, ShaderMaterial]
var _stream: GPUParticles3D     # debris along the beam
var _stream_pm: ParticleProcessMaterial
var _spray: GPUParticles3D      # dirt flung out of the hole
var _spray_pm: ParticleProcessMaterial
var _dust: GPUParticles3D
var _dust_pm: ParticleProcessMaterial
var _sparks: GPUParticles3D
var _sparks_pm: ParticleProcessMaterial
var _kick: GPUParticles3D       # chunks thrown back toward the player (kick_back(); the player's drill only)
var _kick_pm: ParticleProcessMaterial
var _hot_light: OmniLight3D
var _hot_glow: MeshInstance3D
var _hot_mat: StandardMaterial3D
var _foot: MeshInstance3D       # brush footprint (deferred decal box)
var _foot_mat: ShaderMaterial
var _foot_up := Vector3.ZERO    # smoothed footprint up axis
var _foot_on := 0.0             # fade in / out
var _radius_label: Label3D
var _label_r := -1.0
var _label_t := 0.0             # seconds the radius label stays bright after a change
var _t := 0.0
var _work := 0.0                # smoothed 0..1 "tool is working"
var _since_work := 1.0
var tip_node: Node3D            # beam start follows this every frame (view model nozzle)
var tip_is_vm := true           # tip_node is drawn with the view-model projection

static var _soft_tex: GradientTexture2D


static func soft_texture() -> GradientTexture2D:
	if _soft_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.35, Color(1, 1, 1, 0.55))
		_soft_tex = GradientTexture2D.new()
		_soft_tex.gradient = g
		_soft_tex.fill = GradientTexture2D.FILL_RADIAL
		_soft_tex.fill_from = Vector2(0.5, 0.5)
		_soft_tex.fill_to = Vector2(0.5, 0.0)
		_soft_tex.width = 64
		_soft_tex.height = 64
	return _soft_tex


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_build_beams()
	_build_particles()
	_build_hotspot()
	_build_preview()
	set_working(false)


func _build_beams() -> void:
	var sh := Shader.new()
	sh.code = BEAM_SHADER
	# core, outer haze, two helix strands
	var specs := [
		{"r": 0.03, "re": 0.075, "wob": 0.025, "helix": 0.0, "ph": 0.0, "int": 1.4, "white": 1.0},
		{"r": 0.09, "re": 0.28, "wob": 0.05, "helix": 0.0, "ph": 1.0, "int": 0.3, "white": 0.0},
		{"r": 0.011, "re": 0.02, "wob": 0.01, "helix": 0.085, "ph": 0.0, "int": 1.1, "white": 0.5},
		{"r": 0.011, "re": 0.02, "wob": 0.01, "helix": 0.085, "ph": PI, "int": 1.1, "white": 0.5},
	]
	for s in specs:
		var cm := CylinderMesh.new()
		cm.top_radius = 1.0
		cm.bottom_radius = 1.0
		cm.height = 1.0
		cm.radial_segments = 10
		cm.rings = 40
		cm.cap_top = false
		cm.cap_bottom = false
		var m := ShaderMaterial.new()
		m.shader = sh
		m.set_shader_parameter("radius", s["r"])
		m.set_shader_parameter("radius_end", s["re"])
		m.set_shader_parameter("wobble", s["wob"])
		m.set_shader_parameter("helix", s["helix"])
		m.set_shader_parameter("phase", s["ph"])
		m.set_shader_parameter("intensity", s["int"])
		m.set_shader_parameter("core_white", s["white"])
		var mi := MeshInstance3D.new()
		mi.mesh = cm
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.custom_aabb = AABB(Vector3.ONE * -1.0e5, Vector3.ONE * 2.0e5)
		add_child(mi)
		_beams.append([mi, m])


func _particles(amount: int, lifetime: float, draw: Mesh) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.emitting = false
	p.draw_pass_1 = draw
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 60, 60))
	add_child(p)
	return p


func _curve(points: Array) -> CurveTexture:
	var c := Curve.new()
	for pt in points:
		c.add_point(pt)
	var ct := CurveTexture.new()
	ct.curve = c
	return ct


func _build_particles() -> void:
	# Debris chunks (lit, vertex colored).
	var chunk_mat := StandardMaterial3D.new()
	chunk_mat.vertex_color_use_as_albedo = true
	chunk_mat.roughness = 0.9
	var chunk := BoxMesh.new()
	chunk.size = Vector3(0.045, 0.036, 0.04)
	chunk.material = chunk_mat
	var var_ramp := Gradient.new()
	var_ramp.set_color(0, Color(0.6, 0.6, 0.6))
	var_ramp.set_color(1, Color(1.15, 1.1, 1.05))
	var var_tex := GradientTexture1D.new()
	var_tex.gradient = var_ramp

	_stream = _particles(56, 0.5, chunk)
	_stream_pm = ParticleProcessMaterial.new()
	_stream_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_stream_pm.emission_sphere_radius = 0.35
	_stream_pm.direction = Vector3(0, 1, 0)
	_stream_pm.spread = 9.0
	_stream_pm.gravity = Vector3.ZERO
	_stream_pm.scale_min = 0.5
	_stream_pm.scale_max = 1.15
	_stream_pm.scale_curve = _curve([Vector2(0, 0.6), Vector2(0.2, 1.0), Vector2(0.8, 0.8), Vector2(1, 0.1)])
	_stream_pm.color_initial_ramp = var_tex
	_stream_pm.angle_min = -180.0
	_stream_pm.angle_max = 180.0
	_stream_pm.angular_velocity_min = -540.0
	_stream_pm.angular_velocity_max = 540.0
	_stream_pm.particle_flag_rotate_y = true
	_stream.process_material = _stream_pm

	_spray = _particles(36, 0.9, chunk)
	_spray_pm = ParticleProcessMaterial.new()
	_spray_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_spray_pm.emission_sphere_radius = 0.3
	_spray_pm.direction = Vector3(0, 1, 0)
	_spray_pm.spread = 45.0
	_spray_pm.initial_velocity_min = 1.5
	_spray_pm.initial_velocity_max = 4.0
	_spray_pm.scale_min = 0.4
	_spray_pm.scale_max = 1.1
	_spray_pm.scale_curve = _curve([Vector2(0, 1.0), Vector2(0.7, 0.9), Vector2(1, 0.0)])
	_spray_pm.color_initial_ramp = var_tex
	_spray_pm.angular_velocity_min = -720.0
	_spray_pm.angular_velocity_max = 720.0
	_spray_pm.particle_flag_rotate_y = true
	_spray.process_material = _spray_pm

	# Kick-back: bigger clods flung back toward the camera in an arc that lands short of it.
	var clod := BoxMesh.new()
	clod.size = Vector3(0.07, 0.055, 0.06)
	clod.material = chunk_mat
	_kick = _particles(16, 0.75, clod)
	_kick_pm = ParticleProcessMaterial.new()
	_kick_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_kick_pm.emission_sphere_radius = 0.25
	_kick_pm.direction = Vector3(0, 1, 0)
	_kick_pm.spread = 16.0
	_kick_pm.scale_min = 0.5
	_kick_pm.scale_max = 1.25
	_kick_pm.scale_curve = _curve([Vector2(0, 1.0), Vector2(0.8, 0.9), Vector2(1, 0.0)])
	_kick_pm.color_initial_ramp = var_tex
	_kick_pm.angular_velocity_min = -720.0
	_kick_pm.angular_velocity_max = 720.0
	_kick_pm.particle_flag_rotate_y = true
	_kick.process_material = _kick_pm

	# Dust puffs (soft billboards).
	var dust_mat := StandardMaterial3D.new()
	dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dust_mat.vertex_color_use_as_albedo = true
	dust_mat.albedo_texture = soft_texture()
	dust_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dust_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var dq := QuadMesh.new()
	dq.size = Vector2(0.9, 0.9)
	dq.material = dust_mat
	_dust = _particles(18, 1.3, dq)
	_dust_pm = ParticleProcessMaterial.new()
	_dust_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_dust_pm.emission_sphere_radius = 0.6
	_dust_pm.direction = Vector3(0, 1, 0)
	_dust_pm.spread = 60.0
	_dust_pm.initial_velocity_min = 0.3
	_dust_pm.initial_velocity_max = 1.2
	_dust_pm.damping_min = 0.5
	_dust_pm.damping_max = 1.0
	_dust_pm.gravity = Vector3.ZERO
	_dust_pm.scale_min = 0.8
	_dust_pm.scale_max = 1.8
	_dust_pm.scale_curve = _curve([Vector2(0, 0.35), Vector2(1, 1.0)])
	_dust_pm.angle_min = -180.0
	_dust_pm.angle_max = 180.0
	var dg := Gradient.new()
	dg.set_color(0, Color(1, 1, 1, 0.0))
	dg.set_color(1, Color(1, 1, 1, 0.0))
	dg.add_point(0.15, Color(1, 1, 1, 0.42))
	var dgt := GradientTexture1D.new()
	dgt.gradient = dg
	_dust_pm.color_ramp = dgt
	_dust.process_material = _dust_pm

	# Sparks (additive, mode or ore colored).
	var spark_mat := StandardMaterial3D.new()
	spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	spark_mat.vertex_color_use_as_albedo = true
	spark_mat.albedo_texture = soft_texture()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var sq := QuadMesh.new()
	sq.size = Vector2(0.045, 0.045)
	sq.material = spark_mat
	_sparks = _particles(48, 0.45, sq)
	_sparks_pm = ParticleProcessMaterial.new()
	_sparks_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_sparks_pm.emission_sphere_radius = 0.25
	_sparks_pm.direction = Vector3(0, 1, 0)
	_sparks_pm.spread = 80.0
	_sparks_pm.initial_velocity_min = 2.0
	_sparks_pm.initial_velocity_max = 6.0
	_sparks_pm.damping_min = 3.0
	_sparks_pm.damping_max = 6.0
	_sparks_pm.scale_min = 0.6
	_sparks_pm.scale_max = 1.3
	_sparks_pm.scale_curve = _curve([Vector2(0, 1.0), Vector2(1, 0.0)])
	_sparks.process_material = _sparks_pm


func _build_hotspot() -> void:
	_hot_light = OmniLight3D.new()
	_hot_light.omni_range = 3.0
	_hot_light.light_energy = 0.0
	_hot_light.shadow_enabled = false
	add_child(_hot_light)
	_hot_mat = StandardMaterial3D.new()
	_hot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hot_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hot_mat.albedo_texture = soft_texture()
	_hot_mat.no_depth_test = false
	_hot_glow = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	_hot_glow.mesh = q
	_hot_glow.material_override = _hot_mat
	_hot_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_hot_glow)


func _build_preview() -> void:
	_foot_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = FOOT_SHADER
	_foot_mat.shader = sh
	_foot_mat.render_priority = 1
	_foot = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2, 2, 2)
	_foot.mesh = bm
	_foot.material_override = _foot_mat
	_foot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_foot.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_foot.visible = false
	add_child(_foot)
	# Radius read-out beside the rim: faint, bright for a moment after the wheel changes it.
	_radius_label = Label3D.new()
	_radius_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_radius_label.fixed_size = true
	_radius_label.pixel_size = 0.0009
	_radius_label.font_size = 26
	_radius_label.outline_size = 8
	_radius_label.outline_modulate = Color(0, 0, 0, 0.55)
	_radius_label.no_depth_test = true
	_radius_label.shaded = false
	_radius_label.double_sided = true
	_radius_label.render_priority = 2
	_radius_label.visible = false
	add_child(_radius_label)


## Brush preview: the ground footprint at the aim point. mode: 0 dig, 1 raise, 2 flatten (-1 = from
## `flatten`). normal: surface normal at the aim (dig / raise lie along it; flatten along plane_up).
func show_preview(on: bool, point := Vector3.ZERO, radius := 1.0, color := Color.WHITE,
		flatten := false, plane_point := Vector3.ZERO, plane_up := Vector3.UP, normal := Vector3.ZERO, mode := -1) -> void:
	if not on:
		_foot.visible = false
		_radius_label.visible = false
		_foot_on = 0.0
		return
	var m := mode if mode >= 0 else (2 if flatten else 0)
	var want_up := plane_up.normalized()
	if m != 2 and normal != Vector3.ZERO:
		# Lean towards the surface normal, but never more than ~50 deg off gravity up (cave walls).
		want_up = plane_up.normalized().slerp(normal.normalized(), 0.65).normalized()
	if _foot_up == Vector3.ZERO or not _foot.visible:
		_foot_up = want_up
	else:
		_foot_up = _foot_up.slerp(want_up, 0.25).normalized()
	_foot.visible = true
	_foot_on = minf(_foot_on + 0.16, 1.0)
	# Crosshair arms line up with the view: -Z of the brush frame points away from the camera.
	var cam := get_viewport().get_camera_3d()
	var y := _foot_up
	var fwd := Vector3.FORWARD
	if cam != null:
		fwd = point - cam.global_position
	fwd -= y * fwd.dot(y)
	if fwd.length_squared() < 1e-6:
		fwd = _basis_y(y).z
	var z := -fwd.normalized()
	var x := y.cross(z).normalized()
	var half_h := maxf(1.2, radius * 0.8)
	var reach := radius * 1.3 + 0.3
	_foot.global_transform = Transform3D(Basis(x * reach, y * half_h, z * reach), point)
	_foot_mat.set_shader_parameter("color", color)
	_foot_mat.set_shader_parameter("radius", radius)
	_foot_mat.set_shader_parameter("half_h", half_h)
	_foot_mat.set_shader_parameter("mode", float(m))
	_foot_mat.set_shader_parameter("active", _work)
	_foot_mat.set_shader_parameter("fade_in", _foot_on)
	var fh := 0.0
	if m == 2:
		fh = -(point - plane_point).dot(plane_up.normalized())
	_foot_mat.set_shader_parameter("flat_h", fh)
	# Radius label on the near rim.
	if absf(radius - _label_r) > 0.01:
		if _label_r >= 0.0:
			_label_t = 1.4
		_label_r = radius
		_radius_label.text = ("%.1f m" % radius)
	_radius_label.visible = true
	_radius_label.global_position = point + z * (radius + 0.25) + y * 0.12
	var la := 0.42 + 0.58 * clampf(_label_t / 0.4, 0.0, 1.0)
	_radius_label.modulate = Color(color.r * 0.5 + 0.5, color.g * 0.5 + 0.5, color.b * 0.5 + 0.5, la * _foot_on)



func set_working(on: bool) -> void:
	if not on:
		_stream.emitting = false
		_spray.emitting = false
		_dust.emitting = false
		_sparks.emitting = false
		_kick.emitting = false


## Chunks thrown back toward `eye` (the camera, world) from the hit point, arcing under gravity (-up)
## to land roughly halfway: never into the view. strength 0..1 (power; SÜPER KAZI / the bore > 1
## throws more). Call it each physics frame after work(); it stops with the work.
func kick_back(hit: Vector3, eye: Vector3, up: Vector3, soil := SOIL, strength := 1.0) -> void:
	var to_eye := eye - hit
	var dist := to_eye.length()
	if dist < 1.2 or strength <= 0.01:
		_kick.emitting = false
		return
	var flat := to_eye - up * to_eye.dot(up)
	var dir := (flat.normalized() * 0.75 + up * 0.66).normalized() if flat.length_squared() > 1e-4 else up
	_kick.global_transform = Transform3D(_basis_y(dir), hit + up * 0.1)
	var v := clampf(dist * 0.95, 2.0, 6.5)
	_kick_pm.initial_velocity_min = v * 0.75
	_kick_pm.initial_velocity_max = v
	_kick_pm.gravity = -up * 9.0
	_kick_pm.color = soil.darkened(0.05)
	_kick.amount_ratio = clampf(0.35 * strength, 0.1, 1.0)
	_kick.emitting = true


## Called every physics frame while the tool is working.
## mode: 0 dig, 1 raise, 2 flatten. color: beam / mode colour. soil: debris colour (the planet's
## soil_color).
func work(tip: Vector3, tip_dir: Vector3, hit: Vector3, normal: Vector3, up: Vector3,
		mode: int, radius: float, color: Color, soil := SOIL) -> void:
	_since_work = 0.0
	var dist := tip.distance_to(hit)
	var to_tip := (tip - hit) / maxf(dist, 0.001)
	var mcol: Color = soil

	# Beam: quadratic bezier leaving the nozzle along the barrel and bending into the hit point.
	var ctrl := tip + tip_dir * dist * 0.45
	var flow := -1.0 if mode == 0 else 1.0
	for b in _beams:
		var m: ShaderMaterial = b[1]
		m.set_shader_parameter("p0", tip)
		m.set_shader_parameter("p1", ctrl)
		m.set_shader_parameter("p2", hit)
		m.set_shader_parameter("color", color)
		m.set_shader_parameter("flow", flow)
		b[0].visible = true

	# Debris stream: dig pulls chunks into the tool, raise sprays material onto the ground.
	var T := _stream.lifetime
	if mode == 0:
		_stream.global_transform = Transform3D(_basis_y(to_tip), hit + normal * 0.15)
		var v0 := 1.2
		_stream_pm.initial_velocity_min = v0
		_stream_pm.initial_velocity_max = v0
		var a := 2.0 * maxf(dist - 0.25 - v0 * T, 0.0) / (T * T)
		_stream_pm.linear_accel_min = a * 0.9
		_stream_pm.linear_accel_max = a * 1.05
		_stream_pm.emission_sphere_radius = clampf(radius * 0.35, 0.2, 1.0)
		_stream_pm.color = mcol
		_stream.emitting = true
		_stream.amount_ratio = 1.0
	elif mode == 1:
		_stream.global_transform = Transform3D(_basis_y(-to_tip), tip - to_tip * 0.05)
		var v := dist / T
		_stream_pm.initial_velocity_min = v * 0.95
		_stream_pm.initial_velocity_max = v * 1.05
		_stream_pm.linear_accel_min = 0.0
		_stream_pm.linear_accel_max = 0.0
		_stream_pm.emission_sphere_radius = 0.03
		_stream_pm.color = mcol.lightened(0.1)
		_stream.emitting = true
		_stream.amount_ratio = 0.8
	else:
		_stream.emitting = false

	# Dirt spray out of the hole / splash where material lands / scrape when flattening.
	_spray.global_transform = Transform3D(_basis_y(normal), hit)
	_spray_pm.gravity = -up * 9.0
	_spray_pm.emission_sphere_radius = clampf(radius * 0.4, 0.2, 1.4)
	_spray_pm.color = mcol
	_spray_pm.spread = 45.0 if mode != 2 else 85.0
	_spray_pm.initial_velocity_max = 4.0 if mode == 0 else 2.5
	_spray.emitting = true
	_spray.amount_ratio = 0.7 if mode == 0 else (0.5 if mode == 1 else 0.6)

	_dust.global_transform = Transform3D(_basis_y(up), hit)
	_dust_pm.emission_sphere_radius = clampf(radius * 0.5, 0.3, 2.0)
	_dust_pm.color = mcol.lightened(0.25)
	_dust.emitting = true

	_sparks.global_transform = Transform3D(_basis_y(normal), hit + normal * 0.05)
	_sparks_pm.color = Color(color.r * 2.0, color.g * 2.0, color.b * 2.0)
	_sparks.emitting = true
	_sparks.amount_ratio = 0.5

	_hot_light.global_position = hit + normal * 0.4
	_hot_light.light_color = color
	_hot_light.omni_range = radius * 1.4 + 1.5
	_hot_glow.global_position = hit + normal * 0.15
	var gs := minf(radius * 0.5, 1.1) * randf_range(0.85, 1.1)     # a hot spot, not a fireball over the view
	_hot_glow.scale = Vector3(gs, gs, gs)
	_hot_mat.albedo_color = Color(color.r * 1.3, color.g * 1.3, color.b * 1.3, 0.35)


func _process(delta: float) -> void:
	_t += delta
	_since_work += delta
	var on := _since_work < 0.08
	_work = move_toward(_work, 1.0 if on else 0.0, delta * (10.0 if on else 5.0))
	if tip_node != null and is_instance_valid(tip_node) and _work > 0.0:
		var cam := get_viewport().get_camera_3d()
		var tp: Vector3 = VM.vm_to_world(cam, tip_node.global_position) if (cam and tip_is_vm) else tip_node.global_position
		for b in _beams:
			b[1].set_shader_parameter("p0", tp)
	for i in _beams.size():
		var b: Array = _beams[i]
		b[0].visible = _work > 0.03
		b[1].set_shader_parameter("intensity", BEAM_INT[i] * (0.85 + 0.3 * randf()) * clampf(_work * 1.5, 0.0, 1.0))
	_hot_light.visible = _work > 0.03
	_hot_light.light_energy = (1.2 + sin(_t * 41.0) * 0.25 + randf() * 0.25) * _work
	_hot_glow.visible = _work > 0.03
	_label_t = maxf(_label_t - delta, 0.0)
	if not on:
		set_working(false)


static func _basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var rf := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := rf.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())
