extends Node3D
## World-space effects for the rifle, all pooled: ballistic bullets (fast tracer streaks with drop
## that start at the muzzle and converge onto the true eye-line trajectory, widened with distance
## so they stay visible), tranquilizer darts, impact bursts per surface (a hot flash + ground-colored
## dust + clods on terrain, metal sparks, alien goo sprays on creatures: back toward the shooter and
## out along the shot, with a goo splat decal where the spray lands), bullet-hole decals, brass
## casings that bounce and tink, muzzle smoke, muzzle light, 3D sounds.

const SndLib := preload("res://scripts/audio/snd_lib.gd")
const MASK := 1 | 2 | 4 | 8 | 32     # terrain | ship | vehicle | characters (Game.LAYER_PLAYER) | 32
const N_TRACERS := 20
const N_DECALS := 48
const N_SHELLS := 18
const N_EMIT := 8                # pooled emitters per burst type
const CONVERGE := 14.0           # meters over which the visible tracer joins the eye-line path
const SPLAT_GAP := 0.06          # min seconds between two goo splat decals (rapid fire)

static var _tex_splat: Texture2D

var rifle                        # owner (scripts/items/rifle.gd)
var bullets_in_flight := 0
var _bullets: Array = []
var _tracers: Array = []         # pooled {mi, mat, busy}
var _darts: Array = []           # pooled dart meshes {node, busy}
var _emit := {}                  # kind -> {"list": Array, "i": int}
var _decals: Array = []          # {node, t, life}
var _decal_i := 0
var _shells: Array = []          # {mi, vel, spin, t, bounces}
var _shell_i := 0
var _puffs: Array = []           # {mi, mat, t, dur, size}
var _lights: Array = []          # {light, t, dur, energy}
var _audio: Array = []
var _audio_i := 0
var _tex_dot: Texture2D
var _tex_hole: Texture2D
var _tex_hole_big: Texture2D
var _streams := {}               # name -> Array[AudioStream]
var _sphere_mesh: SphereMesh
var _brass_mat: Material
var _hull_mat: StandardMaterial3D
var _cam_pos := Vector3.ZERO
var _splat_t := 0


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_tex_dot = _make_dot()
	_tex_hole = _make_decal_tex(0)
	_tex_hole_big = _make_decal_tex(1)
	_sphere_mesh = SphereMesh.new()
	_sphere_mesh.radius = 1.0
	_sphere_mesh.height = 2.0
	_sphere_mesh.radial_segments = 12
	_sphere_mesh.rings = 6
	if _tex_splat == null:
		_tex_splat = _make_splat_tex()
	var tracer_mesh := CylinderMesh.new()
	tracer_mesh.top_radius = 0.006
	tracer_mesh.bottom_radius = 0.0095
	tracer_mesh.height = 1.0
	tracer_mesh.radial_segments = 6
	tracer_mesh.rings = 1
	for i in N_TRACERS:
		var mi := MeshInstance3D.new()
		mi.mesh = tracer_mesh
		var m := _add_mat(Color(1.0, 0.85, 0.55), 6.0)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_tracers.append({"mi": mi, "mat": m, "busy": false})
	for i in 6:
		_darts.append({"node": _make_dart(), "busy": false})
	_emit["dust"] = _make_pool("dust")
	_emit["debris"] = _make_pool("debris")
	_emit["sparks"] = _make_pool("sparks")
	_emit["goo"] = _make_pool("goo")
	_emit["smoke"] = _make_pool("smoke")
	_emit["msmoke"] = _make_pool("msmoke")
	_emit["zap"] = _make_pool("zap")
	for i in N_DECALS:
		var d := Decal.new()
		d.visible = false
		d.upper_fade = 0.3
		d.lower_fade = 0.3
		d.normal_fade = 0.4
		add_child(d)
		_decals.append({"node": d, "t": 0.0, "life": 0.0})
	var brass := StandardMaterial3D.new()
	brass.albedo_color = Color(0.86, 0.64, 0.3)
	brass.metallic = 0.95
	brass.roughness = 0.25
	var shell_mesh := CylinderMesh.new()
	shell_mesh.top_radius = 0.0045
	shell_mesh.bottom_radius = 0.0058
	shell_mesh.height = 0.034
	shell_mesh.radial_segments = 8
	shell_mesh.rings = 1
	for i in N_SHELLS:
		var mi := MeshInstance3D.new()
		mi.mesh = shell_mesh
		mi.material_override = brass
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_shells.append({"mi": mi, "vel": Vector3.ZERO, "spin": Vector3.ZERO, "t": 99.0, "bounces": 0, "scale": 1.0})
	for i in 10:
		var mi := MeshInstance3D.new()
		mi.mesh = _sphere_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		var m := _add_mat(Color.WHITE, 2.0)
		mi.material_override = m
		add_child(mi)
		_puffs.append({"mi": mi, "mat": m, "t": 99.0, "dur": 0.1, "size": 0.3})
	for i in 3:
		var l := OmniLight3D.new()
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append({"light": l, "t": 99.0, "dur": 0.1, "energy": 1.0})
	for i in 14:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 9.0
		p.max_distance = 140.0
		p.max_db = 3.0
		add_child(p)
		_audio.append(p)
	# Recorded bullet impacts (assets/audio/sonniss/bimp: Mechanical Wave rock / dirt, Gamemaster
	# metal and concrete, Gorification flesh); energy hits keep the Kenney force-field zaps.
	_streams["dirt"] = SndLib.set_of("bimp/dirt")
	_streams["rock"] = SndLib.set_of("bimp/rock")
	_streams["metal"] = SndLib.set_of("bimp/metal")
	_streams["flesh"] = SndLib.set_of("bimp/flesh")
	_streams["zap"] = _ogg_set("scifi/forceField_00%d", 5)


