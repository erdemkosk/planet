extends RefCounted
## Geometry of the respawn ships (scripts/war/respawn_ship.gd): the İniş Gemisi (dropship.gd) and the
## Taşıyıcı (carrier.gd). Procedural, flat-shaded angular solids in the vertex format of the Mekik's
## shaders (scripts/craft/skiff_shaders.gd): HULL COLOR = albedo (sRGB) + roughness in alpha, UV =
## metres, UV2 = (pattern, metallic); EMIT COLOR = colour + intensity, UV2 = (mode, phase). Built once
## per livery and shared by every ship of it:
##   "home"  white paint, orange stripes, warm lit windows (the Yurt side, like the Mekik)
##   "rival" dark gunmetal, red stripes, red lights (the Rakip side)
##   dropship(team) -> {"hull", "cabin", "glass", "emit", "ramp"}
##       Ship frame: -Z forward, +Y up, origin = the ground point under the skids. An 7.2 m long,
##       3 m wide, 3.2 m tall troop shuttle: an octagonal body, a glazed wedge nose, a side ramp-door
##       on the right (+X) that swings down to the ground, a window strip on the left, two main engines
##       at the tail, four lift / retro jets on sponsons, two skids. The cabin (benches, the jump seat
##       the player rides in, a console in the nose) is its own mesh ("cabin", interior material).
##       "ramp" is built about its hinge (DS_HINGE), closed pose.
##   carrier(team) -> {"hull", "emit"}
##       Carrier frame: -Z forward, +Y away from the planet, origin = the hull centre. ~60 m: a long
##       octagonal hull, a wedge prow, a superstructure with the lit bridge, hangar sponsons with
##       window rows, radiators, three big engines and, under the keel, CV_SLOTS docking clamps where
##       a dropship hangs (its origin at Vector3(0, CV_HANGAR_Y, CV_SLOT_Z[i])).

const Shaders := preload("res://scripts/craft/skiff_shaders.gd")

# Hull shader patterns (UV2.x; > 0: panel plating of that size in m).
const P_PLAIN := 0.0
const P_HAZARD := -1.0
const P_TREAD := -2.0
const P_QUILT := -3.0
const P_RUBBER := -4.0
const P_NOZZLE := -5.0
const P_VENT := -6.0
const P_TILES := -7.0
const P_BRUSHED := -8.0
# EMIT shader modes.
const E_STEADY := 0.0
const E_PULSE := 1.0
const E_STROBE := 2.0
const E_NAV := 3.0
const E_ENGINE := 5.0
const E_LIFT := 6.0
const E_LAND := 7.0

const LIVERY := {
	"home": {"paint": Color(0.80, 0.80, 0.78, 0.42), "stripe": Color(0.86, 0.42, 0.12, 0.45),
			"dark": Color(0.24, 0.25, 0.27, 0.58), "cabin": Color(0.38, 0.39, 0.41, 0.62),
			"cabin_dk": Color(0.25, 0.26, 0.28, 0.72), "seat": Color(0.31, 0.32, 0.34, 0.86),
			"window": Color(1.0, 0.84, 0.6, 0.9), "lamp": Color(1.0, 0.9, 0.75, 1.0),
			"strobe": Color(1.0, 1.0, 1.0, 1.0), "name": "YURT",
			# Carrier underside (seen from the ground: kept light, it is never in the sun), keel, its
			# running lights, the self-lit rim and the planet's bounce light (carrier.gd FILL shader).
			"under": Color(0.66, 0.67, 0.68, 0.5), "keel": Color(0.5, 0.51, 0.53, 0.5),
			"run": Color(1.0, 0.78, 0.45, 1.0), "rim": Color(0.55, 0.72, 1.0), "fill": Color(0.62, 0.5, 0.42)},
	"rival": {"paint": Color(0.3, 0.29, 0.29, 0.46), "stripe": Color(0.76, 0.15, 0.1, 0.45),
			"dark": Color(0.19, 0.19, 0.2, 0.6), "cabin": Color(0.27, 0.26, 0.26, 0.66),
			"cabin_dk": Color(0.2, 0.19, 0.19, 0.74), "seat": Color(0.24, 0.22, 0.22, 0.86),
			"window": Color(1.0, 0.3, 0.2, 0.75), "lamp": Color(1.0, 0.36, 0.26, 1.0),
			"strobe": Color(1.0, 0.22, 0.16, 1.0), "name": "RAKİP",
			"under": Color(0.4, 0.39, 0.39, 0.5), "keel": Color(0.33, 0.32, 0.32, 0.52),
			"run": Color(1.0, 0.25, 0.16, 1.0), "rim": Color(1.0, 0.36, 0.26), "fill": Color(0.55, 0.52, 0.5)},
}
const C_STEEL := Color(0.36, 0.37, 0.39, 0.45)
const C_METAL := Color(0.6, 0.61, 0.63, 0.36)
const C_RUBBER := Color(0.2, 0.2, 0.21, 0.9)
const C_YELLOW := Color(0.9, 0.72, 0.2, 0.5)
const C_RED := Color(0.72, 0.15, 0.1, 0.4)

# --- İniş Gemisi ----------------------------------------------------------------------------------
## Body cross-section (x, y), around: belly, lower chines, the vertical side walls, upper chines, roof.
const DS_SEC := [Vector2(-1.05, 0.7), Vector2(1.05, 0.7), Vector2(1.5, 0.95), Vector2(1.5, 2.75),
		Vector2(0.95, 3.15), Vector2(-0.95, 3.15), Vector2(-1.5, 2.75), Vector2(-1.5, 0.95)]
## The nose tip section (the same corners, smaller and lower).
const DS_TIP := [Vector2(-0.55, 0.85), Vector2(0.55, 0.85), Vector2(0.85, 1.05), Vector2(0.85, 1.75),
		Vector2(0.42, 2.0), Vector2(-0.42, 2.0), Vector2(-0.85, 1.75), Vector2(-0.85, 1.05)]
const DS_Z_TIP := -3.85
const DS_Z_FRONT := -2.2
const DS_Z_REAR := 2.6
const DS_FLOOR := 0.95                 # cabin floor = the door sill
## The ramp-door in the right wall (x = 1.5): z range and height; it swings down about DS_HINGE.
const DS_DOOR_Z0 := -0.65
const DS_DOOR_Z1 := 0.95
const DS_DOOR_H := 1.8
const DS_HINGE := Vector3(1.5, 0.95, 0.15)
## The window strip in the left wall.
const DS_WIN_Z0 := -1.9
const DS_WIN_Z1 := 0.5
const DS_WIN_Y0 := 1.85
const DS_WIN_Y1 := 2.4
## The jump seat's eye (the player rides here, facing forward).
const DS_SEAT_EYE := Vector3(0.0, 2.1, 1.2)
## Where the passengers step off, past the ramp's foot (ground level; bots fan out along z).
const DS_EXIT := Vector3(3.35, 0.0, 0.15)
const DS_EXIT_SPREAD := [0.0, -0.95, 0.95, -1.9, 1.9, 0.5]
const DS_MAIN := [Vector3(-0.6, 1.95, 3.3), Vector3(0.6, 1.95, 3.3)]          # main nozzle exits (+Z)
const DS_LIFT := [Vector3(-1.7, 0.42, -1.6), Vector3(1.7, 0.42, -1.6), Vector3(-1.7, 0.42, 1.95), Vector3(1.7, 0.42, 1.95)]
const DS_STROBE := Vector3(0.0, 3.93, 2.45)
const DS_LAND_LIGHT := Vector3(0.0, 0.8, -3.4)

# --- Taşıyıcı -------------------------------------------------------------------------------------
const CV_SEC := [Vector2(-5.5, -3.4), Vector2(5.5, -3.4), Vector2(7.5, -1.2), Vector2(7.5, 1.4),
		Vector2(5.5, 3.4), Vector2(-5.5, 3.4), Vector2(-7.5, 1.4), Vector2(-7.5, -1.2)]
const CV_MID := [Vector2(-4.0, -3.2), Vector2(4.0, -3.2), Vector2(5.8, -1.2), Vector2(5.8, 1.0),
		Vector2(4.0, 2.6), Vector2(-4.0, 2.6), Vector2(-5.8, 1.0), Vector2(-5.8, -1.2)]
const CV_PROW := [Vector2(-1.6, -2.0), Vector2(1.6, -2.0), Vector2(2.6, -1.0), Vector2(2.6, 0.4),
		Vector2(1.8, 1.2), Vector2(-1.8, 1.2), Vector2(-2.6, 0.4), Vector2(-2.6, -1.0)]
const CV_ENG := [Vector2(-8.0, -3.8), Vector2(8.0, -3.8), Vector2(8.6, -1.5), Vector2(8.6, 2.2),
		Vector2(7.0, 3.8), Vector2(-7.0, 3.8), Vector2(-8.6, 2.2), Vector2(-8.6, -1.5)]
const CV_Z_PROW := -34.0
const CV_Z_MID := -27.0
const CV_Z_FRONT := -21.0
const CV_Z_REAR := 18.0
const CV_Z_ENG0 := 20.0
const CV_Z_ENG1 := 26.0
const CV_NOZZLES := [Vector3(-4.6, 0.0, 26.0), Vector3(0.0, 0.3, 26.0), Vector3(4.6, 0.0, 26.0)]
const CV_SLOT_Z := [-10.0, 0.0, 10.0]
const CV_SLOTS := 3
const CV_KEEL_Y := -4.1                # underside of the keel
const CV_CLAMP_Y := -4.75              # clamp pads: the docked dropship's roof
const CV_HANGAR_Y := CV_CLAMP_Y - 3.15 # the docked dropship's origin (its roof is 3.15 m above it)
const CV_MAST_TOP := Vector3(0.0, 13.2, 9.0)
const CV_PROW_TIP := Vector3(0.0, -0.4, -34.2)

