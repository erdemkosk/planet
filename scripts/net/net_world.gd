extends Node
## World sync (child "World" of the Net autoload): structures, shells, flak, cores, skiffs, build
## requests and hit claims. The host owns all of it; the client sees puppets.
##
## Ids: 1 host player, 2 client player, 10 + body = cores, 100 + i = bots (net_bots.gd),
## 3000+ = structures and skiffs (host-assigned when any structure enters the host's tree: the
## player's build tool, a client's build request, the AI engineers). Shells: host counter, or
## 1 << 24 | n for a shell the client fired (the host's authoritative copy keeps that id).
##
## Messages
##   reliable  spawn {id, script, side, body, xf, hp, footprint, animate} · destroy {id}
##             build_req {req, kind, script, xf, cost} -> ok / denied (refund) · man {id, on} / unman
##             shell {id, from, vel, side, launcher} (host) · shell_req (client fired) · shell impact /
##             shot down (host decides) · flak {from, vel, fuse, side, launcher} · flak_req
##             claim {target id, amount, from, impulse, hit point (pack_point: 1 int, -1 none)}
##             (client bullets) · core_claim (client drill) · mine_grant {id, amount} (host -> the
##             client whose Otomatik Kazıcı filled a hopper: auto_miner.gd receive_grant) ·
##             turret_cost {id, amount} (host -> the client whose Otomatik Taret fires a burst: it pays)
##             / turret_paid {id, ok} (client -> host, on change: false starves the turret)
##             cores {hp, destroyed} on change · skiff_hit {id, amount, from, impulse, hp} ·
##             pilot {id, on, final state} / pilot_denied
##   unreliable structure states 5 Hz, changed only + full every 2 s (10 B each: hp, yaw, pitch,
##             charge, manned / tracking flags) · manned aim from the client 10 Hz · skiff state
##             (39 B) from its authority: 20 Hz while flying / powered, 1 Hz parked

const SnapBuffer := preload("res://scripts/net/snap_buffer.gd")
const Passenger := preload("res://scripts/net/net_passenger.gd")

const CANNON_PATH := "res://scripts/war/cannon.gd"
const FLAK_PATH := "res://scripts/war/flak.gd"
const SKIFF_PATH := "res://scripts/craft/skiff.gd"
const ARMORY_PATH := "res://scripts/war/armory.gd"     # Silahlık (extends Node3D, cannon-like contract)
const MINER_PATH := "res://scripts/war/auto_miner.gd"  # Otomatik Kazıcı (charge = depth; pays its owner)
## Base pieces (bunker module, wall, door, sentry turret, core shield, radar tower, light post) all
## extend this; a spawn entry carries the subclass path. Door open = charge 1; turret aim = _yaw_t /
## _pitch_t, firing = tracking (the client fakes the rounds).
const BASE_PIECE_PATH := "res://scripts/war/base_piece.gd"
const BASE_KIT_PATH := "res://scripts/war/base_kit.gd"
const INTENT_PATH := "res://scripts/war/build_intent.gd"   # co-op build notifications (BuildIntent)
const SHELL_PATH := "res://scripts/war/shell.gd"
const ROUND_PATH := "res://scripts/war/flak_round.gd"
const BUILD_FX_PATH := "res://scripts/war/build_fx.gd"
const BALANCE_PATH := "res://scripts/war/balance.gd"

const ID_HOST_PLAYER := 1
const ID_CLIENT_PLAYER := 2
const ID_CORE := 10
const ID_BOT := 100                # = net_bots.gd ID_BASE
const ID_STRUCT := 3000
const CLIENT_SHELL := 1 << 24
const TORPEDO_PATH := "res://scripts/war/torpedo.gd"
const TORP_BASE := 1 << 20           # torpedo ids (their net_id field)
const CLIENT_TORP := 1 << 19         # ...one the client launched (the host's copy keeps the id)
const TORP_PERIOD := 0.25
const STATE_PERIOD := 0.1
const STATE_FULL := 2.0
const AIM_PERIOD := 0.1
const SKIFF_PERIOD := 0.05
const SKIFF_IDLE := 1.0
const CORE_PERIOD := 0.25
const CLAIM_PERIOD := 0.1

const SF_HOST_MANS := 1
const SF_CLIENT_MANS := 2
const SF_TRACKING := 4
const SF_CRAFTING := 8                # Silahlık: its owner's machine is crafting (the fabricator look)

var _nodes := {}                  # id -> structure / skiff
var _next_id := ID_STRUCT
var _shells := {}                 # id -> shell
var _next_shell := 1
var _spawning := false            # creating something the network asked for: hooks stay quiet
var _main: Node
var _state_t := 0.0
var _full_t := 0.0
var _aim_t := 0.0
var _core_t := 0.0
var _claim_t := 0.0
var _last_state := {}             # id -> PackedByteArray
var _skiff_t := {}                # id -> seconds since last state
var _skiff_auth := {}             # host: skiff id -> client peer (client flies it)
var _manned: Node = null          # what our player is in (structure, skiff or passenger seat)
var _client_mans := 0             # host: structure id the client mans
var _build_req := 0
var _pending_builds := {}         # client: req -> cost
var _core_claims := {}            # client: body index -> damage to send
var _core_sent := {}              # host: body index -> [hp, destroyed] last sent
var _scripts := {}
var _torps := {}                  # id -> torpedo.gd (flying / burrowing / dying)
var _next_torp := 1
var _torp_t := 0.0
var _torp_hooked := false
var _gun_out := {}                # skiff id -> PackedByteArray of batched rounds (armed_skiff.gd)
var _craft_sent := {}              # client: armory id -> true while its local craft look was sent
var _turret_ok := {}               # client: our turret id -> could we pay its last burst (sent on change)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _scr(path: String) -> Script:
	if not _scripts.has(path):
		_scripts[path] = load(path)
	return _scripts[path]


func begin(main: Node) -> void:
	reset()
	_main = main
	_hook_torpedoes()
	# The host's quiet removals (undo / sell: BaseKit.deconstruct) go out at once (a bound method of
	# this autoload node: it outlives every scene, no capturing lambda on the static hub).
	_scr(BASE_KIT_PATH).set("deconstruct_hook", Callable(self, "_on_deconstruct"))
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)


func reset() -> void:
	_nodes.clear()
	_shells.clear()
	_last_state.clear()
	_skiff_t.clear()
	_skiff_auth.clear()
	_pending_builds.clear()
	_core_claims.clear()
	_core_sent.clear()
	_next_id = ID_STRUCT
	_next_shell = 1
	_manned = null
	_torps.clear()
	_torp_t = 0.0
	_gun_out.clear()
	_craft_sent.clear()
	_turret_ok.clear()
	_client_mans = 0
	_spawning = false
	_main = null
	if get_tree() != null and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


## Host: the client left. Whatever it flew or manned is ours again.
func on_peer_gone() -> void:
	for id in _skiff_auth.keys():
		var sk = _nodes.get(id)
		if sk != null and is_instance_valid(sk):
			sk.remove_meta("net_busy")
			sk.net_set_puppet(false)
	_skiff_auth.clear()
	if _client_mans != 0:
		var n = _nodes.get(_client_mans)
		if n != null and is_instance_valid(n):
			n.remove_meta("net_busy")
		_client_mans = 0
	_last_state.clear()
	_core_sent.clear()


# =================================================================================================
# Ids
# =================================================================================================

func id_of(n: Object) -> int:
	if n == null or not is_instance_valid(n):
		return 0
	if n is Node and (n as Node).has_meta("net_id"):
		return int((n as Node).get_meta("net_id"))
	return 0


func node_of(id: int) -> Node:
	if (id & TORP_BASE) != 0:
		var t = _torps.get(id)
		return t if t != null and is_instance_valid(t) and (t as Node).is_inside_tree() else null
	var n = _nodes.get(id)
	if n != null and is_instance_valid(n) and (n as Node).is_inside_tree():
		return n
	return null


