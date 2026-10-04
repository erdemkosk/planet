extends Control
## Flight markers of the Mekik (skiff.gd), in its own CanvasLayer under the HUD; only while seated.
##   - aim ring (where the mouse points the nose), nose cross, flight-path marker (where the ship
##     is actually going) once it moves
##   - chase view (V): a compact readout, since the dash is out of sight there
##   - a controls line after boarding (fades), the lift-off hint while landed
## Everything else stays on the instruments in the cockpit.

const UI := preload("res://scripts/ui/ui_style.gd")

var ship                     # skiff.gd
var _f: Font
var _fb: Font


func _ready() -> void:
	_f = UI.font(500)
	_fb = UI.font(700)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if ship == null or not is_instance_valid(ship) or ship.pilot == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var vs := size
	var fade: float = ship.eye_fade()
	if fade > 0.01:
		draw_rect(Rect2(Vector2.ZERO, vs), Color(0.03, 0.03, 0.035, fade * 0.95))
	var cpos := cam.global_position
	var flying: bool = not ship.landed
	if flying and not ship.free_looking():
		var nose: Vector3 = ship.nose_dir()
		var aim: Vector3 = ship.aim_dir()
		var pn := _proj(cam, cpos + nose * 200.0)
		var pa := _proj(cam, cpos + aim * 200.0)
		if pn.x > -9000.0:
			var c := Color(0.9, 0.95, 1.0, 0.75)
			draw_line(pn + Vector2(-9, 0), pn + Vector2(-3, 0), c, 2.0)
			draw_line(pn + Vector2(3, 0), pn + Vector2(9, 0), c, 2.0)
			draw_line(pn + Vector2(0, 3), pn + Vector2(0, 8), c, 2.0)
		if pa.x > -9000.0:
			draw_arc(pa, 11.0, 0.0, TAU, 32, Color(1.0, 0.72, 0.3, 0.85), 2.0)
			if pn.x > -9000.0 and pa.distance_to(pn) > 26.0:
				draw_dashes(pn, pa, Color(1.0, 0.72, 0.3, 0.3))
		var v: Vector3 = ship.hud_velocity()
		if v.length() > 2.5:
			var pv := _proj(cam, cpos + v.normalized() * 200.0)
			if pv.x > -9000.0:
				var g := Color(0.45, 0.95, 0.6, 0.8)
				draw_arc(pv, 6.0, 0.0, TAU, 20, g, 2.0)
				draw_line(pv + Vector2(-14, 0), pv + Vector2(-6, 0), g, 2.0)
				draw_line(pv + Vector2(6, 0), pv + Vector2(14, 0), g, 2.0)
				draw_line(pv + Vector2(0, -6), pv + Vector2(0, -12), g, 2.0)
	if ship.chase_view:
		var line := "%d m/s  ·  İrtifa %s  ·  Gövde %d%%" % [roundi(ship.hud_velocity().length()), ship.clearance_text(),
				roundi(ship.hp / ship.hp_max * 100.0)]
		_text(Vector2(vs.x * 0.5, vs.y - 92.0), line, 17, UI.TEXT, _fb)
	var hint: String = ship.hint_text()
	if hint != "":
		var a: float = ship.hint_alpha()
		_text(Vector2(vs.x * 0.5, vs.y - 58.0), hint, 14, Color(UI.DIM, a), _f)
	var big: String = ship.center_text()
	if big != "":
		_text(Vector2(vs.x * 0.5, vs.y * 0.5 + 70.0), big, 18, Color(UI.WARN, 0.95), _fb)


func draw_dashes(a: Vector2, b: Vector2, c: Color) -> void:
	var d := b - a
	var n := int(d.length() / 10.0)
	for i in n:
		if i % 2 == 0:
			draw_line(a + d * (float(i) / n), a + d * (float(i + 1) / n), c, 1.5)


## Screen point of a world point, or (-9999, -9999) behind the camera / off screen.
func _proj(cam: Camera3D, p: Vector3) -> Vector2:
	if cam.is_position_behind(p):
		return Vector2(-9999, -9999)
	var s := cam.unproject_position(p)
	if s.x < -40.0 or s.y < -40.0 or s.x > size.x + 40.0 or s.y > size.y + 40.0:
		return Vector2(-9999, -9999)
	return s


func _text(p: Vector2, s: String, sz: int, col: Color, f: Font) -> void:
	var tw := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var at := Vector2(p.x - tw * 0.5, p.y)
	draw_string(f, at + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, Color(0, 0, 0, 0.55 * col.a))
	draw_string(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)
