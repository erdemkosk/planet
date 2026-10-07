extends Node
## Screen overlay of the Delici Raylı Tüfek (scripts/items/railgun.gd), on top of its weapon_hud.gd
## crosshair:
##   charge ring   around the crosshair while charging (cyan -> violet, a tick at the minimum charge,
##                 white flash at full); after a shot the cooling arc ("SOĞUYOR")
##   scope         at 2.5× (RMB fully in): a round eyepiece (dark outside), a thin reticle with mil ticks,
##                 the charge arc around it, readouts: TOPRAK (soil along the aim) against ERİŞİM (how
##                 much this charge goes through), YÜZEY (distance to where the beam enters the ground),
##                 the charge %
##   x-ray marks   scoped + charging: corner brackets on every enemy the x-ray shows (railgun.gd
##                 xray_marks()), "12 m · toprak 4,0 m"; green when this charge reaches it through the
##                 soil, amber when not

const UI := preload("res://scripts/ui/ui_style.gd")
const Balance := preload("res://scripts/war/balance.gd")

const CYAN := Color(0.38, 0.95, 1.0)
const VIOLET := Color(0.78, 0.45, 1.0)
const OK := Color(0.45, 1.0, 0.6)
const WARN := Color(1.0, 0.66, 0.25)

var weapon                        # railgun.gd
var _layer: CanvasLayer
var _c: Control
var _font: Font
var _font_b: Font
var _t := 0.0
var _full_flash := 0.0
var _was_full := false


func _ready() -> void:
	_font = UI.font(500)
	_font_b = UI.font(700)
	_layer = CanvasLayer.new()
	_layer.add_to_group("gameplay_overlay")       # hidden on the end screen / menus (overlay_guard.gd)
	_layer.layer = 10                     # under weapon_hud.gd (11): its crosshair stays on top
	add_child(_layer)
	_c = Control.new()
	_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_c.draw.connect(_draw)
	_layer.add_child(_c)


func _process(delta: float) -> void:
	_t += delta
	var on: bool = weapon != null and weapon.hud_visible()
	_c.visible = on
	if not on:
		return
	var full: bool = float(weapon.charge) >= 0.999
	if full and not _was_full:
		_full_flash = 1.0
	_was_full = full
	_full_flash = maxf(_full_flash - delta * 3.0, 0.0)
	_c.queue_redraw()


func _draw() -> void:
	var vs := _c.size
	var c := vs * 0.5
	var sk: float = weapon.scope_k()
	if sk > 0.01:
		_draw_scope(c, vs, sk)
	_draw_charge(c, sk)
	_draw_marks(sk)


## Charge ring at the hip (in the scope it rides the eyepiece instead), the cooling arc after a shot.
func _draw_charge(c: Vector2, sk: float) -> void:
	var ch: float = weapon.charge
	var r := lerpf(30.0 * UI.scale_k(_c.size), _c.size.y * 0.205, sk)
	var a := 1.0
	if ch > 0.0:
		var col := CYAN.lerp(VIOLET, ch)
		if ch >= 0.999:
			col = col.lerp(Color.WHITE, 0.35 + 0.35 * sin(_t * 18.0))
		_c.draw_arc(c, r, 0, TAU, 64, Color(0, 0, 0, 0.35 * a), 5.0, true)
		_c.draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * ch, 64, Color(col, 0.95 * a), 3.0, true)
		# The minimum charge tick.
		var mk := -PI * 0.5 + TAU * Balance.RAIL_MIN_CHARGE
		_c.draw_line(c + Vector2(cos(mk), sin(mk)) * (r - 5.0), c + Vector2(cos(mk), sin(mk)) * (r + 5.0),
				Color(1, 1, 1, 0.6 * a), 1.5, true)
		if _full_flash > 0.0:
			_c.draw_arc(c, r + 6.0 * (1.0 - _full_flash), 0, TAU, 64, Color(1, 1, 1, 0.7 * _full_flash), 2.0, true)
		if sk < 0.5:
			var txt := "ŞARJ %d%%" % int(ch * 100.0) if ch < 0.999 else "TAM ŞARJ  ·  bırak: ateş"
			_text_c(c + Vector2(0, r + 22.0), txt, 12, Color(col.lightened(0.3), 0.95), _font_b)
	elif float(weapon.cool) > 0.0 and float(weapon.cool_total) > 0.0:
		var k: float = 1.0 - float(weapon.cool) / float(weapon.cool_total)
		_c.draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * k, 64, Color(VIOLET, 0.4), 2.0, true)
		if sk < 0.5:
			_text_c(c + Vector2(0, r + 22.0), "SOĞUYOR", 11, Color(VIOLET.lightened(0.3), 0.7), _font_b)


