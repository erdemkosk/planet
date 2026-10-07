extends RefCounted
## Capital ships of the background space battle (space_battle.gd): each zone holds a home ship
## (white / orange) at its -a end and a rival ship (dark / red) at its +a end, side by side so their
## broadsides face each other. They drift slowly and fight on their own:
##   broadsides  a ripple of muzzle flashes and slow glowing slugs along the side facing the enemy
##   beam lances a charge glow at the bow, then a beam that rakes the enemy hull for ~2 s
##   missile salvos corkscrewing swarms (battle_wings.gd flies them)
##   flak curtains bursts and point-defence tracers around enemy craft that come close
##   shields     hits on a shielded hull flash a coloured bubble patch; shields regenerate
##   damage      fires and venting jets appear as the hull wears down
## A director dooms one ship every few minutes (after a quiet opening): its shields collapse, it
## burns, chain explosions run along the hull, it blows apart in a huge blast and its three sections
## drift away as burning wreckage for minutes. A fresh ship warps in at the station later.
## Ticks at 5 Hz per ship (staggered). Cosmetic only.

const Fx := preload("res://scripts/fx/battle_fx.gd")
const Zone := preload("res://scripts/fx/battle_zone.gd")
const Models := preload("res://scripts/fx/battle_models.gd")

const DT := 0.2
const SLUG_SPEED := 320.0
const DRAMA_START := 200.0          # no capital ship dies in the first minutes
const WRECK_LIFE := 230.0

## Impact kinds and their shield / hull damage.
enum { K_SLUG, K_BOLT, K_MISSILE, K_TORPEDO, K_BEAM }
const POWER := [0.012, 0.003, 0.012, 0.06, 0.025]

const SLUG_COL := [Color(1.0, 0.6, 0.26) * 1.9, Color(1.0, 0.24, 0.1) * 2.1]
const MUZZLE_COL := [Color(1.0, 0.75, 0.45), Color(1.0, 0.35, 0.2)]
const BEAM_CORE := [Color(1.0, 0.82, 0.5) * 2.3, Color(1.0, 0.32, 0.34) * 2.3]
const BEAM_HALO := [Color(1.0, 0.6, 0.25) * 0.35, Color(1.0, 0.1, 0.12) * 0.35]
const FLAK_COL := [Color(1.0, 0.85, 0.55), Color(1.0, 0.5, 0.3)]
const PD_COL := [Color(1.0, 0.8, 0.45) * 1.6, Color(1.0, 0.3, 0.18) * 1.6]
const FIRE_COL := Color(1.0, 0.45, 0.12)
## Hull window strips (hull shader detail), engine halo, running lights (port red, starboard
## green, white strobes).
const WIN_COL := [Color(1.0, 0.78, 0.5), Color(1.0, 0.22, 0.1)]
const HALO_COL := [Color(1.0, 0.62, 0.3), Color(1.0, 0.25, 0.1)]
const NAV_COL := [Color(1.0, 0.12, 0.08), Color(0.2, 1.0, 0.35), Color(1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0)]
const NAV_PERIOD := [1.6, 1.6, 2.1, 2.9]
const VENT_COL := Color(0.55, 0.65, 0.75) * 0.4


class Cap:
	var idx := 0
	var kind := 0
	var team := 0
	var zone := 0
	var model: Dictionary
	var mi: MeshInstance3D
	var pos := Vector3.ZERO
	var basis := Basis()
	var station := Vector3.ZERO
	var fwd0 := Vector3.FORWARD
	var up := Vector3.UP
	var ph := 0.0
	var state := 0               # 0 fighting, 1 doomed (shields down, burning), 2 dying, 3 gone
	var shield := 1.0
	var hull := 1.0
	var st := 0.0
	var t_broad := 0.0
	var t_beam := 0.0
	var t_salvo := 0.0
	var t_state := 0.0
	var dur := 1.0
	var fires := PackedVector3Array()
	var vents := PackedVector3Array()


