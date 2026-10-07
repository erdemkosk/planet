extends Node3D
## Sondaj Torpidosu: a drilling torpedo. The player's comes from a Sondaj Kulesi built on the enemy
## planet (scripts/war/torpedo_rig.gd -> Torpedo.plant(): no flight, it starts at PLANT under the
## rig). Fired ones (the old hand launcher scripts/items/torpedo_launcher.gd, out of the loadout now;
## the rival AI while Balance.AI_TORPEDO_LAUNCHES) go through fire(). A fired one flies like a cannon shell
## (Game.gravity_at, the same update as Ballistics; Ballistics.segment_hit on the nose's path every
## step) for up to Balance.TORPEDO_LIFE s: a white / orange (rival: gunmetal / red) body, a spinning
## fluted drill nose, fins, a glowing team band, a smoke / ember trail and a halo that stays a few
## pixels wide from the other planet.
##
## Landing (the nose touches the ground):
##   - on a planet whose core (group "war_core", core.body == that planet) belongs to ANOTHER team it
##     noses over toward that core (PLANT, ~PLANT_TIME s) and burrows (BURROW);
##   - on its own team's planet (or when that core is already gone) it is a dud: a puff, it lies there;
##   - on a structure / character (a physics body that is not terrain) it goes off on contact.
## Burrowing: Balance.TORPEDO_BURROW_SPEED m/s along a slowly weaving path toward the core (harder to
## intercept), carving its tunnel with Dig.dig_at(..., team) ~8 times a second (so it lands in
## scripts/war/tunnel_log.gd for the enemy's Tünel tarayıcı); a dust plume and clods out of the entry
## hole, sparks and grit at the head, a loud drill whine + grinding loop + rock crunches
## (AudioStreamPlayer3D, max_distance TORPEDO_HEAR_RANGE: no occlusion, so it is heard through the
## rock) and a ground rumble (camera trauma) for a player nearby.
## Reaching the core (REACH m from its surface): a big underground Explosion.spawn, the core takes the
## full TORPEDO_CORE_DAMAGE (Core.blast_all at the core's centre with a 1 m "crater": only that core
## is in reach), a crater at the tunnel's end, a gout of dust out of the entry hole.
## Vulnerable (hp TORPEDO_HP, groups "damageable" + "war_torpedo"): a StaticBody3D capsule on
## Game.LAYER_PLAYER (the layer bullets hit; the player's own movement ignores it) whose parent is
## this node, so Game.damageable_of(collider) finds it; area damage (Explosion / Game.area_damage);
## and an ENEMY brush overlapping it (planet.brush_applied: drills, craters) at TORPEDO_DRILL_DPS.
## Its own carving (and an allied torpedo's) is ignored: a static flag is set around the dig call,
## plus the last carve centres (a brush the network applies later). In flight it is also in group
## "war_shell" with team / vel / is_live() / shot_down(pos), so an Uçaksavar's point defence
## (scripts/war/flak.gd + flak_round.gd) can burst it. Dying: a small blast (no core damage) and a
## HUD message.
##
## Public API (the war HUD, the tunnel scanner and later the AI read it):
##   Torpedo.fire(parent, from, vel, team, exclude_rids := []) -> the torpedo
##   Torpedo.plant(parent, point, dir, team, planet) -> the torpedo, set in at `point` (drill tip on the
##                   ground) pointing along dir, already at PLANT (emits events().launched first)
##   planted         true for a planted one (no launch whoosh / flight trail, its own HUD lines)
##   team, vel (while flying), hp, hp_max, body (planet it burrows in), core (its target core)
##   is_live()       flying or burrowing (false once dead, a dud or done)
##   is_flying(), is_burrowing(), is_dead()
##   depth()         m of the drill head below the ORIGINAL (generated) surface
##   core_distance() m from the drill head to the target core's surface (flying: the nearest enemy
##                   core; INF when there is none)
##   progress()      0..1 of the way from the entry hole to the core (burrowing)
##   tip_position()  world position of the drill head
##   take_damage(amount, from_pos, impulse) -> {"dmg", "killed"}
##   Torpedo.drill_mesh(length, radius) -> a fluted drill bit ArrayMesh, base at z 0, tip at -length
##   (shared with the launcher's view model and the Delici Top's penetrators)
##
## Multiplayer (scripts/net/*; single player never touches any of this, Net.active is false):
##   Torpedo.events().launched(torpedo, from, vel, team)  every Torpedo.fire() (the AI) and
##                   Torpedo.plant() (a rig: vel = dir × PLANT_VEL, |vel| < 2 m/s = planted) but NOT
##                   Torpedo.fire_replica(); connect once, number it, mirror it. A planted one's
##                   puppet lands at once and waits for the host's PLANT (set_remote_state).
##   torpedo.state_changed(torpedo, state)  FLY 0 -> PLANT 1 -> BURROW 2, or DUD 3 / DEAD 4 / DONE 5
##                   (send these reliably); net_state() -> {"state", "tip", "dir", "hp", "vel"} for
##                   the periodic update (a few Hz while burrowing).
##   net_id, net_puppet  a client's copy is a puppet: it flies and drills for the look only, waits on
##                   the ground for the host's word and is driven by set_remote_state(state, tip,
##                   dir, hp, vel). The HOST (or single player) alone carves the tunnel (Dig.dig_at,
##                   synced by the terrain hook), takes damage (a client's hits are claims through
##                   Game.damage_target), decides landing / death and damages the core.
##   Torpedo.fire_replica(parent, from, vel, team) -> a puppet that does not emit `launched`.

