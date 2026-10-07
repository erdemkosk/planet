extends Control
## The İniş Gemisi's cabin displays (scripts/war/dropship.gd), drawn into one SubViewport (SIZE) that
## four screen quads show parts of (dropship.gd sets each quad's uv1 offset / scale):
##   NAV   (0, 0, 340, 256)       radar: range rings, the ship's heading up, the landing marker in the
##                                ship's frame, the distance to it, the carrier's bearing
##   İRT   (342, 0, 340, 256)     altitude (big), vertical speed, ground speed, an altitude tape
##   İNİŞ  (684, 0, 340, 256)     time to touchdown (big) and the sequence: KENET · AYRILMA · ANA MOTOR ·
##                                RETRO · İNİŞ TAKIMI · RAMPA (done / now / to come)
##   KAPI  (0, 256, 1024, 512)    the wall screen: "YENİDEN DOĞUŞ" with the countdown to the ramp, the
##                                door state (KİLİTLİ / AÇIK), the descent progress
## Data: ship.screen_info() (a Dictionary). Redrawn REDRAW_HZ times a second while the viewport is
## updated (dropship.gd only updates it while someone rides along).

const UI := preload("res://scripts/ui/ui_style.gd")

const SIZE := Vector2i(1024, 768)
const PANELS := {"nav": Rect2(0, 0, 340, 256), "alt": Rect2(342, 0, 340, 256), "seq": Rect2(684, 0, 340, 256),
		"wall": Rect2(0, 256, 1024, 512)}
const REDRAW_HZ := 20.0
const BG := Color(0.015, 0.03, 0.045)
const GRID := Color(0.25, 0.6, 0.85, 0.07)
const CYAN := Color(0.4, 0.86, 1.0)
const DIM := Color(0.42, 0.62, 0.74)
const AMBER := Color(1.0, 0.68, 0.28)
const GOOD := Color(0.45, 0.95, 0.6)
const BAD := Color(1.0, 0.36, 0.3)

var ship = null
var _acc := 0.0
var _f4: Font
var _f7: Font


func _ready() -> void:
	size = Vector2(SIZE)
	_f4 = UI.font(500)
	_f7 = UI.font(700)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_acc += delta
	if _acc >= 1.0 / REDRAW_HZ:
		_acc = 0.0
		queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(SIZE)), Color(0, 0, 0))
	var d: Dictionary = {}
	if ship != null and is_instance_valid(ship) and ship.has_method("screen_info"):
		d = ship.screen_info()
	for key: String in PANELS:
		_frame(PANELS[key])
	if d.is_empty():
		return
	_nav(PANELS["nav"], d)
	_alt(PANELS["alt"], d)
	_seq(PANELS["seq"], d)
	_wall(PANELS["wall"], d)


func _frame(r: Rect2) -> void:
	draw_rect(r, BG)
	var x := r.position.x + 16.0
	while x < r.end.x:
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), GRID, 1.0)
		x += 32.0
	var y := r.position.y + 16.0
	while y < r.end.y:
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), GRID, 1.0)
		y += 32.0
	draw_rect(r.grow(-3.0), Color(CYAN.r, CYAN.g, CYAN.b, 0.25), false, 2.0)


