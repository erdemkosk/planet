extends RefCounted
## Geometry of the Mekik (scripts/craft/skiff.gd). Procedural meshes in the ship frame (-Z forward,
## +Y up, origin = the ground point under the feet with the legs at their nominal length), built
## once per run and shared by every Mekik; the materials belong to each ship (damage soot, power,
## lights).
##
## The ship: a 4.6 m teardrop pod, 2.1 m wide (2.4 m over the nacelles), 2.0 m tall. Its upper half
## is a glass bubble over a two-seat cabin (side by side, the pilot on the left). Two side nacelles
## carry the four lift jets and the four stubby legs; one main engine sits in the tail.
## Vertex data for the hull shader (skiff_shaders.gd HULL): COLOR = albedo (sRGB) + roughness in
## alpha, UV = metres, UV2 = (pattern, metallic). Emissive bits (EMIT): COLOR = colour + intensity,
## UV2 = (mode, phase).

const Shaders := preload("res://scripts/craft/skiff_shaders.gd")
const UI := preload("res://scripts/ui/ui_style.gd")

# --- Hull loft -------------------------------------------------------------------------------------
## Cross-sections: [z, centre y, half width, height above the centre, depth below it]. A
## superellipse (exponent N_EXP) through them; the glass replaces the upper half from ZC0 to ZC1.
const KEYS := [
	[-2.32, 1.00, 0.06, 0.03, 0.06],
	[-2.24, 1.00, 0.34, 0.09, 0.24],
	[-2.08, 1.02, 0.60, 0.14, 0.41],
	[-1.85, 1.05, 0.80, 0.17, 0.54],
	[-1.55, 1.09, 0.93, 0.58, 0.62],
	[-1.15, 1.12, 1.01, 0.76, 0.66],
	[-0.60, 1.14, 1.05, 0.85, 0.68],
	[-0.05, 1.15, 1.05, 0.86, 0.68],
	[0.40, 1.15, 1.02, 0.78, 0.68],
	[0.85, 1.16, 0.95, 0.60, 0.66],
	[1.35, 1.17, 0.85, 0.46, 0.60],
	[1.85, 1.19, 0.71, 0.37, 0.52],
	[2.20, 1.20, 0.57, 0.31, 0.45],
	[2.32, 1.20, 0.52, 0.29, 0.42],
]
const N_EXP := 2.5
const ZC0 := -1.85                 # glass from here...
const ZC1 := 0.40                  # ...to here (rear bulkhead)
const SKIN := 0.035                # hull wall (cabin tub)
const FLOOR_Y := 0.60
const Z_NOSE := -2.32
const Z_TAIL := 2.32

# --- Cabin -----------------------------------------------------------------------------------------
const SEAT_X := 0.38
## Pilot's eye (left seat).
const EYE := Vector3(-0.38, 1.50, -0.20)
## Where the (hidden) pilot body rides: on the left seat pan.
const SEAT_POS := Vector3(-0.38, 0.80, -0.30)
## Instrument face of the dash: centre height / z and its normal (tilted up toward the eyes).
const DASH_FACE := Vector3(0.0, 1.005, -1.06)
const DASH_N := Vector3(0.0, 0.38, 0.92)
const STICK_POS := Vector3(-0.38, 0.62, -0.78)
const THROTTLE_POS := Vector3(-0.065, 0.83, -0.42)

# --- Nacelles, legs, engines -----------------------------------------------------------------------
const NAC_X := 0.98
const NAC_Y := 0.62
const NAC_R := 0.21
## Footpads at nominal leg length (the ship frame's ground plane is y = 0).
const FEET := [Vector3(-1.0, 0.0, -1.15), Vector3(1.0, 0.0, -1.15), Vector3(-1.0, 0.0, 1.35), Vector3(1.0, 0.0, 1.35)]
const STRUT_BOTTOM := 0.24
## Lift-jet nozzle exits (pointing down) and the main nozzle exit (pointing back, +Z).
const VTOL := [Vector3(-0.98, 0.37, -0.72), Vector3(0.98, 0.37, -0.72), Vector3(-0.98, 0.37, 0.95), Vector3(0.98, 0.37, 0.95)]
const MAIN_Y := 1.18
const MAIN_EXIT := Vector3(0.0, 1.18, 2.62)
const LAND_LIGHT := Vector3(0.0, 0.52, -1.98)
const STROBE := Vector3(0.0, 1.95, 2.02)

# --- Paint (sRGB, alpha = roughness) ---------------------------------------------------------------
const C_WHITE := Color(0.80, 0.80, 0.78, 0.42)
const C_ORANGE := Color(0.86, 0.42, 0.12, 0.45)
const C_GRAPHITE := Color(0.24, 0.25, 0.27, 0.58)
const C_MATTE := Color(0.2, 0.21, 0.22, 0.8)
const C_STEEL := Color(0.36, 0.37, 0.39, 0.45)
const C_METAL := Color(0.6, 0.61, 0.63, 0.36)
const C_CHROME := Color(0.74, 0.75, 0.77, 0.2)
const C_RUBBER := Color(0.2, 0.2, 0.21, 0.9)
const C_CABIN := Color(0.38, 0.39, 0.41, 0.62)
const C_CABIN_DK := Color(0.25, 0.26, 0.28, 0.72)
const C_SEAT := Color(0.31, 0.32, 0.34, 0.86)
const C_LEATHER := Color(0.5, 0.31, 0.17, 0.7)
const C_STRAP := Color(0.7, 0.44, 0.14, 0.8)
const C_YELLOW := Color(0.9, 0.72, 0.2, 0.5)
const C_RED := Color(0.72, 0.15, 0.1, 0.4)

# Pattern codes (UV2.x) of the hull shader.
const P_PLAIN := 0.0
const P_HAZARD := -1.0
const P_TREAD := -2.0
const P_QUILT := -3.0
const P_RUBBER := -4.0
const P_NOZZLE := -5.0
const P_VENT := -6.0
const P_TILES := -7.0
const P_BRUSHED := -8.0

## Liveries: [paint, stripe colour, strobe colour, stripe pattern]. home = white with an orange
## pinstripe, white strobe; rival = dark gunmetal with red stripes and a red strobe (light lettering,
## add_decals); armed (the Silahlı Mekik, armed_skiff.gd) = dark olive armour, yellow / black hazard
## stripes, white strobe.
const LIVERY := {
	"home": [Color(0.80, 0.80, 0.78, 0.42), Color(0.86, 0.42, 0.12, 0.45), Color(1.0, 1.0, 1.0, 1.0), 0.0],
	"rival": [Color(0.31, 0.30, 0.30, 0.46), Color(0.76, 0.15, 0.1, 0.45), Color(1.0, 0.22, 0.16, 1.0), 0.0],
	"armed": [Color(0.34, 0.36, 0.32, 0.55), Color(0.9, 0.72, 0.2, 0.5), Color(1.0, 1.0, 1.0, 1.0), -1.0],
	# The rival's Silahlı Mekik (AI pilot): the rival gunmetal with red / black hazard stripes.
	"rival_armed": [Color(0.29, 0.28, 0.28, 0.5), Color(0.8, 0.16, 0.1, 0.5), Color(1.0, 0.22, 0.16, 1.0), -1.0],
}

static var _sets := {}           # livery -> {hull, leds} + the shared meshes
static var _shared := {}
# The livery being built (the exterior builders read these).
static var _paint := C_WHITE
static var _stripe := C_ORANGE
static var _stripe_pat := 0.0
static var _tip_mesh: ArrayMesh
static var _strobe_col := Color(1.0, 1.0, 1.0, 1.0)


## Every mesh of a livery, built on first use: hull, leds (per livery; "armed" also weapons,
## barrels, flash); cabin, glass, foot, stick, throttle (shared).
static func meshes(team := "home") -> Dictionary:
	var key := team if LIVERY.has(team) else "home"
	if _sets.has(key):
		return _sets[key]
	if _shared.is_empty():
		_shared["cabin"] = _build_cabin()
		_shared["glass"] = _build_glass()
		_shared["foot"] = _build_foot()
		_shared["stick"] = _build_stick()
		_shared["throttle"] = _build_throttle()
	var lv: Array = LIVERY[key]
	_paint = lv[0]
	_stripe = lv[1]
	_strobe_col = lv[2]
	_stripe_pat = float(lv[3])
	var d := {"hull": _build_hull(), "leds": _build_leds()}
	if key == "armed" or key == "rival_armed":
		d["weapons"] = _build_weapons()
		d["barrels"] = _build_barrels()
		d["flash"] = _build_flash()
	d.merge(_shared)
	_sets[key] = d
	return d


