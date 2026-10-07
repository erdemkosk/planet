extends Node
## How the fight feels to the local player. Local only: nothing here is networked.
##
## Patlama sağırlığı (blast deafness). Every Game.blast(pos, radius, team) (scripts/items/explosion.gd:
## shells, rockets, grenades, the bunker buster, torpedoes, wrecks) is scored at the listener by
## blast radius over distance, L = radius / distance:
##   k  = ln(L / 0.3) / ln(8.7)    deafness: a grenade at 3 m ≈ 1, a cannon shell at 15 m ≈ 0.45,
##                                 a shell at 30 m ≈ 0.1 (nothing but the thump)
##   kt = ln(L / 0.12) / ln(21.7)  the pressure thump, which carries farther
## The effect lands with the sound (distance / 340 m/s) and brings, scaled by k:
##   - a pressure thump: a recorded sub "whump" with an ear-pressure layer (assets/audio/sonniss/feel);
##   - tinnitus, synthesized (real tinnitus is a tone): two partials near 3.9 kHz beating at 2.75 Hz,
##     a faint octave below, a breath of narrow-band air, a slow amplitude wobble, a 0.12 s soft
##     attack and a slight pitch sag as it fades over 1.5-4 s;
##   - the world muffle: a low-pass plus a small duck that open again over the same time, at the end
##     of every world bus (WORLD_BUSES: "Env" = world sounds in the air, the guns' "Weapons", the
##     vacuum routes, the skiff, the bots' radio), so the ring, the thump, the hit confirms and the
##     UI on Master stay clear. The heavy-hit muffle of scripts/ui/damage_ui.gd goes through here
##     (muffle_hit): one filter ("dmg_muffle") serves both. Without an "Env" bus (older routing)
##     the pair sits first on Master instead and the ring is pre-boosted by exactly what the filter
##     takes at its frequency (_lp_gain: the RBJ response of the single-stage filter) and the duck;
##   - a short concussion on screen: blur, a drifting double image and desaturation, recovering in
##     about half the time. The camera trauma stays explosion.gd's.
## Rock between the listener and the blast dulls the ring and the picture. In a seat it is scaled
## down (×0.5, the closed skiff cockpit ×0.35); while ragdolled it plays in full. Vacuum rule
## (sfx.gd route_for): through the air in full; through the ground you stand on or your own hull the
## ring and thump come through the suit (bone conduction) and the muffle is lighter; with no medium
## only a blast right on you (its gas and fragments hit the suit) counts.
##
## Baskı altında kalma (suppression). `suppression` (0..1) rises on enemy near misses (hit_feel.gd:
## whizz / snap, and enemy shots that strike close by), nearby blasts and hits taken (damage_ui.gd).
## It holds 0.5 s, then decays in ~2 s. It darkens, desaturates and softly blurs the screen edges,
## makes you breathe hard (scripts/ui/helmet_fx.gd reads `suppression`: the one breathing voice),
## speeds the heartbeat up and makes it a little louder (damage_ui.gd), widens weapon spread by up to
## 35 % (spread_mult(), used by GunFeel.stance_spread) and adds a slight aim tremble on foot.
##
##   FeelFx.inst()                 the instance (child of the Game autoload, made on first use)
##   suppress(amount)              feed suppression (amount on the 0..1 scale, saturating)
##   muffle_hit(k)                 heavy-hit muffle from damage_ui.gd (k 0..1, opens in ~0.7 s)
##   static spread_mult() -> float 1 .. 1.35, from the current suppression
##   suppression, deaf             current levels (deaf: the blast deafness envelope, 0..1)

const Snd := preload("res://scripts/audio/snd_lib.gd")

const SOUND_SPEED := 340.0
const MUFFLE_NAME := "dmg_muffle"      # the muffle low-pass (damage_ui.gd used to own it on Master)
const DUCK_NAME := "feel_duck"         # the duck right after it
## Buses that carry the world (muffled); Master keeps the helmet sounds and the UI.
const WORLD_BUSES := ["Env", "Weapons", "VacHull", "VacGround", "VacSuit", "Skiff", "RadioRx"]
const MUFFLE_MIN_HZ := 320.0           # cut-off at full depth
const DUCK_DB := -6.0                  # world duck at full blast deafness
const RING_HZ := 3900.0
const RING_LOOP := 4.0                 # s; every component completes whole cycles (seamless)
const RATE := 44100
const SPREAD_MAX := 0.35               # spread bonus at full suppression
const SUPP_HOLD := 0.5
const SUPP_FALL := 2.0                 # s from full to zero after the hold

