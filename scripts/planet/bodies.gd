extends RefCounted
## The two voxel planets: presets and a registry of the spawned Planet nodes.
##
##   var p = Bodies.spawn(parent, "home", Vector3(-175, 0, 0))   # creates + registers a Planet
##   Bodies.all()            -> Array of Planet nodes
##   Bodies.nearest(pos)     -> Planet whose surface is closest to a world position
##   Bodies.dominant(pos)    -> Planet that pulls hardest at pos ("up" comes from it)
##   Bodies.containing(pos)  -> Planet whose sphere of influence (3 radii) contains pos, or null
##   Bodies.by_preset(name)  -> the Planet spawned from a preset, or null
##
## Every Planet exposes: preset_name, display_name, radius, global_position (centre),
## has_atmosphere, atmo_height, gravity_surface (g), soil_color, soi_radius, gravity_accel(dist),
## surface_height_at(world), apply_brush / crater / density_at / raycast_density (planet.gd).
##
## Generator parameters (CPU terrain_gen.gd + GPU gpu_density.gd, keep both in sync): the m_* keys
## shape the surface (continents, hills, ridged ranges, craters...). Colours (sRGB) drive
## shaders/moon_terrain.gdshader. max_depth >= radius puts the whole ball in the LOD band, so the
## planet can be dug to (and through) the core. detail_lod / detail_dist / regen_max_lod: see planet.gd.

## THE size and layout numbers (everything else derives from these two): both planets' radius and
## the centre-to-centre distance. main.gd places them at ∓PLANET_DISTANCE / 2 on the x axis. The
## surface gravity stays BASE "gravity" (0.8 g) whatever the radius; the cannon speeds, the crater
## size, the flak and the bots' ranges in scripts/war/balance.gd are tuned for these values
## (re-check them on a change). The terrain relief below scales with the radius (a scale model).
const PLANET_RADIUS := 60.0
const PLANET_DISTANCE := 350.0

## Shared by both planets; PRESETS entries override it.
const BASE := {
	# max_depth just past the centre: the whole ball is in the LOD band, so it can be dug to the core.
	# max_height: the band above the base radius (relief ~±9 m at R 60, plus raised ground).
	"kind": 1, "radius": PLANET_RADIUS, "max_height": PLANET_RADIUS * 0.3, "max_depth": PLANET_RADIUS + 2.0,
	"cave_min_r": 1.0e6, "cave_entrance": 0.0,          # no caves
	# detail_dist: the far-detail rule covers the far side of the other planet from anywhere here.
	"split_k": 2.0, "far_k": 2.0, "detail_lod": 1, "regen_max_lod": 9,
	"detail_dist": PLANET_DISTANCE + 4.0 * PLANET_RADIUS,
	# Relief (continents, hills, ridges, craters) proportional to the radius.
	"m_amp_cont": PLANET_RADIUS / 12.0, "m_freq_cont": 1.0 / (PLANET_RADIUS * 1.25),
	"m_amp_hill": PLANET_RADIUS / 30.0, "m_freq_hill": 1.0 / (PLANET_RADIUS * 0.37),
	"m_amp_mount": PLANET_RADIUS / 17.0, "m_maria": 0.0, "m_terrace": 0.0, "m_crevasse": 0.0,
	"m_crater_amp": 0.25, "m_crater_cell": PLANET_RADIUS * 0.27, "m_crater_density": 0.25, "m_volcano": 0.0,
	"m_pool_level": -1000.0,
	# Thin air on the surface (sound carries, scripts/audio/sfx.gd); the sky stays dark and starry.
	"has_atmosphere": true, "atmo_height": PLANET_RADIUS * 0.4,
	"gravity": 0.8,
	"pool_emission": 0.0, "crack_emission": 0.0, "pool_gloss": 0.0, "height_range": PLANET_RADIUS * 0.17,
	"detail_flat_layer": 0.0,
	"rock_density": 0.0015, "flora": [], "cave_flora": false,
}

