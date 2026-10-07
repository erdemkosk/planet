extends Node3D
## Sondaj Kulesi (drilling rig): how the player's drilling torpedo gets into the enemy planet now.
## Built with the İnşa Aracı on the ENEMY planet only (Balance.BUILD_SITE "enemy",
## TORPEDO_RIG_COST = the old launcher's craft price + one torpedo). One torpedo per rig.
##
## Model (local frame, +Y up, +Z toward whoever built it): a steel tripod derrick on hydraulic feet
## (white / orange; the rival's gunmetal / red) with two rings of braces, a crown block with a
## sheave and a beacon at the apex; a diesel-electric winch skid behind (housing, radiator grille,
## spinning cooling fan, exhaust stack, winch drum, status lamps); the hoist cable over the sheave
## down to the torpedo, which hangs nose-down through a guide collar over a hazard-striped bore
## frame; power cables along the ground; two work lights on the rear legs aimed at the bore; a
## small holo status screen on the front leg.
##
## Life: the parts drop into place (begin_assembly, ~1.6 s), then it ARMS for
## Balance.TORPEDO_RIG_ARM_TIME s: the winch spools up and lowers the torpedo, the drill spins up,
## at the ground sparks, dust and a grinding rumble (camera shake nearby). At the end the model
## torpedo is swapped for the real one: Torpedo.plant() at the ground under the bore pointing at the
## planet's centre (PLANT -> BURROW of scripts/war/torpedo.gd, its own hp and interception). The
## screen then follows it (depth, distance to the core) and shows how it ended. The rig stays as a
## structure; destroyed while arming, no torpedo.
##
## Groups "damageable", "war_structure", "war_torpedo_rig". take_damage(amount, from, impulse) ->
## {"dmg", "killed"}; is_arming() (the AI sends more bots at an arming rig). Structure contract like
## the armory (team, body, hp, hp_max, is_destroyed, begin_assembly(), _destroy(), static
## footprint()).
##   TorpedoRig.spawn(parent, body, xf, team, animate := true) -> rig
## Multiplayer (scripts/net/net_world.gd, a structure by script path): only the HOST (or single
## player) arms it and plants the torpedo (Torpedo.plant emits Torpedo.events().launched: the
## client gets a puppet). `charge` (arming 0..1, 1 = planted) rides the structure state's charge
## byte, so the client's copy shows the host's progress and swaps its model torpedo at 1.