class Wreck:
	var mis: Array[MeshInstance3D] = []
	var xf: Array[Transform3D] = []
	var vel := PackedVector3Array()
	var spin := PackedVector3Array()
	var ctr := PackedVector3Array()
	var fire_pts := PackedVector3Array()
	var fire_sec := PackedInt32Array()
	var born := 0.0
	var st := 0.0


var fx: Fx
var zones: Array[Zone] = []
var wings                          # battle_wings.gd (untyped: it preloads this script)
var caps: Array[Cap] = []
var wrecks: Array[Wreck] = []
var _models := {}
var _ev_t := PackedFloat64Array()
var _ev_c := PackedInt32Array()
var _ev_p := PackedVector3Array()
var _ev_k := PackedInt32Array()
var _next_drama := 0.0
var _next_cook := 0.0
var _drama_team := 0
var _head_base := 0                # fx head slots _head_base + ship index: engine halos


## plan: per zone [home kind, rival kind] or [] (no capital ships there). head_base: the first fx
## head slot reserved for the engine halos (one per ship).
func setup(p_fx: Fx, p_zones: Array[Zone], p_wings, plan: Array, head_base: int) -> void:
	fx = p_fx
	zones = p_zones
	wings = p_wings
	_head_base = head_base
	var n_total := 0
	for zp: Array in plan:
		n_total += zp.size()
	for zi in plan.size():
		var zp: Array = plan[zi]
		for team in zp.size():
			var c := Cap.new()
			c.idx = caps.size()
			c.kind = int(zp[team])
			c.team = team
			c.zone = zi
			c.model = _model(c.kind)
			var z: Zone = zones[zi]
			var side := -1.0 if team == 0 else 1.0
			c.station = z.center + z.a * (side * z.ext.x * 0.55) + z.d * (z.ext.y * 0.45)
			c.fwd0 = z.n * (1.0 if team == 0 else -1.0)
			c.up = z.up
			c.ph = fx.rng.randf_range(0.0, TAU)
			c.mi = MeshInstance3D.new()
			c.mi.mesh = c.model["mesh"]
			c.mi.set_instance_shader_parameter("detail", 1.0)
			c.mi.set_instance_shader_parameter("win_col", WIN_COL[team])
			c.mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			c.mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			c.mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			c.mi.sorting_offset = -3000.0
			fx.root.add_child(c.mi)
			c.st = fx.now - DT * float(c.idx) / float(maxi(n_total, 1))
			c.t_broad = fx.now + fx.rng.randf_range(2.0, 9.0)
			c.t_beam = fx.now + fx.rng.randf_range(12.0, 30.0)
			c.t_salvo = fx.now + fx.rng.randf_range(20.0, 45.0)
			c.hull = fx.rng.randf_range(0.85, 1.0)
			caps.append(c)
			_place(c)
	_next_drama = fx.now + DRAMA_START + fx.rng.randf_range(0.0, 70.0)
	_next_cook = fx.now + fx.rng.randf_range(45.0, 90.0)
	_drama_team = fx.rng.randi() % 2


func _model(kind: int) -> Dictionary:
	if not _models.has(kind):
		_models[kind] = Models.capital(kind, fx.hull_cap, fx.glow_cap)
	return _models[kind]


func teardown() -> void:
	for c in caps:
		if is_instance_valid(c.mi):
			c.mi.queue_free()
	for w in wrecks:
		for mi in w.mis:
			if is_instance_valid(mi):
				mi.queue_free()
	caps.clear()
	wrecks.clear()


# --- Queries for the craft (battle_wings.gd) -------------------------------------------------

## A fighting (or doomed) enemy capital ship in the zone, or null.
func enemy_cap(zi: int, team: int) -> Cap:
	var best: Cap = null
	for c in caps:
		if c.zone == zi and c.team != team and c.state <= 1:
			if best == null or c.state == 1:
				best = c
	return best