# ==================================================================================================
# Materials (one set per ship)
# ==================================================================================================

static func hull_material(interior := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Shaders.shader("hull")
	if interior:
		m.set_shader_parameter("ambient_k", 0.82)
		m.set_shader_parameter("grime", 0.06)
		m.set_shader_parameter("wear", 0.25)
		m.set_shader_parameter("seam_w", 0.003)
	return m


static func glass_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Shaders.shader("glass")
	m.render_priority = 1
	return m


static func emit_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Shaders.shader("emit")
	return m


## The pilot's instrument screen: a lit display (the dash viewport) behind a glossy cover.
static func screen_material(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.02, 0.025, 0.03)
	m.roughness = 0.16
	m.metallic_specular = 0.35
	m.emission_enabled = true
	m.emission_texture = tex
	m.emission = Color(1, 1, 1)
	m.emission_energy_multiplier = 1.15
	return m


# ==================================================================================================
# Hull loft helpers
# ==================================================================================================

static func _key(i: int) -> Vector4:
	var k: Array = KEYS[i]
	return Vector4(float(k[1]), float(k[2]), float(k[3]), float(k[4]))


## Section at z: (centre y, half width, height above, depth below), smooth between the keys.
static func section(z: float) -> Vector4:
	var n := KEYS.size()
	if z <= float(KEYS[0][0]):
		return _key(0)
	if z >= float(KEYS[n - 1][0]):
		return _key(n - 1)
	var k := 0
	while k < n - 2 and z > float(KEYS[k + 1][0]):
		k += 1
	var z0: float = float(KEYS[k][0])
	var z1: float = float(KEYS[k + 1][0])
	var t := (z - z0) / (z1 - z0)
	return _key(k).cubic_interpolate(_key(k + 1), _key(maxi(k - 1, 0)), _key(mini(k + 2, n - 1)), t)


static func _sgp(v: float, e: float) -> float:
	return signf(v) * pow(absf(v), e)


## Point on the section at angle th (0 right, PI/2 top, PI left, 3PI/2 bottom), `inset` m inside.
static func sp(s: Vector4, th: float, z: float, inset := 0.0) -> Vector3:
	var e := 2.0 / N_EXP
	var sn := sin(th)
	var hh := (s.z if sn >= 0.0 else s.w) - inset
	return Vector3((s.y - inset) * _sgp(cos(th), e), s.x + hh * _sgp(sn, e), z)


## Outward surface normal at (z, th).
static func _hn(z: float, th: float, inset: float) -> Vector3:
	var d := 0.004
	var s := section(z)
	var a := sp(s, th + d, z, inset) - sp(s, th - d, z, inset)
	var b := sp(section(z + d), th, z + d, inset) - sp(section(z - d), th, z - d, inset)
	var n := a.cross(b)
	var p := sp(s, th, z, inset)
	var out := Vector3(p.x, p.y - s.x, 0.0)
	if n.dot(out) < 0.0:
		n = -n
	if n.length_squared() < 1e-12:
		return out.normalized() if out.length_squared() > 1e-8 else Vector3.FORWARD
	return n.normalized()


## Inner half width of the cabin tub at height y (z section s), for fitting floor / furniture.
static func tub_half_width(z: float, y: float) -> float:
	var s := section(z)
	var hh := (s.z if y >= s.x else s.w) - SKIN
	var k := clampf(absf(y - s.x) / maxf(hh, 0.01), 0.0, 1.0)
	return (s.y - SKIN) * pow(maxf(1.0 - pow(k, N_EXP), 0.0), 1.0 / N_EXP)


## Height of the hull top (outside) at z, x = 0.
static func top_y(z: float) -> float:
	var s := section(z)
	return s.x + s.z


static func _zrows(z0: float, z1: float) -> PackedFloat32Array:
	var marks: Array = [z0]
	for k in KEYS:
		var kz := float(k[0])
		if kz > z0 + 1e-4 and kz < z1 - 1e-4:
			marks.append(kz)
	marks.append(z1)
	var out := PackedFloat32Array()
	for i in marks.size() - 1:
		var a: float = marks[i]
		var b: float = marks[i + 1]
		var n := maxi(1, ceili((b - a) / 0.11))
		for j in n:
			out.append(lerpf(a, b, float(j) / float(n)))
	out.append(z1)
	return out


## Arc coordinate around the section from the bottom centre (m, roughly), for panel layout.
static func _arc_u(s: Vector4, th: float) -> float:
	var phi := wrapf(th - 1.5 * PI, -PI, PI)
	var hh := s.z if sin(th) >= 0.0 else s.w
	return phi * 0.5 * (s.y + hh)


## A band of the hull surface over z0..z1 and angles th0..th1. inset > 0: inside the skin;
## inward: normals face in (cabin side). uv_mode 1: UV.y = height above the sill / glass height.
static func _band(st: SurfaceTool, z0: float, z1: float, th0: float, th1: float, col: Color, pat: float,
		metal: float, inset := 0.0, inward := false, uv_mode := 0) -> void:
	var zs := _zrows(z0, z1)
	var m := maxi(2, ceili(absf(th1 - th0) / 0.07))
	var grid: Array = []
	for z in zs:
		var s := section(z)
		var row: Array = []
		for j in m + 1:
			var th := lerpf(th0, th1, float(j) / float(m))
			var p := sp(s, th, z, inset)
			var nrm := _hn(z, th, inset)
			if inward:
				nrm = -nrm
			var uv := Vector2(_arc_u(s, th), z)
			if uv_mode == 1:
				uv = Vector2(th, clampf((p.y - s.x) / maxf(s.z, 0.01), 0.0, 1.0))
			row.append([p, nrm, uv])
		grid.append(row)
	for i in zs.size() - 1:
		for j in m:
			_quad(st, grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1], col, pat, metal)


## Flat cap over the section at z for angles th0..th1, fanned from `center`, facing `normal`.
static func _cap(st: SurfaceTool, z: float, th0: float, th1: float, center: Vector3, normal: Vector3,
		col: Color, pat: float, metal: float, inset := 0.0) -> void:
	var s := section(z)
	var m := maxi(2, ceili(absf(th1 - th0) / 0.07))
	var c := [center, normal, Vector2(center.x, center.y)]
	var prev := sp(s, th0, z, inset)
	for j in range(1, m + 1):
		var p := sp(s, lerpf(th0, th1, float(j) / float(m)), z, inset)
		_tri(st, c, [prev, normal, Vector2(prev.x, prev.y)], [p, normal, Vector2(p.x, p.y)], col, pat, metal)
		prev = p


# ==================================================================================================
# Primitive helpers (vertices are [position, normal, uv])
# ==================================================================================================

static func _emit(st: SurfaceTool, v: Array, col: Color, pat: float, metal: float) -> void:
	st.set_color(col)
	st.set_normal(v[1])
	st.set_uv(v[2])
	st.set_uv2(Vector2(pat, metal))
	st.add_vertex(v[0])


## Triangle facing the side its vertex normals point to (Godot front faces wind clockwise).
static func _tri(st: SurfaceTool, a: Array, b: Array, c: Array, col: Color, pat: float, metal: float) -> void:
	var pa: Vector3 = a[0]
	var pb: Vector3 = b[0]
	var pc: Vector3 = c[0]
	var n: Vector3 = (a[1] as Vector3) + (b[1] as Vector3) + (c[1] as Vector3)
	if (pb - pa).cross(pc - pa).dot(n) > 0.0:
		_emit(st, a, col, pat, metal)
		_emit(st, c, col, pat, metal)
		_emit(st, b, col, pat, metal)
	else:
		_emit(st, a, col, pat, metal)
		_emit(st, b, col, pat, metal)
		_emit(st, c, col, pat, metal)


static func _quad(st: SurfaceTool, a: Array, b: Array, c: Array, d: Array, col: Color, pat: float, metal: float) -> void:
	_tri(st, a, b, c, col, pat, metal)
	_tri(st, a, c, d, col, pat, metal)


