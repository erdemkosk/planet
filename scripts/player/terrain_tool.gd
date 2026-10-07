extends "res://scripts/items/item.gd"
## Kazı Aracı: the player's drill (key 1). Astroneer-style terrain tool: dig, raise, flatten.
## Digging collects generic soil into Game.material; raising and flattening spend it (a flatten that
## cuts away ground also collects). Visual effects live in scripts/items/dig_fx.gd, the brush itself
## in scripts/player/dig.gd (shared with the AI rival).
## Controls: LMB applies the mode, RMB the opposite (dig <-> raise), middle mouse cycles the mode,
## R vents the heat, the mouse wheel changes the brush radius, E (Mk IV) the burst bore.
##
## Heat (matkap ısınması, 2026-10-06; logic scripts/items/drill_heat.gd, numbers Balance "Drill heat
## and upgrades"): working heats the drill (faster with a bigger brush), resting cools it. Past 60 %
## the vent window opens: a marker sweeps the gauge; R in the white sweet spot = instant cool + SÜPER
## KAZI (+40 % rate, teal glow), in the amber zone = a partial cool, elsewhere = a jam (a short
## lockout, a steam cough); ignored to the top = an overheat lockout. Gauges: the side strip of the
## model (GAUGE_SHADER), the coils and the side vents glowing orange → white-hot, a heat shimmer at the
## nozzle (HAZE_SHADER), the wrist screen (wrist_display.gd set_drill) and the quickbar (it reads
## `heat`, `heat_max`, `overheated` and heat_info()). Sounds / steam / the material tick ladder:
## scripts/items/drill_feel.gd.
## Upgrades (scripts/items/drill_tiers.gd; craft.gd "drill_mk2" .. "drill_mk4" at the Silahlık):
## Mk II-IV raise the dig rate and the material cap (× tier rate), the max brush radius and the heat
## tolerance; Mk III auto-collects crater soil nearby (planet.gd crater_done), Mk IV adds the burst
## bore (hold E: a straight 3 m tunnel). Each tier shows on the model (bands, extra coils, an
## intake, the bore bit). Material credit: min(soil, DRILL_MAX_RATE × tier rate × SÜPER) per second,
## then × Veins.mult_at(body, point) (scripts/planet/veins.gd, rich veins, when it exists).