const SCREEN_SHADER := """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float deaf = 0.0;      // blast concussion 0..1
uniform float supp = 0.0;      // suppression 0..1
uniform vec2 ghost = vec2(0.006, 0.002);
uniform float t = 0.0;

vec3 tap(vec2 uv, float lod) {
	return textureLod(screen_tex, clamp(uv, vec2(0.001), vec2(0.999)), lod).rgb;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = SCREEN_PIXEL_SIZE;
	vec2 c = uv - 0.5;
	c.x *= px.y / px.x;
	float edge = smoothstep(0.3, 0.95, length(c));
	float d = clamp(deaf, 0.0, 1.0);
	float s = clamp(supp, 0.0, 1.0) * edge;
	float lod = d * 2.0 + s * 2.6;
	vec2 o = px * (1.0 + lod * 1.5);
	vec3 col = tap(uv, lod) * 0.4 + (tap(uv + vec2(o.x, 0.0), lod) + tap(uv - vec2(o.x, 0.0), lod)
			+ tap(uv + vec2(0.0, o.y), lod) + tap(uv - vec2(0.0, o.y), lod)) * 0.15;
	if (d > 0.001) {
		vec2 g = ghost * d * (0.75 + 0.25 * sin(t * 2.1));
		col = mix(col, tap(uv + g, lod + 0.6), 0.33 * d);
	}
	float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(col, vec3(l), clamp(0.45 * d + 0.75 * s, 0.0, 0.85));
	col *= 1.0 - 0.4 * s * edge;
	COLOR = vec4(col, 1.0);
}
"""

static var _ring_stream: AudioStream
static var _synth_task := -1
static var _synth_mutex := Mutex.new()
static var _synth_out := {}

var suppression := 0.0
var deaf := 0.0
var debug_log: Array = []              # tests: last blasts [ring, thump, muffle, picture]

var _supp_hold := 9.0
var _supp_vis := 0.0
var _supp_feed_t := 0
var _hit_muffle := 0.0
var _deaf_k := 0.0                     # current deafness: overall strength...
var _deaf_rk := 0.0                    # ...the ring's...
var _deaf_mk := 0.0                    # ...the muffle's
var _deaf_T := 1.0
var _deaf_t := 99.0
var _dm := 0.0                         # blast muffle depth now
var _ring_lin := 0.0                   # ring amplitude now (linear, before compensation)
var _ring_from := 0.0                  # re-trigger start levels (fractions of the new peak)
var _dm_from := 0.0
var _duck_from := 0.0
var _vis_k := 0.0
var _vis_T := 1.0
var _vis_t := 99.0
var _ghost := Vector2(0.006, 0.002)
var _pending: Array = []               # [usec, ring, thump, muffle, picture, radius]
var _ring: AudioStreamPlayer
var _ring_pitch := 1.0
var _thumps: Array = []
var _thump_p: Array = []
var _thump_i := 0
var _thump_last := -1
var _master_duck_db := 0.0            # duck on Master (older routing only; the ring makes it up)
var _cutoff := 20000.0
var _lp_on := false
var _lp_first := true                  # the muffle is Master's first effect (safe to pre-boost)
var _duck_db := 0.0
var _layer: CanvasLayer
var _rect: ColorRect
var _mat: ShaderMaterial
var _t := 0.0
var _sway_t := 0.0


static func inst() -> Node:
	if Game.has_meta("feel_fx"):
		var f = Game.get_meta("feel_fx")
		if is_instance_valid(f):
			return f
	var n: Node = load("res://scripts/ui/feel_fx.gd").new()
	n.name = "FeelFx"
	Game.add_child(n)
	Game.set_meta("feel_fx", n)
	return n


