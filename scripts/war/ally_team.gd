extends Node
## Friendly bots in single player (2026-10-05, "Single player'da bizim yanımıza dost bot ver"): child
## of the scene root (group "war_ally_team"), spawned by war.gd when neither multiplayer nor the
## Eğitim Alanı runs. Balance.ALLY_COUNT bots of team "home" on our planet: the rival's own bot AI
## (scripts/war/ai_rival.gd with team = "home"; its "Ally bots" section) brings the movement on the
## density surface, the combat (cover, slides, jumps), hit reactions, ragdolls and respawns. This
## node is the small team controller those bots expect as `team_node` (rival_team.gd's duck-typed
## API; no pool, no structures of its own, no raids, pods or weapon tasks: those are no-ops).
## Roles (fixed, by index: even = Muhafız, odd = Kazıcı):
##   Muhafız (ROLE_RAIDER)  "Beni takip et" (start): at the player's side while he is on foot on our
##                          planet within ALLY_FOLLOW_RANGE of the base; "Üssü koru": patrols the
##                          base and our structures (also while he is away / flying / dead)
##   Kazıcı  (ROLE_MINER)   digs pits ALLY_DIG_MIN..MAX m around the base; while it digs the PLAYER's
##                          material grows by ALLY_MINER_RATE m³/s (half a busy player's drill)
## F on an ally (InteractButton, scripts/ships/interact_button.gd) toggles its follow command
## ("Dost — Muhafız: Üssü koru" / "Beni takip et"; the Kazıcı: "Beni takip et" / "Kazmaya dön").
## Fights: they shoot the rival's bots they see on our planet (drop-pod crews); every second idle
## allies are also sent at intruders (the rival's bots on our planet) within ALLY_POD_REACT m (the
## Kazıcı only within 25 m), and at once when an enemy pod lands near them. The rival's bots, shells
## and blasts treat them as enemies; our hits do Balance.FRIENDLY_FIRE (game.gd damage_target, group
## "war_ally") and never turn them on him (ai_rival.gd _al_friendly_src); the tunnel scanner and the
## rail x-ray skip them (same team), our flak and cannons never aim at bots.
## Respawn: like the rival's bots, in our team's waves (on_bot_died -> RespawnShip.enqueue_dead) at respawn_xf: a spiral
## around our base clear of our structures and the player.
## Budgets (4 Hz, like rival_team.gd but for a handful): LOD by camera distance, lights, voices, a
## shooter token whenever it has a target, a real brush and its own DigFx while it digs, crowd /
## structure / player separation.

