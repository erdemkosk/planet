extends Node3D
## Sound of the Mekik (skiff.gd), recorded loops from assets/audio/sonniss/shuttle (snd_lib.gd),
## pitched up a little for a craft this small:
##   rumble / sub   main engine body, swells with forward thrust and boost (at the tail)
##   whine          turbine, follows the overall power
##   vtol           lift-jet wash under the belly
##   boost          afterburner roar
##   bed            the cabin's own air and electronics (2D, only while seated)
## One-shots: start-up / shut-down, lift-jet puffs, gear clunk, boost whoosh, touchdown, impacts.
## Medium (no sound in vacuum): the ship's players sit on their own "Skiff" bus, which this script
## sets from where the listener is:
##   seated in a Mekik  muffled through the hull (in vacuum only the structure-borne low end)
##   outside, in air    the open exterior sound, thinner high up; a ship out in the vacuum is silent
##   outside, vacuum    nothing

const Snd := preload("res://scripts/audio/snd_lib.gd")
const BUS := "Skiff"
const PITCH := 1.12                 # a smaller machine than the recordings

var ship
var _loops := {}                    # name -> [player, base_db, cur, target, pitch]
var _pool: Array = []
var _bed: AudioStreamPlayer
var _bed_lvl := 0.0
var _rng := RandomNumberGenerator.new()
var _was_boost := false
var _puff_t := 0.0
var _gate := 1.0                    # this ship's audibility from the listener (vacuum rule)
var _alarm: AudioStreamPlayer

static var _rec := {}
static var _alarm_stream: AudioStreamWAV


func _ready() -> void:
	_rng.randomize()
	_ensure_bus()
	_loop("rumble", "shuttle/rumble", -9.0, Vector3(0.0, 1.2, 2.3))
	_loop("sub", "shuttle/sub", -6.0, Vector3(0.0, 1.0, 0.6))
	_loop("whine", "shuttle/whine", -19.0, Vector3(0.0, 1.2, 1.9))
	_loop("vtol", "shuttle/vtol", -13.0, Vector3(0.0, 0.45, 0.1))
	_loop("boost", "shuttle/boost", -10.0, Vector3(0.0, 1.2, 2.6))
	_bed = AudioStreamPlayer.new()
	_bed.stream = Snd.loop("shuttle/cockpit_bed")
	_bed.volume_db = -80.0
	add_child(_bed)
	if _bed.stream != null:
		_bed.play()
		_bed.stream_paused = true
	_alarm = AudioStreamPlayer.new()
	_alarm.stream = _alarm_wav()
	_alarm.volume_db = -15.0
	add_child(_alarm)
	for i in 6:
		var p := AudioStreamPlayer3D.new()
		p.bus = BUS
		p.unit_size = 10.0
		p.max_db = 0.0
		p.max_distance = 250.0
		p.panning_strength = 0.5
		add_child(p)
		_pool.append(p)


static func _ensure_bus() -> void:
	if AudioServer.get_bus_index(BUS) >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, BUS)
	AudioServer.set_bus_send(i, "Master")
	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = 16000.0
	lp.resonance = 0.5
	lp.db = AudioEffectFilter.FILTER_24DB
	AudioServer.add_bus_effect(i, lp)
	var comp := AudioEffectCompressor.new()
	comp.threshold = -14.0
	comp.ratio = 3.0
	comp.attack_us = 20000.0
	comp.release_ms = 250.0
	AudioServer.add_bus_effect(i, comp)


func _loop(name: String, rel: String, base_db: float, at: Vector3) -> void:
	var p := AudioStreamPlayer3D.new()
	p.stream = Snd.loop(rel)
	p.bus = BUS
	p.unit_size = 12.0
	p.max_db = 0.0
	p.max_distance = 300.0
	p.panning_strength = 0.35
	p.volume_db = -80.0
	p.position = at
	add_child(p)
	if p.stream != null:
		p.play()
		p.stream_paused = true
	_loops[name] = [p, base_db, 0.0, 0.0, PITCH]


