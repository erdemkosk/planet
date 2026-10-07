extends RefCounted
## Base building (2026-10-05): the shared rules of the base pieces and of the İnşa Aracı's underground
## placement, the blast shelter, the snapping of modular pieces, and the API the rival AI builds with.
## Numbers: the "BASE BUILDING" block at the end of scripts/war/balance.gd.
##
## Pieces (entry id = script file name = Balance.BASE_BUILD_SITE / BUILD_UNDERGROUND key; all extend
## scripts/war/base_piece.gd, groups "damageable", "war_structure", "war_base" + their own):
##   bunker_module  Sığınak Modülü    "war_bunker"       armor_wall   Takviyeli Duvar   "war_wall"
##   blast_door     Zırhlı Kapı       "war_blast_door"   sentry_turret Otomatik Taret   "war_turret"
##   core_shield    Çekirdek Kalkanı  "war_core_shield"  radar_tower  Radar Kulesi      "war_radar"
##   light_post     Işık Direği       "war_light"
##
## Underground: a spot with soil straight over it within Balance.UNDERGROUND_PROBE m is COVERED (a
## tunnel, a cavern, under an overhang). Only BUILD_UNDERGROUND entries may stand there; their box must
## fit the cavity: every one of the 9 footprint samples (corners, edge middles, centre) starts in air
## just over the floor ("Yer dar — biraz daha kaz" otherwise), the floor spread stays within the
## piece's step tolerance, and the ceiling (density march AND the terrain collision ray) clears the
## structure's height ("Tavan çok alçak — biraz daha kaz").
## Blast shelter: Explosion's area damage on a structure is cut by the soil between the blast and the
## structure (blast_shelter): bots / players are not affected, cores take theirs through Core.blast_all.
##
##   BaseKit.cover_above(body, p, up) -> float            m to the soil over p (INF: open sky)
##   BaseKit.cavity_fit(node, body, p, up, rb, half, need) -> {"ok", "reason", "lowest", "highest", "ceiling"}
##   BaseKit.soil_between(body, a, b, skip_c, skip_r) -> float   m of soil on the segment
##   BaseKit.blast_shelter(target, center, bite, normal) -> 0..1
##   BaseKit.snap(kind, p, team, tree) -> {} or {"xf", "target", "guides"}   modular pieces
##   BaseKit.overlap_reason(kind, xf, r, tree, player_pos) -> ""             exact boxes for modular pieces
##   BaseKit.rule_reason(kind, xf, team, tree) -> ""        core shield: near the own core, one per side
##   BaseKit.net_build_reason(script_path, xf, team, tree) -> ""   (multiplayer host, net_world)
##   BaseKit.half_of(kind) / radius_of(kind) / height_of(kind) / step_tol(kind) / base_k(kind)
## AI (scripts/war/ai_rival.gd / rival_team.gd):
##   BaseKit.suggest_spot(kind, team, near) -> {"ok", "xf", "body", "underground", "needs_dig",
##       "dig_points", "dig_radius", "reason"}        a buildable spot near `near` (the core shield: in a
##       chamber over the team's own core; needs_dig = carve it first: dig_points / carve_for)
##   BaseKit.carve_for(kind, body, xf, team) -> float     digs the room the piece needs (host; synced)
##   BaseKit.spawn(kind, team, xf, body := null, animate := true, owner_peer := 0) -> Node3D
##       (any build kind: the pieces above and cannon / flak / buster / armory / torpedo_rig / auto_miner)
##   BaseKit.cost_of(kind) -> float                        material (the AI pays it from its pool)
##   BaseKit.blocking_door(from, to, team) -> Node3D       a closed ENEMY door across the segment (bots
##       cannot pass it: stop and shoot it), or null
## Undo / sell (build tool Z / X, 2026-10-06):
##   BaseKit.display_name(kind) -> String                   "Top", "Uçaksavar", "Sığınak Modülü"…
##   BaseKit.structure_of(collider) -> Node3D               the war structure a collider belongs to
##   BaseKit.unbuild_reason(node, refund_k, team) -> String "" = it may be taken down now (own team, not
##       in use; refund_k >= 1 = an undo: only within Balance.UNDO_TIME s of its build)
##   BaseKit.refund_of(node, refund_k) -> float             meta "build_cost" (else cost_of) × refund_k
##   BaseKit.deconstruct(node, fx := true)                  quiet removal: out of every group, colliders
##       off, logic stopped, a reverse print (the parts sink and shrink into the ground, dust, a ring),
##       then freed; meta "deconstructed" (the network sends it as a removal, not a destruction)
## Structures built by the tool (or a client's request on the host) carry the metas "build_cost" (m³
## paid), "built_ms" (Time msec) and "builder" (the player's name, "" in single player).

const Balance := preload("res://scripts/war/balance.gd")
const Foundation := preload("res://scripts/war/foundation.gd")
const Dig := preload("res://scripts/player/dig.gd")

