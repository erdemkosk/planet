extends Node
## Hit feel for every player weapon (rifle, shotgun, explosions): confirm sounds per result
## (body tick + synthesized thwack / weak-point ping / deep kill thump), hit-stop (a 35-60 ms
## Engine.time_scale dip on kills, restored in real time), damage-scaled camera shake
## (player.add_trauma), and the combat overlay (scripts/ui/combat_hud.gd): hit / kill markers,
## popups and damage numbers (Esc › Ayarlar › Hasar sayıları, off by default). Targets are
## damageables (Game.DAMAGEABLE: hp_max, take_damage).
## Head hits (r["headshot"], set by gun_feel.gd) get a sharp ding and a gold marker; kills a bigger
## marker, the kill thump, a short warm screen-edge pulse and a kill-feed line top right
## ("Sen ➜ Rakip — Kazıcı (Keskin, kafadan)"; feed() is public for other kill sources).
## Near misses: near_miss(point, dir, speed) whizzes / snaps a bullet past the listener (rifle_fx
## calls it for other shooters' simulated bullets); hitscan shots of other teams announced through
## Game.shot_fired(from, dir, team) are checked here too, and where such a shot strikes within
## IMPACT_R of the listener counts as a near impact (near_impact(point), one ray per close shot).
## Both feed the suppression meter (scripts/ui/feel_fx.gd). Silent in vacuum (sfx.gd routing).
## Every enemy shot (Game.shot_fired of another team) also gets a recorded distant report with a rolling
## tail (weap/far) at its muzzle, arriving at the speed of sound (_far_report): the bots' fire carries.
##
## Structures and cores. A hit on an ENEMY structure (group "war_structure": cannon, Uçaksavar,
## Delici Top, Silahlık, skiff) is not a body hit: target_hit hands it to structure_hit, which plays
## a heavy recorded "tank" clang (hit/struct_*: Gamemaster metal impact over an industrial lever's
## low hull ring), shows a steel-blue bracket marker and an in-place hp readout ("TOP · %62") above
## the crosshair; a kill a big clang (hit/struct_kill_*), "YIKILDI" and a kill-feed line. Own-team
## structures (friendly fire) get nothing. The enemy core (group "war_core", buried: shells, the
## buster, torpedoes, the drill) confirms from Game.core_damaged: a deep resonant crystalline
## hum-hit (hit/core_*), a violet diamond marker and "ÇEKİRDEK · 280/450" (drill ticks throttled).
## Training dummies (group "training_dummy") count as characters. Multiplayer: a client's bullet
## hits arrive here with the predicted claim result; a client's own blasts (Explosion damage runs on
## the host only) are confirmed here from the blast's falloff (_client_blast); core hp arrives synced
## (Core.net_set_hp emits core_damaged), so each hit confirms once.
## One instance lives under the Game autoload: HitFeel.inst().

