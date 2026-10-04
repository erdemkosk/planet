shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
// Vegetation / rocks / cave crystals drawn with MultiMesh.
// COLOR.rgb = base color, COLOR.a = tint mask, UV.x = emission mask, UV.y = surface kind
// (0 plain, 1 leaves, 2 rock — see flora_meshes.gd).
// INSTANCE_CUSTOM.rgb = per-instance tint, INSTANCE_CUSTOM.a = snow cover.

uniform float sway = 0.1;            // wind bend in meters at sway_height
uniform float sway_height = 6.0;
uniform float wind = 1.0;            // global wind strength (planet.set_wind)
uniform float emission_energy = 0.0;
// Centre of the body the plant grows on (planet.gd sets it per MultiMesh): noise and wind phase use
// body-local positions, so they stay put when the floating origin moves the world.
instance uniform vec3 body_center = vec3(0.0);

varying vec4 v_tint;
varying float v_emit;
varying float v_snow;
varying float v_kind;
varying vec3 v_bpos;      // body-local (relative to body_center)
varying vec3 v_lpos;      // object space (bark fissures follow the trunk, not world up)

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// Value noise with its analytic gradient (xyz) for bump detail without tangents.
vec4 vnoised(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	vec3 u = f * f * (3.0 - 2.0 * f);
	vec3 du = 6.0 * f * (1.0 - f);
	float a = hash13(i);
	float b = hash13(i + vec3(1, 0, 0));
	float c = hash13(i + vec3(0, 1, 0));
	float d = hash13(i + vec3(1, 1, 0));
	float e = hash13(i + vec3(0, 0, 1));
	float f1 = hash13(i + vec3(1, 0, 1));
	float g = hash13(i + vec3(0, 1, 1));
	float h = hash13(i + vec3(1, 1, 1));
	float k1 = b - a;
	float k2 = c - a;
	float k3 = e - a;
	float k4 = a - b - c + d;
	float k5 = a - c - e + g;
	float k6 = a - b - e + f1;
	float k7 = -a + b + c - d + e - f1 - g + h;
	float v = a + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x + k7 * u.x * u.y * u.z;
	vec3 gr = du * vec3(k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
			k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
			k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
	return vec4(gr, v);
}

void vertex() {
	v_tint = INSTANCE_CUSTOM;
	v_emit = UV.x;
	v_kind = UV.y;
	vec3 origin = MODEL_MATRIX[3].xyz - body_center;
	float ph = dot(origin, vec3(0.071, 0.113, 0.093));
	float h = max(VERTEX.y, 0.0) / sway_height;
	float w = (sin(TIME * 1.3 + ph) * 0.7 + sin(TIME * 2.9 + ph * 2.3) * 0.3) * sway * wind * h * h;
	VERTEX.x += w;
	VERTEX.z += w * 0.6 * sin(ph * 3.0);
	vec3 up = normalize(MODEL_MATRIX[1].xyz);     // instances are aligned with the local up
	// Thin grass blades can have zero-length normals: guard against NaN (NaN pixels bloom into white orbs).
	vec3 n4 = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	float nl = length(n4);
	v_snow = nl > 1e-5 ? clamp(v_tint.a, 0.0, 1.0) * smoothstep(0.05, 0.5, dot(n4 / nl, up)) : 0.0;
	if (length(NORMAL) < 1e-5) {
		NORMAL = vec3(0.0, 1.0, 0.0);
	}
	v_bpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - body_center;
	v_lpos = VERTEX;
}

void fragment() {
	vec3 base = COLOR.rgb;
	vec3 col = mix(base, base * v_tint.rgb, COLOR.a);
	bool leaf = v_kind > 0.5 && v_kind < 1.5;
	bool rock = v_kind > 1.5 && v_kind < 2.5;
	bool bark = v_kind > 3.5;
	float cam_d = length(VERTEX);      // view space: the camera sits at 0
	float detail = 1.0 - smoothstep(60.0, 160.0, cam_d);
	vec3 bump = vec3(0.0);
	if (leaf) {
		// Leaf clusters: patchy light / dark breakup plus a lumpy normal, so a crown reads as
		// foliage rather than a smooth ball. Fades to the plain soft volume in the distance.
		vec4 n1 = vnoised(v_bpos * 2.2);
		vec4 n2 = vnoised(v_bpos * 5.3);
		float leafy = n1.w * 0.65 + n2.w * 0.35;
		col *= mix(1.0, 0.72 + 0.42 * leafy, detail);
		bump = (n1.xyz * 2.2 * 0.6 + n2.xyz * 5.3 * 0.25) * 0.09 * detail;
	} else if (rock) {
		vec4 n1 = vnoised(v_bpos * 0.9);
		vec4 n2 = vnoised(v_bpos * 3.1);
		float rn = n1.w * 0.7 + n2.w * 0.3;
		col *= 0.8 + 0.32 * rn;
		col = mix(col, col * vec3(1.06, 1.0, 0.9), smoothstep(0.55, 0.8, n1.w));
		// Fine grain and darker cracks so boulders read as weathered stone up close.
		vec4 n3 = vnoised(v_bpos * 9.0);
		col *= 0.9 + 0.16 * n3.w;
		col *= 1.0 - 0.25 * (1.0 - smoothstep(0.0, 0.06, abs(n2.w - 0.5))) * detail;
		bump = (n1.xyz * 0.9 * 0.7 + n2.xyz * 3.1 * 0.3 + n3.xyz * 9.0 * 0.06) * 0.35 * detail;
	} else if (bark) {
		// Vertical bark fissures along the trunk (object space), plus a little lengthwise variation.
		vec3 bs = vec3(7.0, 1.1, 7.0);
		vec4 b1 = vnoised(v_lpos * bs);
		vec4 b2 = vnoised(v_lpos * 2.7 + vec3(3.0, 0.0, 1.0));
		float fiss = smoothstep(0.32, 0.68, b1.w);
		col *= (0.66 + 0.46 * fiss) * (0.88 + 0.2 * b2.w);
		bump = (b1.xyz * bs * 0.5 + b2.xyz * 2.7 * 0.2) * 0.1 * detail;
	}
	col = mix(col, vec3(0.88, 0.91, 0.96), v_snow);
	col = pow(clamp(col, vec3(0.0), vec3(1.0)), vec3(2.2));      // colors are authored in sRGB
	ALBEDO = col;
	ROUGHNESS = 0.85 - v_emit * 0.5;
	SPECULAR = 0.25 + v_emit * 0.3 - (leaf ? 0.08 : 0.0);
	BACKLIGHT = vec3(0.28, 0.32, 0.18) * COLOR.a * (1.0 - v_snow) * (1.0 - v_emit) * (rock ? 0.0 : 1.0);
	EMISSION = col * v_emit * emission_energy;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	if (any(isnan(NORMAL)) || dot(NORMAL, NORMAL) < 1e-8) {
		NORMAL = VIEW;
	}
	if (detail > 0.001 && (leaf || rock || bark)) {
		vec3 nW = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 g = bump - nW * dot(bump, nW);
		NORMAL = normalize((VIEW_MATRIX * vec4(normalize(nW - g), 0.0)).xyz);
	}
}
