extends Node3D
## Göktaşı yağmuru (2026-10-06): every METEOR_GAP s (the first after METEOR_FIRST) METEOR_COUNT rich
## meteors streak in from space toward one planet (the rival's METEOR_RIVAL_SHARE of the time): a
## "GÖKTAŞI YAĞMURU!" alert with markers on the impact sites (scripts/war/war_hud.gd "Meteor
## shower"), fiery trails, a roar and a sonic crack, a blast (Explosion, team "meteor": hurts anyone
## near) and a crater (planet.crater, small). Each leaves a glowing meteor core embedded under the
## crater floor: a temporary deposit (scripts/planet/veins.gd add_deposit) worth METEOR_AMOUNT m³ of
## generic soil to whoever digs it out (the drill's × Veins.mult_at, on the digger's machine), for
## METEOR_LIFE s. The rival team sends bots to dig the ones on its planet (rival_team.gd / ai_rival.gd
## "Prospecting"), so the player has to contest them.
## One node, child of the war (scripts/war/war.gd), on every machine. The HOST (and single player)
## decides showers, impact points, craters, damage, the cores and their end; everything is announced
## through the static hub MeteorShower.events() so the multiplayer layer can replay it on the client:
##   shower_started(shower_id, body, impacts: PackedVector3Array (world), warn s)
##                 -> client: MeteorShower.net_shower(body, impacts, warn)
##   meteor_incoming(id, body, from, to (world), flight s)
##                 -> client: MeteorShower.net_incoming(id, body, from, to, flight)  (the streak, the
##                    blast's look at the end; no damage, no crater: the host's crater comes as terrain ops)
##   meteor_landed(id, body, pos (world core centre), amount m³)
##                 -> client: MeteorShower.net_landed(id, body, pos, amount)  (the core + its deposit:
##                    needed on the client so his drill gets the bonus)
##   meteor_gone(id, why)   "spent" (dug out) / "expired"  -> client: MeteorShower.net_gone(id)
## (World positions; bodies are planet nodes: Net.body_index / body_by_index. Body-local = pos −
## body.global_position if the transport prefers it.)
##   MeteorShower.hud_state() -> {"alert" (bool), "left" (s of warning / flight), "body", "sites"
##       (Array of world impact points still to come), "flying" (Array of world meteor positions),
##       "cores" (Array of {"id", "pos", "rem" 0..1, "amount", "body"})}
##   MeteorShower.instance(tree), start_shower(body = null) (host: one now; tests / training panel)
##   strike(body, centre, count, spread, warn, gap, opts) (host: Topçu's Göktaşı Yağmuru,
##       scripts/war/heroes/ult_meteor.gd: aimed meteors through the same path, no cores)

