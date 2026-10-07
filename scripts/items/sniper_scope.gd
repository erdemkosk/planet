extends CanvasLayer
## Scope overlay of the sniper (scripts/items/sniper.gd), on its own CanvasLayer under the main HUD
## (layer 4 < hud.gd 5): a round lens with a soft rim, black outside, a slight darkening and warm
## fringe toward the rim, an eye-box shadow crescent that slides when the gun sways or kicks, a
## muzzle-flash glare, and a fixed (second focal plane) duplex mil-dot reticle with an illuminated
## red centre. Readouts inside the lens: zoom (4× / 6×), the rangefinder distance and the breath
## bar while holding the breath (Shift). Drawn only while the scope is up (strength k > 0).

const UI := preload("res://scripts/ui/ui_style.gd")

const RADIUS := 0.46                 # lens radius in screen heights

const MASK_SHADER := """
shader_type canvas_item;

uniform float k = 0.0;               // 0 hidden .. 1 fully scoped
uniform float aspect = 1.777;
uniform float radius = 0.46;
uniform vec2 shadow = vec2(0.0);     // eye-box offset (in lens radii)
uniform float flash = 0.0;           // muzzle glare 0..1

void fragment() {
	vec2 p = (UV - 0.5) * vec2(aspect, 1.0);
	float open = mix(0.55, 1.0, smoothstep(0.0, 1.0, k));
	float rr = length(p) / (radius * open);
	float outside = smoothstep(0.965, 1.0, rr);
	float vign = smoothstep(0.5, 1.0, rr);
	vign = vign * vign * 0.5;
	float sh = smoothstep(0.78, 1.08, length(p / (radius * open) - shadow));
	float a = max(outside, max(vign, sh * 0.9));
	float rim = exp(-pow((rr - 0.962) * 70.0, 2.0));
	vec3 col = vec3(0.32, 0.16, 0.06) * rim * (1.0 - outside);
	// Lens tint (slightly cool) and the shot's glare from below.
	float inside = 1.0 - outside;
	float low = smoothstep(-0.2, 0.9, p.y / radius);   // canvas y grows downward: glare from below
	col += vec3(1.0, 0.72, 0.38) * flash * low * inside;
	a = max(a, inside * (0.05 + flash * 0.35 * low));
	COLOR = vec4(col, a * smoothstep(0.0, 0.3, k));
}
"""

var _mask: ColorRect
var _mask_mat: ShaderMaterial
var _ret: Control
var _font: Font
var _font_b: Font

# State pushed by the sniper every frame (update()).
var k := 0.0
var zoom := 4.0
var range_m := -1.0
var breath := 1.0                     # 0..1 left
var holding := false
var gasp := 0.0                       # 0..1 out of breath
var shadow := Vector2.ZERO
var flash := 0.0
var _t := 0.0


func _ready() -> void:
	layer = 4
	add_to_group("gameplay_overlay")             # hidden on the end screen / menus (overlay_guard.gd)
	_font = UI.font(500)
	_font_b = UI.font(700)
	_mask = ColorRect.new()
	_mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = MASK_SHADER
	_mask_mat = ShaderMaterial.new()
	_mask_mat.shader = sh
	_mask.material = _mask_mat
	add_child(_mask)
	_ret = Control.new()
	_ret.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ret.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ret.draw.connect(_draw_reticle)
	add_child(_ret)
	visible = false


func update(delta: float) -> void:
	_t += delta
	visible = k > 0.01
	if not visible:
		return
	var vs := _mask.size
	_mask_mat.set_shader_parameter("k", k)
	_mask_mat.set_shader_parameter("aspect", vs.x / maxf(vs.y, 1.0))
	_mask_mat.set_shader_parameter("radius", RADIUS)
	_mask_mat.set_shader_parameter("shadow", shadow)
	_mask_mat.set_shader_parameter("flash", flash)
	_ret.queue_redraw()


