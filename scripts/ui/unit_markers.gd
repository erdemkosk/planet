extends Control
## Unit markers (readability, 2026-10-06): who is who on screen, kept minimal.
##   ENEMY "spotted" chevron: a small filled red chevron over the head, only while the enemy is
##     spotted, fading out SPOT_TIME s after the last time it was:
##       (a) aimed at: within AIM_DEG of the view centre (or within its body width up close) WITH line
##           of sight: ONE physics ray against the terrain (Game.LAYER_TERRAIN), only for the best
##           candidate, its answer reused for RAY_DT s;
##       (b) revealed by the wrist scanner (tunnel_scanner.gd revealed_targets(), kind "bot", read
##           every SCAN_DT s): while the scanner's own diamond is up no chevron (no double marks), it
##           lingers after;
##       (c) it just shot at you: Game.shot_fired from the other team whose line passes within
##           SHOT_NEAR m of you spots the enemy nearest the muzzle (ai_rival.gd / net_bot.gd /
##           net_players.gd emit it for every bot / remote shot).
##   FRIENDLY chevron: a tiny thin cyan one over ally bots / a co-op partner, only on screen and
##     closer than FRIEND_RANGE m (fading over the last FRIEND_FADE m).
##   Names: never in Sade; Normal: the short name of the unit under the crosshair (with line of
##     sight); Detaylı: its full callsign and the distance.
## Smooth: the marker sits at the unit node's own transform + its up × HEAD_H, read in _draw (after
## every _process: the bots' render-interpolated transform of this frame, ai_rival.gd
## _show_interpolated / net_bot / remote_avatar / training_dummy), never at a bone (posed at the
## bots' lower pose rate) nor at a physics-tick position. Cheap: no per-frame allocations (reused
## point arrays and query, the unit list refreshed every LIST_DT s), at most one ray per RAY_DT.
## Units: groups "war_ai" (ai_rival.gd incl. ally bots, net_bot.gd, training_dummy.gd) and
## "net_player" (remote_avatar.gd); friend / enemy = Game.team_of(unit) vs the local player's (teams
## are local strings in multiplayer: "rival" is the other side on each machine). Training dummies
## (team "rival") count as enemies. Purely local and cosmetic; nothing here is synced.
## Child of the combat overlay (scripts/ui/combat_hud.gd), group "gameplay_overlay" (hidden on the
## end screen / menus / pause: overlay_guard.gd).

const UI := preload("res://scripts/ui/ui_style.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")

const GROUPS := ["war_ai", "net_player"]
const SPOT_TIME := 2.5            # s a spotted enemy keeps its chevron...
const FADE := 0.6                 # ...fading over the last this many s
const AIM_DEG := 4.0              # aim cone that spots (with line of sight)
const AIM_BODY_R := 0.55          # m: up close a target spots anywhere within its body width
const AIM_RANGE := 400.0          # m
const RAY_DT := 0.08              # s a line-of-sight answer is reused
const SHOT_NEAR := 4.5            # m: an enemy round passing this close to you spots its shooter
const SHOOTER_R := 3.0            # m: the shooter is the enemy unit this close to the muzzle
const FRIEND_RANGE := 60.0        # m: friendly chevrons only this close (and on screen)
const FRIEND_FADE := 15.0         # m of fade-out before FRIEND_RANGE
const FRIEND_ALPHA := 0.5
const LIST_DT := 0.25             # s between unit list refreshes
const SCAN_DT := 0.2              # s between scanner reads
const AIM_LINGER := 0.35          # s the aimed name stays after the crosshair leaves
const HEAD_H := 2.2               # m over the unit's feet: the chevron's tip
const CHEST_H := 1.3              # m over the feet: aim / line-of-sight point
const ENEMY_COL := Color(1.0, 0.24, 0.16)
const FRIEND_COL := Color(0.45, 0.88, 1.0)

var _units: Array = []            # Node3D, refreshed every LIST_DT
var _spot := {}                   # instance id -> s left
var _pop := {}                    # instance id -> 0..1 pop-in of a fresh spot
var _scan_a := {}                 # instance id -> the scanner's own mark alpha (no chevron while it shows)
var _gone: Array = []             # (reused) expired ids
var _los_id := 0                  # the last line-of-sight answer: unit, time, result
var _los_ms := 0
var _los_ok := false
var _q: PhysicsRayQueryParameters3D
var _aim_id := 0                  # the unit under the crosshair with line of sight (names), 0 none
var _aim_node: Node3D
var _aim_t := 0.0
var _aim_txt := ""
var _aim_txt_t := 0.0
var _aim_lv := -1
var _list_t := 0.0
var _scan_t := 0.0
var _my_team := "home"
var _drew := false
var _pe := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var _pe_ol := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var _pf := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("gameplay_overlay")
	_q = PhysicsRayQueryParameters3D.new()
	_q.collision_mask = Game.LAYER_TERRAIN
	Game.shot_fired.connect(_on_shot)


