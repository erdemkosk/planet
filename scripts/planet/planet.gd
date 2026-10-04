extends Node3D
## Voxel planet: octree LOD of Surface-Nets chunks plus sparse density edits (dig / raise / flatten)
## like Astroneer's terrain tool. One instance per body ("home" and "rival", presets in bodies.gd).
## The node position is the body centre; chunks, focus and edits are body-local. Every public
## method below takes WORLD positions.
##
## Public API (for the player, the AI rival, cannons):
##   apply_brush(center, radius, mode, amount, plane_point, plane_normal) -> float
##       Brush.DIG / RAISE / FLATTEN at once. Returns soil volume in m³: + dug out, - placed.
##       `amount` is roughly metres of density change at the centre (a DIG of amount A lowers the
##       ground by about A there). Cost: a GDScript loop over (2r+3)³ voxels on the calling thread.
##   crater(center, radius, depth = -1) -> void
##       A big DIG (cannonball) spread over frames (CRATER_BUDGET_USEC per frame), radius capped at
##       CRATER_MAX_R. Emits crater_done(center, radius, soil) when finished.
##   density_at(world) -> float           edited density (< 0 solid, > 0 air)
##   raycast_density(from, to, step)      {} or {"position", "normal", "distance"}: works anywhere on
##                                        the body, also where no collision / fine chunk exists.
##   gravity_accel(dist), up_at(pos), surface_height_at(pos), altitude_of(pos)
##   signal brush_applied(center, radius) after every edit (world centre)
##
## Streaming:
## - Density grids are sampled on the GPU (compute shader in gpu_density.gd, run by the shared
##   gpu_service.gd thread) when available, else on CPU worker threads. Meshing, vertex attributes
##   and flora placement run on the WorkerThreadPool.
## - The LOD tree only refines a node once all its children are built (and only merges once the
##   parent is built), so the visible set is always complete: no holes, no overlapping LODs, and
##   coarse terrain appears first. Requests are prioritised by distance to the focus and by whether
##   they are in front of the camera. Distant bodies stay at their single coarse root chunk.
## - Main-thread work (mesh upload, collision shapes, multimeshes) runs under a per-frame budget.

const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const GpuService := preload("res://scripts/planet/gpu_service.gd")
const FloraMeshes := preload("res://scripts/planet/flora_meshes.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const FloraDebris := preload("res://scripts/planet/flora_debris.gd")
const TerrainTextures := preload("res://scripts/planet/terrain_textures.gd")
const DEBRIS_DIST := 70.0                    # rocks removed by digging closer than this tumble into the pit
const MOON_SHADER := preload("res://shaders/moon_terrain.gdshader")

const N := TerrainGen.N
const VOXEL := TerrainGen.VOXEL
const LOD_MAX := 9                           # default root LOD (recomputed per body in _ready)
const SPLIT_K := 1.7                         # node splits when camera is closer than size * K
const KEEP_K := 2.4                          # hidden built chunks are cached while the parent is this close
const REGEN_MAX_LOD := 3                     # default: edits re-mesh chunks up to this LOD (cfg "regen_max_lod")
const EDIT_CLAMP := 4.0
const CRATER_MAX_R := 12.0                   # crater() radius cap (m)
const CRATER_BUDGET_USEC := 3000             # crater() main-thread time per frame
const APPLY_BUDGET_USEC := 2500              # main-thread time per frame for applying finished chunks
const LOD0_COLLISION_DIST := 48.0            # collision shapes are built only this close to the camera
const LOD1_COLLISION_DIST := 45.0            # (LOD1: only while displayed, e.g. vehicles behind a look-ahead focus)
const COLLISION_URGENT_DIST := 22.0          # closer than this: build every frame, else every other frame
const FRAME_BUDGET_USEC := 4000              # total planet main-thread time per frame (collision stops here)
const EDIT_REMESH_USEC := 40000              # a chunk being dug re-meshes at most this often (25 Hz)
const EDIT_COLLISION_USEC := 120000          # ...and keeps its old collision shape at least this long
const EDIT_SETTLE_USEC := 400000             # hidden coarse chunks re-mesh once the brush rests this long
const UPDATE_INTERVAL := 0.25               # LOD tree refresh when idle...
const MIN_LOD_INTERVAL := 0.07              # ...and at most this often while moving / loading
const SAMPLES := TerrainGen.S * TerrainGen.S * TerrainGen.S

# Per flora kind: visibility range end (m) and whether it casts shadows (near chunks only).
const FLORA_VIS := [430.0, 430.0, 430.0, 460.0, 260.0, 300.0, 430.0, 150.0, 240.0, 55.0, 50.0, 90.0, 80.0, 450.0]
const FLORA_SHADOW := [true, true, true, true, true, true, true, false, true, false, false, false, false, true]
## Detailed near version (flora_meshes.gd near meshes: leaf cards, bark, smooth boulders) up to this
## distance, the cheap far version from there to FLORA_VIS; 0 = one version only.
const FLORA_NEAR := [110.0, 110.0, 110.0, 130.0, 0.0, 0.0, 0.0, 60.0, 70.0, 0.0, 0.0, 0.0, 0.0, 0.0]
const FLORA_LOD_MARGIN := 10.0

enum Brush { DIG, RAISE, FLATTEN }


class Chunk:
	var key: Vector4i
	var origin: Vector3i
	var lod: int
	var uid := 0
	var mesh_inst: MeshInstance3D
	var body: StaticBody3D
	var shape_node: CollisionShape3D
	var faces := PackedVector3Array()    # collision faces waiting for lazy creation (LOD1)
	var foliage: Array = []
	var version := 0
	var built := -1
	var running := false
	var shown := false
	var is_void := false     # built and conservatively free of any surface: never split
	var t_req := 0
	var col_usec := 0                      # when the collision shape was last (re)built
	var flora_body: StaticBody3D           # rock colliders (only while displayed)
	var colliders: Array = []              # pending flora collider specs from TerrainGen._colliders
	var flora_bufs: Array = []             # last built flora buffers, diffed after edits so removed
	                                       # rocks tumble into the pit (flora_debris.gd)


## Emitted after every terrain edit (apply_brush, each crater slice): world centre and radius.
signal brush_applied(center: Vector3, radius: float)
## Emitted when a crater() has been fully carved: world centre, radius, soil removed (m³).
signal crater_done(center: Vector3, radius: float, soil: float)

## Body preset (bodies.gd PRESETS key) and optional overrides (radius, seed, ...). Set before _ready.
var preset := "home"
var config_overrides := {}
var cfg: Dictionary = {}
var seed_value := 1337
## LOD focus in body-local coordinates; follows the current camera when auto_focus (default).
var focus := Vector3(0, 0, 3000)
var auto_focus := true
## Set false before adding to the tree to force CPU density sampling.
var prefer_gpu := true

# --- body API (see bodies.gd) ------------------------------------------------------------------
var preset_name := "home"
var display_name := "Yurt"
var radius := 150.0
var has_atmosphere := true
var atmo_height := 60.0
var gravity_surface := 0.8                   # in g
var max_height := 24.0
var max_depth := 152.0
var lod_max := LOD_MAX
var split_k := SPLIT_K                       # split distance factor for fine levels
var far_k := SPLIT_K                         # ...and for coarse levels (LOD >= FAR_LOD)
const FAR_LOD := 5
var far_lod := FAR_LOD
## Far-detail rule (cfg "detail_lod" / "detail_dist"): every node coarser than detail_lod splits
## while the focus is closer than detail_dist, so the other planet across the gap still renders
## at LOD detail_lod (2 m cells for 1) and its craters show. detail_dist 0 = off.
var detail_lod := 0
var detail_dist := 0.0
## Edits re-mesh chunks up to this LOD (cfg "regen_max_lod"; the planets use lod_max so craters on
## the far planet re-mesh too).
var regen_max_lod := REGEN_MAX_LOD
## Sphere of influence (m from the centre): Bodies.containing().
var soi_radius := 450.0
## Dig debris / soil tint of this body (cfg "soil_color"), used by the terrain tool effects.
var soil_color := Color(0.42, 0.33, 0.22)
var root := -(N << (LOD_MAX - 1))

var chunks := {}        # Vector4i -> Chunk
var displayed := {}     # Vector4i -> true: visible, complete set of built leaves
var wanted := {}        # Vector4i -> priority: chunks the LOD tree waits for
var need_build := {}    # Vector4i -> true
var edits := {}         # Vector3i region -> PackedFloat32Array(4096)
var _deferred := {}     # Vector4i -> true: hidden coarse chunks to re-mesh once editing pauses
var _last_edit_usec := 0
var tasks := {}         # WorkerThreadPool task id -> true
var results: Array = []
var mutex := Mutex.new()
var max_jobs := 4

var gen: TerrainGen
var terrain_material: ShaderMaterial
var flora_meshes: Array = []
var flora_near: Array = []           # detailed near versions (null where there is none)
var flora_materials: Array = []
var use_gpu := false

static var _flora_cache: Array = []          # [meshes, materials] shared by all bodies
static var _shape_cache := {}                # quantized flora collider shapes shared by all bodies

# GPU density service
var _gpu
var _gpu_body := -1
var _gpu_inflight := 0

var _uid := 0
var _update_timer := 0.0
var _since_lod := 0.0
var stat_visit_usec := 0
var _last_focus := Vector3(INF, INF, INF)
var _ready_changed := false
var _queue_dirty := true
var _build_queue: Array = []
var _pending: Array = []        # per-LOD arrays of finished results waiting for the main thread
var _hidden := {}               # built chunks kept hidden as a cache
var _col_pending := {}          # chunks holding collision faces not turned into a shape yet
var _col_skip := false
var _col_speed := 0.0
var _col_last_pos := Vector3.ZERO
var _col_last_usec := 0
var _hidden_scan: Array = []
var _frame_t0 := 0
var _band := {}                 # Vector4i -> bool, octree band test cache (traversal thread only)
var _state := {}                # Vector4i -> 0 created, 1 built, 2 built + void (snapshot for traversal)
var _trav_task := -1
var _trav_out: Array = []
var _tv_state := {}
var _tv_focus := Vector3.ZERO
var _tv_cam := Vector3.ZERO
var _tv_fwd := Vector3.ZERO
var _prio := {}                 # Vector4i -> float
var _cam_pos := Vector3.ZERO
var _cam_fwd := Vector3.ZERO
var _wind := 1.0
var _debris: Node3D                         # flora_debris.gd: falling trees, tumbling rocks
var _recent_brush: Array = []               # [center (body-local), radius, usec] of recent digs
## Craters being carved slice by slice (crater()): {c, r, amount, z, lo, hi, soil, world}.
var _craters: Array = []

## Debug counters (read by tests/bench_planet.gd).
var stat_applied := 0
var stat_mesh_usec := 0
var stat_col_usec := 0
var stat_shapes := 0
var stat_lat_sum := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var stat_lat_n := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var stat_mm_usec := 0
var stat_lod_usec := 0


func _enter_tree() -> void:
	Bodies.register(self)


func _ready() -> void:
	cfg = Bodies.config(preset, config_overrides)
	seed_value = int(cfg.get("seed", seed_value))
	preset_name = preset
	display_name = cfg.get("display_name", preset)
	radius = float(cfg.get("radius", radius))
	has_atmosphere = cfg.get("has_atmosphere", false)
	atmo_height = float(cfg.get("atmo_height", 0.0))
	gravity_surface = float(cfg.get("gravity", 1.0))
	max_height = float(cfg.get("max_height", max_height))
	max_depth = float(cfg.get("max_depth", max_depth))
	split_k = float(cfg.get("split_k", SPLIT_K))
	far_k = float(cfg.get("far_k", split_k))
	detail_lod = int(cfg.get("detail_lod", 0))
	detail_dist = float(cfg.get("detail_dist", 0.0))
	soil_color = cfg.get("soil_color", soil_color)
	soi_radius = radius * 3.0
	if config_overrides.has("auto_focus"):
		auto_focus = bool(config_overrides["auto_focus"])
	# Smallest root that still encloses the body.
	lod_max = 2
	while float(N << lod_max) * 0.5 < radius + max_height + 16.0:
		lod_max += 1
	root = -(N << (lod_max - 1))
	regen_max_lod = mini(int(cfg.get("regen_max_lod", REGEN_MAX_LOD)), lod_max)
	gen = TerrainGen.new(seed_value, cfg)
	max_jobs = clampi(OS.get_processor_count() - 2, 2, 16)
	_make_terrain_material()
	_pending.resize(lod_max + 1)
	for i in _pending.size():
		_pending[i] = []
	_make_foliage_meshes()
	_debris = FloraDebris.new()
	_debris.name = "FloraDebris"
	_debris.planet = self
	add_child(_debris)
	if prefer_gpu and not OS.get_cmdline_user_args().has("--cpu-terrain"):
		_gpu = GpuService.acquire()
		if _gpu != null:
			_gpu_body = _gpu.register_body(cfg)
			use_gpu = _gpu_body >= 0
	if auto_focus:
		_update_auto_focus()
	_start_traversal(false)


func _exit_tree() -> void:
	Bodies.unregister(self)
	if _trav_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_trav_task)
		_trav_task = -1
	if _gpu != null:
		_gpu.release(get_instance_id())
		_gpu = null
	for id in tasks.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	tasks.clear()


