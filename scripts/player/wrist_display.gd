extends Control
## Wrist computer screen content, drawn into a small SubViewport that the view model shows on the
## left forearm. Only re-rendered when the shown values change.
## Normal page, top to bottom: CAN (health: big number + 10-segment bar, green → amber → red; below
## LOW_HP it pulses red), JETPACK (+ the low-fuel LED), MALZEME, gravity and FENER on one line, the
## scanner state, the held item. A hit (flash_hit(), the view model calls it on any health drop and
## on hit reactions) flashes the screen red for FLASH_TIME. While a flash runs or health is low the
## screen re-renders itself at ~20 fps.
## Tünel tarayıcı (scripts/items/tunnel_scanner.gd pushes set_scan(), group "wrist_display"): the
## normal page shows the scanner's recharge under the header; while the wrist is raised for a scan
## or a reveal runs, the screen turns into the scanner page (radar of the reveal: the planet as a
## disc around you, its far side at the rim, ahead = up; bots red (hollow = underground), torpedoes
## amber triangles, tunnels amber dots; the counts and the reveal time) and re-renders itself at
## ~24 fps for the sweep. It keeps a small CAN readout in its top-left corner.
## Kazı aracı (scripts/player/terrain_tool.gd pushes set_drill() / drill_pop()): while the drill is
## held the held-item box is its heat gauge with the vent window (_draw_drill), and "+N" material
## popups rise beside MALZEME; the screen re-renders itself at ~30 fps while the gauge moves.

const UI := preload("res://scripts/ui/ui_style.gd")
const LOW_HP := 0.3                 # health share below which CAN pulses red
const FLASH_TIME := 0.45            # s of the red hit flash

var hp := -1.0                      # health (< 0: not known yet, CAN shows "--")
var hp_max := 100.0
var fuel := 1.0
var soil := 0.0
var soil_max := 400.0
var grav := 1.0
var item := ""
var item_color := Color(1, 0.6, 0.2)
var blink := false
var lamp := 1.0
var lamp_on := false
# Tünel tarayıcı (set_scan).
var scan_on := false             # scanner page shown
var scan_charge := 1.0           # 0..1 recharge
var scan_left := 0               # whole seconds of recharge left (0 = ready)
var scan_pulse := -1.0           # wave front in radar space (0..1), -1 = no wave
var scan_reveal := 0.0           # 0..1 reveal time left
var scan_reveal_s := 0
var scan_scanned := false        # a reveal is running (else: wrist up before / without one)
var scan_blips: Array = []       # [Vector2 radar pos, kind 0 bot / 1 torpedo / 2 tunnel, underground 0/1, alpha]
var scan_counts: Array = [0, 0, 0]   # bots, torpedoes, tunnel metres
# Kazı aracı (set_drill / drill_pop, pushed by scripts/player/terrain_tool.gd while it is held): the
# held-item box becomes the drill's heat gauge (tier name, state, heat fill, the vent window's zones
# and sweeping marker, SÜPER KAZI, a lockout), "+N" material popups rise beside MALZEME.
var drill_on := false
var drill := {}                  # heat, window, marker, good, sweet, locked, lock_kind, lock_k, lock_s,
								 # boost, boost_s, tier_name, tier_col, flash, flash_kind
var drill_pops: Array = []       # [text, colour, age s]
var _drill_anim_prev := false

var _key := ""
var _scan_key := ""
var _scan_t := 0.0
var _scan_frame := 0.0
var _flash := 0.0                   # hit flash 1 → 0
var _pulse_t := 0.0                 # low-health pulse clock


func _ready() -> void:
	add_to_group("wrist_display")


## Scanner state (see the vars above; keys on, charge, left, pulse, reveal, reveal_s, scanned,
## blips, counts). Returns true when the screen changed; it re-renders itself.
func set_scan(d: Dictionary) -> bool:
	var on := bool(d.get("on", false))
	var was_on := scan_on
	scan_on = on
	scan_charge = clampf(float(d.get("charge", 1.0)), 0.0, 1.0)
	scan_left = int(d.get("left", 0))
	if on:
		scan_pulse = float(d.get("pulse", -1.0))
		scan_reveal = float(d.get("reveal", 0.0))
		scan_reveal_s = int(d.get("reveal_s", 0))
		scan_scanned = bool(d.get("scanned", false))
		scan_blips = d.get("blips", [])
		scan_counts = d.get("counts", [0, 0, 0])
	var key := "%s|%d|%d" % [on, scan_left, int(scan_charge * 40.0)]
	var changed := key != _scan_key or on != was_on
	_scan_key = key
	if changed and not on:
		_rerender()
	return changed or on


