extends Node
## Hızlı siper (2026-10-06): X on foot with any item but the build tool (it uses X itself) slams the
## left fist into the ground and in ~1 s a crescent berm (~1.1 m high, ~2.5 m wide) rises
## Balance.ENTRENCH_DIST ahead along the aim, with a shallow scrape where you stand. Costs
## Balance.ENTRENCH_COST m³ of material (paid at the press, given back if the slam is cut short before
## it lands), Balance.ENTRENCH_COOLDOWN s between two. The brushes are queued by
## scripts/war/cave_in.gd entrench() on this machine (a client predicts its own; they sync like the
## drill's) and that emits CaveIn.events().entrenched(feet, dir) for the multiplayer layer.
## Child of the player (player.gd _ready). The slam drives the view model's left arm through the
## player's hand_action (scripts/player/hand_action.gd) channel: its state is "entrench" while it runs
## (so the held item can't fire and no grenade / scan starts), and this node writes left_w /
## left_target / left_elbow / right_lower every frame after hand_action's own _process. A cancel()
## there (ragdoll, vehicle, death) ends the slam.

const CaveIn := preload("res://scripts/war/cave_in.gd")
const Balance := preload("res://scripts/war/balance.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # the "why not" toast: key "deny" (1)

# Left wrist targets (camera space) and forearm directions (toward the elbow), like hand_action.gd's.
const LOW := Vector3(-0.28, -0.6, -0.28)
const LOW_ELBOW := Vector3(-0.35, -0.8, 0.45)
const UP := Vector3(-0.2, -0.1, -0.42)
const UP_ELBOW := Vector3(-0.45, -0.55, 0.7)
const SLAM := Vector3(-0.1, -0.64, -0.6)
const SLAM_ELBOW := Vector3(-0.4, 0.2, 0.9)
const HOLD := Vector3(-0.13, -0.52, -0.56)
const T_RAISE := 0.16
const T_SLAM := 0.12
const T_HOLD := 0.42
const T_RECOVER := 0.3

var player
var _cd := 0.0
var _phase := ""
var _t := 0.0
var _paid := 0.0
var _from_target := LOW
var _from_elbow := LOW_ELBOW
var _from_w := 0.0
var _from_lower := 0.0


func _ready() -> void:
	name = "Entrench"
	if player == null:
		player = get_parent()


func _unhandled_input(event: InputEvent) -> void:
	if not InputMap.has_action("entrench") or not event.is_action_pressed("entrench") or event.is_echo():
		return
	if player == null or not is_instance_valid(player) or player.vehicle != null:
		return
	if start():
		get_viewport().set_input_as_handled()


## Seconds until the next one (0 = ready).
func cooldown_left() -> float:
	return _cd


func busy() -> bool:
	return _phase != ""


## X pressed: the slam starts (false: refused, with a message).
func start() -> bool:
	var p = player
	if _phase != "" or p.is_dead() or p.is_ragdolled() or Game.ui_panel_open() or Game.overlays_hidden():
		return false
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return false
	var it = p.current()
	if it != null and str(it.get("item_id")) == "build":
		return false
	if CaveIn.is_buried(p):
		return false
	var ha = p.hand_action
	if ha == null or ha.busy() or (p.mantle != null and p.mantle.busy()):
		return false
	if _cd > 0.0:
		_deny("Siper hazır değil (%d sn)" % int(ceilf(_cd)))
		return false
	if not p.is_on_floor():
		_deny("Siper için yerde ol")
		return false
	if Game.material + 0.0001 < Balance.ENTRENCH_COST:
		_deny("Siper için %d m³ malzeme gerek" % int(Balance.ENTRENCH_COST))
		return false
	Game.add_material(-Balance.ENTRENCH_COST)
	_paid = Balance.ENTRENCH_COST
	_cd = Balance.ENTRENCH_COOLDOWN
	ha.state = "entrench"
	ha.phase = "raise"
	_next("raise")
	if Game.sfx:
		Game.sfx.play("cloth", -12.0, 1.1)
	return true


func _process(delta: float) -> void:
	_cd = maxf(_cd - delta, 0.0)
	if _phase == "":
		return
	var p = player
	var ha = p.hand_action if p != null and is_instance_valid(p) else null
	if ha == null or str(ha.state) != "entrench" or p.is_dead() or p.is_ragdolled() or p.vehicle != null:
		_abort()
		return
	_t += delta
	match _phase:
		"raise":
			var k := _ease(_t / T_RAISE)
			_pose(ha, _from_target.lerp(UP, k), _from_elbow.lerp(UP_ELBOW, k), lerpf(_from_w, 1.0, k), lerpf(_from_lower, 0.55, k))
			if _t >= T_RAISE:
				_next("slam")
		"slam":
			var k := clampf(_t / T_SLAM, 0.0, 1.0)
			k = k * k                                    # accelerating into the ground
			_pose(ha, _from_target.lerp(SLAM, k), _from_elbow.lerp(SLAM_ELBOW, k), 1.0, lerpf(_from_lower, 0.7, k))
			if _t >= T_SLAM:
				_impact()
				_next("hold")
		"hold":
			var j := sin(_t * 47.0) * 0.006 * (1.0 - _t / T_HOLD)
			var k := _ease(_t / T_HOLD)
			_pose(ha, SLAM.lerp(HOLD, k) + Vector3(j, j * 0.5, 0.0), SLAM_ELBOW.lerp(UP_ELBOW, k * 0.4), 1.0, 0.7)
			if _t >= T_HOLD:
				_next("recover")
		"recover":
			var k := _ease(_t / T_RECOVER)
			_pose(ha, _from_target.lerp(LOW, k), _from_elbow.lerp(LOW_ELBOW, k), lerpf(_from_w, 0.0, k), lerpf(_from_lower, 0.0, k))
			ha.phase = "recover"                         # (hand_action.busy(): the tail is free)
			if _t >= T_RECOVER:
				_phase = ""
				ha.state = ""
				ha.phase = ""


## The fist hits the ground: the berm and the scrape are queued, the view nods, a thump.
func _impact() -> void:
	var p = player
	var body: Node3D = Game.dominant_body(p.global_position)
	var up: Vector3 = p.global_transform.basis.y
	var fwd: Vector3 = -(p.camera as Camera3D).global_transform.basis.z
	var team := Game.team_of(p)
	if not CaveIn.entrench(body, p.global_position, fwd, up, team if team != "" else "home", p):
		Game.add_material(_paid)
		_deny("Burada siper kazılamaz")
	_paid = 0.0
	var pv = p.get("_punch")
	if pv is Vector3:
		p.set("_punch", pv + Vector3(-0.045, 0.0, 0.012))
	if p.has_method("add_trauma"):
		p.add_trauma(0.14)
	if Game.sfx:
		Game.sfx.play("melee_dirt", -4.0, 0.85)


func _abort() -> void:
	if _paid > 0.0:
		Game.add_material(_paid)                     # (cut short before the fist landed: no berm, no cost)
		_paid = 0.0
		_cd = 0.0
	_phase = ""


func _next(ph: String) -> void:
	var ha = player.hand_action
	_phase = ph
	_t = 0.0
	_from_target = ha.left_target
	_from_elbow = ha.left_elbow
	_from_w = float(ha.left_w)
	_from_lower = float(ha.right_lower)


func _pose(ha, target: Vector3, elbow: Vector3, w: float, lower: float) -> void:
	ha.left_target = target
	ha.left_elbow = elbow
	ha.left_w = w
	ha.right_lower = lower


func _deny(msg: String) -> void:
	if Game.sfx:
		Game.sfx.play("error", -10.0)
	if Game.hud:
		HudLevel.alert(msg, 1, "deny", 1.6)


static func _ease(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)
