extends Control
## Radar / minimap (2026-10-07; the user: "sağda minimap; ateş eden düşmanlar görünsün, bizim gezegen
## ya da düşmanınki; susturucu takanlar görünmesin"). Call of Duty style: an enemy who fires WITHOUT
## a suppressor shows as a red dot where he stood when he fired, fading out over PING_AGE s (not
## tracked afterwards); silent enemies never show (no wallhack).
## Look: a compact dark glass disc right under the HUD's material plate (top right, clear of the
## war_hud strip top centre), a thin rim, faint range rings, the player's arrow in the centre with a
## faint view cone; heading-up, centred on the player, on the planet he stands on (Game.dominant_body).
## Shows: teammates (cyan dots: ally bots, a co-op partner; always), loud enemy shots (red, fading,
## with a pop ring), the control points (owner-coloured letters, scripts/war/control_points.gd), the
## cores (the planet's own core under you: a diamond around the arrow; the other planet's core: the
## edge chevron's colour), the other planet: a chevron on the rim toward it with a tiny label
## ("RAKİP" / "YURT"); loud shots fired on the other planet pulse red on that chevron.
## Projection: geodesic. A point's map distance is the angle between its up vector and the player's
## (both from the planet centre) × the planet radius, along the direction of the great circle in the
## player's tangent plane; so a point across the small planet lands where you would walk to it, the
## antipode straight behind on the rim. RANGE_M m to the rim; pings and objectives beyond it are
## clamped to the rim as smaller dots, teammates beyond it are not drawn. Points on the other planet
## are never dots (only the chevron). Heading: the camera's forward flattened onto the tangent plane
## (looking straight down / up: its up vector), so it works on foot, on the ATV, in the shuttle.
## High above a planet (SPACE_ALT) the dots hide and both planets get chevrons in the camera's frame.
## HUD level (scripts/ui/hud_level.gd): shown in every level (the user asked for it); Sade: no range
## rings, the control points as plain dots, no chevron label; Detaylı: + the range read-out.
## Cheap: one Control, _draw at TICK (20 Hz), reused packed arrays, no rays; the unit list every
## LIST_DT s. Data: scripts/war/shot_pings.gd (fed by enemy_fire.gd / remote_avatar.gd). Child of the
## combat overlay (scripts/ui/combat_hud.gd), group "gameplay_overlay" (overlay_guard.gd).
##   Minimap.layout(vs) -> Vector3(cx, cy, r)   Minimap.bottom_y(vs) -> float (what stacks under it)
##   Minimap.map_point(p, c, up, right, fwd, radius) -> Vector3(x m, y m (forward), geodesic m)
##   Minimap.heading(up, cam_basis) -> [right, fwd]

const UI := preload("res://scripts/ui/ui_style.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")
const ShotPings := preload("res://scripts/war/shot_pings.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")

const RANGE_M := 90.0             # m of geodesic distance from the centre to the rim
const RADIUS := 85.0              # px at 1080p (UI.scale_k)
const RIGHT_X := 130.0            # px from the right edge to the centre (at 1080p)
const TOP_Y := 220.0              # px from the top to the centre: under the material plate
const TICK := 0.05                # s between redraws (20 Hz)
const LIST_DT := 0.25             # s between teammate list refreshes
const PING_AGE := 2.5             # s a loud shot stays on the radar
const SPACE_ALT := 45.0           # m above the base radius: "in space" (dots hide)
const GROUPS := ["war_ai", "net_player"]
const FRIEND_COL := Color(0.45, 0.88, 1.0)
const ENEMY_COL := Color(1.0, 0.24, 0.16)
const NEUTRAL_COL := Color(0.6, 0.71, 0.79)