const DigFx := preload("res://scripts/items/dig_fx.gd")
const Dig := preload("res://scripts/player/dig.gd")
const Balance := preload("res://scripts/war/balance.gd")
const Core := preload("res://scripts/war/core.gd")
const DrillHeat := preload("res://scripts/items/drill_heat.gd")
const DrillTiers := preload("res://scripts/items/drill_tiers.gd")
const DrillFeel := preload("res://scripts/items/drill_feel.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const VEINS_PATH := "res://scripts/planet/veins.gd"
const HELMET_PATH := "res://scripts/ui/helmet_fx.gd"

enum Mode { DIG, RAISE, FLATTEN }
const MODE_NAMES := ["KAZ", "YÜKSELT", "DÜZLE"]
const MODE_COLORS := [Color(1.0, 0.55, 0.15), Color(0.3, 0.9, 0.45), Color(0.35, 0.65, 1.0)]
const SUPER_COL := Color(0.45, 1.0, 0.95)      # SÜPER KAZI
const HOT_COL := Color(1.0, 0.42, 0.1)
const WHITE_HOT := Color(1.0, 0.95, 0.86)
const LOCK_COL := Color(1.0, 0.22, 0.1)
const RANGE := 10.0             # m: aim reach
const RATE := 16.0              # density change per second at full power (≈ m/s of digging at the centre;
								# user 2026-10-05 "matkap daha hızlı delmeli": was 7); × the tier rate
const RADIUS_MIN := 1.0
const RADIUS_MAX := 5.0         # Mk I; the tier's max is `radius_max` (Balance.DRILL_TIER_RADIUS)
const FILL_DISPLAY := 200.0     # m³ that fill the canister on the model (display only, no cap)

## The heat gauge on the model's side: heat fill (orange → white-hot) from the rear toward the
## nozzle; the vent window's amber zone, white sweet spot and cyan marker; teal ripples in SÜPER KAZI;
## red blinking while locked. View-model projection like vm_parts.gd GLOW_SHADER.
const GAUGE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform vec4 base_col : source_color = vec4(1.0, 0.55, 0.15, 1.0);
uniform float heat = 0.0;
uniform float window_on = 0.0;
uniform float marker = 0.0;
uniform vec2 good = vec2(0.45, 0.79);
uniform vec2 sweet = vec2(0.55, 0.68);
uniform float lock_on = 0.0;
uniform float boost = 0.0;
uniform float flash = 0.0;
uniform vec4 flash_col : source_color = vec4(1.0);
uniform float energy = 3.0;

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

vec3 heat_col(float h) {
	vec3 a = vec3(1.0, 0.3, 0.06);
	vec3 b = vec3(1.0, 0.6, 0.18);
	vec3 c = vec3(1.0, 0.95, 0.85);
	return h < 0.6 ? mix(a, b, h / 0.6) : mix(b, c, (h - 0.6) / 0.4);
}

void fragment() {
	float x = 1.0 - UV.x;
	float edge = smoothstep(0.0, 0.18, UV.y) * smoothstep(1.0, 0.82, UV.y);
	vec3 col = base_col.rgb * 0.22;
	float fill = 1.0 - smoothstep(heat - 0.01, heat + 0.01, x);
	col = mix(col, heat_col(heat) * (0.7 + 0.5 * x), fill);
	if (window_on > 0.5) {
		col *= 0.4;
		float g = step(good.x, x) * step(x, good.y);
		float s = step(sweet.x, x) * step(x, sweet.y);
		col = mix(col, vec3(1.0, 0.66, 0.25), g * 0.75);
		col = mix(col, vec3(1.15), s);
		float m = 1.0 - smoothstep(0.012, 0.03, abs(x - marker));
		col = mix(col, vec3(0.4, 1.3, 1.4), m);
	}
	if (boost > 0.0) {
		float r = 0.5 + 0.5 * sin(TIME * 16.0 - x * 24.0);
		col = mix(col, vec3(0.45, 1.0, 0.95) * (0.7 + 0.6 * r), 0.65 * clamp(boost * 3.0, 0.0, 1.0));
	}
	if (lock_on > 0.5) {
		col = vec3(1.0, 0.2, 0.08) * (0.35 + 0.65 * step(0.5, fract(TIME * 3.0)));
	}
	col = mix(col, flash_col.rgb * 1.3, flash);
	ALBEDO = col * energy * (0.55 + 0.45 * edge);
}
"""

## Heat shimmer in front of the nozzle: the screen behind, wobbled, stronger with heat.
const HAZE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float heat = 0.0;

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float k = heat * facing * facing;
	vec2 off = vec2(sin(SCREEN_UV.y * 140.0 + TIME * 17.0) + sin(SCREEN_UV.y * 61.0 - TIME * 9.0),
			cos(SCREEN_UV.x * 120.0 - TIME * 13.0)) * 0.0035 * k;
	ALBEDO = texture(screen_tex, SCREEN_UV + off).rgb + vec3(0.06, 0.02, 0.0) * k;
	ALPHA = clamp(k * 1.3, 0.0, 1.0);
}
"""

var mode: int = Mode.DIG
var radius := 2.2
var aim_valid := false
var work_mode := 0             # mode actually applied this frame (RMB inverts dig/raise)
## Heat (the quickbar / HUD read these; heat_info() has the vent window too).
var heat := 0.0                # 0 .. heat_max
var heat_max := 100.0
var overheated := false        # locked out (an overheat or a jammed vent)
var tier := 0                  # DrillTiers: 0 Mk I .. 3 Mk IV
var radius_max := RADIUS_MAX
var heat_logic: DrillHeat = DrillHeat.new()

var fx
var _feel: DrillFeel
var _tip: Node3D
var _glow: ShaderMaterial
var _emitter: ShaderMaterial
var _heat_glow: ShaderMaterial  # the coils
var _vent_glow: ShaderMaterial  # the side vents, Mk IV heat sinks
var _gauge: ShaderMaterial
var _haze: ShaderMaterial
var _haze_mi: MeshInstance3D
var _coils: Array = []
var _tier_nodes: Array = []     # [null, Mk II parts, Mk III parts, Mk IV parts]
var _tip_z := [-0.26, -0.262, -0.268, -0.325]
var _bit: Node3D                # Mk IV bore bit (spins)
var _bit_spin := 0.0
var _soil_fill: MeshInstance3D
var _use_t := 0.0
var _power := 0.0               # emitter spin-up 0..1 (sfx.gd reads it for the hum)
var _t := 0.0
var _empty_msg_t := 0.0
var _stats := {}
var _bodies_t := 0.0
var _wrist_node: Node = null
var _wrist_was_on := false
var _was_pressing := false
# Burst bore (Mk IV).
var _bore_charge := 0.0
var _bore_t := -1.0             # >= 0 while boring
var _bore_cd := 0.0
var _bore_from := Vector3.ZERO
var _bore_dir := Vector3.FORWARD
var _bore_body: Node3D
var _bore_done := 0.0
var _bore_budget := 0.0         # m³ this bore may still credit (the drill's rate cap over one bore cycle)
var _soil_bank := 0.0           # dug soil not credited yet (paid out at the rate cap; see _drill_frame)

static var _veins_state := 0    # 0 not looked up yet, 1 none, 2 found
static var _veins_script: Script
static var _gauge_shader: Shader
static var _haze_shader: Shader
static var _hint_window := 0    # first-time hints shown this session
static var _hint_overheat := 0


func _init() -> void:
	item_id = "terrain"
	slot_key = 0                     # (no number key: Z selects the drill, player.gd _tool_key_input)
	item_name = "Kazı Aracı"
	item_desc = "Araziyi kazar, yükseltir ve düzler. Kazdıkça malzeme toplanır; yükseltmek ve düzlemek malzeme harcar."
	icon = "terrain"


func _ready() -> void:
	fx = DigFx.new()
	add_child(fx)
	if _tip:
		fx.tip_node = _tip
	_feel = DrillFeel.new()
	add_child(_feel)
	_feel.pop.connect(_on_pop)
	DrillTiers.events().changed.connect(_on_tier_changed)
	_set_mode(Mode.DIG)
	_apply_tier()


## First-person model: white housing, orange trim, glowing coil rings colored by mode (and heat), the
## heat gauge on the left side, glowing side vents; the tier parts are built hidden and shown by
## _apply_tier_visuals().
func build_model() -> Node3D:
	model = Node3D.new()
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	_glow = VM.glow(MODE_COLORS[mode], 3.0)
	_emitter = VM.glow(MODE_COLORS[mode], 6.0)
	_heat_glow = VM.glow(MODE_COLORS[mode], 3.0)
	_vent_glow = VM.glow(HOT_COL, 0.1)
	var skip: Array = []
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
	# Side panel with the heat gauge + glowing vents on the left side (the side the player sees).
	VM.box(model, Vector3(-0.039, y + 0.008, -0.04), Vector3(0.01, 0.022, 0.12), dark)
	_gauge = ShaderMaterial.new()
	if _gauge_shader == null:
		_gauge_shader = Shader.new()
		_gauge_shader.code = VM.prep(GAUGE_SHADER)
	_gauge.shader = _gauge_shader
	var gq := QuadMesh.new()
	gq.size = Vector2(0.11, 0.009)
	var gmi := VM.mesh_inst(model, gq, _gauge)
	gmi.transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-0.0446, y + 0.008, -0.04))
	skip.append(gmi)
	for i in 3:
		VM.box(model, Vector3(-0.036, y - 0.022, 0.045 - i * 0.016), Vector3(0.012, 0.012, 0.007), _vent_glow)
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
		_coils.append(VM.ring(model, Vector3(0, y, -0.14 - i * 0.022), Vector3.FORWARD, 0.038, 0.008, _heat_glow))
	VM.seg(model, Vector3(0, y, -0.2), Vector3(0, y, -0.245), 0.03, 0.017, steel)
	VM.ring(model, Vector3(0, y, -0.206), Vector3.FORWARD, 0.033, 0.006, orange)
	VM.sphere(model, Vector3(0, y, -0.247), 0.013, _emitter)
	_tip = VM.node(model, Vector3(0, y, -0.26))
	# Heat shimmer ahead of the nozzle.
	_haze = ShaderMaterial.new()
	if _haze_shader == null:
		_haze_shader = Shader.new()
		_haze_shader.code = VM.prep(HAZE_SHADER)
	_haze.shader = _haze_shader
	_haze.render_priority = 1
	_haze_mi = VM.ellipsoid(model, Vector3(0, y + 0.006, -0.3), Vector3(0.026, 0.032, 0.05), _haze)
	_haze_mi.visible = false
	skip.append(_haze_mi)
	_build_tier_parts(y, dark, steel)
	skip.append_array(_tier_nodes.filter(func(n): return n != null))
	VM.bake(model, _coils + [_soil_fill.get_parent(), _tip, left_grip] + skip)
	if fx:
		fx.tip_node = _tip
	_apply_tier_visuals()
	return model


