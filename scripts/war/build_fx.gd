extends Node3D
## Build effects shared by the build tool, the structures, the AI and the network copies. Everything
## is static; the first call puts one pooled runner (an instance of this script, "BuildFx") into
## the current scene, which animates the effects and recycles their nodes (no per-build node churn).
##   BuildFx.assemble(parent, xf, half_extents, color := AUTO, node: Node3D = null)
##       The placement PRINT (~2 s): a bright build volume rises out of the ground, a fabrication
##       front sweeps up through it (a glowing build plate, rising sparks, a travelling light, a hum
##       and welding ticks); the real structure's parts show as glowing nanite matter above the
##       front and as hot, cooling fresh layers just under it (a material_overlay on every
##       MeshInstance3D of `node`, removed afterwards), plus a dust burst and a shockwave ring that
##       hugs the ground. Driven by `node`'s mesh bounds (works for any structure, future ones too);
##       without a node by `half_extents` at `xf`. color AUTO: by the node's team (home cyan, rival
##       red). Structures call it FIRST in begin_assembly(), before their parts are moved / hidden:
##           BuildFx.assemble(get_parent(), global_transform, half, BuildFx.AUTO, self)
##   BuildFx.disassemble(parent, xf, half_extents, color := AUTO, node: Node3D = null)
##       The REVERSE print (~1.2 s; scripts/war/base_kit.gd deconstruct: undo / sell): the structure
##       shimmers, then dissolves top-down into glowing nanite matter behind a ragged sinking front
##       (its plain materials swapped for DISSOLVE_SHADER stand-ins; other surfaces glow and wink out
##       as the front passes them), the build volume collapses with the front, nanite motes drift up,
##       a soft ring draws in on the ground, a falling hum and a hiss. No shake, no blast. Frees
##       `node` at the end (it should already be inert: out of its groups, colliders off, processing
##       off, as BaseKit.deconstruct leaves it).
##   BuildFx.dust(parent, pos, up, radius, col)      one-shot dust burst (pooled emitters)
##   BuildFx.shockwave(parent, pos, up, radius, col) ground-hugging ring that expands and fades
##   BuildFx.local_bounds(node, fallback) -> AABB    a structure's mesh bounds in its own frame
##   BuildFx.zone_node(parent) -> MeshInstance3D     a ground projector (ZONE_SHADER: keep-out disc,
##       impact ring, headroom soil hatch, shockwave), see zone_place()
## Build-mode helpers, forwarded to the held build tool's hologram (scripts/war/build_holo.gd). Call
## them every frame while they apply (they clear themselves ~0.15 s after the last call; no-ops
## while the build tool is not held):
##   BuildFx.snap_guides(pairs)          pairs: [[from: Vector3, to: Vector3], ...] world points:
##                                       animated connector lines from the ghost's snap point to
##                                       the target, pulse dots at both ends (locked when they meet)
##   BuildFx.snap_points(points)         PackedVector3Array of free connectors nearby (small dots)
##   BuildFx.headroom_box(xf, aabb, ok)  underground: the clear volume (aabb in xf's frame) as an
##                                       outlined box with its height read-out; soil inside it is
##                                       hatched amber / red ("soil-cut hints"); ok = cyan
##   BuildFx.mark_blockers(nodes)        extra Node3D structures to tint red (their footprint glows)

