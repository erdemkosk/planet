extends Node
## The rival team (child of the scene root, group "war_rival_team"): Balance.BOT_COUNT bots
## (scripts/war/ai_rival.gd) sharing ONE material pool, the team's structures and its aim learning,
## plus the budgets that keep 70 bots affordable.
##
## Roles (by share of the living bots, re-assigned every second, sticky): ROLE_ENGINEER_SHARE
## engineers (at least 1; AI_MAX_BUILDERS build at a time, one per cannon fires, others repair or
## dig), ROLE_MINER_SHARE miners, the rest guards ("Muhafız"; raiders when Balance.RAIDS_ENABLED).
## Bots spawn a few at a time over BOT_SPAWN_TIME s on a spiral around the base (AI_SPAWN_SPACING apart)
## and respawn there in waves (2026-10-07: on_bot_died -> RespawnShip.enqueue_dead, scripts/war/respawn_waves.gd).
## Build order: cannon and Uçaksavar alternately up to AI_MAX_CANNONS / AI_MAX_FLAKS; destroyed
## structures drop out of the lists, so the engineers rebuild them.
## Economy: the pool earns min(TEAM_INCOME_CAP, digging bots × DRILL_MAX_RATE × AI_GATHER_MULT)
## m³/s; shells at most one per AI_TEAM_FIRE_GAP s team-wide.
##
## Budgets (the "LOD manager", 4 Hz, by distance to the active camera):
##   bot.lod             0 near (< AI_LOD_NEAR, the AI_NEAR_MAX nearest), 1 mid (< AI_LOD_MID, the
##                       AI_MID_MAX nearest), 2 far: think / move / pose rates
##   bot.sep             crowd avoidance: pairs closer than AI_SEPARATION and bots inside a
##                       structure footprint get pushed apart (O(n²), 4 Hz)
##   lights              the AI_LIGHT_MAX nearest bots keep their helmet lamp and muzzle flash light
##   voices              the AI_VOICE_MAX nearest bots may play sounds
##   dig FX              a pool of AI_FX_MAX DigFx goes to the nearest digging bots; the others get
##                       dust puffs from a small pool of reused one-shot bursts (dust_puff)
##   brushes             AI_MAX_BRUSHES bots really carve the terrain (2 nearest diggers + 2 rotating
##                       every AI_BRUSH_SLOT s); the rest dig with animation / FX only
##   shooters            AI_MAX_SHOOTERS bots (nearest with the player in sight) may fire at him
##   take_los()          AI_LOS_PER_FRAME density line-of-sight marches per physics frame
##   take_cover_eval()   AI_COVER_EVALS_PER_FRAME cover candidates per physics frame
##   ragdolls            AI_RAGDOLL_MAX live ones; older and settled corpses freeze in place
##   call_help()         at most AI_HELP_MAX allies answer
## Skiff raids (Balance.RAIDS_ENABLED, on since 2026-10-05; the skiff's AI pilot: skiff.gd): see
## _raid_think and "Skiff raids: crew, variant, timing, upkeep" at the end.
##   team.material, team.cannons, team.flaks, team.inbound_skiff() (HUD), team.raid_dig_dist (HUD)
## Drop-pod raids (on, Balance.POD_RAIDS_ENABLED): crews fired at our planet from a cannon in a
## DropPod; see the "Drop-pod raids" section at the end.

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
var pending := {"cannon": 0, "flak": 0, "buster": 0}   # structures an engineer is on the way to build
var skiff: Node3D = null
var skiff_pad := Transform3D()
# Shared cannon aim learning (all engineers).
var aim_err := Balance.AI_AIM_ERROR_START
var correction := Vector3.ZERO
var last_shot_ms := -1000000
# Skiff raids.
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
	_wx_process(delta)                         # AI use of the new weapons (end of file)
	_foothold_process(delta)                   # our structures on their planet (end of file)
	_pod_process(delta)                        # drop-pod raids at us (end of file)
	_dg_process(delta)                         # digging tactics, the base pieces (end of file)
	_vn_process(delta)                         # prospecting rich veins / meteor cores (end of file)
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
	_raid_load_armed()                         # the Silahlı Mekik variant (Skiff raids, end of file)


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


## Where bot `i` (re)appears: a golden-angle spiral around the base, AI_SPAWN_SPACING apart
## (radius grows with the count), slightly above the ground (it drops onto the real, dug ground).
func respawn_xf(i: int) -> Transform3D:
	var n := maxi(Balance.BOT_COUNT, 1)
	var radius := 3.0 + Balance.AI_SPAWN_SPACING * sqrt(float(n) / PI)
	var arc := radius * sqrt((float(i % n) + 0.5) / float(n))
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
	var got := minf(Balance.TEAM_INCOME_CAP, float(n) * Balance.DRILL_MAX_RATE * Balance.AI_GATHER_MULT) * dt
	add_material(got)
	_lt_carry(got, n)                          # loot: each digger carries its share (end of file)


func build_cost(kind: String) -> float:
	if DgKit.PIECES.has(kind):
		return DgKit.cost_of(kind)             # a base piece (Digging tactics, end of file)
	match kind:
		"flak":
			return Balance.FLAK_COST
		"skiff":
			return skiff_cost
		"buster":
			return Balance.BUSTER_COST
	return Balance.CANNON_COST


func build_radius(kind: String) -> float:
	if DgKit.PIECES.has(kind):
		return DgKit.radius_of(kind)           # a base piece (Digging tactics, end of file)
	match kind:
		"flak":
			return Balance.FLAK_FOOTPRINT
		"skiff":
			return maxf(skiff_half.x, skiff_half.z)
		"buster":
			return Balance.BUSTER_FOOTPRINT
	return Balance.CANNON_FOOTPRINT


## The next structure (counting the ones on the way): cannon and Uçaksavar alternately up to the
## caps. "" when complete.
func next_build() -> String:
	var nc: int = cannons.size() + int(pending["cannon"])
	var nf: int = flaks.size() + int(pending["flak"])
	if nc >= Balance.AI_MAX_CANNONS and nf >= Balance.AI_MAX_FLAKS:
		var bk := _bk_next_build()             # turrets, a Sığınak Modülü (Digging tactics, end of file)
		return bk if bk != "" else _wx_next_build()   # the Delici Top after the base (end of file)
	if nc == 0:
		return "cannon"
	if nf < Balance.AI_MAX_FLAKS and (nf < nc or nc >= Balance.AI_MAX_CANNONS):
		return "flak"
	if nc < Balance.AI_MAX_CANNONS:
		return "cannon"
	return "flak"


## An engineer may start building `kind` (at most AI_MAX_BUILDERS at once).
func claim_build(kind: String) -> bool:
	if int(pending["cannon"]) + int(pending["flak"]) + int(pending.get("buster", 0)) >= Balance.AI_MAX_BUILDERS:
		return false
	if kind == "cannon" or kind == "flak" or kind == "buster":
		pending[kind] = int(pending[kind]) + 1
	return true


func release_build(kind: String) -> void:
	if pending.has(kind):
		pending[kind] = maxi(int(pending[kind]) - 1, 0)


## May the team fire a shell now (the team-wide pace; slower while saving for structures)?
func may_fire() -> bool:
	# Saving for the base halves the pace; saving for the Delici Top (built last) does not.
	var nb := next_build()
	var gap := Balance.AI_TEAM_FIRE_GAP * (2.0 if nb != "" and nb != "buster" else 1.0)
	return Time.get_ticks_msec() - last_shot_ms > int(gap * 1000.0)


## The engineer puts a structure of `kind` at xf (material already paid).
func spawn_structure(kind: String, xf: Transform3D) -> Node3D:
	if DgKit.PIECES.has(kind):
		return DgKit.spawn(kind, team, xf, body, true)   # a base piece (Digging tactics, end of file)
	var scene: Node = get_tree().current_scene
	match kind:
		"flak":
			var f: Node3D = Flak.spawn(scene, body, xf, team, true)
			flaks.append(f)
			return f
		"skiff":
			if _skiff_script == null:
				return null
			var sk: Node3D = _raid_skiff_script().new()     # (armed or plain: Skiff raids, end of file)
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
		"buster":
			return _wx_spawn_buster(scene, xf)
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
	# From 3 bots up keep at least one guard (3 bots: 1 engineer, 1 miner, 1 guard).
	want_min = mini(want_min, n - want_eng - (1 if n >= 3 else 0))
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
	_pod_on_bot_died(b)                        # a pod crew member / gunner (end of file)
	_dg_on_bot_died(b)                         # its dig task (Digging tactics, end of file)
	preload("res://scripts/war/respawn_ship.gd").enqueue_dead(b)   # respawn: its team's next wave (respawn_waves.gd)


# =================================================================================================
# Budgets / LOD (4 Hz)
# =================================================================================================

func _lod_update() -> void:
	var cam := get_viewport().get_camera_3d()
	var cp: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	var others: Array = get_tree().get_nodes_in_group("net_player")
	var live: Array = []
	for b in bots:
		if not is_instance_valid(b) or not b.is_inside_tree():
			continue
		var d: float = b.global_position.distance_to(cp)
		for rp in others:                  # multiplayer co-op: the other player counts as a camera too
			d = minf(d, b.global_position.distance_to((rp as Node3D).global_position))
		b.cam_dist = d
		b.lod = 2
		if not b.is_dead() and not b.is_aboard():
			live.append([d, b])
	live.sort_custom(func(a, c): return a[0] < c[0])
	# LOD by distance and rank: a crowd around the camera cannot all run at full rate.
	for k in live.size():
		var d: float = live[k][0]
		var b = live[k][1]
		if d < Balance.AI_LOD_NEAR and k < Balance.AI_NEAR_MAX:
			b.lod = 0
		elif d < Balance.AI_LOD_MID and k < Balance.AI_MID_MAX:
			b.lod = 1
	_separate(live)
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
	_wx_lod_tick()                             # interceptor brushes, grenade warnings / dodges (end of file)


## Crowd avoidance (4 Hz): every pair of living bots closer than AI_SEPARATION pushes apart, and a
## bot inside a structure's footprint (+ AI_STRUCT_CLEARANCE) is pushed out. O(n²) over ~70 bots:
## ~2.4k distance checks per update (~1 ms in GDScript, every 0.25 s).
func _separate(live: Array) -> void:
	var n := live.size()
	var pos: Array = []
	var push: Array = []
	for e in live:
		pos.append((e[1] as Node3D).global_position)
		push.append(Vector3.ZERO)
	var r := Balance.AI_SEPARATION
	var r2 := r * r
	for i in n:
		var pi: Vector3 = pos[i]
		for j in range(i + 1, n):
			var dv: Vector3 = pi - (pos[j] as Vector3)
			var d2 := dv.length_squared()
			if d2 < r2:
				var d := sqrt(d2)
				var dir := dv / d if d > 0.01 else Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1)).normalized()
				var k := (r - d) / r * 2.5
				push[i] = (push[i] as Vector3) + dir * k
				push[j] = (push[j] as Vector3) - dir * k
	var structs: Array = []
	for s in get_tree().get_nodes_in_group("war_structure") + get_tree().get_nodes_in_group("poi_obstacle"):   # (+ combat-area walls / wrecks, poi.gd)
		if s is Node3D and Game.dominant_body((s as Node3D).global_position) == body:
			structs.append([(s as Node3D).global_position, float(s.get_meta("footprint_r", 3.0)) + Balance.AI_STRUCT_CLEARANCE])
	for i in n:
		var pi: Vector3 = pos[i]
		for st in structs:
			var dv: Vector3 = pi - (st[0] as Vector3)
			var rr: float = st[1]
			var d := dv.length()
			if d < rr:
				var dir := dv / d if d > 0.01 else Vector3.RIGHT
				push[i] = (push[i] as Vector3) + dir * (rr - d + 0.5) * 2.0
		(live[i][1]).sep = (push[i] as Vector3).limit_length(4.0)


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
# Skiff raids (Balance.RAIDS_ENABLED; crew, variant, timing, upkeep: the end of the file)
# =================================================================================================

func is_raiding(b: Node3D) -> bool:
	return (raid != RAID_NONE and raid != RAID_BUILD and raiders.has(b)) or _pod_has(b)   # (+ drop pods)


## "" (not on a raid), "board", "aboard", "site", "return"; drop pods (end of file): "gunner",
## "muster", "aboard", "site".
func raid_phase(b: Node3D) -> String:
	if _pod_has(b):
		return _pod_phase_of(b)
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
	var sd := _dg_sapper_digger()             # the sapper while it tunnels (Digging tactics, end of file)
	if sd != null:
		return sd
	for b in raiders:
		if is_instance_valid(b) and not b.is_dead():
			return b
	return _pod_digger()                       # a landed drop-pod crew's digger (end of file)


## The rival skiff while it flies toward us (HUD warning), else null.
func inbound_skiff() -> Node3D:
	if raid == RAID_OUT and skiff != null and is_instance_valid(skiff):
		return skiff
	return null


func report_dig(dist: float) -> void:
	raid_dig_dist = maxf(dist, 0.0)
	_dig_report_ms = Time.get_ticks_msec()


## A hurt raider (b: who; null = the team) calls the skiff raid home. Drop-pod crews never flee.
func raid_retreat(b: Node3D = null) -> void:
	if raid == RAID_SITE and (b == null or raiders.has(b)):
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
	_raid_phase_hook(r)                        # a raid that flew pushes the next drop pod (end of file)
	raid = r
	_raid_t = 0.0
	if r == RAID_NONE:
		_last_raid_end = _match_t
		raiders.clear()
		_retreat = false


