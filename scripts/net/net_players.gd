extends Node
## Player sync (child "Players" of the Net autoload).
##   Out (each peer, 20 Hz unreliable-ordered, ~42-58 bytes): its own player's state: sender clock,
##     flags (floor, jet, dead, ragdoll, in vehicle, lamp, using, drilling), body, body-local
##     position (f32), rotation (4 halves), velocity (3 halves), aim pitch, hp, jet power, vehicle
##     net id + seat, and while drilling the dig point, normal, mode and brush radius.
##   Events (reliable): held item (icon + tool colour + the gun's attachments {slot: id}) on change,
##     every shot (origin, direction, icon, suppressed), respawn, hit reactions (7 B, net_react.gd); host -> client: hurt (amount, from, impulse,
##     new hp, hit point) and a 1 Hz hp sync; client -> host: self damage (falls, crashes: the host
##     owns the client's hp).
## The other player is a remote_avatar.gd in the scene (created on its first state).

const RemoteAvatar := preload("res://scripts/net/remote_avatar.gd")
const SEND_PERIOD := 0.05
const ATT_PATH := "res://scripts/items/attachments.gd"   # (load()ed lazily: see clean_att)
const HP_SYNC_PERIOD := 1.0

var avatar: Node3D = null

var _send_t := 0.0
var _hp_t := 0.0
var _held := ""
var _held_col := Color.BLACK
var _held_att := {}
var _rx_emitting := false
var _main: Node
var _was_dead := false
var _proj: Node3D = null           # replays the other player's grenades (scripts/items/projectiles.gd)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Game.shot_fired.connect(_on_local_shot)


func begin(main: Node) -> void:
	_main = main
	avatar = null
	_held = ""
	_was_dead = false
	_proj = null
	var pl = Game.player
	if pl != null and is_instance_valid(pl):
		_connect_items(pl)
		if pl.has_signal("melee_swung") and not pl.is_connected("melee_swung", _on_melee):
			pl.connect("melee_swung", _on_melee)
		if pl.has_signal("hit_reacted") and not pl.is_connected("hit_reacted", _on_hit_reacted):
			pl.connect("hit_reacted", _on_hit_reacted)
		if pl.has_signal("mantled") and not pl.is_connected("mantled", _on_mantled):
			pl.connect("mantled", _on_mantled)
		var ha = pl.get("hand_action")
		if ha != null and ha.has_signal("grenade_thrown") and not ha.grenade_thrown.is_connected(_on_grenade):
			ha.grenade_thrown.connect(_on_grenade)


func reset() -> void:
	if avatar != null and is_instance_valid(avatar) and not avatar.is_queued_for_deletion():
		avatar.queue_free()
	avatar = null
	_held = ""
	_main = null


func on_peer_gone() -> void:
	reset_avatar()


func reset_avatar() -> void:
	if avatar != null and is_instance_valid(avatar):
		avatar.queue_free()
	avatar = null
	_held = ""


func _ensure_avatar() -> Node3D:
	if avatar != null and is_instance_valid(avatar):
		return avatar
	if _main == null or not is_instance_valid(_main) or not Net.in_game:
		return null
	avatar = RemoteAvatar.new()
	var side := Net.other_side() if Net.is_server else 0
	avatar.setup(Net.other_name, side)
	_main.add_child(avatar)
	_held = ""                 # resend ours so the other side's new avatar holds the right thing
	return avatar


# =================================================================================================
# Out
# =================================================================================================

func _physics_process(delta: float) -> void:
	if not Net.live():
		return
	var pl = Game.player
	if pl == null or not is_instance_valid(pl):
		return
	_send_t += delta
	if _send_t >= SEND_PERIOD:
		_send_t = 0.0
		_rx_state.rpc_id(Net.other_id, _encode(pl))
		_send_held(pl)
	if Net.is_server:
		_hp_t += delta
		if _hp_t >= HP_SYNC_PERIOD and avatar != null and is_instance_valid(avatar):
			_hp_t = 0.0
			_rx_hp.rpc_id(Net.other_id, avatar.hp)
	else:
		var dead: bool = pl.is_dead()
		if _was_dead and not dead:
			_rx_respawned.rpc_id(1)
		_was_dead = dead
		_shield_tick()


func _send_held(pl) -> void:
	var icon := ""
	var col := Color(1.0, 0.55, 0.15)
	var it = pl.current() if pl.has_method("current") else null
	if it != null and not pl.is_ragdolled() and pl.vehicle == null:
		icon = str(it.get("icon"))
	var tool = pl.get("tool")
	if tool != null:
		var mc: Array = tool.MODE_COLORS
		col = mc[clampi(int(tool.get("work_mode")), 0, mc.size() - 1)]
	# The held gun's fitted attachments ({slot: id}, scripts/items/attachments.gd) ride along: the
	# other side dresses its third-person prop (Attachments.dress_tp).
	var att := {}
	if it != null and icon != "" and it.has_method("get_attachments"):
		var a = it.call("get_attachments")
		if a is Dictionary:
			att = a
	if icon != _held or not col.is_equal_approx(_held_col) or att != _held_att:
		_held = icon
		_held_col = col
		_held_att = att.duplicate()
		_rx_held.rpc_id(Net.other_id, icon, col, att)


