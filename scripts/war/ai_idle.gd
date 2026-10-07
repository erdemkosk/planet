extends RefCounted
## Natural idle for a bot that is not going anywhere (2026-10-07, the user: "yapay zekalar kütük gibi
## duruyor, doğal görünmüyorlar"). One per bot (scripts/war/ai_rival.gd owns it: `_idle`), cosmetic
## and cheap: it only acts for bots near the camera that the role's work leaves standing, and only
## through what the bot already has: the body-language look and gestures (astronaut.gd "Body
## language": look_dir / gesture via the bot's _bl_look / _bl_gesture, so multiplayer puppets get
## them too), the crouch hold (_crouch_hold), a short walk (_move_to at IDLE_STEP_SPEED) and the
## miner's dig site. The weight shift is an additive upper-body pose after astronaut.animate.
##
## Driven by two one-line hooks in ai_rival.gd:
##   _think (after _think_work, WORK only)        _idle.think(self, dt)
##   _process (after astronaut.animate, before
##             astronaut.sync_skeleton)           _idle.pose(self, dt)
## What it does (all per bot, staggered, random gaps; never in COMBAT, never on a weapon / dig / pod
## task, never during a body-language pause or gesture):
##   look      every LOOK_GAP s standing: the head (and a little of the chest) turns to something: the
##             spot of a recent threat (more often while it is fresh), the other planet up in the sky,
##             a teammate close by, the base, a slow sweep of the ground ahead; a miner looks at its pit;
##             walking about (not a guard: its patrol scan is the bot's own) a glance every ~2 LOOK_GAP
##   shift     the weight moves from one leg to the other every SHIFT_GAP s (spine / chest roll, the
##             head kept level), a slight settle forward after a step or a kneel (pose, lod 0 / 1)
##   step      guards / raid guards / idle bots: now and then a short turn-and-step (STEP_LEN m) to
##             watch another sector, kept within STEP_LEASH m of the guard's waypoint
##   kneel     guards on watch take a knee now and then (KNEEL_GAP, KNEEL_TIME)
##   radio     now and then a radio check: the head down toward the left shoulder, then a nod
##   digging   (its own spot, any role) a kneel-dig cycle: kneeling MINER_KNEEL s with the beam, then straightening
##             up for MINER_PAUSE s (beam off: the bot's "rest" pause; a look around, a visor wipe or a
##             stretch), every MINER_MOVE_EVERY-th cycle moving MINER_MOVE m to a fresh patch
## The bot's own idle life (ai_rival.gd _bl_idle_life: look around / stretch / check the rifle / wipe
## the visor every BL_IDLE_GAP s, the miner's rest, the engineer's inspection) stays as it is.
## Cost: think() is a handful of comparisons for a far bot (early out on cam_dist / lod) and one
## look direction for a near one (measured ~7 µs a call headless); pose() is six additive bone
## rotations (lod 0 / 1 only, ~8 µs a call headless).

const RANGE := 70.0                      # m from the camera (cam_dist): beyond this nothing runs
const STILL_T := 0.9                     # s standing before it counts as idle (the bot's _still_t)
const LOOK_GAP := Vector2(2.2, 5.5)      # s between two looks
const LOOK_HOLD := Vector2(1.1, 2.4)     # s a look holds
const THREAT_MEM := 25000                # ms: a threat this recent draws the looks (half of them)
const SHIFT_GAP := Vector2(3.5, 8.0)     # s between two weight shifts
const SHIFT_T := 1.3                     # s: the shift's blend (time constant)
const SHIFT_ROLL := 0.07                 # rad of spine roll at a full shift (chest / head counter it)
const STEP_GAP := Vector2(7.0, 16.0)     # s standing between two steps (when the dice say so)
const STEP_CHANCE := 0.45
const STEP_LEN := Vector2(0.55, 1.0)     # m
const STEP_TURN := Vector2(0.35, 1.2)    # rad: the new facing, either side of the old one
const STEP_LEASH := 1.0                  # m from a guard's waypoint (its walk-back radius is 1.2 m)
const STEP_SPEED := 1.1                  # m/s: an unhurried step (AI_WALK_SPEED is 3.2)
const STEP_TIME := 2.5                   # s at most for a step
const STEP_JOBS := ["", "guard", "raid_guard"]
const KNEEL_GAP := Vector2(18.0, 40.0)   # s between two kneels on watch
const KNEEL_TIME := Vector2(3.0, 7.0)
const KNEEL_JOBS := ["guard", "raid_guard"]
const RADIO_GAP := Vector2(25.0, 55.0)
const MINER_KNEEL := Vector2(7.0, 13.0)  # s kneeling with the beam...
const MINER_PAUSE := Vector2(1.6, 3.2)   # ...then up, beam off, this long
const MINER_MOVE_EVERY := 3              # every this many cycles: to a fresh patch...
const MINER_MOVE := 1.8                  # ...this far (more than the 1.2 m arrival radius: it walks)
const DIG_JOBS := [""]                    # digging its own spot (the gather work): the kneel-dig cycle (not a shaft / vein)
const MODE_WORK := 0                     # (ai_rival.gd Mode.WORK)

