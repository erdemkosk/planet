extends Node3D
## Grenades in flight (kept as the base for the phase-2 cannonballs): ballistic flight with
## Game.gravity_at (both planets) and a little drag, a smoke trail, contact tests against the world
## and characters (group "damageable": a direct hit damages them through Game.damage_target), bounce
## with friction / come to rest / detonate, an arming distance for impact rounds (a round that hits
## closer than ARM_DIST only bounces and goes off on its back-up fuse), fuses, a blinking LED on hand
## grenades. Detonation spawns an Explosion (scripts/items/explosion.gd).
## Note for long flights between the planets: the far planet has no collision shapes (only chunks
## near the camera get them), so a cannonball needs planet.raycast_density() as its hit test there
## (see scripts/items/ballistics.gd) and a lifetime longer than the 14 s used here.

const Explosion := preload("res://scripts/items/explosion.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")
const RifleFx := preload("res://scripts/items/rifle_fx.gd")
const Rifle := preload("res://scripts/items/rifle.gd")

const MASK := 1 | 2 | 4 | 8 | 32
const ARM_DIST := 4.0
const MODE_IMPACT := 0
const MODE_BOUNCE := 1

var player                       # excluded from ray tests
var detonations := 0             # tests
var last_explosion: Node3D = null
var _list: Array = []
var _fading: Array = []          # [node, seconds left]
var _audio: Array = []
var _ai := 0
var _soft: Texture2D


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	add_to_group("grenade_sim")         # the kinetic pusher's shock wave finds the grenades here (shove)
	for i in 4:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 6.0
		p.max_distance = 80.0
		add_child(p)
		_audio.append(p)
	Explosion.prewarm()


func in_flight() -> int:
	return _list.size()


## A shock wave (scripts/items/kinetic_pusher.gd): every grenade inside the cone from `from` along
## `fwd` (half angle `cone` rad, out to `reach` m), flying or lying, gets lerp(v_near, v_far, d /
## reach) m/s along the blast (lying ones take off again). Returns how many were hit.
func shove(from: Vector3, fwd: Vector3, reach: float, cone: float, v_near: float, v_far: float) -> int:
	var n := 0
	for g in _list:
		var node: Node3D = g["node"]
		if not is_instance_valid(node):
			continue
		var to := node.global_position - from
		var d := to.length()
		if d > reach or d < 0.01:
			continue
		if acos(clampf(fwd.dot(to / d), -1.0, 1.0)) > cone + atan(0.4 / maxf(d, 0.3)):
			continue
		var dir := (to / d).lerp(fwd, 0.4).normalized()
		g["vel"] = (g["vel"] as Vector3) + dir * lerpf(v_near, v_far, clampf(d / reach, 0.0, 1.0))
		g["rest"] = false
		n += 1
	return n


## Launches a grenade. kind "40mm" or "hand"; cfg = Explosion config (+ "direct": impact damage).
func launch(pos: Vector3, vel: Vector3, kind: String, mode: int, fuse: float, cfg: Dictionary) -> void:
	var node := _make_mesh(kind)
	add_child(node)
	node.global_position = pos
	var trail := _make_trail(kind)
	add_child(trail)
	trail.global_position = pos
	trail.emitting = true
	_list.append({"node": node, "trail": trail, "vel": vel, "kind": kind, "mode": mode, "fuse": fuse,
			"dist": 0.0, "life": 14.0, "rest": false, "n": Explosion._up_at(pos), "cfg": cfg, "bounces": 0,
			"spin": Vector3(randf_range(-9, 9), randf_range(-9, 9), randf_range(-9, 9)) if kind == "hand" else Vector3.ZERO,
			"t": 0.0})


