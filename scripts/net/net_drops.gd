extends Node
## Drops (child "Drops" of the Net autoload): material loot (scripts/war/loot.gd) and the rival's drop
## pods (scripts/war/drop_pod.gd). Both are host-authoritative; the client shows mirrors / puppets.
##
## Loot (Loot.events(); the host spawns every pickup, a client only asks):
##   host -> client (reliable)
##     loot      {id, pos, amount, age}   loot_spawned -> Loot.spawn_mirror (also the late-join list)
##     loot_amt  {id, amount}             loot_updated (a drop merged in) -> Loot.set_amount
##     loot_gone {id, yours, amount}      loot_taken / loot_expired -> Loot.taken(id, yours, amount):
##                                        yours = the client's player took it (TAKER_PEER): ITS
##                                        Game.material gets the amount there, once (this message is
##                                        the only grant; a repeated pickup request finds it gone)
##   client -> host (reliable)
##     loot_pick {id}                     pickup_requested (≤ 1/s per pickup) -> Loot.claim(id, TAKER_PEER)
##     loot_drop {pos, amount}            drop_requested (the client player died; his share is already
##                                        off his Game.material) -> Loot.drop(pos, amount)
##   The host keeps every pickup's amount from its own events (claim() has freed the node by the time
##   loot_taken fires).
## Drop pods (RivalTeam.events(), co-op host only; the crews are ordinary bots: net_bots.gd):
##   host -> client (reliable)
##     pod       {id, from, vel, side, launcher}  pod_fired -> DropPod.puppet (+ the cannon's shot look)
##     pod_land  {id, pos}                        pod_landed -> pod.net_land(pos)
##     pod_down  {id, pos}                        pod_destroyed (shot down / lost) -> pod.net_destroy(pos)
##   Late join: pods in flight (a puppet from where it is now) and landed ones (a puppet put down at
##   once). Air defence needs nothing here: the client's Uçaksavar rounds and armed-skiff rounds are
##   fired for real on the host (net_world.gd), whose pod takes the hits; the client's puppet ignores
##   shot_down; a flying pod has no collider for bullets. The puppets are in "war_drop_pod", so the
##   client's war_hud.gd "DÜŞMAN ÇIKARMASI GELİYOR!" warning works as on the host.
## Weapon drops (WeaponDrop.events(), scripts/war/weapon_drop.gd; like the loot, every message reliable):
##   host -> client
##     wdrop      {id, data, age}           drop_spawned -> WeaponDrop.spawn_mirror (+ the late-join list)
##     wdrop_gone {id, yours, data}         drop_taken / drop_expired -> WeaponDrop.taken(id, yours, data):
##                                          yours = our pickup request won (data = what claim() returned:
##                                          the client's player.take_dropped_gun equips it, once)
##   client -> host
##     wdrop_pick {id}                      pickup_requested -> WeaponDrop.claim(id, TAKER_PEER)
##     wdrop_req  {data}                    drop_requested (the client's death / swap) -> drop_data
##   data = {item, pos, vel, state, ammo, reserve}: validated and clamped on receipt both ways (_wdata).
## Respawn dropships (RespawnShip.events(), scripts/war/respawn_ship.gd), both ways, reliable: each
## machine forwards the ships IT sends (host: the bots'; each: its own player's), the other replays
## them look-only (replays emit nothing: no echo):
##     ship       {id, side, from, to, land_in}   ship_dispatched -> RespawnShip.replay_dispatch
##     ship_land  {id, pos}                       ship_landed -> RespawnShip.replay_landed
##   side: the carrier's PHYSICAL side (0 = the Yurt preset "home", 1 = the Rakip preset "rival"; the
##   same strings on both machines, even in PvP where the client's Game.planet is swapped). Ids are
##   the sender's own; the receiver keeps replays apart from its own ships (respawn_ship.gd _remote),
##   and only one other machine sends, so they cannot collide. A ship in flight is not sent to a late
##   joiner (cosmetic). The carriers run off the clock: nothing to send. The bots riding a ship stay
##   "dead" in the snapshots until they step off (net_bot.gd then reappears at the ramp's foot).
## Buried caches (Caches.events(), scripts/war/caches.gd; positions and contents come from the seed, the
## host owns the OPENED state; finds are local, from the synced terrain), reliable:
##   client -> host   cache_open {id}                  open_requested -> Caches.claim(id, TAKER_PEER)
##   host -> client   cache_opened {id, yours, contents}   cache_opened (either player's) ->
##                                       Caches.opened_remote(id, yours, contents) (yours: the client's
##                                       request won; its personal items are granted there, once)
##   Late join: the opened ids (Caches.snapshot -> apply_snapshot). Guns come as weapon drops (above).
## Cave-ins (CaveIn.events(), scripts/war/cave_in.gd; the fill brushes and the damage sync themselves):
##   host -> client   cave_warn {pos} (unreliable)    cave_warning -> CaveIn.net_warning(pos)
##                    cave_fall {pos, radius}         cave_collapse -> CaveIn.net_collapse(pos, radius)
##   both ways        entrench {pos, dir}             entrenched (our own berms) -> net_entrenched (look)
##                    bury {depth}                    buried(target = our remote avatar) -> the other
##                                                    machine: CaveIn.bury(Game.player, depth)
##   Nothing for a late join (a groaning roof just goes on groaning on the host).
## Supply pods (SupplyPod.events(), scripts/war/supply_pod.gd; the gun itself is a weapon drop), reliable:
##   host -> client   spod {id, data}        pod_spawned -> SupplyPod.spawn_mirror(id, data) (+ late join:
##                                           SupplyPod.snapshot, the pods still in flight)
##                    spod_land {id, pos}    pod_landed -> SupplyPod.net_land
##                    spod_down {id, pos}    pod_destroyed -> SupplyPod.net_destroy
##   client -> host   spod_call {req, gun, to}   call_requested (already paid there) ->
##                                           SupplyPod.host_request; a refusal goes back:
##   host -> client   spod_no {req, why}     -> SupplyPod.refused(req, why) (the refund)
##   data = {gun, side (absolute), to, dir, land_in, req}: validated on receipt (_sdata).
## Control zones (ControlPoints.events(), scripts/war/control_points.gd; both machines build the same
## zones from the POI sites, the host decides owner / progress; each machine pays its own income):
##   host -> client   cp {states} (reliable)  state_changed (≤ 5 Hz, the changed zones) -> inst.net_apply
##                                            (+ late join: snapshot(), every zone)
##   state = [preset ("home" Yurt / "rival" Rakip), i, owner (-1 / absolute side), progress (+1 = side 0
##   … -1 = side 1), contested]; held here until the client's zones exist (_cp_flush).
## Meteor showers (MeteorShower.events(), scripts/war/meteor_shower.gd; the host decides; craters come
## through the terrain sync, veins are a pure function of the seed), host -> client, reliable:
##   met_shower {body, impacts, warn}           shower_started -> MeteorShower.net_shower
##   met_in {id, body, from, to, flight}        meteor_incoming -> net_incoming (the look)
##   met_land {id, body, pos, amount}           meteor_landed -> net_landed (the deposit: the drill bonus)
##   met_gone {id}                              meteor_gone -> net_gone
##   body = Net.body_index (physical: 0 Yurt / 1 Rakip). Nothing for a late join (a shower is short).
## Respawn waves (RespawnWaves.events(), scripts/war/respawn_waves.gd; the bots are host-simulated, so the
## wave clock, the queue and the team-wipe check run on the host; each player's own respawn stays local):
##   host -> client (reliable)  waves {d}:
##     {"wave_t": [s0, s1]}    waves_changed (on change): s to each side's next bot wave, by ABSOLUTE
##                             side (Net.abs_side: 0 = the host's side; co-op: [home_s, rival_s]), -1 none
##                             -> RespawnWaves.net_waves(home_s, rival_s) in the client's local teams
##     {"wipe": side, "secs"}  team_wiped: that absolute side was wiped, its next wave in secs ->
##                             RespawnWaves.net_wipe(Net.local_team(side), secs) (the alert line)
##   Late join: the countdowns ride the snapshot ("waves", the wave_t form).
## Corpses (scripts/war/corpse.gd) are local on each machine: net_bot.gd / remote_avatar.gd leave()
## their own dead ragdolls at the respawn; nothing goes over the wire.

