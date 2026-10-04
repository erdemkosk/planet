extends CharacterBody3D
## The player: first-person astronaut on a small voxel planet. Walks on whatever gravity applies
## (Game.gravity_at: both planets, "up" from the strongest pull), hops with a weak short jetpack,
## holds four hand items (1 drill, 2 rifle, 3 shotgun, 4 build tool), has a helmet headlamp (L), takes damage
## (group "damageable"), ragdolls on hard hits / death and respawns on the home planet.
## The full-body astronaut model (scripts/player/astronaut.gd) is shadow-only in first person and
## drives the ragdoll (scripts/player/ragdoll.gd).
##
## Damage API (shared with the AI rival bot later, see Game.damage_target / area_damage):
##   take_damage(amount, from_pos = ZERO, impulse = ZERO) -> {"dmg": float, "killed": bool}
##   hp, hp_max, is_dead()
## Seat API for a vehicle (phase 3 shuttle): the vehicle's interact(player) calls enter_vehicle(v);
## the vehicle implements set_pilot(p | null), get_exit_transform(), get_exit_velocity(),
## hud_velocity(), hud_name(), hud_extra(); F leaves it (exit_vehicle). Optional: can_exit() -> bool
## (refuse F, e.g. the shuttle in flight), shield_pilot(amount, from_pos) -> float (damage that
## still reaches the pilot inside).

