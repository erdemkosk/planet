extends CanvasLayer
## Combat overlay (owned by scripts/items/hit_feel.gd): hit markers (white hit, gold weak point,
## steel armor, red kill with a burst ring), short popups under the crosshair ("ZAYIF NOKTA ×2",
## "ZIRH", kill streaks), floating damage numbers at the hit point, and full-screen suit effects on
## a lower layer: personal-shield hex shimmer (toward the hit side), shield break flash, heal pulse
## and the stim tint.

const UI := preload("res://scripts/ui/ui_style.gd")

const HEX_SHADER := """
shader_type canvas_item;
uniform float strength = 0.0;
uniform float side = 0.0;          // -1 left, +1 right, 0 all around
uniform float broken = 0.0;
uniform vec4 tint : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform float t = 0.0;

float hex_edge(vec2 p) {
	p.y *= 1.1547;
	p.x += 0.5 * mod(floor(p.y), 2.0);
	vec2 f = fract(p) - 0.5;
	vec2 a = abs(f);
	float d = max(a.x * 0.866 + a.y * 0.5, a.y);
	return smoothstep(0.40, 0.48, d);
}

void fragment() {
	vec2 uv = UV;
	vec2 c = uv - 0.5;
	c.x *= 1.777;
	float r = length(c);
	float edge = smoothstep(0.25, 0.95, r);
	float dir = 1.0;
	if (abs(side) > 0.01) {
		dir = clamp(0.35 + side * (uv.x - 0.5) * 2.2, 0.0, 1.0);
	}
	float h = hex_edge(uv * vec2(34.0, 19.0) + vec2(0.0, t * 0.6));
	float wave = 0.6 + 0.4 * sin(r * 40.0 - t * 18.0);
	float a = strength * edge * dir * (0.25 + h * 0.75) * wave;
	vec3 col = mix(tint.rgb, vec3(1.0, 0.45, 0.35), broken);
	COLOR = vec4(col * (1.0 + h), clamp(a, 0.0, 0.85));
}
"""

var _low: CanvasLayer
var _hex: ColorRect
var _hex_mat: ShaderMaterial
var _tint: ColorRect
var _top: Control
var _font: Font
var _font_b: Font

var _mark_t := 0.0
var _mark_cls := "hit"
var _mark_dur := 0.3
var _mark_age := 0.0
var _mark_w := 0.3
var _popups: Array = []            # {text, col, t}
var _nums: Array = []              # {pos, val, cls, t, off}
var _hex_k := 0.0
var _hex_side := 0.0
var _hex_broken := 0.0
var _heal_k := 0.0
var _stim_k := 0.0
var _t := 0.0
var _was_busy := false


func _ready() -> void:
	layer = 12
	_font = UI.font(600)
	_font_b = UI.font(800)
	_low = CanvasLayer.new()
	_low.layer = 9
	add_child(_low)
	_hex = ColorRect.new()
	_hex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = HEX_SHADER
	_hex_mat = ShaderMaterial.new()
	_hex_mat.shader = sh
	_hex.material = _hex_mat
	_hex.visible = false
	_low.add_child(_hex)
	_tint = ColorRect.new()
	_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tint.color = Color(0, 0, 0, 0)
	_tint.visible = false
	_low.add_child(_tint)
	_top = Control.new()
	_top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.draw.connect(_draw_top)
	add_child(_top)


# --- API -------------------------------------------------------------------------------------

## cls: "hit", "head", "weak", "armor", "stun", "kill". `weight` 0..1: how big the hit was (the
## marker pops larger for heavy hits).
func marker(cls: String, weight := 0.3) -> void:
	var rank := {"hit": 0, "armor": 1, "stun": 1, "head": 2, "weak": 3, "kill": 4}
	if _mark_t > 0.0 and int(rank.get(cls, 0)) < int(rank.get(_mark_cls, 0)):
		_mark_t = maxf(_mark_t, 0.12)
		_mark_age = minf(_mark_age, 0.03)
		return
	var again := _mark_t > 0.0 and cls == _mark_cls and _mark_age < 0.12   # rapid fire: no 20 Hz pop flicker
	_mark_cls = cls
	_mark_dur = 0.55 if cls == "kill" else (0.38 if cls in ["weak", "head"] else 0.28)
	_mark_t = _mark_dur
	if not again:
		_mark_age = 0.0
	_mark_w = maxf(clampf(weight, 0.0, 1.0), _mark_w if again else 0.0)