const Balance := preload("res://scripts/war/balance.gd")
const LOOT_PATH := "res://scripts/war/loot.gd"
const WDROP_PATH := "res://scripts/war/weapon_drop.gd"
const TEAM_PATH := "res://scripts/war/rival_team.gd"
const POD_PATH := "res://scripts/war/drop_pod.gd"
const ROUND_PATH := "res://scripts/war/flak_round.gd"
const SHIP_PATH := "res://scripts/war/respawn_ship.gd"
const CACHE_PATH := "res://scripts/war/caches.gd"
const CACHE_KINDS := ["gun", "mat", "gren", "att", "buff"]
const CAVE_PATH := "res://scripts/war/cave_in.gd"
const SUPPLY_PATH := "res://scripts/war/supply_pod.gd"
const CP_PATH := "res://scripts/war/control_points.gd"
const METEOR_PATH := "res://scripts/war/meteor_shower.gd"
const WAVES_PATH := "res://scripts/war/respawn_waves.gd"
const LOOT_MAX := 100000.0              # m³: a client's drop is clamped to this (sanity)

var _main: Node
var _loot_hooked := false
var _wdrop_hooked := false
var _ships_hooked := false
var _waves_hooked := false
var _pods_hooked := false
var _caches_hooked := false
var _cave_hooked := false
var _supply_hooked := false
var _cp_hooked := false
var _met_hooked := false
var _cp_pending := {}                   # client: "preset:i" -> state, until the zones exist
var _cp_tries := 0
var _loot_amt := {}                     # host: pickup id -> amount (from its events)
var _pods := {}                         # pod id -> drop_pod.gd (host: real; client: puppet)
var _pod_landed := {}                   # host: pod id -> landing point


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func begin(main: Node) -> void:
	reset()
	_main = main
	_hook()


func reset() -> void:
	_loot_amt.clear()
	_pods.clear()
	_pod_landed.clear()
	_cp_pending.clear()
	_main = null


func on_peer_gone() -> void:
	pass


