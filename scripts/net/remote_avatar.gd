extends Node3D
## The OTHER player as seen on this machine: a full astronaut (scripts/player/astronaut.gd) driven
## by that player's 20 Hz state (net_players.gd), interpolated ~110 ms behind. Name tag, held item,
## walk / run / jump / jetpack animation with the aim pitch, jetpack flame and roar, footsteps, the
## drill beam (DigFx) with its hum, muzzle flash + tracer + impact puff + 3D gunshot per shot, the
## headlamp, a ragdoll while that player is down, sitting in a skiff seat, hidden while manning a gun.
## Hit reactions (that player's player.hit_reacted, net_players.gd -> react_event -> net_react.gd): the
## flinch at the struck part, the stagger pose, the knockdown / death ragdoll launched like the owner's
## hit reactor (a uniform share + the rest into the torso at the struck part), the get-up blended back
## where this body lies. A ragdoll the owner's F_RAG flag starts without an event (late / lost) falls
## back to the plain velocity; an event right after corrects its launch.
##
## Damage: group "damageable" (bullets and blasts find it through its collider):
##   host:   the other player's hp lives HERE (mirror): take_damage() subtracts, regenerates like
##           player.gd, and tells the owner (net_players.gd hurt event); death is decided here.
##   client: take_damage() is never reached (Game.damage_target turns hits into claims to the host).