func _update_auto_focus() -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam:
		focus = cam.global_position - global_position


func _process(delta: float) -> void:
	_frame_t0 = Time.get_ticks_usec()
	if auto_focus:
		_update_auto_focus()
	_collect_finished_tasks()
	if not _craters.is_empty():
		_step_craters()
	_update_timer -= delta
	_since_lod += delta
	if _trav_task >= 0 and WorkerThreadPool.is_task_completed(_trav_task):
		WorkerThreadPool.wait_for_task_completion(_trav_task)
		_trav_task = -1
		var t0 := Time.get_ticks_usec()
		_apply_traversal()
		stat_lod_usec = Time.get_ticks_usec() - t0
	var moved := focus.distance_to(_last_focus)
	if _trav_task < 0 and (_update_timer <= 0.0 or ((moved > 4.0 or _ready_changed) and _since_lod >= MIN_LOD_INTERVAL)):
		_update_timer = UPDATE_INTERVAL
		_since_lod = 0.0
		_last_focus = focus
		_ready_changed = false
		_start_traversal(true)
	if not _deferred.is_empty() and Time.get_ticks_usec() - _last_edit_usec > EDIT_SETTLE_USEC:
		_flush_deferred()
	_dispatch()
	_apply_results()
	_process_collision()


# ------------------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------------------

## Height of the (unedited) terrain above the base radius under a world position.
func surface_height_at(pos: Vector3) -> float:
	var local := pos - global_position
	if local.length_squared() < 1.0:
		return 0.0
	return gen.surface_height(local.normalized())


## Altitude of a world position above this body's base radius.
func altitude_of(pos: Vector3) -> float:
	return pos.distance_to(global_position) - radius


## Unit "up" vector of this body at a world position.
func up_at(pos: Vector3) -> Vector3:
	return (pos - global_position).normalized()


## Pull (m/s², toward the centre) `dist` m from the centre: g·(R/r)² outside, rising linearly from
## 0 at the centre to g at the radius inside (a uniform ball), no fade with distance. Game.gravity_at
## sums it over every body, so a shell between the planets feels both.
func gravity_accel(dist: float) -> float:
	var g0 := gravity_surface * 9.81
	if dist < radius:
		return g0 * maxf(dist, 0.0) / radius
	return g0 * pow(radius / dist, 2.0)


## Fraction of the wanted LOD set that is built (for the loading overlay).
func build_progress() -> float:
	var total := displayed.size() + wanted.size()
	if total == 0:
		return 0.0
	return float(displayed.size()) / float(total)


## Wind strength for vegetation sway (1 = calm breeze, 3+ = storm).
func set_wind(strength: float) -> void:
	_wind = strength
	for m in flora_materials:
		m.set_shader_parameter("wind", strength)


# ------------------------------------------------------------------------------------------
# Terrain edits
# ------------------------------------------------------------------------------------------