const Balance := preload("res://scripts/war/balance.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const Core := preload("res://scripts/war/core.gd")
const Dig := preload("res://scripts/player/dig.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const FlakRound := preload("res://scripts/war/flak_round.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

const GROUP := "war_torpedo"
const LENGTH := 1.25                 # m, nose tip to nozzle
const HALF := 0.625
const RADIUS := 0.09                 # body radius
const HIT_RADIUS := 0.32             # bullet capsule (generous: it sits in a 2 m tunnel)
const PLANT_TIME := 0.9              # s nosing over toward the core before it advances at full speed
const DIG_INTERVAL := 0.12           # s between tunnel brushes
const DIG_AMOUNT := 12.0             # density per brush (deep rock is clamped to -4: two passes carve it)
const WAVE := 0.3                    # weave of the path (rad-ish), fades out near the core
const REACH := 0.5                   # m from the core's surface: it hits
const DUD_LIFE := 8.0                # s a dud lies on the ground

enum { FLY, PLANT, BURROW, DUD, DEAD, DONE }
const STATE_NAMES := ["fly", "plant", "burrow", "dud", "dead", "done"]
const NET_WAIT := 3.0                # s a puppet that landed waits for the host before it gives up
const PLANT_VEL := 0.5               # m/s: plant()'s nominal velocity (anything under 2 m/s = planted)
const RUMBLE_RANGE := 50.0           # m from the drill head: the burrowing shakes the player (2026-10-06: 28 at R 30)

## Launch events of every torpedo (multiplayer sync, later anything that tracks them).
class Events extends RefCounted:
	signal launched(torpedo: Node3D, from: Vector3, vel: Vector3, team: String)

## Every state change (see the header).
signal state_changed(torpedo: Node3D, new_state: int)

static var _carving := ""            # team whose torpedo is carving right now (not an attack)
static var _meshes := {}
static var _events: Events
static var _quiet := false           # fire_replica(): no launched event

var team := "home"
var vel := Vector3.ZERO
var hp := Balance.TORPEDO_HP
var hp_max := Balance.TORPEDO_HP
var exclude: Array = []              # RIDs the flight test ignores (the shooter, this torpedo)
var body: Node3D                     # planet it burrows in
var core: Node3D                     # its target
var state := FLY
var net_id := 0
var net_puppet := false              # multiplayer client copy: looks only (see the header)
var planted := false                 # set into the ground by a rig (plant(); a puppet: its slow vel)

var _net_tip := Vector3.ZERO         # puppet: the host's drill head / direction (extrapolated)
var _net_dir := Vector3.FORWARD
var _net_wait := -1.0                # puppet: s since it landed locally, waiting for the host
var _life := 0.0
var _t := 0.0                        # s in the current state
var _vt := 0.0                       # visual clock
var _dir := Vector3.FORWARD
var _bx := Vector3.RIGHT             # previous basis x (keeps the roll continuous)
var _tip := Vector3.ZERO
var _entry := Vector3.ZERO
var _entry_up := Vector3.UP
var _start_dist := 1.0
var _spin := 0.0
var _spin_rate := 7.0
var _roll := 0.0
var _dig_t := 0.0
var _own_centers: Array = []
var _drill_last := -1.0
var _rumble_t := 0.0
var _crunch_t := 0.0
var _hit_t := 0.0
var _ph := Vector2.ZERO
var _col_team := Color.WHITE
var _soil := Color(0.45, 0.35, 0.24)

var _rig: Node3D                     # orientation (model -Z = flight / drilling direction)
var _model: Node3D
var _drill: Node3D
var _band_mat: StandardMaterial3D
var _halo: MeshInstance3D
var _light: OmniLight3D
var _spark_light: OmniLight3D
var _trail: GPUParticles3D
var _embers: GPUParticles3D
var _sparks: CPUParticles3D
var _grit: CPUParticles3D
var _plume: CPUParticles3D
var _clods: CPUParticles3D
var _col: StaticBody3D
var _drill_audio: AudioStreamPlayer3D
var _grind_audio: AudioStreamPlayer3D
var _crunch_audio: AudioStreamPlayer3D


## Launches a torpedo of `p_team` from world `from` with velocity `p_vel` under `parent`.
static func fire(parent: Node, from: Vector3, p_vel: Vector3, p_team: String, p_exclude: Array = []) -> Node3D:
	var t: Node3D = load("res://scripts/war/torpedo.gd").new()
	t.team = p_team
	t.vel = p_vel
	t.exclude = p_exclude.duplicate()
	t.name = "Torpedo_" + p_team
	parent.add_child(t)
	t.global_position = from
	if not _quiet:
		events().launched.emit(t, from, p_vel, p_team)
	return t


## Sondaj Kulesi (scripts/war/torpedo_rig.gd): a torpedo SET INTO the ground, no flight. Its drill
## tip at `point` (on the surface of `planet`), pointing along `dir` (down, toward the core); it
## starts at PLANT like a landed one (reusing _begin_burrow: no core of another team under it = a
## dud). events().launched fires first (centre, a slow velocity along dir), so the multiplayer layer
## numbers it, gets the PLANT state reliably and the client's puppet (fire_replica) is told to burrow.
## Host / single player only (a client's copy comes from the host).
static func plant(parent: Node, point: Vector3, dir: Vector3, p_team: String, planet: Node3D) -> Node3D:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.DOWN
	var v := d * PLANT_VEL
	var from := point - d * HALF
	var t: Node3D = load("res://scripts/war/torpedo.gd").new()
	t.team = p_team
	t.vel = v
	t.name = "Torpedo_" + p_team
	parent.add_child(t)
	t.global_transform = Transform3D(t.call("_orient", d), from)
	events().launched.emit(t, from, v, p_team)
	t.call("_begin_burrow", point, planet, t.call("_enemy_core", planet))
	return t


## Multiplayer: the other peer's torpedo, mirrored here (a puppet; no launched event).
static func fire_replica(parent: Node, from: Vector3, p_vel: Vector3, p_team: String) -> Node3D:
	_quiet = true
	var t: Node3D = fire(parent, from, p_vel, p_team, [])
	_quiet = false
	t.net_puppet = true
	return t


static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


func _ready() -> void:
	top_level = true
	add_to_group(GROUP)
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_shell")                 # flak point defence while it flies
	_ph = Vector2(randf() * TAU, randf() * TAU)
	_col_team = Color(0.35, 0.88, 1.0) if team == "home" else Color(1.0, 0.28, 0.14)
	_dir = vel.normalized() if vel.length_squared() > 0.01 else Vector3.FORWARD
	planted = vel.length_squared() < 4.0              # plant() / a planted one's puppet: no flight look
	_build_model()
	_build_fx()
	_build_audio()
	_build_collision()
	exclude.append(_col.get_rid())
	global_basis = _orient(_dir)
	if planted:
		_trail.emitting = false
		_embers.emitting = false
		_halo.visible = false


# =================================================================================================
# Public queries
# =================================================================================================

func is_live() -> bool:
	return state == FLY or state == PLANT or state == BURROW


func is_flying() -> bool:
	return state == FLY


func is_burrowing() -> bool:
	return state == PLANT or state == BURROW


func is_dead() -> bool:
	return state == DUD or state == DEAD or state == DONE


func tip_position() -> Vector3:
	if state == FLY:
		return global_position + _dir * HALF
	return _tip


func depth() -> float:
	var p := tip_position()
	var b: Node3D = body
	if b == null or not is_instance_valid(b):
		b = Game.dominant_body(p)
	if b == null:
		return 0.0
	var surf := float(b.radius) + float(b.surface_height_at(p))
	return maxf(surf - p.distance_to(b.global_position), 0.0)


func core_distance() -> float:
	var c: Node3D = core
	if c == null or not is_instance_valid(c):
		c = _nearest_enemy_core()
	if c == null:
		return INF
	return maxf(tip_position().distance_to(c.global_position) - Balance.CORE_RADIUS, 0.0)


func progress() -> float:
	if not is_burrowing():
		return 1.0 if state == DONE else 0.0
	return clampf(1.0 - (core_distance() - REACH) / _start_dist, 0.0, 1.0)


## Kill feed / hit marker name (scripts/items/hit_feel.gd display_name).
func hud_name() -> String:
	return "Sondaj torpidosu" if team == "home" else "Düşman torpidosu"


## Multiplayer: what the host sends about this torpedo.
func net_state() -> Dictionary:
	return {"state": state, "tip": tip_position(), "dir": _dir, "hp": hp, "vel": vel}


## Multiplayer client: the host's word on this (puppet) torpedo. state: FLY / PLANT / BURROW / DUD /
## DEAD / DONE; tip: drill head (world); dir: drilling / flight direction; p_vel: flight velocity.
func set_remote_state(st: int, tip: Vector3, dir: Vector3, p_hp: float, p_vel := Vector3.ZERO) -> void:
	if state == DEAD or state == DONE or state == DUD:
		return
	if p_hp < hp - 0.01:
		_hit_t = 1.0
	hp = p_hp
	if dir.length_squared() > 1e-4:
		_net_dir = dir.normalized()
	_net_tip = tip
	match st:
		FLY:
			if state == FLY:
				_net_wait = -1.0
				if p_vel.length_squared() > 0.01:
					vel = p_vel
				var c := tip - _net_dir * HALF
				if c.distance_to(global_position) > 2.0:
					global_position = c
		PLANT, BURROW:
			if state == FLY:
				var planet: Node3D = Game.dominant_body(tip)
				_dir = _net_dir
				_begin_burrow(tip, planet, _enemy_core(planet))
			if st == BURROW and state == PLANT:
				_set_state(BURROW)
		DUD:
			_dud(tip, _up_at(tip), Game.dominant_body(tip))
		DEAD:
			if state == FLY and _net_wait < 0.0:
				# Still in the air here: the flak got it (or it was lost in space).
				_leave_groups()
				_set_state(DEAD)
				FlakRound.burst_fx(get_parent(), global_position, 1.6)
				_finish(true)
			else:
				_tip = tip
				_blow_up(tip - _net_dir * 0.3, -_net_dir if is_burrowing() else _up_at(tip), is_burrowing(), "killed")
		DONE:
			if is_burrowing():
				_tip = tip
				_reach_core()


func _set_state(s: int) -> void:
	if state == s:
		return
	state = s
	state_changed.emit(self, s)


# =================================================================================================
# Model and effects
# =================================================================================================

func _mat(c: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	return m


func _mesh(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, b := Basis()) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = Transform3D(b, pos)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


## Cylinder along -Z (r_front at the -Z end) centred at z.
func _zcyl(parent: Node3D, z: float, r_front: float, r_back: float, h: float, mat: Material, seg := 18) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r_front
	c.bottom_radius = r_back
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return _mesh(parent, c, mat, Vector3(0, 0, z), Basis(Vector3.RIGHT, -PI * 0.5))


## The torpedo along the rig's -Z: drill (z -0.625..-0.27, spins), cutter collar, body with two
## stripes and the glowing band, motor taper, nozzle, four fins.
func _build_model() -> void:
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
	_rig = Node3D.new()
	_rig.basis = Basis(Vector3.RIGHT, -PI * 0.5)      # model -Z -> this node's -Y (= -basis.y = _dir)
	add_child(_rig)
	_model = Node3D.new()
	_rig.add_child(_model)
	# Drill head (spins): fluted bit, cutter collar with carbide teeth.
	_drill = Node3D.new()
	_model.add_child(_drill)
	_mesh(_drill, drill_mesh(0.355, RADIUS * 1.06), steel, Vector3(0, 0, -0.27))
	_zcyl(_drill, -0.28, RADIUS * 1.12, RADIUS * 1.08, 0.05, carbide, 20)
	for i in 6:
		var a := TAU * float(i) / 6.0
		var bx := BoxMesh.new()
		bx.size = Vector3(0.022, 0.03, 0.05)
		_mesh(_drill, bx, carbide, Vector3(cos(a) * RADIUS * 1.1, sin(a) * RADIUS * 1.1, -0.29), Basis(Vector3.BACK, a))
	# Body.
	_zcyl(_model, 0.08, RADIUS, RADIUS, 0.68, paint, 20)
	for z in [-0.18, 0.3]:
		_zcyl(_model, z, RADIUS * 1.02, RADIUS * 1.02, 0.035, stripe, 20)
	var tm := TorusMesh.new()
	tm.inner_radius = RADIUS * 0.96
	tm.outer_radius = RADIUS * 1.12
	tm.rings = 24
	tm.ring_segments = 6
	_mesh(_model, tm, _band_mat, Vector3(0, 0, 0.06), Basis(Vector3.RIGHT, PI * 0.5))
	# Launch lugs along the top.
	for z in [-0.1, 0.2]:
		var lug := BoxMesh.new()
		lug.size = Vector3(0.02, 0.016, 0.06)
		_mesh(_model, lug, dark, Vector3(0, RADIUS + 0.006, z))
	# Motor taper, nozzle.
	_zcyl(_model, 0.49, RADIUS, RADIUS * 0.72, 0.14, dark, 18)
	_zcyl(_model, 0.585, RADIUS * 0.66, RADIUS * 0.78, 0.05, carbide, 18)
	# Fins (X layout).
	for i in 4:
		var a := TAU * (float(i) + 0.5) / 4.0
		var fin := Node3D.new()
		fin.rotation.z = a
		_model.add_child(fin)
		var fb := BoxMesh.new()
		fb.size = Vector3(0.008, 0.075, 0.17)
		_mesh(fin, fb, stripe if i % 2 == 0 else paint, Vector3(0, RADIUS + 0.035, 0.46))
		var tip := BoxMesh.new()
		tip.size = Vector3(0.01, 0.02, 0.06)
		_mesh(fin, tip, dark, Vector3(0, RADIUS + 0.07, 0.5))


func _build_fx() -> void:
	# Halo: a soft dot that never shrinks below a few pixels (follow it to the other planet).
	_halo = MeshInstance3D.new()
	_halo.mesh = DebrisMesh.quad_mesh()
	_halo.material_override = DebrisMesh.halo_material(_col_team, 1.8, 0.006, 7.0)
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.custom_aabb = AABB(Vector3.ONE * -50.0, Vector3.ONE * 100.0)
	add_child(_halo)
	_light = OmniLight3D.new()
	_light.light_color = _col_team
	_light.omni_range = 6.0
	_light.light_energy = 1.6
	_light.shadow_enabled = false
	_light.position = Vector3(0, 0, 0.06)
	_rig.add_child(_light)
	_spark_light = OmniLight3D.new()
	_spark_light.light_color = Color(1.0, 0.62, 0.3)
	_spark_light.omni_range = 5.0
	_spark_light.light_energy = 0.0
	_spark_light.shadow_enabled = false
	_spark_light.position = Vector3(0, 0, -0.75)
	_rig.add_child(_spark_light)
	# Trails from the nozzle (world space: left behind as it flies).
	_trail = _make_trail(Color(0.6, 0.58, 0.56, 0.45), 2.2, 0.75, 56)
	_embers = _make_trail(_col_team, 0.6, 0.2, 36)
	(_embers.process_material as ParticleProcessMaterial).color = _col_team * 2.0
	# Underground: sparks streaming back along the body, grit in the tunnel.
	_sparks = CPUParticles3D.new()
	_sparks.amount = 48
	_sparks.lifetime = 0.45
	_sparks.local_coords = false
	_sparks.emitting = false
	var sq := QuadMesh.new()
	sq.size = Vector2(0.025, 0.2)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sm.billboard_keep_scale = true
	sm.vertex_color_use_as_albedo = true
	sq.material = sm
	_sparks.mesh = sq
	_sparks.particle_flag_align_y = true
	_sparks.direction = Vector3(0, 0, 1)
	_sparks.spread = 70.0
	_sparks.initial_velocity_min = 3.0
	_sparks.initial_velocity_max = 9.0
	_sparks.damping_min = 2.0
	_sparks.damping_max = 4.0
	_sparks.gravity = Vector3.ZERO
	_sparks.scale_amount_min = 0.6
	_sparks.scale_amount_max = 1.4
	var sg := Gradient.new()
	sg.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	sg.colors = PackedColorArray([Color(3.0, 2.6, 1.8, 1.0), Color(2.4, 1.0, 0.3, 0.9), Color(0.8, 0.2, 0.05, 0.0)])
	_sparks.color_ramp = sg
	_sparks.position = Vector3(0, 0, -0.55)
	_rig.add_child(_sparks)
	_grit = CPUParticles3D.new()
	_grit.amount = 22
	_grit.lifetime = 1.4
	_grit.local_coords = false
	_grit.emitting = false
	var gq := QuadMesh.new()
	gq.size = Vector2(0.4, 0.4)
	var gm := StandardMaterial3D.new()
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	gm.vertex_color_use_as_albedo = true
	gm.roughness = 1.0
	gm.albedo_texture = DigFx.soft_texture()
	gq.material = gm
	_grit.mesh = gq
	_grit.direction = Vector3(0, 0, 1)
	_grit.spread = 100.0
	_grit.initial_velocity_min = 0.6
	_grit.initial_velocity_max = 2.2
	_grit.damping_min = 1.2
	_grit.damping_max = 2.0
	_grit.gravity = Vector3.ZERO
	_grit.scale_amount_min = 0.7
	_grit.scale_amount_max = 1.8
	var gg := Gradient.new()
	gg.set_color(0, Color(1, 1, 1, 0.65))
	gg.set_color(1, Color(1, 1, 1, 0.0))
	_grit.color_ramp = gg
	_grit.position = Vector3(0, 0, -0.45)
	_rig.add_child(_grit)


## World-space particle trail from the nozzle (shell.gd's look, smaller).
func _make_trail(col: Color, lifetime: float, size: float, amount: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3.ONE * -2000.0, Vector3.ONE * 4000.0)
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 180.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.7
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.5
	pm.damping_max = 1.0
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.5))
	sc.add_point(Vector2(1, 1.7))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, col.a))
	g.set_color(1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = col
	p.process_material = pm
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = DigFx.soft_texture()
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = mat
	p.draw_pass_1 = q
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = Vector3(0, 0, HALF)
	_rig.add_child(p)
	p.emitting = true
	return p


func _build_audio() -> void:
	_drill_audio = _audio3d(Snd.loop("foley/motor_loop"), 7.0, 5.0)
	_grind_audio = _audio3d(Snd.loop("shuttle/rumble"), 10.0, 7.0)
	_crunch_audio = _audio3d(Snd.rand("dig/mine", 1.1, 2.0), 9.0, 3.0)
	if vel.length_squared() < 4.0:
		return                                         # planted by a rig: no launch whoosh
	# The launch whoosh travels with it.
	var w := AudioStreamPlayer3D.new()
	w.stream = Snd.rand("whoosh/rocket", 1.06, 1.5)
	w.unit_size = 10.0
	w.max_distance = 220.0
	w.volume_db = -2.0
	add_child(w)
	w.play()


func _audio3d(st: AudioStream, unit: float, vol: float) -> AudioStreamPlayer3D:
	var a := AudioStreamPlayer3D.new()
	a.stream = st
	a.unit_size = unit
	a.max_distance = Balance.TORPEDO_HEAR_RANGE
	a.max_db = 6.0
	a.volume_db = vol
	add_child(a)
	return a


func _build_collision() -> void:
	_col = StaticBody3D.new()
	_col.collision_layer = Game.LAYER_PLAYER
	_col.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = HIT_RADIUS
	cap.height = LENGTH + 0.25
	cs.shape = cap                           # along this node's y = the torpedo's axis
	_col.add_child(cs)
	add_child(_col)


## Basis whose -y is `dir` (the model rig maps its -Z onto it); the roll follows the last one.
func _orient(dir: Vector3) -> Basis:
	var y := -dir.normalized()
	var x := _bx - y * _bx.dot(y)
	if x.length_squared() < 0.04:
		var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		x = ref.cross(y)
	x = x.normalized()
	_bx = x
	return Basis(x, y, x.cross(y))


# =================================================================================================
# Flight
# =================================================================================================

func _physics_process(delta: float) -> void:
	_hit_t = maxf(_hit_t - delta * 4.0, 0.0)
	match state:
		FLY:
			if _net_wait >= 0.0:
				# Puppet on the ground here: the host decides what happened.
				_net_wait += delta
				if _net_wait > NET_WAIT:
					_leave_groups()
					_set_state(DEAD)
					_finish(true)
			else:
				_fly(delta)
		PLANT, BURROW:
			_burrow(delta)


func _fly(delta: float) -> void:
	_life += delta
	var p := global_position
	var g: Vector3 = Game.gravity_at(p)
	var np := p + vel * delta + g * (delta * delta * 0.5)      # same update as Ballistics.predict
	vel += g * delta
	var nose := _dir * HALF
	var hit := Ballistics.segment_hit(p + nose, np + nose, get_world_3d().direct_space_state, exclude)
	if not hit.is_empty():
		if net_puppet:
			# Client copy: stop where it touched and wait for the host's landing / death.
			_tip = hit["position"]
			global_transform = Transform3D(_orient(_dir), _tip - _dir * HALF)
			_trail.emitting = false
			_embers.emitting = false
			_net_wait = 0.0
			return
		_land(hit)
		return
	if vel.length_squared() > 0.01:
		_dir = vel.normalized()
	global_transform = Transform3D(_orient(_dir), np)
	if _life > Balance.TORPEDO_LIFE:
		_lost()


## Destroyed in the air by an enemy flak burst (flak_round.gd point defence). On a multiplayer
## client the host's word does it (set_remote_state DEAD).
func shot_down(_by_pos: Vector3) -> void:
	if state != FLY or net_puppet or Net.is_client():
		return
	_set_state(DEAD)
	_leave_groups()
	FlakRound.burst_fx(get_parent(), global_position, 1.6)
	if Game.hud:
		Game.hud.show_message("Düşman torpidosu havada vuruldu!" if team == "rival" else "Torpidomuz havada vuruldu", 2.0)
	_finish(true)


func _lost() -> void:
	_set_state(DEAD)
	_leave_groups()
	if Game.hud and team == "home" and not net_puppet:
		Game.hud.show_message("Torpido ıskaladı — uzayda kayboldu", 2.0)
	_finish(true)


## The nose touched something (host / single player): burrow, dud or contact blast.
func _land(hit: Dictionary) -> void:
	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	remove_from_group("war_shell")
	_tip = point
	if not _is_ground(hit.get("body")):
		# A structure / character: the contact fuse.
		global_transform = Transform3D(_orient(_dir), point - _dir * HALF)
		_blow_up(point, normal, false, "contact")
		return
	var planet: Node3D = Game.dominant_body(point)
	var c := _enemy_core(planet)
	if c == null:
		_impact_fx(point, planet)
		_dud(point, _up_at(point), planet)
		return
	_begin_burrow(point, planet, c)


## Dust, clods and the thud where it hit the ground.
func _impact_fx(point: Vector3, planet: Node3D) -> void:
	if planet != null and planet.get("soil_color") is Color:
		_soil = planet.get("soil_color")
	_burst(get_parent(), point, _up_at(point), _soil, 1.0)
	if Game.sfx:
		Game.sfx.play_at("impact", point, 2.0, 0.6, 24.0)
		Game.sfx.play_at("mine", point, 0.0, 0.75, 18.0)


## Stuck in at `point` on `planet` with `c` (an enemy core) to drill for: noses over and starts.
## A puppet gets here from the host's word (no carving, no damage there).
func _begin_burrow(point: Vector3, planet: Node3D, c: Node3D) -> void:
	remove_from_group("war_shell")
	_impact_fx(point, planet)
	if planet == null or c == null:
		_dud(point, _up_at(point), planet)
		return
	_net_wait = -1.0
	body = planet
	core = c
	_tip = point
	_net_tip = point
	_entry = point
	_entry_up = _up_at(point)
	_start_dist = maxf(point.distance_to(c.global_position) - Balance.CORE_RADIUS - REACH, 1.0)
	_set_state(PLANT)
	_t = 0.0
	_dig_t = 0.0
	vel = Vector3.ZERO
	_spin_rate = 10.0
	if body.has_signal("brush_applied") and not body.brush_applied.is_connected(_on_brush):
		body.brush_applied.connect(_on_brush)
	_start_burrow_fx()
	if Game.hud:
		if team == "home" and planted:
			Game.hud.show_message("Sondaj torpidosu toprağa girdi — çekirdeğe kazıyor", 2.5)
		elif team == "home":
			Game.hud.show_message("Torpido %s gezegenine saplandı — çekirdeğe kazıyor" % str(planet.get("display_name")), 2.5)
		elif planted:
			Game.hud.show_message("DÜŞMAN SONDAJ KULESİ TORPİDOSU İNDİRDİ — çekirdeğe kazıyor!", 3.0)
		else:
			Game.hud.show_message("DÜŞMAN TORPİDOSU GEZEGENİMİZE SAPLANDI — çekirdeğe kazıyor!", 3.0)
	if Game.sfx:
		if team == "home":
			Game.sfx.play("select", -8.0, 1.1)
		else:
			Game.sfx.play("error", -4.0, 0.75)


## The ground (a planet from the density test, or a terrain / rock collider), not a structure.
static func _is_ground(hb) -> bool:
	if hb == null:
		return true
	if hb is Node and (hb as Node).has_method("raycast_density"):
		return true
	if hb is CollisionObject3D and ((hb as CollisionObject3D).collision_layer & Game.LAYER_TERRAIN) != 0:
		return true
	return false


## The core of `planet` when it belongs to another team and still stands.
func _enemy_core(planet: Node3D) -> Node3D:
	if planet == null:
		return null
	for c in get_tree().get_nodes_in_group(Core.GROUP):
		if c.get("body") == planet and str(c.get("team")) != team and not bool(c.get("destroyed")):
			return c as Node3D
	return null


func _nearest_enemy_core() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for c in get_tree().get_nodes_in_group(Core.GROUP):
		if str(c.get("team")) == team or bool(c.get("destroyed")):
			continue
		var d := global_position.distance_to((c as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = c
	return best


func _up_at(p: Vector3) -> Vector3:
	var b: Node3D = Game.dominant_body(p)
	if b == null:
		return Vector3.UP
	var u := p - b.global_position
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


# =================================================================================================
# Burrowing
# =================================================================================================

func _burrow(delta: float) -> void:
	if net_puppet:
		_burrow_puppet(delta)
		return
	if core == null or not is_instance_valid(core) or bool(core.get("destroyed")) or body == null or not is_instance_valid(body):
		_stall()
		return
	_t += delta
	var to_c := core.global_position - _tip
	var dist := to_c.length()
	var want := to_c / maxf(dist, 0.001)
	if state == PLANT:
		# Noses over toward the core while the drill spins up and bites in.
		var k := clampf(_t / PLANT_TIME, 0.0, 1.0)
		_dir = _dir.slerp(want, 1.0 - exp(-delta * 4.0)).normalized()
		_tip += _dir * Balance.TORPEDO_BURROW_SPEED * 0.35 * k * delta
		_spin_rate = lerpf(10.0, 34.0, k)
		if _t >= PLANT_TIME:
			_set_state(BURROW)
			_t = 0.0
	else:
		# Toward the core along a slow weave (fades out over the last metres so it arrives).
		var pb := _perp(want)
		var fade := clampf((dist - Balance.CORE_RADIUS - 3.0) / 8.0, 0.0, 1.0)
		var wob: Vector3 = ((pb[0] as Vector3) * sin(_t * 0.85 + _ph.x) + (pb[1] as Vector3) * sin(_t * 0.55 + _ph.y)) * WAVE * fade
		_dir = _dir.slerp((want + wob).normalized(), 1.0 - exp(-delta * 1.4)).normalized()
		_tip += _dir * Balance.TORPEDO_BURROW_SPEED * delta
	_dig_t -= delta
	if _dig_t <= 0.0:
		_dig_t = DIG_INTERVAL
		_carve()
	global_transform = Transform3D(_orient(_dir), _tip - _dir * HALF)
	_burrow_fx(delta)
	if core_distance() <= REACH:
		_reach_core()


## Multiplayer client copy: follows the host's drill head (extrapolated between its updates); the
## tunnel itself arrives through the terrain sync.
func _burrow_puppet(delta: float) -> void:
	_t += delta
	if state == PLANT:
		_spin_rate = lerpf(10.0, 34.0, clampf(_t / PLANT_TIME, 0.0, 1.0))
	else:
		_net_tip += _net_dir * Balance.TORPEDO_BURROW_SPEED * delta
	var k := 1.0 - exp(-delta * 6.0)
	_tip = _tip.lerp(_net_tip, k)
	_dir = _dir.slerp(_net_dir, k).normalized()
	global_transform = Transform3D(_orient(_dir), _tip - _dir * HALF)
	_burrow_fx(delta)


static func _perp(d: Vector3) -> Array:
	var ref := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var a := d.cross(ref).normalized()
	return [a, d.cross(a).normalized()]


## One tunnel brush just ahead of the head (logged for the enemy's scanner through `team`). Host /
## single player only: the terrain sync carries it to the client.
func _carve() -> void:
	if net_puppet or Net.is_client():
		return
	var c := _tip + _dir * 0.2
	_own_centers.append(c)
	if _own_centers.size() > 10:
		_own_centers.pop_front()
	_carving = team
	Dig.dig_at(body, c, Balance.TORPEDO_DIG_RADIUS, Dig.MODE_DIG, DIG_AMOUNT, Vector3.ZERO, Vector3.UP, -1.0, team)
	_carving = ""


## A brush on the planet: an enemy drill (or a crater) biting into the torpedo damages it.
func _on_brush(center: Vector3, radius: float) -> void:
	if not is_burrowing() or _carving == team or net_puppet or Net.is_client():
		return
	for c in _own_centers:
		if (c as Vector3).distance_squared_to(center) < 0.01:
			return
	var a := _tip - _dir * LENGTH
	var ab := _tip - a
	var u := clampf((center - a).dot(ab) / maxf(ab.length_squared(), 1e-4), 0.0, 1.0)
	var q := a + ab * u
	if q.distance_to(center) > radius + RADIUS + 0.15:
		return
	if team == "home" and _own_player_drilling(center):
		return
	# Rate independent: ~TORPEDO_DRILL_DPS however often the digger's brush ticks.
	var now := Time.get_ticks_msec() * 0.001
	var dt := clampf(now - _drill_last, 0.03, 0.25) if _drill_last >= 0.0 else 0.1
	_drill_last = now
	_grind_spark(q)
	Game.damage_target(self, Balance.TORPEDO_DRILL_DPS * dt, center, Vector3.ZERO)


## Our own player's drill near our own torpedo is not an attack.
func _own_player_drilling(center: Vector3) -> bool:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl):
		return false
	var tool = pl.get("tool")
	return tool != null and bool(tool.get("using")) and (pl as Node3D).global_position.distance_to(center) < 14.0


func take_damage(amount: float, _from_pos := Vector3.ZERO, _impulse := Vector3.ZERO) -> Dictionary:
	if is_dead() or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	if net_puppet or Net.is_client():
		# Multiplayer client: hp is the host's (set_remote_state); only the hit flash here.
		_hit_t = 1.0
		return {"dmg": amount, "killed": false}
	hp = maxf(hp - amount, 0.0)
	_hit_t = 1.0
	if hp <= 0.0:
		_blow_up(tip_position() - _dir * 0.3, -_dir if is_burrowing() else _up_at(global_position), is_burrowing(), "killed")
		return {"dmg": amount, "killed": true}
	return {"dmg": amount, "killed": false}


## Spun-up drill, sparks, plume, sounds; the first brush right away.
func _start_burrow_fx() -> void:
	_halo.visible = false
	_trail.emitting = false
	_embers.emitting = false
	_sparks.emitting = true
	_grit.color = _soil
	_grit.emitting = true
	_light.omni_range = 7.0
	var scene := get_parent()
	_plume = _entry_plume(_soil)
	scene.add_child(_plume)
	_plume.global_position = _entry + _entry_up * 0.3
	_clods = _entry_clods(_soil)
	scene.add_child(_clods)
	_clods.global_position = _entry + _entry_up * 0.2
	_drill_audio.pitch_scale = 0.9
	_drill_audio.play()
	_grind_audio.pitch_scale = 0.7
	_grind_audio.play()


## Continuous dust out of the entry hole (world-space vectors: the node is not rotated).
func _entry_plume(col: Color) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 40
	p.lifetime = 2.4
	p.local_coords = false
	var q := QuadMesh.new()
	q.size = Vector2(1.1, 1.1)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	p.mesh = q
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.5
	p.direction = _entry_up
	p.spread = 22.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 5.5
	p.damping_min = 0.6
	p.damping_max = 1.2
	p.gravity = -_entry_up * 1.0
	p.scale_amount_min = 0.8
	p.scale_amount_max = 2.4
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.5))
	sc.add_point(Vector2(1, 1.6))
	p.scale_amount_curve = sc
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	g.colors = PackedColorArray([Color(col.r, col.g, col.b, 0.0), Color(col.r, col.g, col.b, 0.55), Color(col.lightened(0.2).r, col.lightened(0.2).g, col.lightened(0.2).b, 0.0)])
	p.color_ramp = g
	p.visibility_aabb = AABB(Vector3.ONE * -40.0, Vector3.ONE * 80.0)
	p.emitting = true
	return p


