extends RigidBody3D
## "Mekik": the player-built two-seat skiff, the way across to the rival planet and back. Tiny
## (4.6 m), side-by-side cabin under a bubble canopy (the pilot left, the passenger seat unused for
## now), two nacelles with four lift jets and four stubby legs, one main engine. Geometry and
## materials: skiff_build.gd / skiff_shaders.gd; instruments: skiff_dash.gd (on the dash screen);
## flight markers: skiff_overlay.gd; sound: skiff_audio.gd; wreck: skiff_wreck.gd.
##
## Build contract (scripts/war/build_tool.gd loads this file at runtime):
##   BUILD_COST, DISPLAY_NAME, static footprint() -> half extents of the placement box (it stands
##   on the ground, centred over the origin), place(body, xf) right after add_child: sets the ship
##   down at xf on that body, resting on its legs.
## Seat API (player.gd): interact(p) -> p.enter_vehicle(self); set_pilot(p | null),
##   get_exit_transform(), get_exit_velocity(), hud_velocity(), hud_name(), hud_extra(),
##   can_exit() (no stepping out in flight), shield_pilot(amount, from) (the hull takes the hits).
## Damage: group "damageable", take_damage(amount, from_pos, impulse) -> {dmg, killed}, hp / hp_max,
##   is_dead(). Destroyed: explosion, the pilot thrown out (ragdoll + damage), a burning wreck.
##
## Flying (first person in the cockpit; V: chase view):
##   mouse aims the nose (aim ring), A / D turn, W / S thrust / brake-reverse, Q / E slide sideways,
##   Space / Ctrl climb / descend, Shift boost, right mouse: look around, L lights, F get out (only
##   landed or hovering low and slow).
##   Assisted: the thrusters hold the velocity you ask for (no drifting) against Game.gravity_at
##   (both planets), let go and the ship eases to a hover and holds its height; near a planet it
##   levels to the local up and banks into turns, out between the planets the attitude is free.
##   Near the ground the sink rate is limited (an automatic flare) and a cushion keeps fast low
##   flight off the ground; hovering slow and low with no input it settles onto its legs. Ground
##   height comes from the planets' density field (works on the far planet without collision).
## Landed: frozen on its legs (each leg reaches for the ground), re-probed when the terrain under
## it changes (planet brush_applied): dug away -> it lifts and settles into the hole.
##
## Team: `team` ("home" = the player's side, "rival" = the bots'), set BEFORE add_child / place.
##   A rival skiff wears its own livery: dark gunmetal hull, red stripes, "RK-0N" lettering, a red
##   strobe (home: white, orange pinstripe, "MEKİK" / "YR-0N"). Flak / bots filter on `team`.
##   The player boards a home skiff, or an EMPTY rival one: that captures it (team becomes "home",
##   the paint stays; single player only — in multiplayer a rival skiff cannot be boarded, the team
##   change has no network message yet). A skiff with a bot aboard cannot be boarded.
## AI pilot (the bots, scripts/war/rival_team.gd skiff raids; the "AI pilot" section at the end).
## It flies with exactly the player's flight model: it only sets the same inputs (aim, thrust,
## strafe, up / down, boost) that the keyboard and mouse set.
##   ai_board(bot) -> bool    landed, no pilot, same team (if the bot has `team`), a free seat (two:
##                            the first bot flies, the second rides on the right): the bot takes the
##                            seat. It is hidden (a seated astronaut shows through the canopy), taken
##                            out of "damageable" (the hull shields it) and its collision shapes
##                            are disabled; the skiff carries it along (global_transform).
##   ai_exit(bot = null) -> Transform3D  landed only (or being destroyed): that bot (null: the last
##                            one aboard) steps out beside its door (visible, damageable, collisions
##                            back), returns where it stands. Not landed / not aboard: Transform3D()
##                            (origin ZERO) and nothing changes.
##   ai_crew() -> Array       the bots aboard, the pilot first.
##   ai_fly_to(pos, land)     lifts off (if landed), climbs out, crosses at cruise speed around any
##                            planet in the way, then: land = true picks a landing spot near pos
##                            (density field: level ground, not in a crater / the core shaft, clear
##                            of cannons, flak and other skiffs) and sets down with the auto-flare;
##                            land = false hovers at pos.
##   ai_hold()                stop: hover where it is (or stay landed).
##   ai_busy() -> bool        flying a task that has not arrived yet.
##   ai_arrived() -> bool     the last ai_fly_to arrived (landed for land = true).
##   ai_pilot() -> Node3D     the bot aboard or null.
##   ai_under_fire(from_pos)  call on near misses (flak bursts close by); hits call it themselves.
##                            For ~4 s the skiff jinks: a new random sideways / vertical push every
##                            0.6-1.5 s (and boosts while crossing) so tracking resets.
##   Destroyed with a bot aboard: the bot is thrown out and killed (its take_damage, with an
##   impulse: its ragdoll), then the explosion and the wreck.
##   Variant hook _ai_combat(delta) (armed_skiff.gd: target, attack runs, guns, rockets).
## Multiplayer: an AI-flown skiff is simulated on the host only (the rival team runs there); it is
##   host-owned in net_world.gd's skiff sync (never in _skiff_auth), its state goes out at 20 Hz
##   while a bot is aboard (net_state "powered"), the client's copy is the usual puppet; a crewed
##   rival puppet cannot be boarded there and shows a seated pilot.

const BUILD_COST: float = 50.0    # TEMP (user playtest 2026-10-05): real balance value 3000.0
const DISPLAY_NAME := "Mekik"

const Build := preload("res://scripts/craft/skiff_build.gd")
const Dash := preload("res://scripts/craft/skiff_dash.gd")
const Overlay := preload("res://scripts/craft/skiff_overlay.gd")
const SkiffAudio := preload("res://scripts/craft/skiff_audio.gd")
const Wreck := preload("res://scripts/craft/skiff_wreck.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const Settings := preload("res://scripts/save/settings.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const PLUME_SHADER := preload("res://shaders/shuttle/plume.gdshader")

# --- Flight (m/s, m/s²) ----------------------------------------------------------------------------
## Speeds for two ~120 m worlds ~460 m apart: a crossing takes ~20-30 s.
const CRUISE := 22.0
const BOOST_SPEED := 35.0
const REVERSE := 6.0
const STRAFE := 7.0
const CLIMB := 8.0
const SINK := 6.0
const MAIN_ACC := 12.0             # main engine (climbing out at 45 deg still nets ~6.5 m/s²)
const BOOST_MULT := 1.4
const RETRO_ACC := 8.0             # S: braking
const HOLD_ACC := 6.0              # faster than asked while pushing (boost let go)
const COAST_ACC := 2.2             # W let go: an easy stop (+ COAST_K per m/s)
const COAST_K := 0.07
const LAT_ACC := 6.5               # side thrusters (strafe, drift kill)
const LIFT_ACC := 15.0             # lift jets: ~2 g on these 0.8 g worlds
const DROP_ACC := 6.0
const TAU_F := 1.1                 # assist response along the nose (s)...
const TAU_LAT := 0.5               # ...across it...
const TAU_UP := 0.45               # ...and vertically
const SPOOL_MAIN := 0.25           # thrust lag of the main engine (s)
const SPOOL_RCS := 0.08            # ...of the thrusters / lift jets
const BOOST_SPOOL := 0.5
const LIFTOFF_SPOOL := 0.6         # lift jets spool on the legs before lift-off
const AIR_DRAG := 0.0015           # quadratic drag in sea-level air (thin)
# --- Attitude (rad, rad/s) --------------------------------------------------------------------------
const RATE := Vector3(1.25, 1.15, 1.9)      # pitch, yaw, roll limits
const ANG_ACC := Vector3(3.6, 3.4, 5.0)     # angular authority (the turn rate eases in)
const ROT_WN := 8.0
const ROT_ZETA := 0.85
const ROT_LEAD := 0.05
const ROT_DECEL := 2.6
const TURN_K := 3.2
const AIM_SENS := 0.0021
const AIM_CONE := 0.55
const YAW_KEY := 0.85              # A / D turn rate
const LOOK_SENS := 0.0022
# --- Ground ------------------------------------------------------------------------------------------
const LEG_FLY := 0.10              # legs hang this much below nominal in flight
const LEG_MAX := 0.12
const LEG_MIN := -0.05
const LEG_SAG := 0.03              # struts compress under the weight
const TOUCH_CLEAR := 0.1
const SAFE_SINK := 4.5             # touchdown faster than this hurts
const MAX_TILT := 0.32             # steepest resting tilt on the legs (rad)
const EXIT_CLEAR := 3.0            # stepping out allowed this low...
const EXIT_SPEED := 4.0            # ...and this slow
# --- Damage ------------------------------------------------------------------------------------------
const HP_MAX := 180.0
const IMPACT_MIN := 6.5            # m/s of sudden velocity change before the hull takes damage
const IMPACT_K := 7.0
const EJECT_DAMAGE := 28.0
const MASS := 900.0
const HINT_TIME := 14.0
# --- Visual layers ------------------------------------------------------------------------------------
## Exterior effects (plumes, smoke trail, hit sparks / smoke): hidden from the cockpit camera, so
## nothing of them can show inside the cabin.
const VIS_FX := 1 << 11
## The cabin (tub, seats, dash, stick, screen): the exterior lights skip it (no strobe / nav / engine
## glow inside), the hit decals never reach it.
const VIS_CABIN := 1 << 12
## The outer hull: the only thing hit decals project onto.
const VIS_HULL := 1 << 13
const EXT_LIGHT_MASK := 0xFFFFF & ~VIS_CABIN
## Cockpit free look limits (rad): the head turns as far as a strapped-in pilot's would.
const LOOK_YAW := 2.2
const LOOK_UP := 1.15
const LOOK_DOWN := 1.0

# --- AI pilot ----------------------------------------------------------------------------------------
const AI_CRUISE_ALT := 40.0        # crossing: the waypoint this high over the target
const AI_CLIMB_CLEAR := 22.0       # climb out to this before turning on course
const AI_APPROACH := 110.0         # horizontal distance where the approach (and the spot search) starts
const AI_KEEP_OUT := 30.0          # planets: stay this far above the base radius en route
const AI_JINK_TIME := 4.0
const AI_DESCEND_R := 45.0         # this near the cruise waypoint (spot known): glide down to it
const AI_BRAKE := 3.5              # m/s² the AI plans its slow-downs with (sqrt(2·a·d))
const AI_AVOID_CLEAR := 5.0        # look-ahead: pull up when a point 0.5-2.8 s ahead is this low
const AI_SPOT_EVALS := 2           # landing spot candidates checked per physics tick
const AI_SPOT_FLAT := 0.96         # cos of the steepest ground normal it lands on (~16°)
const AI_SPOT_STEP := 1.1          # m of height difference under the four feet at most
const AI_SPOT_DUG := 2.2           # m below the untouched surface: a crater / shaft, not a pad
const AI_SPOT_CLEAR := 4.5         # m between the spot and any structure's / skiff's footprint
const AI_DESCEND_TIMEOUT := 30.0   # s on one spot before it tries another
const AI_LAND_GIVEUP := 100.0      # s into the task: it takes the target itself, unchecked
const AI_SIT_HIPS := Vector3(0.0, 0.1, 0.03)   # seated astronaut (remote_avatar.gd's seat pose)
const AI_SIT_LEAN := 0.2
enum AiPhase { CLIMB, CRUISE, APPROACH, DESCEND, HOVER }
const Astronaut := preload("res://scripts/player/astronaut.gd")

static var _serial := {}           # team -> skiffs built (registration numbers)

# --- Public state ------------------------------------------------------------------------------------
## "home" (the player's side) or "rival" (the bots'); set before add_child / place.
var team: String = "home"
var pilot = null
var hp := HP_MAX
var hp_max := HP_MAX
var landed := true
var destroyed := false
var chase_view := false
## Flight-feel multipliers for heavier variants (armed_skiff.gd): cruise / top speed, turn rates
## and angular authority.
var speed_k := 1.0
var agility_k := 1.0

# --- Internals ----------------------------------------------------------------------------------------
var _body: Node3D
var _placed := false
var _dying := false
var _visual: Node3D
var _cam: Camera3D
var _chase: Camera3D
var _chase_b := Basis()
var _chase_init := false
var _overlay_layer: CanvasLayer
var _audio
var _dash_vp: SubViewport
var _dash
var _dash_t := 0.0
var _dash_on := false
var radar_mode := 0                # dash centre: 0 RADAR 400 m, 1 RADAR 150 m, 2 UFUK (R cycles, skiff_dash.gd)
var _mat_ext: ShaderMaterial
var _mat_int: ShaderMaterial
var _mat_glass: ShaderMaterial
var _mat_emit: ShaderMaterial
var _feet: Array = []
var _stick: Node3D
var _throttle: Node3D
var _plumes: Array = []            # [pivot, ShaderMaterial, vtol]
var _land_light: SpotLight3D
var _nav_lights: Array = []
var _strobe: OmniLight3D
var _engine_light: OmniLight3D
var _ground_light: OmniLight3D
var _cabin_light: OmniLight3D
var _screen_light: OmniLight3D
var _dust: GPUParticles3D
var _hit_sparks: GPUParticles3D
var _hit_smoke: GPUParticles3D
var _dmg_smoke: GPUParticles3D
var _caution_light: OmniLight3D
var _decals: Array = []
var _hit_warn_t := 0.0
var _hit_fx_t := 0.0
var _eye_fade := 0.0               # terrain at the eye (a crater wall through the canopy): fade out
var _eye_fade_t := 0.0
var _chase_d := -1.0               # smoothed chase-camera distance

static var _scorch_tex: Texture2D

var _in := Vector3.ZERO            # x strafe (E+), y up (Space+), z forward (W+)
var _yaw_in := 0.0
var _boost_in := false
var _aim := Vector3.FORWARD
var _boost := 0.0
var _spool := 0.0
var _thr := Vector3.ZERO           # spooled thrust in the ship frame: x right, y up, z forward (m/s²)
var _ang_acc := Vector3.ZERO
var _w_now := Vector3.ZERO
var _v_expected := Vector3.ZERO
var _v_valid := false
var _impact := 0.0
var _contacts := 0
var _contact_t := 0.0
var _touch_fail_t := 0.0
var _g := Vector3.ZERO
var _up := Vector3.UP
var _alt := 0.0
var _near := 1.0
var _air := 0.0
var _clear := 0.0
var _probe_t := 0.0
var _liftoff_t := 0.0
var _hold_r := -1.0
var _hold_c := 0.0
var _sink_peak := 0.0
var _yaw_f := 0.0
var _resettle_t := 0.0
var _leg_ext := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _leg_target := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _susp := 0.0                   # visual suspension (touchdown dip + rebound)
var _susp_v := 0.0
var _look := Vector2.ZERO
var _look_s := Vector2.ZERO
var _head_off := Vector3.ZERO
var _shake := 0.0
var _shake_t := 0.0
var _jolt := Vector3.ZERO
var _prev_xf := Transform3D()
var _cur_xf := Transform3D()
var _power := 0.0
var _lights := true
var _lights_k := 0.0
var _hint_t := 0.0
var _center_msg := ""
var _center_t := 0.0
var _soft_msg_t := -100.0
var _hp_warned := 0
var _t := 0.0
var _reg := ""
var _seat_body: Node3D             # seated astronaut shown through the canopy (bot / chase view)
# AI pilot state.
var _bot: Node3D = null            # the bot flying it (= _crew[0])
var _crew: Array = []              # [{"bot", "dmg" (was in "damageable"), "shapes" (we disabled)}]
var _seat_body2: Node3D            # the passenger bot's seated astronaut
var _ai_goto := false
var _ai_arrive := false
var _ai_target := Vector3.INF
var _ai_land := false
var _ai_phase := AiPhase.HOVER
var _ai_tbody: Node3D
var _ai_spot := Vector3.INF
var _ai_search: Array = []
var _ai_best := {}
var _ai_obst_t := 0.0
var _ai_pullup := 0.0
var _jink_t := 0.0
var _jink_next := 0.0
var _jink := Vector2.ZERO
var _ai_rng := RandomNumberGenerator.new()
var _ai_sstate := 0                # landing spot search: 0 not started, 1 near rings, 2 wide, 3 done
var _ai_bad: Array = []            # spots it could not set down on
var _ai_lifted := false
var _ai_task_t := 0.0
var _ai_phase_t := 0.0
var _ai_route_t := 0.0
var _ai_wp := Vector3.INF
var _ai_check_t := 0.0
var _ai_v_des := Vector3.ZERO      # what the AI wants this tick (world velocity, nose direction)
var _ai_nose_des := Vector3.ZERO
var _ai_boost := false
var _ai_engaged := false           # the variant's _ai_combat is on a target (no descent meanwhile)
var _ai_serial := 0                # +1 per ai_fly_to (armed_skiff.gd: a new sortie)
var _ai_puppet_t := 0.0

# --- Multiplayer (scripts/net/net_world.gd): sync-only puppet mode ---------------------------------
## Another peer flies this skiff: local physics frozen (kinematic), the transform, velocity, landed
## state and the thrust / boost / spool / lights that drive the plumes, lights and sound follow the
## network. The flight model, visuals and camera are untouched.
var net_puppet := false
var net_powered := false            # its pilot (on the other machine) is aboard
var _net_buf = null                 # scripts/net/snap_buffer.gd
var _net_vel := Vector3.ZERO
var _net_hit := false


## Half extents of the placement box (it stands on the ground over the ship's origin).
static func footprint() -> Vector3:
	return Vector3(1.25, 1.02, 2.5)


func is_skiff() -> bool:
	return true


func _ready() -> void:
	add_to_group(Game.DAMAGEABLE)
	add_to_group("skiff")
	mass = MASS
	gravity_scale = 0.0
	linear_damp = 0.0
	angular_damp = 0.0
	custom_integrator = true
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 6
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = true
	collision_layer = Game.LAYER_VEHICLE
	collision_mask = Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, 0.95, 0.1)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.6
	pm.bounce = 0.05
	physics_material_override = pm
	_build_shapes()
	_build_visual()
	_build_lights()
	_build_fx()
	_build_cameras()
	_audio = SkiffAudio.new()
	_audio.ship = self
	add_child(_audio)
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.add_to_group("gameplay_overlay")   # hidden on the end screen / menus (overlay_guard.gd)
	_overlay_layer.layer = 4
	_overlay_layer.visible = false
	add_child(_overlay_layer)
	var ov: Control = Overlay.new()
	ov.ship = self
	_overlay_layer.add_child(ov)
	for b in Bodies.all():
		if is_instance_valid(b) and b.has_signal("brush_applied"):
			b.brush_applied.connect(_on_brush)
	_build_extra()
	_reset_interp()
	call_deferred("_auto_place")


