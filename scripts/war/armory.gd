extends Node3D
## Silahlık (armory), built with the İnşa Aracı (Balance.ARMORY_COST): a fortified weapons workshop.
## Model: a concrete pad, an armoured white / orange workshop module with sloped side plates and
## hazard-striped bay edges, a canopy with floodlights; inside the open bay (it faces whoever built
## it) a lit rack wall of guns, a work table with a glowing build plate and a fabricator gantry
## (rails, a carriage running along X, a telescopic arm with a nozzle that welds while crafting), a
## holo screen beside the bay with the state, heat-sink fins, an antenna and a beacon on the roof.
## Groups "damageable", "war_structure", "war_armory". take_damage(amount, from, impulse) -> {"dmg",
## "killed"}; destroyed at 0 hp (an explosion; a craft in progress is lost, its price comes back).
##   Armory.spawn(parent, body, xf, team, animate := true) -> armory
##
## Player (own team): F opens the Silahlık panel (scripts/war/craft_menu.gd). 2026-10-06: guns are no
## longer made here (the loadout and İkmal kapsülü give them); it sells permanent upgrades (drill
## tiers, İkmal İndirimi, Bomba Kemeri), grenades and attachments, and every purchase is INSTANT
## (start_craft(id) pays and Craft.grant()s at once); the fabricator then plays a short flourish
## (FX_T s: the arm sweeps, the print flashes up on the plate, the screen says TESLİM).
## Multiplayer: a structure like the cannon (net_world.gd: spawn by script path, hp, destroy). The
## craft queue is local to the machine whose player ordered it (each player crafts for himself);
## `crafting` / `craft_k` are the optional state for the fabricator look on the other machine.

