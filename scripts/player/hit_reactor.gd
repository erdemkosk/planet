extends RefCounted
## Physical hit reactions of an astronaut-bodied damageable (scripts/player/astronaut.gd): the rival
## bots (scripts/war/ai_rival.gd) and the training dummies (scripts/training/training_dummy.gd). The
## player's own side (aim punch, tagging, knockback kick, stumble, weapon jolt) is PlayerFeel at the end.
## Host / single player only for bots (they are host-simulated; the client's puppets mirror the
## owner's RivalTeam.events().bot_react). Tunables: balance.gd "Hit reactions" (HR_*).
##
## Coalescing: every hit on the body within one physics frame is ONE impact, resolved on the next
## physics frame (a shotgun blast is one big reaction that still keeps every pellet's bone). A hit =
## take_damage -> on_hit (its point from Game.hit_pos, set by Game.damage_target's hit_point), plus the
## astronaut.hit_react(dir, k, head) gun_feel / melee / the pusher call right after it: astronaut.gd
## routes that here (route_flinch) for the exact shot direction and the head flag, so the body never
## flinches twice.
## Tiers, by a decaying meter of impact scores (damage, impulse, point blank; a leg hit strong enough,
## a shove fast enough, or a random roll on one strong impact can also knock it down):
##   flinch     per-bone hit springs at the struck bones (astronaut.apply_hit: the push at the hit
##              point as a torque up the joint chain) + a short skid back along the shot (~0.3-0.6 m
##              for a rifle hit); a bot's aim is spoilt for aim_block s
##   stagger    the shove: knockback along the shot with a little hop (bots fly it on their own
##              airborne sim: `lift`; own_air owners read lift_height()), then a skid with ground
##              friction (HR_KB_FRICTION, none in the air), the walk cycle stumbling with the real
##              displacement, torso bent with the shove and arms out (astronaut.set_stagger); no
##              control, no shooting
##   knockdown  a physical ragdoll (scripts/player/ragdoll.gd) launched with the impulse plus a kick
##              at each struck part (a leg shot topples differently from a head shot); the hit capsule
##              follows the body (still vulnerable: hits shove the ragdoll and hurt); lies
##              HR_DOWN_MIN..MAX s once settled, then player.gd's animated get-up (hands and knees, one
##              knee, stand) where it lies. Only when can_down() allows (bots: near / mid LOD and a free
##              team ragdoll slot), else the same shove as a stagger.
## Kills: take_corpse() lets a knocked-down body go on as the corpse; death_launch() adds the same
## blast's other hits to a fresh corpse's launch (at least HR_KILL_LAUNCH_MIN m/s for a knockdown-strength
## blast) and kicks their parts; on_dead_hit() throws the corpse with the hits that land right after the
## death (the rest of the pellets).
##
## Owner API (the owner keeps its ragdoll in `_ragdoll`, has `hp` and is_dead()):
##   setup(host, astronaut, collider)       once (collider: the hit capsule's CollisionShape3D)
##   on_hit(amount, from_pos, impulse, point = INF, head = false)   take_damage, alive, after the hp
##   on_push(v, from_pos)                   a shove without damage (fling below AI_FLING_KO)
##   on_dead_hit(impulse, point = INF)      take_damage on a dead body
##   tick(delta, grounded = true)           every physics frame (or frame) while alive
##   process(delta)                         every frame while is_down() (get-up, capsule)
##   move_velocity(want, up)                the owner's walking velocity with the reaction applied
##   kb_velocity(), lift_height(), blocked() (a wall stopped the shove)
##   take_corpse(impulse) / death_launch(base_v)   from the owner's _die (see above)
##   is_staggered(), is_down() (incl. the get-up), busy(), reset(); aim_block, lift
## Signals: reacted(kind, dir, strength, bone): kind "flinch" / "stagger" / "knockdown" / "getup";
## dir × strength = the knockback / launch velocity (world, m/s, with the hop); "getup": dir = the
## facing it stands up toward, strength = the get-up's duration (s); bone = the part struck hardest
## ("head", "chest", "pelvis", "uarm0", "farm1", "thigh0", "shin1", ... 0 = left; "" = none).
## went_down(ragdoll), getup_started(stand: Transform3D) (the reactor already moved the host there),
## recovered().

const Balance := preload("res://scripts/war/balance.gd")
const Ragdoll := preload("res://scripts/player/ragdoll.gd")
const Downed := preload("res://scripts/war/downed.gd")     # a downed owner gets no reactions (its own pose)

signal reacted(kind: String, dir: Vector3, strength: float, bone: String)
signal went_down(ragdoll: Node)
signal getup_started(stand: Transform3D)
signal recovered()

enum { NONE, STAGGER, DOWN, GETUP }

var host: Node3D
var astronaut
var collider: CollisionShape3D
var own_air := false                   # true: the reactor flies the stagger hop itself (lift_height())
var can_down := Callable()             # () -> bool: may it go down now (empty: always)
var face_hint := Callable()            # () -> Vector3: facing to stand up toward (empty: the body's)
var state := NONE
var aim_block := 0.0                   # s the owner may not shoot
var lift := 0.0                        # m/s up of the current stagger's hop (bots: their _vy)

var _pend: Array = []                  # hits of the open impact
var _pend_frame := -1
var _meter := 0.0
var _t := 0.0
var _len := 0.0
var _kb := Vector3.ZERO                # knockback velocity (world, tangent)
var _h := 0.0                          # own_air hop: height and speed
var _vy := 0.0
var _rag = null                        # the knockdown ragdoll
var _still := 0.0
var _down_len := 1.5
var _col_rest := Transform3D()
var _proc_was := false
var _l0 := {}
var _poses := {}
var _died_frame := -1000
var _corpse_hits: Array = []
var _corpse_core := Vector3.ZERO       # the non-uniform rest of a corpse's launch (_torso_kick, deferred)
var _corpse_pt := Vector3.INF          # ... delivered at this point (the heaviest hit; INF: the torso's centre)
## Record of the last corpse launch (read-only; multiplayer: net_bots.gd sends it to the client's puppet):
## death_launch: the whole launch before the split; take_corpse (kept body): what was added to it.
var corpse_v := Vector3.ZERO
var corpse_point := Vector3.INF        # its point (INF: none, through the torso's centre)
## One-shot: the next death_launch is NOT capped (the Kinetik İtici's into-space band sets it right
## before its _die, ai_rival.gd fling()); every other corpse / knockdown launch is capped by _cap_v.
var allow_escape := false
var getup_time: float = Balance.HR_GETUP_TIME   # s of the get-up (a multiplayer mirror: the owner's)


