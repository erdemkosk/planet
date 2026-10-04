extends Node
## Hit feel for every player weapon (rifle, shotgun, explosions): confirm sounds per result
## (body tick + synthesized thwack / weak-point ping / deep kill thump), hit-stop (a 35-60 ms
## Engine.time_scale dip on kills, restored in real time), damage-scaled camera shake
## (player.add_trauma), and the combat overlay (scripts/ui/combat_hud.gd): hit / kill markers,
## popups and damage numbers. Targets are damageables (Game.DAMAGEABLE: hp_max, take_damage).
## One instance lives under the Game autoload: HitFeel.inst().

const CombatHud := preload("res://scripts/ui/combat_hud.gd")
const RifleFx := preload("res://scripts/items/rifle_fx.gd")
const WeaponAudio := preload("res://scripts/items/weapon_audio.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

const STOP_GAP := 0.22              # min real seconds between two hit-stops
var hud                              # CombatHud (CanvasLayer)
var debug_log: Array = []            # tests: last results
var hit_stops := 0

var _stop_until := 0                 # usec (real time)
var _stop_active := false
var _last_stop := 0
var _snd := {}
var _players: Array = []
var _pi := 0
var _last_snd := {}
var _streak := 0
var _streak_t := 0.0
var _synth_task := -1
var _synth_ready := {}
var _synth_mutex := Mutex.new()


static func inst() -> Node:
	if Game.has_meta("hit_feel"):
		var h = Game.get_meta("hit_feel")
		if is_instance_valid(h):
			return h
	var n: Node = load("res://scripts/items/hit_feel.gd").new()
	n.name = "HitFeel"
	Game.add_child(n)
	Game.set_meta("hit_feel", n)
	return n


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	hud = CombatHud.new()
	add_child(hud)
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	# Recorded confirm sounds (Sonniss: Gamemaster bullet impacts, Gorification), played near their
	# natural pitch instead of the old 1.5-2.4x pitched Kenney ticks / bells.
	_snd["tick"] = Snd.set_of("hit/tick")
	_snd["kill"] = Snd.set_of("hit/kill")
	_snd["weak"] = Snd.set_of("hit/weak")
	_snd["armor"] = Snd.set_of("hit/armor")
	_snd["plate"] = Snd.set_of("hit/plate")
	_snd["bell"] = Snd.set_of("hit/bell")
	_synth_task = WorkerThreadPool.add_task(_build_synth, false, "hit_feel_audio")


func _exit_tree() -> void:
	if _stop_active:
		Engine.time_scale = 1.0
		_stop_active = false
	if _synth_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_synth_task = -1


func _process(delta: float) -> void:
	if _stop_active and Time.get_ticks_usec() >= _stop_until:
		Engine.time_scale = 1.0
		_stop_active = false
	var rd := delta / maxf(Engine.time_scale, 0.01)
	_streak_t = maxf(_streak_t - rd, 0.0)
	if _streak_t <= 0.0:
		_streak = 0


# =================================================================================================
# Public API
# =================================================================================================

## A player weapon hit damageable `c` (group "damageable"); `r` is its take_damage result
## ({"dmg", "killed"}, optional "weak" / "headshot"), `dmg` the damage sent.
## opts: "big" (0..1: shake / hit-stop weight of this weapon), "quiet" (no confirm sound),
## "number" (false = no damage number). Returns the class: "kill", "weak", "head", "hit".
func target_hit(c, r: Dictionary, dmg: float, point: Vector3, opts := {}) -> String:
	var killed: bool = r.get("killed", false)
	var weak: bool = r.get("weak", false)
	var head: bool = r.get("headshot", false)
	var armored := false
	var cls := "hit"
	if killed:
		cls = "kill"
	elif weak:
		cls = "weak"
	elif armored:
		cls = "armor"
	elif head:
		cls = "head"
	if r.get("stunned", false) and not killed:
		cls = "stun"
	var big: float = float(opts.get("big", 0.0))
	# Damage really dealt (weak point ×2.5, head ×2, armor) as reported by take_hit.
	var real_dmg: float = float(r.get("dmg", dmg))
	var mh: float = 100.0
	if c != null and is_instance_valid(c) and c.get("hp_max") != null:
		mh = float(c.get("hp_max"))
	hud.marker(cls, clampf(real_dmg / maxf(mh, 1.0) * 1.5 + big * 0.5, 0.0, 1.0))
	if bool(opts.get("number", true)):
		hud.number(point, real_dmg, cls)
	if weak:
		hud.popup("ZAYIF NOKTA ×2.5", Color(1.0, 0.82, 0.25))
	elif armored and not killed:
		hud.popup("ZIRH", Color(0.62, 0.72, 0.85))
	if not bool(opts.get("quiet", false)):
		_confirm(cls, big)
	if killed:
		_streak += 1
		_streak_t = 1.6
		if _streak >= 2:
			hud.popup("×%d" % _streak, Color(1.0, 0.4, 0.3))
		var k := clampf(mh / 160.0, 0.0, 1.0)
		# Hit-stop only on kills (rapid fire only on big ones, so swarm clearing does not stutter).
		if big >= 0.18 or mh >= 80.0:
			hit_stop(0.035 + 0.025 * k, 0.12)
		shake(0.12 + 0.25 * k + big * 0.2)
	elif weak and (big >= 0.3 or real_dmg >= 50.0):
		# ...and a shorter one on a heavy weak-point hit.
		hit_stop(0.02 + 0.012 * big, 0.3)
		shake(0.06 + big * 0.1)
	elif big > 0.55:
		shake(0.05 + big * 0.08)
	debug_log.append(cls)
	if debug_log.size() > 40:
		debug_log.pop_front()
	return cls


## Time dip: Engine.time_scale = `scale` for `sec` of real time (throttled; never stacks).
func hit_stop(sec: float, scale := 0.1) -> void:
	var now := Time.get_ticks_usec()
	if _stop_active or now - _last_stop < int(STOP_GAP * 1e6):
		return
	if get_tree().paused or absf(Engine.time_scale - 1.0) > 0.001:
		return
	_last_stop = now
	_stop_until = now + int(clampf(sec, 0.0, 0.08) * 1e6)
	_stop_active = true
	hit_stops += 1
	Engine.time_scale = clampf(scale, 0.02, 1.0)


## Camera trauma on the player (0..1, squared falloff in the player's shake).
func shake(amount: float) -> void:
	var p = Game.player
	if p != null and p.has_method("add_trauma"):
		p.add_trauma(amount)


## Confirm sounds per class: body hits a crisp tick over a meaty thwack, weak points a bright ping,
## armor a metallic clank, kills a deep thump + punch + bell (rapid fire: thinner layers).
func _confirm(cls: String, big := 0.3) -> void:
	var now := Time.get_ticks_msec()
	if now - int(_last_snd.get(cls, -1000)) < 45:
		return
	_last_snd[cls] = now
	_poll_synth()
	var light := big < 0.18
	match cls:
		"kill":
			_play("kill_thump", -4.0 if not light else -8.0, randf_range(0.95, 1.05))
			_play("kill", -8.0, randf_range(0.95, 1.05))
			_play("bell", -24.0, randf_range(0.97, 1.03))
		"weak":
			_play("weak_ping", -10.0, randf_range(0.97, 1.05))
			_play("weak", -14.0, randf_range(1.0, 1.08))
			_play("hit_thwack", -11.0, 1.0)
		"armor":
			_play("armor", -10.0, randf_range(0.95, 1.08))
			_play("plate", -16.0, randf_range(0.95, 1.05))
		"stun":
			_play("tick", -12.0, 1.0)
		_:
			_play("tick", -13.0, randf_range(0.95, 1.06))
			if now - int(_last_snd.get("thwack", -1000)) >= 70:
				_last_snd["thwack"] = now
				_play("hit_thwack", -10.0 if not light else -16.0, randf_range(0.94, 1.06))


## Synthesized confirm layers (scripts/items/weapon_audio.gd), built on a worker thread.
func _poll_synth() -> void:
	if _synth_task >= 0 and WorkerThreadPool.is_task_completed(_synth_task):
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_synth_task = -1
		_synth_mutex.lock()
		for k in _synth_ready:
			_snd[k] = [_synth_ready[k]]
		_synth_mutex.unlock()


func _build_synth() -> void:
	var gen := WeaponAudio.new()
	var out := {}
	for n in WeaponAudio.HIT_NAMES:
		out[n] = gen.make(n)
	_synth_mutex.lock()
	_synth_ready = out
	_synth_mutex.unlock()


func _play(name: String, vol: float, pitch: float) -> void:
	var arr: Array = _snd.get(name, [])
	if arr.is_empty():
		return
	var p: AudioStreamPlayer = _players[_pi]
	_pi = (_pi + 1) % _players.size()
	p.stream = arr[randi() % arr.size()]
	p.volume_db = vol
	p.pitch_scale = pitch
	p.play()