const Balance := preload("res://scripts/war/balance.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const Torpedo := preload("res://scripts/war/torpedo.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const Foundation := preload("res://scripts/war/foundation.gd")

const GROUP := "war_torpedo_rig"
const APEX := Vector3(0.0, 3.35, 0.0)
const FOOT_R := 1.6                    # m from the bore to each foot
const HANG := 0.6                      # m the torpedo's tip hangs above the ground before arming
const COLLAR_Y := 0.48
const MOTOR := Vector3(0.0, 0.0, -1.38)
const AMBER := Color(1.0, 0.62, 0.2)
const SPOT_COL := Color(1.0, 0.93, 0.8)

signal destroyed(rig: Node3D)

var team := "home"
var body: Node3D
var hp := Balance.TORPEDO_RIG_HP
var hp_max := Balance.TORPEDO_RIG_HP
var is_destroyed := false
var charge := 0.0                      # arming 0..1 (1 = the torpedo is in the ground); host -> client
var torpedo = null                     # the planted torpedo (untyped: it frees itself when done)
# Read by the multiplayer structure sync like any structure's (unused here).
var _yaw_t := 0.0
var _pitch_t := 0.0
var tracking := false

var _hit_t := 0.0
var _t := 0.0
var _build_t := -1.0
var _parts: Array = []                 # [node, rest transform, delay]
var _launched := false
var _result := ""                      # how the torpedo ended (screen)
var _k := 0.0                          # shown arming progress (smoothed on a client)
var _ground_y := 0.0                   # ground height under the bore (local y)
var _bore := Vector3.ZERO              # world point the torpedo went in
var _since_launch := 0.0
var _spin := 0.0
var _fan_spin := 0.0
var _hook_y := 0.0
var _rumble_t := 0.0
var _find_t := 0.0
var _scan_t := 0.0
var _ground_check := false
var _foundation: Node3D               # piles under the feet down to the real ground (foundation.gd)
var _started_fx := false
var _col_team := Color(0.35, 0.88, 1.0)

var _paint: StandardMaterial3D
var _glow: StandardMaterial3D
var _band_mat: StandardMaterial3D
var _collar_mat: StandardMaterial3D
var _beacon_mat: StandardMaterial3D
var _lens_mat: StandardMaterial3D
var _lamp_mats: Array = []             # status lamps on the winch housing
var _torp: Node3D                      # the model torpedo (origin = its drill tip, body up +Y)
var _drill: Node3D
var _cable: MeshInstance3D
var _hook: Node3D
var _fan: Node3D
var _drum: Node3D
var _spots: Array = []
var _beacon: OmniLight3D
var _spark_light: OmniLight3D
var _sparks: GPUParticles3D
var _dust: CPUParticles3D
var _smoke: CPUParticles3D
var _screen: Label3D
var _hum: AudioStreamPlayer3D
var _grind: AudioStreamPlayer3D
var _torp_cs: CollisionShape3D


static func spawn(parent: Node, p_body: Node3D, xf: Transform3D, p_team: String, animate := true) -> Node3D:
	var r: Node3D = load("res://scripts/war/torpedo_rig.gd").new()
	r.team = p_team
	r.body = p_body
	r.name = "TorpedoRig_" + p_team
	r.transform = xf
	parent.add_child(r)
	if animate:
		r.begin_assembly()
	return r


## Half extents of the placement box (net_world's build check reads its radius from this).
static func footprint() -> Vector3:
	return Vector3(Balance.TORPEDO_RIG_FOOTPRINT, 1.7, Balance.TORPEDO_RIG_FOOTPRINT)


func _ready() -> void:
	_col_team = Color(0.35, 0.88, 1.0) if team == "home" else Color(1.0, 0.28, 0.14)
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_structure")
	add_to_group(GROUP)
	set_meta("footprint_r", Balance.TORPEDO_RIG_FOOTPRINT)
	var preview := has_meta("build_preview")
	if not preview:
		# The ground under the bore (the origin is the lowest footprint sample: it may sit higher).
		# (build_tool.gd STEP_TOL lets the footprint vary up to 2.2 m.)
		_ground_y = clampf((_ground_point() - global_position).dot(global_transform.basis.y.normalized()),
				-0.4, 2.4)
	_build_model()
	_build_fx()
	_build_audio()
	_place_torpedo(HANG)
	if preview:
		return
	if body != null:
		_foundation = Foundation.create(self, body, PackedVector3Array(), _foot_piles(), Color.GRAY)
		_parts.append([_foundation, _foundation.transform, 0.15])
	if body != null and body.has_signal("brush_applied"):
		body.brush_applied.connect(_on_brush)


# =================================================================================================
# Model
# =================================================================================================

func _mat(c: Color, metal: float, rough: float, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	return m


func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, pos: Vector3, r_top: float, r_bot: float, h: float, mat: Material, rot := Vector3.ZERO, seg := 16) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


## Basis whose y runs from a to b (for tubes and their collision).
static func _seg_basis(a: Vector3, b: Vector3) -> Basis:
	var y := (b - a).normalized()
	var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


## A tube from a to b.
func _seg(parent: Node3D, a: Vector3, b: Vector3, r: float, mat: Material, seg := 10) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = maxf(a.distance_to(b), 0.01)
	c.radial_segments = seg
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.transform = Transform3D(_seg_basis(a, b), (a + b) * 0.5)
	parent.add_child(mi)
	return mi


## A cable through the points (straight runs between them).
func _cable_path(parent: Node3D, pts: Array, r: float, mat: Material) -> void:
	for i in pts.size() - 1:
		_seg(parent, pts[i], pts[i + 1], r, mat, 6)


func _part(delay: float, pos := Vector3.ZERO) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	add_child(n)
	_parts.append([n, n.transform, delay])
	return n


func _foot(i: int) -> Vector3:
	var a := PI * 0.5 + TAU * float(i) / 3.0
	return Vector3(cos(a), 0.0, sin(a)) * FOOT_R


## Leg i: from the top of its jack to just under the crown block.
func _leg_ends(i: int) -> Array:
	var f := _foot(i)
	return [f + Vector3(0, 0.36, 0), APEX + f.normalized() * 0.16 + Vector3(0, -0.12, 0)]


## The point on leg i at height y.
func _leg_at(i: int, y: float) -> Vector3:
	var e := _leg_ends(i)
	var a: Vector3 = e[0]
	var b: Vector3 = e[1]
	return a.lerp(b, clampf((y - a.y) / maxf(b.y - a.y, 0.01), 0.0, 1.0))


func _build_model() -> void:
	var home := team == "home"
	_paint = _mat(Color(0.86, 0.87, 0.86) if home else Color(0.22, 0.21, 0.21), 0.1 if home else 0.5, 0.45)
	var stripe := _mat(Color(0.95, 0.42, 0.08) if home else Color(0.72, 0.12, 0.08), 0.0, 0.5)
	var dark := _mat(Color(0.14, 0.15, 0.17), 0.6, 0.42)
	var gun := _mat(Color(0.09, 0.095, 0.105), 0.75, 0.34)
	var steel := _mat(Color(0.6, 0.62, 0.66), 0.88, 0.28)
	var worn := _mat(Color(0.42, 0.4, 0.37), 0.55, 0.62)
	var rubber := _mat(Color(0.05, 0.05, 0.055), 0.0, 0.85)
	var yellow := _mat(Color(0.95, 0.75, 0.12), 0.0, 0.55)
	var black := _mat(Color(0.04, 0.04, 0.045), 0.2, 0.7)
	_glow = _mat(_col_team, 0.0, 0.4, 2.5)
	_collar_mat = _mat(AMBER, 0.0, 0.35, 0.6)
	_beacon_mat = _mat(AMBER, 0.0, 0.4, 0.6)
	_lens_mat = _mat(SPOT_COL, 0.0, 0.3, 0.8)

	# --- Bore frame: a striped steel square around the hole, on the ground under the crown.
	var frame := _part(0.0, Vector3(0, _ground_y, 0))
	for c in [[Vector3(0, 0.03, 0.36), Vector3(0.94, 0.06, 0.22)], [Vector3(0, 0.03, -0.36), Vector3(0.94, 0.06, 0.22)],
			[Vector3(0.36, 0.03, 0), Vector3(0.22, 0.06, 0.5)], [Vector3(-0.36, 0.03, 0), Vector3(0.22, 0.06, 0.5)]]:
		_box(frame, c[0], c[1], worn)
	for i in 8:
		var a := TAU * float(i) / 8.0
		var p := Vector3(cos(a), 0.0, sin(a)) * 0.36
		_box(frame, p + Vector3(0, 0.065, 0), Vector3(0.1, 0.012, 0.14), yellow if i % 2 == 0 else black, Vector3(0, -a, 0))
	# --- Legs with hydraulic feet.
	var legs := _part(0.15)
	for i in 3:
		var f := _foot(i)
		var e := _leg_ends(i)
		_box(legs, f + Vector3(0, 0.035, 0), Vector3(0.56, 0.07, 0.56), worn, Vector3(0, -(PI * 0.5 + TAU * float(i) / 3.0), 0))
		_box(legs, f + Vector3(0, 0.08, 0), Vector3(0.42, 0.03, 0.42), dark, Vector3(0, -(PI * 0.5 + TAU * float(i) / 3.0), 0))
		_cyl(legs, f + Vector3(0, 0.2, 0), 0.085, 0.1, 0.26, gun)
		_cyl(legs, f + Vector3(0, 0.36, 0), 0.06, 0.06, 0.1, steel)
		_seg(legs, e[0], e[1], 0.065, _paint, 12)
		_seg(legs, _leg_at(i, 0.5), _leg_at(i, 0.72), 0.072, stripe, 12)
		_seg(legs, _leg_at(i, 2.5), _leg_at(i, 2.62), 0.072, stripe, 12)
	# --- Braces: two rings, X bracing between them.
	var braces := _part(0.35)
	for i in 3:
		var j := (i + 1) % 3
		for y in [1.15, 2.2]:
			_seg(braces, _leg_at(i, y), _leg_at(j, y), 0.03, steel, 8)
		_seg(braces, _leg_at(i, 1.15), _leg_at(j, 2.2), 0.018, dark, 6)
		_seg(braces, _leg_at(i, 2.2), _leg_at(j, 1.15), 0.018, dark, 6)
	# Guide collar and its spider arms (holds the torpedo square over the bore).
	var tm := TorusMesh.new()
	tm.inner_radius = 0.12
	tm.outer_radius = 0.2
	tm.rings = 24
	tm.ring_segments = 8
	var cy := _ground_y + COLLAR_Y
	var collar := MeshInstance3D.new()
	collar.mesh = tm
	collar.material_override = gun
	collar.position = Vector3(0, cy, 0)
	braces.add_child(collar)
	var tg := TorusMesh.new()
	tg.inner_radius = 0.19
	tg.outer_radius = 0.215
	tg.rings = 24
	tg.ring_segments = 6
	var glow_ring := MeshInstance3D.new()
	glow_ring.mesh = tg
	glow_ring.material_override = _collar_mat
	glow_ring.position = Vector3(0, cy + 0.03, 0)
	braces.add_child(glow_ring)
	for i in 3:
		var d := _foot(i).normalized()
		_seg(braces, d * 0.2 + Vector3(0, cy, 0), _leg_at(i, maxf(cy, 0.5) + 0.1) - d * 0.05, 0.022, dark, 6)
	# --- Crown block, sheave, beacon.
	var crown := _part(0.55)
	_box(crown, APEX + Vector3(0, 0.04, 0), Vector3(0.56, 0.34, 0.56), dark)
	_box(crown, APEX + Vector3(0, 0.24, 0), Vector3(0.62, 0.06, 0.62), stripe)
	for sx in [-1.0, 1.0]:
		_box(crown, APEX + Vector3(sx * 0.1, -0.2, 0), Vector3(0.03, 0.2, 0.38), dark)
	_cyl(crown, APEX + Vector3(0, -0.2, -0.02), 0.17, 0.17, 0.06, steel, Vector3(0, 0, PI * 0.5), 20)
	_cyl(crown, APEX + Vector3(0, -0.2, -0.02), 0.04, 0.04, 0.24, gun, Vector3(0, 0, PI * 0.5), 10)
	_cyl(crown, APEX + Vector3(0, 0.33, 0), 0.07, 0.09, 0.08, gun)
	_cyl(crown, APEX + Vector3(0, 0.42, 0), 0.06, 0.07, 0.11, _beacon_mat)
	_cyl(crown, APEX + Vector3(0.2, 0.55, -0.18), 0.012, 0.018, 0.55, steel)          # antenna
	# --- Winch skid behind: housing, radiator, fan, exhaust, drum, lamps.
	var winch := _part(0.75)
	var m := MOTOR
	_box(winch, m + Vector3(0, 0.06, 0), Vector3(1.32, 0.12, 0.86), dark)
	for sx in [-1.0, 1.0]:
		_box(winch, m + Vector3(sx * 0.6, 0.05, 0), Vector3(0.1, 0.1, 0.9), steel)
	_box(winch, m + Vector3(0, 0.46, 0), Vector3(1.06, 0.66, 0.7), _paint)
	_box(winch, m + Vector3(0, 0.66, 0), Vector3(1.08, 0.08, 0.72), stripe)
	_box(winch, m + Vector3(0, 0.81, 0), Vector3(1.0, 0.04, 0.64), dark)
	_box(winch, m + Vector3(0, 0.44, -0.355), Vector3(0.82, 0.44, 0.02), gun)
	for k in 8:
		_box(winch, m + Vector3(-0.35 + k * 0.1, 0.44, -0.37), Vector3(0.025, 0.4, 0.02), steel)
	_cyl(winch, m + Vector3(0.55, 0.45, 0), 0.23, 0.23, 0.07, gun, Vector3(0, 0, PI * 0.5), 20)
	_fan = Node3D.new()
	_fan.position = m + Vector3(0.6, 0.45, 0)
	winch.add_child(_fan)
	for k in 4:
		_box(_fan, Vector3.ZERO, Vector3(0.015, 0.36, 0.06), worn, Vector3(TAU * float(k) / 8.0, 0, 0))
	_cyl(_fan, Vector3.ZERO, 0.05, 0.05, 0.04, dark, Vector3(0, 0, PI * 0.5), 10)
	_cyl(winch, m + Vector3(-0.38, 1.1, -0.18), 0.045, 0.045, 0.62, steel)
	_cyl(winch, m + Vector3(-0.38, 1.43, -0.18), 0.065, 0.05, 0.06, gun)
	for sx in [-1.0, 1.0]:
		_box(winch, m + Vector3(sx * 0.27, 0.92, 0.1), Vector3(0.06, 0.2, 0.12), dark)
	_drum = Node3D.new()
	_drum.position = m + Vector3(0, 1.03, 0.1)
	winch.add_child(_drum)
	_cyl(_drum, Vector3.ZERO, 0.14, 0.14, 0.48, stripe, Vector3(0, 0, PI * 0.5), 16)
	for sx in [-1.0, 1.0]:
		_cyl(_drum, Vector3(sx * 0.25, 0, 0), 0.19, 0.19, 0.03, dark, Vector3(0, 0, PI * 0.5), 16)
	_box(_drum, Vector3(0, 0.14, 0), Vector3(0.44, 0.012, 0.03), black)                 # a wrap seam (shows the turn)
	for k in 3:
		var lm := _mat([Color(0.3, 1.0, 0.45), AMBER, Color(1.0, 0.3, 0.2)][k], 0.0, 0.4, 0.4)
		_lamp_mats.append(lm)
		_box(winch, m + Vector3(-0.3 + k * 0.12, 0.55, 0.355), Vector3(0.06, 0.04, 0.02), lm)
	# The hoist line: drum -> sheave (static) and sheave -> hook (follows the hook).
	_seg(winch, m + Vector3(0, 1.17, 0.1), APEX + Vector3(0, -0.06, -0.19), 0.012, gun, 6)
	var cm := CylinderMesh.new()
	cm.top_radius = 0.012
	cm.bottom_radius = 0.012
	cm.height = 1.0
	cm.radial_segments = 6
	cm.rings = 1
	_cable = MeshInstance3D.new()
	_cable.mesh = cm
	_cable.material_override = gun
	winch.add_child(_cable)
	_hook = Node3D.new()
	winch.add_child(_hook)
	_box(_hook, Vector3(0, 0.07, 0), Vector3(0.09, 0.1, 0.06), stripe)
	_cyl(_hook, Vector3(0, 0.0, 0), 0.03, 0.03, 0.06, steel, Vector3(PI * 0.5, 0, 0), 8)
	# Power cables along the ground: winch -> bore frame, winch -> front leg -> screen.
	_cable_path(winch, [m + Vector3(0.2, 0.25, 0.36), m + Vector3(0.24, 0.05, 0.62), Vector3(0.3, 0.04, -0.62),
			Vector3(0.36, 0.07, -0.47)], 0.025, rubber)
	var f0 := _foot(0)
	_cable_path(winch, [m + Vector3(-0.45, 0.22, 0.36), m + Vector3(-0.62, 0.04, 0.7), Vector3(-0.95, 0.04, 0.2),
			Vector3(-0.42, 0.04, 1.2), f0 + Vector3(-0.1, 0.05, -0.12), _leg_at(0, 0.9) + Vector3(-0.08, 0, -0.04),
			_leg_at(0, 1.1) + Vector3(-0.08, 0, -0.04)], 0.02, rubber)
	# --- Work lights on the rear legs, aimed at the bore.
	var lights := _part(0.95)
	for i in [1, 2]:
		var p := _leg_at(i, 2.3) - _foot(i).normalized() * 0.12
		var aim := Vector3(0, 0.3, 0)
		var b := Basis.looking_at(aim - p, Vector3.UP)
		var head := Node3D.new()
		head.transform = Transform3D(b, p)
		lights.add_child(head)
		_cyl(head, Vector3(0, 0, 0.02), 0.08, 0.1, 0.16, gun, Vector3(PI * 0.5, 0, 0), 14)
		_cyl(head, Vector3(0, 0, -0.065), 0.075, 0.075, 0.012, _lens_mat, Vector3(PI * 0.5, 0, 0), 14)
		_box(head, Vector3(0, 0, 0.12), Vector3(0.05, 0.05, 0.08), dark)
		var sp := SpotLight3D.new()
		sp.light_color = SPOT_COL
		sp.spot_range = 8.0
		sp.spot_angle = 34.0
		sp.light_energy = 0.0
		sp.shadow_enabled = false
		sp.position = Vector3(0, 0, -0.08)
		head.add_child(sp)
		_spots.append(sp)
	# --- Holo status screen on the front leg.
	var scr := _part(1.1)
	var sp0 := _leg_at(0, 1.25) + Vector3(0, 0, 0.1)
	_box(scr, sp0, Vector3(0.5, 0.34, 0.06), dark)
	_box(scr, sp0 + Vector3(0, -0.2, 0), Vector3(0.52, 0.04, 0.08), stripe)
	var pane_m := StandardMaterial3D.new()
	pane_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pane_m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pane_m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	pane_m.albedo_color = Color(_col_team, 0.3)
	pane_m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pane := _box(scr, sp0 + Vector3(0, 0, 0.032), Vector3(0.44, 0.28, 0.004), pane_m)
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_screen = Label3D.new()
	_screen.text = "SONDAJ KULESİ"
	_screen.font_size = 48
	_screen.pixel_size = 0.0022
	_screen.modulate = _col_team.lightened(0.45)
	_screen.outline_size = 0
	_screen.shaded = false
	_screen.position = sp0 + Vector3(0, 0, 0.036)
	scr.add_child(_screen)
	# --- The model torpedo (hangs from the hook; not a part: it drops with the cable).
	_build_torpedo()
	for mi in find_children("*", "MeshInstance3D", true, false):
		var gi := mi as MeshInstance3D
		if gi.material_override != pane_m and gi.material_override != _collar_mat and gi.material_override != _lens_mat:
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_build_collision()


## Cylinder along -Z (r_front at the -Z end) centred at z (torpedo.gd's layout).
func _zcyl(parent: Node3D, z: float, r_front: float, r_back: float, h: float, mat: Material, seg := 18) -> MeshInstance3D:
	return _cyl(parent, Vector3(0, 0, z), r_front, r_back, h, mat, Vector3(-PI * 0.5, 0, 0), seg)


## The torpedo as torpedo.gd draws it (same sizes and paint), nose down: _torp's origin is its drill
## tip, the body runs up +Y; a lifting eye on the tail for the hook.
func _build_torpedo() -> void:
	var home := team == "home"
	var paint := _mat(Color(0.86, 0.87, 0.88) if home else Color(0.2, 0.19, 0.19), 0.25 if home else 0.55, 0.42)
	var stripe := _mat(Color(0.95, 0.45, 0.1) if home else Color(0.72, 0.12, 0.08), 0.1, 0.5)
	var steel := _mat(Color(0.62, 0.64, 0.68), 0.92, 0.24)
	steel.cull_mode = BaseMaterial3D.CULL_DISABLED
	var carbide := _mat(Color(0.14, 0.14, 0.15), 0.75, 0.32)
	var dark := _mat(Color(0.07, 0.07, 0.08), 0.6, 0.5)
	_band_mat = StandardMaterial3D.new()
	_band_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_band_mat.albedo_color = _col_team * 2.2
	_torp = Node3D.new()
	add_child(_torp)
	var mdl := Node3D.new()
	mdl.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, Torpedo.HALF, 0))   # model -Z -> -Y
	_torp.add_child(mdl)
	var rr := Torpedo.RADIUS
	_drill = Node3D.new()
	mdl.add_child(_drill)
	var dm := MeshInstance3D.new()
	dm.mesh = Torpedo.drill_mesh(0.355, rr * 1.06)
	dm.material_override = steel
	dm.position = Vector3(0, 0, -0.27)
	_drill.add_child(dm)
	_zcyl(_drill, -0.28, rr * 1.12, rr * 1.08, 0.05, carbide, 20)
	for i in 6:
		var a := TAU * float(i) / 6.0
		_box(_drill, Vector3(cos(a) * rr * 1.1, sin(a) * rr * 1.1, -0.29), Vector3(0.022, 0.03, 0.05), carbide, Vector3(0, 0, a))
	_zcyl(mdl, 0.08, rr, rr, 0.68, paint, 20)
	for z in [-0.18, 0.3]:
		_zcyl(mdl, z, rr * 1.02, rr * 1.02, 0.035, stripe, 20)
	var tm := TorusMesh.new()
	tm.inner_radius = rr * 0.96
	tm.outer_radius = rr * 1.12
	tm.rings = 24
	tm.ring_segments = 6
	var band := MeshInstance3D.new()
	band.mesh = tm
	band.material_override = _band_mat
	band.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, 0, 0.06))
	mdl.add_child(band)
	_zcyl(mdl, 0.49, rr, rr * 0.72, 0.14, dark, 18)
	_zcyl(mdl, 0.585, rr * 0.66, rr * 0.78, 0.05, carbide, 18)
	for i in 4:
		var a := TAU * (float(i) + 0.5) / 4.0
		var fin := Node3D.new()
		fin.rotation.z = a
		mdl.add_child(fin)
		_box(fin, Vector3(0, rr + 0.035, 0.46), Vector3(0.008, 0.075, 0.17), stripe if i % 2 == 0 else paint)
		_box(fin, Vector3(0, rr + 0.07, 0.5), Vector3(0.01, 0.02, 0.06), dark)
	# Lifting eye on the tail.
	_cyl(_torp, Vector3(0, Torpedo.LENGTH + 0.03, 0), 0.03, 0.04, 0.05, dark)
	var eye := TorusMesh.new()
	eye.inner_radius = 0.018
	eye.outer_radius = 0.034
	var em := MeshInstance3D.new()
	em.mesh = eye
	em.material_override = steel
	em.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, Torpedo.LENGTH + 0.08, 0))
	_torp.add_child(em)


