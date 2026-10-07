extends Node
## Sound occlusion (Game.sfx.acoustics.occlusion, a child of scripts/audio/acoustics.gd): world
## sounds behind soil, a hill, a crater rim or a structure reach the listener muffled and quieter,
## so an enemy digging in a tunnel or firing beyond a ridge can be placed by ear.
##   Tracking  every AudioStreamPlayer3D in the tree (get_tree().node_added + one sweep at start;
##             non-owning refs, dropped on tree_exiting), without touching the scripts that create
##             them. Each physics frame (late: process_physics_priority) every player's playing flag
##             is read (new plays); the playing ones get a full update (position, bases, route,
##             level) on a new play and every FULL_EVERY-th frame (staggered). Eligible: bus "Env" /
##             "Master" (the world route in the air; not the vacuum buses of sfx.gd) or "Skiff" (other
##             ships), not your own / your vehicle's sounds, not stream_paused, audible
##             (INAUDIBLE_DB). Ranked by the estimated level at the ear: the MAX_ACTIVE loudest are
##             managed, the rest keep their last values.
##   Rays      listener (camera) -> source (lifted SRC_LIFT off the ground, less under a ceiling),
##             re-evaluated RATE_NEAR..RATE_FAR Hz by distance (density marches FAR_IV_K slower), at
##             once when either end moved MOVE_M, only every STILL_T s when neither moved (dug ground;
##             a Game.blast re-checks all), most overdue / loudest first, within EVAL_USEC per
##             physics frame. A new play (or a pooled player re-used far away) is evaluated at once
##             and snaps (a gunshot's attack must already be muffled): reuses its own fresh result or
##             a recent one of the same CELL, else spends up to NEW_USEC.
##             Near (PHYS_R, collision exists): physics rays on LAYER_TERRAIN | LAYER_SHIP (the
##             source's own structure excluded). The centre line decides: clear = clear (a source in
##             your own tunnel stays clear). Blocked: a reverse ray finds the exit point (chord =
##             exit - entry; none = the source is buried) and two offset rays (SIDE_OFF left / right,
##             SIDE_UP up) give the partial amount 1/3 (just behind an edge), 2/3, 1. A structure
##             (LAYER_SHIP) is judged by that alone; soil also by how far below the surface the line
##             passes (a few density samples between entry and exit): partial capped to 1/3 below
##             DEEP_HALF, 2/3 below DEEP_FULL, thickness = min(chord, DEEP_THICK_K × depth). On the
##             60 m planet the horizon is ~14 m away: a long shallow chord under its curve is a short
##             detour for the sound, not a hill.
##             Far, or no collision (fast listener, acoustics' density mode): physics for the first
##             PHYS_R m, then a density march (planet.density_fast: no ±1.3 m detail, no natural
##             caves; soil counts only SOLID_EPS m below the smooth surface, END_TRIM m kept free at
##             the ends) through every body: solid metres and the deepest point, mapped the same way.
##   Mapping   severity = smoothstep(THIN_M, THICK_M, thickness); amount = partial × k, both smoothed
##             (SMOOTH_T, ~0.2 s): the player's attenuation-filter cut-off from its own value toward
##             CUT_THIN..CUT_THICK, a duck DUCK_THIN..DUCK_THICK dB and a high shelf
##             SHELF_THIN..SHELF_THICK dB above that cut-off.
##   Engine    AudioStreamPlayer3D's attenuation filter is a high shelf at attenuation_filter_cutoff_hz
##             whose depth is (1 - min(1, distance gain)) × attenuation_filter_db: none for a near /
##             loud source. The missing depth rides on the emission-angle cut (enabled at 0.1°, so it
##             always applies; its filter_attenuation_db = target - the distance shelf), which works at
##             any distance. The duck scales unit_size (+ lowers max_db, which clamps near sources)
##             instead of writing volume_db, which several scripts fade in place (lerp of their own
##             value: auto_miner, core_shield, radar_tower, torpedo_rig).
##   Bases     a player's own unit_size / max_db / cut-off / emission settings are captured while it is
##             untouched, re-captured whenever a script writes a value other than ours (per-play set-ups
##             such as sfx.play_at), and restored when the occlusion clears, the player leaves the tree
##             or this node exits.
##   k         per-node meta "occlusion_k" (0 = never occluded .. 1 = full) if the creator sets it;
##             default 1, LOUD_K for big booms (unit_size >= LOUD_UNIT: explosion.gd's blast / debris
##             / sub layers, cannons, flak, buster, distant reports: heard through the ground with
##             their low end), LOUD_DB_K for players at volume_db >= LOUD_DB.
## Vacuum: sfx.gd routes sources off the air buses there; the listener in vacuum = every source clear.
## DEBUG (or the var `debug` at run time) prints the stats every 2 s: counts, rays / marches per
## second, the cost per physics frame split into poll / rays / apply.

const Bodies := preload("res://scripts/planet/bodies.gd")

