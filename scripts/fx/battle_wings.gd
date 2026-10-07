extends RefCounted
## Fighters, bombers, missiles and torpedoes of the background space battle (space_battle.gd).
## Craft fly a small dogfight AI at 10 Hz each (staggered, so a frame runs only a handful): lead
## pursuit with gun bursts, overshoot extends, evasive breaks with barrel rolls, loops, strafing
## runs on enemy capital ships, missile salvos. Bombers form up on their side, make torpedo runs on
## the enemy capital ship, break away and regroup; their tail gun answers fighters on their six.
## The GPU dead-reckons every craft between steps (hull shader, INSTANCE_CUSTOM = velocity + state
## time), so the CPU writes each craft's 16 floats only when it steps. Engine trails are streak
## segments emitted per step. Missiles (corkscrewing) and torpedoes step at 20 Hz.
## Hits are rolled, not traced: a hit bolt ends exactly where the target will be and the damage
## lands when it arrives. Destroyed craft relaunch later from a carrier bay or jump in at their
## end of the zone. No physics, no groups, nothing the game scans.

const Fx := preload("res://scripts/fx/battle_fx.gd")
const Zone := preload("res://scripts/fx/battle_zone.gd")
const Models := preload("res://scripts/fx/battle_models.gd")
const Fleet := preload("res://scripts/fx/battle_fleet.gd")

const DT := 0.1                 # craft AI step
const PDT := 0.05               # missile / torpedo step (corkscrews need it)
const BOLT_SPEED := 650.0
const GUN_RANGE := 430.0

enum { LAUNCH, PURSUE, BREAK, LOOP, STRAFE, EXTEND, RUN, FORM }

const BOLT_COL := [Color(1.0, 0.6, 0.22) * 2.0, Color(1.0, 0.14, 0.08) * 2.2]
const TRAIL_COL := [Color(1.0, 0.62, 0.32) * 0.5, Color(1.0, 0.2, 0.1) * 0.55]
const MSL_TRAIL := [Color(1.0, 0.82, 0.6) * 0.75, Color(1.0, 0.45, 0.35) * 0.75]
const MSL_HEAD := [Color(1.0, 0.85, 0.6), Color(1.0, 0.4, 0.3)]
const TORP_TRAIL := [Color(1.0, 0.7, 0.35), Color(1.0, 0.28, 0.16)]
const TORP_HEAD := [Color(1.0, 0.75, 0.4), Color(1.0, 0.3, 0.18)]
const BAY_COL := [Color(1.0, 0.6, 0.25), Color(1.0, 0.25, 0.1)]
const FLARE := Color(1.0, 0.85, 0.5) * 2.0
const HIT := Color(1.0, 0.75, 0.45)


class Craft:
	var team := 0
	var bomber := false
	var zone := 0
	var slot := 0
	var alive := false
	var pos := Vector3.ZERO
	var fwd := Vector3.FORWARD
	var up := Vector3.UP
	var speed := 120.0
	var st := 0.0
	var mode := 1
	var mode_t := 0.0
	var tgt := -1
	var cap: Fleet.Cap = null
	var aim := Vector3.ZERO       # break / extend direction, rally point or ship-local aim point
	var hp := 3
	var gun_cd := 0.0
	var burst := 0
	var msl_cd := 0.0
	var threat := 0.0
	var threat_src := -1
	var roll := 0.0
	var respawn_at := 0.0
	var retarget_t := 0.0


class Proj:
	var team := 0
	var kind := 0                 # 0 missile, 1 torpedo
	var zone := 0
	var slot := 0
	var pos := Vector3.ZERO       # base path (without the corkscrew)
	var draw := Vector3.ZERO      # last drawn point
	var dir := Vector3.FORWARD
	var speed := 150.0
	var vmax := 300.0
	var accel := 150.0
	var turn := 2.5
	var tgt := -1
	var cap: Fleet.Cap = null
	var cap_pt := Vector3.ZERO
	var cr := 4.0                 # corkscrew radius
	var ph := 0.0
	var spin := 10.0
	var life := 6.0
	var st := 0.0
	var decoy := false
	var decoy_ok := false
	var kill_t := 1.0e9           # point-defence intercept time


var fx: Fx
var zones: Array[Zone] = []
var fleet: Fleet
var crafts: Array[Craft] = []
var projs: Array[Proj] = []
var _zone_idx: Array[PackedInt32Array] = []
var _attackers := PackedInt32Array()
var _cbuf := PackedFloat32Array()
var _mm_rid: Array[RID] = []
var _mm_from := PackedInt32Array()
var _mm_to := PackedInt32Array()
var _c_dirty := false
var _free_heads := PackedInt32Array()
var _ev_t := PackedFloat64Array()
var _ev_i := PackedInt32Array()
var _ev_d := PackedInt32Array()


