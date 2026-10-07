extends Node3D
## Topçu nişangahı: the Havan's fire control (a child of scripts/items/mortar.gd): the firing solution,
## the marks it can lock onto, and the 3D aim drawing (arc, landing ring, beam).
##   Solution  the tube fires at an elevation above the local horizon taken from a table (ELEV_NEAR
##             at RANGE_MIN falling to ELEV_FAR at RANGE_MAX: high lobs close by, flatter far out so
##             the apex stays well inside the home planet's pull) and solves the SPEED for the range:
##             an analytic two-body first guess (the orbit equation for the home planet), then a
##             bracketed secant (Illinois) on a gravity-only flight with the shell's own steps (both
##             planets pull: the rival planet bends a long shot by tens of metres), and up to
##             SOLVE_PASSES passes that move a virtual target against the remaining miss (the side
##             drift). The exact trace (mortar_shell.gd trace: the same steps as the flight, with the
##             terrain and bodies) then gives the true landing point the marker shows.
##   Manual    the mouse wheel sets the range (RANGE_STEP m), the body's facing the azimuth; the target
##             is the generator's ground at that arc distance (the trace finds the real ground).
##   Marks     what T can lock onto, nearest first (T again: the next one; after the last: unlocked):
##               the scanner's reveal: tunnel_scanner.gd revealed_targets() (read only): enemy bots,
##                 drilling torpedoes and cores (SCAN_KINDS; ore veins and caches are no targets) are
##                 marked while shown, tracking them live, and keep their LAST KNOWN position for
##                 MARK_HOLD s after the reveal fades ("son konum"); the enemy player (group
##                 "net_player", not in that list) is marked from the scanner's pulsed(origin) by the
##                 same rule (within Balance.SCAN_RANGE, when the wave reaches him, SCAN_TIME s live)
##               team pings: the build tool's "BURAYA KUR" pings (scripts/war/build_intent.gd, its
##                 node's ping list read only: ours and the co-op partner's)
##             A locked mark solves azimuth and speed by itself; a shot needs the body facing within
##             LOCK_CONE of its bearing. A trace that comes down short of the target (a hill or a wall
##             in the way) raises the elevation by ELEV_STEP per update up to ELEV_MAX (over the hill).
##             A target under the ground is aimed at the ground above it.
##   Drawing   the dashed arc, a ring the size of the blast on the ground and a beam over it, all drawn
##             through the terrain (no depth test): amber manual, green locked on a hit, red blocked.
## API (mortar.gd / its HUD): range_set, step_range(dir), cycle_lock() -> String, unlock(), locked
## (mark or {}), lock_status ("hit", "near", "blocked", "reach", ""), preview ({} or "points", "position",
## "normal", "time", "elev", "speed", "land_m", "ok"), candidates() (marks: "pos", "label", "kind",
## "dist", "last"), off_angle (rad, signed, the locked bearing against the facing), fire_block() ->
## String ("" = may fire), solution(fresh) -> {"p0", "v0", ...}.

const Bodies := preload("res://scripts/planet/bodies.gd")
const Balance := preload("res://scripts/war/balance.gd")
const MortarShell := preload("res://scripts/items/mortar_shell.gd")
const VM := preload("res://scripts/player/vm_parts.gd")

# --- Tuning -----------------------------------------------------------------------------------------
const RANGE_MIN := 15.0            # m of arc along the ground
const RANGE_MAX := 140.0
const RANGE_STEP := 5.0
const RANGE_START := 45.0
const ELEV_NEAR := 62.0            # deg above the horizon at RANGE_MIN ...
const ELEV_FAR := 28.0             # ... at RANGE_MAX (flight ~3 s close, ~11-14 s far; apex <= ~38 m)
const ELEV_CURVE := 0.8
const ELEV_MAX := 80.0             # a locked shot over a hill may climb to this
const ELEV_STEP := 7.0
const V_MIN := 3.0                 # m/s
const V_MAX := 25.0                # (escape from the surface: ~30.7 m/s)
const SOLVE_TOL := 0.12            # m along the range
const MISS_TOL := 0.2              # m left after the drift passes
const SOLVE_PASSES := 3
const HIT_TOL := 2.5               # m: a locked trace that lands this close counts as a hit
const BIAS_MAX := 12.0             # m: the most a lock corrects its aim for the ground at the target
const UPDATE := 0.05               # s from one finished sight trace to the next solve
const TRACE_STEPS := 45            # flight steps of the sight trace per frame (a 12 s flight: ~8 frames)
const LOCK_CONE := 0.7             # rad (40°)
const MARK_HOLD := 20.0            # s after the scan's reveal a mark keeps its last known position
const MARK_RANGE := 160.0          # m: farther marks are not offered
const SCAN_KINDS := ["bot", "torpedo", "core"]   # what of the scanner's reveal can be locked (not veins / caches)
const MAX_FLIGHT := 30.0           # s
const UNDERGROUND := 1.5           # m below the ground: aim at the ground above
const MANUAL_COL := Color(1.0, 0.66, 0.26)
const LOCK_COL := Color(0.42, 1.0, 0.6)
const BAD_COL := Color(1.0, 0.36, 0.3)