## A gun's attachments as received ({slot: id}, the held-item sync / a weapon drop's state["att"]):
## only the known slots, ids that exist (Attachments.def), sit in that slot and fit gun `item_id`.
## (attachments.gd is loaded here, at use time: never preloaded by this autoload's scripts.)
func clean_att(item_id: String, d) -> Dictionary:
	var out := {}
	if not (d is Dictionary) or (d as Dictionary).is_empty() or not ResourceLoader.exists(ATT_PATH):
		return out
	var A = load(ATT_PATH)
	for k in (d as Dictionary).keys():
		var slot := str(k)
		var id := str((d as Dictionary)[k])
		if not (slot in ["muzzle", "optic", "under"]) or id == "" or out.has(slot):
			continue
		var df = A.call("def", id)
		if not (df is Dictionary) or (df as Dictionary).is_empty() or str((df as Dictionary).get("slot", "")) != slot:
			continue
		if not bool(A.call("compatible", id, item_id)):
			continue
		out[slot] = id
	return out


func _encode(pl) -> PackedByteArray:
	var flags := 0
	var rag: bool = pl.is_ragdolled()
	var pos: Vector3 = pl.global_position
	var vel: Vector3 = pl.velocity
	if rag and pl.has_method("hud_velocity"):
		vel = pl.hud_velocity()
	if pl.is_on_floor():
		flags |= RemoteAvatar.F_FLOOR
	if pl.jetting:
		flags |= RemoteAvatar.F_JET
	if pl.is_dead():
		flags |= RemoteAvatar.F_DEAD
	if rag:
		flags |= RemoteAvatar.F_RAG
	var veh_id := 0
	var seat := 0
	if pl.vehicle != null and is_instance_valid(pl.vehicle):
		flags |= RemoteAvatar.F_VEHICLE
		var v: Node = pl.vehicle
		if v.has_meta("net_seat_of"):
			veh_id = Net.world.id_of(v.get_meta("net_seat_of"))
			seat = 1
		else:
			veh_id = Net.world.id_of(v)
	if pl.lamp_on():
		flags |= RemoteAvatar.F_LAMP
	var it = pl.current()
	var using: bool = it != null and bool(it.get("using"))
	if using:
		flags |= RemoteAvatar.F_USING
	var tool = pl.tool
	var digging: bool = using and it == tool and bool(tool.get("aim_valid"))
	var dig_p := Vector3.ZERO
	if digging:
		flags |= RemoteAvatar.F_DIG
	var body: Node3D = Game.dominant_body(pos)
	var bi := Net.body_index(body)
	var bpos: Vector3 = body.global_position if body != null else Vector3.ZERO
	var buf := PackedByteArray()
	buf.resize(58 if digging else 42)
	buf.encode_u32(0, Time.get_ticks_msec())
	buf.encode_u8(4, flags)
	buf.encode_u8(5, bi)
	var lp := pos - bpos
	buf.encode_float(6, lp.x)
	buf.encode_float(10, lp.y)
	buf.encode_float(14, lp.z)
	var q: Quaternion = pl.global_transform.basis.orthonormalized().get_rotation_quaternion()
	buf.encode_half(18, q.x)
	buf.encode_half(20, q.y)
	buf.encode_half(22, q.z)
	buf.encode_half(24, q.w)
	buf.encode_half(26, vel.x)
	buf.encode_half(28, vel.y)
	buf.encode_half(30, vel.z)
	buf.encode_half(32, float(pl.get("_pitch")))
	buf.encode_u8(34, clampi(int(ceilf(float(pl.hp))), 0, 255))
	buf.encode_u8(35, clampi(int(pl.jet_effect() * 255.0), 0, 255))
	buf.encode_u16(36, veh_id)
	buf.encode_u8(38, seat)
	buf.encode_u8(39, clampi(int(float(pl.get("crouch_k") if pl.get("crouch_k") != null else 0.0) * 255.0), 0, 255))
	buf.encode_u8(40, clampi(int(float(pl.get("slide_k") if pl.get("slide_k") != null else 0.0) * 255.0), 0, 255))
	var glint = it.get("glint") if it != null else null
	buf.encode_u8(41, clampi(int(float(glint) * 255.0), 0, 255) if glint != null else 0)
	if digging:
		dig_p = _dig_point(pl, tool)
		var n: Vector3 = _dig_normal(pl, dig_p)
		var ldp := dig_p - bpos
		buf.encode_float(42, ldp.x)
		buf.encode_float(46, ldp.y)
		buf.encode_float(50, ldp.z)
		buf.encode_s8(54, clampi(int(n.x * 127.0), -127, 127))
		buf.encode_s8(55, clampi(int(n.y * 127.0), -127, 127))
		buf.encode_s8(56, clampi(int(n.z * 127.0), -127, 127))
		buf.encode_u8(57, (clampi(int(tool.get("work_mode")), 0, 3) << 6) | clampi(int(float(tool.get("radius")) * 10.0), 0, 63))
	return buf


## Where the drill beam lands (same ray as terrain_tool.gd).
func _dig_point(pl, tool) -> Vector3:
	var cam: Camera3D = pl.camera
	var from: Vector3 = pl.aim_origin()
	var dir := -cam.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * float(tool.RANGE), Game.LAYER_TERRAIN)
	var hit: Dictionary = pl.get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"] if not hit.is_empty() else from + dir * 3.0