# =================================================================================================
# Public effects
# =================================================================================================

## Launches a bullet (or dart) from the eye along vel; the visible streak starts at `muzzle`.
func bullet(eye: Vector3, vel: Vector3, muzzle: Vector3, ammo: int, col: Color, dart: bool, pierce: int) -> void:
	var b := {"pos": eye, "vel": vel, "off": muzzle - eye, "dist": 0.0, "life": 3.0, "ammo": ammo, "dart": dart,
			"pierce": pierce, "pierced": 0, "ignore": null, "vis": null, "prev": muzzle}
	if dart:
		for d in _darts:
			if not d["busy"]:
				d["busy"] = true
				b["vis"] = d
				break
	else:
		for tr in _tracers:
			if not tr["busy"]:
				tr["busy"] = true
				b["vis"] = tr
				var m: StandardMaterial3D = tr["mat"]
				var hot := Color(1.0, 0.86, 0.58).lerp(col, 0.35)
				m.albedo_color = hot
				m.emission = hot
				break
	_bullets.append(b)


func muzzle_light(p: Vector3, col: Color, energy: float, dur := 0.05, light_range := 9.0) -> void:
	var best: Dictionary = _lights[0]
	for li in _lights:
		if float(li["t"]) >= float(li["dur"]):
			best = li
			break
	var l: OmniLight3D = best["light"]
	l.global_position = p
	l.light_color = col
	l.omni_range = light_range
	l.light_energy = energy
	l.visible = true
	best["t"] = 0.0
	best["dur"] = maxf(dur, 0.05)
	best["energy"] = energy
	best["fresh"] = true      # shots come from the physics step: render one frame at full strength


## Smoke wisp drifting from the muzzle after a shot.
func muzzle_smoke(p: Vector3, fwd: Vector3, up: Vector3) -> void:
	_burst("msmoke", p, (fwd * 0.8 + up * 0.4).normalized(), Color(0.82, 0.82, 0.84), 1.0)


## Small gas puff (dart gun).
func muzzle_puff(p: Vector3, fwd: Vector3) -> void:
	_burst("msmoke", p, fwd, Color(0.9, 0.95, 1.0), 0.4)


