extends "res://scripts/war/base_piece.gd"
## Zırhlı Kapı (blast door), İnşa Aracı (Savunma; Balance.DOOR_*): a steel frame (two deep posts, a
## header, a hazard-striped sill) with two heavy leaves that slide sideways into the posts. Fits a
## Sığınak Modülü doorway (BaseKit.snap) or a ~2 m tunnel.
## It opens by itself for its OWN side: a friendly player, co-op partner or bot within
## DOOR_OPEN_RANGE m of its middle; it stays open DOOR_HOLD s after the last one, then shuts. It never
## opens for the enemy, who has to break it (DOOR_HP; blasts × DOOR_BLAST_MULT). The leaves are solid
## (ship-layer colliders that slide with them). Rival bots do not collide with structures: the AI asks
## BaseKit.blocking_door(from, to, team) and stops to shoot it.
## Lamps on the header: green open, amber moving, red shut.
## Multiplayer: the host decides; `charge` = 1 open / 0 shut (the structure state byte), the client
## slides its leaves to it. Group "war_blast_door".

const Dig := preload("res://scripts/player/dig.gd")

const OPEN_W := 1.6                     # clear opening
const OPEN_H := 2.2
const POST_W := 0.35
const DEPTH := 0.5
const LEAF_T := 0.16

var _open := 0.0                        # 0 shut .. 1 open (shown)
var _open_until := -1.0
var _sense_t := 0.0
var _leaves: Array = []                 # [node, collider, side]
var _lamp_mats: Array = []
var _servo: AudioStreamPlayer3D
var _was_moving := false


static func footprint() -> Vector3:
	return Vector3(OPEN_W * 0.5 + POST_W, 1.25, DEPTH * 0.5)


func piece_kind() -> String:
	return "blast_door"


func piece_name() -> String:
	return "Zırhlı Kapı"


func piece_group() -> String:
	return "war_blast_door"


func piece_hp() -> float:
	return Balance.DOOR_HP


func footprint_r() -> float:
	return Balance.DOOR_FOOTPRINT


func blast_mult() -> float:
	return Balance.DOOR_BLAST_MULT


func is_open() -> bool:
	return _open > 0.6


func _foundation_shape() -> Array:
	return [Foundation.rect(-(OPEN_W * 0.5 + POST_W), OPEN_W * 0.5 + POST_W, -DEPTH * 0.5, DEPTH * 0.5, 0.0, 3, 1), [],
			Color(0.36, 0.36, 0.37)]


func _build_piece() -> void:
	var home := team == "home"
	_paint = _mat(Color(0.8, 0.81, 0.8) if home else Color(0.2, 0.19, 0.19), 0.3 if home else 0.6, 0.45)
	var stripe := _mat(Color(0.95, 0.42, 0.08) if home else Color(0.72, 0.12, 0.08), 0.0, 0.5)
	var steel := _mat(Color(0.33, 0.34, 0.36), 0.85, 0.38)
	var dark := _mat(Color(0.1, 0.105, 0.11), 0.7, 0.42)
	var rubber := _mat(Color(0.04, 0.04, 0.045), 0.0, 0.9)
	var bolt := _mat(Color(0.56, 0.57, 0.6), 0.9, 0.3)
	var haz := hazard()
	# --- Frame.
	var frame := _part(0.0)
	var px := OPEN_W * 0.5 + POST_W * 0.5
	for sx: float in [1.0, -1.0]:
		_box(frame, Vector3(sx * px, 1.25, 0), Vector3(POST_W, 2.5, DEPTH), steel)
		_box(frame, Vector3(sx * (OPEN_W * 0.5 + 0.02), 1.1, 0), Vector3(0.04, OPEN_H, DEPTH + 0.02), dark)   # guide rails
		for sz: float in [1.0, -1.0]:
			for k in 4:
				_box(frame, Vector3(sx * px, 0.35 + k * 0.6, sz * (DEPTH * 0.5 + 0.006)), Vector3(0.05, 0.05, 0.012), bolt)
		_col_box(Vector3(sx * px, 1.25, 0), Vector3(POST_W, 2.5, DEPTH))
	_box(frame, Vector3(0, OPEN_H + 0.15, 0), Vector3(OPEN_W + POST_W * 2.0, 0.3, DEPTH), steel)
	_col_box(Vector3(0, OPEN_H + 0.15, 0), Vector3(OPEN_W + POST_W * 2.0, 0.3, DEPTH))
	_box(frame, Vector3(0, 0.02, 0), Vector3(OPEN_W, 0.04, DEPTH), haz)
	for sz: float in [1.0, -1.0]:
		_box(frame, Vector3(0, OPEN_H + 0.16, sz * (DEPTH * 0.5 + 0.01)), Vector3(OPEN_W + 0.4, 0.12, 0.02), _paint)
		_box(frame, Vector3(0, OPEN_H + 0.08, sz * (DEPTH * 0.5 + 0.012)), Vector3(OPEN_W + 0.4, 0.03, 0.02), stripe)
		for k in 3:
			var col: Color = [Color(0.3, 1.0, 0.45), Color(1.0, 0.65, 0.15), Color(1.0, 0.22, 0.15)][k]
			_lamp_mats.append(_lamp(frame, Vector3(-0.2 + k * 0.2, OPEN_H + 0.25, sz * (DEPTH * 0.5 + 0.03)), col, 0.035, 0.3))
	# --- Leaves (slide into the posts).
	var leaves := _part(0.25)
	var lw := OPEN_W * 0.5 + 0.02
	for sx: float in [-1.0, 1.0]:
		var leaf := Node3D.new()
		leaves.add_child(leaf)
		_box(leaf, Vector3(0, OPEN_H * 0.5, 0), Vector3(lw, OPEN_H - 0.02, LEAF_T), _paint)
		for sz: float in [1.0, -1.0]:
			var zf := sz * (LEAF_T * 0.5 + 0.006)
			_box(leaf, Vector3(0, 0.35, zf), Vector3(lw - 0.04, 0.36, 0.012), haz)
			_box(leaf, Vector3(0, 1.4, zf), Vector3(lw - 0.12, 1.1, 0.012), steel)
			_box(leaf, Vector3(0, 2.02, zf), Vector3(lw - 0.04, 0.05, 0.014), stripe)
			for k in 3:
				_box(leaf, Vector3(-0.25 + k * 0.25, 0.92, zf * 1.15), Vector3(0.12, 0.025, 0.01), dark)
		# The seal strip on the meeting edge.
		_box(leaf, Vector3(-sx * (lw * 0.5 - 0.015), OPEN_H * 0.5, 0), Vector3(0.03, OPEN_H - 0.04, LEAF_T + 0.01), rubber)
		var cs := _col_box(Vector3(sx * lw * 0.5, OPEN_H * 0.5, 0), Vector3(lw, OPEN_H - 0.02, LEAF_T))
		_leaves.append([leaf, cs, sx])
	_servo = AudioStreamPlayer3D.new()
	_servo.unit_size = 5.0
	_servo.max_distance = 30.0
	_servo.position = Vector3(0, OPEN_H, 0)
	add_child(_servo)
	_place_leaves()