func _dig_normal(pl, p: Vector3) -> Vector3:
	var b: Node3D = Game.dominant_body(p)
	if b != null:
		return (p - b.global_position).normalized()
	return pl.global_transform.basis.y


static func decode(buf: PackedByteArray) -> Dictionary:
	if buf.size() < 42:
		return {}
	var bi := buf.decode_u8(5)
	var body := Net.body_by_index(bi)
	var bpos: Vector3 = body.global_position if body != null else Vector3.ZERO
	var q := Quaternion(buf.decode_half(18), buf.decode_half(20), buf.decode_half(22), buf.decode_half(24))
	if q.length_squared() < 0.01:
		q = Quaternion.IDENTITY
	var s := {"t": int(buf.decode_u32(0)), "flags": buf.decode_u8(4), "body": bi,
			"pos": bpos + Vector3(buf.decode_float(6), buf.decode_float(10), buf.decode_float(14)),
			"rot": q.normalized(),
			"vel": Vector3(buf.decode_half(26), buf.decode_half(28), buf.decode_half(30)),
			"pitch": buf.decode_half(32), "hp": float(buf.decode_u8(34)), "jet": buf.decode_u8(35) / 255.0,
			"veh": buf.decode_u16(36), "seat": buf.decode_u8(38), "crouch": buf.decode_u8(39) / 255.0,
			"slide": buf.decode_u8(40) / 255.0, "glint": buf.decode_u8(41) / 255.0}
	if buf.size() >= 58:
		var mr := buf.decode_u8(57)
		s["dig_p"] = bpos + Vector3(buf.decode_float(42), buf.decode_float(46), buf.decode_float(50))
		s["dig_n"] = Vector3(buf.decode_s8(54), buf.decode_s8(55), buf.decode_s8(56)).normalized()
		s["dig_mode"] = mr >> 6
		s["dig_r"] = float(mr & 63) / 10.0
	return s


func _on_local_shot(from: Vector3, dir: Vector3, team: String) -> void:
	# Only our own player's guns (team "home"): bot shots go via net_bots.gd, remote ones are ours.
	if _rx_emitting or team != "home" or not Net.live():
		return
	var pl = Game.player
	var icon := ""
	var sup := false
	if pl != null and is_instance_valid(pl) and pl.has_method("current") and pl.current() != null:
		var it = pl.current()
		icon = str(it.get("icon"))
		var kit = it.get("att_kit")
		if kit != null and kit.has_method("suppressed"):
			sup = bool(kit.call("suppressed"))
	_rx_shot.rpc_id(Net.other_id, from, dir, icon, sup)


# =================================================================================================
# In
# =================================================================================================

func _sender_ok() -> bool:
	return Net.active and Net.in_game and multiplayer.get_remote_sender_id() == Net.other_id


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rx_state(buf: PackedByteArray) -> void:
	if not _sender_ok() or not Net.live():
		return
	var s := decode(buf)
	if s.is_empty():
		return
	var av := _ensure_avatar()
	if av != null:
		av.push_state(s)


@rpc("any_peer", "call_remote", "reliable")
func _rx_held(icon: String, col: Color, att: Dictionary) -> void:
	if not _sender_ok():
		return
	var av := _ensure_avatar()
	if av != null:
		av.set_held(icon, col, clean_att(icon, att))


## sup: the shooter's gun wears a suppressor (att_kit.suppressed()): the avatar's report is quiet and
## flashless. (Game.shot_fired carries no loudness: the bots and hit_feel.gd treat a local suppressed
## shot the same way, so the replay matches it.)
@rpc("any_peer", "call_remote", "reliable")
func _rx_shot(from: Vector3, dir: Vector3, icon: String, sup: bool) -> void:
	if not _sender_ok() or not Net.live():
		return
	var av := _ensure_avatar()
	if av != null:
		av.shot_fx(from, dir.normalized(), icon, sup)
	# The bots hear the other player's shots (ai_rival.gd), and an enemy's bullets whizz past us
	# (hit_feel.gd near misses): Game.shot_fired with the shooter's local team.
	if icon in RemoteAvatar.NO_BULLET:
		return
	var side := Net.other_side() if Net.is_server else 0
	_rx_emitting = true
	Game.shot_fired.emit(from, dir.normalized(), Net.local_team(side))
	_rx_emitting = false


## Host: the hp mirror changed (remote_avatar.gd take_damage). point: the hit point packed in the
## avatar's frame (net_world.gd pack_point, -1 = none).
func send_hurt(amount: float, from_pos: Vector3, impulse: Vector3, new_hp: float, point := -1) -> void:
	if Net.is_server and Net.other_id != 0 and Net.welcomed:
		_rx_hurt.rpc_id(Net.other_id, amount, from_pos, impulse, new_hp, point)


## Client: the host's hit on us; our take_damage sees its point as Game.hit_pos (hit reactions).
@rpc("authority", "call_remote", "reliable")
func _rx_hurt(amount: float, from_pos: Vector3, impulse: Vector3, new_hp: float, point: int) -> void:
	if Net.is_server or not Net.in_game:
		return
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("net_hurt"):
		var prev: Vector3 = Game.hit_pos
		Game.hit_pos = Net.world.unpack_point(pl, point)
		pl.net_hurt(amount, from_pos, impulse, new_hp)
		Game.hit_pos = prev