const Balance := preload("res://scripts/war/balance.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const Craft := preload("res://scripts/war/craft.gd")
const CraftMenu := preload("res://scripts/war/craft_menu.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

const CYAN := Color(0.4, 0.88, 1.0)
const AMBER := Color(1.0, 0.62, 0.2)

signal destroyed(armory: Node3D)

var team := "home"
var body: Node3D
var hp := Balance.ARMORY_HP
var hp_max := Balance.ARMORY_HP
var is_destroyed := false
var crafting := false                     # a timed craft (none since purchases are instant; kept for net_world.gd)
var craft_k := 0.0                        # its progress 0..1
var job := {}                             # {"id", "t", "total", "local", "cost"}
const FX_T := 1.6                         # s of the fabricator's flourish after a purchase
var _fx_t := 0.0
var _fx_name := ""
# Read by the multiplayer structure sync like any structure's (unused here).
var _yaw_t := 0.0
var _pitch_t := 0.0
var tracking := false

var _hit_t := 0.0
var _t := 0.0
var _build_t := -1.0
var _parts: Array = []                    # [node, rest transform, delay]
var _paint: StandardMaterial3D
var _glow: StandardMaterial3D
var _plate: StandardMaterial3D
var _beam_mat: StandardMaterial3D
var _holo_mat: StandardMaterial3D
var _beacon_mat: StandardMaterial3D
var _carriage: Node3D
var _arm: Node3D
var _nozzle: Node3D
var _beam: MeshInstance3D
var _print: MeshInstance3D
var _print_mat: StandardMaterial3D
var _weld: OmniLight3D
var _bay_light: OmniLight3D
var _screen: Label3D
var _sparks: GPUParticles3D
var _hum: AudioStreamPlayer3D
var _zap_t := 0.0
var _ground_check := false


static func spawn(parent: Node, p_body: Node3D, xf: Transform3D, p_team: String, animate := true) -> Node3D:
	var a: Node3D = load("res://scripts/war/armory.gd").new()
	a.team = p_team
	a.body = p_body
	a.name = "Armory_" + p_team
	a.transform = xf
	parent.add_child(a)
	if animate:
		a.begin_assembly()
	return a


func _ready() -> void:
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_structure")
	add_to_group("war_armory")
	set_meta("footprint_r", Balance.ARMORY_FOOTPRINT)
	_build_model()
	_hum = AudioStreamPlayer3D.new()
	_hum.unit_size = 5.0
	_hum.max_distance = 40.0
	_hum.stream = Snd.loop("foley/motor_loop")
	_hum.volume_db = -80.0
	add_child(_hum)
	if body != null and body.has_signal("brush_applied"):
		body.brush_applied.connect(_on_brush)


# =================================================================================================
# Model (local frame: +Y up, the open bay faces +Z)
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


func _part(delay: float) -> Node3D:
	var n := Node3D.new()
	add_child(n)
	_parts.append([n, n.transform, delay])
	return n


func _build_model() -> void:
	_paint = _mat(Color(0.88, 0.89, 0.88), 0.05, 0.42)
	var orange := _mat(Color(0.95, 0.42, 0.08), 0.0, 0.5)
	var dark := _mat(Color(0.15, 0.16, 0.18), 0.6, 0.4)
	var gun := _mat(Color(0.1, 0.105, 0.115), 0.75, 0.32)
	var steel := _mat(Color(0.6, 0.62, 0.66), 0.85, 0.28)
	var concrete := _mat(Color(0.44, 0.43, 0.41), 0.0, 0.95)
	var floor_m := _mat(Color(0.24, 0.25, 0.27), 0.4, 0.7)
	var yellow := _mat(Color(0.95, 0.75, 0.12), 0.0, 0.55)
	var black := _mat(Color(0.04, 0.04, 0.045), 0.2, 0.7)
	_glow = _mat(CYAN, 0.0, 0.4, 3.0)
	_plate = _mat(CYAN, 0.0, 0.3, 1.2)
	_beacon_mat = _mat(AMBER, 0.0, 0.4, 0.5)

	# --- Pad: a concrete slab with a dark kerb and anchor bolts.
	var pad := _part(0.0)
	_box(pad, Vector3(0, 0.12, -0.1), Vector3(6.0, 0.24, 5.0), concrete)
	_box(pad, Vector3(0, 0.255, -0.1), Vector3(5.6, 0.03, 4.6), floor_m)
	for sx in [-1.0, 1.0]:
		_box(pad, Vector3(sx * 2.97, 0.17, -0.1), Vector3(0.08, 0.3, 5.0), dark)
		for sz in [-1.0, 1.0]:
			_cyl(pad, Vector3(sx * 2.7, 0.29, -0.1 + sz * 2.25), 0.06, 0.07, 0.06, steel)
	# Hazard stripes along the front edge of the bay floor.
	for i in 12:
		_box(pad, Vector3(-1.65 + i * 0.3, 0.275, 1.05), Vector3(0.15, 0.012, 0.2), yellow if i % 2 == 0 else black, Vector3(0, 0.6, 0))
	# Foundation: a concrete skirt from just inside the slab's edge down to the real ground under it
	# (slopes, dug ground; scripts/war/foundation.gd), dropped in with the slab.
	if body != null and not has_meta("build_preview"):
		_foundation = Foundation.create(self, body, _foundation_ring(), [], Color(0.4, 0.39, 0.37))
		_parts.append([_foundation, _foundation.transform, 0.0])

	# --- Shell: back wall, side walls, roof, front frame (the bay is open toward +Z).
	var shell := _part(0.25)
	_box(shell, Vector3(0, 1.55, -1.45), Vector3(4.2, 2.6, 0.3), _paint)
	for sx in [-1.0, 1.0]:
		_box(shell, Vector3(sx * 1.95, 1.55, -0.2), Vector3(0.3, 2.6, 2.8), _paint)
		# Sloped armour plates on the flanks with an orange band and a dark seam.
		_box(shell, Vector3(sx * 2.22, 1.05, -0.2), Vector3(0.22, 1.7, 2.9), _paint, Vector3(0, 0, sx * 0.24))
		_box(shell, Vector3(sx * 2.3, 1.4, -0.2), Vector3(0.05, 0.16, 2.92), orange, Vector3(0, 0, sx * 0.24))
		_box(shell, Vector3(sx * 2.23, 0.62, -0.2), Vector3(0.04, 0.03, 2.92), dark, Vector3(0, 0, sx * 0.24))
		# Front pillars with hazard stripes.
		_box(shell, Vector3(sx * 1.72, 1.4, 1.15), Vector3(0.36, 2.3, 0.36), dark)
		for k in 6:
			_box(shell, Vector3(sx * 1.72, 0.55 + k * 0.32, 1.335), Vector3(0.34, 0.14, 0.02), yellow if k % 2 == 0 else black,
					Vector3(0, 0, 0.45 * sx))
	_box(shell, Vector3(0, 2.72, -0.15), Vector3(4.3, 0.34, 3.2), _paint)
	_box(shell, Vector3(0, 2.92, -0.15), Vector3(4.1, 0.06, 3.0), dark)
	# Header over the bay: orange band, the name plate, a lit strip.
	_box(shell, Vector3(0, 2.42, 1.2), Vector3(3.8, 0.42, 0.3), _paint)
	_box(shell, Vector3(0, 2.42, 1.36), Vector3(3.8, 0.12, 0.02), orange)
	_box(shell, Vector3(0, 2.24, 1.32), Vector3(3.2, 0.03, 0.03), _glow)
	# Canopy over the front with two floodlights.
	_box(shell, Vector3(0, 2.82, 1.55), Vector3(4.4, 0.1, 0.9), dark, Vector3(-0.08, 0, 0))
	for sx in [-1.0, 1.0]:
		_cyl(shell, Vector3(sx * 1.3, 2.68, 1.7), 0.09, 0.12, 0.14, gun)
		_cyl(shell, Vector3(sx * 1.3, 2.6, 1.7), 0.085, 0.085, 0.02, _mat(Color(1.0, 0.95, 0.85), 0.0, 0.3, 2.5))
	# Corner bumpers.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(shell, Vector3(sx * 2.05, 2.72, -0.15 + sz * 1.55), Vector3(0.3, 0.42, 0.3), orange)

	# --- Interior: rack wall with guns, back-lit.
	var rack := _part(0.55)
	_box(rack, Vector3(0, 1.55, -1.28), Vector3(3.5, 2.1, 0.04), dark)
	for row in 2:
		var y := 1.05 + row * 0.85
		_box(rack, Vector3(0, y - 0.32, -1.22), Vector3(3.3, 0.04, 0.16), steel)       # shelf
		_box(rack, Vector3(0, y + 0.36, -1.255), Vector3(3.3, 0.025, 0.02), _glow)      # back light
		for i in 5:
			var x := -1.32 + i * 0.66
			_rack_gun(rack, Vector3(x, y, -1.18), row * 5 + i, gun, orange, dark)
	# Side lockers.
	for sx in [-1.0, 1.0]:
		_box(rack, Vector3(sx * 1.6, 1.1, -0.6), Vector3(0.3, 1.5, 0.9), _paint)
		_box(rack, Vector3(sx * 1.445, 1.1, -0.6), Vector3(0.01, 1.4, 0.82), dark)
		for k in 3:
			_box(rack, Vector3(sx * 1.44, 0.55 + k * 0.45, -0.25), Vector3(0.02, 0.05, 0.12), _glow)

	# --- Work table with the build plate.
	var table := _part(0.75)
	_box(table, Vector3(0, 0.6, -0.25), Vector3(1.8, 0.7, 1.0), dark)
	_box(table, Vector3(0, 0.97, -0.25), Vector3(1.9, 0.06, 1.1), _paint)
	_box(table, Vector3(0, 1.005, -0.25), Vector3(1.4, 0.012, 0.7), _plate)
	for k in 5:
		_box(table, Vector3(-0.56 + k * 0.28, 1.012, -0.25), Vector3(0.006, 0.004, 0.68), dark)
	_box(table, Vector3(0, 0.62, 0.26), Vector3(1.6, 0.06, 0.02), orange)
	# The printed gun: a hologram box growing on the plate.
	_print_mat = StandardMaterial3D.new()
	_print_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_print_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_print_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_print_mat.albedo_color = Color(CYAN, 0.55)
	_print_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_print = _box(table, Vector3(0, 1.08, -0.25), Vector3(1.0, 0.12, 0.22), _print_mat)
	_print.visible = false

	# --- Fabricator gantry: two rails, a carriage, a telescopic arm and a nozzle.
	var gantry := _part(0.95)
	for sz in [-1.0, 1.0]:
		_box(gantry, Vector3(0, 2.28, -0.25 + sz * 0.32), Vector3(3.4, 0.08, 0.08), steel)
	_carriage = Node3D.new()
	_carriage.position = Vector3(0, 2.28, -0.25)
	gantry.add_child(_carriage)
	_box(_carriage, Vector3(0, 0, 0), Vector3(0.32, 0.14, 0.78), orange)
	_box(_carriage, Vector3(0, -0.1, 0), Vector3(0.22, 0.08, 0.3), dark)
	_arm = Node3D.new()
	_carriage.add_child(_arm)
	_cyl(_arm, Vector3(0, -0.4, 0), 0.05, 0.05, 0.6, steel)
	_cyl(_arm, Vector3(0, -0.15, 0), 0.07, 0.07, 0.2, dark)
	_nozzle = Node3D.new()
	_nozzle.position = Vector3(0, -0.72, 0)
	_arm.add_child(_nozzle)
	_cyl(_nozzle, Vector3(0, 0.02, 0), 0.08, 0.05, 0.12, gun)
	_cyl(_nozzle, Vector3(0, -0.06, 0), 0.03, 0.012, 0.06, steel)
	_beam_mat = _mat(CYAN, 0.0, 0.3, 6.0)
	_beam = _cyl(_nozzle, Vector3(0, -0.2, 0), 0.01, 0.022, 0.24, _beam_mat)
	_beam.visible = false
	_weld = OmniLight3D.new()
	_weld.light_color = CYAN
	_weld.omni_range = 3.0
	_weld.light_energy = 0.0
	_weld.shadow_enabled = false
	_weld.position = Vector3(0, -0.3, 0)
	_nozzle.add_child(_weld)
	_sparks = GPUParticles3D.new()
	_sparks.amount = 24
	_sparks.lifetime = 0.45
	_sparks.emitting = false
	_sparks.local_coords = false
	_sparks.position = Vector3(0, -0.32, 0)
	_sparks.visibility_aabb = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))
	_sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 70.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 2.6
	pm.gravity = Vector3(0, -6, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	pm.color = Color(0.7, 0.95, 1.0) * 3.0
	_sparks.process_material = pm
	var sq := QuadMesh.new()
	sq.size = Vector2(0.01, 0.05)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.vertex_color_use_as_albedo = true
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sq.material = sm
	_sparks.draw_pass_1 = sq
	_nozzle.add_child(_sparks)

	# --- Holo screen on the right pillar: a frame, a translucent cyan pane, the state text.
	var scr := _part(1.1)
	_box(scr, Vector3(2.05, 1.62, 1.42), Vector3(0.06, 0.62, 0.86), dark, Vector3(0, -0.5, 0))
	_holo_mat = StandardMaterial3D.new()
	_holo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_holo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_holo_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_holo_mat.albedo_color = Color(CYAN, 0.35)
	_holo_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pane := _box(scr, Vector3(2.12, 1.62, 1.47), Vector3(0.005, 0.52, 0.76), _holo_mat, Vector3(0, -0.5, 0))
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_screen = Label3D.new()
	_screen.text = "SİLAHLIK"
	_screen.font_size = 64
	_screen.pixel_size = 0.0026
	_screen.modulate = Color(0.75, 0.97, 1.0)
	_screen.outline_size = 0
	_screen.shaded = false
	_screen.no_depth_test = false
	_screen.position = Vector3(2.15, 1.62, 1.49)
	_screen.rotation = Vector3(0, PI * 0.5 - 0.5, 0)
	scr.add_child(_screen)

	# --- Roof: heat-sink fins, antenna, beacon.
	var roof := _part(1.25)
	for i in 9:
		_box(roof, Vector3(-1.2 + i * 0.3, 3.08, -0.7), Vector3(0.04, 0.3, 1.1), steel)
	_box(roof, Vector3(0, 2.98, -0.7), Vector3(2.7, 0.06, 1.2), dark)
	_cyl(roof, Vector3(1.6, 3.35, -1.2), 0.02, 0.03, 0.8, steel)
	_cyl(roof, Vector3(-1.6, 3.06, 0.9), 0.1, 0.12, 0.2, gun)
	_cyl(roof, Vector3(-1.6, 3.22, 0.9), 0.08, 0.1, 0.14, _beacon_mat)

	# Light in the bay (warm, soft).
	_bay_light = OmniLight3D.new()
	_bay_light.light_color = Color(0.75, 0.92, 1.0)
	_bay_light.omni_range = 4.5
	_bay_light.light_energy = 0.9
	_bay_light.shadow_enabled = false
	_bay_light.position = Vector3(0, 2.0, -0.4)
	add_child(_bay_light)

	for mi in find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).material_override != _print_mat and (mi as MeshInstance3D).material_override != _holo_mat \
				and (mi as MeshInstance3D).material_override != _beam_mat:
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Collision (an obstacle on the ship layer, like the other structures) + interaction.
	var sb := StaticBody3D.new()
	sb.collision_layer = Game.LAYER_SHIP
	sb.collision_mask = 0
	sb.set_meta("interact_target", self)
	for c in [[Vector3(0, 1.55, -1.45), Vector3(4.2, 2.6, 0.3)], [Vector3(-1.95, 1.55, -0.2), Vector3(0.6, 2.6, 2.9)],
			[Vector3(1.95, 1.55, -0.2), Vector3(0.6, 2.6, 2.9)], [Vector3(0, 2.75, -0.15), Vector3(4.4, 0.4, 3.2)],
			[Vector3(0, 0.6, -0.25), Vector3(1.9, 1.0, 1.1)],
			[Vector3(-1.72, 1.4, 1.15), Vector3(0.36, 2.3, 0.36)], [Vector3(1.72, 1.4, 1.15), Vector3(0.36, 2.3, 0.36)]]:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = c[1]
		cs.shape = bs
		cs.position = c[0]
		sb.add_child(cs)
	# The pad: a low frustum with ~40° edges (walkable: the player has no step-up), its top flush
	# with the bay floor, its base below the ground.
	var pad_cs := CollisionShape3D.new()
	var cv := ConvexPolygonShape3D.new()
	var pts := PackedVector3Array()
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			pts.append(Vector3(sx * 3.0, -0.35, -0.1 + sz * 2.5))
			pts.append(Vector3(sx * 2.35, 0.27, -0.1 + sz * 1.85))
	cv.points = pts
	pad_cs.shape = cv
	sb.add_child(pad_cs)
	add_child(sb)