func popup(text: String, col: Color) -> void:
	for p in _popups:
		if p["text"] == text and float(p["t"]) < 0.3:
			p["t"] = 0.0
			return
	_popups.append({"text": text, "col": col, "t": 0.0})
	while _popups.size() > 3:
		_popups.pop_front()


## Floating damage number at world point `pos` (merges hits on the same spot within 0.12 s).
func number(pos: Vector3, val: float, cls: String) -> void:
	if val < 0.5:
		return
	for n in _nums:
		if float(n["t"]) < 0.12 and (n["pos"] as Vector3).distance_to(pos) < 1.2:
			n["val"] = float(n["val"]) + val
			if cls in ["kill", "weak"]:
				n["cls"] = cls
			return
	_nums.append({"pos": pos, "val": val, "cls": cls, "t": 0.0, "off": Vector2(randf_range(-14, 14), randf_range(-6, 6))})
	while _nums.size() > 14:
		_nums.pop_front()


## Personal shield took a hit: hex shimmer (side -1 left, +1 right, 0 around), strength 0..1.
func shield_hit(side: float, strength: float) -> void:
	_hex_k = maxf(_hex_k, clampf(strength, 0.25, 1.0))
	_hex_side = side
	_hex_broken = 0.0


func shield_break() -> void:
	_hex_k = 1.2
	_hex_side = 0.0
	_hex_broken = 1.0


func heal_pulse() -> void:
	_heal_k = 1.0


func set_stim(k: float) -> void:
	_stim_k = clampf(k, 0.0, 1.0)


# --- Update / draw ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var rd := delta / maxf(Engine.time_scale, 0.01)
	_t += rd
	_mark_t = maxf(_mark_t - rd, 0.0)
	_mark_age += rd
	for i in range(_popups.size() - 1, -1, -1):
		_popups[i]["t"] = float(_popups[i]["t"]) + rd
		if float(_popups[i]["t"]) > 1.0:
			_popups.remove_at(i)
	for i in range(_nums.size() - 1, -1, -1):
		_nums[i]["t"] = float(_nums[i]["t"]) + rd
		if float(_nums[i]["t"]) > 0.9:
			_nums.remove_at(i)
	_hex_k = maxf(_hex_k - rd * (1.6 if _hex_broken < 0.5 else 1.0), 0.0)
	_hex.visible = _hex_k > 0.01
	if _hex.visible:
		_hex_mat.set_shader_parameter("strength", minf(_hex_k, 1.0) * 0.8)
		_hex_mat.set_shader_parameter("side", _hex_side)
		_hex_mat.set_shader_parameter("broken", _hex_broken)
		_hex_mat.set_shader_parameter("t", _t)
	_heal_k = maxf(_heal_k - rd * 1.2, 0.0)
	var tc := Color(0, 0, 0, 0)
	if _heal_k > 0.0:
		tc = Color(0.3, 1.0, 0.5, 0.12 * _heal_k)
	if _stim_k > 0.0:
		var s := Color(1.0, 0.75, 0.25, 0.05 * _stim_k * (0.8 + 0.2 * sin(_t * 4.0)))
		tc = s if tc.a < s.a else tc
	_tint.color = tc
	_tint.visible = tc.a > 0.003
	var p = Game.player
	_top.visible = p != null and p.get("vehicle") == null
	var busy := _mark_t > 0.0 or not _popups.is_empty() or not _nums.is_empty()
	if _top.visible and (busy or _was_busy):
		_top.queue_redraw()
	_was_busy = busy


