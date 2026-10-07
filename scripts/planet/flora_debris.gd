extends Node3D
## Short-lived physical stand-ins for vegetation and rocks whose ground was dug away, plus a generic
## dirt burst (_dirt, also handy for crater debris). planet.gd diffs a chunk's old / new flora
## instances after an edit and calls spawn_*() for the
## ones that disappeared near a recent brush stroke:
##   - trees, cacti, giant mushrooms, crystal spires: creak, tip over away from the dig (accelerating
##     like gravity), drop into the pit, thud, burst into wood chunks / leaves / dirt, then sink away
##   - bushes, grass, flowers, glow fungi: sucked into the hole, shrinking, with a dirt puff
##   - rocks, crystal clusters, ore pebbles: tumble and roll into the pit, then settle and sink
##   - torn out by a shock wave (launch_flora, the kinetic pusher): rocks fly along the blast, bounce,
##     settle; trees topple away from it
## Everything is animated by hand (no physics bodies) and capped, so it stays cheap.

const MAX_BIG := 20              # simultaneous falling trees / tumbling rocks (a ship landing in a forest)
const MAX_FX := 60               # all effects incl. small batches and particle bursts
const TREE_KINDS := [0, 1, 2, 3, 4, 5, 6, 13]
const SMALL_KINDS := [7, 9, 10, 12]
const TREE_HEIGHT := {0: 6.0, 1: 6.0, 2: 7.5, 3: 12.0, 4: 3.2, 5: 4.5, 6: 5.2, 13: 6.5}
const SOIL := Color(0.36, 0.25, 0.15)
const BARK := Color(0.33, 0.23, 0.15)

var planet: Node3D               # owning Planet (for flora meshes and body center)
var _fx: Array = []
var _big := 0
var _rng := RandomNumberGenerator.new()
var _chunk_mat: StandardMaterial3D
var _chunk_mesh: SphereMesh
var _wood_mesh: BoxMesh
var _leaf_mesh: QuadMesh


func _ready() -> void:
	top_level = true
	_rng.randomize()
	_chunk_mat = StandardMaterial3D.new()
	_chunk_mat.vertex_color_use_as_albedo = true
	_chunk_mat.roughness = 0.95
	# Dirt clods: small faceted lumps (a coarse sphere) instead of crisp cubes.
	_chunk_mesh = SphereMesh.new()
	_chunk_mesh.radius = 0.065
	_chunk_mesh.height = 0.11
	_chunk_mesh.radial_segments = 5
	_chunk_mesh.rings = 3
	_chunk_mesh.material = _chunk_mat
	_leaf_mesh = QuadMesh.new()
	_leaf_mesh.size = Vector2(0.42, 0.3)
	_wood_mesh = BoxMesh.new()
	_wood_mesh.size = Vector3(0.22, 0.22, 0.5)
	_wood_mesh.material = _chunk_mat
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.vertex_color_use_as_albedo = true
	leaf_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	leaf_mat.roughness = 0.9
	_leaf_mesh.material = leaf_mat


func active_count() -> int:
	return _fx.size()


## kind = TerrainGen.Flora value; xf = world transform of the instance (basis carries its scale);
## tint = per-instance custom data; dig = world center of the brush that removed its ground.
func spawn_flora(kind: int, mesh: Mesh, xf: Transform3D, tint: Color, dig: Vector3, dig_radius: float) -> void:
	if _fx.size() >= MAX_FX:
		return
	var up: Vector3 = (xf.origin - planet.global_position).normalized()
	if kind in TREE_KINDS:
		if _big >= MAX_BIG:
			_dirt(xf.origin, up, 14, 1.0)
			return
		_spawn_tree(kind, mesh, xf, tint, dig, dig_radius, up)
	elif kind in SMALL_KINDS:
		_spawn_small(mesh, [xf], [tint], dig, up)
	else:
		if _big >= MAX_BIG:
			return
		_spawn_rock(mesh, xf, tint, dig, up, true)


## Several small plants of one kind at once (one node, one dirt puff).
func spawn_small_batch(mesh: Mesh, xfs: Array, tints: Array, dig: Vector3) -> void:
	if _fx.size() >= MAX_FX or xfs.is_empty():
		return
	var up: Vector3 = (xfs[0].origin - planet.global_position).normalized()
	_spawn_small(mesh, xfs, tints, dig, up)