func _raid_think() -> void:
	if not Balance.RAIDS_ENABLED:
		return
	_raid_upkeep()                             # capture, repairs, variant, stranded crews (end of file)
	match raid:
		RAID_NONE:
			# (timing, pods, crew and variant: "Skiff raids" at the end of the file)
			if not _skiff_ok or cannons.is_empty() or flaks.is_empty():
				return
			if skiff == null:
				if _raid_build_ok():
					_set_raid(RAID_BUILD)
				return
			if not is_instance_valid(skiff) or Game.dominant_body(skiff.global_position) != body or not _raid_launch_ok():
				return
			var rs := _raid_pick_crew()
			if rs.is_empty():
				return
			raiders = rs
			_set_raid(RAID_BOARD)
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
			if _raid_out_abort():                  # badly hit / no landing: back home (end of file)
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
	_raid_lost_t = _match_t                    # (rebuilt after RAID_SKIFF_REBUILD s)
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
	var lr := _dg_land_range()                 # (a sapper's raid lands farther out: Digging tactics, end of file)
	for i in 16:
		for dist in [lr.x, (lr.x + lr.y) * 0.5, lr.y]:
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
			score += _cp_land_bonus(p)          # Bölge kontrolü: land by one of our zones (end of file)
			if not Ballistics.segment_hit(eye, p + d * 2.5).is_empty():
				score += 100.0
			if score > best_s:
				best_s = score
				best = p
	_dg_landing_picked(best)
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


# =================================================================================================
# AI use of the new weapons (El bombası, Delici Top, Sondaj torpidosu, torpedo interception)
# =================================================================================================
# Hooks into the code above: _process -> _wx_process, _lod_update -> _wx_lod_tick, next_build ->
# _wx_next_build; build_cost / build_radius / claim_build / spawn_structure / pending know "buster".
# The bot side is the same section at the end of ai_rival.gd; constants in balance.gd "AI use of
# the new weapons".
#   Grenades: a bot asks wx_grenade_ok() before it solves an arc and wx_grenade_take() (the pool,
#     the team-wide gap) before its wind-up; wx_throw_grenade() launches it from ONE shared
#     Projectiles (scripts/items/projectiles.gd "hand", team "rival", not player-owned). At 4 Hz the
#     local player hears "El bombası!" when one lands within AI_GRENADE_WARN_RANGE of him, and bots
#     near a live grenade of the player sprint off.
#   Delici Top: AI_MAX_BUSTERS built after the base (busters; destroyed ones drop out and are
#     rebuilt); every AI_WX_SCAN s, once loaded and paced (AI_BUSTER_FIRE_GAP), one free engineer
#     gets the task "buster" (aimed at wx_buster_target()).
#   Torpedoes: from AI_TORPEDO_FIRST_AFTER s on, every AI_TORPEDO_GAP s a free engineer (else a
#     guard) gets the task "torpedo" while the pool affords TORPEDO_COST + AI_RESERVE.
#   Interception: each of our torpedoes burrowing into this planet gets AI_INTERCEPTORS bots (guards
#     first, then miners, nearest to the drill head; task "intercept"); they keep a real brush
#     whatever AI_MAX_BRUSHES says. "Rakip torpidonu kazıyor!" once per torpedo.
# Multiplayer (the team runs on the host / single player only): RivalTeam.events() carries
#   grenade_thrown(pos, vel, fuse, cfg, team)   every bot grenade (replay: Projectiles.launch(pos,
#                                               vel, "hand", MODE_BOUNCE, fuse, cfg))
#   bot_action(index, action)                   bot `index` starts "grenade" (wind-up),
#                                               "torpedo_aim", "torpedo_fire" or "intercept"
#   intercept_started(torpedo)                  once per torpedo (the callout above)
#   bot_react(index, kind, dir, strength, bone) a bot's hit reaction (ai_rival.gd "Hit reactions",
#                                               scripts/player/hit_reactor.gd): kind "flinch" /
#                                               "stagger" / "knockdown" / "getup"; dir × strength =
#                                               the knockback / launch velocity (getup: dir = facing,
#                                               strength = its duration s); bone = the part struck
#                                               hardest ("head", "chest", "pelvis", "uarm0", "thigh1",
#                                               ...; puppet: astronaut.apply_hit(dir, k, bone ==
#                                               "head", astronaut.part_point(bone)))
# Torpedoes report through Torpedo.events().launched, the buster's penetrator through
# BusterShell.fire (Net.world.on_shell_fired); an intercepted torpedo dies through its own
# take_damage / brush damage on the host.

const WxProjectiles := preload("res://scripts/items/projectiles.gd")
const WxBuster := preload("res://scripts/war/buster.gd")
const WxSnd := preload("res://scripts/audio/snd_lib.gd")

## Signals of the team's weapon use (see above).
class WeaponEvents extends RefCounted:
	signal grenade_thrown(pos: Vector3, vel: Vector3, fuse: float, cfg: Dictionary, team: String)
	signal bot_action(index: int, action: String)
	signal intercept_started(torpedo: Node3D)
	signal bot_react(index: int, kind: String, dir: Vector3, strength: float, bone: String)
	# Drop-pod raids (end of file).
	signal pod_fired(id: int, from: Vector3, vel: Vector3)
	signal pod_landed(id: int, pos: Vector3)
	signal pod_destroyed(id: int, pos: Vector3)
	# Reactions and body language (ai_rival.gd; the puppets mirror them, scripts/war/bot_cues.gd):
	# gesture = astronaut.gesture(kind, dir) ("look" = look_dir(dir, 3 s)), dir in the bot's own space;
	# callout = BotCues.line_text(line, variant, arg) over its head + radio; alert = BotCues.alert
	# ("seen" / "marked"); mood = astronaut.set_mood(wound, hunch), sent on change (0.1 steps).
	signal bot_gesture(index: int, kind: String, dir: Vector3)
	signal bot_callout(index: int, line: String, variant: int, arg: int)
	signal bot_alert(index: int, kind: String)
	signal bot_mood(index: int, wound: float, hunch: float)

static var _wx_events: WeaponEvents

var busters: Array = []                  # the Delici Top(s)
var _wx_scan_t := 0.0
var _wx_proj: Node3D = null              # the team's grenades in flight (created on the first throw)
var _wx_gren_ms := -1000000              # last grenade (team-wide gap)
var _wx_solve_ms := -1000000             # last arc solve (team-wide)
var _wx_warned := {}                     # grenade node id -> true: the player was warned
var _wx_audio: Array = []
var _wx_audio_i := 0
var _wx_streams := {}
var _wx_icpt: Array = []                 # interceptors: [bot, torpedo, slot]
var _wx_called := {}                     # torpedo instance id -> true: callout done
var _wx_torp_bot = null                  # the bot with the launcher
var _wx_torp_next: float = Balance.AI_TORPEDO_FIRST_AFTER
var _wx_torp_start := 0.0
var _wx_gunner = null                    # the bot manning the Delici Top
var _wx_gunner_start := 0.0
var _wx_buster_ms := -1000000            # last penetrator
var _wx_buster_skip_ms := 0


static func events() -> WeaponEvents:
	if _wx_events == null:
		_wx_events = WeaponEvents.new()
	return _wx_events


## A bot (index) starts a visible weapon action (events().bot_action, for the multiplayer puppets).
func wx_bot_action(bot_index: int, action: String) -> void:
	events().bot_action.emit(bot_index, action)


## Every AI_WX_SCAN s: the busters list, the interceptors, the torpedo launch, the buster crew.
func _wx_process(delta: float) -> void:
	_wx_scan_t -= delta
	if _wx_scan_t > 0.0:
		return
	_wx_scan_t = Balance.AI_WX_SCAN
	busters = busters.filter(func(c): return is_instance_valid(c) and not c.is_destroyed)
	_wx_intercept_update()
	_wx_torpedo_update()
	_wx_buster_update()


## 4 Hz (end of _lod_update): interceptors keep a real brush; grenade warnings and dodges.
func _wx_lod_tick() -> void:
	for e in _wx_icpt:
		if is_instance_valid(e[0]):
			e[0].tok_brush = true
	_wx_grenade_watch()
	_wx_dodge_player_grenades()


## A bot that may take a weapon task now (working, no task, not building / firing / repairing).
func _wx_free(b) -> bool:
	return is_instance_valid(b) and b.is_inside_tree() and not b.is_dead() and not is_raiding(b) and b.wx_available()


## A bot's weapon task ended (ok: it fired); the timers move on.
func wx_task_done(b: Node3D, kind: String, ok: bool) -> void:
	var now := Time.get_ticks_msec()
	match kind:
		"torpedo":
			if _wx_torp_bot == b:
				_wx_torp_bot = null
				_wx_torp_next = _match_t + (Balance.AI_TORPEDO_GAP if ok else Balance.AI_TORPEDO_RETRY)
		"buster":
			if _wx_gunner == b:
				_wx_gunner = null
				if ok:
					_wx_buster_ms = now
				else:
					_wx_buster_skip_ms = now + int(Balance.AI_BUSTER_RETRY * 1000.0)
		"intercept":
			_wx_icpt = _wx_icpt.filter(func(e): return e[0] != b)


## The surface point of our planet facing theirs, plus the shared adjust-fire correction (where the
## shells go by default; a torpedo landing anywhere on our planet burrows to our core).
func wx_near_side() -> Vector3:
	var dir: Vector3 = (body.global_position - home.global_position).normalized()
	var r: float = float(home.radius) + float(home.surface_height_at(home.global_position + dir * float(home.radius)))
	return home.global_position + dir * r + correction


## A positional one-shot for the bots' weapon use ("pin", "whoosh", "launch") from a small pool.
func wx_play_at(key: String, pos: Vector3, vol_db := 0.0) -> void:
	if _wx_audio.is_empty():
		_wx_streams = {"pin": WxSnd.rand("foley/pin", 1.06, 1.0), "whoosh": WxSnd.rand("whoosh/whoosh", 1.1, 1.5),
				"launch": WxSnd.rand("weap/rpg", 1.05, 1.0)}
		for i in 3:
			var p := AudioStreamPlayer3D.new()
			p.unit_size = 10.0
			p.max_distance = 260.0
			add_child(p)
			_wx_audio.append(p)
	var st = _wx_streams.get(key)
	if st == null:
		return
	var a: AudioStreamPlayer3D = _wx_audio[_wx_audio_i]
	_wx_audio_i = (_wx_audio_i + 1) % _wx_audio.size()
	a.stream = st
	a.volume_db = vol_db
	a.global_position = pos
	a.play()


# --- Grenades ---------------------------------------------------------------------------------------

## May a bot solve a grenade arc now (the team-wide gap, the pool, one solve per
## AI_GRENADE_SOLVE_GAP s)? True books the solve slot.
func wx_grenade_ok() -> bool:
	var now := Time.get_ticks_msec()
	if now - _wx_gren_ms < int(Balance.AI_GRENADE_TEAM_GAP * 1000.0):
		return false
	if now - _wx_solve_ms < int(Balance.AI_GRENADE_SOLVE_GAP * 1000.0):
		return false
	if material - Balance.AI_RESERVE < Balance.GRENADE_COST:
		return false
	_wx_solve_ms = now
	return true


## Pays for a grenade (GRENADE_COST) and starts the team-wide gap. False when the pool is short.
func wx_grenade_take() -> bool:
	if material - Balance.AI_RESERVE < Balance.GRENADE_COST or not spend(Balance.GRENADE_COST):
		return false
	_wx_gren_ms = Time.get_ticks_msec()
	return true


## The Explosion config of a bot grenade: the player's numbers, the rival's side, not player-owned,
## no direct-hit damage (projectiles.gd would credit the player with a hit marker for it).
static func wx_grenade_cfg() -> Dictionary:
	return {"radius": Balance.GRENADE_RADIUS, "damage": Balance.GRENADE_DAMAGE, "impulse": Balance.GRENADE_IMPULSE,
			"self_mult": 1.0, "crater": Balance.GRENADE_CRATER, "direct": 0.0, "player_owned": false, "team": "rival"}


## Bot `b` lets go of a grenade at pos with vel (fuse s left): the shared Projectiles, with the
## thrower's collider excluded from its flight test.
func wx_throw_grenade(b: Node3D, pos: Vector3, vel: Vector3, fuse: float) -> void:
	if _wx_proj == null or not is_instance_valid(_wx_proj):
		_wx_proj = WxProjectiles.new()
		_wx_proj.name = "RivalGrenades"
		add_child(_wx_proj)
	var col = b.get("_col") if b != null and is_instance_valid(b) else null
	_wx_proj.player = col if col is CollisionObject3D else null
	var cfg := wx_grenade_cfg()
	cfg["team"] = team
	_wx_proj.launch(pos, vel, "hand", WxProjectiles.MODE_BOUNCE, fuse, cfg)
	events().grenade_thrown.emit(pos, vel, fuse, cfg, team)


## "El bombası!" for the local player when a bot grenade lands (its first bounce / at rest) within
## AI_GRENADE_WARN_RANGE of him, once per grenade.
func _wx_grenade_watch() -> void:
	if _wx_proj == null or not is_instance_valid(_wx_proj) or int(_wx_proj.in_flight()) == 0:
		if not _wx_warned.is_empty():
			_wx_warned.clear()
		return
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or pl.is_dead() or Game.hud == null:
		return
	var pp: Vector3 = (pl as Node3D).global_position
	for g in _wx_proj.get("_list"):
		var n = g.get("node")
		if not is_instance_valid(n):
			continue
		var id: int = (n as Node3D).get_instance_id()
		if _wx_warned.has(id) or (int(g.get("bounces", 0)) == 0 and not bool(g.get("rest", false))):
			continue
		if (n as Node3D).global_position.distance_to(pp) < Balance.AI_GRENADE_WARN_RANGE:
			_wx_warned[id] = true
			Game.hud.show_message("El bombası!", 1.6)