var _t := 0.0
var _list_t := 0.0
var _units: Array = []
var _mode := 0                    # 0 hidden, 1 on / near a planet, 2 in space
var _lv := 0
var _my_team := "home"
var _half_fov := 0.6
var _core_col := Color(0, 0, 0, 0)   # the core under you (alpha 0: none)
# Reused per tick (map coords: unit disc, +y = forward; |v| = 1 on the rim).
var _fr := PackedVector2Array()
var _pg := PackedVector2Array()
var _pg_age := PackedFloat32Array()
var _pg_rim := PackedByteArray()
var _cp := PackedVector2Array()
var _cp_txt := PackedStringArray()
var _cp_col := PackedColorArray()
var _cp_rim := PackedByteArray()
var _ar := PackedVector2Array()        # unit directions toward the other planet(s)
var _ar_txt := PackedStringArray()
var _ar_col := PackedColorArray()
var _ar_pulse := PackedFloat32Array()  # 0..1: the newest loud enemy shot over there
var _ar_body: Array = []
var _wedge := PackedVector2Array()
var _tri := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var _dia := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var _font_c: Font
var _font_n: Font


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("gameplay_overlay")
	_font_c = UI.font_caps(700, 1)
	_font_n = UI.font_num(600)
	_wedge.resize(10)


# =================================================================================================
# Layout and projection (static: tests)
# =================================================================================================

## The disc for a viewport size: Vector3(centre x, centre y, radius) in px.
static func layout(vs: Vector2) -> Vector3:
	var k := UI.scale_k(vs)
	return Vector3(vs.x - RIGHT_X * k, TOP_Y * k, RADIUS * k)


## Where things stacked under the radar on the right (the kill feed, craft pills) may start.
static func bottom_y(vs: Vector2) -> float:
	var l := layout(vs)
	return l.y + l.z + 14.0 * UI.scale_k(vs)


## The map frame at a point whose unit up is `up`: [right, fwd] in the tangent plane, fwd = the
## camera's forward flattened (looking straight down: its up vector; straight up: minus it).
static func heading(up: Vector3, cam_basis: Basis) -> Array:
	var fz := -cam_basis.z
	var f := fz - up * fz.dot(up)
	if f.length_squared() < 0.0225:
		var y := cam_basis.y * (1.0 if fz.dot(up) < 0.0 else -1.0)
		f = y - up * y.dot(up)
	if f.length_squared() < 1e-8:
		f = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	f = f.normalized()
	return [f.cross(up).normalized(), f]


## World point p on the planet (centre c, base radius `radius`) seen from a player whose unit up is
## `up`: Vector3(x m to the right, y m forward, geodesic m). The geodesic distance is the angle
## between the two up vectors × radius; the direction is the great circle's in the tangent plane.
## The antipode (no direction) lands straight behind.
static func map_point(p: Vector3, c: Vector3, up: Vector3, right: Vector3, fwd: Vector3, radius: float) -> Vector3:
	var u := p - c
	var l := u.length()
	if l < 1e-4:
		return Vector3.ZERO
	u /= l
	var ca := clampf(u.dot(up), -1.0, 1.0)
	var s := acos(ca) * radius
	var t := u - up * ca
	var tl := t.length()
	if tl < 1e-6:
		return Vector3(0.0, -s if ca < 0.0 else 0.0, s)
	t /= tl
	return Vector3(t.dot(right) * s, t.dot(fwd) * s, s)


## Map coordinates (unit disc, +y forward) of map_point's result; rim = clamped to 1.
static func to_disc(m: Vector3, range_m := RANGE_M) -> Vector2:
	var v := Vector2(m.x, m.y) / range_m
	if v.length_squared() > 1.0:
		v = v.normalized()
	return v


# =================================================================================================
# Update (TICK)
# =================================================================================================

func _process(delta: float) -> void:
	_t -= delta
	_list_t -= delta
	if _t > 0.0:
		return
	_t = TICK
	var was := _mode
	_update()
	if _mode != 0 or was != 0:
		queue_redraw()


