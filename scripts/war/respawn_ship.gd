extends Node3D
## Yeniden doğuş gemileri (2026-10-05, the user: "Ölünce bizi gezegene bir uzay gemisi atsın, 10 sn
## sonra doğalım; düşmanda da bu olsun"). main.gd adds one of these after the war. It owns:
##   Carriers  one Taşıyıcı per planet (scripts/war/carrier.gd), parked high above its base on a slow
##             loop; decorative (group "war_carrier").
##   Dropships İniş Gemisi (scripts/war/dropship.gd, group "respawn_ship") from a carrier's keel down
##             to the ground near the base, and back up.
## Player (player.gd _die -> RespawnShip.player_died(self): true = this takes over the respawn):
##   0 s       death: the ragdoll and its camera as before; an overlay "YENİDEN DOĞUŞ · 13" counts down
##             ("Taşıyıcı iniş gemisi hazırlıyor…").
##   RESPAWN_CUT (5 s)  through RESPAWN_FADE of black the view cuts into a dropship docked under our
##             carrier: first person from the jump seat (the mouse looks round), hp already full (no
##             low-health screen). It drops out of the clamps, dives, brakes on its jets and touches
##             down at RESPAWN_TIME - RESPAWN_DOOR (12.1 s) near our spawn point (landing spot: below).
##   ramp      drops to the ground; the view stands up and walks out to the ramp's foot over the last
##             RESPAWN_STAND s.
##   RESPAWN_TIME (13 s)  player.gd _respawn() (corpse left where we fell, hp, the loadout re-equipped,
##             its camera), then the body is put at the ramp's foot facing out (toward the other planet)
##             with the view's pitch; it snaps to the ground there (player.gd waiting_ground). The ship
##             waits RESPAWN_GROUND s, closes up, flies back into the carrier.
##   Fallback  no carrier / no landing spot / the match ended before the cut / the ship lost: the old
##             respawn (fade, _respawn() at the spawn point) at RESPAWN_TIME.
##   Training  (Game.has_meta("training")): not handled, player.gd keeps its old quick respawn
##             (RESPAWN_DELAY 4 s); no bot ships either. The carriers still hang in the sky.
##   Loadout   (2026-10-06, CoD style) from 0.6 s after death to the landing the YÜKLEME picker
##             (scripts/war/loadout_panel.gd, MODE_RIDE) sits over the upper middle with a free mouse:
##             slot A / slot B by click or 1 / 2; the landing (or the fallback respawn) applies it
##             (Game.set_loadout) and refills the loadout (Game.loadout_refill: reserve, magazines,
##             grenades) right before player.gd _respawn(), then takes the mouse back. Its layer is in
##             group "gameplay_overlay" (hidden at the match end / under the pause menu).
##   Match start  once, ~1 s in (Balance.LOADOUT_START_PICK, not in training): the same picker as a
##             modal (MODE_START, in Game.ui_panels), a pick applies at once, Enter / HAZIR closes it.
## Bots (host / single player) come back in WAVES (2026-10-07, scripts/war/respawn_waves.gd: the clock,
##   the queue, the dead count, the wipe alert, the "DALGA 0:14" label). The entry: enqueue_dead(unit)
##   the moment a unit is confirmed dead (today rival_team.gd / ally_team.gd on_bot_died; later the
##   downed system); the bot gets its team's first wave slot >= RESPAWN_WAVE_MIN s later.
##   Polled 5× a second: each wave RESPAWN_LEAD s before its slot gets ONE ship from its team's carrier
##   landing RESPAWN_DOOR s before the slot with every bot of that wave (RESPAWN_SHIP_CAP seats; more
##   -> a second ship). ai_rival.gd _tick_dead hooks (after the corpse is left, AI_RESPAWN s):
##   hold_bot(self) -> true while it waits for its wave / is still aboard (the bot node is hidden, it
##   stays dead), then bot_exit_xf(self, xf) puts it at its exit slot at the ramp's foot (they step
##   off RESPAWN_STAGGER s apart). No ship -> the old spot at the slot.
## Landing spot: the team's spawn point (the player: main.spawn_transform; bots: the rival base), else
##   the nearest ground on rings up to 21 m (surface arc) that is not dug out more than DUG_MAX below
##   the original surface, level within FLAT_MAX over the skids and the ramp's foot (density raycasts,
##   works with no collision built), and clear of structures, skiffs, drop pods and other ships.
##   The bases are scanned in the background (a little each frame: SCAN_BUDGET_USEC), so a dispatch
##   only checks the cached spots (obstacles, ships, one ray for fresh digging); the full search runs
##   only when the scan is stale or every cached spot is taken.
## Cost notes: a throwaway "warm" ship is built at the start (one-time material costs), sounds and
##   meshes are loaded / built in _ready, the exits are probed on the final approach.
## Multiplayer (scripts/net/** replays them): events() signals, emitted for every ship this machine
## sends (host: the bots'; every machine: its own player's):
##   ship_dispatched(id, team, from, to, land_in)  id local to the sender; team "home" / "rival" = the
##       carrier's physical side (Yurt / Rakip, Bodies preset); from = its clamp now; to = the
##       touchdown point (the ship's origin, on the ground; the ramp side faces the other planet:
##       Dropship.door_dir(to)); land_in = s until the touchdown.
##   ship_landed(id, pos)                          the touchdown (the host's word for the replay)
##   The other side calls RespawnShip.replay_dispatch(id, team, from, to, land_in) and
##   RespawnShip.replay_landed(id, pos): a look-only ship (it starts from its own carrier's clamp).

