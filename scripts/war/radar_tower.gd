extends "res://scripts/war/base_piece.gd"
## Radar Kulesi (radar tower), İnşa Aracı (Üs; Balance.RADAR_*), on your own planet, on the surface or
## underground (a ground-penetrating set). A painted equipment cabinet with vents and a status screen,
## a three-legged lattice mast and a rotating phased-array panel with a blinking red aviation lamp.
## Every RADAR_SCAN s (on every machine: it reads what that machine sees) its contacts are the ENEMIES
## within RADAR_RANGE m: bots / pod crews ("war_ai"), the enemy player / remote player ("net_player"),
## drop pods ("war_drop_pod"), and fresh enemy digs (scripts/war/tunnel_log.gd, younger than
## RADAR_DIG_RECENT s, clustered): underground diggers show even when nothing else does. A new
## underground contact on the local player's side warns "Yeraltında düşman kazısı tespit edildi"
## (HUD toast + a blip, at most every RADAR_WARN_GAP s).
## Read it (HUD compass pips, quickbar, skiff radar):
##   Radar.contacts_for(team) -> Array of {"pos": Vector3 (world, at the scan), "kind": "bot" / "player" /
##       "pod" / "dig", "under": bool, "node": Node3D or null (live position: node.global_position)}
##       merged over the side's standing radars (empty without one)
##   Radar.has_radar(team) -> bool       Radar.revision (int, +1 per scan of any radar)
##   signal contacts_changed(team, contacts) on each radar node
## (const Radar := preload("res://scripts/war/radar_tower.gd"))
## Group "war_radar". Multiplayer state: hp only.

const Snd := preload("res://scripts/audio/snd_lib.gd")
const TunnelLog := preload("res://scripts/war/tunnel_log.gd")

const CAB := Vector3(1.0, 0.85, 0.75)
const HEAD_Y := 2.22

signal contacts_changed(team: String, contacts: Array)

static var revision := 0
static var _warn_ms := {}               # team -> Time msec of the last underground warning

var contacts: Array = []
var _scan_t := 0.0
var _head: Node3D
var _beacon_mat: StandardMaterial3D
var _screen: Label3D
var _sweep := 0.0
var _hum: AudioStreamPlayer3D


static func footprint() -> Vector3:
	return Vector3(0.9, 1.35, 0.9)


## Every contact of `team`'s standing radars (see the header), nodes de-duplicated.
static func contacts_for(team: String) -> Array:
	var out: Array = []
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return out
	var seen := {}
	for r in tree.get_nodes_in_group("war_radar"):
		if Game.team_of(r) != team or r.get("is_destroyed") == true or not r.has_method("is_assembled") or not r.is_assembled():
			continue
		for c in r.get("contacts"):
			var n = (c as Dictionary).get("node")
			if n != null and is_instance_valid(n):
				var key: int = (n as Object).get_instance_id()
				if seen.has(key):
					continue
				seen[key] = true
			out.append(c)
	return out


## `team` has a standing (assembled) radar.
static func has_radar(team: String) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return false
	for r in tree.get_nodes_in_group("war_radar"):
		if Game.team_of(r) == team and r.get("is_destroyed") != true and r.has_method("is_assembled") and r.is_assembled():
			return true
	return false


func piece_kind() -> String:
	return "radar_tower"


func piece_name() -> String:
	return "Radar Kulesi"


func piece_group() -> String:
	return "war_radar"


func piece_hp() -> float:
	return Balance.RADAR_HP


func footprint_r() -> float:
	return Balance.RADAR_FOOTPRINT


func _foundation_shape() -> Array:
	return [Foundation.rect(-CAB.x * 0.5, CAB.x * 0.5, -CAB.z * 0.5, CAB.z * 0.5, 0.0, 2, 2), [], Color(0.36, 0.36, 0.37)]


