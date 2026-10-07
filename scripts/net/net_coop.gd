extends Node
## Co-op ("Birlikte") build features (child "Coop" of the Net autoload): the TEAM MATERIAL POOL, the
## partner's build intent and the build pings. PvP has none of them (each side its own material).
##
## Team pool (game side: Game.shared_pool, scripts/game.gd): the HOST owns `Game.material`. OFF since
## 2026-10-06 (Balance.COOP_SHARED_POOL false, the user: "herkesin bakiyesi ayrı olsun"): each player
## his own material like PvP; team incomes (zones, core pump, auto-miners) pay every teammate in full.
##   World start (and every restart), with the flag on: host Game.set_shared_pool(true, 2 ×
##   START_MATERIAL), client Game.set_shared_pool(true); flag off / PvP / leaving: set_shared_pool(false).
##   client -> host  pool_delta {seq, sum}   reliable, every 0.1 s while the client's own changes
##                                           (Game.pool_delta: digging, builds, crafts, ammo, refunds,
##                                           pickups) add up; the host applies net_pool_delta(sum)
##                                           (clamped ±5000) and remembers the newest seq
##   host -> client  pool {value, last_seq}  unreliable_ordered, ≤ 10 Hz on change + every 1 s; the
##                                           client shows value + its deltas newer than last_seq
##                                           (Game.net_set_pool): its own spending never jumps back
## Build intent (scripts/war/build_intent.gd BuildIntent.intent_out, ≤ 5 Hz): {on, id, name, xf, ok}
##   -> intent, unreliable_ordered -> BuildIntent.show_remote(data, Net.other_name) (the partner's ghost).
## Build pings (BuildIntent.ping_out(pos, label)) -> build_ping, reliable -> BuildIntent.ping(pos,
##   label, Net.other_name, false).
## (The build notifications, undo / sell and the quiet removal: net_world.gd.)

const BALANCE_PATH := "res://scripts/war/balance.gd"
const INTENT_PATH := "res://scripts/war/build_intent.gd"
const DELTA_PERIOD := 0.1
const POOL_PERIOD := 0.1
const POOL_REFRESH := 1.0
const DELTA_MAX := 5000.0

var _hooked_game := false
var _bi: Node = null                    # the BuildIntent node our signals are connected to
# Client
var _seq := 0
var _pend := 0.0                        # deltas not sent yet
var _sent: Array = []                   # [seq, sum] sent, not yet in a host value
var _delta_t := 0.0
# Host
var _last_seq := 0
var _pool_t := 0.0
var _refresh_t := 0.0
var _sent_v := -1.0
var _sent_seq := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func coop() -> bool:
	return Net.active and Net.mode == Net.MODE_COOP


func begin(_main: Node) -> void:
	_clear()
	if not _hooked_game:
		Game.pool_delta.connect(_on_pool_delta)
		_hooked_game = true
	# Balance.COOP_SHARED_POOL off (2026-10-06, the user: "herkesin bakiyesi ayrı olsun"): co-op works
	# like PvP, each player his own Game.material (Game.reset_state gave both START_MATERIAL).
	if coop() and bool(load(BALANCE_PATH).COOP_SHARED_POOL):
		if Net.is_server:
			var start := float(load(BALANCE_PATH).START_MATERIAL) * 2.0
			Game.set_shared_pool(true, start)
		else:
			Game.set_shared_pool(true)
	else:
		Game.set_shared_pool(false)


## The scene is going (restart / leaving) or the session ended: the pool is off until the next begin.
func reset() -> void:
	_clear()
	if Game.shared_pool:
		Game.set_shared_pool(false)


func on_peer_gone() -> void:
	_last_seq = 0
	_sent_v = -1.0
	_sent_seq = -1


func _clear() -> void:
	_seq = 0
	_pend = 0.0
	_sent.clear()
	_last_seq = 0
	_sent_v = -1.0
	_sent_seq = -1
	_bi = null


func _sender_ok() -> bool:
	return Net.active and Net.in_game and multiplayer.get_remote_sender_id() == Net.other_id