var weapon                          # mortar.gd
var range_set := RANGE_START
var locked := {}
var lock_status := ""
var preview := {}
var off_angle := 0.0
var marks: Array = []               # {"kind", "node", "pos", "reveal", "live_until", "expire", "label"}
var scans := 0

var _clock := 0.0
var _upd_t := 0.0
var _mark_t := 0.0
var _warm := {}                     # {"elev", "speed", "shift"} of the last solve
var _lock_elev := -1.0
var _job := {}                      # the sight trace in progress (MortarShell.trace_job + "sol")
var _bias := Vector3.ZERO           # locked: the aim offset learnt from the traces' misses on the ground
var _scanner: Object = null
var _pings: Array = []
var _arc_im: ImmediateMesh
var _arc: MeshInstance3D
var _arc_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _beam: MeshInstance3D
var _beam_mat: StandardMaterial3D
var _show := false


func _ready() -> void:
	_build_viz()


# =================================================================================================
# Per frame (mortar.gd _tick)
# =================================================================================================

## on: the Havan is held and usable; aiming: Topçu modu (RMB).
func tick(delta: float, on: bool, aiming: bool) -> void:
	_clock += delta
	_hook_scanner()
	_mark_t -= delta
	if _mark_t <= 0.0:
		_mark_t = 0.25
		_refresh_marks()
	if not locked.is_empty() and _find(locked).is_empty():
		locked = {}
		lock_status = ""
		_lock_elev = -1.0
		if on:
			MortarShell.toast("Hedef kayboldu — kilit açıldı", 0, "mortar_lock", 1.6)
	_show = on and aiming
	if on and not locked.is_empty():
		_update_off()
	if on and (aiming or not locked.is_empty()):
		if not _job.is_empty():
			if MortarShell.trace_step(_job, TRACE_STEPS, get_world_3d().direct_space_state, [weapon.player.get_rid()], MAX_FLIGHT):
				_finish_job()
		else:
			_upd_t -= delta
			if _upd_t <= 0.0:
				_upd_t = UPDATE
				_start_job()
	else:
		_upd_t = 0.0
		_job = {}
		if not on:
			preview = {}
	_draw_viz()


func step_range(dir: int) -> void:
	var nr := clampf(snappedf(range_set + RANGE_STEP * dir, RANGE_STEP), RANGE_MIN, RANGE_MAX)
	if not locked.is_empty():
		# The wheel takes the tube back: manual at the locked range.
		nr = clampf(snappedf(float(preview.get("land_m", range_set)), RANGE_STEP), RANGE_MIN, RANGE_MAX)
		unlock()
	range_set = nr
	_upd_t = 0.0
	_job = {}


func unlock() -> void:
	locked = {}
	lock_status = ""
	_lock_elev = -1.0
	_warm = {}
	_bias = Vector3.ZERO
	_upd_t = 0.0
	_job = {}


## T: the nearest mark, then the next; after the last one the lock opens. The message for the HUD.
func cycle_lock() -> String:
	var c := candidates()
	if c.is_empty():
		unlock()
		return "İşaretli hedef yok — Q ile tara ya da İnşa Aracıyla işaret koy"
	var i := -1
	if not locked.is_empty():
		for k in c.size():
			if _same(c[k], locked):
				i = k
				break
		if i == c.size() - 1:
			unlock()
			return "Kilit açık — elle nişan"
	locked = c[i + 1]
	lock_status = ""
	_lock_elev = -1.0
	_warm = {}
	_bias = Vector3.ZERO
	_upd_t = 0.0
	_job = {}
	return ""


