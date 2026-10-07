extends RefCounted
## Props of the combat areas (scripts/planet/poi.gd): procedural meshes in the Mekik's hull shader
## (scripts/craft/skiff_shaders.gd "hull": vertex colour = sRGB albedo + roughness, UV in metres,
## UV2 = (pattern, metallic)), so ruins and wrecks share the game's white / orange / dark-metal look
## and the shader weathers them (grime, chipped paint, soot; the wreck also scorched, with glowing
## cracks). Bevelled edges everywhere so the sun catches them.
## Collision: one StaticBody3D per area on Game.LAYER_SHIP (bullets, the player, mantle, vehicles
## and the acoustics hit it). The bots move on the density, so the area also registers Node3Ds in
## group "poi_obstacle" (meta "footprint_r") for their crowd separation, and poi.gd raised soil
## under / inside the big pieces.
## Beacons: the debris_mesh.gd halo billboard (never shrinks below a few pixels, blinks in its
## shader: no per-frame script cost). Smoke and fire: GPU particles.
## Meshes that do not depend on the area (tower, bunker, hull, engine, crates, barriers, portals)
## are built once per run and shared by every area on both planets.
##
##   Props.build(planet, site, root) -> collision shape count     (poi.gd spawn_props)

const Shaders := preload("res://scripts/craft/skiff_shaders.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const Balance := preload("res://scripts/war/balance.gd")

# Paint (sRGB, alpha = roughness): the Mekik's palette.
const WHITE := Color(0.78, 0.78, 0.76, 0.46)
const ORANGE := Color(0.84, 0.41, 0.13, 0.5)
const GRAPHITE := Color(0.24, 0.25, 0.27, 0.62)
const STEEL := Color(0.38, 0.39, 0.41, 0.48)
const DARK := Color(0.17, 0.18, 0.19, 0.72)
const INSIDE := Color(0.3, 0.31, 0.32, 0.78)
const WINDOW := Color(0.1, 0.12, 0.14, 0.12)
const YELLOW := Color(0.88, 0.7, 0.2, 0.55)
const COMPOSITE := Color(0.7, 0.7, 0.68, 0.82)
# Hull shader patterns (UV2.x): > 0 panel plating of that size (m).
const P_PLAIN := 0.0
const P_HAZARD := -1.0
const P_TREAD := -2.0
const P_VENT := -6.0
const P_TILES := -7.0
const P_BRUSHED := -8.0

const NEAR_VIS := 170.0       # m: small props (crates, debris, barriers) are drawn up to here
const MID_VIS := 650.0        # structures: past the far side of the other planet
const HULL_KEYS := [          # crash hull sections: z, half width, half height, centre y
	[-7.0, 2.45, 2.1, 0.0], [-4.5, 2.6, 2.25, 0.0], [-1.0, 2.68, 2.3, 0.02], [2.5, 2.55, 2.2, 0.0],
	[4.8, 2.15, 1.9, -0.08], [6.4, 1.55, 1.4, -0.16], [7.4, 0.85, 0.8, -0.22], [8.0, 0.16, 0.16, -0.25]]
const HULL_Z := [-7.0, -6.3, -5.5, -4.6, -3.8, -3.0, -2.0, -1.0, 0.0, 1.0, 1.6, 2.2, 3.0, 3.8, 4.5, 5.1,
	5.7, 6.2, 6.7, 7.1, 7.45, 7.75, 8.0]
const HULL_SEGS := 28
const HULL_INNER := 4         # rings 0..HULL_INNER: the torn, open section (an inner shell, a bulkhead)

static var _cache := {}
static var _mats := {}
static var _shapes := {}


## Builds one area's props under `root` (a Node3D at the area frame, child of the planet). Returns
## the number of collision shapes.
static func build(pl: Node3D, site: Dictionary, root: Node3D) -> int:
	var c := Ctx.new()
	c.pl = pl
	c.site = site
	c.data = site.get("data", {})
	c.root = root
	c.frame = site["frame"]
	c.inv = c.frame.affine_inverse()
	c.rng = RandomNumberGenerator.new()
	c.rng.seed = int(site["seed"]) ^ 0x5bd1e995
	c.gen = pl.gen
	c.edits = pl.edits
	c.q = maxf(float(pl.radius), 8.0)
	match str(site.get("kind_id", "")):
		"outpost":
			_outpost(c)
		"crash":
			_crash(c)
		"trench":
			_trench(c)
		"tunnel":
			_tunnel(c)
	_finish(c)
	return c.shapes


class Ctx:
	var pl: Node3D
	var site: Dictionary
	var data: Dictionary
	var root: Node3D
	var frame: Transform3D
	var inv: Transform3D
	var rng: RandomNumberGenerator
	var gen: TerrainGen
	var edits: Dictionary
	var q := 60.0
	var body: StaticBody3D = null
	var shapes := 0
	var kits := {}            # "material|vis|shadow" -> [Kit, material, vis, shadow]
	var vc := {}              # density corner cache
	var surf := {}            # direction cell -> generator surface sample


## Accumulates flat / smooth triangles with the hull shader's vertex data.
class Kit:
	var st := SurfaceTool.new()
	var count := 0

	func _init() -> void:
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

	func _tan(n: Vector3) -> Vector3:
		var r := Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT
		return r.cross(n).normalized()

	func _basis_y(y: Vector3) -> Basis:
		var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
		return Basis(x, y, x.cross(y))

	## Flat triangle facing along n (any winding in: Godot's front faces wind clockwise), UV planar in m.
	func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, paint: Color, pat := 0.0, metal := 0.0) -> void:
		if (b - a).cross(c - a).dot(n) > 0.0:
			var t := b
			b = c
			c = t
		var u := _tan(n)
		var v := n.cross(u)
		st.set_color(paint)
		st.set_normal(n)
		st.set_uv2(Vector2(pat, metal))
		st.set_uv(Vector2(a.dot(u), a.dot(v)))
		st.add_vertex(a)
		st.set_uv(Vector2(b.dot(u), b.dot(v)))
		st.add_vertex(b)
		st.set_uv(Vector2(c.dot(u), c.dot(v)))
		st.add_vertex(c)
		count += 1

	## Smooth triangle: per-vertex normals and UVs.
	func tri_s(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, ua: Vector2, ub: Vector2,
			uc: Vector2, paint: Color, pat := 0.0, metal := 0.0) -> void:
		if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:
			var t := b
			b = c
			c = t
			var tn := nb
			nb = nc
			nc = tn
			var tu := ub
			ub = uc
			uc = tu
		st.set_color(paint)
		st.set_uv2(Vector2(pat, metal))
		st.set_normal(na)
		st.set_uv(ua)
		st.add_vertex(a)
		st.set_normal(nb)
		st.set_uv(ub)
		st.add_vertex(b)
		st.set_normal(nc)
		st.set_uv(uc)
		st.add_vertex(c)
		count += 1

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, paint: Color, pat := 0.0, metal := 0.0) -> void:
		tri(a, b, c, n, paint, pat, metal)
		tri(a, c, d, n, paint, pat, metal)

	## Box of half extents h under xf (orthonormal), edges bevelled by bev.
	func box(xf: Transform3D, h: Vector3, paint: Color, pat := 0.0, metal := 0.0, bev := 0.03) -> void:
		var b := minf(bev, minf(h.x, minf(h.y, h.z)) * 0.45)
		var hi := h - Vector3.ONE * b
		for ax in 3:
			var a1 := (ax + 1) % 3
			var a2 := (ax + 2) % 3
			for s: float in [-1.0, 1.0]:
				var n := Vector3.ZERO
				n[ax] = s
				var c := Vector3.ZERO
				c[ax] = s * h[ax]
				var u := Vector3.ZERO
				u[a1] = hi[a1]
				var v := Vector3.ZERO
				v[a2] = hi[a2]
				quad(xf * (c - u - v), xf * (c + u - v), xf * (c + u + v), xf * (c - u + v), xf.basis * n, paint, pat, metal)
		if b < 0.002:
			return
		for ax in 3:
			var a1 := (ax + 1) % 3
			var a2 := (ax + 2) % 3
			for s1: float in [-1.0, 1.0]:
				for s2: float in [-1.0, 1.0]:
					var p1 := Vector3.ZERO
					p1[a1] = s1 * h[a1]
					p1[a2] = s2 * hi[a2]
					var p2 := Vector3.ZERO
					p2[a1] = s1 * hi[a1]
					p2[a2] = s2 * h[a2]
					var e := Vector3.ZERO
					e[ax] = hi[ax]
					var n := Vector3.ZERO
					n[a1] = s1
					n[a2] = s2
					quad(xf * (p1 - e), xf * (p1 + e), xf * (p2 + e), xf * (p2 - e), (xf.basis * n).normalized(), paint, pat, metal)
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					tri(xf * Vector3(sx * h.x, sy * hi.y, sz * hi.z), xf * Vector3(sx * hi.x, sy * h.y, sz * hi.z),
							xf * Vector3(sx * hi.x, sy * hi.y, sz * h.z), (xf.basis * Vector3(sx, sy, sz)).normalized(), paint, pat, metal)

	## Cylinder / cone along local +y (0 .. len) under xf: smooth sides, flat caps.
	func cyl(xf: Transform3D, r0: float, r1: float, len: float, sides: int, paint: Color, pat := 0.0, metal := 0.0,
			caps := true) -> void:
		var slope := (r0 - r1) / maxf(len, 1e-4)
		var ra := (r0 + r1) * 0.5
		var top := xf * Vector3(0.0, len, 0.0)
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var c0 := Vector3(cos(a0), 0.0, sin(a0))
			var c1 := Vector3(cos(a1), 0.0, sin(a1))
			var n0 := xf.basis * (c0 + Vector3(0.0, slope, 0.0)).normalized()
			var n1 := xf.basis * (c1 + Vector3(0.0, slope, 0.0)).normalized()
			var p00 := xf * (c0 * r0)
			var p10 := xf * (c1 * r0)
			var p01 := xf * (c0 * r1 + Vector3(0.0, len, 0.0))
			var p11 := xf * (c1 * r1 + Vector3(0.0, len, 0.0))
			tri_s(p00, p10, p11, n0, n1, n1, Vector2(a0 * ra, 0.0), Vector2(a1 * ra, 0.0), Vector2(a1 * ra, len), paint, pat, metal)
			tri_s(p00, p11, p01, n0, n1, n0, Vector2(a0 * ra, 0.0), Vector2(a1 * ra, len), Vector2(a0 * ra, len), paint, pat, metal)
			if caps:
				if r1 > 0.001:
					tri(top, p01, p11, xf.basis.y, paint, pat, metal)
				if r0 > 0.001:
					tri(xf.origin, p00, p10, -xf.basis.y, paint, pat, metal)

	func rod(a: Vector3, b: Vector3, r: float, sides: int, paint: Color, pat := 0.0, metal := 0.0, caps := false) -> void:
		var d := b - a
		var l := d.length()
		if l < 1e-4:
			return
		cyl(Transform3D(_basis_y(d / l), a), r, r, l, sides, paint, pat, metal, caps)

	## Convex polygon (local x, y) extruded ±t / 2 along local z under xf.
	func slab(xf: Transform3D, pts: PackedVector2Array, t: float, paint: Color, pat := 0.0, metal := 0.0) -> void:
		var n := pts.size()
		var hz := Vector3(0.0, 0.0, t * 0.5)
		var c2 := Vector2.ZERO
		for p in pts:
			c2 += p
		c2 /= float(n)
		var cc := Vector3(c2.x, c2.y, 0.0)
		for i in n:
			var a := Vector3(pts[i].x, pts[i].y, 0.0)
			var b := Vector3(pts[(i + 1) % n].x, pts[(i + 1) % n].y, 0.0)
			tri(xf * (cc + hz), xf * (a + hz), xf * (b + hz), xf.basis.z, paint, pat, metal)
			tri(xf * (cc - hz), xf * (a - hz), xf * (b - hz), -xf.basis.z, paint, pat, metal)
			var e := b - a
			var on := Vector3(e.y, -e.x, 0.0).normalized()
			if on.dot(a - cc) < 0.0:
				on = -on
			quad(xf * (a - hz), xf * (b - hz), xf * (b + hz), xf * (a + hz), xf.basis * on, paint, pat, metal)

	## Low-poly sphere (lamp bulbs).
	func ball(c: Vector3, r: float, paint: Color) -> void:
		var rings := 5
		var segs := 8
		for i in rings:
			var t0 := PI * float(i) / float(rings)
			var t1 := PI * float(i + 1) / float(rings)
			for j in segs:
				var f0 := TAU * float(j) / float(segs)
				var f1 := TAU * float(j + 1) / float(segs)
				var d00 := Vector3(sin(t0) * cos(f0), cos(t0), sin(t0) * sin(f0))
				var d10 := Vector3(sin(t0) * cos(f1), cos(t0), sin(t0) * sin(f1))
				var d01 := Vector3(sin(t1) * cos(f0), cos(t1), sin(t1) * sin(f0))
				var d11 := Vector3(sin(t1) * cos(f1), cos(t1), sin(t1) * sin(f1))
				if i > 0:
					tri_s(c + d00 * r, c + d10 * r, c + d11 * r, d00, d10, d11, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, paint)
				if i < rings - 1:
					tri_s(c + d00 * r, c + d11 * r, c + d01 * r, d00, d11, d01, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, paint)

	func commit() -> ArrayMesh:
		return st.commit()


