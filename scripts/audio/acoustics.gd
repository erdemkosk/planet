extends Node
## Acoustic space of the listener (Game.sfx.acoustics, a child of scripts/audio/sfx.gd). Replaces
## the guns' two reverb presets (open / tunnel) with a continuously measured room:
##   Rays      N_RAYS rays from the listener (the camera): up, an 8-ray horizontal ring, 4
##             up-diagonals (50°), 4 down-diagonals (-25°) and down, against the terrain and the
##             structures (LAYER_TERRAIN | LAYER_SHIP), RAYS_PER_FRAME per physics frame (a full sweep
##             ~7 times a second; the ring turns a little every sweep so it samples more directions).
##             Where the collision shapes are not built yet (the floor ray misses while the player
##             stands) a density march (planet.raycast_density) stands in.
##   Measures  enclosure (how closed the sky / the horizon / the ground around are), the typical
##             distance of the enclosing surfaces (room size), the narrowest wall-to-wall span
##             (tunnel width) and the longest (tunnel length), the ceiling / shaft height, the depth
##             below the original surface, and blends of open air, pit / crater, narrow tunnel,
##             vertical shaft and cavern.
##   Reverb    mapped smoothly (SMOOTH_T) onto the AudioEffectReverb of the "Env" bus (world sounds:
##             sfx.gd routes every 3D player in the air, the 2D one-shots, the footsteps, the drill /
##             jetpack loops and the bots' gunfire here) and of the "Weapons" bus (the player's guns):
##             room_size (decay; long tubes ring on), damping (soil absorbs more than the rival
##             planet's rock, small spaces more), wet, predelay = first bounce (2 × distance /
##             SOUND_SPEED), predelay_feedback (flutter between the parallel walls of a tunnel /
##             shaft), hipass (open air keeps the tail thin, a cavern its rumble), spread (only
##             changed while the bus is quiet).
##   Slap      a slap-back echo when the sky is open and a big wall stands SLAP_MIN..MAX_D m away
##             (pit, crater, canyon): AudioEffectDelay's feedback path (low-passed, decaying
##             repeats) before each reverb, time = 2 × wall distance / SOUND_SPEED. The time only
##             changes while the buses are quiet or the echo is off (no clicks), or after
##             SLAP_FORCE_T s for a big change. Weaker on the guns (they bring their own outdoor
##             echo layer), and only for near walls there.
##   Vacuum    (sfx.listener_air) no air, no reverb: Env goes dry, the gun keeps a tiny helmet
##             resonance (the suit-borne thump of weapon_base / rifle).
## Underground ambience: a dark room tone (assets/audio/sonniss/amb/cave_tone, InMotionAudio Cave
## Design) fading in with enclosure and depth, very low in the mix; rare soil-settling trickles /
## clods (amb/settle_*) and, deeper down, drips (amb/drip_*) placed on the measured ceiling and
## walls; a few trickles after a blast nearby while underground (Game.blast).
## Read only: space_kind() -> 1 enclosed / 2 open / 3 vacuum (the guns' tail / echo choice;
## weapon_base.gd / rifle.gd _space_kind() delegate here and their _set_space() is a no-op while
## this node exists), enclosure, room_size_m, ceiling_m, depth_m, underground, kind_name ("açık",
## "çukur", "tünel", "kuyu", "mağara", "oyuk", "boşluk").
## Occlusion: the child `occlusion` (scripts/audio/occlusion.gd) muffles and ducks every 3D world
## sound whose line to the listener runs through soil or a structure (rays + density march).

const Snd := preload("res://scripts/audio/snd_lib.gd")
const Occlusion := preload("res://scripts/audio/occlusion.gd")

