extends Node3D
## One bot of the rival team (scripts/war/rival_team.gd owns the team, the shared material pool,
## the structures, the roles and the budgets that keep 70 bots affordable). An astronaut
## (scripts/player/astronaut.gd) with a role:
##   MINER    (Kazıcı)   digs for the pool on its own spot of a spiral around the base (the team
##                       credits every digging bot, capped; only budgeted bots carve real pits)
##   ENGINEER (Mühendis) builds the team's cannons / Uçaksavar (AI_MAX_BUILDERS at a time), fires a
##                       cannon it claims (incremental Ballistics search + the team's shrinking
##                       aim error and adjust-fire correction, team-wide pace), repairs damaged
##                       structures, otherwise digs
##   RAIDER              guard ("Muhafız") patrolling the base while Balance.RAIDS_ENABLED is off;
##                       with raids: boards the team skiff, lands near our base, fights, shoots our
##                       structures and digs a shaft toward our core, retreats aboard when told
## Combat (every role, on foot): reacts to hits, near misses (Game.shot_fired within AI_NEAR_MISS)
## and blasts (Game.blast) by turning on the shooter even unseen and calling allies; strafes,
## sprints between cover found by sampling the density field (spots whose line of sight from the
## enemy is blocked near the hider), crouches and peeks to shoot; jet-hops over obstacles and to
## dodge, jet-climbs out of pits; never stands in the open under fire; aims worse moving / under
## fire, better settled; magazine + reload window; flinches when hit; flees at low hp, regenerates
## when calm. Only bots holding a shooter token (the nearest AI_MAX_SHOOTERS) fire at the player.
## Squads press a vulnerable or outnumbered player (one suppresses, others flank / push), outgunned
## bots hold cover and peek-shoot, they hunt his last known position after losing him ("Pressure,
## cover and lethality"). Any non-engineer may be sent at our planet in a drop pod fired from a
## cannon and fight there to the death ("Drop-pod raids").
## Level of detail (set by the team from the camera distance): lod 0 near — think ~8 Hz in combat,
## move 15 Hz, full pose + foot IK every frame, cover search; lod 1 mid — think 2 Hz, move 8 Hz, pose
## 12 Hz, no foot rays; lod 2 far — think ~1.3 Hz, move 4 Hz, pose 3 Hz (2 Hz off screen), no
## cover search, no shadow. Lights, sounds and the dig FX only for the nearest few (tokens).
## Movement is kinematic on the density surface (analytic surface where the ground is unedited, a
## density march where it was dug); line of sight uses planet.raycast_density on the team's budget
## and physics rays near the camera.
## Group "damageable" + "war_ai": take_damage(amount, from_pos, impulse) -> {"dmg", "killed"};
## ragdoll at 0 hp (the team keeps at most AI_RAGDOLL_MAX simulating), respawn at the base after
## AI_RESPAWN s. The bullet catcher carries meta "callsign" / "ai_bot" for the HUD name tag.

const Balance := preload("res://scripts/war/balance.gd")
const Dig := preload("res://scripts/player/dig.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Astronaut := preload("res://scripts/player/astronaut.gd")
const Ragdoll := preload("res://scripts/player/ragdoll.gd")
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")     # N (LOD chunk keys)
const Core := preload("res://scripts/war/core.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const VM := preload("res://scripts/player/vm_parts.gd")
const Heroes := preload("res://scripts/war/heroes/heroes.gd")         # ultimates: bot_tick, the cloak, the dome
const Downed := preload("res://scripts/war/downed.gd")     # downed / revive / drag ("Downed / revive", end of file)
const Revive := preload("res://scripts/war/revive.gd")

const ROLE_MINER := 0
const ROLE_ENGINEER := 1
const ROLE_RAIDER := 2
const ROLE_NAMES := ["Kazıcı", "Mühendis", "Akıncı"]
const ROLE_COLORS := [Color(1.0, 0.62, 0.15), Color(0.95, 0.9, 0.3), Color(1.0, 0.16, 0.1)]

enum Mode { WORK, COMBAT, ABOARD, DEAD }
enum Tac { NONE, STRAFE, TO_COVER, COVER, ADVANCE, HOLD, FLEE, FLANK, SUPPRESS, HUNT }   # (the last three: "Pressure, cover and lethality")
const MODE_NAMES := ["çalışıyor", "çatışmada", "mekikte", "ölü"]

const TICKS := [1.0 / 15.0, 1.0 / 15.0, 0.25]         # movement step per LOD (perf pass 2026-10-07: mid 1/8 -> 1/15,
													  # its path corners stepped visibly; _tick ~0.17 ms)
## Perf pass 2026-10-07: decisions and cover tests are spread over physics frames (one bot's _think
## with a cover search took up to ~10 ms and several bots told "decide right away" by the same event
## all thought in one frame). Shared by every bot (static), reset per physics frame.
const THINKS_PER_FRAME := 2            # _think calls per physics frame (all bots)...
const THINK_LATE_MAX := 0.25           # ...except a bot this many s past its period (never starves)
const COVER_USEC_PER_FRAME := 1500     # cover candidate tests per physics frame (all bots), µs
static var _budget_frame := -1
static var _thinks_left := 0
static var _cover_us_left := 0
const THINK_WORK := [0.25, 0.5, 0.8]
const THINK_COMBAT := [0.125, 0.5, 0.75]
const POSE_RATE := [0.0, 1.0 / 30.0, 1.0 / 10.0]        # 0 = every frame (off screen: 2 Hz)
## On screen and nearer than this (m): posed every frame whatever its LOD, farther on screen at least
## POSE_FAR_ON_SCREEN (2026-10-07: mid / far bots stepped visibly at the LOD pose rate).
const POSE_FULL_DIST := 60.0
const POSE_FAR_ON_SCREEN := 1.0 / 20.0
const TURN_RATE := 4.5                 # rad/s the body turns toward where it wants to face (2026-10-06 tok: 7 -> 4.5)
const WALK_ACCEL := 9.0                # m/s² walking speed changes (no instant starts / flips) (2026-10-06 tok: 14 -> 9)
const HEIGHT_W := 20.0                 # 1/s critically damped ground height of the shown body
const DIG_COLOR := Color(1.0, 0.45, 0.2)
const REPAIR_COLOR := Color(0.4, 0.85, 1.0)
const EYE_H := 1.55
const CROUCH_DROP := 0.38
const STEP_MAX := 0.55
const COVER_DIRS := 8
const COVER_RADII := [3.0, 6.0, 9.0]
const COVER_SAMPLES := [0.8, 1.6, 2.5, 3.5, 5.0, 7.0, 10.0, 14.0, 20.0, 28.0]

var team_node                          # rival_team.gd
var index := 0
var role := -1
var team := "rival"
var body: Node3D
var hp := Balance.AI_HP
var hp_max := Balance.AI_HP
var mode := Mode.WORK
var velocity := Vector3.ZERO
var astronaut
var callsign := ""
var shooting_skiff := false
var aboard: Node3D = null
var foothold = null                    # an enemy structure on our planet the team sent us at (untyped: may be freed)
# Set by the team (budgets / LOD).
var lod := 2
var cam_dist := 1000.0
var tok_audio := false
var tok_shoot := false
var tok_brush := false
var sep := Vector3.ZERO                # crowd / structure push (m/s), from the team at 4 Hz

# Movement.
var _move_to := Vector3.INF
var _move_speed := Balance.AI_WALK_SPEED
var _strafe := Vector3.ZERO
var _strafe_speed := 0.0
var _knock := Vector3.ZERO
var _air := false
var _climb := false
var _climb_t := 0.0
var _vy := 0.0
var _jet_t := 0.0
var _crouch := false
var _crouch_k := 0.0
var _face := Vector3.ZERO
var _still_t := 0.0
var _probe_t := 0.0
var _tick_acc := 0.0
var _think_acc := 0.0
var _pose_acc := 0.0
var _vis_pos := Vector3.ZERO           # the shown position (= the node's, render-interpolated)
# Render interpolation: _tick simulates at the LOD rate on _sim_xf; every frame the node shows the
# blend of the last two sim states (position lerp + basis slerp), the ground height critically
# damped on top. Anything that moves the node from outside (spawn, respawn, skiff) restarts it.
var _sim_xf := Transform3D()
var _sim_prev := Transform3D()
var _shown_xf := Transform3D()
var _vis_r := -1.0
var _vis_rv := 0.0
var _pose_pos := Vector3.INF
var _hv := Vector3.ZERO                # smoothed horizontal walking velocity (sim)
var _sep_s := Vector3.ZERO             # smoothed crowd push
# Combat movement: slides and jumps (the "Slides and jumps" section). Exposed for multiplayer:
# `sliding`, `airborne` (the snapshot already carries them: see that section's notes).
var sliding := false
var airborne := false
var _slide_t := -1.0
var _slide_v := Vector3.ZERO
var _slide_aim := Vector3.INF
var _slide_cd := 0.0
var _slide_k := 0.0
var _jump_cd := 0.0
var _dodge_cd := 0.0
var _crouch_hold := 0.0
var _pending := {}
var _land_v := 0.0
var _land_t := 0.0
var _agile := 0.6                      # trait: how often it slides / jumps (0.3..1)
var _react := 1.0                      # trait: reaction delay scale (0.7..1.4)
# Work.
var _job := ""
var _dig_acc := 0.0
var _puff_t := 0.0
var _dig_site := Vector3.INF
var _dig_t := 0.0
var _digging := false
var _shaft := false
var _dig_point := Vector3.ZERO
var _dig_normal := Vector3.UP
var _build_kind := "cannon"
var _build_spot := Vector3.INF
var _build_claimed := false
var _repair_target: Node3D
var _fire_cannon: Node3D
var _fire_target := Vector3.INF
var _guard_wp := Vector3.INF
var _guard_wait := 0.0
var _solve := {}
var _solved_v := Vector3.ZERO
var _solved := false
# Combat.
var _target: Node3D
var _target_visible := false
var _los_cache := false
var _threat_pos := Vector3.INF
var _threat_ms := -100000
var _seen_ms := -100000
var _hurt_ms := -100000
var _help_ms := -100000
var _tac := Tac.NONE
var _tac_t := 0.0
var _cover_pos := Vector3.INF
var _cover_search := {}
var _peek := false
var _peek_t := 0.0
var _mag := Balance.AI_MAG
var _reload_t := 0.0
var _rifle_t := 0.0
var _burst := 0
var _flinch := 0.0
var _fire_vis := 0.0
var _skiff_seen_t := 0.0
# Nodes.
var _fx = null                         # a pooled DigFx while the team lends one
var _dig_audio: AudioStreamPlayer3D
var _mine_audio: AudioStreamPlayer3D
var _gun_audio: AudioStreamPlayer3D
var _col: StaticBody3D
var _cap: CapsuleShape3D
var _cap_cs: CollisionShape3D
var _ragdoll = null
var _rag_frozen := false
var _dead_t := 0.0
var _held := ""
var _tracer: MeshInstance3D
var _tracer_mesh: ImmediateMesh
var _tracer_t := 0.0
var _flash: OmniLight3D
var _flash_t := 0.0
var _lamp: OmniLight3D
var _light_on := false
var _role_mat: StandardMaterial3D
var _skin_mesh: GeometryInstance3D
var _shadow_lod := -1
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_ai")
	_rng.randomize()
	_agile = _rng.randf_range(0.3, 1.0)
	_react = _rng.randf_range(0.7, 1.4)
	body = _al_home_body()                   # (Game.rival; our planet for an ally bot: "Ally bots", end of file)
	_vis_pos = global_position
	_sim_xf = global_transform
	_sim_prev = global_transform
	_shown_xf = global_transform
	_face = -global_transform.basis.z
	astronaut = Astronaut.new()
	add_child(astronaut)
	astronaut.set_first_person(false)
	astronaut.set_process(false)          # the bot syncs the skeleton itself, at its pose rate
	_build_rifle_prop()
	_lamp = OmniLight3D.new()
	_lamp.omni_range = 3.5
	_lamp.light_energy = 1.4
	_lamp.shadow_enabled = false
	_lamp.visible = false
	astronaut.head.add_child(_lamp)
	_lamp.position = Vector3(0, 0.25, -0.15)
	_role_mat = StandardMaterial3D.new()
	_role_mat.albedo_color = Color(0.1, 0.1, 0.1)
	_role_mat.emission_enabled = true
	_role_mat.emission_energy_multiplier = 3.0
	VM.box(astronaut.chest, Vector3(0, 0.2, 0.29), Vector3(0.06, 0.16, 0.01), _role_mat)
	_visual_lod_setup()
	_col = StaticBody3D.new()
	_col.collision_layer = Game.LAYER_PLAYER
	_col.collision_mask = 0
	_col.set_meta("ai_bot", self)
	_cap_cs = CollisionShape3D.new()
	_cap = CapsuleShape3D.new()
	_cap.radius = 0.4
	_cap.height = 1.8
	_cap_cs.shape = _cap
	_cap_cs.position = Vector3(0, 0.9, 0)
	_col.add_child(_cap_cs)
	add_child(_col)
	_dig_audio = _audio3d(Snd.loop("ship/dig_beam"), 10.0, 160.0)
	_mine_audio = _audio3d(Snd.rand("dig/mine", 1.08, 2.0), 8.0, 120.0)
	_gun_audio = _audio3d(Snd.rand("weap/rifle_shot", 1.05, 1.5), 14.0, 600.0)
	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.7, 0.4)
	_flash.omni_range = 8.0
	_flash.light_energy = 0.0
	_flash.shadow_enabled = false
	_flash.visible = false
	add_child(_flash)
	_tracer_mesh = ImmediateMesh.new()
	_tracer = MeshInstance3D.new()
	_tracer.mesh = _tracer_mesh
	_tracer.top_level = true
	_tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tm := StandardMaterial3D.new()
	tm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tm.vertex_color_use_as_albedo = true
	tm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_tracer.material_override = tm
	add_child(_tracer)
	_tracer.global_transform = Transform3D.IDENTITY
	_set_held("terrain")
	if role < 0:
		set_role(ROLE_MINER)
	else:
		var r := role
		role = -1
		set_role(r)
	Game.shot_fired.connect(_on_shot)
	for pl in [Game.planet, Game.rival]:
		if pl != null and pl.has_signal("brush_applied"):
			pl.brush_applied.connect(_on_ground_edit)
	Game.blast.connect(_on_blast)
	# Stagger the bots' updates across frames.
	_think_acc = _rng.randf() * 0.5
	_tick_acc = _rng.randf() * 0.25
	_pose_acc = _rng.randf() * 0.3
	astronaut.animate(0.016, {"speed": 0.0, "grounded": true, "probe": false})
	astronaut.sync_skeleton()


func _audio3d(stream: AudioStream, unit: float, max_d: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.unit_size = unit
	p.max_distance = max_d
	p.max_polyphony = 1
	add_child(p)
	return p


## Small details fade out with distance (engine visibility ranges): pack lights, decals, props,
## jet flames; the rival's chest tag reads "RAKİP". The skinned body stays; its shadow is LOD'd.
func _visual_lod_setup() -> void:
	for n in astronaut.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if gi is MeshInstance3D and (gi as MeshInstance3D).skin != null:
			_skin_mesh = gi
			continue
		gi.visibility_range_end = 45.0
		gi.visibility_range_end_margin = 5.0
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if gi is Label3D:
			(gi as Label3D).text = "DOST" if team == "home" else "RAKİP"   # (ally bots: end of file)


func _build_rifle_prop() -> void:
	var hands: Array = astronaut.hand
	if hands.size() < 2 or hands[1] == null:
		return
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.86, 0.85, 0.82) if team == "home" else Color(0.75, 0.3, 0.25)   # (ally: white)
	white.roughness = 0.4
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.16, 0.17, 0.19)
	dark.metallic = 0.6
	dark.roughness = 0.4
	var p := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.06, -0.05), Vector3(0.05, 0.07, 0.3), white)
	VM.box(p, Vector3(0, 0.05, 0.17), Vector3(0.036, 0.09, 0.15), white)
	VM.seg(p, Vector3(0, 0.062, -0.2), Vector3(0, 0.062, -0.6), 0.016, 0.014, dark, 8)
	VM.box(p, Vector3(0, -0.03, -0.085), Vector3(0.03, 0.1, 0.05), dark)
	astronaut.props["rifle"] = p
	astronaut.prop_tips["rifle"] = VM.node(p, Vector3(0, 0.062, -0.62))
	p.visible = false


func _set_held(id: String) -> void:
	if _held == id:
		return
	_held = id
	astronaut.set_held(id)


func set_role(r: int) -> void:
	if r == role:
		return
	role = r
	var nm: String = ROLE_NAMES[r]
	if r == ROLE_RAIDER and (not Balance.RAIDS_ENABLED or team == "home"):
		nm = "Muhafız"
	callsign = ("Dost — %s" if team == "home" else "Rakip — %s") % nm   # (ally bots: end of file)
	if _col == null:
		return
	_col.set_meta("callsign", callsign)
	var c: Color = _al_role_color(r) if team == "home" else ROLE_COLORS[r]
	_role_mat.emission = c
	_lamp.light_color = c
	if mode == Mode.WORK:
		_set_job("")


# --- Team interface (budgets) -------------------------------------------------------------------

func set_light(on: bool) -> void:
	if on == _light_on:
		return
	_light_on = on
	_lamp.visible = on
	_flash.visible = on


func set_fx(fx) -> void:
	if _fx != null and _fx != fx and is_instance_valid(_fx):
		_fx.set_working(false)
	_fx = fx


func get_fx():
	return _fx


func is_digging() -> bool:
	return _digging and mode == Mode.WORK


func is_idle() -> bool:
	return mode == Mode.WORK


## A player: ours, or (multiplayer co-op) the other one's body (scripts/net/remote_avatar.gd).
func _is_player(n) -> bool:
	return n != null and is_instance_valid(n) and (n == Game.player or (n as Node).is_in_group("net_player"))


## The player this bot watches: Game.player, or in multiplayer the nearer living one (the current
## target is kept while it stays alive and on this planet).
func _pick_player():
	if team == "home":
		return null                          # an ally bot never targets a player (end of file)
	var pl = Game.player
	if not Net.active:
		return pl
	if _is_player(_target) and not _target.is_dead() and Game.dominant_body(_target.global_position) == body:
		return _target
	var best = pl
	var bd := INF
	for c in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if c == null or not is_instance_valid(c) or c.is_dead():
			continue
		var d: float = (c as Node3D).global_position.distance_to(global_position)
		if d < bd:
			bd = d
			best = c
	return best


## In a fight with the player (or his skiff) in sight (or pinning the spot where he ducked out of
## sight: suppressive fire): asks the team for a shooter token.
func wants_to_shoot() -> bool:
	if mode != Mode.COMBAT or _target == null or not is_instance_valid(_target) or not (_target_visible or _pr_blind_fire()):
		return false
	return _is_player(_target) or _target.is_in_group("skiff") or _al_is_bot(_target)   # (bot vs bot: ally bots)


func is_dead() -> bool:
	return mode == Mode.DEAD


func is_aboard() -> bool:
	return mode == Mode.ABOARD


func _now() -> int:
	return Time.get_ticks_msec()


func _up() -> Vector3:
	return body.up_at(global_position) if body != null else global_transform.basis.y


func _eye() -> Vector3:
	return global_position + _up() * (EYE_H - CROUCH_DROP * _crouch_k)


func _play(p: AudioStreamPlayer3D) -> void:
	if tok_audio and p.stream != null:
		p.play()


# =================================================================================================
# Per frame
# =================================================================================================

func _physics_process(delta: float) -> void:
	if mode == Mode.DEAD:
		_tick_dead(delta)
		return
	if mode == Mode.ABOARD:
		_tick_aboard()
		return
	if _ci_buried_tick(delta):           # buried by a cave-in: stuck in the soil (Cave-ins and entrench, end of file)
		return
	if _dn_physics(delta):               # downed: crawl / dragged; getting up (Downed / revive, end of file)
		return
	if _hr_physics(delta):               # hit reactions: knocked down / getting up (end of file)
		return
	_flinch = maxf(_flinch - delta, 0.0)
	_moves_update(delta)                 # slides / jumps: cooldowns, delayed reactions
	if hp < hp_max and _now() - _hurt_ms > int(Balance.AI_REGEN_DELAY * 1000.0):
		hp = minf(hp + Balance.AI_REGEN * delta, hp_max)
	# Fixed sim steps; the remainder carries over so the steps stay evenly spaced (the render
	# interpolation in _process blends between the last two by _tick_acc / tick).
	var tick: float = TICKS[lod]
	_tick_acc += delta
	if _tick_acc >= tick:
		_tick_acc -= tick
		if _tick_acc > tick:
			_tick_acc = 0.0                  # fell behind (hitch, LOD change): drop the backlog
		_tick(tick)
	_think_acc += delta
	var period: float = THINK_COMBAT[lod] if mode == Mode.COMBAT else THINK_WORK[lod]
	if _think_acc >= period and not _hr_busy():     # (no decisions while staggered: hit reactions)
		if _take_think(delta):           # (spread over frames: THINKS_PER_FRAME)
			_think(_think_acc)
			_think_acc = 0.0
	if not _solve.is_empty():
		_step_solve()
	if _digging:
		_dig_update(delta)
	elif _job == "repair" and _repair_target != null and _fx != null:
		_repair_fx()
	if mode == Mode.COMBAT or _job == "raid_attack":
		_shoot_update(delta)


func _process(delta: float) -> void:
	if mode == Mode.DEAD:
		# Ragdoll still simulating: keep the skin on its bones (at the pose rate).
		if _ragdoll != null and is_instance_valid(_ragdoll) and not _rag_frozen:
			_pose_acc += delta
			if _pose_acc >= POSE_RATE[lod]:
				_pose_acc = 0.0
				astronaut.sync_skeleton()
		return
	if mode == Mode.ABOARD:
		return
	if _dn_process(delta):               # downed / getting up: the pose instead of the animation (end of file)
		return
	if _hr_process(delta):               # hit reactions: knocked down / getting up (end of file)
		return
	_show_interpolated(delta)
	# Crouch (also while sliding and just after it) and the slide: the astronaut's own poses.
	_crouch_k = move_toward(_crouch_k, 1.0 if (_crouch or sliding or _crouch_hold > 0.0) else 0.0, delta * 4.5)
	_slide_k = move_toward(_slide_k, 1.0 if sliding else 0.0, delta * 6.0)
	var b := global_transform.basis
	astronaut.position = Vector3.ZERO
	_fire_vis = maxf(_fire_vis - delta, 0.0)
	_tracer_t = maxf(_tracer_t - delta, 0.0)
	if _tracer_t <= 0.0 and _tracer.visible:
		_tracer.visible = false
	if _flash_t > 0.0:
		_flash_t = maxf(_flash_t - delta * 12.0, 0.0)
		_flash.light_energy = 5.0 * _flash_t
	# Pose at the LOD rate (slower still off screen); on screen every frame within POSE_FULL_DIST and
	# at least POSE_FAR_ON_SCREEN farther (the limbs no longer step; a few bots: cheap).
	var rate: float = POSE_RATE[lod]
	if lod > 0:
		var cam := get_viewport().get_camera_3d()
		if cam != null and not cam.is_position_in_frustum(global_position):
			rate = 0.5
		elif cam_dist < POSE_FULL_DIST:
			rate = 0.0
		else:
			rate = minf(rate, POSE_FAR_ON_SCREEN)
	_pose_acc += delta
	if _pose_acc < rate:
		return
	var dt := _pose_acc
	_pose_acc = 0.0
	if _shadow_lod != lod and _skin_mesh != null:
		_shadow_lod = lod
		_skin_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod < 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Gait speed = the distance the shown body really travelled since the last pose (no sliding).
	var vv := velocity
	if _pose_pos != Vector3.INF and dt > 1e-4 and _pose_pos.distance_to(global_position) < 5.0:
		vv = (global_position - _pose_pos) / dt
	_pose_pos = global_position
	var hv := vv - b.y * vv.dot(b.y)
	var pitch := 0.0
	if _target != null and is_instance_valid(_target) and (mode == Mode.COMBAT or _job == "raid_attack"):
		var d := (_aim_point(_target) - _eye()).normalized()
		pitch = asin(clampf(d.dot(b.y), -1.0, 1.0))
	# vel_up: the fall speed in the air, the impact speed right after a landing (the landing dip).
	var vup := _vy if _air else (_land_v if _land_t > 0.0 else 0.0)
	astronaut.animate(minf(dt, 0.5), {"vel_local": b.inverse() * hv, "vel_up": vup, "speed": hv.length(),
			"grounded": not _air and not _climb, "jetting": _jet_t > 0.0 or _climb, "jet_power": 1.0,
			"zero_g": false, "pitch": pitch, "holding": _held != "", "two_hand": true,
			"using": _digging or _fire_vis > 0.0 or _job == "repair", "exclude": [_col.get_rid()],
			"probe": lod == 0, "crouch": _crouch_k, "slide": _slide_k})
	astronaut.set_tool_color(REPAIR_COLOR if _job == "repair" else DIG_COLOR)
	_idle.pose(self, dt)                     # natural idle: the weight shift (ai_idle.gd; "Natural idle" before "Raid site")
	astronaut.sync_skeleton()


# =================================================================================================
# Movement (kinematic on the density surface, rate by LOD)
# =================================================================================================

func _tick(dt: float) -> void:
	_sync_from_node()
	var pos := _sim_xf.origin
	var nb: Node3D = Game.dominant_body(pos)
	if nb != null:
		body = nb
	var up: Vector3 = body.up_at(pos)
	var want := Vector3.ZERO
	if _move_to != Vector3.INF:
		var to := _move_to - pos
		var flat := to - up * to.dot(up)
		var dist := flat.length()
		if dist < 0.6:
			_move_to = Vector3.INF
		else:
			want = flat / dist * minf(_move_speed, dist / dt)
	elif _strafe != Vector3.ZERO:
		var sf := _strafe - up * _strafe.dot(up)
		if sf.length_squared() > 1e-4:
			want = sf.normalized() * _strafe_speed
	if _knock.length_squared() > 0.01:
		want += _knock - up * _knock.dot(up)
		_knock *= 0.75
	if _crouch_k > 0.5:
		want *= 0.45
	if mode != Mode.COMBAT and want.length_squared() > 0.01:
		_face = want.normalized()
	want = _hr_move(want, up)            # hit reactions: the shove / skid, the limp (end of file)
	# Crowd: step aside from bots / structures that are too close (also while standing). The team
	# updates `sep` at 4 Hz: eased in so it does not jerk the path.
	_sep_s = _sep_s.lerp(sep, 1.0 - exp(-3.0 * dt))
	if _sep_s.length_squared() > 0.04:
		want += _sep_s - up * _sep_s.dot(up)
	want = _dg_block(want, pos, up)      # enemy doors stop it, walls turn it (Digging tactics, end of file)
	if not want.is_finite() or not _hv.is_finite():
		# (2026-10-07: a non-finite target (a _move_to / _strafe / shove made from a NaN position) never
		# reaches the sim position: the bot stops and re-decides.)
		want = Vector3.ZERO
		_hv = Vector3.ZERO
		_knock = Vector3.ZERO
		_move_to = Vector3.INF
		_strafe = Vector3.ZERO
	# Walking speed and direction change at a limited rate (no instant starts, stops or flips).
	_hv -= up * _hv.dot(up)
	# (in the air only a little steering: a jump keeps its arc)
	_hv = _hv.move_toward(want, (Balance.AI_AIR_ACCEL if _air else WALK_ACCEL) * dt)
	want = _hv
	var gmag: float = Game.gravity_at(pos).length()
	var np := pos
	if sliding:
		np = _slide_tick(pos, up, dt)
	elif _climb:
		_climb_t += dt
		np = pos + up * Balance.AI_CLIMB_SPEED * dt
		if body.density_at(np + up * 1.9) < 0.0 or _climb_t > 45.0 or want == Vector3.ZERO:
			_climb = false
			_air = true
			_vy = 0.0
		else:
			var g := _probe(np + want * dt, up, np)
			if g["ok"]:
				np = g["pos"]
				_climb = false
			elif not g["blocked"]:
				np += want * dt
				_climb = false
				_air = true
				_vy = 0.0
	elif _air:
		_vy -= gmag * dt
		_jet_t = maxf(_jet_t - dt, 0.0)
		var hstep := want * dt
		if hstep != Vector3.ZERO and body.density_at(pos + hstep + up * 1.0) < 0.0:
			hstep = Vector3.ZERO
		np = pos + hstep + up * _vy * dt
		if _vy <= 0.0:
			var h: Dictionary = body.raycast_density(np + up * (0.6 - _vy * dt), np - up * 0.3, 0.3, false)
			if not h.is_empty():
				np = h["position"]
				_air = false
				_land_v = _vy                    # the landing dip (pose)
				_land_t = 0.25
				_probe_t = 0.0                   # settle onto the true ground at the next step
				_vy = 0.0
		elif body.density_at(np + up * 1.8) < 0.0:
			_vy = 0.0
	else:
		if want == Vector3.ZERO:
			# Standing: re-check the ground now and then (every tick while carving a pit).
			# (_on_ground_edit forces a check at once when the ground nearby changes.)
			_probe_t -= dt
			if _probe_t <= 0.0 or (tok_brush and _digging):
				_probe_t = 0.5
				var g := _probe(pos, up, pos)
				if g["ok"]:
					np = g["pos"]
					if (np - pos).dot(up) < -0.4:
						np = pos                     # the ground dropped away: fall, don't glide down
						_air = true
						_vy = 0.0
				elif g["blocked"]:
					np = pos + up * 0.4
				else:
					_air = true
					_vy = 0.0
		else:
			var tgt := pos + want * dt
			var g := _probe(tgt, up, pos)
			if g["blocked"]:
				_on_blocked(up, tgt)
			elif not g["ok"]:
				np = tgt
				_air = true
				_vy = 0.0
			else:
				np = g["pos"]
				if (np - pos).dot(up) < -0.7:
					np = tgt                         # off a step: a short fall, not a snap
					_air = true
					_vy = 0.0
	if not np.is_finite():
		np = pos                             # (2026-10-07: never a non-finite sim position)
		_vy = 0.0
		_slide_v = Vector3.ZERO
	velocity = (np - pos) / dt
	airborne = _air
	_still_t = _still_t + dt if velocity.length() < 0.6 else 0.0
	up = body.up_at(np)
	# Facing: turn toward _face at TURN_RATE (no snapping round in one step).
	var cur := -_sim_xf.basis.z
	cur = cur - up * cur.dot(up)
	if cur.length_squared() < 1e-4 or not cur.is_finite():
		# (2026-10-07: up.cross(RIGHT) alone was zero with up along ±X: a zero facing, a degenerate
		# basis, a NaN quaternion in _show_interpolated and a bot stuck at NaN from then on.)
		cur = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	cur = cur.normalized()
	var fw := _slide_v if (sliding and _slide_v.length_squared() > 0.25) else _face   # slides face their way
	var f := fw - up * fw.dot(up)
	if f.length_squared() < 1e-4 or not f.is_finite():
		f = cur
	f = f.normalized()
	var ang := cur.signed_angle_to(f, up)
	if absf(ang) > TURN_RATE * dt:
		f = cur.rotated(up, signf(ang) * TURN_RATE * dt)
	var z := -f
	var x := up.cross(z).normalized()
	_sim_prev = _sim_xf
	if np.is_finite() and x.length_squared() > 0.5:
		_sim_xf = Transform3D(Basis(x, up, x.cross(up)).orthonormalized(), np)


## Someone outside the sim moved the node (spawn, respawn, skiff exit, aboard, another script):
## restart the sim and the interpolation there.
func _sync_from_node() -> void:
	if not _xf_ok(global_transform) or not _xf_ok(_sim_xf) or not _xf_ok(_sim_prev):
		_heal_xf()
		return
	if global_position.distance_to(_shown_xf.origin) > 0.05 or not global_transform.basis.is_equal_approx(_shown_xf.basis):
		_sim_xf = global_transform
		_sim_prev = global_transform
		_shown_xf = global_transform
		_vis_r = -1.0
		_pose_pos = Vector3.INF
		_hv = Vector3.ZERO


## A transform with finite numbers and a usable (non-degenerate) basis.
static func _xf_ok(xf: Transform3D) -> bool:
	return xf.origin.is_finite() and xf.basis.x.is_finite() and xf.basis.y.is_finite() and xf.basis.z.is_finite() \
			and absf(xf.basis.determinant()) > 1e-3


## 2026-10-07 (bots seen at NON-FINITE positions while they ran; Jolt flooded "cannot be normalized" on
## every ray that reached one): a non-finite or degenerate transform never sticks. The traced chain:
## a corpse / knockdown ragdoll blew up (ragdoll.gd kick_torso / kick_part: impulses on parts made that
## frame acted on 1 kg bodies, ~50-110 m/s), its bones went non-finite, the get-up stood the bot there
## (hit_reactor.gd _begin_getup -> host.global_transform), and _sync_from_node copied that into the sim
## for good. Both ends are guarded now; this puts the bot back on its last finite spot, upright.
func _heal_xf() -> void:
	var p: Vector3 = _sim_xf.origin
	if not p.is_finite():
		p = _vis_pos
	if not p.is_finite() and team_node != null and team_node.has_method("respawn_xf"):
		p = (team_node.respawn_xf(index) as Transform3D).origin
	if not p.is_finite():
		return
	var up: Vector3 = body.up_at(p) if body != null else Vector3.UP
	var f := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var x := up.cross(-f).normalized()
	var xf := Transform3D(Basis(x, up, x.cross(up)), p)
	global_transform = xf
	_sim_xf = xf
	_sim_prev = xf
	_shown_xf = xf
	_vis_pos = p
	_vis_r = -1.0
	_pose_pos = Vector3.INF
	_hv = Vector3.ZERO
	_knock = Vector3.ZERO
	_slide_v = Vector3.ZERO
	velocity = Vector3.ZERO
	if not _face.is_finite():
		_face = f
	if not is_finite(_vy):
		_vy = 0.0


## Every frame: the node shows the blend of the last two sim states (render interpolation, one sim
## step behind), with the ground height critically damped so steps between the analytic surface
## and dug (density) ground and small bumps never show; airborne bots are shown as simulated.
func _show_interpolated(delta: float) -> void:
	_sync_from_node()
	var tick: float = TICKS[lod]
	var pdt := 1.0 / float(Engine.physics_ticks_per_second)
	var a := clampf((_tick_acc + Engine.get_physics_interpolation_fraction() * pdt) / tick, 0.0, 1.0)
	var pos := _sim_prev.origin.lerp(_sim_xf.origin, a)
	var q := _sim_prev.basis.get_rotation_quaternion().slerp(_sim_xf.basis.get_rotation_quaternion(), a)
	if body != null:
		var c: Vector3 = body.global_position
		var rel := pos - c
		var r := rel.length()
		if r > 0.5:
			if _vis_r < 0.0 or _air or _climb or absf(r - _vis_r) > 1.5:
				_vis_r = r
				_vis_rv = 0.0
			else:
				# Critically damped spring toward the interpolated height (exact step).
				var x := _vis_r - r
				var e := exp(-HEIGHT_W * delta)
				var tmp := (_vis_rv + HEIGHT_W * x) * delta
				_vis_rv = (_vis_rv - HEIGHT_W * tmp) * e
				_vis_r = r + (x + tmp) * e
			pos = c + rel / r * (_vis_r - _lod_sink())       # far LOD meshes sit lower: never float
	_shown_xf = Transform3D(Basis(q), pos)
	global_transform = _shown_xf
	_vis_pos = pos


## True when the 16 m edit region holding world point w (or its +1 neighbour) was dug / raised.
func _edited(w: Vector3) -> bool:
	var ed: Dictionary = body.edits
	if ed.is_empty():
		return false
	var v := Vector3i((w - body.global_position).floor())
	return ed.has(Vector3i(v.x >> 4, v.y >> 4, v.z >> 4)) or ed.has(Vector3i((v.x + 1) >> 4, (v.y + 1) >> 4, (v.z + 1) >> 4))


## Ground at p: {"ok", "pos"} when it can step there from `from`, "blocked" for a wall / a step too
## high, neither when there is no ground within 2.5 m below. The height is the REAL ground
## (_true_ground): the drawn terrain collision near the camera, the edited density in dug places,
## the generator surface WITH its ±1.3 m detail noise elsewhere. (It used to take the analytic
## surface without that noise on undug ground: bots floated or sank by up to ~1.3 m.)
func _probe(p: Vector3, up: Vector3, from: Vector3) -> Dictionary:
	var g := _true_ground(p, up, 1.0, 2.5)
	if g == Vector3.INF:
		return {"ok": false, "blocked": false}
	if g == Vector3(-INF, -INF, -INF):
		return {"ok": false, "blocked": true}
	if (g - from).dot(up) > STEP_MAX:
		return {"ok": false, "blocked": true}
	return {"ok": true, "pos": g, "blocked": false}


## The real ground under (or around) p along `up`, searched from `above` m over p down to `below` m
## under it. Returns the ground point, Vector3.INF for none in the range, or (-INF, -INF, -INF) when
## p + up × above is already inside rock (a wall). Three sources, the most exact one available:
##   near the camera (collision exists): a physics ray against the terrain the player sees;
##   dug / raised places (an edit region nearby): the edited density, marched + bisected;
##   undug ground: the generator surface solved along the radius with its detail noise (the same
##   density the mesh is built from), a few noise samples.
func _true_ground(p: Vector3, up: Vector3, above: float, below: float) -> Vector3:
	var top := p + up * above
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	# Right after a dig / crater nearby the collision lags the ground (the chunk re-meshes, then its
	# shape is rebuilt up to ~0.2 s later): a bot probing it then stayed on the old rim, in the air
	# over the pit. While the edit is fresh the edited density decides (it is exact at once).
	var fresh_edit := Time.get_ticks_usec() - int(body.get("_last_edit_usec")) < 900000 \
			and (_edited(top) or _edited(p) or _edited(p - up * below))
	if cam != null and not fresh_edit and p.distance_to(cam.global_position) < 40.0:
		var q := PhysicsRayQueryParameters3D.create(top, p - up * below, Game.LAYER_TERRAIN)
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			return hit["position"]
		# (no hit: no collision built there yet, a wall we start inside, or no ground: the density says)
	if _edited(top) or _edited(p) or _edited(p - up * below):
		var h: Dictionary = body.raycast_density(top, p - up * below, 0.25, false)
		if h.is_empty():
			return Vector3.INF
		if float(h["distance"]) < 0.01:
			return Vector3(-INF, -INF, -INF)
		return h["position"]
	var c: Vector3 = body.global_position
	var rel := p - c
	var rl := rel.length()
	if rl < 1.0:
		return Vector3.INF
	var g := _surface_point(rel / rl)
	var h2 := (g - p).dot(up)
	if h2 > above:
		return Vector3(-INF, -INF, -INF)
	if h2 < -below:
		return Vector3.INF
	return g