## A friendly carrier in the zone that can launch craft, or null.
func carrier_in(zi: int, team: int) -> Cap:
	for c in caps:
		if c.zone == zi and c.team == team and c.state == 0 and bool(c.model["carrier"]):
			return c
	return null


func rand_pt(c: Cap) -> Vector3:
	var pts: PackedVector3Array = c.model["pts"]
	return pts[fx.rng.randi() % pts.size()]


## A hull point on the side of c that faces `from` (battle-local), so the hit flash shows.
func facing_pt(c: Cap, from: Vector3) -> Vector3:
	var pts: PackedVector3Array = c.model["pts"]
	var to := from - c.pos
	var lp := pts[fx.rng.randi() % pts.size()]
	for _k in 5:
		if (c.basis * Vector3(lp.x, lp.y * 0.7, 0.0)).dot(to) >= 0.0:
			return lp
		lp = pts[fx.rng.randi() % pts.size()]
	return lp


## Schedules an impact on capital ship c at ship-local point lp at time t.
func queue(t: float, c: Cap, lp: Vector3, kind: int) -> void:
	_ev_t.append(t)
	_ev_c.append(c.idx)
	_ev_p.append(lp)
	_ev_k.append(kind)


# --- Tick ------------------------------------------------------------------------------------

func tick() -> void:
	var now := fx.now
	for c in caps:
		var steps := 0
		while c.st + DT <= now and steps < 2:
			c.st += DT
			_step(c)
			steps += 1
		if c.st + DT * 3.0 < now:
			c.st = now - DT * 0.5
	var i := 0
	while i < wrecks.size():
		var w: Wreck = wrecks[i]
		if w.st + DT <= now:
			w.st += DT
			if not _wreck_step(w):
				for mi in w.mis:
					mi.queue_free()
				wrecks[i] = wrecks[wrecks.size() - 1]
				wrecks.pop_back()
				continue
		i += 1
	_events(now)
	_director(now)


func _events(now: float) -> void:
	var n := _ev_t.size()
	if n == 0:
		return
	var w := 0
	for i in n:
		if _ev_t[i] <= now:
			hit_now(caps[_ev_c[i]], _ev_p[i], _ev_k[i])
		else:
			_ev_t[w] = _ev_t[i]
			_ev_c[w] = _ev_c[i]
			_ev_p[w] = _ev_p[i]
			_ev_k[w] = _ev_k[i]
			w += 1
	if w < n:
		_ev_t.resize(w)
		_ev_c.resize(w)
		_ev_p.resize(w)
		_ev_k.resize(w)


## An impact on capital ship c at ship-local point lp: a shield flash while the shields hold,
## else a hull explosion, damage, fires.
func hit_now(c: Cap, lp: Vector3, kind: int) -> void:
	if c.state >= 2:
		return
	var wp := c.pos + c.basis * lp
	var out := c.basis * Vector3(lp.x, lp.y * 0.7, 0.0)
	out = out.normalized() if out.length_squared() > 0.01 else c.basis.y
	var power: float = POWER[kind]
	var t := fx.now
	if c.shield > 0.18 and c.state == 0:
		var hw: float = c.model["hw"]
		var sz := minf(hw * 0.3, 11.0)
		var inten := 0.35
		if kind == K_TORPEDO:
			sz = minf(hw * 1.0, 50.0)
			inten = 0.8
		elif kind != K_BOLT:
			sz = minf(hw * 0.6, 30.0)
			inten = 0.6
		fx.shield(wp + out * (sz * 0.3), sz, c.team, inten, t)
		c.shield = maxf(c.shield - power, 0.0)
		return
	match kind:
		K_BOLT:
			fx.flash(wp, Vector3.ZERO, 3.0, 9.0, t, 0.25, Fx.F_GLOW, Fx.CORE, 1.8)
		K_TORPEDO:
			fx.boom(wp + out * 4.0, out * 8.0, 75.0, t)
		K_SLUG:
			fx.pop(wp + out * 3.0, out * 10.0, 30.0, t)
		_:
			fx.pop(wp + out * 3.0, out * 10.0, 24.0, t)
	var floor_hull := 0.0 if c.state == 1 else 0.18
	c.hull = maxf(c.hull - power * 0.5, floor_hull)
	_update_damage(c)


