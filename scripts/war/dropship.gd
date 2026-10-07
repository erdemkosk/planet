extends Node3D
## İniş Gemisi: the small dropship that brings the dead back down from their side's Taşıyıcı
## (scripts/war/carrier.gd) to the base. scripts/war/respawn_ship.gd dispatches it and runs the
## respawn; this node is the ship itself: model, flight, landing, ramp, sound, the passenger's view.
##   Model (scripts/war/respawn_ship_build.gd): a compact angular troop shuttle on two skids, a glazed
##     nose, a window strip on the left, a ramp-door on the right, two main engines, four lift / retro
##     jets; a furnished cabin (benches with harnesses, the jump seat the player rides in, cable trays,
##     recessed roof lamps, lockers, the console in the nose). Registration and stencils: Label3D.
##   Cabin light: the cabin mesh and the ramp are on Build.INTERIOR_LAYER. Only the cabin's own lights
##     (a warm one at the back, a cool one over the console, the jump light over the door: red in
##     flight, green with the ramp down) and the sun through the windows reach them; the exterior
##     lights (belly glow, landing light) and the carrier's bay light leave that layer out (no shadows:
##     they would shine through the hull). The cabin lights are on only while someone rides along or
##     the ramp is open.
##   Screens: one SubViewport (scripts/war/dropship_screens.gd: NAV, İRTİFA, İNİŞE on the console,
##     YENİDEN DOĞUŞ / KAPI on the wall ahead of the door) shown by four quads (uv1 offset / scale);
##     only on our own ride (kind "player"), rendered only while we sit in it (bot ships: dark bezels).
##   Timeline (t = s since dispatch): docked under the carrier's keel (clamp slot `slot`) until
##     t_release, then a cubic path to the landing point: a short fall away from the carrier, the main
##     engines light and it dives (nose down along its flight, a slow sway), from ~60 % the nose comes
##     level, it turns to its landing heading (the ramp side facing the other planet: door_dir()) and
##     brakes on its lift jets (retro-burn: flames, belly light, a ring of soft dust under it, landing
##     lights), touchdown at t_land (a thump, a burst of dust, sound, a camera shake nearby). The ramp
##     drops to the ground (its angle fits the ground under it), passengers step off at exit_xf(k);
##     once nobody is left (stay_until_ms) it closes, lifts off on its jets and flies back up into its
##     clamp, then frees.
##   Dust: small soft particles (soft-particle fade against the ground, faded out within ~1-4 m of the
##     camera so the walk-out never looks through a wall of it), the planet's soil colour washed
##     toward grey.
##   Passenger (the local player, seat_player): a first-person view from the jump seat (mouse looks
##     around within limits), shaking gently with the engines and hard at the release / ignition /
##     touchdown; stand_up() walks the view to the door and down the ramp to the player's eye at its
##     foot (respawn_ship.gd then hands the controls back there). The camera carries meta
##     "motion_blur_k" (scripts/ui/motion_blur.gd): damped in the seat, off on the walk-out. Inside, the
##     engines are a muffled rumble through the hull (2D players on the "VacHull" bus: low-pass) plus
##     the cabin's own air; the ship's outside sound is muted for its passenger.
##   Outside sound: AudioStreamPlayer3D on Master, routed by sfx.gd's medium rule; the engine loops
##     carry meta "snd_air_only" (heard only in the thin air near the surface, never as a ground thud).
##     Every stream is loaded once (warm(), respawn_ship.gd calls it at the start of the match): no disk
##     reads at the touchdown.
## Group "respawn_ship" (the Mekik's radar), nothing else: no collision, no damage.
## puppet (kind "replay"): a look-only copy of another machine's ship (multiplayer): it flies the same
## timeline and lands on its own, net_land(pos) moves it to the owner's touchdown; it emits nothing.

signal landed(ship: Node3D, pos: Vector3)