const BASE_PATH := "res://scripts/war/base_piece.gd"
## Base pieces: entry id -> script.
const PIECES := {"bunker_module": "res://scripts/war/bunker_module.gd",
		"armor_wall": "res://scripts/war/armor_wall.gd", "blast_door": "res://scripts/war/blast_door.gd",
		"sentry_turret": "res://scripts/war/sentry_turret.gd", "core_shield": "res://scripts/war/core_shield.gd",
		"radar_tower": "res://scripts/war/radar_tower.gd", "light_post": "res://scripts/war/light_post.gd"}
## The older structures (each has its own static spawn(parent, body, xf, team, animate)).
const LEGACY := {"cannon": "res://scripts/war/cannon.gd", "flak": "res://scripts/war/flak.gd",
		"buster": "res://scripts/war/buster.gd", "armory": "res://scripts/war/armory.gd",
		"torpedo_rig": "res://scripts/war/torpedo_rig.gd", "auto_miner": "res://scripts/war/auto_miner.gd"}
## Pieces whose boxes are tested exactly against each other (they join edge to edge) and that snap.
const MODULAR := ["bunker_module", "armor_wall", "blast_door"]
## Small pieces that may stand INSIDE a Sığınak Modülü.
const INNER_OK := ["sentry_turret", "light_post"]
## Allowed floor spread (m, lowest to highest footprint sample) and where the base sits in it (0 = on
## the lowest sample), for the build tool's _validate (STEP_TOL / BASE_K fall back to these) and the AI.
const STEP_TOL := {"bunker_module": 1.1, "armor_wall": 1.0, "blast_door": 0.9, "sentry_turret": 1.6,
		"radar_tower": 1.6, "light_post": 2.5, "core_shield": 1.5}
const BASE_K := {"bunker_module": 0.5, "armor_wall": 0.35, "blast_door": 0.3, "sentry_turret": 0.4,
		"radar_tower": 0.4, "light_post": 0.0, "core_shield": 0.4}
const WALL_T := 0.45                   # armor_wall thickness (its footprint z)
const MODULE_HALF := 2.0               # bunker_module outer half size
const MODULE_WALL := 0.3               # bunker_module wall thickness

static var _halves := {}
## The structure overlap_reason() found in the way last (for the build tool's red highlight).
static var last_blocker: Node3D = null
## Multiplayer host (scripts/net/net_world.gd, the MP agent): called with the node at the START of a
## deconstruct on the host / in single player, to send the quiet removal to the client at once.
static var deconstruct_hook: Callable = Callable()


# =================================================================================================
# Kinds
# =================================================================================================

static func is_piece_path(path: String) -> bool:
	return PIECES.values().has(path)


## Entry id of a structure node ("" when unknown).
static func kind_of(n: Object) -> String:
	if n == null or not is_instance_valid(n):
		return ""
	if n.has_method("piece_kind"):
		return str(n.call("piece_kind"))
	var s = n.get_script()
	return (s as Script).resource_path.get_file().get_basename() if s is Script else ""


## Half extents of a kind's placement box (x, z half sizes; y = half the height).
static func half_of(kind: String) -> Vector3:
	if _halves.has(kind):
		return _halves[kind]
	var h := Vector3(1.5, 1.5, 1.5)
	match kind:
		"cannon":
			h = Vector3(2.5, 1.7, 2.5)
		"flak":
			h = Vector3(1.9, 1.4, 1.9)
		"buster":
			h = Vector3(2.7, 1.6, 2.7)
		"armory":
			h = Vector3(3.0, 1.8, 2.6)
		_:
			var path := str(PIECES.get(kind, LEGACY.get(kind, "")))
			if path != "" and ResourceLoader.exists(path):
				var s = load(path)
				if s is Script:
					for m in (s as Script).get_script_method_list():
						if str(m.get("name", "")) == "footprint":
							h = s.call("footprint")
							break
	_halves[kind] = h
	return h


## Footprint radius kept clear around a kind (the build tool's "radius").
static func radius_of(kind: String) -> float:
	match kind:
		"bunker_module":
			return Balance.BUNKER_FOOTPRINT
		"armor_wall":
			return Balance.WALL_FOOTPRINT
		"blast_door":
			return Balance.DOOR_FOOTPRINT
		"sentry_turret":
			return Balance.TURRET_FOOTPRINT
		"core_shield":
			return Balance.CORE_SHIELD_FOOTPRINT
		"radar_tower":
			return Balance.RADAR_FOOTPRINT
		"light_post":
			return Balance.LIGHT_FOOTPRINT
		"cannon":
			return Balance.CANNON_FOOTPRINT
		"flak":
			return Balance.FLAK_FOOTPRINT
		"buster":
			return Balance.BUSTER_FOOTPRINT
		"armory":
			return Balance.ARMORY_FOOTPRINT
		"torpedo_rig":
			return Balance.TORPEDO_RIG_FOOTPRINT
		"auto_miner":
			return Balance.MINER_FOOTPRINT
	var h := half_of(kind)
	return maxf(h.x, h.z)


## Clear height a kind needs over its base (m).
static func height_of(kind: String) -> float:
	return half_of(kind).y * 2.0 + Balance.HEADROOM_MARGIN


static func step_tol(kind: String) -> float:
	return float(STEP_TOL.get(kind, Balance.BUILD_MAX_STEP))


