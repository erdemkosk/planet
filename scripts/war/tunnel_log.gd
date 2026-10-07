extends RefCounted
## Where each side has dug underground, per planet: the Tünel tarayıcı (scripts/items/tunnel_scanner.gd)
## shows the enemy's tunnels from it. Fed by Dig.dig_at(..., team) (the player's drill, the rival
## bots) and by the drilling torpedo (scripts/war/torpedo.gd).
## Points are kept in the planet's local frame (floating origin safe) and thinned: a new point is
## only stored when it is farther than ~0.8 × radius from the side's last point on that planet.
##
##   TunnelLog.record(body, world_point, radius, team)
##   TunnelLog.points(body, team) -> Array of {"p": Vector3 (world), "r": float, "t": float (s)}
##   TunnelLog.clear()            (a new match)

const MAX_PER_SIDE := 3000

static var _log := {}            # planet instance id -> {team -> Array of [local Vector3, r, msec]}
static var _last := {}           # "id|team" -> last local point


static func record(body: Node3D, point: Vector3, radius: float, team: String) -> void:
	if body == null or not is_instance_valid(body) or team == "":
		return
	var id := body.get_instance_id()
	var lp := body.to_local(point)
	var key := "%d|%s" % [id, team]
	var last = _last.get(key)
	if last is Vector3 and (last as Vector3).distance_to(lp) < radius * 0.8:
		return
	_last[key] = lp
	if not _log.has(id):
		_log[id] = {}
	var sides: Dictionary = _log[id]
	if not sides.has(team):
		sides[team] = []
	var arr: Array = sides[team]
	arr.append([lp, radius, Time.get_ticks_msec()])
	if arr.size() > MAX_PER_SIDE:
		arr.remove_at(0)


## The recorded points of `team` on `body`, in world space; t = seconds since it was dug.
static func points(body: Node3D, team: String) -> Array:
	var out: Array = []
	if body == null or not is_instance_valid(body):
		return out
	var sides: Dictionary = _log.get(body.get_instance_id(), {})
	var now := Time.get_ticks_msec()
	for e in sides.get(team, []):
		out.append({"p": body.to_global(e[0]), "r": float(e[1]), "t": float(now - int(e[2])) / 1000.0})
	return out


static func clear() -> void:
	_log.clear()
	_last.clear()
