extends RefCounted
## Shaders of the Mekik (scripts/craft/skiff.gd), kept as code so scripts/craft is self-contained:
##   HULL  painted hull, cabin trim, seats, legs: every look comes from vertex data (skiff_build.gd)
##   GLASS the bubble canopy (fresnel rim, smudges, dust along the sill, cracks with hull damage)
##   EMIT  LEDs, nav lights, the strobe, nozzle glow (vertex colour + mode, driven by uniforms)
## Colours stay inside the tone curve on purpose: the darkest paint is a graphite around 0.18 sRGB
## and nothing emissive goes far past the glow threshold (no crushed blacks, no blown whites).

const HULL := """
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;
// Vertex data (skiff_build.gd):
//   COLOR.rgb albedo (sRGB), COLOR.a roughness
//   UV        surface coordinates in metres
//   UV2.x     pattern: > 0 panel plating (panel size in m), 0 plain, -1 hazard stripes, -2 tread
//             plate, -3 quilted padding, -4 rubber, -5 nozzle metal (UV.y 0 throat .. 1 lip),
//             -6 vent slots, -7 heat tiles, -8 brushed metal
//   UV2.y     metallic (kept low: the sky gives no reflections, bare metal would turn black)

uniform float grime = 0.12;
uniform float wear = 0.6;
uniform float soot = 0.0;          // battle damage (1 - hp / hp_max)
uniform float scorch = 0.0;        // wreck
uniform float ember = 0.0;         // wreck: glowing cracks that cool down
uniform float ambient_k = 1.0;     // cabin: share of the sky light that reaches inside
uniform float seam_w = 0.0045;

varying vec3 lp;

float hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float hash3(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x),
			mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x),
			mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

vec3 lin(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(2.2));
}

void vertex() {
	lp = VERTEX;
}

void fragment() {
	vec3 base = lin(COLOR.rgb);
	float r = COLOR.a;
	float metal = UV2.y;
	float pat = UV2.x;
	vec2 uv = UV;
	vec3 col = base;
	float cc = 0.0;
	// Screen-space footprint: fine detail fades out with distance instead of shimmering.
	float fw = max(length(fwidth(uv)), 1e-4);
	float fade = 1.0 - smoothstep(0.012, 0.06, fw);
	float aa = max(fw * 0.75, 0.0012);

	if (pat > 0.05) {
		// Panel plating: panels a bit longer around the hull than along it, some split in two; a
		// dark seam with a light bevel beside it, a faint per-panel tint, rivet rows on big panels.
		vec2 sz = vec2(pat * 1.25, pat);
		vec2 g = uv / sz;
		vec2 cell = floor(g);
		vec2 f = fract(g);
		float rnd = hash2(cell + 11.0);
		if (rnd > 0.62) {
			if (rnd > 0.81) { f.x = fract(f.x * 2.0); sz.x *= 0.5; cell.x += 0.5 * floor(fract(g.x) * 2.0); }
			else { f.y = fract(f.y * 2.0); sz.y *= 0.5; cell.y += 0.5 * floor(fract(g.y) * 2.0); }
		}
		float rnd2 = hash2(cell * 1.37 + 3.1);
		vec2 ed = min(f, 1.0 - f) * sz;
		float e = min(ed.x, ed.y);
		float line = 1.0 - smoothstep(seam_w - aa, seam_w + aa, e);
		float bev = smoothstep(seam_w, seam_w * 2.0, e) * (1.0 - smoothstep(seam_w * 2.0, seam_w * 5.0, e));
		col *= 0.955 + rnd2 * 0.09;
		if (rnd2 > 0.93) col *= 0.87;                        // a replaced access panel
		col *= 1.0 + bev * 0.07 * fade;
		if (pat > 0.3) {
			vec2 q = (fract(uv / 0.055) - 0.5) * 0.055;
			float d1 = length(vec2(q.x, ed.y - 0.02));
			float d2 = length(vec2(q.y, ed.x - 0.02));
			float rv = 1.0 - smoothstep(0.003, 0.005 + aa, min(d1, d2));
			col *= 1.0 - rv * 0.2 * fade;
		}
		col = mix(col, col * 0.4, line * fade);
		r = clamp(r + (rnd2 - 0.5) * 0.08 + line * 0.25 * fade, 0.05, 1.0);
		cc = 0.25 * (1.0 - metal);
	} else if (pat < -0.5 && pat > -1.5) {
		// Hazard stripes (the vertex colour is the light stripe).
		float s = step(0.5, fract((uv.x + uv.y) * 3.2));
		col = mix(lin(vec3(0.16, 0.16, 0.17)), base, s);
		r = clamp(r + (1.0 - s) * 0.1, 0.0, 1.0);
	} else if (pat < -1.5 && pat > -2.5) {
		// Diamond tread plate.
		vec2 q = uv * 9.0;
		vec2 c1 = fract(q) - 0.5;
		vec2 c2 = fract(q + 0.5) - 0.5;
		float d1 = abs(c1.x * 2.2 + c1.y * 0.7) + abs(c1.y * 2.2 - c1.x * 0.7);
		float d2 = abs(c2.x * 0.7 - c2.y * 2.2) + abs(c2.y * 0.7 + c2.x * 2.2);
		float bump = max(1.0 - smoothstep(0.25, 0.35, d1), 1.0 - smoothstep(0.25, 0.35, d2)) * fade;
		col *= 0.88 + bump * 0.24;
		r = clamp(r - bump * 0.18, 0.0, 1.0);
	} else if (pat < -2.5 && pat > -3.5) {
		// Quilted padding: diamond stitches, puffed cells.
		vec2 q = uv * 6.0;
		vec2 d = abs(fract(vec2(q.x + q.y, q.x - q.y) * 0.7071) - 0.5);
		float st = (1.0 - smoothstep(0.0, 0.07, min(d.x, d.y))) * fade;
		float puff = clamp(0.5 + 2.0 * min(d.x, d.y), 0.0, 1.0);
		col *= mix(0.8, 1.04, puff);
		col = mix(col, col * 0.62, st * 0.6);
		r = 0.86;
		metal = 0.0;
	} else if (pat < -3.5 && pat > -4.5) {
		// Rubber (footpads, seals): fine ribs, matte.
		col *= 0.9 + 0.1 * step(0.5, fract(uv.x * 16.0)) * fade + 0.08 * (vnoise(lp * 23.0) - 0.5);
		r = 0.88;
		metal = 0.0;
	} else if (pat < -4.5 && pat > -5.5) {
		// Nozzle metal: heat temper and soot toward the throat (UV.y 0), clean toward the lip.
		float t = clamp(uv.y, 0.0, 1.0);
		vec3 temper = mix(lin(vec3(0.36, 0.30, 0.27)), lin(vec3(0.42, 0.42, 0.48)), t);
		col = mix(col, temper, 0.55 * (1.0 - t));
		col *= mix(0.62, 1.0, smoothstep(0.0, 0.6, t));
		r = mix(0.62, r, t);
	} else if (pat < -5.5 && pat > -6.5) {
		// Vent slots.
		float s = fract(uv.y * 14.0);
		float slot = smoothstep(0.25, 0.32, s) * (1.0 - smoothstep(0.68, 0.75, s));
		col = mix(col, col * 0.25, slot * fade);
		r = mix(r, 0.85, slot);
	} else if (pat < -6.5 && pat > -7.5) {
		// Heat tiles on the belly: a grid of small ceramic tiles, each its own shade.
		vec2 g = uv / 0.15;
		vec2 cell = floor(g);
		vec2 f = fract(g);
		float e = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)) * 0.15;
		float gap = 1.0 - smoothstep(0.003 - aa, 0.003 + aa, e);
		float t = hash2(cell + 5.0);
		col *= 0.86 + t * 0.2;
		col = mix(col, col * 0.45, gap * fade);
		r = 0.72 + t * 0.12;
		metal = 0.0;
	} else if (pat < -7.5 && pat > -8.5) {
		// Brushed metal: streaks along U.
		col *= 0.93 + 0.08 * vnoise(vec3(uv.x * 3.0, uv.y * 140.0, 0.0)) * fade;
	}

	// Large-scale weathering: soft grime, a little streaking down the sides.
	float n_big = vnoise(lp * 0.9);
	float streak = vnoise(vec3(lp.x * 3.0, lp.y * 0.45, lp.z * 3.0));
	float gk = grime * (pat > 0.05 ? 1.0 : 0.6);
	col *= 1.0 - gk * (n_big * 0.5 + streak * 0.5) * 0.55;
	r = clamp(r + gk * n_big * 0.15, 0.0, 1.0);
	// Chipped paint on the painted surfaces: small chips show the light primer.
	if (wear > 0.0 && metal < 0.3 && pat >= 0.0) {
		float chip = smoothstep(0.80, 0.86, vnoise(lp * 13.0) * 0.6 + vnoise(lp * 41.0) * 0.4);
		chip *= (1.0 - smoothstep(0.004, 0.012, fw)) * wear;
		col = mix(col, lin(vec3(0.56, 0.57, 0.58)), chip * 0.65);
		r = mix(r, 0.42, chip);
	}
	// Battle damage: soot patches that spread as the hull loses health.
	if (soot > 0.01) {
		float m = smoothstep(0.62 - soot * 0.42, 0.78 - soot * 0.42, vnoise(lp * 1.7) * 0.7 + vnoise(lp * 6.3) * 0.3);
		m *= soot;
		col = mix(col, lin(vec3(0.14, 0.13, 0.12)), m * 0.8);
		r = mix(r, 0.9, m);
		cc *= 1.0 - m;
	}
	if (scorch > 0.01) {
		float st2 = vnoise(lp * 2.2) * 0.6 + vnoise(lp * 9.0) * 0.4;
		col = mix(col, lin(vec3(0.15, 0.13, 0.12)) * (0.8 + 0.4 * st2), scorch * 0.85);
		r = mix(r, 0.92, scorch);
		cc = 0.0;
		metal *= 1.0 - scorch;
	}
	ALBEDO = col;
	METALLIC = metal;
	ROUGHNESS = r;
	CLEARCOAT = cc;
	CLEARCOAT_ROUGHNESS = 0.3;
	if (ambient_k < 0.999) {
		AO = ambient_k;
		AO_LIGHT_AFFECT = 0.0;
	}
	if (ember > 0.01) {
		float crack = smoothstep(0.78, 0.9, vnoise(lp * 4.0 + vec3(0.0, TIME * 0.15, 0.0)));
		EMISSION = vec3(1.0, 0.36, 0.08) * crack * ember * 2.2;
	}
}
"""

