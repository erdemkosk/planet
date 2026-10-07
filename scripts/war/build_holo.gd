extends Node3D
## The İnşa Aracı's in-world build-mode visuals (owned by scripts/war/build_tool.gd as `holo`; the
## tool feeds it every frame with show_ghost() and calls confirm() / refuse() / hide_all()). One
## top_level node at the world origin; everything below lives in world space.
##   GHOST       the real model as a hologram (scripts/war/build_preview.gd HOLO_*: inner glow, a
##               clean front shell with a chromatic fresnel rim, crease lines, scanlines, a rising
##               build slice), one cached material chain per kind. Coloured by validity with smooth
##               blends: cyan-white = can build, amber = fixable here (slope, uneven, too close),
##               red = blocked (wrong planet, no material). It prints itself in from the base when it
##               appears or the kind changes; on a build it collapses into the ground (BuildFx then
##               prints the real structure there) and comes back; a refused click shakes it and
##               flashes its edges.
##   PROJECTOR   PROJ_SHADER: one box whose pixels rebuild the ground point from the depth buffer
##               (the dig_fx.gd brush technique), so everything lies on the uneven ground: the
##               footprint rectangle (the ghost's real bounds) with corner brackets, a crawling dashed
##               outline, a fine grid inside (hatched when blocked), a facing chevron, dimension
##               lines on the camera side (Label3D "6.2 m"), the dashed keep-out circle, a world
##               lattice fixed to the planet that fades in around the cursor, 25 cm height contours
##               (amber and stronger when it is too steep / uneven), a terrain-scan ring sweeping out,
##               and the ROTATION GIZMO while turning (ticks every 15° / 45°, the arc turned since the
##               turn began, a pointer, a "135°" read-out).
##   BEAM        a scan beam from the emitter at the tool's fork (make_emitter(), on the view model)
##               to the ghost and a faint projection fan to the footprint corners; the emitter's
##               lens and gimbal rings, its light cone and the tool screen take the validity colour.
##   GUN ARC     Top / Delici Top: the default shot as a glowing dashed ribbon and a pulsing impact
##               ring on the other planet (refreshed ~3x a second; tool._arc_t = 0 refreshes now).
##   BLOCKERS    the structures in the way glow red on the ground (keep-out discs), brighter after a
##               refused click; "too close to you" marks your own feet.
##   BASE API    (also via BuildFx.snap_guides / snap_points / headroom_box / mark_blockers; call
##               every frame while they apply, they clear ~0.15 s after the last call):
##               snap_guides([[from, to], ...])  connector lines with flowing dashes, pulse dots at
##                                               both ends, a bright "locked" dot when they meet
##               snap_points(PackedVector3Array) free connectors nearby (small dim dots)
##               headroom_box(xf, aabb, ok)      underground: the clear volume outlined, its height
##                                               read-out, soil inside it hatched (amber / red), or
##                                               cyan when ok; the projector shrinks to the floor
##               mark_blockers([Node3D, ...])    extra structures to tint red
## Everything hides while Game.overlays_hidden() (match over, a menu, pause).