static func base_k(kind: String) -> float:
	return float(BASE_K.get(kind, 0.0))


static func cost_of(kind: String) -> float:
	match kind:
		"bunker_module":
			return Balance.BUNKER_COST
		"armor_wall":
			return Balance.WALL_COST
		"blast_door":
			return Balance.DOOR_COST
		"sentry_turret":
			return Balance.TURRET_COST
		"core_shield":
			return Balance.CORE_SHIELD_COST
		"radar_tower":
			return Balance.RADAR_COST
		"light_post":
			return Balance.LIGHT_COST
		"cannon":
			return Balance.CANNON_COST
		"flak":
			return Balance.FLAK_COST
		"buster":
			return Balance.BUSTER_COST
		"armory":
			return Balance.ARMORY_COST
		"torpedo_rig":
			return Balance.TORPEDO_RIG_COST
		"auto_miner":
			return Balance.MINER_COST
	return 0.0


## The core of `team` (group "war_core"), or null.
static func own_core(team: String, tree: SceneTree) -> Node3D:
	if tree == null:
		return null
	for c in tree.get_nodes_in_group("war_core"):
		if c is Node3D and Game.team_of(c) == team:
			return c
	return null


# =================================================================================================
# Underground
# =================================================================================================

## Distance (m) from p straight up (along up) to the soil over it; INF = open sky within `probe`.
static func cover_above(body: Node3D, p: Vector3, up: Vector3, probe := Balance.UNDERGROUND_PROBE) -> float:
	if body == null or not is_instance_valid(body) or not body.has_method("raycast_density"):
		return INF
	var a := p + up * 0.3
	var h: Dictionary = body.raycast_density(a, p + up * probe, 0.4)
	if h.is_empty():
		return INF
	return float(h["distance"]) + 0.3


## The floor of a cavity under a point in its air (a wall / ceiling hit stepped back into the room):
## {"position", "normal"} or {}.
static func floor_below(body: Node3D, p: Vector3, up: Vector3, depth := 7.0) -> Dictionary:
	if body == null or not body.has_method("raycast_density"):
		return {}
	if float(body.density_at(p)) < 0.0:
		return {}
	return body.raycast_density(p, p - up * depth, 0.25)


## Underground fit of a box footprint (half.x / half.z, rotated by rb: basis with y = up) on a cavity
## floor around p: the 9 samples (corners and edge middles at 0.92 × the half size, the centre). Each
## must be AIR Balance.UNDERGROUND_LIFT m over p's level (else the cavity is too narrow there); its
## floor comes from Foundation.ground_offset (the terrain collision, else the exact density); its ceiling
## from the density march AND the terrain physics ray (the nearer), searched up to `need` + 2 m over
## that floor. Offsets are relative to p along up; "ceiling" = the lowest ceiling offset (INF: none).
## node: for the physics queries (null: density only, e.g. the AI far from the camera).
static func cavity_fit(node: Node3D, body: Node3D, p: Vector3, up: Vector3, rb: Basis, half: Vector3, need: float) -> Dictionary:
	var out := {"ok": false, "reason": "", "lowest": 0.0, "highest": 0.0, "ceiling": INF}
	if body == null or not is_instance_valid(body) or not body.has_method("density_at"):
		out["reason"] = "Gezegen üzerinde değil"
		return out
	var space: PhysicsDirectSpaceState3D = null
	if node != null and node.is_inside_tree():
		space = node.get_world_3d().direct_space_state
	var lift := Balance.UNDERGROUND_LIFT
	var lowest := INF
	var highest := -INF
	var ceiling := INF
	for i in 9:
		var lp := Vector3(float(i % 3 - 1) * half.x * 0.92, 0.0, float(floori(i / 3.0) - 1) * half.z * 0.92)
		var s := p + rb * lp
		if float(body.density_at(s + up * lift)) < 0.0:
			out["reason"] = "Yer dar — biraz daha kaz"
			return out
		var off := Foundation.ground_offset(node, body, s, up, lift, 4.0)
		if is_inf(off):
			out["reason"] = "Zemin düz değil"
			return out
		lowest = minf(lowest, off)
		highest = maxf(highest, off)
		var f0 := s + up * (off + 0.15)
		var reach := need + 2.0
		var c := INF
		var h: Dictionary = body.raycast_density(f0, f0 + up * reach, 0.4)
		if not h.is_empty():
			c = float(h["distance"])
		if space != null:
			var q := PhysicsRayQueryParameters3D.create(f0, f0 + up * reach, Game.LAYER_TERRAIN)
			var ph := space.intersect_ray(q)
			if not ph.is_empty():
				c = minf(c, f0.distance_to(ph["position"]))
		if not is_inf(c):
			ceiling = minf(ceiling, off + 0.15 + c)
	out["ok"] = true
	out["lowest"] = lowest
	out["highest"] = highest
	out["ceiling"] = ceiling
	return out


# =================================================================================================
# Blast shelter
# =================================================================================================