func _hook() -> void:
	if not _loot_hooked and ResourceLoader.exists(LOOT_PATH):
		var ev = load(LOOT_PATH).call("events")
		if ev != null:
			ev.connect("loot_spawned", _on_loot_spawned)
			ev.connect("loot_updated", _on_loot_updated)
			ev.connect("loot_taken", _on_loot_taken)
			ev.connect("loot_expired", _on_loot_expired)
			ev.connect("pickup_requested", _on_pickup_requested)
			ev.connect("drop_requested", _on_drop_requested)
			_loot_hooked = true
	if not _wdrop_hooked and ResourceLoader.exists(WDROP_PATH):
		var wev = load(WDROP_PATH).call("events")
		if wev != null:
			wev.connect("drop_spawned", _on_wdrop_spawned)
			wev.connect("drop_taken", _on_wdrop_taken)
			wev.connect("drop_expired", _on_wdrop_expired)
			wev.connect("pickup_requested", _on_wdrop_pick_requested)
			wev.connect("drop_requested", _on_wdrop_requested)
			_wdrop_hooked = true
	if not _ships_hooked and ResourceLoader.exists(SHIP_PATH):
		var sev = load(SHIP_PATH).call("events")
		if sev != null:
			sev.connect("ship_dispatched", _on_ship_dispatched)
			sev.connect("ship_landed", _on_ship_landed)
			_ships_hooked = true
	if not _waves_hooked and ResourceLoader.exists(WAVES_PATH):
		var wvev = load(WAVES_PATH).call("events")
		if wvev != null and wvev.has_signal("team_wiped"):
			wvev.connect("waves_changed", _on_waves_changed)
			wvev.connect("team_wiped", _on_team_wiped)
			_waves_hooked = true
	if not _caches_hooked and ResourceLoader.exists(CACHE_PATH):
		var cev = load(CACHE_PATH).call("events")
		if cev != null and cev.has_signal("open_requested"):
			cev.connect("open_requested", _on_cache_open_requested)
			cev.connect("cache_opened", _on_cache_opened)
			_caches_hooked = true
	if not _cave_hooked and ResourceLoader.exists(CAVE_PATH):
		var vev = load(CAVE_PATH).call("events")
		if vev != null and vev.has_signal("cave_collapse"):
			vev.connect("cave_warning", _on_cave_warning)
			vev.connect("cave_collapse", _on_cave_collapse)
			vev.connect("entrenched", _on_entrenched)
			vev.connect("buried", _on_buried)
			_cave_hooked = true
	if not _supply_hooked and ResourceLoader.exists(SUPPLY_PATH):
		var pev = load(SUPPLY_PATH).call("events")
		if pev != null and pev.has_signal("call_requested"):
			pev.connect("pod_spawned", _on_spod_spawned)
			pev.connect("pod_landed", _on_spod_landed)
			pev.connect("pod_destroyed", _on_spod_destroyed)
			pev.connect("call_requested", _on_spod_call)
			_supply_hooked = true
	if not _cp_hooked and ResourceLoader.exists(CP_PATH):
		var cpev = load(CP_PATH).call("events")
		if cpev != null and cpev.has_signal("state_changed"):
			cpev.connect("state_changed", _on_cp_changed)
			_cp_hooked = true
	if not _met_hooked and ResourceLoader.exists(METEOR_PATH):
		var mev = load(METEOR_PATH).call("events")
		if mev != null and mev.has_signal("meteor_landed"):
			mev.connect("shower_started", _on_met_shower)
			mev.connect("meteor_incoming", _on_met_in)
			mev.connect("meteor_landed", _on_met_land)
			mev.connect("meteor_gone", _on_met_gone)
			_met_hooked = true
	if not _pods_hooked and ResourceLoader.exists(TEAM_PATH):
		var scr = load(TEAM_PATH)
		if (scr as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "events"):
			var ev = scr.call("events")
			if ev != null and ev.has_signal("pod_fired"):
				ev.connect("pod_fired", _on_pod_fired)
				ev.connect("pod_landed", _on_pod_landed)
				ev.connect("pod_destroyed", _on_pod_destroyed)
				_pods_hooked = true


func _host_live() -> bool:
	return Net.is_host() and Net.in_game


func _sender_ok() -> bool:
	return Net.active and Net.in_game and multiplayer.get_remote_sender_id() == Net.other_id


func _loot():
	return load(LOOT_PATH)


# =================================================================================================
# Loot
# =================================================================================================

func _on_loot_spawned(id: int, pos: Vector3, amount: float) -> void:
	if not _host_live():
		return
	_loot_amt[id] = amount
	if Net.live():
		_rx_loot.rpc_id(Net.other_id, id, pos, amount, 0.0)


func _on_loot_updated(id: int, amount: float) -> void:
	if not _host_live():
		return
	_loot_amt[id] = amount
	if Net.live():
		_rx_loot_amt.rpc_id(Net.other_id, id, amount)


func _on_loot_taken(id: int, by: String) -> void:
	if not _host_live():
		return
	var amt := float(_loot_amt.get(id, -1.0))
	_loot_amt.erase(id)
	if Net.live():
		_rx_loot_gone.rpc_id(Net.other_id, id, by == str(_loot().TAKER_PEER), amt)


func _on_loot_expired(id: int) -> void:
	if not _host_live():
		return
	_loot_amt.erase(id)
	if Net.live():
		_rx_loot_gone.rpc_id(Net.other_id, id, false, -1.0)


func _on_pickup_requested(id: int) -> void:
	if Net.is_client() and Net.live():
		_rx_loot_pick.rpc_id(1, id)


func _on_drop_requested(pos: Vector3, amount: float) -> void:
	if Net.is_client() and Net.live():
		_rx_loot_drop.rpc_id(1, pos, amount)


@rpc("authority", "call_remote", "reliable")
func _rx_loot(id: int, pos: Vector3, amount: float, age: float) -> void:
	if Net.is_server or not Net.world_ready:
		return
	_loot().call("spawn_mirror", id, pos, maxf(amount, 0.0), maxf(age, 0.0))


@rpc("authority", "call_remote", "reliable")
func _rx_loot_amt(id: int, amount: float) -> void:
	if Net.is_server or not Net.world_ready:
		return
	_loot().call("set_amount", id, maxf(amount, 0.0))
	# The host's merge makes the pickup fresh again (loot.gd drop: _age = 0): the mirror too, or it
	# would expire here up to LOOT_TIME s before the host's.
	var l = _loot().call("find", id)
	if l != null and is_instance_valid(l):
		l.set("_age", 0.0)