## One gun silhouette on the rack (a few kinds by index), muzzle up.
func _rack_gun(parent: Node3D, pos: Vector3, i: int, gun: Material, orange: Material, dark: Material) -> void:
	var g := Node3D.new()
	g.position = pos
	g.rotation = Vector3(0, 0, 0.08 * (1 if i % 2 == 0 else -1))
	parent.add_child(g)
	var kind := i % 4
	var length: float = [0.62, 0.5, 0.78, 0.56][kind]
	_box(g, Vector3(0, 0.0, 0), Vector3(0.07, length, 0.05), _paint if kind != 2 else gun)
	_box(g, Vector3(0, length * 0.5 + 0.1, 0), Vector3(0.022, 0.22 if kind != 1 else 0.12, 0.022), dark)
	_box(g, Vector3(0.045, -0.05, 0), Vector3(0.02, 0.12, 0.04), orange)
	_box(g, Vector3(0, -length * 0.5 - 0.06, 0), Vector3(0.06, 0.12, 0.045), dark)
	if kind == 2:
		_cyl(g, Vector3(-0.055, 0.05, 0), 0.03, 0.03, 0.25, dark)          # scope
	if kind == 3:
		_cyl(g, Vector3(0, length * 0.5 + 0.06, 0), 0.06, 0.05, 0.1, dark)  # emitter dish