## Metres of soil on the segment a -> b (sampled every SHELTER_STEP m; the cheap density, solid samples
## confirmed with the exact one), not counting what lies within skip_r of skip_c.
static func soil_between(body: Node3D, a: Vector3, b: Vector3, skip_c: Vector3, skip_r: float) -> float:
	if body == null or not is_instance_valid(body) or not body.has_method("density_fast"):
		return 0.0
	var seg := b - a
	var len := seg.length()
	if len < 0.05:
		return 0.0
	var n := maxi(int(ceilf(len / Balance.SHELTER_STEP)), 1)
	var st := len / float(n)
	var dir := seg / len
	var soil := 0.0
	for i in n:
		var q := a + dir * (st * (float(i) + 0.5))
		if skip_r > 0.0 and q.distance_to(skip_c) < skip_r:
			continue
		if float(body.density_fast(q)) < 0.0 and float(body.density_at(q)) < 0.0:
			soil += st
	return soil


## Share (0..1) of a blast at `center` that reaches structure `target` through the soil (Explosion's
## area damage; see Balance "Blast shelter"). bite: the radius of the hole the blast is about to blow
## (its soil does not shelter); normal: the blast's normal (up when unknown).
static func blast_shelter(target: Node3D, center: Vector3, bite: float, normal := Vector3.ZERO) -> float:
	if target == null or not is_instance_valid(target):
		return 1.0
	var body: Node3D = Game.dominant_body(center)
	if body == null or not body.has_method("density_fast"):
		return 1.0
	var up: Vector3 = normal.normalized() if normal.length_squared() > 0.01 else body.up_at(center)
	var from := center + up * Balance.SHELTER_LIFT
	var aim: Vector3 = target.global_position + target.global_transform.basis.y.normalized() * 0.9
	if target.has_method("shelter_point"):
		aim = target.call("shelter_point")
	var to := aim.move_toward(from, 0.3)         # (the structure's own embedding does not count)
	var soil := soil_between(body, from, to, center, bite)
	if soil <= Balance.SHELTER_SOIL_MIN:
		return 1.0
	return clampf(1.0 - soil / Balance.SHELTER_SOIL_BLOCK, 0.0, 1.0)


# =================================================================================================
# Snapping (modular pieces) and overlap
# =================================================================================================

## Where a new `kind` piece may join an existing piece `tk` at transform txf (orthonormal): Transforms.
static func _candidates(kind: String, tk: String, txf: Transform3D) -> Array:
	var out: Array = []
	var b := txf.basis
	match kind:
		"bunker_module":
			if tk == "bunker_module":
				for sz: float in [1.0, -1.0]:                     # doorway to doorway: a corridor
					out.append(Transform3D(b, txf * Vector3(0, 0, MODULE_HALF * 2.0 * sz)))
		"armor_wall":
			if tk == "armor_wall":
				var hx := 1.5
				for sx: float in [1.0, -1.0]:
					out.append(Transform3D(b, txf * Vector3(hx * 2.0 * sx, 0, 0)))         # straight on
					for sz: float in [1.0, -1.0]:                                          # a corner
						out.append(Transform3D(b * Basis(Vector3.UP, PI * 0.5),
								txf * Vector3(sx * (hx - WALL_T * 0.5), 0, sz * (hx + WALL_T * 0.5))))
			elif tk == "bunker_module":
				for sz: float in [1.0, -1.0]:
					# plug a doorway from outside...
					out.append(Transform3D(b, txf * Vector3(0, 0, sz * (MODULE_HALF + WALL_T * 0.5 + 0.01))))
					# ...or a wing wall carrying the front / back face on sideways
					for sx: float in [1.0, -1.0]:
						out.append(Transform3D(b, txf * Vector3(sx * (MODULE_HALF + 1.5), 0, sz * (MODULE_HALF - WALL_T * 0.5))))
		"blast_door":
			if tk == "bunker_module":
				for sz: float in [1.0, -1.0]:
					out.append(Transform3D(b, txf * Vector3(0, 0, sz * (MODULE_HALF - MODULE_WALL * 0.5))))
	return out


## Another base piece already stands within 0.6 m of `o` (a taken doorway / wall end).
static func _occupied(o: Vector3, tree: SceneTree) -> bool:
	for s in tree.get_nodes_in_group("war_base"):
		if s is Node3D and not s.has_meta("build_preview") and s.get("is_destroyed") != true \
				and (s as Node3D).global_position.distance_to(o) < 0.6:
			return true
	return false


## The snap spot nearest to the aim point p (within Balance.BASE_SNAP_DIST) for a modular piece of
## `team`: {"xf", "target", "guides": [the joint points]} or {}.
static func snap(kind: String, p: Vector3, team: String, tree: SceneTree) -> Dictionary:
	if not kind in MODULAR or tree == null:
		return {}
	var best := {}
	var best_d := Balance.BASE_SNAP_DIST
	for s in tree.get_nodes_in_group("war_base"):
		if not (s is Node3D) or s.has_meta("build_preview") or s.get("is_destroyed") == true:
			continue
		if Game.team_of(s) != team:
			continue
		var sx := (s as Node3D).global_transform.orthonormalized()
		for c in _candidates(kind, kind_of(s), sx):
			var cx: Transform3D = c
			var d := cx.origin.distance_to(p)
			if d < best_d and not _occupied(cx.origin, tree):
				best_d = d
				best = {"xf": cx, "target": s, "guides": [sx.origin, cx.origin]}
	return best


