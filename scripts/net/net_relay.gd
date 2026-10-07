extends Node
## WebRTC over the signaling relay (relay-main/server.js): a WebSocket to the relay carries only the
## handshake (offer / answer / ICE); the game traffic then flows peer to peer in a
## WebRTCMultiplayerPeer that Net (scripts/net/net.gd) installs as multiplayer.multiplayer_peer.
## Ported from the bike_mike client and trimmed for two players (no host migration, no Steam).
##
##   host_room(code) / join_room(code)   start; signals: progress(text), joined(as_host), failed(reason)
##   stop()                              closes the signaling socket (the WebRTC session lives on)
##   rtt_ms                              signaling round trip (relay ping)
##
## Two players: the host accepts one client. A further peer gets a {"kind": "full"} signal and
## its client fails with "Oda dolu.". Same NAT (sameNat from the relay): a direct attempt first,
## after LAN_TIMEOUT s TURN-relay candidates only.

signal failed(reason: String)
signal joined(as_host: bool)
signal progress(text: String)

const MpConfig := preload("res://scripts/net/mp_config.gd")

const TIMEOUT := 12.0
const WEBRTC_TIMEOUT := 28.0
const LAN_TIMEOUT := 4.5
const PING_PERIOD := 2.0
const MAX_CLIENTS := 1

const SIG_OFFER := "offer"
const SIG_ANSWER := "answer"
const SIG_ICE := "ice"
const SIG_WANT_RELAY := "want-relay"
const SIG_FULL := "full"

const FALLBACK_ICE := [{"urls": ["stun:stun.l.google.com:19302"]}]

var rtt_ms := -1
var last_fail := ""

var _ws: WebSocketPeer = null
var _rtc: WebRTCMultiplayerPeer = null
var _ice: Array = []
var _as_host := false
var _room := ""
var _live := false
var _me := ""
var _host_sig := ""
var _conn: Dictionary = {}           # signal id -> WebRTCPeerConnection
var _num_by_sig: Dictionary = {}
var _sig_by_num: Dictionary = {}
var _next_id := 2
var _ice_queue: Dictionary = {}
var _desc_ready: Dictionary = {}
var _same_nat := false
var _same_nat_by_sig: Dictionary = {}
var _relay_only := false
var _relay_by_sig: Dictionary = {}
var _lan_clock: Dictionary = {}
var _relay_asked := false
var _clock := 0.0
var _webrtc_clock := 0.0
var _adopted := false
var _ping_clock := 0.0

static var _has_webrtc := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


## True when the WebRTC GDExtension (addons/webrtc_native) is loaded and works.
static func available() -> bool:
	if _has_webrtc >= 0:
		return _has_webrtc == 1
	_has_webrtc = 0
	if ClassDB.class_exists("WebRTCPeerConnection"):
		var probe := WebRTCPeerConnection.new()
		if probe != null and probe.initialize({"iceServers": FALLBACK_ICE}) == OK:
			var ch = probe.create_data_channel("probe", {"id": 1, "negotiated": true})
			_has_webrtc = 1 if ch != null else 0
			probe.close()
	return _has_webrtc == 1


## Why online play cannot start ("" = it can).
static func blocker() -> String:
	if not available():
		return "WebRTC eklentisi yüklenemedi (addons/webrtc_native). Oyun dosyalarını kontrol et."
	if not MpConfig.has_key():
		return "Bu sürümde çevrimiçi oyun kapalı."
	return ""


func host_room(code: String) -> void:
	_start(code, true)


func join_room(code: String) -> void:
	_start(code, false)


func room_code() -> String:
	return _room


func is_live() -> bool:
	return _live


func _start(code: String, as_host: bool) -> void:
	last_fail = ""
	var why := blocker()
	if not why.is_empty():
		failed.emit(why)
		return
	if _live:
		stop()
	_reset()
	_room = MpConfig.normalize_code(code)
	if _room.is_empty():
		failed.emit("Oda kodu boş.")
		return
	if not MpConfig.room_ok(_room):
		failed.emit("Oda kodu yalnız harf ve rakam olabilir.")
		return
	_as_host = as_host
	_ice = FALLBACK_ICE.duplicate(true)
	_live = true
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 18
	var err := _ws.connect_to_url(MpConfig.connect_url(MpConfig.wire_room(_room), as_host))
	if err != OK:
		print("[mp] relay'e bağlanılamadı: %s" % MpConfig.safe_url())
		_fail("Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.")
		return
	progress.emit("Sunucuya bağlanılıyor…")
	set_process(true)


