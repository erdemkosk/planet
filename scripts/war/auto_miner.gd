extends Node3D
## Otomatik Kazıcı (auto-miner), built with the İnşa Aracı (Balance.MINER_COST, BUILD_SITE "any": on
## our planet or, risky but lucrative, on the enemy's: × MINER_ENEMY_MULT). It digs its OWN shaft and
## pays its owner while it digs.
##
## Model (local frame, +Y up, +Z toward whoever built it; home white / orange, rival gunmetal / red):
## four outrigger legs with pads holding a square deck frame around a striped steel collar over the
## shaft; a four-post mast over the hole with the drive head on top (motor housing, a spinning
## flywheel, an amber beacon) and two work lamps aimed down the shaft; a telescoping drill string
## (four nested tubes) down to a cutter head (disc, spokes, carbide teeth, a centre cone and a warm
## lamp) that spins and sinks with the shaft; an inclined belt conveyor carrying soil lumps from the
## collar up to a hopper that visibly fills and dumps a load (MINER_HOPPER m³: "+10 m³" rises over
## it); a dust plume out of the collar while it digs; a power pack with a spinning fan and exhaust
## smoke on a corner of the deck; a holo screen on the front: "ÜRETİM x m³/dk · DERİNLİK y m".
##
## Life: the parts drop into place (begin_assembly, ~1.6 s), it spins up (MINER_START_DELAY), then
## sinks at MINER_DESCENT m/s (slower deeper) carving a real shaft: a DIG brush of MINER_SHAFT_R every
## MINER_DIG_STEP m (Dig.dig_at with its team: logged for the enemy's Tünel tarayıcı, synced like any
## dig) down to MINER_MAX_DEPTH. Output MINER_RATE m³/s at the top, less deeper, MINER_RATE_DRY at the
## bottom ("KURUDU"). Only the HOST / single player digs and pays; a client's copy shows `charge`
## (depth / MINER_MAX_DEPTH, the structure state's charge byte) and fakes the hopper from the same rate.
##
## Who is paid (per full hopper, `produced` is emitted for every load): EVERY player of the miner's
## team gets the full load, whoever built it (2026-10-06: team income, no co-op pool any more):
##   the local player   when the miner is on his side: Game.add_material (single player, the host)
##   the remote player  when he is on the miner's side (co-op: always; PvP: his own builds): the
##                      network layer forwards `produced` to him (net_world _on_miner_produced), his
##                      machine calls AutoMiner.receive_grant(amount)
##   the rival pool     an AI side's miner with no local player on it (group "war_rival_team",
##                      add_material: the AI does not build miners yet, the hook is there).
## owner_peer (> 0: the client who asked for the build) only decides that nobody local is paid for a
## remote player's side.
##
## Groups "damageable", "war_structure", "war_miner" (a juicy target: the AI may go for it).
## take_damage(amount, from, impulse) -> {"dmg", "killed"}; destroyed at 0 hp: an explosion, the shaft
## stays. Structure contract like the armory / Sondaj Kulesi: team, body, hp, hp_max, is_destroyed,
## begin_assembly(), _destroy(), static footprint(), _yaw_t / _pitch_t / tracking / charge (net sync).
##   AutoMiner.spawn(parent, body, xf, team, animate := true, owner_peer := 0) -> miner