@rpc("authority", "call_remote", "reliable")
func _rx_loot_gone(id: int, yours: bool, amount: float) -> void:
	if Net.is_server or not Net.in_game:
		return
	_loot().call("taken", id, yours, amount)


@rpc("any_peer", "call_remote", "reliable")
func _rx_loot_pick(id: int) -> void:
	if not Net.is_host() or not _sender_ok() or not Net.peer_ready:
		return
	var l = _loot()
	l.call("claim", id, str(l.TAKER_PEER))     # (the first claim wins; loot_taken tells the client)


@rpc("any_peer", "call_remote", "reliable")
func _rx_loot_drop(pos: Vector3, amount: float) -> void:
	if not Net.is_host() or not _sender_ok() or not Net.peer_ready:
		return
	if not pos.is_finite() or not is_finite(amount) or amount <= 0.0:
		return
	_loot().call("drop", pos, minf(amount, LOOT_MAX))


# =================================================================================================
# Weapon drops
# =================================================================================================

func _wdrop():
	return load(WDROP_PATH)


## A weapon drop's data as received: only known guns, finite vectors (vel ≤ 20 m/s), the gun state's
## known keys as small ints, a plain ammo id, reserve 0..999. {} = refused.
func _wdata(d) -> Dictionary:
	if not (d is Dictionary):
		return {}
	var src := d as Dictionary
	var item := str(src.get("item", ""))
	var names = _wdrop().get("NAMES")
	if item == "" or not (names is Dictionary) or not (names as Dictionary).has(item):
		return {}
	var pos = src.get("pos")
	if not (pos is Vector3) or not (pos as Vector3).is_finite():
		return {}
	var vel = src.get("vel")
	var v: Vector3 = (vel as Vector3).limit_length(20.0) if vel is Vector3 and (vel as Vector3).is_finite() else Vector3.ZERO
	var st := {}
	var s = src.get("state")
	if s is Dictionary:
		var sd := s as Dictionary
		for k in ["mag", "ammo", "fire_mode"]:
			if sd.has(k):
				st[k] = clampi(int(sd[k]), 0, 999)
		var m = sd.get("mags")
		if m is Array:
			var mags: Array = []
			for i in mini((m as Array).size(), 8):
				mags.append(clampi(int(m[i]), 0, 999))
			st["mags"] = mags
		if sd.get("att") is Dictionary:
			# The fitted attachments the gun carries (weapon_drop.gd shows them): known ids only.
			st["att"] = Net.players.clean_att(item, sd["att"])
	var ammo := str(src.get("ammo", ""))
	if ammo.length() > 24 or (ammo != "" and not ammo.is_valid_ascii_identifier()):
		ammo = ""
	return {"item": item, "pos": pos, "vel": v, "state": st, "ammo": ammo,
			"reserve": clampi(int(src.get("reserve", 0)), 0, 999)}


func _on_wdrop_spawned(id: int, data: Dictionary) -> void:
	if _host_live() and Net.live():
		_rx_wdrop.rpc_id(Net.other_id, id, data, 0.0)


func _on_wdrop_taken(id: int, by: String) -> void:
	# (the client's own win goes out from _rx_wdrop_pick, with the data claim() returned)
	if _host_live() and Net.live() and by != str(_wdrop().TAKER_PEER):
		_rx_wdrop_gone.rpc_id(Net.other_id, id, false, {})


func _on_wdrop_expired(id: int) -> void:
	if _host_live() and Net.live():
		_rx_wdrop_gone.rpc_id(Net.other_id, id, false, {})


func _on_wdrop_pick_requested(id: int) -> void:
	if Net.is_client() and Net.live():
		_rx_wdrop_pick.rpc_id(1, id)


func _on_wdrop_requested(data: Dictionary) -> void:
	if Net.is_client() and Net.live():
		_rx_wdrop_req.rpc_id(1, data)


@rpc("authority", "call_remote", "reliable")
func _rx_wdrop(id: int, data: Dictionary, age: float) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var d := _wdata(data)
	if not d.is_empty():
		_wdrop().call("spawn_mirror", id, d, maxf(age, 0.0))


@rpc("authority", "call_remote", "reliable")
func _rx_wdrop_gone(id: int, yours: bool, data: Dictionary) -> void:
	if Net.is_server or not Net.in_game:
		return
	_wdrop().call("taken", id, yours, _wdata(data) if yours else {})


@rpc("any_peer", "call_remote", "reliable")
func _rx_wdrop_pick(id: int) -> void:
	if not Net.is_host() or not _sender_ok() or not Net.peer_ready:
		return
	var w = _wdrop()
	var d = w.call("claim", id, str(w.TAKER_PEER))     # (the first claim wins: {} = already gone)
	if d is Dictionary and not (d as Dictionary).is_empty() and Net.live():
		_rx_wdrop_gone.rpc_id(Net.other_id, id, true, d)


@rpc("any_peer", "call_remote", "reliable")
func _rx_wdrop_req(data: Dictionary) -> void:
	if not Net.is_host() or not _sender_ok() or not Net.peer_ready:
		return
	var d := _wdata(data)
	if not d.is_empty():
		_wdrop().call("drop_data", d)


# =================================================================================================
# Buried caches
# =================================================================================================

