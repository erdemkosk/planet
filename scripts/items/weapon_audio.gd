extends RefCounted
## Synthesized weapon sounds that layer with the recorded gunshot crack (assets/audio/weapons):
##   thump      short low body (65-110 Hz falling sine + soft noise), ~0.12 s
##   action     bolt / action clack right after the shot, ~0.06 s
##   tail       soft outdoor tail (dark low-passed noise rumble), ~1.3 s
##   dart       tranquilizer "pfft"
##   tink       brass casing landing
##   dry        empty click
##   punch      sub-bass kick under every gunshot (120 -> 42 Hz sweep with a snap transient), ~0.22 s
##   echo       outdoor slap-back: three dark reflections off the terrain (0.15 / 0.37 / 0.68 s)
## Reload foley: cloth, mag_release, mag_out, mag_in, mag_slap, bolt_back, bolt_fwd, selector.
## Hit confirmation (scripts/items/hit_feel.gd): hit_thwack (meaty body hit), weak_ping (bright
## weak-point ping), kill_thump (deep kill thump with a crunch).
## Built once on a worker thread.
## Recorded foley (Sonniss: Pole Position gun handling, Gorification, Gamemaster; see
## scripts/audio/snd_lib.gd) replaces the synthesized clicks wherever a set exists (RECORDED); the
## low synthesized layers (thump, punch, tail, echo) and dart stay synthesized. Cloth uses the
## handling set foley/cloth (layered recorded foley + fabric, see sfx.gd FOLEY_SETS) when present.

const Snd := preload("res://scripts/audio/snd_lib.gd")
const RATE := 44100
const NAMES := ["thump", "action", "tail", "dart", "tink", "dry", "cloth", "mag_release", "mag_out", "mag_in",
		"mag_slap", "bolt_back", "bolt_fwd", "selector", "punch", "echo"]
const HIT_NAMES := ["hit_thwack", "weak_ping", "kill_thump"]
## Feedback layers built by HitFeel: near-miss whizz / supersonic snap, low-hp heartbeat, head ding.
const FEEL_NAMES := ["whizz", "snap", "heartbeat", "head_ding"]
## Sniper extras (weapon_base.gd builds them with the arsenal set): breath hold, bolt handle clicks.
const SNIPER_NAMES := ["breath_in", "breath_out", "bolt_lift", "bolt_drop"]
## Looped slide scrape (scripts/player/stance.gd).
const LOOP_NAMES := ["scrape"]
## name -> recorded variant set (assets/audio/sonniss/...), played through an AudioStreamRandomizer.
const RECORDED := {"action": "foley/action", "tink": "foley/tink", "dry": "foley/dry",
		"mag_release": "foley/mag_release", "mag_out": "foley/mag_out", "mag_in": "foley/mag_in",
		"mag_slap": "foley/mag_slap", "bolt_back": "foley/bolt_back", "bolt_fwd": "foley/bolt_fwd",
		"selector": "foley/selector", "hit_thwack": "hit/thwack", "weak_ping": "hit/weak", "kill_thump": "hit/kill_thump",
		"cloth": "foley/cloth"}

var rng := RandomNumberGenerator.new()


func _init() -> void:
	rng.seed = 777


## Recorded variant set of `name` as a randomizer, or null (then the synthesized version is used).
func _recorded(table: Dictionary, name: String) -> AudioStream:
	if table.has(name):
		return Snd.rand(table[name], 1.03, 1.0)
	return null