const GLASS := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, diffuse_burley, specular_schlick_ggx, shadows_disabled;
// Bubble canopy. UV.y: 0 at the sill .. 1 at the top (dust settles along the sill).

uniform vec3 tint : source_color = vec3(0.62, 0.72, 0.78);
uniform float base_alpha = 0.045;
uniform float damage = 0.0;

varying vec3 lp;

float hash3(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x),
			mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x),
			mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	lp = VERTEX;
}

void fragment() {
	float nv = clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0);
	float fres = pow(1.0 - nv, 4.0);
	float h = clamp(UV.y, 0.0, 1.0);
	float smudge = smoothstep(0.62, 0.92, vnoise(lp * 2.3) * 0.55 + vnoise(lp * 9.0) * 0.45);
	float dust = (1.0 - smoothstep(0.0, 0.3, h)) * (0.35 + 0.65 * vnoise(lp * 5.0));
	float crk = 0.0;
	if (damage > 0.25) {
		float n = vnoise(lp * 6.5) * 0.7 + vnoise(lp * 19.0) * 0.3;
		crk = (1.0 - smoothstep(0.0, 0.012, abs(n - 0.5))) * smoothstep(0.25, 0.8, damage) * step(0.5, vnoise(lp * 1.3 + 4.0));
	}
	ALBEDO = tint * 0.32 + vec3(0.3) * (smudge * 0.25 + dust * 0.4 + crk * 0.8);
	ROUGHNESS = 0.05 + smudge * 0.22 + dust * 0.35;
	METALLIC = 0.0;
	SPECULAR = 0.6;
	ALPHA = clamp(base_alpha + fres * 0.4 + smudge * 0.03 + dust * 0.09 + crk * 0.55, 0.0, 0.8);
}
"""

const EMIT := """
shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled, fog_disabled;
// Emissive bits. COLOR.rgb colour (sRGB), COLOR.a intensity; UV2.x mode, UV2.y phase:
//   0 steady panel light (power), 1 slow pulse (power), 2 strobe (always when lights are on),
//   3 nav light (lights), 4 parked blink (only while powered down), 5 main nozzle glow (engine),
//   6 lift nozzle glow (vtol), 7 landing light lens (lights), 8 warning (warn)