## A cache's contents as received: known kinds only, plain bounded values. ([] = nothing usable.)
func _cdata(c) -> Array:
	var out: Array = []
	if not (c is Array):
		return out
	for e in (c as Array).slice(0, 12):
		if not (e is Dictionary):
			continue
		var src := e as Dictionary
		var t := str(src.get("t", ""))
		if not (t in CACHE_KINDS):
			continue
		var o := {"t": t}
		if src.has("n"):
			if t == "gren":
				o["n"] = clampi(int(src["n"]), 0, 20)
			else:
				o["n"] = clampf(float(src["n"]), 0.0, 5000.0)
		if src.has("k"):
			o["k"] = int(src["k"])
		if src.has("s"):
			o["s"] = clampf(float(src["s"]), 0.0, 600.0)
		if src.has("id"):
			var id := str(src["id"])
			if id.length() > 24 or not id.is_valid_ascii_identifier():
				continue
			o["id"] = id
		out.append(o)
	return out


func _on_cache_open_requested(id: int) -> void:
	if Net.is_client() and Net.live():
		_rx_cache_open.rpc_id(1, id)


## Host: a cache opened (ours or, through _rx_cache_open's claim, the client's): the client mirrors it.
func _on_cache_opened(id: int, by: String, contents: Array) -> void:
	if _host_live() and Net.live():
		_rx_cache_opened.rpc_id(Net.other_id, id, by == str(load(CACHE_PATH).TAKER_PEER), contents)


@rpc("any_peer", "call_remote", "reliable")
func _rx_cache_open(id: int) -> void:
	if not Net.is_host() or not _sender_ok() or not Net.peer_ready:
		return
	var cs = load(CACHE_PATH)
	cs.call("claim", id, str(cs.TAKER_PEER))      # (the first claim wins; cache_opened carries the answer)


@rpc("authority", "call_remote", "reliable")
func _rx_cache_opened(id: int, yours: bool, contents: Array) -> void:
	if Net.is_server or not Net.in_game:
		return
	load(CACHE_PATH).call("opened_remote", id, yours, _cdata(contents))


# =================================================================================================
# Cave-ins and entrench
# =================================================================================================

func _on_cave_warning(pos: Vector3) -> void:
	if _host_live() and Net.live():
		_rx_cave_warn.rpc_id(Net.other_id, pos)


func _on_cave_collapse(pos: Vector3, radius: float) -> void:
	if _host_live() and Net.live():
		_rx_cave_fall.rpc_id(Net.other_id, pos, radius)


func _on_entrenched(pos: Vector3, dir: Vector3) -> void:
	if Net.live() and Net.in_game:
		_rx_entrench.rpc_id(Net.other_id, pos, dir)


## A collapse / a dirt hit buried the other player's avatar here: his machine buries him.
func _on_buried(target: Node3D, depth: float) -> void:
	if Net.live() and Net.in_game and target != null and is_instance_valid(target) and target == Net.players.avatar:
		_rx_bury.rpc_id(Net.other_id, depth)


@rpc("authority", "call_remote", "unreliable")
func _rx_cave_warn(pos: Vector3) -> void:
	if Net.is_server or not Net.in_game or not pos.is_finite():
		return
	load(CAVE_PATH).call("net_warning", pos)


@rpc("authority", "call_remote", "reliable")
func _rx_cave_fall(pos: Vector3, radius: float) -> void:
	if Net.is_server or not Net.in_game or not pos.is_finite() or not is_finite(radius):
		return
	load(CAVE_PATH).call("net_collapse", pos, clampf(radius, 0.5, 30.0))


@rpc("any_peer", "call_remote", "reliable")
func _rx_entrench(pos: Vector3, dir: Vector3) -> void:
	if not _sender_ok() or not pos.is_finite() or not dir.is_finite():
		return
	load(CAVE_PATH).call("net_entrenched", pos, dir.normalized() if dir.length_squared() > 1e-6 else Vector3.FORWARD)


@rpc("any_peer", "call_remote", "reliable")
func _rx_bury(depth: float) -> void:
	if not _sender_ok() or not is_finite(depth):
		return
	var pl = Game.player
	if pl != null and is_instance_valid(pl):
		load(CAVE_PATH).call("bury", pl, clampf(depth, -2.0, 4.0))


# =================================================================================================
# Supply pods (İkmal kapsülü)
# =================================================================================================

## A supply pod's data as received: a known pod gun, side 0/1, finite points, land_in 0..30 s. {} = refused.
func _sdata(d) -> Dictionary:
	if not (d is Dictionary):
		return {}
	var src := d as Dictionary
	var g := str(src.get("gun", ""))
	if not (g in Balance.SUPPLY_GUNS):
		return {}
	var to = src.get("to")
	var dir = src.get("dir")
	if not (to is Vector3) or not (to as Vector3).is_finite():
		return {}
	var dv: Vector3 = (dir as Vector3).normalized() if dir is Vector3 and (dir as Vector3).is_finite() \
			and (dir as Vector3).length_squared() > 1e-6 else Vector3.RIGHT
	return {"gun": g, "side": clampi(int(src.get("side", 0)), 0, 1), "to": to, "dir": dv,
			"land_in": clampf(float(src.get("land_in", 0.0)), 0.0, 30.0), "req": int(src.get("req", -1))}


func _on_spod_spawned(id: int, data: Dictionary) -> void:
	if _host_live() and Net.live():
		_rx_spod.rpc_id(Net.other_id, id, data)


func _on_spod_landed(id: int, pos: Vector3) -> void:
	if _host_live() and Net.live():
		_rx_spod_land.rpc_id(Net.other_id, id, pos)


func _on_spod_destroyed(id: int, pos: Vector3) -> void:
	if _host_live() and Net.live():
		_rx_spod_down.rpc_id(Net.other_id, id, pos)


