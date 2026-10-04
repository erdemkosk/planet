extends Node
## The rival team (child of the scene root, group "war_rival_team"): Balance.BOT_COUNT bots
## (scripts/war/ai_rival.gd) sharing ONE material pool, the team's structures and its aim learning,
## plus the budgets that keep 70 bots affordable.
##
## Roles (by share of the living bots, re-assigned every second, sticky): ROLE_ENGINEER_SHARE
## engineers (at least 1; AI_MAX_BUILDERS build at a time, one per cannon fires, others repair or
## dig), ROLE_MINER_SHARE miners, the rest guards ("Muhafız"; raiders when Balance.RAIDS_ENABLED).
## Bots spawn a few at a time over BOT_SPAWN_TIME s on a spiral around the base (AI_SPAWN_RADIUS)
## and respawn there AI_RESPAWN s after dying.
## Build order: cannon and Uçaksavar alternately up to AI_MAX_CANNONS / AI_MAX_FLAKS; destroyed
## structures drop out of the lists, so the engineers rebuild them.
## Economy: the pool earns min(TEAM_INCOME_CAP, digging bots × DRILL_MAX_RATE × AI_GATHER_MULT)
## m³/s; shells at most one per AI_TEAM_FIRE_GAP s team-wide.
##
## Budgets (the "LOD manager", 4 Hz, by distance to the active camera):
##   bot.lod             0 near (< AI_LOD_NEAR), 1 mid (< AI_LOD_MID), 2 far: think / move / pose rates
##   lights              the AI_LIGHT_MAX nearest bots keep their helmet lamp and muzzle flash light
##   voices              the AI_VOICE_MAX nearest bots may play sounds
##   dig FX              a pool of AI_FX_MAX DigFx goes to the nearest digging bots; the others get
##                       dust puffs from one shared particle emitter (dust_puff)
##   brushes             AI_MAX_BRUSHES bots really carve the terrain (2 nearest diggers + 2 rotating
##                       every AI_BRUSH_SLOT s); the rest dig with animation / FX only
##   shooters            AI_MAX_SHOOTERS bots (nearest with the player in sight) may fire at him
##   take_los()          AI_LOS_PER_FRAME density line-of-sight marches per physics frame
##   take_cover_eval()   AI_COVER_EVALS_PER_FRAME cover candidates per physics frame
##   ragdolls            AI_RAGDOLL_MAX live ones; older and settled corpses freeze in place
##   call_help()         at most AI_HELP_MAX allies answer
## Raids (DEFERRED: Balance.RAIDS_ENABLED = false, nothing of it runs and no skiff is built or
## touched): see _raid_think.
##   team.material, team.cannons, team.flaks, team.inbound_skiff() (HUD), team.raid_dig_dist (HUD)

