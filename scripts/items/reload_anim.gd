extends RefCounted
## Reload choreography player: data-driven keyframes for MW-style magazine changes (rifle.gd; built so
## weapon_base.gd can adopt it, see the hook below).
##
## weapon_base.gd adoption (intended hook, ~10 lines; NOT wired yet: another session owns that file).
## A gun declares `func _reload_profile(empty: bool) -> Dictionary` (built with mag_tactical /
## mag_empty / smg_mag from its own geometry, see rifle.gd _reload_geo) plus `_mag_hold`
## (VMHand.hold_frame of its magazine descriptor) and `left_hold` (that descriptor + "root": its
## magazine node, for the viewmodel's finger solve); then in weapon_base.gd:
##     const ReloadAnim := preload("res://scripts/items/reload_anim.gd")
##     var _ra = ReloadAnim.Player.new()
##     var left_reach_basis := Basis(); var left_reach_basis_w := 0.0; var left_reach_space := 0.0; var left_fingers := {}
##     # reload(), mag kind, after _reload_total:   if has_method("_reload_profile"): _ra.start(call("_reload_profile", _reload_empty))
##     # _tick_reload(), mag kind:   if _ra.playing: for e in _ra.advance(reload_progress(), delta): _play(e.snd, e.db, e.pitch)  else old _reload_events(u)
##     # _process() when not reloading:   _ra.idle(minf(delta, 0.033))
##     # _cancel_reload():   _ra.cancel()      (put away: _ra.reset())     _finish_mag_reload(): _ra.finish()
##     # _apply_camera():   cam.rotation += _ra.cam_rot()
##     # _update_pose():   pose = _ra.apply_gun(pose) if _ra.shown() else _blend(pose, reload pose, _reload_w)
##     # _animate_model():   if _ra.shown(): ReloadAnim.drive(self, _ra, _mag, seat, _mag_hold, delta) else ReloadAnim.release(self)
## Shell guns (reload_kind "shell") would play shotgun_shell(geo)["start" / "each" / "end" / "end_empty"]
## one phase at a time (start(prof) per phase, advance with the phase's own 0..1).
##
## Profile (Dictionary; keys on the normalized reload progress u, 0..1, which the caller scales to the
## gun's own reload time):
##   "pivot"   Vector3   gun-frame point the gun's offset rotation turns about (near the grip / well)
##   "gun"     [[u, pos, rot, k?, e?], ...]  the gun's offset: pos camera space (m), rot gun-local euler
##             (pitch, yaw, roll about the bore; rad)
##   "cam"     [[u, rot, k?, e?], ...]  additive camera rotation (pitch, yaw, roll), clamped to CAM_MAX
##   "hand"    [[u, Transform3D, space, k?, e?], ...]  the left hand frame (vm_hand.gd hand frame):
##             space 0 = gun frame (the item model: the hand stays on the gun however it moves),
##             1 = camera space (the off-screen trip to the pouch), converted every frame, so the
##             path blends from one space to the other between keys
##   "reach"   [[u, w, k?, e?]]  0..1 hand off its grip (the viewmodel's left_reach_w)
##   "lag"     [[u, w, k?, e?]]  0..1 how much the hand trails its target (free travel only, never
##             while it touches the gun or the magazine: those keys stay exact)
##   "fingers" [[u, {channel: w}], ...]  left finger pose weights (viewmodel.gd _left_finger_mix):
##             grip (its solved grip), relaxed, wrap_mag (the solved hold on the magazine), open_palm,
##             fist, shell; thumb_press (0..1) overrides the thumb
##   "mag"     [[u, state, fresh], ...]  step track: MAG_IN_GUN / MAG_IN_HAND / MAG_POUCH / MAG_DROPPED;
##             fresh = the new magazine (its glow takes the new ammo colour)
##   "extra"   {name: [[u, v, k?, e?]]}  extra channels ("charge": the charging handle, 1 = back)
##   "events"  [[u, {snd, db, pitch, sfx, p, r}], ...]  foley (snd through the gun's _play, or with
##             sfx true a Game.sfx foley set) and kicks into the secondary spring (p m/s camera space,
##             r rad/s gun-local euler)
## Interpolation: cubic Hermite through the keys with non-uniform Catmull-Rom tangents, scaled per key
## by k (1 default; 0 = the motion comes to rest on that key; > 1 whips through it) and an ease e on
## the segment arriving at a key (time warp s + e·s(s − 1): > 0 accelerates into it, an impact; < 0
## settles into it). Anticipation and overshoot are keyed (a small counter move before a swing, a key
## past the hold); the spring adds the rest. Hand rotations interpolate as rotation vectors (log map)
## about the segment's start key.
## Per reload: a smooth monotonic time warp (about ±4 % timing) and ±10 % gun / camera amplitudes
## and kicks. Secondary motion: a damped spring (pos + rot) on the gun, kicked by the events (seat bump,
## slap, bolt), a little of it in the camera; a slight lag on the left hand in free travel.

const VMHand := preload("res://scripts/player/vm_hand.gd")

const MAG_IN_GUN := 0
const MAG_IN_HAND := 1
const MAG_POUCH := 2          # hidden: in the pouch / below the frame
const MAG_DROPPED := 3        # fell free: the world copy (mag_drop.gd) falls, the view-model one is hidden

const LEFT_WRIST := Vector3(-0.026, -0.07, 0.05)   # wrist point W of the left hand frame (viewmodel _lw_h)
const PALM_N := Vector3(0.866, 0.0, -0.5)          # left hand frame: from the palm toward what it holds
const PALM_C := Vector3(-0.0204, -0.046, 0.0118)   # left palm pad's contact point (hand frame)
const CAM_MAX := 0.026                             # rad (1.5°) per axis
const SPRING_K := 260.0
const SPRING_C := 15.0                             # ζ ≈ 0.47: a visible overshoot, settled in ~0.4 s
const CAM_SPRING := 0.06                           # share of the gun spring's rotation the camera feels
const LAG_RATE := 24.0                             # 1/s: ~40 ms of hand lag in free travel
const FADE_TIME := 0.18                            # s: a cancelled reload eases out
const TIME_JITTER := 0.03
const AMP_JITTER := 0.1