## Ground hit: dust in the ground color, flying clods and a bullet hole.
func impact_terrain(p: Vector3, n: Vector3, dir: Vector3, ground: Color, dart: bool, heavy: bool) -> void:
	if dart:
		_burst("dust", p, n, ground, 0.3)
		_sound("dirt", p, -14.0, 1.5)
		return
	var rock := ground.r < 0.45 and absf(ground.r - ground.g) < 0.05
	_puff(p + n * 0.04, Color(1.0, 0.82, 0.55), 0.05, 0.22 if heavy else 0.15)
	_burst("dust", p, n.lerp(-dir, 0.25).normalized(), ground, 1.0 if heavy else 0.8)
	_burst("debris", p, n.lerp(-dir, 0.3).normalized(), ground.darkened(0.25), 1.0 if heavy else 0.7)
	if rock or heavy:
		_burst("sparks", p, n, Color(1.0, 0.75, 0.4), 0.35 if rock else 0.5)
	_decal(p, n, 0.24 if heavy else 0.16, _tex_hole, Color(0.1, 0.085, 0.07, 0.95), 30.0)
	_sound("rock" if rock else "dirt", p, -5.0 if heavy else -8.0, randf_range(0.95, 1.25))


## Hull / metal hit: sparks, a wisp of smoke and a ricochet ping.
func impact_metal(p: Vector3, n: Vector3, dir: Vector3, dart: bool) -> void:
	if dart:
		_burst("zap", p, n, Color(0.6, 0.9, 1.0), 0.4)
		_sound("metal", p, -14.0, 1.8)
		return
	_burst("sparks", p, n.lerp(dir.bounce(n), 0.5).normalized(), Color(1.0, 0.8, 0.45), 1.0)
	_burst("smoke", p, n, Color(0.45, 0.45, 0.47), 0.3)
	_decal(p, n, 0.1, _tex_hole_big, Color(0.06, 0.06, 0.07, 0.9), 30.0)
	_sound("metal", p, -6.0, randf_range(1.0, 1.35))


## Creature hit: a splash of its alien body fluid (non-gory, glowing). Darts: a soft blue puff.
func impact_creature(p: Vector3, n: Vector3, dir: Vector3, goo: Color, dart: bool, heavy: bool) -> void:
	if dart:
		_burst("zap", p, n, Color(0.45, 0.9, 1.0), 0.6)
		_puff(p, Color(0.4, 0.85, 1.0), 0.12, 0.18)
		_sound("zap", p, -10.0, 1.6)
		return
	# Back-spray toward the shooter, a jet out along the shot, a bright puff, a splat where it lands.
	_burst("goo", p, (n - dir * 0.6).normalized(), goo, 1.0 if heavy else 0.8)
	_burst("goo", p, (dir + _up_at(p) * 0.15).normalized(), goo.lightened(0.2), 0.9 if heavy else 0.55)
	_puff(p, goo.lightened(0.15), 0.09, 0.38 if heavy else 0.26)
	_goo_splat(p, dir, goo, heavy)
	_sound("flesh", p, -2.0 if heavy else -4.0, randf_range(0.9, 1.15))


## A goo splat decal on the ground (or wall) behind the creature where the exit spray lands.
func _goo_splat(p: Vector3, dir: Vector3, goo: Color, heavy: bool) -> void:
	var now := Time.get_ticks_msec()
	if now - _splat_t < int(SPLAT_GAP * 1000.0) or not is_inside_tree():
		return
	_splat_t = now
	var up := _up_at(p)
	var d := (dir - up * 0.7).normalized()
	var q := PhysicsRayQueryParameters3D.create(p + dir * 0.3, p + d * 3.5, 1 | 2)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	var c := goo.darkened(0.15)
	_decal(hit["position"], hit["normal"], randf_range(0.5, 0.75) * (1.35 if heavy else 1.0), _tex_splat,
			Color(c.r, c.g, c.b, 0.9), 22.0)


