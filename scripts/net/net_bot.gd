extends Node3D
## A rival bot on a multiplayer CLIENT: the look of the host's ai_rival.gd bot, driven by its 10 Hz
## snapshots (net_bots.gd), ~150 ms behind and interpolated. Astronaut with the role light on the
## chest, the rifle / drill prop, walk / crouch / jet animation and aim pitch (pose rate by
## distance like the host's LOD), the drill beam (DigFx) + hum while digging, muzzle flash + tracer
## + 3D shot sound, a ragdoll when it dies, the name tag ("Rakip — Kazıcı") through war_hud.gd.
## Hits on it become claims to the host (Game.damage_target -> net_world.gd claim_damage).
## Hit reactions (the host bot's hit_reactor.gd, net_bots.gd -> react -> net_react.gd): the flinch at
## the struck part, the stagger pose, the knockdown ragdoll (the snapshots are ignored while down; the
## host's node lies still until its get-up), the get-up where this puppet lies, and the corpse launched
## like the host's (the whole launch: a uniform share + the rest into the torso at the struck part).
## The death comes with the host's clock: older "alive" snapshots still in the buffer don't revive it.

const Astronaut := preload("res://scripts/player/astronaut.gd")
const Ragdoll := preload("res://scripts/player/ragdoll.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const VM := preload("res://scripts/player/vm_parts.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const SnapBuffer := preload("res://scripts/net/snap_buffer.gd")
const NetReact := preload("res://scripts/net/net_react.gd")
const Corpse := preload("res://scripts/war/corpse.gd")

const ENEMY_FIRE_PATH := "res://scripts/war/enemy_fire.gd"
const CUES_PATH := "res://scripts/war/bot_cues.gd"
const DEATH_FIX_MS := 600          # the host's death launch this soon after a snapshot-started death corrects it
const ROLE_COLORS := [Color(1.0, 0.62, 0.15), Color(0.95, 0.9, 0.3), Color(1.0, 0.16, 0.1), Color(0.9, 0.9, 0.9)]
const DIG_COLOR := Color(1.0, 0.45, 0.2)
const REPAIR_COLOR := Color(0.4, 0.85, 1.0)
const SLIDE_SPEED := 3.0           # m/s: a crouched bot on the ground faster than this is sliding

var index := 0
var team := "rival"
var callsign := "Rakip"
var hp := 100.0
var hp_max := 100.0
var shooting_skiff := false
## The host bot's gun wears a suppressor (ai_rival.gd `suppressed`, once the spawn data carries it):
## no muzzle star, a quiet report, no radar ping (scripts/war/shot_pings.gd). False until synced.
var suppressed := false
var astronaut
var dead := false

var _buf := SnapBuffer.new()
var _col: StaticBody3D
var _cap_cs: CollisionShape3D
var _role_mat: StandardMaterial3D
var _lamp: OmniLight3D
var _role := -1
var _held := ""
var _fx = null
var _dig_audio: AudioStreamPlayer3D
var _gun_audio: AudioStreamPlayer3D
var _tracer: MeshInstance3D
var _tracer_mesh: ImmediateMesh
var _tracer_t := 0.0
var _flash: OmniLight3D
var _flash_t := 0.0
var _fire_vis := 0.0
var _ragdoll = null
var _pose_acc := 0.0
var _crouch_k := 0.0
var _slide_k := 0.0
var _vel := Vector3.ZERO
var _prev_pos := Vector3.INF
var _have := false
var _throw_t := -1.0                # grenade wind-up / throw clock (bot_action "grenade")
var _gprop: Node3D = null
var _react = NetReact.new()         # hit reactions mirrored (react)
var _sup := 0.0                     # the host bot's suppression 0..1 (snapshots)
var _death_ms := -1                 # host clock of the death: "alive" snapshots up to it don't revive
var _fallback_v := Vector3.INF      # launch of a snapshot-started death (no host event yet)
var _fallback_ms := 0
var _fix := Vector3.ZERO            # position blend after our get-up (our ragdoll lay elsewhere than the host's)
var _fix_pending := false


func _ready() -> void:
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_ai")
	top_level = true
	name = "NetBot%d" % index
	hp_max = float(load("res://scripts/war/balance.gd").AI_HP)
	hp = hp_max
	astronaut = Astronaut.new()
	add_child(astronaut)
	astronaut.set_first_person(false)
	astronaut.set_process(false)
	_build_rifle_prop()
	_role_mat = StandardMaterial3D.new()
	_role_mat.albedo_color = Color(0.1, 0.1, 0.1)
	_role_mat.emission_enabled = true
	_role_mat.emission_energy_multiplier = 3.0
	VM.box(astronaut.chest, Vector3(0, 0.2, 0.29), Vector3(0.06, 0.16, 0.01), _role_mat)
	_lamp = OmniLight3D.new()
	_lamp.omni_range = 3.5
	_lamp.light_energy = 1.4
	_lamp.shadow_enabled = false
	_lamp.visible = false
	astronaut.head.add_child(_lamp)
	_lamp.position = Vector3(0, 0.25, -0.15)
	for n in astronaut.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if gi is MeshInstance3D and (gi as MeshInstance3D).skin != null:
			continue
		gi.visibility_range_end = 45.0
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if gi is Label3D:
			(gi as Label3D).text = "RAKİP"
	_col = StaticBody3D.new()
	_col.collision_layer = Game.LAYER_PLAYER
	_col.collision_mask = 0
	_col.set_meta("ai_bot", self)
	_col.set_meta("callsign", callsign)
	_cap_cs = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	_cap_cs.shape = cap
	_cap_cs.position = Vector3(0, 0.9, 0)
	_col.add_child(_cap_cs)
	add_child(_col)
	_react.setup(self, astronaut, _cap_cs, [_col], false)
	_react.recovered.connect(_on_recovered)
	_dig_audio = _audio3d(Snd.loop("ship/dig_beam"), 10.0, 160.0)
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
	_tracer.custom_aabb = AABB(Vector3.ONE * -2000.0, Vector3.ONE * 4000.0)
	add_child(_tracer)
	_tracer.global_transform = Transform3D.IDENTITY
	visible = false
	_buf.delay_ms = 160.0
	_buf.max_extra_ms = 250.0


func _audio3d(stream: AudioStream, unit: float, max_d: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.unit_size = unit
	p.max_distance = max_d
	p.max_polyphony = 1
	add_child(p)
	return p


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


func set_callsign(cs: String) -> void:
	callsign = cs
	if _col != null:
		_col.set_meta("callsign", cs)


func is_dead() -> bool:
	return dead


func is_aboard() -> bool:
	return false


## Hits are the host's (claims); this only keeps the damageable contract.
func take_damage(amount: float, _from_pos := Vector3.ZERO, _impulse := Vector3.ZERO) -> Dictionary:
	return {"dmg": amount if not dead else 0.0, "killed": false}


func push(s: Dictionary) -> void:
	_buf.push(int(s["t"]), s)
	if not _have:
		_have = true
		visible = true
		_place(s["pos"], s["up"], s["fwd"])


func _place(pos: Vector3, up: Vector3, fwd: Vector3) -> void:
	var f := fwd - up * fwd.dot(up)
	if f.length_squared() < 1e-6:
		f = up.cross(Vector3.RIGHT)
	var z := -f.normalized()
	var x := up.cross(z).normalized()
	global_transform = Transform3D(Basis(x, up, x.cross(up)), pos)


func _process(delta: float) -> void:
	_tracer_t = maxf(_tracer_t - delta, 0.0)
	if _tracer_t <= 0.0 and _tracer.visible:
		_tracer.visible = false
	_flash_t = maxf(_flash_t - delta * 12.0, 0.0)
	_flash.light_energy = 5.0 * _flash_t
	_flash.visible = _flash_t > 0.01
	_fire_vis = maxf(_fire_vis - delta, 0.0)
	var smp := _buf.sample()
	if smp.is_empty():
		if _react.is_down():
			_react.process(delta)
		return
	var a: Dictionary = smp[0]
	var b: Dictionary = smp[1]
	var t: float = clampf(smp[2], 0.0, 1.0)
	var f1 := int(b["f1"])
	hp = float(b["hp"]) * hp_max
	_sup = lerpf(float(a.get("sup", 0.0)), float(b.get("sup", 0.0)), t)
	shooting_skiff = bool(b["skiff"])
	var role := int(b["role"])
	if role != _role:
		_role = role
		var c: Color = ROLE_COLORS[clampi(role, 0, 3)]
		_role_mat.emission = c
		_lamp.light_color = c
	var is_dead_now := (f1 & 1) != 0
	if is_dead_now and not dead:
		_die(Vector3.INF, "", int(b["t"]))
	elif not is_dead_now and dead and int(b["t"]) > _death_ms:
		_revive()
		return                             # (fresh snapshots only: no blend from the dead spot)
	if dead or (f1 & 2) != 0:
		visible = not ((f1 & 2) != 0) or dead
		_set_digging(false, b)
		if dead and _ragdoll != null and is_instance_valid(_ragdoll):
			astronaut.sync_skeleton()        # (the astronaut does not sync itself on a bot)
		return
	if _react.is_down():
		# Knocked down / getting up: our own ragdoll and get-up (the host's node lies still until its
		# get-up, so the snapshots say nothing new); the hit capsule rides on the body.
		_set_digging(false, b)
		_lamp.visible = (f1 & 64) != 0
		_react.process(delta)
		return
	visible = true
	var pos: Vector3 = (a["pos"] as Vector3).lerp(b["pos"], t)
	var up: Vector3 = (a["up"] as Vector3).slerp(b["up"], t).normalized()
	var fwd: Vector3 = (a["fwd"] as Vector3).slerp(b["fwd"], t)
	if _prev_pos != Vector3.INF and pos.distance_to(_prev_pos) < 8.0:
		_vel = _vel.lerp((pos - _prev_pos) / maxf(delta, 1e-3), 1.0 - exp(-10.0 * delta))
	else:
		_vel = Vector3.ZERO
	_prev_pos = pos
	if _fix_pending:
		# Our get-up stood the puppet where OUR ragdoll lay: blend over to the host's spot.
		_fix_pending = false
		var off := global_position - pos
		_fix = off if off.length() < 4.0 else Vector3.ZERO
	_place(pos + _fix, up, fwd)
	if _fix != Vector3.ZERO:
		_fix = _fix * exp(-6.0 * delta) if _fix.length_squared() > 1e-4 else Vector3.ZERO
	_react.process(delta)                  # (the stagger pose, read by the next animate)
	# Crouch / slide: the astronaut's own poses, like the host (ai_rival.gd). A slide is a crouch on
	# the ground faster than a crouch-walk can go (byte 13: horizontal speed; crouch-walk < ~1.7 m/s).
	var sliding := (f1 & 4) != 0 and (f1 & 8) == 0 and float(b["speed"]) >= SLIDE_SPEED
	_crouch_k = move_toward(_crouch_k, 1.0 if (f1 & 4) != 0 else 0.0, delta * 4.5)
	_slide_k = move_toward(_slide_k, 1.0 if sliding else 0.0, delta * 6.0)
	astronaut.position = Vector3.ZERO
	# The bullet capsule shrinks like the host's (~1.0 m in a slide).
	var hh := 1.8 - 0.6 * maxf(_crouch_k, _slide_k * 1.3)
	var cap := _cap_cs.shape as CapsuleShape3D
	if absf(cap.height - hh) > 0.05:
		cap.height = hh
		_cap_cs.position = Vector3(0, hh * 0.5, 0)
	var held := ["", "terrain", "rifle", "wx_torpedo"][int(b["held"])] as String
	if held == "wx_torpedo" and not astronaut.props.has("wx_torpedo"):
		_build_launcher_prop()
	if held != _held:
		_held = held
		astronaut.set_held(held)
	_lamp.visible = (f1 & 64) != 0
	_set_digging((f1 & 32) != 0 and b.has("dig"), b)
	# Pose at a distance-based rate (same tiers as the host's ai_rival.gd: every frame near,
	# 30 Hz mid, 10 Hz far), so the legs don't step against the smoothly gliding body.
	var cam := get_viewport().get_camera_3d()
	var d := cam.global_position.distance_to(pos) if cam != null else 0.0
	var rate := 0.0 if d < 25.0 else (1.0 / 30.0 if d < 60.0 else 1.0 / 10.0)
	_pose_acc += delta
	if _pose_acc < rate:
		_throw_step(delta)
		return
	var dt := _pose_acc
	_pose_acc = 0.0
	var bas := global_transform.basis
	var hv := _vel - up * _vel.dot(up)
	astronaut.animate(minf(dt, 0.5), {"vel_local": bas.inverse() * hv, "vel_up": _vel.dot(up), "speed": hv.length(),
			"grounded": (f1 & 8) == 0, "jetting": (f1 & 16) != 0, "jet_power": 1.0, "zero_g": false,
			"pitch": lerpf(float(a["pitch"]), float(b["pitch"]), t), "holding": _held != "", "two_hand": true,
			"using": (f1 & 32) != 0 or _fire_vis > 0.0 or (f1 & 128) != 0, "exclude": [_col.get_rid()],
			"probe": d < 30.0, "crouch": _crouch_k, "slide": _slide_k})
	astronaut.set_tool_color(REPAIR_COLOR if (f1 & 128) != 0 else DIG_COLOR)
	astronaut.sync_skeleton()
	_throw_step(delta)


func _set_digging(on: bool, s: Dictionary) -> void:
	if not on:
		if _fx != null and is_instance_valid(_fx):
			_fx.set_working(false)
		if _dig_audio.playing:
			_dig_audio.stop()
		return
	var cam := get_viewport().get_camera_3d()
	var near := cam == null or cam.global_position.distance_to(global_position) < 70.0
	if not near:
		if _dig_audio.playing:
			_dig_audio.stop()
		return
	if _fx == null or not is_instance_valid(_fx):
		_fx = DigFx.new()
		_fx.tip_is_vm = false
		add_child(_fx)
	var tip_n: Node3D = astronaut.held_tip("terrain")
	var tip := tip_n.global_position if tip_n != null else global_position + global_transform.basis.y * 1.3
	var dp: Vector3 = s["dig"]
	var body := Net.body_by_index(int(s["body"]))
	var soil: Color = body.get("soil_color") if body != null and body.get("soil_color") is Color else Color(0.45, 0.35, 0.24)
	var n := (dp - body.global_position).normalized() if body != null else global_transform.basis.y
	_fx.work(tip, (dp - tip).normalized(), dp, n, global_transform.basis.y, 0, 1.4, DIG_COLOR, soil)
	if not _dig_audio.playing:
		_dig_audio.play()


func shot_fx(end: Vector3) -> void:
	if dead or not visible:
		return
	var tip: Node3D = astronaut.held_tip("rifle")
	var muzzle: Vector3 = tip.global_position if tip != null else global_position + global_transform.basis.y * 1.5
	# The enemy-fire look the host draws for its bots (scripts/war/enemy_fire.gd: a flying red / warm
	# streak, the far-visible muzzle star, the dirt where a miss lands; loaded at use time).
	load(ENEMY_FIRE_PATH).call("shot", muzzle, end, team, false, 0.3, 1.0, not suppressed, not suppressed)
	_flash.global_position = muzzle
	_flash_t = 0.0 if suppressed else 1.0
	_fire_vis = 0.25
	_gun_audio.global_position = muzzle
	_gun_audio.play()
	# Near-miss whizz / snap for our player (hit_feel.gd listens to Game.shot_fired).
	if end.distance_squared_to(muzzle) > 1e-4:
		Game.shot_fired.emit(muzzle, (end - muzzle).normalized(), team)


## Death: v = the host's corpse launch (whole, before the split; net_react.gd die splits it like the
## host) and the struck part; INF = a dead snapshot before the host's event (the old plain launch,
## corrected if the event follows within DEATH_FIX_MS). host_ms: the host's clock of the death.
func _die(v := Vector3.INF, bone := "", host_ms := -1) -> void:
	if dead:
		if v != Vector3.INF and _fallback_v != Vector3.INF and Time.get_ticks_msec() - _fallback_ms < DEATH_FIX_MS:
			_react.add_launch(_ragdoll, v - _fallback_v, bone)
		_fallback_v = Vector3.INF
		return
	dead = true
	_death_ms = host_ms
	_fallback_v = Vector3.INF
	if not visible:
		# Hidden aboard (a drop pod's crew shot down with it): the puppet was not moved while aboard;
		# the host's bot rode the pod, so it dies where the newest snapshot has it.
		var s = _buf.latest()
		if s is Dictionary:
			_place(s["pos"], s["up"], s["fwd"])
		visible = true
	if v == Vector3.INF:
		v = Vector3.ZERO if _react.is_down() else _vel + global_transform.basis.y * 1.5
		_fallback_v = v
		_fallback_ms = Time.get_ticks_msec()
	_cap_cs.disabled = true
	_lamp.visible = false
	astronaut.set_held("")
	_held = ""
	_set_digging(false, {})
	_end_throw()
	_ragdoll = _react.die(v, bone)
	if _ragdoll != null and not _ragdoll.finished.is_connected(_on_settled):
		_ragdoll.finished.connect(_on_settled)
	var cam := get_viewport().get_camera_3d()
	if Game.hud and cam != null and cam.global_position.distance_to(global_position) < 120.0:
		Game.hud.show_message("%s düştü!" % callsign, 2.0)


func _on_settled(_p: Vector3, _f: Vector3) -> void:
	astronaut.sync_skeleton()
	if _ragdoll != null and is_instance_valid(_ragdoll):
		for k in (_ragdoll.bodies as Dictionary).keys():
			var rb: RigidBody3D = _ragdoll.bodies[k]
			rb.freeze = true


func _revive() -> void:
	dead = false
	_death_ms = -1
	_fallback_v = Vector3.INF
	_fix = Vector3.ZERO
	_react.reset()
	# The body stays where it fell (scripts/war/corpse.gd, local: the host leaves its own); a ragdoll
	# still moving is taken over (null back), else the pose is copied and we free it.
	if _ragdoll != null and is_instance_valid(_ragdoll) and not _ragdoll.is_queued_for_deletion():
		_ragdoll = Corpse.leave(astronaut, _ragdoll, team, "bot")
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null
	astronaut.transform = Transform3D.IDENTITY
	astronaut.reset_pose()
	_cap_cs.disabled = false
	_prev_pos = Vector3.INF
	_buf.clear()
	_have = false
	# Hidden until the first fresh snapshot (push) puts it where the host respawned it (a dropship's
	# ramp foot, respawn_ship.gd): never a frame standing at the old spot where it died.
	visible = false


func _exit_tree() -> void:
	_react.reset()
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null


## The host's bot was hit (alive; net_bots.gd): its flinch / stagger / knockdown come as react(); here
## only a knocked-down puppet's ragdoll takes the shove (hit_reactor.gd on_hit while down).
func hit_fx(from_pos: Vector3, _amount: float, impulse := Vector3.ZERO, point := Vector3.INF) -> void:
	if dead or not visible or astronaut == null:
		return
	_react.shove(impulse, point, from_pos)


## The host's bot reacted to a hit (RivalTeam.events().bot_react: "flinch" / "stagger" / "knockdown" /
## "getup") or died ("death": its corpse launch; host_ms = the host's clock), through net_bots.gd.
func react(kind: String, dir: Vector3, strength: float, bone: String, host_ms := -1) -> void:
	if not _have or astronaut == null:
		return
	if kind == "death":
		_die(dir * strength, bone, host_ms)
		return
	if dead:
		return
	if kind == "knockdown":
		_set_digging(false, {})
		_end_throw()
		_tracer.visible = false
		_fire_vis = 0.0
		_crouch_k = 0.0
		_slide_k = 0.0
		var cap := _cap_cs.shape as CapsuleShape3D
		cap.height = 1.8
		_cap_cs.position = Vector3(0, 0.9, 0)
	_react.react(kind, dir, strength, bone)


## Our get-up has ended (net_react.gd recovered): back on the snapshots.
func _on_recovered() -> void:
	_prev_pos = Vector3.INF
	_vel = Vector3.ZERO
	_fix_pending = true
	_pose_acc = 1.0


## Visual state only (gates for code that asks any "war_ai" body; the host decides the real ones).
func is_staggered() -> bool:
	return _react.is_staggered()


## How suppressed the host's bot is, 0..1 (ai_rival.gd suppression(), the snapshot's byte 14, 16
## steps): the same API on the puppet for the posture layer.
func suppression() -> float:
	return 0.0 if dead else _sup


# --- NPC reactions (the host bot's RivalTeam.events() bot_gesture / bot_callout / bot_alert /
# bot_mood, through net_bots.gd; scripts/war/bot_cues.gd loaded at use time) -------------------------

## A gesture (astronaut.gesture) or, for "look", a glance toward dir (the bot's local space) for 3 s.
func cue_gesture(kind: String, dir_local: Vector3) -> void:
	if dead or not visible or astronaut == null or _react.is_down():
		return
	if kind == "look":
		astronaut.look_dir(dir_local, 3.0)
	else:
		astronaut.gesture(kind, dir_local)


## A callout line over its head (BotCues.say; urgent lines pop larger). False for an unknown line.
func cue_say(line: String, variant: int, arg: int) -> bool:
	if dead or not visible:
		return false
	var cues = load(CUES_PATH)
	var text := str(cues.call("line_text", line, variant, arg))
	if text == "":
		return false
	cues.call("say", self, text, false, line in (cues.get("URGENT") as Array))
	return true


## The "!" over its head: "seen" (it just saw you) / "marked" (an ally points you out).
func cue_alert(kind: String) -> void:
	if not dead and visible:
		load(CUES_PATH).call("alert", self, kind)


## Wounded / hunched under fire (the host's mood, in tenths).
func cue_mood(wound: float, hunch: float) -> void:
	if astronaut != null:
		astronaut.set_mood(wound, hunch)


func is_down() -> bool:
	return _react.is_down()


func _end_throw() -> void:
	_throw_t = -1.0
	if _gprop != null and is_instance_valid(_gprop):
		_gprop.visible = false


# --- The bots' new weapons (scripts/war/ai_rival.gd, synced through net_bots.gd) ---------------------

## The host's bot started a visible action (RivalTeam.events().bot_action): "grenade" = the wind-up.
func action(what: String) -> void:
	if what == "grenade" and not dead and visible:
		_throw_t = 0.0
		var g := _grenade_prop()
		if g != null:
			g.visible = true


## The throw over the animated pose (same curve as ai_rival.gd _wx_throw_pose): the right arm swings
## up and back over the shoulder, then whips forward; blended from and back to the animation.
func _throw_step(delta: float) -> void:
	if _throw_t < 0.0:
		return
	_throw_t += delta
	var w_up := float(load("res://scripts/war/balance.gd").get_script_constant_map().get("AI_GRENADE_WINDUP", 0.55))
	var t := _throw_t
	if t > w_up and _gprop != null:
		_gprop.visible = false
	if dead or t > w_up + 0.4:
		_throw_t = -1.0
		if _gprop != null:
			_gprop.visible = false
		return
	var sh_t := Vector3(3.5, 0.0, 0.25)
	var el_t := Vector3(1.7, 0.0, 0.0)
	var twist := -0.35
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
	var rot: Dictionary = astronaut.get("_rot")
	(sh as Node3D).rotation = (rot.get(sh, (sh as Node3D).rotation) as Vector3).lerp(sh_t, w)
	(el as Node3D).rotation = (rot.get(el, (el as Node3D).rotation) as Vector3).lerp(el_t, w)
	(ch as Node3D).rotation = (rot.get(ch, (ch as Node3D).rotation) as Vector3) + Vector3(0.0, twist * w, 0.0)
	astronaut.sync_skeleton()


## The grenade in the right fist during the wind-up (white body, orange band, red LED).
func _grenade_prop() -> Node3D:
	if _gprop != null and is_instance_valid(_gprop):
		return _gprop
	var hands: Array = astronaut.hand
	if hands.size() < 2 or hands[1] == null:
		return null
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.88, 0.89, 0.9)
	white.roughness = 0.4
	var orange := StandardMaterial3D.new()
	orange.albedo_color = Color(1.0, 0.48, 0.1)
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
	_gprop = g
	return g


## The bot's torpedo launcher (held code 3, "wx_torpedo"): gunmetal tube, red bands, drill nose.
func _build_launcher_prop() -> void:
	var hands: Array = astronaut.hand
	if hands.size() < 2 or hands[1] == null:
		return
	var gun := StandardMaterial3D.new()
	gun.albedo_color = Color(0.22, 0.21, 0.21)
	gun.metallic = 0.55
	gun.roughness = 0.45
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.75, 0.13, 0.08)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.08, 0.08, 0.09)
	dark.metallic = 0.5
	var p := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.03, -0.04), Vector3(0.05, 0.05, 0.16), dark)
	VM.seg(p, Vector3(0, 0.1, 0.33), Vector3(0, 0.1, -0.49), 0.062, 0.062, gun, 12)
	VM.seg(p, Vector3(0, 0.1, -0.47), Vector3(0, 0.1, -0.56), 0.07, 0.073, dark, 12)
	VM.seg(p, Vector3(0, 0.1, 0.32), Vector3(0, 0.1, 0.44), 0.066, 0.086, dark, 12)
	for z in [-0.42, 0.22]:
		VM.seg(p, Vector3(0, 0.1, z + 0.01), Vector3(0, 0.1, z - 0.01), 0.066, 0.066, red, 12)
	var tp := "res://scripts/war/torpedo.gd"
	if ResourceLoader.exists(tp):
		var nose := MeshInstance3D.new()
		nose.mesh = load(tp).call("drill_mesh", 0.11, 0.05)
		nose.material_override = gun
		nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.add_child(nose)
		nose.position = Vector3(0, 0.1, -0.56)
	for n in p.find_children("*", "GeometryInstance3D", true, false):
		(n as GeometryInstance3D).visibility_range_end = 60.0
	astronaut.props["wx_torpedo"] = p
	astronaut.prop_tips["wx_torpedo"] = VM.node(p, Vector3(0, 0.1, -0.68))
	p.visible = false