## Seat in a skiff: 0 pilot (left), 1 passenger (right).
func seat_position(seat: int) -> Vector3:
	if seat == 1:
		return Passenger.seat_offset()
	var build = load("res://scripts/craft/skiff_build.gd")
	return build.SEAT_POS if build != null else Vector3(-0.38, 0.8, -0.3)


func _core_of(bi: int) -> Node:
	for c in get_tree().get_nodes_in_group("war_core"):
		if Net.body_index(c.get("body")) == bi:
			return c
	return null


func _is_structure(n: Node) -> bool:
	var s = n.get_script()
	while s != null:
		var p: String = (s as Script).resource_path
		if p == CANNON_PATH or p == FLAK_PATH or p == SKIFF_PATH or p == ARMORY_PATH \
				or p == "res://scripts/war/torpedo_rig.gd" or p == MINER_PATH or p == BASE_PIECE_PATH:
			return true
		s = (s as Script).get_base_script()
	return false


func _is_skiff(n: Node) -> bool:
	return n != null and n.has_method("net_set_puppet")


# =================================================================================================
# Structures: spawn / destroy (host -> client)
# =================================================================================================

func _on_node_added(n: Node) -> void:
	if not Net.is_host() or not Net.in_game or not (n is Node3D):
		return
	if _is_structure(n):
		_register.call_deferred(n)


func _register(n: Node) -> void:
	if not is_instance_valid(n) or not n.is_inside_tree() or n.has_meta("net_id") or not Net.is_server:
		return
	var id := _next_id
	_next_id += 1
	_bind(n, id)
	if Net.live():
		_rx_spawn.rpc_id(Net.other_id, _entry(n, true))


func _bind(n: Node, id: int) -> void:
	n.set_meta("net_id", id)
	_nodes[id] = n
	if n.has_signal("weapon_fired") and not n.is_connected("weapon_fired", _on_skiff_weapon.bind(id)):
		n.connect("weapon_fired", _on_skiff_weapon.bind(id))      # armed_skiff.gd
	if Net.is_server and n.has_signal("produced") and not n.is_connected("produced", _on_miner_produced.bind(id)):
		n.connect("produced", _on_miner_produced.bind(id))       # auto_miner.gd
	if Net.is_server and n.has_signal("burst_cost") and not n.is_connected("burst_cost", _on_turret_cost.bind(id)):
		n.connect("burst_cost", _on_turret_cost.bind(id))        # sentry_turret.gd
	n.tree_exiting.connect(_on_exit.bind(id), CONNECT_ONE_SHOT)


## Host: a client-built Otomatik Taret fires a burst: its owner pays it on its own machine
## (turret_cost); the answer comes back only when it changes (turret_paid: false = broke, the turret
## starves like an empty pool until the client can pay again). With that client gone it fires free.
func _on_turret_cost(peer: int, amount: float, id: int) -> void:
	if peer <= 0:
		return
	if Game.shared_pool:
		# Co-op team pool: paid here at once (no round trip).
		var n := node_of(id)
		if n != null and "peer_broke" in n:
			n.set("peer_broke", not Game.spend_material(amount))
		return
	if peer == Net.other_id and Net.live():
		_rx_turret_cost.rpc_id(peer, id, amount)


@rpc("authority", "call_remote", "reliable")
func _rx_turret_cost(id: int, amount: float) -> void:
	if Net.is_server or not Net.in_game:
		return
	var ok := Game.spend_material(clampf(amount, 0.0, 100.0))
	if bool(_turret_ok.get(id, true)) != ok:
		_turret_ok[id] = ok
		_rx_turret_paid.rpc_id(1, id, ok)
		if not ok and Game.hud:
			Game.hud.show_message("Taret mermisi için malzeme yetmiyor", 2.0)


@rpc("any_peer", "call_remote", "reliable")
func _rx_turret_paid(id: int, ok: bool) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id:
		return
	var n := node_of(id)
	if n != null and int(n.get("owner_peer")) == Net.other_id and "peer_broke" in n:
		n.set("peer_broke", not ok)


## Host: an auto-miner's hopper load (auto_miner.gd produced). Team income (2026-10-06): every player
## of the miner's side gets the full load: the host's player was paid by the miner itself when on that
## side; the client is paid on its machine (receive_grant) whenever he is on it, whoever built it.
func _on_miner_produced(peer: int, amount: float, id: int) -> void:
	var n := node_of(id)
	var mteam := str(n.get("team")) if n != null else ""
	if Game.shared_pool:
		# Co-op team pool (Balance.COOP_SHARED_POOL): one payment into it: the miner's own when the
		# host is on its side, else here for a client's build.
		if peer > 0 and mteam != Net.local_team(Net.my_side()):
			Game.add_material(amount)
		return
	if Net.live() and mteam != "" and mteam == Net.local_team(Net.other_side()):
		_rx_mine_grant.rpc_id(Net.other_id, id, amount)


@rpc("authority", "call_remote", "reliable")
func _rx_mine_grant(_id: int, amount: float) -> void:
	if Net.is_server or not Net.in_game:
		return
	_scr(MINER_PATH).call("receive_grant", amount)


func _on_exit(id: int) -> void:
	var n = _nodes.get(id)
	var quiet: bool = n != null and is_instance_valid(n) and (n as Node).has_meta("deconstructed")
	_nodes.erase(id)
	_last_state.erase(id)
	_skiff_t.erase(id)
	_skiff_auth.erase(id)
	if Net.is_server and Net.live() and not quiet:   # (a deconstruct went out as _rx_deconstruct already)
		_rx_destroy.rpc_id(Net.other_id, id)


func _entry(n: Node, animate: bool) -> Dictionary:
	var body = n.get("body")
	if body == null:
		body = n.get("_body")
	if body == null:
		body = Game.dominant_body((n as Node3D).global_position)
	var e := {"id": id_of(n), "path": (n.get_script() as Script).resource_path,
			"side": Net.abs_side(Game.team_of(n)), "body": Net.body_index(body),
			"xf": (n as Node3D).global_transform, "anim": animate, "hp": float(n.get("hp")),
			"fr": float(n.get_meta("footprint_r", 3.0))}
	if _is_skiff(n):
		e["skiff"] = true
		e["landed"] = bool(n.get("landed"))
	# Who built it and for how much (build_tool.gd / _rx_build_req metas): the partner's notification,
	# the undo / sell refund.
	if n.has_meta("builder"):
		e["by"] = str(n.get_meta("builder"))
	if n.has_meta("build_cost"):
		e["cost"] = float(n.get_meta("build_cost"))
	return e


@rpc("authority", "call_remote", "reliable")
func _rx_spawn(e: Dictionary) -> void:
	if Net.is_server or not Net.in_game:
		return
	_spawn_entry(e)


func _spawn_entry(e: Dictionary) -> void:
	var id := int(e.get("id", 0))
	if id == 0 or node_of(id) != null:
		return
	var path := str(e.get("path", ""))
	if not path.begins_with("res://scripts/") or not ResourceLoader.exists(path):
		return
	var scr := _scr(path)
	if scr == null or _main == null or not is_instance_valid(_main):
		return
	var team := Net.local_team(int(e.get("side", 0)))
	var body := Net.body_by_index(int(e.get("body", 0)))
	var xf: Transform3D = e.get("xf", Transform3D())
	var animate := bool(e.get("anim", false))
	var scene: Node = get_tree().current_scene if get_tree().current_scene != null else _main
	_spawning = true
	var n: Node3D = scr.new()
	if bool(e.get("skiff", false)):
		n.set("team", team)
		n.set_meta("team", team)
		n.transform = xf
		scene.add_child(n)
		n.add_to_group("war_structure")
		n.set_meta("footprint_r", float(e.get("fr", 3.0)))
		if n.has_method("place"):
			n.place(body, xf)
		n.global_transform = xf
		if animate:
			var half := Vector3(1.25, 1.02, 2.5)
			if (scr as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "footprint"):
				half = scr.call("footprint")
			_scr(BUILD_FX_PATH).assemble(scene, xf, half)
		n.net_set_puppet(true)
	else:
		n.set("team", team)
		n.set("body", body)
		n.name = "%s_%s_net" % [path.get_file().get_basename(), team]
		n.transform = xf
		scene.add_child(n)
		if animate and n.has_method("begin_assembly"):
			n.begin_assembly()
	n.set("hp", float(e.get("hp", n.get("hp"))))
	# Who built it, the price (the undo / sell checks of the client's build tool); a fresh build by the
	# partner: "Arkadaşın (Ali) Uçaksavar kurdu" (co-op).
	var by := str(e.get("by", ""))
	if by != "":
		n.set_meta("builder", by)
	if e.has("cost"):
		n.set_meta("build_cost", float(e["cost"]))
	if animate:
		n.set_meta("built_ms", Time.get_ticks_msec())
	if by != "" and by != Net.my_name and animate and not Net.pvp():
		var bk := _scr(BASE_KIT_PATH)
		_scr(INTENT_PATH).call("notify_built", by, str(bk.call("display_name", str(bk.call("kind_of", n)))))
	_bind(n, id)
	_spawning = false