## The undug surface along direction `dir` (unit, body-local): r = R + h(dir) - 1.3 × detail(r × dir)
## solved by a short fixed-point iteration (the detail noise changes slowly over the 1.3 m it moves).
func _surface_point(dir: Vector3) -> Vector3:
	var g = body.gen
	var s: Vector4 = g._surf(dir)
	var base := float(body.radius) + s.x
	var r := base
	for i in 3:
		r = base - float(g.n_detail.get_noise_3dv(dir * r)) * 1.3      # density d = r - R - h + 1.3 n = 0
	return body.global_position + dir * r


## The ground was edited (a crater, a drill, a dig, the island clean-up) near this bot: check its
## footing at the next step instead of up to 0.5 s later (it falls if the ground went away).
func _on_ground_edit(center: Vector3, radius: float) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	if center.distance_to(_sim_xf.origin) < radius + 2.5:
		_probe_t = 0.0


## How far to show the body below its exact ground: the far planet is drawn with coarse LOD cells
## (2-8 m) whose surface sits a little under the exact one on bumps; sinking a few cm into it reads
## far better than floating. 0 where the terrain is drawn at full detail. The cell's sink is re-read
## every 0.5 s; the shown sink eases toward it at SINK_EASE /s (2026-10-07: a LOD cell change moved
## the body by up to 0.7 m in one frame, a visible step, "düşmanlar titriyor").
const SINK_EASE := 3.0
var _sink := 0.0                       # shown (eased)
var _sink_goal := 0.0                  # the drawn cell's
var _sink_t := 0.0
func _lod_sink() -> float:
	var dt := get_process_delta_time()
	_sink_t -= dt
	if _sink_t <= 0.0:
		_sink_t = 0.5
		_sink_goal = _lod_sink_goal()
	_sink = lerpf(_sink, _sink_goal, 1.0 - exp(-SINK_EASE * dt))
	return _sink


func _lod_sink_goal() -> float:
	var disp: Dictionary = body.get("displayed") if body.get("displayed") is Dictionary else {}
	if disp.is_empty() or not _sim_xf.origin.is_finite():
		return 0.0
	var root: int = int(body.get("root"))
	var lmax: int = int(body.get("lod_max"))
	var v := Vector3i((_sim_xf.origin - body.global_position).floor())
	var n0: int = TerrainGen.N
	for l in lmax + 1:
		var span := n0 << l
		var k := Vector4i(root + _floor_div(v.x - root, span) * span, root + _floor_div(v.y - root, span) * span,
				root + _floor_div(v.z - root, span) * span, l)
		if disp.has(k):
			return [0.0, 0.2, 0.45, 0.9, 1.6][mini(l, 4)]
	return 0.0


static func _floor_div(a: int, b: int) -> int:
	return floori(float(a) / float(b))


func _on_blocked(up: Vector3, tgt: Vector3) -> void:
	if _hr_blocked():                    # a hit's shove ran into the wall: it stops there (end of file)
		return
	if _move_to == Vector3.INF and _strafe != Vector3.ZERO:
		_strafe = -_strafe
		_hv = Vector3.ZERO               # stop against the wall, then turn
		return
	var h: Dictionary = body.raycast_density(tgt + up * 4.5, tgt - up * 1.0, 0.3, true)
	var height := 99.0
	if not h.is_empty() and float(h["distance"]) > 0.01:
		height = ((h["position"] as Vector3) - _sim_xf.origin).dot(up)
	var g: float = Game.gravity_at(global_position).length()
	if height < 1.3 and not _reactor_busy():
		# A low obstacle or a crater rim: a real jump (no jet), keeping the walking momentum.
		_jump(sqrt(2.0 * g * (height + 0.45)), _hv)
	elif height < 3.5:
		_hop(maxf(Balance.AI_JET_HOP, sqrt(2.0 * g * (height + 0.7))), Vector3.ZERO)
	else:
		_climb = true
		_climb_t = 0.0


func _hop(v_up: float, lateral: Vector3) -> void:
	if _air or _climb or _hr_busy():
		return
	_air = true
	_vy = v_up
	_jet_t = 0.45
	_knock += lateral


# =================================================================================================
# Thinking
# =================================================================================================

func _think(dt: float) -> void:
	_bl_think(dt)                            # mood, signals, idle life (Reactions and body language, end of file)
	_perceive(dt)
	Heroes.bot_tick(self, dt, {"target": _target, "visible": _target_visible, "threat": _threat_pos,   # ultimates (scripts/war/heroes)
			"combat": mode == Mode.COMBAT, "under_fire": _now() - _threat_ms < 2000, "eye": _eye()})
	if _dn_think(dt):                        # a medic going to / reviving a downed teammate (Downed / revive, end of file)
		pass
	elif mode == Mode.COMBAT:
		_think_combat(dt)
	else:
		_think_work()
		_idle.think(self, dt)                    # natural idle: looks, weight, steps, kneel-dig (ai_idle.gd; "Natural idle" before "Raid site")
	var hh := 1.8 - 0.6 * maxf(_crouch_k, _slide_k * 1.3)      # (lower still in a slide)
	if absf(_cap.height - hh) > 0.05:
		_cap.height = hh
		_cap_cs.position = Vector3(0, hh * 0.5, 0)


func _perceive(dt: float) -> void:
	shooting_skiff = false
	if _al_perceive(dt):                     # bot vs bot sight; an ally bot stops here (end of file)
		return
	var pl = _pick_player()
	if _dn_skip_target(pl):                  # a downed player is left alone (unless ours to finish: end of file)
		pl = null
	if pl == null or not is_instance_valid(pl) or pl.is_dead():
		if _target == pl:
			_target_visible = false
		_skiff_seen_t = 0.0
		return
	var me := _eye()
	if pl.vehicle == null:
		_skiff_seen_t = 0.0
		var chest: Vector3 = pl.global_position + pl.global_transform.basis.y * 1.2
		var d := me.distance_to(chest)
		var vis := false
		if Game.dominant_body(chest) == body and d < Balance.AI_SIGHT_RANGE:
			var ang := _face.angle_to(chest - me) if _face != Vector3.ZERO else 0.0
			if d < Balance.AI_PREFERRED_RANGE or ang < deg_to_rad(75.0) or mode == Mode.COMBAT:
				vis = _los_clear(me, chest)
		if _target == null or _target == pl or not is_instance_valid(_target) or _target.is_in_group("war_structure") \
				or _al_is_bot(_target):          # (the player before an ally bot: end of file)
			if vis:
				_target = pl
		if _target == pl:
			_target_visible = vis
		if vis:
			_bl_spot(pl, chest)              # a new sighting: the beat, point, "!" (Reactions and body language)
			_seen_ms = _now()
			_threat_pos = chest
			if mode == Mode.WORK:
				_enter_combat(chest)
		return
	var sk = pl.vehicle
	if not (sk is Node3D) or not (sk as Node3D).is_in_group("skiff"):
		_skiff_seen_t = 0.0
		return
	var hull: Vector3 = (sk as Node3D).global_position + (sk as Node3D).global_transform.basis.y * 0.9
	var seen := false
	if hull.distance_to(me) < Balance.AI_SKIFF_RIFLE_RANGE:
		seen = _los_clear(me, hull - (hull - me).normalized() * 2.0)
	_skiff_seen_t = _skiff_seen_t + dt if seen else 0.0
	if _skiff_seen_t >= Balance.AI_SKIFF_REACT:
		_target = sk
		_target_visible = true
		_seen_ms = _now()
		_threat_pos = hull
		shooting_skiff = tok_shoot
		if mode == Mode.WORK:
			_enter_combat(hull)
	elif _target == sk:
		_target_visible = false


## Line of sight a -> b: physics when both ends are near the camera (collision exists there, cheap),
## else a density march when the team's per-frame budget allows (otherwise the last answer).
func _los_clear(a: Vector3, b: Vector3) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam != null and a.distance_to(cam.global_position) < 40.0 and b.distance_to(cam.global_position) < 40.0:
		var q := PhysicsRayQueryParameters3D.create(a, b, Game.LAYER_TERRAIN | Game.LAYER_SHIP)
		_los_cache = get_world_3d().direct_space_state.intersect_ray(q).is_empty()
		return _los_cache
	if team_node != null and not team_node.take_los():
		return _los_cache
	var h: Dictionary = body.raycast_density(a, b, 2.0, true)
	_los_cache = h.is_empty()
	return _los_cache


func _covered(from: Vector3, head: Vector3) -> bool:
	var seg := from - head
	var l := seg.length()
	if l < 2.0:
		return false
	var dir := seg / l
	for s in COVER_SAMPLES:
		var sd: float = s
		if sd > l - 1.0:
			break
		if body.density_fast(head + dir * sd) < 0.0:
			return true
	return false


# --- Work ---------------------------------------------------------------------------------------

func _think_work() -> void:
	if team_node == null:
		return
	if _bl_hold_work():                          # a pause / an idle inspection (Reactions and body language)
		return
	if team == "home" and _al_think_work():      # an ally bot: follow / guard / dig (end of file)
		return
	if _wx_task != "" and _wx_think_task():      # a weapon task first (end of file)
		return
	if _dg_task != "" and _dg_think_task():      # a dig task (Digging tactics, end of file)
		return
	if (_pod_phase != "" or _pod_tag) and _pod_think():   # drop-pod gunner / crew (end of file)
		return
	if not _vn_tgt.is_empty() and _vn_think():   # prospecting a rich vein / meteor core (end of file)
		return
	if foothold != null:                         # an enemy structure on our planet (rival_team.gd footholds)
		if is_instance_valid(foothold) and foothold.get("is_destroyed") != true:
			_raid_attack(foothold)
			return
		foothold = null
	match role:
		ROLE_ENGINEER:
			_work_engineer()
		ROLE_RAIDER:
			_work_raider()
		_:
			_set_held("terrain")
			_think_gather()


func _set_job(j: String) -> void:
	if j == _job:
		return
	if _job == "build" and _build_claimed and team_node != null:
		team_node.release_build(_build_kind)
	_build_claimed = false
	if _fire_cannon != null and is_instance_valid(_fire_cannon) and _fire_cannon.has_meta("ai_claim") and _fire_cannon.get_meta("ai_claim") == self:
		_fire_cannon.remove_meta("ai_claim")
	if _repair_target != null and is_instance_valid(_repair_target) and _repair_target.has_meta("ai_repair") and _repair_target.get_meta("ai_repair") == self:
		_repair_target.remove_meta("ai_repair")
	_job = j
	_stop_dig()
	_move_to = Vector3.INF
	_solve = {}
	_solved = false
	_solved_v = Vector3.ZERO
	_fire_cannon = null
	_build_spot = Vector3.INF
	_repair_target = null
	if j != "raid_attack" and mode == Mode.WORK:
		_target = null
		_target_visible = false


func _think_gather() -> void:
	if _job != "":
		_set_job("")
	if _dig_site == Vector3.INF or _dig_t > _rng.randf_range(14.0, 22.0):
		_dig_site = _pick_dig_site()
		_dig_t = 0.0
		_stop_dig()
	if not _digging:
		if _walk_to(_dig_site, Balance.AI_WALK_SPEED):
			_digging = true
			_shaft = false
			_dig_acc = 0.0
			_play(_dig_audio)


## Each bot digs on its own spot of a golden-angle spiral around the base (AI_MINE_MIN..MAX m),
## jittered a little each time; non-miners dig closer in.
func _pick_dig_site() -> Vector3:
	var n := maxi(Balance.BOT_COUNT, 1)
	var u := (float(index % n) + 0.5) / float(n)
	# The digging area grows with the team (3 bots: within ~14 m, 70 bots: out to AI_MINE_MAX).
	var spread := clampf(sqrt(float(n) / 70.0), 0.25, 1.0)
	var lo := Balance.AI_MINE_MIN if role == ROLE_MINER else Balance.AI_MINE_MIN * 0.6
	var hi := lerpf(lo + 4.0, Balance.AI_MINE_MAX, spread) * (1.0 if role == ROLE_MINER else 0.6)
	for i in 6:
		var arc := lerpf(lo, hi, sqrt(u)) + _rng.randf_range(-3.0, 3.0)
		var phi := float(index) * 2.39996 + _rng.randf_range(-0.25, 0.25)
		var p: Vector3 = team_node.around_base(maxf(arc, 2.0), phi)
		var ok := true
		for s in get_tree().get_nodes_in_group("war_structure"):
			if (s as Node3D).global_position.distance_to(p) < float(s.get_meta("footprint_r", 3.0)) + 4.0:
				ok = false
				break
		if ok:
			return _ground_at(p + _up_of(p) * 3.0)
	return team_node.base_xf.origin


func _up_of(p: Vector3) -> Vector3:
	return body.up_at(p)


## The unedited surface point under / over p (radial).
func _on_sphere(p: Vector3) -> Vector3:
	var c: Vector3 = body.global_position
	var d := (p - c).normalized()
	return c + d * (float(body.radius) + float(body.surface_height_at(p)))


## The real ground near p (dig sites, build spots, patrol points): see _true_ground.
func _ground_at(p: Vector3) -> Vector3:
	var up: Vector3 = body.up_at(p)
	var g := _true_ground(p, up, 1.6, 4.0)
	if g == Vector3(-INF, -INF, -INF):
		g = _true_ground(p + up * 8.0, up, 1.0, 8.0)       # inside a hill: look from higher up
	if g == Vector3.INF or g == Vector3(-INF, -INF, -INF):
		var h: Dictionary = body.raycast_density(p + up * 1.6, p - up * 40.0, 0.5, false)
		return h["position"] if not h.is_empty() else p
	return g


func _walk_to(p: Vector3, spd: float) -> bool:
	var up: Vector3 = body.up_at(global_position)
	var to := p - global_position
	if (to - up * to.dot(up)).length() < 1.2 and absf(to.dot(up)) < 3.0:
		_move_to = Vector3.INF
		return true
	_move_to = p
	_move_speed = spd
	_strafe = Vector3.ZERO
	return false


## Digging each physics frame: a real brush at AI_DIG_HZ only while the team lends a brush slot;
## the beam FX only with a pooled DigFx; otherwise dust puffs (near / mid bots).
func _dig_update(delta: float) -> void:
	# The dig loop follows the team's voice budget.
	if tok_audio != _dig_audio.playing:
		if tok_audio:
			_dig_audio.play()
		else:
			_dig_audio.stop()
	_dig_acc += delta
	var step := 1.0 / Balance.AI_DIG_HZ
	if _dig_acc >= step:
		_dig_acc -= step
		if _shaft:
			_dig_shaft(step)
		else:
			_dig_once(step)
	if _fx != null:
		_dig_fx()
	elif lod < 2:
		_puff_t -= delta
		if _puff_t <= 0.0:
			_puff_t = _rng.randf_range(1.2, 2.0)
			var soil: Color = body.get("soil_color") if body.get("soil_color") != null else Color(0.5, 0.3, 0.2)
			team_node.dust_puff(_dig_point if _dig_point != Vector3.ZERO else global_position, _up(), soil)


func _dig_once(dt: float) -> void:
	_dig_t += dt
	var up: Vector3 = body.up_at(global_position)
	var fwd := -global_transform.basis.z
	if not tok_brush:
		_dig_point = global_position + fwd * 2.0 - up * 0.3
		_dig_normal = up
		return
	var aim := global_position + fwd * 2.4 + up * 0.6
	var h: Dictionary = body.raycast_density(global_position + up * 1.5, aim - up * 6.0, 0.3, false)
	if h.is_empty():
		_dig_site = Vector3.INF
		_stop_dig()
		return
	_dig_point = h["position"]
	_dig_normal = h["normal"]
	var depth: float = float(body.radius) + float(body.surface_height_at(_dig_point)) - _dig_point.distance_to(body.global_position)
	if depth > Balance.AI_PIT_DEPTH:
		_dig_site = Vector3.INF
		_stop_dig()
		return
	Dig.dig_at(body, _dig_point, Balance.AI_DIG_RADIUS, Dig.MODE_DIG, Balance.AI_DIG_RATE * dt, Vector3.ZERO, Vector3.UP, -1.0, team)
	Core.drill_all(get_tree(), _dig_point, Balance.AI_DIG_RADIUS, team, dt)
	if not _mine_audio.playing and _rng.randf() < 0.25:
		_play(_mine_audio)


func _dig_shaft(dt: float) -> void:
	if _wx_task != "" and _wx_dig_tick(dt):       # interceptor / climber brush (end of file)
		return
	if _dg_task != "" and _dg_dig_tick(dt):       # a dig task's brush (Digging tactics, end of file)
		return
	if _vn_on and _vn_dig_tick(dt):               # prospecting brush (Prospecting, end of file)
		return
	var up: Vector3 = body.up_at(global_position)
	_dig_point = global_position - up * 0.7
	_dig_normal = up
	Dig.dig_at(body, _dig_point, Balance.RAID_DIG_RADIUS, Dig.MODE_DIG, Balance.RAID_DIG_RATE * dt, Vector3.ZERO, Vector3.UP, -1.0, team)
	Core.drill_all(get_tree(), _dig_point, Balance.RAID_DIG_RADIUS, team, dt)
	team_node.report_dig(_dig_point.distance_to(body.global_position) - Balance.CORE_RADIUS)
	if not _mine_audio.playing and _rng.randf() < 0.25:
		_play(_mine_audio)


func _dig_fx() -> void:
	var tip: Node3D = astronaut.held_tip("terrain")
	if tip == null:
		return
	_fx.tip_node = tip
	var up: Vector3 = global_transform.basis.y
	var soil: Color = body.get("soil_color") if body.get("soil_color") != null else Color(0.5, 0.3, 0.2)
	var r := Balance.RAID_DIG_RADIUS if _shaft else Balance.AI_DIG_RADIUS
	var p := _dig_point if _dig_point != Vector3.ZERO else global_position - global_transform.basis.z * 2.0
	_fx.work(tip.global_position, -tip.global_transform.basis.z, p, _dig_normal, up, 0, r, DIG_COLOR, soil)


func _stop_dig() -> void:
	if _digging:
		_digging = false
		_shaft = false
		_dig_audio.stop()
		if _fx != null:
			_fx.set_working(false)


# --- Engineer -----------------------------------------------------------------------------------

func _work_engineer() -> void:
	var t = team_node
	_set_held("terrain")
	match _job:
		"build":
			_think_build()
			return
		"fire":
			_think_fire()
			return
		"repair":
			_think_repair()
			return
	if t.wants_skiff() and t.material >= t.skiff_cost and t.claim_build("skiff"):
		_start_build("skiff")
		return
	var want: String = t.next_build()
	if want != "" and t.material >= t.build_cost(want) and t.claim_build(want):
		_start_build(want)
		return
	var rep := _repair_candidate()
	if rep != null:
		_set_job("repair")
		_repair_target = rep
		rep.set_meta("ai_repair", self)
		return
	if t.may_fire() and float(t.material) - Balance.AI_RESERVE >= Balance.SHELL_COST:
		var c := _ready_cannon()
		if c != null:
			_set_job("fire")
			_fire_cannon = c
			c.set_meta("ai_claim", self)
			_fire_target = _pick_target()
			return
	_think_gather()


func _start_build(kind: String) -> void:
	_set_job("build")
	_build_kind = kind
	_build_claimed = true


func _think_build() -> void:
	var t = team_node
	if _build_spot == Vector3.INF:
		_build_spot = _pick_build_spot(_build_kind)
		if _build_spot == Vector3.INF:
			_set_job("")
			return
	var up: Vector3 = body.up_at(_build_spot)
	var off := _build_spot - global_position
	off = off - up * off.dot(up)
	var stand := _build_spot - off.normalized() * (float(t.build_radius(_build_kind)) + 2.5)
	if not _walk_to(stand, Balance.AI_WALK_SPEED):
		return
	if not t.spend(t.build_cost(_build_kind)):
		_set_job("")
		return
	var to_home: Vector3 = t.home.global_position - _build_spot
	var fwd := to_home - up * to_home.dot(up)
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(Vector3.RIGHT)
	var z := -fwd.normalized()
	var x := up.cross(z).normalized()
	t.release_build(_build_kind)
	_build_claimed = false
	t.spawn_structure(_build_kind, Transform3D(Basis(x, up, x.cross(up)), _build_spot))
	_face = (_build_spot - global_position).normalized()
	_set_job("")


func _pick_build_spot(kind: String) -> Vector3:
	if DgKit.PIECES.has(kind):
		return _bk_pick_spot(kind)          # a base piece: BaseKit's spot (Digging tactics, end of file)
	var bx: Transform3D = team_node.base_xf
	var up := bx.basis.y
	var toward: Vector3 = team_node.home.global_position - bx.origin
	toward = (toward - up * toward.dot(up)).normalized()
	var side := up.cross(toward).normalized()
	var r: float = float(team_node.build_radius(kind))
	for i in 36:
		var off := toward * _rng.randf_range(4.0, Balance.AI_BUILD_AHEAD) \
				+ side * _rng.randf_range(-Balance.AI_BUILD_SIDE, Balance.AI_BUILD_SIDE)
		if i >= 20:
			# The front is full (a small planet): anywhere around the base.
			var a := _rng.randf() * TAU
			off = (toward * cos(a) + side * sin(a)) * _rng.randf_range(5.0, Balance.AI_BUILD_AHEAD * 1.3)
		if kind == "skiff":
			off = toward * _rng.randf_range(-Balance.AI_BUILD_AHEAD * 1.3, -Balance.AI_BUILD_AHEAD * 0.6) \
					+ side * _rng.randf_range(-Balance.AI_BUILD_SIDE * 0.8, Balance.AI_BUILD_SIDE * 0.8)
		var q := _on_sphere(bx.origin + off)       # the flat offset bent onto the small planet
		var p := _ground_at(q + _up_of(q) * 4.0)
		var pu: Vector3 = body.up_at(p)
		var ok := true
		for s in get_tree().get_nodes_in_group("war_structure"):
			if (s as Node3D).global_position.distance_to(p) < r + float(s.get_meta("footprint_r", 3.0)) + 1.5:
				ok = false
				break
		if not ok:
			continue
		var hmin := INF
		var hmax := -INF
		var tx := pu.cross(toward).normalized()
		for k in 6:
			var a := TAU * float(k) / 6.0
			var fq := _ground_at(p + (tx * cos(a) + toward * sin(a)) * r * 0.8 + pu * 3.0)
			var hh := (fq - p).dot(pu)
			hmin = minf(hmin, hh)
			hmax = maxf(hmax, hh)
		if hmax - hmin <= Balance.BUILD_MAX_STEP * (1.5 if kind == "skiff" else 1.0):
			return p + pu * hmin
	return Vector3.INF


func _repair_candidate() -> Node3D:
	if float(team_node.material) < 30.0:
		return null
	var best: Node3D = null
	var best_f := 0.6
	for s in team_node.cannons + team_node.flaks + team_node.busters:
		if not is_instance_valid(s) or s.is_destroyed:
			continue
		var who = s.get_meta("ai_repair") if s.has_meta("ai_repair") else null
		if who != null and who != self and is_instance_valid(who) and not who.is_dead():
			continue
		var f: float = float(s.hp) / maxf(float(s.hp_max), 1.0)
		if f < best_f:
			best_f = f
			best = s
	return best


func _think_repair() -> void:
	var s := _repair_target
	if s == null or not is_instance_valid(s) or s.is_destroyed or float(s.hp) >= float(s.hp_max) * 0.98:
		_set_job("")
		return
	var off := s.global_position - global_position
	var up: Vector3 = body.up_at(global_position)
	off = off - up * off.dot(up)
	if off.length() > 4.5:
		_walk_to(s.global_position - off.normalized() * 3.5, Balance.AI_WALK_SPEED)
		return
	_move_to = Vector3.INF
	_face = off.normalized()
	var amount := Balance.AI_REPAIR_RATE * float(THINK_WORK[lod])
	if not team_node.spend(amount * Balance.AI_REPAIR_COST):
		_set_job("")
		return
	s.hp = minf(float(s.hp) + amount, float(s.hp_max))


func _repair_fx() -> void:
	var tip: Node3D = astronaut.held_tip("terrain")
	if tip == null or not is_instance_valid(_repair_target):
		return
	_fx.tip_node = tip
	var p: Vector3 = _repair_target.global_position + _repair_target.global_transform.basis.y * 1.2
	_fx.work(tip.global_position, -tip.global_transform.basis.z, p, global_transform.basis.y,
			global_transform.basis.y, 1, 0.5, REPAIR_COLOR, REPAIR_COLOR)


# --- Engineer: cannons --------------------------------------------------------------------------

func _ready_cannon() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for c in team_node.cannons:
		if not is_instance_valid(c) or not c.ready_to_fire() or _now() < int(c.get_meta("ai_skip_until", 0)):
			continue
		var who = c.get_meta("ai_claim") if c.has_meta("ai_claim") else null
		if who != null and who != self and is_instance_valid(who) and not who.is_dead():
			continue
		var d: float = (c as Node3D).global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best = c
	return best


func _think_fire() -> void:
	var t = team_node
	var c := _fire_cannon
	if c == null or not is_instance_valid(c) or c.is_destroyed:
		_set_job("")
		return
	var cb: Basis = c.global_transform.basis
	var stand: Vector3 = c.global_position + (cb * Basis(Vector3.UP, c.yaw)) * Vector3(0, 0, 3.4)
	if not _walk_to(stand, Balance.AI_WALK_SPEED):
		return
	_face = -(cb * Basis(Vector3.UP, c.yaw)).z
	if not _solved and _solve.is_empty():
		_start_solve(c.muzzle_position(), _fire_target)
		return
	if not _solve.is_empty():
		return
	if _solved_v == Vector3.ZERO:
		c.set_meta("ai_skip_until", _now() + 25000)
		_set_job("")
		return
	c.aim_dir(_solved_v.normalized(), _solved_v.length())
	if not c.aligned() or not c.ready_to_fire():
		return
	if not t.may_fire():
		return
	if float(t.material) - Balance.AI_RESERVE < Balance.SHELL_COST or not t.spend(Balance.SHELL_COST):
		_set_job("")
		return
	t.last_shot_ms = _now()
	var tgt := _fire_target
	c.fire(true, func(point: Vector3, _b) -> void: _observe(point, tgt))
	_set_job("")


func _pick_target() -> Vector3:
	var home: Node3D = team_node.home
	if _rng.randf() < Balance.AI_TARGET_CANNON_CHANCE:
		var theirs: Array = []
		# Our cannons and auto-miners ("war_miner", scripts/war/auto_miner.gd when present) count
		# twice: the high-value targets; the Uçaksavar and the Delici Top once.
		for grp in ["war_cannon", "war_miner", "war_flak", "war_buster"]:
			for s in get_tree().get_nodes_in_group(grp):
				# (only on OUR planet: one built on theirs is a foothold for the rifles, not the guns)
				if s is Node3D and Game.team_of(s) == "home" and s.get("is_destroyed") != true \
						and Game.dominant_body((s as Node3D).global_position) == home:
					theirs.append(s)
					if grp == "war_cannon" or grp == "war_miner":
						theirs.append(s)
		if not theirs.is_empty():
			return (theirs[_rng.randi() % theirs.size()] as Node3D).global_position
	var dir: Vector3 = (team_node.body.global_position - home.global_position).normalized()
	var r: float = float(home.radius) + float(home.surface_height_at(home.global_position + dir * float(home.radius)))
	return home.global_position + dir * r + team_node.correction


func _start_solve(from: Vector3, target: Vector3) -> void:
	_solve = {"from": from, "target": target, "i": 0, "best_v": Vector3.ZERO, "best_d": INF,
			"best_el": 45.0, "best_spd": 0.0, "ref": -1, "h": 1.6}


## One trajectory per frame: a grid of speeds × elevations (the planet is a small target: only a
## few degrees of elevation land at all), then 10 refining steps on the elevation of the best hit.
func _step_solve() -> void:
	var speeds: Array = Balance.AI_SOLVE_SPEEDS
	var n_el := 22
	var i: int = _solve["i"]
	var spd := 0.0
	var el := 0.0
	if i < speeds.size() * n_el:
		spd = lerpf(Balance.CANNON_SPEED_MIN, Balance.CANNON_SPEED_MAX, float(speeds[i / n_el]))
		el = lerpf(15.0, 75.0, float(i % n_el) / float(n_el - 1))
		_solve["i"] = i + 1
	else:
		var ref: int = _solve["ref"] + 1
		if ref >= 10 or float(_solve["best_spd"]) <= 0.0:
			var bv: Vector3 = _solve["best_v"]
			if float(_solve["best_d"]) > Balance.AI_SOLVE_MAX_MISS:
				bv = Vector3.ZERO
			if bv != Vector3.ZERO and _solve.has("pod"):
				_solved_v = _pod_aim_error(bv)          # a drop pod: less error (Drop-pod raids)
			else:
				_solved_v = _apply_error(bv) if bv != Vector3.ZERO else Vector3.ZERO
			_solved = true
			_solve = {}
			return
		_solve["ref"] = ref
		spd = _solve["best_spd"]
		el = float(_solve["best_el"]) + float(_solve["h"]) * (1.0 if ref % 2 == 0 else -1.0)
		if ref % 2 == 1:
			_solve["h"] = float(_solve["h"]) * 0.5
	var v := Ballistics.launch_vector(_solve["from"], _solve["target"], spd, el)
	var r := Ballistics.predict(_solve["from"], v, Balance.SHELL_LIFE, 0.1)
	if not r.is_empty() and r.get("body") == team_node.home:
		var d := (r["position"] as Vector3).distance_to(_solve["target"])
		if d < float(_solve["best_d"]):
			_solve["best_d"] = d
			_solve["best_v"] = v
			_solve["best_el"] = el
			_solve["best_spd"] = spd


func _apply_error(v: Vector3) -> Vector3:
	var err: float = team_node.aim_err
	var axis := v.normalized().cross(Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1))).normalized()
	if axis.length_squared() < 0.5:
		axis = v.normalized().cross(Vector3.UP).normalized()
	var ang := deg_to_rad(err) * _rng.randf_range(-1.0, 1.0)
	var k := err / Balance.AI_AIM_ERROR_START
	var spd := v.length() * (1.0 + _rng.randf_range(-1.0, 1.0) * Balance.AI_SPEED_ERROR * k)
	return v.normalized().rotated(axis, ang) * spd


func _observe(point: Vector3, target: Vector3) -> void:
	if team_node == null:
		return
	team_node.aim_err = maxf(float(team_node.aim_err) * Balance.AI_AIM_ERROR_DECAY, Balance.AI_AIM_ERROR_MIN)
	if Game.dominant_body(point) == team_node.home and point.distance_to(target) < Balance.AI_OBSERVE_RANGE:
		# Learn only the miss ALONG the ground: impacts land in craters below the surface aim point,
		# and that depth part used to pile up as a bogus correction (hit AI_CORRECTION_MAX in ~10 shots).
		var miss := point - target
		var up_t: Vector3 = (target - (team_node.home as Node3D).global_position).normalized()
		miss -= up_t * miss.dot(up_t)
		var c: Vector3 = team_node.correction - miss * 0.6
		team_node.correction = c.limit_length(Balance.AI_CORRECTION_MAX)


# --- Guard / raider -----------------------------------------------------------------------------

func _work_raider() -> void:
	var t = team_node
	if not Balance.RAIDS_ENABLED:
		_work_guard()
		return
	match t.raid_phase(self):
		"board", "return":
			_go_board()
		"site":
			_raid_on_site()
		"aboard":
			pass
		_:
			_work_guard()                      # between raids: guards the base (skiff raids, rival_team.gd)


func _work_guard() -> void:
	if _job != "guard":
		_set_job("guard")
		_guard_wp = Vector3.INF
		_guard_wait = 0.0
	_set_held("rifle")
	if _guard_wp == Vector3.INF:
		_guard_wp = _pick_guard_point()
	if not _walk_to(_guard_wp, Balance.AI_WALK_SPEED):
		return
	_guard_wait -= float(THINK_WORK[lod])
	if _guard_wait <= 0.0:
		_guard_wait = _rng.randf_range(2.5, 6.0)
		_guard_wp = Vector3.INF
		var bx: Transform3D = team_node.base_xf
		var out := global_position - bx.origin
		var up := _up()
		out = out - up * out.dot(up)
		if out.length_squared() > 0.01:
			_face = out.normalized().rotated(up, _rng.randf_range(-0.9, 0.9))


func _pick_guard_point() -> Vector3:
	var cpg := _cp_guard_point()                  # Bölge kontrolü: retake our lost / contested zone (end of file)
	if cpg != Vector3.INF:
		return cpg
	var structs: Array = team_node.cannons + team_node.flaks
	if not structs.is_empty() and _rng.randf() < 0.5:
		var s = structs[_rng.randi() % structs.size()]
		if is_instance_valid(s):
			var c: Vector3 = (s as Node3D).global_position
			var up: Vector3 = body.up_at(c)
			var x := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
			var z := up.cross(x).normalized()
			var a := _rng.randf() * TAU
			var q := _on_sphere(c + (x * cos(a) + z * sin(a)) * _rng.randf_range(6.0, 14.0))
			return _ground_at(q + _up_of(q) * 3.0)
	var arc := _rng.randf_range(Balance.AI_GUARD_RADIUS * 0.3, Balance.AI_GUARD_RADIUS)
	var p: Vector3 = team_node.around_base(arc, _rng.randf() * TAU)
	return _ground_at(p + _up_of(p) * 3.0)


func _go_board() -> void:
	var sk: Node3D = team_node.skiff
	if sk == null or not is_instance_valid(sk):
		return
	_set_job("board")
	_set_held("rifle")
	var to := sk.global_position - global_position
	var up: Vector3 = body.up_at(global_position)
	var flat := to - up * to.dot(up)
	if flat.length() > 4.0 or absf(to.dot(up)) > 3.0:
		_move_to = sk.global_position
		_move_speed = Balance.AI_RUN_SPEED
		return
	_board(sk)


func _board(sk: Node3D) -> void:
	_stop_dig()
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_air = false
	_climb = false
	if sk.has_method("ai_board") and not sk.ai_board(self):
		return                             # (not landed / full / not ours: skiff.gd AI pilot)
	aboard = sk
	mode = Mode.ABOARD
	visible = false
	_cap_cs.disabled = true
	_job = ""


func exit_skiff() -> void:
	if mode != Mode.ABOARD:
		return
	var sk := aboard
	var xf := Transform3D(global_transform.basis, global_position)
	if sk != null and is_instance_valid(sk):
		if sk.has_method("ai_exit"):
			xf = sk.ai_exit(self)
			if xf.origin == Vector3.ZERO:
				return                         # (still flying: stays aboard, skiff.gd AI pilot)
		else:
			xf = Transform3D(sk.global_transform.basis, sk.global_position + sk.global_transform.basis.x * 3.0)
	aboard = null
	mode = Mode.WORK
	visible = true
	_cap_cs.disabled = false
	var nb: Node3D = Game.dominant_body(xf.origin)
	if nb != null:
		body = nb
	global_transform = xf
	_vis_pos = xf.origin
	_face = -xf.basis.z
	_air = true
	_vy = 0.0
	_job = ""


func die_aboard() -> void:
	if mode != Mode.ABOARD:
		return
	mode = Mode.WORK
	visible = true
	aboard = null
	_die(Vector3.ZERO)


func _tick_aboard() -> void:
	if aboard == null or not is_instance_valid(aboard):
		die_aboard()
		return
	global_position = aboard.global_position


func _raid_on_site() -> void:
	if _dg_raid_site():                      # the enemy core shield / a door in the way (Digging tactics)
		return
	var t = team_node
	var digger: bool = t.raid_digger() == self
	var s := _nearest_enemy_structure(Balance.RAID_STRUCT_RANGE)
	var calm := _now() - _threat_ms > int(Balance.RAID_CALM_TIME * 1000.0) and _now() - _seen_ms > int(Balance.RAID_CALM_TIME * 1000.0)
	var solo: bool = t.raid_crew_size() <= 1          # (skiff raiders + landed drop-pod crews)
	if s != null and (not digger or (solo and s.global_position.distance_to(global_position) < Balance.RAID_STRUCT_RANGE * 0.5)):
		_raid_attack(s)
		return
	if digger and calm:
		if _job != "raid_dig":
			_set_job("raid_dig")
			_set_held("terrain")
		if not _digging:
			_digging = true
			_shaft = true
			_dig_acc = 0.0
			_play(_dig_audio)
		return
	_set_job("raid_guard")
	_set_held("rifle")
	var d = t.raid_digger()
	if d != null and d != self and is_instance_valid(d):
		if d.global_position.distance_to(global_position) > 10.0:
			_walk_to(d.global_position, Balance.AI_WALK_SPEED)


func _raid_attack(s: Node3D) -> void:
	if _job != "raid_attack":
		_set_job("raid_attack")
	_set_held("rifle")
	_target = s
	var aimp := _aim_point(s)
	var d := _eye().distance_to(aimp)
	var vis := d < Balance.AI_PREFERRED_RANGE * 1.4 and _los_clear(_eye(), aimp - (aimp - _eye()).normalized() * 2.5)
	_target_visible = vis
	_face = (aimp - global_position).normalized()
	if not vis:
		_walk_to(s.global_position, Balance.AI_RUN_SPEED if d > 30.0 else Balance.AI_WALK_SPEED)
	else:
		_move_to = Vector3.INF
		if _strafe == Vector3.ZERO or _rng.randf() < 0.1:
			var up: Vector3 = body.up_at(global_position)
			_strafe = up.cross(aimp - global_position).normalized() * (1.0 if _rng.randf() < 0.5 else -1.0)
			_strafe_speed = 1.5