## Built (host / single player): clears soil left in the opening (a door set into a tunnel).
func _on_assembled() -> void:
	if Net.is_client() or body == null or not is_instance_valid(body):
		return
	for y in [0.75, 1.55]:
		Dig.dig_at(body, global_transform * Vector3(0, float(y), 0), 0.85, Dig.MODE_DIG, 5.0)


func _place_leaves() -> void:
	var lw := OPEN_W * 0.5 + 0.02
	var e := _open * _open * (3.0 - 2.0 * _open)
	for l in _leaves:
		var sx := float(l[2])
		var x := sx * (lw * 0.5 + e * (lw - 0.05))
		(l[0] as Node3D).position = Vector3(x, 0, 0)
		(l[1] as CollisionShape3D).position = Vector3(x, OPEN_H * 0.5, 0)


## Host / single player: open for friends, shut for everyone else.
func _tick(delta: float) -> void:
	_sense_t -= delta
	if _sense_t <= 0.0:
		_sense_t = 0.15
		var mid := global_position + global_transform.basis.y.normalized() * 1.1
		if _friends_near(mid, Balance.DOOR_OPEN_RANGE):
			_open_until = _t + Balance.DOOR_HOLD
	charge = 1.0 if _t < _open_until else 0.0
	_slide(delta)


## Multiplayer client: the host's charge (1 open / 0 shut).
func _tick_client(delta: float) -> void:
	_slide(delta)


func _slide(delta: float) -> void:
	var target := 1.0 if charge > 0.5 else 0.0
	var before := _open
	_open = move_toward(_open, target, delta / maxf(Balance.DOOR_OPEN_TIME, 0.05))
	var moving := absf(_open - before) > 0.0001
	if moving != _was_moving:
		_was_moving = moving
		if moving and Game.sfx:
			Game.sfx.play_at("servo", global_position + global_transform.basis.y * 1.5, -6.0, 0.75 if target > 0.5 else 0.65, 10.0)
		elif not moving and _open < 0.01 and Game.sfx:
			Game.sfx.play_at("impact", global_position + global_transform.basis.y * 1.0, -8.0, 0.7, 10.0)
	if moving:
		_place_leaves()


func _animate(_delta: float) -> void:
	if has_meta("build_preview") or _lamp_mats.size() < 6:
		return
	var on := _build_t < 0.0 and not is_destroyed
	var moving := _open > 0.01 and _open < 0.99
	for side in 2:
		var g: StandardMaterial3D = _lamp_mats[side * 3]
		var a: StandardMaterial3D = _lamp_mats[side * 3 + 1]
		var r: StandardMaterial3D = _lamp_mats[side * 3 + 2]
		g.emission_energy_multiplier = 3.0 if on and _open >= 0.99 else 0.25
		a.emission_energy_multiplier = (3.0 if fmod(_t, 0.4) < 0.2 else 0.4) if on and moving else 0.25
		r.emission_energy_multiplier = 3.0 if on and _open <= 0.01 else 0.25