func _update_damage(c: Cap) -> void:
	var want_f := clampi(int((1.0 - c.hull) * 8.0), 0, 7)
	while c.fires.size() < want_f:
		c.fires.append(rand_pt(c))
	var want_v := clampi(int((0.62 - c.hull) * 6.0), 0, 3)
	while c.vents.size() < want_v:
		c.vents.append(rand_pt(c))


func _place(c: Cap) -> void:
	var z: Zone = zones[c.zone]
	var t := c.st
	c.pos = c.station + z.n * (120.0 * sin(t * 0.011 + c.ph)) + z.d * (30.0 * sin(t * 0.017 + c.ph * 1.7)) \
			+ z.a * (25.0 * sin(t * 0.013 + c.ph * 0.6))
	var f := c.fwd0.rotated(c.up, 0.09 * sin(t * 0.009 + c.ph * 2.3))
	var right := f.cross(c.up).normalized()
	c.basis = Basis(right, c.up, -f)
	c.mi.transform = Transform3D(c.basis, c.pos)


func _step(c: Cap) -> void:
	if c.state == 3:
		if fx.now >= c.t_state:
			_warp_in(c)
		return
	_place(c)
	var now := c.st
	var ii := fx.intensity
	if c.state == 2:
		_dying(c)
		var ud := clampf((c.t_state - fx.now) / c.dur, 0.0, 1.0)
		_lights(c, ud * fx.rng.randf_range(0.0, 0.6))
		return
	if c.state == 0:
		c.shield = minf(c.shield + 0.02 * DT, 1.0)
	else:
		c.hull = maxf(c.hull - 0.018 * DT, 0.0)
		if fx.rng.randf() < 0.3:
			fx.pop(c.pos + c.basis * rand_pt(c), Vector3.ZERO, fx.rng.randf_range(28.0, 50.0), now + fx.rng.randf() * DT)
			_update_damage(c)
		if fx.now >= c.t_state or c.hull <= 0.02:
			c.state = 2
			c.dur = fx.rng.randf_range(7.0, 10.0)
			c.t_state = fx.now + c.dur
			return
	var tgt := enemy_cap(c.zone, c.team)
	if now >= c.t_broad:
		_broadside(c, tgt)
		c.t_broad = now + fx.rng.randf_range(6.0, 12.0) / (0.5 + ii)
	if bool(c.model["beam"]) and now >= c.t_beam and tgt != null:
		_beam(c, tgt)
		c.t_beam = now + fx.rng.randf_range(14.0, 26.0) / (0.5 + ii)
	if bool(c.model["salvo"]) and now >= c.t_salvo and tgt != null:
		var pts: PackedVector3Array = c.model["launch"]
		var from := c.pos + c.basis * pts[fx.rng.randi() % pts.size()]
		var dir0 := (c.up * 0.8 + (tgt.pos - c.pos).normalized() * 0.5).normalized()
		wings.salvo_cap(from, dir0, c.team, c.zone, tgt, fx.rng.randi_range(5, 9), now)
		c.t_salvo = now + fx.rng.randf_range(24.0, 42.0) / (0.5 + ii)
	_flak(c)
	_burn(c)
	_lights(c, 1.0 if c.state == 0 else fx.rng.randf_range(0.2, 1.0))