# =================================================================================================
# Context helpers: kits, collision, obstacles, ground
# =================================================================================================

static func _kit(c: Ctx, mat: String, vis := 0.0, shadow := true) -> Kit:
	var key := "%s|%d|%d" % [mat, int(vis), 1 if shadow else 0]
	if not c.kits.has(key):
		c.kits[key] = [Kit.new(), mat, vis, shadow]
	return c.kits[key][0]


static func _finish(c: Ctx) -> void:
	for key: String in c.kits:
		var e: Array = c.kits[key]
		var k: Kit = e[0]
		if k.count == 0:
			continue
		var mi := _place(c, k.commit(), _mat(e[1]), Transform3D.IDENTITY, e[2], e[3])
		mi.name = "Mesh_" + str(e[1])


static func _place(c: Ctx, mesh: Mesh, mat: Material, xf: Transform3D, vis := 0.0, shadow := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = xf
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if vis > 0.0:
		mi.visibility_range_end = vis
		mi.visibility_range_end_margin = 8.0
	c.root.add_child(mi)
	return mi


static func _body(c: Ctx) -> StaticBody3D:
	if c.body == null:
		c.body = StaticBody3D.new()
		c.body.name = "Collision"
		c.body.collision_layer = Game.LAYER_SHIP
		c.body.collision_mask = 0
		c.root.add_child(c.body)
	return c.body


static func _shape(c: Ctx, shape: Shape3D, xf: Transform3D) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = xf
	_body(c).add_child(cs)
	c.shapes += 1


## Box collider (size = full extents) at a site-local transform.
static func _box_shape(c: Ctx, xf: Transform3D, size: Vector3) -> void:
	var q := (size / 0.05).round() * 0.05
	var key := "b%s" % q
	if not _shapes.has(key):
		var b := BoxShape3D.new()
		b.size = q.max(Vector3.ONE * 0.05)
		_shapes[key] = b
	_shape(c, _shapes[key], xf)


## Cylinder (axis local y) or capsule collider.
static func _round_shape(c: Ctx, xf: Transform3D, r: float, h: float, capsule := false) -> void:
	var key := "%s%.2f_%.2f" % ["p" if capsule else "c", r, h]
	if not _shapes.has(key):
		if capsule:
			var cp := CapsuleShape3D.new()
			cp.radius = r
			cp.height = maxf(h, r * 2.0)
			_shapes[key] = cp
		else:
			var cy := CylinderShape3D.new()
			cy.radius = r
			cy.height = h
			_shapes[key] = cy
	_shape(c, _shapes[key], xf)


## A footprint the bots' crowd separation pushes them out of (site-local position).
static func _obstacle(c: Ctx, p: Vector3, r: float) -> void:
	var n := Node3D.new()
	n.name = "Obstacle"
	n.position = p
	n.add_to_group("poi_obstacle")
	n.set_meta("footprint_r", r)
	c.root.add_child(n)


## A shared prop set at a site-local transform: meshes, colliders, obstacles.
static func _place_set(c: Ctx, pset: Dictionary, xf: Transform3D, vis := 0.0) -> void:
	var meshes: Dictionary = pset["meshes"]
	for mk: String in meshes:
		_place(c, meshes[mk], _mat(mk), xf, vis, not mk.begins_with("glow"))
	for b: Array in pset.get("boxes", []):
		_box_shape(c, xf * (b[0] as Transform3D), b[1])
	for b: Array in pset.get("rounds", []):
		_round_shape(c, xf * (b[0] as Transform3D), b[1], b[2], b[3])
	for o: Array in pset.get("obst", []):
		_obstacle(c, xf * (o[0] as Vector3), o[1])


static func _set_of(kits: Dictionary, extra := {}) -> Dictionary:
	var meshes := {}
	for mk: String in kits:
		var k: Kit = kits[mk]
		if k.count > 0:
			meshes[mk] = k.commit()
	var s := {"meshes": meshes}
	s.merge(extra)
	return s


static func _corner(c: Ctx, v: Vector3i) -> float:
	var hit = c.vc.get(v)
	if hit != null:
		return hit
	var val := TerrainGen.NO_EDIT
	var arr = c.edits.get(Vector3i(v.x >> 4, v.y >> 4, v.z >> 4))
	if arr != null:
		val = (arr as PackedFloat32Array)[(v.x & 15) | ((v.y & 15) << 4) | ((v.z & 15) << 8)]
	if val >= TerrainGen.NO_EDIT * 0.5:
		var p := Vector3(v)
		var rr := maxf(p.length(), 1.0)
		var k := Vector3i((p / rr * c.q).round())
		var s = c.surf.get(k)
		if s == null:
			s = c.gen._surf((Vector3(k) / c.q).normalized())
			c.surf[k] = s
		val = c.gen._density(p, rr, s)
	c.vc[v] = val
	return val


## Edited density at body-local p (trilinear between the voxel corners, like the mesh).
static func _dens(c: Ctx, p: Vector3) -> float:
	var f := p.floor()
	var b := Vector3i(f)
	var t := p - f
	var x00 := lerpf(_corner(c, b), _corner(c, b + Vector3i(1, 0, 0)), t.x)
	var x10 := lerpf(_corner(c, b + Vector3i(0, 1, 0)), _corner(c, b + Vector3i(1, 1, 0)), t.x)
	var x01 := lerpf(_corner(c, b + Vector3i(0, 0, 1)), _corner(c, b + Vector3i(1, 0, 1)), t.x)
	var x11 := lerpf(_corner(c, b + Vector3i(0, 1, 1)), _corner(c, b + Vector3i(1, 1, 1)), t.x)
	return lerpf(lerpf(x00, x10, t.y), lerpf(x01, x11, t.y), t.z)


## The (edited) ground under body-local p along up, searched from `above` m over it down to `below`
## m under it; Vector3.INF: none.
static func _ground(c: Ctx, p: Vector3, up: Vector3, above := 3.0, below := 5.0) -> Vector3:
	var a := p + up * above
	if _dens(c, a) < 0.0:
		return a
	var n := int(ceil((above + below) / 0.3))
	for i in range(1, n + 1):
		var b := p + up * (above - (above + below) * float(i) / float(n))
		if _dens(c, b) < 0.0:
			var lo := a
			var hi := b
			for k in 7:
				var m := (lo + hi) * 0.5
				if _dens(c, m) < 0.0:
					hi = m
				else:
					lo = m
			return (lo + hi) * 0.5
		a = b
	return Vector3.INF


## Site-local frame on the edited ground under the site frame's (x, z): radial up, x near the frame's x.
static func _gnd(c: Ctx, x: float, z: float, above := 3.0, below := 5.0) -> Transform3D:
	var pb := c.frame * Vector3(x, 0.0, z)
	var up := pb.normalized()
	var g := _ground(c, pb, up, above, below)
	if g == Vector3.INF:
		g = pb
	var lup := (c.inv.basis * up).normalized()
	var lx := (Vector3.RIGHT - lup * lup.x).normalized()
	return Transform3D(Basis(lx, lup, lx.cross(lup)), c.inv * g)


static func _basis_y(y: Vector3) -> Basis:
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	return Basis(x, y, x.cross(y))


static func _yaw(yaw: float, p: Vector3) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw), p)


