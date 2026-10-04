shader_type spatial;
// Planet ground, colors per body preset (scripts/planet/bodies.gd).
//   UV   = (pool mask, crack mask)
//   UV2  = (depth below the original surface, mare mask)
//   COLOR.r = exposed underground (dug or cave).
// Dug walls show strata by depth; deep down (toward the core) the rock warms to core_color with a
// faint glow, so a tunnel to the centre reads as getting closer.

uniform vec3 planet_center = vec3(0.0);
uniform float planet_radius = 300.0;
uniform vec3 col_low : source_color = vec3(0.5);
uniform vec3 col_high : source_color = vec3(0.6);
uniform vec3 col_rock : source_color = vec3(0.4);
uniform vec3 col_dust : source_color = vec3(0.7);
uniform vec3 col_mare : source_color = vec3(0.3);
uniform vec3 col_pool : source_color = vec3(0.5);
uniform vec3 col_crack : source_color = vec3(0.2);
uniform vec3 strata_top : source_color = vec3(0.5);
uniform vec3 strata_mid : source_color = vec3(0.4);
uniform vec3 strata_deep : source_color = vec3(0.3);
uniform float pool_emission = 0.0;
uniform float crack_emission = 0.0;
uniform float pool_gloss = 0.0;
uniform float height_range = 40.0;
uniform vec3 core_color : source_color = vec3(0.85, 0.42, 0.16);
uniform float core_glow = 0.35;          // emission of the deepest rock (kept low: no blown whites)
// Close-range material detail (TerrainTextures: 0 soil -> regolith, 1 rock), triplanar.
uniform sampler2DArray detail_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_on = 0.0;
uniform float detail_flat_layer = 0.0;   // layer for open ground: 0 regolith, 3 snow (ice moon)
const float DETAIL_TILE = 2.0;     // TerrainTextures.TILE_M
const float DETAIL_GRAD = 2.5;     // TerrainTextures.GRAD_RANGE

varying vec3 body_pos;     // relative to the body centre (planet_center): textures stay put when the floating origin moves the world
varying vec3 world_normal;
varying float disturbed;
varying vec2 masks;
varying float depth;
varying float mare;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
			mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
			mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

// Triplanar sample of one detail layer (same as terrain.gdshader).
void detail_tri(vec3 p, vec3 bw, float layer, float k, vec3 dpx, vec3 dpy, inout vec2 la, inout vec3 g) {
	float s = 1.0 / DETAIL_TILE;
	vec4 sx = textureGrad(detail_tex, vec3(p.zy * s, layer), dpx.zy * s, dpy.zy * s);
	vec4 sy = textureGrad(detail_tex, vec3(p.xz * s, layer), dpx.xz * s, dpy.xz * s);
	vec4 sz = textureGrad(detail_tex, vec3(p.xy * s, layer), dpx.xy * s, dpy.xy * s);
	la += (sx.ra * bw.x + sy.ra * bw.y + sz.ra * bw.z) * k;
	vec2 gx = (sx.gb * 2.0 - 1.0) * DETAIL_GRAD;
	vec2 gy = (sy.gb * 2.0 - 1.0) * DETAIL_GRAD;
	vec2 gz = (sz.gb * 2.0 - 1.0) * DETAIL_GRAD;
	g += (vec3(0.0, gx.y, gx.x) * bw.x + vec3(gy.x, 0.0, gy.y) * bw.y + vec3(gz.x, gz.y, 0.0) * bw.z) * k;
}

void vertex() {
	body_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - planet_center;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	disturbed = COLOR.r;
	masks = UV;
	depth = UV2.x;
	mare = UV2.y;
}

