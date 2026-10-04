extends RefCounted
## Thread-safe density sampler + Surface Nets mesher for the voxel planets.
## Every worker job creates its own instance, so noise objects are never shared between threads.
##
## Density convention: negative = solid ground, positive = air. Surface is density == 0. Density is
## roughly a signed vertical distance in metres (r - radius - height), so a DIG brush of `amount`
## lowers the ground by about `amount` metres at its centre.
##
## One generator (the "moon" generator): continents, hills, ridged ranges, terraces, crevasses,
## hash craters, volcano cones and flat pools, all driven by the m_* keys of the body config
## (scripts/planet/bodies.gd). The material is generic soil everywhere: no ore, no biomes.
## Mirrored exactly by surf_moon() / density() in gpu_density.gd: keep both in sync, or the GPU
## self-test fails and that body silently falls back to CPU sampling.
##
## Vertex attributes written by mesh_from_density (read by shaders/moon_terrain.gdshader):
##   COLOR.r = exposed underground (dug or cave wall), UV = (pool mask, crack mask),
##   UV2 = (depth below the original surface, mare mask).

const VOXEL := 1.0           # 1 m voxels; apply_brush / _point_ready / the GPU assume exactly 1.0
const N := 16                # cells per chunk side
const S := N + 2             # samples per side (cells 0..N need samples 0..N+1)
const SS := S * S
const C := N + 1             # cells per side that may hold a vertex
const CC := C * C
const NO_EDIT := 1.0e9
const WARP_O1 := Vector3(131.7, -57.3, 89.1)     # domain warp: sample offsets of the y / z
const WARP_O2 := Vector3(-73.9, 112.6, -41.3)    # warp components (same constants in gpu_density.gd)
const COLLISION_LOD := 1
const FOLIAGE_LOD := 2
const DETAIL_LOD := 0        # cave flora only on the finest chunks
const EDGE_SHIFT := 17
const EDGE_MASK := (1 << EDGE_SHIFT) - 1
const CAVE_MAX_DEPTH := 80.0 # (gpu_density.gd repeats it)

## Flora kinds (index into flora_meshes.gd build_all()). The planets only use ROCK (and the cave
## kinds when a preset enables "cave_flora"); the rest stay available for presets.
enum Flora { PINE, BROADLEAF, PALM, JUNGLE_TREE, CACTUS, DEAD_TREE, MUSHROOM, BUSH, ROCK, GRASS, FLOWER,
		CRYSTAL_CLUSTER, GLOW_SHROOM, CRYSTAL_SPIRE }
const FLORA_COUNT := 14
const FLORA_STRIDE := 16     # floats per instance in a MultiMesh buffer (3x4 transform + custom color)
# Collision per flora kind: trunk / stalk cylinder [radius, height] in mesh units ([] = rocks, shards).
const COLLIDE := {
	0: [0.3, 5.0], 1: [0.32, 4.0], 2: [0.26, 5.5], 3: [0.6, 10.0], 4: [0.36, 3.1], 5: [0.22, 4.2],
	6: [0.3, 4.7], 8: [], 11: [], 13: [0.7, 6.0],
}
const GLOW_COLS := [Color(0.55, 0.30, 1.0), Color(0.25, 0.80, 1.0), Color(0.30, 1.0, 0.60)]

var n_cont := FastNoiseLite.new()
var n_mount := FastNoiseLite.new()
var n_hill := FastNoiseLite.new()
var n_lake := FastNoiseLite.new()
var n_detail := FastNoiseLite.new()
var n_cave1 := FastNoiseLite.new()
var n_cave2 := FastNoiseLite.new()
var n_cavern := FastNoiseLite.new()
var n_warp := FastNoiseLite.new()     # domain warp of the shape noise (a_warp > 0)

# Scratch buffers used while meshing one chunk.
var _idx := PackedInt32Array()
var _edges := {}

# Body parameters (see bodies.gd).
var cfg: Dictionary = {}
var seed_value := 1337
var radius := 150.0
var max_height := 24.0
var max_depth := 152.0
var cave_min_r := 1.0e6       # caves only above this radius (1e6 = no caves)
var cave_entrance := 0.0      # 0 = caves never open to the surface
## Coarse chunks (LOD >= 2) sample without caves: a coarse sample landing in a tunnel just below
## the ground would otherwise punch holes into the distant surface. Gameplay queries keep caves.
var no_caves := false
var m_amp_cont := 0.0
var m_amp_hill := 0.0
var m_amp_mount := 0.0
var m_maria := 0.0
var m_terrace := 0.0
var m_crevasse := 0.0
var m_crater_amp := 0.0
var m_crater_cell := 50.0
var m_crater_density := 0.0
var m_volcano := 0.0
var m_pool_level := -1000.0
var _last_mare := 0.0         # side output of _surf (per instance, so thread-safe)
# Optional potato shape: an ellipsoid term (a_axes = semi-axes / radius) and a domain-warped
# continent / hill noise (a_warp metres of warp, a_warp_freq). Mirrored in gpu_density.gd.
var a_shape := false
var a_axes := Vector3.ONE
var a_warp := 0.0
var a_warp_freq := 0.01


