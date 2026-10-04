extends SceneTree
## Loads the home planet around a surface spot and checks that rocks have collision: a horizontal
## ray aimed at a rock collider must hit the chunk's flora body on the terrain layer.
##   godot --headless --script res://tests/test_flora_collision.gd

const Planet := preload("res://scripts/planet/planet.gd")
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")

var planet
var cam: Camera3D
var frame := 0
var spot := Vector3.ZERO


func _initialize() -> void:
	cam = Camera3D.new()
	root.add_child(cam)
	planet = Planet.new()
	planet.set_process(false)
	root.add_child(planet)


func _process(_d: float) -> bool:
	frame += 1
	if frame == 1:
		var g: TerrainGen = planet.gen
		var d := Vector3(0.55, 0.42, 0.72).normalized()
		spot = d * (g.radius + g.surface_height(d) + 2.0)
		cam.global_position = spot
		planet.focus = spot
	planet._process(1.0 / 60.0)
	if frame < 20 or (planet.build_progress() < 0.999 and frame < 4000):
		return false
	if frame < 4060:
		return false     # let the budgeted collision queue catch up
	var bodies := 0
	var shapes := 0
	var hits := 0
	var tries := 0
	var space := root.get_world_3d().direct_space_state
	for k in planet.displayed:
		var c = planet.chunks[k]
		if c.flora_body == null:
			continue
		bodies += 1
		var fb: StaticBody3D = c.flora_body
		for o in fb.get_shape_owners():
			shapes += 1
			if tries >= 30:
				continue
			var xf: Transform3D = fb.global_transform * fb.shape_owner_get_transform(o)
			var up := xf.basis.y
			var side := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
			var q := PhysicsRayQueryParameters3D.create(xf.origin + side * 4.0, xf.origin - side * 4.0, 1)
			var hit := space.intersect_ray(q)
			tries += 1
			if not hit.is_empty() and hit["collider"] == fb:
				hits += 1
	print("flora collision: %d bodies, %d shapes, ray hits %d / %d" % [bodies, shapes, hits, tries])
	print("PASS" if bodies > 0 and hits >= tries * 0.8 else "FAIL")
	return true
