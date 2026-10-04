extends SceneTree
## Sanity test for both planet presets: height range, CPU chunk timing, rock counts and that
## density_base agrees with surface_height (air 2 m above the surface).
##   godot --headless --script res://tests/test_moons.gd

const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")


func _init() -> void:
	for preset: String in Bodies.preset_names():
		var cfg := Bodies.config(preset)
		var g := TerrainGen.new(int(cfg["seed"]), cfg)
		var R: float = cfg["radius"]
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var hmin := 1e9
		var hmax := -1e9
		var bad := 0
		var pools := 0
		var dirs: Array[Vector3] = []
		var t0 := Time.get_ticks_usec()
		for i in 1500:
			var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var s := g._surf(d)
			hmin = minf(hmin, s.x)
			hmax = maxf(hmax, s.x)
			if s.y > 0.5:
				pools += 1
			if s.x > 0.0 and dirs.size() < 6:
				dirs.append(d)
			if g.density_base(d * (R + s.x + 2.0)) <= 0.0:
				bad += 1
		var surf_us := (Time.get_ticks_usec() - t0) / 1500.0
		var ms := 0.0
		var n := 0
		var flora := 0
		for d in dirs:
			for lod: int in [0, 2]:
				var size := 16 << lod
				var o := Vector3i((d * (R + g.surface_height(d))).floor()) - Vector3i.ONE * (size / 2)
				o = Vector3i(o.x & ~(size - 1), o.y & ~(size - 1), o.z & ~(size - 1))
				var t1 := Time.get_ticks_usec()
				var r := g.build_chunk(o, lod, {})
				ms += (Time.get_ticks_usec() - t1) / 1000.0
				n += 1
				if r.has("flora"):
					for buf in r["flora"]:
						flora += buf.size() / TerrainGen.FLORA_STRIDE
		print("%-9s R %4.0f  h %6.1f .. %5.1f  (max_height %.0f, max_depth %.0f)  pools %.2f  solid-above %d  surf %.1f us  chunk avg %.1f ms  flora %d" % [
				preset, R, hmin, hmax, cfg["max_height"], cfg["max_depth"], pools / 1500.0, bad, surf_us, ms / maxf(n, 1), flora])
	quit()