## Parts drop into place over ~1.8 s (built with the tool).
func begin_assembly() -> void:
	BuildFx.assemble(get_parent(), global_transform, Vector3(3.0, 1.8, 2.6), BuildFx.AUTO, self)
	_build_t = 0.0
	for p in _parts:
		var n: Node3D = p[0]
		n.visible = false


# =================================================================================================
# Crafting
# =================================================================================================

func is_ready() -> bool:
	return _build_t < 0.0 and not is_destroyed


## Buys `id` for the local player: pays and grants it at once (Craft.grant), then the fabricator's
## flourish. Returns "" or why it cannot. (Name kept for its callers: craft_menu, attachments_panel.)
func start_craft(id: String) -> String:
	if not is_ready():
		return "Silahlık hazır değil"
	var why := Craft.blocked(id)
	if why != "":
		return why
	var r := Craft.recipe(id)
	if r.is_empty():
		return "Bilinmeyen tarif"
	var cost := float(r["cost"])
	if not Game.spend_material(cost):
		return "Yetersiz malzeme"
	Craft.grant(id)
	_fx_t = FX_T
	_fx_name = str(r.get("name", ""))
	if Game.sfx:
		Game.sfx.play_at("servo", global_position, -6.0, 1.1, 8.0)
	return ""


## Seconds left of the running craft (0 when idle).
func time_left() -> float:
	if not crafting or job.is_empty():
		return 0.0
	return maxf(float(job["total"]) - float(job["t"]), 0.0)


