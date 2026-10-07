extends RefCounted
## Procedural low-poly models of the background space battle (space_battle.gd): a fighter and a
## bomber per side, four capital-ship classes (whole ship with engine plumes + three hull-only
## wreck sections), a debris chunk and the two billboard quads. Built once per battle from
## flat-shaded hexahedra; vertex colour rgb = albedo (linear), alpha = emissive amount (hull shader).
## Home side: white hulls with orange paint and warm lights. Rival side: near-black hulls with red.
## Ships point -z, dorsal +y, starboard +x.

const WHITE := Color(0.78, 0.77, 0.74, 0.0)
const PANEL := Color(0.6, 0.6, 0.62, 0.0)
const GREY := Color(0.4, 0.41, 0.43, 0.0)
const ORANGE := Color(0.95, 0.42, 0.08, 0.3)
const ORANGE_LIT := Color(1.0, 0.55, 0.18, 0.85)
const WINDOW := Color(1.0, 0.78, 0.5, 0.8)
const NOZZLE_H := Color(1.0, 0.66, 0.32, 1.0)
const GLASS := Color(0.16, 0.24, 0.34, 0.3)
const DARK := Color(0.13, 0.123, 0.135, 0.0)
const DARK2 := Color(0.19, 0.18, 0.195, 0.0)
const RED := Color(0.85, 0.07, 0.04, 0.85)
const RED_DIM := Color(0.7, 0.06, 0.03, 0.4)
const RED_BAY := Color(1.0, 0.22, 0.07, 0.7)
const NOZZLE_R := Color(1.0, 0.2, 0.08, 1.0)
const PLUME_H := Color(1.0, 0.6, 0.28, 0.0)
const PLUME_R := Color(1.0, 0.2, 0.09, 0.0)

enum { CARRIER_H, BATTLESHIP_H, CARRIER_R, DESTROYER_R }


