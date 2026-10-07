extends Node3D
## Builds the world: a dark starry sky, a fixed sun, the two planets ("home" for the player,
## "rival" for the AI), the player, audio, the HUD and the pause menu.
##
## Layout: the planets (Bodies.PLANET_RADIUS = 30 m) sit on the x axis Bodies.PLANET_DISTANCE =
## 350 m apart (~290 m of open space between the surfaces), so everything stays well within 1 km
## of the scene origin (no floating origin needed). The sun is fixed and side-on to that axis: both facing
## hemispheres get light on their sun side, and from either planet the other one hangs in the sky
## as a half-lit disc (~10° across from the spawn point).

const Bodies := preload("res://scripts/planet/bodies.gd")
const Player := preload("res://scripts/player/player.gd")
const Hud := preload("res://scripts/ui/hud.gd")
const Sfx := preload("res://scripts/audio/sfx.gd")
const PauseMenu := preload("res://scripts/save/pause_menu.gd")
const War := preload("res://scripts/war/war.gd")
const Training := preload("res://scripts/training/training.gd")
const MotionBlur := preload("res://scripts/ui/motion_blur.gd")
const RandomWorld := preload("res://scripts/planet/random_world.gd")
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
	# Random planets (scripts/planet/random_world.gd): both built from one world seed per match
	# (single player: a new one each match; multiplayer: from the host's config, identical on both).
	# Eğitim Alanı (scripts/training/training.gd): fixed planets, home is the grey test planet "Eğitim".
	var world: Dictionary = {} if Training.active() else RandomWorld.generate(RandomWorld.match_seed())
	RandomWorld.current = world
	var home_over: Dictionary = Training.planet_overrides() if Training.active() else _planet_over(world, "home")
	Game.planet = Bodies.spawn(self, "home", HOME_POS, home_over)
	Game.rival = Bodies.spawn(self, "rival", RIVAL_POS, _planet_over(world, "rival"))
	if Net.swap_perspective():
		# Multiplayer PvP, the client plays the Rakip side: "home" (own planet, own core, spawn,
		# build area) is the Rakip planet from its point of view (scripts/net/net.gd).
		var yurt = Game.planet
		Game.planet = Game.rival
		Game.rival = yurt
	# Combat areas (scripts/planet/poi.gd): stamped into both planets' density before anything spawns.
	if not Training.active():
		preload("res://scripts/planet/poi.gd").build_world(self)

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
	add_child(MotionBlur.new())        # camera motion blur (Ayarlar › Hareket bulanıklığı)

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
	add_child(preload("res://scripts/war/respawn_ship.gd").new())   # Taşıyıcı carriers + dropship respawns
	add_child(preload("res://scripts/war/caches.gd").new())         # Gömülü sandıklar ve eski kalıntılar (buried caches)
	add_child(preload("res://scripts/war/cave_in.gd").new())        # tunnel cave-ins, burial, the entrench brushes
	if Training.active():
		add_child(Training.new())       # dummies, stats, the H panel
	else:
		add_child(preload("res://scripts/fx/space_battle.gd").new())   # cosmetic far-off space battle (Ayarlar › Arka plan savaşı)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if Net.active:
		Net.world_built(self)          # multiplayer: sync hooks, the other player, the world stream
	if not world.is_empty():
		get_tree().create_timer(1.5).timeout.connect(_announce_world)


## A planet's overrides: the multiplayer host's (preset seeds) under this match's random world.
func _planet_over(world: Dictionary, preset: String) -> Dictionary:
	var o: Dictionary = Net.planet_overrides(preset)
	o.merge(world.get(preset, {}) as Dictionary, true)
	return o


## The random planets' names, once at the start ("Yurt — Kızıl Kum   ·   Rakip — Kül Ovası").
func _announce_world() -> void:
	var line := RandomWorld.names_line(Game.planet, Game.rival)
	if line != "" and Game.hud != null and is_instance_valid(Game.hud):
		Game.hud.alert(line, 0, "world_names", 4.5)


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
## sun so the spot is lit (~50° from the point facing `other`: the other planet stands ~35° above
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