## plan: per zone [home fighters, home bombers, rival fighters, rival bombers]; one MultiMesh per
## craft type (4), slots grouped by type.
func setup(p_fx: Fx, p_zones: Array[Zone], p_fleet: Fleet, plan: Array, n_heads: int) -> void:
	fx = p_fx
	zones = p_zones
	fleet = p_fleet
	for typ in 4:
		var team := 0 if typ < 2 else 1
		var bomber := typ % 2 == 1
		var from := crafts.size()
		for zi in plan.size():
			var zp: Array = plan[zi]
			for _i in int(zp[typ]):
				var f := Craft.new()
				f.team = team
				f.bomber = bomber
				f.zone = zi
				f.slot = crafts.size()
				crafts.append(f)
		var to := crafts.size()
		_mm_from.append(from)
		_mm_to.append(to)
		if to > from:
			var mi := fx.multimesh(Models.craft(team, bomber, fx.hull_craft, fx.glow_craft), null, to - from, false)
			_mm_rid.append(mi.multimesh.get_rid())
		else:
			_mm_rid.append(RID())
	_cbuf.resize(crafts.size() * 16)
	_attackers.resize(crafts.size())
	for zi in zones.size():
		var lst := PackedInt32Array()
		for f in crafts:
			if f.zone == zi:
				lst.append(f.slot)
		_zone_idx.append(lst)
	var n := crafts.size()
	for f in crafts:
		f.st = fx.now - DT * float(f.slot) / float(maxi(n, 1))
		if fx.rng.randf() < 0.8:
			_spawn_in_zone(f)
		else:
			f.alive = false
			f.respawn_at = fx.now + fx.rng.randf_range(3.0, 50.0)
			_hide(f)
	for i in n_heads:
		_free_heads.append(i)
	_push()


# --- Tick ------------------------------------------------------------------------------------

func tick() -> void:
	var now := fx.now
	for f in crafts:
		if not f.alive:
			if now >= f.respawn_at:
				_launch(f)
			continue
		var steps := 0
		while f.alive and f.st + DT <= now and steps < 2:
			_step(f)
			steps += 1
		if f.alive and f.st + DT * 2.0 < now:
			# starved (hitch): jump ahead along the current heading
			var lag := now - DT * 0.5 - f.st
			f.pos += f.fwd * (f.speed * lag)
			f.st += lag
			_write(f)
	var i := 0
	while i < projs.size():
		var p: Proj = projs[i]
		var keep := true
		var steps := 0
		while keep and p.st + PDT <= now and steps < 3:
			keep = _pstep(p)
			steps += 1
		if keep:
			i += 1
			continue
		fx.head_hide(p.slot)
		_free_heads.append(p.slot)
		projs[i] = projs[projs.size() - 1]
		projs.pop_back()
	_events(now)
	_push()