## Spread multiplier from suppression (GunFeel.stance_spread): 1 .. 1 + SPREAD_MAX.
static func spread_mult() -> float:
	if not Game.has_meta("feel_fx"):
		return 1.0
	var f = Game.get_meta("feel_fx")
	if not is_instance_valid(f):
		return 1.0
	return 1.0 + SPREAD_MAX * clampf(float(f.suppression), 0.0, 1.0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 100              # after the player resets its camera and the guns add to it
	_ring = AudioStreamPlayer.new()
	_ring.bus = "Master"
	add_child(_ring)
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_thump_p.append(p)
	_thumps = Snd.set_of("feel/thump")
	_build_screen()
	_start_synth()
	if not Game.blast.is_connected(_on_blast):
		Game.blast.connect(_on_blast)


func _exit_tree() -> void:
	if _synth_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_synth_task = -1
		_take_synth()
	_set_bus(false, 20000.0, 0.0)


# =================================================================================================
# Public API
# =================================================================================================

## Adds suppression (saturating toward 1) and restarts the hold.
func suppress(amount: float) -> void:
	if amount <= 0.0:
		return
	var p = Game.player
	if p == null or not is_instance_valid(p) or (p.has_method("is_dead") and p.is_dead()):
		return
	suppression = clampf(suppression + amount * (1.0 - 0.45 * suppression), 0.0, 1.0)
	_supp_hold = 0.0


## Heavy hit taken (damage_ui.gd): the short world muffle, k 0..1 (squared into the depth).
func muffle_hit(k: float) -> void:
	_hit_muffle = maxf(_hit_muffle, clampf(k, 0.0, 1.0))


# =================================================================================================
# Blast deafness
# =================================================================================================

func _on_blast(pos: Vector3, radius: float, _team: String) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var p = Game.player
	if cam == null or p == null or not is_instance_valid(p):
		return
	var ear := cam.global_position
	var d := maxf(ear.distance_to(pos), 0.8)
	var l := maxf(radius, 0.5) / d
	var k := clampf(log(l / 0.3) / log(8.7), 0.0, 1.0)
	var kt := clampf(log(l / 0.12) / log(21.7), 0.0, 1.0)
	if kt <= 0.0:
		return
	var med := _medium(pos, d, radius)          # (ring, thump, muffle)
	if med == Vector3.ZERO:
		return
	var seat := _seat_scale()
	var occl := _occluded(cam, ear, pos)
	var kr := k * med.x * seat * (0.55 if occl else 1.0)
	var km := k * med.z * seat
	var ktt := kt * med.y * (1.0 if seat >= 1.0 else 0.75)
	var kv := k * seat * (0.5 if occl else 1.0)
	_pending.append([Time.get_ticks_usec() + int(d / SOUND_SPEED * 1e6), kr, ktt, km, kv, radius])
	if _pending.size() > 8:
		_pending.pop_front()


## How the blast reaches the listener (sfx.gd route_for): x ring, y thump, z muffle scale.
func _medium(pos: Vector3, d: float, radius: float) -> Vector3:
	var sfx = Game.sfx
	if sfx == null or not is_instance_valid(sfx) or not sfx.has_method("route_for"):
		return Vector3.ONE
	match int(sfx.route_for(pos, null)):
		0:
			return Vector3.ONE                      # through the air
		1, 2:
			return Vector3(0.85, 1.0, 0.45)         # your hull / the ground: through the suit
	if d < radius * 0.6:
		return Vector3(0.8, 0.9, 0.4)               # vacuum, but the blast is on you
	return Vector3.ZERO


## Sitting in something: a cannon / Uçaksavar seat ×0.5, the closed skiff cockpit ×0.35.
func _seat_scale() -> float:
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return 1.0
	var v = p.get("vehicle")
	if v == null or not is_instance_valid(v):
		return 1.0
	return 0.35 if (v as Node).is_in_group("skiff") else 0.5


## Solid rock between the ear and the blast (a blast deep in a tunnel, behind a hill).
func _occluded(cam: Camera3D, ear: Vector3, pos: Vector3) -> bool:
	var w := cam.get_world_3d()
	if w == null:
		return false
	var q := PhysicsRayQueryParameters3D.create(ear, pos, Game.LAYER_TERRAIN)
	var h := w.direct_space_state.intersect_ray(q)
	return not h.is_empty() and (h["position"] as Vector3).distance_to(pos) > 1.5


## The blast's sound arrives: thump, deafness, picture, suppression.
func _land(kr: float, kt: float, km: float, kv: float, radius: float) -> void:
	debug_log.append([kr, kt, km, kv])
	if debug_log.size() > 20:
		debug_log.pop_front()
	if kt > 0.02:
		_thump(kt, radius)
	var kd := maxf(kr, km)
	if kd > 0.1:
		var T := lerpf(1.5, 4.0, kd)
		if kd >= _deaf_level():
			# Re-trigger from where ring / muffle / duck are now (no dip while they ramp up again).
			_ring_from = clampf(_ring_lin / maxf(db_to_linear(_ring_peak_db(kr)), 1e-5), 0.0, 1.0)
			_dm_from = clampf(_dm / maxf(km, 1e-3), 0.0, 1.0)
			_duck_from = clampf(_duck_db / minf(DUCK_DB * km, -1e-3), 0.0, 1.0)
			_deaf_k = kd
			_deaf_rk = kr
			_deaf_mk = km
			_deaf_T = T
			_deaf_t = 0.0
			_start_ring()
		else:
			_deaf_T += 0.25 * kd                     # a smaller blast inside a bigger ring
	if kv > 0.1:
		if kv >= _vis_level():
			_vis_k = kv
			_vis_T = lerpf(0.7, 1.8, kv)
			_vis_t = 0.0
			var a := randf() * TAU
			_ghost = Vector2(cos(a), sin(a) * 0.4) * 0.007
	suppress(0.12 * kt + 0.6 * kd)


func _thump(kt: float, radius: float) -> void:
	if _thumps.is_empty():
		return
	var i := randi() % _thumps.size()
	if i == _thump_last and _thumps.size() > 1:
		i = (i + 1) % _thumps.size()
	_thump_last = i
	var p: AudioStreamPlayer = _thump_p[_thump_i]
	_thump_i = (_thump_i + 1) % _thump_p.size()
	p.stream = _thumps[i]
	p.volume_db = lerpf(-28.0, -2.0, kt)
	# Bigger blasts sit lower.
	p.pitch_scale = randf_range(0.95, 1.05) * lerpf(1.08, 0.9, clampf(radius / 12.0, 0.0, 1.0))
	p.play()


func _start_ring() -> void:
	_poll_synth()
	if _ring_stream == null:
		return
	if not _ring.playing:
		_ring.stream = _ring_stream
		_ring_pitch = randf_range(0.93, 1.07)       # 3.6 - 4.2 kHz
		_ring.pitch_scale = _ring_pitch
		_ring.volume_db = -80.0
		_ring.play(randf() * (RING_LOOP - 0.1))


func _deaf_level() -> float:
	if _deaf_t >= _deaf_T:
		return 0.0
	return _deaf_k * pow(1.0 - _deaf_t / _deaf_T, 1.3)


func _vis_level() -> float:
	if _vis_t >= _vis_T:
		return 0.0
	return _vis_k * pow(1.0 - _vis_t / _vis_T, 1.6)


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	var rd := delta / maxf(Engine.time_scale, 0.01)
	_t += rd
	_poll_synth()
	if not _pending.is_empty():
		var now := Time.get_ticks_usec()
		for i in range(_pending.size() - 1, -1, -1):
			var pd: Array = _pending[i]
			if now >= int(pd[0]):
				_pending.remove_at(i)
				_land(float(pd[1]), float(pd[2]), float(pd[3]), float(pd[4]), float(pd[5]))
	_deaf_t += rd
	_vis_t += rd
	_hit_muffle = maxf(_hit_muffle - rd * 1.4, 0.0)
	var u := clampf(_deaf_t / _deaf_T, 0.0, 1.0)
	var deaf_on := _deaf_t < _deaf_T
	deaf = _deaf_level()
	# Muffle: snaps in, holds 0.1 s, opens over the rest; the duck eases in over 0.25 s.
	_dm = 0.0
	var duck := 0.0
	if deaf_on:
		var uo := clampf((_deaf_t - 0.1) / maxf(_deaf_T - 0.1, 0.1), 0.0, 1.0)
		_dm = _deaf_mk * lerpf(_dm_from, 1.0, clampf(_deaf_t / 0.03, 0.0, 1.0)) * pow(1.0 - uo, 1.3)
		duck = DUCK_DB * _deaf_mk * lerpf(_duck_from, 1.0, clampf(_deaf_t / 0.25, 0.0, 1.0)) * pow(1.0 - uo, 1.3)
	var depth := maxf(_hit_muffle * _hit_muffle, _dm)
	var cutoff := exp(lerpf(log(20000.0), log(MUFFLE_MIN_HZ), clampf(depth, 0.0, 1.0)))
	_set_bus(depth > 0.001, cutoff, duck)
	_update_ring(u, deaf_on)
	_update_suppression(rd)
	_update_screen()
	_tremble(rd)


## Ring level at its peak for ring strength kr (dB, before the filter compensation).
func _ring_peak_db(kr: float) -> float:
	return lerpf(-33.0, -15.0, clampf(kr, 0.0, 1.0))


func _update_ring(u: float, on: bool) -> void:
	if not _ring.playing:
		_ring_lin = 0.0
		return
	var a := 0.0
	if on:
		a = lerpf(_ring_from, 1.0, clampf(_deaf_t / 0.12, 0.0, 1.0)) * pow(1.0 - u, 1.5)
	if a <= 0.0005:
		_ring.stop()
		_ring_lin = 0.0
		return
	_ring.pitch_scale = _ring_pitch * (1.0 - 0.025 * u)
	var lvl := _ring_peak_db(_deaf_rk) + linear_to_db(a)
	_ring_lin = db_to_linear(lvl)
	# Older routing (muffle on Master): pre-boost by what the low-pass and duck take at the ring's
	# frequency. With the world buses Master is clean and nothing is added.
	var comp := 0.0
	if _lp_on and _lp_first:
		comp = clampf(-linear_to_db(maxf(_lp_gain(RING_HZ * _ring.pitch_scale, _cutoff), 1e-4)), 0.0, 46.0)
	_ring.volume_db = lvl + comp - _master_duck_db


func _update_suppression(rd: float) -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p) or (p.has_method("is_dead") and p.is_dead()):
		suppression = maxf(suppression - rd * 2.0, 0.0)
	_supp_hold += rd
	if _supp_hold > SUPP_HOLD:
		suppression = maxf(suppression - rd / SUPP_FALL, 0.0)
	# The picture follows quickly up, a little behind on the way down.
	_supp_vis = lerpf(_supp_vis, suppression, 1.0 - exp(-(10.0 if suppression > _supp_vis else 4.0) * rd))


