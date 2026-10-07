extends Control
## The Mekik's instrument screen (skiff.gd): drawn into a small SubViewport whose texture lights the
## pilot's display on the dash (diegetic, no 2D overlay). Turkish labels.
##   left    HIZ (speed), DİKEY (vertical speed), İTKİ / TAKVİYE bars
##   centre  RADAR (default; R in the pilot seat cycles 400 m › 150 m › UFUK) or the attitude ball
##           (pitch ladder, bank); the mode line under it
##   right   İRTİFA (height of the feet above the ground), distance to the YURT / RAKİP surfaces,
##           GÖVDE (hull) bar
## Skiff.gd fills `data` and calls refresh() ~20 times a second while the ship is powered.
## Radar (radar_scan, filled by skiff.gd into data["radar"]): top-down on the local horizontal plane,
## the ship's heading up, the ship in the middle. Both planets as discs (their projection: the one
## under us fills the scope) labelled YURT / RAKİP, the cores (diamonds; out of range: on the rim with
## a tick toward them), our structures (cyan squares) and theirs (red), skiffs (triangles along their
## heading: ours cyan, enemy red), enemy drop pods in flight (red, ringed), incoming shells / torpedoes
## (blinking), the other player (co-op green, PvP red), carriers (groups "war_carrier" / "respawn_ship",
## big hexagons). A carat over / under a far-above / below contact. Built only from replicated nodes
## and groups, so a client's dash shows the same.