## Why the tube may not fire now ("" = it may).
func fire_block() -> String:
	if locked.is_empty():
		return ""
	_update_off()
	if absf(off_angle) > LOCK_CONE:
		return "HEDEFE DÖN"
	if lock_status == "reach":
		return "MENZİL DIŞI"
	return ""


# =================================================================================================
# Geometry of the shot
# =================================================================================================

## The elevation (deg above the local horizon) the table gives for an arc range (m).
static func table_elev(range_m: float) -> float:
	var u := clampf((range_m - RANGE_MIN) / (RANGE_MAX - RANGE_MIN), 0.0, 1.0)
	return lerpf(ELEV_NEAR, ELEV_FAR, pow(u, ELEV_CURVE))


## Where the shell leaves the tube (world): just below and right of the eye, ahead of the body. The
## same point for the sight and the shot (the drawn shell starts at the view model's mouth instead).
func launch_point() -> Vector3:
	var pl = weapon.player
	var cam: Camera3D = pl.camera
	var b: Basis = (pl as Node3D).global_transform.basis
	return cam.global_position + b.y * -0.3 - b.z * 0.5 + b.x * 0.15


## The body's facing as a unit tangent at p (the azimuth of a manual shot).
func facing(p: Vector3) -> Vector3:
	var pl = weapon.player
	var up := _up(p)
	var f: Vector3 = -(pl as Node3D).global_transform.basis.z
	f -= up * f.dot(up)
	return f.normalized() if f.length_squared() > 1e-6 else up.cross(Vector3.RIGHT).normalized()


## The point the tube aims at now: the locked mark (the ground above it when it is buried), else
## the ground range_set m away along the facing.
func target_point(p0: Vector3) -> Vector3:
	var b := Bodies.dominant(p0)
	if b == null:
		return Vector3.INF
	var c: Vector3 = (b as Node3D).global_position
	if not locked.is_empty():
		var tp: Vector3 = _pos_of(locked)
		var u := (tp - c).normalized()
		var ground := float(b.radius) + float(b.surface_height_at(tp))
		if ground - tp.distance_to(c) > UNDERGROUND:
			return c + u * ground
		return tp
	var up0 := (p0 - c).normalized()
	var th := range_set / float(b.radius)
	var u2 := (up0 * cos(th) + facing(p0) * sin(th)).normalized()
	return c + u2 * (float(b.radius) + float(b.surface_height_at(c + u2 * float(b.radius))))


## The firing solution now: {"p0", "v0", "elev", "speed", "ok", "target"} ({} without a planet).
## fresh: the shot (solved at this very instant; the sight solves the same way, warm-started).
func solution(_fresh := false) -> Dictionary:
	if weapon == null or weapon.player == null:
		return {}
	var p0 := launch_point()
	var tgt := target_point(p0)
	if not tgt.is_finite():
		return {}
	var elev := _lock_elev if (not locked.is_empty() and _lock_elev > 0.0) else table_elev(arc_m(p0, tgt))
	# Locked: aim off by what the last trace missed on the real ground (the solve meets the target's
	# radius; a slope there moves the hit).
	var sol := solve(p0, tgt + (_bias if not locked.is_empty() else Vector3.ZERO), elev, _warm)
	if sol.is_empty():
		return {}
	sol["p0"] = p0
	sol["target"] = tgt
	return sol


## Arc distance (m, along the home planet's radius) between two points seen from its centre.
static func arc_m(a: Vector3, b: Vector3) -> float:
	var body := Bodies.dominant(a)
	if body == null:
		return a.distance_to(b)
	var c: Vector3 = (body as Node3D).global_position
	return (a - c).angle_to(b - c) * float(body.radius)


# =================================================================================================
# The solver
# =================================================================================================