func stop() -> void:
	set_process(false)
	if _ws != null:
		_ws.close()
	_reset()


func _reset() -> void:
	_live = false
	_adopted = false
	_ws = null
	_rtc = null
	_me = ""
	_host_sig = ""
	_conn.clear()
	_num_by_sig.clear()
	_sig_by_num.clear()
	_ice_queue.clear()
	_desc_ready.clear()
	_same_nat_by_sig.clear()
	_relay_by_sig.clear()
	_lan_clock.clear()
	_same_nat = false
	_relay_only = false
	_relay_asked = false
	_next_id = 2
	_clock = 0.0
	_webrtc_clock = 0.0
	_ping_clock = 0.0
	rtt_ms = -1


func _process(delta: float) -> void:
	for pc in _conn.values():
		if pc != null:
			pc.poll()
	_tick_lan_fallback(delta)
	_tick_client_webrtc(delta)
	if _ws == null:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_clock = 0.0
			_ping_clock += delta
			if _ping_clock >= PING_PERIOD:
				_ping_clock = 0.0
				_send({"type": "ping", "t": Time.get_ticks_msec()})
			var ws := _ws
			while ws != null and ws.get_available_packet_count() > 0:
				_on_packet(ws.get_packet())
				ws = _ws
		WebSocketPeer.STATE_CONNECTING:
			_clock += delta
			if _clock > TIMEOUT:
				print("[mp] relay yanıt vermedi: %s" % MpConfig.safe_url())
				_fail("Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.")
		_:
			if _live:
				print("[mp] relay bağlantısı kapandı: kod %d '%s'" % [_ws.get_close_code(), _ws.get_close_reason()])
				_fail("Sunucu bağlantısı koptu.", "closed")


func _tick_client_webrtc(delta: float) -> void:
	if _as_host or not _live or _host_sig.is_empty():
		return
	if _connected(_host_sig):
		return
	_webrtc_clock += delta
	if _webrtc_clock > WEBRTC_TIMEOUT:
		_fail("Oda sahibine bağlanılamadı (WebRTC). Tekrar dene.")


func _tick_lan_fallback(delta: float) -> void:
	if not _live:
		return
	if _as_host:
		var retry: Array = []
		for key in _lan_clock.keys():
			var sig := String(key)
			if bool(_relay_by_sig.get(sig, false)) or not bool(_same_nat_by_sig.get(sig, false)):
				continue
			if _connected(sig):
				_lan_clock.erase(sig)
				continue
			_lan_clock[sig] = float(_lan_clock[sig]) + delta
			if float(_lan_clock[sig]) >= LAN_TIMEOUT:
				retry.append(sig)
		for sig in retry:
			_host_retry_relay(String(sig))
		return
	if not _same_nat or _relay_only or _host_sig.is_empty() or not _conn.has(_host_sig):
		return
	if _connected(_host_sig):
		return
	_lan_clock[_host_sig] = float(_lan_clock.get(_host_sig, 0.0)) + delta
	if float(_lan_clock[_host_sig]) >= LAN_TIMEOUT:
		_ask_relay()


func _connected(sig: String) -> bool:
	var pc: WebRTCPeerConnection = _conn.get(sig)
	return pc != null and pc.get_connection_state() == WebRTCPeerConnection.STATE_CONNECTED


