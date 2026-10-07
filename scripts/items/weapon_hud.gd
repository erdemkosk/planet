extends Node
## Screen overlay for the weapon_base.gd guns (like rifle_hud.gd): a crosshair that shows the real
## cone of fire (a pellet circle for the shotgun, ticks otherwise), the reload ring and the empty
## warning, the fire mode for a moment after a switch. The ammo count is in the main HUD's weapon
## plate (scripts/ui/hud.gd); hit markers come from HitFeel
## (scripts/ui/combat_hud.gd).
## HUD level (scripts/ui/hud_level.gd): Sade = the crosshair (its ring / ladder / range finder mark),
## the reload ring and a compact empty / overheat warning; Normal = + the fire mode and attachment
## tags for a moment after a change, the reload text, the range finder distance; Detaylı = everything.

const UI := preload("res://scripts/ui/ui_style.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")

var weapon                        # owner (scripts/items/weapon_base.gd subclass)
var _layer: CanvasLayer
var _top: Control
var _t := 0.0
var _empty_t := 0.0
var _mode_t := 0.0
var _att_t := 0.0                 # the attachment tag after a fit (scripts/items/attachments.gd)
var _font: Font
var _font_b: Font


func _ready() -> void:
	_font = UI.font(500)
	_font_b = UI.font(700)
	if weapon != null and weapon.has_signal("attachments_changed"):
		weapon.attachments_changed.connect(func(_s: Dictionary) -> void: _att_t = 1.8)
	_layer = CanvasLayer.new()
	_layer.add_to_group("gameplay_overlay")       # hidden on the end screen / menus (overlay_guard.gd)
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
	_att_t = maxf(_att_t - delta, 0.0)
	_top.visible = weapon != null and weapon.hud_visible()
	if _top.visible:
		_top.queue_redraw()


## Drawn in the design system's look (scripts/ui/ui_style.gd), scaled with the window height.
func _draw_top() -> void:
	var vs := _top.size
	var c := (vs * 0.5).round()
	var k := UI.scale_k(vs)
	var col: Color = weapon.accent_color()
	var lv := HudLevel.shown_level()
	_draw_crosshair(c, col)
	# What is fitted, for a moment after an attachment change (the middle mouse radial). Normal+.
	if _att_t > 0.0 and weapon.has_method("attachment_text") and lv >= HudLevel.NORMAL:
		var ak := clampf(_att_t / 0.5, 0.0, 1.0)
		var at := str(weapon.attachment_text())
		var s2 := UI.upper_tr("EKLENTİ  ·  " + (at if at != "" else "yok"))
		var fsz2 := UI.fs(11.0, k)
		var f2 := UI.font_caps(700, 1)
		var r2 := Rect2(c + Vector2(40.0, 36.0) * k, Vector2(UI.text_w(f2, s2, fsz2) + 14.0 * k, fsz2 + 9.0 * k))
		UI.draw_chamfer(_top, r2, 4.0 * k, Color(UI.GLASS, 0.6 * ak), Color(UI.SCREEN_CYAN, 0.5 * ak))
		UI.draw_text(_top, f2, r2.position + Vector2(7.0 * k, fsz2 + 3.0 * k), s2, fsz2, Color(UI.SCREEN_CYAN.lightened(0.3), ak), 2)
	# The fire mode for a moment after a switch (B: "TEK" / "SERİ").
	if _mode_t > 0.0 and weapon.has_method("mode_text") and str(weapon.mode_text()) != "" and lv >= HudLevel.NORMAL:
		var sk := clampf(_mode_t / 0.5, 0.0, 1.0)
		var s := str(weapon.mode_text())
		var fsz := UI.fs(11.0 + 3.0 * sk, k)
		var f := UI.font_caps(700, 1)
		var tw := UI.text_w(f, s, fsz)
		var r := Rect2(c + Vector2(40.0, 10.0) * k, Vector2(tw + 14.0 * k, fsz + 9.0 * k))
		UI.draw_chamfer(_top, r, 4.0 * k, Color(UI.GLASS, 0.6 * sk), Color(col, 0.6 * sk))
		UI.draw_text(_top, f, r.position + Vector2(7.0 * k, fsz + 3.0 * k), s, fsz, Color(col.lightened(0.35), sk), 2)
	if weapon.reloading:
		var p: float = weapon.reload_progress()
		UI.draw_ring(_top, c, 26.0 * k, p, Color(col.lerp(UI.SUIT_ORANGE, 0.35), 0.95), maxf(3.0 * k, 2.0))
		if lv >= HudLevel.NORMAL:
			UI.draw_text_c(_top, UI.font_caps(700, 2), c + Vector2(0, 54.0 * k), str(weapon.reload_label()), UI.fs(12, k),
					Color(col.lightened(0.3), 0.92), 3)
	elif weapon.get("overheated") == true:
		var blink := 0.55 + 0.45 * sin(_t * 10.0)
		UI.draw_text_c(_top, UI.font_caps(800, 2), c + Vector2(0, 52.0 * k), "AŞIRI ISINDI", UI.fs(15, k), Color(UI.SUIT_ORANGE, blink), 3)
	elif weapon.mag <= 0:
		var blink2 := 0.55 + 0.45 * sin(_t * 9.0)
		var msg := "BOŞ  ·  R" if weapon.reserve_count() > 0 else "FİŞEK YOK  ·  kazıp malzeme topla"
		if lv == HudLevel.SADE and weapon.reserve_count() <= 0:
			msg = "FİŞEK YOK"
		UI.draw_text_c(_top, _font_b, c + Vector2(0, 48.0 * k), msg, UI.fs(14, k), Color(UI.CRIT.lightened(0.1), blink2), 3)