func setup(p_host: Node3D, p_astronaut, p_collider: CollisionShape3D = null) -> void:
	host = p_host
	astronaut = p_astronaut
	collider = p_collider
	if astronaut != null:
		astronaut.reactor = self


func is_staggered() -> bool:
	return state == STAGGER


## Down: the knockdown ragdoll and the get-up after it.
func is_down() -> bool:
	return state == DOWN or state == GETUP


func busy() -> bool:
	return state != NONE


func kb_velocity() -> Vector3:
	return _kb


func lift_height() -> float:
	return _h


## A wall stopped the shove.
func blocked() -> void:
	_kb = Vector3.ZERO


## Back to standing still (revive / respawn): a knockdown ragdoll is freed.
func reset() -> void:
	if _rag != null and is_instance_valid(_rag) and not _rag.is_queued_for_deletion():
		_rag.queue_free()
	_rag = null
	_end_down_body()
	state = NONE
	_pend.clear()
	_corpse_hits.clear()
	_meter = 0.0
	_kb = Vector3.ZERO
	_h = 0.0
	_vy = 0.0
	aim_block = 0.0
	lift = 0.0
	if astronaut != null:
		astronaut.set_stagger(0.0)


# =================================================================================================
# Hits
# =================================================================================================

## take_damage on the living body (after its hp went down). point: world hit point (INF: Game.hit_pos).
func on_hit(amount: float, from_pos: Vector3, impulse: Vector3, point := Vector3.INF, head := false) -> void:
	if host == null or Downed.is_downed(host):
		return
	if point == Vector3.INF:
		point = Game.hit_pos
	var dir := _dir_of(from_pos, impulse, point)
	if state == DOWN:
		_rag_hit(_rag, impulse, point, dir, 1.0)
		return
	var hp = host.get("hp")
	_pend.append({"dmg": maxf(amount, 0.0), "imp": impulse, "from": from_pos, "point": point, "dir": dir,
			"head": head, "push": Vector3.ZERO, "lethal": hp != null and float(hp) <= 0.0})
	_pend_frame = Engine.get_physics_frames()


## A shove of velocity v without damage (the Kinetik İtici below AI_FLING_KO, the melee fling).
## Tier by speed: HR_PUSH_STAGGER / HR_PUSH_DOWN. Ignored while down (the pusher shoves the ragdoll).
func on_push(v: Vector3, from_pos := Vector3.ZERO) -> void:
	if host == null or is_down() or host.is_dead() or v.length_squared() < 0.0025 or Downed.is_downed(host):
		return
	_pend.append({"dmg": 0.0, "imp": Vector3.ZERO, "from": from_pos, "point": Vector3.INF, "dir": v.normalized(),
			"head": false, "push": v, "lethal": false})
	_pend_frame = Engine.get_physics_frames()


## astronaut.hit_react of the same hit (right after its damage): the pending hit gets the exact shot
## direction and the head flag. True = handled here (the astronaut does not flinch on its own).
func route_flinch(dir: Vector3, _k: float, head_hit: bool) -> bool:
	if host == null:
		return false
	if host.is_dead() or is_down() or Downed.is_downed(host):
		return true
	if not _pend.is_empty() and _pend_frame == Engine.get_physics_frames():
		var h: Dictionary = _pend[_pend.size() - 1]
		if not h.has("routed"):
			h["routed"] = true
			if dir.length_squared() > 1e-6:
				h["dir"] = dir.normalized()
			h["head"] = bool(h["head"]) or head_hit
		return true
	return false


## take_damage on a dead body: within HR_DEATH_WINDOW physics frames of the death (the rest of the
## blast) it still throws the corpse, at the struck part.
func on_dead_hit(impulse: Vector3, point := Vector3.INF) -> void:
	if host == null or Engine.get_physics_frames() - _died_frame > Balance.HR_DEATH_WINDOW:
		return
	if point == Vector3.INF:
		point = Game.hit_pos
	impulse = _cap_v(impulse, Balance.HR_CORPSE_MAX * 0.6)
	_rag_hit(host.get("_ragdoll"), impulse * 0.8, point, impulse.normalized() if impulse.length_squared() > 1e-6 else Vector3.ZERO, 0.6)


## Caps a corpse / knockdown launch for the small, low-gravity planets (0.8 g, escape ~30.7 m/s): the
## part along the ground to `tan_max`, the upward part to HR_CORPSE_UP_MAX (downward is free). A
## point-blank shotgun or a shell next to a bot then throws it a few metres with a short hop instead
## of sailing off the planet (the user: "ölünce uzaya fırlıyorlar, aşırı olmaması lazım").
func _cap_v(v: Vector3, tan_max: float) -> Vector3:
	if host == null:
		return v.limit_length(tan_max)
	var up := _up()
	var vu := v.dot(up)
	var vt := (v - up * vu).limit_length(tan_max)
	return vt + up * minf(vu, Balance.HR_CORPSE_UP_MAX)


# =================================================================================================
# Per frame
# =================================================================================================