const Balance := preload("res://scripts/war/balance.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const Dig := preload("res://scripts/player/dig.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const Foundation := preload("res://scripts/war/foundation.gd")

const GROUP := "war_miner"
const FRAME := 1.6                     # deck frame half size (the shaft is under its middle)
const DECK_Y := 0.45
const HEAD_Y := 3.35                   # drive head on top of the mast
const STRING_TOP := 3.2
const HOPPER := Vector3(2.0, 0.0, -0.35)
const HOPPER_TOP := 2.1
const AMBER := Color(1.0, 0.62, 0.2)
const SPOT_COL := Color(1.0, 0.93, 0.8)
const LUMPS := 7

signal destroyed(miner: Node3D)
## A hopper load is ready for the owner (see the header). owner_peer: 0 = paid here (local player /
## rival pool), > 0 = a remote peer the network layer must pay.
signal produced(peer: int, amount: float)

var team := "home"
var body: Node3D
var hp := Balance.MINER_HP
var hp_max := Balance.MINER_HP
var is_destroyed := false
var owner_peer := 0                    # who is paid (header); set before add_child (net_world: the client's peer id)
var depth := 0.0                       # m the shaft reaches below the ground it was built on
var charge := 0.0                      # depth / MINER_MAX_DEPTH (host -> client)
var rate := 0.0                        # m³/s right now (screen)
var total_mined := 0.0                 # m³ paid out (host / single player)
# Read by the multiplayer structure sync like any structure's (unused here).
var _yaw_t := 0.0
var _pitch_t := 0.0
var tracking := false

var _hit_t := 0.0
var _t := 0.0
var _build_t := -1.0
var _parts: Array = []                 # [node, rest transform, delay]
var _start_t := Balance.MINER_START_DELAY
var _since_brush := 99.0
var _hopper := 0.0                     # m³ in the hopper (host: real, client: cosmetic)
var _dump_t := -1.0                    # s since a dump (animation)
var _ground_y := 0.0                   # ground under the shaft (local y)
var _shown_depth := 0.0
var _spin := 0.0
var _fan_spin := 0.0
var _belt_t := 0.0
var _work := 0.0                       # 0..1 how hard it works (look / sound)
var _digging := false                  # inside our own Dig call (ignore our own brush_applied)
var _ground_check := false
var _foundation: Node3D               # piles under the leg pads down to the real ground (foundation.gd)
var _col_team := Color(0.35, 0.88, 1.0)
var _home_body: Node3D

var _paint: StandardMaterial3D
var _beacon_mat: StandardMaterial3D
var _lens_mat: StandardMaterial3D
var _lamp_mats: Array = []
var _strip_mat: StandardMaterial3D
var _belt_mat: StandardMaterial3D
var _tubes: Array = []                 # nested drill-string tubes (MeshInstance3D, unit height)
var _bit: Node3D
var _bit_light: OmniLight3D
var _flywheel: Node3D
var _fan: Node3D
var _lumps: Array = []
var _fill: MeshInstance3D
var _spots: Array = []
var _beacon: OmniLight3D
var _plume: CPUParticles3D
var _head_dust: CPUParticles3D
var _smoke: CPUParticles3D
var _screen: Label3D
var _hum: AudioStreamPlayer3D
var _grind: AudioStreamPlayer3D
var _belt_a := Vector3.ZERO
var _belt_b := Vector3.ZERO


static func spawn(parent: Node, p_body: Node3D, xf: Transform3D, p_team: String, animate := true, p_owner := 0) -> Node3D:
	var m: Node3D = load("res://scripts/war/auto_miner.gd").new()
	m.team = p_team
	m.body = p_body
	m.owner_peer = p_owner
	m.name = "AutoMiner_" + p_team
	m.transform = xf
	parent.add_child(m)
	if animate:
		m.begin_assembly()
	return m


## Half extents of the placement box (net_world's build check reads its radius from this).
static func footprint() -> Vector3:
	return Vector3(Balance.MINER_FOOTPRINT, 1.9, Balance.MINER_FOOTPRINT)


## Multiplayer: the owner's machine is paid a load (net_world forwards `produced` to that peer).
static func receive_grant(amount: float) -> void:
	if amount > 0.0:
		Game.add_material(minf(amount, 500.0))


func _ready() -> void:
	_col_team = Color(0.35, 0.88, 1.0) if team == "home" else Color(1.0, 0.28, 0.14)
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_structure")
	add_to_group(GROUP)
	set_meta("footprint_r", Balance.MINER_FOOTPRINT)
	var preview := has_meta("build_preview")
	if not preview:
		_ground_y = clampf((_ground_point() - global_position).dot(global_transform.basis.y.normalized()),
				-0.4, Balance.BUILD_MAX_STEP + 0.2)
	_home_body = Game.planet if team == "home" else Game.rival
	_build_model()
	_build_fx()
	_build_audio()
	_update_string()
	if preview:
		return
	if body != null:
		_foundation = Foundation.create(self, body, PackedVector3Array(), _leg_piles(), Color.GRAY)
		_parts.append([_foundation, _foundation.transform, 0.12])
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


static func _seg_basis(a: Vector3, b: Vector3) -> Basis:
	var y := (b - a).normalized()
	var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


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


func _part(delay: float, pos := Vector3.ZERO) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	add_child(n)
	_parts.append([n, n.transform, delay])
	return n


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
	var carbide := _mat(Color(0.16, 0.16, 0.17), 0.8, 0.3)
	var soil := Color(0.42, 0.36, 0.27)
	if body != null and body.get("soil_color") is Color:
		soil = body.get("soil_color")
	var soil_m := _mat(soil.darkened(0.15), 0.0, 0.95)
	_beacon_mat = _mat(AMBER, 0.0, 0.4, 0.6)
	_lens_mat = _mat(SPOT_COL, 0.0, 0.3, 0.8)
	_strip_mat = _mat(_col_team, 0.0, 0.4, 2.0)
	var gy := _ground_y

	# --- Collar over the shaft: a striped steel ring on the ground.
	var collar := _part(0.0, Vector3(0, gy, 0))
	var tm := TorusMesh.new()
	tm.inner_radius = 1.42
	tm.outer_radius = 1.62
	tm.rings = 40
	tm.ring_segments = 6
	var ring := MeshInstance3D.new()
	ring.mesh = tm
	ring.material_override = worn
	ring.position = Vector3(0, 0.06, 0)
	collar.add_child(ring)
	for i in 16:
		var a := TAU * float(i) / 16.0
		_box(collar, Vector3(cos(a), 0.0, sin(a)) * 1.52 + Vector3(0, 0.13, 0), Vector3(0.12, 0.012, 0.3),
				yellow if i % 2 == 0 else black, Vector3(0, -a, 0))
	# --- Legs with pads and the deck frame.
	var legs := _part(0.12)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var c := Vector3(FRAME * sx, gy, FRAME * sz)
			_box(legs, c + Vector3(0, 0.035, 0), Vector3(0.5, 0.07, 0.5), worn)
			_cyl(legs, c + Vector3(0, 0.2, 0), 0.08, 0.1, 0.26, gun)
			_box(legs, Vector3(FRAME * sx, (gy + DECK_Y) * 0.5 + 0.15, FRAME * sz), Vector3(0.16, DECK_Y - gy + 0.1, 0.16), _paint)
	for s in [-1.0, 1.0]:
		_box(legs, Vector3(0, DECK_Y, FRAME * s), Vector3(FRAME * 2.0 + 0.2, 0.18, 0.2), _paint)
		_box(legs, Vector3(FRAME * s, DECK_Y, 0), Vector3(0.2, 0.18, FRAME * 2.0 + 0.2), _paint)
		_box(legs, Vector3(0, DECK_Y + 0.1, FRAME * s), Vector3(FRAME * 2.0 + 0.22, 0.03, 0.22), stripe)
		_box(legs, Vector3(FRAME * s, DECK_Y + 0.1, 0), Vector3(0.22, 0.03, FRAME * 2.0 + 0.22), stripe)
	# Corner deck plates.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(legs, Vector3(1.2 * sx, DECK_Y + 0.02, 1.2 * sz), Vector3(0.75, 0.04, 0.75), dark, Vector3(0, PI * 0.25, 0))
	# --- Mast over the hole: four posts, braces, the drive head on top.
	var mast := _part(0.3)
	var top := HEAD_Y - 0.25
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var foot := Vector3(0.95 * sx, DECK_Y, 0.95 * sz)
			var head := Vector3(0.42 * sx, top, 0.42 * sz)
			_seg(mast, foot, head, 0.06, _paint, 10)
	var corners := [Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1), Vector2(-1, 1)]
	for y in [1.4, 2.4]:
		var k: float = (float(y) - DECK_Y) / (top - DECK_Y)
		var h := lerpf(0.95, 0.42, k)
		for i in 4:
			var ca: Vector2 = corners[i]
			var cb: Vector2 = corners[(i + 1) % 4]
			_seg(mast, Vector3(ca.x * h, float(y), ca.y * h), Vector3(cb.x * h, float(y), cb.y * h), 0.028, steel, 6)
	_box(mast, Vector3(0, top + 0.02, 0), Vector3(1.0, 0.1, 1.0), stripe)
	var drive := _part(0.5)
	_box(drive, Vector3(0, HEAD_Y, 0), Vector3(0.85, 0.42, 0.7), _paint)
	_box(drive, Vector3(0, HEAD_Y + 0.23, 0), Vector3(0.87, 0.05, 0.72), dark)
	_box(drive, Vector3(0, HEAD_Y, 0.36), Vector3(0.6, 0.06, 0.02), _strip_mat)
	for k in 6:
		_box(drive, Vector3(-0.25 + k * 0.1, HEAD_Y + 0.05, -0.36), Vector3(0.03, 0.28, 0.02), steel)
	_flywheel = Node3D.new()
	_flywheel.position = Vector3(0.47, HEAD_Y, 0.0)
	drive.add_child(_flywheel)
	_cyl(_flywheel, Vector3.ZERO, 0.26, 0.26, 0.07, gun, Vector3(0, 0, PI * 0.5), 20)
	for k in 3:
		_box(_flywheel, Vector3(0.04, 0, 0), Vector3(0.03, 0.46, 0.06), stripe, Vector3(TAU * float(k) / 6.0, 0, 0))
	_cyl(drive, Vector3(0, HEAD_Y + 0.33, 0), 0.07, 0.09, 0.08, gun)
	_cyl(drive, Vector3(0, HEAD_Y + 0.42, 0), 0.06, 0.07, 0.11, _beacon_mat)
	_cyl(drive, Vector3(-0.3, HEAD_Y + 0.55, -0.25), 0.012, 0.018, 0.5, steel)
	# Work lamps on the mast, aimed down the shaft.
	for sx in [-1.0, 1.0]:
		var p := Vector3(0.62 * sx, 2.3, 0.62)
		var lamp := Node3D.new()
		lamp.transform = Transform3D(Basis.looking_at(Vector3(0, gy - 4.0, 0) - p, Vector3.FORWARD), p)
		drive.add_child(lamp)
		_cyl(lamp, Vector3(0, 0, 0.02), 0.07, 0.09, 0.14, gun, Vector3(PI * 0.5, 0, 0), 12)
		_cyl(lamp, Vector3(0, 0, -0.055), 0.065, 0.065, 0.012, _lens_mat, Vector3(PI * 0.5, 0, 0), 12)
		var sp := SpotLight3D.new()
		sp.light_color = SPOT_COL
		sp.spot_range = 16.0
		sp.spot_angle = 26.0
		sp.light_energy = 0.0
		sp.shadow_enabled = false
		sp.position = Vector3(0, 0, -0.07)
		lamp.add_child(sp)
		_spots.append(sp)
	# --- Conveyor: collar -> hopper (an inclined frame, rollers, a moving belt, soil lumps).
	var conv := _part(0.7)
	_belt_a = Vector3(1.0, gy + 0.6, -0.1)
	_belt_b = Vector3(HOPPER.x - 0.1, HOPPER_TOP + 0.25, HOPPER.z)
	var along := _belt_b - _belt_a
	var bl := along.length()
	var bb := Basis.looking_at(-along.normalized(), Vector3.UP)          # +Z of bb runs a -> b
	var mid := (_belt_a + _belt_b) * 0.5
	var fr := Node3D.new()
	fr.transform = Transform3D(bb, mid)
	conv.add_child(fr)
	for sx in [-1.0, 1.0]:
		_box(fr, Vector3(0.21 * sx, -0.04, 0), Vector3(0.05, 0.12, bl + 0.1), _paint)
		_box(fr, Vector3(0.235 * sx, -0.04, 0), Vector3(0.008, 0.04, bl), stripe)
	_belt_mat = StandardMaterial3D.new()
	_belt_mat.albedo_texture = _belt_tex()
	_belt_mat.roughness = 0.9
	_belt_mat.uv1_scale = Vector3(1.0, bl * 2.0, 1.0)
	_box(fr, Vector3(0, -0.01, 0), Vector3(0.38, 0.03, bl), dark)
	var pm := PlaneMesh.new()                  # the belt's top: plain 0..1 UVs, v along the belt
	pm.size = Vector2(0.36, bl)
	var belt := MeshInstance3D.new()
	belt.mesh = pm
	belt.material_override = _belt_mat
	belt.position = Vector3(0, 0.007, 0)
	fr.add_child(belt)
	for k in 5:
		_cyl(fr, Vector3(0, -0.03, -bl * 0.5 + bl * float(k) / 4.0), 0.035, 0.035, 0.4, steel, Vector3(0, 0, PI * 0.5), 10)
	# Supports down to the deck / ground.
	_seg(conv, Vector3(_belt_a.x + 0.2, DECK_Y + 0.1, _belt_a.z), _belt_a + along * 0.12 - Vector3(0, 0.08, 0), 0.04, dark, 8)
	_seg(conv, Vector3(HOPPER.x - 0.55, gy, HOPPER.z + 0.3), _belt_a + along * 0.72 - Vector3(0, 0.08, 0), 0.04, dark, 8)
	for i in LUMPS:
		var lm := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.08 + 0.03 * float(i % 3)
		sm.height = sm.radius * 1.4
		sm.radial_segments = 6
		sm.rings = 3
		lm.mesh = sm
		lm.material_override = soil_m
		lm.visible = false
		conv.add_child(lm)
		_lumps.append(lm)
	# --- Hopper: a square funnel bin on legs, the soil fill inside.
	var hop := _part(0.85, HOPPER)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(hop, Vector3(0.36 * sx, (gy + HOPPER_TOP - 0.7) * 0.5, 0.36 * sz), Vector3(0.07, HOPPER_TOP - 0.7 - gy, 0.07), dark)
	var bin := _cyl(hop, Vector3(0, HOPPER_TOP - 0.38, 0), 0.62, 0.3, 0.76, _paint, Vector3(0, PI * 0.25, 0), 4)
	(bin.mesh as CylinderMesh).cap_top = false
	_paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	_box(hop, Vector3(0, HOPPER_TOP + 0.01, 0), Vector3(0.9, 0.04, 0.04), stripe)
	_box(hop, Vector3(0, HOPPER_TOP - 0.82, 0), Vector3(0.36, 0.1, 0.36), gun)                   # the gate
	var fm := CylinderMesh.new()
	fm.top_radius = 0.58
	fm.bottom_radius = 0.3
	fm.height = 0.7
	fm.radial_segments = 4
	fm.rings = 1
	_fill = MeshInstance3D.new()
	_fill.mesh = fm
	_fill.material_override = soil_m
	_fill.rotation = Vector3(0, PI * 0.25, 0)
	_fill.visible = false
	hop.add_child(_fill)
	# --- Power pack on a deck corner: housing, fan, exhaust, status lamps.
	var pk := _part(1.0, Vector3(-1.25, DECK_Y + 0.04, -1.25))
	_box(pk, Vector3(0, 0.36, 0), Vector3(0.9, 0.68, 0.7), _paint, Vector3(0, PI * 0.25, 0))
	_box(pk, Vector3(0, 0.72, 0), Vector3(0.92, 0.05, 0.72), stripe, Vector3(0, PI * 0.25, 0))
	_fan = Node3D.new()
	_fan.transform = Transform3D(Basis(Vector3.UP, PI * 0.25), Vector3(0.0, 0.4, 0.0)).translated_local(Vector3(0, 0, 0.37))
	pk.add_child(_fan)
	for k in 4:
		_box(_fan, Vector3.ZERO, Vector3(0.05, 0.4, 0.015), worn, Vector3(0, 0, TAU * float(k) / 8.0))
	_cyl(_fan, Vector3.ZERO, 0.05, 0.05, 0.04, dark, Vector3(PI * 0.5, 0, 0), 10)
	_cyl(pk, Vector3(-0.15, 1.0, -0.15), 0.045, 0.045, 0.6, steel)
	_cyl(pk, Vector3(-0.15, 1.33, -0.15), 0.065, 0.05, 0.06, gun)
	for k in 3:
		var lm := _mat([Color(0.3, 1.0, 0.45), AMBER, Color(1.0, 0.3, 0.2)][k], 0.0, 0.4, 0.4)
		_lamp_mats.append(lm)
		var lp := Basis(Vector3.UP, PI * 0.25) * Vector3(-0.15 + k * 0.15, 0.55, 0.36)
		_box(pk, lp, Vector3(0.07, 0.045, 0.02), lm, Vector3(0, PI * 0.25, 0))
	_cyl(pk, Vector3(0.0, 0.05, 0.0), 0.02, 0.02, 0.1, rubber)
	# --- Holo screen on the front.
	var scr := _part(1.15)
	var sp0 := Vector3(0, DECK_Y + 0.75, FRAME + 0.12)
	_box(scr, Vector3(0, DECK_Y + 0.4, FRAME + 0.1), Vector3(0.08, 0.6, 0.08), dark)
	_box(scr, sp0, Vector3(0.95, 0.42, 0.06), dark)
	_box(scr, sp0 + Vector3(0, -0.24, 0), Vector3(0.97, 0.04, 0.08), stripe)
	var pane_m := StandardMaterial3D.new()
	pane_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pane_m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pane_m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	pane_m.albedo_color = Color(_col_team, 0.3)
	pane_m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pane := _box(scr, sp0 + Vector3(0, 0, 0.032), Vector3(0.88, 0.36, 0.004), pane_m)
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_screen = Label3D.new()
	_screen.text = "OTOMATİK KAZICI"
	_screen.font_size = 44
	_screen.pixel_size = 0.0021
	_screen.modulate = _col_team.lightened(0.45)
	_screen.outline_size = 0
	_screen.shaded = false
	_screen.position = sp0 + Vector3(0, 0, 0.036)
	scr.add_child(_screen)
	# --- Drill string (four nested tubes) and the cutter head: not parts (they follow the depth).
	for i in 4:
		var r := 0.17 - 0.03 * float(i)
		var c := CylinderMesh.new()
		c.top_radius = r
		c.bottom_radius = r
		c.height = 1.0
		c.radial_segments = 14
		c.rings = 1
		var mi := MeshInstance3D.new()
		mi.mesh = c
		mi.material_override = steel if i % 2 == 0 else gun
		add_child(mi)
		_tubes.append(mi)
	_bit = Node3D.new()
	add_child(_bit)
	_cyl(_bit, Vector3(0, -0.05, 0), 1.0, 1.05, 0.22, gun, Vector3.ZERO, 24)
	_cyl(_bit, Vector3(0, 0.12, 0), 0.3, 0.75, 0.16, _paint, Vector3.ZERO, 20)
	_cyl(_bit, Vector3(0, -0.38, 0), 0.32, 0.02, 0.45, carbide, Vector3.ZERO, 12)
	for k in 4:
		_box(_bit, Vector3(0, -0.19, 0), Vector3(1.9, 0.08, 0.12), stripe if k % 2 == 0 else dark, Vector3(0, TAU * float(k) / 8.0, 0))
	for k in 10:
		var a := TAU * float(k) / 10.0
		_box(_bit, Vector3(cos(a), -0.2, sin(a)) * Vector3(0.98, 1.0, 0.98), Vector3(0.09, 0.12, 0.09), carbide, Vector3(0.4, -a, 0))
	_bit_light = OmniLight3D.new()
	_bit_light.light_color = Color(1.0, 0.75, 0.45)
	_bit_light.omni_range = 4.5
	_bit_light.light_energy = 0.0
	_bit_light.shadow_enabled = false
	_bit_light.position = Vector3(0, 0.5, 0)
	_bit.add_child(_bit_light)
	for mi in find_children("*", "MeshInstance3D", true, false):
		var gi := mi as MeshInstance3D
		if gi.material_override != pane_m and gi.material_override != _lens_mat and gi.material_override != _strip_mat:
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_build_collision()