## Placed by something other than the build tool: set down where it stands.
func _auto_place() -> void:
	if not _placed and is_inside_tree():
		place(Bodies.nearest(global_position), global_transform)


## Build contract: sets the ship down landed at xf on `body` (legs on the real, edited ground).
func place(body: Node3D, xf: Transform3D) -> void:
	_placed = true
	_body = body if body != null else Bodies.nearest(xf.origin)
	global_transform = xf.orthonormalized()
	landed = true
	freeze = true
	_update_env()
	if not _settle():
		_unsettle()
	for i in 4:
		_leg_ext[i] = _leg_target[i]
	_reset_interp()


# ==================================================================================================
# Construction
# ==================================================================================================

func _build_shapes() -> void:
	var along := Basis(Vector3.RIGHT, PI * 0.5)
	_capsule(0.66, 4.4, Transform3D(along, Vector3(0.0, 1.1, 0.05)))
	_capsule(0.5, 2.2, Transform3D(along, Vector3(0.0, 1.45, -0.75)))
	# The wide middle (the hull is broader than the capsule at the sill).
	var mid := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(1.96, 0.66, 2.5)
	mid.shape = bx
	mid.position = Vector3(0.0, 1.1, -0.4)
	add_child(mid)
	for sx: float in [-1.0, 1.0]:
		_capsule(0.22, 3.2, Transform3D(along, Vector3(sx * Build.NAC_X, Build.NAC_Y, 0.1)))
	for f: Vector3 in Build.FEET:
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.1
		cs.shape = sph
		cs.position = f + Vector3(0.0, 0.1, 0.0)
		add_child(cs)


func _capsule(r: float, h: float, xf: Transform3D) -> void:
	var cs := CollisionShape3D.new()
	var c := CapsuleShape3D.new()
	c.radius = r
	c.height = h
	cs.shape = c
	cs.transform = xf
	add_child(cs)


func _build_visual() -> void:
	_visual = Node3D.new()
	_visual.name = "Visual"
	_visual.top_level = true
	add_child(_visual)
	var ms := Build.meshes(_livery())
	_mat_ext = Build.hull_material(false)
	_mat_int = Build.hull_material(true)
	_mat_glass = Build.glass_material()
	_mat_emit = Build.emit_material()
	_mesh(ms["hull"], _mat_ext, true, 1 | VIS_HULL)
	_mesh(ms["cabin"], _mat_int, true, VIS_CABIN)
	_mesh(ms["glass"], _mat_glass, false)
	_mesh(ms["leds"], _mat_emit, false)
	for i in 4:
		var n := Node3D.new()
		n.position = Build.FEET[i]
		_visual.add_child(n)
		var fm := MeshInstance3D.new()
		fm.mesh = ms["foot"]
		fm.material_override = _mat_ext
		fm.layers = 1 | VIS_HULL
		n.add_child(fm)
		_feet.append(n)
	_stick = Node3D.new()
	_stick.position = Build.STICK_POS
	_visual.add_child(_stick)
	var sm := MeshInstance3D.new()
	sm.mesh = ms["stick"]
	sm.material_override = _mat_int
	sm.layers = VIS_CABIN
	_stick.add_child(sm)
	_throttle = Node3D.new()
	_throttle.position = Build.THROTTLE_POS
	_visual.add_child(_throttle)
	var tm := MeshInstance3D.new()
	tm.mesh = ms["throttle"]
	tm.material_override = _mat_int
	tm.layers = VIS_CABIN
	_throttle.add_child(tm)
	# The pilot's display: the dash viewport on a quad in the bezel.
	_dash_vp = Dash.create()
	add_child(_dash_vp)
	_dash = _dash_vp.get_child(0)
	var q := QuadMesh.new()
	q.size = Vector2(0.36, 0.18)
	var scr := MeshInstance3D.new()
	scr.mesh = q
	scr.material_override = Build.screen_material(_dash_vp.get_texture())
	scr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scr.layers = VIS_CABIN
	var fb := Build.dash_basis()
	scr.transform = Transform3D(fb, Vector3(-Build.SEAT_X, Build.DASH_FACE.y, Build.DASH_FACE.z) + fb.z * 0.02)
	_visual.add_child(scr)
	Build.add_decals(_visual, _livery(), _registration())


func _mesh(m: Mesh, mat: Material, shadows: bool, vis_layers := 1) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = vis_layers
	_visual.add_child(mi)
	return mi


func _build_lights() -> void:
	_land_light = SpotLight3D.new()
	_land_light.light_color = Color(1.0, 0.94, 0.84)
	_land_light.light_energy = 0.0
	_land_light.spot_range = 42.0
	_land_light.spot_angle = 30.0
	_land_light.spot_attenuation = 0.9
	_land_light.spot_angle_attenuation = 0.8
	_land_light.shadow_enabled = true
	_land_light.transform = Transform3D(Basis.looking_at(Vector3(0.0, -0.55, -0.83), Vector3.UP), Build.LAND_LIGHT + Vector3(0.0, -0.03, -0.03))
	_visual.add_child(_land_light)
	for i in 2:
		var nl := OmniLight3D.new()
		nl.light_color = Color(1.0, 0.2, 0.15) if i == 0 else Color(0.25, 1.0, 0.4)
		nl.omni_range = 1.8
		nl.light_energy = 0.0
		nl.position = Vector3((-1.0 if i == 0 else 1.0) * Build.NAC_X, Build.NAC_Y, -1.62)
		_visual.add_child(nl)
		_nav_lights.append(nl)
	_strobe = OmniLight3D.new()
	_strobe.light_color = Color(1.0, 1.0, 1.0)
	_strobe.omni_range = 5.0
	_strobe.light_energy = 0.0
	_strobe.position = Build.STROBE + Vector3(0.0, 0.05, 0.0)
	_visual.add_child(_strobe)
	_engine_light = OmniLight3D.new()
	_engine_light.light_color = Color(0.55, 0.75, 1.0)
	_engine_light.omni_range = 6.0
	_engine_light.light_energy = 0.0
	_engine_light.position = Build.MAIN_EXIT + Vector3(0.0, 0.0, 0.5)
	_visual.add_child(_engine_light)
	_ground_light = OmniLight3D.new()
	_ground_light.light_color = Color(0.6, 0.8, 1.0)
	_ground_light.omni_range = 5.5
	_ground_light.light_energy = 0.0
	_ground_light.position = Vector3(0.0, 0.15, 0.1)
	_visual.add_child(_ground_light)
	_cabin_light = OmniLight3D.new()
	_cabin_light.light_color = Color(1.0, 0.88, 0.72)
	_cabin_light.omni_range = 1.8
	_cabin_light.light_energy = 0.0
	_cabin_light.position = Vector3(0.0, 1.82, -0.2)
	_visual.add_child(_cabin_light)
	_screen_light = OmniLight3D.new()
	_screen_light.light_color = Color(0.5, 0.8, 1.0)
	_screen_light.omni_range = 1.0
	_screen_light.light_energy = 0.0
	_screen_light.position = Vector3(-Build.SEAT_X, Build.DASH_FACE.y, Build.DASH_FACE.z) + Build.DASH_N.normalized() * 0.25
	_visual.add_child(_screen_light)