# =================================================================================================
# Curves
# =================================================================================================
## Hermite / track helpers (an inner class: the Player reaches them as Crv.*).
class Crv extends RefCounted:
	static func _kk(k: Array, idx: int) -> float:
		return float(k[idx]) if k.size() > idx else 1.0


	static func _ke(k: Array, idx: int) -> float:
		return clampf(float(k[idx]), -0.95, 0.95) if k.size() > idx else 0.0


	static func _ease(s: float, e: float) -> float:
		return clampf(s + e * s * (s - 1.0), 0.0, 1.0)


	## Index i with keys[i][0] <= t < keys[i + 1][0] (t inside the track).
	static func _find(keys: Array, t: float) -> int:
		for i in range(keys.size() - 1):
			if t < float(keys[i + 1][0]):
				return i
		return keys.size() - 2


	static func _herm3(p0: Vector3, p1: Vector3, m0: Vector3, m1: Vector3, h: float, s: float) -> Vector3:
		var s2 := s * s
		var s3 := s2 * s
		return p0 * (2.0 * s3 - 3.0 * s2 + 1.0) + m0 * (h * (s3 - 2.0 * s2 + s)) + p1 * (-2.0 * s3 + 3.0 * s2) + m1 * (h * (s3 - s2))


	static func _hermf(p0: float, p1: float, m0: float, m1: float, h: float, s: float) -> float:
		var s2 := s * s
		var s3 := s2 * s
		return p0 * (2.0 * s3 - 3.0 * s2 + 1.0) + m0 * (h * (s3 - 2.0 * s2 + s)) + p1 * (-2.0 * s3 + 3.0 * s2) + m1 * (h * (s3 - s2))


	## Vector3 track [[t, v, k?, e?], ...] at t (rest tangents at both ends).
	static func _s3(keys: Array, t: float) -> Vector3:
		var n := keys.size()
		if n == 0:
			return Vector3.ZERO
		if n == 1 or t <= float(keys[0][0]):
			return keys[0][1]
		if t >= float(keys[n - 1][0]):
			return keys[n - 1][1]
		var i := Crv._find(keys, t)
		var t0 := float(keys[i][0])
		var t1 := float(keys[i + 1][0])
		var h := t1 - t0
		var s := Crv._ease(clampf((t - t0) / h, 0.0, 1.0), Crv._ke(keys[i + 1], 3))
		var m0 := Vector3.ZERO
		var m1 := Vector3.ZERO
		if i > 0:
			m0 = ((keys[i + 1][1] as Vector3) - (keys[i - 1][1] as Vector3)) / maxf(t1 - float(keys[i - 1][0]), 1e-4) * Crv._kk(keys[i], 2)
		if i + 2 < n:
			m1 = ((keys[i + 2][1] as Vector3) - (keys[i][1] as Vector3)) / maxf(float(keys[i + 2][0]) - t0, 1e-4) * Crv._kk(keys[i + 1], 2)
		return Crv._herm3(keys[i][1], keys[i + 1][1], m0, m1, h, s)


	## Float track [[t, v, k?, e?], ...] at t.
	static func _sf(keys: Array, t: float) -> float:
		var n := keys.size()
		if n == 0:
			return 0.0
		if n == 1 or t <= float(keys[0][0]):
			return float(keys[0][1])
		if t >= float(keys[n - 1][0]):
			return float(keys[n - 1][1])
		var i := Crv._find(keys, t)
		var t0 := float(keys[i][0])
		var t1 := float(keys[i + 1][0])
		var h := t1 - t0
		var s := Crv._ease(clampf((t - t0) / h, 0.0, 1.0), Crv._ke(keys[i + 1], 3))
		var m0 := 0.0
		var m1 := 0.0
		if i > 0:
			m0 = (float(keys[i + 1][1]) - float(keys[i - 1][1])) / maxf(t1 - float(keys[i - 1][0]), 1e-4) * Crv._kk(keys[i], 2)
		if i + 2 < n:
			m1 = (float(keys[i + 2][1]) - float(keys[i][1])) / maxf(float(keys[i + 2][0]) - t0, 1e-4) * Crv._kk(keys[i + 1], 2)
		return Crv._hermf(float(keys[i][1]), float(keys[i + 1][1]), m0, m1, h, s)


	static func _qlog(q: Quaternion) -> Vector3:
		if q.w < 0.0:
			q = -q
		var v := Vector3(q.x, q.y, q.z)
		var s := v.length()
		if s < 1e-7:
			return Vector3.ZERO
		return v / s * (2.0 * atan2(s, q.w))


	static func _qexp(r: Vector3) -> Quaternion:
		var a := r.length()
		if a < 1e-7:
			return Quaternion()
		return Quaternion(r / a, a)



# =================================================================================================
# Player
# =================================================================================================