func _nearest_enemy_structure(rng: float) -> Node3D:
	var best: Node3D = null
	var best_d := rng
	# (+ our Silahlık and auto-miners: "war_miner", scripts/war/auto_miner.gd when present; base pieces,
	# scripts/war/base_kit.gd: turrets, doors, the core shield, radars, bunker modules)
	for grp in ["war_cannon", "war_flak", "war_buster", "war_torpedo_rig", "war_armory", "war_miner",
			"war_turret", "war_blast_door", "war_core_shield", "war_radar", "war_bunker"]:
		for s in get_tree().get_nodes_in_group(grp):
			if not (s is Node3D) or Game.team_of(s) == team or s.get("is_destroyed") == true:
				continue
			var d := _dg_struct_rank(s, (s as Node3D).global_position.distance_to(global_position))   # (priority: Digging tactics)
			if d < best_d:
				best_d = d
				best = s
	return best


# --- Combat -------------------------------------------------------------------------------------

func _enter_combat(threat: Vector3) -> void:
	if mode != Mode.WORK:
		return
	_set_job("")
	mode = Mode.COMBAT
	_set_held("rifle")
	_threat_pos = threat
	_tac = Tac.NONE
	_tac_t = 0.0
	_think_acc = 1.0                     # decide right away
	_radio_call("contact" if _now() - _seen_ms < 300 else "alert")   # radio chatter (end of file)
	if _now() - _help_ms > 5000:
		_help_ms = _now()
		team_node.call_help(self, threat)


func _leave_combat() -> void:
	mode = Mode.WORK
	_tac = Tac.NONE
	_crouch = false
	_peek = false
	_strafe = Vector3.ZERO
	_move_to = Vector3.INF
	_cover_pos = Vector3.INF
	_cover_search = {}
	if _is_player(_target) or (_target != null and is_instance_valid(_target) and _target.is_in_group("skiff")):
		_target = null
	_target_visible = false
	_job = ""


func help_call(threat: Vector3) -> void:
	if mode != Mode.WORK or _al_friendly_src(threat):   # (an ally: not at our own player, end of file)
		return
	_threat_ms = _now() - 1500
	_enter_combat(threat)
	_tac = Tac.ADVANCE
	_tac_t = 4.0
	_move_to = threat
	_move_speed = Balance.AI_RUN_SPEED


func _on_threat(src: Vector3, hit: bool) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD or _al_friendly_src(src):   # (an ally hit by our player)
		return
	_threat_ms = _now()
	if src != Vector3.INF:
		_threat_pos = src
	if mode == Mode.WORK:
		_enter_combat(_threat_pos if _threat_pos != Vector3.INF else global_position)
	# (2026-10-06 tok: a near miss no longer cuts a strafe that still runs > AI_STRAFE_HOLD s: fewer
	# left-right flips under fire; a hit still makes it re-decide at once.)
	var keep_strafe := not hit and _tac == Tac.STRAFE and _tac_t > Balance.AI_STRAFE_HOLD
	if not (_tac == Tac.COVER and _crouch) and _tac != Tac.FLEE and _tac != Tac.TO_COVER and not keep_strafe:
		_tac_t = 0.0
		_think_acc = 1.0
	if not hit:
		_schedule_dodge()                # a slide / jump / jet hop sideways, after a reaction delay
	_sup_add(Balance.AI_SUP_HIT if hit else 0.0)   # a hit pins it too (Suppression, end of file)


func _on_shot(from: Vector3, dir: Vector3, t: String) -> void:
	if t == team or mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	var c := global_position + global_transform.basis.y * 1.1
	var rel := c - from
	var along := rel.dot(dir)
	_bl_heard(from, dir, along, rel)     # gunfire heard (Reactions and body language, end of file)
	if along < 0.0 or along > 400.0:
		return
	_sup_near_miss(dir, (rel - dir * along).length())   # cracks feed the suppression meter (end of file)
	if (rel - dir * along).length() < Balance.AI_NEAR_MISS:
		_on_threat(_bl_shot_src(from, dir, along), false)   # (a suppressed far shot: only roughly placed)


func _on_blast(pos: Vector3, radius: float, t: String) -> void:
	if t == team or mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	var d := global_position.distance_to(pos)
	if d > maxf(radius * 3.0, 12.0):
		return
	var src := pos
	var pl = _pick_player()
	if pl != null and is_instance_valid(pl) and Game.dominant_body(pl.global_position) == body \
			and pl.global_position.distance_to(global_position) < Balance.AI_SIGHT_RANGE:
		src = pl.global_position + pl.global_transform.basis.y * 1.2
	_hr_blast(pos, d, radius)            # the blast's shove (hit reactions, end of file)
	_bl_on_blast(pos, d, radius)         # cowering (Reactions and body language, end of file)
	_sup_blast(d, radius)                # (Suppression, end of file)
	_on_threat(src, false)


func _think_combat(dt: float) -> void:
	var now := _now()
	var t = team_node
	var phase: String = t.raid_phase(self)
	if phase == "return" or phase == "board":
		_leave_combat()
		return
	if _target != null and not is_instance_valid(_target):
		_target = null
		_target_visible = false
	if _is_player(_target) and _target.is_dead():
		_target = null
		_target_visible = false
	_pr_observe(now)                             # sight tracking, last known position (end of file)
	var calm := Balance.AI_CALM_AFTER * 1000.0
	if not _target_visible and now - _threat_ms > int(calm) and now - _seen_ms > int(calm) \
			and not _pr_keep_combat(now):        # (still hunting him: end of file)
		_leave_combat()
		return
	if _target_visible and _target != null:
		_threat_pos = _aim_point(_target)
	if lod == 0:
		_step_cover_search()
	else:
		_cover_search = {}
	_tac_t -= dt
	var under_fire := now - _threat_ms < 2000
	var low := hp < hp_max * Balance.AI_FLEE_HP and _pod_phase != "site"   # (a pod crew fights to the death)
	var threat := _threat_pos if _threat_pos != Vector3.INF else global_position
	var up := _up()
	var to_t := threat - global_position
	var dist := to_t.length()
	if _target_visible or under_fire:
		_face = to_t.normalized()
	if _dg_combat(dt, threat, dist, under_fire, low):   # foxhole / escape pit / shelter / dig out (end of file)
		return
	if low and _tac != Tac.FLEE:
		_tac = Tac.FLEE
		_tac_t = 12.0
		if lod == 0:
			_request_cover(threat, true)
		if now - _help_ms > 3000:
			_help_ms = now
			t.call_help(self, threat)
	match _tac:
		Tac.FLEE:
			_crouch = false
			_peek = false
			if _cover_pos != Vector3.INF:
				_move_to = _cover_pos
				_move_speed = Balance.AI_RUN_SPEED
				_strafe = Vector3.ZERO
				if global_position.distance_to(_cover_pos) < 1.5:
					_crouch = true
			elif _cover_search.is_empty():
				var away := -(to_t - up * to_t.dot(up)).normalized()
				_move_to = global_position + away * 15.0
				_move_speed = Balance.AI_RUN_SPEED
			if not _target_visible and _move_to != Vector3.INF:
				_face = (_move_to - global_position).normalized()
			if (not low and _tac_t <= 0.0) or _tac_t <= -20.0:
				_tac = Tac.NONE
		Tac.TO_COVER:
			_crouch = false
			if _cover_pos == Vector3.INF:
				_tac = Tac.NONE
			else:
				_move_to = _cover_pos
				_move_speed = Balance.AI_RUN_SPEED
				_strafe = Vector3.ZERO
				_maybe_slide_to(_cover_pos, under_fire, 0.8)     # slide into cover (Slides and jumps)
				if global_position.distance_to(_cover_pos) < 1.4 or _tac_t <= 0.0:
					_tac = Tac.COVER
					_tac_t = _rng.randf_range(6.0, 12.0)
					_crouch = true
					_peek = false
					_peek_t = _rng.randf_range(0.6, 1.4)
		Tac.COVER:
			_move_to = Vector3.INF
			_strafe = Vector3.ZERO
			_peek_t -= dt
			if _peek_t <= 0.0:
				_peek = not _peek
				_peek_t = _rng.randf_range(1.2, 2.2) if _peek else _rng.randf_range(0.8, 1.8)
				_peek_t *= _sup_peek_k(_peek)   # pinned: short peeks, long hides (Suppression, end of file)
				if _peek and not _sup_pinned:
					_maybe_jump_peek()          # sometimes a jump over the rim instead (Slides and jumps)
			if _reload_t > 0.0:
				_peek = false
			_crouch = not _peek
			if _rng.randf() < 0.3 and not _covered(threat, global_position + up * (EYE_H - CROUCH_DROP)):
				_tac_t = 0.0
			if _tac_t <= 0.0:
				_tac = Tac.NONE
				_crouch = false
		Tac.STRAFE:
			_crouch = false
			_move_to = Vector3.INF
			if _tac_t <= 0.0:
				_tac = Tac.NONE
		Tac.ADVANCE:
			_crouch = false
			if dist < Balance.AI_PREFERRED_RANGE or _tac_t <= 0.0:
				_tac = Tac.NONE
			elif _move_to == Vector3.INF:
				_move_to = threat
				_move_speed = Balance.AI_STRAFE_SPEED
			elif _move_speed >= Balance.AI_RUN_SPEED * 0.9:
				_maybe_slide_to(_move_to, under_fire, 0.45)  # across an open gap (Slides and jumps)
		Tac.HOLD:
			_crouch = false
			_move_to = Vector3.INF
			_strafe = Vector3.ZERO
			if under_fire or _tac_t <= 0.0:
				_tac = Tac.NONE
		Tac.FLANK, Tac.SUPPRESS, Tac.HUNT:
			_pr_tac_tick(dt, threat, dist, under_fire)   # Pressure, cover and lethality (end of file)
	if _tac == Tac.NONE:
		_decide(threat, dist, under_fire)
	_wx_think_grenade()                          # El bombası (end of file)


## A new tactic. Far bots (lod > 0) keep it simple: no cover search, close in / strafe; bots
## without a shooter token keep moving (flank, advance) instead of holding.
func _decide(threat: Vector3, dist: float, under_fire: bool) -> void:
	if _sup_decide(threat):                      # pinned: duck / hold cover / fall back, never advance (end of file)
		return
	if _pr_decide(threat, dist, under_fire):     # pressure / flank / suppress / outgunned / hunt (end of file)
		return
	var up := _up()
	var to_t := threat - global_position
	var flat := (to_t - up * to_t.dot(up)).normalized()
	var side := up.cross(flat).normalized() * (1.0 if _rng.randf() < 0.5 else -1.0)
	if lod > 0:
		if dist > Balance.AI_PREFERRED_RANGE * 1.2:
			_tac = Tac.ADVANCE
			_tac_t = _rng.randf_range(2.0, 4.0)
			_move_to = global_position + (flat * 0.8 + side * 0.5).normalized() * minf(12.0, dist * 0.5)
			_move_speed = Balance.AI_RUN_SPEED if dist > 50.0 else Balance.AI_STRAFE_SPEED
		else:
			_strafe_for(side, _rng.randf_range(1.0, 2.0), Balance.AI_STRAFE_SPEED)
		return
	var cover_fresh := _cover_pos != Vector3.INF and _covered(threat, _cover_pos + up * (EYE_H - CROUCH_DROP)) \
			and _cover_pos.distance_to(global_position) < 16.0
	if _reload_t > 0.0 or under_fire:
		if cover_fresh:
			_tac = Tac.TO_COVER
			_tac_t = 5.0
			return
		if _cover_search.is_empty():
			_request_cover(threat, false)
		_strafe_for(side, _rng.randf_range(0.7, 1.3), Balance.AI_STRAFE_SPEED * 1.2)
		return
	if not _target_visible:
		if _threat_pos != Vector3.INF and dist > 6.0:
			_tac = Tac.ADVANCE
			_tac_t = _rng.randf_range(2.5, 4.0)
			_move_to = threat - flat * 6.0
			_move_speed = Balance.AI_WALK_SPEED
		else:
			_strafe_for(side, 1.0, Balance.AI_WALK_SPEED)
		return
	if not tok_shoot:
		# Not allowed to fire now: reposition (flank around, or take a covered spot).
		if cover_fresh and _rng.randf() < 0.5:
			_tac = Tac.TO_COVER
			_tac_t = 5.0
		else:
			_tac = Tac.ADVANCE
			_tac_t = _rng.randf_range(2.0, 3.5)
			_move_to = global_position + (side * 0.9 + flat * 0.3).normalized() * 8.0
			_move_speed = Balance.AI_STRAFE_SPEED
		return
	if dist > Balance.AI_PREFERRED_RANGE * 1.7:
		_tac = Tac.ADVANCE
		_tac_t = _rng.randf_range(1.5, 3.0)
		_move_to = global_position + (flat * 0.8 + side * 0.6).normalized() * minf(10.0, dist * 0.4)
		_move_speed = Balance.AI_STRAFE_SPEED
		return
	if dist < Balance.AI_PREFERRED_RANGE * 0.45:
		_strafe_for((side - flat * 0.8).normalized(), _rng.randf_range(1.0, 1.8), Balance.AI_STRAFE_SPEED)
		return
	var r := _rng.randf()
	if r < 0.3:
		_tac = Tac.HOLD
		_tac_t = _rng.randf_range(0.8, 1.5)
	elif r < 0.65:
		if cover_fresh:
			_tac = Tac.TO_COVER
			_tac_t = 5.0
		else:
			_request_cover(threat, false)
			_strafe_for(side, _rng.randf_range(0.8, 1.4), Balance.AI_STRAFE_SPEED)
	else:
		_strafe_for(side, _rng.randf_range(1.0, 2.0), Balance.AI_STRAFE_SPEED)


func _strafe_for(dir: Vector3, t: float, spd: float) -> void:
	_tac = Tac.STRAFE
	_tac_t = t * Balance.AI_STRAFE_TIME_K     # (2026-10-06 tok: longer, steadier strafes)
	_strafe = dir
	_strafe_speed = spd
	_move_to = Vector3.INF
	_crouch = false


func _request_cover(threat: Vector3, away: bool) -> void:
	_cover_search = {"threat": threat, "i": 0, "best": Vector3.INF, "best_s": -INF, "away": away}


## The shared per-physics-frame budgets (THINKS_PER_FRAME, COVER_USEC_PER_FRAME), refilled on a new frame.
static func _budget_refill() -> void:
	var f := Engine.get_physics_frames()
	if f != _budget_frame:
		_budget_frame = f
		_thinks_left = THINKS_PER_FRAME
		_cover_us_left = COVER_USEC_PER_FRAME


var _think_wait := 0.0                 # s this bot's due decision has waited for a slot


## May this bot think this physics frame? A bot that waited THINK_LATE_MAX s goes anyway.
func _take_think(delta: float) -> bool:
	_budget_refill()
	if _thinks_left > 0 or _think_wait >= THINK_LATE_MAX:
		_thinks_left -= 1
		_think_wait = 0.0
		return true
	_think_wait += delta
	return false


## Tests up to 4 cover candidates per think (as many as the team's per-frame budget allows).
func _step_cover_search() -> void:
	if _cover_search.is_empty():
		return
	var budget: int = team_node.take_cover_eval(4) if team_node != null else 4
	_budget_refill()
	if budget <= 0 or _cover_us_left <= 0:       # (and the shared µs budget: COVER_USEC_PER_FRAME)
		return
	var cover_t0 := Time.get_ticks_usec()
	var threat: Vector3 = _cover_search["threat"]
	var away: bool = _cover_search["away"]
	var up := _up()
	var x := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var z := up.cross(x).normalized()
	var total := COVER_DIRS * COVER_RADII.size()
	var d_now := global_position.distance_to(threat)
	for k in budget:
		var i: int = _cover_search["i"]
		if i >= total or (k > 0 and Time.get_ticks_usec() - cover_t0 >= _cover_us_left):
			break
		_cover_search["i"] = i + 1
		var r: float = COVER_RADII[i / COVER_DIRS]
		var a := TAU * float(i % COVER_DIRS) / float(COVER_DIRS) + float(index) * 0.4
		var p := global_position + (x * cos(a) + z * sin(a)) * r
		var g_d := _probe(p, up, global_position + up * 20.0)
		if not g_d["ok"]:
			continue
		var g: Vector3 = g_d["pos"]
		if not _covered(threat, g + up * (EYE_H - CROUCH_DROP)):
			continue
		var d_new := g.distance_to(threat)
		var score := -r * 0.5
		if away:
			score += (d_new - d_now) * 1.0
		else:
			score -= maxf(0.0, d_now - d_new - 4.0) * 0.4
			if d_new < 10.0:
				score -= 20.0
		if score > float(_cover_search["best_s"]):
			_cover_search["best_s"] = score
			_cover_search["best"] = g
	_cover_us_left -= int(Time.get_ticks_usec() - cover_t0)
	if int(_cover_search["i"]) >= total:
		_cover_pos = _cover_search["best"]
		_cover_search = {}
		if _cover_pos != Vector3.INF and (_tac == Tac.STRAFE or _tac == Tac.NONE):
			_tac = Tac.TO_COVER
			_tac_t = 5.0


func _aim_point(n: Node3D) -> Vector3:
	if Downed.is_downed(n):
		return Downed.aim_point(n)           # the lying chest (Downed / revive, end of file)
	if _is_player(n):
		# Lower head while the player crouches / slides (player.crouch_k, 0..1).
		var ck = n.get("crouch_k")
		var k: float = float(ck) if ck != null else 0.0
		return n.global_position + n.global_transform.basis.y * (1.2 - 0.55 * k)
	if n.is_in_group("skiff"):
		return n.global_position + n.global_transform.basis.y * 0.9
	return n.global_position + n.global_transform.basis.y * 1.4


## The rifle: bursts, magazine and reload, hit chance from distance, own movement, being under
## fire and settling. Against the player / his skiff only with the team's shooter token.
func _shoot_update(delta: float) -> void:
	_rifle_t -= delta
	if _reload_t > 0.0:
		_reload_t -= delta
		if _reload_t <= 0.0:
			_mag = Balance.AI_MAG
		return
	var tg := _target
	if tg == null or not is_instance_valid(tg) or not (_target_visible or _pr_blind_fire()):   # (blind: suppression)
		return
	var vs_player: bool = _is_player(tg) or tg.is_in_group("skiff")
	if vs_player and not tok_shoot:
		return
	# (a slide may fire from its second half on; a jump from its apex down)
	if _flinch > 0.0 or _climb or (_air and _vy > 1.0) or (_crouch_k > 0.5 and not _peek and not sliding):
		return
	if sliding and _slide_t < 0.35:
		return
	if is_staggered() or is_down():          # off balance: no firing (hit reactions)
		return
	if not sliding and _move_to != Vector3.INF and _move_speed >= Balance.AI_RUN_SPEED * 0.9 and velocity.length() > 3.0:
		return
	if _rifle_t > 0.0:
		return
	if _mag <= 0:
		_reload_t = Balance.AI_RELOAD
		_burst = 0
		_radio_call("reload")
		return
	var is_pl: bool = _is_player(tg)
	if _burst <= 0:
		_burst = _pr_burst_len(is_pl)        # short controlled bursts (end of file)
	_burst -= 1
	_rifle_t = _pr_shot_gap(is_pl, _burst > 0)
	_mag -= 1
	var me := _eye()
	var aimp := _aim_point(tg) if _target_visible else _threat_pos     # (blind: where he ducked)
	var to := aimp - me
	var dist := to.length()
	var structure: bool = tg.is_in_group("war_structure") and not tg.is_in_group("skiff")
	var rng_max := Balance.AI_SKIFF_RIFLE_RANGE if tg.is_in_group("skiff") else Balance.AI_FIGHT_RANGE
	# Distance, own movement, settling, being under fire, sight time, the lead (end of file).
	var chance := _pr_hit_chance(tg, dist, rng_max, is_pl)
	if sliding:
		chance *= Balance.AI_ACC_SLIDE
	elif _air:
		chance *= Balance.AI_ACC_AIR
	chance *= _sup_acc()                     # pinned: wild bursts (Suppression, end of file)
	if structure:
		chance = 0.8
	var end := aimp
	if _target_visible and _rng.randf() < clampf(chance, 0.03, 0.9):
		var dmg := Balance.AI_RIFLE_DAMAGE
		if structure:
			dmg = Balance.AI_RIFLE_STRUCT_DAMAGE
		elif not is_pl and not _al_is_bot(tg):   # (a bot target, ally bots: the full rifle damage)
			dmg = Balance.AI_SKIFF_RIFLE_DAMAGE
		Game.damage_target(tg, dmg, me, to.normalized() * (0.6 if is_pl else 0.0), team,
				aimp + Vector3(_rng.randf_range(-0.2, 0.2), _rng.randf_range(-0.35, 0.25), _rng.randf_range(-0.2, 0.2)))   # (hit point: hit reactions)
	else:
		var spread := clampf(dist * 0.06, 0.6, 4.0)
		if _tac == Tac.SUPPRESS:
			spread = _rng.randf_range(0.5, Balance.AI_PR_SUPPRESS_MISS)       # close past him: pinning cracks
		spread *= _sup_spread()              # (pinned: wider, Suppression)
		var miss := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * spread
		end = aimp + miss + to.normalized() * 6.0
	var tip: Node3D = astronaut.held_tip("rifle")
	var muzzle: Vector3 = tip.global_position if tip != null else me
	EnemyFire.shot(muzzle, end, team, end == aimp)   # flash halo, flying red tracer, where a miss lands (Suppression section)
	if _light_on:
		_flash.global_position = muzzle
		_flash_t = 1.0
	_fire_vis = 0.25
	_gun_audio.global_position = muzzle
	_play(_gun_audio)
	# Near-miss whizz / crack for the player (gun_feel listens to Game.shot_fired).
	Game.shot_fired.emit(muzzle, (end - muzzle).normalized(), team)
	if Net.is_host():
		Net.bots.on_bot_shot(self, end)


# =================================================================================================
# Health
# =================================================================================================

func take_damage(amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO) -> Dictionary:
	if mode == Mode.DEAD:
		_hr_dead_hit(impulse)                # the rest of a killing blast still throws the corpse (end of file)
	if mode == Mode.DEAD or mode == Mode.ABOARD or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	if Downed.is_downed(self):               # down: hits drain its bleed-out (Downed / revive, end of file)
		return Downed.hurt_downed(self, amount, from_pos, impulse)
	var dn_hp0 := hp
	if Net.is_host():
		Net.bots.on_bot_hit(self, from_pos, amount, impulse)     # (a knocked-down puppet's ragdoll takes the shove)
	hp = maxf(hp - amount, 0.0)
	_hurt_ms = _now()
	_bl_note_hit(from_pos)                   # who hit it last (Reactions and body language, end of file)
	_hr_hit(amount, from_pos, impulse)       # hit reactions: flinch / stagger / knockdown (end of file)
	if hp > 0.0:
		_flinch = maxf(_flinch, Balance.HR_FLINCH_AIM)  # (the reactor holds it longer: its aim_block)
		_radio_call("hit")
		_on_threat(from_pos if from_pos != Vector3.ZERO else Vector3.INF, true)
		if team_node != null and team_node.raid_phase(self) == "site" and hp < hp_max * Balance.RAID_RETREAT_HP:
			team_node.raid_retreat(self)       # (only a skiff raider calls the raid home, not a pod crew)
		return {"dmg": amount, "killed": false}
	if Downed.try_down(self, amount, from_pos, impulse, dn_hp0):   # not overkill: down, not dead (end of file)
		return {"dmg": amount, "killed": false, "downed": true}
	_die(impulse)
	return {"dmg": amount, "killed": true}


func _die(impulse: Vector3) -> void:
	_set_job("")
	_stop_dig()
	_set_held("")
	shooting_skiff = false
	_target = null
	_target_visible = false
	_skiff_seen_t = 0.0
	_crouch = false
	_crouch_k = 0.0
	_climb = false
	_air = false
	_end_slide(false)
	mode = Mode.DEAD
	_dead_t = 0.0
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_cap_cs.disabled = true
	set_light(false)
	if team_node != null:
		team_node.on_bot_died(self)
	_rag_frozen = false
	if not _hr_keep_ragdoll(impulse):        # hit reactions: a knocked-down body goes on as the corpse (end of file)
		_ragdoll = Ragdoll.new()
		get_parent().add_child(_ragdoll)
		_ragdoll.no_float_recover = true
		_ragdoll.start(self, _hr_launch(velocity + impulse), 60.0, [], false)
	_ragdoll.finished.connect(_on_ragdoll_settled)
	if team_node != null:
		team_node.add_ragdoll(_ragdoll)
	if Game.hud and cam_dist < 120.0:
		Game.hud.show_message("%s düştü!" % callsign, 2.0)
	_radio_call("down")
	_bl_on_died()                            # teammates look / call it; an ally's thumbs up (Reactions and body language)
	_lt_on_death()                           # loot: the material it carried drops here (end of file)
	if team != "home":                       # (an ally bot drops nothing: "Ally bots", end of file)
		preload("res://scripts/war/weapon_drop.gd").drop_bot(self)   # its rifle drops (host / single player)


## The corpse came to rest: drop its physics bodies, keep the pose.
func _on_ragdoll_settled(_p: Vector3, _f: Vector3) -> void:
	if _ragdoll != null and is_instance_valid(_ragdoll) and team_node != null:
		astronaut.sync_skeleton()
		team_node.freeze_ragdoll(_ragdoll)
	_rag_frozen = true


func _tick_dead(delta: float) -> void:
	_dead_t += delta
	if _ragdoll != null and is_instance_valid(_ragdoll) and not _rag_frozen and _ragdoll.bodies.is_empty():
		_rag_frozen = true                 # frozen by the team's ragdoll cap
		astronaut.sync_skeleton()
	if _dead_t < Balance.AI_RESPAWN:
		return
	_lt_leave_corpse()                       # corpses: the body stays where it fell (end of file)
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null
	if preload("res://scripts/war/respawn_ship.gd").hold_bot(self):   # aboard (hidden) until its dropship has landed
		return
	visible = true
	astronaut.transform = Transform3D.IDENTITY
	astronaut.reset_pose()
	hp = hp_max
	_mag = Balance.AI_MAG
	_reload_t = 0.0
	body = _al_home_body()                   # (Game.rival; our planet for an ally bot)
	transform = team_node.respawn_xf(index) if team_node != null else transform
	transform = preload("res://scripts/war/respawn_ship.gd").bot_exit_xf(self, transform)   # off its dropship's ramp
	_vis_pos = global_position
	_cap_cs.disabled = false
	mode = Mode.WORK
	_tac = Tac.NONE
	_threat_pos = Vector3.INF
	_set_held("terrain")
	_dig_site = Vector3.INF
	_air = true
	_vy = 0.0
	astronaut.animate(0.016, {"speed": 0.0, "grounded": true, "probe": false})
	astronaut.sync_skeleton()


func status() -> String:
	return "%s · %s · %d can · lod %d" % [callsign, MODE_NAMES[mode], int(ceilf(hp)), lod]


# =================================================================================================
# Slides and jumps (combat movement like a player)
# =================================================================================================
# Hooks elsewhere (one line each): _physics_process -> _moves_update; _tick -> _slide_tick while
# `sliding`, the air steering limit (AI_AIR_ACCEL) and the landing dip (_land_v); _on_blocked ->
# _jump over low obstacles / rims; _on_threat -> _schedule_dodge; _think_combat -> _maybe_slide_to
# (to cover, across gaps) and _maybe_jump_peek; _shoot_update -> AI_ACC_SLIDE / AI_ACC_AIR;
# _process -> the astronaut's "crouch" / "slide" poses; _think -> the lower collider in a slide.
# Everything moves the SIM state (_tick); the render interpolation shows it and the pose follows the
# real motion (in a slide the feet are in the slide pose, no stepping).
# Slide: the player's rules (stance.gd): a burst of AI_SLIDE_BOOST × the running speed (capped at
# AI_SLIDE_MAX), friction + drag eat it in ~0.9 s, gravity along the floor (density normal: works on
# the far planet without collision) makes it longer downhill; it steers a little toward its aim
# (cover); it ends below AI_SLIDE_END, after AI_SLIDE_MAX_T (1.8× downhill), against a wall, or off a
# ledge (then it flies on); it ends crouched for a moment.
# Jumps are real arcs under Game.gravity_at (no jet; jet hops stay for tall obstacles and some
# dodges). Reactions wait AI_REACT_MIN..MAX × the bot's trait; cooldowns AI_SLIDE_CD / AI_DODGE_CD;
# each bot has its own agility (how often) and reaction trait. None of it starts while the bot is
# staggered or down (is_staggered() / is_down() when the hit reactor provides them, the fling arc,
# a flinch), nor at far LOD.
# Multiplayer: no new snapshot field is needed. A client sees a slide as f1 bit 4 (crouch) set,
# f1 bit 8 (air) clear and byte 13 (horizontal speed × 10) >= 30; a real jump as f1 bit 8 set with
# bit 16 (jet) clear. The host bot also exposes `sliding` / `airborne` / `_slide_k`.

## Busy with a hit reaction (staggered, knocked down, flung, flinching): no special moves.
func _reactor_busy() -> bool:
	if _flinch > 0.0:
		return true
	var fl: Dictionary = get_meta("fling", {})
	if bool(fl.get("live", false)):
		return true
	for m in ["is_staggered", "is_down"]:
		if has_method(m) and bool(call(m)):
			return true
	return false


func _can_special() -> bool:
	return mode == Mode.COMBAT and lod < 2 and not _air and not _climb and not sliding and not _reactor_busy()


## Cooldowns, the landing dip timer, the crouch-after-a-slide hold and a delayed reaction.
func _moves_update(delta: float) -> void:
	_slide_cd = maxf(_slide_cd - delta, 0.0)
	_jump_cd = maxf(_jump_cd - delta, 0.0)
	_dodge_cd = maxf(_dodge_cd - delta, 0.0)
	_crouch_hold = maxf(_crouch_hold - delta, 0.0)
	_land_t = maxf(_land_t - delta, 0.0)
	if sliding and _reactor_busy():
		_end_slide(false)
	if _pending.is_empty() or _now() < int(_pending["at"]):
		return
	var p := _pending
	_pending = {}
	if not _can_special():
		return
	var up := _up()
	var side: Vector3 = p["dir"]
	side = (side - up * side.dot(up)).normalized()
	match str(p["kind"]):
		"slide":
			_start_slide(side, maxf(_hv.length(), Balance.AI_RUN_SPEED * 0.8), Vector3.INF)
		"jump":
			_jump(Balance.AI_JUMP_V, side * Balance.AI_JUMP_SIDE)
		_:
			_hop(Balance.AI_JET_HOP * 0.8, side * 4.0)


## A shot passed close: maybe dodge sideways (slide-strafe, jump-strafe or a jet hop), after a
## believable delay, not too often.
func _schedule_dodge() -> void:
	if not _pending.is_empty() or _dodge_cd > 0.0 or lod >= 2:
		return
	if _rng.randf() > Balance.AI_DODGE_CHANCE * (0.5 + _agile):
		return
	var up := _up()
	var side := up.cross(_threat_pos - global_position)
	if side.length_squared() < 1e-4:
		side = global_transform.basis.x
	side = side.normalized() * (1.0 if _rng.randf() < 0.5 else -1.0)
	var r := _rng.randf()
	var kind := "jet"
	if _hv.length() > 2.5:
		kind = "slide" if r < 0.5 else ("jump" if r < 0.8 else "jet")
	else:
		kind = "jump" if r < 0.6 else ("jet" if r < 0.85 else "slide")
	var delay := _rng.randf_range(Balance.AI_REACT_MIN, Balance.AI_REACT_MAX) * _react
	_pending = {"kind": kind, "at": _now() + int(delay * 1000.0), "dir": side}
	_dodge_cd = Balance.AI_DODGE_CD * _rng.randf_range(0.8, 1.4) * (1.5 - _agile * 0.5)


## Running toward `aim` (cover, the far side of a gap): slide the last few metres sometimes.
func _maybe_slide_to(aim: Vector3, under_fire: bool, chance: float) -> void:
	if not _can_special() or _slide_cd > 0.0 or aim == Vector3.INF:
		return
	if _hv.length() < Balance.AI_RUN_SPEED * 0.7:
		return
	var up := _up()
	var to := aim - global_position
	to -= up * to.dot(up)
	var d := to.length()
	if d < 2.5 or d > 7.5:
		return
	if _rng.randf() > chance * _agile * (1.0 if under_fire else 0.5):
		return
	_start_slide(to / d, _hv.length(), aim)


## In cover, a peek is sometimes a short jump over the rim (fires from the apex).
func _maybe_jump_peek() -> void:
	if not _can_special() or _jump_cd > 0.0:
		return
	if _rng.randf() > Balance.AI_PEEK_JUMP * _agile * 2.0:
		return
	_jump(Balance.AI_JUMP_V * 0.8, Vector3.ZERO)
	_jump_cd = _rng.randf_range(3.0, 5.0)


## A real jump: a ballistic arc under Game.gravity_at from the current horizontal velocity
## `lateral` (no jet).
func _jump(v_up: float, lateral: Vector3) -> void:
	if _air or _climb or sliding:
		return
	var up := _up()
	_air = true
	_vy = v_up
	_jet_t = 0.0
	_hv = lateral - up * lateral.dot(up)
	_crouch = false
	if tok_audio and Game.sfx:
		Game.sfx.play_at("step", global_position, -8.0, 0.8, 8.0)


func _start_slide(dir: Vector3, speed: float, aim: Vector3) -> bool:
	if not _can_special() or _slide_cd > 0.0:
		return false
	var up := _up()
	var d := dir - up * dir.dot(up)
	if d.length_squared() < 1e-4:
		return false
	var sp := clampf(speed * Balance.AI_SLIDE_BOOST, Balance.AI_SLIDE_END + 3.0, Balance.AI_SLIDE_MAX)
	_slide_v = d.normalized() * sp
	_slide_t = 0.0
	_slide_aim = aim
	sliding = true
	_crouch = true
	if tok_audio and Game.sfx:
		Game.sfx.play_at("step", global_position, -4.0, 0.6, 10.0)
	return true


## Ends a slide: crouched for a moment (pops up into cover) unless it slid off a ledge.
func _end_slide(crouched := true) -> void:
	if not sliding:
		return
	sliding = false
	_slide_t = -1.0
	var up := _up()
	_hv = (_slide_v - up * _slide_v.dot(up)) * 0.3
	_slide_cd = Balance.AI_SLIDE_CD * _rng.randf_range(0.8, 1.3) * (1.6 - _agile)
	if crouched:
		_crouch_hold = 0.6
	_slide_aim = Vector3.INF


## One sim step of a slide on the density surface: friction, drag, the slope along the floor,
## a little steering toward the aim. Returns the new position.
func _slide_tick(pos: Vector3, up: Vector3, dt: float) -> Vector3:
	_slide_t += dt
	var n: Vector3 = body.density_normal(pos + up * 0.3)
	if n.dot(up) < 0.2:
		n = up
	var g: Vector3 = Game.gravity_at(pos)
	var g_t := g - n * g.dot(n)
	var g_h := g_t - up * g_t.dot(up)
	var v := _slide_v - up * _slide_v.dot(up)
	v += g_h * Balance.AI_SLIDE_SLOPE * dt
	var sp := v.length()
	if sp > 0.01:
		var dir := v / sp
		sp = maxf(sp - (Balance.AI_SLIDE_FRICTION + Balance.AI_SLIDE_DRAG * sp) * dt, 0.0)
		if _slide_aim != Vector3.INF:
			var want := _slide_aim - pos
			want -= up * want.dot(up)
			if want.length_squared() > 0.25:
				var ang := dir.signed_angle_to(want.normalized(), up)
				dir = dir.rotated(up, clampf(ang, -Balance.AI_SLIDE_STEER * dt, Balance.AI_SLIDE_STEER * dt))
		v = dir * sp
	_slide_v = v
	var fast_down := sp > Balance.AI_RUN_SPEED and g_h.dot(v) > 0.0
	var over := _slide_t > Balance.AI_SLIDE_MAX_T * (1.8 if fast_down else 1.0)
	var np := pos
	var tgt := pos + v * dt
	var g2 := _probe(tgt, up, pos)
	if g2["blocked"]:
		_end_slide()
	elif not g2["ok"]:
		# Off a ledge or a crater rim: it flies on.
		np = tgt
		_end_slide(false)
		_hv = v
		_air = true
		_vy = 0.0
	else:
		np = g2["pos"]
		if sp < Balance.AI_SLIDE_END or over:
			_end_slide()
	return np


# =================================================================================================
# Kinetik İtici (scripts/items/kinetic_pusher.gd)
# =================================================================================================

