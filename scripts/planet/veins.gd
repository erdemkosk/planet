extends RefCounted
## Zengin damarlar (2026-10-06): glowing rich veins inside the soil. Digging into one credits the SAME
## generic soil (Game.material; no ore types, the user's rule) × its multiplier: a jackpot moment.
## Veins are capsules (an axis A–B and a radius) placed from the planet's seed, its radius and its
## preset alone, in body-local coordinates (floating-origin safe): every machine generates the same
## set, nothing is synced. Depletion follows the terrain edits (synced already): a dug-out vein is air
## and credits nothing more; the vein volume itself is the budget.
##   ordinary  VEIN_COUNT_MIN..MAX per planet anywhere, VEIN_DEPTH m down, × VEIN_MULT_MIN..MAX
##   rich      RICH_COUNT_MIN..MAX in the contested zones (contested_dirs: the combat POIs of
##             scripts/planet/poi.gd when that exists, else the front: the point facing the other
##             planet, the approach to the base, VEIN_HOTSPOTS random spots on the facing half),
##             RICH_DEPTH m down, × RICH_MULT_MIN..MAX
## Meteor cores (scripts/war/meteor_shower.gd, host-decided; every machine registers them from its
## events) are temporary spherical deposits in the same lookup.
##
##   Veins.mult_at(body, world_point) -> float   1 outside; × the vein's multiplier inside, falling to 1
##       over VEIN_EDGE m outside. Pure (seed veins + registered meteor cores), a few capsule tests.
##       The drill (scripts/player/terrain_tool.gd) multiplies its credited soil by it after the
##       DRILL_MAX_RATE cap; the rival bots their bonus (ai_rival.gd "Prospecting").
##   Veins.info_at(body, world_point) -> {} or {"mult" (here), "full" (the vein's), "kind" (KIND_*),
##       "i" (vein index; the meteor id for KIND_METEOR)}
##   Veins.drill_rate_k(body, world_point) -> float   VEIN_DRILL_K inside a vein, else 1 (optional:
##       crystal is hard; a drill that scales its density rate by it makes the jackpot last longer)
##   Veins.veins(body) -> Array      [{"i", "a", "b", "c" (world), "r", "mult", "kind", "rich", "top" (m
##       of original soil over its top)}]
##   Veins.remaining(body, i) -> float   0..1 of the vein still solid: a local estimate sampled from the
##       edits (cached; mark_edit marks the veins a brush touched, else re-sampled every REMAIN_TTL_MS)
##   Veins.glow(rem) -> float        shader strength for a remaining share (fades out when spent)
##   Veins.contested_dirs(body) -> Array   body-local unit directions of the contested zones
##   Veins.mark_edit(body, world_center, radius)   a brush happened (scripts/planet/vein_fx.gd calls it)
##   Veins.vein_volume(body, i), count(body), reset() (vein_fx.gd, a new world: regenerated identically)
##   Veins.take_gain(body, kind, i) -> float   the extra worth of the share of a vein / core that turned
##       to air since its last sample (re-samples now); the rival bots' pool bonus
##   Veins.solid_point_near(body, kind, i, from) -> Vector3   its nearest still-solid sample (INF: dug out)
##   Veins.vein_bonus(body, point, soil, delta) -> float   OPTIONAL exact drill credit: banks take_gain
##       after a brush, pays out at most VEIN_BONUS_RATE m³/s (instead of `credit *= mult_at`; see there)
##   Meteor cores: add_deposit(id, body, world_center, radius, mult, amount, floor_off),
##       remove_deposit(id), clear_deposits(), has_deposit(id), deposits(body = null) -> Array of
##       {"id", "body", "pos" (world centre), "r", "mult", "amount", "rem", "up"},
##       deposit_remaining(id) -> float (0..1 of the part under the crater floor still solid),
##       below_floor_volume(r, floor_off)
## The generated set is made lazily on first use; made before the combat POIs exist it looks for them
## once a second and regenerates when they appear (every machine converges on the same set).

const Balance := preload("res://scripts/war/balance.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")

