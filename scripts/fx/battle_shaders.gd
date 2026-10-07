extends RefCounted
## Shaders of the cosmetic background space battle (scripts/fx/space_battle.gd). All unshaded and
## cheap:
##   HULL   opaque hulls (fighters, capital ships, wreck sections, debris chunks): wrapped sun +
##          ambient + a fill from the viewer's side + a cool rim + distance haze (no flat black
##          cut-outs), vertex-colour accents (alpha = emissive amount), one optional blast light.
##          Capital ships add procedural panel seams and lit window strips (instance uniforms
##          detail / win_col). sim_mode 0 = fighters (MultiMesh; INSTANCE_CUSTOM = velocity xyz +
##          state time w, so the GPU dead-reckons between the 10 Hz AI steps), 1 = static mesh,
##          2 = tumbling debris (INSTANCE_CUSTOM = spin axis * rad/s, w = phase + 10 * ember level).
##   GLOW   additive engine plumes (second surface of the hull meshes; same sim_mode 0 / 1).
##   STREAK additive camera-facing ribbons from a ring buffer: bolts, slugs, beams, trails, sparks.
##          Each instance animates itself from its birth time, so the CPU writes it once.
##          Transform columns: x = velocity, y = axis (head - tail), z = (width, t0, life),
##          origin = head at t0. INSTANCE_CUSTOM = rgb (HDR) + mode (0 bolt, 1 constant, 2 beam
##          envelope, 3 trail, 4 spark).
##   FLASH  additive camera-facing billboards from a ring buffer: explosions, rings, flak, shield
##          flashes, fires, projectile heads. Columns: x = (size0, size1, t0), y = (life, kind, seed),
##          z = drift velocity, origin = centre. INSTANCE_CUSTOM = rgb + intensity.
##          kind 0 glow, 1 ring, 2 constant dot, 3 shield ripple (partial hex rim, seed = its angle).
## Streaks and flashes keep a minimum on-screen size (~1.5 px) and trade brightness for it, so far
## bolts never shimmer and nothing blows out (the user's lighting rule).

