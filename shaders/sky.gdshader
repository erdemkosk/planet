shader_type sky;
// Deep space: procedural stars, faint nebula and the sun disk.

uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float star_visibility = 1.0;
uniform vec3 sun_color : source_color = vec3(1.0, 0.93, 0.82);

vec3 hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

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

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p *= 2.1;
		a *= 0.5;
	}
	return v;
}

vec3 star_layer(vec3 dir, float scale, float density, float size) {
	vec3 p = dir * scale;
	vec3 c = floor(p);
	vec3 f = fract(p);
	vec3 r = hash33(c);
	if (r.x > density) {
		return vec3(0.0);
	}
	vec3 sp = 0.25 + 0.5 * hash33(c + 17.0);
	float d = length(f - sp);
	float b = smoothstep(size * (0.6 + r.y), 0.0, d) * (0.3 + 1.7 * r.z * r.z);
	vec3 tint = mix(vec3(0.65, 0.78, 1.0), vec3(1.0, 0.82, 0.62), r.y);
	return tint * b;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 col = vec3(0.0);

	float n1 = fbm(d * 2.5);
	float n2 = fbm(d * 5.0 + vec3(5.2, 1.3, 2.8));
	col += vec3(0.26, 0.09, 0.34) * smoothstep(0.52, 0.85, n1) * 0.22;
	col += vec3(0.05, 0.14, 0.30) * smoothstep(0.5, 0.82, n2) * 0.22;
	float band = exp(-pow(dot(d, normalize(vec3(0.3, 1.0, 0.25))) * 3.5, 2.0));
	col += vec3(0.10, 0.10, 0.14) * band * (0.4 + n2);

	col += star_layer(d, 110.0, 0.22, 0.10) * 2.2;
	col += star_layer(d, 260.0, 0.25, 0.14) * 1.0;
	col += star_layer(d, 520.0, 0.30, 0.18) * 0.6 * band;

	col *= star_visibility;

	float s = dot(d, normalize(sun_dir));
	col += sun_color * smoothstep(0.99955, 0.99975, s) * 14.0;
	col += sun_color * pow(max(s, 0.0), 900.0) * 1.5;
	col += sun_color * pow(max(s, 0.0), 60.0) * 0.12 * star_visibility;
	COLOR = col;
}