## Applies a terrain-tool brush at once (world positions). mode: Brush.DIG / RAISE / FLATTEN;
## amount ~ metres of density change at the centre (smoothstep falloff to the rim); FLATTEN pulls the
## ground toward the plane through plane_point with normal plane_normal. Returns the soil volume
## (m³): positive = dug out (solid -> air), negative = placed (air -> solid).
func apply_brush(center: Vector3, radius: float, mode: int, amount: float,
		plane_point := Vector3.ZERO, plane_normal := Vector3.UP) -> float:
	# Callers pass world-space points; the voxel grid is relative to this body's centre.
	var c := center - global_position
	var lo := Vector3i((c - Vector3.ONE * (radius + 1.0)).floor())
	var hi := Vector3i((c + Vector3.ONE * (radius + 1.0)).ceil())
	var soil := _brush_slab(c, radius, mode, amount, plane_point - global_position, plane_normal, lo, hi, lo.z, hi.z)
	_after_edit(c, radius, mode, lo, hi)
	return soil


## Carves a crater (a DIG brush, cannonball impacts) over the next frames instead of at once: the
## voxel loop runs in z slices under CRATER_BUDGET_USEC per frame, then the chunks re-mesh once.
## radius is capped at CRATER_MAX_R; depth (m at the centre) defaults to ~1.2 x radius. Emits
## brush_applied when done and crater_done(center, radius, soil m³).
func crater(center: Vector3, radius: float, depth := -1.0) -> void:
	var r := clampf(radius, 1.0, CRATER_MAX_R)
	var c := center - global_position
	var lo := Vector3i((c - Vector3.ONE * (r + 1.0)).floor())
	var hi := Vector3i((c + Vector3.ONE * (r + 1.0)).ceil())
	_craters.append({"c": c, "r": r, "amount": depth if depth > 0.0 else r * 1.2, "z": lo.z, "y": lo.y,
			"lo": lo, "hi": hi, "soil": 0.0, "world": center})


## Carves pending craters row by row (one z, y line of voxels at a time) under the per-frame budget.
func _step_craters() -> void:
	var t0 := Time.get_ticks_usec()
	while not _craters.is_empty() and Time.get_ticks_usec() - t0 < CRATER_BUDGET_USEC:
		var j: Dictionary = _craters[0]
		var z: int = j["z"]
		var y: int = j["y"]
		var lo: Vector3i = j["lo"]
		var hi: Vector3i = j["hi"]
		j["soil"] = float(j["soil"]) + _brush_slab(j["c"], j["r"], Brush.DIG, j["amount"], Vector3.ZERO,
				Vector3.UP, lo, hi, z, z, y, y)
		y += 1
		if y > hi.y:
			y = lo.y
			z += 1
		j["y"] = y
		j["z"] = z
		if z > hi.z:
			_craters.pop_front()
			_after_edit(j["c"], j["r"], Brush.DIG, lo, hi)
			crater_done.emit(j["world"], j["r"], j["soil"])


## The voxel loop of a brush over z0..z1 (and y0..y1, default the whole box) of the box lo..hi
## (body-local centre c). Returns the soil volume moved (m³, + dug).
func _brush_slab(c: Vector3, r: float, mode: int, amount: float, plane_point: Vector3, plane_normal: Vector3,
		lo: Vector3i, hi: Vector3i, z0: int, z1: int, y0 := -2147483647, y1 := 2147483647) -> float:
	var soil := 0.0
	var ya := maxi(lo.y, y0)
	var yb := mini(hi.y, y1)
	for z in range(z0, z1 + 1):
		for y in range(ya, yb + 1):
			for x in range(lo.x, hi.x + 1):
				var p := Vector3(x, y, z) * VOXEL
				var dist := p.distance_to(c)
				if dist > r:
					continue
				var f := 1.0 - dist / r
				f = f * f * (3.0 - 2.0 * f)
				var key := Vector3i(x >> 4, y >> 4, z >> 4)
				var arr: PackedFloat32Array
				if edits.has(key):
					arr = edits[key]
				else:
					arr = PackedFloat32Array()
					arr.resize(4096)
					arr.fill(TerrainGen.NO_EDIT)
				var li := (x & 15) | ((y & 15) << 4) | ((z & 15) << 8)
				var cur := arr[li]
				if cur >= TerrainGen.NO_EDIT * 0.5:
					cur = gen.density_base(p)
				var nv := cur
				match mode:
					Brush.DIG:
						nv = cur + amount * f
					Brush.RAISE:
						nv = cur - amount * f
					Brush.FLATTEN:
						var target := (p - plane_point).dot(plane_normal)
						nv = lerpf(cur, target, clampf(amount * f * 0.6, 0.0, 1.0))
				nv = clampf(nv, -EDIT_CLAMP, EDIT_CLAMP)
				if cur < 0.0 and nv >= 0.0:
					soil += 1.0
				elif cur >= 0.0 and nv < 0.0:
					soil -= 1.0
				arr[li] = nv
				edits[key] = arr
	return soil * VOXEL * VOXEL * VOXEL


## After an edit: remember it for the falling-rock diff, re-mesh what it touched, tell listeners.
func _after_edit(c: Vector3, r: float, mode: int, lo: Vector3i, hi: Vector3i) -> void:
	_last_edit_usec = Time.get_ticks_usec()
	if mode != Brush.RAISE:
		# Remembered briefly so the re-meshed chunks can make the rocks here fall.
		_recent_brush.append([c, r, _last_edit_usec])
		if _recent_brush.size() > 16:
			_recent_brush.pop_front()
	_mark_dirty(lo - Vector3i.ONE, hi + Vector3i.ONE)
	brush_applied.emit(c + global_position, r)


## Edited density at a world position (< 0 solid, > 0 air): the edit if there is one, else the
## generator. Trilinear between the 1 m samples, like the mesh.
func density_at(world: Vector3) -> float:
	var p := world - global_position
	var f := p.floor()
	var b := Vector3i(f)
	var t := p - f
	var d := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for i in 8:
		d[i] = _sample(b + Vector3i(i & 1, (i >> 1) & 1, (i >> 2) & 1))
	var x00 := lerpf(d[0], d[1], t.x)
	var x10 := lerpf(d[2], d[3], t.x)
	var x01 := lerpf(d[4], d[5], t.x)
	var x11 := lerpf(d[6], d[7], t.x)
	return lerpf(lerpf(x00, x10, t.y), lerpf(x01, x11, t.y), t.z)


## Density at one body-local voxel corner (edit or generator).
func _sample(v: Vector3i) -> float:
	var arr = edits.get(Vector3i(v.x >> 4, v.y >> 4, v.z >> 4))
	if arr != null:
		var e: float = arr[(v.x & 15) | ((v.y & 15) << 4) | ((v.z & 15) << 8)]
		if e < TerrainGen.NO_EDIT * 0.5:
			return e
	return gen.density_base(Vector3(v) * VOXEL)


## Cheap density for marching: the edited value inside edited regions, else the unedited height
## field without the ±1.3 m detail noise (one surface lookup instead of eight noise samples).
func density_fast(world: Vector3) -> float:
	var p := world - global_position
	var v := Vector3i(p.floor())
	if edits.has(Vector3i(v.x >> 4, v.y >> 4, v.z >> 4)) or edits.has(Vector3i((v.x + 1) >> 4, (v.y + 1) >> 4, (v.z + 1) >> 4)):
		return density_at(world)
	var r := p.length()
	if r < 1.0:
		return -radius
	return r - radius - gen.surface_height(p / r)


