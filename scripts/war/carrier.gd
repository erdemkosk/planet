extends Node3D
## Taşıyıcı: a side's mother ship, parked high above its own planet (Balance.CARRIER_ALT above the
## base radius, far beyond the jetpack's reach) where the respawn dropships (scripts/war/dropship.gd)
## come from. ~60 m of hull (scripts/war/respawn_ship_build.gd): the Yurt one white with orange
## stripes and warm lit windows, the Rakip one dark gunmetal with red stripes and red lights; blinking
## beacons that read from the other planet, three engines idling with a soft glow, a lit docking bay
## under the keel (CV_SLOTS clamp pairs, hangar_xf(slot)).
## Decorative only: no collision, no damage, no gameplay group but "war_carrier" (the Mekik's radar).
## Motion: a slow loop in the sky above its base: the direction from the planet centre turns about a
## point tilted away from the other planet (so it stays out of the shells' corridor between the
## planets), Balance.CARRIER_LOOP rad off it, once per Balance.CARRIER_PERIOD s, nose along the loop,
## banked a little into it. The phase comes from the wall clock (Time.get_unix_time_from_system), so
## two machines in a multiplayer match show it in about the same place without any traffic.

const Build := preload("res://scripts/war/respawn_ship_build.gd")
const Balance := preload("res://scripts/war/balance.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const GROUP := "war_carrier"

## "home" = the Yurt planet's carrier (white / orange), "rival" = the Rakip planet's (dark / red):
## the physical side (Bodies preset of `planet`), the same on both machines.
var team := "home"
var planet: Node3D = null                # the planet it serves (untyped users: compare with Game.planet)
var _center_dir := Vector3.UP
var _start_dir := Vector3.UP
var _phase0 := 0.0
var _emit: ShaderMaterial


## `base_dir`: from the planet centre toward the base; `to_other`: toward the other planet's centre.
func setup(p_team: String, p_planet: Node3D, base_dir: Vector3, to_other: Vector3) -> void:
	team = p_team
	planet = p_planet
	var c := (base_dir.normalized() - to_other.normalized() * 0.35).normalized()
	_center_dir = c
	var side := c.cross(to_other)
	if side.length_squared() < 1e-6:
		side = c.cross(Vector3.UP if absf(c.y) < 0.9 else Vector3.RIGHT)
	side = side.normalized()
	_start_dir = (c * cos(Balance.CARRIER_LOOP) + side * sin(Balance.CARRIER_LOOP)).normalized()
	_phase0 = 0.0 if team == "home" else 2.1


func _ready() -> void:
	add_to_group(GROUP)
	name = "Carrier_" + team
	_build()
	if planet != null and is_instance_valid(planet):
		global_transform = orbit_xf(_clock())


func _process(_delta: float) -> void:
	if planet == null or not is_instance_valid(planet):
		return
	global_transform = orbit_xf(_clock())


static func _clock() -> float:
	return Time.get_unix_time_from_system()


## Where the carrier is at wall-clock `time` (s).
func orbit_xf(time: float) -> Transform3D:
	var ph := fmod(time, Balance.CARRIER_PERIOD) / Balance.CARRIER_PERIOD * TAU + _phase0
	var dir := _start_dir.rotated(_center_dir, ph)
	var r := float(planet.radius) + Balance.CARRIER_ALT + sin(time * TAU / 97.0) * 1.6
	var pos: Vector3 = planet.global_position + dir * r
	var fwd := _center_dir.cross(dir)
	if fwd.length_squared() < 1e-6:
		fwd = dir.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT)
	fwd = fwd.normalized()
	# Banked a little into the loop, a slow breathing pitch.
	var inward := _center_dir - dir * _center_dir.dot(dir)
	var up := dir
	if inward.length_squared() > 1e-6:
		up = (dir + inward.normalized() * 0.07).normalized()
	fwd = (fwd + up * sin(time * TAU / 61.0) * 0.015).normalized()
	return Transform3D(Basis.looking_at(fwd, up), pos)