func _init(p_seed: int = 1337, config: Dictionary = {}) -> void:
	seed_value = p_seed
	cfg = config
	radius = float(config.get("radius", radius))
	max_height = float(config.get("max_height", max_height))
	max_depth = float(config.get("max_depth", max_depth))
	cave_min_r = float(config.get("cave_min_r", cave_min_r))
	cave_entrance = float(config.get("cave_entrance", cave_entrance))
	m_amp_cont = float(config.get("m_amp_cont", 0.0))
	m_amp_hill = float(config.get("m_amp_hill", 0.0))
	m_amp_mount = float(config.get("m_amp_mount", 0.0))
	m_maria = float(config.get("m_maria", 0.0))
	m_terrace = float(config.get("m_terrace", 0.0))
	m_crevasse = float(config.get("m_crevasse", 0.0))
	m_crater_amp = float(config.get("m_crater_amp", 0.0))
	m_crater_cell = float(config.get("m_crater_cell", 50.0))
	m_crater_density = float(config.get("m_crater_density", 0.0))
	m_volcano = float(config.get("m_volcano", 0.0))
	m_pool_level = float(config.get("m_pool_level", -1000.0))
	a_shape = config.has("a_axes")
	a_axes = config.get("a_axes", Vector3.ONE)
	a_warp = float(config.get("a_warp", 0.0))
	a_warp_freq = float(config.get("a_warp_freq", 0.01))
	# Frequencies scale with the body (keep in sync with gpu_density.gd surf_moon / density).
	_setup(n_cont, seed_value, float(config.get("m_freq_cont", 1.0 / 300.0)), FastNoiseLite.FRACTAL_FBM, 4)
	_setup(n_mount, seed_value + 1, 1.0 / 150.0, FastNoiseLite.FRACTAL_RIDGED, 4)
	_setup(n_hill, seed_value + 2, float(config.get("m_freq_hill", 1.0 / 60.0)), FastNoiseLite.FRACTAL_FBM, 3)
	_setup(n_lake, seed_value + 3, 1.0 / 90.0, FastNoiseLite.FRACTAL_NONE, 1)
	_setup(n_warp, seed_value + 15, a_warp_freq, FastNoiseLite.FRACTAL_FBM, 2)
	_setup(n_detail, seed_value + 4, 1.0 / 16.0, FastNoiseLite.FRACTAL_FBM, 2)
	_setup(n_cave1, seed_value + 9, 1.0 / 42.0, FastNoiseLite.FRACTAL_NONE, 1)
	_setup(n_cave2, seed_value + 10, 1.0 / 42.0, FastNoiseLite.FRACTAL_NONE, 1)
	_setup(n_cavern, seed_value + 11, 1.0 / 75.0, FastNoiseLite.FRACTAL_NONE, 1)


func _setup(n: FastNoiseLite, s: int, freq: float, fractal: FastNoiseLite.FractalType, octaves: int) -> void:
	n.seed = s
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_type = fractal
	n.fractal_octaves = octaves


# ------------------------------------------------------------------------------------------
# Terrain shape
# ------------------------------------------------------------------------------------------

## Terrain height (metres above the base radius) for a unit direction from the body centre.
func surface_height(dir: Vector3) -> float:
	return _surf(dir).x