func _on_spod_call(req: int, gun: String, to: Vector3) -> void:
	if Net.is_client() and Net.live():
		_rx_spod_call.rpc_id(1, req, gun, to)


@rpc("authority", "call_remote", "reliable")
func _rx_spod(id: int, data: Dictionary) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var d := _sdata(data)
	if not d.is_empty():
		load(SUPPLY_PATH).call("spawn_mirror", id, d)


@rpc("authority", "call_remote", "reliable")
func _rx_spod_land(id: int, pos: Vector3) -> void:
	if Net.is_server or not Net.in_game or not pos.is_finite():
		return
	load(SUPPLY_PATH).call("net_land", id, pos)


@rpc("authority", "call_remote", "reliable")
func _rx_spod_down(id: int, pos: Vector3) -> void:
	if Net.is_server or not Net.in_game or not pos.is_finite():
		return
	load(SUPPLY_PATH).call("net_destroy", id, pos)


@rpc("any_peer", "call_remote", "reliable")
func _rx_spod_call(req: int, gun: String, to: Vector3) -> void:
	if not Net.is_host() or not _sender_ok() or not Net.peer_ready:
		return
	var why := "Geçersiz istek"
	if to.is_finite() and gun.length() <= 24:
		why = str(load(SUPPLY_PATH).call("host_request", req, gun, to))
	if why != "" and Net.live():
		_rx_spod_no.rpc_id(Net.other_id, req, why.left(80))


@rpc("authority", "call_remote", "reliable")
func _rx_spod_no(req: int, why: String) -> void:
	if Net.is_server or not Net.in_game:
		return
	load(SUPPLY_PATH).call("refused", req, why.left(80))


# =================================================================================================
# Control zones (Bölge kontrolü)
# =================================================================================================

func _cp_inst() -> Node:
	if not ResourceLoader.exists(CP_PATH) or not is_inside_tree():
		return null
	return load(CP_PATH).call("inst", get_tree())


func _on_cp_changed(states: Array) -> void:
	if _host_live() and Net.live() and not states.is_empty():
		_rx_cp.rpc_id(Net.other_id, states)


@rpc("authority", "call_remote", "reliable")
func _rx_cp(states: Array) -> void:
	if Net.is_server or not Net.in_game:
		return
	_cp_take(states)


## Client: validated states into the pending map (the newest per zone wins), then applied when the
## zones exist (built a frame after the war: a late join's snapshot can come first).
func _cp_take(states: Array) -> void:
	for st in states.slice(0, 64):
		if not (st is Array) or (st as Array).size() < 5:
			continue
		var preset := str(st[0])
		if preset != "home" and preset != "rival":
			continue
		var pr := float(st[3])
		_cp_pending["%s:%d" % [preset, int(st[1])]] = [preset, clampi(int(st[1]), 0, 63), clampi(int(st[2]), -1, 1),
				clampf(pr, -1.0, 1.0) if is_finite(pr) else 0.0, bool(st[4])]
	_cp_tries = 0
	_cp_flush()


func _cp_flush() -> void:
	if _cp_pending.is_empty() or not is_inside_tree():
		return
	var cp := _cp_inst()
	if cp != null and bool(cp.get("_ready_zones")):
		var out: Array = _cp_pending.values()
		_cp_pending.clear()
		cp.call("net_apply", out)
		return
	_cp_tries += 1
	if _cp_tries <= 60:                 # (≤ 15 s of waiting for the zones)
		get_tree().create_timer(0.25).timeout.connect(_cp_flush, CONNECT_ONE_SHOT)
	else:
		_cp_pending.clear()


# =================================================================================================
# Meteor showers (Göktaşı yağmuru)
# =================================================================================================

func _met_body(i: int) -> Node3D:
	return Net.body_by_index(i) if i == 0 or i == 1 else null


func _on_met_shower(_shower_id: int, body: Node3D, impacts: PackedVector3Array, warn: float) -> void:
	if _host_live() and Net.live() and body != null:
		_rx_met_shower.rpc_id(Net.other_id, Net.body_index(body), impacts, warn)


func _on_met_in(id: int, body: Node3D, from: Vector3, to: Vector3, flight: float) -> void:
	if _host_live() and Net.live() and body != null:
		_rx_met_in.rpc_id(Net.other_id, id, Net.body_index(body), from, to, flight)


func _on_met_land(id: int, body: Node3D, pos: Vector3, amount: float) -> void:
	if _host_live() and Net.live() and body != null:
		_rx_met_land.rpc_id(Net.other_id, id, Net.body_index(body), pos, amount)


func _on_met_gone(id: int, _why: String) -> void:
	if _host_live() and Net.live():
		_rx_met_gone.rpc_id(Net.other_id, id)


@rpc("authority", "call_remote", "reliable")
func _rx_met_shower(bi: int, impacts: PackedVector3Array, warn: float) -> void:
	var b := _met_body(bi)
	if Net.is_server or not Net.in_game or b == null or not is_finite(warn):
		return
	var pts := PackedVector3Array()
	for p in impacts.slice(0, 32):
		if p.is_finite():
			pts.append(p)
	load(METEOR_PATH).call("net_shower", b, pts, clampf(warn, 0.0, 60.0))


@rpc("authority", "call_remote", "reliable")
func _rx_met_in(id: int, bi: int, from: Vector3, to: Vector3, flight: float) -> void:
	var b := _met_body(bi)
	if Net.is_server or not Net.in_game or b == null or not from.is_finite() or not to.is_finite() or not is_finite(flight):
		return
	load(METEOR_PATH).call("net_incoming", id, b, from, to, clampf(flight, 0.1, 30.0))