const Build := preload("res://scripts/war/respawn_ship_build.gd")
const Balance := preload("res://scripts/war/balance.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const Settings := preload("res://scripts/save/settings.gd")
const Screens := preload("res://scripts/war/dropship_screens.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const GROUP := "respawn_ship"
const RAMP_TIME := 0.55                # s for the ramp to drop / close
const DEPART_TIME := 7.0               # s from lift-off back into the clamps
const EYE_H := 1.72                    # player.gd EYE_H: the walk-out view ends at the player's eye
const PITCH_OUT := 0.12                # rad: the view looks a little up when you step off
const MOUSE_SENS := 0.0022
const BLUR_SEAT := 0.35                # motion_blur.gd: the smear in the seat (the cabin is near: stays sharp anyway)...
const DOOR_EYE := Vector3(1.05, 2.05, 0.15)   # ...the walk-out goes through here (in the doorway, facing out)
const EXTERIOR_MASK := 0xFFFFF & ~Build.INTERIOR_LAYER
## One-shot and loop streams by key (warm() loads them).
const STREAMS := {"metal": ["one", "impact/metal_heavy_01"], "thud": ["rand", "impact/thud"], "boost": ["one", "shuttle/boost"],
		"whoosh": ["one", "shuttle/boost_whoosh"], "gear": ["one", "shuttle/gear"], "shutdown": ["one", "shuttle/shutdown"],
		"startup": ["one", "shuttle/startup"], "ramp_open": ["one", "shuttle/ramp_open"], "ramp_close": ["one", "shuttle/ramp_close"],
		"decompress": ["one", "shuttle/decompress"], "step": ["rand", "foot/land_rock"], "belt": ["rand", "foley/belt"],
		"rumble": ["loop", "shuttle/rumble"], "vtol": ["loop", "shuttle/vtol"], "sub": ["loop", "shuttle/sub"],
		"bed": ["loop", "shuttle/cockpit_bed"], "hiss": ["loop", "shuttle/hiss_loop"]}

enum St { DOCKED, FLIGHT, LANDED, DEPART }

static var _streams := {}
static var _dust_tex: Texture2D = null
static var _dust_mat: StandardMaterial3D = null
static var _dust_pm := {}               # shared dust process materials / quads (_dust_process, _dust_quad)
static var _reg_n := 0

var id := 0
var team := "home"                     # livery / side: "home" Yurt, "rival" Rakip (the carrier's)
var kind := "bots"                     # "player" (our own ride), "bots", "replay", "warm" (built and freed at the start)
var puppet := false
var carrier = null                     # carrier.gd (untyped: may be freed)
var slot := 0
var body: Node3D = null                # the planet it lands on
var land_pos := Vector3.ZERO
var land_up := Vector3.UP
var land_basis := Basis()
var state := St.DOCKED
var t := 0.0
var t_release := 0.5
var t_land := 5.0
var land_ms := 0                       # Time.get_ticks_msec() of the touchdown (planned)
var stay_until_ms := 0                 # it stays on the ground (ramp down) at least until then
var bots := 0                          # bot passengers (slots handed out)
var bots_out := 0
var reg := "İG-01"                     # registration (hull lettering, the wall screen)

var _p: Array = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _prev := Vector3.ZERO
var _vel := Vector3.ZERO
var _q := Quaternion.IDENTITY
var _main := 0.0
var _lift := 0.0
var _main_t := 0.0
var _lift_t := 0.0
var _touch_t := -1.0
var _dep_t := -1.0
var _door := 0.0
var _ramp_open := deg_to_rad(122.0)
var _exits: Array = []
var _ignited := false
var _retro_on := false
var _lights_on := false

var _hull_mat: ShaderMaterial
var _emit_mat: ShaderMaterial
var _ramp: Node3D
var _flames_main: Array = []
var _flames_lift: Array = []
var _belly_light: OmniLight3D
var _land_spot: SpotLight3D
var _cab_warm: OmniLight3D
var _cab_cool: OmniLight3D
var _cab_jump: OmniLight3D
var _cab_on := false
var _lamp_red: StandardMaterial3D
var _lamp_green: StandardMaterial3D
var _halo: MeshInstance3D
var _dust: GPUParticles3D
var _burst: GPUParticles3D
var _vp: SubViewport = null
var _screens = null                    # dropship_screens.gd

var _ex_main: AudioStreamPlayer3D
var _ex_lift: AudioStreamPlayer3D
var _in := {}                          # cabin loops (2D): name -> AudioStreamPlayer

var _pass = null                       # the riding player (untyped: may be freed)
var _cam: Camera3D = null
var _look := Vector2.ZERO
var _kick := 0.0
var _shake_t := 0.0
var _stand_from := Transform3D()
var _stand_to := Transform3D()
var _stand_t := -1.0
var _stand_dur := 0.6


## Loads every stream the ships use (once per run).
static func warm() -> void:
	if not _streams.is_empty():
		return
	for key: String in STREAMS:
		var e: Array = STREAMS[key]
		match str(e[0]):
			"one":
				_streams[key] = Snd.one(str(e[1]))
			"rand":
				_streams[key] = Snd.rand(str(e[1]), 1.05, 1.0)
			_:
				_streams[key] = Snd.loop(str(e[1]))


static func _st(key: String) -> AudioStream:
	if _streams.is_empty():
		warm()
	var s = _streams.get(key)
	return s as AudioStream


## Before add_child: where it docks (`p_carrier`, clamp `p_slot`), where and when it lands.
func setup(p_id: int, p_team: String, p_carrier, p_slot: int, p_body: Node3D, p_land: Vector3, land_in: float,
		p_kind: String) -> void:
	id = p_id
	team = p_team
	carrier = p_carrier
	slot = p_slot
	body = p_body
	kind = p_kind
	puppet = p_kind == "replay"
	_set_land(p_land)
	t_land = maxf(land_in, 1.0)
	t_release = clampf(t_land * 0.11, 0.25, 0.55)
	land_ms = Time.get_ticks_msec() + int(t_land * 1000.0)
	stay_until_ms = land_ms + int((Balance.RESPAWN_DOOR + Balance.RESPAWN_GROUND) * 1000.0)
	_reg_n = _reg_n % 9 + 1
	reg = "%s-0%d" % ["İG" if team == "home" else "RG", _reg_n]


## The ramp side (+X of the landed ship): toward the other planet, along the ground at `p`. Both
## machines derive it from the landing point alone (multiplayer replays need no heading).
static func door_dir(p: Vector3) -> Vector3:
	var b: Node3D = Game.dominant_body(p)
	var up := Vector3.UP
	if b != null:
		up = (p - b.global_position).normalized()
	var other: Node3D = null
	for pl in Bodies.all():
		if is_instance_valid(pl) and pl != b:
			other = pl
	var to := Vector3.RIGHT
	if other != null:
		to = other.global_position - p
	to -= up * to.dot(up)
	if to.length_squared() < 1e-4:
		to = up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT)
	return to.normalized()


func _set_land(p: Vector3) -> void:
	land_pos = p
	if body == null or not is_instance_valid(body):
		body = Game.dominant_body(p)
	land_up = (p - body.global_position).normalized() if body != null else Vector3.UP
	var door := door_dir(p)
	land_basis = Basis(door, land_up, door.cross(land_up)).orthonormalized()


func _ready() -> void:
	if kind != "warm":                   # (respawn_ship.gd builds one "warm" ship at the start and frees it)
		add_to_group(GROUP)
	name = "Dropship_%s_%d" % [kind, id]
	warm()
	_build()
	_build_cabin()
	_build_fx()
	_build_audio()
	var xf := _dock_xf()
	global_transform = xf
	_q = xf.basis.get_rotation_quaternion()
	_prev = xf.origin


func is_landed() -> bool:
	return state == St.LANDED


func is_departing() -> bool:
	return state == St.DEPART


# =================================================================================================
# Model
# =================================================================================================

func _build() -> void:
	var m: Dictionary = Build.dropship(team)
	_hull_mat = Build.hull_material(false)
	_emit_mat = Build.emit_material()
	_mesh(m["hull"], _hull_mat, true)
	var cab := _mesh(m["cabin"], Build.hull_material(true), false)
	cab.layers = Build.INTERIOR_LAYER
	_mesh(m["glass"], Build.glass_material(), false)
	_mesh(m["emit"], _emit_mat, false)
	_ramp = Node3D.new()
	_ramp.position = Build.DS_HINGE
	add_child(_ramp)
	var rm := MeshInstance3D.new()
	rm.mesh = m["ramp"]
	rm.material_override = _hull_mat
	rm.layers = Build.INTERIOR_LAYER
	_ramp.add_child(rm)
	# The jump lights over the door inside: red in flight, green when the ramp is down.
	_lamp_red = _lamp(Vector3(1.42, 2.6, Build.DS_DOOR_Z0 - 0.22), Color(1.0, 0.15, 0.1))
	_lamp_green = _lamp(Vector3(1.42, 2.6, Build.DS_DOOR_Z1 + 0.22), Color(0.2, 1.0, 0.35))
	_set_lamps(false)
	# Lettering: the registration on both flanks, stencils inside.
	var lv: Dictionary = Build.LIVERY.get(team, Build.LIVERY["home"])
	var ink := Color(0.12, 0.12, 0.13) if team == "home" else Color(0.85, 0.85, 0.82)
	_label(self, reg, Vector3(-1.53, 1.55, 1.7), Vector3(0.0, -PI * 0.5, 0.0), 64, 0.006, ink, true)
	_label(self, reg, Vector3(1.53, 1.55, 1.85), Vector3(0.0, PI * 0.5, 0.0), 64, 0.006, ink, true)
	_label(self, str(lv["name"]), Vector3(-1.53, 2.25, 1.55), Vector3(0.0, -PI * 0.5, 0.0), 48, 0.005, (lv["stripe"] as Color), true)
	# Inside: on the ramp's inner face (it turns with it: a stencil on the ramp once it is down) and
	# on the oxygen rack.
	_label(_ramp, "RAMPA", Vector3(-0.012, 1.2, 0.0), Vector3(0.0, -PI * 0.5, 0.0), 32, 0.003, Build.C_YELLOW, false)
	_label(self, "O2", Vector3(0.41, 1.62, 2.26), Vector3(0.0, PI, 0.0), 40, 0.003, Color(0.9, 0.9, 0.85), false)


func _mesh(mesh: Mesh, mat: Material, shadow: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _label(parent: Node3D, text: String, pos: Vector3, rot: Vector3, size: int, px: float, col: Color, outside: bool) -> void:
	var l := Label3D.new()
	l.text = text
	l.font = UI.font(700)
	l.font_size = size
	l.outline_size = 0
	l.pixel_size = px
	l.modulate = col
	l.shaded = true
	l.double_sided = false
	l.position = pos
	l.rotation = rot
	l.visibility_range_end = 60.0 if outside else 14.0
	l.layers = 1 if outside else Build.INTERIOR_LAYER
	parent.add_child(l)


func _lamp(pos: Vector3, col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col * 0.3
	mat.emission_enabled = true
	mat.emission = col
	var bm := BoxMesh.new()
	bm.size = Vector3(0.05, 0.06, 0.1)
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	add_child(mi)
	return mat


func _set_lamps(open: bool) -> void:
	_lamp_red.emission_energy_multiplier = 0.15 if open else 3.0
	_lamp_green.emission_energy_multiplier = 3.0 if open else 0.15
	if _cab_jump != null:
		_cab_jump.light_color = Color(0.3, 1.0, 0.45) if open else Color(1.0, 0.2, 0.12)


## Cabin lights (INTERIOR_LAYER only) and, on our own ride, the screens.
func _build_cabin() -> void:
	var lv: Dictionary = Build.LIVERY.get(team, Build.LIVERY["home"])
	_cab_warm = _cab_light(Vector3(0.0, 2.85, 1.1), lv["lamp"], 5.0, 0.85)
	_cab_cool = _cab_light(Vector3(0.0, 2.05, -2.45), Color(0.45, 0.75, 1.0), 2.6, 0.55)
	_cab_jump = _cab_light(Vector3(0.95, 2.6, 0.15), Color(1.0, 0.2, 0.12), 1.5, 0.1)
	_set_cabin_lights(false)
	if kind != "player":
		return                             # (the screens: only our own ride has someone to read them)
	_vp = SubViewport.new()
	_vp.size = Screens.SIZE
	_vp.disable_3d = true
	_vp.transparent_bg = false
	_vp.gui_disable_input = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	_screens = Screens.new()
	_screens.ship = self
	_screens.set_process(false)
	_vp.add_child(_screens)
	var tex := _vp.get_texture()
	var cb := Build.console_basis()
	var r: Array = [Screens.PANELS["nav"], Screens.PANELS["alt"], Screens.PANELS["seq"]]
	for i in 3:
		# Quad in the console's tilted plane: its +Z face toward the cabin (up the slope's normal).
		var b := Basis(cb.x, -cb.z, cb.y)
		_screen_quad(tex, r[i], Transform3D(b, Build.console_screen_pos(i)), Build.DS_SCREEN_SIZE)
	var wb := Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(-1, 0, 0))
	_screen_quad(tex, Screens.PANELS["wall"], Transform3D(wb, Build.DS_WALL_SCREEN), Build.DS_WALL_SCREEN_SIZE)


func _cab_light(pos: Vector3, col: Color, rng: float, energy: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = col
	l.omni_range = rng
	l.omni_attenuation = 1.4
	l.light_energy = energy
	l.shadow_enabled = false
	l.light_specular = 0.35
	l.light_cull_mask = Build.INTERIOR_LAYER
	l.position = pos
	add_child(l)
	return l


func _set_cabin_lights(on: bool) -> void:
	_cab_on = on
	for l: OmniLight3D in [_cab_warm, _cab_cool, _cab_jump]:
		l.visible = on


func _screen_quad(tex: Texture2D, region: Rect2, xf: Transform3D, sz: Vector2) -> void:
	var q := QuadMesh.new()
	q.size = sz
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED       # a lit display: no light falls on it
	m.albedo_texture = tex
	m.albedo_color = Color(0.92, 0.95, 1.0)
	var full := Vector2(Screens.SIZE)
	m.uv1_scale = Vector3(region.size.x / full.x, region.size.y / full.y, 1.0)
	m.uv1_offset = Vector3(region.position.x / full.x, region.position.y / full.y, 0.0)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = Build.INTERIOR_LAYER
	mi.transform = xf
	add_child(mi)


## What the cabin screens show (dropship_screens.gd).
func screen_info() -> Dictionary:
	var pos := global_position
	var rel := land_pos - pos
	var b := global_transform.basis
	var local := b.inverse() * rel
	var hrel := rel - land_up * rel.dot(land_up)
	var phase := "KENETLİ"
	match state:
		St.FLIGHT:
			phase = "RETRO" if _retro_on else ("DALIŞ" if _ignited else "AYRILMA")
		St.LANDED:
			phase = "RAMPA AÇIK" if _door >= 1.0 else "İNDİ"
		St.DEPART:
			phase = "DÖNÜŞ"
	var span := maxf(t_land - t_release, 0.2)
	return {"alt": maxf((pos - land_pos).dot(land_up), 0.0), "vspeed": _vel.dot(land_up),
			"hspeed": (_vel - land_up * _vel.dot(land_up)).length(), "t_land": maxf(t_land - t, 0.0),
			"land_local": Vector2(local.x, local.z), "land_dist": hrel.length(), "landed": state == St.LANDED or state == St.DEPART,
			"released": state != St.DOCKED, "ignited": _ignited, "retro": _retro_on, "gear": _lights_on,
			"door_open": _door >= 1.0, "respawn_in": maxf(t_land + Balance.RESPAWN_DOOR - t, 0.0),
			"progress": clampf((t - t_release) / span, 0.0, 1.0) if state != St.DOCKED else 0.0, "phase": phase, "reg": reg}


func _screens_live(on: bool) -> void:
	if _vp == null:
		return
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	_screens.set_process(on)
	if on:
		_screens.queue_redraw()


## One fresh frame on the screens (an empty ship at the touchdown: seen through the open door).
func _screens_once() -> void:
	if _vp == null or _pass != null:
		return
	_screens.queue_redraw()
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _build_fx() -> void:
	var main_mat := _flame_mat(Color(1.3, 1.25, 1.9, 0.75))
	var lift_mat := _flame_mat(Color(2.1, 1.3, 0.6, 0.8))
	for p: Vector3 in Build.DS_MAIN:
		_flames_main.append(_flame(Vector3(p.x, p.y, p.z + 0.36), Basis(Vector3.RIGHT, PI * 0.5), 0.27, 2.4, main_mat))
	for p2: Vector3 in Build.DS_LIFT:
		_flames_lift.append(_flame(p2 + Vector3(0.0, -0.02, 0.0), Basis(Vector3.RIGHT, PI), 0.21, 1.7, lift_mat))
	_belly_light = OmniLight3D.new()
	_belly_light.light_color = Color(1.0, 0.6, 0.32)
	_belly_light.omni_range = 8.0
	_belly_light.light_energy = 0.0
	_belly_light.shadow_enabled = false
	_belly_light.light_cull_mask = EXTERIOR_MASK
	_belly_light.position = Vector3(0.0, -0.4, 0.2)
	_belly_light.visible = false
	add_child(_belly_light)
	_land_spot = SpotLight3D.new()
	_land_spot.light_color = Color(1.0, 0.95, 0.85)
	_land_spot.spot_range = 24.0
	_land_spot.spot_angle = 30.0
	_land_spot.light_energy = 4.0
	_land_spot.shadow_enabled = false
	_land_spot.light_cull_mask = EXTERIOR_MASK
	_land_spot.position = Build.DS_LAND_LIGHT
	_land_spot.rotation = Vector3(-1.15, 0.0, 0.0)
	_land_spot.visible = false
	add_child(_land_spot)
	# A glow that reads from the base while it comes down from the carrier.
	_halo = MeshInstance3D.new()
	_halo.mesh = DebrisMesh.quad_mesh()
	_halo.material_override = DebrisMesh.halo_material(Color(1.0, 0.7, 0.45, 1.0), 2.2, 0.004)
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.custom_aabb = AABB(Vector3.ONE * -10.0, Vector3.ONE * 20.0)
	_halo.position = Vector3(0.0, 1.2, 2.0)
	_halo.visible = false
	add_child(_halo)
	_dust = _make_dust(false)
	add_child(_dust)
	_burst = _make_dust(true)
	add_child(_burst)


static func _flame_mat(col: Color) -> StandardMaterial3D:
	var key := "f|" + col.to_html()
	if _dust_pm.has(key):
		return _dust_pm[key]
	var f := StandardMaterial3D.new()
	f.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	f.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	f.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	f.albedo_color = col
	f.cull_mode = BaseMaterial3D.CULL_DISABLED
	_dust_pm[key] = f
	return f


## A cone of flame under a pivot at the nozzle exit (pivot +Y = the flame's direction; scale.y = length).
func _flame(at: Vector3, b: Basis, r: float, length: float, mat: Material) -> Node3D:
	var pivot := Node3D.new()
	pivot.transform = Transform3D(b, at)
	add_child(pivot)
	var c := CylinderMesh.new()
	c.top_radius = 0.015
	c.bottom_radius = r
	c.height = length
	c.radial_segments = 10
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(0.0, length * 0.5, 0.0)
	pivot.add_child(mi)
	pivot.visible = false
	return pivot


## A soft puff (smooth radial falloff, no hard rim) shared by every ship's dust.
static func _puff_texture() -> Texture2D:
	if _dust_tex != null:
		return _dust_tex
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.72), Color(1, 1, 1, 0.36), Color(1, 1, 1, 0.1), Color(1, 1, 1, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	_dust_tex = tex
	return tex


## The dust material: soft particles (fade where they meet the ground) and gone near the camera.
static func _dust_material() -> StandardMaterial3D:
	if _dust_mat != null:
		return _dust_mat
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = _puff_texture()
	m.proximity_fade_enabled = true
	m.proximity_fade_distance = 0.9
	m.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	m.distance_fade_min_distance = 1.2
	m.distance_fade_max_distance = 4.5
	m.disable_receive_shadows = true
	_dust_mat = m
	return m


## The ring of dust the lift jets blow off the ground (burst: the one-shot touchdown puff), world
## space, oriented on the landing spot (_dust_set / _touchdown).
func _make_dust(burst: bool) -> GPUParticles3D:
	var d := GPUParticles3D.new()
	d.top_level = true
	d.amount = 110 if burst else 150
	d.lifetime = 1.7 if burst else 1.3
	d.one_shot = burst
	d.explosiveness = 0.85 if burst else 0.0
	d.local_coords = false
	d.emitting = false
	d.visibility_aabb = AABB(Vector3(-14, -4, -14), Vector3(28, 10, 28))
	d.draw_order = GPUParticles3D.DRAW_ORDER_INDEX
	d.process_material = _dust_process(burst, _dust_color())
	d.draw_pass_1 = _dust_quad(burst)
	d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return d


## The dust's process material, shared by every ship of a planet (building one is the costly part of
## a new ship): blown out along the ground by the jets, damped to a stop, no gravity (they settle in
## place while they fade, whichever way "down" is on the little planet).
static func _dust_process(burst: bool, col: Color) -> ParticleProcessMaterial:
	var key := "%s|%s" % [str(burst), col.to_html()]
	if _dust_pm.has(key):
		return _dust_pm[key]
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0, 1, 0)
	pm.emission_ring_radius = 2.4 if burst else 1.9
	pm.emission_ring_inner_radius = 0.6
	pm.emission_ring_height = 0.15
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = 0.3
	pm.initial_velocity_max = 1.2 if burst else 0.8
	pm.radial_velocity_min = 5.0 if burst else 4.0
	pm.radial_velocity_max = 11.0 if burst else 8.0
	pm.damping_min = 3.5
	pm.damping_max = 5.0
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.7
	pm.scale_max = 1.7
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.35))
	sc.add_point(Vector2(1, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.12, 0.55, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.3 if burst else 0.22), Color(1, 1, 1, 0.14), Color(1, 1, 1, 0.0)])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = col
	_dust_pm[key] = pm
	return pm