## Obstacle on the ship layer (like the other structures): the winch skid, the legs, the crown,
## the hanging torpedo (shooting it hurts the rig).
func _build_collision() -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = Game.LAYER_SHIP
	sb.collision_mask = 0
	var bx := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(1.32, 0.9, 0.86)
	bx.shape = bs
	bx.position = MOTOR + Vector3(0, 0.45, 0)
	sb.add_child(bx)
	var cr := CollisionShape3D.new()
	var cb := BoxShape3D.new()
	cb.size = Vector3(0.6, 0.45, 0.6)
	cr.shape = cb
	cr.position = APEX + Vector3(0, 0.05, 0)
	sb.add_child(cr)
	for i in 3:
		var e := _leg_ends(i)
		var a: Vector3 = e[0]
		var b: Vector3 = e[1]
		var cs := CollisionShape3D.new()
		var cy := CylinderShape3D.new()
		cy.radius = 0.09
		cy.height = a.distance_to(b)
		cs.shape = cy
		cs.transform = Transform3D(_seg_basis(a, b), (a + b) * 0.5)
		sb.add_child(cs)
		var pad := CollisionShape3D.new()
		var pb := BoxShape3D.new()
		pb.size = Vector3(0.5, 0.36, 0.5)
		pad.shape = pb
		pad.position = _foot(i) + Vector3(0, 0.18, 0)
		sb.add_child(pad)
	_torp_cs = CollisionShape3D.new()
	var tc := CylinderShape3D.new()
	tc.radius = 0.13
	tc.height = Torpedo.LENGTH
	_torp_cs.shape = tc
	sb.add_child(_torp_cs)
	add_child(sb)