# =================================================================================================
# Materials
# =================================================================================================

static func _mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m: Material
	match key:
		"glow_warm":
			m = _glow(Color(1.0, 0.8, 0.55), 2.4)
		"glow_hot":
			m = _glow(Color(1.0, 0.42, 0.12), 2.2)
		"glow_red":
			m = _glow(Color(1.0, 0.18, 0.12), 3.0)
		"glow_amber":
			m = _glow(Color(1.0, 0.62, 0.2), 2.6)
		"glow_screen":
			m = _glow(Color(0.35, 0.85, 0.95), 1.4)
		_:
			var sm := ShaderMaterial.new()
			sm.shader = Shaders.shader("hull")
			match key:
				"ruin":
					sm.set_shader_parameter("grime", 0.5)
					sm.set_shader_parameter("wear", 0.95)
					sm.set_shader_parameter("soot", 0.3)
				"wreck":
					sm.set_shader_parameter("grime", 0.45)
					sm.set_shader_parameter("wear", 0.8)
					sm.set_shader_parameter("soot", 0.6)
					sm.set_shader_parameter("scorch", 0.3)
					sm.set_shader_parameter("ember", 0.32)
				_:
					sm.set_shader_parameter("grime", 0.3)
					sm.set_shader_parameter("wear", 0.6)
					sm.set_shader_parameter("soot", 0.06)
			m = sm
	_mats[key] = m
	return m