const Balance := preload("res://scripts/war/balance.gd")
const Veins := preload("res://scripts/planet/veins.gd")
const VeinFx := preload("res://scripts/planet/vein_fx.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const GROUP := "meteor_shower"
const RATE := 22050

## The events of the showers (see the header).
class MeteorEvents extends RefCounted:
	signal shower_started(shower_id: int, body: Node3D, impacts: PackedVector3Array, warn: float)
	signal meteor_incoming(id: int, body: Node3D, from: Vector3, to: Vector3, flight: float)
	signal meteor_landed(id: int, body: Node3D, pos: Vector3, amount: float)
	signal meteor_gone(id: int, why: String)

const CORE_SHADER := """
shader_type spatial;
uniform vec3 hot : source_color = vec3(1.0, 0.55, 0.15);
uniform float glow = 1.0;
varying vec3 lp;

float h3(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vn(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h3(i), h3(i + vec3(1.0, 0.0, 0.0)), f.x), mix(h3(i + vec3(0.0, 1.0, 0.0)), h3(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
		mix(mix(h3(i + vec3(0.0, 0.0, 1.0)), h3(i + vec3(1.0, 0.0, 1.0)), f.x), mix(h3(i + vec3(0.0, 1.0, 1.0)), h3(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

void vertex() {
	lp = VERTEX;
}

void fragment() {
	float n = vn(lp * 3.0) * 0.6 + vn(lp * 7.0) * 0.4;
	float crack = 1.0 - smoothstep(0.025, 0.085, abs(n - 0.5));
	float pulse = 0.8 + 0.2 * sin(TIME * 2.2 + n * 6.0);
	ALBEDO = mix(vec3(0.07, 0.06, 0.055), hot * 0.6, crack * 0.5);
	ROUGHNESS = mix(0.85, 0.3, crack);
	EMISSION = hot * crack * glow * 2.0 * pulse + hot * 0.04 * glow;
}
"""

static var _events: MeteorEvents
static var _inst: Node = null

var _next := 0.0
var _clock := 0.0
var _shower_id := 0
var _meteor_id := 0
var _pending: Array = []             # host: [launch at (clock s), id, body, from, to]
var _flying := {}                    # id -> {node, body, from, to, t, flight, boom, light, roar}
var _landing := {}                   # host: id -> {body, to, t} waiting for the crater
var _cores := {}                     # id -> {node, rock, mat, light, body, t, life}
var _alert_body: Node3D = null
var _alert_until := 0.0              # clock s
var _sites: Array = []               # [id or -1, world point, body] of the current shower not landed yet
var _hooked := {}
var _check_t := 0.0
var _core_shader: Shader
var _shard_mesh: Mesh
var _soft: Texture2D
var _task := -1
var _mutex := Mutex.new()
var _snd := {}
var _custom := {}                    # host: meteor id -> a hero strike's opts (strike())


static func events() -> MeteorEvents:
	if _events == null:
		_events = MeteorEvents.new()
	return _events


static func instance(tree: SceneTree = null) -> Node:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	if tree == null:
		tree = Engine.get_main_loop() as SceneTree
	return tree.get_first_node_in_group(GROUP) if tree != null else null


func _ready() -> void:
	add_to_group(GROUP)
	_inst = self
	name = "MeteorShower"
	top_level = true
	global_transform = Transform3D.IDENTITY
	_next = Balance.METEOR_FIRST
	_core_shader = Shader.new()
	_core_shader.code = CORE_SHADER
	_shard_mesh = VeinFx.cluster_mesh()
	_soft = DigFx.soft_texture()
	Explosion.prewarm()
	_task = WorkerThreadPool.add_task(_build_snd, false, "meteor_audio")


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	for id in _cores:
		Veins.remove_deposit(int(id))
	if _inst == self:
		_inst = null


func _authority() -> bool:
	return not Net.is_client()


func _process(delta: float) -> void:
	_clock += delta
	if _authority() and not Game.has_meta("training") and not bool(Game.get("match_over")):
		_next -= delta
		if _next <= 0.0:
			_next = randf_range(Balance.METEOR_GAP.x, Balance.METEOR_GAP.y)
			start_shower()
	for i in range(_pending.size() - 1, -1, -1):
		var p: Array = _pending[i]
		if _clock >= float(p[0]):
			_pending.remove_at(i)
			var body = p[2]
			if is_instance_valid(body):
				var fl: float = float(p[5]) if p.size() > 5 else Balance.METEOR_FLIGHT    # (a hero strike's own flight)
				events().meteor_incoming.emit(int(p[1]), body, p[3], p[4], fl)
				_spawn_flyer(int(p[1]), body, p[3], p[4], fl)
	_update_flyers(delta)
	_check_t -= delta
	if _check_t <= 0.0:
		_check_t = 0.5
		_check_landings()
		_check_cores()
	_animate_cores(delta)


# --- Host: showers ----------------------------------------------------------------------------------

## Starts a shower now on `body` (null: the rival's planet METEOR_RIVAL_SHARE of the time, else ours).
## Host / single player only. Returns the number of meteors.
func start_shower(body: Node3D = null) -> int:
	if not _authority():
		return 0
	if body == null:
		body = Game.rival if randf() < Balance.METEOR_RIVAL_SHARE else Game.planet
	if body == null or not is_instance_valid(body):
		return 0
	var impacts := _pick_impacts(body)
	if impacts.is_empty():
		return 0
	_shower_id += 1
	var warn := Balance.METEOR_WARN
	events().shower_started.emit(_shower_id, body, impacts, warn)
	var at := _clock + warn
	for p in impacts:
		_meteor_id += 1
		var id := (_shower_id << 8) | (_meteor_id & 0xFF)
		var up := (p - body.global_position).normalized()
		var t1 := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
		var t2 := up.cross(t1)
		var th := randf() * TAU
		var from: Vector3 = p + (up * 0.75 + (t1 * cos(th) + t2 * sin(th)) * 0.66).normalized() * Balance.METEOR_START_DIST
		_pending.append([at, id, body, from, p])
		_sites.append([id, p, body])
		at += randf_range(Balance.METEOR_STAGGER.x, Balance.METEOR_STAGGER.y)
	_begin_alert(body, at + Balance.METEOR_FLIGHT - _clock)
	return impacts.size()


## A hero's Göktaşı Yağmuru (scripts/war/heroes/ult_meteor.gd; host / single player only): `count`
## meteors on `body` within `spread` m of world point `centre`, the first launched after `warn` s, then
## one every `gap` s. Through the usual path and events (shower_started, meteor_incoming: a client
## replays it), the alert and the war HUD's site markers included. opts: "flight" (s), "start_dist" (m),
## "blast_r", "damage", "impulse" (the Explosion; 0 damage = the caller hurts with "on_impact"),
## "crater_r", "crater_depth", "core" (false: no meteor core / deposit), "team" (the Explosion's side),
## "on_impact" (Callable(world pos), host, after each blast). Returns the number of meteors.
func strike(body: Node3D, centre: Vector3, count: int, spread: float, warn: float, gap: float, opts := {}) -> int:
	if not _authority() or body == null or not is_instance_valid(body) or count <= 0:
		return 0
	var c := body.global_position
	var up0 := (centre - c).normalized()
	var R := float(body.radius)
	var impacts := PackedVector3Array()
	for k in count:
		for attempt in 8:
			var t1 := up0.cross(Vector3.RIGHT if absf(up0.x) < 0.9 else Vector3.FORWARD).normalized()
			var t2 := up0.cross(t1)
			var th := randf() * TAU
			var rr := spread * sqrt(randf()) if k > 0 else spread * 0.25 * randf()
			var d := (up0 * R + (t1 * cos(th) + t2 * sin(th)) * rr).normalized()
			var top := c + d * (R + float(body.max_height) + 2.0)
			var h: Dictionary = body.raycast_density(top, c + d * maxf(R - 25.0, 1.0), 0.5, true)
			if h.is_empty():
				continue
			var p: Vector3 = h["position"]
			var ok := true
			for q in impacts:
				if q.distance_to(p) < spread * 0.3:
					ok = false
			if ok or attempt == 7:
				impacts.append(p)
				break
	if impacts.is_empty():
		return 0
	_shower_id += 1
	events().shower_started.emit(_shower_id, body, impacts, warn)
	var flight := float(opts.get("flight", Balance.METEOR_FLIGHT))
	var dist := float(opts.get("start_dist", Balance.METEOR_START_DIST))
	var at := _clock + warn
	for p in impacts:
		_meteor_id += 1
		var id := (_shower_id << 8) | (_meteor_id & 0xFF)
		var up := (p - c).normalized()
		var t1 := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
		var t2 := up.cross(t1)
		var th := randf() * TAU
		var from: Vector3 = p + (up * 0.8 + (t1 * cos(th) + t2 * sin(th)) * 0.5).normalized() * dist
		_pending.append([at, id, body, from, p, flight])
		_sites.append([id, p, body])
		_custom[id] = opts
		at += gap
	_begin_alert(body, at + flight - _clock)
	return impacts.size()


## Impact points: around a centre (a contested zone or a random spot away from the base), spread over
## METEOR_SPREAD m of arc, METEOR_SPACING apart, clear of structures.
func _pick_impacts(body: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var c := body.global_position
	var R := float(body.radius)
	var cands: Array = Veins.contested_dirs(body)
	var centre := Vector3.ZERO
	for attempt in 12:
		var d: Vector3
		if not cands.is_empty() and randf() < 0.6:
			d = cands[randi() % cands.size()]
		else:
			d = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
		if _clear_of_structures(c + d * R, Balance.METEOR_STRUCT_CLEAR * 1.6):
			centre = d
			break
	if centre == Vector3.ZERO:
		return out
	var n := randi_range(Balance.METEOR_COUNT.x, Balance.METEOR_COUNT.y)
	for k in n:
		for attempt in 14:
			var t1 := centre.cross(Vector3.RIGHT if absf(centre.x) < 0.9 else Vector3.FORWARD).normalized()
			var t2 := centre.cross(t1)
			var th := randf() * TAU
			var ang := (randf() * Balance.METEOR_SPREAD if k > 0 else 0.0) / maxf(R, 1.0)
			var d := (centre * cos(ang) + (t1 * cos(th) + t2 * sin(th)) * sin(ang)).normalized()
			var top := c + d * (R + float(body.max_height) + 2.0)
			var h: Dictionary = body.raycast_density(top, c + d * maxf(R - 25.0, 1.0), 0.5, true)
			if h.is_empty():
				continue
			var p: Vector3 = h["position"]
			var ok := _clear_of_structures(p, Balance.METEOR_STRUCT_CLEAR)
			for q in out:
				if q.distance_to(p) < Balance.METEOR_SPACING:
					ok = false
			if ok:
				out.append(p)
				break
	return out


func _clear_of_structures(p: Vector3, r: float) -> bool:
	for s in get_tree().get_nodes_in_group("war_structure"):
		if s is Node3D and (s as Node3D).global_position.distance_to(p) < r + float(s.get_meta("footprint_r", 3.0)):
			return false
	return true


func _begin_alert(body: Node3D, secs: float) -> void:
	_alert_body = body
	_alert_until = maxf(_alert_until, _clock + secs)
	if Game.sfx:
		Game.sfx.play("error", -6.0, 0.7)


# --- Client replay ---------------------------------------------------------------------------------

static func net_shower(body: Node3D, impacts: PackedVector3Array, warn: float) -> void:
	var s = instance()
	if s == null or body == null:
		return
	for p in impacts:
		s._sites.append([-1, p, body])
	s._begin_alert(body, warn + Balance.METEOR_FLIGHT + float(impacts.size()) * Balance.METEOR_STAGGER.y)


static func net_incoming(id: int, body: Node3D, from: Vector3, to: Vector3, flight: float) -> void:
	var s = instance()
	if s != null and body != null and not s._flying.has(id):
		s._spawn_flyer(id, body, from, to, flight)


static func net_landed(id: int, body: Node3D, pos: Vector3, amount: float) -> void:
	var s = instance()
	if s != null and body != null:
		s._land_core(id, body, pos, amount)


static func net_gone(id: int) -> void:
	var s = instance()
	if s != null:
		s._crumble(id, false)


# --- Flight -----------------------------------------------------------------------------------------

func _spawn_flyer(id: int, body: Node3D, from: Vector3, to: Vector3, flight: float) -> void:
	var root := Node3D.new()
	add_child(root)
	root.global_position = from
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.55
	sm.height = 1.1
	sm.radial_segments = 10
	sm.rings = 6
	head.mesh = sm
	var hm := StandardMaterial3D.new()
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.albedo_color = Color(1.6, 1.15, 0.7)
	head.material_override = hm
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)
	var halo := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(4.0, 4.0)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.albedo_texture = _soft
	qm.albedo_color = Color(1.0, 0.55, 0.2, 0.85)
	q.material = qm
	halo.mesh = q
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(halo)
	root.add_child(_trail(Color(1.0, 0.75, 0.4), Color(1.0, 0.3, 0.08), 140, 0.9, 0.45, 1.6))
	root.add_child(_trail(Color(0.42, 0.38, 0.36, 0.55), Color(0.25, 0.24, 0.24, 0.0), 70, 3.2, 0.9, 3.5))
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.25)
	light.omni_range = 28.0
	light.light_energy = 2.6
	light.shadow_enabled = false
	root.add_child(light)
	var roar := AudioStreamPlayer3D.new()
	roar.unit_size = 30.0
	roar.max_distance = 260.0
	roar.volume_db = -4.0
	root.add_child(roar)
	var st = _sound("roar")
	if st != null:
		roar.stream = st
		roar.play()
	_flying[id] = {"node": root, "body": body, "from": from, "to": to, "t": 0.0, "flight": maxf(flight, 0.5),
			"boom": false, "light": light}