## Mesh builder: flat-shaded hexahedra (hull surface) and plume quads (glow surface).
class MB:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	## Wreck sections: every hexahedron also goes into secs[0] (stern: centroid z > cut.x),
	## secs[2] (bow: z < cut.y) or secs[1] (mid).
	var secs: Array = []
	var cut := Vector2.ZERO

	func tri(a: Vector3, b: Vector3, d: Vector3, nn: Vector3, col: Color) -> void:
		# Godot's front faces are clockwise seen from outside (the shaders don't cull anyway).
		v.append(a)
		if (b - a).cross(d - a).dot(nn) > 0.0:
			v.append(d)
			v.append(b)
		else:
			v.append(b)
			v.append(d)
		for i in 3:
			n.append(nn)
			c.append(col)

	## Corners 0-3 = one end (-x-y, +x-y, +x+y, -x+y), 4-7 = the other end in the same order.
	func hexa(p: PackedVector3Array, col: Color) -> void:
		var ctr := Vector3.ZERO
		for q: Vector3 in p:
			ctr += q
		ctr /= 8.0
		_face(p[0], p[1], p[2], p[3], ctr, col)
		_face(p[4], p[5], p[6], p[7], ctr, col)
		_face(p[0], p[1], p[5], p[4], ctr, col)
		_face(p[3], p[2], p[6], p[7], ctr, col)
		_face(p[0], p[3], p[7], p[4], ctr, col)
		_face(p[1], p[2], p[6], p[5], ctr, col)
		if not secs.is_empty():
			var k := 1
			if ctr.z > cut.x:
				k = 0
			elif ctr.z < cut.y:
				k = 2
			secs[k].hexa(p, col)

	func _face(a: Vector3, b: Vector3, cc: Vector3, d: Vector3, ctr: Vector3, col: Color) -> void:
		var nn := (cc - a).cross(d - b)
		if nn.length_squared() < 1e-10:
			return
		nn = nn.normalized()
		if nn.dot((a + b + cc + d) * 0.25 - ctr) < 0.0:
			nn = -nn
		tri(a, b, cc, nn, col)
		tri(a, cc, d, nn, col)

	func box(ctr: Vector3, size: Vector3, col: Color) -> void:
		var h := size * 0.5
		hexa(PackedVector3Array([
			ctr + Vector3(-h.x, -h.y, h.z), ctr + Vector3(h.x, -h.y, h.z),
			ctr + Vector3(h.x, h.y, h.z), ctr + Vector3(-h.x, h.y, h.z),
			ctr + Vector3(-h.x, -h.y, -h.z), ctr + Vector3(h.x, -h.y, -h.z),
			ctr + Vector3(h.x, h.y, -h.z), ctr + Vector3(-h.x, h.y, -h.z)]), col)

	## Cross-section w0 x h0 at z0 (centre height y0) to w1 x h1 at z1 (y1).
	func taper(z0: float, w0: float, h0: float, z1: float, w1: float, h1: float, col: Color,
			y0 := 0.0, y1 := 0.0, x := 0.0) -> void:
		var a := w0 * 0.5
		var b := h0 * 0.5
		var e := w1 * 0.5
		var f := h1 * 0.5
		hexa(PackedVector3Array([
			Vector3(x - a, y0 - b, z0), Vector3(x + a, y0 - b, z0), Vector3(x + a, y0 + b, z0), Vector3(x - a, y0 + b, z0),
			Vector3(x - e, y1 - f, z1), Vector3(x + e, y1 - f, z1), Vector3(x + e, y1 + f, z1), Vector3(x - e, y1 + f, z1)]), col)

	## Main hull through cross-sections Vector4(z, width, height, centre y), stern first.
	func hull(prof: Array, col: Color) -> void:
		for i in prof.size() - 1:
			var p: Vector4 = prof[i]
			var q: Vector4 = prof[i + 1]
			taper(p.x, p.y, p.z, q.x, q.y, q.z, col, p.w, q.w)

	## Horizontal plate (wing): root edge at x = rx from z rz0 (leading) to rz1, tip edge at x = tx.
	func plate(rx: float, rz0: float, rz1: float, tx: float, tz0: float, tz1: float, y: float,
			th: float, col: Color) -> void:
		var t := th * 0.5
		hexa(PackedVector3Array([
			Vector3(rx, y - t, rz0), Vector3(tx, y - t, tz0), Vector3(tx, y + t, tz0), Vector3(rx, y + t, rz0),
			Vector3(rx, y - t, rz1), Vector3(tx, y - t, tz1), Vector3(tx, y + t, tz1), Vector3(rx, y + t, rz1)]), col)

	## Vertical plate (fin) at x: root at height ry from z rz0 to rz1, tip at height ty (tz0..tz1).
	func fin(x: float, ry: float, rz0: float, rz1: float, ty: float, tz0: float, tz1: float,
			th: float, col: Color) -> void:
		var t := th * 0.5
		hexa(PackedVector3Array([
			Vector3(x - t, ry, rz0), Vector3(x - t, ty, tz0), Vector3(x + t, ty, tz0), Vector3(x + t, ry, rz0),
			Vector3(x - t, ry, rz1), Vector3(x - t, ty, tz1), Vector3(x + t, ty, tz1), Vector3(x + t, ry, rz1)]), col)

	## Engine plume: two crossed quads from nozzle point o backward (+z) and a soft disc facing aft.
	func plume(o: Vector3, length: float, width: float, col: Color) -> void:
		var h := width * 0.5
		var e := o + Vector3(0.0, 0.0, length)
		_gquad(o + Vector3(-h, 0, 0), o + Vector3(h, 0, 0), e + Vector3(h * 0.3, 0, 0), e + Vector3(-h * 0.3, 0, 0), col)
		_gquad(o + Vector3(0, -h, 0), o + Vector3(0, h, 0), e + Vector3(0, h * 0.3, 0), e + Vector3(0, -h * 0.3, 0), col)
		var r := h * 1.4
		var dc := Color(col.r, col.g, col.b, 1.0)
		var z := o + Vector3(0.0, 0.0, 0.05)
		_gv(z + Vector3(-r, -r, 0), Vector2(0, 0), dc)
		_gv(z + Vector3(r, -r, 0), Vector2(1, 0), dc)
		_gv(z + Vector3(r, r, 0), Vector2(1, 1), dc)
		_gv(z + Vector3(-r, -r, 0), Vector2(0, 0), dc)
		_gv(z + Vector3(r, r, 0), Vector2(1, 1), dc)
		_gv(z + Vector3(-r, r, 0), Vector2(0, 1), dc)

	func _gquad(a: Vector3, b: Vector3, cc: Vector3, d: Vector3, col: Color) -> void:
		var pc := Color(col.r, col.g, col.b, 0.0)
		_gv(a, Vector2(0, 0), pc)
		_gv(b, Vector2(1, 0), pc)
		_gv(cc, Vector2(1, 1), pc)
		_gv(a, Vector2(0, 0), pc)
		_gv(cc, Vector2(1, 1), pc)
		_gv(d, Vector2(0, 1), pc)

	func _gv(p: Vector3, t: Vector2, col: Color) -> void:
		v.append(p)
		n.append(Vector3.BACK)
		c.append(col)
		uv.append(t)

	func commit(mesh: ArrayMesh, mat: Material) -> void:
		if v.is_empty():
			return
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		if not uv.is_empty():
			arr[Mesh.ARRAY_TEX_UV] = uv
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)

	func centroid() -> Vector3:
		var s := Vector3.ZERO
		for p: Vector3 in v:
			s += p
		return s / maxf(float(v.size()), 1.0)


