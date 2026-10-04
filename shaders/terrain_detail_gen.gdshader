shader_type canvas_item;
render_mode blend_disabled;
// Bakes one layer of the terrain detail texture (terrain_textures.gd). Everything is periodic over
// the tile, so the result tiles seamlessly. Output (stored raw, read without source_color):
//   R = albedo luminance factor (0.5 = unchanged)   G, B = height gradient d/du, d/dv (0.5 = flat)
//   A = cavity / AO (1 = open, lower in cracks and pits)
// Layers: 0 soil / grassy ground, 1 rock, 2 sand, 3 snow.

uniform int layer = 0;
uniform float tile_m = 2.0;          // meters covered by one tile (gradient units: meters / meter)
uniform float grad_range = 2.5;      // |gradient| that maps to 0 / 1

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

// Periodic value noise: P lattice cells per tile, x in tile units [0,1).
float pnoise(vec2 x, float P, float seed) {
	vec2 q = x * P;
	vec2 i = floor(q);
	vec2 f = fract(q);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash12(mod(i, P) + seed);
	float b = hash12(mod(i + vec2(1, 0), P) + seed);
	float c = hash12(mod(i + vec2(0, 1), P) + seed);
	float d = hash12(mod(i + vec2(1, 1), P) + seed);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float pfbm(vec2 x, float P, int oct, float gain, float seed) {
	float s = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	for (int o = 0; o < 8; o++) {
		if (o >= oct) break;
		s += pnoise(x, P, seed + float(o) * 17.0) * amp;
		norm += amp;
		P *= 2.0;
		amp *= gain;
	}
	return s / norm;
}

// Periodic Worley: returns (F1, F2, cell id hash) with P cells per tile.
vec3 pworley(vec2 x, float P, float seed, float jitter) {
	vec2 q = x * P;
	vec2 i = floor(q);
	vec2 f = fract(q);
	float f1 = 9.0;
	float f2 = 9.0;
	float id = 0.0;
	for (int yy = -1; yy <= 1; yy++) {
		for (int xx = -1; xx <= 1; xx++) {
			vec2 g = vec2(float(xx), float(yy));
			vec2 cell = mod(i + g, P);
			vec2 o = 0.5 + (hash22(cell + seed) - 0.5) * jitter;
			float d = length(g + o - f);
			if (d < f1) {
				f2 = f1;
				f1 = d;
				id = hash12(cell + seed + 7.0);
			} else if (d < f2) {
				f2 = d;
			}
		}
	}
	return vec3(f1, f2, id);
}

// Height in meters and the albedo / cavity terms for the layer, at tile coordinate x.
// Returns (height, luminance 0..1, cavity 0..1).
vec3 sample_layer(vec2 x) {
	if (layer == 0) {
		// Soil: clumpy loam with root-like furrows, a few scattered irregular stones, fine grain.
		float clump = pfbm(x, 6.0, 5, 0.55, 1.0);
		float grain = pfbm(x, 48.0, 3, 0.5, 9.0);
		vec2 sw = vec2(pfbm(x, 8.0, 2, 0.5, 13.0), pfbm(x, 8.0, 2, 0.5, 17.0)) - 0.5;
		vec3 pb = pworley(x + sw * 0.05, 11.0, 3.0, 0.95);
		float has_pb = step(0.8, pb.z);
		float size = mix(0.16, 0.36, fract(pb.z * 13.7));
		float stone = has_pb * smoothstep(size, size * 0.45, pb.x);
		float furrow = 1.0 - smoothstep(0.0, 0.1, abs(pfbm(x, 5.0, 3, 0.5, 23.0) - 0.5));
		float h = clump * 0.05 + grain * 0.008 + stone * 0.022 - furrow * 0.008;
		float lum = 0.5 + (clump - 0.5) * 0.5 + (grain - 0.5) * 0.3 + stone * (fract(pb.z * 7.3) * 0.5 - 0.05)
				- furrow * 0.08;
		float ring = has_pb * smoothstep(size * 1.25, size, pb.x) * (1.0 - stone);
		float cav = mix(0.82, 1.0, smoothstep(0.3, 0.65, clump)) * (1.0 - ring * 0.35) * (1.0 - furrow * 0.15);
		return vec3(h, lum, cav);
	} else if (layer == 1) {
		// Rock: craggy ridged relief with a few irregular fractures (not a mosaic), weathered
		// faces, grain and pitting.
		vec2 warp = vec2(pfbm(x, 3.0, 4, 0.5, 21.0), pfbm(x, 3.0, 4, 0.5, 37.0)) - 0.5;
		float ridged = 0.0;
		float amp = 0.5;
		float P = 3.0;
		for (int o = 0; o < 5; o++) {
			float r = 1.0 - abs(pnoise(x + warp * 0.2, P, 41.0 + float(o) * 9.0) * 2.0 - 1.0);
			ridged += r * r * amp;
			amp *= 0.5;
			P *= 2.0;
		}
		vec3 w = pworley(x + warp * 0.18, 3.0, 11.0, 1.0);
		float frac_mask = smoothstep(0.35, 0.6, pfbm(x, 2.0, 2, 0.5, 31.0));
		float crack = (1.0 - smoothstep(0.0, 0.035, w.y - w.x)) * frac_mask;
		float grain = pfbm(x, 32.0, 4, 0.55, 51.0);
		float coarse = pfbm(x, 4.0, 4, 0.5, 61.0);
		float pit = smoothstep(0.84, 0.95, pnoise(x, 40.0, 71.0));
		float h = ridged * 0.1 + coarse * 0.08 + (w.z - 0.5) * 0.03 + grain * 0.015 - crack * 0.05 - pit * 0.008;
		float lum = 0.5 + (ridged - 0.45) * 0.5 + (coarse - 0.5) * 0.35 + (grain - 0.5) * 0.35
				+ (w.z - 0.5) * 0.15 - crack * 0.2 - pit * 0.1;
		float cav = mix(0.7, 1.0, smoothstep(0.15, 0.55, ridged)) * (1.0 - crack * 0.4) * (1.0 - pit * 0.2);
		return vec3(h, lum, cav);
	} else if (layer == 2) {
		// Sand: wind ripples (integer wave counts keep it periodic) bent by a soft warp, fine grain.
		float wv = pfbm(x, 3.0, 3, 0.5, 81.0);
		float ph = (x.x * 5.0 + x.y * 2.0) * TAU + wv * 7.0;
		float rip = sin(ph);
		rip = rip * 0.5 + 0.5;
		rip = pow(rip, 1.6);
		float grain = pfbm(x, 96.0, 2, 0.5, 91.0);
		float dune = pfbm(x, 2.0, 3, 0.5, 97.0);
		float h = rip * 0.014 + dune * 0.06 + grain * 0.002;
		float lum = 0.5 + (rip - 0.5) * 0.14 + (grain - 0.5) * 0.5 + (dune - 0.5) * 0.2;
		return vec3(h, lum, mix(0.9, 1.0, rip));
	}
	// Snow: soft drifts, wind-carved sastrugi (stretched), faint crystalline sparkle.
	float drift = pfbm(x, 3.0, 4, 0.5, 101.0);
	vec2 xs = vec2(x.x, x.y);
	float sast = pfbm(vec2(xs.x, xs.y), 6.0, 3, 0.5, 111.0);
	sast = pfbm(vec2(xs.x + sast * 0.15, xs.y), 12.0, 2, 0.5, 121.0);
	float sparkle = step(0.985, hash12(floor(x * 512.0) + 131.0));
	float h = drift * 0.05 + sast * 0.012;
	float lum = 0.5 + (drift - 0.5) * 0.12 + sparkle * 0.45;
	return vec3(h, lum, 1.0);
}

void fragment() {
	vec2 x = UV;
	float e = 1.0 / 512.0;
	vec3 c = sample_layer(x);
	float hx0 = sample_layer(fract(x - vec2(e, 0.0))).x;
	float hx1 = sample_layer(fract(x + vec2(e, 0.0))).x;
	float hy0 = sample_layer(fract(x - vec2(0.0, e))).x;
	float hy1 = sample_layer(fract(x + vec2(0.0, e))).x;
	// Height is in meters; one texel is tile_m * e meters.
	vec2 g = vec2(hx1 - hx0, hy1 - hy0) / (2.0 * e * tile_m);
	g = clamp(g / grad_range, vec2(-1.0), vec2(1.0)) * 0.5 + 0.5;
	COLOR = vec4(clamp(c.y, 0.0, 1.0), g.x, g.y, clamp(c.z, 0.0, 1.0));
}