## A shove of velocity `v` (m/s, world) from the player's Kinetik İtici, fired from `from_pos`.
## Ignored while dead or aboard. Three outcomes by speed:
##   below Balance.AI_FLING_KO   the hit reactor's shove (end of file): a skid, a stagger from
##                               HR_PUSH_STAGGER, a knockdown ragdoll from HR_PUSH_DOWN m/s
##   KO .. AI_FLING_ESCAPE_K × the local escape speed (~26 m/s on the surface)
##                               it loses its footing and flies a kinematic arc: the vertical part
##                               goes into _vy with _air (the normal airborne branch of _tick lands
##                               it), the tangential part is held as _knock every physics frame by a
##                               tween bound to this bot (so _tick needs no hook; the bot's own
##                               steering is cleared meanwhile). No shooting in flight, dazed for a
##                               moment after. The landing, or a wall that stops it, hurts by speed:
##                               (speed - AI_FLING_LAND_SAFE) × AI_FLING_LAND_DMG. A second fling in
##                               flight adds to the arc.
##   faster                      ragdoll through _die(v): it sails off into space ("uzaya
##                               fırladı!"); the team respawns it after AI_RESPAWN s
## Host / single player only (bots are host-simulated; the pusher replays a client's blast here).
func fling(v: Vector3, from_pos := Vector3.ZERO) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD or is_down() or Downed.is_downed(self) or Downed.is_rising(self):   # (down: the pusher shoves its ragdoll)
		return
	var up := _up()
	var speed := v.length()
	if speed < Balance.AI_FLING_KO:
		_hr_push(v, from_pos)              # skid / stagger / knockdown by speed (hit reactions, end of file)
		return
	var b: Node3D = Game.dominant_body(global_position)
	var r := maxf(global_position.distance_to(b.global_position), 1.0) if b != null else 60.0
	var esc := sqrt(2.0 * Game.gravity_at(global_position).length() * r)
	if speed >= Balance.AI_FLING_ESCAPE_K * esc:
		_hr_get().allow_escape = true          # this one really sails off (corpse launches are capped otherwise)
		_die(v)
		if Game.hud and cam_dist < 120.0:
			Game.hud.show_message("%s uzaya fırladı!" % callsign, 2.0)
		return
	if from_pos != Vector3.ZERO:
		_on_threat(from_pos, true)
	var vy := maxf(v.dot(up), 2.5)
	var lat := v - up * v.dot(up)
	var st: Dictionary = get_meta("fling", {})
	if bool(st.get("live", false)):
		st["h"] = (st["h"] as Vector3) + lat
		_vy = maxf(_vy, 0.0) + vy
		_air = true
		return
	st = {"live": true, "h": lat, "t": 0.0, "vy": vy}
	set_meta("fling", st)
	_climb = false
	_crouch = false
	_air = true
	_vy = vy
	_jet_t = 0.0
	_strafe = Vector3.ZERO
	_move_to = Vector3.INF
	_flinch = maxf(_flinch, 0.5)
	if astronaut != null and astronaut.has_method("hit_react"):
		astronaut.hit_react(lat.normalized() if lat.length_squared() > 0.01 else -global_transform.basis.z, 1.2, false)
	var tw := create_tween()
	tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	var step := func(_x: float) -> void:
		var s: Dictionary = get_meta("fling", {})
		if mode == Mode.DEAD or mode == Mode.ABOARD or not bool(s.get("live", false)):
			s["live"] = false
			tw.kill()
			return
		s["t"] = float(s["t"]) + get_physics_process_delta_time()
		var u := _up()
		var h: Vector3 = s["h"]
		if h.length_squared() > 1e-4:
			h = (h - u * h.dot(u)).normalized() * h.length()      # stays tangent on the round planet
		s["h"] = h
		var wall := false
		if _air:
			s["vy"] = _vy
			var hv := velocity - u * velocity.dot(u)
			wall = float(s["t"]) > 0.3 and h.length() > 3.0 and hv.length() < h.length() * 0.25
			if not wall and float(s["t"]) < 7.0:
				_knock = h
				_strafe = Vector3.ZERO
				_move_to = Vector3.INF
				_flinch = maxf(_flinch, 0.3)
				return
		# Down (or against a wall): a short skid, dazed, hurt by the impact speed.
		s["live"] = false
		tw.kill()
		var vy_l := float(s["vy"])
		var impact := sqrt(vy_l * vy_l + h.length_squared()) if not wall else h.length()
		_knock = h.limit_length(4.0)
		_flinch = maxf(_flinch, 0.9)
		var dmg := (impact - Balance.AI_FLING_LAND_SAFE) * Balance.AI_FLING_LAND_DMG
		if dmg > 0.0:
			take_damage(dmg, global_position - (h.normalized() if h.length_squared() > 1e-4 else u) * 2.0, Vector3.ZERO)
	tw.tween_method(step, 0.0, 1.0, 8.0)


# =================================================================================================
# AI use of the new weapons (the team side: the same section at the end of rival_team.gd; the
# constants: balance.gd "AI use of the new weapons")
# =================================================================================================
# Hooks into the code above: _think_work -> _wx_think_task (a weapon task before the role's work),
# _dig_shaft -> _wx_dig_tick (the interceptor's / climber's brush), _think_combat (last line) ->
# _wx_think_grenade; _dig_once / _dig_shaft pass `team` to Dig.dig_at (tunnel log); _pick_target /
# _nearest_enemy_structure include "war_buster"; _repair_candidate includes team.busters.
#   El bombası (combat): a near bot (lod 0-1) that held a shooter token within AI_GRENADE_TOKEN_MEM s,
#     whose target hid for AI_GRENADE_HIDDEN_MIN s (seen within AI_GRENADE_MEMORY s) or stands in a pit
#     / tunnel, AI_GRENADE_MIN..MAX_RANGE m away, solves a lob to the last known position (the flight
#     of projectiles.gd on the density field: no landing near it = no line), pays GRENADE_COST, pops
#     up out of a crouch, faces it, winds the arm up over the shoulder with the grenade in the fist
#     (a pose on top of the animation, from a tween this bot owns) and throws; killed mid-wind-up it
#     drops the live grenade. The team launches it (one shared Projectiles).
#   Tasks given by the team (wx_assign; wx_clear_task takes them back):
#     "buster"    mans the Delici Top like a cannon: _start_solve / _step_solve, the team's aim error
#                 and _observe adjust-fire, BUSTER_SHELL_COST from the pool, fire(true, on_impact)
#     "torpedo"   walks to a spot facing our planet with a launcher prop, solves like a shell (speed
#                 clamped to TORPEDO_SPEED_MIN..MAX) at the near side of our planet, raises the tube,
#                 pays TORPEDO_COST and fires Torpedo.fire(..., "rival", [its collider]); backblast
#     "intercept" runs to the surface above our burrowing torpedo's drill head and digs at it (a real
#                 brush every dig tick, squeezing along its own tunnel; the torpedo takes an enemy
#                 brush as drill damage) and shoots it in bursts when it sees it
#     "exit"      afterwards climbs back out of its hole (carving above its head, the normal jet climb)

const WxTorpedo := preload("res://scripts/war/torpedo.gd")
const WxBuildFx := preload("res://scripts/war/build_fx.gd")

var _wx_task := ""                     # "", "buster", "torpedo", "intercept", "exit"
var _wx_phase := ""
var _wx_torp = null                    # intercept: the torpedo (untyped: it may be freed)
var _wx_slot := 0                      # intercept: 0 digs over the head, 1 to the side
var _wx_t0 := 0                        # ms: task / phase start
var _wx_spot := Vector3.INF            # torpedo: launch spot
var _wx_from := Vector3.ZERO           # torpedo: launch point
var _wx_vel := Vector3.ZERO            # torpedo: launch velocity
var _wx_target := Vector3.INF          # buster: aim point
var _wx_shot_ms := 0                   # intercept: next burst
var _wx_tok_ms := -100000              # last combat think holding a shooter token
var _wx_seen_pos := Vector3.INF        # the target's feet when last seen
var _wx_gren_ms := 0                   # this bot may throw again from then on
var _wx_throwing := false
var _wx_tw: Tween = null
var _wx_gren := {}                     # the solved throw: "vel", "land", "fwd"
var _wx_gprop: Node3D = null           # the grenade in the fist (built on the first throw)
var _wx_flee_ms := -100000


## Free for a weapon task (the team asks): working, no task, not building / firing / repairing.
func wx_available() -> bool:
	return _wx_task == "" and not _wx_throwing and mode == Mode.WORK \
			and _job != "build" and _job != "fire" and _job != "repair" and _dg_task == ""   # (+ dig tasks)


## The team gives this bot a weapon task: "buster", "torpedo" or "intercept" (with its torpedo and
## slot).
func wx_assign(kind: String, torp: Node3D = null, slot := 0) -> void:
	_wx_task = kind
	_wx_torp = torp
	_wx_slot = slot
	_wx_phase = ""
	_wx_t0 = _now()
	if mode == Mode.WORK:
		_set_job("wx_" + kind)
	_think_acc = 1.0


## The team takes the task back (finished elsewhere, timed out, the bot went to fight or died). An
## interceptor deep in its hole climbs out first ("exit").
func wx_clear_task() -> void:
	if _wx_task == "" or _wx_task == "exit":
		return
	var was := _wx_task
	_wx_task = ""
	_wx_torp = null
	_wx_phase = ""
	_wx_drop_launcher()
	if mode == Mode.WORK and _job.begins_with("wx_"):
		_set_job("")
	if was == "intercept" and mode != Mode.DEAD and mode != Mode.ABOARD and _wx_depth() > 1.5:
		_wx_task = "exit"
		_wx_t0 = _now()
		if mode == Mode.WORK:
			_set_job("wx_exit")


## This bot finished its task (ok: it fired); the team moves its timers on.
func _wx_done(ok: bool) -> void:
	var kind := _wx_task
	_wx_task = ""
	_wx_torp = null
	_wx_phase = ""
	_wx_drop_launcher()
	if team_node != null:
		team_node.wx_task_done(self, kind, ok)
	_set_job("")


## m of the feet below the original (generated) surface.
func _wx_depth() -> float:
	return float(body.radius) + float(body.surface_height_at(global_position)) - global_position.distance_to(body.global_position)


## From _think_work: runs the weapon task; false lets the role's own work run this think.
func _wx_think_task() -> bool:
	if not _job.begins_with("wx_"):
		_set_job("wx_" + _wx_task)          # (re)entering, e.g. after a fight: start the task over
		_wx_phase = ""
	match _wx_task:
		"buster":
			return _wx_think_buster()
		"torpedo":
			return _wx_think_torpedo()
		"intercept":
			return _wx_think_intercept()
		"exit":
			return _wx_think_exit()
	return false


# --- Task: Delici Top -------------------------------------------------------------------------------

## Stands behind the breech, solves (one trajectory per frame, the team's aim error), lays the gun,
## pays and fires; the impact feeds the shared adjust-fire (_observe).
func _wx_think_buster() -> bool:
	var t = team_node
	var c: Node3D = t.wx_buster()
	if c == null:
		_wx_done(false)
		return true
	_set_held("terrain")
	if _wx_phase == "":
		_wx_target = t.wx_buster_target()
		_solve = {}
		_solved = false
		_solved_v = Vector3.ZERO
		_wx_phase = "lay"
	var cb: Basis = c.global_transform.basis * Basis(Vector3.UP, float(c.get("yaw")))
	var stand: Vector3 = c.global_position + cb * Vector3(0, 0, Balance.AI_BUSTER_STAND)
	if not _walk_to(stand, Balance.AI_WALK_SPEED):
		return true
	_face = -cb.z
	if not _solved and _solve.is_empty():
		_start_solve(c.muzzle_position(), _wx_target)
		return true
	if not _solve.is_empty():
		return true
	if _solved_v == Vector3.ZERO:
		_wx_done(false)
		return true
	c.aim_dir(_solved_v.normalized(), _solved_v.length())
	if not c.aligned() or not c.ready_to_fire():
		return true
	if float(t.material) - Balance.AI_RESERVE < Balance.BUSTER_SHELL_COST or not t.spend(Balance.BUSTER_SHELL_COST):
		_wx_done(false)
		return true
	var tgt := _wx_target
	if not c.fire(true, func(point: Vector3, _b) -> void: _observe(point, tgt)):
		t.add_material(Balance.BUSTER_SHELL_COST)
		_wx_done(false)
		return true
	_fire_vis = 0.3
	_radio_call("launch")
	_wx_done(true)
	return true


# --- Task: torpedo launch -----------------------------------------------------------------------------

## walk (launcher in hand) -> solve (one trajectory per frame) -> aim (tube raised) -> fire.
func _wx_think_torpedo() -> bool:
	var t = team_node
	var up := _up()
	match _wx_phase:
		"":
			_wx_spot = _wx_launch_spot()
			_wx_hold_launcher()
			_wx_tilt_launcher(0.0)
			_wx_phase = "walk"
		"walk":
			_wx_hold_launcher()
			if not _walk_to(_wx_spot, Balance.AI_RUN_SPEED):
				return true
			var fwd := _wx_toward_home(up)
			_face = fwd
			_wx_from = _eye() + fwd * 0.8 + up * 0.5
			if body.density_at(_wx_from) < 0.3 or body.density_at(_wx_from + (fwd + up).normalized() * 1.2) < 0.3:
				_wx_from = _eye() + up * 0.7
			_solve = {}
			_solved = false
			_solved_v = Vector3.ZERO
			_start_solve(_wx_from, t.wx_near_side())
			_wx_phase = "solve"
		"solve":
			_move_to = Vector3.INF
			_face = _wx_toward_home(up)
			if not _solve.is_empty():
				return true
			if _solved_v == Vector3.ZERO:
				_wx_done(false)
				return true
			_wx_vel = _solved_v.normalized() * clampf(_solved_v.length(), Balance.TORPEDO_SPEED_MIN, Balance.TORPEDO_SPEED_MAX)
			var flat := _wx_vel - up * _wx_vel.dot(up)
			if flat.length_squared() > 1e-4:
				_face = flat.normalized()
			_wx_tilt_launcher(asin(clampf(_wx_vel.normalized().dot(up), -1.0, 1.0)))
			_wx_t0 = _now()
			_wx_phase = "aim"
			t.wx_bot_action(index, "torpedo_aim")
		"aim":
			_move_to = Vector3.INF
			if _now() - _wx_t0 < int(Balance.AI_TORPEDO_AIM_TIME * 1000.0):
				return true
			if float(t.material) - Balance.AI_RESERVE < Balance.TORPEDO_COST or not t.spend(Balance.TORPEDO_COST):
				_wx_done(false)
				return true
			_wx_fire_torpedo()
			_wx_done(true)
	return true


## Horizontal direction toward our planet (its centre) from here.
func _wx_toward_home(up: Vector3) -> Vector3:
	var to: Vector3 = team_node.home.global_position - global_position
	var f := to - up * to.dot(up)
	if f.length_squared() < 1e-4:
		return -global_transform.basis.z
	return f.normalized()


## A clear spot ~AI_TORPEDO_SPOT_AHEAD m from the base toward our planet (off the structures).
func _wx_launch_spot() -> Vector3:
	var bx: Transform3D = team_node.base_xf
	var up := bx.basis.y
	var toward: Vector3 = team_node.home.global_position - bx.origin
	toward = toward - up * toward.dot(up)
	toward = toward.normalized() if toward.length_squared() > 1e-4 else -bx.basis.z
	var side := up.cross(toward).normalized()
	for i in 10:
		var off := toward * _rng.randf_range(Balance.AI_TORPEDO_SPOT_AHEAD * 0.6, Balance.AI_TORPEDO_SPOT_AHEAD * 1.4) \
				+ side * _rng.randf_range(-9.0, 9.0)
		var q := _on_sphere(bx.origin + off)
		var ok := true
		for s in get_tree().get_nodes_in_group("war_structure"):
			if (s as Node3D).global_position.distance_to(q) < float(s.get_meta("footprint_r", 3.0)) + 2.5:
				ok = false
				break
		if ok:
			return _ground_at(q + _up_of(q) * 3.0)
	return _ground_at(bx.origin + up * 3.0)


## Fires the torpedo from the tube's muzzle (Torpedo.fire emits Torpedo.events().launched for the
## multiplayer layer), with the backblast: dust behind, the flash, the launch roar.
func _wx_fire_torpedo() -> void:
	var up := _up()
	var dir := _wx_vel.normalized()
	var from := _wx_from
	var tip: Node3D = astronaut.held_tip("wx_torpedo")
	if tip != null and tip.is_inside_tree() and tip.global_position.distance_to(from) < 1.5 \
			and body.density_at(tip.global_position + dir * 0.9) > 0.3:
		from = tip.global_position + dir * 0.25
	var scene: Node = get_tree().current_scene
	WxTorpedo.fire(scene, from, _wx_vel, team, [_col.get_rid()])
	var flat := dir - up * dir.dot(up)
	var back_dir := flat.normalized() if flat.length_squared() > 1e-4 else -global_transform.basis.z
	if lod < 2:
		var soil: Color = body.get("soil_color") if body.get("soil_color") is Color else Color(0.5, 0.4, 0.3)
		WxBuildFx.dust(scene, global_position - back_dir * 1.6, up, 1.3, soil)
	if _light_on:
		_flash.global_position = from
		_flash_t = 1.0
	_fire_vis = 0.4
	_knock -= back_dir * 1.2
	team_node.wx_play_at("launch", from, 3.0)
	team_node.wx_bot_action(index, "torpedo_fire")


## Shows the launcher in the hands (built the first time: a gunmetal tube with red bands, a dark
## front shroud with the torpedo's drill nose, a flared venturi, a sight, a foregrip).
func _wx_hold_launcher() -> void:
	if not astronaut.props.has("wx_torpedo"):
		_wx_build_launcher()
	_set_held("wx_torpedo")


func _wx_drop_launcher() -> void:
	if _held == "wx_torpedo":
		_wx_tilt_launcher(0.0)
		_set_held("terrain")


## Raises the launcher's muzzle by `elev` rad about the grip (the hold pose stays level at work).
func _wx_tilt_launcher(elev: float) -> void:
	var p = astronaut.props.get("wx_torpedo")
	if p is Node3D:
		(p as Node3D).basis = Basis(Vector3.RIGHT, -PI * 0.5) * Basis(Vector3.RIGHT, elev)


func _wx_build_launcher() -> void:
	var hands: Array = astronaut.hand
	if hands.size() < 2 or hands[1] == null:
		return
	var gun := StandardMaterial3D.new()
	gun.albedo_color = Color(0.22, 0.21, 0.21)
	gun.metallic = 0.55
	gun.roughness = 0.45
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.75, 0.13, 0.08)
	red.roughness = 0.5
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.08, 0.08, 0.09)
	dark.metallic = 0.5
	dark.roughness = 0.5
	var p := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.03, -0.04), Vector3(0.05, 0.05, 0.16), dark)
	VM.seg(p, Vector3(0, 0.1, 0.33), Vector3(0, 0.1, -0.49), 0.062, 0.062, gun, 12)
	VM.seg(p, Vector3(0, 0.1, -0.47), Vector3(0, 0.1, -0.56), 0.07, 0.073, dark, 12)
	VM.seg(p, Vector3(0, 0.1, 0.32), Vector3(0, 0.1, 0.44), 0.066, 0.086, dark, 12)
	for z in [-0.42, 0.22]:
		VM.seg(p, Vector3(0, 0.1, z + 0.01), Vector3(0, 0.1, z - 0.01), 0.066, 0.066, red, 12)
	VM.box(p, Vector3(-0.088, 0.142, 0.0), Vector3(0.04, 0.04, 0.05), dark)
	VM.capsule(p, Vector3(0, -0.07, -0.25), Vector3(0, -0.01, -0.258), 0.017, dark)
	var nose := MeshInstance3D.new()
	nose.mesh = WxTorpedo.drill_mesh(0.11, 0.05)
	nose.material_override = gun
	nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.add_child(nose)
	nose.position = Vector3(0, 0.1, -0.56)
	for n in p.find_children("*", "GeometryInstance3D", true, false):
		(n as GeometryInstance3D).visibility_range_end = 60.0
		(n as GeometryInstance3D).visibility_range_end_margin = 5.0
	astronaut.props["wx_torpedo"] = p
	astronaut.prop_tips["wx_torpedo"] = VM.node(p, Vector3(0, 0.1, -0.68))
	p.visible = false


# --- Task: intercept our torpedo ------------------------------------------------------------------