## Torn out by a shock wave (planet.add_push_zone, the kinetic pusher): rocks, crystal clusters and
## ore fly off along `vel` (m/s, world) with a tumble, arc under the planet's gravity, bounce once
## on the ground and settle / sink; trees topple away along the blast; small plants are whisked
## away. Capped like the rest.
func launch_flora(kind: int, mesh: Mesh, xf: Transform3D, tint: Color, vel: Vector3) -> void:
	if _fx.size() >= MAX_FX:
		return
	var up: Vector3 = (xf.origin - planet.global_position).normalized()
	var flat := vel - up * vel.dot(up)
	if kind in TREE_KINDS:
		if _big >= MAX_BIG:
			_dirt(xf.origin, up, 14, 1.4)
			return
		# Topples away from the blast (the "dig" point behind it), dropping a little.
		var behind := xf.origin - (flat.normalized() if flat.length_squared() > 0.01 else up.cross(Vector3.RIGHT)) * 3.0
		_spawn_tree(kind, mesh, xf, tint, behind, 1.6, up)
		return
	if kind in SMALL_KINDS:
		_spawn_small(mesh, [xf], [tint], xf.origin + flat * 0.25, up)
		return
	if _big >= MAX_BIG:
		_dirt(xf.origin, up, 10, 1.6)
		return
	var node := _instance(mesh, [xf], [tint], true)
	node.global_transform = xf
	var v := vel * _rng.randf_range(0.75, 1.1) + up * _rng.randf_range(1.0, 3.0)
	var axis := up.cross(flat.normalized() if flat.length_squared() > 0.01 else Vector3.RIGHT)
	if axis.length_squared() < 1e-4:
		axis = Vector3.RIGHT
	_fx.append({"type": "fly", "node": node, "t": 0.0, "pos": xf.origin, "basis": xf.basis, "vel": v,
			"spin_axis": (axis.normalized() + Vector3(_rng.randf_range(-0.3, 0.3), _rng.randf_range(-0.3, 0.3), 0.0)).normalized(),
			"spin": 0.0, "spin_rate": _rng.randf_range(6.0, 13.0), "bounces": 0, "rest_t": -1.0})
	_big += 1
	_dirt(xf.origin, up, 12, 1.4)
	_sound("mine", -10.0, _rng.randf_range(0.5, 0.65), xf.origin)


func spawn_ore(mesh: Mesh, xf: Transform3D, dig: Vector3) -> void:
	if _fx.size() >= MAX_FX or _big >= MAX_BIG:
		return
	var up: Vector3 = (xf.origin - planet.global_position).normalized()
	_spawn_rock(mesh, xf, Color(1, 1, 1, 0), dig, up, false)


# ------------------------------------------------------------------------------------------

