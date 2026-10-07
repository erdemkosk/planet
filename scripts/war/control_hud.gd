extends CanvasLayer
## The control zones on the HUD (scripts/war/control_points.gd), in the design system's look
## (scripts/ui/ui_style.gd), drawn around war_hud.gd's top cluster without touching it:
##   - a chip per zone on each side of the compass ribbon: our planet's zones left of it (under our
##     core bar), the rival planet's right; filled in the owner's colour (ours violet, theirs red,
##     neutral: glass), the letter on it, a thin bar under it while it changes hands (the leading
##     side's colour), a blinking red frame while the enemy stands in one of ours, a pulse while
##     contested;
##   - our zone income under our chips ("BÖLGE +23,5 m³/s", the core pump included);
##   - the capture plate (lower centre) while the local player stands in a zone: its letter and name,
##     what is happening (ELE GEÇİRİLİYOR / ETKİSİZLEŞTİRİLİYOR / ÇEKİŞMELİ / TUTULUYOR · +N m³/s /
##     DÜŞMAN BÖLGESİ) and a two-sided bar (left: theirs, right: ours, a tick at neutral).
## Hidden with the gameplay overlays (Game.overlays_hidden, when present) and after the match.
## HUD density (scripts/ui/hud_mode.gd): the chips and the income line are on their own canvas (_rows)
## and fade with war_hud.gd's top cluster (HudMode "cores": they sit beside its compass). In Sade the
## always-on mini strip of war_hud.gd (_draw_strip) shows the zone owners instead; a zone that changes
## hands, or one on your planet / of ours that turns contested or gets an enemy in it, reveals "zones"
## for ZONE_REVEAL s (the strip lights up). The income line: not in Sade (Alt shows it). The capture
## plate shows in every density.

const UI := preload("res://scripts/ui/ui_style.gd")
const Balance := preload("res://scripts/war/balance.gd")
const HudMode := preload("res://scripts/ui/hud_mode.gd")
const ZONE_REVEAL := 4.0

## war_hud.gd's top cluster (TOP_Y + TOP_H + 6 = the compass ribbon's top; COMPASS_W / H).
const ROW_Y := 76.0
const COMPASS_HALF := 220.0
const CHIP := 20.0
const CHIP_GAP := 4.0

var cp                                   # control_points.gd
var _c: Control
var _rows: Control                       # the chips + the income line (they fade in Sade)
var _zstate := {}                        # "preset:i" -> the zone's last [owner, contested, enemy in ours]
var _t := 0.0
var _redraw := 0.0
var _font: Font
var _font_b: Font
var _font_n: Font


func _ready() -> void:
	layer = 6
	_rows = Control.new()
	_rows.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows.draw.connect(_draw_rows)
	add_child(_rows)
	_c = Control.new()
	_c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_c.draw.connect(_draw_all)
	add_child(_c)
	add_to_group("gameplay_overlay")
	_font = UI.font(500)
	_font_b = UI.font_caps(700, 1)
	_font_n = UI.font_num(700)


func _process(delta: float) -> void:
	_t += delta
	_redraw -= delta
	if _redraw <= 0.0:
		_redraw = 1.0 / 20.0
		_watch_zones()
		_c.queue_redraw()
		if _rows.modulate.a > 0.0:
			_rows.queue_redraw()
	HudMode.fade(_rows, HudMode.shown("cores"), 0.2, 0.7)


