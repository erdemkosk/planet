extends SceneTree
## Streaming benchmark: flies the planet focus (and a camera) low over the surface at 150 m/s for
## 15 s (frames paced at 60 fps) and reports planet._process() cost and how quickly full detail
## follows the camera.
##   godot --path . --script res://tests/bench_planet.gd                  (GPU density path)
##   godot --path . --script res://tests/bench_planet.gd -- --cpu-terrain  (CPU density path)

const Planet := preload("res://scripts/planet/planet.gd")
const SPEED := 150.0
const ALT := 35.0
const DT := 1.0 / 60.0

var planet
var cam: Camera3D
var phase := -1
var frame := 0
var times: Array[float] = []
var lod_at_focus: Array[int] = []
var lod_ahead: Array[int] = []
var start_usec := 0
var dir := Vector3(0.55, 0.42, 0.72).normalized()
var axis := Vector3.ZERO
var lod_usec_max := 0
var lod_usec_sum := 0
var lod_runs := 0


func _initialize() -> void:
	Engine.max_fps = 60
	cam = Camera3D.new()
	cam.far = 20000.0
	root.add_child(cam)
	planet = Planet.new()
	planet.set_process(false)
	root.add_child(planet)
	axis = dir.cross(Vector3.UP).normalized()


func _place() -> void:
	var h: float = planet.gen.surface_height(dir)
	var pos := dir * (planet.radius + maxf(h, 0.0) + ALT)
	var fwd := axis.cross(dir).normalized()
	cam.global_transform = Transform3D(Basis.looking_at(fwd - dir * 0.25, dir), pos)
	planet.focus = pos + fwd * 30.0


func _process(_delta: float) -> bool:
	if phase == -1:
		_place()
		start_usec = Time.get_ticks_usec()
		phase = 0
	var t0 := Time.get_ticks_usec()
	var before: int = planet.stat_lod_usec
	planet.stat_lod_usec = 0
	planet._process(DT)
	var us := Time.get_ticks_usec() - t0
	if phase == 0:
		if planet.build_progress() >= 0.999 or Time.get_ticks_usec() - start_usec > 30_000_000:
			print("initial load: %.2f s, chunks %d, gpu=%s" % [(Time.get_ticks_usec() - start_usec) / 1e6,
					planet.chunks.size(), planet.use_gpu])
			phase = 1
		return false
	frame += 1
	times.append(us / 1000.0)
	if planet.stat_lod_usec > 0:
		lod_usec_max = maxi(lod_usec_max, planet.stat_lod_usec)
		lod_usec_sum += planet.stat_lod_usec
		lod_runs += 1
	dir = dir.rotated(axis, -SPEED * DT / planet.radius).normalized()
	_place()
	if frame % 10 == 0:
		if planet.gen.surface_height(dir) > 2.0:     # land only (ocean columns are void chunks)
			lod_at_focus.append(_lod_under(cam.global_position - dir * (ALT + 2.0)))
		var fwd := axis.cross(dir).normalized()
		var ahead := (cam.global_position + fwd * 60.0).normalized()
		if planet.gen.surface_height(ahead) > 2.0:
			lod_ahead.append(_lod_under(ahead * (planet.radius + planet.gen.surface_height(ahead) - 2.0)))
	if frame >= 900:
		_report()
		return true
	return false


func _lod_under(p: Vector3) -> int:
	var best := 99
	for k in planet.displayed:
		var size: int = 16 << k.w
		if p.x >= k.x and p.x < k.x + size and p.y >= k.y and p.y < k.y + size and p.z >= k.z and p.z < k.z + size:
			best = mini(best, k.w * 10 + (1 if planet.chunks[k].is_void else 0))
	return best


func _report() -> void:
	var s := 0.0
	var mx := 0.0
	var sorted: Array[float] = times.duplicate()
	sorted.sort()
	for v in times:
		s += v
		mx = maxf(mx, v)
	var lod_hist := {}
	for l in lod_at_focus:
		lod_hist[l] = lod_hist.get(l, 0) + 1
	print("flight %d frames at %.0f m/s: planet._process avg %.2f ms, p99 %.2f ms, max %.2f ms" % [
			times.size(), SPEED, s / times.size(), sorted[int(sorted.size() * 0.99)], mx])
	print("LOD apply (main thread): %d runs, avg %.2f ms, max %.2f ms (worker traversal last %.2f ms, wanted %d)" % [lod_runs, lod_usec_sum / 1000.0 / maxf(lod_runs, 1), lod_usec_max / 1000.0, planet.stat_visit_usec / 1000.0, planet.wanted.size()])
	var ahead_hist := {}
	for l in lod_ahead:
		ahead_hist[l] = ahead_hist.get(l, 0) + 1
	print("LOD of ground 60 m ahead (in view): ", ahead_hist)
	print("request->built latency:", _latency())
	print("LOD under the camera (samples): ", lod_hist, "  chunks: ", planet.chunks.size(),
			"  displayed: ", planet.displayed.size(), "  applied: ", planet.stat_applied)
	var per := {}
	for k in planet.displayed:
		var c = planet.chunks[k]
		var e: Array = per.get(k.w, [0, 0, 0])
		e[0] += 1
		if c.is_void:
			e[1] += 1
		elif c.mesh_inst == null or c.mesh_inst.mesh == null:
			e[2] += 1
		per[k.w] = e
	print("displayed per lod [count, void, empty-not-void]: ", per)
	print("main-thread totals: mesh %.0f ms, collision %.0f ms (%d shapes), multimesh %.0f ms over %d applied; pending now %d" % [
			planet.stat_mesh_usec / 1000.0, planet.stat_col_usec / 1000.0, planet.stat_shapes, planet.stat_mm_usec / 1000.0, planet.stat_applied, _pending_count()])


func _pending_count() -> int:
	var n := 0
	for l in planet._pending:
		n += l.size()
	return n


func _latency() -> String:
	var s := ""
	for l in 8:
		if planet.stat_lat_n[l] > 0:
			s += "  lod%d %.0f ms" % [l, planet.stat_lat_sum[l] / 1000.0 / planet.stat_lat_n[l]]
	return s + "  (max_jobs %d)" % planet.max_jobs
