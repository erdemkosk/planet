extends RefCounted
## Static trajectory helpers for anything fired across the planets (cannon previews, the AI rival's
## aiming, shells).
##
##   var r := Ballistics.predict(from, vel)            # {} or {"position", "normal", "time", "body"}
##   var r := Ballistics.trace(from, vel)              # the same + "points" (PackedVector3Array)
##   var v := Ballistics.solve(from, target, speed)    # launch velocity whose impact lands nearest
##   var r := Ballistics.intercept(from, speed, p, v, a, dir)  # lead a moving target (flak)
##
## Integrates under Game.gravity_at (the summed pull of both planets) with the same update as a
## flying shell (scripts/war/shell.gd: p += v dt + g dt²/2, v += g dt) and tests every step
## against the planets' density field (planet.gd raycast_density, fast march), so it also works
## where the far planet has no collision shapes. With use_physics the step is also tested against
## physics bodies (structures, characters, near terrain); `exclude` are RIDs it ignores.

const Bodies := preload("res://scripts/planet/bodies.gd")


static func predict(from: Vector3, vel: Vector3, max_time := 60.0, dt := 0.05, exclude: Array = [],
		use_physics := false, world: World3D = null) -> Dictionary:
	return _run(from, vel, max_time, dt, exclude, use_physics, world, false)


## Like predict(), plus "points": the sampled path (every step), for drawing the arc. A miss
## returns {"points": ...} without "position".
static func trace(from: Vector3, vel: Vector3, max_time := 60.0, dt := 0.05) -> Dictionary:
	return _run(from, vel, max_time, dt, [], false, null, true)


static func _run(from: Vector3, vel: Vector3, max_time: float, dt: float, exclude: Array, use_physics: bool,
		world: World3D, keep_points: bool) -> Dictionary:
	var p := from
	var v := vel
	var t := 0.0
	var pts := PackedVector3Array()
	if keep_points:
		pts.append(p)
	var space: PhysicsDirectSpaceState3D = world.direct_space_state if (use_physics and world != null) else null
	while t < max_time:
		var g: Vector3 = Game.gravity_at(p)
		var np := p + v * dt + g * (dt * dt * 0.5)
		v += g * dt
		t += dt
		var hit := segment_hit(p, np, space, exclude)
		if not hit.is_empty():
			hit["time"] = t
			if keep_points:
				pts.append(hit["position"])
				hit["points"] = pts
			return hit
		p = np
		if keep_points:
			pts.append(p)
	return {"points": pts} if keep_points else {}


## Next position of a free-flying shell after dt (uses the gravity at the current position).
static func step(p: Vector3, v: Vector3, dt: float) -> Vector3:
	return p + v * dt + Game.gravity_at(p) * (dt * dt * 0.5)


## The first thing the segment a -> b hits: a planet's (edited) ground, or with `space` a physics
## body. {} or {"position", "normal", "body"} (body: the planet node or the collider).
static func segment_hit(a: Vector3, b: Vector3, space: PhysicsDirectSpaceState3D = null, exclude: Array = []) -> Dictionary:
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(a, b, 1 | 2 | 4 | 8, exclude)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			return {"position": hit["position"], "normal": hit["normal"], "body": hit["collider"]}
	var seg := a.distance_to(b)
	for pb in Bodies.all():
		if not is_instance_valid(pb):
			continue
		# Cheap reject: only segments that come near this planet's terrain shell.
		var c: Vector3 = (pb as Node3D).global_position
		var reach: float = float(pb.radius) + float(pb.max_height) + 4.0
		if minf(a.distance_to(c), b.distance_to(c)) > reach + seg:
			continue
		var h: Dictionary = pb.raycast_density(a, b, 1.5, true)
		if not h.is_empty():
			return {"position": h["position"], "normal": h["normal"], "body": pb}
	return {}