## Local "up" (against gravity; works on the moons too). Weightless: away from the nearest world's
## centre (worlds are not at the scene origin).
static func _up_at(p: Vector3) -> Vector3:
	var g: Vector3 = Game.gravity_at(p)
	if g.length_squared() > 1e-6:
		return -g.normalized()
	var b := Game.body_at(p)
	var u := p - (b.global_position if b != null else Game.planet_center())
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


## Spent casing ejected to the right; it bounces on the ground and tinks.
## hull = true: a red shotgun hull (plastic body, brass head) instead of a brass casing.
func shell(p: Vector3, vel: Vector3, big: bool, hull := false) -> void:
	var s: Dictionary = _shells[_shell_i]
	_shell_i = (_shell_i + 1) % _shells.size()
	s["vel"] = vel
	s["spin"] = Vector3(randf_range(-40, 40), randf_range(-25, 25), randf_range(-40, 40))
	s["t"] = 0.0
	s["bounces"] = 0
	s["scale"] = 2.1 if hull else (1.3 if big else 1.0)
	var mi: MeshInstance3D = s["mi"]
	if _hull_mat == null:
		_brass_mat = mi.material_override
		_hull_mat = StandardMaterial3D.new()
		_hull_mat.albedo_color = Color(0.8, 0.14, 0.1)
		_hull_mat.roughness = 0.45
	mi.material_override = _hull_mat if hull else _brass_mat
	mi.global_transform = Transform3D(Basis().scaled(Vector3.ONE * float(s["scale"])), p)
	mi.visible = true


# =================================================================================================
# Simulation
# =================================================================================================

func _physics_process(delta: float) -> void:
	_step_bullets(delta)
	_step_shells(delta)


func _step_bullets(delta: float) -> void:
	bullets_in_flight = _bullets.size()
	if _bullets.is_empty():
		return
	var space := get_world_3d().direct_space_state
	var ex: Array = []
	if rifle != null and rifle.player != null:
		ex.append(rifle.player.get_rid())
	var vcam := get_viewport().get_camera_3d()
	if vcam != null:
		_cam_pos = vcam.global_position
	var keep: Array = []
	for b in _bullets:
		var p: Vector3 = b["pos"]
		var start := p
		var v: Vector3 = b["vel"]
		v += Game.gravity_at(p) * delta
		var np := p + v * delta
		var done := false
		# Up to two segments per step (a piercing round continues past the body it hit).
		for pass_i in 2:
			var seg := np - p
			var len := seg.length()
			if len < 1e-4:
				break
			var dir := seg / len
			var exb: Array = ex if b["ignore"] == null else ex + [b["ignore"]]
			var q := PhysicsRayQueryParameters3D.create(p, np, MASK, exb)
			var hit := space.intersect_ray(q)
			var info := {}
			if not hit.is_empty():
				info = _classify(hit)
			if info.is_empty():
				break
			var stop := true
			if rifle != null:
				stop = rifle.bullet_hit(info, dir, int(b["ammo"]), int(b["pierced"]))
			if stop:
				done = true
				np = info["point"]
				break
			# Pierced through a body: keep flying from just past the hit, ignoring that collider.
			b["pierced"] = int(b["pierced"]) + 1
			var hc = info.get("collider")
			b["ignore"] = (hc as CollisionObject3D).get_rid() if hc is CollisionObject3D else null
			var hp: Vector3 = info["point"]
			p = hp + dir * 0.05
			v *= 0.75
			np = p + v * delta * 0.5
		b["dist"] = float(b["dist"]) + start.distance_to(np)
		b["life"] = float(b["life"]) - delta
		b["pos"] = np
		b["vel"] = v
		if done or float(b["life"]) <= 0.0:
			_release(b)
			continue
		_draw_bullet(b, np, delta)
		keep.append(b)
	_bullets = keep


