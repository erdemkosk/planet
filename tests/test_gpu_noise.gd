extends SceneTree
## Compares the GLSL OpenSimplex2S port with Godot's FastNoiseLite on many random points.
##   godot --path . --script res://tests/test_gpu_noise.gd
const GpuDensity := preload("res://scripts/planet/gpu_density.gd")

func _init() -> void:
	var g := GpuDensity.new()
	if not g.init():
		quit()
		return
	var fnl := FastNoiseLite.new()
	fnl.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fnl.fractal_type = FastNoiseLite.FRACTAL_NONE
	var bad := 0
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for trial in 6:
		var sd := 9101 + trial * 17
		var freq := 1.0 / (40.0 + trial * 13.0)
		fnl.seed = sd
		fnl.frequency = freq
		var params := PackedFloat32Array([1.0, 9.0, 0.0, 0.0, float(sd), freq, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
		g.set_bodies(params)
		var o := Vector3i(rng.randi_range(-400, 400), rng.randi_range(-400, 400), rng.randi_range(-400, 400))
		var res := g.compute([Vector4i(o.x, o.y, o.z, 2)])
		var dens: PackedFloat32Array = res[0]
		for si in GpuDensity.SAMPLES:
			var p := Vector3(o.x + (si % 18) * 4, o.y + ((si / 18) % 18) * 4, o.z + (si / 324) * 4)
			var c := fnl.get_noise_3dv(p)
			var e := absf(c - dens[si])
			if e > 0.001:
				bad += 1
				if e > worst:
					worst = e
					print("  mismatch seed %d freq %.5f at %s cpu %.5f gpu %.5f" % [sd, freq, p, c, dens[si]])
	print("noise compare: %d bad samples of %d, worst %.5f" % [bad, 6 * GpuDensity.SAMPLES, worst])
	g.free_resources()
	quit()