## Segment test against the (edited) density field, world positions: marches `step` m at a time,
## then refines the crossing by bisection. Works anywhere on the body, also far from the camera
## where no collision shape exists. fast = march with density_fast (shells, trajectory previews);
## the crossing is always refined with the exact density. Returns {} or
## {"position", "normal", "distance"}.
func raycast_density(from: Vector3, to: Vector3, step := 0.75, fast := false) -> Dictionary:
	var seg := to - from
	var len := seg.length()
	if len < 1e-4:
		return {}
	var dir := seg / len
	# Skip the parts of the segment outside the terrain shell.
	var oc := from - global_position
	var shell := radius + max_height + 2.0
	var bb := oc.dot(dir)
	var disc := bb * bb - (oc.length_squared() - shell * shell)
	if disc < 0.0:
		return {}
	var sq := sqrt(disc)
	var t := maxf(-bb - sq, 0.0)
	var t_end := minf(-bb + sq, len)
	if t > t_end:
		return {}
	var prev := density_fast(from + dir * t) if fast else density_at(from + dir * t)
	if prev < 0.0:
		return {"position": from + dir * t, "normal": -dir, "distance": t}
	while t < t_end:
		# Density is roughly the height above the ground: far above it, take bigger steps.
		var adv := maxf(step, prev * 0.7) if fast else step
		var tn := minf(t + adv, t_end)
		var d := density_fast(from + dir * tn) if fast else density_at(from + dir * tn)
		prev = d
		if d < 0.0:
			var a := t
			var b := tn
			for i in 8:
				var m := (a + b) * 0.5
				if density_at(from + dir * m) < 0.0:
					b = m
				else:
					a = m
			var hit := from + dir * b
			return {"position": hit, "normal": density_normal(hit), "distance": b}
		t = tn
	return {}


## Outward surface normal of the density field at a world position (central differences).
func density_normal(world: Vector3) -> Vector3:
	var e := 0.5
	var n := Vector3(density_at(world + Vector3(e, 0, 0)) - density_at(world - Vector3(e, 0, 0)),
			density_at(world + Vector3(0, e, 0)) - density_at(world - Vector3(0, e, 0)),
			density_at(world + Vector3(0, 0, e)) - density_at(world - Vector3(0, 0, e)))
	return n.normalized() if n.length_squared() > 1e-10 else up_at(world)


# ------------------------------------------------------------------------------------------
# LOD octree
# ------------------------------------------------------------------------------------------

## Starts a LOD-tree traversal on a worker thread (or runs it inline when async is false). It works
## on a snapshot of chunk states, so the main thread only applies the resulting visibility diff.
func _start_traversal(async: bool) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	_cam_pos = cam.global_position - global_position if cam else focus
	_cam_fwd = -cam.global_transform.basis.z if cam else Vector3.ZERO
	var args := [_state.duplicate(), displayed, wanted, focus, _cam_pos, _cam_fwd]
	if async:
		_trav_task = WorkerThreadPool.add_task(_traverse.bind(args), true, "planet lod")
	else:
		_traverse(args)
		_apply_traversal()


# --- worker side (touches only _tv_* members, the band cache and its arguments) -------------

func _traverse(args: Array) -> void:
	var t0 := Time.get_ticks_usec()
	_tv_state = args[0]
	var old_disp: Dictionary = args[1]
	var old_want: Dictionary = args[2]
	_tv_focus = args[3]
	_tv_cam = args[4]
	_tv_fwd = args[5]
	var new_disp := {}
	var new_want := {}
	_visit(lod_max, Vector3i(root, root, root), new_disp, new_want)
	var to_hide: Array = []
	var to_show: Array = []
	var dropped: Array = []
	for k in old_disp:
		if not new_disp.has(k):
			to_hide.append(k)
	for k in new_disp:
		if not old_disp.has(k):
			to_show.append(k)
	for k in old_want:
		if not new_want.has(k):
			dropped.append(k)
	_tv_state = {}
	_trav_out = [new_disp, new_want, to_hide, to_show, dropped]
	stat_visit_usec = Time.get_ticks_usec() - t0


func _visit(lod: int, o: Vector3i, disp: Dictionary, want: Dictionary) -> void:
	var key := Vector4i(o.x, o.y, o.z, lod)
	var st: int = _tv_state.get(key, -1)
	var ready := st >= 1
	if st == 2:
		disp[key] = true
		return
	var size := float(N << lod) * VOXEL
	var mn := Vector3(o) * VOXEL
	var d := _tv_focus.distance_to(_tv_focus.clamp(mn, mn + Vector3.ONE * size))
	if _splits(lod, d, size):
		var half := N << (lod - 1)
		var csize := size * 0.5
		var all_ready := true
		# Siblings are swapped in together, so they share the parent's priority.
		var kid_prio := _priority(key)
		# Children that are void or will not split themselves are resolved here without recursing.
		var leaf_kids: Array[Vector4i] = []
		var deep_kids: Array[Vector4i] = []
		for i in 8:
			var ck := Vector4i(o.x + (i & 1) * half, o.y + ((i >> 1) & 1) * half, o.z + ((i >> 2) & 1) * half, lod - 1)
			if not _in_band(ck):
				continue
			var cst: int = _tv_state.get(ck, -1)
			if cst < 1:
				all_ready = false
				want[ck] = kid_prio
				_prefetch(ck, want)
				deep_kids.append(ck)
			elif cst == 2 or ck.w == 0:
				leaf_kids.append(ck)
			else:
				var cmn := Vector3(ck.x, ck.y, ck.z) * VOXEL
				if _splits(lod - 1, _tv_focus.distance_to(_tv_focus.clamp(cmn, cmn + Vector3.ONE * csize)), csize):
					deep_kids.append(ck)
				else:
					leaf_kids.append(ck)
		if all_ready:
			for ck in leaf_kids:
				disp[ck] = true
			for ck in deep_kids:
				_visit(ck.w, Vector3i(ck.x, ck.y, ck.z), disp, want)
			return
		if ready:
			# Children still loading: keep showing this coarser chunk meanwhile.
			disp[key] = true
			return
		# Nothing to show here yet (startup / teleport): show whatever finer chunks are ready.
		want[key] = _priority(key)
		for ck in leaf_kids:
			disp[ck] = true
		for ck in deep_kids:
			_visit(ck.w, Vector3i(ck.x, ck.y, ck.z), disp, want)
		return
	if ready:
		disp[key] = true
		return
	want[key] = _priority(key)
	# Merging: keep showing the finer chunks until this one is built.
	if lod > 0:
		var half := N << (lod - 1)
		for i in 8:
			_fallback(Vector4i(o.x + (i & 1) * half, o.y + ((i >> 1) & 1) * half, o.z + ((i >> 2) & 1) * half, lod - 1), disp)


## Requests the whole ideal subtree below a chunk that is still loading, so fine LODs (and their
## collision) are generated in parallel instead of one level at a time. Display stays gated.
func _prefetch(k: Vector4i, want: Dictionary) -> void:
	if k.w == 0:
		return
	var size := float(N << k.w) * VOXEL
	var mn := Vector3(k.x, k.y, k.z) * VOXEL
	if not _splits(k.w, _tv_focus.distance_to(_tv_focus.clamp(mn, mn + Vector3.ONE * size)), size):
		return
	var half := N << (k.w - 1)
	var kid_prio := _priority(k)
	for i in 8:
		var ck := Vector4i(k.x + (i & 1) * half, k.y + ((i >> 1) & 1) * half, k.z + ((i >> 2) & 1) * half, k.w - 1)
		if not _in_band(ck):
			continue
		var cst: int = _tv_state.get(ck, -1)
		if cst < 1:
			want[ck] = kid_prio
		elif cst == 2:
			continue
		_prefetch(ck, want)


func _fallback(k: Vector4i, disp: Dictionary) -> void:
	var st: int = _tv_state.get(k, -1)
	if st < 0:
		return
	if st >= 1:
		disp[k] = true
		return
	if k.w > 0:
		var half := N << (k.w - 1)
		for i in 8:
			_fallback(Vector4i(k.x + (i & 1) * half, k.y + ((i >> 1) & 1) * half, k.z + ((i >> 2) & 1) * half, k.w - 1), disp)


func _in_band(k: Vector4i) -> bool:
	var v = _band.get(k)
	if v != null:
		return v
	var size := float(N << k.w) * VOXEL
	var mn := Vector3(k.x, k.y, k.z) * VOXEL
	var mx := mn + Vector3.ONE * size
	var near_c := Vector3.ZERO.clamp(mn, mx).length()
	var far_c := Vector3(maxf(absf(mn.x), absf(mx.x)), maxf(absf(mn.y), absf(mx.y)), maxf(absf(mn.z), absf(mx.z))).length()
	var inside := not (near_c > radius + max_height or far_c < radius - max_depth)
	_band[k] = inside
	return inside