## The eyepiece: dark outside the circle, a thin reticle, the readouts.
func _draw_scope(c: Vector2, vs: Vector2, sk: float) -> void:
	var r := vs.y * 0.44
	var w := maxf(vs.x, vs.y) * 1.5
	_c.draw_arc(c, r + w * 0.5, 0, TAU, 128, Color(0.0, 0.0, 0.01, 0.97 * sk), w, false)
	_c.draw_arc(c, r, 0, TAU, 128, Color(0.05, 0.08, 0.12, 0.9 * sk), 6.0, true)
	_c.draw_arc(c, r - 3.0, 0, TAU, 128, Color(CYAN, 0.22 * sk), 1.5, true)
	var lc := Color(CYAN.lightened(0.4), 0.85 * sk)
	var sh := Color(0, 0, 0, 0.5 * sk)
	var gap := 14.0
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		var dv: Vector2 = d
		_c.draw_line(c + dv * gap + Vector2(1, 1), c + dv * (r - 10.0) + Vector2(1, 1), sh, 2.0, true)
		_c.draw_line(c + dv * gap, c + dv * (r - 10.0), Color(lc, lc.a * (0.55 if dv.y < 0.0 else 0.85)), 1.2, true)
	# Mil ticks along the horizontal and lower vertical line.
	for i in range(1, 9):
		var x := float(i) * r * 0.1
		var h := 7.0 if i % 2 == 0 else 4.0
		for sx in [-1.0, 1.0]:
			_c.draw_line(c + Vector2(x * sx, -h), c + Vector2(x * sx, h), Color(lc, 0.6 * sk), 1.0, true)
		_c.draw_line(c + Vector2(-h, x), c + Vector2(h, x), Color(lc, 0.6 * sk), 1.0, true)
	_c.draw_circle(c, 2.0, Color(VIOLET.lightened(0.3), sk))
	# Readouts (right of the reticle) on small glass plates (the design system, scripts/ui/ui_style.gd).
	var k := UI.scale_k(vs)
	var caps := UI.font_caps(700, 2)
	var num := UI.font_num(700)
	var soil: float = weapon.soil_ahead
	var reach: float = weapon.reach()
	var p := c + Vector2(r * 0.42, -r * 0.42)
	var dim := Color(UI.DIM, 0.9 * sk)
	var pr := Rect2(p + Vector2(-10.0, -18.0) * k, Vector2(132.0, 92.0) * k)
	if soil >= 0.0 or float(weapon.surface_ahead) >= 0.0:
		UI.draw_chamfer(_c, pr, 7.0 * k, Color(UI.GLASS, 0.5 * sk), Color(CYAN, 0.3 * sk))
	if soil >= 0.0:
		var col := OK if soil <= reach + 0.01 else WARN
		UI.draw_text(_c, caps, p, "TOPRAK", UI.fs(10, k), dim, 2)
		UI.draw_text(_c, num, p + Vector2(0, 22) * k, "%s m" % String.num(soil, 1).replace(".", ","), UI.fs(19, k), Color(col, sk), 2)
		UI.draw_text(_c, _font, p + Vector2(0, 40) * k, "erişim %s m" % String.num(reach, 1).replace(".", ","), UI.fs(11, k), dim, 2)
	var surf: float = weapon.surface_ahead
	if surf >= 0.0:
		UI.draw_text(_c, caps, p + Vector2(0, 62) * k, "YÜZEY %d m" % int(surf), UI.fs(10, k), dim, 2)
	var ch: float = weapon.charge
	var q := c + Vector2(-r * 0.62, r * 0.5)
	var cc := CYAN.lerp(VIOLET, ch)
	UI.draw_chamfer(_c, Rect2(q + Vector2(-10.0, -18.0) * k, Vector2(84.0, 50.0) * k), 7.0 * k, Color(UI.GLASS, 0.5 * sk),
			Color(cc, 0.35 * sk))
	UI.draw_text(_c, caps, q, "ŞARJ", UI.fs(10, k), dim, 2)
	UI.draw_text(_c, num, q + Vector2(0, 23) * k, "%d%%" % int(ch * 100.0), UI.fs(21, k), Color(cc.lightened(0.3), sk), 2)
	if ch <= 0.0 and float(weapon.cool) <= 0.0:
		UI.draw_text_c(_c, _font, c + Vector2(0, r * 0.62), "sol tık basılı: şarj et  ·  röntgen", UI.fs(12, k), Color(UI.SUIT_WHITE, 0.6 * sk), 3)


## X-ray brackets on the enemies the railgun shows through the soil.
func _draw_marks(sk: float) -> void:
	var cam: Camera3D = weapon.player.camera if weapon.player != null else null
	if cam == null:
		return
	var reach: float = weapon.reach()
	for m in weapon.xray_marks():
		var n = m.get("node")
		if not is_instance_valid(n):
			continue
		var k := float(m.get("k", 0.0)) * maxf(sk, 0.4)
		if k <= 0.02:
			continue
		var wp: Vector3 = (n as Node3D).global_position + (n as Node3D).global_transform.basis.y * 1.0
		if cam.is_position_behind(wp):
			continue
		var sp := cam.unproject_position(wp)
		var top := cam.unproject_position(wp + (n as Node3D).global_transform.basis.y * 0.9)
		var hh := clampf(absf(sp.y - top.y), 12.0, 140.0)
		var hw := hh * 0.55
		var soil := float(m.get("soil", -1.0))
		var col := OK if soil >= 0.0 and soil <= reach + 0.01 else WARN
		col = Color(col, 0.9 * k)
		var l := minf(hw, hh) * 0.45
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				var corner := sp + Vector2(hw * sx, hh * sy)
				_c.draw_line(corner, corner - Vector2(l * sx, 0), col, 2.0, true)
				_c.draw_line(corner, corner - Vector2(0, l * sy), col, 2.0, true)
		var txt := "%d m" % int(m.get("dist", 0.0))
		if soil > 0.05:
			txt += "  ·  toprak %s m" % String.num(soil, 1)
		_text_c(sp + Vector2(0, hh + 16.0), txt, 11, col, _font_b)


## Outlined text (the design system's), the size scaled with the window height.
func _text(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	UI.draw_text(_c, f, p, s, UI.fs(size, UI.scale_k(_c.size)), col, 3)


func _text_c(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	UI.draw_text_c(_c, f, p, s, UI.fs(size, UI.scale_k(_c.size)), col, 3)
