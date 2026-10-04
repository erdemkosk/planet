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
const Core := preload("res://scripts/war/core.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const VM := preload("res://scripts/player/vm_parts.gd")

const ROLE_MINER := 0
const ROLE_ENGINEER := 1
const ROLE_RAIDER := 2
const ROLE_NAMES := ["Kazıcı", "Mühendis", "Akıncı"]
const ROLE_COLORS := [Color(1.0, 0.62, 0.15), Color(0.95, 0.9, 0.3), Color(1.0, 0.16, 0.1)]

enum Mode { WORK, COMBAT, ABOARD, DEAD }
enum Tac { NONE, STRAFE, TO_COVER, COVER, ADVANCE, HOLD, FLEE }
const MODE_NAMES := ["çalışıyor", "çatışmada", "mekikte", "ölü"]

const TICKS := [1.0 / 15.0, 1.0 / 8.0, 0.25]          # movement step per LOD
const THINK_WORK := [0.25, 0.5, 0.8]
const THINK_COMBAT := [0.125, 0.5, 0.75]
const POSE_RATE := [0.0, 1.0 / 12.0, 1.0 / 3.0]         # 0 = every frame
const DIG_COLOR := Color(1.0, 0.45, 0.2)
const REPAIR_COLOR := Color(0.4, 0.85, 1.0)
const EYE_H := 1.55
const CROUCH_DROP := 0.38
const STEP_MAX := 0.55
const COVER_DIRS := 8
const COVER_RADII := [5.0, 9.0, 14.0]
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
# Set by the team (budgets / LOD).
var lod := 2
var cam_dist := 1000.0
var tok_audio := false
var tok_shoot := false
var tok_brush := false

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
var _vis_pos := Vector3.ZERO
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
	body = Game.rival
	_vis_pos = global_position
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
			(gi as Label3D).text = "RAKİP"


func _build_rifle_prop() -> void:
	var hands: Array = astronaut.hand
	if hands.size() < 2 or hands[1] == null:
		return
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.75, 0.3, 0.25)
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
	if r == ROLE_RAIDER and not Balance.RAIDS_ENABLED:
		nm = "Muhafız"
	callsign = "Rakip — %s" % nm
	if _col == null:
		return
	_col.set_meta("callsign", callsign)
	var c: Color = ROLE_COLORS[r]
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


## In a fight with the player (or his skiff) in sight: asks the team for a shooter token.
func wants_to_shoot() -> bool:
	if mode != Mode.COMBAT or not _target_visible or _target == null or not is_instance_valid(_target):
		return false
	return _target == Game.player or _target.is_in_group("skiff")


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
	_flinch = maxf(_flinch - delta, 0.0)
	if hp < hp_max and _now() - _hurt_ms > int(Balance.AI_REGEN_DELAY * 1000.0):
		hp = minf(hp + Balance.AI_REGEN * delta, hp_max)
	var tick: float = TICKS[lod]
	_tick_acc += delta
	if _tick_acc >= tick:
		_tick(minf(_tick_acc, 0.3))
		_tick_acc = 0.0
	_think_acc += delta
	var period: float = THINK_COMBAT[lod] if mode == Mode.COMBAT else THINK_WORK[lod]
	if _think_acc >= period:
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
	_vis_pos = _vis_pos.lerp(global_position, 1.0 - exp(-(14.0 if lod == 0 else 8.0) * delta))
	_crouch_k = move_toward(_crouch_k, 1.0 if _crouch else 0.0, delta * 4.5)
	var b := global_transform.basis
	astronaut.position = b.inverse() * (_vis_pos - global_position) + Vector3(0, -CROUCH_DROP * _crouch_k, 0)
	_fire_vis = maxf(_fire_vis - delta, 0.0)
	_tracer_t = maxf(_tracer_t - delta, 0.0)
	if _tracer_t <= 0.0 and _tracer.visible:
		_tracer.visible = false
	if _flash_t > 0.0:
		_flash_t = maxf(_flash_t - delta * 12.0, 0.0)
		_flash.light_energy = 5.0 * _flash_t
	# Pose at the LOD rate (slower still off screen).
	var rate: float = POSE_RATE[lod]
	if lod > 0:
		var cam := get_viewport().get_camera_3d()
		if cam != null and not cam.is_position_in_frustum(global_position):
			rate = 0.5
	_pose_acc += delta
	if _pose_acc < rate:
		return
	var dt := _pose_acc
	_pose_acc = 0.0
	if _shadow_lod != lod and _skin_mesh != null:
		_shadow_lod = lod
		_skin_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod < 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hv := velocity - b.y * velocity.dot(b.y)
	var pitch := 0.0
	if _target != null and is_instance_valid(_target) and (mode == Mode.COMBAT or _job == "raid_attack"):
		var d := (_aim_point(_target) - _eye()).normalized()
		pitch = asin(clampf(d.dot(b.y), -1.0, 1.0))
	astronaut.animate(minf(dt, 0.5), {"vel_local": b.inverse() * hv, "vel_up": _vy, "speed": hv.length(),
			"grounded": not _air and not _climb, "jetting": _jet_t > 0.0 or _climb, "jet_power": 1.0,
			"zero_g": false, "pitch": pitch, "holding": _held != "", "two_hand": true,
			"using": _digging or _fire_vis > 0.0 or _job == "repair", "exclude": [_col.get_rid()],
			"probe": lod == 0})
	astronaut.set_tool_color(REPAIR_COLOR if _job == "repair" else DIG_COLOR)
	astronaut.sync_skeleton()