const CombatHud := preload("res://scripts/ui/combat_hud.gd")
const WeaponAudio := preload("res://scripts/items/weapon_audio.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const Settings := preload("res://scripts/save/settings.gd")
const FeelFx := preload("res://scripts/ui/feel_fx.gd")

const STOP_GAP := 0.22              # min real seconds between two hit-stops
## 2026-10-06 tok ("vuruşlar ... çok daha tok olsun"): every confirmed body hit gives the view a tiny
## punch away from the target (player._punch: rad, by the hit's weight; it settles on the player's own
## ~0.25 s spring) on top of the marker's short hold (combat_hud.gd MARK_HOLD). No time change: the
## Engine.time_scale hit-stop on kills stays single player only (in multiplayer it slowed the whole
## host simulation for both players).
const MICRO_PUNCH := 0.0035         # rad at a light hit...
const MICRO_PUNCH_BIG := 0.007      # ...more at weight 1 (kills, heavy guns)
const NEAR_R := 2.6                 # m: a shot passing the listener this close whizzes
const NEAR_GAP := 0.07              # s between two near-miss sounds
const IMPACT_R := 4.0               # m: an enemy round striking this close suppresses
## Enemy gunfire by distance (weapon-feel pass, 2026-10-05: the bots' fire has to sound dangerous).
## The shooter's own 3D report fades with distance, so every enemy shot also gets the recorded distant
## report + rolling tail (weap/far) at its muzzle, arriving at the speed of sound: quiet under the
## report up close, the main sound at mid range, a far rumble out to FAR_MAX.
const FAR_GAP := 0.07                # s between two distant-report layers
const FAR_MAX := 600.0               # m
const SOUND_SPEED := 343.0
const STRUCT_COL := Color(0.55, 0.76, 1.0)       # steel blue
const CORE_COL := Color(0.72, 0.52, 1.0)         # violet (core.gd HOME_HOT family)
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
var _near: Array = []                # pooled AudioStreamPlayer3D for whizz / snap
var _near_i := 0
var _near_t := 0
var _pending: Array = []             # delayed near misses [usec, point, speed]
var _last_pick := {}                 # sound set -> last variant index (no immediate repeats)
var _struct_snd_t := 0               # msec of the last structure clang
var _killed_structs := {}            # instance id -> msec (one "YIKILDI" per structure)
var _core_hp := {}                   # core instance id -> last known hp
var _core_snd_t := 0
var _core_acc := 0.0                 # core damage since the last confirm sound (drill ticks)
var _supp_t := 0                     # msec of the last near-miss suppression feed
var _far: Array = []                 # pooled AudioStreamPlayer3D for the distant reports
var _far_i := 0
var _far_t := 0                      # msec of the last distant-report layer
var _far_pending: Array = []         # [usec, position, volume_db] waiting for the sound to arrive


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
	# Structure / core confirms (Sonniss, layered and processed: see the file header).
	_snd["struct"] = Snd.set_of("hit/struct")
	_snd["struct_light"] = Snd.set_of("hit/struct_light")
	_snd["struct_kill"] = Snd.set_of("hit/struct_kill")
	_snd["core"] = Snd.set_of("hit/core")
	# Near misses and distant enemy fire (weapon-feel pass): a recorded bullet flyby (Gamemaster) and a
	# supersonic crack (the first ms of a close 5.56 report, high-passed) replace the synthesized whizz /
	# snap when imported; weap/far = a distant .30 cal / AKM report with a rolling tail.
	_snd["flyby"] = Snd.set_of("bimp/flyby")
	_snd["crack"] = Snd.set_of("bimp/crack")
	_snd["far"] = Snd.set_of("weap/far")
	for i in 4:
		var p3 := AudioStreamPlayer3D.new()
		p3.unit_size = 3.0
		p3.max_distance = 30.0
		p3.max_db = 4.0
		add_child(p3)
		_near.append(p3)
	for i in 3:
		var pf := AudioStreamPlayer3D.new()
		pf.unit_size = 60.0
		pf.max_distance = FAR_MAX + 100.0
		pf.max_db = 0.0
		pf.attenuation_filter_cutoff_hz = 9000.0
		pf.attenuation_filter_db = -12.0
		add_child(pf)
		_far.append(pf)
	_synth_task = WorkerThreadPool.add_task(_build_synth, false, "hit_feel_audio")
	if not Game.shot_fired.is_connected(_on_shot_fired):
		Game.shot_fired.connect(_on_shot_fired)
	if not Game.core_damaged.is_connected(_on_core_damaged):
		Game.core_damaged.connect(_on_core_damaged)
	if not Game.blast.is_connected(_client_blast):
		Game.blast.connect(_client_blast)
	FeelFx.inst()


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
	if not _far_pending.is_empty():
		var now_f := Time.get_ticks_usec()
		for i in range(_far_pending.size() - 1, -1, -1):
			var fp: Array = _far_pending[i]
			if now_f >= int(fp[0]):
				_far_pending.remove_at(i)
				_far_play(fp[1], float(fp[2]))
	if not _pending.is_empty():
		var now := Time.get_ticks_usec()
		for i in range(_pending.size() - 1, -1, -1):
			var pd: Array = _pending[i]
			if now >= int(pd[0]):
				_pending.remove_at(i)
				_whizz(pd[1], float(pd[2]))
	if Engine.get_process_frames() % 30 == 0:
		_seed_cores()


# =================================================================================================
# Public API
# =================================================================================================

## A player weapon hit damageable `c` (group "damageable"); `r` is its take_damage result
## ({"dmg", "killed"}, optional "weak" / "headshot"), `dmg` the damage sent.
## opts: "big" (0..1: shake / hit-stop weight of this weapon), "quiet" (no confirm sound),
## "number" (false = no damage number). Returns the class: "kill", "weak", "head", "hit".
## A structure (group "war_structure", not a training dummy) goes to structure_hit instead.
func target_hit(c, r: Dictionary, dmg: float, point: Vector3, opts := {}) -> String:
	if c != null and is_instance_valid(c) and (c as Node).is_in_group("war_structure") \
			and not (c as Node).is_in_group("training_dummy"):
		return structure_hit(c, r, dmg, point, opts)
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
	var mark_w := clampf(real_dmg / maxf(mh, 1.0) * 1.5 + big * 0.5, 0.0, 1.0)
	hud.marker(cls, mark_w + (0.25 if head else 0.0))
	_micro_punch(mark_w + (0.3 if killed else 0.0))        # (2026-10-06 tok: the hit lands in the view too)
	if bool(opts.get("number", true)) and Settings.damage_numbers:
		hud.number(point, real_dmg, cls)
	if weak:
		hud.popup("ZAYIF NOKTA ×2.5", Color(1.0, 0.82, 0.25))
	elif armored and not killed:
		hud.popup("ZIRH", Color(0.62, 0.72, 0.85))
	if not bool(opts.get("quiet", false)):
		_confirm(cls, big)
		if killed and head:
			_play("head_ding", -9.0, randf_range(0.98, 1.04))
	if killed:
		_streak += 1
		_streak_t = 1.6
		if _streak >= 2:
			hud.popup("×%d" % _streak, Color(1.0, 0.4, 0.3))
		hud.kill_pulse(1.0 if head else 0.7)
		var wn := str(opts.get("weapon", ""))
		var detail := wn
		if head:
			detail = (wn + ", kafadan") if wn != "" else "kafadan"
		feed("Sen", display_name(c), detail, true)
		if head:
			hud.popup("KAFADAN", Color(1.0, 0.85, 0.35))
		var k := clampf(mh / 160.0, 0.0, 1.0)
		# (2026-10-07: the kill hit-stop, time_scale 0.12 for ~56 ms, froze 4-7 frames on every kill: the
		# user's "ölünce kare kare". Only a barely-there dip on a big blow now; the shake carries the weight.)
		if big >= 0.6:
			hit_stop(0.02, 0.5)
		shake(0.12 + 0.25 * k + big * 0.2)
	elif weak and (big >= 0.3 or real_dmg >= 50.0):
		# ...a heavy weak-point hit: shake only (no time dip).
		shake(0.06 + big * 0.1)
	elif big > 0.55:
		shake(0.05 + big * 0.08)
	debug_log.append(cls)
	if debug_log.size() > 40:
		debug_log.pop_front()
	return cls


## A confirmed hit's tiny view punch (MICRO_PUNCH .. MICRO_PUNCH_BIG by weight w 0..1): mostly up, a
## little sideways and roll; the player's _punch spring settles it. Local view only (no time change).
func _micro_punch(w: float) -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p) or not ("_punch" in p):
		return
	var a := lerpf(MICRO_PUNCH, MICRO_PUNCH_BIG, clampf(w, 0.0, 1.0))
	p._punch += Vector3(randf_range(0.2, 1.0), randf_range(-0.8, 0.8), randf_range(-0.6, 0.6)) * a