const Balance := preload("res://scripts/war/balance.gd")
const Bot := preload("res://scripts/war/ai_rival.gd")
const Cannon := preload("res://scripts/war/cannon.gd")
const Flak := preload("res://scripts/war/flak.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const SKIFF_PATH := "res://scripts/craft/skiff.gd"
const GROUP := "war_rival_team"

const RAID_NONE := 0
const RAID_BUILD := 1
const RAID_BOARD := 2
const RAID_OUT := 3
const RAID_SITE := 4
const RAID_RETURN := 5
const RAID_BACK := 6
const RAID_NAMES := ["yok", "mekik yapılıyor", "biniyorlar", "yolda", "bizim gezegende", "dönüyorlar", "eve uçuyor"]

var team := "rival"
var body: Node3D                       # the rival planet
var home: Node3D                       # ours
var base_xf := Transform3D()
var material: float = Balance.START_MATERIAL
var bots: Array = []
var cannons: Array = []
var flaks: Array = []
var pending := {"cannon": 0, "flak": 0}   # structures an engineer is on the way to build
var skiff: Node3D = null
var skiff_pad := Transform3D()
# Shared cannon aim learning (all engineers).
var aim_err := Balance.AI_AIM_ERROR_START
var correction := Vector3.ZERO
var last_shot_ms := -1000000
# Raids (deferred).
var raid := RAID_NONE
var raiders: Array = []
var raid_land := Vector3.INF
var raid_dig_dist := -1.0
var skiff_cost := 0.0
var skiff_half := Vector3(3.0, 1.5, 4.0)
var _skiff_script: Script = null
var _skiff_ok := false
var _raid_t := 0.0
var _last_raid_end := -1.0e9
var _retreat := false
var _skiff_hp := -1.0
var _skiff_threat_ms := -100000
# Bookkeeping.
var _match_t := 0.0
var _think_t := 0.0
var _lod_t := 0.0
var _income_t := 0.0
var _spawned := 0
var _spawn_t := 0.0
var _dig_report_ms := -100000
var _los_left := 0
var _cover_left := 0
var _fx_pool: Array = []
var _ragdolls: Array = []
var _brush_rot: Array = []             # rotating brush holders: [bot, until_ms]
var _dust_pool: Array = []
var _dust_i := 0
const DUST_POOL := 12


func _ready() -> void:
	add_to_group(GROUP)
	name = "RivalTeam"
	body = Game.rival
	home = Game.planet
	base_xf = _base_transform()
	if Balance.RAIDS_ENABLED:
		_load_skiff_script()
	for i in Balance.AI_FX_MAX:
		var fx: Node3D = DigFx.new()
		fx.tip_is_vm = false
		add_child(fx)
		_fx_pool.append({"fx": fx, "bot": null})
	_build_dust()


func _physics_process(_delta: float) -> void:
	_los_left = Balance.AI_LOS_PER_FRAME
	_cover_left = Balance.AI_COVER_EVALS_PER_FRAME


func _process(delta: float) -> void:
	_match_t += delta
	_raid_t += delta
	# Staggered spawning: BOT_COUNT bots over BOT_SPAWN_TIME s (one or two per frame at most).
	if _spawned < Balance.BOT_COUNT:
		_spawn_t += delta
		var due := int(ceilf(_spawn_t / maxf(Balance.BOT_SPAWN_TIME, 0.1) * float(Balance.BOT_COUNT)))
		var n := mini(mini(due - _spawned, 2), Balance.BOT_COUNT - _spawned)
		for k in maxi(n, 0):
			_spawn_bot(_spawned)
			_spawned += 1
	_lod_t -= delta
	if _lod_t <= 0.0:
		_lod_t = 0.25
		_lod_update()
	_income_t += delta
	if _income_t >= 1.0:
		_income(_income_t)
		_income_t = 0.0
	_think_t -= delta
	if _think_t <= 0.0:
		_think_t = 1.0
		_think()
	if Time.get_ticks_msec() - _dig_report_ms > 1500:
		raid_dig_dist = -1.0


func _spawn_bot(i: int) -> void:
	var b: Node3D = Bot.new()
	b.team_node = self
	b.index = i
	b.name = "RivalBot%d" % i
	b.transform = respawn_xf(i)
	var scene: Node = get_tree().current_scene if get_tree().current_scene != null else get_parent()
	scene.add_child(b)
	bots.append(b)


func _load_skiff_script() -> void:
	if not ResourceLoader.exists(SKIFF_PATH):
		return
	var s = load(SKIFF_PATH)
	if not (s is Script) or not (s as Script).can_instantiate():
		return
	_skiff_script = s
	var consts: Dictionary = (s as Script).get_script_constant_map()
	skiff_cost = float(consts.get("BUILD_COST", Balance.SHUTTLE_COST_HINT))
	var names := {}
	for m in (s as Script).get_script_method_list():
		names[str(m.get("name", ""))] = true
	if names.has("footprint"):
		skiff_half = s.call("footprint")
	_skiff_ok = names.has("ai_board") and names.has("ai_exit") and names.has("ai_fly_to") and names.has("ai_arrived")


## The base: on the rival planet, on the side facing home, turned to the sun (like the player's).
func _base_transform() -> Transform3D:
	var main = get_tree().current_scene
	if main != null and main.has_method("spawn_transform"):
		var xf: Transform3D = main.spawn_transform(body, home, 0.0)
		var up := xf.basis.y
		var h: Dictionary = body.raycast_density(xf.origin + up * 6.0, xf.origin - up * 30.0, 0.5, true)
		if not h.is_empty():
			xf.origin = h["position"]
		return xf
	return Transform3D(Basis(), body.global_position + Vector3.LEFT * (float(body.radius) + 2.0))


## A point on the planet `arc` m (along the surface) from the base, at angle `phi` around it.
func around_base(arc: float, phi: float) -> Vector3:
	var c: Vector3 = body.global_position
	var bdir := (base_xf.origin - c).normalized()
	var a := arc / maxf(float(body.radius), 1.0)
	var d := (bdir * cos(a) + (base_xf.basis.x * cos(phi) + base_xf.basis.z * sin(phi)) * sin(a)).normalized()
	return c + d * (float(body.radius) + float(body.surface_height_at(c + d * float(body.radius))))


## Where bot `i` (re)appears: a golden-angle spiral around the base out to AI_SPAWN_RADIUS (~8 m
## apart for 70 bots), slightly above the ground (it drops onto the real, dug ground).
func respawn_xf(i: int) -> Transform3D:
	var n := maxi(Balance.BOT_COUNT, 1)
	var arc := Balance.AI_SPAWN_RADIUS * sqrt((float(i % n) + 0.5) / float(n))
	var p := around_base(arc, float(i) * 2.39996)
	var up: Vector3 = (p - body.global_position).normalized()
	var h: Dictionary = body.raycast_density(p + up * 8.0, p - up * 30.0, 0.5, true)
	if not h.is_empty():
		p = h["position"]
	var x := up.cross(base_xf.basis.z)
	if x.length_squared() < 1e-4:
		x = up.cross(Vector3.RIGHT)
	x = x.normalized()
	return Transform3D(Basis(x, up, x.cross(up)), p + up * 0.5)


func _think() -> void:
	cannons = cannons.filter(func(c): return is_instance_valid(c) and not c.is_destroyed)
	flaks = flaks.filter(func(f): return is_instance_valid(f) and not f.is_destroyed)
	if skiff != null and (not is_instance_valid(skiff) or skiff.is_queued_for_deletion() or not skiff.is_inside_tree()):
		_skiff_lost()
	_assign_roles()
	_raid_think()


# =================================================================================================
# Pool, income, structures
# =================================================================================================

func add_material(d: float) -> void:
	material = maxf(material + d, 0.0)


func spend(cost: float) -> bool:
	if material + 0.001 < cost:
		return false
	material -= cost
	return true


## Team income for `dt` s: every digging bot counts, the total is capped.
func _income(dt: float) -> void:
	var n := 0
	for b in bots:
		if is_instance_valid(b) and b.is_digging():
			n += 1
	add_material(minf(Balance.TEAM_INCOME_CAP, float(n) * Balance.DRILL_MAX_RATE * Balance.AI_GATHER_MULT) * dt)


func build_cost(kind: String) -> float:
	match kind:
		"flak":
			return Balance.FLAK_COST
		"skiff":
			return skiff_cost
	return Balance.CANNON_COST


func build_radius(kind: String) -> float:
	match kind:
		"flak":
			return Balance.FLAK_FOOTPRINT
		"skiff":
			return maxf(skiff_half.x, skiff_half.z)
	return Balance.CANNON_FOOTPRINT


## The next structure (counting the ones on the way): cannon and Uçaksavar alternately up to the
## caps. "" when complete.
func next_build() -> String:
	var nc: int = cannons.size() + int(pending["cannon"])
	var nf: int = flaks.size() + int(pending["flak"])
	if nc >= Balance.AI_MAX_CANNONS and nf >= Balance.AI_MAX_FLAKS:
		return ""
	if nc == 0:
		return "cannon"
	if nf < Balance.AI_MAX_FLAKS and (nf < nc or nc >= Balance.AI_MAX_CANNONS):
		return "flak"
	if nc < Balance.AI_MAX_CANNONS:
		return "cannon"
	return "flak"


## An engineer may start building `kind` (at most AI_MAX_BUILDERS at once).
func claim_build(kind: String) -> bool:
	if int(pending["cannon"]) + int(pending["flak"]) >= Balance.AI_MAX_BUILDERS:
		return false
	if kind == "cannon" or kind == "flak":
		pending[kind] = int(pending[kind]) + 1
	return true


func release_build(kind: String) -> void:
	if pending.has(kind):
		pending[kind] = maxi(int(pending[kind]) - 1, 0)


## May the team fire a shell now (the team-wide pace; slower while saving for structures)?
func may_fire() -> bool:
	var gap := Balance.AI_TEAM_FIRE_GAP * (2.0 if next_build() != "" else 1.0)
	return Time.get_ticks_msec() - last_shot_ms > int(gap * 1000.0)


## The engineer puts a structure of `kind` at xf (material already paid).
func spawn_structure(kind: String, xf: Transform3D) -> Node3D:
	var scene: Node = get_tree().current_scene
	match kind:
		"flak":
			var f: Node3D = Flak.spawn(scene, body, xf, team, true)
			flaks.append(f)
			return f
		"skiff":
			if _skiff_script == null:
				return null
			var sk: Node3D = _skiff_script.new()
			sk.set("team", team)
			sk.set_meta("team", team)
			sk.transform = xf
			scene.add_child(sk)
			sk.add_to_group("war_structure")
			sk.set_meta("footprint_r", build_radius("skiff"))
			if sk.has_method("place"):
				sk.place(body, xf)
			BuildFx.assemble(scene, xf, skiff_half, Color(1.0, 0.45, 0.3))
			skiff = sk
			skiff_pad = xf
			_skiff_hp = -1.0
			return sk
	var c: Node3D = Cannon.spawn(scene, body, xf, team, true)
	cannons.append(c)
	return c


# =================================================================================================
# Roles
# =================================================================================================

func _assign_roles() -> void:
	var avail: Array = []
	for b in bots:
		if not is_instance_valid(b) or not b.is_inside_tree() or b.is_dead() or is_raiding(b):
			continue
		avail.append(b)
	if avail.is_empty():
		return
	var n := avail.size()
	var want_eng := maxi(1, int(round(float(n) * Balance.ROLE_ENGINEER_SHARE)))
	var want_min := int(round(float(n) * Balance.ROLE_MINER_SHARE))
	want_min = mini(want_min, n - want_eng)
	# Keep current roles where the counts allow, fill the rest by index order.
	var engs: Array = []
	var mins: Array = []
	for b in avail:
		if b.role == Bot.ROLE_ENGINEER and engs.size() < want_eng:
			engs.append(b)
	for b in avail:
		if b.role == Bot.ROLE_MINER and mins.size() < want_min and not engs.has(b):
			mins.append(b)
	for b in avail:
		if engs.size() >= want_eng:
			break
		if not engs.has(b) and not mins.has(b):
			engs.append(b)
	for b in avail:
		if mins.size() >= want_min:
			break
		if not engs.has(b) and not mins.has(b):
			mins.append(b)
	for b in avail:
		if engs.has(b):
			b.set_role(Bot.ROLE_ENGINEER)
		elif mins.has(b):
			b.set_role(Bot.ROLE_MINER)
		else:
			b.set_role(Bot.ROLE_RAIDER)


## A bot was attacked at `threat`: the AI_HELP_MAX nearest idle allies within AI_HELP_RANGE come.
func call_help(from_bot: Node3D, threat: Vector3) -> void:
	var cands: Array = []
	for b in bots:
		if b == from_bot or not is_instance_valid(b) or b.is_dead() or not b.is_inside_tree() or not b.is_idle():
			continue
		var d: float = b.global_position.distance_to(from_bot.global_position)
		if d < Balance.AI_HELP_RANGE:
			cands.append([d, b])
	cands.sort_custom(func(a, c): return a[0] < c[0])
	for k in mini(cands.size(), Balance.AI_HELP_MAX):
		cands[k][1].help_call(threat)


func on_bot_died(b: Node3D) -> void:
	raiders.erase(b)
	_release_fx(b)


# =================================================================================================
# Budgets / LOD (4 Hz)
# =================================================================================================

func _lod_update() -> void:
	var cam := get_viewport().get_camera_3d()
	var cp: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	var live: Array = []
	for b in bots:
		if not is_instance_valid(b) or not b.is_inside_tree():
			continue
		var d: float = b.global_position.distance_to(cp)
		b.cam_dist = d
		b.lod = 0 if d < Balance.AI_LOD_NEAR else (1 if d < Balance.AI_LOD_MID else 2)
		if not b.is_dead() and not b.is_aboard():
			live.append([d, b])
	live.sort_custom(func(a, c): return a[0] < c[0])
	# Lights and voices: the nearest few.
	for k in live.size():
		var b = live[k][1]
		b.set_light(k < Balance.AI_LIGHT_MAX)
		b.tok_audio = k < Balance.AI_VOICE_MAX
	# Shooters: the nearest bots that see the player.
	var shooters := 0
	for e in live:
		var b = e[1]
		var ok: bool = b.wants_to_shoot() and shooters < Balance.AI_MAX_SHOOTERS
		b.tok_shoot = ok
		if ok:
			shooters += 1
	# Dig FX: the nearest digging bots get the pooled DigFx.
	var diggers: Array = []
	for e in live:
		if e[1].is_digging():
			diggers.append(e[1])
	var want_fx: Array = diggers.slice(0, Balance.AI_FX_MAX)
	for slot in _fx_pool:
		if slot["bot"] != null and (not is_instance_valid(slot["bot"]) or not want_fx.has(slot["bot"])):
			_free_slot(slot)
	for b in want_fx:
		if b.get_fx() != null:
			continue
		for slot in _fx_pool:
			if slot["bot"] == null:
				slot["bot"] = b
				b.set_fx(slot["fx"])
				break
	# Real brushes: the 2 nearest diggers + rotating slots among the rest.
	var now := Time.get_ticks_msec()
	var holders: Array = diggers.slice(0, mini(2, Balance.AI_MAX_BRUSHES))
	_brush_rot = _brush_rot.filter(func(e): return is_instance_valid(e[0]) and e[0].is_digging() and now < int(e[1]) and not holders.has(e[0]))
	var rot_slots := Balance.AI_MAX_BRUSHES - holders.size()
	while _brush_rot.size() < rot_slots:
		var pick: Node3D = null
		var tries := diggers.size()
		while tries > 0 and pick == null:
			tries -= 1
			var c = diggers[randi() % diggers.size()]
			if not holders.has(c) and not _brush_rot.any(func(e): return e[0] == c):
				pick = c
		if pick == null:
			break
		_brush_rot.append([pick, now + int(Balance.AI_BRUSH_SLOT * 1000.0)])
	for b in bots:
		if is_instance_valid(b):
			b.tok_brush = holders.has(b) or _brush_rot.any(func(e): return e[0] == b)


func _free_slot(slot: Dictionary) -> void:
	var b = slot["bot"]
	if b != null and is_instance_valid(b):
		b.set_fx(null)
	(slot["fx"] as Node3D).call("set_working", false)
	slot["bot"] = null


func _release_fx(b: Node3D) -> void:
	for slot in _fx_pool:
		if slot["bot"] == b:
			_free_slot(slot)


## A density line-of-sight march may run this physics frame (round-robin budget).
func take_los() -> bool:
	if _los_left <= 0:
		return false
	_los_left -= 1
	return true


## How many cover candidates (of `want`) a bot may test this frame.
func take_cover_eval(want: int) -> int:
	var n := mini(want, _cover_left)
	_cover_left -= n
	return n


## Keeps at most AI_RAGDOLL_MAX ragdolls simulating: the oldest freezes in its pose.
func add_ragdoll(r: Node) -> void:
	_ragdolls = _ragdolls.filter(func(x): return is_instance_valid(x) and not x.is_queued_for_deletion())
	_ragdolls.append(r)
	while _ragdolls.size() > Balance.AI_RAGDOLL_MAX:
		var old = _ragdolls.pop_front()
		freeze_ragdoll(old)


## Stops a ragdoll's physics; the astronaut keeps the last pose until its bot respawns.
func freeze_ragdoll(r) -> void:
	if r == null or not is_instance_valid(r):
		return
	_ragdolls.erase(r)
	if r.has_method("begin_getup") and not r.bodies.is_empty():
		r.begin_getup(null, 0.0)


# =================================================================================================
# Shared dust puffs (one GPUParticles3D for every far / FX-less digging bot)
# =================================================================================================

## A small pool of one-shot dust bursts, reused round-robin (no per-puff nodes).
func _build_dust() -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = DigFx.soft_texture()
	var q := QuadMesh.new()
	q.size = Vector2(1.4, 1.4)
	q.material = mat
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0.0)])
	for i in DUST_POOL:
		var p := CPUParticles3D.new()
		p.one_shot = true
		p.emitting = false
		p.amount = 5
		p.lifetime = 2.0
		p.explosiveness = 0.85
		p.local_coords = false
		p.mesh = q
		p.direction = Vector3.UP
		p.spread = 35.0
		p.initial_velocity_min = 0.6
		p.initial_velocity_max = 1.6
		p.damping_min = 0.5
		p.damping_max = 1.2
		p.gravity = Vector3.ZERO
		p.scale_amount_min = 0.7
		p.scale_amount_max = 1.5
		p.color_ramp = g
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		p.emission_sphere_radius = 0.5
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.top_level = true
		add_child(p)
		_dust_pool.append(p)