func _step(f: Craft) -> void:
	var z: Zone = zones[f.zone]
	f.st += DT
	f.mode_t -= DT
	f.gun_cd -= DT
	f.msl_cd -= DT
	f.threat = maxf(f.threat - DT, 0.0)
	var ii := fx.intensity
	var want := f.fwd
	var vt := 88.0 if f.bomber else 125.0
	var turn := 0.8 if f.bomber else 1.35
	var fire := -1
	var fire_cap := false
	if not f.bomber and f.mode == PURSUE:
		if f.tgt < 0 or not crafts[f.tgt].alive or f.st >= f.retarget_t:
			_retarget(f)
	match f.mode:
		LAUNCH:
			vt = 150.0
			if f.mode_t <= 0.0:
				if f.bomber:
					f.mode = FORM
					f.aim = _rally(f)
					f.mode_t = fx.rng.randf_range(4.0, 10.0)
				else:
					f.mode = PURSUE
		PURSUE:
			if f.tgt < 0:
				var side := 1.0 if f.team == 0 else -1.0
				want = (z.center + z.a * (side * z.ext.x * 0.5) - f.pos).normalized()
				if fx.rng.randf() < 0.02:
					_start_strafe(f)
			else:
				var t: Craft = crafts[f.tgt]
				var tp := t.pos + t.fwd * (t.speed * (f.st - t.st))
				var to := tp - f.pos
				var dist := maxf(to.length(), 0.1)
				var lead := tp + t.fwd * (t.speed * dist / BOLT_SPEED)
				want = (lead - f.pos).normalized()
				vt = clampf(t.speed + (dist - 160.0) * 0.3, 90.0, 168.0)
				if dist < 70.0 and f.fwd.dot(to) > 0.0:
					_extend(f, fx.rng.randf_range(1.5, 2.6), Vector3.ZERO)
				elif dist < GUN_RANGE and f.fwd.dot(want) > 0.985:
					fire = f.tgt
					if dist < 320.0 and t.fwd.dot(to / dist) > 0.5:
						t.threat = maxf(t.threat, 1.2)
						t.threat_src = f.slot
				if f.msl_cd <= 0.0 and dist > 280.0 and dist < 950.0 and fx.rng.randf() < 0.05 + 0.05 * ii:
					_missiles(f, f.tgt, 2 if ii < 0.7 else fx.rng.randi_range(2, 4))
			if f.mode == PURSUE:
				if f.threat > 0.0 and fx.rng.randf() < 0.22:
					_break(f)
				elif fx.rng.randf() < 0.002:
					f.mode = LOOP
					f.mode_t = fx.rng.randf_range(3.6, 4.6)
				elif fx.rng.randf() < 0.0015 * ii:
					_start_strafe(f)
		BREAK:
			want = f.aim
			vt = 170.0
			turn *= 1.5
			if f.mode_t <= 0.0:
				f.mode = PURSUE
		LOOP:
			var right := f.fwd.cross(f.up).normalized()
			want = f.fwd.rotated(right, 0.8)
			vt = 118.0
			if f.mode_t <= 0.0:
				f.mode = PURSUE
		STRAFE, RUN:
			if f.cap == null or f.cap.state > 1:
				f.cap = null
				f.mode = FORM if f.bomber else PURSUE
				if f.bomber:
					f.aim = _rally(f)
			else:
				var hp := f.cap.pos + f.cap.basis * f.aim
				var to := hp - f.pos
				var dist := maxf(to.length(), 0.1)
				want = to / dist
				var aligned := f.fwd.dot(want) > 0.975
				var away := (f.pos - f.cap.pos).normalized()
				if f.bomber:
					vt = 105.0
					if f.burst == 0 and dist < 700.0 and aligned:
						_torpedoes(f)
						f.burst = 1
						f.mode_t = minf(f.mode_t, 1.5)
					if dist < 260.0 or (f.burst == 1 and f.mode_t <= 0.0):
						_extend(f, fx.rng.randf_range(4.0, 6.0), away)
				else:
					vt = 150.0
					if dist < 650.0 and aligned:
						fire_cap = true
					if dist < 170.0:
						_extend(f, fx.rng.randf_range(2.5, 3.5), away)
				if (f.mode == STRAFE or f.mode == RUN) and f.mode_t <= 0.0:
					f.mode = FORM if f.bomber else PURSUE
					if f.bomber:
						f.aim = _rally(f)
		EXTEND:
			want = f.aim
			vt = 120.0 if f.bomber else 165.0
			if f.mode_t <= 0.0:
				if f.bomber:
					f.mode = FORM
					f.aim = _rally(f)
					f.mode_t = fx.rng.randf_range(6.0, 14.0)
				else:
					f.mode = PURSUE
		FORM:
			want = (f.aim - f.pos).normalized()
			vt = 85.0
			if f.pos.distance_squared_to(f.aim) < 6400.0:
				f.aim = _rally(f)
			if f.mode_t <= 0.0:
				var c := fleet.enemy_cap(f.zone, f.team)
				if c != null and fx.rng.randf() < 0.25 * (0.5 + ii):
					f.cap = c
					f.aim = fleet.facing_pt(c, f.pos)
					f.mode = RUN
					f.mode_t = 26.0
					f.burst = 0
				else:
					f.mode_t = fx.rng.randf_range(3.0, 7.0)
	if f.bomber:
		_turret(f)
	# stay inside the zone
	var out := z.outside(f.pos)
	if out > 0.0:
		want = (want + (z.center - f.pos).normalized() * minf(out * 2.0, 3.0)).normalized()
	var nf := _turn(f.fwd, want, turn * DT, f.up)
	if f.mode == BREAK:
		f.up = f.up.rotated(nf, f.roll * DT)
	else:
		# bank into the turn; "level" means dorsal toward the planets
		var lat := (nf - f.fwd) * (f.speed / DT)
		f.up = f.up.lerp((z.up * 30.0 + lat).normalized(), 0.45)
	f.up = _ortho(f.up, nf, z.up)
	f.fwd = nf
	f.speed = move_toward(f.speed, vt, 70.0 * DT)
	var prev := f.pos
	f.pos += nf * (f.speed * DT)
	fx.streak(f.pos, Vector3.ZERO, f.pos - prev, 2.2 if f.bomber else 1.5, f.st, 0.8 if f.bomber else 0.65,
			TRAIL_COL[f.team], Fx.S_TRAIL)
	if f.gun_cd <= 0.0:
		if fire >= 0:
			_guns(f, fire)
		elif fire_cap:
			_guns_cap(f)
	_write(f)