## The docked dropship's transform at clamp slot `slot` (its origin = the point under its skids).
func hangar_xf(slot: int) -> Transform3D:
	var z: float = Build.CV_SLOT_Z[clampi(slot, 0, Build.CV_SLOTS - 1)]
	return global_transform * Transform3D(Basis(), Vector3(0.0, Build.CV_HANGAR_Y, z))


func _build() -> void:
	var m: Dictionary = Build.carrier(team)
	var lv: Dictionary = Build.LIVERY.get(team, Build.LIVERY["home"])
	var hull := MeshInstance3D.new()
	hull.mesh = m["hull"]
	var hm: ShaderMaterial = Build.hull_material(false, 6.0)
	hm.next_pass = _fill_material(lv)
	hull.material_override = hm
	# (no shadow: a 60 m slab drifting over the base would black out whole patches of it)
	hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hull)
	_emit = Build.emit_material()
	_emit.set_shader_parameter("engine", 0.75)
	_emit.set_shader_parameter("energy", 2.4)
	var em := MeshInstance3D.new()
	em.mesh = m["emit"]
	em.material_override = _emit
	em.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(em)
	_plumes()
	# Engine glow, the bay light shining down on a docked ship (not into its cabin: no shadows).
	var eng := OmniLight3D.new()
	eng.light_color = Color(0.55, 0.75, 1.0)
	eng.omni_range = 22.0
	eng.light_energy = 1.4
	eng.shadow_enabled = false
	eng.light_cull_mask = 0xFFFFF & ~Build.INTERIOR_LAYER
	eng.position = Vector3(0.0, 0.0, Build.CV_Z_ENG1 + 4.0)
	add_child(eng)
	var bay := SpotLight3D.new()
	var lamp: Color = lv["lamp"]
	bay.light_color = lamp
	bay.spot_range = 16.0
	bay.spot_angle = 55.0
	bay.light_energy = 2.2
	bay.shadow_enabled = false
	bay.light_cull_mask = 0xFFFFF & ~Build.INTERIOR_LAYER
	bay.position = Vector3(0.0, Build.CV_KEEL_Y - 0.1, 0.0)
	bay.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	add_child(bay)
	# A slow red beacon under the keel (reads from the base below).
	_halo(Vector3(0.0, Build.CV_KEEL_Y - 0.4, -15.5), Color(1.0, 0.25, 0.15, 1.0), 2.6, 0.0035, 0.5)
	_halo(Vector3(0.0, Build.CV_KEEL_Y - 0.4, 15.5), Color(1.0, 0.25, 0.15, 1.0), 2.6, 0.0035, 0.5)
	# Beacons that read from far away (blinking halos): prow, mast, sponson fronts, engine block.
	var red := Color(1.0, 0.25, 0.15, 1.0)
	var strobe: Color = lv["strobe"]
	_halo(Build.CV_PROW_TIP, red, 3.0, 0.004, 0.55)
	_halo(Build.CV_MAST_TOP + Vector3(0.0, 0.25, 0.0), strobe, 3.4, 0.005, 0.8)
	_halo(Vector3(-10.25, -0.5, -9.2), Color(1.0, 0.2, 0.12, 1.0), 2.4, 0.0035, 0.0)
	_halo(Vector3(10.25, -0.5, -9.2), Color(0.25, 1.0, 0.4, 1.0), 2.4, 0.0035, 0.0)
	_halo(Vector3(-8.0, 3.9, 25.0), red, 2.2, 0.003, 0.45)
	_halo(Vector3(8.0, 3.9, 25.0), red, 2.2, 0.003, 0.45)
	# Name on both flanks of the hangar sponsons.
	for sx: float in [-1.0, 1.0]:
		var l := Label3D.new()
		l.text = "TAŞIYICI · %s" % str(lv["name"])
		l.font = UI.font(700)
		l.font_size = 96
		l.outline_size = 0
		l.pixel_size = 0.012
		l.shaded = false                    # a backlit sign: readable on the shaded side too
		l.double_sided = false
		l.modulate = (lv["stripe"] as Color).lightened(0.1)
		l.modulate.a = 1.0
		l.position = Vector3(sx * 10.24, -1.2, 1.0)
		l.rotation = Vector3(0.0, sx * PI * 0.5, 0.0)
		add_child(l)