const Balance := preload("res://scripts/war/balance.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const Build := preload("res://scripts/war/respawn_ship_build.gd")
const Carrier := preload("res://scripts/war/carrier.gd")
const Dropship := preload("res://scripts/war/dropship.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const Waves := preload("res://scripts/war/respawn_waves.gd")

const RINGS := [0.0, 5.0, 9.0, 13.0, 17.0, 21.0]    # m of surface arc around the spawn point
const DUG_MAX := 1.4                   # m below the original surface: dug out
const FLAT_MAX := 0.9                  # m of height difference under the skids / the ramp's foot
## Flatness rays around a candidate, in the landed ship's frame (x toward the ramp, z along it): the four
## skid corners and the ramp's foot.
const FLAT_OFFS := [Vector2(1.8, 2.6), Vector2(1.8, -2.6), Vector2(-1.8, 2.6), Vector2(-1.8, -2.6), Vector2(3.3, 0.0)]
const HOLD_MAX_MS := 9000              # a bot waits aboard at most this long past its respawn time
const SCAN_BUDGET_USEC := 500          # background landing-spot scan: per frame...
const SCAN_EVERY_MS := 6000            # ...each base again after this long...
const SCAN_ENOUGH := 5                 # ...stopping after the ring that brings it to this many spots
const SPOT_FRESH_MS := 15000           # a scan older than this is not used (full search then)

class RespawnEvents extends RefCounted:
	signal ship_dispatched(id: int, team: String, from: Vector3, to: Vector3, land_in: float)
	signal ship_landed(id: int, pos: Vector3)

static var _events: RespawnEvents = null
static var _inst = null                # the live manager (untyped: may be freed)

var carriers := {}                     # "home" / "rival" -> carrier.gd
var _ships := {}                       # id -> dropship.gd (sent from here)
var _remote := {}                      # sender's id -> dropship.gd (replays)
var _next_id := 1
var _bot := {}                         # bot instance id -> {"bot": WeakRef, "ship", "slot", "hold_ms", "wave_ms"}
var _waves: Waves = null               # scripts/war/respawn_waves.gd (child)
var _poll_t := 0.0
var _pl := {}                          # the local player's ride: {"pl", "t", "phase", "ship", "team"}
var _ui_root: Control
var _ui_title: Label
var _ui_sub: Label
var _ui_fill: ColorRect
var _ui_a := 0.0
# The loadout picker (scripts/war/loadout_panel.gd, loaded at runtime): layer > root (our visibility)
# > a transparent click shield + the panel.
var _lp_script = null
var _pick_layer: CanvasLayer
var _pick_root: Control
var _pick: Control
var _pick_mode := -1                   # -1 closed, else LoadoutPanel.MODE_RIDE / MODE_START
var _pick_k := 0.0
var _start_t := 0.0
var _start_done := false
var _spots := {}                       # planet instance id -> {"center", "list": [[pos, score]] (best first), "ms"}
var _scan := {}                        # the running scan: {"body", "center", "ring", "k", "list", "avoid"}
var _scan_next := 0


static func events() -> RespawnEvents:
	if _events == null:
		_events = RespawnEvents.new()
	return _events


static func _mgr():
	if _inst != null and is_instance_valid(_inst) and (_inst as Node).is_inside_tree():
		return _inst
	return null


## player.gd _die: true = the dropship respawn takes over (it calls the player's _respawn() at
## Balance.RESPAWN_TIME); false = do the old respawn.
static func player_died(pl) -> bool:
	var m = _mgr()
	if m == null or pl == null or Game.has_meta("training"):
		return false
	return bool(m._player_start(pl))


## THE entry into the respawn flow (2026-10-07 waves): `unit` is confirmed dead NOW (the wave's
## RESPAWN_WAVE_MIN counts from here). A bot (host / single player) is queued for its team's next wave
## (scripts/war/respawn_waves.gd); the local player goes to his own fixed ride (= player_died: true =
## the ride takes over; player.gd _die calls player_died itself today, so call one of the two for him).
## Callers today: rival_team.gd / ally_team.gd on_bot_died; the downed system calls it instead on a
## give-up / bleed-out / finish. false = nothing took it (no manager, a client, the Eğitim Alanı).
static func enqueue_dead(unit) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if unit == Game.player:
		return player_died(unit)
	if _mgr() == null or Waves.inst() == null:
		return false
	Waves.enqueue(unit)
	return Waves.inst().wave_ms_of(unit) >= 0


## ai_rival.gd _tick_dead (respawn due, corpse left): true = waiting for its wave / still aboard a
## dropship, wait.
static func hold_bot(bot) -> bool:
	var m = _mgr()
	if m == null or bot == null:
		return false
	return bool(m._bot_hold(bot))


## ai_rival.gd _tick_dead: where the respawning bot appears (its ship's exit slot, else `xf`).
static func bot_exit_xf(bot, xf: Transform3D) -> Transform3D:
	var m = _mgr()
	if m == null or bot == null:
		return xf
	var out: Transform3D = m._bot_exit(bot, xf)
	return out


## Multiplayer: another machine's ship (see the header).
static func replay_dispatch(id: int, team: String, from: Vector3, to: Vector3, land_in: float) -> void:
	var m = _mgr()
	if m != null:
		m._replay(id, team, from, to, land_in)


static func replay_landed(id: int, pos: Vector3) -> void:
	var m = _mgr()
	if m != null:
		m._replay_land(id, pos)


func _ready() -> void:
	name = "RespawnShips"
	_inst = self
	_waves = Waves.new()                 # the wave clock / queue / dead count / wipe alert / label
	add_child(_waves)
	Dropship.warm()                     # every ship sound loaded now, not at a touchdown...
	Build.dropship("home")               # ...and both liveries' meshes built now, not at the first dispatch
	Build.dropship("rival")
	_build_carriers()
	_build_ui()
	_build_picker()
	_prewarm.call_deferred()


## One throwaway ship built (and freed in the same frame, never drawn) once the world is up: the
## first ship's one-time costs (particle, flame and label materials) land at the start of the match
## instead of in the middle of it.
func _prewarm() -> void:
	if Game.planet == null or not is_instance_valid(Game.planet):
		return
	var w: Dropship = Dropship.new()
	var p: Vector3 = Game.planet.global_position + Vector3.UP * float(Game.planet.get("radius"))
	w.setup(0, "home", null, 0, Game.planet, p, 5.0, "warm")
	add_child(w)
	w.queue_free()


func _exit_tree() -> void:
	if _inst == self:
		_inst = null
	if _pick != null:
		Game.ui_panels.erase(_pick)


func _process(delta: float) -> void:
	_poll_t -= delta
	if _poll_t <= 0.0:
		_poll_t = 0.2
		_poll_bots()
	_tick_player(delta)
	_tick_ui(delta)
	_tick_start_pick(delta)
	_tick_picker(delta)
	_scan_tick()


# =================================================================================================
# Carriers, dispatch, landing spots
# =================================================================================================

func _build_carriers() -> void:
	for preset: String in ["home", "rival"]:
		var b: Node3D = Bodies.by_preset(preset)
		var other: Node3D = Bodies.by_preset("rival" if preset == "home" else "home")
		if b == null or other == null:
			continue
		var c: Carrier = Carrier.new()
		c.setup(preset, b, _base_point(b, other) - b.global_position, other.global_position - b.global_position)
		add_child(c)
		carriers[preset] = c


## A side's spawn / base point (main.gd spawn_transform, the same rule rival_team.gd uses).
func _base_point(b: Node3D, other: Node3D) -> Vector3:
	var main = get_parent()               # main.gd (current_scene may not be set yet while it builds)
	if main == null or not main.has_method("spawn_transform"):
		main = get_tree().current_scene
	if main != null and main.has_method("spawn_transform"):
		var xf: Transform3D = main.spawn_transform(b, other, 0.0)
		return xf.origin
	return b.global_position + (other.global_position - b.global_position).normalized() * float(b.radius)


## A ship from `team`'s carrier to the ground near `center` on `body`, touching down in `land_in` s.
## null when there is no carrier or no landing spot.
func _dispatch(team: String, body: Node3D, center: Vector3, land_in: float, kind: String) -> Dropship:
	var c = carriers.get(team)
	if c == null or not is_instance_valid(c) or body == null:
		return null
	var spot := _pick_landing(body, center)
	if spot == Vector3.INF:
		return null
	var id := _next_id
	_next_id += 1
	var s: Dropship = Dropship.new()
	s.setup(id, team, c, _free_slot(team), body, spot, land_in, kind)
	add_child(s)
	_ships[id] = s
	s.landed.connect(_on_landed)
	s.tree_exited.connect(_on_ship_gone.bind(id))
	events().ship_dispatched.emit(id, team, s.global_position, spot, land_in)
	return s


func _on_landed(ship: Node3D, pos: Vector3) -> void:
	events().ship_landed.emit(int(ship.get("id")), pos)


func _on_ship_gone(id: int) -> void:
	_ships.erase(id)


## A clamp under the carrier not taken by a docked or docking ship.
func _free_slot(team: String) -> int:
	var used := {}
	for s in _ships.values() + _remote.values():
		if not is_instance_valid(s) or str(s.team) != team:
			continue
		if s.state == Dropship.St.DOCKED or s.is_departing():
			used[int(s.slot)] = true
	for k in Build.CV_SLOTS:
		if not used.has(k):
			return k
	return randi() % Build.CV_SLOTS


## The nearest good ground to `center` (see the header), Vector3.INF if none. From the background
## scan of that base when it is fresh (only cheap checks here: obstacles, ships, one ray to see the
## ground has not been dug since), else the full search now.
func _pick_landing(body: Node3D, center: Vector3) -> Vector3:
	if not body.has_method("raycast_density"):
		return Vector3.INF
	var e = _spots.get(body.get_instance_id())
	if e != null and Time.get_ticks_msec() - int(e["ms"]) < SPOT_FRESH_MS and (e["center"] as Vector3).distance_to(center) < 4.0:
		var avoid := _obstacles(true)
		for cand: Array in e["list"]:
			var p: Vector3 = cand[0]
			var free := true
			for a: Array in avoid:
				if p.distance_to(a[0]) < float(a[1]):
					free = false
					break
			if free and _ground_still(body, p):
				return p
	return _pick_landing_now(body, center)


## The full search, ring by ring (the first ring with a good spot wins; its flattest spot).
func _pick_landing_now(body: Node3D, center: Vector3) -> Vector3:
	var avoid := _obstacles(true)
	for ri in RINGS.size():
		var best := Vector3.INF
		var best_s := INF
		var n := _ring_n(ri)
		for k in n:
			var res := _probe(body, _ring_dir(body, center, ri, k), avoid)
			if res.is_empty():
				continue
			var sc: float = res["score"]
			if sc < best_s:
				best_s = sc
				best = res["pos"]
		if best != Vector3.INF:
			return best
	return Vector3.INF


static func _ring_n(ri: int) -> int:
	return 1 if float(RINGS[ri]) == 0.0 else 10


## Candidate k of ring ri around `center`: the direction from the planet's centre.
func _ring_dir(body: Node3D, center: Vector3, ri: int, k: int) -> Vector3:
	var c := body.global_position
	var r := float(body.get("radius"))
	var ring: float = RINGS[ri]
	var bdir := (center - c).normalized()
	var ref := Dropship.door_dir(center)
	var side := bdir.cross(ref).normalized()
	var phi := TAU * float(k) / float(_ring_n(ri)) + ring * 0.37
	var a := ring / maxf(r, 1.0)
	return (bdir * cos(a) + (ref * cos(phi) + side * sin(phi)) * sin(a)).normalized()


## The ground under a cached spot is still where the scan found it (nobody dug or built it up).
func _ground_still(body: Node3D, p: Vector3) -> bool:
	var up := (p - body.global_position).normalized()
	var h: Dictionary = body.raycast_density(p + up * 3.0, p - up * 3.0, 0.4, true)
	return not h.is_empty() and absf(((h["position"] as Vector3) - p).dot(up)) < 0.6


## Background scan of the bases' landing spots (a little each frame, SCAN_BUDGET_USEC): every
## SCAN_EVERY_MS one side's base, ring by ring, until it has SCAN_ENOUGH good spots (sorted, the
## nearest ring first). Ships use it (_pick_landing), so a dispatch costs a few checks, not a search.
func _scan_tick() -> void:
	if Game.has_meta("training") or Game.match_over:
		return
	var now := Time.get_ticks_msec()
	if _scan.is_empty():
		var bodies := _scan_bodies()
		for i in bodies.size():
			var b: Node3D = bodies[(_scan_next + i) % bodies.size()]
			var e = _spots.get(b.get_instance_id())
			if e == null or now - int(e["ms"]) > SCAN_EVERY_MS:
				_scan_next = (_scan_next + i + 1) % bodies.size()
				var other: Node3D = Game.rival if b == Game.planet else Game.planet
				_scan = {"body": b, "center": _base_point(b, other), "ring": 0, "k": 0, "list": [], "avoid": _obstacles(false), "cand": {}}
				break
		if _scan.is_empty():
			return
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < SCAN_BUDGET_USEC:
		if _scan_step():
			continue
		var b2 = _scan["body"]
		if b2 != null and is_instance_valid(b2):
			var list: Array = _scan["list"]
			list.sort_custom(func(x: Array, y: Array) -> bool: return float(x[1]) < float(y[1]))
			_spots[(b2 as Node).get_instance_id()] = {"center": _scan["center"], "list": list, "ms": now}
		_scan = {}
		return


## One ray of the running scan (a candidate's first ray or one of its flatness rays), so a frame
## never pays more than SCAN_BUDGET_USEC plus one ray; false when the scan is complete.
func _scan_step() -> bool:
	var b = _scan["body"]
	var ri: int = _scan["ring"]
	if b == null or not is_instance_valid(b) or ri >= RINGS.size():
		return false
	var cand: Dictionary = _scan["cand"]
	if cand.is_empty():
		cand = _probe_start(b, _ring_dir(b, _scan["center"], ri, int(_scan["k"])), _scan["avoid"])
		if not cand.is_empty():
			_scan["cand"] = cand
			return true
	else:
		var r := _probe_flat(b, cand)
		if r == 0:
			return true
		if r > 0:
			(_scan["list"] as Array).append([cand["pos"], float(cand["score"]) + float(ri) * 10.0])
		_scan["cand"] = {}
	var k: int = int(_scan["k"]) + 1
	if k >= _ring_n(ri):
		k = 0
		ri += 1
		if (_scan["list"] as Array).size() >= SCAN_ENOUGH:
			ri = RINGS.size()
	_scan["k"] = k
	_scan["ring"] = ri
	return ri < RINGS.size()


## Whose bases get scanned: ours (the player, the allies); the rival's too where its bot team runs.
func _scan_bodies() -> Array:
	var out: Array = []
	if Game.planet != null and is_instance_valid(Game.planet):
		out.append(Game.planet)
	if not Net.is_client() and Game.rival != null and is_instance_valid(Game.rival) \
			and get_tree().get_first_node_in_group("war_rival_team") != null:
		out.append(Game.rival)
	return out


## One candidate straight above direction d: {"pos", "score"} or {} (dug out, uneven, occupied).
func _probe(body: Node3D, d: Vector3, avoid: Array) -> Dictionary:
	var st := _probe_start(body, d, avoid)
	if st.is_empty():
		return {}
	for i in FLAT_OFFS.size():
		var r := _probe_flat(body, st)
		if r < 0:
			return {}
		if r > 0:
			return {"pos": st["pos"], "score": st["score"]}
	return {}


## A candidate's first ray: the ground straight above direction d, not dug out, not taken. {} =
## rejected; else its state for _probe_flat().
func _probe_start(body: Node3D, d: Vector3, avoid: Array) -> Dictionary:
	var c := body.global_position
	var r := float(body.get("radius"))
	var h: Dictionary = body.raycast_density(c + d * (r + 25.0), c + d * maxf(r - 14.0, 1.0), 0.5, true)
	if h.is_empty():
		return {}
	var p: Vector3 = h["position"]
	var dist := p.distance_to(c)
	var orig := r + float(body.surface_height_at(p))
	if orig - dist > DUG_MAX:
		return {}
	for a: Array in avoid:
		if p.distance_to(a[0]) < float(a[1]):
			return {}
	var x := Dropship.door_dir(p)
	return {"p": p, "dist": dist, "d": d, "x": x, "z": x.cross(d).normalized(), "i": 0, "worst": 0.0, "sum": 0.0, "hi": 0.0}


## One flatness ray of a started candidate (skid corners, the ramp's foot): -1 too uneven, 0 more to
## come, 1 done (st "pos": where the ship rests, half way up toward its highest corner; "score").
func _probe_flat(body: Node3D, st: Dictionary) -> int:
	var c := body.global_position
	var i: int = st["i"]
	var o2: Vector2 = FLAT_OFFS[i]
	var p: Vector3 = st["p"]
	var dist: float = st["dist"]
	var qd := (p + (st["x"] as Vector3) * o2.x + (st["z"] as Vector3) * o2.y - c).normalized()
	var hh: Dictionary = body.raycast_density(c + qd * (dist + 4.0), c + qd * (dist - 4.0), 0.3, true)
	if hh.is_empty():
		return -1
	var dh := (hh["position"] as Vector3).distance_to(c) - dist
	st["worst"] = maxf(float(st["worst"]), absf(dh))
	st["sum"] = float(st["sum"]) + absf(dh)
	st["hi"] = maxf(float(st["hi"]), dh)
	if float(st["worst"]) > FLAT_MAX:
		return -1
	st["i"] = i + 1
	if i + 1 < FLAT_OFFS.size():
		return 0
	st["pos"] = p + (st["d"] as Vector3) * (float(st["hi"]) * 0.5)
	st["score"] = float(st["worst"]) * 2.0 + float(st["sum"]) * 0.3
	return 1


## [position, keep-out radius] of everything a ship must not land on (with `ships`: the spots of the
## ships on their way down or on the ground too).
func _obstacles(ships: bool) -> Array:
	var out: Array = []
	for g: Array in [["war_structure", 8.0], ["skiff", 7.0], ["war_drop_pod", 4.5]]:
		for n in get_tree().get_nodes_in_group(str(g[0])):
			if n is Node3D and is_instance_valid(n):
				out.append([(n as Node3D).global_position, float(g[1])])
	if ships:
		for s in _ships.values() + _remote.values():
			if is_instance_valid(s) and not s.is_departing():
				out.append([s.land_pos, 10.0])
	return out


# =================================================================================================
# The local player
# =================================================================================================

func _player_start(pl) -> bool:
	if Game.match_over or Game.planet == null:
		return false
	var team := str(Game.planet.get("preset_name"))
	var c = carriers.get(team)
	if c == null or not is_instance_valid(c):
		return false
	_pl = {"pl": pl, "t": 0.0, "phase": 0, "ship": null, "team": team, "faded": false}
	return true


func _tick_player(delta: float) -> void:
	if _pl.is_empty():
		return
	var pl = _pl["pl"]
	if pl == null or not is_instance_valid(pl) or not (pl as Node).is_inside_tree():
		_player_clear()
		return
	var t: float = float(_pl["t"]) + delta
	_pl["t"] = t
	var T := Balance.RESPAWN_TIME
	var ph: int = int(_pl["phase"])
	var ship = _pl["ship"]
	if not pl.is_dead():
		# Brought back by something else (a new match...): drop the ride, the player's own view.
		if ship != null and is_instance_valid(ship) and ship.has_passenger():
			var cam = pl.get("camera")
			if cam is Camera3D:
				(cam as Camera3D).current = true
			ship.release_player()
		_player_clear()
		return
	if _pick_mode < 0 and t >= 0.6 and not Game.match_over and _lp_script != null:
		_open_picker(int(_lp_script.MODE_RIDE))   # (the YÜKLEME picker for the whole ride)
	match ph:
		0:
			# On the ground as a ragdoll; the cut starts through black.
			if Game.match_over:
				_pl["phase"] = 9
			elif t >= Balance.RESPAWN_CUT - Balance.RESPAWN_FADE:
				_fade(true, Balance.RESPAWN_FADE)
				_pl["phase"] = 1
		1:
			if t >= Balance.RESPAWN_CUT:
				var land_in := T - Balance.RESPAWN_DOOR - t
				var s := _dispatch(str(_pl["team"]), Game.planet, _player_base(), land_in, "player")
				_fade(false, 0.5)
				if s == null:
					_pl["phase"] = 9
				else:
					_pl["ship"] = s
					pl.hp = pl.hp_max            # (no low-health screen while riding; dead until the respawn)
					s.seat_player(pl)
					_pl["phase"] = 2
		2:
			if ship == null or not is_instance_valid(ship):
				_ride_lost(pl)
			elif t >= T - Balance.RESPAWN_STAND and ship.is_landed():
				ship.stand_up(Balance.RESPAWN_STAND)
				_pl["phase"] = 3
			elif t >= T + 2.0:
				_ride_lost(pl)
				ship.release_player()
		3:
			if ship == null or not is_instance_valid(ship):
				_ride_lost(pl)
			elif t >= T:
				_player_land(pl, ship)
		9:
			# The old respawn at RESPAWN_TIME.
			if t >= T - 0.6 and not bool(_pl["faded"]):
				_pl["faded"] = true
				_fade(true, 0.6)
			if t >= T:
				_apply_pick()
				_player_clear()
				pl.call("_respawn")
				_fade(false, 0.8)


## The ship is gone mid-ride: back to the player's own view, the old respawn at RESPAWN_TIME.
func _ride_lost(pl) -> void:
	var cam = pl.get("camera")
	if cam is Camera3D:
		(cam as Camera3D).current = true
	_pl["ship"] = null
	_pl["phase"] = 9
	_pl["faded"] = false


## Touched down, walked out: the respawn, then the body where the view ended.
func _player_land(pl, ship: Dropship) -> void:
	var exit := ship.exit_xf(0)
	_apply_pick()                        # the ride's loadout pick, refilled (Game.set_loadout / loadout_refill)
	_player_clear()
	pl.call("_respawn")                  # corpse, hp, the loadout, its camera (player.gd)
	pl.global_transform = exit
	pl.velocity = Vector3.ZERO
	pl.set("_pitch", Dropship.PITCH_OUT)
	var head = pl.get("head")
	if head is Node3D:
		(head as Node3D).rotation.x = Dropship.PITCH_OUT
	ship.release_player()


func _player_clear() -> void:
	_pl = {}
	if _lp_script != null and _pick_mode == int(_lp_script.MODE_RIDE):
		_close_picker()


func _player_base() -> Vector3:
	var other: Node3D = Game.rival
	return _base_point(Game.planet, other) if other != null else Game.planet.global_position


func _fade(to_black: bool, dur: float) -> void:
	var hud = Game.hud
	if hud == null or not is_instance_valid(hud):
		return
	if to_black and hud.has_method("fade_to_black"):
		hud.fade_to_black(dur)
	elif not to_black and hud.has_method("fade_from_black"):
		hud.fade_from_black(dur)


# =================================================================================================
# Bots
# =================================================================================================

func _poll_bots() -> void:
	for key in _bot.keys():
		var e: Dictionary = _bot[key]
		var b = (e["bot"] as WeakRef).get_ref()
		if b == null or not b.is_dead():
			_bot.erase(key)
	if Net.is_client() or Game.has_meta("training") or Game.match_over or _waves == null:
		return
	var now := Time.get_ticks_msec()
	for w: Dictionary in _waves.take_due(now):
		_wave_dispatch(int(w["wave_ms"]), w["units"], now)


## One wave of a team's dead (slot `wave_ms`, respawn_waves.gd take_due): ships from its carrier that
## touch down RESPAWN_DOOR s before the slot, RESPAWN_SHIP_CAP seats each (a ship of the same slot
## already on its way takes them first; a bigger wave gets a second ship). No ship (no carrier / no
## landing spot): the bots still wait for the slot (_bot_hold), then appear at the base.
func _wave_dispatch(wave_ms: int, units: Array, now: int) -> void:
	var b0 = null
	for u in units:
		if is_instance_valid(u):
			b0 = u
			break
	if b0 == null:
		return
	var tn = b0.get("team_node")
	var body: Node3D = null
	var center := Vector3.INF
	if tn != null and is_instance_valid(tn):
		body = tn.get("body")
		var bx = tn.get("base_xf")
		if bx is Transform3D:
			center = (bx as Transform3D).origin
	if body == null:
		body = Game.rival
	if body == null:
		return
	if center == Vector3.INF:
		var other: Node3D = Game.planet if body != Game.planet else Game.rival
		center = _base_point(body, other) if other != null else body.global_position
	var team := str(body.get("preset_name"))
	var land_ms := wave_ms - int(Balance.RESPAWN_DOOR * 1000.0)
	var ship: Dropship = null
	var no_ship := false
	for b in units:
		if not is_instance_valid(b):
			continue
		if not no_ship and (ship == null or int(ship.bots) >= Balance.RESPAWN_SHIP_CAP):
			ship = _join_ship(team, land_ms)
			if ship == null:
				var land_in := maxf(float(land_ms - now) / 1000.0, Balance.RESPAWN_MIN_FLIGHT)
				ship = _dispatch(team, body, center, land_in, "bots")
				no_ship = ship == null
		var slot := -1
		if ship != null and not no_ship:
			slot = ship.add_bot()
			ship.extend_stay(wave_ms + int((float(slot) * Balance.RESPAWN_STAGGER + 1.0 + Balance.RESPAWN_GROUND) * 1000.0))
		_bot[b.get_instance_id()] = {"bot": weakref(b), "ship": ship if not no_ship else null, "slot": slot,
				"hold_ms": -1, "wave_ms": wave_ms}


## A ship of `team` that touches down within RESPAWN_BATCH s of `land_ms` and has room.
func _join_ship(team: String, land_ms: int) -> Dropship:
	var now := Time.get_ticks_msec()
	var win := int(Balance.RESPAWN_BATCH * 1000.0)
	for s in _ships.values():
		if not is_instance_valid(s) or str(s.kind) != "bots" or str(s.team) != team:
			continue
		if int(s.bots) >= Balance.RESPAWN_SHIP_CAP or s.is_departing():
			continue
		if s.is_landed() and now > int(s.stay_until_ms) - 600:
			continue
		var dms := land_ms - int(s.land_ms)
		if dms < -win or dms > win:
			continue
		return s
	return null


func _bot_hold(b) -> bool:
	var key: int = b.get_instance_id()
	var now := Time.get_ticks_msec()
	if not _bot.has(key):
		# No seat yet: it waits for its wave (the ship goes RESPAWN_LEAD s before the slot).
		if Net.is_client() or Game.has_meta("training") or Game.match_over or _waves == null:
			return false
		if Waves.down_weight(b) == 0.5:
			return true                    # downed, not confirmed yet (scripts/war/downed.gd decides)
		var w: int = _waves.wave_ms_of(b)
		if w < 0:
			# Nobody queued it (a death path without enqueue_dead): queue it now, dated to its death.
			var dt = b.get("_dead_t")
			Waves.enqueue(b, now - int((float(dt) if dt != null else 0.0) * 1000.0))
			w = _waves.wave_ms_of(b)
		if w < 0 or now > w + 1500:
			_waves.forget(b)                 # (no wave after all: the old spot now)
			return false
		_hide_aboard(b)
		return true
	var e: Dictionary = _bot[key]
	var s = e["ship"]
	var k := int(e["slot"])
	var wave_ms := int(e.get("wave_ms", 0))
	if s == null or not is_instance_valid(s) or not (s as Node).is_inside_tree() or k < 0:
		if now < wave_ms:
			_hide_aboard(b)                  # no ship for its wave: it still waits for the slot
			return true
		_bot.erase(key)
		return false
	if int(e["hold_ms"]) < 0:
		e["hold_ms"] = now
	if now - maxi(int(e["hold_ms"]), wave_ms) > HOLD_MAX_MS:
		_bot.erase(key)
		return false
	if s.bot_ready(k):
		return false
	_hide_aboard(b)
	return true


func _hide_aboard(b) -> void:
	if b is Node3D and (b as Node3D).visible:
		(b as Node3D).visible = false      # aboard (the corpse lies where it fell)


func _bot_exit(b, xf: Transform3D) -> Transform3D:
	var key: int = b.get_instance_id()
	if _waves != null:
		_waves.forget(b)                   # back: out of the wave queue
	if not _bot.has(key):
		return xf
	var e: Dictionary = _bot[key]
	_bot.erase(key)
	var s = e["ship"]
	var k := int(e["slot"])
	if s == null or not is_instance_valid(s) or not s.is_landed() or k < 0:
		return xf
	s.bot_out(k)
	var out: Transform3D = s.exit_xf(k)
	out.origin += out.basis.y * 0.25
	return out


# =================================================================================================
# Multiplayer replays
# =================================================================================================

func _replay(id: int, team: String, _from: Vector3, to: Vector3, land_in: float) -> void:
	if _remote.has(id) and is_instance_valid(_remote[id]):
		return
	var body: Node3D = Game.dominant_body(to)
	var s: Dropship = Dropship.new()
	s.setup(-id, team, carriers.get(team), _free_slot(team), body, to, maxf(land_in, 1.0), "replay")
	add_child(s)
	_remote[id] = s
	s.tree_exited.connect(_on_remote_gone.bind(id))


func _replay_land(id: int, pos: Vector3) -> void:
	var s = _remote.get(id)
	if s != null and is_instance_valid(s):
		s.net_land(pos)


func _on_remote_gone(id: int) -> void:
	_remote.erase(id)


# =================================================================================================
# Overlay: "YENİDEN DOĞUŞ · 9"
# =================================================================================================

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)
	_ui_root = Control.new()
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.modulate.a = 0.0
	_ui_root.visible = false
	layer.add_child(_ui_root)
	# A dark glass plate behind the text (readable over snow and a bright cabin; ui_style.gd).
	var holder := CenterContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.anchor_left = 0.0
	holder.anchor_right = 1.0
	holder.anchor_top = 0.64
	holder.anchor_bottom = 0.64
	holder.offset_top = -60.0
	holder.offset_bottom = 60.0
	_ui_root.add_child(holder)
	var plate := UI.panel(holder, UI.glass_box(18.0, Color(UI.SUIT_WHITE, 0.18), 12.0, 0.84))
	plate.custom_minimum_size = Vector2(420, 0)
	plate.draw.connect(func() -> void: plate.draw_rect(Rect2(Vector2(24, 0), Vector2(110, 3)), UI.SUIT_ORANGE))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	plate.add_child(box)
	_ui_title = UI.label(box, "", 34, UI.SUIT_WHITE, 700)
	_ui_title.add_theme_font_override("font", UI.font_caps(700, 4))         # (the design system, ui_style.gd)
	_ui_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ui_title.add_theme_constant_override("outline_size", 8)
	_ui_title.add_theme_color_override("font_outline_color", UI.OUTLINE)
	_ui_sub = UI.label(box, "", 16, Color(UI.TEXT, 0.85), 500)
	_ui_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ui_sub.add_theme_constant_override("outline_size", 6)
	_ui_sub.add_theme_color_override("font_outline_color", UI.OUTLINE)
	var bar := CenterContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bar)
	var bg := ColorRect.new()
	bg.custom_minimum_size = Vector2(280.0, 3.0)
	bg.color = Color(UI.SUIT_WHITE, 0.12)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(bg)
	_ui_fill = ColorRect.new()
	_ui_fill.color = UI.SUIT_ORANGE
	_ui_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_fill.position = Vector2.ZERO
	_ui_fill.size = Vector2(0.0, 3.0)
	bg.add_child(_ui_fill)