static func _dust_quad(burst: bool) -> QuadMesh:
	var key := "q|%s" % str(burst)
	if _dust_pm.has(key):
		return _dust_pm[key]
	var q := QuadMesh.new()
	q.size = Vector2(0.75, 0.75) if burst else Vector2(0.6, 0.6)
	q.material = _dust_material()
	_dust_pm[key] = q
	return q



## Dust: the soil colour washed toward a dusty grey (bright orange soil made orange polka dots).
func _dust_color() -> Color:
	var soil := Color(0.62, 0.55, 0.46)
	if body != null and is_instance_valid(body) and body.get("soil_color") is Color:
		soil = body.get("soil_color") as Color
	return soil.lerp(Color(0.66, 0.63, 0.58), 0.55)


func _ground_xf() -> Transform3D:
	var up := land_up
	var ref := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(up).normalized()
	return Transform3D(Basis(x, up, x.cross(up)), land_pos + up * 0.12)


func _dust_set(on: bool, k: float) -> void:
	if _dust.emitting != on:
		_dust.emitting = on
		if on:
			_dust.global_transform = _ground_xf()
	if on:
		_dust.amount_ratio = clampf(k, 0.15, 1.0) * (0.6 if _pass != null else 1.0)


func _build_audio() -> void:
	_ex_main = _loop3d("rumble", Vector3(0.0, 1.9, 3.4), 14.0)
	_ex_lift = _loop3d("vtol", Vector3(0.0, 0.5, 0.2), 12.0)