func _text(p: Vector2, s: String, sz: int, col: Color, bold := false, align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	draw_string(_f7 if bold else _f4, p, s, align, w, sz, col)


func _blink(hz: float) -> bool:
	return fmod(Time.get_ticks_msec() / 1000.0 * hz, 1.0) < 0.5


func _nav(r: Rect2, d: Dictionary) -> void:
	var o := r.position
	_text(o + Vector2(14, 30), "NAV", 20, CYAN, true)
	_text(o + Vector2(64, 30), "İNİŞ NOKTASI", 15, DIM)
	var c := o + Vector2(r.size.x * 0.5, 146.0)
	var rad := 92.0
	for k in 3:
		draw_arc(c, rad * float(k + 1) / 3.0, 0.0, TAU, 48, Color(CYAN.r, CYAN.g, CYAN.b, 0.22 + 0.1 * float(k)), 1.5)
	draw_line(c - Vector2(rad, 0), c + Vector2(rad, 0), Color(CYAN.r, CYAN.g, CYAN.b, 0.18), 1.0)
	draw_line(c - Vector2(0, rad), c + Vector2(0, rad), Color(CYAN.r, CYAN.g, CYAN.b, 0.18), 1.0)
	for i in 36:
		var a := TAU * float(i) / 36.0
		var l := 8.0 if i % 9 == 0 else 4.0
		draw_line(c + Vector2(sin(a), -cos(a)) * rad, c + Vector2(sin(a), -cos(a)) * (rad + l), Color(CYAN.r, CYAN.g, CYAN.b, 0.5), 1.0)
	# The sweep.
	var sw := fmod(Time.get_ticks_msec() / 1000.0 * 1.4, TAU)
	for k2 in 8:
		var a2 := sw - float(k2) * 0.06
		draw_line(c, c + Vector2(sin(a2), -cos(a2)) * rad, Color(CYAN.r, CYAN.g, CYAN.b, 0.16 - 0.018 * float(k2)), 2.0)
	# Landing marker: its horizontal offset in the ship's frame (x right, -z ahead = up on the screen).
	var lv: Vector2 = d.get("land_local", Vector2.ZERO)
	var dist: float = float(d.get("land_dist", 0.0))
	var range_m := maxf(40.0, ceilf(dist / 40.0) * 40.0)
	var mp := lv / range_m * rad
	if mp.length() > rad:
		mp = mp.normalized() * rad
	var mk := c + mp
	var col := AMBER if not bool(d.get("landed", false)) else GOOD
	draw_colored_polygon(PackedVector2Array([mk + Vector2(0, -7), mk + Vector2(7, 0), mk + Vector2(0, 7), mk + Vector2(-7, 0)]), col)
	draw_arc(mk, 11.0 + (3.0 if _blink(2.0) else 0.0), 0.0, TAU, 20, Color(col.r, col.g, col.b, 0.6), 1.5)
	# Ourselves.
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -9), c + Vector2(6, 7), c + Vector2(0, 3), c + Vector2(-6, 7)]), Color(0.9, 0.97, 1.0))
	_text(o + Vector2(14, 246), "%d m" % int(round(dist)), 18, col, true)
	_text(o + Vector2(r.size.x - 120, 246), "ÖLÇEK %d m" % int(range_m), 13, DIM, false, HORIZONTAL_ALIGNMENT_RIGHT, 106.0)


func _alt(r: Rect2, d: Dictionary) -> void:
	var o := r.position
	var alt: float = float(d.get("alt", 0.0))
	var vs: float = float(d.get("vspeed", 0.0))
	var hs: float = float(d.get("hspeed", 0.0))
	_text(o + Vector2(14, 30), "İRTİFA", 20, CYAN, true)
	var big := "%d" % maxi(int(round(alt)), 0)
	_text(o + Vector2(14, 128), big, 76, Color(0.9, 0.97, 1.0), true)
	_text(o + Vector2(16 + 44.0 * float(big.length()), 128), "m", 26, DIM)
	var vcol := GOOD if absf(vs) < 6.0 else (AMBER if absf(vs) < 18.0 else BAD)
	_text(o + Vector2(14, 176), "DİKEY HIZ", 14, DIM)
	_text(o + Vector2(14, 204), "%+.1f m/s" % vs, 24, vcol, true)
	_text(o + Vector2(14, 236), "YATAY  %.1f m/s" % hs, 15, DIM)
	# Tape: 0..120 m, the ship's mark, the retro gate.
	var tx := o.x + r.size.x - 40.0
	var t0 := o.y + 24.0
	var t1 := o.y + r.size.y - 18.0
	draw_line(Vector2(tx, t0), Vector2(tx, t1), Color(CYAN.r, CYAN.g, CYAN.b, 0.45), 2.0)
	for i in 7:
		var y := lerpf(t1, t0, float(i) / 6.0)
		draw_line(Vector2(tx - 8.0, y), Vector2(tx, y), Color(CYAN.r, CYAN.g, CYAN.b, 0.45), 1.0)
		_text(Vector2(tx - 60.0, y + 5.0), "%d" % (i * 20), 12, DIM, false, HORIZONTAL_ALIGNMENT_RIGHT, 48.0)
	var gy := lerpf(t1, t0, 38.0 / 120.0)
	draw_line(Vector2(tx - 14.0, gy), Vector2(tx + 10.0, gy), Color(AMBER.r, AMBER.g, AMBER.b, 0.6), 1.5)
	var my := lerpf(t1, t0, clampf(alt / 120.0, 0.0, 1.0))
	draw_colored_polygon(PackedVector2Array([Vector2(tx + 2.0, my), Vector2(tx + 16.0, my - 7.0), Vector2(tx + 16.0, my + 7.0)]), Color(0.9, 0.97, 1.0))


