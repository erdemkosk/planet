extends Node
## AI bot sync (child "Bots" of the Net autoload). The bots only think on the host (co-op; there
## are none in PvP). The client sees puppets (net_bot.gd).
##   Snapshots, host -> client, 10 Hz unreliable-ordered: u32 clock, u8 count, then per bot 15 bytes
##   (+6 while digging): index, flags (dead, aboard, crouch, air, jet, digging, light, repair), body /
##   role / held / shooting-skiff bits, body-local position as 3 int16 (step = PLANET_DISTANCE /
##   32767 ≈ 1 cm, read from bodies.gd), yaw on the local tangent frame (u16), aim pitch (s8), hp
##   (u8 of hp_max), ground speed (u8), suppression (u8 0..1), [dig point 3 int16]. Only bots that
##   moved / changed go out,
##   every bot at least once a second. 70 bots all moving: ~10 KB/s; typical a few hundred B/s.
##   Roster (reliable): index -> callsign on spawn / role change. Shots (unreliable): index + end
##   point, the puppet draws the tracer, flash and sound. Hits (unreliable): from, amount, impulse,
##   hit point. Hit reactions and the death launch (reliable, 8 / 12 B): see "Hit reactions" below.
## Ids for hit claims: ID_BASE + index.

const NetBot := preload("res://scripts/net/net_bot.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")

const ID_BASE := 100
const SEND_PERIOD := 0.1
const FULL_PERIOD := 1.0
const MAX_PER_MSG := 120

var _main: Node
var _t := 0.0
var _full_t := 0.0
var _last := {}                   # index -> PackedByteArray last sent (host)
var _roster := {}                 # index -> callsign (host: last sent)
var _puppets := {}                # index -> net_bot.gd (client)
var _host_bots := {}              # index -> ai_rival.gd (host)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func begin(main: Node) -> void:
	reset()
	_main = main
	_hook_events()


func reset() -> void:
	for k in _puppets:
		var p = _puppets[k]
		if p != null and is_instance_valid(p) and not p.is_queued_for_deletion():
			p.queue_free()
	_puppets.clear()
	_last.clear()
	_roster.clear()
	_host_bots.clear()
	_gren = null
	_warned.clear()
	_main = null


func on_peer_gone() -> void:
	_last.clear()
	_roster.clear()


static func quant() -> float:
	return 32767.0 / maxf(float(Bodies.PLANET_DISTANCE), 1.0)


func node_of(id: int) -> Node:
	var i := id - ID_BASE
	var b = _host_bots.get(i) if Net.is_server else _puppets.get(i)
	return b if b != null and is_instance_valid(b) else null


# =================================================================================================
# Host
# =================================================================================================

func _process(delta: float) -> void:
	if not Net.active or not Net.in_game or not Net.is_server:
		return
	_t += delta
	_full_t += delta
	if _t < SEND_PERIOD:
		return
	_t = 0.0
	var full := _full_t >= FULL_PERIOD
	if full:
		_full_t = 0.0
	_host_bots.clear()
	var roster: Array = []
	var bots: Array = get_tree().get_nodes_in_group("war_ai")
	for b in bots:
		if not is_instance_valid(b) or b.get("index") == null:
			continue
		var i := int(b.get("index"))
		_host_bots[i] = b
		if not b.has_meta("net_id"):
			b.set_meta("net_id", ID_BASE + i)
		var cs := str(b.get("callsign"))
		if _roster.get(i, "") != cs:
			_roster[i] = cs
			roster.append([i, cs, Net.abs_side(str(b.get("team")))])
	if not Net.live():
		return
	if not roster.is_empty():
		_rx_roster.rpc_id(Net.other_id, roster)
	var buf := PackedByteArray()
	buf.resize(5)
	buf.encode_u32(0, Time.get_ticks_msec())
	var n := 0
	for i in _host_bots:
		var e := _encode(_host_bots[i])
		if e.is_empty():
			continue
		if not full and _last.get(i) == e:
			continue
		_last[i] = e
		buf.append_array(e)
		n += 1
		if n >= MAX_PER_MSG:
			buf.encode_u8(4, n)
			_rx_snap.rpc_id(Net.other_id, buf)
			buf = PackedByteArray()
			buf.resize(5)
			buf.encode_u32(0, Time.get_ticks_msec())
			n = 0
	if n > 0:
		buf.encode_u8(4, n)
		_rx_snap.rpc_id(Net.other_id, buf)