# -------------------------------------------------------------------------------------------------
# Relic Kalkan (scripts/war/cache_buffs.gd "shield") of the CLIENT's player. The host decides the
# bots' hits on the client (remote_avatar.gd take_damage), so it keeps a mirror of the shield:
#   client -> host  shield {left}   whenever CacheBuffs.shield_left() moved (start, a local absorb, end)
#   host -> client  shield_hit {n}  the mirror ate n of a host hit -> the client's absorb(n) (its
#                                   flash / chime / bar, the buff ends at 0)
# -------------------------------------------------------------------------------------------------

const BUFFS_PATH := "res://scripts/war/cache_buffs.gd"
var _shield_sent := 0.0


## Client: the shield left, sent when it changed (checked every physics frame: a static read).
func _shield_tick() -> void:
	if not ResourceLoader.exists(BUFFS_PATH):
		return
	var s := float(load(BUFFS_PATH).call("shield_left"))
	if absf(s - _shield_sent) > 0.25 or (s <= 0.0 and _shield_sent > 0.0):
		_shield_sent = s
		_rx_shield.rpc_id(1, s)


@rpc("any_peer", "call_remote", "reliable")
func _rx_shield(left: float) -> void:
	if not Net.is_server or not _sender_ok() or avatar == null or not is_instance_valid(avatar):
		return
	avatar.set("shield", clampf(left, 0.0, 1000.0) if is_finite(left) else 0.0)


## Host: remote_avatar.gd take_damage let the mirror absorb n.
func send_shield_hit(n: float) -> void:
	if Net.is_server and Net.other_id != 0 and Net.welcomed:
		_rx_shield_hit.rpc_id(Net.other_id, n)


@rpc("authority", "call_remote", "reliable")
func _rx_shield_hit(n: float) -> void:
	if Net.is_server or not Net.in_game:
		return
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and (pl as Object).has_meta("dmg_absorb"):
		var ab = (pl as Object).get_meta("dmg_absorb")
		if ab != null and is_instance_valid(ab) and ab.has_method("absorb"):
			ab.call("absorb", maxf(n, 0.0))
	_shield_sent = float(load(BUFFS_PATH).call("shield_left")) if ResourceLoader.exists(BUFFS_PATH) else 0.0


@rpc("authority", "call_remote", "unreliable")
func _rx_hp(new_hp: float) -> void:
	if Net.is_server or not Net.in_game:
		return
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and not pl.is_dead() and absf(float(pl.hp) - new_hp) > 1.0:
		pl.hp = clampf(new_hp, 1.0, float(pl.hp_max))


## Client: damage our own body caused (hard landings, crashes, the skiff eject): the host decides.
func claim_self_damage(amount: float, from_pos: Vector3, impulse: Vector3) -> void:
	if Net.is_client() and Net.live():
		_rx_self_damage.rpc_id(1, amount, from_pos, impulse)


@rpc("any_peer", "call_remote", "reliable")
func _rx_self_damage(amount: float, from_pos: Vector3, impulse: Vector3) -> void:
	if not Net.is_server or not _sender_ok():
		return
	var av := _ensure_avatar()
	if av != null:
		av.take_damage(clampf(amount, 0.0, 500.0), from_pos, impulse, true)      # (own: past the hull)


@rpc("any_peer", "call_remote", "reliable")
func _rx_respawned() -> void:
	if not Net.is_server or not _sender_ok():
		return
	var av := _ensure_avatar()
	if av != null:
		av.mirror_respawn()


# =================================================================================================
# Snapshot (late join)
# =================================================================================================

func build_snapshot() -> Dictionary:
	var d := {}
	if avatar != null and is_instance_valid(avatar):
		d["client_hp"] = avatar.hp
	return d


func apply_snapshot(d: Dictionary) -> void:
	var pl = Game.player
	if d.has("client_hp") and pl != null and is_instance_valid(pl):
		pl.hp = clampf(float(d["client_hp"]), 1.0, float(pl.hp_max))
	_held = ""


# =================================================================================================
# Grenades (hand_action.gd grenade_thrown): each side replays the other's throw. On the client the
# replay (and its own grenade) only shows; on the host the client's grenade is the real one.
# =================================================================================================

func _on_grenade(pos: Vector3, vel: Vector3, fuse: float, cfg: Dictionary) -> void:
	if not Net.live():
		return
	var c: Dictionary = cfg.duplicate()
	c.erase("ground")
	_rx_grenade.rpc_id(Net.other_id, pos, vel, fuse, c, Net.my_side())


@rpc("any_peer", "call_remote", "reliable")
func _rx_grenade(pos: Vector3, vel: Vector3, fuse: float, cfg: Dictionary, side: int) -> void:
	if not _sender_ok() or not Net.live() or _main == null or not is_instance_valid(_main):
		return
	if _proj == null or not is_instance_valid(_proj):
		_proj = load("res://scripts/items/projectiles.gd").new()
		_proj.name = "NetGrenades"
		_main.add_child(_proj)
	var av := _ensure_avatar()
	_proj.set("player", av.get("_col") if av != null else null)
	var c: Dictionary = cfg.duplicate()
	c["team"] = Net.local_team(side)
	c["player_owned"] = false
	c["damage"] = clampf(float(c.get("damage", 0.0)), 0.0, 400.0)
	c["radius"] = clampf(float(c.get("radius", 4.0)), 0.5, 20.0)
	c["crater"] = clampf(float(c.get("crater", 0.0)), 0.0, 8.0)
	c["direct"] = clampf(float(c.get("direct", 0.0)), 0.0, 200.0)
	_proj.call("launch", pos, vel.limit_length(80.0), "hand", 1, clampf(fuse, 0.05, 10.0), c)