static func _glow(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col * 0.35
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	m.roughness = 0.4
	return m


## A landmark beacon: the halo billboard (blinks in its shader) and a lit bulb under it.
static func _beacon(c: Ctx, p: Vector3, tint: Color, blink: float) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Beacon"
	mi.mesh = DebrisMesh.quad_mesh()
	mi.material_override = DebrisMesh.halo_material(Color(tint.r, tint.g, tint.b, 1.0), 0.9, 0.0055, 0.0, blink)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 4.0
	mi.position = p
	c.root.add_child(mi)


# =================================================================================================
# Outpost
# =================================================================================================

static func _outpost(c: Ctx) -> void:
	var d := c.data
	var top: float = d.get("pad_top", 0.3)
	var bp: Vector2 = d["bunker"]
	var tp: Vector2 = d["tower"]
	_place_set(c, _bunker_set(), _yaw(d["bunker_yaw"], Vector3(bp.x, top - 0.04, bp.y)), MID_VIS)
	var h := clampf(float(c.pl.radius) * 0.3, Balance.POI_TOWER_H.x, Balance.POI_TOWER_H.y)
	var tw := _tower_set(h)
	var txf := _yaw(d["tower_yaw"], Vector3(tp.x, top - 0.08, tp.y))
	_place_set(c, tw, txf)
	_beacon(c, txf * (tw["top"] as Vector3), Color(1.0, 0.16, 0.1), Balance.POI_BEACON_BLINK)
	var k := _kit(c, "ruin", MID_VIS)
	for w: Array in d["walls"]:
		_wall(c, k, w[0], w[1], top)
	# The fallen antenna: a smaller mast lying outward through the gap between the bunker and the tower.
	var aa: float = d.get("antenna", 0.0)
	var rd := Vector2(cos(aa), sin(aa))
	var p0 := rd * 1.0
	var dir3 := Vector3(rd.x, 0.0, rd.y)
	var mlen := 5.4
	var side3 := Vector3.UP.cross(dir3)
	var mx := Transform3D(Basis(side3, dir3, side3.cross(dir3)), Vector3(p0.x, top + 0.5, p0.y))
	mx.basis = mx.basis * Basis(Vector3.UP, c.rng.randf() * TAU)
	_lattice(k, mx, mlen, 0.55, 0.22, 1.1, false)
	var mid := Vector3(p0.x, top + 0.45, p0.y) + dir3 * (mlen * 0.5)
	_box_shape(c, Transform3D(Basis(side3, Vector3.UP, dir3), mid), Vector3(1.0, 0.95, mlen))
	for i in 3:
		_obstacle(c, Vector3(p0.x, top + 0.5, p0.y) + dir3 * (0.9 + 1.8 * float(i)), 0.8)
	var dish_at := Vector3(p0.x, top + 0.25, p0.y) + dir3 * (mlen + 0.45)
	_dish(k, Transform3D(Basis(Vector3.RIGHT, -1.2) * Basis(Vector3.UP, c.rng.randf() * TAU), dish_at), 0.7, 0.24)
	# Crates in a few clusters on the free parts of the pad.
	var occ: Array = [[bp, 3.5], [tp, 2.6], [rd * 2.5, 1.6], [rd * 4.6, 1.6]]
	var placed := 0
	for t in 60:
		if placed >= 6:
			break
		var a := c.rng.randf() * TAU
		var p := Vector2(cos(a), sin(a)) * c.rng.randf_range(1.0, 6.2)
		var ok := true
		for o: Array in occ:
			if p.distance_to(o[0]) < float(o[1]) + 0.9:
				ok = false
				break
		if not ok:
			continue
		var kind := c.rng.randi_range(0, 2)
		var cs := _crate_set(kind)
		var yaw := c.rng.randf() * TAU
		_place_set(c, cs, _yaw(yaw, Vector3(p.x, top - 0.02, p.y)), NEAR_VIS)
		if kind != 2 and c.rng.randf() < 0.4:
			_place_set(c, _crate_set(1), _yaw(yaw + c.rng.randf_range(-0.4, 0.4), Vector3(p.x, top - 0.02 + float(cs["h"]), p.y)), NEAR_VIS)
		occ.append([p, 1.4 if kind == 2 else 1.0])
		placed += 1


## A broken freestanding wall from a to b (site-local xz) on the pad plane: composite slats on
## steel posts, some snapped off, a footing; a collider per slat.
static func _wall(c: Ctx, k: Kit, a: Vector2, b: Vector2, top: float) -> void:
	var dv := b - a
	var l := dv.length()
	var u := dv / maxf(l, 0.01)
	var mid := (a + b) * 0.5
	var xf := _yaw(atan2(-u.y, u.x), Vector3(mid.x, top, mid.y))
	var ns := maxi(int(ceil(l / 0.62)), 3)
	var w := l / float(ns)
	for i in ns:
		var x := -l * 0.5 + w * (float(i) + 0.5)
		var r := c.rng.randf()
		var h := 2.25 + c.rng.randf_range(-0.08, 0.08)
		if r < 0.28:
			h = c.rng.randf_range(0.7, 1.6)
		elif r < 0.36:
			h = c.rng.randf_range(0.18, 0.4)
		var lean := c.rng.randf_range(-0.06, 0.06) if h < 1.7 else 0.0
		k.box(xf * Transform3D(Basis(Vector3.BACK, lean), Vector3(x, h * 0.5 - 0.1, 0.0)), Vector3(w * 0.5 - 0.015, h * 0.5 + 0.1, 0.16),
				WHITE, 0.75, 0.04, 0.02)
		if h > 1.8:
			k.box(xf * Transform3D(Basis(), Vector3(x, 1.68, 0.0)), Vector3(w * 0.5 - 0.01, 0.07, 0.172), ORANGE, P_PLAIN, 0.04, 0.01)
		if h > 0.45:
			_box_shape(c, xf * Transform3D(Basis(), Vector3(x, h * 0.5 - 0.1, 0.0)), Vector3(w, h + 0.2, 0.32))
	for e: float in [-1.0, 1.0]:
		var pxf := xf * Transform3D(Basis(), Vector3(e * (l * 0.5 + 0.1), 1.15, 0.0))
		k.box(pxf, Vector3(0.11, 1.3, 0.21), STEEL, P_BRUSHED, 0.25, 0.02)
		_box_shape(c, pxf, Vector3(0.22, 2.6, 0.42))
	k.box(xf * Transform3D(Basis(), Vector3(0.0, 0.03, 0.0)), Vector3(l * 0.5 + 0.24, 0.14, 0.28), GRAPHITE, P_PLAIN, 0.0, 0.03)
	var no := maxi(int(round(l / 1.4)), 2)
	for i in no:
		_obstacle(c, xf * Vector3(-l * 0.5 + l * (float(i) + 0.5) / float(no), 1.0, 0.0), 0.75)


## A bunker part: a bevelled box (and its collider unless collide is false).
static func _bx(k: Kit, boxes: Array, pos: Vector3, half: Vector3, paint: Color, pat: float, metal := 0.0, collide := true,
		b := Basis()) -> void:
	var xf := Transform3D(b, pos)
	k.box(xf, half, paint, pat, metal, 0.025)
	if collide:
		boxes.append([xf, half * 2.0])


## The ruined prefab bunker (5.2 x 2.9 x 4.2 m): door (+z) and a window slit, the +x wall and half
## the roof caved in, a fallen door, a console and a locker inside.
static func _bunker_set() -> Dictionary:
	if _cache.has("bunker"):
		return _cache["bunker"]
	var k := Kit.new()
	var g := Kit.new()
	var s := Kit.new()
	var boxes: Array = []
	var w := 2.6
	var dd := 2.1
	var hh := 2.9
	var t := 0.22
	_bx(k, boxes, Vector3(0.0, 0.07, 0.0), Vector3(w, 0.07, dd), GRAPHITE, P_TREAD, 0.15)
	_bx(k, boxes, Vector3(0.0, hh * 0.5, -dd + t * 0.5), Vector3(w, hh * 0.5, t * 0.5), WHITE, 1.1)
	# Left wall with the window slit (z -1 .. 1, y 1.45 .. 1.85).
	_bx(k, boxes, Vector3(-w + t * 0.5, 0.725, 0.0), Vector3(t * 0.5, 0.725, dd - t), WHITE, 1.1)
	_bx(k, boxes, Vector3(-w + t * 0.5, (1.85 + hh) * 0.5, 0.0), Vector3(t * 0.5, (hh - 1.85) * 0.5, dd - t), WHITE, 1.1)
	for e: float in [-1.0, 1.0]:
		_bx(k, boxes, Vector3(-w + t * 0.5, 1.65, e * ((dd - t) + 1.0) * 0.5), Vector3(t * 0.5, 0.2, ((dd - t) - 1.0) * 0.5), WHITE, 1.1)
	# Right wall: snapped panels.
	var hs := [2.2, 1.9, 1.5, 1.15, 1.35, 1.75]
	var ws := (dd - t) * 2.0 / float(hs.size())
	for i in hs.size():
		var h: float = hs[i]
		_bx(k, boxes, Vector3(w - t * 0.5, h * 0.5, -(dd - t) + ws * (float(i) + 0.5)), Vector3(t * 0.5, h * 0.5, ws * 0.5 - 0.01), WHITE, 1.1)
	# Front wall around the door (x -1.6 .. -0.2, 2.2 m high), broken toward +x.
	_bx(k, boxes, Vector3((-w - 1.6) * 0.5, hh * 0.5, dd - t * 0.5), Vector3((w - 1.6) * 0.5, hh * 0.5, t * 0.5), WHITE, 1.1)
	_bx(k, boxes, Vector3(-0.9, (2.2 + hh) * 0.5, dd - t * 0.5), Vector3(0.7, (hh - 2.2) * 0.5, t * 0.5), WHITE, 1.1)
	_bx(k, boxes, Vector3(0.55, hh * 0.5, dd - t * 0.5), Vector3(0.75, hh * 0.5, t * 0.5), WHITE, 1.1)
	_bx(k, boxes, Vector3((1.3 + w - t) * 0.5, 0.95, dd - t * 0.5), Vector3((w - t - 1.3) * 0.5, 0.95, t * 0.5), WHITE, 1.1)
	# Roof: the intact half, the half that caved in toward +x.
	_bx(k, boxes, Vector3((-w + 0.3) * 0.5, hh + 0.1, 0.0), Vector3((w + 0.3) * 0.5, 0.1, dd + 0.05), GRAPHITE, 0.9)
	var rb := Basis(Vector3.BACK, -0.66)
	_bx(k, boxes, Vector3(0.3, hh, 0.0) + rb * Vector3(1.22, 0.1, 0.0), Vector3(1.22, 0.1, dd - 0.1), GRAPHITE, 0.9, 0.0, true, rb)
	# Trim: corner posts, the graphite skirt and the orange band on the standing walls.
	for p: Vector3 in [Vector3(-w, 1.52, -dd), Vector3(w, 1.52, -dd), Vector3(-w, 1.52, dd)]:
		_bx(k, boxes, p, Vector3(0.16, 1.52, 0.16), STEEL, P_BRUSHED, 0.25, false)
	_bx(k, boxes, Vector3(w, 0.95, dd), Vector3(0.16, 0.95, 0.16), STEEL, P_BRUSHED, 0.25, false)
	_bx(k, boxes, Vector3(0.0, 0.22, -dd - 0.015), Vector3(w - 0.17, 0.22, t * 0.5), GRAPHITE, P_PLAIN, 0.0, false)
	_bx(k, boxes, Vector3(-w - 0.015, 0.22, 0.0), Vector3(t * 0.5, 0.22, dd - 0.17), GRAPHITE, P_PLAIN, 0.0, false)
	_bx(k, boxes, Vector3(0.0, 2.35, -dd - 0.02), Vector3(w - 0.17, 0.1, t * 0.5), ORANGE, P_PLAIN, 0.0, false)
	_bx(k, boxes, Vector3(-w - 0.02, 2.35, 0.0), Vector3(t * 0.5, 0.1, dd - 0.17), ORANGE, P_PLAIN, 0.0, false)
	_bx(k, boxes, Vector3((-w - 1.6) * 0.5, 2.35, dd + 0.02), Vector3((w - 1.6) * 0.5 - 0.17, 0.1, t * 0.5), ORANGE, P_PLAIN, 0.0, false)
	# The door blown out onto the ground, a vent, an antenna stub, the lamp over the door.
	_bx(k, boxes, Vector3(-0.9, 0.05, dd + 1.35), Vector3(0.66, 0.04, 1.05), STEEL, 0.6, 0.2, false, Basis(Vector3.UP, 0.25) * Basis(Vector3.RIGHT, 0.05))
	_bx(k, boxes, Vector3(-1.6, hh + 0.35, -0.8), Vector3(0.35, 0.15, 0.35), STEEL, P_VENT, 0.2, false)
	k.rod(Vector3(-2.2, hh + 0.2, 1.6), Vector3(-2.15, hh + 1.7, 1.55), 0.03, 6, STEEL, P_PLAIN, 0.3)
	_bx(k, boxes, Vector3(-0.9, 2.42, dd + 0.12), Vector3(0.18, 0.06, 0.09), GRAPHITE, P_PLAIN, 0.0, false)
	g.box(Transform3D(Basis(), Vector3(-0.9, 2.355, dd + 0.13)), Vector3(0.14, 0.012, 0.06), Color(1, 1, 1), 0.0, 0.0, 0.005)
	# Inside: a toppled locker, a console with a dim screen.
	_bx(k, boxes, Vector3(-1.5, 0.4, -0.9), Vector3(0.9, 0.26, 0.3), GRAPHITE, 0.5, 0.0, true, Basis(Vector3.UP, 0.3))
	_bx(k, boxes, Vector3(-1.1, 0.55, -1.62), Vector3(0.6, 0.45, 0.28), GRAPHITE, P_PLAIN, 0.0, true)
	s.box(Transform3D(Basis(Vector3.RIGHT, -0.5), Vector3(-1.1, 1.02, -1.5)), Vector3(0.45, 0.012, 0.16), Color(1, 1, 1), 0.0, 0.0, 0.004)
	var obst: Array = []
	for p: Vector3 in [Vector3(-1.7, 1.0, -1.6), Vector3(0.0, 1.0, -1.6), Vector3(1.7, 1.0, -1.6), Vector3(-2.2, 1.0, 0.0),
			Vector3(2.2, 1.0, 0.0), Vector3(-1.9, 1.0, 1.7), Vector3(1.4, 1.0, 1.7)]:
		obst.append([p, 0.9])
	var pset := _set_of({"ruin": k, "glow_amber": g, "glow_screen": s}, {"boxes": boxes, "obst": obst})
	_cache["bunker"] = pset
	return pset


## The comm tower (LANDMARK): a three-legged lattice mast `h` m tall in orange / white aviation
## bands, a platform, a dish, panel antennas, a whip with the red light ("top": the beacon point).
static func _tower_set(h: float) -> Dictionary:
	var key := "tower%d" % int(h * 10.0)
	if _cache.has(key):
		return _cache[key]
	var k := Kit.new()
	var g := Kit.new()
	var rb := 1.3
	var rt := 0.36
	_lattice(k, Transform3D.IDENTITY, h, rb, rt, 1.6, true)
	var boxes: Array = []
	for i in 3:
		var a := TAU * float(i) / 3.0
		var b0 := Vector3(cos(a) * rb, 0.0, sin(a) * rb)
		var t0 := Vector3(cos(a) * rt, h, sin(a) * rt)
		k.box(Transform3D(Basis(), b0 + Vector3(0.0, 0.12, 0.0)), Vector3(0.32, 0.22, 0.32), GRAPHITE, P_PLAIN, 0.0, 0.03)
		boxes.append([Transform3D(_basis_y((t0 - b0).normalized()), (b0 + t0) * 0.5), Vector3(0.24, b0.distance_to(t0), 0.24)])
	# Equipment cabinet at the foot.
	var cab := Transform3D(Basis(), Vector3(rb + 0.9, 0.7, 0.0))
	k.box(cab, Vector3(0.42, 0.7, 0.32), WHITE, 0.6, 0.05, 0.03)
	k.box(cab * Transform3D(Basis(), Vector3(0.0, 0.25, 0.325)), Vector3(0.34, 0.3, 0.012), STEEL, P_VENT, 0.2, 0.005)
	boxes.append([cab, Vector3(0.84, 1.4, 0.64)])
	# Platform with a railing.
	var py := h * 0.72
	var pr := lerpf(rb, rt, 0.72) + 0.75
	k.cyl(Transform3D(Basis(), Vector3(0.0, py - 0.05, 0.0)), pr, pr, 0.08, 6, STEEL, P_TREAD, 0.2)
	for i in 6:
		var a0 := TAU * float(i) / 6.0
		var a1 := TAU * float(i + 1) / 6.0
		var q0 := Vector3(cos(a0) * pr, py, sin(a0) * pr)
		var q1 := Vector3(cos(a1) * pr, py, sin(a1) * pr)
		k.rod(q0, q0 + Vector3(0.0, 1.0, 0.0), 0.025, 5, STEEL)
		k.rod(q0 + Vector3(0.0, 1.0, 0.0), q1 + Vector3(0.0, 1.0, 0.0), 0.022, 5, STEEL)
	# Dish on one face, tilted up.
	var dr := lerpf(rb, rt, 0.62)
	var dish_at := Vector3(-dr - 0.55, h * 0.62, 0.0)
	_dish(k, Transform3D(Basis(Vector3.UP, PI * 0.5) * Basis(Vector3.RIGHT, 0.3), dish_at), 0.95, 0.32)
	k.rod(dish_at + Vector3(0.35, 0.0, 0.0), Vector3(-dr * 0.5, h * 0.62, 0.0), 0.05, 6, STEEL)
	# Panel antennas.
	for i in 3:
		var a := TAU * (float(i) + 0.5) / 3.0
		var ar := lerpf(rb, rt, 0.86) * 0.5 + 0.3
		k.box(Transform3D(Basis(Vector3.UP, -a), Vector3(cos(a) * ar, h * 0.86, sin(a) * ar)), Vector3(0.05, 0.62, 0.14), WHITE, P_PLAIN, 0.0, 0.02)
	# Whip, the light housing and the bulb.
	k.rod(Vector3(0.0, h - 0.2, 0.0), Vector3(0.0, h + 2.2, 0.0), 0.04, 6, STEEL, P_PLAIN, 0.3)
	k.cyl(Transform3D(Basis(), Vector3(0.0, h + 2.15, 0.0)), 0.11, 0.09, 0.14, 8, DARK)
	g.ball(Vector3(0.0, h + 2.38, 0.0), 0.12, Color(1, 1, 1))
	var pset := _set_of({"ruin": k, "glow_red": g}, {"boxes": boxes, "obst": [[Vector3(0.0, 1.0, 0.0), 1.7]],
			"top": Vector3(0.0, h + 2.42, 0.0)})
	_cache[key] = pset
	return pset


## A three-legged lattice mast along local +y (0 .. h) under xf: legs from base circumradius rb to rt,
## zig-zag bracing every `step` m; banded = orange / white aviation bands on the legs.
static func _lattice(k: Kit, xf: Transform3D, h: float, rb: float, rt: float, step: float, banded: bool) -> void:
	var legs: Array = []
	for i in 3:
		var a := TAU * float(i) / 3.0
		legs.append([Vector3(cos(a) * rb, 0.0, sin(a) * rb), Vector3(cos(a) * rt, h, sin(a) * rt)])
	var nb := 7
	for i in 3:
		var b0: Vector3 = legs[i][0]
		var t0: Vector3 = legs[i][1]
		for s in nb:
			var col := (ORANGE if s % 2 == 0 else WHITE) if banded else STEEL
			k.rod(xf * b0.lerp(t0, float(s) / float(nb)), xf * b0.lerp(t0, float(s + 1) / float(nb)),
					0.075 * (1.0 - 0.35 * float(s) / float(nb)), 8, col, P_PLAIN, 0.1, s == nb - 1)
	var levels := int(h / step)
	for l in levels + 1:
		var y0 := float(l) * step / h
		var y1 := minf(float(l + 1) * step / h, 1.0)
		for i in 3:
			var j := (i + 1) % 3
			var pi0: Vector3 = (legs[i][0] as Vector3).lerp(legs[i][1], y0)
			var pj0: Vector3 = (legs[j][0] as Vector3).lerp(legs[j][1], y0)
			k.rod(xf * pi0, xf * pj0, 0.028, 5, STEEL, P_PLAIN, 0.2)
			if l < levels:
				var pi1: Vector3 = (legs[i][0] as Vector3).lerp(legs[i][1], y1)
				var pj1: Vector3 = (legs[j][0] as Vector3).lerp(legs[j][1], y1)
				if l % 2 == 0:
					k.rod(xf * pi0, xf * pj1, 0.024, 5, STEEL, P_PLAIN, 0.2)
				else:
					k.rod(xf * pj0, xf * pi1, 0.024, 5, STEEL, P_PLAIN, 0.2)


## A parabolic dish (radius r, depth dep) opening along local -z under xf: front and back shells,
## a rim, a feed arm.
static func _dish(k: Kit, xf: Transform3D, r: float, dep: float) -> void:
	var rings := 5
	var segs := 16
	var pts: Array = []
	for i in rings + 1:
		var row: Array = []
		var rr := r * float(i) / float(rings)
		var z := -dep * pow(float(i) / float(rings), 2.0)
		for j in segs:
			var a := TAU * float(j) / float(segs)
			row.append(Vector3(cos(a) * rr, sin(a) * rr, z))
		pts.append(row)
	for i in rings:
		for j in segs:
			var j1 := (j + 1) % segs
			var a: Vector3 = pts[i][j]
			var b: Vector3 = pts[i][j1]
			var c: Vector3 = pts[i + 1][j1]
			var d: Vector3 = pts[i + 1][j]
			var n := (b - a).cross(d - a)
			if i == 0:
				n = (c - a).cross(d - a)
			n = n.normalized()
			if n.z > 0.0:
				n = -n
			var nb := xf.basis * n
			# Front (concave, facing -z) and back (+z), the back a little behind.
			var o := Vector3(0.0, 0.0, 0.035)
			if i > 0:
				k.quad(xf * a, xf * b, xf * c, xf * d, nb, WHITE, P_PLAIN, 0.05)
				k.quad(xf * (a + o), xf * (b + o), xf * (c + o), xf * (d + o), -nb, GRAPHITE, P_PLAIN, 0.1)
			else:
				k.tri(xf * a, xf * c, xf * d, nb, WHITE, P_PLAIN, 0.05)
				k.tri(xf * (a + o), xf * (c + o), xf * (d + o), -nb, GRAPHITE, P_PLAIN, 0.1)
	for j in segs:
		var j1 := (j + 1) % segs
		var a: Vector3 = pts[rings][j]
		var b: Vector3 = pts[rings][j1]
		var out := ((a + b) * 0.5 * Vector3(1.0, 1.0, 0.0)).normalized()
		k.quad(xf * a, xf * b, xf * (b + Vector3(0.0, 0.0, 0.035)), xf * (a + Vector3(0.0, 0.0, 0.035)), xf.basis * out, STEEL)
	k.rod(xf * Vector3(0.0, 0.0, -dep), xf * Vector3(0.0, 0.0, -dep - r * 0.75), 0.025, 5, STEEL)
	k.box(xf * Transform3D(Basis(), Vector3(0.0, 0.0, -dep - r * 0.8)), Vector3(0.07, 0.07, 0.1), DARK, P_PLAIN, 0.0, 0.01)


## Cargo crates (origin at the bottom centre; "h": height): 0 orange 1.2 m, 1 white 1.0 m,
## 2 a graphite 2.4 m container.
static func _crate_set(kind: int) -> Dictionary:
	var key := "crate%d" % kind
	if _cache.has(key):
		return _cache[key]
	var half: Vector3 = [Vector3(0.6, 0.6, 0.6), Vector3(0.5, 0.5, 0.5), Vector3(1.2, 0.62, 0.62)][kind]
	var paint: Color = [ORANGE, WHITE, GRAPHITE][kind]
	var k := Kit.new()
	k.box(Transform3D(Basis(), Vector3(0.0, half.y, 0.0)), half - Vector3(0.025, 0.025, 0.025), paint, 0.55 if kind < 2 else 0.8, 0.05, 0.03)
	var e := 0.045
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			k.box(Transform3D(Basis(), Vector3(sx * (half.x - e), half.y, sz * (half.z - e))), Vector3(e, half.y, e), DARK, P_PLAIN, 0.2, 0.012)
		for y: float in [e, half.y * 2.0 - e]:
			k.box(Transform3D(Basis(), Vector3(sx * (half.x - e), y, 0.0)), Vector3(e, e, half.z - e * 2.0), DARK, P_PLAIN, 0.2, 0.012)
			k.box(Transform3D(Basis(), Vector3(0.0, y, sx * (half.z - e))), Vector3(half.x - e * 2.0, e, e), DARK, P_PLAIN, 0.2, 0.012)
	k.box(Transform3D(Basis(), Vector3(0.0, half.y * 1.42, 0.0)), Vector3(half.x - 0.02, 0.07, half.z + 0.004), YELLOW, P_HAZARD, 0.0, 0.008)
	k.box(Transform3D(Basis(), Vector3(half.x * 0.35, half.y * 0.8, half.z + 0.004)), Vector3(half.x * 0.3, half.y * 0.18, 0.008),
			WHITE if kind != 1 else GRAPHITE, P_PLAIN, 0.0, 0.004)
	var pset := _set_of({"kit": k}, {"boxes": [[Transform3D(Basis(), Vector3(0.0, half.y, 0.0)), half * 2.0]],
			"obst": [[Vector3(0.0, half.y, 0.0), maxf(half.x, half.z) + 0.3]], "h": half.y * 2.0})
	_cache[key] = pset
	return pset


# =================================================================================================
# Crash site
# =================================================================================================

static func _crash(c: Ctx) -> void:
	var d := c.data
	var hull: Transform3D = d["hull"]
	var hs := _hull_set()
	_place_set(c, hs, hull)
	_beacon(c, hull * (hs["top"] as Vector3), Color(1.0, 0.55, 0.12), Balance.POI_BEACON_BLINK * 0.6)
	# Fire and smoke from the torn tail (the plume shows from far away), a warm light in it.
	var fire_at: Vector3 = hull * (hs["fire"] as Vector3)
	var up := Vector3.UP
	_fire(c, fire_at, up)
	_smoke(c, fire_at + up * 1.2, up)
	var lt := OmniLight3D.new()
	lt.light_color = Color(1.0, 0.55, 0.25)
	lt.light_energy = 1.5
	lt.omni_range = 8.0
	lt.shadow_enabled = false
	lt.position = fire_at + up * 0.9
	c.root.add_child(lt)
	# The engine nacelle thrown off to one side, half buried.
	var side := 1.0 if c.rng.randf() < 0.5 else -1.0
	var eng := Vector2(side * c.rng.randf_range(6.5, 8.0), c.rng.randf_range(-6.0, -1.0))
	var g := _gnd(c, eng.x, eng.y)
	var exf := g * Transform3D(Basis(Vector3.UP, c.rng.randf() * TAU) * Basis(Vector3.RIGHT, c.rng.randf_range(-0.25, 0.1)),
			Vector3(0.0, 0.5, 0.0))
	_place_set(c, _engine_set(), exf, MID_VIS)
	var k := _kit(c, "wreck", MID_VIS)
	var kn := _kit(c, "wreck", NEAR_VIS)
	var kg := _kit(c, "glow_hot", NEAR_VIS, false)
	# The torn-off wing stuck edge-down in the ground on the other side.
	var wg := _gnd(c, -side * c.rng.randf_range(5.5, 7.0), c.rng.randf_range(-2.0, 4.0))
	var wxf := wg * Transform3D(Basis(Vector3.UP, c.rng.randf() * TAU) * Basis(Vector3.RIGHT, c.rng.randf_range(0.9, 1.25)),
			Vector3(0.0, -0.7, 0.0))
	var wing := PackedVector2Array([Vector2(-2.2, 0.0), Vector2(2.2, 0.0), Vector2(1.8, 1.9), Vector2(-1.6, 2.3)])
	k.slab(wxf, wing, 0.28, WHITE, 1.2, 0.05)
	k.box(wxf * Transform3D(Basis(), Vector3(0.0, 2.05, 0.0)), Vector3(1.6, 0.12, 0.16), ORANGE, P_PLAIN, 0.05, 0.02)
	_box_shape(c, wxf * Transform3D(Basis(), Vector3(0.0, 1.1, 0.0)), Vector3(4.2, 2.3, 0.32))
	_obstacle(c, wxf * Vector3(0.0, 1.0, 0.0), 1.6)
	# Debris: bent plates, chunks and frame ribs over the furrow and around; the big ones are cover.
	var n := c.rng.randi_range(13, 17)
	for i in n:
		for t in 20:
			var x := c.rng.randf_range(-8.5, 8.5)
			var z := c.rng.randf_range(-20.0, 11.0)
			if absf(x) < 3.4 and z > -8.5 and z < 9.5:
				continue
			if Vector2(x, z).distance_to(eng) < 2.6:
				continue
			var gp := _gnd(c, x, z)
			var big := i < 4
			var sz := c.rng.randf_range(1.4, 2.2) if big else c.rng.randf_range(0.45, 1.3)
			var bas := Basis(Vector3.UP, c.rng.randf() * TAU) * Basis(Vector3.RIGHT, c.rng.randf_range(-0.7, 0.7)) \
					* Basis(Vector3.BACK, c.rng.randf_range(-0.5, 0.5))
			var xf := gp * Transform3D(bas, Vector3(0.0, sz * 0.08, 0.0))
			var kk := k if big else kn
			var r := c.rng.randf()
			var paint: Color = [WHITE, WHITE, ORANGE, GRAPHITE][c.rng.randi_range(0, 3)]
			var pat := P_TILES if paint == GRAPHITE else 1.0
			if r < 0.55 or big:
				# A bent hull plate: two halves at a crease.
				var crease := c.rng.randf_range(0.25, 0.7)
				kk.box(xf * Transform3D(Basis(), Vector3(-sz * 0.25, 0.0, 0.0)), Vector3(sz * 0.25, 0.04, sz * 0.36), paint, pat, 0.05, 0.015)
				kk.box(xf * Transform3D(Basis(Vector3.BACK, crease), Vector3.ZERO) * Transform3D(Basis(), Vector3(sz * 0.25, 0.0, 0.0)),
						Vector3(sz * 0.25, 0.04, sz * 0.36), paint, pat, 0.05, 0.015)
				if big:
					_box_shape(c, xf * Transform3D(Basis(), Vector3(0.0, sz * 0.12, 0.0)), Vector3(sz, sz * 0.3, sz * 0.72))
					_obstacle(c, xf.origin, sz * 0.55)
			elif r < 0.85:
				kk.box(xf, Vector3(sz * 0.35, sz * 0.22, sz * 0.3), [STEEL, DARK][c.rng.randi_range(0, 1)], P_PLAIN, 0.3, 0.03)
			else:
				var a := xf * Vector3(-sz * 0.7, 0.05, 0.0)
				var m := xf * Vector3(0.0, sz * 0.25, 0.1)
				var b := xf * Vector3(sz * 0.7, 0.1, 0.25)
				kk.rod(a, m, 0.055, 6, STEEL, P_PLAIN, 0.3, true)
				kk.rod(m, b, 0.055, 6, STEEL, P_PLAIN, 0.3, true)
			if i % 4 == 1:
				# A still-hot shard beside it.
				kg.box(xf * Transform3D(Basis(Vector3.UP, 0.7), Vector3(sz * 0.5, 0.05, 0.2)), Vector3(0.14, 0.05, 0.1), Color(1, 1, 1), 0.0, 0.0, 0.01)
			break


## The crashed hull (16 m, nose +z): a lofted superellipse hull, white panelling with an orange band,
## heat tiles on the belly, cockpit windows, the torn-open tail (inner skin, bulkhead, broken ribs,
## glowing edges), the tail fin (LANDMARK; "top": its beacon point) and the stub of one wing.
static func _hull_set() -> Dictionary:
	if _cache.has("hull"):
		return _cache["hull"]
	var k := Kit.new()
	var g := Kit.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var nz := HULL_Z.size()
	var jag: Array = []
	for j in HULL_SEGS:
		jag.append([rng.randf_range(0.0, 1.3), rng.randf_range(0.92, 1.06)])
	var pts: Array = []
	var inner: Array = []
	for i in nz:
		var z: float = HULL_Z[i]
		var sec := _hull_sec(z)
		var row: Array = []
		var irow: Array = []
		for j in HULL_SEGS:
			var a := TAU * float(j) / float(HULL_SEGS)
			var sz := sec
			var zz := z
			if i == 0:
				zz -= float(jag[j][0])
				sz = Vector3(sec.x * float(jag[j][1]), sec.y * float(jag[j][1]), sec.z)
			var p := _se(a, sz, zz)
			row.append(p)
			if i <= HULL_INNER:
				var kk := 1.0 - 0.12 / ((sz.x + sz.y) * 0.5)
				irow.append(Vector3(p.x * kk, sz.z + (p.y - sz.z) * kk, zz))
		pts.append(row)
		if i <= HULL_INNER:
			inner.append(irow)
	# Outer skin, smooth normals from the neighbours.
	var norms: Array = []
	for i in nz:
		var nrow: Array = []
		for j in HULL_SEGS:
			var pa: Vector3 = pts[i][(j + 1) % HULL_SEGS]
			var pb: Vector3 = pts[i][(j - 1 + HULL_SEGS) % HULL_SEGS]
			var pc: Vector3 = pts[mini(i + 1, nz - 1)][j]
			var pd: Vector3 = pts[maxi(i - 1, 0)][j]
			var n := (pa - pb).cross(pc - pd).normalized()
			var p: Vector3 = pts[i][j]
			var sec := _hull_sec(p.z)
			if n.dot(Vector3(p.x, p.y - sec.z, 0.0)) < 0.0:
				n = -n
			nrow.append(n)
		norms.append(nrow)
	for i in nz - 1:
		for j in HULL_SEGS:
			var j1 := (j + 1) % HULL_SEGS
			var a: Vector3 = pts[i][j]
			var b: Vector3 = pts[i][j1]
			var cc: Vector3 = pts[i + 1][j1]
			var dd: Vector3 = pts[i + 1][j]
			var zc := (a.z + cc.z) * 0.5
			var ang := TAU * (float(j) + 0.5) / float(HULL_SEGS)
			var sn := sin(ang)
			var paint := WHITE
			var pat := 1.4
			var metal := 0.05
			if sn < -0.55:
				paint = GRAPHITE
				pat = P_TILES
			elif zc > 4.5 and zc < 6.2 and sn > 0.55:
				paint = WINDOW
				pat = P_PLAIN
				metal = 0.0
			elif zc > 1.0 and zc < 2.0:
				paint = ORANGE
			elif zc >= 2.0 and zc < 2.15:
				paint = GRAPHITE
				pat = P_PLAIN
			var ra := 2.5
			var ua := Vector2(float(j) / float(HULL_SEGS) * TAU * ra, a.z)
			var ub := Vector2(float(j + 1) / float(HULL_SEGS) * TAU * ra, b.z)
			var uc := Vector2(float(j + 1) / float(HULL_SEGS) * TAU * ra, cc.z)
			var ud := Vector2(float(j) / float(HULL_SEGS) * TAU * ra, dd.z)
			k.tri_s(a, b, cc, norms[i][j], norms[i][j1], norms[i + 1][j1], ua, ub, uc, paint, pat, metal)
			k.tri_s(a, cc, dd, norms[i][j], norms[i + 1][j1], norms[i + 1][j], ua, uc, ud, paint, pat, metal)
	# The torn section: the inner skin (facing the axis), the lip, the bulkhead, broken ribs.
	for i in HULL_INNER:
		for j in HULL_SEGS:
			var j1 := (j + 1) % HULL_SEGS
			var a: Vector3 = inner[i][j]
			var b: Vector3 = inner[i][j1]
			var cc: Vector3 = inner[i + 1][j1]
			var dd: Vector3 = inner[i + 1][j]
			var sec := _hull_sec((a.z + cc.z) * 0.5)
			var n := -Vector3((a.x + cc.x) * 0.5, (a.y + cc.y) * 0.5 - sec.z, 0.0).normalized()
			k.quad(a, b, cc, dd, n, INSIDE, 0.6, 0.05)
	for j in HULL_SEGS:
		var j1 := (j + 1) % HULL_SEGS
		k.quad(pts[0][j], pts[0][j1], inner[0][j1], inner[0][j], Vector3(0.0, 0.0, -1.0), DARK)
		if j % 3 == 0:
			var e: Vector3 = pts[0][j]
			g.box(Transform3D(Basis(Vector3.BACK, float(j)), e + Vector3(0.0, 0.0, 0.05)), Vector3(0.09, 0.06, 0.12) * rng.randf_range(0.8, 1.8),
					Color(1, 1, 1), 0.0, 0.0, 0.01)
	var bz: float = HULL_Z[HULL_INNER]
	var bc := Vector3(0.0, _hull_sec(bz).z, bz)
	for j in HULL_SEGS:
		k.tri(bc, inner[HULL_INNER][j], inner[HULL_INNER][(j + 1) % HULL_SEGS], Vector3(0.0, 0.0, -1.0), INSIDE, 0.5, 0.05)
	for i: int in [1, 2]:
		for j in HULL_SEGS:
			if rng.randf() < 0.35:
				continue
			var a: Vector3 = inner[i][j]
			var b: Vector3 = inner[i][(j + 1) % HULL_SEGS]
			k.rod(a * Vector3(0.96, 1.0, 1.0), b * Vector3(0.96, 1.0, 1.0), 0.06, 5, STEEL, P_PLAIN, 0.25, true)
	# Tail fin: white with an orange tip, a steel leading edge.
	var fin_xf := Transform3D(Basis(Vector3(0.0, 0.0, 1.0), Vector3(0.0, 1.0, 0.0), Vector3(-1.0, 0.0, 0.0)), Vector3.ZERO)
	k.slab(fin_xf, PackedVector2Array([Vector2(-2.2, 1.9), Vector2(-6.4, 1.9), Vector2(-7.46, 7.7), Vector2(-5.3, 7.7)]), 0.26, WHITE, 1.0, 0.05)
	k.slab(fin_xf, PackedVector2Array([Vector2(-5.3, 7.7), Vector2(-7.46, 7.7), Vector2(-7.7, 9.0), Vector2(-6.0, 9.0)]), 0.24, ORANGE, P_PLAIN, 0.05)
	k.rod(Vector3(0.0, 1.9, -2.2), Vector3(0.0, 9.0, -6.0), 0.1, 6, STEEL, P_BRUSHED, 0.3, true)
	k.box(Transform3D(Basis(), Vector3(0.0, 4.2, -5.0)), Vector3(0.14, 0.3, 1.05), YELLOW, P_HAZARD, 0.0, 0.01)
	# The wing on the high side, the torn stub on the other.
	var wing_xf := Transform3D(Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0)), Vector3(0.0, -0.7, 0.0))
	k.slab(wing_xf, PackedVector2Array([Vector2(2.3, -2.0), Vector2(2.3, 3.4), Vector2(6.6, 4.6), Vector2(6.6, 2.8)]), 0.3, WHITE, 1.2, 0.05)
	k.slab(wing_xf, PackedVector2Array([Vector2(-2.3, -1.5), Vector2(-2.3, 2.5), Vector2(-3.4, 2.6), Vector2(-3.6, -0.6)]), 0.3, GRAPHITE, P_TILES, 0.05)
	var boxes: Array = [[Transform3D(Basis(), Vector3(0.0, 5.4, -5.3)), Vector3(0.3, 7.0, 3.4)],
			[Transform3D(Basis(), Vector3(4.45, -0.7, -1.3)), Vector3(4.3, 0.32, 4.4)]]
	var rounds: Array = [[Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, -0.02, 0.4)), 2.4, 15.0, true]]
	var obst: Array = []
	for z: float in [-5.5, -2.5, 0.5, 3.5, 6.5]:
		obst.append([Vector3(0.0, 0.0, z), 2.7])
	var pset := _set_of({"wreck": k, "glow_hot": g}, {"boxes": boxes, "rounds": rounds, "obst": obst,
			"top": Vector3(0.0, 9.25, -6.85), "fire": Vector3(0.0, -0.4, -5.6)})
	_cache["hull"] = pset
	return pset