func _loop3d(key: String, at: Vector3, unit: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = _st(key)
	p.unit_size = unit
	p.max_distance = 450.0
	p.volume_db = -60.0
	p.set_meta("snd_air_only", true)
	p.position = at
	add_child(p)
	return p


func _drive_loop3d(p: AudioStreamPlayer3D, k: float, top_db: float, pitch: float) -> void:
	if p.stream == null:
		return
	if k < 0.01:
		if p.playing:
			p.stop()
		return
	if not p.playing:
		p.play()
	p.volume_db = top_db + linear_to_db(k)
	p.pitch_scale = pitch


static func _hull_bus() -> String:
	return "VacHull" if AudioServer.get_bus_index("VacHull") >= 0 else "Master"


## A one-shot: for our own passenger a 2D sound through the hull (muffled unless `open`: the ramp is
## down, the air comes in), else a 3D sound at the ship (sfx.gd routes it by the medium).
func _shot(key: String, db: float, pitch: float, at: Vector3, unit: float, open := false) -> void:
	var stream := _st(key)
	if stream == null:
		return
	if _pass != null:
		var a := AudioStreamPlayer.new()
		a.stream = stream
		a.volume_db = db - (0.0 if open else 1.5)
		a.pitch_scale = pitch
		a.bus = "Master" if open else _hull_bus()
		add_child(a)
		a.play()
		a.finished.connect(a.queue_free)
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.unit_size = unit
	p.max_distance = maxf(unit * 25.0, 200.0)
	p.volume_db = db
	p.pitch_scale = pitch
	p.position = at
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)