## Sade: a zone that changes hands (anywhere), or one on your planet / of ours that turns contested or
## gets an enemy in it, reveals "zones" for ZONE_REVEAL s (war_hud.gd's strip lights up).
func _watch_zones() -> void:
	if cp == null or not is_instance_valid(cp) or not (cp.get("zones") is Array):
		return
	var pl = Game.player
	var here: Node3D = Game.dominant_body((pl as Node3D).global_position) if pl != null and is_instance_valid(pl) else null
	for z in cp.zones:
		var key := "%s:%d" % [str(z["preset"]), int(z["i"])]
		var own := str(z["owner"])
		var st := [own, bool(z["contested"]), own == "home" and int(z["r"]) > 0]
		if _zstate.has(key):
			var was: Array = _zstate[key]
			var near: bool = z["body"] == here or own == "home" or str(was[0]) == "home"
			if own != str(was[0]) or (near and ((st[1] and not was[1]) or (st[2] and not was[2]))):
				HudMode.reveal("zones", ZONE_REVEAL)
		_zstate[key] = st


func _hidden() -> bool:
	if Game.match_over:
		return true
	var oh = Game.overlays_hidden() if Game.has_method("overlays_hidden") else false
	return oh is bool and oh


func _draw_all() -> void:
	if cp == null or not is_instance_valid(cp) or _hidden():
		return
	_plate(_c.size, UI.scale_k(_c.size))


## The chips and the income line on their own canvas (the drawing helpers draw on `_c`, so it points
## at `_rows` meanwhile).
func _draw_rows() -> void:
	if cp == null or not is_instance_valid(cp) or _hidden():
		return
	var keep := _c
	_c = _rows
	var vs := _c.size
	var k := UI.scale_k(vs)
	var cx := vs.x * 0.5
	var y := ROW_Y * k
	_row(cp.zones_of(Game.planet), cx - (COMPASS_HALF + 10.0) * k, y, k, true)
	_row(cp.zones_of(Game.rival), cx + (COMPASS_HALF + 10.0) * k, y, k, false)
	if HudMode.mode() != HudMode.SADE or HudMode.peek():
		var inc: float = cp.income_rate("home")
		var s := "BÖLGE +%s m³/s" % String.num(inc, 1).replace(".", ",")
		UI.draw_text_r(_c, _font_b, cx - (COMPASS_HALF + 10.0) * k, y + (CHIP + 17.0) * k, s, UI.fs(11, k), UI.GOOD, 2)
	_c = keep


## A row of zone chips: `right_edge` = the anchor (our row grows leftward from it, theirs rightward).
func _row(zs: Array, anchor: float, y: float, k: float, leftward: bool) -> void:
	var n := zs.size()
	for i in n:
		var z: Dictionary = zs[i]
		var slot := (n - 1 - i) if leftward else i
		var x := anchor - (slot + 1) * (CHIP + CHIP_GAP) * k + CHIP_GAP * k if leftward else anchor + slot * (CHIP + CHIP_GAP) * k
		var r := Rect2(Vector2(x, y), Vector2(CHIP * k, CHIP * k))
		var own: String = z["owner"]
		var fill := Color(UI.GLASS, 0.7)
		var ink := UI.TEXT
		if own == "home":
			fill = Color(UI.HOME, 0.88)
			ink = UI.INK
		elif own == "rival":
			fill = Color(UI.RIVAL, 0.88)
			ink = UI.INK
		var border := Color(UI.SUIT_WHITE, 0.22)
		var alert: bool = own == "home" and int(z["r"]) > 0 or (z["body"] == Game.planet and z["contested"])
		if alert and fmod(_t, UI.BLINK) < UI.BLINK * 0.6:
			border = UI.CRIT
		elif z["contested"]:
			border = Color(UI.WARN, 0.6 + 0.4 * sin(_t * 10.0))
		UI.draw_chamfer(_c, r, 4.0 * k, fill, border, 1 if not alert else 2)
		UI.draw_text_c(_c, _font_b, Vector2(r.get_center().x, r.end.y - 5.5 * k), str(z["letter"]), UI.fs(12, k), ink, 0 if own != "" else 2)
		# Changing hands: a bar under the chip, the leading side's colour, its share of the way.
		var p: float = z["progress"]
		var full: bool = (own == "home" and p >= 0.999) or (own == "rival" and p <= -0.999) or (own == "" and absf(p) < 0.001)
		if not full:
			var lead := UI.HOME if p > 0.0 else UI.RIVAL
			var br := Rect2(Vector2(r.position.x, r.end.y + 2.0 * k), Vector2(r.size.x, maxf(2.5 * k, 2.0)))
			_c.draw_rect(br, Color(0, 0, 0, 0.45))
			_c.draw_rect(Rect2(br.position, Vector2(br.size.x * absf(p), br.size.y)), lead)