## Tier parts (cumulative: Mk III shows Mk II's too), each tier its own baked group; its extra coils
## stay loose (they pulse) and join _coils.
##   Mk II   a cyan band, a 4th coil, a nozzle collar and a bigger emitter
##   Mk III  an amber band, a 5th coil, a flared intake mouth with two collector fins
##   Mk IV   a violet band, heat-sink fins over the coils, the spinning bore bit
func _build_tier_parts(y: float, dark: Material, steel: Material) -> void:
	_tier_nodes = [null]
	for t in range(1, DrillTiers.MAX_TIER + 1):
		var g := VM.node(model)
		var loose: Array = []
		var band := VM.mat(DrillTiers.COLORS[t], 0.35, 0.25)
		var bz := -0.05 - t * 0.02
		VM.seg(g, Vector3(0, y, bz + 0.004), Vector3(0, y, bz - 0.004), 0.0428, 0.0428, band, 20)
		match t:
			1:
				var c := VM.ring(g, Vector3(0, y, -0.151), Vector3.FORWARD, 0.035, 0.005, _heat_glow)
				loose.append(c)
				VM.ring(g, Vector3(0, y, -0.236), Vector3.FORWARD, 0.024, 0.004, steel)
				VM.sphere(g, Vector3(0, y, -0.249), 0.0155, _emitter)
			2:
				var c := VM.ring(g, Vector3(0, y, -0.173), Vector3.FORWARD, 0.035, 0.005, _heat_glow)
				loose.append(c)
				VM.seg(g, Vector3(0, y, -0.236), Vector3(0, y, -0.258), 0.02, 0.031, dark, 18)
				VM.ring(g, Vector3(0, y, -0.257), Vector3.FORWARD, 0.032, 0.004, VM.glow(DrillTiers.COLORS[2], 2.5))
				for sx in [-1.0, 1.0]:
					VM.box(g, Vector3(sx * 0.031, y, -0.214), Vector3(0.004, 0.02, 0.03), steel)
			3:
				for i in 3:
					VM.box(g, Vector3(0, y + 0.033, -0.15 - i * 0.017), Vector3(0.024, 0.006, 0.004), _vent_glow)
				_bit = VM.node(g, Vector3(0, y, -0.262))
				VM.seg(_bit, Vector3.ZERO, Vector3(0, 0, -0.058), 0.022, 0.0025, steel, 16)
				for i in 3:
					var zr := -0.012 - i * 0.015
					var rr := lerpf(0.02, 0.0045, (float(i) + 0.5) / 3.2)
					VM.ring(_bit, Vector3(0, 0, zr), Vector3(0.18 * (1.0 if i % 2 == 0 else -1.0), 0, -1.0), rr + 0.0035, 0.003,
							VM.glow(DrillTiers.COLORS[3], 3.0))
				VM.bake(_bit)
				loose.append(_bit)
		VM.bake(g, loose)
		for c in loose:
			if c != _bit:
				_coils.append(c)
		_tier_nodes.append(g)


func mode_name() -> String:
	return MODE_NAMES[mode]


func accent_color() -> Color:
	return MODE_COLORS[mode]