# --- Fighters and bombers -------------------------------------------------------------------

static func craft(team: int, bomber: bool, hull_mat: Material, glow_mat: Material) -> ArrayMesh:
	var b := MB.new()
	var g := MB.new()
	if team == 0 and not bomber:
		_fighter_h(b, g)
	elif team == 0:
		_bomber_h(b, g)
	elif not bomber:
		_fighter_r(b, g)
	else:
		_bomber_r(b, g)
	var m := ArrayMesh.new()
	b.commit(m, hull_mat)
	g.commit(m, glow_mat)
	return m


static func _fighter_h(b: MB, g: MB) -> void:
	b.taper(5.0, 1.8, 1.4, -6.5, 0.45, 0.4, WHITE)
	b.box(Vector3(0, 0.75, -2.2), Vector3(0.75, 0.45, 2.6), GLASS)
	b.box(Vector3(0, 0.72, 1.4), Vector3(1.6, 0.12, 0.7), ORANGE)
	b.fin(0.0, 0.6, 3.0, 5.0, 2.1, 4.3, 5.3, 0.18, WHITE)
	for s: float in [-1.0, 1.0]:
		b.plate(0.8 * s, -1.0, 3.6, 5.2 * s, 2.5, 4.3, 0.0, 0.25, WHITE)
		b.box(Vector3(5.2 * s, 0.0, 3.4), Vector3(0.35, 0.3, 2.0), ORANGE_LIT)
		b.box(Vector3(1.15 * s, -0.1, 3.8), Vector3(0.75, 0.75, 2.8), GREY)
		b.box(Vector3(1.15 * s, -0.1, 5.25), Vector3(0.62, 0.62, 0.12), NOZZLE_H)
		g.plume(Vector3(1.15 * s, -0.1, 5.35), 11.0, 1.2, PLUME_H)


static func _fighter_r(b: MB, g: MB) -> void:
	b.taper(5.0, 1.3, 1.1, -7.0, 0.25, 0.25, DARK)
	b.box(Vector3(0, 0.55, -1.6), Vector3(0.45, 0.2, 1.8), RED_DIM)
	b.box(Vector3(0, 0, 5.05), Vector3(1.0, 0.8, 0.12), NOZZLE_R)
	g.plume(Vector3(0, 0, 5.15), 12.0, 1.6, PLUME_R)
	for s: float in [-1.0, 1.0]:
		b.plate(0.5 * s, -3.6, 5.0, 5.6 * s, 4.2, 5.2, -0.05, 0.3, DARK2)
		b.box(Vector3(3.0 * s, 0.12, 5.0), Vector3(4.4, 0.1, 0.25), RED)
		b.box(Vector3(1.15 * s, 0.0, -4.6), Vector3(0.35, 0.3, 3.2), DARK)
		b.box(Vector3(1.15 * s, 0.0, -6.3), Vector3(0.3, 0.25, 0.4), RED)
		b.fin(2.4 * s, 0.1, 2.6, 4.9, 1.3, 4.0, 5.2, 0.15, DARK2)