## Engine halo (a soft glow behind the nozzles, refreshed every step) and blinking running lights.
func _lights(c: Cap, k: float) -> void:
	var eng: Vector4 = c.model["engine"]
	fx.head(_head_base + c.idx, c.pos + c.basis * Vector3(eng.x, eng.y, eng.z), Vector3.ZERO, eng.w, c.st,
			HALO_COL[c.team], 0.32 * k * (0.92 + 0.08 * sin(c.st * 7.0 + c.ph)))
	if k < 0.5:
		return
	var bc: PackedVector3Array = c.model["beacons"]
	for i in bc.size():
		var per: float = NAV_PERIOD[i]
		if fmod(c.st + c.ph * 0.3 + float(i) * 0.37, per) < DT:
			fx.flash(c.pos + c.basis * bc[i], Vector3.ZERO, 5.0, 6.0, c.st, 0.3 if i < 2 else 0.14,
					Fx.F_GLOW, NAV_COL[i], 2.2 if i < 2 else 2.6)


func _broadside(c: Cap, tgt: Cap) -> void:
	var z: Zone = zones[c.zone]
	var guns: PackedVector3Array = c.model["guns"]
	var enemy_side := 1.0 if c.team == 0 else -1.0
	var aim_c := tgt.pos if tgt != null else z.center + z.a * (enemy_side * z.ext.x * 2.5)
	var side := 1.0 if (aim_c - c.pos).dot(c.basis.x) >= 0.0 else -1.0
	var col: Color = SLUG_COL[c.team]
	var mcol: Color = MUZZLE_COL[c.team]
	for k in guns.size():
		var g := guns[k]
		g.x *= side
		var mz := c.pos + c.basis * g
		var t0 := c.st + float(k) * 0.11 + fx.rng.randf() * 0.05
		var lp := Vector3.ZERO
		var tw := aim_c + fx.rand_dir() * 120.0
		var hit := tgt != null and fx.rng.randf() < 0.6
		if tgt != null:
			lp = facing_pt(tgt, mz)
			tw = tgt.pos + tgt.basis * lp
			if not hit:
				tw += fx.rand_dir() * fx.rng.randf_range(60.0, 160.0)
		var dir := tw - mz
		var dist := dir.length()
		dir /= maxf(dist, 1.0)
		var travel := dist / SLUG_SPEED
		fx.flash(mz + dir * 5.0, Vector3.ZERO, 5.0, 18.0, t0, 0.32, Fx.F_GLOW, mcol, 1.9)
		fx.streak(mz, dir * SLUG_SPEED, dir * 30.0, 4.5, t0, travel if hit else minf(travel * 2.5, 6.0), col, Fx.S_CONST)
		if hit:
			queue(t0 + travel, tgt, lp, K_SLUG)


func _beam(c: Cap, tgt: Cap) -> void:
	var bow: Vector3 = c.model["bow"]
	var em := c.pos + c.basis * bow
	var lp := facing_pt(tgt, em)
	var tw := tgt.pos + tgt.basis * lp
	var t0 := c.st + 1.0
	var core: Color = BEAM_CORE[c.team]
	fx.flash(em, Vector3.ZERO, 3.0, 26.0, c.st, 1.05, Fx.F_GLOW, core * 0.6, 1.0)
	fx.flash(em, Vector3.ZERO, 12.0, 30.0, t0, 2.4, Fx.F_GLOW, core * 0.4, 1.0)
	var ax := tw - em
	fx.streak(tw, Vector3.ZERO, ax, 6.0, t0, 2.4, core, Fx.S_BEAM)
	fx.streak(tw, Vector3.ZERO, ax, 24.0, t0, 2.4, BEAM_HALO[c.team], Fx.S_BEAM)
	for k in 5:
		queue(t0 + 0.2 + float(k) * 0.45, tgt, lp + fx.rand_dir() * 6.0, K_BEAM)