## Launch velocity to send a shot from `from` to `target` at `speed`: tries a spread of elevation
## angles in the plane of (target - from) and the local up and returns the velocity whose impact
## lands closest (Vector3.ZERO if none lands). Costly (dozens of simulations): the AI uses its own
## incremental version (scripts/war/ai_rival.gd) spread over frames.
static func solve(from: Vector3, target: Vector3, speed: float, lob := false, max_time := 90.0) -> Vector3:
	var best := Vector3.ZERO
	var best_d := INF
	for i in 24:
		var v := launch_vector(from, target, speed, lerpf(5.0, 85.0, float(i) / 23.0), lob)
		var r := predict(from, v, max_time, 0.1)
		if r.is_empty():
			continue
		var d := (r["position"] as Vector3).distance_to(target)
		if d < best_d:
			best_d = d
			best = v
	return best


## Firing solution against a MOVING target (flak, scripts/war/flak.gd): the launch direction for a
## round at `speed` from `from` that passes closest to a target predicted as
## tgt_pos + tgt_vel t + tgt_acc t²/2. Shooting method: each pass simulates the round (same update
## as a shell, ground ignored), finds the closest approach and turns the direction by miss / (speed
## t). Warm-start with the previous `dir` (one pass per frame is enough while tracking).
## Returns {"dir": the corrected direction, "time": s to the closest approach, "miss": m}.
static func intercept(from: Vector3, speed: float, tgt_pos: Vector3, tgt_vel: Vector3, tgt_acc: Vector3,
		dir := Vector3.ZERO, passes := 1, max_time := 7.0, dt := 0.08) -> Dictionary:
	if dir.length_squared() < 0.5:
		var t0 := from.distance_to(tgt_pos) / maxf(speed, 1.0)
		dir = (tgt_pos + tgt_vel * t0 + tgt_acc * (0.5 * t0 * t0) - from).normalized()
	var out := {"dir": dir, "time": 0.0, "miss": INF}
	for k in passes:
		var p := from
		var v := dir * speed
		var t := 0.0
		var best_d := INF
		var best_t := 0.0
		var best_m := Vector3.ZERO
		var rel_a := p - tgt_pos
		while t < max_time:
			var g: Vector3 = Game.gravity_at(p)
			p += v * dt + g * (dt * dt * 0.5)
			v += g * dt
			t += dt
			var rel_b := p - (tgt_pos + tgt_vel * t + tgt_acc * (0.5 * t * t))
			# Closest approach within this step (relative motion taken as linear).
			var seg := rel_b - rel_a
			var u := 0.0
			var ll := seg.length_squared()
			if ll > 1e-6:
				u = clampf(-rel_a.dot(seg) / ll, 0.0, 1.0)
			var rel := rel_a + seg * u
			var d := rel.length()
			if d < best_d:
				best_d = d
				best_t = t - dt * (1.0 - u)
				best_m = -rel
			elif d > best_d + 40.0:
				break                        # past the closest approach
			rel_a = rel_b
		out = {"dir": dir, "time": best_t, "miss": best_d}
		# Turn the launch direction toward the miss (a turn δ moves the round ~speed·t·δ at t).
		var corr := best_m / maxf(speed * maxf(best_t, 0.05), 1.0)
		corr -= dir * corr.dot(dir)
		dir = (dir + corr * 0.9).normalized()
		out["dir"] = dir
	return out


## Velocity at `elev_deg` above the local horizon of `from`, heading toward `target`.
static func launch_vector(from: Vector3, target: Vector3, speed: float, elev_deg: float, lob := false) -> Vector3:
	var b: Node3D = Bodies.dominant(from)
	var up: Vector3 = (from - b.global_position).normalized() if b != null else Vector3.UP
	var to := target - from
	var flat := to - up * to.dot(up)
	if flat.length_squared() < 1e-4:
		flat = up.cross(Vector3.RIGHT)
	var fwd := flat.normalized()
	var ang := deg_to_rad(elev_deg)
	if lob:
		ang = deg_to_rad(90.0 - elev_deg)
	return (fwd * cos(ang) + up * sin(ang)) * speed