# =================================================================================================
# Movement (kinematic on the density surface, rate by LOD)
# =================================================================================================

func _tick(dt: float) -> void:
	var nb: Node3D = Game.dominant_body(global_position)
	if nb != null:
		body = nb
	var up: Vector3 = body.up_at(global_position)
	var pos := global_position
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
	var gmag: float = Game.gravity_at(pos).length()
	var np := pos
	if _climb:
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
				_vy = 0.0
		elif body.density_at(np + up * 1.8) < 0.0:
			_vy = 0.0
	else:
		if want == Vector3.ZERO:
			# Standing: re-check the ground now and then (every tick while carving a pit).
			_probe_t -= dt
			if _probe_t <= 0.0 or (tok_brush and _digging):
				_probe_t = 0.5
				var g := _probe(pos, up, pos)
				if g["ok"]:
					np = g["pos"]
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
	velocity = (np - pos) / dt
	_still_t = _still_t + dt if velocity.length() < 0.6 else 0.0
	up = body.up_at(np)
	var f := _face - up * _face.dot(up)
	if f.length_squared() < 1e-4:
		f = -global_transform.basis.z
		f = f - up * f.dot(up)
		if f.length_squared() < 1e-4:
			f = up.cross(Vector3.RIGHT)
	var z := -f.normalized()
	var x := up.cross(z).normalized()
	global_transform = Transform3D(Basis(x, up, x.cross(up)), np)


## True when the 16 m edit region holding world point w (or its +1 neighbour) was dug / raised.
func _edited(w: Vector3) -> bool:
	var ed: Dictionary = body.edits
	if ed.is_empty():
		return false
	var v := Vector3i((w - body.global_position).floor())
	return ed.has(Vector3i(v.x >> 4, v.y >> 4, v.z >> 4)) or ed.has(Vector3i((v.x + 1) >> 4, (v.y + 1) >> 4, (v.z + 1) >> 4))


## Ground at p: {"ok", "pos"} when it can step there from `from`, "blocked" for a wall / a step too
## high, neither when there is no ground within 2.5 m below. Unedited ground: the analytic surface
## (one height sample); dug ground: a density march.
func _probe(p: Vector3, up: Vector3, from: Vector3) -> Dictionary:
	var c: Vector3 = body.global_position
	var rel := p - c
	var rl := rel.length()
	if rl > 1.0:
		var surf: Vector3 = c + rel / rl * (float(body.radius) + float(body.surface_height_at(p)))
		if not _edited(surf) and not _edited(p):
			var st := (surf - from).dot(up)
			if st > STEP_MAX:
				return {"ok": false, "blocked": true}
			if st < -2.5:
				return {"ok": false, "blocked": false}
			return {"ok": true, "pos": surf, "blocked": false}
	var h: Dictionary = body.raycast_density(p + up * 1.0, p - up * 2.5, 0.3, true)
	if h.is_empty():
		return {"ok": false, "blocked": false}
	if float(h["distance"]) < 0.01:
		return {"ok": false, "blocked": true}
	var hp_: Vector3 = h["position"]
	if (hp_ - from).dot(up) > STEP_MAX:
		return {"ok": false, "blocked": true}
	return {"ok": true, "pos": hp_, "blocked": false}


