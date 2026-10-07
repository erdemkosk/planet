extends CanvasLayer
## Relic buffs (Eski kalıntı, scripts/war/caches.gd): CACHE_BUFF_TIME s each, local to the player who
## opened the relic; the same kind again refreshes it. Child "CacheBuffs" of the Caches node; its HUD chips
## (glass plates in the buff's colour: icon, name, seconds left, a segment bar) stack above the CAN plate
## (bottom left, hud.gd). Tunables: balance.gd "Buried caches".
##   "dig"     Kazı hızı +50 %: our drill's dig strength × CACHE_DIG_MULT. Hook: scripts/player/dig.gd
##             Dig.amount_hook = this node's _dig_amount, which only boosts the DIG call whose plane point
##             is our player's feet (terrain_tool.gd's own brush; the AI, blasts and beams pass none).
##             (The material credit stays capped by the drill's DRILL_MAX_RATE.)
##   "shield"  Kalkan: absorbs CACHE_SHIELD_HP of damage, then breaks. Hook: player.gd take_damage calls
##             get_meta("dmg_absorb").absorb(amount, from_pos) (this node, set on our player while it lasts).
##   "scan"    Tarayıcı şarjı: the Tünel tarayıcı is charged at once and recharges CACHE_SCAN_RATE × as fast
##             (its cooldown counter is wound down from here; tunnel_scanner.gd itself is untouched, it still
##             plays its own "ready" tones).
##   "quiet"   Sessiz adım: noise_mult() = CACHE_QUIET_MULT for the bots' hearing. Its weight stays 0 until
##             ai_rival.gd _bl_noise multiplies its result by CacheBuffs.noise_mult() (one line).
## API (static): start(id, secs), active(id), left(id), shield_left(), dig_mult(), noise_mult(),
##   buff_name(id). Events: Caches.events().buff_started(id, secs) / buff_ended(id).

const Balance := preload("res://scripts/war/balance.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # toasts: key "buff" (shield broken 1, ended 0)
const Dig := preload("res://scripts/player/dig.gd")
const CACHES_PATH := "res://scripts/war/caches.gd"      # (loaded at use: caches.gd preloads this file)
const META := "dmg_absorb"

const NAMES := {"dig": "Kazı hızı +50 %", "shield": "Kalkan", "scan": "Tarayıcı şarjı", "quiet": "Sessiz adım"}
const COLORS := {"dig": Color(1.0, 0.62, 0.22), "shield": Color(0.45, 0.82, 1.0), "scan": Color(0.4, 0.95, 0.85),
		"quiet": Color(0.7, 0.95, 0.55)}
const CHIP_W := 222.0
const CHIP_H := 36.0
const VITALS_TOP := 24.0 + 80.0 + 12.0  # px above the bottom (1080p): hud.gd MARGIN + the CAN plate + a gap

static var _inst: Node

var _left := {}                        # buff id -> s left
var _total := {}                       # buff id -> s it started with
var _shield := 0.0
var _flash := 0.0                      # an absorbed hit's frame flash 1..0
var _t := 0.0
var _canvas: Control


static func _live() -> Node:
	return _inst if _inst != null and is_instance_valid(_inst) else null


## Starts (or refreshes) relic buff `id` for `secs` s on our player.
static func start(id: String, secs: float) -> void:
	var b := _live()
	if b != null:
		b.call("_start", id, secs)


static func active(id: String) -> bool:
	var b := _live()
	return b != null and (b.get("_left") as Dictionary).has(id)


static func left(id: String) -> float:
	var b := _live()
	return float((b.get("_left") as Dictionary).get(id, 0.0)) if b != null else 0.0


static func shield_left() -> float:
	var b := _live()
	return float(b.get("_shield")) if b != null and active("shield") else 0.0


## × our drill's dig strength (CACHE_DIG_MULT while "dig" runs).
static func dig_mult() -> float:
	return Balance.CACHE_DIG_MULT if active("dig") else 1.0


## × the bots' hearing range of our noise (CACHE_QUIET_MULT while "quiet" runs).
static func noise_mult() -> float:
	var q := Balance.CACHE_QUIET_MULT if active("quiet") else 1.0
	# × the Avcı's passive (scripts/war/heroes/heroes.gd noise_mult; loaded at use: 1 without it).
	var h = load("res://scripts/war/heroes/heroes.gd") if ResourceLoader.exists("res://scripts/war/heroes/heroes.gd") else null
	if h != null and (h as Script).can_instantiate():
		q *= float(h.noise_mult())
	return q


static func buff_name(id: String) -> String:
	return str(NAMES.get(id, id))


func _ready() -> void:
	_inst = self
	layer = 5
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_to_group("gameplay_overlay")      # hidden on the end screen / menus (overlay_guard.gd)
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)
	Dig.amount_hook = _dig_amount