## Obstacles on the ship layer like the other structures: legs, the deck frame beams, the mast, the
## drive head, the hopper, the power pack (the shaft itself stays open: mind the hole).
func _build_collision() -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = Game.LAYER_SHIP
	sb.collision_mask = 0
	var boxes: Array = []
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			boxes.append([Vector3(FRAME * sx, (_ground_y + DECK_Y) * 0.5 + 0.1, FRAME * sz), Vector3(0.5, DECK_Y - _ground_y + 0.3, 0.5)])
	for s in [-1.0, 1.0]:
		boxes.append([Vector3(0, DECK_Y, FRAME * s), Vector3(FRAME * 2.0 + 0.2, 0.25, 0.22)])
		boxes.append([Vector3(FRAME * s, DECK_Y, 0), Vector3(0.22, 0.25, FRAME * 2.0 + 0.2)])
	boxes.append([Vector3(0, (DECK_Y + HEAD_Y) * 0.5, 0), Vector3(1.2, HEAD_Y - DECK_Y, 1.2)])
	boxes.append([Vector3(0, HEAD_Y + 0.1, 0), Vector3(0.9, 0.55, 0.75)])
	boxes.append([HOPPER + Vector3(0, (HOPPER_TOP + _ground_y) * 0.5, 0), Vector3(1.0, HOPPER_TOP - _ground_y, 1.0)])
	boxes.append([Vector3(-1.25, DECK_Y + 0.4, -1.25), Vector3(0.9, 0.8, 0.9)])
	for c in boxes:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = c[1]
		cs.shape = bs
		cs.position = c[0]
		sb.add_child(cs)
	add_child(sb)