## Clods thrown out of the entry hole while the head is shallow.
func _entry_clods(col: Color) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 18
	p.lifetime = 1.6
	p.local_coords = false
	var bm := BoxMesh.new()
	bm.size = Vector3(0.14, 0.11, 0.12)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	bm.material = mat
	p.mesh = bm
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.3
	p.direction = _entry_up
	p.spread = 30.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 7.0
	p.gravity = -_entry_up * 7.8
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.8
	p.angular_velocity_min = -300.0
	p.angular_velocity_max = 300.0
	p.particle_flag_rotate_y = true
	p.color = col.darkened(0.15)
	p.visibility_aabb = AABB(Vector3.ONE * -40.0, Vector3.ONE * 80.0)
	p.emitting = true
	return p


func _burrow_fx(delta: float) -> void:
	var d := depth()
	if _plume != null:
		# The plume out of the hole weakens as the head goes deeper.
		var k := clampf(1.0 - d / 14.0, 0.15, 1.0)
		_plume.initial_velocity_min = 1.5 * k
		_plume.initial_velocity_max = 5.5 * k
	if _clods != null:
		var kc := clampf(1.0 - d / 10.0, 0.0, 1.0)
		_clods.initial_velocity_max = 3.0 + 4.0 * kc
		_clods.emitting = kc > 0.05
	_drill_audio.pitch_scale = lerpf(_drill_audio.pitch_scale, 1.75 + 0.08 * sin(_vt * 7.0), 1.0 - exp(-delta * 3.0))
	_grind_audio.pitch_scale = 0.7 + 0.05 * sin(_vt * 2.3)
	_crunch_t -= delta
	if _crunch_t <= 0.0:
		_crunch_t = randf_range(0.22, 0.5)
		_crunch_audio.pitch_scale = randf_range(0.58, 0.78)
		_crunch_audio.play()
	_rumble_t -= delta
	if _rumble_t <= 0.0:
		_rumble_t = 0.15
		var pl = Game.player
		if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
			var dp: float = (pl as Node3D).global_position.distance_to(_tip)
			if dp < RUMBLE_RANGE:
				var k2 := 1.0 - dp / RUMBLE_RANGE
				pl.add_trauma(0.02 + 0.16 * k2 * k2)