const Astronaut := preload("res://scripts/player/astronaut.gd")
const Ragdoll := preload("res://scripts/player/ragdoll.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const VM := preload("res://scripts/player/vm_parts.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const SnapBuffer := preload("res://scripts/net/snap_buffer.gd")
const NetReact := preload("res://scripts/net/net_react.gd")
const Corpse := preload("res://scripts/war/corpse.gd")
const Downed := preload("res://scripts/war/downed.gd")     # downed / revive / drag (host decides; the pose here)
const ATT_PATH := "res://scripts/items/attachments.gd"   # load()ed at use (never preloaded under the Net autoload)
const ENEMY_FIRE_PATH := "res://scripts/war/enemy_fire.gd"   # (load()ed at use, like the above)
const SHOT_PINGS_PATH := "res://scripts/war/shot_pings.gd"   # radar pings (scripts/ui/minimap.gd)
## Heavy NO_BULLET guns that still reveal the shooter on the radar (no suppressor fits them).
const LOUD_HEAVY := ["rocket", "torpedo", "rail", "mortar"]

const HP_MAX := 135.0               # = player.gd HP_MAX (2026-10-06 tok: 100 -> 135)
const RAG_FIX := 0.6               # s: a knockdown / death event this soon after a flag-started ragdoll corrects it
const RAG_HOLD := 1.5               # s an event's ragdoll waits for the owner's F_RAG (the buffered state)
## Hit capsule: the whole 1.92 m suit standing (helmet included, for the head zone); crouched like
## stance.gd CROUCH_H (eye 1.25 m).
const STAND_H := 1.95
const CROUCH_H := 1.35
const REGEN_DELAY := 6.0
const REGEN_RATE := 7.0
const TWO_HAND := ["terrain", "rifle", "shotgun", "build", "sniper", "pusher", "rocket", "torpedo", "rail", "smg", "plasma", "dirt", "mortar"]
## Held items that fire no bullet (the pusher's blast, rockets, torpedoes, the rail beam sync on their own).
const NO_BULLET := ["pusher", "rocket", "torpedo", "rail", "plasma", "dirt", "mortar"]
## Guns whose third-person model comes from their own script (_build_tp).
const TP_GUNS := {"shotgun": "res://scripts/items/shotgun.gd", "pusher": "res://scripts/items/kinetic_pusher.gd",
		"rocket": "res://scripts/items/rocket_launcher.gd", "torpedo": "res://scripts/items/torpedo_launcher.gd",
		"rail": "res://scripts/items/railgun.gd", "smg": "res://scripts/items/smg.gd",
		"plasma": "res://scripts/items/plasma_cutter.gd", "dirt": "res://scripts/items/dirt_launcher.gd",
		"mortar": "res://scripts/items/mortar.gd",
		"pistol": "res://scripts/items/pistol.gd", "revolver": "res://scripts/items/revolver.gd",
		"mpistol": "res://scripts/items/mpistol.gd"}

const F_FLOOR := 1
const F_JET := 2
const F_DEAD := 4
const F_RAG := 8
const F_VEHICLE := 16
const F_LAMP := 32
const F_USING := 64
const F_DIG := 128

var player_name := "Oyuncu"
var side := 0                       # absolute side (net.gd)
var team := "home"                  # local team string (Game.team_of reads it)
var hp := HP_MAX
var hp_max := HP_MAX
var shield := 0.0                  # host: the owner's relic Kalkan left (net_players.gd _rx_shield)
var dead := false
var in_vehicle := false
var vehicle_id := 0
var seat := 0
var vehicle: Node = null           # the skiff / gun it is in (ai_rival.gd reads it like player.gd)
var velocity := Vector3.ZERO
var crouch_k := 0.0                 # (ai_rival.gd _aim_point lowers its aim for a crouching player)
var astronaut

var _buf := SnapBuffer.new()
var _col: StaticBody3D
var _cap_cs: CollisionShape3D
var _tag: Label3D
var _held := ""                     # what the owner holds
var _held_shown := "-"              # what this body shows (none while seated)
var _sniper_script = null
var _crouch := 0.0
var _slide := 0.0
var _glint := 0.0
var _ragdoll = null
var _since_hit := 99.0
var _prev_fwd := Vector3.ZERO
var _vel := Vector3.ZERO
var _pitch := 0.0
var _flags := 0
var _jet := 0.0
var _body_i := 0
var _dig_point := Vector3.ZERO
var _dig_normal := Vector3.UP
var _dig_mode := 0
var _dig_r := 2.0
var _tool_col := Color(1.0, 0.55, 0.15)
var _fx                             # DigFx
var _dig_audio: AudioStreamPlayer3D
var _mine_audio: AudioStreamPlayer3D
var _jet_audio: AudioStreamPlayer3D
var _gun_audio: AudioStreamPlayer3D
var _heavy_audio: AudioStreamPlayer3D
var _lamp: SpotLight3D
var _flash: OmniLight3D
var _flash_t := 0.0
var _tracer: MeshInstance3D
var _tracer_mesh: ImmediateMesh
var _tracer_t := 0.0
var _use_vis := 0.0
var _mine_t := 0.0
var _step_half := -1
var _have_state := false
var _whoosh_audio: AudioStreamPlayer3D
var _melee_t := -1.0                # dipçik swing clock (melee_fx), -1 idle
var _mantle_t := -1.0               # climb clock (mantle_fx), -1 idle
var _mantle_len := 0.5
var _react = NetReact.new()         # hit reactions mirrored (react_event)
var _rag_evt := false               # the ragdoll came from a knockdown / death event (not the F_RAG flag)...
var _rag_seen := false              # ...and the owner's F_RAG has shown up since
var _rag_age := 0.0
var _rag_fallback := Vector3.INF    # launch of a flag-started ragdoll (an event within RAG_FIX s corrects it)
var _rag_wait_clear := false        # our get-up ended before the owner's F_RAG cleared: ignore the flag till then
var _rag_pending: Array = []        # [death, v, bone] of an event that came while still seated
var _rag_pending_t := 0.0
var _fix := Vector3.ZERO            # position blend after our get-up (our ragdoll lay elsewhere than the owner's)
var _fix_pending := false
var _att := {}                      # the held gun's attachments {slot: id}
var _att_dirty := false
var _rag_dead := false              # the ragdoll is the corpse (left as a Corpse at the respawn)


func setup(p_name: String, p_side: int) -> void:
	player_name = p_name
	side = p_side
	team = Net.local_team(p_side)


func _ready() -> void:
	name = "RemotePlayer"
	add_to_group(Game.DAMAGEABLE)
	add_to_group("net_player")
	top_level = true
	astronaut = Astronaut.new()
	add_child(astronaut)
	astronaut.set_first_person(false)
	_build_props()
	_col = StaticBody3D.new()
	_col.collision_layer = Game.LAYER_PLAYER
	_col.collision_mask = 0
	_col.set_meta("net_player", self)
	_cap_cs = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.38
	cap.height = STAND_H
	_cap_cs.shape = cap
	_cap_cs.position = Vector3(0, STAND_H * 0.5, 0)
	_col.add_child(_cap_cs)
	add_child(_col)
	_react.setup(self, astronaut, null, [_col], true)
	_react.recovered.connect(_on_recovered)
	_tag = Label3D.new()
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.no_depth_test = false
	_tag.fixed_size = true
	_tag.pixel_size = 0.0011
	_tag.font_size = 30
	_tag.outline_size = 10
	_tag.position = Vector3(0, 2.35, 0)            # over the 1.92 m suit
	_tag.visibility_range_end = 160.0
	var friend := side == Net.my_side()
	_tag.modulate = Color(0.55, 0.92, 1.0) if friend else Color(1.0, 0.45, 0.38)
	_tag.text = player_name
	add_child(_tag)
	_fx = DigFx.new()
	_fx.tip_is_vm = false
	add_child(_fx)
	_dig_audio = _audio3d(Snd.loop("ship/dig_beam"), 10.0, 160.0)
	_mine_audio = _audio3d(Snd.rand("dig/mine", 1.08, 2.0), 8.0, 120.0)
	_jet_audio = _audio3d(Snd.loop("ship/jetpack"), 9.0, 140.0)
	_gun_audio = _audio3d(Snd.rand("weap/rifle_shot", 1.05, 1.5), 14.0, 600.0)
	_heavy_audio = _audio3d(Snd.rand("weap/rifle_heavy", 1.05, 1.5), 16.0, 650.0)
	_whoosh_audio = _audio3d(Snd.rand("whoosh/whoosh", 1.08, 2.0), 6.0, 60.0)
	_lamp = SpotLight3D.new()
	_lamp.light_color = Color(1.0, 0.92, 0.8)
	_lamp.light_energy = 6.0
	_lamp.spot_range = 28.0
	_lamp.spot_angle = 24.0
	_lamp.shadow_enabled = false
	_lamp.visible = false
	astronaut.head.add_child(_lamp)
	_lamp.position = Vector3(0.17, 0.17, -0.16)
	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.72, 0.4)
	_flash.omni_range = 9.0
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


