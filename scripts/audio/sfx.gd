extends Node
## Game audio (Game.sfx). Recorded sounds: the Sonniss GDC bundle recordings in
## assets/audio/sonniss (scripts/audio/snd_lib.gd) plus the Kenney UI / impact packs.
##   play(name, db, pitch)          2D one-shot (recorded variant sets get a small pitch / volume spread)
##   play_at(name, world, db, pitch) positional one-shot
##   pick(name) -> AudioStream      one variant of a set (the pause menu plays UI sounds itself)
##   set_loop(name, volume, pitch)  loops driven each frame: wind, the drill hum, the jetpack roar
##
## Medium: the planets have thin air near the surface (bodies.gd atmo_height), so sounds carry
## there normally; in the vacuum between the planets they do not. route_for() picks how a source
## reaches the listener: through the air, muffled through your own suit / vessel, as a dull thud
## through the ground you stand on, or not at all. Every AudioStreamPlayer3D in the tree is routed
## automatically (node_added hook); 2D one-shots follow the listener's medium.
##
## Room: in the air, world sounds go through the "Env" bus (ENV_BUS: 3D players otherwise on
## Master, non-UI 2D one-shots and footsteps, the drill / jetpack loops), whose reverb and slap-back
## echo the child `acoustics` (scripts/audio/acoustics.gd) sizes continuously from rays around the
## listener; it drives the guns' "Weapons" bus reverb the same way and plays the underground room
## tone. The child `radio` (scripts/audio/radio_fx.gd) is the rival bots' radio chatter.
##
## Handling foley (section at the end): the named sets FOLEY_SETS (cloth, gear, grip, tick, clunk,
## tap, ... and the melee hits) that the weapon handling (scripts/items/handling.gd), the view model
## and the melee (scripts/player/melee.gd) play through play() / play_later(name, delay, db, pitch);
## and the player's own gear on the footstep clock: a kit rattle per step (sprint loud, walk faint,
## crouch near silent), a jump rustle, a landing clank scaled by the fall speed, slide in / out.

const Snd := preload("res://scripts/audio/snd_lib.gd")
const Acoustics := preload("res://scripts/audio/acoustics.gd")
const RadioFx := preload("res://scripts/audio/radio_fx.gd")
const ENV_BUS := "Env"      # world sounds in the air: through the measured room (acoustics.gd)

const ROUTE_AIR := 0        # normal
const ROUTE_HULL := 1       # through your own vessel / suit: muffled rumble
const ROUTE_GROUND := 2     # through the ground you stand on: dull low thud
const ROUTE_NONE := 3       # vacuum, no contact: silent
const GROUND_RANGE := 70.0  # m: farther ground-borne sounds are lost (45 at R 30: the core is ~57 m down now)
const ROUTE_BUS := ["", "VacHull", "VacGround", "VacMute"]
## UI sounds: always heard (they are in your helmet).
const UI_NAMES := {"click": true, "select": true, "open": true, "close": true, "error": true, "toggle": true,
		"switch": true, "craft": true, "ding": true, "blip": true}
## World events without a position: in vacuum only felt through the ground.
const WORLD_NAMES := {"explosion": true, "explosion_crunch": true}
## Recorded sets keep their character: callers' pitch requests are clamped to these ranges.
const PITCH_RANGE := {"explosion": Vector2(0.8, 1.15), "explosion_crunch": Vector2(0.78, 1.15),
		"whoosh": Vector2(0.85, 1.25), "servo": Vector2(0.85, 1.2), "mine": Vector2(0.85, 1.2),
		"impact": Vector2(0.75, 1.2), "impact_light": Vector2(0.75, 1.35), "blip": Vector2(0.9, 1.15),
		"land_rock": Vector2(0.85, 1.05)}

var _loops := {}      # name -> {"player": AudioStreamPlayer, "vol": float, "cur": float, "pitch": float}
var _pool: Array = []
var _pool3d: Array = []
var _pool3d_i := 0
var _rng := RandomNumberGenerator.new()
var _variants := {}   # name -> Array[AudioStream] (one is picked at random per play)
var _dig_tick := 0.0