func _build_fx() -> void:
	_add_plume(Build.MAIN_EXIT - Vector3(0.0, 0.0, 0.04), Vector3.BACK, 0.2, 2.0, false)
	for p: Vector3 in Build.VTOL:
		_add_plume(p + Vector3(0.0, 0.01, 0.0), Vector3.DOWN, 0.11, 1.2, true)
	_dust = GPUParticles3D.new()
	_dust.top_level = true
	_dust.amount = 40
	_dust.lifetime = 1.6
	_dust.local_coords = false
	_dust.emitting = false
	_dust.visibility_aabb = AABB(Vector3(-12, -6, -12), Vector3(24, 12, 24))
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0, 1, 0)
	pm.emission_ring_radius = 3.2          # outside the hull: no dust card can reach into the cabin
	pm.emission_ring_inner_radius = 2.1
	pm.emission_ring_height = 0.05
	pm.direction = Vector3(0, 0.2, 0)
	pm.spread = 80.0
	pm.flatness = 0.75
	pm.initial_velocity_min = 2.5
	pm.initial_velocity_max = 6.0
	pm.radial_accel_min = 2.0
	pm.radial_accel_max = 5.0
	pm.damping_min = 1.5
	pm.damping_max = 2.5
	pm.gravity = Vector3.ZERO
	pm.scale_min = 1.0
	pm.scale_max = 2.2
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.4))
	sc.add_point(Vector2(1, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.15, Color(1, 1, 1, 0.42))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = Color(0.72, 0.66, 0.58)
	_dust.process_material = pm
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = DigFx.soft_texture()
	m.roughness = 1.0
	var qm := QuadMesh.new()
	qm.size = Vector2(1.1, 1.1)
	qm.material = m
	_dust.draw_pass_1 = qm
	add_child(_dust)
	_build_damage_fx()


## Hit reactions: a spark burst and a smoke puff where a hit lands, a smoke trail from the
## engine bay once the hull is badly damaged, the master-caution lamp in the cockpit.
func _build_damage_fx() -> void:
	_hit_sparks = _fx_particles(26, 0.55, true, 0.0, 1.0)
	var spm := _hit_sparks.process_material as ParticleProcessMaterial
	spm.spread = 55.0
	spm.initial_velocity_min = 4.0
	spm.initial_velocity_max = 11.0
	spm.damping_min = 2.0
	spm.damping_max = 4.0
	spm.particle_flag_align_y = true
	_hit_smoke = _fx_particles(10, 2.2, false, 0.9, 1.0)
	var smm := _hit_smoke.process_material as ParticleProcessMaterial
	smm.spread = 35.0
	smm.initial_velocity_min = 0.6
	smm.initial_velocity_max = 1.8
	_dmg_smoke = _fx_particles(28, 3.2, false, 1.0, 0.0)
	_dmg_smoke.top_level = false
	_dmg_smoke.one_shot = false
	_dmg_smoke.emitting = false
	_dmg_smoke.position = Vector3(0.2, Build.top_y(1.55) + 0.06, 1.55)      # on the tail top, outside the hull
	remove_child(_dmg_smoke)
	_visual.add_child(_dmg_smoke)
	var dm := _dmg_smoke.process_material as ParticleProcessMaterial
	dm.spread = 20.0
	dm.initial_velocity_min = 0.8
	dm.initial_velocity_max = 2.0
	_caution_light = OmniLight3D.new()
	_caution_light.light_color = Color(1.0, 0.25, 0.18)
	_caution_light.omni_range = 1.4
	_caution_light.light_energy = 0.0
	_caution_light.visible = false
	_caution_light.position = Vector3(-Build.SEAT_X + 0.17, 1.24, -1.0)
	_visual.add_child(_caution_light)


## A world-space particle burst (top_level). spark: additive hot streaks; else lit grey smoke.
func _fx_particles(amount: int, life: float, spark: bool, size: float, explosive: float) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.top_level = true
	e.one_shot = true
	e.emitting = false
	e.amount = amount
	e.lifetime = life
	e.explosiveness = explosive
	e.local_coords = false
	e.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	var g := Gradient.new()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var q := QuadMesh.new()
	if spark:
		g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
		g.colors = PackedColorArray([Color(1.0, 0.92, 0.7, 1.0), Color(1.0, 0.55, 0.2, 1.0), Color(0.8, 0.2, 0.05, 0.0)])
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		mat.billboard_keep_scale = true
		mat.albedo_color = Color(2.2, 2.2, 2.2)
		q.size = Vector2(0.025, 0.22)
	else:
		g.offsets = PackedFloat32Array([0.0, 0.12, 1.0])
		g.colors = PackedColorArray([Color(0.2, 0.19, 0.18, 0.0), Color(0.24, 0.23, 0.22, 0.6), Color(0.42, 0.41, 0.4, 0.0)])
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.albedo_texture = DigFx.soft_texture()
		mat.roughness = 1.0
		q.size = Vector2.ONE * size
		var cv := Curve.new()
		cv.max_value = 4.0
		cv.add_point(Vector2(0.0, 0.6))
		cv.add_point(Vector2(1.0, 2.8))
		var ct := CurveTexture.new()
		ct.curve = cv
		pm.scale_curve = ct
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	e.process_material = pm
	q.material = mat
	e.draw_pass_1 = q
	add_child(e)
	return e


## Hit effects at the point of the hull facing `from_pos`: sparks, a smoke puff, a scorch mark
## that stays (the last few).
func _hit_fx(from_pos: Vector3, k: float) -> void:
	var xf := _visual.global_transform if _visual != null else global_transform
	var c := Vector3(0.0, 1.08, 0.0)
	var dl := Vector3(randf_range(-1, 1), randf_range(-0.2, 1), randf_range(-1, 1))
	if from_pos != Vector3.ZERO:
		var dw := from_pos - xf * c
		if dw.length_squared() > 1e-4:
			dl = xf.basis.inverse() * dw
	dl = dl.normalized()
	var e := Vector3(1.1, 0.96, 2.36)          # (encloses the hull and the canopy: bursts stay outside)
	var t := 1.0 / sqrt(pow(dl.x / e.x, 2.0) + pow(dl.y / e.y, 2.0) + pow(dl.z / e.z, 2.0))
	var p := c + dl * t
	var nl := Vector3(p.x / (e.x * e.x), (p.y - c.y) / (e.y * e.y), p.z / (e.z * e.z)).normalized()
	var wp := xf * p
	var wn := (xf.basis * nl).normalized()
	var bn := Build._basis_y(wn)
	var g := Game.gravity_at(wp)
	if _hit_fx_t <= 0.0:
		_hit_fx_t = 0.08
		_hit_sparks.global_transform = Transform3D(bn, wp)
		(_hit_sparks.process_material as ParticleProcessMaterial).gravity = g * 0.6
		_hit_sparks.amount_ratio = clampf(0.4 + k, 0.4, 1.0)
		_hit_sparks.restart()
		_hit_smoke.global_transform = Transform3D(bn, wp)
		(_hit_smoke.process_material as ParticleProcessMaterial).gravity = -g * 0.08
		_hit_smoke.restart()
	if k > 0.15:
		var d := Decal.new()
		d.texture_albedo = _scorch()
		d.modulate = Color(0.1, 0.09, 0.08, clampf(0.55 + k * 0.4, 0.0, 0.92))
		var s := lerpf(0.35, 0.9, k)
		d.size = Vector3(s, 0.25, s)
		d.cull_mask = VIS_HULL                  # never onto the cabin through the glass, nor the ground
		d.normal_fade = 0.4
		d.upper_fade = 0.2
		d.lower_fade = 0.2
		d.transform = Transform3D(Build._basis_y(nl).rotated(nl, randf() * TAU), p)
		_visual.add_child(d)
		_decals.append(d)
		if _decals.size() > 8:
			(_decals.pop_front() as Node).queue_free()


static func _scorch() -> Texture2D:
	if _scorch_tex != null:
		return _scorch_tex
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 77
	noise.frequency = 0.09
	for y in n:
		for x in n:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(n) * 2.0 - Vector2.ONE
			var r := u.length() * (1.0 + 0.3 * noise.get_noise_2d(x, y))
			var a := clampf(1.0 - smoothstep(0.2, 0.95, r), 0.0, 1.0) * (0.7 + 0.3 * noise.get_noise_2d(x * 2.5, y * 2.5))
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	_scorch_tex = ImageTexture.create_from_image(img)
	return _scorch_tex


## Exhaust cone: pivot at the nozzle exit, local +Y along `dir` (shaders/shuttle/plume.gdshader).
func _add_plume(pos: Vector3, dir: Vector3, radius: float, length: float, vtol: bool) -> void:
	var pivot := Node3D.new()
	pivot.transform = Transform3D(Build._basis_y(dir), pos)
	pivot.visible = false
	_visual.add_child(pivot)
	var m := ShaderMaterial.new()
	m.shader = PLUME_SHADER
	m.render_priority = 2
	m.set_shader_parameter("plume_length", length)
	if vtol:
		m.set_shader_parameter("edge_color", Vector3(0.2, 0.68, 1.0))
	var cm := CylinderMesh.new()
	cm.top_radius = radius * 0.2
	cm.bottom_radius = radius
	cm.height = length
	cm.radial_segments = 18
	cm.rings = 6
	cm.cap_top = false
	cm.cap_bottom = false
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = m
	mi.position = Vector3(0.0, length * 0.5, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = length * 2.0
	pivot.add_child(mi)
	_plumes.append([pivot, m, vtol])


func _build_cameras() -> void:
	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = Game.CAM_FAR
	_cam.fov = Settings.fov
	_cam.position = Build.EYE
	_visual.add_child(_cam)
	_chase = Camera3D.new()
	_chase.top_level = true
	_chase.near = 0.1
	_chase.far = Game.CAM_FAR
	_chase.fov = 70.0
	add_child(_chase)


# ==================================================================================================
# Seat API
# ==================================================================================================

func interact(p) -> void:
	if destroyed or _dying or pilot != null or p == null or _ai_blocks(p):     # (bots aboard / capture: AI pilot)
		return
	if Net.active and Net.world.skiff_interact(self, p):
		return              # multiplayer: the passenger seat, or the seats are taken
	if p.has_method("enter_vehicle"):
		p.enter_vehicle(self)


func get_interact_prompt() -> String:
	if destroyed or _dying or pilot != null:
		return ""
	var ap := _ai_prompt()                  # (bots aboard / a rival skiff: AI pilot)
	if ap != "":
		return "" if ap == "-" else ap
	if Net.active:
		var np: String = Net.world.skiff_prompt(self)
		if np != "":
			return "" if np == "-" else np
	var s := "Mekiğe bin"
	if hp < hp_max - 0.5:
		s += "  ·  gövde %d%%" % roundi(hp / hp_max * 100.0)
	return s


func set_pilot(p) -> void:
	pilot = p
	_in = Vector3.ZERO
	_yaw_in = 0.0
	_boost_in = false
	_look = Vector2.ZERO
	_look_s = Vector2.ZERO
	_spool = 0.0
	chase_view = false
	_chase_init = false
	if p != null:
		_aim = -global_transform.basis.z
		_cam.current = true
		_overlay_layer.visible = true
		_hint_t = HINT_TIME
		_lights = true
		_audio.startup()
		if Game.sfx:
			Game.sfx.play("switch", -10.0)
		_carry_pilot()
	else:
		_cam.current = false
		_chase.current = false
		_overlay_layer.visible = false
		if not destroyed:
			_audio.shutdown()
		_hold_r = -1.0
	continuous_cd = p != null


## Stepping out: landed, or hovering low and slow (no bailing out in flight).
func can_exit() -> bool:
	if landed or destroyed or _dying:
		return true
	if _clear < EXIT_CLEAR and linear_velocity.length() < EXIT_SPEED:
		return true
	_flash("Uçarken inilmez — yere yaklaş (3 m) ve yavaşla")
	if Game.sfx:
		Game.sfx.play("error", -10.0)
	return false


## Where the pilot steps out: beside the pilot's door on the ground, else the other side, the
## nose, the tail, or on top of the hull.
func get_exit_transform() -> Transform3D:
	var xf := global_transform.orthonormalized()
	var up := _up
	var fwd := -xf.basis.z
	for side: Vector3 in [Vector3(-1.75, 0.0, -0.4), Vector3(1.75, 0.0, -0.4), Vector3(0.0, 0.0, -3.3), Vector3(0.0, 0.0, 3.5)]:
		var p := xf * side
		if _body == null:
			break
		var from := p + up * 2.5
		var d := _ground_dist(_body, from, -up, 8.0)
		if d <= 8.0:
			var gp := from - up * d
			if float(_body.call("density_at", gp + up * 1.0)) > 0.3:
				return _stand_xf(gp + up * 0.05, up, fwd)
	return _stand_xf(xf * Vector3(0.0, 2.25, 0.8), up, fwd)


static func _stand_xf(pos: Vector3, up: Vector3, fwd: Vector3) -> Transform3D:
	var f := fwd - up * fwd.dot(up)
	if f.length_squared() < 1e-4:
		f = up.cross(Vector3.RIGHT)
	var z := -f.normalized()
	var x := up.cross(z).normalized()
	return Transform3D(Basis(x, up, x.cross(up)), pos)


func get_exit_velocity() -> Vector3:
	return _net_vel if net_puppet else (Vector3.ZERO if landed else linear_velocity)


func hud_velocity() -> Vector3:
	return _net_vel if net_puppet else (Vector3.ZERO if freeze else linear_velocity)


func hud_name() -> String:
	return DISPLAY_NAME


func hud_extra() -> String:
	return "Gövde %d%%" % roundi(hp / hp_max * 100.0)


## The pilot sits inside the hull: the hull takes the hits (player.gd asks before hurting them).
func shield_pilot(amount: float, _from_pos := Vector3.ZERO) -> float:
	return amount if destroyed else 0.0


func _carry_pilot() -> void:
	if pilot != null and is_instance_valid(pilot):
		(pilot as Node3D).global_transform = global_transform * Transform3D(Basis(), Build.SEAT_POS)


# ==================================================================================================
# Input
# ==================================================================================================

func free_looking() -> bool:
	return landed or _free_look_held()


func _unhandled_input(event: InputEvent) -> void:
	if pilot == null or destroyed or Game.ui_panel_open():
		return
	if _weapons_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var lk := Settings.look((event as InputEventMouseMotion).relative)
		if free_looking():
			_look.x = clampf(_look.x - lk.x * LOOK_SENS, -2.4, 2.4)
			_look.y = clampf(_look.y - lk.y * LOOK_SENS, -1.1, 1.2)
		else:
			_aim_mouse(lk)
	elif event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).physical_keycode == KEY_V:
		chase_view = not chase_view
		_chase_init = false
		_chase.current = chase_view
		_cam.current = not chase_view
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("flashlight"):
		_lights = not _lights
		if Game.sfx:
			Game.sfx.play("switch", -10.0)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).physical_keycode == KEY_R:
		radar_mode = (radar_mode + 1) % 3      # the dash radar's range / the attitude ball
		_dash_t = 0.0
		if Game.sfx:
			Game.sfx.play("switch", -12.0, 1.15)
		get_viewport().set_input_as_handled()


func _read_input(delta: float) -> void:
	_in = Vector3.ZERO
	_yaw_in = 0.0
	_boost_in = false
	if pilot == null and _bot != null:
		_ai_step(delta)                     # a bot flies it: the same inputs (AI pilot, end of file)
		return
	if pilot == null or Game.ui_panel_open():
		return
	_in.z = Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	_yaw_in = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	_in.x = (1.0 if Input.is_physical_key_pressed(KEY_E) else 0.0) - (1.0 if Input.is_physical_key_pressed(KEY_Q) else 0.0)
	_in.y = Input.get_action_strength("jump") - Input.get_action_strength("descend")
	_boost_in = Input.is_action_pressed("sprint") and _in.z > 0.1
	if not landed and absf(_yaw_in) > 0.01:
		_aim = _aim.rotated(_yaw_axis(), -_yaw_in * YAW_KEY * delta).normalized()
		_clamp_aim()


## Turning axis: the planet's up near a planet (the horizon stays put), the ship's up out in space.
func _yaw_axis() -> Vector3:
	var sb := global_transform.basis.y.normalized()
	if _near <= 0.01 or sb.dot(_up) < 0.2:
		return sb
	return sb.lerp(_up, _near).normalized()


## Mouse: moves the aim in screen directions (the active camera), within a cone around the nose.
func _aim_mouse(lk: Vector2) -> void:
	var cb := (_chase if chase_view else _cam).global_transform.basis.orthonormalized()
	var yaw_ax := cb.y
	if _near > 0.3 and cb.y.dot(_up) > 0.3:
		yaw_ax = cb.y.lerp(_up, _near * 0.7).normalized()
	_aim = _aim.rotated(yaw_ax, -lk.x * AIM_SENS)
	_aim = _aim.rotated(cb.x, -lk.y * AIM_SENS).normalized()
	_clamp_aim()


func _clamp_aim() -> void:
	var fwd := -global_transform.basis.z.normalized()
	var ang := fwd.angle_to(_aim)
	if ang > 2.8:
		_aim = fwd
	elif ang > AIM_CONE:
		_aim = fwd.slerp(_aim, AIM_CONE / ang).normalized()
	if _near > 0.5:
		var el := asin(clampf(_aim.dot(_up), -1.0, 1.0))
		if absf(el) > 1.35:
			var h := _aim - _up * _aim.dot(_up)
			if h.length_squared() > 1e-4:
				_aim = (h.normalized() * cos(1.35) + _up * signf(el) * sin(1.35)).normalized()


# ==================================================================================================
# Per tick
# ==================================================================================================

func _physics_process(delta: float) -> void:
	_prev_xf = _cur_xf
	_cur_xf = global_transform
	if destroyed:
		return
	_t += delta
	if net_puppet:
		_net_follow()
		_update_env()
		_carry_pilot()
		_ai_puppet_seat(delta)              # a crewed rival skiff on a client: its pilot (AI pilot)
		return
	_read_input(delta)
	_weapons_step(delta)
	_update_env()
	if landed:
		_landed_step(delta)
	else:
		_probe(delta)
		_flight_checks(delta)
	if _impact > 0.0:
		_apply_impact()
	_carry_pilot()


func _update_env() -> void:
	var pos := global_position
	_g = Game.gravity_at(pos + global_transform.basis.y)
	_air = Game.atmosphere_factor(pos)
	var b := Bodies.nearest(pos)
	if b == null:
		_near = 0.0
		_up = global_transform.basis.y.normalized()
		return
	_body = b
	var d := pos - b.global_position
	var dist := d.length()
	_up = d / dist if dist > 0.01 else Vector3.UP
	var r := float(b.radius)
	_alt = dist - r
	_near = 1.0 - smoothstep(0.3 * r, 0.8 * r, _alt)        # (R 60: 18..48 m up)


## Height of the feet above the ground: the planet's analytic height high up, a density march near
## it (craters, dug ground), one density sample per foot in the last metres.
func _probe(delta: float) -> void:
	_clear += linear_velocity.dot(_up) * delta
	_probe_t -= delta
	if _probe_t > 0.0:
		return
	if _body == null:
		_clear = 1e4
		_probe_t = 0.2
		return
	var b := _body
	var pos := global_position
	var r := pos.distance_to(b.global_position)
	var alt_an := r - (float(b.get("radius")) + float(b.call("surface_height_at", pos)))
	if alt_an > 32.0:
		_clear = alt_an - LEG_FLY
		_probe_t = 0.15
		return
	_probe_t = 0.06 if alt_an < 6.0 else 0.1
	var from := pos + _up * 1.2
	var max_d := alt_an + 20.0
	var d := _ground_dist(b, from, -_up, max_d)
	# (no ground within reach, e.g. over a dug shaft: it is at least that far down)
	var c := (d - 1.2 - LEG_FLY) if d <= max_d else max_d
	if c < 3.0:
		var xf := global_transform
		for f: Vector3 in Build.FEET:
			var fp := xf * (f - Vector3(0.0, LEG_FLY, 0.0))
			c = minf(c, float(b.call("density_at", fp)))
	_clear = c