## Visual layer of the dropship's cabin (cabin mesh, ramp): lit only by the cabin's own lights and the
## sun through the windows; the ship's exterior lights and the carrier's bay light leave it out (they
## have no shadows and would shine straight through the hull).
const INTERIOR_LAYER := 1 << 14

static var _ds := {}
static var _cv := {}
static var _glass_uv := false


## The İniş Gemisi's meshes for a livery (built on first use).
static func dropship(team: String) -> Dictionary:
	var key := team if LIVERY.has(team) else "home"
	if _ds.has(key):
		return _ds[key]
	var lv: Dictionary = LIVERY[key]
	var hull := _new_st()
	var cabin := _new_st()
	var glass := _new_st()
	_ds_shell(hull, cabin, glass, lv)
	_ds_exterior(hull, lv)
	_ds_interior(cabin, lv)
	var d := {"hull": _commit(hull), "cabin": _commit(cabin), "glass": _commit(glass),
			"emit": _ds_emit(lv), "ramp": _ds_ramp(lv)}
	_ds[key] = d
	return d


## The Taşıyıcı's meshes for a livery (built on first use).
static func carrier(team: String) -> Dictionary:
	var key := team if LIVERY.has(team) else "home"
	if _cv.has(key):
		return _cv[key]
	var lv: Dictionary = LIVERY[key]
	var d := {"hull": _cv_hull(lv), "emit": _cv_emit(lv, key)}
	_cv[key] = d
	return d