const PRESETS := {
	# The player's planet: earthy grey-green ground, brown soil underneath.
	"home": {
		"display_name": "Yurt", "seed": 2024,
		"col_low": Color(0.30, 0.34, 0.25), "col_high": Color(0.42, 0.45, 0.35), "col_rock": Color(0.34, 0.33, 0.31),
		"col_dust": Color(0.47, 0.45, 0.37), "col_mare": Color(0.27, 0.30, 0.23),
		"col_pool": Color(0.3, 0.3, 0.3), "col_crack": Color(0.2, 0.2, 0.2),
		"strata": [Color(0.46, 0.37, 0.27), Color(0.37, 0.31, 0.25), Color(0.27, 0.25, 0.25)],
		"rock_tint": Color(0.42, 0.42, 0.40),
		"soil_color": Color(0.42, 0.33, 0.22),
		"core_color": Color(0.45, 0.78, 0.86),   # deep rock tint toward the core (cyan, scripts/war/core.gd)
		"step": "step_dirt",
	},
	# The AI rival's planet: rusty red.
	"rival": {
		"display_name": "Rakip", "seed": 4242,
		"col_low": Color(0.62, 0.30, 0.17), "col_high": Color(0.76, 0.45, 0.26), "col_rock": Color(0.50, 0.24, 0.14),
		"col_dust": Color(0.82, 0.55, 0.35), "col_mare": Color(0.50, 0.25, 0.15),
		"col_pool": Color(0.5, 0.3, 0.2), "col_crack": Color(0.3, 0.12, 0.08),
		"strata": [Color(0.72, 0.39, 0.21), Color(0.57, 0.27, 0.15), Color(0.35, 0.19, 0.15)],
		"rock_tint": Color(0.55, 0.28, 0.17),
		"soil_color": Color(0.58, 0.30, 0.17),
		"core_color": Color(0.92, 0.32, 0.16),   # deep rock tint toward the core (red)
		"step": "step_rock",
	},
}

static var _bodies: Array = []


## Full config for a preset (BASE + preset + optional overrides such as radius / seed).
static func config(preset: String, overrides := {}) -> Dictionary:
	var c: Dictionary = (BASE as Dictionary).duplicate(true)
	c.merge((PRESETS.get(preset, PRESETS["home"]) as Dictionary).duplicate(true), true)
	c["preset"] = preset
	for k in overrides:
		c[k] = overrides[k]
	return c


static func preset_names() -> Array:
	return PRESETS.keys()


## Creates a Planet for a preset at a world position, adds it under parent and registers it.
static func spawn(parent: Node, preset: String, position: Vector3, overrides := {}) -> Node3D:
	var p: Node3D = load("res://scripts/planet/planet.gd").new()
	p.preset = preset
	p.config_overrides = overrides
	p.name = "Planet_" + preset
	p.position = position
	parent.add_child(p)
	return p


static func all() -> Array:
	return _bodies


static func register(p: Node3D) -> void:
	if not _bodies.has(p):
		_bodies.append(p)


static func unregister(p: Node3D) -> void:
	_bodies.erase(p)


static func by_preset(preset: String) -> Node3D:
	for b in _bodies:
		if is_instance_valid(b) and str(b.preset_name) == preset:
			return b
	return null


## Body whose surface (radius) is nearest to a world position.
static func nearest(pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for b in _bodies:
		if not is_instance_valid(b):
			continue
		var d: float = pos.distance_to(b.global_position) - b.radius
		if d < best_d:
			best_d = d
			best = b
	return best


## Body with the strongest pull at pos (gravity_accel); the nearest one when nothing pulls.
static func dominant(pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_g := -1.0
	for b in _bodies:
		if not is_instance_valid(b):
			continue
		var g: float = b.gravity_accel(pos.distance_to(b.global_position))
		if g > best_g:
			best_g = g
			best = b
	return best if best != null else nearest(pos)


## Body whose sphere of influence (Planet.soi_radius) contains pos, nearest first; null in open space.
static func containing(pos: Vector3) -> Node3D:
	var b := nearest(pos)
	if b == null:
		return null
	if pos.distance_to(b.global_position) < float(b.soi_radius):
		return b
	return null