## Runs to the surface over the torpedo's drill head (slot 1: AI_INTERCEPT_SIDE m to the side), then
## digs at the head (_wx_dig_tick) and shoots it in bursts when it sees it.
func _wx_think_intercept() -> bool:
	var tp = _wx_torp
	if tp == null or not is_instance_valid(tp) or not tp.is_burrowing():
		if team_node != null:
			team_node.wx_task_done(self, "intercept", false)
		wx_clear_task()
		return true
	var tip: Vector3 = tp.tip_position()
	var up := _up()
	var to := tip - (global_position + up * 0.9)
	var d := to.length()
	if _wx_phase == "":
		_wx_phase = "go"
	if _wx_phase == "go":
		var above := _on_sphere(tip)
		var au: Vector3 = body.up_at(above)
		var side := au.cross(Vector3.FORWARD if absf(au.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		var goal := above + side * Balance.AI_INTERCEPT_SIDE * float(_wx_slot)
		var flat := goal - global_position
		flat = flat - up * flat.dot(up)
		if flat.length() > 2.0 and _wx_depth() < 1.5:
			_set_held("terrain")
			_stop_dig()
			_move_to = goal
			_move_speed = Balance.AI_RUN_SPEED
			_strafe = Vector3.ZERO
			return true
		_wx_phase = "dig"
		if team_node != null:
			team_node.wx_intercept_started(self, tp)
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	var tf := to - up * to.dot(up)
	if tf.length_squared() > 0.01:
		_face = tf.normalized()
	if _wx_try_shoot(tp, tip, d):
		return true
	_set_held("terrain")
	if not _digging:
		_digging = true
		_shaft = true
		_dig_acc = 0.0
		_play(_dig_audio)
	return true


## A burst at the torpedo within AI_INTERCEPT_SHOOT_RANGE when a density ray to its head is clear
## (rifle out, digging paused); true while it is at it.
func _wx_try_shoot(tp: Node3D, tip: Vector3, d: float) -> bool:
	if d > Balance.AI_INTERCEPT_SHOOT_RANGE:
		return false
	var now := _now()
	if now < _wx_shot_ms:
		return _held == "rifle"                # between bursts: keeps the rifle up
	var me := _eye()
	if not body.raycast_density(me, tip + (me - tip).normalized() * 0.5, 0.5, false).is_empty():
		return false
	_stop_dig()
	_set_held("rifle")
	_wx_shot_ms = now + int((Balance.AI_RIFLE_INTERVAL * float(Balance.AI_RIFLE_BURST) + Balance.AI_RIFLE_PAUSE) * 1000.0)
	var dmg := 0.0
	for k in Balance.AI_RIFLE_BURST:
		if _rng.randf() < Balance.AI_INTERCEPT_HIT:
			dmg += Balance.AI_RIFLE_DAMAGE
	var tip_n: Node3D = astronaut.held_tip("rifle")
	var muzzle: Vector3 = tip_n.global_position if tip_n != null else me
	var end := tip
	if dmg <= 0.0:
		end = tip + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.8
	_tracer_mesh.clear_surfaces()
	_tracer_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_tracer_mesh.surface_set_color(Color(1.0, 0.8, 0.5, 0.9))
	_tracer_mesh.surface_add_vertex(muzzle)
	_tracer_mesh.surface_set_color(Color(1.0, 0.6, 0.3, 0.2))
	_tracer_mesh.surface_add_vertex(end)
	_tracer_mesh.surface_end()
	_tracer.visible = true
	_tracer_t = 0.06
	if _light_on:
		_flash.global_position = muzzle
		_flash_t = 1.0
	_fire_vis = 0.25
	_gun_audio.global_position = muzzle
	_play(_gun_audio)
	Game.shot_fired.emit(muzzle, (end - muzzle).normalized(), team)
	if Net.is_host():
		Net.bots.on_bot_shot(self, end)
	if dmg > 0.0:
		Game.damage_target(tp, dmg, me, Vector3.ZERO, team)
	return true


## Climbs back out of the interception hole: carves above its head (_wx_dig_tick) while the normal
## jet climb (a blocked walk toward a spot beside the hole) lifts it; done near the surface.
func _wx_think_exit() -> bool:
	if _wx_depth() < 1.2 or _now() - _wx_t0 > int(Balance.AI_INTERCEPT_EXIT_TIME * 1000.0):
		_wx_task = ""
		_set_job("")
		return false
	var up := _up()
	_set_held("terrain")
	if not _digging:
		_digging = true
		_shaft = true
		_dig_acc = 0.0
	var x := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	_move_to = _on_sphere(global_position) + x * 3.0
	_move_speed = Balance.AI_WALK_SPEED
	_strafe = Vector3.ZERO
	return true


## From _dig_shaft (AI_DIG_HZ): the interceptor's brush toward the torpedo's drill head (always a
## real brush, logged for the tunnel scanner; the torpedo takes it as drill damage), squeezing
## sideways into the dug space toward the head (falling does the rest); the climber's brush above
## its head. False: not a weapon dig (the normal shaft runs).
func _wx_dig_tick(dt: float) -> bool:
	var up: Vector3 = body.up_at(global_position)
	var mid := global_position + up * 0.9
	match _wx_task:
		"intercept":
			var tp = _wx_torp
			if tp == null or not is_instance_valid(tp) or not tp.is_burrowing():
				return true
			var to: Vector3 = (tp.tip_position() as Vector3) - mid
			var d := to.length()
			if d < 0.05:
				return true
			var dir := to / d
			_dig_point = mid + dir * minf(d, Balance.AI_INTERCEPT_REACH)
			_dig_normal = -dir
			Dig.dig_at(body, _dig_point, Balance.AI_INTERCEPT_DIG_RADIUS, Dig.MODE_DIG, Balance.AI_INTERCEPT_DIG_RATE * dt,
					Vector3.ZERO, Vector3.UP, -1.0, team)
			var lat := to - up * to.dot(up)
			var ll := lat.length()
			if ll > 1.0 and d > 1.6:
				var step := lat / ll * minf(Balance.AI_INTERCEPT_CRAWL * dt, ll - 0.8)
				if body.density_at(mid + step) > 0.0 and body.density_at(mid + step + up * 0.7) > 0.0:
					global_position += step
			if not _mine_audio.playing and _rng.randf() < 0.3:
				_play(_mine_audio)
			return true
		"exit":
			_dig_point = global_position + up * 2.6
			_dig_normal = -up
			Dig.dig_at(body, _dig_point, 1.4, Dig.MODE_DIG, Balance.AI_INTERCEPT_DIG_RATE * dt,
					Vector3.ZERO, Vector3.UP, -1.0, team)
			return true
	return false


# --- El bombası -----------------------------------------------------------------------------------------

## From _think_combat: a grenade at the target's last known position (hid for a while) or at it in
## its pit / tunnel, on the team's and this bot's caps (see the section header).
func _wx_think_grenade() -> void:
	if lod > 1 or team_node == null or _wx_throwing or mode != Mode.COMBAT:
		return
	var tg = _target
	if not _is_player(tg) or tg.is_dead() or tg.get("vehicle") != null:
		return
	var now := _now()
	if tok_shoot:
		_wx_tok_ms = now
	var feet: Vector3 = (tg as Node3D).global_position
	if _target_visible:
		_wx_seen_pos = feet
	if now < _wx_gren_ms or now - _wx_tok_ms > int(Balance.AI_GRENADE_TOKEN_MEM * 1000.0):
		return
	var aim := Vector3.INF
	if _target_visible:
		var depth: float = float(body.radius) + float(body.surface_height_at(feet)) - feet.distance_to(body.global_position)
		if depth > Balance.AI_GRENADE_PIT_DEPTH:
			aim = feet
	else:
		var hid := now - _seen_ms
		if hid > int(Balance.AI_GRENADE_HIDDEN_MIN * 1000.0) and hid < int(Balance.AI_GRENADE_MEMORY * 1000.0):
			aim = _wx_seen_pos
	if aim == Vector3.INF or Game.dominant_body(aim) != body:
		return
	var dist := global_position.distance_to(aim)
	if dist < Balance.AI_GRENADE_MIN_RANGE or dist > Balance.AI_GRENADE_MAX_RANGE:
		return
	if _flinch > 0.0 or _climb or _air or _reload_t > 0.0:
		return
	if not team_node.wx_grenade_ok():
		return
	var sol := _wx_solve_grenade(aim)
	if sol.is_empty() or _wx_ally_near(sol["land"], Balance.AI_GRENADE_ALLY_CLEAR):
		_wx_gren_ms = now + int(Balance.AI_GRENADE_RETRY * 1000.0)
		return
	if not team_node.wx_grenade_take():
		return
	_wx_gren_ms = now + int(Balance.AI_GRENADE_BOT_COOLDOWN * 1000.0)
	_wx_begin_throw(sol)


## Where the grenade leaves the hand: over the right shoulder, a little ahead (standing height).
func _wx_hand_point(fwd: Vector3) -> Vector3:
	var up := _up()
	return global_position + up * (EYE_H + 0.25) + fwd * 0.45 + fwd.cross(up).normalized() * 0.15


## A lob to `aim` (the target's feet): the elevations of AI_GRENADE_ELEVATIONS, each with a few speed
## corrections on the simulated landing, the throw speed capped at GRENADE_THROW_SPEED. {} when none
## lands within AI_GRENADE_ACCEPT m (no rough line), else {"vel", "land", "fwd"}.
func _wx_solve_grenade(aim: Vector3) -> Dictionary:
	var up := _up()
	var to := aim - global_position
	var flat := to - up * to.dot(up)
	if flat.length_squared() < 1.0:
		return {}
	var fwd := flat.normalized()
	var from := _wx_hand_point(fwd)
	var tgt: Vector3 = aim + body.up_at(aim) * 0.3
	var tf := tgt - from
	var t_rng := (tf - up * tf.dot(up)).length()
	var g0: float = Game.gravity_at(from).length()
	var best := {}
	var best_e := INF
	for el_deg in Balance.AI_GRENADE_ELEVATIONS:
		var el := deg_to_rad(float(el_deg))
		var dir := fwd * cos(el) + up * sin(el)
		var spd := sqrt(t_rng * g0 / maxf(sin(2.0 * el), 0.3))
		for it in 3:
			spd = clampf(spd, 3.0, Balance.GRENADE_THROW_SPEED)
			var land := _wx_sim_grenade(from, dir * spd)
			if land == Vector3.INF:
				break
			var e := land.distance_to(tgt)
			if e < best_e:
				best_e = e
				best = {"vel": dir * spd, "land": land, "fwd": fwd}
			if e < 0.8:
				break
			var lf := land - from
			var r_land := (lf - up * lf.dot(up)).dot(fwd)
			if r_land < 0.5 or (spd >= Balance.GRENADE_THROW_SPEED - 0.01 and r_land < t_rng):
				break                          # blocked right in front / out of reach at this angle
			spd *= sqrt(clampf(t_rng / r_land, 0.5, 2.0))
		if best_e < 1.0:
			break
	if best_e > Balance.AI_GRENADE_ACCEPT:
		return {}
	return best


## Landing point of a grenade thrown from `from` with `v`, flown like projectiles.gd (gravity of both
## planets, a little drag) against this planet's density (Vector3.INF: still in the air after 3 s).
func _wx_sim_grenade(from: Vector3, v: Vector3) -> Vector3:
	var p := from
	var dt := 0.05
	var t := 0.0
	while t < 3.0:
		v += Game.gravity_at(p) * dt
		v *= 1.0 - 0.015 * dt
		var np := p + v * dt
		t += dt
		if t > 0.12 and body.density_fast(np) < 0.0:
			return (p + np) * 0.5
		p = np
	return Vector3.INF


func _wx_ally_near(p: Vector3, r: float) -> bool:
	for b in team_node.bots:
		if is_instance_valid(b) and not b.is_dead() and (b as Node3D).global_position.distance_to(p) < r:
			return true
	return false


## Pops up (out of a crouch), stops, faces the throw, shows the grenade in the fist (the pin pings
## if this bot may make sounds) and winds up; the release and the follow-through run on a tween.
func _wx_begin_throw(sol: Dictionary) -> void:
	_wx_gren = sol
	_wx_throwing = true
	_tac = Tac.HOLD
	_tac_t = Balance.AI_GRENADE_WINDUP + 0.45
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_crouch = false
	_peek = true
	_flinch = maxf(_flinch, Balance.AI_GRENADE_WINDUP + 0.25)    # no rifle meanwhile
	_face = sol["fwd"]
	_set_held("")
	var gp := _wx_grenade_prop()
	if gp != null:
		gp.visible = true
	if tok_audio:
		team_node.wx_play_at("pin", _eye(), -4.0)
	team_node.wx_bot_action(index, "grenade")
	if _wx_tw != null and _wx_tw.is_valid():
		_wx_tw.kill()
	var total := Balance.AI_GRENADE_WINDUP + 0.4
	_wx_tw = create_tween()
	_wx_tw.tween_method(_wx_throw_pose, 0.0, total, total)
	_wx_tw.parallel().tween_callback(_wx_release).set_delay(Balance.AI_GRENADE_WINDUP)
	_wx_tw.tween_callback(_wx_throw_end)


## The throw over the animated pose (runs after the bot's own pose each frame): the right arm swings
## up and back over the shoulder (forearm behind the head) with the chest turned away, then whips
## forward and down; blended from and back to the animation (the astronaut's smoothed _rot).
func _wx_throw_pose(t: float) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD or astronaut == null:
		return
	var w_up := Balance.AI_GRENADE_WINDUP
	var sh_t := Vector3(3.5, 0.0, 0.25)
	var el_t := Vector3(1.7, 0.0, 0.0)
	var twist := -0.35                         # + yaw brings the right shoulder forward
	var w := 0.0
	if t < w_up:
		w = smoothstep(0.0, 1.0, t / (w_up * 0.7))
	else:
		var k := clampf((t - w_up) / 0.12, 0.0, 1.0)
		sh_t = sh_t.lerp(Vector3(1.15, 0.0, 0.1), k)
		el_t = el_t.lerp(Vector3(0.15, 0.0, 0.0), k)
		twist = lerpf(-0.35, 0.3, k)
		w = 1.0 - clampf((t - w_up - 0.15) / 0.22, 0.0, 1.0)
	var sh = astronaut.shoulder[1]
	var el = astronaut.elbow[1]
	var ch = astronaut.chest
	if sh == null or el == null or ch == null:
		return
	var rot: Dictionary = astronaut._rot
	(sh as Node3D).rotation = (rot.get(sh, (sh as Node3D).rotation) as Vector3).lerp(sh_t, w)
	(el as Node3D).rotation = (rot.get(el, (el as Node3D).rotation) as Vector3).lerp(el_t, w)
	(ch as Node3D).rotation = (rot.get(ch, (ch as Node3D).rotation) as Vector3) + Vector3(0.0, twist * w, 0.0)
	astronaut.sync_skeleton()


## The grenade leaves the hand (the team launches it; multiplayer: RivalTeam.events().grenade_thrown).
## Killed during the wind-up: the live grenade drops where it stood.
func _wx_release() -> void:
	if _wx_gprop != null:
		_wx_gprop.visible = false
	if team_node == null or _wx_gren.is_empty() or mode == Mode.ABOARD:
		return
	var fwd: Vector3 = _wx_gren["fwd"]
	var vel: Vector3 = _wx_gren["vel"]
	_wx_gren = {}
	if mode == Mode.DEAD:
		team_node.wx_throw_grenade(self, _vis_pos + _up() * 1.2, Vector3.ZERO, Balance.AI_GRENADE_FUSE)
		return
	team_node.wx_throw_grenade(self, _wx_hand_point(fwd), vel, Balance.AI_GRENADE_FUSE)
	if tok_audio:
		team_node.wx_play_at("whoosh", _eye(), -8.0)


func _wx_throw_end() -> void:
	_wx_throwing = false
	if _wx_gprop != null:
		_wx_gprop.visible = false
	if mode == Mode.COMBAT and _held == "":
		_set_held("rifle")


## The grenade in the right fist during the wind-up (white body, orange band, red LED).
func _wx_grenade_prop() -> Node3D:
	if _wx_gprop != null and is_instance_valid(_wx_gprop):
		return _wx_gprop
	var hands: Array = astronaut.hand
	if hands.size() < 2 or hands[1] == null:
		return null
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.88, 0.89, 0.9)
	white.roughness = 0.4
	var orange := StandardMaterial3D.new()
	orange.albedo_color = Color(1.0, 0.48, 0.1)
	orange.roughness = 0.5
	var led := StandardMaterial3D.new()
	led.albedo_color = Color(1.0, 0.15, 0.1)
	led.emission_enabled = true
	led.emission = Color(1.0, 0.15, 0.1)
	led.emission_energy_multiplier = 5.0
	var g := VM.node(hands[1], Vector3(0, -0.1, 0.02))
	VM.sphere(g, Vector3.ZERO, 0.045, white)
	VM.seg(g, Vector3(0, -0.009, 0), Vector3(0, 0.009, 0), 0.047, 0.047, orange, 12)
	VM.sphere(g, Vector3(0, 0.05, 0), 0.008, led)
	g.visible = false
	_wx_gprop = g
	return g


## The team saw a live grenade of the player within reach (4 Hz): sprint away from it for
## AI_GRENADE_FLEE_TIME s (a working bot drops its work and turns on the thrower at `src`).
func wx_dodge_grenade(gpos: Vector3, src: Vector3) -> void:
	if mode != Mode.WORK and mode != Mode.COMBAT:
		return
	if _wx_task == "intercept" or _wx_task == "exit" or _wx_throwing or _climb:
		return
	var now := _now()
	if now - _wx_flee_ms < 1500:
		return
	_wx_flee_ms = now
	var up := _up()
	var away := global_position - gpos
	away = away - up * away.dot(up)
	if away.length_squared() < 0.01:
		away = -global_transform.basis.z
	_on_threat(src, false)
	if mode != Mode.COMBAT:
		return
	_tac = Tac.STRAFE
	_tac_t = Balance.AI_GRENADE_FLEE_TIME
	_strafe = away.normalized()
	_strafe_speed = Balance.AI_RUN_SPEED
	_move_to = Vector3.INF
	_crouch = false
	_peek = false


# =================================================================================================
# Radio chatter (scripts/audio/radio_fx.gd, Game.sfx.radio)
# =================================================================================================
# One-line hooks above report to the team radio: take_damage "hit" (alive), _die "down" (an ally
# nearby calls it), the reload in _shoot_update "reload", _enter_combat "contact" (it saw the player)
# or "alert" (shot at / called to help), the Delici Top shot in _wx_think_buster "launch". Grenade,
# torpedo and intercept callouts come from RivalTeam.events().bot_action. The radio throttles
# team-wide and decides who hears it; sound only, local, a no-op without it.

func _radio_call(kind: String) -> void:
	var s = Game.sfx
	if s == null or not is_instance_valid(s):
		return
	var r = s.get("radio")
	if r != null and is_instance_valid(r) and r.has_method("bot_event"):
		r.bot_event(self, kind)


# =================================================================================================
# Hit reactions (scripts/player/hit_reactor.gd; tunables: balance.gd "Hit reactions")
# =================================================================================================
# Hooks above (one line each): take_damage -> _hr_hit (alive, after the hp; the hit point comes from
# Game.hit_pos) and _hr_dead_hit (dead: the rest of a killing blast throws the corpse); _die ->
# _hr_keep_ragdoll / _hr_launch; _physics_process -> _hr_physics (the reactor's tick; the rest is
# skipped while down) and no _think while _hr_busy(); _process -> _hr_process (get-up, capsule while
# down); _tick -> _hr_move (the shove moves the SIM state: the render interpolation shows it and the
# walk cycle stumbles with the real displacement); _on_blocked -> _hr_blocked (a wall stops the shove);
# _hop refuses while busy; fling() below AI_FLING_KO -> _hr_push and nothing while down; _on_blast ->
# _hr_blast (a shove just outside the damage radius; inside, the blast's damage impulse does it); the
# rifle's hit on a player passes its hit point.
# The bot's side of a reaction (_hr_on_react / _hr_on_down / _hr_on_getup / _hr_on_up):
#   flinch     no shooting for the reactor's aim_block (through _flinch: _shoot_update needs no hook,
#              the slides / jumps section's _reactor_busy() sees it too); the skid adds to its walk
#   stagger    also no thinking, slides or hops; digging stops; out of a crouch; the hop is flown by
#              the normal airborne branch of _tick (_air / _vy: the kinematic arc fling() uses too),
#              the skid then runs along the density ground with friction; a wall stops it
#   knockdown  only at lod 0-1 with a free slot under the team's AI_RAGDOLL_MAX (else a stagger); the
#              ragdoll is this bot's `_ragdoll` (the pusher's limb shove finds it) and on the team's
#              list; a grenade being wound up drops live; the capsule lies along the body; the get-up
#              stands it where it lies (the node moved: _sync_from_node restarts the sim and the
#              interpolation there). Dying while down: the knockdown ragdoll goes on as the corpse.
# Gates for other code: is_staggered(), is_down() (also during the get-up).
# Multiplayer: bots are host-simulated (none exist on a client); every reaction goes out as
# RivalTeam.events().bot_react(index, kind, dir, strength, bone) (dir x strength = the velocity; see
# rival_team.gd WeaponEvents); the corpse's launch (hit_reactor.gd corpse_v / corpse_point) goes out
# from _hr_keep_ragdoll / _hr_launch as Net.bots.on_bot_died (scripts/net/net_bots.gd).

const HitReactor := preload("res://scripts/player/hit_reactor.gd")

var _reactor = null                    # hit_reactor.gd (made on the first hit / shove)
var _hr_cmd := 0.0                     # m/s of shove commanded on the last sim step (wall check)


## Shoved off balance by a hit (stumbling back, no control).
func is_staggered() -> bool:
	return _reactor != null and _reactor.is_staggered()


## Knocked down (the ragdoll) or getting up.
func is_down() -> bool:
	return _reactor != null and _reactor.is_down()


func _hr_busy() -> bool:
	return _reactor != null and _reactor.busy()


func _hr_get():
	if _reactor == null:
		_reactor = HitReactor.new()
		_reactor.setup(self, astronaut, _cap_cs)
		_reactor.can_down = _hr_can_down
		_reactor.reacted.connect(_hr_on_react)
		_reactor.went_down.connect(_hr_on_down)
		_reactor.getup_started.connect(_hr_on_getup)
		_reactor.recovered.connect(_hr_on_up)
	return _reactor


func _hr_hit(amount: float, from_pos: Vector3, impulse: Vector3) -> void:
	if not Net.is_client():
		_hr_get().on_hit(amount, from_pos, impulse)


func _hr_dead_hit(impulse: Vector3) -> void:
	if _reactor != null:
		_reactor.on_dead_hit(impulse)


func _hr_push(v: Vector3, from_pos: Vector3) -> void:
	if from_pos != Vector3.ZERO:
		_on_threat(from_pos, true)
	_hr_get().on_push(v, from_pos)


## A blast nearby (Game.blast): just outside its damage radius a shove away from it (up to a stagger
## at the edge); inside, its damage impulse already shoves through take_damage.
func _hr_blast(pos: Vector3, d: float, radius: float) -> void:
	var r := maxf(radius, 1.0)
	if d <= r * 1.15:
		return
	var up := _up()
	var away := global_position - pos
	away -= up * away.dot(up)
	var sp := clampf((r * 2.0 - d) / r * 3.5, 0.0, 3.5)
	if sp > 0.2 and away.length_squared() > 1e-4:
		_hr_get().on_push(away.normalized() * sp, pos)


## Every physics frame: the reactor's tick. True while down (the bot does nothing else).
func _hr_physics(delta: float) -> bool:
	if _reactor == null:
		return false
	_reactor.tick(delta, not _air and not _climb)
	if _reactor.is_down():
		return true
	if _reactor.aim_block > 0.0:
		_flinch = maxf(_flinch, _reactor.aim_block)
	return false


## Every frame while down: the get-up / the capsule; the skin follows on the astronaut's own process.
func _hr_process(delta: float) -> bool:
	if _reactor == null or not _reactor.is_down():
		return false
	_reactor.process(delta)
	return true


## _tick: the walking velocity with the shove (instant, not the walking acceleration) and the limp.
## A shove that stopped dead (a wall in the air) ends.
func _hr_move(want: Vector3, up: Vector3) -> Vector3:
	if _reactor == null:
		return want
	var kb: Vector3 = _reactor.kb_velocity()
	if _hr_cmd > 1.0 and kb.length_squared() > 1.0:
		var hv := velocity - up * velocity.dot(up)
		if hv.length() < _hr_cmd * 0.25:
			_reactor.blocked()
			kb = Vector3.ZERO
	var v: Vector3 = _reactor.move_velocity(want, up)
	if _reactor.is_staggered():
		v += _knock - up * _knock.dot(up)  # a fling arc in flight keeps its push
	_hr_cmd = kb.length()
	if kb.length_squared() > 0.04:
		_hv = v - up * v.dot(up)
	return v


func _hr_blocked() -> bool:
	if _reactor == null or _reactor.kb_velocity().length_squared() < 0.04:
		return false
	_reactor.blocked()
	_hv = Vector3.ZERO
	_hr_cmd = 0.0
	return _reactor.is_staggered()


## May it go down now: near / mid LOD and a free slot under the team's live-ragdoll cap.
func _hr_can_down() -> bool:
	if lod > 1 or team_node == null:
		return false
	var n := 0
	var rl = team_node.get("_ragdolls")
	if rl is Array:
		for r in rl:
			if r != null and is_instance_valid(r) and not r.is_queued_for_deletion():
				var bd = r.get("bodies")
				if bd is Dictionary and not (bd as Dictionary).is_empty():
					n += 1
	return n < Balance.AI_RAGDOLL_MAX


func _hr_on_react(kind: String, dir: Vector3, strength: float, bone: String) -> void:
	if kind == "stagger":
		_stop_dig()
		_crouch = false
		_peek = false
		if sliding:
			_end_slide(false)
		var lf: float = _reactor.lift
		if lf > 0.3 and not _climb:
			_air = true
			_vy = maxf(_vy, lf)
			_jet_t = 0.0
	if team_node != null:
		team_node.events().bot_react.emit(index, kind, dir, strength, bone)


func _hr_on_down(rag: Node) -> void:
	_stop_dig()
	if sliding:
		_end_slide(false)
	_crouch = false
	_crouch_k = 0.0
	_peek = false
	_climb = false
	_air = false
	_vy = 0.0
	_hv = Vector3.ZERO
	_hr_cmd = 0.0
	velocity = Vector3.ZERO
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	var st: Dictionary = get_meta("fling", {})
	if bool(st.get("live", false)):
		st["live"] = false                 # the fling arc's tween ends itself
	if _wx_throwing:
		_hr_drop_grenade()
	_tracer.visible = false
	_fire_vis = 0.0
	_ragdoll = rag
	_rag_frozen = false
	if team_node != null:
		team_node.add_ragdoll(rag)


## Knocked down during a grenade wind-up: it drops, live, where it stood.
func _hr_drop_grenade() -> void:
	if _wx_tw != null and _wx_tw.is_valid():
		_wx_tw.kill()
	_wx_throwing = false
	if _wx_gprop != null:
		_wx_gprop.visible = false
	if not _wx_gren.is_empty() and team_node != null:
		team_node.wx_throw_grenade(self, _vis_pos + _up() * 1.0, Vector3.ZERO, Balance.AI_GRENADE_FUSE)
	_wx_gren = {}


func _hr_on_getup(xf: Transform3D) -> void:
	var nb: Node3D = Game.dominant_body(xf.origin)
	if nb != null:
		body = nb
	_vis_pos = xf.origin
	_face = -xf.basis.z


func _hr_on_up() -> void:
	_ragdoll = null                        # (the reactor freed it)
	_hv = Vector3.ZERO
	velocity = Vector3.ZERO
	_air = false
	_vy = 0.0
	_pose_pos = Vector3.INF
	_think_acc = 1.0                       # decide right away
	astronaut.animate(0.016, {"speed": 0.0, "grounded": true, "probe": false})
	astronaut.sync_skeleton()


## _die: a knocked-down body with live physics goes on as the corpse (true: _ragdoll is it).
func _hr_keep_ragdoll(impulse: Vector3) -> bool:
	if _reactor == null:
		return false
	var r = _reactor.take_corpse(impulse)
	if r == null:
		return false
	_ragdoll = r
	var rl = team_node.get("_ragdolls") if team_node != null else null
	if rl is Array:
		(rl as Array).erase(r)             # _die puts it on the list again
	if Net.is_host():
		Net.bots.on_bot_died(self, _reactor.corpse_v, _reactor.corpse_point)   # the client's corpse
	return true


## _die: a fresh corpse's launch with the rest of the killing blast (hit_reactor.gd death_launch).
func _hr_launch(v: Vector3) -> Vector3:
	_hr_get()                              # (never hit before, e.g. a first-shove KO: still capped)
	var out: Vector3 = _reactor.death_launch(v)
	if Net.is_host():                      # the client's corpse: the whole launch, before the split
		Net.bots.on_bot_died(self, _reactor.corpse_v if _reactor != null else v,
				_reactor.corpse_point if _reactor != null else Vector3.INF)
	return out


# =================================================================================================
# Pressure, cover and lethality (tunables: balance.gd "Smarter, more dangerous bots", AI_PR_*)
# =================================================================================================
# Hooks above (one line each): _think_combat -> _pr_observe (sight time, his last known position and
# heading), the calm check -> _pr_keep_combat (a hunt keeps it in the fight), the tactic match ->
# _pr_tac_tick for FLANK / SUPPRESS / HUNT (new Tac values); _decide -> _pr_decide first;
# _shoot_update -> _pr_hit_chance, _pr_burst_len / _pr_shot_gap, blind suppressive fire
# (_pr_blind_fire, also in wants_to_shoot for the shooter token), suppressive misses close past
# him, and no firing while is_staggered() / is_down().
#   Pressure (near / mid LOD, the player on foot and in sight): two or more bots on him (per living
#     player on the planet), or him reloading / below AI_PR_WEAK_HP / knocked over / stumbling from a
#     heavy hit, or the bot clearly healthier. The first bot with a shooter token and an ally lays
#     suppressive fire (SUPPRESS: holds still, longer bursts at AI_PR_SUPPRESS_ACC, the misses crack
#     close past him, it keeps pinning the spot where he ducked for AI_PR_SUPPRESS_MEMORY s); up to
#     AI_PR_FLANKERS sprint to a point AI_PR_FLANK_DIST m from him, AI_PR_FLANK_ANGLE° round from their
#     own side toward his side / rear (his view), preferring spots his line of sight cannot reach
#     (tested on the team's cover-eval budget; the next flanker takes the other side), then settle
#     and shoot from there; the rest push in to AI_PR_PUSH_RANGE m firing on the move (alone
#     against a weakened player it pushes instead of flanking). The squad is counted at decision
#     time from the team's bots (no per-frame work).
#   Outgunned (not pressing; alone and shot at, or hurt below AI_PR_OUTGUN_HP while he is
#     healthier): runs to a fresh cover even when not under fire, else starts the cover search, and
#     holds the next cover AI_PR_COVER_HOLD × longer, peek-shooting (a peek counts as settled).
#   Lethality: the hit model and its numbers are in balance.gd.
#   Hunt: AI_PR_HUNT_AFTER s after losing sight of him on the planet it stands on, it walks to his
#     last known position, looks around for AI_PR_HUNT_LOOK s, then searches points up to
#     AI_PR_HUNT_RADIUS m around it (along his last heading when he was moving), until he shows up,
#     AI_PR_HUNT_TIME s pass since the last sighting, or he dies / boards a vehicle / leaves.
# A grenade wind-up (El bombası) holds still; a pod crew never flees (Drop-pod raids below).

var _pr_acq_ms := -100000               # ms: the target came into sight (continuously since)
var _pr_vis_ms := -100000               # ms: last combat think it was in sight
var _pr_lkp := Vector3.INF               # his feet when last seen
var _pr_lkv := Vector3.ZERO              # his velocity then
var _pr_mode := ""                       # FLANK: "flank" / "push"
var _pr_side := 0.0                      # FLANK: the side taken around him (±1)
var _pr_until := 0                       # ms: FLANK / SUPPRESS end
var _pr_cover_long := false              # outgunned: hold the next cover longer
var _pr_hunt_i := 0
var _pr_look_t := 0.0
var _pr_flank_cd := 0                    # ms: no new flank run before then (fights from the new angle)


## Every combat think: how long the player has been in sight, where he was last seen and going;
## an outgunned bot's cover hold is stretched once it is in.
func _pr_observe(now: int) -> void:
	if _target_visible and _is_player(_target):
		if now - _pr_vis_ms > 900:
			_pr_acq_ms = now
		_pr_vis_ms = now
		_pr_lkp = (_target as Node3D).global_position
		var v = _target.get("velocity")
		_pr_lkv = v if v is Vector3 else Vector3.ZERO
	if _pr_cover_long and _tac == Tac.COVER:
		_pr_cover_long = false
		_tac_t *= Balance.AI_PR_COVER_HOLD


## Suppressing the spot where the player ducked out of sight (no hits possible).
func _pr_blind_fire() -> bool:
	return _tac == Tac.SUPPRESS and _threat_pos != Vector3.INF and _is_player(_target) \
			and _now() - _seen_ms < int(Balance.AI_PR_SUPPRESS_MEMORY * 1000.0)


## Rounds in the next burst: short controlled bursts at a player (longer while suppressing), the old
## rhythm at skiffs and structures.
func _pr_burst_len(vs_player: bool) -> int:
	if not vs_player:
		return Balance.AI_RIFLE_BURST
	if _tac == Tac.SUPPRESS:
		return Balance.AI_PR_SUPPRESS_BURST
	return _rng.randi_range(Balance.AI_PR_BURST_MIN, Balance.AI_PR_BURST_MAX)


## Seconds to the next round (inside a burst / the pause after it).
func _pr_shot_gap(vs_player: bool, in_burst: bool) -> float:
	if not vs_player:
		return Balance.AI_RIFLE_INTERVAL if in_burst else Balance.AI_RIFLE_PAUSE * _rng.randf_range(0.8, 1.3)
	if in_burst:
		return Balance.AI_PR_BURST_GAP
	if _tac == Tac.SUPPRESS:
		return Balance.AI_PR_SUPPRESS_PAUSE * _rng.randf_range(0.8, 1.2)
	return Balance.AI_PR_BURST_PAUSE * _rng.randf_range(0.8, 1.25)


## Hit chance of one round before the slide / air factors (see balance.gd for the model): players by
## the angular-size curve, the sight time and the lead; skiffs / structures by the old curve.
func _pr_hit_chance(tg: Node3D, dist: float, rng_max: float, is_pl: bool) -> float:
	var now := _now()
	var c: float
	if is_pl:
		c = Balance.AI_PR_HIT_CLOSE * minf(1.0, Balance.AI_PR_CLOSE / maxf(dist, 0.1))
	else:
		c = Balance.AI_RIFLE_HIT * (1.0 - 0.5 * clampf(dist / rng_max, 0.0, 1.0))
	if velocity.length() > 1.0:
		c *= Balance.AI_ACC_MOVING
	elif _still_t >= Balance.AI_PR_SETTLE_TIME or (_tac == Tac.COVER and _peek):
		c *= Balance.AI_ACC_SETTLED
	if now - _threat_ms < 2000:
		c *= Balance.AI_ACC_UNDER_FIRE
	if is_pl:
		var track := clampf(float(now - _pr_acq_ms) / (Balance.AI_PR_TRACK_TIME * 1000.0), 0.0, 1.0)
		c *= lerpf(Balance.AI_PR_FIRST_SHOT_K, 1.0, track)
		var tv = tg.get("velocity")
		if tv is Vector3:
			var los := (_aim_point(tg) - _eye()).normalized()
			var lat: Vector3 = (tv as Vector3) - los * (tv as Vector3).dot(los)
			var v_eff := lat.length() * lerpf(1.0, Balance.AI_PR_LEAD_K, track)
			c *= clampf(1.0 - v_eff / Balance.AI_PR_LEAD_SPEED, Balance.AI_PR_LEAD_MIN, 1.0)
		if _tac == Tac.SUPPRESS:
			c *= Balance.AI_PR_SUPPRESS_ACC
	else:
		var tv2 = tg.get("linear_velocity")
		if tv2 is Vector3:
			c *= clampf(1.0 - (tv2 as Vector3).length() / 30.0, 0.35, 1.0)
	return c


## The allies fighting the same player near this bot: {"n", "sup" (suppressing), "flk" (flanking),
## "side" (sum of their flank sides), "players" (living players on this planet, at least 1)}.
func _pr_squad(pl: Node3D) -> Dictionary:
	var now := _now()
	var n := 0
	var sup := 0
	var flk := 0
	var side := 0.0
	if team_node != null:
		for b in team_node.bots:
			if b == self or not is_instance_valid(b) or b.mode != Mode.COMBAT or b._target != pl:
				continue
			if now - int(b._seen_ms) > 4000 or (b as Node3D).global_position.distance_to(global_position) > Balance.AI_PR_SQUAD_RANGE:
				continue
			n += 1
			if b._tac == Tac.SUPPRESS:
				sup += 1
			elif b._tac == Tac.FLANK and str(b._pr_mode) == "flank":
				flk += 1
				side += float(b._pr_side)
	var players := 0
	for p in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if p != null and is_instance_valid(p) and not p.is_dead() and Game.dominant_body((p as Node3D).global_position) == body:
			players += 1
	return {"n": n, "sup": sup, "flk": flk, "side": side, "players": maxi(players, 1)}


## The player is vulnerable now: low hp, reloading, knocked over or stumbling from a heavy hit.
func _pr_player_weak(pl: Node3D) -> bool:
	var h = pl.get("hp")
	var hm = pl.get("hp_max")
	if (h is float or h is int) and (hm is float or hm is int) and float(h) < float(hm) * Balance.AI_PR_WEAK_HP:
		return true
	if pl.has_method("is_ragdolled") and bool(pl.call("is_ragdolled")):
		return true
	if pl.has_method("current"):
		var it = pl.call("current")
		if it != null and is_instance_valid(it) and it.get("reloading") == true:
			return true
	var hf = pl.get("hit_fx")                # hit_reactor.gd PlayerFeel: a heavy hit's stumble spring
	if hf is Object:
		var sa = (hf as Object).get("_sa")
		if sa is Vector3 and (sa as Vector3).length() > 0.03:
			return true
	return false


## The pressure / outgunned / hunt choice (before _decide's own); false leaves it to _decide.
func _pr_decide(threat: Vector3, dist: float, under_fire: bool) -> bool:
	if _wx_throwing:                         # a grenade wind-up: stand still (El bombası)
		_tac = Tac.HOLD
		_tac_t = 0.3
		_move_to = Vector3.INF
		_strafe = Vector3.ZERO
		return true
	var pl = _target
	if lod > 1 or team_node == null or not _is_player(pl) or pl.is_dead() or pl.get("vehicle") != null:
		return false
	var now := _now()
	if not _target_visible:
		if now - _seen_ms > int(Balance.AI_PR_HUNT_AFTER * 1000.0) and _pr_hunt_ok(now):
			_pr_start_hunt()
			return true
		return false                         # (the first seconds: the careful advance, grenades)
	var sq := _pr_squad(pl)
	var allies: int = sq["n"]
	var hp_k := hp / maxf(hp_max, 1.0)
	var pl_k := 1.0
	var ph = pl.get("hp")
	var pm = pl.get("hp_max")
	if (ph is float or ph is int) and (pm is float or pm is int):
		pl_k = float(ph) / maxf(float(pm), 1.0)
	var weak := _pr_player_weak(pl)
	var press: bool = weak or allies + 1 >= 2 * int(sq["players"]) or (hp_k > 0.8 and pl_k < 0.5)
	var up := _up()
	var to_t := threat - global_position
	var flat := to_t - up * to_t.dot(up)
	flat = flat.normalized() if flat.length_squared() > 1e-4 else -global_transform.basis.z
	if not press:
		var outgunned := (allies == 0 and under_fire) or (hp_k < Balance.AI_PR_OUTGUN_HP and pl_k > hp_k)
		if not outgunned:
			return false
		_pr_cover_long = true
		var cover_fresh := _cover_pos != Vector3.INF and _cover_pos.distance_to(global_position) < 16.0 \
				and _covered(threat, _cover_pos + up * (EYE_H - CROUCH_DROP))
		if cover_fresh:
			_tac = Tac.TO_COVER
			_tac_t = 5.0
			return true
		if _cover_search.is_empty() and lod == 0:
			_request_cover(threat, false)
		return false                         # (the normal strafing while it searches)
	_pr_cover_long = false
	# One suppresses (with an ally to cover)...
	if allies >= 1 and int(sq["sup"]) == 0 and tok_shoot and _reload_t <= 0.0:
		_tac = Tac.SUPPRESS
		_tac_t = Balance.AI_PR_SUPPRESS_TIME
		_pr_until = now + int(Balance.AI_PR_SUPPRESS_TIME * _rng.randf_range(0.8, 1.25) * 1000.0)
		_move_to = Vector3.INF
		_strafe = Vector3.ZERO
		_crouch = false
		_peek = true
		return true
	# ...up to AI_PR_FLANKERS run to his side / rear...
	if int(sq["flk"]) < Balance.AI_PR_FLANKERS and hp_k >= Balance.AI_FLEE_HP and not (weak and allies == 0) \
			and now > _pr_flank_cd:
		var fp := _pr_flank_point(pl, threat, float(sq["side"]))
		if fp != Vector3.INF:
			_pr_go(fp, "flank", Balance.AI_RUN_SPEED, Balance.AI_PR_FLANK_TIME)
			return true
	# ...the rest push in, firing on the move.
	if dist > Balance.AI_PR_PUSH_RANGE + 1.5:
		var side := up.cross(flat).normalized() * (1.0 if _rng.randf() < 0.5 else -1.0)
		var step := minf(dist - Balance.AI_PR_PUSH_RANGE, 8.0)
		_pr_go(global_position + (flat * 0.85 + side * 0.35).normalized() * step, "push", Balance.AI_STRAFE_SPEED, 3.0)
		return true
	return false                             # (close: the normal close-range strafing)


## A FLANK / push move to p.
func _pr_go(p: Vector3, m: String, spd: float, t: float) -> void:
	_tac = Tac.FLANK
	_pr_mode = m
	_tac_t = t
	_pr_until = _now() + int(t * 1000.0)
	_move_to = p
	_move_speed = spd
	_strafe = Vector3.ZERO
	_crouch = false
	_peek = false


## A flank point AI_PR_FLANK_DIST m from the player (closer when the bot is closer), three angles
## round from the bot's side (the other flankers' side mirrored); scored by how far behind his view
## it lies, the run, and (on the team's cover-eval budget) whether it is ground he cannot see.
func _pr_flank_point(pl: Node3D, threat: Vector3, side_sum: float) -> Vector3:
	var pp: Vector3 = pl.global_position
	var up: Vector3 = body.up_at(pp)
	var back := global_position - pp
	back -= up * back.dot(up)
	if back.length_squared() < 0.01:
		back = pl.global_transform.basis.z - up * pl.global_transform.basis.z.dot(up)
	if back.length_squared() < 1e-4:
		return Vector3.INF
	back = back.normalized()
	var view := -pl.global_transform.basis.z
	var cam = pl.get("camera")
	if cam is Node3D:
		view = -(cam as Node3D).global_transform.basis.z
	view -= up * view.dot(up)
	view = view.normalized() if view.length_squared() > 1e-4 else -back
	var sgn := -signf(side_sum) if absf(side_sum) > 0.1 else (1.0 if _rng.randf() < 0.5 else -1.0)
	var r := clampf(minf(Balance.AI_PR_FLANK_DIST, pp.distance_to(global_position) * 0.9), 6.0, 14.0)
	var budget: int = team_node.take_cover_eval(3) if team_node != null else 0
	var best := Vector3.INF
	var best_s := -INF
	for k in 3:
		var dir := back.rotated(up, deg_to_rad(Balance.AI_PR_FLANK_ANGLE + float(k - 1) * 25.0) * sgn)
		var q := _on_sphere(pp + dir * r)
		var s := -view.dot(dir) * 2.0 - q.distance_to(global_position) * 0.08
		if k < budget:
			var qu: Vector3 = body.up_at(q)
			var g := _probe(q, qu, q + qu * 20.0)
			if g["ok"]:
				q = g["pos"]
				if _covered(threat, q + qu * (EYE_H - CROUCH_DROP)):
					s += 1.5
			else:
				s -= 3.0
		if s > best_s:
			best_s = s
			best = q
	_pr_side = sgn
	return best


## FLANK / SUPPRESS / HUNT, every combat think.
func _pr_tac_tick(dt: float, threat: Vector3, _dist: float, under_fire: bool) -> void:
	if _wx_throwing:
		return
	var now := _now()
	match _tac:
		Tac.SUPPRESS:
			_move_to = Vector3.INF
			_strafe = Vector3.ZERO
			_crouch = false
			_peek = true
			if not _target_visible and (threat - global_position).length_squared() > 0.01:
				_face = (threat - global_position).normalized()
			var lost := not _target_visible and not _pr_blind_fire()
			if now > _pr_until or lost or _reload_t > 0.0 or (under_fire and hp < hp_max * Balance.AI_PR_OUTGUN_HP):
				_tac = Tac.NONE
				_peek = false
		Tac.FLANK:
			_crouch = false
			if _move_to == Vector3.INF or now > _pr_until:
				_tac = Tac.NONE
				if _pr_mode == "flank":
					_pr_flank_cd = now + 6000
				if _target_visible:
					_tac = Tac.HOLD                  # settle and shoot from the new angle
					_tac_t = _rng.randf_range(0.8, 1.6)
			else:
				if not _target_visible and (_move_to - global_position).length_squared() > 0.01:
					_face = (_move_to - global_position).normalized()
				if _move_speed >= Balance.AI_RUN_SPEED * 0.9:
					_maybe_slide_to(_move_to, under_fire, 0.45)  # across the open (Slides and jumps)
		Tac.HUNT:
			_pr_hunt_tick(dt, now)


## May it (still) hunt: he was seen within AI_PR_HUNT_TIME s on this planet and is alive, on foot
## and still on this planet.
func _pr_hunt_ok(now: int) -> bool:
	if _pr_lkp == Vector3.INF or now - _seen_ms > int(Balance.AI_PR_HUNT_TIME * 1000.0):
		return false
	var pl = _target if _is_player(_target) else _pick_player()
	if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.get("vehicle") != null:
		return false
	return Game.dominant_body(_pr_lkp) == body and Game.dominant_body((pl as Node3D).global_position) == body


## The calm check: a hunt keeps the bot in the fight (and starts if it may).
func _pr_keep_combat(now: int) -> bool:
	if not _pr_hunt_ok(now):
		return false
	if _tac != Tac.HUNT:
		_pr_start_hunt()
	return true


func _pr_start_hunt() -> void:
	_tac = Tac.HUNT
	_tac_t = Balance.AI_PR_HUNT_TIME
	_pr_hunt_i = 0
	_pr_look_t = 0.0
	_crouch = false
	_peek = false
	_strafe = Vector3.ZERO
	_move_to = _pr_lkp
	_move_speed = Balance.AI_STRAFE_SPEED


## Walk to the search point, look around, pick the next one.
func _pr_hunt_tick(dt: float, now: int) -> void:
	_crouch = false
	if _target_visible or not _pr_hunt_ok(now):
		_tac = Tac.NONE
		return
	if _move_to != Vector3.INF:
		if (_move_to - global_position).length_squared() > 0.01:
			_face = (_move_to - global_position).normalized()
		if _still_t > 2.0:
			_move_to = Vector3.INF               # stuck: search from here
		return
	_pr_look_t += dt
	var up := _up()
	var look := _pr_lkv - up * _pr_lkv.dot(up)
	if look.length_squared() < 0.25:
		look = _pr_lkp - global_position
		look -= up * look.dot(up)
	if look.length_squared() < 1e-4:
		look = -global_transform.basis.z
	_face = look.normalized().rotated(up, sin(_pr_look_t * 2.2 + float(index)) * 1.3)
	if _pr_look_t < Balance.AI_PR_HUNT_LOOK:
		return
	_pr_look_t = 0.0
	_pr_hunt_i += 1
	var lu: Vector3 = body.up_at(_pr_lkp)
	var head := _pr_lkv - lu * _pr_lkv.dot(lu)
	var dir: Vector3
	if head.length_squared() > 0.25:
		dir = head.normalized().rotated(lu, _rng.randf_range(-0.9, 0.9))
	else:
		var x := lu.cross(Vector3.RIGHT if absf(lu.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
		dir = x.rotated(lu, float(_pr_hunt_i + index) * 2.39996)
	var r := Balance.AI_PR_HUNT_RADIUS * clampf(0.4 + 0.25 * float(_pr_hunt_i), 0.4, 1.3)
	_move_to = _on_sphere(_pr_lkp + dir * r)
	_move_speed = Balance.AI_WALK_SPEED


# =================================================================================================
# Suppression and the look of its fire (2026-10-06, "Botların baskı altında kalması" / "Düşman
# ateşinin okunması"; tunables: balance.gd "COMBAT FEEL", AI_SUP_* / EF_*; the drawing:
# scripts/war/enemy_fire.gd)
# =================================================================================================
# Hooks above (one line each): _on_shot -> _sup_near_miss (every round of another side passing
# within AI_SUP_NEAR_R), _on_blast -> _sup_blast, _on_threat -> _sup_add (a hit); bullet impacts near
# it come through scripts/war/erosion.gd -> sup_impact; _decide -> _sup_decide FIRST (before the
# pressure choice, so a pinned bot is never picked to flank, push or suppress); the COVER tactic ->
# _sup_peek_k (and no jump peek while pinned); _shoot_update -> _sup_acc (hit chance), _sup_spread
# (misses) and the shot's look, EnemyFire.shot (a muzzle-flash halo, the flying red tracer, where a
# miss lands: dirt and cover erosion) instead of the old instant line.
#   The meter (_sup, 0..1, brought up to date lazily: no per-frame work) rises with each crack
#     (AI_SUP_NEAR_MISS × 1 at 0 m .. × 0.5 at AI_SUP_NEAR_R), each impact within AI_SUP_IMPACT_R
#     (AI_SUP_IMPACT × the round's erosion weight), a blast (AI_SUP_BLAST, 0 at 3 × its radius) and a
#     hit (AI_SUP_HIT), × the bot's nerve (0.75..1.25); it drains AI_SUP_DECAY / s once AI_SUP_HOLD s
#     pass without fire (AI_SUP_DECAY_FIRE before). Pinned from AI_SUP_PIN until it falls under
#     AI_SUP_RELEASE: ~2-3 s of quiet bring a pinned bot back.
#   The pin edge drops an advance / flank / push / suppress / hunt / strafe / hold at once (a
#     re-decide), calls "pinned" on the radio (one guarded line: radio_fx.gd maps the key, unknown
#     keys are dropped), and a peeking bot ducks back. Pinned: if ducking where it stands hides it,
#     it holds that spot as cover (COVER, crouched); a fresh cover within 16 m: it runs there
#     (TO_COVER); exposed: it falls back away from the threat for AI_SUP_FALLBACK s (FLEE, with a
#     cover search "away" at near LOD). In cover it peeks AI_SUP_PEEK × as long and hides AI_SUP_HIDE
#     × as long, no jump peeks; its rounds hit × AI_SUP_ACC_PIN .. AI_SUP_ACC (× AI_SUP_ACC_RATTLED
#     just under the pin) and miss up to AI_SUP_SPREAD × wider. A crack within AI_SUP_FLINCH_R makes
#     it flinch: no aim for AI_SUP_FLINCH s and (near LOD) a small torso twitch (astronaut.apply_hit,
#     the hit-reaction springs).
#   suppression() (0..1) / is_suppressed(): read-outs for the body language (the hunched posture).
# Multiplayer: bots are host-simulated; a client's puppet posture would need suppression() as one
# byte in the bot snapshot (net_bots.gd). The tracers / flashes are drawn on the client from the
# synced shot (Net.bots.on_bot_shot -> net_bot.gd, which should call EnemyFire.shot).

const EnemyFire := preload("res://scripts/war/enemy_fire.gd")

var _sup := 0.0                          # suppression meter 0..1 (as of _sup_t)
var _sup_t := 0                          # ms the meter was last brought up to date
var _sup_ms := -100000                   # ms of the last suppressing event
var _sup_pinned := false
var _sup_nerve := -1.0                   # trait: × every gain (0.75..1.25, rolled on first use)
var _sup_flinch_ms := -100000


## 0..1: how suppressed this bot is right now (the body language reads it).
func suppression() -> float:
	return _sup_level()


## Pinned down (AI_SUP_PIN in, AI_SUP_RELEASE out).
func is_suppressed() -> bool:
	_sup_level()
	return _sup_pinned


## A bullet of another side struck the ground at p (weight w; scripts/war/erosion.gd): dirt in its face.
func sup_impact(p: Vector3, w: float) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	var d := (global_position + _up() * 1.0).distance_to(p)
	if d < Balance.AI_SUP_IMPACT_R:
		_sup_add(Balance.AI_SUP_IMPACT * minf(w, 2.0) * (1.0 - 0.5 * d / Balance.AI_SUP_IMPACT_R))


## The meter brought up to now: drains at AI_SUP_DECAY_FIRE until AI_SUP_HOLD s after the last
## event, at AI_SUP_DECAY after that.
func _sup_level() -> float:
	var now := _now()
	if _sup > 0.0:
		var span := float(now - _sup_t) * 0.001
		var fire := clampf(float(_sup_ms - _sup_t) * 0.001 + Balance.AI_SUP_HOLD, 0.0, span)
		_sup = maxf(_sup - fire * Balance.AI_SUP_DECAY_FIRE - (span - fire) * Balance.AI_SUP_DECAY, 0.0)
	_sup_t = now
	if _sup_pinned and _sup < Balance.AI_SUP_RELEASE:
		_sup_pinned = false
	return _sup


func _sup_add(amount: float) -> void:
	if amount <= 0.0 or mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	if _sup_nerve < 0.0:
		_sup_nerve = _rng.randf_range(0.75, 1.25)
	var was := _sup_pinned
	_sup = minf(_sup_level() + amount * _sup_nerve, 1.0)
	_sup_ms = _now()
	if _sup >= Balance.AI_SUP_PIN:
		_sup_pinned = true
	if _sup_pinned and not was:
		_sup_on_pinned()
	elif _sup_pinned and _tac == Tac.COVER and _peek and _peek_t > 0.25:
		_peek_t = 0.15                       # a crack while peeking: duck back now


## The pin edge: drop any forward move (re-decide next frame through _sup_decide), duck a peek.
func _sup_on_pinned() -> void:
	_radio_call("pinned")                    # (radio_fx.gd maps the key; unknown keys are dropped)
	if mode != Mode.COMBAT or _wx_throwing:
		return
	match _tac:
		Tac.ADVANCE, Tac.FLANK, Tac.SUPPRESS, Tac.HUNT, Tac.STRAFE, Tac.HOLD, Tac.NONE:
			_tac = Tac.NONE
			_tac_t = 0.0
			_move_to = Vector3.INF
			_strafe = Vector3.ZERO
			_peek = false
			_think_acc = 1.0
		Tac.COVER:
			_peek = false
			_crouch = true
			_peek_t = maxf(_peek_t, _rng.randf_range(0.8, 1.8) * Balance.AI_SUP_HIDE)
			_tac_t = maxf(_tac_t, 3.0)


## Every round of another side passing within AI_SUP_NEAR_R (miss_d: its distance from the chest).
func _sup_near_miss(dir: Vector3, miss_d: float) -> void:
	if miss_d > Balance.AI_SUP_NEAR_R:
		return
	_sup_add(Balance.AI_SUP_NEAR_MISS * (1.0 - 0.5 * miss_d / Balance.AI_SUP_NEAR_R))
	if miss_d < Balance.AI_SUP_FLINCH_R:
		_sup_flinch(dir)


## A crack right past it: no aim for a moment, and a small twitch away from it (near LOD).
func _sup_flinch(dir: Vector3) -> void:
	var now := _now()
	if now - _sup_flinch_ms < 400 or mode == Mode.DEAD or mode == Mode.ABOARD or _hr_busy():
		return
	_sup_flinch_ms = now
	_flinch = maxf(_flinch, Balance.AI_SUP_FLINCH)
	if lod == 0 and astronaut != null:
		astronaut.apply_hit(dir, 0.14)


func _sup_blast(d: float, radius: float) -> void:
	var r := maxf(radius, 1.0) * 3.0
	if d < r:
		_sup_add(Balance.AI_SUP_BLAST * (1.0 - d / r))


## Hit chance factor: × 1 calm, down to AI_SUP_ACC_RATTLED just under the pin, AI_SUP_ACC_PIN at the
## pin and AI_SUP_ACC at a full meter.
func _sup_acc() -> float:
	if _sup <= 0.0:
		return 1.0
	var s := _sup_level()
	if _sup_pinned:
		return lerpf(Balance.AI_SUP_ACC_PIN, Balance.AI_SUP_ACC, clampf((s - Balance.AI_SUP_PIN) / (1.0 - Balance.AI_SUP_PIN), 0.0, 1.0))
	return lerpf(1.0, Balance.AI_SUP_ACC_RATTLED, clampf(s / Balance.AI_SUP_PIN, 0.0, 1.0))


## Miss spread factor: up to AI_SUP_SPREAD at a full meter.
func _sup_spread() -> float:
	if _sup <= 0.0:
		return 1.0
	return 1.0 + (Balance.AI_SUP_SPREAD - 1.0) * _sup_level()


## Peek / hide time factor in cover (pinned: short peeks, long hides).
func _sup_peek_k(peek: bool) -> float:
	if not is_suppressed():
		return 1.0
	return Balance.AI_SUP_PEEK if peek else Balance.AI_SUP_HIDE


## Pinned: the tactic instead of _decide's own (false: not pinned, or a grenade wind-up, which the
## pressure choice holds still).
func _sup_decide(threat: Vector3) -> bool:
	if not is_suppressed() or _wx_throwing:
		return false
	var up := _up()
	_strafe = Vector3.ZERO
	if _covered(threat, global_position + up * (EYE_H - CROUCH_DROP)):
		# Ducking right here hides it: hold this spot as cover, crouched.
		_cover_pos = global_position
		_tac = Tac.COVER
		_tac_t = _rng.randf_range(3.0, 6.0)
		_move_to = Vector3.INF
		_crouch = true
		_peek = false
		_peek_t = _rng.randf_range(0.8, 1.8) * Balance.AI_SUP_HIDE
		return true
	if _cover_pos != Vector3.INF and _cover_pos.distance_to(global_position) < 16.0 \
			and _covered(threat, _cover_pos + up * (EYE_H - CROUCH_DROP)):
		_tac = Tac.TO_COVER
		_tac_t = 5.0
		return true
	if _ci_entrench(threat):                 # sometimes a berm right here instead (Cave-ins and entrench, end of file)
		return true
	# Exposed, no cover at hand: fall back away from him (FLEE runs to the cover the search finds).
	var to_t := threat - global_position
	var away := -(to_t - up * to_t.dot(up))
	away = away.normalized() if away.length_squared() > 1e-4 else global_transform.basis.z
	_cover_pos = Vector3.INF
	if lod == 0 and _cover_search.is_empty():
		_request_cover(threat, true)
	_tac = Tac.FLEE
	_tac_t = Balance.AI_SUP_FALLBACK
	_move_to = global_position + away * 8.0
	_move_speed = Balance.AI_RUN_SPEED
	return true


# =================================================================================================
# Drop-pod raids (the team side: rival_team.gd "Drop-pod raids"; the pod: scripts/war/drop_pod.gd;
# constants: balance.gd "Çıkarma kapsülü")
# =================================================================================================
# Hooks above (one line each): _think_work -> _pod_think (after a weapon task, before the foothold
# and role work); _step_solve -> _pod_aim_error for a pod solve; _think_combat: a crew member on
# site never flees; _raid_on_site's `solo` counts the pod crews (team.raid_crew_size);
# _nearest_enemy_structure also knows our Silahlık and auto-miners.
# Phases (`_pod_phase`; the team reads pod_phase()):
#   "gunner"  an engineer lays its claimed cannon at the landing spot with the cannon solver
#             (_start_solve marked "pod": POD_AIM_ERROR_K of the team's aim error), waits for the
#             crew (team.pod_crew_ready) and fires along the barrel (team.pod_launch); no solution:
#             the cannon is skipped for 25 s and the muster called off (team.pod_abort)
#   "muster"  runs to the cannon and climbs in within POD_BOARD_DIST of it (_board: hidden, aboard)
#   "aboard"  in the cannon; "flight": riding the pod (_tick_aboard follows it; pod_die when it is
#             destroyed: the corpse tumbles out of the burst)
#   "site"    out on our planet (pod_exit / _pod_place: the spawn path, the node moved once onto
#             _true_ground so _sync_from_node restarts the sim and the interpolation there; a hop out
#             of the door, a run clear of the pod): callsign "Rakip — Akıncı"; the raid site
#             behaviour (_pod_site -> _raid_on_site: our structures in RAID_STRUCT_RANGE, the first
#             crew member digs the shaft when calm) and, with nothing in reach, it walks at the
#             player on the planet (POD_SEEK_RANGE); combat as usual (pressure, hunt) but never
#             flees, until it dies (respawn at the base, the role's callsign back).

var _pod_phase := ""
var _pod_cannon = null                   # gunner / crew: the cannon (untyped: may be freed)
var _pod_land := Vector3.INF             # gunner: the landing spot
var _pod_tag := false                    # the callsign shows "Akıncı" (the role's comes back later)
var _pod_clear_ms := 0                   # ms: running clear of the pod until then


func pod_phase() -> String:
	return _pod_phase


## The team makes this engineer the pod's gunner (the cannon is claimed, the landing spot picked).
func pod_assign_gunner(c: Node3D, land: Vector3) -> void:
	_pod_phase = "gunner"
	_pod_cannon = c
	_pod_land = land
	if mode == Mode.WORK:
		_set_job("pod_fire")
	_think_acc = 1.0


## The team puts this bot in a pod's crew: it musters at cannon c.
func pod_assign_crew(c: Node3D) -> void:
	_pod_phase = "muster"
	_pod_cannon = c
	if mode == Mode.WORK:
		_set_job("pod_muster")
	_think_acc = 1.0


## Off pod duty (fired, called off, died).
func pod_clear() -> void:
	_pod_phase = ""
	_pod_cannon = null
	_pod_land = Vector3.INF
	if mode == Mode.WORK and _job.begins_with("pod_"):
		_set_job("")


## Called off while mustering: out of the cannon (beside it) if it had climbed in; back to work.
func pod_unboard() -> void:
	var c = _pod_cannon
	pod_clear()
	if mode != Mode.ABOARD:
		return
	var p := global_position
	var up := _up()
	var out := global_transform.basis.x
	if c != null and is_instance_valid(c):
		p = (c as Node3D).global_position
		up = body.up_at(p)
		var x := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		out = x.rotated(up, _rng.randf() * TAU)
	_pod_place(p + out * (Balance.CANNON_FOOTPRINT + 1.5), out, 0.0)


## The pod is fired: this crew member rides it (aboard, hidden, following it).
func pod_ride(pod: Node3D) -> void:
	if mode != Mode.ABOARD:
		_board(pod)
	aboard = pod
	_pod_phase = "flight"


## The doors are off: out it jumps, slot k of n around the pod, and runs clear; a raider from now.
func pod_exit(pos: Vector3, up: Vector3, k: int, n: int) -> void:
	if mode != Mode.ABOARD:
		return
	var x := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var out := x.rotated(up, TAU * float(k) / float(maxi(n, 1)) + _rng.randf_range(-0.3, 0.3))
	_pod_place(pos + out * 1.5 + up * 0.3, out, _rng.randf_range(2.2, 3.4))
	_pod_phase = "site"
	_pod_cannon = null
	_pod_tag = true
	callsign = "Rakip — Akıncı"
	_col.set_meta("callsign", callsign)
	_set_held("rifle")
	_move_to = pos + out * 5.0
	_move_speed = Balance.AI_RUN_SPEED
	_pod_clear_ms = _now() + 1200


## The pod was destroyed with this crew member aboard.
func pod_die(v: Vector3) -> void:
	if mode != Mode.ABOARD:
		return
	mode = Mode.WORK
	visible = true
	aboard = null
	velocity = v
	_die(Vector3.ZERO)


## Out of the cannon / pod at p, facing out_dir: visible, collidable, on the real ground
## (_true_ground). The node is moved once, the spawn path: _sync_from_node restarts the sim and the
## render interpolation there. hop: m/s up (a jump out of the door).
func _pod_place(p: Vector3, out_dir: Vector3, hop: float) -> void:
	aboard = null
	mode = Mode.WORK
	visible = true
	_cap_cs.disabled = false
	var nb: Node3D = Game.dominant_body(p)
	if nb != null:
		body = nb
	var up: Vector3 = body.up_at(p)
	var g := _true_ground(p, up, 2.5, 6.0)
	if g == Vector3.INF or g == Vector3(-INF, -INF, -INF):
		g = _ground_at(p)
	var f := out_dir - up * out_dir.dot(up)
	if f.length_squared() < 1e-4:
		f = up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD)
	f = f.normalized()
	var x := up.cross(-f).normalized()       # (the sim's own basis: -z = facing)
	global_transform = Transform3D(Basis(x, up, x.cross(up)), g + up * 0.05)
	_vis_pos = global_position
	_face = f
	_air = true
	_vy = hop
	_climb = false
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_job = ""
	_think_acc = 1.0


## From _think_work: the pod duty; false lets the normal work run.
func _pod_think() -> bool:
	if _pod_phase == "":
		if _pod_tag:                          # back from the dead: the role's callsign again
			_pod_tag = false
			var r := role
			role = -1
			set_role(r)
		return false
	match _pod_phase:
		"gunner":
			return _pod_think_gunner()
		"muster":
			return _pod_think_muster()
		"site":
			_pod_site()
	return true


## Lays the claimed cannon at the landing spot (the cannon solver), fires when the crew is in.
func _pod_think_gunner() -> bool:
	var t = team_node
	var c = _pod_cannon
	if c == null or not is_instance_valid(c) or c.is_destroyed:
		t.pod_abort()
		return true
	if _job != "pod_fire":
		_set_job("pod_fire")                  # (re)entering, e.g. after a fight: solve again
	_set_held("terrain")
	var cb: Basis = c.global_transform.basis * Basis(Vector3.UP, float(c.yaw))
	var stand: Vector3 = c.global_position + cb * Vector3(0, 0, 3.4)
	if not _walk_to(stand, Balance.AI_WALK_SPEED):
		return true
	_face = -cb.z
	if not _solved and _solve.is_empty():
		_start_solve(c.muzzle_position(), _pod_land)
		_solve["pod"] = true
		return true
	if not _solve.is_empty():
		return true
	if _solved_v == Vector3.ZERO:
		c.set_meta("ai_skip_until", _now() + 25000)
		t.pod_abort()
		return true
	c.aim_dir(_solved_v.normalized(), _solved_v.length())
	if not c.aligned() or not c.ready_to_fire() or not t.pod_crew_ready():
		return true
	if t.pod_launch(self, c, c.barrel_dir() * float(c.speed())):
		_fire_vis = 0.3
	return true


## Runs to the cannon and climbs in.
func _pod_think_muster() -> bool:
	var c = _pod_cannon
	if c == null or not is_instance_valid(c) or c.is_destroyed:
		return false                          # (the team calls it off)
	if _job != "pod_muster":
		_set_job("pod_muster")
	_set_held("rifle")
	var cp: Vector3 = (c as Node3D).global_position
	var up := _up()
	var off := global_position - cp
	off -= up * off.dot(up)
	var d := off.length()
	if d < Balance.POD_BOARD_DIST:
		_board(c)
		_pod_phase = "aboard"
		return true
	_walk_to(cp + off / maxf(d, 0.01) * (Balance.POD_BOARD_DIST - 1.5), Balance.AI_RUN_SPEED)
	return true


## On our planet: the raid site behaviour; with nothing to attack in reach and no digging to do it
## goes for the player.
func _pod_site() -> void:
	if _now() < _pod_clear_ms:
		return                                # running clear of the pod first
	var t = team_node
	if t.home != null and body != t.home:
		t.pod_release(self)                   # came down off target: back to normal duty
		return
	if t.raid_digger() != self and _cp_raid():      # Bölge kontrolü: take our nearest zone first (end of file)
		return
	if t.raid_digger() == self or _nearest_enemy_structure(Balance.RAID_STRUCT_RANGE) != null:
		_raid_on_site()
		return
	var pl = _pick_player()
	if pl != null and is_instance_valid(pl) and not pl.is_dead() and pl.get("vehicle") == null \
			and Game.dominant_body((pl as Node3D).global_position) == body \
			and (pl as Node3D).global_position.distance_to(global_position) < Balance.POD_SEEK_RANGE:
		if _job != "raid_guard":
			_set_job("raid_guard")
		_set_held("rifle")
		_walk_to((pl as Node3D).global_position, Balance.AI_WALK_SPEED)
		return
	_raid_on_site()


## _apply_error with POD_AIM_ERROR_K of the team's aim error (a pod also steers in, drop_pod.gd).
func _pod_aim_error(v: Vector3) -> Vector3:
	var err: float = float(team_node.aim_err) * Balance.POD_AIM_ERROR_K if team_node != null else 0.0
	var axis := v.normalized().cross(Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1))).normalized()
	if axis.length_squared() < 0.5:
		axis = v.normalized().cross(Vector3.UP).normalized()
	if axis.length_squared() < 0.5:
		return v
	var ang := deg_to_rad(err) * _rng.randf_range(-1.0, 1.0)
	var spd := v.length() * (1.0 + _rng.randf_range(-1.0, 1.0) * Balance.AI_SPEED_ERROR * err / Balance.AI_AIM_ERROR_START)
	return v.normalized().rotated(axis, ang) * spd