func _tick_ui(delta: float) -> void:
	var want := 0.0
	if not _pl.is_empty() and float(_pl["t"]) > 0.6 and not Game.overlays_hidden():
		want = 1.0
	_ui_a = move_toward(_ui_a, want, delta * 3.0)
	_ui_root.modulate.a = _ui_a
	_ui_root.visible = _ui_a > 0.01
	if _pl.is_empty() or not _ui_root.visible:
		return
	var t := float(_pl["t"])
	var T := Balance.RESPAWN_TIME
	_ui_title.text = "YENİDEN DOĞUŞ  ·  %d" % ceili(maxf(T - t, 0.0))
	var sub := "Taşıyıcı iniş gemisi hazırlıyor…"
	var ph := int(_pl["phase"])
	var ship = _pl["ship"]
	if ph == 9:
		sub = "Yeniden doğuluyor…"
	elif ph >= 2 and ship != null and is_instance_valid(ship):
		if ship.is_landed():
			sub = "İniş tamam — rampa açılıyor…"
		else:
			var alt: float = ((ship as Node3D).global_position - (ship.land_pos as Vector3)).dot(ship.land_up as Vector3)
			sub = "İniş Gemisi  ·  irtifa %d m" % maxi(int(alt), 0)
	_ui_sub.text = sub
	_ui_fill.size = Vector2(280.0 * clampf(t / T, 0.0, 1.0), 3.0)


