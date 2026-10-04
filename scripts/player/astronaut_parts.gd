extends RefCounted
## Third-person astronaut body: one skinned ArrayMesh (one surface per material) built from
## procedural pieces — superellipse lofts for the soft suit (with convolute bellows at the joints),
## bevelled shell plates that follow the suit surface, rounded boxes and lathed rings. Built once
## and shared by every astronaut (player, inventory preview, ATV rider).
## Vertex COLOR carries shading data for the suit shader: r = cavity/AO, g = dust, b = brightness,
## a = quilting. UV is in metres (u around, v along), UV2.x is the normalised angle (side seams).
## Model space: origin between the feet, facing -Z, +X is the astronaut's right.

enum { HIPS, SPINE, CHEST, HEAD, THIGH_L, SHIN_L, FOOT_L, THIGH_R, SHIN_R, FOOT_R,
		SHOULDER_L, ELBOW_L, HAND_L, SHOULDER_R, ELBOW_R, HAND_R,
		HAND_L_OPEN, HAND_L_GRIP, HAND_R_OPEN, HAND_R_GRIP, BONE_COUNT }

enum { M_FABRIC, M_SHELL, M_GREY, M_DARK, M_ORANGE, M_METAL, M_VISOR, M_GLOW, M_COUNT }

const BONE_NAMES := ["hips", "spine", "chest", "head", "thigh_l", "shin_l", "foot_l", "thigh_r", "shin_r",
		"foot_r", "shoulder_l", "elbow_l", "hand_l", "shoulder_r", "elbow_r", "hand_r",
		"hand_l_open", "hand_l_grip", "hand_r_open", "hand_r_grip"]
const BONE_PARENT := [-1, 0, 1, 2, 0, 4, 5, 0, 7, 8, 2, 10, 11, 2, 13, 14, 12, 12, 15, 15]
const NODE_BONES := 16          # bones 0..15 mirror the astronaut's Node3D bones

## Skeleton proportions (~1.8 m person, ~1.92 m with helmet and boots).
const L_THIGH := 0.4
const L_SHIN := 0.39
const ANKLE_H := 0.1            # ankle joint above the sole
const HIP_DROP := 0.05          # hip joints below the pelvis origin
const HIPS_Y := 0.94            # L_THIGH + L_SHIN + ANKLE_H + HIP_DROP
const HIP_X := 0.095
const L_UPPER := 0.3
const L_FORE := 0.27
const SHOULDER_X := 0.2
const SHOULDER_Y := 0.35        # shoulder joints above the chest bone
## Hand space: the axis of a gripped handle / bar runs along Z through this point.
const GRIP := Vector3(0, -0.09, 0)
## Chest space: jetpack nozzle exits (flames start here, pointing down).
const NOZZLES := [Vector3(-0.095, -0.13, 0.2), Vector3(0.095, -0.13, 0.2)]
## Head space: headlamp housing (front face) and the direction it points.
const LAMP_POS := Vector3(0.112, 0.252, -0.085)
const LAMP_DIR := Vector3(0.1, -0.05, -1.0)


static func bone_local(i: int) -> Vector3:
	match i:
		HIPS:
			return Vector3(0, HIPS_Y, 0)
		SPINE:
			return Vector3(0, 0.06, 0)
		CHEST:
			return Vector3(0, 0.13, 0)
		HEAD:
			return Vector3(0, 0.47, 0)
		THIGH_L:
			return Vector3(-HIP_X, -HIP_DROP, 0)
		THIGH_R:
			return Vector3(HIP_X, -HIP_DROP, 0)
		SHIN_L, SHIN_R:
			return Vector3(0, -L_THIGH, 0)
		FOOT_L, FOOT_R:
			return Vector3(0, -L_SHIN, 0)
		SHOULDER_L:
			return Vector3(-SHOULDER_X, SHOULDER_Y, 0)
		SHOULDER_R:
			return Vector3(SHOULDER_X, SHOULDER_Y, 0)
		ELBOW_L, ELBOW_R:
			return Vector3(0, -L_UPPER, 0)
		HAND_L, HAND_R:
			return Vector3(0, -L_FORE, 0)
	return Vector3.ZERO


static func bone_global(i: int) -> Vector3:
	var p := Vector3.ZERO
	var k := i
	while k >= 0:
		p += bone_local(k)
		k = BONE_PARENT[k]
	return p


# ------------------------------------------------------------------------------------------
# Accumulator
# ------------------------------------------------------------------------------------------

class Surf:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var t := PackedFloat32Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var b := PackedInt32Array()
	var w := PackedFloat32Array()
	var i := PackedInt32Array()

	func add(p: Vector3, nn: Vector3, tt: Vector3, col: Color, t1: Vector2, t2: Vector2, b0: int, b1: int, w1: float,
			bsign := 1.0) -> void:
		v.append(p)
		n.append(nn)
		t.append(tt.x)
		t.append(tt.y)
		t.append(tt.z)
		t.append(bsign)
		c.append(col)
		uv.append(t1)
		uv2.append(t2)
		b.append(b0)
		b.append(b1)
		b.append(0)
		b.append(0)
		w.append(1.0 - w1)
		w.append(w1)
		w.append(0.0)
		w.append(0.0)

	func tri(a: int, bb: int, cc: int) -> void:
		i.append(a)
		i.append(bb)
		i.append(cc)

	func tint(from: int, col: Color) -> void:
		for k in range(from, c.size()):
			c[k] = col


## Bone weights for a rest-pose point. spec: a bone index (rigid) or [axis, [[coord, bone], ...]]
## with coords ascending along `axis` (smooth blend between consecutive entries).
static func _wt(spec, p: Vector3) -> Array:
	if spec is int:
		return [spec, spec, 0.0]
	var ax: Vector3 = spec[0]
	var ch: Array = spec[1]
	var x := p.dot(ax)
	if x <= float(ch[0][0]):
		return [ch[0][1], ch[0][1], 0.0]
	for k in range(1, ch.size()):
		if x <= float(ch[k][0]):
			var x0: float = ch[k - 1][0]
			var x1: float = ch[k][0]
			var tt := clampf((x - x0) / maxf(x1 - x0, 1e-5), 0.0, 1.0)
			tt = tt * tt * (3.0 - 2.0 * tt)
			return [ch[k - 1][1], ch[k][1], tt]
	var last: Array = ch[ch.size() - 1]
	return [last[1], last[1], 0.0]


## Emits a grid (rows of PackedVector3Array). N: same shape, or empty to derive normals from the
## grid (oriented away from ref[row]). wrap: the columns close around (a seam column is added).
## o: {ao: float | Array[PackedFloat32Array], bright, quilt (float | PackedFloat32Array per row), dust}
static func grid(s: Surf, P: Array, N: Array, ref: PackedVector3Array, wrap: bool, spec, o := {}) -> void:
	var rows := P.size()
	if rows < 2:
		return
	var cols: int = (P[0] as PackedVector3Array).size()
	var bright: float = o.get("bright", 1.0)
	var dust: float = o.get("dust", 1.0)
	var ao_v = o.get("ao", 1.0)
	var q_v = o.get("quilt", 0.0)
	var ecols := cols + 1 if wrap else cols
	var base := s.v.size()
	var vacc := 0.0
	for j in rows:
		var row: PackedVector3Array = P[j]
		var jd := maxi(j - 1, 0)
		var ju := mini(j + 1, rows - 1)
		var rowd: PackedVector3Array = P[jd]
		var rowu: PackedVector3Array = P[ju]
		if j > 0:
			vacc += row[0].distance_to((P[j - 1] as PackedVector3Array)[0])
		var uacc := 0.0
		var qrow: float = q_v[j] if q_v is PackedFloat32Array else float(q_v)
		for ii in ecols:
			var i := ii % cols
			if ii > 0:
				uacc += row[i].distance_to(row[(ii - 1) % cols])
			var il := (i - 1 + cols) % cols if wrap else maxi(i - 1, 0)
			var ir := (i + 1) % cols if wrap else mini(i + 1, cols - 1)
			var du: Vector3 = row[ir] - row[il]
			var dv: Vector3 = rowu[i] - rowd[i]
			var nn: Vector3
			if N.is_empty():
				nn = du.cross(dv)
				if nn.length_squared() < 1e-14:
					# Pole: point away from the neighbouring ring's centre.
					var other: PackedVector3Array = P[ju] if ju != j else P[jd]
					var cen := Vector3.ZERO
					for pp in other:
						cen += pp
					cen /= float(other.size())
					nn = row[i] - cen
				elif nn.dot(row[i] - ref[j]) < 0.0:
					nn = -nn
			else:
				nn = (N[j] as PackedVector3Array)[i]
			nn = nn.normalized()
			var tg := du - nn * du.dot(nn)
			if tg.length_squared() < 1e-12:
				tg = nn.cross(Vector3.UP if absf(nn.y) < 0.9 else Vector3.RIGHT)
			tg = tg.normalized()
			var ao := 1.0
			if ao_v is Array:
				ao = (ao_v[j] as PackedFloat32Array)[i]
			elif ao_v is PackedFloat32Array:
				ao = ao_v[j]
			else:
				ao = float(ao_v)
			var p: Vector3 = row[i]
			var wv := _wt(spec, p)
			var d := (1.0 - smoothstep(0.04, 0.5, p.y)) * dust
			# Binormal (Godot: cross(normal, tangent) * sign) must run along +v for the normal map.
			var bs := 1.0 if nn.cross(tg).dot(dv) >= 0.0 else -1.0
			s.add(p, nn, tg, Color(ao, d, bright, qrow), Vector2(uacc, vacc),
					Vector2(float(ii) / float(cols), float(j) / float(rows - 1)), wv[0], wv[1], wv[2], bs)
	for j in rows - 1:
		for i in ecols - 1:
			var a := base + j * ecols + i
			var bq := a + 1
			var cq := a + ecols
			var dq := cq + 1
			var nq: Vector3 = s.n[a] + s.n[bq] + s.n[cq] + s.n[dq]
			var e := (s.v[bq] - s.v[a]).cross(s.v[cq] - s.v[a]) + (s.v[dq] - s.v[bq]).cross(s.v[cq] - s.v[bq])
			if e.dot(nq) < 0.0:
				s.tri(a, bq, cq)
				s.tri(bq, dq, cq)
			else:
				s.tri(a, cq, bq)
				s.tri(bq, cq, dq)