# =================================================================================================
# Corpses and loot (scripts/war/corpse.gd, scripts/war/loot.gd; tunables: balance.gd "Corpses and loot")
# =================================================================================================
# Hooks above (one line each): _die -> _lt_on_death (what it carried drops at the death spot as a
# pickup, out of the team pool), _tick_dead -> _lt_leave_corpse (at the respawn the body stays where it
# fell: corpse.gd takes over a ragdoll still moving, else copies the pose; the astronaut resets as
# before). rival_team.gd _income -> _lt_carry credits each digging bot's share of the income through
# lt_add_carry; loot.gd hands a pickup a bot walked over to lt_pickup. The bots only exist on the host /
# in single player, so every drop here is the host's (Loot.events() carries it to a client).

const LtCorpse := preload("res://scripts/war/corpse.gd")
const LtLoot := preload("res://scripts/war/loot.gd")

var lt_carried := 0.0                  # m³ dug (its share of the income) or picked up since the respawn


func lt_add_carry(d: float) -> void:
	lt_carried = minf(lt_carried + d, Balance.LOOT_CARRY_MAX)


## loot.gd: it walked over a pickup on its planet: into the pool, and it carries it.
func lt_pickup(d: float) -> void:
	if team_node != null:
		team_node.add_material(d)
	lt_add_carry(d)


## _die: LOOT_MIN..LOOT_CARRY_MAX m³ out of the team pool (no longer theirs) pop out of the body.
func _lt_on_death() -> void:
	var amt := clampf(lt_carried, Balance.LOOT_MIN, Balance.LOOT_CARRY_MAX)
	lt_carried = 0.0
	if Net.is_client() or team == "home":    # (an ally bot carries nothing: "Ally bots" below)
		return
	if team_node != null:
		team_node.add_material(-minf(amt, float(team_node.material)))
	var up := _up()
	var side := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1))
	side = (side - up * side.dot(up)).limit_length(1.0) * 0.8
	LtLoot.drop(global_position + up * 1.0, amt, velocity * 0.3 + up * 2.2 + side)


## _tick_dead at the respawn: a corpse.gd where it lies (null: it took the still moving ragdoll over).
func _lt_leave_corpse() -> void:
	_ragdoll = LtCorpse.leave(astronaut, _ragdoll, team, "bot")


# =================================================================================================
# Ally bots (single player: scripts/war/ally_team.gd; tunables: balance.gd "Ally bots", ALLY_*)
# =================================================================================================
# The same bot with team = "home" fights FOR the player on our planet; ally_team.gd is its team_node
# (rival_team.gd's duck-typed API, mostly no-ops). Hooks above (one line each; inert for the rival's
# bots while no ally exists): _ready / _tick_dead -> _al_home_body (our planet for an ally);
# _visual_lod_setup / _build_rifle_prop / set_role: the "DOST" chest tag, a white rifle, the
# "Dost — Muhafız" callsign and _al_role_color; _pick_player -> null for an ally (it never targets a
# player, so a blast's source is never pinned on him either); _perceive -> _al_perceive first;
# wants_to_shoot and the player-sight retarget know a bot target (_al_is_bot); _shoot_update: a bot
# target takes AI_RIFLE_DAMAGE; _on_threat / help_call ignore our player's own hits / scope glint on
# an ally (_al_friendly_src); _think_work -> _al_think_work; _die / _lt_on_death: an ally drops no
# rifle and no loot.
#   Sight: an ally looks for the rival's bots on its planet (AI_SIGHT_RANGE, the same view-cone rule
#   as for the player, one line-of-sight test per think on its team's budget); a rival bot also looks
#   for allies (group "war_ally") while the player is not its visible target (he takes priority
#   again as soon as it sees him). The fight is the normal combat AI (cover, slides, jumps, hit
#   reactions); bot-vs-bot fire needs no shooter token.
#   Work: al_follow (the F command, ally_team.gd; the Muhafız starts with it): at the player's side
#   while he is alive, on foot and on our planet within ALLY_FOLLOW_RANGE of the base. Otherwise the
#   Muhafız guards (_work_guard: the base and our structures, team.cannons / team.flaks) and the
#   Kazıcı digs its own pits ALLY_DIG_MIN..MAX m out (_think_gather on a site from _al_dig_site; the
#   team credits the player's material while it digs).

var al_follow := false                   # the F command (ally_team.gd): stay with the player


## Where this bot belongs: the rival's planet, our planet for an ally.
func _al_home_body() -> Node3D:
	return Game.planet if team == "home" else Game.rival


## A bot of this AI, either team (not a training dummy or a multiplayer puppet).
func _al_is_bot(n) -> bool:
	return n != null and is_instance_valid(n) and n is Node3D and (n as Node).is_in_group("war_ai") \
			and (n as Node).has_method("pod_phase")


## An ally's role light (chest strip, helmet lamp): cyan Muhafız, green Kazıcı.
func _al_role_color(r: int) -> Color:
	return Color(0.35, 0.95, 0.55) if r == ROLE_MINER else Color(0.3, 0.8, 1.0)


## The threat came from our own player (his hit, shove or scope glint on an ally): no fight with him.
func _al_friendly_src(src: Vector3) -> bool:
	if team != "home" or src == Vector3.INF or src == Vector3.ZERO:
		return false
	var pl = Game.player
	return pl != null and is_instance_valid(pl) and src.distance_to((pl as Node3D).global_position) < 3.5


## _perceive's first step (see the header). True: done (an ally never looks for players).
func _al_perceive(_dt: float) -> bool:
	var ally := team == "home"
	if not ally and get_tree().get_first_node_in_group("war_ally") == null:
		return false
	if _al_is_bot(_target) and (_target.is_dead() or _target.is_aboard()):
		_target = null
		_target_visible = false
	if not ally and _is_player(_target) and _target_visible:
		return false                         # (busy with the player: his part of _perceive)
	var me := _eye()
	var best: Node3D = null
	var best_d := Balance.AI_SIGHT_RANGE
	for n in get_tree().get_nodes_in_group("war_ai" if ally else "war_ally"):
		if n == self or not _al_is_bot(n) or str(n.get("team")) == team or n.is_dead() or n.is_aboard() or _dn_skip_target(n):
			continue
		var c: Vector3 = (n as Node3D).global_position + (n as Node3D).global_transform.basis.y * 1.2
		var d := me.distance_to(c)
		if d < best_d and Game.dominant_body(c) == body:
			best_d = d
			best = n as Node3D
	var vis := false
	var chest := Vector3.INF
	if best != null:
		chest = best.global_position + best.global_transform.basis.y * 1.2
		var ang := _face.angle_to(chest - me) if _face != Vector3.ZERO else 0.0
		if best_d < Balance.AI_PREFERRED_RANGE or ang < deg_to_rad(75.0) or mode == Mode.COMBAT:
			vis = _los_clear(me, chest)
	if vis:
		if _target == null or not is_instance_valid(_target) or _al_is_bot(_target) \
				or _target.is_in_group("war_structure") or (_is_player(_target) and not _target_visible):
			_target = best
		if _target == best:
			_target_visible = true
			_bl_spot(best, chest)            # a new sighting (Reactions and body language, end of file)
			_seen_ms = _now()
			_threat_pos = chest
			if mode == Mode.WORK:
				_enter_combat(chest)
	elif _al_is_bot(_target):
		_target_visible = false
		if mode == Mode.WORK:
			_target = null
	return ally


## _think_work for an ally (always true: the rival's role work never runs for it).
func _al_think_work() -> bool:
	if al_follow and _al_follow_ok():
		_al_follow_player()
	elif role == ROLE_MINER:
		_al_work_miner()
	else:
		_work_guard()
	return true


## The player is alive, on foot and on our planet within ALLY_FOLLOW_RANGE of the base.
func _al_follow_ok() -> bool:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.get("vehicle") != null:
		return false
	var p: Vector3 = (pl as Node3D).global_position
	var bx: Transform3D = team_node.base_xf
	return Game.dominant_body(p) == body and p.distance_to(bx.origin) < Balance.ALLY_FOLLOW_RANGE


## Loosely at his side: catches up beyond ALLY_FOLLOW_FAR (running when far) to ~ALLY_FOLLOW_DIST on
## its side and a little behind him, steps aside when he comes too close, else watches outward.
func _al_follow_player() -> void:
	if _job != "al_follow":
		_set_job("al_follow")
		_guard_wait = 0.0
	_set_held("rifle")
	var pl: Node3D = Game.player
	var pp := pl.global_position
	var up: Vector3 = body.up_at(pp)
	var off := global_position - pp
	off -= up * off.dot(up)
	var d := off.length()
	var look := -pl.global_transform.basis.z
	look -= up * look.dot(up)
	look = look.normalized() if look.length_squared() > 1e-4 else up.cross(Vector3.RIGHT).normalized()
	var side := off / d if d > 0.1 else -look
	# Never in front of him (it stood in his view while he drilled or aimed): its spot is on its own
	# side of his view, a little behind; from in front it walks round to it.
	var in_front := side.dot(look) > 0.3
	if in_front:
		var lat := side - look * side.dot(look)
		side = lat.normalized() if lat.length_squared() > 1e-4 else up.cross(look).normalized()
	if in_front or d > Balance.ALLY_FOLLOW_FAR or (_move_to != Vector3.INF and d > Balance.ALLY_FOLLOW_DIST + 1.0):
		var dir := side - look * 0.5
		dir = dir.normalized() if dir.length_squared() > 1e-4 else side
		var spd := Balance.AI_RUN_SPEED if d > 18.0 else Balance.AI_WALK_SPEED
		_walk_to(_ground_at(pp + dir * Balance.ALLY_FOLLOW_DIST + up * 2.0), spd)
		return
	if d < Balance.ALLY_CAM_CLEAR + 0.6:
		# Too close to him (his camera): back off to the side, never in front of him.
		var away := side - look * maxf(side.dot(look), 0.0)
		away = away.normalized() if away.length_squared() > 1e-4 else up.cross(look).normalized()
		_walk_to(_ground_at(pp + away * (Balance.ALLY_FOLLOW_DIST - 1.0) + up * 2.0), Balance.AI_WALK_SPEED)
		return
	_move_to = Vector3.INF
	_guard_wait -= float(THINK_WORK[lod])
	if _guard_wait <= 0.0:
		_guard_wait = _rng.randf_range(2.0, 4.5)
		_face = look.rotated(up, _rng.randf_range(-1.1, 1.1))


## The Kazıcı: its own pits away from the base (the team pays the player while it digs).
func _al_work_miner() -> void:
	_set_held("terrain")
	if _dig_site == Vector3.INF or _dig_t > 13.0:      # (before _think_gather would pick a rival's spot)
		_dig_site = _al_dig_site()
		_dig_t = 0.0
		_stop_dig()
	_think_gather()


## A pit ALLY_DIG_MIN..MAX m from the base, clear of our structures (footprint + 5 m) and the player.
func _al_dig_site() -> Vector3:
	var pl = Game.player
	for i in 8:
		var p: Vector3 = team_node.around_base(_rng.randf_range(Balance.ALLY_DIG_MIN, Balance.ALLY_DIG_MAX), _rng.randf() * TAU)
		var ok: bool = pl == null or not is_instance_valid(pl) or (pl as Node3D).global_position.distance_to(p) > 7.0
		if ok:
			for s in get_tree().get_nodes_in_group("war_structure"):
				if s is Node3D and (s as Node3D).global_position.distance_to(p) < float(s.get_meta("footprint_r", 3.0)) + 5.0:
					ok = false
					break
		if ok:
			return _ground_at(p + _up_of(p) * 3.0)
	var q: Vector3 = team_node.around_base(Balance.ALLY_DIG_MAX, _rng.randf() * TAU)
	return _ground_at(q + _up_of(q) * 3.0)


# =================================================================================================
# Digging tactics and the rival's base (2026-10-05; the team side: the same section at the end of
# rival_team.gd; constants: balance.gd "Digging tactics and the rival's base")
# =================================================================================================
# Hooks above (one line each): _think_work -> _dg_think_task (a dig task before the role's work);
# _dig_shaft -> _dg_dig_tick (the task's brush instead of the shaft); _think_combat -> _dg_combat
# (foxhole, escape pit, shelter, digging out); wx_available: not while on a dig task; _raid_on_site
# -> _dg_raid_site (the enemy core shield, doors); _tick -> _dg_block (bots have no physics against
# structures: a closed enemy Zırhlı Kapı stops it, enemy walls / Sığınak Modülü turn it along their
# face); _nearest_enemy_structure -> _dg_struct_rank (turrets and the core shield first, an
# underground one only from near it); _pick_build_spot -> _bk_pick_spot (base pieces:
# BaseKit.suggest_spot).
# Every brush is Dig.dig_at with the team (host only, synced, logged for the Tünel tarayıcı) and takes
# the team's carve tokens (DG_CARVE_PER_MIN); digging out never waits for them. Tasks (_dg_task; the
# team gives them with dg_assign, the combat ones start here):
#   sapper   (a raider on our planet, the raid's digger) a tunnel from its landing spot: a ramp down to
#            DG_SAP_DEPTH, under the ground beside our cannon / Uçaksavar / turret and up behind it
#            ("popup": then it attacks it), or to under our base ("core": then the raid digger's shaft
#            to the core). DG_SAP_STEP m every DG_SAP_STEP_T s, walking the tunnel floor behind the
#            face; the HUD's "Rakip kazıyor" gives its distance to our core. Off the raid: it stops.
#   trench   (a guard) DG_TRENCH_SEGS pits in a line in front of a cannon, one slow brush at a time
#   ambush   (a guard) a pit off a path the player walked, waits crouched in it, peeking (DG_AMBUSH_WAIT)
#   bunker   (the engineer, no Sığınak Modülü yet) a ramp down to a room under ~1 m of soil by the
#            cannons, a firing slit toward our planet, a Işık Direği inside
#   shield   (the engineer) a shaft down beside its core to the chamber BaseKit.suggest_spot gives,
#            BaseKit.carve_for the room, BaseKit.spawn the Çekirdek Kalkanı (+ a light), climbs out
#   counter  (the engineer / a guard) the enemy digs toward their core: a tunnel to his tunnel's head;
#            meeting him it fights (the normal combat); the digger gone (DG_COUNTER_STALE), it rolls a
#            grenade into his tunnel and caves it in (the team fills it)
#   fox      (combat, no cover) a DG_FOX_DEPTH pit at its feet, then the normal cover tactic in it
#   escape   (combat, low hp, no cover) a DG_ESCAPE_DEPTH pit, crouched in it until healed
#   shelter  (shelling: an enemy blast near, nobody in sight) into the team's Sığınak Modülü or dug
#            bunker, crouched until the shelling stops
#   exit     dug in under soil (or stuck DG_STUCK_T s underground: the team checks): a ramp up to the
#            surface, out of an open pit / shaft the normal jet climb; lifted out after DG_EXIT_TIME

const DgKit := preload("res://scripts/war/base_kit.gd")

var _dg_task := ""
var _dg_phase := ""
var _dg_data := {}
var _dg_dig := ""                      # what _dg_dig_tick carves: "", "tunnel", "pit", "shaft"
var _dg_path: Array = []               # tunnel floor points (world)
var _dg_i := 0                         # the next one to carve
var _dg_acc := 0.0
var _dg_t0 := 0                        # ms: task start
var _dg_t1 := 0                        # ms: phase start
var _dg_prog_ms := 0                   # ms: last progress (stuck)
var _dg_fox_ms := -100000
var _dg_esc_ms := -100000
var _dg_door: Node3D = null            # a closed enemy door in its way (_dg_block)
var _dg_door_ms := -100000


# --- Team interface ------------------------------------------------------------------------------------

func dg_task() -> String:
	return _dg_task


## Free for a dig task: working, no weapon / dig / pod task, not on a raid, not building.
func dg_free() -> bool:
	return _dg_task == "" and wx_available() and _pod_phase == "" and not _pod_tag and foothold == null \
			and team_node != null and not team_node.is_raiding(self)


## Free for a fight-time dig task (flank, counter, a crew member's sapper): dg_free, or in a fight while
## it cannot see the player; a landed pod crew member too (not the shaft digger).
func dg_free_fight() -> bool:
	if _dg_task != "" or _wx_task != "" or _wx_throwing or foothold != null or team_node == null or _hr_busy():
		return false
	if (_pod_phase != "" and _pod_phase != "site") or (_pod_phase == "" and team_node.is_raiding(self)):
		return false
	if team_node.raid_digger() == self or hp < hp_max * Balance.DG_FLANK_MIN_HP or _job in ["build", "fire", "repair"]:
		return false
	if mode == Mode.WORK:
		return true
	return mode == Mode.COMBAT and not _target_visible and _now() - _threat_ms > 2500 and _tac != Tac.FLEE


## The team's order while flankers come out behind him: pin him from here for t s (a fighter that
## sees him and may fire). The SUPPRESS tactic itself is the "Pressure" section's.
func dg_suppress(t: float) -> bool:
	if mode != Mode.COMBAT or not _target_visible or not _is_player(_target) or not tok_shoot or _reload_t > 0.0 \
			or _dg_task != "" or _wx_throwing or _hr_busy():
		return false
	_tac = Tac.SUPPRESS
	_tac_t = t
	_pr_until = _now() + int(t * 1000.0)
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_crouch = false
	_peek = true
	return true


func dg_assign(kind: String, data := {}) -> void:
	_dg_task = kind
	_dg_data = data
	_dg_phase = ""
	_dg_dig = ""
	_dg_path = []
	_dg_i = 0
	_dg_acc = 0.0
	_dg_t0 = _now()
	_dg_t1 = _dg_t0
	_dg_prog_ms = _dg_t0
	if mode == Mode.WORK:
		_set_job("dg_" + kind)
	_think_acc = 1.0


func dg_clear() -> void:
	if _dg_task == "":
		return
	_dg_task = ""
	_dg_data = {}
	_dg_phase = ""
	_dg_dig = ""
	_dg_path = []
	_crouch = false
	if _job.begins_with("dg_"):
		_set_job("")
	else:
		_stop_dig()


## The counter-tunneller's target: the enemy tunnel's head (the team, every scan); fresh = a new dig.
func dg_set_head(p: Vector3, fresh: bool) -> void:
	if _dg_task != "counter":
		return
	if fresh:
		_dg_data["fresh_ms"] = _now()
	var old: Vector3 = _dg_data.get("head", Vector3.INF)
	_dg_data["head"] = p
	if old == Vector3.INF or old.distance_to(p) > 2.0:
		_dg_data["replan"] = true


## The team's 1 Hz check: stuck underground while trying to move -> dig out.
func dg_check_trapped() -> void:
	if (mode != Mode.WORK and mode != Mode.COMBAT) or _dg_task != "" or _wx_task != "" or _climb or _air:
		return
	if _still_t < Balance.DG_STUCK_T or (_move_to == Vector3.INF and _strafe == Vector3.ZERO):
		return
	if _dg_buried():
		dg_assign("exit")


# --- Helpers ----------------------------------------------------------------------------------------

## Under soil (a tunnel / room) or deep in a hole it cannot hop out of.
func _dg_buried() -> bool:
	var up := _up()
	return DgKit.cover_above(body, global_position + up * 0.5, up, 8.0) < 8.0 or _wx_depth() > 3.4


func _dg_flat(v: Vector3, up: Vector3) -> Vector3:
	return v - up * v.dot(up)


## The untouched surface radius under a direction (body-local unit dir).
func _dg_surf_r(dir: Vector3) -> float:
	return float(body.radius) + float(body.surface_height_at(body.global_position + dir * float(body.radius)))


## Ends the task; under soil it digs itself out first.
func _dg_done() -> void:
	var was := _dg_task
	dg_clear()
	if was != "exit" and mode != Mode.DEAD and mode != Mode.ABOARD and _dg_buried():
		dg_assign("exit")


func _dg_dig_on(kind: String) -> void:
	_dg_dig = kind
	_set_held("terrain")
	if not _digging:
		_digging = true
		_shaft = true
		_dig_acc = 0.0
		_play(_dig_audio)


func _dg_dig_off() -> void:
	_dg_dig = ""
	_stop_dig()


func _dg_take(n: int) -> bool:
	return team_node != null and team_node.has_method("dg_take") and team_node.dg_take(n)   # (ally_team.gd: none)


# --- Per think ---------------------------------------------------------------------------------------

## From _think_work: runs the dig task; false lets the role's own work run this think.
func _dg_think_task() -> bool:
	if team_node == null or team == "home":
		dg_clear()
		return false
	if not _job.begins_with("dg_") and _dg_phase != "attack":
		_set_job("dg_" + _dg_task)            # (back from a fight: carry on)
		_dg_prog_ms = _now()
	match _dg_task:
		"sapper":
			return _dg_think_sapper()
		"trench":
			return _dg_think_trench()
		"ambush":
			return _dg_think_ambush()
		"bunker":
			return _dg_think_bunker()
		"shield":
			return _dg_think_shield()
		"counter":
			return _dg_think_counter()
		"flank":
			return _dg_think_flank()
		"exit":
			return _dg_think_exit()
		"shelter":
			return _dg_shelter_tick()
		"fox", "escape":
			_dg_done()                        # (the fight is over)
			return false
	dg_clear()
	return false


## From _think_combat (after the threat is known): the combat dig tasks; true = this think is done.
func _dg_combat(_dt: float, threat: Vector3, dist: float, under_fire: bool, low: bool) -> bool:
	if team_node == null or team == "home":
		return false
	match _dg_task:
		"fox":
			return _dg_fox_tick(threat)
		"escape":
			return _dg_escape_tick(threat, dist)
		"shelter":
			return _dg_shelter_tick()
		"exit":
			return _dg_think_exit()
		"flank":
			return _dg_think_flank()           # (it decides itself when to give up for the fight)
		"counter":
			return not _target_visible and _dg_think_counter()
		"sapper":
			return _dg_phase != "attack" and not _target_visible and _dg_think_sapper()
		"":
			pass
		_:
			return false                      # (a work task waits: the fight first)
	if low and _dg_want_escape(threat):
		dg_assign("escape", {"pit": global_position, "depth": Balance.DG_ESCAPE_DEPTH, "r": 1.2, "step_t": 0.35})
		_dg_esc_ms = _now()
		return _dg_escape_tick(threat, dist)
	if not _target_visible and _dg_want_shelter():
		return true
	if _dg_want_fox(threat, dist, under_fire):
		dg_assign("fox", {"pit": global_position, "depth": Balance.DG_FOX_DEPTH, "r": 1.4, "step_t": 0.45})
		_dg_fox_ms = _now()
		return _dg_fox_tick(threat)
	return false


## A fresh covered spot near (the cover search's) or none.
func _dg_has_cover(threat: Vector3) -> bool:
	var up := _up()
	return _cover_pos != Vector3.INF and _cover_pos.distance_to(global_position) < 16.0 \
			and _covered(threat, _cover_pos + up * (EYE_H - CROUCH_DROP))


# --- Foxhole / escape pit ----------------------------------------------------------------------------

func _dg_want_fox(threat: Vector3, dist: float, under_fire: bool) -> bool:
	if lod > 1 or _now() - _dg_fox_ms < int(Balance.DG_FOX_COOLDOWN * 1000.0):
		return false
	if not (_target_visible or under_fire) or dist < Balance.DG_FOX_RANGE_MIN or dist > Balance.DG_FOX_RANGE_MAX:
		return false
	if _tac != Tac.NONE and _tac != Tac.STRAFE and _tac != Tac.HOLD:
		return false
	if not _cover_search.is_empty() or _dg_has_cover(threat) or _wx_depth() > 0.6 or sliding or _air or _hr_busy():
		return false
	if _rng.randf() > Balance.DG_FOX_CHANCE:
		_dg_fox_ms = _now() - int(Balance.DG_FOX_COOLDOWN * 600.0)     # (ask again in a while)
		return false
	return _dg_take(2)


func _dg_want_escape(threat: Vector3) -> bool:
	if lod > 1 or _pod_phase == "site" or _now() - _dg_esc_ms < 60000 or _wx_depth() > 0.6:
		return false
	if _dg_has_cover(threat) or sliding or _air or _hr_busy():
		return false
	if _rng.randf() > Balance.DG_ESCAPE_CHANCE:
		_dg_esc_ms = _now()
		return false
	return _dg_take(3)


## Digs the foxhole (crouched, still), then hands it to the cover tactic: crouch, peek, fire.
func _dg_fox_tick(threat: Vector3) -> bool:
	var up := _up()
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_crouch = true
	var tf := _dg_flat(threat - global_position, up)
	if tf.length_squared() > 0.01:
		_face = tf.normalized()
	if not _dg_pit_done() and _now() - _dg_t0 < 5000:
		_dg_dig_on("pit")
		return true
	_dg_dig_off()
	dg_clear()
	_cover_pos = global_position
	_cover_search = {}
	_set_held("rifle")
	_tac = Tac.COVER
	_tac_t = Balance.DG_FOX_HOLD
	_crouch = true
	_peek = false
	_peek_t = _rng.randf_range(0.5, 1.0)
	return true


## Digs down out of sight, then hides crouched until healed (or found close: it fights).
func _dg_escape_tick(threat: Vector3, dist: float) -> bool:
	var up := _up()
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_crouch = true
	var tf := _dg_flat(threat - global_position, up)
	if tf.length_squared() > 0.01:
		_face = tf.normalized()
	if _dg_phase == "":
		if not _dg_pit_done() and _now() - _dg_t0 < 6000:
			_dg_dig_on("pit")
			return true
		_dg_dig_off()
		_dg_phase = "hide"
		_dg_t1 = _now()
		_set_held("rifle")
	var healed := hp >= hp_max * Balance.DG_ESCAPE_HEAL
	if healed or _now() - _dg_t1 > int(Balance.DG_ESCAPE_TIME * 1000.0) or (_target_visible and dist < 8.0):
		_dg_done()
		return false
	_peek = false
	return true


# --- Shelter from shelling ---------------------------------------------------------------------------

func _dg_want_shelter() -> bool:
	if _dg_task != "" or body != Game.rival or team_node.is_raiding(self) or not team_node.dg_shelling(global_position):
		return false
	var s: Dictionary = team_node.dg_shelter_near(global_position)
	if s.is_empty():
		return false
	dg_assign("shelter", s)
	return _dg_shelter_tick()