## Surface: continents/maria, ridged ranges, mesa terraces, crevasses, hash-based craters and
## volcano cones, and flat pools below m_pool_level. Returns (height, pool mask, crack mask, crack
## noise); the mare mask goes to _last_mare. With a_axes / a_warp the body is a potato (still a
## radial height field, so every surface_height() user keeps working).
## Mirrored exactly by surf_moon() in gpu_density.gd.
func _surf(dir: Vector3) -> Vector4:
	var q := dir * radius
	var qn := q
	if a_warp > 0.0:
		qn = q + Vector3(n_warp.get_noise_3dv(q), n_warp.get_noise_3dv(q + WARP_O1),
				n_warp.get_noise_3dv(q + WARP_O2)) * a_warp
	var c := n_cont.get_noise_3dv(qn)
	var nh := n_hill.get_noise_3dv(qn)
	var l := n_lake.get_noise_3dv(q)
	var h := c * m_amp_cont + nh * m_amp_hill
	if a_shape:
		# Ellipsoid with semi-axes radius * a_axes: its distance from the centre along dir.
		var e := Vector3(dir.x / a_axes.x, dir.y / a_axes.y, dir.z / a_axes.z)
		h += radius * (1.0 / sqrt(maxf(e.length_squared(), 0.01)) - 1.0)
	if m_amp_mount > 0.0:
		var mt := n_mount.get_noise_3dv(q) * 0.5 + 0.5
		h += mt * mt * m_amp_mount * smoothstep(-0.05, 0.3, c)
	var mare := 0.0
	if m_maria > 0.0:
		mare = smoothstep(-0.05, -0.25, c) * m_maria
		h = lerpf(h, -m_amp_cont * 0.25 + nh * 0.6, mare)
	if m_terrace > 0.0:
		var k := h / m_terrace
		var fk := floorf(k)
		h = lerpf(h, (fk + smoothstep(0.55, 0.9, k - fk)) * m_terrace, 0.85)
	var crack := 0.0
	if m_crevasse > 0.0:
		crack = 1.0 - smoothstep(0.0, 0.045, absf(l))
		h -= crack * m_crevasse
	if m_crater_amp > 0.0:
		h += _craters(q / m_crater_cell, 0) * m_crater_amp * m_crater_cell
	if m_volcano > 0.0:
		h += _volcanoes(q / (m_crater_cell * 4.0)) * m_volcano
	var pool := 0.0
	if h < m_pool_level:
		pool = clampf((m_pool_level - h) * 2.0, 0.0, 1.0)
		h = m_pool_level - (m_pool_level - h) * 0.04
	_last_mare = mare
	return Vector4(h, pool, crack, l)


## Sum of crater profiles (in cell units) from the 2x2x2 nearest lattice cells.
func _craters(p: Vector3, salt: int) -> float:
	var b := (p - Vector3(0.5, 0.5, 0.5)).floor()
	var bx := int(b.x)
	var by := int(b.y)
	var bz := int(b.z)
	var off := 0.0
	for k in 8:
		var cx := bx + (k & 1)
		var cy := by + ((k >> 1) & 1)
		var cz := bz + ((k >> 2) & 1)
		var hs := _ihash(cx, cy, cz, seed_value + salt)
		if float(hs & 255) > m_crater_density * 255.0 + 0.25:     # never exactly on the boundary (GPU parity)
			continue
		var center := Vector3(float(cx) + 0.25 + 0.5 * float((hs >> 8) & 255) / 255.0,
				float(cy) + 0.25 + 0.5 * float((hs >> 16) & 255) / 255.0,
				float(cz) + 0.25 + 0.5 * float((hs >> 24) & 255) / 255.0)
		var rad := 0.18 + 0.3 * float((hs >> 4) & 255) / 255.0
		var d := p.distance_to(center) / rad
		if d > 1.7:
			continue
		var bowl := maxf(d * d - 1.0, -0.55) if d < 1.0 else 0.0
		var rim := 0.32 * exp(-(d - 1.0) * (d - 1.0) * 14.0)
		off += (bowl + rim) * rad
	return off


## Volcano cones with a summit crater (unit height), sparse.
func _volcanoes(p: Vector3) -> float:
	var b := (p - Vector3(0.5, 0.5, 0.5)).floor()
	var bx := int(b.x)
	var by := int(b.y)
	var bz := int(b.z)
	var off := 0.0
	for k in 8:
		var cx := bx + (k & 1)
		var cy := by + ((k >> 1) & 1)
		var cz := bz + ((k >> 2) & 1)
		var hs := _ihash(cx, cy, cz, seed_value + 7)
		if float(hs & 255) > 0.35 * 255.0 + 0.25:
			continue
		var center := Vector3(float(cx) + 0.25 + 0.5 * float((hs >> 8) & 255) / 255.0,
				float(cy) + 0.25 + 0.5 * float((hs >> 16) & 255) / 255.0,
				float(cz) + 0.25 + 0.5 * float((hs >> 24) & 255) / 255.0)
		var d := p.distance_to(center) / 0.45
		if d >= 1.0:
			continue
		var cone := (1.0 - d) * (1.0 - d) * 0.6 + (1.0 - d) * 0.4
		off += cone - smoothstep(0.22, 0.08, d) * 0.45
	return off