func make(name: String) -> AudioStream:
	var rec := _recorded(RECORDED, name)
	if rec != null:
		return rec
	match name:
		"thump":
			return _wav(_thump())
		"action":
			return _wav(_mix([[_click(0.035, [3100.0, 4700.0, 6900.0], 70.0, 0.6, 0.6), 0.0, 1.0],
					[_click(0.04, [2200.0, 3600.0], 60.0, 0.4, 0.4), 0.022, 0.7]], 0.07), 0.5)
		"tail":
			return _wav(_tail(1.4))
		"dart":
			return _wav(_dart())
		"tink":
			return _wav(_click(0.16, [3150.0, 5230.0, 7900.0], 30.0, 0.1, 0.9), 0.45)
		"dry":
			return _wav(_mix([[_click(0.03, [2600.0, 4100.0], 120.0, 0.7, 0.5), 0.0, 1.0],
					[_click(0.025, [1800.0], 140.0, 0.6, 0.3), 0.03, 0.6]], 0.07), 0.55)
		"cloth":
			return _wav(_slide(0.28, 0.08, 0.6), 0.25)
		"mag_release":
			return _wav(_click(0.05, [2400.0, 3900.0, 5600.0], 75.0, 0.5, 0.6), 0.5)
		"mag_out":
			return _wav(_mix([[_slide(0.16, 0.25, 0.5), 0.0, 0.6], [_click(0.06, [1500.0, 2300.0, 3400.0], 50.0, 0.4, 0.4), 0.13, 1.0]], 0.22), 0.6)
		"mag_in":
			return _wav(_mix([[_slide(0.1, 0.25, 0.5), 0.0, 0.5], [_click(0.07, [900.0, 1700.0, 2800.0], 45.0, 0.6, 0.3), 0.08, 1.0],
					[_click(0.05, [2600.0, 4200.0], 70.0, 0.3, 0.5), 0.11, 0.6]], 0.2), 0.75)
		"mag_slap":
			return _wav(_mix([[_thud(0.09, 160.0), 0.0, 1.0], [_click(0.05, [1900.0, 3100.0], 60.0, 0.5, 0.4), 0.004, 0.7]], 0.1), 0.75)
		"bolt_back":
			return _wav(_mix([[_click(0.04, [2100.0, 3300.0], 70.0, 0.5, 0.4), 0.0, 0.8], [_slide(0.12, 0.35, 0.6), 0.02, 0.6],
					[_click(0.05, [1700.0, 2900.0, 4300.0], 55.0, 0.5, 0.5), 0.12, 1.0]], 0.18), 0.65)
		"bolt_fwd":
			return _wav(_mix([[_slide(0.06, 0.4, 0.6), 0.0, 0.5], [_click(0.08, [1300.0, 2400.0, 3700.0], 40.0, 0.8, 0.4), 0.05, 1.0],
					[_thud(0.06, 200.0), 0.05, 0.6]], 0.15), 0.8)
		"selector":
			return _wav(_click(0.04, [3300.0, 5100.0], 90.0, 0.4, 0.7), 0.45)
		"punch":
			return _wav(_punch(), 0.95)
		"echo":
			return _wav(_echo(), 0.8)
		"hit_thwack":
			return _wav(_mix([[_thud(0.08, 150.0), 0.0, 1.0], [_click(0.03, [1700.0, 2600.0], 120.0, 0.9, 0.5), 0.0, 0.45]], 0.09), 0.85)
		"weak_ping":
			return _wav(_mix([[_click(0.2, [2350.0, 3530.0, 4710.0], 22.0, 0.25, 0.8), 0.0, 1.0],
					[_thud(0.06, 220.0), 0.0, 0.6]], 0.2), 0.7)
		"kill_thump":
			return _wav(_kill_thump(), 0.92)
		"whizz":
			return _wav(_whizz(), 0.7)
		"snap":
			return _wav(_snap(), 0.9)
		"heartbeat":
			return _wav(_heartbeat(), 0.9)
		"head_ding":
			return _wav(_mix([[_click(0.32, [3950.0, 5920.0, 8150.0], 14.0, 0.15, 0.9), 0.0, 1.0],
					[_click(0.05, [2600.0], 90.0, 0.8, 0.6), 0.0, 0.5]], 0.32), 0.75)
		"breath_in":
			return _wav(_breath(0.55, true), 0.35)
		"breath_out":
			return _wav(_breath(0.8, false), 0.35)
		"bolt_lift":
			return _wav(_mix([[_click(0.04, [2300.0, 3500.0], 80.0, 0.6, 0.5), 0.0, 1.0],
					[_slide(0.05, 0.3, 0.5), 0.01, 0.4]], 0.07), 0.55)
		"bolt_drop":
			return _wav(_mix([[_click(0.05, [1900.0, 3100.0, 4400.0], 60.0, 0.7, 0.5), 0.0, 1.0],
					[_thud(0.04, 260.0), 0.0, 0.5]], 0.07), 0.6)
		"scrape":
			return _loop_wav(_scrape(1.2))
	return null


# --- helpers -------------------------------------------------------------------------------------

func _w() -> float:
	return rng.randf() * 2.0 - 1.0


func _buf(sec: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(sec * RATE))
	return s