const KIND_NORMAL := 0
const KIND_RICH := 1
const KIND_METEOR := 2
## Combat POIs (scripts/planet/poi.gd, another author): Poi.sites_of(planet) -> [{"dir" (body-local
## unit), "near" (the band by the base where the fights are), ...}], built in main.gd at world build
## from the seed. The veins are generated once, lazily (after main._ready: vein_fx.gd waits a frame).
const POI_PATH := "res://scripts/planet/poi.gd"
const REMAIN_TTL_MS := 3000

static var _data := {}          # body instance id -> the generated set (see _generate)
static var _deposits := {}      # meteor id -> deposit (see add_deposit)
static var _bank := 0.0         # vein_bonus: m³ still to pay out on this machine...
static var _paid := 0.0         # ...and paid so far
static var _bank_frame := -1
static var _bank_ms := -1
static var _had_poi := false    # (_contested -> _generate)


# --- Lookup -------------------------------------------------------------------------------------

## The soil multiplier at a world point of `body` (1 = ordinary soil). See the header.
static func mult_at(body: Node3D, world_point: Vector3) -> float:
	if body == null or not is_instance_valid(body):
		return 1.0
	var best := 1.0
	var d := _set_of(body)
	var p := world_point - body.global_position
	if not d.is_empty():
		var lp := p.length()
		if lp >= float(d["rmin"]) and lp <= float(d["rmax"]):
			var a: PackedVector3Array = d["a"]
			var b: PackedVector3Array = d["b"]
			var r: PackedFloat32Array = d["r"]
			var m: PackedFloat32Array = d["m"]
			var mid: PackedVector3Array = d["mid"]
			var b2: PackedFloat32Array = d["bound2"]
			for i in a.size():
				if p.distance_squared_to(mid[i]) > b2[i]:
					continue
				var k := _edge_k(_seg_dist(p, a[i], b[i]) - r[i])
				if k > 0.0:
					best = maxf(best, 1.0 + (m[i] - 1.0) * k)
	if not _deposits.is_empty():
		var bid := body.get_instance_id()
		for id in _deposits:
			var dp: Dictionary = _deposits[id]
			if int(dp["bid"]) != bid:
				continue
			var k := _edge_k(p.distance_to(dp["c"]) - float(dp["r"]))
			if k > 0.0:
				best = maxf(best, 1.0 + (float(dp["m"]) - 1.0) * k)
	return best


## What lies at a world point: {} (ordinary soil) or the strongest vein / core there (see the header).
static func info_at(body: Node3D, world_point: Vector3) -> Dictionary:
	if body == null or not is_instance_valid(body):
		return {}
	var out := {}
	var best := 1.0
	var d := _set_of(body)
	var p := world_point - body.global_position
	if not d.is_empty():
		var a: PackedVector3Array = d["a"]
		var b: PackedVector3Array = d["b"]
		var r: PackedFloat32Array = d["r"]
		var m: PackedFloat32Array = d["m"]
		var mid: PackedVector3Array = d["mid"]
		var b2: PackedFloat32Array = d["bound2"]
		var kinds: PackedByteArray = d["kind"]
		for i in a.size():
			if p.distance_squared_to(mid[i]) > b2[i]:
				continue
			var k := _edge_k(_seg_dist(p, a[i], b[i]) - r[i])
			var v := 1.0 + (m[i] - 1.0) * k
			if k > 0.0 and v > best:
				best = v
				out = {"mult": v, "full": m[i], "kind": int(kinds[i]), "i": i}
	var bid := body.get_instance_id()
	for id in _deposits:
		var dp: Dictionary = _deposits[id]
		if int(dp["bid"]) != bid:
			continue
		var k := _edge_k(p.distance_to(dp["c"]) - float(dp["r"]))
		var v := 1.0 + (float(dp["m"]) - 1.0) * k
		if k > 0.0 and v > best:
			best = v
			out = {"mult": v, "full": float(dp["m"]), "kind": KIND_METEOR, "i": int(id)}
	return out


## Optional drill slow-down inside a vein (VEIN_DRILL_K) so the jackpot lasts; 1 elsewhere.
static func drill_rate_k(body: Node3D, world_point: Vector3) -> float:
	return Balance.VEIN_DRILL_K if mult_at(body, world_point) > 1.5 else 1.0