var _rng := RandomNumberGenerator.new()
var _look_ms := 0
var _step_ms := 0
var _kneel_ms := 0
var _kneel_until := 0
var _radio_ms := 0
var _step := Vector3.INF                 # the step's target while it walks
var _step_face := Vector3.ZERO
var _step_end := 0
var _shift := 0.0                        # -1..1, blended
var _shift_to := 0.0
var _shift_ms := 0
var _settle := 0.0                       # 0..1: the forward settle after a step / kneel
var _m_phase := ""                       # miner: "", "kneel", "up"
var _m_until := 0
var _m_cycles := 0
var _active := false


func _init(seed_v := 0) -> void:
	_rng.seed = hash(seed_v) if seed_v != 0 else randi()
	var now := Time.get_ticks_msec()
	_look_ms = now + _rng.randi_range(500, 4000)
	_step_ms = now + _rng.randi_range(4000, 12000)
	_kneel_ms = now + _rng.randi_range(8000, 30000)
	_radio_ms = now + _rng.randi_range(10000, 40000)
	_shift_ms = now + _rng.randi_range(500, 3000)


## True while an idle step is walking (the bot's own code may want to know).
func stepping() -> bool:
	return _step != Vector3.INF


## Drops whatever it was doing (combat, death, a task): the bot's own state is left to the bot.
func reset() -> void:
	_step = Vector3.INF
	_m_phase = ""
	_kneel_until = 0
	_active = false


# --- Think (the bot's think rate, WORK only) --------------------------------------------------------

func think(bot, dt: float) -> void:
	if bot.mode != MODE_WORK or bot.cam_dist > RANGE or int(bot.lod) > 1 or not bot.visible:
		if _active:
			_end_step(bot)
			reset()
		return
	if str(bot._dg_task) != "" or str(bot._wx_task) != "" or str(bot._pod_phase) != "" or bot.foothold != null:
		if _active:
			_end_step(bot)
			reset()
		return
	_active = true
	var now := Time.get_ticks_msec()
	if _step != Vector3.INF and _step_tick(bot, now):
		return
	if bool(bot._digging) and str(bot._job) in DIG_JOBS and not bool(bot._shaft):
		_miner(bot, now, dt)
		return
	if _m_phase != "" and not bool(bot._digging) and now > _m_until:
		_m_phase = ""
	# Standing (the work wants it here): looks, a kneel, a step, a radio check.
	var job := str(bot._job)
	var standing: bool = bot._move_to == Vector3.INF and bot._strafe == Vector3.ZERO and float(bot._still_t) > STILL_T
	if now < int(bot._bl_pause_ms) or bot.astronaut.gesture_kind() != "":
		return
	if not standing:
		# Walking about (not a guard: its patrol scan is the bot's own): a glance now and then.
		if now > _look_ms and job != "guard" and job != "raid_guard" and float(bot.velocity.length()) > 0.5:
			_look_ms = now + _ms(LOOK_GAP) * 2
			var pw := _look_target(bot, now)
			if pw != Vector3.INF:
				bot._bl_look(bot._bl_local(pw), _rng.randf_range(0.8, 1.5))
		return
	if _kneel_until > 0:
		if now < _kneel_until and job in KNEEL_JOBS:
			bot._crouch_hold = maxf(float(bot._crouch_hold), dt + 0.35)     # (decays fast once it stops)
		else:
			_kneel_until = 0
			_settle = 1.0
	elif now > _kneel_ms and job in KNEEL_JOBS:
		_kneel_ms = now + _ms(KNEEL_GAP)
		var kt := _ms(KNEEL_TIME)
		_kneel_until = now + kt
		_settle = 1.0
		if job == "guard":
			bot._guard_wait = maxf(float(bot._guard_wait), float(kt) / 1000.0)   # (stays at its waypoint meanwhile)
		bot._crouch_hold = maxf(float(bot._crouch_hold), dt + 0.35)
		return
	if now > _step_ms and job in STEP_JOBS and _kneel_until == 0 and not bool(bot._digging):
		_step_ms = now + _ms(STEP_GAP)
		if _rng.randf() < STEP_CHANCE and _start_step(bot, now):
			return
	if now > _radio_ms and str(bot._held) == "rifle":
		_radio_ms = now + _ms(RADIO_GAP)
		var up: Vector3 = bot._up()
		var b: Basis = bot.global_transform.basis
		bot._bl_look(bot._bl_local(bot._eye() - b.z * 0.5 - b.x * 0.6 - up * 0.7), 1.1)
		bot._bl_gesture("nod", Vector3.FORWARD, true)
		_look_ms = now + 1800
		return
	if now > _look_ms:
		_look_ms = now + _ms(LOOK_GAP)
		var p := _look_target(bot, now)
		if p != Vector3.INF:
			bot._bl_look(bot._bl_local(p), _rng.randf_range(LOOK_HOLD.x, LOOK_HOLD.y))


