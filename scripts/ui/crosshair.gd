extends Control
## Center reticle: dot + four ticks tinted by the held item. Ticks spread and spin while the tool
## works, a ring appears over interactable objects, and it dims when the aim is out of range.
## Group "gameplay_overlay": hidden on the end screen, the pause menu and modal panels.

const UI := preload("res://scripts/ui/ui_style.gd")

var color := Color(1, 1, 1)
var using := false
var has_target := false
var valid := true
var pickup_flash := 0.0
var fuel := 1.0                 # jetpack fuel 0..1 (arc shown only while used / refilling)
var jetting := false
var overcharge := false
var _fuel_vis := 0.0
var _fuel_hold := 0.0

var _spread := 0.0
var _spin := 0.0
var _ring := 0.0
var _last := PackedFloat32Array()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Hidden while the match is over / a menu is open (scripts/ui/overlay_guard.gd).
	add_to_group("gameplay_overlay")


func _process(delta: float) -> void:
	_spread = lerpf(_spread, 1.0 if using else 0.0, 1.0 - exp(-12.0 * delta))
	_ring = lerpf(_ring, 1.0 if has_target else 0.0, 1.0 - exp(-14.0 * delta))
	if using:
		_spin += delta * 3.5
	else:
		_spin = lerpf(_spin, roundf(_spin / (PI * 0.5)) * PI * 0.5, 1.0 - exp(-10.0 * delta))
	pickup_flash = maxf(pickup_flash - delta * 2.5, 0.0)
	# Jetpack arc: fades in while jetting or refilling, out a moment after it is full.
	if jetting or fuel < 0.995:
		_fuel_hold = 1.2
	else:
		_fuel_hold = maxf(_fuel_hold - delta, 0.0)
	_fuel_vis = move_toward(_fuel_vis, 1.0 if _fuel_hold > 0.0 else 0.0, delta * (5.0 if _fuel_hold > 0.0 else 2.0))
	var key := PackedFloat32Array([_spread, _ring, _spin, pickup_flash, color.r, color.g, color.b, 1.0 if valid else 0.0, _fuel_vis, fuel, size.y])
	if key != _last:
		_last = key
		queue_redraw()


## Drawn in the design system's look (scripts/ui/ui_style.gd), scaled with the window height: four
## outlined ticks and a centre dot in the item's colour; over an interactable an orange ring with four
## notches (the suit's accent, the prompt's colour); the jetpack arc on the left as 10 segments
## (cyan, amber below 25 %, red below 10 %, orange when overcharged).
func _draw() -> void:
	var k := UI.scale_k(size)
	var c := (size * 0.5).round()
	var a := 0.95 if valid else 0.45
	var col := Color(color.r, color.g, color.b, a)
	var ol := Color(UI.OUTLINE, 0.7 * a)
	var g0 := (6.0 + _spread * 5.0 + pickup_flash * 4.0) * k
	var g1 := g0 + (7.0 - _spread * 1.5) * k
	var w := maxf(2.0 * k, 1.5)
	for i in 4:
		var ang := _spin + i * PI * 0.5
		var d := Vector2(cos(ang), sin(ang))
		draw_line(c + d * (g0 - 1.0), c + d * (g1 + 1.0), ol, w + 2.0, true)
		draw_line(c + d * g0, c + d * g1, col, w, true)
	draw_circle(c, 2.6 * k, ol)
	draw_circle(c, 1.7 * k, Color(1.0, 0.99, 0.97, a))
	if _ring > 0.02:
		var r := (16.0 + (1.0 - _ring) * 8.0) * k
		var rc := Color(UI.SUIT_ORANGE.lightened(0.15), 0.9 * _ring)
		draw_arc(c, r, 0, TAU, 40, Color(UI.OUTLINE, 0.5 * _ring), w + 2.0, true)
		draw_arc(c, r, 0, TAU, 40, rc, w * 0.8, true)
		for q in 4:
			var qa := PI * 0.25 + q * PI * 0.5
			var qd := Vector2(cos(qa), sin(qa))
			draw_line(c + qd * (r + 2.0 * k), c + qd * (r + 6.0 * k), rc, w, true)
	if _spread > 0.05:
		draw_arc(c, g1 + 5.0 * k, _spin * -1.5, _spin * -1.5 + PI * 1.2, 24, Color(color.r, color.g, color.b, 0.35 * _spread), 1.5 * k, true)
	if pickup_flash > 0.0:
		draw_arc(c, (22.0 + (1.0 - pickup_flash) * 14.0) * k, 0, TAU, 40, Color(1.0, 0.99, 0.97, 0.5 * pickup_flash), 2.0 * k, true)
	if _fuel_vis > 0.01:
		var r2 := 32.0 * k
		var a0 := PI * 0.64
		var a1 := PI * 1.36
		var fc := UI.SUIT_ORANGE if overcharge else (UI.CRIT if fuel < 0.1 else (UI.WARN if fuel < 0.25 else UI.SCREEN_CYAN))
		var n := 10
		var gap := 0.025
		var seg := (a1 - a0) / n
		draw_arc(c, r2, a0 - 0.02, a1 + 0.02, 32, Color(UI.OUTLINE, 0.4 * _fuel_vis), 6.0 * k, true)
		for i in n:
			# Fills from the bottom up.
			var s1 := a1 - i * seg
			var s0 := s1 - seg + gap
			var lit := clampf(fuel * n - i, 0.0, 1.0)
			draw_arc(c, r2, s0, s1 - gap, 6, Color(UI.SUIT_WHITE, 0.12 * _fuel_vis), 3.0 * k, true)
			if lit > 0.0:
				draw_arc(c, r2, s1 - gap - (s1 - gap - s0) * lit, s1 - gap, 6, Color(fc, 0.92 * _fuel_vis), 3.0 * k, true)
