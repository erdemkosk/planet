extends RefCounted
## Shot pings (radar, 2026-10-07; the user: "ateş eden düşmanlar minimapte görünsün, susturucu
## takanlar görünmesin"): a tiny static registry of recent gunshots, Call of Duty style. Firing
## WITHOUT a suppressor reveals the shooter's position (where he stood when he fired, not tracked
## afterwards) for a couple of seconds; scripts/ui/minimap.gd draws the enemy side's loud ones as
## fading red dots. Silent (suppressed) shots are recorded with loud = false and never drawn.
##   ShotPings.add(pos, team, loud := true)     one shot (world position of the muzzle)
##   ShotPings.recent(max_age := 2.5) -> Array  [{"pos": Vector3 (world, now), "team", "loud",
##                                               "age" (s), "body" (the planet it was fired on, or
##                                               null in open space)}], newest last
##   ShotPings.events().pinged(pos, team, loud) every add (optional listeners)
##   ShotPings.clear()
## Fed by scripts/war/enemy_fire.gd EnemyFire.shot (bots on the host / single player, net_bot.gd on
## a client, remote players through remote_avatar.gd shot_fx with their suppressor flag) and
## remote_avatar.gd for the heavy NO_BULLET guns. The local player's own shots are not recorded.
## Teams are local strings ("home" / "rival": in multiplayer "rival" is the other side on each
## machine), the same as Game.team_of(); the reader decides enemy vs ally.
## Floating-origin safe: a ping is stored relative to the nearest planet's centre (Bodies.nearest)
## and turned back into a world position on read, so a moved planet / origin never strands it.
## Ring buffer of CAP entries (fixed packed arrays, no per-shot allocation); a burst from one spot
## refreshes its entry instead of filling the ring (MERGE_MS / MERGE_D).

const Bodies := preload("res://scripts/planet/bodies.gd")

const CAP := 64
const MAX_AGE := 2.5                    # s (the radar's default fade)
const MERGE_MS := 400                   # a shot this soon after the same team's last ping...
const MERGE_D := 2.5                    # ...within this many m refreshes it (bursts, pellets)


class Events:
	extends RefCounted
	signal pinged(pos: Vector3, team: String, loud: bool)


static var _events: Events
static var _rel := PackedVector3Array()   # position relative to the body's centre (world if no body)
static var _body: Array = []              # planet node or null
static var _team := PackedStringArray()
static var _loud := PackedByteArray()
static var _ms := PackedInt64Array()      # Time.get_ticks_msec of the shot (0 = empty slot)
static var _head := 0                     # next slot to write
static var _n := 0                        # filled slots (≤ CAP)


static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


static func _ensure() -> void:
	if _ms.size() == CAP:
		return
	_rel.resize(CAP)
	_body.resize(CAP)
	_team.resize(CAP)
	_loud.resize(CAP)
	_ms.resize(CAP)
	_ms.fill(0)
	_head = 0
	_n = 0


## One shot fired from world position pos by `team`. loud = false: a suppressed gun (recorded, never
## shown on the radar).
static func add(pos: Vector3, team: String, loud := true) -> void:
	if not pos.is_finite():
		return
	_ensure()
	var now := Time.get_ticks_msec()
	var b: Node3D = Bodies.nearest(pos)
	var rel := pos - b.global_position if b != null else pos
	# A burst (or a shotgun's pellets) from the same spot: refresh the newest matching ping.
	for j in mini(_n, 6):
		var i := (_head - 1 - j + CAP) % CAP
		if now - _ms[i] > MERGE_MS:
			break
		if _team[i] == team and _body[i] == b and _rel[i].distance_to(rel) < MERGE_D and bool(_loud[i]) == loud:
			_ms[i] = now
			_rel[i] = rel
			events().pinged.emit(pos, team, loud)
			return
	_rel[_head] = rel
	_body[_head] = b
	_team[_head] = team
	_loud[_head] = 1 if loud else 0
	_ms[_head] = now
	_head = (_head + 1) % CAP
	_n = mini(_n + 1, CAP)
	events().pinged.emit(pos, team, loud)


## The pings of the last max_age s, oldest first (positions in world space as of now).
static func recent(max_age := MAX_AGE) -> Array:
	var out: Array = []
	if _n == 0:
		return out
	var now := Time.get_ticks_msec()
	var lim := int(max_age * 1000.0)
	for j in range(_n - 1, -1, -1):
		var i := (_head - 1 - j + CAP) % CAP
		var t := _ms[i]
		if t <= 0 or now - t > lim:
			continue
		var b = _body[i]
		var p: Vector3 = _rel[i]
		if b != null:
			if not is_instance_valid(b):
				continue
			p += (b as Node3D).global_position
		out.append({"pos": p, "team": _team[i], "loud": _loud[i] != 0, "age": float(now - t) / 1000.0, "body": b})
	return out


static func clear() -> void:
	_ensure()
	_ms.fill(0)
	_body.fill(null)
	_head = 0
	_n = 0