# Listener state (updated every frame in _update_listener).
var listener_pos := Vector3.ZERO
var listener_air := 1.0
var listener_ground := false
var _lis_owner: Array = []    # nodes whose sounds are "own": the player, the vehicle you are in
var _p3d := {}                # instance id -> AudioStreamPlayer3D (every 3D player in the tree)
var _wlp: AudioEffectLowPassFilter   # vacuum muffle on the Weapons bus
var acoustics                 # scripts/audio/acoustics.gd: the listener's room (reverb, echo, ambience)
var radio                     # scripts/audio/radio_fx.gd: the rival bots' radio chatter


func _ready() -> void:
	_rng.seed = 99
	_setup_buses()
	acoustics = Acoustics.new()   # creates the Env bus before anything is routed to it
	acoustics.name = "Acoustics"
	add_child(acoustics)
	radio = RadioFx.new()
	radio.name = "Radio"
	add_child(radio)
	_add_loop_stream("wind", Snd.loop("amb/wind_gusty"))
	_add_loop_stream("dig", Snd.loop("ship/dig_beam"))
	_add_loop_stream("jet", Snd.loop("ship/jetpack"))
	_load_variants()
	_remove_master_limiters()
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = -1.0
	AudioServer.add_bus_effect(0, lim)
	for i in 20:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	for i in 12:
		var p3 := AudioStreamPlayer3D.new()
		p3.unit_size = 12.0
		p3.max_distance = 300.0
		p3.max_db = 3.0
		add_child(p3)
		_pool3d.append(p3)
	get_tree().node_added.connect(_on_node_added)
	call_deferred("_scan_3d")


## Plays a one-shot sound (2D). "step" picks the footstep set of the planet underfoot.
func play(name: String, volume_db := 0.0, pitch := 1.0) -> void:
	if name == "step":
		var surf := _step_surface()
		if pitch < 0.9:
			surf = "land_rock"       # landings / heavy thuds
			volume_db += 2.0
		name = surf
		pitch = clampf(pitch, 0.88, 1.12)
	if PITCH_RANGE.has(name):
		var r: Vector2 = PITCH_RANGE[name]
		pitch = clampf(pitch, r.x, r.y)
	var stream := pick(name)
	if stream == null:
		return
	if not UI_NAMES.has(name):
		pitch *= _rng.randf_range(0.97, 1.03)
		volume_db += _rng.randf_range(-1.2, 1.2)
	var bus := _bus_2d(name)
	if bus == "VacMute":
		return
	for p in _pool:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = pitch
			p.bus = bus
			p.play()
			return


## Positional one-shot at world point `at` (explosions, impacts). Routed through the medium rules.
func play_at(name: String, at: Vector3, volume_db := 0.0, pitch := 1.0, unit := 12.0) -> void:
	if PITCH_RANGE.has(name):
		var r: Vector2 = PITCH_RANGE[name]
		pitch = clampf(pitch, r.x, r.y)
	var stream := pick(name)
	if stream == null:
		return
	var route := route_for(at, null)
	if route == ROUTE_NONE:
		return
	var p: AudioStreamPlayer3D = null
	for k in _pool3d.size():
		var c: AudioStreamPlayer3D = _pool3d[(_pool3d_i + k) % _pool3d.size()]
		if not c.playing:
			p = c
			break
	if p == null:
		p = _pool3d[_pool3d_i]
	_pool3d_i = (_pool3d_i + 1) % _pool3d.size()
	p.stream = stream
	p.unit_size = unit
	p.max_distance = maxf(300.0, unit * 5.0)
	p.volume_db = volume_db + _rng.randf_range(-1.0, 1.0)
	p.pitch_scale = pitch * _rng.randf_range(0.97, 1.03)
	p.global_position = at
	_apply_route(p, route)
	p.play()


## One random variant of a sound set (null if unknown).
func pick(name: String) -> AudioStream:
	var arr: Array = _variants.get(name, [])
	if arr.is_empty():
		return null
	return arr[_rng.randi() % arr.size()]