func _process(delta: float) -> void:
	var flashing := _flash > 0.0
	if flashing:
		_flash = maxf(_flash - delta / FLASH_TIME, 0.0)
	var low := hp_low()
	if low:
		_pulse_t += delta
	var drill_anim := _tick_drill(delta)
	if _drill_anim_prev and not drill_anim and not scan_on:
		_rerender()                       # the drill gauge settled: one last frame
	_drill_anim_prev = drill_anim
	if not scan_on and not flashing and not low and not drill_anim:
		return
	if flashing and _flash <= 0.0 and not scan_on and not low and not drill_anim:
		_rerender()                       # the last frame of the flash: clear it
		return
	if scan_on:
		_scan_t += delta
	_scan_frame -= delta
	if _scan_frame <= 0.0:
		_scan_frame = 1.0 / (24.0 if scan_on else (30.0 if drill_anim else 20.0))
		_rerender()


## The held drill's state (terrain_tool.gd, every frame while held; {"on": false} once put away).
## Keys: see `drill`. The screen re-renders itself while the gauge moves.
func set_drill(d: Dictionary) -> void:
	var on := bool(d.get("on", false))
	if on != drill_on:
		drill_on = on
		_rerender()
	if on:
		drill = d


## A "+N" material popup beside MALZEME (the drill's tick ladder, the auto-collect).
func drill_pop(text: String, col: Color) -> void:
	drill_pops.append([text, col, 0.0])
	if drill_pops.size() > 4:
		drill_pops.pop_front()


## Ages the popups; true while the drill block needs re-rendering (heat moving, a window, a lockout,
## SÜPER KAZI, a vent flash or popups in the air).
func _tick_drill(delta: float) -> bool:
	for i in range(drill_pops.size() - 1, -1, -1):
		drill_pops[i][2] = float(drill_pops[i][2]) + delta
		if float(drill_pops[i][2]) > 0.95:
			drill_pops.remove_at(i)
	if not drill_on:
		return not drill_pops.is_empty()
	return not drill_pops.is_empty() or float(drill.get("heat", 0.0)) > 0.005 or bool(drill.get("window", false)) \
			or bool(drill.get("locked", false)) or float(drill.get("boost", 0.0)) > 0.0 or float(drill.get("flash", 0.0)) > 0.0


## A hit: the screen flashes red for FLASH_TIME (re-rendered right away).
func flash_hit() -> void:
	_flash = 1.0
	_scan_frame = 0.0
	_rerender()


## Health share 0..1 (1 while not known yet).
func hp_frac() -> float:
	return clampf(hp / maxf(hp_max, 1.0), 0.0, 1.0) if hp >= 0.0 else 1.0


## Below LOW_HP (alive, known): CAN pulses red.
func hp_low() -> bool:
	return hp > 0.0 and hp_frac() < LOW_HP


## Health colour as on the HUD (scripts/ui/hud.gd): green → amber below 60 % → red below 35 %.
static func hp_color(frac: float) -> Color:
	return UI.GOOD.lerp(UI.WARN, smoothstep(0.6, 0.35, frac)).lerp(UI.BAD, smoothstep(0.35, 0.15, frac))


func _rerender() -> void:
	queue_redraw()
	var vp := get_viewport()
	if vp is SubViewport:
		(vp as SubViewport).render_target_update_mode = SubViewport.UPDATE_ONCE


