extends "res://scripts/items/item.gd"
## Kazı Aracı: the player's drill (key 1). Astroneer-style terrain tool: dig, raise, flatten.
## Digging collects generic soil into Game.material; raising and flattening spend it (a flatten that
## cuts away ground also collects). Visual effects live in scripts/items/dig_fx.gd, the brush itself
## in scripts/player/dig.gd (shared with the AI rival).
## Controls: LMB applies the mode, RMB the opposite (dig <-> raise), R / middle mouse cycles the mode,
## mouse wheel changes the brush radius.

const DigFx := preload("res://scripts/items/dig_fx.gd")
const Dig := preload("res://scripts/player/dig.gd")
const Balance := preload("res://scripts/war/balance.gd")
const Core := preload("res://scripts/war/core.gd")

enum Mode { DIG, RAISE, FLATTEN }
const MODE_NAMES := ["KAZ", "YÜKSELT", "DÜZLE"]
const MODE_COLORS := [Color(1.0, 0.55, 0.15), Color(0.3, 0.9, 0.45), Color(0.35, 0.65, 1.0)]
const RANGE := 10.0             # m: aim reach
const RATE := 7.0               # density change per second at full power (≈ m/s of digging at the centre)
const RADIUS_MIN := 1.0
const RADIUS_MAX := 5.0
const FILL_DISPLAY := 200.0     # m³ that fill the canister on the model (display only, no cap)

var mode: int = Mode.DIG
var radius := 2.2
var aim_valid := false
var work_mode := 0             # mode actually applied this frame (RMB inverts dig/raise)

var fx
var _tip: Node3D
var _glow: ShaderMaterial
var _emitter: ShaderMaterial
var _coils: Array = []
var _soil_fill: MeshInstance3D
var _use_t := 0.0
var _power := 0.0               # emitter spin-up 0..1 (sfx.gd reads it for the hum)
var _t := 0.0
var _glow_col := Color.BLACK
var _empty_msg_t := 0.0


func _init() -> void:
	item_id = "terrain"
	item_name = "Kazı Aracı"
	item_desc = "Araziyi kazar, yükseltir ve düzler. Kazdıkça malzeme toplanır; yükseltmek ve düzlemek malzeme harcar."
	icon = "terrain"


func _ready() -> void:
	fx = DigFx.new()
	add_child(fx)
	if _tip:
		fx.tip_node = _tip
	_set_mode(Mode.DIG)