const ENV_BUS := "Env"
const WEAPONS_BUS := "Weapons"
const MAX_D := 45.0                  # m: farther surfaces count as open air (collision ~45 m around the camera)
const RAYS_PER_FRAME := 2            # 18 rays: one sweep every 9 physics frames
const SMOOTH_T := 0.12               # s: the reverb follows the measurement (~90 % in 0.3 s)
const SOUND_SPEED := 343.0           # m/s
const SLAP_MIN := 7.0                # m: nearer walls merge into the early reflections (predelay)
const SLAP_QUIET_DB := -50.0         # the echo time changes while both buses are this quiet...
const SLAP_FORCE_T := 1.5            # ...or after this long when the change is big (> 25 %)
const SLAP_GUN_DB := -5.0            # the guns' slap relative to the world's (they have their own echo)
const SLAP_GUN_FAR := Vector2(22.0, 32.0)   # m: the guns' slap fades out over this wall distance
const TONE_MAX := 0.22               # room tone gain at full enclosure and depth (~ -13 dB)
const TONE_T := 1.4                  # s: room tone fade
const FX_ENV_RV := "acu_env_rv"
const FX_ENV_SLAP := "acu_env_slap"
const FX_WPN_SLAP := "acu_wpn_slap"

# Ray layout (canonical, y up): 0 up, 1-8 ring, 9-12 up-diagonals, 13-16 down-diagonals, 17 down.
const N_RAYS := 18
const UP := 0
const RING0 := 1
const UPD0 := 9
const DND0 := 13
const DOWN := 17

# Reverb parameter slots.
const R_ROOM := 0
const R_DAMP := 1
const R_PD := 2
const R_PFB := 3
const R_HIP := 4
const R_WET := 5

var enclosure := 0.0
var room_size_m := MAX_D
var ceiling_m := MAX_D
var depth_m := 0.0
var underground := 0.0
var kind_name := "açık"

var occlusion                        # scripts/audio/occlusion.gd: sounds behind soil muffled
var _sfx = null                      # sfx.gd (parent): listener_pos, listener_air, route_player()
var _rng := RandomNumberGenerator.new()
var _space := 2
var _sky_s := 0.0
var _canon: Array = []
var _rot := 0.0
var _ray_i := 0
var _origin := Vector3.ZERO
var _dirs: Array = []
var _dist := PackedFloat32Array()
var _hit := PackedByteArray()
var _body: Node3D = null
var _rock := false
var _density_mode := false
var _idle_frames := 0
var _query := PhysicsRayQueryParameters3D.new()
# The last finished sweep (ambience placement).
var _a_origin := Vector3.ZERO
var _a_dirs: Array = []
var _a_dist := PackedFloat32Array()
var _a_hit := PackedByteArray()
var _have_sweep := false

# Targets / current values: [room, damping, predelay ms, predelay feedback, hipass, wet].
var _tgt_env := PackedFloat32Array([0.7, 0.78, 75.0, 0.14, 0.3, 0.03])
var _cur_env := PackedFloat32Array([0.7, 0.78, 75.0, 0.14, 0.3, 0.03])
var _tgt_wpn := PackedFloat32Array([0.84, 0.72, 75.0, 0.14, 0.24, 0.11])
var _cur_wpn := PackedFloat32Array([0.84, 0.72, 75.0, 0.14, 0.24, 0.11])
var _tgt_spread := 1.0
var _cur_spread := 1.0
var _tgt_slap_db := -80.0
var _cur_slap_db := -80.0
var _slap_wall := MAX_D
var _slap_want_ms := 120.0
var _slap_ms := 120.0
var _slap_lp := 2400.0
var _slap_pending := 0.0

var _env_idx := -1
var _env_rv: AudioEffectReverb = null
var _env_dl: AudioEffectDelay = null
var _wpn_idx := -1
var _wpn_rv: AudioEffectReverb = null
var _wpn_dl: AudioEffectDelay = null
var _check_t := 0.0

# Underground ambience.
var _tone: AudioStreamPlayer = null
var _tone_v := 0.0
var _shots: Array = []
var _shot_i := 0
var _settle: Array = []
var _drips: Array = []
var _settle_t := 8.0
var _drip_t := 24.0
var _queued: Array = []              # [seconds left, "settle" / "drip"]


func _ready() -> void:
	_sfx = get_parent()
	_rng.randomize()
	_build_canon()
	_dist.resize(N_RAYS)
	_hit.resize(N_RAYS)
	_query.collision_mask = Game.LAYER_TERRAIN | Game.LAYER_SHIP
	ensure_env_bus()
	_build_ambience()
	if Game.has_signal("blast"):
		Game.blast.connect(_on_blast)
	occlusion = Occlusion.new()
	occlusion.name = "Occlusion"
	add_child(occlusion)