## Something worth a look from where it stands (world point), INF for none.
func _look_target(bot, now: int) -> Vector3:
	var up: Vector3 = bot._up()
	var eye: Vector3 = bot._eye()
	var fwd: Vector3 = -bot.global_transform.basis.z
	if now - int(bot._threat_ms) < THREAT_MEM and bot._threat_pos != Vector3.INF and _rng.randf() < 0.5:
		var tp: Vector3 = bot._threat_pos
		var side := up.cross(tp - eye).normalized()
		return tp + side * _rng.randf_range(-6.0, 6.0)          # around where it came from
	var r := _rng.randf()
	if r < 0.14:
		var other = Game.planet if str(bot.team) == "rival" else Game.rival
		if other != null and is_instance_valid(other):
			return (other as Node3D).global_position              # the other planet in the sky
	elif r < 0.3 and bot.team_node != null:
		for m in bot.team_node.bots:
			if m != bot and is_instance_valid(m) and not m.is_dead() and not m.is_aboard() \
					and (m as Node3D).global_position.distance_to(bot.global_position) < 14.0:
				return (m as Node3D).global_position + up * 1.4     # a teammate
	elif r < 0.4 and bot.team_node != null and str(bot.team) == "rival":
		var bx: Transform3D = bot.team_node.base_xf
		if bx.origin.distance_to(bot.global_position) > 8.0:
			return bx.origin + up * 1.0                              # the base
	# A sweep: somewhere ahead or to the side, mostly at the ground some way off.
	var yaw := _rng.randf_range(-1.25, 1.25)
	var d := fwd.rotated(up, yaw)
	return eye + d * _rng.randf_range(8.0, 25.0) - up * _rng.randf_range(0.5, 2.5)


## A turn-and-step to watch another sector: the new facing ±STEP_TURN, STEP_LEN m that way (near a
## guard's waypoint), at STEP_SPEED. False when there is no room for one.
func _start_step(bot, now: int) -> bool:
	if float(bot._wx_depth()) > 0.6:
		return false                                             # (in a pit / hole: stays)
	var up: Vector3 = bot._up()
	var pos: Vector3 = bot.global_position
	var fwd: Vector3 = -bot.global_transform.basis.z
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var turn := _rng.randf_range(STEP_TURN.x, STEP_TURN.y) * (1.0 if _rng.randf() < 0.5 else -1.0)
	var dir := fwd.rotated(up, turn)
	var tgt := pos + dir * _rng.randf_range(STEP_LEN.x, STEP_LEN.y)
	if str(bot._job) == "guard" and bot._guard_wp != Vector3.INF:
		var wp: Vector3 = bot._guard_wp
		var off := tgt - wp
		off -= up * off.dot(up)
		if off.length() > STEP_LEASH:
			tgt = wp + off.normalized() * STEP_LEASH                 # (within its waypoint's reach)
			if tgt.distance_to(pos) < 0.35:
				return false
	_step = tgt
	_step_face = dir
	_step_end = now + int(STEP_TIME * 1000.0)
	bot._move_to = _step
	bot._move_speed = STEP_SPEED
	bot._strafe = Vector3.ZERO
	return true


## The step under way: re-asserts it while the work leaves the bot standing; true while it walks.
func _step_tick(bot, now: int) -> bool:
	var mt: Vector3 = bot._move_to
	if mt != Vector3.INF and mt != _step:
		_step = Vector3.INF                                       # the work wants it elsewhere
		return false
	var up: Vector3 = bot._up()
	var off: Vector3 = _step - bot.global_position
	off -= up * off.dot(up)
	if off.length() < 0.25 or now > _step_end or bot.astronaut.gesture_kind() != "":
		_end_step(bot)
		return false
	bot._move_to = _step
	bot._move_speed = STEP_SPEED
	return true