## Time dip: Engine.time_scale = `scale` for `sec` of real time (throttled; never stacks). Single player
## only (2026-10-06): in multiplayer the host's time scale slowed the shared simulation for both players.
func hit_stop(sec: float, scale := 0.1) -> void:
	if Net.active:
		return
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


# =================================================================================================
# Structures and cores
# =================================================================================================

## A player weapon hit structure `c` (group "war_structure"); `r` its take_damage result (or a
## client's predicted claim). Own-team structures: nothing. Returns "structure", "structure_kill"
## or "" (friendly / already destroyed).
func structure_hit(c, r: Dictionary, dmg: float, _point: Vector3, opts := {}) -> String:
	if Game.team_of(c) == _my_team():
		return ""
	var id: int = (c as Object).get_instance_id()
	var now := Time.get_ticks_msec()
	if _killed_structs.has(id) and now - int(_killed_structs[id]) < 8000:
		return ""
	var killed: bool = r.get("killed", false)
	var real_dmg: float = float(r.get("dmg", dmg))
	var big: float = float(opts.get("big", 0.0))
	var mh: float = maxf(float(c.get("hp_max")) if c.get("hp_max") != null else 100.0, 1.0)
	# A client's claim has not lowered the local hp yet (the host's sync will).
	var hp_now: float = float(c.get("hp")) if c.get("hp") != null else 0.0
	if Net.is_client():
		hp_now -= real_dmg
	hp_now = clampf(hp_now, 0.0, mh)
	if hp_now <= 0.0:
		killed = true
	var w := clampf(real_dmg / mh * 4.0 + big * 0.35, 0.2, 1.0)
	hud.struct_marker("structure", w, killed)
	var label := _struct_label(c)
	if killed:
		_killed_structs[id] = now
		hud.struct_info("%s · YIKILDI" % _tr_upper(label), STRUCT_COL)
		hud.popup("YIKILDI", Color(0.7, 0.85, 1.0))
		hud.kill_pulse(0.55)
		feed("Sen", "Rakip — %s" % label, str(opts.get("weapon", "")), true)
		_struct_confirm(true, big)
		shake(0.18 + big * 0.2)
		debug_log.append("structure_kill")
	else:
		hud.struct_info("%s · %%%d" % [_tr_upper(label), int(ceilf(hp_now / mh * 100.0))], STRUCT_COL)
		if not bool(opts.get("quiet", false)):
			_struct_confirm(false, big)
		debug_log.append("structure")
	if debug_log.size() > 40:
		debug_log.pop_front()
	return "structure_kill" if killed else "structure"