## 2D boxes (half.x / half.z around the origin, height 2 × half.y from it) overlap by more than tol.
static func _boxes_overlap(xa: Transform3D, ha: Vector3, xb: Transform3D, hb: Vector3, tol: float) -> bool:
	var up := xa.basis.y.normalized()
	var dy := (xb.origin - xa.origin).dot(up)
	if ha.y * 2.0 - tol <= dy or dy + hb.y * 2.0 - tol <= 0.0:
		return false
	var d := xb.origin - xa.origin
	var axa := xa.basis.x.normalized()
	var aza := xa.basis.z.normalized()
	var axb := xb.basis.x.normalized()
	var azb := xb.basis.z.normalized()
	for axis0: Vector3 in [axa, aza, axb, azb]:
		var axis := axis0 - up * axis0.dot(up)
		if axis.length_squared() < 1e-6:
			continue
		axis = axis.normalized()
		var ra := ha.x * absf(axa.dot(axis)) + ha.z * absf(aza.dot(axis))
		var rb := hb.x * absf(axb.dot(axis)) + hb.z * absf(azb.dot(axis))
		if absf(d.dot(axis)) >= ra + rb - tol:
			return false
	return true


## A door (dk at dxf) sits in a doorway of the module at mxf.
static func _door_in_doorway(dk: String, dxf: Transform3D, mk: String, mxf: Transform3D) -> bool:
	if dk != "blast_door" or mk != "bunker_module":
		return false
	var l := mxf.affine_inverse() * dxf.origin
	return absf(l.x) < 0.35 and absf(absf(l.z) - (MODULE_HALF - MODULE_WALL * 0.5)) < 0.35 and absf(l.y) < 0.6


## "" when a `kind` piece at xf (footprint radius r) is clear of every structure (and of the player at
## player_pos, INF = not checked), else the reason. Modular pieces against each other: exact boxes
## (edge to edge is fine; a door may sit in a module's doorway); small pieces may stand inside a
## Sığınak Modülü; everything else: the footprint circles like before.
static func overlap_reason(kind: String, xf: Transform3D, r: float, tree: SceneTree, player_pos := Vector3.INF) -> String:
	var mod := kind in MODULAR
	var half := half_of(kind)
	last_blocker = null
	for s in tree.get_nodes_in_group("war_structure"):
		if not (s is Node3D) or s.has_meta("build_preview") or s.get("is_destroyed") == true:
			continue
		var sn := s as Node3D
		var sk := kind_of(sn)
		var smod := sk in MODULAR
		var sxf := sn.global_transform.orthonormalized()
		var sr := float(sn.get_meta("footprint_r", 3.0))
		if mod and smod:
			if _door_in_doorway(kind, xf, sk, sxf) or _door_in_doorway(sk, sxf, kind, xf):
				continue
			if _boxes_overlap(xf, half, sxf, half_of(sk), 0.12):
				last_blocker = sn
				return "Başka bir yapıyla çakışıyor"
			continue
		if sk == "bunker_module" and kind in INNER_OK:
			var l := sxf.affine_inverse() * xf.origin
			var inner := MODULE_HALF - MODULE_WALL - 0.05
			if absf(l.x) + r <= inner + 0.35 and absf(l.z) + r <= inner + 0.35 and l.y > -0.6 and l.y < 0.8:
				continue
		if mod or smod:
			# A box (the modular one) against the other's circle (0.6 × its clearance radius: a turret
			# may stand right behind a wall).
			var bx := xf if mod else sxf
			var bh := half if mod else half_of(sk)
			var cp := sn.global_position if mod else xf.origin
			var cr := (sr if mod else r) * 0.6
			var l2 := bx.affine_inverse() * cp
			if absf(l2.x) < bh.x + cr and absf(l2.z) < bh.z + cr and l2.y > -1.5 and l2.y < bh.y * 2.0 + 1.5:
				last_blocker = sn
				return "Başka bir yapıya çok yakın"
			continue
		if sn.global_position.distance_to(xf.origin) < r + sr:
			last_blocker = sn
			return "Başka bir yapıya çok yakın"
	if player_pos != Vector3.INF:
		if mod:
			var lp := xf.affine_inverse() * player_pos
			if absf(lp.x) < half.x + 0.5 and absf(lp.z) < half.z + 0.5 and lp.y > -1.0 and lp.y < half.y * 2.0 + 0.5:
				return "Çok yakınsın — biraz geri çekil"
		elif player_pos.distance_to(xf.origin) < r + 0.6:
			return "Çok yakınsın — biraz geri çekil"
	return ""


## Per-piece rules beyond the site / overlap: the Çekirdek Kalkanı stands near its side's own core
## (Balance.CORE_SHIELD_RANGE from the core's surface), one per side. "" = fine.
static func rule_reason(kind: String, xf: Transform3D, team: String, tree: SceneTree) -> String:
	if kind == "core_shield":
		var core := own_core(team, tree)
		if core == null:
			return "Çekirdek bulunamadı"
		var d := xf.origin.distance_to(core.global_position) - Balance.CORE_RADIUS
		if d > Balance.CORE_SHIELD_RANGE:
			return "Çekirdeğe %d m'den yakın olmalı (şu an %d m) — aşağı kaz" % [int(Balance.CORE_SHIELD_RANGE), int(ceilf(d))]
		for s in tree.get_nodes_in_group("war_core_shield"):
			if Game.team_of(s) == team and s.get("is_destroyed") != true and not s.has_meta("build_preview"):
				return "Takım başına tek Çekirdek Kalkanı"
	return ""