func _build_piece() -> void:
	var home := team == "home"
	_paint = _mat(Color(0.84, 0.85, 0.84) if home else Color(0.22, 0.21, 0.21), 0.15 if home else 0.5, 0.5)
	var stripe := _mat(Color(0.95, 0.42, 0.08) if home else Color(0.72, 0.12, 0.08), 0.0, 0.5)
	var steel := _mat(Color(0.34, 0.35, 0.37), 0.85, 0.38)
	var dark := _mat(Color(0.1, 0.105, 0.11), 0.7, 0.42)
	var radome := _mat(Color(0.78, 0.8, 0.8), 0.0, 0.55)
	# --- Cabinet.
	var cab := _part(0.0)
	_box(cab, Vector3(0, 0.04, 0), Vector3(CAB.x + 0.1, 0.08, CAB.z + 0.1), concrete(true))
	_box(cab, Vector3(0, 0.08 + CAB.y * 0.5, 0), CAB, _paint)
	_box(cab, Vector3(0, CAB.y + 0.1, 0), Vector3(CAB.x + 0.04, 0.04, CAB.z + 0.04), dark)
	_box(cab, Vector3(0, CAB.y - 0.02, 0), Vector3(CAB.x + 0.01, 0.05, CAB.z + 0.01), stripe)
	for sx: float in [1.0, -1.0]:
		for k in 5:
			_box(cab, Vector3(sx * (CAB.x * 0.5 + 0.004), 0.3 + k * 0.08, 0), Vector3(0.008, 0.03, CAB.z * 0.6), dark)
	_box(cab, Vector3(0, 0.55, CAB.z * 0.5 + 0.01), Vector3(0.62, 0.36, 0.02), dark)
	_screen = _label(cab, Vector3(0, 0.55, CAB.z * 0.5 + 0.024), "RADAR", 30, _col_team.lightened(0.4))
	_lamp(cab, Vector3(0.38, 0.8, CAB.z * 0.5 + 0.02), Color(0.3, 1.0, 0.45), 0.025, 2.5)
	_col_box(Vector3(0, 0.08 + CAB.y * 0.5, 0), CAB)
	# --- Lattice mast.
	var mast := _part(0.2)
	var feet: Array = []
	var tops: Array = []
	for k in 3:
		var a := TAU * float(k) / 3.0 + PI * 0.5
		feet.append(Vector3(cos(a) * 0.34, CAB.y + 0.12, sin(a) * 0.3))
		tops.append(Vector3(cos(a) * 0.09, HEAD_Y - 0.12, sin(a) * 0.09))
	for k in 3:
		_seg(mast, feet[k], tops[k], 0.025, steel, 6)
	for y in [0.35, 0.65]:
		for k in 3:
			var a: Vector3 = (feet[k] as Vector3).lerp(tops[k], float(y))
			var b: Vector3 = (feet[(k + 1) % 3] as Vector3).lerp(tops[(k + 1) % 3], float(y))
			_seg(mast, a, b, 0.012, steel, 5)
			var c: Vector3 = (feet[(k + 1) % 3] as Vector3).lerp(tops[(k + 1) % 3], float(y) + 0.3)
			_seg(mast, a, c, 0.01, steel, 5)
	_seg(mast, Vector3(0.15, CAB.y + 0.12, -0.2), Vector3(0.05, HEAD_Y - 0.1, -0.05), 0.018, dark, 6)   # feed cable
	_col_box(Vector3(0, (CAB.y + HEAD_Y) * 0.5, 0), Vector3(0.5, HEAD_Y - CAB.y, 0.5))
	# --- Rotating head: bearing, arm, the phased-array panel, the aviation lamp.
	var hp_ := _part(0.4)
	_cyl(hp_, Vector3(0, HEAD_Y - 0.06, 0), 0.13, 0.15, 0.12, dark, Vector3.ZERO, 14)
	_head = Node3D.new()
	_head.position = Vector3(0, HEAD_Y, 0)
	hp_.add_child(_head)
	_cyl(_head, Vector3(0, 0.05, 0), 0.08, 0.1, 0.1, steel, Vector3.ZERO, 12)
	_box(_head, Vector3(0, 0.14, 0.06), Vector3(0.12, 0.08, 0.2), _paint)
	var panel := Node3D.new()
	panel.position = Vector3(0, 0.28, -0.04)
	panel.rotation = Vector3(-0.26, 0, 0)
	_head.add_child(panel)
	_box(panel, Vector3(0, 0, 0), Vector3(1.15, 0.42, 0.06), radome)
	_box(panel, Vector3(0, 0, 0.045), Vector3(1.19, 0.46, 0.03), dark)
	for k in 4:
		_box(panel, Vector3(-0.43 + k * 0.287, 0, -0.033), Vector3(0.006, 0.38, 0.004), steel)
	_box(panel, Vector3(0, -0.22, 0.0), Vector3(1.0, 0.025, 0.05), stripe)
	_beacon_mat = _lamp(_head, Vector3(0, 0.56, 0.02), Color(1.0, 0.2, 0.12), 0.035, 0.5)
	_seg(_head, Vector3(0, 0.48, 0.02), Vector3(0, 0.53, 0.02), 0.01, steel, 5)
	_hum = AudioStreamPlayer3D.new()
	_hum.stream = Snd.loop("foley/motor_loop")
	_hum.unit_size = 3.0
	_hum.max_distance = 18.0
	_hum.volume_db = -80.0
	_hum.pitch_scale = 1.6
	_hum.position = Vector3(0, CAB.y, 0)
	add_child(_hum)