## Structure confirm: the heavy clang with its hull ring; inside an autofire string a short clang
## (hit/struct_light, no ring to pile up), throttled to 90 ms; a kill the big clang over the deep
## kill thump.
func _struct_confirm(killed: bool, big: float) -> void:
	var now := Time.get_ticks_msec()
	_poll_synth()
	if killed:
		_struct_snd_t = now
		_play("struct_kill", -4.0, randf_range(0.96, 1.03))
		_play("kill_thump", -11.0, randf_range(0.9, 0.98))
		return
	if now - _struct_snd_t < 90:
		return
	var rapid := now - _struct_snd_t < 220 and big < 0.3
	_struct_snd_t = now
	if rapid:
		_play("struct_light", -14.0, randf_range(0.95, 1.07))
		return
	_play("struct", lerpf(-11.0, -7.0, clampf(big, 0.0, 1.0)), randf_range(0.93, 1.06))
	if big >= 0.45:
		_play("armor", -17.0, randf_range(0.85, 0.95))


## An enemy core lost hp (Game.core_damaged: shells, the buster, torpedoes, a drill; on a client the
## host's synced hp). Our own core never confirms. Drill ticks collect into one hum every 0.42 s.
func _on_core_damaged(body: Node3D, hp: float) -> void:
	var core: Node = null
	for c in get_tree().get_nodes_in_group("war_core"):
		if c.get("body") == body:
			core = c
			break
	if core == null:
		return
	var id := core.get_instance_id()
	var last: float = float(_core_hp.get(id, hp))
	_core_hp[id] = hp
	if str(core.get("team")) == _my_team():
		return
	var d := last - hp
	if d <= 0.01:
		return
	_core_acc += d
	var mh: float = maxf(float(core.get("hp_max")), 1.0)
	var now := Time.get_ticks_msec()
	var dead := hp <= 0.0 or bool(core.get("destroyed"))
	var heavy := d >= 15.0
	hud.struct_info("ÇEKİRDEK · %d/%d" % [int(ceilf(hp)), int(mh)], CORE_COL)
	if not heavy and not dead and now - _core_snd_t < 420:
		return
	var w := clampf(_core_acc / 60.0 + (0.3 if heavy else 0.0), 0.2, 1.0)
	_core_acc = 0.0
	_core_snd_t = now
	hud.struct_marker("core", w, dead)
	if dead:
		hud.popup("ÇEKİRDEK YIKILDI", Color(0.82, 0.68, 1.0))
		feed("Sen", "Rakip — Çekirdek", "", true)
		_play("core", -4.0, 0.9)
		_play("struct_kill", -9.0, 0.82)
		return
	_play("core", -7.0 if heavy else -14.0, randf_range(0.96, 1.04) * (1.0 if heavy else 1.06))
	if heavy:
		hud.popup("ÇEKİRDEK İSABET", Color(0.82, 0.68, 1.0))
		shake(0.08)