## Launch velocity from p0 that brings a shell down onto `target` (world) at `elev` deg above the
## local horizon: {"v0", "speed", "elev", "ok"} (ok false: out of reach at this elevation, v0 the
## closest try) plus "shift" / "passes" for a warm start. warm: a previous result for the same
## elevation ("speed", "shift").
static func solve(p0: Vector3, target: Vector3, elev: float, warm: Dictionary = {}) -> Dictionary:
	var b := Bodies.dominant(p0)
	if b == null:
		return {}
	var c: Vector3 = (b as Node3D).global_position
	var bl := _bodies()
	var up0 := (p0 - c).normalized()
	var r0 := p0.distance_to(c)
	var r1 := target.distance_to(c)
	var mu := float(b.gravity_surface) * 9.81 * float(b.radius) * float(b.radius)
	var gam := deg_to_rad(elev)
	var shift: Vector3 = warm.get("shift", Vector3.ZERO) if warm.get("elev", -1.0) == elev else Vector3.ZERO
	var v_warm := float(warm.get("speed", -1.0)) if warm.get("elev", -1.0) == elev else -1.0
	var tdir := (target - c).normalized()
	var out := {}
	for pass_i in SOLVE_PASSES:
		var aim := target + shift
		var ut := (aim - c).normalized()
		var az := ut - up0 * ut.dot(up0)
		if az.length_squared() < 1e-8:
			az = up0.cross(Vector3.RIGHT if absf(up0.x) < 0.9 else Vector3.FORWARD)
		az = az.normalized()
		var theta := atan2(ut.dot(az), ut.dot(up0))
		var dir := (az * cos(gam) + up0 * sin(gam)).normalized()
		var v0 := v_warm if v_warm > 0.0 else _analytic(theta, gam, r0, r1, mu)
		if v0 <= 0.0:
			v0 = V_MAX
		var sp := _solve_speed(p0, dir, c, r1, up0, az, theta, clampf(v0, V_MIN, V_MAX), bl, v_warm > 0.0)
		var v := float(sp["v"])
		out = {"v0": dir * v, "speed": v, "elev": elev, "ok": bool(sp["ok"]), "shift": shift, "passes": pass_i + 1}
		var L: Vector3 = sp["land"]
		if not bool(sp["ok"]) or L == Vector3.ZERO:
			break
		# What is left (mostly the side drift): move the virtual target against it.
		var miss := (tdir - L) * r1
		miss -= tdir * miss.dot(tdir)
		if miss.length() < MISS_TOL:
			break
		shift += miss
		v_warm = v
	return out


## Speed along `dir` whose gravity-only flight comes down through radius r1 at the arc angle theta
## (Illinois on the angle error, bracketed). {"v", "ok", "land" (unit dir from c, ZERO = none)}.
static func _solve_speed(p0: Vector3, dir: Vector3, c: Vector3, r1: float, up0: Vector3, az: Vector3, theta: float,
		v0: float, bl: Array, warm: bool) -> Dictionary:
	var k := 0.03 if warm else 0.15
	var lo := maxf(v0 * (1.0 - k), V_MIN)
	var hi := minf(v0 * (1.0 + k), V_MAX)
	var rl := _err(p0, dir * lo, c, r1, up0, az, theta, bl)
	var rh := _err(p0, dir * hi, c, r1, up0, az, theta, bl)
	var tries := 0
	while float(rl[0]) > 0.0 and lo > V_MIN and tries < 8:
		hi = lo
		rh = rl
		lo = maxf(lo * 0.75, V_MIN)
		rl = _err(p0, dir * lo, c, r1, up0, az, theta, bl)
		tries += 1
	while float(rh[0]) < 0.0 and hi < V_MAX and tries < 16:
		lo = hi
		rl = rh
		hi = minf(hi * 1.25, V_MAX)
		rh = _err(p0, dir * hi, c, r1, up0, az, theta, bl)
		tries += 1
	if float(rl[0]) > 0.0:
		return {"v": lo, "ok": false, "land": rl[1]}
	if float(rh[0]) < 0.0:
		return {"v": hi, "ok": false, "land": rh[1]}
	var fl := float(rl[0])
	var fh := float(rh[0])
	var best := [lo, rl]
	var side := 0
	for i in 14:
		var v := (lo * fh - hi * fl) / (fh - fl) if absf(fh - fl) > 1e-9 else (lo + hi) * 0.5
		if not (v > lo and v < hi):
			v = (lo + hi) * 0.5
		var r := _err(p0, dir * v, c, r1, up0, az, theta, bl)
		var f := float(r[0])
		best = [v, r]
		if absf(f) * r1 < SOLVE_TOL or hi - lo < 1e-4:
			break
		if f > 0.0:
			hi = v
			fh = f
			if side == 1:
				fl *= 0.5
			side = 1
		else:
			lo = v
			fl = f
			if side == -1:
				fh *= 0.5
			side = -1
	var br: Array = best[1]
	return {"v": float(best[0]), "ok": absf(float(br[0])) * r1 < 2.0, "land": br[1]}