func _break(f: Craft) -> void:
	f.mode = BREAK
	f.mode_t = fx.rng.randf_range(1.0, 2.2)
	var p := fx.rand_dir()
	p = p - f.fwd * p.dot(f.fwd)
	f.aim = (p.normalized() * 0.9 - f.fwd * 0.25).normalized()
	f.roll = (1.0 if fx.rng.randf() < 0.5 else -1.0) * fx.rng.randf_range(2.5, 5.0)


func _extend(f: Craft, t: float, away: Vector3) -> void:
	f.mode = EXTEND
	f.mode_t = t
	var p := fx.rand_dir()
	p = p - f.fwd * p.dot(f.fwd)
	f.aim = (f.fwd + p * 0.6 + away * 1.2).normalized()


func _start_strafe(f: Craft) -> void:
	var c := fleet.enemy_cap(f.zone, f.team)
	if c == null:
		return
	f.cap = c
	f.aim = fleet.facing_pt(c, f.pos)
	f.mode = STRAFE
	f.mode_t = 16.0


## A point on the craft's own half of the zone (bombers form up there).
func _rally(f: Craft) -> Vector3:
	var z: Zone = zones[f.zone]
	var side := -1.0 if f.team == 0 else 1.0
	return z.center + z.a * (side * z.ext.x * fx.rng.randf_range(0.2, 0.6)) \
			+ z.d * (fx.rng.randf_range(-0.5, 0.5) * z.ext.y) + z.n * (fx.rng.randf_range(-0.6, 0.6) * z.ext.z)


func _retarget(f: Craft) -> void:
	if f.tgt >= 0:
		_attackers[f.tgt] = maxi(_attackers[f.tgt] - 1, 0)
	f.tgt = -1
	var best := INF
	var lst: PackedInt32Array = _zone_idx[f.zone]
	for j in lst:
		var t: Craft = crafts[j]
		if t.team == f.team or not t.alive:
			continue
		var s := f.pos.distance_to(t.pos) + float(_attackers[j]) * 260.0 + fx.rng.randf() * 180.0
		if t.bomber:
			s -= 180.0
		if s < best:
			best = s
			f.tgt = j
	if f.tgt >= 0:
		_attackers[f.tgt] += 1
	f.retarget_t = f.st + fx.rng.randf_range(5.0, 10.0)


# --- Weapons ---------------------------------------------------------------------------------

func _guns(f: Craft, ti: int) -> void:
	var t: Craft = crafts[ti]
	var tp := t.pos + t.fwd * (t.speed * (f.st - t.st))
	var dist := f.pos.distance_to(tp)
	var tof := dist / BOLT_SPEED
	var aim := (tp + t.fwd * (t.speed * tof) - f.pos).normalized()
	var p_hit := (0.07 + 0.08 * fx.intensity) * clampf(1.25 - dist / GUN_RANGE, 0.25, 1.0)
	if t.bomber:
		p_hit *= 1.3
	var hit := fx.rng.randf() < p_hit
	var right := f.fwd.cross(f.up)
	var col: Color = BOLT_COL[f.team]
	for g in 2:
		var dt0 := 0.05 * float(g)
		var mz := f.pos + f.fwd * (f.speed * dt0 + 5.0) + right * (1.2 if g == 0 else -1.2)
		var dir := aim
		var life := 0.75
		if hit and g == 0:
			life = tof
		else:
			dir = (aim + fx.rand_dir() * fx.rng.randf_range(0.015, 0.05)).normalized()
		fx.streak(mz, dir * BOLT_SPEED, dir * 16.0, 1.0, f.st + dt0, life, col, Fx.S_BOLT)
	if hit:
		_ev(f.st + tof, ti, 1)
	_burst(f)


func _guns_cap(f: Craft) -> void:
	var to := f.cap.pos + f.cap.basis * f.aim - f.pos
	var dist := maxf(to.length(), 1.0)
	var dir := to / dist
	var tof := dist / BOLT_SPEED
	var right := f.fwd.cross(f.up)
	var col: Color = BOLT_COL[f.team]
	for g in 2:
		var dt0 := 0.05 * float(g)
		var mz := f.pos + f.fwd * (f.speed * dt0 + 5.0) + right * (1.2 if g == 0 else -1.2)
		var d2 := (dir + fx.rand_dir() * 0.012).normalized()
		fx.streak(mz, d2 * BOLT_SPEED, d2 * 16.0, 1.0, f.st + dt0, tof, col, Fx.S_BOLT)
	if fx.rng.randf() < 0.5:
		fleet.queue(f.st + tof, f.cap, f.aim + fx.rand_dir() * 5.0, Fleet.K_BOLT)
	_burst(f)


