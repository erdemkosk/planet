extends CanvasLayer
## Lens overlay of the 4× attachment scope ("Dürbün 4×", scripts/items/attachments.gd; the rifle and
## the SMG), on its own CanvasLayer under the HUD (layer 4 < hud.gd 5, like the sniper's scope). One
## full-screen shader draws the whole scope picture from the (already 4× zoomed) screen:
##   lens       the view through the glass with a slight barrel squeeze, a chromatic fringe and a
##              darkening toward the rim, a faint coating tint and reflection, the shot's glare
##   reticle    ACOG-like: an illuminated red chevron (its tip the aim point, on the camera axis) with
##              a dark outline over bright ground and a soft glow, a fine bullet-drop post under it
##              with five shrinking bars (black by day, a dim red in the dark: auto brightness from
##              the scene at the centre); thin, pixel-exact antialiased lines, no stadia
##   eye box    the clear circle follows the eye's offset (`shadow`, lens radii: the Kit feeds the
##              recoil and the gun's sway off the aim pose), a dark crescent on the far side
##   surround   a black eyepiece ring with a machined bevel, the scope body round it (out of focus,
##              lit from above), the world beyond blurred and dim
## While aiming in, the lens matches the 3D eyepiece's size on screen (`radius_from`, the Kit), then
## settles at RADIUS; the Kit hides the view model once the overlay is opaque. Drawn only while the
## scope is up (k > 0); hidden with the other gameplay overlays (group "gameplay_overlay",
## scripts/ui/overlay_guard.gd).

const RADIUS := 0.4                  # lens radius in screen heights (fully in)