## A bright scrape where an enemy drill bites the casing.
func _grind_spark(p: Vector3) -> void:
	_burst(get_parent(), p, -_dir, Color(1.0, 0.7, 0.35), 0.35, true)
	if Game.sfx:
		Game.sfx.play_at("impact_light", p, -2.0, randf_range(0.8, 1.1), 10.0)


## The head is at the core: a big blast down there, the core's damage, a crater at the end of the
## tunnel and a gout of dust out of the entry hole.
func _reach_core() -> void:
	_set_state(DONE)
	_leave_groups()
	# (On a multiplayer client the explosion is only the look: explosion.gd skips the damage.)
	Explosion.spawn(_tip, -_dir, {"radius": Balance.TORPEDO_BLAST_R, "damage": Balance.TORPEDO_BLAST_DAMAGE,
			"impulse": 16.0, "self_mult": 1.0, "crater": 0.0, "player_owned": team == "home", "ground": _soil,
			"team": team})
	if not net_puppet and not Net.is_client():
		# Host / single player: the core's damage (only that core is within 1 m × CORE_BLAST_K) and
		# the cavity at the end of the tunnel (the terrain sync carries it).
		if core != null and is_instance_valid(core):
			Core.blast_all(get_tree(), core.global_position, 1.0, Balance.TORPEDO_CORE_DAMAGE)
		if body != null and is_instance_valid(body) and body.has_method("crater"):
			body.crater(_tip, Balance.TORPEDO_END_CRATER, Balance.TORPEDO_END_CRATER * 1.1)
	_entry_blowout()
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var dp: float = minf((pl as Node3D).global_position.distance_to(_tip), (pl as Node3D).global_position.distance_to(_entry))
		if dp < 60.0:
			pl.add_trauma(0.35 + 0.6 * (1.0 - dp / 60.0))
	if Game.hud:
		Game.hud.show_message("Torpido çekirdeğe ulaştı!" if team == "home" else "Düşman torpidosu çekirdeğe çarptı!", 3.0)
	_finish(true)