const DEBUG := false
const MAX_ACTIVE := 40               # loudest playing sources managed; the rest keep their last values
const FULL_EVERY := 6                # physics frames between a playing player's full updates (staggered)
const EVAL_USEC := 450               # ray time per physics frame for the regular re-evaluations
const NEW_USEC := 900                # ...ceiling for the immediate evaluations of new plays
const MAX_EVALS := 14                # evaluations per physics frame (new plays: +6)
const RATE_NEAR := 15.0              # Hz: re-evaluation of a near source (NEAR_M)...
const RATE_FAR := 3.0                # ...falling to this at FAR_M
const NEAR_M := 20.0
const FAR_M := 120.0
const MOVE_M := 2.5                  # m: listener / source moved this far since the last ray -> due now
const STILL_M := 0.4                 # m: neither end moved more than this...
const STILL_T := 1.0                 # ...-> re-checked only this often (dug ground; a blast forces it)
const FAR_IV_K := 2.0                # interval factor for the density-march evaluations
const INAUDIBLE_DB := -66.0          # estimated level at the ear below which a source is not managed
const PHYS_R := 40.0                 # m: physics rays this far from the camera (collision ~45-48 m)
const PHYS_MAX_SPEED := 18.0         # m/s: a faster listener outruns the collision shapes: density
const CLEAR_M := 1.2                 # nearer sources are never occluded
const EAR_MARGIN := 0.15             # m: the rays start this far from the camera...
const SRC_MARGIN := 0.45             # ...and stop this short of the source (its own housing)
const SRC_LIFT := 0.6                # m: the source point is lifted off the ground (bots' players sit at the feet)
const SIDE_OFF := 0.6                # m: offset rays left / right of the line...
const SIDE_UP := 0.3                 # ...and up (crater rims are edges above the line)
const EAR_SPREAD := 0.25             # the offset at the ear end (× SIDE_OFF: stays inside a tunnel)
const THIN_DEFAULT := 1.0            # m: thickness when the rays cannot measure it (a structure wall)
const JUMP_M := 15.0                 # m between full updates: a pooled player re-used elsewhere = a new play
const SMOOTH_T := 0.08               # s: amount / severity smoothing (~90 % in 0.2 s); new plays snap
const CELL := 4.0                    # m: cache of recent results for new plays when the budget is spent
const CELL_TTL := 0.5                # s
const CELL_MAX := 512
# Density march.
const MARCH_STEP := 1.0              # m: minimum step (air: 0.7 × height above the ground)
const MARCH_SOLID_MAX := 3.0         # m: maximum step inside the soil (still finds dug tunnels)
const MARCH_MAX := 160               # samples per body at most
const SOLID_EPS := 0.6               # m below the smooth surface before a sample counts as soil
const MIN_SOLID := 0.5               # m of soil before a line counts as blocked
const END_TRIM := 1.5                # m at each end not counted (endpoints on / in the ground)
const DEEP_HALF := 1.2               # m: deepest point below the surface -> partial 1/3 below, 2/3...
const DEEP_FULL := 2.5               # ...and full from here
const DEEP_THICK_K := 3.0            # soil thickness counts at most this × the deepest point (detour)
const DEEP_SAMPLE_M := 1.5           # m between the depth samples along a blocked near line
# Mapping (severity 0 = thin crater rim, 1 = a hill).
const THIN_M := 0.5
const THICK_M := 8.0
const CUT_THIN := 2400.0             # Hz: fully occluded cut-off behind a thin rim...
const CUT_THICK := 700.0             # ...and behind a hill
const DUCK_THIN := -4.0              # dB
const DUCK_THICK := -12.0
const SHELF_THIN := -16.0            # dB above the cut-off (total with the distance shelf)
const SHELF_THICK := -30.0
const LOUD_UNIT := 16.0              # unit_size of the big booms...
const LOUD_K := 0.5                  # ...occluded this much
const LOUD_DB := 4.0
const LOUD_DB_K := 0.75



## One tracked AudioStreamPlayer3D.
class Src:
	var node: AudioStreamPlayer3D     # non-owning (nodes are not reference counted)
	var id := 0
	var slot := 0                     # stagger slot of the full updates (id mod FULL_EVERY)
	var dead := false
	var playing := false
	var managed := false
	var own := false
	var applied := false              # the node carries our values (bases below)
	var k := 1.0
	var b_unit := 10.0
	var b_maxdb := 3.0
	var b_cut := 5000.0
	var b_emis := false               # the creator uses the emission angle itself: no shelf trick
	var b_emis_deg := 45.0
	var b_emis_db := -12.0
	var w_unit := 0.0                 # what we wrote (read back from the node)
	var w_maxdb := 0.0
	var w_cut := 0.0
	var w_emis_db := 0.0
	var emis_on := false              # we enabled the emission angle
	var tgt_a := 0.0                  # occlusion amount (partial × k)
	var tgt_sev := 0.0                # thickness severity
	var cur_a := 0.0
	var cur_sev := 0.0
	var snap := false
	var cand := false                 # last full update: eligible and audible
	var rel := false                  # last full update: ineligible while carrying our values
	var dirty := false                # a base changed since the last write
	var level := -80.0                # estimated dB at the ear (base values)
	var model := 0                    # attenuation_model / max_distance as of the play's start
	var max_d := 0.0
	var dist := 0.0
	var w_dist := 0.0                 # distance at the last write
	var pos := Vector3.ZERO
	var next_t := 0.0
	var iv := 0.1                     # s: re-evaluation interval
	var urg := 0.0
	var eval_t := -10.0
	var eval_src := Vector3.INF
	var eval_lis := Vector3.INF
	var res := Vector2.ZERO           # last ray result: partial, thickness (m)
	var rids: Array[RID] = []
	var rids_done := false


