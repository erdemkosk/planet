extends Node
## Gömülü sandıklar ve eski kalıntılar (2026-10-06, the user: "kazarken nadiren eski bir ikmal sandığı,
## kayıp bir ekipman ya da eklenti bulursun"): old caches buried in both planets, so there is always a
## reason to dig one more metre. Child "Caches" of main.gd; tunables: balance.gd "Buried caches" (CACHE_*).
##
## Placement (plan(), static and pure): CACHE_COUNT per planet from the planet's seed, identical on every
## machine (directions, kinds and rejections use the RNG only, never the edited terrain), CACHE_DEPTH
## under the ORIGINAL ground (the generator's density along the radius), CACHE_SPACING apart (along the
## surface), none within CACHE_BASE_CLEAR of either base (main.gd spawn_transform: the player's spawn and
## the rival team's base, rival_team.gd _base_transform, are the same point). CACHE_CONTESTED_SHARE of them
## lie in the contested areas and get CACHE_CONTESTED_BONUS of richness: around the combat areas of
## scripts/planet/poi.gd (within a site's footprint + CACHE_POI_REACH; loaded lazily, Poi.sites_of) when the
## planet has any, else within CACHE_FRONT_ANGLE of the point facing the other planet. Under a site's
## footprint (stamped trenches, tunnels) a cache lies at least CACHE_POI_MIN_DEPTH deep. Planned one frame
## after main._ready (the combat areas are built by then). Richness 0..1 = depth share × 0.75 + 0.25 of luck
## (+ the bonus) picks the kind (CACHE_KIND_W) and scales the contents.
## Kinds (scripts/war/cache_prop.gd draws them): "crate" Eski ikmal sandığı (common), "kitbag" Düşmüş
## askerin çantası and "locker" Mühürlü ekipman dolabı (uncommon), "relic" Eski kalıntı (rare).
## Caches are records, not nodes: the CACHE_POOL nearest ones within CACHE_NODE_R of the camera borrow a
## pooled cache_prop.gd node (model, collider once dug free, the F area, group "buried_cache" with
## scan_point() / scan_label() for the Tünel tarayıcı while unopened).
## Discovery: every brush on a planet (planet.gd brush_applied: digs, craters, either side's) near a
## buried cache tests the edited density around it; air within CACHE_EXPOSE_R of its centre digs it free:
## within CACHE_FOUND_R of us a dirt burst, a glint, a chime and "Gömülü sandık bulundu!". Before that our
## own drill within CACHE_TINK_R of it gives a faint metallic tink through the soil. Pooled props re-test
## once a second (edits that came without a brush signal, e.g. a late join's terrain stream).
## Opening: F on a dug-free cache plays CACHE_OPEN_TIME s of lid / latch animation, then claims it.
## Contents (roll_contents(), deterministic per cache; plain values): {"t": "gun", "id"} lies on the ground
## as a WeaponDrop (spawned by the host, hold F to take); {"t": "mat", "n"} material (Game.add_material, so
## the summary toast is not replaced by a pickup's), {"t": "gren", "n"} grenades, {"t": "att", "k"} an
## attachment the opener does not own yet (k picks it; all owned: CACHE_ATT_FALLBACK m³) and {"t": "buff",
## "id", "s"} a relic buff (scripts/war/cache_buffs.gd) go to the opener only, with one summary toast.
##
## Multiplayer (host authoritative for the OPENED state; positions come from the seed). Caches.events():
##   open_requested(id)              client: our player opened cache id (the animation ran) -> host:
##                                   Caches.claim(id, TAKER_PEER)  (the first claim wins; a client
##                                   re-sends every RETRY_MS while unanswered, at most RETRIES times)
##   cache_opened(id, by, contents)  host: cache id is open; by = TAKER_LOCAL (the host's player) or
##                                   TAKER_PEER (the client's). The host already spawned the gun (its
##                                   WeaponDrop events carry it) -> client:
##                                   Caches.opened_remote(id, by == TAKER_PEER, contents) (grants the
##                                   opener's personal items there, once; plays the lid open)
##   cache_found(id)                 local only: each machine digs it free from the synced terrain
##   buff_started(buff, secs) / buff_ended(buff)   local only: our relic buff (cache_buffs.gd). "shield"
##                                   absorbs the damage this machine applies; a client's hits decided by
##                                   the host are not covered unless the host is told (optional)
##   snapshot() -> [id, ...]         the opened caches -> a late join: Caches.apply_snapshot(ids) (kept
##                                   and applied after the planning when it comes earlier)
## API (static): claim(id, by) -> Array, opened_remote(id, by_me, contents), snapshot(), apply_snapshot(ids),
##   records() -> Array, find(id) -> Dictionary, world_pos(id) -> Vector3, plan(body, other, base_dirs, sites),
##   roll_contents(rec), is_exposed(body, world), kind_name(kind), instance().