func _burst(f: Craft) -> void:
	f.burst += 1
	if f.burst >= 8:
		f.burst = 0
		f.gun_cd = fx.rng.randf_range(0.6, 1.6)


## Tail gun of a bomber: shoots back at the fighter on its six.
func _turret(f: Craft) -> void:
	if f.threat <= 0.0 or f.threat_src < 0 or fx.rng.randf() > 0.4:
		return
	var t: Craft = crafts[f.threat_src]
	if not t.alive or t.team == f.team:
		return
	var to := t.pos + t.fwd * (t.speed * (f.st - t.st)) - f.pos
	var dist := to.length()
	if dist > 400.0 or dist < 1.0:
		return
	var dir := (to / dist + fx.rand_dir() * 0.03).normalized()
	fx.streak(f.pos + dir * 6.0, dir * BOLT_SPEED, dir * 12.0, 0.9, f.st, 0.7, BOLT_COL[f.team], Fx.S_BOLT)
	if fx.rng.randf() < 0.06:
		_ev(f.st + dist / BOLT_SPEED, f.threat_src, 1)


func _new_proj() -> Proj:
	if _free_heads.is_empty():
		return null
	var p := Proj.new()
	p.slot = _free_heads[_free_heads.size() - 1]
	_free_heads.resize(_free_heads.size() - 1)
	projs.append(p)
	return p


func _missiles(f: Craft, ti: int, n: int) -> void:
	var t: Craft = crafts[ti]
	var decoy := fx.rng.randf() < 0.45
	for k in n:
		var p := _new_proj()
		if p == null:
			break
		p.team = f.team
		p.kind = 0
		p.zone = f.zone
		p.st = f.st + float(k) * 0.12
		p.pos = f.pos + f.fwd * (f.speed * float(k) * 0.12 + 3.0) - f.up * 1.2
		p.draw = p.pos
		p.dir = (f.fwd + fx.rand_dir() * 0.2).normalized()
		p.speed = f.speed + 20.0
		p.vmax = 330.0
		p.accel = 230.0
		p.turn = 3.4
		p.tgt = ti
		p.cr = fx.rng.randf_range(2.5, 5.0)
		p.ph = TAU * float(k) / float(n)
		p.spin = fx.rng.randf_range(9.0, 13.0) * (1.0 if k % 2 == 0 else -1.0)
		p.life = 6.0
		p.decoy_ok = decoy
	t.threat = maxf(t.threat, 2.5)
	t.threat_src = f.slot
	f.msl_cd = fx.rng.randf_range(12.0, 24.0)


## A corkscrewing missile salvo from a capital ship (battle_fleet.gd) at another capital ship;
## point defence downs some on the way.
func salvo_cap(from: Vector3, dir0: Vector3, team: int, zi: int, cap: Fleet.Cap, n: int, t0: float) -> void:
	fx.flash(from, Vector3.ZERO, 4.0, 16.0, t0, 0.35, Fx.F_GLOW, MSL_HEAD[team], 1.4)
	for k in n:
		var p := _new_proj()
		if p == null:
			return
		p.team = team
		p.kind = 0
		p.zone = zi
		p.st = t0 + float(k) * 0.18
		p.pos = from + fx.rand_dir() * 6.0
		p.draw = p.pos
		p.dir = (dir0 + fx.rand_dir() * 0.35).normalized()
		p.speed = 60.0
		p.vmax = 240.0
		p.accel = 120.0
		p.turn = 1.6
		p.cap = cap
		p.cap_pt = fleet.facing_pt(cap, from)
		p.cr = fx.rng.randf_range(5.0, 9.0)
		p.ph = fx.rng.randf_range(0.0, TAU)
		p.spin = fx.rng.randf_range(6.0, 9.0) * (1.0 if fx.rng.randf() < 0.5 else -1.0)
		p.life = 10.0
		if fx.rng.randf() < 0.45:
			p.kill_t = p.st + fx.rng.randf_range(2.0, 5.0)


