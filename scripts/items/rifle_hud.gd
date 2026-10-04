extends Node
## Screen overlays for the rifle (drawn above the main HUD): spread crosshair, hit marker, reload
## ring and the empty-mag warning. The ammo count itself is in the main HUD's right panel.

const UI := preload("res://scripts/ui/ui_style.gd")

var rifle                         # owner (scripts/items/rifle.gd)
var _layer: CanvasLayer
var _top: Control
var _hit_t := 0.0
var _hit_kind := 0                # 0 hit, 1 headshot, 2 kill, 3 knocked out
var _t := 0.0
var _switch_t := 0.0
var _empty_t := 0.0
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


## kind: 0 hit, 1 headshot, 2 kill, 3 knocked out.
func hit_marker(kind: int) -> void:
	if _hit_t > 0.0 and kind < _hit_kind:
		kind = _hit_kind
	_hit_kind = kind
	_hit_t = 0.5 if kind >= 2 else 0.28


func ammo_switched() -> void:
	_switch_t = 1.4


func empty_flash() -> void:
	_empty_t = 1.0


func _process(delta: float) -> void:
	_t += delta
	_hit_t = maxf(_hit_t - delta, 0.0)
	_switch_t = maxf(_switch_t - delta, 0.0)
	_empty_t = maxf(_empty_t - delta, 0.0)
	_top.visible = rifle != null and rifle.hud_visible()
	if _top.visible:
		_top.queue_redraw()


func _draw_top() -> void:
	if rifle == null:
		return
	var vs := _top.size
	var c := vs * 0.5
	var col: Color = rifle.ammo_color()
	_draw_crosshair(c, col)
	# Hit marker.
	if _hit_t > 0.0:
		var dur := 0.5 if _hit_kind >= 2 else 0.28
		var k := _hit_t / dur
		var mc := Color(1, 1, 1)
		if _hit_kind == 1:
			mc = Color(1.0, 0.85, 0.3)
		elif _hit_kind == 2:
			mc = Color(1.0, 0.25, 0.2)
		elif _hit_kind == 3:
			mc = Color(0.45, 0.9, 1.0)
		var g := 7.0 + (1.0 - k) * 6.0 + (3.0 if _hit_kind >= 2 else 0.0)
		var l := 8.0 + (4.0 if _hit_kind >= 2 else 0.0)
		var w := 2.5 if _hit_kind >= 2 else 2.0
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var dv: Vector2 = (d as Vector2).normalized()
			_top.draw_line(c + dv * g + Vector2(1, 1), c + dv * (g + l) + Vector2(1, 1), Color(0, 0, 0, 0.5 * k), w + 1.0, true)
			_top.draw_line(c + dv * g, c + dv * (g + l), Color(mc, k), w, true)
	# Reload ring around the crosshair / warnings under it.
	if rifle.reloading:
		var p: float = rifle.reload_progress()
		_top.draw_arc(c, 26.0, -PI * 0.5, -PI * 0.5 + TAU, 48, Color(0, 0, 0, 0.35), 4.0, true)
		_top.draw_arc(c, 26.0, -PI * 0.5, -PI * 0.5 + TAU * p, 48, Color(col, 0.95), 3.0, true)
		var txt := "MERMİ DEĞİŞİYOR" if rifle.switching() else "ŞARJÖR DEĞİŞİYOR"
		_text_c(_top, c + Vector2(0, 52), txt, 13, Color(col.lightened(0.3), 0.9), _font_b)
	elif rifle.mag_count() == 0:
		var blink := 0.55 + 0.45 * sin(_t * 9.0)
		var msg := "ŞARJÖR BOŞ  ·  R" if rifle.reserve_count() > 0 else "MERMİ YOK  ·  kazıp malzeme topla"
		_text_c(_top, c + Vector2(0, 46), msg, 14, Color(1.0, 0.42, 0.36, blink), _font_b)


func _text(ci: CanvasItem, p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	ci.draw_string(f, p + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.55 * col.a))
	ci.draw_string(f, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _text_c(ci: CanvasItem, p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_text(ci, p - Vector2(w * 0.5, 0), s, size, col, f)


## Dynamic crosshair: four ticks whose gap shows the real cone of fire (blooms with shots, grows
## while moving, recovers), fading out while aiming down the sights or sprinting.
func _draw_crosshair(c: Vector2, col: Color) -> void:
	var a := 1.0 - clampf(rifle.ads, 0.0, 1.0)
	a *= 1.0 - float(rifle.get("_sprint_w"))
	a *= 0.4 if rifle.reloading else 1.0
	if a <= 0.02:
		return
	var cam: Camera3D = rifle.player.camera if rifle.player != null else null
	var fov := deg_to_rad(cam.fov if cam != null else 75.0)
	var px: float = tan(rifle.current_spread()) / tan(fov * 0.5) * _top.size.y * 0.5
	var g := clampf(px, 3.0, 90.0) + 3.0
	var l := 7.0
	var shadow := Color(0, 0, 0, 0.55 * a)
	var tc := Color(0.95, 0.97, 1.0, 0.9 * a)
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		var dv: Vector2 = d
		_top.draw_line(c + dv * g + Vector2(1, 1), c + dv * (g + l) + Vector2(1, 1), shadow, 3.0, true)
		_top.draw_line(c + dv * g, c + dv * (g + l), tc, 2.0, true)
	_top.draw_circle(c + Vector2(1, 1), 1.9, shadow)
	_top.draw_circle(c, 1.4, Color(col.lightened(0.4), a))
	if rifle.player != null and rifle.player.get("interact_target") != null:
		_top.draw_arc(c, 18.0, 0, TAU, 40, Color(1.0, 0.85, 0.45, 0.9 * a), 2.0, true)
