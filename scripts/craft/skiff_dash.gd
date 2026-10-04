extends Control
## The Mekik's instrument screen (skiff.gd): drawn into a small SubViewport whose texture lights the
## pilot's display on the dash (diegetic, no 2D overlay). Turkish labels.
##   left    HIZ (speed), DİKEY (vertical speed), İTKİ / TAKVİYE bars
##   centre  attitude ball (pitch ladder, bank), the mode line under it
##   right   İRTİFA (height of the feet above the ground), distance to the YURT / RAKİP surfaces,
##           GÖVDE (hull) bar
## Skiff.gd fills `data` and calls refresh() ~20 times a second while the ship is powered.

const UI := preload("res://scripts/ui/ui_style.gd")
const SIZE := Vector2i(768, 384)

const BG := Color(0.035, 0.06, 0.085)
const LINE := Color(0.35, 0.62, 0.78, 0.35)
const TXT := Color(0.86, 0.93, 0.98)
const DIM := Color(0.5, 0.62, 0.72)
const CYAN := Color(0.42, 0.85, 1.0)
const AMBER := Color(1.0, 0.72, 0.3)
const RED := Color(1.0, 0.38, 0.32)
const GREEN := Color(0.45, 0.92, 0.6)
const SKY := Color(0.2, 0.36, 0.52)
const GROUND := Color(0.42, 0.29, 0.18)

var data := {}
var viewport: SubViewport
var _f: Font
var _fb: Font
var _t := 0.0


## Builds the viewport with this screen in it; the returned node goes under the ship.
static func create() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	var d: Control = load("res://scripts/craft/skiff_dash.gd").new()
	d.viewport = vp
	d.size = Vector2(SIZE)
	vp.add_child(d)
	return vp


func _ready() -> void:
	_f = UI.font(500)
	_fb = UI.font(700)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = Vector2(SIZE)


## Redraws and renders the viewport once.
func refresh(delta: float) -> void:
	_t += delta
	queue_redraw()
	if viewport != null:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _draw() -> void:
	var w := float(SIZE.x)
	var h := float(SIZE.y)
	draw_rect(Rect2(0, 0, w, h), BG)
	if not bool(data.get("power", false)):
		# Standby: a dim logo and nothing else.
		_text(Vector2(w * 0.5, h * 0.52), "MEKİK", 30, Color(DIM, 0.25), _fb, HORIZONTAL_ALIGNMENT_CENTER)
		return
	# Faint scan lines and the frame.
	for y in range(0, int(h), 4):
		draw_line(Vector2(0, y), Vector2(w, y), Color(1, 1, 1, 0.012))
	draw_rect(Rect2(6, 6, w - 12, h - 12), LINE, false, 2.0)
	draw_line(Vector2(250, 20), Vector2(250, h - 20), LINE, 1.0)
	draw_line(Vector2(518, 20), Vector2(518, h - 20), LINE, 1.0)
	_left(w, h)
	_center(w, h)
	_right(w, h)


func _left(_w: float, h: float) -> void:
	var sp: float = float(data.get("speed", 0.0))
	var vs: float = float(data.get("vspeed", 0.0))
	_text(Vector2(26, 46), "HIZ", 18, DIM, _fb)
	_text(Vector2(26, 118), "%d" % roundi(sp), 72, TXT, _fb)
	_text(Vector2(30 + _fb.get_string_size("%d" % roundi(sp), HORIZONTAL_ALIGNMENT_LEFT, -1, 72).x, 118), "m/s", 22, DIM, _f)
	_text(Vector2(26, 170), "DİKEY", 18, DIM, _fb)
	var vc := TXT
	if vs < -4.0 and float(data.get("clear", 99.0)) < 15.0:
		vc = AMBER
	_text(Vector2(26, 212), ("%+.1f" % vs) + " m/s", 34, vc, _fb)
	# Vertical-speed arrow.
	var ax := 214.0
	var ay := 196.0
	var dir := -1.0 if vs > 0.2 else (1.0 if vs < -0.2 else 0.0)
	if dir != 0.0:
		draw_colored_polygon(PackedVector2Array([Vector2(ax - 10, ay - dir * 6), Vector2(ax + 10, ay - dir * 6),
				Vector2(ax, ay + dir * 10)]), Color(vc, 0.9))
	# Thrust and boost bars.
	var thr: float = clampf(float(data.get("thrust", 0.0)), 0.0, 1.0)
	var bo: float = clampf(float(data.get("boost", 0.0)), 0.0, 1.0)
	_bar(Vector2(26, 252), 200.0, thr, CYAN, "İTKİ")
	_bar(Vector2(26, 300), 200.0, bo, AMBER, "TAKVİYE")
	_text(Vector2(26, h - 30), "MEKİK · YR-01", 15, Color(DIM, 0.6), _f)


