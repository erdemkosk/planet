extends RefCounted
## Procedural building blocks for the first-person view model (arms, gloves, held items).
## All view-model materials use a shader that squeezes depth toward the near plane, so the
## arms and the held item always draw on top of world geometry (no clipping into walls).
##
## Lighting (VM_SHADER, GLOVE_SHADER; the shared _VM_LIT chunk). The world's ambient is one flat
## colour and its reflections are off (main.gd): every normal in shade got the same light, so the arms
## and guns drew as flat cut-outs (no form, an emissive rim for an outline: a drawing), and metals had
## nothing to reflect (matte paint). The view model drops that ambient (render_mode
## ambient_light_disabled) and lights itself, as emission, from a small procedural lunar surroundings
## that stays level with the planet (vm_env.gd feeds the world up and the sun every frame):
##   - irradiance: the world ambient's average, but dark toward the black sky and bright toward the
##     lit ground (its bounce), so round shapes keep their form in shade;
##   - reflections through the split-sum BRDF (Godot's own fit): regolith below a horizon blurred by
##     roughness, brighter toward the sun, with broad structure that slides across a surface as the
##     view turns; a near-black sky above with a floor (black parts never go void). Metals tint it with
##     their albedo; dielectrics get physical Fresnel (a grazing sheen from the ground, no painted rim);
##   - occlusion (gloves: joint creases, the palm side facing the held item) on the ambient, the
##     reflections and part of the direct light (AO_LIGHT_AFFECT): the held item's contact shadow.
## Surfaces (object space, every fine detail faded out where a pixel is too coarse for it: no
## shimmer). Items: roughness / tone blotches and smudges, a fine stipple in the normal, sparse
## hairline scratches, worn rounded edges (screen-space curvature: soft_box edges, rings, knobs) and
## regolith dust on their upper faces. metallic >= 0.55 is bare metal (edges polish brighter), 0.12..0.45
## a coated metal (a dielectric cerakote / paint, bare steel where it wears through: the partial
## metallic was unphysical), below that polymer (dark plastic scuffs paler, light plastic picks up
## grime). White plastic / suit keep a softer sun highlight (SPECULAR 0.32: it clipped to white).
## Albedo is floored at 0.055 (black paint, not a hole). Gloves: see GLOVE_SHADER.

const _VM_LIT := """
// World up (xyz; zero: unknown, the camera's up is used) and the sun reaching the eye (w), the
// direction toward the sun: vm_env.gd.
global uniform vec4 vm_env_up;
global uniform vec3 vm_env_sun;

// The world's flat ambient (main.gd AMBIENT × AMBIENT_ENERGY), the sun (SUN_COLOR × light_energy),
// the regolith seen in reflections and the dust it leaves.
const vec3 VM_AMB = vec3(0.231, 0.253, 0.3025);
const vec3 VM_SUN = vec3(1.15, 1.0925, 1.012);
const vec3 VM_GROUND = vec3(0.3, 0.29, 0.28);
const vec3 VM_DUST = vec3(0.46, 0.44, 0.41);

float vm_hash(vec3 p) {
	vec3 q = fract(p * 0.1031);
	q += dot(q, q.zyx + 31.32);
	return fract((q.x + q.y) * q.z);
}

// Value noise, -1..1.
float vm_noise(vec3 x) {
	vec3 i = floor(x);
	vec3 w = fract(x);
	vec3 u = w * w * (3.0 - 2.0 * w);
	float a = mix(mix(vm_hash(i), vm_hash(i + vec3(1.0, 0.0, 0.0)), u.x),
			mix(vm_hash(i + vec3(0.0, 1.0, 0.0)), vm_hash(i + vec3(1.0, 1.0, 0.0)), u.x), u.y);
	float b = mix(mix(vm_hash(i + vec3(0.0, 0.0, 1.0)), vm_hash(i + vec3(1.0, 0.0, 1.0)), u.x),
			mix(vm_hash(i + vec3(0.0, 1.0, 1.0)), vm_hash(i + vec3(1.0, 1.0, 1.0)), u.x), u.y);
	return mix(a, b, u.z) * 2.0 - 1.0;
}

// Value noise (x, -1..1) and its gradient (yzw) in one pass (Inigo Quilez): relief without extra
// samples.
vec4 vm_noised(vec3 x) {
	vec3 i = floor(x);
	vec3 w = fract(x);
	vec3 u = w * w * (3.0 - 2.0 * w);
	vec3 du = 6.0 * w * (1.0 - w);
	float a = vm_hash(i);
	float b = vm_hash(i + vec3(1.0, 0.0, 0.0));
	float c = vm_hash(i + vec3(0.0, 1.0, 0.0));
	float d = vm_hash(i + vec3(1.0, 1.0, 0.0));
	float e = vm_hash(i + vec3(0.0, 0.0, 1.0));
	float f = vm_hash(i + vec3(1.0, 0.0, 1.0));
	float g = vm_hash(i + vec3(0.0, 1.0, 1.0));
	float h = vm_hash(i + vec3(1.0, 1.0, 1.0));
	float k1 = b - a;
	float k2 = c - a;
	float k3 = e - a;
	float k4 = a - b - c + d;
	float k5 = a - c - e + g;
	float k6 = a - b - e + f;
	float k7 = -a + b + c - d + e - f - g + h;
	float v = a + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x
			+ k7 * u.x * u.y * u.z;
	vec3 dv = du * vec3(k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
			k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
			k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
	return vec4(v * 2.0 - 1.0, dv * 2.0);
}

// View-space world up and sun, and how much sun the ground around gets (0 at night / in a tunnel).
void vm_frame(mat4 view, out vec3 up, out vec3 sun, out float sunk) {
	vec3 upw = vm_env_up.xyz;
	up = dot(upw, upw) > 0.25 ? normalize(mat3(view) * upw) : vec3(0.0, 1.0, 0.0);
	sun = normalize(mat3(view) * vm_env_sun);
	sunk = smoothstep(-0.12, 0.3, dot(up, sun)) * mix(0.3, 1.0, clamp(vm_env_up.w, 0.0, 1.0));
}

// Split-sum environment BRDF (Karis' fit, the one Godot uses): scale and bias on F0.
vec2 vm_env_brdf(float nv, float ro) {
	const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
	const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
	vec4 r = ro * c0 + c1;
	float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
	return vec2(-1.04, 1.04) * a004 + r.zw;
}

// The surroundings seen along r (view space; rw the same in world space) by a surface of roughness
// ro: lit regolith below a horizon blurred by roughness (brighter toward the sun, darker straight
// down in the viewer's own shade, broad structure that slides as the view turns), a near-black sky
// above with a floor.
vec3 vm_env(vec3 r, vec3 rw, vec3 up, vec3 sun, float sunk, float ro) {
	float h = dot(r, up);
	float w = 0.025 + ro * ro * 0.9;
	float sky = smoothstep(-w, w * 0.5, h);
	vec3 rh = r - up * h;
	vec3 sh = sun - up * dot(sun, up);
	float toward = dot(rh, sh) / max(length(rh) * length(sh), 1e-4);
	vec3 ground = VM_GROUND * (VM_AMB + VM_SUN * (0.6 * sunk * (0.8 + 0.3 * toward)));
	ground *= (1.0 + 0.3 * vm_noise(rw * 2.5) * (1.0 - 0.8 * ro)) * mix(0.75, 1.0, smoothstep(-1.0, -0.35, h));
	return mix(ground, VM_AMB * 0.3, sky);
}

// Irradiance on view-space normal n: the world ambient's average, dark toward the sky, bright toward
// the ground (more so while the ground is sunlit).
vec3 vm_irr(vec3 n, vec3 up, float sunk) {
	float g = 0.5 - 0.5 * dot(n, up);
	return VM_AMB * mix(1.0, mix(0.7, 1.3, g), 0.55 + 0.45 * sunk);
}

// Indirect light of a surface (its emission): diffuse irradiance (+ a little extra for dark
// albedos, so black parts in shade keep their form; it fades out on light ones, whites never blow
// out) and the reflected surroundings, both occluded by ao (the reflections by Lagarde's specular
// occlusion). grazing scales the dielectric reflection (the old rim uniform).
vec3 vm_indirect(vec3 n, vec3 v, mat4 inv_view, vec3 up, vec3 sun, float sunk, vec3 col, float met,
		float ro, float spec, float ao, float grazing) {
	float nv = clamp(dot(n, v), 1e-3, 1.0);
	vec3 r = reflect(-v, n);
	vec3 rw = mat3(inv_view) * r;
	vec2 ab = vm_env_brdf(nv, ro);
	vec3 f0 = mix(vec3(0.16 * spec * spec), col, met);
	float so = clamp(pow(nv + ao, exp2(-16.0 * ro - 1.0)) - 1.0 + ao, 0.0, 1.0);
	vec3 irr = vm_irr(n, up, sunk);
	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	vec3 dif = col * irr * ao * ((1.0 - met) + 0.25 * (1.0 - smoothstep(0.08, 0.45, lum)));
	vec3 spc = vm_env(r, rw, up, sun, sunk, ro) * (f0 * ab.x + ab.y) * so * mix(grazing, 1.0, met);
	return dif + spc;
}
"""