## Distance along `dir` from `from` to the ground of body b (density field), or max_d + 1.
static func _ground_dist(b: Node3D, from: Vector3, dir: Vector3, max_d: float) -> float:
	var t := 0.0
	var d := float(b.call("density_fast", from))
	if d < 1.6:
		d = float(b.call("density_at", from))
		if d < 0.0:
			return 0.0
	for i in 48:
		var tn := minf(t + maxf(d * 0.75, 0.2), max_d)
		var p := from + dir * tn
		var dn := float(b.call("density_fast", p))
		if dn < 1.6:
			dn = float(b.call("density_at", p))
		if dn < 0.0:
			var lo := t
			var hi := tn
			for k in 4:
				var m := (lo + hi) * 0.5
				if float(b.call("density_at", from + dir * m)) < 0.0:
					hi = m
				else:
					lo = m
			return hi
		t = tn
		d = dn
		if t >= max_d:
			break
	return max_d + 1.0


func _sink_max(c: float) -> float:
	var cc := maxf(c, 0.0)
	return maxf(minf(sqrt(7.0 * cc), 0.6 + 0.45 * cc), 0.55)


func _landed_step(delta: float) -> void:
	if _resettle_t > 0.0:
		_resettle_t -= delta
		if _resettle_t <= 0.0:
			_reprobe()
			if not landed:
				return
	var wants := _piloted() and (_in.y > 0.1 or _in.z > 0.1)
	if wants:
		if _spool <= 0.0:
			_audio.puff(0.6)
		_spool = minf(_spool + delta / LIFTOFF_SPOOL, 1.0)
		if _spool >= 1.0:
			_lift_off()
	else:
		_spool = maxf(_spool - delta * 1.5, 0.0)


func _lift_off() -> void:
	landed = false
	freeze = false
	_spool = 0.0
	_liftoff_t = 1.0
	_hold_r = -1.0
	_aim = -global_transform.basis.z
	_thr = Vector3(0.0, _g.length() * 1.05, 0.0)
	_ang_acc = Vector3.ZERO
	linear_velocity = _up * 2.2
	angular_velocity = Vector3.ZERO
	_v_valid = false
	_clear = 0.05
	_probe_t = 0.0
	_audio.puff(1.0)
	_shake = maxf(_shake, 0.15)


func _flight_checks(delta: float) -> void:
	_liftoff_t = maxf(_liftoff_t - delta, 0.0)
	var v := linear_velocity
	var vu := v.dot(_up)
	var hs := (v - _up * vu).length()
	_sink_peak = maxf(_sink_peak - delta * 6.0, maxf(-vu, 0.0))
	_contact_t = _contact_t + delta if _contacts > 0 else 0.0
	var up_in := _piloted() and _in.y > 0.05
	_touch_fail_t = maxf(_touch_fail_t - delta, 0.0)
	if _liftoff_t <= 0.0 and _touch_fail_t <= 0.0 and not up_in and _near > 0.5 and hs < 8.0:
		if _clear < TOUCH_CLEAR and vu < 1.0:
			_touchdown()
		elif _contacts > 0 and _clear < 0.7 and v.length() < 3.0 and _contact_t > 0.25:
			_touchdown()


func _touchdown() -> void:
	var v := linear_velocity
	var vs := maxf(_sink_peak, -v.dot(_up))
	var hs := (v - _up * v.dot(_up)).length()
	if not _settle():
		# Nothing to stand on under the feet (a pit edge): keep flying, try again shortly.
		_touch_fail_t = 0.5
		return
	freeze = true
	landed = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_thr = Vector3.ZERO
	_ang_acc = Vector3.ZERO
	_boost = 0.0
	_v_valid = false
	_susp_v = -clampf(vs, 0.5, 6.0) * 0.12
	var k := clampf(vs / 4.0, 0.2, 1.0)
	_audio.touchdown(k)
	_audio.gear()
	_shake = maxf(_shake, clampf(vs / 6.0, 0.08, 0.5))
	var dmg := maxf(vs - SAFE_SINK, 0.0) * 12.0 + maxf(hs - 6.0, 0.0) * 6.0
	if dmg > 0.5:
		take_damage(dmg, global_position - _up * 3.0)
		if pilot != null:
			_flash("Sert iniş!")
	elif pilot != null and vs < 1.3 and hs < 1.5 and _t - _soft_msg_t > 25.0:
		_soft_msg_t = _t
		_flash("Yumuşak iniş · %.1f m/s" % vs)
		if Game.sfx:
			Game.sfx.play("ding", -15.0, 1.25)


## Rests the ship on the ground under its feet (density field): plane through the four ground
## points (tilt limited), the lowest foot on the ground, the others reaching down.
func _settle() -> bool:
	var b := _body if _body != null else Bodies.nearest(global_position)
	if b == null:
		return false
	_body = b
	var xf := global_transform.orthonormalized()
	var up := (xf.origin - b.global_position).normalized()
	var hits: Array = []
	var miss := 0
	for f: Vector3 in Build.FEET:
		var foot := xf * f
		var from := foot + up * 2.5
		var d := _ground_dist(b, from, -up, 9.0)
		if d > 9.0:
			miss += 1
			hits.append(foot - up * 6.5)
		else:
			hits.append(from - up * d)
	if miss >= 2:
		return false
	var h0: Vector3 = hits[0]
	var h1: Vector3 = hits[1]
	var h2: Vector3 = hits[2]
	var h3: Vector3 = hits[3]
	var n := (h3 - h0).cross(h2 - h1)
	if n.length_squared() < 1e-8:
		n = up
	n = n.normalized()
	if n.dot(up) < 0.0:
		n = -n
	var ang := up.angle_to(n)
	if ang > MAX_TILT:
		n = up.slerp(n, MAX_TILT / ang).normalized()
	var f2 := -xf.basis.z
	f2 = f2 - n * f2.dot(n)
	if f2.length_squared() < 1e-6:
		f2 = n.cross(xf.basis.x)
	f2 = f2.normalized()
	var nb := Basis(n.cross(-f2).normalized(), n, -f2)
	var o := (h0 + h1 + h2 + h3) * 0.25
	var gaps: Array = []
	var min_gap := INF
	for i in 4:
		var gap := (o + nb * (Build.FEET[i] as Vector3) - (hits[i] as Vector3)).dot(n)
		gaps.append(gap)
		min_gap = minf(min_gap, gap)
	o -= n * (min_gap + LEG_SAG)
	for i in 4:
		_leg_target[i] = clampf(float(gaps[i]) - min_gap - LEG_SAG, LEG_MIN, LEG_MAX)
	global_transform = Transform3D(nb, o)
	_reset_interp()
	return true


## The ground under a parked ship changed: rest on the new ground, or lift and settle into a hole.
func _reprobe() -> void:
	var old := global_transform
	if not _settle():
		global_transform = old
		_reset_interp()
		_unsettle()
		return
	var drop := (old.origin - global_position).dot(_up)
	if drop > 0.3:
		global_transform = old
		_reset_interp()
		_unsettle()


func _unsettle() -> void:
	landed = false
	freeze = false
	_liftoff_t = 0.0
	_hold_r = -1.0
	_thr = Vector3(0.0, _g.length(), 0.0)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_v_valid = false
	_probe_t = 0.0
	_clear = 1.0


func _on_brush(center: Vector3, r: float) -> void:
	if destroyed or not landed or net_puppet:
		return
	if center.distance_to(global_position + global_transform.basis.y * 0.5) > r + 4.0:
		return
	_resettle_t = 0.2


func _reset_interp() -> void:
	_prev_xf = global_transform
	_cur_xf = global_transform
	if _visual != null:
		_visual.global_transform = global_transform


# ==================================================================================================
# Flight model
# ==================================================================================================

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if freeze or destroyed or landed:
		_v_valid = false
		return
	var dt := state.step
	var v := state.linear_velocity
	# A velocity change we did not cause: a collision.
	if _v_valid:
		var dv := (v - _v_expected).length()
		if dv > IMPACT_MIN:
			_impact = maxf(_impact, dv)
	_v_valid = true
	_contacts = state.get_contact_count()
	var b := state.transform.basis.orthonormalized()
	v = _fly_velocity(v, b, state.transform.origin, dt)
	state.linear_velocity = v
	_v_expected = v
	# Rotation with inertia: the turn rate follows the command as a damped 2nd-order system.
	var w_cmd := _attitude(b, state.angular_velocity, dt)
	var lw := b.inverse() * state.angular_velocity
	var lc := b.inverse() * w_cmd
	var jerk := (lc - lw) * (ROT_WN * ROT_WN) - _ang_acc * (2.0 * ROT_ZETA * ROT_WN)
	_ang_acc = (_ang_acc + jerk * dt).clamp(-ANG_ACC * agility_k, ANG_ACC * agility_k)
	lw += _ang_acc * dt
	state.angular_velocity = b * lw
	_w_now = state.angular_velocity


## Assisted flight: a target velocity from the controls, the thrusters (limited per ship axis,
## spooled) push toward it against gravity.
func _fly_velocity(v: Vector3, b: Basis, pos: Vector3, dt: float) -> Vector3:
	var fwd := -b.z
	var right := b.x
	var upb := b.y
	var g := _g
	var nk := _near
	var piloted := _piloted()                  # (a player, or a bot: AI pilot)
	var in_f := _in.z if piloted else 0.0
	var in_s := _in.x if piloted else 0.0
	var in_u := _in.y if piloted else 0.0
	var boosting := piloted and _boost_in
	_boost = move_toward(_boost, 1.0 if boosting else 0.0, dt / (BOOST_SPOOL if boosting else 0.8))
	# Vertical reference: the planet's up near it, the ship's own up out in the open.
	var upr := upb
	if nk > 0.001:
		var bl := upb.lerp(_up, nk)
		upr = bl.normalized() if bl.length_squared() > 0.01 else _up
	var vf := v.dot(fwd)
	var pushing := in_f > 0.05 or _boost > 0.02
	var braking := in_f < -0.05
	var tf := 0.0
	if pushing:
		tf = lerpf(CRUISE * speed_k * maxf(in_f, 0.0), BOOST_SPEED * speed_k, _boost)
	elif braking:
		tf = -REVERSE if vf < 1.5 else 0.0
	var vt := fwd * tf + right * (in_s * STRAFE)
	var c := _clear
	var hspeed := (v - _up * v.dot(_up)).length()
	var vt_u := vt.dot(upr)
	var tu := vt_u
	if absf(in_u) > 0.05:
		tu += in_u * (CLIMB if in_u > 0.0 else SINK)
		_hold_r = -1.0
	elif not piloted:
		# Nobody aboard: set it down.
		_hold_r = -1.0
		vt = Vector3.ZERO
		vt_u = 0.0
		tu = -_sink_max(c) if nk > 0.3 else 0.0
	elif pushing or nk < 0.5 or _body == null:
		_hold_r = -1.0
	elif c < 0.6 and hspeed < 2.0 and _liftoff_t <= 0.0:
		# Just above the ground, slow, no input: settle onto the legs.
		_hold_r = -1.0
		tu = -0.7
	else:
		# Height hold (distance from the planet's centre), climbing over ground rising below.
		var r_now := pos.distance_to(_body.global_position)
		var vu := v.dot(_up)
		if _hold_r < 0.0:
			_hold_r = r_now + vu * 0.35
			_hold_c = maxf(c + vu * 0.35, 1.2)
		var want_r := maxf(_hold_r, r_now + (_hold_c - c))
		tu = clampf((want_r - r_now) * 1.4, -3.0, 5.0)
	# Near the ground: an automatic flare (the sink rate shrinks with the height) and a cushion
	# that keeps fast, low flight off the ground.
	if nk > 0.3 and c < 60.0:
		tu = maxf(tu, -_sink_max(c))
		if in_u >= -0.05 and c < 2.5 and (hspeed > 4.0 or absf(in_f) > 0.05 or absf(in_s) > 0.05):
			tu = maxf(tu, (2.5 - c) * 1.6)
	vt += upr * (tu - vt_u)
	# Acceleration asked per ship axis (gravity compensated), within each thruster's authority.
	var e := vt - v
	var a_f := e.dot(fwd) / TAU_F - g.dot(fwd)
	var a_r := e.dot(right) / TAU_LAT - g.dot(right)
	var a_u := e.dot(upb) / TAU_UP - g.dot(upb)
	var retro := COAST_ACC + COAST_K * absf(vf)
	if braking:
		retro = RETRO_ACC
	elif pushing:
		retro = HOLD_ACC
	if not piloted:
		retro = maxf(retro, 4.0)
	# Flaring out of a dive: the main engine may brake hard too (the nose comes up meanwhile).
	if nk > 0.3 and c < 60.0 and v.dot(_up) < -(_sink_max(c) + 1.5):
		retro = maxf(retro, 12.0)
	var main := MAIN_ACC * lerpf(1.0, BOOST_MULT, _boost)
	var want := Vector3(clampf(a_r, -LAT_ACC, LAT_ACC), clampf(a_u, -DROP_ACC, LIFT_ACC), clampf(a_f, -retro, main))
	_thr.x += (want.x - _thr.x) * (1.0 - exp(-dt / SPOOL_RCS))
	_thr.y += (want.y - _thr.y) * (1.0 - exp(-dt / SPOOL_RCS))
	var tz := SPOOL_MAIN if absf(want.z) > absf(_thr.z) else SPOOL_MAIN * 0.8
	_thr.z += (want.z - _thr.z) * (1.0 - exp(-dt / tz))
	var sp := v.length()
	var drag := -v * sp * AIR_DRAG * _air if sp > 0.3 else Vector3.ZERO
	return v + (g + drag + right * _thr.x + upb * _thr.y + fwd * _thr.z) * dt


## Attitude command (world angular velocity): the nose to the aim (kept near the horizon close to
## the ground), the wings level to the planet with a bank into turns; free roll in open space.
func _attitude(b: Basis, w_now: Vector3, dt: float) -> Vector3:
	var fwd := -b.z
	var upb := b.y
	var nk := _near
	var up_w := _up
	var f_des := _aim
	if not _piloted():
		var h := fwd - up_w * fwd.dot(up_w)
		f_des = h.normalized() if h.length_squared() > 1e-4 else fwd
	if nk > 0.01:
		var elev := asin(clampf(f_des.dot(up_w), -1.0, 1.0))
		var lim := lerpf(1.5, lerpf(0.25, 1.4, smoothstep(2.0, 40.0, _clear)), nk)
		if absf(elev) > lim:
			var hz := f_des - up_w * f_des.dot(up_w)
			if hz.length_squared() > 1e-4:
				f_des = (hz.normalized() * cos(lim) + up_w * signf(elev) * sin(lim)).normalized()
	var u_des := upb
	if nk > 0.01 and absf(f_des.dot(up_w)) < 0.97:
		var sp := _v_expected.length()
		_yaw_f = lerpf(_yaw_f, w_now.dot(up_w), 1.0 - exp(-6.0 * dt))
		var gl := maxf(_g.length(), 2.0)
		var bank := clampf(atan(sp * -_yaw_f / gl * 0.5), -0.5, 0.5) * clampf(sp / 15.0, 0.0, 1.0)
		if _piloted():
			bank += _in.x * 0.1
		var level := up_w - f_des * up_w.dot(f_des)
		if level.length_squared() > 1e-4:
			var tgt := level.normalized().rotated(f_des, bank)
			var bl := upb.lerp(tgt, nk)
			u_des = bl.normalized() if bl.length_squared() > 0.01 else tgt
	return _rot_cmd(b, f_des, u_des, w_now)