## 32-bit integer hash, bit-identical to the GLSL version (uint arithmetic).
static func _ihash(x: int, y: int, z: int, s: int) -> int:
	var h := ((x * 1597334677) ^ (y * 1812015801) ^ (z * 1798796415) ^ (s * 1979697957)) & 0xFFFFFFFF
	h = ((h ^ (h >> 15)) * 1274126177) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1103515245) & 0xFFFFFFFF
	return h ^ (h >> 16)


## Unedited density at a body-local point (solid at the very centre).
func density_base(p: Vector3) -> float:
	var r := p.length()
	if r < 1.0:
		return -radius
	return _density(p, r, _surf(p / r))


func _density(p: Vector3, r: float, s: Vector4) -> float:
	var d := r - radius - s.x
	if d > -8.0 and d < 8.0:
		d += n_detail.get_noise_3dv(p) * 1.3
	if not no_caves and d < 4.0 and d > -CAVE_MAX_DEPTH and r > cave_min_r:
		d = maxf(d, _cave(p, r, -d, s.w))
	return d


## Cave field (positive = air): spaghetti tunnels where two noise iso-surfaces cross, plus big
## flattened caverns deeper down (off on the small planets: cave_min_r 1e6).
func _cave(p: Vector3, r: float, depth: float, l: float) -> float:
	var top := 4.0 - 8.0 * cave_entrance * smoothstep(-0.4, -0.52, l)
	if depth < top:
		return -100.0
	var up := p / r
	var sq := p + up * ((r - radius) * 1.2)       # squash vertically: tunnels run mostly level
	var n1 := n_cave1.get_noise_3dv(sq)
	var n2 := n_cave2.get_noise_3dv(sq)
	var cv := (0.17 - maxf(absf(n1), absf(n2))) * 16.0
	if depth > 20.0:
		var n3 := n_cavern.get_noise_3dv(p + up * ((r - radius) * 1.8))
		cv = maxf(cv, (n3 - 0.55 -(1.0 - smoothstep(20.0, 30.0, depth)) * 0.6) * 45.0)
	var f := smoothstep(top, top + 5.0, depth) * smoothstep(cave_min_r, cave_min_r + 6.0, r) \
			* (1.0 - smoothstep(CAVE_MAX_DEPTH - 12.0, CAVE_MAX_DEPTH, depth))
	return cv - (1.0 - f) * 16.0


## A sampled chunk whose densities all have the same sign and |d| above this is treated as holding
## no surface at all (the LOD tree then never splits it). Density is roughly a vertical distance, so
## a feature would have to rise > 2.5 cells between two samples to be missed.
static func void_margin(lod: int) -> float:
	return 2.5 * float(1 << lod) * VOXEL + 2.0


## Cheap conservative test: true when the chunk box certainly holds no surface (all air, or all
## solid rock without caves). Samples the height field on a coarse lattice with a safety margin.
func surely_empty(lo: Vector3, size: float) -> bool:
	if size > 300.0:
		return false
	var hi := lo + Vector3.ONE * size
	var rmin := Vector3.ZERO.clamp(lo, hi).length()
	var rmax := Vector3(maxf(absf(lo.x), absf(hi.x)), maxf(absf(lo.y), absf(hi.y)), maxf(absf(lo.z), absf(hi.z))).length()
	if rmin - radius > max_height or rmax - radius < -max_depth - 20.0:
		return true
	var stp := size / 3.0
	var hmin := INF
	var hmax := -INF
	for k in 4:
		for j in 4:
			for i in 4:
				var h := _surf((lo + Vector3(i, j, k) * stp).normalized()).x
				hmin = minf(hmin, h)
				hmax = maxf(hmax, h)
	var margin := 4.0 + stp * 2.0
	if rmin - radius > hmax + margin:
		return true
	if rmax - radius < hmin - margin:
		return rmax < cave_min_r or radius + hmin - margin - rmax > CAVE_MAX_DEPTH + 4.0
	return false


# ------------------------------------------------------------------------------------------
# Chunk meshing
# ------------------------------------------------------------------------------------------