func tick(delta: float, grounded := true) -> void:
	if host == null:
		return
	_meter *= exp(-delta * 0.6931 / Balance.HR_METER_HALF)
	aim_block = maxf(aim_block - delta, 0.0)
	if not _pend.is_empty() and Engine.get_physics_frames() > _pend_frame:
		_resolve()
	if state == DOWN:
		_tick_down(delta)
		return
	if state == GETUP:
		return
	if own_air and (_h > 0.0 or _vy > 0.0):
		_vy -= _gravity() * delta
		_h += _vy * delta
		if _h <= 0.0:
			_h = 0.0
			_vy = 0.0
	if own_air:
		grounded = _h <= 0.0
	if _kb != Vector3.ZERO:
		var up := _up()
		var l := _kb.length()
		var t := _kb - up * _kb.dot(up)                   # stays tangent on the round planet
		_kb = t.normalized() * l if t.length_squared() > 1e-8 else Vector3.ZERO
		if grounded:
			_kb = _kb.move_toward(Vector3.ZERO, Balance.HR_KB_FRICTION * delta)
	if state == STAGGER:
		_t += delta
		var w := 1.0 - smoothstep(_len - 0.25, _len, _t)
		var d := _kb if _kb.length_squared() > 0.01 else Vector3.ZERO
		astronaut.set_stagger(w, astronaut.global_transform.basis.inverse() * d if d != Vector3.ZERO else Vector3.ZERO)
		if (_t >= _len and grounded) or _t > _len + 2.5:
			state = NONE
			astronaut.set_stagger(0.0)


## Every frame while down: the get-up animation, the hit capsule on the body.
func process(delta: float) -> void:
	if state == GETUP:
		_animate_getup(delta)
	if is_down():
		_follow_collider()


## The owner's walking velocity with the reaction on top: staggered = the shove alone (no control);
## otherwise its own `want` plus the skid, slowed while limping.
func move_velocity(want: Vector3, up: Vector3) -> Vector3:
	var kb := _kb - up * _kb.dot(up)
	if state == STAGGER:
		return kb
	var m := 1.0 - (1.0 - Balance.HR_LIMP_MOVE) * (float(astronaut.limp_amount()) if astronaut != null else 0.0)
	return want * m + kb


# =================================================================================================
# Resolving an impact
# =================================================================================================

func _score(h: Dictionary) -> float:
	var d := float(h["dmg"])
	var s := d * (1.0 + d / Balance.HR_HEAVY_DMG) + (h["imp"] as Vector3).length() * Balance.HR_IMPULSE_K
	var from: Vector3 = h["from"]
	if from != Vector3.ZERO:
		var dist := from.distance_to(host.global_position)
		s *= lerpf(Balance.HR_NEAR_BONUS, 1.0, smoothstep(Balance.HR_NEAR_FULL, Balance.HR_NEAR_ZERO, dist))
	return s


func _resolve() -> void:
	var hits := _pend
	_pend = []
	if host.is_dead() or astronaut == null:
		return
	var up := _up()
	var score := 0.0
	var best := 0.0
	var imp := Vector3.ZERO
	var push := Vector3.ZERO
	var dsum := Vector3.ZERO
	var leg := 0.0
	var bone := ""
	for h in hits:
		var s := _score(h)
		h["s"] = s
		score += s
		imp += h["imp"]
		var pv: Vector3 = h["push"]
		if pv.length() > push.length():
			push = pv
		dsum += (h["dir"] as Vector3) * maxf(s, 1.0 + pv.length() * 10.0)
		if h["point"] == Vector3.INF:
			h["point"] = _guess_point(h, up)
		var part: String = "head" if bool(h["head"]) else astronaut.part_at(h["point"])
		h["part"] = part
		if part.begins_with("thigh") or part.begins_with("shin"):
			leg += s
		if s >= best:
			best = s
			bone = part
	_meter += score
	var dir := dsum - up * dsum.dot(up)
	if dir.length_squared() < 1e-6:
		dir = host.global_transform.basis.z
		dir -= up * dir.dot(up)
	dir = dir.normalized()
	var imp_t := imp - up * imp.dot(up)
	var push_t := push - up * push.dot(up)
	var kb := minf(maxf(imp_t.length(), Balance.HR_KB_K * sqrt(score)), Balance.HR_KB_MAX)
	var kb_down := maxf(kb, push_t.length())          # a knockdown flies with the whole shove...
	kb = maxf(kb, push_t.length() * Balance.HR_PUSH_KB)   # ...a stumble skids with part of it
	var tier := 0
	if _meter >= Balance.HR_STAGGER:
		tier = 1
	var roll := (score - Balance.HR_DOWN_SOFT) / (Balance.HR_KNOCKDOWN - Balance.HR_DOWN_SOFT)
	if _meter >= Balance.HR_KNOCKDOWN or leg >= Balance.HR_LEG_SWEEP or (roll > 0.0 and randf() < roll):
		tier = 2
	var ps := push.length()
	if ps >= Balance.HR_PUSH_DOWN:
		tier = 2
	elif ps >= Balance.HR_PUSH_STAGGER:
		tier = maxi(tier, 1)
	if tier == 2 and not _may_down():
		tier = 1
	var up_v := maxf(push.dot(up), 0.0)
	if tier == 2:
		_go_down(hits, dir, kb_down, up_v, score, bone)
		return
	if state == GETUP:
		return                             # (the get-up drives the bones; only a knockdown interrupts it)
	up_v *= Balance.HR_PUSH_KB
	for h in hits:
		astronaut.apply_hit(h["dir"], clampf(float(h["s"]) / Balance.HR_FLINCH_REF, 0.15, 1.5) + (h["push"] as Vector3).length() * 0.12,
				bool(h["head"]), h["point"])
	if tier == 1:
		_kb = (_kb + dir * kb).limit_length(maxf(Balance.HR_KB_MAX, kb))
		lift = maxf(Balance.HR_KB_LIFT * kb, up_v)
		var air := 2.0 * lift / maxf(_gravity(), 1.0)
		_len = clampf(kb / Balance.HR_KB_FRICTION + 0.3, Balance.HR_STAGGER_MIN, Balance.HR_STAGGER_MAX) + air
		_t = 0.0
		state = STAGGER
		if own_air and _h <= 0.0:
			_vy = lift
		aim_block = maxf(aim_block, _len)
		var v := _kb + up * lift
		reacted.emit("stagger", v.normalized(), v.length(), bone)
	else:
		_kb = (_kb + dir * kb).limit_length(maxf(Balance.HR_KB_MAX, kb))
		lift = 0.0
		aim_block = maxf(aim_block, Balance.HR_FLINCH_AIM * clampf(score / Balance.HR_FLINCH_REF, 1.0, 2.0))
		reacted.emit("flinch", dir, kb, bone)