static func _basis_y(y: Vector3) -> Basis:
	var yy := y.normalized()
	var ref := Vector3.FORWARD if absf(yy.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(yy).normalized()
	var z := x.cross(yy).normalized()
	return Basis(x, yy, z)


## Rounded box (superellipsoid: flat faces, rounded edges), half size h, placed by xf (rotation
## and translation only).
static func _rbox(st: SurfaceTool, xf: Transform3D, h: Vector3, col: Color, pat: float, metal: float,
		ex := 7.0, seg := 8) -> void:
	var rows := seg
	var cols := seg * 2
	var e := 2.0 / ex
	var grid: Array = []
	for i in rows + 1:
		var v := -PI * 0.5 + PI * float(i) / float(rows)
		var row: Array = []
		for j in cols + 1:
			var u := -PI + TAU * float(j) / float(cols)
			var d := Vector3(cos(v) * cos(u), sin(v), cos(v) * sin(u))
			var p := Vector3(h.x * _sgp(d.x, e), h.y * _sgp(d.y, e), h.z * _sgp(d.z, e))
			var n := Vector3(_sgp(p.x / h.x, ex - 1.0) / h.x, _sgp(p.y / h.y, ex - 1.0) / h.y,
					_sgp(p.z / h.z, ex - 1.0) / h.z)
			if n.length_squared() < 1e-12:
				n = d
			n = n.normalized()
			var an := n.abs()
			var uv := Vector2(p.x, p.y)
			if an.x >= an.y and an.x >= an.z:
				uv = Vector2(p.z, p.y)
			elif an.y >= an.z:
				uv = Vector2(p.x, p.z)
			row.append([xf * p, (xf.basis * n).normalized(), uv + Vector2(xf.origin.x + xf.origin.z, xf.origin.y)])
		grid.append(row)
	for i in rows:
		for j in cols:
			_quad(st, grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1], col, pat, metal)


## Cylinder / cone from a (radius ra) to b (radius rb), with flat end caps.
static func _cyl(st: SurfaceTool, a: Vector3, b: Vector3, ra: float, rb: float, col: Color, pat: float,
		metal: float, sides := 12, cap_a := true, cap_b := true) -> void:
	var ax := b - a
	var ln := ax.length()
	if ln < 1e-5:
		return
	var bs := _basis_y(ax / ln)
	var ra_pts: Array = []
	var rb_pts: Array = []
	for k in sides + 1:
		var ang := TAU * float(k) / float(sides)
		var dir := bs.x * cos(ang) + bs.z * sin(ang)
		var n := (dir * ln + bs.y * (ra - rb)).normalized()
		var u := ang * 0.5 * (ra + rb)
		ra_pts.append([a + dir * ra, n, Vector2(u, 0.0)])
		rb_pts.append([b + dir * rb, n, Vector2(u, ln)])
	for k in sides:
		_quad(st, ra_pts[k], rb_pts[k], rb_pts[k + 1], ra_pts[k + 1], col, pat, metal)
	if cap_a and ra > 0.0005:
		var c := [a, -bs.y, Vector2.ZERO]
		for k in sides:
			_tri(st, c, [ra_pts[k][0], -bs.y, Vector2.ZERO], [ra_pts[k + 1][0], -bs.y, Vector2.ZERO], col, pat, metal)
	if cap_b and rb > 0.0005:
		var c2 := [b, bs.y, Vector2.ZERO]
		for k in sides:
			_tri(st, c2, [rb_pts[k][0], bs.y, Vector2.ZERO], [rb_pts[k + 1][0], bs.y, Vector2.ZERO], col, pat, metal)


## Surface of revolution about the local Y axis of xf. prof: Vector2(radius, y) points; the normals
## point away from the axis for a profile running up (flip for one running down). UV.y runs 0..1
## along the profile (the nozzle pattern uses it).
static func _lathe(st: SurfaceTool, xf: Transform3D, prof: Array, col: Color, pat: float, metal: float,
		sides := 16, flip := false) -> void:
	var np := prof.size()
	var ring: Array = []
	for i in np:
		var p: Vector2 = prof[i]
		var t: Vector2 = (prof[mini(i + 1, np - 1)] as Vector2) - (prof[maxi(i - 1, 0)] as Vector2)
		var n2 := Vector2(t.y, -t.x).normalized()
		if flip:
			n2 = -n2
		var r_row: Array = []
		for k in sides + 1:
			var ang := TAU * float(k) / float(sides)
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			var pos := dir * p.x + Vector3(0.0, p.y, 0.0)
			var nrm := dir * n2.x + Vector3(0.0, n2.y, 0.0)
			r_row.append([xf * pos, (xf.basis * nrm).normalized(), Vector2(ang * maxf(p.x, 0.02), float(i) / float(np - 1))])
		ring.append(r_row)
	for i in np - 1:
		for k in sides:
			_quad(st, ring[i][k], ring[i + 1][k], ring[i + 1][k + 1], ring[i][k + 1], col, pat, metal)


## Tube of radius r along a polyline (parallel-transported frames), open ends.
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
			_quad(st, rings[i][k], rings[i + 1][k], rings[i + 1][k + 1], rings[i][k + 1], col, pat, metal)