## 1 = enclosed (tunnel, shaft, cavern: short gun tail, no outdoor echo layer), 2 = open air / pit,
## 3 = vacuum. With hysteresis on the smoothed sky closure.
func space_kind() -> int:
	if _in_vacuum():
		return 3
	return _space


## The "Env" bus (world sounds -> slap-back delay -> reverb -> Master). Safe to call repeatedly;
## after a scene reload it reuses the bus and its effects (AudioServer is global).
static func ensure_env_bus() -> void:
	var i := AudioServer.get_bus_index(ENV_BUS)
	if i < 0:
		AudioServer.add_bus()
		i = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, ENV_BUS)
		AudioServer.set_bus_send(i, "Master")
		AudioServer.set_bus_volume_db(i, 0.0)
	if _find_fx(i, FX_ENV_SLAP) < 0:
		AudioServer.add_bus_effect(i, _new_slap(FX_ENV_SLAP), 0)
	if _find_fx(i, FX_ENV_RV) < 0:
		var rv := AudioEffectReverb.new()
		rv.resource_name = FX_ENV_RV
		rv.room_size = 0.7
		rv.damping = 0.78
		rv.predelay_msec = 75.0
		rv.predelay_feedback = 0.14
		rv.spread = 1.0
		rv.hipass = 0.3
		rv.dry = 1.0
		rv.wet = 0.03
		AudioServer.add_bus_effect(i, rv)


# =================================================================================================
# Measuring
# =================================================================================================

func _build_canon() -> void:
	_canon.clear()
	_canon.append(Vector3.UP)
	for k in 8:
		var a := TAU * float(k) / 8.0
		_canon.append(Vector3(cos(a), 0.0, sin(a)))
	var e := deg_to_rad(50.0)
	for k in 4:
		var a := TAU * (float(k) + 0.5) / 4.0
		_canon.append(Vector3(cos(a) * cos(e), sin(e), sin(a) * cos(e)))
	var e2 := deg_to_rad(-25.0)
	for k in 4:
		var a := TAU * (float(k) + 0.25) / 4.0
		_canon.append(Vector3(cos(a) * cos(e2), sin(e2), sin(a) * cos(e2)))
	_canon.append(Vector3.DOWN)


func _physics_process(_delta: float) -> void:
	if _sfx == null or not is_instance_valid(_sfx):
		return
	if _in_vacuum():
		_ray_i = 0
		_vacuum_targets()
		return
	var w := get_viewport().find_world_3d()
	if w == null:
		return
	if _idle_frames > 0:
		_idle_frames -= 1
		return
	var space := w.direct_space_state
	for k in RAYS_PER_FRAME:
		if _ray_i == 0:
			_begin_sweep()
			if _body == null or Game.altitude(_origin) > MAX_D + 10.0:
				_all_open()                # far above any ground: nothing to hit
				_idle_frames = ceili(float(N_RAYS) / RAYS_PER_FRAME)   # one sweep's worth
				return
		_cast(_ray_i, space)
		_ray_i += 1
		if _ray_i >= N_RAYS:
			_ray_i = 0
			_analyse()


## Fixes the origin and the frame of one sweep (the local up of the planet underfoot) and turns the
## ring by a golden fraction of its 45° step.
func _begin_sweep() -> void:
	_origin = _sfx.listener_pos
	_body = Game.dominant_body(_origin)
	var up := Vector3.UP
	if _body != null:
		var r := _origin - _body.global_position
		if r.length_squared() > 1e-6:
			up = r.normalized()
	var ref := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := up.cross(ref).normalized()
	var z := x.cross(up)
	_rot = fmod(_rot + PI / 4.0 * 0.618034, PI / 4.0)
	var b := Basis(x, up, z) * Basis(Vector3.UP, _rot)
	_dirs.resize(N_RAYS)
	for i in N_RAYS:
		_dirs[i] = b * (_canon[i] as Vector3)


func _cast(i: int, space: PhysicsDirectSpaceState3D) -> void:
	var to: Vector3 = _origin + (_dirs[i] as Vector3) * MAX_D
	_query.from = _origin
	_query.to = to
	var r := space.intersect_ray(_query)
	var d := MAX_D
	var h := 0
	if not r.is_empty():
		d = _origin.distance_to(r["position"])
		h = 1
	elif _density_mode and _body != null and _body.has_method("raycast_density"):
		var rd: Dictionary = _body.raycast_density(_origin, to, 0.75, true)
		if not rd.is_empty():
			d = float(rd["distance"])
			h = 1
	_dist[i] = d
	_hit[i] = h