## A dark belt with light cross ribs (scrolls along the conveyor).
static func _belt_tex() -> Texture2D:
	var img := Image.create(8, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 8:
			var rib := y % 8 < 2
			var c := Color(0.2, 0.2, 0.21) if rib else Color(0.07, 0.07, 0.075)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _build_fx() -> void:
	_beacon = OmniLight3D.new()
	_beacon.light_color = AMBER
	_beacon.omni_range = 6.0
	_beacon.light_energy = 0.0
	_beacon.shadow_enabled = false
	_beacon.position = Vector3(0, HEAD_Y + 0.6, 0)
	add_child(_beacon)
	var soil := Color(0.42, 0.36, 0.27)
	if body != null and body.get("soil_color") is Color:
		soil = body.get("soil_color")
	# Dust plume out of the collar.
	_plume = _dust(50, 2.6, 1.0, 1.0, 3.2, 1.0, 2.6, soil)
	_plume.position = Vector3(0, _ground_y + 0.3, 0)
	# Dust at the cutter head (seen down the shaft).
	_head_dust = _dust(18, 1.2, 0.8, 0.5, 1.6, 0.8, 1.8, soil.darkened(0.2))
	# Exhaust smoke of the power pack.
	_smoke = CPUParticles3D.new()
	_smoke.amount = 12
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
	smm.albedo_texture = DigFx.soft_texture()
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
	_smoke.position = Vector3(-1.4, DECK_Y + 1.42, -1.4)
	add_child(_smoke)


func _dust(amount: int, life: float, radius: float, vmin: float, vmax: float, smin: float, smax: float, col: Color) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.emitting = false
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 0.9)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	p.mesh = q
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = radius
	p.direction = Vector3(0, 1, 0)
	p.spread = 30.0
	p.initial_velocity_min = vmin
	p.initial_velocity_max = vmax
	p.damping_min = 0.6
	p.damping_max = 1.2
	p.scale_amount_min = smin
	p.scale_amount_max = smax
	var g := Gradient.new()
	g.set_color(0, Color(col.r, col.g, col.b, 0.5))
	g.set_color(1, Color(col.r, col.g, col.b, 0.0))
	p.color_ramp = g
	add_child(p)
	return p