# =================================================================================================
# Rockets (rocket_launcher.gd rocket_launched) and the Kinetik İtici (kinetic_pusher.gd
# pusher_fired): each side replays the other's shot. A rocket replay on the client only shows (no
# direct hit, explosion.gd skips the damage); on the host it is the real one. The pusher's replay
# on the host damages, flings bots, ragdolls players and deflects projectiles; on a client it is the
# look only.
# =================================================================================================

const ROCKETS_PATH := "res://scripts/items/rockets.gd"
const PUSHER_PATH := "res://scripts/items/kinetic_pusher.gd"
var _rockets: Node3D = null


func _connect_items(pl) -> void:
	var items = pl.get("items")
	if not (items is Array):
		return
	for it in items:
		if it == null or not is_instance_valid(it):
			continue
		if it.has_signal("rocket_launched") and not it.is_connected("rocket_launched", _on_rocket):
			it.connect("rocket_launched", _on_rocket)
		if it.has_signal("pusher_fired") and not it.is_connected("pusher_fired", _on_pusher):
			it.connect("pusher_fired", _on_pusher)
		if it.has_signal("rail_fired") and not it.is_connected("rail_fired", _on_rail):
			it.connect("rail_fired", _on_rail)
		if it.has_signal("plasma_beam") and not it.is_connected("plasma_beam", _on_plasma):   # Plazma Kesici (section below)
			it.connect("plasma_beam", _on_plasma)
		if it.has_signal("dirt_fired") and not it.is_connected("dirt_fired", _on_dirt):   # Toprak Topu (section below)
			it.connect("dirt_fired", _on_dirt)
		if it.has_signal("mortar_fired") and not it.is_connected("mortar_fired", _on_mortar):   # Havan (section below)
			it.connect("mortar_fired", _on_mortar)


## The railgun (railgun.gd rail_fired: muzzle, where the beam ended, charge 0..1): the other side
## draws the beam (rail_beam.gd replay; on the host it also bores the soil, synced as digs). The hit
## itself went through Game.damage_target (a client's: a claim). Reliable.
func _on_rail(from: Vector3, to: Vector3, charge: float) -> void:
	if Net.live():
		_rx_rail.rpc_id(Net.other_id, from, to, charge, Net.my_side())


@rpc("any_peer", "call_remote", "reliable")
func _rx_rail(from: Vector3, to: Vector3, charge: float, side: int) -> void:
	if not _sender_ok() or not Net.live() or _main == null or not is_instance_valid(_main):
		return
	if not from.is_finite() or not to.is_finite():
		return
	var av := _ensure_avatar()
	var d := to - from
	if av != null and d.length_squared() > 1e-4:
		av.shot_fx(from, d.normalized(), "rail")      # (NO_BULLET: the flash / use pose only)
	load("res://scripts/items/rail_beam.gd").call("replay", _main, from, to, clampf(charge, 0.0, 1.0), Net.local_team(side))
	# The bots hear it and it cracks past us (hit_feel.gd): like a bullet's Game.shot_fired.
	if d.length_squared() > 1e-4:
		_rx_emitting = true
		Game.shot_fired.emit(from, d.normalized(), Net.local_team(side))
		_rx_emitting = false


func _on_rocket(pos: Vector3, vel: Vector3, cfg: Dictionary) -> void:
	if Net.live():
		_rx_rocket.rpc_id(Net.other_id, pos, vel, cfg, Net.my_side())


@rpc("any_peer", "call_remote", "reliable")
func _rx_rocket(pos: Vector3, vel: Vector3, cfg: Dictionary, side: int) -> void:
	if not _sender_ok() or not Net.live() or _main == null or not is_instance_valid(_main):
		return
	if not ResourceLoader.exists(ROCKETS_PATH):
		return
	if _rockets == null or not is_instance_valid(_rockets):
		_rockets = load(ROCKETS_PATH).new()
		_rockets.name = "NetRockets"
		_main.add_child(_rockets)
	var av := _ensure_avatar()
	var c := {}
	for k in ["radius", "damage", "impulse", "crater", "self_mult", "direct"]:
		if cfg.has(k):
			c[k] = float(cfg[k])
	c["radius"] = clampf(float(c.get("radius", 5.0)), 0.5, 20.0)
	c["damage"] = clampf(float(c.get("damage", 0.0)), 0.0, 400.0)
	c["crater"] = clampf(float(c.get("crater", 0.0)), 0.0, 8.0)
	c["direct"] = clampf(float(c.get("direct", 0.0)), 0.0, 300.0)
	c["impulse"] = clampf(float(c.get("impulse", 0.0)), 0.0, 60.0)
	c["player_owned"] = false
	var ex: Array = []
	var col = av.get("_col") if av != null else null
	if col is CollisionObject3D:
		ex.append((col as CollisionObject3D).get_rid())
	if av != null:
		av.shot_fx(pos, vel.normalized(), "rocket")
	_rockets.call("launch", pos, vel.limit_length(160.0), Net.local_team(side), c, ex, av)


