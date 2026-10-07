extends RefCounted
## Combat areas ("Haritaya çatışma alanları", 2026-10-06): Balance.POI_COUNT points of interest per
## planet, deterministic from the planet seed (fixed presets and random worlds alike), so every
## machine builds the same ones. The planets were bare grey soil; now there is cover to fight over.
##
## Kinds (KIND_*, a varied mix per planet; outpost and crash site on every planet):
##   mesa      rock pillars 3-6 m tall with lanes between them, a leaning slab, boulders
##   trench    a zig-zag trench 1.8 m deep with a firing step along the front wall (the side away
##             from the base), ramps at both ends, the spoil raised beside it as berms, barriers
##   tunnel    a terrain-following hill, 2-3 arched tunnels (floor ~2.2 m wide, ceiling 2.65 m) bending into a
##             domed chamber (ceiling 3.2 m), portal frames at the mouths, a lamp inside
##   outpost   a levelled pad with a ruined prefab bunker, broken wall segments, crates, a fallen
##             antenna and a tall comm tower with a blinking red beacon (LANDMARK)
##   crash     a half-buried hull at the end of its furrow (spoil berms, a mound over the nose), a
##             tall tail fin with an amber beacon (LANDMARK), its engine, a wing, glowing debris, smoke
##   ridge     a long rocky ridge (long sightlines from its crest), raised-rim craters beside it and,
##             when the LOD band leaves room, a rock arch at its end (LANDMARK)
## Placement: the first three areas (outpost, crash and one more) sit in a band just outside the
## base's clear zone (where raiders land and fights happen), the outpost and crash on the side that
## faces the other planet so their beacons show from there; the rest go to the far side. No area
## comes closer than max(POI_BASE_CLEAR_K x radius, POI_BASE_CLEAR_MIN) to a base centre (spawn,
## build area, drop pods, the dropship landing rings): the spawn area stays untouched.
##
## Terrain: every shape is density, a signed-distance stamp (smooth union / subtraction) written
## straight into planet.edits at world build, before the first chunk is meshed. So the CPU density,
## the GPU meshing (edits merge over it), the bots' movement / line of sight / cover search (they read
## the density), saves and multiplayer all see ordinary terrain edits. Added solid is capped
## CEIL_MARGIN m under the planet's LOD band top (radius + max_height).
## Multiplayer: BOTH machines stamp the same edits locally; planet.net_hook is bypassed (nothing goes
## out as ops). The join snapshot (net_terrain.gd, sent on every client world build) then replaces the
## client's edit grid with the host's, which already holds the identical POI regions, so a late join /
## rejoin / restart stays consistent. Drift checks only hash regions touched by ops: never these.
## Props (meshes, collision on Game.LAYER_SHIP, beacons, smoke) spawn on every machine from the same
## seed, never synced (poi_props.gd). Walls, hulls, crates and the tower register Node3Ds in group
## "poi_obstacle" (meta "footprint_r") that the bots' crowd separation pushes them out of.
##
## Cost: the stamping runs on worker threads (one per planet, main.gd waits): a few hundred ms at
## world build, nothing afterwards (the beacons blink in their shader).
##
##   Poi.build_world(main)              main.gd, after both planets exist (main.spawn_transform: bases)
##   Poi.plan(planet, base_dir, other_dir) -> Array of sites, ops not applied (tests)
##   Poi.sites_of(planet) -> Array      built sites: {kind, kind_id, name, dir, frame (body-local,
##                                      origin on the ground, y up), fp (footprint m), data, ...}
##   Poi.last_stats                     {"sites", "ops", "voxels", "written", "regions", "plan_ms",
##                                      "stamp_ms", "props_ms"} of the last build (probes)

const Bodies := preload("res://scripts/planet/bodies.gd")
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const Planet := preload("res://scripts/planet/planet.gd")
const Balance := preload("res://scripts/war/balance.gd")
const Props := preload("res://scripts/planet/poi_props.gd")

const KIND_MESA := 0
const KIND_TRENCH := 1
const KIND_TUNNEL := 2
const KIND_OUTPOST := 3
const KIND_CRASH := 4
const KIND_RIDGE := 5
const KIND_IDS := ["mesa", "trench", "tunnel", "outpost", "crash", "ridge"]
const KIND_NAMES := ["Kaya Kümesi", "Siper Hattı", "Tünel Tepesi", "Harap Karakol", "Enkaz Alanı", "Krater Sırtı"]
## Footprint radius (m) per kind: spacing, the base clear zone test.
const FOOT := [12.0, 14.0, 14.0, 12.5, 15.0, 19.0]
## Height (m) a kind needs between the ground and the LOD band ceiling (its tall terrain shapes).
const ROOM := [3.5, 0.0, 5.0, 0.0, 2.5, 3.0]

# Density stamp shapes (Job._sdf), in the op's local frame (y up).
const SH_PILLAR := 0          # tapered elliptic rock pillar with ledges
const SH_SEG := 1             # a segment along local z (P_* profiles), its floor rising dy over L
const SH_ELLIPSOID := 2       # optional flat floor (domes)
const SH_TORUS_V := 3         # ring in the local xy-plane (an arch)
const SH_TORUS_H := 4         # ring in the xz-plane (a crater rim)
const SH_FRUSTUM := 5         # a flat pad with 45° sides going down
const SH_CUTCONE := 6         # ...and the cut above it, widening upward
const SH_RBOX := 7            # rounded box
const SH_BUMP := 8            # terrain-following hill: the ground raised by a rounded cone (h, slope s, round c)
const P_BOX := 0.0
const P_ARCH := 1.0
const P_CAPS := 2.0
const P_RIDGE := 3.0          # a walkable ridge: rounded crest, sides of slope s, conical ends
const BAND := 1.0             # m: voxels farther outside a shape (+ its blend + noise) are left alone
const CEIL_MARGIN := 2.5      # m under radius + max_height: added solid stops here
const DETAIL_AMP := 1.4       # m: bound of terrain_gen's detail noise (±1.3)
const SKIP_LIM := 2.0         # m: a voxel whose value stays beyond ± this (+ k / 4) is not written
const NO_FLOOR := -1.0e6

static var last_stats := {}
static var _sites := {}       # planet instance id -> Array of sites