## The blast's pressure wave out of the entry hole a moment later.
func _entry_blowout() -> void:
	var parent := get_parent()
	var pos := _entry + _entry_up * 0.3
	var up := _entry_up
	var col := _soil
	var tw := parent.create_tween()
	tw.tween_interval(0.3)
	tw.tween_callback(func() -> void:
		_burst(parent, pos, up, col, 2.2)
		_burst(parent, pos, up, Color(0.3, 0.29, 0.28), 1.6))


func _blow_up(pos: Vector3, n: Vector3, underground: bool, why: String) -> void:
	if state == DEAD or state == DONE:
		return
	_set_state(DEAD)
	_leave_groups()
	Explosion.spawn(pos, n, {"radius": Balance.TORPEDO_DEATH_R, "damage": Balance.TORPEDO_DEATH_DAMAGE, "impulse": 7.0,
			"self_mult": 0.5, "crater": 1.4 if underground else 0.0, "player_owned": team == "home", "ground": _soil,
			"team": team})
	if Game.hud:
		if why == "killed":
			Game.hud.show_message("Düşman torpidosu imha edildi!" if team == "rival" else "Torpidomuz yok edildi", 2.2)
		elif team == "home":
			Game.hud.show_message("Torpido bir engele çarptı", 2.0)
	_finish(true)