## Optional drill credit (the digger's machine; INSTEAD of `credit *= mult_at`, then
## `credit += Veins.vein_bonus(body, point, soil, delta)`): a brush that dug (soil > 0) at a vein / core
## banks the share of it that just turned to air (re-sampled now) × its volume × (mult − 1) — a core:
## × its amount — and the bank pays out at most VEIN_BONUS_RATE m³/s; returns this frame's payout.
## Exactly the vein's worth whatever the brush size (no over-credit from soil around it). Why: the
## per-frame cap (DRILL_MAX_RATE × delta ≈ 0.2 m³ at 60 Hz) meets whole-voxel soil (1 m³ steps), so
## `min(soil, cap) × mult` pays ~25-40 % of a vein (probe: a ×10 vein of 28 m³ -> +67..105 m³).
## Drained once per physics frame by whoever calls first (call it with soil 0 every frame to keep it
## streaming after the trigger is released).
static func vein_bonus(body: Node3D, world_point: Vector3, soil: float, delta: float) -> float:
	if soil > 0.0 and body != null and is_instance_valid(body):
		var inf := info_at(body, world_point)
		if not inf.is_empty():
			var gain := take_gain(body, int(inf["kind"]), int(inf["i"]))
			if gain > 0.0:
				_bank += gain
				_bank_ms = Time.get_ticks_msec()
	var f := Engine.get_physics_frames()
	if f == _bank_frame or _bank <= 0.0:
		return 0.0
	_bank_frame = f
	var pay := minf(_bank, Balance.VEIN_BONUS_RATE * maxf(delta, 0.0))
	_bank -= pay
	_paid += pay
	return pay


## The extra worth (m³ beyond the plain soil) of the share of vein i (KIND_METEOR: core i) that
## turned to air since its last sample, re-sampled now: a vein × its volume × (mult − 1), a core × its
## amount − its volume. Call it right after your own brush (vein_bonus; the rival bots, ai_rival.gd
## "Prospecting"): whoever samples first after a dig takes that share.
static func take_gain(body: Node3D, kind: int, i: int) -> float:
	if kind == KIND_METEOR:
		var dp = _deposits.get(i)
		if not (dp is Dictionary):
			return 0.0
		var before := float(dp["rem"])
		dp["dirty"] = true
		var now := deposit_remaining(i)
		var vol := below_floor_volume(float(dp["r"]), float(dp["floor"]))
		return maxf(before - now, 0.0) * maxf(float(dp["amount"]) - vol, 0.0)
	if body == null or not is_instance_valid(body):
		return 0.0
	var d := _set_of(body)
	if d.is_empty() or i < 0 or i >= (d["rem"] as Array).size():
		return 0.0
	var before := float((d["rem"] as Array)[i])
	(d["dirty"] as Array)[i] = true
	var now := remaining(body, i)
	return maxf(before - now, 0.0) * vein_volume(body, i) * (float((d["m"] as PackedFloat32Array)[i]) - 1.0)


## The vein bonus still to be paid out (m³) and the total paid so far (vein_fx.gd: the chime ladder).
static func bank() -> float:
	return _bank


static func bank_paid() -> float:
	return _paid


## ms of the last deposit into the bank (-1: none yet).
static func bank_fed_ms() -> int:
	return _bank_ms


static func clear_bank() -> void:
	_bank = 0.0
	_paid = 0.0
	_bank_ms = -1


## The vein set of a planet with world positions (for the scanner, the HUD and the bots).
static func veins(body: Node3D) -> Array:
	var out: Array = []
	if body == null or not is_instance_valid(body):
		return out
	var d := _set_of(body)
	if d.is_empty():
		return out
	var c := body.global_position
	var a: PackedVector3Array = d["a"]
	var b: PackedVector3Array = d["b"]
	var r: PackedFloat32Array = d["r"]
	var m: PackedFloat32Array = d["m"]
	var kinds: PackedByteArray = d["kind"]
	var top: PackedFloat32Array = d["top"]
	for i in a.size():
		out.append({"i": i, "a": c + a[i], "b": c + b[i], "c": c + (a[i] + b[i]) * 0.5, "r": r[i], "mult": m[i],
				"kind": int(kinds[i]), "rich": int(kinds[i]) == KIND_RICH, "top": top[i]})
	return out