## Where a hit without a known point (Game.hit_pos INF) lands: a blast (its impulse leans up: the
## explosions add "up") on the part nearest its centre (a ground blast sweeps the legs); a shot (a
## multiplayer claim, the pusher's damage) on the part nearest the shooter's eye height; a shove on
## the chest.
func _guess_point(h: Dictionary, up: Vector3) -> Vector3:
	var f: Vector3 = h["from"]
	var chest_c: Vector3 = astronaut.chest.global_transform * Vector3(0, 0.2, 0)
	if f == Vector3.ZERO or (h["push"] as Vector3) != Vector3.ZERO:
		return chest_c
	var imp: Vector3 = h["imp"]
	if imp.length_squared() > 0.01 and imp.normalized().dot(up) > 0.3:
		return astronaut.closest_on_body(f)
	return astronaut.closest_on_body(f + _up_at(f) * 1.4)


func _may_down() -> bool:
	if host == null or host.get_parent() == null:
		return false
	return not can_down.is_valid() or bool(can_down.call())


# =================================================================================================
# Knockdown and get-up
# =================================================================================================

func _go_down(hits: Array, dir: Vector3, kb: float, up_v: float, score: float, bone: String) -> void:
	var up := _up()
	if _rag != null and is_instance_valid(_rag) and not _rag.is_queued_for_deletion():
		_rag.queue_free()                  # knocked down again during the get-up
	var hv = host.get("velocity")
	if not (hv is Vector3):
		hv = host.get("_vel")
	var v: Vector3 = (hv as Vector3) if hv is Vector3 else Vector3.ZERO
	v = v - up * minf(v.dot(up), 0.0)
	v += dir * maxf(kb, 3.0) + up * maxf(Balance.HR_KB_LIFT * 1.4 * maxf(kb, 3.0), up_v)
	v = _cap_v(v, Balance.HR_DOWN_LAUNCH_MAX)
	var was_down := is_down()
	if not was_down:
		_proc_was = astronaut.is_processing()
		if collider != null:
			_col_rest = collider.transform
	astronaut.set_stagger(0.0)
	_rag = Ragdoll.new()
	host.get_parent().add_child(_rag)
	# Uniform share for every part, the rest into the torso at the heaviest hit (it topples by location).
	_rag.start(host, v * Balance.HR_RAG_UNIFORM, Balance.HR_DOWN_MIN, [], false)
	_torso_kick(_rag, v * (1.0 - Balance.HR_RAG_UNIFORM), _main_point(hits))
	for h in hits:
		_part_kick(_rag, h["point"], h["dir"], clampf(float(h["s"]) / Balance.HR_FLINCH_REF, 0.2, 1.0), h.get("part", ""))
	astronaut.set_process(true)            # the skin follows the ragdoll every frame (after it moved)
	state = DOWN
	_t = 0.0
	_still = 0.0
	_kb = Vector3.ZERO
	_h = 0.0
	_vy = 0.0
	lift = 0.0
	aim_block = 0.0
	_down_len = lerpf(Balance.HR_DOWN_MIN, Balance.HR_DOWN_MAX,
			clampf((score - Balance.HR_STAGGER) / (Balance.HR_KNOCKDOWN * 1.5 - Balance.HR_STAGGER), 0.0, 1.0))
	went_down.emit(_rag)
	reacted.emit("knockdown", v.normalized(), v.length(), bone)


func _tick_down(delta: float) -> void:
	_t += delta
	if _rag == null or not is_instance_valid(_rag):
		_recover()
		return
	var bodies: Dictionary = _rag.bodies
	if bodies.is_empty():
		_still += delta                    # frozen by the team's ragdoll cap: just lie there
	elif _rag.pelvis_velocity().length() < 1.0:
		_still += delta
	else:
		_still = maxf(_still - delta, 0.0)
	if _still >= _down_len or _t >= Balance.HR_DOWN_TIMEOUT:
		_begin_getup()


## The body lies still: drop the physics, stand the host up on the ground under the pelvis and
## animate the get-up from the lying pose (player.gd's, bone locals; the hips in the new root's space).
func _begin_getup() -> void:
	var a = astronaut
	var bones: Array = [a.hips, a.chest, a.head] + a.shoulder + a.elbow + a.thigh + a.shin
	var hips_g: Transform3D = a.hips.global_transform
	var chest_b: Basis = a.chest.global_transform.basis
	_l0.clear()
	for b in bones:
		_l0[b] = b.transform
	if not (_rag.bodies as Dictionary).is_empty():
		_rag.begin_getup(null, 0.0)
	var pos := hips_g.origin
	if not pos.is_finite():
		pos = host.global_position         # (2026-10-07: a blown-up ragdoll never stands the host up at NaN)
	var up := _up_at(pos)
	var feet := _ground_below(pos, up)
	var f := Vector3.ZERO
	if face_hint.is_valid():
		f = face_hint.call()
	if f.length_squared() < 1e-4 or not f.is_finite():
		f = -chest_b.z if chest_b.z.is_finite() else Vector3.ZERO
		if f != Vector3.ZERO and absf(f.normalized().dot(up)) > 0.7:
			f = chest_b.y                  # lying: along the body, toward the head
	f -= up * f.dot(up)
	if f.length_squared() < 1e-4 or not f.is_finite():
		f = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	f = f.normalized()
	var x := up.cross(-f).normalized()
	var xf := Transform3D(Basis(x, up, x.cross(up)), feet)
	host.global_transform = xf
	a.transform = Transform3D.IDENTITY
	_l0[a.hips] = a.global_transform.affine_inverse() * hips_g
	state = GETUP
	_t = 0.0
	getup_started.emit(xf)
	reacted.emit("getup", f, getup_time, "")