## What a bullet hit: "body" (a node in group "damageable", or its child; info["target"]),
## "terrain" (the terrain layer) or "metal" (anything else).
func _classify(hit: Dictionary) -> Dictionary:
	var col: Object = hit["collider"]
	var target: Node = Game.damageable_of(col)
	if target != null:
		return {"type": "body", "target": target, "point": hit["position"], "normal": hit["normal"], "collider": col}
	var t := "metal"
	if col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & 1) != 0:
		t = "terrain"
	return {"type": t, "point": hit["position"], "normal": hit["normal"], "collider": col}


## Places the tracer streak (or dart) for a bullet whose true position is `pos`.
func _draw_bullet(b: Dictionary, pos: Vector3, delta: float) -> void:
	var vis = b["vis"]
	if vis == null:
		return
	var v: Vector3 = b["vel"]
	var speed := v.length()
	var dir := v / maxf(speed, 1e-4)
	var k := clampf(1.0 - float(b["dist"]) / CONVERGE, 0.0, 1.0)
	var off: Vector3 = b["off"]
	var head := pos + off * k
	if b["dart"]:
		var node: Node3D = vis["node"]
		node.visible = true
		node.global_transform = Transform3D(_basis_y(-dir), head)
		return
	var mi: MeshInstance3D = vis["mi"]
	var prev: Vector3 = b["prev"]
	var len := minf(clampf(speed * delta * 1.25, 1.2, 9.0), head.distance_to(prev) + 0.6)
	b["prev"] = head
	if len < 0.05:
		mi.visible = false
		return
	var bas := _basis_y(dir)
	# Wider with distance so far tracers stay a visible streak instead of a sub-pixel line.
	var w := clampf(head.distance_to(_cam_pos) * 0.08, 1.0, 10.0)
	mi.global_transform = Transform3D(Basis(bas.x * w, bas.y * len, bas.z * w), head - dir * len * 0.5)
	mi.visible = true


func _release(b: Dictionary) -> void:
	var vis = b["vis"]
	if vis == null:
		return
	vis["busy"] = false
	if b["dart"]:
		(vis["node"] as Node3D).visible = false
	else:
		(vis["mi"] as Node3D).visible = false


func _step_shells(delta: float) -> void:
	var space := get_world_3d().direct_space_state
	for s in _shells:
		var t: float = s["t"]
		if t > 2.6:
			continue
		var mi: MeshInstance3D = s["mi"]
		t += delta
		s["t"] = t
		if t > 2.6:
			mi.visible = false
			continue
		var v: Vector3 = s["vel"]
		var p := mi.global_position
		v += Game.gravity_at(p) * delta
		var np := p + v * delta
		if v.length_squared() > 0.04:
			var q := PhysicsRayQueryParameters3D.create(p, np, 1 | 2 | 4)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				var n: Vector3 = hit["normal"]
				var hp: Vector3 = hit["position"]
				var speed := v.length()
				v = v.bounce(n) * 0.32 + Vector3(randf_range(-0.3, 0.3), 0, randf_range(-0.3, 0.3))
				if v.dot(n) < 0.4 and speed > 1.0:
					v += n * 0.4
				s["spin"] = Vector3(s["spin"]) * 0.5
				np = hp + n * 0.012
				var bn: int = s["bounces"]
				if bn < 3 and speed > 1.0 and rifle != null:
					var st: AudioStream = rifle.synth_stream("tink")
					if st != null:
						_sound_stream(st, hp, -18.0 - bn * 5.0, randf_range(0.85, 1.25))
				s["bounces"] = bn + 1
				if speed < 0.8:
					v = Vector3.ZERO
					s["spin"] = Vector3.ZERO
		s["vel"] = v
		var sp: Vector3 = s["spin"]
		var bas := mi.global_transform.basis
		if sp.length_squared() > 0.01:
			bas = bas.rotated(sp.normalized(), sp.length() * delta)
		var sc: float = float(s["scale"]) * clampf((2.6 - t) * 2.0, 0.0, 1.0)
		mi.global_transform = Transform3D(bas.orthonormalized().scaled(Vector3.ONE * maxf(sc, 0.001)), np)