@rpc("authority", "call_remote", "reliable")
func _rx_destroy(id: int) -> void:
	if Net.is_server:
		return
	var n := node_of(id)
	if n == null:
		return
	_nodes.erase(id)
	if n.has_method("_destroy"):
		n.call("_destroy")
	else:
		n.queue_free()


# =================================================================================================
# Build requests (client -> host)
# =================================================================================================

## Client build tool: the material is already spent here; the host validates and builds (or the
## cost comes back).
func request_build(kind: String, script_path: String, xf: Transform3D, cost: float) -> void:
	_build_req += 1
	_pending_builds[_build_req] = cost
	_rx_build_req.rpc_id(1, _build_req, kind, script_path, xf, cost)


@rpc("any_peer", "call_remote", "reliable")
func _rx_build_req(req: int, kind: String, script_path: String, xf: Transform3D, cost: float) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or not Net.peer_ready:
		return
	var why := _validate_build(kind, script_path, xf)
	if why != "":
		_rx_build_denied.rpc_id(Net.other_id, req, why)
		return
	var body: Node3D = Game.dominant_body(xf.origin)
	var team := Net.local_team(Net.other_side())
	var scene: Node = get_tree().current_scene
	var path := script_path
	if path == "":
		path = CANNON_PATH if kind == "cannon" else (FLAK_PATH if kind == "flak" else SKIFF_PATH)
	var scr := _scr(path)
	var n: Node3D = scr.new()
	if kind == "skiff" or n.has_method("net_set_puppet"):
		var half := Vector3(1.25, 1.02, 2.5)
		if (scr as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "footprint"):
			half = scr.call("footprint")
		n.set("team", team)
		n.set_meta("team", team)
		n.transform = xf
		scene.add_child(n)
		n.add_to_group("war_structure")
		n.set_meta("footprint_r", maxf(half.x, half.z))
		if n.has_method("place"):
			n.place(body, xf)
		_scr(BUILD_FX_PATH).assemble(scene, xf, half)
	else:
		n.set("team", team)
		n.set("body", body)
		n.name = "%s_%s" % [path.get_file().get_basename(), team]
		n.transform = xf
		if "owner_peer" in n:
			n.set("owner_peer", Net.other_id)  # (auto_miner.gd: its loads go to the client, _on_miner_produced)
		scene.add_child(n)
		if n.has_method("begin_assembly"):
			n.begin_assembly()
	# Who built it and for how much (set before the deferred _register: the spawn entry carries them):
	# the undo / sell refund (BaseKit.refund_of: the known price, else the client's, capped) and the
	# notification ("Arkadaşın (Ali) Uçaksavar kurdu", co-op only).
	var bk := _scr(BASE_KIT_PATH)
	var price := float(bk.call("refund_of", n, 1.0))
	n.set_meta("build_cost", price if price > 0.0 else clampf(cost, 0.0, 1000.0))
	n.set_meta("built_ms", Time.get_ticks_msec())
	n.set_meta("builder", Net.other_name)
	if not Net.pvp():
		_scr(INTENT_PATH).call("notify_built", Net.other_name, str(bk.call("display_name", str(bk.call("kind_of", n)))))
	_rx_build_ok.rpc_id(Net.other_id, req)


func _validate_build(kind: String, script_path: String, xf: Transform3D) -> String:
	if script_path != "" and (not script_path.begins_with("res://scripts/") or not ResourceLoader.exists(script_path)):
		return "Bilinmeyen yapı"
	if script_path == "" and not kind in ["cannon", "flak", "skiff", "armed_skiff"]:
		return "Bilinmeyen yapı"
	var body: Node3D = Game.dominant_body(xf.origin)
	if body == null:
		return "Gezegen üzerinde değil"
	# Per-entry site rule (balance.gd BUILD_SITE): home-only, enemy-only (the drill rig) or any.
	var site_why := str(_scr(BALANCE_PATH).call("build_site_reason", kind, script_path,
			Net.body_index(body) == Net.other_side()))
	if site_why != "":
		return site_why
	# Base pieces: their own exact rules (a wall plugging a doorway, a door in a doorway, the core
	# shield's range, boxes against boxes) instead of the radius loop below. Nothing here assumes the
	# surface: an underground spot (xf in a cavity) is checked like any other; the cavity fit itself
	# was the client's build tool's (its room digs come as terrain ops).
	if script_path != "" and bool(_scr(BASE_KIT_PATH).call("is_piece_path", script_path)):
		return str(_scr(BASE_KIT_PATH).call("net_build_reason", script_path, xf, Net.local_team(Net.other_side()), get_tree()))
	var r := 3.0
	if kind == "cannon":
		r = float(_scr(BALANCE_PATH).CANNON_FOOTPRINT)
	elif kind == "flak":
		r = float(_scr(BALANCE_PATH).FLAK_FOOTPRINT)
	elif script_path == ARMORY_PATH:
		r = float(_scr(BALANCE_PATH).get_script_constant_map().get("ARMORY_FOOTPRINT", 3.2))
	elif script_path != "":
		# Skiffs (and anything with a footprint()): its half extents decide the radius.
		var ps := _scr(script_path)
		if ps != null and (ps as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "footprint"):
			var half: Vector3 = ps.call("footprint")
			r = maxf(half.x, half.z)
		else:
			var fp = (ps as Script).get_script_constant_map().get("BUSTER_FOOTPRINT") if ps != null else null
			r = float(_scr(BALANCE_PATH).get_script_constant_map().get("BUSTER_FOOTPRINT", 3.0)) if fp == null else float(fp)
	for s in get_tree().get_nodes_in_group("war_structure"):
		if s is Node3D and (s as Node3D).global_position.distance_to(xf.origin) < r + float(s.get_meta("footprint_r", 3.0)) - 0.3:
			return "Başka bir yapıya çok yakın"
	return ""


@rpc("authority", "call_remote", "reliable")
func _rx_build_ok(req: int) -> void:
	_pending_builds.erase(req)


@rpc("authority", "call_remote", "reliable")
func _rx_build_denied(req: int, why: String) -> void:
	var cost := float(_pending_builds.get(req, 0.0))
	_pending_builds.erase(req)
	if cost > 0.0:
		Game.add_material(cost)
	if Game.hud:
		Game.hud.show_message("Kurulamadı: %s (+%d m³)" % [why, int(cost)], 2.5)
	if Game.sfx:
		Game.sfx.play("error", -10.0)


# =================================================================================================
# Per frame: states, manning, skiffs, cores
# =================================================================================================

func _process(delta: float) -> void:
	if not Net.active or not Net.in_game:
		return
	_watch_manning()
	if not Net.live():
		return
	if Net.is_server:
		_state_t += delta
		_full_t += delta
		if _state_t >= STATE_PERIOD:
			_state_t = 0.0
			var full := _full_t >= STATE_FULL
			if full:
				_full_t = 0.0
			_send_states(full)
		_core_t += delta
		if _core_t >= CORE_PERIOD:
			_core_t = 0.0
			_send_cores()
	else:
		_aim_t += delta
		if _aim_t >= AIM_PERIOD:
			_aim_t = 0.0
			_send_aim()
			_send_craft_looks()
		_claim_t += delta
		if _claim_t >= CLAIM_PERIOD:
			_claim_t = 0.0
			for bi in _core_claims:
				if float(_core_claims[bi]) > 0.0:
					_rx_core_claim.rpc_id(1, int(bi), float(_core_claims[bi]))
			_core_claims.clear()
	_send_skiffs(delta)
	_flush_gun()
	if Net.is_server:
		_torp_t += delta
		if _torp_t >= TORP_PERIOD:
			_torp_t = 0.0
			_send_torps()
	if Engine.get_process_frames() % 120 == 0:
		for id in _shells.keys():
			if not is_instance_valid(_shells[id]):
				_shells.erase(id)