func _trail(c0: Color, c1: Color, amount: int, life: float, r: float, size: float) -> GPUParticles3D:
	var g := GPUParticles3D.new()
	g.amount = amount
	g.lifetime = life
	g.local_coords = false
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.visibility_aabb = AABB(Vector3.ONE * -300.0, Vector3.ONE * 600.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = r
	pm.spread = 180.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 1.2
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.5
	pm.damping_max = 1.0
	pm.scale_min = 0.6
	pm.scale_max = 1.0
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.45))
	sc.add_point(Vector2(1.0, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var gr := Gradient.new()
	gr.set_color(0, c0)
	gr.set_color(1, Color(c1, 0.0))
	gr.add_point(0.35, c1)
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	pm.color_ramp = gt
	g.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if c0.a > 0.9 else BaseMaterial3D.BLEND_MODE_MIX
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = _soft
	q.material = m
	g.draw_pass_1 = q
	g.emitting = true
	return g


func _update_flyers(delta: float) -> void:
	for id in _flying.keys():
		var f: Dictionary = _flying[id]
		var root = f["node"]
		if not is_instance_valid(root) or not is_instance_valid(f["body"]):
			_flying.erase(id)
			if is_instance_valid(root):
				(root as Node).queue_free()
			continue
		f["t"] = float(f["t"]) + delta
		var k := clampf(float(f["t"]) / float(f["flight"]), 0.0, 1.0)
		var e := k * k * 0.35 + k * 0.65                   # speeding up on the way in
		(root as Node3D).global_position = (f["from"] as Vector3).lerp(f["to"], e)
		if not bool(f["boom"]) and k > 0.55:
			f["boom"] = true
			_sonic_boom((root as Node3D).global_position)
		if k >= 1.0:
			_flying.erase(id)
			_impact(int(id), f["body"], f["to"])
			# The trails fade out where they are.
			for c in (root as Node).get_children():
				if c is GPUParticles3D:
					(c as GPUParticles3D).emitting = false
				elif c is MeshInstance3D or c is OmniLight3D or c is AudioStreamPlayer3D:
					(c as Node).queue_free()
			get_tree().create_timer(3.5).timeout.connect((root as Node).queue_free)


func _sonic_boom(p: Vector3) -> void:
	var st = _sound("crack")
	if st == null:
		return
	var a := AudioStreamPlayer3D.new()
	a.stream = st
	a.unit_size = 60.0
	a.max_distance = 600.0
	a.volume_db = 2.0
	add_child(a)
	a.global_position = p
	a.play()
	a.finished.connect(a.queue_free)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma") and (pl as Node3D).global_position.distance_to(p) < 120.0:
		pl.add_trauma(0.18)


## The strike: the blast everywhere (Explosion: damage only on the host), the crater and the core on
## the host.
func _impact(id: int, body: Node3D, to: Vector3) -> void:
	var up := (to - body.global_position).normalized()
	var soil: Color = body.get("soil_color") if body.get("soil_color") != null else Color(0.42, 0.36, 0.27)
	var o: Dictionary = _custom.get(id, {})          # a hero strike's own numbers (strike())
	_custom.erase(id)
	Explosion.spawn(to, up, {"radius": float(o.get("blast_r", Balance.METEOR_BLAST_R)),
			"damage": float(o.get("damage", Balance.METEOR_DAMAGE)), "impulse": float(o.get("impulse", Balance.METEOR_IMPULSE)),
			"crater": 0.0, "player_owned": false, "team": str(o.get("team", "meteor")), "ground": soil})
	for i in range(_sites.size() - 1, -1, -1):
		var s: Array = _sites[i]
		if int(s[0]) == id or (int(s[0]) < 0 and (s[1] as Vector3).distance_to(to) < 1.0):
			_sites.remove_at(i)
	if not _authority():
		return
	var cb = o.get("on_impact")
	if cb is Callable and (cb as Callable).is_valid():
		(cb as Callable).call(to)
	if body.has_method("crater"):
		_hook_crater(body)
		body.crater(to, float(o.get("crater_r", Balance.METEOR_CRATER_R)), float(o.get("crater_depth", Balance.METEOR_CRATER_DEPTH)))
	if bool(o.get("core", true)):
		_landing[id] = {"body": body, "to": to, "t": _clock}


func _hook_crater(body: Node3D) -> void:
	var bid := body.get_instance_id()
	if _hooked.has(bid) or not body.has_signal("crater_done"):
		return
	_hooked[bid] = true
	body.connect("crater_done", _on_crater_done.bind(body))


func _on_crater_done(center: Vector3, _radius: float, _soil: float, body: Node3D) -> void:
	for id in _landing.keys():
		var l: Dictionary = _landing[id]
		if l["body"] == body and (l["to"] as Vector3).distance_to(center) < 2.0:
			_landing.erase(id)
			_settle(int(id), body, l["to"])


## Landings whose crater_done never came (1.5 s) settle anyway.
func _check_landings() -> void:
	for id in _landing.keys():
		var l: Dictionary = _landing[id]
		if _clock - float(l["t"]) > 1.5:
			_landing.erase(id)
			if is_instance_valid(l["body"]):
				_settle(int(id), l["body"], l["to"])


## Host: the core under the fresh crater floor.
func _settle(id: int, body: Node3D, to: Vector3) -> void:
	var up := (to - body.global_position).normalized()
	var h: Dictionary = body.raycast_density(to + up * 6.0, to - up * 14.0, 0.25, false)
	var floor_p: Vector3 = h["position"] if not h.is_empty() else to - up * 2.0
	var core := floor_p - up * Balance.METEOR_CORE_FLOOR
	var amount := randf_range(Balance.METEOR_AMOUNT.x, Balance.METEOR_AMOUNT.y)
	_land_core(id, body, core, amount)
	events().meteor_landed.emit(id, body, core, amount)


# --- Cores ------------------------------------------------------------------------------------------

func _land_core(id: int, body: Node3D, pos: Vector3, amount: float) -> void:
	if _cores.has(id):
		return
	var R := Balance.METEOR_CORE_R
	var vol := Veins.below_floor_volume(R, Balance.METEOR_CORE_FLOOR)
	var mult := clampf(amount / maxf(vol, 0.1), Balance.METEOR_MULT.x, Balance.METEOR_MULT.y)
	Veins.add_deposit(id, body, pos, R, mult, amount, Balance.METEOR_CORE_FLOOR)
	for i in range(_sites.size() - 1, -1, -1):
		if (_sites[i][1] as Vector3).distance_to(pos) < 6.0:
			_sites.remove_at(i)
	var up := (pos - body.global_position).normalized()
	var root := Node3D.new()
	body.add_child(root)
	root.global_transform = Transform3D(VeinFx._basis_y(up), pos)
	var rock := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.85
	sm.height = 1.4
	sm.radial_segments = 9
	sm.rings = 5
	rock.mesh = sm
	var mat := ShaderMaterial.new()
	mat.shader = _core_shader
	rock.material_override = mat
	rock.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
	root.add_child(rock)
	var shard_mat := StandardMaterial3D.new()
	shard_mat.albedo_color = Color(1.0, 0.78, 0.4)
	shard_mat.emission_enabled = true
	shard_mat.emission = Color(1.0, 0.55, 0.15)
	shard_mat.emission_energy_multiplier = 1.8
	shard_mat.roughness = 0.15
	for k in 3:
		var sh := MeshInstance3D.new()
		sh.mesh = _shard_mesh
		sh.material_override = shard_mat
		sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var a := TAU * float(k) / 3.0 + randf() * 0.6
		var dir := Vector3(cos(a) * 0.55, 0.85, sin(a) * 0.55).normalized()
		sh.transform = Transform3D(VeinFx._basis_y(dir).scaled(Vector3.ONE * randf_range(1.2, 1.8)), dir * 0.55)
		root.add_child(sh)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.22)
	light.omni_range = 7.0
	light.light_energy = 1.4
	light.shadow_enabled = false
	light.position = Vector3(0, 1.0, 0)
	root.add_child(light)
	_cores[id] = {"node": root, "rock": rock, "mat": mat, "shard": shard_mat, "light": light, "body": body,
			"t": _clock, "life": Balance.METEOR_LIFE, "rem": 1.0, "amount": amount}


func _check_cores() -> void:
	for id in _cores.keys():
		var c: Dictionary = _cores[id]
		if not is_instance_valid(c["body"]) or not is_instance_valid(c["node"]):
			_cores.erase(id)
			Veins.remove_deposit(int(id))
			continue
		var rem := Veins.deposit_remaining(int(id))
		c["rem"] = rem
		if rem < Balance.VEIN_SPENT:
			_crumble(int(id), true, "spent")
		elif _clock - float(c["t"]) > float(c["life"]) and _authority():
			_crumble(int(id), true, "expired")
		elif _clock - float(c["t"]) > float(c["life"]) + 30.0:
			_crumble(int(id), false)            # (client: the host's event never came)


func _animate_cores(delta: float) -> void:
	for id in _cores:
		var c: Dictionary = _cores[id]
		if not is_instance_valid(c["node"]):
			continue
		var rem := float(c["rem"])
		var g := Veins.glow(rem)
		var age := _clock - float(c["t"])
		var fade := clampf((float(c["life"]) - age) / 20.0, 0.25, 1.0)      # dims over its last 20 s
		var rock: MeshInstance3D = c["rock"]
		var s := lerpf(0.35, 1.0, clampf(rem, 0.0, 1.0))
		rock.scale = rock.scale.lerp(Vector3.ONE * s, minf(delta * 3.0, 1.0))
		(c["mat"] as ShaderMaterial).set_shader_parameter("glow", g * fade)
		(c["shard"] as StandardMaterial3D).emission_energy_multiplier = 0.3 + 1.6 * g * fade
		var l: OmniLight3D = c["light"]
		l.light_energy = (1.1 + 0.3 * sin(_clock * 2.6 + float(id))) * maxf(g, 0.15) * fade


## Removes core `id` (dug out / expired / the host said so): a burst of embers, its deposit goes.
func _crumble(id: int, announce: bool, why := "spent") -> void:
	var c = _cores.get(id)
	Veins.remove_deposit(id)
	if not (c is Dictionary):
		return
	_cores.erase(id)
	var root = c["node"]
	if is_instance_valid(root):
		var p: Vector3 = (root as Node3D).global_position
		var g := GPUParticles3D.new()
		g.one_shot = true
		g.amount = 24
		g.lifetime = 1.0
		g.explosiveness = 0.9
		g.local_coords = false
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3.UP
		pm.spread = 70.0
		pm.initial_velocity_min = 1.5
		pm.initial_velocity_max = 4.0
		pm.gravity = -(p - (c["body"] as Node3D).global_position).normalized() * 5.0
		pm.color = Color(1.0, 0.6, 0.2)
		g.process_material = pm
		var q := QuadMesh.new()
		q.size = Vector2(0.08, 0.08)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = _soft
		q.material = m
		g.draw_pass_1 = q
		add_child(g)
		g.global_transform = Transform3D(VeinFx._basis_y((p - (c["body"] as Node3D).global_position).normalized()), p)
		g.emitting = true
		get_tree().create_timer(1.6).timeout.connect(g.queue_free)
		(root as Node).queue_free()
	if announce and _authority():
		events().meteor_gone.emit(id, why)


# --- HUD --------------------------------------------------------------------------------------------

## What the war HUD shows (see the header); empty values when nothing is going on.
static func hud_state() -> Dictionary:
	var s = instance()
	var out := {"alert": false, "left": 0.0, "body": null, "sites": [], "flying": [], "cores": []}
	if s == null:
		return out
	var left: float = float(s._alert_until) - float(s._clock)
	out["alert"] = left > 0.0 and (not (s._sites as Array).is_empty() or not (s._flying as Dictionary).is_empty())
	out["left"] = maxf(left, 0.0)
	out["body"] = s._alert_body if is_instance_valid(s._alert_body) else null
	for e in s._sites:
		out["sites"].append(e[1])
	for id in s._flying:
		var f: Dictionary = s._flying[id]
		if is_instance_valid(f["node"]):
			out["flying"].append((f["node"] as Node3D).global_position)
	for id in s._cores:
		var c: Dictionary = s._cores[id]
		if is_instance_valid(c["node"]):
			out["cores"].append({"id": int(id), "pos": (c["node"] as Node3D).global_position, "rem": float(c["rem"]),
					"amount": float(c["amount"]), "body": c["body"]})
	return out


# --- Sounds -----------------------------------------------------------------------------------------
#   roar   the meteor's rushing rumble (loop)
#   crack  the sonic boom: a double N-wave crack and a rolling rumble

func _sound(nm: String):
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_mutex.lock()
	var st = _snd.get(nm)
	_mutex.unlock()
	return st


func _build_snd() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var roar := VeinFx._wav(_roar_s(rng), 0.7)
	roar.mix_rate = RATE
	roar.loop_mode = AudioStreamWAV.LOOP_FORWARD
	roar.loop_begin = 0
	roar.loop_end = roar.data.size() / 2
	var crack := VeinFx._wav(_crack_s(rng), 0.95)
	crack.mix_rate = RATE
	_mutex.lock()
	_snd = {"roar": roar, "crack": crack}
	_mutex.unlock()


static func _roar_s(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var n := int(1.6 * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var b := 0.0
	var lp := 0.0
	for i in n:
		var w := rng.randf() * 2.0 - 1.0
		b = (b + 0.02 * w) * 0.997
		lp += 0.25 * (w - lp)
		var t := float(i) / RATE
		s[i] = b * 9.0 + lp * 0.35 * (0.7 + 0.3 * sin(TAU * 7.0 * t))
	# Crossfade the ends for a seamless loop.
	var xf := int(0.1 * RATE)
	for i in xf:
		var k := float(i) / float(xf)
		s[i] = s[i] * k + s[n - xf + i] * (1.0 - k)
	return s


static func _crack_s(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var n := int(1.4 * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var b := 0.0
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for st: float in [0.0, 0.11]:
			var te := t - st
			if te > 0.0 and te < 0.012:
				v += (1.0 - te / 0.006) * 1.2           # N-wave: up, then down
		var w := rng.randf() * 2.0 - 1.0
		b = (b + 0.05 * w) * 0.995
		v += b * 3.0 * exp(-t * 2.2) * minf(t * 30.0, 1.0)
		v += sin(TAU * 42.0 * t) * exp(-t * 3.0) * 0.4 * minf(t * 60.0, 1.0)
		s[i] = v
	return s