## Six-faced solid from 8 corners (bottom 0-3, top 4-7 in the same order), flat shaded.
static func _hexa(st: SurfaceTool, c: Array, col: Color, pat: float, metal: float) -> void:
	var ctr := Vector3.ZERO
	for p in c:
		ctr += p as Vector3
	ctr /= 8.0
	var faces := [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
	for f: Array in faces:
		var a: Vector3 = c[f[0]]
		var b: Vector3 = c[f[1]]
		var cc: Vector3 = c[f[2]]
		var d: Vector3 = c[f[3]]
		var n := (cc - a).cross(d - b).normalized()
		var fc := (a + b + cc + d) * 0.25
		if n.dot(fc - ctr) < 0.0:
			n = -n
		var an := n.abs()
		var pick := func(p: Vector3) -> Vector2:
			if an.x >= an.y and an.x >= an.z:
				return Vector2(p.z, p.y)
			if an.y >= an.z:
				return Vector2(p.x, p.z)
			return Vector2(p.x, p.y)
		_quad(st, [a, n, pick.call(a)], [b, n, pick.call(b)], [cc, n, pick.call(cc)], [d, n, pick.call(d)], col, pat, metal)


static func _xf(pos: Vector3, rot := Vector3.ZERO) -> Transform3D:
	return Transform3D(Basis.from_euler(rot), pos)


static func _commit(st: SurfaceTool) -> ArrayMesh:
	st.index()
	return st.commit()


static func _new_st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


# ==================================================================================================
# Exterior
# ==================================================================================================

static func _build_hull() -> ArrayMesh:
	var st := _new_st()
	var B := 1.5 * PI
	# Lower half (whole length): graphite heat-tile belly, white sides, an orange pinstripe.
	_band(st, Z_NOSE, Z_TAIL, B - 0.62, B + 0.62, C_GRAPHITE, P_TILES, 0.0)
	_band(st, Z_NOSE, Z_TAIL, PI + 0.2, B - 0.62, _paint, 0.52, 0.0)
	_band(st, Z_NOSE, Z_TAIL, B + 0.62, TAU - 0.2, _paint, 0.52, 0.0)
	_band(st, Z_NOSE, Z_TAIL, PI + 0.1, PI + 0.2, _stripe, _stripe_pat, 0.0)
	_band(st, Z_NOSE, Z_TAIL, TAU - 0.2, TAU - 0.1, _stripe, _stripe_pat, 0.0)
	_band(st, Z_NOSE, Z_TAIL, PI, PI + 0.1, _paint, 0.52, 0.0)
	_band(st, Z_NOSE, Z_TAIL, TAU - 0.1, TAU, _paint, 0.52, 0.0)
	# Upper half of the nose: matte anti-glare panel ahead of the windscreen, white flanks.
	_band(st, Z_NOSE, ZC0, 0.0, 0.5, _paint, 0.4, 0.0)
	_band(st, Z_NOSE, ZC0, 0.5, PI - 0.5, C_MATTE, 0.3, 0.0)
	_band(st, Z_NOSE, ZC0, PI - 0.5, PI, _paint, 0.4, 0.0)
	# Upper half of the tail: white, a graphite spine.
	_band(st, ZC1, Z_TAIL, 0.0, PI * 0.5 - 0.12, _paint, 0.52, 0.0)
	_band(st, ZC1, Z_TAIL, PI * 0.5 - 0.12, PI * 0.5 + 0.12, C_GRAPHITE, 0.3, 0.1)
	_band(st, ZC1, Z_TAIL, PI * 0.5 + 0.12, PI, _paint, 0.52, 0.0)
	# Nose tip and the engine bay face at the tail.
	var sn := section(Z_NOSE)
	_cap(st, Z_NOSE, 0.0, TAU, Vector3(0.0, sn.x, Z_NOSE - 0.025), Vector3.FORWARD, C_MATTE, P_PLAIN, 0.0)
	var stl := section(Z_TAIL)
	_cap(st, Z_TAIL, 0.0, TAU, Vector3(0.0, stl.x, Z_TAIL), Vector3.BACK, C_GRAPHITE, P_VENT, 0.15)
	_canopy_frame(st)
	_nacelles(st)
	_engines(st)
	_details(st)
	return _commit(st)


## Canopy frame: sill rails, front / middle / rear arches hugging the glass.
static func _canopy_frame(st: SurfaceTool) -> void:
	for th: float in [0.0, PI]:
		var pts: Array = []
		for z in _zrows(ZC0, ZC1):
			pts.append(sp(section(z), th, z, SKIN * 0.5))
		_tube(st, pts, 0.03, C_STEEL, P_PLAIN, 0.25, 8)
	for arch: Array in [[ZC0 + 0.012, 0.034], [-1.0, 0.02], [ZC1 - 0.012, 0.03]]:
		var z: float = arch[0]
		var s := section(z)
		var pts2: Array = []
		for j in 25:
			pts2.append(sp(s, PI * float(j) / 24.0, z, -0.008))
		_tube(st, pts2, float(arch[1]), C_STEEL, P_PLAIN, 0.25, 8)


static func _nacelles(st: SurfaceTool) -> void:
	var rot := Basis(Vector3.RIGHT, PI * 0.5)        # lathe Y -> ship Z
	for sx: float in [-1.0, 1.0]:
		var xf := Transform3D(rot, Vector3(sx * NAC_X, NAC_Y, 0.0))
		# Rounded nose, an orange band, the long white body, a graphite tail cone.
		_lathe(st, xf, [Vector2(0.0, -1.52), Vector2(0.07, -1.505), Vector2(0.13, -1.46), Vector2(0.175, -1.38),
				Vector2(0.2, -1.27), Vector2(0.21, -1.17)], _paint, P_PLAIN, 0.0, 18)
		_lathe(st, xf, [Vector2(0.21, -1.17), Vector2(0.21, -1.02)], _stripe, _stripe_pat, 0.0, 18)
		_lathe(st, xf, [Vector2(0.21, -1.02), Vector2(0.21, -0.2), Vector2(0.21, 0.6), Vector2(0.21, 1.25)],
				_paint, 0.45, 0.0, 18)
		_lathe(st, xf, [Vector2(0.21, 1.25), Vector2(0.205, 1.42), Vector2(0.185, 1.56), Vector2(0.15, 1.66),
				Vector2(0.08, 1.71), Vector2(0.0, 1.72)], C_GRAPHITE, P_PLAIN, 0.1, 18)
		# Pylon into the hull side.
		var xi := sx * 0.6
		var xo := sx * 0.88
		_hexa(st, [Vector3(xi, 0.56, -0.95), Vector3(xo, 0.58, -0.82), Vector3(xo, 0.58, 1.12), Vector3(xi, 0.56, 1.25),
				Vector3(xi, 0.84, -0.95), Vector3(xo, 0.70, -0.82), Vector3(xo, 0.70, 1.12), Vector3(xi, 0.84, 1.25)],
				C_GRAPHITE, 0.35, 0.1)
		# Hazard stripes round the lift jets, a boarding step on the pilot's side.
		for vz: float in [-0.72, 0.95]:
			_lathe(st, Transform3D(Basis(), Vector3(sx * NAC_X, NAC_Y - NAC_R - 0.004, vz)),
					[Vector2(0.19, 0.0), Vector2(0.155, 0.0)], C_YELLOW, P_HAZARD, 0.0, 20, true)
		if sx < 0.0:
			_rbox(st, _xf(Vector3(-1.12, 0.62, -0.28)), Vector3(0.1, 0.018, 0.16), C_STEEL, P_TREAD, 0.25)
			_rbox(st, _xf(Vector3(-1.02, 0.62, -0.42)), Vector3(0.02, 0.03, 0.02), C_STEEL, P_PLAIN, 0.25)
			_rbox(st, _xf(Vector3(-1.02, 0.62, -0.14)), Vector3(0.02, 0.03, 0.02), C_STEEL, P_PLAIN, 0.25)
	# Leg struts (the moving pistons and pads are separate: _build_foot).
	for f: Vector3 in FEET:
		var top := Vector3(f.x, NAC_Y - 0.12, f.z)
		_cyl(st, top, Vector3(f.x, STRUT_BOTTOM, f.z), 0.05, 0.046, C_STEEL, P_PLAIN, 0.3, 12)
		_cyl(st, Vector3(f.x, STRUT_BOTTOM + 0.05, f.z), Vector3(f.x, STRUT_BOTTOM, f.z), 0.06, 0.06, C_GRAPHITE, P_PLAIN, 0.2, 12)
		_rbox(st, _xf(Vector3(f.x, NAC_Y - NAC_R + 0.02, f.z)), Vector3(0.075, 0.05, 0.1), C_GRAPHITE, P_PLAIN, 0.2)
		# Drag brace back to the nacelle.
		var dz := signf(-f.z) * 0.22
		_cyl(st, Vector3(f.x, STRUT_BOTTOM + 0.1, f.z), Vector3(f.x, NAC_Y - NAC_R + 0.03, f.z + dz), 0.016, 0.016,
				C_METAL, P_PLAIN, 0.3, 6)


static func _engines(st: SurfaceTool) -> void:
	# Lift jets: a short metal bell under each nacelle, the hot liner inside.
	for p: Vector3 in VTOL:
		var xf := Transform3D(Basis(), p)
		_lathe(st, xf, [Vector2(0.14, 0.07), Vector2(0.15, 0.02), Vector2(0.155, -0.005)], C_STEEL, P_PLAIN, 0.3, 18, true)
		_lathe(st, xf, [Vector2(0.155, -0.005), Vector2(0.13, -0.004)], C_GRAPHITE, P_PLAIN, 0.2, 18, true)
		_lathe(st, xf, [Vector2(0.075, 0.08), Vector2(0.1, 0.04), Vector2(0.13, -0.004)], C_METAL, P_NOZZLE, 0.2, 18)
	# Main engine: collar, bell, liner.
	var rot := Basis(Vector3.RIGHT, PI * 0.5)
	var mx := Transform3D(rot, Vector3(0.0, MAIN_Y, 0.0))
	_lathe(st, mx, [Vector2(0.27, Z_TAIL - 0.01), Vector2(0.27, Z_TAIL + 0.07)], C_GRAPHITE, P_PLAIN, 0.2, 24)
	_lathe(st, mx, [Vector2(0.235, Z_TAIL + 0.07), Vector2(0.25, Z_TAIL + 0.18), Vector2(0.275, Z_TAIL + 0.27),
			Vector2(0.3, Z_TAIL + 0.3)], C_STEEL, P_BRUSHED, 0.3, 24)
	_lathe(st, mx, [Vector2(0.3, Z_TAIL + 0.3), Vector2(0.28, Z_TAIL + 0.3)], C_GRAPHITE, P_PLAIN, 0.2, 24)
	_lathe(st, mx, [Vector2(0.12, Z_TAIL + 0.03), Vector2(0.17, Z_TAIL + 0.12), Vector2(0.23, Z_TAIL + 0.22),
			Vector2(0.28, Z_TAIL + 0.3)], C_METAL, P_NOZZLE, 0.2, 24, true)


static func _details(st: SurfaceTool) -> void:
	# RCS quads: nose and tail sides, two tiny nozzles each.
	for z: float in [-2.0, 2.02]:
		var s := section(z)
		for sx: float in [-1.0, 1.0]:
			var p := Vector3(sx * (s.y - 0.015), s.x + 0.06, z)
			_rbox(st, _xf(p), Vector3(0.04, 0.035, 0.05), C_GRAPHITE, P_PLAIN, 0.2)
			_cyl(st, p + Vector3(sx * 0.03, 0.0, 0.0), p + Vector3(sx * 0.06, 0.0, 0.0), 0.012, 0.016, C_METAL, P_NOZZLE, 0.2, 8, false, true)
			_cyl(st, p + Vector3(0.0, 0.025, 0.0), p + Vector3(0.0, 0.055, 0.0), 0.012, 0.016, C_METAL, P_NOZZLE, 0.2, 8, false, true)
	# Dorsal fin (graphite, the strobe on its tip) and an antenna mast.
	var tb0 := top_y(0.95) - 0.03
	var tb1 := top_y(2.18) - 0.03
	var tt0 := top_y(1.8) + 0.38
	var tt1 := top_y(2.22) + 0.36
	_hexa(st, [Vector3(-0.035, tb0, 0.95), Vector3(0.035, tb0, 0.95), Vector3(0.035, tb1, 2.18), Vector3(-0.035, tb1, 2.18),
			Vector3(-0.018, tt0, 1.8), Vector3(0.018, tt0, 1.8), Vector3(0.018, tt1, 2.22), Vector3(-0.018, tt1, 2.22)],
			C_GRAPHITE, 0.28, 0.1)
	_rbox(st, _xf(Vector3(0.0, STROBE.y - 0.03, STROBE.z)), Vector3(0.022, 0.02, 0.05), C_STEEL, P_PLAIN, 0.2)
	var ay := top_y(0.7)
	_cyl(st, Vector3(0.24, ay - 0.05, 0.7), Vector3(0.24, ay + 0.3, 0.72), 0.009, 0.006, C_STEEL, P_PLAIN, 0.3, 6)
	_lathe(st, _xf(Vector3(0.24, ay + 0.3, 0.72)), [Vector2(0.0, -0.016), Vector2(0.014, -0.008), Vector2(0.016, 0.0),
			Vector2(0.014, 0.008), Vector2(0.0, 0.016)], _stripe, P_PLAIN, 0.0, 8)
	# Landing-light housing under the nose, a grab handle under the pilot's sill.
	_rbox(st, _xf(LAND_LIGHT + Vector3(0.0, 0.035, 0.0)), Vector3(0.09, 0.035, 0.07), C_GRAPHITE, P_PLAIN, 0.2)
	var hs := section(-0.6)
	var hy := hs.x - 0.2
	var hx := -(tub_half_width(-0.6, hy) + SKIN) - 0.005
	_tube(st, [Vector3(hx, hy, -0.85), Vector3(hx - 0.05, hy, -0.8), Vector3(hx - 0.05, hy, -0.4), Vector3(hx, hy, -0.35)],
			0.014, C_STEEL, P_PLAIN, 0.3, 6)
	# Vent grilles on the tail flanks (engine bay intakes).
	for sx: float in [-1.0, 1.0]:
		var z := 1.6
		var s2 := section(z)
		var p2 := sp(s2, PI * 0.5 - sx * PI * 0.5 + sx * 0.25, z, -0.004)
		var n2 := _hn(z, PI * 0.5 - sx * PI * 0.5 + sx * 0.25, 0.0)
		var b2 := Basis.looking_at(-n2, Vector3.UP)
		_rbox(st, Transform3D(b2, p2), Vector3(0.11, 0.05, 0.008), C_GRAPHITE, P_VENT, 0.1, 6.0, 6)


## Footpad + oleo piston, origin at the ground contact point (moved by the leg animation).
static func _build_foot() -> ArrayMesh:
	var st := _new_st()
	_cyl(st, Vector3(0.0, 0.06, 0.0), Vector3(0.0, 0.38, 0.0), 0.032, 0.032, C_CHROME, P_BRUSHED, 0.35, 12, false, true)
	_lathe(st, Transform3D(), [Vector2(0.0, 0.0), Vector2(0.15, 0.0), Vector2(0.165, 0.012)], C_RUBBER, P_RUBBER, 0.0, 20)
	_lathe(st, Transform3D(), [Vector2(0.165, 0.012), Vector2(0.165, 0.036), Vector2(0.14, 0.052)], C_RUBBER, P_RUBBER, 0.0, 20)
	_lathe(st, Transform3D(), [Vector2(0.14, 0.052), Vector2(0.06, 0.06), Vector2(0.0, 0.062)], C_STEEL, P_PLAIN, 0.3, 20)
	_lathe(st, Transform3D(), [Vector2(0.0, 0.03), Vector2(0.035, 0.045), Vector2(0.045, 0.075), Vector2(0.035, 0.1),
			Vector2(0.0, 0.11)], C_GRAPHITE, P_PLAIN, 0.2, 12)
	return _commit(st)


# ==================================================================================================
# Glass
# ==================================================================================================

static func _build_glass() -> ArrayMesh:
	var st := _new_st()
	_band(st, ZC0, ZC1, 0.0, PI, Color(1, 1, 1, 0.05), 0.0, 0.0, -0.004, false, 1)
	return _commit(st)


# ==================================================================================================
# Cabin
# ==================================================================================================

static func _build_cabin() -> ArrayMesh:
	var st := _new_st()
	var B := 1.5 * PI
	# Tub: the inner skin of the lower half, bulkheads, the floor.
	_band(st, ZC0, ZC1, PI, TAU, C_CABIN, 0.32, 0.0, SKIN, true)
	var s0 := section(ZC0)
	_cap(st, ZC0, PI, TAU, Vector3(0.0, s0.x, ZC0), Vector3.BACK, C_CABIN_DK, 0.3, 0.0, SKIN)
	# (the strip where the windscreen meets the low nose, above the dash)
	_cap(st, ZC0, 0.0, PI, Vector3(0.0, s0.x, ZC0), Vector3.BACK, C_MATTE, P_PLAIN, 0.0, 0.0)
	var s1 := section(ZC1)
	_cap(st, ZC1, PI, TAU, Vector3(0.0, s1.x + 0.1, ZC1), Vector3.FORWARD, C_CABIN, 0.34, 0.0, SKIN)
	_cap(st, ZC1, 0.0, PI, Vector3(0.0, s1.x + 0.1, ZC1), Vector3.FORWARD, C_CABIN, 0.34, 0.0, 0.0)
	var zs := _zrows(ZC0, ZC1)
	for i in zs.size() - 1:
		var za: float = zs[i]
		var zb: float = zs[i + 1]
		var wa := tub_half_width(za, FLOOR_Y) - 0.005
		var wb := tub_half_width(zb, FLOOR_Y) - 0.005
		_quad(st, [Vector3(-wa, FLOOR_Y, za), Vector3.UP, Vector2(-wa, za)], [Vector3(wa, FLOOR_Y, za), Vector3.UP, Vector2(wa, za)],
				[Vector3(wb, FLOOR_Y, zb), Vector3.UP, Vector2(wb, zb)], [Vector3(-wb, FLOOR_Y, zb), Vector3.UP, Vector2(-wb, zb)],
				C_CABIN_DK, P_TREAD, 0.2)
	_dash(st)
	for sx: float in [-1.0, 1.0]:
		_seat(st, sx * SEAT_X, sx < 0.0)
	# Centre console between the seats.
	_rbox(st, _xf(Vector3(0.0, 0.7, -0.55)), Vector3(0.11, 0.1, 0.42), C_CABIN_DK, P_PLAIN, 0.0)
	_rbox(st, _xf(Vector3(0.0, 0.805, -0.62)), Vector3(0.085, 0.01, 0.26), C_GRAPHITE, P_PLAIN, 0.1)
	for i in 4:
		_cyl(st, Vector3(0.04, 0.815, -0.78 + i * 0.05), Vector3(0.04, 0.84, -0.78 + i * 0.05 - 0.008), 0.004, 0.004,
				C_METAL, P_PLAIN, 0.3, 6)
	# Side switch panel by the pilot's left hand.
	var px := -tub_half_width(-0.6, 1.0) + 0.02
	_rbox(st, Transform3D(Basis(Vector3.FORWARD, -0.12), Vector3(px, 1.0, -0.62)), Vector3(0.018, 0.06, 0.2), C_CABIN_DK, P_PLAIN, 0.0)
	# Rudder pedals in the footwell.
	for x: float in [-0.5, -0.26]:
		_rbox(st, Transform3D(Basis(Vector3.RIGHT, -0.9), Vector3(x, 0.7, -1.42)), Vector3(0.05, 0.08, 0.012), C_STEEL, P_TREAD, 0.25)
		_cyl(st, Vector3(x, 0.62, -1.36), Vector3(x, 0.66, -1.4), 0.012, 0.012, C_METAL, P_PLAIN, 0.3, 6)
	# Rear bulkhead: padded panels behind the seats, a locker, the fire extinguisher.
	for sx: float in [-1.0, 1.0]:
		_rbox(st, _xf(Vector3(sx * 0.42, 1.25, ZC1 - 0.03)), Vector3(0.26, 0.3, 0.025), C_SEAT, P_QUILT, 0.0)
	_rbox(st, _xf(Vector3(0.0, 0.8, ZC1 - 0.07)), Vector3(0.12, 0.17, 0.06), C_CABIN_DK, P_VENT, 0.0)
	_cyl(st, Vector3(0.0, 1.0, ZC1 - 0.09), Vector3(0.0, 1.3, ZC1 - 0.09), 0.05, 0.05, C_RED, P_PLAIN, 0.0, 14)
	_cyl(st, Vector3(0.0, 1.3, ZC1 - 0.09), Vector3(0.0, 1.35, ZC1 - 0.09), 0.05, 0.02, C_GRAPHITE, P_PLAIN, 0.2, 14)
	_rbox(st, _xf(Vector3(0.0, 1.12, ZC1 - 0.04)), Vector3(0.06, 0.012, 0.02), C_STEEL, P_PLAIN, 0.3)
	# Dome light housing under the rear arch.
	_rbox(st, _xf(Vector3(0.0, top_y(ZC1) - 0.03, ZC1 - 0.05)), Vector3(0.09, 0.015, 0.04), C_CABIN_DK, P_PLAIN, 0.0)
	return _commit(st)


## Basis of the dash's instrument face (z = its normal, y up along the face).
static func dash_basis() -> Basis:
	var z := DASH_N.normalized()
	var y := Vector3(0.0, 0.29, -0.12).normalized()
	return Basis(y.cross(z).normalized(), y, z)


static func _dash(st: SurfaceTool) -> void:
	# Body: under the windscreen from the front bulkhead back to the instrument face.
	_hexa(st, [Vector3(-0.7, 0.86, ZC0), Vector3(0.7, 0.86, ZC0), Vector3(0.84, 0.86, -1.0), Vector3(-0.84, 0.86, -1.0),
			Vector3(-0.7, 1.13, ZC0), Vector3(0.7, 1.13, ZC0), Vector3(0.84, 1.15, -1.12), Vector3(-0.84, 1.15, -1.12)],
			C_CABIN_DK, P_PLAIN, 0.0)
	var fb := dash_basis()
	var face := Vector3(0.0, DASH_FACE.y, DASH_FACE.z)
	# Pilot screen bezel, glare shield over it; passenger display, centre switch panel.
	_rbox(st, Transform3D(fb, face + Vector3(-SEAT_X, 0.0, 0.0) + fb.z * 0.006), Vector3(0.2, 0.105, 0.012), C_GRAPHITE, P_PLAIN, 0.1)
	_rbox(st, Transform3D(Basis(Vector3.RIGHT, -0.1), Vector3(-SEAT_X, 1.165, -1.1)), Vector3(0.24, 0.012, 0.075), C_MATTE, P_PLAIN, 0.0)
	_rbox(st, Transform3D(fb, face + Vector3(SEAT_X, 0.01, 0.0) + fb.z * 0.006), Vector3(0.15, 0.08, 0.012), C_GRAPHITE, P_PLAIN, 0.1)
	_rbox(st, Transform3D(fb, face + fb.z * 0.008), Vector3(0.075, 0.1, 0.012), C_GRAPHITE, P_PLAIN, 0.1)
	for i in 3:
		for j in 2:
			var p := face + fb.x * (-0.035 + j * 0.07) + fb.y * (0.05 - i * 0.045) + fb.z * 0.022
			_cyl(st, p, p + fb.z * 0.022 + fb.y * 0.006, 0.0045, 0.004, C_METAL, P_PLAIN, 0.3, 6)
	# Small round gauge on the passenger side (a backup altimeter).
	var g := face + Vector3(SEAT_X + 0.2, 0.0, 0.0) + fb.z * 0.008
	_cyl(st, g, g + fb.z * 0.015, 0.045, 0.045, C_GRAPHITE, P_PLAIN, 0.1, 16)


static func _seat(st: SurfaceTool, sx: float, pilot: bool) -> void:
	# Frame and rails.
	_rbox(st, _xf(Vector3(sx, 0.68, -0.36)), Vector3(0.19, 0.075, 0.2), C_STEEL, P_PLAIN, 0.25)
	for rx: float in [-0.13, 0.13]:
		_rbox(st, _xf(Vector3(sx + rx, FLOOR_Y + 0.012, -0.36)), Vector3(0.018, 0.012, 0.3), C_METAL, P_PLAIN, 0.3)
	# Pan, bolsters, back, headrest (back tilted 14 degrees).
	_rbox(st, _xf(Vector3(sx, 0.79, -0.38)), Vector3(0.21, 0.05, 0.25), C_SEAT, P_QUILT, 0.0)
	for bx: float in [-0.215, 0.215]:
		_rbox(st, _xf(Vector3(sx + bx, 0.825, -0.38)), Vector3(0.035, 0.055, 0.24), C_LEATHER, P_PLAIN, 0.0)
	# (+X rotation tips the top back, toward +Z: a reclined back behind the pilot)
	var tilt := Basis(Vector3.RIGHT, 0.244)
	var up := tilt * Vector3.UP
	var base := Vector3(sx, 0.82, -0.1)
	_rbox(st, Transform3D(tilt, base + up * 0.31), Vector3(0.21, 0.31, 0.055), C_SEAT, P_QUILT, 0.0)
	for bx: float in [-0.215, 0.215]:
		_rbox(st, Transform3D(tilt, base + up * 0.28 + Vector3(bx, 0.0, -0.02)), Vector3(0.04, 0.27, 0.07), C_LEATHER, P_PLAIN, 0.0)
	_rbox(st, Transform3D(tilt, base + up * 0.31 + tilt * Vector3(0.0, 0.0, 0.07)), Vector3(0.22, 0.3, 0.02), C_STEEL, P_PLAIN, 0.2)
	_rbox(st, Transform3D(tilt, base + up * 0.7 + tilt * Vector3(0.0, 0.0, 0.02)), Vector3(0.13, 0.085, 0.05), C_SEAT, P_QUILT, 0.0)
	_cyl(st, base + up * 0.6 + Vector3(-0.06, 0.0, 0.0), base + up * 0.66 + Vector3(-0.06, 0.0, 0.0), 0.009, 0.009, C_METAL, P_PLAIN, 0.3, 6)
	_cyl(st, base + up * 0.6 + Vector3(0.06, 0.0, 0.0), base + up * 0.66 + Vector3(0.06, 0.0, 0.0), 0.009, 0.009, C_METAL, P_PLAIN, 0.3, 6)
	# Harness: two shoulder straps, a lap belt, the buckle.
	var fwd := tilt * Vector3.FORWARD
	for hx: float in [-0.09, 0.09]:
		_tube(st, [base + up * 0.55 + Vector3(hx, 0.0, 0.0) + fwd * 0.07, base + up * 0.35 + Vector3(hx * 0.6, 0.0, 0.0) + fwd * 0.07,
				Vector3(sx + hx * 0.3, 0.86, -0.36)], 0.012, C_STRAP, P_PLAIN, 0.0, 4)
	_tube(st, [Vector3(sx - 0.2, 0.84, -0.18), Vector3(sx, 0.86, -0.36), Vector3(sx + 0.2, 0.84, -0.18)], 0.013, C_STRAP, P_PLAIN, 0.0, 4)
	_rbox(st, _xf(Vector3(sx, 0.87, -0.36)), Vector3(0.035, 0.012, 0.03), C_METAL, P_PLAIN, 0.35)
	if pilot:
		# Stick base boot on the floor in front of the seat.
		_cyl(st, Vector3(sx, FLOOR_Y, STICK_POS.z), Vector3(sx, FLOOR_Y + 0.02, STICK_POS.z), 0.07, 0.07, C_GRAPHITE, P_PLAIN, 0.2, 14)


## Control stick (pivot at its base, local frame).
static func _build_stick() -> ArrayMesh:
	var st := _new_st()
	_cyl(st, Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.06, 0.0), 0.05, 0.022, C_RUBBER, P_RUBBER, 0.0, 12)
	_cyl(st, Vector3(0.0, 0.05, 0.0), Vector3(0.0, 0.3, 0.0), 0.012, 0.012, C_STEEL, P_PLAIN, 0.3, 8)
	_rbox(st, Transform3D(Basis(Vector3.RIGHT, 0.25), Vector3(0.0, 0.34, 0.01)), Vector3(0.022, 0.055, 0.026), C_GRAPHITE, P_RUBBER, 0.0)
	_rbox(st, _xf(Vector3(0.0, 0.39, 0.0)), Vector3(0.016, 0.01, 0.016), C_RED, P_PLAIN, 0.0)
	return _commit(st)