var _acu = null                      # acoustics.gd (parent): _density_mode
var _sfx = null                      # sfx.gd: listener_air, _is_own()
var _list: Array = []                # Src
var _by_id := {}                     # instance id -> Src
var _cells := {}                     # Vector3i -> PackedFloat32Array [partial, thickness, t, lis x, y, z]
var _query := PhysicsRayQueryParameters3D.new()
var _space: PhysicsDirectSpaceState3D = null
var _excl: Array[RID] = []
var _lis := Vector3.ZERO
var _lis_prev := Vector3.INF
var _lis_speed := 0.0
var _lis_up := Vector3.UP
var _phys_ok := true
var _rng := RandomNumberGenerator.new()
var _frame := 0
var _dead_n := 0
# Stats (debug).
var debug := DEBUG
var _st_poll := 0
var _st_eval := 0
var _st_apply := 0
var _st_t := 0.0
var _st_frames := 0
var _st_evals := 0
var _st_new := 0
var _st_reuse := 0
var _st_rays := 0
var _st_marches := 0
var _st_samples := 0
var _st_usec := 0
var _st_peak := 0
var _st_cands := 0
var _st_managed := 0
var _st_occl := 0


func _enter_tree() -> void:
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)


func _ready() -> void:
	_acu = get_parent()
	_sfx = _acu.get_parent() if _acu != null else null
	_rng.randomize()
	process_physics_priority = 100       # after the scripts that start sounds this frame
	_query.collision_mask = Game.LAYER_TERRAIN | Game.LAYER_SHIP
	if Game.has_signal("blast") and not Game.blast.is_connected(_on_blast):
		Game.blast.connect(_on_blast)
	call_deferred("_sweep")


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	for e: Src in _list:
		if not e.dead and e.applied and is_instance_valid(e.node):
			_restore(e)


## 0..1: the current occlusion amount of a player (0 when untracked / clear).
func amount_of(p: Node) -> float:
	if p == null:
		return 0.0
	var e: Src = _by_id.get(p.get_instance_id())
	return e.cur_a if e != null else 0.0


# =================================================================================================
# Tracking
# =================================================================================================

func _on_node_added(n: Node) -> void:
	if n is AudioStreamPlayer3D:
		_register(n as AudioStreamPlayer3D)


func _sweep() -> void:
	for n in get_tree().root.find_children("*", "AudioStreamPlayer3D", true, false):
		_register(n as AudioStreamPlayer3D)


func _register(p: AudioStreamPlayer3D) -> void:
	var id := p.get_instance_id()
	if _by_id.has(id):
		return
	var e := Src.new()
	e.node = p
	e.id = id
	e.slot = posmod(id, FULL_EVERY)
	_by_id[id] = e
	_list.append(e)
	p.tree_exiting.connect(_forget.bind(e), CONNECT_ONE_SHOT)


## The player leaves the tree (freed, or re-parented: it registers again on entering).
func _forget(e: Src) -> void:
	if e.dead:
		return
	e.dead = true
	_dead_n += 1
	_by_id.erase(e.id)
	if e.applied and is_instance_valid(e.node):
		_restore(e)


func _compact() -> void:
	var w := 0
	for i in _list.size():
		var e: Src = _list[i]
		if not e.dead:
			_list[w] = e
			w += 1
	_list.resize(w)
	_dead_n = 0


## A blast reshapes the ground (a crater): every source is re-checked at its next turn.
func _on_blast(_pos: Vector3, _radius: float, _team: String) -> void:
	_cells.clear()
	for e: Src in _list:
		e.eval_t = -10.0


# =================================================================================================
# Per physics frame
# =================================================================================================

