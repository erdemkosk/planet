extends RefCounted
## Cover erosion ("Mermilerin siperi aşındırması"): bullets chip the soil and sustained fire wears
## cover down. Every terrain impact calls Erosion.add_impact(point, normal, weight, team): the guns'
## impacts through scripts/items/rifle_fx.gd impact_terrain (every machine, local FX), the bots'
## misses through scripts/war/enemy_fire.gd.
##   - A sparse grid per planet (cells of EROSION_CELL m, keys local to the planet node, so the
##     floating origin does not matter) gathers the weight of each hit: erosion_weight(cal) maps the
##     impact calibre to rifle 1, AP 2, sniper 4, shotgun pellet 0.4, SMG 0.7. It decays at
##     EROSION_DECAY / s (lazily, whenever the cell is touched: no per-frame work).
##   - Once a cell passes EROSION_THRESHOLD the HOST (single player: always; multiplayer: never on a
##     client, Net.is_client()) bites ONE small dig brush there (Dig.dig_at, team "" so it is not
##     logged as a tunnel; the planet's net hook, scripts/net/net_terrain.gd, syncs it like any host
##     edit) and the cell drops to EROSION_RESET × the threshold: ~9 rifle hits on one spot bite the
##     first notch, every ~5 more the next, so sustained fire eats through a thin crater rim.
##   - The terrain is a 1 m voxel grid: a ~0.55 m brush centred anywhere would often touch no voxel
##     at all, so the bite is centred ON the solid voxel corner nearest to a point EROSION_BRUSH_DEPTH
##     under the impact (one density lookup per candidate corner) with a radius under 1 m: exactly one
##     corner loses EROSION_BRUSH_AMOUNT of density, a ~1 m dimple that follows the surface as it
##     recedes (the next bites take the corners behind it).
##   - Never inside a structure footprint (group "war_structure", meta footprint_r, + margin), near
##     a core (group "war_core"), or under a player's feet (a short column under each player); at
##     most EROSION_BRUSH_RATE bites / s for all shooters together (a token bucket EROSION_BRUSH_BURST
##     deep; net_terrain batches at 15 Hz). A full cell waiting for a token keeps its weight and bites
##     on a later hit; a blocked cell is reset (no re-test on every hit).
## Bots: an impact within AI_SUP_IMPACT_R of a bot of another side feeds its suppression meter
## (ai_rival.gd "Suppression", sup_impact(point, weight)); host / single player only, one
## notification per spot and physics frame (a shotgun blast is one, not nine).
## Static, no node: the state lives in statics keyed by the planet's instance id (dropped when the
## planet goes away).

const Balance := preload("res://scripts/war/balance.gd")
const Dig := preload("res://scripts/player/dig.gd")

static var bites := 0                    # brushes applied (tests / debug)
static var _grids := {}                  # planet instance id -> {Vector3i: [v, ms, cx, cy, cz, nx, ny, nz]}
static var _tokens := -1.0               # bite tokens (< 0: not started)
static var _tok_ms := 0
static var _note_frame := -1
static var _noted: Array = []            # impact points sent to the bots this physics frame


## Erosion weight of one round from its impact calibre (rifle_fx.gd `cal`: 0.65 a shotgun pellet,
## 0.7 the SMG, 1 a rifle round, 1.6 AP, 2.2 the sniper).
static func erosion_weight(cal: float) -> float:
	if cal <= 0.0:
		return Balance.EROSION_W_RIFLE
	if cal < 0.68:
		return Balance.EROSION_W_PELLET
	if cal < 0.9:
		return Balance.EROSION_W_SMG
	if cal < 1.3:
		return Balance.EROSION_W_RIFLE
	if cal < 2.0:
		return Balance.EROSION_W_AP
	return Balance.EROSION_W_SNIPER


## One bullet hit the terrain at world point p (surface normal n) with erosion weight w, fired by
## `team` ("" = unknown). Returns the cell's fill 0..1 (toward the next bite).
static func add_impact(p: Vector3, n: Vector3, w: float, team := "") -> float:
	if w <= 0.0:
		return 0.0
	var body: Node3D = Game.dominant_body(p)
	if body == null or not is_instance_valid(body) or not body.has_method("apply_brush"):
		return 0.0
	var host := not Net.is_client()
	if host:
		_notify_bots(p, w, team)
	var grid := _grid(body)
	var local := p - body.global_position
	var key := Vector3i((local / Balance.EROSION_CELL).floor())
	var now := Time.get_ticks_msec()
	var c = grid.get(key)
	if c == null:
		if grid.size() >= Balance.EROSION_MAX_CELLS:
			_prune(grid, now)
		c = [0.0, now, local.x, local.y, local.z, n.x, n.y, n.z]
		grid[key] = c
	var v := maxf(float(c[0]) - Balance.EROSION_DECAY * float(now - int(c[1])) * 0.001, 0.0)
	# The cell's bite point and normal follow the recent hits (weighted by w).
	var k := w / (v + w)
	c[2] = lerpf(float(c[2]), local.x, k)
	c[3] = lerpf(float(c[3]), local.y, k)
	c[4] = lerpf(float(c[4]), local.z, k)
	c[5] = lerpf(float(c[5]), n.x, k)
	c[6] = lerpf(float(c[6]), n.y, k)
	c[7] = lerpf(float(c[7]), n.z, k)
	v += w
	c[0] = v
	c[1] = now
	if v >= Balance.EROSION_THRESHOLD and host:
		var cn := Vector3(float(c[5]), float(c[6]), float(c[7]))
		var r := _bite(body, body.global_position + Vector3(float(c[2]), float(c[3]), float(c[4])),
				cn.normalized() if cn.length_squared() > 1e-6 else n)
		if r != 0:
			c[0] = Balance.EROSION_THRESHOLD * Balance.EROSION_RESET
	return clampf(float(c[0]) / Balance.EROSION_THRESHOLD, 0.0, 1.0)


