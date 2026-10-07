extends Node3D
## Havan mermileri: the shells of the Havan (scripts/items/mortar.gd owns one manager; it sits at the
## world origin, top_level; scripts/net/net_players.gd keeps another for the other player's shots).
## Each shell is a small node (inner class Shell, group "war_shell": team, vel, is_live(),
## shot_down(by_pos), so an enemy Uçaksavar's point defence can burst it in the air) that this
## manager steps:
##   flight   pure ballistics under Game.gravity_at (both planets) with a FIXED step (STEP), driven
##            by an accumulator, so the flight is exactly the rule trace() runs: the tube's sight
##            (scripts/items/mortar_aim.gd) predicts the landing point with the very same steps and
##            the shell lands where the marker said. The drawn body is interpolated between steps and
##            starts at the visible tube mouth (vis offset fading over VIS_BLEND s).
##   hits     Ballistics.segment_hit every step: physics (terrain, structures, the skiff, characters)
##            and the planets' density field; the shooter's RIDs are excluded
##   impact   Explosion.spawn (BLAST_RADIUS / DAMAGE / IMPULSE / CRATER: smaller than a cannon shell,
##            bigger than a grenade; it emits Game.blast, carves the crater on the host, shoves and
##            ragdolls through Game.damage_target); a direct hit on a damageable also takes DIRECT
##   whistle  the falling whistle (synthesized, WHISTLE_LEAD s long, its pitch dropping) starts so it
##            ends at the predicted impact: a 3D sound on the shell, so whoever is near the landing
##            point hears it coming; a shell not fired by this machine's player that will land within
##            WARN_R of him also flashes "HAVAN GELİYOR" on the HUD
##   timeout  after LIFE s it bursts in the air (no crater, AIRBURST of the blast); shot_down() too
##   looks    a dark olive finned bomb with a red band, a thin smoke trail, a halo so it stays a dot
##            high in the sky
## Multiplayer: a shell is (pos, vel, team, cfg); the Havan emits mortar_fired(pos, vel, cfg) and the
## other machine replays it with launch() (net_players.gd, the "Havan" section). Damage, the direct
## hit and the crater are host-authoritative: on a client the direct hit is skipped and
## Explosion.spawn skips damage and craters (the host's crater arrives as a terrain op). cfg "nid"
## names the shell on both machines: a shell the host's flak bursts is burst on the client too
## (net_players.gd send_mortar_down / burst_nid()).
##   shells.launch(pos, vel, team, cfg = {}, exclude_rids = [], shooter = null, vis_from = INF) -> Shell
##   MortarShell.trace(from, vel, space, exclude, max_t) -> {"points", "position", "normal", "body", "time"}
##   MortarShell.default_cfg() -> Dictionary
##   shells.launch_fx(pos, dir)   the tube's blast seen from outside (a replayed shot)