## Multiplayer client: Explosion damage runs on the host only, so the client's own blasts confirm
## their enemy structures here from the same falloff explosion.gd uses (the host's sync sets the hp).
func _client_blast(pos: Vector3, radius: float, _team: String) -> void:
	if not Net.is_client():
		return
	var e := _explosion_at(pos)
	if e == null or not bool(e.get("player_owned")):
		return
	var dmg0: float = float(e.get("damage")) if e.get("damage") != null else 0.0
	var first := true
	for s in get_tree().get_nodes_in_group("war_structure"):
		if not (s is Node3D) or not s.has_method("take_damage") or s.is_in_group("training_dummy"):
			continue
		if (s.has_method("is_dead") and s.is_dead()) or Game.team_of(s) == _my_team():
			continue
		var c: Vector3 = (s as Node3D).global_position + (s as Node3D).global_transform.basis.y * 0.9
		var rr := radius * 1.1
		var d := pos.distance_to(c)
		if d > rr:
			continue
		var f := 1.0 - d / rr
		f = f * f * 0.55 + f * 0.45
		var dmg := dmg0 * f
		var hp: float = float(s.get("hp")) if s.get("hp") != null else 0.0
		structure_hit(s, {"dmg": dmg, "killed": hp > 0.0 and dmg >= hp}, dmg, c, {"big": f, "quiet": not first})
		first = false


## The Explosion node that is emitting Game.blast at `pos` right now (it was just added to the scene).
func _explosion_at(pos: Vector3) -> Node:
	var tree := get_tree()
	for parent: Node in [tree.current_scene, tree.root]:
		if parent == null:
			continue
		var n := parent.get_child_count()
		for i in range(n - 1, maxi(n - 8, 0) - 1, -1):
			var ch := parent.get_child(i)
			var sc = ch.get_script()
			if ch is Node3D and sc is Script and str((sc as Script).resource_path).ends_with("items/explosion.gd") \
					and (ch as Node3D).global_position.distance_to(pos) < 0.05:
				return ch
	return null


## "home" from this machine's point of view (the local player's team).
static func _my_team() -> String:
	var p = Game.player
	if p != null and is_instance_valid(p):
		return Game.team_of(p)
	return "home"


static func _struct_label(c) -> String:
	if c != null and is_instance_valid(c) and c.has_method("hud_name"):
		return str(c.hud_name())
	return "Yapı"


## Turkish upper case (i → İ, ı → I).
static func _tr_upper(s: String) -> String:
	return s.replace("i", "İ").replace("ı", "I").to_upper()


## Seeds the core hp table so the first core hit has something to compare with.
func _seed_cores() -> void:
	for c in get_tree().get_nodes_in_group("war_core"):
		var id: int = c.get_instance_id()
		if not _core_hp.has(id):
			_core_hp[id] = float(c.get("hp"))


# =================================================================================================
# Suppression feeds (scripts/ui/feel_fx.gd)
# =================================================================================================

## An enemy round struck at `point` (terrain, a wall) close to the listener.
func near_impact(point: Vector3) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var d := point.distance_to(cam.global_position)
	if d > IMPACT_R:
		return
	FeelFx.inst().suppress(lerpf(0.26, 0.08, d / IMPACT_R))