func _build_fx() -> void:
	_beacon = OmniLight3D.new()
	_beacon.light_color = AMBER
	_beacon.omni_range = 5.0
	_beacon.light_energy = 0.0
	_beacon.shadow_enabled = false
	_beacon.position = APEX + Vector3(0, 0.5, 0)
	add_child(_beacon)
	_spark_light = OmniLight3D.new()
	_spark_light.light_color = Color(1.0, 0.62, 0.3)
	_spark_light.omni_range = 4.5
	_spark_light.light_energy = 0.0
	_spark_light.shadow_enabled = false
	_spark_light.position = Vector3(0, 0.25, 0)
	add_child(_spark_light)
	# Sparks off the drill where it bites (world space once emitted).
	_sparks = GPUParticles3D.new()
	_sparks.amount = 40
	_sparks.lifetime = 0.5
	_sparks.emitting = false
	_sparks.local_coords = false
	_sparks.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	_sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 80.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 5.5
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.5
	pm.damping_max = 1.5
	pm.scale_min = 0.6
	pm.scale_max = 1.3
	pm.color = Color(1.0, 0.62, 0.25) * 3.0
	_sparks.process_material = pm
	var sq := QuadMesh.new()
	sq.size = Vector2(0.015, 0.09)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.vertex_color_use_as_albedo = true
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sq.material = sm
	_sparks.draw_pass_1 = sq
	add_child(_sparks)
	# Dust out of the bore frame.
	_dust = CPUParticles3D.new()
	_dust.amount = 30
	_dust.lifetime = 1.8
	_dust.local_coords = false
	_dust.emitting = false
	var dq := QuadMesh.new()
	dq.size = Vector2(0.8, 0.8)
	var dmat := StandardMaterial3D.new()
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dmat.vertex_color_use_as_albedo = true
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.albedo_texture = DigFx.soft_texture()
	dq.material = dmat
	_dust.mesh = dq
	_dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_dust.emission_sphere_radius = 0.35
	_dust.direction = Vector3(0, 1, 0)
	_dust.spread = 55.0
	_dust.initial_velocity_min = 0.8
	_dust.initial_velocity_max = 2.6
	_dust.damping_min = 0.8
	_dust.damping_max = 1.4
	_dust.scale_amount_min = 0.7
	_dust.scale_amount_max = 2.0
	add_child(_dust)
	# Exhaust smoke from the winch's stack while it runs.
	_smoke = CPUParticles3D.new()
	_smoke.amount = 14
	_smoke.lifetime = 2.2
	_smoke.local_coords = false
	_smoke.emitting = false
	var smq := QuadMesh.new()
	smq.size = Vector2(0.35, 0.35)
	var smm := StandardMaterial3D.new()
	smm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smm.vertex_color_use_as_albedo = true
	smm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smm.albedo_texture = dmat.albedo_texture
	smq.material = smm
	_smoke.mesh = smq
	_smoke.direction = Vector3(0, 1, 0)
	_smoke.spread = 12.0
	_smoke.initial_velocity_min = 0.6
	_smoke.initial_velocity_max = 1.2
	_smoke.scale_amount_min = 0.8
	_smoke.scale_amount_max = 2.2
	var sg := Gradient.new()
	sg.set_color(0, Color(0.3, 0.3, 0.31, 0.45))
	sg.set_color(1, Color(0.45, 0.45, 0.46, 0.0))
	_smoke.color_ramp = sg
	_smoke.position = MOTOR + Vector3(-0.38, 1.48, -0.18)
	add_child(_smoke)