## Forgets the generated sets (vein_fx.gd on its first frame: a new world / match). Deterministic, so
## they come back identical unless the world changed.
static func reset() -> void:
	_data.clear()
	clear_bank()


## The still-solid sample point of vein i (KIND_METEOR: of core id i) nearest `from` (world), or
## Vector3.INF when it is dug out (cheap: reads the edit grid only). The rival bots dig toward it.
static func solid_point_near(body: Node3D, kind: int, i: int, from: Vector3) -> Vector3:
	if body == null or not is_instance_valid(body):
		return Vector3.INF
	var pts := PackedVector3Array()
	if kind == KIND_METEOR:
		var dp = _deposits.get(i)
		if not (dp is Dictionary):
			return Vector3.INF
		pts = dp["samples"]
	else:
		var d := _set_of(body)
		if d.is_empty() or i < 0 or i >= (d["samples"] as Array).size():
			return Vector3.INF
		pts = (d["samples"] as Array)[i]
	var c := body.global_position
	var edits = body.get("edits")
	var best := Vector3.INF
	var bd := INF
	for p in pts:
		var solid := true
		if edits is Dictionary:
			var v := Vector3i(p.round())
			var arr = (edits as Dictionary).get(Vector3i(v.x >> 4, v.y >> 4, v.z >> 4))
			if arr != null:
				var e: float = (arr as PackedFloat32Array)[(v.x & 15) | ((v.y & 15) << 4) | ((v.z & 15) << 8)]
				solid = e >= TerrainGen.NO_EDIT * 0.5 or e < 0.0
		if not solid:
			continue
		var w := c + p
		var dd := w.distance_squared_to(from)
		if dd < bd:
			bd = dd
			best = w
	return best


## Number of veins of a planet (0 until its generator is up).
static func count(body: Node3D) -> int:
	if body == null or not is_instance_valid(body):
		return 0
	var d := _set_of(body)
	return 0 if d.is_empty() else (d["a"] as PackedVector3Array).size()


## 0..1 share of vein i still solid (local estimate from the edits; cached).
static func remaining(body: Node3D, i: int) -> float:
	if body == null or not is_instance_valid(body):
		return 0.0
	var d := _set_of(body)
	if d.is_empty():
		return 0.0
	var rem: Array = d["rem"]
	if i < 0 or i >= rem.size():
		return 0.0
	var ms: Array = d["rem_ms"]
	var dirty: Array = d["dirty"]
	var now := Time.get_ticks_msec()
	if bool(dirty[i]) or now - int(ms[i]) > REMAIN_TTL_MS:
		rem[i] = _solid_share(body, (d["samples"] as Array)[i])
		ms[i] = now
		dirty[i] = false
	return float(rem[i])


## Volume (m³) of vein i (its capsule).
static func vein_volume(body: Node3D, i: int) -> float:
	var d := _set_of(body)
	if d.is_empty() or i < 0 or i >= (d["r"] as PackedFloat32Array).size():
		return 0.0
	var r := float((d["r"] as PackedFloat32Array)[i])
	var L := (d["a"] as PackedVector3Array)[i].distance_to((d["b"] as PackedVector3Array)[i])
	return PI * r * r * L + 4.0 / 3.0 * PI * r * r * r


## Shader strength for a remaining share: full glow until VEIN_GLOW_FULL is left, out when spent.
static func glow(rem: float) -> float:
	if rem < Balance.VEIN_SPENT:
		return 0.0
	return clampf(rem / Balance.VEIN_GLOW_FULL, 0.0, 1.0)


