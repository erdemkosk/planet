extends Node
## Autoload "Net": two-player multiplayer over the user's relay (WebRTC, scripts/net/net_relay.gd).
## Single player never touches any of this: Net.active stays false and every hook in the game
## checks it first.
##
## Session: host_room(mode) opens a room ("UZAY-" + 5 letters) and waits in the menu; join_room(code)
## connects to it. The client says hello (protocol + build fingerprint: planet seeds / sizes, every
## Balance constant), the host answers with the match config (mode, seeds, sides) and both load
## the game scene. main.gd calls world_built(); the client then asks for the world and the host
## streams it (terrain edits, structures, cores, skiffs, bots), after which live updates flow.
## Late join / rejoin and "Yeniden başla" (host reloads both) use the same path.
##
## Authority: the HOST owns the AI, shells / flak impacts, every hp (players, bots, structures,
## skiffs, cores), structure spawns, crater events and the match end. Each peer owns its own
## player movement and the skiff it pilots. Modules (children with fixed names so RPC paths match):
##   Terrain (net_terrain.gd)  brush ops, ordering, drift check, snapshot
##   Players (net_players.gd)  player state 20 Hz, remote astronaut, shots, drill, damage, death
##   World   (net_world.gd)    structures, shells, flak, cores, skiffs, build requests, hit claims
##   Bots    (net_bots.gd)     AI bot snapshots 10 Hz + events, puppets on the client
##   Drops   (net_drops.gd)    material loot pickups, the rival's drop pods
##   Coop    (net_coop.gd)     co-op team material pool, the partner's build intent, build pings
##   Overlay (net_overlay.gd)  in-game chat, ping, toasts, loading / dialogs
##
## Sides: absolute side 0 = Yurt (the host), 1 = Rakip (the AI in co-op, the client in PvP). The game
## code speaks in LOCAL team strings ("home" = mine, "rival" = theirs); local_team() / abs_side()
## translate at the network boundary. In PvP the client swaps Game.planet / Game.rival (main.gd), so
## to it "home" is the Rakip planet: every own-planet check, HUD label and spawn just works.

signal status(text: String)
signal failed(reason: String)
signal session_ready