const Ballistics := preload("res://scripts/items/ballistics.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const Rockets := preload("res://scripts/items/rockets.gd")          # puff(): one-shot smoke bursts
const DigFx := preload("res://scripts/items/dig_fx.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const SCRIPT_PATH := "res://scripts/items/mortar_shell.gd"

# --- Tuning -----------------------------------------------------------------------------------------
const STEP := 1.0 / 30.0           # s: the fixed flight step (the sight's trace uses the very same)
const LIFE := 40.0                 # s before a shell that hit nothing bursts in the air
const BLAST_RADIUS := 6.0          # Explosion radius (× Balance.BLAST_RADIUS_SCALE): grenade 5.0 < this < cannon shell 7.5
const DAMAGE := 170.0              # at the centre (grenade 130, rocket 200, cannon shell 220)
const DIRECT := 40.0               # + a direct hit on a damageable
const IMPULSE := 15.0              # m/s at the centre: knocks a character over (player.gd RAGDOLL_PUSH 7.5)
const CRATER := 3.0                # crater radius (m; grenade 1.8, rocket 2.4, cannon shell 5.5 deep)
const SELF_MULT := 0.7             # share of the blast the shooter takes
const AIRBURST := 0.5              # damage / radius share of an air burst (timeout, shot down)
const MAX_SPEED := 40.0            # m/s: a replayed launch is clamped to this
const VIS_BLEND := 0.25            # s the drawn shell takes to slide from the tube mouth onto the true path
const NEAR_GROW := 6.0             # m from the camera at which the drawn bomb reaches full size
const PREDICT_STEPS := 90          # flight steps of the impact prediction per physics frame (~3 s of flight)
const WHISTLE_LEAD := 2.6          # s: the whistle starts this long before the predicted impact
const WHISTLE_DB := 4.0
const WHISTLE_UNIT := 24.0         # AudioStreamPlayer3D unit_size: heard well ~60 m around the landing
const WARN_R := 14.0               # m: a shell landing this close to the local player warns him
const BODY_LEN := 0.5              # m: the drawn bomb (a little larger than life, to be seen)
const BODY_R := 0.085
const OLIVE := Color(0.27, 0.31, 0.2)
const BAND := Color(0.85, 0.2, 0.12)
const RATE := 22050

## One shell in flight (stepped by the manager). Group "war_shell".
class Shell extends Node3D:
	var manager
	var team := "home"
	var vel := Vector3.ZERO
	var pos := Vector3.ZERO            # true position (the node is drawn interpolated)
	var prev := Vector3.ZERO
	var age := 0.0
	var acc := 0.0
	var exclude: Array = []
	var shooter: Node3D = null
	var cfg: Dictionary = {}
	var owned := true
	var nid := 0
	var done := false
	var impact_t := -1.0               # predicted flight time to the impact (s from launch), -1 unknown
	var impact_p := Vector3.INF
	var job := {}                      # the impact prediction in progress (trace_job)
	var job_age := 0.0
	var vel_set := Vector3.ZERO        # vel after our last step (an outside change re-predicts)
	var vis_off := Vector3.ZERO
	var spin := 0.0
	var whistled := false
	var warned := false
	var body_node: Node3D
	var halo: MeshInstance3D
	var trail: GPUParticles3D
	var whistle: AudioStreamPlayer3D

	## Still flying.
	func is_live() -> bool:
		return not done

	## Burst in the air by an enemy Uçaksavar (flak_round.gd): an air burst, no crater.
	func shot_down(by_pos: Vector3) -> void:
		if not done and manager != null and is_instance_valid(manager):
			manager.airburst(self, true, by_pos)


static var _whistle_wav: AudioStreamWAV
static var _whistle_task := -1
static var _whistle_mutex := Mutex.new()
static var _whistle_pending: AudioStreamWAV
static var _next_nid := 1

var launched := 0
var detonations := 0
var last_impact := Vector3.INF
var _list: Array = []
var _dead: Array = []               # [Shell, seconds until freed] (smoke fading)
var _flashes: Array = []            # [OmniLight3D, t, dur, energy]
var _snd := {}


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	Explosion.prewarm()
	prewarm()
	_snd["whump"] = Snd.rand("weap/cannon", 1.06, 1.0)
	_snd["launch"] = Snd.rand("weap/launch", 1.05, 1.0)


func in_flight() -> int:
	return _list.size()


## The live shells (newest last).
func shells() -> Array:
	return _list.duplicate()


# =================================================================================================
# Motion (shared with the sight)
# =================================================================================================

## One fixed step of a shell's flight (the same update as Ballistics / shell.gd).
static func advance(p: Vector3, v: Vector3, dt: float) -> Array:
	var g: Vector3 = Game.gravity_at(p)
	return [p + v * dt + g * (0.5 * dt * dt), v + g * dt]


## The whole flight from `from` at `vel` with the shell's own steps: {"points"} (every step) plus, when
## it lands within max_t, "position", "normal", "body" (collider or planet) and "time" (s).
static func trace(from: Vector3, vel: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array = [],
		max_t := 30.0) -> Dictionary:
	var job := trace_job(from, vel, true)
	trace_step(job, 1 << 30, space, exclude, max_t)
	return job


## A trace spread over frames (a full one near the ground costs ~10-15 ms): trace_job() makes it,
## trace_step() advances it by up to n steps and returns true once it is over; the job then holds
## what trace() returns ("points" only with keep_points).
static func trace_job(from: Vector3, vel: Vector3, keep_points := true) -> Dictionary:
	return {"p": from, "v": vel, "t": 0.0, "keep": keep_points,
			"points": PackedVector3Array([from]) if keep_points else PackedVector3Array()}


static func trace_step(job: Dictionary, n: int, space: PhysicsDirectSpaceState3D, exclude: Array, max_t: float) -> bool:
	if job.has("done"):
		return true
	var p: Vector3 = job["p"]
	var v: Vector3 = job["v"]
	var t: float = job["t"]
	var keep: bool = job["keep"]
	var pts: PackedVector3Array = job["points"]
	var over := false
	for i in n:
		if t >= max_t:
			over = true
			break
		var res := advance(p, v, STEP)
		var np: Vector3 = res[0]
		var hit := Ballistics.segment_hit(p, np, space, exclude)
		t += STEP
		if not hit.is_empty():
			if keep:
				pts.append(hit["position"])
			job.merge(hit, true)
			job["time"] = t
			over = true
			break
		p = np
		v = res[1]
		if keep:
			pts.append(p)
	job["p"] = p
	job["v"] = v
	job["t"] = t
	job["points"] = pts
	if over:
		job["done"] = true
	return over


## The Havan's numbers (mortar_fired cfg; launch() fills in whatever a replay leaves out).
static func default_cfg() -> Dictionary:
	return {"radius": BLAST_RADIUS, "damage": DAMAGE, "impulse": IMPULSE, "crater": CRATER,
			"self_mult": SELF_MULT, "direct": DIRECT}


## A HUD toast for the Havan's files: Game.hud.alert(text, priority, key, secs) where the HUD has it
## (priority 0 info, 1 normal, 2 critical; key dedupes), else show_message.
static func toast(text: String, priority: int, key: String, secs := 2.0) -> void:
	if Game.hud == null or not is_instance_valid(Game.hud):
		return
	if Game.hud.has_method("alert"):
		Game.hud.call("alert", text, priority, key, secs)
	elif Game.hud.has_method("show_message"):
		Game.hud.show_message(text, secs)


## A fresh shell id for this machine's shots (the side keeps the two machines' ids apart).
static func new_nid() -> int:
	_next_nid += 1
	return (Net.my_side() if Net.active else 0) * 1000000 + _next_nid


# =================================================================================================
# Launch / impact
# =================================================================================================

## Fires a shell from `pos` (world) with velocity `vel` for side `p_team`. cfg: see default_cfg() plus
## "player_owned" (markers + self_mult on Game.player; default: shooter is null or Game.player) and
## "nid". vis_from: where the drawn shell starts (the view model's tube mouth), INF = pos.
func launch(pos: Vector3, vel: Vector3, p_team: String, cfg: Dictionary = {}, exclude_rids: Array = [],
		shooter: Node3D = null, vis_from := Vector3.INF) -> Node3D:
	var s := Shell.new()
	s.manager = self
	s.team = p_team
	s.vel = vel.limit_length(MAX_SPEED)
	s.vel_set = s.vel
	s.pos = pos
	s.prev = pos
	s.exclude = exclude_rids
	s.shooter = shooter
	s.cfg = default_cfg()
	s.cfg.merge(cfg, true)
	s.owned = bool(s.cfg.get("player_owned", shooter == null or shooter == Game.player))
	s.nid = int(s.cfg.get("nid", 0))
	s.spin = randf() * TAU
	if vis_from.is_finite() and vis_from.distance_to(pos) < 3.0:
		s.vis_off = vis_from - pos
	add_child(s)
	s.global_transform = Transform3D(_look(s.vel), pos + s.vis_off)
	s.add_to_group("war_shell")
	_build_shell(s)
	_predict(s)
	_list.append(s)
	launched += 1
	return s


## Where this shell will land (for the whistle and the warning): the same trace the sight ran, run
## ahead of the shell PREDICT_STEPS steps per physics frame (_physics_process).
func _predict(s: Shell) -> void:
	s.impact_t = -1.0
	s.impact_p = Vector3.INF
	s.job = trace_job(s.pos, s.vel, false)
	s.job_age = s.age


func _predict_step(s: Shell, space: PhysicsDirectSpaceState3D) -> void:
	if s.job.is_empty():
		return
	if trace_step(s.job, PREDICT_STEPS, space, s.exclude, LIFE - s.job_age):
		if s.job.has("position"):
			s.impact_t = s.job_age + float(s.job["time"])
			s.impact_p = s.job["position"]
		s.job = {}


func _impact(s: Shell, point: Vector3, n: Vector3, dir: Vector3, collider) -> void:
	s.pos = point
	s.global_position = point
	var c: Dictionary = s.cfg
	var t: Node = Game.damageable_of(collider) if collider is Object else null
	var direct := float(c.get("direct", 0.0))
	# Multiplayer client: the host's replay of this shell deals the direct hit.
	if t != null and t != s.shooter and direct > 0.0 and not Net.is_client():
		var src: Vector3 = s.shooter.global_position if s.shooter != null and is_instance_valid(s.shooter) else point - dir * 10.0
		var res := Game.damage_target(t, direct, src, dir * 8.0, s.team, point)
		if s.owned and not res.is_empty():
			HitFeel.inst().target_hit(t, res, direct, point, {"big": 0.9, "weapon": "Havan"})
	var nn := n.normalized() if (t == null and n.length_squared() > 0.01) else -dir.normalized()
	Explosion.spawn(point + nn * 0.2, nn, {"radius": float(c["radius"]), "damage": float(c["damage"]),
			"impulse": float(c["impulse"]), "crater": float(c["crater"]), "self_mult": float(c["self_mult"]),
			"player_owned": s.owned, "ground": Rifle.ground_color(point, nn), "team": s.team})
	_dust_ring(point, nn)
	last_impact = point
	detonations += 1
	_finish(s)


## Bursts in the air (timed out, or shot down): a smaller blast, no crater. A shot-down shell on the
## host tells the other machine (net_players.gd send_mortar_down).
func airburst(s: Shell, shot := false, _by_pos := Vector3.INF) -> void:
	if s.done:
		return
	var p := s.pos
	var c: Dictionary = s.cfg
	Explosion.spawn(p, Explosion._up_at(p), {"radius": float(c["radius"]) * AIRBURST,
			"damage": float(c["damage"]) * AIRBURST, "impulse": float(c["impulse"]) * AIRBURST, "crater": 0.0,
			"self_mult": float(c["self_mult"]), "player_owned": s.owned, "ground": Color(0.55, 0.55, 0.56), "team": s.team})
	detonations += 1
	if shot and s.nid != 0 and Net.is_host() and Net.get("players") != null and Net.players.has_method("send_mortar_down"):
		Net.players.call("send_mortar_down", s.nid, p)
	if shot and s.team != Game.team_of(Game.player):
		toast("Havan mermisi havada vuruldu!", 0, "mortar_down", 1.6)
	_finish(s)


## The other machine burst shell `nid` in the air (its flak): burst ours too. True when found.
func burst_nid(nid: int) -> bool:
	for s in _list:
		if is_instance_valid(s) and (s as Shell).nid == nid:
			airburst(s as Shell)
			return true
	return false


## Stops a shell: hides it and its sounds, lets the smoke fade, frees it later.
func _finish(s: Shell) -> void:
	if s.done:
		return
	s.done = true
	s.remove_from_group("war_shell")
	_list.erase(s)
	s.body_node.visible = false
	s.halo.visible = false
	s.trail.emitting = false
	if s.whistle != null:
		s.whistle.stop()
	_dead.append([s, s.trail.lifetime + 0.3])


# =================================================================================================
# Per frame
# =================================================================================================

func _physics_process(delta: float) -> void:
	for i in range(_dead.size() - 1, -1, -1):
		_dead[i][1] = float(_dead[i][1]) - delta
		if float(_dead[i][1]) <= 0.0:
			var dn = _dead[i][0]
			if is_instance_valid(dn):
				(dn as Node).queue_free()
			_dead.remove_at(i)
	if _list.is_empty():
		return
	var space := get_world_3d().direct_space_state
	for s in _list.duplicate():
		if not is_instance_valid(s):
			_list.erase(s)
			continue
		var sh := s as Shell
		# Pushed by something (the Kinetik İtici deflects shells): the old prediction is void.
		if not sh.vel.is_equal_approx(sh.vel_set):
			sh.vel_set = sh.vel
			_predict(sh)
		_predict_step(sh, space)
		sh.acc += delta
		while sh.acc >= STEP and not sh.done:
			sh.acc -= STEP
			_step(sh, space)


func _step(s: Shell, space: PhysicsDirectSpaceState3D) -> void:
	var res := advance(s.pos, s.vel, STEP)
	var np: Vector3 = res[0]
	var hit := Ballistics.segment_hit(s.pos, np, space, s.exclude)
	s.age += STEP
	if not hit.is_empty():
		_impact(s, hit["position"], hit["normal"], (np - s.pos).normalized(), hit.get("body"))
		return
	s.prev = s.pos
	s.pos = np
	s.vel = res[1]
	s.vel_set = s.vel
	if s.age >= LIFE:
		airburst(s)


func _process(delta: float) -> void:
	for s in _list:
		if is_instance_valid(s):
			_animate(s as Shell, delta)
	for i in range(_flashes.size() - 1, -1, -1):
		var f: Array = _flashes[i]
		f[1] = float(f[1]) + delta
		var l: OmniLight3D = f[0]
		var k := 1.0 - float(f[1]) / float(f[2])
		if k <= 0.0:
			l.queue_free()
			_flashes.remove_at(i)
			continue
		l.light_energy = float(f[3]) * k * k


## Interpolated drawing, the slide off the tube mouth, spin; the whistle and the warning.
func _animate(s: Shell, delta: float) -> void:
	var k := clampf(s.acc / STEP, 0.0, 1.0)
	var vk := clampf(1.0 - s.age / VIS_BLEND, 0.0, 1.0)
	var p := s.prev.lerp(s.pos, k) + s.vis_off * vk * vk
	s.spin += delta * 3.0
	s.global_transform = Transform3D(_look(s.vel), p)
	s.body_node.rotation.z = s.spin
	# Right at the shooter's eye the (oversized) bomb would fill the view: it grows to full size over
	# the first metres.
	if s.age < 1.0:
		var cam := get_viewport().get_camera_3d()
		var cd := cam.global_position.distance_to(p) if cam != null else 10.0
		s.body_node.scale = Vector3.ONE * clampf(cd / NEAR_GROW, 0.25, 1.0)
	elif s.body_node.scale.x < 1.0:
		s.body_node.scale = Vector3.ONE
	if s.impact_t < 0.0:
		return
	var left := s.impact_t - s.age
	if not s.whistled and left <= WHISTLE_LEAD and s.vel.dot(Explosion._up_at(s.pos)) < 0.0:
		s.whistled = true
		_start_whistle(s, left)
	if not s.warned and left <= WHISTLE_LEAD + 0.4 and not s.owned:
		s.warned = true
		var pl = Game.player
		if pl != null and is_instance_valid(pl) and s.impact_p.is_finite() \
				and (pl as Node3D).global_position.distance_to(s.impact_p) < WARN_R:
			var foe := s.team != Game.team_of(pl)
			if foe:
				toast("HAVAN GELİYOR — siper al!", 2, "mortar_incoming", 2.2)
			else:
				toast("Dost havan atışı yakınına düşüyor!", 1, "mortar_friendly", 2.0)


## The falling whistle, started so it ends at the impact (cut in when less is left).
func _start_whistle(s: Shell, left: float) -> void:
	var st := whistle_stream()
	if st == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = st
	p.volume_db = WHISTLE_DB
	p.unit_size = WHISTLE_UNIT
	p.max_distance = 260.0
	p.max_db = 6.0
	p.pitch_scale = randf_range(0.96, 1.04)
	s.add_child(p)
	if Game.sfx != null and Game.sfx.has_method("route_player"):
		Game.sfx.route_player(p)
	p.play(clampf(WHISTLE_LEAD - left, 0.0, WHISTLE_LEAD - 0.1))
	s.whistle = p


# =================================================================================================
# Building a shell
# =================================================================================================

func _build_shell(s: Shell) -> void:
	s.body_node = Node3D.new()
	s.add_child(s.body_node)
	var olive := _mat(OLIVE, 0.55, 0.25)
	var dark := _mat(Color(0.12, 0.13, 0.12), 0.45, 0.6)
	var band := _mat(BAND, 0.5, 0.0)
	var steel := _mat(Color(0.62, 0.64, 0.66), 0.3, 0.85)
	var L := BODY_LEN
	var r := BODY_R
	# Nose at -Z: fuze, ogive, body, band, tapered tail boom, fins (+Z).
	_cyl(s.body_node, r * 0.28, r * 0.12, L * 0.08, steel, -L * 0.46)
	_cyl(s.body_node, r * 0.95, r * 0.3, L * 0.2, olive, -L * 0.32)
	_cyl(s.body_node, r, r, L * 0.24, olive, -L * 0.1)
	_cyl(s.body_node, r * 1.01, r * 1.01, L * 0.04, band, -L * 0.2)
	_cyl(s.body_node, r * 0.35, r * 0.95, L * 0.18, olive, L * 0.11)
	_cyl(s.body_node, r * 0.3, r * 0.3, L * 0.2, dark, L * 0.3)
	for f in 6:
		var a := f * TAU / 6.0
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.006, r * 1.1, L * 0.17)
		mi.mesh = bm
		mi.material_override = dark
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.transform = Transform3D(Basis(Vector3.BACK, a), Vector3(-sin(a), cos(a), 0.0) * r * 0.75 + Vector3(0, 0, L * 0.34))
		s.body_node.add_child(mi)
	s.halo = MeshInstance3D.new()
	s.halo.mesh = DebrisMesh.quad_mesh()
	s.halo.material_override = DebrisMesh.halo_material(Color(1.0, 0.72, 0.45), 0.6, 0.004, 0.0)
	s.halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.halo.custom_aabb = AABB(Vector3.ONE * -50.0, Vector3.ONE * 100.0)
	s.add_child(s.halo)
	s.trail = _trail(s)


## A faint world-space smoke trail behind the shell.
func _trail(s: Shell) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.amount = 70
	e.lifetime = 1.6
	e.local_coords = false
	e.randomness = 0.3
	e.visibility_aabb = AABB(Vector3.ONE * -400.0, Vector3.ONE * 800.0)
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0, 1)
	pm.spread = 25.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 1.0
	pm.damping_min = 0.5
	pm.damping_max = 1.2
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.05
	pm.scale_min = 0.6
	pm.scale_max = 1.2
	var cv := Curve.new()
	cv.max_value = 4.0
	cv.add_point(Vector2(0.0, 0.3))
	cv.add_point(Vector2(1.0, 2.4))
	var ct := CurveTexture.new()
	ct.curve = cv
	pm.scale_curve = ct
	var gr := Gradient.new()
	gr.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	gr.colors = PackedColorArray([Color(0.85, 0.83, 0.8, 0.0), Color(0.8, 0.79, 0.76, 0.32), Color(0.75, 0.75, 0.75, 0.0)])
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	pm.color_ramp = gt
	e.process_material = pm
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_texture = DigFx.soft_texture()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.roughness = 1.0
	var q := QuadMesh.new()
	q.size = Vector2(0.45, 0.45)
	q.material = m
	e.draw_pass_1 = q
	e.position = Vector3(0, 0, BODY_LEN * 0.45)
	s.add_child(e)
	e.emitting = true
	return e


