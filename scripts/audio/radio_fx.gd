extends Node
## Rival bot radio chatter (Game.sfx.radio, a child of scripts/audio/sfx.gd): short synthesized
## transmissions (no words) that give the bot team a voice.
##
## One transmission: the squelch-open click and the carrier-lock noise burst, an optional digital
## sync burst (FSK), carrier hiss (ducked under the voice: FM quieting) with sparse crackle, a garbled
## voice-like babble, then the key release and the classic squelch tail ("kşşş"). The babble is a
## source-filter voice: a Rosenberg glottal pulse (jitter, shimmer, breath) through three cascaded
## formant resonators gliding between Turkish-like vowels (front / back vowel harmony per word) and
## consonant loci, plosive bursts with aspiration, fricatives, nasals, a tapped r; phrase
## declination, word accents, a shouted variant (higher pitch, pressed voice, raised F1, faster).
## The radio chain: mic AGC (pumps between words), saturation (harder when shouting), sample-hold
## grit and a touch of ring modulation, a steep 300-3400 Hz band-pass (2 x 2 biquads), the small
## speaker's mid honk, multipath fading and the odd drop-out. Synthesized at Synth.SR (narrow band)
## on a WorkerThreadPool task when the first bot appears; kept in statics across scene reloads.
## Banks: "normal" (calm, 1.4-2.2 s), "contact" (tense), "urgent" (shouted), "short"
## (acknowledgements), "click" (a double squelch break, no voice). 12 transmissions.
##
## Events: bot_event(bot, kind) with kind "down" (killed: a nearby ally calls it), "hit", "grenade",
## "reload", "contact" (saw the player), "alert" (shot at / called to help), "intercept" (digging at
## our torpedo), "launch" (torpedo / Delici Top). Sources: one-line hooks in ai_rival.gd (host /
## single player: take_damage, _die, the reload in _shoot_update, _enter_combat, the Delici Top
## shot), RivalTeam.events().bot_action ("grenade", "torpedo_aim", "intercept"), and on a
## multiplayer client a WATCH_HZ look at the bot puppets (net_bot.gd: dead, hp, the throw clock,
## the held item), since the team only runs on the host.
## Throttle: one transmission at a time team-wide (+ GAP s), per-kind COOLDOWN and CHANCE, a per-bot
## cooldown, the best pending request (PRIORITY) waits up to PENDING_TTL s; after an "ally down"
## another bot nearby may answer (REPLY_CHANCE).
## Playback: 3D from the speaker's suit (RANGE_3D, started distance / 343 m/s late; host bots only
## with their voice token, tok_audio / Balance.AI_VOICE_MAX), and an intercepted copy in the
## player's helmet (2D, very quiet, through the extra band-limited "RadioRx" bus, also in vacuum:
## radio needs no air) when the speaker is within HELMET_RANGE or it is a kill. Every bot keeps its
## own voice (a pitch offset from its index). Local only.

const RX_BUS := "RadioRx"
const RANGE_3D := 26.0               # m: the suit speaker carries this far
const HELMET_RANGE := 12.0           # m: closer than this the helmet picks the transmission up
const ALLY_RANGE := 40.0             # m: who calls a death / answers it
const VOL_3D := -3.0                 # dB (suit speaker; urgent +2)
const VOL_HELMET := -20.0            # dB (intercepted in the helmet)
const VOL_HELMET_KILL := -15.0
const GAP := Vector2(0.7, 1.8)       # s of silence after a transmission
const BOT_COOLDOWN := 6.0            # s between two transmissions of one bot
const PENDING_TTL := 1.5             # s a request waits for the channel
const REPLY_CHANCE := 0.45
const WATCH_HZ := 4.0
const BANK_OF := {"down": "urgent", "grenade": "urgent", "hit": "contact", "contact": "contact",
		"alert": "short", "reload": "short", "intercept": "normal", "launch": "normal", "reply": "short",
		"pinned": "contact"}   # (pinned: ai_rival.gd suppression; its Turkish line: bot_cues.gd "pinned")
const COOLDOWN := {"down": 3.5, "grenade": 5.0, "hit": 6.0, "contact": 7.0, "alert": 9.0, "reload": 10.0,
		"intercept": 9.0, "launch": 9.0, "reply": 0.0, "pinned": 8.0}
const CHANCE := {"down": 1.0, "grenade": 0.85, "hit": 0.45, "contact": 0.75, "alert": 0.35, "reload": 0.3,
		"intercept": 1.0, "launch": 0.9, "reply": 1.0, "pinned": 0.8}
const PRIORITY := {"down": 6, "reply": 5, "grenade": 5, "intercept": 4, "launch": 4, "contact": 3, "hit": 2,
		"alert": 1, "reload": 1, "pinned": 3}
const TEAM_PATH := "res://scripts/war/rival_team.gd"

static var _bank := {}               # bank name -> Array[AudioStreamWAV]
static var _gen: Synth = null
static var _task := -1

var _rng := RandomNumberGenerator.new()
var _p3d: Array = []
var _p2d: AudioStreamPlayer = null
var _busy_until := 0                 # ms
var _last := {}                      # kind -> ms of its last transmission
var _bot_last := {}                  # bot instance id -> ms
var _last_pick := {}                 # bank -> index (no immediate repeats)
var _pending := {}                   # {"bot", "kind", "t", "pri"}
var _sched: Array = []               # [ms, player, bot] delayed 3D starts
var _follow: Array = []              # [player, bot]: the suit speaker moves with its bot
var _reply := {}                     # {"t", "pos", "from"}
var _hooked := false
var _hook_t := 0.0
var _watch_t := 0.0
var _pup := {}                       # client: puppet instance id -> last seen state


func _ready() -> void:
	_rng.randomize()
	_ensure_rx_bus()
	for i in 2:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 3.0
		p.max_distance = RANGE_3D + 4.0
		p.max_db = 0.0
		p.attenuation_filter_cutoff_hz = 6000.0
		add_child(p)
		_p3d.append(p)
	_p2d = AudioStreamPlayer.new()
	_p2d.bus = RX_BUS
	add_child(_p2d)