func _exit_tree() -> void:
	if _inst == self:
		_inst = null
	if Dig.amount_hook.is_valid() and Dig.amount_hook.get_object() == self:
		Dig.amount_hook = Callable()
	_clear_meta()


func _hub() -> Object:
	var s = load(CACHES_PATH)
	return s.events() if s != null else null


func _start(id: String, secs: float) -> void:
	if not NAMES.has(id) or secs <= 0.0:
		return
	_left[id] = secs
	_total[id] = secs
	match id:
		"shield":
			_shield = Balance.CACHE_SHIELD_HP
			_set_meta()
		"scan":
			var sc = _scanner()
			if sc != null:
				var c = sc.get("_cool")
				if (c is float or c is int) and float(c) > 0.0:
					sc.set("_cool", 0.001)          # (its own tick crosses zero: the "ready" tones)
	var hub := _hub()
	if hub != null:
		hub.buff_started.emit(id, secs)
	if Game.sfx:
		Game.sfx.play("whoosh", -10.0, 1.2)
	_canvas.queue_redraw()


func _end(id: String, broken: bool) -> void:
	if not _left.has(id):
		return
	_left.erase(id)
	_total.erase(id)
	if id == "shield":
		_shield = 0.0
		_clear_meta()
	var hub := _hub()
	if hub != null:
		hub.buff_ended.emit(id)
	if Game.hud:
		HudLevel.alert("Kalkan kırıldı!" if broken else "%s sona erdi" % buff_name(id), 1 if broken else 0, "buff_" + str(id), 2.0)
	if Game.sfx:
		Game.sfx.play("close", -9.0, 0.9 if broken else 1.0)
	_canvas.queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	_flash = maxf(_flash - delta * 2.5, 0.0)
	for id in _left.keys():
		_left[id] = float(_left[id]) - delta
		if float(_left[id]) <= 0.0:
			_end(str(id), false)
	if _left.has("shield"):
		_set_meta()                            # (a respawned / replaced player node gets it too)
	if _left.has("scan"):
		_wind_scanner(delta)
	if not _left.is_empty() or _flash > 0.0:
		_canvas.queue_redraw()


# --- Hooks ----------------------------------------------------------------------------------------

## Dig.amount_hook: our drill's own DIG brush (plane point = our player's feet) digs × CACHE_DIG_MULT.
func _dig_amount(_point: Vector3, mode: int, amount: float, plane_point: Vector3, team: String) -> float:
	if mode != 0 or team == "" or not _left.has("dig"):
		return amount
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return amount
	if not plane_point.is_equal_approx((p as Node3D).global_position):
		return amount
	return amount * Balance.CACHE_DIG_MULT


## player.gd take_damage (via the "dmg_absorb" meta): the shield eats what it can; returns the rest.
func absorb(amount: float, _from_pos := Vector3.ZERO) -> float:
	if not _left.has("shield") or _shield <= 0.0 or amount <= 0.0:
		return amount
	var take := minf(_shield, amount)
	_shield -= take
	_flash = 1.0
	if Game.sfx:
		Game.sfx.play("impact_light", -9.0, 1.35)
		Game.sfx.play("ding", -15.0, 1.9)
	if _shield <= 0.01:
		_end("shield", true)
	return amount - take


func _set_meta() -> void:
	var p = Game.player
	if p != null and is_instance_valid(p) and not (p as Object).has_meta(META):
		(p as Object).set_meta(META, self)


func _clear_meta() -> void:
	var p = Game.player
	if p != null and is_instance_valid(p) and (p as Object).has_meta(META) and (p as Object).get_meta(META) == self:
		(p as Object).remove_meta(META)


func _scanner() -> Object:
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return null
	var ha = p.get("hand_action")
	if ha == null or not is_instance_valid(ha):
		return null
	var sc = ha.get("scanner")
	return sc if sc != null and is_instance_valid(sc) else null


## "scan": the scanner's cooldown runs CACHE_SCAN_RATE × as fast (down to a hair above zero: its own
## tick finishes it and plays the "ready" tones).
func _wind_scanner(delta: float) -> void:
	var sc = _scanner()
	if sc == null:
		return
	var c = sc.get("_cool")
	if not (c is float or c is int):
		return
	var cool := float(c)
	if cool > 0.002:
		sc.set("_cool", maxf(cool - delta * (Balance.CACHE_SCAN_RATE - 1.0), 0.001))


# --- HUD chips ------------------------------------------------------------------------------------