func _end_step(bot) -> void:
	if _step == Vector3.INF:
		return
	if bot._move_to == _step:
		bot._move_to = Vector3.INF
	_step = Vector3.INF
	if _step_face != Vector3.ZERO:
		bot._face = _step_face                                    # keeps facing the new sector
	_settle = 1.0
	_look_ms = mini(_look_ms, Time.get_ticks_msec() + 600)       # and soon looks over it


## The miner's kneel-dig cycle (from think while its beam is on at its own site).
func _miner(bot, now: int, dt: float) -> void:
	match _m_phase:
		"", "up":
			_m_phase = "kneel"
			_m_until = now + _ms(MINER_KNEEL)
			_settle = 1.0
		"kneel":
			bot._crouch_hold = maxf(float(bot._crouch_hold), dt + 0.35)
			if now > _look_ms and bot.astronaut.gesture_kind() == "":
				_look_ms = now + _ms(LOOK_GAP) + 1500
				var dp: Vector3 = bot._dig_point
				if dp != Vector3.ZERO and _rng.randf() < 0.6:
					bot._bl_look(bot._bl_local(dp), _rng.randf_range(1.2, 2.2))     # at the pit
				else:
					var p := _look_target(bot, now)
					if p != Vector3.INF:
						bot._bl_look(bot._bl_local(p), _rng.randf_range(0.9, 1.6))
			if now < _m_until:
				return
			# Up: beam off a moment ("rest" pause: _bl_hold_work stops the dig), a look / wipe / stretch.
			var t := _rng.randf_range(MINER_PAUSE.x, MINER_PAUSE.y)
			_m_cycles += 1
			_m_phase = "up"
			_m_until = now + int(t * 1000.0)
			_settle = 1.0
			bot._bl_pause(t, "rest")
			var r := _rng.randf()
			if r < 0.25:
				bot._bl_gesture("wipe_visor")
			elif r < 0.4 and t > 2.3:
				bot._bl_gesture("stretch")
			else:
				var p2 := _look_target(bot, now)
				if p2 != Vector3.INF:
					bot._bl_look(bot._bl_local(p2), t * 0.8)
			if _m_cycles % MINER_MOVE_EVERY == 0 and str(bot._job) == "" and bot._dig_site != Vector3.INF:
				# A fresh patch beside the old one: the gather code walks there after the pause.
				var up: Vector3 = bot._up()
				var b: Basis = bot.global_transform.basis
				var side: Vector3 = (b.x if _rng.randf() < 0.5 else -b.x) + (-b.z) * _rng.randf_range(-0.4, 0.6)
				side -= up * side.dot(up)
				if side.length_squared() > 1e-4:
					bot._dig_site = bot._ground_at(bot.global_position + side.normalized() * MINER_MOVE + up * 1.5)


# --- Pose (the bot's pose rate, after astronaut.animate) --------------------------------------------

## The weight shift and the settle: additive upper-body rotations (animate sets the bones fresh every
## call, so nothing accumulates). Near bots only; fades out while walking, crouched or in combat.
func pose(bot, dt: float) -> void:
	if int(bot.lod) > 1 or bot.cam_dist > RANGE:
		return
	var now := Time.get_ticks_msec()
	if now > _shift_ms:
		_shift_ms = now + _ms(SHIFT_GAP)
		_shift_to = _rng.randf_range(0.45, 1.0) * (-1.0 if _shift_to > 0.0 else 1.0)
	var calm := 1.0 if (bot.mode == MODE_WORK and float(bot._still_t) > 0.4) else 0.0
	calm *= 1.0 - clampf(float(bot._crouch_k), 0.0, 1.0)
	_shift = lerpf(_shift, _shift_to * calm, 1.0 - exp(-dt / SHIFT_T))
	_settle = maxf(_settle - dt * 0.9, 0.0)
	var a = bot.astronaut
	if absf(_shift) > 0.002:
		var s := _shift * SHIFT_ROLL
		a.spine.rotation.z += s
		a.chest.rotation.z -= s * 0.55
		a.head.rotation.z -= s * 0.35
		a.spine.rotation.y += s * 0.25                         # the hips turn a little under the shift
	if _settle > 0.002:
		var k := sin(_settle * PI) * 0.06 * calm
		a.spine.rotation.x -= k
		a.head.rotation.x += k * 0.6


func _ms(r: Vector2) -> int:
	return int(_rng.randf_range(r.x, r.y) * 1000.0)