func _audio3d(stream: AudioStream, unit: float, max_d: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.unit_size = unit
	p.max_distance = max_d
	p.max_polyphony = 2
	add_child(p)
	return p


## Third-person props for the guns (the drill / build props come with the astronaut).
func _build_props() -> void:
	var hands: Array = astronaut.hand
	if hands.size() < 2 or hands[1] == null:
		return
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.16, 0.17, 0.19)
	dark.metallic = 0.6
	dark.roughness = 0.4
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.9, 0.91, 0.92)
	white.roughness = 0.35
	var sniper_s = load("res://scripts/items/sniper.gd") if ResourceLoader.exists("res://scripts/items/sniper.gd") else null
	if sniper_s != null and (sniper_s as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "build_tp_on"):
		sniper_s.call("build_tp_on", astronaut)
		_sniper_script = sniper_s
	for id in ["rifle", "sniper"]:
		if astronaut.props.has(id):
			continue
		var p := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
		var long := 0.75 if id == "sniper" else 0.6
		VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
		VM.box(p, Vector3(0, 0.06, -0.05), Vector3(0.05, 0.07, 0.3), white)
		VM.box(p, Vector3(0, 0.05, 0.17), Vector3(0.036, 0.09, 0.15), white)
		VM.seg(p, Vector3(0, 0.062, -0.2), Vector3(0, 0.062, -long), 0.016, 0.014, dark, 8)
		if id == "sniper":
			VM.seg(p, Vector3(0, 0.12, 0.02), Vector3(0, 0.12, -0.2), 0.022, 0.022, dark, 10)
		astronaut.props[id] = p
		astronaut.prop_tips[id] = VM.node(p, Vector3(0, 0.062, -long - 0.02))
		p.visible = false
	# The other guns: each one's own third-person model (weapon_base.gd _build_tp).
	for id in TP_GUNS:
		var path: String = TP_GUNS[id]
		if astronaut.props.has(id) or not ResourceLoader.exists(path):
			continue
		var gun = load(path).new()
		if gun == null or not gun.has_method("_build_tp"):
			if gun != null:
				gun.free()
			continue
		var p2 := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
		var tip = gun.call("_build_tp", p2)
		astronaut.props[id] = p2
		astronaut.prop_tips[id] = tip if tip is Node3D else VM.node(p2, Vector3(0, 0.06, -0.6))
		p2.visible = false
		gun.free()


# =================================================================================================
# State in
# =================================================================================================

## One decoded state from net_players.gd: {t, flags, body, pos (world), rot (Quaternion), vel,
## pitch, hp, jet, veh, seat, dig_p, dig_n, dig_mode, dig_r}.
func push_state(s: Dictionary) -> void:
	_buf.push(int(s["t"]), s)
	if not _have_state:
		_have_state = true
		visible = true
		global_transform = Transform3D(Basis(s["rot"] as Quaternion), s["pos"])
	if not Net.is_server:
		hp = float(s["hp"])
		dead = (int(s["flags"]) & F_DEAD) != 0


## att: the held gun's fitted attachments ({slot: id}, already validated by net_players.gd clean_att).
func set_held(icon: String, col: Color, att := {}) -> void:
	_tool_col = col
	_held = icon
	if att != _att:
		_att = att.duplicate()
		_att_dirty = true


func _show_held(icon: String) -> void:
	if icon != _held_shown or _att_dirty:
		_held_shown = icon
		_att_dirty = false
		astronaut.set_held(icon)
		# Its parts on the third-person gun (scripts/items/attachments.gd, loaded at use time).
		if icon != "" and astronaut.props.has(icon) and ResourceLoader.exists(ATT_PATH):
			load(ATT_PATH).call("dress_tp", astronaut.props[icon], icon, _att)