## Returns true when something changed (the caller then re-renders the viewport). h / hmax: health
## (h < 0: not known, CAN shows "--").
func set_values(f: float, s: float, smax: float, g: float, it: String, ic: Color, b: bool, lb := 1.0, lon := false,
		h := -1.0, hmax := 100.0) -> bool:
	var key := "%d|%d|%d|%.2f|%s|%s|%s|%d|%s|%d|%d" % [int(f * 50.0), int(s), int(smax), g, it, ic.to_html(), b,
			int(lb * 100.0), lon, int(ceilf(h)), int(hmax)]
	if key == _key:
		return false
	_key = key
	hp = h
	hp_max = hmax
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


## Segmented bar across the page (16 px margins): n segments, the first `lit` (or the share frac
## when lit < 0) in col, the rest faint.
func _seg_bar(y: float, frac: float, col: Color, hgt := 16.0, n := 12, x0 := 16.0, width := -1.0, lit := -1) -> void:
	var w := size.x - 32.0 if width < 0.0 else width
	var gap := 4.0
	var bw := (w - gap * (n - 1)) / n
	for i in n:
		var on := (i < lit) if lit >= 0 else ((i + 0.5) / n <= frac)
		var c := col if on else Color(col.r, col.g, col.b, 0.13)
		draw_rect(Rect2(x0 + i * (bw + gap), y, bw, hgt), c)