func _torpedoes(f: Craft) -> void:
	var right := f.fwd.cross(f.up)
	for k in 2:
		var p := _new_proj()
		if p == null:
			return
		p.team = f.team
		p.kind = 1
		p.zone = f.zone
		p.st = f.st + float(k) * 0.35
		p.pos = f.pos + f.fwd * (f.speed * float(k) * 0.35 + 2.0) - f.up * 1.8 + right * (2.0 if k == 0 else -2.0)
		p.draw = p.pos
		p.dir = f.fwd
		p.speed = f.speed
		p.vmax = 210.0
		p.accel = 45.0
		p.turn = 0.7
		p.cap = f.cap
		p.cap_pt = fleet.facing_pt(f.cap, f.pos)
		p.cr = 0.8
		p.spin = 3.0
		p.life = 12.0
		if fx.rng.randf() < 0.22:
			p.kill_t = p.st + fx.rng.randf_range(1.5, 3.5)


func _pstep(p: Proj) -> bool:
	p.st += PDT
	p.life -= PDT
	var tp := p.pos + p.dir * 200.0
	var tvel := Vector3.ZERO
	var hit_r := 9.0
	var live := false
	if p.cap != null:
		if p.cap.state <= 1:
			tp = p.cap.pos + p.cap.basis * p.cap_pt
			hit_r = 18.0
			live = true
	elif p.tgt >= 0:
		var t: Craft = crafts[p.tgt]
		if t.alive:
			tp = t.pos + t.fwd * (t.speed * (p.st - t.st))
			tvel = t.fwd * t.speed
			live = true
	if not live and not p.decoy:
		p.decoy = true
		p.life = minf(p.life, fx.rng.randf_range(0.8, 2.0))
	var dist := p.pos.distance_to(tp)
	if not p.decoy:
		var lead := tp + tvel * (clampf(dist / maxf(p.speed, 1.0), 0.0, 1.5) * 0.6)
		p.dir = _turn(p.dir, (lead - p.pos).normalized(), p.turn * PDT, Vector3.UP)
		if p.decoy_ok and dist < 260.0 and p.tgt >= 0:
			p.decoy = true
			p.life = minf(p.life, fx.rng.randf_range(0.6, 1.3))
			_flares(crafts[p.tgt])
	p.speed = minf(p.speed + p.accel * PDT, p.vmax)
	p.pos += p.dir * (p.speed * PDT)
	# corkscrew around the base path, tightening near the target
	p.ph += p.spin * PDT
	var s1 := p.dir.cross(Vector3.UP)
	if s1.length_squared() < 0.01:
		s1 = p.dir.cross(Vector3.RIGHT)
	s1 = s1.normalized()
	var s2 := s1.cross(p.dir)
	var dp := p.pos + (s1 * cos(p.ph) + s2 * sin(p.ph)) * (p.cr * clampf(dist / 150.0, 0.15, 1.0))
	var seg := dp - p.draw
	if p.kind == 1:
		fx.streak(dp, Vector3.ZERO, seg, 2.6, p.st, 1.3, TORP_TRAIL[p.team], Fx.S_TRAIL)
		fx.head(p.slot, dp, seg / PDT, 3.2, p.st, TORP_HEAD[p.team], 2.4)
	else:
		fx.streak(dp, Vector3.ZERO, seg, 1.3, p.st, 0.9, MSL_TRAIL[p.team], Fx.S_TRAIL)
		fx.head(p.slot, dp, seg / PDT, 2.0, p.st, MSL_HEAD[p.team], 2.0)
	p.draw = dp
	if not p.decoy and dist < hit_r + p.speed * PDT:
		_impact(p)
		return false
	if p.st >= p.kill_t:
		# shot down by point defence
		var fc: Color = Fleet.FLAK_COL[1 - p.team]
		fx.pop(p.pos, p.dir * (p.speed * 0.3), 12.0, p.st)
		for k in 2:
			fx.flash(p.pos + fx.rand_dir() * fx.rng.randf_range(15.0, 40.0), Vector3.ZERO, 2.0, 11.0,
					p.st + fx.rng.randf() * 0.2, 0.4, Fx.F_GLOW, fc, 1.4)
		return false
	if p.life <= 0.0:
		fx.pop(p.pos, p.dir * (p.speed * 0.3), 16.0 if p.kind == 1 else 10.0, p.st)
		return false
	return true


func _impact(p: Proj) -> void:
	if p.cap != null:
		fleet.hit_now(p.cap, p.cap_pt, Fleet.K_TORPEDO if p.kind == 1 else Fleet.K_MISSILE)
		return
	if p.tgt < 0:
		return
	var t: Craft = crafts[p.tgt]
	t.hp -= 4
	if t.hp <= 0:
		kill(p.tgt, true)
	else:
		fx.pop(p.pos, t.fwd * t.speed, 12.0, p.st)