func _process(delta: float) -> void:
	_since_hit += delta
	_flash_t = maxf(_flash_t - delta * 12.0, 0.0)
	_flash.light_energy = 6.0 * _flash_t
	_flash.visible = _flash_t > 0.01
	_tracer_t = maxf(_tracer_t - delta, 0.0)
	if _tracer_t <= 0.0 and _tracer.visible:
		_tracer.visible = false
	_use_vis = maxf(_use_vis - delta, 0.0)
	if Net.is_server and not dead and hp < hp_max and _since_hit > REGEN_DELAY and not Downed.is_downed(self):
		hp = minf(hp + REGEN_RATE * delta, hp_max)
	var smp := _buf.sample()
	if smp.is_empty():
		return
	var a: Dictionary = smp[0]
	var b: Dictionary = smp[1]
	var t: float = smp[2]
	_flags = int(b["flags"])
	var pos: Vector3
	if (a["pos"] as Vector3).distance_squared_to(b["pos"]) > 64.0:
		pos = b["pos"]                     # a teleport (respawn off a dropship's ramp): no slide across
	elif t <= 1.0:
		pos = (a["pos"] as Vector3).lerp(b["pos"], t)
	else:
		var span := maxf(float(int(b["t"]) - int(a["t"])), 1.0) / 1000.0
		pos = (b["pos"] as Vector3) + (b["vel"] as Vector3) * (t - 1.0) * span
	var rot := (a["rot"] as Quaternion).slerp(b["rot"], clampf(t, 0.0, 1.0))
	_vel = (a["vel"] as Vector3).lerp(b["vel"], clampf(t, 0.0, 1.0))
	_pitch = lerpf(float(a["pitch"]), float(b["pitch"]), clampf(t, 0.0, 1.0))
	_jet = float(b["jet"])
	var tc := clampf(t, 0.0, 1.0)
	_crouch = lerpf(float(a.get("crouch", 0.0)), float(b.get("crouch", 0.0)), tc)
	_slide = lerpf(float(a.get("slide", 0.0)), float(b.get("slide", 0.0)), tc)
	_glint = float(b.get("glint", 0.0))
	crouch_k = maxf(_crouch, _slide)
	_body_i = int(b["body"])
	in_vehicle = (_flags & F_VEHICLE) != 0
	vehicle_id = int(b["veh"])
	seat = int(b["seat"])
	vehicle = Net.world.node_of(vehicle_id) if in_vehicle and vehicle_id != 0 else null
	velocity = _vel
	if (_flags & F_DIG) != 0:
		_dig_point = b["dig_p"]
		_dig_normal = b["dig_n"]
		_dig_mode = int(b["dig_mode"])
		_dig_r = float(b["dig_r"])
	var rag := (_flags & F_RAG) != 0
	_rag_pending_t += delta
	if _rag_wait_clear:
		if rag:
			rag = false                    # the tail of the owner's get-up: ours has ended already
		else:
			_rag_wait_clear = false
	if _ragdoll != null:
		_rag_age += delta
		if rag:
			_rag_seen = true
		elif _rag_evt and not _rag_seen and _rag_age < RAG_HOLD:
			rag = true                     # the event came before the owner's buffered state
	if rag and _ragdoll == null:
		_start_ragdoll()
	elif not rag and _ragdoll != null and not _react.is_getting_up():
		_end_ragdoll()
	if _ragdoll != null:
		if dead and _react.is_down():
			_ragdoll = _react.die(Vector3.ZERO, "")     # killed while down: it lies on as the corpse
			_rag_dead = true
		if not _react.is_getting_up():
			# The body lies where the ragdoll took it; the root follows the owner's pelvis loosely.
			global_position = global_position.lerp(pos, 1.0 - exp(-2.0 * delta))
		_react.process(delta)              # (the get-up; recovered -> _on_recovered)
		_cap_cs.disabled = true
		_update_audio(delta, false, false)
		return
	_cap_cs.disabled = in_vehicle or dead
	var ck := maxf(_crouch, _slide)
	var cap := _cap_cs.shape as CapsuleShape3D
	var dn := Downed.is_downed(self)
	var ch := Downed.LYING_CAP_H if dn else lerpf(STAND_H, CROUCH_H, ck)
	if absf(cap.height - ch) > 0.02 or dn != (absf(_cap_cs.rotation.x) > 0.1):
		cap.height = ch
		_cap_cs.transform = Downed.LYING_CAP_XF if dn else Transform3D(Basis(), Vector3(0, ch * 0.5, 0))
	var xf := Transform3D(Basis(rot), pos)
	if xf.origin.distance_to(global_position) > 12.0:
		_prev_fwd = Vector3.ZERO           # respawn / teleport
	if _fix_pending:
		# Our get-up stood this body where OUR ragdoll lay: blend over to the owner's spot.
		_fix_pending = false
		var off := global_position - pos
		_fix = off if off.length() < 4.0 else Vector3.ZERO
	if _fix != Vector3.ZERO:
		xf.origin += _fix
		_fix = _fix * exp(-6.0 * delta) if _fix.length_squared() > 1e-4 else Vector3.ZERO
	global_transform = xf
	var sk := _seat_vehicle()
	if in_vehicle:
		if sk != null:
			_sit_in(sk)
		else:
			astronaut.visible = false
			_tag.visible = false
		_fx.set_working(false)
		_update_audio(delta, false, false)
		return
	astronaut.visible = true
	_tag.visible = not dead
	astronaut.transform = Transform3D.IDENTITY
	_show_held(_held)
	_react.process(delta)                  # (the stagger pose, before the animation reads it)
	if Downed.is_downed(self) or Downed.is_rising(self):
		Downed.pose_step(self, delta)      # down: the downed pose / crawl (rising: downed.gd blends the get-up)
	else:
		_animate(delta)
	_melee_pose(delta)
	_mantle_pose(delta)
	var using := (_flags & F_USING) != 0
	var digging := using and (_flags & F_DIG) != 0 and _held == "terrain"
	if digging:
		_drill_fx(delta)
	_lamp.visible = (_flags & F_LAMP) != 0
	_update_audio(delta, digging, (_flags & F_JET) != 0)
	_footsteps()