func _on_packet(raw: PackedByteArray) -> void:
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	match String(msg.get("type", "")):
		"welcome":
			_on_welcome(msg)
		"peer-joined":
			_on_peer_joined(msg)
		"peer-left":
			_on_peer_left(String(msg.get("peerId", "")))
		"signal":
			_on_signal(String(msg.get("from", "")), msg.get("data", {}))
		"room-full":
			_fail("Oda dolu.", "full")
		"host-taken":
			_fail("Bu oda kodu kullanımda — yeni bir kod dene.", "host-taken")
		"room-closed":
			_fail("Oda kapandı.", "closed")
		"pong":
			var sent := int(msg.get("t", 0))
			if sent > 0:
				rtt_ms = maxi(Time.get_ticks_msec() - sent, 0)
		"error":
			_on_error(String(msg.get("reason", "")))


func _on_error(reason: String) -> void:
	match reason:
		"no-host":
			_fail("Bu kodla açık bir oda yok.", "no-host")
		"unauthorized":
			_fail("Sunucu bağlantıyı kabul etmedi (anahtar).")
		"rate-limited":
			_fail("Çok fazla deneme — biraz bekle.")
		"invalid-room":
			_fail("Geçersiz oda kodu.")
		"server-full":
			_fail("Sunucu dolu.")
		_:
			_fail("Oda açılamadı: %s" % (reason if not reason.is_empty() else "bilinmeyen hata"))


func _on_welcome(msg: Dictionary) -> void:
	_me = String(msg.get("peerId", ""))
	_host_sig = String(msg.get("hostId", ""))
	_apply_ice(msg.get("iceServers", []))
	var same := bool(msg.get("sameNat", false)) or bool(msg.get("forceRelay", false))
	if _as_host:
		_rtc = WebRTCMultiplayerPeer.new()
		if _rtc.create_server() != OK:
			_fail("Oda kurulamadı.")
			return
		if not _adopt(true):
			return
		progress.emit("Oda açık — arkadaşın bekleniyor…")
		for peer in msg.get("peers", []):
			var sig := String(peer)
			if sig.is_empty() or sig == _me:
				continue
			_same_nat_by_sig[sig] = same
			_host_connect(sig)
		return
	_same_nat = same
	_webrtc_clock = 0.0
	if _host_sig.is_empty():
		# Nobody hosts this code: fail now instead of the relay's 60 s "waiting for host".
		_fail("Bu kodla açık bir oda yok.", "no-host")
		return
	progress.emit("Aynı ağ — doğrudan bağlanılıyor…" if same else "Oda sahibine bağlanılıyor…")


func _on_peer_joined(msg: Dictionary) -> void:
	var sig := String(msg.get("peerId", ""))
	var same := bool(msg.get("sameNat", false)) or bool(msg.get("forceRelay", false))
	if _as_host:
		if sig.is_empty() or sig == _me:
			return
		_same_nat_by_sig[sig] = same
		_relay_by_sig[sig] = false
		_host_connect(sig)
		return
	if _host_sig.is_empty():
		var host_id := String(msg.get("hostId", ""))
		if not host_id.is_empty():
			_host_sig = host_id
			_webrtc_clock = 0.0


func _on_peer_left(sig: String) -> void:
	if sig.is_empty():
		return
	if _as_host:
		var num := int(_num_by_sig.get(sig, 0))
		if num > 0 and _rtc != null and _rtc.has_peer(num):
			_rtc.remove_peer(num)
		_num_by_sig.erase(sig)
		_sig_by_num.erase(num)
		_forget(sig)
	elif sig == _host_sig:
		_fail("Oda sahibi ayrıldı.", "host-left")


func _forget(sig: String) -> void:
	_conn.erase(sig)
	_ice_queue.erase(sig)
	_desc_ready.erase(sig)
	_lan_clock.erase(sig)
	_same_nat_by_sig.erase(sig)