func _process(delta: float) -> void:
	for f in _puffs:
		var t: float = f["t"]
		var dur: float = f["dur"]
		if t >= dur:
			continue
		t += delta
		f["t"] = t
		var mi: MeshInstance3D = f["mi"]
		if t >= dur:
			mi.visible = false
			continue
		var k := t / dur
		mi.scale = Vector3.ONE * float(f["size"]) * (0.4 + 0.6 * sqrt(k))
		(f["mat"] as StandardMaterial3D).albedo_color.a = (1.0 - k) * (1.0 - k)
	for li in _lights:
		var t: float = li["t"]
		var dur: float = li["dur"]
		if t >= dur:
			continue
		if li.get("fresh", false):
			li["fresh"] = false
			continue
		t += delta
		li["t"] = t
		var l: OmniLight3D = li["light"]
		if t >= dur:
			l.visible = false
			continue
		var k := 1.0 - t / dur
		l.light_energy = float(li["energy"]) * k * k
	for d in _decals:
		var life: float = d["life"]
		if life <= 0.0:
			continue
		var t: float = float(d["t"]) + delta
		d["t"] = t
		var node: Decal = d["node"]
		if t >= life:
			node.visible = false
			d["life"] = 0.0
			continue
		node.albedo_mix = clampf((life - t) / 3.0, 0.0, 1.0)


# =================================================================================================
# Internals
# =================================================================================================

func _add_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m


static func _basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