## A bot reports something (see the header). Throttled; silently dropped when not heard.
func bot_event(bot: Node, kind: String) -> void:
	if bot == null or not is_instance_valid(bot) or not BANK_OF.has(kind):
		return
	_ensure_synth()
	if _bank.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - int(_last.get(kind, -1000000)) < int(float(COOLDOWN[kind]) * 1000.0):
		return
	var speaker: Node3D = _speaker_for(bot, kind)
	var spk_id := speaker.get_instance_id() if speaker != null else bot.get_instance_id()
	if kind != "down" and kind != "reply" and now - int(_bot_last.get(spk_id, -1000000)) < int(BOT_COOLDOWN * 1000.0):
		return
	if _rng.randf() > float(CHANCE[kind]):
		return
	var h3 := _hears_3d(speaker)
	var hh := _hears_helmet(bot, speaker, kind)
	if not h3 and not hh:
		return
	if now < _busy_until:
		if _pending.is_empty() or int(PRIORITY[kind]) > int(_pending["pri"]):
			_pending = {"bot": bot, "kind": kind, "t": now, "pri": int(PRIORITY[kind])}
		return
	_transmit(bot, speaker, kind, h3, hh)


# =================================================================================================
# Who speaks, who hears
# =================================================================================================

## The voice of an event: the bot itself, or for a death the nearest living ally (prefer one with a
## voice token); null when nobody nearby can call it (the helmet may still hear the net).
func _speaker_for(bot: Node, kind: String) -> Node3D:
	if kind != "down":
		return bot as Node3D
	var best: Node3D = null
	var best_s := INF
	var at: Vector3 = (bot as Node3D).global_position
	for n in get_tree().get_nodes_in_group("war_ai"):
		if n == bot or not is_instance_valid(n) or _is_dead(n):
			continue
		var d: float = (n as Node3D).global_position.distance_to(at)
		if d > ALLY_RANGE:
			continue
		var s := d - (15.0 if n.get("tok_audio") == true else 0.0)
		if s < best_s:
			best_s = s
			best = n as Node3D
	return best


func _hears_3d(speaker: Node3D) -> bool:
	if speaker == null or not is_instance_valid(speaker) or _is_dead(speaker):
		return false
	if speaker.get("tok_audio") == false:        # a host bot without a voice token
		return false
	return speaker.global_position.distance_to(_listener()) < RANGE_3D


func _hears_helmet(bot: Node, speaker: Node3D, kind: String) -> bool:
	if speaker != null and is_instance_valid(speaker) and speaker.global_position.distance_to(_listener()) < HELMET_RANGE:
		return true
	if kind == "down":
		var d: float = (bot as Node3D).global_position.distance_to(_listener())
		return d < 80.0 or _rng.randf() < 0.6
	return false


func _listener() -> Vector3:
	var s = get_parent()
	if s != null and s.get("listener_pos") is Vector3:
		return s.listener_pos
	var cam := get_viewport().get_camera_3d()
	return cam.global_position if cam != null else Vector3.ZERO


static func _is_dead(n: Node) -> bool:
	if n.has_method("is_dead"):
		return bool(n.call("is_dead"))
	return n.get("dead") == true


## Every bot keeps its own voice: a pitch offset from its index (0.94-1.06).
static func _voice_pitch(n: Node) -> float:
	var i = n.get("index") if n != null else null
	var k := fposmod(float(i if i is int else 0) * 0.618034, 1.0)
	return 0.94 + k * 0.12


# =================================================================================================
# Playing
# =================================================================================================

## Plays one transmission now: h3 = from the speaker's suit (3D), hh = intercepted in the helmet.
func _transmit(bot: Node, speaker: Node3D, kind: String, h3: bool, hh: bool) -> void:
	var bank_name: String = BANK_OF[kind]
	if kind == "reload" and _rng.randf() < 0.45 and _bank.has("click"):
		bank_name = "click"
	var bank: Array = _bank.get(bank_name, [])
	if bank.is_empty():
		return
	var idx := _rng.randi() % bank.size()
	if bank.size() > 1 and idx == int(_last_pick.get(bank_name, -1)):
		idx = (idx + 1 + _rng.randi() % (bank.size() - 1)) % bank.size()
	_last_pick[bank_name] = idx
	var st: AudioStream = bank[idx]
	var voice_of: Node = speaker if speaker != null else bot
	var pitch := _voice_pitch(voice_of) * _rng.randf_range(0.99, 1.01)
	var dur := st.get_length() / pitch
	var now := Time.get_ticks_msec()
	_last[kind] = now
	_bot_last[voice_of.get_instance_id()] = now
	_busy_until = now + int((dur + _rng.randf_range(GAP.x, GAP.y)) * 1000.0)
	var urgent := bank_name == "urgent"
	if h3 and speaker != null and is_instance_valid(speaker):
		var p: AudioStreamPlayer3D = _free_3d()
		p.stream = st
		p.pitch_scale = pitch
		p.volume_db = VOL_3D + (2.0 if urgent else 0.0)
		var d: float = speaker.global_position.distance_to(_listener())
		_sched.append([now + int(d / 343.0 * 1000.0), p, speaker])
	if hh:
		_p2d.stream = st
		_p2d.pitch_scale = pitch
		_p2d.volume_db = VOL_HELMET_KILL if kind == "down" else VOL_HELMET
		_p2d.play()
	if kind == "down" and _rng.randf() < REPLY_CHANCE:
		var at: Vector3 = speaker.global_position if speaker != null else (bot as Node3D).global_position
		_reply = {"t": now + int((dur + _rng.randf_range(0.25, 0.6)) * 1000.0), "pos": at, "from": voice_of}
		_busy_until = now + int((dur + 0.15) * 1000.0)