## [arc angle error (rad, + = long), landing unit dir] of a gravity-only flight (the shell's steps)
## coming down through radius r1. Never coming down = long (it left), sinking deep = short.
static func _err(p0: Vector3, v0: Vector3, c: Vector3, r1: float, up0: Vector3, az: Vector3, theta: float, bl: Array) -> Array:
	var p := p0
	var v := v0
	var t := 0.0
	var dt := MortarShell.STEP
	var pr := p.distance_to(c)
	var r_low := r1 - 25.0
	while t < MAX_FLIGHT:
		var g := _g(p, bl)
		var np := p + v * dt + g * (0.5 * dt * dt)
		v += g * dt
		t += dt
		var r := np.distance_to(c)
		if r <= r1 and pr > r1:
			var k := (pr - r1) / maxf(pr - r, 1e-6)
			var L := (p.lerp(np, clampf(k, 0.0, 1.0)) - c).normalized()
			return [atan2(L.dot(az), L.dot(up0)) - theta, L]
		if r < r_low:
			return [-theta - 1.0, Vector3.ZERO]
		if r > 240.0:
			break
		pr = r
		p = np
	return [PI, Vector3.ZERO]


## Two-body first guess: speed at flight-path angle gam from radius r0 that comes down at radius r1
## theta rad around (the orbit equation). -1 when this elevation cannot get there.
static func _analytic(theta: float, gam: float, r0: float, r1: float, mu: float) -> float:
	var den := cos(gam) * (r0 * cos(gam) - r1 * cos(theta + gam))
	if den <= 1e-6:
		return -1.0
	var nu := r1 * (1.0 - cos(theta)) / den
	return sqrt(maxf(nu, 0.0) * mu / r0)


## [centre, surface g, radius] of every planet (the solver's gravity: Game.gravity_at's own rule).
static func _bodies() -> Array:
	var out: Array = []
	for b in Bodies.all():
		if is_instance_valid(b):
			out.append([(b as Node3D).global_position, float(b.gravity_surface) * 9.81, float(b.radius)])
	return out


static func _g(p: Vector3, bl: Array) -> Vector3:
	var g := Vector3.ZERO
	for e: Array in bl:
		var d: Vector3 = p - (e[0] as Vector3)
		var r := d.length()
		if r < 0.001:
			continue
		var rr: float = e[2]
		var a: float = float(e[1]) * (r / rr if r < rr else (rr / r) * (rr / r))
		g -= d / r * a
	return g


func _up(p: Vector3) -> Vector3:
	var b := Bodies.dominant(p)
	var c: Vector3 = (b as Node3D).global_position if b != null else Game.planet_center()
	return (p - c).normalized()


# =================================================================================================
# The sight: solve, trace, judge
# =================================================================================================

## The whole sight update at once (start, the full trace, the judgement): tests, a forced refresh.
func _update_preview() -> void:
	_start_job()
	if not _job.is_empty():
		MortarShell.trace_step(_job, 1 << 30, get_world_3d().direct_space_state, [weapon.player.get_rid()], MAX_FLIGHT)
		_finish_job()


## Solves for the current inputs and starts the trace of that shot (advanced TRACE_STEPS a frame).
func _start_job() -> void:
	var sol := solution()
	if sol.is_empty():
		preview = {}
		_job = {}
		return
	_warm = {"elev": sol["elev"], "speed": sol["speed"], "shift": sol.get("shift", Vector3.ZERO)}
	_job = MortarShell.trace_job(sol["p0"], sol["v0"], true)
	_job["sol"] = sol