func _all_open() -> void:
	for i in N_RAYS:
		_dist[i] = MAX_D
		_hit[i] = 0
	_ray_i = 0
	_analyse()


## Closure of one ray: a near hit closes its direction fully, a far one partly, a miss not at all.
func _cl(i: int) -> float:
	if _hit[i] == 0:
		return 0.0
	return clampf(1.0 - (_dist[i] - 4.0) / 60.0, 0.3, 1.0)


## One finished sweep -> measurements and the reverb / echo / ambience targets.
func _analyse() -> void:
	var sky := (2.0 * _cl(UP) + _cl(UPD0) + _cl(UPD0 + 1) + _cl(UPD0 + 2) + _cl(UPD0 + 3)) / 6.0
	var ring := 0.0
	for k in 8:
		ring += _cl(RING0 + k)
	ring /= 8.0
	var low := (_cl(DND0) + _cl(DND0 + 1) + _cl(DND0 + 2) + _cl(DND0 + 3)) / 4.0
	var enc := clampf(0.42 * sky + 0.43 * ring + 0.15 * low, 0.0, 1.0)
	# The enclosing surfaces (floor ray excluded): typical distance and the first reflections
	# (between the nearest and the median hit).
	var hits: Array = []
	for i in DOWN:
		if _hit[i] != 0:
			hits.append(_dist[i])
	hits.sort()
	var size := MAX_D
	var near := MAX_D
	if not hits.is_empty():
		var s := 0.0
		for v in hits:
			s += float(v)
		size = s / float(hits.size())
		near = lerpf(float(hits[0]), float(hits[hits.size() >> 1]), 0.5)
	var width := INF
	var length := 0.0
	var ring_max := 0.0
	for k in 4:
		var span := _dist[RING0 + k] + _dist[RING0 + k + 4]
		width = minf(width, span)
		length = maxf(length, span)
	for k in 8:
		ring_max = maxf(ring_max, _dist[RING0 + k])
	var up_h := _dist[UP] if _hit[UP] != 0 else MAX_D
	var depth := _depth(_origin)
	# Floor ray missed while the player stands: no collision here yet, march the density next sweep.
	var pl = Game.player
	_density_mode = _hit[DOWN] == 0 and pl != null and is_instance_valid(pl) and pl.get("vehicle") == null \
			and pl.has_method("is_on_floor") and pl.is_on_floor()
	_rock = _is_rock()
	# Blends of the archetypes.
	var closed := smoothstep(0.55, 0.85, sky)
	var tunnel_k := closed * (1.0 - smoothstep(3.0, 7.0, width))
	var cavern_k := closed * smoothstep(6.0, 16.0, size)
	var shaft_k := (1.0 - smoothstep(3.0, 6.0, ring_max)) * smoothstep(6.0, 14.0, up_h)
	var pit_k := (1.0 - smoothstep(0.3, 0.55, sky)) * smoothstep(0.35, 0.7, ring) * (1.0 - shaft_k)
	# Reverb.
	var size_k := smoothstep(1.5, 20.0, size)
	var e := pow(enc, 1.2)
	var long_tube := tunnel_k * smoothstep(10.0, 40.0, length)
	var room_in := lerpf(0.42, 0.92, size_k) + 0.07 * shaft_k + 0.12 * long_tube
	var damp_in := (0.4 if _rock else 0.58) + 0.16 * (1.0 - size_k)
	var pd_in := clampf(2.0 * near / SOUND_SPEED * 1000.0, 4.0, 110.0)
	# Flutter between parallel walls; held back for very short bounces (a metallic comb otherwise).
	var pfb := lerpf(0.14, 0.14 + 0.26 * maxf(tunnel_k, shaft_k), e) * lerpf(0.7, 1.0, smoothstep(8.0, 25.0, pd_in))
	var hip := lerpf(0.3, lerpf(0.16, 0.04, size_k), e)
	var wet_k := 0.85 + 0.15 * size_k
	_tgt_env[R_ROOM] = clampf(lerpf(0.7, room_in, e), 0.2, 0.95)
	_tgt_env[R_DAMP] = clampf(lerpf(0.78, damp_in, e), 0.2, 0.95)
	_tgt_env[R_PD] = lerpf(75.0, pd_in, e)
	_tgt_env[R_PFB] = pfb
	_tgt_env[R_HIP] = hip
	_tgt_env[R_WET] = lerpf(0.03, 0.24, e) * wet_k + 0.04 * pit_k
	_tgt_wpn[R_ROOM] = clampf(lerpf(0.84, room_in + 0.03, e), 0.2, 0.95)
	_tgt_wpn[R_DAMP] = clampf(lerpf(0.72, damp_in - 0.04, e), 0.2, 0.95)
	_tgt_wpn[R_PD] = lerpf(75.0, pd_in, e)
	_tgt_wpn[R_PFB] = pfb
	_tgt_wpn[R_HIP] = clampf(hip - 0.04, 0.0, 1.0)
	_tgt_wpn[R_WET] = lerpf(0.11, 0.28, e) * wet_k + 0.03 * pit_k
	_tgt_spread = lerpf(1.0, 0.6, tunnel_k)
	_slap_targets(sky)
	# Measurements (smoothed over sweeps) and the legacy kind with hysteresis.
	_sky_s = lerpf(_sky_s, sky, 0.5)
	if _space != 1 and _sky_s > 0.55:
		_space = 1
	elif _space == 1 and _sky_s < 0.42:
		_space = 2
	enclosure = lerpf(enclosure, enc, 0.5)
	room_size_m = lerpf(room_size_m, size, 0.5)
	ceiling_m = up_h
	depth_m = depth
	underground = smoothstep(0.45, 0.85, 0.6 * sky + 0.4 * ring) * clampf(0.35 + depth / 10.0, 0.0, 1.0)
	if enc < 0.25:
		kind_name = "açık"
	elif pit_k > 0.5:
		kind_name = "çukur"
	elif shaft_k > 0.5:
		kind_name = "kuyu"
	elif cavern_k > 0.5:
		kind_name = "mağara"
	elif tunnel_k > 0.5:
		kind_name = "tünel"
	else:
		kind_name = "oyuk"
	_a_origin = _origin
	_a_dirs = _dirs.duplicate()
	_a_dist = _dist.duplicate()
	_a_hit = _hit.duplicate()
	_have_sweep = true


