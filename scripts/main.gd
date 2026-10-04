extends Node3D
## Builds the world: a dark starry sky, a fixed sun, the two planets ("home" for the player,
## "rival" for the AI), the player, audio, the HUD and the pause menu.
##
## Layout: the planets (Bodies.PLANET_RADIUS = 60 m) sit on the x axis Bodies.PLANET_DISTANCE =
## 350 m apart (~230 m of open space between the surfaces), so everything stays well within 1 km
## of the scene origin (no floating origin needed). The sun is fixed and side-on to that axis: both facing
## hemispheres get light on their sun side, and from either planet the other one hangs in the sky
## as a half-lit disc (~23° across from the spawn point).

const Bodies := preload("res://scripts/planet/bodies.gd")
const Player := preload("res://scripts/player/player.gd")
const Hud := preload("res://scripts/ui/hud.gd")
const Sfx := preload("res://scripts/audio/sfx.gd")
const PauseMenu := preload("res://scripts/save/pause_menu.gd")
const War := preload("res://scripts/war/war.gd")
## Kept for the next phases (cannon, core, AI rival, shuttle). Preloaded here so the headless
## compile check covers them; nothing in phase 1 spawns them.
const NEXT_PHASE_KIT := [
	preload("res://scripts/items/explosion.gd"),
	preload("res://scripts/items/projectiles.gd"),
	preload("res://scripts/items/ballistics.gd"),
	preload("res://scripts/space/debris_mesh.gd"),
	preload("res://scripts/ships/interact_button.gd"),
	preload("res://scripts/player/dig.gd"),
]

## Planet centres (set in scripts/planet/bodies.gd: PLANET_DISTANCE).
const HOME_POS := Vector3(-Bodies.PLANET_DISTANCE * 0.5, 0, 0)
const RIVAL_POS := Vector3(Bodies.PLANET_DISTANCE * 0.5, 0, 0)
const SUN_DIR := Vector3(0.0, 0.35, 1.0)            # toward the sun (unit after normalizing)
const SUN_COLOR := Color(1.0, 0.95, 0.88)
## Fill light so the night side, crater shade and tunnels never sink to pitch black.
const AMBIENT := Color(0.42, 0.46, 0.55)
const AMBIENT_ENERGY := 0.55

var env: Environment
var sky_mat: ShaderMaterial
var sun: DirectionalLight3D


func _ready() -> void:
	Game.sun_dir = SUN_DIR.normalized()
	_build_environment()
	Game.planet = Bodies.spawn(self, "home", HOME_POS)
	Game.rival = Bodies.spawn(self, "rival", RIVAL_POS)

	var sfx = Sfx.new()
	sfx.name = "Sfx"
	add_child(sfx)
	Game.sfx = sfx

	var pl = Player.new()
	pl.name = "Player"
	add_child(pl)
	Game.player = pl
	Game.controlled = pl
	pl.spawn(Game.planet)

	var hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	Game.hud = hud

	var pm = PauseMenu.new()
	pm.name = "PauseMenu"
	add_child(pm)
	Game.pause_menu = pm
	# The war: cores, the AI rival, win / lose (scripts/war/war.gd).
	add_child(War.new())
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _build_environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("sun_dir", Game.sun_dir)
	sky_mat.set_shader_parameter("star_visibility", 1.0)
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT
	env.ambient_light_energy = AMBIENT_ENERGY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	# ACES alone crushes the darks and clips the brights; a slightly flatter curve keeps both
	# readable (black floor ~0.035, white ceiling ~0.965) with a touch of saturation back.
	env.adjustment_enabled = true
	env.adjustment_contrast = 0.93
	env.adjustment_saturation = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.8
	env.glow_hdr_scale = 1.5
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.light_color = SUN_COLOR
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220.0
	add_child(sun)
	var sd := Game.sun_dir
	sun.global_transform = Transform3D(Basis.looking_at(-sd, Vector3.UP if absf(sd.y) < 0.99 else Vector3.FORWARD), Vector3.ZERO)


## Where a player (or the AI rival) stands on `body`: on the side facing `other`, turned toward the
## sun so the spot is lit (~50° from the point facing `other`: the other planet stands ~30° above
## the horizon, the sun ~50°), looking at the other planet (player.gd tilts the view up to frame
## it). Returns a transform on the unedited surface plus `lift` m (spawning snaps down to the real
## ground, player.gd).
static func spawn_transform(body: Node3D, other: Node3D, lift := 1.5) -> Transform3D:
	var c: Vector3 = body.global_position
	var facing := Vector3.RIGHT
	if other != null and is_instance_valid(other):
		facing = (other.global_position - c).normalized()
	var dir := (facing + Game.sun_dir * 1.15 + Vector3.UP * 0.1).normalized()
	var r: float = float(body.radius)
	var ground: float = r + float(body.surface_height_at(c + dir * r))
	var pos := c + dir * (ground + lift)
	var up := dir
	var fwd := facing - up * facing.dot(up)
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(Vector3.RIGHT)
	var z := -fwd.normalized()
	var x := up.cross(z).normalized()
	return Transform3D(Basis(x, up, x.cross(up)), pos)