## Crosshair / coil colour this frame: the mode actually applied.
func crosshair_color() -> Color:
	return MODE_COLORS[work_mode]


func status_text() -> String:
	return MODE_NAMES[mode]


## HUD line: the three modes (current one highlighted), the heat state, brush radius, controls.
func hud_hint() -> String:
	var parts := PackedStringArray()
	for i in 3:
		var c: Color = MODE_COLORS[i]
		if i == mode:
			parts.append("[color=#%s][b]%s[/b][/color]" % [c.to_html(false), MODE_NAMES[i]])
		else:
			parts.append("[color=#6f8090]%s[/color]" % MODE_NAMES[i])
	var state := ""
	if heat_logic.locked():
		state = "   [color=#ff5a40][b]%s[/b][/color]" % ("TIKANDI" if heat_logic.lock_kind == DrillHeat.LOCK_JAM else "AŞIRI ISINDI")
	elif heat_logic.window:
		state = "   [color=#ffffff][b]R: SOĞUT![/b][/color]"
	elif heat_logic.super_on():
		state = "   [color=#%s][b]SÜPER KAZI[/b][/color]" % SUPER_COL.to_html(false)
	var keys := "Orta tık: mod · R: soğut · Teker: fırça %.1f m · Sağ tık: ters" % radius
	if bool(_stats.get("bore", false)):
		keys += " · E: delici sonda"
	return "%s%s   [color=#8fa3b5]%s[/color]" % ["  ›  ".join(parts), state, keys]


## The heat state for gauges (the quickbar): heat (0..1 share), window, marker, good, sweet (gauge
## shares), locked, lock_kind (DrillHeat LOCK_*), lock_k (0..1 of the lockout left), lock_s, boost
## (0..1 of SÜPER KAZI left), boost_s, flash / flash_kind (a vent's flash: DrillHeat PERFECT / GOOD /
## JAM), tier, tier_name, tier_col.
func heat_info() -> Dictionary:
	var h := heat_logic
	return {"heat": h.frac(), "window": h.window, "marker": h.marker, "good": h.good, "sweet": h.sweet,
			"locked": h.locked(), "lock_kind": h.lock_kind, "lock_k": clampf(h.lock_t / maxf(h.lock_total, 0.01), 0.0, 1.0),
			"lock_s": h.lock_t, "boost": clampf(h.super_t / Balance.DRILL_SUPER_T, 0.0, 1.0), "boost_s": h.super_t,
			"flash": h.vent_flash, "flash_kind": h.last_vent, "tier": tier, "tier_name": DrillTiers.tier_name(tier),
			"tier_col": DrillTiers.COLORS[tier]}


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
		_bore_charge = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if not can_operate():
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE:
		cycle_mode()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.is_action_pressed("tool_mode"):
		vent()                                            # R (the guns' reload key): vent the heat
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("brush_up"):
		radius = minf(radius + 0.25, radius_max)
	elif event.is_action_pressed("brush_down"):
		radius = maxf(radius - 0.25, RADIUS_MIN)


# =================================================================================================
# Heat and vent
# =================================================================================================

## R: vents if the window is open (perfect / good / jam), otherwise a dry click.
func vent() -> void:
	var r := heat_logic.vent()
	var nz := _nozzle()
	match r:
		DrillHeat.PERFECT:
			kick = maxf(kick, 0.4)
			_feel.vent_fx(1, nz[0], nz[1], nz[2])
			if Game.hud:
				Game.hud.show_message("SÜPER KAZI  +%%%d" % int(roundf((Balance.DRILL_SUPER_MULT - 1.0) * 100.0)), 1.6)
		DrillHeat.GOOD:
			kick = maxf(kick, 0.3)
			_feel.vent_fx(2, nz[0], nz[1], nz[2])
		DrillHeat.JAM:
			kick = maxf(kick, 0.55)
			_feel.vent_fx(3, nz[0], nz[1], nz[2])
			_exert(0.03)
		_:
			if not heat_logic.locked():
				_feel.early_cue()
	_sync_heat()


func _heat_tick(delta: float, worked: bool, work_radius: float) -> void:
	var ev := heat_logic.tick(delta, worked, _power, work_radius)
	for e in ev:
		_on_heat_event(str(e))
	_sync_heat()


func _on_heat_event(e: String) -> void:
	match e:
		DrillHeat.EV_WINDOW:
			_feel.window_cue()
			if _hint_window < 2 and equipped and Game.hud:
				_hint_window += 1
				Game.hud.show_message("SOĞUTMA PENCERESİ: işaret beyaz bölgeye girince R", 3.0)
		DrillHeat.EV_SWEEP:
			_feel.sweep_cue()
		DrillHeat.EV_OVERHEAT:
			var nz := _nozzle()
			_feel.overheat_fx(nz[0], nz[1], nz[2])
			kick = maxf(kick, 0.5)
			_exert(0.05)
			if _hint_overheat < 2 and Game.hud:
				_hint_overheat += 1
				Game.hud.show_message("MATKAP AŞIRI ISINDI · pencere açılınca R ile zamanında soğut", 3.0)
		DrillHeat.EV_UNLOCK:
			_feel.unlock_fx()
		DrillHeat.EV_SUPER_END:
			_feel.super_end_fx()


func _sync_heat() -> void:
	heat = heat_logic.heat
	heat_max = heat_logic.heat_max
	overheated = heat_logic.locked()


