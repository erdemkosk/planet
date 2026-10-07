extends Node3D
## The drill's heat and dig feel (matkap ısınması / juice, 2026-10-06): sounds, steam and the material
## tick ladder of the Kazı Aracı (scripts/player/terrain_tool.gd drives it; the heat logic is
## scripts/items/drill_heat.gd). Its own 2D players, routed like the drill hum (Env bus in air, the
## suit-muffled VacSuit bus in vacuum).
##   loops     the coil whine (pitch rises with heat), a crackle near the top, the steam hiss of a
##             lockout
##   cues      the vent window opening (a soft double beep), a marker pass (a faint tick)
##   vents     perfect: a big hiss + whoosh + a bright chime (SÜPER KAZI); good: a shorter hiss;
##             jam: a puff and a dry double cough + clunk; overheat: a wind-down + hiss + alarm;
##             back online: two beeps
##   bite      the beam's bite into the ground, layered by depth / hardness (soft dirt near the
##             surface, harder lower rock deeper or on a rock planet), faster with power
##   ladder    credit(m³) accumulates the material dug; every Balance.DRILL_POP_T s of digging a
##             "+N" (signal pop) with a tick climbing a pentatonic ladder (resets after a pause)
##   steam     world-space puffs at the nozzle / side vents (top_level particles)