func _on_draw() -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p) or (p.has_method("is_dead") and p.is_dead()):
		return
	var vs := _canvas.size
	var k := UI.scale_k(vs)
	if _flash > 0.0:
		# An absorbed hit: a cool frame around the view.
		var fc := Color(COLORS["shield"], 0.45 * _flash)
		var t := 5.0 * k
		_canvas.draw_rect(Rect2(0, 0, vs.x, t), fc)
		_canvas.draw_rect(Rect2(0, vs.y - t, vs.x, t), fc)
		_canvas.draw_rect(Rect2(0, 0, t, vs.y), fc)
		_canvas.draw_rect(Rect2(vs.x - t, 0, t, vs.y), fc)
	if _left.is_empty():
		return
	var w := CHIP_W * k
	var h := CHIP_H * k
	var x := 24.0 * k
	var y := vs.y - VITALS_TOP * k
	var caps := UI.font_caps(700, 1)
	var num := UI.font_num(700)
	for id in _left:
		var sid := str(id)
		y -= h
		var r := Rect2(Vector2(x, y), Vector2(w, h))
		var col: Color = COLORS.get(sid, UI.SCREEN_CYAN)
		var lf := float(_left[id])
		var low := lf < 8.0
		var pulse := (0.5 + 0.5 * sin(_t * TAU * 1.4)) if low else 0.0
		UI.draw_glass(_canvas, r, k, col, 0.4 + 0.3 * pulse + (0.4 * _flash if sid == "shield" else 0.0), 1.0, false, 8.0)
		_icon(sid, Vector2(x + 18.0 * k, y + h * 0.5), 8.0 * k, col.lightened(0.15))
		var tx := x + 34.0 * k
		UI.draw_text(_canvas, caps, Vector2(tx, y + 15.0 * k), UI.upper_tr(buff_name(sid)), UI.fs(11, k), UI.TEXT, 2)
		UI.draw_text_r(_canvas, num, r.end.x - 10.0 * k, y + 15.0 * k, "%d sn" % ceili(lf), UI.fs(12, k),
				col.lightened(0.35).lerp(UI.WARN, pulse * 0.6), 2)
		var bar := Rect2(Vector2(tx, y + 22.0 * k), Vector2(r.end.x - 10.0 * k - tx, 5.0 * k))
		if sid == "shield":
			UI.draw_seg_bar(_canvas, bar, 10, _shield / maxf(Balance.CACHE_SHIELD_HP, 1.0), col)
			var tf := lf / maxf(float(_total.get(id, 1.0)), 0.1)
			_canvas.draw_rect(Rect2(bar.position + Vector2(0, bar.size.y + 2.0 * k), Vector2(bar.size.x * tf, maxf(1.0, k))),
					Color(UI.SUIT_WHITE, 0.35))
		else:
			UI.draw_seg_bar(_canvas, bar, 12, lf / maxf(float(_total.get(id, 1.0)), 0.1), col)
		y -= 6.0 * k


## A small glyph per buff (centre c, half size s).
func _icon(id: String, c: Vector2, s: float, col: Color) -> void:
	match id:
		"dig":
			# A drill bit pointing down: a wedge with two thread lines.
			var pts := PackedVector2Array([c + Vector2(-s * 0.7, -s), c + Vector2(s * 0.7, -s), c + Vector2(0, s * 1.05)])
			_canvas.draw_colored_polygon(pts, Color(col, 0.9))
			_canvas.draw_line(c + Vector2(-s * 0.45, -s * 0.35), c + Vector2(s * 0.5, -s * 0.6), Color(UI.INK, 0.8), maxf(1.0, s * 0.18))
			_canvas.draw_line(c + Vector2(-s * 0.25, s * 0.2), c + Vector2(s * 0.3, -s * 0.05), Color(UI.INK, 0.8), maxf(1.0, s * 0.18))
		"shield":
			var hexa := PackedVector2Array()
			for i in 6:
				var a := PI / 6.0 + TAU * float(i) / 6.0
				hexa.append(c + Vector2(cos(a), sin(a)) * s * 1.05)
			_canvas.draw_colored_polygon(hexa, Color(col, 0.35))
			hexa.append(hexa[0])
			_canvas.draw_polyline(hexa, col, maxf(1.5, s * 0.2), true)
		"scan":
			_canvas.draw_circle(c + Vector2(-s * 0.55, s * 0.55), s * 0.22, col)
			for i in 3:
				var rr := s * (0.55 + 0.45 * float(i))
				_canvas.draw_arc(c + Vector2(-s * 0.55, s * 0.55), rr, -PI * 0.5, 0.0, 12, Color(col, 1.0 - 0.25 * i), maxf(1.2, s * 0.16), true)
		_:
			# A footprint.
			_canvas.draw_circle(c + Vector2(-s * 0.3, s * 0.25), s * 0.42, Color(col, 0.85))
			for i in 3:
				_canvas.draw_circle(c + Vector2(-s * 0.55 + s * 0.4 * float(i), -s * 0.55), s * 0.16, Color(col, 0.85))