## Flak and point-defence fire around enemy craft within 750 m; denser (a curtain toward the
## threat) when several come at once. Rarely kills one.
func _flak(c: Cap) -> void:
	var th: PackedVector3Array = wings.threats(c.zone, 1 - c.team, c.pos, 750.0)
	var n := th.size() / 3
	var col: Color = FLAK_COL[c.team]
	var pd: Color = PD_COL[c.team]
	var ii := fx.intensity
	if n == 0:
		# idle point defence: probing bursts and tracer streams around the ship
		if fx.rng.randf() < 0.3 * (0.4 + ii):
			var p := c.pos + fx.rand_dir() * fx.rng.randf_range(150.0, 380.0)
			var t1 := c.st + fx.rng.randf() * DT
			if fx.rng.randf() < 0.6:
				var pts0: PackedVector3Array = c.model["pts"]
				var mz0 := c.pos + c.basis * pts0[fx.rng.randi() % pts0.size()]
				var dir0 := p - mz0
				var d0 := maxf(dir0.length(), 1.0)
				dir0 /= d0
				fx.streak(mz0, dir0 * 700.0, dir0 * 18.0, 1.6, t1, d0 / 700.0, pd, Fx.S_BOLT)
				t1 += d0 / 700.0
			fx.flash(p, Vector3.ZERO, 2.0, 11.0, t1, 0.42, Fx.F_GLOW, col, 1.3)
		return
	var bursts := mini(2 + int(float(n) * 1.5 * (0.5 + ii)), 10)
	var pts: PackedVector3Array = c.model["pts"]
	for _b in bursts:
		var k := fx.rng.randi() % n
		var tp := th[k * 3] + th[k * 3 + 1] * fx.rng.randf_range(0.0, 0.6) + fx.rand_dir() * fx.rng.randf_range(15.0, 70.0)
		var t0 := c.st + fx.rng.randf() * DT
		if fx.rng.randf() < 0.5:
			var mz := c.pos + c.basis * pts[fx.rng.randi() % pts.size()]
			var dir := tp - mz
			var dist := dir.length()
			dir /= maxf(dist, 1.0)
			var travel := dist / 700.0
			fx.streak(mz, dir * 700.0, dir * 18.0, 1.6, t0, travel, pd, Fx.S_BOLT)
			t0 += travel
		fx.flash(tp, Vector3.ZERO, 2.0, 11.0, t0, 0.42, Fx.F_GLOW, col, 1.5)
		if fx.rng.randf() < 0.1:
			fx.flash(tp, Vector3.ZERO, 2.0, 16.0, t0, 0.45, Fx.F_RING, col, 0.4)
		if fx.rng.randf() < 0.003 * (0.5 + ii):
			wings.kill(int(th[k * 3 + 2].x), true)
	if n >= 3:
		var mean := Vector3.ZERO
		for k in n:
			mean += th[k * 3]
		var dirc := (mean / float(n) - c.pos).normalized()
		var s1 := dirc.cross(c.up).normalized()
		var s2 := s1.cross(dirc)
		for _b in 4:
			var a := fx.rng.randf_range(0.0, TAU)
			var r := fx.rng.randf_range(0.0, 160.0)
			var p := c.pos + dirc * fx.rng.randf_range(220.0, 340.0) + (s1 * cos(a) + s2 * sin(a)) * r
			fx.flash(p, Vector3.ZERO, 2.0, 12.0, c.st + fx.rng.randf() * DT, 0.45, Fx.F_GLOW, col, 1.3)


## Fires and venting on a damaged hull.
func _burn(c: Cap) -> void:
	for fp: Vector3 in c.fires:
		if fx.rng.randf() < 0.7:
			var out := (c.basis * Vector3(fp.x, fp.y, 0.0)).normalized()
			fx.flash(c.pos + c.basis * fp + out * 2.0, out * fx.rng.randf_range(2.0, 6.0),
					fx.rng.randf_range(5.0, 9.0), fx.rng.randf_range(12.0, 22.0), c.st + fx.rng.randf() * DT,
					fx.rng.randf_range(0.5, 0.9), Fx.F_GLOW, FIRE_COL, fx.rng.randf_range(0.8, 1.2))
	for vp: Vector3 in c.vents:
		var out := (c.basis * Vector3(vp.x, vp.y, 0.0)).normalized()
		fx.streak(c.pos + c.basis * vp + out * 18.0, out * 35.0 + fx.rand_dir() * 4.0, out * 16.0, 7.0,
				c.st, 1.1, VENT_COL, Fx.S_TRAIL)