const Snd := preload("res://scripts/audio/snd_lib.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Balance := preload("res://scripts/war/balance.gd")

signal pop(text: String, col: Color)

const WHINE_VOL := 0.3
const CRACKLE_VOL := 0.38
const HISS_VOL := 0.34
const BITE_DB := -19.0
const TICK_DB := -21.0
const LADDER := [0, 2, 4, 7, 9, 12, 14, 16]    # semitones (pentatonic), the top two alternate
const POP_COL := Color(1.0, 0.72, 0.32)

static var _cache := {}

var _whine: AudioStreamPlayer
var _crackle: AudioStreamPlayer
var _hiss: AudioStreamPlayer
var _pool: Array = []
var _loop_cur := {}                 # player -> current linear volume
var _steam: GPUParticles3D
var _steam_pm: ParticleProcessMaterial
var _puff: GPUParticles3D
var _puff_pm: ParticleProcessMaterial
var _bite_t := 0.0
var _acc := 0.0                     # m³ credited since the last pop
var _pop_t := 0.0
var _ladder_i := 0
var _ladder_idle := 9.0
var _cough_t := -1.0
var _t := 0.0


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_whine = _loop_player("shuttle/whine")
	_crackle = _loop_player("shuttle/reentry_crackle")
	_hiss = _loop_player("shuttle/hiss_loop")
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_build_steam()


static func _one(rel: String) -> AudioStream:
	if not _cache.has(rel):
		_cache[rel] = Snd.one(rel)
	return _cache[rel]


static func _set_of(rel: String) -> Array:
	var key := "set:" + rel
	if not _cache.has(key):
		_cache[key] = Snd.set_of(rel)
	return _cache[key]


func _loop_player(rel: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = Snd.loop(rel)
	p.volume_db = -80.0
	add_child(p)
	_loop_cur[p] = 0.0
	return p


## The bus the drill's sounds take now: through the room in air, muffled by the suit in vacuum.
static func bus() -> String:
	var air := 1.0
	if Game.sfx != null and is_instance_valid(Game.sfx) and Game.sfx.get("listener_air") != null:
		air = float(Game.sfx.listener_air)
	var b := "Env" if air > 0.05 else "VacSuit"
	return b if AudioServer.get_bus_index(b) >= 0 else "Master"


## A one-shot: a stream, or a set name ("foley/hiss": a random variant). cut > 0: fades out and stops
## after cut s (long recordings used for their start).
func play(what, db := 0.0, pitch := 1.0, cut := 0.0) -> void:
	var s: AudioStream = null
	if what is AudioStream:
		s = what
	elif what is String:
		var arr := _set_of(what)
		s = arr[randi() % arr.size()] if not arr.is_empty() else _one(what)
	if s == null:
		return
	var p: AudioStreamPlayer = null
	for c in _pool:
		if not (c as AudioStreamPlayer).playing:
			p = c
			break
	if p == null:
		p = _pool[0]
	p.stream = s
	p.bus = bus()
	p.volume_db = db + randf_range(-0.8, 0.8)
	p.pitch_scale = pitch * randf_range(0.98, 1.02)
	p.play()
	if cut > 0.0:
		var tw := p.create_tween()
		tw.tween_interval(cut * 0.6)
		tw.tween_property(p, "volume_db", -60.0, cut * 0.4)
		tw.tween_callback(p.stop)


## Every frame: the loops from the heat state. s: heat (0..1), working, locked, lock_kind, lock_k
## (0..1 of the lockout left), boost (0..1 of SÜPER KAZI left), equipped.
func drive(delta: float, s: Dictionary) -> void:
	_t += delta
	var h := float(s.get("heat", 0.0))
	var working := bool(s.get("working", false))
	var locked := bool(s.get("locked", false))
	var lk := float(s.get("lock_k", 0.0))
	var boost := float(s.get("boost", 0.0))
	var eq := bool(s.get("equipped", true))
	var whine := 0.0
	var wp := lerpf(0.62, 1.55, h)
	if eq and not locked:
		whine = WHINE_VOL * smoothstep(0.12, 0.95, h) * (1.0 if working else 0.45)
		if boost > 0.0:
			wp *= 1.06 + 0.02 * sin(_t * 30.0)
			whine = maxf(whine, WHINE_VOL * 0.35 * (1.0 if working else 0.4))
	elif eq and locked:
		whine = WHINE_VOL * 0.5 * lk * lk            # winding down
		wp = lerpf(0.35, 0.9, lk)
	var crackle := CRACKLE_VOL * smoothstep(0.74, 1.0, h) * (1.0 if eq and not locked else 0.0)
	if locked and int(s.get("lock_kind", 0)) == 2:
		crackle = CRACKLE_VOL * 0.6 * lk
	var hiss := HISS_VOL * (0.4 + 0.6 * lk) if locked else 0.0
	_drive_loop(_whine, whine, wp, delta)
	_drive_loop(_crackle, crackle, 0.9 + 0.25 * h, delta)
	_drive_loop(_hiss, hiss, 0.85 + 0.3 * lk, delta)
	_steam.emitting = locked and eq
	_steam.amount_ratio = clampf(0.35 + 0.65 * lk, 0.0, 1.0)
	_ladder_idle += delta
	if _cough_t >= 0.0:
		_cough_t -= delta
		if _cough_t < 0.0:
			play("foley/dry", -9.0, 0.62)
			play("shuttle/puff", -14.0, 1.3)


func _drive_loop(p: AudioStreamPlayer, vol: float, pitch: float, delta: float) -> void:
	var cur := float(_loop_cur.get(p, 0.0))
	cur = lerpf(cur, vol, 1.0 - exp(-7.0 * delta))
	_loop_cur[p] = cur
	if cur < 0.003:
		if p.playing:
			p.stop()
		return
	if not p.playing:
		p.bus = bus()
		p.play(randf() * maxf(p.stream.get_length() - 1.0, 0.0) if p.stream != null else 0.0)
	elif Engine.get_process_frames() % 30 == 0:
		p.bus = bus()
	p.volume_db = linear_to_db(cur)
	p.pitch_scale = lerpf(p.pitch_scale, clampf(pitch, 0.3, 3.0), 1.0 - exp(-8.0 * delta))


## Stops every loop at once (the drill put away / freed).
func silence() -> void:
	for p in _loop_cur:
		_loop_cur[p] = 0.0
		(p as AudioStreamPlayer).stop()
	_steam.emitting = false


# --- Cues --------------------------------------------------------------------------------------

func window_cue() -> void:
	play("foley/beep", -11.0, 1.55)
	get_tree().create_timer(0.11).timeout.connect(play.bind("foley/beep", -12.0, 1.95))


func sweep_cue() -> void:
	play("foley/tick", -23.0, 1.5)


func early_cue() -> void:
	play("foley/tick", -16.0, 0.85)


## A vent: kind 1 perfect, 2 good, 3 jam (DrillHeat). at / dir / up: the nozzle (world), its aim, up.
func vent_fx(kind: int, at: Vector3, dir: Vector3, up: Vector3) -> void:
	match kind:
		1:
			play("foley/hiss", -5.0, 1.05)
			play("whoosh/puff", -8.0, 0.8)
			play(_one("shuttle/boost_whoosh"), -9.0, 1.2, 1.4)
			play("foley/shield_up", -12.0, 1.25)
			if Game.sfx:
				Game.sfx.play("ding", -9.0, 1.6)
			_burst(at, dir, up, 1.0, Color(0.85, 0.97, 1.0, 0.55))
		2:
			play("foley/hiss", -9.0, 1.18)
			play("whoosh/puff", -13.0, 1.0)
			_burst(at, dir, up, 0.55, Color(0.9, 0.92, 0.95, 0.45))
		3:
			play("shuttle/puff", -7.0, 0.75)
			play("foley/dry", -7.0, 0.7)
			play("foley/clunk", -11.0, 0.8)
			_cough_t = 0.24
			_burst(at, up * 0.6 + dir * 0.4, up, 0.8, Color(0.55, 0.55, 0.56, 0.5))


func overheat_fx(at: Vector3, dir: Vector3, up: Vector3) -> void:
	play(_one("shuttle/shutdown"), -8.0, 1.25, 1.6)
	play("foley/hiss", -6.0, 0.8)
	play("shuttle/puff", -8.0, 0.65)
	if Game.sfx:
		Game.sfx.play("error", -10.0, 0.8)
	_burst(at, up * 0.5 + dir * 0.5, up, 1.0, Color(0.7, 0.7, 0.72, 0.55))


func unlock_fx() -> void:
	play("foley/beep", -13.0, 1.2)
	get_tree().create_timer(0.12).timeout.connect(play.bind("foley/beep", -13.0, 1.5))
	play("mach/servo", -18.0, 1.4)


func super_end_fx() -> void:
	play("foley/tick", -15.0, 0.75)


## Mk III auto-collect: soil from a crater nearby.
func collect_fx(amount: float) -> void:
	play("foley/inject", -14.0, 1.1)
	pop.emit("+%d" % int(roundf(amount)), Color(1.0, 0.85, 0.45))


## The beam bites (called every physics frame the drill digs). depth_k: 0 surface .. 1 deep;
## hard: 0 soil .. 1 rock planet; power 0..1.
func bite(delta: float, depth_k: float, hard: float, power: float, boosted: bool) -> void:
	_bite_t -= delta
	if _bite_t > 0.0:
		return
	var rocky := clampf(depth_k * 0.7 + hard * 0.6, 0.0, 1.0)
	_bite_t = lerpf(0.3, 0.16, power) * randf_range(0.8, 1.2) * (0.8 if boosted else 1.0)
	var pitch := lerpf(1.1, 0.78, depth_k) * randf_range(0.92, 1.08)
	if randf() < rocky:
		play("bimp/rock", BITE_DB - 1.0 + rocky * 2.0, pitch)
	else:
		play("bimp/dirt", BITE_DB, pitch * 1.05)
	if rocky > 0.5 and randf() < 0.25:
		play("bimp/crack", BITE_DB - 4.0, randf_range(0.9, 1.2))


## Material dug (m³, after every multiplier): pops "+N" every DRILL_POP_T s with a ladder tick.
func credit(amount: float, delta: float) -> void:
	_acc += maxf(amount, 0.0)
	_pop_t += delta
	if _pop_t < Balance.DRILL_POP_T or _acc < 1.0:
		return
	_pop_t = 0.0
	var n := int(floorf(_acc))
	_acc -= float(n)
	if _ladder_idle > 1.2:
		_ladder_i = 0
	_ladder_idle = 0.0
	var step: int = LADDER[_ladder_i] if _ladder_i < LADDER.size() else LADDER[LADDER.size() - 2 + (_ladder_i % 2)]
	_ladder_i += 1
	play("ui/blip", TICK_DB, pow(2.0, float(step) / 12.0))
	pop.emit("+%d" % n, POP_COL)


# --- Steam --------------------------------------------------------------------------------------

## Where the steam leaves (each frame): the nozzle (world), its aim and up.
func steam_at(at: Vector3, dir: Vector3, up: Vector3) -> void:
	var side := dir.cross(up).normalized()
	if side.length_squared() < 0.5:
		side = Vector3.RIGHT
	_steam.global_transform = Transform3D(DigFx._basis_y((up * 0.8 - side * 0.35 + dir * 0.2).normalized()), at - dir * 0.12)


func _burst(at: Vector3, dir: Vector3, up: Vector3, size: float, col: Color) -> void:
	_puff.global_transform = Transform3D(DigFx._basis_y((dir * 0.7 + up * 0.5).normalized()), at)
	_puff_pm.color = col
	_puff_pm.scale_min = 0.6 * size
	_puff_pm.scale_max = 1.4 * size
	_puff_pm.initial_velocity_min = 1.0 + size
	_puff_pm.initial_velocity_max = 2.0 + size * 2.0
	_puff.amount_ratio = clampf(size, 0.3, 1.0)
	_puff.restart()
	_puff.emitting = true


func _build_steam() -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = DigFx.soft_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var q := QuadMesh.new()
	q.size = Vector2(0.22, 0.22)
	q.material = mat
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.0))
	fade.set_color(1, Color(1, 1, 1, 0.0))
	fade.add_point(0.12, Color(1, 1, 1, 0.8))
	var ft := GradientTexture1D.new()
	ft.gradient = fade
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.3))
	grow.add_point(Vector2(1, 1.0))
	var gt := CurveTexture.new()
	gt.curve = grow

	_steam = GPUParticles3D.new()
	_steam.amount = 26
	_steam.lifetime = 0.9
	_steam.local_coords = false
	_steam.emitting = false
	_steam.draw_pass_1 = q
	_steam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_steam.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	_steam_pm = ParticleProcessMaterial.new()
	_steam_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_steam_pm.emission_sphere_radius = 0.03
	_steam_pm.direction = Vector3(0, 1, 0)
	_steam_pm.spread = 22.0
	_steam_pm.initial_velocity_min = 0.6
	_steam_pm.initial_velocity_max = 1.3
	_steam_pm.damping_min = 0.8
	_steam_pm.damping_max = 1.6
	_steam_pm.gravity = Vector3.ZERO
	_steam_pm.scale_min = 0.5
	_steam_pm.scale_max = 1.2
	_steam_pm.scale_curve = gt
	_steam_pm.color = Color(0.82, 0.84, 0.86, 0.4)
	_steam_pm.color_ramp = ft
	_steam_pm.angle_min = -180.0
	_steam_pm.angle_max = 180.0
	_steam.process_material = _steam_pm
	add_child(_steam)

	_puff = GPUParticles3D.new()
	_puff.amount = 30
	_puff.lifetime = 0.8
	_puff.one_shot = true
	_puff.explosiveness = 0.9
	_puff.local_coords = false
	_puff.emitting = false
	_puff.draw_pass_1 = q
	_puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_puff.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	_puff_pm = ParticleProcessMaterial.new()
	_puff_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_puff_pm.emission_sphere_radius = 0.05
	_puff_pm.direction = Vector3(0, 1, 0)
	_puff_pm.spread = 40.0
	_puff_pm.initial_velocity_min = 2.0
	_puff_pm.initial_velocity_max = 4.0
	_puff_pm.damping_min = 3.0
	_puff_pm.damping_max = 5.0
	_puff_pm.gravity = Vector3.ZERO
	_puff_pm.scale_curve = gt
	_puff_pm.color_ramp = ft
	_puff_pm.angle_min = -180.0
	_puff_pm.angle_max = 180.0
	_puff.process_material = _puff_pm
	add_child(_puff)