## Lower = sooner. Distance to the focus, penalised when behind / outside the camera view, with a
## small bias towards coarse chunks so that a complete low-detail cover always comes first.
func _priority(k: Vector4i) -> float:
	var size := float(N << k.w) * VOXEL
	var mn := Vector3(k.x, k.y, k.z) * VOXEL
	var d := _tv_focus.distance_to(_tv_focus.clamp(mn, mn + Vector3.ONE * size))
	if _tv_fwd != Vector3.ZERO:
		var v := mn + Vector3.ONE * (size * 0.5) - _tv_cam
		var dist := v.length()
		if dist > size and v.dot(_tv_fwd) < dist * 0.35:
			d *= 2.5
	return d - float(k.w) * 6.0


# --- main thread -------------------------------------------------------------------------------

func _apply_traversal() -> void:
	var out := _trav_out
	_trav_out = []
	if out.is_empty():
		return
	var new_disp: Dictionary = out[0]
	var new_want: Dictionary = out[1]
	# Swap visibility atomically: what disappears is replaced by what appears in the same frame.
	var candidates := {}
	for k in out[2]:
		var c = chunks.get(k)
		if c != null:
			_set_shown(c, false)
		candidates[k] = true
	for k in out[3]:
		var c = chunks.get(k)
		if c != null:
			_set_shown(c, true)
	for k in out[4]:
		candidates[k] = true
	displayed = new_disp
	wanted = new_want
	_prio = new_want
	for k in new_want:
		if not chunks.has(k):
			var c := Chunk.new()
			c.key = k
			c.origin = Vector3i(k.x, k.y, k.z)
			c.lod = k.w
			_uid += 1
			c.uid = _uid
			chunks[k] = c
			_state[k] = 0
			need_build[k] = true
	# Free what nobody needs any more; keep recently used built chunks hidden as a cache.
	for k in candidates:
		if new_disp.has(k) or new_want.has(k) or not chunks.has(k):
			continue
		if _keep(k):
			_hidden[k] = true
		else:
			_free_chunk(k)
	# The hidden cache (hundreds of chunks) is re-checked for eviction a slice at a time.
	if _hidden_scan.is_empty():
		_hidden_scan = _hidden.keys()
	var n := 0
	while not _hidden_scan.is_empty() and n < 120:
		var k: Vector4i = _hidden_scan.pop_back()
		n += 1
		if not _hidden.has(k):
			continue
		if new_disp.has(k) or new_want.has(k) or not chunks.has(k):
			_hidden.erase(k)
		elif not _keep(k):
			_free_chunk(k)
	_queue_dirty = true




## Split rule: a node of `lod` (box edge `size` m) at distance d from the focus is refined when it
## is closer than size * k (split_k / far_k), or when it is coarser than detail_lod and within
## detail_dist (far-detail rule: the other planet stays at detail_lod across the gap).
func _splits(lod: int, d: float, size: float) -> bool:
	if lod <= 0:
		return false
	if d < size * (split_k if lod < far_lod else far_k):
		return true
	return lod > detail_lod and d < detail_dist


func _keep(k: Vector4i) -> bool:
	if k.w >= lod_max:
		return true
	var c = chunks.get(k)
	if c == null or c.built < 0:
		return false
	var psize := N << (k.w + 1)
	var m := ~(psize - 1)
	var rel := Vector3i(k.x - root, k.y - root, k.z - root)
	var pmn := Vector3(Vector3i(rel.x & m, rel.y & m, rel.z & m) + Vector3i(root, root, root)) * VOXEL
	var d := focus.distance_to(focus.clamp(pmn, pmn + Vector3.ONE * float(psize)))
	if k.w + 1 > detail_lod and d < detail_dist * 1.2:
		return true
	var kk := split_k if k.w + 1 < far_lod else far_k
	return d < float(psize) * maxf(KEEP_K, kk * 1.4)


func _is_ready(k: Vector4i) -> bool:
	var c = chunks.get(k)
	return c != null and c.built >= 0


func _chunk_dist(c: Chunk, p: Vector3) -> float:
	var mn := Vector3(c.origin) * VOXEL
	return p.distance_to(p.clamp(mn, mn + Vector3.ONE * float(N << c.lod)))


func _set_shown(c: Chunk, on: bool) -> void:
	c.shown = on
	if on and _deferred.has(c.key):
		_deferred.erase(c.key)
		_requeue(c.key, c)
	if c.mesh_inst:
		c.mesh_inst.visible = on
	if c.body:
		c.body.collision_layer = _collision_layer(c)
	if c.flora_body:
		c.flora_body.collision_layer = 1 if on else 0
	_refresh_child_collision(c)


## Displayed chunks collide. A built but hidden LOD0 chunk also collides as a stand-in (so the
## player never falls through after a spawn / teleport) - but NOT while its displayed LOD1 parent
## already has a shape: the two surfaces differ by up to ~1 m and the astronaut wedged between
## them (walk animation playing, no progress).
func _collision_layer(c: Chunk) -> int:
	if c.shown:
		return 1
	if c.lod != 0:
		return 0
	var p = chunks.get(_parent_key(c))
	if p != null and p.shown and p.body != null:
		return 0
	return 1


## Key of the chunk one LOD level up that contains c.
func _parent_key(c: Chunk) -> Vector4i:
	var span := N << (c.lod + 1)
	return Vector4i(root + _floor_to(c.origin.x - root, span), root + _floor_to(c.origin.y - root, span),
			root + _floor_to(c.origin.z - root, span), c.lod + 1)


## A LOD1 chunk changed (shown / shape built / shape gone): its LOD0 children re-evaluate whether
## they stand in for it.
func _refresh_child_collision(p: Chunk) -> void:
	if p.lod != 1:
		return
	for i in 8:
		var ck := Vector4i(p.origin.x + (i & 1) * N, p.origin.y + ((i >> 1) & 1) * N, p.origin.z + ((i >> 2) & 1) * N, 0)
		var cc = chunks.get(ck)
		if cc != null and cc.body != null:
			cc.body.collision_layer = _collision_layer(cc)


func _free_chunk(key: Vector4i) -> void:
	var c: Chunk = chunks[key]
	if c.mesh_inst:
		c.mesh_inst.queue_free()
	chunks.erase(key)
	need_build.erase(key)
	_hidden.erase(key)
	_col_pending.erase(key)
	_deferred.erase(key)
	_state.erase(key)
	_refresh_child_collision(c)


func _mark_dirty(lo: Vector3i, hi: Vector3i) -> void:
	for lod in regen_max_lod + 1:
		var span := N << lod
		var reach := (N + 1) << lod
		var x0 := _floor_to(lo.x - reach, span)
		var y0 := _floor_to(lo.y - reach, span)
		var z0 := _floor_to(lo.z - reach, span)
		for z in range(z0, hi.z + 1, span):
			for y in range(y0, hi.y + 1, span):
				for x in range(x0, hi.x + 1, span):
					if x + reach < lo.x or y + reach < lo.y or z + reach < lo.z:
						continue
					var key := Vector4i(x, y, z, lod)
					var c = chunks.get(key)
					if c == null:
						continue
					# Coarse chunks hidden behind finer ones are re-meshed once the brush rests
					# (see _flush_deferred) instead of on every tick of a long dig.
					if lod > 0 and not c.shown:
						_deferred[key] = true
						continue
					_requeue(key, c)


func _requeue(key: Vector4i, c: Chunk) -> void:
	c.version += 1
	need_build[key] = true
	_build_queue.push_front(key)


func _flush_deferred() -> void:
	for key in _deferred:
		var c = chunks.get(key)
		if c != null:
			_requeue(key, c)
	_deferred.clear()


static func _floor_to(v: int, span: int) -> int:
	return int(floor(float(v) / span)) * span


# ------------------------------------------------------------------------------------------
# Generation: dispatch, GPU thread, worker jobs
# ------------------------------------------------------------------------------------------