## The trace is over: publish it as the preview; locked, judge the bearing and whether it gets there.
func _finish_job() -> void:
	var sol: Dictionary = _job["sol"]
	var tr := {"points": _job["points"], "elev": sol["elev"], "speed": sol["speed"], "ok": sol["ok"], "target": sol["target"]}
	for k in ["position", "normal", "time"]:
		if _job.has(k):
			tr[k] = _job[k]
	_job = {}
	var p0: Vector3 = sol["p0"]
	var tgt: Vector3 = sol["target"]
	if tr.has("position"):
		tr["land_m"] = arc_m(p0, tr["position"])
	preview = tr
	# Locked: whether the trace gets there.
	if locked.is_empty():
		off_angle = 0.0
		lock_status = ""
		return
	if not bool(sol["ok"]):
		lock_status = "reach"
		return
	if tr.has("position") and (tr["position"] as Vector3).distance_to(tgt) <= HIT_TOL:
		lock_status = "hit"
		_learn_bias(tgt, tr["position"])
		return
	# Down short of the target (a hill, a wall): next time a higher lob.
	var short := not tr.has("position") or arc_m(p0, tr["position"]) < arc_m(p0, tgt) - HIT_TOL
	if short and _lock_elev < ELEV_MAX:
		if _lock_elev < 0.0:
			_lock_elev = float(sol["elev"])
		_lock_elev = minf(_lock_elev + ELEV_STEP, ELEV_MAX)
		_warm = {}
		_bias = Vector3.ZERO
		_upd_t = 0.0
	lock_status = "blocked" if short else "near"
	if not short:
		_learn_bias(tgt, tr["position"])


## The trace came down at L instead of tgt (the ground there is not at the target's radius): aim
## that much further next time (BIAS_MAX at most).
func _learn_bias(tgt: Vector3, L: Vector3) -> void:
	var up := _up(tgt)
	var m := tgt - L
	m -= up * m.dot(up)
	if m.length() > 0.15:
		_bias = (_bias + m).limit_length(BIAS_MAX)


## The locked target's bearing against the body's facing (signed rad, + = to the left), every frame.
func _update_off() -> void:
	var p0 := launch_point()
	var tgt := target_point(p0)
	if not tgt.is_finite():
		return
	var up0 := _up(p0)
	var bt := tgt - p0
	bt -= up0 * bt.dot(up0)
	off_angle = facing(p0).signed_angle_to(bt.normalized(), up0) if bt.length_squared() > 1e-4 else 0.0


# =================================================================================================
# Marks: scanned enemies and team pings
# =================================================================================================

## Listens to the wrist scanner (player.hand_action.scanner, made after the guns).
func _hook_scanner() -> void:
	if _scanner != null and is_instance_valid(_scanner):
		return
	var pl = weapon.player if weapon != null else null
	if pl == null:
		return
	var ha = pl.get("hand_action")
	if ha == null or not is_instance_valid(ha):
		return
	var sc = ha.get("scanner")
	if sc == null or not is_instance_valid(sc) or not sc.has_signal("pulsed"):
		return
	_scanner = sc
	if not sc.is_connected("pulsed", _on_scan):
		sc.connect("pulsed", _on_scan)


## A pulse from `origin`: every enemy within Balance.SCAN_RANGE is marked when the wave reaches it.
func _on_scan(origin: Vector3) -> void:
	scans += 1
	var me := Game.team_of(weapon.player) if weapon != null else "home"
	# The scanner lists the bots itself (revealed_targets, read in _refresh_marks); the other player
	# (group "net_player") is not in its list, so his reveal is reckoned here by its rule.
	var groups: Array = ["net_player"] if _scanner_lists() else ["war_ai", "net_player"]
	for g in groups:
		for n in get_tree().get_nodes_in_group(g):
			if not (n is Node3D) or not is_instance_valid(n) or n == weapon.player:
				continue
			var tm := Game.team_of(n)
			if tm == "" or tm == me:
				continue
			if (n.has_method("is_dead") and n.is_dead()) or n.get("dead") == true:
				continue
			var d := (n as Node3D).global_position.distance_to(origin)
			if d > Balance.SCAN_RANGE:
				continue
			var m := _mark_for(n, "", Vector3.ZERO)
			m["kind"] = "player" if g == "net_player" else "bot"
			m["pos"] = (n as Node3D).global_position
			m["reveal"] = _clock + d / maxf(Balance.SCAN_WAVE_SPEED, 1.0)
			m["live_until"] = _clock + Balance.SCAN_TIME
			m["expire"] = _clock + Balance.SCAN_TIME + MARK_HOLD
			m["label"] = _name_of(n, g)


## The scanner publishes what its reveal shows (tunnel_scanner.gd revealed_targets()).
func _scanner_lists() -> bool:
	return _scanner != null and is_instance_valid(_scanner) and _scanner.has_method("revealed_targets")