## Hull section at z: (half width, half height, centre y), Catmull-Rom through HULL_KEYS.
static func _hull_sec(z: float) -> Vector3:
	var n := HULL_KEYS.size()
	if z <= float(HULL_KEYS[0][0]):
		return Vector3(HULL_KEYS[0][1], HULL_KEYS[0][2], HULL_KEYS[0][3])
	for i in n - 1:
		var z0: float = HULL_KEYS[i][0]
		var z1: float = HULL_KEYS[i + 1][0]
		if z <= z1:
			var t := (z - z0) / (z1 - z0)
			var out := Vector3.ZERO
			for c in 3:
				var p0: float = HULL_KEYS[maxi(i - 1, 0)][c + 1]
				var p1: float = HULL_KEYS[i][c + 1]
				var p2: float = HULL_KEYS[i + 1][c + 1]
				var p3: float = HULL_KEYS[mini(i + 2, n - 1)][c + 1]
				out[c] = 0.5 * (2.0 * p1 + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
						+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t)
			return out
	return Vector3(HULL_KEYS[n - 1][1], HULL_KEYS[n - 1][2], HULL_KEYS[n - 1][3])


## Superellipse hull point at angle a (0 = +x, PI / 2 = top) of section (half w, half h, centre y).
static func _se(a: float, sec: Vector3, z: float) -> Vector3:
	var co := cos(a)
	var si := sin(a)
	var e := 2.0 / 2.4
	return Vector3(sec.x * signf(co) * pow(absf(co), e), sec.z + sec.y * signf(si) * pow(absf(si), e), z)