## Multiplayer host: a client's request for a base piece (net_world _validate_build calls this INSTEAD
## of its footprint-radius loop when BaseKit.is_piece_path(script_path); the site rule stays there).
static func net_build_reason(script_path: String, xf: Transform3D, team: String, tree: SceneTree) -> String:
	var kind := script_path.get_file().get_basename()
	var why := rule_reason(kind, xf, team, tree)
	if why != "":
		return why
	return overlap_reason(kind, xf.orthonormalized(), radius_of(kind), tree)


# =================================================================================================
# AI API
# =================================================================================================

## Basis with y = up and -Z (forward) toward `toward` (any tangent when that is straight up).
static func _basis_facing(up: Vector3, toward: Vector3) -> Basis:
	var fwd := toward - up * toward.dot(up)
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	var z := -fwd.normalized()
	var x := up.cross(z).normalized()
	return Basis(x, up, x.cross(up).normalized())


## A buildable spot for `kind` of `team` near world point `near` (on the planet under it), facing the
## other planet. Surface kinds: a spiral of candidates (flat enough by the 9-sample rule, clear of
## structures and of the per-piece rules). The core shield: a chamber floor just over the team's own
## core on the side of `near`; "needs_dig" says the room is not dug yet (carve it: carve_for, or let
## a bot dig dig_points with dig_radius). Returns {"ok", "xf", "body", "underground", "needs_dig",
## "dig_points", "dig_radius", "reason"}.
static func suggest_spot(kind: String, team: String, near: Vector3) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var body: Node3D = Game.dominant_body(near)
	var out := {"ok": false, "xf": Transform3D(), "body": body, "underground": false, "needs_dig": false,
			"dig_points": [], "dig_radius": 0.0, "reason": ""}
	if body == null or not body.has_method("raycast_density"):
		out["reason"] = "Gezegen yok"
		return out
	var c: Vector3 = body.global_position
	var other: Node3D = Game.rival if body == Game.planet else Game.planet
	var half := half_of(kind)
	var r := radius_of(kind)
	if kind == "core_shield":
		var core := own_core(team, tree)
		if core == null:
			out["reason"] = "Çekirdek bulunamadı"
			return out
		var cc := core.global_position
		var up: Vector3 = (near - cc).normalized() if near.distance_to(cc) > 0.5 else body.up_at(cc + Vector3.UP)
		var fp: Vector3 = cc + up * (Balance.CORE_RADIUS + 3.0)
		var b := _basis_facing(up, (other.global_position - fp) if other != null else Vector3.ZERO)
		var xf := Transform3D(b, fp)
		out["xf"] = xf
		out["underground"] = true
		var why := rule_reason(kind, xf, team, tree)
		if why != "":
			out["reason"] = why
			return out
		var fit := cavity_fit(null, body, fp, up, b, half, height_of(kind))
		out["needs_dig"] = not bool(fit["ok"]) or float(fit["ceiling"]) - float(fit["highest"]) < height_of(kind)
		out["dig_points"] = _room_points(kind, xf)
		out["dig_radius"] = 1.4
		out["ok"] = true
		return out
	var n0 := (near - c).normalized()
	var t1 := n0.cross(Vector3.UP if absf(n0.y) < 0.9 else Vector3.RIGHT).normalized()
	var t2 := n0.cross(t1)
	var top_r: float = float(body.radius) + float(body.get("max_height") if body.get("max_height") != null else 8.0) + 3.0
	for i in 32:
		var ring := 0.0 if i == 0 else 1.5 + 1.7 * sqrt(float(i))
		var a := float(i) * 2.39996
		var q := near + (t1 * cos(a) + t2 * sin(a)) * ring
		var dq := (q - c).normalized()
		var hit: Dictionary = body.raycast_density(c + dq * top_r, c + dq * (float(body.radius) - 14.0), 0.5, true)
		if hit.is_empty():
			continue
		var p: Vector3 = hit["position"]
		var up: Vector3 = body.up_at(p)
		if (hit["normal"] as Vector3).dot(up) < cos(deg_to_rad(Balance.BUILD_MAX_SLOPE_DEG)):
			continue
		var b := _basis_facing(up, (other.global_position - p) if other != null else Vector3.ZERO)
		var lo := INF
		var hi := -INF
		var ok := true
		for k in 9:
			var lp := Vector3(float(k % 3 - 1) * half.x, 0.0, float(floori(k / 3.0) - 1) * half.z)
			var off := Foundation.ground_offset(null, body, p + b * lp, up, 4.0, 6.0)
			if is_inf(off):
				ok = false
				break
			lo = minf(lo, off)
			hi = maxf(hi, off)
		if not ok or hi - lo > step_tol(kind):
			continue
		var xf := Transform3D(b, p + up * lerpf(lo, hi, base_k(kind)))
		if overlap_reason(kind, xf, r, tree) != "" or rule_reason(kind, xf, team, tree) != "":
			continue
		var site := Balance.build_site(kind)
		var own: bool = (body == Game.planet) == (team == "home")
		if (site == "home" and not own) or (site == "enemy" and own):
			out["reason"] = "Bu gezegene kurulamaz"
			return out
		out["ok"] = true
		out["xf"] = xf
		return out
	out["reason"] = "Uygun yer bulunamadı"
	return out


