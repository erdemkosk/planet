extends Node
## Bölge kontrolü (2026-10-06; the user: "habire bir şey kazmak zorundayım" — he picked "A: income
## from holding ground" + "C: drop the small taxes" from the analysis): income comes from holding
## ground and from your core, not from holding the drill button. Child "ControlPoints" of War (war.gd);
## tunables: balance.gd "Bölge kontrolü" (CP_*, CORE_PUMP). Off in the Eğitim Alanı.
##
## Zones: every combat area of scripts/planet/poi.gd (POI_COUNT per planet) carries one, a letter
## A, B, C… per planet and the area's name ("Harap Karakol"). Its beacon (control_beacon.gd) stands
## on a spot near the area's centre at the original ground height (not on a rock pillar); the zone is
## everything within CP_RADIUS m of it along the surface, from 25 m underground (tunnels) to
## CP_HEIGHT m above (a skiff flying over does not count).
## Capture (host / single player, every TICK s): `progress` runs -1 (rival) .. +1 (home). Living units
## in a zone: the player (on foot), every bot of group "war_ai" (rival bots and our allies, by
## Game.team_of; not the training dummies, not aboard), remote players (group "net_player"). One
## team alone moves the progress toward itself at 1 / CP_CAPTURE_TIME per s (each further unit
## + CP_CAPTURE_EXTRA, at most × CP_CAPTURE_MAX_K); both teams = contested (frozen, pays nobody);
## nobody = it drifts back toward its owner (CP_DRIFT_K of the speed). Ownership goes through neutral:
## an owned zone is first neutralised (progress crosses 0), then taken (±1).
## Numbers advantage (2026-10-07, _down_k): a team with 2+ dead (respawn_waves.gd team_down) loses its
## zones × CP_DOWN_TAKE_K faster and captures × CP_DOWN_CAP_K.
## Start: every zone belongs to its planet's team, so each side earns from the first second; a rival
## drop-pod crew that takes one cuts your income and adds to theirs, and the other way round.
## Income (per frame): a team's n uncontested zones pay Balance.zone_income(n) m³/s together
## (CP_INCOME for the first, diminishing: × n^CP_INCOME_EXP); each team's living core also pumps
## CORE_PUMP m³/s, less 1/N for each of its N members lying dead (pump_share). "home" pays
## Game.material (the local player, on every machine: each teammate gets it in full), "rival" the rival
## team's pool (rival_team.gd `material`, host / single player only). Nothing after the match ends.
## The bots (one-line hooks): ai_rival.gd _pod_site -> raid_target (a pod crew on our planet goes for
## our nearest zone before it hunts the player), _pick_guard_point -> guard_target (guards retake their
## lost / contested zones); rival_team.gd _pick_landing -> land_bonus (pods land near our zones).
## Feedback: toasts on every owner change seen from our side ("ele geçirildi", "düştü",
## "saldırı altında"), the beacons' colours, control_hud.gd (zone chips beside the compass, the
## zone income, the capture plate while we stand in one).
##
## API
##   ControlPoints.inst(tree) -> Node                 the manager (group GROUP) or null
##   zones -> Array of {"body", "preset", "i", "letter", "name", "dir" (unit, world, the beacon's),
##            "ground_r", "owner" ("home" / "rival" / ""), "progress", "contested", "h", "r" (unit
##            counts), "beacon"}
##   zones_of(body) -> Array    zone_at(body, world_pos) -> Dictionary ({} = none)
##   local_zone() -> Dictionary  the zone the local player stands in
##   income_rate(team) -> float  m³/s that team earns from zones + its core right now
##   raid_target(bot) / guard_target(bot) -> Vector3 (INF = none)   land_bonus(body, p) -> float
## Multiplayer (host authoritative; single player never touches it). Owners and progress go on the
## wire in ABSOLUTE sides (Net.abs_side: 0 = Yurt / the host, 1 = Rakip): owner_abs -1 / 0 / 1,
## progress_abs +1 = side 0 … -1 = side 1. Zones are identified by [planet preset ("home" = Yurt,
## "rival" = Rakip), index]; both machines build the same zones from the same POI sites.
##   ControlPoints.events().state_changed(states)  host: [[preset, i, owner_abs, progress_abs,
##                                                  contested], …] of the zones that changed (≤ 5 Hz)
##   snapshot() -> Array                            host: every zone (a late join)
##   net_apply(states)                              client: apply them (toasts and beacons follow)
## Income on a client: its own side's zones and core are paid locally into its Game.material.

