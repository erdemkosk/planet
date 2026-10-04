extends Control
## Center reticle: dot + four ticks tinted by the held item. Ticks spread and spin while the tool
## works, a ring appears over interactable objects, and it dims when the aim is out of range.

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
	var key := PackedFloat32Array([_spread, _ring, _spin, pickup_flash, color.r, color.g, color.b, 1.0 if valid else 0.0, _fuel_vis, fuel])
	if key != _last:
		_last = key
		queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var a := 0.95 if valid else 0.45
	var col := Color(color.r, color.g, color.b, a)
	var shadow := Color(0, 0, 0, 0.55 * a)
	var g0 := 6.0 + _spread * 5.0 + pickup_flash * 4.0
	var g1 := g0 + 7.0 - _spread * 1.5
	for i in 4:
		var ang := _spin + i * PI * 0.5
		var d := Vector2(cos(ang), sin(ang))
		draw_line(c + d * g0 + Vector2(1, 1), c + d * g1 + Vector2(1, 1), shadow, 3.0, true)
		draw_line(c + d * g0, c + d * g1, col, 2.0, true)
	draw_circle(c + Vector2(1, 1), 2.4, shadow)
	draw_circle(c, 1.8, Color(1, 1, 1, a))
	if _ring > 0.02:
		var r := 16.0 + (1.0 - _ring) * 8.0
		draw_arc(c, r, 0, TAU, 40, Color(1.0, 0.85, 0.45, 0.9 * _ring), 2.0, true)
	if _spread > 0.05:
		draw_arc(c, g1 + 5.0, _spin * -1.5, _spin * -1.5 + PI * 1.2, 24, Color(color.r, color.g, color.b, 0.35 * _spread), 1.5, true)
	if pickup_flash > 0.0:
		draw_arc(c, 22.0 + (1.0 - pickup_flash) * 14.0, 0, TAU, 40, Color(1, 1, 1, 0.5 * pickup_flash), 2.0, true)
	if _fuel_vis > 0.01:
		var r := 30.0
		var a0 := PI * 0.62
		var a1 := PI * 1.38
		var fc := Color(1.0, 0.75, 0.3) if overcharge else (Color(1.0, 0.42, 0.35) if fuel < 0.2 else Color(0.45, 0.88, 1.0))
		draw_arc(c, r, a0, a1, 32, Color(0, 0, 0, 0.35 * _fuel_vis), 5.0, true)
		draw_arc(c, r, a0, a1, 32, Color(1, 1, 1, 0.12 * _fuel_vis), 3.0, true)
		if fuel > 0.005:
			draw_arc(c, r, a1 - (a1 - a0) * fuel, a1, 32, Color(fc.r, fc.g, fc.b, 0.9 * _fuel_vis), 3.0, true)