## A brush of `radius` at world_center touched `body`: the veins / cores it reached re-sample.
static func mark_edit(body: Node3D, world_center: Vector3, radius: float) -> void:
	if body == null or not is_instance_valid(body):
		return
	var bid := body.get_instance_id()
	var p := world_center - body.global_position
	var d = _data.get(bid)
	if d is Dictionary and int((d as Dictionary)["seed"]) == int(body.get("seed_value")):
		var mid: PackedVector3Array = d["mid"]
		var bnd: PackedFloat32Array = d["bound"]
		var dirty: Array = d["dirty"]
		for i in mid.size():
			var reach := bnd[i] + radius + 1.0
			if p.distance_squared_to(mid[i]) < reach * reach:
				dirty[i] = true
	for id in _deposits:
		var dp: Dictionary = _deposits[id]
		if int(dp["bid"]) == bid and p.distance_to(dp["c"]) < float(dp["r"]) + radius + 1.0:
			dp["dirty"] = true


## Body-local unit directions of a planet's contested zones (see the header).
static func contested_dirs(body: Node3D) -> Array:
	if body == null or not is_instance_valid(body):
		return []
	var d := _set_of(body)
	return [] if d.is_empty() else (d["centres"] as Array).duplicate()


# --- Meteor cores -------------------------------------------------------------------------------

## Registers a meteor core: a sphere of `radius` at world_center worth × mult. floor_off: the crater
## floor lies this many m above the centre along "up" (only the part below it counts as the core's
## remaining soil).
static func add_deposit(id: int, body: Node3D, world_center: Vector3, radius: float, mult: float, amount: float,
		floor_off := 0.5) -> void:
	if body == null or not is_instance_valid(body):
		return
	var c := world_center - body.global_position
	var up := c.normalized() if c.length_squared() > 1e-6 else Vector3.UP
	var pts := PackedVector3Array()
	var steps := 4
	for z in range(-steps, steps + 1):
		for y in range(-steps, steps + 1):
			for x in range(-steps, steps + 1):
				var o := Vector3(x, y, z) / float(steps) * radius * 0.92
				if o.length() > radius * 0.92 or o.dot(up) > floor_off - 0.15:
					continue
				pts.append(c + o)
	_deposits[id] = {"id": id, "bid": body.get_instance_id(), "body": body, "c": c, "r": radius, "m": mult,
			"amount": amount, "up": up, "floor": floor_off, "samples": pts, "rem": _solid_share(body, pts), "dirty": false,
			"ms": Time.get_ticks_msec()}


static func remove_deposit(id: int) -> void:
	_deposits.erase(id)


static func clear_deposits() -> void:
	_deposits.clear()


static func has_deposit(id: int) -> bool:
	return _deposits.has(id)


## The registered cores (of `body`, or all), world positions now.
static func deposits(body: Node3D = null) -> Array:
	var out: Array = []
	for id in _deposits:
		var dp: Dictionary = _deposits[id]
		var b = dp["body"]
		if not is_instance_valid(b) or (body != null and b != body):
			continue
		out.append({"id": int(id), "body": b, "pos": (b as Node3D).global_position + (dp["c"] as Vector3), "r": dp["r"],
				"mult": dp["m"], "amount": dp["amount"], "rem": deposit_remaining(int(id)), "up": dp["up"]})
	return out


## 0..1 of a core still solid under its crater floor (0 when unknown).
static func deposit_remaining(id: int) -> float:
	var dp = _deposits.get(id)
	if not (dp is Dictionary):
		return 0.0
	var b = dp["body"]
	if not is_instance_valid(b):
		return 0.0
	var now := Time.get_ticks_msec()
	if bool(dp["dirty"]) or now - int(dp["ms"]) > REMAIN_TTL_MS:
		dp["rem"] = _solid_share(b, dp["samples"])
		dp["ms"] = now
		dp["dirty"] = false
	return float(dp["rem"])


## Volume (m³) of a sphere of radius r below a plane floor_off above its centre.
static func below_floor_volume(r: float, floor_off: float) -> float:
	var h := clampf(r - floor_off, 0.0, 2.0 * r)        # height of the cap above the plane
	return 4.0 / 3.0 * PI * r * r * r - PI * h * h * (3.0 * r - h) / 3.0


# --- Generation ---------------------------------------------------------------------------------