## Normal page (256 × 312). Rows, top to bottom (y of the baselines / boxes):
##   0-11 header + scanner recharge line · 16-96 CAN panel · 122-143 JETPACK · 170-191 MALZEME ·
##   200 divider · 225 gravity | FENER · 247 scanner state · 256-298 held item.
func _draw() -> void:
	if scan_on:
		_draw_scan()
		_draw_hit_flash()
		return
	var w := size.x
	var h := size.y
	var bold := UI.font(700)
	var reg := UI.font(500)
	var dim := Color(0.6, 0.75, 0.85)
	var cyan := Color(0.4, 0.92, 1.0)
	draw_rect(Rect2(0, 0, w, h), Color(0.015, 0.045, 0.06))
	for y in range(0, int(h), 6):
		draw_rect(Rect2(0, y, w, 1), Color(0.3, 0.8, 1.0, 0.035))
	draw_rect(Rect2(0, 0, w, 8), Color(1.0, 0.55, 0.18))
	# Tünel tarayıcı recharge (Q): a thin line under the header (its state is lower down).
	var sready := scan_left <= 0
	var tcol := cyan if sready else Color(1.0, 0.7, 0.3)
	draw_rect(Rect2(0, 8, w * scan_charge, 3), Color(tcol, 0.8))
	# CAN: the most prominent reading.
	_draw_health(w, bold, reg, dim)
	# JETPACK, with the low-fuel LED after the label.
	var warn := fuel < 0.25
	var fcol := Color(1.0, 0.4, 0.3) if warn else cyan
	draw_string(reg, Vector2(16, 122), "JETPACK", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, dim)
	var led := Color(1.0, 0.35, 0.25) if (warn and blink) else Color(0.3, 1.0, 0.5)
	draw_circle(Vector2(16.0 + reg.get_string_size("JETPACK", HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x + 11.0, 116), 4.5, led)
	draw_string(bold, Vector2(16, 124), "%d%%" % int(fuel * 100.0), HORIZONTAL_ALIGNMENT_RIGHT, w - 32, 28, fcol)
	_seg_bar(131, fuel, fcol, 12.0)
	# MALZEME.
	var scol := Color(1.0, 0.65, 0.28)
	draw_string(reg, Vector2(16, 170), "MALZEME", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, dim)
	draw_string(bold, Vector2(16, 172), "%d" % int(soil), HORIZONTAL_ALIGNMENT_RIGHT, w - 32, 28, scol)
	_seg_bar(179, soil / maxf(soil_max, 1.0), scol, 12.0)
	if not drill_pops.is_empty():
		_draw_drill_pops(w, bold, bold.get_string_size("%d" % int(soil), HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x)
	draw_rect(Rect2(16, 200, w - 32, 2), Color(0.4, 0.9, 1.0, 0.25))
	# Gravity (one small line) and the lamp.
	draw_string(bold, Vector2(16, 225), "%.2f g" % grav, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.85, 0.95, 1.0))
	var lcol := Color(1.0, 0.92, 0.7) if lamp_on else Color(0.5, 0.62, 0.72)
	var lv := "AÇIK" if lamp_on else "KAPALI"
	var lvw := bold.get_string_size(lv, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	draw_string(bold, Vector2(16, 225), lv, HORIZONTAL_ALIGNMENT_RIGHT, w - 32, 18, lcol)
	draw_string(reg, Vector2(16, 225), "FENER", HORIZONTAL_ALIGNMENT_RIGHT, w - 32 - lvw - 8.0, 13, Color(0.5, 0.62, 0.72))
	# Scanner state.
	draw_string(reg, Vector2(16, 247), "TARAYICI HAZIR" if sready else "TARAYICI %d sn" % scan_left,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(tcol, 0.9))
	# Held item (the drill: its heat gauge).
	if drill_on:
		_draw_drill(w, bold, reg)
	else:
		draw_rect(Rect2(16, 256, w - 32, 42), Color(item_color.r, item_color.g, item_color.b, 0.16))
		draw_rect(Rect2(16, 256, 5, 42), item_color)
		draw_string(bold, Vector2(30, 284), item, HORIZONTAL_ALIGNMENT_LEFT, w - 46, 20, item_color.lightened(0.3))
	_draw_hit_flash()


## Heat colour of the drill gauge: deep orange → orange (60 %) → white-hot.
static func drill_heat_color(h: float) -> Color:
	var a := Color(1.0, 0.34, 0.08)
	var b := Color(1.0, 0.62, 0.2)
	var c := Color(1.0, 0.96, 0.86)
	return a.lerp(b, clampf(h / 0.6, 0.0, 1.0)) if h < 0.6 else b.lerp(c, clampf((h - 0.6) / 0.4, 0.0, 1.0))


## The drill block (y 256-298, in place of the held item): "MATKAP Mk II" + the state on the first
## line, the heat gauge under it. Window: the fill dims, the amber zone and the white sweet spot show,
## a cyan marker sweeps; SÜPER KAZI: teal ripples; locked: red (blinking on a jam); a vent flashes the
## box white (perfect) / amber (good) / red (jam).
func _draw_drill(w: float, bold: Font, reg: Font) -> void:
	var h := clampf(float(drill.get("heat", 0.0)), 0.0, 1.0)
	var window := bool(drill.get("window", false))
	var locked := bool(drill.get("locked", false))
	var jam := int(drill.get("lock_kind", 0)) == 1
	var boost := float(drill.get("boost", 0.0))
	var tcol: Color = drill.get("tier_col", item_color)
	var teal := Color(0.45, 1.0, 0.95)
	var red := Color(1.0, 0.3, 0.22)
	var blink := fmod(float(Time.get_ticks_msec()) / 1000.0, 0.5) < 0.28
	var accent := tcol
	var state := "ISI %d%%" % int(roundf(h * 100.0))
	var scol := drill_heat_color(h) if h > 0.05 else Color(0.6, 0.75, 0.85)
	if locked:
		accent = red
		state = ("TIKANDI %.1f" if jam else "AŞIRI ISINDI %.1f") % float(drill.get("lock_s", 0.0))
		scol = Color(red, 1.0 if (blink or not jam) else 0.55)
	elif boost > 0.0:
		accent = teal
		state = "SÜPER KAZI %d" % int(ceilf(float(drill.get("boost_s", 0.0))))
		scol = teal
	elif window:
		state = "SOĞUT: R"
		scol = Color(1, 1, 1) if blink else Color(1.0, 0.78, 0.35)
	draw_rect(Rect2(16, 256, w - 32, 42), Color(accent.r, accent.g, accent.b, 0.16))
	draw_rect(Rect2(16, 256, 5, 42), accent)
	draw_string(bold, Vector2(28, 274), "MATKAP %s" % str(drill.get("tier_name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
			tcol.lightened(0.35))
	draw_string(bold, Vector2(28, 274), state, HORIZONTAL_ALIGNMENT_RIGHT, w - 52, 14, scol)
	# The gauge.
	var gx := 28.0
	var gw := w - 52.0
	var gy := 281.0
	var gh := 11.0
	draw_rect(Rect2(gx, gy, gw, gh), Color(0.0, 0.02, 0.03, 0.9))
	var fill := drill_heat_color(h)
	if locked:
		fill = red
	draw_rect(Rect2(gx, gy, gw * h, gh), Color(fill, 0.35 if window else 0.95))
	# The vent threshold tick.
	var ox := gx + gw * 0.6
	draw_rect(Rect2(ox - 1.0, gy - 2.0, 2.0, gh + 4.0), Color(1, 1, 1, 0.3))
	if window:
		var gd: Vector2 = drill.get("good", Vector2(0.45, 0.79))
		var sw: Vector2 = drill.get("sweet", Vector2(0.55, 0.68))
		draw_rect(Rect2(gx + gw * gd.x, gy, gw * (gd.y - gd.x), gh), Color(1.0, 0.7, 0.28, 0.6))
		draw_rect(Rect2(gx + gw * sw.x, gy, gw * (sw.y - sw.x), gh), Color(1.0, 1.0, 1.0, 0.95))
		var mx := gx + gw * clampf(float(drill.get("marker", 0.0)), 0.0, 1.0)
		draw_rect(Rect2(mx - 2.0, gy - 4.0, 4.0, gh + 8.0), Color(0.35, 1.0, 1.0))
		draw_rect(Rect2(mx - 0.5, gy - 4.0, 1.0, gh + 8.0), Color(1, 1, 1))
	if boost > 0.0 and not locked:
		var ph := float(Time.get_ticks_msec()) / 1000.0
		for i in 6:
			var u := fmod(ph * 0.9 + i / 6.0, 1.0)
			draw_rect(Rect2(gx + gw * u - 3.0, gy, 6.0, gh), Color(teal, 0.45 * boost))
	draw_rect(Rect2(gx, gy, gw, gh), Color(1, 1, 1, 0.18), false, 1.0)
	var fl := float(drill.get("flash", 0.0))
	if fl > 0.0:
		var fk := int(drill.get("flash_kind", 0))
		var fc := Color(1, 1, 1) if fk == 1 else (Color(1.0, 0.75, 0.3) if fk == 2 else red)
		draw_rect(Rect2(16, 256, w - 32, 42), Color(fc, 0.35 * fl))


## "+N" popups rising from beside the MALZEME number (num_w: its width) and fading.
func _draw_drill_pops(w: float, bold: Font, num_w: float) -> void:
	var right := w - 16.0 - num_w - 10.0
	for p in drill_pops:
		var age := float(p[2])
		var k := clampf(age / 0.95, 0.0, 1.0)
		var col: Color = p[1]
		var a := 1.0 - k * k
		var y := 168.0 - 22.0 * (1.0 - pow(1.0 - k, 2.0))
		draw_string(bold, Vector2(16, y), str(p[0]), HORIZONTAL_ALIGNMENT_RIGHT, right - 16.0, 17, Color(col, a))


## CAN panel (y 16-96): label, "/ max", the big number on the right and a 10-segment bar, tinted
## green → amber → red; below LOW_HP the panel and the number pulse red.
func _draw_health(w: float, bold: Font, reg: Font, dim: Color) -> void:
	var known := hp >= 0.0
	var frac := hp_frac()
	var hc := hp_color(frac) if known else dim
	var pulse := 0.0
	if hp_low():
		pulse = 0.5 + 0.5 * sin(_pulse_t * TAU * 1.6)
		hc = hc.lerp(Color(1.0, 0.18, 0.12), 0.35 + 0.35 * pulse)
	draw_rect(Rect2(10, 16, w - 20, 80), Color(hc, 0.1 + 0.25 * pulse))
	draw_rect(Rect2(10, 16, 5, 80), Color(hc, 1.0 - 0.5 * pulse))
	draw_string(reg, Vector2(24, 41), "CAN", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, dim)
	draw_string(reg, Vector2(24, 63), "/ %d" % int(hp_max), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(dim, 0.7))
	var num := "%d" % int(ceilf(hp)) if known else "--"
	draw_string(bold, Vector2(24, 70), num, HORIZONTAL_ALIGNMENT_RIGHT, w - 46, 56, hc.lerp(Color.WHITE, 0.3 * pulse))
	var lit := int(ceilf(frac * 10.0 - 0.001)) if hp > 0.0 else 0      # 1 hp still lights a segment
	_seg_bar(76, frac, hc, 14.0, 10, 24.0, w - 46, lit)


## Red hit flash over either page (flash_hit): a tint and a border that fade over FLASH_TIME.
func _draw_hit_flash() -> void:
	if _flash <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.12, 0.08, 0.3 * _flash * _flash))
	draw_rect(Rect2(Vector2(3, 3), size - Vector2(6, 6)), Color(1.0, 0.25, 0.2, 0.9 * _flash), false, 6.0)


## Scanner page: title + state, the radar (planet disc around you, its far side at the rim, ahead =
## up, a rotating sweep that lights the blips, the wave ring), the counts and the reveal / charge bar.
func _draw_scan() -> void:
	var w := size.x
	var h := size.y
	var bold := UI.font(700)
	var reg := UI.font(500)
	var cyan := Color(0.4, 0.92, 1.0)
	var red := Color(1.0, 0.36, 0.26)
	var amber := Color(1.0, 0.64, 0.22)
	var hot := int(scan_counts[0]) + int(scan_counts[1]) > 0
	draw_rect(Rect2(0, 0, w, h), Color(0.012, 0.035, 0.045))
	for y in range(0, int(h), 6):
		draw_rect(Rect2(0, y, w, 1), Color(0.3, 0.8, 1.0, 0.035))
	draw_rect(Rect2(0, 0, w, 8), red if hot else cyan)
	draw_string(bold, Vector2(14, 34), "TÜNEL TARAYICI", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, cyan.lightened(0.25))
	var status := "HAZIR"
	var scol := cyan
	if scan_pulse >= 0.0:
		status = "TARIYOR"
		scol = Color(cyan, 1.0 if fmod(_scan_t, 0.5) < 0.3 else 0.4)
	elif scan_scanned:
		status = "%d sn" % scan_reveal_s
		scol = red if hot else cyan
	elif scan_left > 0:
		status = "ŞARJ %d sn" % scan_left
		scol = amber
	draw_string(reg, Vector2(14, 34), status, HORIZONTAL_ALIGNMENT_RIGHT, w - 28, 15, scol)
	# Radar.
	var c := Vector2(w * 0.5, 148.0)
	var R := 96.0
	draw_circle(c, R, Color(0.03, 0.09, 0.11))
	for k in [0.5, 0.866]:                  # 45° and 135° around the planet
		draw_arc(c, R * k, 0.0, TAU, 64, Color(cyan, 0.16), 1.0, true)
	draw_arc(c, R * 0.7071, 0.0, TAU, 64, Color(cyan, 0.3), 1.5, true)       # 90°: the horizon
	draw_arc(c, R, 0.0, TAU, 96, Color(cyan, 0.6), 2.0, true)                # the far side
	draw_line(c - Vector2(R, 0), c + Vector2(R, 0), Color(cyan, 0.1), 1.0)
	draw_line(c - Vector2(0, R), c + Vector2(0, R), Color(cyan, 0.1), 1.0)
	draw_colored_polygon(PackedVector2Array([c, c + Vector2(sin(-0.5), -cos(-0.5)) * R * 0.62,
			c + Vector2(sin(0.5), -cos(0.5)) * R * 0.62]), Color(cyan, 0.07))
	var sw := fmod(_scan_t * 3.6, TAU)
	for i in 16:
		var a0 := sw - i * 0.06
		var a1 := a0 - 0.06
		draw_colored_polygon(PackedVector2Array([c, c + Vector2(sin(a0), -cos(a0)) * R, c + Vector2(sin(a1), -cos(a1)) * R]),
				Color(cyan, 0.15 * (1.0 - i / 16.0)))
	draw_line(c, c + Vector2(sin(sw), -cos(sw)) * R, Color(cyan, 0.55), 1.5, true)
	if scan_pulse >= 0.0:
		var pr := R * clampf(scan_pulse, 0.0, 1.0)
		draw_circle(c, pr, Color(cyan, 0.05))
		draw_arc(c, maxf(pr, 1.0), 0.0, TAU, 72, Color(cyan.lightened(0.3), 0.85 - 0.5 * scan_pulse), 3.0, true)
	for b in scan_blips:
		var v: Vector2 = b[0]
		var kind := int(b[1])
		var under := int(b[2]) == 1
		var al := clampf(float(b[3]), 0.0, 1.0)
		var p := c + Vector2(v.x, -v.y) * R
		var since := fposmod(sw - atan2(v.x, v.y), TAU)
		var lit := minf(0.55 + 0.6 * exp(-since * 1.6), 1.0)
		match kind:
			3:                                  # a rich vein / meteor core (scripts/planet/veins.gd): gold diamond
				var dsz := 4.5
				draw_colored_polygon(PackedVector2Array([p + Vector2(0, -dsz), p + Vector2(dsz, 0), p + Vector2(0, dsz), p + Vector2(-dsz, 0)]),
						Color(1.0, 0.8, 0.32, al * lit))
			4:                                  # a buried cache: green square
				draw_rect(Rect2(p - Vector2(3.5, 3.5), Vector2(7, 7)), Color(0.45, 1.0, 0.55, al * lit))
			2:
				draw_circle(p, 1.7, Color(amber, 0.55 * al * lit))
			1:
				var s := 6.0 + 1.5 * sin(_scan_t * 9.0)
				draw_colored_polygon(PackedVector2Array([p + Vector2(0, -s), p + Vector2(s * 0.9, s * 0.6), p + Vector2(-s * 0.9, s * 0.6)]),
						Color(amber, al * lit))
				draw_arc(p, s + 4.0, 0.0, TAU, 20, Color(amber, 0.35 * al), 1.5, true)
			_:
				draw_circle(p, 8.0, Color(red, 0.16 * al * lit))
				if under:
					draw_arc(p, 4.2, 0.0, TAU, 16, Color(red, al * lit), 2.0, true)
				else:
					draw_circle(p, 4.2, Color(red, al * lit))
	draw_circle(c, 4.0, Color(1, 1, 1, 0.95))
	# CAN, small, in the top-left corner outside the radar disc: number and a mini bar (pulses red
	# when low, like the normal page).
	var hfrac := hp_frac()
	var hcol := hp_color(hfrac) if hp >= 0.0 else Color(0.55, 0.68, 0.78)
	if hp_low():
		hcol = hcol.lerp(Color(1.0, 0.18, 0.12), 0.35 + 0.35 * (0.5 + 0.5 * sin(_pulse_t * TAU * 1.6)))
	draw_string(reg, Vector2(14, 62), "CAN", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.75, 0.85))
	draw_string(bold, Vector2(14, 85), ("%d" % int(ceilf(hp))) if hp >= 0.0 else "--", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, hcol)
	draw_rect(Rect2(14, 90, 32, 4), Color(hcol, 0.2))
	draw_rect(Rect2(14, 90, 32.0 * hfrac, 4), hcol)
	# Counts and the reveal (or charge) bar.
	draw_string(bold, Vector2(0, 272), "%d BOT · %d TORPİDO" % [int(scan_counts[0]), int(scan_counts[1])],
			HORIZONTAL_ALIGNMENT_CENTER, w, 18, red.lightened(0.15) if hot else cyan)
	var tm := int(scan_counts[2])
	var tl := "TÜNEL %d m" % tm if tm > 0 else ("TÜNEL YOK" if scan_scanned else "—")
	if scan_counts.size() > 4 and int(scan_counts[3]) + int(scan_counts[4]) > 0:   # veins, caches (tunnel_scanner.gd)
		tl += "  ·  %d DAMAR" % int(scan_counts[3]) if int(scan_counts[3]) > 0 else ""
		tl += "  ·  %d SANDIK" % int(scan_counts[4]) if int(scan_counts[4]) > 0 else ""
	draw_string(reg, Vector2(0, 293), tl, HORIZONTAL_ALIGNMENT_CENTER, w, 15, amber if tm > 0 else Color(0.55, 0.68, 0.78))
	var bar_k := scan_reveal if scan_scanned else scan_charge
	draw_rect(Rect2(16, 300, w - 32, 4), Color(cyan, 0.15))
	draw_rect(Rect2(16, 300, (w - 32) * bar_k, 4), (red if hot else cyan) if scan_scanned else amber)
