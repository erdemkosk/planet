extends Control
## Wrist computer screen content, drawn into a small SubViewport that the view model shows on the
## left forearm. Only re-rendered when the shown values change.

const UI := preload("res://scripts/ui/ui_style.gd")

var fuel := 1.0
var soil := 0.0
var soil_max := 400.0
var grav := 1.0
var item := ""
var item_color := Color(1, 0.6, 0.2)
var blink := false
var lamp := 1.0
var lamp_on := false

var _key := ""


## Returns true when something changed (the caller then re-renders the viewport).
func set_values(f: float, s: float, smax: float, g: float, it: String, ic: Color, b: bool, lb := 1.0, lon := false) -> bool:
	var key := "%d|%d|%d|%.2f|%s|%s|%s|%d|%s" % [int(f * 50.0), int(s), int(smax), g, it, ic.to_html(), b, int(lb * 100.0), lon]
	if key == _key:
		return false
	_key = key
	fuel = f
	soil = s
	soil_max = smax
	grav = g
	item = it
	item_color = ic
	blink = b
	lamp = lb
	lamp_on = lon
	queue_redraw()
	return true


func _seg_bar(y: float, frac: float, col: Color) -> void:
	var w := size.x - 32.0
	var n := 12
	var gap := 4.0
	var bw := (w - gap * (n - 1)) / n
	for i in n:
		var on := (i + 0.5) / n <= frac
		var c := col if on else Color(col.r, col.g, col.b, 0.13)
		draw_rect(Rect2(16.0 + i * (bw + gap), y, bw, 16.0), c)


func _draw() -> void:
	var w := size.x
	var h := size.y
	var bold := UI.font(700)
	var reg := UI.font(500)
	draw_rect(Rect2(0, 0, w, h), Color(0.015, 0.045, 0.06))
	for y in range(0, int(h), 6):
		draw_rect(Rect2(0, y, w, 1), Color(0.3, 0.8, 1.0, 0.035))
	draw_rect(Rect2(0, 0, w, 8), Color(1.0, 0.55, 0.18))
	var cyan := Color(0.4, 0.92, 1.0)
	var warn := fuel < 0.25
	var fcol := Color(1.0, 0.4, 0.3) if warn else cyan
	draw_string(reg, Vector2(16, 48), "JETPACK", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(0.6, 0.75, 0.85))
	draw_string(bold, Vector2(16, 50), "%d%%" % int(fuel * 100.0), HORIZONTAL_ALIGNMENT_RIGHT, w - 32, 36, fcol)
	_seg_bar(64, fuel, fcol)
	var scol := Color(1.0, 0.65, 0.28)
	draw_string(reg, Vector2(16, 128), "MALZEME", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(0.6, 0.75, 0.85))
	draw_string(bold, Vector2(16, 130), "%d" % int(soil), HORIZONTAL_ALIGNMENT_RIGHT, w - 32, 36, scol)
	_seg_bar(144, soil / maxf(soil_max, 1.0), scol)
	draw_rect(Rect2(16, 184, w - 32, 2), Color(0.4, 0.9, 1.0, 0.25))
	draw_string(bold, Vector2(16, 226), "%.2f g" % grav, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(0.85, 0.95, 1.0))
	var lcol := Color(1.0, 0.92, 0.7) if lamp_on else Color(0.5, 0.62, 0.72)
	draw_string(reg, Vector2(16, 212), "FENER", HORIZONTAL_ALIGNMENT_RIGHT, w - 32, 16, Color(0.5, 0.62, 0.72))
	draw_string(bold, Vector2(16, 236), "AÇIK" if lamp_on else "KAPALI", HORIZONTAL_ALIGNMENT_RIGHT, w - 32, 24, lcol)
	draw_rect(Rect2(16, 248, w - 32, 44), Color(item_color.r, item_color.g, item_color.b, 0.16))
	draw_rect(Rect2(16, 248, 5, 44), item_color)
	draw_string(bold, Vector2(30, 279), item, HORIZONTAL_ALIGNMENT_LEFT, w - 46, 22, item_color.lightened(0.3))
	var led := Color(1.0, 0.35, 0.25) if (warn and blink) else Color(0.3, 1.0, 0.5)
	draw_circle(Vector2(w - 22, 20), 6, led)