static func _bomber_h(b: MB, g: MB) -> void:
	b.taper(8.0, 3.2, 2.4, -6.0, 2.2, 1.8, WHITE)
	b.taper(-6.0, 2.2, 1.8, -10.0, 0.9, 0.8, WHITE)
	b.box(Vector3(0, 1.25, -5.5), Vector3(1.4, 0.6, 3.0), GLASS)
	b.box(Vector3(0, 1.22, 2.0), Vector3(2.6, 0.15, 1.0), ORANGE)
	b.box(Vector3(0, 0, 8.05), Vector3(1.6, 1.2, 0.12), NOZZLE_H)
	g.plume(Vector3(0, 0, 8.15), 15.0, 2.0, PLUME_H)
	for s: float in [-1.0, 1.0]:
		b.plate(1.5 * s, -1.0, 4.5, 8.5 * s, 1.5, 4.8, 0.0, 0.4, WHITE)
		b.box(Vector3(8.5 * s, 0.0, 3.6), Vector3(0.5, 0.35, 2.2), ORANGE_LIT)
		b.box(Vector3(4.0 * s, -0.2, 3.0), Vector3(1.2, 1.2, 4.5), GREY)
		b.box(Vector3(4.0 * s, -0.2, 5.3), Vector3(1.0, 1.0, 0.12), NOZZLE_H)
		g.plume(Vector3(4.0 * s, -0.2, 5.4), 13.0, 1.8, PLUME_H)
		b.box(Vector3(1.9 * s, -1.5, -1.0), Vector3(0.8, 0.8, 6.0), GREY)


static func _bomber_r(b: MB, g: MB) -> void:
	b.taper(9.0, 5.0, 2.2, -2.0, 3.0, 1.8, DARK)
	b.taper(-2.0, 3.0, 1.8, -11.0, 0.6, 0.6, DARK)
	b.box(Vector3(0, 1.0, -3.0), Vector3(0.9, 0.3, 2.5), RED_DIM)
	for s: float in [-1.0, 1.0]:
		b.plate(2.2 * s, -2.0, 9.0, 7.5 * s, 6.0, 9.0, -0.3, 0.5, DARK2)
		b.box(Vector3(5.0 * s, 0.3, 8.9), Vector3(4.0, 0.15, 0.3), RED)
		b.box(Vector3(2.6 * s, -1.1, 1.0), Vector3(1.1, 1.0, 7.0), DARK2)
		b.box(Vector3(2.6 * s, -1.1, -2.6), Vector3(0.6, 0.5, 0.3), RED_DIM)
		b.box(Vector3(1.4 * s, 0.0, 9.05), Vector3(1.4, 1.2, 0.12), NOZZLE_R)
		g.plume(Vector3(1.4 * s, 0.0, 9.15), 14.0, 1.9, PLUME_R)


# --- Capital ships ---------------------------------------------------------------------------

## {"mesh" (hull + plumes), "sections" [stern, mid, bow hull-only meshes], "sec_ctr" [centroids],
##  "len", "hw" (max half width), "pts" (hull surface points), "guns" (starboard broadside mounts;
##  mirror x for port), "bays" (just outside the hangar mouths; x sign = side), "bow" (beam
##  emitter), "launch" (missile tubes), "carrier", "beam", "salvo"}. All ship-local.
static func capital(kind: int, hull_mat: Material, glow_mat: Material) -> Dictionary:
	var b := MB.new()
	b.secs = [MB.new(), MB.new(), MB.new()]
	var g := MB.new()
	var info := {}
	match kind:
		CARRIER_H:
			_carrier_h(b, g, info)
		BATTLESHIP_H:
			_battleship_h(b, g, info)
		CARRIER_R:
			_carrier_r(b, g, info)
		_:
			_destroyer_r(b, g, info)
	var m := ArrayMesh.new()
	b.commit(m, hull_mat)
	g.commit(m, glow_mat)
	info["mesh"] = m
	var secs: Array = []
	var ctrs: Array = []
	for s in b.secs:
		var sm := ArrayMesh.new()
		s.commit(sm, hull_mat)
		secs.append(sm)
		ctrs.append(s.centroid())
	info["sections"] = secs
	info["sec_ctr"] = ctrs
	info["cut"] = b.cut
	info["pts"] = _hull_points(info["prof"], 48, kind)
	return info


## (half width, half height, centre y) of a hull profile at z.
static func _sec_at(prof: Array, z: float) -> Vector3:
	for i in prof.size() - 1:
		var p: Vector4 = prof[i]
		var q: Vector4 = prof[i + 1]
		if z <= p.x and z >= q.x:
			var t := (p.x - z) / maxf(p.x - q.x, 0.001)
			return Vector3(lerpf(p.y, q.y, t) * 0.5, lerpf(p.z, q.z, t) * 0.5, lerpf(p.w, q.w, t))
	var first: Vector4 = prof[0]
	var last: Vector4 = prof[prof.size() - 1]
	var e: Vector4 = first if z > first.x else last
	return Vector3(e.y * 0.5, e.z * 0.5, e.w)