## Into the shelter (its entry, then the room), crouched there until DG_SHELTER_TIME s after the
## last blast near it, then out by the entry.
func _dg_shelter_tick() -> bool:
	var entry: Vector3 = _dg_data.get("entry", global_position)
	var room: Vector3 = _dg_data.get("room", entry)
	if _target_visible and _target != null and is_instance_valid(_target) and _target.global_position.distance_to(global_position) < 30.0:
		dg_clear()                             # (an enemy right here: fight)
		return false
	_set_held("rifle")
	match _dg_phase:
		"":
			_dg_phase = "in" if global_position.distance_to(entry) < 3.0 else "go"
			return true
		"go":
			_crouch = false
			if _walk_to(entry, Balance.AI_RUN_SPEED) or _now() - _dg_t0 > 25000:
				_dg_phase = "in"
			return true
		"in":
			if _walk_to(room, Balance.AI_WALK_SPEED) or _now() - _dg_t0 > 35000:
				_dg_phase = "stay"
				_dg_t1 = _now()
			return true
		"stay":
			_crouch = true
			_move_to = Vector3.INF
			if team_node.dg_shelling(room):
				_dg_t1 = _now()
			if _now() - _dg_t1 > int(Balance.DG_SHELTER_TIME * 1000.0) or _now() - _dg_t0 > 90000:
				_dg_phase = "out"
				_crouch = false
			return true
		"out":
			if _walk_to(entry, Balance.AI_WALK_SPEED) or _now() - _dg_t0 > 110000:
				_dg_done()
				return false
			return true
	return false


# --- Digging (from _dig_shaft, AI_DIG_HZ) -----------------------------------------------------------------

func _dg_dig_tick(dt: float) -> bool:
	match _dg_dig:
		"tunnel":
			_dg_tunnel_tick(dt)
		"pit":
			_dg_pit_tick(dt)
		"shaft":
			_dg_shaft_tick(dt)
	return true


## One tunnel step every step_t s at the face (_dg_path[_dg_i]) while the bot stands near it: two
## stacked brushes (twice each where deep: the edit clamp), ~2 m of headroom over the floor point.
func _dg_tunnel_tick(dt: float) -> void:
	if _dg_i >= _dg_path.size():
		return
	var q: Vector3 = _dg_path[_dg_i]
	var up: Vector3 = body.up_at(q)
	_dig_point = q + up * 1.0
	_dig_normal = _dg_flat(global_position - q, up).normalized()
	if global_position.distance_to(q) > 3.2:
		return
	_dg_acc += dt
	if _dg_acc < float(_dg_data.get("step_t", Balance.DG_SAP_STEP_T)):
		return
	if _dg_task != "exit" and not _dg_take(2):
		return
	_dg_acc = 0.0
	_dg_carve(q, up, float(_dg_data.get("r", Balance.DG_TUN_R)))
	_dg_i += 1
	_dg_prog_ms = _now()
	if _dg_task == "sapper" and team_node != null and body == team_node.home:
		team_node.report_dig(q.distance_to(body.global_position) - Balance.CORE_RADIUS)


func _dg_carve(q: Vector3, up: Vector3, r: float) -> void:
	var deep := float(body.radius) + float(body.surface_height_at(q)) - q.distance_to(body.global_position) > 3.0
	for k in (2 if deep else 1):
		for h: float in [0.8, 1.45]:
			Dig.dig_at(body, q + up * h, r, Dig.MODE_DIG, Balance.DG_TUN_AMOUNT, Vector3.ZERO, Vector3.UP, -1.0, team)
	if not _mine_audio.playing and _rng.randf() < 0.4:
		_play(_mine_audio)
	if (_dg_task == "flank" or _dg_task == "sapper" or _dg_task == "counter") and team_node.has_method("dg_tunnel_tell"):
		team_node.dg_tunnel_tell(self, q, _dg_i)   # muffled thumps near a player, dust over the face


## A pit at _dg_data "pit" (where the bot stood): one brush every step_t, deeper each time.
func _dg_pit_tick(dt: float) -> void:
	var top: Vector3 = _dg_data.get("pit", global_position)
	var up: Vector3 = body.up_at(top)
	var depth := float(_dg_data.get("depth", 1.2))
	var n := int(_dg_data.get("dug", 0))
	_dig_point = top - up * minf(0.3 + float(n) * 0.5, maxf(depth - 0.6, 0.3))
	_dig_normal = up
	if _dg_pit_done():
		return
	_dg_acc += dt
	if _dg_acc < float(_dg_data.get("step_t", 0.5)):
		return
	if _dg_task != "fox" and _dg_task != "escape" and not _dg_take(1):
		return                                 # (fox / escape paid up front)
	_dg_acc = 0.0
	Dig.dig_at(body, _dig_point, float(_dg_data.get("r", 1.3)), Dig.MODE_DIG, 2.5, Vector3.ZERO, Vector3.UP, -1.0, team)
	_dg_data["dug"] = n + 1
	_dg_prog_ms = _now()
	if not _mine_audio.playing and _rng.randf() < 0.4:
		_play(_mine_audio)


func _dg_pit_done() -> bool:
	return int(_dg_data.get("dug", 0)) >= maxi(int(ceilf(float(_dg_data.get("depth", 1.2)) / 0.5)), 2)


## Straight down at the feet (the shield's shaft; the bot drops as the floor goes).
func _dg_shaft_tick(dt: float) -> void:
	var up: Vector3 = body.up_at(global_position)
	_dig_point = global_position - up * 0.6
	_dig_normal = up
	Dig.dig_at(body, _dig_point, 1.4, Dig.MODE_DIG, Balance.DG_SHAFT_RATE * dt, Vector3.ZERO, Vector3.UP, -1.0, team)
	if not _mine_audio.playing and _rng.randf() < 0.3:
		_play(_mine_audio)


## Walks the tunnel behind its face, brush on (_dg_tunnel_tick carves): 1 = all carved and the bot at
## the end, 0 = working, -1 = no progress for 25 s.
func _dg_tunnel_walk() -> int:
	if _dg_path.is_empty():
		return -1
	var up := _up()
	if _dg_i >= _dg_path.size():
		_dg_dig_off()
		if _walk_to(_dg_path[_dg_path.size() - 1], Balance.AI_WALK_SPEED):
			return 1
		return -1 if _now() - _dg_prog_ms > 25000 else 0
	var face: Vector3 = _dg_path[_dg_i]
	var stand: Vector3 = _dg_path[maxi(_dg_i - 2, 0)]
	var tf := _dg_flat(face - global_position, up)
	if tf.length_squared() > 0.01:
		_face = tf.normalized()
	if global_position.distance_to(stand) > 1.3:
		_move_to = stand
		_move_speed = Balance.AI_WALK_SPEED
		_strafe = Vector3.ZERO
	else:
		_move_to = Vector3.INF
	_dg_dig_on("tunnel")
	return -1 if _now() - _dg_prog_ms > 25000 else 0


## Floor points from `from` along the surface toward each of `legs` (world points; their depth is
## worked out here): depth(along) by `profile` ("sapper": ramp down to DG_SAP_DEPTH; "popup": and up
## again at the end; "bunker": ramp to DG_BUNKER_DEPTH). Stops early where `stop` says.
func _dg_route(from: Vector3, legs: Array, profile: String, depth_max: float, d0 := 0.0) -> Array:
	var c: Vector3 = body.global_position
	var dirs: Array = [(from - c).normalized()]
	for p: Vector3 in legs:
		dirs.append((p - c).normalized())
	var lens: Array = []
	var total := 0.0
	for k in dirs.size() - 1:
		var l := (dirs[k] as Vector3).angle_to(dirs[k + 1]) * float(body.radius)
		lens.append(l)
		total += l
	var pts: Array = []
	var along := 0.0
	for k in lens.size():
		var l: float = lens[k]
		var n := maxi(int(ceilf(l / Balance.DG_SAP_STEP)), 1)
		for s in range(0 if k == 0 else 1, n + 1):
			var f := float(s) / float(n)
			var dir: Vector3 = (dirs[k] as Vector3).slerp(dirs[k + 1], f).normalized()
			var a := along + l * f
			var depth := minf(depth_max, d0 + a * Balance.DG_SAP_SLOPE)
			if profile == "popup":
				depth = minf(depth, (total - a) * Balance.DG_SAP_SLOPE)
			pts.append(c + dir * (_dg_surf_r(dir) - depth))
		along += l
	return pts


## True when a floor point runs into a structure's footprint (+ margin; pop-up ends are checked).
func _dg_hits_structure(p: Vector3, margin: float, skip: Node3D) -> bool:
	for s in get_tree().get_nodes_in_group("war_structure"):
		if s == skip or not (s is Node3D) or s.is_in_group("skiff"):
			continue
		var sp: Vector3 = (s as Node3D).global_position
		var up: Vector3 = body.up_at(sp)
		var fl := _dg_flat(p - sp, up).length()
		if fl < float(s.get_meta("footprint_r", 3.0)) + margin and absf((p - sp).dot(up)) < 4.0:
			return true
	return false


# --- Sapper ----------------------------------------------------------------------------------------------

func _dg_think_sapper() -> bool:
	if team_node.raid_phase(self) != "site" or body == Game.rival:
		_dg_done()                             # (the raid is going home / it is home: stop)
		return false
	if _dg_phase == "":
		_dg_path = _dg_plan_sapper()
		if _dg_path.size() < 3:
			dg_clear()
			return false
		_dg_phase = "dig"
		_dg_data["step_t"] = Balance.DG_SAP_STEP_T
		if Game.hud and body == Game.planet and cam_dist < 90.0:
			Game.hud.show_message("Yer altından kazı sesi geliyor…", 2.5)
	match _dg_phase:
		"dig":
			if _now() - _dg_t0 > int(Balance.DG_SAP_TIME * 1000.0):
				_dg_done()
				return false
			var st := _dg_tunnel_walk()
			if st == -1:
				_dg_done()
				return false
			if st == 1:
				_dg_dig_off()
				if str(_dg_data.get("mode", "core")) == "popup":
					_dg_phase = "attack"
				else:
					dg_clear()                 # (under our base: the raid digger's shaft goes on from here)
					return false
			return true
		"attack":
			var s = _dg_data.get("target")
			if s == null or not is_instance_valid(s) or s.get("is_destroyed") == true \
					or _now() - _dg_t0 > int((Balance.DG_SAP_TIME + 60.0) * 1000.0):
				_dg_done()
				return false
			_raid_attack(s)
			return true
	return false


## The sapper's tunnel: pop-up beside and behind its target, else toward our base (stopping
## DG_SAP_CORE_SHORT m short of its centre, and short of any structure's footprint).
func _dg_plan_sapper() -> Array:
	var entry := global_position
	var tgt = _dg_data.get("target")
	if str(_dg_data.get("mode", "core")) == "popup" and tgt != null and is_instance_valid(tgt):
		var sp: Vector3 = (tgt as Node3D).global_position
		var up: Vector3 = body.up_at(sp)
		var away := _dg_flat(sp - entry, up).normalized()
		var side := up.cross(away).normalized() * (1.0 if _rng.randf() < 0.5 else -1.0)
		var fr := float(tgt.get_meta("footprint_r", 3.0))
		var via := sp + side * (fr + Balance.DG_SAP_SIDE)
		var exit_p := sp + away * (fr + Balance.DG_SAP_BEYOND)
		var pts := _dg_route(entry, [via, exit_p], "popup", Balance.DG_SAP_DEPTH)
		var ok := pts.size() >= 3
		for k in pts.size():
			if _dg_hits_structure(pts[k], 1.2, null):
				ok = false
				break
		if ok:
			return pts
	_dg_data["mode"] = "core"
	var base: Vector3 = _dg_data.get("base", entry)
	var all := _dg_route(entry, [base], "sapper", Balance.DG_SAP_DEPTH)
	var out: Array = []
	for p: Vector3 in all:
		var up: Vector3 = body.up_at(p)
		if _dg_flat(p - base, up).length() < Balance.DG_SAP_CORE_SHORT or _dg_hits_structure(p, 2.0, null):
			break
		out.append(p)
	return out


# --- Trench / ambush ---------------------------------------------------------------------------------------

func _dg_think_trench() -> bool:
	var pts: Array = _dg_data.get("points", [])
	if _dg_i >= pts.size() or _now() - _dg_t0 > 150000:
		_dg_done()
		return false
	var p: Vector3 = pts[_dg_i]
	if _dg_phase != "dig":
		_dg_dig_off()
		_set_held("terrain")
		if _walk_to(p, Balance.AI_WALK_SPEED):
			_dg_phase = "dig"
			_dg_data["pit"] = p
			_dg_data["dug"] = 0
			_dg_data["depth"] = Balance.DG_TRENCH_DEPTH
			_dg_data["r"] = 1.1
			_dg_data["step_t"] = Balance.DG_TRENCH_STEP_T
			_dg_t1 = _now()
		return true
	_move_to = Vector3.INF
	_crouch = true
	var cn = _dg_data.get("cannon")
	var toward: Vector3 = team_node.home.global_position - global_position
	_face = _dg_flat(toward, _up()).normalized()
	if _dg_pit_done() or _now() - _dg_t1 > 20000:
		_crouch = false
		_dg_i += 1
		_dg_phase = ""
		return true
	if cn == null or not is_instance_valid(cn):
		_dg_done()
		return false
	_dg_dig_on("pit")
	return true


func _dg_think_ambush() -> bool:
	var spot: Vector3 = _dg_data.get("spot", global_position)
	var watch: Vector3 = _dg_data.get("watch", global_position)
	match _dg_phase:
		"":
			_dg_dig_off()
			_set_held("rifle")
			if _walk_to(spot, Balance.AI_RUN_SPEED):
				_dg_phase = "dig"
				_dg_data["pit"] = global_position
				_dg_data["dug"] = 0
				_dg_data["depth"] = Balance.DG_AMBUSH_DEPTH
				_dg_data["r"] = 1.3
				_dg_data["step_t"] = 0.6
				_dg_t1 = _now()
			elif _now() - _dg_t0 > 60000:
				_dg_done()
				return false
			return true
		"dig":
			_move_to = Vector3.INF
			_crouch = true
			if _dg_pit_done() or _now() - _dg_t1 > 12000:
				_dg_dig_off()
				_dg_phase = "wait"
				_dg_t1 = _now()
				_dg_data["peek_ms"] = _now() + _rng.randi_range(4000, 8000)
			else:
				_dg_dig_on("pit")
			return true
		"wait":
			_move_to = Vector3.INF
			_set_held("rifle")
			_face = _dg_flat(watch - global_position, _up()).normalized()
			# Mostly down in the pit; now and then up for a look.
			var now := _now()
			var pk: int = int(_dg_data.get("peek_ms", now))
			_crouch = not (now > pk and now < pk + 1500)
			if now > pk + 1500:
				_dg_data["peek_ms"] = now + _rng.randi_range(5000, 9000)
			if now - _dg_t1 > int(Balance.DG_AMBUSH_WAIT * 1000.0):
				_crouch = false
				_dg_done()
				return false
			return true
	return false


# --- Bunker (dug) / core shield --------------------------------------------------------------------------

func _dg_think_bunker() -> bool:
	var entry: Vector3 = _dg_data.get("entry", global_position)
	if _now() - _dg_t0 > 180000:
		_dg_done()
		return false
	match _dg_phase:
		"":
			_dg_dig_off()
			_set_held("terrain")
			if _walk_to(entry, Balance.AI_WALK_SPEED):
				var rd: Vector3 = _dg_data.get("room_dir", Vector3.ZERO)
				var run := Balance.DG_BUNKER_DEPTH / 0.65 + 2.0
				var c: Vector3 = body.global_position
				_dg_path = []
				var n := int(ceilf(run / Balance.DG_SAP_STEP))
				for s in n + 1:
					var a := float(s) / float(n) * run
					var dir := (entry + rd * a - c).normalized()
					_dg_path.append(c + dir * (_dg_surf_r(dir) - minf(Balance.DG_BUNKER_DEPTH, a * 0.65)))
				_dg_data["room"] = _dg_path[_dg_path.size() - 1]
				_dg_data["step_t"] = 0.9
				_dg_i = 1
				_dg_phase = "ramp"
			return true
		"ramp":
			var st := _dg_tunnel_walk()
			if st == -1:
				_dg_done()
				return false
			if st == 1:
				_dg_phase = "room"
			return true
		"room":
			var room: Vector3 = _dg_data["room"]
			var up: Vector3 = body.up_at(room)
			var rd: Vector3 = _dg_data.get("room_dir", Vector3.ZERO)
			var side := up.cross(rd).normalized()
			var sd: Vector3 = _dg_data.get("slit_dir", rd)
			if not _dg_take(4):
				return true
			for o: Vector3 in [Vector3.ZERO, side * 1.2, -side * 1.2]:
				for k in 2:
					Dig.dig_at(body, room + o + up * 1.0, 1.8, Dig.MODE_DIG, Balance.DG_TUN_AMOUNT, Vector3.ZERO, Vector3.UP, -1.0, team)
			# The firing slit: a narrow cut rising toward our planet from the room's front.
			var s0 := room + up * 1.6 + sd * 1.4
			for k in 5:
				Dig.dig_at(body, s0 + sd * (0.75 * float(k)) + up * (0.55 * float(k)), 0.55, Dig.MODE_DIG,
						Balance.DG_TUN_AMOUNT, Vector3.ZERO, Vector3.UP, -1.0, team)
			team_node.bk_light(room - side * 1.4, up)
			team_node.dg_bunker_done(entry, room)
			_dg_phase = "leave"
			_dg_dig_off()
			return true
		"leave":
			if _walk_to(entry, Balance.AI_WALK_SPEED) or _now() - _dg_t0 > 170000:
				_dg_done()
				return false
			return true
	return false


func _dg_think_shield() -> bool:
	var xf: Transform3D = _dg_data.get("xf", Transform3D())
	var c: Vector3 = body.global_position
	var up_s := (xf.origin - c).normalized()
	var top := c + up_s * _dg_surf_r(up_s)
	if _now() - _dg_t0 > 240000:
		_dg_done()
		return false
	match _dg_phase:
		"":
			_dg_dig_off()
			_set_held("terrain")
			if _walk_to(top, Balance.AI_WALK_SPEED):
				_dg_phase = "shaft"
				_dg_t1 = _now()
				_dg_data["r_last"] = global_position.distance_to(c)
			return true
		"shaft":
			_move_to = Vector3.INF
			var r_now := global_position.distance_to(c)
			if r_now < float(_dg_data.get("r_last", r_now)) - 0.3:
				_dg_data["r_last"] = r_now
				_dg_prog_ms = _now()
			if r_now <= xf.origin.distance_to(c) + 0.4:
				_dg_dig_off()
				_dg_phase = "room"
				return true
			if _now() - _dg_prog_ms > 25000:
				_dg_done()
				return false
			_dg_dig_on("shaft")
			return true
		"room":
			if not team_node.bk_build_shield(xf):
				_dg_done()                     # (the pool ran short / taken: climb out)
				return false
			_dg_phase = "up"
			_dg_t1 = _now()
			return true
		"up":
			# Out by the shaft: walking at its wall starts the jet climb.
			var side := up_s.cross(Vector3.UP if absf(up_s.y) < 0.9 else Vector3.RIGHT).normalized()
			_move_to = top + side * 4.0
			_move_speed = Balance.AI_WALK_SPEED
			if _wx_depth() < 1.0:
				_dg_done()
				return false
			if _now() - _dg_t1 > int(Balance.DG_EXIT_TIME * 1000.0):
				_dg_lift_out()
				return false
			return true
	return false


# --- Counter-tunnel ---------------------------------------------------------------------------------------

func _dg_think_counter() -> bool:
	var head: Vector3 = _dg_data.get("head", Vector3.INF)
	if head == Vector3.INF or _now() - _dg_t0 > int(Balance.DG_COUNTER_TIME * 1000.0):
		_dg_done()
		return false
	var up := _up()
	match _dg_phase:
		"":
			# To the surface over the head, between it and the base (the side it is coming from).
			var hu: Vector3 = body.up_at(head)
			var hs := _on_sphere(head)
			var to_b: Vector3 = _dg_flat(team_node.base_xf.origin - hs, hu)
			var start := hs + (to_b.normalized() * 4.0 if to_b.length_squared() > 1.0 else Vector3.ZERO)
			_dg_dig_off()
			_set_held("terrain")
			if _walk_to(_ground_at(start + hu * 2.0), Balance.AI_RUN_SPEED):
				_dg_phase = "dig"
				_dg_data["replan"] = true
			return true
		"dig":
			if bool(_dg_data.get("replan", false)):
				_dg_data["replan"] = false
				_dg_path = _dg_line(global_position, head)
				_dg_i = 1
				_dg_data["step_t"] = Balance.DG_COUNTER_STEP_T
			# (met: at the head, or right beside any of his tunnel deeper down)
			if global_position.distance_to(head) < 2.6 or (_wx_depth() > 2.0 and team_node.dg_enemy_dug_near(global_position + up, 2.2)):
				_dg_dig_off()
				_dg_phase = "met"
				_dg_t1 = _now()
				return true
			if _dg_tunnel_walk() == -1:
				_dg_done()
				return false
			return true
		"met":
			_move_to = Vector3.INF
			_set_held("rifle")
			var fresh: int = int(_dg_data.get("fresh_ms", _dg_t0))
			if _now() - fresh > int(Balance.DG_COUNTER_STALE * 1000.0) and _now() - _seen_ms > 6000 and _now() - _dg_t1 > 3000:
				# The digger is gone: a grenade down his tunnel, the team caves it in.
				if team_node.wx_grenade_take():
					var hand := _eye() - up * 0.3
					var v := (head - hand).normalized() * 4.0 + up * 1.2
					team_node.wx_throw_grenade(self, hand, v, 2.2)
					team_node.dg_cave_in(head, 2.4)
				_dg_phase = "away"
				_dg_t1 = _now()
			elif _now() - _dg_t1 > 45000:
				_dg_done()
				return false
			return true
		"away":
			# Back off along its own tunnel while the fuse burns, then dig out.
			if _dg_path.size() > 3:
				_move_to = _dg_path[maxi(_dg_i - 4, 0)]
				_move_speed = Balance.AI_RUN_SPEED
			if _now() - _dg_t1 > 3500:
				_dg_done()
				return false
			return true
	return false


## Floor points on the straight line a -> b (the counter-tunnel), every DG_SAP_STEP m.
func _dg_line(a: Vector3, b: Vector3) -> Array:
	var pts: Array = []
	var l := a.distance_to(b)
	var n := maxi(int(ceilf(l / Balance.DG_SAP_STEP)), 1)
	for s in n + 1:
		pts.append(a.lerp(b, float(s) / float(n)))
	return pts


# --- Digging out --------------------------------------------------------------------------------------------

func _dg_think_exit() -> bool:
	var up := _up()
	var open := DgKit.cover_above(body, global_position + up * 0.5, up, 8.0) >= 8.0
	if open and _wx_depth() < 3.0:
		dg_clear()                             # (open sky, shallow enough: its own hop gets it out)
		return false
	if _now() - _dg_t0 > int(Balance.DG_EXIT_TIME * 1000.0):
		_dg_lift_out()
		return false
	if open:
		# An open pit / shaft: walk at its wall (the jet climb takes it up).
		_dg_dig_off()
		var f := _dg_flat(-global_transform.basis.z, up)
		f = f.normalized() if f.length_squared() > 1e-4 else up.cross(Vector3.RIGHT).normalized()
		_move_to = _on_sphere(global_position) + f * 4.0
		_move_speed = Balance.AI_WALK_SPEED
		_strafe = Vector3.ZERO
		return true
	if _dg_path.is_empty():
		_dg_path = _dg_plan_ramp_up()
		_dg_i = 1
		_dg_data["step_t"] = 0.5
		_dg_prog_ms = _now()
	var st := _dg_tunnel_walk()
	if st == 1:
		_dg_path = []                          # (at its end, still under soil: another ramp from here)
	elif st == -1:
		_dg_lift_out()
		return false
	return true


## A ramp from the feet up to the surface (DG_SAP_SLOPE), toward home ground when it can.
func _dg_plan_ramp_up() -> Array:
	var c: Vector3 = body.global_position
	var up := _up()
	var dir := _dg_flat(-global_transform.basis.z, up)
	if team_node != null and body == Game.rival:
		var tb := _dg_flat(team_node.base_xf.origin - global_position, up)
		if tb.length_squared() > 4.0:
			dir = tb
	dir = dir.normalized() if dir.length_squared() > 1e-4 else up.cross(Vector3.RIGHT).normalized()
	var r0 := global_position.distance_to(c)
	var pts: Array = [global_position]
	for k in 60:
		var a := Balance.DG_SAP_STEP * float(k + 1)
		var q := global_position + dir * a
		var d := (q - c).normalized()
		var r := minf(r0 + a * Balance.DG_SAP_SLOPE, _dg_surf_r(d))
		pts.append(c + d * r)
		if r >= _dg_surf_r(d) - 0.05:
			break
	return pts


## Never stuck: onto the surface over where it is.
func _dg_lift_out() -> void:
	var up := _up()
	var p := _ground_at(_on_sphere(global_position) + up * 2.0)
	dg_clear()
	_stop_dig()
	global_position = p + up * 0.3
	_air = true
	_vy = 0.0
	_climb = false


# --- Raid site, doors, walls, target choice ---------------------------------------------------------------

## From _raid_on_site: the enemy core shield next to it (its shaft got there), a closed enemy door in
## its way: shoot that first.
func _dg_raid_site() -> bool:
	for s in get_tree().get_nodes_in_group("war_core_shield"):
		if s is Node3D and Game.team_of(s) != team and s.get("is_destroyed") != true \
				and (s as Node3D).global_position.distance_to(global_position) < 9.0:
			_raid_attack(s)
			return true
	var d := _dg_door
	if d != null and is_instance_valid(d) and d.get("is_destroyed") != true and _now() - _dg_door_ms < 3000:
		_raid_attack(d)
		return true
	return false


## From _tick (the wanted walk): a closed enemy Zırhlı Kapı stops it (the raid code shoots it), an
## enemy wall / Sığınak Modülü turns it along its face (bots have no physics against structures).
func _dg_block(want: Vector3, pos: Vector3, up: Vector3) -> Vector3:
	if want.length_squared() < 0.01 or team_node == null:
		return want
	var ahead := pos + want.normalized() * 0.9
	var door: Node3D = DgKit.blocking_door(pos + up * 0.9, ahead + up * 0.9, team)
	if door != null:
		_dg_door = door
		_dg_door_ms = _now()
		return Vector3.ZERO
	for grp: String in ["war_wall", "war_bunker"]:
		for s in get_tree().get_nodes_in_group(grp):
			if not (s is Node3D) or Game.team_of(s) == team or s.get("is_destroyed") == true:
				continue
			var sx := (s as Node3D).global_transform.orthonormalized()
			if sx.origin.distance_to(pos) > 7.0:
				continue
			var half := DgKit.half_of(DgKit.kind_of(s)) + Vector3(0.4, 0.0, 0.4)
			var inv := sx.affine_inverse()
			var la := inv * ahead
			if absf(la.x) > half.x or absf(la.z) > half.z or la.y < -0.6 or la.y > half.y * 2.0 + 0.5:
				continue
			var lp := inv * pos
			var n := Vector3.ZERO
			if absf(lp.x) > half.x:
				n = sx.basis.x * signf(lp.x)
			elif absf(lp.z) > half.z:
				n = sx.basis.z * signf(lp.z)
			else:
				continue                       # (already inside: let it out)
			var into := want.dot(n)
			if into < 0.0:
				want -= n * into
	return want


## _nearest_enemy_structure's distance: turrets and the core shield count as half as far; an
## underground one (soil over it) only from within 10 m (its shaft / tunnel), never from the surface.
func _dg_struct_rank(s: Node3D, d: float) -> float:
	if team == "home":
		return d
	var under := s.is_in_group("war_core_shield") or s.is_in_group("war_bunker")
	if under and d > 10.0:
		var up: Vector3 = body.up_at(s.global_position)
		if DgKit.cover_above(body, s.global_position + up * 2.5, up, 10.0) < 10.0:
			return INF
	if s.is_in_group("war_turret") or s.is_in_group("war_core_shield"):
		return d * 0.5
	return d


## _pick_build_spot for a base piece: BaseKit's spot near what the team says (surface pieces).
func _bk_pick_spot(kind: String) -> Vector3:
	var near: Vector3 = team_node.bk_near(kind)
	var r: Dictionary = DgKit.suggest_spot(kind, team, near)
	if not bool(r["ok"]) or bool(r["underground"]):
		team_node.bk_failed(kind)             # (not asked again for a while)
		return Vector3.INF
	return (r["xf"] as Transform3D).origin


# =================================================================================================
# Reactions and body language (2026-10-06, "NPC tepkileri çok daha güzel olsun"; the poses:
# astronaut.gd "Body language"; the "!" and the lines: scripts/war/bot_cues.gd; tunables: balance.gd
# "Reactions and body language")
# =================================================================================================
# Hooks above (one line each): _think -> _bl_think (first: mood, combat transitions, idle life);
# _think_work -> _bl_hold_work (a pause: stands still); _perceive / _al_perceive -> _bl_spot (a NEW
# sighting); _on_blast -> _bl_on_blast; _on_shot -> _bl_heard (gunfire heard) and _bl_shot_src (a
# suppressed far shot is only roughly placed); take_damage -> _bl_note_hit; _die -> _bl_on_died;
# ally_team.gd _command -> bl_ack.
#   Sighting  seeing the player (or an enemy bot) after BL_SPOT_FORGET s unseen: no shot for
#             BL_SPOT_BEAT s (the beat), a startle (head snaps to him), then it points at him, a red
#             "!" over its head (~1 s), "Düşman görüldü! Saat 3 yönünde, 40 metre!" (the clock from
#             its own facing). Marking: teammates within BL_MARK_RANGE turn their heads there; idle
#             ones go to combat facing it and look for cover (no extra help calls).
#   Signals   (a teammate within BL_SQUAD_RANGE, BL_SIGNAL_CD apart) "move up" when it advances /
#             flanks ("İlerle!"), "hold" when it holds, "cover me" (pats its helmet) when it reloads
#             under fire; "El bombası atıyorum!" at a grenade wind-up, "Geri çekiliyorum!" when it
#             flees, "Mekiğe!" when a skiff raid goes home.
#   Feelings  a blast just outside its damage radius: cowers BL_COWER_TIME s (crouched, hunched, a
#             forearm over the visor, "Siper al!" now and then); a teammate dying within
#             BL_DOWN_RANGE: the others look at the body, idle ones stop a moment, the nearest calls
#             "Kazıcı düştü!"; the player killed by its fire: a short fist pump, "Hedef etkisiz!"
#             (team-wide 6 s apart); below BL_WOUND_HP: a limp, the left hand pressed to the side
#             (hands free), a slight hunch, "Yaralıyım!" once; under heavy fire (suppression(): the
#             "Pressure, cover and lethality" section's, else the near misses of the last 3 s):
#             hunched, "Bastırıldım!" above BL_PINNED.
#   Idle      (near the camera, in WORK) every BL_IDLE_GAP s standing about: look around, stretch,
#             check the rifle, wipe the visor; guards scan with their heads on patrol; miners rest
#             (crouched, a hand on the knee) every BL_REST_GAP s of digging; engineers between jobs
#             walk to one of their structures, put a hand on it and sweep it with the tool.
#   Allies    a wave (or a nod) when the player comes within BL_GREET_R; a thumbs up, "İyi atış!"
#             when he kills a rival bot within BL_NICE_SHOT_R; seeing an enemy: it points, an amber
#             "!" over the enemy for ~2 s, "Düşman! Saat 2 yönünde, 25 metre!" (the clock from the
#             PLAYER's view); the F command: a nod and a raised palm, "Anlaşıldı, peşindeyim!".
#   Hearing   gunfire within BL_HEAR_RANGE (a suppressed gun of the player's: × its attachment
#             "noise" stat, ~16 m) turns an idle bot toward a guess of the spot and into combat;
#             a near miss always alerts, but from a suppressed gun beyond its hearing radius the
#             shooter is only guessed along the bullet's line (BL_SUPP_FUZZ).
# Cost: poses, lines and idle life only within BL_RANGE of a camera (cam_dist); the beat, marking,
# hearing and the shot guess run everywhere. Per-bot cooldowns (_bl_ready), a team-wide callout gap.
# Multiplayer (host): RivalTeam.events() bot_gesture(index, kind, dir) / bot_callout(index, line,
# variant, arg) / bot_alert(index, kind) / bot_mood(index, wound, hunch) for the rival's bots (allies
# are single player only); net_bot.gd mirrors them on the puppets.

const BotCues := preload("res://scripts/war/bot_cues.gd")

var _bl_cd := {}                         # cooldown key -> msec when allowed again
var _bl_pause_ms := 0                    # WORK: stands still until then...
var _bl_pause_kind := ""                 # ...("rest": no digging either)
var _bl_prev_tac := Tac.NONE
var _bl_was_reload := false
var _bl_was_throw := false
var _bl_wounded := false
var _bl_pl_alive := {}                   # player instance id -> alive at the last think
var _bl_idle_ms := 0
var _bl_rest_ms := 0
var _bl_inspect := {}                    # an engineer's idle inspection: {"s", "t0", "at"}
var _bl_inspect_ms := 0
var _bl_greet_ms := -100000
var _bl_pl_far := true
var _bl_hit_from := Vector3.INF
var _bl_hit_ms := -100000
var _bl_phase_prev := ""
var _bl_mood := Vector2(-1.0, -1.0)
var _bl_scan_ms := 0
var _bl_heard_ms := -100000
var _bl_nm: Array = []                   # msec of the recent near misses / hits (suppression guess)


# --- Helpers --------------------------------------------------------------------------------------------

func _bl_near() -> bool:
	return cam_dist < Balance.BL_RANGE and visible


## True (and the cooldown starts) when `key` is off cooldown.
func _bl_ready(key: String, cd: float) -> bool:
	var now := _now()
	if now < int(_bl_cd.get(key, 0)):
		return false
	_bl_cd[key] = now + int(cd * 1000.0)
	return true


## A world point as a direction in this bot's own space (from its eyes; -Z ahead).
func _bl_local(p: Vector3) -> Vector3:
	var l := global_transform.basis.orthonormalized().inverse() * (p - _eye())
	return l.normalized() if l.length_squared() > 1e-4 else Vector3.FORWARD


func _bl_events():
	if team != "rival" or not Net.is_host() or team_node == null or not team_node.has_method("events"):
		return null
	return team_node.events()


func _bl_gesture(kind: String, dir_local := Vector3.FORWARD, queue := false) -> void:
	if not _bl_near() or mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	if queue:
		astronaut.queue_gesture(kind, dir_local)
	else:
		astronaut.gesture(kind, dir_local)
	var ev = _bl_events()
	if ev != null:
		ev.bot_gesture.emit(index, kind, dir_local)


func _bl_look(dir_local: Vector3, hold: float) -> void:
	if not _bl_near():
		return
	astronaut.look_dir(dir_local, hold)
	var ev = _bl_events()
	if ev != null:
		ev.bot_gesture.emit(index, "look", dir_local)


## A callout: the line over the head (near the camera), the radio, the event. force: past the
## per-bot cooldown and the team gap (sightings, kills, deaths, answers to the player).
func _bl_call(line: String, arg := 0, force := false) -> bool:
	if mode == Mode.DEAD or team_node == null:
		return false
	var now := _now()
	if not force:
		if now < int(_bl_cd.get("call", 0)) or not BotCues.team_may_call(team, Balance.BL_CALL_GAP):
			return false
	_bl_cd["call"] = now + int(Balance.BL_CALL_CD * 1000.0)
	var v := BotCues.pick(line)
	if cam_dist < Balance.BL_SAY_RANGE:
		BotCues.say(self, BotCues.line_text(line, v, arg), team == "home", line in BotCues.URGENT)
	var rk := BotCues.radio_kind(line)
	if rk != "":
		_radio_call(rk)
	var ev = _bl_events()
	if ev != null:
		ev.bot_callout.emit(index, line, v, arg)
	return true


## Stands still a moment in WORK (_bl_hold_work), unless a task of the team's is running.
func _bl_pause(t: float, kind: String) -> void:
	if _dg_task != "" or _wx_task != "" or _pod_phase != "" or _pod_tag or foothold != null:
		return
	if team_node != null and team_node.is_raiding(self):
		return
	_bl_pause_ms = _now() + int(t * 1000.0)
	_bl_pause_kind = kind


func _bl_squad_near() -> bool:
	if team_node == null:
		return false
	for b in team_node.bots:
		if b != self and is_instance_valid(b) and not b.is_dead() and not b.is_aboard() \
				and (b as Node3D).global_position.distance_to(global_position) < Balance.BL_SQUAD_RANGE:
			return true
	return false


## 0..1 how pinned down it is: the "Pressure, cover and lethality" section's suppression() when it
## exists, else the near misses and hits of the last 3 s.
func _bl_suppression(now: int) -> float:
	if has_method("suppression"):
		return clampf(float(call("suppression")), 0.0, 1.0)
	while not _bl_nm.is_empty() and now - int(_bl_nm[0]) > 3000:
		_bl_nm.pop_front()
	return clampf(float(_bl_nm.size()) / 5.0, 0.0, 1.0)


## The role name for "X düştü!" (BotCues.NAMES).
func _bl_name_index() -> int:
	if callsign.contains("Muhafız"):
		return 3
	return clampi(role, 0, 2)


# --- Per think ------------------------------------------------------------------------------------------

func _bl_think(_dt: float) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD or team_node == null:
		return
	var now := _now()
	var f := hp / maxf(hp_max, 1.0)
	# Mood: wounded, hunched under heavy fire.
	var wound := 0.0
	if f < Balance.BL_WOUND_HP:
		wound = clampf(0.45 + (Balance.BL_WOUND_HP - f) / Balance.BL_WOUND_HP, 0.0, 1.0)
	var supp := _bl_suppression(now)
	var hunch := clampf((supp - 0.3) / 0.5, 0.0, 1.0) if mode == Mode.COMBAT else 0.0
	astronaut.set_mood(wound, hunch)
	var mq := Vector2(snappedf(wound, 0.1), snappedf(hunch, 0.1))
	if mq != _bl_mood:
		_bl_mood = mq
		var ev = _bl_events()
		if ev != null:
			ev.bot_mood.emit(index, mq.x, mq.y)
	if f < Balance.BL_WOUND_HP and not _bl_wounded:
		_bl_wounded = true
		_bl_call("wounded", 0, true)
	elif f > 0.6:
		_bl_wounded = false
	if mode == Mode.COMBAT:
		if supp > Balance.BL_PINNED and _bl_ready("pinned", 15.0):
			_bl_call("pinned")
		_bl_combat_cues(now)
	else:
		_bl_prev_tac = Tac.NONE
	_bl_was_reload = _reload_t > 0.0
	_bl_was_throw = _wx_throwing
	var ph: String = str(team_node.raid_phase(self)) if team == "rival" else ""
	if ph == "return" and _bl_phase_prev != "return" and BotCues.team_may_call("rival_raid", 20.0):
		_bl_call("raid_return", 0, true)
	_bl_phase_prev = ph
	_bl_kill_check(now)
	if mode == Mode.WORK:
		_bl_idle_life(now)
	if team == "home":
		_bl_ally_life(now)