const VM_SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque, ambient_light_disabled;

uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness = 0.6;
uniform float metallic = 0.0;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float weave = 0.0;      // fabric pattern strength
uniform float rim = 0.25;       // dielectric reflection strength (0.25 = physical)
uniform float fill = 0.035;     // tiny self-illumination so the suit never goes pitch black
uniform float wear = 1.0;       // surface life: roughness variation, scratches, edge wear
varying vec3 op;
varying vec3 onrm;
""" + _VM_LIT + """
void vertex() {
	op = VERTEX;
	onrm = NORMAL;
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	// Reverse-Z: 1 = near plane. Keep the view model in the [0.92, 1] depth slice.
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	vec3 up;
	vec3 sun;
	float sunk;
	vm_frame(VIEW_MATRIX, up, sun, sunk);
	float px = max(length(dFdx(op)), length(dFdy(op)));        // object-space metres per pixel
	vec3 no = normalize(onrm);
	// Curvature (1 / radius, m): the screen-space change of the normal over that of the position.
	float curv = length(fwidth(NORMAL)) / max(length(fwidth(VERTEX)), 1e-6);
	// Material class: bare metal, coated metal (dielectric finish over steel) or polymer.
	float bare = smoothstep(0.45, 0.6, metallic);
	float coat = (1.0 - bare) * smoothstep(0.08, 0.15, metallic);
	float poly = (1.0 - bare) * (1.0 - coat);
	float met = metallic * bare;
	vec3 col = albedo.rgb * (1.0 - 0.7 * metallic * coat);
	float rough = roughness;
	float fab = 0.0;
	if (weave > 0.0) {
		float w = sin(UV.x * 260.0) * sin(UV.y * 140.0);
		float n = fract(sin(dot(floor(UV * vec2(260.0, 140.0)), vec2(12.9898, 78.233))) * 43758.5453);
		col *= 1.0 - weave * (0.35 + 0.35 * w + 0.3 * n);
		fab = smoothstep(0.0, 0.04, weave);
	}
	col = max(col, vec3(0.055));        // black paint / polymer is ~0.05, never a void
	float hard = 1.0 - fab;
	float lum0 = dot(col, vec3(0.2126, 0.7152, 0.0722));
	// Blotches (~1 cm) and mottling (~4 mm): roughness and tone, smudges on the gloss.
	float nn = vm_noise(op * 90.0) * 0.6 + vm_noise(op * 260.0) * 0.4;
	rough = clamp(rough + nn * mix(0.06, 0.12, bare) * wear, 0.05, 1.0);
	col *= 1.0 + nn * 0.05 * wear;
	// Hairline scratches: thin sheets of a stretched noise in two directions cut by the surface,
	// sparse (in patches), antialiased, gone where a pixel is wider than they are.
	float sk = (1.0 - smoothstep(0.0009, 0.0018, px)) * hard * wear;
	float scr = 0.0;
	if (sk > 0.0) {
		float s1 = vm_noise(vec3(dot(op, vec3(0.33, 0.87, 0.36)) * 380.0, op.x * 14.0 + op.z * 9.0, op.y * 12.0));
		float s2 = vm_noise(vec3(dot(op, vec3(0.81, -0.22, 0.54)) * 350.0, op.y * 15.0 - op.z * 7.0, op.z * 13.0 + 4.7));
		float a1 = fwidth(s1) + 0.02;
		float a2 = fwidth(s2) + 0.02;
		float scl = max(smoothstep(0.62 - a1, 0.62 + a1, s1), smoothstep(0.64 - a2, 0.64 + a2, s2));
		scr = scl * smoothstep(0.05, 0.55, vm_noise(op * 28.0 + 7.3)) * sk;
	}
	// Worn rounded edges, broken up by the mottling: bare metal polishes brighter, a coat wears
	// through to steel, dark plastic scuffs paler and light plastic picks up grime.
	float e = smoothstep(70.0, 240.0, curv) * smoothstep(-0.3, 0.45, nn) * wear * hard;
	const vec3 STEEL = vec3(0.56, 0.57, 0.585);
	vec3 scuff = mix(col * 1.45 + 0.04, col * 0.82, smoothstep(0.3, 0.6, lum0));
	col = mix(col, STEEL, e * (0.3 * bare + 0.75 * coat));
	col = mix(col, scuff, e * 0.4 * poly);
	met = mix(met, 1.0, e * (0.5 * bare + 0.85 * coat));
	rough = mix(rough, 0.28, e * (0.5 * bare + 0.6 * coat));
	rough = min(rough + 0.12 * e * poly, 1.0);
	col = mix(col, mix(col * 1.3 + 0.035, STEEL, coat * 0.7 + bare * 0.3), scr * 0.5);
	met = mix(met, 1.0, scr * coat * 0.6);
	rough = clamp(rough + scr * 0.08, 0.05, 1.0);
	// Regolith dust settled on the item's upper faces (its own +Y: it stays put as the view turns),
	// patchy.
	float dust = smoothstep(0.35, 0.95, no.y) * smoothstep(-0.2, 0.6, vm_noise(op * 55.0) + 0.4 * nn) * 0.22;
	col = mix(col, VM_DUST, dust);
	rough = mix(rough, 0.95, dust);
	met *= 1.0 - dust;
	// A fine stipple / orange peel on hard surfaces: a highlight breaks up on it.
	vec3 n = NORMAL;
	float stk = (1.0 - smoothstep(0.0006, 0.0014, px)) * hard * (1.0 - 0.5 * bare);
	if (stk > 0.0) {
		vec4 sd = vm_noised(op * 650.0);
		vec3 gv = mat3(VIEW_MATRIX) * (MODEL_NORMAL_MATRIX * (sd.yzw * (650.0 * 0.00003 * stk)));
		n = normalize(n - (gv - dot(gv, n) * n));
	}
	NORMAL = n;
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = met;
	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	// White plastic / suit: a softer sun highlight (on top of a ~0.9 diffuse it clipped to white).
	float spec = 0.5 - 0.18 * smoothstep(0.5, 0.85, lum) * (1.0 - met);
	SPECULAR = spec;
	EMISSION = emission * emission_energy + col * fill
			+ vm_indirect(n, VIEW, INV_VIEW_MATRIX, up, sun, sunk, col, met, rough, spec, 1.0, 0.8 + 0.8 * rim);
}
"""

## Emitters (indicator strips, LEDs, coils): read as lights inset behind a diffuser, not stickers.
## Toned down (×0.62), full face-on and dimmer at a grazing angle (the slot's walls hide them; the
## old bright fresnel edge drew a neon outline), a faint step per 3 mm (separate LEDs under the
## diffuser, gone where a pixel covers one), an over-driven core whitening a little, and the clear
## cover's faint reflection at a grazing angle.
const GLOW_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 3.0;
uniform float flicker = 0.0;
varying vec3 op;

void vertex() {
	op = VERTEX;
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

float led_hash(vec3 p) {
	vec3 q = fract(p * 0.1031);
	q += dot(q, q.zyx + 31.32);
	return fract((q.x + q.y) * q.z);
}

void fragment() {
	float f = 1.0 - flicker * (0.5 + 0.5 * sin(TIME * 47.0 + UV.y * 30.0));
	float nv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float face = 0.4 + 0.6 * sqrt(nv);
	float px = max(length(dFdx(op)), length(dFdy(op)));
	float led = mix(1.0, 0.93 + 0.1 * led_hash(floor(op / 0.003)), 1.0 - smoothstep(0.0012, 0.0024, px));
	vec3 c = color.rgb * (energy * 0.62 * f * face * led);
	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(c, vec3(lum), smoothstep(1.5, 5.0, lum) * 0.3);
	ALBEDO = c + vec3(0.025, 0.027, 0.03) * pow(1.0 - nv, 5.0);
}
"""