# =================================================================================================
# Timeline
# =================================================================================================

func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	t += delta
	match state:
		St.DOCKED:
			_tick_docked()
		St.FLIGHT:
			_tick_flight(delta)
		St.LANDED:
			_tick_landed(delta)
		St.DEPART:
			_tick_depart(delta)
	_tick_engines(delta)
	_tick_cabin(delta)
	var want_cab := _pass != null or (state == St.LANDED and _door > 0.0)
	if want_cab != _cab_on:
		_set_cabin_lights(want_cab)


## The clamp it hangs in (or, with no carrier, a point high above the landing spot).
func _dock_xf() -> Transform3D:
	if carrier != null and is_instance_valid(carrier) and carrier.has_method("hangar_xf"):
		return carrier.hangar_xf(slot)
	return Transform3D(land_basis, land_pos + land_up * (Balance.CARRIER_ALT + 8.0))


func _bez(s: float) -> Vector3:
	var u := 1.0 - s
	var p0: Vector3 = _p[0]
	var p1: Vector3 = _p[1]
	var p2: Vector3 = _p[2]
	var p3: Vector3 = _p[3]
	return p0 * (u * u * u) + p1 * (3.0 * u * u * s) + p2 * (3.0 * u * s * s) + p3 * (s * s * s)


func _tick_docked() -> void:
	var xf := _dock_xf()
	global_transform = xf
	_q = xf.basis.get_rotation_quaternion()
	_prev = xf.origin
	if t >= t_release:
		_release()


## The clamps let go: fall away from the carrier, then the path down to the landing point.
func _release() -> void:
	state = St.FLIGHT
	var p0 := global_position
	var cu := global_transform.basis.y
	var to := land_pos - p0
	var tan := to - cu * to.dot(cu)
	var lead := Vector3.ZERO
	if tan.length() > 0.1:
		lead = tan.normalized() * minf(tan.length() * 0.25, 14.0)
	_p = [p0, p0 - cu * 32.0 + lead, land_pos + land_up * 38.0, land_pos]
	_kick = maxf(_kick, 0.55)
	_shot("metal", -8.0, 1.2, Vector3(0.0, 3.0, 0.0), 10.0)


