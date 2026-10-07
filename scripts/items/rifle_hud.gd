extends Node
## Screen overlays for the rifle (drawn above the main HUD): spread crosshair, hit marker, reload
## ring, the empty-mag warning and the fire mode tag (TEK / SERİ / ÜÇLÜ · ammo). The ammo count itself
## is in the main HUD's weapon plate (bottom right, scripts/ui/hud.gd).
## HUD level (scripts/ui/hud_level.gd): Sade = the crosshair, hit markers, the reload ring and a
## compact empty warning; Normal = + the fire mode · ammo type tag and the attachment tag for a moment
## after a change, the reload text; Detaylı = everything (the long empty hint too).

const UI := preload("res://scripts/ui/ui_style.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")

var rifle                         # owner (scripts/items/rifle.gd)
var _layer: CanvasLayer
var _top: Control
var _hit_t := 0.0
var _hit_kind := 0                # 0 hit, 1 headshot, 2 kill, 3 knocked out
var _t := 0.0
var _switch_t := 0.0
var _empty_t := 0.0
var _att_t := 0.0                 # the attachment tag after a fit (scripts/items/attachments.gd)
var _font: Font
var _font_b: Font


func _ready() -> void:
	_font = UI.font(500)
	_font_b = UI.font(700)
	if rifle != null and rifle.has_signal("attachments_changed"):
		rifle.attachments_changed.connect(func(_s: Dictionary) -> void: _att_t = 1.8)
	_layer = CanvasLayer.new()
	_layer.add_to_group("gameplay_overlay")       # hidden on the end screen / menus (overlay_guard.gd)
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
	_att_t = maxf(_att_t - delta, 0.0)
	_top.visible = rifle != null and rifle.hud_visible()
	if _top.visible:
		_top.queue_redraw()


## Drawn in the design system's look (scripts/ui/ui_style.gd), scaled with the window height.
func _draw_top() -> void:
	if rifle == null:
		return
	var vs := _top.size
	var c := (vs * 0.5).round()
	var k := UI.scale_k(vs)
	var col: Color = rifle.ammo_color()
	var lv := HudLevel.shown_level()
	_draw_crosshair(c, col)
	# Fire mode and ammo ("SERİ · STD") right of the crosshair: only for a moment after a switch
	# (B, T), then gone (a screenshot review found the always-on tag cluttered). Normal+.
	if rifle.has_method("mode_text") and _switch_t > 0.0 and lv >= HudLevel.NORMAL:
		var sk := clampf(_switch_t / 0.5, 0.0, 1.0)
		var s := "%s  ·  %s" % [rifle.mode_text(), rifle.ammo_short()]
		var fsz := UI.fs(11.0 + 3.0 * sk, k)
		var f := UI.font_caps(700, 1)
		var tw := UI.text_w(f, s, fsz)
		var r := Rect2(c + Vector2(40.0, 10.0) * k, Vector2(tw + 14.0 * k, fsz + 9.0 * k))
		UI.draw_chamfer(_top, r, 4.0 * k, Color(UI.GLASS, 0.6 * sk), Color(col, 0.6 * sk))
		UI.draw_text(_top, f, r.position + Vector2(7.0 * k, fsz + 3.0 * k), s, fsz, Color(col.lightened(0.35), sk), 2)
	# What is fitted, for a moment after an attachment change (the middle mouse radial).
	if _att_t > 0.0 and rifle.has_method("attachment_text") and lv >= HudLevel.NORMAL:
		var ak := clampf(_att_t / 0.5, 0.0, 1.0)
		var at := str(rifle.attachment_text())
		var s2 := UI.upper_tr("EKLENTİ  ·  " + (at if at != "" else "yok"))
		var fsz2 := UI.fs(11.0, k)
		var f2 := UI.font_caps(700, 1)
		var r2 := Rect2(c + Vector2(40.0, 36.0) * k, Vector2(UI.text_w(f2, s2, fsz2) + 14.0 * k, fsz2 + 9.0 * k))
		UI.draw_chamfer(_top, r2, 4.0 * k, Color(UI.GLASS, 0.6 * ak), Color(UI.SCREEN_CYAN, 0.5 * ak))
		UI.draw_text(_top, f2, r2.position + Vector2(7.0 * k, fsz2 + 3.0 * k), s2, fsz2, Color(UI.SCREEN_CYAN.lightened(0.3), ak), 2)
	# Hit marker.
	if _hit_t > 0.0:
		var dur := 0.5 if _hit_kind >= 2 else 0.28
		var hk := _hit_t / dur
		var mc := Color(0.96, 0.97, 0.98)
		if _hit_kind == 1:
			mc = Color(1.0, 0.84, 0.36)
		elif _hit_kind == 2:
			mc = UI.CRIT
		elif _hit_kind == 3:
			mc = UI.SCREEN_CYAN
		var g := (7.0 + (1.0 - hk) * 6.0 + (3.0 if _hit_kind >= 2 else 0.0)) * k
		var l := (8.0 + (4.0 if _hit_kind >= 2 else 0.0)) * k
		var w := (2.5 if _hit_kind >= 2 else 2.0) * k
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var dv: Vector2 = (d as Vector2).normalized()
			_top.draw_line(c + dv * (g - 1.0), c + dv * (g + l + 1.0), Color(UI.OUTLINE, UI.OUTLINE.a * hk), w + 2.5, true)
			_top.draw_line(c + dv * g, c + dv * (g + l), Color(mc, hk), w, true)
	# Reload ring around the crosshair / warnings under it.
	if rifle.reloading:
		var p: float = rifle.reload_progress()
		UI.draw_ring(_top, c, 26.0 * k, p, Color(col.lerp(UI.SUIT_ORANGE, 0.35), 0.95), maxf(3.0 * k, 2.0))
		if lv >= HudLevel.NORMAL:
			var txt := "MERMİ DEĞİŞİYOR" if rifle.switching() else "ŞARJÖR DEĞİŞİYOR"
			UI.draw_text_c(_top, UI.font_caps(700, 2), c + Vector2(0, 54.0 * k), txt, UI.fs(12, k), Color(col.lightened(0.3), 0.92), 3)
	elif rifle.mag_count() == 0:
		var blink := 0.55 + 0.45 * sin(_t * 9.0)
		var msg := "ŞARJÖR BOŞ  ·  R" if rifle.reserve_count() > 0 else "MERMİ YOK  ·  kazıp malzeme topla"
		if lv == HudLevel.SADE:
			msg = "BOŞ  ·  R" if rifle.reserve_count() > 0 else "MERMİ YOK"
		UI.draw_text_c(_top, _font_b, c + Vector2(0, 48.0 * k), msg, UI.fs(14, k), Color(UI.CRIT.lightened(0.1), blink), 3)