## Bots within GRENADE_RADIUS + AI_GRENADE_FLEE of a live grenade of the player (his hand_action's
## Projectiles, read only; usually none or one) sprint away from it.
func _wx_dodge_player_grenades() -> void:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl):
		return
	var ha = pl.get("hand_action")
	if ha == null or not is_instance_valid(ha):
		return
	var pj = ha.get("proj")
	if pj == null or not is_instance_valid(pj) or int(pj.in_flight()) == 0:
		return
	var r := Balance.GRENADE_RADIUS + Balance.AI_GRENADE_FLEE
	var src: Vector3 = (pl as Node3D).global_position + (pl as Node3D).global_transform.basis.y * 1.2
	for g in pj.get("_list"):
		var n = g.get("node")
		if not is_instance_valid(n):
			continue
		var gp: Vector3 = (n as Node3D).global_position
		if Game.dominant_body(gp) != body:
			continue
		for b in bots:
			if is_instance_valid(b) and not b.is_dead() and not b.is_aboard() and b.global_position.distance_to(gp) < r:
				b.wx_dodge_grenade(gp, src)


# --- Delici Top -------------------------------------------------------------------------------------

## next_build() once the cannons and Uçaksavar stand: a Delici Top up to AI_MAX_BUSTERS, else "".
func _wx_next_build() -> String:
	var live := 0
	for c in busters:
		if is_instance_valid(c) and not c.is_destroyed:
			live += 1
	if live + int(pending.get("buster", 0)) < Balance.AI_MAX_BUSTERS:
		return "buster"
	return ""


func _wx_spawn_buster(scene: Node, xf: Transform3D) -> Node3D:
	var c: Node3D = WxBuster.spawn(scene, body, xf, team, true)
	busters.append(c)
	return c


## The standing Delici Top (or null).
func wx_buster() -> Node3D:
	for c in busters:
		if is_instance_valid(c) and not c.is_destroyed:
			return c
	return null


## Gives the loaded buster to the nearest free engineer when the pace allows (AI_BUSTER_FIRE_GAP,
## twice that while saving for a structure) and the pool pays BUSTER_SHELL_COST + AI_RESERVE.
func _wx_buster_update() -> void:
	var now := Time.get_ticks_msec()
	if _wx_gunner != null:
		var g = _wx_gunner
		if not is_instance_valid(g) or g.is_dead() or not g.is_idle() or wx_buster() == null \
				or _match_t - _wx_gunner_start > Balance.AI_BUSTER_TASK_TIME:
			if is_instance_valid(g):
				g.wx_clear_task()
			_wx_gunner = null
			_wx_buster_skip_ms = now + int(Balance.AI_BUSTER_RETRY * 1000.0)
		return
	var bu := wx_buster()
	if bu == null or not bu.ready_to_fire() or now < _wx_buster_skip_ms:
		return
	var gap := Balance.AI_BUSTER_FIRE_GAP * (2.0 if next_build() != "" else 1.0)
	if now - _wx_buster_ms < int(gap * 1000.0):
		return
	if material - Balance.AI_RESERVE < Balance.BUSTER_SHELL_COST:
		return
	var best = null
	var best_d := INF
	for b in bots:
		if not _wx_free(b) or b.role != Bot.ROLE_ENGINEER:
			continue
		var d: float = b.global_position.distance_to(bu.global_position)
		if d < best_d:
			best_d = d
			best = b
	if best != null:
		_wx_gunner = best
		_wx_gunner_start = _match_t
		best.wx_assign("buster")


## Where the Delici Top aims: the ground above our core on the side facing them (the near-side point
## and six points AI_BUSTER_TARGET_ARC m around it), the deepest crater there (a penetrator down an
## old hole gets closer to the core), plus the shared adjust-fire correction.
func wx_buster_target() -> Vector3:
	var c: Vector3 = home.global_position
	var d0 := (body.global_position - c).normalized()
	var r0 := float(home.radius)
	var t1 := d0.cross(Vector3.UP)
	if t1.length_squared() < 1e-4:
		t1 = d0.cross(Vector3.RIGHT)
	t1 = t1.normalized()
	var t2 := d0.cross(t1).normalized()
	var a := Balance.AI_BUSTER_TARGET_ARC / maxf(r0, 1.0)
	var best: Vector3 = c + d0 * (r0 + float(home.surface_height_at(c + d0 * r0)))
	var best_r := INF
	for k in 7:
		var d := d0
		if k > 0:
			var phi := TAU * float(k - 1) / 6.0
			d = (d0 * cos(a) + (t1 * cos(phi) + t2 * sin(phi)) * sin(a)).normalized()
		# (down to the core: the old "r0 - 26" stopped half way at R 60)
		var h: Dictionary = home.raycast_density(c + d * (r0 + 14.0), c + d * (Balance.CORE_RADIUS + 1.0), 0.6, true)
		if h.is_empty():
			continue
		var p: Vector3 = h["position"]
		var rr := p.distance_to(c)
		if rr < best_r - 0.5:                  # the near-side point wins ties
			best_r = rr
			best = p
	return best + correction


# --- Torpedoes at us --------------------------------------------------------------------------------

## From AI_TORPEDO_FIRST_AFTER s on, every AI_TORPEDO_GAP s: the free engineer nearest the base
## (else a guard) takes the launcher, while the pool affords TORPEDO_COST + AI_RESERVE.
func _wx_torpedo_update() -> void:
	if _wx_torp_bot != null:
		var b = _wx_torp_bot
		if not is_instance_valid(b) or b.is_dead() or not b.is_idle() \
				or _match_t - _wx_torp_start > Balance.AI_TORPEDO_TASK_TIME:
			if is_instance_valid(b):
				b.wx_clear_task()
			_wx_torp_bot = null
			_wx_torp_next = _match_t + Balance.AI_TORPEDO_RETRY
		return
	if not Balance.AI_TORPEDO_LAUNCHES:
		return                                 # off while the AI cannot reach us (balance.gd)
	if _match_t < _wx_torp_next or material < Balance.TORPEDO_COST + Balance.AI_RESERVE:
		return
	if not _wx_home_core_alive():
		return
	var pick = null
	var best_d := INF
	for pass_i in 2:
		var want_role: int = Bot.ROLE_ENGINEER if pass_i == 0 else Bot.ROLE_RAIDER
		for b in bots:
			if not _wx_free(b) or b.role != want_role:
				continue
			var d: float = b.global_position.distance_to(base_xf.origin)
			if d < best_d:
				best_d = d
				pick = b
		if pick != null:
			break
	if pick == null:
		return
	_wx_torp_bot = pick
	_wx_torp_start = _match_t
	pick.wx_assign("torpedo")


func _wx_home_core_alive() -> bool:
	for c in get_tree().get_nodes_in_group("war_core"):
		if c.get("body") == home and not bool(c.get("destroyed")):
			return true
	return false


# --- Our torpedoes in their planet -------------------------------------------------------------------

## Each of our torpedoes burrowing into this planet gets AI_INTERCEPTORS bots: guards first, then
## miners, nearest to the drill head first. A finished torpedo (dead, done) or a bot that died / went
## to fight releases them (wx_clear_task: one deep in its hole climbs out first).
func _wx_intercept_update() -> void:
	var live: Array = []
	for t in get_tree().get_nodes_in_group("war_torpedo"):
		if is_instance_valid(t) and str(t.get("team")) != team and t.get("body") == body and t.is_burrowing():
			live.append(t)
	var keep: Array = []
	for e in _wx_icpt:
		var b = e[0]
		if is_instance_valid(b) and not b.is_dead() and b.is_idle() and live.has(e[1]):
			keep.append(e)
		elif is_instance_valid(b):
			b.wx_clear_task()
	_wx_icpt = keep
	if live.is_empty():
		if not _wx_called.is_empty():
			_wx_called.clear()
		return
	for t in live:
		var n := 0
		var slots := {}
		for e in _wx_icpt:
			if e[1] == t:
				n += 1
				slots[int(e[2])] = true
		if n >= Balance.AI_INTERCEPTORS:
			continue
		var tip: Vector3 = t.tip_position()
		for want_role in [Bot.ROLE_RAIDER, Bot.ROLE_MINER]:
			var cands: Array = []
			for b in bots:
				if _wx_free(b) and b.role == want_role:
					cands.append([(b as Node3D).global_position.distance_to(tip), b])
			cands.sort_custom(func(x, y): return x[0] < y[0])
			for c in cands:
				if n >= Balance.AI_INTERCEPTORS:
					break
				var slot := 0
				while slots.has(slot):
					slot += 1
				slots[slot] = true
				_wx_icpt.append([c[1], t, slot])
				c[1].wx_assign("intercept", t, slot)
				n += 1
			if n >= Balance.AI_INTERCEPTORS:
				break


## An interceptor reached its torpedo and starts digging: "Rakip torpidonu kazıyor!" once per torpedo.
func wx_intercept_started(b: Node3D, t: Node3D) -> void:
	if b != null and is_instance_valid(b):
		events().bot_action.emit(int(b.get("index")), "intercept")
	if t == null or not is_instance_valid(t):
		return
	var id := t.get_instance_id()
	if _wx_called.has(id):
		return
	_wx_called[id] = true
	if Game.hud:
		Game.hud.show_message("Rakip torpidonu kazıyor!", 2.5)
	events().intercept_started.emit(t)


# =================================================================================================
# Enemy footholds: structures the enemy built on THIS planet (Sondaj Kulesi, Uçaksavar)
# =================================================================================================
# Hook: _process -> _foothold_process. Every AI_FOOTHOLD_SCAN s the enemy structures standing on
# this planet (group "war_structure", another team; parked skiffs are left alone: the player's ride
# home) are listed, a Sondaj Kulesi that is still arming (is_arming(): its torpedo is not in the
# ground yet) first, then the rest nearest the base first. Each gets up to AI_FOOTHOLD_RIG_ATTACKERS
# (arming rig) / AI_FOOTHOLD_ATTACKERS bots: free guards nearest to it, and for an arming rig also
# miners. A bot with a foothold (ai_rival.gd `foothold`, checked in _think_work after its weapon
# task) walks into rifle range and shoots it (_raid_attack, AI_RIFLE_STRUCT_DAMAGE); a bot that
# leaves work (a fight, a weapon task) or dies is released and replaced. "Rakip kuleye saldırıyor!"
# once per arming rig. Host / single player only, like the rest of the team.

var _fh_t := 0.0
var _fh: Array = []                      # [bot, structure]
var _fh_called := {}                     # structure instance id -> true: callout done


func _foothold_process(delta: float) -> void:
	_fh_t -= delta
	if _fh_t > 0.0:
		return
	_fh_t = Balance.AI_FOOTHOLD_SCAN
	# The enemy structures on this planet: [sort key, structure, arming].
	var targets: Array = []
	for s in get_tree().get_nodes_in_group("war_structure"):
		if not (s is Node3D) or s.is_in_group("skiff") or s.has_meta("build_preview"):
			continue
		if Game.team_of(s) == team or s.get("is_destroyed") == true:
			continue
		if Game.dominant_body((s as Node3D).global_position) != body:
			continue
		var arming: bool = s.has_method("is_arming") and bool(s.call("is_arming"))
		var d: float = (s as Node3D).global_position.distance_to(base_xf.origin)
		targets.append([d - (10000.0 if arming else 0.0), s, arming])
	# Release bots whose target is gone or who left work.
	var keep: Array = []
	for e in _fh:
		var b = e[0]
		var s = e[1]
		var live := false
		for tg in targets:
			if tg[1] == s:
				live = true
				break
		if live and is_instance_valid(b) and not b.is_dead() and b.is_idle() and b.wx_available():
			keep.append(e)
		elif is_instance_valid(b) and b.foothold == s:
			b.foothold = null
	_fh = keep
	if targets.is_empty():
		if not _fh_called.is_empty():
			_fh_called.clear()
		return
	targets.sort_custom(_fh_sort)
	for tg in targets:
		var s: Node3D = tg[1]
		var arming: bool = tg[2]
		var cap: int = Balance.AI_FOOTHOLD_RIG_ATTACKERS if arming else Balance.AI_FOOTHOLD_ATTACKERS
		var n := 0
		for e in _fh:
			if e[1] == s:
				n += 1
		if n >= cap:
			continue
		var roles: Array = [Bot.ROLE_RAIDER, Bot.ROLE_MINER] if arming else [Bot.ROLE_RAIDER]
		for want_role in roles:
			var cands: Array = []
			for b in bots:
				if _fh_free(b) and b.role == want_role:
					cands.append([(b as Node3D).global_position.distance_to(s.global_position), b])
			cands.sort_custom(_fh_sort)
			for c in cands:
				if n >= cap:
					break
				var bot = c[1]
				bot.foothold = s
				_fh.append([bot, s])
				n += 1
			if n >= cap:
				break
		if arming and n > 0:
			var id := s.get_instance_id()
			if not _fh_called.has(id):
				_fh_called[id] = true
				if Game.hud and Game.team_of(s) == "home":
					Game.hud.show_message("Rakip sondaj kulene saldırıyor!", 2.5)


func _fh_sort(x: Array, y: Array) -> bool:
	return float(x[0]) < float(y[0])


