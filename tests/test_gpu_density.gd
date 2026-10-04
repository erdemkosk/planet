extends SceneTree
## GPU density self-test + timing for every body preset. Needs a rendering device (no --headless):
##   godot --path . --script res://tests/test_gpu_density.gd

const GpuDensity := preload("res://scripts/planet/gpu_density.gd")
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")


func _init() -> void:
	var g := GpuDensity.new()
	var ok := g.init()
	print("gpu init: ", ok, " ", g.error)
	if not ok:
		quit()
		return
	var params := PackedFloat32Array()
	var gens: Array = []
	var names: Array = []
	for preset: String in Bodies.preset_names():
		var cfg := Bodies.config(preset)
		params.append_array(GpuDensity.body_params(cfg))
		gens.append(TerrainGen.new(int(cfg["seed"]), cfg))
		names.append(preset)
	g.set_bodies(params)
	for i in gens.size():
		var worst := g.self_test(i, gens[i])
		print("  %-9s worst diff %.5f %s" % [names[i], worst, "OK" if worst < 0.05 else "MISMATCH"])
	# Throughput: a full batch of surface chunks + CPU meshing time from GPU data.
	var gen: TerrainGen = gens[0]
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var chunks := []
	while chunks.size() < GpuDensity.BATCH:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var o := Vector3i((d * (gen.radius + gen.surface_height(d))).floor()) - Vector3i(8, 8, 8)
		chunks.append(Vector4i(o.x & ~15, o.y & ~15, o.z & ~15, 0))
	for rep in 3:
		var t0 := Time.get_ticks_usec()
		var res := g.compute(chunks)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		print("batch of %d chunks: %.2f ms (%.3f ms/chunk)" % [chunks.size(), ms, ms / chunks.size()])
		if rep == 2:
			var dens: PackedFloat32Array = res[0]
			var flags: PackedInt32Array = res[1]
			var tm := 0.0
			var meshed := 0
			for ci in chunks.size():
				if flags[ci] != 3:
					continue
				var c: Vector4i = chunks[ci]
				var t1 := Time.get_ticks_usec()
				gen.mesh_from_density(dens.slice(ci * GpuDensity.SAMPLES, (ci + 1) * GpuDensity.SAMPLES),
						Vector3i(c.x, c.y, c.z), 0, false)
				tm += (Time.get_ticks_usec() - t1) / 1000.0
				meshed += 1
			print("CPU meshing from GPU data: %.2f ms/chunk over %d chunks" % [tm / maxf(meshed, 1), meshed])
	g.free_resources()
	quit()