## The engine nacelle thrown off the wreck (axis z, 4.3 m): panelled body, orange band, a scorched
## nozzle still glowing inside, the intake, the torn pylon.
static func _engine_set() -> Dictionary:
	if _cache.has("engine"):
		return _cache["engine"]
	var k := Kit.new()
	var g := Kit.new()
	var along := Basis(Vector3.RIGHT, PI * 0.5)
	k.cyl(Transform3D(along, Vector3(0.0, 0.0, -1.7)), 0.95, 0.9, 3.4, 20, WHITE, 0.8, 0.05)
	k.cyl(Transform3D(along, Vector3(0.0, 0.0, 0.45)), 0.975, 0.975, 0.35, 20, ORANGE, P_PLAIN, 0.05, false)
	k.cyl(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.0, 0.0, -1.7)), 0.82, 1.03, 0.9, 20, STEEL, P_BRUSHED, 0.3, false)
	k.cyl(Transform3D(along, Vector3(0.0, 0.0, -1.78)), 0.8, 0.8, 0.06, 16, DARK)
	k.cyl(Transform3D(along, Vector3(0.0, 0.0, 1.7)), 0.98, 0.88, 0.3, 20, DARK, P_PLAIN, 0.2, false)
	k.cyl(Transform3D(along, Vector3(0.0, 0.0, 1.85)), 0.5, 0.5, 0.05, 12, STEEL, P_VENT, 0.2)
	k.box(Transform3D(Basis(), Vector3(0.0, 1.05, 0.2)), Vector3(0.15, 0.32, 0.8), GRAPHITE, 0.6, 0.05, 0.03)
	g.cyl(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.0, 0.0, -1.81)), 0.55, 0.55, 0.02, 12, Color(1, 1, 1))
	var pset := _set_of({"wreck": k, "glow_hot": g}, {"rounds": [[Transform3D(along, Vector3(0.0, 0.0, -0.05)), 1.0, 4.4, false]],
			"obst": [[Vector3(0.0, 0.0, -1.2), 1.3], [Vector3(0.0, 0.0, 1.2), 1.3]]})
	_cache["engine"] = pset
	return pset