# ------------------------------------------------------------------------------------------
# Tube: superellipse loft along a straight axis
# ------------------------------------------------------------------------------------------

class Tube:
	var o := Vector3.ZERO
	var ax := Vector3.UP
	var xv := Vector3.RIGHT
	var zv := Vector3.BACK
	var ss := PackedFloat32Array()
	var prm: Array = []          # PackedFloat32Array [cx, cz, rx, rz_neg, rz_pos, n]
	var ribs: Array = []         # [s0, s1, count, amp]

	func _init(origin := Vector3.ZERO, axis := Vector3.UP, x := Vector3.RIGHT, z := Vector3.BACK) -> void:
		o = origin
		ax = axis
		xv = x
		zv = z

	## Station: section centre offset (cx, cz), half sizes rx / rz toward -Z / rz toward +Z, exponent n.
	func st(s: float, cx: float, cz: float, rx: float, rzn: float, rzp: float, n := 2.0) -> void:
		var k := 0
		while k < ss.size() and ss[k] < s:
			k += 1
		ss.insert(k, s)
		prm.insert(k, PackedFloat32Array([cx, cz, rx, rzn, rzp, n]))

	## Rounded end: stations along a quarter ellipse from the section at s_base to a pole at s_tip.
	func dome(s_base: float, s_tip: float, steps := 5) -> void:
		var q := at(s_base)
		for k in range(1, steps + 1):
			var ph := float(k) / float(steps) * PI * 0.5
			var c := cos(ph)
			if k == steps:
				c = 0.0
			st(s_base + (s_tip - s_base) * sin(ph), q[0], q[1], q[2] * c, q[3] * c, q[4] * c, q[5])

	func at(s: float) -> PackedFloat32Array:
		var n := ss.size()
		if s <= ss[0]:
			return prm[0]
		if s >= ss[n - 1]:
			return prm[n - 1]
		var k := 0
		while k < n - 2 and s > ss[k + 1]:
			k += 1
		var s0 := ss[k]
		var s1 := ss[k + 1]
		var h := s1 - s0
		var t := (s - s0) / h
		var t2 := t * t
		var t3 := t2 * t
		var h00 := 2.0 * t3 - 3.0 * t2 + 1.0
		var h10 := t3 - 2.0 * t2 + t
		var h01 := -2.0 * t3 + 3.0 * t2
		var h11 := t3 - t2
		var a: PackedFloat32Array = prm[k]
		var b: PackedFloat32Array = prm[k + 1]
		var out := PackedFloat32Array()
		out.resize(6)
		for c in 6:
			var m0 := (b[c] - a[c]) / h
			if k > 0:
				m0 = (b[c] - (prm[k - 1] as PackedFloat32Array)[c]) / (s1 - ss[k - 1])
			var m1 := (b[c] - a[c]) / h
			if k + 2 < n:
				m1 = ((prm[k + 2] as PackedFloat32Array)[c] - a[c]) / (ss[k + 2] - s0)
			# Keep radii from overshooting toward a pole (no bulge past the stations).
			if c >= 2 and c <= 4 and (a[c] < 1e-4 or b[c] < 1e-4):
				m0 = (b[c] - a[c]) / h
				m1 = m0
			out[c] = h00 * a[c] + h10 * h * m0 + h01 * b[c] + h11 * h * m1
		for c in [2, 3, 4]:
			out[c] = maxf(out[c], 0.0)
		return out

	## Convolute ribs: x = outward offset, y = cavity (1 = open, lower in the grooves).
	func rib(s: float) -> Vector2:
		var off := 0.0
		var ao := 1.0
		for r in ribs:
			var s0: float = r[0]
			var s1: float = r[1]
			if s < s0 or s > s1:
				continue
			var t := (s - s0) / (s1 - s0)
			var env := pow(sin(PI * t), 0.6)
			var wv := 0.5 - 0.5 * cos(TAU * float(r[2]) * t)
			off += float(r[3]) * wv * env
			ao = minf(ao, 1.0 - 0.5 * env * (1.0 - wv))
		return Vector2(off, ao)

	func center(q: PackedFloat32Array, s: float) -> Vector3:
		return o + ax * s + xv * q[0] + zv * q[1]

	func pt(a: float, q: PackedFloat32Array, s: float, off: float) -> Vector3:
		var e := 2.0 / q[5]
		var ca := cos(a)
		var sa := sin(a)
		var fade := clampf(minf(q[2], minf(q[3], q[4])) / 0.012, 0.0, 1.0)
		var o2 := off * fade
		var px := signf(ca) * pow(absf(ca), e) * maxf(q[2] + o2, 0.0)
		var rz := (q[3] if sa < 0.0 else q[4]) + o2
		var pz := signf(sa) * pow(absf(sa), e) * maxf(rz, 0.0)
		return o + ax * s + xv * (q[0] + px) + zv * (q[1] + pz)

	func radius(q: PackedFloat32Array) -> float:
		return (q[2] + (q[3] + q[4]) * 0.5) * 0.5


## Sample positions between s0 and s1: `step` apart, `fine_step` inside the fine ranges, plus
## every station (so domes keep their poles).
static func _rows(tb: Tube, s0: float, s1: float, step: float, fine: Array, fine_step: float) -> PackedFloat32Array:
	var out: Array = []
	var s := s0
	while s < s1 - 1e-5:
		out.append(s)
		var stp := step
		for f in fine:
			if s >= float(f[0]) - 1e-5 and s < float(f[1]) - 1e-5:
				stp = fine_step
			elif s < float(f[0]) and s + stp > float(f[0]):
				stp = float(f[0]) - s
		s += maxf(stp, 0.001)
	out.append(s1)
	for x in tb.ss:
		if x > s0 + 1e-4 and x < s1 - 1e-4:
			out.append(x)
	out.sort()
	var res := PackedFloat32Array()
	for x in out:
		if res.is_empty() or float(x) - res[res.size() - 1] > 0.0015:
			res.append(x)
	return res


## Soft suit surface along a tube. o: ao, bright, quilt, dust, fine ([[s0, s1]]), fine_step.
static func tube(s: Surf, tb: Tube, s0: float, s1: float, sides: int, step: float, spec, o := {}) -> void:
	var rows := _rows(tb, s0, s1, step, o.get("fine", []), o.get("fine_step", 0.006))
	var P: Array = []
	var ref := PackedVector3Array()
	var aos := PackedFloat32Array()
	var quilt := PackedFloat32Array()
	var qv: float = o.get("quilt", 0.0)
	var qr: Array = o.get("quilt_range", [-1e9, 1e9])
	var ao0: float = o.get("ao", 1.0)
	for y in rows:
		var q := tb.at(y)
		var rb := tb.rib(y)
		var row := PackedVector3Array()
		for k in sides:
			row.append(tb.pt(TAU * float(k) / float(sides), q, y, rb.x))
		P.append(row)
		ref.append(tb.center(q, y))
		aos.append(rb.y * ao0)
		var qin := smoothstep(float(qr[0]) - 0.02, float(qr[0]) + 0.02, y) * (1.0 - smoothstep(float(qr[1]) - 0.02, float(qr[1]) + 0.02, y))
		quilt.append(qv * qin * clampf((rb.y - 0.9) * 10.0, 0.0, 1.0))
	var o2 := o.duplicate()
	o2["ao"] = aos
	o2["quilt"] = quilt
	grid(s, P, [], ref, true, spec, o2)