func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if _sfx == null or not is_instance_valid(_sfx):
		_sfx = Game.sfx
		if _sfx == null or not is_instance_valid(_sfx):
			return
	var now := float(Time.get_ticks_msec()) * 0.001
	var off := not _listener(delta)
	var cands: Array = []
	var releasing: Array = []
	# Poll: the playing flag of every player each frame (new plays); the rest (position, bases,
	# eligibility, level) on a new play and every FULL_EVERY-th frame per player (staggered).
	_frame += 1
	var slot := _frame % FULL_EVERY
	if _dead_n > 0:
		_compact()
	for e: Src in _list:
		if e.dead or not is_instance_valid(e.node):
			if not e.dead:
				e.dead = true
				_by_id.erase(e.id)
			_dead_n += 1
			continue
		var p := e.node
		if not p.playing:
			if e.playing:
				e.playing = false
				e.managed = false
				e.cand = false
			continue
		var fresh := not e.playing
		if not fresh and e.slot != slot:
			if e.cand:
				cands.append(e)
			elif e.rel:
				releasing.append(e)
			continue
		e.cand = false
		e.rel = false
		if p.stream_paused or not p.is_inside_tree():
			e.managed = false
			continue
		var pos := p.global_position
		if pos.distance_squared_to(e.pos) > JUMP_M * JUMP_M:
			fresh = true                     # a pooled player re-used elsewhere while still playing
		e.playing = true
		e.pos = pos
		if e.applied:
			_sync_bases(e, p)
		if fresh:
			e.snap = true
			e.own = _is_own(p) or p.get_viewport() != get_viewport()   # (a sub-viewport's world: not ours)
			e.k = _k_of(p, e.b_unit if e.applied else p.unit_size)
			e.model = p.attenuation_model
			e.max_d = p.max_distance
		e.dist = pos.distance_to(_lis)
		var bus := p.bus
		if off or e.own or e.k <= 0.0 or (bus != &"Env" and bus != &"Master" and bus != &"" and bus != &"Skiff"):
			e.managed = false
			if e.applied:
				e.rel = true
				releasing.append(e)
			continue
		e.level = _level_db(e, p)
		if e.level < INAUDIBLE_DB:
			e.managed = false
			if e.snap and e.applied:
				releasing.append(e)          # a new play out of earshot: clean, not last play's values
			continue
		e.cand = true
		cands.append(e)
	# Rank: the MAX_ACTIVE loudest are managed (native sort of the levels for the threshold).
	var thresh := -INF
	if cands.size() > MAX_ACTIVE:
		var lv := PackedFloat32Array()
		lv.resize(cands.size())
		for i in cands.size():
			lv[i] = (cands[i] as Src).level
		lv.sort()
		thresh = lv[cands.size() - MAX_ACTIVE]
	var managed: Array = []
	for e: Src in cands:
		e.managed = e.level >= thresh and managed.size() < MAX_ACTIVE
		if e.managed:
			managed.append(e)
		elif e.snap and e.applied:
			releasing.append(e)              # a new play over the cap: clean (its last values were elsewhere)
		else:
			e.snap = false                   # over the cap: keeps its last values
	# Rays: new plays first (snap), then the most overdue / loudest.
	var t1 := Time.get_ticks_usec()
	var evals := 0
	var due: Array = []
	for e: Src in managed:
		if e.snap:
			if _reuse(e, now):
				continue
			if evals < MAX_EVALS + 6 and Time.get_ticks_usec() - t1 < NEW_USEC:
				_evaluate(e, now)
				evals += 1
				_st_new += 1
			else:
				# No budget: keep the old result only if it was taken near here, else start open.
				if not (e.eval_src.distance_squared_to(e.pos) < 36.0):
					e.tgt_a = 0.0
				e.next_t = 0.0
				e.urg = 99.0
				due.append(e)
		else:
			var lm := e.eval_lis.distance_squared_to(_lis)
			var sm := e.eval_src.distance_squared_to(e.pos)
			if lm < MOVE_M * MOVE_M and sm < MOVE_M * MOVE_M:
				if now < e.next_t:
					continue
				if lm < STILL_M * STILL_M and sm < STILL_M * STILL_M and now - e.eval_t < STILL_T:
					e.next_t = now + e.iv        # neither end moved: only a dug / blasted ground changes it
					continue
			e.urg = (now - e.next_t) / e.iv + clampf((e.level + 60.0) / 30.0, 0.0, 2.0)
			due.append(e)
	if due.size() > MAX_EVALS:
		due.sort_custom(func(x: Src, y: Src) -> bool: return x.urg > y.urg)
	for e: Src in due:
		if evals >= MAX_EVALS or Time.get_ticks_usec() - t1 > EVAL_USEC:
			break
		_evaluate(e, now)
		evals += 1
	# Apply (smoothed; new plays snap).
	var t2 := Time.get_ticks_usec()
	var ks := 1.0 - exp(-delta / SMOOTH_T)
	var occl := 0
	for e: Src in managed:
		_apply(e, ks)
		if e.cur_a > 0.05:
			occl += 1
	for e: Src in releasing:
		e.tgt_a = 0.0
		_apply(e, ks)
	if _cells.size() > CELL_MAX:
		_cells.clear()
	if debug:
		var t3 := Time.get_ticks_usec()
		var us := t3 - t0
		_st_usec += us
		_st_poll += t1 - t0
		_st_eval += t2 - t1
		_st_apply += t3 - t2
		_st_peak = maxi(_st_peak, us)
		_st_frames += 1
		_st_evals += evals
		_st_cands = cands.size()
		_st_managed = managed.size()
		_st_occl = occl
		_debug_print(now)