func _update_screen() -> void:
	var dv := _vis_level()
	var sv := _supp_vis * 0.85
	var on := dv > 0.005 or sv > 0.01
	_rect.visible = on
	if not on:
		return
	_mat.set_shader_parameter("deaf", dv)
	_mat.set_shader_parameter("supp", sv)
	_mat.set_shader_parameter("ghost", _ghost)
	_mat.set_shader_parameter("t", _t)


## A slight aim tremble under suppression, on foot. Added on top of the camera rotation that the
## player resets every frame (this node processes after it: process_priority).
func _tremble(rd: float) -> void:
	if suppression < 0.02 or get_tree().paused:
		return
	var p = Game.player
	if p == null or not is_instance_valid(p) or p.get("vehicle") != null:
		return
	if p.has_method("is_ragdolled") and p.is_ragdolled():
		return
	var cam = p.get("camera")
	if not (cam is Camera3D) or not (cam as Camera3D).current:
		return
	_sway_t += rd
	var a := 0.0032 * pow(suppression, 1.3)
	(cam as Camera3D).rotation += Vector3((sin(_sway_t * 2.3) + 0.6 * sin(_sway_t * 5.1 + 1.3)) * a * 0.6,
			(sin(_sway_t * 1.7 + 0.4) + 0.5 * sin(_sway_t * 4.3)) * a, 0.0)