## Throttle lever on the console (pivot at its base, local frame).
static func _build_throttle() -> ArrayMesh:
	var st := _new_st()
	_rbox(st, _xf(Vector3(0.0, 0.0, 0.0)), Vector3(0.022, 0.012, 0.04), C_GRAPHITE, P_PLAIN, 0.1)
	_cyl(st, Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.1, -0.015), 0.008, 0.008, C_STEEL, P_PLAIN, 0.3, 6)
	_rbox(st, _xf(Vector3(0.0, 0.115, -0.02)), Vector3(0.024, 0.02, 0.03), C_ORANGE, P_PLAIN, 0.0)
	return _commit(st)


# ==================================================================================================
# Emissive bits (EMIT shader: COLOR = colour + intensity, UV2 = mode, phase)
# ==================================================================================================

static func _led(st: SurfaceTool, xf: Transform3D, h: Vector3, col: Color, mode: float, phase := 0.0) -> void:
	_rbox(st, xf, h, col, mode, phase, 5.0, 4)


static func _disc(st: SurfaceTool, c: Vector3, n: Vector3, r: float, col: Color, mode: float) -> void:
	var b := _basis_y(n)
	var center := [c, n, Vector2.ZERO]
	for k in 16:
		var a0 := TAU * float(k) / 16.0
		var a1 := TAU * float(k + 1) / 16.0
		var p0 := c + (b.x * cos(a0) + b.z * sin(a0)) * r
		var p1 := c + (b.x * cos(a1) + b.z * sin(a1)) * r
		_tri(st, center, [p0, n, Vector2.ZERO], [p1, n, Vector2.ZERO], col, mode, 0.0)