const Balance := preload("res://scripts/war/balance.gd")
const Bot := preload("res://scripts/war/ai_rival.gd")
const RivalTeam := preload("res://scripts/war/rival_team.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const InteractButton := preload("res://scripts/ships/interact_button.gd")
const Downed := preload("res://scripts/war/downed.gd")     # downed intruders are left alone
const GROUP := "war_ally_team"
const BOT_GROUP := "war_ally"
const INDEX_BASE := 1000               # bot.index (the rival's run 0..n: radio / events stay apart)
const MINER_HELP_RANGE := 25.0         # m: the Kazıcı leaves its pit for intruders only this close

var team := "home"
var body: Node3D                       # our planet
var home: Node3D                       # (rival_team.gd naming: the planet it fights) the rival's
var base_xf := Transform3D()
var material := 0.0                    # no pool: the Kazıcı pays the player (Game.add_material)
var bots: Array = []
var cannons: Array = []                # our structures on our planet (guard points), every second
var flaks: Array = []                  # (Uçaksavar + Silahlık, Delici Top, Otomatik Kazıcı)
var busters: Array = []
var skiff: Node3D = null
var aim_err := 0.0
var correction := Vector3.ZERO
var raid_dig_dist := -1.0
var _ragdolls: Array = []
var _events = null                     # rival_team.gd WeaponEvents (bot_react goes nowhere)
var _fx := {}                          # bot -> its DigFx
var _lod_t := 0.0
var _think_t := 0.0
var _income_t := 0.0
var _los_left := 0
var _cover_left := 0


func _ready() -> void:
	add_to_group(GROUP)
	name = "AllyTeam"
	body = Game.planet
	home = Game.rival
	base_xf = _base_transform()
	_events = RivalTeam.WeaponEvents.new()
	RivalTeam.events().pod_landed.connect(_on_pod_landed)
	_spawn_all.call_deferred()


func _spawn_all() -> void:
	for i in Balance.ALLY_COUNT:
		_spawn_bot(i)
	_think()


func _spawn_bot(i: int) -> void:
	var b: Node3D = Bot.new()
	b.team = team                          # (before _ready: our planet, the "DOST" tag, the callsign)
	b.team_node = self
	b.index = INDEX_BASE + i
	b.role = Bot.ROLE_RAIDER if i % 2 == 0 else Bot.ROLE_MINER
	b.al_follow = i % 2 == 0
	b.name = "AllyBot%d" % i
	b.transform = respawn_xf(b.index)
	b.add_to_group(BOT_GROUP)
	var scene: Node = get_tree().current_scene if get_tree().current_scene != null else get_parent()
	scene.add_child(b)
	bots.append(b)
	var btn = InteractButton.new()
	btn.name = "Command"
	btn.setup(Vector3(0.9, 1.9, 0.9), _command.bind(b), _prompt.bind(b))
	btn.position = Vector3(0, 0.95, 0)
	b.add_child(btn)
	var fx: Node3D = DigFx.new()
	fx.tip_is_vm = false
	add_child(fx)
	_fx[b] = fx


func _physics_process(_delta: float) -> void:
	_los_left = 2
	_cover_left = 4


func _process(delta: float) -> void:
	_lod_t -= delta
	if _lod_t <= 0.0:
		_lod_t = 0.25
		_lod_update()
	_think_t -= delta
	if _think_t <= 0.0:
		_think_t = 1.0
		_think()
	_income_t += delta
	if _income_t >= 1.0:
		_income(_income_t)
		_income_t = 0.0


## The base: our planet's spawn spot (the player's), on the real ground.
func _base_transform() -> Transform3D:
	var main = get_tree().current_scene
	if main != null and main.has_method("spawn_transform"):
		var xf: Transform3D = main.spawn_transform(body, home, 0.0)
		var up := xf.basis.y
		var h: Dictionary = body.raycast_density(xf.origin + up * 6.0, xf.origin - up * 30.0, 0.5, true)
		if not h.is_empty():
			xf.origin = h["position"]
		return xf
	return Transform3D(Basis(), body.global_position + Vector3.RIGHT * (float(body.radius) + 2.0))


## A point on our planet `arc` m (along the surface) from the base, at angle `phi` around it.
func around_base(arc: float, phi: float) -> Vector3:
	var c: Vector3 = body.global_position
	var bdir := (base_xf.origin - c).normalized()
	var a := arc / maxf(float(body.radius), 1.0)
	var d := (bdir * cos(a) + (base_xf.basis.x * cos(phi) + base_xf.basis.z * sin(phi)) * sin(a)).normalized()
	return c + d * (float(body.radius) + float(body.surface_height_at(c + d * float(body.radius))))


## Where ally `i` (re)appears: around the base, clear of our structures and the player.
func respawn_xf(i: int) -> Transform3D:
	var k := i - INDEX_BASE if i >= INDEX_BASE else i
	var phi := float(k) * 2.39996 + 0.7
	var p := around_base(4.0, phi)
	for t in 10:
		var q := around_base(4.0 + 2.5 * float(t), phi + float(t) * 1.1)
		if _spot_clear(q):
			p = q
			break
	var up: Vector3 = (p - body.global_position).normalized()
	var h: Dictionary = body.raycast_density(p + up * 8.0, p - up * 30.0, 0.5, true)
	if not h.is_empty():
		p = h["position"]
	var x := up.cross(base_xf.basis.z)
	if x.length_squared() < 1e-4:
		x = up.cross(Vector3.RIGHT)
	x = x.normalized()
	return Transform3D(Basis(x, up, x.cross(up)), p + up * 0.5)


func _spot_clear(p: Vector3) -> bool:
	for s in get_tree().get_nodes_in_group("war_structure"):
		if s is Node3D and (s as Node3D).global_position.distance_to(p) < float(s.get_meta("footprint_r", 3.0)) + 2.0:
			return false
	var pl = Game.player
	return pl == null or not is_instance_valid(pl) or (pl as Node3D).global_position.distance_to(p) > 2.5


# =================================================================================================
# Every second: guard points, intruders, income
# =================================================================================================

func _think() -> void:
	bots = bots.filter(func(b): return is_instance_valid(b))
	cannons = []
	flaks = []
	for grp in ["war_cannon", "war_flak", "war_armory", "war_buster", "war_miner"]:
		for s in get_tree().get_nodes_in_group(grp):
			if not (s is Node3D) or Game.team_of(s) != team or s.get("is_destroyed") == true \
					or Game.dominant_body((s as Node3D).global_position) != body:
				continue
			if grp == "war_cannon":
				cannons.append(s)
			else:
				flaks.append(s)
	_send_at_intruders()


## Idle allies go for the rival's bots on our planet (the nearest within reach of each).
func _send_at_intruders() -> void:
	var foes: Array = []
	for n in get_tree().get_nodes_in_group("war_ai"):
		if n is Node3D and n.has_method("pod_phase") and str(n.get("team")) != team and not n.is_dead() \
				and not n.is_aboard() and not Downed.is_downed(n) and Game.dominant_body((n as Node3D).global_position) == body:
			foes.append(n)
	if foes.is_empty():
		return
	for b in bots:
		if not is_instance_valid(b) or not b.is_inside_tree() or b.is_dead() or not b.is_idle():
			continue
		var reach: float = MINER_HELP_RANGE if b.role == Bot.ROLE_MINER else Balance.ALLY_POD_REACT
		var best: Node3D = null
		var best_d := reach
		for f in foes:
			var d: float = (f as Node3D).global_position.distance_to(b.global_position)
			if d < best_d:
				best_d = d
				best = f
		if best != null:
			b.help_call(best.global_position + best.global_transform.basis.y * 1.2)


## The Kazıcı's digging pays the player.
func _income(dt: float) -> void:
	var n := 0
	for b in bots:
		if is_instance_valid(b) and b.is_digging():
			n += 1
	if n > 0:
		Game.add_material(float(n) * Balance.ALLY_MINER_RATE * dt)


## An enemy pod came down on our planet: idle allies near it go there at once.
func _on_pod_landed(_id: int, pos: Vector3) -> void:
	if body == null or not is_instance_valid(body) or Game.dominant_body(pos) != body:
		return
	for b in bots:
		if not is_instance_valid(b) or b.is_dead() or not b.is_idle():
			continue
		var reach: float = MINER_HELP_RANGE if b.role == Bot.ROLE_MINER else Balance.ALLY_POD_REACT
		if b.global_position.distance_to(pos) < reach:
			b.help_call(pos)


# =================================================================================================
# The F command
# =================================================================================================

func _prompt(b: Node3D) -> String:
	if not is_instance_valid(b) or b.is_dead():
		return ""
	var what: String
	if b.role == Bot.ROLE_MINER:
		what = "Kazmaya dön" if b.al_follow else "Beni takip et"
	else:
		what = "Üssü koru" if b.al_follow else "Beni takip et"
	return "%s: %s" % [str(b.callsign), what]


func _command(b: Node3D) -> void:
	if not is_instance_valid(b) or b.is_dead():
		return
	b.al_follow = not b.al_follow
	var what := "seni takip ediyor"
	if not b.al_follow:
		what = "kazmaya döndü" if b.role == Bot.ROLE_MINER else "üssü koruyor"
	if Game.hud:
		Game.hud.show_message("%s %s" % [str(b.callsign), what], 2.0)
	if Game.sfx:
		Game.sfx.play("select", -8.0)
	if b.has_method("bl_ack"):
		b.bl_ack()                         # a nod and a raised palm, the answer (ai_rival.gd body language)


# =================================================================================================
# Budgets (4 Hz)
# =================================================================================================

func _lod_update() -> void:
	var cam := get_viewport().get_camera_3d()
	var cp: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	var live: Array = []
	for b in bots:
		if not is_instance_valid(b) or not b.is_inside_tree():
			continue
		var d: float = (b as Node3D).global_position.distance_to(cp)
		b.cam_dist = d
		b.lod = 0 if d < Balance.AI_LOD_NEAR else (1 if d < Balance.AI_LOD_MID else 2)
		var alive: bool = not b.is_dead() and not b.is_aboard()
		b.set_light(alive and d < Balance.AI_LOD_MID * 1.5)
		b.tok_audio = d < Balance.AI_LOD_MID
		b.tok_shoot = alive and b.wants_to_shoot()
		var digging: bool = alive and b.is_digging()
		b.tok_brush = digging
		var fx = _fx.get(b)
		if fx != null and is_instance_valid(fx):
			if digging and int(b.lod) < 2:
				if b.get_fx() == null:
					b.set_fx(fx)
			elif b.get_fx() != null:
				b.set_fx(null)
				fx.set_working(false)
		if alive:
			live.append(b)
	_separate(live)


## Crowd avoidance: allies apart, out of structure footprints, off the player's toes.
func _separate(live: Array) -> void:
	var structs: Array = []
	for s in get_tree().get_nodes_in_group("war_structure") + get_tree().get_nodes_in_group("poi_obstacle"):   # (+ combat-area walls / wrecks, poi.gd)
		if s is Node3D and Game.dominant_body((s as Node3D).global_position) == body:
			structs.append([(s as Node3D).global_position, float(s.get_meta("footprint_r", 3.0)) + Balance.AI_STRUCT_CLEARANCE])
	var pl = Game.player
	var pp := Vector3.INF
	# The player's eye and view while he drills / builds / aims (busy): allies keep out of that
	# cone (an ally ~1 m from the lens filled a quarter of the screen while he drilled).
	var eye := Vector3.INF
	var look := Vector3.ZERO
	var busy := false
	if pl != null and is_instance_valid(pl) and not pl.is_dead() and pl.get("vehicle") == null:
		pp = (pl as Node3D).global_position
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			eye = cam.global_position
			look = -cam.global_transform.basis.z
		var it = pl.call("current") if pl.has_method("current") else null
		if it != null and is_instance_valid(it):
			busy = bool(it.get("using")) or float(it.get("ads") if it.get("ads") != null else 0.0) > 0.3 \
					or str(it.get("item_id")) in ["terrain", "build"]
	var r := Balance.AI_SEPARATION
	for b in live:
		var p: Vector3 = (b as Node3D).global_position
		var push := Vector3.ZERO
		for o in live:
			if o == b:
				continue
			var dv: Vector3 = p - (o as Node3D).global_position
			var d := dv.length()
			if d < r:
				push += (dv / d if d > 0.01 else Vector3.RIGHT) * (r - d) / r * 2.5
		for st in structs:
			var dv: Vector3 = p - (st[0] as Vector3)
			var rr: float = st[1]
			var d := dv.length()
			if d < rr:
				push += (dv / d if d > 0.01 else Vector3.RIGHT) * (rr - d + 0.5) * 2.0
		if pp != Vector3.INF:
			# Never within ALLY_CAM_CLEAR m of the player (his camera).
			var dv: Vector3 = p - pp
			var d := dv.length()
			var cr := Balance.ALLY_CAM_CLEAR
			if d < cr:
				push += (dv / d if d > 0.01 else Vector3.RIGHT) * (cr - d) / cr * 4.0
			# Busy (drilling, building, aiming): out of his view cone, sideways (to the side it is on).
			if busy and eye != Vector3.INF:
				var c: Vector3 = p + (b as Node3D).global_transform.basis.y * 1.0 - eye
				var along := c.dot(look)
				if along > 0.0 and along < Balance.ALLY_VIEW_CLEAR_DIST:
					var lat := c - look * along
					var cone := along * tan(deg_to_rad(Balance.ALLY_VIEW_CLEAR_DEG)) + 0.8
					var ll := lat.length()
					if ll < cone:
						var bu: Vector3 = (b as Node3D).global_transform.basis.y
						var side := lat - bu * lat.dot(bu)
						if side.length_squared() < 1e-4:
							side = look.cross(bu)
						push += side.normalized() * (cone - ll) / cone * 3.5
		b.sep = push.limit_length(4.0)


# =================================================================================================
# The bot-facing team API (rival_team.gd's names; see ai_rival.gd)
# =================================================================================================

func take_los() -> bool:
	if _los_left <= 0:
		return false
	_los_left -= 1
	return true


## Carve tokens for the bots' dig tasks (rival_team.gd dg_take: the same bucket, refilled lazily here).
var _dg_tokens: float = Balance.DG_CARVE_BURST
var _dg_ms := 0


func dg_take(n: int) -> bool:
	var now := Time.get_ticks_msec()
	if _dg_ms > 0:
		_dg_tokens = minf(_dg_tokens + float(now - _dg_ms) / 1000.0 * Balance.DG_CARVE_PER_MIN / 60.0, Balance.DG_CARVE_BURST)
	_dg_ms = now
	if _dg_tokens < float(n):
		return false
	_dg_tokens -= float(n)
	return true


func take_cover_eval(want: int) -> int:
	var n := mini(want, _cover_left)
	_cover_left -= n
	return n


func call_help(from_bot: Node3D, threat: Vector3) -> void:
	for b in bots:
		if b == from_bot or not is_instance_valid(b) or b.is_dead() or not b.is_inside_tree() or not b.is_idle():
			continue
		if (b as Node3D).global_position.distance_to(from_bot.global_position) < Balance.AI_HELP_RANGE:
			b.help_call(threat)


func on_bot_died(b: Node3D) -> void:
	var fx = _fx.get(b)
	if b != null and is_instance_valid(b) and b.get_fx() != null:
		b.set_fx(null)
	if fx != null and is_instance_valid(fx):
		fx.set_working(false)
	preload("res://scripts/war/respawn_ship.gd").enqueue_dead(b)   # respawn: our next wave (respawn_waves.gd)


func add_ragdoll(r: Node) -> void:
	_ragdolls = _ragdolls.filter(func(x): return is_instance_valid(x) and not x.is_queued_for_deletion())
	_ragdolls.append(r)
	while _ragdolls.size() > 2:
		freeze_ragdoll(_ragdolls.pop_front())


func freeze_ragdoll(r) -> void:
	if r == null or not is_instance_valid(r):
		return
	_ragdolls.erase(r)
	if r.has_method("begin_getup") and not r.bodies.is_empty():
		r.begin_getup(null, 0.0)


## Dust for a digging ally without its FX: the rival team's shared puffs (none without that team).
func dust_puff(pos: Vector3, up: Vector3, col: Color) -> void:
	var rt = get_tree().get_first_node_in_group(RivalTeam.GROUP)
	if rt != null and rt.has_method("dust_puff"):
		rt.dust_puff(pos, up, col)


func events():
	return _events


func status() -> String:
	var parts: Array = []
	for b in bots:
		if is_instance_valid(b):
			parts.append(str(b.status()))
	return "Dostlar: " + " | ".join(PackedStringArray(parts))


# No pool, structures, raids, pods or weapon tasks (the rival-only paths never reach these; kept so
# every team_node call an ally could make resolves).
func add_material(_d: float) -> void:
	pass


func spend(_cost: float) -> bool:
	return false


func build_radius(_kind: String) -> float:
	return Balance.CANNON_FOOTPRINT


func claim_build(_kind: String) -> bool:
	return false


func release_build(_kind: String) -> void:
	pass


func next_build() -> String:
	return ""


func may_fire() -> bool:
	return false


func is_raiding(_b) -> bool:
	return false


func raid_phase(_b) -> String:
	return ""


func raid_digger() -> Node3D:
	return null


func raid_crew_size() -> int:
	return 0


func raid_retreat() -> void:
	pass


func report_dig(_dist: float) -> void:
	pass


func inbound_skiff() -> Node3D:
	return null


func wx_bot_action(_bot_index: int, _action: String) -> void:
	pass


func wx_task_done(_b: Node3D, _kind: String, _ok: bool) -> void:
	pass


func wx_play_at(_key: String, _pos: Vector3, _vol_db := 0.0) -> void:
	pass


func wx_grenade_ok() -> bool:
	return false


func wx_grenade_take() -> bool:
	return false


func wx_throw_grenade(_b: Node3D, _pos: Vector3, _vel: Vector3, _fuse: float) -> void:
	pass


func wx_intercept_started(_b: Node3D, _t: Node3D) -> void:
	pass


func pod_release(_b: Node3D) -> void:
	pass


func pod_abort() -> void:
	pass


func pod_crew_ready() -> bool:
	return false


func pod_launch(_gunner: Node3D, _c: Node3D, _v: Vector3) -> bool:
	return false