const Balance := preload("res://scripts/war/balance.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # toasts: key "cache" (found / opened / empty, 1)
const WeaponDrop := preload("res://scripts/war/weapon_drop.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const CacheProp := preload("res://scripts/war/cache_prop.gd")
const CacheBuffs := preload("res://scripts/war/cache_buffs.gd")
const Dig := preload("res://scripts/player/dig.gd")
const ATT_PATH := "res://scripts/items/attachments.gd"      # loaded lazily (never at an autoload's _ready)
const POI_PATH := "res://scripts/planet/poi.gd"             # loaded lazily (another session's; may be absent)
const GROUP := "war_caches"

const TAKER_LOCAL := "local"
const TAKER_PEER := "peer"

const KINDS := ["crate", "kitbag", "locker", "relic"]
const NAMES := {"crate": "Eski ikmal sandığı", "kitbag": "Düşmüş askerin çantası", "locker": "Mühürlü ekipman dolabı",
		"relic": "Eski kalıntı"}
const FOUND_TEXT := {"crate": "Gömülü sandık bulundu!", "kitbag": "Gömülü bir asker çantası bulundu!",
		"locker": "Gömülü sandık bulundu! Mühürlü bir dolap", "relic": "Eski bir kalıntı bulundu!"}
const GUN_NAMES := {"rifle": "Tüfek", "shotgun": "Pompalı", "sniper": "Keskin Nişancı", "pusher": "Kinetik İtici",
		"rocket": "Roketatar", "rail": "Raylı Tüfek", "smg": "Hafif Makineli", "dirt": "Toprak Topu", "plasma": "Plazma Kesici", "mortar": "Havan",
		"pistol": "Tabanca", "revolver": "Altıpatlar", "mpistol": "Makineli Tabanca"}
const POOL_TICK := 0.25                # s between pool updates
const RECHECK := 1.0                   # s between the pooled props' exposure re-tests
const RETRY_MS := 2000                 # client: an unanswered open request is sent again after this...
const RETRIES := 3                     # ...this many times at most
const DRILL_NEAR := 12.0               # m: a brush this close to our player while the drill works is ours
const PROBE_STEPS := 7                 # exposure samples per axis across the CACHE_EXPOSE_R ball (~0.27 m apart)
const NO_EDIT_HALF := 0.5e9            # terrain_gen.gd NO_EDIT × 0.5: an untouched voxel of an edit region
const SOLID := -8.0                    # an unedited voxel corner: solid (caches lie ≥ 2 m deep, no caves)
static var _ball: PackedVector3Array   # the sample offsets inside the ball (unit radius)

## Multiplayer / listener hooks (see above).
class CacheEvents extends RefCounted:
	signal open_requested(id: int)
	signal cache_opened(id: int, by: String, contents: Array)
	signal cache_found(id: int)
	signal buff_started(buff: String, secs: float)
	signal buff_ended(buff: String)

static var _events: CacheEvents
static var _inst: Node                 # the live manager (this script's node)
static var _recs := {}                 # id -> record (Dictionary, see plan())
static var _by_preset := {}            # preset -> [record, ...]
static var _pending_snap: Array = []   # apply_snapshot() before the planning: applied after it

var _bodies := {}                      # preset -> planet node
var _props: Array = []                 # pooled cache_prop.gd nodes
var _prop_of := {}                     # record id -> prop
var _tick := 0.0
var _recheck := 0.0
var buffs: Node                        # cache_buffs.gd (relic buffs, their HUD chips, the tiny hooks)


static func events() -> CacheEvents:
	if _events == null:
		_events = CacheEvents.new()
	return _events


static func instance() -> Node:
	return _inst if _inst != null and is_instance_valid(_inst) else null


# =================================================================================================
# API (static)
# =================================================================================================

## Every cache record (both planets). Fields: id, preset, local (body-local centre), dir (unit "up"),
## kind, depth, rich, front, yaw, tilt, seed, exposed, opened, opening, granted, pending_ms, tries, tink_ms.
static func records() -> Array:
	return _recs.values()


static func find(id: int) -> Dictionary:
	return _recs.get(id, {})


static func kind_name(kind: String) -> String:
	return str(NAMES.get(kind, "Gömülü sandık"))


## World centre of cache id (INF when unknown or its planet is gone).
static func world_pos(id: int) -> Vector3:
	var rec: Dictionary = _recs.get(id, {})
	if rec.is_empty():
		return Vector3.INF
	var b := Bodies.by_preset(str(rec["preset"]))
	if b == null:
		return Vector3.INF
	return b.global_position + (rec["local"] as Vector3)


## Host / single player: someone opens cache id (TAKER_LOCAL / TAKER_PEER). Spawns the world items
## (material, gun) here, grants the personal ones to our player when TAKER_LOCAL, emits cache_opened.
## Returns the contents ([] = unknown or already opened: the first claim wins).
static func claim(id: int, by: String) -> Array:
	var rec: Dictionary = _recs.get(id, {})
	if rec.is_empty() or bool(rec["opened"]):
		return []
	rec["opened"] = true
	rec["exposed"] = true
	var waited := bool(rec["opening"])
	rec["opening"] = false
	var contents := roll_contents(rec)
	var m := instance()
	if m != null:
		m.call("_spawn_world", rec, contents)
		m.call("_show_open", rec, not (by == TAKER_LOCAL and waited))
	if by == TAKER_LOCAL:
		_grant_local(rec, contents)
	events().cache_opened.emit(id, by, contents.duplicate(true))
	return contents


## Multiplayer client: the host says cache id is open; by_me = our open request won (contents: what the
## host's claim rolled; our personal items are granted from it, once).
static func opened_remote(id: int, by_me: bool, contents: Array) -> void:
	var rec: Dictionary = _recs.get(id, {})
	if rec.is_empty():
		return
	var waiting := bool(rec["opening"]) or int(rec["pending_ms"]) > 0
	var first := not bool(rec["opened"])
	rec["opened"] = true
	rec["exposed"] = true
	rec["opening"] = false
	rec["pending_ms"] = 0
	var m := instance()
	if m != null and first:
		m.call("_show_open", rec, not waiting)
	if by_me:
		_grant_local(rec, contents)
	elif waiting and Game.hud:
		HudLevel.alert("Boş — biri senden önce açmış", 1, "cache", 2.2)


## The opened caches (a late join).
static func snapshot() -> Array:
	var out: Array = []
	for id in _recs:
		if bool(_recs[id]["opened"]):
			out.append(int(id))
	return out


## Multiplayer client, late join: these caches are already open (no animation, nothing granted).
static func apply_snapshot(ids: Array) -> void:
	var m := instance()
	if _recs.is_empty():
		_pending_snap = ids.duplicate()        # (not planned yet: _setup applies it)
		return
	for v in ids:
		var rec: Dictionary = _recs.get(int(v), {})
		if rec.is_empty() or bool(rec["opened"]):
			continue
		rec["opened"] = true
		rec["exposed"] = true
		rec["granted"] = true
		if m != null:
			m.call("_show_open", rec, false, true)


## Air within CACHE_EXPOSE_R of world point w on body: dug free. Exact enough and cheap: the voxel
## corners around it come straight from the planet's edit grid (an unedited corner is solid this deep);
## no air corner in reach = buried at once; else the trilinear density (as the mesh) is sampled toward
## every air corner (at its distance, at most CACHE_EXPOSE_R: catches a thin cap of air at the ball's
## rim) and on a PROBE_STEPS³ grid inside the ball.
static func is_exposed(body: Node3D, w: Vector3) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	var edits = body.get("edits")
	if not (edits is Dictionary) or (edits as Dictionary).is_empty():
		return false
	var R := Balance.CACHE_EXPOSE_R
	var p := w - body.global_position            # body-local, 1 m voxels
	var lo := Vector3i((p - Vector3.ONE * R).floor())
	var hi := Vector3i((p + Vector3.ONE * R).floor()) + Vector3i.ONE
	var n := hi - lo + Vector3i.ONE
	var grid := PackedFloat32Array()
	grid.resize(n.x * n.y * n.z)
	var air: Array = []                       # body-local air corners
	var i := 0
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var v := SOLID
				var arr = edits.get(Vector3i(x >> 4, y >> 4, z >> 4))
				if arr != null:
					var e: float = arr[(x & 15) | ((y & 15) << 4) | ((z & 15) << 8)]
					if e < NO_EDIT_HALF:
						v = e
				grid[i] = v
				if v > 0.0:
					air.append(Vector3(x, y, z))
				i += 1
	if air.is_empty():
		return false
	for c in air:
		var rel: Vector3 = c - p
		var L := rel.length()
		var q: Vector3 = p if L < 1e-4 else p + rel * (minf(L, R) / L)
		if _tri(grid, n, q - Vector3(lo)) > 0.0:
			return true
	if _ball.is_empty():
		for a in PROBE_STEPS:
			for b in PROBE_STEPS:
				for c in PROBE_STEPS:
					var o := Vector3(a, b, c) / float(PROBE_STEPS - 1) * 2.0 - Vector3.ONE
					if o.length() <= 1.0:
						_ball.append(o)
	for o in _ball:
		if _tri(grid, n, p + o * R - Vector3(lo)) > 0.0:
			return true
	return false


## Trilinear value of the corner grid (n corners per axis, x fastest) at grid-local q (inside it).
static func _tri(grid: PackedFloat32Array, n: Vector3i, q: Vector3) -> float:
	var f := q.floor()
	f = Vector3(clampf(f.x, 0.0, n.x - 2), clampf(f.y, 0.0, n.y - 2), clampf(f.z, 0.0, n.z - 2))
	var t := q - f
	var sy := n.x
	var sz := n.x * n.y
	var bi := int(f.x) + int(f.y) * sy + int(f.z) * sz
	var x00 := lerpf(grid[bi], grid[bi + 1], t.x)
	var x10 := lerpf(grid[bi + sy], grid[bi + sy + 1], t.x)
	var x01 := lerpf(grid[bi + sz], grid[bi + sz + 1], t.x)
	var x11 := lerpf(grid[bi + sz + sy], grid[bi + sz + sy + 1], t.x)
	return lerpf(lerpf(x00, x10, t.y), lerpf(x01, x11, t.y), t.z)


# =================================================================================================
# Placement (static, pure)
# =================================================================================================

## The caches of `body`: deterministic from its seed and preset. base_dirs: unit directions (from the
## body's centre) of the bases to keep clear; other: the other planet (the contested front faces it);
## sites: poi.gd sites of the body ({dir, fp, ...}; [] = none: the front instead).
static func plan(body: Node3D, other: Node3D, base_dirs: Array, sites: Array = []) -> Array:
	var out: Array = []
	if body == null or not is_instance_valid(body):
		return out
	var preset := str(body.get("preset_name"))
	var side := 1 if preset == "rival" else 0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(body.get("seed_value")) * 7919 + side * 104729 + 9001
	var R := maxf(float(body.get("radius")), 1.0)
	var c := body.global_position
	var front := Vector3.RIGHT if side == 0 else Vector3.LEFT
	if other != null and is_instance_valid(other) and other.global_position.distance_to(c) > 1.0:
		front = (other.global_position - c).normalized()
	var n := rng.randi_range(Balance.CACHE_COUNT.x, Balance.CACHE_COUNT.y)
	var cos_space := cos(Balance.CACHE_SPACING / R)
	var cos_base := cos(Balance.CACHE_BASE_CLEAR / R)
	var front_ang := deg_to_rad(Balance.CACHE_FRONT_ANGLE)
	var dirs: Array = []
	var tries := 0
	while out.size() < n and tries < n * 80:
		tries += 1
		# Every draw happens before the tests: each try eats the same numbers, so the sequence never
		# depends on a comparison that floats could tip differently on another machine.
		var in_front := rng.randf() < Balance.CACHE_CONTESTED_SHARE
		var u_ct := rng.randf()
		var u_ph := rng.randf()
		var u_depth := rng.randf()
		var u_luck := rng.randf()
		var u_kind := rng.randf()
		var yaw := rng.randf() * TAU
		var tilt := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
		var cseed := int(rng.randi())
		var u_site := rng.randf()
		var axis := front
		var ang := front_ang if in_front else PI
		if in_front and not sites.is_empty():
			var s = sites[mini(int(u_site * float(sites.size())), sites.size() - 1)]
			if s is Dictionary and (s as Dictionary).get("dir") is Vector3:
				axis = ((s as Dictionary)["dir"] as Vector3).normalized()
				ang = (float((s as Dictionary).get("fp", 8.0)) + Balance.CACHE_POI_REACH) / R
		var d := _cap_dir(axis, ang, u_ct, u_ph)
		if not _clear_of(d, base_dirs, cos_base) or not _clear_of(d, dirs, cos_space):
			continue
		var depth := lerpf(Balance.CACHE_DEPTH.x, Balance.CACHE_DEPTH.y, pow(u_depth, Balance.CACHE_DEPTH_BIAS))
		if _in_site(d, sites, R):
			depth = maxf(depth, Balance.CACHE_POI_MIN_DEPTH)
		var d01 := inverse_lerp(Balance.CACHE_DEPTH.x, Balance.CACHE_DEPTH.y, depth)
		var rich := clampf(d01 * 0.75 + u_luck * 0.25 + (Balance.CACHE_CONTESTED_BONUS if in_front else 0.0), 0.0, 1.0)
		var kind := _pick_kind(rich, u_kind)
		var ground := _ground_r(body, d)
		dirs.append(d)
		out.append({"id": side * 1000 + out.size(), "preset": preset, "local": d * (ground - depth), "dir": d,
				"kind": kind, "depth": depth, "rich": rich, "front": in_front, "yaw": yaw, "tilt": tilt,
				"seed": cseed, "exposed": false, "opened": false, "opening": false, "granted": false,
				"pending_ms": 0, "tries": 0, "tink_ms": 0})
	return out


## A direction in the cap of half-angle max_ang around axis (uniform on the sphere; PI = anywhere).
static func _cap_dir(axis: Vector3, max_ang: float, u_ct: float, u_ph: float) -> Vector3:
	var ct := lerpf(1.0, cos(max_ang), u_ct)
	var st := sqrt(maxf(1.0 - ct * ct, 0.0))
	var ph := u_ph * TAU
	var t1 := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var t2 := axis.cross(t1)
	return (axis * ct + (t1 * cos(ph) + t2 * sin(ph)) * st).normalized()


## d lies under a combat area's footprint (+ 1.5 m).
static func _in_site(d: Vector3, sites: Array, R: float) -> bool:
	for s in sites:
		if not (s is Dictionary) or not ((s as Dictionary).get("dir") is Vector3):
			continue
		var sd: Vector3 = ((s as Dictionary)["dir"] as Vector3).normalized()
		if acos(clampf(d.dot(sd), -1.0, 1.0)) * R < float((s as Dictionary).get("fp", 8.0)) + 1.5:
			return true
	return false


## d is farther than the angle whose cosine is min_cos from every direction in dirs.
static func _clear_of(d: Vector3, dirs: Array, min_cos: float) -> bool:
	for e in dirs:
		if e is Vector3 and d.dot(e) > min_cos:
			return false
	return true


static func _pick_kind(rich: float, u: float) -> String:
	var total := 0.0
	for k in KINDS:
		var w: Vector2 = Balance.CACHE_KIND_W.get(k, Vector2.ZERO)
		total += maxf(lerpf(w.x, w.y, rich), 0.0)
	var roll := u * total
	for k in KINDS:
		var w: Vector2 = Balance.CACHE_KIND_W.get(k, Vector2.ZERO)
		roll -= maxf(lerpf(w.x, w.y, rich), 0.0)
		if roll <= 0.0:
			return str(k)
	return "crate"


## Distance from the centre to the ORIGINAL ground along d: the generator's density (with its ±1.3 m
## detail, like the mesh), marched down from above the analytic surface and bisected.
static func _ground_r(body: Node3D, d: Vector3) -> float:
	var R := float(body.get("radius"))
	var r0 := R + float(body.surface_height_at(body.global_position + d * R))
	var g = body.get("gen")
	if g == null or not (g as Object).has_method("density_base"):
		return r0
	var hi := r0 + 3.0
	var lo := hi
	var found := false
	for i in 24:
		lo = hi - 0.5
		if float(g.density_base(d * lo)) < 0.0:
			found = true
			break
		hi = lo
	if not found:
		return r0
	for i in 10:
		var mid := (hi + lo) * 0.5
		if float(g.density_base(d * mid)) < 0.0:
			lo = mid
		else:
			hi = mid
	return (hi + lo) * 0.5


# =================================================================================================
# Contents (static)
# =================================================================================================

## What cache `rec` holds (deterministic from its seed): see the header for the entries.
static func roll_contents(rec: Dictionary) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(rec.get("seed", 1))
	var kind := str(rec.get("kind", "crate"))
	var rich := float(rec.get("rich", 0.0))
	var out: Array = []
	if kind == "relic":
		var b := _pick(rng.randf(), Balance.CACHE_RELIC_W)
		var secs := roundf(lerpf(Balance.CACHE_BUFF_TIME.x, Balance.CACHE_BUFF_TIME.y, rng.randf()))
		if b != "":
			out.append({"t": "buff", "id": b, "s": secs})
	var rr: Vector2i = Balance.CACHE_ROLLS.get(kind, Vector2i(1, 1))
	var n := rng.randi_range(rr.x, rr.y)
	var mat := 0.0
	var gren := 0
	var gun := ""
	for i in n:
		var t := _pick(rng.randf(), Balance.CACHE_TABLE.get(kind, {}))
		var v := rng.randf()
		var k := int(rng.randi())
		var g := _pick(rng.randf(), Balance.CACHE_GUN_W)
		if t == "gun" and gun != "":
			t = "att"                       # (one gun per cache)
		elif t == "gren" and gren > 0:
			t = "mat"                       # (one grenade roll per cache: +2-4)
		match t:
			"mat":
				mat += roundf(lerpf(Balance.CACHE_MAT.x, Balance.CACHE_MAT.y, clampf(rich * 0.7 + v * 0.3, 0.0, 1.0)))
			"gren":
				gren += clampi(Balance.CACHE_GRENADES.x + int(floorf(v * float(Balance.CACHE_GRENADES.y - Balance.CACHE_GRENADES.x + 1))),
						Balance.CACHE_GRENADES.x, Balance.CACHE_GRENADES.y)
			"att":
				out.append({"t": "att", "k": k})
			"gun":
				gun = g
	if mat > 0.0:
		out.append({"t": "mat", "n": mat})
	if gren > 0:
		out.append({"t": "gren", "n": gren})
	if gun != "":
		out.append({"t": "gun", "id": gun})
	return out


## A key of `weights` (key -> weight, insertion order) for a uniform roll u in 0..1 ("" = all zero).
static func _pick(u: float, weights: Dictionary) -> String:
	var total := 0.0
	for k in weights:
		total += maxf(float(weights[k]), 0.0)
	if total <= 0.0:
		return ""
	var roll := u * total
	var last := ""
	for k in weights:
		var w := maxf(float(weights[k]), 0.0)
		if w <= 0.0:
			continue
		last = str(k)
		roll -= w
		if roll <= 0.0:
			return last
	return last


## Our player opened it (or the host says our request won): the personal items, one summary toast.
static func _grant_local(rec: Dictionary, contents: Array) -> void:
	if bool(rec.get("granted", false)):
		return
	rec["granted"] = true
	var parts := PackedStringArray()
	var att_hint := false
	for e in contents:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		match str(d.get("t", "")):
			"mat":
				Game.add_material(float(d.get("n", 0.0)))
				parts.append("+%d m³ malzeme" % int(d.get("n", 0)))
			"gren":
				var before := Game.grenades
				Game.grenades = mini(Game.grenades + int(d.get("n", 0)), Balance.GRENADE_MAX)
				Game.loadout_changed.emit()
				parts.append("+%d el bombası" % maxi(Game.grenades - before, 0) if Game.grenades > before else "el bombası cebi dolu")
			"att":
				var got := _grant_attachment(int(d.get("k", 0)))
				if got != "":
					parts.append("YENİ EKLENTİ: " + got)
					att_hint = true
				else:
					Game.add_material(Balance.CACHE_ATT_FALLBACK)
					parts.append("+%d m³ malzeme" % int(Balance.CACHE_ATT_FALLBACK))
			"gun":
				parts.append("yerde silah: " + str(GUN_NAMES.get(str(d.get("id", "")), str(d.get("id", "")))))
			"buff":
				var bid := str(d.get("id", ""))
				var secs := float(d.get("s", Balance.CACHE_BUFF_TIME.x))
				CacheBuffs.start(bid, secs)
				parts.append("%s %d sn" % [CacheBuffs.buff_name(bid).to_upper(), int(secs)])
	if parts.is_empty():
		parts.append("boş çıktı")
	if att_hint:
		parts.append("orta tuşla tak")
	if Game.hud:
		HudLevel.alert("%s: %s" % [kind_name(str(rec.get("kind", ""))), "  ·  ".join(parts)], 1, "cache", 4.5)
	if Game.sfx:
		Game.sfx.play("craft", -6.0, 1.05)
		Game.sfx.play_later("ding", 0.12, -9.0, 1.3)


## A random attachment the player does not own yet (k picks it); its name, "" when all are owned.
static func _grant_attachment(k: int) -> String:
	var att = load(ATT_PATH)
	if att == null or not (att is Script) or not (att as Script).can_instantiate():
		return ""
	var missing: Array = []
	for d in att.list():
		if d is Dictionary and not bool((d as Dictionary).get("owned", true)):
			missing.append(d)
	if missing.is_empty():
		return ""
	var pick: Dictionary = missing[absi(k) % missing.size()]
	att.unlock(str(pick.get("id", "")))
	return str(pick.get("name", pick.get("id", "")))


# =================================================================================================
# The manager node
# =================================================================================================

func _ready() -> void:
	name = "Caches"
	add_to_group(GROUP)
	_inst = self
	_recs.clear()
	_by_preset.clear()
	buffs = CacheBuffs.new()
	buffs.name = "CacheBuffs"
	add_child(buffs)
	for i in Balance.CACHE_POOL:
		var p: Node3D = CacheProp.new()
		p.manager = self
		p.name = "CacheProp%d" % i
		add_child(p)
		_props.append(p)
	set_process(false)
	_setup.call_deferred()                    # (after main._ready: the combat areas exist by then)


## Plans both planets' caches (once) and listens to their brushes.
func _setup() -> void:
	var all: Array = []
	for b in Bodies.all():
		if b != null and is_instance_valid(b) and b.has_method("density_at"):
			all.append(b)
	for b in all:
		var other: Node3D = null
		for o in all:
			if o != b:
				other = o
		var preset := str(b.get("preset_name"))
		_bodies[preset] = b
		var list := plan(b, other, [_base_dir(b, other)], _poi_sites(b))     # (one base per planet)
		_by_preset[preset] = list
		for rec in list:
			_recs[int(rec["id"])] = rec
		if b.has_signal("brush_applied"):
			b.brush_applied.connect(_on_brush.bind(b))
	if not _pending_snap.is_empty():
		var ids := _pending_snap
		_pending_snap = []
		apply_snapshot(ids)
	set_process(true)


## The combat areas of `body` (scripts/planet/poi.gd, when that exists and compiles), else [].
static func _poi_sites(body: Node3D) -> Array:
	if not ResourceLoader.exists(POI_PATH):
		return []
	var poi = load(POI_PATH)
	if poi == null or not (poi is Script) or not (poi as Script).can_instantiate():
		return []
	var s = poi.sites_of(body)
	return s if s is Array else []


func _exit_tree() -> void:
	if _inst == self:
		_inst = null
		_recs.clear()                          # (the match is over: a late snapshot must not land on these)
		_by_preset.clear()
		_pending_snap = []


## Unit direction (from the body's centre) of the base on `body`: main.gd spawn_transform (the
## player's spawn on the home planet, the rival team's base on theirs: the same formula).
func _base_dir(body: Node3D, other: Node3D) -> Vector3:
	var c := body.global_position
	var m := get_parent()
	if m != null and m.has_method("spawn_transform"):
		var xf: Transform3D = m.spawn_transform(body, other, 0.0)
		if xf.origin.distance_to(c) > 1.0:
			return (xf.origin - c).normalized()
	var facing := Vector3.RIGHT
	if other != null and is_instance_valid(other):
		facing = (other.global_position - c).normalized()
	return (facing + Game.sun_dir * 1.15 + Vector3.UP * 0.1).normalized()


func _process(delta: float) -> void:
	_tick -= delta
	if _tick <= 0.0:
		_tick = POOL_TICK
		_update_pool()
	_recheck -= delta
	if _recheck <= 0.0:
		_recheck = RECHECK
		_recheck_props()
		_retry_requests()


## Where the pool is centred: the camera (the player's eyes, the shuttle's chase cam), else the player.
func _ref_pos() -> Vector3:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		return cam.global_position
	var p = Game.player
	if p != null and is_instance_valid(p):
		return (p as Node3D).global_position
	return Vector3.INF


func _body(rec: Dictionary) -> Node3D:
	var b = _bodies.get(str(rec["preset"]))
	if b == null or not is_instance_valid(b):
		return null
	return b


## The CACHE_POOL nearest caches within CACHE_NODE_R get a prop; the others give theirs back.
func _update_pool() -> void:
	var ref := _ref_pos()
	if ref == Vector3.INF:
		return
	var cand: Array = []
	var r2 := Balance.CACHE_NODE_R * Balance.CACHE_NODE_R
	for id in _recs:
		var rec: Dictionary = _recs[id]
		var b := _body(rec)
		if b == null:
			continue
		var d2 := (b.global_position + (rec["local"] as Vector3)).distance_squared_to(ref)
		if d2 < r2:
			cand.append([d2, int(id)])
	cand.sort_custom(func(x, y): return float(x[0]) < float(y[0]))
	if cand.size() > _props.size():
		cand.resize(_props.size())
	var want := {}
	for c in cand:
		want[int(c[1])] = true
	for id in _prop_of.keys():
		if not want.has(int(id)):
			var p = _prop_of[id]
			_prop_of.erase(id)
			if p != null and is_instance_valid(p):
				p.release()
	for c in cand:
		var id := int(c[1])
		if _prop_of.has(id):
			continue
		var p = _free_prop()
		if p == null:
			break
		var rec: Dictionary = _recs[id]
		var b := _body(rec)
		if not bool(rec["exposed"]) and is_exposed(b, b.global_position + (rec["local"] as Vector3)):
			rec["exposed"] = true            # (dug free while nobody was near: no fanfare)
		p.assign(rec, b)
		_prop_of[id] = p


func _free_prop() -> Node3D:
	for p in _props:
		if int(p.rec_id) < 0:
			return p
	return null


## Pooled props of still buried caches re-test the density (edits without a brush signal).
func _recheck_props() -> void:
	for id in _prop_of:
		var rec: Dictionary = _recs.get(int(id), {})
		if rec.is_empty() or bool(rec["exposed"]):
			continue
		var b := _body(rec)
		var w := b.global_position + (rec["local"] as Vector3) if b != null else Vector3.INF
		if b != null and is_exposed(b, w):
			_found(rec, b, w)


## A client's open request the host has not answered yet: once more (reliable messages make this rare).
func _retry_requests() -> void:
	if not Net.is_client():
		return
	var now := Time.get_ticks_msec()
	for id in _recs:
		var rec: Dictionary = _recs[id]
		var since := int(rec["pending_ms"])
		if since <= 0 or bool(rec["opened"]) or now - since < RETRY_MS:
			continue
		if int(rec["tries"]) >= RETRIES:
			rec["pending_ms"] = 0
			rec["opening"] = false
			var p = _prop_of.get(int(id))
			if p != null and is_instance_valid(p):
				p.cancel_open()
			continue
		rec["tries"] = int(rec["tries"]) + 1
		rec["pending_ms"] = now
		events().open_requested.emit(int(id))


# --- Discovery ------------------------------------------------------------------------------------

## A brush on `body` (any source): buried caches near it are tested; our drill near one: a tink.
func _on_brush(center: Vector3, r: float, body: Node3D) -> void:
	var list = _by_preset.get(str(body.get("preset_name")))
	if not (list is Array):
		return
	var ours := _local_drilling(center)
	var reach := r + Balance.CACHE_EXPOSE_R + 1.0
	var tink_r := Balance.CACHE_TINK_R + r * 0.5
	var c := body.global_position
	for rec in list:
		if bool(rec["exposed"]):
			continue
		var w: Vector3 = c + (rec["local"] as Vector3)
		var d := w.distance_to(center)
		if d < reach and is_exposed(body, w):
			_found(rec, body, w)
		elif ours and d < tink_r:
			_tink(rec, w)


## Our player is working the drill near `center` right now: a team-logged dig (Dig.net_team is set
## while dig_at applies it; the drill passes "home") within DRILL_NEAR of us with the drill in hand.
## (The drill's `using` flag is cleared at the start of its tick, so it cannot tell during the brush.)
func _local_drilling(center: Vector3) -> bool:
	if Dig.net_team == "":
		return false
	var p = Game.player
	if p == null or not is_instance_valid(p) or (p.has_method("is_dead") and p.is_dead()):
		return false
	var t = p.get("tool")
	if t == null or not is_instance_valid(t) or not bool(t.get("equipped")):
		return false
	return (p as Node3D).global_position.distance_to(center) < DRILL_NEAR


## A faint metallic tink through the soil (the drill bit grazing something below).
func _tink(rec: Dictionary, w: Vector3) -> void:
	var now := Time.get_ticks_msec()
	if now < int(rec["tink_ms"]):
		return
	rec["tink_ms"] = now + int(Balance.CACHE_TINK_GAP * 1000.0) + randi_range(0, 350)
	if Game.sfx == null:
		return
	if str(rec["kind"]) == "relic":
		Game.sfx.play_at("impact_light", w, -19.0, 0.8)     # (a duller, glassy knock)
		Game.sfx.play_later("tick", 0.06, -20.0, 0.7)
	else:
		Game.sfx.play_at("impact_light", w, -16.0, randf_range(1.25, 1.35))


## Cache dug free: its prop shows the collider / F area; near us the burst, glint, chime and toast.
func _found(rec: Dictionary, body: Node3D, w: Vector3) -> void:
	if bool(rec["exposed"]):
		return
	rec["exposed"] = true
	events().cache_found.emit(int(rec["id"]))
	var p = _prop_of.get(int(rec["id"]))
	if p != null and is_instance_valid(p):
		p.on_exposed()
	var ref := _ref_pos()
	if ref == Vector3.INF or ref.distance_to(w) > Balance.CACHE_FOUND_R:
		return
	var up: Vector3 = rec["dir"]
	var soil = body.get("soil_color")
	BuildFx.dust(self, w + up * 0.3, up, 1.1, soil if soil is Color else Color(0.42, 0.33, 0.22))
	if p != null and is_instance_valid(p):
		p.glint(1.0)
	var kind := str(rec["kind"])
	if Game.sfx:
		Game.sfx.play_at("impact", w, -8.0, 0.9)              # the lump of soil falling off it
		if kind == "relic":
			Game.sfx.play("whoosh", -12.0, 0.85)
			Game.sfx.play("ding", -6.0, 0.75)
			Game.sfx.play_later("ding", 0.16, -8.0, 1.12)
			Game.sfx.play_later("ding", 0.34, -10.0, 1.5)
		else:
			Game.sfx.play("ding", -5.0, 1.0)
			Game.sfx.play_later("ding", 0.11, -7.0, 1.5)
	if Game.hud:
		HudLevel.alert(str(FOUND_TEXT.get(kind, "Gömülü sandık bulundu!")), 1, "cache", 2.8)


# --- Opening --------------------------------------------------------------------------------------

## F on a dug-free cache (cache_prop.gd): the animation, then the claim (a client asks the host).
func request_open(id: int) -> void:
	var rec: Dictionary = _recs.get(id, {})
	if rec.is_empty() or bool(rec["opened"]) or bool(rec["opening"]) or not bool(rec["exposed"]):
		return
	rec["opening"] = true
	rec["tries"] = 0
	var p = _prop_of.get(id)
	if p != null and is_instance_valid(p):
		p.play_open(true)
	get_tree().create_timer(Balance.CACHE_OPEN_TIME, false).timeout.connect(_open_done.bind(id))


func _open_done(id: int) -> void:
	var rec: Dictionary = _recs.get(id, {})
	if rec.is_empty() or bool(rec["opened"]) or not bool(rec["opening"]):
		return
	if Net.is_client():
		rec["pending_ms"] = Time.get_ticks_msec()
		events().open_requested.emit(id)
		return
	claim(id, TAKER_LOCAL)


## The prop of rec opens (animated: remote = someone else's open, with its sound; instant: a late join).
func _show_open(rec: Dictionary, remote: bool, instant := false) -> void:
	var p = _prop_of.get(int(rec["id"]))
	if p == null or not is_instance_valid(p):
		return
	if instant:
		p.set_open_pose()
	elif remote:
		p.play_open(false)
	p.on_opened()


## Host / single player: the gun spills out of rec (WeaponDrop: its own sync).
func _spawn_world(rec: Dictionary, contents: Array) -> void:
	var b := _body(rec)
	if b == null:
		return
	var up: Vector3 = rec["dir"]
	var at: Vector3 = b.global_position + (rec["local"] as Vector3) + up * 0.6
	var p = _prop_of.get(int(rec["id"]))
	if p != null and is_instance_valid(p):
		at = p.spill_point()
		up = p.up_dir()
	for e in contents:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		match str(d.get("t", "")):
			"gun":
				var gid := str(d.get("id", ""))
				var res: Dictionary = Balance.CRAFT_RESERVE.get(gid, {})
				var ammo_id := ""
				var reserve := 0
				for a in res:
					ammo_id = str(a)
					reserve = int(roundf(float(res[a]) * Balance.CACHE_GUN_RESERVE))
					break
				WeaponDrop.drop_data(WeaponDrop.make_data(gid, at + up * 0.1, up * 2.4 + _jitter(up, 1.0), {}, ammo_id, reserve))


static func _jitter(up: Vector3, k: float) -> Vector3:
	var v := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
	v -= up * v.dot(up)
	return v.limit_length(1.0) * k