func _mat(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


## Cylinder along the shell's axis (top radius toward the nose, -Z), centred at z.
func _cyl(parent: Node3D, r_tail: float, r_nose: float, h: float, m: Material, z: float) -> void:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r_tail
	cm.top_radius = r_nose
	cm.height = h
	cm.radial_segments = 14
	cm.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 0, z))
	parent.add_child(mi)


static func _look(dir: Vector3) -> Basis:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.FORWARD
	var ref := Vector3.UP if absf(d.y) < 0.97 else Vector3.RIGHT
	return Basis.looking_at(d, ref)


# =================================================================================================
# One-shot effects: the impact's dust ring, the tube's blast seen from outside, light flashes
# =================================================================================================

## A low dust ring rolling out along the ground (on top of the Explosion's show).
func _dust_ring(point: Vector3, n: Vector3) -> void:
	var col: Color = Rifle.ground_color(point, n)
	Rockets.puff(self, point + n * 0.3, n, {"amount": 34, "life": 2.6, "vmin": 6.0, "vmax": 13.0, "damp": 3.4,
			"spread": 88.0, "size": 1.6, "scale": [0.5, 1.6, 3.2], "radius": 0.6, "explosive": 0.95,
			"gravity": -n * 0.4, "ramp": [[0.0, Color(col, 0.0)], [0.08, Color(col, 0.65)], [1.0, Color(col.lightened(0.2), 0.0)]]})


