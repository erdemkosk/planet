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
##   the paint stays). A skiff with a bot aboard cannot be boarded.
## NOT IMPLEMENTED YET (paused 2026-10-05 on the user's request): the team livery and everything
## below are a plan only. `team` exists but changes nothing; none of the ai_* functions exist.
## AI pilot (the bots, scripts/war/**). It flies with exactly the player's flight model: it only
## sets the same inputs (aim, thrust, strafe, up / down, boost) that the keyboard and mouse set.
##   ai_board(bot) -> bool    landed, no pilot, same team (if the bot has `team`): the bot takes the
##                            seat. It is hidden (a seated astronaut shows through the canopy), taken
##                            out of "damageable" (the hull shields it) and its collision shapes
##                            are disabled; the skiff carries it along (global_transform).
##   ai_exit() -> Transform3D landed only: the bot steps out beside the ship (visible, damageable,
##                            collisions back), returns where it stands. Not landed / no bot:
##                            Transform3D() (origin ZERO) and nothing changes.
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
const AI_APPROACH := 90.0          # horizontal distance where the approach (and the spot search) starts
const AI_KEEP_OUT := 30.0          # planets: stay this far above the base radius en route
const AI_JINK_TIME := 4.0
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
var _bot: Node3D = null
var _bot_dmg := false              # it was in "damageable" before boarding
var _bot_shapes: Array = []        # its collision shapes we disabled
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
	_overlay_layer.layer = 4
	_overlay_layer.visible = false
	add_child(_overlay_layer)
	var ov: Control = Overlay.new()
	ov.ship = self
	_overlay_layer.add_child(ov)
	for b in Bodies.all():
		if is_instance_valid(b) and b.has_signal("brush_applied"):
			b.brush_applied.connect(_on_brush)
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
	var ms := Build.meshes()
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
	Build.add_decals(_visual)


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
	if destroyed or _dying or pilot != null or p == null:
		return
	if p.has_method("enter_vehicle"):
		p.enter_vehicle(self)


func get_interact_prompt() -> String:
	if destroyed or _dying or pilot != null:
		return ""
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
	return Vector3.ZERO if landed else linear_velocity


func hud_velocity() -> Vector3:
	return Vector3.ZERO if freeze else linear_velocity


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
	return landed or Input.is_action_pressed("tool_alt")


func _unhandled_input(event: InputEvent) -> void:
	if pilot == null or destroyed or Game.ui_panel_open():
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


func _read_input(delta: float) -> void:
	_in = Vector3.ZERO
	_yaw_in = 0.0
	_boost_in = false
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
	_read_input(delta)
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
	_near = 1.0 - smoothstep(0.5 * r, 1.35 * r, _alt)


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
	var wants := pilot != null and (_in.y > 0.1 or _in.z > 0.1)
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
	var up_in := pilot != null and _in.y > 0.05
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
	if destroyed or not landed:
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
	_ang_acc = (_ang_acc + jerk * dt).clamp(-ANG_ACC, ANG_ACC)
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
	var piloted := pilot != null
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
		tf = lerpf(CRUISE * maxf(in_f, 0.0), BOOST_SPEED, _boost)
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
	if pilot == null:
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
		if pilot != null:
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
	l = l.clamp(-RATE, RATE)
	return b * l


# ==================================================================================================
# Damage
# ==================================================================================================

func is_dead() -> bool:
	return destroyed or _dying


func take_damage(amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO) -> Dictionary:
	if destroyed or _dying or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	hp = maxf(hp - amount, 0.0)
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
	var soil := Color(0.42, 0.36, 0.27)
	if _body != null and _body.get("soil_color") is Color:
		soil = _body.get("soil_color")
	Explosion.spawn(center, up, {"radius": 6.0, "damage": 28.0, "impulse": 9.0, "crater": 2.0,
			"player_owned": false, "ground": soil})
	var ms := Build.meshes()
	Wreck.spawn(get_parent(), xf, vel, [ms["hull"], ms["cabin"]], Build.hull_material(false))
	if Game.hud:
		Game.hud.show_message("Mekik yok edildi!", 2.5)
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
	var on := pilot != null or not landed
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
		elif pilot == null:
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
		return "BOŞLUK / W kalk  ·  fare etrafa bak  ·  V kamera  ·  L ışıklar  ·  F in"
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