func _draw_top() -> void:
	var c := _top.size * 0.5
	if _mark_t > 0.0:
		_draw_marker(c)
	var y := c.y + 38.0
	for p in _popups:
		var t: float = p["t"]
		var a := clampf(t / 0.06, 0.0, 1.0) * clampf((1.0 - t) / 0.35, 0.0, 1.0)
		var col: Color = p["col"]
		var size := 15 if not String(p["text"]).begins_with("×") else 18
		var pop := 1.0 + 0.25 * maxf(0.0, 1.0 - t / 0.12)
		_text_c(c + Vector2(0, y - c.y - t * 10.0), p["text"], int(size * pop), Color(col, a), _font_b)
		y += 20.0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for n in _nums:
		var wp: Vector3 = n["pos"]
		if cam.is_position_behind(wp):
			continue
		var sp := cam.unproject_position(wp)
		var t: float = n["t"]
		var a := clampf((0.9 - t) / 0.3, 0.0, 1.0)
		var cls: String = n["cls"]
		var col := Color(0.95, 0.97, 1.0)
		var sz := 14
		match cls:
			"weak", "head":
				col = Color(1.0, 0.82, 0.25)
				sz = 17
			"armor":
				col = Color(0.62, 0.7, 0.8)
			"kill":
				col = Color(1.0, 0.42, 0.32)
				sz = 18
		var off: Vector2 = n["off"]
		var pos := sp + off + Vector2(0, -26.0 * t - 8.0)
		_text_c(pos, "%d" % int(roundf(float(n["val"]))), sz, Color(col, a), _font_b)


func _draw_marker(c: Vector2) -> void:
	var k := _mark_t / _mark_dur
	var e := 1.0 - k
	var col := Color(1, 1, 1)
	# Snaps in from 1.45x over 60 ms (bigger for heavy hits), then drifts out as it fades.
	var pop := 1.0 + (0.25 + _mark_w * 0.35) * clampf(1.0 - _mark_age / 0.06, 0.0, 1.0)
	var g := (6.0 + e * 6.0) * pop
	var l := (9.0 + _mark_w * 3.0) * pop
	var w := 2.2 + _mark_w * 0.6
	match _mark_cls:
		"head":
			col = Color(1.0, 0.85, 0.35)
			l = 11.0 * pop
			w = 2.8
		"weak":
			col = Color(1.0, 0.78, 0.2)
			l = 12.5 * pop
			w = 3.2
		"armor":
			col = Color(0.62, 0.72, 0.85)
			l = 7.0 * pop
		"stun":
			col = Color(0.45, 0.9, 1.0)
		"kill":
			col = Color(1.0, 0.25, 0.2)
			g = (8.0 + e * 5.0) * pop
			l = 14.0 * pop
			w = 3.6
	for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var dv: Vector2 = (d as Vector2).normalized()
		_top.draw_line(c + dv * g + Vector2(1.5, 1.5), c + dv * (g + l) + Vector2(1.5, 1.5), Color(0, 0, 0, 0.55 * k), w + 1.5, true)
		_top.draw_line(c + dv * g, c + dv * (g + l), Color(col, k), w, true)
	if _mark_cls == "kill":
		# Burst ring + a small skull-like diamond.
		_top.draw_arc(c, 20.0 + e * 22.0, 0, TAU, 40, Color(1.0, 0.35, 0.25, 0.75 * k), 2.5 * k + 0.5, true)
		var s := 5.0
		var pts := PackedVector2Array([c + Vector2(0, -s), c + Vector2(s, 0), c + Vector2(0, s), c + Vector2(-s, 0)])
		_top.draw_colored_polygon(pts, Color(1.0, 0.3, 0.25, k))
	elif _mark_cls == "armor":
		# Cracked plate glyph under the marker.
		var o := c + Vector2(0, 26)
		var pts2 := PackedVector2Array([o + Vector2(-7, -6), o + Vector2(7, -6), o + Vector2(6, 3), o + Vector2(0, 8), o + Vector2(-6, 3), o + Vector2(-7, -6)])
		_top.draw_polyline(pts2, Color(col, 0.9 * k), 1.6, true)
		_top.draw_polyline(PackedVector2Array([o + Vector2(-1, -6), o + Vector2(1, -1), o + Vector2(-2, 2), o + Vector2(1, 7)]), Color(col, 0.9 * k), 1.4, true)
	elif _mark_cls == "weak":
		_top.draw_arc(c, 6.0, 0, TAU, 20, Color(col, 0.9 * k), 2.0, true)


func _text_c(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_top.draw_string(f, p + Vector2(-w * 0.5 + 1.5, 1.5), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.6 * col.a))
	_top.draw_string(f, p + Vector2(-w * 0.5, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