## Offsets in [-half - margin, half + margin] with dense samples across the bevels.
static func _span(half: float, bevel: float, n_mid: int, margin: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var bv := minf(bevel, half * 0.45)
	out.append(-half - margin)
	for k in 4:
		out.append(-half + bv * (1.0 - cos(float(k) / 3.0 * PI * 0.5)))
	var inner := half - bv
	for k in range(1, n_mid):
		out.append(-inner + 2.0 * inner * float(k) / float(n_mid))
	for k in range(3, -1, -1):
		out.append(half - bv * (1.0 - cos(float(k) / 3.0 * PI * 0.5)))
	out.append(half + margin)
	return out


## Bevelled shell plate lying on a tube: centred on angle ac (half-angle ah; >= PI = full band)
## from s0 to s1. thick: height above the surface; bevel: rounded edge width; corner: radius.
## o: nu, nv (interior subdivisions), lift (extra base offset), bright, dust.
static func plate(s: Surf, tb: Tube, ac: float, ah: float, s0: float, s1: float, thick: float, bevel: float,
		corner: float, spec, o := {}) -> void:
	var band := ah >= PI - 1e-3
	var hh := (s1 - s0) * 0.5
	var sc := (s0 + s1) * 0.5
	var vs := _span(hh, bevel, o.get("nv", 6), 0.006)
	var lift: float = o.get("lift", 0.0)
	var qm := tb.at(sc)
	var rm := tb.radius(qm)
	var us := PackedFloat32Array()
	if band:
		var nu: int = o.get("nu", 40)
		for k in nu:
			us.append(-PI + TAU * float(k) / float(nu))
	else:
		var hw_m := ah * rm
		var sp := _span(hw_m, bevel, o.get("nu", 8), 0.006)
		for x in sp:
			us.append(x / rm)
	var P: Array = []
	var ref := PackedVector3Array()
	var AO: Array = []
	for vy in vs:
		var y := sc + vy
		var q := tb.at(y)
		var rl := maxf(tb.radius(q), 0.005)
		var row := PackedVector3Array()
		var aorow := PackedFloat32Array()
		for ua in us:
			var a := ac + ua
			var d: float
			if band:
				d = absf(vy) - hh
			else:
				var px := absf(ua) * rl
				var qx := px - (ah * rl - corner)
				var qy := absf(vy) - (hh - corner)
				d = Vector2(maxf(qx, 0.0), maxf(qy, 0.0)).length() + minf(maxf(qx, qy), 0.0) - corner
			var h: float
			if d >= 0.0:
				h = -0.004
			else:
				var tt := clampf(-d / maxf(bevel, 1e-4), 0.0, 1.0)
				h = thick * sqrt(1.0 - (1.0 - tt) * (1.0 - tt))
			row.append(tb.pt(a, q, y, h + lift))
			aorow.append(lerpf(0.62, 1.0, clampf(h / maxf(thick, 1e-4), 0.0, 1.0)))
		P.append(row)
		ref.append(tb.center(q, y))
		AO.append(aorow)
	var o2 := o.duplicate()
	o2["ao"] = AO
	grid(s, P, [], ref, band, spec, o2)


# ------------------------------------------------------------------------------------------
# Rounded box, lathe, sweep
# ------------------------------------------------------------------------------------------

static func _box_coords(h: float, r: float, seg: float) -> PackedFloat32Array:
	var inner := maxf(h - r, 0.0)
	var out := PackedFloat32Array()
	# Fewer bevel samples on small radii (tiny buttons / vents need almost none).
	var phs: Array = [45.0, 30.0, 15.0] if r >= 0.015 else ([45.0, 22.5] if r >= 0.005 else [45.0])
	for ph in phs:
		out.append(-(inner + r * tan(deg_to_rad(ph))))
	var nd := maxi(1, int(ceil(2.0 * inner / seg)))
	for k in nd + 1:
		out.append(-inner + 2.0 * inner * float(k) / float(nd))
	for k in range(phs.size() - 1, -1, -1):
		out.append(inner + r * tan(deg_to_rad(float(phs[k]))))
	return out


## Box with rounded edges/corners of radius r (exact), transformed by xf.
static func rbox(s: Surf, xf: Transform3D, half: Vector3, r: float, spec, o := {}) -> void:
	r = clampf(r, 0.0005, minf(half.x, minf(half.y, half.z)))
	var seg: float = o.get("seg", 0.04)
	var nb := xf.basis.inverse().transposed()
	var inner := half - Vector3.ONE * r
	var faces := [[0, 1, 2], [1, 2, 0], [2, 0, 1]]
	for f in faces:
		var ka: int = f[0]
		var ku: int = f[1]
		var kv: int = f[2]
		for sg in [-1.0, 1.0]:
			var cu := _box_coords(half[ku], r, seg)
			var cv := _box_coords(half[kv], r, seg)
			var P: Array = []
			var N: Array = []
			for y in cv:
				var row := PackedVector3Array()
				var nrow := PackedVector3Array()
				for x in cu:
					var p := Vector3.ZERO
					p[ka] = half[ka] * sg
					p[ku] = x
					p[kv] = y
					var q := Vector3(clampf(p.x, -inner.x, inner.x), clampf(p.y, -inner.y, inner.y), clampf(p.z, -inner.z, inner.z))
					var dir := (p - q).normalized()
					row.append(xf * (q + dir * r))
					nrow.append((nb * dir).normalized())
				P.append(row)
				N.append(nrow)
			grid(s, P, N, PackedVector3Array(), false, spec, o)


## Surface of revolution around xf's Y axis. prof: (radius, y) points ordered so the outside is
## on the right of the travel direction (e.g. up the outer wall). Duplicate a point for a crease.
static func lathe(s: Surf, xf: Transform3D, prof: PackedVector2Array, sides: int, spec, o := {}) -> void:
	var n := prof.size()
	var P: Array = []
	var N: Array = []
	var nb := xf.basis.inverse().transposed()
	for k in n:
		var p2 := prof[k]
		var tg := prof[mini(k + 1, n - 1)] - prof[maxi(k - 1, 0)]
		if k > 0 and k < n - 1:
			if prof[k].distance_to(prof[k - 1]) < 1e-6:
				tg = prof[k + 1] - prof[k]
			elif prof[k].distance_to(prof[k + 1]) < 1e-6:
				tg = prof[k] - prof[k - 1]
		tg = tg.normalized()
		var n2 := Vector2(tg.y, -tg.x)
		var row := PackedVector3Array()
		var nrow := PackedVector3Array()
		for i in sides:
			var ang := TAU * float(i) / float(sides)
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			row.append(xf * (dir * p2.x + Vector3(0, p2.y, 0)))
			nrow.append((nb * (dir * n2.x + Vector3(0, n2.y, 0))).normalized())
		P.append(row)
		N.append(nrow)
	grid(s, P, N, PackedVector3Array(), true, spec, o)


## Round tube along a smooth (Catmull-Rom) path with per-point radii and rounded end caps.
static func sweep(s: Surf, pts: Array, radii: Array, sides: int, spec, o := {}) -> void:
	var per: int = o.get("per", 5)
	var C: Array = []
	var R: Array = []
	var n := pts.size()
	for k in n - 1:
		var p0: Vector3 = pts[maxi(k - 1, 0)]
		var p1: Vector3 = pts[k]
		var p2: Vector3 = pts[k + 1]
		var p3: Vector3 = pts[mini(k + 2, n - 1)]
		for j in per:
			var t := float(j) / float(per)
			var t2 := t * t
			var t3 := t2 * t
			C.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
			R.append(lerpf(float(radii[k]), float(radii[k + 1]), t))
	C.append(pts[n - 1])
	R.append(float(radii[n - 1]))
	var m := C.size()
	var T: Array = []
	for k in m:
		var tg: Vector3 = (C[mini(k + 1, m - 1)] as Vector3) - (C[maxi(k - 1, 0)] as Vector3)
		T.append(tg.normalized())
	# Caps: hemispheres.
	var caps: bool = o.get("caps", true)
	var rings: Array = []          # [centre, tangent, radius]
	var cs := 3
	if caps:
		for k in range(cs, 0, -1):
			var ph := float(k) / float(cs) * PI * 0.5
			var r0: float = R[0]
			rings.append([(C[0] as Vector3) - (T[0] as Vector3) * sin(ph) * r0, T[0], r0 * cos(ph) if k < cs else 0.0])
	for k in m:
		rings.append([C[k], T[k], R[k]])
	if caps:
		for k in range(1, cs + 1):
			var ph2 := float(k) / float(cs) * PI * 0.5
			var r1: float = R[m - 1]
			rings.append([(C[m - 1] as Vector3) + (T[m - 1] as Vector3) * sin(ph2) * r1, T[m - 1], r1 * cos(ph2) if k < cs else 0.0])
	# Parallel-transported frame.
	var t0: Vector3 = rings[0][1]
	var nrm := t0.cross(Vector3.UP if absf(t0.y) < 0.9 else Vector3.RIGHT).normalized()
	var P: Array = []
	var ref := PackedVector3Array()
	var prev_t := t0
	for rg in rings:
		var tg: Vector3 = rg[1]
		nrm = (nrm - tg * nrm.dot(tg))
		if nrm.length_squared() < 1e-8:
			nrm = tg.cross(Vector3.UP if absf(tg.y) < 0.9 else Vector3.RIGHT)
		nrm = nrm.normalized()
		prev_t = tg
		var bn := tg.cross(nrm).normalized()
		var row := PackedVector3Array()
		var cen: Vector3 = rg[0]
		var rr: float = rg[2]
		for i in sides:
			var ang := TAU * float(i) / float(sides)
			row.append(cen + (nrm * cos(ang) + bn * sin(ang)) * rr)
		P.append(row)
		ref.append(cen)
	grid(s, P, [], ref, true, spec, o)


static func commit(acc: Array) -> ArrayMesh:
	var am := ArrayMesh.new()
	for m in M_COUNT:
		var s: Surf = acc[m]
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		if s.i.is_empty():
			# Keep surface index == material id: a tiny degenerate triangle.
			s.add(Vector3.ZERO, Vector3.UP, Vector3.RIGHT, Color(1, 0, 1, 0), Vector2.ZERO, Vector2.ZERO, HIPS, HIPS, 0.0)
			s.tri(0, 0, 0)
		arr[Mesh.ARRAY_VERTEX] = s.v
		arr[Mesh.ARRAY_NORMAL] = s.n
		arr[Mesh.ARRAY_TANGENT] = s.t
		arr[Mesh.ARRAY_COLOR] = s.c
		arr[Mesh.ARRAY_TEX_UV] = s.uv
		arr[Mesh.ARRAY_TEX_UV2] = s.uv2
		arr[Mesh.ARRAY_BONES] = s.b
		arr[Mesh.ARRAY_WEIGHTS] = s.w
		arr[Mesh.ARRAY_INDEX] = s.i
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


static func skin() -> Skin:
	var sk := Skin.new()
	for i in BONE_COUNT:
		sk.add_bind(i, Transform3D(Basis(), -bone_global(i)))
	return sk


static func _xf(pos: Vector3, b := Basis()) -> Transform3D:
	return Transform3D(b, pos)


## Basis whose Y axis points along `dir`.
static func basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


## Ring of rectangular-ish section (rounded) for lathe(): inner radius ri, outer ro, y0..y1.
static func ring_prof(ri: float, ro: float, y0: float, y1: float, rr := 0.003) -> PackedVector2Array:
	var p := PackedVector2Array()
	rr = minf(rr, minf((ro - ri) * 0.5, (y1 - y0) * 0.5))
	# Inner wall going down, bottom going out, outer wall going up, top going in (outside on the right).
	p.append(Vector2(ri, y1 - rr))
	p.append(Vector2(ri, y0 + rr))
	for k in range(1, 4):
		var a := float(k) / 4.0 * PI * 0.5
		p.append(Vector2(ri + rr - cos(a) * rr, y0 + rr - sin(a) * rr))
	p.append(Vector2(ro - rr, y0))
	for k in range(1, 4):
		var a2 := float(k) / 4.0 * PI * 0.5
		p.append(Vector2(ro - rr + sin(a2) * rr, y0 + rr - cos(a2) * rr))
	p.append(Vector2(ro, y1 - rr))
	for k in range(1, 4):
		var a3 := float(k) / 4.0 * PI * 0.5
		p.append(Vector2(ro - rr + cos(a3) * rr, y1 - rr + sin(a3) * rr))
	p.append(Vector2(ri + rr, y1))
	for k in range(1, 4):
		var a4 := float(k) / 4.0 * PI * 0.5
		p.append(Vector2(ri + rr - sin(a4) * rr, y1 - rr + cos(a4) * rr))
	p.append(Vector2(ri, y1 - rr))
	return p


# ------------------------------------------------------------------------------------------
# The body
# ------------------------------------------------------------------------------------------

static func build_mesh() -> ArrayMesh:
	var acc: Array = []
	for i in M_COUNT:
		acc.append(Surf.new())
	_torso(acc)
	for sd in [-1.0, 1.0]:
		_leg(acc, sd)
		_boot(acc, sd)
		_arm(acc, sd)
		_glove(acc, sd)
	_helmet(acc)
	_backpack(acc)
	return commit(acc)


static func _torso(acc: Array) -> void:
	var fab: Surf = acc[M_FABRIC]
	var tb := Tube.new()
	# y, cx, cz, rx, rz front, rz back, n
	tb.st(0.85, 0.0, 0.013, 0.15, 0.096, 0.11, 2.4)
	tb.st(0.895, 0.0, 0.012, 0.172, 0.106, 0.122, 2.5)
	tb.st(0.95, 0.0, 0.008, 0.175, 0.106, 0.118, 2.5)
	tb.st(1.00, 0.0, 0.004, 0.165, 0.102, 0.106, 2.5)
	tb.st(1.045, 0.0, 0.0, 0.158, 0.1, 0.1, 2.4)
	tb.st(1.10, 0.0, -0.002, 0.163, 0.107, 0.102, 2.5)
	tb.st(1.17, 0.0, -0.005, 0.178, 0.118, 0.106, 2.6)
	tb.st(1.25, 0.0, -0.008, 0.192, 0.127, 0.11, 2.7)
	tb.st(1.33, 0.0, -0.008, 0.2, 0.131, 0.114, 2.8)
	tb.st(1.41, 0.0, -0.006, 0.203, 0.127, 0.116, 2.8)
	tb.st(1.47, 0.0, -0.003, 0.196, 0.12, 0.116, 2.7)
	tb.st(1.52, 0.0, 0.0, 0.172, 0.118, 0.114, 2.5)
	tb.st(1.56, 0.0, 0.0, 0.138, 0.112, 0.11, 2.3)
	tb.st(1.595, 0.0, 0.0, 0.108, 0.1, 0.1, 2.1)
	tb.st(1.62, 0.0, 0.0, 0.098, 0.094, 0.094, 2.0)
	tb.dome(0.85, 0.808, 4)
	tb.ribs = [[0.985, 1.095, 4, 0.0065]]
	var spec := [Vector3.UP, [[0.975, HIPS], [1.05, SPINE], [1.12, CHEST]]]
	tube(fab, tb, 0.808, 1.62, 32, 0.022, spec, {"fine": [[0.985, 1.095]], "fine_step": 0.0055, "quilt": 1.0})
	# Hard chest plate with an orange yoke along its top edge, lower abdomen plate.
	plate(acc[M_SHELL], tb, -PI * 0.5, 1.02, 1.215, 1.505, 0.016, 0.009, 0.04, CHEST, {"nu": 12, "nv": 10})
	plate(acc[M_ORANGE], tb, -PI * 0.5, 0.92, 1.47, 1.515, 0.021, 0.006, 0.012, CHEST, {"nu": 12, "nv": 2})
	plate(acc[M_SHELL], tb, -PI * 0.5, 0.62, 1.115, 1.19, 0.012, 0.007, 0.025, spec, {"nu": 8, "nv": 4})
	# Back plate the life-support pack is mounted on.
	plate(acc[M_GREY], tb, PI * 0.5, 0.85, 1.1, 1.5, 0.012, 0.008, 0.04, CHEST, {"nu": 10, "nv": 8, "bright": 0.75})
	# Side panels under the arms (grey fabric reinforcement).
	for sd in [-1.0, 1.0]:
		var a_side := 0.0 if sd > 0.0 else PI
		plate(acc[M_GREY], tb, a_side, 0.34, 1.16, 1.4, 0.004, 0.006, 0.02, CHEST, {"nu": 4, "nv": 6, "bright": 1.15})
	# Belt (dark band), buckle, pouches.
	plate(acc[M_DARK], tb, 0.0, PI, 0.935, 0.98, 0.013, 0.006, 0.0, HIPS, {"nu": 44, "nv": 3, "bright": 1.2})
	rbox(acc[M_GREY], _xf(Vector3(0, 0.958, -0.122)), Vector3(0.036, 0.024, 0.01), 0.006, HIPS)
	rbox(acc[M_ORANGE], _xf(Vector3(0, 0.958, -0.132)), Vector3(0.018, 0.01, 0.004), 0.003, HIPS)
	for sd in [-1.0, 1.0]:
		var pb := Basis(Vector3.UP, -sd * 0.55)
		rbox(acc[M_DARK], _xf(Vector3(sd * 0.158, 0.935, 0.045), pb), Vector3(0.026, 0.042, 0.04), 0.012, HIPS, {"bright": 1.35})
		rbox(acc[M_DARK], _xf(Vector3(sd * 0.168, 0.962, 0.05), pb), Vector3(0.027, 0.012, 0.042), 0.006, HIPS, {"bright": 1.0})
	# Chest control unit with a screen and buttons.
	var tilt := Basis(Vector3.RIGHT, -0.12)
	rbox(acc[M_GREY], _xf(Vector3(0, 1.295, -0.163), tilt), Vector3(0.072, 0.043, 0.02), 0.012, CHEST)
	rbox(acc[M_DARK], _xf(Vector3(-0.02, 1.3, -0.182), tilt), Vector3(0.038, 0.027, 0.002), 0.002, CHEST, {"bright": 0.6})
	_glow_box(acc, Vector3(-0.02, 1.3, -0.1838), Vector3(0.033, 0.022, 0.0015), Color(0.3, 0.85, 1.0), CHEST, tilt)
	var btn := [Color(1.0, 0.3, 0.2), Color(0.3, 1.0, 0.45), Color(1.0, 0.7, 0.2)]
	for k in 3:
		_glow_box(acc, Vector3(0.033 + (k % 2) * 0.02, 1.312 - (k / 2) * 0.022, -0.183), Vector3(0.007, 0.007, 0.003), btn[k], CHEST, tilt)
	# Name patch (the Label3D text sits on it).
	rbox(acc[M_DARK], _xf(Vector3(0.1, 1.436, -0.139), Basis(Vector3.UP, -0.3)), Vector3(0.045, 0.013, 0.003), 0.003, CHEST,
			{"bright": 0.55})
	# Neck collar: a flange on the shoulders, metal bearing ring and an orange seal.
	var cb := Basis.from_scale(Vector3(1.0, 1.0, 0.86))
	var cp := PackedVector2Array([Vector2(0.1, 1.575), Vector2(0.1, 1.575), Vector2(0.158, 1.536), Vector2(0.158, 1.536),
			Vector2(0.153, 1.552), Vector2(0.142, 1.576), Vector2(0.132, 1.594), Vector2(0.132, 1.594), Vector2(0.11, 1.596)])
	lathe(acc[M_GREY], Transform3D(cb, Vector3(0, 0, -0.004)), cp, 36, CHEST, {"bright": 0.8})
	lathe(acc[M_METAL], Transform3D(Basis(), Vector3(0, 0, -0.004)), ring_prof(0.116, 0.136, 1.592, 1.622, 0.006), 36, CHEST)
	lathe(acc[M_ORANGE], Transform3D(Basis(), Vector3(0, 0, -0.004)), ring_prof(0.13, 0.14, 1.598, 1.612, 0.003), 36, CHEST)


static func _glow_box(acc: Array, pos: Vector3, half: Vector3, col: Color, spec, b := Basis()) -> void:
	var s: Surf = acc[M_GLOW]
	var n0 := s.v.size()
	rbox(s, _xf(pos, b), half, 0.002, spec)
	s.tint(n0, col)


static func _leg(acc: Array, sd: float) -> void:
	var fab: Surf = acc[M_FABRIC]
	var thigh := THIGH_L if sd < 0.0 else THIGH_R
	var shin := SHIN_L if sd < 0.0 else SHIN_R
	var tb := Tube.new(Vector3(sd * HIP_X, 0, 0))
	tb.st(0.95, sd * 0.004, 0.006, 0.086, 0.094, 0.1, 2.15)
	tb.st(0.9, sd * 0.004, 0.0, 0.094, 0.1, 0.106, 2.15)
	tb.st(0.84, sd * 0.003, -0.002, 0.096, 0.1, 0.1, 2.1)
	tb.st(0.76, 0.0, -0.004, 0.092, 0.097, 0.092, 2.1)
	tb.st(0.68, 0.0, -0.004, 0.086, 0.092, 0.084, 2.1)
	tb.st(0.61, 0.0, -0.002, 0.079, 0.085, 0.077, 2.1)
	tb.st(0.565, 0.0, 0.0, 0.075, 0.08, 0.074, 2.1)
	tb.st(0.495, 0.0, -0.004, 0.072, 0.079, 0.07, 2.1)
	tb.st(0.43, 0.0, 0.0, 0.069, 0.07, 0.074, 2.1)
	tb.st(0.37, 0.0, 0.003, 0.07, 0.066, 0.079, 2.1)
	tb.st(0.30, 0.0, 0.002, 0.066, 0.063, 0.072, 2.1)
	tb.st(0.24, 0.0, 0.0, 0.062, 0.061, 0.064, 2.1)
	tb.st(0.18, 0.0, 0.0, 0.058, 0.058, 0.06, 2.1)
	tb.dome(0.95, 1.0, 4)
	tb.ribs = [[0.43, 0.565, 4, 0.0065]]
	# The leg ends inside the boot shaft: rigid on the shin there (the shaft bends at the ankle).
	var spec := [Vector3.UP, [[0.455, shin], [0.525, thigh], [0.86, thigh], [0.95, HIPS]]]
	tube(fab, tb, 0.18, 1.0, 24, 0.024, spec, {"fine": [[0.43, 0.565]], "fine_step": 0.0055, "quilt": 1.0, "quilt_range": [0.6, 1.0]})
	# Knee guard (shell + orange insert), riding on the shin.
	plate(acc[M_SHELL], tb, -PI * 0.5, 0.95, 0.44, 0.578, 0.018, 0.008, 0.032, shin, {"nu": 10, "nv": 8})
	plate(acc[M_ORANGE], tb, -PI * 0.5, 0.78, 0.5, 0.516, 0.0215, 0.003, 0.004, shin, {"nu": 10, "nv": 2})
	# Thigh: front shell guard, outer orange stripe, cargo pouch.
	plate(acc[M_SHELL], tb, -PI * 0.5 + sd * 0.25, 0.72, 0.665, 0.81, 0.008, 0.007, 0.03, thigh, {"nu": 10, "nv": 8})
	var a_out := 0.0 if sd > 0.0 else PI
	plate(acc[M_ORANGE], tb, a_out, 0.09, 0.6, 0.86, 0.003, 0.003, 0.004, spec, {"nu": 3, "nv": 10})
	var pb := Basis(Vector3.UP, sd * 0.25)
	rbox(acc[M_DARK], _xf(Vector3(sd * (HIP_X + 0.085), 0.72, 0.03), pb), Vector3(0.02, 0.055, 0.045), 0.012, thigh, {"bright": 1.35})
	rbox(acc[M_DARK], _xf(Vector3(sd * (HIP_X + 0.1), 0.763, 0.03), pb), Vector3(0.012, 0.018, 0.046), 0.008, thigh, {"bright": 1.0})


static func _boot(acc: Array, sd: float) -> void:
	var shin := SHIN_L if sd < 0.0 else SHIN_R
	var foot := FOOT_L if sd < 0.0 else FOOT_R
	var dark: Surf = acc[M_DARK]
	var x0 := sd * HIP_X
	# Shaft.
	var sh := Tube.new(Vector3(x0, 0, 0))
	sh.st(0.08, 0.0, 0.004, 0.068, 0.07, 0.077, 2.3)
	sh.st(0.14, 0.0, 0.002, 0.07, 0.073, 0.077, 2.3)
	sh.st(0.21, 0.0, 0.0, 0.07, 0.072, 0.075, 2.2)
	sh.st(0.27, 0.0, 0.0, 0.07, 0.071, 0.074, 2.2)
	sh.st(0.285, 0.0, 0.0, 0.07, 0.071, 0.074, 2.2)
	var spec := [Vector3.UP, [[0.11, foot], [0.17, shin]]]
	var bo := {"bright": 1.4, "dust": 0.35}
	tube(dark, sh, 0.08, 0.285, 22, 0.025, spec, bo)
	plate(acc[M_ORANGE], sh, 0.0, PI, 0.236, 0.25, 0.003, 0.003, 0.0, shin, {"nu": 30, "nv": 2, "dust": 0.3})
	# Padded top cuff.
	lathe(dark, Transform3D(Basis.from_scale(Vector3(1.0, 1.0, 1.05)), Vector3(x0, 0, 0.0)),
			ring_prof(0.058, 0.079, 0.272, 0.3, 0.011), 22, shin, {"bright": 1.1, "dust": 0.2})
	# Foot: a loft forward along -Z (section "z" axis is up).
	var ft := Tube.new(Vector3(x0, 0, 0), Vector3.FORWARD, Vector3.RIGHT, Vector3.UP)
	# s (forward), cx, cz (up), rx, rz down, rz up, n
	ft.st(-0.09, 0.0, 0.072, 0.046, 0.037, 0.048, 2.6)
	ft.st(-0.072, 0.0, 0.075, 0.058, 0.042, 0.062, 2.6)
	ft.st(-0.04, 0.0, 0.078, 0.065, 0.045, 0.072, 2.6)
	ft.st(0.0, 0.0, 0.078, 0.067, 0.045, 0.072, 2.6)
	ft.st(0.05, 0.0, 0.07, 0.067, 0.037, 0.054, 2.7)
	ft.st(0.1, 0.0, 0.062, 0.066, 0.029, 0.04, 2.8)
	ft.st(0.15, 0.0, 0.058, 0.061, 0.025, 0.031, 2.8)
	ft.st(0.19, 0.0, 0.055, 0.05, 0.021, 0.024, 2.6)
	ft.dome(-0.09, -0.102, 3)
	ft.dome(0.19, 0.218, 4)
	tube(dark, ft, -0.102, 0.218, 22, 0.02, foot, bo)
	# Toe cap, heel counter, instep strap, orange flash.
	var go := {"nu": 10, "nv": 5, "bright": 0.8, "dust": 0.4}
	plate(acc[M_GREY], ft, PI * 0.5, 1.75, 0.112, 0.205, 0.006, 0.006, 0.02, foot, go)
	plate(acc[M_GREY], ft, PI * 0.5, 1.4, 0.015, 0.045, 0.006, 0.004, 0.008, foot, {"nu": 10, "nv": 2, "bright": 0.8, "dust": 0.4})
	plate(acc[M_GREY], ft, PI * 0.5, 2.2, -0.102, -0.06, 0.005, 0.004, 0.008, foot, {"nu": 10, "nv": 2, "bright": 0.8, "dust": 0.4})
	var a_out := 0.0 if sd > 0.0 else PI
	plate(acc[M_ORANGE], ft, a_out, 0.3, -0.04, 0.085, 0.004, 0.004, 0.012, foot, {"nu": 4, "nv": 6, "dust": 0.3})
	# Sole with lugs.
	var so := Tube.new(Vector3(x0, 0, 0), Vector3.FORWARD, Vector3.RIGHT, Vector3.UP)
	so.st(-0.095, 0.0, 0.019, 0.058, 0.019, 0.017, 5.0)
	so.st(-0.04, 0.0, 0.019, 0.066, 0.019, 0.017, 5.0)
	so.st(0.05, 0.0, 0.019, 0.07, 0.019, 0.017, 5.0)
	so.st(0.15, 0.0, 0.021, 0.065, 0.019, 0.017, 5.0)
	so.st(0.2, 0.0, 0.024, 0.054, 0.018, 0.016, 4.0)
	so.dome(-0.095, -0.108, 3)
	so.dome(0.2, 0.228, 4)
	so.ribs = [[-0.09, 0.2, 11, 0.0018]]
	tube(dark, so, -0.108, 0.228, 22, 0.012, foot, {"bright": 0.55, "dust": 0.5, "fine": [[-0.09, 0.2]], "fine_step": 0.0045})
	# Ankle hinge caps.
	for k in [-1.0, 1.0]:
		var c := Vector3(x0 + k * 0.069, 0.108, 0.004)
		var bb := basis_y(Vector3(k, 0, 0))
		lathe(acc[M_GREY], Transform3D(bb, c), PackedVector2Array([Vector2(0.024, -0.004), Vector2(0.024, 0.004),
				Vector2(0.024, 0.004), Vector2(0.018, 0.007), Vector2(0.0, 0.007)]), 16, foot, {"bright": 0.85, "dust": 0.3})
		lathe(acc[M_METAL], Transform3D(bb, c), PackedVector2Array([Vector2(0.009, 0.006), Vector2(0.009, 0.01),
				Vector2(0.009, 0.01), Vector2(0.0, 0.01)]), 12, foot)


static func _arm(acc: Array, sd: float) -> void:
	var fab: Surf = acc[M_FABRIC]
	var sh_b := SHOULDER_L if sd < 0.0 else SHOULDER_R
	var el_b := ELBOW_L if sd < 0.0 else ELBOW_R
	var hd_b := HAND_L if sd < 0.0 else HAND_R
	var sx := sd * SHOULDER_X
	var sy := bone_global(sh_b).y           # 1.48
	var tb := Tube.new(Vector3(sx, 0, 0))
	tb.st(sy + 0.04, 0.0, 0.0, 0.07, 0.07, 0.07, 2.1)
	tb.st(sy + 0.01, 0.0, 0.0, 0.076, 0.074, 0.074, 2.1)
	tb.st(sy - 0.05, 0.0, 0.0, 0.074, 0.072, 0.07, 2.1)
	tb.st(sy - 0.13, 0.0, 0.0, 0.067, 0.068, 0.066, 2.1)
	tb.st(sy - 0.2, 0.0, 0.0, 0.062, 0.064, 0.062, 2.1)
	tb.st(sy - 0.245, 0.0, 0.0, 0.058, 0.06, 0.058, 2.1)
	tb.st(sy - 0.3, 0.0, 0.004, 0.056, 0.057, 0.061, 2.1)
	tb.st(sy - 0.345, 0.0, 0.0, 0.058, 0.06, 0.058, 2.1)
	tb.st(sy - 0.41, 0.0, 0.0, 0.059, 0.06, 0.057, 2.1)
	tb.st(sy - 0.48, 0.0, 0.0, 0.053, 0.053, 0.051, 2.1)
	tb.st(sy - 0.53, 0.0, 0.0, 0.047, 0.047, 0.046, 2.1)
	tb.st(sy - 0.555, 0.0, 0.0, 0.044, 0.044, 0.044, 2.1)
	tb.dome(sy + 0.04, sy + 0.085, 4)
	var el_y := sy - L_UPPER
	tb.ribs = [[el_y - 0.055, el_y + 0.06, 4, 0.006], [sy - 0.535, sy - 0.49, 3, 0.004]]
	var hy := el_y - L_FORE
	var spec := [Vector3.UP, [[hy + 0.015, hd_b], [hy + 0.035, el_b], [el_y - 0.03, el_b], [el_y + 0.03, sh_b]]]
	tube(fab, tb, sy - 0.555, sy + 0.085, 22, 0.022, spec,
			{"fine": [[el_y - 0.055, el_y + 0.06], [sy - 0.535, sy - 0.49]], "fine_step": 0.0055, "quilt": 1.0, "quilt_range": [el_y + 0.07, sy + 0.1]})
	var a_out := 0.0 if sd > 0.0 else PI
	# Shoulder pad: a domed shell cap tipped outward with a rolled rim (pole -> rim, then flipped so
	# the outside is on the right of the travel direction) and an orange band.
	var cap_dir := Vector3(sd * 0.55, 1.0, 0.0).normalized()
	var cb := basis_y(cap_dir)
	var cc := Vector3(sx, sy, 0.0)
	var pr := PackedVector2Array()
	var R := 0.095
	for k in 9:
		var th := float(k) / 8.0 * deg_to_rad(68.0)
		pr.append(Vector2(sin(th) * R, cos(th) * R))
	var th_e := deg_to_rad(68.0)
	for k in range(1, 5):
		var ph := float(k) / 4.0 * PI
		var rr := R - 0.007 + cos(ph) * 0.007
		pr.append(Vector2(sin(th_e) * rr + sin(ph) * 0.003, cos(th_e) * rr - sin(ph) * 0.006))
	lathe(acc[M_SHELL], Transform3D(cb, cc), _flip_profile(pr), 28, sh_b)
	var band := PackedVector2Array()
	var t0 := deg_to_rad(50.0)
	var t1 := deg_to_rad(58.0)
	band.append(Vector2(sin(t0) * (R + 0.0), cos(t0) * (R + 0.0)))
	for k in 5:
		var th2 := lerpf(t0, t1, float(k) / 4.0)
		band.append(Vector2(sin(th2) * (R + 0.004), cos(th2) * (R + 0.004)))
	band.append(Vector2(sin(t1) * R, cos(t1) * R))
	lathe(acc[M_ORANGE], Transform3D(cb, cc), _flip_profile(band), 28, sh_b)
	# Elbow pad, forearm orange band, wrist bellows ring.
	plate(acc[M_GREY], tb, PI * 0.5, 0.95, el_y - 0.04, el_y + 0.035, 0.012, 0.007, 0.022, el_b, {"nu": 6, "nv": 4, "bright": 1.1})
	plate(acc[M_ORANGE], tb, 0.0, PI, el_y - 0.12, el_y - 0.095, 0.004, 0.003, 0.0, el_b, {"nu": 30, "nv": 2})
	plate(acc[M_SHELL], tb, a_out - sd * 0.5, 0.75, el_y - 0.215, el_y - 0.13, 0.008, 0.006, 0.02, el_b, {"nu": 6, "nv": 4})
	# Wrist computer (left) / control pad (right) on the outer forearm.
	var fy := el_y - 0.19
	var fx := sx + sd * 0.06
	if sd < 0.0:
		var wb := Basis(Vector3.UP, 0.0)
		rbox(acc[M_DARK], _xf(Vector3(fx, fy, 0.0), wb), Vector3(0.012, 0.045, 0.034), 0.008, el_b, {"bright": 1.2})
		rbox(acc[M_ORANGE], _xf(Vector3(fx - 0.004, fy, 0.0), wb), Vector3(0.009, 0.05, 0.012), 0.004, el_b)
		_glow_box(acc, Vector3(fx - 0.0115, fy + 0.004, 0.0), Vector3(0.002, 0.03, 0.024), Color(0.3, 0.85, 1.0), el_b)
	else:
		rbox(acc[M_GREY], _xf(Vector3(fx, fy, 0.0)), Vector3(0.01, 0.035, 0.024), 0.006, el_b)
		_glow_box(acc, Vector3(fx + 0.0095, fy + 0.012, -0.008), Vector3(0.0015, 0.005, 0.005), Color(0.3, 1.0, 0.45), el_b)
		_glow_box(acc, Vector3(fx + 0.0095, fy, -0.008), Vector3(0.0015, 0.005, 0.005), Color(1.0, 0.6, 0.15), el_b)


static func _flip_profile(p: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in range(p.size() - 1, -1, -1):
		out.append(p[k])
	return out


static func _glove(acc: Array, sd: float) -> void:
	var hd_b := HAND_L if sd < 0.0 else HAND_R
	var open_b := HAND_L_OPEN if sd < 0.0 else HAND_R_OPEN
	var grip_b := HAND_L_GRIP if sd < 0.0 else HAND_R_GRIP
	var w := bone_global(hd_b)
	var dark: Surf = acc[M_DARK]
	# Gauntlet: flared cuff over the sleeve, orange rim, metal wrist bearing.
	var gp := PackedVector2Array([Vector2(0.0, -0.03), Vector2(0.036, -0.03), Vector2(0.044, -0.012), Vector2(0.047, 0.012),
			Vector2(0.055, 0.04), Vector2(0.06, 0.055), Vector2(0.06, 0.055), Vector2(0.052, 0.058)])
	lathe(dark, _xf(w), gp, 20, hd_b, {"bright": 1.25})
	lathe(acc[M_ORANGE], _xf(w), ring_prof(0.055, 0.0625, 0.045, 0.057, 0.003), 20, hd_b)
	lathe(acc[M_METAL], _xf(w), ring_prof(0.044, 0.054, 0.056, 0.068, 0.003), 20, hd_b)
	# Open, relaxed hand: palm faces the thigh (-X for the right hand), thumb forward.
	var s := sd
	rbox(dark, _xf(w + Vector3(s * 0.003, -0.058, 0.0), Basis(Vector3.FORWARD, s * 0.06)), Vector3(0.017, 0.04, 0.04), 0.015, open_b,
			{"bright": 1.25})
	rbox(acc[M_GREY], _xf(w + Vector3(s * 0.019, -0.058, 0.0), Basis(Vector3.FORWARD, s * 0.06)), Vector3(0.004, 0.028, 0.03), 0.004,
			open_b, {"bright": 1.0})
	var fz := [-0.029, -0.0095, 0.0095, 0.027]
	var fl := [0.074, 0.08, 0.075, 0.06]
	var fr := [0.0105, 0.011, 0.0105, 0.0092]
	for k in 4:
		var p := w + Vector3(s * 0.002, -0.094, fz[k])
		var pts := [p]
		var dir := Vector3(0, -1, 0)
		var lens := [0.44, 0.32, 0.24]
		var curl := [0.18, 0.32, 0.3]
		for j in 3:
			dir = dir.rotated(Vector3.FORWARD, s * curl[j])
			p = p + dir * float(fl[k]) * float(lens[j])
			pts.append(p)
		var r0: float = fr[k]
		sweep(dark, pts, [r0, r0 * 0.97, r0 * 0.92, r0 * 0.85], 8, open_b, {"per": 3, "bright": 1.25})
	var th := [w + Vector3(-s * 0.008, -0.03, -0.03), w + Vector3(-s * 0.018, -0.052, -0.048),
			w + Vector3(-s * 0.024, -0.075, -0.054), w + Vector3(-s * 0.026, -0.095, -0.05)]
	sweep(dark, th, [0.014, 0.0125, 0.0115, 0.0105], 8, open_b, {"per": 3, "bright": 1.25})
	# Fist around a handle along Z through GRIP (palm on the +X*s side of it).
	var gc := w + GRIP
	rbox(dark, _xf(gc + Vector3(s * 0.03, 0.022, 0.0)), Vector3(0.014, 0.046, 0.042), 0.012, grip_b, {"bright": 1.25})
	rbox(acc[M_GREY], _xf(gc + Vector3(s * 0.044, 0.022, 0.0)), Vector3(0.004, 0.03, 0.031), 0.004, grip_b, {"bright": 1.0})
	for k in 4:
		var z: float = fz[k] * 1.02
		var r1: float = fr[k] * 1.05
		var fp := [gc + Vector3(s * 0.03, -0.012, z), gc + Vector3(s * 0.016, -0.03, z), gc + Vector3(-s * 0.01, -0.03, z),
				gc + Vector3(-s * 0.028, -0.012, z), gc + Vector3(-s * 0.026, 0.01, z)]
		sweep(dark, fp, [r1, r1, r1 * 0.97, r1 * 0.93, r1 * 0.88], 8, grip_b, {"per": 3, "bright": 1.25})
	var tg := [gc + Vector3(s * 0.022, 0.06, -0.036), gc + Vector3(-s * 0.002, 0.04, -0.05), gc + Vector3(-s * 0.024, 0.02, -0.05),
			gc + Vector3(-s * 0.03, 0.005, -0.036)]
	sweep(dark, tg, [0.014, 0.0125, 0.0115, 0.0105], 8, grip_b, {"per": 3, "bright": 1.25})


static func _helmet(acc: Array) -> void:
	var hb := bone_global(HEAD)
	var tb := Tube.new(hb)
	var yc := 0.148
	var hh := 0.19
	var ys := [0.0, 0.03, 0.06, 0.09, 0.12, 0.15, 0.18, 0.21, 0.24, 0.265, 0.29, 0.308, 0.32, 0.329, 0.334, 0.337, 0.338]
	for y in ys:
		var k := (float(y) - yc) / hh
		if k < 0.0:
			k *= 0.86          # fuller toward the neck ring
		var f := sqrt(maxf(1.0 - k * k, 0.0))
		if float(y) >= 0.338:
			f = 0.0
		tb.st(y, 0.0, -0.006, 0.156 * f, 0.168 * f, 0.158 * f, 2.15)
	tube(acc[M_SHELL], tb, 0.0, 0.338, 36, 0.016, HEAD)
	# Visor: dark gasket frame, gold glass bulging slightly past it.
	plate(acc[M_DARK], tb, -PI * 0.5, 1.2, 0.052, 0.25, 0.009, 0.006, 0.05, HEAD, {"nu": 16, "nv": 12, "bright": 0.9})
	plate(acc[M_VISOR], tb, -PI * 0.5, 1.07, 0.067, 0.236, 0.0135, 0.012, 0.042, HEAD, {"nu": 18, "nv": 14})
	# Crest along the top, side panels.
	plate(acc[M_GREY], tb, PI * 0.5, 0.2, 0.19, 0.318, 0.006, 0.005, 0.012, HEAD, {"nu": 4, "nv": 6, "bright": 1.2})
	for sd in [-1.0, 1.0]:
		var a_side := 0.0 if sd > 0.0 else PI
		plate(acc[M_GREY], tb, a_side + sd * 0.15, 0.42, 0.05, 0.19, 0.007, 0.006, 0.025, HEAD, {"nu": 5, "nv": 6, "bright": 1.15})
		# Ear module: disc with a metal ring and an orange cap.
		var c := hb + Vector3(sd * 0.161, 0.128, 0.018)
		var eb := basis_y(Vector3(sd, 0, 0))
		lathe(acc[M_GREY], Transform3D(eb, c), PackedVector2Array([Vector2(0.04, -0.01), Vector2(0.038, 0.012),
				Vector2(0.03, 0.022), Vector2(0.03, 0.022), Vector2(0.0, 0.022)]), 20, HEAD, {"bright": 0.95})
		lathe(acc[M_METAL], Transform3D(eb, c), ring_prof(0.03, 0.041, 0.0, 0.012, 0.003), 20, HEAD)
		lathe(acc[M_ORANGE], Transform3D(eb, c), PackedVector2Array([Vector2(0.016, 0.02), Vector2(0.014, 0.026),
				Vector2(0.014, 0.026), Vector2(0.0, 0.026)]), 14, HEAD)
	# Headlamp housing above the visor, right side (the lens is a separate glowing mesh).
	var lb := basis_y(LAMP_DIR)
	lathe(acc[M_GREY], Transform3D(lb, hb + LAMP_POS), PackedVector2Array([Vector2(0.0, -0.035), Vector2(0.019, -0.035),
			Vector2(0.023, -0.015), Vector2(0.023, 0.0), Vector2(0.023, 0.0), Vector2(0.017, 0.002)]), 16, HEAD, {"bright": 0.8})
	# Neck ring of the helmet (sits inside the collar).
	lathe(acc[M_METAL], _xf(hb + Vector3(0, 0, -0.006)), ring_prof(0.104, 0.12, -0.004, 0.022, 0.004), 32, HEAD)
	# Antenna (left rear).
	sweep(acc[M_METAL], [hb + Vector3(-0.098, 0.255, 0.08), hb + Vector3(-0.112, 0.34, 0.1), hb + Vector3(-0.122, 0.42, 0.115)],
			[0.0045, 0.0035, 0.0028], 6, HEAD, {"per": 3})
	lathe(acc[M_GREY], Transform3D(basis_y(Vector3(-0.15, 1.0, 0.2)), hb + Vector3(-0.096, 0.248, 0.078)),
			PackedVector2Array([Vector2(0.013, -0.006), Vector2(0.011, 0.014), Vector2(0.011, 0.014), Vector2(0.0, 0.014)]), 10, HEAD)
	_glow_box(acc, hb + Vector3(-0.122, 0.423, 0.115), Vector3(0.006, 0.006, 0.006), Color(1.0, 0.3, 0.2), HEAD)


static func _backpack(acc: Array) -> void:
	var shell: Surf = acc[M_SHELL]
	var z0 := 0.19
	# Main body (+ a dark mounting frame hidden between pack and back).
	rbox(shell, _xf(Vector3(0, 1.3, z0)), Vector3(0.17, 0.245, 0.088), 0.05, CHEST, {"seg": 0.05})
	rbox(acc[M_DARK], _xf(Vector3(0, 1.3, 0.112)), Vector3(0.11, 0.18, 0.016), 0.012, CHEST, {"bright": 1.2})
	# Service panel with vents and a display.
	rbox(acc[M_GREY], _xf(Vector3(0, 1.33, 0.272)), Vector3(0.115, 0.155, 0.012), 0.009, CHEST, {"bright": 1.0})
	for k in 4:
		rbox(acc[M_DARK], _xf(Vector3(0, 1.205 + k * 0.02, 0.2865)), Vector3(0.082, 0.0055, 0.004), 0.003, CHEST, {"bright": 0.7})
	rbox(acc[M_DARK], _xf(Vector3(0, 1.4, 0.2865)), Vector3(0.07, 0.03, 0.003), 0.003, CHEST, {"bright": 1.4})
	# Side vent grilles on the pack flanks.
	for sd in [-1.0, 1.0]:
		for k in 3:
			rbox(acc[M_DARK], _xf(Vector3(sd * 0.171, 1.44 + k * 0.022, 0.205)), Vector3(0.004, 0.006, 0.05), 0.003, CHEST, {"bright": 0.8})
	# Orange top cap and carry handle.
	rbox(acc[M_ORANGE], _xf(Vector3(0, 1.543, z0)), Vector3(0.124, 0.016, 0.066), 0.012, CHEST)
	for sd in [-1.0, 1.0]:
		rbox(acc[M_GREY], _xf(Vector3(sd * 0.06, 1.563, z0)), Vector3(0.01, 0.012, 0.012), 0.004, CHEST)
	sweep(acc[M_GREY], [Vector3(-0.06, 1.568, z0), Vector3(-0.04, 1.583, z0), Vector3(0.04, 1.583, z0), Vector3(0.06, 1.568, z0)],
			[0.007, 0.007, 0.007, 0.007], 8, CHEST, {"per": 4, "caps": true})
	# Side oxygen tanks.
	for sd in [-1.0, 1.0]:
		var c := Vector3(sd * 0.168, 1.285, 0.2)
		var tp := PackedVector2Array()
		var tr := 0.038
		for k in 6:
			var a := float(k) / 5.0 * PI * 0.5
			tp.append(Vector2(sin(a) * tr, -0.17 - cos(a) * tr * 0.6))
		for k in 6:
			var a2 := float(k) / 5.0 * PI * 0.5
			tp.append(Vector2(cos(a2) * tr, 0.17 + sin(a2) * tr * 0.6))
		lathe(shell, _xf(c), tp, 20, CHEST)
		lathe(acc[M_ORANGE], _xf(c), ring_prof(tr - 0.002, tr + 0.003, 0.08, 0.1, 0.002), 20, CHEST)
		lathe(acc[M_METAL], _xf(c), ring_prof(tr - 0.002, tr + 0.003, -0.13, -0.115, 0.002), 20, CHEST)
		lathe(acc[M_METAL], _xf(c + Vector3(0, 0.2, 0)), PackedVector2Array([Vector2(0.012, 0.0), Vector2(0.01, 0.03),
				Vector2(0.01, 0.03), Vector2(0.0, 0.03)]), 10, CHEST)
	# Thrusters: grey mount, metal bell with a dark throat.
	for np in NOZZLES:
		var c2: Vector3 = bone_global(CHEST) + (np as Vector3)
		lathe(acc[M_GREY], _xf(c2), PackedVector2Array([Vector2(0.034, 0.03), Vector2(0.04, 0.068), Vector2(0.04, 0.068),
				Vector2(0.0, 0.068)]), 18, CHEST, {"bright": 0.8})
		lathe(acc[M_DARK], _xf(c2), PackedVector2Array([Vector2(0.0, 0.036), Vector2(0.019, 0.034), Vector2(0.03, 0.0)]), 18, CHEST,
				{"bright": 0.5})
		lathe(acc[M_METAL], _xf(c2), PackedVector2Array([Vector2(0.03, 0.0), Vector2(0.034, 0.0), Vector2(0.034, 0.0),
				Vector2(0.026, 0.042)]), 18, CHEST)
	# Antenna.
	sweep(acc[M_METAL], [Vector3(0.12, 1.55, 0.235), Vector3(0.125, 1.62, 0.24), Vector3(0.13, 1.69, 0.245)],
			[0.004, 0.0032, 0.0026], 6, CHEST, {"per": 3})
	_glow_box(acc, Vector3(0.13, 1.692, 0.245), Vector3(0.005, 0.005, 0.005), Color(0.3, 1.0, 0.45), CHEST)
