extends RefCounted
## Hit reactions mirrored on a multiplayer puppet: net_bot.gd (a host bot: RivalTeam.events().bot_react
## and its death, through net_bots.gd) and remote_avatar.gd (the other player: player.hit_reacted,
## through net_players.gd). The owner's machine decides every reaction; this is only the look:
##   flinch     astronaut.apply_hit along dir at the struck part (part_point(bone)); its strength from
##              the owner's numbers (_k)
##   stagger    the same plus the stagger pose (astronaut.set_stagger) for the shove's length; the move
##              itself comes with the owner's position snapshots
##   knockdown  the puppet's own ragdoll launched like hit_reactor.gd _go_down: every part v ×
##              HR_RAG_UNIFORM, the rest into the torso at the struck part (ragdoll.gd kick_torso) and a
##              kick at that part; is_down() until the get-up (the owner's snapshots are ignored then)
##   getup      hit_reactor.gd mirror_getup: the animated get-up where the puppet lies, facing dir, over
##              strength s; recovered() when it stands
##   death      die(): a knocked-down ragdoll with live physics goes on as the corpse with v added (the
##              same split), else a fresh ragdoll launched like a knockdown
## dir × strength = the velocity (m/s, world; getup: the facing, strength = its duration s); bone = a
## ragdoll part name ("" = unknown: through the torso's centre).
## The puppet's own weapons' flinch (gun_feel / melee / pusher -> astronaut.hit_react) is swallowed
## (route_flinch): the owner's located reaction arrives one round trip later instead of a double twitch.
## Wire format (encode / decode): 7 bytes: kind u8 (KINDS), bone u8 (BONES, 255 = none), dir 3 × s8
## (/127), strength u16 (/100: 0.01 m/s steps, up to 655 m/s).

signal recovered()

const Balance := preload("res://scripts/war/balance.gd")
const Ragdoll := preload("res://scripts/player/ragdoll.gd")
const HitReactor := preload("res://scripts/player/hit_reactor.gd")

const KINDS := ["flinch", "stagger", "knockdown", "getup", "death"]
const BONES := ["head", "chest", "pelvis", "uarm0", "uarm1", "farm0", "farm1", "thigh0", "thigh1", "shin0", "shin1"]
const SIZE := 7
const PLAYER_STAGGER := 0.55       # s of the stagger pose for a player's stumble (PlayerFeel's camera spring)
const PART_KICK := 0.6             # kick at the struck part (hit_reactor.gd _part_kick's w: 0.2 .. 1)
const DOWN_GIVE_UP := 12.0         # s down without the owner's get-up: stand up anyway

var host: Node3D
var astronaut
var collider: CollisionShape3D
var exclude: Array = []
var player := false                # the other player (PlayerFeel's numbers) or a bot (hit_reactor.gd's)
var rag = null                     # the knockdown ragdoll while is_down()

var _hr = null                     # hit_reactor.gd in mirror mode (the down state and the get-up)
var _stg_t := -1.0
var _stg_len := 0.0
var _stg_dir := Vector3.ZERO
var _down_t := 0.0


func setup(p_host: Node3D, p_astronaut, p_collider: CollisionShape3D, p_exclude: Array, p_player: bool) -> void:
	host = p_host
	astronaut = p_astronaut
	collider = p_collider
	exclude = p_exclude
	player = p_player
	if astronaut != null:
		astronaut.reactor = self


## astronaut.hit_react on the puppet (our own weapons' instant flinch): swallowed, see above.
func route_flinch(_dir: Vector3, _k: float, _head_hit: bool) -> bool:
	return true


static func encode(kind: String, dir: Vector3, strength: float, bone: String) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(SIZE)
	b.encode_u8(0, maxi(KINDS.find(kind), 0))
	var bi := BONES.find(bone)
	b.encode_u8(1, bi if bi >= 0 else 255)
	var d := dir.normalized() if dir.length_squared() > 1e-8 else Vector3.ZERO
	b.encode_s8(2, clampi(roundi(d.x * 127.0), -127, 127))
	b.encode_s8(3, clampi(roundi(d.y * 127.0), -127, 127))
	b.encode_s8(4, clampi(roundi(d.z * 127.0), -127, 127))
	b.encode_u16(5, clampi(roundi(strength * 100.0), 0, 65535))
	return b


## {kind, dir, strength, bone} from `b` at byte `o`; {} when short or unknown.
static func decode(b: PackedByteArray, o := 0) -> Dictionary:
	if b.size() < o + SIZE:
		return {}
	var k := b.decode_u8(o)
	if k >= KINDS.size():
		return {}
	var bi := b.decode_u8(o + 1)
	var d := Vector3(b.decode_s8(o + 2), b.decode_s8(o + 3), b.decode_s8(o + 4)) / 127.0
	var bone: String = BONES[bi] if bi < BONES.size() else ""
	return {"kind": str(KINDS[k]), "bone": bone, "dir": d.normalized() if d.length_squared() > 1e-4 else Vector3.ZERO,
			"strength": float(b.decode_u16(o + 5)) / 100.0}


