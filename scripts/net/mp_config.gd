extends RefCounted
## Multiplayer settings: the signaling relay (relay-main/server.js, WebRTC handshake only; game
## traffic goes peer to peer), the app key, room codes and the player's name.
##
## Override order for the relay: env UZAY_USE_LOCAL=1 (ws://127.0.0.1:8080), env
## UZAY_SIGNALING_URL / UZAY_RELAY_KEY, then user://relay.cfg ("url = ..." / "key = ..."), then the
## built-in production values below.
## Rooms on the wire are "UZAY-" + a 5-letter code (the same relay also serves another game, so the
## lobby list is filtered by that prefix).

const PROD_SIGNALING_URL := "wss://38-242-230-203.sslip.io"
const LOCAL_SIGNALING_URL := "ws://127.0.0.1:8080"
const RELAY_APP_KEY := "f58642a28d8542bfafe3cefc0f59297a5fa419f9db8725989dacf3e1abc016dc"
const KEY_FILE := "user://relay.cfg"
const PREFS_FILE := "user://uzay_mp.cfg"

const ROOM_PREFIX := "UZAY-"
## Room code: no look-alike characters (0 O 1 I L).
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const CODE_LEN := 5
const CODE_MIN := 4


static func use_local() -> bool:
	return OS.get_environment("UZAY_USE_LOCAL").strip_edges() == "1"


static func signaling_url() -> String:
	if use_local():
		return LOCAL_SIGNALING_URL
	var env := OS.get_environment("UZAY_SIGNALING_URL").strip_edges()
	if not env.is_empty():
		return env
	var from_file := _cfg("url")
	return from_file if not from_file.is_empty() else PROD_SIGNALING_URL


static func app_key() -> String:
	var env := OS.get_environment("UZAY_RELAY_KEY").strip_edges()
	if not env.is_empty():
		return env
	var from_file := _cfg("key")
	return from_file if not from_file.is_empty() else RELAY_APP_KEY


static func has_key() -> bool:
	return not app_key().is_empty()


static func _cfg(field: String) -> String:
	if not FileAccess.file_exists(KEY_FILE):
		return ""
	var f := FileAccess.open(KEY_FILE, FileAccess.READ)
	if f == null:
		return ""
	var out := ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		if line.substr(0, eq).strip_edges() == field:
			out = line.substr(eq + 1).strip_edges()
	f.close()
	return out


## The URL without the key (for logs).
static func safe_url() -> String:
	return "%s?key=***" % signaling_url() if has_key() else signaling_url()


# --- Room codes ------------------------------------------------------------------------------------

static func new_room_code() -> String:
	var crypto := Crypto.new()
	var n := CODE_ALPHABET.length()
	var limit := 256 - (256 % n)
	var out := ""
	while out.length() < CODE_LEN:
		for b in crypto.generate_random_bytes(16):
			if out.length() >= CODE_LEN:
				break
			if int(b) < limit:
				out += CODE_ALPHABET[int(b) % n]
	return out


## Upper case, prefix / dashes / spaces removed ("uzay-k7qx2" -> "K7QX2").
static func normalize_code(raw: String) -> String:
	var s := raw.strip_edges().to_upper()
	if s.begins_with(ROOM_PREFIX):
		s = s.substr(ROOM_PREFIX.length())
	var out := ""
	for ch in s:
		if ch == "-" or ch == " " or ch == "\t":
			continue
		out += ch
	return out


static func code_valid(code: String) -> bool:
	if code.length() < CODE_MIN or code.length() > CODE_LEN + 3:
		return false
	for ch in code:
		if not CODE_ALPHABET.contains(ch) and not "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(ch):
			return false
	return true


static func wire_room(code: String) -> String:
	return ROOM_PREFIX + normalize_code(code)


## The code of a wire room id, "" when it is not one of ours.
static func display_room(wire: String) -> String:
	return wire.substr(ROOM_PREFIX.length()) if wire.begins_with(ROOM_PREFIX) else ""


static func room_ok(code: String) -> bool:
	var re := RegEx.new()
	re.compile("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")
	return re.search(wire_room(code)) != null


static func connect_url(room: String, as_host: bool) -> String:
	var params := PackedStringArray()
	if has_key():
		params.append("key=%s" % app_key().uri_encode())
	params.append("room=%s" % room.uri_encode())
	params.append("role=%s" % ("host" if as_host else "client"))
	return "%s?%s" % [_with_path(signaling_url()), "&".join(params)]


static func lobby_url() -> String:
	var params := PackedStringArray()
	if has_key():
		params.append("key=%s" % app_key().uri_encode())
	params.append("role=lobby")
	return "%s?%s" % [_with_path(signaling_url()), "&".join(params)]


static func _with_path(url: String) -> String:
	var scheme := url.find("://")
	if scheme < 0:
		return url
	return url if url.substr(scheme + 3).contains("/") else url + "/"


# --- Player name -----------------------------------------------------------------------------------

static func player_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_FILE) == OK:
		var n := str(cfg.get_value("mp", "name", "")).strip_edges()
		if not n.is_empty():
			return n
	return "Astronot %d" % (100 + randi() % 900)


static func set_player_name(n: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_FILE)
	cfg.set_value("mp", "name", clean_name(n))
	cfg.save(PREFS_FILE)


static func clean_name(n: String) -> String:
	var s := n.strip_edges().replace("\n", " ").replace("\t", " ")
	if s.length() > 18:
		s = s.substr(0, 18)
	return s if not s.is_empty() else "Astronot"