func _build_audio() -> void:
	_hum = AudioStreamPlayer3D.new()
	_hum.stream = Snd.loop("foley/motor_loop")
	_hum.unit_size = 6.0
	_hum.max_distance = 45.0
	_hum.volume_db = -80.0
	add_child(_hum)
	_grind = AudioStreamPlayer3D.new()
	_grind.stream = Snd.loop("shuttle/rumble")
	_grind.unit_size = 8.0
	_grind.max_distance = 40.0
	_grind.volume_db = -80.0
	add_child(_grind)


## The model torpedo with its tip `tip_h` m above the bore frame's ground; the hook and cable follow.
func _place_torpedo(tip_h: float) -> void:
	_torp.position = Vector3(0, _ground_y + tip_h, 0)
	if _torp_cs != null:
		_torp_cs.position = Vector3(0, _ground_y + tip_h + Torpedo.HALF, 0)
	if not _launched:
		_hook_y = _ground_y + tip_h + Torpedo.LENGTH + 0.1
	_update_cable()


func _update_cable() -> void:
	var top := APEX + Vector3(0, -0.36, 0)
	var bot := Vector3(0, _hook_y + 0.12, 0)
	var l := maxf(top.y - bot.y, 0.05)
	_cable.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(1, l, 1)), (top + bot) * 0.5)
	_hook.position = Vector3(0, _hook_y, 0)