func _lvl(name: String, level: float, pitch: float) -> void:
	var l: Array = _loops[name]
	l[3] = clampf(level, 0.0, 1.5)
	l[4] = clampf(pitch * PITCH, 0.3, 3.0)


## Called every frame by the ship: power 0..1 (engines running), thrust 0..~1.4 (main engine),
## vtol 0..1 (lift jets), boost 0..1, spool 0..1 (lift-off), speed m/s.
func update(delta: float, power: float, thrust: float, vtol: float, boost: float, spool: float, speed: float) -> void:
	var sk := clampf(speed / 35.0, 0.0, 1.0)
	_lvl("rumble", power * (0.35 + 0.45 * thrust + 0.3 * boost), 0.92 + 0.14 * thrust + 0.05 * boost + 0.03 * sk)
	_lvl("sub", power * (0.2 + 0.3 * thrust + 0.45 * boost + 0.3 * spool), 0.88 + 0.12 * thrust)
	_lvl("whine", power * (0.3 + 0.35 * thrust + 0.2 * vtol + 0.35 * spool), 0.88 + 0.25 * thrust + 0.12 * boost + 0.18 * spool)
	_lvl("vtol", power * maxf(vtol, spool * 0.9) * 0.85, 0.9 + 0.12 * vtol + 0.06 * spool)
	_lvl("boost", power * pow(boost, 1.4) * 0.85, 0.92 + 0.1 * boost)
	if boost > 0.12 and not _was_boost:
		shot("shuttle/boost_whoosh", -12.0, 1.05, Vector3(0.0, 1.2, 2.0))
	_was_boost = boost > 0.12
	# Lift-jet puffs while hovering on the jets.
	_puff_t -= delta
	if power > 0.5 and vtol > 0.45 and _puff_t <= 0.0:
		_puff_t = _rng.randf_range(1.0, 2.4)
		puff(0.3 + vtol * 0.3)
	_update_medium(delta)
	var k := 1.0 - exp(-7.0 * delta)
	for name in _loops:
		var l: Array = _loops[name]
		var p: AudioStreamPlayer3D = l[0]
		l[2] = lerpf(float(l[2]), float(l[3]) * _gate, k)
		p.pitch_scale = lerpf(p.pitch_scale, float(l[4]), k)
		p.volume_db = linear_to_db(maxf(float(l[2]), 0.0001)) + float(l[1])
		p.stream_paused = float(l[2]) < 0.003
	# The cabin bed: only for whoever sits inside.
	var bed_t := 0.75 if ship != null and ship.pilot != null else 0.0
	_bed_lvl = lerpf(_bed_lvl, bed_t, 1.0 - exp(-2.0 * delta))
	if _bed.stream != null:
		_bed.volume_db = linear_to_db(maxf(_bed_lvl, 0.0001)) - 9.0
		_bed.stream_paused = _bed_lvl < 0.003