## The tube's blast as another player sees it (a replayed shot): the flash, a smoke ring, the whump.
func launch_fx(pos: Vector3, dir: Vector3) -> void:
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Explosion._up_at(pos)
	flash_light(pos + d * 0.6, Color(1.0, 0.7, 0.4), 9.0, 0.14, 12.0)
	muzzle_smoke(self, pos, d)
	for k in ["whump", "launch"]:
		var st = _snd.get(k)
		if st == null:
			continue
		var p := AudioStreamPlayer3D.new()
		p.stream = st
		p.volume_db = 4.0 if k == "whump" else -2.0
		p.pitch_scale = randf_range(1.12, 1.22) if k == "whump" else randf_range(0.66, 0.72)
		p.unit_size = 18.0
		p.max_distance = 500.0
		add_child(p)
		p.global_position = pos
		if Game.sfx != null and Game.sfx.has_method("route_player"):
			Game.sfx.route_player(p)
		p.play()
		p.finished.connect(p.queue_free)


## The muzzle's smoke: a ring blown out of the mouth along `d` and a slow grey cloud (static: the
## Havan uses it for its own shot too).
## k scales the size and density (the shooter's own view: ~0.55, so the cloud in front of the eye
## stays grey, not a white wall).
static func muzzle_smoke(parent: Node, pos: Vector3, d: Vector3, k := 1.0) -> void:
	var g: Vector3 = Game.gravity_at(pos)
	Rockets.puff(parent, pos + d * 0.2, d, {"amount": int(24 * k) + 4, "life": 1.5, "vmin": 3.0 * k, "vmax": 4.5 * k,
			"damp": 3.6, "spread": 88.0, "size": 0.42 * k, "scale": [0.5, 1.2, 2.2], "radius": 0.05, "explosive": 1.0,
			"gravity": -g * 0.02, "ramp": [[0.0, Color(0.8, 0.79, 0.76, 0.0)], [0.05, Color(0.78, 0.77, 0.75, 0.6 * k)],
				[1.0, Color(0.68, 0.68, 0.68, 0.0)]]})
	Rockets.puff(parent, pos + d * 0.4, d, {"amount": int(16 * k) + 4, "life": 2.8, "vmin": 1.0, "vmax": 6.0 * k,
			"damp": 2.6, "spread": 22.0, "size": 0.9 * k, "scale": [0.4, 1.3, 2.6], "radius": 0.1, "explosive": 0.9,
			"gravity": -g * 0.04, "ramp": [[0.0, Color(0.78, 0.77, 0.75, 0.0)], [0.08, Color(0.74, 0.73, 0.72, 0.42 * k)],
				[1.0, Color(0.62, 0.62, 0.62, 0.0)]]})
	Rockets.puff(parent, pos + d * 0.1, d, {"amount": 12, "life": 0.12, "vmin": 2.0, "vmax": 7.0, "damp": 8.0,
			"spread": 30.0, "size": 0.45 * k, "scale": [0.7, 1.3, 1.6], "radius": 0.04, "add": true, "color": Color(1.6, 1.6, 1.6),
			"ramp": [[0.0, Color(1.0, 0.9, 0.7, 1.0)], [1.0, Color(1.0, 0.45, 0.15, 0.0)]]})