func _build_audio() -> void:
	_hum = AudioStreamPlayer3D.new()
	_hum.stream = Snd.loop("foley/motor_loop")
	_hum.unit_size = 6.0
	_hum.max_distance = 45.0
	_hum.volume_db = -80.0
	_hum.position = Vector3(-1.25, DECK_Y + 0.5, -1.25)
	add_child(_hum)
	_grind = AudioStreamPlayer3D.new()
	_grind.stream = Snd.loop("shuttle/rumble")
	_grind.unit_size = 7.0
	_grind.max_distance = 40.0
	_grind.volume_db = -80.0
	_grind.position = Vector3(0, _ground_y, 0)
	add_child(_grind)


## The drill string from under the drive head to the cutter head, telescoped over four tubes.
func _update_string() -> void:
	var head_y := _ground_y - _shown_depth - 0.15
	_bit.position = Vector3(0, head_y, 0)
	var top := STRING_TOP
	var l := maxf(top - (head_y + 0.2), 0.3)
	var n := _tubes.size()
	for i in n:
		var mi: MeshInstance3D = _tubes[i]
		var y0 := top - l * float(i) / float(n) + (0.12 if i > 0 else 0.0)
		var y1 := top - l * float(i + 1) / float(n)
		var h := maxf(y0 - y1, 0.05)
		mi.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(1, h, 1)), Vector3(0, (y0 + y1) * 0.5, 0))


