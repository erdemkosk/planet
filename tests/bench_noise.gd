extends SceneTree
## Profiles chunk generation stages: density sampling vs meshing/attributes/foliage.
## godot --headless --script res://tests/bench_noise.gd
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")

func _init() -> void:
	var g := TerrainGen.new(2024, Bodies.config("home"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var t_sample := 0.0
	var t_mesh := 0.0
	var t_noflora := 0.0
	var n := 0
	var t_surf := 0.0
	while n < 20:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var h := g.surface_height(d)
		if h < -50.0:
			continue
		var o := Vector3i((d * (g.radius + h)).floor()) - Vector3i(8, 8, 8)
		o = Vector3i(o.x & ~15, o.y & ~15, o.z & ~15)
		var t0 := Time.get_ticks_usec()
		var dens := PackedFloat32Array()
		dens.resize(18 * 18 * 18)
		var i := 0
		for z in 18:
			for y in 18:
				for x in 18:
					dens[i] = g.density_base(Vector3(o.x + x, o.y + y, o.z + z))
					i += 1
		var t1 := Time.get_ticks_usec()
		g.mesh_from_density(dens, o, 0, false)
		var t2 := Time.get_ticks_usec()
		g.mesh_from_density(dens, o, 3, false)   # lod 3: no flora, no collision (same density grid)
		var t3 := Time.get_ticks_usec()
		for k in 1000:
			g._surf(d)
		var t4 := Time.get_ticks_usec()
		t_sample += (t1 - t0) / 1000.0
		t_mesh += (t2 - t1) / 1000.0
		t_noflora += (t3 - t2) / 1000.0
		t_surf += (t4 - t3) / 1000.0
		n += 1
	print("lod0 avg: sampling %.2f ms, mesh+attrs+flora %.2f ms, mesh+attrs only %.2f ms, _surf %.2f us" % [
			t_sample / n, t_mesh / n, t_noflora / n, t_surf / n])
	quit()