const HULL := """
shader_type spatial;
render_mode unshaded, world_vertex_coords, cull_disabled, shadows_disabled, fog_disabled;

uniform int sim_mode = 1;
uniform float t_now = 0.0;
uniform vec3 sun_dir = vec3(0.0, 0.33, 0.94);
uniform vec3 sun_col = vec3(1.02, 0.98, 0.9);
uniform vec3 amb_col = vec3(0.24, 0.26, 0.32);
uniform float wrap = 0.45;
uniform float fill = 0.3;
uniform vec3 rim_col = vec3(0.3, 0.38, 0.52);
uniform vec3 haze_col = vec3(0.06, 0.07, 0.1);
uniform float haze = 0.28;
uniform float emis_gain = 2.0;
uniform vec4 blast = vec4(0.0);
uniform vec3 blast_col = vec3(0.0);
instance uniform float emis_mul = 1.0;
instance uniform float charred = 0.0;
instance uniform float detail = 0.0;
instance uniform vec3 win_col = vec3(1.0, 0.78, 0.5);

varying vec3 v_n;
varying vec3 v_wp;
varying vec3 v_lp;
varying vec3 v_ln;
varying float v_haze;
varying float v_ember;

vec3 rot_axis(vec3 v, vec3 k, float a) {
	float c = cos(a);
	float s = sin(a);
	return v * c + cross(k, v) * s + k * dot(k, v) * (1.0 - c);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// Share of a pixel (footprint f metres) covered by a band of half width w centred at x = 0.
float boxcov(float x, float w, float f) {
	float ff = max(f, 0.0001);
	return max(0.0, min(x + 0.5 * ff, w) - max(x - 0.5 * ff, -w)) / ff;
}

void vertex() {
	v_ember = 0.0;
	if (sim_mode == 0) {
		VERTEX += INSTANCE_CUSTOM.xyz * clamp(t_now - INSTANCE_CUSTOM.w, 0.0, 0.3);
	} else if (sim_mode == 2) {
		vec3 ax = INSTANCE_CUSTOM.xyz;
		float sp = length(ax);
		float w = INSTANCE_CUSTOM.w;
		v_ember = floor(w / 10.0) / 3.0;
		if (sp > 0.00001) {
			vec3 k = ax / sp;
			vec3 c = MODEL_MATRIX[3].xyz;
			float a = mod(w, 10.0) + sp * t_now;
			VERTEX = c + rot_axis(VERTEX - c, k, a);
			NORMAL = rot_axis(NORMAL, k, a);
		}
	}
	// ship-local position and normal (capital ships are unscaled) for the surface detail
	mat3 rt = transpose(mat3(MODEL_MATRIX));
	v_lp = rt * (VERTEX - MODEL_MATRIX[3].xyz);
	v_ln = rt * NORMAL;
	v_n = NORMAL;
	v_wp = VERTEX;
	v_haze = haze * smoothstep(500.0, 3300.0, length(VERTEX - INV_VIEW_MATRIX[3].xyz));
}

void fragment() {
	vec3 n = normalize(v_n);
	vec3 vdir = normalize(INV_VIEW_MATRIX[3].xyz - v_wp);
	float ndv = dot(n, vdir);
	// wrapped sun, ambient, a soft fill from the viewer's side (the planets) and a cool rim:
	// the far side of a ship never sinks to a flat black cut-out
	float l = clamp((dot(n, normalize(sun_dir)) + wrap) / (1.0 + wrap), 0.0, 1.0);
	float fl = fill * clamp(ndv * 0.6 + 0.4, 0.0, 1.0);
	vec3 base = COLOR.rgb * (1.0 - 0.6 * charred);
	vec3 emis = vec3(0.0);
	if (detail > 0.5) {
		vec3 p = v_lp;
		vec3 ln = normalize(v_ln);
		vec2 pc = abs(ln.x) > 0.55 ? p.zy : (abs(ln.y) > 0.55 ? p.zx : p.xy);
		vec2 fw = max(fwidth(pc), vec2(0.0001));
		// panel tone and seams (13 x 9 m), faded out once a panel is only a few pixels
		vec2 cell = floor(pc / vec2(13.0, 9.0));
		float lod = 1.0 - smoothstep(1.5, 3.5, max(fw.x, fw.y));
		base *= 1.0 + (hash2(cell + floor(p.x * 0.02) * 17.0) - 0.5) * 0.16 * lod;
		vec2 sg = (fract(pc / vec2(13.0, 9.0) + 0.5) - 0.5) * vec2(13.0, 9.0);
		float seam = max(boxcov(sg.x, 0.3, fw.x), boxcov(sg.y, 0.3, fw.y));
		base *= 1.0 - 0.35 * seam;
		// lit window strips on the sides: 1.4 m bands every 9 m, broken into 22 m runs
		if (abs(ln.x) > 0.55) {
			float row = floor(p.y / 9.0);
			float yy = (fract(p.y / 9.0 + 0.5) - 0.5) * 9.0;
			float zz = (fract(p.z / 22.0) - 0.5) * 22.0;
			float run = floor(p.z / 22.0);
			float lit = step(0.3, hash2(vec2(run, row) + sign(ln.x) * 31.0));
			float on = 0.85 + 0.15 * sin(t_now * 0.7 + run * 3.1 + row);
			emis += win_col * (boxcov(yy, 0.7, fw.y) * boxcov(zz, 8.0, fw.x) * lit * on * 1.7);
		}
		emis *= (1.0 - charred) * emis_mul;
	}
	vec3 col = base * (amb_col + sun_col * l + vec3(fl));
	col += rim_col * pow(1.0 - clamp(ndv, 0.0, 1.0), 3.0) * (0.35 + 0.65 * (1.0 - charred));
	if (blast.w > 0.0) {
		vec3 bl = blast.xyz - v_wp;
		float bd = length(bl);
		float att = clamp(1.0 - bd / blast.w, 0.0, 1.0);
		att *= att;
		col += base * blast_col * att * (0.3 + 0.7 * max(dot(n, bl / max(bd, 0.001)), 0.0));
	}
	float e = clamp(COLOR.a * emis_mul, 0.0, 1.0);
	col = mix(col, COLOR.rgb * emis_gain, e) + emis;
	float flick = 0.75 + 0.25 * sin(t_now * 3.1 + v_wp.x * 0.05 + v_wp.z * 0.04);
	col += vec3(1.0, 0.3, 0.07) * (charred * 0.05 + v_ember * 0.8) * flick;
	ALBEDO = mix(col, haze_col, v_haze);
}
"""

