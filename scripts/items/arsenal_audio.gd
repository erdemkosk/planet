extends "res://scripts/items/weapon_audio.gd"
## Synthesized sounds for the arsenal (layered with the recorded gunshots like the rifle's):
##   pump_back / pump_fwd   shotgun slide, shell_in   shell pushed into the tube
##   boom_body              deep shotgun / launcher body thump (~0.25 s)
##   launch                 40 mm "thoonk", cyl_click   cylinder ratchet, bounce   grenade clank
##   boom / boom_far        explosion body (near: sharp + rumble, far: dull rumble)
##   motor                  minigun spin loop (looped WAV, pitched by spin), hiss   overheat steam
##   belt                   belt link rattle, pin / spoon   hand grenade, beep   cooking beep
##   inject                 injector click + hiss, shield_break   shield shatter sweep, shield_up   recharge
## Kinetik İtici (scripts/items/kinetic_pusher.gd):
##   push_charge            wind-up: capacitor whine sweeping up with a fizzing buzz (~0.2 s)
##   push_whump             the blast: a heavy pressure "whump" under a dark air burst (~0.6 s)
##   push_crackle           electric discharge crackle (~0.45 s), push_ready   capacitor-full chime
## Roketatar rockets (scripts/items/rockets.gd), looped WAVs pitched by the flight:
##   rocket_roar            tearing motor roar with solid-fuel crackle, rocket_whistle   coasting whistle

const ARSENAL_NAMES := ["pump_back", "pump_fwd", "shell_in", "boom_body", "launch", "cyl_click", "bounce",
		"boom", "boom_far", "motor", "hiss", "belt", "pin", "spoon", "beep", "inject", "shield_break", "shield_up",
		"push_charge", "push_whump", "push_crackle", "push_ready", "rocket_roar", "rocket_whistle"]
## Recorded replacements (Sonniss: TS Sound 12 gauge, Bluezone detonation, 3maze motors, PMSFX air
## hiss, Sound Spark energy, Gorification blades...). boom_body stays synthesized (low body layer).
const ARSENAL_RECORDED := {"pump_back": "foley/pump_back", "pump_fwd": "foley/pump_fwd", "shell_in": "foley/shell_in",
		"launch": "weap/launch", "cyl_click": "foley/cyl", "bounce": "foley/bounce", "boom": "expl/explosion",
		"boom_far": "expl/far", "hiss": "foley/hiss", "belt": "foley/belt", "pin": "foley/pin",
		"spoon": "foley/spoon", "beep": "foley/beep", "inject": "foley/inject",
		"shield_break": "foley/shield_break", "shield_up": "foley/shield_up"}


