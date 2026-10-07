extends Node
## What follows an explosive crater on one planet (war.gd makes one per planet):
##   - on planet.crater_started (every machine, also multiplayer replays): flying terrain chunks out
##     of the hole (the pusher's pooled rock chunks, KineticPusher.chunks(), when it exists) and a
##     slow, lingering dust cloud over it, sized by the crater;
##   - on planet.crater_done, host / single player only, for craters >= MIN_R: a floating-island
##     check. A coarse occupancy grid (cells of radius / 3.5, 1.25-2 m) over the crater region +
##     MARGIN is sampled a few
##     hundred cells per frame (edited voxels from planet.edits, the rest from the generator with a
##     per-direction surface cache), then flood-filled from every solid cell on the grid boundary
##     and near the planet's core. Solid components reached by neither are islands: they are dug
##     away cell by cell with Dig.dig_at (planet.apply_brush: synced to clients like any dig) and
##     fall as rock chunks. Conservative: near-surface cells count as solid (SOLID_T), islands larger
##     than MAX_ISLAND_CELLS are left alone (a sampling error must never delete real ground).

const Balance := preload("res://scripts/war/balance.gd")
const Dig := preload("res://scripts/player/dig.gd")
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const PUSHER := "res://scripts/items/kinetic_pusher.gd"

const MIN_R := 4.5                     # carved radius from which a crater is checked (cannon 5.5 m:
                                       # overlapping cannon craters get their islands cleaned up)
const MIN_FX_R := 2.0                  # flying chunks + dust from this radius (rockets, cannons, ...)
const CELL_MIN := 1.25                 # m per occupancy cell: radius / 3.5, clamped
const CELL_MAX := 2.0
const MARGIN := 4.0                    # m around the crater sphere
const SOLID_T := 0.5                   # density below this = solid (near-surface counts as solid)
const SAMPLES_PER_FRAME := 350         # ~3 ms
const FILL_PER_FRAME := 800
const REMOVE_PER_FRAME := 4
const MAX_ISLAND_CELLS := 400          # (500-3200 m³) bigger "islands" are left: likely a sampling error
const SURF_Q := 48.0

var planet: Node3D
var _queue: Array = []                 # [body-local centre, radius]
var _job := {}
var _cache := {}
var _cell := 2.0
static var _pusher: Script = null
static var _pusher_tried := false


func _ready() -> void:
	if planet == null:
		return
	planet.crater_started.connect(_on_started)
	planet.crater_done.connect(_on_done)


# =================================================================================================
# Show: flying chunks + lingering dust
# =================================================================================================

func _on_started(center: Vector3, radius: float) -> void:
	if radius < MIN_FX_R or not is_inside_tree():
		return
	var up := (center - planet.global_position).normalized()
	var soil: Color = planet.get("soil_color") if planet.get("soil_color") is Color else Color(0.45, 0.35, 0.25)
	var ch = _chunks()
	if ch != null:
		if ch.has_method("tint"):
			ch.tint(soil)
		var n := clampi(int(radius * 2.0), 4, 16)
		var x := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
		var z := up.cross(x)
		for i in n:
			var a := randf() * TAU
			var side := x * cos(a) + z * sin(a)
			var p := center + side * randf_range(0.0, radius * 0.45) + up * randf_range(0.3, 1.5)
			# Under escape speed (~22 m/s): the chunks come back down.
			var v := (up * randf_range(0.7, 1.3) + side * randf_range(0.25, 0.9)).normalized() * minf(randf_range(6.0, 7.0 + radius * 0.6), 18.0)
			ch.spawn(p, v, randf_range(0.25, 0.5) * clampf(radius / 6.0, 1.0, 2.4))
	_dust(center + up * minf(radius * 0.25, 4.0), up, radius, soil)


static func _chunks():
	if not _pusher_tried:
		_pusher_tried = true
		if ResourceLoader.exists(PUSHER):
			var s = load(PUSHER)
			if s is Script:
				_pusher = s
	if _pusher == null:
		return null
	for m in _pusher.get_script_method_list():
		if str(m.get("name", "")) == "chunks":
			return _pusher.call("chunks")
	return null


## A slow cloud hanging over the hole for a few seconds (one-shot, capped particle count).
func _dust(pos: Vector3, up: Vector3, radius: float, col: Color) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = clampi(int(radius * 2.0), 6, 16)
	p.lifetime = 7.0
	p.explosiveness = 0.7
	p.local_coords = false
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = DigFx.soft_texture()
	var q := QuadMesh.new()
	q.size = Vector2.ONE * clampf(radius * 0.5, 1.5, 5.0)
	q.material = mat
	p.mesh = q
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 0.4
	p.initial_velocity_max = 2.5
	p.damping_min = 0.2
	p.damping_max = 0.5
	p.gravity = Vector3.ZERO
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = radius * 0.5
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.6))
	sc.add_point(Vector2(1, 2.2))
	p.scale_amount_curve = sc
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	g.colors = PackedColorArray([Color(col.r, col.g, col.b, 0.0), Color(col.lightened(0.1).r, col.lightened(0.1).g, col.lightened(0.1).b, 0.42), Color(col.r, col.g, col.b, 0.0)])
	p.color_ramp = g
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var x := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	add_child(p)
	p.top_level = true
	p.global_transform = Transform3D(Basis(x, up, x.cross(up)), pos)
	p.emitting = true
	p.finished.connect(p.queue_free)


# =================================================================================================
# Floating islands (host / single player)
# =================================================================================================