const SCOPE_SHADER := """
shader_type canvas_item;

uniform float k = 0.0;                // 0 hidden .. 1 fully in
uniform float aspect = 1.777;
uniform float radius = 0.4;           // lens radius, screen heights
uniform float px_h = 900.0;           // screen height, px (line widths in pixels)
uniform vec2 shadow = vec2(0.0);      // eye-box offset, lens radii
uniform float flash = 0.0;            // muzzle glare 0..1
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

float seg_d(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

// Coverage of a line w px wide at distance d px, one pixel of antialiasing.
float cov(float d, float w) {
	return 1.0 - smoothstep(w * 0.5 - 0.6, w * 0.5 + 0.6, d);
}

void fragment() {
	vec2 p = (UV - 0.5) * vec2(aspect, 1.0);          // screen heights from the centre, y down
	float R = radius;
	float rr = length(p) / R;                          // 1 at the lens rim
	float pr = 1.0 / (R * px_h);                       // one pixel in lens radii
	vec2 q = (UV - 0.5) * vec2(aspect, 1.0) * px_h;    // pixels from the centre
	float Rp = R * px_h;
	// --- Through the glass: a slight barrel squeeze and a chromatic fringe toward the rim.
	float e2 = rr * rr;
	float ca = 0.007 * e2 * e2;
	vec2 b = (SCREEN_UV - 0.5) * (1.0 - 0.02 * e2);
	vec3 view = vec3(texture(screen_tex, 0.5 + b * (1.0 + ca)).r, texture(screen_tex, 0.5 + b).g,
			texture(screen_tex, 0.5 + b * (1.0 - ca)).b);
	float lum = dot(textureLod(screen_tex, vec2(0.5), 5.5).rgb, vec3(0.2126, 0.7152, 0.0722));
	float day = smoothstep(0.1, 0.6, lum);
	view *= vec3(0.965, 0.985, 1.02);
	float vig = smoothstep(0.55, 1.0, rr);
	view *= 1.0 - vig * vig * 0.4;
	view += vec3(1.0, 0.72, 0.4) * flash * smoothstep(-0.2, 0.9, p.y / R) * 0.5;
	view += vec3(0.6, 0.75, 1.0) * 0.03 * exp(-pow(length(p / R - vec2(-0.42, -0.5)) * 2.4, 2.0));
	// --- The reticle: the illuminated chevron (tip on the axis) and the bullet-drop post.
	float cw = max(2.2, Rp * 0.008);                   // chevron line width, px
	vec2 arm = vec2(0.068, 0.053) * Rp;                // chevron half width / height
	float dch = min(seg_d(q, vec2(0.0), vec2(-arm.x, arm.y)), seg_d(q, vec2(0.0), vec2(arm.x, arm.y)));
	float chev = cov(dch, cw);
	float chev_ol = cov(dch, cw + 2.4) * (1.0 - chev);
	float chev_glow = exp(-dch * dch / (cw * cw * 5.0)) * (1.0 - chev);
	float ink = cov(seg_d(q, vec2(0.0, arm.y + cw * 1.5), vec2(0.0, Rp * 0.45)), 1.2);
	for (int i = 0; i < 5; i++) {
		float y = Rp * (0.12 + 0.07 * float(i));
		float w = Rp * (0.05 - 0.0065 * float(i));
		ink = max(ink, cov(seg_d(q, vec2(-w, y), vec2(w, y)), 1.3));
	}
	vec3 red = vec3(1.0, 0.17, 0.07) * mix(0.8, 1.1, day) * (0.97 + 0.03 * sin(TIME * 2.2));
	vec3 ink_c = mix(vec3(0.6, 0.09, 0.04), vec3(0.012, 0.013, 0.016), day);
	view = mix(view, ink_c, ink * 0.92);
	view = mix(view, vec3(0.0), chev_ol * (0.2 + 0.5 * day));
	view += red * chev_glow * (0.45 - 0.2 * day);
	view = mix(view, red, chev);
	// --- Eye-box shadow: the clear circle follows the eye; dark beyond it.
	float sh = smoothstep(0.82, 1.04, length(p / R - shadow));
	view *= 1.0 - sh * 0.95;
	// --- Outside: the world beyond (blurred, dim, darker toward the screen edges), the scope body
	// round the eyepiece (out of focus, lit from above) and the black eyepiece ring with a bevel.
	vec3 outc = textureLod(screen_tex, SCREEN_UV, 4.5).rgb * 0.3;
	outc *= 1.0 - smoothstep(0.55, 1.05, length(p)) * 0.65;
	vec2 bp = (p - vec2(0.0, R * 0.14)) / (R * vec2(1.3, 1.34));
	float sb = pow(pow(abs(bp.x), 4.0) + pow(abs(bp.y), 4.0), 0.25);
	float in_body = 1.0 - smoothstep(0.9, 1.0, sb);
	float top = clamp(-p.y / (R * 1.2), -1.0, 1.0);
	vec3 body = vec3(0.045, 0.047, 0.052) * (1.0 + 1.1 * smoothstep(-0.3, 1.0, top));
	body += vec3(0.08, 0.082, 0.09) * exp(-pow((sb - 0.86) * 14.0, 2.0)) * smoothstep(-0.2, 0.9, top);
	outc = mix(outc, body, in_body);
	float rt = (rr - 1.0) / 0.1;                       // 0..1 across the eyepiece ring
	float lit = 0.35 + 0.65 * smoothstep(-0.7, 0.8, -p.y / max(length(p), 1e-4));
	vec3 ringc = vec3(0.008) + vec3(0.08, 0.082, 0.09) * exp(-pow((rt - 0.72) * 5.0, 2.0)) * lit;
	ringc += vec3(0.05) * exp(-pow((rt - 0.08) * 14.0, 2.0)) * lit;
	outc = mix(outc, ringc, 1.0 - smoothstep(0.96, 1.04, rt));
	float inside = 1.0 - smoothstep(1.0 - pr, 1.0 + pr, rr);
	COLOR = vec4(mix(outc, view, inside), smoothstep(0.0, 0.5, k));
}
"""

var k := 0.0
var zoom := 4.0
var shadow := Vector2.ZERO
var flash := 0.0
var radius_from := -1.0              # the 3D eyepiece's radius on screen (screen heights; -1: none)

var _mask: ColorRect
var _mat: ShaderMaterial


func _ready() -> void:
	layer = 4
	add_to_group("gameplay_overlay")
	_mask = ColorRect.new()
	_mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = SCOPE_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mask.material = _mat
	add_child(_mask)
	visible = false


func update(_delta: float) -> void:
	var want := k > 0.01
	if visible != want and not has_meta("_og_vis"):
		visible = want
	if not want or _mask == null:
		return
	var vs := _mask.size
	var r := RADIUS
	if radius_from > 0.0:
		r = lerpf(clampf(radius_from, 0.05, 0.6), RADIUS, smoothstep(0.25, 0.85, k))
	_mat.set_shader_parameter("k", k)
	_mat.set_shader_parameter("aspect", vs.x / maxf(vs.y, 1.0))
	_mat.set_shader_parameter("radius", r)
	_mat.set_shader_parameter("px_h", maxf(vs.y, 1.0))
	_mat.set_shader_parameter("shadow", shadow)
	_mat.set_shader_parameter("flash", flash)