const DigFx := preload("res://scripts/items/dig_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const SCRIPT_PATH := "res://scripts/war/build_fx.gd"

const CYAN := Color(0.45, 0.9, 1.0)
const RIVAL := Color(1.0, 0.42, 0.28)
const AUTO := Color(0, 0, 0, 0)
const HOT_HOME := Color(1.0, 0.72, 0.42)        # freshly printed layers (the suit's orange, warm)
const HOT_RIVAL := Color(1.0, 0.5, 0.3)
const RISE := 0.28                              # s: the build volume rises out of the ground
const FADE := 0.5                               # s: the volume and the overlay fade at the end
const MAX_RIGS := 8
const MAX_DUST := 16
const UN_CHARGE := 0.15                         # s: disassemble: the shimmer comes up
const UN_DUR := 0.85                            # s: the front sinks from the top to the base
const UN_FADE := 0.22                           # s: the volume fades, then the node is freed

## Build volume: a box with bright edges, a faint nanite fog above the print front, the front itself
## as a bright line around the faces. Unit box (BoxMesh 1 m), scaled by the node transform.
const VOLUME_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 col : source_color = vec4(0.45, 0.9, 1.0, 1.0);
uniform vec3 size = vec3(4.0, 3.0, 4.0);
uniform float front = 0.0;
uniform float k = 1.0;
varying vec3 lp;

void vertex() {
	lp = VERTEX;
}

void fragment() {
	vec3 m = (0.5 - abs(lp)) * size;
	float mn = min(m.x, min(m.y, m.z));
	float mx = max(m.x, max(m.y, m.z));
	float mid = m.x + m.y + m.z - mn - mx;
	float edge = 1.0 - smoothstep(0.015, 0.07, mid);
	float h = (lp.y + 0.5) * size.y;
	float d = h - front * size.y;
	float fl = exp(-abs(d) * 16.0);
	float above = smoothstep(-0.05, 0.05, d);
	float scan = 0.5 + 0.5 * sin(h * 18.0 - TIME * 9.0);
	float a = edge * (0.3 + 0.3 * above) + fl * 0.5 + above * (0.03 + 0.03 * scan);
	ALBEDO = mix(col.rgb, vec3(1.0, 0.97, 0.92), fl * 0.45);
	ALPHA = clamp(a * k, 0.0, 1.0);
}
"""

## The build plate at the print front: a glowing slice with a 25 cm grid, a bright rim and nanite glints.
const SLICE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 col : source_color = vec4(0.45, 0.9, 1.0, 1.0);
uniform vec2 size = vec2(4.0, 4.0);
uniform float k = 1.0;
varying vec2 lp;

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	lp = VERTEX.xz;
}

void fragment() {
	vec2 m = (0.5 - abs(lp)) * size;
	float rim = 1.0 - smoothstep(0.0, 0.12, min(m.x, m.y));
	vec2 gc = lp * size * 4.0;
	vec2 g = 0.5 - abs(fract(gc) - 0.5);
	float grid = 1.0 - smoothstep(0.0, 0.08, min(g.x, g.y));
	float glint = step(0.93, hash2(floor(gc) + floor(TIME * 14.0)));
	float a = 0.04 + rim * 0.4 + grid * 0.1 + glint * 0.3;
	ALBEDO = mix(col.rgb, vec3(1.0, 0.96, 0.9), glint * 0.6 + rim * 0.25);
	ALPHA = clamp(a * k, 0.0, 1.0);
}
"""

## The print on the real structure (material_overlay): above the front the parts are glowing nanite
## matter (fresnel, glints), at the front a crisp bright line, just under it the fresh layers glow
## warm and cool down into the real material.
const OVERLAY_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 col : source_color = vec4(0.45, 0.9, 1.0, 1.0);
uniform vec4 hot : source_color = vec4(1.0, 0.72, 0.42, 1.0);
uniform vec3 origin = vec3(0.0);
uniform vec3 up = vec3(0.0, 1.0, 0.0);
uniform float front = -10.0;
uniform float k = 1.0;
varying vec3 wpos;

float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float h = dot(wpos - origin, up);
	float d = h - front;
	float ndv = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 2.0);
	float glint = step(0.93, hash3(floor(wpos * 9.0) + floor(TIME * 12.0)));
	float layers = 0.5 + 0.5 * cos(h * 62.83);
	float fl = exp(-abs(d) * 28.0);
	vec3 rgb = hot.rgb * (0.72 + 0.3 * layers);
	float a = exp(min(d, 0.0) * 3.5) * (0.5 + 0.25 * layers);
	if (d > 0.0) {
		rgb = col.rgb * (0.5 + 0.5 * fres) + vec3(0.55, 0.85, 1.0) * glint * 0.45;
		a = 0.7 + 0.2 * fres;
	}
	rgb = mix(rgb, vec3(1.0, 0.96, 0.9), fl * 0.7);
	a = max(a, fl * 0.9);
	ALBEDO = rgb;
	ALPHA = clamp(a * k, 0.0, 1.0);
}
"""

## The reverse print (disassemble): a lit stand-in for a structure's plain materials (albedo /
## texture / vertex colour, metallic, roughness, emission; `unshaded_k` 1 = an unshaded original)
## that is GONE above a ragged, drifting front (value noise) which sinks from the top to the base; a
## glowing nanite rim at the front, glints just under it, a faint scan shimmer over the rest (`glow`).
## Discarded pixels drop out of the shadow too.
const DISSOLVE_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float use_tex = 0.0;
uniform float use_vcol = 0.0;
uniform vec3 uv_scale = vec3(1.0);
uniform vec3 uv_offset = vec3(0.0);
uniform float metallic = 0.0;
uniform float roughness = 0.8;
uniform vec3 emission : source_color = vec3(0.0);
uniform float unshaded_k = 0.0;
uniform vec4 col : source_color = vec4(0.45, 0.9, 1.0, 1.0);
uniform vec3 origin = vec3(0.0);
uniform vec3 up = vec3(0.0, 1.0, 0.0);
uniform float front = 100.0;
uniform float glow = 0.0;
uniform float k = 1.0;
varying vec3 lpos;

float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash3(i);
	float n100 = hash3(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash3(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash3(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash3(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash3(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash3(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash3(i + vec3(1.0, 1.0, 1.0));
	float lo = mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y);
	float hi = mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y);
	return mix(lo, hi, f.z);
}

void vertex() {
	lpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - origin;
	UV = UV * uv_scale.xy + uv_offset.xy;
}

void fragment() {
	float h = dot(lpos, up);
	float n = vnoise(lpos * 2.6 + vec3(0.0, TIME * 0.7, 0.0));
	float d = front + (n - 0.5) * 0.55 - h;
	if (d < 0.0) {
		discard;
	}
	vec3 base = albedo.rgb;
	if (use_tex > 0.5) {
		base *= texture(albedo_tex, UV).rgb;
	}
	if (use_vcol > 0.5) {
		base *= COLOR.rgb;
	}
	float edge = exp(-d * 10.0);
	float near = exp(-d * 2.5);
	float glint = step(0.9, hash3(floor(lpos * 11.0) + floor(mod(TIME * 14.0, 97.0)))) * near;
	float sh = glow * (0.25 + 0.2 * sin(h * 30.0 - TIME * 8.0));
	vec3 nano = col.rgb * (edge * 0.85 + glint * 0.5 + sh * 0.35) * k;
	ALBEDO = mix(base, col.rgb * 0.22, clamp(edge * 0.75 + sh * 0.3, 0.0, 1.0)) * (1.0 - unshaded_k);
	METALLIC = metallic;
	ROUGHNESS = roughness;
	EMISSION = emission + base * unshaded_k + nano;
}
"""

## Ground projector (the technique of scripts/items/dig_fx.gd FOOT_SHADER): the back faces of a box
## (BoxMesh 2 m, scaled to `ext` half extents) drawn without a depth test; each pixel rebuilds the
## scene point behind it from the depth buffer and draws in the box frame (m, +Y up), so the mark
## lies on whatever ground, rock or wall is inside. Pixels closer than 0.9 m (the view model) skip.
##   mode 0 keep-out disc (pulsing rim + hatch: a structure in the way), 1 impact ring (a gun's
##   default shot lands here: rim, centre cross, outward pulses), 2 headroom volume (soil inside
##   the box, not the floor slab, hatched), 3 shockwave (ring expanding with phase 0..1), 4 a soft
##   ring drawing IN and fading (a structure taken down).
const ZONE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 col : source_color = vec4(1.0, 0.3, 0.24, 1.0);
uniform vec3 ext = vec3(3.0, 2.0, 3.0);
uniform float mode = 0.0;
uniform float radius = 3.0;
uniform float k = 1.0;
uniform float phase = 0.0;

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