## A puff of dust at `pos` (up = the local up) for a digging bot without the full FX.
func dust_puff(pos: Vector3, up: Vector3, col: Color) -> void:
	if _dust_pool.is_empty():
		return
	var p: CPUParticles3D = _dust_pool[_dust_i]
	_dust_i = (_dust_i + 1) % _dust_pool.size()
	var x := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	p.global_transform = Transform3D(Basis(x, up, x.cross(up)), pos)
	p.color = col
	p.restart()


# =================================================================================================
# Raids (deferred: Balance.RAIDS_ENABLED)
# =================================================================================================

func is_raiding(b: Node3D) -> bool:
	return raid != RAID_NONE and raid != RAID_BUILD and raiders.has(b)


## "" (not on a raid), "board", "aboard", "site", "return".
func raid_phase(b: Node3D) -> String:
	if not is_raiding(b):
		return ""
	match raid:
		RAID_BOARD:
			return "board"
		RAID_SITE:
			return "site"
		RAID_RETURN:
			return "return"
	return "aboard"


func wants_skiff() -> bool:
	return raid == RAID_BUILD and (skiff == null or not is_instance_valid(skiff)) and _skiff_script != null


func raid_digger() -> Node3D:
	for b in raiders:
		if is_instance_valid(b) and not b.is_dead():
			return b
	return null