func _tick_flight(delta: float) -> void:
	var span := maxf(t_land - t_release, 0.2)
	var u := clampf((t - t_release) / span, 0.0, 1.0)
	var s := u * u * (3.0 - 2.0 * u)
	var pos := _bez(s)
	_vel = _vel.lerp((pos - _prev) / delta, 1.0 - exp(-12.0 * delta))
	_prev = pos
	_main_t = 1.0 if u > 0.06 and u < 0.58 else 0.0
	_lift_t = 1.0 if u >= 0.58 else (0.35 if u > 0.45 else 0.0)
	if u > 0.06 and not _ignited:
		_ignited = true
		_kick = maxf(_kick, 0.6)
		_shot("boost", -3.0, 0.9, Vector3(0.0, 1.9, 3.4), 22.0)
	if u >= 0.58 and not _retro_on:
		_retro_on = true
		_kick = maxf(_kick, 0.5)
		_shot("whoosh", -5.0, 0.8, Vector3(0.0, 0.5, 0.0), 18.0)
	if u >= 0.9 and _exits.is_empty() and not puppet:
		_compute_ground()                 # the ramp angle and the exits, a few frames before the touchdown
	if u >= 0.68 and not _lights_on:
		_lights_on = true
		_land_spot.visible = true
		_shot("gear", -8.0, 1.0, Vector3(0.0, 0.5, 0.0), 8.0)
	_orient(pos, u, delta)
	if u >= 1.0:
		_touchdown()
		return
	global_transform = Transform3D(Basis(_q), pos)
	var alt := (pos - land_pos).dot(land_up)
	_dust_set(alt < 14.0 and _lift > 0.2, 1.0 - alt / 14.0)


## Nose along the flight (pitched down in the dive, at most ~43°), level and turned to the landing
## heading over the last part; a slow sway in flight.
func _orient(pos: Vector3, u: float, delta: float) -> void:
	var c: Vector3 = body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO
	var up_r := (pos - c).normalized()
	var hv := _vel - up_r * _vel.dot(up_r)
	var vr := _vel.dot(up_r)
	var land_fwd := -land_basis.z
	var lf := land_fwd - up_r * land_fwd.dot(up_r)
	lf = lf.normalized() if lf.length_squared() > 1e-6 else land_fwd
	var heading := hv.normalized() if hv.length() > 2.5 else lf
	var k_lvl := smoothstep(0.5, 0.86, u)
	heading = heading.lerp(lf, k_lvl)
	heading -= up_r * heading.dot(up_r)
	heading = heading.normalized() if heading.length_squared() > 1e-6 else lf
	var pitch := clampf(atan2(vr, maxf(hv.length(), 0.5)), -0.75, 0.3) * (1.0 - k_lvl)
	var fwd := (heading * cos(pitch) + up_r * sin(pitch)).normalized()
	var tb := Basis.looking_at(fwd, up_r)
	var sway := (sin(t * 1.3) * 0.05 + sin(t * 3.1) * 0.015) * (1.0 - k_lvl * 0.9)
	tb = Basis(fwd, sway) * tb
	_q = _q.slerp(tb.get_rotation_quaternion(), 1.0 - exp(-(3.0 + 6.0 * k_lvl) * delta))


func _touchdown() -> void:
	state = St.LANDED
	_touch_t = t
	global_transform = Transform3D(land_basis, land_pos)
	_q = land_basis.get_rotation_quaternion()
	_vel = Vector3.ZERO
	_main_t = 0.0
	_lift_t = 0.0
	_kick = 1.0
	if _exits.is_empty():
		_compute_ground()                 # (normally done on the final approach: _tick_flight)
	_dust.emitting = false
	_burst.global_transform = _ground_xf()
	_burst.amount_ratio = 0.6 if _pass != null else 1.0
	_burst.restart()
	_burst.emitting = true
	_shot("thud", 3.0, 0.72, Vector3.ZERO, 18.0)
	_shot("metal", -3.0, 0.7, Vector3(0.0, 1.0, 0.0), 14.0)
	_shot("shutdown", -9.0, 1.0, Vector3(0.0, 1.5, 2.5), 12.0)
	_screens_once()
	var pl = Game.player
	if _pass == null and pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var dpl: float = (pl as Node3D).global_position.distance_to(land_pos)
		if dpl < 30.0:
			pl.add_trauma(0.35 * (1.0 - dpl / 30.0))
	if not puppet:
		landed.emit(self, land_pos)


## Where the ground is under the ramp's foot and the exits (the ramp's open angle fits it).
func _compute_ground() -> void:
	_exits.clear()
	var xf := Transform3D(land_basis, land_pos)
	var c: Vector3 = body.global_position if body != null and is_instance_valid(body) else land_pos - land_up * 30.0
	var out := land_basis.x
	for k in Build.DS_EXIT_SPREAD.size():
		var p := _ground_at(xf * (Build.DS_EXIT + Vector3(0.0, 0.0, float(Build.DS_EXIT_SPREAD[k]))))
		var up := (p - c).normalized()
		var z := -(out - up * out.dot(up)).normalized()
		_exits.append(Transform3D(Basis(up.cross(z).normalized(), up, z), p + up * 0.05))
	var hinge := xf * Build.DS_HINGE
	var foot := _ground_at(xf * Vector3(Build.DS_HINGE.x + 1.55, 0.0, Build.DS_HINGE.z))
	var drop := (hinge - foot).dot(land_up)
	_ramp_open = PI * 0.5 + asin(clampf(drop / Build.DS_DOOR_H, 0.05, 0.95))


func _ground_at(p: Vector3) -> Vector3:
	if body == null or not is_instance_valid(body) or not body.has_method("raycast_density"):
		return p
	var up := (p - body.global_position).normalized()
	var h: Dictionary = body.raycast_density(p + up * 3.0, p - up * 5.0, 0.5, false)
	if h.is_empty():
		return p
	var q: Vector3 = h["position"]
	return q