## A host bot as 15 (or 21) bytes; [] when it has no planet.
func _encode(b: Node) -> PackedByteArray:
	var body: Node3D = b.get("body")
	if body == null or not is_instance_valid(body):
		return PackedByteArray()
	var q := quant()
	var pos: Vector3 = (b as Node3D).global_position
	var c := body.global_position
	var lp := pos - c
	var up := lp.normalized() if lp.length_squared() > 1e-6 else Vector3.UP
	var mode := int(b.get("mode"))
	var f1 := 0
	if mode == 3:
		f1 |= 1
	if mode == 2:
		f1 |= 2
	if float(b.get("_crouch_k")) > 0.5:
		f1 |= 4
	if bool(b.get("_air")) or bool(b.get("_climb")):
		f1 |= 8
	if float(b.get("_jet_t")) > 0.0 or bool(b.get("_climb")):
		f1 |= 16
	var digging := bool(b.call("is_digging")) if b.has_method("is_digging") else false
	if digging:
		f1 |= 32
	if bool(b.get("_light_on")):
		f1 |= 64
	if str(b.get("_job")) == "repair":
		f1 |= 128
	var held := str(b.get("_held"))
	var hcode := 1 if held == "terrain" else (2 if held == "rifle" else (3 if held == "wx_torpedo" else 0))
	var f2 := (Net.body_index(body) & 3) | ((clampi(int(b.get("role")), 0, 3)) << 2) | (hcode << 4)
	if bool(b.get("shooting_skiff")):
		f2 |= 64
	if digging:
		f2 |= 128
	var fwd: Vector3 = -(b as Node3D).global_transform.basis.z
	var fr := _frame(up)
	var yaw := atan2(fwd.dot(fr[1]), fwd.dot(fr[0]))
	var pitch := 0.0
	var tg = b.get("_target")
	if tg != null and is_instance_valid(tg) and (mode == 1 or str(b.get("_job")) == "raid_attack") and b.has_method("_aim_point"):
		var eye: Vector3 = pos + up * 1.5
		var d: Vector3 = ((b.call("_aim_point", tg) as Vector3) - eye).normalized()
		pitch = asin(clampf(d.dot(up), -1.0, 1.0))
	var vel: Vector3 = b.get("velocity") if b.get("velocity") is Vector3 else Vector3.ZERO
	var hs := (vel - up * vel.dot(up)).length()
	var e := PackedByteArray()
	e.resize(21 if digging else 15)
	e.encode_u8(0, int(b.get("index")) & 255)
	e.encode_u8(1, f1)
	e.encode_u8(2, f2)
	e.encode_s16(3, clampi(roundi(lp.x * q), -32767, 32767))
	e.encode_s16(5, clampi(roundi(lp.y * q), -32767, 32767))
	e.encode_s16(7, clampi(roundi(lp.z * q), -32767, 32767))
	e.encode_u16(9, int(fposmod(yaw, TAU) / TAU * 65535.0) & 0xFFFF)
	e.encode_s8(11, clampi(roundi(pitch * 80.0), -127, 127))
	e.encode_u8(12, clampi(int(float(b.get("hp")) / maxf(float(b.get("hp_max")), 1.0) * 255.0), 0, 255))
	e.encode_u8(13, clampi(int(hs * 10.0), 0, 255))
	# Byte 14: how suppressed it is (ai_rival.gd suppression() 0..1; the puppet hunches the same).
	var sup: float = float(b.call("suppression")) if b.has_method("suppression") else 0.0
	e.encode_u8(14, clampi(roundi(sup * 15.0), 0, 15) * 17)     # (16 steps: a decaying level does not resend every tick)
	if digging:
		var dp: Vector3 = (b.get("_dig_point") as Vector3) - c
		e.encode_s16(15, clampi(roundi(dp.x * q), -32767, 32767))
		e.encode_s16(17, clampi(roundi(dp.y * q), -32767, 32767))
		e.encode_s16(19, clampi(roundi(dp.z * q), -32767, 32767))
	return e