const Settings := preload("res://scripts/save/settings.gd")
const TerrainTool := preload("res://scripts/player/terrain_tool.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const Shotgun := preload("res://scripts/items/shotgun.gd")
const BuildTool := preload("res://scripts/war/build_tool.gd")     # key 4
const Viewmodel := preload("res://scripts/player/viewmodel.gd")
const Astronaut := preload("res://scripts/player/astronaut.gd")
const Ragdoll := preload("res://scripts/player/ragdoll.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const VMParts := preload("res://scripts/player/vm_parts.gd")
const TWO_HAND := ["terrain", "rifle", "shotgun", "build"]

const HP_MAX := 100.0
const REGEN_DELAY := 6.0
const REGEN_RATE := 7.0                   # hp per second
const RESPAWN_DELAY := 4.0                # s on the ground (ragdoll) after dying
const RAGDOLL_IMPACT := 14.0              # m/s of velocity lost in one step (hard landing / crash)
const RAGDOLL_PUSH := 7.5                 # m/s of external velocity change (blast, hit impulse)
const GETUP_TIME := 1.4
const FALL_DMG_SPEED := 10.0             # m/s of impact before landings hurt

const WALK := 3.6                          # m/s, brisk walk in a suit
const SPRINT := 6.2                        # m/s, reached after a ~0.4 s ramp
const JUMP := 2.9                          # m/s take-off
# Jetpack: a weak, short hop out of a pit / over a crater rim, never off the planet.
const JET_ACCEL := 10.5                   # m/s² (just above the 7.85 m/s² surface gravity)
const JET_FUEL := 2.5                     # s of burn
const JET_MAX_CLIMB := 4.0                # m/s
const JET_FULL_H := 8.0                   # full thrust below this height above the ground
const JET_ZERO_H := 20.0                  # no thrust above this
const JET_REFILL_DELAY := 0.8             # s on the ground before it refills...
const JET_REFILL_TIME := 7.0              # ...then this long from empty to full
const MOUSE_SENS := 0.0022
const INTERACT_RANGE := 4.5
const BODY_LAYER := 2                     # visual layer of the astronaut body (lamp ignores it for shadows)
const LAMP_ENERGY := 11.0

var head: Node3D
var camera: Camera3D
var flashlight: SpotLight3D               # the helmet headlamp
var tool                                  # the drill (sfx.gd and the arms read it)
var items: Array = []                     # hand items by key: 1 drill, 2 rifle, 3 shotgun, 4 build tool
var current_item := 0
var viewmodel                             # first-person arms
var astronaut                             # full-body model (shadow-only in first person; ragdoll source)
var vehicle = null
var jet_fuel := JET_FUEL
var jetting := false
var zero_g := false
var gravity_vec := Vector3.ZERO
var interact_target = null
var move_speed_mult := 1.0                # set by items (e.g. rifle aiming); 1 = normal
var look_scale := 1.0                     # mouse-look sensitivity multiplier (aiming)
var hp := HP_MAX
var hp_max := HP_MAX
var waiting_ground := false               # spawned: hold still until the ground under us is built

var _pitch := 0.0
var _jump_hold := 0.0
var _col: CollisionShape3D
var _was_on_floor := true
var _last_fall := 0.0
var _shake := 0.0
var _shake_t := 0.0
var _held_icon := ""
var _lamp_on := false
var _pending_equip := -1
var _sprint_k := 0.0
var _sprint_hold := 0.0
var _bob_amt := 0.0
var _step_half := -1
var _coyote := 0.0
var _jump_buf := 0.0
var _land_off := 0.0
var _land_vel := 0.0
var _phys_prev := Vector3.ZERO            # body position at the previous / last physics step (view smoothing)
var _phys_cur := Vector3.ZERO
var _prev_fwd := Vector3.ZERO
var _jet_power := 0.0
var _jet_beep := 0.0
var _jet_h := 0.0
var _jet_h_t := 0.0
var _jet_ground := Vector3.ZERO
var _jet_ground_hit := false
var _jet_idle := 0.0                      # s on the ground since the jet last burned
var _jet_fx_light: OmniLight3D
var _jet_dust: GPUParticles3D
var _ragdoll = null
var _rag_cooldown := 0.0
var _last_vel := Vector3.ZERO
var _lamp_local := Transform3D()
var _getup_t := -1.0
var _getup_l0 := {}
var _getup_poses := {}
var _since_hit := 99.0
var _dead := false
var _punch := Vector3.ZERO
var _trauma := 0.0
var _trauma_t := 0.0
var _spawn_body: Node3D


func _ready() -> void:
	add_to_group(Game.DAMAGEABLE)
	collision_layer = Game.LAYER_PLAYER
	collision_mask = Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE
	platform_floor_layers = 0
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.4
	floor_stop_on_slope = true

	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	_col = CollisionShape3D.new()
	_col.shape = shape
	_col.position = Vector3(0, 0.9, 0)
	add_child(_col)

	head = Node3D.new()
	head.position = Vector3(0, 1.6, 0)
	add_child(head)
	camera = Camera3D.new()
	camera.near = 0.05
	camera.far = Game.CAM_FAR
	camera.fov = Settings.fov
	head.add_child(camera)

	astronaut = Astronaut.new()
	add_child(astronaut)
	_set_layers(astronaut, BODY_LAYER)
	astronaut.set_first_person(true)

	_build_lamp()
	_build_jet_fx()

	tool = TerrainTool.new()
	items = [tool, Rifle.new(), Shotgun.new(), BuildTool.new()]
	for it in items:
		it.player = self
		camera.add_child(it)
	viewmodel = Viewmodel.new()
	camera.add_child(viewmodel)
	viewmodel.setup(self, items)
	for it in items:
		it.set_equipped(false)
	viewmodel.swap_to(items[0], _on_item_raised.bind(0))
	camera.current = true


func _set_layers(n: Node, layer_bits: int) -> void:
	for c in n.get_children():
		if c is VisualInstance3D:
			c.layers = layer_bits
		_set_layers(c, layer_bits)


## Puts the player on `body` (the home planet): on the side facing the other planet, turned to the
## sun (main.gd spawn_transform), held still until the ground there is built, then dropped onto it.
func spawn(body: Node3D) -> void:
	_spawn_body = body
	var other: Node3D = Game.rival if body == Game.planet else Game.planet
	var main = get_parent()          # main.gd (the player is its child)
	var xf := global_transform
	if main != null and main.has_method("spawn_transform"):
		xf = main.spawn_transform(body, other, 1.5)
	global_transform = xf
	velocity = Vector3.ZERO
	_last_vel = Vector3.ZERO
	# Look up a little so the other planet (~30° above the horizon) is framed in the sky.
	_pitch = 0.0
	if other != null and is_instance_valid(other):
		var to_other: Vector3 = (other.global_position - xf.origin).normalized()
		_pitch = clampf(asin(clampf(to_other.dot(xf.basis.y), -1.0, 1.0)) - 0.2, 0.0, 0.5)
	head.rotation.x = _pitch
	_phys_prev = global_position
	_phys_cur = global_position
	waiting_ground = true


## Helmet headlamp: warm spot with a projector "cookie" (hot center, soft ring, falloff),
## shadows from the world (not from the own body).
func _build_lamp() -> void:
	flashlight = SpotLight3D.new()
	flashlight.light_color = Color(1.0, 0.92, 0.8)
	flashlight.light_energy = LAMP_ENERGY
	flashlight.spot_range = 35.0
	flashlight.spot_angle = 25.0
	flashlight.spot_attenuation = 0.85
	flashlight.spot_angle_attenuation = 0.9
	flashlight.shadow_enabled = true
	flashlight.shadow_blur = 1.5
	flashlight.light_specular = 0.6
	if "shadow_caster_mask" in flashlight:
		flashlight.set("shadow_caster_mask", 0xFFFFF & ~BODY_LAYER)
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.18, 0.45, 0.6, 0.66, 0.85, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1), Color(0.92, 0.92, 0.92), Color(0.5, 0.5, 0.5),
			Color(0.3, 0.3, 0.3), Color(0.4, 0.4, 0.4), Color(0.08, 0.08, 0.08), Color(0, 0, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 128
	tex.height = 128
	flashlight.light_projector = tex
	flashlight.position = Vector3(0.17, 0.12, -0.16)
	flashlight.visible = false
	head.add_child(flashlight)


func toggle_lamp() -> void:
	_lamp_on = not _lamp_on
	flashlight.visible = _lamp_on
	if Game.sfx:
		Game.sfx.play("switch" if _lamp_on else "toggle", -8.0, 1.0)


func lamp_on() -> bool:
	return _lamp_on


## Where aiming / interaction rays start: the eye.
func aim_origin() -> Vector3:
	return camera.global_position


## Selects a hand item: lowers the current one, swaps the model and raises the new one.
func select_item(i: int) -> void:
	if i < 0 or i >= items.size() or i == current_item:
		return
	for it in items:
		it.set_equipped(false)
	current_item = i
	_pending_equip = i
	viewmodel.swap_to(items[i], Callable())
	if Game.sfx:
		Game.sfx.play("select", -12.0, 0.9 + i * 0.08)


func current() -> Object:
	return items[current_item]


func _process(delta: float) -> void:
	_rag_cooldown = maxf(_rag_cooldown - delta, 0.0)
	_update_health(delta)
	if vehicle != null or _ragdoll != null:
		# Shake that builds up while tumbling must not all fire on getting up.
		_punch = _punch.lerp(Vector3.ZERO, 1.0 - exp(-9.0 * delta))
		_trauma = maxf(_trauma - delta * 1.4, 0.0)
	if vehicle != null:
		return
	if _ragdoll != null:
		if _getup_t >= 0.0:
			_animate_getup(delta)
		else:
			_follow_ragdoll()
		return
	# The new item only becomes usable once the arms have fully raised it.
	if _pending_equip >= 0 and viewmodel.is_raised():
		if _pending_equip == current_item:
			items[current_item].set_equipped(true)
		_pending_equip = -1
	_update_head_bob(delta)
	_update_jet_fx(delta)
	# Camera micro-shake while the drill is working + hit punches + explosion trauma.
	_shake_t += delta
	_shake = move_toward(_shake, 1.0 if tool.using else 0.0, delta * 8.0)
	var crot := Vector3.ZERO
	if _shake > 0.0:
		var a := 0.0022 * _shake
		crot = Vector3(sin(_shake_t * 57.0) * a + sin(_shake_t * 23.0) * a * 0.6,
				sin(_shake_t * 49.0 + 1.3) * a, sin(_shake_t * 31.0) * a * 0.5)
	_punch = _punch.lerp(Vector3.ZERO, 1.0 - exp(-9.0 * delta))
	crot += _punch
	if _trauma > 0.0:
		var rd := delta / maxf(Engine.time_scale, 0.05)
		_trauma = maxf(_trauma - rd * 1.4, 0.0)
		_trauma_t += rd
		var tk := _trauma * _trauma * 0.045
		crot += Vector3(sin(_trauma_t * 27.0) + sin(_trauma_t * 11.0) * 0.6, sin(_trauma_t * 23.0 + 1.7) + sin(_trauma_t * 9.0) * 0.6,
				sin(_trauma_t * 19.0 + 0.6) * 0.6) * tk
	if crot.length_squared() > 1e-10:
		camera.rotation = crot
	elif camera.rotation != Vector3.ZERO:
		camera.rotation = Vector3.ZERO
	_animate_body(delta)


func _animate_body(delta: float) -> void:
	var it = items[current_item]
	var icon: String = it.icon if it.equipped or viewmodel.is_raised() else ""
	if icon != _held_icon:
		_held_icon = icon
		astronaut.set_held(icon)
	astronaut.set_tool_color(tool.MODE_COLORS[tool.work_mode])
	var b := global_transform.basis
	var up := b.y
	var hv := velocity - up * velocity.dot(up)
	var fwd := -b.z
	var yaw_rate := 0.0
	if _prev_fwd != Vector3.ZERO:
		yaw_rate = _prev_fwd.cross(fwd).dot(up) / maxf(delta, 1e-4)
	_prev_fwd = fwd
	astronaut.animate(delta, {
		"vel_local": b.inverse() * hv, "vel_up": velocity.dot(up), "yaw_rate": yaw_rate, "exclude": [get_rid()],
		"jet_power": clampf(_jet_power * 1.3, 0.25, 1.0), "speed": hv.length(), "grounded": is_on_floor(),
		"jetting": jetting, "zero_g": false, "pitch": _pitch, "holding": icon != "",
		"two_hand": icon in TWO_HAND, "using": it.using,
	})
	astronaut.set_lamp(_lamp_on, 1.0 if _lamp_on else 0.0)


func _on_item_raised(i: int) -> void:
	if i == current_item:
		items[i].set_equipped(true)


func _unhandled_input(event: InputEvent) -> void:
	if vehicle == null and _ragdoll == null and not _dead:
		for i in items.size():
			if event.is_action_pressed("slot_%d" % (i + 1)):
				select_item(i)
				get_viewport().set_input_as_handled()
				return
	if event.is_action_pressed("interact"):
		if Game.ui_panel_open():
			return
		if vehicle != null:
			# (a vehicle may refuse while it is unsafe to step out: the shuttle in flight)
			if not vehicle.has_method("can_exit") or vehicle.can_exit():
				exit_vehicle()
		elif interact_target != null and _ragdoll == null:
			interact_target.interact(self)
		get_viewport().set_input_as_handled()
		return
	if vehicle != null:
		return
	if _ragdoll != null:
		if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_ragdoll.orbit(Settings.look(event.relative).x * MOUSE_SENS)
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var lk := Settings.look(event.relative)      # sensitivity / invert Y (Esc › Ayarlar)
		viewmodel.add_look(lk)
		rotate_object_local(Vector3.UP, -lk.x * MOUSE_SENS * look_scale)
		_pitch = clampf(_pitch - lk.y * MOUSE_SENS * look_scale, -1.5, 1.5)
		head.rotation.x = _pitch
	elif event.is_action_pressed("flashlight"):
		toggle_lamp()
		get_viewport().set_input_as_handled()


## Camera shake (0..1, accumulates up to 1), e.g. explosions by distance.
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## "Up" of the planet under a position.
func _world_up(pos: Vector3) -> Vector3:
	var b := Game.dominant_body(pos)
	var c: Vector3 = b.global_position if b != null else Game.planet_center()
	var u := pos - c
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


func _physics_process(delta: float) -> void:
	if vehicle != null or _ragdoll != null:
		return
	if waiting_ground:
		_wait_for_ground()
		return
	# Something shoved us hard (blast, big hit impulse): tumble.
	var shove := velocity - _last_vel
	if shove.length() > RAGDOLL_PUSH and _rag_cooldown <= 0.0:
		ragdoll(Vector3.ZERO, 2.0)
		return
	gravity_vec = Game.gravity_at(global_position + global_transform.basis.y * 0.9)
	var g_len := gravity_vec.length()
	zero_g = g_len < 0.05
	if zero_g:
		# (Never happens on the planets; drift gently if it ever does.)
		velocity *= 0.99
		move_and_slide()
	else:
		_move_gravity(delta, g_len)
	_last_vel = velocity
	# Positions of the last two physics steps: the view is drawn between them (_update_head_bob).
	_phys_prev = _phys_cur
	_phys_cur = global_position
	if _phys_prev.distance_squared_to(_phys_cur) > 4.0:
		_phys_prev = _phys_cur          # teleport / respawn: no smear
	if _ragdoll == null:
		_update_interact()


## Spawned / respawned: stay put until the ground below has full-detail collision, then drop onto it.
func _wait_for_ground() -> void:
	velocity = Vector3.ZERO
	var body: Node3D = _spawn_body if _spawn_body != null else Game.dominant_body(global_position)
	if body != null and body.has_method("terrain_ready_near") and not body.terrain_ready_near(global_position, 8.0, 1.5):
		return
	var up := _world_up(global_position)
	var q := PhysicsRayQueryParameters3D.create(global_position + up * 6.0, global_position - up * 30.0,
			Game.LAYER_TERRAIN, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		global_position = (hit["position"] as Vector3) + up * 0.05
	waiting_ground = false
	_phys_prev = global_position
	_phys_cur = global_position
	_last_vel = Vector3.ZERO


func _move_gravity(delta: float, g_len: float) -> void:
	var up := -gravity_vec / g_len
	_align_up(up, delta * (12.0 if g_len > 4.0 else 4.0))
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	up_direction = up

	var b := global_transform.basis
	var inp := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if _dead:
		inp = Vector2.ZERO
	var wish := b.x * inp.x + b.z * inp.y
	wish -= up * wish.dot(up)
	var on_floor := is_on_floor()
	# Sprint builds up: a short delay, then ~0.4 s to full speed; eases off when released. In the air
	# it is kept as it was, so a hop does not cost the run-up.
	var want_sprint := Input.is_action_pressed("sprint") and inp.y < -0.3 and move_speed_mult >= 0.9
	if on_floor:
		_sprint_hold = _sprint_hold + delta if want_sprint else 0.0
		if want_sprint and _sprint_hold > 0.12:
			_sprint_k = minf(_sprint_k + delta / 0.4, 1.0)
		else:
			_sprint_k = maxf(_sprint_k - delta / 0.35, 0.0)
	elif not want_sprint:
		_sprint_k = maxf(_sprint_k - delta / 0.35, 0.0)
	var speed := lerpf(WALK, SPRINT, _sprint_k * _sprint_k * (3.0 - 2.0 * _sprint_k)) * move_speed_mult

	var v_up := up * velocity.dot(up)
	var v_h := velocity - v_up
	# Suit: firm but not floaty acceleration, a bit firmer braking, little control in the air.
	var target := wish * speed
	var accel := 2.2
	if on_floor:
		accel = 15.0 if target.length_squared() < 0.01 else 12.0
		if target.length_squared() > 0.01 and v_h.dot(target) < 0.0:
			accel = 16.0    # turning around: plant the feet
	elif v_h.dot(target) > 0.0:
		# Air control steers but never brakes a running jump down to walking speed.
		target = target.normalized() * maxf(target.length(), v_h.length())
	v_h = v_h.move_toward(target, accel * delta)
	v_up += gravity_vec * delta
	# Forgiving jump: a little after running off an edge (coyote time), or pressed just before
	# touching down (buffer); bumpy voxel ground makes is_on_floor() flicker.
	_coyote = 0.12 if on_floor else maxf(_coyote - delta, 0.0)
	_jump_buf = 0.12 if Input.is_action_just_pressed("jump") and not _dead else maxf(_jump_buf - delta, 0.0)
	if _jump_buf > 0.0 and _coyote > 0.0 and v_up.dot(up) < JUMP * 0.5:
		v_up = up * JUMP
		_jump_buf = 0.0
		_coyote = 0.0
		if Game.sfx:
			Game.sfx.play("step", -9.0, 0.8)

	# Jetpack: hold jump in the air. Weak (a hop out of a pit, over a crater rim), short (2.5 s),
	# capped climb speed, thrust gone 20 m above the ground; refills slowly on the ground.
	jetting = false
	_jet_power = 0.0
	if Input.is_action_pressed("jump") and not _dead:
		_jump_hold += delta
		if not on_floor and _jump_hold > 0.2 and jet_fuel > 0.0:
			var k := _jet_ground_factor(up, delta)
			_jet_power = k
			if v_up.dot(up) < JET_MAX_CLIMB * k:
				v_up += up * JET_ACCEL * k * delta
			jet_fuel = maxf(jet_fuel - delta, 0.0)
			jetting = k > 0.01
			_jet_idle = 0.0
			_jet_low_fuel(delta)
	else:
		_jump_hold = 0.0
	if on_floor and not jetting:
		_jet_idle += delta
		if _jet_idle > JET_REFILL_DELAY:
			jet_fuel = minf(JET_FUEL, jet_fuel + delta * JET_FUEL / JET_REFILL_TIME)
	var fall := v_up.dot(up)
	if fall < -60.0:
		v_up = up * -60.0
	velocity = v_h + v_up
	_last_fall = maxf(_last_fall * 0.9, -v_up.dot(up))
	var pre_v := velocity
	move_and_slide()
	# Hard landing / crash into a wall: hurts above ~10 m/s, tumbles as a ragdoll above 14 m/s.
	var impact := (pre_v - velocity).length()
	if impact > FALL_DMG_SPEED and _rag_cooldown <= 0.0:
		take_damage((impact - FALL_DMG_SPEED) * 6.0)
	if impact > RAGDOLL_IMPACT and _rag_cooldown <= 0.0 and not _dead and _ragdoll == null:
		_was_on_floor = true
		ragdoll(pre_v * 0.55 - velocity, 2.0)
		return
	_footsteps(delta, v_h.length())


## Jetpack fuel 0..1 (HUD).
func jet_fuel_frac() -> float:
	return jet_fuel / JET_FUEL


## Footsteps on the body's gait (a step each time a foot plants: phase 0 and 0.5), so the sound,
## the head dip and the arms keep one rhythm. Landings thump and dip the view with the fall speed.
func _footsteps(_delta: float, h_speed: float) -> void:
	var on_floor := is_on_floor()
	if on_floor and not _was_on_floor and _last_fall > 2.0:
		var k := clampf((_last_fall - 2.0) / 8.0, 0.0, 1.0)
		if Game.sfx:
			Game.sfx.play("step", lerpf(-16.0, -2.0, k), lerpf(0.9, 0.7, k))
		_land_vel -= minf(_last_fall, 12.0) * 0.012
		_last_fall = 0.0
	if on_floor and h_speed > 1.0:
		var half := floori(astronaut._phase * 2.0)
		if half != _step_half:
			_step_half = half
			if Game.sfx:
				Game.sfx.play("step", -14.0, randf_range(0.93, 1.07))
	_was_on_floor = on_floor


## Rotates the body so its up axis approaches `up` (pivoting at the feet).
func _align_up(up: Vector3, rate: float) -> void:
	var b := global_transform.basis
	var cur := b.y.normalized()
	var d := cur.dot(up)
	if d > 0.99999:
		return
	var axis := cur.cross(up)
	if axis.length_squared() < 1e-8:
		axis = b.x
	axis = axis.normalized()
	var ang := acos(clampf(d, -1.0, 1.0))
	var step := ang * clampf(rate, 0.0, 1.0)
	global_transform.basis = (Basis(axis, step) * b).orthonormalized()


func _update_interact() -> void:
	var target = null
	var space := get_world_3d().direct_space_state
	var from := aim_origin()
	var to := from - camera.global_transform.basis.z * INTERACT_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to,
			Game.LAYER_SHIP | Game.LAYER_VEHICLE | Game.LAYER_INTERACT, [get_rid()])
	q.collide_with_areas = true
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		var col = hit["collider"]
		if col.has_meta("interact_target"):
			target = col.get_meta("interact_target")
		elif col.has_method("interact"):
			target = col
	interact_target = target
	if Game.hud:
		Game.hud.set_prompt(target.get_interact_prompt() if target != null and target.has_method("get_interact_prompt") else "")


# ------------------------------------------------------------------------------------------
# Vehicles (seat API, for the phase-3 shuttle)
# ------------------------------------------------------------------------------------------

func enter_vehicle(v) -> void:
	vehicle = v
	interact_target = null
	if Game.hud:
		Game.hud.set_prompt("")
	_col.disabled = true
	visible = false
	velocity = Vector3.ZERO
	for it in items:
		it.set_active(false)
	v.set_pilot(self)
	Game.controlled = v


func exit_vehicle() -> void:
	var v = vehicle
	var xf: Transform3D = v.get_exit_transform()
	var vel: Vector3 = v.get_exit_velocity()
	v.set_pilot(null)
	vehicle = null
	global_transform = xf
	velocity = vel
	_pitch = 0.0
	head.rotation.x = 0.0
	_col.disabled = false
	visible = true
	for it in items:
		it.set_active(true)
	camera.current = true
	Game.controlled = self
	_last_vel = velocity


func hud_velocity() -> Vector3:
	if _ragdoll != null:
		return _ragdoll.pelvis_velocity()
	return velocity


func hud_name() -> String:
	return "Astronot"


func hud_extra() -> String:
	return ""


# ------------------------------------------------------------------------------------------
# Ragdoll
# ------------------------------------------------------------------------------------------

func is_ragdolled() -> bool:
	return _ragdoll != null


## Knocks the astronaut over: a physical ragdoll launched with the current velocity + `impulse`
## (a velocity change in m/s). Stays down at least `duration` s, then stands up where it landed
## (or, when dead, lies there until the respawn).
func ragdoll(impulse: Vector3, duration := 2.5, exclude: Array = []) -> void:
	if _ragdoll != null or vehicle != null:
		return
	var vel := velocity + impulse
	_ragdoll = Ragdoll.new()
	get_parent().add_child(_ragdoll)
	astronaut.set_first_person(false)
	astronaut.set_held(_held_icon)
	viewmodel.visible = false
	for it in items:
		it.set_active(false)
	_col.disabled = true
	velocity = Vector3.ZERO
	jetting = false
	interact_target = null
	camera.rotation = Vector3.ZERO
	if Game.hud:
		Game.hud.set_prompt("")
		if vel.length() > 9.0 and not _dead:
			Game.hud.show_message("Sersemledin!", 1.8)
	if Game.sfx:
		Game.sfx.play("impact", lerpf(-12.0, -2.0, clampf(vel.length() / 25.0, 0.0, 1.0)), 0.9)
	_lamp_local = flashlight.transform
	_ragdoll.start(self, vel, duration, exclude)
	if _dead:
		_ragdoll.no_float_recover = true
	_ragdoll.finished.connect(_end_ragdoll)


## While ragdolled the (non-colliding) player body rides along with the pelvis so the HUD, sound
## and terrain streaming follow; the headlamp sticks to the helmet.
func _follow_ragdoll() -> void:
	global_position = _ragdoll.pelvis().global_position
	flashlight.global_transform = astronaut.head.global_transform * Transform3D(Basis(), Vector3(0.17, 0.17, -0.16))


## The ragdoll came to rest: stand up on the ground below the pelvis, facing where the chest
## pointed, and hand the controls back. (Dead: stay down, the respawn timer takes over.)
func _end_ragdoll(pos: Vector3, fwd: Vector3) -> void:
	if _dead:
		return
	var a = astronaut
	# Capture the lying pose (bone locals; the hips in world space) before moving the body.
	var bones: Array = [a.hips, a.chest, a.head] + a.shoulder + a.elbow + a.thigh + a.shin
	var hips_g: Transform3D = a.hips.global_transform
	_getup_l0.clear()
	for b in bones:
		_getup_l0[b] = b.transform
	var up: Vector3 = _world_up(pos)
	var q := PhysicsRayQueryParameters3D.create(pos + up * 1.2, pos - up * 2.5,
			Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var feet: Vector3 = (hit["position"] + up * 0.05) if not hit.is_empty() else pos - up * 0.5
	var z := -(fwd - up * fwd.dot(up))
	if z.length_squared() < 1e-4:
		z = up.cross(Vector3.RIGHT)
	z = z.normalized()
	var x := up.cross(z).normalized()
	global_transform = Transform3D(Basis(x, up, x.cross(up)), feet)
	a.transform = Transform3D.IDENTITY
	_getup_l0[a.hips] = a.global_transform.affine_inverse() * hips_g
	_pitch = 0.0
	head.rotation.x = 0.0
	camera.rotation = Vector3.ZERO
	_getup_t = 0.0
	_ragdoll.begin_getup(camera, GETUP_TIME)
	if Game.sfx:
		Game.sfx.play("servo", -14.0, 0.8)


## Key poses of the get-up (bone locals): 1 = on hands and knees, 2 = kneeling on one knee.
func _getup_pose(k: int) -> Dictionary:
	if _getup_poses.has(k):
		return _getup_poses[k]
	var a = astronaut
	var d := {}
	var spec := {}
	if k == 1:
		spec = {a.hips: [Vector3(0, 0.5, 0.12), Vector3(-1.25, 0, 0)], a.chest: Vector3(-0.1, 0, 0),
				a.head: Vector3(0.9, 0, 0), a.shoulder[0]: Vector3(1.25, 0, -0.1), a.shoulder[1]: Vector3(1.25, 0, 0.1),
				a.elbow[0]: Vector3(0.15, 0, 0), a.elbow[1]: Vector3(0.15, 0, 0),
				a.thigh[0]: Vector3(1.3, 0, -0.05), a.thigh[1]: Vector3(1.3, 0, 0.05),
				a.shin[0]: Vector3(-1.55, 0, 0), a.shin[1]: Vector3(-1.55, 0, 0)}
	else:
		spec = {a.hips: [Vector3(0, 0.52, 0.05), Vector3(-0.22, 0, 0)], a.chest: Vector3(-0.05, 0, 0),
				a.head: Vector3(0.18, 0, 0), a.shoulder[0]: Vector3(0.55, 0, -0.18), a.shoulder[1]: Vector3(0.85, 0, 0.15),
				a.elbow[0]: Vector3(0.6, 0, 0), a.elbow[1]: Vector3(0.7, 0, 0),
				a.thigh[0]: Vector3(1.55, 0, -0.05), a.thigh[1]: Vector3(0.15, 0, 0.05),
				a.shin[0]: Vector3(-1.5, 0, 0), a.shin[1]: Vector3(-1.55, 0, 0)}
	for b in spec:
		var r: Transform3D = a.rest_local(b)
		if spec[b] is Array:
			d[b] = Transform3D(Basis.from_euler(spec[b][1]), spec[b][0])
		else:
			d[b] = Transform3D(Basis.from_euler(spec[b]), r.origin)
	_getup_poses[k] = d
	return d


## Visible get-up (~1.4 s): roll onto hands and knees, push up onto one knee, stand.
func _animate_getup(delta: float) -> void:
	_getup_t += delta
	var t := _getup_t
	var a = astronaut
	var k1 := _getup_pose(1)
	var k2 := _getup_pose(2)
	var t1 := GETUP_TIME * 0.34
	var t2 := GETUP_TIME * 0.64
	for b in _getup_l0:
		var x: Transform3D
		if t < t1:
			x = (_getup_l0[b] as Transform3D).interpolate_with(k1[b], _ease(t / t1))
		elif t < t2:
			x = (k1[b] as Transform3D).interpolate_with(k2[b], _ease((t - t1) / (t2 - t1)))
		else:
			x = (k2[b] as Transform3D).interpolate_with(a.rest_local(b), _ease((t - t2) / (GETUP_TIME - t2)))
		b.transform = x
	flashlight.global_transform = a.head.global_transform * Transform3D(Basis(), Vector3(0.17, 0.17, -0.16))
	if t >= GETUP_TIME:
		_finish_getup()


static func _ease(v: float) -> float:
	var k := clampf(v, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


## Control returns: collision on, items raised again, own camera current.
func _finish_getup() -> void:
	_getup_t = -1.0
	velocity = Vector3.ZERO
	_last_vel = Vector3.ZERO
	_last_fall = 0.0
	_col.disabled = false
	astronaut.transform = Transform3D.IDENTITY
	astronaut.reset_pose()
	astronaut.set_first_person(true)
	viewmodel.visible = true
	flashlight.transform = _lamp_local
	for it in items:
		it.set_active(true)
		it.set_equipped(false)
	_pending_equip = current_item
	viewmodel.swap_to(items[current_item], Callable())
	camera.current = true
	if _ragdoll != null:
		_ragdoll.queue_free()
	_ragdoll = null
	_rag_cooldown = 1.2


## Subtle head bob from footsteps: a dip per step and a slight sway per stride.
func _update_head_bob(delta: float) -> void:
	var up := global_transform.basis.y
	var hv := velocity - up * velocity.dot(up)
	var moving: bool = is_on_floor() and hv.length() > 0.5
	_bob_amt = move_toward(_bob_amt, clampf(hv.length() / SPRINT, 0.0, 1.0) if moving else 0.0, delta * 3.0)
	# On the body's gait clock: the head is lowest when a foot plants (phase 0 and 0.5).
	var ph: float = astronaut._phase * TAU
	var dip := -(0.5 + 0.5 * cos(2.0 * ph)) * 0.022 * _bob_amt
	var sway := sin(ph) * 0.01 * _bob_amt
	# Landing dip: a short spring.
	_land_vel += (-_land_off * 120.0 - _land_vel * 15.0) * delta
	_land_off = clampf(_land_off + _land_vel * delta, -0.14, 0.05)
	# Physics steps at 60 Hz: on faster screens draw the view between the last two physics
	# positions (at most one tick behind) instead of letting it step.
	var moved := global_position - _phys_cur
	if moved != Vector3.ZERO:
		_phys_prev += moved
		_phys_cur += moved
	var lag := _phys_prev.lerp(_phys_cur, Engine.get_physics_interpolation_fraction()) - global_position
	head.position = Vector3(sway, 1.6 + dip + _land_off, 0.0) + global_transform.basis.inverse() * lag


# ------------------------------------------------------------------------------------------
# Jetpack
# ------------------------------------------------------------------------------------------

## Thrust factor from the height above the ground (ray every 0.1 s while flying).
func _jet_ground_factor(up: Vector3, delta: float) -> float:
	_jet_h_t -= delta
	if _jet_h_t <= 0.0:
		_jet_h_t = 0.1
		var from := global_position + up * 0.2
		var q := PhysicsRayQueryParameters3D.create(from, from - up * (JET_ZERO_H + 10.0),
				Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE, [get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		_jet_ground_hit = not hit.is_empty()
		if _jet_ground_hit:
			_jet_ground = hit["position"]
			_jet_h = from.distance_to(_jet_ground) - 0.2
		else:
			_jet_h = JET_ZERO_H + 10.0
	return 1.0 - smoothstep(JET_FULL_H, JET_ZERO_H, _jet_h)


## Low tank: a warning beep.
func _jet_low_fuel(delta: float) -> void:
	var frac := jet_fuel / JET_FUEL
	if frac > 0.25:
		return
	_jet_beep -= delta
	if _jet_beep <= 0.0:
		_jet_beep = lerpf(0.25, 0.5, frac / 0.25)
		if Game.sfx:
			Game.sfx.play("ding", -15.0, 2.2)


## Jet effects: orange light on the ground below, dust kicked up when close to the ground.
func _build_jet_fx() -> void:
	_jet_fx_light = OmniLight3D.new()
	_jet_fx_light.light_color = Color(1.0, 0.55, 0.22)
	_jet_fx_light.omni_range = 6.0
	_jet_fx_light.light_energy = 0.0
	_jet_fx_light.shadow_enabled = false
	_jet_fx_light.position = Vector3(0, 0.5, 0.3)
	add_child(_jet_fx_light)
	_jet_dust = GPUParticles3D.new()
	_jet_dust.top_level = true
	_jet_dust.amount = 26
	_jet_dust.lifetime = 1.4
	_jet_dust.local_coords = false
	_jet_dust.emitting = false
	_jet_dust.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0, 1, 0)
	pm.emission_ring_radius = 0.6
	pm.emission_ring_inner_radius = 0.2
	pm.emission_ring_height = 0.05
	pm.direction = Vector3(0, 0.25, 0)
	pm.spread = 80.0
	pm.flatness = 0.7
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 4.5
	pm.radial_accel_min = 2.0
	pm.radial_accel_max = 4.0
	pm.damping_min = 1.5
	pm.damping_max = 2.5
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.8
	pm.scale_max = 1.8
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.4))
	sc.add_point(Vector2(1, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.15, Color(1, 1, 1, 0.4))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = Color(0.75, 0.68, 0.6)
	_jet_dust.process_material = pm
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 0.9)
	q.material = m
	_jet_dust.draw_pass_1 = q
	_jet_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_jet_dust)


func _update_jet_fx(delta: float) -> void:
	var p := _jet_power if jetting else 0.0
	var flick := randf_range(0.75, 1.15)
	_jet_fx_light.light_energy = lerpf(_jet_fx_light.light_energy, p * 2.2 * flick, 1.0 - exp(-20.0 * delta))
	_jet_fx_light.visible = _jet_fx_light.light_energy > 0.02
	var near := jetting and _jet_ground_hit and _jet_h < 5.0
	_jet_dust.emitting = near
	if near:
		var up := global_transform.basis.y
		_jet_dust.global_transform = Transform3D(VMParts.basis_y(up), _jet_ground + up * 0.1)
		_jet_dust.amount_ratio = clampf(1.0 - _jet_h / 5.0, 0.2, 1.0)


## Jet thrust 0..1 this frame (sfx.gd: the roar follows it).
func jet_effect() -> float:
	return _jet_power if jetting else 0.0


# ------------------------------------------------------------------------------------------
# Health (group "damageable")
# ------------------------------------------------------------------------------------------

func is_dead() -> bool:
	return _dead


## Damage from any source. from_pos (world) drives the HUD hit direction (ZERO = none); impulse is
## a velocity change (m/s) that shoves the body (a big one knocks it over). Returns
## {"dmg": damage dealt, "killed": true when this hit killed}.
func take_damage(amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO) -> Dictionary:
	if _dead or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	# Inside a vehicle with a hull (the shuttle): it takes the hits instead.
	if vehicle != null and vehicle.has_method("shield_pilot"):
		amount = float(vehicle.shield_pilot(amount, from_pos))
		if amount <= 0.0:
			return {"dmg": 0.0, "killed": false}
	hp = maxf(hp - amount, 0.0)
	_since_hit = 0.0
	var k := clampf(amount / 30.0, 0.15, 1.0)
	var dir_x := 0.0
	if from_pos != Vector3.ZERO:
		var local := camera.global_transform.affine_inverse() * from_pos
		dir_x = signf(local.x)
	_punch += Vector3(randf_range(0.02, 0.05) * k, -dir_x * 0.04 * k, randf_range(-0.04, 0.04) * k)
	if Game.sfx:
		Game.sfx.play("impact" if amount >= 20.0 else "impact_light", lerpf(-12.0, -3.0, k), randf_range(0.8, 1.05))
	if Game.hud and Game.hud.has_method("on_player_damaged"):
		Game.hud.on_player_damaged(amount, from_pos)
	if impulse != Vector3.ZERO and _ragdoll == null and vehicle == null:
		velocity += impulse
	if hp <= 0.0:
		_die(impulse)
		return {"dmg": amount, "killed": true}
	return {"dmg": amount, "killed": false}


func heal(amount: float) -> void:
	if not _dead:
		hp = minf(hp + amount, hp_max)


func _update_health(delta: float) -> void:
	if _dead:
		return
	_since_hit += delta
	if _since_hit > REGEN_DELAY and hp < hp_max:
		hp = minf(hp + REGEN_RATE * delta, hp_max)


## Death: collapse as a ragdoll (the camera follows the body), then respawn on the home planet
## facing the rival with full health. The material is kept.
func _die(impulse := Vector3.ZERO) -> void:
	if _dead:
		return
	_dead = true
	if Game.hud:
		Game.hud.show_message("Öldün — yeniden doğuluyor…", RESPAWN_DELAY)
	if vehicle != null:
		exit_vehicle()
	if _ragdoll == null:
		ragdoll(impulse, 60.0)
	elif _ragdoll != null:
		_ragdoll.no_float_recover = true
	await get_tree().create_timer(RESPAWN_DELAY).timeout
	if not is_inside_tree():
		return
	if Game.hud and Game.hud.has_method("fade_to_black"):
		await Game.hud.fade_to_black(0.6).finished
	_respawn()
	if Game.hud and Game.hud.has_method("fade_from_black"):
		Game.hud.fade_from_black(0.8)


func _respawn() -> void:
	if _ragdoll != null:
		_ragdoll.queue_free()
		_ragdoll = null
	_getup_t = -1.0
	_col.disabled = false
	astronaut.transform = Transform3D.IDENTITY
	astronaut.reset_pose()
	astronaut.set_first_person(true)
	viewmodel.visible = true
	flashlight.transform = _lamp_local if _lamp_local != Transform3D() else flashlight.transform
	for it in items:
		it.set_active(true)
		it.set_equipped(false)
	_pending_equip = current_item
	viewmodel.swap_to(items[current_item], Callable())
	hp = hp_max
	jet_fuel = JET_FUEL
	_since_hit = 99.0
	_rag_cooldown = 2.0
	_dead = false
	camera.current = true
	Game.controlled = self
	spawn(Game.planet)