func _on_pusher(from: Vector3, dir: Vector3, cfg: Dictionary) -> void:
	if Net.live():
		_rx_pusher.rpc_id(Net.other_id, from, dir, cfg, Net.my_side())


@rpc("any_peer", "call_remote", "reliable")
func _rx_pusher(from: Vector3, dir: Vector3, cfg: Dictionary, side: int) -> void:
	if not _sender_ok() or not Net.live() or _main == null or not is_instance_valid(_main):
		return
	if not ResourceLoader.exists(PUSHER_PATH):
		return
	var av := _ensure_avatar()
	var shooter = av.get("_col") if av != null else null
	load(PUSHER_PATH).call("replay", _main, from, dir, cfg, Net.local_team(side), shooter)


## Host: the other player was knocked over (remote_avatar.gd ragdoll).
func send_knock(impulse: Vector3, duration: float) -> void:
	if Net.is_server and Net.live():
		_rx_knock.rpc_id(Net.other_id, impulse, duration)


@rpc("authority", "call_remote", "reliable")
func _rx_knock(impulse: Vector3, duration: float) -> void:
	if Net.is_server or not Net.in_game:
		return
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.vehicle == null and not pl.is_dead():
		pl.ragdoll(impulse.limit_length(40.0), clampf(duration, 0.5, 6.0))


# =================================================================================================
# Dipçik (player.melee_swung): the swing's look on the other screen. The strike is a hit claim
# (Game.damage_target) like any other.
# =================================================================================================

func _on_melee(from: Vector3, dir: Vector3) -> void:
	if Net.live():
		_rx_melee.rpc_id(Net.other_id, from, dir)


@rpc("any_peer", "call_remote", "reliable")
func _rx_melee(_from: Vector3, dir: Vector3) -> void:
	if not _sender_ok() or not Net.live():
		return
	var av := _ensure_avatar()
	if av != null:
		av.melee_fx(dir)


## Mantling (player.mantled(from, to, height), scripts/player/mantle.gd): the other screen's avatar
## plays a climb pose over its replicated movement (the path itself comes with the 20 Hz state).
func _on_mantled(_from: Vector3, _to: Vector3, height: float) -> void:
	if Net.live():
		_rx_mantle.rpc_id(Net.other_id, height)


@rpc("any_peer", "call_remote", "reliable")
func _rx_mantle(height: float) -> void:
	if not _sender_ok() or not Net.live() or not is_finite(height):
		return
	var av := _ensure_avatar()
	if av != null:
		av.mantle_fx(clampf(height, 0.0, 3.0))


# =================================================================================================
# Hit reactions (player.hit_reacted, scripts/player/hit_reactor.gd PlayerFeel): each side's own body
# reacts on its own machine (hits reach it through net_hurt / the host's take_damage); the other
# screen's avatar repeats it (remote_avatar.gd react_event -> net_react.gd): flinch at the struck part,
# stagger pose, knockdown / death ragdoll with the hit-located launch, the get-up. 7 bytes, reliable.
# =================================================================================================

const NetReact := preload("res://scripts/net/net_react.gd")


func _on_hit_reacted(kind: String, dir: Vector3, strength: float, bone: String) -> void:
	if Net.live():
		_rx_react.rpc_id(Net.other_id, NetReact.encode(kind, dir, strength, bone))


@rpc("any_peer", "call_remote", "reliable")
func _rx_react(buf: PackedByteArray) -> void:
	if not _sender_ok() or not Net.live():
		return
	var e := NetReact.decode(buf)
	if e.is_empty():
		return
	var av := _ensure_avatar()
	if av != null:
		av.react_event(str(e["kind"]), e["dir"], float(e["strength"]), str(e["bone"]))


# =================================================================================================
# Plazma Kesici (plasma_cutter.gd plasma_beam(state, from, to, surf, heat)): while the beam or the
# Kesme Düzlemi sweep runs the cutter emits ~12 Hz (state 1 beam / 2 sweep) and once 0 when it
# stops. Sent body-local (28 B + a session byte): the beams unreliable-ordered, the stop reliable; a
# late beam packet of a session already stopped is dropped. The other side drives one remote
# plasma_beam.gd from the avatar's third-person muzzle (its cut end eased toward the received point;
# it goes out by itself 0.4 s after the last packet). The cutting itself travels as terrain ops
# (net_terrain.gd) and the burn as damage claims, like every other gun; the bots on this side hear
# the beam (Game.shot_fired, at most 4 a second).
# =================================================================================================

const PLASMA_BEAM_PATH := "res://scripts/items/plasma_beam.gd"
var _plasma_fx: Node3D = null
var _plasma_session := 0           # out: current beam session (0..255)
var _plasma_on := false
var _plasma_dead := -1             # in: the session last stopped
var _plasma_noise_ms := 0