## Builds mesh data for one chunk. origin is in LOD0 grid units, lod sets the sample step (2^lod).
## edit_regions: Vector3i(region) -> PackedFloat32Array(4096) of density overrides.
func build_chunk(origin: Vector3i, lod: int, edit_regions: Dictionary) -> Dictionary:
	no_caves = lod >= 2
	var step := 1 << lod
	var cell := float(step) * VOXEL
	var world_origin := Vector3(origin) * VOXEL
	var result := {"empty": true}
	var has_edits := not edit_regions.is_empty()
	if not has_edits and surely_empty(world_origin, float(S - 1) * cell):
		result["void"] = true      # no surface anywhere in the box: the LOD tree won't split it
		return result

	# --- 1. Sample density -------------------------------------------------------------
	var dens := PackedFloat32Array()
	dens.resize(S * SS)
	var neg := false
	var pos := false
	var i := 0
	for z in S:
		var gz := origin.z + z * step
		for y in S:
			var gy := origin.y + y * step
			for x in S:
				var gx := origin.x + x * step
				var d := NO_EDIT
				if has_edits:
					var region = edit_regions.get(Vector3i(gx >> 4, gy >> 4, gz >> 4))
					if region != null:
						d = region[(gx & 15) | ((gy & 15) << 4) | ((gz & 15) << 8)]
				if d >= NO_EDIT * 0.5:
					d = density_base(Vector3(gx, gy, gz) * VOXEL)
				dens[i] = d
				if d < 0.0:
					neg = true
				else:
					pos = true
				i += 1
	if not (neg and pos):
		if not has_edits:
			var mind := INF
			for v in dens:
				mind = minf(mind, absf(v))
			if mind > void_margin(lod):
				result["void"] = true
		return result
	return mesh_from_density(dens, origin, lod, has_edits)


## Overrides base densities (e.g. from the GPU) with player edits. Returns true when the grid holds
## both solid and air afterwards.
func merge_edits(dens: PackedFloat32Array, origin: Vector3i, lod: int, edit_regions: Dictionary) -> bool:
	var step := 1 << lod
	var neg := false
	var pos := false
	var i := 0
	for z in S:
		var gz := origin.z + z * step
		for y in S:
			var gy := origin.y + y * step
			for x in S:
				var gx := origin.x + x * step
				var region = edit_regions.get(Vector3i(gx >> 4, gy >> 4, gz >> 4))
				if region != null:
					var e: float = region[(gx & 15) | ((gy & 15) << 4) | ((gz & 15) << 8)]
					if e < NO_EDIT * 0.5:
						dens[i] = e
				if dens[i] < 0.0:
					neg = true
				else:
					pos = true
				i += 1
	return neg and pos