func _on_blocked(up: Vector3, tgt: Vector3) -> void:
	if _move_to == Vector3.INF and _strafe != Vector3.ZERO:
		_strafe = -_strafe
		return
	var h: Dictionary = body.raycast_density(tgt + up * 4.5, tgt - up * 1.0, 0.3, true)
	var height := 99.0
	if not h.is_empty() and float(h["distance"]) > 0.01:
		height = ((h["position"] as Vector3) - global_position).dot(up)
	if height < 3.5:
		var g: float = Game.gravity_at(global_position).length()
		_hop(maxf(Balance.AI_JET_HOP, sqrt(2.0 * g * (height + 0.7))), Vector3.ZERO)
	else:
		_climb = true
		_climb_t = 0.0


func _hop(v_up: float, lateral: Vector3) -> void:
	if _air or _climb:
		return
	_air = true
	_vy = v_up
	_jet_t = 0.45
	_knock += lateral


# =================================================================================================
# Thinking
# =================================================================================================

func _think(dt: float) -> void:
	_perceive(dt)
	if mode == Mode.COMBAT:
		_think_combat(dt)
	else:
		_think_work()
	var hh := 1.8 - 0.6 * _crouch_k
	if absf(_cap.height - hh) > 0.05:
		_cap.height = hh
		_cap_cs.position = Vector3(0, hh * 0.5, 0)


func _perceive(dt: float) -> void:
	shooting_skiff = false
	var pl = Game.player
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
		if _target == null or _target == pl or not is_instance_valid(_target) or _target.is_in_group("war_structure"):
			if vis:
				_target = pl
		if _target == pl:
			_target_visible = vis
		if vis:
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
	if _fire_cannon != null and is_instance_valid(_fire_cannon) and _fire_cannon.get_meta("ai_claim", null) == self:
		_fire_cannon.remove_meta("ai_claim")
	if _repair_target != null and is_instance_valid(_repair_target) and _repair_target.get_meta("ai_repair", null) == self:
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
	var lo := Balance.AI_MINE_MIN if role == ROLE_MINER else Balance.AI_MINE_MIN * 0.6
	var hi := Balance.AI_MINE_MAX if role == ROLE_MINER else Balance.AI_MINE_MAX * 0.5
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


func _ground_at(p: Vector3) -> Vector3:
	var up: Vector3 = body.up_at(p)
	var h: Dictionary = body.raycast_density(p + up * 1.6, p - up * 4.0, 0.4, true)
	if h.is_empty():
		h = body.raycast_density(p + up * 1.6, p - up * 40.0, 1.0, true)
	if h.is_empty():
		return p
	return h["position"]


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
	Dig.dig_at(body, _dig_point, Balance.AI_DIG_RADIUS, Dig.MODE_DIG, Balance.AI_DIG_RATE * dt)
	Core.drill_all(get_tree(), _dig_point, Balance.AI_DIG_RADIUS, team, dt)
	if not _mine_audio.playing and _rng.randf() < 0.25:
		_play(_mine_audio)


func _dig_shaft(dt: float) -> void:
	var up: Vector3 = body.up_at(global_position)
	_dig_point = global_position - up * 0.7
	_dig_normal = up
	Dig.dig_at(body, _dig_point, Balance.RAID_DIG_RADIUS, Dig.MODE_DIG, Balance.RAID_DIG_RATE * dt)
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
	var bx: Transform3D = team_node.base_xf
	var up := bx.basis.y
	var toward: Vector3 = team_node.home.global_position - bx.origin
	toward = (toward - up * toward.dot(up)).normalized()
	var side := up.cross(toward).normalized()
	var r: float = float(team_node.build_radius(kind))
	for i in 20:
		var off := toward * _rng.randf_range(4.0, Balance.AI_BUILD_AHEAD) \
				+ side * _rng.randf_range(-Balance.AI_BUILD_SIDE, Balance.AI_BUILD_SIDE)
		if kind == "skiff":
			off = toward * _rng.randf_range(-Balance.AI_BUILD_AHEAD * 1.3, -Balance.AI_BUILD_AHEAD * 0.6) \
					+ side * _rng.randf_range(-Balance.AI_BUILD_SIDE * 0.8, Balance.AI_BUILD_SIDE * 0.8)
		var p := _ground_at(bx.origin + off + up * 4.0)
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
			var q := _ground_at(p + (tx * cos(a) + toward * sin(a)) * r * 0.8 + pu * 3.0)
			var hh := (q - p).dot(pu)
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
	for s in team_node.cannons + team_node.flaks:
		if not is_instance_valid(s) or s.is_destroyed:
			continue
		var who = s.get_meta("ai_repair", null)
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
		var who = c.get_meta("ai_claim", null)
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
		for grp in ["war_cannon", "war_flak"]:
			for s in get_tree().get_nodes_in_group(grp):
				if s.team == "home" and not s.is_destroyed:
					theirs.append(s)
		if not theirs.is_empty():
			return (theirs[_rng.randi() % theirs.size()] as Node3D).global_position
	var dir: Vector3 = (team_node.body.global_position - home.global_position).normalized()
	var r: float = float(home.radius) + float(home.surface_height_at(home.global_position + dir * float(home.radius)))
	return home.global_position + dir * r + team_node.correction