## DIG brush centres that hollow out the room a `kind` piece needs at xf (radius 1.4 each).
static func _room_points(kind: String, xf: Transform3D) -> Array:
	var half := half_of(kind)
	var h := height_of(kind)
	var pts: Array = []
	var nx := maxi(int(ceilf(half.x * 2.0 / 1.6)), 1)
	var nz := maxi(int(ceilf(half.z * 2.0 / 1.6)), 1)
	var ny := maxi(int(ceilf(h / 1.6)), 1)
	for iy in ny:
		for ix in nx:
			for iz in nz:
				var lx := (float(ix) + 0.5) / float(nx) * 2.0 - 1.0
				var lz := (float(iz) + 0.5) / float(nz) * 2.0 - 1.0
				pts.append(xf * Vector3(lx * half.x * 0.8, 0.9 + float(iy) * 1.4, lz * half.z * 0.8))
	return pts


## Host / single player: digs out the room a `kind` piece needs at xf (logged for the enemy's
## Tünel tarayıcı, synced like any dig). Returns the soil removed (m³; nobody is paid for it).
static func carve_for(kind: String, body: Node3D, xf: Transform3D, team: String) -> float:
	if body == null or not is_instance_valid(body) or Net.is_client():
		return 0.0
	var soil := 0.0
	for p in _room_points(kind, xf):
		soil += Dig.dig_at(body, p, 1.4, Dig.MODE_DIG, 8.0, Vector3.ZERO, Vector3.UP, -1.0, team)
	return soil


## Builds any build kind for `team` at xf (basis y = up) on `body` (default: the planet under it),
## with the assembly animation. Host / single player (a client's builds go through net_world). The
## caller pays (cost_of). Returns the node, or null for an unknown kind.
static func spawn(kind: String, team: String, xf: Transform3D, body: Node3D = null, animate := true, owner_peer := 0) -> Node3D:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var parent: Node = tree.current_scene if tree.current_scene != null else tree.root
	if body == null:
		body = Game.dominant_body(xf.origin)
	if PIECES.has(kind):
		var n: Node3D = load(str(PIECES[kind])).new()
		n.team = team
		n.body = body
		n.owner_peer = owner_peer
		n.name = "%s_%s" % [kind, team]
		n.transform = xf
		parent.add_child(n)
		if animate:
			n.begin_assembly()
		return n
	if LEGACY.has(kind):
		var s = load(str(LEGACY[kind]))
		if kind == "auto_miner":
			return s.call("spawn", parent, body, xf, team, animate, owner_peer)
		return s.call("spawn", parent, body, xf, team, animate)
	return null


## A closed Zırhlı Kapı of ANOTHER side than `team` that the segment from -> to passes through (bots
## cannot walk through it: stop and shoot it), or null.
static func blocking_door(from: Vector3, to: Vector3, team: String) -> Node3D:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	for d in tree.get_nodes_in_group("war_blast_door"):
		if not (d is Node3D) or Game.team_of(d) == team or d.get("is_destroyed") == true:
			continue
		if d.has_method("is_open") and d.is_open():
			continue
		var inv := (d as Node3D).global_transform.affine_inverse()
		var a := inv * from
		var b := inv * to
		if signf(a.z) == signf(b.z):
			continue
		var t := a.z / (a.z - b.z)
		var m := a.lerp(b, t)
		if absf(m.x) < 1.0 and m.y > -0.5 and m.y < 2.6:
			return d
	return null


# =================================================================================================
# Undo / sell (the build tool's Z / X; the multiplayer host checks a client's request the same way)
# =================================================================================================

static func display_name(kind: String) -> String:
	match kind:
		"cannon":
			return "Top"
		"buster":
			return "Delici Top"
		"flak":
			return "Uçaksavar"
		"armory":
			return "Silahlık"
		"torpedo_rig":
			return "Sondaj Kulesi"
		"auto_miner":
			return "Otomatik Kazıcı"
		"skiff":
			return "Mekik"
		"armed_skiff":
			return "Silahlı Mekik"
		"bunker_module":
			return "Sığınak Modülü"
		"armor_wall":
			return "Takviyeli Duvar"
		"blast_door":
			return "Zırhlı Kapı"
		"sentry_turret":
			return "Otomatik Taret"
		"core_shield":
			return "Çekirdek Kalkanı"
		"radar_tower":
			return "Radar Kulesi"
		"light_post":
			return "Işık Direği"
	return "Yapı"