func _physics_process(delta: float) -> void:
	for i in range(_fading.size() - 1, -1, -1):
		_fading[i][1] = float(_fading[i][1]) - delta
		if float(_fading[i][1]) <= 0.0:
			(_fading[i][0] as Node).queue_free()
			_fading.remove_at(i)
	if _list.is_empty():
		return
	var space := get_world_3d().direct_space_state
	var ex: Array = []
	if player != null and is_instance_valid(player):
		ex.append(player.get_rid())
	var keep: Array = []
	for g in _list:
		var node: Node3D = g["node"]
		var p := node.global_position
		g["fuse"] = float(g["fuse"]) - delta
		g["life"] = float(g["life"]) - delta
		g["t"] = float(g["t"]) + delta
		var done := false
		if float(g["fuse"]) <= 0.0 or float(g["life"]) <= 0.0:
			_detonate(g, p, g["n"])
			continue
		if g["rest"]:
			_blink(g)
			keep.append(g)
			continue
		var v: Vector3 = g["vel"]
		v += Game.gravity_at(p) * delta
		v *= 1.0 - 0.015 * delta
		var np := p + v * delta
		var seg := np - p
		var len := seg.length()
		if len > 1e-5:
			var dir := seg / len
			var q := PhysicsRayQueryParameters3D.create(p, np, MASK, ex)
			var hit := space.intersect_ray(q)
			var hit_t := len if hit.is_empty() else p.distance_to(hit["position"])
			var armed := float(g["dist"]) + hit_t >= ARM_DIST
			var body: Node = Game.damageable_of(hit["collider"]) if not hit.is_empty() else null
			if body != null:
				# A direct hit on a character (group "damageable").
				var hp: Vector3 = hit["position"]
				var cfg: Dictionary = g["cfg"]
				var direct := float(cfg.get("direct", 0.0)) * (1.0 if armed else 0.4)
				if direct > 0.0 and not Net.is_client():     # (multiplayer: the host's replay hits)
					var src: Vector3 = player.global_position if player != null and is_instance_valid(player) else hp - dir * 10.0
					var r := Game.damage_target(body, direct, src, dir * 9.0, "", hp)
					HitFeel.inst().target_hit(body, r, direct, hp, {"big": 0.5})
				if armed or g["kind"] == "hand":
					_detonate(g, hp, -dir)
					continue
				v = v.bounce(hit["normal"]) * 0.25
				np = hp - dir * 0.08
				_clank(hp, v.length())
			elif not hit.is_empty():
				var n: Vector3 = hit["normal"]
				var hp2: Vector3 = hit["position"]
				if int(g["mode"]) == MODE_IMPACT and armed:
					_detonate(g, hp2, n)
					continue
				# Bounce: lose most of the normal speed, some of the tangential.
				var vn := n * v.dot(n)
				var vt := v - vn
				v = vt * (0.62 if g["kind"] == "hand" else 0.5) - vn * 0.32
				g["bounces"] = int(g["bounces"]) + 1
				g["n"] = n
				np = hp2 + n * 0.05
				_clank(hp2, v.length())
				if g["kind"] == "hand":
					g["spin"] = (g["spin"] as Vector3) * 0.6 + n.cross(v) * 4.0
				var up := Explosion._up_at(hp2)
				if v.length() < 1.3 and n.dot(up) > 0.5:
					v = Vector3.ZERO
					g["rest"] = true
					np = hp2 + n * (0.04 if g["kind"] == "hand" else 0.035)
			g["dist"] = float(g["dist"]) + p.distance_to(np)
		g["vel"] = v
		_place(g, np, v, delta)
		_blink(g)
		if not done:
			keep.append(g)
	_list = keep


func _place(g: Dictionary, np: Vector3, v: Vector3, delta: float) -> void:
	var node: Node3D = g["node"]
	var b := node.global_transform.basis
	if g["kind"] == "40mm":
		if v.length_squared() > 0.5:
			b = RifleFx._basis_y(v)
	else:
		var sp: Vector3 = g["spin"]
		if sp.length_squared() > 0.01 and not g["rest"]:
			b = b.rotated(sp.normalized(), sp.length() * delta).orthonormalized()
	node.global_transform = Transform3D(b, np)
	var trail: GPUParticles3D = g["trail"]
	trail.global_position = np
	if g["rest"]:
		trail.emitting = g["kind"] == "40mm"


func _blink(g: Dictionary) -> void:
	if g["kind"] != "hand":
		return
	var gn := g["node"] as Node3D
	var led = gn.get_meta("led") if gn.has_meta("led") else null   # (a null default still errors in Godot 4)
	if led is MeshInstance3D:
		var f: float = g["fuse"]
		var rate := 2.0 if f > 1.5 else 7.0
		(led as MeshInstance3D).visible = fmod(float(g["t"]) * rate, 1.0) < 0.5


func _detonate(g: Dictionary, pos: Vector3, n: Vector3) -> void:
	var node: Node3D = g["node"]
	node.visible = false
	node.queue_free()
	var trail: GPUParticles3D = g["trail"]
	trail.emitting = false
	_fading.append([trail, trail.lifetime + 0.2])
	var cfg: Dictionary = (g["cfg"] as Dictionary).duplicate()
	cfg["ground"] = _ground_color(pos, n)
	last_explosion = Explosion.spawn(pos + n * 0.1, n, cfg)
	detonations += 1