func _update() -> void:
	_mode = 0
	var pl = Game.player
	var cam := get_viewport().get_camera_3d()
	if pl == null or not is_instance_valid(pl) or cam == null or Game.overlays_hidden():
		return
	_my_team = Game.team_of(pl)
	_lv = HudLevel.shown_level()
	var me := cam.global_position
	var body: Node3D = Game.dominant_body(me)
	if body == null:
		return
	var cb := cam.global_transform.basis.orthonormalized()
	var vs := get_viewport_rect().size
	var aspect := vs.x / maxf(vs.y, 1.0)
	_half_fov = clampf(atan(tan(deg_to_rad(cam.fov) * 0.5) * aspect), 0.2, 1.25)
	var c := body.global_position
	var radius := float(body.get("radius")) if body.get("radius") != null else 60.0
	var up := (me - c).normalized()
	var space := me.distance_to(c) - radius > SPACE_ALT
	var right: Vector3
	var fwd: Vector3
	if space:
		_mode = 2
		up = cb.y
		right = cb.x
		fwd = -cb.z
	else:
		_mode = 1
		var hf := heading(up, cb)
		right = hf[0]
		fwd = hf[1]
	_fr.clear()
	_pg.clear()
	_pg_age.clear()
	_pg_rim.clear()
	_cp.clear()
	_cp_txt.clear()
	_cp_col.clear()
	_cp_rim.clear()
	_core_col = Color(0, 0, 0, 0)
	_update_arrows(me, body, up, right, fwd, space)
	# Pings: the other side's loud shots; on another planet (or anywhere while in space) they pulse
	# that planet's chevron.
	for pg in ShotPings.recent(PING_AGE):
		if not bool(pg["loud"]):
			continue
		var tm := str(pg["team"])
		if tm == "" or tm == _my_team:
			continue
		var age := float(pg["age"])
		var pb = pg["body"]
		if space or (pb != null and pb != body):
			var ai := _ar_body.find(pb)
			if ai >= 0:
				_ar_pulse[ai] = maxf(_ar_pulse[ai], 1.0 - age / PING_AGE)
			continue
		var m := map_point(pg["pos"], c, up, right, fwd, radius)
		_pg.append(to_disc(m))
		_pg_age.append(age)
		_pg_rim.append(1 if m.z > RANGE_M else 0)
	if space:
		return
	# Teammates within range (never beyond the rim, never on the other planet).
	if _list_t <= 0.0:
		_list_t = LIST_DT
		_units.clear()
		for g in GROUPS:
			for n in get_tree().get_nodes_in_group(g):
				if n is Node3D and n != pl and Game.team_of(n) == _my_team:
					_units.append(n)
	for n in _units:
		if not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
			continue
		if n.has_method("is_dead") and bool(n.call("is_dead")):
			continue
		var p := (n as Node3D).global_position
		if p.distance_to(c) > radius + SPACE_ALT:
			continue
		var m := map_point(p, c, up, right, fwd, radius)
		if m.z <= RANGE_M:
			_fr.append(to_disc(m))
	# Control points of this planet.
	var cpn := get_tree().get_first_node_in_group("control_points")
	if cpn != null:
		var zs = cpn.get("zones")
		if zs is Array:
			for z in zs:
				if not (z is Dictionary) or z.get("body") != body:
					continue
				var d: Vector3 = z.get("dir", Vector3.UP)
				var m := map_point(c + d * float(z.get("ground_r", radius)), c, up, right, fwd, radius)
				var own := str(z.get("owner", ""))
				var col := NEUTRAL_COL if own == "" else (FRIEND_COL if own == _my_team else ENEMY_COL)
				if bool(z.get("contested", false)) and fmod(Time.get_ticks_msec() / 1000.0, 0.7) < 0.35:
					col = UI.WARN
				_cp.append(to_disc(m))
				_cp_txt.append(str(z.get("letter", "")))
				_cp_col.append(col)
				_cp_rim.append(1 if m.z > RANGE_M else 0)
	# The core under you.
	for co in get_tree().get_nodes_in_group("war_core"):
		if co.get("body") == body:
			var mine := str(co.get("team")) == _my_team
			_core_col = Color(FRIEND_COL if mine else ENEMY_COL, 0.3 if bool(co.get("destroyed")) else 0.85)