const BuildPreview := preload("res://scripts/war/build_preview.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const VM := preload("res://scripts/player/vm_parts.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Balance := preload("res://scripts/war/balance.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const ScreenPunch := preload("res://scripts/items/screen_punch.gd")

const VALID_COL := Color(0.62, 0.95, 1.0)       # cyan-white: can build
const FIX_COL := Color(1.0, 0.7, 0.28)          # amber: fixable (move / turn / step back)
const BLOCK_COL := Color(1.0, 0.3, 0.24)        # red: blocked
const GRID_COL := Color(0.7, 0.88, 1.0)
const COLLAPSE := 0.3                           # s: the ghost sinks into the ground on a build
const REST := 0.35                              # s: then stays away at least this long (the beam
const REST_MAX := 1.9                           #    feeds the print), until the aim moves off or this
const APPEAR := 0.45                            # s: prints itself back in from the base
const ARC_PERIOD := 0.3
const MAX_DOTS := 32
const LINGER := 0.15                            # s: base-API calls stay drawn this long

## Ground projector: footprint, grid, contours, scan, gizmo. See the header.
const PROJ_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 col : source_color = vec4(0.62, 0.95, 1.0, 1.0);
uniform vec4 warn_col : source_color = vec4(1.0, 0.7, 0.28, 1.0);
uniform vec4 grid_col : source_color = vec4(0.7, 0.88, 1.0, 1.0);
uniform float ext = 8.0;
uniform float half_h = 3.0;
uniform vec2 rmin = vec2(-2.0, -2.0);
uniform vec2 rmax = vec2(2.0, 2.0);
uniform float rot = 0.0;
uniform float clear_r = 3.0;
uniform float grid_r = 7.0;
uniform vec3 grid_o = vec3(0.0);
uniform vec3 up_w = vec3(0.0, 1.0, 0.0);
uniform float fade = 1.0;
uniform float gizmo = 0.0;
uniform float giz_r = 4.0;
uniform float giz_from = 0.0;
uniform float scan = 0.0;
uniform float alert = 0.0;
uniform float flat_warn = 0.0;
uniform vec2 dim_side = vec2(1.0, 1.0);
uniform float blocked = 0.0;

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

float wrap_pi(float a) {
	return mod(a + 3.14159265, 6.2831853) - 3.14159265;
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
	if (abs(l.x) > ext || abs(l.z) > ext || abs(l.y) > half_h) {
		discard;
	}
	float r = length(l.xz);
	// (capped low: across a crease of the ground the derivative spikes and a wide aa smeared every line
	// into thick red bands along the terrain's triangle edges)
	float aa = clamp(fwidth(r), 0.003, 0.06);
	float t = TIME;

	// Footprint, in the ghost's (rotated) frame.
	float cr = cos(rot);
	float sr = sin(rot);
	vec2 q = vec2(cr * l.x - sr * l.z, sr * l.x + cr * l.z);
	vec2 rc = (rmin + rmax) * 0.5;
	vec2 hs = (rmax - rmin) * 0.5;
	vec2 qa = abs(q - rc);
	vec2 qd = qa - hs;
	float sd = length(max(qd, vec2(0.0))) + min(max(qd.x, qd.y), 0.0);
	float inside = 1.0 - step(0.0, sd);
	float along = qd.y > qd.x ? q.x : q.y;
	float dph = fract(along * 2.0 - t * 0.6);
	float dash = smoothstep(0.0, 0.08, dph) * (1.0 - smoothstep(0.55, 0.63, dph));
	float outline = band(sd, aa * 0.6, aa * 1.2) * (0.45 + 0.55 * dash);
	float arm = min(0.9, min(hs.x, hs.y) * 0.45) + 0.2;
	vec2 o = qa - hs - vec2(0.14);
	float bw = 0.035;
	float arm_x = band(o.y, bw, aa) * step(-arm, o.x) * step(o.x, bw);
	float arm_z = band(o.x, bw, aa) * step(-arm, o.y) * step(o.y, bw);
	float bracket = max(arm_x, arm_z);
	vec2 gm = (0.5 - abs(fract(q * 2.0) - 0.5)) * 0.5;
	float inner_grid = max(band(gm.x, aa * 0.4, aa), band(gm.y, aa * 0.4, aa)) * inside;
	float hsx = (q.x + q.y) * 1.4;
	float hz = abs(fract(hsx) - 0.5);
	float hatch = (1.0 - smoothstep(0.12, 0.12 + clamp(fwidth(hsx), 0.01, 0.3) * 1.5, hz)) * inside * blocked;
	float fill = inside * (0.06 + 0.05 * smoothstep(-1.0, 0.0, sd));
	float dx = abs(q.x - rc.x);
	float chev = band(q.y - (rmin.y - 0.6) - dx * 0.9, 0.03, aa) * step(dx, 0.4);
	float zl = (dim_side.y > 0.0 ? rmax.y : rmin.y) + dim_side.y * 0.6;
	float xl = (dim_side.x > 0.0 ? rmax.x : rmin.x) + dim_side.x * 0.6;
	float dim_a = band(q.y - zl, 0.012, aa) * step(rmin.x, q.x) * step(q.x, rmax.x);
	dim_a += (band(q.x - rmin.x, 0.012, aa) + band(q.x - rmax.x, 0.012, aa)) * step(abs(q.y - zl), 0.16);
	float dim_b = band(q.x - xl, 0.012, aa) * step(rmin.y, q.y) * step(q.y, rmax.y);
	dim_b += (band(q.y - rmin.y, 0.012, aa) + band(q.y - rmax.y, 0.012, aa)) * step(abs(q.x - xl), 0.16);
	float dims = min(dim_a + dim_b, 1.0);

	// Keep-out circle (dashed).
	float ang = atan(l.z, l.x);
	float keep = band(r - clear_r, aa * 0.5, aa) * step(0.5, fract(ang / 6.2831853 * 64.0));

	// World lattice fixed to the planet, fading out around the cursor.
	vec3 w = (INV_VIEW_MATRIX * vec4(p, 1.0)).xyz - grid_o;
	vec3 gf = 0.5 - abs(fract(w) - 0.5);
	vec3 gw = min(fwidth(w), vec3(0.2));
	vec3 gl = vec3(1.0) - smoothstep(gw * 0.5, gw * 1.5 + 0.01, gf);
	vec3 fam = vec3(1.0) - smoothstep(vec3(0.55), vec3(0.85), abs(up_w));
	float lattice = max(max(gl.x * fam.x, gl.y * fam.y), gl.z * fam.z);
	float gfade = 1.0 - smoothstep(grid_r * 0.4, grid_r, r);

	// Height contours every 25 cm (dense where it is steep).
	float hy = l.y * 4.0;
	float cw = min(fwidth(hy), 0.5);
	float ch = 0.5 - abs(fract(hy) - 0.5);
	float contour = (1.0 - smoothstep(cw * 0.5, cw * 1.5, ch)) * (1.0 - smoothstep(clear_r, clear_r * 1.5, r));
	contour *= 1.0 - smoothstep(0.35, 0.5, cw);

	// Terrain-scan sweep.
	float rs = scan * grid_r * 1.15;
	float sx = (r - rs) / 0.45;
	float on_scan = 1.0 - step(1.0, scan);
	float sw = exp(-sx * sx) * on_scan;
	float trail = smoothstep(rs - 2.5, rs, r) * step(r, rs) * 0.35 * on_scan;
	float boost = 1.0 + sw * 2.5 + trail;

	// Rotation gizmo.
	float giz = 0.0;
	if (gizmo > 0.001) {
		float phi = atan(-l.x, -l.z);
		float rr = r - giz_r;
		float ring = band(rr, aa * 0.5, aa);
		float tk_m = abs(fract(phi / 0.2617994 + 0.5) - 0.5) * 0.2617994 * r;
		float tk_big = abs(fract(phi / 0.7853982 + 0.5) - 0.5) * 0.7853982 * r;
		float minor = band(tk_m, 0.012, aa) * step(0.0, rr) * step(rr, 0.22);
		float major = band(tk_big, 0.022, aa) * step(-0.15, rr) * step(rr, 0.42);
		float span = clamp(rot - giz_from, -6.27, 6.27);
		float rel = span >= 0.0 ? mod(phi - giz_from, 6.2831853) : mod(giz_from - phi, 6.2831853);
		float in_arc = step(rel, abs(span)) * step(0.002, abs(span));
		float swept = in_arc * band(rr + 0.02, 0.12, aa);
		float dphi = abs(wrap_pi(phi - rot)) * r;
		float pr = rr - 0.12;
		float ptr = step(0.0, pr) * step(pr, 0.38) * step(dphi, pr * 0.55);
		float heading = band(q.x - rc.x, 0.01, aa) * step(q.y, rmin.y - 0.7) * step(r, giz_r);
		giz = (ring * 0.6 + minor * 0.55 + major * 0.9 + swept * 0.45 + ptr * 0.95 + heading * 0.5) * gizmo;
	}

	vec3 c = col.rgb;
	float a_main = outline * 0.8 + bracket * 0.95 + chev * 0.75 + dims * 0.55 + fill + inner_grid * 0.12 + hatch * 0.28 + keep * 0.4;
	// The footprint marks only on ground near the footprint's own level: the projection column also
	// met the slope above / below it (seen from uphill, the hatch and outline spread over the hill).
	a_main *= 1.0 - smoothstep(1.3, 2.0, abs(l.y));
	a_main *= 1.0 + alert * 0.8;
	float a_grid = (lattice * 0.13 + sw * 0.07 + trail * 0.03) * gfade * boost;
	float a_cont = contour * (0.16 + 0.34 * flat_warn) * boost;
	float a = a_main + a_grid + a_cont + giz;
	vec3 rgb = (c * a_main + grid_col.rgb * a_grid + mix(c, warn_col.rgb, flat_warn) * a_cont + mix(c, vec3(1.0), 0.3) * giz) / max(a, 0.0001);
	rgb = mix(rgb, vec3(1.0), clamp(bracket * 0.3 + alert * 0.2 * outline, 0.0, 0.6));
	a *= fade * (1.0 - smoothstep(half_h * 0.7, half_h, abs(l.y)));
	ALBEDO = rgb;
	ALPHA = clamp(a, 0.0, 0.92);
}
"""

## Camera-facing ribbons (the gun arc, snap lines, the headroom box): NORMAL = the line's tangent,
## UV = (metres along it, side -1..1), COLOR.a = alpha; flowing dashes over a faint solid glow.
const RIBBON_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled, skip_vertex_transform;

uniform vec4 col : source_color = vec4(0.62, 0.95, 1.0, 1.0);
uniform float width = 0.03;
uniform float px = 0.0016;
uniform float dash = 2.0;
uniform float duty = 0.55;
uniform float flow = 1.5;
uniform float total = 100.0;
uniform float k = 1.0;
varying float v_s;
varying float v_side;
varying float v_a;

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 tng = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz + vec3(0.00001));
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 tc = cam - w;
	float d = max(length(tc), 0.001);
	vec3 side = cross(tng, tc / d);
	float sl = length(side);
	side = sl > 0.0001 ? side / sl : vec3(0.0);
	w += side * UV.y * max(width, d * px);
	VERTEX = (VIEW_MATRIX * vec4(w, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
	v_s = UV.x;
	v_side = UV.y;
	v_a = COLOR.a;
}

void fragment() {
	float across = 1.0 - abs(v_side);
	float core = across * across;
	float on = 1.0;
	if (dash > 0.0) {
		float ph = fract((v_s - TIME * flow) / dash);
		on = smoothstep(0.0, 0.06, ph) * (1.0 - smoothstep(duty - 0.06, duty, ph));
	}
	float ends = smoothstep(0.0, 0.6, v_s) * (1.0 - smoothstep(total - 1.5, total, v_s));
	ALBEDO = mix(col.rgb, vec3(1.0), core * 0.3);
	ALPHA = clamp((core * 0.85 + across * 0.2) * mix(0.28, 1.0, on) * ends * k * v_a, 0.0, 1.0);
}
"""

## Projection fan: four ribbons from the emitter (apex) to the footprint corners c0..c3, placed in
## the vertex shader (VERTEX = corner index, t along, side), so the mesh never changes.
const FAN_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled, skip_vertex_transform;

uniform vec4 col : source_color = vec4(0.62, 0.95, 1.0, 1.0);
uniform vec3 apex = vec3(0.0);
uniform vec3 c0 = vec3(0.0);
uniform vec3 c1 = vec3(0.0);
uniform vec3 c2 = vec3(0.0);
uniform vec3 c3 = vec3(0.0);
uniform float k = 1.0;
varying float v_t;
varying float v_side;

void vertex() {
	int i = int(VERTEX.x + 0.5);
	float tt = VERTEX.y;
	float sd = VERTEX.z;
	vec3 c = c0;
	if (i == 1) {
		c = c1;
	} else if (i == 2) {
		c = c2;
	} else if (i == 3) {
		c = c3;
	}
	vec3 w = mix(apex, c, tt);
	vec3 tng = normalize(c - apex + vec3(0.00001));
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 tc = cam - w;
	float d = max(length(tc), 0.001);
	vec3 side = cross(tng, tc / d);
	float sl = length(side);
	side = sl > 0.0001 ? side / sl : vec3(0.0);
	w += side * sd * max(0.006, d * 0.0012);
	VERTEX = (VIEW_MATRIX * vec4(w, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
	v_t = tt;
	v_side = sd;
}

void fragment() {
	float across = 1.0 - abs(v_side);
	float flow = 0.5 + 0.5 * sin(v_t * 40.0 - TIME * 8.0);
	float ends = smoothstep(0.15, 0.55, v_t) * (1.0 - smoothstep(0.97, 1.0, v_t));
	ALBEDO = col.rgb;
	ALPHA = clamp(across * across * (0.07 + 0.11 * flow) * ends * k, 0.0, 1.0);
}
"""

## Snap dots (MultiMesh billboards; INSTANCE_CUSTOM: x kind 0 free / 1 guide end / 2 locked,
## y phase, z size m), drawn over everything so a connector behind a wall still shows.
const DOT_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

uniform vec4 col : source_color = vec4(0.62, 0.95, 1.0, 1.0);
varying float v_kind;
varying float v_ph;

void vertex() {
	vec3 c = MODEL_MATRIX[3].xyz;
	float d = length(INV_VIEW_MATRIX[3].xyz - c);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	VERTEX *= INSTANCE_CUSTOM.z * clamp(d * 0.06, 0.5, 4.0);
	v_kind = INSTANCE_CUSTOM.x;
	v_ph = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec2 u = UV * 2.0 - 1.0;
	float r = length(u);
	float pulse = fract(TIME * 1.6 + v_ph);
	float core = 1.0 - smoothstep(0.16, 0.28, r);
	float ring = (1.0 - smoothstep(0.03, 0.09, abs(r - (0.32 + 0.6 * pulse)))) * (1.0 - pulse);
	float halo = (1.0 - smoothstep(0.0, 1.0, r)) * 0.25;
	vec3 c = col.rgb;
	float a = core * 0.45 + halo * 0.3;
	if (v_kind > 0.5) {
		a = core * 0.95 + ring * 0.8 + halo;
	}
	if (v_kind > 1.5) {
		c = vec3(1.0, 0.96, 0.88);
	}
	ALBEDO = c;
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

## The emitter's light cone on the view model (the view-model depth slice, see vm_parts.gd).
const EMIT_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 col : source_color = vec4(0.62, 0.95, 1.0, 1.0);
uniform float energy = 1.0;
uniform float cone_h = 0.077;
varying float v_y;

void vertex() {
	v_y = VERTEX.y / cone_h + 0.5;
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	float edge = 1.0 - abs(dot(NORMAL, VIEW));
	float flow = 0.6 + 0.4 * sin(v_y * 30.0 - TIME * 14.0);
	ALBEDO = col.rgb;
	ALPHA = clamp((0.15 + 0.5 * edge) * (1.0 - clamp(v_y, 0.0, 1.0)) * flow * energy, 0.0, 1.0);
}
"""

static var _emit_shader: Shader
static var _shaders := {}

var tool                                        # build_tool.gd

# Inputs (show_ghost(), every frame the ghost is wanted).
var _want := false
var _e: Dictionary = {}
var _xf := Transform3D()
var _up := Vector3.UP
var _base_b := Basis()
var _rot := 0.0
var _rot_t := 0.0
var _state := 0
var _reason := ""

# Ghosts.
var ghost: Node3D                               # the current ghost root
var _ghosts := {}                               # kind -> {"root", "mat", "aabb", "height"}
var _kind := ""
var _col := VALID_COL
var _appear := 0.0
var _flash := 0.0
var _alert := 0.0
var _shake := 0.0
var _collapse := -1.0
var _collapse_xf := Transform3D()
var _pulse := 0.0
var _away := 1.0                                # s since the ghost was last shown
var _t := 0.0
var _hidden := true

# Projector, labels, gizmo.
var _proj: MeshInstance3D
var _proj_mat: ShaderMaterial
var _proj_on := 0.0
var _scan := 0.0
var _giz := 0.0
var _giz_hold := 0.0
var _giz_from := 0.0
var _flat := 0.0
var _lbl_w: Label3D
var _lbl_d: Label3D
var _lbl_ang: Label3D
var _lbl_head: Label3D
var _lw := -1.0                                 # label values shown (texts rebuilt only on change)
var _ld := -1.0
var _la := -1

# Beam, fan.
var _beams: Array = []                          # [MeshInstance3D, ShaderMaterial, intensity]
var _fan: MeshInstance3D
var _fan_mat: ShaderMaterial

# Gun arc.
var _arc: MeshInstance3D
var _arc_im: ImmediateMesh
var _arc_mat: ShaderMaterial
var _arc_pts := PackedVector3Array()
var _arc_hit := Vector3.INF
var _impact: MeshInstance3D

# Blockers.
var _zones: Array = []                          # keep-out projectors
var _blockers: Array = []
var _blk_t := 0.0
var _extra_blk: Array = []
var _extra_blk_t := 0.0

# Base-building API.
var _snap_pairs: Array = []
var _snap_t := 0.0
var _snap_pts := PackedVector3Array()
var _snap_pts_t := 0.0
var _head_xf := Transform3D()
var _head_bb := AABB()
var _head_ok := true
var _head_t := 0.0
var _lines: MeshInstance3D
var _lines_im: ImmediateMesh
var _lines_mat: ShaderMaterial
var _lines_key := ""
var _dots: MultiMeshInstance3D
var _mm: MultiMesh
var _dots_mat: ShaderMaterial
var _head_zone: MeshInstance3D

var _sfx: AudioStreamPlayer
var _thump: AudioStream


# =================================================================================================
# The emitter on the tool's view model
# =================================================================================================

## The holo-projector at the tool's emitter fork (call in build_model() before VM.bake): a tip
## marker (where the beam starts), a lens, two gimbal rings that precess, a short light cone.
## Returns the dictionary the build tool keeps as `emitter` (animated by this node).
static func make_emitter(model: Node3D) -> Dictionary:
	var tip := VM.node(model, Vector3(0, 0.06, -0.272))
	var lens := VM.glow(VALID_COL, 2.4)
	var lm := VM.sphere(model, Vector3(0, 0.06, -0.266), 0.0055, lens)
	lm.set_meta("no_bake", true)
	var ring_mat := VM.glow(VALID_COL, 1.8)
	var c := Vector3(0, 0.06, -0.258)
	var r1 := VM.ring(model, c, Vector3(0, 0, -1), 0.03, 0.0026, ring_mat)
	r1.set_meta("no_bake", true)
	var r2 := VM.ring(model, c, Vector3(0, 0, -1), 0.019, 0.0021, ring_mat)
	r2.set_meta("no_bake", true)
	if _emit_shader == null:
		_emit_shader = Shader.new()
		_emit_shader.code = VM.prep(EMIT_SHADER)
	var cone_mat := ShaderMaterial.new()
	cone_mat.shader = _emit_shader
	cone_mat.set_shader_parameter("cone_h", 0.077)
	var cone := VM.seg(model, Vector3(0, 0.06, -0.268), Vector3(0, 0.06, -0.345), 0.003, 0.03, cone_mat, 16)
	cone.set_meta("no_bake", true)
	return {"tip": tip, "lens": lens, "ring_mat": ring_mat, "r1": r1, "r2": r2, "ring_b": r1.transform.basis,
			"ring_c": c, "cone_mat": cone_mat}


# =================================================================================================
# API (build tool)
# =================================================================================================

## The ghost root for entry `e` (built and cached on first use).
func ghost_root(e: Dictionary) -> Node3D:
	var kind := str(e.get("id", ""))
	if not _ghosts.has(kind) or not is_instance_valid(_ghosts[kind]["root"]):
		_ghosts[kind] = _make_ghost(e)
	return _ghosts[kind]["root"]


## Every frame the ghost is wanted: entry, placement (basis y = up, rotation applied), the
## unrotated base frame, the shown / target rotation, the state (0 can build, 1 fixable, 2 blocked)
## and the reason text.
func show_ghost(e: Dictionary, xf: Transform3D, up: Vector3, base_b: Basis, rot: float, rot_t: float,
		state: int, reason: String) -> void:
	_want = true
	_e = e
	_xf = xf
	_up = up
	_base_b = base_b
	_rot = rot
	_rot_t = rot_t
	_state = state
	_reason = reason


func hide_all() -> void:
	_want = false
	_hide_world()


## A build went through at `xf`: the ghost collapses into the ground, the beam pulses, the snap
## sound and a small camera kick (BuildFx.assemble prints the structure itself).
func confirm(xf: Transform3D) -> void:
	_collapse = 0.0
	_collapse_xf = xf
	_flash = 1.0
	_pulse = 1.0
	if Game.sfx:
		Game.sfx.play("craft", -7.0, 1.05)
		Game.sfx.play_at("impact", xf.origin, -11.0, 1.25, 10.0)
	if _thump != null:
		_sfx.stream = _thump
		_sfx.volume_db = -9.0
		_sfx.pitch_scale = 0.9
		_sfx.play()
	ScreenPunch.kick(0.14)
	if tool != null:
		tool.kick = maxf(float(tool.kick), 0.5)
		var pl = tool.player
		if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
			pl.add_trauma(0.3)


## A click that could not build: the ghost shakes and flashes, the blockers glow, a denied buzz.
func refuse() -> void:
	_shake = 1.0
	_alert = 1.0
	_blk_t = 0.0
	if tool != null:
		tool.kick = maxf(float(tool.kick), 0.12)
	if not BuildFx._zap_streams.is_empty():
		_sfx.stream = BuildFx._zap_streams[randi() % BuildFx._zap_streams.size()]
		_sfx.volume_db = -14.0
		_sfx.pitch_scale = 0.55
		_sfx.play()


# --- Base-building API (also through BuildFx) ------------------------------------------------------

func snap_guides(pairs: Array) -> void:
	_snap_pairs = pairs
	_snap_t = LINGER


func snap_points(points: PackedVector3Array) -> void:
	_snap_pts = points
	_snap_pts_t = LINGER


func headroom_box(xf: Transform3D, aabb: AABB, ok: bool) -> void:
	_head_xf = xf
	_head_bb = aabb
	_head_ok = ok
	_head_t = LINGER


func mark_blockers(nodes: Array) -> void:
	_extra_blk = nodes
	_extra_blk_t = LINGER


# =================================================================================================
# Setup
# =================================================================================================

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	process_mode = Node.PROCESS_MODE_ALWAYS          # so a pause (no show_ghost calls) hides it all
	BuildFx.holo = self
	BuildFx._load_streams()
	_sfx = AudioStreamPlayer.new()
	add_child(_sfx)
	var th: Array = Snd.set_of("feel/thump")
	_thump = th[0] if not th.is_empty() else null
	# Ground projector.
	_proj_mat = ShaderMaterial.new()
	_proj_mat.shader = _shader("proj", PROJ_SHADER)
	_proj_mat.render_priority = 1
	_proj_mat.set_shader_parameter("warn_col", FIX_COL)
	_proj_mat.set_shader_parameter("grid_col", GRID_COL)
	_proj = _box_node(_proj_mat)
	# Labels.
	_lbl_w = _label(26)
	_lbl_d = _label(26)
	_lbl_ang = _label(34)
	_lbl_head = _label(26)
	# Scan beam (the dig beam's bezier tube, toned down) and the projection fan.
	var bs := _shader("beam", DigFx.BEAM_SHADER.replace("vec3(1.7)", "vec3(1.1)"))
	for spec in [[0.004, 0.012, 0.004, 0.75, 0.7], [0.018, 0.05, 0.01, 0.14, 0.0]]:
		var cm := CylinderMesh.new()
		cm.top_radius = 1.0
		cm.bottom_radius = 1.0
		cm.height = 1.0
		cm.radial_segments = 8
		cm.rings = 32
		cm.cap_top = false
		cm.cap_bottom = false
		var m := ShaderMaterial.new()
		m.shader = bs
		m.render_priority = 6
		m.set_shader_parameter("radius", spec[0])
		m.set_shader_parameter("radius_end", spec[1])
		m.set_shader_parameter("wobble", spec[2])
		m.set_shader_parameter("helix", 0.0)
		m.set_shader_parameter("flow", 0.6)
		m.set_shader_parameter("core_white", spec[4])
		var mi := MeshInstance3D.new()
		mi.mesh = cm
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.custom_aabb = AABB(Vector3.ONE * -1.0e5, Vector3.ONE * 2.0e5)
		mi.top_level = true
		mi.visible = false
		add_child(mi)
		_beams.append([mi, m, float(spec[3])])
	_fan_mat = ShaderMaterial.new()
	_fan_mat.shader = _shader("fan", FAN_SHADER)
	_fan_mat.render_priority = 6
	_fan = MeshInstance3D.new()
	_fan.mesh = _fan_mesh(20)
	_fan.material_override = _fan_mat
	_fan.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fan.custom_aabb = AABB(Vector3.ONE * -1.0e5, Vector3.ONE * 2.0e5)
	_fan.top_level = true
	_fan.visible = false
	add_child(_fan)
	# Gun arc and its impact ring.
	_arc_im = ImmediateMesh.new()
	_arc_mat = _ribbon_mat(0.035, 0.0018, 3.0, 0.55, 4.0)
	_arc = _mesh_node(_arc_im, _arc_mat)
	_impact = BuildFx.zone_node(self)
	# Keep-out discs for blockers.
	for i in 6:
		_zones.append(BuildFx.zone_node(self))
	# Snap lines / headroom edges, dots, the headroom soil hatch.
	_lines_im = ImmediateMesh.new()
	_lines_mat = _ribbon_mat(0.016, 0.0012, 0.35, 0.6, 1.2)
	_lines = _mesh_node(_lines_im, _lines_mat)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	_mm.mesh = q
	_mm.instance_count = MAX_DOTS
	_mm.visible_instance_count = 0
	_dots_mat = ShaderMaterial.new()
	_dots_mat.shader = _shader("dot", DOT_SHADER)
	_dots_mat.render_priority = 7
	_dots = MultiMeshInstance3D.new()
	_dots.multimesh = _mm
	_dots.material_override = _dots_mat
	_dots.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dots.custom_aabb = AABB(Vector3.ONE * -1.0e5, Vector3.ONE * 2.0e5)
	_dots.top_level = true
	_dots.visible = false
	add_child(_dots)
	_head_zone = BuildFx.zone_node(self)
	_hide_world()


func _exit_tree() -> void:
	if BuildFx.holo == self:
		BuildFx.holo = null


static func _shader(id: String, code: String) -> Shader:
	if _shaders.has(id):
		return _shaders[id]
	var s := Shader.new()
	s.code = code
	_shaders[id] = s
	return s


func _box_node(m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2, 2, 2)
	mi.mesh = bm
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.top_level = true
	mi.visible = false
	add_child(mi)
	return mi


func _mesh_node(mesh: Mesh, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.custom_aabb = AABB(Vector3.ONE * -1.0e5, Vector3.ONE * 2.0e5)
	mi.top_level = true
	mi.visible = false
	add_child(mi)
	return mi


func _ribbon_mat(width: float, px: float, dash: float, duty: float, flow: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader("ribbon", RIBBON_SHADER)
	m.render_priority = 6
	m.set_shader_parameter("width", width)
	m.set_shader_parameter("px", px)
	m.set_shader_parameter("dash", dash)
	m.set_shader_parameter("duty", duty)
	m.set_shader_parameter("flow", flow)
	return m


func _label(size: int) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0009
	l.font = UI.font(700)
	l.font_size = size
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.55)
	l.no_depth_test = true
	l.shaded = false
	l.double_sided = true
	l.render_priority = 9
	l.outline_render_priority = 8
	l.top_level = true
	l.visible = false
	add_child(l)
	return l


## The fan's fixed mesh: per corner i, `seg` steps along, two sides; VERTEX = (i, t, side).
static func _fan_mesh(seg: int) -> ArrayMesh:
	var v := PackedVector3Array()
	for i in 4:
		for j in seg:
			var t0 := float(j) / float(seg)
			var t1 := float(j + 1) / float(seg)
			v.append(Vector3(i, t0, -1.0))
			v.append(Vector3(i, t0, 1.0))
			v.append(Vector3(i, t1, 1.0))
			v.append(Vector3(i, t0, -1.0))
			v.append(Vector3(i, t1, 1.0))
			v.append(Vector3(i, t1, -1.0))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Bounds of the ghost's meshes only (no lights, particles or labels).
static func _mesh_bounds(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		if not (n is MeshInstance3D or n is MultiMeshInstance3D):
			continue
		var gi := n as GeometryInstance3D
		if not gi.is_visible_in_tree():
			continue
		var bb := gi.global_transform * gi.get_aabb()
		out = bb if first else out.merge(bb)
		first = false
	return BuildPreview.bounds(root) if first else out


func _make_ghost(e: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.top_level = true
	root.name = "BuildGhost_" + str(e.get("id", ""))
	add_child(root)
	root.global_transform = Transform3D.IDENTITY
	var m := BuildPreview.model(root, e)
	if m == null:
		var half: Vector3 = e.get("half", Vector3(3, 1.5, 4))
		var bm := BoxMesh.new()
		bm.size = half * 2.0
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.position = Vector3(0, half.y, 0)
		root.add_child(mi)
	BuildPreview.wireframe(root)
	var mat := BuildPreview.holo_material()
	BuildPreview.hologram(root, mat)
	var bb := _mesh_bounds(root)
	# The footprint drawn on the ground is the entry's real footprint ("half", what the placement
	# checks): BuildPreview.bounds also counts lights and particle boxes (the rig's work lights made
	# its blocked footprint, hatch and grid, cover the ground ~10 m round).
	if e.has("half"):
		var hf: Vector3 = e["half"]
		var lo := Vector3(maxf(bb.position.x, -hf.x * 1.1), bb.position.y, maxf(bb.position.z, -hf.z * 1.1))
		var hi := Vector3(minf(bb.end.x, hf.x * 1.1), bb.end.y, minf(bb.end.z, hf.z * 1.1))
		if hi.x > lo.x and hi.z > lo.z:
			bb = AABB(lo, hi - lo)
	root.visible = false
	var h := maxf(bb.end.y, 1.0)
	return {"root": root, "mat": mat, "aabb": bb, "height": h}


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	_flash = maxf(_flash - delta * 2.4, 0.0)
	_alert = maxf(_alert - delta * 2.2, 0.0)
	_shake = maxf(_shake - delta * 2.8, 0.0)
	_pulse = maxf(_pulse - delta * 2.5, 0.0)
	_snap_t -= delta
	_snap_pts_t -= delta
	_head_t -= delta
	_extra_blk_t -= delta
	var want := _want and not Game.overlays_hidden()
	_want = false
	_emitter_tick(want)
	if not want:
		_away += delta
		_collapse = -1.0
		if not _hidden:
			_hide_world()
		return
	_hidden = false
	var e := _e
	var kind := str(e.get("id", ""))
	if kind != _kind or ghost == null or not is_instance_valid(ghost):
		if ghost != null and is_instance_valid(ghost):
			ghost.visible = false
		ghost = ghost_root(e)
		_kind = kind
		_appear = 0.0
		_arc_pts = PackedVector3Array()
		_arc_hit = Vector3.INF
		if tool != null:
			tool.set("_arc_t", 0.0)
	if _away > 0.3:
		_appear = 0.0
	_away = 0.0
	var g: Dictionary = _ghosts[kind]
	var target := VALID_COL if _state == 0 else (FIX_COL if _state == 1 else BLOCK_COL)
	_col = _col.lerp(target, 1.0 - exp(-10.0 * delta))
	_tick_ghost(g, delta)
	_tick_projector(g, delta)
	_tick_beam(g)
	_tick_arc(delta)
	_tick_blockers(delta)
	_tick_base_api()


func _hide_world() -> void:
	_hidden = true
	if ghost != null and is_instance_valid(ghost):
		ghost.visible = false
	for n: Node3D in [_proj, _fan, _arc, _impact, _lines, _dots, _head_zone, _lbl_w, _lbl_d, _lbl_ang, _lbl_head]:
		if n != null:
			n.visible = false
	for b in _beams:
		(b[0] as Node3D).visible = false
	for z in _zones:
		(z as Node3D).visible = false
	_proj_on = 0.0
	_giz = 0.0


## Ghost transform and hologram uniforms (collapse / rest / appear, shake, colour).
func _tick_ghost(g: Dictionary, delta: float) -> void:
	var mat: ShaderMaterial = g["mat"]
	var h := float(g["height"])
	var gxf := _xf
	var shown := true
	if _collapse >= 0.0:
		_collapse += delta
		if _collapse < COLLAPSE:
			var k := _collapse / COLLAPSE
			var ke := k * k
			gxf = Transform3D(_collapse_xf.basis * Basis.from_scale(Vector3(1.0 + 0.06 * k, maxf(1.0 - ke, 0.02), 1.0 + 0.06 * k)),
					_collapse_xf.origin)
			_flash = 1.0
		elif _collapse < COLLAPSE + REST_MAX and (_collapse < COLLAPSE + REST or \
				_xf.origin.distance_to(_collapse_xf.origin) < float(_e.get("radius", 3.0))):
			shown = false
			_appear = 0.0
		else:
			_collapse = -1.0
			_appear = 0.0
	if _collapse < 0.0:
		_appear = minf(_appear + delta / APPEAR, 1.0)
	if _shake > 0.0:
		var s := _shake * _shake
		var side := gxf.basis.x.normalized()
		gxf = Transform3D(Basis(_up, sin(_t * 47.0) * 0.03 * s) * gxf.basis, gxf.origin + side * sin(_t * 71.0) * 0.09 * s)
	ghost.visible = shown
	if not shown:
		return
	ghost.global_transform = gxf
	var ap := 1.0 - pow(1.0 - _appear, 2.0)
	BuildPreview.holo_set(mat, "col", _col)
	BuildPreview.holo_set(mat, "origin", gxf.origin)
	BuildPreview.holo_set(mat, "up", _up)
	BuildPreview.holo_set(mat, "height", h)
	BuildPreview.holo_set(mat, "flash", _flash)
	BuildPreview.holo_set(mat, "appear", ap)
	BuildPreview.holo_set(mat, "alert", _alert)
	BuildPreview.holo_set(mat, "vis", 1.0)


## Footprint, grid, contours, scan, gizmo; the dimension and angle labels.
func _tick_projector(g: Dictionary, delta: float) -> void:
	var resting := _collapse >= 0.0
	_proj_on = move_toward(_proj_on, 0.0 if resting else 1.0, delta * (5.0 if resting else 3.5))
	var bb: AABB = g["aabb"]
	var rmin := Vector2(bb.position.x, bb.position.z)
	var rmax := Vector2(bb.end.x, bb.end.z)
	var clear_r := float(_e.get("radius", 3.0))
	var corner := maxf(maxf(rmin.length(), rmax.length()), maxf(Vector2(rmin.x, rmax.y).length(), Vector2(rmax.x, rmin.y).length()))
	var giz_r := corner + 0.8
	var grid_r := clampf(maxf(clear_r * 1.8, corner * 1.6), 4.5, 9.0)
	var ext := maxf(maxf(grid_r, giz_r + 1.2), maxf(clear_r + 0.6, corner + 1.6))
	var underground := _head_t > 0.0
	var half_h := 1.4 if underground else clampf(ext * 0.5, 2.5, 6.0)
	var o := _xf.origin
	_proj.global_transform = Transform3D(Basis(_base_b.x * ext, _base_b.y * half_h, _base_b.z * ext), o)
	_proj.visible = true
	# The ghost's frame and its yaw in the base frame (a snapped piece brings its own basis).
	var gb := _xf.basis.orthonormalized()
	var gx := Transform3D(gb, o)
	var rot_eff := atan2(-gb.x.dot(_base_b.z), gb.x.dot(_base_b.x))
	# Rotation gizmo while turning (R steps animate, right mouse turns freely), lingers a moment.
	var turning := absf(angle_difference(_rot, _rot_t)) > 0.015 or \
			(Input.is_action_pressed("tool_alt") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	if turning:
		if _giz < 0.05 and _giz_hold <= 0.0:
			_giz_from = rot_eff
		_giz_hold = 0.9
	else:
		_giz_hold -= delta
	_giz = move_toward(_giz, 1.0 if _giz_hold > 0.0 else 0.0, delta * (6.0 if _giz_hold > 0.0 else 2.5))
	_scan += delta / 2.4
	if _scan > 1.3:
		_scan = 0.0
	var fw := 1.0 if (_reason.contains("eğim") or _reason.contains("düz")) else 0.0
	_flat = move_toward(_flat, fw, delta * 4.0)
	# Which edges face the camera (the dimension lines go there).
	var cam := get_viewport().get_camera_3d()
	var side := Vector2(1, 1)
	if cam != null:
		var cl := gx.affine_inverse() * cam.global_position
		side = Vector2(1.0 if cl.x >= 0.0 else -1.0, 1.0 if cl.z >= 0.0 else -1.0)
	var body: Node3D = Game.dominant_body(o)
	var m := _proj_mat
	m.set_shader_parameter("col", _col)
	m.set_shader_parameter("ext", ext)
	m.set_shader_parameter("half_h", half_h)
	m.set_shader_parameter("rmin", rmin)
	m.set_shader_parameter("rmax", rmax)
	m.set_shader_parameter("rot", rot_eff)
	m.set_shader_parameter("clear_r", clear_r)
	m.set_shader_parameter("grid_r", grid_r)
	m.set_shader_parameter("grid_o", body.global_position if body != null else Vector3.ZERO)
	m.set_shader_parameter("up_w", _up)
	m.set_shader_parameter("fade", _proj_on)
	m.set_shader_parameter("gizmo", _giz)
	m.set_shader_parameter("giz_r", giz_r)
	m.set_shader_parameter("giz_from", _giz_from)
	m.set_shader_parameter("scan", _scan)
	m.set_shader_parameter("alert", _alert)
	m.set_shader_parameter("flat_warn", _flat)
	m.set_shader_parameter("dim_side", side)
	m.set_shader_parameter("blocked", 1.0 if _state == 2 else 0.0)
	# Labels: the two dimensions on their lines, the angle at the gizmo pointer.
	var la := _proj_on * (0.55 if resting else 1.0)
	var lc := Color(_col.r * 0.4 + 0.6, _col.g * 0.4 + 0.6, _col.b * 0.4 + 0.6, la)
	var zl := (rmax.y if side.y > 0.0 else rmin.y) + side.y * 0.6
	var xl := (rmax.x if side.x > 0.0 else rmin.x) + side.x * 0.6
	if absf(rmax.x - rmin.x - _lw) > 0.01 or absf(rmax.y - rmin.y - _ld) > 0.01:
		_lw = rmax.x - rmin.x
		_ld = rmax.y - rmin.y
		_lbl_w.text = "%.1f m" % _lw
		_lbl_d.text = "%.1f m" % _ld
	_lbl_w.global_position = gx * Vector3((rmin.x + rmax.x) * 0.5, 0.18, zl)
	_lbl_w.modulate = lc
	_lbl_w.visible = la > 0.02
	_lbl_d.global_position = gx * Vector3(xl, 0.18, (rmin.y + rmax.y) * 0.5)
	_lbl_d.modulate = lc
	_lbl_d.visible = la > 0.02
	_lbl_ang.visible = _giz > 0.02
	if _lbl_ang.visible:
		var deg := int(fposmod(roundf(rad_to_deg(rot_eff)), 360.0))
		if deg != _la:
			_la = deg
			_lbl_ang.text = "%d°" % deg
		_lbl_ang.global_position = gx * Vector3(0.0, 0.3, -(giz_r + 0.95))
		_lbl_ang.modulate = Color(1.0, 0.97, 0.92, _giz)


## The scan beam from the tool's emitter to the ghost and the projection fan to its corners.
func _tick_beam(g: Dictionary) -> void:
	var tip: Node3D = null
	if tool != null and tool.get("emitter") is Dictionary:
		var em: Dictionary = tool.emitter
		if em.has("tip") and is_instance_valid(em["tip"]):
			tip = em["tip"]
	var cam := get_viewport().get_camera_3d()
	var on := tip != null and tip.is_inside_tree() and cam != null
	for b in _beams:
		(b[0] as Node3D).visible = on
	_fan.visible = on and _collapse < 0.0
	if not on:
		return
	var p0 := VM.vm_to_world(cam, tip.global_position)
	var h := float(g["height"])
	var p2 := _xf.origin + _up * minf(h * 0.35, 1.2)
	var feeding := 0.0
	if _collapse >= 0.0:
		# After a build the beam feeds the print: it follows the fabrication front up the structure.
		var front := clampf((_collapse - BuildFx.RISE) / 1.6, 0.0, 1.0)
		p2 = _collapse_xf.origin + _collapse_xf.basis.y.normalized() * h * (0.1 + 0.85 * front)
		feeding = 1.0 - smoothstep(1.5, REST_MAX, _collapse)
	var p1 := (p0 + p2) * 0.5 + _up * p0.distance_to(p2) * 0.08
	var flick := 0.9 + 0.1 * sin(_t * 23.0) + 0.15 * feeding * sin(_t * 61.0)
	var bc := VALID_COL if _collapse >= 0.0 else _col
	for b in _beams:
		var m := b[1] as ShaderMaterial
		m.set_shader_parameter("p0", p0)
		m.set_shader_parameter("p1", p1)
		m.set_shader_parameter("p2", p2)
		m.set_shader_parameter("color", bc.lerp(Color(1.0, 0.97, 0.92), _pulse * 0.6))
		m.set_shader_parameter("intensity", float(b[2]) * flick * (1.0 + 2.0 * _pulse + 0.7 * feeding))
	if not _fan.visible:
		return
	var bb: AABB = g["aabb"]
	var gx := Transform3D(_xf.basis.orthonormalized(), _xf.origin)
	_fan_mat.set_shader_parameter("apex", p0)
	_fan_mat.set_shader_parameter("c0", gx * Vector3(bb.position.x, 0.05, bb.position.z))
	_fan_mat.set_shader_parameter("c1", gx * Vector3(bb.end.x, 0.05, bb.position.z))
	_fan_mat.set_shader_parameter("c2", gx * Vector3(bb.end.x, 0.05, bb.end.z))
	_fan_mat.set_shader_parameter("c3", gx * Vector3(bb.position.x, 0.05, bb.end.z))
	_fan_mat.set_shader_parameter("col", _col)
	_fan_mat.set_shader_parameter("k", _proj_on * _appear)


## Guns: the default shot (45°, middle charge) toward the other planet as a dashed glowing ribbon
## with a pulsing impact ring where it lands.
func _tick_arc(delta: float) -> void:
	var gun := _kind == "cannon" or _kind == "buster"
	if not gun or _state != 0 or Game.rival == null or _collapse >= 0.0:
		_arc.visible = false
		_impact.visible = false
		return
	var at := float(tool.get("_arc_t")) if tool != null and tool.get("_arc_t") != null else 0.0
	at -= delta
	if at <= 0.0 or _arc_pts.is_empty():
		at = ARC_PERIOD
		var from: Vector3 = _xf.origin + _up * 2.6
		var spd := lerpf(Balance.CANNON_SPEED_MIN, Balance.CANNON_SPEED_MAX, 0.55)
		var v := Ballistics.launch_vector(from, (Game.rival as Node3D).global_position, spd, 45.0)
		var tr := Ballistics.trace(from, v, Balance.SHELL_LIFE, 0.1)
		_arc_pts = tr.get("points", PackedVector3Array())
		_arc_hit = tr.get("position", Vector3.INF)
		_arc_im.clear_surfaces()
		var total := 0.0
		for i in range(1, _arc_pts.size()):
			total += _arc_pts[i - 1].distance_to(_arc_pts[i])
		if _arc_pts.size() >= 2:
			_arc_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
			_ribbon(_arc_im, _arc_pts, 0.95, 0.55)
			_arc_im.surface_end()
		_arc_mat.set_shader_parameter("total", maxf(total, 1.0))
	if tool != null:
		tool.set("_arc_t", at)
	_arc.visible = _arc_pts.size() >= 2
	_arc_mat.set_shader_parameter("col", _col)
	_arc_mat.set_shader_parameter("k", _proj_on)
	if _arc_hit == Vector3.INF:
		_impact.visible = false
		return
	var b: Node3D = Game.dominant_body(_arc_hit)
	var u: Vector3 = (_arc_hit - b.global_position).normalized() if b != null else _up
	BuildFx.zone_place(_impact, BuildFx.basis_up(u), _arc_hit, Vector3(6.5, 4.0, 6.5), 1, 5.0, _col, 0.9 * _proj_on)


## Structures in the way glow red (keep-out discs); "too close to you" marks the player's feet.
func _tick_blockers(delta: float) -> void:
	_blk_t -= delta
	if _blk_t <= 0.0:
		_blk_t = 0.12
		_blockers.clear()
		if _reason.contains("yapı"):
			var r := float(_e.get("radius", 3.0))
			for s in get_tree().get_nodes_in_group("war_structure"):
				if not (s is Node3D) or _blockers.size() >= 5:
					continue
				var sr := float(s.get_meta("footprint_r", 3.0))
				if (s as Node3D).global_position.distance_to(_xf.origin) < r + sr:
					_blockers.append(s)
	var used := 0
	var k := 0.6 + 0.4 * _alert
	var list: Array = _blockers
	if _extra_blk_t > 0.0 and not _extra_blk.is_empty():
		list = _extra_blk                       # the placement code knows exactly what is in the way
	for s in list:
		if used >= _zones.size():
			break
		if not is_instance_valid(s) or not (s is Node3D):
			continue
		var n := s as Node3D
		var sr := float(n.get_meta("footprint_r", 3.0)) if n.has_meta("footprint_r") else 3.0
		var b: Node3D = Game.dominant_body(n.global_position)
		var u: Vector3 = (n.global_position - b.global_position).normalized() if b != null else _up
		BuildFx.zone_place(_zones[used], BuildFx.basis_up(u), n.global_position, Vector3(sr + 0.6, 3.0, sr + 0.6), 0, sr,
				BLOCK_COL, k)
		used += 1
	if used < _zones.size() and _reason.contains("yakınsın") and tool != null and tool.player != null:
		var pp: Vector3 = (tool.player as Node3D).global_position
		BuildFx.zone_place(_zones[used], BuildFx.basis_up(_up), pp, Vector3(1.4, 2.0, 1.4), 0, 0.8, BLOCK_COL, k)
		used += 1
	for i in range(used, _zones.size()):
		(_zones[i] as Node3D).visible = false


## Snap guides, free snap points, the headroom box (rebuilt only when they change).
func _tick_base_api() -> void:
	var guides := _snap_t > 0.0 and not _snap_pairs.is_empty()
	var points := _snap_pts_t > 0.0 and not _snap_pts.is_empty()
	var head := _head_t > 0.0
	# Lines: rebuild when the inputs change (a cheap key of rounded numbers).
	var key := ""
	var segs := PackedVector3Array()
	if guides:
		for p in _snap_pairs:
			if p is Array and (p as Array).size() >= 2 and p[0] is Vector3 and p[1] is Vector3:
				var a: Vector3 = p[0]
				var b: Vector3 = p[1]
				key += "%s%s" % [a.snapped(Vector3.ONE * 0.005), b.snapped(Vector3.ONE * 0.005)]
				if a.distance_to(b) > 0.02:
					segs.append(a)
					segs.append(b)
	if head:
		key += "H%s%s%s" % [_head_xf.origin.snapped(Vector3.ONE * 0.005), _head_xf.basis.y.snapped(Vector3.ONE * 0.01), _head_bb]
		var c := _box_corners(_head_xf, _head_bb)
		for e in [0, 1, 1, 3, 3, 2, 2, 0, 4, 5, 5, 7, 7, 6, 6, 4, 0, 4, 1, 5, 2, 6, 3, 7]:
			segs.append(c[e])
	if key != _lines_key:
		_lines_key = key
		_lines_im.clear_surfaces()
		if segs.size() >= 2:
			_lines_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
			var seg := PackedVector3Array()
			seg.resize(2)
			for i in range(0, segs.size() - 1, 2):
				seg[0] = segs[i]
				seg[1] = segs[i + 1]
				_ribbon(_lines_im, seg, 1.0, 0.9)
			_lines_im.surface_end()
	_lines.visible = key != "" and segs.size() >= 2
	_lines_mat.set_shader_parameter("col", VALID_COL if (not head or _head_ok) else (BLOCK_COL if _state == 2 else FIX_COL))
	_lines_mat.set_shader_parameter("total", 1000.0)
	# Dots.
	var n := 0
	if points:
		for p in _snap_pts:
			if n >= MAX_DOTS:
				break
			_mm.set_instance_transform(n, Transform3D(Basis.IDENTITY, p))
			_mm.set_instance_custom_data(n, Color(0.0, float(n) * 0.13, 0.12, 0.0))
			n += 1
	if guides:
		for p in _snap_pairs:
			if n + 2 > MAX_DOTS or not (p is Array) or (p as Array).size() < 2 or not (p[0] is Vector3) or not (p[1] is Vector3):
				continue
			var a: Vector3 = p[0]
			var b: Vector3 = p[1]
			var locked := a.distance_to(b) < 0.05
			_mm.set_instance_transform(n, Transform3D(Basis.IDENTITY, b))
			_mm.set_instance_custom_data(n, Color(2.0 if locked else 1.0, 0.0, 0.3 if locked else 0.24, 0.0))
			n += 1
			if not locked:
				_mm.set_instance_transform(n, Transform3D(Basis.IDENTITY, a))
				_mm.set_instance_custom_data(n, Color(1.0, 0.5, 0.16, 0.0))
				n += 1
	_mm.visible_instance_count = n
	_dots.visible = n > 0
	_dots_mat.set_shader_parameter("col", VALID_COL)
	# Headroom: the soil inside the clear volume (not its floor) hatched; the height read-out.
	if head:
		var hc := _head_bb.get_center()
		var hb := _head_xf.basis.orthonormalized()
		var ok_col := VALID_COL if _head_ok else (BLOCK_COL if _state == 2 else FIX_COL)
		BuildFx.zone_place(_head_zone, hb, _head_xf * hc, _head_bb.size * 0.5 + Vector3(0.05, 0.05, 0.05), 2, 1.0,
				ok_col, 0.35 if _head_ok else 1.0)
		_lbl_head.text = "Tavan %.1f m" % _head_bb.size.y
		_lbl_head.global_position = _head_xf * Vector3(_head_bb.end.x + 0.3, hc.y, hc.z)
		_lbl_head.modulate = Color(ok_col.r * 0.4 + 0.6, ok_col.g * 0.4 + 0.6, ok_col.b * 0.4 + 0.6, 1.0)
		_lbl_head.visible = true
	else:
		_head_zone.visible = false
		_lbl_head.visible = false


static func _box_corners(xf: Transform3D, bb: AABB) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in 8:
		var p := Vector3(bb.end.x if (i & 1) != 0 else bb.position.x, bb.end.y if (i & 4) != 0 else bb.position.y,
				bb.end.z if (i & 2) != 0 else bb.position.z)
		out.append(xf * p)
	return out


## Appends a camera-facing ribbon along `pts` (RIBBON_SHADER: NORMAL = tangent, UV = (m, side),
## COLOR.a from a0 to a1) to the open PRIMITIVE_TRIANGLES surface of `im`.
static func _ribbon(im: ImmediateMesh, pts: PackedVector3Array, a0: float, a1: float) -> void:
	var n := pts.size()
	if n < 2:
		return
	var s0 := 0.0
	for i in n - 1:
		var pa := pts[i]
		var pb := pts[i + 1]
		var ta := pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]
		var tb := pts[mini(i + 2, n - 1)] - pts[i]
		ta = ta.normalized() if ta.length_squared() > 1e-10 else Vector3.UP
		tb = tb.normalized() if tb.length_squared() > 1e-10 else ta
		var s1 := s0 + pa.distance_to(pb)
		var ca := Color(1, 1, 1, lerpf(a0, a1, float(i) / float(n - 1)))
		var cb := Color(1, 1, 1, lerpf(a0, a1, float(i + 1) / float(n - 1)))
		_rv(im, pa, ta, s0, -1.0, ca)
		_rv(im, pa, ta, s0, 1.0, ca)
		_rv(im, pb, tb, s1, 1.0, cb)
		_rv(im, pa, ta, s0, -1.0, ca)
		_rv(im, pb, tb, s1, 1.0, cb)
		_rv(im, pb, tb, s1, -1.0, cb)
		s0 = s1


static func _rv(im: ImmediateMesh, p: Vector3, tng: Vector3, s: float, side: float, c: Color) -> void:
	im.surface_set_normal(tng)
	im.surface_set_uv(Vector2(s, side))
	im.surface_set_color(c)
	im.surface_add_vertex(p)


## The tool's emitter on the view model: gimbal rings precess, the lens and the light cone breathe in
## the validity colour (dim while there is no ghost), the tool's screen follows.
func _emitter_tick(on: bool) -> void:
	if tool == null or not (tool.get("emitter") is Dictionary):
		return
	var em: Dictionary = tool.emitter
	if em.is_empty() or not em.has("r1") or not is_instance_valid(em["r1"]):
		return
	var c: Color = _col if on else Color(0.5, 0.8, 0.95)
	var lvl := 1.0 if on else 0.35
	var rb: Basis = em["ring_b"]
	var rc: Vector3 = em["ring_c"]
	(em["r1"] as Node3D).transform = Transform3D(rb * Basis(Vector3.UP, _t * 2.6) * Basis(Vector3.RIGHT, 0.42), rc)
	(em["r2"] as Node3D).transform = Transform3D(rb * Basis(Vector3.UP, -_t * 3.4) * Basis(Vector3.FORWARD, 0.55), rc)
	var lens := em["lens"] as ShaderMaterial
	lens.set_shader_parameter("color", c)
	lens.set_shader_parameter("energy", (2.0 + 0.5 * sin(_t * 6.0) + 3.0 * _pulse) * lvl)
	var rm := em["ring_mat"] as ShaderMaterial
	rm.set_shader_parameter("color", c)
	rm.set_shader_parameter("energy", (1.6 + 2.0 * _pulse) * lvl)
	var cm := em["cone_mat"] as ShaderMaterial
	cm.set_shader_parameter("col", c)
	cm.set_shader_parameter("energy", (0.75 + 0.25 * sin(_t * 9.0) + 1.5 * _pulse) * (1.0 if on else 0.2))
	var scr = tool.get("_screen")
	if scr is ShaderMaterial:
		(scr as ShaderMaterial).set_shader_parameter("color", c)