## Sets the target loudness (0..1) and pitch of a looping sound; changes are smoothed.
func set_loop(name: String, volume: float, pitch := 1.0) -> void:
	var l: Dictionary = _loops[name]
	l["vol"] = clampf(volume, 0.0, 1.5)
	l["pitch"] = clampf(pitch, 0.3, 3.0)


func _process(delta: float) -> void:
	_update_listener()
	_drive(delta)
	_foley(delta)                 # handling foley: delayed one-shots, the player's gear (section at the end)
	_route_3d()
	var k := 1.0 - exp(-8.0 * delta)
	for name in _loops:
		var l: Dictionary = _loops[name]
		var p: AudioStreamPlayer = l["player"]
		l["cur"] = lerpf(l["cur"], l["vol"], k)
		p.pitch_scale = lerpf(p.pitch_scale, l["pitch"], k)
		p.volume_db = linear_to_db(maxf(l["cur"], 0.0001))
		p.stream_paused = l["cur"] < 0.002


## Maps game state to loop levels.
func _drive(delta: float) -> void:
	var c = Game.controlled
	if c == null or not is_instance_valid(c):
		return
	var pos: Vector3 = c.global_position
	var speed: float = c.hud_velocity().length() if c.has_method("hud_velocity") else 0.0
	var air := open_air_at(pos)
	var vac := listener_air < 0.05
	set_loop("wind", air * (0.18 + clampf(speed / 60.0, 0.0, 1.0) * 0.8), 0.85 + clampf(speed / 150.0, 0.0, 0.5))
	for n: String in ["dig", "jet"]:
		(_loops[n]["player"] as AudioStreamPlayer).bus = "VacSuit" if vac else ENV_BUS
	_weapons_vacuum(vac, delta)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.vehicle == null and pl.tool != null:
		var t = pl.tool
		# The hum follows the emitter's spin-up (terrain_tool._power).
		var pw: float = float(t.get("_power")) if t.get("_power") != null else 1.0
		set_loop("dig", 0.7 * lerpf(0.4, 1.0, pw) if t.using else 0.0, (0.9 + t.mode * 0.08) * lerpf(0.8, 1.0, pw))
		var jp: float = pl.jet_effect()
		set_loop("jet", 0.34 * lerpf(0.3, 1.0, jp) if pl.jetting else 0.0, lerpf(0.88, 1.05, jp))
		# Rock chunks while digging (throttled; a dozen recorded variants).
		_dig_tick -= delta
		if t.using and _dig_tick <= 0.0:
			_dig_tick = _rng.randf_range(0.4, 0.7)
			play("mine", -15.0, _rng.randf_range(0.92, 1.1))
	else:
		set_loop("dig", 0.0)
		set_loop("jet", 0.0)


# ------------------------------------------------------------------------------------------
# Medium: air, vacuum, contact
# ------------------------------------------------------------------------------------------

## 0..1: how well the air at world point `p` carries sound (0 = vacuum between the planets).
func air_at(p: Vector3) -> float:
	return open_air_at(p)


## Outdoor air: the thin air near a planet's surface, 0 in space.
func open_air_at(p: Vector3) -> float:
	return smoothstep(0.0, 0.3, Game.atmosphere_factor(p))


## How a sound at world point `src`, played by `node` (or null), reaches the listener.
func route_for(src: Vector3, node: Node = null) -> int:
	var a := air_at(src)
	if a > 0.05 and listener_air > 0.05:
		return ROUTE_AIR
	if node != null and _is_own(node):
		return ROUTE_AIR if a > 0.05 else ROUTE_HULL
	if listener_ground and src.distance_to(listener_pos) < GROUND_RANGE:
		return ROUTE_GROUND
	return ROUTE_NONE


## The same as a gain (0..1) and a low-pass cut-off (Hz), for systems that mix their own players.
func vacuum_gain(src: Vector3, node: Node = null) -> Vector2:
	match route_for(src, node):
		ROUTE_HULL:
			return Vector2(0.55, 450.0)
		ROUTE_GROUND:
			var d := clampf(src.distance_to(listener_pos) / GROUND_RANGE, 0.0, 1.0)
			return Vector2(0.5 * (1.0 - d), 160.0)
		ROUTE_NONE:
			return Vector2(0.0, 20.0)
	return Vector2(1.0, 20000.0)


