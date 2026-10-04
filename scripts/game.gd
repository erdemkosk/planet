extends Node
## Global state (autoload "Game"): constants, input map, references, the material counter, ammo,
## gravity and damage helpers.
##
## Material (generic soil, m³): the only resource. Digging adds it, raising / flattening ground and
## buying ammo spend it (cannons and the shuttle will too).
##   Game.material                 current amount
##   Game.add_material(d) -> float add (or with d < 0 remove); returns what actually changed
##   Game.spend_material(c) -> bool  all-or-nothing payment
##   signal material_changed(amount)
## Ammo: each kind has a reserve; a reload takes rounds from it and buys the shortfall from material
## at AMMO_COST m³ per round (take_ammo).
## Gravity: every planet pulls (planet.gd gravity_accel: linear inside, inverse square outside, no
## fade); gravity_at() sums them. "Up" on the ground comes from dominant_body().
## Damage: anything in group "damageable" implements take_damage(amount, from_pos, impulse) ->
## {"dmg": float, "killed": bool} and has hp / hp_max; deal_damage() / damage_target() route hits.

const Settings := preload("res://scripts/save/settings.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const Balance := preload("res://scripts/war/balance.gd")     # START_MATERIAL (one cannon)

## Far clip of every gameplay camera: both planets (350 m apart, bodies.gd) and far beyond.
const CAM_FAR := 10000.0

const LAYER_TERRAIN := 1
const LAYER_SHIP := 2
const LAYER_VEHICLE := 4
const LAYER_PLAYER := 8          # characters (player, AI rival bot): what bullets and blasts hit
const LAYER_INTERACT := 16

## Group of everything that takes damage (player, AI rival bot, later the cores / cannons).
const DAMAGEABLE := "damageable"

# Untyped on purpose: scripted nodes we call custom methods on.
var planet                       # the player's home planet (planet.gd)
var rival                        # the AI rival's planet
var player
var hud
var controlled                   # what the player controls right now (the player, later the shuttle)
var sfx
var pause_menu
## Sun direction (unit, toward the sun). Fixed: main.gd sets it side-on to the planets' axis.
var sun_dir := Vector3(0.0, 0.35, 1.0).normalized()

# --- Material ---------------------------------------------------------------------------------
signal material_changed(amount: float)
## War (scripts/war/core.gd): a planet's core lost hp (`body` = that planet), or was destroyed.
signal core_damaged(body: Node3D, hp: float)
signal core_destroyed(body: Node3D)
var material := 0.0
var _material_shown := -1


## Adds (or with a negative d removes) material, never below 0. Returns the change applied.
func add_material(d: float) -> float:
	var before := material
	material = maxf(material + d, 0.0)
	var shown := int(floorf(material + 0.0001))
	if shown != _material_shown:
		_material_shown = shown
		material_changed.emit(material)
	return material - before


## Pays `cost` if there is enough (true), otherwise nothing changes (false).
func spend_material(cost: float) -> bool:
	if cost <= 0.0:
		return true
	if material + 0.0001 < cost:
		return false
	add_material(-cost)
	return true


# --- Ammo -------------------------------------------------------------------------------------
signal ammo_changed
## m³ of material per round when the reserve runs short (bought automatically on reload).
const AMMO_COST := {"ammo_std": 0.1, "ammo_ap": 0.3, "ammo_shell": 0.25}
## Reserve at the start of a game.
const AMMO_START := {"ammo_std": 90, "ammo_ap": 20, "ammo_shell": 24}
var ammo := {}


func ammo_reserve(id: String) -> int:
	return int(ammo.get(id, 0))


## Rounds a reload could get: the reserve plus what the material can buy.
func ammo_available(id: String) -> int:
	var cost: float = float(AMMO_COST.get(id, 0.0))
	var buy := int(floorf(material / cost + 0.0001)) if cost > 0.0 else 0
	return ammo_reserve(id) + buy


## Takes up to n rounds: from the reserve first, the rest bought from material. Returns the rounds
## actually granted.
func take_ammo(id: String, n: int) -> int:
	if n <= 0:
		return 0
	var from_res := mini(ammo_reserve(id), n)
	ammo[id] = ammo_reserve(id) - from_res
	var got := from_res
	var cost: float = float(AMMO_COST.get(id, 0.0))
	if got < n and cost > 0.0:
		var buy := mini(n - got, int(floorf(material / cost + 0.0001)))
		if buy > 0:
			add_material(-cost * buy)
			got += buy
	ammo_changed.emit()
	return got


# --- Setup / input ----------------------------------------------------------------------------

func _ready() -> void:
	_setup_input()
	Settings.load_and_apply()      # mouse, FOV, volume, window (Esc › Ayarlar)
	reset_state()


## A fresh match: material for exactly one cannon (Balance.START_MATERIAL), the starting ammo
## reserve. Not called on respawn (material is kept).
func reset_state() -> void:
	material = Balance.START_MATERIAL
	_material_shown = -1
	ammo = (AMMO_START as Dictionary).duplicate()
	add_material(0.0)
	ammo_changed.emit()


func _setup_input() -> void:
	_bind_keys("move_forward", [KEY_W])
	_bind_keys("move_back", [KEY_S])
	_bind_keys("move_left", [KEY_A])
	_bind_keys("move_right", [KEY_D])
	_bind_keys("jump", [KEY_SPACE])
	_bind_keys("descend", [KEY_CTRL, KEY_C])
	_bind_keys("sprint", [KEY_SHIFT])
	_bind_keys("interact", [KEY_F])
	_bind_keys("flashlight", [KEY_L])
	# Hand items: 1 drill, 2 rifle, 3 shotgun.
	_bind_keys("slot_1", [KEY_1])
	_bind_keys("slot_2", [KEY_2])
	_bind_keys("slot_3", [KEY_3])
	_bind_keys("slot_4", [KEY_4])        # build tool (scripts/war/build_tool.gd)
	# R: drill mode (drill) / reload (guns). Middle mouse: drill mode / gun fire mode.
	_bind_keys("tool_mode", [KEY_R])
	_bind_mouse("tool_mode", MOUSE_BUTTON_MIDDLE)
	_bind_mouse("tool_use", MOUSE_BUTTON_LEFT)
	_bind_mouse("tool_alt", MOUSE_BUTTON_RIGHT)
	_bind_mouse("brush_up", MOUSE_BUTTON_WHEEL_UP)
	_bind_mouse("brush_down", MOUSE_BUTTON_WHEEL_DOWN)


func _bind_keys(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _bind_mouse(action: String, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# Esc: pause menu (it frees the mouse and closes itself on the next Esc).
		if pause_menu != null and is_instance_valid(pause_menu) and not pause_menu.is_open():
			pause_menu.open()
			get_viewport().set_input_as_handled()
		elif pause_menu == null:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and not (event as InputEventMouseButton).button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
				MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT] and not ui_panel_open():
		# A click into the game takes the mouse back, but never while a menu is open.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F11:
		# F11: fullscreen <-> window (remembered, Esc › Ayarlar)
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		Settings.set_fullscreen(not full)
		Settings.save()


## A menu that needs the mouse is open (the pause menu).
func ui_panel_open() -> bool:
	return pause_menu != null and is_instance_valid(pause_menu) and pause_menu.is_open()


# --- Gravity / bodies -------------------------------------------------------------------------

## Gravity at a world position: the sum of every planet's pull (m/s², pointing down).
func gravity_at(pos: Vector3) -> Vector3:
	var g := Vector3.ZERO
	for b in Bodies.all():
		if not is_instance_valid(b):
			continue
		var d: Vector3 = pos - (b as Node3D).global_position
		var dist := d.length()
		if dist < 0.001:
			continue
		g -= d / dist * float(b.gravity_accel(dist))
	return g


## The planet that pulls hardest at pos ("up" for walking, the world you are on).
func dominant_body(pos: Vector3) -> Node3D:
	var b := Bodies.dominant(pos)
	return b if b != null else planet


## Alias of dominant_body (older callers).
func body_at(pos: Vector3) -> Node3D:
	return dominant_body(pos)


## The home planet's centre.
func planet_center() -> Vector3:
	if planet != null and is_instance_valid(planet):
		return (planet as Node3D).global_position
	return Vector3.ZERO


## Height above the base radius of the dominant planet.
func altitude(pos: Vector3) -> float:
	var b := dominant_body(pos)
	if b == null:
		return 0.0
	return pos.distance_to(b.global_position) - float(b.radius)


## 1 at the surface, 0 at the top of the (thin) air and in the vacuum between the planets.
func atmosphere_factor(pos: Vector3) -> float:
	var b := dominant_body(pos)
	if b == null or not b.has_atmosphere or float(b.atmo_height) <= 0.0:
		return 0.0
	return clampf(1.0 - altitude(pos) / float(b.atmo_height), 0.0, 1.0)


# --- Damage -----------------------------------------------------------------------------------

## The damageable node a collider belongs to (itself or an ancestor in group "damageable"), or null.
func damageable_of(obj: Object) -> Node:
	var n := obj as Node
	while n != null:
		if n.is_in_group(DAMAGEABLE) and n.has_method("take_damage"):
			return n
		n = n.get_parent()
	return null


## Applies damage to a damageable node. Returns its result ({} when it is not damageable).
## src_team ("home" / "rival", "" = unknown): own-team structures (group "war_structure") take only
## Balance.FRIENDLY_FIRE of it.
func damage_target(target: Node, amount: float, from_pos: Vector3, impulse := Vector3.ZERO, src_team := "") -> Dictionary:
	if target == null or not is_instance_valid(target) or not target.has_method("take_damage"):
		return {}
	if src_team != "" and target.is_in_group("war_structure") and team_of(target) == src_team:
		amount *= Balance.FRIENDLY_FIRE
	var r = target.take_damage(amount, from_pos, impulse)
	return r if r is Dictionary else {}


## Area damage (explosions): every damageable within `radius` of `center` takes `amount` falling
## off linearly to 0 at the edge, plus an impulse (m/s at the centre) away from the blast.
func area_damage(center: Vector3, radius: float, amount: float, impulse := 0.0, exclude: Node = null, src_team := "") -> void:
	for n in get_tree().get_nodes_in_group(DAMAGEABLE):
		if n == exclude or not (n is Node3D) or not n.has_method("take_damage"):
			continue
		var p: Vector3 = (n as Node3D).global_position + (n as Node3D).global_transform.basis.y * 0.9
		var d := p.distance_to(center)
		if d > radius:
			continue
		var k := 1.0 - d / radius
		var dir := (p - center).normalized() if d > 0.01 else (n as Node3D).global_transform.basis.y
		damage_target(n, amount * k, center, dir * impulse * k, src_team)


## "home" or "rival": a node's `team` property, else its "team" meta, else "home" (the player's).
func team_of(n: Object) -> String:
	if n == null:
		return ""
	var t = n.get("team")
	if t is String and t != "":
		return t
	if n.has_meta("team"):
		return str(n.get_meta("team"))
	return "home"


# --- Combat events (the rival bots react to them, scripts/war/ai_rival.gd) ----------------------
## A gun fired a bullet / pellet from `from` along `dir` (unit): bots it passes close to take cover.
signal shot_fired(from: Vector3, dir: Vector3, team: String)
## Something exploded at `pos` (blast radius `radius`).
signal blast(pos: Vector3, radius: float, team: String)