func _make_dart() -> Node3D:
	var root := Node3D.new()
	root.visible = false
	add_child(root)
	var body := StandardMaterial3D.new()
	body.albedo_color = Color(0.85, 0.88, 0.92)
	body.metallic = 0.6
	body.roughness = 0.3
	var shaft := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.004
	cm.bottom_radius = 0.006
	cm.height = 0.09
	cm.radial_segments = 8
	cm.rings = 1
	shaft.mesh = cm
	shaft.material_override = body
	root.add_child(shaft)
	var tip := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.004
	tm.bottom_radius = 0.0
	tm.height = 0.03
	tm.radial_segments = 6
	tm.rings = 1
	tip.mesh = tm
	tip.material_override = body
	tip.position = Vector3(0, -0.06, 0)
	root.add_child(tip)
	var glow := _add_mat(Color(0.4, 0.9, 1.0), 4.0)
	for k in 2:
		var fin := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.03, 0.025, 0.003)
		fin.mesh = bm
		fin.material_override = glow
		fin.position = Vector3(0, 0.045, 0)
		fin.rotation.y = k * PI * 0.5
		root.add_child(fin)
	for c in root.get_children():
		(c as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


func _puff(p: Vector3, col: Color, dur: float, size: float) -> void:
	var best: Dictionary = _puffs[0]
	for f in _puffs:
		if float(f["t"]) >= float(f["dur"]):
			best = f
			break
	var mi: MeshInstance3D = best["mi"]
	mi.global_position = p
	var m: StandardMaterial3D = best["mat"]
	m.albedo_color = Color(col.r, col.g, col.b, 1.0)
	m.emission = col
	mi.scale = Vector3.ONE * size * 0.4
	mi.visible = true
	best["t"] = 0.0
	best["dur"] = dur
	best["size"] = size


func _decal(p: Vector3, n: Vector3, size: float, tex: Texture2D, col: Color, life: float) -> void:
	var d: Dictionary = _decals[_decal_i]
	_decal_i = (_decal_i + 1) % _decals.size()
	var node: Decal = d["node"]
	node.texture_albedo = tex
	node.modulate = col
	node.albedo_mix = 1.0
	node.size = Vector3(size, maxf(size * 0.8, 0.4), size)
	var b := _basis_y(n).rotated(n.normalized(), randf() * TAU)
	node.global_transform = Transform3D(b, p)
	node.visible = true
	d["t"] = 0.0
	d["life"] = life


func _burst(kind: String, p: Vector3, n: Vector3, col: Color, amount: float) -> void:
	var pool: Dictionary = _emit[kind]
	var list: Array = pool["list"]
	var i: int = pool["i"]
	pool["i"] = (i + 1) % list.size()
	var e: GPUParticles3D = list[i]
	var pm: ParticleProcessMaterial = e.process_material
	pm.color = col * 3.0 if (kind == "sparks" or kind == "zap") else col
	pm.gravity = Game.gravity_at(p) * float(e.get_meta("gk"))
	e.amount_ratio = clampf(amount, 0.05, 1.0)
	e.global_transform = Transform3D(_basis_y(n), p)
	e.restart()


func _make_pool(kind: String) -> Dictionary:
	var list: Array = []
	for i in N_EMIT:
		list.append(_make_emitter(kind))
	return {"list": list, "i": 0}


func _make_emitter(kind: String) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.one_shot = true
	e.emitting = false
	e.explosiveness = 0.95
	e.local_coords = false
	e.fixed_fps = 0
	e.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.04
	var quad := QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = _tex_dot
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	var gk := 1.0
	match kind:
		"dust":
			e.amount = 14
			e.lifetime = 1.2
			pm.spread = 32.0
			pm.initial_velocity_min = 1.0
			pm.initial_velocity_max = 3.6
			pm.damping_min = 3.0
			pm.damping_max = 5.0
			pm.scale_min = 0.5
			pm.scale_max = 1.3
			pm.scale_curve = _curve(0.35, 1.0, 1.7)
			gk = 0.12
			quad.size = Vector2(0.3, 0.3)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 1.0
		"smoke", "msmoke":
			e.amount = 10 if kind == "smoke" else 6
			e.lifetime = 1.8 if kind == "smoke" else 1.0
			e.explosiveness = 0.8
			pm.spread = 25.0 if kind == "smoke" else 12.0
			pm.initial_velocity_min = 0.6
			pm.initial_velocity_max = 2.0 if kind == "smoke" else 1.6
			pm.damping_min = 1.5
			pm.damping_max = 2.5
			pm.scale_min = 0.6
			pm.scale_max = 1.2
			pm.scale_curve = _curve(0.3, 1.0, 2.4)
			gk = -0.04
			quad.size = Vector2(0.7, 0.7) if kind == "smoke" else Vector2(0.14, 0.14)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 1.0
			if kind == "msmoke":
				var fade2 := Gradient.new()
				fade2.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
				fade2.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.35), Color(1, 1, 1, 0)])
				var ramp2 := GradientTexture1D.new()
				ramp2.gradient = fade2
				pm.color_ramp = ramp2
		"debris":
			e.amount = 8
			e.lifetime = 1.2
			pm.spread = 30.0
			pm.initial_velocity_min = 2.0
			pm.initial_velocity_max = 5.5
			pm.angular_velocity_min = -540.0
			pm.angular_velocity_max = 540.0
			pm.scale_min = 0.5
			pm.scale_max = 1.2
			gk = 1.0
			var bm := BoxMesh.new()
			bm.size = Vector3(0.035, 0.028, 0.04)
			var dm := StandardMaterial3D.new()
			dm.vertex_color_use_as_albedo = true
			dm.roughness = 0.95
			bm.material = dm
			e.draw_pass_1 = bm
			pm.color_ramp = null
		"sparks", "zap":
			e.amount = 16
			e.lifetime = 0.3 if kind == "sparks" else 0.25
			pm.spread = 50.0 if kind == "sparks" else 90.0
			pm.initial_velocity_min = 3.0
			pm.initial_velocity_max = 8.0 if kind == "sparks" else 5.0
			pm.damping_min = 2.0
			pm.damping_max = 4.0
			pm.scale_min = 0.5
			pm.scale_max = 1.0
			pm.particle_flag_align_y = true
			gk = 0.6 if kind == "sparks" else 0.0
			quad.size = Vector2(0.012, 0.09)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
			mat.billboard_keep_scale = true
			mat.albedo_texture = null
		"goo":
			e.amount = 24
			e.lifetime = 0.8
			pm.spread = 30.0
			pm.initial_velocity_min = 2.0
			pm.initial_velocity_max = 6.5
			pm.damping_min = 0.5
			pm.damping_max = 1.2
			pm.scale_min = 0.45
			pm.scale_max = 1.4
			pm.scale_curve = _curve(1.0, 0.9, 0.3)
			gk = 1.0
			quad.size = Vector2(0.1, 0.1)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if kind != "debris":
		quad.material = mat
		e.draw_pass_1 = quad
	e.process_material = pm
	e.set_meta("gk", gk)
	add_child(e)
	return e