## Tangent frame on a sphere at `up` (same on both peers): [east, north].
static func _frame(up: Vector3) -> Array:
	var ref := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var e1 := up.cross(ref).normalized()
	return [e1, up.cross(e1).normalized()]


## ai_rival.gd _shoot_update (host): where the shot went.
func on_bot_shot(b: Node, end: Vector3) -> void:
	if Net.live():
		_rx_shot.rpc_id(Net.other_id, int(b.get("index")), end)


# =================================================================================================
# Client
# =================================================================================================

func build_roster() -> Array:
	var out: Array = []
	for b in get_tree().get_nodes_in_group("war_ai"):
		if is_instance_valid(b) and b.get("index") != null:
			out.append([int(b.get("index")), str(b.get("callsign")), Net.abs_side(str(b.get("team")))])
	_last.clear()
	_roster.clear()
	for r in out:
		_roster[int(r[0])] = str(r[1])
	return out


func apply_roster(list: Array) -> void:
	for r in list:
		if r is Array and (r as Array).size() >= 3:
			_puppet(int(r[0]), str(r[1]), int(r[2]))


@rpc("authority", "call_remote", "reliable")
func _rx_roster(list: Array) -> void:
	if Net.is_server or not Net.in_game:
		return
	apply_roster(list)


func _puppet(i: int, callsign: String, side: int) -> Node:
	var p = _puppets.get(i)
	if p != null and is_instance_valid(p):
		if callsign != "":
			p.set_callsign(callsign)
		return p
	if _main == null or not is_instance_valid(_main):
		return null
	p = NetBot.new()
	p.index = i
	p.team = Net.local_team(side)
	p.callsign = callsign if callsign != "" else "Rakip"
	p.set_meta("net_id", ID_BASE + i)
	_main.add_child(p)
	_puppets[i] = p
	return p


@rpc("authority", "call_remote", "unreliable_ordered")
func _rx_snap(buf: PackedByteArray) -> void:
	if Net.is_server or not Net.world_ready or buf.size() < 5:
		return
	var t := int(buf.decode_u32(0))
	var n := buf.decode_u8(4)
	var q := quant()
	var o := 5
	for k in n:
		if o + 15 > buf.size():
			break
		var i := buf.decode_u8(o)
		var f1 := buf.decode_u8(o + 1)
		var f2 := buf.decode_u8(o + 2)
		var bi := f2 & 3
		var body := Net.body_by_index(bi)
		var c: Vector3 = body.global_position if body != null else Vector3.ZERO
		var lp := Vector3(buf.decode_s16(o + 3), buf.decode_s16(o + 5), buf.decode_s16(o + 7)) / q
		var up := lp.normalized() if lp.length_squared() > 1e-6 else Vector3.UP
		var yaw := float(buf.decode_u16(o + 9)) / 65535.0 * TAU
		var fr := _frame(up)
		var fwd: Vector3 = (fr[0] as Vector3) * cos(yaw) + (fr[1] as Vector3) * sin(yaw)
		var s := {"t": t, "f1": f1, "role": (f2 >> 2) & 3, "held": (f2 >> 4) & 3, "skiff": (f2 & 64) != 0,
				"body": bi, "pos": c + lp, "up": up, "fwd": fwd, "pitch": float(buf.decode_s8(o + 11)) / 80.0,
				"hp": float(buf.decode_u8(o + 12)) / 255.0, "speed": float(buf.decode_u8(o + 13)) / 10.0,
				"sup": float(buf.decode_u8(o + 14)) / 255.0}
		o += 15
		if (f2 & 128) != 0:
			if o + 6 > buf.size():
				break
			s["dig"] = c + Vector3(buf.decode_s16(o), buf.decode_s16(o + 2), buf.decode_s16(o + 4)) / q
			o += 6
		var p := _puppet(i, "", 1)
		if p != null:
			p.push(s)