## Main entry (main.gd): plans, stamps and decorates the combat areas of every planet. `main`
## provides spawn_transform(body, other, lift) (the bases).
static func build_world(main: Object) -> void:
	if not Balance.POI_ENABLED or main == null:
		return
	var t0 := Time.get_ticks_usec()
	var planets: Array = []
	for b in Bodies.all():
		if is_instance_valid(b) and b.get("gen") != null:
			planets.append(b)
	var jobs: Array = []
	for pl: Node3D in planets:
		var other: Node3D = null
		for o: Node3D in planets:
			if o != pl:
				other = o
		var c: Vector3 = pl.global_position
		var bxf: Transform3D = main.spawn_transform(pl, other, 0.0)
		var bdir := (bxf.origin - c).normalized()
		var odir := (other.global_position - c).normalized() if other != null else bdir
		var sites := plan(pl, bdir, odir)
		_sites[pl.get_instance_id()] = sites
		jobs.append(make_job(pl, sites))
	var t1 := Time.get_ticks_usec()
	# One worker per planet: each job only touches its own planet's edit grid and generator, and
	# nothing else runs on them meanwhile (the planets' first _process comes after main._ready).
	var tasks: Array = []
	for j: Job in jobs:
		tasks.append(WorkerThreadPool.add_task(j.run, true, "poi stamp"))
	for id: int in tasks:
		WorkerThreadPool.wait_for_task_completion(id)
	var t2 := Time.get_ticks_usec()
	var st := {"sites": 0, "ops": 0, "voxels": 0, "written": 0, "regions": 0, "shapes": 0}
	for i in planets.size():
		var pl: Node3D = planets[i]
		var job: Job = jobs[i]
		finish_job(pl, job)
		st["shapes"] += spawn_props(pl, _sites[pl.get_instance_id()])
		st["sites"] += (_sites[pl.get_instance_id()] as Array).size()
		st["ops"] += job.ops_n
		st["voxels"] += job.voxels
		st["written"] += job.written
		st["regions"] += job.regions.size()
	var t3 := Time.get_ticks_usec()
	st["plan_ms"] = (t1 - t0) / 1000.0
	st["stamp_ms"] = (t2 - t1) / 1000.0
	st["props_ms"] = (t3 - t2) / 1000.0
	last_stats = st


## The built sites of a planet (see the header), [] if none.
static func sites_of(pl: Node3D) -> Array:
	if pl == null or not is_instance_valid(pl):
		return []
	return _sites.get(pl.get_instance_id(), [])


## The site whose footprint contains a world position on `pl`, or {}.
static func site_at(pl: Node3D, world: Vector3) -> Dictionary:
	var rel := world - pl.global_position
	if rel.length_squared() < 1.0:
		return {}
	var d := rel.normalized()
	for s: Dictionary in sites_of(pl):
		if acos(clampf(d.dot(s["dir"]), -1.0, 1.0)) * float(pl.radius) < float(s["fp"]):
			return s
	return {}


# =================================================================================================
# Planning (main thread): sites, then each site's density ops and prop layout
# =================================================================================================