func is_down() -> bool:
	return _hr != null and _hr.is_down()


func is_getting_up() -> bool:
	return _hr != null and _hr.is_getting_up()


func is_staggered() -> bool:
	return _stg_t >= 0.0


## A flinch / stagger / knockdown / getup (the death: die()). Returns the ragdoll of a knockdown.
func react(kind: String, dir: Vector3, strength: float, bone: String) -> Node:
	match kind:
		"flinch":
			flinch(dir, strength, bone)
		"stagger":
			flinch(dir, strength, bone)       # (the owner's stagger kicks the struck bones too)
			_stagger(dir, strength)
		"knockdown":
			return knockdown(dir * strength, bone)
		"getup":
			getup(dir, strength)
	return null


func flinch(dir: Vector3, strength: float, bone: String) -> void:
	if astronaut == null or is_down() or dir.length_squared() < 1e-6:
		return
	var pt: Vector3 = astronaut.part_point(bone) if bone != "" else Vector3.INF
	astronaut.apply_hit(dir, _k(strength), bone == "head", pt)


## The owner's spring strength back from its event's speed: a bot's knockback is HR_KB_K × sqrt(score)
## and its kick k = score / HR_FLINCH_REF; a player's knockback is damage × HR_P_KB_PER_DMG and its own
## body's kick k = damage / HR_P_TAG_REF × 1.2 (hit_reactor.gd).
func _k(strength: float) -> float:
	if player:
		return clampf(strength / Balance.HR_P_KB_PER_DMG / Balance.HR_P_TAG_REF, 0.15, 1.0) * 1.2
	var s := strength / Balance.HR_KB_K
	return clampf(s * s / Balance.HR_FLINCH_REF, 0.15, 1.5)


## The stagger pose for as long as the owner's shove lasts (a bot: hit_reactor.gd _resolve's _len from
## the skid and the hop; a player: its stumble).
func _stagger(dir: Vector3, strength: float) -> void:
	if astronaut == null or host == null or is_down():
		return
	var up := host.global_transform.basis.y
	var v := dir * strength
	var t := v - up * v.dot(up)
	if player:
		_stg_len = PLAYER_STAGGER
	else:
		var lift := maxf(v.dot(up), 0.0)
		var g := maxf((Game.gravity_at(host.global_position) as Vector3).length(), 0.5)
		_stg_len = clampf(t.length() / Balance.HR_KB_FRICTION + 0.3, Balance.HR_STAGGER_MIN, Balance.HR_STAGGER_MAX) + 2.0 * lift / g
	_stg_dir = t.normalized() if t.length_squared() > 1e-6 else Vector3.ZERO
	_stg_t = 0.0


func _end_stagger() -> void:
	if _stg_t >= 0.0 and astronaut != null:
		astronaut.set_stagger(0.0)
	_stg_t = -1.0


## Every frame (before the puppet's animate): the stagger pose; while down the get-up and the hit
## capsule on the body (hit_reactor.gd process).
func process(delta: float) -> void:
	if is_down():
		_down_t += delta
		if not _hr.is_getting_up():
			if rag == null or not is_instance_valid(rag):
				reset()                        # (the body went away under it: just stand)
				if astronaut != null:
					astronaut.transform = Transform3D.IDENTITY
					astronaut.reset_pose()
				recovered.emit()
				return
			if _down_t > DOWN_GIVE_UP:
				_hr.mirror_getup(Vector3.ZERO, Balance.HR_GETUP_TIME)
		_hr.process(delta)
		return
	if _stg_t < 0.0 or astronaut == null:
		return
	_stg_t += delta
	var w := 1.0 - smoothstep(_stg_len - 0.25, _stg_len, _stg_t)
	var d := Vector3.ZERO
	if _stg_dir != Vector3.ZERO:
		d = (astronaut as Node3D).global_transform.basis.inverse() * _stg_dir
	astronaut.set_stagger(w, d)
	if _stg_t >= _stg_len:
		_end_stagger()


## The owner went down: the puppet's ragdoll launched with v (whole, before the split). Already down
## with live physics (the owner fell again during its get-up): v is added to that ragdoll.
func knockdown(v: Vector3, bone: String) -> Node:
	_end_stagger()
	if is_down() and not is_getting_up() and _live(rag):
		add_launch(rag, v, bone)
		return rag
	var r := _launch(v, bone, false)
	if r != null:
		_reactor().mirror_down(r)
		rag = r
		_down_t = 0.0
	return r