func _norm(s: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var m := 0.0001
	for v in s:
		m = maxf(m, absf(v))
	for i in s.size():
		s[i] = s[i] / m * peak
	return s


func _wav(samples: PackedFloat32Array, peak := 0.9) -> AudioStreamWAV:
	samples = _norm(samples, peak)
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


## Places parts [samples, offset_sec, gain] into one buffer of `dur` seconds.
func _mix(parts: Array, dur: float) -> PackedFloat32Array:
	var out := _buf(dur)
	for p in parts:
		var s: PackedFloat32Array = _norm(p[0], 1.0)
		var off := int(float(p[1]) * RATE)
		var g: float = p[2]
		for i in s.size():
			var j := off + i
			if j >= out.size():
				break
			out[j] += s[i] * g
	return out


## Metallic click: a noise transient plus damped inharmonic resonances.
func _click(dur: float, freqs: Array, decay: float, noise: float, bright: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	var hp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var n := _w()
		lp += (0.15 + bright * 0.6) * (n - lp)
		var tr := (lp - hp) * exp(-t * 900.0) * noise
		hp = lp
		var ring := 0.0
		for k in freqs.size():
			ring += sin(TAU * float(freqs[k]) * t + k) * exp(-t * decay * (1.0 + k * 0.4)) / (1.0 + k * 0.6)
		s[i] = (tr * 3.0 + ring) * minf(t * 8000.0, 1.0)
	return s


## Soft low thud (plastic / hand slap).
func _thud(dur: float, f0: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var ph := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		ph += TAU * f0 * (1.0 + 0.5 * exp(-t * 60.0)) / RATE
		lp += 0.1 * (_w() - lp)
		s[i] = (sin(ph) + lp * 0.8) * exp(-t * 55.0) * minf(t * 4000.0, 1.0)
	return s


## Filtered-noise scrape / rustle with a smooth envelope.
func _slide(dur: float, cutoff: float, grit: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var u := t / dur
		lp += cutoff * (_w() - lp)
		lp2 += 0.02 * (lp - lp2)
		var g := 1.0 + grit * (0.5 + 0.5 * sin(t * 260.0 + sin(t * 40.0) * 3.0))
		s[i] = (lp - lp2) * g * sin(u * PI)
	return s


func _thump() -> PackedFloat32Array:
	var s := _buf(0.13)
	var ph := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := 62.0 + 70.0 * exp(-t * 40.0)
		ph += TAU * f / RATE
		lp += 0.03 * (_w() - lp)
		var env := exp(-t * 26.0) * minf(t * 1500.0, 1.0)
		s[i] = (sin(ph) + sin(ph * 2.0) * 0.18 + lp * 1.4) * env
	# Gentle saturation for weight without clicks.
	for i in s.size():
		s[i] = tanh(s[i] * 1.8)
	return s


## Gunshot weight: a fast pitch-dropping sine kick (chest thump) with a 2 ms broadband snap on
## top, saturated so it reads on small speakers too.
func _punch() -> PackedFloat32Array:
	var s := _buf(0.22)
	var ph := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := 42.0 + 78.0 * exp(-t * 32.0)
		ph += TAU * f / RATE
		var n := _w()
		lp += 0.25 * (n - lp)
		var body := sin(ph) * exp(-t * 15.0)
		var snap := (n - lp) * exp(-t * 1400.0) * 1.6
		var att := minf(t * 3000.0, 1.0)
		s[i] = tanh((body * 1.7 + sin(ph * 2.0) * 0.25 * exp(-t * 30.0) + snap) * att * 1.5)
	return s


## Slap-back off the surrounding terrain: three dark, smeared copies of a shot burst.
func _echo() -> PackedFloat32Array:
	var s := _buf(1.15)
	var taps := [[0.15, 0.62, 0.05], [0.37, 0.38, 0.08], [0.68, 0.22, 0.12]]
	for tap in taps:
		var off := int(float(tap[0]) * RATE)
		var g: float = tap[1]
		var smear: float = tap[2]
		var lp := 0.0
		var lp2 := 0.0
		var n := int((0.09 + smear * 2.0) * RATE)
		for i in n:
			var j := off + i
			if j >= s.size():
				break
			var t := float(i) / RATE
			lp += 0.06 * (_w() - lp)
			lp2 += 0.25 * (lp - lp2)
			var env := minf(t / maxf(smear * 0.3, 0.004), 1.0) * exp(-t / maxf(smear + 0.03, 0.01) * 2.2)
			s[j] += lp2 * env * g
	return s


## Kill confirm: a deep falling thump, a short crunch and a faint high ring on top.
func _kill_thump() -> PackedFloat32Array:
	var s := _buf(0.32)
	var ph := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := 48.0 + 120.0 * exp(-t * 24.0)
		ph += TAU * f / RATE
		var n := _w()
		lp += 0.35 * (n - lp)
		var body := sin(ph) * exp(-t * 11.0)
		var crunch := lp * exp(-t * 70.0) * (0.6 + 0.4 * sin(t * 900.0))
		var ring := sin(TAU * 1760.0 * t) * exp(-t * 26.0) * 0.18
		s[i] = tanh((body * 1.5 + crunch * 1.2 + ring) * minf(t * 2500.0, 1.0) * 1.4)
	return s


## Dark, soft outdoor tail: low-passed noise that swells for a moment and fades out.
func _tail(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var n := _w()
		lp += 0.035 * (n - lp)
		lp2 += 0.12 * (lp - lp2)
		var env := minf(t * 25.0, 1.0) * exp(-t * 3.2) * (0.85 + 0.15 * sin(t * 13.0))
		s[i] = lp2 * env
	return s


## Looping WAV (forward loop over the whole buffer, ends cross-faded so the seam does not click).
func _loop_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var n := samples.size()
	var fade := int(0.06 * RATE)
	for i in fade:
		var k := float(i) / float(fade)
		samples[i] = samples[i] * k + samples[n - fade + i] * (1.0 - k)
	samples.resize(n - fade)
	var w := _wav(samples, 0.8)
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = samples.size()
	return w


## A bullet passing close by: band-passed noise that swells and falls with a doppler drop.
func _whizz() -> PackedFloat32Array:
	var s := _buf(0.32)
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var u := t / 0.32
		var cut := lerpf(0.55, 0.12, u)          # bright as it arrives, darker as it leaves
		lp += cut * (_w() - lp)
		lp2 += 0.08 * (lp - lp2)
		var env := exp(-pow((u - 0.28) / 0.16, 2.0))
		s[i] = (lp - lp2) * env
	return s


## Supersonic crack: a sharp N-wave with a short bright ring.
func _snap() -> PackedFloat32Array:
	var s := _buf(0.09)
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var nw := 0.0
		if t < 0.0007:
			nw = 1.0 - t / 0.00035
		var n := _w()
		lp += 0.5 * (n - lp)
		var ring := (n - lp) * exp(-t * 160.0) * 0.55
		s[i] = nw + ring + sin(TAU * 3300.0 * t) * exp(-t * 120.0) * 0.2
	return s


## Low-hp heartbeat: "lub-dub", two soft low thumps.
func _heartbeat() -> PackedFloat32Array:
	var s := _buf(0.55)
	for beat in [[0.0, 1.0, 52.0], [0.2, 0.7, 46.0]]:
		var off := int(float(beat[0]) * RATE)
		var g: float = beat[1]
		var f: float = beat[2]
		var ph := 0.0
		for i in int(0.22 * RATE):
			var j := off + i
			if j >= s.size():
				break
			var t := float(i) / RATE
			ph += TAU * f * (1.0 + 0.6 * exp(-t * 40.0)) / RATE
			s[j] += sin(ph) * exp(-t * 22.0) * minf(t * 300.0, 1.0) * g
	for i in s.size():
		s[i] = tanh(s[i] * 1.6)
	return s


## Breath in the helmet: soft filtered noise (in rises, out falls slower).
func _breath(dur: float, inhale: bool) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var u := t / dur
		lp += (0.25 if inhale else 0.16) * (_w() - lp)
		lp2 += 0.03 * (lp - lp2)
		var env := sin(PI * pow(u, 0.6 if inhale else 0.35)) * (1.0 - u * 0.3)
		s[i] = (lp - lp2) * env
	return s


## Slide scrape: grainy low-mid noise with gravel crackle (looped, pitched by speed).
func _scrape(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var n := _w()
		lp += 0.22 * (n - lp)
		lp2 += 0.015 * (lp - lp2)
		var grit := 1.0 + 0.6 * sin(t * 61.0 + sin(t * 13.0) * 2.0)
		var crackle := 0.0
		if rng.randf() < 0.0025:
			crackle = _w() * 2.5
		s[i] = (lp - lp2) * grit + crackle * 0.3
	return s


func _dart() -> PackedFloat32Array:
	var s := _buf(0.35)
	var bp := 0.0
	var lp := 0.0
	var ph := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var n := _w()
		lp += 0.45 * (n - lp)
		bp += 0.2 * (lp - bp)
		var hiss := (lp - bp) * exp(-t * 22.0) * minf(t * 3000.0, 1.0)
		ph += TAU * 620.0 / RATE
		var tock := sin(ph) * exp(-t * 90.0) * 0.6
		s[i] = hiss * 1.6 + tock
	return s