const GLOW := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled, world_vertex_coords;

uniform int sim_mode = 1;
uniform float t_now = 0.0;
uniform float gain = 1.0;
instance uniform float emis_mul = 1.0;

varying vec3 v_col;
varying vec2 v_uv;
varying float v_disc;

void vertex() {
	if (sim_mode == 0) {
		VERTEX += INSTANCE_CUSTOM.xyz * clamp(t_now - INSTANCE_CUSTOM.w, 0.0, 0.3);
	}
	float d = length(VERTEX - INV_VIEW_MATRIX[3].xyz);
	float fl = 0.86 + 0.14 * sin(t_now * 29.0 + VERTEX.x * 0.37 + VERTEX.y * 0.21);
	v_col = COLOR.rgb * (gain * emis_mul * fl * (1.0 - 0.35 * smoothstep(700.0, 3300.0, d)));
	v_uv = UV;
	v_disc = COLOR.a;
}

void fragment() {
	float a;
	if (v_disc > 0.5) {
		float r = length(v_uv * 2.0 - 1.0);
		a = clamp(1.0 - r, 0.0, 1.0);
		a = a * a;
	} else {
		float along = clamp(1.0 - v_uv.y, 0.0, 1.0);
		float across = clamp(1.0 - abs(v_uv.x * 2.0 - 1.0), 0.0, 1.0);
		a = along * along * across;
	}
	ALBEDO = v_col * a;
}
"""

const STREAK := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float t_now = 0.0;
uniform float gain = 1.0;

varying vec3 v_col;
varying vec2 v_q;
varying float v_taper;

void vertex() {
	vec3 vel = MODEL_MATRIX[0].xyz;
	vec3 axis = MODEL_MATRIX[1].xyz;
	vec3 prm = MODEL_MATRIX[2].xyz;
	float age = t_now - prm.y;
	float life = max(prm.z, 0.001);
	float u = age / life;
	float vis = (age >= 0.0 && u <= 1.0) ? 1.0 : 0.0;
	u = clamp(u, 0.0, 1.0);
	float smode = INSTANCE_CUSTOM.a;
	float k = 1.0 - u;
	if (smode > 0.5 && smode < 1.5) {
		k = 1.0;
	} else if (smode > 1.5 && smode < 2.5) {
		k = smoothstep(0.0, 0.1, u) * (1.0 - smoothstep(0.6, 1.0, u));
	} else if (smode > 2.5) {
		k = (1.0 - u) * (1.0 - u);
	}
	vec3 head = MODEL_MATRIX[3].xyz + vel * max(age, 0.0);
	vec3 p = head - axis * (1.0 - VERTEX.y);
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - p;
	float dist = length(to_cam);
	vec3 side = cross(axis, to_cam);
	float sl = length(side);
	side = sl > 0.000001 ? side / sl : vec3(0.0);
	float px = 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float w = max(prm.x, dist * px * 1.5);
	k *= sqrt(prm.x / max(w, 0.0001));
	p += side * (VERTEX.x * 0.5 * w * vis);
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(p, 1.0));
	v_col = INSTANCE_CUSTOM.rgb * (k * vis * gain * (1.0 - 0.3 * smoothstep(700.0, 3300.0, dist)));
	v_q = VERTEX.xy;
	v_taper = (smode < 0.5 || smode > 3.5) ? 1.0 : 0.0;
}

void fragment() {
	float across = clamp(1.0 - abs(v_q.x), 0.0, 1.0);
	float a = across * across;
	a *= mix(1.0, v_q.y * v_q.y, v_taper);
	ALBEDO = v_col * a;
}
"""