const SCREEN_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform float energy = 1.6;

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	vec3 c = texture(tex, UV).rgb;
	c *= 0.9 + 0.1 * sin(UV.y * 500.0 + TIME * 5.0);
	ALBEDO = c * energy;
}
"""

## See-through tinted glass (optic windows), drawn in the view-model depth slice.
const GLASS_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform vec4 tint : source_color = vec4(0.3, 0.7, 0.75, 0.12);

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	float edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALBEDO = tint.rgb;
	ALPHA = clamp(tint.a + edge * 0.25, 0.0, 1.0);
}
"""

## Collimated sight glass (reflex / holographic, reticle_lens()): the reticle sits at infinity along
## the glass's -Z (the optic's axis, parallel to the bore), never glued to the glass. Every fragment
## rebuilds the true world ray through its pixel (the view model's VM_K squeeze only moves where the
## glass is drawn) and draws the reticle by that ray's angle off the axis in MOA: parallax-free, it
## stays on the bore line however the eye and the window line up, and shows only where the window
## covers that direction. The glass itself: a faint blue coating that turns amber toward the rim, an
## edge vignette and a soft reflection. Auto brightness: the reticle dims in a dark tunnel, brightens
## and gets a thin dark outline over bright ground (the screen behind the aim point, mip-averaged).
## Premultiplied alpha: the reticle's glow adds light, the coating only tints.
const RETICLE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform int kind = 0;                        // 0 red dot, 1 holographic ring + dot (+ ticks)
uniform vec3 reticle : source_color = vec3(1.0, 0.16, 0.08);
uniform float energy = 3.6;
uniform float dot_moa = 2.0;                 // dot diameter
uniform float ring_moa = 65.0;               // holo ring diameter
uniform float ring_w_moa = 2.0;              // holo ring line width
uniform float ticks = 1.0;                   // holo: short ticks at 3 / 6 / 9 / 12 o'clock
uniform float min_px = 1.7;                  // the dot's radius never drops under this (px)
uniform vec4 coat : source_color = vec4(0.62, 0.8, 1.0, 0.035);
uniform vec4 coat_edge : source_color = vec4(1.0, 0.76, 0.5, 0.06);
uniform vec2 half_size = vec2(0.014, 0.014); // glass half extents (m, local x / y)
uniform float corner = 1.0;                  // corner radius (m); >= the half size: a round glass
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