## Routes a 3D player right now (call after play() for zero latency; the global hook also does it).
func route_player(p: AudioStreamPlayer3D) -> void:
	if p != null and p.is_inside_tree():
		_apply_route(p, route_for(p.global_position, p))


func _is_own(node: Node) -> bool:
	for o in _lis_owner:
		if is_instance_valid(o) and (o == node or (o as Node).is_ancestor_of(node)):
			return true
	return false


func _update_listener() -> void:
	var cam := get_viewport().get_camera_3d()
	var pl = Game.player
	if cam != null:
		listener_pos = cam.global_position
	elif pl != null and is_instance_valid(pl):
		listener_pos = pl.global_position
	listener_air = air_at(listener_pos)
	listener_ground = false
	_lis_owner.clear()
	if pl != null and is_instance_valid(pl):
		_lis_owner.append(pl)
		var v = pl.get("vehicle")
		if v != null and is_instance_valid(v):
			_lis_owner.append(v)
		elif pl.has_method("is_on_floor"):
			listener_ground = pl.is_on_floor()
	var c = Game.controlled
	if c != null and is_instance_valid(c) and not _lis_owner.has(c):
		_lis_owner.append(c)


## 2D bus for a one-shot by name, from the listener's medium (in the air: the Env room reverb).
func _bus_2d(name: String) -> String:
	if UI_NAMES.has(name):
		return "Master"
	if listener_air > 0.05:
		return ENV_BUS
	if WORLD_NAMES.has(name):
		return "VacGround" if listener_ground else "VacMute"
	return "VacSuit"


func _on_node_added(n: Node) -> void:
	if n is AudioStreamPlayer3D:
		_p3d[n.get_instance_id()] = n
		var ap := n as AudioStreamPlayer3D
		# In vacuum a new Master player starts muted until it is routed at the end of this frame.
		if listener_air < 0.05 and str(ap.bus) == "Master":
			ap.set_meta("snd_bus0", "Master")
			ap.set_meta("snd_prov", true)
			ap.bus = "VacMute"
		call_deferred("_route_new", n)


func _route_new(n) -> void:
	if not is_instance_valid(n) or not (n as Node).is_inside_tree():
		return
	var ap := n as AudioStreamPlayer3D
	if ap.has_meta("snd_prov"):
		ap.remove_meta("snd_prov")
		if str(ap.bus) != "VacMute" and ap.has_meta("snd_bus0"):
			ap.remove_meta("snd_bus0")
	ap.set_meta("snd_t", Time.get_ticks_msec() + 150)
	_apply_route(ap, route_for(ap.global_position, ap))


func _scan_3d() -> void:
	for n in get_tree().root.find_children("*", "AudioStreamPlayer3D", true, false):
		_p3d[n.get_instance_id()] = n


## Every playing 3D player gets the bus of its route (re-checked every 0.15 s).
func _route_3d() -> void:
	var now := Time.get_ticks_msec()
	var dead: Array = []
	for id in _p3d:
		var p = _p3d[id]
		if not is_instance_valid(p):
			dead.append(id)
			continue
		var ap := p as AudioStreamPlayer3D
		if not ap.playing or not ap.is_inside_tree():
			continue
		if now < int(ap.get_meta("snd_t", 0)):
			continue
		ap.set_meta("snd_t", now + 150)
		_apply_route(ap, route_for(ap.global_position, ap))
	for id in dead:
		_p3d.erase(id)


func _apply_route(p: AudioStreamPlayer3D, route: int) -> void:
	var cur: String = str(p.bus)
	var orig: String = str(p.get_meta("snd_bus0")) if p.has_meta("snd_bus0") else cur
	# Players on a bus of their own apply the vacuum rule themselves; only Master players are routed
	# (in the air through the Env bus: the room reverb of acoustics.gd).
	if orig != "Master" and orig != "" and orig != ENV_BUS:
		return
	if route == ROUTE_GROUND and p.has_meta("snd_air_only"):
		route = ROUTE_NONE
	var want: String = ENV_BUS if route == ROUTE_AIR else ROUTE_BUS[route]
	if cur == want:
		return
	if route != ROUTE_AIR and not p.has_meta("snd_bus0"):
		p.set_meta("snd_bus0", cur)
	p.bus = want
	if route == ROUTE_AIR and p.has_meta("snd_bus0"):
		p.remove_meta("snd_bus0")