# =================================================================================================
# Life
# =================================================================================================

## Parts drop into place over ~1.6 s (built with the tool / by the network with animation).
func begin_assembly() -> void:
	_build_t = 0.0
	for p in _parts:
		(p[0] as Node3D).visible = false
	_bit.visible = false
	for mi in _tubes:
		(mi as Node3D).visible = false
	BuildFx.assemble(get_parent(), global_transform, footprint(), BuildFx.AUTO, self)


func is_working() -> bool:
	return _build_t < 0.0 and not is_destroyed and _start_t <= 0.0


func _process(delta: float) -> void:
	_t += delta
	if _build_t >= 0.0:
		_tick_assembly(delta)
	elif not is_destroyed and not has_meta("build_preview"):
		if _start_t > 0.0:
			_start_t -= delta
		elif Net.is_client():
			_tick_client(delta)
		else:
			_tick_mine(delta)
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
	var show := _build_t > 0.9
	_bit.visible = show
	for mi in _tubes:
		(mi as Node3D).visible = show
	if done:
		_build_t = -1.0
		for p in _parts:
			(p[0] as Node3D).transform = p[1]
		if Game.sfx:
			Game.sfx.play_at("impact", global_position, -4.0, 0.75, 14.0)
			Game.sfx.play_at("servo", global_position + global_transform.basis.y * HEAD_Y, -5.0, 0.7, 16.0)


## m³/s at depth d (enemy planet bonus included).
func _rate_at(d: float) -> float:
	var r := Balance.MINER_RATE_DRY
	if d < Balance.MINER_MAX_DEPTH - 0.001:
		r = Balance.MINER_RATE * (1.0 - Balance.MINER_RATE_DEEP_K * clampf(d / Balance.MINER_MAX_DEPTH, 0.0, 1.0))
	if body != null and _home_body != null and body != _home_body:
		r *= Balance.MINER_ENEMY_MULT
	return r


## Host / single player: sink, carve the shaft, fill the hopper, pay per load.
func _tick_mine(delta: float) -> void:
	var mx := Balance.MINER_MAX_DEPTH
	if depth < mx:
		var v := Balance.MINER_DESCENT * (1.0 - Balance.MINER_DESCENT_DEEP_K * depth / mx)
		var step := minf(v * delta, mx - depth)
		depth += step
		_since_brush += step
		if _since_brush >= Balance.MINER_DIG_STEP or depth >= mx:
			_since_brush = 0.0
			_carve()
	charge = depth / mx
	rate = _rate_at(depth)
	_hopper += rate * delta
	if _hopper >= Balance.MINER_HOPPER:
		_hopper -= Balance.MINER_HOPPER
		_pay(Balance.MINER_HOPPER)
		_dump(Balance.MINER_HOPPER)


## A client's copy: the host's depth (charge), the hopper faked from the same rate.
func _tick_client(delta: float) -> void:
	depth = move_toward(depth, charge * Balance.MINER_MAX_DEPTH, delta * 2.0)
	rate = _rate_at(depth)
	_hopper += rate * delta
	if _hopper >= Balance.MINER_HOPPER:
		_hopper -= Balance.MINER_HOPPER
		_dump(Balance.MINER_HOPPER)


## One DIG brush at the shaft bottom (logged for the enemy's scanner, synced in multiplayer).
func _carve() -> void:
	if body == null or not is_instance_valid(body):
		return
	var c: Vector3 = global_transform * Vector3(0, _ground_y - maxf(depth - 0.45, 0.25), 0)
	_digging = true
	Dig.dig_at(body, c, Balance.MINER_SHAFT_R, Dig.MODE_DIG, Balance.MINER_DIG_AMOUNT, Vector3.ZERO, Vector3.UP, -1.0, team)
	_digging = false


## A hopper load for the owner (header).
func _pay(amount: float) -> void:
	total_mined += amount
	produced.emit(owner_peer, amount)           # (host: net_world pays the remote player when he is on this team)
	# Team income (2026-10-06, the user: "ortak kurulan yapılar bize ve herkese versin"): EVERY player
	# of the miner's team gets the full load, not only its builder: the local one here, whoever built it.
	var pl = Game.player
	var local_team := Game.team_of(pl) if pl != null and is_instance_valid(pl) else "home"
	if team == local_team:
		Game.add_material(amount)
		return
	if owner_peer > 0:
		return                                  # a remote player's side: the network layer pays him
	for n in get_tree().get_nodes_in_group("war_rival_team"):
		if str(n.get("team")) == team and n.has_method("add_material"):
			n.add_material(amount)
			return