## Sites of one planet: kinds, directions, frames, ops (not applied). base_dir / other_dir: unit
## directions from the planet centre to its base and to the other planet.
static func plan(pl: Node3D, base_dir: Vector3, other_dir: Vector3) -> Array:
	var r: float = pl.radius
	var rng := RandomNumberGenerator.new()
	rng.seed = int(pl.seed_value) * 7919 + 104729
	var clear: float = maxf(Balance.POI_BASE_CLEAR_K * r, Balance.POI_BASE_CLEAR_MIN)
	var ceil_r: float = r + float(pl.max_height) - CEIL_MARGIN
	var cnt: Vector2i = Balance.POI_COUNT
	var n: int = rng.randi_range(cnt.x, cnt.y)
	var rest: Array = [KIND_TUNNEL, KIND_TRENCH, KIND_MESA, KIND_RIDGE]
	for i in range(rest.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = rest[i]
		rest[i] = rest[j]
		rest[j] = t
	var kinds: Array = [KIND_OUTPOST, KIND_CRASH]
	kinds.append_array(rest)
	var extra: int = [KIND_MESA, KIND_TRENCH, KIND_RIDGE][rng.randi_range(0, 2)]
	while kinds.size() > n:
		kinds.pop_back()
	while kinds.size() < n:
		kinds.append(extra)
	var sites: Array = []
	for i in kinds.size():
		var kind: int = kinds[i]
		var near := i < 3
		var s := _place_site(pl, rng, kind, near, base_dir, other_dir, clear, ceil_r, sites)
		if s.is_empty() and kind == KIND_TUNNEL:
			# No room for the hill anywhere suitable: a trench needs none.
			s = _place_site(pl, rng, KIND_TRENCH, near, base_dir, other_dir, clear, ceil_r, sites)
		if not s.is_empty():
			s["index"] = sites.size()
			sites.append(s)
	return sites


## A shaped site of `kind` (see _shape_site), {} if none fits: outside the base's clear zone, in the
## near band or on the far side, landmarks facing the other planet, spaced from the sites so far,
## with height room under the LOD band for tall shapes, flat enough for the outpost pad. Candidates
## pass a quick test with the kind's nominal FOOT first; then the site is shaped and its real extent
## (the ops' bounds, "fp") must clear the base zone and the other sites.
static func _place_site(pl: Node3D, rng: RandomNumberGenerator, kind: int, near: bool, b: Vector3, o: Vector3,
		clear: float, ceil_r: float, sites: Array) -> Dictionary:
	var r: float = pl.radius
	var fp: float = FOOT[kind]
	var band: float = Balance.POI_NEAR_BAND
	var far_min: float = Balance.POI_FAR_MIN * r
	var cone: float = Balance.POI_LANDMARK_CONE
	var gap: float = Balance.POI_GAP
	var shaped := 0
	for t in 600:
		var z := rng.randf_range(-1.0, 1.0)
		var ph := rng.randf() * TAU
		var sxy := sqrt(maxf(1.0 - z * z, 0.0))
		var d := Vector3(sxy * cos(ph), z, sxy * sin(ph))
		var arc_b := acos(clampf(d.dot(b), -1.0, 1.0)) * r
		if arc_b < clear + fp:
			continue
		if near and arc_b > clear + fp + band:
			continue
		if not near and arc_b < far_min:
			continue
		if (kind == KIND_OUTPOST or kind == KIND_CRASH) and acos(clampf(d.dot(o), -1.0, 1.0)) > cone:
			continue
		if not _spaced(d, fp, sites, r, gap):
			continue
		if ROOM[kind] > 0.0 and ceil_r - (r + float(pl.gen.surface_height(d)) + 1.3) < ROOM[kind]:
			continue
		if (kind == KIND_OUTPOST or kind == KIND_TUNNEL) and not _flat_enough(pl, d, 8.0, 2.6):
			continue
		var s := {"kind": kind, "dir": d, "fp": fp, "near": near, "seed": rng.randi(), "index": sites.size(),
				"kind_id": KIND_IDS[kind], "name": KIND_NAMES[kind]}
		_shape_site(pl, s, b, ceil_r)
		var ext := _extent(s, r)
		s["fp"] = ext
		shaped += 1
		if arc_b >= clear + ext and _spaced(d, ext, sites, r, gap):
			return s
		if shaped >= 30:
			break
	return {}


static func _spaced(d: Vector3, fp: float, sites: Array, r: float, gap: float) -> bool:
	for s: Dictionary in sites:
		if acos(clampf(d.dot(s["dir"]), -1.0, 1.0)) * r < fp + float(s["fp"]) + gap:
			return false
	return true


## Real footprint (m of surface arc from the site centre) of a shaped site: the farthest corner of
## any op's bounds, plus its blend and noise.
static func _extent(s: Dictionary, r: float) -> float:
	var d: Vector3 = s["dir"]
	var ext := 0.0
	for op: Dictionary in s["ops"]:
		var xf: Transform3D = op["xf"]
		var lb: AABB = op["lb"]
		var grow: float = float(op["k"]) + float(op["amp"])
		for i in 8:
			var w := (xf * lb.get_endpoint(i)).normalized()
			ext = maxf(ext, acos(clampf(w.dot(d), -1.0, 1.0)) * r + grow)
	return ext


static func _flat_enough(pl: Node3D, d: Vector3, rad: float, tol: float) -> bool:
	var t1 := d.cross(Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).normalized()
	var t2 := d.cross(t1)
	var r: float = pl.radius
	var lo := INF
	var hi := -INF
	for v: Vector3 in [Vector3.ZERO, t1, -t1, t2, -t2]:
		var g: float = pl.gen.surface_height((d * r + v * rad).normalized())
		lo = minf(lo, g)
		hi = maxf(hi, g)
	return hi - lo < tol


## Frame (body-local, origin on the true ground, y up) and the kind's ops + prop layout.
static func _shape_site(pl: Node3D, s: Dictionary, base_dir: Vector3, ceil_r: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(s["seed"])
	var up: Vector3 = s["dir"]
	var tb := base_dir - up * base_dir.dot(up)
	if tb.length_squared() < 1e-6:
		tb = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	tb = tb.normalized()
	var kind: int = s["kind"]
	# Trenches face away from the base (frame z toward it, the front is -z); the rest turn at random.
	var ez := tb if kind == KIND_TRENCH else tb.rotated(up, rng.randf() * TAU)
	var ex := up.cross(ez)
	s["frame"] = Transform3D(Basis(ex, up, ez), up * ground_r(pl, up))
	s["ops"] = []
	s["data"] = {}
	match kind:
		KIND_MESA:
			_mesa(pl, s, rng, ceil_r)
		KIND_TRENCH:
			_trench(pl, s, rng)
		KIND_TUNNEL:
			_tunnel(pl, s, rng, ceil_r)
		KIND_OUTPOST:
			_outpost(pl, s, rng)
		KIND_CRASH:
			_crash(pl, s, rng)
		KIND_RIDGE:
			_ridge(pl, s, rng, ceil_r)


static func _op(shape: int, xf: Transform3D, lb: AABB, prm: Array, add: bool, k: float, amp := 0.0) -> Dictionary:
	return {"shape": shape, "xf": xf, "lb": lb, "prm": PackedFloat32Array(prm), "add": add, "k": k, "amp": amp}


## A terrain-following hill at xf (origin on the ground): the ground raised by a rounded cone of
## height h, flank slope sl, crest round c, its foot eased over ± toe m.
static func _bump_op(xf: Transform3D, h: float, sl: float, c: float, toe: float, amp: float) -> Dictionary:
	var rr := sqrt(pow((h + toe) / sl + c, 2.0) - c * c)
	return _op(SH_BUMP, xf, AABB(Vector3(-rr, -8.0, -rr), Vector3(rr * 2.0, h + 14.0, rr * 2.0)), [h, sl, c, toe], true, toe, amp)


## Radius (body-local) of the unedited ground along a unit direction, detail noise included
## (surface_height leaves the ±1.3 m detail noise out): bisection of the generator density.
static func ground_r(pl: Node3D, dir: Vector3) -> float:
	var gen: TerrainGen = pl.gen
	var s: Vector4 = gen._surf(dir)
	var lo: float = float(pl.radius) + s.x - 2.0
	var hi: float = float(pl.radius) + s.x + 2.0
	for i in 14:
		var m := (lo + hi) * 0.5
		if gen._density(dir * m, m, s) < 0.0:
			lo = m
		else:
			hi = m
	return (lo + hi) * 0.5


## Ground frame under the site frame's local (x, z): the true unedited ground, radial up, x along
## the frame's x.
static func _anchor(pl: Node3D, f: Transform3D, x: float, z: float) -> Transform3D:
	var dir := (f * Vector3(x, 0.0, z)).normalized()
	var ex := f.basis.x - dir * f.basis.x.dot(dir)
	ex = ex.normalized()
	return Transform3D(Basis(ex, dir, ex.cross(dir)), dir * ground_r(pl, dir))


## A segment op frame: origin a, y = up, z along b - a in the plane under up. Returns
## [Transform3D, length, rise of b over a along up].
static func _seg(a: Vector3, b: Vector3, up: Vector3) -> Array:
	var d := b - a
	var dy := d.dot(up)
	var h := d - up * dy
	var l := maxf(h.length(), 0.01)
	var z := h / l
	return [Transform3D(Basis(up.cross(z), up, z), a), l, dy]


## Local bounds of a SH_SEG op: x within x0 ± w, y from ylo to yhi over the sheared floor, z past both ends by ext.
static func _seg_box(l: float, dy: float, x0: float, w: float, ylo: float, yhi: float, ext: float) -> AABB:
	var y0 := minf(0.0, dy) + ylo
	var y1 := maxf(0.0, dy) + yhi
	return AABB(Vector3(x0 - w, y0, -ext), Vector3(w * 2.0, y1 - y0, l + ext * 2.0))


# --- Kinds ---------------------------------------------------------------------------------------

static func _mesa(pl: Node3D, s: Dictionary, rng: RandomNumberGenerator, ceil_r: float) -> void:
	var f: Transform3D = s["frame"]
	var ops: Array = s["ops"]
	var pillars: Array = []                       # Vector3(x, z, radius)
	var want := rng.randi_range(4, 6)
	for t in 80:
		if pillars.size() >= want:
			break
		var pr := rng.randf_range(1.6, 2.8)
		var a := rng.randf() * TAU
		var c := Vector2(cos(a), sin(a)) * sqrt(rng.randf()) * 10.0
		var ok := true
		for q: Vector3 in pillars:
			# Lanes between the pillars: ~2.2-3.6 m at the foot (the fillets take a little).
			if c.distance_to(Vector2(q.x, q.y)) < pr + q.z + rng.randf_range(2.6, 4.0):
				ok = false
				break
		if ok:
			pillars.append(Vector3(c.x, c.y, pr))
	for q: Vector3 in pillars:
		var ax := _anchor(pl, f, q.x, q.y)
		ax.basis = ax.basis * Basis(Vector3.UP, rng.randf() * TAU)
		var mh: Vector2 = Balance.POI_MESA_H
		var top: float = minf(rng.randf_range(mh.x, mh.y), ceil_r - ax.origin.length() - 0.3)
		if top < 1.5:
			continue
		var pr: float = q.z
		var sx := rng.randf_range(0.8, 1.25)
		var sz := rng.randf_range(0.85, 1.15) / sx
		var e := pr * maxf(sx, sz) + 0.6
		ops.append(_op(SH_PILLAR, ax, AABB(Vector3(-e, -3.0, -e), Vector3(e * 2.0, top + 3.0, e * 2.0)),
				[pr, pr * rng.randf_range(0.7, 0.88), top, -3.0, sx, sz, rng.randf_range(0.12, 0.28), rng.randf() * TAU],
				true, 1.1, 0.45))
	# A slab leaning across the two closest pillars: a low wall between them.
	if pillars.size() >= 2:
		var bi := 0
		var bj := 1
		var bd := INF
		for i in pillars.size():
			for j in range(i + 1, pillars.size()):
				var dd := Vector2(pillars[i].x, pillars[i].y).distance_to(Vector2(pillars[j].x, pillars[j].y))
				if dd < bd:
					bd = dd
					bi = i
					bj = j
		var pa := Vector2(pillars[bi].x, pillars[bi].y)
		var pb := Vector2(pillars[bj].x, pillars[bj].y)
		var mid := (pa + pb) * 0.5
		var ax := _anchor(pl, f, mid.x, mid.y)
		var dir2 := (pb - pa).normalized()
		ax.basis = ax.basis * Basis(Vector3.UP, atan2(-dir2.y, dir2.x)) * Basis(Vector3.RIGHT, rng.randf_range(0.25, 0.45))
		ax.origin += ax.basis.y * 0.55
		var hl := bd * 0.5 + 0.3
		ops.append(_op(SH_RBOX, ax, AABB(Vector3(-hl, -0.6, -1.0), Vector3(hl * 2.0, 1.2, 2.0)), [hl, 0.45, 0.85, 0.25],
				true, 0.5, 0.25))
	# Boulders: low cover around the pillars.
	for i in rng.randi_range(3, 5):
		for t in 20:
			var a := rng.randf() * TAU
			var c := Vector2(cos(a), sin(a)) * rng.randf_range(3.0, 11.0)
			var ok := true
			for q: Vector3 in pillars:
				if c.distance_to(Vector2(q.x, q.y)) < q.z + 1.8:
					ok = false
					break
			if not ok:
				continue
			var ax := _anchor(pl, f, c.x, c.y)
			ax.basis = ax.basis * Basis(Vector3.UP, rng.randf() * TAU)
			var rad := Vector3(rng.randf_range(1.0, 1.6), rng.randf_range(0.7, 1.1), rng.randf_range(0.9, 1.4))
			ax.origin -= ax.basis.y * rad.y * 0.35
			ops.append(_op(SH_ELLIPSOID, ax, AABB(-rad, rad * 2.0), [rad.x, rad.y, rad.z, NO_FLOOR], true, 0.5, 0.25))
			break
	s["data"]["pillars"] = pillars


static func _trench(pl: Node3D, s: Dictionary, rng: RandomNumberGenerator) -> void:
	var f: Transform3D = s["frame"]
	var ops: Array = s["ops"]
	var nseg := 5
	var segl := rng.randf_range(5.0, 5.8)
	var ang := deg_to_rad(rng.randf_range(24.0, 34.0))
	var p := Vector2(-float(nseg) * segl * cos(ang) * 0.5, rng.randf_range(-1.0, 1.0))
	var pts: Array = [p]
	var flip := 1.0 if rng.randf() < 0.5 else -1.0
	for i in nseg:
		p += Vector2(cos(ang), sin(ang) * flip * (1.0 if i % 2 == 0 else -1.0)) * segl
		pts.append(p)
	var depth: float = Balance.POI_TRENCH_DEPTH
	var front := -f.basis.z
	var segs: Array = []                          # [A, B, up, x axis, front sign]
	for i in nseg:
		var a := _anchor(pl, f, pts[i].x, pts[i].y)
		var b := _anchor(pl, f, pts[i + 1].x, pts[i + 1].y)
		var sg := _seg(a.origin, b.origin, a.basis.y)
		var xf: Transform3D = sg[0]
		var sf := 1.0 if xf.basis.x.dot(front) > 0.0 else -1.0
		segs.append([a.origin, b.origin, a.basis.y, xf.basis.x, sf, sg])
	# Spoil berms first (the cuts below trim them clean): a parapet in front, a lower parados behind.
	for e: Array in segs:
		var sg: Array = e[5]
		var l: float = sg[1]
		var dy: float = sg[2]
		var sf: float = e[4]
		ops.append(_op(SH_SEG, sg[0], _seg_box(l, dy, sf * 2.75, 1.45, -0.8, 0.8, 1.35),
				[P_CAPS, l, dy, sf * 2.75, 0.0, 1.3, 0.5], true, 0.8, 0.15))
		ops.append(_op(SH_SEG, sg[0], _seg_box(l, dy, -sf * 2.1, 1.1, -0.6, 0.6, 1.1),
				[P_CAPS, l, dy, -sf * 2.1, 0.0, 1.0, 0.38], true, 0.7, 0.12))
	for i in nseg:
		var e: Array = segs[i]
		var sg: Array = e[5]
		var l: float = sg[1]
		var dy: float = sg[2]
		var sf: float = e[4]
		# The end segments ramp up to the ground (walk in / out); the rest are full depth.
		var fa: float = -0.15 if i == 0 else -depth
		var fb: float = -0.15 if i == nseg - 1 else -depth
		ops.append(_op(SH_SEG, sg[0], _seg_box(l, dy, 0.0, 0.8, -depth, 2.5, 0.8),
				[P_BOX, l, dy, 0.0, 0.8, fa, fb, 2.5, 0.3, 0.8], false, 0.3, 0.0))
		if i > 0 and i < nseg - 1:
			# Firing step along the front wall: stand on it and the eyes clear the parapet.
			var st: float = -depth + 1.05
			ops.append(_op(SH_SEG, sg[0], _seg_box(l, dy, sf * 1.4, 0.62, st, 2.5, 0.45),
					[P_BOX, l, dy, sf * 1.4, 0.6, st, st, 2.5, 0.15, 0.45], false, 0.2, 0.0))
	var dsegs: Array = []
	for e: Array in segs:
		dsegs.append([e[0], e[1], e[2], e[3], e[4]])
	s["data"]["segs"] = dsegs
	s["data"]["depth"] = depth


static func _tunnel(pl: Node3D, s: Dictionary, rng: RandomNumberGenerator, ceil_r: float) -> void:
	var f: Transform3D = s["frame"]
	var ops: Array = s["ops"]
	var up := f.basis.y
	var g0 := f.origin.length()
	# The hill: a rounded cone (~27° flanks, walkable), its top under the LOD band ceiling.
	var hill_top: float = minf(5.6, ceil_r - g0 - 0.3)
	ops.append(_bump_op(f, hill_top, 0.5, 3.0, 1.2, 0.45))
	# Tunnel directions first, so the side knolls go between the mouths.
	var n := rng.randi_range(2, 3)
	var a0 := rng.randf() * TAU
	var azs: Array = []
	for i in n:
		azs.append(a0 + TAU * float(i) / float(n) + rng.randf_range(-0.3, 0.3))
	for i in mini(n, 2):
		var a: float = (float(azs[i]) + float(azs[(i + 1) % n]) + (TAU if i == n - 1 else 0.0)) * 0.5
		var ax := _anchor(pl, f, cos(a) * 7.5, sin(a) * 7.5)
		var kh: float = minf(rng.randf_range(1.8, 2.6), ceil_r - ax.origin.length() - 0.3)
		if kh > 0.8:
			ops.append(_bump_op(ax, kh, 0.55, 2.0, 1.0, 0.4))
	# The chamber: a dome with a flat floor just under the old ground.
	var floor_r := g0 - 0.3
	var cr := Vector3(5.0, minf(3.2, hill_top - 2.2), 4.6)
	var cxf := f
	cxf.origin = up * floor_r
	ops.append(_op(SH_ELLIPSOID, cxf, AABB(Vector3(-cr.x, -0.5, -cr.z), Vector3(cr.x * 2.0, cr.y + 0.5, cr.z * 2.0)),
			[cr.x, cr.y, cr.z, 0.0], false, 0.35, 0.1))
	# Tunnels: chamber -> bend -> mouth past the hill's foot, arched, floor following the ground.
	var mouths: Array = []
	var tr: float = Balance.POI_TUNNEL_R
	var cy: float = tr - 0.45
	for i in n:
		var az: float = azs[i]
		var d2 := Vector2(cos(az), sin(az))
		var side := Vector2(-d2.y, d2.x)
		var q0 := d2 * 2.0
		var q1 := d2 * 6.5 + side * rng.randf_range(-1.4, 1.4)
		var q2 := d2 * 14.0
		var dir2 := (f * Vector3(q2.x, 0.0, q2.y)).normalized()
		var r2 := ground_r(pl, dir2) - 0.25
		var dir0 := (f * Vector3(q0.x, 0.0, q0.y)).normalized()
		var dir1 := (f * Vector3(q1.x, 0.0, q1.y)).normalized()
		# (the floor follows the lie of the land, like the hill over it)
		var r1 := ground_r(pl, dir1) - 0.3
		var p0 := dir0 * minf(ground_r(pl, dir0) - 0.3, floor_r + 0.3)
		var p1 := dir1 * r1
		var p2 := dir2 * r2
		for pair: Array in [[p0, p1], [p1, p2]]:
			var sg := _seg(pair[0], pair[1], (pair[0] as Vector3).normalized())
			var l: float = sg[1]
			var dy: float = sg[2]
			ops.append(_op(SH_SEG, sg[0], _seg_box(l, dy, 0.0, tr + 0.2, -0.3, cy + tr + 0.3, 0.7),
					[P_ARCH, l, dy, cy, tr, 0.7], false, 0.25, 0.08))
		mouths.append([p2, p1])
	s["data"]["mouths"] = mouths
	s["data"]["chamber"] = up * floor_r
	s["data"]["chamber_h"] = cr.y


static func _outpost(pl: Node3D, s: Dictionary, rng: RandomNumberGenerator) -> void:
	var f: Transform3D = s["frame"]
	var ops: Array = s["ops"]
	var rp := 9.0
	var top := 0.3
	# A levelled pad: fill below (45° sides) and cut above (45° bank) the pad plane.
	ops.append(_op(SH_FRUSTUM, f, AABB(Vector3(-rp - 5.0, -5.0, -rp - 5.0), Vector3(rp * 2.0 + 10.0, 5.0 + top, rp * 2.0 + 10.0)),
			[rp, top, 1.0], true, 0.9, 0.0))
	ops.append(_op(SH_CUTCONE, f, AABB(Vector3(-rp - 5.0, top, -rp - 5.0), Vector3(rp * 2.0 + 10.0, 5.0, rp * 2.0 + 10.0)),
			[rp, top, 1.0], false, 0.9, 0.0))
	# Layout on the pad (site frame, pad plane y = top).
	var ab := rng.randf() * TAU
	var bunker := Vector2(cos(ab), sin(ab)) * 3.4
	var at := ab + rng.randf_range(1.9, 2.6) * (1.0 if rng.randf() < 0.5 else -1.0)
	var tower := Vector2(cos(at), sin(at)) * 4.8
	# The fallen antenna lies outward through the gap left by the bunker and the tower.
	var free := -(Vector2(cos(ab), sin(ab)) + Vector2(cos(at), sin(at)))
	var walls: Array = []
	var nw := 5
	var w0 := rng.randf() * TAU
	for i in nw:
		var span := rng.randf_range(3.6, 4.6) / 7.6
		var a := w0 + TAU * float(i) / float(nw) + rng.randf_range(-0.12, 0.12)
		var wa := Vector2(cos(a), sin(a)) * 7.6
		var wb := Vector2(cos(a + span), sin(a + span)) * 7.6
		walls.append([wa, wb])
		# Drifted soil along the wall's outer foot: the bots' density sees a low berm there.
		var mid := (wa + wb) * 0.5
		var out := mid.normalized()
		var pa := f * Vector3(wa.x + out.x * 0.55, top, wa.y + out.y * 0.55)
		var pb := f * Vector3(wb.x + out.x * 0.55, top, wb.y + out.y * 0.55)
		var sg := _seg(pa, pb, f.basis.y)
		ops.append(_op(SH_SEG, sg[0], _seg_box(sg[1], sg[2], 0.0, 1.1, -0.7, 0.7, 1.0),
				[P_CAPS, sg[1], sg[2], 0.0, 0.0, 0.9, 0.6], true, 0.5, 0.12))
	var d: Dictionary = s["data"]
	d["pad_top"] = top
	d["pad_r"] = rp
	d["bunker"] = bunker
	d["bunker_yaw"] = atan2(bunker.x, bunker.y) + PI        # its door (+z) toward the pad centre
	d["tower"] = tower
	d["tower_yaw"] = atan2(tower.y, -tower.x)                # its cabinet (+x) toward the pad centre
	d["antenna"] = atan2(free.y, free.x)
	d["walls"] = walls
	d["landmark"] = "tower"


static func _crash(pl: Node3D, s: Dictionary, rng: RandomNumberGenerator) -> void:
	var f: Transform3D = s["frame"]
	var ops: Array = s["ops"]
	# The hull (site-local): nose (+z) down into a mound, rolled onto its wingless side, its torn tail
	# resting in the end of the furrow it ploughed (behind, -z).
	var pitch := deg_to_rad(rng.randf_range(8.0, 11.0))
	var roll := deg_to_rad(rng.randf_range(12.0, 22.0))
	var hull := Transform3D(Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll), Vector3(0.0, 0.0, 0.0))
	# Berms of thrown soil on both sides of the furrow.
	for sx: float in [-1.0, 1.0]:
		var a := _anchor(pl, f, sx * 3.5, -19.5)
		var b := _anchor(pl, f, sx * 3.7, -5.0)
		var sg := _seg(a.origin, b.origin, a.basis.y)
		ops.append(_op(SH_SEG, sg[0], _seg_box(sg[1], sg[2], 0.0, 1.5, -0.8, 0.8, 1.4),
				[P_CAPS, sg[1], sg[2], 0.0, 0.0, 1.3, 0.55], true, 0.9, 0.25))
	# The furrow: shallow and narrow far back, deep and wide where the hull stopped.
	for e: Array in [[-21.0, -11.5, 1.6, 0.55], [-12.5, -4.5, 2.4, 0.55]]:
		var a := _anchor(pl, f, 0.0, e[0])
		var b := _anchor(pl, f, 0.0, e[1])
		var sg := _seg(a.origin, b.origin, a.basis.y)
		var rr: float = e[2]
		ops.append(_op(SH_SEG, sg[0], _seg_box(sg[1], sg[2], 0.0, rr + 0.2, -rr, rr, rr + 0.2),
				[P_CAPS, sg[1], sg[2], 0.0, 0.0, rr, e[3]], false, 0.7, 0.18))
	# Soil heaped over the buried nose.
	var m := _anchor(pl, f, 0.0, 9.0)
	var mr := Vector3(5.2, 3.0, 4.2)
	m.origin -= m.basis.y * 0.9
	ops.append(_op(SH_ELLIPSOID, m, AABB(-mr, mr * 2.0), [mr.x, mr.y, mr.z, NO_FLOOR], true, 1.5, 0.35))
	# A soil core inside the hull (well under its skin): far-off bots path around it and cannot see
	# through it (their line of sight there is the density).
	var core := Vector3(1.3, 1.1, 5.0)
	ops.append(_op(SH_ELLIPSOID, f * hull * Transform3D(Basis(), Vector3(0.0, 0.0, 1.5)), AABB(-core, core * 2.0),
			[core.x, core.y, core.z, NO_FLOOR], true, 0.3, 0.0))
	var d: Dictionary = s["data"]
	d["hull"] = hull
	d["landmark"] = "fin"


static func _ridge(pl: Node3D, s: Dictionary, rng: RandomNumberGenerator, ceil_r: float) -> void:
	var f: Transform3D = s["frame"]
	var ops: Array = s["ops"]
	var crest := rng.randf_range(2.6, 3.6)
	var ph := rng.randf() * TAU
	var amp := rng.randf_range(1.5, 3.2)
	var pts: Array = []
	for i in 5:
		var z := -11.5 + 4.25 * float(i)
		pts.append(Vector2(sin(ph + z * 0.17) * amp, z))
	# Flanks of slope 0.62 (~32°, walkable), a rounded crest, conical ends where the segments meet.
	var sl := 0.62
	var rr := 4.4
	for i in 4:
		var a := _anchor(pl, f, pts[i].x, pts[i].y)
		var b := _anchor(pl, f, pts[i + 1].x, pts[i + 1].y)
		var h: float = minf(crest, ceil_r - maxf(a.origin.length(), b.origin.length()) - 0.3)
		if h < 1.2:
			continue
		var w := (h + 1.5) / sl + 1.5
		var sg := _seg(a.origin, b.origin, a.basis.y)
		ops.append(_op(SH_SEG, sg[0], _seg_box(sg[1], sg[2], 0.0, w, -1.5, h + 0.5, w),
				[P_RIDGE, sg[1], sg[2], 0.0, h, sl, 1.5], true, 1.2, 0.6))
	# Raised-rim craters beside the ridge: rims first, then the bowls cut their inner half.
	var nc := rng.randi_range(2, 3)
	var craters: Array = []
	for i in nc:
		var cr := rng.randf_range(3.5, 5.0)
		var side := 1.0 if i % 2 == 0 else -1.0
		var z := rng.randf_range(-10.0, 4.0)
		var x := sin(ph + z * 0.17) * amp + side * (rr + cr + rng.randf_range(0.6, 2.0))
		var ok := true
		for c: Vector3 in craters:
			if Vector2(x, z).distance_to(Vector2(c.x, c.y)) < cr + c.z + 1.0:
				ok = false
		if not ok:
			continue
		craters.append(Vector3(x, z, cr))
	for c: Vector3 in craters:
		var ax := _anchor(pl, f, c.x, c.y)
		var cr: float = c.z
		ops.append(_op(SH_TORUS_H, ax, AABB(Vector3(-cr - 1.0, -0.7, -cr - 1.0), Vector3(cr * 2.0 + 2.0, 1.4, cr * 2.0 + 2.0)),
				[cr, 0.95, 0.6], true, 0.7, 0.25))
	for c: Vector3 in craters:
		var ax := _anchor(pl, f, c.x, c.y)
		var cr: float = c.z - 0.2
		var dep := rng.randf_range(1.6, 2.2)
		ax.origin += ax.basis.y * 0.15
		ops.append(_op(SH_ELLIPSOID, ax, AABB(Vector3(-cr, -dep, -cr), Vector3(cr * 2.0, dep * 2.0, cr * 2.0)),
				[cr, dep, cr, NO_FLOOR], false, 0.7, 0.2))
	# A rock arch closing the ridge's far end (its span along the ridge, the opening across it).
	var end := _anchor(pl, f, pts[4].x, pts[4].y)
	var dir3: Vector3 = (f * Vector3(pts[4].x - pts[3].x, 0.0, pts[4].y - pts[3].y)) - f.origin
	var ar := 4.2
	var at := 1.1
	var arch := false
	if ceil_r - end.origin.length() - 0.3 >= ar + at - 0.5:
		var up := end.basis.y
		var xa := (dir3 - up * dir3.dot(up)).normalized()
		var c := end.origin + xa * (ar + 3.5) - up * 0.5
		var xf := Transform3D(Basis(xa, up, xa.cross(up)), c)
		ops.append(_op(SH_TORUS_V, xf, AABB(Vector3(-ar - at, -ar - at, -at), Vector3((ar + at) * 2.0, (ar + at) * 2.0, at * 2.0)),
				[ar, at], true, 1.0, 0.2))
		arch = true
	s["data"]["arch"] = arch
	if arch:
		s["data"]["landmark"] = "arch"


# =================================================================================================
# Stamping (worker threads)
# =================================================================================================

static func make_job(pl: Node3D, sites: Array) -> Job:
	var j := Job.new()
	j.edits = pl.edits
	j.gen = pl.gen
	j.radius = pl.radius
	j.q = maxf(float(pl.radius), 8.0)
	j.ceil_r = float(pl.radius) + float(pl.max_height) - CEIL_MARGIN
	j.sites = sites
	j.noise.seed = int(pl.seed_value) + 77
	j.noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	j.noise.frequency = 0.32
	j.noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	j.noise.fractal_octaves = 2
	return j


## After the stamp (main thread): re-mesh whatever chunk already exists over the stamped boxes.
static func finish_job(pl: Node3D, job: Job) -> void:
	for box: Array in job.boxes:
		if (box[0] as Vector3i).x <= (box[1] as Vector3i).x:
			pl._mark_dirty(box[0] - Vector3i.ONE, box[1] + Vector3i.ONE)
	pl.set("_last_edit_usec", Time.get_ticks_usec())


## Props of every site (main thread, after the stamp). Returns the collision shape count.
static func spawn_props(pl: Node3D, sites: Array) -> int:
	if sites.is_empty():
		return 0
	var root := Node3D.new()
	root.name = "CombatAreas"
	pl.add_child(root)
	var n := 0
	for s: Dictionary in sites:
		var node := Node3D.new()
		node.name = "Poi%d_%s" % [int(s["index"]), str(s["kind_id"])]
		node.transform = s["frame"]
		node.set_meta("poi_kind", s["kind_id"])
		node.set_meta("poi_name", s["name"])
		root.add_child(node)
		n += Props.build(pl, s, node)
	return n


class Job:
	var edits: Dictionary
	var gen: TerrainGen
	var radius := 60.0
	var ceil_r := 70.0
	var q := 60.0
	var noise := FastNoiseLite.new()
	var sites: Array = []
	var surf := {}                     # direction cell -> generator surface sample (_surf)
	var boxes: Array = []              # per site: [lo, hi] voxel box it touched
	var regions := {}                  # edit regions written
	var ops_n := 0
	var voxels := 0
	var written := 0
	var usec := 0
	var _lo := Vector3i.ZERO
	var _hi := Vector3i.ZERO

	func run() -> void:
		var t0 := Time.get_ticks_usec()
		for s: Dictionary in sites:
			_lo = Vector3i(1 << 30, 1 << 30, 1 << 30)
			_hi = -_lo
			for op: Dictionary in s["ops"]:
				_stamp(op)
				ops_n += 1
			boxes.append([_lo, _hi])
		usec = Time.get_ticks_usec() - t0

	## Generator surface sample (_surf) for body-local p (rr = |p|), cached per ~1 m direction cell
	## (the detail noise stays per voxel, terrain_gen _density).
	func _surf_of(p: Vector3, rr: float) -> Vector4:
		if rr < 1.0:
			return Vector4.ZERO
		var k := Vector3i((p / rr * q).round())
		var s = surf.get(k)
		if s == null:
			s = gen._surf((Vector3(k) / q).normalized())
			surf[k] = s
		return s

	## One op into the edit grid, region by region: smooth union (add) or subtraction of its shape.
	func _stamp(op: Dictionary) -> void:
		var xf: Transform3D = op["xf"]
		var xi := xf.affine_inverse()
		var shape: int = op["shape"]
		var prm: PackedFloat32Array = op["prm"]
		var add: bool = op["add"]
		var k: float = op["k"]
		var amp: float = op["amp"]
		var band := BAND + k
		var deep := -Planet.EDIT_CLAMP - k
		var lb: AABB = (op["lb"] as AABB).grow(band + amp)
		var box: AABB = xf * lb
		var lo := Vector3i(box.position.floor())
		var hi := Vector3i(box.end.ceil())
		var dx := xi.basis.x
		var lmin := lb.position
		var lmax := lb.end
		for kz in range(lo.z >> 4, (hi.z >> 4) + 1):
			var z0 := maxi(lo.z, kz << 4)
			var z1 := mini(hi.z, (kz << 4) + 15)
			for ky in range(lo.y >> 4, (hi.y >> 4) + 1):
				var y0 := maxi(lo.y, ky << 4)
				var y1 := mini(hi.y, (ky << 4) + 15)
				for kx in range(lo.x >> 4, (hi.x >> 4) + 1):
					var x0 := maxi(lo.x, kx << 4)
					var x1 := mini(hi.x, (kx << 4) + 15)
					var key := Vector3i(kx, ky, kz)
					var arr: PackedFloat32Array
					if edits.has(key):
						arr = edits[key]
					else:
						arr = PackedFloat32Array()
						arr.resize(4096)
						arr.fill(TerrainGen.NO_EDIT)
					var changed := false
					for z in range(z0, z1 + 1):
						for y in range(y0, y1 + 1):
							var lq := xi * Vector3(x0, y, z)
							# Only the run of this voxel row inside the op's (rotated) local box.
							var ta := 0.0
							var tb := float(x1 - x0)
							for i in 3:
								if absf(dx[i]) < 1e-9:
									if lq[i] < lmin[i] or lq[i] > lmax[i]:
										tb = -1.0
									continue
								var u0: float = (lmin[i] - lq[i]) / dx[i]
								var u1: float = (lmax[i] - lq[i]) / dx[i]
								ta = maxf(ta, minf(u0, u1))
								tb = minf(tb, maxf(u0, u1))
							if tb < ta:
								continue
							var xs := x0 + int(ceilf(ta))
							var xe := x0 + int(floorf(tb))
							lq += dx * float(xs - x0)
							for x in range(xs, xe + 1):
								var d := _sdf(shape, lq, prm)
								lq += dx
								voxels += 1
								if shape == SH_BUMP:
									if _bump(x, y, z, -d, amp, k, arr):
										changed = true
									continue
								if d > band + amp:
									continue
								var p := Vector3(x, y, z)
								if amp > 0.0:
									d += noise.get_noise_3dv(p) * amp
									if d > band:
										continue
								var rr := p.length()
								if add:
									d = maxf(d, rr - ceil_r)
								var li := (x & 15) | ((y & 15) << 4) | ((z & 15) << 8)
								# Bounds of the current value: exact where already edited, else the
								# height field ± the detail noise (no per-voxel noise yet). Voxels that
								# stay well inside the air or the rock whatever the shape does are left
								# alone (they never touch the mesh).
								var cur: float = arr[li]
								var edited := cur < TerrainGen.NO_EDIT * 0.5
								var sv := Vector4.ZERO
								var c_lo := cur
								var c_hi := cur
								if not edited:
									sv = _surf_of(p, rr)
									var ca := rr - radius - sv.x
									c_lo = ca - DETAIL_AMP
									c_hi = ca + DETAIL_AMP
								var lim := SKIP_LIM + k * 0.25
								if add:
									if c_hi < -lim or (d > lim and c_lo > lim):
										continue
								elif c_lo > lim or (d > lim and c_hi < -lim):
									continue
								var nv: float
								if d <= deep:
									nv = -Planet.EDIT_CLAMP if add else Planet.EDIT_CLAMP
								else:
									if not edited:
										cur = gen._density(p, rr, sv) if rr >= 1.0 else -radius
									nv = _smin(cur, d, k) if add else -_smin(-cur, d, k)
									nv = clampf(nv, -Planet.EDIT_CLAMP, Planet.EDIT_CLAMP)
									if absf(nv - cur) < 1e-4:
										continue
								arr[li] = nv
								changed = true
								written += 1
								_lo = Vector3i(mini(_lo.x, x), mini(_lo.y, y), mini(_lo.z, z))
								_hi = Vector3i(maxi(_hi.x, x), maxi(_hi.y, y), maxi(_hi.z, z))
					if changed:
						edits[key] = arr
						regions[key] = true

	## A terrain-following raise (SH_BUMP): the ground at voxel (x, y, z) goes up by bh m (density
	## - bh), so a hill keeps the lie of the land under it. Returns true when the voxel was written.
	func _bump(x: int, y: int, z: int, bh: float, amp: float, k: float, arr: PackedFloat32Array) -> bool:
		if bh < 0.002:
			return false
		var p := Vector3(x, y, z)
		if amp > 0.0:
			bh = maxf(bh + noise.get_noise_3dv(p) * amp * minf(bh, 1.0), 0.0)
		var rr := p.length()
		var li := (x & 15) | ((y & 15) << 4) | ((z & 15) << 8)
		var cur: float = arr[li]
		var edited := cur < TerrainGen.NO_EDIT * 0.5
		var sv := Vector4.ZERO
		var c_lo := cur
		var c_hi := cur
		if not edited:
			sv = _surf_of(p, rr)
			var ca := rr - radius - sv.x
			c_lo = ca - DETAIL_AMP
			c_hi = ca + DETAIL_AMP
		var lim := SKIP_LIM + k * 0.25
		if c_hi - bh < -lim or c_lo - bh > lim:
			return false
		if not edited:
			cur = gen._density(p, rr, sv) if rr >= 1.0 else -radius
		var nv := clampf(maxf(cur - bh, minf(cur, rr - ceil_r)), -Planet.EDIT_CLAMP, Planet.EDIT_CLAMP)
		if absf(nv - cur) < 1e-4:
			return false
		arr[li] = nv
		written += 1
		_lo = Vector3i(mini(_lo.x, x), mini(_lo.y, y), mini(_lo.z, z))
		_hi = Vector3i(maxi(_hi.x, x), maxi(_hi.y, y), maxi(_hi.z, z))
		return true

	## Polynomial smooth minimum (k = blend width, m).
	func _smin(a: float, b: float, k: float) -> float:
		if k <= 0.0:
			return minf(a, b)
		var h := clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
		return lerpf(b, a, h) - k * h * (1.0 - h)

	## Signed distance (m, < 0 inside) of a shape at op-local q.
	func _sdf(shape: int, q: Vector3, m: PackedFloat32Array) -> float:
		match shape:
			SH_PILLAR:
				# r_base, r_top, top, bottom, sx, sz, ledge, phase
				var t := clampf(q.y / m[2], 0.0, 1.0)
				var r := lerpf(m[0], m[1], t) + m[6] * sin(q.y * 1.7 + m[7])
				var e := Vector2(q.x / m[4], q.z / m[5]).length()
				var dr := (e - r) * minf(m[4], m[5])
				return maxf(-_smin(-dr, m[2] - q.y, 0.7), m[3] - q.y)
			SH_SEG:
				# profile, L, dy, then: box (x0, half w, floor A, floor B, top, round, ext),
				# arch (centre y, radius, ext), capsule (x0, centre y, radius, y squash)
				var l := m[1]
				var t := clampf(q.z / l, 0.0, 1.0)
				var y := q.y - m[2] * t
				var pr := int(m[0])
				if pr == 0:
					var fl := lerpf(m[5], m[6], t)
					return _rbox(absf(q.x - m[3]) - m[4], maxf(fl - y, y - m[7]), maxf(-q.z, q.z - l) - m[9], m[8])
				if pr == 1:
					return maxf(maxf(Vector2(q.x, y - m[3]).length() - m[4], -y), maxf(-q.z, q.z - l) - m[5])
				var tz := clampf(q.z, 0.0, l)
				if pr == 3:
					# ridge (x0, crest h, slope, crest round)
					var rd := sqrt(pow(q.x - m[3], 2.0) + pow(q.z - tz, 2.0) + m[6] * m[6]) - m[6]
					return (rd * m[5] + y - m[4]) / sqrt(1.0 + m[5] * m[5])
				return (Vector3(q.x - m[3], (y - m[4]) / m[6], q.z - tz).length() - m[5]) * minf(m[6], 1.0)
			SH_BUMP:
				# h, slope, crest round, toe: minus the raise (m) of a rounded cone over the ground,
				# eased to 0 over ± toe at its foot
				var raw := m[0] - (sqrt(q.x * q.x + q.z * q.z + m[2] * m[2]) - m[2]) * m[1]
				if raw >= m[3]:
					return -raw
				if raw <= -m[3]:
					return 0.0
				return -(raw + m[3]) * (raw + m[3]) / (4.0 * m[3])
			SH_ELLIPSOID:
				# ax, ay, az, floor
				var a := Vector3(m[0], m[1], m[2])
				var k0 := (q / a).length()
				var k1 := (q / (a * a)).length()
				return maxf(k0 * (k0 - 1.0) / maxf(k1, 1e-6), m[3] - q.y)
			SH_TORUS_V:
				return Vector2(Vector2(q.x, q.y).length() - m[0], q.z).length() - m[1]
			SH_TORUS_H:
				return (Vector2(Vector2(q.x, q.z).length() - m[0], q.y / m[2]).length() - m[1]) * minf(m[2], 1.0)
			SH_FRUSTUM:
				return maxf(Vector2(q.x, q.z).length() - (m[0] + (m[1] - q.y) * m[2]), q.y - m[1]) * 0.7071
			SH_CUTCONE:
				return maxf(Vector2(q.x, q.z).length() - (m[0] + (q.y - m[1]) * m[2]), m[1] - q.y) * 0.7071
			SH_RBOX:
				return _rbox(absf(q.x) - m[0], absf(q.y) - m[1], absf(q.z) - m[2], m[3])
		return 1.0e3

	## Rounded box from the signed distances to its three slabs (rr: edge radius).
	func _rbox(ox: float, oy: float, oz: float, rr: float) -> float:
		var o := Vector3(ox + rr, oy + rr, oz + rr)
		return Vector3(maxf(o.x, 0.0), maxf(o.y, 0.0), maxf(o.z, 0.0)).length() + minf(maxf(o.x, maxf(o.y, o.z)), 0.0) - rr