## Listener (the camera), its speed and up, the physics space; false = every source clear (vacuum,
## no world).
func _listener(delta: float) -> bool:
	var cam := get_viewport().get_camera_3d()
	var l: Vector3 = cam.global_position if cam != null else _sfx.listener_pos
	if _lis_prev != Vector3.INF:
		var v := l.distance_to(_lis_prev) / maxf(delta, 0.001)
		if v < 400.0:                    # a teleport / respawn is not a speed
			_lis_speed = lerpf(_lis_speed, v, 0.2)
	_lis_prev = l
	_lis = l
	var body := Game.dominant_body(l)
	_lis_up = Vector3.UP
	if body != null:
		var r := l - body.global_position
		if r.length_squared() > 1e-6:
			_lis_up = r.normalized()
	var wld := get_viewport().find_world_3d()
	_space = wld.direct_space_state if wld != null else null
	var dm = _acu.get("_density_mode") if _acu != null else null
	_phys_ok = _space != null and _lis_speed < PHYS_MAX_SPEED and not (dm != null and bool(dm))
	# The listener's own vehicle / controlled body never blocks its sounds.
	_excl.clear()
	var pl = Game.player
	if pl != null and is_instance_valid(pl):
		var v = pl.get("vehicle")
		if v is CollisionObject3D and is_instance_valid(v):
			_excl.append((v as CollisionObject3D).get_rid())
	var c = Game.controlled
	if c is CollisionObject3D and is_instance_valid(c):
		_excl.append((c as CollisionObject3D).get_rid())
	var air = _sfx.get("listener_air")
	if air != null and float(air) < 0.05:
		return false
	return _space != null or not Bodies.all().is_empty()


func _is_own(p: Node) -> bool:
	if _sfx != null and _sfx.has_method("_is_own"):
		return bool(_sfx._is_own(p))
	var pl = Game.player
	return pl != null and is_instance_valid(pl) and (pl as Node).is_ancestor_of(p)


func _k_of(p: AudioStreamPlayer3D, unit: float) -> float:
	if p.has_meta(&"occlusion_k"):
		return clampf(float(p.get_meta(&"occlusion_k")), 0.0, 1.0)
	if unit >= LOUD_UNIT:
		return LOUD_K
	if p.volume_db >= LOUD_DB:
		return LOUD_DB_K
	return 1.0


## Estimated level at the ear (dB) from the player's own values: its distance law + volume_db,
## clamped by max_db, × the max_distance fade (the engine's formula; model / max_distance as of
## the play's start).
func _level_db(e: Src, p: AudioStreamPlayer3D) -> float:
	var unit: float = e.b_unit if e.applied else p.unit_size
	var mx: float = e.b_maxdb if e.applied else p.max_db
	var att := minf(_att_db(e.model, e.dist, unit) + p.volume_db, mx)
	if e.max_d > 0.0:
		var f := 1.0 - e.dist / e.max_d
		if f <= 0.0:
			return -INF
		att += linear_to_db(f)
	return att


## AudioStreamPlayer3D's distance attenuation (dB) without volume / clamp (engine formula; the
## logarithmic model uses the natural log there).
static func _att_db(model: int, d: float, unit: float) -> float:
	match model:
		AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE:
			return linear_to_db(1.0 / (d / unit + 0.00001))
		AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE:
			var q := d / unit
			return linear_to_db(1.0 / (q * q + 0.00001))
		AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC:
			return -20.0 * log(d / unit + 0.00001)
	return 0.0


func _interval(d: float) -> float:
	return lerpf(1.0 / RATE_NEAR, 1.0 / RATE_FAR, smoothstep(NEAR_M, FAR_M, d))


## A new play: its own result if taken here moments ago, else a recent one of the same cell.
func _reuse(e: Src, now: float) -> bool:
	if now - e.eval_t < 0.4 and e.eval_src.distance_squared_to(e.pos) < 2.25 \
			and e.eval_lis.distance_squared_to(_lis) < 2.25:
		_st_reuse += 1
		return true
	var c = _cells.get(Vector3i((e.pos / CELL).floor()))
	if c == null:
		return false
	var a: PackedFloat32Array = c
	if now - a[2] > CELL_TTL or Vector3(a[3], a[4], a[5]).distance_squared_to(_lis) > MOVE_M * MOVE_M:
		return false
	_set_target(e, Vector2(a[0], a[1]))
	e.iv = _interval(e.dist)
	e.next_t = now + e.iv * 0.5
	_st_reuse += 1
	return true


func _evaluate(e: Src, now: float) -> void:
	var r := _occlusion(e)
	_set_target(e, r)
	e.res = r
	e.eval_t = now
	e.eval_src = e.pos
	e.eval_lis = _lis
	e.iv = _interval(e.dist)
	if not _phys_ok or e.dist > PHYS_R:
		e.iv *= FAR_IV_K                     # density marches: far and slow to change, and costlier
	e.next_t = now + e.iv * _rng.randf_range(0.85, 1.15)
	var key := Vector3i((e.pos / CELL).floor())
	_cells[key] = PackedFloat32Array([r.x, r.y, now, _lis.x, _lis.y, _lis.z])


func _set_target(e: Src, r: Vector2) -> void:
	e.tgt_a = r.x * e.k
	if r.x > 0.0:                        # clear keeps the last colour while it fades out
		e.tgt_sev = smoothstep(THIN_M, THICK_M, r.y)


# =================================================================================================
# Rays
# =================================================================================================