## The chevrons toward the other planet(s) (every planet while in space).
func _update_arrows(me: Vector3, body: Node3D, up: Vector3, right: Vector3, fwd: Vector3, space: bool) -> void:
	_ar.clear()
	_ar_txt.clear()
	_ar_col.clear()
	_ar_pulse.clear()
	_ar_body.clear()
	var cores := get_tree().get_nodes_in_group("war_core")
	for b in Bodies.all():
		if not is_instance_valid(b) or (b == body and not space):
			continue
		var d: Vector3 = (b as Node3D).global_position - me
		var t := d - up * d.dot(up)
		var v := Vector2(t.dot(right), t.dot(fwd))
		if v.length_squared() < 1e-6:
			v = Vector2(0.0, 1.0)
		var ours: bool = b == Game.planet
		var dead := false
		for co in cores:
			if co.get("body") == b:
				ours = str(co.get("team")) == _my_team
				dead = bool(co.get("destroyed"))
		_ar.append(v.normalized())
		_ar_txt.append("YURT" if ours else "RAKİP")
		_ar_col.append(Color(FRIEND_COL if ours else ENEMY_COL, 0.45 if dead else 1.0))
		_ar_pulse.append(0.0)
		_ar_body.append(b)


# =================================================================================================
# Draw
# =================================================================================================

func _draw() -> void:
	if _mode == 0:
		return
	var l := layout(size)
	var ctr := Vector2(l.x, l.y)
	var r := l.z
	var k := UI.scale_k(size)
	var sade := _lv <= HudLevel.SADE
	# Disc, range rings, rim.
	draw_circle(ctr, r, Color(UI.GLASS, 0.62))
	draw_circle(ctr, r * 0.97, Color(UI.GLASS_HI, 0.18))
	if not sade and _mode == 1:
		var rc := Color(UI.SCREEN_CYAN, 0.09)
		draw_arc(ctr, r / 3.0, 0.0, TAU, 40, rc, 1.0, true)
		draw_arc(ctr, r * 2.0 / 3.0, 0.0, TAU, 56, rc, 1.0, true)
		draw_line(ctr - Vector2(r * 0.97, 0.0), ctr + Vector2(r * 0.97, 0.0), Color(UI.SCREEN_CYAN, 0.05), 1.0)
		draw_line(ctr - Vector2(0.0, r * 0.97), ctr + Vector2(0.0, r * 0.97), Color(UI.SCREEN_CYAN, 0.05), 1.0)
	# The view cone (heading-up: always up).
	var n := _wedge.size() - 1
	_wedge[0] = ctr
	for i in n:
		var a := -PI * 0.5 - _half_fov + 2.0 * _half_fov * float(i) / float(n - 1)
		_wedge[i + 1] = ctr + Vector2(cos(a), sin(a)) * r * 0.94
	draw_colored_polygon(_wedge, Color(UI.SCREEN_CYAN, 0.075))
	draw_arc(ctr, r, 0.0, TAU, 72, Color(UI.SCREEN_CYAN, 0.38), maxf(1.2 * k, 1.0), true)
	draw_line(ctr + Vector2(0.0, -r), ctr + Vector2(0.0, -r + 5.0 * k), Color(UI.SCREEN_CYAN, 0.6), maxf(1.5 * k, 1.0))
	if _mode == 1:
		_draw_objectives(ctr, r, k, sade)
		for v in _fr:
			draw_circle(ctr + _px(v, r), 2.6 * k, Color(UI.OUTLINE, 0.7))
			draw_circle(ctr + _px(v, r), 2.0 * k, FRIEND_COL)
		_draw_pings(ctr, r, k)
		if _core_col.a > 0.0:
			_diamond(ctr, 9.0 * k, _core_col, maxf(1.4 * k, 1.0))
	_draw_arrows(ctr, r, k, sade)
	# The player's arrow.
	var s := 6.0 * k
	_tri[0] = ctr + Vector2(0.0, -s * 1.15)
	_tri[1] = ctr + Vector2(s * 0.8, s * 0.85)
	_tri[2] = ctr + Vector2(0.0, s * 0.4)
	_tri[3] = ctr + Vector2(-s * 0.8, s * 0.85)
	draw_colored_polygon(_tri, UI.SUIT_WHITE)
	if _lv >= HudLevel.DETAYLI and _mode == 1:
		UI.draw_text_r(self, _font_n, ctr.x + r, ctr.y + r + 2.0 * k, "%d m" % int(RANGE_M), UI.fs(10, k), Color(UI.DIM, 0.8), 2)