## A bot that may be sent at a foothold: working, no weapon task, not already sent, not on a raid.
func _fh_free(b) -> bool:
	if not is_instance_valid(b) or not b.is_inside_tree() or b.is_dead() or is_raiding(b):
		return false
	if b.foothold != null and is_instance_valid(b.foothold):
		return false
	return b.is_idle() and b.wx_available()


# =================================================================================================
# Drop-pod raids (Çıkarma kapsülü: raiders fired at our planet from a cannon)
# =================================================================================================
# Hooks above (one line each): _process -> _pod_process; is_raiding / raid_phase / raid_digger /
# on_bot_died know the pod crews and the gunner; WeaponEvents carries pod_fired / pod_landed /
# pod_destroyed. The bot side: ai_rival.gd "Drop-pod raids"; the pod: scripts/war/drop_pod.gd;
# constants: balance.gd "Çıkarma kapsülü" (POD_*). Independent of RAIDS_ENABLED (the skiff raids
# stay deferred). Every AI_WX_SCAN s:
#   idle     from POD_FIRST_AFTER s on, POD_INTERVAL_MIN..MAX s after the last launch: when our core
#            stands, the pool pays POD_COST + AI_RESERVE, a cannon is ready and unclaimed, a free
#            engineer can fire it, the team can spare a crew (POD_CREW_FIRST, from the
#            POD_CREW_LATE_FROM-th pod on POD_CREW_LATE; free guards first, then miners, nearest the
#            cannon; POD_HOME_KEEP living bots at home stay there; short of a full crew it adds up to
#            POD_REINFORCE_MAX bots to the team, once) and _pick_landing finds a spot RAID_LAND_MIN..
#            MAX m from our base (hidden from it preferred): the gunner claims the cannon and lays it
#            with the cannon solver (POD_AIM_ERROR_K of the team's aim error), the crew run to the
#            cannon and climb in (hidden, aboard it). Anything missing: again in POD_RETRY s.
#   muster   the gunner fires once everyone is aboard (after POD_MUSTER_TIME with whoever is in;
#            +20 s, a lost cannon or gunner, nobody aboard: called off, the crew climbs out).
#            pod_launch pays, shows the cannon's shot (cannon.net_fire_fx: recoil, smoke, boom and
#            its reload; cannon.gd untouched) and fires a DropPod from the muzzle with the crew
#            riding it; it counts as the team's shell for the pace (last_shot_ms).
#            events().pod_fired(id, from, vel).
#   flight   war_hud.gd warns "DÜŞMAN ÇIKARMASI GELİYOR!"; our Uçaksavar / skiff gun may destroy it:
#            the crew die aboard (they respawn at home), events().pod_destroyed(id, pos).
#   landed   events().pod_landed(id, pos); the doors blow off and the crew jump out around the pod
#            (bot.pod_exit: the bots' teleport-restart spawn path onto _true_ground). They stay
#            raiders until they die (raid_phase "site": ai_rival.gd _raid_on_site / _pod_site; the
#            first of them digs the shaft): no retreat, no fleeing.
# Host / single player only, like the rest of the team.

const DropPod := preload("res://scripts/war/drop_pod.gd")

var pods_fired := 0
var _pod_t := 0.0
var _pod_next: float = Balance.POD_FIRST_AFTER
var _pod_mustering := false
var _pod_start := 0.0
var _pod_gunner = null                   # the engineer firing it (untyped: may be freed)
var _pod_cannon = null
var _pod_land := Vector3.INF
var _pod_board: Array = []               # crew mustering / aboard the cannon
var _pod_crew: Array = []                # crews in flight / on our planet
var _pod_live: Array = []                # pods in flight
var _pod_seq := 0
var _pod_added := 0                      # reinforcement bots added


## A bot on pod duty (gunner, mustering, aboard, on our planet).
func _pod_has(b) -> bool:
	return b != null and (b == _pod_gunner or _pod_board.has(b) or _pod_crew.has(b))


## raid_phase for pod duty: "gunner", "muster", "aboard" (the cannon or the pod), "site".
func _pod_phase_of(b) -> String:
	if b == _pod_gunner:
		return "gunner"
	var ph := str(b.pod_phase())
	if ph == "flight":
		return "aboard"
	return ph


## The landed crews' digger: the first living crew member on our planet.
func _pod_digger() -> Node3D:
	for b in _pod_crew:
		if is_instance_valid(b) and not b.is_dead() and str(b.pod_phase()) == "site":
			return b
	return null


## Raiders on our planet (skiff raid + landed pod crews): ai_rival.gd _raid_on_site's `solo`.
func raid_crew_size() -> int:
	var n := raiders.size()
	for b in _pod_crew:
		if is_instance_valid(b) and not b.is_dead() and str(b.pod_phase()) == "site":
			n += 1
	return n


## The pods flying at us now.
func inbound_pods() -> Array:
	return _pod_live.filter(func(p): return is_instance_valid(p) and p.is_live())


func _pod_process(delta: float) -> void:
	_pod_t -= delta
	if _pod_t > 0.0:
		return
	_pod_t = Balance.AI_WX_SCAN
	_pod_crew = _pod_crew.filter(func(b): return is_instance_valid(b) and not b.is_dead())
	_pod_live = _pod_live.filter(func(p): return is_instance_valid(p) and p.is_live())
	if _pod_mustering:
		_pod_muster_update()
		return
	if not Balance.POD_RAIDS_ENABLED or _match_t < _pod_next:
		return
	_pod_try_start()


## Everything for a launch (see the header), cheapest checks first; else look again later.
func _pod_try_start() -> void:
	_pod_next = _match_t + Balance.POD_RETRY
	if raid != RAID_NONE:
		return                                 # a skiff raid runs (shared cooldown: "Skiff raids", end of file)
	if material < Balance.POD_COST + Balance.AI_RESERVE or not _wx_home_core_alive():
		return
	var c := _pod_pick_cannon()
	if c == null:
		return
	var gunner = null
	var best_d := INF
	for b in bots:
		if not _wx_free(b) or b.role != Bot.ROLE_ENGINEER:
			continue
		var d: float = (b as Node3D).global_position.distance_to(c.global_position)
		if d < best_d:
			best_d = d
			gunner = b
	if gunner == null:
		return
	var want: int = Balance.POD_CREW_LATE if pods_fired + 1 >= Balance.POD_CREW_LATE_FROM else Balance.POD_CREW_FIRST
	var home_alive := 0
	for b in bots:
		if is_instance_valid(b) and b.is_inside_tree() and not b.is_dead() and not _pod_crew.has(b):
			home_alive += 1
	var crew: Array = []
	for want_role in [Bot.ROLE_RAIDER, Bot.ROLE_MINER]:
		var cands: Array = []
		for b in bots:
			if b != gunner and _wx_free(b) and b.role == want_role and (b.foothold == null or not is_instance_valid(b.foothold)):
				cands.append([(b as Node3D).global_position.distance_to(c.global_position), b])
		cands.sort_custom(_fh_sort)
		for e in cands:
			if crew.size() >= want:
				break
			crew.append(e[1])
	while crew.size() > maxi(home_alive - Balance.POD_HOME_KEEP, 0):
		crew.pop_back()
	# One short of a big crew: a reinforcement joins the team (once), straight into the muster.
	while want > Balance.POD_CREW_FIRST and crew.size() == want - 1 and _pod_added < Balance.POD_REINFORCE_MAX:
		_spawn_bot(bots.size())
		_pod_added += 1
		crew.append(bots[bots.size() - 1])
	if crew.size() < Balance.POD_CREW_FIRST:
		return
	var land := _pick_landing()
	if land == Vector3.INF:
		return
	_pod_mustering = true
	_pod_start = _match_t
	_pod_gunner = gunner
	_pod_cannon = c
	_pod_land = land
	_pod_board = crew
	c.set_meta("ai_claim", gunner)
	gunner.pod_assign_gunner(c, land)
	for b in crew:
		b.pod_assign_crew(c)


## A ready cannon nobody else has claimed (the one nearest the base).
func _pod_pick_cannon() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for c in cannons:
		if not is_instance_valid(c) or c.is_destroyed or not c.ready_to_fire():
			continue
		var who = c.get_meta("ai_claim") if c.has_meta("ai_claim") else null
		if who != null and is_instance_valid(who) and not who.is_dead():
			continue
		var d: float = (c as Node3D).global_position.distance_to(base_xf.origin)
		if d < best_d:
			best_d = d
			best = c
	return best


func _pod_muster_update() -> void:
	_pod_board = _pod_board.filter(func(b): return is_instance_valid(b) and not b.is_dead())
	var c = _pod_cannon
	var g = _pod_gunner
	if c == null or not is_instance_valid(c) or c.is_destroyed or g == null or not is_instance_valid(g) or g.is_dead() \
			or _pod_board.is_empty() or _match_t - _pod_start > Balance.POD_MUSTER_TIME + 20.0:
		pod_abort()


## The gunner may fire: everyone mustered is aboard the cannon (after POD_MUSTER_TIME: at least one).
func pod_crew_ready() -> bool:
	var n := 0
	for b in _pod_board:
		if is_instance_valid(b) and not b.is_dead() and str(b.pod_phase()) == "aboard":
			n += 1
	if n == 0:
		return false
	return n >= _pod_board.size() or _match_t - _pod_start > Balance.POD_MUSTER_TIME


## The gunner fires (cannon laid along v, crew aboard): pays, the cannon's shot, the pod with its
## crew riding it. False when it could not (the muster is then called off).
func pod_launch(gunner: Node3D, c: Node3D, v: Vector3) -> bool:
	if not _pod_mustering or gunner != _pod_gunner or c != _pod_cannon or v == Vector3.ZERO:
		return false
	var crew: Array = []
	for b in _pod_board:
		if is_instance_valid(b) and not b.is_dead() and str(b.pod_phase()) == "aboard":
			crew.append(b)
	if crew.is_empty() or material - Balance.AI_RESERVE < Balance.POD_COST or not spend(Balance.POD_COST):
		pod_abort()
		return false
	var dir := v.normalized()
	var from: Vector3 = c.muzzle_position() + dir * 0.6
	var ex: Array = []
	var cb = c.get("_body")
	if cb is CollisionObject3D:
		ex.append((cb as CollisionObject3D).get_rid())
	if c.has_method("net_fire_fx"):
		c.net_fire_fx()                        # the cannon's shot: recoil, flash, smoke, boom, reload
	var scene: Node = get_tree().current_scene if get_tree().current_scene != null else get_parent()
	var pod: Node3D = DropPod.fire(scene, from, v, team, ex, _pod_land)
	_pod_seq += 1
	pod.net_id = _pod_seq
	pod.crew = crew
	pod.landed.connect(_on_pod_landed)
	pod.doors_open.connect(_on_pod_doors)
	pod.destroyed.connect(_on_pod_destroyed)
	for b in crew:
		b.pod_ride(pod)
		_pod_crew.append(b)
	_pod_board = _pod_board.filter(func(b): return not crew.has(b))
	_pod_live.append(pod)
	pods_fired += 1
	last_shot_ms = Time.get_ticks_msec()
	_pod_end_muster()
	_pod_next = _match_t + randf_range(Balance.POD_INTERVAL_MIN, Balance.POD_INTERVAL_MAX)
	events().pod_fired.emit(int(pod.net_id), from, v)
	return true


## Calls the muster off (the gunner found no solution, the cannon / gunner is gone, timeout).
func pod_abort() -> void:
	_pod_end_muster()
	_pod_next = _match_t + Balance.POD_RETRY


## Releases the cannon, the gunner and whoever is still mustering (climbs out of the cannon).
func _pod_end_muster() -> void:
	var c = _pod_cannon
	var g = _pod_gunner
	if c != null and is_instance_valid(c) and c.has_meta("ai_claim") and c.get_meta("ai_claim") == g:
		c.remove_meta("ai_claim")
	_pod_gunner = null
	_pod_cannon = null
	_pod_land = Vector3.INF
	_pod_mustering = false
	var left := _pod_board
	_pod_board = []
	if g != null and is_instance_valid(g):
		g.pod_clear()
	for b in left:
		if is_instance_valid(b):
			b.pod_unboard()


func _on_pod_landed(pod: Node3D, pos: Vector3, _up: Vector3) -> void:
	_pod_live.erase(pod)
	events().pod_landed.emit(int(pod.net_id), pos)
	if Game.hud and Game.dominant_body(pos) == home:
		Game.hud.show_message("Düşman gezegenimize indi!", 2.5)


## The doors are off: the crew jump out around the pod.
func _on_pod_doors(pod: Node3D, pos: Vector3, up: Vector3) -> void:
	var out: Array = []
	for b in pod.crew:
		if is_instance_valid(b) and b.is_aboard() and b.get("aboard") == pod:
			out.append(b)
	for k in out.size():
		out[k].pod_exit(pos, up, k, out.size())


## Shot down (or lost): the crew die aboard.
func _on_pod_destroyed(pod: Node3D, pos: Vector3) -> void:
	_pod_live.erase(pod)
	events().pod_destroyed.emit(int(pod.net_id), pos)
	for b in pod.crew:
		if is_instance_valid(b) and b.is_aboard() and b.get("aboard") == pod:
			b.pod_die(pod.vel)


## A crew member that came down off target (not on our planet) goes back to normal duty.
func pod_release(b: Node3D) -> void:
	_pod_crew.erase(b)
	_pod_board.erase(b)
	if b != null and b.has_method("pod_clear"):
		b.pod_clear()


func _pod_on_bot_died(b: Node3D) -> void:
	if b == _pod_gunner:
		pod_abort()
	_pod_board.erase(b)
	_pod_crew.erase(b)
	if b != null and b.has_method("pod_clear"):
		b.pod_clear()