func _seq(r: Rect2, d: Dictionary) -> void:
	var o := r.position
	var tl: float = float(d.get("t_land", 0.0))
	var landed: bool = bool(d.get("landed", false))
	_text(o + Vector2(14, 30), "İNİŞE", 20, CYAN, true)
	if landed:
		_text(o + Vector2(14, 98), "İNDİ", 52, GOOD, true)
	else:
		_text(o + Vector2(14, 98), "%.1f s" % tl, 52, AMBER if tl < 2.0 else Color(0.9, 0.97, 1.0), true)
	var steps := [["KENET", d.get("released", false)], ["AYRILMA", d.get("ignited", false)], ["ANA MOTOR", d.get("retro", false)],
			["RETRO", d.get("gear", false)], ["İNİŞ TAKIMI", landed], ["RAMPA", d.get("door_open", false)]]
	var now := -1
	for i in steps.size():
		if not bool(steps[i][1]):
			now = i
			break
	for i2 in steps.size():
		var y := o.y + 128.0 + float(i2) * 21.0
		var done: bool = bool(steps[i2][1])
		var col := GOOD if done else (AMBER if i2 == now else Color(DIM.r, DIM.g, DIM.b, 0.55))
		var m := Vector2(o.x + 24.0, y - 5.0)
		if done:
			draw_polyline(PackedVector2Array([m + Vector2(-6, 0), m + Vector2(-2, 4), m + Vector2(6, -5)]), col, 2.5)
		elif i2 == now:
			if _blink(2.5):
				draw_colored_polygon(PackedVector2Array([m + Vector2(-5, -6), m + Vector2(6, 0), m + Vector2(-5, 6)]), col)
		else:
			draw_circle(m, 2.5, col)
		_text(Vector2(o.x + 40.0, y), str(steps[i2][0]), 15, col, i2 == now)


func _wall(r: Rect2, d: Dictionary) -> void:
	var o := r.position
	var left: float = float(d.get("respawn_in", 0.0))
	var door_open: bool = bool(d.get("door_open", false))
	_text(o + Vector2(32, 72), "YENİDEN DOĞUŞ", 46, CYAN, true)
	_text(o + Vector2(34, 112), "İniş Gemisi  ·  %s" % str(d.get("reg", "İG")), 24, DIM)
	_text(o + Vector2(28, 372), "%d" % ceili(maxf(left, 0.0)), 230, Color(0.92, 0.97, 1.0), true)
	var dc := GOOD if door_open else (BAD if _blink(1.2) else Color(BAD.r, BAD.g, BAD.b, 0.6))
	var bx := Rect2(o + Vector2(540, 46), Vector2(450, 140))
	draw_rect(bx, Color(dc.r, dc.g, dc.b, 0.12))
	draw_rect(bx, dc, false, 4.0)
	_text(bx.position + Vector2(24, 46), "KAPI", 26, DIM, true)
	_text(bx.position + Vector2(24, 112), "AÇIK — ÇIKIŞ" if door_open else "KİLİTLİ", 44, dc, true)
	# Descent progress, altitude, phase.
	var p: float = clampf(float(d.get("progress", 0.0)), 0.0, 1.0)
	_text(o + Vector2(540, 252), "TAŞIYICI", 18, DIM)
	_text(o + Vector2(990 - 160, 252), "ÜS", 18, DIM, false, HORIZONTAL_ALIGNMENT_RIGHT, 160.0)
	var bar := Rect2(o + Vector2(540, 266), Vector2(450, 24))
	draw_rect(bar, Color(1, 1, 1, 0.08))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * p, bar.size.y)), AMBER)
	_text(o + Vector2(540, 340), "İrtifa %d m" % maxi(int(round(float(d.get("alt", 0.0)))), 0), 30, Color(0.9, 0.97, 1.0), true)
	_text(o + Vector2(540, 380), str(d.get("phase", "")), 24, AMBER)
	_text(o + Vector2(32, 470), "İNİŞTE OTURUN  ·  KEMER TAKIN", 24, Color(AMBER.r, AMBER.g, AMBER.b, 0.85), true)