## Surface Nets + attributes + flora from a sampled density grid (S^3 samples).
func mesh_from_density(dens: PackedFloat32Array, origin: Vector3i, lod: int, has_edits: bool) -> Dictionary:
	no_caves = lod >= 2
	var step := 1 << lod
	var cell := float(step) * VOXEL
	var world_origin := Vector3(origin) * VOXEL
	var result := {"empty": true}

	# --- 2. One vertex per cell that the surface crosses ---------------------------------
	var cell_vert := PackedInt32Array()
	cell_vert.resize(C * CC)
	cell_vert.fill(-1)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for z in C:
		for y in C:
			for x in C:
				var b := x + y * S + z * SS
				var c0 := dens[b]
				var c1 := dens[b + 1]
				var c2 := dens[b + S]
				var c3 := dens[b + S + 1]
				var c4 := dens[b + SS]
				var c5 := dens[b + SS + 1]
				var c6 := dens[b + SS + S]
				var c7 := dens[b + SS + S + 1]
				var s0 := c0 < 0.0
				var s1 := c1 < 0.0
				var s2 := c2 < 0.0
				var s3 := c3 < 0.0
				var s4 := c4 < 0.0
				var s5 := c5 < 0.0
				var s6 := c6 < 0.0
				var s7 := c7 < 0.0
				if s0 == s1 and s0 == s2 and s0 == s3 and s0 == s4 and s0 == s5 and s0 == s6 and s0 == s7:
					continue
				var acc := Vector3.ZERO
				var cnt := 0
				# x edges
				if s0 != s1:
					acc += Vector3(c0 / (c0 - c1), 0.0, 0.0)
					cnt += 1
				if s2 != s3:
					acc += Vector3(c2 / (c2 - c3), 1.0, 0.0)
					cnt += 1
				if s4 != s5:
					acc += Vector3(c4 / (c4 - c5), 0.0, 1.0)
					cnt += 1
				if s6 != s7:
					acc += Vector3(c6 / (c6 - c7), 1.0, 1.0)
					cnt += 1
				# y edges
				if s0 != s2:
					acc += Vector3(0.0, c0 / (c0 - c2), 0.0)
					cnt += 1
				if s1 != s3:
					acc += Vector3(1.0, c1 / (c1 - c3), 0.0)
					cnt += 1
				if s4 != s6:
					acc += Vector3(0.0, c4 / (c4 - c6), 1.0)
					cnt += 1
				if s5 != s7:
					acc += Vector3(1.0, c5 / (c5 - c7), 1.0)
					cnt += 1
				# z edges
				if s0 != s4:
					acc += Vector3(0.0, 0.0, c0 / (c0 - c4))
					cnt += 1
				if s1 != s5:
					acc += Vector3(1.0, 0.0, c1 / (c1 - c5))
					cnt += 1
				if s2 != s6:
					acc += Vector3(0.0, 1.0, c2 / (c2 - c6))
					cnt += 1
				if s3 != s7:
					acc += Vector3(1.0, 1.0, c3 / (c3 - c7))
					cnt += 1
				var lp := Vector3(x, y, z) + acc / float(cnt)
				var n := Vector3(
					(c1 - c0) + (c3 - c2) + (c5 - c4) + (c7 - c6),
					(c2 - c0) + (c3 - c1) + (c6 - c4) + (c7 - c5),
					(c4 - c0) + (c5 - c1) + (c6 - c2) + (c7 - c3))
				if n.length_squared() < 1e-12:
					n = (world_origin + lp * cell).normalized()
				cell_vert[x + y * C + z * CC] = verts.size()
				verts.append(lp * cell)
				norms.append(n.normalized())

	if verts.is_empty():
		return result

	# --- 3. Quads for every sign-changing grid edge ---------------------------------------
	_idx = PackedInt32Array()
	_edges = {}
	for z in range(1, N + 1):
		for y in range(1, N + 1):
			for x in N:
				var b := x + y * S + z * SS
				var d0 := dens[b]
				if (d0 < 0.0) == (dens[b + 1] < 0.0):
					continue
				var k := x + y * C + z * CC
				_quad(cell_vert[k - C - CC], cell_vert[k - CC], cell_vert[k], cell_vert[k - C], d0 >= 0.0)
	for z in range(1, N + 1):
		for y in N:
			for x in range(1, N + 1):
				var b := x + y * S + z * SS
				var d0 := dens[b]
				if (d0 < 0.0) == (dens[b + S] < 0.0):
					continue
				var k := x + y * C + z * CC
				_quad(cell_vert[k - 1 - CC], cell_vert[k - CC], cell_vert[k], cell_vert[k - 1], d0 < 0.0)
	for z in N:
		for y in range(1, N + 1):
			for x in range(1, N + 1):
				var b := x + y * S + z * SS
				var d0 := dens[b]
				if (d0 < 0.0) == (dens[b + SS] < 0.0):
					continue
				var k := x + y * C + z * CC
				_quad(cell_vert[k - 1 - C], cell_vert[k - C], cell_vert[k], cell_vert[k - 1], d0 >= 0.0)

	if _idx.is_empty():
		return result

	# --- 4. Per-vertex attributes -----------------------------------------------------------
	# COLOR.r = exposed underground (dug or cave wall); UV = (pool, crack) masks; UV2 = (depth below
	# the original surface, mare mask).
	var nv := verts.size()
	var colors := PackedColorArray()
	colors.resize(nv)
	colors.fill(Color(0, 0, 0, 0))
	var uvs := PackedVector2Array()
	uvs.resize(nv)
	var uv2s := PackedVector2Array()
	uv2s.resize(nv)
	var vkind := PackedByteArray()     # 0 surface, 1 cave wall, 2 dug / raised by the player
	vkind.resize(nv)
	var cave_depth := 2.5 + float(lod) * 1.5
	for vi in nv:
		var wp := world_origin + verts[vi]
		var r := maxf(wp.length(), 0.001)
		var s := _surf(wp / r)
		var depth := radius + s.x - r
		uvs[vi] = Vector2(s.y, s.z)
		uv2s[vi] = Vector2(depth, _last_mare)
		var disturbed := 0.0
		if has_edits:
			var base := _density(wp, r, s)
			disturbed = clampf(absf(base) / 1.2 - 0.25, 0.0, 1.0)
			if disturbed > 0.0:
				vkind[vi] = 2
		if lod <= 1 and depth > cave_depth:
			disturbed = maxf(disturbed, clampf((depth - cave_depth) * 2.0, 0.0, 1.0))
			if vkind[vi] == 0:
				vkind[vi] = 1
		colors[vi] = Color(disturbed, 0, 0, 0)

	# --- 5. Collision faces (near chunks only, before skirts are added) -------------------
	if lod <= COLLISION_LOD:
		var faces := PackedVector3Array()
		faces.resize(_idx.size())
		for fi in _idx.size():
			faces[fi] = verts[_idx[fi]]
		result["faces"] = faces

	# --- 6. Flora (rocks) placement --------------------------------------------------------
	if lod <= FOLIAGE_LOD:
		_place_flora(result, world_origin, lod, verts, norms, uvs, vkind)
		if lod <= COLLISION_LOD:
			result["colliders"] = _colliders(result)

	# --- 7. Skirts on open chunk borders to hide cracks between different LODs ------------
	var skirt_len := cell * 1.3
	for key in _edges:
		if _edges[key] != 1:
			continue
		var a: int = key >> EDGE_SHIFT
		var b: int = key & EDGE_MASK
		var a2 := verts.size()
		var b2 := a2 + 1
		verts.append(verts[a] - norms[a] * skirt_len)
		norms.append(norms[a])
		colors.append(colors[a])
		uvs.append(uvs[a])
		uv2s.append(uv2s[a])
		verts.append(verts[b] - norms[b] * skirt_len)
		norms.append(norms[b])
		colors.append(colors[b])
		uvs.append(uvs[b])
		uv2s.append(uv2s[b])
		_idx.append_array(PackedInt32Array([a, b, b2, a, b2, a2, a, b2, b, a, a2, b2]))

	result["empty"] = false
	result["verts"] = verts
	result["normals"] = norms
	result["colors"] = colors
	result["uvs"] = uvs
	result["uv2s"] = uv2s
	result["indices"] = _idx
	return result


