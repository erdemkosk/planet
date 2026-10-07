extends Node
## Live lobby list from the relay (role=lobby): the open rooms of THIS game ("UZAY-" prefix; the
## relay is shared with another game on the same key), with player counts.
##   start() / stop(); signals rooms_changed(rooms: [{code, players, full}]), rooms_failed(reason)

signal rooms_changed(rooms: Array)
signal rooms_failed(reason: String)

const MpConfig := preload("res://scripts/net/mp_config.gd")
const TIMEOUT := 8.0
const PING_PERIOD := 4.0
const MAX_PLAYERS := 2

var _ws: WebSocketPeer = null
var _clock := 0.0
var _ping := 0.0
var _live := false
var _rooms: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


func rooms() -> Array:
	return _rooms


func is_live() -> bool:
	return _live


func start() -> void:
	if _live or not MpConfig.has_key():
		return
	_live = true
	_clock = 0.0
	_ping = 0.0
	_ws = WebSocketPeer.new()
	if _ws.connect_to_url(MpConfig.lobby_url()) != OK:
		_fail("Oda listesi alınamadı.")
		return
	set_process(true)


func stop() -> void:
	if _ws != null:
		_ws.close()
	set_process(false)
	_live = false
	_ws = null
	if not _rooms.is_empty():
		_rooms = []
		rooms_changed.emit(_rooms)


func _process(delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_ping += delta
			if _ping >= PING_PERIOD:
				_ping = 0.0
				_ws.send_text(JSON.stringify({"type": "ping", "t": 0}))
			while _ws != null and _ws.get_available_packet_count() > 0:
				_on_packet(_ws.get_packet())
		WebSocketPeer.STATE_CONNECTING:
			_clock += delta
			if _clock > TIMEOUT:
				_fail("Oda listesi alınamadı (sunucuya ulaşılamadı).")
		_:
			if _live:
				_fail("Oda listesi bağlantısı kapandı.")


func _on_packet(raw: PackedByteArray) -> void:
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	match String(msg.get("type", "")):
		"rooms":
			_apply(msg.get("rooms", []))
		"error":
			_fail("Oda listesi alınamadı: %s" % String(msg.get("reason", "")))


func _apply(raw: Variant) -> void:
	if typeof(raw) != TYPE_ARRAY:
		return
	var out: Array = []
	for item in raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var rec: Dictionary = item
		var code := MpConfig.display_room(String(rec.get("id", "")))
		if code.is_empty():
			continue
		var players := int(rec.get("playerCount", 0))
		out.append({"code": code, "players": players, "full": players >= MAX_PLAYERS})
	out.sort_custom(_by_code)
	_rooms = out
	rooms_changed.emit(_rooms)


static func _by_code(a: Dictionary, b: Dictionary) -> bool:
	return String(a["code"]) < String(b["code"])


func _fail(reason: String) -> void:
	set_process(false)
	_live = false
	_ws = null
	_rooms = []
	rooms_changed.emit(_rooms)
	rooms_failed.emit(reason)