func _bl_combat_cues(now: int) -> void:
	if _tac != _bl_prev_tac:
		match _tac:
			Tac.ADVANCE, Tac.FLANK:
				if _bl_squad_near() and _bl_ready("signal", Balance.BL_SIGNAL_CD):
					var at := _threat_pos if _threat_pos != Vector3.INF else _eye() - global_transform.basis.z * 10.0
					_bl_gesture("advance", _bl_local(at))
					_bl_call("move_up")
			Tac.HOLD:
				if _bl_squad_near() and _bl_ready("signal", Balance.BL_SIGNAL_CD):
					_bl_gesture("hold")
					_bl_call("hold")
			Tac.FLEE:
				_bl_call("retreat", 0, _bl_ready("retreat", 12.0))
	_bl_prev_tac = _tac
	if _reload_t > 0.0 and not _bl_was_reload and now - _threat_ms < 2500 and _bl_squad_near() \
			and _bl_ready("signal", Balance.BL_SIGNAL_CD):
		_bl_gesture("cover_me")
		_bl_call("cover_me")
	if _wx_throwing and not _bl_was_throw:
		_bl_call("grenade", 0, true)


## The player it was fighting just died with it on him: a fist pump, "Hedef etkisiz!".
func _bl_kill_check(now: int) -> void:
	for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		if pl == null or not is_instance_valid(pl) or not pl.has_method("is_dead"):
			continue
		var id: int = pl.get_instance_id()
		var alive: bool = not bool(pl.is_dead())
		var was: bool = bool(_bl_pl_alive.get(id, alive))
		_bl_pl_alive[id] = alive
		if not was or alive or team != "rival" or _target != pl or now - _seen_ms > 2500:
			continue
		if (pl as Node3D).global_position.distance_to(global_position) > Balance.AI_FIGHT_RANGE:
			continue
		if BotCues.team_may_call("rival_kill", 6.0):
			_bl_gesture("fist", _bl_local((pl as Node3D).global_position))
			_bl_call("kill", 0, true)


# --- Sighting, marking ---------------------------------------------------------------------------------------

## A NEW sighting of `tg` at `pos` (_perceive / _al_perceive, before they stamp _seen_ms).
func _bl_spot(tg: Node3D, pos: Vector3) -> void:
	var now := _now()
	if now - _seen_ms < int(Balance.BL_SPOT_FORGET * 1000.0) or team_node == null:
		return
	_flinch = maxf(_flinch, Balance.BL_SPOT_BEAT)           # the beat: no shot before it has taken him in
	var dl := _bl_local(pos)
	if team == "home":
		# An ally points the enemy out to the player (the clock from his view).
		var arg := BotCues.pack_clock(_eye(), -global_transform.basis.z, _up(), pos)
		var cam := get_viewport().get_camera_3d()
		var pl = Game.player
		if cam != null and pl != null and is_instance_valid(pl) and (pl as Node3D).global_position.distance_to(global_position) < 50.0:
			arg = BotCues.pack_clock(cam.global_position, -cam.global_transform.basis.z, _up(), pos)
		_bl_gesture("point", dl)
		if _bl_near() and tg != null and is_instance_valid(tg):
			BotCues.alert(tg, "marked")
		_bl_call("ally_spot", arg, true)
		return
	if _bl_near():
		_bl_gesture("startle", dl)
		_bl_gesture("point", dl, true)
		BotCues.alert(self, "seen")
	var ev = _bl_events()
	if ev != null:
		ev.bot_alert.emit(index, "seen")
	_bl_call("spot", BotCues.pack_clock(_eye(), -global_transform.basis.z, _up(), pos), true)
	for b in team_node.bots:
		if b == self or not is_instance_valid(b) or b.is_dead() or str(b.get("team")) != team:
			continue
		if (b as Node3D).global_position.distance_to(global_position) < Balance.BL_MARK_RANGE and b.has_method("bl_marked"):
			b.bl_marked(pos)


## A teammate reported the enemy at `pos`: the head turns there; an idle bot goes to combat facing it
## and looks for cover (the spotter already called for help).
func bl_marked(pos: Vector3) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD or _hr_busy():
		return
	var now := _now()
	if now - _seen_ms < 2000:
		return
	_bl_look(_bl_local(pos), Balance.BL_MARK_LOOK)
	_bl_take_cover_toward(pos)


## WORK, nothing the team gave it: into combat facing `pos`, a cover search.
func _bl_take_cover_toward(pos: Vector3) -> void:
	if mode != Mode.WORK or _dg_task != "" or _wx_task != "" or _pod_phase != "" or _pod_tag or foothold != null:
		return
	if _job == "build" or _job == "fire" or _job == "repair" or team_node.is_raiding(self):
		return
	_help_ms = _now()
	_threat_pos = pos
	_enter_combat(pos)
	if mode == Mode.COMBAT:
		_request_cover(pos, false)
		_face = (pos - global_position).normalized()


# --- Blasts, deaths, hits, hearing ---------------------------------------------------------------------------

func _bl_on_blast(pos: Vector3, d: float, radius: float) -> void:
	if d <= radius * 1.15 or d > maxf(radius * Balance.BL_COWER_K, 9.0):
		return
	if is_staggered() or is_down() or _air or sliding or _climb or not _bl_ready("cower", 4.0):
		return
	_crouch_hold = maxf(_crouch_hold, Balance.BL_COWER_TIME)
	_bl_gesture("cower", _bl_local(pos))
	if randf() < 0.35:
		_bl_call("cower")


func _bl_note_hit(from_pos: Vector3) -> void:
	_bl_hit_from = from_pos
	_bl_hit_ms = _now()
	_bl_nm.append(_bl_hit_ms)
	if _bl_nm.size() > 10:
		_bl_nm.pop_front()


## This bot died: the teammates near look at it (the nearest calls it); a rival bot the player killed:
## an ally of his near gives him a thumbs up.
func _bl_on_died() -> void:
	if team_node == null:
		return
	var now := _now()
	var by_player := false
	if now - _bl_hit_ms < 1500 and _bl_hit_from != Vector3.INF and _bl_hit_from != Vector3.ZERO:
		for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
			if pl != null and is_instance_valid(pl) and (pl as Node3D).global_position.distance_to(_bl_hit_from) < 4.0:
				by_player = true
	var best: Node3D = null
	var bd := Balance.BL_DOWN_RANGE
	var ni := _bl_name_index()
	for b in team_node.bots:
		if b == self or not is_instance_valid(b) or b.is_dead() or b.is_aboard() or not b.has_method("bl_ally_down"):
			continue
		var d: float = (b as Node3D).global_position.distance_to(global_position)
		if d > Balance.BL_DOWN_RANGE:
			continue
		b.bl_ally_down(self, false, ni)
		if d < bd:
			bd = d
			best = b
	if best != null:
		best.bl_ally_down(self, true, ni)
	if by_player and team == "rival":
		var pl2 = Game.player
		var al: Node3D = null
		var ad := Balance.BL_NICE_SHOT_R
		for a in get_tree().get_nodes_in_group("war_ally"):
			if not is_instance_valid(a) or not a.has_method("bl_nice_shot") or a.is_dead():
				continue
			var d2: float = (a as Node3D).global_position.distance_to(global_position)
			if pl2 != null and is_instance_valid(pl2):
				d2 = minf(d2, (a as Node3D).global_position.distance_to((pl2 as Node3D).global_position))
			if d2 < ad:
				ad = d2
				al = a
		if al != null:
			al.bl_nice_shot()


## A teammate went down near it: call it (the nearest) or look at the body (an idle one stops a moment).
func bl_ally_down(dead: Node3D, do_call: bool, name_i: int) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD or dead == null or not is_instance_valid(dead):
		return
	if do_call:
		_bl_call("ally_down", name_i, true)
		return
	_bl_gesture("glance", _bl_local(dead.global_position + _up() * 0.6))
	if mode == Mode.WORK:
		_bl_pause(1.4, "look")
		var d := dead.global_position - global_position
		d -= _up() * d.dot(_up())
		if d.length_squared() > 0.01:
			_face = d.normalized()


## How loud a shot from `from` is: 1, or the player's suppressed gun's attachment "noise" stat.
## (scripts/items/attachments.gd is never loaded from here: the gun's att_kit is duck-typed.)
func _bl_noise(from: Vector3) -> float:
	# × a relic's "Sessiz adım" (scripts/war/cache_buffs.gd noise_mult; loaded at use: 1 without it)
	var q := 1.0
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and (pl as Node3D).global_position.distance_to(from) <= 3.2 \
			and ResourceLoader.exists("res://scripts/war/cache_buffs.gd"):
		q = float(load("res://scripts/war/cache_buffs.gd").call("noise_mult"))
	return _bl_noise_gun(from) * q


## The local player's gun noise near `from`: its suppressor's "noise" stat (1 = unsuppressed).
func _bl_noise_gun(from: Vector3) -> float:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or (pl as Node3D).global_position.distance_to(from) > 3.2:
		return 1.0
	var items = pl.get("items")
	var ci = pl.get("current_item")
	if not (items is Array) or ci == null or int(ci) < 0 or int(ci) >= (items as Array).size():
		return 1.0
	var it = (items as Array)[int(ci)]
	if it == null or not is_instance_valid(it):
		return 1.0
	var kit = it.get("att_kit")
	if kit == null or not (kit is Object) or not kit.has_method("suppressed") or not bool(kit.call("suppressed")):
		return 1.0
	var n := 0.35
	if kit.has_method("stat"):
		n = float(kit.call("stat", "noise", 0.35))
	return clampf(n, 0.1, 1.0)


## A near miss (_on_shot): where it thinks the shooter is. A suppressed gun beyond its hearing radius
## only shows the bullet's line: the distance back along it is a guess.
func _bl_shot_src(from: Vector3, dir: Vector3, along: float) -> Vector3:
	_bl_nm.append(_now())
	if _bl_nm.size() > 10:
		_bl_nm.pop_front()
	var n := _bl_noise(from)
	if n >= 0.99 or along <= Balance.BL_HEAR_RANGE * n:
		return from
	var err := along * Balance.BL_SUPP_FUZZ
	var est := maxf(along + randf_range(-err, err), 5.0)
	var up := _up()
	var side := dir.cross(up)
	side = side.normalized() if side.length_squared() > 1e-4 else Vector3.ZERO
	return global_position + up * 1.2 - dir * est + side * randf_range(-1.0, 1.0) * along * 0.12


## Gunfire heard (not a near miss: _on_threat has those): an idle bot turns toward a guess of the
## spot and goes to combat there (cover search); within BL_HEAR_RANGE × the gun's noise.
func _bl_heard(from: Vector3, dir: Vector3, along: float, rel: Vector3) -> void:
	if along >= 0.0 and along <= 400.0 and (rel - dir * along).length() < Balance.AI_NEAR_MISS:
		return
	var now := _now()
	if now - _bl_heard_ms < int(Balance.BL_HEAR_CD * 1000.0) or body == null or Game.dominant_body(from) != body:
		return
	var dist := from.distance_to(global_position)
	if dist < 1.5 or dist > Balance.BL_HEAR_RANGE * _bl_noise(from):
		return
	_bl_heard_ms = now
	var guess := from + Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * dist * 0.15
	if mode == Mode.WORK:
		_bl_look(_bl_local(guess), 2.5)
		if randf() < 0.5:
			_bl_call("heard")
		_bl_take_cover_toward(guess)
	elif mode == Mode.COMBAT and not _target_visible:
		_bl_look(_bl_local(guess), 1.5)


# --- Idle life --------------------------------------------------------------------------------------------

func _bl_idle_life(now: int) -> void:
	if not _bl_near() or now < _bl_pause_ms or not _bl_inspect.is_empty():
		return
	if _dg_task != "" or _wx_task != "" or _pod_phase != "" or _pod_tag or foothold != null:
		return
	var still := velocity.length() < 0.4
	# Miners rest now and then: bent over, a hand on the knee.
	if role == ROLE_MINER and _digging and _job == "":
		if _bl_rest_ms == 0:
			_bl_rest_ms = now + int(randf_range(Balance.BL_REST_GAP.x, Balance.BL_REST_GAP.y) * 1000.0)
		elif now > _bl_rest_ms:
			_bl_rest_ms = now + int(randf_range(Balance.BL_REST_GAP.x, Balance.BL_REST_GAP.y) * 1000.0)
			_bl_pause(Balance.BL_REST_TIME, "rest")
			if now < _bl_pause_ms:
				_stop_dig()
				_crouch_hold = maxf(_crouch_hold, Balance.BL_REST_TIME - 0.6)
				_bl_gesture("rest", Vector3.FORWARD)
			return
	# Engineers between jobs inspect one of their structures.
	if role == ROLE_ENGINEER and _job == "" and _digging and team == "rival":
		if _bl_inspect_ms == 0:
			_bl_inspect_ms = now + int(randf_range(Balance.BL_INSPECT_GAP.x, Balance.BL_INSPECT_GAP.y) * 1000.0)
		elif now > _bl_inspect_ms:
			_bl_inspect_ms = now + int(randf_range(Balance.BL_INSPECT_GAP.x, Balance.BL_INSPECT_GAP.y) * 1000.0)
			var best: Node3D = null
			var bd := 30.0
			for s in team_node.cannons + team_node.flaks:
				if is_instance_valid(s) and not s.is_destroyed:
					var d: float = (s as Node3D).global_position.distance_to(global_position)
					if d < bd:
						bd = d
						best = s
			if best != null:
				_bl_inspect = {"s": best, "t0": now}
				return
	# Guards scan with their heads on patrol.
	if (_job == "guard" or _job == "raid_guard") and not still and now > _bl_scan_ms:
		_bl_scan_ms = now + randi_range(2500, 5000)
		var yaw := randf_range(-1.1, 1.1)
		_bl_look(Vector3(-sin(yaw), -0.05, -cos(yaw)), 1.4)
		return
	# Standing about: look around, stretch, check the rifle, wipe the visor.
	if still and not _digging and (_job == "" or _job == "guard" or _job == "al_follow"):
		if _bl_idle_ms == 0:
			_bl_idle_ms = now + int(randf_range(Balance.BL_IDLE_GAP.x, Balance.BL_IDLE_GAP.y) * 1000.0)
		elif now > _bl_idle_ms:
			_bl_idle_ms = now + int(randf_range(Balance.BL_IDLE_GAP.x, Balance.BL_IDLE_GAP.y) * 1000.0)
			var kinds: Array = ["look_around", "stretch", "wipe_visor"]
			if _held == "rifle":
				kinds.append("check_rifle")
				kinds.append("check_rifle")
			var k: String = kinds[randi() % kinds.size()]
			_bl_gesture(k)
			_bl_pause(float(Astronaut.BL_DUR.get(k, 2.0)), "idle")


## From _think_work: true while it stands still (a pause) or does its idle inspection.
func _bl_hold_work() -> bool:
	if team_node == null:
		return false
	var now := _now()
	if not _bl_inspect.is_empty():
		return _bl_inspect_step(now)
	if now >= _bl_pause_ms:
		return false
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	if _bl_pause_kind == "rest" and _digging:
		_stop_dig()
	return true


func _bl_inspect_step(now: int) -> bool:
	var s = _bl_inspect.get("s")
	if s == null or not is_instance_valid(s) or s.get("is_destroyed") == true or now - int(_bl_inspect["t0"]) > 15000 \
			or _dg_task != "" or _wx_task != "":
		_bl_inspect = {}
		return false
	var sp: Vector3 = (s as Node3D).global_position
	var up := _up()
	var off := sp - global_position
	off -= up * off.dot(up)
	var r := float(s.get_meta("footprint_r", 3.0)) + 0.8
	if not _bl_inspect.has("at"):
		if off.length() > r + 0.7:
			_stop_dig()
			_walk_to(sp - off.normalized() * r, Balance.AI_WALK_SPEED)
			return true
		_bl_inspect["at"] = now
		_move_to = Vector3.INF
		if off.length_squared() > 0.01:
			_face = off.normalized()
		var dl := _bl_local(sp + up * 0.9)
		_bl_gesture("inspect", dl)
		_bl_gesture("scan", dl, true)
	if now - int(_bl_inspect["at"]) > 6500:
		_bl_inspect = {}
		return false
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	return true


# --- Allies and the player ------------------------------------------------------------------------------------

func _bl_ally_life(now: int) -> void:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.get("vehicle") != null:
		return
	var pp: Vector3 = (pl as Node3D).global_position
	var d := pp.distance_to(global_position)
	if d > Balance.BL_GREET_R * 2.0:
		_bl_pl_far = true
		return
	if d > Balance.BL_GREET_R or not _bl_pl_far:
		return
	_bl_pl_far = false
	if mode != Mode.WORK or now - _bl_greet_ms < int(Balance.BL_GREET_CD * 1000.0) or not _bl_near():
		return
	_bl_greet_ms = now
	var up := _up()
	var fd := pp - global_position
	fd -= up * fd.dot(up)
	if fd.length_squared() > 0.01:
		_face = fd.normalized()
	_bl_gesture("nod" if (al_follow and randf() < 0.5) else "wave", _bl_local(pp + up * 1.5))
	if randf() < 0.6:
		_bl_call("greet", 0, true)
	_bl_pause(1.5, "greet")


## The player killed a rival bot near this ally: a thumbs up, "İyi atış!".
func bl_nice_shot() -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD or team != "home" or not _bl_ready("nice", 8.0):
		return
	var pl = Game.player
	if pl == null or not is_instance_valid(pl):
		return
	var pp: Vector3 = (pl as Node3D).global_position + _up() * 1.5
	_bl_gesture("thumbs_up", _bl_local(pp))
	_bl_call("nice_shot", 0, true)
	if mode == Mode.WORK:
		_bl_pause(1.5, "nice")
		var fd := pp - global_position
		fd -= _up() * fd.dot(_up())
		if fd.length_squared() > 0.01:
			_face = fd.normalized()


## The F command (ally_team.gd _command): a nod and a raised palm, the answer.
func bl_ack() -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	var pl = Game.player
	if pl != null and is_instance_valid(pl):
		var pp: Vector3 = (pl as Node3D).global_position + _up() * 1.5
		var fd := pp - global_position
		fd -= _up() * fd.dot(_up())
		if fd.length_squared() > 0.01 and mode == Mode.WORK:
			_face = fd.normalized()
		_bl_gesture("ack", _bl_local(pp))
	var line := "ack_follow" if al_follow else ("ack_dig" if role == ROLE_MINER else "ack_guard")
	_bl_call(line, 0, true)
	if mode == Mode.WORK:
		_bl_pause(1.0, "ack")


# =================================================================================================
# Cave-ins and entrench (2026-10-06, "Tünel çökertme" / "Hızlı siper"; scripts/war/cave_in.gd;
# tunables: balance.gd "Cave-ins and entrench")
# =================================================================================================
# Hooks above (one line each): _physics_process -> _ci_buried_tick (buried: stuck in the soil, nothing
# else runs: no thinking, moving, shooting or hit reactions); _sup_decide -> _ci_entrench (pinned in
# the open with no cover at hand: sometimes it slams a berm up toward the threat and ducks behind it).
#   Buried (CaveIn.bury -> ci_bury(dur, full), host only): its sim state is frozen where the soil holds
#     it, digging / a slide / a grenade wind-up stop (a live grenade drops), the hit reactor is reset
#     (no knockdown ragdoll inside the soil). With the head under the soil it suffocates
#     (CAVE_SUFFOCATE_DMG / s after CAVE_SUFFOCATE_DELAY, through Game.damage_target); after `dur` s it
#     digs itself out (CaveIn.dig_out: a pocket and a shaft) with a small hop and thinks again at once
#     (the team's dg_check_trapped / the jet climb take it the rest of the way up).
#   Entrench: lod 0-1, not more often than ENTRENCH_AI_COOLDOWN, ENTRENCH_AI_CHANCE per decision, one
#     of the team's carve tokens (DG_CARVE_PER_MIN); CaveIn.entrench queues the same brushes as the
#     player's X (synced, bots use the berm as cover through the density line of sight); then it holds
#     the spot as cover, crouched (the COVER tactic peeks over the berm).
# Gates for other code: ci_buried(); cave_in.gd calls ci_bury / ci_clear.
# Multiplayer: bots are host-simulated; a buried bot just stands still in the soil on the client (its
# snapshot does not move).

const CaveIn := preload("res://scripts/war/cave_in.gd")

var _ci_until := 0                     # ms: buried until (0 = free)
var _ci_full := false                  # the head is under the soil too (suffocates)
var _ci_tick := 0                      # ms: next suffocation tick
var _ci_ent_ms := -100000              # ms: last entrench


## cave_in.gd: buried for `dur` s (full: the head too).
func ci_bury(dur: float, full: bool) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	var now := _now()
	if _ci_until > 0:
		_ci_until = maxi(_ci_until, now + int(dur * 1000.0))
		_ci_full = _ci_full or full
		return
	_ci_until = now + int(maxf(dur, 0.5) * 1000.0)
	_ci_full = full
	_ci_tick = now + int(Balance.CAVE_SUFFOCATE_DELAY * 1000.0)
	_stop_dig()
	if sliding:
		_end_slide(false)
	if _wx_throwing:
		_hr_drop_grenade()
	if _reactor != null:
		_reactor.reset()
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_knock = Vector3.ZERO
	_hv = Vector3.ZERO
	_air = false
	_climb = false
	_vy = 0.0
	velocity = Vector3.ZERO
	_sim_prev = _sim_xf                      # (the shown body stops where the sim is)
	_radio_call("hit")


func ci_buried() -> bool:
	return _ci_until > 0


func ci_clear() -> void:
	_ci_until = 0
	_ci_full = false


## _physics_process: true while buried (the rest is skipped).
func _ci_buried_tick(_delta: float) -> bool:
	if _ci_until == 0:
		return false
	var now := _now()
	if now - _ci_until > 2000:
		ci_clear()                           # (stale: it died / boarded meanwhile and was not ticked)
		return false
	velocity = Vector3.ZERO
	if _ci_full and now >= _ci_tick:
		_ci_tick = now + 1000
		Game.damage_target(self, Balance.CAVE_SUFFOCATE_DMG, global_position + _up() * 3.0, Vector3.ZERO, "")
		if mode == Mode.DEAD:
			ci_clear()
			return true
	if now < _ci_until:
		return true
	ci_clear()
	if _reactor != null:
		_reactor.reset()                     # (the suffocation hits do not knock it down afterwards)
	var up := _up()
	CaveIn.dig_out(body, _sim_xf.origin, up)
	_air = true
	_vy = 2.5
	_probe_t = 0.0
	_think_acc = 1.0
	return true


## _sup_decide, pinned in the open: a berm toward the threat, then hold the spot crouched behind it.
func _ci_entrench(threat: Vector3) -> bool:
	if lod > 1 or _air or _climb or sliding or _hr_busy() or _wx_throwing or body == null:
		return false
	var now := _now()
	if now - _ci_ent_ms < int(Balance.ENTRENCH_AI_COOLDOWN * 1000.0):
		return false
	_ci_ent_ms = now
	if _rng.randf() > Balance.ENTRENCH_AI_CHANCE or not _dg_take(1):
		return false
	var up := _up()
	var tf := threat - global_position
	tf -= up * tf.dot(up)
	if tf.length_squared() < 0.25:
		return false
	if not CaveIn.entrench(body, _sim_xf.origin, tf, up, team, self):
		return false
	_face = tf.normalized()
	_cover_pos = global_position
	_tac = Tac.COVER
	_tac_t = _rng.randf_range(4.0, 7.0)
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_crouch = true
	_peek = false
	_peek_t = _rng.randf_range(1.0, 1.8) * Balance.AI_SUP_HIDE
	return true


# =================================================================================================
# Prospecting: rich veins and meteor cores (2026-10-06; the team side: the same section at the end of
# rival_team.gd; the veins: scripts/planet/veins.gd; constants: balance.gd "Veins and meteors" VN_*)
# =================================================================================================
# Hooks above (one line each): _think_work -> _vn_think (after the weapon / dig / pod tasks, before a
# foothold and the role's work); _dig_shaft -> _vn_dig_tick (its brush, after the weapon / dig ones).
# The team gives a target with vn_assign({"key", "kind", "i", "pos"}) (a meteor core or a rich vein on
# this planet). The bot walks to the ground over the target's nearest still-solid part
# (Veins.solid_point_near, re-picked every VN_TEAM_SCAN s or once reached), then digs toward it with a
# real brush (VN_BOT_DIG_R, VN_BOT_DIG_RATE; Dig.dig_at with the team: synced, logged for the scanner),
# stepping into the hole behind its face. After each brush the share of the target that turned to air
# is worth Veins.take_gain × VN_BOT_GATHER to the team pool (team_node.vn_bonus). Done when the target
# is dug out / gone, after VN_BOT_TIMEOUT s or when the team calls it off (vn_clear); under soil it
# digs itself out ("exit"). A fight interrupts it like any work (combat stops the brush; the target
# stays, it goes back afterwards).

const VnVeins := preload("res://scripts/planet/veins.gd")

var _vn_tgt := {}
var _vn_q := Vector3.INF               # the solid point it digs toward (world)
var _vn_q_ms := -100000
var _vn_t0 := 0
var _vn_on := false                    # its brush is on (_dig_shaft -> _vn_dig_tick)


func vn_target_key() -> String:
	return str(_vn_tgt.get("key", ""))


func vn_assign(t: Dictionary) -> void:
	_vn_tgt = t.duplicate()
	_vn_q = Vector3.INF
	_vn_q_ms = -100000
	_vn_t0 = _now()
	_vn_on = false


func vn_clear() -> void:
	if _vn_tgt.is_empty():
		return
	_vn_tgt = {}
	_vn_q = Vector3.INF
	_vn_brush(false)
	if _job == "vn":
		_set_job("")


## From _think_work: walks to / digs at the target; false lets the rest of the work run this think.
func _vn_think() -> bool:
	if team_node == null or team == "home" or body == null:
		vn_clear()
		return false
	var now := _now()
	if now - _vn_t0 > int(Balance.VN_BOT_TIMEOUT * 1000.0):
		_vn_finish()
		return false
	if _job != "vn":
		_set_job("vn")
		_vn_on = false
	_set_held("terrain")
	if _vn_q == Vector3.INF or now - _vn_q_ms > int(Balance.VN_TEAM_SCAN * 1000.0):
		_vn_q_ms = now
		_vn_q = VnVeins.solid_point_near(body, int(_vn_tgt.get("kind", 0)), int(_vn_tgt.get("i", -1)), global_position)
		if _vn_q == Vector3.INF:
			_vn_finish()
			return false
	var up := _up()
	var to := _vn_q - global_position
	var flat := to - up * to.dot(up)
	if flat.length_squared() > 0.04:
		_face = flat.normalized()
	if flat.length() > 2.6 and not _vn_on:
		# Not there yet: walk to the ground over it.
		_vn_brush(false)
		_walk_to(_ground_at(_on_sphere(_vn_q)), Balance.AI_WALK_SPEED)
		return true
	_move_to = Vector3.INF
	_vn_brush(true)
	return true


## One prospecting brush (AI_DIG_HZ): toward the solid point, the first ground on the way; too far: a
## step toward that face first.
func _vn_dig_tick(dt: float) -> bool:
	if mode != Mode.WORK or _vn_tgt.is_empty() or _vn_q == Vector3.INF:
		_vn_brush(false)
		return true
	var up := _up()
	var eye := global_position + up * 1.2
	var dir := _vn_q - eye
	if dir.length_squared() < 0.01:
		dir = -up
	var h: Dictionary = body.raycast_density(eye, _vn_q + dir.normalized() * 0.4, 0.3, false)
	var p: Vector3 = h["position"] if not h.is_empty() else _vn_q
	_dig_point = p
	_dig_normal = h["normal"] if not h.is_empty() else up
	if eye.distance_to(p) > 3.3:
		_move_to = p
		_move_speed = Balance.AI_WALK_SPEED * 0.6
		_strafe = Vector3.ZERO
		return true
	_move_to = Vector3.INF
	var soil := Dig.dig_at(body, p, Balance.VN_BOT_DIG_R, Dig.MODE_DIG, Balance.VN_BOT_DIG_RATE * dt, Vector3.ZERO, Vector3.UP,
			-1.0, team)
	if soil > 0.0:
		var gain := VnVeins.take_gain(body, int(_vn_tgt.get("kind", 0)), int(_vn_tgt.get("i", -1)))
		if gain > 0.0 and team_node.has_method("vn_bonus"):
			team_node.vn_bonus(gain * Balance.VN_BOT_GATHER)
	if p.distance_to(_vn_q) < Balance.VN_BOT_DIG_R * 0.8:
		_vn_q_ms = -100000                     # reached: a new solid point next think
	if not _mine_audio.playing and _rng.randf() < 0.3:
		_play(_mine_audio)
	return true


func _vn_brush(on: bool) -> void:
	if on == _vn_on and (not on or _digging):
		return
	_vn_on = on
	if on:
		_digging = true
		_shaft = true
		_dig_acc = 0.0
		_play(_dig_audio)
	else:
		_stop_dig()


## The target is done: let go; under soil, dig out.
func _vn_finish() -> void:
	vn_clear()
	if mode == Mode.WORK and _dg_task == "" and _dg_buried():
		dg_assign("exit")


# =================================================================================================
# Bölge kontrolü (scripts/war/control_points.gd; tunables: balance.gd "Bölge kontrolü")
# =================================================================================================
# Hooks above (one line each): _pod_site -> _cp_raid (a pod crew member that is not the shaft digger
# walks into our nearest zone within CP_RAID_RANGE and stands in it; combat goes on as usual);
# _pick_guard_point -> _cp_guard_point (a guard heads for one of its team's zones on its planet that
# is lost, being taken or contested).

func _cp_raid() -> bool:
	var cpn = get_tree().get_first_node_in_group("control_points")
	if cpn == null:
		return false
	var p: Vector3 = cpn.raid_target(self)
	if p == Vector3.INF:
		return false
	if _job != "raid_guard":
		_set_job("raid_guard")
	_set_held("rifle")
	_walk_to(_ground_at(p), Balance.AI_WALK_SPEED)
	return true


func _cp_guard_point() -> Vector3:
	var cpn = get_tree().get_first_node_in_group("control_points")
	if cpn == null:
		return Vector3.INF
	var p: Vector3 = cpn.guard_target(self)
	return _ground_at(p) if p != Vector3.INF else Vector3.INF


# =================================================================================================
# Downed / revive (2026-10-07; scripts/war/downed.gd holds the state, revive.gd picks the medics)
# =================================================================================================
# A lethal hit that is not overkill puts the bot DOWN (take_damage -> Downed.try_down): mode COMBAT
# with no target (no team task finds it free: wx_available / dg_free need WORK; not DEAD: still a
# body, is_dead() false), its tasks dropped, the held item away, no thinking or shooting. It lies in
# the downed pose (downed_pose.gd, posed here every frame) with the hit capsule along the body and
# crawls at DN_CRAWL_SPEED toward its medic or away from the threat (Downed.crawl_goal, at most
# DN_BOT_CRAWL_MAX m); a player's strap moves it (downed.gd). Hits drain its bleed-out
# (Downed.hurt_downed); bled out / finished: downed.gd calls _dn_on_dead, then the normal _die (the
# corpse ragdoll from the lying pose, the respawn). Revived: downed.gd blends the get-up, _dn_on_up
# gives the controls back at DN_REVIVE_HP.
# Medic (rare, deliberate "tok"): revive.gd sends the nearest free teammate (_dn_medic_free); it walks
# over (runs when far), crouches beside the body and holds the revive (Downed.begin_revive auto); a
# hit or something in sight and it lets go (revive.gd medic_release -> _dn_medic_end).
# Targets: enemies leave a downed unit alone unless they are its finisher (Downed.target_ok); they
# aim at the lying chest (Downed.aim_point).

var _dn_held := ""                     # the item it held when it went down


## _physics_process: true while down / getting up (nothing else runs).
func _dn_physics(delta: float) -> bool:
	if Downed.is_rising(self):
		return true
	if not Downed.is_downed(self):
		return false
	if _reactor != null and _reactor.busy():
		_reactor.reset()
	if Downed.dragger_of(self) != null:
		_tick_acc = 0.0
		return true                        # (downed.gd moves the body by the strap)
	var tick: float = TICKS[lod]
	_tick_acc += delta
	if _tick_acc >= tick:
		_tick_acc = minf(_tick_acc - tick, tick)
		var g: Vector3 = Downed.crawl_goal(self)
		_move_to = g
		_move_speed = Balance.DN_CRAWL_SPEED
		_strafe = Vector3.ZERO
		_knock = Vector3.ZERO
		sep = Vector3.ZERO
		_sep_s = Vector3.ZERO
		if g != Vector3.INF:
			_face = g - global_position
		var p0 := _sim_xf.origin
		_tick(tick)
		Downed.add_crawled(self, p0.distance_to(_sim_xf.origin))
	return true


## _process: true while down / getting up (the downed pose / downed.gd's get-up instead of the animation).
func _dn_process(delta: float) -> bool:
	var down := Downed.is_downed(self)
	if not down and not Downed.is_rising(self):
		return false
	if down:
		if Downed.dragger_of(self) == null:
			_show_interpolated(delta)
		Downed.pose_step(self, delta)
		_cap_cs.transform = Downed.LYING_CAP_XF
	astronaut.position = Vector3.ZERO
	astronaut.sync_skeleton()
	return true


## _think: a medic on its way / reviving (true: nothing else this think).
func _dn_think(_dt: float) -> bool:
	var u = Revive.medic_task(self)
	if u == null:
		return false
	if _target_visible or _now() - _hurt_ms < int(Balance.DN_MEDIC_SAFE * 1000.0):
		Revive.medic_release(self)         # shot at / something in sight: back to the fight
		return false
	var c: Vector3 = Downed.body_center(u)
	var up := _up()
	var to := c - global_position
	to -= up * to.dot(up)
	if not Downed.in_reach(u, self, -0.5):
		_crouch = false
		_walk_to(_ground_at(c), Balance.AI_RUN_SPEED if to.length() > 8.0 else Balance.AI_WALK_SPEED)
		if to.length_squared() > 1e-4:
			_face = to.normalized()
		return true
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_crouch = true                         # down on a knee beside the body
	if to.length_squared() > 1e-4:
		_face = to.normalized()
	if Downed.reviver_of(u) != self:
		Downed.begin_revive(u, self, true)
	return true


## revive.gd: may this bot go and revive someone now (nothing in sight, not hit lately, no task)?
func _dn_medic_free() -> bool:
	if mode == Mode.DEAD or mode == Mode.ABOARD or _target_visible or _climb or _air or sliding:
		return false
	var now := _now()
	if now - _hurt_ms < int(Balance.DN_MEDIC_SAFE * 1000.0) or now - _seen_ms < 3000:
		return false
	return _wx_task == "" and not _wx_throwing and _dg_task == "" and (_pod_phase == "" or _pod_phase == "site") \
			and _job != "fire" and _job != "build"


## revive.gd: the medic job is over (done, shot at, gave up).
func _dn_medic_end() -> void:
	_crouch = false
	_move_to = Vector3.INF
	_think_acc = 1.0


## downed.gd: it just went down.
func _dn_on_down() -> void:
	_dn_held = _held
	Revive.medic_release(self)
	wx_clear_task()
	dg_clear()
	if _wx_throwing:
		_hr_drop_grenade()                 # a grenade being wound up drops, live
	_set_job("")
	_stop_dig()
	_set_held("")
	shooting_skiff = false
	_target = null
	_target_visible = false
	_crouch = false
	_crouch_k = 0.0
	_climb = false
	_air = false
	_vy = 0.0
	_end_slide(false)
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_knock = Vector3.ZERO
	_hv = Vector3.ZERO
	velocity = Vector3.ZERO
	_tracer.visible = false
	_fire_vis = 0.0
	mode = Mode.COMBAT                     # (not WORK: no team task takes it; not DEAD: still a body)
	set_light(false)
	if _reactor != null:
		_reactor.reset()                   # (frees a knockdown ragdoll, clears the lethal hit's pending hits)
	_ragdoll = null
	_cap.height = Downed.LYING_CAP_H
	_cap_cs.transform = Downed.LYING_CAP_XF
	_pose_pos = Vector3.INF
	_radio_call("down")


## downed.gd: revived (the get-up starts; _dn_on_up when it is done).
func _dn_on_revived() -> void:
	_cap.height = 1.8
	_cap_cs.transform = Transform3D(Basis(), Vector3(0, 0.9, 0))
	_hurt_ms = _now()                      # (no regen at once)
	if _reactor != null:
		_reactor.reset()


## downed.gd: the get-up is done: back in control with its item.
func _dn_on_up() -> void:
	_set_held(_dn_held if _dn_held != "" else "rifle")
	_pose_pos = Vector3.INF
	_hv = Vector3.ZERO
	velocity = Vector3.ZERO
	_air = false
	_vy = 0.0
	_flinch = 0.0
	_think_acc = 1.0                       # decide right away
	astronaut.animate(0.016, {"speed": 0.0, "grounded": true, "probe": false})
	astronaut.sync_skeleton()


## downed.gd: dead for real (bled out / finished): the capsule upright again before _die.
func _dn_on_dead() -> void:
	_cap.height = 1.8
	_cap_cs.transform = Transform3D(Basis(), Vector3(0, 0.9, 0))
	Revive.medic_release(self)


## A downed target is left alone unless this bot is its finisher (Downed.target_ok). True = skip it.
func _dn_skip_target(n) -> bool:
	if not Downed.is_downed(n) or Downed.target_ok(n, self):
		return false
	if _target == n:
		_target = null
		_target_visible = false
	return true