## A short light flash at pos that decays over dur s.
func flash_light(pos: Vector3, col: Color, energy: float, dur: float, light_range: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.omni_range = light_range
	l.shadow_enabled = false
	add_child(l)
	l.global_position = pos
	_flashes.append([l, 0.0, maxf(dur, 0.02), energy])


# =================================================================================================
# The falling whistle (synthesized once on a worker thread)
# =================================================================================================

## Starts building the whistle (call early to avoid a hitch on the first shell).
static func prewarm() -> void:
	if _whistle_wav != null or _whistle_task >= 0:
		return
	_whistle_task = WorkerThreadPool.add_task(_build_whistle, false, "mortar_whistle")


static func whistle_stream() -> AudioStreamWAV:
	if _whistle_wav == null and _whistle_task >= 0 and WorkerThreadPool.is_task_completed(_whistle_task):
		WorkerThreadPool.wait_for_task_completion(_whistle_task)
		_whistle_task = -1
		_whistle_mutex.lock()
		_whistle_wav = _whistle_pending
		_whistle_mutex.unlock()
	return _whistle_wav


## WHISTLE_LEAD s: a breathy tone falling from ~1.45 kHz to ~0.5 kHz with a slow warble and a
## second partial, over rushing air, swelling as it comes down.
static func _build_whistle() -> void:
	var n := int(WHISTLE_LEAD * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	var ph := 0.0
	var ph2 := 0.0
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var t := float(i) / float(RATE)
		var u := t / WHISTLE_LEAD
		var f := 1450.0 * pow(500.0 / 1450.0, pow(u, 1.25)) * (1.0 + 0.012 * sin(t * TAU * 5.5))
		ph = fmod(ph + TAU * f / RATE, TAU)
		ph2 = fmod(ph2 + TAU * f * 2.01 / RATE, TAU)
		var wn := rng.randf_range(-1.0, 1.0)
		lp += (wn - lp) * 0.18
		lp2 += (lp - lp2) * 0.18
		var air := (lp - lp2) * 2.6
		var env := (0.12 + 0.88 * pow(u, 1.6)) * minf(t / 0.12, 1.0) * minf((WHISTLE_LEAD - t) / 0.03, 1.0)
		var v := (sin(ph) * 0.62 + sin(ph2) * 0.1 + air * (0.25 + 0.35 * u)) * env
		data.encode_s16(i * 2, int(clampf(v * 0.85, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	_whistle_mutex.lock()
	_whistle_pending = w
	_whistle_mutex.unlock()