# --- Drama -----------------------------------------------------------------------------------

func _director(now: float) -> void:
	if now >= _next_drama:
		var pick: Cap = null
		for pass_i in 2:
			for c in caps:
				if c.state == 0 and (pass_i == 1 or c.team == _drama_team) and enemy_cap(c.zone, c.team) != null:
					if pick == null or fx.rng.randf() < 0.5:
						pick = c
			if pick != null:
				break
		if pick != null:
			_doom(pick)
			_drama_team = 1 - pick.team
		_next_drama = now + fx.rng.randf_range(170.0, 290.0) / (0.6 + 0.4 * fx.intensity)
	if now >= _next_cook:
		# a magazine cooks off on a worn ship: a huge flash without killing it
		var pick: Cap = null
		for c in caps:
			if c.state == 0 and c.hull < 0.75 and (pick == null or c.hull < pick.hull):
				pick = c
		if pick != null:
			fx.huge(pick.pos + pick.basis * rand_pt(pick), Vector3.ZERO, fx.rng.randf_range(200.0, 300.0), now)
			pick.hull = maxf(pick.hull - 0.08, 0.18)
			_update_damage(pick)
		_next_cook = now + fx.rng.randf_range(70.0, 130.0) / (0.5 + fx.intensity)


## Shields collapse, the ship starts to burn; it dies 30-45 s later.
func _doom(c: Cap) -> void:
	c.state = 1
	c.t_state = fx.now + fx.rng.randf_range(30.0, 45.0)
	var hw: float = c.model["hw"]
	for k in 5:
		var lp := rand_pt(c)
		fx.shield(c.pos + c.basis * lp, minf(hw * 1.1, 70.0), c.team, 0.75, fx.now + float(k) * 0.3, 0.6)
	c.shield = 0.0
	c.hull = minf(c.hull, 0.55)
	_update_damage(c)


## Chain explosions running from stern to bow, engines flickering out, then the break-up.
func _dying(c: Cap) -> void:
	var u := clampf(1.0 - (c.t_state - fx.now) / c.dur, 0.0, 1.0)
	var length: float = c.model["len"]
	var front := lerpf(length * 0.5, -length * 0.5, u)
	var pts: PackedVector3Array = c.model["pts"]
	for k in fx.rng.randi_range(1, 3):
		var lp := pts[fx.rng.randi() % pts.size()]
		for _try in 4:
			if absf(lp.z - front) < length * 0.2:
				break
			lp = pts[fx.rng.randi() % pts.size()]
		fx.boom(c.pos + c.basis * lp, Vector3.ZERO, fx.rng.randf_range(40.0, 85.0), c.st + fx.rng.randf() * DT)
	c.mi.set_instance_shader_parameter("emis_mul", fx.rng.randf_range(0.15, 1.0) * (1.0 - u))
	_burn(c)
	if fx.now >= c.t_state:
		_break(c)