## Dig rate / material cap multiplier now: the tier × SÜPER KAZI.
func _rate_mult() -> float:
	return float(_stats.get("rate", 1.0)) * (Balance.DRILL_SUPER_MULT if heat_logic.super_on() else 1.0)


# =================================================================================================
# Tiers (scripts/items/drill_tiers.gd)
# =================================================================================================

func _apply_tier() -> void:
	tier = DrillTiers.tier()
	_stats = DrillTiers.stats(tier)
	radius_max = float(_stats["radius_max"])
	radius = clampf(radius, RADIUS_MIN, radius_max)
	heat_logic.configure(_stats)
	item_name = "Kazı Aracı" + ("" if tier == 0 else " " + DrillTiers.tier_name(tier))
	_apply_tier_visuals()
	_sync_heat()


func _on_tier_changed(t: int) -> void:
	_apply_tier()
	if t > 0 and equipped:
		kick = maxf(kick, 0.4)


func _apply_tier_visuals() -> void:
	for t in _tier_nodes.size():
		var n = _tier_nodes[t]
		if n != null and is_instance_valid(n):
			(n as Node3D).visible = tier >= t
	if _tip != null:
		_tip.position.z = float(_tip_z[clampi(tier, 0, _tip_z.size() - 1)])
	if _haze_mi != null:
		_haze_mi.position.z = float(_tip_z[clampi(tier, 0, _tip_z.size() - 1)]) - 0.035


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	_empty_msg_t = maxf(_empty_msg_t - delta, 0.0)
	_bodies_t -= delta
	if _bodies_t <= 0.0:
		_bodies_t = 1.0
		_hook_bodies()
	var h := heat_logic
	var hk := h.frac()
	var locked := h.locked()
	var lock_k := clampf(h.lock_t / maxf(h.lock_total, 0.01), 0.0, 1.0)
	var boost := clampf(h.super_t / Balance.DRILL_SUPER_T, 0.0, 1.0)
	var held := equipped and active
	if _feel:
		_feel.drive(delta, {"heat": hk, "working": using, "locked": locked, "lock_kind": h.lock_kind, "lock_k": lock_k,
				"boost": boost, "equipped": held})
	_push_wrist(held)
	if model == null:
		return
	_use_t = move_toward(_use_t, 1.0 if using else 0.0, delta * 6.0)
	var mc := crosshair_color()
	# Coils: the mode colour, heating to orange and white-hot; teal in SÜPER KAZI; a dull red cooling
	# off in a lockout.
	var cc := mc.lerp(HOT_COL, smoothstep(0.2, 0.6, hk)).lerp(WHITE_HOT, smoothstep(0.72, 1.0, hk))
	var ce := 3.0 + _use_t * 3.5 + sin(_t * 3.0) * 0.4 + hk * 3.0
	if boost > 0.0:
		cc = cc.lerp(SUPER_COL, 0.7 + 0.2 * sin(_t * 14.0))
		ce += 2.0
	if locked:
		cc = LOCK_COL
		ce = 1.0 + 4.0 * lock_k * (0.6 + 0.4 * sin(_t * 20.0))
	_heat_glow.set_shader_parameter("color", cc)
	_heat_glow.set_shader_parameter("energy", ce)
	_heat_glow.set_shader_parameter("flicker", _use_t * 0.35 + smoothstep(0.85, 1.0, hk) * 0.4)
	_glow.set_shader_parameter("color", mc)
	var ec := mc.lerp(SUPER_COL, 0.6) if boost > 0.0 else mc
	_emitter.set_shader_parameter("color", ec if not locked else mc.darkened(0.6))
	_emitter.set_shader_parameter("energy", (5.0 + _use_t * 9.0 * randf_range(0.6, 1.0)) * (0.3 if locked else 1.0))
	# Side vents / heat sinks: dark when cool, orange → white-hot.
	var vh := maxf(smoothstep(0.3, 1.0, hk), lock_k if h.lock_kind == DrillHeat.LOCK_OVERHEAT else 0.0)
	_vent_glow.set_shader_parameter("color", HOT_COL.lerp(WHITE_HOT, smoothstep(0.75, 1.0, hk)))
	_vent_glow.set_shader_parameter("energy", 0.08 + 5.0 * vh * (0.85 + 0.15 * sin(_t * 9.0)))
	# The gauge.
	_gauge.set_shader_parameter("base_col", mc)
	_gauge.set_shader_parameter("heat", hk)
	_gauge.set_shader_parameter("window_on", 1.0 if h.window else 0.0)
	_gauge.set_shader_parameter("marker", h.marker)
	_gauge.set_shader_parameter("good", h.good)
	_gauge.set_shader_parameter("sweet", h.sweet)
	_gauge.set_shader_parameter("lock_on", 1.0 if locked else 0.0)
	_gauge.set_shader_parameter("boost", boost)
	_gauge.set_shader_parameter("flash", h.vent_flash * h.vent_flash)
	_gauge.set_shader_parameter("flash_col", Color.WHITE if h.last_vent == DrillHeat.PERFECT
			else (Color(1.0, 0.7, 0.3) if h.last_vent == DrillHeat.GOOD else LOCK_COL))
	# Heat shimmer.
	var hz := maxf(smoothstep(0.35, 1.0, hk), lock_k * 0.8 if h.lock_kind == DrillHeat.LOCK_OVERHEAT else 0.0)
	_haze_mi.visible = hz > 0.02 and held
	_haze.set_shader_parameter("heat", hz)
	for i in _coils.size():
		var s := 1.0 + _use_t * 0.14 * sin(_t * 32.0 - i * 1.7)
		(_coils[i] as Node3D).scale = Vector3(s, 1.0, s)
	if _bit != null:
		var want := 4.0 + _power * 30.0 + (90.0 if _bore_t >= 0.0 else _bore_charge * 160.0)
		_bit_spin = lerpf(_bit_spin, want, 1.0 - exp(-6.0 * delta))
		_bit.rotation.z = fmod(_bit.rotation.z + _bit_spin * delta, TAU)
	var frac := clampf(Game.material / FILL_DISPLAY, 0.0, 1.0)
	_soil_fill.get_parent().scale = Vector3(1, 1, maxf(frac, 0.02))
	if held and _feel:
		var nz := _nozzle()
		_feel.steam_at(nz[0], nz[1], nz[2])


