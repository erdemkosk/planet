extends Node3D
## Base class for hand-held items (keys 1-3: drill, rifle, shotgun). An item lives under the player camera (for
## aiming) and builds its own first-person model, which the view model parents to the right hand.

const VM := preload("res://scripts/player/vm_parts.gd")

var player
var item_id := ""
var item_name := ""
var item_desc := ""
var icon := ""                 # icon / prop id (the astronaut body holds a prop by this id)
var active := true             # false while piloting a vehicle
var equipped := false          # true while this is the selected (and raised) hotbar item
var using := false             # true while the item is working this frame (drives arm shake)
var kick := 0.0                # one-shot recoil impulse, consumed by the view model
var model: Node3D              # first-person model (hand frame: grip at origin, -Z forward)
var left_grip: Node3D = null   # optional second handle for the left hand (child of model)
var hold_offset := Vector3.ZERO  # per-item shift of the right hand rest position (camera space)


func set_active(a: bool) -> void:
	active = a
	if not a:
		using = false
	_on_state_changed()


func set_equipped(e: bool) -> void:
	equipped = e
	if not e:
		using = false
	_on_state_changed()


## True when the player may operate this item right now.
func can_operate() -> bool:
	if not active or not equipped:
		return false
	# Crosshair on a ship control (Button3D with meta "click_use"): the click presses it instead.
	if player != null and player.get("interact_target") != null and is_instance_valid(player.interact_target) \
			and player.interact_target.has_meta("click_use"):
		return false
	if Game.hud and Game.hud.has_method("blocks_input") and Game.hud.blocks_input():
		return false
	# Optional hand actions (player.hands_busy()) occupy the hands.
	if player != null and player.has_method("hands_busy") and player.hands_busy():
		return false
	return true


func _on_state_changed() -> void:
	pass


## Builds and returns the first-person model. Override.
func build_model() -> Node3D:
	model = Node3D.new()
	return model


## Accent color for crosshair / hotbar highlight.
func accent_color() -> Color:
	return Color(0.4, 0.86, 1.0)


## Short status for the hotbar slot (e.g. mode or count).
func status_text() -> String:
	return ""


## One-line context hint shown above the hotbar while equipped (BBCode allowed).
func hud_hint() -> String:
	return ""