# =================================================================================================
# The shared muffle: world buses (or Master)
# =================================================================================================

## Drives the muffle low-pass + duck. With the "Env" world bus (sfx.gd / acoustics.gd: world sounds
## in the air) they sit at the end of every world bus (WORLD_BUSES: after the room reverb, so the
## tails dull too) and Master stays clean: the ring, the thump, the hit confirms and the UI pass
## untouched. Without it (an older routing) they sit first on Master and the ring is pre-boosted by
## what they take (_update_ring). Bypassed when idle; added on first use.
func _set_bus(on: bool, cutoff: float, duck_db: float) -> void:
	_cutoff = cutoff if on else 20000.0
	_duck_db = duck_db if on else 0.0
	var world := AudioServer.get_bus_index("Env") >= 0
	if world:
		_drive_bus(0, false, 20000.0, 0.0, true)            # a Master muffle of an older run: off
		for bn: String in WORLD_BUSES:
			var bi := AudioServer.get_bus_index(bn)
			if bi > 0:
				_drive_bus(bi, on, _cutoff, _duck_db, false)
		_lp_on = false
		_master_duck_db = 0.0
	else:
		_lp_first = _drive_bus(0, on, _cutoff, _duck_db, true)
		_lp_on = on
		_master_duck_db = _duck_db