func _dispatch() -> void:
	if use_gpu:
		var done: Array = _gpu.take_done(get_instance_id())
		var state: int = _gpu.state
		for item in done:
			_gpu_inflight -= 1
			var rq: Array = item[0]
			var c = chunks.get(rq[0])
			if c == null or c.uid != rq[1]:
				continue
			var id: int
			if item[1] == null:
				id = WorkerThreadPool.add_task(_cpu_job.bind(rq), false, "chunk")
			else:
				id = WorkerThreadPool.add_task(_mesh_job.bind(rq, item[1], item[2], item[3]), false, "chunk mesh")
			tasks[id] = true
		if state == -1:
			use_gpu = false
	if need_build.is_empty():
		return
	if _queue_dirty:
		_sort_queue()
	var capacity: int
	if use_gpu:
		capacity = mini(96 - _gpu_inflight, max_jobs * 3 - tasks.size())
	else:
		capacity = max_jobs - tasks.size()
	if capacity <= 0:
		return
	var pushed := false
	var now := Time.get_ticks_usec()
	var later: Array = []
	var i := 0
	while i < _build_queue.size() and capacity > 0:
		var key: Vector4i = _build_queue[i]
		i += 1
		if not need_build.has(key):
			continue
		var c = chunks.get(key)
		if c == null:
			need_build.erase(key)
			continue
		if c.running:
			continue
		# A chunk under the terrain tool re-meshes at a capped rate; the newest edits ride along.
		if c.built >= 0 and now - c.t_req < EDIT_REMESH_USEC:
			later.append(key)
			continue
		need_build.erase(key)
		c.running = true
		c.t_req = now
		var o4 := Vector4i(c.origin.x, c.origin.y, c.origin.z, c.lod)
		var rq := [key, c.uid, c.version, o4, _edits_for(c.origin, c.lod)]
		if use_gpu:
			_gpu.submit(get_instance_id(), _gpu_body, rq)
			_gpu_inflight += 1
			pushed = true
		else:
			tasks[WorkerThreadPool.add_task(_cpu_job.bind(rq), false, "chunk")] = true
		capacity -= 1
	_build_queue = later + _build_queue.slice(i) if not later.is_empty() else _build_queue.slice(i)
	if pushed:
		_gpu.flush()


func _sort_queue() -> void:
	var keys := need_build.keys()
	var packed := PackedInt64Array()
	packed.resize(keys.size())
	for i in keys.size():
		var p: float = _prio.get(keys[i], 50000.0)
		var c = chunks.get(keys[i])
		if c != null and c.built >= 0:
			p = -900.0          # rebuild after an edit: right under the player's tool, do it first
		packed[i] = (int(clampf(p + 1000.0, 0.0, 1.0e6) * 8.0) << 20) | i
	packed.sort()
	_build_queue = []
	_build_queue.resize(keys.size())
	for i in packed.size():
		_build_queue[i] = keys[packed[i] & 0xFFFFF]
	_queue_dirty = false


func _edits_for(origin: Vector3i, lod: int) -> Dictionary:
	var out := {}
	if edits.is_empty():
		return out
	var hi_g := origin + Vector3i.ONE * ((N + 1) << lod)
	var lo := Vector3i(origin.x >> 4, origin.y >> 4, origin.z >> 4)
	var hi := Vector3i(hi_g.x >> 4, hi_g.y >> 4, hi_g.z >> 4)
	if (hi.x - lo.x + 1) * (hi.y - lo.y + 1) * (hi.z - lo.z + 1) < edits.size():
		for z in range(lo.z, hi.z + 1):
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					var k := Vector3i(x, y, z)
					if edits.has(k):
						out[k] = edits[k]
		return out
	for k in edits:
		if k.x >= lo.x and k.x <= hi.x and k.y >= lo.y and k.y <= hi.y and k.z >= lo.z and k.z <= hi.z:
			out[k] = edits[k]
	return out


# rq = [key, uid, version, Vector4i(origin, lod), edit regions]
func _cpu_job(rq: Array) -> void:
	var o4: Vector4i = rq[3]
	var g := TerrainGen.new(seed_value, cfg)
	var r := g.build_chunk(Vector3i(o4.x, o4.y, o4.z), o4.w, rq[4])
	_post_result(r, rq)


func _mesh_job(rq: Array, dens: PackedFloat32Array, flags: int, min_abs: float) -> void:
	var o4: Vector4i = rq[3]
	var origin := Vector3i(o4.x, o4.y, o4.z)
	var regions: Dictionary = rq[4]
	var r: Dictionary
	var g := TerrainGen.new(seed_value, cfg)
	if not regions.is_empty():
		if g.merge_edits(dens, origin, o4.w, regions):
			r = g.mesh_from_density(dens, origin, o4.w, true)
		else:
			r = {"empty": true}
	elif flags == 3:
		r = g.mesh_from_density(dens, origin, o4.w, false)
	else:
		r = {"empty": true}
		var cell := float(1 << o4.w) * VOXEL
		if min_abs > TerrainGen.void_margin(o4.w) or g.surely_empty(Vector3(origin) * VOXEL, float(TerrainGen.S - 1) * cell):
			r["void"] = true
	_post_result(r, rq)


func _post_result(r: Dictionary, rq: Array) -> void:
	r["key"] = rq[0]
	r["uid"] = rq[1]
	r["version"] = rq[2]
	mutex.lock()
	results.append(r)
	mutex.unlock()


func _collect_finished_tasks() -> void:
	if tasks.is_empty():
		return
	for id in tasks.keys():
		if WorkerThreadPool.is_task_completed(id):
			WorkerThreadPool.wait_for_task_completion(id)
			tasks.erase(id)


func _apply_results() -> void:
	mutex.lock()
	var batch := results
	if not batch.is_empty():
		results = []
	mutex.unlock()
	for r in batch:
		var k: Vector4i = r["key"]
		_pending[k.w].append(r)
	var t0 := _frame_t0      # the LOD diff applied earlier this frame counts against the budget
	for lod in _pending.size():
		var list: Array = _pending[lod]
		if list.is_empty():
			continue
		var n := 0
		var over := false
		for r in list:
			n += 1
			_apply_one(r)
			if Time.get_ticks_usec() - t0 > APPLY_BUDGET_USEC:
				over = true
				break
		if n >= list.size():
			list.clear()
		else:
			_pending[lod] = list.slice(n)
		if over:
			return


func _apply_one(r: Dictionary) -> void:
	var key: Vector4i = r["key"]
	var c = chunks.get(key)
	if c == null or c.uid != r["uid"]:
		return
	c.running = false
	var version: int = r["version"]
	if version > c.built:
		_build_nodes(c, r)
		c.built = version
		c.is_void = r.get("void", false)
		_state[key] = 2 if c.is_void else 1
		stat_lat_sum[c.lod] += Time.get_ticks_usec() - c.t_req
		stat_lat_n[c.lod] += 1
		_ready_changed = true
		stat_applied += 1
	if c.version > c.built:
		need_build[key] = true
		_build_queue.push_front(key)


func _build_nodes(c: Chunk, r: Dictionary) -> void:
	if not _recent_brush.is_empty() and not c.flora_bufs.is_empty():
		_drop_removed_flora(c, r)
	c.flora_bufs = r.get("flora", []) if not r["empty"] else []
	for f in c.foliage:
		f.queue_free()
	c.foliage.clear()
	c.faces = PackedVector3Array()
	if r["empty"]:
		if c.mesh_inst:
			c.mesh_inst.mesh = null
		if c.body:
			c.body.queue_free()
			c.body = null
			_refresh_child_collision(c)
		if c.flora_body:
			c.flora_body.queue_free()
			c.flora_body = null
		c.colliders = []
		return
	if c.mesh_inst == null:
		c.mesh_inst = MeshInstance3D.new()
		c.mesh_inst.position = Vector3(c.origin) * VOXEL
		c.mesh_inst.material_override = terrain_material
		c.mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if c.lod <= 3 \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		c.mesh_inst.visible = c.shown
		add_child(c.mesh_inst)
	var t0 := Time.get_ticks_usec()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = r["verts"]
	arrays[Mesh.ARRAY_NORMAL] = r["normals"]
	arrays[Mesh.ARRAY_COLOR] = r["colors"]
	arrays[Mesh.ARRAY_TEX_UV] = r["uvs"]
	arrays[Mesh.ARRAY_TEX_UV2] = r["uv2s"]
	arrays[Mesh.ARRAY_INDEX] = r["indices"]
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	c.mesh_inst.mesh = m

	var t2 := Time.get_ticks_usec()
	stat_mesh_usec += t2 - t0
	# Collision shapes are built later from a distance-sorted queue (see _process_collision);
	# an existing body keeps its old shape until then so edits never open a gap under the player.
	if r.has("faces"):
		c.faces = r["faces"]
		c.colliders = r.get("colliders", [])
		_col_pending[c.key] = true
	elif c.body:
		c.body.queue_free()
		c.body = null
		_refresh_child_collision(c)
	if r.has("flora") and not flora_meshes.is_empty():
		var flora: Array = r["flora"]
		for k in flora.size():
			var buf: PackedFloat32Array = flora[k]
			if buf.is_empty():
				continue
			var shadow: bool = FLORA_SHADOW[k] and c.lod <= 1
			var near_end: float = FLORA_NEAR[k]
			if near_end > 0.0 and c.lod <= 1 and k < flora_near.size() and flora_near[k] != null:
				# Same instances twice: the detailed version close up, the cheap one beyond it.
				c.foliage.append(_multimesh(flora_near[k], buf, c.mesh_inst, near_end, shadow))
				c.foliage.append(_multimesh(flora_meshes[k], buf, c.mesh_inst, FLORA_VIS[k], shadow, near_end))
			else:
				c.foliage.append(_multimesh(flora_meshes[k], buf, c.mesh_inst, FLORA_VIS[k], shadow))
	stat_mm_usec += Time.get_ticks_usec() - t2