func _physics_process(delta: float) -> void:
	using = false
	aim_valid = false
	var r := _drill_frame(delta)
	_heat_tick(delta, r >= 0.0, r if r >= 0.0 else radius)


## The drill's frame: aim, preview, the burst bore, the brush. Returns the radius it worked with
## (-1: it did not work).
func _drill_frame(delta: float) -> float:
	if not can_operate():
		fx.show_preview(false)
		_power = move_toward(_power, 0.0, delta * 4.0)
		_bore_charge = 0.0
		_was_pressing = false
		if _bore_t >= 0.0:
			_bore_t = -1.0
		return -1.0
	var cam := get_parent() as Camera3D
	var from: Vector3 = player.aim_origin()
	var dir := -cam.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * RANGE, Game.LAYER_TERRAIN)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var up: Vector3 = player.global_transform.basis.y
	if _bore_t >= 0.0:
		_bore_step(delta, cam, from, dir, up)
		return Balance.DRILL_BORE_RADIUS
	if hit.is_empty():
		fx.show_preview(false)
		_power = move_toward(_power, 0.0, delta * 4.0)
		_bore_charge = 0.0
		return -1.0
	aim_valid = true
	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var m: int = mode
	var primary := Input.is_action_pressed("tool_use")
	var secondary := Input.is_action_pressed("tool_alt")
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var pressing := (primary or secondary) and captured
	var fresh := pressing and not _was_pressing
	_was_pressing = pressing
	if pressing and secondary and not primary:
		if mode == Mode.DIG:
			m = Mode.RAISE
		elif mode == Mode.RAISE:
			m = Mode.DIG
	work_mode = m
	var locked := heat_logic.locked()
	var pcol: Color = MODE_COLORS[m] if not locked else Color(0.55, 0.35, 0.32)
	fx.show_preview(true, point, radius, pcol, m == Mode.FLATTEN, player.global_position, up, normal, m)
	# Mk IV burst bore: hold E.
	if bool(_stats.get("bore", false)) and captured and not locked and Input.is_physical_key_pressed(KEY_E):
		_bore_cd = maxf(_bore_cd - delta, 0.0)
		if _bore_cd <= 0.0:
			_bore_charge += delta
			_power = move_toward(_power, 1.0, delta * 4.0)
			_shake(0.12 + 0.2 * clampf(_bore_charge / Balance.DRILL_BORE_CHARGE, 0.0, 1.0))
			if _bore_charge >= Balance.DRILL_BORE_CHARGE:
				_start_bore(point, dir, cam, from, up)
				return Balance.DRILL_BORE_RADIUS
		return -1.0
	_bore_charge = 0.0
	_bore_cd = maxf(_bore_cd - delta, 0.0)
	# The emitter spins up: ~0.4 s to full strength, drops quickly when released. A tap still bites.
	_power = move_toward(_power, 1.0 if (pressing and not locked) else 0.0, delta * (2.5 if pressing else 4.0))
	if not pressing:
		return -1.0
	if locked:
		if fresh:
			_feel.play("foley/dry", -12.0, 0.9)          # the trigger clicks on a locked drill
		return -1.0
	if m != Mode.DIG and Game.material <= 0.01:
		# Raising / flattening places soil: nothing to place without material.
		if _empty_msg_t <= 0.0:
			_empty_msg_t = 2.5
			if Game.hud:
				Game.hud.show_message("Malzeme yok — önce kaz", 2.0)
			if Game.sfx:
				Game.sfx.play("error", -12.0)
		return -1.0
	var mult := _rate_mult()
	var rate := RATE * mult * (0.35 + 0.65 * _power)
	var body: Node3D = Game.dominant_body(point)
	var soil := Dig.dig_at(body, point, radius, m, rate * delta, player.global_position, up,
			-1.0 if m == Mode.DIG else Game.material, "home")
	# Dug soil becomes material at most DRILL_MAX_RATE × tier × SÜPER m³/s (a bigger brush digs more,
	# not faster); placed soil is always paid in full. Rich veins multiply AFTER the cap. The soil comes
	# off in whole-voxel lumps (~1 m³ on some frames, nothing on others) while the cap is a fraction of
	# that per frame, so it is banked (at most DRILL_BANK_TIME s of the cap) and paid out at the cap
	# rate: DRILL_MAX_RATE is the real m³/s (2026-10-06 economy pass, probe: the old per-frame
	# min(soil, cap) paid ~5-9 m³/s of a 30 cap with the 2.2 m brush, ~27 with a 5 m one).
	var cap := Balance.DRILL_MAX_RATE * mult
	var credit := soil if soil < 0.0 else 0.0
	if soil > 0.0:
		_soil_bank = minf(_soil_bank + soil, cap * Balance.DRILL_BANK_TIME)
	if soil >= 0.0 and _soil_bank > 0.0:
		var pay := minf(_soil_bank, cap * delta)
		_soil_bank -= pay
		credit = pay * _vein_mult(body, point)
	Game.add_material(credit)
	if credit > 0.0:
		_feel.credit(credit, delta)
	# The rival's core (when you reach it) takes drill damage.
	Core.drill_all(get_tree(), point, radius, "home", delta)
	using = true
	var boosted := heat_logic.super_on()
	var tp: Array = _tip_world(cam, from, dir)
	var soil_col := _soil_color(body)
	var bcol: Color = MODE_COLORS[m].lerp(SUPER_COL, 0.55) if boosted else MODE_COLORS[m]
	fx.work(tp[0], tp[1], point, normal, up, m, radius, bcol, soil_col)
	if m == Mode.DIG and soil > 0.0:
		fx.kick_back(point, cam.global_position, up, soil_col, _power * (1.5 if boosted else 1.0))
		_feel.bite(delta, _depth_k(point), _hardness(body), _power, boosted)
	_shake(Balance.DRILL_SHAKE * _power * (1.3 if boosted else 1.0))
	return radius