func _start_solve(from: Vector3, target: Vector3) -> void:
	_solve = {"from": from, "target": target, "i": 0, "best_v": Vector3.ZERO, "best_d": INF}


func _step_solve() -> void:
	var speeds: Array = Balance.AI_SOLVE_SPEEDS
	var n_el := 22
	var i: int = _solve["i"]
	if i >= speeds.size() * n_el:
		var bv: Vector3 = _solve["best_v"]
		if float(_solve["best_d"]) > Balance.AI_SOLVE_MAX_MISS:
			bv = Vector3.ZERO
		_solved_v = _apply_error(bv) if bv != Vector3.ZERO else Vector3.ZERO
		_solved = true
		_solve = {}
		return
	var spd := lerpf(Balance.CANNON_SPEED_MIN, Balance.CANNON_SPEED_MAX, float(speeds[i / n_el]))
	var el := lerpf(Balance.CANNON_PITCH_MIN + 3.0, Balance.CANNON_PITCH_MAX - 3.0, float(i % n_el) / float(n_el - 1))
	var v := Ballistics.launch_vector(_solve["from"], _solve["target"], spd, el)
	var r := Ballistics.predict(_solve["from"], v, Balance.SHELL_LIFE, 0.1)
	if not r.is_empty() and r.get("body") == team_node.home:
		var d := (r["position"] as Vector3).distance_to(_solve["target"])
		if d < float(_solve["best_d"]):
			_solve["best_d"] = d
			_solve["best_v"] = v
	_solve["i"] = i + 1


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
		var c: Vector3 = team_node.correction - (point - target) * 0.6
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
			_set_held("terrain")
			_think_gather()


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
	var structs: Array = team_node.cannons + team_node.flaks
	if not structs.is_empty() and _rng.randf() < 0.5:
		var s = structs[_rng.randi() % structs.size()]
		if is_instance_valid(s):
			var c: Vector3 = (s as Node3D).global_position
			var up: Vector3 = body.up_at(c)
			var x := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
			var z := up.cross(x).normalized()
			var a := _rng.randf() * TAU
			return _ground_at(c + (x * cos(a) + z * sin(a)) * _rng.randf_range(6.0, 14.0) + up * 3.0)
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
	if sk.has_method("ai_board"):
		sk.ai_board(self)
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
			xf = sk.ai_exit()
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
	var t = team_node
	var digger: bool = t.raid_digger() == self
	var s := _nearest_enemy_structure(Balance.RAID_STRUCT_RANGE)
	var calm := _now() - _threat_ms > int(Balance.RAID_CALM_TIME * 1000.0) and _now() - _seen_ms > int(Balance.RAID_CALM_TIME * 1000.0)
	var solo: bool = t.raiders.size() <= 1
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
	for grp in ["war_cannon", "war_flak"]:
		for s in get_tree().get_nodes_in_group(grp):
			if s.team == team or s.is_destroyed:
				continue
			var d := (s as Node3D).global_position.distance_to(global_position)
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
	if _target == Game.player or (_target != null and is_instance_valid(_target) and _target.is_in_group("skiff")):
		_target = null
	_target_visible = false
	_job = ""


func help_call(threat: Vector3) -> void:
	if mode != Mode.WORK:
		return
	_threat_ms = _now() - 1500
	_enter_combat(threat)
	_tac = Tac.ADVANCE
	_tac_t = 4.0
	_move_to = threat
	_move_speed = Balance.AI_RUN_SPEED