func _host_connect(sig: String, reuse: int = 0) -> void:
	if sig.is_empty() or _conn.has(sig) or _rtc == null:
		return
	var num := reuse
	if num <= 1:
		if _num_by_sig.has(sig):
			num = int(_num_by_sig[sig])
		else:
			if _num_by_sig.size() >= MAX_CLIENTS:
				# Two players only: tell the newcomer the room is full.
				_send_signal(sig, {"kind": SIG_FULL})
				return
			num = _next_id
			_next_id += 1
	var use_relay := bool(_relay_by_sig.get(sig, false))
	var pc := WebRTCPeerConnection.new()
	if pc.initialize({"iceServers": _ice}) != OK:
		progress.emit("Bir oyuncuyla bağlantı kurulamadı.")
		return
	pc.session_description_created.connect(_on_sdp.bind(sig))
	pc.ice_candidate_created.connect(_on_ice.bind(sig))
	_conn[sig] = pc
	_num_by_sig[sig] = num
	_sig_by_num[num] = sig
	_desc_ready[sig] = false
	if bool(_same_nat_by_sig.get(sig, false)) and not use_relay:
		_lan_clock[sig] = 0.0
	_rtc.add_peer(pc, num)
	if pc.create_offer() != OK:
		progress.emit("Bir oyuncuyla bağlantı kurulamadı.")
		return
	pc.poll()


func _host_retry_relay(sig: String) -> void:
	if sig.is_empty() or bool(_relay_by_sig.get(sig, false)):
		return
	var num := int(_num_by_sig.get(sig, 0))
	_relay_by_sig[sig] = true
	if num > 0 and _rtc != null and _rtc.has_peer(num):
		_rtc.remove_peer(num)
	_forget(sig)
	_host_connect(sig, num)


func _ask_relay() -> void:
	if _relay_asked or _host_sig.is_empty():
		return
	_relay_asked = true
	_relay_only = true
	_lan_clock.erase(_host_sig)
	progress.emit("Doğrudan bağlanılamadı — sunucu üzerinden deneniyor…")
	_send_signal(_host_sig, {"kind": SIG_WANT_RELAY})


func _on_sdp(type: String, sdp: String, sig: String) -> void:
	var pc: WebRTCPeerConnection = _conn.get(sig)
	if pc == null:
		return
	pc.set_local_description(type, sdp)
	var data := {"kind": type, "sdp": sdp}
	if type == SIG_OFFER:
		data["assigned_id"] = int(_num_by_sig.get(sig, 0))
	_send_signal(sig, data)


func _on_ice(media: String, index: int, cand: String, sig: String) -> void:
	if not _ice_ok(sig, cand):
		return
	_send_signal(sig, {"kind": SIG_ICE, "media": media, "index": index, "name": cand})


func _on_signal(from: String, raw: Variant) -> void:
	if typeof(raw) != TYPE_DICTIONARY or from.is_empty():
		return
	var data: Dictionary = raw
	var kind := String(data.get("kind", ""))
	if _as_host:
		_host_signal(from, kind, data)
	elif from == _host_sig:
		_client_signal(kind, data)


func _host_signal(from: String, kind: String, data: Dictionary) -> void:
	if kind == SIG_WANT_RELAY:
		_host_retry_relay(from)
		return
	var pc: WebRTCPeerConnection = _conn.get(from)
	if pc == null:
		if kind == SIG_ICE:
			_queue_ice(from, data)
		return
	match kind:
		SIG_ANSWER:
			pc.set_remote_description(SIG_ANSWER, String(data.get("sdp", "")))
			_desc_ready[from] = true
			_flush_ice(from, pc)
			pc.poll()
		SIG_ICE:
			_take_ice(from, pc, data)


func _client_signal(kind: String, data: Dictionary) -> void:
	match kind:
		SIG_FULL:
			_fail("Oda dolu.", "full")
		SIG_OFFER:
			_client_take_offer(data)
		SIG_ICE:
			var pc: WebRTCPeerConnection = _conn.get(_host_sig)
			if pc == null:
				_queue_ice(_host_sig, data)
			else:
				_take_ice(_host_sig, pc, data)