## Countermeasures: a spray of flares behind the craft, and a hard break.
func _flares(t: Craft) -> void:
	if not t.alive:
		return
	var v := t.fwd * t.speed
	var tp := t.pos + v * (fx.now - t.st)
	for k in 5:
		var dt0 := float(k) * 0.08
		var d := (-t.fwd + fx.rand_dir() * 0.8).normalized()
		fx.streak(tp + v * dt0, v * 0.3 + d * fx.rng.randf_range(15.0, 35.0), d * 2.0, 2.0, fx.now + dt0, 1.6,
				FLARE, Fx.S_SPARK)
	if t.mode == PURSUE:
		_break(t)


# --- Damage, launches ------------------------------------------------------------------------

func _ev(t: float, i: int, dmg: int) -> void:
	_ev_t.append(t)
	_ev_i.append(i)
	_ev_d.append(dmg)


func _events(now: float) -> void:
	var n := _ev_t.size()
	if n == 0:
		return
	var w := 0
	for i in n:
		if _ev_t[i] <= now:
			_apply_hit(_ev_i[i], _ev_d[i])
		else:
			_ev_t[w] = _ev_t[i]
			_ev_i[w] = _ev_i[i]
			_ev_d[w] = _ev_d[i]
			w += 1
	if w < n:
		_ev_t.resize(w)
		_ev_i.resize(w)
		_ev_d.resize(w)


func _apply_hit(i: int, dmg: int) -> void:
	var f: Craft = crafts[i]
	if not f.alive:
		return
	f.hp -= dmg
	var v := f.fwd * f.speed
	fx.flash(f.pos + v * (fx.now - f.st), v * 0.5, 2.0, 7.0, fx.now, 0.2, Fx.F_GLOW, HIT, 1.8)
	if f.hp <= 0:
		kill(i, false)


## Destroys craft i (also used by capital-ship flak): an explosion where it is drawn now.
func kill(i: int, big: bool) -> void:
	var f: Craft = crafts[i]
	if not f.alive:
		return
	f.alive = false
	if f.tgt >= 0:
		_attackers[f.tgt] = maxi(_attackers[f.tgt] - 1, 0)
		f.tgt = -1
	_attackers[i] = 0
	var v := f.fwd * f.speed
	var p := f.pos + v * (fx.now - f.st)
	if big or f.bomber or fx.rng.randf() < 0.4:
		fx.boom(p, v, 34.0 if f.bomber else 22.0, fx.now)
	else:
		fx.pop(p, v, 16.0, fx.now)
	_hide(f)
	f.respawn_at = fx.now + fx.rng.randf_range(7.0, 16.0) / (0.55 + 0.6 * fx.intensity)


func _reset(f: Craft) -> void:
	f.alive = true
	f.hp = 6 if f.bomber else 4
	f.st = fx.now
	f.tgt = -1
	f.cap = null
	f.burst = 0
	f.gun_cd = 0.0
	f.msl_cd = fx.rng.randf_range(4.0, 15.0)
	f.threat = 0.0
	f.threat_src = -1
	f.retarget_t = 0.0


## Relaunch: out of a friendly carrier's hangar bay, or a jump in at the craft's end of the zone.
func _launch(f: Craft) -> void:
	var z: Zone = zones[f.zone]
	var c := fleet.carrier_in(f.zone, f.team)
	_reset(f)
	if c != null:
		var bays: PackedVector3Array = c.model["bays"]
		var bay := bays[fx.rng.randi() % bays.size()]
		f.pos = c.pos + c.basis * bay
		f.fwd = (c.basis * Vector3(signf(bay.x), 0.0, -0.5)).normalized()
		f.up = _ortho(c.up, f.fwd, z.up)
		f.speed = 60.0
		f.mode = LAUNCH
		f.mode_t = fx.rng.randf_range(1.4, 2.2)
		fx.flash(f.pos, Vector3.ZERO, 3.0, 14.0, fx.now, 0.45, Fx.F_GLOW, BAY_COL[f.team], 1.1)
	else:
		var side := -1.0 if f.team == 0 else 1.0
		f.pos = z.center + z.a * (side * z.ext.x * fx.rng.randf_range(0.8, 1.0)) \
				+ z.d * (fx.rng.randf_range(-0.5, 0.5) * z.ext.y) + z.n * (fx.rng.randf_range(-0.6, 0.6) * z.ext.z)
		f.fwd = ((z.center - f.pos).normalized() + fx.rand_dir() * 0.3).normalized()
		f.up = _ortho(z.up, f.fwd, Vector3.UP)
		f.speed = 140.0
		f.mode = FORM if f.bomber else PURSUE
		f.mode_t = fx.rng.randf_range(4.0, 10.0)
		if f.bomber:
			f.aim = _rally(f)
		fx.streak(f.pos, Vector3.ZERO, f.fwd * 80.0, 3.0, fx.now, 0.45, Fx.WARP * 1.6, Fx.S_BEAM)
		fx.flash(f.pos, Vector3.ZERO, 2.0, 16.0, fx.now, 0.35, Fx.F_GLOW, Fx.WARP, 1.2)
	_write(f)