static func _set_of(body: Node3D) -> Dictionary:
	var id := body.get_instance_id()
	var d = _data.get(id)
	if d is Dictionary and int((d as Dictionary)["seed"]) == int(body.get("seed_value")):
		# Made before the combat POIs existed: look for them once a second, regenerate when they appear.
		if not bool(d["poi"]) and Time.get_ticks_msec() - int(d["poi_ms"]) > 1000:
			d["poi_ms"] = Time.get_ticks_msec()
			var pd := _poi_dirs(body)
			if (pd[0] as Array).is_empty() and (pd[1] as Array).is_empty():
				return d
		else:
			return d
	if body.get("gen") == null or not body.has_method("surface_height_at"):
		return {}                              # the planet is not set up yet (planet.gd _ready): no cache
	for k in _data.keys():
		if not is_instance_id_valid(int(k)):
			_data.erase(k)
	var nd := _generate(body)
	_data[id] = nd
	return nd


static func _seed_for(seed_v: int, preset: String) -> int:
	var tag := 0
	for ch in preset.to_ascii_buffer():
		tag = (tag * 31 + int(ch)) & 0xFFFF
	return (seed_v * 92821 + tag * 6151 + 0x5EED) & 0x7FFFFFFF


static func _generate(body: Node3D) -> Dictionary:
	var R := float(body.get("radius"))
	var seed_v := int(body.get("seed_value"))
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_for(seed_v, str(body.get("preset_name")))
	# (Plain Arrays while building: a packed array read out of a Dictionary is a copy.)
	var g := {"a": [], "b": [], "r": [], "m": [], "kind": [], "mid": [], "bound": [], "top": [], "samples": []}
	var centres := _contested(body, rng)
	# Rich veins first (in the contested zones), then the ordinary ones anywhere.
	var n_rich := rng.randi_range(Balance.RICH_COUNT_MIN, Balance.RICH_COUNT_MAX)
	for k in n_rich:
		var cdir: Vector3 = centres[k % centres.size()]
		for attempt in 10:
			var dir := _jitter(cdir, rng.randf_range(1.5, Balance.RICH_SPREAD) / maxf(R, 1.0), rng)
			if _try_add(g, body, R, rng, dir, true):
				break
	var n := rng.randi_range(Balance.VEIN_COUNT_MIN, Balance.VEIN_COUNT_MAX)
	for k in n:
		for attempt in 10:
			if _try_add(g, body, R, rng, _rand_dir(rng), false):
				break
	var mid := PackedVector3Array(g["mid"])
	var bnd := PackedFloat32Array(g["bound"])
	var b2 := PackedFloat32Array()
	var rmin := INF
	var rmax := 0.0
	for i in mid.size():
		b2.append(bnd[i] * bnd[i])
		rmin = minf(rmin, mid[i].length() - bnd[i])
		rmax = maxf(rmax, mid[i].length() + bnd[i])
	var cnt := mid.size()
	var rem: Array = []
	var ms: Array = []
	var dirty: Array = []
	var now := Time.get_ticks_msec()
	for i in cnt:
		rem.append(_solid_share(body, (g["samples"] as Array)[i]))      # (already dug parts, e.g. a POI stamp)
		ms.append(now)
		dirty.append(false)
	return {"seed": seed_v, "radius": R, "a": PackedVector3Array(g["a"]), "b": PackedVector3Array(g["b"]),
			"r": PackedFloat32Array(g["r"]), "m": PackedFloat32Array(g["m"]), "kind": PackedByteArray(g["kind"]),
			"mid": mid, "bound": bnd, "bound2": b2, "top": PackedFloat32Array(g["top"]), "samples": g["samples"],
			"rmin": rmin if cnt > 0 else 0.0, "rmax": rmax, "rem": rem, "rem_ms": ms, "dirty": dirty, "centres": centres,
			"poi": _had_poi, "poi_ms": Time.get_ticks_msec()}