# =================================================================================================
# The loadout picker (YÜKLEME: the ride, the match start)
# =================================================================================================

func _build_picker() -> void:
	var s = load("res://scripts/war/loadout_panel.gd")
	if not (s is Script) or not (s as Script).can_instantiate():
		return
	_lp_script = s
	_pick_layer = CanvasLayer.new()
	_pick_layer.layer = 7
	add_child(_pick_layer)
	_pick_root = Control.new()
	_pick_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pick_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pick_root.visible = false
	_pick_layer.add_child(_pick_root)
	# A transparent shield: a click beside the panel does not take the mouse back (Game._unhandled_input).
	var shield := ColorRect.new()
	shield.color = Color(0, 0, 0, 0)
	shield.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shield.mouse_filter = Control.MOUSE_FILTER_STOP
	_pick_root.add_child(shield)
	_pick = s.new()
	_pick.name = "LoadoutPicker"
	_pick_root.add_child(_pick)
	_pick.connect("done", _on_pick_done)


## Opens the picker in `mode` (LoadoutPanel.MODE_RIDE: an overlay, applied at the landing;
## MODE_START: modal, applied at once). The mouse is freed.
func _open_picker(mode: int) -> void:
	if _pick == null:
		return
	_pick_mode = mode
	_pick.call("setup", mode)
	var start := mode == int(_lp_script.MODE_START)
	_pick.set("modal_open", start)
	if start:
		_pick_layer.remove_from_group("gameplay_overlay")
		if not Game.ui_panels.has(_pick):
			Game.ui_panels.append(_pick)
	else:
		_pick_layer.add_to_group("gameplay_overlay")
	_pick_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if Game.sfx:
		Game.sfx.play("open", -12.0, 1.1)