func _finish_craft() -> void:
	var id := str(job.get("id", ""))
	var local := bool(job.get("local", false))
	job = {}
	crafting = false
	craft_k = 0.0
	if local and id != "":
		Craft.grant(id)
	if Game.sfx:
		Game.sfx.play_at("impact_light", global_position, -6.0, 1.3, 8.0)


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	if _build_t >= 0.0:
		_tick_assembly(delta)
	_fx_t = maxf(_fx_t - delta, 0.0)
	if crafting and not job.is_empty():
		job["t"] = float(job["t"]) + delta
		craft_k = clampf(float(job["t"]) / maxf(float(job["total"]), 0.1), 0.0, 1.0)
		if float(job["t"]) >= float(job["total"]):
			_finish_craft()
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
		var k := clampf((_build_t - float(p[2])) / 0.7, 0.0, 1.0)
		n.visible = k > 0.0
		var e := 1.0 - pow(1.0 - k, 3.0)
		n.transform = (p[1] as Transform3D).translated_local(Vector3(0, 2.5 * (1.0 - e), 0)).scaled_local(Vector3.ONE * lerpf(0.6, 1.0, e))
		if k < 1.0:
			done = false
	if done:
		_build_t = -1.0
		for p in _parts:
			(p[0] as Node3D).transform = p[1]
		if Game.sfx:
			Game.sfx.play_at("impact", global_position, -4.0, 0.7, 14.0)