## Your own gun in vacuum: a muffled suit-borne thump instead of a crack (low-pass on the Weapons bus).
func _weapons_vacuum(vac: bool, delta: float) -> void:
	var wi := AudioServer.get_bus_index("Weapons")
	if wi < 0:
		return
	var idx := -1
	for e in AudioServer.get_bus_effect_count(wi):
		var fx := AudioServer.get_bus_effect(wi, e)
		if fx is AudioEffectLowPassFilter and fx.resource_name == "snd_vacuum_lp":
			_wlp = fx as AudioEffectLowPassFilter
			idx = e
			break
	if idx < 0:
		_wlp = AudioEffectLowPassFilter.new()
		_wlp.resource_name = "snd_vacuum_lp"
		_wlp.cutoff_hz = 20000.0
		_wlp.db = AudioEffectFilter.FILTER_24DB
		AudioServer.add_bus_effect(wi, _wlp)
		idx = AudioServer.get_bus_effect_count(wi) - 1
		AudioServer.set_bus_effect_enabled(wi, idx, false)
	var want := 320.0 if vac else 20000.0
	_wlp.cutoff_hz = exp(lerpf(log(maxf(_wlp.cutoff_hz, 20.0)), log(want), 1.0 - exp(-10.0 * delta)))
	AudioServer.set_bus_effect_enabled(wi, idx, vac or _wlp.cutoff_hz < 18000.0)


func _setup_buses() -> void:
	_ensure_bus("VacHull", -5.0, 450.0)
	_ensure_bus("VacGround", -6.0, 160.0)
	_ensure_bus("VacSuit", -3.0, 1100.0)
	_ensure_bus("VacMute", -80.0, 0.0)
	AudioServer.set_bus_mute(AudioServer.get_bus_index("VacMute"), true)


func _ensure_bus(name: String, volume_db: float, lp_hz: float) -> void:
	if AudioServer.get_bus_index(name) >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, name)
	AudioServer.set_bus_send(i, "Master")
	AudioServer.set_bus_volume_db(i, volume_db)
	if lp_hz > 0.0:
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = lp_hz
		lp.db = AudioEffectFilter.FILTER_24DB
		AudioServer.add_bus_effect(i, lp)


## Drops the master limiter of a previous scene (reload) before a new one is added last.
func _remove_master_limiters() -> void:
	for i in range(AudioServer.get_bus_effect_count(0) - 1, -1, -1):
		if AudioServer.get_bus_effect(0, i) is AudioEffectHardLimiter:
			AudioServer.remove_bus_effect(0, i)


# ------------------------------------------------------------------------------------------
# Streams
# ------------------------------------------------------------------------------------------

func _ogg(path: String) -> AudioStream:
	return load("res://assets/audio/%s.ogg" % path) as AudioStream


func _add_loop_stream(name: String, stream: AudioStream, bus := "Master") -> void:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = -80.0
	p.bus = bus
	add_child(p)
	p.play()
	p.stream_paused = true
	_loops[name] = {"player": p, "vol": 0.0, "cur": 0.0, "pitch": 1.0}


func _set_variants(name: String, paths: Array) -> void:
	var arr: Array = []
	for p in paths:
		var s: AudioStream = _ogg(p)
		if s != null:
			arr.append(s)
	_variants[name] = arr