## Initial placement: already fighting somewhere on its own half.
func _spawn_in_zone(f: Craft) -> void:
	var z: Zone = zones[f.zone]
	var keep_st := f.st
	_reset(f)
	f.st = keep_st
	f.pos = z.rand_point(fx.rng, -1.0 if f.team == 0 else 1.0, 0.8)
	f.fwd = ((z.center - f.pos).normalized() + fx.rand_dir() * 0.6).normalized()
	f.up = _ortho(z.up, f.fwd, Vector3.UP)
	f.speed = 85.0 if f.bomber else 125.0
	f.mode = FORM if f.bomber else PURSUE
	f.mode_t = fx.rng.randf_range(2.0, 12.0)
	if f.bomber:
		f.aim = _rally(f)
	_write(f)


## Live craft of `team` in zone zi within r of pos, as triplets (position, velocity, (index, bomber, 0)).
func threats(zi: int, team: int, pos: Vector3, r: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var r2 := r * r
	var lst: PackedInt32Array = _zone_idx[zi]
	for j in lst:
		var f: Craft = crafts[j]
		if f.alive and f.team == team and f.pos.distance_squared_to(pos) < r2:
			out.append(f.pos)
			out.append(f.fwd * f.speed)
			out.append(Vector3(float(j), 1.0 if f.bomber else 0.0, 0.0))
	return out


# --- GPU buffers -----------------------------------------------------------------------------

func _write(f: Craft) -> void:
	var k := f.slot * 16
	var x := f.fwd.cross(f.up)
	var u := f.up
	var b := -f.fwd
	var v := f.fwd * f.speed
	_cbuf[k] = x.x
	_cbuf[k + 1] = u.x
	_cbuf[k + 2] = b.x
	_cbuf[k + 3] = f.pos.x
	_cbuf[k + 4] = x.y
	_cbuf[k + 5] = u.y
	_cbuf[k + 6] = b.y
	_cbuf[k + 7] = f.pos.y
	_cbuf[k + 8] = x.z
	_cbuf[k + 9] = u.z
	_cbuf[k + 10] = b.z
	_cbuf[k + 11] = f.pos.z
	_cbuf[k + 12] = v.x
	_cbuf[k + 13] = v.y
	_cbuf[k + 14] = v.z
	_cbuf[k + 15] = f.st
	_c_dirty = true


func _hide(f: Craft) -> void:
	var k := f.slot * 16
	for j in 16:
		_cbuf[k + j] = 0.0
	_c_dirty = true


func _push() -> void:
	if not _c_dirty:
		return
	_c_dirty = false
	for m in 4:
		var a := _mm_from[m]
		var e := _mm_to[m]
		if e > a:
			RenderingServer.multimesh_set_buffer(_mm_rid[m], _cbuf.slice(a * 16, e * 16))


# --- Math ------------------------------------------------------------------------------------

## cur turned toward want by at most max_ang (both unit); a reversal pitches up around up_hint.
static func _turn(cur: Vector3, want: Vector3, max_ang: float, up_hint: Vector3) -> Vector3:
	var d := cur.dot(want)
	if d > 0.99999:
		return want
	var axis := cur.cross(want)
	if axis.length_squared() < 0.000001:
		axis = cur.cross(up_hint)
		if axis.length_squared() < 0.000001:
			axis = cur.cross(Vector3.RIGHT)
	axis = axis.normalized()
	return cur.rotated(axis, minf(acos(clampf(d, -1.0, 1.0)), max_ang)).normalized()


## v made perpendicular to unit f and normalized (fallback, then any perpendicular).
static func _ortho(v: Vector3, f: Vector3, fallback: Vector3) -> Vector3:
	var o := v - f * v.dot(f)
	if o.length_squared() < 0.0001:
		o = fallback - f * fallback.dot(f)
		if o.length_squared() < 0.0001:
			o = f.cross(Vector3.RIGHT)
			if o.length_squared() < 0.0001:
				o = f.cross(Vector3.FORWARD)
	return o.normalized()