func _break(c: Cap) -> void:
	var length: float = c.model["len"]
	fx.huge(c.pos, Vector3.ZERO, length * 1.6, fx.now)
	var w := Wreck.new()
	w.born = fx.now
	w.st = c.st
	var secs: Array = c.model["sections"]
	var ctrs: Array = c.model["sec_ctr"]
	var xf := Transform3D(c.basis, c.pos)
	var fwd := -c.basis.z
	var z: Zone = zones[c.zone]
	for s in 3:
		var mi := MeshInstance3D.new()
		mi.mesh = secs[s]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		mi.transform = xf
		fx.root.add_child(mi)
		mi.set_instance_shader_parameter("emis_mul", 0.06)
		mi.set_instance_shader_parameter("charred", 1.0)
		mi.set_instance_shader_parameter("detail", 1.0)
		w.mis.append(mi)
		w.xf.append(xf)
		w.ctr.append(ctrs[s])
		var push := fwd * (float(1 - s) * 3.0) + fx.rand_dir() * 1.5 + z.d * 1.3
		w.vel.append(push)
		w.spin.append(fx.rand_dir() * fx.rng.randf_range(0.004, 0.02))
	var cut: Vector2 = c.model["cut"]
	for _k in 9:
		var lp := rand_pt(c)
		var sec := 1
		if lp.z > cut.x:
			sec = 0
		elif lp.z < cut.y:
			sec = 2
		w.fire_pts.append(lp)
		w.fire_sec.append(sec)
	wrecks.append(w)
	c.mi.visible = false
	c.state = 3
	c.fires.clear()
	c.vents.clear()
	c.t_state = fx.now + fx.rng.randf_range(45.0, 90.0)


func _wreck_step(w: Wreck) -> bool:
	var age := fx.now - w.born
	if age > WRECK_LIFE:
		return false
	for s in w.mis.size():
		var xf := w.xf[s]
		var cl := w.ctr[s]
		var cw := xf * cl
		var sp := w.spin[s]
		var rate := sp.length()
		var b := xf.basis
		if rate > 0.000001:
			b = Basis(sp / rate, rate * DT) * b
		cw += w.vel[s] * DT
		xf = Transform3D(b, cw - b * cl)
		w.xf[s] = xf
		w.mis[s].transform = xf
	var k := 1.0 - age / WRECK_LIFE
	for i in w.fire_pts.size():
		if fx.rng.randf() < 0.55 * k:
			var p := w.xf[w.fire_sec[i]] * w.fire_pts[i]
			fx.flash(p, fx.rand_dir() * 3.0, fx.rng.randf_range(5.0, 9.0), fx.rng.randf_range(12.0, 24.0) * (0.5 + 0.5 * k),
					w.st + fx.rng.randf() * DT, fx.rng.randf_range(0.5, 1.0), Fx.F_GLOW, FIRE_COL, fx.rng.randf_range(0.7, 1.1))
	if fx.rng.randf() < 0.035 * k and not w.fire_pts.is_empty():
		var j := fx.rng.randi() % w.fire_pts.size()
		fx.pop(w.xf[w.fire_sec[j]] * w.fire_pts[j], Vector3.ZERO, fx.rng.randf_range(25.0, 45.0), w.st)
	return true


## A fresh ship of the same class jumps in at the station behind a warp flash.
func _warp_in(c: Cap) -> void:
	c.state = 0
	c.shield = 1.0
	c.hull = 1.0
	c.ph = fx.rng.randf_range(0.0, TAU)
	c.st = fx.now
	_place(c)
	c.mi.visible = true
	c.mi.set_instance_shader_parameter("emis_mul", 1.0)
	var length: float = c.model["len"]
	var fwd := -c.basis.z
	fx.streak(c.pos + fwd * length * 0.6, Vector3.ZERO, fwd * (length * 3.0), 30.0, fx.now, 1.1, Fx.WARP * 1.8, Fx.S_BEAM)
	fx.flash(c.pos, Vector3.ZERO, 40.0, length * 0.9, fx.now, 1.0, Fx.F_GLOW, Fx.WARP, 1.2)
	fx.flash(c.pos, Vector3.ZERO, 30.0, length * 1.3, fx.now, 1.3, Fx.F_RING, Fx.WARP, 0.6)
	c.t_broad = fx.now + fx.rng.randf_range(4.0, 8.0)
	c.t_beam = fx.now + fx.rng.randf_range(10.0, 20.0)
	c.t_salvo = fx.now + fx.rng.randf_range(15.0, 30.0)
