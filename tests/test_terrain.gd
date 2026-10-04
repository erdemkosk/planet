extends SceneTree
## Headless sanity test of the planet generator (home preset): height range, chunk build timing per
## LOD, triangle winding vs. gradient normals, the empty-chunk early-out and a dug chunk's strata.
##   godot --headless --script res://tests/test_terrain.gd

const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")


func _init() -> void:
	var cfg := Bodies.config("home")
	var g := TerrainGen.new(int(cfg["seed"]), cfg)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var hmin := 1e9
	var hmax := -1e9
	var dirs: Array[Vector3] = []
	for i in 6000:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var h := g.surface_height(d)
		hmin = minf(hmin, h)
		hmax = maxf(hmax, h)
		if dirs.size() < 24:
			dirs.append(d)
	print("height range: %.1f .. %.1f (max_height %.0f)" % [hmin, hmax, g.max_height])

	# Chunk timing on the surface.
	var per_lod := {0: [], 1: [], 2: [], 3: []}
	var winding_bad := 0
	var rocks := 0
	for d in dirs:
		var surf := d * (g.radius + g.surface_height(d))
		for lod: int in per_lod:
			var size := 16 * (1 << lod)
			var o := Vector3i((surf / TerrainGen.VOXEL).floor()) - Vector3i.ONE * (size / 2)
			o = Vector3i(o.x & ~(size - 1), o.y & ~(size - 1), o.z & ~(size - 1))
			var t0 := Time.get_ticks_usec()
			var r := g.build_chunk(o, lod, {})
			per_lod[lod].append((Time.get_ticks_usec() - t0) / 1000.0)
			if r["empty"]:
				continue
			winding_bad += _winding_bad(r)
			if r.has("flora"):
				rocks += (r["flora"][TerrainGen.Flora.ROCK] as PackedFloat32Array).size() / TerrainGen.FLORA_STRIDE
	for lod in per_lod:
		var arr: Array = per_lod[lod]
		var s := 0.0
		var mx := 0.0
		for v in arr:
			s += v
			mx = maxf(mx, v)
		print("lod %d: avg %.2f ms  max %.2f ms  (%d chunks)" % [lod, s / maxf(arr.size(), 1), mx, arr.size()])
	print("bad windings: %d  rocks: %d" % [winding_bad, rocks])

	# Empty chunk early-out: a chunk well above the ground.
	var d0 := dirs[0]
	var above := Vector3i((d0 * (g.radius + g.surface_height(d0) + 40.0)).floor())
	above = Vector3i(above.x & ~15, above.y & ~15, above.z & ~15)
	var t1 := Time.get_ticks_usec()
	var re := g.build_chunk(above, 0, {})
	print("air chunk: empty=%s void=%s %.2f ms" % [re["empty"], re.get("void", false), (Time.get_ticks_usec() - t1) / 1000.0])

	# Edited chunk: dig a hole and check the strata depth attribute.
	var dd := dirs[1]
	var sp := dd * (g.radius + g.surface_height(dd))
	var o3 := Vector3i(sp.floor()) - Vector3i(8, 8, 8)
	o3 = Vector3i(o3.x & ~15, o3.y & ~15, o3.z & ~15)
	var regions := {}
	for z in range(o3.z - 16, o3.z + 33):
		for y in range(o3.y - 16, o3.y + 33):
			for x in range(o3.x - 16, o3.x + 33):
				var p := Vector3(x, y, z)
				if p.distance_to(sp) > 7.0:
					continue
				var key := Vector3i(x >> 4, y >> 4, z >> 4)
				if not regions.has(key):
					var arr := PackedFloat32Array()
					arr.resize(4096)
					arr.fill(TerrainGen.NO_EDIT)
					regions[key] = arr
				var a: PackedFloat32Array = regions[key]
				a[(x & 15) | ((y & 15) << 4) | ((z & 15) << 8)] = 4.0
	var t3 := Time.get_ticks_usec()
	var red := g.build_chunk(o3, 0, regions)
	var maxdepth := 0.0
	var dug := 0
	var uv2: PackedVector2Array = red["uv2s"]
	var cols: PackedColorArray = red["colors"]
	for i in uv2.size():
		maxdepth = maxf(maxdepth, uv2[i].x)
		if cols[i].r > 0.5:
			dug += 1
	print("dug chunk: %.2f ms, max strata depth %.1f m, dug-wall verts %d" % [(Time.get_ticks_usec() - t3) / 1000.0, maxdepth, dug])
	quit()


func _winding_bad(r: Dictionary) -> int:
	var verts: PackedVector3Array = r["verts"]
	var norms: PackedVector3Array = r["normals"]
	var idx: PackedInt32Array = r["indices"]
	if not r.has("faces"):
		return 0
	var bad := 0
	for t in r["faces"].size() / 3:
		var a := verts[idx[t * 3]]
		var b := verts[idx[t * 3 + 1]]
		var c := verts[idx[t * 3 + 2]]
		var fn := (c - a).cross(b - a)
		var vn := norms[idx[t * 3]] + norms[idx[t * 3 + 1]] + norms[idx[t * 3 + 2]]
		if fn.dot(vn) <= 0.0:
			bad += 1
	return bad