## Partial amount (0, 1/3, 2/3, 1) and thickness (m) between the listener and the source.
func _occlusion(e: Src) -> Vector2:
	var s := e.pos
	var body := Game.dominant_body(s)
	var up := _lis_up
	if body != null:
		var r := s - body.global_position
		if r.length_squared() > 1e-6:
			up = r.normalized()
	if _phys_ok:
		if not e.rids_done:
			e.rids = _owner_rids(e.node)
			e.rids_done = true
		var ex: Array[RID] = _excl.duplicate()
		ex.append_array(e.rids)
		_query.exclude = ex
	var lift := SRC_LIFT
	if _phys_ok and s.distance_to(_lis) < PHYS_R + SRC_LIFT:
		# Not into a tunnel ceiling / overhang (impacts sit on surfaces).
		var hl := _ray(s, s + up * SRC_LIFT)
		if not hl.is_empty():
			lift = maxf(s.distance_to(hl["position"]) - 0.1, 0.0)
	var src := s + up * lift
	var seg := src - _lis
	var dist := seg.length()
	if dist < CLEAR_M:
		return Vector2.ZERO
	var dir := seg / dist
	var a := _lis + dir * EAR_MARGIN
	var b := src - dir * SRC_MARGIN
	var near := _phys_ok and dist <= PHYS_R
	var hit := false
	var entry := 0.0
	var nb := 0
	var h := {}
	if _phys_ok:
		var end := b if near else _lis + dir * PHYS_R
		h = _ray(a, end)
		if not h.is_empty():
			hit = true
			entry = _lis.distance_to(h["position"])
			nb = 1 + _side_rays(a, end, dir)
	if near:
		if not hit:
			return Vector2.ZERO
		# The exit point: the first surface seen from the source (none: the source is buried).
		var exit := dist
		var h2 := _ray(b, a)
		if not h2.is_empty():
			exit = dist - src.distance_to(h2["position"])
		var chord := maxf(exit - entry, 0.2)
		var frac := float(nb) / 3.0
		if _is_structure(h):
			return Vector2(frac, chord)
		# Soil: how far below the surface the line passes decides (a long shallow chord under the
		# curve of the planet or a rim is a short detour for the sound, not a hill).
		var deep := _depth_along(_lis + dir * entry, _lis + dir * minf(exit, dist - SRC_MARGIN))
		return Vector2(minf(frac, _deep_frac(deep)), minf(chord, DEEP_THICK_K * maxf(deep, 0.3)))
	# Far, or no collision: march the density through every body (past the physics part when that
	# was clear: physics knows the dug tunnels and caves near the camera exactly).
	var len := a.distance_to(b)
	var from := (PHYS_R - 2.0) if (_phys_ok and not hit) else END_TRIM
	var solid := 0.0
	var deep := 0.0
	for bd in Bodies.all():
		if not is_instance_valid(bd) or not bd.has_method("density_fast"):
			continue
		var m := march(bd, a, b, from, len - END_TRIM)
		_st_marches += 1
		_st_samples += int(m.z)
		solid += m.x
		deep = maxf(deep, m.y)
	var frac := float(nb) / 3.0
	var thick := THIN_DEFAULT if hit else 0.0
	if solid >= MIN_SOLID:
		thick = minf(solid, DEEP_THICK_K * deep)
		frac = maxf(frac, _deep_frac(deep))
	return Vector2(frac, thick)


static func _deep_frac(deep: float) -> float:
	if deep >= DEEP_FULL:
		return 1.0
	return 2.0 / 3.0 if deep >= DEEP_HALF else 1.0 / 3.0


## A ray hit on a structure (LAYER_SHIP, not terrain): a wall, judged by the rays alone.
static func _is_structure(h: Dictionary) -> bool:
	var col = h.get("collider")
	if col == null or not is_instance_valid(col) or not (col is CollisionObject3D):
		return false
	var layer := (col as CollisionObject3D).collision_layer
	return (layer & Game.LAYER_SHIP) != 0 and (layer & Game.LAYER_TERRAIN) == 0


## Deepest point below the (smooth, edited) surface on the segment p0 -> p1: a few density
## samples (planet.density_fast); 0 when the density sees only air there (a detail bump).
func _depth_along(p0: Vector3, p1: Vector3) -> float:
	var body = Game.dominant_body((p0 + p1) * 0.5)
	if body == null or not body.has_method("density_fast"):
		return DEEP_FULL
	var n := clampi(int(p0.distance_to(p1) / DEEP_SAMPLE_M) + 1, 2, 10)
	var deep := 0.0
	for i in n:
		var d: float = body.density_fast(p0.lerp(p1, (float(i) + 0.5) / float(n)))
		deep = maxf(deep, -d)
	_st_samples += n
	return deep


## The two offset rays beside a blocked centre line: how many are blocked too (0..2).
func _side_rays(a: Vector3, b: Vector3, dir: Vector3) -> int:
	var lat := dir.cross(_lis_up)
	if lat.length_squared() < 0.01:      # a vertical line (a shaft): any horizontal side
		lat = dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.FORWARD)
	lat = lat.normalized()
	var upl := lat.cross(dir)
	var n := 0
	for s: float in [-1.0, 1.0]:
		var off := lat * (SIDE_OFF * s) + upl * SIDE_UP
		if not _ray(a + off * EAR_SPREAD, b + off).is_empty():
			n += 1
	return n


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	_query.from = from
	_query.to = to
	_st_rays += 1
	return _space.intersect_ray(_query)