## The slap-back target: the longest run of adjacent ring hits at similar distances beyond
## SLAP_MIN (a big wall), only while the sky is open.
func _slap_targets(sky: float) -> void:
	_tgt_slap_db = -80.0
	_slap_lp = 3400.0 if _rock else 2400.0
	if sky >= 0.5:
		return
	var best_n := 0
	var best_d := MAX_D
	for k in 8:
		var i0 := RING0 + k
		var d0 := _dist[i0]
		if _hit[i0] == 0 or d0 < SLAP_MIN:
			continue
		var n := 1
		var acc := d0
		while n < 8:
			var j := RING0 + (k + n) % 8
			if _hit[j] == 0 or _dist[j] < SLAP_MIN or absf(_dist[j] - d0) > d0 * 0.35:
				break
			acc += _dist[j]
			n += 1
		var avg := acc / float(n)
		if n > best_n or (n == best_n and avg < best_d):
			best_n = n
			best_d = avg
	if best_n < 2:
		return
	var lvl := lerpf(-13.0, -21.0, smoothstep(SLAP_MIN, MAX_D, best_d))
	if best_n == 2:
		lvl -= 4.0
	elif best_n == 3:
		lvl -= 2.0
	lvl += linear_to_db(maxf(1.0 - sky / 0.5, 0.05))
	_tgt_slap_db = lvl
	_slap_wall = best_d
	_slap_want_ms = clampf(2.0 * best_d / SOUND_SPEED * 1000.0, 30.0, 300.0)


func _vacuum_targets() -> void:
	_tgt_env[R_WET] = 0.0
	_tgt_wpn[R_ROOM] = 0.12
	_tgt_wpn[R_DAMP] = 0.9
	_tgt_wpn[R_PD] = 4.0
	_tgt_wpn[R_PFB] = 0.0
	_tgt_wpn[R_HIP] = 0.1
	_tgt_wpn[R_WET] = 0.03
	_tgt_slap_db = -80.0
	underground = 0.0
	kind_name = "boşluk"


