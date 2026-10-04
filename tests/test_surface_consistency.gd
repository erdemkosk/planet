extends SceneTree
## Verifies that gen.surface_height(dir) matches the density field gameplay relies on, on both
## planets: density_base must be air 2 m above and solid 2 m below the reported surface.
##   godot --headless --script res://tests/test_surface_consistency.gd

const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")


func _init() -> void:
	var all_ok := true
	for preset: String in Bodies.preset_names():
		var cfg := Bodies.config(preset)
		var g := TerrainGen.new(int(cfg["seed"]), cfg)
		var rng := RandomNumberGenerator.new()
		rng.seed = 99
		var bad_above := 0
		var bad_below := 0
		var worst := ""
		for i in 4000:
			var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var h := g.surface_height(d)
			var r := g.radius + h
			if g.density_base(d * (r + 2.0)) <= 0.0:
				bad_above += 1
				worst = "solid 2 m above surface at %s (h %.1f)" % [d, h]
			if g.density_base(d * (r - 2.0)) >= 0.0:
				bad_below += 1
				worst = "air 2 m below surface at %s (h %.1f)" % [d, h]
		print("%-6s 4000 samples: solid above %d, air below %d" % [preset, bad_above, bad_below])
		if worst != "":
			print("  e.g. ", worst)
		all_ok = all_ok and bad_above == 0 and bad_below == 0
	print("PASS" if all_ok else "FAIL")
	quit()
