shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
// Alpha-tested leaf / needle / frond cards of the near-range vegetation (flora_meshes.gd card
// surfaces; atlas from flora_textures.gd). Same inputs as foliage.gdshader:
// COLOR.rgb = shade, COLOR.a = tint mask, INSTANCE_CUSTOM.rgb = per-instance biome tint,
// INSTANCE_CUSTOM.a = snow cover, UV2 = atlas coordinates.
// Normals are crown-volume normals (lit top, shaded underside) and are NOT flipped on back faces,
// so a crown shades like one soft mass; BACKLIGHT gives the sunlit-leaf translucency.

// No source_color hint: the atlas is grey shading authored like COLOR (sRGB-ish), and the whole
// colour goes through one pow(2.2) below — sampling it as sRGB would darken twice.
uniform sampler2D leaf_tex : filter_linear_mipmap_anisotropic, repeat_disable;
uniform float sway = 0.1;            // wind bend in meters at sway_height
uniform float sway_height = 6.0;
uniform float wind = 1.0;            // global wind strength (planet.set_wind)
// Centre of the body the plant grows on (planet.gd sets it per MultiMesh): the wind phase uses
// body-local positions, so it stays put when the floating origin moves the world.
instance uniform vec3 body_center = vec3(0.0);

varying vec4 v_tint;
varying float v_snow;

void vertex() {
	v_tint = INSTANCE_CUSTOM;
	vec3 origin = MODEL_MATRIX[3].xyz - body_center;
	float ph = dot(origin, vec3(0.071, 0.113, 0.093));
	float h = max(VERTEX.y, 0.0) / sway_height;
	float w = (sin(TIME * 1.3 + ph) * 0.7 + sin(TIME * 2.9 + ph * 2.3) * 0.3) * sway * wind * h * h;
	VERTEX.x += w;
	VERTEX.z += w * 0.6 * sin(ph * 3.0);
	// Leaf flutter: small, fast, different per card corner.
	float fl = sin(TIME * 6.3 + dot(VERTEX, vec3(3.1, 2.3, 2.7)) + ph * 5.0) * 0.022 * wind;
	VERTEX += NORMAL * fl;
	vec3 up = normalize(MODEL_MATRIX[1].xyz);
	vec3 n4 = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	float nl = length(n4);
	v_snow = nl > 1e-5 ? clamp(v_tint.a, 0.0, 1.0) * smoothstep(0.05, 0.5, dot(n4 / nl, up)) : 0.0;
	if (nl < 1e-5) {
		NORMAL = vec3(0.0, 1.0, 0.0);
	}
}

void fragment() {
	vec4 t = texture(leaf_tex, UV2);
	float cam_d = length(VERTEX);      // view space: the camera sits at 0
	ALPHA = t.a;
	// Lower the cut with distance: mip levels average thin needles / leaf edges toward 0.
	ALPHA_SCISSOR_THRESHOLD = mix(0.5, 0.28, smoothstep(12.0, 80.0, cam_d));
	vec3 base = COLOR.rgb;
	vec3 col = mix(base, base * v_tint.rgb, COLOR.a);
	col *= t.r * 1.18;
	col = mix(col, vec3(0.88, 0.91, 0.96), v_snow);
	col = pow(clamp(col, vec3(0.0), vec3(1.0)), vec3(2.2));      // colors are authored in sRGB
	ALBEDO = col;
	ROUGHNESS = 0.72;
	SPECULAR = 0.32;
	BACKLIGHT = vec3(0.36, 0.42, 0.22) * COLOR.a * (1.0 - v_snow);
	if (any(isnan(NORMAL)) || dot(NORMAL, NORMAL) < 1e-8) {
		NORMAL = VIEW;
	}
}