func _free_3d() -> AudioStreamPlayer3D:
	for p in _p3d:
		if not (p as AudioStreamPlayer3D).playing:
			var busy := false
			for s in _sched:
				if s[1] == p:
					busy = true
					break
			if not busy:
				return p
	return _p3d[0]


static func _chest(n: Node3D) -> Vector3:
	return n.global_position + n.global_transform.basis.y * 1.35


func _process(delta: float) -> void:
	_poll_synth()
	_hook_events(delta)
	var now := Time.get_ticks_msec()
	# Delayed 3D starts (sound travels; the helmet copy is instant).
	if not _sched.is_empty():
		var keep: Array = []
		for s in _sched:
			if now < int(s[0]):
				keep.append(s)
				continue
			var p: AudioStreamPlayer3D = s[1]
			var b = s[2]
			if b == null or not is_instance_valid(b):
				continue
			p.global_position = _chest(b)
			p.play()
			var sfx = get_parent()
			if sfx != null and sfx.has_method("route_player"):
				sfx.route_player(p)
			_follow = _follow.filter(func(f): return f[0] != p)
			_follow.append([p, b])
		_sched = keep
	# The suit speaker walks with its bot.
	if not _follow.is_empty():
		var alive: Array = []
		for f in _follow:
			var p: AudioStreamPlayer3D = f[0]
			var b = f[1]
			if p.playing and b != null and is_instance_valid(b):
				p.global_position = _chest(b)
				alive.append(f)
		_follow = alive
	if now >= _busy_until:
		if not _reply.is_empty() and now >= int(_reply["t"]):
			var r := _reply
			_reply = {}
			var who := _replier(r["pos"], r["from"])
			if who != null:
				var w3 := _hears_3d(who)
				var wh := _hears_helmet(who, who, "reply")
				if w3 or wh:
					_transmit(who, who, "reply", w3, wh)
		elif _reply.is_empty() and not _pending.is_empty():
			var q := _pending
			_pending = {}
			var b = q["bot"]
			if now - int(q["t"]) < int(PENDING_TTL * 1000.0) and b != null and is_instance_valid(b):
				var pk: String = q["kind"]
				var spk: Node3D = _speaker_for(b, pk)
				var p3 := _hears_3d(spk)
				var ph := _hears_helmet(b, spk, pk)
				if p3 or ph:
					_transmit(b, spk, pk, p3, ph)
	if not _reply.is_empty() and now > int(_reply["t"]) + 2500:
		_reply = {}
	_watch_puppets(delta)


func _replier(at: Vector3, not_this) -> Node3D:
	var best: Node3D = null
	var best_d := ALLY_RANGE
	for n in get_tree().get_nodes_in_group("war_ai"):
		if n == not_this or not is_instance_valid(n) or _is_dead(n):
			continue
		var d: float = (n as Node3D).global_position.distance_to(at)
		if d < best_d:
			best_d = d
			best = n as Node3D
	return best


# =================================================================================================
# Event sources: RivalTeam.events() (host / single player) and the client's puppets
# =================================================================================================

func _hook_events(delta: float) -> void:
	if _hooked:
		return
	_hook_t -= delta
	if _hook_t > 0.0:
		return
	_hook_t = 1.0
	if not ResourceLoader.exists(TEAM_PATH):
		return
	var scr = load(TEAM_PATH)
	if not (scr is Script) or not (scr as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "events"):
		return
	var ev = scr.call("events")
	if ev == null:
		return
	if ev.has_signal("bot_action") and not ev.is_connected("bot_action", _on_bot_action):
		ev.connect("bot_action", _on_bot_action)
	_hooked = true


func _on_bot_action(i: int, what: String) -> void:
	var kind := ""
	match what:
		"grenade":
			kind = "grenade"
		"torpedo_aim":
			kind = "launch"
		"intercept":
			kind = "intercept"
	if kind == "":
		return
	for n in get_tree().get_nodes_in_group("war_ai"):
		if n.get("tok_audio") != null and n.get("index") == i:
			bot_event(n, kind)
			return


## Multiplayer client: the team (and its hooks) runs on the host; the puppets show what the bots do.
func _watch_puppets(delta: float) -> void:
	if not Net.active or Net.is_server:
		if not _pup.is_empty():
			_pup.clear()
		return
	_watch_t -= delta
	if _watch_t > 0.0:
		return
	_watch_t = 1.0 / WATCH_HZ
	var seen := {}
	for n in get_tree().get_nodes_in_group("war_ai"):
		if n.get("tok_audio") != null or not is_instance_valid(n):
			continue                         # a host-side bot reports through its hooks
		var hv = n.get("hp")
		if hv == null:
			continue
		var id := n.get_instance_id()
		var thr = n.get("_throw_t")
		var cur := {"dead": n.get("dead") == true, "hp": float(hv), "held": str(n.get("_held")),
				"thr": float(thr) if thr != null else -1.0}
		seen[id] = true
		var old: Dictionary = _pup.get(id, {})
		_pup[id] = cur
		if old.is_empty():
			continue
		if cur["dead"] and not old["dead"]:
			bot_event(n, "down")
		elif not cur["dead"]:
			if float(cur["hp"]) < float(old["hp"]) - 0.01:
				bot_event(n, "hit")
			if float(cur["thr"]) >= 0.0 and float(old["thr"]) < 0.0:
				bot_event(n, "grenade")
			if cur["held"] == "rifle" and old["held"] != "rifle":
				bot_event(n, "contact")
			elif cur["held"] == "wx_torpedo" and old["held"] != "wx_torpedo":
				bot_event(n, "launch")
	for id in _pup.keys():
		if not seen.has(id):
			_pup.erase(id)


# =================================================================================================
# Buses and the synthesis task
# =================================================================================================