class Player extends RefCounted:
	var playing := false
	var fade := 0.0                 # 1 → 0 after cancel(): the last offsets ease out
	var u := 0.0
	var uw := 0.0                   # warped progress (what the tracks are sampled at)
	var sp_pos := Vector3.ZERO      # secondary spring (camera-space m, gun-local rad)
	var sp_pos_v := Vector3.ZERO
	var sp_rot := Vector3.ZERO
	var sp_rot_v := Vector3.ZERO
	var _pivot := Vector3.ZERO
	var _w1 := 0.0
	var _w2 := 0.0
	var _amp_pos := Vector3.ONE
	var _amp_rot := Vector3.ONE
	var _amp_cam := 1.0
	var _amp_kick := 1.0
	var _t_gpos: Array = []
	var _t_grot: Array = []
	var _t_cam: Array = []
	var _t_reach: Array = []
	var _t_lag: Array = []
	var _t_hand: Array = []
	var _t_mag: Array = []
	var _t_ev: Array = []
	var _t_fing := {}
	var _t_extra := {}
	var _gpos := Vector3.ZERO
	var _grot := Vector3.ZERO
	var _cam := Vector3.ZERO
	var _reach := 0.0
	var _fade_reach := 0.0
	var _lag := 0.0
	var _fingers := {}
	var _mag := MAG_IN_GUN
	var _fresh := false
	var _extra := {}
	var _ev := 0
	var _hand := Transform3D()
	var _lag_xf := Transform3D()
	var _lag_init := false

	## Starts a choreography (a profile from the builders below) with this reload's randomization.
	func start(p: Dictionary) -> void:
		_pivot = p.get("pivot", Vector3.ZERO)
		_t_gpos = []
		_t_grot = []
		for k: Array in p.get("gun", []):
			_t_gpos.append([k[0], k[1], k[3] if k.size() > 3 else 1.0, k[4] if k.size() > 4 else 0.0])
			_t_grot.append([k[0], k[2], k[3] if k.size() > 3 else 1.0, k[4] if k.size() > 4 else 0.0])
		_t_cam = p.get("cam", [])
		_t_reach = p.get("reach", [])
		_t_lag = p.get("lag", [])
		_t_hand = p.get("hand", [])
		_t_mag = p.get("mag", [])
		_t_ev = p.get("events", [])
		_t_extra = p.get("extra", {})
		_t_fing = {}
		var fk: Array = p.get("fingers", [])
		for k: Array in fk:
			for ch in (k[1] as Dictionary):
				_t_fing[ch] = []
		for ch in _t_fing:
			for k: Array in fk:
				(_t_fing[ch] as Array).append([k[0], float((k[1] as Dictionary).get(ch, 0.0)), 0.0])
		_w1 = randf_range(-1.0, 1.0)
		_w2 = randf_range(-1.0, 1.0)
		_amp_pos = Vector3(_j(), _j(), _j())
		_amp_rot = Vector3(_j(), _j(), _j())
		_amp_cam = _j()
		_amp_kick = _j()
		u = 0.0
		uw = 0.0
		_ev = 0
		playing = true
		fade = 0.0
		_lag_init = false
		_sample()

	static func _j() -> float:
		return 1.0 + randf_range(-AMP_JITTER, AMP_JITTER)

	## Progress to `new_u` (0..1); returns the events crossed (Dictionaries), their kicks applied.
	func advance(new_u: float, dt: float) -> Array:
		var out: Array = []
		if not playing:
			idle(dt)
			return out
		u = clampf(new_u, 0.0, 1.0)
		uw = warp(u)
		while _ev < _t_ev.size() and uw >= float(_t_ev[_ev][0]):
			var e: Dictionary = _t_ev[_ev][1]
			sp_pos_v += (e.get("p", Vector3.ZERO) as Vector3) * _amp_kick
			sp_rot_v += (e.get("r", Vector3.ZERO) as Vector3) * _amp_kick
			out.append(e)
			_ev += 1
		_sample()
		_step(dt)
		return out

	## Not reloading: the fade and the spring settle.
	func idle(dt: float) -> void:
		if fade > 0.0:
			fade = maxf(fade - dt / FADE_TIME, 0.0)
		_step(dt)

	## Interrupted (melee): the hand and the gun ease back from where they are.
	func cancel() -> void:
		if playing:
			playing = false
			fade = 1.0
			_fade_reach = _reach

	## Done (u reached 1: everything is home; the spring keeps ringing out).
	func finish() -> void:
		playing = false
		fade = 0.0

	## Put away: no fade, no spring.
	func reset() -> void:
		playing = false
		fade = 0.0
		sp_pos = Vector3.ZERO
		sp_pos_v = Vector3.ZERO
		sp_rot = Vector3.ZERO
		sp_rot_v = Vector3.ZERO

	## Playing or fading out (the hand / magazine are driven).
	func shown() -> bool:
		return playing or fade > 0.0

	func _fk() -> float:
		if playing:
			return 1.0
		return fade * fade * (3.0 - 2.0 * fade)

	## The randomized time warp (monotonic, warp(0) = 0, warp(1) = 1).
	func warp(x: float) -> float:
		return clampf(x + TIME_JITTER * (_w1 * sin(PI * x) + 0.5 * _w2 * sin(TAU * x)), 0.0, 1.0)

	func gun_pos() -> Vector3:
		return _gpos * _amp_pos * _fk() + sp_pos

	func gun_rot() -> Vector3:
		return _grot * _amp_rot * _fk() + sp_rot

	## The gun's camera-space pose with the choreography offset (gun-local rotation about the pivot,
	## camera-space shift) and the secondary spring.
	func apply_gun(pose: Transform3D) -> Transform3D:
		var rot := gun_rot()
		var pos := gun_pos()
		if rot.length_squared() < 1e-12 and pos.length_squared() < 1e-12:
			return pose
		var o := Transform3D(Basis(), _pivot) * Transform3D(Basis.from_euler(rot), Vector3.ZERO) * Transform3D(Basis(), -_pivot)
		var out := pose * o
		out.origin += pos
		return out

	## Additive camera rotation (pitch, yaw, roll), at most CAM_MAX per axis.
	func cam_rot() -> Vector3:
		var c := _cam * _amp_cam * _fk() + sp_rot * CAM_SPRING
		return Vector3(clampf(c.x, -CAM_MAX, CAM_MAX), clampf(c.y, -CAM_MAX, CAM_MAX), clampf(c.z, -CAM_MAX, CAM_MAX))

	func reach_w() -> float:
		if playing:
			return _reach
		return _fade_reach * _fk()

	func fingers() -> Dictionary:
		return _fingers

	func mag_state() -> int:
		return _mag if playing else MAG_IN_GUN

	func fresh() -> bool:
		return playing and _fresh

	func extra(name: String) -> float:
		return float(_extra.get(name, 0.0)) if playing else 0.0

	## The left hand frame in the gun frame this frame (call once a frame: it integrates the lag).
	## cam_to_gun: the inverse of the gun's camera-space pose (converts the camera-space keys).
	func hand(cam_to_gun: Transform3D, dt: float) -> Transform3D:
		if not playing:
			return _hand                     # fading out: the hand eases back from its last target
		var tgt := _sample_hand(uw, cam_to_gun)
		if not _lag_init:
			_lag_xf = tgt
			_lag_init = true
		else:
			var a := 1.0 - exp(-LAG_RATE * dt)
			var q := Quaternion(_lag_xf.basis.orthonormalized()).slerp(Quaternion(tgt.basis.orthonormalized()), a)
			_lag_xf = Transform3D(Basis(q), _lag_xf.origin.lerp(tgt.origin, a))
		_hand = tgt if _lag <= 0.001 else tgt.interpolate_with(_lag_xf, _lag)
		return _hand

	func _sample() -> void:
		_gpos = Crv._s3(_t_gpos, uw)
		_grot = Crv._s3(_t_grot, uw)
		_cam = Crv._s3(_t_cam, uw)
		_reach = clampf(Crv._sf(_t_reach, uw), 0.0, 1.0)
		_lag = clampf(Crv._sf(_t_lag, uw), 0.0, 1.0)
		_fingers = {}
		for ch in _t_fing:
			_fingers[ch] = clampf(Crv._sf(_t_fing[ch], uw), 0.0, 1.0)
		_mag = MAG_IN_GUN
		_fresh = false
		for k: Array in _t_mag:
			if float(k[0]) > uw:
				break
			_mag = int(k[1])
			_fresh = k.size() > 2 and bool(k[2])
		_extra = {}
		for nm in _t_extra:
			_extra[nm] = Crv._sf(_t_extra[nm], uw)

	func _step(dt: float) -> void:
		var n := 1 if dt <= 0.017 else 2
		var h := minf(dt, 0.05) / n
		for i in n:
			sp_pos_v += (-sp_pos * SPRING_K - sp_pos_v * SPRING_C) * h
			sp_pos += sp_pos_v * h
			sp_rot_v += (-sp_rot * SPRING_K - sp_rot_v * SPRING_C) * h
			sp_rot += sp_rot_v * h

	func _hk(j: int, c2g: Transform3D) -> Transform3D:
		var k: Array = _t_hand[j]
		var xf: Transform3D = k[1]
		return c2g * xf if k.size() > 2 and float(k[2]) > 0.5 else xf

	func _sample_hand(t: float, c2g: Transform3D) -> Transform3D:
		var keys := _t_hand
		var n := keys.size()
		if n == 0:
			return Transform3D()
		if n == 1 or t <= float(keys[0][0]):
			return _hk(0, c2g)
		if t >= float(keys[n - 1][0]):
			return _hk(n - 1, c2g)
		var i := Crv._find(keys, t)
		var x0 := _hk(i, c2g)
		var x1 := _hk(i + 1, c2g)
		var xm := _hk(i - 1, c2g) if i > 0 else x0
		var xp := _hk(i + 2, c2g) if i + 2 < n else x1
		var t0 := float(keys[i][0])
		var t1 := float(keys[i + 1][0])
		var tm := float(keys[i - 1][0]) if i > 0 else t0
		var tp := float(keys[i + 2][0]) if i + 2 < n else t1
		var h := t1 - t0
		var s := Crv._ease(clampf((t - t0) / h, 0.0, 1.0), Crv._ke(keys[i + 1], 4))
		var k0 := 0.0 if i == 0 else Crv._kk(keys[i], 3)
		var k1 := 0.0 if i + 1 == n - 1 else Crv._kk(keys[i + 1], 3)
		var m0 := (x1.origin - xm.origin) / maxf(t1 - tm, 1e-4) * k0
		var m1 := (xp.origin - x0.origin) / maxf(tp - t0, 1e-4) * k1
		var pos := Crv._herm3(x0.origin, x1.origin, m0, m1, h, s)
		var q0 := Quaternion(x0.basis.orthonormalized())
		var qi := q0.inverse()
		var r1 := Crv._qlog(qi * Quaternion(x1.basis.orthonormalized()))
		var rm := Crv._qlog(qi * Quaternion(xm.basis.orthonormalized()))
		var rp := Crv._qlog(qi * Quaternion(xp.basis.orthonormalized()))
		var a0 := (r1 - rm) / maxf(t1 - tm, 1e-4) * k0
		var a1 := rp / maxf(tp - t0, 1e-4) * k1
		var r := Crv._herm3(Vector3.ZERO, r1, a0, a1, h, s)
		return Transform3D(Basis(q0 * Crv._qexp(r)), pos)


# =================================================================================================
# Driving a gun (rifle.gd now; weapon_base.gd later)
# =================================================================================================