## The scanner's reveal right now: bots, drilling torpedoes and cores become marks (live while shown,
## then their last known position for MARK_HOLD s); ore veins and caches are no targets.
func _read_scanner() -> void:
	if not _scanner_lists():
		return
	var list = _scanner.call("revealed_targets")
	if not (list is Array):
		return
	for e in list:
		if not (e is Dictionary):
			continue
		var kind := str(e.get("kind", ""))
		if not (kind in SCAN_KINDS) or float(e.get("alpha", 1.0)) < 0.05 or not (e.get("pos") is Vector3):
			continue
		var n = e.get("node")
		if n != null and not is_instance_valid(n):
			continue
		var pos: Vector3 = e["pos"]
		var m := _mark_for(n, kind, pos)
		m["kind"] = kind
		m["pos"] = pos
		m["reveal"] = minf(float(m.get("reveal", _clock)), _clock)
		m["live_until"] = _clock + 0.6
		m["expire"] = _clock + 0.6 + MARK_HOLD
		match kind:
			"bot":
				m["label"] = _name_of(n, "war_ai")
			"torpedo":
				m["label"] = "Torpido"
			_:
				m["label"] = "Çekirdek"


## The mark of node n (or, without a node, of `kind` within 1 m of pos); a new one when none.
func _mark_for(n, kind: String, pos: Vector3) -> Dictionary:
	for e in marks:
		if n != null and e.get("node") == n:
			return e
		if n == null and e.get("node") == null and str(e.get("kind")) == kind and (e["pos"] as Vector3).distance_to(pos) < 1.0:
			return e
	var m := {"node": n, "reveal": _clock}
	marks.append(m)
	return m


func _name_of(n: Node, group: String) -> String:
	if group == "net_player":
		var pn = n.get("player_name")
		return str(pn) if pn != null else "Oyuncu"
	var cs := str(n.get("callsign")) if n != null and n.get("callsign") != null else ""
	if cs == "":
		return "Bot"
	var parts := cs.split(" — ")
	return "Bot · " + parts[parts.size() - 1]


## Drops expired / dead marks, keeps live ones on their target, reads the scanner and the team pings.
func _refresh_marks() -> void:
	for i in range(marks.size() - 1, -1, -1):
		var m: Dictionary = marks[i]
		var n = m.get("node")
		# (A core's mark has no node: it stays until it expires.)
		var alive: bool = n == null or (is_instance_valid(n) and not ((n as Node).has_method("is_dead") and n.is_dead()) \
				and n.get("dead") != true)
		if _clock > float(m["expire"]) or not alive:
			marks.remove_at(i)
			continue
		if n != null and _clock <= float(m["live_until"]):
			m["pos"] = (n as Node3D).global_position
	_read_scanner()
	_pings.clear()
	var tree := get_tree()
	var bi = tree.current_scene.get_node_or_null("BuildIntent") if tree != null and tree.current_scene != null else null
	if bi == null or not is_instance_valid(bi):
		return
	var list = bi.get("_pings")
	if not (list is Array):
		return
	for p in list:
		if p is Dictionary and (p as Dictionary).get("pos") is Vector3:
			var who := str(p.get("who", ""))
			_pings.append({"kind": "ping", "pos": p["pos"], "label": "İşaret" + (" · " + who if who != "" else "")})


## The marks T can lock onto now (revealed, on our planet, in reach), nearest first. Each: "kind",
## "pos", "label", "dist" (m, arc), "last" (true: a last known position), "node" (scanned ones).
func candidates() -> Array:
	var out: Array = []
	if weapon == null or weapon.player == null:
		return out
	var me: Vector3 = (weapon.player as Node3D).global_position
	var home := Bodies.dominant(me)
	for m in marks:
		if _clock < float(m["reveal"]):
			continue
		var e: Dictionary = (m as Dictionary).duplicate()
		e["last"] = _clock > float(m["live_until"])
		out.append(e)
	for p in _pings:
		var e2: Dictionary = (p as Dictionary).duplicate()
		e2["last"] = false
		out.append(e2)
	var keep: Array = []
	for e in out:
		var pos: Vector3 = e["pos"]
		if Bodies.dominant(pos) != home:
			continue
		e["dist"] = arc_m(me, pos)
		if float(e["dist"]) <= MARK_RANGE and float(e["dist"]) > 3.0:
			keep.append(e)
	keep.sort_custom(func(a, b): return float(a["dist"]) < float(b["dist"]))
	return keep


## The current state of a (copied) mark, {} if it is gone.
func _find(m: Dictionary) -> Dictionary:
	for e in candidates():
		if _same(e, m):
			return e
	return {}


