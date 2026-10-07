extends Node
## Feeds the view model's procedural surroundings (vm_parts.gd _VM_LIT: the horizon its metals
## reflect, the ground-bright / sky-dark ambient it is lit by) two global shader uniforms, every frame:
##   vm_env_up   xyz  the world "up" at the eye (the player's up: away from the planet), so the
##                    reflected horizon and the ground bounce stay level as the view pitches and turns;
##               w    how much sun reaches the eye (a ray toward the sun: 0 in a tunnel, on the night
##                    side or in a rock's shadow), eased so it never pops
##   vm_env_sun       the world direction toward the sun (Game.sun_dir)
## The Game autoload is looked up at run time: vm_parts.gd preloads this script, and it must also
## compile where autoloads are not known (--script tools).
## Until a player exists vm_env_up.xyz stays zero and the shaders use the camera's up instead.
## vm_parts.gd prep() calls register() before any view-model shader compiles (a shader that reads a
## global uniform that does not exist fails to compile) and adds one of these nodes to the tree root.

const UP := &"vm_env_up"
const SUN := &"vm_env_sun"
const RAY := 160.0               # m toward the sun (through a planet: R 60 m)
const EASE := 2.5                # 1/s: the sun factor's fade in / out
const MASK := 1 | 2              # Game.LAYER_TERRAIN | Game.LAYER_SHIP

static var _registered := false

var _lit := 1.0
var _lit_t := 1.0


## Registers the global uniforms the view-model shaders read (once per run).
static func register() -> void:
	if _registered:
		return
	_registered = true
	var have := RenderingServer.global_shader_parameter_get_list()
	if not have.has(UP):
		RenderingServer.global_shader_parameter_add(UP, RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0.0, 0.0, 0.0, 1.0))
	if not have.has(SUN):
		RenderingServer.global_shader_parameter_add(SUN, RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(0.0, 0.35, 1.0).normalized())


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _physics_process(_delta: float) -> void:
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null or not cam.is_inside_tree():
		return
	var from := cam.global_position
	var game := get_node_or_null(^"/root/Game")
	if game == null:
		return
	var sun: Vector3 = game.sun_dir
	var q := PhysicsRayQueryParameters3D.create(from, from + sun * RAY, MASK)
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(q)
	_lit_t = 1.0 if hit.is_empty() else 0.0


func _process(delta: float) -> void:
	_lit = move_toward(_lit, _lit_t, delta * EASE)
	var up := Vector3.ZERO
	var game := get_node_or_null(^"/root/Game")
	if game == null:
		return
	var p = game.player
	if is_instance_valid(p) and p is Node3D and (p as Node3D).is_inside_tree():
		up = (p as Node3D).global_transform.basis.y.normalized()
	RenderingServer.global_shader_parameter_set(UP, Vector4(up.x, up.y, up.z, _lit))
	RenderingServer.global_shader_parameter_set(SUN, game.sun_dir)