void fragment() {
	vec3 rel = body_pos;
	vec3 up = normalize(rel);
	float h = length(rel) - planet_radius;
	float slope = dot(normalize(world_normal), up);
	float n = vnoise(body_pos * 0.13) * 0.6 + vnoise(body_pos * 0.6) * 0.4;
	float big = vnoise(body_pos * 0.015);
	float fine = vnoise(body_pos * 2.2);

	// Height gradient, dust drifts on flat ground, maria, rock on slopes.
	vec3 col = mix(col_low, col_high, smoothstep(-0.2, 1.0, h / height_range + (n - 0.5) * 0.25));
	col *= 0.9 + 0.2 * n;
	float dust = smoothstep(0.55, 0.75, big + n * 0.2) * smoothstep(0.85, 0.97, slope);
	col = mix(col, col_dust, dust * 0.7);
	col = mix(col, col_mare * (0.9 + 0.2 * n), clamp(mare, 0.0, 1.0));
	float band = fract(h / 4.1 + vnoise(body_pos * 0.07) * 0.4);
	vec3 rock = col_rock * (0.8 + 0.35 * n) * (0.9 + 0.15 * smoothstep(0.4, 0.5, band));
	float rock_w = 1.0 - smoothstep(0.62, 0.78, slope + (n - 0.5) * 0.08);
	col = mix(col, rock, rock_w);
	// Bright fresh crater rims / ejecta speckle.
	col *= 0.94 + 0.12 * smoothstep(0.7, 0.9, fine);

	// Pools (lava lakes / frozen lakes) and cracks (lava cracks / crevasses / crystal veins).
	float pool = clamp(masks.x, 0.0, 1.0);
	float crack = clamp(masks.y, 0.0, 1.0);
	float flow = vnoise(body_pos * 0.25 + vec3(TIME * 0.12, 0.0, TIME * 0.07));
	vec3 pool_c = col_pool * (0.75 + 0.5 * flow);
	vec3 crack_c = col_crack * (0.8 + 0.4 * fine);
	col = mix(col, pool_c, pool);
	col = mix(col, crack_c, crack * (1.0 - pool));
	vec3 emit = col_pool * pool_emission * pool * (0.55 + 0.9 * flow)
			+ col_crack * crack_emission * crack * (1.0 - pool) * (0.6 + 0.6 * flow);

	// Underground strata (dug walls and caves).
	float under = clamp(disturbed, 0.0, 1.0);
	float dd = depth + (vnoise(body_pos * 0.07) - 0.5) * 2.6;
	vec3 st = mix(strata_top, strata_mid, smoothstep(2.5, 3.5, dd));
	st = mix(st, strata_deep, smoothstep(14.0, 16.0, dd));
	float seam = max(1.0 - smoothstep(0.0, 0.2, abs(dd - 3.0)), 1.0 - smoothstep(0.0, 0.25, abs(dd - 15.0)));
	st *= (1.0 - seam * 0.35) * (0.92 + 0.08 * sin(dd * 2.4 + n * 2.0));
	// Toward the core: warm, faintly glowing rock (from ~45 % of the radius down).
	float core_k = smoothstep(planet_radius * 0.45, planet_radius * 0.85, dd);
	st = mix(st, core_color * (0.8 + 0.3 * n), core_k);
	col = mix(col, st, under);

	// Close-range detail: regolith with scattered stones on open ground, fractured rock on slopes
	// and deep dug walls. Not on pools / cracks. Colors here are linear, so the swing is smaller.
	float cam_d = length(VERTEX);      // view space: the camera sits at 0
	// Frozen lakes keep a little relief; lava pools none.
	float pool_k = pool * (pool_emission > 0.0 ? 1.0 : 0.6);
	float dk = detail_on * (1.0 - smoothstep(22.0, 60.0, cam_d)) * (1.0 - pool_k) * (1.0 - crack * 0.7);
	float dk_bump = 1.0 - smoothstep(10.0, 40.0, cam_d);
	vec3 g_det = vec3(0.0);
	vec3 dpx = dFdx(body_pos);
	vec3 dpy = dFdy(body_pos);
	if (dk > 0.001) {
		vec3 nw = normalize(world_normal);
		vec3 bw = pow(abs(nw), vec3(4.0));
		bw /= bw.x + bw.y + bw.z;
		float wr = mix(rock_w, smoothstep(7.0, 10.0, depth), under);
		float wg = 1.0 - wr;
		vec2 la = vec2(0.0);
		float wt = 0.0;
		if (wg > 0.02) {
			detail_tri(body_pos, bw, detail_flat_layer, wg, dpx, dpy, la, g_det);
			wt += wg;
		}
		if (wr > 0.02) {
			detail_tri(body_pos, bw, 1.0, wr, dpx, dpy, la, g_det);
			wt += wr;
		}
		wt = max(wt, 1e-4);
		la /= wt;
		float vary = 0.55 + 0.45 * smoothstep(0.2, 0.8, n);
		col *= mix(1.0, (0.65 + 0.7 * la.x) * mix(1.0, la.y, 0.8), 0.75 * dk * vary);
		g_det *= dk_bump * vary * (1.0 - pool_k) / wt;
	}

	ALBEDO = col;
	if (dot(g_det, g_det) > 1e-8) {
		vec3 nW = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 g = g_det - nW * dot(g_det, nW);
		NORMAL = normalize((VIEW_MATRIX * vec4(normalize(nW - g), 0.0)).xyz);
	}
	ROUGHNESS = 0.92 - pool * pool_gloss * 0.75;
	SPECULAR = 0.25 + pool * pool_gloss * 0.4;
	EMISSION = emit + core_color * core_glow * core_k * under * (0.7 + 0.3 * fine);
	// Tunnel walls: only a mild ambient-occlusion dip (the lighting rule: no crushed blacks).
	AO = mix(1.0, 0.72, smoothstep(2.5, 12.0, depth) * under);
	AO_LIGHT_AFFECT = 0.0;
}