## The owner stands up: the animated get-up where the puppet lies.
func getup(face: Vector3, duration: float) -> void:
	if not is_down() or is_getting_up():
		return
	_hr.mirror_getup(face, clampf(duration, 0.3, 4.0))


## The owner died: the corpse (no_float_recover). Knocked down with live physics: that ragdoll goes on
## (hit_reactor.gd take_corpse) with v added; otherwise a fresh one launched with v. Ends any reaction.
func die(v: Vector3, bone: String) -> Node:
	_end_stagger()
	rag = null
	_down_t = 0.0
	if _hr != null:
		var keep = _hr.take_corpse(Vector3.ZERO)
		if keep != null:
			add_launch(keep, v, bone)
			return keep
	return _launch(v, bone, true)


## v more on a ragdoll that is already flying, with the same split.
func add_launch(r, v: Vector3, bone: String) -> void:
	if not _live(r) or v.length_squared() < 1e-6:
		return
	var u := v * Balance.HR_RAG_UNIFORM
	for b in (r.get("bodies") as Dictionary).values():
		if b is RigidBody3D and is_instance_valid(b):
			(b as RigidBody3D).linear_velocity += u
	_kick(r, v, bone)


## A hit on the owner's knocked-down body (hit_reactor.gd on_hit while down -> _rag_hit): the impulse on
## every part and a kick at the struck part (point: world, INF = none).
func shove(impulse: Vector3, point: Vector3, from_pos: Vector3) -> void:
	if not is_down() or is_getting_up() or not _live(rag):
		return
	var bodies: Dictionary = rag.get("bodies")
	if impulse.length_squared() > 1e-6:
		for b in bodies.values():
			if b is RigidBody3D and is_instance_valid(b):
				(b as RigidBody3D).linear_velocity += impulse
	var dir := Vector3.ZERO
	if impulse.length_squared() > 1e-4:
		dir = impulse.normalized()
	elif point != Vector3.INF and from_pos != Vector3.ZERO and point.distance_squared_to(from_pos) > 1e-4:
		dir = (point - from_pos).normalized()
	if point == Vector3.INF or dir == Vector3.ZERO:
		return
	var b = bodies.get(astronaut.part_at(point))
	if b is RigidBody3D and is_instance_valid(b):
		var rb := b as RigidBody3D
		Ragdoll.kick_part(rb, dir * Balance.HR_BONE_IMPULSE * rb.mass, point - rb.global_position)   # (2026-10-07: a velocity change, see ragdoll.gd)


## Back to standing (revive / respawn / leaving): a knockdown ragdoll is freed.
func reset() -> void:
	_end_stagger()
	_down_t = 0.0
	rag = null
	if _hr != null:
		_hr.reset()


func _launch(v: Vector3, bone: String, dead: bool) -> Node:
	if host == null or astronaut == null or not host.is_inside_tree() or host.get_parent() == null:
		return null
	var r := Ragdoll.new()
	host.get_parent().add_child(r)
	r.no_float_recover = dead
	r.start(host, v * Balance.HR_RAG_UNIFORM, 60.0 if dead else Balance.HR_DOWN_MIN, exclude, false)
	_kick(r, v, bone)
	return r


## The non-uniform rest of a launch: into the torso at the struck part (it topples / twists by where it
## was hit, the limbs trail) and a kick at that part.
func _kick(r, v: Vector3, bone: String) -> void:
	if not _live(r):
		return
	var pt: Vector3 = astronaut.part_point(bone) if bone != "" else Vector3.INF
	r.kick_torso(v * (1.0 - Balance.HR_RAG_UNIFORM), pt)
	if pt == Vector3.INF or v.length_squared() < 1e-4:
		return
	var b = (r.get("bodies") as Dictionary).get(bone)
	if b is RigidBody3D and is_instance_valid(b):
		var rb := b as RigidBody3D
		Ragdoll.kick_part(rb, v.normalized() * Balance.HR_BONE_IMPULSE * PART_KICK * rb.mass, pt - rb.global_position)   # (2026-10-07)


## A ragdoll with its physics bodies.
func _live(r) -> bool:
	if r == null or not is_instance_valid(r) or (r as Node).is_queued_for_deletion():
		return false
	var bodies = r.get("bodies")
	return bodies is Dictionary and not (bodies as Dictionary).is_empty()


func _reactor():
	if _hr == null:
		_hr = HitReactor.new()
		_hr.setup(host, astronaut, collider)
		_hr.recovered.connect(_on_recovered)
		if astronaut != null:
			astronaut.reactor = self       # (setup took it over: keep swallowing our own weapons' flinch)
	return _hr


func _on_recovered() -> void:
	rag = null
	_down_t = 0.0
	recovered.emit()