@rpc("authority", "call_remote", "reliable")
func _rx_met_land(id: int, bi: int, pos: Vector3, amount: float) -> void:
	var b := _met_body(bi)
	if Net.is_server or not Net.in_game or b == null or not pos.is_finite() or not is_finite(amount):
		return
	load(METEOR_PATH).call("net_landed", id, b, pos, clampf(amount, 0.0, 100000.0))


@rpc("authority", "call_remote", "reliable")
func _rx_met_gone(id: int) -> void:
	if Net.is_server or not Net.in_game:
		return
	load(METEOR_PATH).call("net_gone", id)


# =================================================================================================
# Respawn dropships
# =================================================================================================

func _on_ship_dispatched(id: int, team: String, from: Vector3, to: Vector3, land_in: float) -> void:
	if Net.in_game and Net.live():
		_rx_ship.rpc_id(Net.other_id, id, 1 if team == "rival" else 0, from, to, land_in)


func _on_ship_landed(id: int, pos: Vector3) -> void:
	if Net.in_game and Net.live():
		_rx_ship_land.rpc_id(Net.other_id, id, pos)


@rpc("any_peer", "call_remote", "reliable")
func _rx_ship(id: int, side: int, from: Vector3, to: Vector3, land_in: float) -> void:
	if not _sender_ok() or not Net.live() or not from.is_finite() or not to.is_finite():
		return
	load(SHIP_PATH).call("replay_dispatch", id, "rival" if side == 1 else "home", from, to, clampf(land_in, 0.5, 30.0))


@rpc("any_peer", "call_remote", "reliable")
func _rx_ship_land(id: int, pos: Vector3) -> void:
	if not _sender_ok() or not Net.live() or not pos.is_finite():
		return
	load(SHIP_PATH).call("replay_landed", id, pos)


# =================================================================================================
# Respawn waves
# =================================================================================================

## [s0, s1] by absolute side from the host's local home_s / rival_s.
func _waves_abs(home_s: float, rival_s: float) -> Array:
	var a := [-1.0, -1.0]
	a[Net.abs_side("home")] = snappedf(home_s, 0.01)
	a[Net.abs_side("rival")] = snappedf(rival_s, 0.01)
	return a


func _on_waves_changed(home_s: float, rival_s: float) -> void:
	if _host_live() and Net.live():
		_rx_waves.rpc_id(Net.other_id, {"wave_t": _waves_abs(home_s, rival_s)})


func _on_team_wiped(team: String, secs: float) -> void:
	if _host_live() and Net.live():
		_rx_waves.rpc_id(Net.other_id, {"wipe": Net.abs_side(team), "secs": snappedf(secs, 0.01)})


@rpc("authority", "call_remote", "reliable")
func _rx_waves(d: Dictionary) -> void:
	if Net.is_server or not Net.in_game:
		return
	_waves_take(d)


## Client: a waves message (or the snapshot's "waves"), validated, into the client's local teams.
func _waves_take(d) -> void:
	if not (d is Dictionary) or not ResourceLoader.exists(WAVES_PATH):
		return
	var w = d.get("wave_t")
	if w is Array and (w as Array).size() >= 2:
		load(WAVES_PATH).call("net_waves", _wave_s(w[Net.abs_side("home")]), _wave_s(w[Net.abs_side("rival")]))
	var side = d.get("wipe")
	if side is int or side is float:
		load(WAVES_PATH).call("net_wipe", Net.local_team(clampi(int(side), 0, 1)), _wave_s(d.get("secs", -1.0)))


## A countdown as received: finite, -1 (none) .. 120 s.
static func _wave_s(v) -> float:
	if not (v is int or v is float) or not is_finite(float(v)) or float(v) < 0.0:
		return -1.0
	return minf(float(v), 120.0)


# =================================================================================================
# Drop pods
# =================================================================================================

func _pod_node(id: int) -> Node3D:
	var p = _pods.get(id)
	if p != null and is_instance_valid(p) and (p as Node).is_inside_tree() and not (p as Node).is_queued_for_deletion():
		return p
	for n in get_tree().get_nodes_in_group("war_drop_pod"):
		if is_instance_valid(n) and int(n.get("net_id")) == id and not bool(n.get("net_puppet")):
			return n as Node3D
	return null


func _track(id: int, p: Node3D) -> void:
	if p == null or _pods.get(id) == p:
		return
	_pods[id] = p
	p.tree_exiting.connect(_on_pod_exit.bind(id, p), CONNECT_ONE_SHOT)


func _on_pod_exit(id: int, p: Node3D) -> void:
	if _pods.get(id) == p:
		_pods.erase(id)
		_pod_landed.erase(id)


func _on_pod_fired(id: int, from: Vector3, vel: Vector3) -> void:
	if not _host_live():
		return
	var p := _pod_node(id)
	_track(id, p)
	if not Net.live():
		return
	var side := Net.abs_side(str(p.get("team")) if p != null else "rival")
	_rx_pod.rpc_id(Net.other_id, id, from, vel, side, _cannon_at(from))


func _on_pod_landed(id: int, pos: Vector3) -> void:
	if not _host_live():
		return
	_pod_landed[id] = pos
	if Net.live():
		_rx_pod_land.rpc_id(Net.other_id, id, pos)


func _on_pod_destroyed(id: int, pos: Vector3) -> void:
	if not _host_live():
		return
	_pod_landed.erase(id)
	if Net.live():
		_rx_pod_down.rpc_id(Net.other_id, id, pos)