func _send_states(full: bool) -> void:
	var buf := PackedByteArray()
	var n := 0
	var pl = Game.player
	var host_in = pl.vehicle if pl != null and is_instance_valid(pl) else null
	for id in _nodes:
		var s = _nodes[id]
		if not is_instance_valid(s) or _is_skiff(s):
			continue
		var e := PackedByteArray()
		e.resize(10)
		e.encode_u16(0, int(id) - ID_STRUCT)
		e.encode_u16(2, clampi(int(ceilf(float(s.get("hp")))), 0, 65535))
		e.encode_s16(4, clampi(int(wrapf(float(s.get("_yaw_t")), -PI, PI) * 10000.0), -32767, 32767))
		e.encode_s16(6, clampi(int(float(s.get("_pitch_t")) * 10000.0), -32767, 32767))
		var ch = s.get("charge")
		if ch == null and _crafting_here(s):
			ch = s.get("craft_k")
		e.encode_u8(8, clampi(int(float(ch) * 255.0), 0, 255) if ch != null else 0)
		var f := 0
		if host_in == s:
			f |= SF_HOST_MANS
		if _client_mans == int(id):
			f |= SF_CLIENT_MANS
		if bool(s.get("tracking")):
			f |= SF_TRACKING
		if _crafting_here(s):
			f |= SF_CRAFTING
		e.encode_u8(9, f)
		if not full and _last_state.get(id) == e:
			continue
		_last_state[id] = e
		buf.append_array(e)
		n += 1
	if n > 0:
		_rx_states.rpc_id(Net.other_id, buf)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rx_states(buf: PackedByteArray) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var pl = Game.player
	var mine = pl.vehicle if pl != null and is_instance_valid(pl) else null
	for i in buf.size() / 10:
		var o := i * 10
		var s := node_of(buf.decode_u16(o) + ID_STRUCT)
		if s == null:
			continue
		var hp := float(buf.decode_u16(o + 2))
		var old := float(s.get("hp"))
		if hp < old - 0.5 and s.get("_hit_t") != null:
			s.set("_hit_t", 1.0)
		s.set("hp", hp)
		var f := buf.decode_u8(o + 9)
		if s.get("tracking") != null:
			s.set("tracking", (f & SF_TRACKING) != 0)
		if s.get("craft_k") != null:
			_craft_look(s, (f & SF_CRAFTING) != 0, float(buf.decode_u8(o + 8)) / 255.0)
		if (f & SF_HOST_MANS) != 0:
			s.set_meta("net_busy", true)
		elif s.has_meta("net_busy"):
			s.remove_meta("net_busy")
		if mine == s:
			continue                       # we aim it ourselves
		s.set("_yaw_t", float(buf.decode_s16(o + 4)) / 10000.0)
		s.set("_pitch_t", float(buf.decode_s16(o + 6)) / 10000.0)
		if s.get("charge") != null:
			s.set("charge", float(buf.decode_u8(o + 8)) / 255.0)


## Client: the aim of the gun we man.
func _send_aim() -> void:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl):
		return
	var v = pl.vehicle
	if v == null or not is_instance_valid(v) or _is_skiff(v) or v.has_meta("net_seat_of"):
		return
	var id := id_of(v)
	if id == 0:
		return
	var ch = v.get("charge")
	_rx_aim.rpc_id(1, id, float(v.get("_yaw_t")), float(v.get("_pitch_t")), float(ch) if ch != null else 0.0)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rx_aim(id: int, yaw_t: float, pitch_t: float, charge: float) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or id != _client_mans:
		return
	var s := node_of(id)
	if s == null:
		return
	s.set("_yaw_t", wrapf(yaw_t, -PI, PI))
	s.set("_pitch_t", pitch_t)
	if s.get("charge") != null:
		s.set("charge", clampf(charge, 0.0, 1.0))


## Our player got into / out of something.
func _watch_manning() -> void:
	var pl = Game.player
	var v = pl.vehicle if pl != null and is_instance_valid(pl) else null
	if v != null and not is_instance_valid(v):
		v = null
	if v == _manned:
		return
	var old = _manned
	_manned = v
	if old != null and is_instance_valid(old):
		if _is_skiff(old):
			_left_skiff(old)
		elif not old.has_meta("net_seat_of") and Net.is_client() and Net.live() and id_of(old) != 0:
			_rx_man.rpc_id(1, id_of(old), false)
	if v != null:
		if _is_skiff(v):
			_took_skiff(v)
		elif not v.has_meta("net_seat_of") and Net.is_client() and Net.live() and id_of(v) != 0:
			_rx_man.rpc_id(1, id_of(v), true)


@rpc("any_peer", "call_remote", "reliable")
func _rx_man(id: int, on: bool) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id:
		return
	var s := node_of(id)
	if s == null:
		return
	if on:
		var pl = Game.player
		if pl != null and is_instance_valid(pl) and pl.vehicle == s:
			_rx_unman.rpc_id(Net.other_id, id)
			return
		if _client_mans != 0 and _client_mans != id:
			var o := node_of(_client_mans)
			if o != null:
				o.remove_meta("net_busy")
		_client_mans = id
		s.set_meta("net_busy", true)
	elif _client_mans == id:
		_client_mans = 0
		s.remove_meta("net_busy")


@rpc("authority", "call_remote", "reliable")
func _rx_unman(id: int) -> void:
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.vehicle != null and id_of(pl.vehicle) == id:
		pl.exit_vehicle()
		if Game.hud:
			Game.hud.show_message("Dolu — arkadaşın kullanıyor", 2.0)


# --- Skiffs ------------------------------------------------------------------------------------------

func _took_skiff(sk: Node) -> void:
	var id := id_of(sk)
	if Net.is_server or id == 0:
		return
	sk.net_set_puppet(false)
	if Net.live():
		_rx_pilot.rpc_id(1, id, true, {})


func _left_skiff(sk: Node) -> void:
	var id := id_of(sk)
	if Net.is_server or id == 0:
		return
	if Net.live():
		var st: Dictionary = sk.net_state()
		_rx_pilot.rpc_id(1, id, false, {"xf": st["xf"], "vel": st["vel"], "landed": st["landed"]})
	sk.net_set_puppet(true)


@rpc("any_peer", "call_remote", "reliable")
func _rx_pilot(id: int, on: bool, st: Dictionary) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id:
		return
	var sk := node_of(id)
	if sk == null or not _is_skiff(sk):
		return
	if on:
		var pl = Game.player
		if pl != null and is_instance_valid(pl) and pl.vehicle == sk:
			_rx_pilot_denied.rpc_id(Net.other_id, id)
			return
		_skiff_auth[id] = Net.other_id
		sk.set_meta("net_busy", true)
		sk.net_set_puppet(true)
	else:
		_skiff_auth.erase(id)
		sk.remove_meta("net_busy")
		if st.has("xf"):
			sk.global_transform = st["xf"]
			sk.set("landed", bool(st.get("landed", true)))
			sk.set("_net_vel", st.get("vel", Vector3.ZERO))
		sk.net_set_puppet(false)


@rpc("authority", "call_remote", "reliable")
func _rx_pilot_denied(id: int) -> void:
	var sk := node_of(id)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.vehicle == sk and sk != null:
		pl.exit_vehicle()
		if Game.hud:
			Game.hud.show_message("Mekik dolu — arkadaşın pilot koltuğunda", 2.0)
	if sk != null:
		sk.net_set_puppet(true)