varying vec3 lp;

void vertex() {
	lp = VERTEX;
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// 1 inside a line of half width w at distance d (all in the same units), one pixel px of antialiasing.
float line_cov(float d, float w, float px) {
	return 1.0 - smoothstep(w - px * 0.55, w + px * 0.55, d);
}

void fragment() {
	// The glass outline: a rounded rectangle (signed distance, m), antialiased.
	float cr = min(corner, min(half_size.x, half_size.y));
	vec2 q = abs(lp.xy) - half_size + cr;
	float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cr;
	float aa = max(fwidth(sd), 1e-6);
	float glass = 1.0 - smoothstep(-aa, aa, sd);
	if (glass <= 0.001) {
		discard;
	}
	float inner = clamp(-sd / min(half_size.x, half_size.y), 0.0, 1.0);   // 0 at the rim, 1 at the centre
	// The true ray through this pixel and the optic's axes (view space); m = MOA off the axis.
	vec4 vr = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.5, 1.0);
	vec3 ray = normalize(vr.xyz / vr.w);
	mat3 ob = mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX);
	vec3 ax = normalize(ob[0]);
	vec3 ay = normalize(ob[1]);
	vec3 az = -normalize(ob[2]);
	float fz = max(dot(ray, az), 1e-4);
	vec2 m = vec2(atan(dot(ray, ax), fz), atan(dot(ray, ay), fz)) * 3437.747;
	float px = max(max(fwidth(m.x), fwidth(m.y)), 0.01);                    // MOA per pixel
	// Auto brightness from the scene behind the aim point.
	vec4 cc = PROJECTION_MATRIX * vec4(az, 0.0);
	vec2 cuv = clamp(cc.xy / max(cc.w, 1e-4) * 0.5 + 0.5, vec2(0.0), vec2(1.0));
	float lum = dot(textureLod(screen_tex, cuv, 5.0).rgb, vec3(0.2126, 0.7152, 0.0722));
	float day = smoothstep(0.05, 0.9, lum);
	float gain = mix(0.75, 1.4, day);
	// The reticle: lit coverage, a soft glow and a dark outline round it.
	float r = length(m);
	float dr = max(dot_moa * 0.5, px * min_px);
	float lit = line_cov(r, dr, px);
	float glow = exp(-r * r / pow(dr * 2.0 + px * 1.4, 2.0)) * 0.45 + exp(-r / (dr * 5.0 + px * 4.0)) * 0.05;
	float ol = line_cov(r, dr + px * 1.3, px) * (1.0 - lit);
	float shimmer = 1.0;
	if (kind == 1) {
		float rr = ring_moa * 0.5;
		float rw = max(ring_w_moa * 0.5, px * 0.62);
		float dd = abs(r - rr);
		float ring = line_cov(dd, rw, px);
		float tk = 0.0;
		if (ticks > 0.5) {
			vec2 a = abs(m);
			float along = max(a.x, a.y);
			float across = min(a.x, a.y);
			float tl = rr * 0.2;
			tk = line_cov(across, rw, px) * smoothstep(rr - tl - px * 0.5, rr - tl + px * 0.5, along)
					* (1.0 - smoothstep(rr - px * 0.5, rr + px * 0.5, along));
		}
		float rl = max(ring, tk);
		ol = max(ol, line_cov(dd, rw + px * 1.3, px) * (1.0 - rl));
		glow = max(glow, exp(-dd * dd / pow(rw * 2.5 + px * 1.6, 2.0)) * 0.35);
		lit = max(lit, rl);
		// Hologram shimmer: a faint laser speckle and a slow sweep.
		shimmer = (0.9 + 0.1 * hash2(floor(m / max(px, 0.3)) + floor(TIME * 24.0)))
				* (0.94 + 0.06 * sin(TIME * 5.3 + m.y * 0.12));
	}
	vec3 rc = reticle * energy * gain * shimmer;
	// The glass (premultiplied): coating, edge vignette, a soft diagonal reflection.
	vec2 g = lp.xy / half_size;
	float vig = pow(1.0 - inner, 3.0);
	float band = dot(g, vec2(0.6, 0.8));
	float refl = exp(-pow((band - 0.5) * 3.0, 2.0)) * 0.03 + exp(-pow((band + 0.15) * 10.0, 2.0)) * 0.012;
	// (The coating's tint and the reflection are reflected ambient light: faint in the dark, never a glow.)
	vec4 ct = mix(coat_edge, coat, inner);
	vec3 col = (ct.rgb * ct.a + vec3(0.85, 0.92, 1.0) * refl) * mix(0.15, 1.0, day);
	float al = ct.a + vig * 0.4;
	float ola = ol * smoothstep(0.02, 0.45, lum) * 0.6;
	col *= 1.0 - ola;
	al = al + (1.0 - al) * ola;
	col = col * (1.0 - lit) + rc * lit;
	al = al * (1.0 - lit) + 0.96 * lit;
	col += reticle * energy * gain * glow * (0.55 - 0.3 * day) * (1.0 - lit);   // (less halo by day: crisper)
	ALBEDO = col * glass;
	ALPHA = clamp(al * glass, 0.0, 1.0);
}
"""

static var _glass_shader: Shader
static var _reticle_shader: Shader
## The collimated reticles are drawn this many times their true angular size (a true 65 MOA holo
## ring is ~19 px across at 900 px and a 51° aim FOV, a 2 MOA dot under one pixel): an MW-like,
## readable sight picture.
const RETICLE_SCALE := 2.0

## Suit glove (scripts/player/vm_hand.gd): one material for every glove part. Vertex colour = albedo,
## its alpha the part kind (0 fabric, 1/3 rubber grip pad, 2/3 armour plate, 1 painted accent); with
## use_vcol off the uniforms stand in (the gauntlet / cuff). Lit like the items (_VM_LIT; the old
## emissive fresnel rim drew an outline: gone). Object-space relief (an analytic noise gradient, no
## extra samples) tilts the normal, every fine detail fading out where a pixel is too coarse:
##   fabric  ripstop nylon: raised threads every 4.5 mm, a fine twill, a soft undulation; wrinkles
##           bunch up just past each finger joint (palm side); a soft fabric sheen lit by the
##           surroundings (bright toward the ground, dark toward the sky: never an outline);
##   rubber  ~2 mm molded pebbles, their tops worn a little smoother;
##   plate   matte dielectric polymer (it was 0.15 metallic): a fine orange peel, pale scuffs;
##   accent  painted orange.
## Which mesh a fragment is on: vm_hand.gd builds every phalanx on its joint node (the joint at the
## origin, the bone along -Z, the palm side +Y, all of it within 12.5 mm of the bone axis and 11 mm
## behind the joint) and the palm block in the hand frame (the handle axis = Y through the origin;
## never inside that box, measured). From that: cavities (the crease just past each joint, the palm
## side of every finger and the palm's inner faces facing the held item: its contact shadow, also
## on 45 % of the direct light) and regolith dust (a light film, worked into the fingertip rubber, the
## palm pad, the pinky edge of the palm and the creases).
const GLOVE_SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque, ambient_light_disabled;

uniform bool use_vcol = true;
uniform vec4 albedo : source_color = vec4(0.27, 0.28, 0.31, 1.0);
uniform float kind = 0.0;
uniform float rim = 0.4;        // dielectric reflection strength (0.25 = physical)
uniform float fill = 0.035;
varying vec3 lp;
varying vec3 ln;
varying vec4 vc;
""" + _VM_LIT + """
void vertex() {
	lp = VERTEX;
	ln = NORMAL;
	vc = use_vcol ? COLOR : vec4(albedo.rgb, kind);
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	vec3 up;
	vec3 sun;
	float sunk;
	vm_frame(VIEW_MATRIX, up, sun, sunk);
	int k = int(round(clamp(vc.a, 0.0, 1.0) * 3.0));
	float px = max(length(dFdx(lp)), length(dFdy(lp)));        // object-space metres per pixel
	float fine = 1.0 - smoothstep(0.0006, 0.0013, px);
	vec3 no = normalize(ln);
	float phal = use_vcol ? (1.0 - smoothstep(0.0126, 0.0134, max(abs(lp.x), abs(lp.y))))
			* (1.0 - smoothstep(0.014, 0.02, lp.z)) : 0.0;
	float palm = use_vcol ? 1.0 - phal : 0.0;
	float zj = -lp.z;                                          // past this phalanx's joint (m)
	float palmar = smoothstep(-0.5, 0.7, lp.y / max(length(lp.xy), 1e-4));   // 0 back, 1 palm side
	float n_lo = vm_noise(lp * 60.0);
	vec4 nm = vm_noised(lp * 190.0);
	// Relief: the object-space slope g of the height (m): a soft undulation, then per kind.
	vec3 g = nm.yzw * (190.0 * 0.00012);
	vec3 col = vc.rgb;
	float rough = 0.6;
	float sheen = 0.0;
	float bump = 0.0;
	if (k == 0) {
		// Ripstop threads: three plane families, each weighted by how squarely it crosses the surface.
		vec3 t = fract(lp / 0.0045 + 0.5) - 0.5;
		vec3 a = clamp(abs(t) / 0.16, 0.0, 1.0);
		vec3 wgt = clamp(1.0 - no * no * 1.4, 0.0, 1.0) * (1.0 - smoothstep(0.0009, 0.0018, px));
		vec3 ridge = (1.0 - a * a * (3.0 - 2.0 * a)) * wgt;
		float rs = ridge.x + ridge.y + ridge.z;
		g += -6.0 * a * (1.0 - a) * sign(t) * wgt * (0.00005 / (0.16 * 0.0045));
		vec4 tw = vm_noised(lp * 720.0);
		g += tw.yzw * (720.0 * 0.00004 * fine);
		// Wrinkles bunched up just past the joint, mostly on the palm side.
		float q = (zj - 0.003) / 0.0045;
		float wr = exp(-q * q) * phal * (0.3 + 0.7 * palmar);
		float ph = zj * 1650.0 + nm.x * 2.0;
		g.z -= cos(ph) * wr * (1650.0 * 0.00011);
		col *= 0.95 + 0.05 * tw.x * fine + 0.03 * rs;
		rough = 0.86 - 0.04 * rs;
		sheen = 1.0;
	} else if (k == 1) {
		vec4 pb = vm_noised(lp * 480.0);
		g += pb.yzw * (480.0 * 0.0001 * fine);
		bump = smoothstep(0.0, 0.7, pb.x) * fine;
		rough = 0.7 - 0.1 * bump;
		col *= 0.96 + 0.08 * bump;
	} else if (k == 2) {
		vec4 pe = vm_noised(lp * 520.0);
		g = nm.yzw * (190.0 * 0.00003) + pe.yzw * (520.0 * 0.00002 * fine);
		float sc = smoothstep(0.55, 0.8, vm_noise(vec3(lp.x * 90.0, lp.y * 900.0, lp.z * 90.0)))
				* smoothstep(0.0, 0.6, n_lo) * fine;
		col = mix(col, col * 1.25 + 0.05, sc * 0.6);
		rough = 0.5 + 0.06 * n_lo + 0.15 * sc;
	} else {
		rough = 0.5 + 0.05 * n_lo;
	}
	col *= 0.95 + 0.06 * n_lo;
	// Cavities: the crease past each joint (not on the knuckle plates), the palm side of the
	// fingers, the palm's faces toward the handle axis (the held item's contact shadow).
	float ao = 1.0;
	if (k != 2) {
		float band = 1.0 - smoothstep(-0.002, 0.0065, zj);
		ao -= phal * band * (0.12 + 0.38 * palmar);
	}
	ao *= 1.0 - phal * 0.25 * smoothstep(0.1, 0.9, no.y);
	float rl = max(length(lp.xz), 1e-4);
	float facing = clamp(-dot(lp.xz / rl, no.xz), 0.0, 1.0);
	ao *= 1.0 - palm * 0.45 * facing * (1.0 - smoothstep(0.022, 0.05, rl));
	ao = clamp(ao, 0.3, 1.0);
	// Regolith dust: a film, worked into fingertips, the palm pad, the pinky edge, creases, pebble valleys.
	float rub = k == 1 ? 1.0 : 0.0;
	float pinky = palm * (1.0 - smoothstep(-0.085, -0.055, lp.y));
	float dm = 0.12 + 0.45 * phal * rub + 0.25 * palm * rub + 0.3 * pinky + 0.2 * rub * (1.0 - bump)
			+ 0.25 * (1.0 - ao);
	float grain = vm_noise(lp * 140.0) * 0.7 + vm_noise(lp * 560.0) * 0.3 * fine;
	float dust = clamp(dm * smoothstep(-0.4, 0.5, grain + 0.3 * n_lo), 0.0, 0.65);
	col = mix(col, VM_DUST, dust * 0.55);
	rough = clamp(mix(rough, 0.95, dust), 0.05, 1.0);
	sheen *= 1.0 - dust;
	vec3 gv = mat3(VIEW_MATRIX) * (MODEL_NORMAL_MATRIX * (g * (1.0 - 0.6 * dust)));
	vec3 n = normalize(NORMAL - (gv - dot(gv, NORMAL) * NORMAL));
	NORMAL = n;
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	float spec = 0.5 * (1.0 - 0.5 * dust);
	SPECULAR = spec;
	AO = ao;
	AO_LIGHT_AFFECT = 0.45;
	float nv = clamp(dot(n, VIEW), 0.0, 1.0);
	vec3 sh = mix(col, vec3(0.5), 0.5) * vm_irr(n, up, sunk) * pow(1.0 - nv, 4.0) * 0.35 * sheen * ao;
	EMISSION = vm_indirect(n, VIEW, INV_VIEW_MATRIX, up, sun, sunk, col, 0.0, rough, spec, ao, 0.8 + 0.8 * rim)
			+ sh + col * fill * ao;
}
"""