## A near miss passed `d` m from the ear (one feed per 50 ms: a bullet both simulated and announced).
func _suppress_near(d: float, supersonic: bool) -> void:
	var now := Time.get_ticks_msec()
	if now - _supp_t < 50:
		return
	_supp_t = now
	var k := lerpf(0.3, 0.12, clampf(d / NEAR_R, 0.0, 1.0)) * (1.0 if supersonic else 0.8)
	FeelFx.inst().suppress(k)


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
		"head":
			# Head hit: a sharp, bright ding over the tick (unmistakable from a body hit).
			_play("head_ding", -7.0, randf_range(0.98, 1.04))
			_play("tick", -12.0, randf_range(1.05, 1.12))
			_play("hit_thwack", -14.0, 1.1)
		_:
			_play("tick", -12.0, randf_range(0.95, 1.06))
			if now - int(_last_snd.get("thwack", -1000)) >= 70:
				_last_snd["thwack"] = now
				_play("hit_thwack", -8.0 if not light else -14.0, randf_range(0.94, 1.06))


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
	for n in WeaponAudio.HIT_NAMES + WeaponAudio.FEEL_NAMES:
		out[n] = gen.make(n)
	_synth_mutex.lock()
	_synth_ready = out
	_synth_mutex.unlock()


## Kill feed line (top right): killer ➜ victim (detail). mine = the local player took part.
func feed(killer: String, victim: String, detail := "", mine := true) -> void:
	hud.feed(killer, victim, detail, mine)


## Name of a damageable for the HUD: its callsign ("Rakip — Kazıcı"), hud_name(), display_name, or a
## generic word.
static func display_name(c) -> String:
	if c == null or not is_instance_valid(c):
		return "Hedef"
	var cs = c.get("callsign")
	if cs is String and cs != "":
		return cs
	var pn = c.get("player_name")              # multiplayer: the other player's chosen name
	if pn is String and pn != "":
		return pn
	if c.has_method("hud_name"):
		return str(c.hud_name())
	var dn = c.get("display_name")
	if dn is String and dn != "":
		return dn
	if (c as Node).is_in_group("war_structure"):
		return "Yapı"
	return "Hedef"


## A 2D feedback sound (heartbeat): helmet-internal, always heard.
func play_ui(name: String, vol: float, pitch := 1.0) -> void:
	_poll_synth()
	_play(name, vol, pitch)


## Someone else's bullet passed the listener at `point` (closest approach) at `speed` m/s.
func near_miss(point: Vector3, _dir: Vector3, speed: float) -> void:
	_whizz(point, speed)


## A hitscan shot of another team (Game.shot_fired, e.g. a remote player or a bot): if its line
## passes the listener within NEAR_R, whizz when the bullet would get there (~900 m/s).
func _on_shot_fired(from: Vector3, dir: Vector3, team: String) -> void:
	if team == "home" or team == "":
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var ear := cam.global_position
	_far_report(from, ear)
	var rel := ear - from
	var along := rel.dot(dir)
	if along < 6.0 or along > 900.0:
		return
	var q := from + dir * along
	var miss := q.distance_to(ear)
	if miss < IMPACT_R + 2.0:
		_impact_probe(cam, from, dir, along)
	if miss > NEAR_R or miss < 0.35:
		return
	_pending.append([Time.get_ticks_usec() + int(along / 900.0 * 1e6), q, 900.0])
	if _pending.size() > 6:
		_pending.pop_front()


## Where a close enemy hitscan shot strikes (one ray, ignoring the player: a hit on us is damage):
## within IMPACT_R of the ear it suppresses like a near miss.
func _impact_probe(cam: Camera3D, from: Vector3, dir: Vector3, along: float) -> void:
	var w := cam.get_world_3d()
	if w == null:
		return
	var ex: Array[RID] = []
	var pl = Game.player
	if pl is CollisionObject3D:
		ex.append((pl as CollisionObject3D).get_rid())
	var q := PhysicsRayQueryParameters3D.create(from + dir * 0.5, from + dir * minf(along + IMPACT_R + 2.0, 900.0),
			Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE, ex)
	var h := w.direct_space_state.intersect_ray(q)
	if not h.is_empty():
		near_impact(h["position"])