func _send_skiffs(delta: float) -> void:
	for id in _nodes:
		var sk = _nodes[id]
		if not is_instance_valid(sk) or not _is_skiff(sk) or bool(sk.get("destroyed")):
			continue
		var mine: bool
		if Net.is_server:
			mine = not _skiff_auth.has(id)
		else:
			mine = not bool(sk.get("net_puppet"))
		if not mine:
			continue
		var st: Dictionary = sk.net_state()
		var busy: bool = bool(st["powered"]) or not bool(st["landed"])
		var t := float(_skiff_t.get(id, 99.0)) + delta
		if t < (SKIFF_PERIOD if busy else SKIFF_IDLE):
			_skiff_t[id] = t
			continue
		_skiff_t[id] = 0.0
		_rx_skiff.rpc_id(Net.other_id, int(id), _encode_skiff(st))


static func _encode_skiff(st: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(39)
	var xf: Transform3D = st["xf"]
	var q := xf.basis.orthonormalized().get_rotation_quaternion()
	var v: Vector3 = st["vel"]
	var thr: Vector3 = st["thr"]
	var f := 0
	if bool(st["landed"]):
		f |= 1
	if bool(st["powered"]):
		f |= 2
	if bool(st["lights"]):
		f |= 4
	b.encode_u32(0, Time.get_ticks_msec())
	b.encode_u8(4, f)
	b.encode_float(5, xf.origin.x)
	b.encode_float(9, xf.origin.y)
	b.encode_float(13, xf.origin.z)
	b.encode_half(17, q.x)
	b.encode_half(19, q.y)
	b.encode_half(21, q.z)
	b.encode_half(23, q.w)
	b.encode_half(25, v.x)
	b.encode_half(27, v.y)
	b.encode_half(29, v.z)
	b.encode_half(31, thr.x)
	b.encode_half(33, thr.y)
	b.encode_half(35, thr.z)
	b.encode_u8(37, clampi(int(float(st["boost"]) * 255.0), 0, 255))
	b.encode_u8(38, clampi(int(float(st["spool"]) * 255.0), 0, 255))
	return b


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rx_skiff(id: int, b: PackedByteArray) -> void:
	if not Net.active or not Net.in_game or b.size() < 39 or multiplayer.get_remote_sender_id() != Net.other_id:
		return
	if Net.is_server and not _skiff_auth.has(id):
		return                             # only the skiff the client flies
	if not Net.is_server and not Net.world_ready:
		return
	var sk := node_of(id)
	if sk == null or not _is_skiff(sk):
		return
	var q := Quaternion(b.decode_half(17), b.decode_half(19), b.decode_half(21), b.decode_half(23))
	if q.length_squared() < 0.01:
		q = Quaternion.IDENTITY
	var f := b.decode_u8(4)
	var st := {"xf": Transform3D(Basis(q.normalized()), Vector3(b.decode_float(5), b.decode_float(9), b.decode_float(13))),
			"vel": Vector3(b.decode_half(25), b.decode_half(27), b.decode_half(29)), "landed": (f & 1) != 0,
			"powered": (f & 2) != 0, "lights": (f & 4) != 0,
			"thr": Vector3(b.decode_half(31), b.decode_half(33), b.decode_half(35)),
			"boost": b.decode_u8(37) / 255.0, "spool": b.decode_u8(38) / 255.0}
	if not Net.is_server:
		if bool(st["powered"]):
			sk.set_meta("net_busy", true)
		elif sk.has_meta("net_busy"):
			sk.remove_meta("net_busy")
	sk.net_push(int(b.decode_u32(0)), st)


## skiff.gd interact(): passenger boarding in co-op; true = handled (do not take the pilot seat).
func skiff_interact(sk: Node, p) -> bool:
	if Net.pvp() and Game.team_of(sk) != "home":
		if Game.hud:
			Game.hud.show_message("Rakibin mekiğine binemezsin", 1.8)
		return true
	if not sk.has_meta("net_busy"):
		return false
	if Net.pvp() or _passenger_taken(sk):
		if Game.hud:
			Game.hud.show_message("Mekik dolu", 1.6)
		return true
	var seat: Node3D = Passenger.new()
	seat.skiff = sk
	sk.add_child(seat)
	p.enter_vehicle(seat)
	return true


## skiff.gd prompt: "" = the normal one, "-" = none.
func skiff_prompt(sk: Node) -> String:
	if Net.pvp() and Game.team_of(sk) != "home":
		return "-"
	if not sk.has_meta("net_busy"):
		return ""
	if Net.pvp() or _passenger_taken(sk):
		return "Mekik dolu"
	return "Yolcu koltuğuna otur"


func _passenger_taken(sk: Node) -> bool:
	var av = Net.players.avatar
	return av != null and is_instance_valid(av) and av.in_vehicle and av.vehicle_id == id_of(sk) and av.seat == 1


## skiff.gd take_damage on a client (crash, landing): the host's hull.
func claim_skiff_damage(sk: Node, amount: float, from_pos: Vector3, impulse: Vector3) -> void:
	var id := id_of(sk)
	if id != 0 and Net.live():
		_rx_claim.rpc_id(1, id, amount, from_pos, impulse, -1)


## Host: a skiff took a hit (any source): the other side plays it and takes the hp.
func on_skiff_hit(sk: Node, amount: float, from_pos: Vector3, impulse: Vector3, new_hp: float) -> void:
	var id := id_of(sk)
	if id != 0 and Net.live():
		_rx_skiff_hit.rpc_id(Net.other_id, id, amount, from_pos, impulse, new_hp)


@rpc("authority", "call_remote", "reliable")
func _rx_skiff_hit(id: int, amount: float, from_pos: Vector3, impulse: Vector3, new_hp: float) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var sk := node_of(id)
	if sk != null and _is_skiff(sk):
		sk.net_hit(amount, from_pos, impulse, new_hp)


# --- Cores -------------------------------------------------------------------------------------------

func claim_core_damage(core: Node, amount: float) -> void:
	var bi := Net.body_index(core.get("body"))
	_core_claims[bi] = float(_core_claims.get(bi, 0.0)) + amount


@rpc("any_peer", "call_remote", "reliable")
func _rx_core_claim(bi: int, amount: float) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or not Net.peer_ready:
		return
	var c := _core_of(bi)
	# Only an ENEMY core takes the client's drill (core.gd drill_all checks the team on its side).
	if c != null and Net.abs_side(str(c.get("team"))) != Net.other_side():
		c.call("_damage", clampf(amount, 0.0, 60.0))


func _send_cores() -> void:
	var arr: Array = []
	var changed := false
	for bi in 2:
		var c := _core_of(bi)
		if c == null:
			arr.append_array([-1.0, false])
			continue
		var cur := [snappedf(float(c.get("hp")), 0.1), bool(c.get("destroyed"))]
		if _core_sent.get(bi) != cur:
			changed = true
			_core_sent[bi] = cur
		arr.append_array(cur)
	if changed:
		_rx_cores.rpc_id(Net.other_id, arr)


@rpc("authority", "call_remote", "reliable")
func _rx_cores(arr: Array) -> void:
	if Net.is_server or not Net.in_game or arr.size() < 4:
		return
	for bi in 2:
		var hp := float(arr[bi * 2])
		if hp < 0.0:
			continue
		var c := _core_of(bi)
		if c != null:
			c.net_set_hp(hp, bool(arr[bi * 2 + 1]))


# =================================================================================================
# Shells and flak rounds
# =================================================================================================

## The cannon / Uçaksavar a projectile left from (nearest registered gun within 9 m).
func _launcher_id(from: Vector3) -> int:
	var best := 0
	var bd := 9.0
	for id in _nodes:
		var n = _nodes[id]
		if not is_instance_valid(n) or _is_skiff(n):
			continue
		var d: float = (n as Node3D).global_position.distance_to(from)
		if d < bd:
			bd = d
			best = int(id)
	return best


func _exclude_of(launcher: Node) -> Array:
	if launcher == null:
		return []
	var b = launcher.get("_body")
	if b is CollisionObject3D:
		return [(b as CollisionObject3D).get_rid()]
	return []


## The script a shell came from ("" = plain shell.gd); only res://scripts/war/ scripts are accepted.
static func _shell_path(s: Node) -> String:
	var scr = s.get_script()
	var p: String = (scr as Script).resource_path if scr is Script else ""
	return "" if p == SHELL_PATH else p


func _shell_script(path: String) -> Script:
	if path == "":
		return _scr(SHELL_PATH)
	if not path.begins_with("res://scripts/war/") or not path.ends_with(".gd") or not ResourceLoader.exists(path):
		return null
	var s := _scr(path)
	if s == null or not (s as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "fire"):
		return null
	return s


## shell.gd / buster_shell.gd fire(): number the shell; host -> tell the client, client -> ask the
## host. The shell's script path rides along (a Delici Top penetrator stays a penetrator).
func on_shell_fired(s: Node, from: Vector3, v: Vector3) -> void:
	if _spawning or not Net.in_game:
		return
	var launcher := _launcher_id(from)
	var path := _shell_path(s)
	if Net.is_server:
		var id := _next_shell
		_next_shell += 1
		s.net_id = id
		_shells[id] = s
		if Net.live():
			_rx_shell.rpc_id(Net.other_id, id, from, v, Net.abs_side(str(s.team)), launcher, path)
	else:
		var id := CLIENT_SHELL | (_next_shell & 0xFFFFFF)
		_next_shell += 1
		s.net_id = id
		s.net_puppet = true
		_shells[id] = s
		if Net.live():
			_rx_shell_req.rpc_id(1, id, from, v, launcher, path)


@rpc("authority", "call_remote", "reliable")
func _rx_shell(id: int, from: Vector3, v: Vector3, side: int, launcher: int, path: String) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var scr := _shell_script(path)
	if scr == null:
		return
	var ln := node_of(launcher)
	_spawning = true
	var s: Node = scr.fire(get_tree().current_scene, from, v, Net.local_team(side), _exclude_of(ln))
	_spawning = false
	s.net_id = id
	s.net_puppet = true
	_shells[id] = s
	if ln != null and ln.has_method("net_fire_fx"):
		ln.net_fire_fx()


@rpc("any_peer", "call_remote", "reliable")
func _rx_shell_req(id: int, from: Vector3, v: Vector3, launcher: int, path: String) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or not Net.peer_ready:
		return
	var bal := _scr(BALANCE_PATH)
	if v.length() > float(bal.CANNON_SPEED_MAX) * 1.3 or (id & CLIENT_SHELL) == 0:
		return
	var scr := _shell_script(path)
	if scr == null:
		return
	var ln := node_of(launcher)
	_spawning = true
	var s: Node = scr.fire(get_tree().current_scene, from, v, Net.local_team(Net.other_side()), _exclude_of(ln))
	_spawning = false
	s.net_id = id
	_shells[id] = s
	if ln != null and ln.has_method("net_fire_fx"):
		ln.net_fire_fx()


## Host shell.gd: it landed (crater, damage and core hits already done here).
func on_shell_impact(s: Node, point: Vector3, normal: Vector3) -> void:
	if Net.live() and int(s.net_id) != 0:
		_rx_shell_impact.rpc_id(Net.other_id, int(s.net_id), point, normal)


@rpc("authority", "call_remote", "reliable")
func _rx_shell_impact(id: int, point: Vector3, normal: Vector3) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var s = _shells.get(id)
	_shells.erase(id)
	if s != null and is_instance_valid(s):
		s.net_impact(point, normal)
		return
	var bal := _scr(BALANCE_PATH)
	load("res://scripts/items/explosion.gd").spawn(point + normal * 0.2, normal, {"radius": bal.SHELL_BLAST_R,
			"damage": bal.SHELL_DAMAGE, "impulse": bal.SHELL_IMPULSE, "crater": 0.0, "player_owned": false})


func on_shell_down(s: Node) -> void:
	if Net.live() and int(s.net_id) != 0:
		_rx_shell_down.rpc_id(Net.other_id, int(s.net_id), (s as Node3D).global_position)


@rpc("authority", "call_remote", "reliable")
func _rx_shell_down(id: int, pos: Vector3) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var s = _shells.get(id)
	_shells.erase(id)
	if s != null and is_instance_valid(s):
		(s as Node3D).global_position = pos
		s.shot_down(pos)
	else:
		_scr(ROUND_PATH).burst_fx(get_tree().current_scene, pos, 1.8)


## flak_round.gd fire(): host -> the client shows it; client (its own gun) -> the host fires it.
func on_flak_fired(r: Node) -> void:
	if _spawning or not Net.in_game:
		return
	var from: Vector3 = (r as Node3D).global_position
	var launcher := _launcher_id(from)
	if Net.is_server:
		if Net.live():
			_rx_flak.rpc_id(Net.other_id, from, r.vel, float(r.fuse_time), Net.abs_side(str(r.team)), launcher)
	else:
		r.net_puppet = true
		if Net.live():
			_rx_flak_req.rpc_id(1, from, r.vel, float(r.fuse_time), launcher)


@rpc("authority", "call_remote", "reliable")
func _rx_flak(from: Vector3, v: Vector3, fuse: float, side: int, launcher: int) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var ln := node_of(launcher)
	_spawning = true
	var r: Node = _scr(ROUND_PATH).fire(get_tree().current_scene, from, v, Net.local_team(side), _exclude_of(ln), fuse)
	_spawning = false
	r.net_puppet = true
	if ln != null and ln.has_method("net_fire_fx"):
		ln.net_fire_fx()


@rpc("any_peer", "call_remote", "reliable")
func _rx_flak_req(from: Vector3, v: Vector3, fuse: float, launcher: int) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or not Net.peer_ready:
		return
	if v.length() > float(_scr(BALANCE_PATH).FLAK_SPEED) * 1.3:
		return
	var ln := node_of(launcher)
	_spawning = true
	_scr(ROUND_PATH).fire(get_tree().current_scene, from, v, Net.local_team(Net.other_side()), _exclude_of(ln), clampf(fuse, 0.0, 10.0))
	_spawning = false
	if ln != null and ln.has_method("net_fire_fx"):
		ln.net_fire_fx()


# =================================================================================================
# Undo / sell from a client, quiet removals (BaseKit.deconstruct)
# =================================================================================================

## Client (build_tool.gd Z / X): take structure `id` down. refund_k >= 0.999: an undo (the full price,
## within UNDO_TIME of the build, only what we built ourselves); else a sale (Balance.SELL_REFUND).
func request_unbuild(id: int, refund_k: float) -> void:
	if Net.is_client() and Net.live() and id != 0:
		_rx_unbuild_req.rpc_id(1, id, refund_k)


@rpc("any_peer", "call_remote", "reliable")
func _rx_unbuild_req(id: int, refund_k: float) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or not Net.peer_ready:
		return
	var n: Node = _nodes.get(id) if (id & TORP_BASE) == 0 else null
	if n != null and (not is_instance_valid(n) or not n.is_inside_tree()):
		n = null
	var bk := _scr(BASE_KIT_PATH)
	var k := 1.0 if refund_k >= 0.999 else float(_scr(BALANCE_PATH).SELL_REFUND)
	var why := "Yapı yok" if n == null else str(bk.call("unbuild_reason", n, k, Net.local_team(Net.other_side())))
	if why == "" and k >= 0.999 and str(n.get_meta("builder", "")) != Net.other_name:
		why = "Sadece kendi kurduğunu geri alabilirsin"
	if why != "":
		_rx_unbuild_denied.rpc_id(Net.other_id, why)
		return
	var nm := str(bk.call("display_name", str(bk.call("kind_of", n))))
	var back := float(bk.call("refund_of", n, k))
	bk.call("deconstruct", n)
	if Game.shared_pool:
		Game.add_material(back)                # (the team pool: the client sees it in the next pool value)
	_rx_refund.rpc_id(Net.other_id, back, nm, k >= 0.999)


@rpc("authority", "call_remote", "reliable")
func _rx_unbuild_denied(why: String) -> void:
	if Net.is_server or not Net.in_game:
		return
	if Game.hud:
		Game.hud.show_message(why.left(80), 1.8)
	if Game.sfx:
		Game.sfx.play("error", -10.0)


## Client: our undo / sale went through: the refund (own material; in the co-op team pool the host
## added it already) and the line.
@rpc("authority", "call_remote", "reliable")
func _rx_refund(back: float, piece: String, undo: bool) -> void:
	if Net.is_server or not Net.in_game:
		return
	var b := clampf(back, 0.0, 5000.0)
	if not Game.shared_pool:
		Game.add_material(b)
	if Game.hud:
		Game.hud.show_message("%s %s (+%d m³)" % [piece.left(40), "geri alındı" if undo else "söküldü", roundi(b)], 2.0)
	if Game.sfx:
		Game.sfx.play("toggle", -8.0, 0.8)


## Host (BaseKit.deconstruct_hook, at the start of a quiet removal): the client takes it down too.
func _on_deconstruct(n: Node) -> void:
	if not Net.is_server or not Net.live() or n == null or not is_instance_valid(n):
		return
	var id := id_of(n)
	if id != 0:
		_rx_deconstruct.rpc_id(Net.other_id, id)


@rpc("authority", "call_remote", "reliable")
func _rx_deconstruct(id: int) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var n := node_of(id)
	if n == null or not (n is Node3D):
		return
	_nodes.erase(id)
	_scr(BASE_KIT_PATH).call("deconstruct", n)


# =================================================================================================
# Hit claims (client bullets -> host)
# =================================================================================================

## A hit point on the wire (Game.hit_pos through claims and hurts: hit_reactor.gd reads it): in the
## target's own frame (the puppet on one side, the real body on the other: the same spot on the suit),
## 1 cm steps up to ±5.11 m, one int of 3 × 10 bits; -1 = none (INF, too far, not a Node3D).
func pack_point(n: Node, p: Vector3) -> int:
	if p == Vector3.INF or n == null or not is_instance_valid(n) or not (n is Node3D):
		return -1
	var l: Vector3 = (n as Node3D).global_transform.affine_inverse() * p
	if absf(l.x) > 5.11 or absf(l.y) > 5.11 or absf(l.z) > 5.11:
		return -1
	return (roundi(l.x * 100.0) + 512) | ((roundi(l.y * 100.0) + 512) << 10) | ((roundi(l.z * 100.0) + 512) << 20)


func unpack_point(n: Node, code: int) -> Vector3:
	if code < 0 or n == null or not is_instance_valid(n) or not (n is Node3D):
		return Vector3.INF
	var l := Vector3(float((code & 1023) - 512), float(((code >> 10) & 1023) - 512), float(((code >> 20) & 1023) - 512)) * 0.01
	return (n as Node3D).global_transform * l


## Game.damage_target on a client: send the hit to the host; returns a predicted result for the
## shooter's hit feel ({} = not a networked target). hit_point: where it struck (world; INF = none).
func claim_damage(target: Node, amount: float, from_pos: Vector3, impulse: Vector3, hit_point := Vector3.INF) -> Dictionary:
	if not Net.live() or target == null or not is_instance_valid(target) or amount <= 0.0:
		return {}
	var id := 0
	if target.is_in_group("net_player"):
		id = ID_HOST_PLAYER
	elif target.is_in_group("war_torpedo") and target.get("net_id") != null:
		id = int(target.get("net_id"))
	elif target != Game.player:
		id = id_of(target)
	if id == 0:
		return {}
	_rx_claim.rpc_id(1, id, amount, from_pos, impulse, pack_point(target, hit_point))
	var hp = target.get("hp")
	var h := float(hp) if hp != null else 100.0
	return {"dmg": amount, "killed": h > 0.0 and amount >= h}


@rpc("any_peer", "call_remote", "reliable")
func _rx_claim(id: int, amount: float, from_pos: Vector3, impulse: Vector3, point: int) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or not Net.peer_ready:
		return
	var n: Node = null
	if id == ID_HOST_PLAYER:
		n = Game.player
	elif id >= ID_BOT and id < ID_STRUCT:
		n = Net.bots.node_of(id)
	else:
		n = node_of(id)
	if n == null or not is_instance_valid(n):
		return
	var amt := clampf(amount, 0.0, 300.0)
	if n == Game.player and Net.other_side() == Net.my_side():
		amt *= float(_scr(BALANCE_PATH).FRIENDLY_FIRE)
	var r := Game.damage_target(n, amt, from_pos, impulse.limit_length(30.0), Net.local_team(Net.other_side()),
			unpack_point(n, point))
	if bool(r.get("killed", false)):
		# Kill feed on the host: the other player got this one.
		var hf_s := _scr("res://scripts/items/hit_feel.gd")
		var hf = hf_s.call("inst") if hf_s != null else null
		if hf != null and hf.has_method("feed"):
			var victim: String = "Sen" if n == Game.player else str(hf_s.call("display_name", n))
			hf.feed(Net.other_name, victim, "", false)


# =================================================================================================
# Snapshot (late join / restart)
# =================================================================================================

func build_snapshot() -> Dictionary:
	var structs: Array = []
	for id in _nodes:
		var n = _nodes[id]
		if is_instance_valid(n) and n.is_inside_tree():
			structs.append(_entry(n, false))
	var cores: Array = []
	for bi in 2:
		var c := _core_of(bi)
		cores.append([float(c.get("hp")), bool(c.get("destroyed"))] if c != null else [-1.0, false])
	var torps: Array = []
	for id in _torps:
		var t = _torps[id]
		if t != null and is_instance_valid(t) and t.is_inside_tree() and bool(t.call("is_live")):
			var st: Dictionary = t.call("net_state")
			torps.append([int(id), Net.abs_side(str(t.get("team"))), (t as Node3D).global_position, st["vel"],
					int(st["state"]), st["tip"], st["dir"], float(st["hp"])])
	_last_state.clear()
	_core_sent.clear()
	return {"structs": structs, "cores": cores, "torps": torps}


func apply_snapshot(snap: Dictionary) -> void:
	for e in snap.get("structs", []):
		if e is Dictionary:
			_spawn_entry(e)
	var cores: Array = snap.get("cores", [])
	for bi in mini(cores.size(), 2):
		var cv: Array = cores[bi]
		var c := _core_of(bi)
		if c != null and float(cv[0]) >= 0.0:
			c.net_set_hp(float(cv[0]), bool(cv[1]))
	for e in snap.get("torps", []):
		if e is Array and (e as Array).size() >= 8:
			var t := _torp_replica(int(e[0]), e[2], e[3], int(e[1]))
			if t != null:
				t.call("set_remote_state", int(e[4]), e[5], e[6], float(e[7]), e[3])


# =================================================================================================
# Drilling torpedoes (scripts/war/torpedo.gd). Every Torpedo.fire() (the player's launcher, the AI)
# emits Torpedo.events().launched: the host numbers it and the client gets a puppet
# (Torpedo.fire_replica); a client's own launch becomes a puppet at once and the host fires the
# real one with the same id. The host sends every state change (FLY / PLANT / BURROW / DUD / DEAD /
# DONE) reliably and the live ones at 4 Hz (state, drill head, direction, hp, velocity); the
# puppets follow with set_remote_state(). Hits on a puppet are claims (net_id); the carving comes
# through the terrain sync.
# =================================================================================================

func _hook_torpedoes() -> void:
	if _torp_hooked or not ResourceLoader.exists(TORPEDO_PATH):
		return
	var ev = _scr(TORPEDO_PATH).call("events")
	if ev != null and ev.has_signal("launched"):
		ev.connect("launched", _on_torpedo_launched)
		_torp_hooked = true


func _bind_torp(t: Node, id: int) -> void:
	t.set("net_id", id)
	_torps[id] = t
	if Net.is_server and t.has_signal("state_changed"):
		t.connect("state_changed", _on_torp_state)
	t.tree_exiting.connect(_on_torp_exit.bind(id), CONNECT_ONE_SHOT)


func _on_torp_exit(id: int) -> void:
	_torps.erase(id)


func _on_torpedo_launched(t: Node3D, from: Vector3, vel: Vector3, team: String) -> void:
	if _spawning or not Net.active or not Net.in_game or t == null:
		return
	if Net.is_server:
		var id := TORP_BASE | (_next_torp & 0x7FFFF)
		_next_torp += 1
		_bind_torp(t, id)
		if Net.live():
			_rx_torp.rpc_id(Net.other_id, id, from, vel, Net.abs_side(team))
	else:
		var id := TORP_BASE | CLIENT_TORP | (_next_torp & 0x7FFFF)
		_next_torp += 1
		t.set("net_puppet", true)
		_bind_torp(t, id)
		if Net.live():
			_rx_torp_req.rpc_id(1, id, from, vel)


func _torp_replica(id: int, from: Vector3, vel: Vector3, side: int) -> Node:
	if node_of(id) != null or not ResourceLoader.exists(TORPEDO_PATH):
		return node_of(id)
	var t: Node = _scr(TORPEDO_PATH).call("fire_replica", get_tree().current_scene, from, vel, Net.local_team(side))
	if t != null:
		_bind_torp(t, id)
	return t


@rpc("authority", "call_remote", "reliable")
func _rx_torp(id: int, from: Vector3, vel: Vector3, side: int) -> void:
	if Net.is_server or not Net.world_ready:
		return
	_torp_replica(id, from, vel, side)


@rpc("any_peer", "call_remote", "reliable")
func _rx_torp_req(id: int, from: Vector3, vel: Vector3) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or not Net.peer_ready:
		return
	if (id & TORP_BASE) == 0 or (id & CLIENT_TORP) == 0 or node_of(id) != null:
		return
	var vmax := float((_scr(BALANCE_PATH) as Script).get_script_constant_map().get("TORPEDO_SPEED_MAX", 40.0))
	if vel.length() > vmax * 1.3:
		return
	var ex: Array = []
	var av = Net.players.avatar
	if av != null and is_instance_valid(av) and av.get("_col") is CollisionObject3D:
		ex.append((av.get("_col") as CollisionObject3D).get_rid())
	_spawning = true
	var t: Node = _scr(TORPEDO_PATH).call("fire", get_tree().current_scene, from, vel, Net.local_team(Net.other_side()), ex)
	_spawning = false
	if t != null:
		_bind_torp(t, id)


## Host: a torpedo changed state (landed, burrowing, dud, killed, reached the core).
func _on_torp_state(t: Node, _st: int) -> void:
	var id := int(t.get("net_id"))
	if id == 0 or not Net.live():
		return
	var s: Dictionary = t.call("net_state")
	_rx_torp_state.rpc_id(Net.other_id, id, int(s["state"]), s["tip"], s["dir"], float(s["hp"]), s["vel"])


func _send_torps() -> void:
	if not Net.live():
		return
	for id in _torps:
		var t = _torps[id]
		if t == null or not is_instance_valid(t) or not bool(t.call("is_live")):
			continue
		var s: Dictionary = t.call("net_state")
		_rx_torp_upd.rpc_id(Net.other_id, int(id), int(s["state"]), s["tip"], s["dir"], float(s["hp"]), s["vel"])


@rpc("authority", "call_remote", "reliable")
func _rx_torp_state(id: int, st: int, tip: Vector3, dir: Vector3, hp: float, vel: Vector3) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var t := node_of(id)
	if t != null:
		t.call("set_remote_state", st, tip, dir, hp, vel)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rx_torp_upd(id: int, st: int, tip: Vector3, dir: Vector3, hp: float, vel: Vector3) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var t := node_of(id)
	if t != null:
		t.call("set_remote_state", st, tip, dir, hp, vel)


# =================================================================================================
# Silahlı Mekik (scripts/craft/armed_skiff.gd): weapon_fired(kind, pos, vel) from the skiff this
# machine flies goes to the other one, which calls net_fire() on its copy (the host's replay deals
# the damage; a client's is the look). Gun rounds (~14/s) are batched per frame, unreliable ordered
# (24 B each); rockets go one by one, reliable.
# =================================================================================================

func _flies_here(id: int, sk: Node) -> bool:
	if Net.is_server:
		return not _skiff_auth.has(id)
	return not bool(sk.get("net_puppet"))


func _on_skiff_weapon(kind: String, pos: Vector3, vel: Vector3, id: int) -> void:
	if not Net.live():
		return
	var sk := node_of(id)
	if sk == null or not _flies_here(id, sk):
		return
	if kind == "rocket":
		_rx_skiff_rocket.rpc_id(Net.other_id, id, pos, vel)
		return
	var b: PackedByteArray = _gun_out.get(id, PackedByteArray())
	var o := b.size()
	b.resize(o + 24)
	b.encode_float(o, pos.x)
	b.encode_float(o + 4, pos.y)
	b.encode_float(o + 8, pos.z)
	b.encode_float(o + 12, vel.x)
	b.encode_float(o + 16, vel.y)
	b.encode_float(o + 20, vel.z)
	_gun_out[id] = b


func _flush_gun() -> void:
	if _gun_out.is_empty():
		return
	if Net.live():
		for id in _gun_out:
			_rx_skiff_gun.rpc_id(Net.other_id, int(id), _gun_out[id])
	_gun_out.clear()


func _skiff_fire_ok(id: int) -> Node:
	if not Net.active or not Net.in_game or multiplayer.get_remote_sender_id() != Net.other_id:
		return null
	if not Net.is_server and not Net.world_ready:
		return null
	var sk := node_of(id)
	if sk == null or not sk.has_method("net_fire"):
		return null
	if Net.is_server and not _skiff_auth.has(id):
		return null                         # only the skiff the client flies
	return sk


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rx_skiff_gun(id: int, b: PackedByteArray) -> void:
	var sk := _skiff_fire_ok(id)
	if sk == null:
		return
	for i in mini(b.size() / 24, 16):
		var o := i * 24
		var p := Vector3(b.decode_float(o), b.decode_float(o + 4), b.decode_float(o + 8))
		var v := Vector3(b.decode_float(o + 12), b.decode_float(o + 16), b.decode_float(o + 20))
		sk.net_fire("gun", p, v)


@rpc("any_peer", "call_remote", "reliable")
func _rx_skiff_rocket(id: int, pos: Vector3, vel: Vector3) -> void:
	var sk := _skiff_fire_ok(id)
	if sk != null:
		sk.net_fire("rocket", pos, vel)


# =================================================================================================
# Silahlık (scripts/war/armory.gd): crafting is local to the player who ordered it (it pays, the
# finish grants it to that player only). Only the fabricator LOOK syncs: the host's own craft rides
# in the structure state (SF_CRAFTING + craft_k in the charge byte); the client's goes to the host
# at 10 Hz while it runs. A look is never applied over a local job.
# =================================================================================================

## The armory runs a craft started on THIS machine.
func _crafting_here(s: Node) -> bool:
	if s.get("craft_k") == null or not bool(s.get("crafting")):
		return false
	var job = s.get("job")
	return job is Dictionary and not (job as Dictionary).is_empty()


func _craft_look(s: Node, on: bool, k: float) -> void:
	var job = s.get("job")
	if job is Dictionary and not (job as Dictionary).is_empty():
		return                             # our own craft runs here
	s.set("crafting", on)
	s.set("craft_k", clampf(k, 0.0, 1.0) if on else 0.0)


## Client: our running crafts' look to the host (and one "done" when they end).
func _send_craft_looks() -> void:
	for id in _nodes:
		var s = _nodes[id]
		if not is_instance_valid(s) or s.get("craft_k") == null:
			continue
		if _crafting_here(s):
			_craft_sent[id] = true
			_rx_craft_look.rpc_id(1, int(id), true, float(s.get("craft_k")))
		elif _craft_sent.has(id):
			_craft_sent.erase(id)
			_rx_craft_look.rpc_id(1, int(id), false, 0.0)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rx_craft_look(id: int, on: bool, k: float) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id:
		return
	var s := node_of(id)
	if s != null and s.get("craft_k") != null:
		_craft_look(s, on, k)