func _draw_crosshair(c: Vector2, col: Color) -> void:
	var k := UI.scale_k(_top.size)
	# Gone by half way up (the sight takes over; a half-faded crosshair over the optic read as stray lines).
	var a := 1.0 - smoothstep(0.04, 0.45, float(weapon.ads)) * (0.0 if weapon.crosshair_style == "minigun" else 1.0)
	a *= 1.0 - float(weapon.get("_sprint_w"))
	a *= 0.4 if weapon.reloading else 1.0
	var cam: Camera3D = weapon.player.camera if weapon.player != null else null
	var fov := deg_to_rad(cam.fov if cam != null else 75.0)
	var px: float = tan(weapon.current_spread()) / tan(fov * 0.5) * _top.size.y * 0.5
	var ol := Color(UI.OUTLINE, 0.7 * a)
	var tc := Color(0.95, 0.97, 0.98, 0.92 * a)
	var w := maxf(2.0 * k, 1.5)
	match weapon.crosshair_style:
		"circle":
			if a > 0.02:
				var r := clampf(px, 8.0 * k, 140.0 * k)
				_top.draw_arc(c, r, 0, TAU, 56, ol, w + 1.5, true)
				_top.draw_arc(c, r, 0, TAU, 56, Color(tc, 0.75 * a), w * 0.8, true)
				for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
					var dv: Vector2 = d
					_top.draw_line(c + dv * (r - 5.0 * k), c + dv * (r + 7.0 * k), ol, w + 2.0, true)
					_top.draw_line(c + dv * (r - 4.0 * k), c + dv * (r + 6.0 * k), tc, w, true)
		"launcher":
			if a > 0.02:
				# Range ladder: tick marks for 25 / 50 / 75 m drops below the aim point.
				_top.draw_line(c + Vector2(-14, 0) * k, c + Vector2(14, 0) * k, ol, w + 2.0, true)
				_top.draw_line(c + Vector2(-14, 0) * k, c + Vector2(14, 0) * k, tc, w, true)
				_top.draw_line(c + Vector2(0, -8) * k, c + Vector2(0, 46) * k, Color(tc, 0.5 * a), 1.2 * k, true)
				for i in 3:
					var y := (12.0 + i * 13.0) * k
					var hw := (9.0 - i * 2.0) * k
					_top.draw_line(c + Vector2(-hw, y), c + Vector2(hw, y), Color(tc, 0.75 * a), 1.6 * k, true)
					UI.draw_text(_top, _font, c + Vector2(hw + 4.0 * k, y + 4.0 * k), "%d" % (25 * (i + 1)), UI.fs(9, k), Color(tc, 0.7 * a), 2)
		_:
			var g := clampf(px, 3.0 * k, 90.0 * k) + 3.0 * k
			var l := 7.0 * k
			if a > 0.02:
				for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
					var dv: Vector2 = d
					_top.draw_line(c + dv * (g - 1.0), c + dv * (g + l + 1.0), ol, w + 2.0, true)
					_top.draw_line(c + dv * g, c + dv * (g + l), tc, w, true)
	if a > 0.02:
		_top.draw_circle(c, 2.4 * k, ol)
		_top.draw_circle(c, 1.5 * k, Color(col.lightened(0.4), a))
	# Spin-up ring (HMG).
	if weapon.get("spin") != null and float(weapon.spin) > 0.01:
		var s: float = weapon.spin
		UI.draw_ring(_top, c, 34.0 * k, s, Color(col, 0.35 + 0.4 * s), maxf(2.0 * k, 1.5), false)
	# Launcher range finder: predicted impact point.
	if weapon.has_method("aim_preview"):
		var ip: Vector3 = weapon.aim_preview()
		if ip != Vector3.INF and cam != null and not cam.is_position_behind(ip):
			var sp := cam.unproject_position(ip)
			var pulse := 0.6 + 0.4 * sin(_t * 6.0)
			var oc := UI.SUIT_ORANGE
			_top.draw_arc(sp, 10.0 * k, 0, TAU, 32, Color(UI.OUTLINE, 0.5), w + 2.0, true)
			_top.draw_arc(sp, 10.0 * k, 0, TAU, 32, Color(oc, 0.9 * pulse), w, true)
			_top.draw_circle(sp, 2.0 * k, Color(oc.lightened(0.2), 0.9))
			if HudLevel.shown_level() >= HudLevel.NORMAL:
				var dist := cam.global_position.distance_to(ip)
				UI.draw_text(_top, UI.font_num(700), sp + Vector2(14.0, 4.0) * k, "%d m" % int(dist), UI.fs(11, k), Color(oc.lightened(0.3), 0.92), 3)
	if weapon.player != null and weapon.player.get("interact_target") != null:
		var rc := Color(UI.SUIT_ORANGE.lightened(0.15), 0.9 * a)
		_top.draw_arc(c, 18.0 * k, 0, TAU, 40, Color(UI.OUTLINE, 0.5 * a), w + 2.0, true)
		_top.draw_arc(c, 18.0 * k, 0, TAU, 40, rc, w * 0.8, true)


func _text(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	UI.draw_text(_top, f, p, s, size, col, 3)


func _text_c(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	UI.draw_text_c(_top, f, p, s, size, col, 3)