func _px(v: Vector2, r: float) -> Vector2:
	return Vector2(v.x, -v.y) * r


func _draw_objectives(ctr: Vector2, r: float, k: float, sade: bool) -> void:
	var fsz := UI.fs(10, k)
	for i in _cp.size():
		var col: Color = _cp_col[i]
		if _cp_rim[i] != 0:
			draw_circle(ctr + _px(_cp[i], r * 0.95), 1.9 * k, Color(col, 0.8))
			continue
		var p := ctr + _px(_cp[i], r)
		if sade:
			draw_rect(Rect2(p - Vector2(2.6, 2.6) * k, Vector2(5.2, 5.2) * k), Color(col, 0.9))
			continue
		draw_circle(p, 6.5 * k, Color(UI.GLASS, 0.75))
		draw_arc(p, 6.5 * k, 0.0, TAU, 16, Color(col, 0.75), maxf(1.0 * k, 1.0), true)
		UI.draw_text_c(self, _font_c, p + Vector2(0.0, fsz * 0.36), _cp_txt[i], fsz, col, 0)


func _draw_pings(ctr: Vector2, r: float, k: float) -> void:
	for i in _pg.size():
		var age: float = _pg_age[i]
		var a := clampf((PING_AGE - age) / 1.2, 0.0, 1.0)
		var rim := _pg_rim[i] != 0
		var p := ctr + _px(_pg[i], r * (0.95 if rim else 1.0))
		if age < 0.45:
			var q := age / 0.45
			draw_arc(p, (3.0 + 8.0 * q) * k, 0.0, TAU, 18, Color(ENEMY_COL, 0.8 * (1.0 - q)), maxf(1.3 * k, 1.0), true)
		var rad := (2.2 if rim else 3.4) * k
		draw_circle(p, rad + 0.8 * k, Color(UI.OUTLINE, 0.6 * a))
		draw_circle(p, rad, Color(ENEMY_COL, a))


func _draw_arrows(ctr: Vector2, r: float, k: float, sade: bool) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for i in _ar.size():
		var v: Vector2 = _ar[i]
		var dir := Vector2(v.x, -v.y)
		var side := Vector2(-dir.y, dir.x)
		var tip := ctr + dir * (r - 2.0 * k)
		var col: Color = _ar_col[i]
		var pulse: float = _ar_pulse[i]
		if pulse > 0.0:
			var w := 0.5 + 0.5 * sin(now * 14.0)
			draw_circle(tip - dir * 5.0 * k, (6.0 + 3.0 * w) * k, Color(ENEMY_COL, 0.35 * pulse))
			col = col.lerp(Color(ENEMY_COL, col.a), pulse * (0.4 + 0.6 * w))
		var h := 8.0 * k
		_tri[0] = tip
		_tri[1] = tip - dir * h + side * h * 0.62
		_tri[2] = tip - dir * h * 0.55
		_tri[3] = tip - dir * h - side * h * 0.62
		draw_colored_polygon(_tri, col)
		if not sade:
			var fsz := UI.fs(9, k)
			var lp := tip - dir * (h + 9.0 * k)
			UI.draw_text_c(self, _font_c, lp + Vector2(0.0, fsz * 0.36), _ar_txt[i], fsz, Color(col, 0.85 * col.a), 2)


func _diamond(c: Vector2, s: float, col: Color, w: float) -> void:
	_dia[0] = c + Vector2(0.0, -s)
	_dia[1] = c + Vector2(s, 0.0)
	_dia[2] = c + Vector2(0.0, s)
	_dia[3] = c + Vector2(-s, 0.0)
	_dia[4] = _dia[0]
	draw_polyline(_dia, col, w, true)