func _close_picker() -> void:
	if _pick_mode < 0:
		return
	_pick_mode = -1
	if _pick != null:
		_pick.set("modal_open", false)
		Game.ui_panels.erase(_pick)
	if not Game.ui_panel_open() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## The respawn (landing / fallback): the ride's pick becomes the loadout, then the refill.
func _apply_pick() -> void:
	if _pick != null and _lp_script != null and _pick_mode == int(_lp_script.MODE_RIDE):
		Game.set_loadout(str(_pick.get("pick_a")), str(_pick.get("pick_b")), false)
	Game.loadout_refill()
	if _lp_script != null and _pick_mode == int(_lp_script.MODE_RIDE):
		_close_picker()


func _on_pick_done() -> void:
	if _lp_script != null and _pick_mode == int(_lp_script.MODE_START):
		_close_picker()
		if Game.sfx:
			Game.sfx.play("close", -12.0, 1.1)


## Once at the match start: the modal picker as soon as the player is in control.
func _tick_start_pick(delta: float) -> void:
	if _lp_script != null and _pick_mode == int(_lp_script.MODE_START):
		var p0 = Game.player
		if Game.match_over or p0 == null or not is_instance_valid(p0) or p0.is_dead() or p0.get("vehicle") != null:
			_close_picker()
		return
	if _start_done:
		return
	if Game.ui_panel_open():
		return                             # (the multiplayer loading cover, a menu: the clock waits)
	_start_t += delta
	if not Balance.LOADOUT_START_PICK or Game.has_meta("training") or _lp_script == null or _start_t > 25.0:
		_start_done = true
		return
	if _start_t < 1.2 or Game.match_over or _pick_mode >= 0:
		return
	var p = Game.player
	if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree() or p.is_dead() or p.get("vehicle") != null \
			or Game.controlled != p:
		return
	_start_done = true
	_open_picker(int(_lp_script.MODE_START))