static func _build_leds() -> ArrayMesh:
	var st := _new_st()
	var fb := dash_basis()
	var face := Vector3(0.0, DASH_FACE.y, DASH_FACE.z)
	# Status LEDs under the pilot screen (green / cyan / amber), steady and pulsing.
	var cols := [Color(0.4, 0.95, 0.55, 1.0), Color(0.4, 0.86, 1.0, 1.0), Color(1.0, 0.72, 0.3, 1.0), Color(0.4, 0.95, 0.55, 1.0)]
	for i in 4:
		var p := face + Vector3(-SEAT_X - 0.12 + i * 0.08, 0.0, 0.0) + fb.y * -0.085 + fb.z * 0.02
		_led(st, Transform3D(fb, p), Vector3(0.012, 0.004, 0.003), cols[i], 0.0 if i != 1 else 1.0, i * 0.23)
	# Passenger display: a bar graph and a status row.
	for i in 8:
		var p2 := face + Vector3(SEAT_X - 0.11 + i * 0.03, 0.02, 0.0) + fb.y * (0.02 + 0.006 * float(i % 3)) + fb.z * 0.02
		_led(st, Transform3D(fb, p2), Vector3(0.009, 0.03 + 0.012 * float(i % 3), 0.002), Color(0.35, 0.8, 1.0, 0.7), 1.0, i * 0.11)
	for i in 3:
		var p3 := face + Vector3(SEAT_X - 0.08 + i * 0.08, 0.0, 0.0) + fb.y * -0.05 + fb.z * 0.02
		_led(st, Transform3D(fb, p3), Vector3(0.01, 0.004, 0.003), Color(0.45, 0.95, 0.6, 1.0), 0.0)
	# Centre panel lamps beside the switches; console strip; side panel.
	for i in 3:
		var p4 := face + fb.x * 0.055 + fb.y * (0.05 - i * 0.045) + fb.z * 0.022
		_led(st, Transform3D(fb, p4), Vector3(0.005, 0.005, 0.003), Color(1.0, 0.75, 0.32, 1.0), 0.0)
	_led(st, _xf(Vector3(0.0, 0.817, -0.4)), Vector3(0.06, 0.003, 0.004), Color(0.4, 0.86, 1.0, 0.8), 1.0, 0.5)
	var px := -tub_half_width(-0.6, 1.0) + 0.04
	for i in 3:
		_led(st, _xf(Vector3(px, 1.03, -0.72 + i * 0.07)), Vector3(0.003, 0.006, 0.01), Color(0.45, 0.95, 0.6, 1.0), 0.0)
	# Backup gauge face (a dim ring).
	var g := face + Vector3(SEAT_X + 0.2, 0.0, 0.0) + fb.z * 0.024
	_disc(st, g, fb.z, 0.037, Color(0.35, 0.75, 0.95, 0.35), 0.0)
	# Glare-shield warning lamp, the parked blink on the dash top, the dome light.
	_led(st, _xf(Vector3(-SEAT_X + 0.17, 1.17, -1.05)), Vector3(0.018, 0.006, 0.01), Color(1.0, 0.25, 0.18, 1.0), 8.0)
	_led(st, _xf(Vector3(0.0, 1.15, -1.3)), Vector3(0.008, 0.004, 0.008), Color(1.0, 0.28, 0.2, 1.0), 4.0)
	_led(st, _xf(Vector3(0.0, top_y(ZC1) - 0.048, ZC1 - 0.05)), Vector3(0.07, 0.004, 0.025), Color(1.0, 0.9, 0.75, 0.25), 0.0)
	# Nav lights (red port, green starboard) on the nacelle noses, strobe on the fin, landing lens.
	_lathe(st, _xf(Vector3(-NAC_X, NAC_Y, -1.52), Vector3(PI * 0.5, 0.0, 0.0)), [Vector2(0.0, -0.03), Vector2(0.035, -0.02),
			Vector2(0.04, 0.0)], Color(1.0, 0.18, 0.12, 1.0), 3.0, 0.0, 10)
	_lathe(st, _xf(Vector3(NAC_X, NAC_Y, -1.52), Vector3(PI * 0.5, 0.0, 0.0)), [Vector2(0.0, -0.03), Vector2(0.035, -0.02),
			Vector2(0.04, 0.0)], Color(0.2, 1.0, 0.35, 1.0), 3.0, 0.0, 10)
	_lathe(st, _xf(STROBE), [Vector2(0.0, -0.01), Vector2(0.018, 0.0), Vector2(0.015, 0.015), Vector2(0.0, 0.022)],
			_strobe_col, 2.0, 0.0, 10)
	_disc(st, LAND_LIGHT, Vector3(0.0, -0.6, -0.8).normalized(), 0.045, Color(1.0, 0.95, 0.85, 1.0), 7.0)
	# Nozzle glow: main engine throat (facing back), lift-jet throats (facing down).
	_disc(st, Vector3(0.0, MAIN_Y, Z_TAIL + 0.04), Vector3.BACK, 0.125, Color(0.55, 0.78, 1.0, 1.0), 5.0)
	for p5: Vector3 in VTOL:
		_disc(st, p5 + Vector3(0.0, 0.075, 0.0), Vector3.DOWN, 0.08, Color(0.6, 0.82, 1.0, 1.0), 6.0)
	return _commit(st)