func _tick_landed(delta: float) -> void:
	var now := Time.get_ticks_msec()
	var since := t - _touch_t
	var want_open := since > 0.06 and (now < stay_until_ms or _pass != null)
	var was := _door
	_door = move_toward(_door, 1.0 if want_open else 0.0, delta / RAMP_TIME)
	if was <= 0.0 and _door > 0.0:
		_set_lamps(true)
		_shot("ramp_open", -3.0, 1.0, Build.DS_HINGE, 10.0, true)
		_shot("decompress", -2.0, 1.05, Build.DS_HINGE + Vector3(0.0, 1.0, 0.0), 10.0, true)
		if _pass != null and Game.sfx:
			Game.sfx.play("ding", -12.0, 1.35)
	elif was >= 1.0 and _door < 1.0:
		_set_lamps(false)
		_shot("ramp_close", -4.0, 1.0, Build.DS_HINGE, 10.0)
	elif was < 1.0 and _door >= 1.0:
		_shot("metal", -10.0, 1.3, Build.DS_HINGE + Vector3(1.5, -0.9, 0.0), 8.0, true)
		_screens_once()
	var e := _door * _door * (3.0 - 2.0 * _door)
	_ramp.rotation = Vector3(0.0, 0.0, -_ramp_open * e)
	if since > 1.5 and _land_spot.visible:
		_land_spot.visible = false
	if not want_open and _door <= 0.0 and now >= stay_until_ms and _pass == null:
		_begin_depart()


func _begin_depart() -> void:
	state = St.DEPART
	_dep_t = t
	_land_spot.visible = false
	_set_lamps(false)
	_shot("startup", -4.0, 1.0, Vector3(0.0, 1.5, 2.5), 16.0)
	_p = [land_pos, land_pos + land_up * 26.0, land_pos + land_up * 60.0, land_pos + land_up * 90.0]
	_prev = land_pos


## Lift-off on the jets, then up and back into its clamp under the carrier (which keeps moving: the
## end of the path follows it); freed when docked.
func _tick_depart(delta: float) -> void:
	var u := clampf((t - _dep_t) / DEPART_TIME, 0.0, 1.0)
	var end := _dock_xf()
	var cu := end.basis.y
	_p[2] = end.origin - cu * 30.0
	_p[3] = end.origin
	var s := u * u * u * (u * (6.0 * u - 15.0) + 10.0)
	var pos := _bez(s)
	_vel = _vel.lerp((pos - _prev) / delta, 1.0 - exp(-10.0 * delta))
	_prev = pos
	_lift_t = 1.0 if u < 0.35 else 0.25
	_main_t = 1.0 if u >= 0.22 and u < 0.85 else 0.0
	var c: Vector3 = body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO
	var up_r := (pos - c).normalized()
	var hv := _vel - up_r * _vel.dot(up_r)
	var cur_fwd := -Basis(_q).z
	var heading := hv.normalized() if hv.length() > 3.0 else (cur_fwd - up_r * cur_fwd.dot(up_r)).normalized()
	var pitch := clampf(atan2(_vel.dot(up_r), maxf(hv.length(), 0.5)), -0.3, 0.5) * smoothstep(0.15, 0.4, u)
	var fwd := (heading * cos(pitch) + up_r * sin(pitch)).normalized()
	var tb := Basis.looking_at(fwd, up_r)
	var k_dock := smoothstep(0.8, 0.97, u)
	var tq := tb.get_rotation_quaternion().slerp(end.basis.get_rotation_quaternion(), k_dock)
	_q = _q.slerp(tq, 1.0 - exp(-4.0 * delta))
	global_transform = Transform3D(Basis(_q), pos)
	var alt := (pos - land_pos).dot(land_up)
	_dust_set(alt < 12.0 and u < 0.4, 1.0 - alt / 12.0)
	if u >= 1.0:
		queue_free()


func _tick_engines(delta: float) -> void:
	_main = move_toward(_main, _main_t, delta * 2.5)
	_lift = move_toward(_lift, _lift_t, delta * (3.0 if _lift_t > _lift else 1.2))
	var fl := 0.85 + 0.3 * randf()
	for f in _flames_main:
		var n := f as Node3D
		n.visible = _main > 0.03
		if n.visible:
			n.scale = Vector3(0.8 + 0.2 * _main, maxf(_main * fl, 0.05), 0.8 + 0.2 * _main)
	for f2 in _flames_lift:
		var n2 := f2 as Node3D
		n2.visible = _lift > 0.03
		if n2.visible:
			n2.scale = Vector3(0.8 + 0.2 * _lift, maxf(_lift * (0.8 + 0.4 * randf()), 0.05), 0.8 + 0.2 * _lift)
	_emit_mat.set_shader_parameter("engine", _main)
	_emit_mat.set_shader_parameter("vtol", _lift)
	_belly_light.visible = _lift > 0.05
	if _belly_light.visible:
		_belly_light.light_energy = _lift * 3.0 * fl
	_halo.visible = (_main > 0.1 or _lift > 0.1) and _pass == null
	var ext := 0.0 if _pass != null else 1.0
	_drive_loop3d(_ex_main, _main * ext, -2.0, 0.95 + 0.1 * _main)
	_drive_loop3d(_ex_lift, _lift * ext, -1.0, 1.0)


# =================================================================================================
# Passengers
# =================================================================================================

## A bot comes down in this ship: its exit slot.
func add_bot() -> int:
	var k := bots
	bots += 1
	return k


func extend_stay(until_ms: int) -> void:
	stay_until_ms = maxi(stay_until_ms, until_ms)


## Bot slot k may step off (the ramp is down; one after another).
func bot_ready(k: int) -> bool:
	return state == St.LANDED and _touch_t >= 0.0 and t - _touch_t >= Balance.RESPAWN_DOOR + float(k) * Balance.RESPAWN_STAGGER


## Bot slot k stepped off: a clank on the ramp, the ship waits a little longer for the rest.
func bot_out(_k: int) -> void:
	bots_out += 1
	extend_stay(Time.get_ticks_msec() + int(Balance.RESPAWN_GROUND * 1000.0))
	_shot("step", -6.0, 1.0, Build.DS_EXIT, 8.0, true)


## Where passenger k stands after stepping off (feet on the ground past the ramp, facing out).
func exit_xf(k: int) -> Transform3D:
	if _exits.is_empty():
		_compute_ground()
	return _exits[clampi(k, 0, _exits.size() - 1)]