## The fabricator: idle it parks and the plate breathes; crafting the carriage sweeps along the
## rails, the arm bobs, the nozzle welds (beam, sparks, a cyan flicker), the print grows.
func _animate(delta: float) -> void:
	var on := crafting or _fx_t > 0.0
	var k := craft_k if crafting else clampf(1.0 - _fx_t / FX_T * 0.6, 0.0, 1.0)
	var cx := 0.0
	var arm_y := 0.0
	if on:
		cx = sin(_t * 1.7) * 0.5 + sin(_t * 4.3) * 0.08
		arm_y = -0.12 - 0.06 * sin(_t * 6.0)
	else:
		cx = lerpf(_carriage.position.x, 1.35, 1.0 - exp(-2.0 * delta))
	_carriage.position.x = lerpf(_carriage.position.x, cx, 1.0 - exp(-8.0 * delta)) if on else cx
	_arm.position.y = lerpf(_arm.position.y, arm_y, 1.0 - exp(-6.0 * delta))
	var flick := 0.6 + 0.4 * sin(_t * 53.0) * sin(_t * 31.0)
	_beam.visible = on
	_weld.light_energy = (1.6 * flick) if on else 0.0
	if _sparks.emitting != on:
		_sparks.emitting = on
	_plate.emission_energy_multiplier = (2.2 + 0.8 * sin(_t * 5.0)) if on else (0.9 + 0.3 * sin(_t * 1.3))
	_print.visible = on
	if on:
		var h := lerpf(0.02, 0.14, k)
		_print.scale = Vector3(lerpf(0.15, 1.0, minf(k * 1.6, 1.0)), h / 0.12, 1.0)
		_print.position.y = 1.012 + h * 0.5
		_print_mat.albedo_color = Color(CYAN, 0.35 + 0.25 * flick)
		_zap_t -= delta
		if _zap_t <= 0.0 and Game.sfx:
			_zap_t = randf_range(0.35, 0.7)
			Game.sfx.play_at("impact_light", _nozzle.global_position, -18.0, randf_range(1.5, 2.2), 4.0)
	_hum.volume_db = linear_to_db(0.25) if on else -80.0
	if on and not _hum.playing:
		_hum.play()
	elif not on and _hum.playing:
		_hum.stop()
	# Beacon: slow amber blink while working, dim otherwise.
	_beacon_mat.emission_energy_multiplier = (4.0 if fmod(_t, 0.8) < 0.4 else 0.4) if on else 0.4
	# Holo screen text.
	var txt := "SİLAHLIK\nHAZIR"
	if _build_t >= 0.0:
		txt = "SİLAHLIK\nKURULUYOR"
	elif _fx_t > 0.0 and not crafting:
		txt = "%s\nTESLİM" % _fx_name.to_upper()
	elif on:
		txt = "%s\n%d%%" % [str(job.get("name", "")).to_upper(), int(k * 100.0)]
	if _screen.text != txt:
		_screen.text = txt