# =================================================================================================
# Corpses and loot (scripts/war/corpse.gd, scripts/war/loot.gd; the bot side: end of ai_rival.gd)
# =================================================================================================
# Hook above: _income -> _lt_carry. A bot killed drops what it carries (ai_rival.gd _lt_on_death takes
# it out of `material`); a bot walking over a pickup on this planet puts it back (loot.gd _bot_scan ->
# bot.lt_pickup).

## The income of one _income call split over the bots that dug it: each carries its share.
func _lt_carry(got: float, n: int) -> void:
	if n <= 0 or got <= 0.0:
		return
	var share := got / float(n)
	for b in bots:
		if is_instance_valid(b) and b.is_digging() and b.has_method("lt_add_carry"):
			b.lt_add_carry(share)


# =================================================================================================
# Skiff raids: crew, variant, timing, upkeep (2026-10-05; the raid state machine: _raid_think)
# =================================================================================================
# Hooks above (one line each): _load_skiff_script -> _raid_load_armed; spawn_structure "skiff" ->
# _raid_skiff_script; _set_raid -> _raid_phase_hook; _raid_think -> _raid_upkeep, RAID_NONE ->
# _raid_build_ok / _raid_launch_ok / _raid_pick_crew, RAID_OUT -> _raid_out_abort; _skiff_lost ->
# _raid_lost_t; raid_retreat(b) only for skiff raiders (pod crews never flee); _pod_try_start: no
# pod while a skiff raid runs. The skiff's flying: skiff.gd "AI pilot" (+ armed_skiff.gd "AI
# gunner"). Constants: balance.gd "AI pilot and skiff raids" (+ RAID_FIRST_AFTER, RAID_MIN_INTERVAL,
# RAID_MAX_TIME, RAID_RETREAT_HP, RAID_LAND_* in the older raid block).
#   variant   the engineer builds the Silahlı Mekik (armed_skiff.gd, ARMED_BUILD_COST) when the pool
#             pays it + AI_RESERVE, else the plain Mekik (BUILD_COST); re-chosen every second while
#             RAID_BUILD waits (skiff_cost / skiff_half follow), team "rival" (the rival livery).
#             Built on their own planet behind the base (ai_rival.gd _pick_build_spot; balance.gd
#             BUILD_SITE is the player's build tool's rule, "any" for both skiffs anyway).
#   timing    built from RAID_FIRST_AFTER - RAID_BUILD_LEAD s on (and RAID_SKIFF_REBUILD s after the
#             last one was lost / captured), flies from RAID_FIRST_AFTER s on and RAID_MIN_INTERVAL
#             s after the last raid ended, only while the drop pods are quiet (none mustering, in
#             flight or fighting here; the next one due within RAID_POD_MARGIN s). A raid that flew
#             pushes the next pod POD_INTERVAL_MIN s out; no pod is fired while a raid runs.
#   crew      RAID_SKIFF_CREW free bots nearest the skiff (guards, then miners; never pod crew, the
#             pod gunner or a bot sent at a foothold); POD_HOME_KEEP living bots stay home.
#   upkeep    parked at home between raids: repaired RAID_SKIFF_REPAIR hp/s for
#             RAID_SKIFF_REPAIR_COST m³ a hp; a raid needs RAID_SKIFF_MIN_HP of the hull. Captured by
#             the player (single player): given up like a lost one. Bots still aboard a landed skiff
#             with no raid (or on site) climb out.
#   abort     on the way out below RAID_SKIFF_ABORT_HP of the hull, or no landing after 120 s: home
#             with the crew (RAID_BACK).

const ARMED_SKIFF_PATH := "res://scripts/craft/armed_skiff.gd"

var skiff_armed := false                 # the variant the team builds next / built last
var _armed_script: Script = null
var _armed_cost := 0.0
var _armed_half := Vector3(1.5, 1.02, 2.65)
var _plain_cost := 0.0
var _plain_half := Vector3(1.25, 1.02, 2.5)
var _raid_lost_t := -1.0e9
var _raid_flew := false


func _raid_load_armed() -> void:
	_plain_cost = skiff_cost
	_plain_half = skiff_half
	if not ResourceLoader.exists(ARMED_SKIFF_PATH):
		return
	var s = load(ARMED_SKIFF_PATH)
	if not (s is Script) or not (s as Script).can_instantiate():
		return
	_armed_script = s
	_armed_cost = float((s as Script).get_script_constant_map().get("ARMED_BUILD_COST", 600.0))
	_armed_half = s.call("footprint")


## Armed when the pool pays for it (+ the reserve), else plain; skiff_cost / skiff_half follow.
func _raid_pick_variant() -> void:
	skiff_armed = _armed_script != null and material >= _armed_cost + Balance.AI_RESERVE
	skiff_cost = _armed_cost if skiff_armed else _plain_cost
	skiff_half = _armed_half if skiff_armed else _plain_half


func _raid_skiff_script() -> Script:
	return _armed_script if skiff_armed and _armed_script != null else _skiff_script


## The drop pods are quiet: none mustering, flying or fighting here, the next one due soon anyway.
func _raid_pods_quiet() -> bool:
	if _pod_mustering or not _pod_crew.is_empty() or not inbound_pods().is_empty():
		return false
	return _match_t >= _pod_next - Balance.RAID_POD_MARGIN


func _raid_build_ok() -> bool:
	if _match_t < Balance.RAID_FIRST_AFTER - Balance.RAID_BUILD_LEAD or _match_t - _raid_lost_t < Balance.RAID_SKIFF_REBUILD:
		return false
	if _match_t - _last_raid_end < Balance.RAID_MIN_INTERVAL - Balance.RAID_BUILD_LEAD:
		return false
	_raid_pick_variant()
	return material >= skiff_cost + Balance.AI_RESERVE


func _raid_launch_ok() -> bool:
	if _match_t < Balance.RAID_FIRST_AFTER or _match_t - _last_raid_end < Balance.RAID_MIN_INTERVAL or not _raid_pods_quiet():
		return false
	if not bool(skiff.get("landed")) or (skiff.has_method("ai_busy") and skiff.ai_busy()):
		return false
	var h = skiff.get("hp")
	var m = skiff.get("hp_max")
	return not (h is float and m is float) or float(h) >= float(m) * Balance.RAID_SKIFF_MIN_HP


## RAID_SKIFF_CREW free bots nearest the skiff (guards, then miners); POD_HOME_KEEP stay home.
func _raid_pick_crew() -> Array:
	var crew: Array = []
	var home_alive := 0
	for b in bots:
		if is_instance_valid(b) and b.is_inside_tree() and not b.is_dead() and not _pod_crew.has(b):
			home_alive += 1
	var want := mini(Balance.RAID_SKIFF_CREW, home_alive - Balance.POD_HOME_KEEP)
	if want <= 0:
		return crew
	var at: Vector3 = skiff.global_position
	for want_role in [Bot.ROLE_RAIDER, Bot.ROLE_MINER]:
		var cands: Array = []
		for b in bots:
			if not _wx_free(b) or b.role != want_role or _pod_has(b) or crew.has(b):
				continue
			var fh = b.get("foothold")
			if fh != null and is_instance_valid(fh):
				continue
			cands.append([(b as Node3D).global_position.distance_to(at), b])
		cands.sort_custom(_fh_sort)
		for e in cands:
			if crew.size() >= want:
				break
			crew.append(e[1])
	return crew


## _set_raid hook: a raid that flew out pushes the next drop pod back when it ends.
func _raid_phase_hook(r: int) -> void:
	if r == RAID_OUT:
		_raid_flew = true
	elif r == RAID_NONE and _raid_flew:
		_raid_flew = false
		_pod_next = maxf(_pod_next, _match_t + Balance.POD_INTERVAL_MIN)


## Every think (1 Hz): the variant while the build waits, a captured skiff, stranded crews, repairs.
func _raid_upkeep() -> void:
	if raid == RAID_BUILD:
		_raid_pick_variant()
	if skiff == null or not is_instance_valid(skiff):
		return
	if Game.team_of(skiff) != team:
		_raid_skiff_captured()
		return
	var down := bool(skiff.get("landed"))
	if down and (raid == RAID_NONE or raid == RAID_SITE) and skiff.has_method("ai_crew"):
		for b in skiff.ai_crew():
			if is_instance_valid(b) and b.has_method("exit_skiff"):
				b.exit_skiff()
	if raid != RAID_NONE or not down or Game.dominant_body(skiff.global_position) != body:
		return
	var h = skiff.get("hp")
	var m = skiff.get("hp_max")
	if not (h is float and m is float) or float(h) >= float(m) or material <= Balance.AI_RESERVE:
		return
	var add := minf(Balance.RAID_SKIFF_REPAIR, float(m) - float(h))
	if spend(add * Balance.RAID_SKIFF_REPAIR_COST):
		skiff.set("hp", float(h) + add)


## The player took the empty skiff (single player): his now; raiders on our planet stay and fight
## like a lost skiff's crew.
func _raid_skiff_captured() -> void:
	skiff = null
	_raid_lost_t = _match_t
	if raid == RAID_SITE or raid == RAID_RETURN:
		_set_raid(RAID_SITE)
		_retreat = false
	elif raid != RAID_NONE:
		_set_raid(RAID_NONE)


## On the way out: badly hit (RAID_SKIFF_ABORT_HP) or still no landing after 120 s: home with the crew.
func _raid_out_abort() -> bool:
	if bool(skiff.get("landed")) or (skiff.has_method("ai_arrived") and skiff.ai_arrived()):
		return false
	var h = skiff.get("hp")
	var m = skiff.get("hp_max")
	var hurt: bool = h is float and m is float and float(h) < float(m) * Balance.RAID_SKIFF_ABORT_HP
	if not hurt and _raid_t <= 120.0:
		return false
	skiff.ai_fly_to(skiff_pad.origin, true)
	_set_raid(RAID_BACK)
	if Game.hud and hurt:
		Game.hud.show_message("Rakip mekiği geri dönüyor", 2.0)
	return true


# =================================================================================================
# Digging tactics and the rival's base (2026-10-05; the bot side: the same section at the end of
# ai_rival.gd; constants: balance.gd "Digging tactics and the rival's base")
# =================================================================================================
# Hooks above (one line each): _process -> _dg_process; on_bot_died -> _dg_on_bot_died; _pick_landing
# -> _dg_land_range / _dg_landing_picked (a sapper raid lands DG_SAP_LAND_MIN..MAX m out); raid_digger
# -> the sapper first; next_build -> _bk_next_build (after the cannons and Uçaksavar); build_cost /
# build_radius / spawn_structure know the base pieces (BaseKit). Host / single player, like the team.
# Every second:
#   tokens    the carve bucket refills (DG_CARVE_PER_MIN, at most DG_CARVE_BURST): dg_take(n)
#   trapped   bots stuck underground dig themselves out (bot.dg_check_trapped)
#   sapper    a raid landing picked for one: the first raider on site near it gets "sapper" (pop-up
#             behind the nearest cannon / Uçaksavar / turret within DG_SAP_RANGE, else to the core);
#             one at a time, DG_SAPPER_GAP s apart; it is the raid's digger meanwhile
#   counter   the newest fresh enemy dig (TunnelLog) deeper than DG_COUNTER_MIN_DEPTH near the line
#             base -> core (not a burrowing torpedo: the interceptors take those): a free engineer /
#             guard gets "counter", its target follows the enemy head; dg_cave_in fills his tunnel
#   trench    a cannon without one and a free guard: DG_TRENCH_SEGS pits DG_TRENCH_AHEAD m in front
#   ambush    the player's path on this planet (sampled every 3 s): a pit 8-12 m off it, while every player
#             is DG_AMBUSH_FAR m from the spot (up to DG_AMBUSH_MAX at once; guards, then miners)
#   flank     (Kuşatma tüneli, 2026-10-07) a player holding a spot: one or two bots tunnel round his
#             side from where he cannot see them and burst out behind him ("Flank tunnels" below)
#   bunker    no Sığınak Modülü: the engineer digs a bunker behind the cannon cluster (DG_BUNKER_MAX)
#   shield    BK_SHIELD_AFTER cannons, no Çekirdek Kalkanı, the pool pays it + BK_RESERVE: the
#             engineer digs down to the chamber BaseKit.suggest_spot gives and builds it (bk_build_shield)
#   shelling  enemy blasts on this planet (Game.blast): dg_shelling(p), dg_shelter_near(p) (a Sığınak
#             Modülü of ours first, else a dug bunker)
# Base pieces through the normal build (next_build -> the engineer, BaseKit.suggest_spot near
# bk_near(kind), BaseKit.spawn): BK_TURRETS Otomatik Taret, BK_BUNKER_MODULES Sığınak Modülü; BK_LIGHTS
# Işık Direği in its dug rooms (bk_light).

const DgKit := preload("res://scripts/war/base_kit.gd")
const DgLog := preload("res://scripts/war/tunnel_log.gd")
const DgDig := preload("res://scripts/player/dig.gd")