# =================================================================================================
# Life
# =================================================================================================

## Parts drop into place over ~1.6 s (built with the tool / by the network with animation).
func begin_assembly() -> void:
	_build_t = 0.0
	for p in _parts:
		(p[0] as Node3D).visible = false
	_torp.visible = false
	BuildFx.assemble(get_parent(), global_transform, footprint(), BuildFx.AUTO, self)


## Still lowering its torpedo (the AI's top target).
func is_arming() -> bool:
	return not is_destroyed and not _launched


func _process(delta: float) -> void:
	_t += delta
	if _build_t >= 0.0:
		_tick_assembly(delta)
	elif not is_destroyed:
		_tick_arming(delta)
	_animate(delta)
	_hit_t = maxf(_hit_t - delta * 3.0, 0.0)
	_paint.emission_enabled = _hit_t > 0.0
	if _hit_t > 0.0:
		_paint.emission = Color(1.0, 0.35, 0.1) * _hit_t


func _tick_assembly(delta: float) -> void:
	_build_t += delta
	var done := true
	for p in _parts:
		var n: Node3D = p[0]
		var k := clampf((_build_t - float(p[2])) / 0.6, 0.0, 1.0)
		n.visible = k > 0.0
		var e := 1.0 - pow(1.0 - k, 3.0)
		n.transform = (p[1] as Transform3D).translated_local(Vector3(0, 2.2 * (1.0 - e), 0)).scaled_local(Vector3.ONE * lerpf(0.6, 1.0, e))
		if k < 1.0:
			done = false
	_torp.visible = _build_t > 1.1
	if done:
		_build_t = -1.0
		for p in _parts:
			(p[0] as Node3D).transform = p[1]
		if Game.sfx:
			Game.sfx.play_at("impact", global_position, -4.0, 0.75, 14.0)


## Arming: the host / single player runs the clock and plants the torpedo; a client's copy shows
## the host's `charge` (net_world's structure state) and swaps its model at 1.
func _tick_arming(delta: float) -> void:
	if _launched:
		_since_launch += delta
		return
	if Net.is_client():
		if charge >= 0.999:
			_k = 1.0
			_launch()
			return
		if charge <= 0.0:
			return                         # (a late joiner's copy: wait for the host's word)
		if not _started_fx:
			_start_arming_fx()
		_k = move_toward(_k, charge, delta * 0.6)
		return
	if not _started_fx:
		_start_arming_fx()
	charge = minf(charge + delta / maxf(Balance.TORPEDO_RIG_ARM_TIME, 0.1), 1.0)
	_k = charge
	if charge >= 1.0:
		_launch()


func _start_arming_fx() -> void:
	_started_fx = true
	var up := global_transform.basis.y.normalized()
	(_sparks.process_material as ParticleProcessMaterial).gravity = -up * 7.0
	_dust.gravity = -up * 1.2
	var soil := Color(0.42, 0.36, 0.27)
	if body != null and body.get("soil_color") is Color:
		soil = body.get("soil_color")
	var g := Gradient.new()
	g.set_color(0, Color(soil.r, soil.g, soil.b, 0.55))
	g.set_color(1, Color(soil.r, soil.g, soil.b, 0.0))
	_dust.color_ramp = g
	_smoke.gravity = up * 0.4
	_smoke.emitting = true
	_hum.pitch_scale = 0.55
	_hum.play()
	if Game.sfx:
		Game.sfx.play_at("servo", global_position + up * 1.0, -4.0, 0.8, 16.0)
	var st: AudioStream = Snd.one("shuttle/startup")
	if st != null:
		var a := AudioStreamPlayer3D.new()
		a.stream = st
		a.unit_size = 6.0
		a.max_distance = 40.0
		a.volume_db = -6.0
		a.pitch_scale = 1.25
		add_child(a)
		a.position = MOTOR + Vector3(0, 0.6, 0)
		a.play()
		a.finished.connect(a.queue_free)