## One vein along a random axis under `dir`; false when it would overlap another (or the core).
static func _try_add(g: Dictionary, body: Node3D, R: float, rng: RandomNumberGenerator, dir: Vector3, rich: bool) -> bool:
	var lr: Vector2 = Balance.RICH_LEN if rich else Balance.VEIN_LEN
	var rr: Vector2 = Balance.RICH_R if rich else Balance.VEIN_R
	var dr: Vector2 = Balance.RICH_DEPTH if rich else Balance.VEIN_DEPTH
	var L := rng.randf_range(lr.x, lr.y)
	var r := rng.randf_range(rr.x, rr.y)
	var depth := lerpf(dr.x, dr.y, pow(rng.randf(), 1.6))          # shallow ones more often
	var mult := float(rng.randi_range(Balance.RICH_MULT_MIN, Balance.RICH_MULT_MAX) if rich \
			else rng.randi_range(Balance.VEIN_MULT_MIN, Balance.VEIN_MULT_MAX))
	var up := dir
	var t1 := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := up.cross(t1)
	var th := rng.randf() * TAU
	var tilt := rng.randf_range(-0.6, 0.6)
	var axis := ((t1 * cos(th) + t2 * sin(th)) * cos(tilt) + up * sin(tilt)).normalized()
	var c := dir * (_surf_r(body, R, dir) - depth)
	var a := c - axis * L * 0.5
	var b := c + axis * L * 0.5
	# At least VEIN_COVER of original soil over the top: the whole capsule goes down if an end sticks up.
	var top := minf(_depth_of(body, R, a), _depth_of(body, R, b)) - r
	if top < Balance.VEIN_COVER:
		var s := Balance.VEIN_COVER - top
		a -= up * s
		b -= up * s
		c -= up * s
		top = Balance.VEIN_COVER
	if c.length() - L * 0.5 - r < Balance.CORE_RADIUS + 6.0:
		return false
	var mids: Array = g["mid"]
	var bnds: Array = g["bound"]
	var bound := L * 0.5 + r + Balance.VEIN_EDGE
	for j in mids.size():
		if c.distance_to(mids[j]) < bound + float(bnds[j]) - 1.0:
			return false
	(g["a"] as Array).append(a)
	(g["b"] as Array).append(b)
	(g["r"] as Array).append(r)
	(g["m"] as Array).append(mult)
	(g["kind"] as Array).append(KIND_RICH if rich else KIND_NORMAL)
	mids.append(c)
	bnds.append(bound)
	(g["top"] as Array).append(top)
	(g["samples"] as Array).append(_samples(a, b, r))
	return true


## Points inside a capsule for the remaining share: 5 along the axis, each with 4 around it, + 2 caps.
static func _samples(a: Vector3, b: Vector3, r: float) -> PackedVector3Array:
	var axis := (b - a).normalized() if a.distance_to(b) > 0.01 else Vector3.UP
	var u := axis.cross(Vector3.RIGHT if absf(axis.x) < 0.9 else Vector3.FORWARD).normalized()
	var v := axis.cross(u)
	var out := PackedVector3Array()
	for k in 5:
		var q := a.lerp(b, float(k) / 4.0)
		out.append(q)
		for o: Vector3 in [u, -u, v, -v]:
			out.append(q + o * r * 0.62)
	out.append(a - axis * r * 0.6)
	out.append(b + axis * r * 0.6)
	return out


## Contested zone centres (body-local unit directions). With combat POIs (scripts/planet/poi.gd
## sites_of): the near-band sites (where raiders land and the fights are), the point facing the other
## planet (the front between the two bases), the far sites. Without: the facing point, the approach to
## the base and VEIN_HOTSPOTS random hot spots on the facing half.
static func _contested(body: Node3D, rng: RandomNumberGenerator) -> Array:
	var c := body.global_position
	var other: Node3D = null
	var best := INF
	for o in Bodies.all():
		if o == body or not is_instance_valid(o):
			continue
		var dd := (o as Node3D).global_position.distance_to(c)
		if dd < best:
			best = dd
			other = o
	var facing := (other.global_position - c).normalized() if other != null else Vector3.RIGHT
	# The base (main.gd spawn_transform: facing + sun × 1.15 + world up × 0.1).
	var base := (facing + _sun_dir() * 1.15 + Vector3.UP * 0.1).normalized()
	var poi := _poi_dirs(body)
	var out: Array = []
	_had_poi = not (poi[0] as Array).is_empty() or not (poi[1] as Array).is_empty()
	if _had_poi:
		out.append_array(poi[0])
		out.append(facing)
		out.append_array(poi[1])
		return out
	out.append(facing)
	out.append(facing.slerp(base, 0.5).normalized())
	for k in Balance.VEIN_HOTSPOTS:
		for attempt in 16:
			var d := _rand_dir(rng)
			var ang := d.angle_to(facing)
			if ang > deg_to_rad(25.0) and ang < deg_to_rad(75.0) and d.angle_to(base) > deg_to_rad(20.0):
				out.append(d)
				break
	return out