func _text(ci: CanvasItem, p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	UI.draw_text(ci, f, p, s, size, col, 3)


func _text_c(ci: CanvasItem, p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	UI.draw_text_c(ci, f, p, s, size, col, 3)


## Dynamic crosshair: four ticks whose gap shows the real cone of fire (blooms with shots, grows
## while moving, recovers), fading out while aiming down the sights or sprinting.
func _draw_crosshair(c: Vector2, col: Color) -> void:
	var k := UI.scale_k(_top.size)
	# Gone by half way up (the sight takes over; a half-faded crosshair over the optic read as stray lines).
	var a := 1.0 - smoothstep(0.04, 0.45, float(rifle.ads))
	a *= 1.0 - float(rifle.get("_sprint_w"))
	a *= 0.4 if rifle.reloading else 1.0
	if a <= 0.02:
		return
	var cam: Camera3D = rifle.player.camera if rifle.player != null else null
	var fov := deg_to_rad(cam.fov if cam != null else 75.0)
	var px: float = tan(rifle.current_spread()) / tan(fov * 0.5) * _top.size.y * 0.5
	var g := clampf(px, 3.0 * k, 90.0 * k) + 3.0 * k
	var l := 7.0 * k
	var w := maxf(2.0 * k, 1.5)
	var ol := Color(UI.OUTLINE, 0.7 * a)
	var tc := Color(0.95, 0.97, 0.98, 0.92 * a)
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		var dv: Vector2 = d
		_top.draw_line(c + dv * (g - 1.0), c + dv * (g + l + 1.0), ol, w + 2.0, true)
		_top.draw_line(c + dv * g, c + dv * (g + l), tc, w, true)
	_top.draw_circle(c, 2.4 * k, ol)
	_top.draw_circle(c, 1.5 * k, Color(col.lightened(0.4), a))
	if rifle.player != null and rifle.player.get("interact_target") != null:
		var rc := Color(UI.SUIT_ORANGE.lightened(0.15), 0.9 * a)
		_top.draw_arc(c, 18.0 * k, 0, TAU, 40, Color(UI.OUTLINE, 0.5 * a), w + 2.0, true)
		_top.draw_arc(c, 18.0 * k, 0, TAU, 40, rc, w * 0.8, true)