func _animate(delta: float) -> void:
	var b := global_transform.basis
	var up := b.y
	var hv := _vel - up * _vel.dot(up)
	var fwd := -b.z
	var yaw_rate := 0.0
	if _prev_fwd != Vector3.ZERO:
		yaw_rate = _prev_fwd.cross(fwd).dot(up) / maxf(delta, 1e-4)
	_prev_fwd = fwd
	var holding := _held != ""
	var near := true
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		near = cam.global_position.distance_to(global_position) < 40.0
	astronaut.set_tool_color(_tool_col)
	astronaut.animate(delta, {
		"vel_local": b.inverse() * hv, "vel_up": _vel.dot(up), "yaw_rate": yaw_rate, "exclude": [_col.get_rid()],
		"jet_power": clampf(_jet * 1.3, 0.25, 1.0), "speed": hv.length(), "grounded": (_flags & F_FLOOR) != 0,
		"jetting": (_flags & F_JET) != 0, "zero_g": false, "pitch": _pitch, "holding": holding,
		"two_hand": _held in TWO_HAND, "using": (_flags & F_USING) != 0 or _use_vis > 0.0, "probe": near,
		"crouch": _crouch, "slide": _slide,
	})
	if _sniper_script != null and _held == "sniper":
		_sniper_script.call("set_glint", astronaut, _glint)
	astronaut.set_lamp((_flags & F_LAMP) != 0, 1.0 if (_flags & F_LAMP) != 0 else 0.0)


func _drill_fx(delta: float) -> void:
	var body := Net.body_by_index(_body_i)
	var tip_n: Node3D = astronaut.held_tip("terrain")
	var tip := tip_n.global_position if tip_n != null else global_position + global_transform.basis.y * 1.3
	var tdir := (_dig_point - tip).normalized()
	var soil: Color = body.get("soil_color") if body != null and body.get("soil_color") is Color else Color(0.45, 0.35, 0.24)
	var mc: Array = load("res://scripts/player/terrain_tool.gd").MODE_COLORS
	var col: Color = mc[clampi(_dig_mode, 0, 2)]
	_fx.work(tip, tdir, _dig_point, _dig_normal, global_transform.basis.y, _dig_mode, _dig_r, col, soil)
	_mine_t -= delta
	if _mine_t <= 0.0:
		_mine_t = randf_range(0.35, 0.8)
		if _dig_mode == 0:
			_mine_audio.global_position = _dig_point
			_mine_audio.play()


func _update_audio(_delta: float, digging: bool, jetting: bool) -> void:
	if digging and not _dig_audio.playing:
		_dig_audio.play()
	elif not digging and _dig_audio.playing:
		_dig_audio.stop()
	if jetting and not _jet_audio.playing:
		_jet_audio.play()
	elif not jetting and _jet_audio.playing:
		_jet_audio.stop()
	if jetting:
		_jet_audio.volume_db = linear_to_db(clampf(0.4 + _jet * 0.6, 0.05, 1.0))


func _footsteps() -> void:
	if (_flags & F_FLOOR) == 0 or Game.sfx == null:
		return
	var up := global_transform.basis.y
	var hs := (_vel - up * _vel.dot(up)).length()
	if hs < 1.0:
		return
	var half := floori(float(astronaut.get("_phase")) * 2.0)
	if half == _step_half:
		return
	_step_half = half
	var body := Net.body_by_index(_body_i)
	var step := "step_dirt"
	if body != null and body.get("cfg") is Dictionary:
		step = str((body.get("cfg") as Dictionary).get("step", step))
	Game.sfx.play_at(step, global_position, -10.0, randf_range(0.93, 1.07), 6.0)


## The skiff this player sits in (pilot or passenger seat), else null.
func _seat_vehicle() -> Node3D:
	if not in_vehicle or vehicle_id == 0:
		return null
	var n = Net.world.node_of(vehicle_id)
	if n != null and is_instance_valid(n) and n.is_in_group("skiff"):
		return n
	return null


## Seated through the canopy: pilot (left) or passenger (right) seat, facing the nose (the ship frame's
## -Z, like the astronaut's own forward). The astronaut's bone rotations: +X swings a thigh / an upper
## arm FORWARD, -X bends a knee, +X bends an elbow (astronaut.gd _leg_ik, hit_reactor.gd's get-up
## poses). The old pose had every sign flipped: the legs hung back and the knees bent forward, so
## the other player looked as if he sat the wrong way round ("mekiğe ters biniyorlar"); and the
## standing hips stuck out of the canopy. Now: hips on the seat pan, leaning back into the seat back
## (14°), thighs forward, shins down to the floor, the pilot's hands on the stick, the passenger's in
## the lap. Follows the hull's visual (smoothed) transform, like the passenger camera.
const SIT_HIPS := Vector3(0.0, 0.1, 0.03)       # pelvis over the seat point (ship frame offset)
const SIT_LEAN := 0.2                           # rad, torso back (+X tips the hips' up axis to +Z)