## Key poses of the get-up (bone locals): 1 = on hands and knees, 2 = kneeling on one knee
## (player.gd _getup_pose).
func _pose(k: int) -> Dictionary:
	if _poses.has(k):
		return _poses[k]
	var a = astronaut
	var d := {}
	var spec := {}
	if k == 1:
		spec = {a.hips: [Vector3(0, 0.5, 0.12), Vector3(-1.25, 0, 0)], a.chest: Vector3(-0.1, 0, 0),
				a.head: Vector3(0.9, 0, 0), a.shoulder[0]: Vector3(1.25, 0, -0.1), a.shoulder[1]: Vector3(1.25, 0, 0.1),
				a.elbow[0]: Vector3(0.15, 0, 0), a.elbow[1]: Vector3(0.15, 0, 0),
				a.thigh[0]: Vector3(1.3, 0, -0.05), a.thigh[1]: Vector3(1.3, 0, 0.05),
				a.shin[0]: Vector3(-1.55, 0, 0), a.shin[1]: Vector3(-1.55, 0, 0)}
	else:
		spec = {a.hips: [Vector3(0, 0.52, 0.05), Vector3(-0.22, 0, 0)], a.chest: Vector3(-0.05, 0, 0),
				a.head: Vector3(0.18, 0, 0), a.shoulder[0]: Vector3(0.55, 0, -0.18), a.shoulder[1]: Vector3(0.85, 0, 0.15),
				a.elbow[0]: Vector3(0.6, 0, 0), a.elbow[1]: Vector3(0.7, 0, 0),
				a.thigh[0]: Vector3(1.55, 0, -0.05), a.thigh[1]: Vector3(0.15, 0, 0.05),
				a.shin[0]: Vector3(-1.5, 0, 0), a.shin[1]: Vector3(-1.55, 0, 0)}
	for b in spec:
		var r: Transform3D = a.rest_local(b)
		if spec[b] is Array:
			d[b] = Transform3D(Basis.from_euler(spec[b][1]), spec[b][0])
		else:
			d[b] = Transform3D(Basis.from_euler(spec[b]), r.origin)
	_poses[k] = d
	return d


## Visible get-up: roll onto hands and knees, push up onto one knee, stand (player.gd _animate_getup).
func _animate_getup(delta: float) -> void:
	_t += delta
	var t := _t
	var T := getup_time
	var a = astronaut
	var k1 := _pose(1)
	var k2 := _pose(2)
	var t1 := T * 0.34
	var t2 := T * 0.64
	for b in _l0:
		var x: Transform3D
		if t < t1:
			x = (_l0[b] as Transform3D).interpolate_with(k1[b], _ease(t / t1))
		elif t < t2:
			x = (k1[b] as Transform3D).interpolate_with(k2[b], _ease((t - t1) / (t2 - t1)))
		else:
			x = (k2[b] as Transform3D).interpolate_with(a.rest_local(b), _ease((t - t2) / (T - t2)))
		b.transform = x
	if t >= T:
		_recover()


