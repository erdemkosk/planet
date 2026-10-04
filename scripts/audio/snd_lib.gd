extends RefCounted
## Recorded sound library: the Sonniss GDC bundle recordings processed into
## assets/audio/sonniss/<group>/<name>_NN.wav|ogg (licence: assets/audio/LICENSE_Sonniss.txt).
## Variant sets, AudioStreamRandomizers (random pick, no repeats, small pitch / volume spread) and
## looping streams. Static and cache-free, so it is safe to call from worker threads (it only loads).

const ROOT := "res://assets/audio/sonniss/"


## One sound by path without extension ("foley/beep_01"): WAV first, then OGG. null if missing.
static func one(rel: String) -> AudioStream:
	for ext: String in [".wav", ".ogg"]:
		var p: String = ROOT + rel + ext
		if ResourceLoader.exists(p):
			return load(p) as AudioStream
	return null


## Every numbered variant "<rel>_01", "<rel>_02", ... up to the first missing number.
static func set_of(rel: String, max_n := 24) -> Array:
	var out: Array = []
	for i in range(1, max_n + 1):
		var s: AudioStream = one("%s_%02d" % [rel, i])
		if s == null:
			break
		out.append(s)
	return out


## The variant set of `rel` as one AudioStreamRandomizer (null when the set is empty).
static func rand(rel: String, pitch := 1.04, vol_db := 1.5) -> AudioStream:
	var arr: Array = set_of(rel)
	if arr.is_empty():
		return null
	return randomizer(arr, pitch, vol_db)


## Wraps streams in a randomizer: `pitch` is the max pitch ratio (1.04 = +-4 %), `vol_db` the
## max volume offset either way.
static func randomizer(streams: Array, pitch := 1.04, vol_db := 1.5) -> AudioStreamRandomizer:
	var r := AudioStreamRandomizer.new()
	r.random_pitch = pitch
	r.random_volume_offset_db = vol_db
	for s in streams:
		if s is AudioStream:
			r.add_stream(-1, s, 1.0)
	return r


## A looping stream ("amb/wind_gusty"): OGG with loop on, WAV looped forward over the whole clip.
static func loop(rel: String) -> AudioStream:
	var s: AudioStream = one(rel)
	if s is AudioStreamOggVorbis:
		var o := (s as AudioStreamOggVorbis).duplicate() as AudioStreamOggVorbis
		o.loop = true
		return o
	if s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		if w.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			w = w.duplicate() as AudioStreamWAV
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(round(w.get_length() * float(w.mix_rate)))
		return w
	return s