var dg_bunkers: Array = []               # dug bunkers: {"entry", "room"} (world)
var _dg_t := 0.0
var _dg_tokens: float = Balance.DG_CARVE_BURST
var _dg_hooked := false
var _dg_blasts: Array = []               # [pos, msec]: enemy blasts on this planet
var _dg_sapper = null                    # (untyped: may be freed)
var _dg_sapper_land := Vector3.INF
var _dg_land_t := 0.0
var _dg_land_pending := false
var _dg_sap_next: float = Balance.DG_SAPPER_FIRST
var _dg_counter = null
var _dg_counter_next := 0.0
var _dg_trench_next: float = Balance.DG_TRENCH_FIRST
var _dg_ambush_next: float = Balance.DG_AMBUSH_FIRST
var _dg_trail_pts: Array = []            # [pos, match s]: where the player walked on this planet
var _dg_trail_t := 0.0
var _dg_bunker_next: float = Balance.DG_BUNKER_FIRST
var _bk_shield_next := 0.0
var _bk_fail := {}                       # kind -> match s until which it is not asked for again
var _dg_caves: Array = []                # [due msec, point]: cave-in brushes to do


func dg_take(n: int) -> bool:
	if _dg_tokens < float(n):
		return false
	_dg_tokens -= float(n)
	return true


func _dg_process(delta: float) -> void:
	_dg_tokens = minf(_dg_tokens + delta * Balance.DG_CARVE_PER_MIN / 60.0, Balance.DG_CARVE_BURST)
	if not _dg_hooked:
		_dg_hooked = true
		if not Game.blast.is_connected(_dg_on_blast):
			Game.blast.connect(_dg_on_blast)
	if not _dg_caves.is_empty():
		_dg_cave_step()
	_dg_t -= delta
	if _dg_t > 0.0:
		return
	_dg_t = 1.0
	for b in bots:
		if is_instance_valid(b) and b.has_method("dg_check_trapped"):
			b.dg_check_trapped()
	_dg_trail()
	_dg_sapper_scan()
	_dg_counter_scan()
	_dg_flank_scan()                       # Kuşatma tüneli: behind a player who holds a spot (below)
	_dg_trench_scan()
	_dg_ambush_scan()
	_dg_bunker_scan()
	_bk_shield_scan()


func _dg_on_bot_died(b) -> void:
	if b != null and is_instance_valid(b) and b.has_method("dg_clear"):
		b.dg_clear()
	if b == _dg_sapper:
		_dg_sapper = null
		_dg_sap_next = _match_t + Balance.DG_SAPPER_GAP
	if b == _dg_counter:
		_dg_counter = null
		_dg_counter_next = _match_t + Balance.DG_COUNTER_GAP


## A free bot of the first role in `roles` that has one, on this planet, nearest to `near`; fight: also
## one in a fight that cannot see the player (bot.dg_free_fight).
func _dg_pick_bot(roles: Array, near: Vector3, fight := false) -> Node3D:
	for want in roles:
		var best: Node3D = null
		var best_d := INF
		for b in bots:
			if not is_instance_valid(b) or b.is_dead() or b.role != want or not b.has_method("dg_free"):
				continue
			if not (b.dg_free_fight() if fight else (_wx_free(b) and b.dg_free())):
				continue
			if Game.dominant_body((b as Node3D).global_position) != body:
				continue
			var d: float = (b as Node3D).global_position.distance_to(near)
			if d < best_d:
				best_d = d
				best = b
		if best != null:
			return best
	return null


## How many of the team's own structures in `grp` stand.
func _bk_count(grp: String) -> int:
	var n := 0
	for s in get_tree().get_nodes_in_group(grp):
		if Game.team_of(s) == team and s.get("is_destroyed") != true:
			n += 1
	return n


func _dg_cluster() -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for s in cannons + flaks:
		if is_instance_valid(s):
			sum += (s as Node3D).global_position
			n += 1
	return sum / float(n) if n > 0 else base_xf.origin


func _dg_toward_home(p: Vector3) -> Vector3:
	var up: Vector3 = body.up_at(p)
	var t: Vector3 = home.global_position - p
	t -= up * t.dot(up)
	return t.normalized() if t.length_squared() > 1e-4 else up.cross(Vector3.RIGHT).normalized()


## The ground at p (a density ray from above), INF when none or too steep.
func _dg_ground(p: Vector3) -> Vector3:
	var up: Vector3 = body.up_at(p)
	var h: Dictionary = body.raycast_density(p + up * 10.0, p - up * 10.0, 0.4, true)
	if h.is_empty() or (h["normal"] as Vector3).dot(up) < 0.85:
		return Vector3.INF
	return h["position"]


func _dg_near_structure(p: Vector3, margin: float) -> bool:
	for s in get_tree().get_nodes_in_group("war_structure"):
		if s is Node3D and (s as Node3D).global_position.distance_to(p) < float(s.get_meta("footprint_r", 3.0)) + margin:
			return true
	return false


func _dg_player_here() -> bool:
	for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if pl != null and is_instance_valid(pl) and not pl.is_dead() and Game.dominant_body((pl as Node3D).global_position) == body:
			return true
	return false


# --- Shelling -----------------------------------------------------------------------------------------

func _dg_on_blast(pos: Vector3, _radius: float, t: String) -> void:
	if t == team or body == null or Game.dominant_body(pos) != body:
		return
	_dg_blasts.append([pos, Time.get_ticks_msec()])
	if _dg_blasts.size() > 10:
		_dg_blasts.pop_front()


func dg_shelling(p: Vector3) -> bool:
	var now := Time.get_ticks_msec()
	for e in _dg_blasts:
		if now - int(e[1]) < int(Balance.DG_SHELTER_MEM * 1000.0) and (e[0] as Vector3).distance_to(p) < Balance.DG_SHELTER_NEAR:
			return true
	return false


## The nearest shelter within DG_SHELTER_RANGE: a Sığınak Modülü of ours first, else a dug bunker.
## {"entry", "room"} or {}.
func dg_shelter_near(p: Vector3) -> Dictionary:
	var best := {}
	var best_d := Balance.DG_SHELTER_RANGE
	for s in get_tree().get_nodes_in_group("war_bunker"):
		if not (s is Node3D) or Game.team_of(s) != team or s.get("is_destroyed") == true:
			continue
		var sp: Vector3 = (s as Node3D).global_position
		var d := sp.distance_to(p)
		if d < best_d:
			best_d = d
			best = {"entry": sp, "room": sp}
	if not best.is_empty():
		return best
	for e: Dictionary in dg_bunkers:
		var d := (e["entry"] as Vector3).distance_to(p)
		if d < best_d:
			best_d = d
			best = e.duplicate()
	return best


func dg_bunker_done(entry: Vector3, room: Vector3) -> void:
	dg_bunkers.append({"entry": entry, "room": room})


# --- The player's path (ambush) ----------------------------------------------------------------------

func _dg_trail() -> void:
	_dg_trail_t -= 1.0
	if _dg_trail_t > 0.0:
		return
	_dg_trail_t = 3.0
	for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.get("vehicle") != null:
			continue
		var p: Vector3 = (pl as Node3D).global_position
		if Game.dominant_body(p) != body:
			continue
		if _dg_trail_pts.is_empty() or ((_dg_trail_pts[_dg_trail_pts.size() - 1] as Array)[0] as Vector3).distance_to(p) > 4.0:
			_dg_trail_pts.append([p, _match_t])
	while _dg_trail_pts.size() > 60:
		_dg_trail_pts.pop_front()


func _dg_ambush_scan() -> void:
	if _match_t < _dg_ambush_next or _dg_trail_pts.size() < 6:
		return
	_dg_ambush_next = _match_t + Balance.DG_AMBUSH_GAP
	var n_amb := 0
	for b in bots:
		if is_instance_valid(b) and b.has_method("dg_task") and b.dg_task() == "ambush":
			n_amb += 1
	if n_amb >= Balance.DG_AMBUSH_MAX:
		return
	var i := randi() % (_dg_trail_pts.size() - 1)
	var p: Vector3 = (_dg_trail_pts[i] as Array)[0]
	var q: Vector3 = (_dg_trail_pts[i + 1] as Array)[0]
	var up: Vector3 = body.up_at(p)
	var dir := q - p
	dir -= up * dir.dot(up)
	if dir.length_squared() < 0.01:
		dir = up.cross(Vector3.RIGHT)
	var side := up.cross(dir.normalized()).normalized() * (1.0 if randf() < 0.5 else -1.0)
	var spot := _dg_ground(p + side * randf_range(8.0, 12.0))
	if spot == Vector3.INF or _dg_near_structure(spot, 2.0) or _dg_player_near(spot, Balance.DG_AMBUSH_FAR):
		_dg_ambush_next = _match_t + 15.0           # (he is near there: another spot soon)
		return
	var g := _dg_pick_bot([Bot.ROLE_RAIDER, Bot.ROLE_MINER], spot)
	if g != null:
		g.dg_assign("ambush", {"spot": spot, "watch": p})


# --- Sapper -------------------------------------------------------------------------------------------

## _pick_landing: now and then a raid's spot is picked farther out, for a sapper.
func _dg_land_range() -> Vector2:
	_dg_land_pending = false
	if _dg_sapper == null and _dg_sapper_land == Vector3.INF and _match_t >= _dg_sap_next and randf() < Balance.DG_SAPPER_CHANCE:
		_dg_land_pending = true
		return Vector2(Balance.DG_SAP_LAND_MIN, Balance.DG_SAP_LAND_MAX)
	return Vector2(Balance.RAID_LAND_MIN, Balance.RAID_LAND_MAX)


func _dg_landing_picked(p: Vector3) -> void:
	if _dg_land_pending and p != Vector3.INF:
		_dg_sapper_land = p
		_dg_land_t = _match_t
	_dg_land_pending = false


## raid_digger: the sapper while it is at it.
func _dg_sapper_digger() -> Node3D:
	var s = _dg_sapper
	if s != null and is_instance_valid(s) and not s.is_dead() and s.dg_task() == "sapper" and raid_phase(s) == "site":
		return s
	return null


func _dg_sapper_scan() -> void:
	if _dg_sapper != null:
		if not is_instance_valid(_dg_sapper) or _dg_sapper.is_dead() or _dg_sapper.dg_task() != "sapper":
			_dg_sapper = null
			_dg_sap_next = _match_t + Balance.DG_SAPPER_GAP
		return
	if _dg_sapper_land == Vector3.INF:
		return
	if _match_t - _dg_land_t > 150.0:
		_dg_sapper_land = Vector3.INF            # (that raid never came down there)
		return
	for b in bots:
		if not is_instance_valid(b) or b.is_dead() or b.is_aboard() or raid_phase(b) != "site":
			continue
		if not (b.is_idle() or b.dg_free_fight()):
			continue
		if (b as Node3D).global_position.distance_to(_dg_sapper_land) > Balance.DG_SAP_LAND_NEAR or b.dg_task() != "":
			continue
		var s := _dg_sap_target((b as Node3D).global_position)
		var mode := "popup" if s != null and randf() < Balance.DG_SAP_POPUP else "core"
		b.dg_assign("sapper", {"mode": mode, "target": s, "base": _our_base()})
		_dg_sapper = b
		_dg_sapper_land = Vector3.INF
		return