## The hull's second pass (additive, unshaded): the planet's bounce light on the faces turned toward
## it (they never see the sun from where the carrier hangs) and a faint self-lit rim, so the ship reads
## as a lit hull from the ground instead of a black slab. Albedo from the hull's vertex colour.
const FILL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform vec3 fill : source_color = vec3(0.62, 0.5, 0.42);
uniform vec3 rim : source_color = vec3(0.55, 0.72, 1.0);
uniform float fill_k = 0.32;
uniform float rim_k = 0.22;
uniform float lift = 0.05;
varying vec3 wn;
varying vec3 down;

vec3 lin(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(2.2));
}

void vertex() {
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	down = -normalize(MODEL_MATRIX[1].xyz);
}

void fragment() {
	vec3 alb = lin(COLOR.rgb);
	float to_planet = max(dot(normalize(wn), down), 0.0);
	float nv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float r = pow(1.0 - nv, 3.0);
	ALBEDO = alb * fill * (fill_k * (0.35 + 0.65 * to_planet) + lift) + rim * r * rim_k;
	ALPHA = 1.0;
}
"""

## Engine plumes: soft additive cones, brightest at the nozzle (CylinderMesh UV.y 0 at its top).
const PLUME_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec3 col : source_color = vec3(0.55, 0.75, 1.0);
uniform float k = 0.6;

void fragment() {
	float along = clamp(UV.y, 0.0, 1.0);
	float nv = abs(dot(NORMAL, VIEW));
	float a = pow(1.0 - along, 1.8) * nv * nv * k * (0.9 + 0.1 * sin(TIME * 21.0 + along * 11.0));
	ALBEDO = col * 1.4;
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

static var _shaders := {}


static func _shader(key: String, code: String) -> Shader:
	if _shaders.has(key):
		return _shaders[key]
	var s := Shader.new()
	s.code = code
	_shaders[key] = s
	return s


func _fill_material(lv: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader("fill", FILL_SHADER)
	m.set_shader_parameter("fill", lv["fill"])
	m.set_shader_parameter("rim", lv["rim"])
	m.set_shader_parameter("rim_k", 0.16 if team == "home" else 0.13)
	m.render_priority = -1
	return m


func _plumes() -> void:
	var col := Color(0.55, 0.75, 1.0) if team == "home" else Color(1.0, 0.55, 0.4)
	for p: Vector3 in Build.CV_NOZZLES:
		var c := CylinderMesh.new()
		c.top_radius = 1.55
		c.bottom_radius = 0.35
		c.height = 9.0
		c.radial_segments = 16
		c.rings = 1
		c.cap_top = false
		c.cap_bottom = false
		var mat := ShaderMaterial.new()
		mat.shader = _shader("plume", PLUME_SHADER)
		mat.set_shader_parameter("col", col)
		var mi := MeshInstance3D.new()
		mi.mesh = c
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), p + Vector3(0.0, 0.0, 2.3 + 4.5))
		add_child(mi)
		_halo(p + Vector3(0.0, 0.0, 1.0), Color(col.r, col.g, col.b, 0.7), 4.5, 0.004, 0.0)


func _halo(at: Vector3, col: Color, size: float, px: float, blink: float) -> void:
	var h := MeshInstance3D.new()
	h.mesh = DebrisMesh.quad_mesh()
	h.material_override = DebrisMesh.halo_material(col, size, px, 0.0, blink)
	h.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	h.custom_aabb = AABB(Vector3.ONE * -20.0, Vector3.ONE * 40.0)
	h.position = at
	add_child(h)