## After an edit re-meshed a displayed chunk near the camera: every old rock / plant near a recent
## brush stroke that has no counterpart in the new placement lost its ground, so it is handed to
## flora_debris.gd to topple / tumble into the pit instead of vanishing.
func _drop_removed_flora(c: Chunk, r: Dictionary) -> void:
	if not c.shown or c.lod > 1 or _debris == null or flora_meshes.is_empty():
		return
	var now := Time.get_ticks_usec()
	while not _recent_brush.is_empty() and now - int(_recent_brush[0][2]) > 1500000:
		_recent_brush.pop_front()
	if _recent_brush.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null or _chunk_dist(c, cam.global_position - global_position) > DEBRIS_DIST:
		return
	var origin := Vector3(c.origin) * VOXEL
	var new_flora: Array = r.get("flora", []) if not r["empty"] else []
	for k in c.flora_bufs.size():
		var ob: PackedFloat32Array = c.flora_bufs[k]
		if ob.is_empty():
			continue
		var nb: PackedFloat32Array = new_flora[k] if k < new_flora.size() else PackedFloat32Array()
		var near_new: Array = []
		var near_built := false
		var small_xf: Array = []
		var small_tint: Array = []
		var small_dig := Vector3.ZERO
		for i in range(0, ob.size(), TerrainGen.FLORA_STRIDE):
			var o := Vector3(ob[i + 3], ob[i + 7], ob[i + 11])
			var bi := _brush_near(origin + o, 3.0)
			if bi < 0:
				continue
			if not near_built:
				near_built = true
				for j in range(0, nb.size(), TerrainGen.FLORA_STRIDE):
					var on := Vector3(nb[j + 3], nb[j + 7], nb[j + 11])
					if _brush_near(origin + on, 5.0) >= 0:
						near_new.append(on)
			var kept := false
			for on: Vector3 in near_new:
				if on.distance_squared_to(o) < 1.44:
					kept = true
					break
			if kept:
				continue
			var b := Basis(Vector3(ob[i], ob[i + 4], ob[i + 8]), Vector3(ob[i + 1], ob[i + 5], ob[i + 9]),
					Vector3(ob[i + 2], ob[i + 6], ob[i + 10]))
			var wxf := global_transform * Transform3D(b, origin + o)
			var tint := Color(ob[i + 12], ob[i + 13], ob[i + 14], ob[i + 15])
			var dig: Vector3 = global_transform * (_recent_brush[bi][0] as Vector3)
			if k in FloraDebris.SMALL_KINDS:
				if small_xf.size() < 40:
					small_xf.append(wxf)
					small_tint.append(tint)
					small_dig = dig
			else:
				_debris.spawn_flora(k, flora_meshes[k], wxf, tint, dig, float(_recent_brush[bi][1]))
		if not small_xf.is_empty():
			_debris.spawn_small_batch(flora_meshes[k], small_xf, small_tint, small_dig)


## Index of a recent brush stroke whose sphere (plus margin) contains a body-local point, or -1.
func _brush_near(p: Vector3, margin: float) -> int:
	for i in range(_recent_brush.size() - 1, -1, -1):
		var e: Array = _recent_brush[i]
		if p.distance_to(e[0]) < float(e[1]) + margin:
			return i
	return -1


## Builds pending collision shapes nearest-first under a per-frame budget. Only chunks near the
## camera get one (LOD0 always when near, even while hidden behind a coarser displayed chunk).
func _process_collision() -> void:
	if _col_pending.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	# Fast cameras (vehicles) only need collision right around them.
	var cam := get_viewport().get_camera_3d()
	var cp := cam.global_position - global_position if cam else focus
	var dt := maxf(float(t0 - _col_last_usec) / 1.0e6, 0.001)
	_col_speed = lerpf(_col_speed, cp.distance_to(_col_last_pos) / dt, 0.2)
	_col_last_pos = cp
	_col_last_usec = t0
	var shrink := 1.0 - 0.5 * clampf((_col_speed - 20.0) / 60.0, 0.0, 1.0)
	var r0 := LOD0_COLLISION_DIST * shrink
	var r1 := LOD1_COLLISION_DIST * shrink
	var cands: Array = []
	var gone: Array = []
	for k in _col_pending:
		var c = chunks.get(k)
		if c == null or c.faces.is_empty():
			gone.append(k)
			continue
		# A chunk under the terrain tool re-meshes many times a second; its shape (the costly
		# part: ~1-2 ms BVH) follows a few times a second, keeping the latest faces.
		if c.body != null and t0 - c.col_usec < EDIT_COLLISION_USEC:
			continue
		var d := _chunk_dist(c, cp)
		if (c.lod == 0 and d < r0) or (c.shown and d < r1):
			cands.append([d, k])
	for k in gone:
		_col_pending.erase(k)
	if cands.is_empty():
		return
	cands.sort_custom(func(a, b): return a[0] < b[0])
	# A shape costs ~1-2.5 ms (BVH build); non-urgent ones are spread over every other frame.
	_col_skip = not _col_skip
	var urgent: bool = cands[0][0] <= COLLISION_URGENT_DIST * shrink
	if not urgent and (_col_skip or Time.get_ticks_usec() - _frame_t0 > FRAME_BUDGET_USEC):
		return
	for e in cands:
		var c: Chunk = chunks[e[1]]
		_make_collision(c, c.faces)
		_make_flora_collision(c)
		c.col_usec = Time.get_ticks_usec()
		c.faces = PackedVector3Array()
		_col_pending.erase(e[1])
		if Time.get_ticks_usec() - _frame_t0 > FRAME_BUDGET_USEC:
			break
	stat_col_usec += Time.get_ticks_usec() - t0


## Rocks (and trunks / spires when a preset places them): one StaticBody3D per chunk on the terrain layer, with
## shared (size-quantized) primitive shapes. Only collides while the chunk is displayed, so hidden
## LOD levels never leave invisible obstacles.
func _make_flora_collision(c: Chunk) -> void:
	if c.colliders.is_empty():
		if c.flora_body:
			c.flora_body.queue_free()
			c.flora_body = null
		return
	if c.flora_body == null:
		c.flora_body = StaticBody3D.new()
		c.flora_body.collision_mask = 0
		c.mesh_inst.add_child(c.flora_body)
	else:
		for o in c.flora_body.get_shape_owners():
			c.flora_body.remove_shape_owner(o)
	c.flora_body.collision_layer = 1 if c.shown else 0
	for e in c.colliders:
		var o := c.flora_body.create_shape_owner(c.flora_body)
		c.flora_body.shape_owner_add_shape(o, _shape_for(e[0], e[2]))
		c.flora_body.shape_owner_set_transform(o, e[1])
	c.colliders = []