func make(name: String) -> AudioStream:
	if name == "motor":
		# Minigun spin: a recorded electric motor loop, pitched by spin in minigun.gd.
		var m := Snd.loop("foley/motor_loop")
		if m != null:
			return m
	var rec := _recorded(ARSENAL_RECORDED, name)
	if rec != null:
		return rec
	match name:
		"pump_back":
			return _wav(_mix([[_click(0.05, [1500.0, 2600.0, 3900.0], 55.0, 0.7, 0.4), 0.0, 1.0],
					[_slide(0.09, 0.3, 0.7), 0.02, 0.7], [_click(0.06, [1100.0, 2100.0], 45.0, 0.6, 0.3), 0.1, 0.9]], 0.18), 0.8)
		"pump_fwd":
			return _wav(_mix([[_slide(0.07, 0.35, 0.6), 0.0, 0.6], [_click(0.08, [900.0, 1900.0, 3200.0], 40.0, 0.8, 0.35), 0.06, 1.0],
					[_thud(0.07, 170.0), 0.065, 0.7]], 0.16), 0.85)
		"shell_in":
			return _wav(_mix([[_slide(0.07, 0.2, 0.5), 0.0, 0.5], [_click(0.05, [1300.0, 2500.0], 60.0, 0.5, 0.35), 0.06, 1.0],
					[_thud(0.05, 210.0), 0.065, 0.5]], 0.14), 0.7)
		"boom_body":
			return _wav(_boom_body(0.28, 52.0), 0.95)
		"launch":
			return _wav(_launch(), 0.95)
		"cyl_click":
			return _wav(_mix([[_click(0.035, [2600.0, 4100.0], 80.0, 0.5, 0.6), 0.0, 1.0],
					[_click(0.03, [2200.0, 3500.0], 90.0, 0.4, 0.5), 0.045, 0.7]], 0.09), 0.55)
		"bounce":
			return _wav(_mix([[_thud(0.08, 140.0), 0.0, 1.0], [_click(0.12, [780.0, 1430.0, 2610.0], 28.0, 0.5, 0.3), 0.0, 0.8]], 0.16), 0.8)
		"boom":
			return _wav(_boom(1.6, false), 0.98)
		"boom_far":
			return _wav(_boom(2.0, true), 0.9)
		"motor":
			var w := _wav(_motor(1.0), 0.6)
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(1.0 * RATE)
			return w
		"hiss":
			return _wav(_hiss(1.4), 0.55)
		"belt":
			var parts: Array = []
			for i in 5:
				parts.append([_click(0.03, [2900.0 + i * 140.0, 4400.0], 110.0, 0.5, 0.6), i * 0.022, 1.0 - i * 0.12])
			return _wav(_mix(parts, 0.16), 0.5)
		"pin":
			return _wav(_mix([[_click(0.05, [3400.0, 5200.0], 60.0, 0.4, 0.7), 0.0, 1.0],
					[_click(0.25, [4100.0, 6300.0, 8100.0], 18.0, 0.1, 0.9), 0.04, 0.5]], 0.3), 0.6)
		"spoon":
			return _wav(_click(0.3, [3700.0, 5900.0, 7700.0], 14.0, 0.2, 0.9), 0.45)
		"beep":
			return _wav(_beep(0.07, 2300.0), 0.5)
		"inject":
			return _wav(_mix([[_click(0.04, [2800.0, 4600.0], 80.0, 0.6, 0.6), 0.0, 1.0], [_hiss(0.5), 0.03, 0.8]], 0.55), 0.6)
		"shield_break":
			return _wav(_sweep(0.6, 1800.0, 160.0), 0.8)
		"shield_up":
			return _wav(_sweep(0.45, 300.0, 1400.0), 0.45)
		"push_charge":
			return _wav(_charge_whine(0.2), 0.6)
		"push_whump":
			return _wav(_whump(0.62), 0.97)
		"push_crackle":
			return _wav(_crackle(0.45), 0.7)
		"push_ready":
			return _wav(_mix([[_beep(0.06, 1320.0), 0.0, 0.7], [_beep(0.09, 1980.0), 0.065, 1.0],
					[_click(0.03, [3800.0, 5200.0], 120.0, 0.3, 0.7), 0.0, 0.3]], 0.2), 0.45)
		"rocket_roar":
			return _loop_wav(_rocket_roar(1.3))
		"rocket_whistle":
			# Whole-cycle frequencies over exactly 1 s: loops without a seam.
			var w := _wav(_rocket_whistle(1.0), 0.6)
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = RATE
			return w
	return super.make(name)


# --- generators ----------------------------------------------------------------------------------