## Landed where it cannot drill: it lies there for a while.
func _dud(point: Vector3, up: Vector3, planet: Node3D) -> void:
	if state == DUD or state == DEAD or state == DONE:
		return
	_set_state(DUD)
	_net_wait = -1.0
	_leave_groups()
	var flat := _dir - up * _dir.dot(up)
	_dir = (flat.normalized() * 0.85 - up * 0.45).normalized() if flat.length_squared() > 1e-4 else -up
	_tip = point + _dir * 0.2
	global_transform = Transform3D(_orient(_dir), _tip - _dir * HALF)
	_spin_rate = 0.0
	_trail.emitting = false
	_embers.emitting = false
	_halo.visible = false
	_light.light_energy = 0.4
	# A dull puff: dust, a few sparks off the casing (the thud played on landing).
	_burst(get_parent(), point + up * 0.2, up, _soil, 0.7)
	_burst(get_parent(), point + up * 0.2, up, Color(1.0, 0.7, 0.35), 0.4, true)
	if Game.hud and team == "home":
		var own: bool = planet == Game.planet
		Game.hud.show_message("Torpido kendi gezegenimizde çalışmaz" if own else "Hedef çekirdek kalmamış — torpido boşa gitti", 2.4)
	var tw := create_tween()
	tw.tween_interval(DUD_LIFE)
	tw.tween_property(_model, "scale", Vector3.ONE * 0.01, 0.6)
	tw.tween_callback(_finish.bind(true))