## Angular velocity that turns the nose toward f_des (eased, braking within the authority, a little
## lead so it settles without overshoot) and rolls the ship's up toward u_des.
func _rot_cmd(b: Basis, f_des: Vector3, u_des: Vector3, w_now: Vector3) -> Vector3:
	var fwd := -b.z
	var upb := b.y
	var w := Vector3.ZERO
	var axis := fwd.cross(f_des)
	var s := axis.length()
	var ang := atan2(s, fwd.dot(f_des))
	if s > 1e-6:
		ang = maxf(ang - w_now.dot(axis / s) * ROT_LEAD, 0.0)
		var eff := maxf(ang - 0.003, 0.0)
		var rate := minf(TURN_K * eff, sqrt(2.0 * ROT_DECEL * eff))
		w = axis / s * rate
	w -= fwd * w.dot(fwd)
	var up_p := u_des - fwd * u_des.dot(fwd)
	if up_p.length_squared() > 1e-4:
		up_p = up_p.normalized()
		var roll_err := atan2(upb.cross(up_p).dot(fwd), upb.dot(up_p)) - w_now.dot(fwd) * 0.3
		w += fwd * clampf(roll_err * 2.4, -RATE.z, RATE.z)
	var l := b.inverse() * w
	l = l.clamp(-RATE * agility_k, RATE * agility_k)
	return b * l


# ==================================================================================================
# Damage
# ==================================================================================================

func is_dead() -> bool:
	return destroyed or _dying


func take_damage(amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO) -> Dictionary:
	if destroyed or _dying or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	if Net.is_client() and not _net_hit:
		# Multiplayer: the hull's hp is the host's; crashes / hits here become a claim.
		Net.world.claim_skiff_damage(self, amount, from_pos, impulse)
		return {"dmg": amount, "killed": false}
	if Net.is_host():
		Net.world.on_skiff_hit(self, amount, from_pos, impulse, maxf(hp - amount, 0.0))
	hp = maxf(hp - amount, 0.0)
	if _bot != null and not landed:
		ai_under_fire(from_pos)                 # a bot flying it jinks (AI pilot)
	var k := clampf(amount / 40.0, 0.1, 1.0)
	_shake = clampf(_shake + 0.12 + k * 0.45, 0.0, 1.0)
	var dir := Vector3(randf_range(-1, 1), randf_range(-0.3, 1), randf_range(-1, 1)).normalized()
	if from_pos != Vector3.ZERO:
		var d := global_position + global_transform.basis.y - from_pos
		if d.length_squared() > 1e-4:
			dir = d.normalized()
	_jolt += global_transform.basis.inverse() * dir * 0.05 * k
	_audio.impact(k)
	_hit_fx(from_pos, k)
	if not landed and not freeze and impulse != Vector3.ZERO:
		linear_velocity += impulse * 0.3
		_v_expected += impulse * 0.3        # (a shove, not a collision)
	if amount >= 2.0 and hp > 0.0:
		_hit_warn_t = 2.5
		if pilot != null:
			_flash("GÖVDE HASARI %%%d" % roundi(hp / hp_max * 100.0))
	_hp_warnings()
	if hp <= 0.0:
		_dying = true
		call_deferred("_destroy")
		return {"dmg": amount, "killed": true}
	return {"dmg": amount, "killed": false}


func _hp_warnings() -> void:
	var f := hp / hp_max
	var level := 2 if f < 0.3 else (1 if f < 0.5 else 0)
	if level > _hp_warned and pilot != null:
		if level == 2:
			_flash("GÖVDE KRİTİK %%%d — ana uyarı" % roundi(f * 100.0))
		if Game.sfx:
			Game.sfx.play("error", -8.0, 0.8)
	_hp_warned = maxi(_hp_warned, level)


func _apply_impact() -> void:
	var dv := _impact
	_impact = 0.0
	_audio.impact(clampf(dv / 20.0, 0.2, 1.0))
	_shake = clampf(_shake + clampf(dv / 25.0, 0.1, 0.6), 0.0, 1.0)
	var dmg := (dv - IMPACT_MIN) * IMPACT_K
	if dmg > 0.5:
		# (the hit side: where it was flying)
		var hv := _v_expected if _v_expected.length_squared() > 0.25 else -_up
		take_damage(dmg, global_position + global_transform.basis.y + hv.normalized() * 3.0)
		if pilot != null and dmg > 12.0:
			_flash("Çarpma! −%d" % roundi(dmg))


## Destroyed: the pilot is thrown out and hurt, an explosion, a burning wreck.
func _destroy() -> void:
	if destroyed:
		return
	destroyed = true
	remove_from_group(Game.DAMAGEABLE)
	remove_from_group("war_structure")
	remove_from_group("skiff")
	var xf := global_transform
	var up := _up
	var center := xf * Vector3(0.0, 1.0, 0.0)
	var vel := Vector3.ZERO if freeze else linear_velocity
	var p = pilot
	if p != null and is_instance_valid(p):
		p.exit_vehicle()
		if p.has_method("ragdoll"):
			p.ragdoll(up * 6.0 - xf.basis.x * 3.5 + vel * 0.5, 2.5)
		if p.has_method("take_damage"):
			p.take_damage(EJECT_DAMAGE, center)
	_ai_eject_crew(center, up, vel)             # bots aboard: thrown out, killed (AI pilot)
	var soil := Color(0.42, 0.36, 0.27)
	if _body != null and _body.get("soil_color") is Color:
		soil = _body.get("soil_color")
	Explosion.spawn(center, up, {"radius": 6.0, "damage": 28.0, "impulse": 9.0, "crater": 2.0,
			"player_owned": false, "ground": soil})
	var ms := Build.meshes(_livery())
	Wreck.spawn(get_parent(), xf, vel, [ms["hull"], ms["cabin"]], Build.hull_material(false))
	if Game.hud:
		Game.hud.alert("%s yok edildi!" % hud_name(), 1, "skiff", 2.5)
	queue_free()


# ==================================================================================================
# Per frame: visuals, cameras, instruments, sound
# ==================================================================================================

func _process(delta: float) -> void:
	if destroyed:
		return
	var xf := global_transform
	if not freeze:
		xf = _prev_xf.interpolate_with(_cur_xf, Engine.get_physics_interpolation_fraction())
	_jolt = _jolt.lerp(Vector3.ZERO, 1.0 - exp(-9.0 * delta))
	_susp_v += (-_susp * 140.0 - _susp_v * 11.0) * delta
	_susp = clampf(_susp + _susp_v * delta, -0.08, 0.04)
	_visual.global_transform = Transform3D(xf.basis, xf.origin + xf.basis * (_jolt + Vector3(0.0, _susp, 0.0)))
	_hint_t = maxf(_hint_t - delta, 0.0)
	_center_t = maxf(_center_t - delta, 0.0)
	_hit_warn_t = maxf(_hit_warn_t - delta, 0.0)
	_hit_fx_t = maxf(_hit_fx_t - delta, 0.0)
	_update_parts(delta)
	_update_fx(delta)
	_update_cameras(delta)
	_update_dash(delta)


func _update_parts(delta: float) -> void:
	for i in 4:
		var tgt := LEG_FLY if not landed else _leg_target[i]
		_leg_ext[i] = lerpf(_leg_ext[i], tgt, 1.0 - exp(-(12.0 if landed else 3.0) * delta))
		(_feet[i] as Node3D).position = (Build.FEET[i] as Vector3) + Vector3(0.0, -_leg_ext[i] - _susp, 0.0)
	var lc := global_transform.basis.inverse() * _w_now
	var st := Vector3(clampf(lc.x * 0.22, -0.25, 0.25), 0.0, clampf(lc.z * 0.15 - lc.y * 0.1 - _in.x * 0.08, -0.25, 0.25))
	if landed:
		st = Vector3.ZERO
	_stick.rotation = _stick.rotation.lerp(st, 1.0 - exp(-10.0 * delta))
	var thr := clampf(maxf(_thr.z, 0.0) / MAIN_ACC, 0.0, 1.0) if not landed else 0.0
	var tx := lerpf(0.35, -0.35, thr)
	tx = lerpf(tx, -0.45, _boost)
	_throttle.rotation.x = lerpf(_throttle.rotation.x, tx, 1.0 - exp(-10.0 * delta))


func _update_fx(delta: float) -> void:
	var on := pilot != null or not landed or net_powered or _bot != null
	_power = move_toward(_power, 1.0 if on else 0.0, delta * (1.0 if on else 0.5))
	_lights_k = move_toward(_lights_k, 1.0 if (_lights and _power > 0.5) else 0.0, delta * 4.0)
	var main_k := clampf(maxf(_thr.z, 0.0) / MAIN_ACC, 0.0, 1.4) if not landed else 0.0
	var vt := clampf(_thr.y / LIFT_ACC, 0.0, 1.0) if not landed else _spool * 0.85
	for pl: Array in _plumes:
		var piv: Node3D = pl[0]
		var m: ShaderMaterial = pl[1]
		var inten: float
		var stretch: float
		if bool(pl[2]):
			inten = _power * vt * 1.15
			stretch = 0.35 + vt * 0.75
		else:
			inten = _power * (0.0 if landed else 0.12 + main_k * 0.75 + _boost * 0.35)
			stretch = 0.25 + main_k * 0.6 + _boost * 0.7
		m.set_shader_parameter("intensity", minf(inten, 1.1))
		m.set_shader_parameter("stretch", stretch)
		m.set_shader_parameter("hot", _boost)
		piv.visible = inten > 0.03
	_mat_emit.set_shader_parameter("power", _power)
	_mat_emit.set_shader_parameter("lights", _lights_k)
	_mat_emit.set_shader_parameter("engine", main_k * _power)
	_mat_emit.set_shader_parameter("boost", _boost)
	_mat_emit.set_shader_parameter("vtol", vt * _power)
	# Master caution below 30 %: the glare-shield lamp blinks red (with a little red light in the
	# cockpit) and the alarm sounds for whoever sits inside.
	var caution := hp < hp_max * 0.3 and _power > 0.5
	_mat_emit.set_shader_parameter("warn", 1.0 if caution else 0.0)
	var blink := 1.0 if fmod(_t * 2.0, 1.0) > 0.5 else 0.0
	_caution_light.light_energy = 0.35 * blink if caution else 0.0
	_caution_light.visible = caution
	_audio.alarm(caution and pilot != null)
	var dmg := 1.0 - hp / hp_max
	# Smoke trail from the engine bay once badly hit, thicker as it gets worse.
	_dmg_smoke.emitting = dmg > 0.45
	if _dmg_smoke.emitting:
		_dmg_smoke.amount_ratio = clampf((dmg - 0.45) * 2.2, 0.25, 1.0)
		(_dmg_smoke.process_material as ParticleProcessMaterial).gravity = -_g * 0.12
	_mat_ext.set_shader_parameter("soot", dmg)
	_mat_glass.set_shader_parameter("damage", dmg)
	_engine_light.light_energy = _power * (main_k * 1.3 + _boost * 1.4)
	_engine_light.visible = _engine_light.light_energy > 0.02
	var low := 1.0 - smoothstep(1.0, 7.0, _clear) if not landed else 1.0
	_ground_light.light_energy = vt * _power * 1.3 * low
	_ground_light.visible = _ground_light.light_energy > 0.02
	_land_light.light_energy = 5.0 * _lights_k
	_land_light.visible = _lights_k > 0.01
	for nl: OmniLight3D in _nav_lights:
		nl.light_energy = 0.5 * _lights_k
		nl.visible = _lights_k > 0.01
	var ph := fmod(_t * 0.75, 1.0)
	var flash := 1.0 if (ph < 0.04 or (ph > 0.12 and ph < 0.15)) else 0.0
	_strobe.light_energy = 2.2 * _lights_k * flash
	_strobe.visible = _strobe.light_energy > 0.01
	_cabin_light.light_energy = 0.14 * _power
	_cabin_light.visible = _power > 0.02
	_screen_light.light_energy = 0.1 * _power
	_screen_light.visible = _power > 0.02
	# Downwash dust on the ground below.
	var dusty := vt * _power > 0.25 and (landed or _clear < 6.0)
	_dust.emitting = dusty
	if dusty:
		var gp := global_position - _up * maxf(_clear if not landed else 0.0, 0.0)
		_dust.global_transform = Transform3D(Build._basis_y(_up), gp + _up * 0.1)
		_dust.amount_ratio = clampf(1.0 - (_clear if not landed else 0.0) / 6.0, 0.25, 1.0) * clampf(vt * 1.4, 0.0, 1.0)
		if _body != null and _body.get("cfg") is Dictionary:
			var cd = (_body.get("cfg") as Dictionary).get("col_dust")
			if cd is Color:
				(_dust.process_material as ParticleProcessMaterial).color = (cd as Color).lightened(0.1)
	_audio.update(delta, _power, main_k, vt, _boost, _spool, linear_velocity.length() if not freeze else 0.0)