func _center(w: float, h: float) -> void:
	var c := Vector2(w * 0.5, 160.0)
	var r := 108.0
	var pitch: float = float(data.get("pitch", 0.0))
	var roll: float = float(data.get("roll", 0.0))
	# Horizon: the ground side of a line rotated by the bank and shifted by the pitch.
	var up := Vector2(sin(roll), -cos(roll))
	var off := clampf(pitch / deg_to_rad(40.0), -1.4, 1.4) * r
	var circle := PackedVector2Array()
	for i in 48:
		var a := TAU * float(i) / 48.0
		circle.append(c + Vector2(cos(a), sin(a)) * r)
	draw_colored_polygon(circle, SKY)
	var ground := _clip_half(circle, c - up * off, up)
	if ground.size() >= 3 and _area(ground) > 30.0:
		draw_colored_polygon(ground, GROUND)
	# Pitch ladder every 10 degrees.
	var right := Vector2(-up.y, up.x)
	for k in range(-3, 4):
		if k == 0:
			continue
		var po := c + up * (-off + float(k) * deg_to_rad(10.0) / deg_to_rad(40.0) * r)
		if po.distance_to(c) > r - 12.0:
			continue
		var hw := 26.0 if k % 2 == 0 else 15.0
		draw_line(po - right * hw, po + right * hw, Color(1, 1, 1, 0.55), 2.0)
	var hz := c - up * off
	draw_line(hz - right * r, hz + right * r, Color(1, 1, 1, 0.8), 2.0)
	draw_arc(c, r, 0.0, TAU, 64, Color(LINE, 0.9), 3.0)
	# Fixed aircraft symbol.
	draw_line(c + Vector2(-46, 0), c + Vector2(-14, 0), AMBER, 4.0)
	draw_line(c + Vector2(14, 0), c + Vector2(46, 0), AMBER, 4.0)
	draw_line(c + Vector2(-14, 0), c + Vector2(0, 10), AMBER, 4.0)
	draw_line(c + Vector2(14, 0), c + Vector2(0, 10), AMBER, 4.0)
	draw_circle(c, 3.0, AMBER)
	# Mode line.
	var mode: String = str(data.get("mode", ""))
	var mc: Color = data.get("mode_color", CYAN)
	_text(Vector2(w * 0.5, 304), mode, 24, mc, _fb, HORIZONTAL_ALIGNMENT_CENTER)
	var sub: String = str(data.get("sub", ""))
	if sub != "":
		_text(Vector2(w * 0.5, 334), sub, 16, DIM, _f, HORIZONTAL_ALIGNMENT_CENTER)
	var warn: String = str(data.get("warn", ""))
	if warn != "" and fmod(_t, 0.8) < 0.5:
		var tw := _fb.get_string_size(warn, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		draw_rect(Rect2(w * 0.5 - tw * 0.5 - 12, 352, tw + 24, 26), Color(RED, 0.25))
		_text(Vector2(w * 0.5, 372), warn, 22, RED, _fb, HORIZONTAL_ALIGNMENT_CENTER)


func _right(w: float, h: float) -> void:
	var x := 540.0
	var clear: float = float(data.get("clear", 0.0))
	_text(Vector2(x, 46), "İRTİFA", 18, DIM, _fb)
	var ct := ("%.1f" % clear) if clear < 100.0 else ("%d" % roundi(clear))
	if clear > 9000.0:
		ct = "—"
	var cc := TXT if clear > 3.0 or float(data.get("vspeed", 0.0)) > -2.0 else AMBER
	_text(Vector2(x, 100), ct, 48, cc, _fb)
	_text(Vector2(x + 6 + _fb.get_string_size(ct, HORIZONTAL_ALIGNMENT_LEFT, -1, 48).x, 100), "m", 20, DIM, _f)
	var targets: Array = data.get("targets", [])
	var y := 150.0
	for t in targets:
		var nm: String = str(t[0])
		var d: float = float(t[1])
		var col: Color = t[2]
		_text(Vector2(x, y), nm, 18, col, _fb)
		var ds := ("%d m" % roundi(d)) if d < 1000.0 else ("%.2f km" % (d / 1000.0))
		_text(Vector2(w - 26, y), ds, 22, TXT, _fb, HORIZONTAL_ALIGNMENT_RIGHT)
		y += 38.0
	# Gravity readout.
	_text(Vector2(x, 236), "ÇEKİM", 15, DIM, _fb)
	_text(Vector2(w - 26, 236), "%.1f m/s²" % float(data.get("grav", 0.0)), 18, TXT, _f, HORIZONTAL_ALIGNMENT_RIGHT)
	# Hull.
	var hp: float = clampf(float(data.get("hp", 1.0)), 0.0, 1.0)
	var hc := GREEN.lerp(AMBER, smoothstep(0.65, 0.4, hp)).lerp(RED, smoothstep(0.4, 0.2, hp))
	_text(Vector2(x, 290), "GÖVDE", 18, DIM, _fb)
	_text(Vector2(w - 26, 290), "%d%%" % roundi(hp * 100.0), 22, hc, _fb, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_rect(Rect2(x, 304, w - 26 - x, 12), Color(1, 1, 1, 0.08))
	draw_rect(Rect2(x, 304, (w - 26 - x) * hp, 12), hc)
	var lights: bool = bool(data.get("lights", false))
	_text(Vector2(x, h - 30), "IŞIK " + ("AÇIK" if lights else "KAPALI") + "  ·  L", 15, Color(DIM, 0.7), _f)


func _bar(p: Vector2, w: float, k: float, col: Color, label: String) -> void:
	_text(p + Vector2(0, -4), label, 15, DIM, _fb)
	draw_rect(Rect2(p + Vector2(0, 6), Vector2(w, 12)), Color(1, 1, 1, 0.07))
	draw_rect(Rect2(p + Vector2(0, 6), Vector2(w * k, 12)), col)
	for i in range(1, 4):
		var tx := p.x + w * float(i) / 4.0
		draw_line(Vector2(tx, p.y + 6), Vector2(tx, p.y + 18), Color(BG, 0.8), 2.0)


func _text(p: Vector2, s: String, size: int, col: Color, f: Font, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var x := p.x
	if align != HORIZONTAL_ALIGNMENT_LEFT:
		var tw := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		x -= tw * (0.5 if align == HORIZONTAL_ALIGNMENT_CENTER else 1.0)
	draw_string(f, Vector2(x, p.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5


## The part of polygon `poly` on the side of the line through `p` that `n` points away from.
static func _clip_half(poly: PackedVector2Array, p: Vector2, n: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var cnt := poly.size()
	for i in cnt:
		var a := poly[i]
		var b := poly[(i + 1) % cnt]
		var da := (a - p).dot(n)
		var db := (b - p).dot(n)
		if da <= 0.0:
			out.append(a)
		if (da <= 0.0) != (db <= 0.0):
			out.append(a + (b - a) * (da / (da - db)))
	return out