## m below the original (generated) surface of the planet underfoot (negative above it).
func _depth(p: Vector3) -> float:
	if _body == null or not _body.has_method("surface_height_at"):
		return 0.0
	return float(_body.radius) + float(_body.surface_height_at(p)) - p.distance_to(_body.global_position)


func _is_rock() -> bool:
	if _body == null:
		return false
	var cfg = _body.get("cfg")
	return cfg is Dictionary and str((cfg as Dictionary).get("step", "")) == "step_rock"


func _in_vacuum() -> bool:
	var a = _sfx.get("listener_air") if _sfx != null else null
	return a != null and float(a) < 0.05


# =================================================================================================
# Applying (every frame, smoothed)
# =================================================================================================

func _process(delta: float) -> void:
	if _sfx == null or not is_instance_valid(_sfx):
		return
	var k := 1.0 - exp(-delta / SMOOTH_T)
	for i in 6:
		_cur_env[i] = lerpf(_cur_env[i], _tgt_env[i], k)
		_cur_wpn[i] = lerpf(_cur_wpn[i], _tgt_wpn[i], k)
	_cur_slap_db = lerpf(_cur_slap_db, _tgt_slap_db, k)
	_resolve(delta)
	if _env_rv != null:
		_apply_rv(_env_rv, _cur_env)
	if _wpn_rv != null:
		_apply_rv(_wpn_rv, _cur_wpn)
	_apply_slap(delta)
	if absf(_tgt_spread - _cur_spread) > 0.12 and _quiet(_env_idx) and _quiet(_wpn_idx):
		_cur_spread = _tgt_spread
		if _env_rv != null:
			_env_rv.spread = _cur_spread
		if _wpn_rv != null:
			_wpn_rv.spread = _cur_spread
	_ambience(delta)


static func _apply_rv(rv: AudioEffectReverb, p: PackedFloat32Array) -> void:
	rv.room_size = p[R_ROOM]
	rv.damping = p[R_DAMP]
	rv.predelay_msec = p[R_PD]
	rv.predelay_feedback = p[R_PFB]
	rv.hipass = p[R_HIP]
	rv.wet = p[R_WET]
	rv.dry = 1.0


## The slap level follows every frame; its time only while quiet / off (see the header).
func _apply_slap(delta: float) -> void:
	var gun := _cur_slap_db + SLAP_GUN_DB - 30.0 * smoothstep(SLAP_GUN_FAR.x, SLAP_GUN_FAR.y, _slap_wall)
	if _env_dl != null:
		_env_dl.feedback_level_db = _cur_slap_db if _cur_slap_db > -60.0 else -80.0
		_env_dl.feedback_lowpass = _slap_lp
	if _wpn_dl != null:
		_wpn_dl.feedback_level_db = gun if gun > -60.0 else -80.0
		_wpn_dl.feedback_lowpass = _slap_lp
	var diff := absf(_slap_want_ms - _slap_ms)
	if diff <= 3.0:
		_slap_pending = 0.0
		return
	_slap_pending += delta
	var big := diff > _slap_ms * 0.25 and _slap_pending > SLAP_FORCE_T
	if _cur_slap_db < -45.0 or (_quiet(_env_idx) and _quiet(_wpn_idx)) or big:
		_slap_ms = _slap_want_ms
		_slap_pending = 0.0
		if _env_dl != null:
			_env_dl.feedback_delay_ms = _slap_ms
		if _wpn_dl != null:
			_wpn_dl.feedback_delay_ms = _slap_ms


func _quiet(bus: int) -> bool:
	if bus < 0 or bus >= AudioServer.bus_count:
		return true
	return AudioServer.get_bus_peak_volume_left_db(bus, 0) < SLAP_QUIET_DB \
			and AudioServer.get_bus_peak_volume_right_db(bus, 0) < SLAP_QUIET_DB