func _load_variants() -> void:
	var f5 := func(prefix: String) -> Array:
		var a: Array = []
		for i in 5:
			a.append("%s_%03d" % [prefix, i])
		return a
	# Footsteps per surface (level-matched recordings).
	for s: String in ["rock", "dirt", "sand"]:
		_variants["step_" + s] = Snd.set_of("foot/step_" + s)
	_variants["land_rock"] = Snd.set_of("foot/land_rock")
	# Impacts: Kenney sets plus recorded thuds / metal.
	_set_variants("impact", f5.call("impact/impactMetal_heavy") + f5.call("impact/impactPlate_heavy"))
	(_variants["impact"] as Array).append_array(Snd.set_of("impact/thud") + Snd.set_of("impact/metal_heavy"))
	_set_variants("impact_light", f5.call("impact/impactMetal_light"))
	_variants["mine"] = Snd.set_of("dig/mine")
	_variants["explosion"] = Snd.set_of("expl/explosion")
	_variants["explosion_crunch"] = Snd.set_of("expl/debris")
	_variants["servo"] = Snd.set_of("mach/servo")
	_variants["whoosh"] = Snd.set_of("whoosh/whoosh") + Snd.set_of("whoosh/puff")
	_variants["blip"] = Snd.set_of("ui/blip")
	_set_variants("ding", ["ui/glass_001", "ui/glass_002", "ui/glass_003"])
	_set_variants("craft", ["ui/confirmation_001", "ui/confirmation_002"])
	_set_variants("click", ["ui/click_001", "ui/click_002", "ui/click_003"])
	_set_variants("select", ["ui/select_001", "ui/select_002", "ui/select_003"])
	_set_variants("open", ["ui/open_001", "ui/open_002"])
	_set_variants("close", ["ui/close_001", "ui/close_002"])
	_set_variants("error", ["ui/error_001", "ui/error_002"])
	_set_variants("toggle", ["ui/toggle_001", "ui/toggle_002"])
	_set_variants("switch", ["ui/switch_001", "ui/switch_002", "ui/switch_003"])
	_load_foley_variants()


## Footstep set of the planet underfoot (bodies.gd "step": "step_dirt" at home, "step_rock" on the
## rival planet).
func _step_surface() -> String:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl):
		return "step_dirt"
	var b = Game.body_at(pl.global_position)
	if b != null and b.get("cfg") is Dictionary:
		var s := str((b.cfg as Dictionary).get("step", "step_dirt"))
		if _variants.has(s):
			return s
	return "step_dirt"


# ------------------------------------------------------------------------------------------
# Handling foley: named sets, delayed one-shots, the player's own gear on the footstep clock
# ------------------------------------------------------------------------------------------

const Handling := preload("res://scripts/items/handling.gd")
## Named handling sets (assets/audio/sonniss/...): processed Sonniss recordings (gun handling,
## cartridge clinks, soldier footsteps, Gorification, Gamemaster, Mechanical Wave, lever switches)
## layered with synthesized fabric. Dropping better recordings in under the same file names
## (e.g. foley/cloth_01..) replaces a set without code changes.
const FOLEY_SETS := {
	"cloth": "foley/cloth", "cloth_long": "foley/cloth_long", "gear": "foley/gear", "grip": "foley/grip",
	"tick": "foley/tick", "clunk": "foley/clunk", "tap": "foley/tap", "rattle": "foley/rattle",
	"gear_land": "foley/land", "gear_jump": "foley/jump", "slide_in": "foley/slide", "settle": "foley/settle",
	"draw": "foley/draw", "holster": "foley/holster", "swing": "foley/swing",
	"melee_flesh": "melee/flesh", "melee_dirt": "melee/dirt", "melee_metal": "melee/metal",
}

var _later: Array = []            # delayed one-shots: [seconds left, name, dB, pitch]
var _gear_on := false
var _gear_half := -1
var _gear_ground := true
var _gear_air := 0.0
var _gear_fall := 0.0
var _gear_slide := false
var _gear_crouch := false
var _gear_cloth := false


## Plays `name` (play()) after `delay` seconds: foley timed to an animation.
func play_later(name: String, delay: float, volume_db := 0.0, pitch := 1.0) -> void:
	if delay <= 0.0:
		play(name, volume_db, pitch)
	elif _later.size() < 32:
		_later.append([delay, name, volume_db, pitch])


func _load_foley_variants() -> void:
	for n: String in FOLEY_SETS:
		_variants[n] = Snd.set_of(FOLEY_SETS[n])