## One bus: finds (or, when needed, adds) its "dmg_muffle" low-pass and "feel_duck" amplify and sets
## them. `front`: the low-pass goes first (Master), else last. Returns true when the low-pass is
## the bus's first effect.
func _drive_bus(bi: int, on: bool, cutoff: float, duck_db: float, front: bool) -> bool:
	var li := _fx_find(bi, MUFFLE_NAME)
	if li < 0:
		if not on:
			return true
		var lp := AudioEffectLowPassFilter.new()
		lp.resource_name = MUFFLE_NAME
		li = 0 if front else AudioServer.get_bus_effect_count(bi)
		AudioServer.add_bus_effect(bi, lp, li)
	var lpx := AudioServer.get_bus_effect(bi, li) as AudioEffectLowPassFilter
	if front and li > 0 and not on and lpx != null:
		# Keep the Master muffle first (re-placed while idle): the ring's pre-boost must meet the
		# filter before anything non-linear another system adds (a compressor / limiter).
		AudioServer.remove_bus_effect(bi, li)
		AudioServer.add_bus_effect(bi, lpx, 0)
		li = 0
	if lpx != null:
		# One RBJ stage (12 dB/oct) at resonance 0.5: _lp_gain models exactly this.
		lpx.db = AudioEffectFilter.FILTER_6DB
		lpx.resonance = 0.5
		lpx.cutoff_hz = cutoff
	if AudioServer.is_bus_effect_enabled(bi, li) != on:
		AudioServer.set_bus_effect_enabled(bi, li, on)
	var want_duck := on and duck_db < -0.05
	var di := _fx_find(bi, DUCK_NAME)
	if di < 0:
		if not want_duck:
			return li == 0
		var amp := AudioEffectAmplify.new()
		amp.resource_name = DUCK_NAME
		di = li + 1
		AudioServer.add_bus_effect(bi, amp, di)
	var ax := AudioServer.get_bus_effect(bi, di) as AudioEffectAmplify
	if ax != null:
		ax.volume_db = duck_db if want_duck else 0.0
	if AudioServer.is_bus_effect_enabled(bi, di) != want_duck:
		AudioServer.set_bus_effect_enabled(bi, di, want_duck)
	return li == 0


## Index of the first effect named `fx_name` on bus `bi`, -1 if none.
func _fx_find(bi: int, fx_name: String) -> int:
	for e in AudioServer.get_bus_effect_count(bi):
		var x := AudioServer.get_bus_effect(bi, e)
		if x != null and x.resource_name == fx_name:
			return e
	return -1