const MpConfig := preload("res://scripts/net/mp_config.gd")
const Relay := preload("res://scripts/net/net_relay.gd")
const Rooms := preload("res://scripts/net/net_rooms.gd")
const Terrain := preload("res://scripts/net/net_terrain.gd")
const Players := preload("res://scripts/net/net_players.gd")
const World := preload("res://scripts/net/net_world.gd")
const Bots := preload("res://scripts/net/net_bots.gd")
const Drops := preload("res://scripts/net/net_drops.gd")
const Coop := preload("res://scripts/net/net_coop.gd")
const Overlay := preload("res://scripts/net/net_overlay.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const Balance := preload("res://scripts/war/balance.gd")

const PROTOCOL := 2                # 2: the bot snapshot grew a suppression byte (net_bots.gd)
const MODE_COOP := 0
const MODE_PVP := 1
const MODE_NAMES := ["Birlikte", "Karşı Karşıya"]
const GAME_SCENE := "res://scenes/main.tscn"
const MENU_SCENE := "res://scenes/menu.tscn"
const CONNECT_TIMEOUT := 35.0
const PING_PERIOD := 1.0

var active := false               # in a multiplayer session (hosting or joined)
var is_server := false
var mode := MODE_COOP
var cfg := {}                     # match config (the host's, sent in the welcome)
var room_code := ""
var my_name := ""
var other_name := ""
var other_id := 0                 # the other peer's multiplayer id (0 = nobody)
var welcomed := false             # handshake done with the other peer
var in_game := false              # the game scene is up (main.gd world_built)
var world_ready := false          # client: the host's world is applied
var peer_ready := false           # host: the client has the world; live updates flow
var rtt_ms := -1
var last_message := ""            # shown by the menu after leaving a session

var relay: Node
var rooms: Node
var terrain: Node
var players: Node
var world: Node
var bots: Node
var drops: Node
var coop: Node
var overlay: CanvasLayer

var _connect_t := -1.0
var _ping_t := 0.0
var _pending_scene_ready := false
var _leaving := false
var _scene_main: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	relay = _child(Relay.new(), "Relay")
	rooms = _child(Rooms.new(), "Rooms")
	terrain = _child(Terrain.new(), "Terrain")
	players = _child(Players.new(), "Players")
	world = _child(World.new(), "World")
	bots = _child(Bots.new(), "Bots")
	drops = _child(Drops.new(), "Drops")
	coop = _child(Coop.new(), "Coop")
	overlay = Overlay.new()
	overlay.name = "Overlay"
	add_child(overlay)
	relay.failed.connect(_on_relay_failed)
	relay.progress.connect(func(t: String) -> void: status.emit(t))
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	my_name = MpConfig.player_name()


func _child(n: Node, nm: String) -> Node:
	n.name = nm
	add_child(n)
	return n


# =================================================================================================
# Queries (used all over the game; all false / neutral in single player)
# =================================================================================================

func is_host() -> bool:
	return active and is_server


func is_client() -> bool:
	return active and not is_server


func pvp() -> bool:
	return active and mode == MODE_PVP


## Gameplay messages may flow to the other peer now.
func live() -> bool:
	if not active or other_id == 0 or not in_game or not welcomed:
		return false
	return peer_ready if is_server else world_ready


## In PvP the client plays the Rakip side: its Game.planet is the Rakip planet.
func swap_perspective() -> bool:
	return is_client() and mode == MODE_PVP


## Whether the AI rival team runs on this machine (single player; the host in co-op).
func ai_enabled() -> bool:
	return not active or (is_server and mode == MODE_COOP)


## Absolute side of this machine's player (0 Yurt, 1 Rakip).
func my_side() -> int:
	return 1 if swap_perspective() else 0


## Absolute side of the other player.
func other_side() -> int:
	return (1 if mode == MODE_PVP else 0) if is_server else 0


func local_team(abs_side_: int) -> String:
	return "home" if abs_side_ == my_side() else "rival"


func abs_side(local: String) -> int:
	return my_side() if local == "home" else 1 - my_side()


## Absolute body index: 0 = the Yurt planet (preset "home"), 1 = the Rakip planet.
func body_index(b: Object) -> int:
	if b != null and is_instance_valid(b) and str(b.get("preset_name")) == "rival":
		return 1
	return 0


func body_by_index(i: int) -> Node3D:
	return Bodies.by_preset("rival" if i == 1 else "home")


## Planet overrides for main.gd: the host's seeds (identical builds produce identical planets).
func planet_overrides(preset: String) -> Dictionary:
	if not active or cfg.is_empty():
		return {}
	var k := "seed_" + preset
	return {"seed": int(cfg[k])} if cfg.has(k) else {}


## Hash of everything both sides must agree on: protocol, planet sizes and seeds, every balance
## constant. A mismatch refuses the join ("Sürümler farklı").
static func fingerprint() -> int:
	var parts: Array = [PROTOCOL, Bodies.PLANET_RADIUS, Bodies.PLANET_DISTANCE]
	for p in ["home", "rival"]:
		parts.append(int((Bodies.PRESETS[p] as Dictionary).get("seed", 0)))
	var bal: Dictionary = (Balance as Script).get_script_constant_map()
	var keys: Array = bal.keys()
	keys.sort()
	for k in keys:
		if bal[k] is Object:
			continue                       # (a preloaded resource prints its instance id)
		parts.append(str(k))
		parts.append(str(bal[k]))
	return hash(str(parts))


func _make_cfg() -> Dictionary:
	return {"mode": mode, "fp": fingerprint(), "proto": PROTOCOL, "host_name": my_name,
			"seed_home": int((Bodies.PRESETS["home"] as Dictionary).get("seed", 0)),
			"seed_rival": int((Bodies.PRESETS["rival"] as Dictionary).get("seed", 0)),
			"radius": Bodies.PLANET_RADIUS, "distance": Bodies.PLANET_DISTANCE,
			"match": randi()}


# =================================================================================================
# Session: lobby side
# =================================================================================================

func host_room(p_mode: int) -> void:
	_shutdown()
	last_message = ""
	mode = p_mode
	my_name = MpConfig.player_name()
	room_code = MpConfig.new_room_code()
	cfg = _make_cfg()
	status.emit("Oda kuruluyor…")
	relay.host_room(room_code)


func join_room(code: String) -> void:
	_shutdown()
	last_message = ""
	my_name = MpConfig.player_name()
	room_code = MpConfig.normalize_code(code)
	if room_code.is_empty():
		failed.emit("Oda kodunu yaz.")
		return
	_connect_t = 0.0
	status.emit("Sunucuya bağlanılıyor…")
	relay.join_room(room_code)


## Lobby: stop hosting / joining (back to the menu's main page).
func cancel() -> void:
	_shutdown()


## Called by net_relay.gd when the WebRTC peer object is ready.
func adopt(peer: MultiplayerPeer, as_host: bool) -> int:
	if active:
		return ERR_ALREADY_IN_USE
	if peer == null:
		return ERR_INVALID_PARAMETER
	multiplayer.multiplayer_peer = peer
	active = true
	is_server = as_host
	other_id = 0
	welcomed = false
	return OK


func _on_relay_failed(reason: String) -> void:
	if active and is_server and in_game:
		# The relay only brokers joins: the running game (and a connected friend) goes on.
		overlay.toast("Sunucu bağlantısı koptu — yeni oyuncu katılamaz.", 4.0)
		return
	if active and not is_server and welcomed and other_id != 0:
		return
	var was_game := in_game
	_shutdown()
	if was_game:
		_go_menu(reason)
	else:
		failed.emit(reason)


func _on_peer_connected(id: int) -> void:
	if not active:
		return
	if is_server and other_id != 0 and other_id != id:
		_reject.rpc_id(id, "Oda dolu.")
		_kick_later(id)


func _on_connected_to_server() -> void:
	if not active or is_server:
		return
	status.emit("Bağlandı — oyun bilgisi bekleniyor…")
	_hello.rpc_id(1, PROTOCOL, fingerprint(), my_name)


func _on_connection_failed() -> void:
	if is_client() and not welcomed:
		_fail_lobby("Oda sahibine bağlanılamadı.")


func _on_server_disconnected() -> void:
	if is_client():
		_go_menu("Host ayrıldı.")


func _on_peer_disconnected(id: int) -> void:
	if not active:
		return
	if is_server and id == other_id:
		_other_gone()
	elif not is_server and id == 1:
		_go_menu("Host ayrıldı.")


@rpc("any_peer", "call_remote", "reliable")
func _hello(proto: int, fp: int, p_name: String) -> void:
	if not is_server:
		return
	var id := multiplayer.get_remote_sender_id()
	if other_id != 0 and other_id != id:
		_reject.rpc_id(id, "Oda dolu.")
		_kick_later(id)
		return
	if proto != PROTOCOL or fp != fingerprint():
		_reject.rpc_id(id, "Sürümler farklı — iki taraf da oyunun aynı sürümünü çalıştırmalı.")
		_kick_later(id)
		return
	other_id = id
	other_name = MpConfig.clean_name(p_name)
	welcomed = true
	peer_ready = false
	_welcome.rpc_id(id, cfg)
	status.emit("%s bağlandı." % other_name)
	if in_game:
		overlay.toast("%s oyuna katılıyor…" % other_name, 3.0)
	else:
		start_game()


@rpc("authority", "call_remote", "reliable")
func _welcome(c: Dictionary) -> void:
	if is_server:
		return
	cfg = c
	mode = int(c.get("mode", MODE_COOP))
	other_name = str(c.get("host_name", "Host"))
	other_id = 1
	welcomed = true
	_connect_t = -1.0
	if int(c.get("fp", 0)) != fingerprint() or int(c.get("proto", 0)) != PROTOCOL:
		_shutdown()
		failed.emit("Sürümler farklı — iki taraf da oyunun aynı sürümünü çalıştırmalı.")
		return
	session_ready.emit()
	start_game()


@rpc("authority", "call_remote", "reliable")
func _reject(reason: String) -> void:
	if is_server:
		return
	_fail_lobby(reason)


func _fail_lobby(reason: String) -> void:
	var was_game := in_game
	_shutdown()
	if was_game:
		_go_menu(reason)
	else:
		failed.emit(reason)


func _kick_later(id: int) -> void:
	await get_tree().create_timer(0.6, true, false, true).timeout
	var mp := multiplayer.multiplayer_peer
	if mp != null and active and is_server and id != other_id and mp.has_method("disconnect_peer"):
		mp.disconnect_peer(id)


## Host: the client left (or dropped).
func _other_gone() -> void:
	if other_id == 0:
		return
	var nm := other_name
	other_id = 0
	welcomed = false
	peer_ready = false
	_pending_scene_ready = false
	players.on_peer_gone()
	world.on_peer_gone()
	terrain.on_peer_gone()
	bots.on_peer_gone()
	drops.on_peer_gone()
	coop.on_peer_gone()
	if in_game:
		if mode == MODE_PVP:
			overlay.ask_continue_vs_ai("%s (Rakip) ayrıldı." % nm)
		else:
			overlay.toast("%s ayrıldı — oyun sürüyor." % nm, 4.0)
	else:
		status.emit("Arkadaşın ayrıldı — yeni oyuncu bekleniyor…")


## PvP host after the rival player left: the AI takes over the Rakip side (co-op from now on).
func continue_vs_ai() -> void:
	if not is_server:
		return
	mode = MODE_COOP
	cfg["mode"] = MODE_COOP
	var war = get_tree().get_first_node_in_group("war_controller")
	if war != null and war.has_method("start_ai"):
		war.start_ai()
	overlay.toast("Yapay zekâ Rakip tarafını devraldı.", 3.0)


# =================================================================================================
# Game scene
# =================================================================================================

func start_game() -> void:
	in_game = false
	world_ready = is_server
	peer_ready = false
	rooms.stop()
	Game.reset_state()             # both start with the same material (Balance.START_MATERIAL)
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().change_scene_to_file(GAME_SCENE)


## main.gd: the world is built (planets, player, HUD, war). Hooks the modules in.
func world_built(main: Node) -> void:
	if not active:
		return
	in_game = true
	_scene_main = main
	main.tree_exiting.connect(_on_world_gone.bind(main))
	terrain.begin()
	players.begin(main)
	world.begin(main)
	bots.begin(main)
	drops.begin(main)
	coop.begin(main)
	overlay.show_game()
	if is_server:
		peer_ready = false
		world_ready = true
		if _pending_scene_ready and other_id != 0:
			_pending_scene_ready = false
			_start_sync()
	else:
		world_ready = false
		overlay.loading(true, "Dünya eşitleniyor…")
		_scene_ready.rpc_id(1)


func _on_world_gone(main: Node) -> void:
	if main != _scene_main:
		return
	_scene_main = null
	in_game = false
	peer_ready = false
	if not is_server:
		world_ready = false
	terrain.reset()
	players.reset()
	world.reset()
	bots.reset()
	drops.reset()
	coop.reset()
	overlay.hide_game()


@rpc("any_peer", "call_remote", "reliable")
func _scene_ready() -> void:
	if not is_server or multiplayer.get_remote_sender_id() != other_id:
		return
	if not in_game:
		_pending_scene_ready = true
		return
	_start_sync()


## Host: stream the world to the client (terrain chunks first, then the rest).
func _start_sync() -> void:
	peer_ready = false
	terrain.send_snapshot(other_id)


## Host (net_terrain.gd): the terrain went out; now structures, cores, skiffs, bots, match state.
func terrain_snapshot_sent(peer: int) -> void:
	if not is_server or peer != other_id or not in_game:
		return
	var snap: Dictionary = world.build_snapshot()
	snap["bots"] = bots.build_roster()
	snap["players"] = players.build_snapshot()
	snap["drops"] = drops.build_snapshot()
	_rx_world.rpc_id(peer, snap)
	peer_ready = true
	overlay.toast("%s oyunda." % other_name, 2.5)


@rpc("authority", "call_remote", "reliable")
func _rx_world(snap: Dictionary) -> void:
	if is_server or not in_game:
		return
	terrain.finish_snapshot()
	world.apply_snapshot(snap)
	bots.apply_roster(snap.get("bots", []))
	players.apply_snapshot(snap.get("players", {}))
	drops.apply_snapshot(snap.get("drops", {}))
	world_ready = true
	overlay.loading(false, "")
	overlay.toast("Bağlandın: %s (%s)" % [other_name, MODE_NAMES[clampi(mode, 0, 1)]], 3.0)


## Host: "Yeniden başla" for both.
func restart_match() -> void:
	if is_server and other_id != 0 and welcomed:
		_restart.rpc_id(other_id)
	_reload()


@rpc("authority", "call_remote", "reliable")
func _restart() -> void:
	if is_server:
		return
	overlay.toast("Host yeniden başlatıyor…", 3.0)
	_reload()


func _reload() -> void:
	in_game = false
	world_ready = is_server
	peer_ready = false
	Game.reset_state()
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().reload_current_scene()


## Esc › Odadan Ayrıl, end screen, dialogs.
func leave(message := "") -> void:
	if _leaving:
		return
	_leaving = true
	if active and other_id != 0:
		_bye.rpc_id(other_id)
	var mp := multiplayer.multiplayer_peer
	_shutdown(false)
	if mp != null:
		# Let the goodbye go out before the connection closes.
		get_tree().create_timer(0.3, true, false, true).timeout.connect(mp.close)
	_go_menu(message)
	_leaving = false


@rpc("any_peer", "call_remote", "reliable")
func _bye() -> void:
	if is_server:
		if multiplayer.get_remote_sender_id() == other_id:
			_other_gone()
	else:
		_go_menu("Host ayrıldı.")


func _go_menu(message: String) -> void:
	last_message = message
	_shutdown()
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file.call_deferred(MENU_SCENE)


## Ends the session (no scene change). close_peer = false keeps the peer open briefly (leave()).
func _shutdown(close_peer := true) -> void:
	relay.stop()
	rooms.stop()
	var mp := multiplayer.multiplayer_peer
	if close_peer and mp != null and not (mp is OfflineMultiplayerPeer):
		mp.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	active = false
	is_server = false
	other_id = 0
	welcomed = false
	world_ready = false
	peer_ready = false
	_pending_scene_ready = false
	_connect_t = -1.0
	rtt_ms = -1
	terrain.reset()
	players.reset()
	world.reset()
	bots.reset()
	drops.reset()
	coop.reset()
	if not in_game:
		overlay.hide_game()


# =================================================================================================
# Ping, chat
# =================================================================================================

func _process(delta: float) -> void:
	if _connect_t >= 0.0 and active == false and not relay.is_live():
		_connect_t = -1.0
	if _connect_t >= 0.0:
		_connect_t += delta
		if _connect_t > CONNECT_TIMEOUT and not welcomed:
			_connect_t = -1.0
			_fail_lobby("Bağlantı kurulamadı (zaman aşımı).")
	if not active or other_id == 0 or not welcomed:
		return
	_ping_t += delta
	if _ping_t >= PING_PERIOD:
		_ping_t = 0.0
		_ping.rpc_id(other_id, Time.get_ticks_msec())


@rpc("any_peer", "call_remote", "unreliable")
func _ping(t: int) -> void:
	if active and multiplayer.get_remote_sender_id() == other_id:
		_pong.rpc_id(other_id, t)


@rpc("any_peer", "call_remote", "unreliable")
func _pong(t: int) -> void:
	if active and multiplayer.get_remote_sender_id() == other_id:
		var r := maxi(Time.get_ticks_msec() - t, 0)
		rtt_ms = r if rtt_ms < 0 else int(lerpf(float(rtt_ms), float(r), 0.3))


func send_chat(text: String) -> void:
	var t := text.strip_edges().replace("\n", " ")
	if t.is_empty():
		return
	if t.length() > 160:
		t = t.substr(0, 160)
	overlay.add_chat(my_name, t, true)
	if active and other_id != 0 and welcomed:
		_chat.rpc_id(other_id, t)


@rpc("any_peer", "call_remote", "reliable")
func _chat(text: String) -> void:
	if not active or multiplayer.get_remote_sender_id() != other_id:
		return
	var t := text.strip_edges()
	if t.length() > 160:
		t = t.substr(0, 160)
	overlay.add_chat(other_name, t, false)


## Quit to the desktop from a session: the goodbye goes out first.
func quit_game() -> void:
	if active and other_id != 0:
		_bye.rpc_id(other_id)
	get_tree().create_timer(0.3, true, false, true).timeout.connect(get_tree().quit)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and active and other_id != 0:
		_bye.rpc_id(other_id)
		multiplayer.poll()