## Host: the net id of the cannon a pod left from (its shot's look on the client), 0 = none.
func _cannon_at(from: Vector3) -> int:
	var best: Node = null
	var bd := 9.0
	for c in get_tree().get_nodes_in_group("war_cannon"):
		if c is Node3D and is_instance_valid(c):
			var d: float = (c as Node3D).global_position.distance_to(from)
			if d < bd:
				bd = d
				best = c
	return Net.world.id_of(best) if best != null else 0


func _puppet(id: int, from: Vector3, vel: Vector3, side: int) -> Node3D:
	var old = _pods.get(id)
	if old != null and is_instance_valid(old) and not (old as Node).is_queued_for_deletion():
		return old
	if not ResourceLoader.exists(POD_PATH) or get_tree().current_scene == null:
		return null
	var p: Node3D = load(POD_PATH).call("puppet", get_tree().current_scene, id, from, vel.limit_length(200.0), Net.local_team(side))
	_track(id, p)
	return p


@rpc("authority", "call_remote", "reliable")
func _rx_pod(id: int, from: Vector3, vel: Vector3, side: int, launcher: int) -> void:
	if Net.is_server or not Net.world_ready:
		return
	_puppet(id, from, vel, side)
	var ln: Node = Net.world.node_of(launcher) if launcher != 0 else null
	if ln != null and ln.has_method("net_fire_fx"):
		ln.net_fire_fx()


@rpc("authority", "call_remote", "reliable")
func _rx_pod_land(id: int, pos: Vector3) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var p = _pods.get(id)
	if p == null or not is_instance_valid(p):
		p = _puppet(id, pos, Vector3.ZERO, Net.abs_side("rival"))
	if p != null:
		p.net_land(pos)


@rpc("authority", "call_remote", "reliable")
func _rx_pod_down(id: int, pos: Vector3) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var p = _pods.get(id)
	if p != null and is_instance_valid(p):
		p.net_destroy(pos)
	elif ResourceLoader.exists(ROUND_PATH) and get_tree().current_scene != null:
		load(ROUND_PATH).call("burst_fx", get_tree().current_scene, pos, 2.2)


# =================================================================================================
# Snapshot (late join): every pickup; pods in flight / standing
# =================================================================================================

func build_snapshot() -> Dictionary:
	var loot: Array = []
	if ResourceLoader.exists(LOOT_PATH):
		loot = _loot().call("snapshot")
		for e in loot:
			_loot_amt[int(e[0])] = float(e[2])
	var pods: Array = []
	for id in _pods.keys():
		var p = _pods[id]
		if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
			continue
		var side := Net.abs_side(str(p.get("team")))
		if _pod_landed.has(id):
			pods.append([int(id), _pod_landed[id], Vector3.ZERO, side, true])
		elif bool(p.call("is_live")):
			pods.append([int(id), (p as Node3D).global_position, p.get("vel"), side, false])
	var wdrops: Array = []
	if ResourceLoader.exists(WDROP_PATH):
		wdrops = _wdrop().call("snapshot")
	var caches: Array = []
	if ResourceLoader.exists(CACHE_PATH):
		caches = load(CACHE_PATH).call("snapshot")
	var spods: Array = []
	if ResourceLoader.exists(SUPPLY_PATH):
		spods = load(SUPPLY_PATH).call("snapshot")
	var cps: Array = []
	var cp := _cp_inst()
	if cp != null:
		cps = cp.call("snapshot")
	var waves := {}
	if ResourceLoader.exists(WAVES_PATH):
		var wv = load(WAVES_PATH)
		waves = {"wave_t": _waves_abs(float(wv.call("wave_left", "home")), float(wv.call("wave_left", "rival")))}
	return {"loot": loot, "pods": pods, "wdrops": wdrops, "caches": caches, "spods": spods, "cps": cps, "waves": waves}


func apply_snapshot(d: Dictionary) -> void:
	if ResourceLoader.exists(LOOT_PATH):
		for e in d.get("loot", []):
			if e is Array and (e as Array).size() >= 4:
				_loot().call("spawn_mirror", int(e[0]), e[1], maxf(float(e[2]), 0.0), maxf(float(e[3]), 0.0))
	if ResourceLoader.exists(WDROP_PATH):
		for e in d.get("wdrops", []):
			if e is Array and (e as Array).size() >= 3:
				var wd := _wdata(e[1])
				if not wd.is_empty():
					_wdrop().call("spawn_mirror", int(e[0]), wd, maxf(float(e[2]), 0.0))
	if ResourceLoader.exists(CACHE_PATH):
		var ids: Array = []
		var cs = d.get("caches", [])
		if cs is Array:
			for v in cs:
				if v is int or v is float:
					ids.append(int(v))
		if not ids.is_empty():
			load(CACHE_PATH).call("apply_snapshot", ids)
	if ResourceLoader.exists(SUPPLY_PATH):
		var sp = d.get("spods", [])
		if sp is Array:
			for e in sp:
				if e is Array and (e as Array).size() >= 2:
					var sd := _sdata(e[1])
					if not sd.is_empty():
						load(SUPPLY_PATH).call("spawn_mirror", int(e[0]), sd)
	var cps = d.get("cps", [])
	if cps is Array and not (cps as Array).is_empty():
		_cp_take(cps)
	_waves_take(d.get("waves", {}))
	for e in d.get("pods", []):
		if not (e is Array) or (e as Array).size() < 5:
			continue
		var p := _puppet(int(e[0]), e[1], e[2], int(e[3]))
		if p != null and bool(e[4]):
			p.net_land(e[1])