uniform float energy = 2.0;
uniform float power = 0.0;
uniform float lights = 0.0;
uniform float engine = 0.0;
uniform float boost = 0.0;
uniform float vtol = 0.0;
uniform float warn = 0.0;

vec3 lin(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(2.2));
}

void fragment() {
	float mode = UV2.x;
	float ph = UV2.y;
	vec3 col = lin(COLOR.rgb);
	float k = 1.0;
	if (mode < 0.5) {
		k = power;
	} else if (mode < 1.5) {
		k = power * (0.55 + 0.45 * (0.5 + 0.5 * sin(TIME * 2.4 + ph * 6.2832)));
	} else if (mode < 2.5) {
		float t = fract(TIME * 0.75 + ph);
		k = lights * (0.03 + 1.6 * (step(t, 0.04) + step(0.12, t) * step(t, 0.15)));
	} else if (mode < 3.5) {
		k = 0.08 + 0.92 * lights;
	} else if (mode < 4.5) {
		k = (1.0 - power) * step(0.88, fract(TIME * 0.5 + ph)) * 0.9;
	} else if (mode < 5.5) {
		float e = clamp(engine, 0.0, 1.4);
		col = mix(lin(vec3(1.0, 0.48, 0.2)), mix(col, lin(vec3(0.85, 0.94, 1.0)), boost * 0.6), smoothstep(0.05, 0.5, e));
		k = 0.05 * power + e * 0.8 + boost * 0.4;
	} else if (mode < 6.5) {
		float e = clamp(vtol, 0.0, 1.2);
		col = mix(lin(vec3(1.0, 0.5, 0.22)), col, smoothstep(0.05, 0.5, e));
		k = 0.04 * power + e * 0.85;
	} else if (mode < 7.5) {
		k = 0.05 + lights;
	} else {
		k = warn * (0.4 + 0.6 * step(0.5, fract(TIME * 2.0)));
	}
	// Unshaded: the albedo is the output (HDR above 1 feeds the glow); a dark lens when off.
	ALBEDO = col * 0.06 + col * COLOR.a * k * energy;
}
"""

static var _shaders := {}


static func shader(key: String) -> Shader:
	if _shaders.has(key):
		return _shaders[key]
	var s := Shader.new()
	match key:
		"hull":
			s.code = HULL
		"glass":
			s.code = GLASS
		_:
			s.code = EMIT
	_shaders[key] = s
	return s