## The target core is gone (or its planet): the drill stops where it is.
func _stall() -> void:
	_set_state(DUD)
	_leave_groups()
	_spin_rate = 0.0
	if Game.hud and team == "home":
		Game.hud.show_message("Hedef çekirdek kalmadı — torpido durdu", 2.0)
	_finish(true)


func _leave_groups() -> void:
	remove_from_group("war_shell")
	remove_from_group(Game.DAMAGEABLE)
	if _col != null:
		_col.collision_layer = 0
	if body != null and is_instance_valid(body) and body.has_signal("brush_applied") \
			and body.brush_applied.is_connected(_on_brush):
		body.brush_applied.disconnect(_on_brush)


## Stops everything; the trails fade, then the node goes. hide_model: the torpedo itself vanishes.
func _finish(hide_model: bool) -> void:
	_leave_groups()
	remove_from_group(GROUP)
	set_physics_process(false)
	_spin_rate = 0.0
	_trail.emitting = false
	_embers.emitting = false
	_sparks.emitting = false
	_grit.emitting = false
	_halo.visible = false
	_light.visible = false
	_spark_light.visible = false
	if hide_model:
		_model.visible = false
	for a in [_drill_audio, _grind_audio, _crunch_audio]:
		(a as AudioStreamPlayer3D).stop()
	for e in [_plume, _clods]:
		if e != null and is_instance_valid(e):
			var p := e as CPUParticles3D
			p.emitting = false
			var tw := p.create_tween()
			tw.tween_interval(p.lifetime + 0.5)
			tw.tween_callback(p.queue_free)
	_plume = null
	_clods = null
	var t := create_tween()
	t.tween_interval(3.0)
	t.tween_callback(queue_free)


# =================================================================================================
# Per frame (looks)
# =================================================================================================