func _clank(p: Vector3, speed: float) -> void:
	if speed < 0.4:
		return
	var st := Explosion.synth("bounce")
	if st == null:
		return
	var pl: AudioStreamPlayer3D = _audio[_ai]
	_ai = (_ai + 1) % _audio.size()
	pl.stream = st
	pl.global_position = p
	pl.volume_db = lerpf(-22.0, -4.0, clampf(speed / 12.0, 0.0, 1.0))
	pl.pitch_scale = randf_range(0.85, 1.2)
	pl.play()


func _ground_color(p: Vector3, n: Vector3) -> Color:
	return Rifle.ground_color(p, n)


# =================================================================================================
# Meshes
# =================================================================================================

func _mat(c: Color, rough: float, metal: float, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	return m


func _mi(parent: Node3D, mesh: Mesh, m: Material, pos := Vector3.ZERO, b := Basis()) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.transform = Transform3D(b, pos)
	parent.add_child(mi)
	return mi


func _cyl(r0: float, r1: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r1
	c.bottom_radius = r0
	c.height = h
	c.radial_segments = 14
	c.rings = 1
	return c


func _make_mesh(kind: String) -> Node3D:
	var root := Node3D.new()
	if kind == "40mm":
		# Axis = +Y (flight direction): dark olive body, orange band, brass driving band, gold nose.
		_mi(root, _cyl(0.02, 0.02, 0.07), _mat(Color(0.28, 0.3, 0.22), 0.6, 0.2), Vector3(0, -0.005, 0))
		_mi(root, _cyl(0.0205, 0.0205, 0.012), _mat(Color(1.0, 0.5, 0.12), 0.5, 0.0), Vector3(0, 0.012, 0))
		_mi(root, _cyl(0.021, 0.021, 0.008), _mat(Color(0.85, 0.62, 0.3), 0.3, 0.9), Vector3(0, -0.03, 0))
		_mi(root, _cyl(0.02, 0.006, 0.03), _mat(Color(0.8, 0.66, 0.32), 0.3, 0.9), Vector3(0, 0.045, 0))
	else:
		# Hand grenade: rounded white body, orange band, dark fuse head, red LED.
		var sm := SphereMesh.new()
		sm.radius = 0.042
		sm.height = 0.094
		sm.radial_segments = 14
		sm.rings = 8
		_mi(root, sm, _mat(Color(0.88, 0.89, 0.9), 0.4, 0.0))
		_mi(root, _cyl(0.0435, 0.0435, 0.016), _mat(Color(1.0, 0.48, 0.1), 0.5, 0.0))
		_mi(root, _cyl(0.016, 0.014, 0.024), _mat(Color(0.18, 0.19, 0.21), 0.4, 0.6), Vector3(0, 0.05, 0))
		var led := _mi(root, SphereMesh.new(), _mat(Color(1.0, 0.15, 0.1), 0.3, 0.0, 6.0), Vector3(0, 0.064, 0))
		(led.mesh as SphereMesh).radius = 0.006
		(led.mesh as SphereMesh).height = 0.012
		root.set_meta("led", led)
	for c in root.get_children():
		(c as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


func _make_trail(kind: String) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.amount = 48 if kind == "40mm" else 16
	e.lifetime = 1.1 if kind == "40mm" else 0.6
	e.local_coords = false
	e.emitting = false
	e.visibility_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.3
	pm.damping_min = 0.5
	pm.damping_max = 1.0
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.6
	pm.scale_max = 1.1
	var cv := Curve.new()
	cv.add_point(Vector2(0, 0.4))
	cv.add_point(Vector2(1, 1.0))
	var ct := CurveTexture.new()
	ct.curve = cv
	pm.scale_curve = ct
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.1, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.5), Color(1, 1, 1, 0)])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = Color(0.85, 0.85, 0.86) if kind == "40mm" else Color(0.7, 0.7, 0.72)
	e.process_material = pm
	if _soft == null:
		Explosion._ensure_textures()
		_soft = Explosion._tex_soft
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.roughness = 1.0
	m.albedo_texture = _soft
	var q := QuadMesh.new()
	q.size = Vector2(0.22, 0.22) if kind == "40mm" else Vector2(0.08, 0.08)
	q.material = m
	e.draw_pass_1 = q
	return e