## Finds (and once adds) the effects this node drives: Env's delay + reverb, the Weapons bus's
## reverb (made by Rifle._weapons_bus when the first gun is set up) plus a slap delay before it.
## Re-validated every second (another scene / module may rebuild a bus).
func _resolve(delta: float) -> void:
	_check_t -= delta
	var ei := AudioServer.get_bus_index(ENV_BUS)
	var wi := AudioServer.get_bus_index(WEAPONS_BUS)
	if ei == _env_idx and wi == _wpn_idx and _check_t > 0.0:
		return
	_check_t = 1.0
	if ei < 0:
		ensure_env_bus()
		ei = AudioServer.get_bus_index(ENV_BUS)
	if ei != _env_idx or not _owns(ei, _env_rv) or not _owns(ei, _env_dl):
		_env_idx = ei
		var r := _find_fx(ei, FX_ENV_RV)
		var d := _find_fx(ei, FX_ENV_SLAP)
		_env_rv = AudioServer.get_bus_effect(ei, r) as AudioEffectReverb if r >= 0 else null
		_env_dl = AudioServer.get_bus_effect(ei, d) as AudioEffectDelay if d >= 0 else null
		_sync_new(_env_rv, _cur_env, _env_dl, _cur_slap_db)
	if wi != _wpn_idx or (wi >= 0 and (not _owns(wi, _wpn_rv) or not _owns(wi, _wpn_dl))):
		_wpn_idx = wi
		_wpn_rv = null
		_wpn_dl = null
		if wi >= 0:
			var rvi := -1
			for e in AudioServer.get_bus_effect_count(wi):
				if AudioServer.get_bus_effect(wi, e) is AudioEffectReverb:
					rvi = e
					break
			if rvi >= 0:
				if _find_fx(wi, FX_WPN_SLAP) < 0:
					AudioServer.add_bus_effect(wi, _new_slap(FX_WPN_SLAP), rvi)
				var d := _find_fx(wi, FX_WPN_SLAP)
				for e in AudioServer.get_bus_effect_count(wi):
					if AudioServer.get_bus_effect(wi, e) is AudioEffectReverb:
						_wpn_rv = AudioServer.get_bus_effect(wi, e) as AudioEffectReverb
						break
				_wpn_dl = AudioServer.get_bus_effect(wi, d) as AudioEffectDelay if d >= 0 else null
				_sync_new(_wpn_rv, _cur_wpn, _wpn_dl, -80.0)


func _sync_new(rv: AudioEffectReverb, p: PackedFloat32Array, dl: AudioEffectDelay, slap_db: float) -> void:
	if rv != null:
		_apply_rv(rv, p)
		rv.spread = _cur_spread
	if dl != null:
		dl.feedback_delay_ms = _slap_ms
		dl.feedback_level_db = slap_db if slap_db > -60.0 else -80.0


static func _owns(bus: int, fx: AudioEffect) -> bool:
	if fx == null or bus < 0:
		return false
	for e in AudioServer.get_bus_effect_count(bus):
		if AudioServer.get_bus_effect(bus, e) == fx:
			return true
	return false


static func _find_fx(bus: int, rname: String) -> int:
	if bus < 0:
		return -1
	for e in AudioServer.get_bus_effect_count(bus):
		var fx := AudioServer.get_bus_effect(bus, e)
		if fx != null and fx.resource_name == rname:
			return e
	return -1


## A slap-back delay: dry through, taps off, the feedback path is the echo (low-passed repeats).
static func _new_slap(rname: String) -> AudioEffectDelay:
	var d := AudioEffectDelay.new()
	d.resource_name = rname
	d.dry = 1.0
	d.tap1_active = false
	d.tap2_active = false
	d.feedback_active = true
	d.feedback_delay_ms = 120.0
	d.feedback_level_db = -80.0
	d.feedback_lowpass = 2400.0
	return d


# =================================================================================================
# Underground ambience
# =================================================================================================

func _build_ambience() -> void:
	var st: AudioStream = Snd.loop("amb/cave_tone")
	if st != null:
		_tone = AudioStreamPlayer.new()
		_tone.stream = st
		_tone.bus = "Master"
		_tone.volume_db = -80.0
		add_child(_tone)
		_tone.play()
		_tone.stream_paused = true
	_settle = Snd.set_of("amb/settle")
	_drips = Snd.set_of("amb/drip")
	for i in 3:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 2.5
		p.max_distance = 40.0
		p.max_db = 0.0
		p.max_polyphony = 1
		p.set_meta(&"occlusion_k", 0.0)  # placed on the walls the rays just saw: never behind soil
		add_child(p)
		_shots.append(p)
	_settle_t = _rng.randf_range(6.0, 14.0)
	_drip_t = _rng.randf_range(18.0, 40.0)