func _update_cameras(delta: float) -> void:
	if pilot == null:
		return
	var xf := _visual.global_transform
	var b := xf.basis.orthonormalized()
	_shake = maxf(_shake - delta * 1.5, 0.0)
	_shake_t += delta
	if not free_looking():
		_look = _look.move_toward(Vector2.ZERO, delta * 3.0 * maxf(_look.length(), 0.25))
	_look_s = _look_s.lerp(_look, 1.0 - exp(-20.0 * delta))
	var rumble := 0.0
	if not landed:
		rumble = 0.0015 * clampf(maxf(_thr.z, 0.0) / MAIN_ACC, 0.0, 1.4) + 0.0035 * _boost + 0.001 * clampf(_thr.y / LIFT_ACC, 0.0, 1.0)
	rumble += 0.004 * _spool
	var t := _shake_t
	var sk := _shake * _shake * 0.05 + rumble
	var srot := Vector3(sin(t * 23.0) + 0.6 * sin(t * 9.1), sin(t * 19.0 + 1.3) + 0.5 * sin(t * 7.3), (sin(t * 15.0 + 0.7)) * 0.5) * sk
	if not chase_view:
		# The eye stays where it is (rotation only, a few cm of g-load at most) and the head turns
		# no further than the limits: within those nothing of the cabin comes nearer than ~0.25 m.
		var la := b.inverse() * _aim
		var follow := 0.0 if landed else 0.35
		var yaw := clampf(atan2(-la.x, -la.z) * follow + _look_s.x, -LOOK_YAW, LOOK_YAW)
		var pitch := clampf(asin(clampf(la.y, -1.0, 1.0)) * follow * 0.8 + _look_s.y - 0.12, -LOOK_DOWN, LOOK_UP)
		var head := Basis.from_euler(Vector3(pitch, yaw, 0.0), EULER_ORDER_YXZ)
		var off := Vector3(-_thr.x * 0.002, -(_thr.y - _g.length()) * 0.0015, _thr.z * 0.003) if not landed else Vector3.ZERO
		off = off.clamp(Vector3(-0.025, -0.025, -0.03), Vector3(0.025, 0.02, 0.035))
		_head_off = _head_off.lerp(off, 1.0 - exp(-6.0 * delta))
		_cam.transform = Transform3D(head * Basis.from_euler(srot), Build.EYE + _head_off)
		_cam.fov = clampf(Settings.fov + 6.0, 70.0, 100.0) + _boost * 4.0
		_check_eye_terrain(delta)
		return
	_eye_fade = 0.0
	# Chase: hangs back behind and above, lags the turns a little, looks toward the aim.
	var fwd := -b.z
	var look := (fwd * 0.7 + _aim * 0.3).normalized()
	var cam_up := b.y.lerp(_up, 0.6 * _near).normalized()
	if absf(look.dot(cam_up)) > 0.97:
		cam_up = b.y
	var target := Basis.looking_at(look, cam_up)
	if not _chase_init:
		_chase_b = target
		_chase_init = true
		_chase_d = -1.0
	else:
		_chase_b = Basis(_chase_b.get_rotation_quaternion().slerp(target.get_rotation_quaternion(), 1.0 - exp(-4.5 * delta)))
	var orbit := Basis(_chase_b.y.normalized(), _look_s.x) * Basis(_chase_b.x.normalized(), _look_s.y * 0.6)
	var cb := (orbit * _chase_b).orthonormalized()
	var pivot := xf * Vector3(0.0, 1.3, 0.3)
	var arm := cb.z * (8.5 + _boost * 2.0) + cb.y * 2.2
	var want := arm.length()
	var dir := arm / want
	# Pull in before terrain: the density field (works where no collision exists), then a physics ray
	# for the last metres (rocks); the arm shortens at once and lengthens again slowly.
	var reach := want
	if _body != null and _body.has_method("raycast_density"):
		var h: Dictionary = _body.call("raycast_density", pivot, pivot + dir * want, 0.6, true)
		if not h.is_empty():
			reach = minf(reach, float(h["distance"]) - 0.7)
	var q := PhysicsRayQueryParameters3D.create(pivot, pivot + dir * want, Game.LAYER_TERRAIN, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		reach = minf(reach, pivot.distance_to(hit["position"]) - 0.7)
	reach = maxf(reach, 0.0)
	if _chase_d < 0.0 or reach < _chase_d:
		_chase_d = reach
	else:
		_chase_d = lerpf(_chase_d, reach, 1.0 - exp(-2.5 * delta))
	var pos := pivot + dir * _chase_d
	if _chase_d < 3.2:
		# Too close to stay behind the hull (a wall right behind): look over the canopy instead.
		pos = pivot + (cb.y * 2.4 + cb.z * 0.6) * (1.0 - _chase_d / 3.2) + dir * _chase_d
	var aim_pt := pivot - cb.z * 30.0
	_chase.global_transform = Transform3D(Basis.looking_at(aim_pt - pos, cb.y) * Basis.from_euler(srot), pos)
	_chase.fov = 70.0 + _boost * 6.0


## Cockpit view: terrain reaching the eye (a crater or tunnel wall through the canopy) fades the
## view to dark (skiff_overlay.gd) instead of showing the inside of the ground.
func _check_eye_terrain(delta: float) -> void:
	_eye_fade_t -= delta
	if _eye_fade_t <= 0.0:
		_eye_fade_t = 0.1
		var tgt := 0.0
		if _body != null and _alt < 40.0:
			var e := _cam.global_position
			var d := float(_body.call("density_at", e))
			var ahead := float(_body.call("density_at", e - _cam.global_transform.basis.z * 0.15))
			tgt = clampf((0.45 - minf(d, ahead)) / 0.5, 0.0, 1.0)
		set_meta("fade_target", tgt)
	var ft := float(get_meta("fade_target", 0.0))
	_eye_fade = move_toward(_eye_fade, ft, delta * 4.0)


## 0..1: how dark the cockpit view should be (terrain at the eye).
func eye_fade() -> float:
	return _eye_fade if not chase_view else 0.0


func _update_dash(delta: float) -> void:
	_dash_t -= delta
	var powered := _power > 0.3
	# Unchanged standby: nothing to draw. Powered: ~20 frames a second.
	if powered == _dash_on and (not powered or _dash_t > 0.0):
		return
	_dash_t = 0.05
	var cam := get_viewport().get_camera_3d()
	if powered and _dash_on and cam != null and cam.global_position.distance_to(global_position) > 40.0:
		return
	_dash_on = powered
	var d: Dictionary = _dash.data
	d["power"] = powered
	if powered:
		var b := global_transform.basis.orthonormalized()
		var v := hud_velocity()
		var fwd := -b.z
		d["speed"] = v.length()
		d["vspeed"] = v.dot(_up)
		d["clear"] = 0.0 if landed else _clear
		d["thrust"] = clampf(maxf(_thr.z, 0.0) / MAIN_ACC, 0.0, 1.0) if not landed else _spool
		d["boost"] = _boost
		d["pitch"] = asin(clampf(fwd.dot(_up), -1.0, 1.0))
		var ul := b.inverse() * _up
		d["roll"] = atan2(ul.x, ul.y)
		d["grav"] = _g.length()
		d["hp"] = hp / hp_max
		d["lights"] = _lights
		var targets: Array = []
		for body in Bodies.all():
			if not is_instance_valid(body):
				continue
			var dist := global_position.distance_to((body as Node3D).global_position) - float(body.get("radius"))
			var home: bool = body == Game.planet
			targets.append([UI.upper_tr(str(body.get("display_name"))), maxf(dist, 0.0),
					Color(0.45, 0.92, 0.6) if home else Color(1.0, 0.62, 0.35)])
		d["targets"] = targets
		var mode := "UÇUŞ"
		var mc := Color(0.42, 0.85, 1.0)
		var sub := ""
		if landed:
			mode = "KALKIŞ…" if _spool > 0.05 else "YERDE"
			sub = "BOŞLUK: kalk  ·  F: in"
		elif pilot == null and _bot == null:
			mode = "OTOMATİK İNİŞ"
			mc = Color(1.0, 0.72, 0.3)
		elif _near > 0.3 and _clear < 25.0:
			mode = "İNİŞ"
			sub = "Ctrl: alçal  ·  yere değince durur"
		elif _boost > 0.3:
			mode = "TAKVİYE"
			mc = Color(1.0, 0.72, 0.3)
		elif _near < 0.2:
			mode = "AÇIK UZAY"
			sub = "tutum serbest"
		d["mode"] = mode
		d["mode_color"] = mc
		d["sub"] = sub
		var warn := ""
		var pct := roundi(hp / hp_max * 100.0)
		if _hit_warn_t > 0.0:
			warn = "GÖVDE HASARI %%%d" % pct
		elif hp < hp_max * 0.3:
			warn = "ANA UYARI · GÖVDE %%%d" % pct
		elif not landed and _near > 0.3 and _clear < 20.0 and -v.dot(_up) > _sink_max(_clear) + 1.5:
			warn = "ALÇALMA HIZLI"
		d["warn"] = warn
		if radar_mode < Dash.RADAR_RANGES.size():
			d["radar"] = Dash.radar_scan(self, _up, float(Dash.RADAR_RANGES[radar_mode]))
		else:
			d.erase("radar")
		_dash_extra(d)
	_dash.refresh(0.05)


# ==================================================================================================
# Overlay helpers (skiff_overlay.gd)
# ==================================================================================================

func nose_dir() -> Vector3:
	return -_visual.global_transform.basis.z.normalized()


func aim_dir() -> Vector3:
	return _aim


func clearance_text() -> String:
	if landed:
		return "0 m"
	if _clear > 9000.0:
		return "—"
	return ("%.1f m" % _clear) if _clear < 100.0 else ("%d m" % roundi(_clear))


func hint_text() -> String:
	if landed:
		return "BOŞLUK / W kalk  ·  fare etrafa bak  ·  V kamera  ·  L ışıklar  ·  R radar  ·  F in"
	if _hint_t > 0.0:
		return "Fare yön  ·  W/S itki  ·  A/D dön  ·  Q/E yana  ·  Boşluk/Ctrl yukarı/aşağı  ·  Shift takviye  ·  sağ tık bak  ·  V kamera"
	return ""


func hint_alpha() -> float:
	if landed:
		return 0.85
	return clampf(_hint_t / 2.0, 0.0, 1.0) * 0.85


func center_text() -> String:
	return _center_msg if _center_t > 0.0 else ""


func _flash(s: String) -> void:
	_center_msg = s
	_center_t = 2.2


# ==================================================================================================
# Variant hooks (armed_skiff.gd overrides these; the plain Mekik keeps the defaults)
# ==================================================================================================

## Livery key for skiff_build.gd meshes() / add_decals(): "home", "rival", "armed", "rival_armed"
## (by `team`, set before add_child).
func _livery() -> String:
	return "rival" if team == "rival" else "home"


## Registration painted on the hull (add_decals): "YR-0N" home, "RK-0N" rival (a number per team).
func _registration() -> String:
	if _reg == "":
		var key := "rival" if team == "rival" else "home"
		var n := int(_serial.get(key, 0)) + 1
		_serial[key] = n
		_reg = "%s-%02d" % ["RK" if key == "rival" else "YR", n]
	return _reg


## After the hull, cabin, lights and cameras exist: extra meshes, shapes, nodes.
func _build_extra() -> void:
	pass


## Every physics tick after the controls were read (not in multiplayer puppet mode).
func _weapons_step(_delta: float) -> void:
	pass


## Seated input before the flight controls see it; true = consumed.
func _weapons_input(_event: InputEvent) -> bool:
	return false


## The free-look button while flying (the plain Mekik: right mouse).
func _free_look_held() -> bool:
	return Input.is_action_pressed("tool_alt")


## Extra instrument values for the dash (skiff_dash.gd), called while powered.
func _dash_extra(_d: Dictionary) -> void:
	pass


# ==================================================================================================
# Multiplayer (scripts/net/net_world.gd): puppet mode, state out / in, host hits
# ==================================================================================================

## On: another peer flies it (frozen kinematic, follows the network). Off: local physics take over
## where the network left it (landed: parked on its legs, else flying on with the last velocity).
func net_set_puppet(on: bool) -> void:
	if on == net_puppet:
		return
	net_puppet = on
	_v_valid = false
	_impact = 0.0
	if on:
		_net_buf = load("res://scripts/net/snap_buffer.gd").new()
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true
		return
	net_powered = false
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	if landed:
		freeze = true
		_resettle_t = 0.2
	else:
		freeze = false
		linear_velocity = _net_vel
		angular_velocity = Vector3.ZERO
		_hold_r = -1.0
	_reset_interp()


## The state the authority sends (net_world.gd encodes it).
func net_state() -> Dictionary:
	return {"xf": global_transform, "vel": Vector3.ZERO if freeze else linear_velocity, "landed": landed,
			"thr": _thr, "boost": _boost, "spool": _spool, "powered": pilot != null or _bot != null, "lights": _lights}


## A state from the authority (puppet only), stamped with the sender's clock.
func net_push(t_ms: int, s: Dictionary) -> void:
	if not net_puppet or _net_buf == null:
		return
	_net_buf.push(t_ms, s)


func _net_follow() -> void:
	var smp: Array = _net_buf.sample() if _net_buf != null else []
	if smp.is_empty():
		return
	var a: Dictionary = smp[0]
	var b: Dictionary = smp[1]
	var t: float = smp[2]
	var xa: Transform3D = a["xf"]
	var xb: Transform3D = b["xf"]
	var xf: Transform3D
	if t <= 1.0:
		xf = Transform3D(xa.basis.orthonormalized().slerp(xb.basis.orthonormalized(), t), xa.origin.lerp(xb.origin, t))
	else:
		var span := 0.05
		xf = Transform3D(xb.basis.orthonormalized(), xb.origin + (b["vel"] as Vector3) * (t - 1.0) * span)
	global_transform = xf
	var tc := clampf(t, 0.0, 1.0)
	_net_vel = (a["vel"] as Vector3).lerp(b["vel"], tc)
	var was := landed
	landed = bool(b["landed"])
	if landed and not was:
		_audio.touchdown(0.4)
		_audio.gear()
	_thr = (a["thr"] as Vector3).lerp(b["thr"], tc)
	_boost = lerpf(float(a["boost"]), float(b["boost"]), tc)
	_spool = float(b["spool"])
	net_powered = bool(b["powered"])
	_lights = bool(b["lights"])


## A hit the host applied (feel + the host's hp). Destruction comes with the host's own event.
func net_hit(amount: float, from_pos: Vector3, impulse: Vector3, new_hp: float) -> void:
	if destroyed or _dying:
		return
	_net_hit = true
	hp = new_hp + amount
	take_damage(amount, from_pos, impulse if not net_puppet else Vector3.ZERO)
	hp = new_hp
	_net_hit = false


# ==================================================================================================
# AI pilot (2026-10-05): the bots fly it (scripts/war/rival_team.gd skiff raids)
# ==================================================================================================
# Hooks above (one line each): _read_input -> _ai_step (the AI's inputs instead of the keyboard and
# mouse); _piloted() where the flight model asked "pilot != null" (_landed_step, _flight_checks,
# _fly_velocity, _attitude); interact / get_interact_prompt -> _ai_blocks / _ai_prompt; take_damage
# -> ai_under_fire; _destroy -> _ai_eject_crew; _update_fx / net_state: powered with a bot aboard;
# the puppet branch -> _ai_puppet_seat. The AI only writes _aim, _in, _yaw_in and _boost_in: the
# flight model, its limits and its assists are the player's, no other force.
# Per physics tick (_ai_step): a phase sets the wanted world velocity and nose direction
# (_ai_v_des / _ai_nose_des), the variant's _ai_combat may take them over (armed_skiff.gd), the
# look-ahead pulls up, _ai_apply turns them into stick inputs, the jinking goes on top.
#   CLIMB     straight up off the pad (lift jets) to AI_CLIMB_CLEAR, drifting onto the course
#   CRUISE    toward the cruise point (AI_CRUISE_ALT over the target; land = false: the target), round
#             any planet in the way (_ai_route: a waypoint outside radius + AI_KEEP_OUT), boost far
#             out, slowing with sqrt(2·AI_BRAKE·d); the landing spot search starts AI_APPROACH out
#   APPROACH  hovers near the cruise point until the search has a spot
#   DESCEND   a glide slope onto the spot (height ~0.9 × the horizontal distance), over it straight
#             down: the flight model's auto-flare sets it on its legs (= arrived). A spot it cannot
#             stand on (touchdown refused twice) or AI_DESCEND_TIMEOUT s: the next one
#   HOVER     land = false: holds at the target
# Landing spot (_ai_eval_spot, AI_SPOT_EVALS a tick): rings around the target on its planet, the
# density field: level ground (AI_SPOT_FLAT, the four feet within AI_SPOT_STEP), not in a crater /
# dug shaft (AI_SPOT_DUG below the untouched surface), AI_SPOT_CLEAR from every structure and skiff;
# the nearest to the target wins. Look-ahead (_ai_avoid): points 0.5-2.8 s along the velocity
# (density) and a physics ray 2 s ahead (structures, rocks): pull up for 0.8 s.

var _ai_fail_n := 0                # touchdowns refused on the current spot


func _piloted() -> bool:
	return pilot != null or (_bot != null and not net_puppet)


func ai_pilot() -> Node3D:
	return _bot if _bot != null and is_instance_valid(_bot) else null


func ai_crew() -> Array:
	var out: Array = []
	for e: Dictionary in _crew:
		if is_instance_valid(e["bot"]):
			out.append(e["bot"])
	return out


func ai_board(bot: Node3D) -> bool:
	if bot == null or not is_instance_valid(bot) or destroyed or _dying or net_puppet or pilot != null or not landed:
		return false
	for e: Dictionary in _crew:
		if e["bot"] == bot:
			return true
	if _crew.size() >= 2:
		return false
	var bt = bot.get("team")
	if bt is String and bt != "" and bt != team:
		return false
	var e := {"bot": bot, "dmg": bot.is_in_group(Game.DAMAGEABLE), "shapes": []}
	if bool(e["dmg"]):
		bot.remove_from_group(Game.DAMAGEABLE)
	for cs in bot.find_children("*", "CollisionShape3D", true, false):
		if not (cs as CollisionShape3D).disabled:
			(cs as CollisionShape3D).disabled = true
			(e["shapes"] as Array).append(cs)
	bot.visible = false
	_crew.append(e)
	if _crew.size() == 1:
		_bot = bot
		_ai_goto = false
		_ai_arrive = false
		_lights = true
		continuous_cd = true
		_audio.startup()
	_ai_seats_refresh()
	_ai_carry()
	return true


func ai_exit(bot: Node3D = null) -> Transform3D:
	if _crew.is_empty() or not (landed or _dying or destroyed):
		return Transform3D()
	var i := _crew.size() - 1
	if bot != null:
		i = -1
		for k in _crew.size():
			if _crew[k]["bot"] == bot:
				i = k
				break
		if i < 0:
			return Transform3D()
	var e: Dictionary = _crew[i]
	_crew.remove_at(i)
	var xf := _ai_exit_xf(-1.0 if i == 0 else 1.0)          # the pilot's door (left), the passenger's
	_ai_release(e, true)
	_ai_crew_changed()
	return xf


func ai_fly_to(world_pos: Vector3, land: bool) -> void:
	if destroyed or _dying or net_puppet:
		return
	_ai_goto = true
	_ai_arrive = false
	_ai_target = world_pos
	_ai_land = land
	_ai_tbody = Bodies.nearest(world_pos)
	_ai_spot = Vector3.INF
	_ai_search = []
	_ai_best = {}
	_ai_sstate = 0
	_ai_bad = []
	_ai_task_t = 0.0
	_ai_lifted = not landed
	_ai_wp = Vector3.INF
	_ai_route_t = 0.0
	_ai_serial += 1
	_ai_engaged = false
	_ai_set_phase(AiPhase.CLIMB if (landed or _clear < _ai_climb_clear()) else AiPhase.CRUISE)


func ai_hold() -> void:
	_ai_goto = false
	_ai_arrive = false
	_ai_set_phase(AiPhase.HOVER)


func ai_busy() -> bool:
	return _ai_goto and not _ai_arrive


func ai_arrived() -> bool:
	return _ai_arrive


## Near misses (flak_round.gd bursts within 30 m) and hits: AI_JINK_TIME s of jinking.
func ai_under_fire(_from_pos := Vector3.ZERO) -> void:
	if _bot == null or destroyed or _dying or net_puppet:
		return
	if _jink_t <= 0.0:
		_jink_next = 0.0
	_jink_t = AI_JINK_TIME


## A crewed rival skiff flying at our planet, for the war HUD on a multiplayer client (the rival team
## runs on the host only): a co-op puppet that is powered, airborne and closing on Game.planet.
static func ai_inbound(tree: SceneTree) -> Node3D:
	if tree == null or not Net.active or Net.pvp() or Game.planet == null:
		return null
	var c: Vector3 = (Game.planet as Node3D).global_position
	for s in tree.get_nodes_in_group("skiff"):
		if not (s is Node3D) or not is_instance_valid(s) or Game.team_of(s) == "home":
			continue
		if not bool(s.get("net_powered")) or bool(s.get("landed")):
			continue
		var v = s.get("_net_vel")
		if v is Vector3 and (v as Vector3).dot(c - (s as Node3D).global_position) > 0.0:
			return s
	return null


# --- Crew --------------------------------------------------------------------------------------------

## The bot back in the world: "damageable" again, its collision shapes on (unless it died meanwhile:
## its own respawn turns its capsule back on), visible.
func _ai_release(e: Dictionary, alive: bool) -> void:
	var b = e["bot"]
	if b == null or not is_instance_valid(b):
		return
	if bool(e["dmg"]) and not (b as Node).is_in_group(Game.DAMAGEABLE):
		(b as Node).add_to_group(Game.DAMAGEABLE)
	if alive:
		for cs in e["shapes"]:
			if is_instance_valid(cs):
				(cs as CollisionShape3D).disabled = false
		(b as Node3D).visible = true


func _ai_crew_changed() -> void:
	if _crew.is_empty():
		_bot = null
		_ai_goto = false
		_ai_arrive = false
		_jink_t = 0.0
		continuous_cd = pilot != null
		if not destroyed and not _dying and pilot == null:
			_audio.shutdown()
	else:
		_bot = _crew[0]["bot"]
	_ai_seats_refresh()


## Crew members that left without ai_exit (freed, or no longer aboard by their own account).
func _ai_prune() -> void:
	var changed := false
	for i in range(_crew.size() - 1, -1, -1):
		var b = _crew[i]["bot"]
		var gone: bool = b == null or not is_instance_valid(b) or not (b as Node).is_inside_tree()
		if not gone and b.has_method("is_aboard") and not bool(b.call("is_aboard")):
			gone = true
		if gone:
			var e: Dictionary = _crew[i]
			_crew.remove_at(i)
			var alive: bool = b != null and is_instance_valid(b) and not (b.has_method("is_dead") and bool(b.call("is_dead")))
			_ai_release(e, alive)
			changed = true
	if changed:
		_ai_crew_changed()


## The skiff carries its crew along (the pilot's seat, the passenger's).
func _ai_carry() -> void:
	var xf := global_transform
	for i in _crew.size():
		var b = _crew[i]["bot"]
		if b != null and is_instance_valid(b):
			(b as Node3D).global_transform = xf * Transform3D(Basis(), _ai_seat_pos(i))


static func _ai_seat_pos(seat: int) -> Vector3:
	var sp := Build.SEAT_POS
	return sp if seat == 0 else Vector3(-sp.x, sp.y, sp.z)


## Where a bot steps out: beside its door on the ground (else the other door, the nose, the tail, the
## hull top); being destroyed: beside the hull where it is.
func _ai_exit_xf(side: float) -> Transform3D:
	var xf := global_transform.orthonormalized()
	var up := _up
	var fwd := -xf.basis.z
	if not landed or _body == null:
		return _stand_xf(xf * Vector3(side * 1.9, 1.0, -0.4), up, fwd)
	for off: Vector3 in [Vector3(side * 1.75, 0.0, -0.4), Vector3(side * 1.75, 0.0, 0.9), Vector3(-side * 1.75, 0.0, 0.4),
			Vector3(0.0, 0.0, -3.3), Vector3(0.0, 0.0, 3.5)]:
		var from := xf * off + up * 2.5
		var d := _ground_dist(_body, from, -up, 8.0)
		if d <= 8.0:
			var gp := from - up * d
			if float(_body.call("density_at", gp + up * 1.0)) > 0.3:
				return _stand_xf(gp + up * 0.05, up, fwd)
	return _stand_xf(xf * Vector3(0.0, 2.25, 0.8), up, fwd)


## Destroyed with bots aboard: each is thrown out (its own exit, so its state is right) and killed
## through its take_damage with an impulse (its ragdoll flies off the wreck).
func _ai_eject_crew(center: Vector3, up: Vector3, vel: Vector3) -> void:
	if _crew.is_empty():
		return
	var xb := global_transform.basis.orthonormalized()
	var bots := ai_crew()
	for i in bots.size():
		var b: Node3D = bots[i]
		if b.has_method("exit_skiff") and b.has_method("is_aboard") and bool(b.call("is_aboard")):
			b.call("exit_skiff")
		else:
			var xf := ai_exit(b)
			if xf.origin != Vector3.ZERO:
				b.global_transform = xf
		var side := -1.0 if i == 0 else 1.0
		if b.has_method("take_damage"):
			var hv = b.get("hp")
			var amt := (float(hv) if hv != null else 100.0) + 500.0
			b.call("take_damage", amt, center, up * 6.0 + xb.x * side * 3.5 + vel * 0.5)
	for e: Dictionary in _crew:
		_ai_release(e, false)
	_crew.clear()
	_bot = null


# --- Seated astronauts (through the canopy) ------------------------------------------------------------

func _ai_seats_refresh() -> void:
	var n := _crew.size()
	_seat_body = _ai_seat_set(_seat_body, 0, n >= 1)
	_seat_body2 = _ai_seat_set(_seat_body2, 1, n >= 2)


func _ai_seat_set(cur: Node3D, seat: int, on: bool) -> Node3D:
	if not on:
		if cur != null and is_instance_valid(cur):
			cur.visible = false
		return cur
	if cur == null or not is_instance_valid(cur):
		cur = _ai_make_seated(seat)
	cur.visible = true
	return cur


## An astronaut sitting in `seat` (remote_avatar.gd's seat pose: hips on the pan, leaning back, thighs
## forward, the pilot's hands on the stick and the throttle), riding the hull's visual.
func _ai_make_seated(seat: int) -> Node3D:
	var root := Node3D.new()
	root.position = _ai_seat_pos(seat)
	_visual.add_child(root)
	var a = Astronaut.new()
	root.add_child(a)
	a.set_first_person(false)
	a.set_process(false)
	for n in a.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if gi is Label3D:
			if team == "rival":
				(gi as Label3D).text = "RAKİP"
		elif not (gi is MeshInstance3D and (gi as MeshInstance3D).skin != null):
			gi.visibility_range_end = 45.0
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	a.reset_pose()
	var hips: Node3D = a.hips
	hips.rotation = Vector3(AI_SIT_LEAN, 0.0, 0.0)
	var hip_h: float = (a.rest_local(hips) as Transform3D).origin.y
	a.position = Vector3(AI_SIT_HIPS.x, AI_SIT_HIPS.y - hip_h, AI_SIT_HIPS.z)
	var flies := seat == 0
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		(a.thigh[i] as Node3D).rotation = Vector3(1.32, 0.0, side * 0.06)
		(a.shin[i] as Node3D).rotation = Vector3(-0.55, 0.0, 0.0)
		if flies and i == 0:
			(a.shoulder[i] as Node3D).rotation = Vector3(0.75, 0.0, -side * 0.25)
			(a.elbow[i] as Node3D).rotation = Vector3(0.55, 0.0, 0.0)
		elif flies:
			(a.shoulder[i] as Node3D).rotation = Vector3(0.6, 0.0, side * 0.12)
			(a.elbow[i] as Node3D).rotation = Vector3(0.75, 0.0, 0.0)
		else:
			(a.shoulder[i] as Node3D).rotation = Vector3(0.35, 0.0, side * 0.1)
			(a.elbow[i] as Node3D).rotation = Vector3(1.0, 0.0, 0.0)
	a.sync_skeleton()
	return root


## Multiplayer client: a powered rival puppet (co-op: only the AI flies those) shows its pilot.
func _ai_puppet_seat(delta: float) -> void:
	_ai_puppet_t -= delta
	if _ai_puppet_t > 0.0:
		return
	_ai_puppet_t = 0.5
	var on := net_powered and team != "home" and Net.active and not Net.pvp()
	if on or (_seat_body != null and is_instance_valid(_seat_body)):
		_seat_body = _ai_seat_set(_seat_body, 0, on)


# --- The player at the door ---------------------------------------------------------------------------

## A rival puppet a bot flies (multiplayer co-op client) / bots aboard (host, single player).
func _ai_crewed() -> bool:
	if not _crew.is_empty():
		return true
	return net_puppet and net_powered and team != "home" and Net.active and not Net.pvp()


## interact(): true = the player may not board. An EMPTY rival skiff is captured in single player
## (team "home", the paint stays; rival_team.gd notices and gives it up).
func _ai_blocks(p) -> bool:
	if _ai_crewed():
		return true
	if team == "home" or (Net.active and Net.pvp()):
		return false
	if Net.active:
		if Game.hud:
			Game.hud.alert("Rakip mekiğine çok oyunculu modda binilemez", 1, "skiff", 1.8)
		return true
	if p != Game.player:
		return true
	team = "home"
	set_meta("team", "home")
	_ai_goto = false
	_ai_arrive = false
	if Game.hud:
		Game.hud.alert("Rakip mekiği ele geçirildi!", 1, "skiff", 2.5)
	if Game.sfx:
		Game.sfx.play("ding", -12.0, 1.1)
	return false


## get_interact_prompt(): "" = the normal one, "-" = none, else this one.
func _ai_prompt() -> String:
	if _ai_crewed():
		return "-"
	if team != "home" and not (Net.active and Net.pvp()):
		return "-" if Net.active else "Rakip mekiğini ele geçir"
	return ""


# --- Per tick ------------------------------------------------------------------------------------------

func _ai_set_phase(p: AiPhase) -> void:
	_ai_phase = p
	_ai_phase_t = 0.0


func _ai_climb_clear() -> float:
	if _ai_tbody != null and _ai_tbody == _body and global_position.distance_to(_ai_target) < AI_APPROACH:
		return 8.0                        # a short hop on the same planet
	return AI_CLIMB_CLEAR


## Horizontal part (tangent to the planet under the ship).
func _ai_flat(v: Vector3) -> Vector3:
	return v - _up * v.dot(_up)


## Where the crossing aims: AI_CRUISE_ALT over the target (land), else the target itself.
func _ai_goal() -> Vector3:
	if not _ai_land or _ai_tbody == null:
		return _ai_target
	return _ai_target + (_ai_target - _ai_tbody.global_position).normalized() * AI_CRUISE_ALT


func _ai_step(delta: float) -> void:
	_ai_prune()
	if _bot == null:
		return
	_ai_carry()
	_ai_v_des = Vector3.ZERO
	_ai_nose_des = Vector3.ZERO
	_ai_boost = false                      # (_ai_engaged: last tick's, the variant's _ai_combat sets it)
	if not _ai_goto or _ai_arrive:
		if not landed:
			# Holding: hover where it is (the flight model's height hold), still jinking under fire.
			_ai_nose_des = _ai_flat(-global_transform.basis.z)
			_ai_apply()
			_ai_jink_apply(delta)
		return
	_ai_task_t += delta
	_ai_phase_t += delta
	if landed:
		var near_spot := _ai_spot != Vector3.INF and global_position.distance_to(_ai_spot) < 12.0
		if _ai_land and ((_ai_lifted and (_ai_phase == AiPhase.DESCEND or near_spot or global_position.distance_to(_ai_target) < 15.0))
				or (not _ai_lifted and global_position.distance_to(_ai_target) < 4.0)):
			_ai_arrive = true
			return
		_ai_lifted = false
		_in.y = 1.0                        # lift off (the lift jets spool on the legs first)
		return
	_ai_lifted = true
	match _ai_phase:
		AiPhase.CLIMB:
			_ai_climb()
		AiPhase.CRUISE:
			_ai_cruise(delta)
		AiPhase.APPROACH:
			_ai_approach(delta)
		AiPhase.DESCEND:
			_ai_descend(delta)
		_:
			_ai_hover()
	_ai_combat(delta)
	_ai_avoid(delta)
	_ai_apply()
	_ai_jink_apply(delta)


func _ai_climb() -> void:
	var h := _ai_flat(_ai_next_wp(0.0, _ai_goal()) - global_position)
	if h.length_squared() < 1.0:
		h = _ai_flat(-global_transform.basis.z)
	var dir := h.normalized() if h.length_squared() > 1e-4 else Vector3.ZERO
	if _clear >= _ai_climb_clear() or _near < 0.35:
		_ai_set_phase(AiPhase.CRUISE)
	var k := clampf((_clear - 3.0) / 10.0, 0.0, 1.0)
	_ai_v_des = _up * CLIMB + dir * (3.0 + 9.0 * k)
	_ai_nose_des = dir


func _ai_cruise(delta: float) -> void:
	var goal := _ai_goal()
	var pos := global_position
	var dg := pos.distance_to(goal)
	var to := _ai_next_wp(delta, goal) - pos
	var spd := CRUISE * speed_k
	if dg > 140.0 and _clear > 20.0:
		_ai_boost = true
		spd = BOOST_SPEED * speed_k
	spd = minf(spd, sqrt(2.0 * AI_BRAKE * dg) + 2.0)
	if to.length_squared() > 0.01:
		_ai_v_des = to.normalized() * spd
		_ai_nose_des = to.normalized()
	if not _ai_land:
		if dg < 12.0:
			_ai_set_phase(AiPhase.HOVER)
		return
	if dg < AI_APPROACH:
		_ai_search_step()
	if _ai_spot != Vector3.INF and dg < AI_DESCEND_R and not _ai_engaged:
		_ai_set_phase(AiPhase.DESCEND)
	elif dg < 12.0:
		_ai_set_phase(AiPhase.APPROACH)


## Waiting for a landing spot: hover near the cruise point (or where it is, once over the target).
func _ai_approach(delta: float) -> void:
	var goal := _ai_goal()
	var to := goal - global_position
	var d := to.length()
	if d > 50.0:
		to = _ai_next_wp(delta, goal) - global_position
	if d > 1.0:
		_ai_v_des = to.normalized() * minf(d * 0.8, 10.0)
	if _clear < 6.0:
		_ai_v_des += _up * 2.0
	var tf := _ai_flat(_ai_target - global_position)
	_ai_nose_des = tf.normalized() if tf.length() > 4.0 else _ai_flat(-global_transform.basis.z)
	_ai_search_step()
	if _ai_spot != Vector3.INF and not _ai_engaged:
		_ai_set_phase(AiPhase.DESCEND)
	elif _ai_phase_t > 12.0 and _ai_spot == Vector3.INF:
		_ai_spot = _ai_target
		_ai_sstate = 3
		_ai_set_phase(AiPhase.DESCEND)


## Glide slope onto the spot, straight down over it; the auto-flare and touchdown are the model's.
func _ai_descend(delta: float) -> void:
	var b := _ai_tbody if _ai_tbody != null else _body
	if b == null or _ai_spot == Vector3.INF:
		_ai_set_phase(AiPhase.APPROACH)
		return
	var spot := _ai_spot
	var up_s := (spot - b.global_position).normalized()
	var rel := global_position - spot
	var y := rel.dot(up_s)
	var h := rel - up_s * y
	var hd := h.length()
	var vh := Vector3.ZERO
	if hd > 0.25:
		vh = -h / hd * minf(minf(sqrt(2.0 * AI_BRAKE * hd), hd * 1.2), 14.0)
	var vu := clampf((clampf(hd * 0.9, 0.0, AI_CRUISE_ALT) - y) * 0.7, -SINK, CLIMB)
	var v := linear_velocity
	var hs := (v - up_s * v.dot(up_s)).length()
	if hd < 1.6 and hs < 1.5:
		vu = -SINK                         # over the spot: down (the auto-flare cushions it)
	_ai_v_des = vh + up_s * vu
	_ai_nose_des = (-h / hd) if hd > 8.0 else _ai_flat(-global_transform.basis.z)
	# Touchdown refused (nothing to stand on under the feet: _touchdown set _touch_fail_t = 0.5 last
	# tick), something built on the spot meanwhile, or too long at it: another spot.
	var bad := false
	if _touch_fail_t > 0.49:
		_ai_fail_n += 1
		bad = _ai_fail_n >= 2
	_ai_check_t -= delta
	if _ai_check_t <= 0.0:
		_ai_check_t = 1.0
		if _ai_task_t < AI_LAND_GIVEUP and not _ai_spot_free(spot):
			bad = true
	if _ai_phase_t > AI_DESCEND_TIMEOUT and _ai_task_t < AI_LAND_GIVEUP:
		bad = true
	if bad:
		_ai_bad.append(spot)
		_ai_fail_n = 0
		_ai_spot = Vector3.INF
		_ai_sstate = 0
		if _ai_task_t >= AI_LAND_GIVEUP:
			_ai_spot = _ai_target          # (long enough: the target itself, unchecked)
			_ai_sstate = 3
			_ai_set_phase(AiPhase.DESCEND)
		else:
			_ai_set_phase(AiPhase.APPROACH)


func _ai_hover() -> void:
	var to := _ai_target - global_position
	var d := to.length()
	if d > 0.5:
		_ai_v_des = to / d * minf(sqrt(2.0 * AI_BRAKE * d), CRUISE * speed_k)
	var f := _ai_flat(to)
	_ai_nose_des = f.normalized() if f.length() > 4.0 else _ai_flat(-global_transform.basis.z)
	if d < 4.0 and linear_velocity.length() < 2.0:
		_ai_arrive = true


## The waypoint toward `goal` (re-planned 4× a second): round any planet in the way.
func _ai_next_wp(delta: float, goal: Vector3) -> Vector3:
	_ai_route_t -= delta
	if _ai_route_t <= 0.0 or _ai_wp == Vector3.INF:
		_ai_route_t = 0.25
		_ai_wp = _ai_route(global_position, goal)
	return _ai_wp


## A segment that passes within radius + AI_KEEP_OUT of a planet (between its ends) goes via a point
## pushed out of that sphere instead.
func _ai_route(from: Vector3, to: Vector3) -> Vector3:
	var seg := to - from
	var l2 := seg.length_squared()
	if l2 < 1.0:
		return to
	for pb in Bodies.all():
		if not is_instance_valid(pb):
			continue
		var c: Vector3 = (pb as Node3D).global_position
		var keep := float(pb.get("radius")) + AI_KEEP_OUT
		var t := clampf((c - from).dot(seg) / l2, 0.0, 1.0)
		if t <= 0.02 or t >= 0.98:
			continue
		var off := from + seg * t - c
		if off.length() >= keep:
			continue
		if off.length_squared() < 1e-4:
			off = seg.cross(Vector3.UP)
			if off.length_squared() < 1e-4:
				off = seg.cross(Vector3.RIGHT)
		return c + off.normalized() * keep * 1.15
	return to


# --- Landing spot -----------------------------------------------------------------------------------

func _ai_search_step() -> void:
	if _ai_spot != Vector3.INF or _ai_sstate >= 3:
		return
	var b := _ai_tbody
	if b == null or not b.has_method("raycast_density"):
		_ai_spot = _ai_target
		_ai_sstate = 3
		return
	if _ai_sstate == 0:
		_ai_search = _ai_rings([0.0, 4.0, 8.0, 12.0, 17.0])
		_ai_best = {}
		_ai_sstate = 1
	for k in AI_SPOT_EVALS:
		if _ai_search.is_empty():
			break
		var c: Vector2 = _ai_search.pop_front()
		var r := _ai_eval_spot(c.x, c.y)
		if not r.is_empty() and (_ai_best.is_empty() or float(r["score"]) > float(_ai_best["score"])):
			_ai_best = r
	if not _ai_search.is_empty():
		return
	if not _ai_best.is_empty():
		_ai_spot = _ai_best["p"]
		_ai_sstate = 3
	elif _ai_sstate == 1:
		_ai_search = _ai_rings([23.0, 30.0, 38.0])
		_ai_sstate = 2
	else:
		_ai_spot = _ai_target              # nothing better: the target itself
		_ai_sstate = 3


static func _ai_rings(radii: Array) -> Array:
	var out: Array = []
	for ring: float in radii:
		var n := 1 if ring <= 0.0 else 8
		for k in n:
			out.append(Vector2(ring, TAU * float(k) / float(n) + ring * 0.37))
	return out


## Candidate `ring` m (along the surface) from the target at angle phi: {} or {"p", "score"}.
func _ai_eval_spot(ring: float, phi: float) -> Dictionary:
	var b := _ai_tbody
	var c := b.global_position
	var R := float(b.get("radius"))
	var up_t := (_ai_target - c).normalized()
	var t1 := up_t.cross(Vector3.UP if absf(up_t.y) < 0.9 else Vector3.RIGHT).normalized()
	var t2 := up_t.cross(t1).normalized()
	var a := ring / maxf(R, 1.0)
	var dir := (up_t * cos(a) + (t1 * cos(phi) + t2 * sin(phi)) * sin(a)).normalized()
	var mh = b.get("max_height")
	var top := R + (float(mh) if mh != null else 10.0) + 6.0
	var h: Dictionary = b.call("raycast_density", c + dir * top, c + dir * maxf(R - 14.0, 1.0), 0.5, true)
	if h.is_empty():
		return {}
	var p: Vector3 = h["position"]
	if (h["normal"] as Vector3).dot(dir) < AI_SPOT_FLAT:
		return {}
	if p.distance_to(c) < R + float(b.call("surface_height_at", p)) - AI_SPOT_DUG:
		return {}                          # a crater / a dug shaft
	for q: Vector3 in _ai_bad:
		if q.distance_to(p) < 3.5:
			return {}
	if not _ai_spot_free(p):
		return {}
	var x := dir.cross(t2).normalized()
	var z := dir.cross(x).normalized()
	var lo := INF
	var hi := -INF
	for k in 4:
		var off := x * (1.4 if k % 2 == 0 else -1.4) + z * (2.4 if k < 2 else -2.4)
		var from := p + off + dir * 3.0
		var d := _ground_dist(b, from, -dir, 7.0)
		if d > 7.0:
			return {}
		lo = minf(lo, 3.0 - d)
		hi = maxf(hi, 3.0 - d)
	if hi - lo > AI_SPOT_STEP:
		return {}
	return {"p": p, "score": -p.distance_to(_ai_target) - (hi - lo) * 4.0}


## No structure / other skiff within its footprint + AI_SPOT_CLEAR.
func _ai_spot_free(p: Vector3) -> bool:
	for s in get_tree().get_nodes_in_group("war_structure") + get_tree().get_nodes_in_group("skiff") \
			+ get_tree().get_nodes_in_group("war_drop_pod"):
		if s == self or not (s is Node3D) or not is_instance_valid(s):
			continue
		var fr := float(s.get_meta("footprint_r", 3.0))
		if (s as Node3D).global_position.distance_to(p) < fr + AI_SPOT_CLEAR:
			return false
	return true


# --- Safety, inputs, jinking -----------------------------------------------------------------------

## Terrain / structures ahead: pull up for 0.8 s (climb, less speed, the nose up a little).
func _ai_avoid(delta: float) -> void:
	_ai_obst_t -= delta
	if _ai_obst_t <= 0.0:
		_ai_obst_t = 0.12
		if _ai_danger_ahead():
			_ai_pullup = 0.8
	_ai_pullup = maxf(_ai_pullup - delta, 0.0)
	if _ai_pullup <= 0.0 or _near < 0.05:
		return
	var vu := _ai_v_des.dot(_up)
	_ai_v_des = (_ai_v_des - _up * vu) * 0.4 + _up * maxf(vu, CLIMB)
	var nf := _ai_flat(_ai_nose_des if _ai_nose_des.length_squared() > 0.01 else -global_transform.basis.z)
	if nf.length_squared() > 1e-4:
		_ai_nose_des = nf.normalized() * cos(0.35) + _up * sin(0.35)


func _ai_danger_ahead() -> bool:
	var v := linear_velocity
	var sp := v.length()
	if sp < 3.0:
		return false
	var pos := global_position
	var on_final := _ai_phase == AiPhase.DESCEND and _ai_spot != Vector3.INF and _ai_flat(pos - _ai_spot).length() < 40.0
	if not on_final:
		var margin := AI_AVOID_CLEAR + sp * 0.12
		for k: float in [0.5, 1.0, 1.8, 2.8]:
			var p := pos + v * k
			var pb := Bodies.nearest(p)
			if pb != null and float(pb.call("density_fast", p)) < margin:
				return true
	else:
		v = _ai_flat(v)                    # gliding down on purpose: only what stands in the way
		if v.length() < 3.0:
			return false
	var o := pos + _up * 0.9
	var q := PhysicsRayQueryParameters3D.create(o, o + v * 2.0, Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE, [get_rid()])
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## The wanted velocity / nose as the player's controls: mouse aim (within the cone, like the mouse),
## W/S (forward speed), Q/E (sideways), Space/Ctrl (whatever the nose's tilt does not give), Shift.
func _ai_apply() -> void:
	var b := global_transform.basis.orthonormalized()
	var fwd := -b.z
	var right := b.x
	var upr := b.y
	if _near > 0.001:
		var bl := b.y.lerp(_up, _near)
		upr = bl.normalized() if bl.length_squared() > 0.01 else _up
	if _ai_nose_des.length_squared() > 0.01:
		_aim = _ai_nose_des.normalized()
		_clamp_aim()
	var cr := CRUISE * speed_k
	var v := _ai_v_des
	_in.z = clampf(v.dot(fwd) / cr, -1.0, 1.0)
	_in.x = clampf(v.dot(right) / STRAFE, -1.0, 1.0)
	_boost_in = _ai_boost and _in.z > 0.8
	var tf := 0.0
	if _in.z > 0.05 or _boost > 0.02:
		tf = lerpf(cr * maxf(_in.z, 0.0), BOOST_SPEED * speed_k, _boost)
	var du := v.dot(upr) - (fwd * tf + right * (_in.x * STRAFE)).dot(upr)
	_in.y = clampf(du / (CLIMB if du > 0.0 else SINK), -1.0, 1.0)
	_yaw_in = 0.0


## Under fire: a new random sideways / vertical push every 0.6-1.5 s (never down when low, none on
## short final), boosting while crossing: the flak's tracking has to start over each time.
func _ai_jink_apply(delta: float) -> void:
	if _jink_t <= 0.0:
		return
	_jink_t -= delta
	if _ai_phase == AiPhase.DESCEND and _ai_goto and _clear < 15.0:
		return
	_jink_next -= delta
	if _jink_next <= 0.0:
		_jink_next = _ai_rng.randf_range(0.6, 1.5)
		var sx := 1.0 if _ai_rng.randf() < 0.5 else -1.0
		_jink = Vector2(sx * _ai_rng.randf_range(0.5, 1.0), _ai_rng.randf_range(-0.8, 1.0))
	var jy := _jink.y if _clear > 12.0 else absf(_jink.y)
	_in.x = clampf(_in.x + _jink.x, -1.0, 1.0)
	_in.y = clampf(_in.y + jy * 0.8, -1.0, 1.0)
	if _ai_phase == AiPhase.CRUISE and _in.z > 0.3:
		_boost_in = true


## Variant hook (armed_skiff.gd): attack a target on the way, may replace _ai_v_des / _ai_nose_des
## and set _ai_engaged (no descent meanwhile).
func _ai_combat(_delta: float) -> void:
	pass