## Points on the hull surface (sides and top, a few underneath) for hits, fires and venting.
static func _hull_points(prof: Array, count: int, salt: int) -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 + salt * 131
	var first: Vector4 = prof[0]
	var last: Vector4 = prof[prof.size() - 1]
	var out := PackedVector3Array()
	for i in count:
		var z := rng.randf_range(last.x * 0.85, first.x * 0.95)
		var s := _sec_at(prof, z)
		var face := rng.randi() % 5
		var p := Vector3.ZERO
		if face <= 1:
			p = Vector3(s.x * (1.0 if face == 0 else -1.0), s.z + rng.randf_range(-0.7, 0.7) * s.y, z)
		elif face <= 3:
			p = Vector3(rng.randf_range(-0.8, 0.8) * s.x, s.z + s.y, z)
		else:
			p = Vector3(rng.randf_range(-0.8, 0.8) * s.x, s.z - s.y, z)
		out.append(p)
	return out


## Rows of lit windows along both sides, following the hull taper.
static func _windows(b: MB, prof: Array, z0: float, z1: float, step: float, col: Color, rows: Array) -> void:
	var z := z0
	while z <= z1:
		var s := _sec_at(prof, z)
		for side: float in [-1.0, 1.0]:
			for r: float in rows:
				b.box(Vector3(side * (s.x + 0.3), s.z + s.y * r, z), Vector3(0.8, 1.4, step * 0.6), col)
		z += step


static func _carrier_h(b: MB, g: MB, info: Dictionary) -> void:
	var prof := [Vector4(200, 60, 44, 0), Vector4(70, 72, 52, 0), Vector4(-70, 64, 46, 0), Vector4(-200, 24, 16, -4)]
	b.cut = Vector2(70.0, -70.0)
	b.hull(prof, WHITE)
	# flight deck, one slab per wreck section, with an orange centre line and edge lights
	b.box(Vector3(0, 26.5, 136), Vector3(70, 5, 126), PANEL)
	b.box(Vector3(0, 26.5, 0), Vector3(80, 5, 136), PANEL)
	b.box(Vector3(0, 17.0, -122), Vector3(50, 4, 96), PANEL)
	b.box(Vector3(0, 29.2, 136), Vector3(4, 0.6, 120), ORANGE)
	b.box(Vector3(0, 29.2, 0), Vector3(4, 0.6, 130), ORANGE)
	var z := -160.0
	while z <= 190.0:
		var dhw := 35.0 if z > 70.0 else (40.0 if z > -69.0 else 25.0)
		var dy := 29.2 if z > -69.0 else 19.2
		for side: float in [-1.0, 1.0]:
			b.box(Vector3(side * (dhw - 4.0), dy, z), Vector3(2.0, 0.8, 6.0), ORANGE_LIT)
		z += 24.0
	for zb: float in [110.0, -30.0]:
		var s := _sec_at(prof, zb)
		b.box(Vector3(0, s.z, zb), Vector3(s.x * 2.0 + 2.0, s.y * 2.0 + 2.0, 8.0), ORANGE)
	# island
	b.box(Vector3(24, 44, 125), Vector3(14, 30, 34), WHITE)
	b.box(Vector3(24, 38, 125), Vector3(14.6, 3, 34.6), ORANGE)
	b.box(Vector3(24, 52, 107.7), Vector3(12, 3, 0.8), WINDOW)
	b.box(Vector3(24, 64, 128), Vector3(2, 12, 2), GREY)
	_windows(b, prof, -150.0, 180.0, 14.0, WINDOW, [-0.3, 0.25])
	# hangar mouths (glowing) and the launch points just outside them
	var hs := _sec_at(prof, 10.0)
	var bays := PackedVector3Array()
	for side: float in [-1.0, 1.0]:
		b.box(Vector3(side * (hs.x + 0.6), 2, 10), Vector3(1.6, 16, 60), ORANGE_LIT)
		bays.append(Vector3(side * (hs.x + 6.0), 2.0, -5.0))
		bays.append(Vector3(side * (hs.x + 6.0), 2.0, 25.0))
	# engines
	b.box(Vector3(0, 0, 208), Vector3(56, 40, 16), GREY)
	for e: Vector2 in [Vector2(-15, -10), Vector2(15, -10), Vector2(-15, 10), Vector2(15, 10)]:
		b.box(Vector3(e.x, e.y, 216.6), Vector3(16, 14, 1.2), NOZZLE_H)
		g.plume(Vector3(e.x, e.y, 217.4), 140.0, 16.0, PLUME_H)
	# deck turrets, broadside sponsons
	for zt: float in [-130.0, -60.0, 0.0, 60.0, 120.0, 170.0]:
		var dhw := 35.0 if zt > 70.0 else (40.0 if zt > -69.0 else 25.0)
		var dy := 31.5 if zt > -69.0 else 21.5
		for side: float in [-1.0, 1.0]:
			b.box(Vector3(side * (dhw - 9.0), dy, zt), Vector3(7, 5, 9), GREY)
	var guns := PackedVector3Array()
	var zg := -140.0
	while zg <= 160.0:
		var s := _sec_at(prof, zg)
		for side: float in [-1.0, 1.0]:
			b.box(Vector3(side * (s.x + 1.5), s.z + 4.0, zg), Vector3(5, 5, 9), GREY)
		guns.append(Vector3(s.x + 3.0, s.z + 4.0, zg))
		zg += 40.0
	info["prof"] = prof
	info["guns"] = guns
	info["bays"] = bays
	info["bow"] = Vector3(0, -4, -204)
	info["beacons"] = PackedVector3Array([Vector3(-37.5, 0, 70), Vector3(37.5, 0, 70), Vector3(24, 71, 128), Vector3(0, -4, -205)])
	info["engine"] = Vector4(0, 0, 224, 46)
	info["launch"] = PackedVector3Array([Vector3(-18, 30, -30), Vector3(18, 30, -30), Vector3(-18, 30, 50), Vector3(18, 30, 50)])
	info["len"] = 416.0
	info["hw"] = 36.0
	info["carrier"] = true
	info["beam"] = false
	info["salvo"] = true