func _curve(a: float, b: float, c: float) -> CurveTexture:
	var cv := Curve.new()
	cv.max_value = 3.0
	cv.add_point(Vector2(0.0, a))
	cv.add_point(Vector2(0.3, b))
	cv.add_point(Vector2(1.0, c))
	var ct := CurveTexture.new()
	ct.curve = cv
	return ct


func _sound(name: String, p: Vector3, vol: float, pitch: float) -> void:
	if not _streams.has(name):
		return
	var arr: Array = _streams[name]
	if arr.is_empty():
		return
	if name != "zap":
		pitch = clampf(pitch, 0.85, 1.2) * randf_range(0.97, 1.03)   # recordings near their own pitch
	_sound_stream(arr[randi() % arr.size()], p, vol, pitch)


func _sound_stream(st: AudioStream, p: Vector3, vol: float, pitch: float) -> void:
	var pl: AudioStreamPlayer3D = _audio[_audio_i]
	_audio_i = (_audio_i + 1) % _audio.size()
	pl.stream = st
	pl.global_position = p
	pl.volume_db = vol
	pl.pitch_scale = pitch
	if Game.sfx != null and Game.sfx.has_method("route_player"):
		Game.sfx.route_player(pl)       # no sound in vacuum (sfx.gd medium rules)
	pl.play()


static func _ogg_set(pattern: String, n: int) -> Array:
	var out: Array = []
	for i in n:
		var path := "res://assets/audio/%s.ogg" % (pattern % i)
		if ResourceLoader.exists(path):
			var s = load(path)
			if s != null:
				out.append(s)
	return out


func _make_dot() -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 64
	t.height = 64
	return t


## Procedural goo splat: an irregular blob with a few droplets around it (alpha = coverage, white).
static func _make_splat_tex() -> Texture2D:
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 77
	noise.frequency = 0.07
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 5
	var drops: Array = []
	for i in 9:
		var a := rng2.randf() * TAU
		var r := rng2.randf_range(0.5, 0.85)
		drops.append([Vector2(cos(a), sin(a)) * r, rng2.randf_range(0.04, 0.09)])
	for y in n:
		for x in n:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(n) * 2.0 - Vector2.ONE
			var ang := atan2(u.y, u.x)
			var rr := u.length() * (1.0 + 0.25 * sin(ang * 5.0 + 1.3) + 0.35 * noise.get_noise_2d(x, y))
			var a := 1.0 - smoothstep(0.32, 0.42, rr)
			for dd in drops:
				var dl := (u - (dd[0] as Vector2)).length()
				a = maxf(a, 1.0 - smoothstep(float(dd[1]) * 0.7, float(dd[1]), dl))
			var shade := 0.85 + 0.15 * noise.get_noise_2d(x * 3.0, y * 3.0)
			img.set_pixel(x, y, Color(shade, shade, shade, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


## Procedural bullet-hole textures: 0 dirt hole with a soft ring, 1 sharp metal dent.
func _make_decal_tex(kind: int) -> Texture2D:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 17 + kind
	noise.frequency = 0.09
	for y in n:
		for x in n:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(n) * 2.0 - Vector2.ONE
			var r := u.length()
			var nz := noise.get_noise_2d(x, y)
			var core := 1.0 - smoothstep(0.12, 0.2, r)
			var ring := (1.0 - smoothstep(0.2, 0.62 + nz * 0.25, r)) * (0.55 if kind == 0 else 0.25)
			var a := maxf(core, ring)
			var c := Color(1, 1, 1).lerp(Color(0.55, 0.55, 0.55), core)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