## The capture plate while we stand in a zone.
func _plate(vs: Vector2, k: float) -> void:
	var z: Dictionary = cp.local_zone()
	if z.is_empty():
		return
	var w := 340.0 * k
	var h := 64.0 * k
	var r := Rect2(Vector2(vs.x * 0.5 - w * 0.5, vs.y * 0.69), Vector2(w, h))
	var own: String = z["owner"]
	var p: float = z["progress"]
	var hh: int = z["h"]
	var rr: int = z["r"]
	var state := ""
	var sc := UI.TEXT
	if z["contested"]:
		state = "ÇEKİŞMELİ — düşman bölgede"
		sc = UI.WARN
	elif own == "home" and p >= 0.999:
		state = "TUTULUYOR  ·  +%s m³/s" % String.num(cp.zone_step(cp.held_count("home")), 2).replace(".", ",")
		sc = UI.GOOD
	elif hh > 0 and own == "rival":
		state = "ETKİSİZLEŞTİRİLİYOR"
		sc = UI.WARN
	elif hh > 0:
		state = "ELE GEÇİRİLİYOR"
		sc = UI.CYAN
	elif own == "rival":
		state = "DÜŞMAN BÖLGESİ"
		sc = UI.BAD
	else:
		state = "BÖLGE"
	var accent := UI.HOME if own == "home" else (UI.RIVAL if own == "rival" else UI.SCREEN_CYAN)
	UI.draw_glass(_c, r, k, accent, 0.5)
	var pad := 14.0 * k
	UI.draw_text(_c, _font_b, Vector2(r.position.x + pad, r.position.y + 21.0 * k), "%s  ·  %s" % [z["letter"], UI.upper_tr(str(z["name"]))],
			UI.fs(13, k), UI.TEXT, 2)
	# Two-sided bar: theirs on the left, ours on the right, the neutral tick in the middle.
	var bar := Rect2(Vector2(r.position.x + pad, r.position.y + 34.0 * k), Vector2(w - pad * 2.0, 9.0 * k))
	_c.draw_rect(bar, Color(0, 0, 0, 0.4))
	var mid := bar.get_center().x
	var half := bar.size.x * 0.5
	if p > 0.0:
		_c.draw_rect(Rect2(Vector2(mid, bar.position.y), Vector2(half * p, bar.size.y)), UI.HOME)
	elif p < 0.0:
		_c.draw_rect(Rect2(Vector2(mid + half * p, bar.position.y), Vector2(-half * p, bar.size.y)), UI.RIVAL)
	_c.draw_rect(Rect2(Vector2(mid - 1.0, bar.position.y - 3.0 * k), Vector2(2.0, bar.size.y + 6.0 * k)), Color(UI.SUIT_WHITE, 0.7))
	var who := "sen ve %d dost" % (hh - 1) if hh > 1 else ("sen" if hh == 1 else "")
	var foe := "%d düşman" % rr if rr > 0 else ""
	var line := "  ·  ".join([who, foe].filter(func(s): return s != ""))
	# The state under the bar (left, in its colour), who is in the zone at the right.
	UI.draw_text(_c, _font_b, Vector2(r.position.x + pad, r.end.y - 5.0 * k), state, UI.fs(11, k), sc, 2)
	UI.draw_text_r(_c, _font, r.end.x - pad, r.end.y - 5.0 * k, line, UI.fs(10, k), UI.DIM, 2)