## The war structure (group "war_structure") a collider belongs to (itself or an ancestor), or null.
static func structure_of(obj: Object) -> Node3D:
	var n := obj as Node
	while n != null:
		if n.is_in_group("war_structure") and n is Node3D:
			return n as Node3D
		n = n.get_parent()
	return null


## Why `node` cannot be taken down by `team` now ("" = it can). refund_k >= 1: an undo (only within
## Balance.UNDO_TIME s of its build).
static func unbuild_reason(node: Node, refund_k: float, team: String) -> String:
	if node == null or not is_instance_valid(node) or node.is_queued_for_deletion() or node.has_meta("deconstructed"):
		return "Yapı yok"
	if node.get("is_destroyed") == true or node.has_meta("build_preview"):
		return "Yapı yok"
	if Game.team_of(node) != team:
		return "Düşman yapısı sökülemez"
	if refund_k < 0.999 and node.get("_build_t") != null and float(node.get("_build_t")) >= 0.0:
		return "Hâlâ kuruluyor — bitince sökülür (Z: geri al)"
	if node.get("pilot") != null or node.has_meta("net_busy") or node.get("crafting") == true:
		return "Kullanımda — sökülemez"
	if node.get("passenger") != null:
		return "Kullanımda — sökülemez"
	if refund_k >= 0.999:
		var ms := int(node.get_meta("built_ms", -1000000)) if node.has_meta("built_ms") else -1000000
		if Time.get_ticks_msec() - ms > int(Balance.UNDO_TIME * 1000.0) + 500:
			return "Geri alma süresi geçti"
	return ""


## m³ back for taking `node` down (meta "build_cost", else the kind's price) × refund_k.
static func refund_of(node: Node, refund_k: float) -> float:
	var cost := float(node.get_meta("build_cost")) if node.has_meta("build_cost") else cost_of(kind_of(node))
	if cost <= 0.0:
		var s = node.get_script()
		if s is Script:
			var info = (s as Script).get_script_constant_map().get("BUILD_COST")
			if info != null:
				cost = float(info)
	return maxf(cost * refund_k, 0.0)


## Takes `node` down quietly (no explosion, no "yok edildi"): see the header.
static func deconstruct(node: Node3D, fx := true) -> void:
	if node == null or not is_instance_valid(node) or node.has_meta("deconstructed"):
		return
	node.set_meta("deconstructed", true)
	if deconstruct_hook.is_valid() and not Net.is_client():
		deconstruct_hook.call(node)
	for g in node.get_groups():
		if not str(g).begins_with("_"):
			node.remove_from_group(g)
	for c in node.find_children("*", "CollisionObject3D", true, false):
		(c as CollisionObject3D).collision_layer = 0
		(c as CollisionObject3D).collision_mask = 0
	for cs in node.find_children("*", "CollisionShape3D", true, false):
		(cs as CollisionShape3D).set_deferred("disabled", true)
	if node is CollisionObject3D:
		(node as CollisionObject3D).collision_layer = 0
		(node as CollisionObject3D).collision_mask = 0
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = true
	for l in node.find_children("*", "Light3D", true, false):
		(l as Light3D).visible = false
	for a in node.find_children("*", "AudioStreamPlayer3D", true, false):
		(a as AudioStreamPlayer3D).stop()
	node.process_mode = Node.PROCESS_MODE_DISABLED
	if not fx or not node.is_inside_tree():
		node.queue_free()
		return
	var xf := node.global_transform
	var up := xf.basis.y.normalized()
	var half := half_of(kind_of(node))
	var parent := node.get_parent()
	# The visuals agent's reverse print when it exists; else the parts sink and shrink into the ground.
	var bf = load("res://scripts/war/build_fx.gd")
	var has_rev := false
	for m in (bf as Script).get_script_method_list():
		if str(m.get("name", "")) == "disassemble":
			has_rev = true
			break
	if has_rev:
		bf.call("disassemble", parent, xf, half, bf.get("AUTO"), node)
		return                                  # (the reverse print has its own sound and frees the node)
	else:
		bf.call("dust", parent, xf.origin, up, maxf(half.x, half.z), Color(0.5, 0.45, 0.38))
		bf.call("shockwave", parent, xf.origin, up, maxf(half.x, half.z) * 1.4, Color(0.45, 0.9, 1.0))
	if Game.sfx:
		Game.sfx.play_at("servo", xf.origin, -4.0, 0.6, 14.0)
		Game.sfx.play_at("impact_light", xf.origin, -8.0, 0.7, 12.0)
	var tw := node.get_tree().create_tween()
	tw.set_process_mode(Tween.TWEEN_PROCESS_IDLE)
	var h := maxf(half.y * 2.0, 1.0)
	tw.tween_method(_sink.bind(node, xf, up, h), 0.0, 1.0, 0.85).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	tw.tween_callback(_free_if_valid.bind(node))


static func _sink(k: float, node: Node3D, xf: Transform3D, up: Vector3, h: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var sy := maxf(1.0 - k, 0.02)
	var sxz := lerpf(1.0, 0.85, k)
	node.global_transform = Transform3D(xf.basis * Basis.from_scale(Vector3(sxz, sy, sxz)), xf.origin - up * h * 0.15 * k)


static func _free_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