@rpc("authority", "call_remote", "unreliable")
func _rx_shot(i: int, end: Vector3) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var p = _puppets.get(i)
	if p != null and is_instance_valid(p):
		p.shot_fx(end)


## ai_rival.gd take_damage (host, alive): every hit with its impulse and point (Game.hit_pos, packed in
## the bot's frame). The puppet's flinch / stagger / knockdown come as bot_react (below); this only
## shoves a knocked-down puppet's ragdoll (hit_reactor.gd on_hit while down).
func on_bot_hit(b: Node, from_pos: Vector3, amount: float, impulse := Vector3.ZERO) -> void:
	if Net.live():
		_rx_hit.rpc_id(Net.other_id, int(b.get("index")), from_pos, amount, impulse, Net.world.pack_point(b, Game.hit_pos))


@rpc("authority", "call_remote", "unreliable")
func _rx_hit(i: int, from_pos: Vector3, amount: float, impulse: Vector3, point: int) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var p = _puppets.get(i)
	if p != null and is_instance_valid(p):
		p.hit_fx(from_pos, amount, impulse.limit_length(40.0), Net.world.unpack_point(p, point))


# =================================================================================================
# Hit reactions (ai_rival.gd "Hit reactions", scripts/player/hit_reactor.gd): every reaction of a host
# bot (RivalTeam.events().bot_react: flinch / stagger / knockdown / getup) and its death launch
# (on_bot_died: the whole corpse launch before the split, the part at its point) go to the client's
# puppet (net_bot.gd react -> net_react.gd). Reliable, PackedByteArray: index u8 + net_react.gd's 7
# bytes (kind, bone, dir 3 × s8, strength u16 at 0.01) + for "death" the host clock u32 (the puppet
# ignores older "alive" snapshots): 8 / 12 bytes.
# =================================================================================================

const NetReact := preload("res://scripts/net/net_react.gd")


func _on_bot_react(i: int, kind: String, dir: Vector3, strength: float, bone: String) -> void:
	if Net.is_server and Net.live():
		_send_react(i, kind, dir, strength, bone)


## ai_rival.gd _die (host): the corpse's launch v (whole, before hit_reactor.gd's split; a knocked-down
## body that goes on as the corpse: what was added to it) and its point (INF: none).
func on_bot_died(b: Node, v: Vector3, point: Vector3) -> void:
	if not Net.live():
		return
	var bone := ""
	var ast = b.get("astronaut")
	if point != Vector3.INF and ast != null and ast.has_method("part_at"):
		bone = str(ast.part_at(point))
	_send_react(int(b.get("index")), "death", v.normalized() if v.length_squared() > 1e-8 else Vector3.ZERO, v.length(), bone)


func _send_react(i: int, kind: String, dir: Vector3, strength: float, bone: String) -> void:
	var buf := PackedByteArray([i & 255])
	buf.append_array(NetReact.encode(kind, dir, strength, bone))
	if kind == "death":
		var o := buf.size()
		buf.resize(o + 4)
		buf.encode_u32(o, Time.get_ticks_msec())
	_rx_react.rpc_id(Net.other_id, buf)