static func _shape_for(type: int, size: Vector3) -> Shape3D:
	var q := (size / 0.05).round() * 0.05
	var key := Vector4(type, q.x, q.y, q.z)
	var s = _shape_cache.get(key)
	if s != null:
		return s
	var shape: Shape3D
	match type:
		0:
			var cy := CylinderShape3D.new()
			cy.radius = maxf(q.x, 0.05)
			cy.height = maxf(q.y, 0.1)
			shape = cy
		1:
			var bx := BoxShape3D.new()
			bx.size = (q * 2.0).max(Vector3.ONE * 0.1)
			shape = bx
		_:
			var sp := SphereShape3D.new()
			sp.radius = maxf(q.x, 0.05)
			shape = sp
	_shape_cache[key] = shape
	return shape


func _make_collision(c: Chunk, faces: PackedVector3Array) -> void:
	var fresh := c.body == null
	if fresh:
		c.body = StaticBody3D.new()
		c.body.collision_mask = 0
		c.shape_node = CollisionShape3D.new()
		c.body.add_child(c.shape_node)
		c.mesh_inst.add_child(c.body)
	c.body.collision_layer = _collision_layer(c)
	if fresh:
		_refresh_child_collision(c)
	stat_shapes += 1
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	c.shape_node.shape = shape


func _multimesh(mesh: Mesh, buf: PackedFloat32Array, parent: Node3D, vis_end: float, shadow: bool,
		vis_begin := 0.0) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = buf.size() / TerrainGen.FLORA_STRIDE
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.visibility_range_end = vis_end
	if vis_begin > 0.0:
		mmi.visibility_range_begin = vis_begin
		mmi.visibility_range_begin_margin = FLORA_LOD_MARGIN
	elif vis_end < FLORA_VIS.max():
		mmi.visibility_range_end_margin = FLORA_LOD_MARGIN
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Flora shaders take noise / wind phase body-local (stable under the floating origin).
	mmi.set_instance_shader_parameter("body_center", global_position)
	parent.add_child(mmi)
	return mmi


# ------------------------------------------------------------------------------------------
# Materials and meshes
# ------------------------------------------------------------------------------------------

func _make_terrain_material() -> void:
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = MOON_SHADER
	terrain_material.set_shader_parameter("planet_radius", radius)
	terrain_material.set_shader_parameter("planet_center", global_position)
	for k in ["col_low", "col_high", "col_rock", "col_dust", "col_mare", "col_pool", "col_crack"]:
		terrain_material.set_shader_parameter(k, cfg.get(k, Color(0.5, 0.5, 0.5)))
	for k in ["pool_emission", "crack_emission", "pool_gloss", "height_range", "detail_flat_layer"]:
		terrain_material.set_shader_parameter(k, float(cfg.get(k, 0.0)))
	var strata: Array = cfg.get("strata", [Color(0.5, 0.5, 0.5), Color(0.4, 0.4, 0.4), Color(0.3, 0.3, 0.3)])
	terrain_material.set_shader_parameter("strata_top", strata[0])
	terrain_material.set_shader_parameter("strata_mid", strata[1])
	terrain_material.set_shader_parameter("strata_deep", strata[2])
	if cfg.has("core_color"):
		terrain_material.set_shader_parameter("core_color", cfg["core_color"])
	TerrainTextures.request(self, _on_detail_texture)


func _on_detail_texture(tex: Texture2DArray) -> void:
	terrain_material.set_shader_parameter("detail_tex", tex)
	terrain_material.set_shader_parameter("detail_on", 1.0)


func _notification(what: int) -> void:
	# Keep the shaders' body centre in sync if the body ever moves: terrain and flora texture body-local.
	if what == NOTIFICATION_TRANSFORM_CHANGED and terrain_material:
		var c := global_position
		terrain_material.set_shader_parameter("planet_center", c)
		for ch in chunks.values():
			for f in (ch as Chunk).foliage:
				if is_instance_valid(f) and f is MultiMeshInstance3D:
					(f as GeometryInstance3D).set_instance_shader_parameter("body_center", c)


## Rock / flora meshes (flora_meshes.gd, shared by all bodies), only built when this body places
## any (cfg "rock_density" > 0, a "flora" list or "cave_flora").
func _make_foliage_meshes() -> void:
	set_notify_transform(true)
	var plants: Array = cfg.get("flora", [])
	if float(cfg.get("rock_density", 0.0)) <= 0.0 and plants.is_empty() and not bool(cfg.get("cave_flora", false)):
		return
	if _flora_cache.is_empty():
		_flora_cache = FloraMeshes.new().build_all()
	flora_meshes = _flora_cache[0]
	flora_materials = _flora_cache[1]
	flora_near = _flora_cache[2] if _flora_cache.size() > 2 else []


# ------------------------------------------------------------------------------------------
# Save / load (no save system yet; kept for the next phases)
# ------------------------------------------------------------------------------------------

## Terrain edits of this body, JSON-friendly. The edit regions (16³ float32 each) are packed into
## one zstd-compressed blob ("edits", base64) with their int32 region keys ("keys").
func save_state() -> Dictionary:
	var keys := PackedInt32Array()
	var raw := PackedByteArray()
	for k: Vector3i in edits:
		var arr: PackedFloat32Array = edits[k]
		if arr.size() != 4096:
			continue
		keys.append(k.x)
		keys.append(k.y)
		keys.append(k.z)
		raw.append_array(arr.to_byte_array())
	var out := {"regions": keys.size() / 3}
	if not raw.is_empty():
		out["keys"] = Marshalls.raw_to_base64(keys.to_byte_array())
		out["edits"] = Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD))
		out["raw_size"] = raw.size()
		out["codec"] = "zstd"
	return out


## Replaces the edits with saved ones and re-meshes every chunk they touch.
func load_state(d: Dictionary) -> void:
	var touched: Array = edits.keys()
	edits = {}
	var n := int(d.get("regions", 0))
	if n > 0 and d.get("keys") is String and d.get("edits") is String:
		var keys := Marshalls.base64_to_raw(d["keys"]).to_int32_array()
		var raw := Marshalls.base64_to_raw(d["edits"])
		if str(d.get("codec", "")) == "zstd":
			var size := int(d.get("raw_size", n * 4096 * 4))
			raw = raw.decompress(size, FileAccess.COMPRESSION_ZSTD) if size > 0 else PackedByteArray()
		var floats := raw.to_float32_array()
		if keys.size() >= n * 3 and floats.size() >= n * 4096:
			for i in n:
				var k := Vector3i(keys[i * 3], keys[i * 3 + 1], keys[i * 3 + 2])
				edits[k] = floats.slice(i * 4096, (i + 1) * 4096)
				touched.append(k)
		else:
			push_warning("%s: terrain edits in the save are truncated; ignored" % display_name)
	for k: Vector3i in touched:
		_mark_dirty(k * 16 - Vector3i.ONE, k * 16 + Vector3i.ONE * 16)
	_last_edit_usec = Time.get_ticks_usec()


## True once the ground under a world position has full-detail collision: every point of a few
## columns (centre + `spread` m around, down to `depth` m below) lies in a built LOD0 chunk whose
## collision shape is in, or in a chunk known to hold no surface at all. Spawning waits for this.
func terrain_ready_near(pos: Vector3, depth := 8.0, spread := 3.0) -> bool:
	var p := pos - global_position
	if p.length() > radius + max_height + depth:
		return true
	var up := p.normalized()
	var t1 := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := up.cross(t1)
	for c: Vector3 in [Vector3.ZERO, t1 * spread, -t1 * spread, t2 * spread, -t2 * spread]:
		for i in 5:
			if not _point_ready(p + c - up * (depth * float(i) / 4.0)):
				return false
	return true


## Body-local point: covered by a built LOD0 chunk with its collision done, or by a void chunk.
func _point_ready(q: Vector3) -> bool:
	var v := Vector3i(q.floor())
	for lod in lod_max + 1:
		var span := N << lod
		var k := Vector4i(root + _floor_to(v.x - root, span), root + _floor_to(v.y - root, span),
				root + _floor_to(v.z - root, span), lod)
		var c = chunks.get(k)
		if lod == 0:
			if c != null and c.built >= 0:
				return c.faces.is_empty() or not _col_pending.has(k)
			continue
		if c != null and c.built >= 0 and c.is_void:
			return true
		if displayed.has(k):
			return false
	# Not covered by anything: fine only outside the terrain shell.
	return q.length() > radius + max_height + 2.0