## "RadioRx": the helmet's intercept receiver, thinner than the transmission (520-2600 Hz) with a
## little bit-crush on top.
static func _ensure_rx_bus() -> void:
	if AudioServer.get_bus_index(RX_BUS) >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, RX_BUS)
	AudioServer.set_bus_send(i, "Master")
	AudioServer.set_bus_volume_db(i, -1.0)
	var hp := AudioEffectHighPassFilter.new()
	hp.cutoff_hz = 520.0
	hp.db = AudioEffectFilter.FILTER_12DB
	AudioServer.add_bus_effect(i, hp)
	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = 2600.0
	lp.db = AudioEffectFilter.FILTER_12DB
	AudioServer.add_bus_effect(i, lp)
	var ds := AudioEffectDistortion.new()
	ds.mode = AudioEffectDistortion.MODE_LOFI
	ds.drive = 0.18
	ds.post_gain = -1.5
	ds.keep_hf_hz = 16000.0
	AudioServer.add_bus_effect(i, ds)


## Starts the synthesis once per run (the first bot event, or the first bot in the tree).
static func _ensure_synth() -> void:
	if not _bank.is_empty() or _task >= 0:
		return
	_gen = Synth.new()
	_task = WorkerThreadPool.add_task(_gen.build, false, "radio_fx")


static func _poll_synth() -> void:
	if _task < 0 or not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if _gen != null:
		_gen.mutex.lock()
		_bank = _gen.out
		_gen.mutex.unlock()
	_gen = null


func _physics_process(_delta: float) -> void:
	# Lazy start: synthesize as soon as bots exist (not in a match without them).
	if _bank.is_empty() and _task < 0 and Engine.get_physics_frames() % 60 == 0:
		if get_tree().get_first_node_in_group("war_ai") != null:
			_ensure_synth()


# =================================================================================================
# Synthesis (worker thread)
# =================================================================================================