## Collision bodies of the source's own structure (the parent, its direct children, the
## grandparent): a cannon's sound sits inside the cannon's StaticBody.
static func _owner_rids(p: Node) -> Array[RID]:
	var out: Array[RID] = []
	var n := p.get_parent()
	if n == null or n is Viewport:
		return out
	if n is CollisionObject3D:
		out.append((n as CollisionObject3D).get_rid())
	if n.get_child_count() <= 24:
		for c in n.get_children():
			if c is CollisionObject3D:
				out.append((c as CollisionObject3D).get_rid())
	var g := n.get_parent()
	if g is CollisionObject3D:
		out.append((g as CollisionObject3D).get_rid())
	return out


## Density march of segment a -> b through one body's (edited) soil, counting only between
## count_from and count_to m along it: Vector3(solid m, deepest point below the smooth surface (m),
## samples). Fast density (planet.density_fast: the edit inside dug regions, else the height field
## without the ±1.3 m detail and the natural caves); a sample counts as soil only SOLID_EPS m below.
## Steps: 0.7 × the height above the ground in the air (at least MARCH_STEP), half the depth in the
## soil (MARCH_STEP..MARCH_SOLID_MAX); the parts outside the terrain shell are skipped.
static func march(body: Node3D, a: Vector3, b: Vector3, count_from := 0.0, count_to := INF) -> Vector3:
	var seg := b - a
	var len := seg.length()
	if len < 0.001:
		return Vector3.ZERO
	var dir := seg / len
	var oc := a - body.global_position
	var shell := float(body.radius) + float(body.max_height) + 2.0
	var bb := oc.dot(dir)
	var disc := bb * bb - (oc.length_squared() - shell * shell)
	if disc <= 0.0:
		return Vector3.ZERO
	var sq := sqrt(disc)
	var t := maxf(-bb - sq, count_from)
	var t_end := minf(minf(-bb + sq, len), count_to)
	var solid := 0.0
	var deep := 0.0
	var n := 0
	while t < t_end and n < MARCH_MAX:
		var d: float = body.density_fast(a + dir * t)
		n += 1
		var adv: float
		if d < -SOLID_EPS:
			adv = minf(clampf(-d * 0.5, MARCH_STEP, MARCH_SOLID_MAX), t_end - t)
			solid += adv
			deep = maxf(deep, -d)
		else:
			adv = maxf(MARCH_STEP, d * 0.7)
		t += adv
	return Vector3(solid, deep, float(n))


# =================================================================================================
# Applying
# =================================================================================================

func _apply(e: Src, ks: float) -> void:
	if e.snap:
		e.cur_a = e.tgt_a
		e.cur_sev = e.tgt_sev
		e.snap = false
	elif absf(e.cur_a - e.tgt_a) > 0.002 or absf(e.cur_sev - e.tgt_sev) > 0.002:
		e.cur_a = lerpf(e.cur_a, e.tgt_a, ks)
		e.cur_sev = lerpf(e.cur_sev, e.tgt_sev, ks)
	elif e.tgt_a > 0.0 and e.applied and not e.dirty and absf(e.dist - e.w_dist) < 0.5:
		return                               # settled, nothing changed since the last write
	if e.cur_a < 0.003 and e.tgt_a <= 0.0:
		e.cur_a = 0.0
		if e.applied:
			_restore(e)
		return
	var p := e.node
	if not e.applied:
		_capture(e, p)
	var a := e.cur_a
	var sev := e.cur_sev
	var cut_full := exp(lerpf(log(CUT_THIN), log(CUT_THICK), sev))
	var cut := exp(lerpf(log(e.b_cut), log(minf(e.b_cut, cut_full)), a))
	var duck := lerpf(DUCK_THIN, DUCK_THICK, sev) * a
	var unit := e.b_unit
	var mx := e.b_maxdb + duck
	match e.model:
		AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE:
			unit *= db_to_linear(duck)
		AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE:
			unit *= db_to_linear(duck * 0.5)
		AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC:
			unit *= exp(duck / 20.0)
		_:
			mx = e.b_maxdb                # no distance law to scale: the filter only
	unit = maxf(unit, 0.05)
	var shelf := lerpf(SHELF_THIN, SHELF_THICK, sev) * a
	var extra := clampf(shelf - _native_shelf_db(e, p, unit, mx), -60.0, 0.0)
	_write(e, p, unit, mx, cut, extra)
	e.w_dist = e.dist
	e.dirty = false


## The engine's own distance shelf (dB) with these values: (1 - min(1, gain)) × attenuation_filter_db.
static func _native_shelf_db(e: Src, p: AudioStreamPlayer3D, unit: float, mx: float) -> float:
	var att := minf(_att_db(e.model, e.dist, unit) + p.volume_db, mx)
	var mult := db_to_linear(att)
	if e.max_d > 0.0:
		mult *= maxf(0.0, 1.0 - e.dist / e.max_d)
	return (1.0 - minf(1.0, mult)) * p.attenuation_filter_db