func _draw_reticle() -> void:
	var a := smoothstep(0.55, 1.0, k)
	if a <= 0.01:
		return
	var vs := _ret.size
	var c := vs * 0.5
	var rad := RADIUS * vs.y * lerpf(0.55, 1.0, k)
	var ink := Color(0.02, 0.02, 0.025, 0.92 * a)
	var thin := 1.3
	var inner := rad * 0.36
	# Duplex: thick posts from the rim, thin crosshair in the middle.
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		var dv: Vector2 = d
		_ret.draw_line(c + dv * inner, c + dv * rad, ink, 4.0, true)
		_ret.draw_line(c, c + dv * inner, ink, thin, true)
		# Mil dots on the thin part (fixed spacing).
		for i in range(1, 5):
			_ret.draw_circle(c + dv * inner * float(i) / 5.0, 2.1, ink)
	# Small holdover hashes under the centre.
	for i in range(1, 4):
		var y := inner * 0.1 * float(i) + inner * 0.05
		var w := 7.0 - i * 1.5
		_ret.draw_line(c + Vector2(-w, y), c + Vector2(w, y), Color(ink, ink.a * 0.8), 1.0, true)
	# Illuminated centre.
	var glow := 0.75 + 0.25 * sin(_t * 2.0)
	_ret.draw_circle(c, 4.0, Color(1.0, 0.15, 0.1, 0.18 * a * glow))
	_ret.draw_circle(c, 1.7, Color(1.0, 0.22, 0.15, 0.95 * a))
	# Readouts inside the lens (lower right), the design system's look (scripts/ui/ui_style.gd): a
	# small glass rangefinder plate, ZUM and MESAFE in caps, the values in tabular figures.
	var s := UI.scale_k(vs)
	var tc := Color(UI.SCREEN_CYAN, 0.9 * a)
	var pr := Rect2(c + Vector2(rad * 0.46, rad * 0.5), Vector2(118.0, 50.0) * s)
	UI.draw_chamfer(_ret, pr, 7.0 * s, Color(UI.GLASS, 0.55 * a), Color(UI.SCREEN_CYAN, 0.35 * a))
	var caps := UI.font_caps(700, 2)
	var num := UI.font_num(700)
	UI.draw_text(_ret, caps, pr.position + Vector2(10.0, 19.0) * s, "ZUM", UI.fs(10, s), Color(UI.DIM, a), 2)
	UI.draw_text_r(_ret, num, pr.end.x - 10.0 * s, pr.position.y + 20.0 * s, "%d×" % int(roundf(zoom)), UI.fs(16, s), tc, 2)
	var rt := "---" if range_m < 0.0 else "%d" % int(roundf(range_m))
	UI.draw_text(_ret, caps, pr.position + Vector2(10.0, 40.0) * s, "MESAFE", UI.fs(10, s), Color(UI.DIM, a), 2)
	var uw := UI.draw_text_r(_ret, _font, pr.end.x - 10.0 * s, pr.position.y + 41.0 * s, " m", UI.fs(11, s), Color(UI.DIM, a), 2)
	UI.draw_text_r(_ret, num, pr.end.x - 10.0 * s - uw, pr.position.y + 41.0 * s, rt, UI.fs(15, s), tc, 2)
	# Breath bar (12 segments along an arc under the reticle) while it is not full, red and pulsing
	# when out of breath.
	if holding or breath < 0.995 or gasp > 0.0:
		var bc := Color(UI.SCREEN_CYAN, 0.85 * a)
		if gasp > 0.0:
			bc = Color(UI.CRIT, (0.55 + 0.35 * sin(_t * 9.0)) * a)
		elif holding:
			bc = Color(UI.SUIT_WHITE, 0.9 * a)
		var r2 := rad * 0.82
		var a0 := PI * 0.5 + 0.38
		var a1 := PI * 0.5 - 0.38
		var n := 12
		var seg := (a1 - a0) / n
		var b := clampf(breath, 0.0, 1.0)
		_ret.draw_arc(c, r2, a0, a1, 32, Color(UI.OUTLINE, 0.45 * a), 6.0 * s, true)
		for i in n:
			var s0 := a0 + i * seg
			var s1 := s0 + seg * 0.82
			var lit := clampf(b * n - i, 0.0, 1.0)
			_ret.draw_arc(c, r2, s0, s1, 4, Color(UI.SUIT_WHITE, 0.12 * a), 3.0 * s, true)
			if lit > 0.0:
				_ret.draw_arc(c, r2, s0, lerpf(s0, s1, lit), 4, bc, 3.0 * s, true)
		var lbl := "NEFES TUTULUYOR" if holding else ("NEFES NEFESE" if gasp > 0.0 else "NEFES")
		UI.draw_text_c(_ret, caps, c + Vector2(0, r2 + 22.0 * s), lbl, UI.fs(11, s), bc, 3)
	elif a > 0.9:
		var hint := "Shift: nefesini tut  ·  teker: yakınlaştır"
		UI.draw_text_c(_ret, _font, c + Vector2(0, rad * 0.86), hint, UI.fs(12, s), Color(UI.SUIT_WHITE, 0.55 * a), 3)


func _text(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	UI.draw_text(_ret, f, p, s, size, col, 3)


func _text_c(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_text(p - Vector2(w * 0.5, 0), s, size, col, f)