static func _smoke(c: Ctx, p: Vector3, up: Vector3) -> void:
	var gp := GPUParticles3D.new()
	gp.name = "Smoke"
	gp.amount = 28
	gp.lifetime = 9.0
	gp.preprocess = 6.0
	gp.local_coords = false
	gp.visibility_aabb = AABB(Vector3(-9.0, -2.0, -9.0), Vector3(18.0, 32.0, 18.0))
	gp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 12.0
	pm.initial_velocity_min = 0.9
	pm.initial_velocity_max = 1.5
	# (global space, local_coords off: a slow buoyant rise along the planet's up here)
	pm.gravity = (c.pl.global_transform.basis * (c.frame.basis * up)).normalized() * 0.18
	pm.damping_min = 0.02
	pm.damping_max = 0.08
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.7
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.45))
	sc.add_point(Vector2(1.0, 1.0))
	sc.max_value = 1.0
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var gr := Gradient.new()
	gr.offsets = PackedFloat32Array([0.0, 0.12, 0.6, 1.0])
	gr.colors = PackedColorArray([Color(0.2, 0.19, 0.18, 0.0), Color(0.22, 0.21, 0.2, 0.5), Color(0.3, 0.29, 0.28, 0.3),
			Color(0.34, 0.33, 0.32, 0.0)])
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	pm.color_ramp = gt
	gp.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(5.0, 5.0)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	gp.draw_pass_1 = q
	gp.transform = Transform3D(_basis_y(up), p)
	c.root.add_child(gp)


