extends Node
## Screen overlay for the weapon_base.gd guns (like rifle_hud.gd): a crosshair that shows the real
## cone of fire (a pellet circle for the shotgun, ticks otherwise), the reload ring and the empty
## warning. The ammo count is in the main HUD's right panel; hit markers come from HitFeel
## (scripts/ui/combat_hud.gd).

const UI := preload("res://scripts/ui/ui_style.gd")

var weapon                        # owner (scripts/items/weapon_base.gd subclass)
var _layer: CanvasLayer
var _top: Control
var _t := 0.0
var _empty_t := 0.0
var _mode_t := 0.0
var _font: Font
var _font_b: Font


func _ready() -> void:
	_font = UI.font(500)
	_font_b = UI.font(700)
	_layer = CanvasLayer.new()
	_layer.layer = 11
	add_child(_layer)
	_top = Control.new()
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_top.draw.connect(_draw_top)
	_layer.add_child(_top)


func empty_flash() -> void:
	_empty_t = 1.0


func mode_switched() -> void:
	_mode_t = 1.4


func _process(delta: float) -> void:
	_t += delta
	_empty_t = maxf(_empty_t - delta, 0.0)
	_mode_t = maxf(_mode_t - delta, 0.0)
	_top.visible = weapon != null and weapon.hud_visible()
	if _top.visible:
		_top.queue_redraw()


func _draw_top() -> void:
	var vs := _top.size
	var c := vs * 0.5
	var col: Color = weapon.accent_color()
	_draw_crosshair(c, col)
	if weapon.reloading:
		var p: float = weapon.reload_progress()
		_top.draw_arc(c, 26.0, -PI * 0.5, -PI * 0.5 + TAU, 48, Color(0, 0, 0, 0.35), 4.0, true)
		_top.draw_arc(c, 26.0, -PI * 0.5, -PI * 0.5 + TAU * p, 48, Color(col, 0.95), 3.0, true)
		_text_c(c + Vector2(0, 52), weapon.reload_label(), 13, Color(col.lightened(0.3), 0.9), _font_b)
	elif weapon.get("overheated") == true:
		var blink := 0.55 + 0.45 * sin(_t * 10.0)
		_text_c(c + Vector2(0, 50), "AŞIRI ISINDI", 15, Color(1.0, 0.45, 0.25, blink), _font_b)
	elif weapon.mag <= 0:
		var blink2 := 0.55 + 0.45 * sin(_t * 9.0)
		var msg := "BOŞ  ·  R" if weapon.reserve_count() > 0 else "FİŞEK YOK  ·  kazıp malzeme topla"
		_text_c(c + Vector2(0, 46), msg, 14, Color(1.0, 0.42, 0.36, blink2), _font_b)


func _draw_crosshair(c: Vector2, col: Color) -> void:
	var a := 1.0 - clampf(weapon.ads, 0.0, 1.0) * (0.0 if weapon.crosshair_style == "minigun" else 1.0)
	a *= 1.0 - float(weapon.get("_sprint_w"))
	a *= 0.4 if weapon.reloading else 1.0
	var cam: Camera3D = weapon.player.camera if weapon.player != null else null
	var fov := deg_to_rad(cam.fov if cam != null else 75.0)
	var px: float = tan(weapon.current_spread()) / tan(fov * 0.5) * _top.size.y * 0.5
	var shadow := Color(0, 0, 0, 0.55 * a)
	var tc := Color(0.95, 0.97, 1.0, 0.9 * a)
	match weapon.crosshair_style:
		"circle":
			if a > 0.02:
				var r := clampf(px, 8.0, 140.0)
				_top.draw_arc(c + Vector2(1, 1), r, 0, TAU, 56, shadow, 3.0, true)
				_top.draw_arc(c, r, 0, TAU, 56, Color(tc, 0.75 * a), 1.6, true)
				for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
					var dv: Vector2 = d
					_top.draw_line(c + dv * (r - 4.0), c + dv * (r + 6.0), tc, 2.0, true)
		"launcher":
			if a > 0.02:
				# Range ladder: tick marks for 25 / 50 / 75 m drops below the aim point.
				_top.draw_line(c + Vector2(-14, 0), c + Vector2(14, 0), tc, 2.0, true)
				_top.draw_line(c + Vector2(0, -8), c + Vector2(0, 46), Color(tc, 0.5 * a), 1.2, true)
				for k in 3:
					var y := 12.0 + k * 13.0
					var w := 9.0 - k * 2.0
					_top.draw_line(c + Vector2(-w, y), c + Vector2(w, y), Color(tc, 0.75 * a), 1.6, true)
					_text(c + Vector2(w + 4.0, y + 4.0), "%d" % (25 * (k + 1)), 9, Color(tc, 0.6 * a), _font)
		_:
			var g := clampf(px, 3.0, 90.0) + 3.0
			var l := 7.0
			if a > 0.02:
				for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
					var dv: Vector2 = d
					_top.draw_line(c + dv * g + Vector2(1, 1), c + dv * (g + l) + Vector2(1, 1), shadow, 3.0, true)
					_top.draw_line(c + dv * g, c + dv * (g + l), tc, 2.0, true)
	if a > 0.02:
		_top.draw_circle(c + Vector2(1, 1), 1.9, shadow)
		_top.draw_circle(c, 1.4, Color(col.lightened(0.4), a))
	# Spin-up ring (HMG).
	if weapon.get("spin") != null and float(weapon.spin) > 0.01:
		var s: float = weapon.spin
		_top.draw_arc(c, 34.0, -PI * 0.5, -PI * 0.5 + TAU * s, 48, Color(col, 0.35 + 0.4 * s), 2.0, true)
	# Launcher range finder: predicted impact point.
	if weapon.has_method("aim_preview"):
		var ip: Vector3 = weapon.aim_preview()
		if ip != Vector3.INF and cam != null and not cam.is_position_behind(ip):
			var sp := cam.unproject_position(ip)
			var pulse := 0.6 + 0.4 * sin(_t * 6.0)
			_top.draw_arc(sp, 10.0, 0, TAU, 32, Color(1.0, 0.5, 0.2, 0.9 * pulse), 2.0, true)
			_top.draw_circle(sp, 2.0, Color(1.0, 0.6, 0.3, 0.9))
			var dist := cam.global_position.distance_to(ip)
			_text(sp + Vector2(14, 4), "%d m" % int(dist), 11, Color(1.0, 0.75, 0.5, 0.9), _font_b)
	if weapon.player != null and weapon.player.get("interact_target") != null:
		_top.draw_arc(c, 18.0, 0, TAU, 40, Color(1.0, 0.85, 0.45, 0.9 * a), 2.0, true)


func _text(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	_top.draw_string(f, p + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.55 * col.a))
	_top.draw_string(f, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _text_c(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_text(p - Vector2(w * 0.5, 0), s, size, col, f)