# ==================================================================================================
# Weapons (the Silahlı Mekik, armed_skiff.gd): chin guns, rocket pods
# ==================================================================================================

## Twin rotary cannon under the nose: housings at (±GUN_X, GUN_Y); each barrel cluster spins about
## the ship's Z at GUN_PIVOT_Z, its muzzle at GUN_MUZZLE_Z.
const GUN_X := 0.3
const GUN_Y := 0.45
const GUN_PIVOT_Z := -2.15
const GUN_MUZZLE_Z := -2.6
## Rocket pods outboard of the nacelles: centre (±POD_X, POD_Y), tube mouths at POD_Z0, two tubes
## each (POD_TUBES: x / y offsets), four rockets in all.
const POD_X := 1.34
const POD_Y := 0.62
const POD_Z0 := -0.96
const POD_R := 0.135
const POD_TUBES := [Vector2(0.0, 0.056), Vector2(0.0, -0.056)]


## Gun housings, rocket pods with their pylons (hull material, the livery's colours).
static func _build_weapons() -> ArrayMesh:
	var st := _new_st()
	var rot := Basis(Vector3.RIGHT, PI * 0.5)        # lathe Y -> ship Z
	for sx: float in [-1.0, 1.0]:
		var gx := sx * GUN_X
		# Gun housing tucked under the nose, a fairing into the belly, an ammo feed box behind it.
		_rbox(st, _xf(Vector3(gx, GUN_Y, -1.93)), Vector3(0.072, 0.066, 0.23), C_GRAPHITE, 0.2, 0.15)
		_rbox(st, _xf(Vector3(gx, GUN_Y + 0.07, -1.86)), Vector3(0.045, 0.04, 0.13), _paint, P_PLAIN, 0.0)
		_rbox(st, _xf(Vector3(gx * 0.82, GUN_Y + 0.01, -1.66)), Vector3(0.05, 0.05, 0.07), C_STEEL, P_VENT, 0.2)
		_cyl(st, Vector3(gx, GUN_Y, -2.13), Vector3(gx, GUN_Y, GUN_PIVOT_Z - 0.04), 0.058, 0.052, C_STEEL, P_PLAIN, 0.3, 16)
		# Rocket pod: pylon from the nacelle, a rounded tube body, hazard band, the tube mouths.
		var px := sx * POD_X
		_rbox(st, _xf(Vector3(sx * 1.2, POD_Y, -0.32)), Vector3(0.075, 0.035, 0.3), C_GRAPHITE, 0.25, 0.1)
		var pxf := Transform3D(rot, Vector3(px, POD_Y, 0.0))
		_lathe(st, pxf, [Vector2(POD_R - 0.01, POD_Z0), Vector2(POD_R, POD_Z0 + 0.03), Vector2(POD_R, -0.86)], C_GRAPHITE, P_PLAIN, 0.15, 20)
		_lathe(st, pxf, [Vector2(POD_R, -0.86), Vector2(POD_R, -0.74)], _stripe, _stripe_pat, 0.0, 20)
		_lathe(st, pxf, [Vector2(POD_R, -0.74), Vector2(POD_R, -0.2), Vector2(POD_R, 0.12)], _paint, 0.3, 0.0, 20)
		_lathe(st, pxf, [Vector2(POD_R, 0.12), Vector2(0.115, 0.24), Vector2(0.07, 0.31), Vector2(0.0, 0.33)], C_GRAPHITE, P_PLAIN, 0.15, 20)
		_disc(st, Vector3(px, POD_Y, POD_Z0), Vector3.FORWARD, POD_R - 0.01, C_STEEL, P_PLAIN)
		for t: Vector2 in POD_TUBES:
			var c := Vector3(px + t.x, POD_Y + t.y, POD_Z0 - 0.002)
			_disc(st, c, Vector3.FORWARD, 0.04, Color(0.12, 0.12, 0.13, 0.9), P_PLAIN)
			_lathe(st, Transform3D(rot, c), [Vector2(0.04, -0.012), Vector2(0.05, -0.006), Vector2(0.05, 0.0)], C_METAL, P_PLAIN, 0.3, 14)
	return _commit(st)