## Rocks, the preset's flora list ([kind, density, tint, min scale, max scale, detail only]) and
## cave flora ("cave_flora"). Nothing grows in pools or cracks, dug pits stay bare.
func _place_flora(result: Dictionary, world_origin: Vector3, lod: int, verts: PackedVector3Array,
		norms: PackedVector3Array, uvs: PackedVector2Array, vkind: PackedByteArray) -> void:
	var cell := float(1 << lod) * VOXEL
	var area := cell * cell
	var detail := lod <= DETAIL_LOD
	var flora := []
	for k in FLORA_COUNT:
		flora.append(PackedFloat32Array())
	var plants: Array = cfg.get("flora", [])
	var rock_d: float = cfg.get("rock_density", 0.0)
	var rock_t: Color = cfg.get("rock_tint", Color(0.5, 0.5, 0.5))
	var cave_flora: bool = cfg.get("cave_flora", false)
	for vi in verts.size():
		var lv := verts[vi]
		var nrm := norms[vi]
		var wp := world_origin + lv
		var up := wp.normalized()
		var slope := nrm.dot(up)
		if slope < 0.45:
			continue
		var hx := int(round(wp.x * 3.0))
		var hy := int(round(wp.y * 3.0))
		var hz := int(round(wp.z * 3.0))
		var kd := vkind[vi]
		if kd != 0:
			if kd == 1 and detail and cave_flora and slope > 0.55:
				var rc := _hash01(hx, hy, hz, 21)
				var rr := _hash01(hx, hy, hz, 22)
				if rc < 0.03 * area:
					var cb := _basis_from_up(nrm.lerp(up, 0.5).normalized()).rotated(nrm, rr * TAU)
					_push(flora[Flora.CRYSTAL_CLUSTER], cb.scaled(Vector3.ONE * (0.5 + rr * 0.9)), lv - nrm * 0.1,
							GLOW_COLS[int(rr * 2.99)])
				elif rc > 1.0 - 0.06 * area:
					var gb := _basis_from_up(up).rotated(up, rr * TAU)
					_push(flora[Flora.GLOW_SHROOM], gb.scaled(Vector3.ONE * (0.6 + rr * 0.8)), lv - up * 0.05,
							GLOW_COLS[int(_hash01(hx, hy, hz, 23) * 2.99)])
			continue
		if uvs[vi].x > 0.3 or uvs[vi].y > 0.3:
			continue
		var r1 := _hash01(hx, hy, hz, 1)
		# --- preset plants / spires
		var acc := 0.0
		var placed := false
		for e: Array in plants:
			var detail_only: bool = e[5]
			if detail_only and not detail:
				continue
			var fk: int = e[0]
			if fk != Flora.GLOW_SHROOM and slope < 0.8:
				continue
			acc += float(e[1]) * area
			if r1 < acc:
				var r2 := _hash01(hx, hy, hz, 2)
				var sc := lerpf(float(e[3]), float(e[4]), r2)
				var pb := _basis_from_up(up).rotated(up, r2 * TAU).scaled(Vector3.ONE * sc)
				var tint: Color = e[2]
				var v := 0.85 + _hash01(hx, hy, hz, 4) * 0.3
				_push(flora[fk], pb, lv - up * 0.25 * sc, Color(tint.r * v, tint.g * v, tint.b * v, 0.0))
				placed = true
				break
		if placed:
			continue
		# --- rocks and boulders
		if rock_d > 0.0 and slope > 0.5 and r1 > 1.0 - rock_d * area:
			var r3 := _hash01(hx, hy, hz, 3)
			var r4 := _hash01(hx, hy, hz, 4)
			var rb := _basis_from_up(nrm.lerp(up, 0.4).normalized()).rotated(nrm, r3 * TAU)
			var sx := 0.5 + r3 * 1.6
			rb = Basis(rb.x * sx, rb.y * (0.45 + r4 * 0.8), rb.z * (0.6 + r4 * 1.3))
			var rv := 0.85 + r4 * 0.3
			_push(flora[Flora.ROCK], rb, lv - nrm * 0.25, Color(rock_t.r * rv, rock_t.g * rv, rock_t.b * rv, 0.0))
	result["flora"] = flora