## Sets the left hand's viewmodel fields on gun `g` from a playing (or fading) choreography
## (left_reach / _w / _elbow, left_reach_basis / _basis_w, left_reach_space 1 = gun frame,
## left_fingers) and places `mag`: seated at `seat` (its parent's space), in the hand
## (hand · hold⁻¹; `hold` = the hand frame in the magazine's space) or hidden. Returns the state.
static func drive(g: Object, ra: Player, mag: Node3D, seat: Transform3D, hold: Transform3D, dt: float) -> int:
	var pose: Transform3D = g.get("pose_override")
	var hand := ra.hand(pose.affine_inverse(), dt)
	g.set("left_reach_space", 1.0)
	g.set("left_reach_basis", hand.basis)
	g.set("left_reach_basis_w", 1.0)
	g.set("left_reach", hand * LEFT_WRIST)
	g.set("left_reach_w", ra.reach_w())
	g.set("left_reach_elbow", Vector3(-0.3, -0.82, 0.48))
	g.set("left_fingers", ra.fingers())
	var st := ra.mag_state()
	if mag != null:
		match st:
			MAG_IN_HAND:
				var par := _model_xf(mag.get_parent() as Node3D, g.get("model") as Node3D)
				mag.transform = par.affine_inverse() * hand * hold.affine_inverse()
				mag.visible = true
			MAG_IN_GUN:
				mag.transform = seat
				mag.visible = true
			_:
				mag.visible = false
	return st


## No choreography: the reach fields back to the legacy camera-space mode (inspect / fitting reaches).
static func release(g: Object) -> void:
	if "left_reach_space" in g:
		g.set("left_reach_space", 0.0)
	if "left_reach_basis_w" in g:
		g.set("left_reach_basis_w", 0.0)
	if "left_fingers" in g:
		g.set("left_fingers", {})