## Magnitude of the Master low-pass at `f` Hz with cut-off `fc`: one RBJ biquad, Q 0.5
## (AudioFilterSW low-pass at FILTER_6DB / resonance 0.5).
func _lp_gain(f: float, fc: float) -> float:
	var fs := AudioServer.get_mix_rate()
	var w0 := TAU * minf(fc, fs * 0.5 - 100.0) / fs
	var cw := cos(w0)
	var alpha := sin(w0)                         # sin(w0) / (2 Q), Q = 0.5
	var b0 := (1.0 - cw) * 0.5
	var a0 := 1.0 + alpha
	var a1 := -2.0 * cw
	var a2 := 1.0 - alpha
	var w := TAU * f / fs
	var num := b0 * (2.0 + 2.0 * cos(w))
	var re := a0 + a1 * cos(w) + a2 * cos(2.0 * w)
	var im := a1 * sin(w) + a2 * sin(2.0 * w)
	return num / maxf(sqrt(re * re + im * im), 1e-9)


# =================================================================================================
# Screen
# =================================================================================================

## A full-screen copy pass under the HUD (layer 3: the HUD, scope and combat overlay stay sharp).
func _build_screen() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 3
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = SCREEN_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_rect.material = _mat
	_rect.visible = false
	_layer.add_child(_rect)


# =================================================================================================
# Synthesis (worker thread, cached for the session)
# =================================================================================================

static func _start_synth() -> void:
	if _synth_task >= 0 or _ring_stream != null:
		return
	_synth_task = WorkerThreadPool.add_task(_build_synth, false, "feel_fx_audio")


static func _build_synth() -> void:
	var out := {"ring": _make_ring()}
	_synth_mutex.lock()
	_synth_out = out
	_synth_mutex.unlock()


static func _poll_synth() -> void:
	if _synth_task >= 0 and WorkerThreadPool.is_task_completed(_synth_task):
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_synth_task = -1
		_take_synth()


static func _take_synth() -> void:
	_synth_mutex.lock()
	if _synth_out.has("ring"):
		_ring_stream = _synth_out["ring"]
	_synth_mutex.unlock()


## The tinnitus loop (RING_LOOP s, 44.1 kHz mono, seamless): partials at RING_HZ and RING_HZ + 2.75
## (soft beating), a faint octave below, a slow ±0.12 % drift (closed-form phase, so the loop closes
## exactly), a 0.5 / 1.25 Hz amplitude wobble and a little narrow-band "air" around the tone (a
## resonator on noise; its loop seam is cross-faded).
static func _make_ring() -> AudioStreamWAV:
	var n := int(RING_LOOP * RATE)
	var m := int(0.25 * RATE)                    # cross-fade length for the noise seam
	var buf := PackedFloat32Array()
	buf.resize(n + m)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	# Narrow-band air: two-pole resonator at RING_HZ (bandwidth ~70 Hz) on white noise.
	var air := PackedFloat32Array()
	air.resize(n + m)
	var r := 0.995
	var cw := cos(TAU * RING_HZ / RATE)
	var y1 := 0.0
	var y2 := 0.0
	var e2 := 0.0
	for i in n + m:
		var y := 2.0 * r * cw * y1 - r * r * y2 + (rng.randf() * 2.0 - 1.0)
		y2 = y1
		y1 = y
		air[i] = y
		e2 += y * y
	var air_k := 0.07 / maxf(sqrt(e2 / float(n + m)), 1e-6)
	var f1 := RING_HZ
	var f2 := RING_HZ + 2.75
	var f3 := RING_HZ * 0.5
	var dk := 0.0012 / (TAU * 0.25)              # drift depth / drift angular rate
	for i in n + m:
		var t := float(i) / RATE
		var dc := cos(TAU * 0.25 * t)
		var p1 := TAU * f1 * (t - dk * dc)
		var p2 := TAU * f2 * (t - dk * dc)
		var p3 := TAU * f3 * (t - dk * dc)
		var wob := 1.0 + 0.1 * sin(TAU * 0.5 * t + 0.7) + 0.05 * sin(TAU * 1.25 * t)
		buf[i] = (sin(p1) + 0.35 * sin(p2) + 0.06 * sin(p3) + air[i] * air_k) * wob
	# Close the loop: the tones repeat exactly, so only the air changes across the cross-fade.
	for i in m:
		var x := float(i) / float(m)
		buf[i] = buf[i] * x + buf[n + i] * (1.0 - x)
	var pk := 0.0001
	for i in n:
		pk = maxf(pk, absf(buf[i]))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(clampf(buf[i] / pk * 0.85, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w