## Ground point under the bore (world): the density surface below the rig's centre.
## (Foundation.ground_offset: the terrain collision, else the density; the old cheap march skipped
## the ±1.3 m detail noise and the frame floated or sank.)
func _ground_point() -> Vector3:
	var up := global_transform.basis.y.normalized()
	var o := global_position
	if body != null and is_instance_valid(body):
		var off := Foundation.ground_offset(self, body, o, up, 2.6, 3.0)
		if not is_inf(off):
			return o + up * off
	return o


## Foundation (scripts/war/foundation.gd): a steel pile under each foot (local).
func _foot_piles() -> Array:
	var piles: Array = []
	for i in 3:
		piles.append([_foot(i), 0.1])
	return piles


## The arming is over: the model torpedo goes, the real one starts drilling (host / single player).
func _launch() -> void:
	if _launched:
		return
	_launched = true
	charge = 1.0
	_k = 1.0
	_torp.visible = false
	_torp_cs.disabled = true
	var up := global_transform.basis.y.normalized()
	_bore = global_position + up * _ground_y
	_sparks.emitting = false
	_dust.emitting = false
	if Game.sfx:
		Game.sfx.play_at("impact", _bore, -2.0, 0.6, 20.0)
	if Net.is_client() or body == null or not is_instance_valid(body):
		return                         # a client's torpedo comes from the host (found in _track)
	_bore = _ground_point()
	var down := (body.global_position - _bore).normalized()
	torpedo = Torpedo.plant(get_parent(), _bore, down, team, body)
	if torpedo == null:
		return
	torpedo.state_changed.connect(_on_torp_state)
	if bool(torpedo.call("is_dead")):
		_on_torp_state(torpedo, int(torpedo.get("state")))


func _on_torp_state(_t_node: Node3D, st: int) -> void:
	if st == Torpedo.DONE:
		_result = "ÇEKİRDEĞE\nULAŞTI"
	elif st == Torpedo.DEAD:
		_result = "TORPİDO\nYOK EDİLDİ"
	elif st == Torpedo.DUD:
		_result = "HEDEF\nKALMADI"


## The planted torpedo is still at work (a client that has not found its puppet yet: for a while).
func _working() -> bool:
	if not _launched or _result != "" or is_destroyed:
		return false
	if torpedo != null:
		return is_instance_valid(torpedo) and bool(torpedo.call("is_live"))
	return _since_launch < 8.0


## A client: finds the host's torpedo (its puppet) near the bore once it arrives.
func _track(delta: float) -> void:
	if torpedo != null or _result != "" or _find_t > 6.0:
		return
	_find_t += delta
	_scan_t -= delta
	if _scan_t > 0.0:
		return
	_scan_t = 0.25
	for t in get_tree().get_nodes_in_group(Torpedo.GROUP):
		if str(t.get("team")) == team and (t as Node3D).global_position.distance_to(_bore) < 4.0:
			torpedo = t
			if t.has_signal("state_changed"):
				t.state_changed.connect(_on_torp_state)
			return


# =================================================================================================
# Per frame (looks)
# =================================================================================================

func _animate(delta: float) -> void:
	var k := _k
	var building := _build_t >= 0.0
	var arming := not building and not _launched and not is_destroyed
	var contact := arming and k > 0.6
	var working := _working()
	# Winch: pays out while the torpedo goes down, hauls the empty hook back up afterwards.
	var drop := smoothstep(0.05, 0.6, k)
	if not _launched:
		_place_torpedo(HANG * (1.0 - drop))
		_drum.rotation.x = -drop * HANG / 0.14
	else:
		_hook_y = lerpf(_hook_y, APEX.y - 1.0, 1.0 - exp(-delta * 0.8))
		_drum.rotation.x += delta * 2.0 * clampf((_hook_y - (APEX.y - 1.0)) * -1.0, 0.0, 1.0)
		_update_cable()
	# Drill and fan.
	var spin_rate := 0.0
	if arming:
		spin_rate = lerpf(0.0, 34.0, smoothstep(0.1, 0.7, k))
	_spin += spin_rate * delta
	_drill.rotation.z = _spin
	var fan_rate := 0.0
	if arming:
		fan_rate = 6.0 + 30.0 * k
	elif working:
		fan_rate = 4.0
	_fan_spin += fan_rate * delta
	_fan.rotation.x = _fan_spin
	# Sound.
	if _hum.playing:
		var want_db: float = linear_to_db(0.25 + 0.75 * k) if arming else (linear_to_db(0.12) if working else -80.0)
		_hum.volume_db = lerpf(_hum.volume_db, want_db, 1.0 - exp(-delta * 3.0))
		_hum.pitch_scale = lerpf(_hum.pitch_scale, (0.6 + 0.8 * k) if arming else 0.5, 1.0 - exp(-delta * 2.0))
		if _hum.volume_db < -60.0 and not arming:
			_hum.stop()
	if contact and not _grind.playing:
		_grind.play()
	if _grind.playing:
		_grind.volume_db = lerpf(_grind.volume_db, -2.0 if contact else -80.0, 1.0 - exp(-delta * 4.0))
		_grind.pitch_scale = 0.7 + 0.25 * k
		if not contact and _grind.volume_db < -60.0:
			_grind.stop()
	# Bite-in: sparks, dust, the spark light, a rumble for a player nearby.
	if _sparks.emitting != contact:
		_sparks.emitting = contact
		_dust.emitting = contact
	_sparks.position = Vector3(0, _ground_y + 0.08, 0)
	_dust.position = Vector3(0, _ground_y + 0.1, 0)
	_spark_light.position = Vector3(0, _ground_y + 0.25, 0)
	_spark_light.light_energy = randf_range(1.6, 3.0) if contact else 0.0
	if contact:
		_rumble_t -= delta
		if _rumble_t <= 0.0:
			_rumble_t = 0.15
			var pl = Game.player
			if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
				var dp: float = (pl as Node3D).global_position.distance_to(global_position)
				if dp < 18.0:
					var k2 := 1.0 - dp / 18.0
					pl.add_trauma(0.015 + 0.08 * k2 * k2)
	if _smoke.emitting and not arming and not working:
		_smoke.emitting = false
	# Lights: work lights on while it works; the beacon blinks amber while arming, then the team
	# colour, dim when it is all over; the collar ring glows with the arming.
	var on := not building and not is_destroyed
	var work := on and (arming or working)
	for sp in _spots:
		(sp as SpotLight3D).light_energy = lerpf((sp as SpotLight3D).light_energy, 2.4 if work else (0.5 if on else 0.0), 1.0 - exp(-delta * 4.0))
	_lens_mat.emission_energy_multiplier = 3.0 if work else 0.8
	if arming:
		var blink := 1.0 if fmod(_t, 0.6) < 0.3 else 0.15
		_beacon.light_color = AMBER
		_beacon.light_energy = 1.4 * blink
		_beacon_mat.emission = AMBER
		_beacon_mat.emission_energy_multiplier = 5.0 * blink
		_collar_mat.emission = AMBER
		_collar_mat.emission_energy_multiplier = 0.6 + 4.0 * k + (1.5 * sin(_t * 20.0) if contact else 0.0)
	elif on:
		var live := working
		var pulse := (0.6 + 0.4 * sin(_t * 2.5)) if live else 0.25
		_beacon.light_color = _col_team
		_beacon.light_energy = 0.9 * pulse
		_beacon_mat.emission = _col_team
		_beacon_mat.emission_energy_multiplier = 3.0 * pulse
		_collar_mat.emission = _col_team
		_collar_mat.emission_energy_multiplier = 1.2 * pulse
	else:
		_beacon.light_energy = 0.0
	for i in _lamp_mats.size():
		var lm: StandardMaterial3D = _lamp_mats[i]
		var lit := false
		match i:
			0:
				lit = on and (_launched or fmod(_t, 1.0) < 0.5)
			1:
				lit = arming and fmod(_t * 3.0, 1.0) < 0.5
			2:
				lit = _hit_t > 0.05 or _result.begins_with("TORPİDO")
		lm.emission_energy_multiplier = 4.0 if lit else 0.3
	_band_mat.albedo_color = _col_team * (2.2 + (1.2 * sin(_t * 9.0) if contact else 0.0))
	# Screen.
	if _launched and Net.is_client():
		_track(delta)
	var txt := _screen_text(k, building)
	if _screen.text != txt:
		_screen.text = txt