## Forget everything (a new match; tests).
static func reset() -> void:
	_grids.clear()
	_tokens = -1.0
	_noted.clear()
	bites = 0


# =================================================================================================
# Internals
# =================================================================================================

## The bite: 0 = no token now (the cell keeps its weight), 1 = bitten, 2 = blocked / nothing to bite
## (the cell resets anyway).
static func _bite(body: Node3D, p: Vector3, n: Vector3) -> int:
	_refill()
	if _tokens < 1.0:
		return 0
	if _blocked(p, body):
		return 2
	var corner := _solid_corner(body, p, n)
	if corner == Vector3.INF or _blocked(corner, body):
		return 2
	_tokens -= 1.0
	Dig.dig_at(body, corner, Balance.EROSION_BRUSH_R, Dig.MODE_DIG, Balance.EROSION_BRUSH_AMOUNT)
	bites += 1
	return 1


static func _refill() -> void:
	var now := Time.get_ticks_msec()
	if _tokens < 0.0:
		_tokens = Balance.EROSION_BRUSH_BURST
	else:
		_tokens = minf(Balance.EROSION_BRUSH_BURST, _tokens + float(now - _tok_ms) * 0.001 * Balance.EROSION_BRUSH_RATE)
	_tok_ms = now


## The voxel corner to bite (1 m lattice, body-local) among the 8 around the point
## EROSION_BRUSH_DEPTH under the impact: a solid one (density <= 0) as close to the surface as
## possible (the density is about the signed distance: the highest wins, so the dent shows), a
## little in favour of the ones nearer that point. INF when all 8 are air (a thin overhang, a trunk).
static func _solid_corner(body: Node3D, p: Vector3, n: Vector3) -> Vector3:
	var o := body.global_position
	var q := p - n * Balance.EROSION_BRUSH_DEPTH - o
	var base := q.floor()
	var best := Vector3.INF
	var best_s := -INF
	for i in 8:
		var v := base + Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1)
		var dens := float(body.density_at(o + v))
		if dens > 0.0:
			continue
		var s := dens - 0.35 * v.distance_to(q)
		if s > best_s:
			best_s = s
			best = o + v
	return best


## No bite here: a structure's footprint, a core, or the ground under a player's feet.
static func _blocked(p: Vector3, body: Node3D) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return true
	for s in tree.get_nodes_in_group("war_structure"):
		if s is Node3D and (s as Node3D).global_position.distance_to(p) \
				< float(s.get_meta("footprint_r", 3.0)) + Balance.EROSION_STRUCT_MARGIN:
			return true
	for c in tree.get_nodes_in_group("war_core"):
		if c is Node3D and (c as Node3D).global_position.distance_to(p) < Balance.CORE_RADIUS + Balance.EROSION_CORE_MARGIN:
			return true
	var up: Vector3 = body.up_at(p) if body.has_method("up_at") else Vector3.UP
	for pl in [Game.player] + tree.get_nodes_in_group("net_player"):
		if pl == null or not is_instance_valid(pl) or not (pl is Node3D):
			continue
		var rel := p - (pl as Node3D).global_position
		var h := rel.dot(up)
		if h < 0.6 and h > -2.2 and (rel - up * h).length() < Balance.EROSION_FEET_R:
			return true
	return false


## Bots of another side near the impact (their chest within AI_SUP_IMPACT_R) feel it (suppression).
static func _notify_bots(p: Vector3, w: float, team: String) -> void:
	var f := Engine.get_physics_frames()
	if f != _note_frame:
		_note_frame = f
		_noted.clear()
	for q in _noted:
		if (q as Vector3).distance_squared_to(p) < 2.25:
			return
	if _noted.size() >= 8:
		return
	_noted.append(p)
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var reach := Balance.AI_SUP_IMPACT_R + 1.2
	for b in tree.get_nodes_in_group("war_ai"):
		if not (b is Node3D) or not b.has_method("sup_impact"):
			continue
		if team != "" and str(b.get("team")) == team:
			continue
		if (b as Node3D).global_position.distance_squared_to(p) < reach * reach:
			b.sup_impact(p, w)


static func _grid(body: Node3D) -> Dictionary:
	var id := body.get_instance_id()
	var g = _grids.get(id)
	if g == null:
		if _grids.size() >= 4:
			for k in _grids.keys():
				if not is_instance_id_valid(k):
					_grids.erase(k)
		g = {}
		_grids[id] = g
	return g


## The grid is full: drop the cells that have decayed (all of them if that is not enough).
static func _prune(grid: Dictionary, now: int) -> void:
	for key in grid.keys():
		var c: Array = grid[key]
		if float(c[0]) - Balance.EROSION_DECAY * float(now - int(c[1])) * 0.001 < 0.5:
			grid.erase(key)
	if grid.size() >= Balance.EROSION_MAX_CELLS:
		grid.clear()