func _on_threat(src: Vector3, hit: bool) -> void:
	if mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	_threat_ms = _now()
	if src != Vector3.INF:
		_threat_pos = src
	if mode == Mode.WORK:
		_enter_combat(_threat_pos if _threat_pos != Vector3.INF else global_position)
	if not (_tac == Tac.COVER and _crouch) and _tac != Tac.FLEE and _tac != Tac.TO_COVER:
		_tac_t = 0.0
		_think_acc = 1.0
	if not hit and _rng.randf() < Balance.AI_DODGE_CHANCE and not _air and not _climb:
		var up := _up()
		var side := up.cross(_threat_pos - global_position).normalized() * (1.0 if _rng.randf() < 0.5 else -1.0)
		_hop(Balance.AI_JET_HOP * 0.8, side * 4.0)


func _on_shot(from: Vector3, dir: Vector3, t: String) -> void:
	if t == team or mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	var c := global_position + global_transform.basis.y * 1.1
	var rel := c - from
	var along := rel.dot(dir)
	if along < 0.0 or along > 400.0:
		return
	if (rel - dir * along).length() < Balance.AI_NEAR_MISS:
		_on_threat(from, false)


func _on_blast(pos: Vector3, radius: float, t: String) -> void:
	if t == team or mode == Mode.DEAD or mode == Mode.ABOARD:
		return
	var d := global_position.distance_to(pos)
	if d > maxf(radius * 3.0, 12.0):
		return
	var src := pos
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and Game.dominant_body(pl.global_position) == body \
			and pl.global_position.distance_to(global_position) < Balance.AI_SIGHT_RANGE:
		src = pl.global_position + pl.global_transform.basis.y * 1.2
	_knock += (global_position - pos).normalized() * clampf(6.0 - d * 0.3, 0.0, 4.0)
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
	if _target == Game.player and Game.player.is_dead():
		_target = null
		_target_visible = false
	var calm := Balance.AI_CALM_AFTER * 1000.0
	if not _target_visible and now - _threat_ms > int(calm) and now - _seen_ms > int(calm):
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
	var low := hp < hp_max * Balance.AI_FLEE_HP
	var threat := _threat_pos if _threat_pos != Vector3.INF else global_position
	var up := _up()
	var to_t := threat - global_position
	var dist := to_t.length()
	if _target_visible or under_fire:
		_face = to_t.normalized()
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
		Tac.HOLD:
			_crouch = false
			_move_to = Vector3.INF
			_strafe = Vector3.ZERO
			if under_fire or _tac_t <= 0.0:
				_tac = Tac.NONE
	if _tac == Tac.NONE:
		_decide(threat, dist, under_fire)


## A new tactic. Far bots (lod > 0) keep it simple: no cover search, close in / strafe; bots
## without a shooter token keep moving (flank, advance) instead of holding.
func _decide(threat: Vector3, dist: float, under_fire: bool) -> void:
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
	_tac_t = t
	_strafe = dir
	_strafe_speed = spd
	_move_to = Vector3.INF
	_crouch = false


func _request_cover(threat: Vector3, away: bool) -> void:
	_cover_search = {"threat": threat, "i": 0, "best": Vector3.INF, "best_s": -INF, "away": away}


## Tests up to 4 cover candidates per think (as many as the team's per-frame budget allows).
func _step_cover_search() -> void:
	if _cover_search.is_empty():
		return
	var budget: int = team_node.take_cover_eval(4) if team_node != null else 4
	if budget <= 0:
		return
	var threat: Vector3 = _cover_search["threat"]
	var away: bool = _cover_search["away"]
	var up := _up()
	var x := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var z := up.cross(x).normalized()
	var total := COVER_DIRS * COVER_RADII.size()
	var d_now := global_position.distance_to(threat)
	for k in budget:
		var i: int = _cover_search["i"]
		if i >= total:
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
	if int(_cover_search["i"]) >= total:
		_cover_pos = _cover_search["best"]
		_cover_search = {}
		if _cover_pos != Vector3.INF and (_tac == Tac.STRAFE or _tac == Tac.NONE):
			_tac = Tac.TO_COVER
			_tac_t = 5.0