## Marks enemy `n` as spotted (any script may call it, e.g. a future radar ping).
func spot(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	var id := n.get_instance_id()
	if not _spot.has(id):
		_pop[id] = 1.0
	_spot[id] = SPOT_TIME


func _process(delta: float) -> void:
	var pl = Game.player
	var cam := get_viewport().get_camera_3d()
	if pl == null or not is_instance_valid(pl) or cam == null:
		if _drew:
			_drew = false
			queue_redraw()
		return
	_my_team = Game.team_of(pl)
	_list_t -= delta
	if _list_t <= 0.0:
		_list_t = LIST_DT
		_refresh_units()
	if not _spot.is_empty():
		_gone.clear()
		for id in _spot:
			var left: float = float(_spot[id]) - delta
			_spot[id] = left
			if left <= 0.0:
				_gone.append(id)
		for id in _gone:
			_spot.erase(id)
			_pop.erase(id)
		for id in _pop:
			_pop[id] = maxf(float(_pop[id]) - delta * 4.0, 0.0)
	_scan_t -= delta
	if _scan_t <= 0.0:
		_scan_t = SCAN_DT
		_read_scanner(pl)
	_aim(cam, delta)
	var busy := not _spot.is_empty() or _aim_id != 0 or not _units.is_empty()
	if busy or _drew:
		queue_redraw()
	_drew = busy


func _refresh_units() -> void:
	_units.clear()
	for g in GROUPS:
		for n in get_tree().get_nodes_in_group(g):
			if n is Node3D and n != Game.player and not _units.has(n):
				_units.append(n)


# --- Spotting ---------------------------------------------------------------------------------------

## (a) The best unit inside the aim cone, if in line of sight: spots it (enemy), names it.
func _aim(cam: Camera3D, delta: float) -> void:
	var cp := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var best: Node3D = null
	var best_s := INF
	for n in _units:
		if not _alive(n):
			continue
		var to: Vector3 = _at(n, CHEST_H) - cp
		var d := to.length()
		if d < 0.5 or d > AIM_RANGE:
			continue
		var c := fwd.dot(to / d)
		if c <= 0.5:
			continue
		var lim := maxf(deg_to_rad(AIM_DEG), atan(AIM_BODY_R / d))
		var s := acos(clampf(c, -1.0, 1.0)) / lim
		if s <= 1.0 and s < best_s:
			best_s = s
			best = n
	if best != null and _clear_to(best, cam):
		if _enemy(best):
			spot(best)
		var id := best.get_instance_id()
		if id != _aim_id:
			_aim_txt_t = 0.0
		_aim_id = id
		_aim_node = best
		_aim_t = AIM_LINGER
	else:
		_aim_t = maxf(_aim_t - delta, 0.0)
		if _aim_t <= 0.0:
			_aim_id = 0
			_aim_node = null
	# The name text: rebuilt only when the aimed unit / level changes or every LIST_DT (the distance).
	_aim_txt_t -= delta
	var lv := HudLevel.shown_level()
	if _aim_id != 0 and (_aim_txt_t <= 0.0 or lv != _aim_lv) and is_instance_valid(_aim_node):
		_aim_txt_t = LIST_DT
		_aim_lv = lv
		_aim_txt = ""
		if lv >= HudLevel.NORMAL:
			var full := lv >= HudLevel.DETAYLI
			_aim_txt = _name(_aim_node, full)
			if full:
				var dm := int(cp.distance_to(_aim_node.global_position))
				_aim_txt = UI.upper_tr("%s  ·  %d m" % [_aim_txt, dm]) if _aim_txt != "" else "%d m" % dm


## Line of sight from the camera to the unit's chest: terrain only, one ray, reused RAY_DT s.
func _clear_to(n: Node3D, cam: Camera3D) -> bool:
	var id := n.get_instance_id()
	var now := Time.get_ticks_msec()
	if id == _los_id and now - _los_ms < int(RAY_DT * 1000.0):
		return _los_ok
	var from := cam.global_position
	var seg := _at(n, CHEST_H) - from
	var l := seg.length()
	var ok := true
	if l > 0.7:
		_q.from = from
		_q.to = from + seg * ((l - 0.5) / l)
		ok = cam.get_world_3d().direct_space_state.intersect_ray(_q).is_empty()
	_los_id = id
	_los_ms = now
	_los_ok = ok
	return ok


## (b) What the wrist scanner reveals right now (enemy bots).
func _read_scanner(pl) -> void:
	_scan_a.clear()
	var ha = pl.get("hand_action")
	var sc = ha.get("scanner") if ha != null and is_instance_valid(ha) else null
	if sc == null or not is_instance_valid(sc) or not sc.has_method("revealing") or not sc.revealing():
		return
	if not sc.has_method("revealed_targets"):
		return
	for e in sc.revealed_targets():
		if not (e is Dictionary) or str(e.get("kind", "")) != "bot":
			continue
		var n = e.get("node")
		if n is Node3D and is_instance_valid(n) and _enemy(n):
			_scan_a[(n as Node).get_instance_id()] = float(e.get("alpha", 1.0))
			spot(n)


## (c) A shot of the other side passed close to the local player: spot its shooter.
func _on_shot(from: Vector3, dir: Vector3, team: String) -> void:
	if team == "" or team == _my_team or team == "meteor":
		return
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or not (pl is Node3D):
		return
	var pn := pl as Node3D
	var pc := pn.global_position + pn.global_transform.basis.y * 1.2
	var t := (pc - from).dot(dir)
	if t < 0.0 or (from + dir * t).distance_to(pc) > SHOT_NEAR:
		return
	var best: Node3D = null
	var bd := SHOOTER_R
	for n in _units:
		if not _alive(n) or Game.team_of(n) != team:
			continue
		var d := _at(n, CHEST_H).distance_to(from)
		if d < bd:
			bd = d
			best = n
	if best != null:
		spot(best)


# --- Unit helpers -----------------------------------------------------------------------------------

func _alive(n) -> bool:
	if n == null or not is_instance_valid(n) or not (n as Node).is_inside_tree():
		return false
	if not (n as Node3D).is_visible_in_tree():
		return false
	return not (n.has_method("is_dead") and n.is_dead())


func _enemy(n) -> bool:
	var t := Game.team_of(n)
	return t != "" and t != _my_team


## A point h m above the unit's feet along its up: from the node's own (render-interpolated) transform.
func _at(n: Node3D, h: float) -> Vector3:
	var xf := n.global_transform
	var u := xf.basis.y
	var l := u.length()
	return xf.origin + (u / l if l > 1e-4 else Vector3.UP) * h


func _name(n: Node, full: bool) -> String:
	var s := ""
	if n.get("callsign") != null:
		s = str(n.get("callsign"))
	elif n.get("player_name") != null:
		s = str(n.get("player_name"))
	if s == "" or full:
		return s
	var parts := s.split(" — ")
	return parts[parts.size() - 1]


# --- Draw ---------------------------------------------------------------------------------------------

func _draw() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or Game.player == null:
		return
	var k := UI.scale_k(size)
	var cp := cam.global_position
	var view := Rect2(Vector2.ZERO, size).grow(-6.0)
	for n in _units:
		if not _alive(n):
			continue
		var id := (n as Node).get_instance_id()
		var enemy := _enemy(n)
		var spotted := enemy and _spot.has(id)
		var named := id == _aim_id and _aim_txt != ""
		if enemy and not spotted and not named:
			continue
		var hp := _at(n, HEAD_H)
		var d := cp.distance_to(hp)
		if not enemy and d >= FRIEND_RANGE and not named:
			continue
		if cam.is_position_behind(hp):
			continue
		var sp := cam.unproject_position(hp)
		if not view.has_point(sp):
			continue
		if spotted:
			var a := clampf(float(_spot[id]) / FADE, 0.0, 1.0)
			a *= 1.0 - clampf(float(_scan_a.get(id, 0.0)) * 1.5, 0.0, 1.0)
			if a > 0.01:
				_chevron_enemy(sp, k * (1.0 + 0.45 * float(_pop.get(id, 0.0))), a)
		elif not enemy and d < FRIEND_RANGE:
			var fa := clampf((FRIEND_RANGE - d) / FRIEND_FADE, 0.0, 1.0) * FRIEND_ALPHA
			if fa > 0.01:
				_chevron_friend(sp, k, fa)
		if named:
			var col := ENEMY_COL.lightened(0.3) if enemy else FRIEND_COL.lightened(0.2)
			var na := clampf(_aim_t / 0.15, 0.0, 1.0) * (1.0 if enemy else 0.85)
			UI.draw_text_c(self, UI.font_caps(700, 1), sp + Vector2(0.0, -13.0 * k), _aim_txt, UI.fs(11, k), Color(col, na), 3)


## A small filled chevron pointing down at the head, outlined (never pure black).
func _chevron_enemy(p: Vector2, s: float, a: float) -> void:
	var w := 6.5 * s
	var h := 6.0 * s
	var notch := 2.6 * s
	_pe[0] = p + Vector2(-w, -h)
	_pe[1] = p + Vector2(0.0, -h + notch)
	_pe[2] = p + Vector2(w, -h)
	_pe[3] = p
	for i in 4:
		_pe_ol[i] = _pe[i]
	_pe_ol[4] = _pe[0]
	draw_polyline(_pe_ol, Color(UI.OUTLINE, UI.OUTLINE.a * a), 3.0 * s, true)
	draw_colored_polygon(_pe, Color(ENEMY_COL, 0.95 * a))


## A tiny thin cyan chevron (friends: subtle).
func _chevron_friend(p: Vector2, s: float, a: float) -> void:
	var w := 4.5 * s
	var h := 3.5 * s
	_pf[0] = p + Vector2(-w, -h)
	_pf[1] = p
	_pf[2] = p + Vector2(w, -h)
	draw_polyline(_pf, Color(UI.OUTLINE, UI.OUTLINE.a * a), 3.2 * s, true)
	draw_polyline(_pf, Color(FRIEND_COL, a), 1.5 * s, true)