## [position, direction] of the nozzle in world space (where the beam starts).
func _tip_world(cam: Camera3D, from: Vector3, dir: Vector3) -> Array:
	fx.tip_node = _tip
	fx.tip_is_vm = true
	if _tip == null:
		return [from, dir]
	var tip_pos := VM.vm_to_world(cam, _tip.global_position)
	var tip_dir := (VM.vm_to_world(cam, _tip.global_position - _tip.global_transform.basis.z) - tip_pos).normalized()
	return [tip_pos, tip_dir]


## [position, aim, up] of the nozzle in world space (steam, vent puffs), safe without a camera.
func _nozzle() -> Array:
	var cam := get_parent() as Camera3D
	var up := Vector3.UP
	if player != null and is_instance_valid(player):
		up = (player as Node3D).global_transform.basis.y
	if cam == null or not cam.is_inside_tree():
		return [global_position, -global_transform.basis.z, up]
	var tp := _tip_world(cam, cam.global_position, -cam.global_transform.basis.z)
	return [tp[0], tp[1], up]


# =================================================================================================
# Burst bore (Mk IV)
# =================================================================================================

func _start_bore(point: Vector3, dir: Vector3, cam: Camera3D, from: Vector3, up: Vector3) -> void:
	_bore_charge = 0.0
	_bore_t = 0.0
	_bore_dir = dir.normalized()
	_bore_from = point - _bore_dir * 0.25
	_bore_body = Game.dominant_body(point)
	_bore_done = 0.0
	# Never more than the drill's own rate cap over one bore cycle (Balance "Drill heat and upgrades").
	_bore_budget = Balance.DRILL_MAX_RATE * _rate_mult() \
			* (Balance.DRILL_BORE_CHARGE + Balance.DRILL_BORE_T + Balance.DRILL_BORE_COOLDOWN)
	kick = maxf(kick, 0.6)
	_exert(0.04)
	_bore_carve(0.0, up)
	_feel.play("bimp/rock", -6.0, 0.6)
	_feel.play("foley/clunk", -8.0, 0.55)
	if Game.sfx:
		Game.sfx.play("impact", -9.0, 0.6)
		Game.sfx.play("explosion_crunch", -14.0, 1.1)
	_bore_step(0.0, cam, from, dir, up)


func _bore_step(delta: float, cam: Camera3D, from: Vector3, dir: Vector3, up: Vector3) -> void:
	_bore_t += delta
	var k := clampf(_bore_t / Balance.DRILL_BORE_T, 0.0, 1.0)
	var e := 1.0 - pow(1.0 - k, 1.6)                       # hits hard, slows as it goes
	var dist := Balance.DRILL_BORE_LEN * e
	var got := 0.0
	while _bore_done + Balance.DRILL_BORE_STEP <= dist + 0.001:
		_bore_done += Balance.DRILL_BORE_STEP
		got += _bore_carve(_bore_done, up)
	if got > 0.0:
		_feel.credit(got, delta)
	_power = 1.0
	using = true
	var head := _bore_from + _bore_dir * maxf(dist, 0.3)
	var tp: Array = _tip_world(cam, from, dir)
	var soil_col := _soil_color(_bore_body)
	fx.work(tp[0], tp[1], head, -_bore_dir, up, Mode.DIG, Balance.DRILL_BORE_RADIUS, MODE_COLORS[0].lerp(WHITE_HOT, 0.35), soil_col)
	fx.kick_back(_bore_from, cam.global_position, up, soil_col, 2.5)
	_feel.bite(delta, _depth_k(head), 1.0, 1.0, true)
	_shake(0.5)
	if k >= 1.0:
		_bore_t = -1.0
		_bore_cd = Balance.DRILL_BORE_COOLDOWN
		if heat_logic.add_heat(Balance.DRILL_BORE_HEAT):
			_on_heat_event(DrillHeat.EV_OVERHEAT)
		_sync_heat()