## Per frame: fade, scale and place the picker (ride: the upper middle, over the YENİDEN DOĞUŞ plate;
## start: the middle); keep the mouse free while it is up.
func _tick_picker(delta: float) -> void:
	if _pick_root == null:
		return
	_pick_k = move_toward(_pick_k, 1.0 if _pick_mode >= 0 else 0.0, delta * (5.0 if _pick_mode >= 0 else 7.0))
	_pick_root.visible = _pick_k > 0.01
	if not _pick_root.visible:
		return
	_pick_root.modulate.a = UI.smooth(_pick_k)
	var vs := _pick_root.get_viewport_rect().size
	var ps: Vector2 = _pick.get("page_size")
	var k := clampf(vs.y / 1080.0, 0.6, 2.0)
	k = minf(k, (vs.x - 40.0) / maxf(ps.x, 1.0))
	_pick.size = ps
	_pick.scale = Vector2.ONE * k * lerpf(0.97, 1.0, UI.smooth(_pick_k))
	var cy := 0.5 if _pick_mode == int(_lp_script.MODE_START) else 0.33
	_pick.position = Vector2(vs.x * 0.5, vs.y * cy) - ps * k * 0.5
	if _pick_mode >= 0 and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE and not get_tree().paused \
			and (_pick_mode == int(_lp_script.MODE_START) or not Game.ui_panel_open()):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE       # (the pause menu took it back on closing)