func _client_take_offer(data: Dictionary) -> void:
	var assigned := int(data.get("assigned_id", 0))
	if assigned <= 1:
		_fail("Oda sahibiyle bağlantı kurulamadı. Tekrar dene.")
		return
	_conn.erase(_host_sig)
	# A relay retry (same-NAT fallback) re-offers: keep the adopted multiplayer peer, swap the
	# connection inside it.
	var reuse := _adopted and _rtc != null
	if not reuse:
		_rtc = WebRTCMultiplayerPeer.new()
		if _rtc.create_client(assigned) != OK:
			_fail("Oda sahibiyle bağlantı kurulamadı. Tekrar dene.")
			return
	elif _rtc.has_peer(1):
		_rtc.remove_peer(1)
	var pc := WebRTCPeerConnection.new()
	if pc.initialize({"iceServers": _ice}) != OK:
		_fail("Oda sahibiyle bağlantı kurulamadı. Tekrar dene.")
		return
	pc.session_description_created.connect(_on_sdp.bind(_host_sig))
	pc.ice_candidate_created.connect(_on_ice.bind(_host_sig))
	_conn[_host_sig] = pc
	_desc_ready[_host_sig] = true
	if _same_nat and not _relay_only:
		_lan_clock[_host_sig] = 0.0
	_rtc.add_peer(pc, 1)
	pc.set_remote_description(SIG_OFFER, String(data.get("sdp", "")))
	pc.poll()
	_flush_ice(_host_sig, pc)
	_webrtc_clock = 0.0
	if reuse:
		return
	if not _adopt(false):
		return
	progress.emit("Bağlantı kuruluyor…")


func _adopt(as_host: bool) -> bool:
	var net := get_node_or_null("/root/Net")
	if net == null or int(net.call("adopt", _rtc, as_host)) != OK:
		_fail("Oturum kurulamadı.")
		return false
	_adopted = true
	joined.emit(as_host)
	return true


func _apply_ice(raw: Variant) -> void:
	if typeof(raw) != TYPE_ARRAY or (raw as Array).is_empty():
		return
	var clean: Array = []
	var has_stun := false
	for entry in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var urls_raw = entry.get("urls", null)
		if urls_raw == null:
			continue
		var list: Array = urls_raw if typeof(urls_raw) == TYPE_ARRAY else [urls_raw]
		var kept: Array = []
		for u in list:
			var s := String(u).to_lower()
			if s.begins_with("turns:") or s.contains("transport=tcp") or s.contains("transport=tls"):
				continue
			if s.begins_with("stun:"):
				has_stun = true
			kept.append(u)
		if kept.is_empty():
			continue
		var item := {"urls": kept}
		if entry.has("username"):
			item["username"] = String(entry.get("username", ""))
		if entry.has("credential"):
			item["credential"] = String(entry.get("credential", ""))
		clean.append(item)
	if clean.is_empty():
		return
	if not has_stun:
		clean.push_front((FALLBACK_ICE[0] as Dictionary).duplicate(true))
	_ice = clean


func _ice_ok(sig: String, cand: String) -> bool:
	var only := _relay_only if not _as_host else bool(_relay_by_sig.get(sig, false))
	return true if not only else cand.contains(" typ relay")


func _queue_ice(sig: String, data: Dictionary) -> void:
	if not _ice_ok(sig, String(data.get("name", ""))):
		return
	if not _ice_queue.has(sig):
		_ice_queue[sig] = []
	var arr: Array = _ice_queue[sig]
	if arr.size() < 64:
		arr.append(data)


func _take_ice(sig: String, pc: WebRTCPeerConnection, data: Dictionary) -> void:
	if not _ice_ok(sig, String(data.get("name", ""))):
		return
	if not bool(_desc_ready.get(sig, false)):
		_queue_ice(sig, data)
		return
	pc.add_ice_candidate(String(data.get("media", "")), int(data.get("index", 0)), String(data.get("name", "")))
	pc.poll()


func _flush_ice(sig: String, pc: WebRTCPeerConnection) -> void:
	if pc == null or not _ice_queue.has(sig):
		return
	var queued: Array = _ice_queue[sig]
	_ice_queue.erase(sig)
	for data in queued:
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = data
		if not _ice_ok(sig, String(d.get("name", ""))):
			continue
		pc.add_ice_candidate(String(d.get("media", "")), int(d.get("index", 0)), String(d.get("name", "")))
	pc.poll()


func _send(msg: Dictionary) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.send_text(JSON.stringify(msg))


func _send_signal(to: String, data: Dictionary) -> void:
	_send({"type": "signal", "to": to, "data": data})


func _fail(reason: String, kind: String = "") -> void:
	stop()
	last_fail = kind
	failed.emit(reason)