func _write(e: Src, p: AudioStreamPlayer3D, unit: float, mx: float, cut: float, extra: float) -> void:
	if absf(unit - e.w_unit) > e.w_unit * 0.002:
		p.unit_size = unit
		e.w_unit = p.unit_size
	if absf(mx - e.w_maxdb) > 0.05:
		p.max_db = mx
		e.w_maxdb = p.max_db
	if absf(cut - e.w_cut) > e.w_cut * 0.004:
		p.attenuation_filter_cutoff_hz = cut
		e.w_cut = p.attenuation_filter_cutoff_hz
	if e.b_emis:
		return
	if extra < -0.1:
		if not e.emis_on:
			if p.emission_angle_enabled:
				e.b_emis = true              # the creator switched the emission angle on itself: theirs
				return
			e.b_emis_deg = p.emission_angle_degrees
			e.b_emis_db = p.emission_angle_filter_attenuation_db
			p.emission_angle_degrees = 0.1
			p.emission_angle_enabled = true
			e.emis_on = true
			e.w_emis_db = 1.0
		if absf(extra - e.w_emis_db) > 0.1:
			p.emission_angle_filter_attenuation_db = extra
			e.w_emis_db = p.emission_angle_filter_attenuation_db
	elif e.emis_on:
		_emission_off(e, p)


## Bases from an untouched player.
func _capture(e: Src, p: AudioStreamPlayer3D) -> void:
	e.b_unit = p.unit_size
	e.b_maxdb = p.max_db
	e.b_cut = p.attenuation_filter_cutoff_hz
	e.b_emis = p.emission_angle_enabled
	e.b_emis_deg = p.emission_angle_degrees
	e.b_emis_db = p.emission_angle_filter_attenuation_db
	e.w_unit = e.b_unit
	e.w_maxdb = e.b_maxdb
	e.w_cut = e.b_cut
	e.emis_on = false
	e.applied = true


## A script wrote its own value since our last write: that is the new base.
func _sync_bases(e: Src, p: AudioStreamPlayer3D) -> void:
	var u := p.unit_size
	if u != e.w_unit:
		e.b_unit = u
		e.w_unit = u
		e.k = _k_of(p, u)
		e.tgt_a = e.res.x * e.k
		e.dirty = true
	var m := p.max_db
	if m != e.w_maxdb:
		e.b_maxdb = m
		e.w_maxdb = m
		e.dirty = true
	var c := p.attenuation_filter_cutoff_hz
	if c != e.w_cut:
		e.b_cut = c
		e.w_cut = c
		e.dirty = true


## Back to the bases (values a script changed meanwhile stay theirs).
func _restore(e: Src) -> void:
	var p := e.node
	if p.unit_size == e.w_unit and e.w_unit != e.b_unit:
		p.unit_size = e.b_unit
	if p.max_db == e.w_maxdb and e.w_maxdb != e.b_maxdb:
		p.max_db = e.b_maxdb
	if p.attenuation_filter_cutoff_hz == e.w_cut and e.w_cut != e.b_cut:
		p.attenuation_filter_cutoff_hz = e.b_cut
	if e.emis_on:
		_emission_off(e, p)
	e.cur_a = 0.0
	e.applied = false


func _emission_off(e: Src, p: AudioStreamPlayer3D) -> void:
	p.emission_angle_enabled = false
	p.emission_angle_degrees = e.b_emis_deg
	p.emission_angle_filter_attenuation_db = e.b_emis_db
	e.emis_on = false


# =================================================================================================
# Debug
# =================================================================================================

func _debug_print(now: float) -> void:
	if now - _st_t < 2.0:
		return
	var span := maxf(now - _st_t, 0.001)
	if _st_t > 0.0:
		var fr := maxf(float(_st_frames), 1.0)
		print("[occlusion] tracked %d  playing/eligible %d  managed %d  occluded %d | evals %.0f/s (new %.0f/s, reused %.0f/s)  rays %.0f/s  marches %.0f/s (%.0f samples each) | us/frame %.0f avg (poll %.0f, rays %.0f, apply %.0f), %d peak  phys %s  speed %.1f" % [
				_list.size(), _st_cands, _st_managed, _st_occl, _st_evals / span, _st_new / span,
				_st_reuse / span, _st_rays / span, _st_marches / span,
				float(_st_samples) / maxf(float(_st_marches), 1.0), float(_st_usec) / fr,
				float(_st_poll) / fr, float(_st_eval) / fr, float(_st_apply) / fr,
				_st_peak, _phys_ok, _lis_speed])
	_st_t = now
	_st_poll = 0
	_st_eval = 0
	_st_apply = 0
	_st_frames = 0
	_st_evals = 0
	_st_new = 0
	_st_reuse = 0
	_st_rays = 0
	_st_marches = 0
	_st_samples = 0
	_st_usec = 0
	_st_peak = 0