## One brush of the tunnel at `s` m along the bore; returns the material credited.
func _bore_carve(s: float, up: Vector3) -> float:
	if _bore_body == null or not is_instance_valid(_bore_body):
		return 0.0
	var c := _bore_from + _bore_dir * s
	var soil := Dig.dig_at(_bore_body, c, Balance.DRILL_BORE_RADIUS, Dig.MODE_DIG, 16.0,
			player.global_position if player != null else c, up, -1.0, "home")
	Core.drill_all(get_tree(), c, Balance.DRILL_BORE_RADIUS, "home",
			Balance.DRILL_BORE_T * Balance.DRILL_BORE_STEP / Balance.DRILL_BORE_LEN)
	if soil <= 0.0 or _bore_budget <= 0.0:
		return 0.0
	var base := minf(soil * Balance.DRILL_BORE_CREDIT, _bore_budget)
	_bore_budget -= base
	var credit := base * _vein_mult(_bore_body, c)
	Game.add_material(credit)
	return credit


# =================================================================================================
# Auto-collect (Mk III+)
# =================================================================================================

## Connects to every planet's crater_done (new ones too: checked every second).
func _hook_bodies() -> void:
	for b in Bodies.all():
		if b != null and is_instance_valid(b) and (b as Object).has_signal("crater_done") \
				and not (b as Object).is_connected("crater_done", _on_crater_done):
			(b as Object).connect("crater_done", _on_crater_done)


## A crater finished somewhere: Mk III+ credits a share of its soil when it was near the player.
func _on_crater_done(center: Vector3, r: float, soil: float) -> void:
	var share := float(_stats.get("auto_share", 0.0))
	if share <= 0.0 or soil <= 0.0 or player == null or not is_instance_valid(player):
		return
	if (player.has_method("is_dead") and player.is_dead()) or player.get("vehicle") != null:
		return
	var reach := maxf(float(_stats.get("auto_radius", 0.0)), 1.0)
	var d := (player as Node3D).global_position.distance_to(center) - r
	if d > reach:
		return
	var got := minf(soil * share * lerpf(1.0, 0.5, clampf(d / reach, 0.0, 1.0)), Balance.DRILL_AUTO_MAX)
	# Co-op shared pool: both machines see the same crater, so when the teammate stands in reach too
	# each credits half (the pool never gets the same soil twice).
	if Game.shared_pool:
		for av in get_tree().get_nodes_in_group("net_player"):
			if av is Node3D and is_instance_valid(av) \
					and (av as Node3D).global_position.distance_to(center) - r <= reach:
				got *= 0.5
				break
	if got < 0.5:
		return
	Game.add_material(got)
	if _feel:
		_feel.collect_fx(got)


# =================================================================================================
# Helpers
# =================================================================================================

## Rich-vein multiplier at a dug point (scripts/planet/veins.gd mult_at, looked up once; 1 without it).
func _vein_mult(body: Node3D, point: Vector3) -> float:
	if _veins_state == 0:
		_veins_state = 1
		if ResourceLoader.exists(VEINS_PATH):
			var s = load(VEINS_PATH)
			if s is Script and (s as Script).can_instantiate():
				for md in (s as Script).get_script_method_list():
					if str(md.get("name", "")) == "mult_at":
						_veins_script = s
						_veins_state = 2
						break
	if _veins_state != 2 or body == null:
		return 1.0
	return maxf(float(_veins_script.call("mult_at", body, point)), 0.0)


func _soil_color(body: Node3D) -> Color:
	return body.get("soil_color") if body != null and body.get("soil_color") != null else Color(0.45, 0.35, 0.24)


## 0 at the surface .. 1 twelve metres below the planet's base radius (the bite gets harder, lower).
func _depth_k(point: Vector3) -> float:
	return clampf(-Game.altitude(point) / 12.0, 0.0, 1.0)


## 0 soil .. 0.6 a rocky planet (bodies.gd cfg "step": "step_rock").
func _hardness(body: Node3D) -> float:
	if body != null and body.get("cfg") is Dictionary and str((body.cfg as Dictionary).get("step", "")) == "step_rock":
		return 0.6
	return 0.0


## Holds the camera trauma (player.gd add_trauma) at least at `target` (a faint shake while boring).
func _shake(target: float) -> void:
	if player == null or not is_instance_valid(player) or not player.has_method("add_trauma"):
		return
	var cur = player.get("_trauma")
	var c := float(cur) if cur != null else 0.0
	if c < target:
		player.add_trauma(target - c)


## A little suit exertion (helmet_fx.gd: the breathing) for a strain: a jam, an overheat, a bore.
func _exert(amount: float) -> void:
	if not ResourceLoader.exists(HELMET_PATH):
		return
	var hs = load(HELMET_PATH)
	if hs == null:
		return
	var h = hs.call("peek")
	if h != null and is_instance_valid(h) and h.get("exertion") != null:
		h.exertion = minf(float(h.exertion) + amount, 1.0)


func _on_pop(text: String, col: Color) -> void:
	var w = _wrist()
	if w != null and w.has_method("drill_pop"):
		w.drill_pop(text, col)


## The player's wrist screen (scripts/player/wrist_display.gd, group "wrist_display"), cached.
func _wrist() -> Node:
	if _wrist_node != null and is_instance_valid(_wrist_node):
		return _wrist_node
	_wrist_node = null
	if player == null or not is_instance_valid(player) or not is_inside_tree():
		return null
	for n in get_tree().get_nodes_in_group("wrist_display"):
		if (player as Node).is_ancestor_of(n):
			_wrist_node = n
			break
	return _wrist_node


func _push_wrist(on: bool) -> void:
	var w = _wrist()
	if w == null or not w.has_method("set_drill"):
		return
	if not on:
		if _wrist_was_on:
			_wrist_was_on = false
			w.set_drill({"on": false})
		return
	_wrist_was_on = true
	var d := heat_info()
	d["on"] = true
	w.set_drill(d)