# =================================================================================================
# Interaction (player.gd interact ray: the collider's meta "interact_target")
# =================================================================================================

func _usable() -> bool:
	return Game.team_of(self) == Game.team_of(Game.player) if Game.player != null else team == "home"


func get_interact_prompt() -> String:
	if not _usable():
		return ""
	if _build_t >= 0.0:
		return "Silahlık kuruluyor…"
	if crafting:
		var nm := str(job.get("name", "")) if not job.is_empty() else "arkadaşın"
		return "Silahlık: %s üretiliyor %d%%" % [nm, int(craft_k * 100.0)]
	return "Silahlık: kalıcı gelişmeler · yükleme · ikmal · eklentiler"


func interact(p) -> void:
	if not _usable() or is_destroyed or _build_t >= 0.0:
		return
	var menu = CraftMenu.open_for(self)
	if menu == null and Game.sfx:
		Game.sfx.play("error", -10.0)
	if p != null and p.has_method("hands_busy") and p.hands_busy() and p.get("hand_action") != null:
		p.hand_action.cancel()


func hud_name() -> String:
	return "Silahlık"


# =================================================================================================
# Damage, ground
# =================================================================================================

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
	if crafting and bool(job.get("local", false)):
		var back := float(job.get("cost", 0.0)) * Balance.CRAFT_REFUND
		if back > 0.0:
			Game.add_material(back)
		if Game.hud:
			Game.hud.alert("Silahlık yok edildi — %s üretimi iptal (+%d m³)" % [str(job.get("name", "")), int(back)], 2, "armory", 3.0)
	elif Game.hud and Game.team_of(self) == "home":
		Game.hud.alert("Silahlığımız yok edildi!", 2, "armory", 2.5)
	crafting = false
	job = {}
	destroyed.emit(self)
	Explosion.spawn(global_position + global_transform.basis.y * 1.5, global_transform.basis.y,
			{"radius": 5.5, "damage": 30.0, "impulse": 8.0, "crater": 0.0, "player_owned": false})
	remove_from_group("war_structure")
	remove_from_group("war_armory")
	remove_from_group(Game.DAMAGEABLE)
	queue_free()


## The ground under the pad was dug away: settle onto what is left (like the cannon).
func _on_brush(center: Vector3, r: float) -> void:
	if is_destroyed or _ground_check:
		return
	if center.distance_to(global_position) < r + Balance.ARMORY_FOOTPRINT + 2.0:
		_ground_check = true
		_settle.call_deferred()


const Foundation := preload("res://scripts/war/foundation.gd")
var _foundation: Node3D                   # concrete skirt under the slab (scripts/war/foundation.gd)


## Sinks only when under a quarter of the slab still has ground (Foundation.support_drop, never up), then
## the skirt refits to the new ground.
func _settle() -> void:
	await get_tree().create_timer(1.2).timeout
	_ground_check = false
	if is_destroyed or body == null or not is_inside_tree():
		return
	var up: Vector3 = global_transform.basis.y.normalized()
	var pts := _foundation_ring()
	pts.append(Vector3(0, 0, -0.1))
	var drop := Foundation.support_drop(self, body, pts)
	if drop > 0.4:
		var tw := create_tween()
		tw.tween_property(self, "global_position", global_position - up * drop, clampf(sqrt(drop) * 0.3, 0.2, 1.2)).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(_refit_foundation)
	else:
		_refit_foundation()


## The slab's outline just inside its edge (local), 3 segments a side.
func _foundation_ring() -> PackedVector3Array:
	return Foundation.rect(-2.95, 2.95, -2.55, 2.35, 0.05, 6, 5)


func _refit_foundation() -> void:
	if _foundation != null and is_instance_valid(_foundation):
		_foundation.refit(true)