@rpc("authority", "call_remote", "reliable")
func _rx_react(buf: PackedByteArray) -> void:
	if Net.is_server or not Net.world_ready or buf.size() < 1 + NetReact.SIZE:
		return
	var e := NetReact.decode(buf, 1)
	if e.is_empty():
		return
	var p = _puppets.get(buf.decode_u8(0))
	if p == null or not is_instance_valid(p):
		return
	var o := 1 + NetReact.SIZE
	var host_ms := int(buf.decode_u32(o)) if buf.size() >= o + 4 else -1
	p.react(str(e["kind"]), e["dir"], float(e["strength"]), str(e["bone"]), host_ms)


# =================================================================================================
# The bots' new weapons (RivalTeam.events(), scripts/war/rival_team.gd): grenade throws replayed on
# the client (a Projectiles node; the explosion there is the look, the host's grenade does the
# damage), the wind-up pose on the puppet (bot_action "grenade"), "Rakip torpidonu kazıyor!" when
# a bot starts digging after our torpedo, and the client's own "El bombası!" warning (a replayed
# bot grenade landing within AI_GRENADE_WARN_RANGE of our player).
# Bot torpedoes (Torpedo.events), the Delici Top (structure + BusterShell) and the interceptors'
# tracers (on_bot_shot) already sync through net_world.gd / above.
# =================================================================================================

const TEAM_PATH := "res://scripts/war/rival_team.gd"
const PROJ_PATH := "res://scripts/items/projectiles.gd"
var _events_hooked := false
var _gren: Node3D = null
var _warned := {}
var _warn_t := 0.0
var _last_interceptor := -1        # host: the bot of the last "intercept" action (sent with intercept_started)


func _hook_events() -> void:
	if _events_hooked or not ResourceLoader.exists(TEAM_PATH):
		return
	var scr = load(TEAM_PATH)
	if not (scr as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "events"):
		return
	var ev = scr.call("events")
	if ev == null:
		return
	if ev.has_signal("grenade_thrown"):
		ev.connect("grenade_thrown", _on_bot_grenade)
	if ev.has_signal("bot_action"):
		ev.connect("bot_action", _on_bot_action)
	if ev.has_signal("intercept_started"):
		ev.connect("intercept_started", _on_intercept)
	if ev.has_signal("bot_react"):
		ev.connect("bot_react", _on_bot_react)
	if ev.has_signal("bot_gesture"):
		ev.connect("bot_gesture", _on_bot_gesture)
	if ev.has_signal("bot_callout"):
		ev.connect("bot_callout", _on_bot_callout)
	if ev.has_signal("bot_alert"):
		ev.connect("bot_alert", _on_bot_alert)
	if ev.has_signal("bot_mood"):
		ev.connect("bot_mood", _on_bot_mood)
	_events_hooked = true


func _on_bot_grenade(pos: Vector3, vel: Vector3, fuse: float, cfg: Dictionary, team: String) -> void:
	if Net.is_server and Net.live():
		var c: Dictionary = cfg.duplicate()
		c.erase("ground")
		_rx_grenade.rpc_id(Net.other_id, pos, vel, fuse, c, Net.abs_side(team))


func _on_bot_action(i: int, what: String) -> void:
	if what == "intercept":
		_last_interceptor = i
	if Net.is_server and Net.live():
		_rx_action.rpc_id(Net.other_id, i, what)


func _on_intercept(t: Node3D) -> void:
	if Net.is_server and Net.live():
		var id := int(t.get("net_id")) if t != null and t.get("net_id") != null else 0
		_rx_intercept.rpc_id(Net.other_id, id, _last_interceptor)