class Synth extends RefCounted:
	const SR := 16000
	## Male vowel formants (Hz): F1, F2, F3, plus the vowel's loudness.
	const VOWELS := {"a": [730.0, 1190.0, 2440.0, 1.0], "e": [530.0, 1840.0, 2480.0, 0.92],
			"ı": [350.0, 1350.0, 2450.0, 0.78], "i": [290.0, 2250.0, 2950.0, 0.76],
			"o": [520.0, 880.0, 2400.0, 0.9], "ö": [440.0, 1600.0, 2350.0, 0.85],
			"u": [320.0, 850.0, 2300.0, 0.78], "ü": [300.0, 1650.0, 2200.0, 0.76]}
	const ONSETS := ["k", "k", "t", "t", "b", "d", "d", "s", "s", "y", "g", "m", "m", "n", "l", "ş", "h", "p",
			"v", "z", "ç"]
	const CODAS := ["r", "r", "n", "n", "l", "m", "k", "t", "s", "z", "ş"]

	var rng := RandomNumberGenerator.new()
	var mutex := Mutex.new()
	var out := {}

	func build() -> void:
		rng.seed = 7311
		var b := {}
		b["normal"] = [
			make({"words": 4, "f0": 112.0, "fs": 1.0, "rate": 1.0, "u": 0.0, "digital": true, "fade": 0.25}),
			make({"words": 5, "f0": 104.0, "fs": 0.96, "rate": 0.95, "u": 0.1, "fade": 0.1, "dropout": true}),
			make({"words": 4, "f0": 122.0, "fs": 1.04, "rate": 1.05, "u": 0.15, "fade": 0.35})]
		b["contact"] = [
			make({"words": 3, "f0": 132.0, "fs": 1.0, "rate": 1.12, "u": 0.45, "fade": 0.15}),
			make({"words": 2, "f0": 126.0, "fs": 0.95, "rate": 1.15, "u": 0.5, "digital": true}),
			make({"words": 3, "f0": 140.0, "fs": 1.05, "rate": 1.1, "u": 0.55, "fade": 0.2})]
		b["urgent"] = [
			make({"words": 2, "f0": 168.0, "fs": 1.0, "rate": 1.25, "u": 1.0}),
			make({"words": 3, "f0": 178.0, "fs": 0.97, "rate": 1.3, "u": 1.0, "dropout": true, "fade": 0.2}),
			make({"words": 2, "f0": 158.0, "fs": 1.04, "rate": 1.2, "u": 0.9})]
		b["short"] = [
			make({"words": 1, "syl": 2, "f0": 118.0, "fs": 0.98, "rate": 1.05, "u": 0.2}),
			make({"words": 1, "syl": 2, "f0": 128.0, "fs": 1.03, "rate": 1.1, "u": 0.3, "fade": 0.15})]
		b["click"] = [make({"voice": false, "keys": 2})]
		mutex.lock()
		out = b
		mutex.unlock()

	# --- one transmission ----------------------------------------------------------------------

	func make(p: Dictionary) -> AudioStreamWAV:
		var u: float = p.get("u", 0.0)
		var has_voice: bool = p.get("voice", true)
		var keys: int = p.get("keys", 1)
		var voice := PackedFloat32Array()
		if has_voice:
			voice = _radio(_norm(_voice(_plan(p), p), 0.5), p)
		# Timeline (s): per key [open, carrier start, voice start, tail start, tail end].
		var marks: Array = []
		var t := 0.0
		var dig_at := -1.0
		var dig_len := 0.0
		for k in keys:
			var open := rng.randf_range(0.035, 0.06)
			var c0 := t + open
			var v0 := -1.0
			var tail0: float
			if has_voice:
				var pre := rng.randf_range(0.07, 0.14)
				if p.get("digital", false):
					dig_at = c0 + 0.015
					dig_len = rng.randf_range(0.07, 0.1)
					pre += dig_len
				v0 = c0 + pre
				tail0 = v0 + float(voice.size()) / SR + rng.randf_range(0.05, 0.11)
			else:
				tail0 = c0 + rng.randf_range(0.09, 0.14)
			var tail_len := rng.randf_range(0.15, 0.26) * (1.0 - 0.3 * u) if has_voice else rng.randf_range(0.1, 0.14)
			marks.append([t, c0, v0, tail0, tail0 + tail_len])
			t = tail0 + tail_len + (rng.randf_range(0.12, 0.18) if k < keys - 1 else 0.0)
		var n := int((t + 0.02) * SR)
		# Voice envelope for the FM quieting of the hiss.
		var venv := PackedFloat32Array()
		venv.resize(voice.size())
		var e := 0.0
		var er := 1.0 - exp(-1.0 / (SR * 0.05))
		for i in voice.size():
			e += (absf(voice[i]) - e) * er
			venv[i] = e
		# Noise layer (pre-filter): click, carrier lock, hiss, crackle, digital burst, tail burst.
		var nz := PackedFloat32Array()
		nz.resize(n)
		var tail := PackedFloat32Array()
		tail.resize(n)
		var hiss: float = rng.randf_range(0.035, 0.055) * (1.4 if not has_voice else 1.0)
		for m in marks:
			var s0 := int(float(m[0]) * SR)
			var c0 := int(float(m[1]) * SR)
			var v0 := int(float(m[2]) * SR) if float(m[2]) >= 0.0 else -1
			var t0 := int(float(m[3]) * SR)
			var t1 := mini(int(float(m[4]) * SR), n)
			# Squelch-open click: an impulse pair and 2.5 ms of decaying noise.
			if s0 + 1 < n:
				nz[s0] += 0.95
				nz[s0 + 1] -= 0.55
			var ck := int(0.0025 * SR)
			for i in ck:
				if s0 + i < n:
					nz[s0 + i] += (rng.randf() * 2.0 - 1.0) * 0.5 * (1.0 - float(i) / ck)
			# Carrier lock: a burst that settles to the hiss.
			for i in range(s0, c0):
				var x := float(i - s0) / maxf(float(c0 - s0), 1.0)
				nz[i] += (rng.randf() * 2.0 - 1.0) * lerpf(0.42, hiss, x * x)
			# Carrier on: hiss, ducked while the voice is loud.
			for i in range(c0, t0):
				var duck := 1.0
				if v0 >= 0 and i >= v0 and i - v0 < venv.size():
					duck = 1.0 - 0.6 * clampf(venv[i - v0] / 0.2, 0.0, 1.0)
				nz[i] += (rng.randf() * 2.0 - 1.0) * hiss * duck
			# Crackle: sparse little static pops.
			var pops := int(float(t0 - c0) / SR * rng.randf_range(3.0, 8.0))
			for k in pops:
				var at := rng.randi_range(c0, maxi(c0, t0 - 40))
				var amp := rng.randf_range(0.08, 0.35)
				var ln := rng.randi_range(8, 40)
				for i in ln:
					if at + i < n:
						nz[at + i] += (rng.randf() * 2.0 - 1.0) * amp * (1.0 - float(i) / ln)
			# Key release -> squelch tail: a fast-rising noise burst, a slight sag, then a hard close.
			var tl := maxi(t1 - t0, 1)
			for i in range(t0, t1):
				var x := float(i - t0) / tl
				var env := minf(float(i - t0) / (0.002 * SR), 1.0) * lerpf(0.72, 0.48, x)
				env *= clampf(float(t1 - i) / (0.006 * SR), 0.0, 1.0)
				tail[i] = (rng.randf() * 2.0 - 1.0) * env
		# Digital sync burst: phase-continuous FSK 1200 / 2200 Hz.
		if dig_at >= 0.0:
			var d0 := int(dig_at * SR)
			var dn := int(dig_len * SR)
			var ph := 0.0
			var f := 1200.0
			var sw := 0
			for i in dn:
				if i >= sw:
					f = 2200.0 if f < 2000.0 else 1200.0
					sw = i + rng.randi_range(int(0.0008 * SR), int(0.0025 * SR))
				ph += f / SR
				var fe := minf(minf(float(i), float(dn - i)) / (0.003 * SR), 1.0)
				if d0 + i < n:
					nz[d0 + i] += sin(TAU * ph) * 0.2 * fe
		nz = _bq(nz, "hp", 350.0, 0.707)
		nz = _bq(nz, "lp", 3800.0, 0.707)
		nz = _bq(nz, "lp", 3800.0, 0.707)
		tail = _bq(tail, "hp", 420.0, 0.707)
		tail = _bq(tail, "lp", 4800.0, 0.707)
		# Mix: the voice at a fixed RMS, then a soft limit and the final level.
		var outb := PackedFloat32Array()
		outb.resize(n)
		var vg := 0.0
		if has_voice and voice.size() > 0:
			var acc := 0.0
			for x in voice:
				acc += x * x
			vg = 0.24 / maxf(sqrt(acc / voice.size()), 1e-4)
		var v0i := int(float(marks[0][2]) * SR) if has_voice else -1
		for i in n:
			var x := nz[i] + tail[i] * 0.85
			if v0i >= 0 and i >= v0i and i - v0i < voice.size():
				x += voice[i - v0i] * vg
			outb[i] = tanh(x * 1.2) / tanh(1.2)
		var fo := int(0.005 * SR)
		for i in fo:
			if n - 1 - i >= 0:
				outb[n - 1 - i] *= float(i) / fo
		return _wav(_norm(outb, 0.89))

	# --- the phrase plan -----------------------------------------------------------------------

	## Segments {d, f [F1 F2 F3], av voicing, an frication, fc / fq its band, ah aspiration, acc pitch
	## accent, tau formant glide, decay (bursts)}.
	func _plan(p: Dictionary) -> Array:
		var u: float = p.get("u", 0.0)
		var rate: float = p.get("rate", 1.0)
		var fs: float = p.get("fs", 1.0)
		var words: int = p.get("words", 3)
		var segs: Array = [_sil(0.02, [500.0, 1500.0, 2500.0])]
		if rng.randf() < 0.4:
			# A short breath in after keying up (the AGC lifts it, like on a real set).
			var bf: Array = [600.0 * fs, 1400.0 * fs, 2500.0 * fs]
			segs.append({"d": rng.randf_range(0.09, 0.14), "f": bf, "ah": 0.03, "tau": 0.03})
			segs.append(_sil(0.035, bf))
		for w in words:
			var front := rng.randf() < 0.5
			var nsyl: int = p.get("syl", rng.randi_range(1, 3 if u < 0.7 else 2))
			for s in nsyl:
				var acc := 1.0
				if s == 0:
					acc = 1.0 + lerpf(0.1, 0.24, u) * rng.randf_range(0.7, 1.2)
				if w == words - 1 and s == nsyl - 1:
					acc *= lerpf(0.9, 1.04, u)          # the final fall (a shout stays up)
				if rng.randf() < 0.85:
					_cons(segs, ONSETS[rng.randi() % ONSETS.size()], rate, fs, acc)
				var v := _vowel(front, s == 0)
				var vf: Array = VOWELS[v]
				var vd := rng.randf_range(0.075, 0.12) / rate * (1.25 if s == 0 else 1.0)
				segs.append({"d": vd, "f": [vf[0] * fs * (1.0 + 0.14 * u), vf[1] * fs, vf[2] * fs],
						"av": float(vf[3]) * lerpf(0.85, 1.0, u), "acc": acc, "tau": 0.025})
				if rng.randf() < 0.28:
					_cons(segs, CODAS[rng.randi() % CODAS.size()], rate, fs, acc)
			if w < words - 1:
				var r := rng.randf()
				var lf: Array = segs[segs.size() - 1]["f"]
				if r < 0.18:
					segs.append(_sil(rng.randf_range(0.12, 0.2) / rate, lf))
				elif r < 0.5:
					segs.append(_sil(rng.randf_range(0.03, 0.06), lf))
		segs.append(_sil(0.07, segs[segs.size() - 1]["f"]))
		return segs

	func _sil(d: float, f: Array) -> Dictionary:
		return {"d": d, "f": f, "tau": 0.04}

	## Vowel harmony: a word stays front (e i ö ü) or back (a ı o u); the rounded ones mostly in
	## the first syllable.
	func _vowel(front: bool, first: bool) -> String:
		var pool: Array
		if front:
			pool = ["e", "e", "i", "i", "ö", "ü"] if first else ["e", "e", "e", "i", "i"]
		else:
			pool = ["a", "a", "ı", "o", "u"] if first else ["a", "a", "a", "ı", "ı"]
		return pool[rng.randi() % pool.size()]

	## Appends a consonant as its sub-segments (closure, burst, aspiration / frication / murmur).
	func _cons(segs: Array, c: String, rate: float, fs: float, acc: float) -> void:
		var r := 1.0 / rate
		var prev: Array = segs[segs.size() - 1]["f"]
		var lf := func(a: float, b: float, c3: float) -> Array: return [a * fs, b * fs, c3 * fs]
		match c:
			"t", "k", "p", "ç":
				var loc: Array = lf.call(300.0, 1800.0, 2600.0)
				var bfc := 3600.0
				var bq := 1.1
				var ba := 0.55
				var asp := 0.022
				if c == "k":
					loc = lf.call(300.0, maxf(float(prev[1]) / fs, 1500.0) * 1.05, 2500.0)
					bfc = 2300.0
					bq = 1.4
					ba = 0.5
					asp = 0.03
				elif c == "p":
					loc = lf.call(300.0, 900.0, 2300.0)
					bfc = 1000.0
					bq = 0.9
					ba = 0.35
					asp = 0.018
				segs.append({"d": rng.randf_range(0.035, 0.05) * r, "f": loc, "tau": 0.02, "acc": acc})
				segs.append({"d": 0.012, "f": loc, "an": ba, "fc": bfc, "fq": bq, "decay": 0.004, "acc": acc})
				if c == "ç":
					segs.append({"d": 0.07 * r, "f": loc, "an": 0.4, "fc": 2800.0, "fq": 1.3, "acc": acc})
				else:
					segs.append({"d": asp * r, "f": loc, "ah": 0.22, "acc": acc})
			"d", "g", "b":
				var loc2: Array = lf.call(220.0, 1700.0, 2600.0)
				var bfc2 := 3300.0
				if c == "g":
					loc2 = lf.call(220.0, maxf(float(prev[1]) / fs, 1500.0), 2400.0)
					bfc2 = 2100.0
				elif c == "b":
					loc2 = lf.call(220.0, 900.0, 2200.0)
					bfc2 = 900.0
				segs.append({"d": rng.randf_range(0.028, 0.04) * r, "f": loc2, "av": 0.12, "tau": 0.02, "acc": acc})
				segs.append({"d": 0.008, "f": loc2, "av": 0.2, "an": 0.3, "fc": bfc2, "fq": 1.1, "decay": 0.003, "acc": acc})
			"s":
				segs.append({"d": 0.085 * r, "f": lf.call(300.0, 1700.0, 2700.0), "an": 0.32, "fc": 4300.0, "fq": 1.0, "acc": acc})
			"ş":
				segs.append({"d": 0.09 * r, "f": lf.call(300.0, 1900.0, 2500.0), "an": 0.42, "fc": 2700.0, "fq": 1.3, "acc": acc})
			"h":
				segs.append({"d": 0.055 * r, "f": prev, "ah": 0.28, "acc": acc})
			"z":
				segs.append({"d": 0.07 * r, "f": lf.call(250.0, 1700.0, 2600.0), "av": 0.35, "an": 0.18, "fc": 4300.0, "fq": 1.0, "acc": acc})
			"v":
				segs.append({"d": 0.05 * r, "f": lf.call(300.0, 1150.0, 2300.0), "av": 0.42, "an": 0.05, "fc": 2500.0, "fq": 0.7, "acc": acc})
			"m":
				segs.append({"d": 0.065 * r, "f": lf.call(260.0, 1000.0, 2200.0), "av": 0.38, "acc": acc, "tau": 0.015})
			"n":
				segs.append({"d": 0.055 * r, "f": lf.call(260.0, 1500.0, 2500.0), "av": 0.38, "acc": acc, "tau": 0.015})
			"l":
				segs.append({"d": 0.05 * r, "f": lf.call(360.0, 1250.0, 2700.0), "av": 0.55, "acc": acc})
			"y":
				segs.append({"d": 0.045 * r, "f": lf.call(280.0, 2200.0, 2900.0), "av": 0.6, "acc": acc})
			"r":
				var rf: Array = lf.call(420.0, 1300.0, 1650.0)
				segs.append({"d": 0.022 * r, "f": rf, "av": 0.5, "acc": acc, "tau": 0.012})
				segs.append({"d": 0.012 * r, "f": rf, "av": 0.16, "acc": acc, "tau": 0.012})
				segs.append({"d": 0.02 * r, "f": rf, "av": 0.45, "acc": acc, "tau": 0.012})

	# --- the voice -----------------------------------------------------------------------------

	## Source-filter synthesis of the plan: glottal pulse + breath -> F1 -> F2 -> F3 (Klatt
	## resonators, coefficients every 32 samples), plus the frication band-pass in parallel.
	func _voice(segs: Array, p: Dictionary) -> PackedFloat32Array:
		var total := 0.0
		for s in segs:
			total += float(s["d"])
		var n := int(total * SR) + 64
		var out := PackedFloat32Array()
		out.resize(n)
		var u: float = p.get("u", 0.0)
		var f0b: float = p.get("f0", 115.0)
		var oq := lerpf(0.62, 0.42, u)           # pressed (shouted) voice: shorter open phase, brighter
		var tp := oq * 0.7
		var breath := lerpf(0.035, 0.09, u)
		var jit := 0.012 + 0.01 * u
		var shim := 0.06
		var decl1 := lerpf(0.86, 0.97, u)
		var inv_sr := 1.0 / SR
		var f1 := 500.0
		var f2 := 1500.0
		var f3 := 2500.0
		var bw1 := 70.0
		var bw2 := 100.0
		var bw3 := 160.0
		var a1 := 0.0
		var b1 := 0.0
		var c1 := 0.0
		var a2 := 0.0
		var b2 := 0.0
		var c2 := 0.0
		var a3 := 0.0
		var b3 := 0.0
		var c3 := 0.0
		var y1a := 0.0
		var y1b := 0.0
		var y2a := 0.0
		var y2b := 0.0
		var y3a := 0.0
		var y3b := 0.0
		var fx1 := 0.0
		var fx2 := 0.0
		var fy1 := 0.0
		var fy2 := 0.0
		var av := 0.0
		var an := 0.0
		var ah := 0.0
		var acc := 1.0
		var ph := 0.0
		var gp := 0.0
		var pj := 1.0
		var ps := 1.0
		var f0 := f0b
		var ka := 1.0 - exp(-1.0 / (SR * 0.006))
		var i := 0
		for s in segs:
			var seg_n := int(float(s["d"]) * SR)
			var tf: Array = s["f"]
			var tf1: float = tf[0]
			var tf2: float = tf[1]
			var tf3: float = tf[2]
			var tav: float = s.get("av", 0.0)
			var tgn: float = s.get("an", 0.0)
			var tah: float = s.get("ah", 0.0)
			var tacc: float = s.get("acc", acc)
			var kf := 1.0 - exp(-32.0 / (SR * float(s.get("tau", 0.03))))
			var decay: float = s.get("decay", 0.0)
			var dk := exp(-1.0 / (SR * decay)) if decay > 0.0 else 1.0
			var benv := 1.0
			# The frication band-pass of this segment (constant 0 dB peak).
			var fc: float = minf(s.get("fc", 3000.0), SR * 0.45)
			var fq: float = s.get("fq", 1.0)
			var w0 := TAU * fc * inv_sr
			var al := sin(w0) / (2.0 * fq)
			var na0 := 1.0 + al
			var fb0 := al / na0
			var fa1 := -2.0 * cos(w0) / na0
			var fa2 := (1.0 - al) / na0
			for _j in seg_n:
				if i >= n:
					break
				if (i & 31) == 0:
					f1 += (tf1 - f1) * kf
					f2 += (tf2 - f2) * kf
					f3 += (tf3 - f3) * kf
					acc += (tacc - acc) * kf * 0.6
					c1 = -exp(-TAU * bw1 * inv_sr)
					b1 = 2.0 * exp(-PI * bw1 * inv_sr) * cos(TAU * f1 * inv_sr)
					a1 = 1.0 - b1 - c1
					c2 = -exp(-TAU * bw2 * inv_sr)
					b2 = 2.0 * exp(-PI * bw2 * inv_sr) * cos(TAU * f2 * inv_sr)
					a2 = 1.0 - b2 - c2
					c3 = -exp(-TAU * bw3 * inv_sr)
					b3 = 2.0 * exp(-PI * bw3 * inv_sr) * cos(TAU * minf(f3, SR * 0.45) * inv_sr)
					a3 = 1.0 - b3 - c3
					f0 = f0b * lerpf(1.08, decl1, float(i) / n) * acc
				av += (tav - av) * ka
				ah += (tah - ah) * ka
				var an_now: float
				if decay > 0.0:
					benv *= dk
					an_now = tgn * benv
					an = an_now
				else:
					an += (tgn - an) * ka
					an_now = an
				# Glottal flow (Rosenberg): opening, closing, closed; its derivative excites the tract.
				ph += f0 * pj * inv_sr
				if ph >= 1.0:
					ph -= 1.0
					pj = 1.0 + rng.randf_range(-jit, jit)
					ps = 1.0 + rng.randf_range(-shim, shim)
				var g := 0.0
				if ph < tp:
					g = 0.5 - 0.5 * cos(PI * ph / tp)
				elif ph < oq:
					g = cos(PI * 0.5 * (ph - tp) / (oq - tp))
				var dg := (g - gp) * (SR / f0) * 0.08
				gp = g
				var wn := rng.randf() * 2.0 - 1.0
				var src := dg * av * ps + wn * (ah + breath * g * av)
				var y1 := a1 * src + b1 * y1a + c1 * y1b
				y1b = y1a
				y1a = y1
				var y2 := a2 * y1 + b2 * y2a + c2 * y2b
				y2b = y2a
				y2a = y2
				var y3 := a3 * y2 + b3 * y3a + c3 * y3b
				y3b = y3a
				y3a = y3
				var fin := wn * an_now
				var fo := fb0 * fin - fb0 * fx2 - fa1 * fy1 - fa2 * fy2
				fx2 = fx1
				fx1 = fin
				fy2 = fy1
				fy1 = fo
				out[i] = y3 + fo
				i += 1
		return out

	# --- the radio chain -----------------------------------------------------------------------

	func _radio(v: PackedFloat32Array, p: Dictionary) -> PackedFloat32Array:
		var u: float = p.get("u", 0.0)
		var n := v.size()
		v = _bq(v, "hp", 140.0, 0.707)
		# Mic AGC: a fast attack, a slow release; pumps the breath up between words like a real set.
		var env := 0.0
		var att := 1.0 - exp(-1.0 / (SR * 0.004))
		var rel := 1.0 - exp(-1.0 / (SR * 0.14))
		for i in n:
			var a := absf(v[i])
			env += (a - env) * (att if a > env else rel)
			v[i] *= clampf(0.32 / maxf(env, 0.02), 0.0, 8.0)
		# Saturation (an overdriven mic / cheap amplifier): harder when shouting.
		var drive := lerpf(1.6, 3.6, u)
		var dn := 0.8 / tanh(drive)
		# Grit: sample-and-hold to half the rate, coarse steps, blended in; a touch of ring modulation.
		var mixc := lerpf(0.22, 0.35, u)
		var q := 1.0 / 90.0
		var rmf := rng.randf_range(380.0, 520.0)
		var rmd := lerpf(0.06, 0.12, u)
		var held := 0.0
		var rph := 0.0
		for i in n:
			var x := tanh(v[i] * drive) * dn
			if (i & 1) == 0:
				held = roundf(x / q) * q
			x = x * (1.0 - mixc) + held * mixc
			rph += rmf / SR
			v[i] = x * (1.0 - rmd) + x * sin(TAU * rph) * rmd
		# The radio band, steep, and the small speaker's honk.
		v = _bq(v, "hp", 300.0, 0.707)
		v = _bq(v, "hp", 300.0, 0.707)
		v = _bq(v, "lp", 3300.0, 0.707)
		v = _bq(v, "lp", 3300.0, 0.707)
		v = _bq(v, "peak", rng.randf_range(1700.0, 2300.0), 1.1, 4.5)
		# Multipath fading and drop-outs.
		var fd: float = p.get("fade", 0.0)
		var ff := rng.randf_range(1.5, 4.0)
		var fph := rng.randf() * TAU
		var drops: Array = []
		if p.get("dropout", false):
			for k in rng.randi_range(1, 2):
				var at := rng.randi_range(int(n * 0.25), int(n * 0.8))
				drops.append([at, at + rng.randi_range(int(0.025 * SR), int(0.06 * SR))])
		var ramp := 0.004 * SR
		if fd > 0.0 or not drops.is_empty():
			for i in n:
				var gn := 1.0
				if fd > 0.0:
					var lfo := 0.5 + 0.5 * sin(TAU * ff * float(i) / SR + fph)
					gn -= fd * lfo * lfo
				for dpair in drops:
					var a0: int = dpair[0]
					var a1: int = dpair[1]
					if i > a0 - ramp and i < a1 + ramp:
						var inside := minf(minf(float(i - a0 + ramp), float(a1 + ramp - i)) / ramp, 1.0)
						gn *= lerpf(1.0, 0.12, inside)
				v[i] *= gn
		return v

	# --- helpers -------------------------------------------------------------------------------

	## RBJ biquad in place: "lp", "hp", "bp", "peak" (gain_db).
	func _bq(x: PackedFloat32Array, kind: String, f: float, q: float, gain_db := 0.0) -> PackedFloat32Array:
		var w0 := TAU * minf(f, SR * 0.45) / SR
		var cw := cos(w0)
		var al := sin(w0) / (2.0 * q)
		var b0 := 0.0
		var b1 := 0.0
		var b2 := 0.0
		var a0 := 1.0 + al
		var a1 := -2.0 * cw
		var a2 := 1.0 - al
		match kind:
			"lp":
				b0 = (1.0 - cw) * 0.5
				b1 = 1.0 - cw
				b2 = b0
			"hp":
				b0 = (1.0 + cw) * 0.5
				b1 = -(1.0 + cw)
				b2 = b0
			"bp":
				b0 = al
				b2 = -al
			"peak":
				var A := pow(10.0, gain_db / 40.0)
				b0 = 1.0 + al * A
				b1 = -2.0 * cw
				b2 = 1.0 - al * A
				a0 = 1.0 + al / A
				a2 = 1.0 - al / A
		b0 /= a0
		b1 /= a0
		b2 /= a0
		a1 /= a0
		a2 /= a0
		var x1 := 0.0
		var x2 := 0.0
		var y1 := 0.0
		var y2 := 0.0
		for i in x.size():
			var xi := x[i]
			var yi := b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
			x2 = x1
			x1 = xi
			y2 = y1
			y1 = yi
			x[i] = yi
		return x

	func _norm(s: PackedFloat32Array, peak: float) -> PackedFloat32Array:
		var m := 0.0001
		for v in s:
			m = maxf(m, absf(v))
		var g := peak / m
		for i in s.size():
			s[i] *= g
		return s

	func _wav(s: PackedFloat32Array) -> AudioStreamWAV:
		var data := PackedByteArray()
		data.resize(s.size() * 2)
		for i in s.size():
			data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32000.0))
		var w := AudioStreamWAV.new()
		w.format = AudioStreamWAV.FORMAT_16_BITS
		w.mix_rate = SR
		w.stereo = false
		w.data = data
		return w