## Bus filter / volume from the listener's medium; this ship's gate from the air at the ship.
func _update_medium(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var lpos: Vector3 = cam.global_position if cam != null else global_position
	var lis_air := smoothstep(0.0, 0.3, Game.atmosphere_factor(lpos))
	var src_air := smoothstep(0.0, 0.3, Game.atmosphere_factor(global_position))
	var pl = Game.player
	var inside := false
	if pl != null and is_instance_valid(pl):
		var v = pl.get("vehicle")
		inside = v != null and is_instance_valid(v) and (v as Object).has_method("is_skiff")
	var mine: bool = ship != null and ship.pilot != null
	var cut := 16000.0
	var vol := 0.0
	if inside:
		cut = lerpf(600.0, 2600.0, lis_air)
		vol = lerpf(-4.0, -1.0, lis_air)
	elif lis_air > 0.05:
		cut = 16000.0
		vol = linear_to_db(clampf(lis_air * 1.3, 0.25, 1.0))
	else:
		vol = -80.0
	# Seated in another ship, or outside: a ship out in the vacuum is not heard.
	_gate = 1.0 if mine else (src_air if not inside or lis_air > 0.05 else 0.0)
	var bi := AudioServer.get_bus_index(BUS)
	if bi < 0:
		return
	var lp := AudioServer.get_bus_effect(bi, 0) as AudioEffectLowPassFilter
	if lp != null:
		lp.cutoff_hz = exp(lerpf(log(maxf(lp.cutoff_hz, 20.0)), log(cut), 1.0 - exp(-4.0 * delta)))
	var cur := AudioServer.get_bus_volume_db(bi)
	AudioServer.set_bus_volume_db(bi, vol if vol < -60.0 and cur < -40.0 else lerpf(cur, vol, 1.0 - exp(-3.0 * delta)))


# ------------------------------------------------------------------------------------------
# One-shots
# ------------------------------------------------------------------------------------------

func shot(rel: String, db: float, pitch := 1.0, at := Vector3.ZERO, numbered := false) -> void:
	var key := ("set:" if numbered else "") + rel
	if not _rec.has(key):
		_rec[key] = Snd.rand(rel) if numbered else Snd.one(rel)
	var s: AudioStream = _rec[key]
	if s == null:
		return
	for p: AudioStreamPlayer3D in _pool:
		if not p.playing:
			p.stream = s
			p.volume_db = db
			p.pitch_scale = pitch
			p.position = at
			p.play()
			return


func startup() -> void:
	shot("shuttle/startup", -11.0, 1.1, Vector3(0.0, 1.2, 1.6))


func shutdown() -> void:
	shot("shuttle/shutdown", -12.0, 1.1, Vector3(0.0, 1.2, 1.6))


func puff(k: float) -> void:
	shot("shuttle/puff", linear_to_db(clampf(k, 0.1, 1.0)) - 17.0, _rng.randf_range(1.0, 1.12), Vector3(0.0, 0.4, 0.1), true)


func gear() -> void:
	shot("shuttle/gear", -16.0, 1.15, Vector3(0.0, 0.5, 0.0))


func touchdown(k: float) -> void:
	var db := linear_to_db(clampf(k, 0.1, 1.0))
	shot("impact/thud", db - 9.0, 1.0, Vector3(0.0, 0.2, 0.0), true)
	shot("foot/land_rock", db - 8.0, 0.95, Vector3(0.0, 0.2, 0.0), true)
	puff(0.5)


## Master-caution alarm in the cabin (two-tone chime, repeating) on / off.
func alarm(on: bool) -> void:
	if on and not _alarm.playing:
		_alarm.play()
	elif not on and _alarm.playing:
		_alarm.stop()


## Two-tone caution chime (880 / 660 Hz) with a pause, 1.2 s, looping. Synthesized once.
static func _alarm_wav() -> AudioStreamWAV:
	if _alarm_stream != null:
		return _alarm_stream
	var rate := 22050
	var n := int(rate * 1.2)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / float(rate)
		var s := 0.0
		for tone: Vector3 in [Vector3(0.0, 0.17, 880.0), Vector3(0.23, 0.4, 660.0)]:
			if t >= tone.x and t < tone.y:
				var env := minf((t - tone.x) / 0.006, 1.0) * minf((tone.y - t) / 0.03, 1.0)
				var ph := TAU * tone.z * t
				s += (sin(ph) + 0.22 * sin(ph * 3.0) + 0.08 * sin(ph * 5.0)) * env
		data.encode_s16(i * 2, int(clampf(s * 0.42, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	_alarm_stream = w
	return w


func impact(k: float) -> void:
	var db := linear_to_db(clampf(k, 0.05, 1.0))
	shot("impact/thud", db - 3.0, _rng.randf_range(0.85, 1.0), Vector3(0.0, 0.8, 0.0), true)
	shot("impact/metal_heavy_01", db - 5.0, _rng.randf_range(0.9, 1.05), Vector3(0.0, 1.0, 0.0))