@rpc("authority", "call_remote", "reliable")
func _rx_grenade(pos: Vector3, vel: Vector3, fuse: float, cfg: Dictionary, side: int) -> void:
	if Net.is_server or not Net.world_ready or _main == null or not is_instance_valid(_main):
		return
	if not ResourceLoader.exists(PROJ_PATH):
		return
	if _gren == null or not is_instance_valid(_gren):
		_gren = load(PROJ_PATH).new()
		_gren.name = "NetBotGrenades"
		_main.add_child(_gren)
	var c: Dictionary = cfg.duplicate()
	c["team"] = Net.local_team(side)
	c["player_owned"] = false
	c["direct"] = 0.0
	c["damage"] = clampf(float(c.get("damage", 0.0)), 0.0, 400.0)
	c["radius"] = clampf(float(c.get("radius", 4.0)), 0.5, 20.0)
	c["crater"] = clampf(float(c.get("crater", 0.0)), 0.0, 8.0)
	_gren.call("launch", pos, vel.limit_length(80.0), "hand", 1, clampf(fuse, 0.05, 10.0), c)


@rpc("authority", "call_remote", "reliable")
func _rx_action(i: int, what: String) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var p = _puppets.get(i)
	if p != null and is_instance_valid(p):
		p.action(what)


@rpc("authority", "call_remote", "reliable")
func _rx_intercept(_torp_id: int, bot_index: int) -> void:
	if Net.is_server or not Net.world_ready:
		return
	if Game.hud:
		Game.hud.show_message("Rakip torpidonu kazıyor!", 2.5)
	_radio(bot_index, "intercept")


## Client: "El bombası!" when a replayed bot grenade lands (first bounce / at rest) close to us.
func _physics_process(delta: float) -> void:
	if Net.is_server or not Net.in_game or _gren == null or not is_instance_valid(_gren):
		return
	_warn_t -= delta
	if _warn_t > 0.0:
		return
	_warn_t = 0.1
	var list = _gren.get("_list")
	if not (list is Array) or (list as Array).is_empty():
		if not _warned.is_empty():
			_warned.clear()
		return
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or pl.is_dead() or Game.hud == null:
		return
	var rng := float(load("res://scripts/war/balance.gd").get_script_constant_map().get("AI_GRENADE_WARN_RANGE", 8.0))
	var pp: Vector3 = (pl as Node3D).global_position
	for g in list:
		var n = g.get("node")
		if not is_instance_valid(n):
			continue
		var id: int = (n as Node3D).get_instance_id()
		if _warned.has(id) or (int(g.get("bounces", 0)) == 0 and not bool(g.get("rest", false))):
			continue
		if (n as Node3D).global_position.distance_to(pp) < rng:
			_warned[id] = true
			Game.hud.show_message("El bombası!", 1.6)


## Client: a radio callout from a bot puppet (scripts/audio/radio_fx.gd bot_event; the team and its
## hooks only run on the host). The puppet watcher there covers deaths, hits, grenades and launches.
func _radio(i: int, kind: String) -> void:
	var p = _puppets.get(i)
	if p == null or not is_instance_valid(p) or Game.sfx == null or not is_instance_valid(Game.sfx):
		return
	var r = Game.sfx.get("radio")
	if r != null and is_instance_valid(r) and r.has_method("bot_event"):
		r.bot_event(p, kind)


# =================================================================================================
# NPC reactions (ai_rival.gd "Reactions and body language", RivalTeam.events(), rival bots on the
# host): mirrored on the client's puppets (net_bot.gd cue_*), the text and "!" through
# scripts/war/bot_cues.gd (loaded at use time).
#   gesture  unreliable_ordered  PackedByteArray: index u8, dir 3 × s8 (/127, the bot's local space),
#                                kind ASCII ("look" = astronaut.look_dir 3 s, else astronaut.gesture)
#   cue      reliable            PackedByteArray: index u8, type u8 (0 callout: variant u8, arg s32,
#                                line ASCII · 1 alert: kind ASCII "seen" / "marked" · 2 mood: wound,
#                                hunch u8 in tenths, as the host emits them on change)
# Mood is forwarded rather than derived on the client: the host's hunch is combat-only and reads its
# own suppression memory (_bl_suppression), which the snapshot's 16-step byte does not reproduce.
# Sanity caps (cosmetic, dropped past them): CUE_RATE gestures and CUE_RATE callouts / alerts a
# second for the whole team; moods always go (on change only).
# =================================================================================================