func _screen_text(k: float, building: bool) -> String:
	if building:
		return "SONDAJ KULESİ\nKURULUYOR"
	if not _launched:
		var head := "TORPİDO İNİYOR" if k < 0.6 else "DELİYOR"
		return "%s\n%d%%" % [head, int(k * 100.0)]
	if _result != "":
		return _result
	if torpedo != null and is_instance_valid(torpedo) and bool(torpedo.call("is_burrowing")):
		var dep := int(float(torpedo.call("depth")))
		var left := int(ceilf(float(torpedo.call("core_distance"))))
		return "KAZIYOR %d m\nÇEKİRDEĞE %d m" % [dep, left]
	return "TORPİDO\nTOPRAKTA"


# =================================================================================================
# Damage, ground
# =================================================================================================

func hud_name() -> String:
	return "Sondaj Kulesi" if team == "home" else "Düşman Sondaj Kulesi"


func take_damage(amount: float, _from_pos := Vector3.ZERO, _impulse := Vector3.ZERO) -> Dictionary:
	if is_destroyed or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	hp = maxf(hp - amount, 0.0)
	_hit_t = 1.0
	if hp <= 0.0:
		_destroy()
		return {"dmg": amount, "killed": true}
	return {"dmg": amount, "killed": false}


func is_dead() -> bool:
	return is_destroyed


func _destroy() -> void:
	if is_destroyed:
		return
	is_destroyed = true
	if Game.hud:
		if team == "home":
			Game.hud.show_message("Sondaj kulemiz yok edildi!" + ("" if _launched else " Torpido indirilemedi."), 2.8)
		else:
			Game.hud.show_message("Düşman sondaj kulesi yok edildi!", 2.5)
	destroyed.emit(self)
	Explosion.spawn(global_position + global_transform.basis.y * 1.2, global_transform.basis.y,
			{"radius": 4.5, "damage": 25.0, "impulse": 7.0, "crater": 0.0, "player_owned": false})
	remove_from_group("war_structure")
	remove_from_group(GROUP)
	remove_from_group(Game.DAMAGEABLE)
	queue_free()


## Ground dug away near the feet: the tripod settles onto what is left (its own torpedo's tunnel,
## 1 m around the bore, never reaches the feet).
func _on_brush(center: Vector3, r: float) -> void:
	if is_destroyed or _ground_check:
		return
	if center.distance_to(global_position) < r + FOOT_R + 2.0:
		_ground_check = true
		_settle.call_deferred()


func _settle() -> void:
	await get_tree().create_timer(1.2).timeout
	_ground_check = false
	if is_destroyed or body == null or not is_instance_valid(body) or not is_inside_tree():
		return
	var up: Vector3 = global_transform.basis.y.normalized()
	var drop := INF
	for i in 3:
		var f: Vector3 = global_transform * _foot(i)
		var hit: Dictionary = body.raycast_density(f + up * 2.0, f - up * 30.0, 0.5)
		if hit.is_empty():
			continue
		drop = minf(drop, (f - (hit["position"] as Vector3)).dot(up))
	if drop == INF or drop < 0.4:
		_refit_foundation()                # a foot over the new hole gets its pile
		return
	var tw := create_tween()
	tw.tween_property(self, "global_position", global_position - up * drop, clampf(sqrt(drop) * 0.3, 0.2, 1.2)).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(_refit_foundation)


func _refit_foundation() -> void:
	if _foundation != null and is_instance_valid(_foundation):
		_foundation.refit(true)