func _on_done(center: Vector3, radius: float, _soil: float) -> void:
	if radius < MIN_R or Net.is_client():
		return
	_queue.append([center - planet.global_position, radius])


func _process(_delta: float) -> void:
	if _job.is_empty():
		if _queue.is_empty():
			return
		var q: Array = _queue.pop_front()
		_start(q[0], q[1])
	match str(_job["stage"]):
		"sample":
			_sample()
		"fill":
			_fill()
		"remove":
			_remove()


func _start(c: Vector3, r: float) -> void:
	var half := r + MARGIN
	_cell = clampf(r / 3.5, CELL_MIN, CELL_MAX)
	var n := int(ceilf(half * 2.0 / _cell)) + 1
	var occ := PackedByteArray()
	occ.resize(n * n * n)
	occ.fill(0)
	_cache = {}
	_job = {"stage": "sample", "c": c, "o": c - Vector3.ONE * half, "n": n, "occ": occ, "i": 0,
			"mark": PackedByteArray(), "stack": [], "islands": [], "k": 0}


func _cell_pos(o: Vector3, n: int, i: int) -> Vector3:
	return o + Vector3(float(i % n), float((i / n) % n), float(i / (n * n))) * _cell


func _sample() -> void:
	var o: Vector3 = _job["o"]
	var n: int = _job["n"]
	var occ: PackedByteArray = _job["occ"]
	var i: int = _job["i"]
	var total := n * n * n
	var end := mini(i + SAMPLES_PER_FRAME, total)
	while i < end:
		if _density_local(_cell_pos(o, n, i)) < SOLID_T:
			occ[i] = 1
		i += 1
	_job["occ"] = occ
	_job["i"] = i
	if i >= total:
		# Seeds: solid boundary cells and solid cells near the core are anchored.
		var mark := PackedByteArray()
		mark.resize(total)
		mark.fill(0)
		var stack: Array = []
		for k in total:
			if occ[k] == 0:
				continue
			var x := k % n
			var y := (k / n) % n
			var z := k / (n * n)
			var edge := x == 0 or y == 0 or z == 0 or x == n - 1 or y == n - 1 or z == n - 1
			if edge or _cell_pos(o, n, k).length() < 4.0:
				mark[k] = 1
				stack.append(k)
		_job["mark"] = mark
		_job["stack"] = stack
		_job["stage"] = "fill"


func _fill() -> void:
	var n: int = _job["n"]
	var occ: PackedByteArray = _job["occ"]
	var mark: PackedByteArray = _job["mark"]
	var stack: Array = _job["stack"]
	var budget := FILL_PER_FRAME
	var nn := n * n
	while not stack.is_empty() and budget > 0:
		budget -= 1
		var k: int = stack.pop_back()
		var x := k % n
		var y := (k / n) % n
		var z := k / nn
		for d in [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]:
			var xx: int = x + int(d[0])
			var yy: int = y + int(d[1])
			var zz: int = z + int(d[2])
			if xx < 0 or yy < 0 or zz < 0 or xx >= n or yy >= n or zz >= n:
				continue
			var j := xx + yy * n + zz * nn
			if occ[j] == 1 and mark[j] == 0:
				mark[j] = 1
				stack.append(j)
	_job["mark"] = mark
	if not stack.is_empty():
		return
	var islands: Array = []
	for k in occ.size():
		if occ[k] == 1 and mark[k] == 0:
			islands.append(k)
	if islands.is_empty() or islands.size() > MAX_ISLAND_CELLS:
		_job = {}
		return
	_job["islands"] = islands
	_job["k"] = 0
	_job["stage"] = "remove"


## Digs the floating cells away (synced brushes) and lets them fall as rock chunks.
func _remove() -> void:
	var o: Vector3 = _job["o"]
	var n: int = _job["n"]
	var islands: Array = _job["islands"]
	var k: int = _job["k"]
	var ch = _chunks()
	var base: Vector3 = planet.global_position
	var end := mini(k + REMOVE_PER_FRAME, islands.size())
	while k < end:
		var w := base + _cell_pos(o, n, int(islands[k]))
		Dig.dig_at(planet, w, _cell * 1.15, Dig.MODE_DIG, 10.0)
		if ch != null and k % 2 == 0:
			var down: Vector3 = Game.gravity_at(w).normalized()
			ch.spawn(w, down * randf_range(0.5, 2.0) + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)),
					randf_range(0.5, 0.9))
		k += 1
	_job["k"] = k
	if k >= islands.size():
		_job = {}


## Density at a body-local point (nearest voxel): the edit if that voxel was edited, else the
## generator with the surface sample cached per direction cell.
func _density_local(pl: Vector3) -> float:
	var v := Vector3i(pl.round())
	var ed: Dictionary = planet.edits
	var key := Vector3i(v.x >> 4, v.y >> 4, v.z >> 4)
	if ed.has(key):
		var arr: PackedFloat32Array = ed[key]
		var val := arr[(v.x & 15) | ((v.y & 15) << 4) | ((v.z & 15) << 8)]
		if val < TerrainGen.NO_EDIT * 0.5:
			return val
	var g = planet.gen
	var rr := pl.length()
	if rr < 1.0:
		return -float(planet.radius)
	var ck := Vector3i((pl / rr * SURF_Q).round())
	var s = _cache.get(ck)
	if s == null:
		s = g._surf((Vector3(ck) / SURF_Q).normalized())
		_cache[ck] = s
	return float(g._density(pl, rr, s))