func _whizz(point: Vector3, speed: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		_suppress_near(point.distance_to(cam.global_position), speed > 360.0)
	var now := Time.get_ticks_msec()
	if now - _near_t < int(NEAR_GAP * 1000.0):
		return
	_near_t = now
	_poll_synth()
	# Supersonic rounds crack past (+ the flyby under it); slower ones only whizz. Recorded sets first
	# (bimp/crack, bimp/flyby), the synthesized snap / whizz until they are imported.
	var sup := speed > 360.0
	var rec_crack: Array = _snd.get("crack", [])
	var rec_fly: Array = _snd.get("flyby", [])
	var main: Array = (rec_crack if not rec_crack.is_empty() else _snd.get("snap", [])) if sup \
			else (rec_fly if not rec_fly.is_empty() else _snd.get("whizz", []))
	if main.is_empty():
		return
	var main_db := (1.0 if not rec_crack.is_empty() else 2.0) if sup else (1.0 if not rec_fly.is_empty() else 0.0)
	_near_play(main[randi() % main.size()], point, main_db, randf_range(0.92, 1.08))
	if sup:
		var under: Array = rec_fly if not rec_fly.is_empty() else _snd.get("whizz", [])
		if not under.is_empty():
			_near_play(under[randi() % under.size()], point, -3.0 if not rec_fly.is_empty() else -6.0, randf_range(1.0, 1.15))


func _near_play(st: AudioStream, point: Vector3, vol: float, pitch: float) -> void:
	var p: AudioStreamPlayer3D = _near[_near_i]
	_near_i = (_near_i + 1) % _near.size()
	p.stream = st
	p.global_position = point
	p.volume_db = vol
	p.pitch_scale = pitch
	if Game.sfx != null and Game.sfx.has_method("route_player"):
		Game.sfx.route_player(p)
	p.play()


## The distant report + rolling tail of an enemy shot fired at `from` (weap/far, FAR_GAP), queued to
## arrive at the speed of sound: quiet under the shooter's own report up close, loudest ~50 m out, a
## rumble far away.
func _far_report(from: Vector3, ear: Vector3) -> void:
	if (_snd.get("far", []) as Array).is_empty():
		return
	var d := from.distance_to(ear)
	if d > FAR_MAX:
		return
	var now := Time.get_ticks_msec()
	if now - _far_t < int(FAR_GAP * 1000.0):
		return
	_far_t = now
	var vol := lerpf(-14.0, -4.0, clampf((d - 8.0) / 40.0, 0.0, 1.0)) if d < 48.0 \
			else lerpf(-4.0, -12.0, clampf((d - 48.0) / (FAR_MAX - 48.0), 0.0, 1.0))
	_far_pending.append([Time.get_ticks_usec() + int(d / SOUND_SPEED * 1e6), from, vol])
	if _far_pending.size() > 6:
		_far_pending.pop_front()


func _far_play(pos: Vector3, vol: float) -> void:
	var arr: Array = _snd.get("far", [])
	if arr.is_empty() or not is_inside_tree():
		return
	var p: AudioStreamPlayer3D = _far[_far_i]
	_far_i = (_far_i + 1) % _far.size()
	var i := randi() % arr.size()
	if arr.size() > 2 and i == int(_last_pick.get("far", -1)):
		i = (i + 1) % arr.size()
	_last_pick["far"] = i
	p.stream = arr[i]
	p.global_position = pos
	p.volume_db = vol
	p.pitch_scale = randf_range(0.94, 1.06)
	if Game.sfx != null and Game.sfx.has_method("route_player"):
		Game.sfx.route_player(p)      # vacuum rules (sfx.gd): silent between the planets
	p.play()


func _play(name: String, vol: float, pitch: float) -> void:
	var arr: Array = _snd.get(name, [])
	if arr.is_empty():
		return
	var p: AudioStreamPlayer = _players[_pi]
	_pi = (_pi + 1) % _players.size()
	var i := randi() % arr.size()
	if arr.size() > 2 and i == int(_last_pick.get(name, -1)):
		i = (i + 1 + randi() % (arr.size() - 1)) % arr.size()
	_last_pick[name] = i
	p.stream = arr[i]
	p.volume_db = vol
	p.pitch_scale = pitch
	p.play()