static func _battleship_h(b: MB, g: MB, info: Dictionary) -> void:
	var prof := [Vector4(160, 42, 34, 0), Vector4(55, 50, 38, 0), Vector4(-55, 40, 30, 0), Vector4(-160, 8, 8, -2)]
	b.cut = Vector2(55.0, -55.0)
	b.hull(prof, WHITE)
	# superstructure (stern) and the dorsal spine
	b.box(Vector3(0, 24, 95), Vector3(30, 12, 70), PANEL)
	b.box(Vector3(0, 34, 105), Vector3(18, 10, 36), WHITE)
	b.box(Vector3(0, 33, 105), Vector3(18.6, 2, 36.6), ORANGE)
	b.box(Vector3(0, 36, 86.7), Vector3(16, 2.5, 0.8), WINDOW)
	b.box(Vector3(0, 21, 7), Vector3(14, 8, 94), PANEL)
	# main turrets with barrels pointing forward
	for zt: float in [-85.0, -50.0, 30.0]:
		var s := _sec_at(prof, zt)
		var top := 25.0 if absf(zt - 7.0) < 47.0 else s.z + s.y
		b.box(Vector3(0, top + 3.0, zt), Vector3(16, 6, 18), GREY)
		b.box(Vector3(0, top + 4.0, zt - 17.0), Vector3(2.5, 2.5, 18), GREY)
	for zb: float in [125.0, -25.0]:
		var s := _sec_at(prof, zb)
		b.box(Vector3(0, s.z, zb), Vector3(s.x * 2.0 + 2.0, s.y * 2.0 + 2.0, 7.0), ORANGE)
	_windows(b, prof, -110.0, 150.0, 13.0, WINDOW, [-0.35, 0.2])
	var guns := PackedVector3Array()
	var zg := -100.0
	while zg <= 130.0:
		var s := _sec_at(prof, zg)
		for side: float in [-1.0, 1.0]:
			b.box(Vector3(side * (s.x + 2.0), s.z + 3.0, zg), Vector3(5, 5, 9), GREY)
		guns.append(Vector3(s.x + 4.5, s.z + 3.0, zg))
		zg += 23.0
	b.box(Vector3(0, 0, 167), Vector3(38, 30, 14), GREY)
	for e: Vector2 in [Vector2(-12, -6), Vector2(12, -6), Vector2(0, 8)]:
		b.box(Vector3(e.x, e.y, 174.6), Vector3(13, 12, 1.2), NOZZLE_H)
		g.plume(Vector3(e.x, e.y, 175.4), 120.0, 13.0, PLUME_H)
	b.box(Vector3(0, -2, -163), Vector3(5, 5, 6), ORANGE_LIT)
	info["prof"] = prof
	info["guns"] = guns
	info["bays"] = PackedVector3Array()
	info["bow"] = Vector3(0, -2, -168)
	info["beacons"] = PackedVector3Array([Vector3(-26.5, 0, 55), Vector3(26.5, 0, 55), Vector3(0, 40, 105), Vector3(0, -2, -169)])
	info["engine"] = Vector4(0, 0, 181, 34)
	info["launch"] = PackedVector3Array([Vector3(-12, 26, 60), Vector3(12, 26, 60)])
	info["len"] = 334.0
	info["hw"] = 25.0
	info["carrier"] = false
	info["beam"] = true
	info["salvo"] = false


