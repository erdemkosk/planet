extends Node3D
## Multiplayer co-op: the skiff's second (right-hand) seat. While the other player flies a skiff,
## F on it sits you here: a seat object implementing player.gd's vehicle API (set_pilot,
## get_exit_transform, get_exit_velocity, hud_*, can_exit), a first-person camera at the passenger's
## eye with free look (mouse), and it carries the player's body along. F gets out once the skiff is
## landed or low and slow. If the skiff is destroyed the passenger is thrown out like the pilot.
## Meta "net_seat_of" = the skiff (net_players.gd sends vehicle id + seat 1).

const Settings := preload("res://scripts/save/settings.gd")
const LOOK_SENS := 0.0022
const EXIT_CLEAR := 3.0
const EXIT_SPEED := 4.0
const EJECT_DAMAGE := 28.0

var skiff: Node3D
var passenger = null
var _cam: Camera3D
var _look := Vector2.ZERO
var _seat := Vector3(0.38, 0.8, -0.3)
var _eye := Vector3(0.38, 1.5, -0.2)


func _ready() -> void:
	name = "NetPassengerSeat"
	set_meta("net_seat_of", skiff)
	var build = load("res://scripts/craft/skiff_build.gd")
	if build != null:
		var sp: Vector3 = build.SEAT_POS
		var ey: Vector3 = build.EYE
		_seat = Vector3(-sp.x, sp.y, sp.z)
		_eye = Vector3(-ey.x, ey.y, ey.z)
	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = Game.CAM_FAR
	_cam.fov = Settings.fov
	add_child(_cam)
	if skiff != null:
		skiff.tree_exiting.connect(_on_skiff_gone)


static func seat_offset() -> Vector3:
	var build = load("res://scripts/craft/skiff_build.gd")
	if build == null:
		return Vector3(0.38, 0.8, -0.3)
	var sp: Vector3 = build.SEAT_POS
	return Vector3(-sp.x, sp.y, sp.z)


func set_pilot(p) -> void:
	passenger = p
	if p != null:
		_look = Vector2.ZERO
		_cam.current = true
		if Game.sfx:
			Game.sfx.play("switch", -10.0)
	else:
		_cam.current = false
		queue_free()


func _physics_process(_delta: float) -> void:
	if skiff == null or not is_instance_valid(skiff):
		return
	if passenger != null and is_instance_valid(passenger):
		(passenger as Node3D).global_transform = skiff.global_transform * Transform3D(Basis(), _seat)


func _process(_delta: float) -> void:
	if skiff == null or not is_instance_valid(skiff):
		return
	var xf: Transform3D = skiff.global_transform.orthonormalized()
	var vis = skiff.get("_visual")
	if vis is Node3D:
		xf = (vis as Node3D).global_transform.orthonormalized()
	global_transform = xf
	_cam.transform = Transform3D(Basis.from_euler(Vector3(_look.y, _look.x, 0.0)), _eye)


func _unhandled_input(event: InputEvent) -> void:
	if passenger == null or Game.ui_panel_open():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var lk := Settings.look((event as InputEventMouseMotion).relative)
		_look.x = clampf(_look.x - lk.x * LOOK_SENS, -2.4, 2.4)
		_look.y = clampf(_look.y - lk.y * LOOK_SENS, -1.1, 1.2)
		get_viewport().set_input_as_handled()


func can_exit() -> bool:
	if skiff == null or not is_instance_valid(skiff):
		return true
	if bool(skiff.get("landed")):
		return true
	var v: Vector3 = skiff.hud_velocity()
	var clear := float(skiff.get("_clear"))
	if clear < EXIT_CLEAR and v.length() < EXIT_SPEED:
		return true
	if Game.hud:
		Game.hud.show_message("Uçarken inilmez — pilot yere yaklaşsın", 1.8)
	return false


func get_exit_transform() -> Transform3D:
	if skiff != null and is_instance_valid(skiff):
		var xf: Transform3D = skiff.get_exit_transform()
		# Out on the passenger's side when the pilot's door spot is the one picked.
		var side: Vector3 = skiff.global_transform.basis.x.normalized()
		return Transform3D(xf.basis, xf.origin + side * 0.6)
	return global_transform


func get_exit_velocity() -> Vector3:
	return skiff.get_exit_velocity() if skiff != null and is_instance_valid(skiff) else Vector3.ZERO


func hud_velocity() -> Vector3:
	return skiff.hud_velocity() if skiff != null and is_instance_valid(skiff) else Vector3.ZERO


func hud_name() -> String:
	return "Mekik · yolcu"


func hud_extra() -> String:
	if skiff == null or not is_instance_valid(skiff):
		return ""
	return "Gövde %d%%" % roundi(float(skiff.get("hp")) / maxf(float(skiff.get("hp_max")), 1.0) * 100.0)


## The skiff is going away (destroyed / scene change) with us aboard: thrown out like the pilot.
func _on_skiff_gone() -> void:
	var p = passenger
	if p == null or not is_instance_valid(p) or p.get("vehicle") != self:
		return
	if not Net.in_game:
		return
	var up: Vector3 = skiff.global_transform.basis.y
	var vel: Vector3 = skiff.hud_velocity()
	p.exit_vehicle()
	if p.has_method("ragdoll"):
		p.ragdoll(up * 6.0 + skiff.global_transform.basis.x * 3.5 + vel * 0.5, 2.5)
	if p.has_method("take_damage"):
		p.take_damage(EJECT_DAMAGE, skiff.global_position)