## The rival skiff while it flies toward us (HUD warning), else null.
func inbound_skiff() -> Node3D:
	if raid == RAID_OUT and skiff != null and is_instance_valid(skiff):
		return skiff
	return null


func report_dig(dist: float) -> void:
	raid_dig_dist = maxf(dist, 0.0)
	_dig_report_ms = Time.get_ticks_msec()


func raid_retreat() -> void:
	if raid == RAID_SITE:
		_retreat = true


func skiff_under_fire(s: Node3D, _pos: Vector3) -> void:
	if s == skiff:
		_skiff_threat_ms = Time.get_ticks_msec()


func _alive_raiders() -> Array:
	return raiders.filter(func(b): return is_instance_valid(b) and not b.is_dead())


func _all_aboard(rs: Array) -> bool:
	for b in rs:
		if not b.is_aboard():
			return false
	return true


func _any_aboard(rs: Array) -> bool:
	for b in rs:
		if b.is_aboard():
			return true
	return false


func _set_raid(r: int) -> void:
	raid = r
	_raid_t = 0.0
	if r == RAID_NONE:
		_last_raid_end = _match_t
		raiders.clear()
		_retreat = false


func _raid_think() -> void:
	if not Balance.RAIDS_ENABLED:
		return
	match raid:
		RAID_NONE:
			if not _skiff_ok or _match_t < Balance.RAID_FIRST_AFTER or _match_t - _last_raid_end < Balance.RAID_MIN_INTERVAL:
				return
			if cannons.is_empty() or flaks.is_empty():
				return
			var rs: Array = []
			for b in bots:
				if is_instance_valid(b) and b.is_inside_tree() and not b.is_dead() and b.role == Bot.ROLE_RAIDER:
					rs.append(b)
					if rs.size() >= 2:
						break
			if rs.is_empty():
				return
			if skiff != null and is_instance_valid(skiff) and Game.dominant_body(skiff.global_position) == body:
				raiders = rs
				_set_raid(RAID_BOARD)
			elif skiff == null and material >= skiff_cost + Balance.AI_RESERVE:
				_set_raid(RAID_BUILD)
		RAID_BUILD:
			if skiff != null and is_instance_valid(skiff):
				_set_raid(RAID_NONE)
				_last_raid_end = _match_t - Balance.RAID_MIN_INTERVAL
			elif _raid_t > 120.0:
				_set_raid(RAID_NONE)
		RAID_BOARD:
			var rs := _alive_raiders()
			if rs.is_empty() or skiff == null:
				_abort_raid()
				return
			if _all_aboard(rs) or (_raid_t > 40.0 and _any_aboard(rs)):
				raid_land = _pick_landing()
				if raid_land == Vector3.INF:
					_abort_raid()
					return
				raiders = rs.filter(func(b): return b.is_aboard())
				skiff.ai_fly_to(raid_land, true)
				_set_raid(RAID_OUT)
				if Game.hud:
					Game.hud.show_message("Rakip mekiği kalktı!", 2.5)
			elif _raid_t > 75.0:
				_abort_raid()
		RAID_OUT:
			if skiff == null:
				return
			var arrived: bool = skiff.ai_arrived() if skiff.has_method("ai_arrived") else false
			if arrived or _raid_t > 120.0:
				for b in _alive_raiders():
					if b.is_aboard():
						b.exit_skiff()
				_retreat = false
				_skiff_hp = -1.0
				_set_raid(RAID_SITE)
		RAID_SITE:
			var rs := _alive_raiders()
			raiders = rs
			if rs.is_empty():
				_set_raid(RAID_NONE)
				return
			if skiff == null:
				return
			var threatened := Time.get_ticks_msec() - _skiff_threat_ms < 4000
			var h = skiff.get("hp")
			if h is float:
				if _skiff_hp >= 0.0 and h < _skiff_hp - 0.5:
					threatened = true
				_skiff_hp = h
			var pl = Game.player
			if pl != null and is_instance_valid(pl) and not pl.is_dead() \
					and pl.global_position.distance_to(skiff.global_position) < 22.0:
				threatened = true
			if _retreat or threatened or _raid_t > Balance.RAID_MAX_TIME:
				_set_raid(RAID_RETURN)
				raiders = rs
		RAID_RETURN:
			var rs := _alive_raiders()
			if skiff == null:
				return
			if rs.is_empty():
				_set_raid(RAID_NONE)
				return
			if _all_aboard(rs) or (_raid_t > 45.0 and _any_aboard(rs)):
				raiders = rs.filter(func(b): return b.is_aboard())
				skiff.ai_fly_to(skiff_pad.origin, true)
				_set_raid(RAID_BACK)
		RAID_BACK:
			if skiff == null:
				return
			var arrived2: bool = skiff.ai_arrived() if skiff.has_method("ai_arrived") else false
			if arrived2 or _raid_t > 150.0:
				for b in _alive_raiders():
					if b.is_aboard():
						b.exit_skiff()
				_set_raid(RAID_NONE)