func _on_plasma(state: int, from: Vector3, to: Vector3, surf: int, heat: float) -> void:
	if not Net.live():
		return
	if state > 0 and not _plasma_on:
		_plasma_session = (_plasma_session + 1) % 256
	_plasma_on = state > 0
	var body: Node3D = Game.dominant_body(to)
	var bpos: Vector3 = body.global_position if body != null else Vector3.ZERO
	var buf := PackedByteArray()
	buf.resize(29)
	buf.encode_u8(0, clampi(state, 0, 2))
	buf.encode_u8(1, Net.body_index(body))
	var lf := from - bpos
	var lt := to - bpos
	buf.encode_float(2, lf.x)
	buf.encode_float(6, lf.y)
	buf.encode_float(10, lf.z)
	buf.encode_float(14, lt.x)
	buf.encode_float(18, lt.y)
	buf.encode_float(22, lt.z)
	buf.encode_u8(26, clampi(surf, 0, 3))
	buf.encode_u8(27, clampi(int(heat * 255.0), 0, 255))
	buf.encode_u8(28, _plasma_session)
	if state > 0:
		_rx_plasma.rpc_id(Net.other_id, buf)
	else:
		_rx_plasma_off.rpc_id(Net.other_id, buf)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rx_plasma(buf: PackedByteArray) -> void:
	_plasma_in(buf)


@rpc("any_peer", "call_remote", "reliable")
func _rx_plasma_off(buf: PackedByteArray) -> void:
	_plasma_in(buf)


func _plasma_in(buf: PackedByteArray) -> void:
	if not _sender_ok() or not Net.live() or buf.size() < 29 or _main == null or not is_instance_valid(_main):
		return
	var state := buf.decode_u8(0)
	var session := buf.decode_u8(28)
	if state == 0:
		_plasma_dead = session
	elif session == _plasma_dead:
		return                         # (a beam packet that arrived after its own stop)
	var body := Net.body_by_index(buf.decode_u8(1))
	var bpos: Vector3 = body.global_position if body != null else Vector3.ZERO
	var from := bpos + Vector3(buf.decode_float(2), buf.decode_float(6), buf.decode_float(10))
	var to := bpos + Vector3(buf.decode_float(14), buf.decode_float(18), buf.decode_float(22))
	if not from.is_finite() or not to.is_finite() or from.distance_to(to) > 40.0:
		return
	if _plasma_fx == null or not is_instance_valid(_plasma_fx) or _plasma_fx.get_parent() != _main:
		if state == 0:
			return
		_plasma_fx = load(PLASMA_BEAM_PATH).call("make", _main, true)
	var av := _ensure_avatar()
	if av != null:
		var ast = av.get("astronaut")
		if ast != null and ast.has_method("held_tip"):
			_plasma_fx.set("tip", ast.held_tip("plasma"))
	_plasma_fx.call("net_update", state, from, to, buf.decode_u8(26), buf.decode_u8(27) / 255.0)
	# The bots hear it like gunfire (ai_rival.gd), a few times a second.
	var now := Time.get_ticks_msec()
	if state > 0 and now - _plasma_noise_ms >= 250:
		_plasma_noise_ms = now
		var d := to - from
		if d.length_squared() > 1e-4:
			var side := Net.other_side() if Net.is_server else 0
			_rx_emitting = true
			Game.shot_fired.emit(from, d.normalized(), Net.local_team(side))
			_rx_emitting = false


# =================================================================================================
# Toprak Topu (dirt_launcher.gd dirt_fired(pos, vel, kind) + dirt_glob.gd burials): each side
# replays the other's glob, the look only (the arc, the clods, the splat; its mound / wall arrive
# as the shooter's brushes through net_terrain.gd, its hits as damage claims). Burials are decided
# by the shooter's machine: a client claims a body here (claim_dirt_bury -> the host buries it with
# DirtGlob.execute_bury -> CaveIn.bury); the host's own glob buries directly, the client's body
# through cave_in.gd's `buried` event (its transport). The terrain ops are flushed first, so the soil
# collar is there before the body is held in it. Reliable.
# =================================================================================================

const DIRT_GLOB_PATH := "res://scripts/items/dirt_glob.gd"
const _DIRT_ID_HOST := 1                 # net_world.gd ID_HOST_PLAYER
const _DIRT_ID_BOT := 100                # net_world.gd ID_BOT .. ID_STRUCT: the bots (Net.bots.node_of)
const _DIRT_ID_STRUCT := 3000
var _dirt: Node3D = null                 # replays the other player's globs


func _on_dirt(pos: Vector3, vel: Vector3, kind: int) -> void:
	if Net.live():
		_rx_dirt.rpc_id(Net.other_id, pos, vel, kind, Net.my_side())


@rpc("any_peer", "call_remote", "reliable")
func _rx_dirt(pos: Vector3, vel: Vector3, kind: int, side: int) -> void:
	if not _sender_ok() or not Net.live() or _main == null or not is_instance_valid(_main):
		return
	if not pos.is_finite() or not vel.is_finite() or not ResourceLoader.exists(DIRT_GLOB_PATH):
		return
	if _dirt == null or not is_instance_valid(_dirt):
		_dirt = load(DIRT_GLOB_PATH).new()
		_dirt.name = "NetDirt"
		_main.add_child(_dirt)
	var av := _ensure_avatar()
	var ex: Array = []
	var col = av.get("_col") if av != null else null
	if col is CollisionObject3D:
		ex.append((col as CollisionObject3D).get_rid())
	if av != null and vel.length_squared() > 1e-4:
		av.shot_fx(pos, vel.normalized(), "dirt")        # (NO_BULLET: the use pose only)
	_dirt.call("launch", pos, vel.limit_length(80.0), clampi(kind, 0, 1), Net.local_team(side), false, ex, av)