static func _carrier_r(b: MB, g: MB, info: Dictionary) -> void:
	var prof := [Vector4(200, 150, 32, 0), Vector4(70, 112, 30, 0), Vector4(-75, 62, 24, 0), Vector4(-230, 10, 8, -2)]
	b.cut = Vector2(70.0, -75.0)
	b.hull(prof, DARK)
	# stepped superstructure and bridge (stern), dorsal ridge (mid)
	b.box(Vector3(0, 23, 135), Vector3(64, 16, 110), DARK2)
	b.box(Vector3(0, 38, 148), Vector3(36, 14, 56), DARK2)
	b.box(Vector3(0, 49, 158), Vector3(54, 8, 14), DARK)
	b.box(Vector3(0, 49, 150.7), Vector3(50, 2.2, 0.8), RED)
	b.box(Vector3(0, 19, 0), Vector3(26, 10, 130), DARK2)
	var zr := -60.0
	while zr <= 60.0:
		b.box(Vector3(0, 24.3, zr), Vector3(3, 0.8, 6), RED_DIM)
		zr += 20.0
	# red running lights along the wedge edges
	var ze := -215.0
	while ze <= 195.0:
		var s := _sec_at(prof, ze)
		for side: float in [-1.0, 1.0]:
			b.box(Vector3(side * (s.x + 0.6), s.z, ze), Vector3(1.6, 1.8, 9), RED)
		ze += 26.0
	# hangar mouths
	var hs := _sec_at(prof, 20.0)
	var bays := PackedVector3Array()
	for side: float in [-1.0, 1.0]:
		b.box(Vector3(side * (hs.x + 0.6), hs.z, 20), Vector3(1.6, 14, 64), RED_BAY)
		bays.append(Vector3(side * (hs.x + 7.0), 0.0, 5.0))
		bays.append(Vector3(side * (hs.x + 7.0), 0.0, 35.0))
	for x: float in [-52.0, -26.0, 0.0, 26.0, 52.0]:
		b.box(Vector3(x, 0, 200.6), Vector3(18, 14, 1.2), NOZZLE_R)
		g.plume(Vector3(x, 0, 201.4), 150.0, 16.0, PLUME_R)
	var zt := -150.0
	while zt <= 60.0:
		var s := _sec_at(prof, zt)
		for side: float in [-1.0, 1.0]:
			b.box(Vector3(side * s.x * 0.6, s.z + s.y + 2.5, zt), Vector3(8, 5, 10), DARK2)
			b.box(Vector3(side * s.x * 0.6, s.z + s.y + 5.3, zt), Vector3(2, 0.8, 2), RED)
		zt += 42.0
	var guns := PackedVector3Array()
	var zg := -160.0
	while zg <= 170.0:
		var s := _sec_at(prof, zg)
		guns.append(Vector3(s.x + 3.0, s.z + 4.0, zg))
		zg += 36.0
	info["prof"] = prof
	info["guns"] = guns
	info["bays"] = bays
	info["bow"] = Vector3(0, -2, -232)
	info["beacons"] = PackedVector3Array([Vector3(-76.5, 0, 190), Vector3(76.5, 0, 190), Vector3(0, 54, 158), Vector3(0, -2, -233)])
	info["engine"] = Vector4(0, 0, 208, 60)
	info["launch"] = PackedVector3Array([Vector3(-40, 25, 100), Vector3(40, 25, 100), Vector3(-30, 20, 20), Vector3(30, 20, 20)])
	info["len"] = 430.0
	info["hw"] = 75.0
	info["carrier"] = true
	info["beam"] = false
	info["salvo"] = true