func _process(delta: float) -> void:
	_vt += delta
	_spin += _spin_rate * delta
	if _drill != null:
		_drill.rotation.z = _spin
	if state == FLY:
		_roll += delta * 2.5
		_rig.basis = Basis(Vector3.RIGHT, -PI * 0.5) * Basis(Vector3.BACK, _roll)
	var e := 2.2 + _hit_t * 5.0
	if is_burrowing():
		e += 0.5 * sin(_vt * 13.0)
		var f := randf_range(0.6, 1.0)
		_spark_light.light_energy = 2.6 * f
		_light.light_energy = 1.8 + 0.4 * sin(_vt * 9.0)
	_band_mat.albedo_color = Color(_col_team.r * e, _col_team.g * e, _col_team.b * e)


# =================================================================================================
# Shared helpers
# =================================================================================================

## One-shot dust + clods (or sparks) burst at `pos` (world vectors, unrotated nodes).
static func _burst(parent: Node, pos: Vector3, up: Vector3, col: Color, size: float, sparks := false) -> void:
	if parent == null:
		return
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.92
	p.local_coords = false
	if sparks:
		p.amount = 14
		p.lifetime = 0.35
		var q := QuadMesh.new()
		q.size = Vector2(0.02, 0.14)
		var sm := StandardMaterial3D.new()
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		sm.billboard_keep_scale = true
		sm.vertex_color_use_as_albedo = true
		q.material = sm
		p.mesh = q
		p.particle_flag_align_y = true
		p.spread = 80.0
		p.initial_velocity_min = 2.0
		p.initial_velocity_max = 6.0
		p.gravity = Vector3.ZERO
		var sg := Gradient.new()
		sg.colors = PackedColorArray([Color(col.r * 3.0, col.g * 3.0, col.b * 3.0, 1.0), Color(col.r, col.g * 0.5, col.b * 0.3, 0.0)])
		p.color_ramp = sg
	else:
		p.amount = int(18 + 22 * size)
		p.lifetime = 2.2
		var q2 := QuadMesh.new()
		q2.size = Vector2(1.2, 1.2) * size
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_texture = DigFx.soft_texture()
		q2.material = m
		p.mesh = q2
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		p.emission_sphere_radius = 0.4 * size
		p.spread = 35.0
		p.initial_velocity_min = 2.0 * size
		p.initial_velocity_max = 7.0 * size
		p.damping_min = 1.0
		p.damping_max = 2.0
		p.gravity = -up * 1.5
		p.scale_amount_min = 0.8
		p.scale_amount_max = 2.2
		var g := Gradient.new()
		g.set_color(0, Color(col.r, col.g, col.b, 0.6))
		g.set_color(1, Color(col.r, col.g, col.b, 0.0))
		p.color_ramp = g
		# Clods with the dust.
		var c := CPUParticles3D.new()
		c.one_shot = true
		c.explosiveness = 0.95
		c.local_coords = false
		c.amount = int(8 + 14 * size)
		c.lifetime = 2.0
		var bm := BoxMesh.new()
		bm.size = Vector3(0.16, 0.12, 0.14) * clampf(size, 0.6, 1.6)
		var cm := StandardMaterial3D.new()
		cm.vertex_color_use_as_albedo = true
		cm.roughness = 0.95
		bm.material = cm
		c.mesh = bm
		c.direction = up
		c.spread = 40.0
		c.initial_velocity_min = 3.0 * size
		c.initial_velocity_max = 9.0 * size
		c.gravity = -up * 7.8
		c.angular_velocity_min = -300.0
		c.angular_velocity_max = 300.0
		c.particle_flag_rotate_y = true
		c.scale_amount_min = 0.5
		c.scale_amount_max = 1.8
		c.color = col.darkened(0.15)
		c.visibility_aabb = AABB(Vector3.ONE * -60.0, Vector3.ONE * 120.0)
		parent.add_child(c)
		c.global_position = pos
		c.emitting = true
		c.finished.connect(c.queue_free)
	p.direction = up
	p.visibility_aabb = AABB(Vector3.ONE * -60.0, Vector3.ONE * 120.0)
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)


## A fluted (helical) drill bit along -Z: base ring at z 0 (radius `radius`), tip at z -length.
## Cached per size. Wound clockwise seen from outside (Godot's front faces), outward normals.
static func drill_mesh(length: float, radius: float, flutes := 3, twist := 1.15, rings := 14, seg := 24) -> ArrayMesh:
	var key := "%.3f|%.3f|%d|%.2f|%d|%d" % [length, radius, flutes, twist, rings, seg]
	if _meshes.has(key):
		return _meshes[key]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var e := 0.01
	for i in rings + 1:
		var t := float(i) / float(rings)
		for j in seg + 1:
			var th := TAU * float(j) / float(seg)
			var p := _drill_point(th, t, length, radius, flutes, twist)
			var d_th := _drill_point(th + e, t, length, radius, flutes, twist) - _drill_point(th - e, t, length, radius, flutes, twist)
			var d_t := _drill_point(th, minf(t + e, 1.0), length, radius, flutes, twist) \
					- _drill_point(th, maxf(t - e, 0.0), length, radius, flutes, twist)
			var n := d_th.cross(d_t)
			var radial := Vector3(cos(th), sin(th), 0.0)
			if n.length_squared() < 1e-14:
				n = radial + Vector3(0, 0, -0.6)
			elif n.dot(radial) < 0.0:
				n = -n
			verts.append(p)
			norms.append(n.normalized())
			uvs.append(Vector2(float(j) / float(seg), t))
	var row := seg + 1
	for i in rings:
		for j in seg:
			var a := i * row + j
			var b := a + 1
			var c := a + row
			var d := c + 1
			for tri in [[a, b, c], [b, d, c]]:
				var v0: Vector3 = verts[tri[0]]
				var v1: Vector3 = verts[tri[1]]
				var v2: Vector3 = verts[tri[2]]
				var cen := (v0 + v1 + v2) / 3.0
				var out := Vector3(cen.x, cen.y, 0.0)
				# Clockwise from outside: the (v1 - v0) x (v2 - v0) normal points inward.
				if (v1 - v0).cross(v2 - v0).dot(out) < 0.0:
					idx.append(tri[0])
					idx.append(tri[1])
					idx.append(tri[2])
				else:
					idx.append(tri[0])
					idx.append(tri[2])
					idx.append(tri[1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_meshes[key] = am
	return am


## Surface point of the drill bit at angle th, 0..1 along its length (0 base, 1 tip): a slightly
## convex cone with `flutes` helical ridges turning `twist` times.
static func _drill_point(th: float, t: float, length: float, radius: float, flutes: int, twist: float) -> Vector3:
	var r0 := radius * pow(maxf(1.0 - t, 0.0), 0.85)
	var ridge := 0.5 + 0.5 * cos(float(flutes) * th - t * twist * TAU)
	var r := r0 * (0.66 + 0.34 * ridge * ridge)
	return Vector3(cos(th) * r, sin(th) * r, -t * length)