const FLASH := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float t_now = 0.0;
uniform float gain = 1.0;

varying vec3 v_col;
varying vec2 v_q;
varying float v_kind;
varying float v_u;
varying float v_seed;

void vertex() {
	vec3 a = MODEL_MATRIX[0].xyz;
	vec3 b = MODEL_MATRIX[1].xyz;
	vec3 vel = MODEL_MATRIX[2].xyz;
	float age = t_now - a.z;
	float life = max(b.x, 0.001);
	float u = age / life;
	float vis = (age >= 0.0 && u <= 1.0) ? 1.0 : 0.0;
	u = clamp(u, 0.0, 1.0);
	float kind = b.y;
	float grow = 1.0 - (1.0 - u) * (1.0 - u);
	float size = mix(a.x, a.y, grow);
	float k = (1.0 - u) * (1.0 - u);
	if (kind > 0.5 && kind < 1.5) {
		k = (1.0 - u) * (1.0 - u);
	} else if (kind > 1.5 && kind < 2.5) {
		k = 1.0;
		size = a.x;
	} else if (kind > 2.5) {
		k = (1.0 - u) * (1.0 - u) * smoothstep(0.0, 0.06, u);
	}
	vec3 c = MODEL_MATRIX[3].xyz + vel * max(age, 0.0);
	float dist = length(INV_VIEW_MATRIX[3].xyz - c);
	float px = 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float s = max(size, dist * px * 1.8);
	k *= sqrt(size / max(s, 0.0001));
	vec3 p = c + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * (s * vis);
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(p, 1.0));
	v_col = INSTANCE_CUSTOM.rgb * (INSTANCE_CUSTOM.a * k * vis * gain * (1.0 - 0.3 * smoothstep(700.0, 3300.0, dist)));
	v_q = VERTEX.xy;
	v_kind = kind;
	v_u = u;
	v_seed = b.z;
}

void fragment() {
	float d = length(v_q);
	float a;
	if (v_kind > 0.5 && v_kind < 1.5) {
		float rr = (d - 0.72) * 4.5;
		a = exp(-rr * rr) * 0.85 + 0.12 * exp(-d * d * 3.0);
	} else if (v_kind > 2.5) {
		// shield: a partial hexagonal ripple with a fresnel rim, never a solid disc
		vec2 hp = v_q * 4.2;
		vec2 hr = vec2(1.0, 1.732);
		vec2 hh = hr * 0.5;
		vec2 ga = mod(hp, hr) - hh;
		vec2 gb = mod(hp - hh, hr) - hh;
		vec2 gv = dot(ga, ga) < dot(gb, gb) ? ga : gb;
		vec2 ap = abs(gv);
		float hd = max(dot(ap, vec2(0.5, 0.866)), ap.x);
		float cells = smoothstep(0.41, 0.49, hd);
		float rr = (d - mix(0.12, 0.95, sqrt(v_u))) * 6.0;
		float rip = exp(-rr * rr);
		float rim = smoothstep(0.62, 0.96, d) * (1.0 - smoothstep(0.96, 1.0, d));
		float ang = atan(v_q.y, v_q.x);
		float part = smoothstep(-0.1, 0.95, cos(ang - v_seed));
		part *= part * part * (0.55 + 0.45 * sin(ang * 3.0 + v_seed * 2.0));
		float fresh = (1.0 - v_u) * (1.0 - v_u);
		a = (cells * 1.5 * rip + rip * 0.22 + rim * 0.22 * fresh) * part + 0.2 * exp(-d * d * 16.0) * fresh;
	} else {
		a = exp(-d * d * 4.5) + 0.6 * exp(-d * d * 28.0);
	}
	a *= 1.0 - smoothstep(0.9, 1.0, d);
	ALBEDO = v_col * max(a, 0.0);
}
"""


static func shader(code: String) -> Shader:
	var sh := Shader.new()
	sh.code = code
	return sh


static func material(sh: Shader, params: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = sh
	for k in params:
		m.set_shader_parameter(StringName(str(k)), params[k])
	return m