func _abort_raid() -> void:
	for b in _alive_raiders():
		if b.is_aboard():
			b.exit_skiff()
	_set_raid(RAID_NONE)


func _skiff_lost() -> void:
	skiff = null
	for b in _alive_raiders():
		if b.is_aboard():
			b.die_aboard()
	if raid == RAID_SITE or raid == RAID_RETURN:
		_set_raid(RAID_SITE)
		_retreat = false
	elif raid != RAID_NONE:
		_set_raid(RAID_NONE)
	if Game.hud:
		Game.hud.show_message("Rakip mekiği yok edildi!", 2.5)


func _pick_landing() -> Vector3:
	var c: Vector3 = home.global_position
	var ref := _our_base()
	var rdir := (ref - c).normalized()
	var t1 := rdir.cross(Vector3.UP)
	if t1.length_squared() < 1e-4:
		t1 = rdir.cross(Vector3.RIGHT)
	t1 = t1.normalized()
	var t2 := rdir.cross(t1).normalized()
	var to_rival := (body.global_position - c).normalized()
	var surf_r := float(home.radius)
	var eye := ref + rdir * 2.0
	var best := Vector3.INF
	var best_s := -INF
	for i in 16:
		for dist in [Balance.RAID_LAND_MIN, (Balance.RAID_LAND_MIN + Balance.RAID_LAND_MAX) * 0.5, Balance.RAID_LAND_MAX]:
			var phi := TAU * float(i) / 16.0
			var a: float = float(dist) / surf_r
			var d := (rdir * cos(a) + (t1 * cos(phi) + t2 * sin(phi)) * sin(a)).normalized()
			var h: Dictionary = home.raycast_density(c + d * (surf_r + 40.0), c + d * (surf_r - 40.0), 1.0, true)
			if h.is_empty():
				continue
			var p: Vector3 = h["position"]
			var n: Vector3 = h["normal"]
			if n.dot(d) < cos(deg_to_rad(20.0)):
				continue
			var near_struct := false
			for s in get_tree().get_nodes_in_group("war_structure"):
				if (s as Node3D).global_position.distance_to(p) < 14.0:
					near_struct = true
					break
			if near_struct:
				continue
			var score := d.dot(to_rival) * 25.0 - float(dist) * 0.05
			if not Ballistics.segment_hit(eye, p + d * 2.5).is_empty():
				score += 100.0
			if score > best_s:
				best_s = score
				best = p
	return best


func _our_base() -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for s in get_tree().get_nodes_in_group("war_structure"):
		if Game.team_of(s) == "home" and Game.dominant_body((s as Node3D).global_position) == home:
			sum += (s as Node3D).global_position
			n += 1
	if n > 0:
		return sum / float(n)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and Game.dominant_body(pl.global_position) == home:
		return pl.global_position
	var main = get_tree().current_scene
	if main != null and main.has_method("spawn_transform"):
		var xf: Transform3D = main.spawn_transform(home, body, 0.0)
		return xf.origin
	return home.global_position + (body.global_position - home.global_position).normalized() * float(home.radius)


## Debug line, e.g. "640 m³ · 3 top · 1 uçaksavar · 70 bot".
func status() -> String:
	var alive := 0
	for b in bots:
		if is_instance_valid(b) and not b.is_dead():
			alive += 1
	return "%d m³ · %d top · %d uçaksavar · %d bot · baskın: %s" % [int(material), cannons.size(), flaks.size(), alive, RAID_NAMES[raid]]