## One barrel cluster (three barrels round the spin axis), along -Z from its pivot.
static func _build_barrels() -> ArrayMesh:
	var st := _new_st()
	var bl := GUN_PIVOT_Z - GUN_MUZZLE_Z
	for k in 3:
		var a := TAU * float(k) / 3.0
		var o := Vector3(cos(a), sin(a), 0.0) * 0.027
		_cyl(st, o, o + Vector3(0.0, 0.0, -bl), 0.011, 0.01, C_STEEL, P_BRUSHED, 0.3, 8)
	_cyl(st, Vector3(0, 0, -bl * 0.62), Vector3(0, 0, -bl * 0.62 - 0.025), 0.045, 0.045, C_GRAPHITE, P_PLAIN, 0.2, 14)
	_cyl(st, Vector3(0, 0, -bl + 0.02), Vector3(0, 0, -bl), 0.043, 0.043, C_GRAPHITE, P_PLAIN, 0.2, 14)
	_cyl(st, Vector3(0, 0, 0.0), Vector3(0, 0, -0.03), 0.05, 0.05, C_STEEL, P_PLAIN, 0.3, 14)
	return _commit(st)


## Muzzle flash: crossed soft quads along -Z and one facing forward (UV 0..1; additive material).
static func _build_flash() -> ArrayMesh:
	var st := _new_st()
	var L := 0.42
	var W := 0.1
	for ax: Vector3 in [Vector3.RIGHT, Vector3.UP]:
		var n := ax.cross(Vector3.FORWARD)
		var a := [ax * -W, n, Vector2(0, 0)]
		var b := [ax * W, n, Vector2(1, 0)]
		var c := [ax * W + Vector3(0, 0, -L), n, Vector2(1, 1)]
		var d := [ax * -W + Vector3(0, 0, -L), n, Vector2(0, 1)]
		_quad(st, a, b, c, d, Color(1, 1, 1, 1), 0.0, 0.0)
	var f := 0.13
	_quad(st, [Vector3(-f, -f, -0.02), Vector3.FORWARD, Vector2(0, 0)], [Vector3(f, -f, -0.02), Vector3.FORWARD, Vector2(1, 0)],
			[Vector3(f, f, -0.02), Vector3.FORWARD, Vector2(1, 1)], [Vector3(-f, f, -0.02), Vector3.FORWARD, Vector2(0, 1)],
			Color(1, 1, 1, 1), 0.0, 0.0)
	return _commit(st)


## A loaded rocket's nose in a tube mouth (one per tube, hidden once fired).
static func rocket_tip_mesh() -> ArrayMesh:
	if _tip_mesh != null:
		return _tip_mesh
	var st := _new_st()
	_lathe(st, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO), [Vector2(0.032, 0.0), Vector2(0.026, -0.03),
			Vector2(0.012, -0.055), Vector2(0.0, -0.065)], C_ORANGE, P_PLAIN, 0.0, 12, true)
	var m := _commit(st)
	_tip_mesh = m
	return m


# ==================================================================================================
# Decals
# ==================================================================================================

## Painted lettering. Home: MEKİK on the tail flanks, the registration (YR-0N) on the nacelles,
## dark paint. Rival: the registration (RK-0N) on the tail, RAKİP on the nacelles, light paint.
## Armed: the registration (SM-0N) on the tail, SİLAHLI on the nacelles (behind the rocket pods),
## light paint.
static func add_decals(parent: Node3D, team := "home", reg := "YR-01") -> void:
	var f := UI.font(700)
	var rival := team.begins_with("rival")         # (+ "rival_armed": the rival's Silahlı Mekik)
	var armed := team.ends_with("armed")
	var light := rival or armed
	var ink := Color(0.76, 0.74, 0.72, 0.9) if light else Color(0.2, 0.21, 0.23, 0.9)
	var warn := Color(0.86, 0.3, 0.22, 0.9) if rival else Color(0.72, 0.42, 0.1, 0.9)
	for sx: float in [-1.0, 1.0]:
		var z := 0.95
		var s := section(z)
		var th := 0.12 if sx > 0.0 else PI - 0.12
		var p := sp(s, th, z, -0.004)
		var taper := atan2(section(1.25).y - section(0.65).y, 0.6)
		var l := _label(f, reg if light else "MEKİK", 54, ink)
		l.transform = Transform3D(Basis(Vector3.UP, sx * (PI * 0.5 + taper)), p)
		parent.add_child(l)
		var l2 := _label(f, "RAKİP" if rival else ("SİLAHLI" if armed else reg), 30, Color(ink, 0.85))
		l2.transform = Transform3D(Basis(Vector3.UP, sx * PI * 0.5), Vector3(sx * (NAC_X + NAC_R + 0.003), NAC_Y + 0.02,
				0.75 if armed else 0.35))
		parent.add_child(l2)
		var l3 := _label(f, "İTİCİ — UZAK DUR", 18, warn)
		l3.transform = Transform3D(Basis(Vector3.UP, sx * PI * 0.5), Vector3(sx * (NAC_X + NAC_R + 0.003), NAC_Y, 1.05))
		parent.add_child(l3)


static func _label(f: Font, text: String, size: int, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = f
	l.font_size = size
	l.pixel_size = 0.0021
	l.modulate = col
	l.outline_size = 0
	l.shaded = true
	l.double_sided = false
	l.no_depth_test = false
	l.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return l