func _sit_in(sk: Node3D) -> void:
	var seat_pos: Vector3 = Net.world.seat_position(seat)
	var hull: Transform3D = sk.global_transform
	var vis = sk.get("_visual")
	if vis is Node3D and is_instance_valid(vis):
		hull = (vis as Node3D).global_transform
	global_transform = hull.orthonormalized() * Transform3D(Basis(), seat_pos)
	astronaut.visible = true
	_tag.visible = false
	var a = astronaut
	a.reset_pose()
	var hips: Node3D = a.hips
	hips.rotation = Vector3(SIT_LEAN, 0.0, 0.0)
	# Pelvis onto the seat: the rest pose stands it ~1 m over the root (the root rides at the seat).
	var hip_h: float = (a.rest_local(hips) as Transform3D).origin.y
	a.position = Vector3(SIT_HIPS.x, SIT_HIPS.y - hip_h, SIT_HIPS.z)
	var pilot := seat == 0
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		(a.thigh[i] as Node3D).rotation = Vector3(1.32, 0.0, side * 0.06)
		(a.shin[i] as Node3D).rotation = Vector3(-0.55, 0.0, 0.0)
		if pilot and i == 0:
			# Left hand in on the centre stick (skiff_build STICK_POS: under the seat's middle), the
			# right one out on the throttle by the console (THROTTLE_POS). (z: side × + = outward)
			(a.shoulder[i] as Node3D).rotation = Vector3(0.75, 0.0, -side * 0.25)
			(a.elbow[i] as Node3D).rotation = Vector3(0.55, 0.0, 0.0)
		elif pilot:
			(a.shoulder[i] as Node3D).rotation = Vector3(0.6, 0.0, side * 0.12)
			(a.elbow[i] as Node3D).rotation = Vector3(0.75, 0.0, 0.0)
		else:
			(a.shoulder[i] as Node3D).rotation = Vector3(0.35, 0.0, side * 0.1)
			(a.elbow[i] as Node3D).rotation = Vector3(1.0, 0.0, 0.0)
	_show_held("")


# =================================================================================================
# Events
# =================================================================================================

## A shot by this player: muzzle flash, tracer(s) to whatever the ray hits, an impact puff, 3D sound.
## sup: a suppressed shot (the gun's att_kit.suppressed()): no muzzle light, a quiet report.
func shot_fx(origin: Vector3, dir: Vector3, icon: String, sup := false) -> void:
	if not visible:
		return
	_use_vis = 0.25
	if icon in NO_BULLET:
		if icon in LOUD_HEAVY:
			load(SHOT_PINGS_PATH).call("add", origin, team, true)   # (the radar: a loud heavy shot)
		return             # (their blast / projectile comes as its own event)
	var tip_n: Node3D = astronaut.held_tip(icon) if icon != "" else null
	var muzzle := tip_n.global_position if tip_n != null else origin + dir * 0.6
	var pellets := 9 if icon == "shotgun" else 1
	# Impact calibre (rifle_fx.gd / erosion.gd): pellet 0.65, SMG 0.7, rifle 1, sniper 2.2.
	var cal: float = float({"shotgun": 0.65, "smg": 0.7, "sniper": 2.2, "pistol": 0.65, "mpistol": 0.6, "revolver": 1.3}.get(icon, 1.0))
	var side_team := team
	var space := get_world_3d().direct_space_state
	var ef = load(ENEMY_FIRE_PATH)
	for i in pellets:
		var d := dir
		if pellets > 1:
			d = (dir + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.045).normalized()
		var q := PhysicsRayQueryParameters3D.create(origin, origin + d * 600.0,
				Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE | Game.LAYER_PLAYER, [_col.get_rid()])
		var hit := space.intersect_ray(q)
		var end: Vector3 = hit["position"] if not hit.is_empty() else origin + d * 600.0
		var on_body := false
		if not hit.is_empty() and hit.get("collider") is CollisionObject3D:
			on_body = ((hit["collider"] as CollisionObject3D).collision_layer & Game.LAYER_PLAYER) != 0
		# The enemy-fire look (scripts/war/enemy_fire.gd): the streak in the shooter's colour (red when
		# he is our enemy), the muzzle star (not for a suppressed shot), the dirt where it lands; on the
		# HOST that impact also erodes cover (the client's bullets wear it down too: Erosion, synced as
		# digs). Pellets after the first: no second star.
		ef.call("shot", muzzle, end, side_team, on_body, 0.3, cal, not sup and i == 0, not sup)   # (loud: radar)
	_flash.global_position = muzzle
	_flash_t = 0.0 if sup else 1.0
	var snd := _heavy_audio if icon == "shotgun" or icon == "sniper" else _gun_audio
	snd.global_position = muzzle
	snd.volume_db = -13.0 if sup else 0.0
	snd.pitch_scale = 1.12 if sup else 1.0
	snd.play()


func _impact_puff(p: Vector3, n: Vector3) -> void:
	var cp := CPUParticles3D.new()
	cp.one_shot = true
	cp.amount = 10
	cp.lifetime = 0.6
	cp.explosiveness = 1.0
	var q := QuadMesh.new()
	q.size = Vector2(0.25, 0.25)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	cp.mesh = q
	cp.direction = n
	cp.spread = 35.0
	cp.initial_velocity_min = 1.5
	cp.initial_velocity_max = 4.0
	cp.gravity = -n * 4.0
	cp.color = Color(0.75, 0.66, 0.55, 0.8)
	var parent: Node = get_tree().current_scene if get_tree().current_scene != null else get_parent()
	parent.add_child(cp)
	cp.global_position = p + n * 0.05
	cp.emitting = true
	cp.finished.connect(cp.queue_free)


## The owner's F_RAG flag without a knockdown / death event first: an event that came while still seated
## (its launch), else the plain velocity (a later event within RAG_FIX s corrects it).
func _start_ragdoll() -> void:
	if not _rag_pending.is_empty() and _rag_pending_t < 1.0:
		var p := _rag_pending
		_rag_pending = []
		_begin_rag(bool(p[0]) or dead, p[1], str(p[2]), true)
		_rag_seen = true
		return
	_begin_rag(dead, _vel, "", false)