const Balance := preload("res://scripts/war/balance.gd")
const Poi := preload("res://scripts/planet/poi.gd")
const Beacon := preload("res://scripts/war/control_beacon.gd")
const ControlHud := preload("res://scripts/war/control_hud.gd")
const Waves := preload("res://scripts/war/respawn_waves.gd")   # the dead count (_down_k)

const GROUP := "control_points"
const LETTERS := "ABCDEFGHIJKL"
const TICK := 0.2
const UNDER := 25.0                      # m below the ground a unit still counts (tunnels)


class Events:
	extends RefCounted
	signal state_changed(states: Array)


static var _events: Events

var zones: Array = []
var war                                  # war.gd (parent)
var _tick_acc := 0.0
var _ready_zones := false
var _sent_p := {}                        # zone key -> progress last sent (host)


static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


static func inst(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null


func _ready() -> void:
	name = "ControlPoints"
	add_to_group(GROUP)
	war = get_parent()
	_setup.call_deferred()


## One frame after the world: the POI sites exist by then (main.gd builds them before the war).
func _setup() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	for body in [Game.planet, Game.rival]:
		if body == null or not is_instance_valid(body):
			continue
		var team := "home" if body == Game.planet else "rival"
		var n := 0
		for s: Dictionary in Poi.sites_of(body):
			var z := _make_zone(body, s, n, team)
			if not z.is_empty():
				zones.append(z)
				n += 1
	var hud: CanvasLayer = ControlHud.new()
	hud.cp = self
	add_child(hud)
	_ready_zones = true


func _make_zone(body: Node3D, s: Dictionary, n: int, team: String) -> Dictionary:
	var dir := _beacon_dir(body, s)
	var c: Vector3 = body.global_position
	var gr := Poi.ground_r(body, dir)
	var h: Dictionary = body.raycast_density(c + dir * (gr + 22.0), c + dir * (gr - 18.0), 0.4, false)
	var p: Vector3 = h["position"] if not h.is_empty() else c + dir * gr
	var z := {"body": body, "preset": str(body.get("preset_name")), "i": n, "letter": LETTERS[mini(n, LETTERS.length() - 1)],
			"name": str(s.get("name", "Bölge")), "dir": dir, "ground_r": gr,
			"owner": team, "progress": 1.0 if team == "home" else -1.0, "contested": false, "h": 0, "r": 0,
			"alert_ms": -100000, "beacon": null}
	var b: Node3D = Beacon.new()
	b.letter = z["letter"]
	b.zone_name = z["name"]
	add_child(b)
	var up := dir
	var x := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	b.global_transform = Transform3D(Basis(x, up, x.cross(up)), p)
	b.set_state(z["owner"], z["progress"], false)
	z["beacon"] = b
	return z


## A spot near the site's centre at its original ground height (not on a pillar / hill top), flat
## enough for the beacon: the centre, then rings at 3, 6 and 9 m.
func _beacon_dir(body: Node3D, s: Dictionary) -> Vector3:
	var d0: Vector3 = (s["dir"] as Vector3).normalized()
	var c: Vector3 = body.global_position
	var r: float = float(body.radius)
	var x := d0.cross(Vector3.UP if absf(d0.y) < 0.9 else Vector3.RIGHT).normalized()
	var y := d0.cross(x).normalized()
	var best := d0
	var best_e := INF
	for ring in [0.0, 3.0, 6.0, 9.0]:
		var count := 1 if ring == 0.0 else 8
		for k in count:
			var a := TAU * float(k) / float(count)
			var d := d0 if ring == 0.0 else d0.rotated((x * cos(a) + y * sin(a)).cross(d0).normalized(), -float(ring) / r)
			var gr := Poi.ground_r(body, d)
			var h: Dictionary = body.raycast_density(c + d * (gr + 22.0), c + d * (gr - 18.0), 0.5, false)
			if h.is_empty():
				continue
			var e := absf((h["position"] as Vector3).distance_to(c) - gr)
			if (h["normal"] as Vector3).dot(d) < cos(deg_to_rad(28.0)):
				e += 2.0
			if e < best_e:
				best_e = e
				best = d
		if best_e < 0.8:
			break
	return best


# =================================================================================================
# Capture (host / single player)
# =================================================================================================

func _process(delta: float) -> void:
	if not _ready_zones:
		return
	if not Net.is_client():
		_tick_acc += delta
		if _tick_acc >= TICK:
			_tick(_tick_acc)
			_tick_acc = 0.0
	if not Game.match_over:
		_pay_income(delta)


func _tick(dt: float) -> void:
	for z in zones:
		z["h"] = 0
		z["r"] = 0
	for u in _units():
		var pos: Vector3 = u[0]
		var team: String = u[1]
		var z := zone_at(Game.dominant_body(pos), pos)
		if z.is_empty():
			continue
		if team == "home":
			z["h"] = int(z["h"]) + 1
		elif team == "rival":
			z["r"] = int(z["r"]) + 1
	var changed: Array = []
	for z in zones:
		var h: int = z["h"]
		var r: int = z["r"]
		var old_owner: String = z["owner"]
		var old_p: float = z["progress"]
		var old_c: bool = z["contested"]
		z["contested"] = h > 0 and r > 0
		var p := old_p
		if z["contested"]:
			pass
		elif h > 0:
			p = minf(p + _speed(h) * dt * _down_k(z, "home"), 1.0)
		elif r > 0:
			p = maxf(p - _speed(r) * dt * _down_k(z, "rival"), -1.0)
		else:
			var rest := 1.0 if old_owner == "home" else (-1.0 if old_owner == "rival" else 0.0)
			p = move_toward(p, rest, Balance.CP_DRIFT_K / Balance.CP_CAPTURE_TIME * dt)
		z["progress"] = p
		var owner := old_owner
		if p >= 1.0:
			owner = "home"
		elif p <= -1.0:
			owner = "rival"
		elif old_owner == "home" and p <= 0.0:
			owner = ""
		elif old_owner == "rival" and p >= 0.0:
			owner = ""
		z["owner"] = owner
		if owner != old_owner:
			_on_owner_changed(z, old_owner)
		_alert_check(z)
		if owner != old_owner or z["contested"] != old_c or absf(p - float(_sent_p.get(_key(z), 99.0))) > 0.04:
			changed.append(z)
		var b = z["beacon"]
		if b != null and is_instance_valid(b):
			b.set_state(owner, p, z["contested"])
	if Net.is_host() and not changed.is_empty():
		var states: Array = []
		for z in changed:
			var st := _state(z)
			_sent_p[_key(z)] = float(z["progress"])
			states.append(st)
		events().state_changed.emit(states)


## Numbers advantage (2026-10-07, respawn waves): × on `taker`'s capture speed in zone z. The other
## team down (RespawnWaves.is_team_down: weighted dead >= CP_DOWN_MIN) and z still theirs (owner, or
## leaning their way while neutral): × CP_DOWN_TAKE_K; `taker` itself down: × CP_DOWN_CAP_K.
func _down_k(z: Dictionary, taker: String) -> float:
	var other := "rival" if taker == "home" else "home"
	var p: float = z["progress"]
	var held: String = z["owner"]
	if held == "":
		held = "home" if p > 0.0 else ("rival" if p < 0.0 else "")
	var k := 1.0
	if held == other and Waves.is_team_down(other):
		k *= Balance.CP_DOWN_TAKE_K
	if Waves.is_team_down(taker):
		k *= Balance.CP_DOWN_CAP_K
	return k


static func _speed(n: int) -> float:
	return minf(1.0 + float(n - 1) * Balance.CP_CAPTURE_EXTRA, Balance.CP_CAPTURE_MAX_K) / Balance.CP_CAPTURE_TIME


## [world position, team] of every living unit that can hold ground.
func _units() -> Array:
	var out: Array = []
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and not pl.is_dead() and pl.get("vehicle") == null:
		out.append([(pl as Node3D).global_position, "home"])
	for n in get_tree().get_nodes_in_group("war_ai"):
		if not (n is Node3D) or n.is_in_group("training_dummy"):
			continue
		if n.has_method("is_dead") and n.is_dead():
			continue
		if n.get("aboard") != null:
			continue
		if n.has_method("pod_phase") and str(n.pod_phase()) in ["aboard", "flight", "muster"]:
			continue
		out.append([(n as Node3D).global_position, Game.team_of(n)])
	for n in get_tree().get_nodes_in_group("net_player"):
		if not (n is Node3D) or (n.has_method("is_dead") and n.is_dead()):
			continue
		out.append([(n as Node3D).global_position, Game.team_of(n)])
	return out


## The zone of `body` that contains world `pos` ({} = none).
func zone_at(body: Node3D, pos: Vector3) -> Dictionary:
	if body == null:
		return {}
	var c: Vector3 = body.global_position
	var rel := pos - c
	var dist := rel.length()
	if dist < 1.0:
		return {}
	var d := rel / dist
	for z in zones:
		if z["body"] != body:
			continue
		var gr: float = z["ground_r"]
		if dist - gr > Balance.CP_HEIGHT or gr - dist > UNDER:
			continue
		if acos(clampf(d.dot(z["dir"]), -1.0, 1.0)) * gr <= Balance.CP_RADIUS:
			return z
	return {}


func zones_of(body: Node3D) -> Array:
	return zones.filter(func(z) -> bool: return z["body"] == body)


## The zone the local player stands in ({} = none).
func local_zone() -> Dictionary:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.get("vehicle") != null:
		return {}
	var p: Vector3 = (pl as Node3D).global_position
	return zone_at(Game.dominant_body(p), p)


# =================================================================================================
# Income
# =================================================================================================

func _pay_income(delta: float) -> void:
	var home := income_rate("home") * delta
	# (co-op shared pool: the host pays the team once; a client's add_material would pay it again)
	if home > 0.0 and not (Net.is_client() and Game.shared_pool):
		Game.add_material(home)
	if not Net.is_client() and war != null and is_instance_valid(war):
		var t = war.get("team")
		if t != null and is_instance_valid(t) and t.get("material") != null:
			t.material = float(t.material) + income_rate("rival") * delta


## m³/s `team` earns right now: its uncontested zones (diminishing: Balance.zone_income) and its
## living core, whose pump loses 1/N for each of the team's N members lying dead (pump_share).
func income_rate(team: String) -> float:
	var r := Balance.zone_income(held_count(team))
	if war != null and is_instance_valid(war):
		var core = war.get("home_core") if team == "home" else war.get("rival_core")
		if core != null and is_instance_valid(core) and not bool(core.get("destroyed")):
			r += Balance.CORE_PUMP * pump_share(team)
	return r


var _pump_k := {}                        # team -> [process frame, share] (pump_share's per-frame cache)


## Share of `team`'s CORE_PUMP running now: its living members / all of them (the player, remote
## players, the rival team's / our ally bots). A kill stops 1/N of the enemy's pump until the respawn
## (2026-10-06 economy pass: "killing enemies gives no advantage"). Cached per frame (≤ ~12 nodes).
func pump_share(team: String) -> float:
	var f := Engine.get_process_frames()
	var c = _pump_k.get(team)
	if c is Array and int(c[0]) == f:
		return float(c[1])
	var n := 0
	var dead := 0
	var pl = Game.player
	if team == "home" and pl != null and is_instance_valid(pl):
		n += 1
		dead += 1 if pl.is_dead() else 0
	if war != null and is_instance_valid(war):
		var squad = war.get("team") if team == "rival" else war.get("allies")
		if squad != null and is_instance_valid(squad) and squad.get("bots") is Array:
			for b in squad.bots:
				if is_instance_valid(b) and b.has_method("is_dead"):
					n += 1
					dead += 1 if b.is_dead() else 0
	for a in get_tree().get_nodes_in_group("net_player"):
		if is_instance_valid(a) and a.has_method("is_dead") and Game.team_of(a) == team:
			n += 1
			dead += 1 if a.is_dead() else 0
	var k := 1.0 if n <= 0 else float(n - dead) / float(n)
	_pump_k[team] = [f, k]
	return k


## Zones `team` holds uncontested (the ones that pay).
func held_count(team: String) -> int:
	var n := 0
	for z in zones:
		if z["owner"] == team and not z["contested"]:
			n += 1
	return n


## m³/s the n-th held zone adds on top of n - 1 (the capture toast, the "held" plate).
static func zone_step(n: int) -> float:
	return Balance.zone_income(n) - Balance.zone_income(n - 1)


# =================================================================================================
# Feedback (host and client alike)
# =================================================================================================

func _on_owner_changed(z: Dictionary, old: String) -> void:
	_tz = z                                  # (the alert line's key, _toast)
	var tag := "%s (%s)" % [z["name"], z["letter"]]
	var ours: bool = z["body"] == Game.planet
	var where := "" if ours else "  ·  rakip gezegen"
	match str(z["owner"]):
		"home":
			_toast("%s ELE GEÇİRİLDİ  ·  +%s m³/s%s" % [tag, String.num(zone_step(held_count("home")), 2).replace(".", ","), where], "craft", -6.0)
		"rival":
			_toast("%s DÜŞTÜ  ·  rakip gelir alıyor%s" % [tag, where], "error", -6.0)
		_:
			if old == "home":
				_toast("%s KAYBEDİLİYOR%s" % [tag, where], "error", -8.0)
			elif old == "rival":
				_toast("%s etkisizleştirildi%s" % [tag, where], "ding", -10.0)


## One of our zones has the enemy in it: a warning, at most every CP_ALERT_GAP s per zone.
func _alert_check(z: Dictionary) -> void:
	if z["owner"] != "home" or int(z["r"]) <= 0:
		return
	var now := Time.get_ticks_msec()
	if now - int(z["alert_ms"]) < int(Balance.CP_ALERT_GAP * 1000.0):
		return
	z["alert_ms"] = now
	_tz = z
	_toast("%s (%s) SALDIRI ALTINDA" % [z["name"], z["letter"]], "error", -10.0)


## The zone the next _toast is about (set by _on_owner_changed / _alert_check): its alert key.
var _tz: Dictionary = {}


## Through the HUD's one alert channel (scripts/ui/hud.gd alert): one line per zone (key
## "cp_<preset>_<i>", a newer state replaces the older in place); SALDIRI ALTINDA / DÜŞTÜ /
## KAYBEDİLİYOR are critical (priority 2), a capture / neutralise normal (1). Our own sound plays.
func _toast(text: String, snd: String, db: float) -> void:
	if Game.hud and Game.hud.has_method("alert"):
		var crit := text.contains("SALDIRI ALTINDA") or text.contains("DÜŞTÜ") or text.contains("KAYBEDİLİYOR")
		var key := ("cp_%s_%d" % [str(_tz.get("preset", "")), int(_tz.get("i", 0))]) if not _tz.is_empty() else ""
		Game.hud.alert(text, 2 if crit else 1, key, 3.0, false)
	elif Game.hud and Game.hud.has_method("show_message"):
		Game.hud.show_message(text, 3.0)
	if Game.sfx:
		Game.sfx.play(snd, db, 1.0)


# =================================================================================================
# The bots (hooks in ai_rival.gd / rival_team.gd)
# =================================================================================================

## A point inside the nearest zone on the bot's planet that its team does not hold, within
## CP_RAID_RANGE (INF = none). Stable per bot (its own spot in the zone).
func raid_target(bot: Node3D) -> Vector3:
	if not _ready_zones or bot == null:
		return Vector3.INF
	var team := Game.team_of(bot)
	var body: Node3D = Game.dominant_body(bot.global_position)
	var best: Dictionary = {}
	var best_d := Balance.CP_RAID_RANGE
	for z in zones:
		if z["body"] != body or (z["owner"] == team and absf(float(z["progress"])) >= 0.999):
			continue
		var d := bot.global_position.distance_to(_center(z))
		if d < best_d:
			best_d = d
			best = z
	return _spot_in(best, bot) if not best.is_empty() else Vector3.INF


## For a guard on its own planet: a point in one of its team's zones there that is lost, being
## taken or contested (INF = all held).
func guard_target(bot: Node3D) -> Vector3:
	if not _ready_zones or bot == null:
		return Vector3.INF
	var team := Game.team_of(bot)
	var body: Node3D = Game.dominant_body(bot.global_position)
	var want := 1.0 if team == "home" else -1.0
	var best: Dictionary = {}
	var best_d := INF
	for z in zones:
		if z["body"] != body:
			continue
		var threatened: bool = float(z["progress"]) * want < 0.999 or z["contested"] \
				or (team == "rival" and int(z["h"]) > 0) or (team == "home" and int(z["r"]) > 0)
		if not threatened:
			continue
		var d := bot.global_position.distance_to(_center(z))
		if d < best_d:
			best_d = d
			best = z
	return _spot_in(best, bot) if not best.is_empty() else Vector3.INF


## Pod landing score bonus for a spot `p` on `body` near a zone the rival does not hold.
func land_bonus(body: Node3D, p: Vector3) -> float:
	for z in zones:
		if z["body"] == body and z["owner"] != "rival" and p.distance_to(_center(z)) < Balance.CP_LAND_NEAR:
			return Balance.CP_LAND_BONUS
	return 0.0


func _center(z: Dictionary) -> Vector3:
	return (z["body"] as Node3D).global_position + (z["dir"] as Vector3) * float(z["ground_r"])


## A spot inside zone z for this bot: a fixed angle (by the bot's id) at 2-6 m from the beacon.
func _spot_in(z: Dictionary, bot: Node3D) -> Vector3:
	var d0: Vector3 = z["dir"]
	var x := d0.cross(Vector3.UP if absf(d0.y) < 0.9 else Vector3.RIGHT).normalized()
	var y := d0.cross(x).normalized()
	var id := bot.get_instance_id()
	var a := float(id % 360) * PI / 180.0
	var r := 2.0 + float((id / 360) % 5)
	var d := d0.rotated((x * cos(a) + y * sin(a)).cross(d0).normalized(), -r / float(z["ground_r"]))
	return (z["body"] as Node3D).global_position + d * (float(z["ground_r"]) + 1.0)


# =================================================================================================
# Multiplayer state (absolute sides on the wire)
# =================================================================================================

static func _key(z: Dictionary) -> String:
	return "%s:%d" % [z["preset"], int(z["i"])]


func _state(z: Dictionary) -> Array:
	var s0 := Net.abs_side("home") == 0           # our "home" is absolute side 0
	var o := -1
	if z["owner"] == "home":
		o = Net.abs_side("home")
	elif z["owner"] == "rival":
		o = Net.abs_side("rival")
	var pa: float = float(z["progress"]) * (1.0 if s0 else -1.0)
	return [z["preset"], int(z["i"]), o, snappedf(pa, 0.001), bool(z["contested"])]


## Host: every zone (a late join).
func snapshot() -> Array:
	var out: Array = []
	for z in zones:
		out.append(_state(z))
	return out


## Client: the host's zone states.
func net_apply(states: Array) -> void:
	var s0 := Net.abs_side("home") == 0
	for st in states:
		if not (st is Array) or (st as Array).size() < 5:
			continue
		for z in zones:
			if z["preset"] != str(st[0]) or int(z["i"]) != int(st[1]):
				continue
			var o := int(st[2])
			var owner := ""
			if o >= 0:
				owner = "home" if o == Net.abs_side("home") else "rival"
			var old: String = z["owner"]
			z["owner"] = owner
			z["progress"] = float(st[3]) * (1.0 if s0 else -1.0)
			z["contested"] = bool(st[4])
			if owner != old:
				_on_owner_changed(z, old)
			var b = z["beacon"]
			if b != null and is_instance_valid(b):
				b.set_state(owner, z["progress"], z["contested"])
			break