func _foley(delta: float) -> void:
	if not _later.is_empty():
		for i in range(_later.size() - 1, -1, -1):
			var e: Array = _later[i]
			e[0] = float(e[0]) - delta
			if float(e[0]) <= 0.0:
				_later.remove_at(i)
				play(str(e[1]), float(e[2]), float(e[3]))
	_gear(delta)


## The player's own kit: a rattle on every footstep of the body's gait (the clock of player.gd
## _footsteps), a rustle on the jump take-off, a clank on landing (scaled by the fall speed), slide
## in / out, a cloth shift on crouch / stand. Louder with a heavier item in hand.
func _gear(delta: float) -> void:
	var pl = Game.player
	var ok: bool = pl != null and is_instance_valid(pl) and pl.vehicle == null and not pl.is_ragdolled() \
			and not pl.is_dead() and pl.get("waiting_ground") != true and pl.get("zero_g") != true
	if not ok:
		_gear_on = false
		return
	var on_floor: bool = pl.is_on_floor()
	var up: Vector3 = pl.global_transform.basis.y
	var vel: Vector3 = pl.velocity
	var v_up := vel.dot(up)
	var hs := (vel - up * v_up).length()
	var sliding: bool = pl.get("sliding") == true
	var crouched: bool = pl.get("crouching") == true
	if not _gear_on:
		# (Re)started (spawn, out of a vehicle / ragdoll): no events from stale state.
		_gear_on = true
		_gear_ground = on_floor
		_gear_slide = sliding
		_gear_crouch = crouched
		_gear_half = -1
		_gear_air = 0.0
		_gear_fall = 0.0
		return
	var it = pl.items[pl.current_item] if pl.current_item < pl.items.size() else null
	var w := float(Handling.spec(it)["weight"])
	# Steps.
	if on_floor and hs > 1.0 and not sliding and pl.astronaut != null:
		var half := floori(float(pl.astronaut._phase) * 2.0)
		if half != _gear_half:
			if _gear_half != -1:
				_gear_step(hs, clampf(float(pl.get("_sprint_k")), 0.0, 1.0), clampf(float(pl.get("crouch_k")), 0.0, 1.0), w)
			_gear_half = half
	# Jump take-off / landing.
	if on_floor:
		if not _gear_ground and (_gear_air > 0.25 or _gear_fall > 2.5):
			var k := clampf((_gear_fall - 2.0) / 8.0, 0.0, 1.0)
			play("gear_land", lerpf(-24.0, -9.0, k) + w * 2.0, lerpf(1.04, 0.9, k))
			if k > 0.3:
				play_later("rattle", 0.06, lerpf(-24.0, -14.0, k), 0.95)
		_gear_air = 0.0
		_gear_fall = 0.0
	else:
		if _gear_ground and v_up > 1.2 and Input.is_action_pressed("jump"):
			play("gear_jump", -17.0 + w * 2.0, _rng.randf_range(0.96, 1.04))
		_gear_air += delta
		_gear_fall = maxf(_gear_fall, -v_up)
	_gear_ground = on_floor
	# Slide in / out; crouch / stand.
	if sliding != _gear_slide:
		_gear_slide = sliding
		if sliding:
			play("slide_in", -13.0 + w * 2.0, 1.0)
		else:
			play("settle", -18.0 + w * 2.0, 1.0)
	elif crouched != _gear_crouch and not sliding:
		play("cloth", -24.0, 0.94 if crouched else 1.04)
	_gear_crouch = crouched


## One step's kit rattle: faint walking, much louder sprinting (plus a cloth swish every other
## sprint step), near silent crouched.
func _gear_step(hs: float, sprint: float, crouch: float, w: float) -> void:
	var run := maxf(sprint, clampf((hs - 3.6) / 2.6, 0.0, 1.0))
	var db := lerpf(-28.0, -16.0, run) + (w - 0.5) * 5.0 - crouch * 9.0
	if db < -39.0:
		return
	play("rattle", db, _rng.randf_range(0.95, 1.05) * lerpf(1.04, 0.94, w))
	if run > 0.5:
		_gear_cloth = not _gear_cloth
		if _gear_cloth:
			play("cloth", lerpf(-30.0, -22.0, run), _rng.randf_range(0.92, 1.06))