const CUES_PATH := "res://scripts/war/bot_cues.gd"
const CUE_RATE := 24
var _cue_sec := -1
var _cue_n := 0
var _gest_n := 0


func _cue_ok(gesture: bool) -> bool:
	if not Net.is_server or not Net.live():
		return false
	var s := Time.get_ticks_msec() / 1000
	if s != _cue_sec:
		_cue_sec = s
		_cue_n = 0
		_gest_n = 0
	if gesture:
		_gest_n += 1
		return _gest_n <= CUE_RATE
	_cue_n += 1
	return _cue_n <= CUE_RATE


func _on_bot_gesture(i: int, kind: String, dir: Vector3) -> void:
	if not _cue_ok(true):
		return
	var d := dir.normalized() if dir.length_squared() > 1e-8 else Vector3.FORWARD
	var buf := PackedByteArray([i & 255, 0, 0, 0])
	buf.encode_s8(1, clampi(roundi(d.x * 127.0), -127, 127))
	buf.encode_s8(2, clampi(roundi(d.y * 127.0), -127, 127))
	buf.encode_s8(3, clampi(roundi(d.z * 127.0), -127, 127))
	buf.append_array(kind.left(24).to_ascii_buffer())
	_rx_gesture.rpc_id(Net.other_id, buf)


func _on_bot_callout(i: int, line: String, variant: int, arg: int) -> void:
	if not _cue_ok(false):
		return
	var buf := PackedByteArray([i & 255, 0, clampi(variant, 0, 255), 0, 0, 0, 0])
	buf.encode_s32(3, arg)
	buf.append_array(line.left(24).to_ascii_buffer())
	_rx_cue.rpc_id(Net.other_id, buf)


func _on_bot_alert(i: int, kind: String) -> void:
	if not _cue_ok(false):
		return
	var buf := PackedByteArray([i & 255, 1])
	buf.append_array(kind.left(16).to_ascii_buffer())
	_rx_cue.rpc_id(Net.other_id, buf)


func _on_bot_mood(i: int, wound: float, hunch: float) -> void:
	if Net.is_server and Net.live():
		_rx_cue.rpc_id(Net.other_id, PackedByteArray([i & 255, 2, clampi(roundi(wound * 10.0), 0, 10),
				clampi(roundi(hunch * 10.0), 0, 10)]))


@rpc("authority", "call_remote", "unreliable_ordered")
func _rx_gesture(buf: PackedByteArray) -> void:
	if Net.is_server or not Net.world_ready or buf.size() < 5:
		return
	var p = _puppets.get(buf.decode_u8(0))
	if p == null or not is_instance_valid(p):
		return
	var d := Vector3(buf.decode_s8(1), buf.decode_s8(2), buf.decode_s8(3)) / 127.0
	p.cue_gesture(buf.slice(4).get_string_from_ascii(), d)


@rpc("authority", "call_remote", "reliable")
func _rx_cue(buf: PackedByteArray) -> void:
	if Net.is_server or not Net.world_ready or buf.size() < 3:
		return
	var p = _puppets.get(buf.decode_u8(0))
	if p == null or not is_instance_valid(p):
		return
	match buf.decode_u8(1):
		0:
			if buf.size() < 8:
				return
			var line := buf.slice(7).get_string_from_ascii()
			var cues = load(CUES_PATH)
			if p.cue_say(line, buf.decode_u8(2), buf.decode_s32(3)):      # (false: an unknown line)
				var rk := str(cues.call("radio_kind", line))
				if rk != "":
					_radio(buf.decode_u8(0), rk)
		1:
			var kind := buf.slice(2).get_string_from_ascii()
			if kind == "seen" or kind == "marked":
				p.cue_alert(kind)
		2:
			if buf.size() >= 4:
				p.cue_mood(float(buf.decode_u8(2)) / 10.0, float(buf.decode_u8(3)) / 10.0)