func _instance(mesh: Mesh, xfs: Array, tints: Array, shadow: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, Transform3D.IDENTITY)
		mm.set_instance_custom_data(i, tints[i] if i < tints.size() else Color(1, 1, 1, 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


func _away(up: Vector3, from: Vector3, to: Vector3) -> Vector3:
	var a := to - from
	a -= up * a.dot(up)
	if a.length_squared() < 0.01:
		a = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	return a.normalized()


func _spawn_tree(kind: int, mesh: Mesh, xf: Transform3D, tint: Color, dig: Vector3, dig_radius: float, up: Vector3) -> void:
	var node := _instance(mesh, [xf], [tint], true)
	node.global_transform = xf
	var away := _away(up, dig, xf.origin)
	var s := xf.basis.y.length()
	var height: float = TREE_HEIGHT.get(kind, 5.0) * s
	# The roots slide into the hole a little; bigger digs drop them further.
	var drop := clampf(dig_radius * 0.5, 0.4, 2.0) * (1.0 - clampf(dig.distance_to(xf.origin) / (dig_radius + 3.0), 0.0, 1.0))
	_fx.append({"type": "tree", "node": node, "t": 0.0, "basis": xf.basis, "pivot": xf.origin,
			"axis": up.cross(away).normalized(), "up": up, "away": away, "height": height, "drop": drop,
			"fall": clampf(sqrt(height) * 0.62, 1.0, 2.2), "hit": false, "tint": tint, "kind": kind})
	_big += 1
	_sound("whoosh", -16.0, 0.45, xf.origin)
	_sound("explosion_crunch", -20.0, 1.7, xf.origin)
	_dirt(xf.origin, up, 12, 0.8)


func _spawn_small(mesh: Mesh, xfs: Array, tints: Array, dig: Vector3, up: Vector3) -> void:
	var node := _instance(mesh, xfs, tints, false)
	node.global_transform = Transform3D.IDENTITY
	var starts: Array = []
	var centroid := Vector3.ZERO
	for xf: Transform3D in xfs:
		starts.append(xf)
		centroid += xf.origin
	centroid /= xfs.size()
	var target := dig - up * 0.5
	_fx.append({"type": "small", "node": node, "t": 0.0, "starts": starts, "target": target, "up": up,
			"dur": _rng.randf_range(0.55, 0.85)})
	_dirt(centroid, up, 6 + mini(xfs.size(), 10), 0.6)
	_sound("step", -14.0, _rng.randf_range(0.8, 1.0), centroid)


func _spawn_rock(mesh: Mesh, xf: Transform3D, tint: Color, dig: Vector3, up: Vector3, is_flora: bool) -> void:
	var node := _instance(mesh, [xf], [tint], true)
	node.global_transform = xf
	var inward := _away(up, xf.origin, dig)
	var vel := inward * _rng.randf_range(1.2, 2.4) + up * _rng.randf_range(0.6, 1.4)
	var spin_axis := up.cross(inward).normalized()
	_fx.append({"type": "rock", "node": node, "t": 0.0, "pos": xf.origin, "basis": xf.basis, "vel": vel,
			"up": up, "spin_axis": spin_axis, "spin": 0.0, "spin_rate": _rng.randf_range(3.0, 6.0),
			"floor": (dig - xf.origin).dot(up) - 0.3, "landed": false, "is_flora": is_flora})
	_big += 1
	_sound("mine", -14.0, _rng.randf_range(0.55, 0.75), xf.origin)


## One-shot burst of dirt clods (or wood chunks / leaves with a color) flying out and falling back.
func _dirt(pos: Vector3, up: Vector3, amount: int, strength: float, color := SOIL, mesh: Mesh = null,
		lifetime := 1.1) -> void:
	if _fx.size() >= MAX_FX:
		return
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = amount
	p.lifetime = lifetime
	p.explosiveness = 0.92
	p.mesh = mesh if mesh != null else _chunk_mesh
	p.direction = up
	p.spread = 55.0
	p.initial_velocity_min = 1.5 * strength
	p.initial_velocity_max = 4.0 * strength
	p.gravity = -up * 9.0
	p.damping_min = 0.5
	p.damping_max = 1.5
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.6
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	p.particle_flag_rotate_y = true
	p.color = color
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(0.8, 0.8, 0.8, 1))
	p.color_ramp = ramp
	add_child(p)
	p.global_position = pos + up * 0.2
	p.emitting = true
	_fx.append({"type": "burst", "node": p, "t": 0.0, "dur": lifetime + 0.3})


func _sound(name: String, vol: float, pitch: float, pos: Vector3) -> void:
	# The Game autoload is looked up at runtime so planet.gd also works in plain SceneTree tests.
	var game := get_node_or_null("/root/Game")
	var sfx = game.get("sfx") if game else null
	if sfx == null:
		return
	var cam := get_viewport().get_camera_3d()
	var d := cam.global_position.distance_to(pos) if cam else 0.0
	if d > 70.0:
		return
	sfx.play(name, vol - d * 0.35, pitch)


func _process(delta: float) -> void:
	if _fx.is_empty():
		return
	var i := 0
	while i < _fx.size():
		var e: Dictionary = _fx[i]
		e["t"] = float(e["t"]) + delta
		var done := false
		match e["type"]:
			"tree":
				done = _step_tree(e)
			"small":
				done = _step_small(e)
			"rock":
				done = _step_rock(e, delta)
			"fly":
				done = _step_fly(e, delta)
			"crush":
				done = _step_crush(e)
			_:
				done = e["t"] >= e["dur"]
		if done:
			(e["node"] as Node).queue_free()
			if e["type"] == "tree" or e["type"] == "rock" or e["type"] == "fly":
				_big -= 1
			_fx.remove_at(i)
		else:
			i += 1


func _step_tree(e: Dictionary) -> bool:
	var t: float = e["t"]
	var fall: float = e["fall"]
	var up: Vector3 = e["up"]
	var node: MultiMeshInstance3D = e["node"]
	var angle: float
	if t < fall:
		var k := t / fall
		angle = (PI * 0.5 - 0.1) * k * k                     # accelerating like a real topple
	else:
		var b := t - fall                                        # small bounce on impact
		angle = PI * 0.5 - 0.1 - 0.09 * exp(-b * 7.0) * sin(b * 18.0)
		if not e["hit"]:
			e["hit"] = true
			_impact(e)
	var sink := float(e["drop"]) * smoothstep(0.0, fall * 0.8, t)
	var settle := smoothstep(fall + 0.9, fall + 2.6, t)
	sink += settle * 1.6
	var basis: Basis = (e["basis"] as Basis)
	var rot := Basis(e["axis"], angle) * basis
	node.global_transform = Transform3D(rot.scaled(Vector3.ONE * (1.0 - settle * 0.75)) if settle > 0.0 else rot,
			(e["pivot"] as Vector3) - up * sink)
	return t > fall + 2.7


func _impact(e: Dictionary) -> void:
	var up: Vector3 = e["up"]
	var away: Vector3 = e["away"]
	var h: float = e["height"]
	var crown: Vector3 = (e["pivot"] as Vector3) + away * h * 0.65 - up * float(e["drop"])
	var tint: Color = e["tint"]
	var kind: int = e["kind"]
	_sound("step", -2.0, 0.42, crown)
	_sound("mine", -12.0, 0.5, crown)
	# Breaks up: wood / body chunks, then leaves or shards, then dirt where it lands.
	var body_col := BARK if kind in [0, 1, 2, 3, 5] else Color(tint.r, tint.g, tint.b)
	_dirt(crown, up, 12, 1.1, body_col, _wood_mesh, 1.6)
	if kind in [0, 1, 2, 3]:
		var leaf := Color(tint.r * 0.9, tint.g * 0.9, tint.b * 0.9)
		_dirt(crown + up * 0.8, up, 36, 0.8, leaf, _leaf_mesh, 2.2)
	_dirt((e["pivot"] as Vector3) + away * h * 0.3, up, 22, 1.2)


func _step_small(e: Dictionary) -> bool:
	var t: float = e["t"]
	var dur: float = e["dur"]
	var k := clampf(t / dur, 0.0, 1.0)
	var ease := k * k
	var node: MultiMeshInstance3D = e["node"]
	var target: Vector3 = e["target"]
	var up: Vector3 = e["up"]
	var starts: Array = e["starts"]
	for i in starts.size():
		var s: Transform3D = starts[i]
		var pos := s.origin.lerp(target, ease * 0.75) - up * ease * 0.6
		var b := Basis(up, k * 2.5) * s.basis
		node.multimesh.set_instance_transform(i, Transform3D(b.scaled(Vector3.ONE * maxf(1.0 - ease, 0.02)), pos))
	return t >= dur


func _step_rock(e: Dictionary, dt: float) -> bool:
	var t: float = e["t"]
	var up: Vector3 = e["up"]
	var node: MultiMeshInstance3D = e["node"]
	var pos: Vector3 = e["pos"]
	if not e["landed"]:
		var vel: Vector3 = e["vel"]
		vel -= up * 9.0 * dt
		pos += vel * dt
		e["vel"] = vel
		e["spin"] = float(e["spin"]) + float(e["spin_rate"]) * dt
		# Hits the pit floor (approx. the brush center height) or rolls for at most 1.4 s.
		var h := (pos - (e["pos"] as Vector3)).dot(up)
		if (h < float(e["floor"]) and vel.dot(up) < 0.0) or t > 1.4:
			e["landed"] = true
			_sound("impact_light", -16.0, 0.45, pos)
			_dirt(pos, up, 8, 0.5)
		e["pos"] = pos
	var settle := smoothstep(1.6, 3.2, t)
	var b := Basis(e["spin_axis"], e["spin"]) * (e["basis"] as Basis)
	node.global_transform = Transform3D(b.scaled(Vector3.ONE * (1.0 - settle * 0.85)) if settle > 0.0 else b,
			pos - up * settle * 0.8)
	return t > 3.3


## A thrown rock: the planet's own gravity, the ground from its density field (works far from any
## collider), one or two bounces, then it rests, sinks and shrinks away (~5 s at most).
func _step_fly(e: Dictionary, dt: float) -> bool:
	var t: float = e["t"]
	var node: MultiMeshInstance3D = e["node"]
	var pos: Vector3 = e["pos"]
	var c: Vector3 = planet.global_position
	var up := (pos - c).normalized()
	var rest_t: float = e["rest_t"]
	if rest_t < 0.0:
		var vel: Vector3 = e["vel"]
		var dist := pos.distance_to(c)
		var g := float(planet.gravity_accel(dist)) if planet.has_method("gravity_accel") else 9.0
		vel -= up * g * dt
		var np := pos + vel * dt
		e["spin"] = float(e["spin"]) + float(e["spin_rate"]) * dt
		if planet.has_method("density_fast") and float(planet.density_fast(np)) < 0.0 and vel.dot(up) < 0.0:
			var b := int(e["bounces"])
			var speed := vel.length()
			if b < 2 and speed > 3.0:
				# Bounce: lose most of the speed into the ground, keep some along it.
				var vn := up * vel.dot(up)
				vel = (vel - vn) * 0.5 - vn * 0.3
				e["spin_rate"] = float(e["spin_rate"]) * 0.6
				e["bounces"] = b + 1
				_sound("impact_light", -12.0 - b * 4.0, 0.5, np)
				_dirt(pos, up, 8, 0.7)
				np = pos
			else:
				e["rest_t"] = t
				_sound("impact_light", -16.0, 0.42, np)
				np = pos
		pos = np
		e["vel"] = vel
		e["pos"] = pos
		if t > 6.0:
			e["rest_t"] = t
	rest_t = float(e["rest_t"])
	var settle := 0.0
	if rest_t >= 0.0:
		settle = smoothstep(rest_t + 1.2, rest_t + 2.6, t)
	var b2 := Basis(e["spin_axis"], e["spin"]) * (e["basis"] as Basis)
	node.global_transform = Transform3D(b2.scaled(Vector3.ONE * (1.0 - settle * 0.85)) if settle > 0.0 else b2,
			pos - up * settle * 0.8)
	return rest_t >= 0.0 and t > rest_t + 2.7


## Crushed by a ship coming down (planet.gd fell_flora): bushes, grass, flowers and fungi are pressed
## flat away from it and fade; rocks and crystal clusters are pushed into the ground.
func spawn_crush(kind: int, mesh: Mesh, xfs: Array, tints: Array, from: Vector3) -> void:
	if _fx.size() >= MAX_FX or xfs.is_empty():
		return
	var up: Vector3 = ((xfs[0] as Transform3D).origin - planet.global_position).normalized()
	var node := _instance(mesh, xfs, tints, false)
	node.global_transform = Transform3D.IDENTITY
	var starts: Array = []
	var centroid := Vector3.ZERO
	for xf: Transform3D in xfs:
		starts.append(xf)
		centroid += xf.origin
	centroid /= xfs.size()
	var rock := kind == 8 or kind == 11
	_fx.append({"type": "crush", "node": node, "t": 0.0, "starts": starts, "up": up, "from": from, "rock": rock,
			"dur": _rng.randf_range(0.35, 0.5) if not rock else 0.7})
	_dirt(centroid, up, 6 + mini(xfs.size(), 12), 0.7)
	_sound("mine" if rock else "step", -12.0 if rock else -10.0, 0.5 if rock else _rng.randf_range(0.7, 0.85), centroid)


func _step_crush(e: Dictionary) -> bool:
	var t: float = e["t"]
	var dur: float = e["dur"]
	var k := clampf(t / dur, 0.0, 1.0)
	var ease := 1.0 - (1.0 - k) * (1.0 - k)
	var fade := clampf((t - dur - 0.8) / 0.6, 0.0, 1.0)
	var node: MultiMeshInstance3D = e["node"]
	var up: Vector3 = e["up"]
	var starts: Array = e["starts"]
	for i in starts.size():
		var s: Transform3D = starts[i]
		var b: Basis
		var pos: Vector3
		if bool(e["rock"]):
			var depth := s.basis.y.length() * 1.1 + 0.2
			b = s.basis
			pos = s.origin - up * depth * ease
		else:
			var away := _away(up, e["from"], s.origin)
			var axis := up.cross(away).normalized()
			b = Basis(axis, 1.35 * ease) * s.basis
			pos = s.origin - up * 0.06 * ease
		node.multimesh.set_instance_transform(i, Transform3D(b.scaled(Vector3.ONE * maxf(1.0 - fade, 0.02)), pos))
	return t >= dur + 1.4