func _tick(delta: float) -> void:
	_scan_maybe(delta)


func _tick_client(delta: float) -> void:
	_scan_maybe(delta)


func _scan_maybe(delta: float) -> void:
	_scan_t -= delta
	if _scan_t > 0.0:
		return
	_scan_t = Balance.RADAR_SCAN
	_scan()


## Below the original surface by more than RADAR_UNDER_DEPTH m.
func _under(p: Vector3) -> bool:
	if body == null or not is_instance_valid(body) or not body.has_method("surface_height_at"):
		return false
	return float(body.altitude_of(p)) - float(body.surface_height_at(p)) < -Balance.RADAR_UNDER_DEPTH


func _scan() -> void:
	var me := global_position
	var rr := Balance.RADAR_RANGE
	var out: Array = []
	var units: Array = get_tree().get_nodes_in_group("war_ai") + get_tree().get_nodes_in_group("net_player")
	var pl = Game.player
	if pl != null and is_instance_valid(pl):
		units.append(pl)
	for n in units:
		if not (n is Node3D) or not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
			continue
		if Game.team_of(n) == team or (n.has_method("is_dead") and n.is_dead()) or n.is_in_group("training_dummy"):
			continue
		var p := (n as Node3D).global_position
		if p.distance_to(me) > rr:
			continue
		out.append({"pos": p, "kind": "bot" if n.is_in_group("war_ai") else "player", "under": _under(p), "node": n})
	for pod in get_tree().get_nodes_in_group("war_drop_pod"):
		if pod is Node3D and Game.team_of(pod) != team and (pod as Node3D).global_position.distance_to(me) < rr * 1.5:
			out.append({"pos": (pod as Node3D).global_position, "kind": "pod", "under": false, "node": pod})
	# Fresh enemy digs (clustered, at most 8).
	var digs: Array = []
	if body != null and is_instance_valid(body):
		var enemy := "rival" if team == "home" else "home"
		for e in TunnelLog.points(body, enemy):
			if float(e["t"]) > Balance.RADAR_DIG_RECENT:
				continue
			var p: Vector3 = e["p"]
			if p.distance_to(me) > rr or not _under(p):
				continue
			var near := false
			for d in digs:
				if (d as Vector3).distance_to(p) < 4.0:
					near = true
					break
			if not near:
				digs.append(p)
				if digs.size() >= 8:
					break
	for p in digs:
		out.append({"pos": p, "kind": "dig", "under": true, "node": null})
	_warn_new_under(out)
	contacts = out
	revision += 1
	contacts_changed.emit(team, contacts)


## A new underground contact (none of the last scan's within 6 m) on the local player's side: warn.
func _warn_new_under(now: Array) -> void:
	var pl = Game.player
	var local_team := Game.team_of(pl) if pl != null and is_instance_valid(pl) else "home"
	if team != local_team:
		return
	var fresh := false
	for c in now:
		if not bool(c["under"]):
			continue
		var seen := false
		for o in contacts:
			if bool(o["under"]) and (o["pos"] as Vector3).distance_to(c["pos"]) < 6.0:
				seen = true
				break
		if not seen:
			fresh = true
			break
	if not fresh:
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms - int(_warn_ms.get(team, -1000000)) < int(Balance.RADAR_WARN_GAP * 1000.0):
		return
	_warn_ms[team] = now_ms
	if Game.hud:
		Game.hud.show_message("Yeraltında düşman kazısı tespit edildi", 3.0)
	if Game.sfx:
		Game.sfx.play("blip", -6.0, 0.8)


func _animate(delta: float) -> void:
	if has_meta("build_preview"):
		return
	var on := _build_t < 0.0 and not is_destroyed
	if on:
		_sweep += delta * 1.3
		_head.rotation.y = _sweep
	_beacon_mat.emission_energy_multiplier = (4.0 if fmod(_t, 1.4) < 0.18 else 0.3) if on else 0.2
	if on and not _hum.playing:
		_hum.play()
	if _hum.playing:
		_hum.volume_db = lerpf(_hum.volume_db, -22.0 if on else -80.0, 1.0 - exp(-delta * 2.0))
	var n := contacts.size()
	var under := 0
	for c in contacts:
		if bool(c["under"]):
			under += 1
	var txt := "RADAR\nKURULUYOR" if _build_t >= 0.0 else ("RADAR · TEMAS %d\nYERALTI %d" % [n, under])
	if _screen.text != txt:
		_screen.text = txt