## The player's eye at exit 0 (the end of the walk-out view; player.gd EYE_H, pitched PITCH_OUT).
func exit_eye_xf() -> Transform3D:
	var x := exit_xf(0)
	return Transform3D(x.basis * Basis(Vector3.RIGHT, PITCH_OUT), x.origin + x.basis.y * EYE_H)


## The local player rides along: the view from the jump seat, the cabin's sound, light and screens.
func seat_player(pl) -> void:
	_pass = pl
	if _cam == null:
		_cam = Camera3D.new()
		_cam.near = 0.04
		_cam.far = Game.CAM_FAR
		add_child(_cam)
	_cam.fov = Settings.fov
	_cam.set_meta("motion_blur_k", BLUR_SEAT)
	_look = Vector2.ZERO
	_stand_t = -1.0
	_tick_cabin(0.0)
	_cam.current = true
	_set_cabin_lights(true)
	_screens_live(true)
	_cabin_audio(true)


## The view gets up, steps to the doorway and walks down the ramp to the player's eye at its foot.
func stand_up(dur: float) -> void:
	if _cam == null:
		return
	_stand_from = _cam.global_transform
	_stand_to = exit_eye_xf()
	_stand_t = 0.0
	_stand_dur = maxf(dur, 0.05)
	_cam.set_meta("motion_blur_k", 0.0)
	_shot("belt", -10.0, 1.0, Vector3.ZERO, 4.0, true)


## The player has control again (respawn_ship.gd moved the body to the ramp's foot).
func release_player() -> void:
	_pass = null
	if _cam != null:
		_cam.current = false
	_cabin_audio(false)
	_screens_live(false)
	extend_stay(Time.get_ticks_msec() + int(Balance.RESPAWN_GROUND * 1000.0))


func has_passenger() -> bool:
	return _pass != null


func _input(event: InputEvent) -> void:
	if _pass == null or _cam == null or _stand_t >= 0.0:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not Game.ui_panel_open():
		var lk: Vector2 = Settings.look((event as InputEventMouseMotion).relative)
		_look.x = clampf(_look.x - lk.x * MOUSE_SENS, -1.9, 1.9)
		_look.y = clampf(_look.y - lk.y * MOUSE_SENS, -1.0, 0.95)


## The walk-out: up from the seat to the doorway (turning to face out), then down the ramp.
func _walk_xf(k: float) -> Transform3D:
	var door := Transform3D(Basis(Vector3.UP, -PI * 0.5) * Basis(Vector3.RIGHT, 0.08), DOOR_EYE)
	var door_g := global_transform * door
	var split := 0.45
	if k < split:
		var e := _smooth(k / split)
		var xf := _stand_from.interpolate_with(door_g, e)
		xf.origin += door_g.basis.y * sin(e * PI) * 0.08
		return xf
	var e2 := _smooth((k - split) / (1.0 - split))
	var xf2 := door_g.interpolate_with(_stand_to, e2)
	xf2.origin += _stand_to.basis.y * sin(e2 * PI * 2.0) * 0.025      # two steps down the ramp
	return xf2


static func _smooth(v: float) -> float:
	var k := clampf(v, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


func _tick_cabin(delta: float) -> void:
	if _pass == null or _cam == null:
		return
	_kick = maxf(_kick - delta * 1.6, 0.0)
	_shake_t += delta
	_drive_cabin_audio()
	if _stand_t >= 0.0:
		_stand_t += delta
		_cam.global_transform = _walk_xf(clampf(_stand_t / _stand_dur, 0.0, 1.0))
		return
	var amp := 0.0008 + 0.0035 * _main + 0.005 * _lift + 0.035 * _kick * _kick
	var st := _shake_t
	var sh := Vector3(sin(st * 37.0) + sin(st * 17.3) * 0.6, sin(st * 29.0 + 1.1) + sin(st * 11.0) * 0.5,
			sin(st * 23.0 + 0.4) * 0.6) * amp
	var seat := global_transform * Transform3D(Basis(), Build.DS_SEAT_EYE)
	var look := Basis(Vector3.UP, _look.x) * Basis(Vector3.RIGHT, _look.y)
	_cam.global_transform = Transform3D(seat.basis * look * Basis.from_euler(sh), seat.origin + seat.basis * Vector3(sh.y, sh.x, 0.0) * 0.5)


func _cabin_audio(on: bool) -> void:
	if on and _in.is_empty():
		var hb := _hull_bus()
		_in["bed"] = _loop2d("bed", "Master")
		_in["hiss"] = _loop2d("hiss", "Master")
		_in["rumble"] = _loop2d("rumble", hb)
		_in["sub"] = _loop2d("sub", hb)
		_in["vtol"] = _loop2d("vtol", hb)
	for p in _in.values():
		var a := p as AudioStreamPlayer
		if a.stream == null:
			continue
		if on and not a.playing:
			a.play()
		elif not on and a.playing:
			a.stop()


func _loop2d(key: String, bus: String) -> AudioStreamPlayer:
	var a := AudioStreamPlayer.new()
	a.stream = _st(key)
	a.bus = bus
	a.volume_db = -60.0
	add_child(a)
	return a


func _drive_cabin_audio() -> void:
	if _in.is_empty():
		return
	var power := maxf(_main, _lift * 0.8)
	(_in["bed"] as AudioStreamPlayer).volume_db = -17.0
	(_in["hiss"] as AudioStreamPlayer).volume_db = -27.0
	var r := _in["rumble"] as AudioStreamPlayer
	r.volume_db = lerpf(-34.0, -5.0, power)
	r.pitch_scale = 0.9 + 0.15 * _main
	(_in["sub"] as AudioStreamPlayer).volume_db = lerpf(-30.0, -6.0, power)
	(_in["vtol"] as AudioStreamPlayer).volume_db = lerpf(-42.0, -6.0, _lift)


# =================================================================================================
# Multiplayer replay
# =================================================================================================

## Puppet: the owner's touchdown at `pos` (lands there now if it is still in the air).
func net_land(pos: Vector3) -> void:
	if state == St.DEPART:
		return
	if state == St.LANDED:
		if pos.distance_to(land_pos) > 0.5:
			_set_land(pos)
			global_transform = Transform3D(land_basis, land_pos)
			_compute_ground()
		return
	_set_land(pos)
	_touchdown()