## The hopper dumps a load: the fill drops, dust under the gate, a clunk, "+N m³" rises over it.
func _dump(amount: float) -> void:
	_dump_t = 0.0
	var top: Vector3 = global_transform * (HOPPER + Vector3(0, HOPPER_TOP + 0.5, 0))
	var up := global_transform.basis.y.normalized()
	var lbl := Label3D.new()
	lbl.text = "+%d m³" % int(roundf(amount))
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.font_size = 64
	lbl.pixel_size = 0.004
	lbl.outline_size = 10
	lbl.modulate = Color(1.0, 0.8, 0.4)
	lbl.no_depth_test = false
	lbl.visible = Game.hud_mode() != 0           # (HUD Sade: no floating "+N"; MALZEME shows the gain)
	get_parent().add_child(lbl)
	lbl.global_position = top
	var tw := lbl.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "global_position", top + up * 1.6, 1.6).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 1.6).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lbl.queue_free)
	var gate: Vector3 = global_transform * (HOPPER + Vector3(0, HOPPER_TOP - 0.9, 0))
	BuildFx.dust(get_parent(), gate - up * 0.6, up, 0.7, Color(0.5, 0.44, 0.36))
	if Game.sfx:
		Game.sfx.play_at("impact_light", gate, -8.0, 0.7, 14.0)


# =================================================================================================
# Per frame (looks)
# =================================================================================================

func _animate(delta: float) -> void:
	var building := _build_t >= 0.0
	var on := not building and not is_destroyed and not has_meta("build_preview")
	var spin_up := on and _start_t <= 0.0
	var digging := spin_up and depth < Balance.MINER_MAX_DEPTH - 0.01
	var want := (1.0 if digging else (0.35 if spin_up else (0.2 if on and _start_t > 0.0 else 0.0)))
	_work = move_toward(_work, want, delta * 0.8)
	_shown_depth = lerpf(_shown_depth, depth, 1.0 - exp(-delta * 4.0))
	if not building:
		_update_string()
	# Spinning parts.
	_spin += (2.0 + 5.0 * _work) * _work * delta
	_bit.rotation.y = _spin
	_flywheel.rotation.x += (3.0 + 14.0 * _work) * _work * delta
	_fan_spin += (4.0 + 26.0 * _work) * (0.3 if on else 0.0) * delta
	_fan.rotation.z = _fan_spin
	# Conveyor: belt scroll and soil lumps riding up to the hopper.
	var belt_v := 0.55 * _work
	_belt_t += belt_v * delta
	_belt_mat.uv1_offset = Vector3(0.0, -_belt_t * 2.0, 0.0)
	var bl := _belt_a.distance_to(_belt_b)
	var dirb := (_belt_b - _belt_a) / maxf(bl, 0.01)
	for i in _lumps.size():
		var lm: MeshInstance3D = _lumps[i]
		var u := fmod(_belt_t / maxf(bl, 0.01) + float(i) / float(_lumps.size()), 1.0)
		lm.visible = _work > 0.25 and not building
		lm.position = _belt_a + dirb * (u * bl) + Vector3(0, 0.07, 0)
		lm.rotation = Vector3(u * 9.0, float(i), 0.0)
	# Hopper fill (drops quickly on a dump).
	var fill := clampf(_hopper / Balance.MINER_HOPPER, 0.0, 1.0)
	if _dump_t >= 0.0:
		_dump_t += delta
		fill *= clampf(_dump_t / 0.5, 0.0, 1.0)
		if _dump_t > 0.5:
			_dump_t = -1.0
	_fill.visible = fill > 0.02 and not building
	if _fill.visible:
		var h := 0.7 * fill
		_fill.scale = Vector3(lerpf(0.55, 1.0, fill), maxf(fill, 0.02), lerpf(0.55, 1.0, fill))
		_fill.position = Vector3(0, HOPPER_TOP - 0.76 + h * 0.5, 0)
	# Dust and smoke.
	_plume.emitting = digging and _work > 0.4
	_head_dust.emitting = digging and _work > 0.4
	_head_dust.position = _bit.position + Vector3(0, 0.4, 0)
	var up := global_transform.basis.y.normalized()
	_plume.gravity = -up * 0.6
	_head_dust.gravity = -up * 0.3
	_smoke.gravity = up * 0.4
	_smoke.emitting = on and _work > 0.1
	# Lights: work lamps down the shaft, the cutter's lamp, the beacon (amber blinking while it digs,
	# the team colour when dry), status lamps.
	for sp in _spots:
		(sp as SpotLight3D).light_energy = lerpf((sp as SpotLight3D).light_energy, 3.0 if on else 0.0, 1.0 - exp(-delta * 3.0))
	_lens_mat.emission_energy_multiplier = 3.0 if on else 0.6
	_bit_light.light_energy = (1.6 + 0.6 * sin(_t * 23.0) * _work) if on else 0.0
	if digging:
		var blink := 1.0 if fmod(_t, 0.8) < 0.4 else 0.15
		_beacon.light_color = AMBER
		_beacon.light_energy = 1.2 * blink
		_beacon_mat.emission = AMBER
		_beacon_mat.emission_energy_multiplier = 5.0 * blink
	elif on:
		var pulse := 0.6 + 0.4 * sin(_t * 2.0)
		_beacon.light_color = _col_team
		_beacon.light_energy = 0.8 * pulse
		_beacon_mat.emission = _col_team
		_beacon_mat.emission_energy_multiplier = 3.0 * pulse
	else:
		_beacon.light_energy = 0.0
	_strip_mat.emission_energy_multiplier = (1.5 + 1.5 * _work) if on else 0.4
	for i in _lamp_mats.size():
		var lm2: StandardMaterial3D = _lamp_mats[i]
		var lit := false
		match i:
			0:
				lit = on and fmod(_t, 1.0) < 0.5
			1:
				lit = digging and fmod(_t * 3.0, 1.0) < 0.5
			2:
				lit = _hit_t > 0.05 or (on and not digging)
		lm2.emission_energy_multiplier = 4.0 if lit else 0.3
	# Sound: the motor, the grinding (fainter as the cutter goes deeper).
	if on and not _hum.playing:
		_hum.play()
	if _hum.playing:
		_hum.volume_db = lerpf(_hum.volume_db, linear_to_db(0.1 + 0.3 * _work) if on else -80.0, 1.0 - exp(-delta * 3.0))
		_hum.pitch_scale = 0.6 + 0.5 * _work
		if not on and _hum.volume_db < -60.0:
			_hum.stop()
	if digging and not _grind.playing:
		_grind.play()
	if _grind.playing:
		var g := (-6.0 - _shown_depth * 0.8) if digging else -80.0
		_grind.volume_db = lerpf(_grind.volume_db, g, 1.0 - exp(-delta * 3.0))
		_grind.pitch_scale = 0.75 + 0.2 * _work
		_grind.position = Vector3(0, _ground_y - _shown_depth * 0.5, 0)
		if not digging and _grind.volume_db < -60.0:
			_grind.stop()
	var txt := _screen_text(building)
	if _screen.text != txt:
		_screen.text = txt