func _process(delta: float) -> void:
	if not Net.active or not Net.in_game:
		return
	if coop():
		_hook_intent()
	if not Game.shared_pool or not Net.live():
		return
	if Net.is_server:
		_pool_t -= delta
		_refresh_t -= delta
		if _pool_t > 0.0:
			return
		_pool_t = POOL_PERIOD
		if Game.material != _sent_v or _last_seq != _sent_seq or _refresh_t <= 0.0:
			_sent_v = Game.material
			_sent_seq = _last_seq
			_refresh_t = POOL_REFRESH
			_rx_pool.rpc_id(Net.other_id, Game.material, _last_seq)
	else:
		_delta_t -= delta
		if _delta_t > 0.0 or is_zero_approx(_pend):
			return
		_delta_t = DELTA_PERIOD
		_seq += 1
		_sent.append([_seq, _pend])
		_rx_pool_delta.rpc_id(1, _seq, _pend)
		_pend = 0.0


# =================================================================================================
# Team pool
# =================================================================================================

## Client: our own change to the team pool (Game.add_material while shared).
func _on_pool_delta(d: float) -> void:
	if Net.is_client() and Game.shared_pool:
		_pend += d


@rpc("any_peer", "call_remote", "reliable")
func _rx_pool_delta(seq: int, sum: float) -> void:
	if not Net.is_host() or not _sender_ok() or not Game.shared_pool or not is_finite(sum):
		return
	Game.net_pool_delta(clampf(sum, -DELTA_MAX, DELTA_MAX))
	_last_seq = maxi(_last_seq, seq)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rx_pool(value: float, last_seq: int) -> void:
	if Net.is_server or not Net.in_game or not Game.shared_pool or not is_finite(value):
		return
	var pending := _pend
	var keep: Array = []
	for e in _sent:
		if int(e[0]) > last_seq:
			keep.append(e)
			pending += float(e[1])
	_sent = keep
	Game.net_set_pool(value + pending)


# =================================================================================================
# The partner's build intent and pings (co-op only)
# =================================================================================================

func _intent():
	return load(INTENT_PATH)


## Connects the scene's BuildIntent node (made on first use; a new one after every scene restart).
func _hook_intent() -> void:
	if _bi != null and is_instance_valid(_bi) and _bi.is_inside_tree():
		return
	if get_tree().current_scene == null or not ResourceLoader.exists(INTENT_PATH):
		return
	var n = _intent().call("inst")
	if n == null or not is_instance_valid(n):
		return
	_bi = n
	if n.has_signal("intent_out") and not n.is_connected("intent_out", _on_intent_out):
		n.connect("intent_out", _on_intent_out)
	if n.has_signal("ping_out") and not n.is_connected("ping_out", _on_ping_out):
		n.connect("ping_out", _on_ping_out)


func _on_intent_out(data: Dictionary) -> void:
	if coop() and Net.live():
		_rx_intent.rpc_id(Net.other_id, data)


func _on_ping_out(pos: Vector3, label: String) -> void:
	if coop() and Net.live():
		_rx_build_ping.rpc_id(Net.other_id, pos, label.left(40))


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rx_intent(data: Dictionary) -> void:
	if not _sender_ok() or not Net.live() or not coop():
		return
	var d := {"on": data.get("on") == true}
	if bool(d["on"]):
		var xf = data.get("xf")
		if not (xf is Transform3D) or not (xf as Transform3D).origin.is_finite():
			return
		d["id"] = str(data.get("id", "")).left(32)
		d["name"] = str(data.get("name", "")).left(40)
		d["xf"] = xf
		d["ok"] = data.get("ok") == true
	_intent().call("show_remote", d, Net.other_name)


@rpc("any_peer", "call_remote", "reliable")
func _rx_build_ping(pos: Vector3, label: String) -> void:
	if not _sender_ok() or not Net.live() or not coop() or not pos.is_finite():
		return
	_intent().call("ping", pos, label.left(40), Net.other_name, false)