func _begin_rag(death: bool, v: Vector3, bone: String, evt: bool) -> void:
	_fx.set_working(false)
	var r: Node = _react.die(v, bone) if death else _react.knockdown(v, bone)
	if _ragdoll != null and _ragdoll != r and is_instance_valid(_ragdoll) and not _ragdoll.is_queued_for_deletion():
		_ragdoll.queue_free()
	_ragdoll = r
	_rag_dead = death
	_rag_evt = evt
	_rag_seen = not evt
	_rag_age = 0.0
	_rag_fallback = Vector3.INF if evt else v
	_rag_wait_clear = false
	_tag.visible = false


func _end_ragdoll() -> void:
	var r = _ragdoll
	_ragdoll = null
	if _rag_dead and r != null and is_instance_valid(r) and not r.is_queued_for_deletion():
		# The body stays where it fell (scripts/war/corpse.gd, local on each machine); a ragdoll still
		# moving is taken over (null back), else the pose is copied and we free it.
		r = Corpse.leave(astronaut, r, team, "peer")
	_react.reset()
	if r != null and is_instance_valid(r) and not r.is_queued_for_deletion():
		r.queue_free()
	_rag_dead = false
	_rag_evt = false
	_rag_fallback = Vector3.INF
	astronaut.transform = Transform3D.IDENTITY
	astronaut.reset_pose()
	_held_shown = "-"
	_prev_fwd = Vector3.ZERO


## Our mirrored get-up has ended (net_react.gd recovered; the reactor freed the ragdoll).
func _on_recovered() -> void:
	_ragdoll = null
	_rag_dead = false
	_rag_evt = false
	_rag_fallback = Vector3.INF
	_rag_wait_clear = (_flags & F_RAG) != 0
	_fix_pending = true
	_held_shown = "-"
	_prev_fwd = Vector3.ZERO
	_tag.visible = not dead


## The other player's hit reaction (its player.hit_reacted, net_players.gd): kind "flinch" / "stagger"
## / "knockdown" / "death" / "getup", dir × strength = the velocity (getup: facing, duration s), bone =
## the struck part. Knockdown / death start our ragdoll at once (the owner's F_RAG comes ~0.1 s later
## with the buffered state).
func react_event(kind: String, dir: Vector3, strength: float, bone: String) -> void:
	if not _have_state:
		return
	match kind:
		"flinch", "stagger":
			if _ragdoll == null and not in_vehicle and not dead:
				_react.react(kind, dir, strength, bone)
		"knockdown", "death":
			_rag_event(kind == "death", dir * strength, bone)
		"getup":
			if _ragdoll != null and not dead:
				_react.getup(dir, strength)


func _rag_event(death: bool, v: Vector3, bone: String) -> void:
	if in_vehicle:
		_rag_pending = [death, v, bone]    # (it left the seat first: the flag starts it with this)
		_rag_pending_t = 0.0
		return
	_rag_pending = []
	if _ragdoll != null and is_instance_valid(_ragdoll) and not _react.is_getting_up():
		if _rag_fallback != Vector3.INF and _rag_age < RAG_FIX:
			# The flag started it a moment ago with the plain velocity: correct the launch.
			_react.add_launch(_ragdoll, v - _rag_fallback, bone)
			_rag_fallback = Vector3.INF
			_rag_evt = true
			_rag_seen = true
		return                             # (already down: a death then keeps it, see _process)
	_begin_rag(death or dead, v, bone, true)


func _exit_tree() -> void:
	_react.reset()
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null


# =================================================================================================
# Damage (host: this is the other player's hp)
# =================================================================================================

func is_dead() -> bool:
	return dead


func take_damage(amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO, own := false) -> Dictionary:
	if not Net.is_server or dead or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	if in_vehicle and _seat_vehicle() != null and not own:
		return {"dmg": 0.0, "killed": false}       # the skiff hull takes the hits
	if shield > 0.0:
		# The owner's relic Kalkan eats what it can; its machine plays the absorb (send_shield_hit).
		var take := minf(shield, amount)
		shield -= take
		amount -= take
		Net.players.send_shield_hit(take)
		if amount <= 0.0:
			return {"dmg": 0.0, "killed": false}
	if Downed.is_downed(self):               # down: the hit drains its bleed-out (scripts/war/downed.gd)
		var dr: Dictionary = Downed.hurt_downed(self, amount, from_pos, impulse)
		Net.players.send_hurt(amount, from_pos, impulse, 0.0, Net.world.pack_point(self, Game.hit_pos))
		return dr
	var hp0 := hp
	hp = maxf(hp - amount, 0.0)
	_since_hit = 0.0
	var killed := hp <= 0.0
	if killed and Downed.try_down(self, amount, from_pos, impulse, hp0):
		killed = false                       # down, not dead: events().downed -> its owner (net_players.gd)
	if killed:
		dead = true
	Net.players.send_hurt(amount, from_pos, impulse, hp, Net.world.pack_point(self, Game.hit_pos))
	return {"dmg": amount, "killed": killed}


## Host: the owner respawned.
func mirror_respawn() -> void:
	hp = hp_max
	shield = 0.0
	dead = false
	_since_hit = 99.0