func _boom_body(dur: float, f0: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var ph := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := f0 + 90.0 * exp(-t * 30.0)
		ph += TAU * f / RATE
		lp += 0.04 * (_w() - lp)
		var env := exp(-t * 14.0) * minf(t * 1200.0, 1.0)
		s[i] = tanh((sin(ph) + sin(ph * 2.0) * 0.2 + lp * 1.6) * env * 2.0)
	return s


func _launch() -> PackedFloat32Array:
	var s := _buf(0.32)
	var ph := 0.0
	var lp := 0.0
	var bp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := 75.0 + 160.0 * exp(-t * 45.0)
		ph += TAU * f / RATE
		var n := _w()
		lp += 0.06 * (n - lp)
		bp += 0.3 * (n - bp)
		var pop := sin(ph) * exp(-t * 18.0)
		var chuff := (bp - lp) * exp(-t * 35.0) * 0.8
		s[i] = tanh((pop * 1.4 + chuff + lp * exp(-t * 10.0) * 1.2) * minf(t * 2000.0, 1.0) * 1.6)
	return s


func _boom(dur: float, far: bool) -> PackedFloat32Array:
	var s := _buf(dur)
	var ph := 0.0
	var lp := 0.0
	var lp2 := 0.0
	var crack := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var n := _w()
		lp += (0.02 if far else 0.05) * (n - lp)
		lp2 += 0.01 * (lp - lp2)
		crack += 0.5 * (n - crack)
		var f := 38.0 + 70.0 * exp(-t * 12.0)
		ph += TAU * f / RATE
		var body := sin(ph) * exp(-t * (3.5 if far else 5.0))
		var rumble := (lp * 1.6 + lp2 * 3.0) * exp(-t * (1.8 if far else 2.4)) * (0.8 + 0.2 * sin(t * 23.0))
		var hit := 0.0 if far else (crack * exp(-t * 60.0) * 1.2)
		var att := minf(t * (300.0 if far else 3000.0), 1.0)
		s[i] = tanh((body * 1.3 + rumble + hit) * att * 1.8)
	return s


## Electric motor + gear whine; seamless one-second loop (whole-cycle frequencies).
func _motor(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		lp += 0.08 * (_w() - lp)
		var whine := sin(TAU * 220.0 * t) * 0.5 + sin(TAU * 440.0 * t) * 0.25 + sin(TAU * 660.0 * t) * 0.12
		var gear := sin(TAU * 55.0 * t) * (0.5 + 0.5 * sin(TAU * 18.0 * t))
		var rattle := lp * (0.6 + 0.4 * sin(TAU * 36.0 * t))
		s[i] = whine * 0.5 + gear * 0.35 + rattle * 0.5
	return s


func _hiss(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var n := _w()
		lp += 0.3 * (n - lp)
		var env := minf(t * 30.0, 1.0) * exp(-t * 2.2)
		s[i] = (n - lp) * env
	return s


func _beep(dur: float, f: float) -> PackedFloat32Array:
	var s := _buf(dur)
	for i in s.size():
		var t := float(i) / RATE
		s[i] = sin(TAU * f * t) * minf(t * 400.0, 1.0) * minf((dur - t) * 400.0, 1.0)
	return s


func _sweep(dur: float, f0: float, f1: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var ph := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var u := t / dur
		var f := lerpf(f0, f1, u * u if f1 < f0 else sqrt(u))
		ph += TAU * f / RATE
		lp += 0.4 * (_w() - lp)
		var env := minf(t * 200.0, 1.0) * (1.0 - u) * (1.0 - u)
		s[i] = (sin(ph) * 0.6 + sin(ph * 2.01) * 0.25 + lp * 0.35) * env
	return s


# --- Kinetik İtici / Roketatar -------------------------------------------------------------------

## Capacitor wind-up: a whine sweeping 280 -> 1900 Hz with a square-ish sub buzz and a sizzle that
## grows toward the release.
func _charge_whine(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var ph := 0.0
	var ph2 := 0.0
	var lp := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var u := t / dur
		var f := lerpf(280.0, 1900.0, u * u)
		ph += TAU * f / RATE
		ph2 += TAU * f * 1.503 / RATE
		lp += 0.5 * (_w() - lp)
		var buzz := signf(sin(ph * 0.5)) * 0.3
		var env := minf(t * 60.0, 1.0) * (0.35 + 0.65 * u)
		s[i] = (sin(ph) * 0.6 + sin(ph2) * 0.2 + buzz * 0.3 + lp * 0.3 * u) * env
	return s


## The shock: a 95 -> 32 Hz drop (the chest "whump") under a dark low-passed air burst, saturated.
func _whump(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var ph := 0.0
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var f := 32.0 + 63.0 * exp(-t * 14.0)
		ph += TAU * f / RATE
		var n := _w()
		lp += 0.06 * (n - lp)
		lp2 += 0.012 * (lp - lp2)
		var body := sin(ph) * exp(-t * 6.5)
		var air := (lp * 1.4 + lp2 * 2.5) * exp(-t * 7.0)
		var att := minf(t * 900.0, 1.0)
		s[i] = tanh((body * 1.6 + air) * att * 1.7)
	return s


## Electric discharge: sparse sharp snaps over a sizzling high band, thinning out as it decays.
func _crackle(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	var snap := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var n := _w()
		lp += 0.55 * (n - lp)
		var hiss := (n - lp) * 0.35
		if rng.randf() < 0.004 * exp(-t * 6.0):
			snap = _w() * 1.5
		snap *= 0.93
		var env := exp(-t * 7.0) * minf(t * 2000.0, 1.0)
		s[i] = (hiss + snap) * env
	return s


## Rocket motor (looped): low roar with a fluttering tearing band and random solid-fuel pops.
func _rocket_roar(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	var lp2 := 0.0
	var bp := 0.0
	var pop := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var n := _w()
		lp += 0.09 * (n - lp)
		lp2 += 0.02 * (lp - lp2)
		bp += 0.35 * (n - bp)
		if rng.randf() < 0.0012:
			pop = _w() * 2.0
		pop *= 0.96
		var flutter := 0.75 + 0.25 * sin(t * TAU * 23.0 + sin(t * TAU * 7.0) * 2.0)
		s[i] = lp2 * 3.2 + (lp - lp2) * 1.4 * flutter + (bp - lp) * 0.35 + pop * 0.6
	return s


## Coasting rocket: a resonant whistle (whole cycles per second, so 1 s loops) over airy noise.
func _rocket_whistle(dur: float) -> PackedFloat32Array:
	var s := _buf(dur)
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		lp += 0.4 * (_w() - lp)
		lp2 += 0.12 * (lp - lp2)
		var tone := sin(TAU * 1800.0 * t + sin(TAU * 3.0 * t) * 4.0) * 0.35 + sin(TAU * 2700.0 * t) * 0.1
		s[i] = (lp - lp2) * 0.8 + tone * (0.8 + 0.2 * sin(TAU * 5.0 * t))
	return s