static var _glove_shader: Shader


## Glove material (GLOVE_SHADER): vcol true for the glove parts (colour + kind per vertex), false for
## a plain part in `col` of kind `k` (0 fabric, 1 rubber, 2 plate, 3 accent).
static func glove_skin(vcol := true, col := Color(0.27, 0.28, 0.31), k := 0) -> ShaderMaterial:
	var key := "glove|%s|%s|%d" % [vcol, col.to_html(), k]
	if _mats.has(key):
		return _mats[key]
	if _glove_shader == null:
		_glove_shader = Shader.new()
		_glove_shader.code = prep(GLOVE_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _glove_shader
	m.set_shader_parameter("use_vcol", vcol)
	m.set_shader_parameter("albedo", col)
	m.set_shader_parameter("kind", float(k) / 3.0)
	_mats[key] = m
	return m


static func glass(tint := Color(0.3, 0.7, 0.75, 0.12)) -> ShaderMaterial:
	if _glass_shader == null:
		_glass_shader = Shader.new()
		_glass_shader.code = prep(GLASS_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _glass_shader
	m.set_shader_parameter("tint", tint)
	return m


## Collimated sight glass (RETICLE_SHADER) centred at `pos` (parent frame, facing the eye along +Z,
## the reticle along -Z): half extents `half`, corner radius `corner` (>= the half size: round).
## kind 0 a red dot (dot_moa), 1 a holographic ring (ring_moa) with a dot and ticks; sizes in true
## MOA, drawn RETICLE_SCALE× larger. Never baked (its own frame is the reticle's axis). Returns the
## mesh instance (its material: the reticle's uniforms).
static func reticle_lens(parent: Node3D, pos: Vector3, half: Vector2, corner: float, kind: int, col: Color,
		dot_moa := 2.0, ring_moa := 65.0) -> MeshInstance3D:
	if _reticle_shader == null:
		_reticle_shader = Shader.new()
		_reticle_shader.code = prep(RETICLE_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _reticle_shader
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("reticle", Color(col.r, col.g, col.b))
	m.set_shader_parameter("half_size", half)
	m.set_shader_parameter("corner", corner)
	m.set_shader_parameter("dot_moa", dot_moa * RETICLE_SCALE)
	m.set_shader_parameter("ring_moa", ring_moa * RETICLE_SCALE)
	m.set_shader_parameter("ring_w_moa", maxf(ring_moa * 0.04, 1.0) * RETICLE_SCALE)
	var qm := QuadMesh.new()
	qm.size = half * 2.0
	var mi := mesh_inst(parent, qm, m)
	mi.position = pos
	mi.set_meta("no_bake", true)
	return mi


## Holographic weapon sight on a rail (weapon mods): riser, slim frame and a collimated window
## (reticle_lens: ring + dot at infinity along the bore, on the sight line y = sight_y; gun frame,
## -Z forward). Returns the root node.
static func holo_sight(parent: Node3D, z: float, rail_y: float, sight_y: float, dot := Color(1.0, 0.25, 0.2)) -> Node3D:
	var o := node(parent)
	var dark := dark_metal()
	var frame := mat(Color(0.2, 0.21, 0.23), 0.4, 0.5)
	var wz := z - 0.01
	var bottom := sight_y - 0.017
	soft_box(o, Vector3(0, (rail_y + bottom) * 0.5, z), Vector3(0.028, maxf(bottom - rail_y, 0.006), 0.05), 0.004, dark)
	box(o, Vector3(0, bottom, wz), Vector3(0.042, 0.006, 0.026), frame)
	for sx in [-1.0, 1.0]:
		box(o, Vector3(0.0195 * sx, sight_y, wz), Vector3(0.004, 0.04, 0.026), frame)
	box(o, Vector3(0, sight_y + 0.0185, wz), Vector3(0.043, 0.005, 0.026), frame)
	box(o, Vector3(0, sight_y + 0.0215, wz + 0.004), Vector3(0.014, 0.002, 0.012), suit_orange())
	reticle_lens(o, Vector3(0, sight_y + 0.001, wz - 0.008), Vector2(0.0176, 0.0152), 0.0025, 1, dot, 1.0, 65.0)
	return o


## The camera FOV and the narrower FOV the arms are drawn with (less wide-angle distortion).
const CAM_FOV := 75.0
const VM_FOV := 70.0

const VMEnv := preload("res://scripts/player/vm_env.gd")
static var _env_node: Node = null
static var _vm_shader: Shader
static var _glow_shader: Shader
static var _screen_shader: Shader
static var _mats := {}


## Projection scale applied to the view model in clip space.
static func fov_scale() -> float:
	return tan(deg_to_rad(CAM_FOV * 0.5)) / tan(deg_to_rad(VM_FOV * 0.5))


## Prepares view-model shader code (inserts the FOV scale). Other scripts use this too. Whole-word
## only: a name merely starting with VM_K (e.g. a VM_KEY constant) is left alone.
## Also registers the global uniforms the view-model lighting reads (vm_env.gd; before any shader
## that uses them compiles) and starts the node that feeds them.
static func prep(code: String) -> String:
	_env_ready()
	return RegEx.create_from_string("\\bVM_K\\b").sub(code, "%.5f" % fov_scale(), true)


static func _env_ready() -> void:
	VMEnv.register()
	if _env_node != null and is_instance_valid(_env_node):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	_env_node = VMEnv.new()
	_env_node.name = "VMEnv"
	tree.root.add_child.call_deferred(_env_node)


## World position that appears on screen where view-model point `p` is drawn
## (used to start world-space effects like the dig beam at the nozzle).
static func vm_to_world(cam: Camera3D, p: Vector3) -> Vector3:
	var k := fov_scale()
	var local := cam.global_transform.affine_inverse() * p
	return cam.global_transform * Vector3(local.x * k, local.y * k, local.z)


static func vm_shader() -> Shader:
	if _vm_shader == null:
		_vm_shader = Shader.new()
		_vm_shader.code = prep(VM_SHADER)
	return _vm_shader


## Unshaded screen showing a texture (e.g. a SubViewport).
static func screen_mat(tex: Texture2D, energy := 1.6) -> ShaderMaterial:
	if _screen_shader == null:
		_screen_shader = Shader.new()
		_screen_shader.code = prep(SCREEN_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _screen_shader
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("energy", energy)
	return m


## Cached lit material. Same parameters share one material.
static func mat(albedo: Color, rough := 0.6, metal := 0.0, weave := 0.0, rim := 0.25) -> ShaderMaterial:
	var key := "%s|%.2f|%.2f|%.2f|%.2f" % [albedo.to_html(), rough, metal, weave, rim]
	if _mats.has(key):
		return _mats[key]
	var m := ShaderMaterial.new()
	m.shader = vm_shader()
	m.set_shader_parameter("albedo", albedo)
	m.set_shader_parameter("roughness", rough)
	m.set_shader_parameter("metallic", metal)
	m.set_shader_parameter("weave", weave)
	m.set_shader_parameter("rim", rim)
	_mats[key] = m
	return m


## Unshaded emissive material (not cached so it can be recolored / animated per item).
static func glow(color: Color, energy := 3.0) -> ShaderMaterial:
	if _glow_shader == null:
		_glow_shader = Shader.new()
		_glow_shader.code = prep(GLOW_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _glow_shader
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("energy", energy)
	return m


# --- Common palette -------------------------------------------------------------------------

static func suit_white() -> ShaderMaterial:
	return mat(Color(0.86, 0.87, 0.85), 0.75, 0.0, 0.10)

static func suit_orange() -> ShaderMaterial:
	return mat(Color(0.95, 0.42, 0.08), 0.55, 0.0, 0.06)

static func suit_gray() -> ShaderMaterial:
	return mat(Color(0.55, 0.57, 0.6), 0.5, 0.2)

static func metal() -> ShaderMaterial:
	return mat(Color(0.62, 0.64, 0.68), 0.28, 0.85)

## Dark gunmetal (a believable 0.3 albedo, not the old 0.16 that drew black in shade; the shader adds
## the roughness blotches and worn edges).
static func dark_metal() -> ShaderMaterial:
	return mat(Color(0.3, 0.31, 0.33), 0.44, 0.6)

static func glove() -> ShaderMaterial:
	return mat(Color(0.25, 0.26, 0.29), 0.75, 0.0, 0.06, 0.4)

static func glove_pad() -> ShaderMaterial:
	return mat(Color(0.42, 0.44, 0.47), 0.55, 0.0)

## (Albedo 0.83, roughness 0.42: at 0.9 / 0.32 the sun's highlight on the receivers clipped to pure
## white.)
static func plastic_white() -> ShaderMaterial:
	return mat(Color(0.83, 0.84, 0.85), 0.42, 0.0)

static func rubber() -> ShaderMaterial:
	return mat(Color(0.14, 0.14, 0.15), 0.88, 0.0)


# --- Geometry -------------------------------------------------------------------------------

## Orthonormal basis whose Y axis points along `dir`.
static func basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


static func node(parent: Node3D, pos := Vector3.ZERO, b := Basis()) -> Node3D:
	var n := Node3D.new()
	n.transform = Transform3D(b, pos)
	parent.add_child(n)
	return n


static func mesh_inst(parent: Node3D, mesh: Mesh, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(mi)
	return mi


## Tapered cylinder from a (radius ra) to b (radius rb).
static func seg(parent: Node3D, a: Vector3, b: Vector3, ra: float, rb: float, m: Material, sides := 18) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.bottom_radius = ra
	cm.top_radius = rb
	cm.height = maxf(a.distance_to(b), 0.001)
	cm.radial_segments = sides
	cm.rings = 1
	var mi := mesh_inst(parent, cm, m)
	mi.transform = Transform3D(basis_y(b - a), (a + b) * 0.5)
	return mi


## Capsule whose cap centers are a and b.
static func capsule(parent: Node3D, a: Vector3, b: Vector3, r: float, m: Material, sides := 14) -> MeshInstance3D:
	var cm := CapsuleMesh.new()
	cm.radius = r
	cm.height = a.distance_to(b) + r * 2.0
	cm.radial_segments = sides
	cm.rings = 4
	var mi := mesh_inst(parent, cm, m)
	mi.transform = Transform3D(basis_y(b - a) if a.distance_to(b) > 1e-5 else Basis(), (a + b) * 0.5)
	return mi


## Torus ring around `axis` through `center`.
static func ring(parent: Node3D, center: Vector3, axis: Vector3, r_out: float, thick: float, m: Material) -> MeshInstance3D:
	var tm := TorusMesh.new()
	tm.inner_radius = r_out - thick
	tm.outer_radius = r_out
	tm.rings = 20
	tm.ring_segments = 8
	var mi := mesh_inst(parent, tm, m)
	mi.transform = Transform3D(basis_y(axis), center)
	return mi


static func ellipsoid(parent: Node3D, pos: Vector3, radii: Vector3, m: Material, b := Basis()) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 18
	sm.rings = 10
	var mi := mesh_inst(parent, sm, m)
	mi.transform = Transform3D(b * Basis.from_scale(radii), pos)
	return mi


static func sphere(parent: Node3D, pos: Vector3, r: float, m: Material) -> MeshInstance3D:
	return ellipsoid(parent, pos, Vector3.ONE * r, m)


static func box(parent: Node3D, pos: Vector3, size: Vector3, m: Material, b := Basis()) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := mesh_inst(parent, bm, m)
	mi.transform = Transform3D(b, pos)
	return mi


## Box with softened edges: a box core plus capsules along its four long edges (Z axis).
static func soft_box(parent: Node3D, pos: Vector3, size: Vector3, r: float, m: Material, b := Basis()) -> Node3D:
	var n := node(parent, pos, b)
	box(n, Vector3.ZERO, Vector3(size.x - r * 2.0, size.y, size.z), m)
	box(n, Vector3.ZERO, Vector3(size.x, size.y - r * 2.0, size.z), m)
	var hx := size.x * 0.5 - r
	var hy := size.y * 0.5 - r
	var hz := size.z * 0.5 - r
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			capsule(n, Vector3(sx * hx, sy * hy, hz), Vector3(sx * hx, sy * hy, -hz), r, m, 10)
	return n


## A pistol grip centered at the origin of the hand frame (vertical, Y up).
static func grip(parent: Node3D, accent: Material) -> void:
	capsule(parent, Vector3(0, -0.068, 0.008), Vector3(0, 0.012, -0.002), 0.0185, rubber())
	for i in 3:
		ring(parent, Vector3(0, -0.05 + i * 0.022, 0.006 - i * 0.002), Vector3(0, 1, -0.1), 0.0195, 0.004, dark_metal())
	seg(parent, Vector3(0, -0.092, 0.01), Vector3(0, -0.078, 0.009), 0.022, 0.02, accent)


## Opt-in record of what bake() merges: while it is an Array, every baked primitive appends
## [bake root, transform relative to that root, its Mesh]. The view model turns an item's record into
## the collision shapes its glove fingers wrap without clipping (scripts/player/vm_hand.gd shapes_of).
static var bake_log = null


## Merges all primitive MeshInstance3D descendants of `root` (except subtrees in `skip`) into
## one ArrayMesh with one surface per material. Cuts the view model's draw calls ~5x.
## Normals are transformed with the inverse-transpose so scaled spheres stay smooth.
static func bake(root: Node3D, skip: Array = []) -> MeshInstance3D:
	var groups := {}
	var victims: Array = []
	_bake_collect(root, Transform3D.IDENTITY, skip, groups, victims)
	if bake_log is Array:
		for v in victims:
			(bake_log as Array).append([root, v.get_meta("_bake_xf", Transform3D()), (v as MeshInstance3D).mesh])
	if victims.is_empty():
		return null
	var am := ArrayMesh.new()
	for key in groups:
		var g: Dictionary = groups[key]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = g["v"]
		arrays[Mesh.ARRAY_NORMAL] = g["n"]
		arrays[Mesh.ARRAY_TEX_UV] = g["uv"]
		arrays[Mesh.ARRAY_INDEX] = g["i"]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		am.surface_set_material(am.get_surface_count() - 1, g["mat"])
	for v in victims:
		v.get_parent().remove_child(v)
		v.queue_free()
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(mi)
	return mi


static func _bake_collect(n: Node, xf: Transform3D, skip: Array, groups: Dictionary, victims: Array) -> void:
	for c in n.get_children():
		if skip.has(c) or not (c is Node3D):
			continue
		var cx: Transform3D = xf * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null and (c as MeshInstance3D).mesh.get_surface_count() == 1 and c.get_child_count() == 0 and not c.has_meta("no_bake"):
			var mi := c as MeshInstance3D
			if bake_log is Array:
				mi.set_meta("_bake_xf", cx)
			var m: Material = mi.material_override
			var key := m.get_instance_id() if m else 0
			if not groups.has(key):
				groups[key] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(),
						"i": PackedInt32Array(), "mat": m}
			var g: Dictionary = groups[key]
			var arr: Array = mi.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var uvs = arr[Mesh.ARRAY_TEX_UV]
			var idx = arr[Mesh.ARRAY_INDEX]
			var nb := cx.basis.inverse().transposed()
			var base: int = g["v"].size()
			var gv: PackedVector3Array = g["v"]
			var gn: PackedVector3Array = g["n"]
			var guv: PackedVector2Array = g["uv"]
			var gi: PackedInt32Array = g["i"]
			for k in verts.size():
				gv.append(cx * verts[k])
				gn.append((nb * norms[k]).normalized())
				guv.append(uvs[k] if uvs != null and k < uvs.size() else Vector2.ZERO)
			if idx != null and idx.size() > 0:
				for k in idx.size():
					gi.append(base + idx[k])
			else:
				for k in verts.size():
					gi.append(base + k)
			g["v"] = gv
			g["n"] = gn
			g["uv"] = guv
			g["i"] = gi
			victims.append(mi)
		else:
			_bake_collect(c, cx, skip, groups, victims)
