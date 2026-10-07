extends CanvasLayer
## The İnşa Aracı's first-time guide (2026-10-06; the user: "herkes anlayabilsin, kullanım kolaylığı"):
## the first time the build tool is held in a run, a compact plate on the left lists the six steps
## with their keys; each one gets a green tick the first time the player does it (build_tool.gd
## guide_steps), and once all six are done the plate says "Hazırsın!" and fades out. H opens / closes
## it again while the tool is held (in the Eğitim Alanı H is the training panel). Owned by
## scripts/war/build_tool.gd (`tool`); group "gameplay_overlay" (overlay_guard.gd hides it with menus).

const UI := preload("res://scripts/ui/ui_style.gd")

## [step id, key cap, text]; the ids are build_tool.gd GUIDE_STEPS.
const ROWS := [["cat", "Q / E", "kategori"], ["pick", "Teker", "yapı seç"], ["variant", "T", "tür"],
		["rotate", "R", "döndür"], ["build", "Sol tık", "kur"], ["free", "Sağ tık + fare", "serbest döndür"]]

var tool                                  # build_tool.gd

var _c: Control
var _a := 0.0
var _t := 0.0
var _ticks := {}                          # step -> 0..1 (the tick's pop)
var _font: Font
var _font_b: Font


func _ready() -> void:
	layer = 6
	_font = UI.font(500)
	_font_b = UI.font(700)
	_c = Control.new()
	_c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_c.add_to_group("gameplay_overlay")
	_c.draw.connect(_draw)
	add_child(_c)


func _process(delta: float) -> void:
	var want: bool = tool != null and is_instance_valid(tool) and bool(tool.call("menu_wanted")) and bool(tool.get("guide_open"))
	_a = move_toward(_a, 1.0 if want else 0.0, delta * (5.0 if want else 3.0))
	_c.visible = _a > 0.001
	if not _c.visible:
		return
	_t += delta
	var steps: Dictionary = tool.get("guide_steps") if tool.get("guide_steps") is Dictionary else {}
	for r in ROWS:
		var id := str(r[0])
		var target := 1.0 if bool(steps.get(id, false)) else 0.0
		_ticks[id] = move_toward(float(_ticks.get(id, 0.0)), target, delta * 4.0)
	_c.queue_redraw()


func _draw() -> void:
	var vs := _c.size
	var k := UI.scale_k(vs)
	var steps: Dictionary = tool.get("guide_steps") if tool != null and tool.get("guide_steps") is Dictionary else {}
	var done := 0
	for r in ROWS:
		if bool(steps.get(str(r[0]), false)):
			done += 1
	var all := done >= ROWS.size()
	var w := 300.0 * k
	var row_h := 30.0 * k
	var h := (58.0 + ROWS.size() * 30.0 + 30.0) * k
	var slide := (1.0 - UI.smooth(_a)) * -24.0 * k
	var r := Rect2(Vector2(24.0 * k + slide, vs.y * 0.3), Vector2(w, h))
	UI.draw_glass(_c, r, k, UI.SUIT_ORANGE, 0.0, _a)
	_c.draw_rect(Rect2(r.position.x + 1.0, r.position.y + 16.0 * k, 3.0 * k, h - 32.0 * k), Color(UI.SUIT_ORANGE, 0.9 * _a))
	var x := r.position.x + 16.0 * k
	var y := r.position.y + 24.0 * k
	UI.draw_text(_c, UI.font_caps(700, 2), Vector2(x, y), "İNŞA NASIL YAPILIR", UI.fs(12, k), Color(UI.SUIT_WHITE, _a), 2)
	UI.draw_text_r(_c, _font, r.end.x - 14.0 * k, y, "%d / %d" % [done, ROWS.size()], UI.fs(12, k), Color(UI.DIM, _a), 2)
	y += 20.0 * k
	UI.draw_text(_c, _font, Vector2(x, y), "Her adımı bir kez dene", UI.fs(12, k), Color(UI.DIM, _a), 2)
	y += 14.0 * k
	for row in ROWS:
		var id := str(row[0])
		var tk := float(_ticks.get(id, 0.0))
		var on := bool(steps.get(id, false))
		var cy := y + row_h * 0.5
		# The tick: an empty ring, a green disc with a check once done (pops in).
		var tc := Vector2(x + 9.0 * k, cy)
		var tr := 8.0 * k
		_c.draw_arc(tc, tr, 0.0, TAU, 24, Color(UI.SUIT_WHITE, 0.35 * _a), maxf(1.2 * k, 1.0), true)
		if tk > 0.0:
			var pr := tr * (0.6 + 0.4 * UI.smooth(tk) + 0.25 * sin(tk * PI))
			_c.draw_circle(tc, pr, Color(UI.GOOD, 0.9 * _a * tk))
			var lw := maxf(2.0 * k, 1.5)
			_c.draw_polyline(PackedVector2Array([tc + Vector2(-0.45, 0.02) * tr, tc + Vector2(-0.1, 0.38) * tr,
					tc + Vector2(0.5, -0.38) * tr]), Color(UI.INK, _a * tk), lw, true)
		var kx := x + 26.0 * k
		var kw := UI.draw_key(_c, Vector2(kx, cy - UI.fs(11, k) * 0.73), str(row[1]), k, on, 0.95 * _a, 11)
		var tcol := Color(UI.DIM, 0.8 * _a) if on else Color(UI.TEXT, _a)
		UI.draw_text(_c, _font_b, Vector2(kx + kw + 8.0 * k, cy + UI.fs(14, k) * 0.36), str(row[2]), UI.fs(14, k), tcol, 2)
		if on:
			var lx0 := kx + kw + 8.0 * k
			var lw2 := UI.text_w(_font_b, str(row[2]), UI.fs(14, k))
			_c.draw_line(Vector2(lx0, cy + 1.0 * k), Vector2(lx0 + lw2 * UI.smooth(tk), cy + 1.0 * k), Color(UI.DIM, 0.6 * _a), maxf(1.0 * k, 1.0))
		y += row_h
	y += 18.0 * k
	if all:
		UI.draw_text(_c, _font_b, Vector2(x, y), "Hazırsın!  ·  H: bu kılavuz", UI.fs(13, k), Color(UI.GOOD, _a), 2)
	else:
		UI.draw_text(_c, _font, Vector2(x, y), "H: kılavuzu aç / kapa", UI.fs(12, k), Color(UI.FAINT, _a), 2)