## First-person model: white housing, orange trim, glowing coil rings colored by mode.
func build_model() -> Node3D:
	model = Node3D.new()
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	_glow = VM.glow(MODE_COLORS[mode], 3.0)
	_emitter = VM.glow(MODE_COLORS[mode], 6.0)
	VM.grip(model, orange)
	# Trigger + guard.
	VM.box(model, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(model, Vector3(0, -0.018, -0.022), Vector3(0, -0.018, -0.06), 0.0045, steel)
	VM.capsule(model, Vector3(0, -0.018, -0.06), Vector3(0, 0.025, -0.07), 0.0045, steel)
	# Main housing.
	var y := 0.052
	VM.capsule(model, Vector3(0, y, 0.07), Vector3(0, y, -0.12), 0.041, white, 20)
	VM.seg(model, Vector3(0, y, 0.025), Vector3(0, y, -0.035), 0.0435, 0.0435, orange, 20)
	VM.box(model, Vector3(0, y + 0.046, -0.02), Vector3(0.018, 0.016, 0.15), orange)
	VM.box(model, Vector3(0, y + 0.056, -0.075), Vector3(0.008, 0.012, 0.03), dark)
	# Side light strip + vents on the left side (the side the player sees).
	VM.box(model, Vector3(-0.039, y + 0.008, -0.04), Vector3(0.01, 0.022, 0.12), dark)
	VM.box(model, Vector3(-0.0445, y + 0.008, -0.04), Vector3(0.003, 0.006, 0.11), _glow)
	for i in 3:
		VM.box(model, Vector3(-0.036, y - 0.022, 0.045 - i * 0.016), Vector3(0.012, 0.012, 0.007), dark)
	# Rear cap.
	VM.seg(model, Vector3(0, y, 0.095), Vector3(0, y, 0.11), 0.034, 0.024, dark)
	VM.ring(model, Vector3(0, y, 0.1), Vector3.BACK, 0.037, 0.005, orange)
	# Foregrip under the coil housing for the left hand.
	VM.box(model, Vector3(0, y - 0.035, -0.165), Vector3(0.02, 0.03, 0.04), dark)
	VM.capsule(model, Vector3(0, -0.06, -0.162), Vector3(0, 0.0, -0.17), 0.0165, VM.rubber())
	VM.seg(model, Vector3(0, -0.085, -0.16), Vector3(0, -0.072, -0.161), 0.019, 0.018, orange)
	left_grip = VM.node(model, Vector3(0, 0.004, -0.166), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	# Material canister on top: glass rails + glowing fill whose length shows the collected material.
	var cy := y + 0.062
	VM.seg(model, Vector3(0, cy, 0.075), Vector3(0, cy, 0.064), 0.018, 0.018, steel)
	VM.seg(model, Vector3(0, cy, 0.004), Vector3(0, cy, -0.007), 0.018, 0.018, steel)
	VM.seg(model, Vector3(0, cy, 0.064), Vector3(0, cy, 0.004), 0.011, 0.011, VM.mat(Color(0.05, 0.05, 0.06), 0.2, 0.3))
	for sx in [-1.0, 1.0]:
		VM.capsule(model, Vector3(sx * 0.015, cy + 0.006, 0.066), Vector3(sx * 0.015, cy + 0.006, 0.002), 0.0028, steel, 8)
	var fill_root := VM.node(model, Vector3(0, cy, 0.064))
	_soil_fill = VM.seg(fill_root, Vector3.ZERO, Vector3(0, 0, -0.06), 0.0125, 0.0125, VM.glow(Color(1.0, 0.62, 0.25), 2.2), 12)
	VM.box(model, Vector3(0, y + 0.04, 0.035), Vector3(0.03, 0.02, 0.03), dark)
	# Front: coil housing, three glowing coil rings, nozzle and emitter.
	VM.seg(model, Vector3(0, y, -0.125), Vector3(0, y, -0.2), 0.03, 0.027, dark)
	_coils.clear()
	for i in 3:
		_coils.append(VM.ring(model, Vector3(0, y, -0.14 - i * 0.022), Vector3.FORWARD, 0.038, 0.008, _glow))
	VM.seg(model, Vector3(0, y, -0.2), Vector3(0, y, -0.245), 0.03, 0.017, steel)
	VM.ring(model, Vector3(0, y, -0.206), Vector3.FORWARD, 0.033, 0.006, orange)
	VM.sphere(model, Vector3(0, y, -0.247), 0.013, _emitter)
	_tip = VM.node(model, Vector3(0, y, -0.26))
	VM.bake(model, _coils + [_soil_fill.get_parent(), _tip, left_grip])
	if fx:
		fx.tip_node = _tip
	return model


func mode_name() -> String:
	return MODE_NAMES[mode]


func accent_color() -> Color:
	return MODE_COLORS[mode]


## Crosshair / coil colour this frame: the mode actually applied.
func crosshair_color() -> Color:
	return MODE_COLORS[work_mode]


func status_text() -> String:
	return MODE_NAMES[mode]


## HUD line: the three modes (current one highlighted), brush radius, controls.
func hud_hint() -> String:
	var parts := PackedStringArray()
	for i in 3:
		var c: Color = MODE_COLORS[i]
		if i == mode:
			parts.append("[color=#%s][b]%s[/b][/color]" % [c.to_html(false), MODE_NAMES[i]])
		else:
			parts.append("[color=#6f8090]%s[/color]" % MODE_NAMES[i])
	return "%s   [color=#8fa3b5]R: mod · Teker: fırça %.1f m · Sağ tık: ters[/color]" % ["  ›  ".join(parts), radius]


func cycle_mode() -> void:
	_set_mode((mode + 1) % 3)
	kick = maxf(kick, 0.25)
	if Game.sfx:
		Game.sfx.play("click", -10.0, 1.0 + mode * 0.1)


func _set_mode(m: int) -> void:
	mode = m
	var c: Color = MODE_COLORS[m]
	if _glow:
		_glow.set_shader_parameter("color", c)
		_emitter.set_shader_parameter("color", c)


func _on_state_changed() -> void:
	if fx and (not active or not equipped):
		fx.show_preview(false)
		fx.set_working(false)


func _unhandled_input(event: InputEvent) -> void:
	if not can_operate():
		return
	if event.is_action_pressed("tool_mode"):
		cycle_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("brush_up"):
		radius = minf(radius + 0.25, RADIUS_MAX)
	elif event.is_action_pressed("brush_down"):
		radius = maxf(radius - 0.25, RADIUS_MIN)


func _process(delta: float) -> void:
	_t += delta
	_empty_msg_t = maxf(_empty_msg_t - delta, 0.0)
	if model == null:
		return
	_use_t = move_toward(_use_t, 1.0 if using else 0.0, delta * 6.0)
	var gc := crosshair_color()
	if gc != _glow_col:
		_glow_col = gc
		_glow.set_shader_parameter("color", gc)
		_emitter.set_shader_parameter("color", gc)
	var e := 3.0 + _use_t * 3.5 + sin(_t * 3.0) * 0.4
	_glow.set_shader_parameter("energy", e)
	_glow.set_shader_parameter("flicker", _use_t * 0.35)
	_emitter.set_shader_parameter("energy", 5.0 + _use_t * 9.0 * randf_range(0.6, 1.0))
	for i in _coils.size():
		var s := 1.0 + _use_t * 0.14 * sin(_t * 32.0 - i * 1.7)
		_coils[i].scale = Vector3(s, 1.0, s)
	var frac := clampf(Game.material / FILL_DISPLAY, 0.0, 1.0)
	_soil_fill.get_parent().scale = Vector3(1, 1, maxf(frac, 0.02))


func _physics_process(delta: float) -> void:
	using = false
	aim_valid = false
	if not can_operate():
		fx.show_preview(false)
		return
	var cam := get_parent() as Camera3D
	var from: Vector3 = player.aim_origin()
	var dir := -cam.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * RANGE, Game.LAYER_TERRAIN)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		fx.show_preview(false)
		_power = move_toward(_power, 0.0, delta * 4.0)
		return
	aim_valid = true
	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var up: Vector3 = player.global_transform.basis.y
	var m: int = mode
	var primary := Input.is_action_pressed("tool_use")
	var secondary := Input.is_action_pressed("tool_alt")
	var pressing := (primary or secondary) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if pressing and secondary and not primary:
		if mode == Mode.DIG:
			m = Mode.RAISE
		elif mode == Mode.RAISE:
			m = Mode.DIG
	work_mode = m
	fx.show_preview(true, point, radius, MODE_COLORS[m], m == Mode.FLATTEN, player.global_position, up, normal, m)
	# The emitter spins up: ~0.4 s to full strength, drops quickly when released. A tap still bites.
	_power = move_toward(_power, 1.0 if pressing else 0.0, delta * (2.5 if pressing else 4.0))
	if not pressing:
		return
	if m != Mode.DIG and Game.material <= 0.01:
		# Raising / flattening places soil: nothing to place without material.
		if _empty_msg_t <= 0.0:
			_empty_msg_t = 2.5
			if Game.hud:
				Game.hud.show_message("Malzeme yok — önce kaz", 2.0)
			if Game.sfx:
				Game.sfx.play("error", -12.0)
		return
	var rate := RATE * (0.35 + 0.65 * _power)
	var body: Node3D = Game.dominant_body(point)
	var soil := Dig.dig_at(body, point, radius, m, rate * delta, player.global_position, up,
			-1.0 if m == Mode.DIG else Game.material)
	# Dug soil becomes material at most DRILL_MAX_RATE m³/s (a bigger brush digs more, not faster);
	# placed soil is always paid in full.
	Game.add_material(minf(soil, Balance.DRILL_MAX_RATE * delta) if soil > 0.0 else soil)
	# The rival's core (when you reach it) takes drill damage.
	Core.drill_all(get_tree(), point, radius, "home", delta)
	using = true
	var tp: Array = _tip_world(cam, from, dir)
	var soil_col: Color = body.get("soil_color") if body != null and body.get("soil_color") != null else Color(0.45, 0.35, 0.24)
	fx.work(tp[0], tp[1], point, normal, up, m, radius, MODE_COLORS[m], soil_col)


## [position, direction] of the nozzle in world space (where the beam starts).
func _tip_world(cam: Camera3D, from: Vector3, dir: Vector3) -> Array:
	fx.tip_node = _tip
	fx.tip_is_vm = true
	if _tip == null:
		return [from, dir]
	var tip_pos := VM.vm_to_world(cam, _tip.global_position)
	var tip_dir := (VM.vm_to_world(cam, _tip.global_position - _tip.global_transform.basis.z) - tip_pos).normalized()
	return [tip_pos, tip_dir]