## Host: something knocked the other player over (the Kinetik İtici's blast): its owner ragdolls.
func ragdoll(impulse: Vector3, duration := 2.5, _exclude: Array = []) -> void:
	if Net.is_server and not dead and not in_vehicle:
		Net.players.send_knock(impulse, duration)


## The other player swung the dipçik (player.melee_swung, scripts/player/melee.gd): the arms drive
## the held item forward with the chest turning into it (MELEE_TIME s) and the whoosh. The hit
## itself is a claim / the host's (Game.damage_target).
func melee_fx(_dir: Vector3) -> void:
	if not visible or dead or in_vehicle or _ragdoll != null:
		return
	_melee_t = 0.0
	_use_vis = 0.45
	_whoosh_audio.pitch_scale = randf_range(0.92, 1.05)
	get_tree().create_timer(0.1).timeout.connect(_whoosh_audio.play)


func _melee_pose(delta: float) -> void:
	if _melee_t < 0.0:
		return
	_melee_t += delta
	var total := 0.45
	if _melee_t >= total or dead or _ragdoll != null:
		_melee_t = -1.0
		return
	var k := _melee_t / total
	# Wind-up (chest turns away, arms back), strike at ~35 %, recovery.
	var wind := smoothstep(0.0, 0.25, k) * (1.0 - smoothstep(0.25, 0.4, k))
	var strike := smoothstep(0.25, 0.38, k) * (1.0 - smoothstep(0.55, 1.0, k))
	var a = astronaut
	var rot: Dictionary = a.get("_rot")
	var ch = a.chest
	if ch is Node3D:
		(ch as Node3D).rotation = (rot.get(ch, (ch as Node3D).rotation) as Vector3) + Vector3(0.12 * strike, 0.45 * wind - 0.5 * strike, 0.0)
	for i in 2:
		var sh = a.shoulder[i]
		var el = a.elbow[i]
		if sh is Node3D:
			var base: Vector3 = rot.get(sh, (sh as Node3D).rotation)
			(sh as Node3D).rotation = base + Vector3(-0.35 * wind + 0.75 * strike, 0.0, 0.0)
		if el is Node3D:
			var eb: Vector3 = rot.get(el, (el as Node3D).rotation)
			(el as Node3D).rotation = eb.lerp(Vector3(0.25, 0.0, 0.0), strike * 0.8)


## The other player mantled a ledge `height` m high (player.mantled, scripts/player/mantle.gd): a climb
## pose over the replicated movement, as long as the owner's pull + roll-over (Balance MANTLE_T_RISE +
## MANTLE_T_OVER: ~0.34 s for a 0.45 m ledge .. ~0.64 s at 1.9 m).
func mantle_fx(height: float) -> void:
	if not visible or dead or in_vehicle or _ragdoll != null:
		return
	_mantle_len = lerpf(0.34, 0.64, clampf((height - 0.45) / 1.45, 0.0, 1.0))
	_mantle_t = 0.0


## Arms up to the edge, then pushing down on it with the knees tucked, the torso leaning over; blended
## out at the end (bone rotations: +X swings an arm / thigh forward, -X bends a knee).
func _mantle_pose(delta: float) -> void:
	if _mantle_t < 0.0:
		return
	_mantle_t += delta
	if _mantle_t >= _mantle_len or dead or _ragdoll != null or in_vehicle:
		_mantle_t = -1.0
		return
	var k := _mantle_t / _mantle_len
	var reach := smoothstep(0.0, 0.15, k) * (1.0 - smoothstep(0.28, 0.5, k))
	var push := smoothstep(0.28, 0.48, k) * (1.0 - smoothstep(0.72, 1.0, k))
	var tuck := smoothstep(0.22, 0.42, k) * (1.0 - smoothstep(0.68, 1.0, k))
	var a = astronaut
	var rot: Dictionary = a.get("_rot")
	var ch = a.chest
	if ch is Node3D:
		(ch as Node3D).rotation = (rot.get(ch, (ch as Node3D).rotation) as Vector3) + Vector3(-0.4 * push, 0.0, 0.0)
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var sh = a.shoulder[i]
		var el = a.elbow[i]
		var th = a.thigh[i]
		var sn = a.shin[i]
		if sh is Node3D:
			var s0: Vector3 = rot.get(sh, (sh as Node3D).rotation)
			(sh as Node3D).rotation = s0.lerp(Vector3(2.7, 0.0, side * 0.25), reach).lerp(Vector3(0.9, 0.0, side * 0.35), push)
		if el is Node3D:
			var e0: Vector3 = rot.get(el, (el as Node3D).rotation)
			(el as Node3D).rotation = e0.lerp(Vector3(0.25, 0.0, 0.0), reach).lerp(Vector3(1.5, 0.0, 0.0), push)
		if th is Node3D:
			var t0: Vector3 = rot.get(th, (th as Node3D).rotation)
			(th as Node3D).rotation = t0.lerp(Vector3(1.25 if i == 0 else 0.9, 0.0, side * 0.05), tuck)
		if sn is Node3D:
			var n0: Vector3 = rot.get(sn, (sn as Node3D).rotation)
			(sn as Node3D).rotation = n0.lerp(Vector3(-1.6, 0.0, 0.0), tuck)