float band(float d, float w, float aa) {
	return 1.0 - smoothstep(w, w + aa, abs(d));
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 p = vp.xyz / vp.w;
	if (-p.z < 0.9) {
		discard;
	}
	vec3 dd = p - v_c;
	vec3 l = vec3(dot(dd, v_x), dot(dd, v_y), dot(dd, v_z));
	if (abs(l.x) > ext.x || abs(l.y) > ext.y || abs(l.z) > ext.z) {
		discard;
	}
	float r = length(l.xz);
	float aa = clamp(fwidth(r), 0.004, 0.6);
	float t = TIME;
	float a = 0.0;
	float vf = 1.0 - smoothstep(ext.y * 0.75, ext.y, abs(l.y));
	if (mode < 0.5) {
		float pulse = 0.65 + 0.35 * sin(t * 7.0);
		float rim = band(r - radius, aa * 0.8, aa * 1.5);
		float hs = (l.x + l.z) * 1.4;
		float hz = abs(fract(hs) - 0.5);
		float hatch = (1.0 - smoothstep(0.14, 0.14 + clamp(fwidth(hs), 0.01, 0.3) * 1.5, hz)) * step(r, radius);
		a = rim * (0.55 + 0.45 * pulse) + hatch * 0.2 * pulse + step(r, radius) * 0.06;
	} else if (mode < 1.5) {
		float rim = band(r - radius, aa, aa * 2.0);
		float ph = fract(t * 0.6);
		float wave = band(r - ph * radius * 1.5, aa * 1.5 + 0.08, aa * 3.0) * (1.0 - ph);
		float inner = band(r - radius * 0.55, aa * 0.6, aa * 1.5) * 0.45;
		float cs = radius * 0.18;
		float cr = band(l.x, aa * 0.8, aa) * step(abs(l.z), cs) + band(l.z, aa * 0.8, aa) * step(abs(l.x), cs);
		a = rim * 0.85 + wave * 0.6 + inner + min(cr, 1.0) * 0.6 + step(r, radius) * 0.05;
	} else if (mode < 2.5) {
		float floor_cut = step(-ext.y + 0.35, l.y);
		vec3 m = ext - abs(l);
		float face = 1.0 - smoothstep(0.0, 0.35, min(m.x, min(m.y, m.z)));
		float hs = (l.x + l.y + l.z) * 1.6;
		float hz = abs(fract(hs) - 0.5);
		float hatch = 1.0 - smoothstep(0.16, 0.16 + clamp(fwidth(hs), 0.01, 0.3) * 1.5, hz);
		float pulse = 0.75 + 0.25 * sin(t * 6.0);
		a = floor_cut * (hatch * 0.35 * pulse + face * 0.35 + 0.08);
		vf = 1.0;
	} else if (mode < 3.5) {
		float e = 1.0 - pow(1.0 - phase, 3.0);
		float rr = radius * (0.12 + 0.88 * e);
		float w = 0.2 + 0.7 * phase;
		float x = (r - rr) / w;
		float ring = exp(-x * x);
		float inner = (1.0 - smoothstep(0.0, max(rr, 0.01), r)) * 0.18;
		a = (ring * 0.75 + inner) * (1.0 - phase);
	} else {
		float rr = radius * (1.0 - 0.88 * phase * phase);
		float x = (r - rr) / 0.22;
		float ring = exp(-x * x);
		a = ring * 0.36 * sin(phase * 3.14159);
	}
	ALBEDO = col.rgb;
	ALPHA = clamp(a * k * vf, 0.0, 0.9);
}
"""

static var holo: Node = null              # the held build tool's hologram (build_holo.gd sets it)
static var _inst: Node = null
static var _shaders := {}
static var _hum_stream: AudioStream
static var _zap_streams: Array = []
static var _rise_stream: AudioStream
static var _hiss_stream: AudioStream
static var _streams_loaded := false

var _rigs: Array = []                     # pooled print rigs (Dictionary)
var _dust: Array = []                     # pooled CPUParticles3D
var _dust_i := 0
var _waves: Array = []                    # [MeshInstance3D, ShaderMaterial, t, dur] shockwaves
var _one: Array = []                      # pooled AudioStreamPlayer3D for the custom one-shots
var _one_i := 0
var _dust_mesh: QuadMesh
var _spark_mesh: QuadMesh


# =================================================================================================
# Static API
# =================================================================================================

## The placement print (see the header). `parent` only finds the scene; the effect lives in the runner.
static func assemble(parent: Node, xf: Transform3D, half_extents: Vector3, color := AUTO, node: Node3D = null) -> void:
	var r = _runner(parent if parent != null else node)
	if r == null:
		return
	r.call("_start_print", xf, half_extents, color, node)


## The reverse print (see the header). Frees `node` when it is done (at once outside a scene).
static func disassemble(parent: Node, xf: Transform3D, half_extents: Vector3, color = AUTO, node: Node3D = null) -> void:
	var r = _runner(parent if parent != null and is_instance_valid(parent) else node)
	if r == null:
		if node != null and is_instance_valid(node):
			node.queue_free()
		return
	r.call("_start_unprint", xf, half_extents, color if color is Color else AUTO, node)


## One-shot dust and clod burst on the ground (pooled; falls back to a fresh emitter outside a scene).
static func dust(parent: Node, pos: Vector3, up: Vector3, radius: float, col: Color) -> void:
	var r = _runner(parent)
	if r != null:
		r.call("_dust_burst", pos, up, radius, col)
		return
	if parent == null:
		return
	var p := _make_dust_emitter(null)
	parent.add_child(p)
	_setup_dust(p, pos, up, radius, col)
	p.finished.connect(p.queue_free)


## A ring that runs out over the ground from `pos` and fades (~0.8 s).
static func shockwave(parent: Node, pos: Vector3, up: Vector3, radius: float, col: Color) -> void:
	var r = _runner(parent)
	if r != null:
		r.call("_wave", pos, up, radius, col, 0.8)


static func snap_guides(pairs: Array) -> void:
	if holo != null and is_instance_valid(holo):
		holo.call("snap_guides", pairs)


static func snap_points(points: PackedVector3Array) -> void:
	if holo != null and is_instance_valid(holo):
		holo.call("snap_points", points)


static func headroom_box(xf: Transform3D, aabb: AABB, ok: bool) -> void:
	if holo != null and is_instance_valid(holo):
		holo.call("headroom_box", xf, aabb, ok)


static func mark_blockers(nodes: Array) -> void:
	if holo != null and is_instance_valid(holo):
		holo.call("mark_blockers", nodes)


## Mesh bounds of a structure in its own frame (every MeshInstance3D, visible or not, so a structure
## that hides its parts for the assembly still measures whole). Footings far below (a foundation in a
## crater) and stray huge meshes are left out; the bottom is clamped just under the base.
static func local_bounds(node: Node3D, fallback := AABB(Vector3(-2, 0, -2), Vector3(4, 3, 4))) -> AABB:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return fallback
	var inv := node.global_transform.affine_inverse()
	var out := AABB()
	var first := true
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or _detached(mi, node):
			continue
		var bb: AABB = (inv * mi.global_transform) * mi.get_aabb()
		if bb.get_center().y < -1.2 or bb.size.length() > 60.0 or bb.get_center().length() > 25.0:
			continue
		if first:
			out = bb
			first = false
		else:
			out = out.merge(bb)
	if first:
		return fallback
	if out.position.y < -0.6:
		out.size.y -= -0.6 - out.position.y
		out.position.y = -0.6
	out.size.y = clampf(out.size.y, 0.5, 18.0)
	return out


## True when `n` (or a node between it and `root`) is top_level: world-space effects a structure
## keeps as children (tracers, flashes) that are not part of its body.
static func _detached(n: Node, root: Node) -> bool:
	var cur := n
	while cur != null and cur != root:
		if cur is Node3D and (cur as Node3D).top_level:
			return true
		cur = cur.get_parent()
	return false


## A ground projector node (ZONE_SHADER, own material), hidden; place it with zone_place().
static func zone_node(parent: Node) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2, 2, 2)
	mi.mesh = bm
	var m := ShaderMaterial.new()
	m.shader = shader("zone")
	m.render_priority = 1
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.top_level = true
	mi.visible = false
	parent.add_child(mi)
	return mi


## Puts a projector at `pos` (basis: y = up) with half extents `ext` and its look.
static func zone_place(mi: MeshInstance3D, b: Basis, pos: Vector3, ext: Vector3, mode: int, radius: float, col: Color, k: float, phase := 0.0) -> void:
	mi.global_transform = Transform3D(b.orthonormalized() * Basis.from_scale(ext), pos)
	var m := mi.material_override as ShaderMaterial
	m.set_shader_parameter("ext", ext)
	m.set_shader_parameter("mode", float(mode))
	m.set_shader_parameter("radius", radius)
	m.set_shader_parameter("col", col)
	m.set_shader_parameter("k", k)
	m.set_shader_parameter("phase", phase)
	mi.visible = true


## Shared Shader objects by name: "volume", "slice", "overlay", "zone".
static func shader(id: String) -> Shader:
	if _shaders.has(id):
		return _shaders[id]
	var s := Shader.new()
	match id:
		"volume":
			s.code = VOLUME_SHADER
		"slice":
			s.code = SLICE_SHADER
		"overlay":
			s.code = OVERLAY_SHADER
		"dissolve":
			s.code = DISSOLVE_SHADER
		"dissolve_ds":
			s.code = DISSOLVE_SHADER.replace("cull_back", "cull_disabled")
		_:
			s.code = ZONE_SHADER
	_shaders[id] = s
	return s


## An orthonormal basis whose Y is `up`.
static func basis_up(up: Vector3) -> Basis:
	var y := up.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


static func _runner(from: Node) -> Node:
	if _inst != null and is_instance_valid(_inst) and _inst.is_inside_tree():
		return _inst
	if from == null or not is_instance_valid(from) or not from.is_inside_tree():
		return null
	var tree := from.get_tree()
	var scene: Node = tree.current_scene if tree.current_scene != null else tree.root
	var r: Node = load(SCRIPT_PATH).new()
	r.name = "BuildFx"
	scene.add_child(r)
	_inst = r
	return r


static func _load_streams() -> void:
	if _streams_loaded:
		return
	_streams_loaded = true
	_hum_stream = Snd.loop("ship/dig_beam")
	_rise_stream = Snd.one("foley/shield_up_01")
	_hiss_stream = Snd.rand("foley/hiss", 1.06, 1.5)
	for i in 5:
		var p := "res://assets/audio/scifi/forceField_%03d.ogg" % i
		if ResourceLoader.exists(p):
			var s = load(p)
			if s is AudioStream:
				_zap_streams.append(s)


static func _make_dust_emitter(mesh: QuadMesh) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 36
	p.lifetime = 1.8
	p.explosiveness = 0.9
	if mesh == null:
		mesh = _dust_quad()
	p.mesh = mesh
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.spread = 75.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 4.0
	p.damping_min = 1.0
	p.damping_max = 2.0
	p.scale_amount_min = 0.8
	p.scale_amount_max = 2.2
	var g := Gradient.new()
	g.set_color(0, Color(0.5, 0.45, 0.38, 0.55))
	g.set_color(1, Color(0.5, 0.45, 0.38, 0.0))
	p.color_ramp = g
	p.emitting = false
	return p


static func _dust_quad() -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(1.4, 1.4)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	return q


static func _setup_dust(p: CPUParticles3D, pos: Vector3, up: Vector3, radius: float, col: Color) -> void:
	p.emission_sphere_radius = maxf(radius * 0.6, 0.5)
	p.direction = up
	p.gravity = -up * 1.5
	var g := p.color_ramp
	if g != null:
		g.set_color(0, Color(col.r, col.g, col.b, 0.55))
		g.set_color(1, Color(col.r, col.g, col.b, 0.0))
	p.global_position = pos + up * 0.3
	p.restart()
	p.emitting = true


# =================================================================================================
# Runner
# =================================================================================================

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_dust_mesh = _dust_quad()
	_spark_mesh = QuadMesh.new()
	_spark_mesh.size = Vector2(0.07, 0.07)
	var sm := StandardMaterial3D.new()
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.vertex_color_use_as_albedo = true
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.albedo_texture = DigFx.soft_texture()
	_spark_mesh.material = sm
	_load_streams()


func _exit_tree() -> void:
	# Leave no overlay behind on a structure that outlives the runner (scene change mid-print).
	for rig in _rigs:
		if bool(rig["on"]):
			_end_rig(rig)


func _dust_burst(pos: Vector3, up: Vector3, radius: float, col: Color) -> void:
	var p: CPUParticles3D = null
	for e in _dust:
		if not (e as CPUParticles3D).emitting:
			p = e
			break
	if p == null:
		if _dust.size() < MAX_DUST:
			p = _make_dust_emitter(_dust_mesh)
			add_child(p)
			_dust.append(p)
		else:
			p = _dust[_dust_i % _dust.size()]
			_dust_i += 1
	_setup_dust(p, pos, up, radius, col)


## A ground ring: mode 3 runs out (a build), 4 draws in (a structure taken down).
func _wave(pos: Vector3, up: Vector3, radius: float, col: Color, dur: float, mode := 3) -> void:
	var w: Array = []
	for e in _waves:
		if float(e[2]) >= float(e[3]):
			w = e
			break
	if w.is_empty():
		if _waves.size() >= 6:
			w = _waves[0]
		else:
			w = [zone_node(self), null, 0.0, 1.0]
			_waves.append(w)
	w[1] = [pos, basis_up(up), radius, col, mode]
	w[2] = 0.0
	w[3] = dur
	_tick_wave(w, 0.0)


func _tick_wave(w: Array, delta: float) -> void:
	var mi := w[0] as MeshInstance3D
	w[2] = float(w[2]) + delta
	var ph := clampf(float(w[2]) / float(w[3]), 0.0, 1.0)
	if ph >= 1.0:
		mi.visible = false
		return
	var d: Array = w[1]
	var r := float(d[2])
	zone_place(mi, d[1], d[0], Vector3(r + 0.5, 2.5, r + 0.5), int(d[4]), r, d[3], 1.0, ph)


func _play_one(stream: AudioStream, pos: Vector3, db: float, pitch: float, unit := 10.0) -> void:
	if stream == null:
		return
	var p: AudioStreamPlayer3D = null
	for e in _one:
		if not (e as AudioStreamPlayer3D).playing:
			p = e
			break
	if p == null:
		if _one.size() < 6:
			p = AudioStreamPlayer3D.new()
			p.max_distance = 200.0
			add_child(p)
			_one.append(p)
		else:
			p = _one[_one_i % _one.size()]
			_one_i += 1
	p.stream = stream
	p.unit_size = unit
	p.volume_db = db
	p.pitch_scale = pitch
	p.global_position = pos
	p.play()


# --- Print rigs ------------------------------------------------------------------------------------

func _new_rig() -> Dictionary:
	var vol := MeshInstance3D.new()
	var vb := BoxMesh.new()
	vb.size = Vector3.ONE
	vol.mesh = vb
	var vm := ShaderMaterial.new()
	vm.shader = shader("volume")
	vm.render_priority = 2
	vol.material_override = vm
	vol.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	vol.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	vol.top_level = true
	vol.visible = false
	add_child(vol)
	var sl := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2.ONE
	sl.mesh = pm
	var smat := ShaderMaterial.new()
	smat.shader = shader("slice")
	smat.render_priority = 2
	sl.material_override = smat
	sl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sl.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	sl.top_level = true
	sl.visible = false
	add_child(sl)
	var om := ShaderMaterial.new()
	om.shader = shader("overlay")
	var light := OmniLight3D.new()
	light.shadow_enabled = false
	light.light_energy = 0.0
	light.top_level = true
	light.visible = false
	add_child(light)
	var sp := CPUParticles3D.new()
	sp.mesh = _spark_mesh
	sp.amount = 48
	sp.lifetime = 0.55
	sp.emitting = false
	sp.top_level = true
	sp.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	sp.direction = Vector3.UP
	sp.spread = 65.0
	sp.initial_velocity_min = 1.2
	sp.initial_velocity_max = 3.6
	sp.damping_min = 0.5
	sp.damping_max = 1.5
	sp.scale_amount_min = 0.6
	sp.scale_amount_max = 1.4
	var sg := Gradient.new()
	sg.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	sg.colors = PackedColorArray([Color(1.0, 0.95, 0.85, 1.0), Color(0.6, 0.92, 1.0, 0.85), Color(1.0, 0.55, 0.2, 0.0)])
	sp.color_ramp = sg
	add_child(sp)
	var hum := AudioStreamPlayer3D.new()
	hum.unit_size = 7.0
	hum.max_distance = 120.0
	hum.stream = _hum_stream
	add_child(hum)
	return {"on": false, "vol": vol, "vol_mat": vm, "slice": sl, "slice_mat": smat, "over": om,
			"light": light, "sparks": sp, "spark_grad": sg, "hum": hum, "node": null, "meshes": [],
			"xf": Transform3D(), "aabb": AABB(), "t": 0.0, "dur": 1.5, "col": CYAN, "hot": HOT_HOME,
			"tick": 0.0, "done": false, "lost": false, "wave": false,
			"mode": "build", "dmats": [], "hide": []}


## The sparks' look for a print (hot welding sparks) or a reverse print (slow nanite motes drifting up).
func _spark_look(rig: Dictionary, c0: Color, c1: Color, c2: Color, life: float, spread: float, vmin: float, vmax: float) -> void:
	var sp := rig["sparks"] as CPUParticles3D
	sp.lifetime = life
	sp.spread = spread
	sp.initial_velocity_min = vmin
	sp.initial_velocity_max = vmax
	var sg := rig["spark_grad"] as Gradient
	sg.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	sg.colors = PackedColorArray([c0, c1, c2])


func _take_rig() -> Dictionary:
	for rig in _rigs:
		if not bool(rig["on"]):
			return rig
	if _rigs.size() < MAX_RIGS:
		var r := _new_rig()
		_rigs.append(r)
		return r
	# All busy: finish the oldest one now.
	var oldest: Dictionary = _rigs[0]
	for rig in _rigs:
		if float(rig["t"]) > float(oldest["t"]):
			oldest = rig
	_end_rig(oldest)
	return oldest


func _start_print(xf: Transform3D, half: Vector3, color: Color, node: Node3D) -> void:
	var rig := _take_rig()
	var team := ""
	var alive := node != null and is_instance_valid(node) and node.is_inside_tree()
	if alive and node.get("team") != null:
		team = str(node.get("team"))
	var c := color
	if c.a <= 0.0:
		c = RIVAL if team == "rival" else CYAN
	var hot := HOT_RIVAL if team == "rival" or c.r > c.b else HOT_HOME
	var bb := AABB(Vector3(-half.x, 0.0, -half.z), Vector3(half.x * 2.0, half.y * 2.0, half.z * 2.0))
	if alive:
		xf = node.global_transform
		bb = local_bounds(node, bb)
	rig["on"] = true
	rig["mode"] = "build"
	rig["node"] = node if alive else null
	rig["xf"] = xf
	rig["aabb"] = bb
	rig["t"] = 0.0
	rig["dur"] = clampf(0.95 + bb.size.y * 0.2, 1.2, 2.2)
	rig["col"] = c
	rig["hot"] = hot
	rig["tick"] = 0.1
	rig["done"] = false
	rig["lost"] = false
	rig["wave"] = false
	var meshes: Array = rig["meshes"]
	meshes.clear()
	var om: ShaderMaterial = rig["over"]
	om.set_shader_parameter("col", c)
	om.set_shader_parameter("hot", hot)
	om.set_shader_parameter("k", 1.0)
	om.set_shader_parameter("front", -100.0)
	if alive:
		for n in node.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi.material_overlay == null and not mi.has_meta("no_print"):
				mi.material_overlay = om
				meshes.append(mi)
	(rig["vol_mat"] as ShaderMaterial).set_shader_parameter("col", c)
	(rig["slice_mat"] as ShaderMaterial).set_shader_parameter("col", c)
	var light := rig["light"] as OmniLight3D
	light.light_color = c.lerp(hot, 0.45)
	light.omni_range = maxf(bb.size.x, bb.size.z) * 0.9 + 2.5
	_spark_look(rig, Color(1.0, 0.95, 0.85, 1.0), Color(0.6, 0.92, 1.0, 0.85), Color(hot.r, hot.g * 0.8, hot.b * 0.6, 0.0),
			0.55, 65.0, 1.2, 3.6)
	var up := xf.basis.y.normalized()
	var base := xf.origin
	# Dust burst, sounds.
	var soil := Color(0.5, 0.45, 0.38)
	var body: Node3D = Game.dominant_body(base) if Game.has_method("dominant_body") else null
	if body != null and body.get("soil_color") is Color:
		soil = (body.get("soil_color") as Color).lightened(0.15)
	_dust_burst(base, up, maxf(bb.size.x, bb.size.z) * 0.5, soil)
	var hum := rig["hum"] as AudioStreamPlayer3D
	if hum.stream != null:
		hum.global_position = base + up * 1.0
		hum.volume_db = -30.0
		hum.pitch_scale = 1.15
		hum.play()
	if not _zap_streams.is_empty():
		_play_one(_zap_streams[randi() % _zap_streams.size()], base + up * 1.0, -8.0, randf_range(0.85, 0.95), 12.0)
	_play_one(_rise_stream, base + up * 0.5, -10.0, 1.05, 10.0)
	if Game.sfx:
		Game.sfx.play_at("servo", base, -6.0, 0.85, 14.0)
	_tick_rig(rig, 0.0)


func _process(delta: float) -> void:
	for rig in _rigs:
		if bool(rig["on"]):
			_tick_rig(rig, delta)
	for w in _waves:
		if float(w[2]) < float(w[3]):
			_tick_wave(w, delta)


func _tick_rig(rig: Dictionary, delta: float) -> void:
	if str(rig["mode"]) == "unbuild":
		_tick_unrig(rig, delta)
		return
	var t := float(rig["t"]) + delta
	var dur := float(rig["dur"])
	var node = rig["node"]
	var xf: Transform3D = rig["xf"]
	if node != null:
		if is_instance_valid(node) and (node as Node3D).is_inside_tree():
			xf = (node as Node3D).global_transform
			rig["xf"] = xf
		elif not bool(rig["lost"]):
			# Destroyed mid-print: skip to the fade.
			rig["lost"] = true
			rig["node"] = null
			t = maxf(t, RISE + dur)
	rig["t"] = t
	if t >= RISE + dur + FADE:
		_end_rig(rig)
		return
	var bb: AABB = rig["aabb"]
	var c: Color = rig["col"]
	var b := xf.basis.orthonormalized()
	var up := b.y
	var rise := clampf(t / RISE, 0.0, 1.0)
	var rise_e := 1.0 - pow(1.0 - rise, 3.0)
	var pk := clampf((t - RISE) / dur, 0.0, 1.0)
	var pe := pk * pk * (3.0 - 2.0 * pk)
	var fade := 1.0 - clampf((t - RISE - dur) / FADE, 0.0, 1.0)
	var bottom := bb.position.y
	var height := bb.size.y
	var cx := bb.get_center().x
	var cz := bb.get_center().z
	var front := lerpf(bottom - 0.15, bottom + height + 0.15, pe) if pk > 0.0 else bottom - 0.15
	# The build volume (rises out of the ground, then holds while the front climbs, then fades).
	var vh := maxf(height * rise_e, 0.02)
	var vsize := Vector3(bb.size.x + 0.3, vh, bb.size.z + 0.3)
	var vol := rig["vol"] as MeshInstance3D
	vol.visible = true
	vol.global_transform = Transform3D(b * Basis.from_scale(vsize), xf * Vector3(cx, bottom + vh * 0.5, cz))
	var vm := rig["vol_mat"] as ShaderMaterial
	vm.set_shader_parameter("size", vsize)
	vm.set_shader_parameter("front", clampf((front - bottom) / maxf(vh, 0.01), 0.0, 1.0))
	vm.set_shader_parameter("k", fade * (0.55 + 0.45 * rise_e) * (1.0 + 0.6 * (1.0 - rise)))
	# The build plate at the front.
	var sl := rig["slice"] as MeshInstance3D
	var plate := pk > 0.0 and pk < 1.0
	sl.visible = plate
	var fpos: Vector3 = xf * Vector3(cx, front, cz)
	if plate:
		sl.global_transform = Transform3D(b * Basis.from_scale(Vector3(vsize.x, 1.0, vsize.z)), fpos)
		var sm := rig["slice_mat"] as ShaderMaterial
		sm.set_shader_parameter("size", Vector2(vsize.x, vsize.z))
		sm.set_shader_parameter("k", minf(pk * 8.0, 1.0) * minf((1.0 - pk) * 8.0, 1.0))
	# The overlay on the real parts.
	var om := rig["over"] as ShaderMaterial
	om.set_shader_parameter("origin", xf.origin)
	om.set_shader_parameter("up", up)
	om.set_shader_parameter("front", front)
	om.set_shader_parameter("k", fade)
	# Sparks and the travelling light at the front.
	var sp := rig["sparks"] as CPUParticles3D
	var printing := pk > 0.02 and pk < 0.98
	sp.global_transform = Transform3D(b, fpos)
	sp.emission_box_extents = Vector3(bb.size.x * 0.5, 0.05, bb.size.z * 0.5)
	sp.gravity = -up * 6.0
	if printing != sp.emitting:
		sp.emitting = printing
	var light := rig["light"] as OmniLight3D
	light.visible = t < RISE + dur + FADE * 0.6
	light.global_position = fpos + up * 0.3
	light.light_energy = (1.1 + 0.25 * sin(t * 37.0) + 0.15 * randf()) * fade * (0.4 + 0.6 * rise_e)
	# Sound: the hum climbs with the print, welding ticks at the front.
	var hum := rig["hum"] as AudioStreamPlayer3D
	if hum.playing:
		hum.global_position = fpos
		hum.pitch_scale = 1.15 + 0.6 * pe
		hum.volume_db = lerpf(-30.0, -13.0, minf(t / 0.3, 1.0)) - (1.0 - fade) * 30.0
	if printing:
		rig["tick"] = float(rig["tick"]) - delta
		if float(rig["tick"]) <= 0.0:
			rig["tick"] = randf_range(0.08, 0.2)
			if Game.sfx:
				var off := b * Vector3(randf_range(-0.5, 0.5) * bb.size.x, 0.0, randf_range(-0.5, 0.5) * bb.size.z)
				Game.sfx.play_at("impact_light", fpos + off, -22.0, 1.3, 5.0)
	# The shockwave a moment after the touchdown.
	if not bool(rig["wave"]) and t >= 0.05:
		rig["wave"] = true
		_wave(xf.origin, up, maxf(bb.size.x, bb.size.z) * 0.5 + 3.0, c.lerp(Color(0.85, 0.8, 0.7), 0.35), 0.85)
	# Done: a hiss, a little thump for anyone near.
	if not bool(rig["done"]) and pk >= 1.0:
		rig["done"] = true
		hum.stop()
		_play_one(_hiss_stream, xf.origin + up * 0.4, -12.0, 0.95, 8.0)
		var pl = Game.player
		if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
			var d := (pl as Node3D).global_position.distance_to(xf.origin)
			if d < 25.0:
				pl.add_trauma(0.12 * (1.0 - d / 25.0))


func _end_rig(rig: Dictionary) -> void:
	var om = rig["over"]
	for mi in rig["meshes"]:
		if is_instance_valid(mi) and (mi as MeshInstance3D).material_overlay == om:
			(mi as MeshInstance3D).material_overlay = null
	(rig["meshes"] as Array).clear()
	(rig["vol"] as Node3D).visible = false
	(rig["slice"] as Node3D).visible = false
	(rig["light"] as Node3D).visible = false
	(rig["sparks"] as CPUParticles3D).emitting = false
	(rig["hum"] as AudioStreamPlayer3D).stop()
	if str(rig["mode"]) == "unbuild":
		# The reverse print owns its structure: gone now.
		var n = rig["node"]
		if n != null and is_instance_valid(n) and not (n as Node).is_queued_for_deletion():
			(n as Node).queue_free()
		(rig["dmats"] as Array).clear()
		(rig["hide"] as Array).clear()
	rig["node"] = null
	rig["on"] = false


# --- Reverse print (disassemble) -------------------------------------------------------------------

func _start_unprint(xf: Transform3D, half: Vector3, color: Color, node: Node3D) -> void:
	# An undo while it is still being printed: that print ends here (its overlay comes off first).
	for other in _rigs:
		if bool(other["on"]) and str(other["mode"]) == "build" and other["node"] == node and node != null:
			_end_rig(other)
	var rig := _take_rig()
	var alive := node != null and is_instance_valid(node) and node.is_inside_tree()
	var team := ""
	if alive and node.get("team") != null:
		team = str(node.get("team"))
	var c := color
	if c.a <= 0.0:
		c = RIVAL if team == "rival" else CYAN
	var bb := AABB(Vector3(-half.x, 0.0, -half.z), Vector3(half.x * 2.0, half.y * 2.0, half.z * 2.0))
	if alive:
		xf = node.global_transform
		bb = local_bounds(node, bb)
	rig["on"] = true
	rig["mode"] = "unbuild"
	rig["node"] = node if alive else null
	rig["xf"] = xf
	rig["aabb"] = bb
	rig["t"] = 0.0
	rig["dur"] = UN_DUR
	rig["col"] = c
	rig["hot"] = c
	rig["tick"] = 0.2
	rig["done"] = false
	rig["lost"] = false
	rig["wave"] = false
	var meshes: Array = rig["meshes"]
	meshes.clear()
	var dm: Array = rig["dmats"]
	dm.clear()
	var hide: Array = rig["hide"]
	hide.clear()
	var om: ShaderMaterial = rig["over"]
	om.set_shader_parameter("col", c)
	om.set_shader_parameter("hot", c.lerp(Color(1.0, 1.0, 1.0), 0.3))
	om.set_shader_parameter("k", 0.0)
	om.set_shader_parameter("front", 100.0)
	if alive:
		var conv := {}
		var inv := xf.affine_inverse()
		for n in node.find_children("*", "GeometryInstance3D", true, false):
			var gi := n as GeometryInstance3D
			if _detached(gi, node):
				gi.visible = false                  # its world-space effects (tracers, flashes): gone now
				continue
			if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
				var mi := gi as MeshInstance3D
				if not _dissolve_mesh(mi, conv, dm, c, xf):
					# Not a plain material (glass, a custom shader): an opaque one glows as nanite, and
					# every one of them winks out as the front passes its middle.
					if mi.visible and mi.material_overlay == null and not _see_through(mi):
						mi.material_overlay = om
						meshes.append(mi)
					hide.append([mi, ((inv * mi.global_transform) * mi.get_aabb()).get_center().y])
			elif gi.visible:
				hide.append([gi, ((inv * gi.global_transform) * gi.get_aabb()).get_center().y])     # labels, sprites, particles
	(rig["vol_mat"] as ShaderMaterial).set_shader_parameter("col", c)
	(rig["slice_mat"] as ShaderMaterial).set_shader_parameter("col", c)
	var light := rig["light"] as OmniLight3D
	light.light_color = c
	light.omni_range = maxf(bb.size.x, bb.size.z) * 0.8 + 2.0
	_spark_look(rig, Color(0.95, 1.0, 1.0, 0.9), Color(c.r, c.g, c.b, 0.7), Color(c.r, c.g, c.b, 0.0), 0.9, 35.0, 0.2, 0.9)
	var up := xf.basis.y.normalized()
	var base := xf.origin
	var hum := rig["hum"] as AudioStreamPlayer3D
	if hum.stream != null:
		hum.global_position = base + up * bb.end.y
		hum.volume_db = -34.0
		hum.pitch_scale = 1.6
		hum.play()
	if not _zap_streams.is_empty():
		_play_one(_zap_streams[randi() % _zap_streams.size()], base + up * 1.0, -14.0, 0.72, 10.0)
	_tick_unrig(rig, 0.0)


## A transparent BaseMaterial3D on it (glass, a glow sprite): no nanite overlay there.
func _see_through(mi: MeshInstance3D) -> bool:
	var count := mi.mesh.get_surface_count()
	for s in count:
		var m := mi.get_active_material(s)
		if m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
	return false


## A plain material swapped for its DISSOLVE_SHADER stand-in on every surface; false (nothing
## changed) when one of them cannot be (not a BaseMaterial3D, or transparent).
func _dissolve_mesh(mi: MeshInstance3D, conv: Dictionary, dm: Array, c: Color, xf: Transform3D) -> bool:
	if mi.material_override != null:
		var d := _dissolve_mat(mi.material_override, conv, dm, c, xf)
		if d == null:
			return false
		mi.material_override = d
		return true
	var count := mi.mesh.get_surface_count()
	var mats: Array = []
	for s in count:
		var d := _dissolve_mat(mi.get_active_material(s), conv, dm, c, xf)
		if d == null:
			return false
		mats.append(d)
	for s in count:
		mi.set_surface_override_material(s, mats[s])
	return true


func _dissolve_mat(src: Material, conv: Dictionary, dm: Array, c: Color, xf: Transform3D) -> ShaderMaterial:
	var key := src.get_instance_id() if src != null else 0
	if conv.has(key):
		return conv[key]
	var m := ShaderMaterial.new()
	if src == null:
		m.shader = shader("dissolve")
		m.set_shader_parameter("albedo", Color(0.8, 0.8, 0.8))
	else:
		if not (src is BaseMaterial3D):
			return null
		var bm := src as BaseMaterial3D
		if bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return null
		m.shader = shader("dissolve_ds" if bm.cull_mode == BaseMaterial3D.CULL_DISABLED else "dissolve")
		m.set_shader_parameter("albedo", bm.albedo_color)
		if bm.albedo_texture != null:
			m.set_shader_parameter("albedo_tex", bm.albedo_texture)
			m.set_shader_parameter("use_tex", 1.0)
		m.set_shader_parameter("use_vcol", 1.0 if bm.vertex_color_use_as_albedo else 0.0)
		m.set_shader_parameter("uv_scale", bm.uv1_scale)
		m.set_shader_parameter("uv_offset", bm.uv1_offset)
		m.set_shader_parameter("metallic", bm.metallic)
		m.set_shader_parameter("roughness", bm.roughness)
		if bm.emission_enabled:
			m.set_shader_parameter("emission", bm.emission * bm.emission_energy_multiplier)
		m.set_shader_parameter("unshaded_k", 1.0 if bm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED else 0.0)
	m.set_shader_parameter("col", c)
	m.set_shader_parameter("origin", xf.origin)
	m.set_shader_parameter("up", xf.basis.y.normalized())
	m.set_shader_parameter("front", 100.0)
	conv[key] = m
	dm.append(m)
	return m


func _tick_unrig(rig: Dictionary, delta: float) -> void:
	var t := float(rig["t"]) + delta
	var node = rig["node"]
	var xf: Transform3D = rig["xf"]
	if node != null and not (is_instance_valid(node) and (node as Node3D).is_inside_tree()):
		rig["node"] = null
		rig["lost"] = true
		t = maxf(t, UN_CHARGE + UN_DUR)
	rig["t"] = t
	if t >= UN_CHARGE + UN_DUR + UN_FADE:
		_end_rig(rig)
		return
	var bb: AABB = rig["aabb"]
	var c: Color = rig["col"]
	var b := xf.basis.orthonormalized()
	var up := b.y
	var ch := clampf(t / UN_CHARGE, 0.0, 1.0)
	var pk := clampf((t - UN_CHARGE) / UN_DUR, 0.0, 1.0)
	var pe := pk * pk * (3.0 - 2.0 * pk)
	var fade := 1.0 - clampf((t - UN_CHARGE - UN_DUR) / UN_FADE, 0.0, 1.0)
	var bottom := bb.position.y
	var top := bb.end.y
	var cx := bb.get_center().x
	var cz := bb.get_center().z
	var front := lerpf(top + 0.35, bottom - 0.4, pe)
	# The structure: dissolving stand-ins, glowing / winking-out others.
	var glow := ch * (1.0 - 0.4 * pk)
	for m in rig["dmats"]:
		var sm := m as ShaderMaterial
		sm.set_shader_parameter("front", front)
		sm.set_shader_parameter("glow", glow)
	var om := rig["over"] as ShaderMaterial
	om.set_shader_parameter("origin", xf.origin)
	om.set_shader_parameter("up", up)
	om.set_shader_parameter("front", front - 0.6)
	om.set_shader_parameter("k", ch)
	for e in rig["hide"]:
		if front < float(e[1]) and is_instance_valid(e[0]):
			(e[0] as Node3D).visible = false
	# The build volume: comes up around it, then its lid sinks with the front (it collapses).
	var vtop := clampf(front + 0.3, bottom + 0.02, top + 0.15)
	var vh := maxf(vtop - bottom, 0.02)
	var vsize := Vector3(bb.size.x + 0.3, vh, bb.size.z + 0.3)
	var vol := rig["vol"] as MeshInstance3D
	vol.visible = true
	vol.global_transform = Transform3D(b * Basis.from_scale(vsize), xf * Vector3(cx, bottom + vh * 0.5, cz))
	var vm := rig["vol_mat"] as ShaderMaterial
	vm.set_shader_parameter("size", vsize)
	vm.set_shader_parameter("front", clampf((front - bottom) / vh, 0.0, 1.0))
	vm.set_shader_parameter("k", fade * ch * 0.7)
	# The plate at the front.
	var sl := rig["slice"] as MeshInstance3D
	var plate := pk > 0.0 and pk < 1.0
	sl.visible = plate
	var fpos: Vector3 = xf * Vector3(cx, clampf(front, bottom, top), cz)
	if plate:
		sl.global_transform = Transform3D(b * Basis.from_scale(Vector3(vsize.x, 1.0, vsize.z)), fpos)
		var slm := rig["slice_mat"] as ShaderMaterial
		slm.set_shader_parameter("size", Vector2(vsize.x, vsize.z))
		slm.set_shader_parameter("k", 0.7 * minf(pk * 8.0, 1.0) * minf((1.0 - pk) * 6.0, 1.0))
	# Nanite motes drifting up off the front, a soft light riding it.
	var sp := rig["sparks"] as CPUParticles3D
	var going := pk > 0.03 and pk < 0.95
	sp.global_transform = Transform3D(b, fpos)
	sp.emission_box_extents = Vector3(bb.size.x * 0.45, 0.08, bb.size.z * 0.45)
	sp.gravity = up * 1.2
	if going != sp.emitting:
		sp.emitting = going
	var light := rig["light"] as OmniLight3D
	light.visible = true
	light.global_position = fpos + up * 0.2
	light.light_energy = (0.8 + 0.12 * sin(t * 29.0)) * fade * ch
	# Sound: the hum falls as it goes, faint ticks, a hiss when the base is gone.
	var hum := rig["hum"] as AudioStreamPlayer3D
	if hum.playing:
		hum.global_position = fpos
		hum.pitch_scale = lerpf(1.6, 0.85, pe)
		hum.volume_db = lerpf(-34.0, -17.0, ch) - (1.0 - fade) * 30.0
	if going:
		rig["tick"] = float(rig["tick"]) - delta
		if float(rig["tick"]) <= 0.0:
			rig["tick"] = randf_range(0.14, 0.3)
			if Game.sfx:
				Game.sfx.play_at("impact_light", fpos, -28.0, 1.35, 4.0)
	# A soft ring drawing in on the ground as the base goes.
	if not bool(rig["wave"]) and pk >= 0.55:
		rig["wave"] = true
		_wave(xf.origin, up, maxf(bb.size.x, bb.size.z) * 0.5 + 1.2, c, 0.6, 4)
	if not bool(rig["done"]) and pk >= 1.0:
		rig["done"] = true
		hum.stop()
		_play_one(_hiss_stream, xf.origin + up * 0.3, -16.0, 1.1, 7.0)