const UI := preload("res://scripts/ui/ui_style.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const SIZE := Vector2i(768, 384)
const RADAR_C := Vector2(384.0, 158.0)
const RADAR_R := 116.0
const RADAR_RANGES := [400.0, 150.0]       # m (skiff.gd radar_mode 0, 1; 2 = the attitude ball)
const HOME_COL := Color(0.42, 0.85, 1.0)
const ENEMY_COL := Color(1.0, 0.36, 0.3)

const BG := Color(0.035, 0.06, 0.085)
const LINE := Color(0.35, 0.62, 0.78, 0.35)
const TXT := Color(0.86, 0.93, 0.98)
const DIM := Color(0.5, 0.62, 0.72)
const CYAN := Color(0.42, 0.85, 1.0)
const AMBER := Color(1.0, 0.72, 0.3)
const RED := Color(1.0, 0.38, 0.32)
const GREEN := Color(0.45, 0.92, 0.6)
const SKY := Color(0.2, 0.36, 0.52)
const GROUND := Color(0.42, 0.29, 0.18)

var data := {}
var viewport: SubViewport
var _f: Font
var _fb: Font
var _t := 0.0


## Builds the viewport with this screen in it; the returned node goes under the ship.
static func create() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	var d: Control = load("res://scripts/craft/skiff_dash.gd").new()
	d.viewport = vp
	d.size = Vector2(SIZE)
	vp.add_child(d)
	return vp


func _ready() -> void:
	_f = UI.font(500)
	_fb = UI.font(700)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = Vector2(SIZE)


## Redraws and renders the viewport once.
func refresh(delta: float) -> void:
	_t += delta
	queue_redraw()
	if viewport != null:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _draw() -> void:
	var w := float(SIZE.x)
	var h := float(SIZE.y)
	draw_rect(Rect2(0, 0, w, h), BG)
	if not bool(data.get("power", false)):
		# Standby: a dim logo and nothing else.
		_text(Vector2(w * 0.5, h * 0.52), "MEKİK", 30, Color(DIM, 0.25), _fb, HORIZONTAL_ALIGNMENT_CENTER)
		return
	# Faint scan lines and the frame.
	for y in range(0, int(h), 4):
		draw_line(Vector2(0, y), Vector2(w, y), Color(1, 1, 1, 0.012))
	draw_rect(Rect2(6, 6, w - 12, h - 12), LINE, false, 2.0)
	draw_line(Vector2(250, 20), Vector2(250, h - 20), LINE, 1.0)
	draw_line(Vector2(518, 20), Vector2(518, h - 20), LINE, 1.0)
	_left(w, h)
	_center(w, h)
	_right(w, h)


func _left(_w: float, h: float) -> void:
	var sp: float = float(data.get("speed", 0.0))
	var vs: float = float(data.get("vspeed", 0.0))
	_text(Vector2(26, 46), "HIZ", 18, DIM, _fb)
	_text(Vector2(26, 118), "%d" % roundi(sp), 72, TXT, _fb)
	_text(Vector2(30 + _fb.get_string_size("%d" % roundi(sp), HORIZONTAL_ALIGNMENT_LEFT, -1, 72).x, 118), "m/s", 22, DIM, _f)
	_text(Vector2(26, 170), "DİKEY", 18, DIM, _fb)
	var vc := TXT
	if vs < -4.0 and float(data.get("clear", 99.0)) < 15.0:
		vc = AMBER
	_text(Vector2(26, 212), ("%+.1f" % vs) + " m/s", 34, vc, _fb)
	# Vertical-speed arrow.
	var ax := 214.0
	var ay := 196.0
	var dir := -1.0 if vs > 0.2 else (1.0 if vs < -0.2 else 0.0)
	if dir != 0.0:
		draw_colored_polygon(PackedVector2Array([Vector2(ax - 10, ay - dir * 6), Vector2(ax + 10, ay - dir * 6),
				Vector2(ax, ay + dir * 10)]), Color(vc, 0.9))
	# Thrust and boost bars.
	var thr: float = clampf(float(data.get("thrust", 0.0)), 0.0, 1.0)
	var bo: float = clampf(float(data.get("boost", 0.0)), 0.0, 1.0)
	_bar(Vector2(26, 252), 200.0, thr, CYAN, "İTKİ")
	_bar(Vector2(26, 300), 200.0, bo, AMBER, "TAKVİYE")
	if data.has("heat"):
		# Armed variant (armed_skiff.gd): the gun's heat instead of the name plate.
		var heat: float = clampf(float(data.get("heat", 0.0)), 0.0, 1.0)
		var over: bool = bool(data.get("overheat", false))
		var hc := GREEN.lerp(AMBER, smoothstep(0.45, 0.7, heat)).lerp(RED, smoothstep(0.75, 0.95, heat))
		if over:
			hc = RED if fmod(_t, 0.5) < 0.3 else Color(RED, 0.45)
		_bar(Vector2(26, h - 36), 200.0, heat, hc, "AŞIRI ISINDI" if over else "TOP ISISI")
	else:
		_text(Vector2(26, h - 30), str(data.get("reg", "MEKİK · YR-01")), 15, Color(DIM, 0.6), _f)


func _center(w: float, h: float) -> void:
	if data.get("radar") is Dictionary:
		_radar(data["radar"])
		_mode_lines(w)
		return
	var c := Vector2(w * 0.5, 160.0)
	var r := 108.0
	var pitch: float = float(data.get("pitch", 0.0))
	var roll: float = float(data.get("roll", 0.0))
	# Horizon: the ground side of a line rotated by the bank and shifted by the pitch.
	var up := Vector2(sin(roll), -cos(roll))
	var off := clampf(pitch / deg_to_rad(40.0), -1.4, 1.4) * r
	var circle := PackedVector2Array()
	for i in 48:
		var a := TAU * float(i) / 48.0
		circle.append(c + Vector2(cos(a), sin(a)) * r)
	draw_colored_polygon(circle, SKY)
	var ground := _clip_half(circle, c - up * off, up)
	if ground.size() >= 3 and _area(ground) > 30.0:
		draw_colored_polygon(ground, GROUND)
	# Pitch ladder every 10 degrees.
	var right := Vector2(-up.y, up.x)
	for k in range(-3, 4):
		if k == 0:
			continue
		var po := c + up * (-off + float(k) * deg_to_rad(10.0) / deg_to_rad(40.0) * r)
		if po.distance_to(c) > r - 12.0:
			continue
		var hw := 26.0 if k % 2 == 0 else 15.0
		draw_line(po - right * hw, po + right * hw, Color(1, 1, 1, 0.55), 2.0)
	var hz := c - up * off
	draw_line(hz - right * r, hz + right * r, Color(1, 1, 1, 0.8), 2.0)
	draw_arc(c, r, 0.0, TAU, 64, Color(LINE, 0.9), 3.0)
	# Fixed aircraft symbol.
	draw_line(c + Vector2(-46, 0), c + Vector2(-14, 0), AMBER, 4.0)
	draw_line(c + Vector2(14, 0), c + Vector2(46, 0), AMBER, 4.0)
	draw_line(c + Vector2(-14, 0), c + Vector2(0, 10), AMBER, 4.0)
	draw_line(c + Vector2(14, 0), c + Vector2(0, 10), AMBER, 4.0)
	draw_circle(c, 3.0, AMBER)
	_text(Vector2(c.x + r - 4.0, c.y - r + 8.0), "UFUK", 14, Color(DIM, 0.8), _fb, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(Vector2(c.x + r - 4.0, c.y - r + 24.0), "R", 13, Color(DIM, 0.55), _f, HORIZONTAL_ALIGNMENT_RIGHT)
	_mode_lines(w)


## Mode line, its sub line and the master warning under the centre instrument.
func _mode_lines(w: float) -> void:
	var mode: String = str(data.get("mode", ""))
	var mc: Color = data.get("mode_color", CYAN)
	_text(Vector2(w * 0.5, 304), mode, 24, mc, _fb, HORIZONTAL_ALIGNMENT_CENTER)
	var sub: String = str(data.get("sub", ""))
	if sub != "":
		_text(Vector2(w * 0.5, 334), sub, 16, DIM, _f, HORIZONTAL_ALIGNMENT_CENTER)
	var warn: String = str(data.get("warn", ""))
	if warn != "" and fmod(_t, 0.8) < 0.5:
		var tw := _fb.get_string_size(warn, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		draw_rect(Rect2(w * 0.5 - tw * 0.5 - 12, 352, tw + 24, 26), Color(RED, 0.25))
		_text(Vector2(w * 0.5, 372), warn, 22, RED, _fb, HORIZONTAL_ALIGNMENT_CENTER)


func _right(w: float, h: float) -> void:
	var x := 540.0
	var clear: float = float(data.get("clear", 0.0))
	_text(Vector2(x, 46), "İRTİFA", 18, DIM, _fb)
	var ct := ("%.1f" % clear) if clear < 100.0 else ("%d" % roundi(clear))
	if clear > 9000.0:
		ct = "—"
	var cc := TXT if clear > 3.0 or float(data.get("vspeed", 0.0)) > -2.0 else AMBER
	_text(Vector2(x, 100), ct, 48, cc, _fb)
	_text(Vector2(x + 6 + _fb.get_string_size(ct, HORIZONTAL_ALIGNMENT_LEFT, -1, 48).x, 100), "m", 20, DIM, _f)
	var targets: Array = data.get("targets", [])
	var y := 150.0
	for t in targets:
		var nm: String = str(t[0])
		var d: float = float(t[1])
		var col: Color = t[2]
		_text(Vector2(x, y), nm, 18, col, _fb)
		var ds := ("%d m" % roundi(d)) if d < 1000.0 else ("%.2f km" % (d / 1000.0))
		_text(Vector2(w - 26, y), ds, 22, TXT, _fb, HORIZONTAL_ALIGNMENT_RIGHT)
		y += 38.0
	# Gravity readout.
	_text(Vector2(x, 236), "ÇEKİM", 15, DIM, _fb)
	_text(Vector2(w - 26, 236), "%.1f m/s²" % float(data.get("grav", 0.0)), 18, TXT, _f, HORIZONTAL_ALIGNMENT_RIGHT)
	# Hull.
	var hp: float = clampf(float(data.get("hp", 1.0)), 0.0, 1.0)
	var hc := GREEN.lerp(AMBER, smoothstep(0.65, 0.4, hp)).lerp(RED, smoothstep(0.4, 0.2, hp))
	_text(Vector2(x, 290), "GÖVDE", 18, DIM, _fb)
	_text(Vector2(w - 26, 290), "%d%%" % roundi(hp * 100.0), 22, hc, _fb, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_rect(Rect2(x, 304, w - 26 - x, 12), Color(1, 1, 1, 0.08))
	draw_rect(Rect2(x, 304, (w - 26 - x) * hp, 12), hc)
	var lights: bool = bool(data.get("lights", false))
	if data.has("rockets"):
		# Armed variant: rockets in the pods, or the reload progress.
		var n: int = int(data.get("rockets", 0))
		var rl: float = float(data.get("rocket_reload", 0.0))
		var rt := ("ROKET  %d / 4" % n) if rl <= 0.0 else ("ROKET  %%%d" % roundi(rl * 100.0))
		_text(Vector2(x, h - 30), rt, 16, AMBER if rl > 0.0 else TXT, _fb)
		for i in 4:
			var lit := i < n
			draw_rect(Rect2(Vector2(w - 26 - 14.0 * float(4 - i), h - 44), Vector2(10, 16)), Color(AMBER, 0.9) if lit else Color(1, 1, 1, 0.1))
	else:
		_text(Vector2(x, h - 30), "IŞIK " + ("AÇIK" if lights else "KAPALI") + "  ·  L", 15, Color(DIM, 0.7), _f)


# =================================================================================================
# Radar
# =================================================================================================

## The radar picture around `ship` (world -> its scope frame, metres): x right, y ahead along the
## heading on the horizontal plane of `up`, h up. Called by skiff.gd while powered (~20 Hz).
##   {"range", "planets": [[x, y, r, label, home]], "items": [[kind, x, y, h, col, ang]]}
##   kind: "core" "struct" "skiff" "pod" "shell" "player" "carrier"; ang: heading on the scope (skiffs)
static func radar_scan(ship: Node3D, up: Vector3, range_m: float) -> Dictionary:
	var c := ship.global_position
	var u := up.normalized() if up.length_squared() > 1e-6 else Vector3.UP
	var b := ship.global_transform.basis.orthonormalized()
	var f := -b.z - u * (-b.z).dot(u)
	if f.length_squared() < 0.02:
		# Nose straight up / down: the top of the ship points back / ahead.
		f = (b.y - u * b.y.dot(u)) * -signf((-b.z).dot(u))
	f = f.normalized() if f.length_squared() > 1e-6 else Vector3.FORWARD
	var r := f.cross(u).normalized()
	var planets: Array = []
	for body in Bodies.all():
		if body == null or not is_instance_valid(body):
			continue
		var rel: Vector3 = (body as Node3D).global_position - c
		var home: bool = body == Game.planet
		planets.append([rel.dot(r), rel.dot(f), float(body.get("radius")), "YURT" if home else "RAKİP", home])
	var items: Array = []
	var tree := ship.get_tree()
	var far := range_m * 1.05
	for n in tree.get_nodes_in_group("war_core"):
		if n is Node3D and is_instance_valid(n) and n.get("destroyed") != true:
			_radar_add(items, "core", (n as Node3D).global_position - c, r, f, u, _team_col(n), 0.0)
	for n in tree.get_nodes_in_group("war_structure"):
		if not (n is Node3D) or not is_instance_valid(n) or n == ship or n.is_in_group("skiff") \
				or n.has_meta("build_preview") or n.get("is_destroyed") == true:
			continue
		var rel: Vector3 = (n as Node3D).global_position - c
		if rel.length() < far * 1.5:
			_radar_add(items, "struct", rel, r, f, u, _team_col(n), 0.0)
	for n in tree.get_nodes_in_group("skiff"):
		if not (n is Node3D) or not is_instance_valid(n) or n == ship or n.get("destroyed") == true:
			continue
		var sf: Vector3 = -(n as Node3D).global_transform.basis.z
		_radar_add(items, "skiff", (n as Node3D).global_position - c, r, f, u, _team_col(n), atan2(sf.dot(r), sf.dot(f)))
	for n in tree.get_nodes_in_group("war_drop_pod"):
		if n is Node3D and is_instance_valid(n) and Game.team_of(n) != "home" and n.has_method("is_live") and n.is_live():
			_radar_add(items, "pod", (n as Node3D).global_position - c, r, f, u, ENEMY_COL, 0.0)
	for n in tree.get_nodes_in_group("war_shell"):
		if not (n is Node3D) or not is_instance_valid(n) or n.is_in_group("war_drop_pod") or Game.team_of(n) == "home":
			continue
		if n.has_method("is_live") and not n.is_live():
			continue
		var rel: Vector3 = (n as Node3D).global_position - c
		if rel.length() < far * 1.5:
			_radar_add(items, "shell", rel, r, f, u, ENEMY_COL, 0.0)
	for n in tree.get_nodes_in_group("net_player"):
		if not (n is Node3D) or not is_instance_valid(n) or n.get("dead") == true:
			continue
		var rel: Vector3 = (n as Node3D).global_position - c
		if rel.length() < 3.5:
			continue                             # (in this ship with us)
		var col: Color = Color(0.45, 0.95, 0.55) if Game.team_of(n) == "home" else ENEMY_COL
		_radar_add(items, "player", rel, r, f, u, col, 0.0)
	for g in ["war_carrier", "respawn_ship"]:
		for n in tree.get_nodes_in_group(g):
			if n is Node3D and is_instance_valid(n):
				_radar_add(items, "carrier", (n as Node3D).global_position - c, r, f, u, _team_col(n), 0.0)
	return {"range": range_m, "planets": planets, "items": items}


static func _radar_add(items: Array, kind: String, rel: Vector3, r: Vector3, f: Vector3, u: Vector3, col: Color, ang: float) -> void:
	items.append([kind, rel.dot(r), rel.dot(f), rel.dot(u), col, ang])


static func _team_col(n: Node) -> Color:
	return HOME_COL if Game.team_of(n) == "home" else ENEMY_COL


func _radar(rd: Dictionary) -> void:
	var c := RADAR_C
	var rr := RADAR_R
	var rng := maxf(float(rd.get("range", 400.0)), 1.0)
	var k := rr / rng
	var scope := _circle_poly(c, rr, 56)
	draw_colored_polygon(scope, Color(0.02, 0.07, 0.07))
	# Planets: their discs, clipped to the scope.
	for p in rd.get("planets", []):
		var pc: Vector2 = c + Vector2(float(p[0]), -float(p[1])) * k
		var pr := float(p[2]) * k
		var home: bool = bool(p[4])
		var col := Color(0.25, 0.75, 0.45) if home else Color(0.95, 0.5, 0.25)
		var dist := pc.distance_to(c)
		if dist - pr > rr:
			# Out of the scope: a tick on the rim toward it, the name inside.
			var dir := (pc - c) / maxf(dist, 1e-3)
			draw_line(c + dir * (rr - 10.0), c + dir * (rr + 2.0), col, 4.0)
			_text(c + dir * (rr - 26.0) + Vector2(0, 5), str(p[3]), 13, col, _fb, HORIZONTAL_ALIGNMENT_CENTER)
			continue
		var disc := _circle_poly(pc, pr, 64)
		for part in Geometry2D.intersect_polygons(disc, scope):
			if (part as PackedVector2Array).size() >= 3:
				draw_colored_polygon(part, Color(col, 0.16))
		var prev := Vector2.INF
		for i in 65:
			var a := TAU * float(i) / 64.0
			var q := pc + Vector2(cos(a), sin(a)) * pr
			var inside := q.distance_to(c) <= rr
			if inside and prev != Vector2.INF:
				draw_line(prev, q, Color(col, 0.75), 2.0)
			prev = q if inside else Vector2.INF
		var lp := pc
		if lp.distance_to(c) > rr - 18.0:
			lp = c + (pc - c).normalized() * (rr - 30.0) if dist > 1.0 else c + Vector2(0, rr * 0.55)
		elif pr > rr * 0.9:
			lp = c + Vector2(0, rr * 0.62)    # (the one under us: its name low in the scope)
		_text(lp + Vector2(0, 5), str(p[3]), 15, col, _fb, HORIZONTAL_ALIGNMENT_CENTER)
	# Range rings and the heading line.
	draw_arc(c, rr * 0.5, 0.0, TAU, 48, Color(LINE, 0.5), 1.0)
	draw_line(c + Vector2(0, -rr), c + Vector2(0, rr), Color(LINE, 0.35), 1.0)
	draw_line(c + Vector2(-rr, 0), c + Vector2(rr, 0), Color(LINE, 0.35), 1.0)
	# Contacts.
	var blink := fmod(_t, 0.5) < 0.3
	for it in rd.get("items", []):
		var kind: String = str(it[0])
		var p := c + Vector2(float(it[1]), -float(it[2])) * k
		var col: Color = it[4]
		var out := p.distance_to(c) > rr - 4.0
		if out:
			if not (kind in ["core", "pod", "player", "carrier", "skiff"]):
				continue
			p = c + (p - c).normalized() * (rr - 4.0)
		match kind:
			"core":
				var s := 8.0
				var dia := PackedVector2Array([p + Vector2(0, -s), p + Vector2(s, 0), p + Vector2(0, s), p + Vector2(-s, 0)])
				draw_colored_polygon(dia, Color(col, 0.35 if out else 0.85))
				draw_polyline(dia + PackedVector2Array([dia[0]]), col, 2.0)
			"struct":
				draw_rect(Rect2(p - Vector2(3.5, 3.5), Vector2(7, 7)), col)
			"skiff":
				var a := float(it[5])
				var fw := Vector2(sin(a), -cos(a))
				var rt := Vector2(-fw.y, fw.x)
				draw_colored_polygon(PackedVector2Array([p + fw * 9.0, p - fw * 6.0 + rt * 6.0, p - fw * 6.0 - rt * 6.0]),
						Color(col, 0.5 if out else 1.0))
			"pod":
				draw_circle(p, 5.0, col)
				if blink:
					draw_arc(p, 9.0, 0.0, TAU, 16, col, 2.0)
			"shell":
				if blink:
					draw_circle(p, 3.5, AMBER if fmod(_t, 1.0) < 0.5 else col)
			"player":
				draw_circle(p, 5.0, col)
				draw_arc(p, 8.0, 0.0, TAU, 16, Color(col, 0.6), 1.5)
			"carrier":
				var hx := PackedVector2Array()
				for i in 6:
					var ha := TAU * float(i) / 6.0
					hx.append(p + Vector2(cos(ha), sin(ha)) * 9.0)
				draw_colored_polygon(hx, Color(col, 0.35))
				hx.append(hx[0])
				draw_polyline(hx, col, 2.0)
		# Far above / below: a carat (a contact more than a quarter of the range up or down).
		var hgt := float(it[3])
		if kind != "struct" and kind != "core" and absf(hgt) > rng * 0.25:
			var sg := -1.0 if hgt > 0.0 else 1.0
			draw_colored_polygon(PackedVector2Array([p + Vector2(0, sg * 15.0), p + Vector2(-4, sg * 10.0), p + Vector2(4, sg * 10.0)]),
					Color(col, 0.8))
	# Our ship, the rim, the range.
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -10), c + Vector2(7, 7), c + Vector2(0, 3), c + Vector2(-7, 7)]), AMBER)
	draw_arc(c, rr, 0.0, TAU, 64, Color(LINE, 0.9), 3.0)
	_text(Vector2(c.x + rr - 2.0, c.y - rr + 8.0), "%d m" % roundi(rng), 15, CYAN, _fb, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(Vector2(c.x + rr - 2.0, c.y - rr + 24.0), "R", 13, Color(DIM, 0.55), _f, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(Vector2(c.x - rr + 2.0, c.y - rr + 8.0), "RADAR", 14, Color(DIM, 0.8), _fb)


static func _circle_poly(c: Vector2, r: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(c + Vector2(cos(a), sin(a)) * r)
	return out


func _bar(p: Vector2, w: float, k: float, col: Color, label: String) -> void:
	_text(p + Vector2(0, -4), label, 15, DIM, _fb)
	draw_rect(Rect2(p + Vector2(0, 6), Vector2(w, 12)), Color(1, 1, 1, 0.07))
	draw_rect(Rect2(p + Vector2(0, 6), Vector2(w * k, 12)), col)
	for i in range(1, 4):
		var tx := p.x + w * float(i) / 4.0
		draw_line(Vector2(tx, p.y + 6), Vector2(tx, p.y + 18), Color(BG, 0.8), 2.0)


func _text(p: Vector2, s: String, size: int, col: Color, f: Font, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var x := p.x
	if align != HORIZONTAL_ALIGNMENT_LEFT:
		var tw := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		x -= tw * (0.5 if align == HORIZONTAL_ALIGNMENT_CENTER else 1.0)
	draw_string(f, Vector2(x, p.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5


## The part of polygon `poly` on the side of the line through `p` that `n` points away from.
static func _clip_half(poly: PackedVector2Array, p: Vector2, n: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var cnt := poly.size()
	for i in cnt:
		var a := poly[i]
		var b := poly[(i + 1) % cnt]
		var da := (a - p).dot(n)
		var db := (b - p).dot(n)
		if da <= 0.0:
			out.append(a)
		if (da <= 0.0) != (db <= 0.0):
			out.append(a + (b - a) * (da / (da - db)))
	return out