## Client: our glob buried `target` (a bot puppet / the host's avatar) with its collar at `feet`.
func claim_dirt_bury(target: Node, feet: Vector3) -> void:
	if not Net.is_client() or not Net.live() or target == null or not is_instance_valid(target):
		return
	var id := 0
	if target.is_in_group("net_player"):
		id = _DIRT_ID_HOST
	elif target != Game.player:
		id = Net.world.id_of(target)
	if id == 0:
		return
	var body: Node3D = Game.dominant_body(feet)
	var bpos: Vector3 = body.global_position if body != null else Vector3.ZERO
	Net.terrain.flush()
	_rx_dirt_bury_claim.rpc_id(1, id, Net.body_index(body), feet - bpos)


@rpc("any_peer", "call_remote", "reliable")
func _rx_dirt_bury_claim(id: int, bi: int, lfeet: Vector3) -> void:
	if not Net.is_host() or not _sender_ok() or not Net.peer_ready or not lfeet.is_finite():
		return
	var n: Node = null
	if id == _DIRT_ID_HOST:
		n = Game.player
	elif id >= _DIRT_ID_BOT and id < _DIRT_ID_STRUCT:
		n = Net.bots.node_of(id)
	else:
		n = Net.world.node_of(id)
	var body := Net.body_by_index(bi)
	if n == null or not is_instance_valid(n) or not (n is Node3D) or body == null:
		return
	# The claimed collar must be where the body is (lag allowance), else it is a stale claim.
	if (n as Node3D).global_position.distance_to(body.global_position + lfeet) > 3.0:
		return
	load(DIRT_GLOB_PATH).call("execute_bury", n)


# =================================================================================================
# Havan (scripts/items/mortar.gd mortar_fired, shells: scripts/items/mortar_shell.gd): each side
# replays the other's shell: the tube's blast at the launch point, the flight (the same fixed steps,
# so it lands where it landed there), the whistle on the way down, the impact. On the host the
# replay is the real one (direct hit, area damage, crater: synced as a terrain op); on a client it
# is the look (mortar_shell.gd skips the direct hit, explosion.gd damage and craters). A shell the
# host's flak bursts in the air is burst on the client too (send_mortar_down, by cfg "nid").
# =================================================================================================

const MORTAR_SHELL_PATH := "res://scripts/items/mortar_shell.gd"
var _mortar: Node3D = null


func _on_mortar(pos: Vector3, vel: Vector3, cfg: Dictionary) -> void:
	if Net.live():
		_rx_mortar.rpc_id(Net.other_id, pos, vel, cfg, Net.my_side())


@rpc("any_peer", "call_remote", "reliable")
func _rx_mortar(pos: Vector3, vel: Vector3, cfg: Dictionary, side: int) -> void:
	if not _sender_ok() or not Net.live() or _main == null or not is_instance_valid(_main):
		return
	if not pos.is_finite() or not vel.is_finite() or not ResourceLoader.exists(MORTAR_SHELL_PATH):
		return
	var sh := _mortar_shells()
	var av := _ensure_avatar()
	var c := {}
	for k in ["radius", "damage", "impulse", "crater", "self_mult", "direct"]:
		if cfg.has(k):
			c[k] = float(cfg[k])
	c["radius"] = clampf(float(c.get("radius", 6.0)), 0.5, 12.0)
	c["damage"] = clampf(float(c.get("damage", 0.0)), 0.0, 300.0)
	c["crater"] = clampf(float(c.get("crater", 0.0)), 0.0, 6.0)
	c["direct"] = clampf(float(c.get("direct", 0.0)), 0.0, 120.0)
	c["impulse"] = clampf(float(c.get("impulse", 0.0)), 0.0, 40.0)
	c["self_mult"] = clampf(float(c.get("self_mult", 1.0)), 0.0, 1.0)
	c["nid"] = int(cfg.get("nid", 0))
	c["player_owned"] = false
	var ex: Array = []
	var col = av.get("_col") if av != null else null
	if col is CollisionObject3D:
		ex.append((col as CollisionObject3D).get_rid())
	if av != null:
		av.shot_fx(pos, vel.normalized(), "mortar")      # (NO_BULLET: the use pose only)
	sh.call("launch_fx", pos, vel)
	sh.call("launch", pos, vel, Net.local_team(side), c, ex, av)


func _mortar_shells() -> Node3D:
	if _mortar == null or not is_instance_valid(_mortar):
		_mortar = load(MORTAR_SHELL_PATH).new()
		_mortar.name = "NetMortarShells"
		_main.add_child(_mortar)
	return _mortar


## Host: a shell (ours or the replay of the client's) was burst in the air by flak: burst the client's copy.
func send_mortar_down(nid: int, pos: Vector3) -> void:
	if Net.is_server and Net.live():
		_rx_mortar_down.rpc_id(Net.other_id, nid, pos)


@rpc("authority", "call_remote", "reliable")
func _rx_mortar_down(nid: int, _pos: Vector3) -> void:
	if Net.is_server or not Net.in_game or nid == 0:
		return
	# The shell is in our replay manager (the host's shot) or in our own Havan's (ours).
	var managers: Array = [_mortar]
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.get("items") is Array:
		for it in pl.items:
			if it != null and is_instance_valid(it) and it.get("shells") is Node3D:
				managers.append(it.get("shells"))
	for m in managers:
		if m != null and is_instance_valid(m) and m.has_method("burst_nid") and m.call("burst_nid", nid):
			return