static func _ease(v: float) -> float:
	var k := clampf(v, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


func _recover() -> void:
	if _rag != null and is_instance_valid(_rag) and not _rag.is_queued_for_deletion():
		_rag.queue_free()
	_rag = null
	_end_down_body()
	astronaut.transform = Transform3D.IDENTITY
	astronaut.reset_pose()
	state = NONE
	_t = 0.0
	_kb = Vector3.ZERO
	_meter = 0.0
	recovered.emit()


## Leaving the down state: the skin back to the owner's own syncing, the capsule upright again.
func _end_down_body() -> void:
	if not is_down():
		return
	if astronaut != null:
		astronaut.set_process(_proc_was)
	if collider != null:
		collider.transform = _col_rest


## The hit capsule lies along the body (centred at the hips, along hips -> head): still hittable.
func _follow_collider() -> void:
	if collider == null or astronaut == null:
		return
	var hp: Vector3 = astronaut.hips.global_position
	var ax: Vector3 = astronaut.head.global_position - hp
	if ax.length_squared() < 1e-4:
		return
	var y := ax.normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	collider.global_transform = Transform3D(Basis(x, y, x.cross(y)), hp + y * 0.05)


## Multiplayer mirror (scripts/net/net_react.gd on a client's bot puppet / the other player's avatar):
## a body with no reactions of its own shows the owner's knockdown and get-up. No tick() and no hits:
## mirror_down(rag) = `rag` (the puppet's own ragdoll, already launched) is the knockdown body;
## mirror_getup(face, duration) = the animated get-up where it lies, facing `face` (ZERO: the chest's),
## over `duration` s; process(delta) every frame while is_down(); recovered() at the end.
func mirror_down(rag: Node) -> void:
	if host == null or astronaut == null or rag == null:
		return
	if not is_down():
		_proc_was = astronaut.is_processing()
		if collider != null:
			_col_rest = collider.transform
	elif _rag != null and _rag != rag and is_instance_valid(_rag) and not _rag.is_queued_for_deletion():
		_rag.queue_free()
	astronaut.set_stagger(0.0)
	astronaut.set_process(true)
	_rag = rag
	state = DOWN
	_t = 0.0
	_still = 0.0
	_kb = Vector3.ZERO
	_pend.clear()


func mirror_getup(face: Vector3, duration: float) -> void:
	if state != DOWN or _rag == null or not is_instance_valid(_rag):
		return
	var keep := face_hint
	face_hint = func() -> Vector3: return face
	getup_time = maxf(duration, 0.3)
	_begin_getup()
	face_hint = keep


func is_getting_up() -> bool:
	return state == GETUP


# =================================================================================================
# Kills
# =================================================================================================

## The owner dies (its _die). A knocked-down body whose physics still run goes on as the corpse
## (returned; the death's impulse and the same blast's other hits added); otherwise null (a get-up /
## frozen ragdoll is freed: the owner makes a fresh one, launched with death_launch). Ends any
## reaction and opens the death window (on_dead_hit).
func take_corpse(impulse: Vector3) -> Node:
	_died_frame = Engine.get_physics_frames()
	var keep: Node = null
	if state == DOWN and _rag != null and is_instance_valid(_rag) and not (_rag.bodies as Dictionary).is_empty():
		keep = _rag
		keep.set("no_float_recover", true)
		keep.set("_done", false)           # (it may have settled already: let it report again)
		keep.set("_settle", 0.0)
		var extra := impulse
		for h in _pend:
			if not bool(h["lethal"]):
				extra += h["imp"]
		if allow_escape:
			allow_escape = false
		else:
			extra = _cap_v(extra, Balance.HR_CORPSE_MAX)
		corpse_v = extra
		corpse_point = _main_point(_pend)
		_rag_hit(keep, extra * Balance.HR_RAG_UNIFORM, Vector3.INF, Vector3.ZERO, 0.0)
		_torso_kick(keep, extra * (1.0 - Balance.HR_RAG_UNIFORM), _main_point(_pend))
		for h in _pend:
			_part_kick(keep, h["point"], h["dir"], 0.5, "")
		_pend.clear()
		_rag = null
	elif _rag != null and is_instance_valid(_rag) and not _rag.is_queued_for_deletion():
		_rag.queue_free()
		_rag = null
	_end_down_body()
	state = NONE
	_kb = Vector3.ZERO
	_h = 0.0
	_vy = 0.0
	_meter = 0.0
	aim_block = 0.0
	if astronaut != null:
		astronaut.set_stagger(0.0)
	return keep


## Launch velocity of a fresh corpse: base_v (the body's velocity + the lethal hit's impulse) plus the
## same blast's other hits; a knockdown-strength blast throws it at least HR_KILL_LAUNCH_MIN m/s along
## the shot, lifted. Their parts get their kicks once the ragdoll exists (deferred).
## Only HR_RAG_UNIFORM of it is returned (every part starts with that); the rest is delivered into the
## torso at the heaviest hit's point right after the ragdoll exists (_kick_corpse -> _torso_kick), so a
## corpse crumples, topples and twists by where it was hit instead of flying back as one stiff piece.
func death_launch(base_v: Vector3) -> Vector3:
	var hits := _pend
	_pend = []
	if host == null:
		return base_v
	var escape := allow_escape
	allow_escape = false
	if not escape:
		base_v = _cap_v(base_v, Balance.HR_CORPSE_MAX)
	var share := Balance.HR_RAG_UNIFORM
	if hits.is_empty():
		_corpse_core = base_v * (1.0 - share)
		_corpse_pt = Vector3.INF
		corpse_v = base_v
		corpse_point = Vector3.INF
		_corpse_hits = []
		_kick_corpse.call_deferred()
		return base_v * share
	var up := _up()
	var v := base_v
	var score := 0.0
	var dsum := Vector3.ZERO
	for h in hits:
		var s := _score(h)
		h["s"] = s
		score += s
		dsum += (h["dir"] as Vector3) * maxf(s, 1.0)
		if not bool(h["lethal"]):
			v += h["imp"]
	var dir := dsum - up * dsum.dot(up)
	var fl := Balance.HR_KILL_LAUNCH_MIN * smoothstep(Balance.HR_STAGGER, Balance.HR_KNOCKDOWN, score)
	if fl > 0.0 and dir.length_squared() > 1e-6:
		dir = dir.normalized()
		var along := v.dot(dir)
		if along < fl:
			v += dir * (fl - along)
		var vu := v.dot(up)
		if vu < fl * 0.3:
			v += up * (fl * 0.3 - vu)
	if not escape:
		v = _cap_v(v, Balance.HR_CORPSE_MAX)
	_corpse_hits = hits
	_corpse_core = v * (1.0 - share)
	_corpse_pt = _main_point(hits)
	corpse_v = v
	corpse_point = _corpse_pt
	_kick_corpse.call_deferred()
	return v * share


func _kick_corpse() -> void:
	var hits := _corpse_hits
	_corpse_hits = []
	var core := _corpse_core
	var pt := _corpse_pt
	_corpse_core = Vector3.ZERO
	_corpse_pt = Vector3.INF
	if host == null or not is_instance_valid(host):
		return
	var r = host.get("_ragdoll")
	_torso_kick(r, core, pt)
	for h in hits:
		if h["point"] != Vector3.INF:
			_part_kick(r, h["point"], h["dir"], clampf(float(h.get("s", 30.0)) / Balance.HR_FLINCH_REF, 0.2, 1.0), "")


# =================================================================================================
# Ragdoll kicks
# =================================================================================================

## A hit on a ragdoll: `k` × impulse shared by every part (the body moves as one, ragdoll.gd keeps the
## limbs together) plus a kick at the struck part.
func _rag_hit(r, impulse: Vector3, point: Vector3, dir: Vector3, k: float) -> void:
	if r == null or not is_instance_valid(r):
		return
	var bodies = r.get("bodies")
	if not (bodies is Dictionary) or (bodies as Dictionary).is_empty():
		return
	if impulse.length_squared() > 1e-6:
		for b in (bodies as Dictionary).values():
			if b is RigidBody3D and is_instance_valid(b):
				(b as RigidBody3D).linear_velocity += impulse
	if k > 0.0 and point != Vector3.INF and dir != Vector3.ZERO:
		_part_kick(r, point, dir, k, "")


## The non-uniform rest of a launch into the torso at the hit point (ragdoll.gd kick_torso: it topples /
## twists by where the hit landed, the limbs trail and flop).
func _torso_kick(r, dv: Vector3, point: Vector3) -> void:
	if r != null and is_instance_valid(r) and r.has_method("kick_torso"):
		r.kick_torso(dv, point)


## The point of the heaviest hit of an impact (its "s" score, else the first with a point); INF if none.
func _main_point(hits: Array) -> Vector3:
	var best := Vector3.INF
	var bs := -1.0
	for h in hits:
		var pt = h.get("point", Vector3.INF)
		if not (pt is Vector3) or pt == Vector3.INF:
			continue
		var s := float(h.get("s", 0.0))
		if s > bs:
			bs = s
			best = pt
	return best


## The impulse AT the struck part (apply_impulse off its centre: a leg shot topples, a head shot
## whips): HR_BONE_IMPULSE × w m/s × the part's mass.
func _part_kick(r, point: Vector3, dir: Vector3, w: float, part: String) -> void:
	if r == null or not is_instance_valid(r) or point == Vector3.INF or dir == Vector3.ZERO:
		return
	var bodies = r.get("bodies")
	if not (bodies is Dictionary) or (bodies as Dictionary).is_empty():
		return
	if part == "" and astronaut != null:
		part = astronaut.part_at(point)
	var b = (bodies as Dictionary).get(part)
	if not (b is RigidBody3D) or not is_instance_valid(b):
		return
	# A budget per ragdoll and physics frame (HR_PART_KICK_BUDGET of full-strength kicks): the nine
	# pellets of a point-blank shotgun used to add nine full kicks (~1 m/s of whole-body speed each)
	# on top of the capped launch and sent the corpse off the planet.
	var frame := Engine.get_physics_frames()
	var used := float(r.get_meta("pk_used", 0.0)) if int(r.get_meta("pk_frame", -1)) == frame else 0.0
	var allow := maxf(Balance.HR_PART_KICK_BUDGET - used, 0.0)
	w = minf(w, allow)
	r.set_meta("pk_frame", frame)
	r.set_meta("pk_used", used + w)
	if w <= 0.001:
		return
	var rb := b as RigidBody3D
	# (A velocity change, not apply_impulse(): on a ragdoll made this frame that acted on a 1 kg part,
	# ~20× too hard; ragdoll.gd kick_part, 2026-10-07.)
	Ragdoll.kick_part(rb, dir.normalized() * Balance.HR_BONE_IMPULSE * w * rb.mass, point - rb.global_position)


# =================================================================================================
# Helpers
# =================================================================================================

## Push direction of a hit: its impulse, else from the source through the hit point / the body.
func _dir_of(from_pos: Vector3, impulse: Vector3, point: Vector3) -> Vector3:
	if impulse.length_squared() > 1e-4:
		return impulse.normalized()
	var c: Vector3 = point if point != Vector3.INF else host.global_position + host.global_transform.basis.y
	if from_pos != Vector3.ZERO and c.distance_squared_to(from_pos) > 1e-4:
		return (c - from_pos).normalized()
	return host.global_transform.basis.z


func _up() -> Vector3:
	return _up_at(host.global_position)


func _up_at(p: Vector3) -> Vector3:
	var b: Node3D = Game.dominant_body(p)
	if b != null and b.has_method("up_at"):
		return b.up_at(p)
	var g: Vector3 = Game.gravity_at(p)
	return -g.normalized() if g.length_squared() > 1e-4 else host.global_transform.basis.y


func _gravity() -> float:
	return maxf((Game.gravity_at(host.global_position) as Vector3).length(), 0.5)


## Ground under p along up: the visible terrain / structures first (a physics ray: collision exists
## near the camera), else the EXACT density (dug ground counts). (The fast density march skips the
## ±1.3 m detail noise: a get-up there stood the body in the air.)
func _ground_below(p: Vector3, up: Vector3) -> Vector3:
	var q := PhysicsRayQueryParameters3D.create(p + up * 1.2, p - up * 2.5, Game.LAYER_TERRAIN | Game.LAYER_SHIP)
	var hit := host.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		return hit["position"]
	var b: Node3D = Game.dominant_body(p)
	if b != null and b.has_method("raycast_density"):
		var h: Dictionary = b.raycast_density(p + up * 1.2, p - up * 2.5, 0.25, false)
		if not h.is_empty():
			return h["position"]
	return p - up * 0.4


# =================================================================================================
# The player's side
# =================================================================================================

## The local player getting hit (scripts/player/player.gd: take_damage -> on_hit, after the hp and the
## hit's impulse; on a multiplayer client the host's hits arrive through net_hurt -> take_damage, so it
## all runs on the victim's machine). Every hit:
##   aim punch     the view kicked away from the shooter (player._punch: it recovers fast), by damage
##   knockback     a real velocity kick along the hit (HR_P_KB_PER_DMG, a little up, ~half crouched),
##                 on top of the hit's own impulse; the step's change stays under RAGDOLL_PUSH (the
##                 existing tumble threshold is for the big shoves); a loosened grip lets it skid
##   tagging       a short slowdown (speed_mult, read by the move code)
##   weapon jolt   the held item's `kick` (item.gd, consumed by the view model)
##   the body      the own astronaut reels at the struck part (body view, shadow, remote mirrors)
## Heavy (HR_P_HEAVY damage or a HR_P_HEAVY_IMPULSE shove below the tumble): a stumble: camera roll and
## pitch on a slower spring (cam_rot), a deeper crouch dip (the landing spring).
## Emits player.hit_reacted(kind, dir, strength, bone): "flinch" / "stagger" (heavy), dir × strength =
## the velocity change (impulse + kick).
class PlayerFeel extends RefCounted:
	var _tag := 0.0
	var _tag_len := 0.3
	var _tag_k := 0.0
	var _grip := 0.0
	var _grip_len := 0.3
	var _grip_k := 1.0
	var _sa := Vector3.ZERO            # stumble camera spring (pitch, yaw, roll) and its velocity
	var _sv := Vector3.ZERO
	var _last_point := Vector3.INF     # the last hit (a ragdoll right after it gets a kick there)
	var _last_dir := Vector3.ZERO
	var _last_frame := -1000
	var _last_part := ""

	func on_hit(p, amount: float, from_pos: Vector3, impulse: Vector3) -> void:
		if p == null:
			return
		var up: Vector3 = p.global_transform.basis.y
		var dir := Vector3.ZERO
		if impulse.length_squared() > 1e-4:
			dir = impulse.normalized()
		elif from_pos != Vector3.ZERO:
			dir = (p.global_position + up * 1.1 - from_pos).normalized()
		_last_point = Game.hit_pos
		_last_dir = dir
		_last_frame = Engine.get_physics_frames()
		_last_part = ""
		if _last_point != Vector3.INF and p.astronaut != null:
			_last_part = p.astronaut.part_at(_last_point)
		if p.is_dead() or float(p.hp) <= 0.0 or p.vehicle != null or p.is_ragdolled():
			return
		var cam: Camera3D = p.camera
		var k := clampf(amount / Balance.HR_P_TAG_REF, 0.15, 1.0)
		var rp = p.get("RAGDOLL_PUSH")
		var tumble := float(rp) if rp != null else 7.5
		# Aim punch, away from the shooter: hit from the front -> the head goes back (view up), from
		# the right -> the view turns and rolls to the left.
		var lc := cam.global_transform.basis.orthonormalized().inverse() * dir if dir != Vector3.ZERO else Vector3(0, 0, -0.5)
		p._punch += Vector3(lc.z * 0.8 + 0.25, -lc.x, -lc.x * 0.8) * Balance.HR_P_PUNCH * k
		# Tagging.
		var tl := lerpf(0.25, Balance.HR_P_TAG_TIME, k)
		var cur := _tag_k * (_tag / _tag_len) if _tag > 0.0 else 0.0
		if k >= cur:
			_tag_k = k
			_tag_len = tl
			_tag = tl
		# Weapon jolt.
		var it = p.current()
		if it != null and it.get("kick") != null:
			it.kick = maxf(float(it.kick), 0.15 + 0.35 * k)
		# Knockback kick on top of the hit's own impulse (already in the velocity).
		var flat := dir - up * dir.dot(up)
		var add := Vector3.ZERO
		if flat.length_squared() > 1e-6:
			var crouch := clampf(float(p.crouch_k), 0.0, 1.0)
			var kb := minf(amount * Balance.HR_P_KB_PER_DMG, Balance.HR_P_KB_MAX) * lerpf(1.0, Balance.HR_P_CROUCH_RESIST, crouch)
			add = flat.normalized() * kb + up * kb * Balance.HR_P_LIFT
			var room := tumble - 0.6 - impulse.length()
			add = add.limit_length(room) if room > 0.0 else Vector3.ZERO
			p.velocity += add
		var il := impulse.length()
		var heavy := amount >= Balance.HR_P_HEAVY or (il >= Balance.HR_P_HEAVY_IMPULSE and il < tumble)
		# A loosened grip: the knockback skids instead of stopping dead.
		_grip_k = lerpf(0.7, 0.3, k) if not heavy else 0.25
		_grip_len = 0.2 + 0.25 * k + (0.2 if heavy else 0.0)
		_grip = _grip_len
		var part := _last_part
		if heavy:
			var hk := clampf(maxf(amount / 60.0, il / tumble), 0.4, 1.0)
			_sv += Vector3(lc.z * 1.6 + randf_range(-0.4, 0.4), -lc.x * 0.8, -lc.x * 3.2 + randf_range(-0.8, 0.8)) * hk
			p._land_vel -= 0.3 * hk
		if p.astronaut != null and dir != Vector3.ZERO:
			p.astronaut.apply_hit(dir, k * 1.2, part == "head", Game.hit_pos)
		var dv := add + impulse
		if p.has_signal("hit_reacted"):
			p.emit_signal("hit_reacted", "stagger" if heavy else "flinch", dv.normalized() if dv.length_squared() > 1e-6 else dir,
					dv.length(), part)

	## The player went ragdoll (player.ragdoll: a big shove, a hard landing, death): a hit within the
	## last few physics frames kicks its part (a leg shot topples differently from a head shot), the
	## stumble state ends; hit_reacted "knockdown" (alive) / "death" (the death's ragdoll) with the launch
	## velocity (multiplayer: the other screen's avatar repeats it).
	func on_ragdoll(p, rag, vel: Vector3) -> void:
		_sa = Vector3.ZERO
		_sv = Vector3.ZERO
		_tag = 0.0
		_grip = 0.0
		var part := ""
		if Engine.get_physics_frames() - _last_frame <= 3 and _last_point != Vector3.INF and _last_dir != Vector3.ZERO \
				and rag != null and is_instance_valid(rag):
			part = _last_part
			var bodies = rag.get("bodies")
			var b = (bodies as Dictionary).get(part) if bodies is Dictionary else null
			if b is RigidBody3D:
				var rb := b as RigidBody3D
				Ragdoll.kick_part(rb, _last_dir * Balance.HR_BONE_IMPULSE * rb.mass, _last_point - rb.global_position)   # (ragdoll.gd: not apply_impulse on a fresh ragdoll)
		if p != null and p.has_signal("hit_reacted"):
			p.emit_signal("hit_reacted", "death" if p.is_dead() else "knockdown",
					vel.normalized() if vel.length_squared() > 1e-6 else Vector3.ZERO, vel.length(), part)

	## Walking speed × (the move code): tagged hits slow it, easing back.
	func speed_mult() -> float:
		if _tag <= 0.0:
			return 1.0
		return 1.0 - Balance.HR_P_TAG_SLOW * _tag_k * clampf(_tag / _tag_len, 0.0, 1.0)

	## Ground acceleration × (the move code): < 1 right after a hit, so the knockback skids.
	func grip() -> float:
		if _grip <= 0.0:
			return 1.0
		return lerpf(1.0, _grip_k, clampf(_grip / _grip_len, 0.0, 1.0))

	## Every frame on foot: the timers and the stumble spring; returns the camera rotation to add.
	func cam_rot(_p, delta: float) -> Vector3:
		_tag = maxf(_tag - delta, 0.0)
		_grip = maxf(_grip - delta, 0.0)
		if _sa == Vector3.ZERO and _sv == Vector3.ZERO:
			return Vector3.ZERO
		var n := int(ceilf(delta / 0.016))
		var h := delta / float(maxi(n, 1))
		for i in n:
			_sv += (-_sa * 60.0 - _sv * 9.0) * h
			_sa += _sv * h
		_sa = _sa.limit_length(0.25)
		if _sa.length_squared() < 1e-8 and _sv.length_squared() < 1e-6:
			_sa = Vector3.ZERO
			_sv = Vector3.ZERO
		return _sa