static func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.get("kind") != b.get("kind"):
		return false
	if a.get("node") != null or b.get("node") != null:
		return a.get("node") == b.get("node")
	return (a["pos"] as Vector3).distance_to(b["pos"]) < 0.05


## Where a locked mark is now (live while the scan shows it, else its last known position).
func _pos_of(m: Dictionary) -> Vector3:
	var cur := _find(m)
	if cur.is_empty():
		return m["pos"]
	locked = cur
	return cur["pos"]


# =================================================================================================
# 3D drawing: dashed arc, landing ring (blast size), beam; seen through the terrain
# =================================================================================================

func _build_viz() -> void:
	_arc_im = ImmediateMesh.new()
	_arc = MeshInstance3D.new()
	_arc.mesh = _arc_im
	_arc.top_level = true
	_arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arc.custom_aabb = AABB(Vector3.ONE * -5000.0, Vector3.ONE * 10000.0)
	_arc_mat = _see_through(Color.WHITE, true)
	_arc.material_override = _arc_mat
	add_child(_arc)
	_arc.global_transform = Transform3D.IDENTITY
	var tm := TorusMesh.new()
	tm.inner_radius = 0.94
	tm.outer_radius = 1.0
	tm.rings = 56
	tm.ring_segments = 4
	_ring_mat = _see_through(MANUAL_COL, false)
	_ring = MeshInstance3D.new()
	_ring.mesh = tm
	_ring.material_override = _ring_mat
	_ring.top_level = true
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	var cm := CylinderMesh.new()
	cm.top_radius = 0.02
	cm.bottom_radius = 0.12
	cm.height = 10.0
	cm.radial_segments = 8
	cm.rings = 1
	_beam_mat = _see_through(MANUAL_COL, false)
	_beam = MeshInstance3D.new()
	_beam.mesh = cm
	_beam.material_override = _beam_mat
	_beam.top_level = true
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beam)
	_arc.visible = false
	_ring.visible = false
	_beam.visible = false


static func _see_through(col: Color, vcol: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.vertex_color_use_as_albedo = vcol
	m.albedo_color = col
	return m


## The colour of the sight now: amber manual, green locked on a hit, red blocked / out of reach.
func sight_color() -> Color:
	if not locked.is_empty():
		match lock_status:
			"hit":
				return LOCK_COL
			"blocked", "reach":
				return BAD_COL
	elif not bool(preview.get("ok", true)):
		return BAD_COL
	return MANUAL_COL


func _draw_viz() -> void:
	var on := _show and preview.has("points")
	_arc.visible = on
	_ring.visible = on and preview.has("position")
	_beam.visible = _ring.visible
	if not on:
		return
	var col := sight_color()
	var pts: PackedVector3Array = preview["points"]
	_arc_im.clear_surfaces()
	if pts.size() >= 2:
		_arc_im.surface_begin(Mesh.PRIMITIVE_LINES)
		var n := pts.size()
		var phase := int(_clock * 12.0)
		for i in range(1, n - 1):
			if ((i + phase) / 2) % 2 == 1:
				continue
			var a := 0.85 * (1.0 - float(i) / float(n) * 0.5) * clampf(float(i) / 4.0, 0.0, 1.0)
			_arc_im.surface_set_color(Color(col.r, col.g, col.b, a))
			_arc_im.surface_add_vertex(pts[i])
			_arc_im.surface_set_color(Color(col.r, col.g, col.b, a))
			_arc_im.surface_add_vertex(pts[i + 1])
		_arc_im.surface_end()
	if _ring.visible:
		var p: Vector3 = preview["position"]
		var nrm: Vector3 = _up(p)
		var rr := MortarShell.BLAST_RADIUS * Balance.BLAST_RADIUS_SCALE
		var pulse := 0.5 + 0.5 * sin(_clock * 6.0)
		_ring.global_transform = Transform3D(VM.basis_y(nrm) * Basis.from_scale(Vector3(rr, 1.0, rr)), p + nrm * 0.3)
		_ring_mat.albedo_color = Color(col.r, col.g, col.b, 0.45 + 0.3 * pulse)
		_beam.global_transform = Transform3D(VM.basis_y(nrm), p + nrm * 5.0)
		_beam_mat.albedo_color = Color(col.r, col.g, col.b, 0.22 + 0.12 * pulse)