func _ambience(delta: float) -> void:
	var vac := _in_vacuum()
	var ug := 0.0 if vac else underground
	_tone_v = lerpf(_tone_v, TONE_MAX * ug, 1.0 - exp(-delta / TONE_T))
	if _tone != null:
		_tone.volume_db = linear_to_db(maxf(_tone_v, 0.0001))
		var paused := _tone_v < 0.003
		if _tone.stream_paused != paused:
			_tone.stream_paused = paused
	if vac or not _have_sweep:
		_queued.clear()
		return
	var keep: Array = []
	for q in _queued:
		q[0] = float(q[0]) - delta
		if float(q[0]) > 0.0:
			keep.append(q)
		else:
			_play_shot(str(q[1]))
	_queued = keep
	if ug > 0.45 and not _settle.is_empty():
		_settle_t -= delta
		if _settle_t <= 0.0:
			_settle_t = _rng.randf_range(7.0, 18.0) / lerpf(0.7, 1.3, ug)
			_play_shot("settle")
	if ug > 0.6 and depth_m > 4.0 and not _drips.is_empty():
		_drip_t -= delta
		if _drip_t <= 0.0:
			_drip_t = _rng.randf_range(16.0, 40.0) * (1.0 if _rock else 1.6)
			_play_shot("drip")


## A trickle / clod / drip on the measured ceiling or a wall (3D, through the Env reverb).
func _play_shot(kind: String) -> void:
	var arr: Array = _drips if kind == "drip" else _settle
	if arr.is_empty() or _shots.is_empty():
		return
	var pos := _surface_point()
	if pos == Vector3.INF:
		return
	var idx := _rng.randi() % arr.size()
	if kind == "settle" and arr.size() > 5 and idx >= 5 and _rng.randf() < 0.65:
		idx = _rng.randi() % 5                 # the clods (06, 07) are the rare ones
	var p: AudioStreamPlayer3D = _shots[_shot_i]
	_shot_i = (_shot_i + 1) % _shots.size()
	p.stream = arr[idx]
	p.global_position = pos
	if kind == "drip":
		p.volume_db = _rng.randf_range(-18.0, -13.0)
		p.pitch_scale = _rng.randf_range(0.9, 1.12)
	else:
		p.volume_db = _rng.randf_range(-19.0, -12.0)
		p.pitch_scale = _rng.randf_range(0.85, 1.08)
	p.play()
	if _sfx.has_method("route_player"):
		_sfx.route_player(p)


## A point on the last sweep's ceiling (weighted 3x) or walls, 1.2-16 m away; INF when none.
func _surface_point() -> Vector3:
	if not _have_sweep:
		return Vector3.INF
	var cands: Array = []
	var tot := 0.0
	for i in DOWN:
		if _a_hit[i] == 0 or _a_dist[i] < 1.2 or _a_dist[i] > 16.0:
			continue
		var w := 3.0 if i == UP or (i >= UPD0 and i < DND0) else 1.0
		cands.append([w, i])
		tot += w
	if cands.is_empty():
		return Vector3.INF
	var r := _rng.randf() * tot
	for c in cands:
		r -= float(c[0])
		if r <= 0.0:
			var i: int = c[1]
			return _a_origin + (_a_dirs[i] as Vector3) * (_a_dist[i] - 0.2)
	var last: int = cands[cands.size() - 1][1]
	return _a_origin + (_a_dirs[last] as Vector3) * (_a_dist[last] - 0.2)


## A blast nearby while underground shakes soil loose: 1-3 trickles over the next ~2 s.
func _on_blast(pos: Vector3, radius: float, _team: String) -> void:
	if underground < 0.35 or _settle.is_empty() or _sfx == null or not is_instance_valid(_sfx):
		return
	var d: float = pos.distance_to(_sfx.listener_pos)
	if d > 30.0 + radius:
		return
	var n := 1 + int(_rng.randf() < 0.6) + int(d < 12.0)
	for k in n:
		_queued.append([_rng.randf_range(0.35, 2.4), "settle"])