## Transform of node n in the space of its ancestor root (identity when n is root / null).
static func _model_xf(n: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D()
	while n != null and n != root:
		xf = n.transform * xf
		n = n.get_parent() as Node3D
	return xf


# =================================================================================================
# Builders: profiles from a gun's geometry
# =================================================================================================
## geo (Dictionary, gun frame unless noted):
##   "pivot"     gun-offset rotation pivot          "mag_rest" / "mag_basis"  the seated magazine node
##   "mag_axis"  slide-out direction                "lip"   front lip (magazine space): the insert pivot
##   "base"      base plate bottom (magazine space) "hold"  hand frame in magazine space (VMHand.hold_frame)
##   "grip"      hand frame on its grip (palm offset included)
##   "catch"     bolt catch on the left side (empty reloads)
##   "pouch"     camera-space pouch point            "nominal" camera-space gun pose (the hip pose)
##   "scale"     gun motion amplitude (1 rifle)

## Magazine node transform (gun frame): slid `d` m out along the axis, turned by `rot` (euler) about
## its front lip (rot.x > 0 swings the body forward: front lip first).
static func mag_at(geo: Dictionary, d: float, rot := Vector3.ZERO) -> Transform3D:
	var seat := Transform3D(geo.get("mag_basis", Basis()), geo["mag_rest"])
	var lip: Vector3 = geo.get("lip", Vector3.ZERO)
	var tilt := Transform3D(Basis(), lip) * Transform3D(Basis.from_euler(rot), Vector3.ZERO) * Transform3D(Basis(), -lip)
	return Transform3D(Basis(), (geo["mag_axis"] as Vector3).normalized() * d) * seat * tilt


## Left hand frame whose palm pad (PALM_C) touches `at`, palm facing `n` (toward the object), the
## index side toward `y`.
static func palm_frame(at: Vector3, n: Vector3, y: Vector3) -> Transform3D:
	var b := _map_basis(PALM_N, Vector3.UP, n, y)
	return Transform3D(b, at - b * PALM_C)


static func _map_basis(dir_a: Vector3, up_a: Vector3, dir_b: Vector3, up_b: Vector3) -> Basis:
	var da := dir_a.normalized()
	var ua := (up_a - da * up_a.dot(da)).normalized()
	var db := dir_b.normalized()
	var ub := (up_b - db * up_b.dot(db)).normalized()
	return Basis(db, ub, db.cross(ub)) * Basis(da, ua, da.cross(ua)).inverse()


static func _shift(xf: Transform3D, d: Vector3) -> Transform3D:
	return Transform3D(xf.basis, xf.origin + d)


## Gun pose (camera space) of the nominal hip pose with an offset (for authoring camera-space keys).
static func _nominal(geo: Dictionary, pos: Vector3, rot: Vector3) -> Transform3D:
	var pv: Vector3 = geo.get("pivot", Vector3.ZERO)
	var o := Transform3D(Basis(), pv) * Transform3D(Basis.from_euler(rot), Vector3.ZERO) * Transform3D(Basis(), -pv)
	var out: Transform3D = (geo.get("nominal", Transform3D()) as Transform3D) * o
	out.origin += pos
	return out


## Pouch keys (camera space): the hand low left below the frame, its basis the `via` hand (gun frame)
## as seen in the nominal reload pose, tipped toward the body.
static func _pouch(geo: Dictionary, via: Transform3D, cp: Vector3, cr: Vector3, off := Vector3.ZERO) -> Transform3D:
	var cam := _nominal(geo, cp, cr) * via
	return Transform3D(Basis.from_euler(Vector3(0.55, 0.3, 0.35)) * cam.basis.orthonormalized(), (geo["pouch"] as Vector3) + off)


static func _up_fwd(geo: Dictionary) -> Array:
	var up := -(geo["mag_axis"] as Vector3).normalized()
	var f: Vector3 = (geo.get("mag_basis", Basis()) as Basis) * Vector3.FORWARD
	f = (f - up * f.dot(up)).normalized()
	return [up, f]


## Tactical (rounds left): the gun cants and rolls right (the well toward the left hand), the hand
## takes the magazine, the thumb presses the release, strips it down and drops below the frame to the
## belt pouch, comes back up with the new one (visible rising from below), puts it in front lip first,
## rocks it back and seats it with a push (the gun bumps up), a palm slap on the base, back to the
## handguard, the gun settles past its hold.
##   u 0.00-0.06 anticipation, hand off the grip · 0.17 hand on the magazine · 0.205 release ·
##   0.225-0.34 strip · 0.42-0.52 below the frame (old one stowed, new one drawn) · 0.58 rising ·
##   0.665 lip in · 0.69 rock · 0.705 seat · 0.79 slap · 0.94 on the grip · 0.95 overshoot · 1 rest
static func mag_tactical(geo: Dictionary) -> Dictionary:
	var sc := float(geo.get("scale", 1.0))
	var G: Transform3D = geo["hold"]
	var grip: Transform3D = geo["grip"]
	var uf: Array = _up_fwd(geo)
	var up: Vector3 = uf[0]
	var fwd: Vector3 = uf[1]
	var C := Vector3(0.1, 0.2, -0.42) * sc            # the reload cant: muzzle up / left, rolled right
	var CP := Vector3(-0.035, 0.03, 0.02) * sc
	var p := {"pivot": geo.get("pivot", Vector3.ZERO)}
	p["gun"] = [
		[0.0, Vector3.ZERO, Vector3.ZERO],
		[0.05, Vector3(0.0, -0.004, 0.002) * sc, Vector3(-0.015, -0.01, 0.035) * sc, 0.6],   # anticipation
		[0.17, CP, C],
		[0.215, CP + Vector3(0.0, 0.002, 0.0), C + Vector3(0.01, 0.0, -0.04) * sc, 0.6],     # past the cant
		[0.27, CP + Vector3(0.0, 0.006, 0.0), C + Vector3(0.02, 0.01, -0.02) * sc],           # lifts off the magazine
		[0.36, CP + Vector3(0.005, 0.0, 0.0), C * 0.85],
		[0.5, CP + Vector3(0.006, -0.004, 0.0), C * 0.82],
		[0.62, CP + Vector3(-0.004, -0.008, -0.004), C + Vector3(0.0, 0.02, -0.06) * sc],    # meets the new one
		[0.70, CP + Vector3(-0.004, -0.006, -0.004), C + Vector3(-0.01, 0.02, -0.06) * sc, 0.5],
		[0.74, CP + Vector3(0.0, 0.004, 0.0), C + Vector3(0.02, 0.0, -0.03) * sc, 0.8],
		[0.80, CP * 0.9 + Vector3(0.0, 0.004, 0.0), C * 0.9],
		[0.9, CP * 0.12, C * 0.1],
		[0.95, Vector3(0.0, 0.003, -0.002) * sc, Vector3(-0.012, -0.012, 0.03) * sc, 0.7],     # overshoot
		[1.0, Vector3.ZERO, Vector3.ZERO, 0.0],
	]
	p["cam"] = [
		[0.0, Vector3.ZERO],
		[0.17, Vector3(-0.008, 0.004, -0.008)],
		[0.3, Vector3(-0.012, 0.006, -0.006)],
		[0.44, Vector3(-0.016, 0.004, 0.006)],       # the shoulder dips toward the pouch
		[0.6, Vector3(-0.011, 0.006, -0.01)],
		[0.72, Vector3(-0.008, 0.004, -0.008)],
		[0.86, Vector3(-0.003, 0.001, -0.002)],
		[1.0, Vector3.ZERO, 0.0],
	]
	var off := _shift(grip, Vector3(-0.015, -0.03, 0.025))
	var seat := mag_at(geo, 0.0) * G
	var pop := mag_at(geo, 0.005) * G
	var clear := mag_at(geo, 0.07, Vector3(0.06, 0.0, -0.05)) * G
	var low := mag_at(geo, 0.17, Vector3(0.15, 0.1, -0.3)) * G
	var rise := mag_at(geo, 0.2, Vector3(0.45, -0.1, -0.35)) * G
	var app := mag_at(geo, 0.075, Vector3(0.32, 0.0, -0.08)) * G
	var lip := mag_at(geo, 0.026, Vector3(0.25, 0.0, 0.0)) * G
	var rock := mag_at(geo, 0.009, Vector3(0.06, 0.0, 0.0)) * G
	var push := mag_at(geo, -0.002) * G
	var rel := _shift(mag_at(geo, 0.035) * G, Vector3(-0.012, 0.0, 0.004))
	var base: Vector3 = mag_at(geo, 0.0) * (geo["base"] as Vector3)
	var slap := palm_frame(base - up * 0.0015, up, fwd)
	var slap0 := _shift(slap, -up * 0.055 + Vector3(-0.02, 0.0, 0.015))
	var slap1 := _shift(slap, -up * 0.025 + Vector3(-0.006, 0.0, 0.0))
	var pouch := _pouch(geo, low, CP, C * 0.85)
	var pouch2 := _pouch(geo, low, CP, C * 0.82, Vector3(0.03, 0.0, 0.015))
	p["hand"] = [
		[0.0, grip, 0, 0.0],
		[0.06, off, 0],
		[0.17, seat, 0, 0.0, -0.3],
		[0.205, seat, 0, 0.0],
		[0.225, pop, 0, 0.0],
		[0.28, clear, 0, 1.0, 0.3],
		[0.34, low, 0],
		[0.44, pouch, 1, 0.0],
		[0.5, pouch2, 1, 0.0],
		[0.58, rise, 0],
		[0.635, app, 0, 0.6],
		[0.665, lip, 0, 0.0],
		[0.69, rock, 0, 0.3],
		[0.705, push, 0, 0.0, 0.5],
		[0.725, seat, 0, 0.0],
		[0.74, rel, 0, 0.6],
		[0.765, slap0, 0, 0.0, -0.3],
		[0.79, slap, 0, 0.0, 0.6],
		[0.815, slap1, 0, 0.5],
		[0.88, off, 0],
		[0.94, grip, 0, 0.0, -0.2],
		[1.0, grip, 0, 0.0],
	]
	p["reach"] = [[0.0, 0.0, 0.0], [0.06, 1.0, 0.0], [0.94, 1.0, 0.0], [1.0, 0.0, 0.0]]
	p["lag"] = [[0.0, 0.0, 0.0], [0.08, 0.5, 0.0], [0.16, 0.0, 0.0], [0.29, 0.0, 0.0], [0.36, 1.0, 0.0], [0.58, 1.0, 0.0],
			[0.63, 0.0, 0.0], [0.82, 0.0, 0.0], [0.87, 0.6, 0.0], [0.93, 0.0, 0.0]]
	p["fingers"] = [
		[0.0, {"grip": 1.0}],
		[0.07, {"open_palm": 0.5, "relaxed": 0.5}],
		[0.15, {"open_palm": 1.0}],
		[0.175, {"wrap_mag": 1.0}],
		[0.19, {"wrap_mag": 1.0, "thumb_press": 0.0}],
		[0.205, {"wrap_mag": 1.0, "thumb_press": 1.0}],
		[0.235, {"wrap_mag": 1.0, "thumb_press": 0.0}],
		[0.725, {"wrap_mag": 1.0}],
		[0.75, {"open_palm": 1.0}],
		[0.82, {"open_palm": 1.0}],
		[0.87, {"relaxed": 1.0}],
		[0.93, {"grip": 1.0}],
		[1.0, {"grip": 1.0}],
	]
	p["mag"] = [[0.0, MAG_IN_GUN, false], [0.17, MAG_IN_HAND, false], [0.42, MAG_POUCH, false], [0.47, MAG_POUCH, true],
			[0.52, MAG_IN_HAND, true], [0.725, MAG_IN_GUN, true]]
	p["events"] = [
		[0.02, {"snd": "cloth", "db": -17.0, "pitch": 1.0}],
		[0.165, {"snd": "grip", "sfx": true, "db": -22.0, "pitch": 1.0}],
		[0.205, {"snd": "mag_release", "db": -9.0, "pitch": 1.0, "r": Vector3(-0.2, 0.0, 0.15)}],
		[0.25, {"snd": "mag_out", "db": -8.0, "pitch": 1.0, "p": Vector3(0.0, 0.12, 0.0), "r": Vector3(0.35, 0.0, 0.2)}],
		[0.41, {"snd": "cloth", "db": -18.0, "pitch": 0.9}],
		[0.49, {"snd": "gear", "sfx": true, "db": -24.0, "pitch": 1.0}],
		[0.665, {"snd": "tap", "sfx": true, "db": -24.0, "pitch": 1.1}],
		[0.705, {"snd": "mag_in", "db": -6.0, "pitch": 1.0, "p": Vector3(0.0, 0.16, 0.03), "r": Vector3(0.6, 0.05, -0.25)}],
		[0.79, {"snd": "mag_slap", "db": -5.0, "pitch": 1.0, "p": Vector3(0.0, 0.22, 0.0), "r": Vector3(1.0, -0.1, 0.3)}],
		[0.93, {"snd": "grip", "sfx": true, "db": -23.0, "pitch": 0.95}],
	]
	return p


## Empty (speed reload): the hand heads for the pouch and the thumb flicks the release on the way, the
## old magazine drops free (MAG_DROPPED: the gun spawns the world copy), the new one is seated as in
## the tactical, then the gun rolls further right and the palm slaps the bolt catch: the bolt (locked
## back on the empty magazine, extra "charge") slams forward with a sharp kick.
##   u 0.04 anticipation · 0.12 thumb on the release · 0.145 dropped · 0.3-0.36 pouch · 0.44 rising ·
##   0.515 lip in · 0.555 seat · 0.635 wind-up · 0.665 bolt catch · 0.88 on the grip · 0.93 overshoot
static func mag_empty(geo: Dictionary) -> Dictionary:
	var sc := float(geo.get("scale", 1.0))
	var G: Transform3D = geo["hold"]
	var grip: Transform3D = geo["grip"]
	var C := Vector3(0.1, 0.2, -0.45) * sc
	var C2 := Vector3(0.14, 0.18, -0.62) * sc          # rolled further right for the bolt catch
	var CP := Vector3(-0.035, 0.03, 0.02) * sc
	var p := {"pivot": geo.get("pivot", Vector3.ZERO)}
	p["gun"] = [
		[0.0, Vector3.ZERO, Vector3.ZERO],
		[0.04, Vector3(0.0, -0.003, 0.0) * sc, Vector3(-0.012, -0.008, 0.03) * sc, 0.6],
		[0.12, CP, C],
		[0.16, CP + Vector3(0.0, 0.004, 0.0), C + Vector3(0.02, 0.0, -0.02) * sc],
		[0.3, CP + Vector3(0.005, 0.0, 0.0), C * 0.85],
		[0.42, CP + Vector3(0.006, -0.004, 0.0), C * 0.82],
		[0.5, CP + Vector3(-0.004, -0.008, -0.004), C + Vector3(0.0, 0.02, -0.06) * sc],
		[0.555, CP + Vector3(-0.004, -0.006, -0.004), C + Vector3(-0.01, 0.02, -0.06) * sc, 0.5],
		[0.59, CP + Vector3(0.0, 0.004, 0.0), C + Vector3(0.02, 0.0, -0.03) * sc, 0.8],
		[0.64, CP + Vector3(0.0, 0.01, 0.0) * sc, C2],
		[0.665, CP + Vector3(0.0, 0.01, 0.0) * sc, C2, 0.0],
		[0.72, CP * 0.6, C2 * 0.6],
		[0.84, CP * 0.1, C * 0.1],
		[0.93, Vector3(0.0, 0.003, -0.002) * sc, Vector3(-0.015, -0.012, 0.035) * sc, 0.7],
		[1.0, Vector3.ZERO, Vector3.ZERO, 0.0],
	]
	p["cam"] = [
		[0.0, Vector3.ZERO],
		[0.12, Vector3(-0.008, 0.004, -0.008)],
		[0.2, Vector3(-0.013, 0.004, -0.004)],
		[0.3, Vector3(-0.016, 0.004, 0.006)],
		[0.48, Vector3(-0.011, 0.006, -0.01)],
		[0.6, Vector3(-0.008, 0.004, -0.01)],
		[0.665, Vector3(-0.006, 0.004, -0.014)],
		[0.75, Vector3(-0.004, 0.002, -0.005)],
		[0.9, Vector3(0.001, 0.0, 0.002)],
		[1.0, Vector3.ZERO, 0.0],
	]
	var off := _shift(grip, Vector3(-0.015, -0.03, 0.025))
	var seat := mag_at(geo, 0.0) * G
	var pass_ := _shift(seat, Vector3(-0.022, -0.035, 0.012))
	var below := _shift(mag_at(geo, 0.12, Vector3(0.15, 0.1, -0.3)) * G, Vector3(-0.04, -0.03, 0.03))
	var rise := mag_at(geo, 0.2, Vector3(0.45, -0.1, -0.35)) * G
	var app := mag_at(geo, 0.075, Vector3(0.32, 0.0, -0.08)) * G
	var lip := mag_at(geo, 0.026, Vector3(0.25, 0.0, 0.0)) * G
	var rock := mag_at(geo, 0.009, Vector3(0.06, 0.0, 0.0)) * G
	var push := mag_at(geo, -0.002) * G
	var rel := _shift(mag_at(geo, 0.035) * G, Vector3(-0.015, 0.0, 0.004))
	var cat := palm_frame((geo["catch"] as Vector3) + Vector3(-0.001, 0.0, 0.0), Vector3.RIGHT, Vector3(0.0, 0.966, 0.259))
	var cat0 := _shift(cat, Vector3(-0.035, -0.015, 0.015))
	var cat1 := _shift(cat, Vector3(-0.02, -0.008, 0.008))
	var pouch := _pouch(geo, below, CP, C * 0.85)
	var pouch2 := _pouch(geo, below, CP, C * 0.82, Vector3(0.03, 0.0, 0.015))
	p["hand"] = [
		[0.0, grip, 0, 0.0],
		[0.05, off, 0],
		[0.12, pass_, 0, 0.6],
		[0.18, below, 0],
		[0.3, pouch, 1, 0.0],
		[0.36, pouch2, 1, 0.0],
		[0.44, rise, 0],
		[0.49, app, 0, 0.6],
		[0.515, lip, 0, 0.0],
		[0.54, rock, 0, 0.3],
		[0.555, push, 0, 0.0, 0.5],
		[0.575, seat, 0, 0.0],
		[0.6, rel, 0, 0.6],
		[0.635, cat0, 0, 0.0, -0.3],
		[0.665, cat, 0, 0.0, 0.6],
		[0.69, cat1, 0, 0.5],
		[0.8, off, 0],
		[0.88, grip, 0, 0.0, -0.2],
		[1.0, grip, 0, 0.0],
	]
	p["reach"] = [[0.0, 0.0, 0.0], [0.05, 1.0, 0.0], [0.88, 1.0, 0.0], [0.96, 0.0, 0.0]]
	p["lag"] = [[0.0, 0.0, 0.0], [0.06, 0.4, 0.0], [0.11, 0.2, 0.0], [0.17, 0.8, 0.0], [0.42, 1.0, 0.0], [0.49, 0.0, 0.0],
			[0.6, 0.0, 0.0], [0.62, 0.5, 0.0], [0.65, 0.0, 0.0], [0.7, 0.3, 0.0], [0.8, 0.6, 0.0], [0.87, 0.0, 0.0]]
	p["fingers"] = [
		[0.0, {"grip": 1.0}],
		[0.06, {"relaxed": 0.5, "open_palm": 0.5}],
		[0.105, {"relaxed": 0.4, "open_palm": 0.6, "thumb_press": 0.0}],
		[0.125, {"relaxed": 0.4, "open_palm": 0.6, "thumb_press": 1.0}],
		[0.16, {"relaxed": 1.0, "thumb_press": 0.3}],
		[0.22, {"relaxed": 1.0}],
		[0.28, {"wrap_mag": 1.0}],
		[0.575, {"wrap_mag": 1.0}],
		[0.6, {"open_palm": 1.0}],
		[0.69, {"open_palm": 1.0}],
		[0.75, {"relaxed": 1.0}],
		[0.87, {"grip": 1.0}],
		[1.0, {"grip": 1.0}],
	]
	p["mag"] = [[0.0, MAG_IN_GUN, false], [0.145, MAG_DROPPED, false], [0.33, MAG_POUCH, true], [0.38, MAG_IN_HAND, true],
			[0.575, MAG_IN_GUN, true]]
	p["extra"] = {"charge": [[0.0, 1.0, 0.0], [0.664, 1.0, 0.0], [0.676, 0.0, 0.0], [1.0, 0.0, 0.0]]}
	p["events"] = [
		[0.02, {"snd": "cloth", "db": -17.0, "pitch": 1.0}],
		[0.135, {"snd": "mag_release", "db": -9.0, "pitch": 1.0, "r": Vector3(-0.25, 0.0, 0.1)}],
		[0.15, {"snd": "mag_out", "db": -9.0, "pitch": 1.05, "p": Vector3(0.0, 0.14, 0.0), "r": Vector3(0.4, 0.0, 0.2)}],
		[0.29, {"snd": "cloth", "db": -18.0, "pitch": 0.9}],
		[0.37, {"snd": "gear", "sfx": true, "db": -24.0, "pitch": 1.0}],
		[0.515, {"snd": "tap", "sfx": true, "db": -24.0, "pitch": 1.1}],
		[0.555, {"snd": "mag_in", "db": -6.0, "pitch": 1.0, "p": Vector3(0.0, 0.16, 0.03), "r": Vector3(0.6, 0.05, -0.25)}],
		[0.663, {"snd": "bolt_back", "db": -14.0, "pitch": 1.15}],                                # the catch clicks
		[0.666, {"snd": "bolt_fwd", "db": -4.0, "pitch": 1.0, "p": Vector3(0.0, 0.14, 0.32), "r": Vector3(1.7, -0.15, 0.9)}],
		[0.86, {"snd": "grip", "sfx": true, "db": -23.0, "pitch": 0.95}],
	]
	return p


## SMG (data only, not wired: weapon_base.gd): the magazine through the pistol grip, a quick speed
## reload (MW SMGs drop the old one): the hand comes under the grip, strips it (dropped), a new one from
## the pouch, pushed home with the palm (no separate slap); `empty` adds a rack of the top cocking knob
## (geo "knob": knob point, gun frame; the hand pinches it from above and pulls it back 4 cm).
## geo as above with the SMG's raked magazine ("mag_basis") and a lighter "scale" (0.7).
static func smg_mag(geo: Dictionary, empty := false) -> Dictionary:
	var sc := float(geo.get("scale", 0.7))
	var G: Transform3D = geo["hold"]
	var grip: Transform3D = geo["grip"]
	var uf: Array = _up_fwd(geo)
	var up: Vector3 = uf[0]
	var fwd: Vector3 = uf[1]
	var C := Vector3(0.12, 0.22, -0.5) * sc
	var CP := Vector3(-0.03, 0.035, 0.02) * sc
	var end_u := 0.78 if empty else 0.86
	var p := {"pivot": geo.get("pivot", Vector3.ZERO)}
	p["gun"] = [
		[0.0, Vector3.ZERO, Vector3.ZERO],
		[0.05, Vector3(0.0, -0.003, 0.0), Vector3(-0.012, -0.008, 0.03) * sc, 0.6],
		[0.16, CP, C],
		[0.24, CP + Vector3(0.0, 0.005, 0.0), C + Vector3(0.02, 0.0, -0.03) * sc],
		[0.42, CP, C * 0.85],
		[0.56, CP + Vector3(0.0, -0.006, 0.0), C + Vector3(0.0, 0.02, -0.05) * sc],
		[0.62, CP + Vector3(0.0, 0.004, 0.0), C + Vector3(0.02, 0.0, -0.02) * sc, 0.8],
		[end_u, CP * 0.15, C * 0.15],
		[minf(end_u + 0.08, 0.97), Vector3(0.0, 0.002, 0.0), Vector3(-0.01, -0.01, 0.025) * sc, 0.7],
		[1.0, Vector3.ZERO, Vector3.ZERO, 0.0],
	]
	p["cam"] = [[0.0, Vector3.ZERO], [0.2, Vector3(-0.01, 0.004, -0.008)], [0.4, Vector3(-0.014, 0.004, 0.005)],
			[0.62, Vector3(-0.008, 0.004, -0.008)], [1.0, Vector3.ZERO, 0.0]]
	var off := _shift(grip, Vector3(-0.015, -0.03, 0.025))
	var seat := mag_at(geo, 0.0) * G
	var below := _shift(mag_at(geo, 0.1, Vector3(0.1, 0.0, -0.25)) * G, Vector3(-0.04, -0.03, 0.03))
	var rise := mag_at(geo, 0.18, Vector3(0.3, -0.1, -0.3)) * G
	var app := mag_at(geo, 0.06, Vector3(0.15, 0.0, -0.05)) * G
	var push := mag_at(geo, -0.002) * G
	var base: Vector3 = mag_at(geo, 0.0) * (geo["base"] as Vector3)
	var palm := palm_frame(base - up * 0.0015, up, fwd)
	var pouch := _pouch(geo, below, CP, C * 0.85)
	var hand := [
		[0.0, grip, 0, 0.0], [0.06, off, 0], [0.15, seat, 0, 0.0, -0.3], [0.2, _shift(seat, -up * 0.03), 0, 0.6],
		[0.26, below, 0], [0.36, pouch, 1, 0.0], [0.42, pouch, 1, 0.0], [0.5, rise, 0], [0.55, app, 0, 0.0],
		[0.6, push, 0, 0.0, 0.5], [0.615, seat, 0, 0.0], [0.64, _shift(palm, -up * 0.04), 0, 0.0],
		[0.66, palm, 0, 0.0, 0.6], [0.69, _shift(palm, -up * 0.02), 0],
	]
	var fing := [[0.0, {"grip": 1.0}], [0.1, {"open_palm": 1.0}], [0.15, {"wrap_mag": 1.0}], [0.2, {"wrap_mag": 1.0}],
			[0.24, {"relaxed": 1.0}], [0.34, {"wrap_mag": 1.0}], [0.615, {"wrap_mag": 1.0}], [0.64, {"open_palm": 1.0}],
			[0.7, {"open_palm": 1.0}]]
	var ev := [
		[0.02, {"snd": "cloth", "db": -17.0, "pitch": 1.05}],
		[0.16, {"snd": "mag_release", "db": -9.0, "pitch": 1.1, "r": Vector3(-0.2, 0.0, 0.1)}],
		[0.2, {"snd": "mag_out", "db": -9.0, "pitch": 1.1, "p": Vector3(0.0, 0.1, 0.0), "r": Vector3(0.3, 0.0, 0.15)}],
		[0.6, {"snd": "mag_in", "db": -6.0, "pitch": 1.1, "p": Vector3(0.0, 0.14, 0.0), "r": Vector3(0.5, 0.0, -0.2)}],
		[0.66, {"snd": "mag_slap", "db": -7.0, "pitch": 1.1, "p": Vector3(0.0, 0.15, 0.0), "r": Vector3(0.7, 0.0, 0.2)}],
	]
	if empty and geo.has("knob"):
		var knob: Vector3 = geo["knob"]
		var k0 := palm_frame(knob + Vector3(0.0, 0.012, 0.0), Vector3.DOWN, Vector3(0.0, 0.0, 1.0))
		hand.append([0.72, _shift(k0, Vector3(-0.02, 0.03, -0.01)), 0, 0.0])
		hand.append([0.75, k0, 0, 0.0])
		hand.append([0.8, _shift(k0, Vector3(0.0, 0.0, 0.04)), 0, 0.0, 0.3])
		hand.append([0.83, _shift(k0, Vector3(-0.02, 0.025, 0.04)), 0])
		fing.append([0.72, {"relaxed": 1.0}])
		fing.append([0.75, {"fist": 1.0}])
		fing.append([0.8, {"fist": 1.0}])
		fing.append([0.84, {"open_palm": 1.0}])
		ev.append([0.78, {"snd": "bolt_back", "db": -6.0, "pitch": 1.1}])
		ev.append([0.8, {"snd": "bolt_fwd", "db": -4.0, "pitch": 1.1, "p": Vector3(0.0, 0.1, 0.25), "r": Vector3(1.2, 0.0, 0.5)}])
		p["extra"] = {"charge": [[0.0, 0.0, 0.0], [0.75, 0.0, 0.0], [0.8, 1.0, 0.0, 0.3], [0.805, 0.0, 0.0], [1.0, 0.0, 0.0]]}
	hand.append([end_u, off, 0])
	hand.append([minf(end_u + 0.07, 0.95), grip, 0, 0.0, -0.2])
	hand.append([1.0, grip, 0, 0.0])
	fing.append([end_u, {"relaxed": 1.0}])
	fing.append([minf(end_u + 0.06, 0.94), {"grip": 1.0}])
	fing.append([1.0, {"grip": 1.0}])
	p["hand"] = hand
	p["fingers"] = fing
	p["reach"] = [[0.0, 0.0, 0.0], [0.06, 1.0, 0.0], [minf(end_u + 0.07, 0.95), 1.0, 0.0], [1.0, 0.0, 0.0]]
	p["lag"] = [[0.0, 0.0, 0.0], [0.08, 0.4, 0.0], [0.14, 0.0, 0.0], [0.2, 0.0, 0.0], [0.28, 1.0, 0.0], [0.5, 1.0, 0.0],
			[0.54, 0.0, 0.0], [0.7, 0.0, 0.0], [end_u, 0.5, 0.0], [1.0, 0.0, 0.0]]
	p["mag"] = [[0.0, MAG_IN_GUN, false], [0.15, MAG_IN_HAND, false], [0.21, MAG_DROPPED, false], [0.33, MAG_POUCH, true],
			[0.4, MAG_IN_HAND, true], [0.615, MAG_IN_GUN, true]]
	p["events"] = ev
	return p


## Shotgun shell insert (data only, not wired: weapon_base.gd "shell" reloads), one profile per phase:
## "start" (the gun cants left, the hand from the pump to the side pouch), "each" (a shell from the
## pouch to the loading port, the thumb pushes it in, back to the pouch; played once per shell),
## "end" (back to the pump) and "end_empty" (back to the pump and rack it).
## geo: "pump" (hand frame on the pump, gun frame), "port" (loading port, gun frame), "pouch" (camera
## space), "nominal", "pivot", "pump_dir" (rack direction, gun frame, default +Z).
static func shotgun_shell(geo: Dictionary) -> Dictionary:
	var pump: Transform3D = geo["pump"]
	var port: Vector3 = geo["port"]
	var C := Vector3(0.12, 0.16, 0.5)                   # rolled left: the loading port up toward the hand
	var CP := Vector3(-0.03, 0.03, 0.02)
	var at_port := palm_frame(port + Vector3(0.0, -0.03, 0.012), Vector3.UP, Vector3(0.0, 0.0, -1.0))
	var below := _shift(at_port, Vector3(-0.03, -0.06, 0.03))
	var pouch := _pouch(geo, below, CP, C)
	var pv: Vector3 = geo.get("pivot", Vector3.ZERO)
	var rack: Vector3 = geo.get("pump_dir", Vector3(0.0, 0.0, 1.0))
	var start := {"pivot": pv,
		"gun": [[0.0, Vector3.ZERO, Vector3.ZERO], [0.15, Vector3(0.0, -0.003, 0.0), Vector3(-0.01, 0.0, -0.03), 0.6],
			[0.8, CP, C], [1.0, CP, C, 0.0]],
		"cam": [[0.0, Vector3.ZERO], [1.0, Vector3(-0.008, 0.004, 0.006), 0.0]],
		"hand": [[0.0, pump, 0, 0.0], [0.35, _shift(pump, Vector3(-0.02, -0.04, 0.03)), 0], [1.0, pouch, 1, 0.0]],
		"reach": [[0.0, 0.0, 0.0], [0.25, 1.0, 0.0], [1.0, 1.0, 0.0]],
		"lag": [[0.0, 0.0, 0.0], [0.4, 1.0, 0.0], [1.0, 1.0, 0.0]],
		"fingers": [[0.0, {"grip": 1.0}], [0.5, {"relaxed": 1.0}], [1.0, {"shell": 1.0}]],
		"events": [[0.1, {"snd": "cloth", "db": -15.0, "pitch": 1.0}]]}
	var each := {"pivot": pv,
		"gun": [[0.0, CP, C], [0.62, CP + Vector3(0.0, -0.004, 0.0), C + Vector3(0.0, 0.0, 0.03), 0.6],
			[0.7, CP + Vector3(0.0, 0.002, 0.0), C, 0.6], [1.0, CP, C, 0.0]],
		"cam": [[0.0, Vector3(-0.008, 0.004, 0.006)], [1.0, Vector3(-0.008, 0.004, 0.006)]],
		"hand": [[0.0, pouch, 1, 0.0], [0.25, pouch, 1, 0.0], [0.45, below, 0], [0.62, at_port, 0, 0.0, 0.3],
			[0.72, _shift(at_port, Vector3(0.0, 0.025, -0.01)), 0, 0.0, 0.5], [1.0, pouch, 1, 0.0]],
		"reach": [[0.0, 1.0], [1.0, 1.0]],
		"lag": [[0.0, 1.0, 0.0], [0.45, 1.0, 0.0], [0.58, 0.0, 0.0], [0.76, 0.0, 0.0], [0.85, 1.0, 0.0], [1.0, 1.0, 0.0]],
		"fingers": [[0.0, {"shell": 1.0}], [0.62, {"shell": 1.0}], [0.68, {"shell": 0.4, "relaxed": 0.6, "thumb_press": 1.0}],
			[0.8, {"relaxed": 1.0}], [1.0, {"shell": 1.0}]],
		"events": [[0.66, {"snd": "shell_in", "db": -5.0, "pitch": 1.0, "p": Vector3(0.0, 0.06, 0.0), "r": Vector3(0.25, 0.0, 0.1)}]]}
	var end := {"pivot": pv,
		"gun": [[0.0, CP, C], [0.7, CP * 0.1, C * 0.1], [0.85, Vector3.ZERO, Vector3(-0.01, 0.0, -0.025), 0.7],
			[1.0, Vector3.ZERO, Vector3.ZERO, 0.0]],
		"cam": [[0.0, Vector3(-0.008, 0.004, 0.006)], [1.0, Vector3.ZERO, 0.0]],
		"hand": [[0.0, pouch, 1, 0.0], [0.45, _shift(pump, Vector3(-0.02, -0.04, 0.03)), 0], [0.75, pump, 0, 0.0, -0.2], [1.0, pump, 0, 0.0]],
		"reach": [[0.0, 1.0, 0.0], [0.75, 1.0, 0.0], [1.0, 0.0, 0.0]],
		"lag": [[0.0, 1.0, 0.0], [0.5, 0.5, 0.0], [0.7, 0.0, 0.0]],
		"fingers": [[0.0, {"relaxed": 1.0}], [0.7, {"grip": 1.0}], [1.0, {"grip": 1.0}]],
		"events": [[0.72, {"snd": "grip", "sfx": true, "db": -22.0, "pitch": 1.0}]]}
	var end_empty := end.duplicate(true)
	end_empty["hand"] = [[0.0, pouch, 1, 0.0], [0.3, pump, 0, 0.0, -0.2], [0.42, pump, 0, 0.0],
		[0.55, Transform3D(pump.basis, pump.origin + rack * 0.09), 0, 0.0, 0.4], [0.72, pump, 0, 0.0, 0.5], [1.0, pump, 0, 0.0]]
	end_empty["reach"] = [[0.0, 1.0, 0.0], [0.85, 1.0, 0.0], [1.0, 0.0, 0.0]]
	end_empty["extra"] = {"pump": [[0.0, 0.0, 0.0], [0.42, 0.0, 0.0], [0.55, 1.0, 0.0, 0.4], [0.72, 0.0, 0.0, 0.5], [1.0, 0.0]]}
	end_empty["events"] = [[0.5, {"snd": "pump_back", "db": -4.0, "pitch": 0.95}],
		[0.72, {"snd": "pump_fwd", "db": -3.0, "pitch": 0.95, "p": Vector3(0.0, 0.08, -0.15), "r": Vector3(0.8, 0.0, 0.0)}]]
	return {"start": start, "each": each, "end": end, "end_empty": end_empty}