func _screen_text(building: bool) -> String:
	if building:
		return "OTOMATİK KAZICI\nKURULUYOR"
	if is_destroyed:
		return ""
	if _start_t > 0.0:
		return "OTOMATİK KAZICI\nISINIYOR"
	var per_min := int(roundf(rate * 60.0))
	if depth >= Balance.MINER_MAX_DEPTH - 0.01:
		return "KURUDU · %d m³/dk\nDERİNLİK %d m" % [per_min, int(Balance.MINER_MAX_DEPTH)]
	return "ÜRETİM %d m³/dk\nDERİNLİK %s m" % [per_min, String.num(depth, 1)]


# =================================================================================================
# Damage, ground
# =================================================================================================

func hud_name() -> String:
	return "Otomatik Kazıcı" if Game.team_of(self) == Game.team_of(Game.player) else "Düşman Otomatik Kazıcısı"


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
		if Game.team_of(self) == Game.team_of(Game.player):
			Game.hud.show_message("Otomatik kazıcımız yok edildi!", 2.5)
		else:
			Game.hud.show_message("Düşman otomatik kazıcısı yok edildi!", 2.5)
	destroyed.emit(self)
	Explosion.spawn(global_position + global_transform.basis.y * 1.4, global_transform.basis.y,
			{"radius": 4.5, "damage": 25.0, "impulse": 7.0, "crater": 0.0, "player_owned": false})
	remove_from_group("war_structure")
	remove_from_group(GROUP)
	remove_from_group(Game.DAMAGEABLE)
	queue_free()


## Ground point under the shaft (world): the density surface below the centre.
## (Foundation.ground_offset: the terrain collision, else the density; the old cheap march skipped
## the ±1.3 m detail noise.)
func _ground_point() -> Vector3:
	var up := global_transform.basis.y.normalized()
	var o := global_position
	if body != null and is_instance_valid(body):
		var off := Foundation.ground_offset(self, body, o, up, 2.5, 3.0)
		if not is_inf(off):
			return o + up * off
	return o


## Foundation (scripts/war/foundation.gd): a pile under each leg pad (the pads sit at the shaft's
## ground height; a corner over lower ground gets a pile down to it).
func _leg_piles() -> Array:
	var piles: Array = []
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			piles.append([Vector3(FRAME * sx, _ground_y, FRAME * sz), 0.09])
	return piles


## Ground dug away near the feet: settle onto what is left (its own shaft never reaches the feet).
func _on_brush(center: Vector3, r: float) -> void:
	if is_destroyed or _ground_check or _digging:
		return
	var up := global_transform.basis.y.normalized()
	var rel := center - global_position
	var radial := (rel - up * rel.dot(up)).length()
	if radial < Balance.MINER_SHAFT_R + 0.3 and rel.dot(up) < _ground_y:
		return                                 # the shaft (the host's carving replayed here)
	if center.distance_to(global_position) < r + FRAME * 1.42 + 2.0:
		_ground_check = true
		_settle.call_deferred()


func _settle() -> void:
	await get_tree().create_timer(1.2).timeout
	_ground_check = false
	if is_destroyed or body == null or not is_instance_valid(body) or not is_inside_tree():
		return
	var up: Vector3 = global_transform.basis.y.normalized()
	var drop := INF
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var f: Vector3 = global_transform * Vector3(FRAME * sx, _ground_y, FRAME * sz)
			var hit: Dictionary = body.raycast_density(f + up * 2.0, f - up * 30.0, 0.5)
			if hit.is_empty():
				continue
			drop = minf(drop, (f - (hit["position"] as Vector3)).dot(up))
	if drop == INF or drop < 0.4:
		_refit_foundation()                # a pad over the new hole gets its pile
		return
	var tw := create_tween()
	tw.tween_property(self, "global_position", global_position - up * drop, clampf(sqrt(drop) * 0.3, 0.2, 1.2)).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(_refit_foundation)


func _refit_foundation() -> void:
	if _foundation != null and is_instance_valid(_foundation):
		_foundation.refit(true)