static func _fire(c: Ctx, p: Vector3, up: Vector3) -> void:
	var gp := GPUParticles3D.new()
	gp.name = "Fire"
	gp.amount = 18
	gp.lifetime = 0.75
	gp.local_coords = false
	gp.visibility_aabb = AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 4.0, 4.0))
	gp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 18.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.2
	pm.gravity = (c.pl.global_transform.basis * (c.frame.basis * up)).normalized() * 1.2
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.45
	pm.scale_min = 0.7
	pm.scale_max = 1.2
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 1.0))
	sc.add_point(Vector2(1.0, 0.25))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var gr := Gradient.new()
	gr.offsets = PackedFloat32Array([0.0, 0.15, 0.6, 1.0])
	gr.colors = PackedColorArray([Color(1.0, 0.85, 0.45, 0.0), Color(1.0, 0.6, 0.2, 0.85), Color(0.8, 0.22, 0.05, 0.5),
			Color(0.3, 0.08, 0.02, 0.0)])
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	pm.color_ramp = gt
	gp.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 0.9)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	gp.draw_pass_1 = q
	gp.transform = Transform3D(_basis_y(up), p)
	c.root.add_child(gp)


# =================================================================================================
# Trench and tunnel fittings
# =================================================================================================

static func _trench(c: Ctx) -> void:
	var segs: Array = c.data.get("segs", [])
	var bs := _barrier_set()
	for i in range(1, segs.size() - 1):
		var e: Array = segs[i]
		var a: Vector3 = e[0]
		var b: Vector3 = e[1]
		var up: Vector3 = e[2]
		var x: Vector3 = e[3]
		var sf: float = e[4]
		for t: float in ([0.32, 0.72] if i % 2 == 1 else [0.5]):
			var p := a.lerp(b, t) + x * sf * 2.75
			var g := _ground(c, p, up, 2.5, 2.5)
			if g == Vector3.INF:
				continue
			var along := (b - a)
			along = (along - up * along.dot(up)).normalized()
			var bxf := c.inv * Transform3D(Basis(along, up, along.cross(up)), g - up * 0.06)
			_place_set(c, bs, bxf, NEAR_VIS)
	# A supply point behind the line.
	if segs.size() >= 3:
		var e: Array = segs[segs.size() / 2]
		var up: Vector3 = e[2]
		var p: Vector3 = (e[0] as Vector3).lerp(e[1], 0.5) - (e[3] as Vector3) * float(e[4]) * 4.6
		var g := _ground(c, p, up, 2.5, 2.5)
		if g != Vector3.INF:
			var yaw := c.rng.randf() * TAU
			var lxf := c.inv * Transform3D(Basis(), g)
			var lup := (c.inv.basis * up).normalized()
			var lx := (Vector3.RIGHT - lup * lup.x).normalized()
			lxf.basis = Basis(lx, lup, lx.cross(lup)) * Basis(Vector3.UP, yaw)
			_place_set(c, _crate_set(0), lxf, NEAR_VIS)
			_place_set(c, _crate_set(1), lxf * Transform3D(Basis(Vector3.UP, 0.4), Vector3(1.35, 0.0, 0.2)), NEAR_VIS)


## A composite blast barrier (1.8 m long along local x, 0.9 m high) with a hazard band.
static func _barrier_set() -> Dictionary:
	if _cache.has("barrier"):
		return _cache["barrier"]
	var k := Kit.new()
	var xf := Transform3D(Basis(Vector3(0.0, 0.0, 1.0), Vector3(0.0, 1.0, 0.0), Vector3(-1.0, 0.0, 0.0)), Vector3.ZERO)
	k.slab(xf, PackedVector2Array([Vector2(-0.3, 0.0), Vector2(0.3, 0.0), Vector2(0.3, 0.12), Vector2(0.12, 0.9), Vector2(-0.12, 0.9),
			Vector2(-0.3, 0.12)]), 1.8, COMPOSITE, P_PLAIN, 0.0)
	k.box(Transform3D(Basis(), Vector3(0.0, 0.76, 0.0)), Vector3(0.86, 0.05, 0.155), YELLOW, P_HAZARD, 0.0, 0.01)
	for sx: float in [-0.55, 0.55]:
		k.rod(Vector3(sx - 0.08, 0.9, 0.0), Vector3(sx, 1.0, 0.0), 0.018, 5, STEEL, P_PLAIN, 0.3)
		k.rod(Vector3(sx, 1.0, 0.0), Vector3(sx + 0.08, 0.9, 0.0), 0.018, 5, STEEL, P_PLAIN, 0.3)
	var pset := _set_of({"kit": k}, {"boxes": [[Transform3D(Basis(), Vector3(0.0, 0.45, 0.0)), Vector3(1.8, 0.9, 0.5)]],
			"obst": [[Vector3(0.0, 0.5, 0.0), 1.0]]})
	_cache["barrier"] = pset
	return pset


static func _tunnel(c: Ctx) -> void:
	var d := c.data
	var ps := _portal_set()
	var azs: Array = []
	for m: Array in d.get("mouths", []):
		var p2: Vector3 = m[0]
		var p1: Vector3 = m[1]
		# Walk in from the mouth's floor until the roof closes ~2.7 m over it: the portal goes there.
		var mouth := p2
		for i in 25:
			var t := float(i) / 24.0
			var fp := p2.lerp(p1, t)
			if _dens(c, fp + fp.normalized() * 2.75) < 0.0:
				mouth = p2.lerp(p1, maxf(t - 0.03, 0.0))
				break
		var up := mouth.normalized()
		var along := p1 - p2
		along = (along - up * along.dot(up)).normalized()
		_place_set(c, ps, c.inv * Transform3D(Basis(up.cross(along), up, along), mouth - up * 0.05), MID_VIS)
		var lp := c.inv * p1
		azs.append(atan2(lp.z, lp.x))
	# The chamber: a work lamp under the dome, a terminal, crates along the wall.
	var cf: Vector3 = c.inv * (d.get("chamber", c.frame.origin) as Vector3)
	var ch: float = d.get("chamber_h", 3.0)
	var k := _kit(c, "kit", NEAR_VIS)
	var gw := _kit(c, "glow_warm", NEAR_VIS, false)
	var lamp := cf + Vector3(0.0, ch - 0.45, 0.0)
	k.box(Transform3D(Basis(), lamp), Vector3(0.4, 0.06, 0.14), GRAPHITE, P_PLAIN, 0.1, 0.02)
	gw.box(Transform3D(Basis(), lamp - Vector3(0.0, 0.065, 0.0)), Vector3(0.34, 0.01, 0.1), Color(1, 1, 1), 0.0, 0.0, 0.004)
	for sx: float in [-0.32, 0.32]:
		k.rod(lamp + Vector3(sx, 0.05, 0.0), cf + Vector3(sx * 1.4, ch + 0.4, 0.0), 0.012, 4, DARK)
	var lt := OmniLight3D.new()
	lt.light_color = Color(1.0, 0.82, 0.6)
	lt.light_energy = 1.3
	lt.omni_range = 7.0
	lt.shadow_enabled = false
	lt.position = lamp - Vector3(0.0, 0.4, 0.0)
	c.root.add_child(lt)
	var placed := 0
	for t in 30:
		if placed >= 3:
			break
		var a := c.rng.randf() * TAU
		var ok := true
		for az: float in azs:
			if absf(wrapf(a - az, -PI, PI)) < 0.75:
				ok = false
				break
		if not ok:
			continue
		var r := c.rng.randf_range(2.5, 3.0)
		var p := cf + Vector3(cos(a) * r, -0.02, sin(a) * r)
		if placed == 0:
			# The terminal, its screen toward the centre.
			var txf := Transform3D(Basis(Vector3.UP, atan2(-cos(a), -sin(a))), p)
			k.box(txf * Transform3D(Basis(), Vector3(0.0, 0.55, 0.0)), Vector3(0.36, 0.55, 0.24), GRAPHITE, 0.5, 0.05, 0.03)
			var gs := _kit(c, "glow_screen", NEAR_VIS, false)
			gs.box(txf * Transform3D(Basis(Vector3.RIGHT, -0.35), Vector3(0.0, 0.92, 0.2)), Vector3(0.28, 0.16, 0.01), Color(1, 1, 1), 0.0, 0.0, 0.003)
			_box_shape(c, txf * Transform3D(Basis(), Vector3(0.0, 0.55, 0.0)), Vector3(0.72, 1.1, 0.48))
		else:
			_place_set(c, _crate_set(c.rng.randi_range(0, 1)), _yaw(c.rng.randf() * TAU, p), NEAR_VIS)
		azs.append(a)
		placed += 1


## Tunnel portal (local x across, y up, z along): steel posts, a hazard-striped lintel, an amber lamp.
static func _portal_set() -> Dictionary:
	if _cache.has("portal"):
		return _cache["portal"]
	var k := Kit.new()
	var g := Kit.new()
	var boxes: Array = []
	for sx: float in [-1.35, 1.35]:
		var xf := Transform3D(Basis(), Vector3(sx, 1.2, 0.0))
		k.box(xf, Vector3(0.11, 1.32, 0.13), DARK, P_BRUSHED, 0.3, 0.02)
		k.box(Transform3D(Basis(), Vector3(sx, 0.06, 0.0)), Vector3(0.2, 0.08, 0.22), GRAPHITE, P_PLAIN, 0.0, 0.02)
		boxes.append([xf, Vector3(0.22, 2.64, 0.26)])
	var lxf := Transform3D(Basis(), Vector3(0.0, 2.62, 0.0))
	k.box(lxf, Vector3(1.5, 0.15, 0.16), YELLOW, P_HAZARD, 0.0, 0.02)
	boxes.append([lxf, Vector3(3.0, 0.3, 0.32)])
	k.box(Transform3D(Basis(), Vector3(0.0, 2.4, 0.2)), Vector3(0.16, 0.05, 0.08), GRAPHITE, P_PLAIN, 0.0, 0.01)
	g.box(Transform3D(Basis(), Vector3(0.0, 2.345, 0.2)), Vector3(0.12, 0.01, 0.06), Color(1, 1, 1), 0.0, 0.0, 0.003)
	var pset := _set_of({"kit": k, "glow_amber": g}, {"boxes": boxes})
	_cache["portal"] = pset
	return pset