func _aim_point(n: Node3D) -> Vector3:
	if n == Game.player:
		return n.global_position + n.global_transform.basis.y * 1.2
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
	if tg == null or not is_instance_valid(tg) or not _target_visible:
		return
	var vs_player: bool = tg == Game.player or tg.is_in_group("skiff")
	if vs_player and not tok_shoot:
		return
	if _flinch > 0.0 or _climb or (_air and _vy > 1.0) or (_crouch_k > 0.5 and not _peek):
		return
	if _move_to != Vector3.INF and _move_speed >= Balance.AI_RUN_SPEED * 0.9 and velocity.length() > 3.0:
		return
	if _rifle_t > 0.0:
		return
	if _mag <= 0:
		_reload_t = Balance.AI_RELOAD
		_burst = 0
		return
	if _burst <= 0:
		_burst = Balance.AI_RIFLE_BURST
	_burst -= 1
	_rifle_t = Balance.AI_RIFLE_INTERVAL if _burst > 0 else Balance.AI_RIFLE_PAUSE * _rng.randf_range(0.8, 1.3)
	_mag -= 1
	var me := _eye()
	var aimp := _aim_point(tg)
	var to := aimp - me
	var dist := to.length()
	var is_pl: bool = tg == Game.player
	var structure: bool = tg.is_in_group("war_structure") and not tg.is_in_group("skiff")
	var rng_max := Balance.AI_SKIFF_RIFLE_RANGE if tg.is_in_group("skiff") else Balance.AI_FIGHT_RANGE
	var chance := Balance.AI_RIFLE_HIT * (1.0 - 0.5 * clampf(dist / rng_max, 0.0, 1.0))
	if velocity.length() > 1.0:
		chance *= Balance.AI_ACC_MOVING
	if _now() - _threat_ms < 2000:
		chance *= Balance.AI_ACC_UNDER_FIRE
	if _still_t > 1.0:
		chance *= Balance.AI_ACC_SETTLED
	var tv = tg.get("velocity") if is_pl else tg.get("linear_velocity")
	if tv is Vector3:
		chance *= clampf(1.0 - (tv as Vector3).length() / 30.0, 0.35, 1.0)
	if structure:
		chance = 0.8
	var end := aimp
	if _rng.randf() < clampf(chance, 0.03, 0.9):
		var dmg := Balance.AI_RIFLE_DAMAGE
		if structure:
			dmg = Balance.AI_RIFLE_STRUCT_DAMAGE
		elif not is_pl:
			dmg = Balance.AI_SKIFF_RIFLE_DAMAGE
		Game.damage_target(tg, dmg, me, to.normalized() * (0.6 if is_pl else 0.0), team)
	else:
		var miss := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * clampf(dist * 0.06, 0.6, 4.0)
		end = aimp + miss + to.normalized() * 6.0
	var tip: Node3D = astronaut.held_tip("rifle")
	var muzzle: Vector3 = tip.global_position if tip != null else me
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


# =================================================================================================
# Health
# =================================================================================================

func take_damage(amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO) -> Dictionary:
	if mode == Mode.DEAD or mode == Mode.ABOARD or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	hp = maxf(hp - amount, 0.0)
	_hurt_ms = _now()
	if hp > 0.0:
		_flinch = Balance.AI_FLINCH
		var up := _up()
		var kick := impulse - up * impulse.dot(up)
		_knock += kick.limit_length(3.0) + (global_position - from_pos).normalized() * 0.8 if from_pos != Vector3.ZERO else kick.limit_length(3.0)
		_on_threat(from_pos if from_pos != Vector3.ZERO else Vector3.INF, true)
		if team_node != null and team_node.raid_phase(self) == "site" and hp < hp_max * Balance.RAID_RETREAT_HP:
			team_node.raid_retreat()
		return {"dmg": amount, "killed": false}
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
	mode = Mode.DEAD
	_dead_t = 0.0
	_move_to = Vector3.INF
	_strafe = Vector3.ZERO
	_cap_cs.disabled = true
	set_light(false)
	if team_node != null:
		team_node.on_bot_died(self)
	_rag_frozen = false
	_ragdoll = Ragdoll.new()
	get_parent().add_child(_ragdoll)
	_ragdoll.no_float_recover = true
	_ragdoll.start(self, velocity + impulse, 60.0, [], false)
	_ragdoll.finished.connect(_on_ragdoll_settled)
	if team_node != null:
		team_node.add_ragdoll(_ragdoll)
	if Game.hud and cam_dist < 120.0:
		Game.hud.show_message("%s düştü!" % callsign, 2.0)


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
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null
	visible = true
	astronaut.transform = Transform3D.IDENTITY
	astronaut.reset_pose()
	hp = hp_max
	_mag = Balance.AI_MAG
	_reload_t = 0.0
	body = Game.rival
	transform = team_node.respawn_xf(index) if team_node != null else transform
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