## Simple collision shapes for solid flora and rocks (grass, flowers, bushes and glowing fungi stay
## walk-through). Each entry: [type (0 cylinder, 1 box, 2 sphere), Transform3D (orthonormal, at the
## shape center), size (cylinder: radius, height; box: half extents; sphere: r)].
func _colliders(result: Dictionary) -> Array:
	var out: Array = []
	var flora: Array = result["flora"]
	for k in flora.size():
		var spec: Array = COLLIDE.get(k, [])
		if spec.is_empty() and k != Flora.ROCK and k != Flora.CRYSTAL_CLUSTER:
			continue
		var buf: PackedFloat32Array = flora[k]
		for i in range(0, buf.size(), FLORA_STRIDE):
			var b := Basis(Vector3(buf[i], buf[i + 4], buf[i + 8]), Vector3(buf[i + 1], buf[i + 5], buf[i + 9]),
					Vector3(buf[i + 2], buf[i + 6], buf[i + 10]))
			var o := Vector3(buf[i + 3], buf[i + 7], buf[i + 11])
			var ob := b.orthonormalized()
			if k == Flora.ROCK:
				var sx := b.x.length()
				var sy := b.y.length()
				var sz := b.z.length()
				if maxf(sx, sz) < 0.55:
					continue
				out.append([1, Transform3D(ob, o + b.y * 0.1), Vector3(sx * 0.85, sy * 0.6, sz * 0.85)])
				continue
			var s := b.y.length()
			if k == Flora.CRYSTAL_CLUSTER:
				if s > 0.8:
					out.append([2, Transform3D(ob, o + ob.y * (0.5 * s)), Vector3(0.45 * s, 0, 0)])
				continue
			var r: float = spec[0] * s
			var h: float = spec[1] * s
			out.append([0, Transform3D(ob, o + ob.y * (h * 0.5)), Vector3(r, h, 0)])
			if k == Flora.MUSHROOM:
				out.append([0, Transform3D(ob, o + ob.y * (5.05 * s)), Vector3(2.1 * s, 0.8 * s, 0)])
	return out


static func _push(buf: PackedFloat32Array, b: Basis, o: Vector3, col: Color) -> void:
	buf.append_array(PackedFloat32Array([b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y,
			b.x.z, b.y.z, b.z.z, o.z, col.r, col.g, col.b, col.a]))


func _quad(a: int, b: int, c: int, d: int, natural: bool) -> void:
	# Godot front faces are clockwise; "natural" order matches the expected outward normal.
	if natural:
		_idx.append(a)
		_idx.append(b)
		_idx.append(c)
		_idx.append(a)
		_idx.append(c)
		_idx.append(d)
	else:
		_idx.append(a)
		_idx.append(c)
		_idx.append(b)
		_idx.append(a)
		_idx.append(d)
		_idx.append(c)
	_edge(a, b)
	_edge(b, c)
	_edge(c, d)
	_edge(d, a)


func _edge(a: int, b: int) -> void:
	var key := (mini(a, b) << EDGE_SHIFT) | maxi(a, b)
	_edges[key] = _edges.get(key, 0) + 1


static func _basis_from_up(up: Vector3) -> Basis:
	var ref := Vector3.FORWARD if absf(up.y) > 0.9 else Vector3.UP
	var x := ref.cross(up).normalized()
	var z := x.cross(up).normalized()
	return Basis(x, up, z)


static func _hash01(x: int, y: int, z: int, s: int) -> float:
	var h := (x * 73856093) ^ (y * 19349663) ^ (z * 83492791) ^ (s * 2654435761)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFF) / 65535.0