## The structure a pop-up goes for: the nearest enemy cannon / Uçaksavar / turret / Delici Top.
func _dg_sap_target(p: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := Balance.DG_SAP_RANGE
	for grp: String in ["war_cannon", "war_flak", "war_turret", "war_buster"]:
		for s in get_tree().get_nodes_in_group(grp):
			if not (s is Node3D) or Game.team_of(s) == team or s.get("is_destroyed") == true:
				continue
			var d := (s as Node3D).global_position.distance_to(p)
			if d < best_d:
				best_d = d
				best = s
	return best


# --- Counter-tunnelling -------------------------------------------------------------------------------

func _dg_counter_scan() -> void:
	if _dg_counter != null:
		if not is_instance_valid(_dg_counter) or _dg_counter.is_dead() or _dg_counter.dg_task() != "counter":
			_dg_counter = null
			_dg_counter_next = _match_t + Balance.DG_COUNTER_GAP
			return
		var hd := _dg_enemy_head()
		if hd != Vector3.INF:
			_dg_counter.dg_set_head(hd, true)
		return
	if _match_t < _dg_counter_next:
		return
	var head := _dg_enemy_head()
	if head == Vector3.INF:
		return
	var b := _dg_pick_bot([Bot.ROLE_ENGINEER, Bot.ROLE_RAIDER, Bot.ROLE_MINER], head, true)
	if b == null:
		return
	b.dg_assign("counter", {"head": head, "fresh_ms": Time.get_ticks_msec()})
	_dg_counter = b


## The newest enemy dig on this planet that threatens the core: fresh, deep, near the line from the
## base down to the core, not a burrowing torpedo's.
func _dg_enemy_head() -> Vector3:
	var enemy := "home" if team == "rival" else "rival"
	var pts: Array = DgLog.points(body, enemy)
	var c: Vector3 = body.global_position
	var seg: Vector3 = base_xf.origin - c
	var torps: Array = []
	for t in get_tree().get_nodes_in_group("war_torpedo"):
		if is_instance_valid(t) and t.has_method("is_burrowing") and t.is_burrowing() and t.has_method("tip_position"):
			torps.append(t.tip_position())
	for i in range(pts.size() - 1, -1, -1):
		var e: Dictionary = pts[i]
		if float(e["t"]) > Balance.DG_COUNTER_FRESH:
			break
		var p: Vector3 = e["p"]
		var depth := float(body.radius) + float(body.surface_height_at(p)) - p.distance_to(c)
		if depth < Balance.DG_COUNTER_MIN_DEPTH:
			continue
		var tt := clampf((p - c).dot(seg) / maxf(seg.length_squared(), 1e-4), 0.0, 1.0)
		if p.distance_to(c + seg * tt) > Balance.DG_COUNTER_R:
			continue
		var torp := false
		for tp: Vector3 in torps:
			if tp.distance_to(p) < 6.0:
				torp = true
				break
		if not torp:
			return p
	return Vector3.INF


## Any enemy dig on this planet within r of p (the counter-tunneller broke into his tunnel).
func dg_enemy_dug_near(p: Vector3, r: float) -> bool:
	var enemy := "home" if team == "rival" else "rival"
	for e in DgLog.points(body, enemy):
		if (e["p"] as Vector3).distance_to(p) < r:
			return true
	return false


## A grenade went down the enemy tunnel at `at`: in `delay` s his tunnel comes down around it (RAISE
## brushes on his dig points 3..DG_COUNTER_FILL_R m from the blast, never on anyone).
func dg_cave_in(at: Vector3, delay: float) -> void:
	var enemy := "home" if team == "rival" else "rival"
	var due := Time.get_ticks_msec() + int(delay * 1000.0)
	for e in DgLog.points(body, enemy):
		var p: Vector3 = e["p"]
		var d := p.distance_to(at)
		if d > 3.0 and d < Balance.DG_COUNTER_FILL_R:
			_dg_caves.append([due, p])


func _dg_cave_step() -> void:
	var now := Time.get_ticks_msec()
	var keep: Array = []
	var n := 0
	for e in _dg_caves:
		if int(e[0]) > now or n >= 3:
			keep.append(e)
			continue
		n += 1
		var p: Vector3 = e[1]
		if _dg_someone_near(p, 2.5):
			continue
		DgDig.dig_at(body, p, 1.5, DgDig.MODE_RAISE, 8.0, Vector3.ZERO, Vector3.UP, -1.0, team)
		var soil: Color = body.get("soil_color") if body.get("soil_color") != null else Color(0.5, 0.3, 0.2)
		dust_puff(p, body.up_at(p), soil)
	_dg_caves = keep


func _dg_someone_near(p: Vector3, r: float) -> bool:
	for n in get_tree().get_nodes_in_group(Game.DAMAGEABLE):
		if n is Node3D and not n.is_in_group("war_structure") and (n as Node3D).global_position.distance_to(p) < r + 1.0:
			return true
	for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if pl != null and is_instance_valid(pl) and (pl as Node3D).global_position.distance_to(p) < r + 1.0:
			return true
	return false


# --- Flank tunnels (Kuşatma tüneli, 2026-10-07) ----------------------------------------------------
# Every second (_dg_process): a player on either planet who holds a spot (within DG_FLANK_HOLD_R m
# for DG_FLANK_HOLD_T s; × DG_FLANK_DUG_K dug in) gets a flank, DG_FLANK_GAP s after the last one:
# one bot, two when DG_FLANK_PAIR_MIN of ours are on his planet (exits DG_FLANK_PAIR_DEG apart), from
# the free ones (bot.dg_free_fight: on our planet a home bot, on his a landed pod crew member)
# DG_FLANK_MIN_D..MAX_D m from him, each from a spot near it he cannot see (_dg_flank_entry). The
# first one under the lip asks dg_flank_go (waits for the other, DG_FLANK_PAIR_WAIT s at most); then
# two front bots that see him pin him (bot.dg_suppress) while they burst out.
# Tells: dg_tunnel_tell (each carve step of a flank / sapper / counter tunnel: a muffled thump at the
# face within DG_THUMP_R m of a player, dust over the face every third step, once per tunnel within
# DG_TELL_R m "Ayaklarının altından kazı sesi geliyor…"), dg_popup_fx (the dirt burst at an exit).

const DgSnd := preload("res://scripts/audio/snd_lib.gd")

var _dg_flank: Array = []                # the running flank's bots (untyped: may be freed)
var _dg_flank_on := false
var _dg_flank_pinned := false
var _dg_flank_ready := {}                # bot instance id -> match s it got under the lip
var _dg_flank_next: float = Balance.DG_FLANK_FIRST
var _dg_hold := {}                       # player instance id -> [spot, since match s]
var _dg_snd: Array = []                  # 3D one-shots: tunnel thumps, dirt bursts
var _dg_snd_i := 0
var _dg_snd_thump: AudioStream = null
var _dg_snd_burst: AudioStream = null
var _dg_told := {}                       # tunneller instance id -> its task's start (told once)


func _dg_flank_scan() -> void:
	_dg_flank = _dg_flank.filter(func(b): return is_instance_valid(b) and not b.is_dead() and b.dg_task() == "flank")
	if not _dg_flank.is_empty():
		return
	if _dg_flank_on:
		_dg_flank_on = false
		_dg_flank_pinned = false
		_dg_flank_ready = {}
		_dg_flank_next = _match_t + Balance.DG_FLANK_GAP
	for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.get("vehicle") != null:
			continue
		var pp: Vector3 = (pl as Node3D).global_position
		var pb: Node3D = Game.dominant_body(pp)
		if pb != body and pb != home:
			continue
		var id: int = pl.get_instance_id()
		var h: Array = _dg_hold.get(id, [pp, _match_t])
		if (h[0] as Vector3).distance_to(pp) > Balance.DG_FLANK_HOLD_R:
			h = [pp, _match_t]
		_dg_hold[id] = h
		var need := Balance.DG_FLANK_HOLD_T * (Balance.DG_FLANK_DUG_K if _dg_dug_in(pb, pp) else 1.0)
		if _match_t < _dg_flank_next or _match_t - float(h[1]) < need or not _dg_player_known(pl):
			continue
		if _dg_flank_start(pl, pb):
			_dg_hold[id] = [pp, _match_t]
			return
		_dg_flank_next = _match_t + 10.0           # (nobody free / no hidden start: again soon)


## The team knows where he is: one of ours saw him in the last 30 s (no flank at a player nobody has
## found: he may snipe from hiding until he is spotted or heard).
func _dg_player_known(pl: Node3D) -> bool:
	var now := Time.get_ticks_msec()
	for b in bots:
		if is_instance_valid(b) and not b.is_dead() and b.get("_target") == pl and now - int(b.get("_seen_ms")) < 30000:
			return true
	return false


## In a pit / tunnel, or soil over his head.
func _dg_dug_in(pb: Node3D, pp: Vector3) -> bool:
	var up: Vector3 = pb.up_at(pp)
	var depth := float(pb.radius) + float(pb.surface_height_at(pp)) - pp.distance_to(pb.global_position)
	return depth > 1.0 or DgKit.cover_above(pb, pp + up * 0.5, up, 8.0) < 8.0


## Picks the flankers and gives them "flank" (see the subsection header); false when none could go.
func _dg_flank_start(pl: Node3D, pb: Node3D) -> bool:
	var pp := pl.global_position
	var up: Vector3 = pb.up_at(pp)
	var eye := pp + up * 1.5
	# Where the fight is (the bots on him), else the base on his planet.
	var front := Vector3.ZERO
	var n_on := 0
	for b in bots:
		if not is_instance_valid(b) or b.is_dead() or b.is_aboard() or Game.dominant_body((b as Node3D).global_position) != pb:
			continue
		n_on += 1
		var d: Vector3 = (b as Node3D).global_position - pp
		d -= up * d.dot(up)
		if b.mode == Bot.Mode.COMBAT and d.length() < 70.0 and d.length_squared() > 0.01:
			front += d.normalized()
	if front.length_squared() < 0.01:
		front = (base_xf.origin if pb == body else _our_base()) - pp
	front -= up * front.dot(up)
	if front.length_squared() < 1e-4:
		return false
	front = front.normalized()
	var cands: Array = []
	for b in bots:
		if not is_instance_valid(b) or b.is_dead() or not b.has_method("dg_free_fight") or not b.dg_free_fight():
			continue
		var bp: Vector3 = (b as Node3D).global_position
		if Game.dominant_body(bp) != pb or (pb == home and raid_phase(b) != "site"):
			continue
		var dd := bp.distance_to(pp)
		if dd >= Balance.DG_FLANK_MIN_D and dd <= Balance.DG_FLANK_MAX_D:
			cands.append([dd, b])
	if cands.is_empty():
		return false
	cands.sort_custom(_fh_sort)
	var want := 2 if cands.size() >= 2 and n_on >= Balance.DG_FLANK_PAIR_MIN else 1
	var half := Balance.DG_FLANK_PAIR_DEG * 0.5 if want == 2 else 0.0
	var behind := randf_range(Balance.DG_FLANK_BEHIND.x, Balance.DG_FLANK_BEHIND.y)
	for e in cands:
		if _dg_flank.size() >= want:
			break
		var b = e[1]
		var entry := _dg_flank_entry(pb, eye, (b as Node3D).global_position, pp)
		if entry == Vector3.INF:
			continue
		var k := _dg_flank.size()
		b.dg_assign("flank", {"player": pl, "entry": entry, "front": front, "behind": behind + randf_range(-1.0, 1.0),
				"exit_deg": half * (1.0 if k == 0 else -1.0)})
		_dg_flank.append(b)
	_dg_flank_on = not _dg_flank.is_empty()
	return _dg_flank_on


## A spot by `bp` (the bot) that the player's eye cannot see: where it stands, else one of six round it
## 3..7 m out (away from him first); INF when none.
func _dg_flank_entry(pb: Node3D, eye: Vector3, bp: Vector3, pp: Vector3) -> Vector3:
	var up: Vector3 = pb.up_at(bp)
	if not pb.raycast_density(eye, bp + up * 1.4, 0.5, true).is_empty():
		return bp
	var away := bp - pp
	away -= up * away.dot(up)
	away = away.normalized() if away.length_squared() > 1e-4 else up.cross(Vector3.RIGHT).normalized()
	for k in 6:
		var dir := away.rotated(up, (floorf(float(k) * 0.5) * 0.7 + 0.35) * (1.0 if k % 2 == 0 else -1.0))
		var q := bp + dir * randf_range(3.0, 7.0)
		var qu: Vector3 = pb.up_at(q)
		var h: Dictionary = pb.raycast_density(q + qu * 10.0, q - qu * 10.0, 0.4, true)
		if h.is_empty() or (h["normal"] as Vector3).dot(qu) < 0.85:
			continue
		var g: Vector3 = h["position"]
		if _dg_near_structure(g, 2.0):
			continue
		if not pb.raycast_density(eye, g + qu * 1.4, 0.5, true).is_empty():
			return g
	return Vector3.INF


## A flanker under the lip: true when it may burst out (every other flanker is under its lip too, or
## the first has waited DG_FLANK_PAIR_WAIT s); the first true has two front bots pin him.
func dg_flank_go(b: Node3D) -> bool:
	var id := b.get_instance_id()
	if not _dg_flank_ready.has(id):
		_dg_flank_ready[id] = _match_t
	var first := _match_t
	for v in _dg_flank_ready.values():
		first = minf(first, float(v))
	var go := _match_t - first > Balance.DG_FLANK_PAIR_WAIT
	if not go:
		go = true
		for m in _dg_flank:
			if is_instance_valid(m) and not m.is_dead() and m.dg_task() == "flank" and not _dg_flank_ready.has(m.get_instance_id()):
				go = false
				break
	if go and not _dg_flank_pinned:
		_dg_flank_pinned = true
		var n := 0
		for m in bots:
			if n >= 2 or not is_instance_valid(m) or _dg_flank.has(m) or not m.has_method("dg_suppress"):
				continue
			if (m as Node3D).global_position.distance_to(b.global_position) < 80.0 and m.dg_suppress(Balance.DG_FLANK_SUPPRESS):
				n += 1
	return go


## A carve step of a flank / sapper / counter tunnel at q (the bot's _dg_carve): see the header.
func dg_tunnel_tell(b: Node3D, q: Vector3, k: int) -> void:
	var near := INF
	for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if pl != null and is_instance_valid(pl) and not pl.is_dead():
			near = minf(near, (pl as Node3D).global_position.distance_to(q))
	if near > Balance.DG_THUMP_R:
		return
	var pb: Node3D = Game.dominant_body(q)
	if pb == null:
		return
	var up: Vector3 = pb.up_at(q)
	_dg_play("thump", q + up * 1.0, lerpf(-4.0, -16.0, near / Balance.DG_THUMP_R))
	if k % 3 == 0:
		var c: Vector3 = pb.global_position
		var d := (q - c).normalized()
		var soil: Color = pb.get("soil_color") if pb.get("soil_color") != null else Color(0.5, 0.3, 0.2)
		dust_puff(c + d * (float(pb.radius) + float(pb.surface_height_at(q))), up, soil)
	var id := b.get_instance_id()
	var t0 = b.get("_dg_t0")
	if near < Balance.DG_TELL_R and _dg_told.get(id) != t0 and Game.hud != null:
		_dg_told[id] = t0
		Game.hud.show_message("Ayaklarının altından kazı sesi geliyor…", 2.5)


## The dirt burst where a tunneller comes out (three dust puffs, a debris crash).
func dg_popup_fx(pos: Vector3, up: Vector3) -> void:
	var pb: Node3D = Game.dominant_body(pos)
	var soil := Color(0.5, 0.3, 0.2)
	if pb != null and pb.get("soil_color") != null:
		soil = pb.get("soil_color")
	var x := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	for k in 3:
		dust_puff(pos + x.rotated(up, TAU * float(k) / 3.0) * 0.7 + up * (0.2 + 0.3 * float(k)), up, soil)
	_dg_play("burst", pos, 0.0)


## A positional one-shot from a pool of three ("thump": a pick blow pitched down, small unit size: the
## occlusion system muffles it through the soil; "burst": a debris crash).
func _dg_play(key: String, pos: Vector3, vol_db: float) -> void:
	if _dg_snd.is_empty():
		_dg_snd_thump = DgSnd.rand("dig/mine", 1.1, 2.0)
		_dg_snd_burst = DgSnd.rand("expl/debris", 1.06, 1.5)
		for i in 3:
			var p := AudioStreamPlayer3D.new()
			p.max_polyphony = 1
			add_child(p)
			_dg_snd.append(p)
	var a: AudioStreamPlayer3D = _dg_snd[_dg_snd_i]
	_dg_snd_i = (_dg_snd_i + 1) % _dg_snd.size()
	if key == "thump":
		a.stream = _dg_snd_thump
		a.pitch_scale = randf_range(0.5, 0.65)
		a.unit_size = 5.0
		a.max_distance = Balance.DG_THUMP_R + 10.0
	else:
		a.stream = _dg_snd_burst
		a.pitch_scale = 1.0
		a.unit_size = 9.0
		a.max_distance = 120.0
	if a.stream == null:
		return
	a.volume_db = vol_db
	a.global_position = pos
	a.play()


func _dg_player_near(p: Vector3, r: float) -> bool:
	for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if pl != null and is_instance_valid(pl) and not pl.is_dead() and (pl as Node3D).global_position.distance_to(p) < r:
			return true
	return false


# --- Trenches, bunkers -----------------------------------------------------------------------------------

func _dg_trench_scan() -> void:
	if _match_t < _dg_trench_next:
		return
	_dg_trench_next = _match_t + Balance.DG_TRENCH_GAP
	var cn: Node3D = null
	for c in cannons:
		if is_instance_valid(c) and not c.is_destroyed and not c.has_meta("dg_trench"):
			cn = c
			break
	if cn == null:
		return
	var g := _dg_pick_bot([Bot.ROLE_RAIDER], cn.global_position)
	if g == null:
		_dg_trench_next = _match_t + 20.0
		return
	cn.set_meta("dg_trench", true)
	var cp := cn.global_position
	var up: Vector3 = body.up_at(cp)
	var fwd := _dg_toward_home(cp)
	var side := up.cross(fwd).normalized()
	var mid := cp + fwd * Balance.DG_TRENCH_AHEAD
	var pts: Array = []
	for k in Balance.DG_TRENCH_SEGS:
		var q := _dg_ground(mid + side * (float(k) - float(Balance.DG_TRENCH_SEGS - 1) * 0.5) * Balance.DG_TRENCH_SPACING)
		if q == Vector3.INF or _dg_near_structure(q, 1.5):
			continue
		pts.append(q)
	if pts.size() >= 3:
		g.dg_assign("trench", {"points": pts, "cannon": cn})


func _dg_bunker_scan() -> void:
	if _match_t < _dg_bunker_next or dg_bunkers.size() >= Balance.DG_BUNKER_MAX or cannons.is_empty():
		return
	_dg_bunker_next = _match_t + Balance.DG_BUNKER_GAP
	if _bk_count("war_bunker") > 0:
		return                                     # (a Sığınak Modülü is the shelter)
	var k := _dg_cluster()
	var up: Vector3 = body.up_at(k)
	var fwd := _dg_toward_home(k)
	var side := up.cross(fwd).normalized()
	for attempt in 6:
		var e := _dg_ground(k - fwd * randf_range(9.0, 13.0) + side * randf_range(-5.0, 5.0))
		if e == Vector3.INF or _dg_near_structure(e, 2.0):
			continue
		var rd := _dg_toward_home(e)
		if _dg_near_structure(e + rd * (Balance.DG_BUNKER_DEPTH / 0.65 + 2.0), 1.5):
			continue
		var g := _dg_pick_bot([Bot.ROLE_ENGINEER], e)
		if g == null:
			_dg_bunker_next = _match_t + 30.0
			return
		g.dg_assign("bunker", {"entry": e, "room_dir": rd, "slit_dir": fwd})
		return


# --- The rival's base pieces (BaseKit) -----------------------------------------------------------------

## next_build after the cannons and Uçaksavar: turrets near the cannons, a Sığınak Modülü by them.
func _bk_next_build() -> String:
	if material < Balance.BK_RESERVE:
		return ""
	if _bk_count("war_turret") < Balance.BK_TURRETS and _match_t >= float(_bk_fail.get("sentry_turret", 0.0)):
		return "sentry_turret"
	if _bk_count("war_bunker") < Balance.BK_BUNKER_MODULES and _match_t >= float(_bk_fail.get("bunker_module", 0.0)):
		return "bunker_module"
	return ""


## The engineer found no spot for `kind`: not asked again for 90 s.
func bk_failed(kind: String) -> void:
	_bk_fail[kind] = _match_t + 90.0


## Where a base piece of `kind` should go (BaseKit.suggest_spot searches around it).
func bk_near(kind: String) -> Vector3:
	var k := _dg_cluster()
	var fwd := _dg_toward_home(k)
	match kind:
		"sentry_turret":
			var cs: Array = cannons.filter(func(c): return is_instance_valid(c) and not c.is_destroyed)
			if not cs.is_empty():
				var cn: Node3D = cs[randi() % cs.size()]
				var up: Vector3 = body.up_at(cn.global_position)
				var side := up.cross(fwd).normalized() * (1.0 if randf() < 0.5 else -1.0)
				return cn.global_position + side * 6.0 + fwd * 2.0
		"bunker_module":
			return k - fwd * 8.0
	return k


func _bk_shield_scan() -> void:
	if _match_t < _bk_shield_next:
		return
	_bk_shield_next = _match_t + 20.0
	if _bk_count("war_core_shield") > 0 or cannons.size() < Balance.BK_SHIELD_AFTER:
		return
	for b in bots:
		if is_instance_valid(b) and b.has_method("dg_task") and b.dg_task() == "shield":
			return
	if material < DgKit.cost_of("core_shield") + Balance.BK_RESERVE:
		return
	var r: Dictionary = DgKit.suggest_spot("core_shield", team, base_xf.origin)
	if not bool(r["ok"]):
		_bk_shield_next = _match_t + 120.0
		return
	var g := _dg_pick_bot([Bot.ROLE_ENGINEER, Bot.ROLE_RAIDER], base_xf.origin)
	if g == null:
		return
	g.dg_assign("shield", {"xf": r["xf"]})
	_bk_shield_next = _match_t + 60.0


## The engineer is down in the chamber: carve it, pay, build the Çekirdek Kalkanı (+ a light).
## False when one stands already or the pool is short now.
func bk_build_shield(xf: Transform3D) -> bool:
	if _bk_count("war_core_shield") > 0:
		return false
	var cost := DgKit.cost_of("core_shield")
	if material - Balance.AI_RESERVE < cost or not spend(cost):
		return false
	DgKit.carve_for("core_shield", body, xf, team)
	DgKit.spawn("core_shield", team, xf, body, true)
	bk_light(xf.origin + xf.basis.x * 1.8, xf.basis.y)
	return true


## A Işık Direği at p (a dug room / tunnel floor), within BK_LIGHTS, paid from the pool.
func bk_light(p: Vector3, up: Vector3) -> void:
	if _bk_count("war_light") >= Balance.BK_LIGHTS:
		return
	var cost := DgKit.cost_of("light_post")
	if material - Balance.AI_RESERVE < cost or not spend(cost):
		return
	var h: Dictionary = body.raycast_density(p + up * 1.2, p - up * 3.0, 0.2, false)
	var at: Vector3 = h["position"] if not h.is_empty() else p
	var x := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	DgKit.spawn("light_post", team, Transform3D(Basis(x, up, x.cross(up)).orthonormalized(), at), body, true)


# =================================================================================================
# Prospecting: rich veins and meteor cores (2026-10-06; the bot side: the same section at the end of
# ai_rival.gd; the veins: scripts/planet/veins.gd, the cores: scripts/war/meteor_shower.gd; constants:
# balance.gd "Veins and meteors" VN_*)
# =================================================================================================
# Hook above (one line): _process -> _vn_process. Every VN_TEAM_SCAN s (one cached scan for the whole
# team) it lists the targets on its own planet: meteor cores first (temporary; most of them left), then
# rich veins (the contested ones) within VN_BOT_VEIN_RANGE m of arc from the base, at most
# VN_BOT_VEIN_DEPTH under the original ground and not dug out (VN_BOT_VEIN_LEFT), nearest the base
# first. Free bots (miners, then guards; nearest; dg_free, no weapon task, not on a raid) go:
# VN_BOTS_PER_METEOR per core, VN_BOTS_PER_VEIN per vein, VN_MAX_BOTS in all; a target gone, its bots
# are called off (vn_clear). They count as diggers for _income and add vn_bonus on top.

const VnVeins := preload("res://scripts/planet/veins.gd")

var _vn_t := 1.0
var _vn_jobs := {}                       # target key -> Array of bots
var vn_earned := 0.0                     # m³ the prospectors' bonus brought in this match (probes / stats)


func _vn_process(delta: float) -> void:
	_vn_t -= delta
	if _vn_t > 0.0:
		return
	_vn_t = Balance.VN_TEAM_SCAN
	if body == null or not is_instance_valid(body):
		return
	var targets := _vn_targets()
	var live := {}
	for t: Dictionary in targets:
		live[t["key"]] = true
	var busy := 0
	for k in _vn_jobs.keys():
		var keep: Array = []
		for b in _vn_jobs[k]:
			if not is_instance_valid(b) or not b.has_method("vn_target_key") or b.vn_target_key() != k:
				continue
			# Dead, gone aboard / on a raid, on another planet, or the target is gone: called off.
			if b.is_dead() or not live.has(k) or b.mode == Bot.Mode.ABOARD or is_raiding(b) \
					or Game.dominant_body((b as Node3D).global_position) != body:
				b.vn_clear()
				continue
			keep.append(b)
		if keep.is_empty():
			_vn_jobs.erase(k)
		else:
			_vn_jobs[k] = keep
			busy += keep.size()
	for t: Dictionary in targets:
		var meteor := int(t["kind"]) == VnVeins.KIND_METEOR
		var want := Balance.VN_BOTS_PER_METEOR if meteor else Balance.VN_BOTS_PER_VEIN
		var list: Array = _vn_jobs.get(t["key"], [])
		while list.size() < want:
			var b: Node3D = null
			if busy < Balance.VN_MAX_BOTS:
				b = _vn_pick(t["pos"])
			elif meteor:
				b = _vn_take_from_vein()           # a meteor core (temporary) goes before a vein
				busy -= 1 if b != null else 0
			if b == null:
				break
			b.vn_assign(t)
			list.append(b)
			busy += 1
		if not list.is_empty():
			_vn_jobs[t["key"]] = list


## A bot digging a vein, called off to go for a meteor core instead (null: none).
func _vn_take_from_vein() -> Node3D:
	for k in _vn_jobs.keys():
		if not str(k).begins_with("v"):
			continue
		var list: Array = _vn_jobs[k]
		var b = list.pop_back()
		if list.is_empty():
			_vn_jobs.erase(k)
		if b != null and is_instance_valid(b):
			b.vn_clear()
			return b
	return null


## The targets on this planet (see the section header).
func _vn_targets() -> Array:
	var out: Array = []
	for dp: Dictionary in VnVeins.deposits(body):
		if float(dp["rem"]) < 0.15:
			continue
		out.append({"key": "m%d" % int(dp["id"]), "kind": VnVeins.KIND_METEOR, "i": int(dp["id"]), "pos": dp["pos"]})
	var c: Vector3 = body.global_position
	var bdir := (base_xf.origin - c).normalized()
	var R := float(body.radius)
	var veins: Array = []
	for v: Dictionary in VnVeins.veins(body):
		if not bool(v["rich"]) or float(v["top"]) > Balance.VN_BOT_VEIN_DEPTH:
			continue
		var p: Vector3 = v["c"]
		var arc := bdir.angle_to((p - c).normalized()) * R
		if arc > Balance.VN_BOT_VEIN_RANGE or VnVeins.remaining(body, int(v["i"])) < Balance.VN_BOT_VEIN_LEFT:
			continue
		veins.append({"key": "v%d" % int(v["i"]), "kind": int(v["kind"]), "i": int(v["i"]), "pos": p, "arc": arc})
	veins.sort_custom(func(x, y): return float(x["arc"]) < float(y["arc"]))
	out.append_array(veins)
	return out


## The nearest free miner (else guard) on this planet that is not prospecting yet.
func _vn_pick(near: Vector3) -> Node3D:
	for want in [Bot.ROLE_MINER, Bot.ROLE_RAIDER]:
		var best: Node3D = null
		var best_d := INF
		for b in bots:
			if not _wx_free(b) or b.role != want or b.is_dead() or b.mode != Bot.Mode.WORK:
				continue
			if not b.has_method("vn_target_key") or b.vn_target_key() != "" or not b.has_method("dg_free") or not b.dg_free():
				continue
			if Game.dominant_body((b as Node3D).global_position) != body:
				continue
			var d: float = (b as Node3D).global_position.distance_to(near)
			if d < best_d:
				best_d = d
				best = b
		if best != null:
			return best
	return null


## A prospecting bot's dig turned part of a vein / core to air: its worth (× VN_BOT_GATHER) to the pool.
func vn_bonus(m3: float) -> void:
	if m3 > 0.0:
		add_material(m3)
		vn_earned += m3


# =================================================================================================
# Bölge kontrolü (scripts/war/control_points.gd): _pick_landing -> _cp_land_bonus (one line): a drop
# pod prefers to land near one of our zones, so its crew can take it.
# =================================================================================================

func _cp_land_bonus(p: Vector3) -> float:
	var cpn = get_tree().get_first_node_in_group("control_points")
	return float(cpn.land_bonus(home, p)) if cpn != null else 0.0