## The combat POIs of scripts/planet/poi.gd (sites_of: built in main.gd at world build, deterministic
## from the seed) as [near-band dirs, far dirs], body-local units; [[], []] without them.
static func _poi_dirs(body: Node3D) -> Array:
	var near: Array = []
	var far: Array = []
	if not ResourceLoader.exists(POI_PATH):
		return [near, far]
	var s = load(POI_PATH)
	if not (s is Script) or not (s as Script).can_instantiate():
		return [near, far]
	var res = s.call("sites_of", body)
	if not (res is Array):
		return [near, far]
	for e in res:
		if not (e is Dictionary) or not ((e as Dictionary).get("dir") is Vector3):
			continue
		var d: Vector3 = (e as Dictionary)["dir"]
		if d.length_squared() < 0.5:
			continue
		if bool((e as Dictionary).get("near", false)):
			near.append(d.normalized())
		else:
			far.append(d.normalized())
	return [near, far]


## Game.sun_dir (main.gd SUN_DIR), read without naming the autoload (this script may compile first).
static func _sun_dir() -> Vector3:
	var tree := Engine.get_main_loop() as SceneTree
	var g: Node = tree.root.get_node_or_null("Game") if tree != null else null
	var s = g.get("sun_dir") if g != null else null
	return (s as Vector3) if s is Vector3 else Vector3(0.0, 0.35, 1.0).normalized()


static func _surf_r(body: Node3D, R: float, dir: Vector3) -> float:
	return R + float(body.surface_height_at(body.global_position + dir * R))


## Original soil over a body-local point (m; negative above the surface).
static func _depth_of(body: Node3D, R: float, p: Vector3) -> float:
	var l := p.length()
	if l < 0.01:
		return R
	return _surf_r(body, R, p / l) - l


static func _rand_dir(rng: RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var ph := rng.randf() * TAU
	var s := sqrt(maxf(1.0 - z * z, 0.0))
	return Vector3(s * cos(ph), s * sin(ph), z)


## `dir` turned by `ang` rad toward a random tangent.
static func _jitter(dir: Vector3, ang: float, rng: RandomNumberGenerator) -> Vector3:
	var t1 := dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := dir.cross(t1)
	var th := rng.randf() * TAU
	return (dir * cos(ang) + (t1 * cos(th) + t2 * sin(th)) * sin(ang)).normalized()


# --- Helpers ------------------------------------------------------------------------------------

static func _seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 < 1e-6 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## 1 inside (signed distance <= 0), falling linearly to 0 at VEIN_EDGE outside.
static func _edge_k(sd: float) -> float:
	if sd <= 0.0:
		return 1.0
	if sd >= Balance.VEIN_EDGE:
		return 0.0
	return 1.0 - sd / Balance.VEIN_EDGE


## Share of body-local points still solid, read straight from the edit regions (an unedited voxel is
## the original ground: solid there, every sample lies under the original surface).
static func _solid_share(body: Node3D, pts: PackedVector3Array) -> float:
	if pts.is_empty():
		return 0.0
	var edits = body.get("edits")
	if not (edits is Dictionary) or (edits as Dictionary).is_empty():
		return 1.0
	var solid := 0
	for p in pts:
		var v := Vector3i(p.round())
		var arr = (edits as Dictionary).get(Vector3i(v.x >> 4, v.y >> 4, v.z >> 4))
		if arr == null:
			solid += 1
			continue
		var e: float = (arr as PackedFloat32Array)[(v.x & 15) | ((v.y & 15) << 4) | ((v.z & 15) << 8)]
		if e >= TerrainGen.NO_EDIT * 0.5 or e < 0.0:
			solid += 1
	return float(solid) / float(pts.size())