## The hull material (one per ship: the dropship drives nothing on it, but keep them separate).
static func hull_material(interior := false, scale := 1.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Shaders.shader("hull")
	m.set_shader_parameter("grime", 0.14 if not interior else 0.07)
	m.set_shader_parameter("wear", 0.45 if scale < 2.0 else 0.25)
	m.set_shader_parameter("seam_w", 0.0045 * scale)
	if interior:
		m.set_shader_parameter("ambient_k", 0.8)
	return m


static func glass_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Shaders.shader("glass")
	m.render_priority = 1
	return m


static func emit_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Shaders.shader("emit")
	m.set_shader_parameter("power", 1.0)
	m.set_shader_parameter("lights", 1.0)
	return m


# ==================================================================================================
# Primitives (flat shaded; vertices carry colour, UV in metres, UV2 = pattern / metallic)
# ==================================================================================================

static func _new_st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


static func _commit(st: SurfaceTool) -> ArrayMesh:
	st.index()
	return st.commit()


static func _uv(p: Vector3, n: Vector3) -> Vector2:
	var an := n.abs()
	if an.x >= an.y and an.x >= an.z:
		return Vector2(p.z, p.y)
	if an.y >= an.z:
		return Vector2(p.x, p.z)
	return Vector2(p.x, p.y)


static func _vert(st: SurfaceTool, p: Vector3, n: Vector3, uv: Vector2, col: Color, pat: float, metal: float) -> void:
	st.set_color(col)
	st.set_normal(n)
	st.set_uv(uv)
	st.set_uv2(Vector2(pat, metal))
	st.add_vertex(p)


## Triangle facing n (Godot's front faces wind clockwise seen from the front).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color, pat: float,
		metal: float, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	if (b - a).cross(c - a).dot(n) > 0.0:
		_vert(st, a, n, ua, col, pat, metal)
		_vert(st, c, n, uc, col, pat, metal)
		_vert(st, b, n, ub, col, pat, metal)
	else:
		_vert(st, a, n, ua, col, pat, metal)
		_vert(st, b, n, ub, col, pat, metal)
		_vert(st, c, n, uc, col, pat, metal)


## Triangle with its own normal per corner (round parts); the winding follows their average.
static func _tri_s(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3,
		col: Color, pat: float, metal: float, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:
		_vert(st, a, na, ua, col, pat, metal)
		_vert(st, c, nc, uc, col, pat, metal)
		_vert(st, b, nb, ub, col, pat, metal)
	else:
		_vert(st, a, na, ua, col, pat, metal)
		_vert(st, b, nb, ub, col, pat, metal)
		_vert(st, c, nc, uc, col, pat, metal)


## Flat convex polygon (points in order, either winding) facing away from `ref` (inward: toward it).
static func _face(st: SurfaceTool, pts: Array, ref: Vector3, col: Color, pat: float, metal: float, inward := false) -> void:
	var m := pts.size()
	if m < 3:
		return
	var n := Vector3.ZERO
	var fc := Vector3.ZERO
	for i in m:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % m]
		n += a.cross(b)
		fc += a
	fc /= float(m)
	if n.length_squared() < 1e-12:
		return
	n = n.normalized()
	if n.dot(fc - ref) < 0.0:
		n = -n
	if inward:
		n = -n
	var p0: Vector3 = pts[0]
	for i in range(1, m - 1):
		var p1: Vector3 = pts[i]
		var p2: Vector3 = pts[i + 1]
		if _glass_uv:
			# (glass shader: UV.y = height above the sill; keep it clear of the dusty bottom band)
			_tri(st, p0, p1, p2, n, col, pat, metal, Vector2(p0.x + p0.z, 0.7), Vector2(p1.x + p1.z, 0.7), Vector2(p2.x + p2.z, 0.7))
		else:
			_tri(st, p0, p1, p2, n, col, pat, metal, _uv(p0, n), _uv(p1, n), _uv(p2, n))


## Six-faced solid from 8 corners (bottom 0-3, top 4-7 in the same order).
static func _hexa(st: SurfaceTool, c: Array, col: Color, pat: float, metal: float) -> void:
	var ctr := Vector3.ZERO
	for p in c:
		ctr += p as Vector3
	ctr /= 8.0
	for f: Array in [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]:
		_face(st, [c[f[0]], c[f[1]], c[f[2]], c[f[3]]], ctr, col, pat, metal)


## Box of half size h about `center`, turned by `b`.
static func _box(st: SurfaceTool, center: Vector3, h: Vector3, col: Color, pat: float, metal: float, b := Basis()) -> void:
	var c: Array = []
	for y in [-1.0, 1.0]:
		for xz: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			c.append(center + b * Vector3(h.x * xz.x, h.y * y, h.z * xz.y))
	_hexa(st, c, col, pat, metal)


static func _basis_y(y: Vector3) -> Basis:
	var yy := y.normalized()
	var ref := Vector3.FORWARD if absf(yy.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(yy).normalized()
	var z := x.cross(yy).normalized()
	return Basis(x, yy, z)


## Cylinder / cone from a (radius ra) to b (radius rb), smooth sides, flat caps.
static func _cyl(st: SurfaceTool, a: Vector3, b: Vector3, ra: float, rb: float, col: Color, pat: float,
		metal: float, sides := 12, caps := true) -> void:
	var ax := b - a
	var ln := ax.length()
	if ln < 1e-5:
		return
	var bs := _basis_y(ax / ln)
	var pa: Array = []
	var pb: Array = []
	var nn: Array = []
	for k in sides + 1:
		var ang := TAU * float(k) / float(sides)
		var dir := bs.x * cos(ang) + bs.z * sin(ang)
		pa.append(a + dir * ra)
		pb.append(b + dir * rb)
		nn.append((dir * ln + bs.y * (ra - rb)).normalized())
	for k in sides:
		var u0 := TAU * float(k) / float(sides) * 0.5 * (ra + rb)
		var u1 := TAU * float(k + 1) / float(sides) * 0.5 * (ra + rb)
		var n0: Vector3 = nn[k]
		var n1: Vector3 = nn[k + 1]
		_tri_s(st, pa[k], pb[k], pb[k + 1], n0, n0, n1, col, pat, metal, Vector2(u0, 0.0), Vector2(u0, ln), Vector2(u1, ln))
		_tri_s(st, pa[k], pb[k + 1], pa[k + 1], n0, n1, n1, col, pat, metal, Vector2(u0, 0.0), Vector2(u1, ln), Vector2(u1, 0.0))
	if caps:
		if ra > 0.0005:
			_face(st, pa.slice(0, sides), b, col, pat, metal)
		if rb > 0.0005:
			_face(st, pb.slice(0, sides), a, col, pat, metal)


## Surface of revolution about the local Y axis of xf. prof: Vector2(radius, y); UV.y runs 0..1 along
## the profile (the nozzle pattern reads it). flip: normals toward the axis (the inside of a bell).
static func _lathe(st: SurfaceTool, xf: Transform3D, prof: Array, col: Color, pat: float, metal: float,
		sides := 16, flip := false) -> void:
	var np := prof.size()
	var rings: Array = []
	for i in np:
		var p: Vector2 = prof[i]
		var t: Vector2 = (prof[mini(i + 1, np - 1)] as Vector2) - (prof[maxi(i - 1, 0)] as Vector2)
		var n2 := Vector2(t.y, -t.x).normalized()
		if flip:
			n2 = -n2
		var row: Array = []
		for k in sides + 1:
			var ang := TAU * float(k) / float(sides)
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			row.append([xf * (dir * p.x + Vector3(0.0, p.y, 0.0)), (xf.basis * (dir * n2.x + Vector3(0.0, n2.y, 0.0))).normalized(),
					Vector2(ang * maxf(p.x, 0.02), float(i) / float(maxi(np - 1, 1)))])
		rings.append(row)
	for i in np - 1:
		for k in sides:
			var a: Array = rings[i][k]
			var b: Array = rings[i + 1][k]
			var c: Array = rings[i + 1][k + 1]
			var d: Array = rings[i][k + 1]
			_tri_s(st, a[0], b[0], c[0], a[1], b[1], c[1], col, pat, metal, a[2], b[2], c[2])
			_tri_s(st, a[0], c[0], d[0], a[1], c[1], d[1], col, pat, metal, a[2], c[2], d[2])


## Flat disc (emissive glow, lenses) at c facing n.
static func _disc(st: SurfaceTool, c: Vector3, n: Vector3, r: float, col: Color, mode: float, phase := 0.0) -> void:
	var b := _basis_y(n)
	var pts: Array = []
	for k in 16:
		var a := TAU * float(k) / 16.0
		pts.append(c + (b.x * cos(a) + b.z * sin(a)) * r)
	_face(st, pts, c - n, col, mode, phase)


## A straight-sided loft between two sections (x, y at za and at zb), one quad per edge. cols / pats
## per edge (null = skip that edge); `inner` (if given) gets the same faces turned inward with icols.
static func _loft(st: SurfaceTool, a: Array, za: float, b: Array, zb: float, ref: Vector3, cols: Array,
		pats: Array, inner: SurfaceTool = null, icols: Array = [], ipats: Array = []) -> void:
	var m := a.size()
	for i in m:
		var j := (i + 1) % m
		var a0: Vector2 = a[i]
		var a1: Vector2 = a[j]
		var b0: Vector2 = b[i]
		var b1: Vector2 = b[j]
		var pts := [Vector3(a0.x, a0.y, za), Vector3(a1.x, a1.y, za), Vector3(b1.x, b1.y, zb), Vector3(b0.x, b0.y, zb)]
		if cols[i] != null:
			_face(st, pts, ref, cols[i], float(pats[i]), 0.0)
		if inner != null and i < icols.size() and icols[i] != null:
			_face(inner, pts, ref, icols[i], float(ipats[i]), 0.0, true)


static func _sec3(sec: Array, z: float) -> Array:
	var out: Array = []
	for p: Vector2 in sec:
		out.append(Vector3(p.x, p.y, z))
	return out


## A vertical wall rectangle at x (y0..y1, z0..z1): outward face into `st`, inward into `inner`.
static func _wallx(st: SurfaceTool, inner: SurfaceTool, x: float, y0: float, y1: float, z0: float, z1: float,
		col: Color, pat: float, icol: Color, ipat: float) -> void:
	var pts := [Vector3(x, y0, z0), Vector3(x, y1, z0), Vector3(x, y1, z1), Vector3(x, y0, z1)]
	var ref := Vector3(0.0, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
	_face(st, pts, ref, col, pat, 0.0)
	if inner != null:
		_face(inner, pts, ref, icol, ipat, 0.0, true)


# ==================================================================================================
# İniş Gemisi
# ==================================================================================================

## The skin: the body prism (door and window cut out), the glazed nose, the end caps; every face both
## outside (hull) and inside (cabin).
static func _ds_shell(hull: SurfaceTool, cabin: SurfaceTool, glass: SurfaceTool, lv: Dictionary) -> void:
	var paint: Color = lv["paint"]
	var dark: Color = lv["dark"]
	var cab: Color = lv["cabin"]
	var cab_dk: Color = lv["cabin_dk"]
	var S: Array = DS_SEC
	var n := S.size()
	var ocols := [dark, dark, paint, paint, paint, paint, paint, dark]
	var opats := [P_TILES, 0.6, 0.85, 0.85, 0.85, 0.85, 0.85, 0.6]
	var icols := [cab_dk, cab_dk, cab, cab_dk, cab, cab_dk, cab, cab_dk]
	var ipats := [0.5, 0.5, 0.6, 0.5, P_QUILT, 0.5, 0.6, 0.5]
	for i in n:
		var a: Vector2 = S[i]
		var b: Vector2 = S[(i + 1) % n]
		var col: Color = ocols[i]
		var pat: float = opats[i]
		var icol: Color = icols[i]
		var ipat: float = ipats[i]
		if i == 2:
			# Right wall: the ramp-door opening (the full wall height) between DS_DOOR_Z0 and Z1.
			_wallx(hull, cabin, a.x, a.y, b.y, DS_Z_FRONT, DS_DOOR_Z0, col, pat, icol, ipat)
			_wallx(hull, cabin, a.x, a.y, b.y, DS_DOOR_Z1, DS_Z_REAR, col, pat, icol, ipat)
			continue
		if i == 6:
			# Left wall: the window strip.
			_wallx(hull, cabin, a.x, b.y, a.y, DS_Z_FRONT, DS_WIN_Z0, col, pat, icol, ipat)
			_wallx(hull, cabin, a.x, b.y, a.y, DS_WIN_Z1, DS_Z_REAR, col, pat, icol, ipat)
			_wallx(hull, cabin, a.x, b.y, DS_WIN_Y0, DS_WIN_Z0, DS_WIN_Z1, col, pat, icol, ipat)
			_wallx(hull, cabin, a.x, DS_WIN_Y1, a.y, DS_WIN_Z0, DS_WIN_Z1, col, pat, icol, ipat)
			_glass_uv = true
			_wallx(glass, null, a.x - 0.01, DS_WIN_Y0, DS_WIN_Y1, DS_WIN_Z0, DS_WIN_Z1, Color(1, 1, 1, 1), 0.0, Color(), 0.0)
			_glass_uv = false
			continue
		var pts := [Vector3(a.x, a.y, DS_Z_FRONT), Vector3(b.x, b.y, DS_Z_FRONT), Vector3(b.x, b.y, DS_Z_REAR), Vector3(a.x, a.y, DS_Z_REAR)]
		var ref := Vector3(0.0, 1.9, 0.2)
		_face(hull, pts, ref, col, pat, 0.0)
		_face(cabin, pts, ref, icol, ipat, 0.0, true)
	# Nose: the upper faces are the windscreen (glass, seen from both sides).
	var ncols: Array = [dark, dark, paint, null, null, null, paint, dark]
	var npats: Array = [P_TILES, P_TILES, 0.7, 0.0, 0.0, 0.0, 0.7, P_TILES]
	var nicols: Array = [cab_dk, cab_dk, cab, null, null, null, cab, cab_dk]
	var nref := Vector3(0.0, 1.7, -2.9)
	_loft(hull, S, DS_Z_FRONT, DS_TIP, DS_Z_TIP, nref, ncols, npats, cabin, nicols, [0.5, 0.5, 0.6, 0.0, 0.0, 0.0, 0.6, 0.5])
	var wcols: Array = [null, null, null, Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 1), null, null]
	_glass_uv = true
	_loft(glass, S, DS_Z_FRONT, DS_TIP, DS_Z_TIP, nref, wcols, [0, 0, 0, 0, 0, 0, 0, 0])
	_glass_uv = false
	# Nose tip and the rear bulkhead.
	var tip := _sec3(DS_TIP, DS_Z_TIP)
	_face(hull, tip, nref, dark, P_TILES, 0.0)
	_face(cabin, tip, nref, cab_dk, 0.5, 0.0, true)
	var rear := _sec3(DS_SEC, DS_Z_REAR)
	_face(hull, rear, Vector3(0.0, 1.9, 0.0), dark, 0.5, 0.0)
	_face(cabin, rear, Vector3(0.0, 1.9, 0.0), cab_dk, 0.5, 0.0, true)


static func _ds_exterior(st: SurfaceTool, lv: Dictionary) -> void:
	var paint: Color = lv["paint"]
	var dark: Color = lv["dark"]
	var stripe: Color = lv["stripe"]
	# Livery stripes along both flanks (not across the door) and a band round the nose.
	_box(st, Vector3(-1.522, 2.52, (DS_Z_FRONT + DS_Z_REAR) * 0.5), Vector3(0.012, 0.07, (DS_Z_REAR - DS_Z_FRONT) * 0.5), stripe, 0.0, 0.0)
	_box(st, Vector3(1.522, 2.52, (DS_Z_FRONT + DS_DOOR_Z0) * 0.5), Vector3(0.012, 0.07, (DS_DOOR_Z0 - DS_Z_FRONT) * 0.5 - 0.06), stripe, 0.0, 0.0)
	_box(st, Vector3(1.522, 2.52, (DS_DOOR_Z1 + DS_Z_REAR) * 0.5), Vector3(0.012, 0.07, (DS_Z_REAR - DS_DOOR_Z1) * 0.5 - 0.06), stripe, 0.0, 0.0)
	# Door frame: hazard jambs and a header outside.
	for z: float in [DS_DOOR_Z0 - 0.05, DS_DOOR_Z1 + 0.05]:
		_box(st, Vector3(1.545, 1.85, z), Vector3(0.035, 0.92, 0.05), C_YELLOW, P_HAZARD, 0.0)
	_box(st, Vector3(1.545, 2.78, 0.15), Vector3(0.035, 0.05, 0.86), dark, 0.0, 0.1)
	# Window frame (left).
	_box(st, Vector3(-1.54, DS_WIN_Y0 - 0.03, (DS_WIN_Z0 + DS_WIN_Z1) * 0.5), Vector3(0.03, 0.035, (DS_WIN_Z1 - DS_WIN_Z0) * 0.5 + 0.04), dark, 0.0, 0.1)
	_box(st, Vector3(-1.54, DS_WIN_Y1 + 0.03, (DS_WIN_Z0 + DS_WIN_Z1) * 0.5), Vector3(0.03, 0.035, (DS_WIN_Z1 - DS_WIN_Z0) * 0.5 + 0.04), dark, 0.0, 0.1)
	for z: float in [DS_WIN_Z0, -0.7, DS_WIN_Z1]:
		_box(st, Vector3(-1.54, (DS_WIN_Y0 + DS_WIN_Y1) * 0.5, z), Vector3(0.03, (DS_WIN_Y1 - DS_WIN_Y0) * 0.5 + 0.05, 0.035), dark, 0.0, 0.1)
	# Canopy frame: posts along the windscreen edges and a cross bar.
	for i: int in [3, 4, 5, 6]:
		var s: Vector2 = DS_SEC[i]
		var t: Vector2 = DS_TIP[i]
		_cyl(st, Vector3(s.x, s.y, DS_Z_FRONT), Vector3(t.x, t.y, DS_Z_TIP), 0.04, 0.035, dark, 0.0, 0.2, 6)
	var mid := 0.5
	var pl: Array = []
	for i: int in [3, 4, 5, 6]:
		var s2: Vector2 = DS_SEC[i]
		var t2: Vector2 = DS_TIP[i]
		var q := s2.lerp(t2, mid)
		pl.append(Vector3(q.x, q.y, lerpf(DS_Z_FRONT, DS_Z_TIP, mid)))
	for i in pl.size() - 1:
		_cyl(st, pl[i], pl[i + 1], 0.03, 0.03, dark, 0.0, 0.2, 6)
	_cyl(st, Vector3(1.5, 2.75, DS_Z_FRONT), Vector3(-1.5, 2.75, DS_Z_FRONT), 0.045, 0.045, dark, 0.0, 0.2, 6)
	# Engine block at the tail, two main nozzles (bell outside and inside).
	var e0 := [Vector3(-1.25, 1.2, DS_Z_REAR), Vector3(1.25, 1.2, DS_Z_REAR), Vector3(1.25, 1.2, 3.3), Vector3(-1.25, 1.2, 3.3),
			Vector3(-1.25, 2.7, DS_Z_REAR), Vector3(1.25, 2.7, DS_Z_REAR), Vector3(1.1, 2.6, 3.3), Vector3(-1.1, 2.6, 3.3)]
	_hexa(st, e0, dark, P_VENT, 0.15)
	var to_z := Basis(Vector3.RIGHT, PI * 0.5)
	for p: Vector3 in DS_MAIN:
		var xf := Transform3D(to_z, p - Vector3(0.0, 0.0, 0.02))
		_lathe(st, xf, [Vector2(0.3, 0.0), Vector2(0.34, 0.1), Vector2(0.42, 0.3), Vector2(0.45, 0.38)], C_STEEL, P_NOZZLE, 0.3, 14)
		_lathe(st, xf, [Vector2(0.28, 0.0), Vector2(0.32, 0.1), Vector2(0.4, 0.3), Vector2(0.43, 0.38)], C_STEEL, P_NOZZLE, 0.3, 14, true)
	# Lift / retro jet sponsons and their down-facing nozzles.
	for p2: Vector3 in DS_LIFT:
		var c := Vector3(p2.x, 0.8, p2.z)
		_box(st, c + Vector3(0.0, 0.0, 0.0), Vector3(0.27, 0.26, 0.45), dark, 0.5, 0.1)
		_box(st, c + Vector3(signf(p2.x) * 0.05, 0.27, 0.0), Vector3(0.24, 0.02, 0.42), paint, 0.0, 0.0)
		_cyl(st, Vector3(p2.x, 0.56, p2.z), Vector3(p2.x, p2.y, p2.z), 0.2, 0.25, C_STEEL, P_NOZZLE, 0.3, 12, false)
	# Skids on struts.
	for sx: float in [-1.75, 1.75]:
		_tube(st, [Vector3(sx, 0.36, -2.8), Vector3(sx, 0.2, -2.62), Vector3(sx, 0.1, -2.35), Vector3(sx, 0.1, 2.3),
				Vector3(sx, 0.16, 2.55)], 0.075, C_STEEL, 0.0, 0.3)
		for z: float in [-1.0, 1.3]:
			_cyl(st, Vector3(signf(sx) * 1.0, 0.72, z), Vector3(sx, 0.13, z), 0.065, 0.06, dark, 0.0, 0.2, 8)
			_box(st, Vector3(sx, 0.05, z), Vector3(0.12, 0.05, 0.22), C_RUBBER, P_RUBBER, 0.0)
	# Dorsal fin, sensor dome, antenna.
	_hexa(st, [Vector3(-0.09, 3.15, 0.4), Vector3(0.09, 3.15, 0.4), Vector3(0.09, 3.15, 2.55), Vector3(-0.09, 3.15, 2.55),
			Vector3(-0.05, 3.25, 0.5), Vector3(0.05, 3.25, 0.5), Vector3(0.05, 3.9, 2.45), Vector3(-0.05, 3.9, 2.45)], paint, 0.5, 0.0)
	_box(st, Vector3(0.0, 3.6, 2.2), Vector3(0.075, 0.08, 0.3), lv["stripe"], 0.0, 0.0)
	_lathe(st, Transform3D(Basis(), Vector3(0.0, 3.14, -1.6)), [Vector2(0.24, 0.0), Vector2(0.22, 0.08), Vector2(0.14, 0.17),
			Vector2(0.0, 0.2)], C_METAL, 0.0, 0.2, 12)
	_cyl(st, Vector3(0.55, 3.13, -0.5), Vector3(0.6, 3.8, -0.35), 0.018, 0.01, C_METAL, 0.0, 0.3, 5)
	# Chin sensor / landing-light housing.
	_box(st, Vector3(0.0, 0.86, -3.35), Vector3(0.32, 0.06, 0.22), dark, 0.0, 0.1)


## Tube along a polyline (parallel-transported frames), open ends.
static func _tube(st: SurfaceTool, pts: Array, r: float, col: Color, pat: float, metal: float, sides := 8) -> void:
	var n := pts.size()
	if n < 2:
		return
	var rings: Array = []
	var nrm := Vector3.ZERO
	var along := 0.0
	for i in n:
		var p: Vector3 = pts[i]
		var t: Vector3 = ((pts[mini(i + 1, n - 1)] as Vector3) - (pts[maxi(i - 1, 0)] as Vector3)).normalized()
		if i == 0:
			nrm = _basis_y(t).x
		else:
			along += p.distance_to(pts[i - 1])
			nrm = (nrm - t * nrm.dot(t)).normalized()
		var bn := t.cross(nrm)
		var ring: Array = []
		for k in sides + 1:
			var ang := TAU * float(k) / float(sides)
			var d := nrm * cos(ang) + bn * sin(ang)
			ring.append([p + d * r, d, Vector2(ang * r, along)])
		rings.append(ring)
	for i in n - 1:
		for k in sides:
			var a: Array = rings[i][k]
			var b: Array = rings[i + 1][k]
			var c: Array = rings[i + 1][k + 1]
			var d2: Array = rings[i][k + 1]
			_tri_s(st, a[0], b[0], c[0], a[1], b[1], c[1], col, pat, metal, a[2], b[2], c[2])
			_tri_s(st, a[0], c[0], d2[0], a[1], c[1], d2[1], col, pat, metal, a[2], c[2], d2[2])


## The troop cabin: floor with tie-down rails, benches with harness straps, the jump seat, ribs, cable
## trays and recessed lamp housings under the roof, vent panels, the wall screen's bezel, lockers,
## oxygen bottles, a med kit, the console in the nose with its screen bezels (the screens themselves:
## dropship.gd, a SubViewport drawn by dropship_screens.gd).
static func _ds_interior(st: SurfaceTool, lv: Dictionary) -> void:
	var cab: Color = lv["cabin"]
	var cab_dk: Color = lv["cabin_dk"]
	var seat: Color = lv["seat"]
	var stripe: Color = lv["stripe"]
	# Floor (tread plate), also into the nose; two tie-down rails with rings.
	_box(st, Vector3(0.0, DS_FLOOR - 0.045, 0.2), Vector3(1.47, 0.045, 2.4), C_STEEL, P_TREAD, 0.2)
	_box(st, Vector3(0.0, DS_FLOOR - 0.045, -2.95), Vector3(0.65, 0.045, 0.75), C_STEEL, P_TREAD, 0.2)
	for x: float in [-0.42, 0.42]:
		_box(st, Vector3(x, DS_FLOOR + 0.008, 0.15), Vector3(0.035, 0.008, 2.25), C_METAL, P_BRUSHED, 0.45)
		var z := -1.9
		while z < 2.3:
			_cyl(st, Vector3(x, DS_FLOOR + 0.012, z), Vector3(x, DS_FLOOR + 0.03, z), 0.03, 0.03, C_STEEL, 0.0, 0.4, 8)
			z += 0.6
	# Benches along the walls (the right one split by the door), quilted backs, harness straps.
	_bench(st, Vector3(-1.18, 0.0, -0.45), 1.45, -1.0, seat, cab_dk)
	_bench(st, Vector3(1.18, 0.0, 1.75), 0.62, 1.0, seat, cab_dk)
	_bench(st, Vector3(1.18, 0.0, -1.45), 0.62, 1.0, seat, cab_dk)
	# The jump seat at the back, facing forward (the player rides here).
	_box(st, Vector3(0.0, 1.15, 1.32), Vector3(0.08, 0.2, 0.08), C_STEEL, 0.0, 0.3)
	_box(st, Vector3(0.0, 1.38, 1.32), Vector3(0.28, 0.05, 0.27), seat, P_QUILT, 0.0)
	_box(st, Vector3(0.0, 1.88, 1.62), Vector3(0.28, 0.46, 0.05), seat, P_QUILT, 0.0)
	_box(st, Vector3(0.0, 2.45, 1.63), Vector3(0.17, 0.1, 0.05), seat, P_QUILT, 0.0)
	_box(st, Vector3(0.0, 1.88, 1.69), Vector3(0.3, 0.5, 0.02), cab_dk, 0.0, 0.2)
	for sx: float in [-0.3, 0.3]:
		_box(st, Vector3(sx, 1.42, 1.06), Vector3(0.03, 0.02, 0.06), C_METAL, 0.0, 0.4)     # armrest grips
	# Ribs (walls and ceiling), clear of the door and the window.
	for z: float in [-2.1, 0.62, 1.55, 2.5]:
		_box(st, Vector3(-1.46, 1.85, z), Vector3(0.04, 0.9, 0.05), cab_dk, 0.0, 0.2)
		_box(st, Vector3(0.0, 3.11, z), Vector3(0.96, 0.035, 0.05), cab_dk, 0.0, 0.2)
	for z: float in [-2.1, DS_DOOR_Z0 - 0.06, DS_DOOR_Z1 + 0.06, 2.5]:
		_box(st, Vector3(1.46, 1.85, z), Vector3(0.04, 0.9, 0.05), cab_dk, 0.0, 0.2)
	# Recessed lamp housings in the roof (the lit panels: _ds_emit, DS_LAMPS).
	for z2: float in DS_LAMPS:
		_box(st, Vector3(0.0, 3.125, z2), Vector3(0.3, 0.025, 0.13), cab_dk, 0.0, 0.25)
		_box(st, Vector3(0.0, 3.1, z2), Vector3(0.27, 0.006, 0.105), C_METAL, P_BRUSHED, 0.4)
	# Cable trays along the roof with their bundles.
	for sx2: float in [-0.62, 0.62]:
		_box(st, Vector3(sx2, 3.075, 0.2), Vector3(0.1, 0.012, 2.3), cab_dk, P_VENT, 0.3)
		var cols := [C_STEEL, C_RED.darkened(0.25), Color(0.2, 0.32, 0.5, 0.5), C_YELLOW.darkened(0.3)]
		for k in 4:
			var cx := sx2 - 0.06 + float(k) * 0.04
			_cyl(st, Vector3(cx, 3.05, -2.1), Vector3(cx, 3.05, 2.5), 0.014, 0.014, cols[k], 0.0, 0.1, 6, false)
		for z3: float in [-1.6, -0.4, 0.8, 2.0]:
			_box(st, Vector3(sx2, 3.03, z3), Vector3(0.11, 0.008, 0.02), C_METAL, 0.0, 0.4)
	# Hazard trim round the door inside, the sill.
	_box(st, Vector3(1.44, DS_FLOOR + 0.01, 0.15), Vector3(0.07, 0.012, 0.8), C_YELLOW, P_HAZARD, 0.0)
	_box(st, Vector3(1.455, 2.72, 0.15), Vector3(0.035, 0.025, 0.84), C_YELLOW, P_HAZARD, 0.0)
	# Grab rails under the upper chines, hand loops hanging off them.
	for x: float in [-1.0, 1.0]:
		_cyl(st, Vector3(x, 2.92, -2.0), Vector3(x, 2.92, 2.45), 0.025, 0.025, C_METAL, P_BRUSHED, 0.4, 8, false)
		for z: float in [-1.6, 0.0, 1.6]:
			_cyl(st, Vector3(x, 2.92, z), Vector3(x * 1.12, 3.0, z), 0.015, 0.015, C_METAL, 0.0, 0.4, 5, false)
		for z4: float in [-1.3, -0.5, 0.3]:
			_box(st, Vector3(x, 2.8, z4), Vector3(0.012, 0.1, 0.035), Color(0.16, 0.16, 0.17, 0.85), 0.0, 0.0)
			_box(st, Vector3(x, 2.68, z4), Vector3(0.015, 0.02, 0.05), C_METAL, 0.0, 0.3)
	# Vent panels above the window; an equipment panel and a med kit behind the door.
	for z5: float in [-1.45, -0.15]:
		_box(st, Vector3(-1.485, 2.6, z5), Vector3(0.012, 0.09, 0.42), cab_dk, P_VENT, 0.2)
	_box(st, Vector3(1.475, 2.42, 1.75), Vector3(0.02, 0.2, 0.5), cab_dk, 0.3, 0.15)
	for k2 in 6:
		_box(st, Vector3(1.452, 2.48 - float(k2 / 3) * 0.12, 1.45 + float(k2 % 3) * 0.1), Vector3(0.008, 0.02, 0.012), C_METAL, 0.0, 0.4)
	_box(st, Vector3(1.47, 2.42, 2.12), Vector3(0.02, 0.1, 0.12), Color(0.82, 0.82, 0.8, 0.5), 0.0, 0.0)
	_box(st, Vector3(1.455, 2.42, 2.12), Vector3(0.004, 0.06, 0.018), C_RED, 0.0, 0.0)
	_box(st, Vector3(1.455, 2.42, 2.12), Vector3(0.004, 0.018, 0.06), C_RED, 0.0, 0.0)
	# The wall screen's bezel (right wall, ahead of the door: DS_WALL_SCREEN).
	_box(st, DS_WALL_SCREEN + Vector3(0.035, 0.0, 0.0), Vector3(0.03, DS_WALL_SCREEN_SIZE.y * 0.5 + 0.035,
			DS_WALL_SCREEN_SIZE.x * 0.5 + 0.035), cab_dk, 0.0, 0.25)
	# Lockers on the rear bulkhead, a red extinguisher, oxygen bottles, a stripe.
	for x: float in [-0.92, 0.92]:
		_box(st, Vector3(x, 1.85, 2.52), Vector3(0.42, 0.85, 0.08), cab, 0.4, 0.1)
		_box(st, Vector3(x + 0.3 * signf(x), 1.85, 2.43), Vector3(0.02, 0.12, 0.02), C_METAL, 0.0, 0.4)
	_cyl(st, Vector3(-0.35, 1.0, 2.45), Vector3(-0.35, 1.5, 2.45), 0.075, 0.075, C_RED, 0.0, 0.1, 10)
	for ox: float in [0.3, 0.52]:
		_cyl(st, Vector3(ox, 1.0, 2.36), Vector3(ox, 1.78, 2.36), 0.09, 0.09, Color(0.32, 0.48, 0.36, 0.45), 0.0, 0.2, 12)
		_cyl(st, Vector3(ox, 1.78, 2.36), Vector3(ox, 1.86, 2.36), 0.04, 0.03, C_METAL, 0.0, 0.4, 8)
	_box(st, Vector3(0.41, 1.5, 2.33), Vector3(0.2, 0.025, 0.1), Color(0.16, 0.16, 0.17, 0.85), 0.0, 0.0)
	_box(st, Vector3(0.0, 2.85, 2.56), Vector3(1.0, 0.04, 0.02), stripe, 0.0, 0.0)
	# The console in the nose: body, screen bezels on its sloping top, a grille and switch rows on its
	# face, a hand rail.
	_hexa(st, [Vector3(-0.8, DS_FLOOR, -2.6), Vector3(0.8, DS_FLOOR, -2.6), Vector3(0.72, DS_FLOOR, -3.5), Vector3(-0.72, DS_FLOOR, -3.5),
			Vector3(-0.8, 1.45, -2.6), Vector3(0.8, 1.45, -2.6), Vector3(0.72, 1.75, -3.5), Vector3(-0.72, 1.75, -3.5)], cab_dk, 0.35, 0.1)
	_box(st, Vector3(0.0, 1.47, -2.58), Vector3(0.82, 0.025, 0.04), C_METAL, P_BRUSHED, 0.4)
	var cb := console_basis()
	for i in 3:
		_box(st, console_screen_pos(i) - cb.y * 0.012, Vector3(DS_SCREEN_SIZE.x * 0.5 + 0.025, 0.01, DS_SCREEN_SIZE.y * 0.5 + 0.025),
				Color(0.1, 0.1, 0.11, 0.3), 0.0, 0.3, cb)
	_box(st, Vector3(0.0, 1.17, -2.595), Vector3(0.6, 0.13, 0.008), Color(0.18, 0.18, 0.19, 0.7), P_VENT, 0.2)
	for i2 in 10:
		_box(st, Vector3(-0.45 + float(i2) * 0.1, 1.37, -2.59), Vector3(0.018, 0.022, 0.012), C_STEEL if i2 % 3 != 1 else C_YELLOW, 0.0, 0.3)
	_cyl(st, Vector3(-0.75, 1.52, -2.55), Vector3(0.75, 1.52, -2.55), 0.018, 0.018, C_METAL, P_BRUSHED, 0.45, 8, false)
	for sx3: float in [-0.75, 0.75]:
		_cyl(st, Vector3(sx3, 1.45, -2.58), Vector3(sx3, 1.52, -2.55), 0.014, 0.014, C_METAL, 0.0, 0.45, 6, false)


## A bench along a side wall: seat, legs, quilted back against the wall (`side` -1 left, +1 right), a
## harness (two dark straps with a buckle) per seat.
static func _bench(st: SurfaceTool, c: Vector3, half_len: float, side: float, seat: Color, frame: Color) -> void:
	_box(st, Vector3(c.x, 1.32, c.z), Vector3(0.27, 0.05, half_len), seat, P_QUILT, 0.0)
	_box(st, Vector3(c.x, 1.25, c.z), Vector3(0.25, 0.02, half_len - 0.02), frame, 0.0, 0.3)
	for k: float in [-1.0, 1.0]:
		_box(st, Vector3(c.x - side * 0.12, 1.1, c.z + k * (half_len - 0.1)), Vector3(0.03, 0.15, 0.03), C_STEEL, 0.0, 0.3)
	_box(st, Vector3(c.x + side * 0.24, 1.78, c.z), Vector3(0.04, 0.38, half_len), seat, P_QUILT, 0.0)
	var n := maxi(1, int(round(half_len * 2.0 / 0.6)))
	for i in n:
		var z := c.z - half_len + (float(i) + 0.5) * (half_len * 2.0 / float(n))
		for dz: float in [-0.09, 0.09]:
			_box(st, Vector3(c.x + side * 0.195, 1.82, z + dz), Vector3(0.006, 0.3, 0.022), C_STRAP, 0.0, 0.0)
		_box(st, Vector3(c.x + side * 0.19, 1.62, z), Vector3(0.01, 0.035, 0.07), C_METAL, 0.0, 0.45)


const C_STRAP := Color(0.17, 0.17, 0.18, 0.85)
## Roof lamp housings (z), the console's screens (centres on its sloping top, size along x / along the
## slope) and the wall screen on the right wall ahead of the door (centre, size along z / y).
const DS_LAMPS := [-1.45, -0.05, 1.08, 2.02]
const DS_SCREEN_SIZE := Vector2(0.4, 0.3)
const DS_WALL_SCREEN := Vector3(1.43, 2.45, -1.4)
const DS_WALL_SCREEN_SIZE := Vector2(0.84, 0.42)


## The console's sloping top: x across, y its normal (up, tilted toward the cabin), z down the slope
## toward the cabin.
static func console_basis() -> Basis:
	var n := Vector3(0.0, 0.9, 0.3).normalized()
	return Basis(Vector3.RIGHT, n, Vector3.RIGHT.cross(n))


## Centre of console screen i (0 left, 1 middle, 2 right), just above the surface.
static func console_screen_pos(i: int) -> Vector3:
	var cb := console_basis()
	return Vector3(0.0, 1.6, -3.05) + cb.x * (float(i) - 1.0) * 0.47 + cb.y * 0.024 + cb.z * 0.05


## Emissive bits (EMIT shader): engine and lift glow, nav lights, strobe, landing lens, door running
## lights; inside the roof lamp panels (warm, soft), wall lamps, the floor's cool guide lights, the
## console's LEDs and status strip.
static func _ds_emit(lv: Dictionary) -> ArrayMesh:
	var st := _new_st()
	var lamp: Color = lv["lamp"]
	for p: Vector3 in DS_MAIN:
		_disc(st, p + Vector3(0.0, 0.0, 0.03), Vector3.BACK, 0.3, Color(0.55, 0.78, 1.0, 1.0), E_ENGINE)
	for p2: Vector3 in DS_LIFT:
		_disc(st, p2 + Vector3(0.0, 0.03, 0.0), Vector3.DOWN, 0.2, Color(0.6, 0.82, 1.0, 1.0), E_LIFT)
	# Nav lights on the front sponsons (red port, green starboard), the strobe on the fin.
	_box(st, Vector3(-1.98, 0.86, -1.95), Vector3(0.02, 0.04, 0.06), Color(1.0, 0.18, 0.12, 1.0), E_NAV, 0.0)
	_box(st, Vector3(1.98, 0.86, -1.95), Vector3(0.02, 0.04, 0.06), Color(0.2, 1.0, 0.35, 1.0), E_NAV, 0.0)
	_box(st, DS_STROBE, Vector3(0.04, 0.03, 0.06), lv["strobe"], E_STROBE, 0.0)
	_box(st, Vector3(0.0, 1.0, 2.62), Vector3(0.9, 0.02, 0.01), Color(1.0, 0.3, 0.2, 0.6), E_NAV, 0.0)
	# Landing light lenses under the nose.
	for x: float in [-0.2, 0.2]:
		_disc(st, Vector3(x, 0.795, -3.35), Vector3(0.0, -1.0, -0.4).normalized(), 0.07, Color(1.0, 0.95, 0.85, 1.0), E_LAND)
	# Door running lights (outside, pulsing amber).
	for z: float in [DS_DOOR_Z0 - 0.05, DS_DOOR_Z1 + 0.05]:
		_box(st, Vector3(1.585, 1.85, z), Vector3(0.006, 0.8, 0.012), Color(1.0, 0.72, 0.3, 0.8), E_PULSE, 0.0)
	# Cabin: soft warm roof panels (in their housings), dim wall lamps, cool floor guide lights.
	for z2: float in DS_LAMPS:
		_box(st, Vector3(0.0, 3.092, z2), Vector3(0.24, 0.003, 0.085), Color(lamp.r, lamp.g, lamp.b, 0.22), E_STEADY, 0.0)
	for z3: float in [1.0, 2.05]:
		_box(st, Vector3(-1.453, 2.62, z3), Vector3(0.004, 0.025, 0.09), Color(lamp.r, lamp.g, lamp.b, 0.25), E_STEADY, 0.0)
	var guide := Color(0.35, 0.72, 1.0, 0.45)
	for sx: float in [-0.86, 0.86]:
		var z4 := -2.0
		while z4 < 2.35:
			_box(st, Vector3(sx, DS_FLOOR + 0.004, z4), Vector3(0.018, 0.003, 0.03), guide, E_STEADY, 0.0)
			z4 += 0.42
	for k in 5:
		_box(st, Vector3(1.43, DS_FLOOR + 0.025, -0.5 + float(k) * 0.32), Vector3(0.012, 0.004, 0.05), Color(1.0, 0.72, 0.3, 0.6), E_PULSE, float(k) * 0.12)
	# Console: LED rows along its front edge, a cool status strip under the screens.
	var cb := console_basis()
	var top := Vector3(0.0, 1.6, -3.05) + cb.y * 0.013
	for i in 8:
		_box(st, top + cb.x * (-0.66 + float(i) * 0.19) + cb.z * 0.4, Vector3(0.012, 0.003, 0.008),
				Color(0.4, 0.95, 0.55, 1.0) if i % 3 != 1 else Color(1.0, 0.55, 0.2, 1.0), E_PULSE, float(i) * 0.17, cb)
	_box(st, top + cb.z * 0.33, Vector3(0.7, 0.003, 0.006), Color(0.35, 0.8, 1.0, 0.5), E_STEADY, 0.0, cb)
	for i2 in 10:
		_box(st, Vector3(-0.45 + float(i2) * 0.1, 1.405, -2.585), Vector3(0.006, 0.004, 0.003),
				Color(0.45, 0.95, 0.6, 1.0) if i2 % 4 != 2 else Color(1.0, 0.3, 0.2, 1.0), E_PULSE, float(i2) * 0.31)
	# Locker status LEDs.
	for x2: float in [-0.92, 0.92]:
		_box(st, Vector3(x2 - 0.3 * signf(x2), 2.5, 2.43), Vector3(0.015, 0.008, 0.005), Color(0.45, 0.95, 0.6, 1.0), E_PULSE, x2)
	return _commit(st)


## The ramp-door, built about its hinge (local origin = DS_HINGE), closed: the panel stands up from
## the sill (local y 0..DS_DOOR_H), its outer face at x = 0.06, the tread plate inside (x = 0).
static func _ds_ramp(lv: Dictionary) -> ArrayMesh:
	var st := _new_st()
	var paint: Color = lv["paint"]
	var half_z := (DS_DOOR_Z1 - DS_DOOR_Z0) * 0.5 - 0.02
	_box(st, Vector3(0.045, DS_DOOR_H * 0.5, 0.0), Vector3(0.016, DS_DOOR_H * 0.5, half_z), paint, 0.7, 0.0)
	_box(st, Vector3(0.014, DS_DOOR_H * 0.5, 0.0), Vector3(0.015, DS_DOOR_H * 0.5 - 0.02, half_z - 0.02), C_STEEL, P_TREAD, 0.2)
	_box(st, Vector3(0.064, DS_DOOR_H - 0.23, 0.0), Vector3(0.004, 0.07, half_z), lv["stripe"], 0.0, 0.0)
	# Rails along both edges (become the ramp's side rails) and a lip at the free end.
	for z: float in [-half_z + 0.03, half_z - 0.03]:
		_box(st, Vector3(-0.02, DS_DOOR_H * 0.5, z), Vector3(0.025, DS_DOOR_H * 0.5, 0.025), lv["dark"], 0.0, 0.2)
	_box(st, Vector3(0.03, DS_DOOR_H - 0.02, 0.0), Vector3(0.04, 0.02, half_z), C_YELLOW, P_HAZARD, 0.0)
	return _commit(st)


# ==================================================================================================
# Taşıyıcı
# ==================================================================================================

## The hull. Seen from the ground it is mostly its underside, which never faces the sun: that side is
## a light plated grey ("under", "keel"), broken up by greebles, hangar doors and the docking bays.
static func _cv_hull(lv: Dictionary) -> ArrayMesh:
	var st := _new_st()
	var paint: Color = lv["paint"]
	var dark: Color = lv["dark"]
	var stripe: Color = lv["stripe"]
	var under: Color = lv["under"]
	var keel: Color = lv["keel"]
	var ref := Vector3.ZERO
	# Main hull, the two-step prow, the flare into the engine block. Faces: 0 belly, 1 / 7 lower bevels,
	# 2 / 6 flanks, 3 / 5 upper bevels, 4 deck.
	var hc := [under, under, paint, paint, paint, paint, paint, under]
	var hp := [2.2, 2.0, 2.4, 2.4, 2.4, 2.8, 2.4, 2.0]
	_loft(st, CV_SEC, CV_Z_FRONT, CV_SEC, CV_Z_REAR, ref, hc, hp)
	_loft(st, CV_MID, CV_Z_MID, CV_SEC, CV_Z_FRONT, Vector3(0, 0, -24.0), hc, hp)
	_loft(st, CV_PROW, CV_Z_PROW, CV_MID, CV_Z_MID, Vector3(0, -0.5, -30.0), hc, hp)
	_face(st, _sec3(CV_PROW, CV_Z_PROW), Vector3(0, -0.5, -30.0), dark, 1.0, 0.0)
	_loft(st, CV_SEC, CV_Z_REAR, CV_ENG, CV_Z_ENG0, Vector3(0, 0, 19.0), [under, under, paint, paint, paint, paint, paint, under],
			[1.6, 1.6, 2.0, 2.0, 2.0, 2.0, 2.0, 1.6])
	_loft(st, CV_ENG, CV_Z_ENG0, CV_ENG, CV_Z_ENG1, Vector3(0, 0, 23.0), [keel, dark, dark, dark, dark, dark, dark, dark],
			[1.2, 1.2, P_VENT, 1.4, 1.4, 1.4, P_VENT, 1.2])
	_face(st, _sec3(CV_ENG, CV_Z_ENG1), Vector3(0, 0, 23.0), dark, 1.0, 0.1)
	# Livery stripes along the flanks and a prow band.
	for sx: float in [-1.0, 1.0]:
		_box(st, Vector3(sx * 7.53, 1.15, -1.5), Vector3(0.05, 0.16, 19.0), stripe, 0.0, 0.0)
		_box(st, Vector3(sx * 7.53, -0.95, -1.5), Vector3(0.05, 0.08, 19.0), stripe, 0.0, 0.0)
		_box(st, Vector3(sx * 5.7, 0.0, -27.5), Vector3(0.12, 0.9, 0.6), C_YELLOW, P_HAZARD, 0.0, Basis(Vector3.UP, sx * 0.2))
	# Superstructure: a long deck block, the bridge with its slanted front, a mast and a dish.
	_hexa(st, [Vector3(-4.2, 3.4, 0.0), Vector3(4.2, 3.4, 0.0), Vector3(4.2, 3.4, 16.0), Vector3(-4.2, 3.4, 16.0),
			Vector3(-4.0, 5.8, 3.0), Vector3(4.0, 5.8, 3.0), Vector3(4.0, 5.8, 15.5), Vector3(-4.0, 5.8, 15.5)], paint, 1.8, 0.0)
	_hexa(st, [Vector3(-2.8, 5.8, 5.0), Vector3(2.8, 5.8, 5.0), Vector3(2.8, 5.8, 12.5), Vector3(-2.8, 5.8, 12.5),
			Vector3(-2.5, 8.2, 6.6), Vector3(2.5, 8.2, 6.6), Vector3(2.6, 8.2, 12.2), Vector3(-2.6, 8.2, 12.2)], paint, 1.4, 0.0)
	_box(st, Vector3(0.0, 8.35, 9.5), Vector3(2.0, 0.15, 2.4), dark, 0.0, 0.2)
	_cyl(st, Vector3(0.0, 8.4, 9.0), CV_MAST_TOP, 0.18, 0.08, C_METAL, 0.0, 0.3, 8)
	_cyl(st, Vector3(-1.2, 11.6, 9.0), Vector3(1.2, 11.6, 9.0), 0.05, 0.05, C_METAL, 0.0, 0.3, 6)
	_cyl(st, Vector3(0.0, 10.2, 8.4), Vector3(0.0, 10.2, 7.2), 0.05, 0.05, C_METAL, 0.0, 0.3, 6)
	_lathe(st, Transform3D(Basis(Vector3.RIGHT, -0.7), Vector3(1.6, 8.6, 11.3)), [Vector2(0.0, 0.32), Vector2(0.5, 0.2),
			Vector2(0.95, 0.0)], C_METAL, 0.0, 0.2, 14)
	_lathe(st, Transform3D(Basis(Vector3.RIGHT, -0.7), Vector3(1.6, 8.6, 11.3)), [Vector2(0.0, 0.3), Vector2(0.5, 0.18),
			Vector2(0.93, -0.02)], dark, 0.0, 0.1, 14, true)
	# Dorsal spine with radiator fins.
	_box(st, Vector3(0.0, 3.8, -9.0), Vector3(1.0, 0.4, 11.0), dark, 1.0, 0.1)
	for k in 5:
		var z := -18.0 + float(k) * 3.6
		for sx2: float in [-1.0, 1.0]:
			_box(st, Vector3(sx2 * 2.6, 4.6, z), Vector3(1.5, 1.0, 0.06), dark, P_VENT, 0.15)
	# Hangar sponsons along both flanks (tapered fronts): a plated underside with three hangar doors
	# each (dark recessed leaves in a light frame).
	for sx3: float in [-1.0, 1.0]:
		var xi := sx3 * 7.4
		var xo := sx3 * 10.2
		_hexa(st, [Vector3(xi, -2.6, -12.0), Vector3(xo, -2.6, -9.0), Vector3(xo, -2.6, 11.0), Vector3(xi, -2.6, 11.0),
				Vector3(xi, 1.6, -12.0), Vector3(xo, 1.6, -9.0), Vector3(xo, 1.6, 11.0), Vector3(xi, 1.6, 11.0)], paint, 2.0, 0.0)
		_box(st, Vector3(sx3 * 10.22, 1.25, 1.0), Vector3(0.04, 0.12, 9.8), stripe, 0.0, 0.0)
		_box(st, Vector3(sx3 * 8.8, -2.64, 1.0), Vector3(1.36, 0.04, 9.85), under, 1.6, 0.0)
		for zd: float in [-5.5, 1.0, 7.5]:
			_box(st, Vector3(sx3 * 8.8, -2.69, zd), Vector3(1.0, 0.02, 2.6), keel, 0.0, 0.15)
			_box(st, Vector3(sx3 * 8.8, -2.71, zd), Vector3(0.48, 0.012, 2.5), dark, P_VENT, 0.1)
			_box(st, Vector3(sx3 * 8.8 - 0.5, -2.71, zd), Vector3(0.012, 0.014, 2.5), C_STEEL, 0.0, 0.3)
			_box(st, Vector3(sx3 * 8.8 + 0.5, -2.71, zd), Vector3(0.012, 0.014, 2.5), C_STEEL, 0.0, 0.3)
		# Pipes along the hull under the sponsons, with brackets.
		_cyl(st, Vector3(sx3 * 7.2, -2.0, -19.0), Vector3(sx3 * 7.2, -2.0, 17.0), 0.22, 0.22, C_STEEL, P_BRUSHED, 0.3, 8)
		_cyl(st, Vector3(sx3 * 6.4, -2.9, -19.0), Vector3(sx3 * 6.4, -2.9, 17.0), 0.16, 0.16, C_STEEL, P_BRUSHED, 0.3, 8)
		var zb := -18.0
		while zb < 17.0:
			_box(st, Vector3(sx3 * 6.8, -2.5, zb), Vector3(0.65, 0.08, 0.12), keel, 0.0, 0.2)
			zb += 4.0
	# Belly greebles between the keel and the pipes (fixed seed: the same ship every run).
	var rng := RandomNumberGenerator.new()
	rng.seed = 2207
	for sx4: float in [-1.0, 1.0]:
		var zg := -19.5
		while zg < 16.5:
			var w := rng.randf_range(0.35, 0.9)
			var l := rng.randf_range(0.5, 1.8)
			var h := rng.randf_range(0.08, 0.3)
			var x := sx4 * rng.randf_range(3.9, 5.0)
			var c := [under.darkened(0.12), keel, C_STEEL, under][rng.randi() % 4] as Color
			_box(st, Vector3(x, -3.4 - h, zg + l), Vector3(w, h, l), c, 0.0 if rng.randf() < 0.6 else P_VENT, 0.15)
			if rng.randf() < 0.3:
				_cyl(st, Vector3(x, -3.4 - h * 2.0, zg + l), Vector3(x, -3.4 - h * 2.0 - 0.25, zg + l), 0.22, 0.16, C_METAL, 0.0, 0.3, 10)
			zg += l * 2.0 + rng.randf_range(0.4, 1.6)
	# Keel: plated, the docking bays (a darker recess, a hazard frame, the clamps).
	_box(st, Vector3(0.0, (CV_KEEL_Y - 3.4) * 0.5, -1.0), Vector3(3.6, (3.4 + CV_KEEL_Y) * -0.5, 16.0), keel, 1.4, 0.15)
	for zc: float in CV_SLOT_Z:
		_box(st, Vector3(0.0, CV_KEEL_Y - 0.01, zc), Vector3(1.5, 0.012, 2.3), lv["dark"], P_TREAD, 0.2)
		for e: Array in [[Vector3(0.0, 0.0, -2.38), Vector3(1.62, 0.016, 0.08)], [Vector3(0.0, 0.0, 2.38), Vector3(1.62, 0.016, 0.08)],
				[Vector3(-1.58, 0.0, 0.0), Vector3(0.08, 0.016, 2.3)], [Vector3(1.58, 0.0, 0.0), Vector3(0.08, 0.016, 2.3)]]:
			_box(st, Vector3(0.0, CV_KEEL_Y - 0.02, zc) + (e[0] as Vector3), e[1], C_YELLOW, P_HAZARD, 0.0)
		for dz: float in [-1.4, 1.4]:
			for ax: float in [-0.65, 0.65]:
				_box(st, Vector3(ax, (CV_KEEL_Y + CV_CLAMP_Y) * 0.5, zc + dz), Vector3(0.28, (CV_KEEL_Y - CV_CLAMP_Y) * 0.5, 0.18), C_STEEL, 0.0, 0.3)
				_box(st, Vector3(ax, CV_CLAMP_Y + 0.04, zc + dz), Vector3(0.3, 0.04, 0.3), C_RUBBER, P_RUBBER, 0.0)
	# Engines: three big bells and their throats, four manoeuvring nozzles.
	var to_z := Basis(Vector3.RIGHT, PI * 0.5)
	for p: Vector3 in CV_NOZZLES:
		var xf := Transform3D(to_z, p)
		_lathe(st, xf, [Vector2(1.3, -0.2), Vector2(1.6, 0.4), Vector2(1.95, 1.6), Vector2(2.05, 2.3)], C_STEEL, P_NOZZLE, 0.3, 20)
		_lathe(st, xf, [Vector2(1.2, -0.2), Vector2(1.5, 0.4), Vector2(1.85, 1.6), Vector2(1.95, 2.3)], C_STEEL, P_NOZZLE, 0.3, 20, true)
	for c2: Vector2 in [Vector2(-7.2, 3.0), Vector2(7.2, 3.0), Vector2(-7.4, -3.0), Vector2(7.4, -3.0)]:
		_cyl(st, Vector3(c2.x, c2.y, CV_Z_ENG1), Vector3(c2.x, c2.y, CV_Z_ENG1 + 0.8), 0.5, 0.65, C_STEEL, P_NOZZLE, 0.3, 10, false)
	# Prow sensor cluster, a chin dome, antennas.
	_lathe(st, Transform3D(Basis(), Vector3(0.0, 1.55, -31.0)), [Vector2(0.9, 0.0), Vector2(0.8, 0.35), Vector2(0.45, 0.65),
			Vector2(0.0, 0.75)], C_METAL, 0.0, 0.2, 14)
	_lathe(st, Transform3D(Basis(Vector3.RIGHT, PI), Vector3(0.0, -3.3, -22.0)), [Vector2(1.1, 0.0), Vector2(1.0, 0.4), Vector2(0.6, 0.8),
			Vector2(0.0, 0.95)], C_METAL, 0.0, 0.2, 16)
	for k2 in 3:
		_cyl(st, Vector3(-0.8 + float(k2) * 0.8, 3.4, -18.0 + float(k2) * 1.2), Vector3(-0.8 + float(k2) * 0.8, 5.6 - float(k2) * 0.5, -18.0 + float(k2) * 1.2),
				0.06, 0.03, C_METAL, 0.0, 0.3, 5)
	return _commit(st)


## Emissive: window rows (upper and lower bevels, sponsons, the bridge band), engine throats, running
## lights along the keel (a slow chase toward the stern), belly edge lights, hangar floods, the
## docking bays' lights, nav strips.
static func _cv_emit(lv: Dictionary, key: String) -> ArrayMesh:
	var st := _new_st()
	var win: Color = lv["window"]
	var run: Color = lv["run"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711 if key == "home" else 9173
	var keep := 0.78 if key == "home" else 0.55
	for sx: float in [-1.0, 1.0]:
		# Bevels: two rows on the upper one, two on the lower one (seen from below).
		var bevels := [[Vector2(7.5, 1.4), Vector2(5.5, 3.4), [0.3, 0.62]], [Vector2(7.5, -1.2), Vector2(5.5, -3.4), [0.32, 0.66]]]
		for bv: Array in bevels:
			var p0: Vector2 = bv[0]
			var p1: Vector2 = bv[1]
			var along := Vector2(sx * (p1.x - p0.x), p1.y - p0.y).normalized()
			var bn := Vector3(along.y, -along.x, 0.0)
			if bn.dot(Vector3(sx, (p0.y + p1.y) * 0.5, 0.0)) < 0.0:
				bn = -bn
			bn = bn.normalized()
			var bb := Basis(Vector3(0.0, 0.0, 1.0).cross(bn).normalized(), bn, Vector3(0.0, 0.0, 1.0))
			for row: float in bv[2]:
				var bp := p0.lerp(p1, row)
				var z := -19.5
				while z < 16.5:
					if rng.randf() < keep:
						var c := Color(win.r, win.g, win.b, win.a * rng.randf_range(0.55, 1.0))
						_box(st, Vector3(sx * bp.x, bp.y, z) + bn * 0.015, Vector3(0.16, 0.012, 0.32), c, E_STEADY, 0.0, bb)
					z += 1.3
		# Sponson outer walls: three decks (the name sign sits between the lower two).
		for row2: float in [0.85, 0.2, -1.95]:
			var z2 := -8.0
			while z2 < 10.5:
				if rng.randf() < keep:
					_box(st, Vector3(sx * 10.215, row2, z2), Vector3(0.012, 0.14, 0.3), Color(win.r, win.g, win.b, win.a * rng.randf_range(0.5, 1.0)), E_STEADY, 0.0)
				z2 += 1.1
		# Superstructure side rows.
		var z3 := 1.0
		while z3 < 15.5:
			if rng.randf() < keep:
				_box(st, Vector3(sx * 4.12, 4.7, z3), Vector3(0.012, 0.18, 0.35), Color(win.r, win.g, win.b, win.a * 0.8), E_STEADY, 0.0)
			z3 += 1.2
		# Keel running lights: a chase toward the stern (EMIT pulse, phase along z).
		var zk := -16.5
		while zk < 15.0:
			_box(st, Vector3(sx * 3.42, CV_KEEL_Y - 0.014, zk), Vector3(0.1, 0.012, 0.2), Color(run.r, run.g, run.b, 0.9), E_PULSE, -zk / 24.0)
			zk += 1.5
		# Belly edge lights (the belly / lower bevel corner), steady.
		var ze := -18.0
		while ze < 16.0:
			_box(st, Vector3(sx * 5.45, -3.415, ze), Vector3(0.08, 0.012, 0.08), Color(1.0, 0.95, 0.88, 0.8), E_STEADY, 0.0)
			ze += 3.5
		# Hangar floods under the sponsons: two panels per door, amber corner lights.
		for zd: float in [-5.5, 1.0, 7.5]:
			for dz: float in [-1.6, 1.6]:
				_box(st, Vector3(sx * 8.8 + sx * 0.75, -2.72, zd + dz), Vector3(0.08, 0.008, 0.5), Color(1.0, 0.93, 0.8, 0.32), E_STEADY, 0.0)
			_box(st, Vector3(sx * 8.8 - sx * 0.85, -2.72, zd - 2.45), Vector3(0.06, 0.008, 0.06), Color(1.0, 0.65, 0.25, 1.0), E_PULSE, zd * 0.05)
	# The bridge: a lit band across its slanted front.
	var a := Vector3(-2.3, 6.4, 5.45)
	var b := Vector3(2.3, 6.4, 5.45)
	var n := Vector3(0.0, 0.55, -0.83).normalized()
	var fb := Basis(Vector3.RIGHT, n, Vector3.RIGHT.cross(n))
	for i in 9:
		var p := a.lerp(b, (float(i) + 0.5) / 9.0) + Vector3(0.0, 0.55, 0.37) + n * 0.03
		_box(st, p, Vector3(0.2, 0.01, 0.22), Color(win.r, win.g, win.b, 1.0), E_STEADY, 0.0, fb)
	# Engine throats (idle glow driven by the material's `engine`).
	for p2: Vector3 in CV_NOZZLES:
		_disc(st, p2 + Vector3(0.0, 0.0, 0.05), Vector3.BACK, 1.25, Color(0.55, 0.78, 1.0, 1.0), E_ENGINE)
	# Docking bays: lit plates inside the hazard frames, bay lights on the keel's flanks, guide lights.
	for zc: float in CV_SLOT_Z:
		for dx: float in [-0.9, 0.0, 0.9]:
			_box(st, Vector3(dx, CV_KEEL_Y - 0.024, zc), Vector3(0.07, 0.006, 1.6), Color(1.0, 0.85, 0.65, 0.1), E_STEADY, 0.0)
		for sx5: float in [-1.0, 1.0]:
			_box(st, Vector3(sx5 * 3.62, CV_KEEL_Y + 0.3, zc), Vector3(0.012, 0.08, 1.6), Color(1.0, 0.9, 0.75, 0.6), E_STEADY, 0.0)
			_box(st, Vector3(sx5 * 1.7, CV_KEEL_Y - 0.03, zc - 2.3), Vector3(0.1, 0.012, 0.1), Color(1.0, 0.7, 0.3, 1.0), E_PULSE, zc * 0.1)
	# Under the prow: two rows of approach lights.
	for k in 6:
		var zp := CV_Z_PROW + 1.0 + float(k) * 1.15
		var kk := (zp - CV_Z_PROW) / (CV_Z_MID - CV_Z_PROW)
		var yb := lerpf(-2.0, -3.2, kk)
		var xb := lerpf(1.6, 4.0, kk) * 0.7
		for sx6: float in [-1.0, 1.0]:
			_box(st, Vector3(sx6 * xb, yb - 0.014, zp), Vector3(0.07, 0.01, 0.07), Color(run.r, run.g, run.b, 1.0), E_PULSE, float(k) * 0.12)
	# Nav strips at the sponson fronts (red port, green starboard).
	_box(st, Vector3(-10.0, -0.5, -9.2), Vector3(0.2, 0.6, 0.02), Color(1.0, 0.18, 0.12, 1.0), E_NAV, 0.0)
	_box(st, Vector3(10.0, -0.5, -9.2), Vector3(0.2, 0.6, 0.02), Color(0.2, 1.0, 0.35, 1.0), E_NAV, 0.0)
	return _commit(st)