static func _destroyer_r(b: MB, g: MB, info: Dictionary) -> void:
	var prof := [Vector4(170, 36, 30, 0), Vector4(55, 34, 28, 0), Vector4(-60, 20, 16, 0), Vector4(-170, 3, 3, 0)]
	b.cut = Vector2(55.0, -60.0)
	b.hull(prof, DARK)
	b.fin(0.0, 14.0, 40.0, 165.0, 52.0, 110.0, 168.0, 2.5, DARK2)
	b.fin(0.0, -14.0, 40.0, 165.0, -46.0, 115.0, 168.0, 2.5, DARK2)
	b.box(Vector3(0, 52.5, 139), Vector3(3.2, 1.5, 58), RED)
	b.box(Vector3(0, -46.5, 141.5), Vector3(3.2, 1.5, 53), RED)
	for side: float in [-1.0, 1.0]:
		b.box(Vector3(side * 14.0, 0, -95), Vector3(5, 8, 90), DARK2)
		b.box(Vector3(side * 10.0, 0, -70), Vector3(8, 3, 6), DARK2)
		b.box(Vector3(side * 14.0, 0, -141), Vector3(4, 6, 2), RED)
	_windows(b, prof, -50.0, 160.0, 12.0, RED_DIM, [0.3])
	b.box(Vector3(0, 0, -172), Vector3(4, 4, 4), RED)
	for e: Vector2 in [Vector2(-11, 0), Vector2(11, 0), Vector2(0, 9)]:
		b.box(Vector3(e.x, e.y, 170.6), Vector3(12, 12, 1.2), NOZZLE_R)
		g.plume(Vector3(e.x, e.y, 171.4), 130.0, 13.0, PLUME_R)
	var guns := PackedVector3Array()
	var zg := -50.0
	while zg <= 150.0:
		var s := _sec_at(prof, zg)
		for side: float in [-1.0, 1.0]:
			b.box(Vector3(side * (s.x + 1.5), s.z + 3.0, zg), Vector3(4, 4, 8), DARK2)
		guns.append(Vector3(s.x + 3.0, s.z + 3.0, zg))
		zg += 28.0
	info["prof"] = prof
	info["guns"] = guns
	info["bays"] = PackedVector3Array()
	info["bow"] = Vector3(0, 0, -176)
	info["beacons"] = PackedVector3Array([Vector3(-19, 0, 55), Vector3(19, 0, 55), Vector3(0, 53, 165), Vector3(0, -47, 166)])
	info["engine"] = Vector4(0, 2, 178, 32)
	info["launch"] = PackedVector3Array([Vector3(-10, 16, 60), Vector3(10, 16, 60), Vector3(-10, 16, 100), Vector3(10, 16, 100)])
	info["len"] = 346.0
	info["hw"] = 18.0
	info["carrier"] = false
	info["beam"] = true
	info["salvo"] = true


# --- Debris and billboards -------------------------------------------------------------------

## An irregular chunk (~1.4 m); the debris field scales and tints it per instance.
static func chunk() -> ArrayMesh:
	var b := MB.new()
	var col := Color(1, 1, 1, 0)
	b.hexa(PackedVector3Array([
		Vector3(-0.5, -0.4, 0.6), Vector3(0.6, -0.5, 0.5), Vector3(0.4, 0.5, 0.7), Vector3(-0.6, 0.3, 0.4),
		Vector3(-0.4, -0.6, -0.5), Vector3(0.5, -0.3, -0.7), Vector3(0.7, 0.4, -0.4), Vector3(-0.5, 0.6, -0.6)]), col)
	b.box(Vector3(0.55, 0.1, -0.2), Vector3(0.6, 0.22, 1.0), col)
	var m := ArrayMesh.new()
	b.commit(m, null)
	return m


## Unit quad: x in -1..1, y in y0..1 (streaks use y0 = 0: tail .. head; flashes y0 = -1).
static func quad(y0: float) -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-1, y0, 0), Vector3(1, y0, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0)])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
