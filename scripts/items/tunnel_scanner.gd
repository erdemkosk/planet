extends Node3D
## Tünel tarayıcı: the wrist scanner. scripts/player/hand_action.gd raises the left wrist on Q and
## calls pulse(). A pulse sends a scan wave out from the player (Balance.SCAN_WAVE_SPEED, out to
## SCAN_RANGE): a deferred, depth-reconstructed band that sweeps over the ground (bright front line,
## expanding rings and a faint voxel grid in its wake), with a sci-fi sweep sound. Everything of the
## ENEMY (any side other than Game.team_of(player)) within SCAN_RANGE lights up when the front
## reaches it and stays for SCAN_TIME s, drawn THROUGH the terrain (x-ray: no depth test), fading out
## at the end:
##   bots (group "war_ai", scripts/war/ai_rival.gd: team, is_dead(), callsign): a red x-ray
##     silhouette (a material overlay on the bot's skinned suit: a faint rim where it is in plain
##     sight, a banded red fill where something hides it), a diamond over it and, for the nearest
##     LABEL_MAX, a label (name, distance, "derinlik X m" when underground). Tracked live.
##   drilling torpedoes (group "war_torpedo", scripts/war/torpedo.gd: team, is_burrowing(), depth(),
##     core_distance(); read with has_method guards): a pulsing marker, "TORPİDO · çekirdeğe X m"
##     and a dashed x-ray line down to the core. Tracked live.
##   tunnels (scripts/war/tunnel_log.gd points of the enemy side on the planet you stand on, deeper
##     than SCAN_TUNNEL_DEPTH below the ORIGINAL surface, not refilled since): glowing x-ray tube
##     strands (MultiMeshes: tube segments joining each point to its nearest earlier neighbour, plus
##     joints), newer digs brighter. The tubes appear exactly where the wave front passes.
## The wrist computer (scripts/player/wrist_display.gd set_scan) shows a radar of the reveal while
## the wrist is up or the reveal runs (azimuthal around you: the planet is the disc, its far side
## the rim) with the counts, and the recharge on its normal page.
##
##   rich veins (scripts/planet/veins.gd, not dug out) and meteor cores on the planet you stand on: a
##     glowing crystal x-ray blob (cyan, gold for the contested rich ones, ember for cores), labels
##     "Zengin damar · derinlik X m" for the nearest LABEL_MAX ("Veins and buried caches", end of file)
##   buried caches: any node in group "buried_cache" with scan_point() -> Vector3 (optional
##     scan_label() -> String): a green x-ray diamond, "Gömülü sandık · derinlik X m" (duck typed)
##
## API: player, wrist_up (set by hand_action), can_pulse(), cooldown_left(), pulse() -> bool,
## deny() (error beep + "şarj oluyor" message), revealing(), counts() -> {"bots", "torpedoes",
## "tunnel_m", "veins", "caches"}; signal pulsed(origin). Purely local: no game state changes, nothing
## to sync.
##   revealed_targets() -> Array   read-only, what the reveal marks right now (empty when none):
##       [{"kind": "bot" / "torpedo" / "vein" / "core" / "cache", "node": Node3D (null for veins),
##       "pos": Vector3 (world, live for nodes), "alpha": 0..1}] (e.g. a mortar locking onto marks)

signal pulsed(origin: Vector3)

const Balance := preload("res://scripts/war/balance.gd")
const TunnelLog := preload("res://scripts/war/tunnel_log.gd")
const VM := preload("res://scripts/player/vm_parts.gd")
const UI := preload("res://scripts/ui/ui_style.gd")

const TINT := Color(0.35, 0.9, 1.0)
const ENEMY := Color(1.0, 0.3, 0.2)
const TORP := Color(1.0, 0.62, 0.16)
const TUNNEL := Color(1.0, 0.42, 0.18)
const FADE_OUT := 1.5                # s: the reveal fades over the end of SCAN_TIME
const LABEL_MAX := 8                 # labels for the nearest bots (every bot gets a diamond)
## HUD level (scripts/ui/hud_level.gd): Sade keeps the pulse itself (the wave, the x-ray, the
## diamonds, torpedo labels and cache labels) with no bot labels and only the nearest vein's; Normal
## labels the nearest few; Detaylı the nearest LABEL_MAX. The summary toast is info (dropped in Sade)
## unless it found torpedoes (critical: they bore toward a core).
const HudLevel := preload("res://scripts/ui/hud_level.gd")
const LABELS_BY_LEVEL := [0, 3, LABEL_MAX]       # bot labels per level
const VEIN_LABELS_BY_LEVEL := [1, 3, LABEL_MAX]  # vein / meteor core labels per level
const CELL := 3.0                    # m: tunnel link grid
const LINK_K := 2.6                  # points closer than LINK_K × dig radius join into a strand...
const LINK_MIN := 1.6                # ...but at least this (m)
const TUBE_K := 0.5                  # drawn tube radius / dig radius
const POINT_BUDGET := 120            # tunnel points checked per frame (the wave reveals them in order)
const RADAR_TUNNEL_MAX := 90
const WAVE_BAND := 10.0              # m of glowing wake behind the wave front
const RATE := 44100

## Scan wave: the back faces of a sphere around the origin, drawn without a depth test; each pixel
## rebuilds the scene point behind it from the depth buffer and lights it by its distance from the
## origin. Sky and the view-model arms are skipped.
const WAVE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec3 origin = vec3(0.0);
uniform float radius = 0.0;
uniform float fade = 1.0;
uniform float band = 10.0;
uniform vec3 tint : source_color = vec3(0.35, 0.9, 1.0);

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 p = vp.xyz / vp.w;
	float vz = -p.z;
	if (vz < 0.9 || vz > 400.0) {
		discard;
	}
	vec3 wp = (INV_VIEW_MATRIX * vec4(p, 1.0)).xyz;
	float d = length(wp - origin);
	float behind = radius - d;
	if (behind < -1.5 || behind > band) {
		discard;
	}
	float aa = clamp(fwidth(d), 0.01, 1.5);
	float front = 1.0 - smoothstep(0.0, 0.12 + aa * 1.5, abs(behind));
	float lead = exp(-max(-behind, 0.0) * 3.0) * step(behind, 0.0) * 0.3;
	float k = clamp(behind / band, 0.0, 1.0);
	float trail = (1.0 - k) * (1.0 - k) * step(0.0, behind);
	float rl = abs(fract(d / 1.5 + 0.5) - 0.5) * 1.5;
	float rings = (1.0 - smoothstep(0.02, 0.02 + aa * 1.5, rl)) * trail;
	vec3 g = abs(fract(wp * 0.8 + 0.5) - 0.5) / 0.8;
	vec3 gw = clamp(fwidth(wp) * 1.5, vec3(0.005), vec3(0.4));
	vec3 gl = vec3(1.0) - smoothstep(vec3(0.0), gw + vec3(0.015), g);
	float grid = max(max(gl.x, gl.y), gl.z) * trail;
	vec3 col = tint * (trail * 0.06 + rings * 0.42 + grid * 0.14 + lead) + mix(tint, vec3(1.0), 0.5) * front * 0.8;
	ALBEDO = col;
	ALPHA = clamp(fade, 0.0, 1.0);
}
"""

## X-ray silhouette (material overlay on a bot's skinned suit): where the bot is hidden behind
## something its body glows red with bands running up; where it is in plain sight only a faint rim.
const XRAY_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_test_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 color : source_color = vec4(1.0, 0.3, 0.2, 1.0);
uniform float k = 0.0;

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -vp.z / vp.w;
	float hidden = smoothstep(0.04, 0.3, -VERTEX.z - scene_z);
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.2);
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 up = normalize(MODEL_MATRIX[1].xyz);
	float h = dot(wp - MODEL_MATRIX[3].xyz, up);
	float f = fract(h * 7.0 - TIME * 1.4);
	float bands = 0.6 + 0.4 * smoothstep(0.0, 0.15, f) * (1.0 - smoothstep(0.5, 0.65, f));
	float a = mix(rim * 0.4, (0.14 + rim * 0.8) * bands, hidden);
	ALBEDO = color.rgb * (1.0 + rim * 0.5);
	ALPHA = clamp(a * k, 0.0, 1.0);
}
"""

## Markers (diamonds, rings) seen through everything.
const MARK_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_test_disabled, depth_draw_never, shadows_disabled;

uniform vec4 tint : source_color = vec4(1.0, 0.3, 0.2, 1.0);
uniform float alpha = 1.0;

void fragment() {
	float rim = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.5);
	ALBEDO = tint.rgb * (1.05 + rim * 0.7);
	ALPHA = clamp(alpha * (0.62 + 0.38 * rim), 0.0, 1.0);
}
"""

## Tunnel strands (MultiMesh; INSTANCE_CUSTOM.r = brightness by age): hollow x-ray tubes (bright
## rim, faint middle) or joints, shown only behind the wave front, flaring as the front passes.
const TUBE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_test_disabled, depth_draw_never, shadows_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.42, 0.18, 1.0);
uniform vec3 origin = vec3(0.0);
uniform float wave_r = 0.0;
uniform float fade = 0.0;
uniform float joint = 0.0;
varying float v_bright;

void vertex() {
	v_bright = INSTANCE_CUSTOM.r;
}

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float since = wave_r - length(wp - origin);
	if (since < 0.0) {
		discard;
	}
	float pop = exp(-since * 0.3);
	float rim = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.7);
	float flow = 0.7 + 0.3 * sin(dot(wp, vec3(1.3, 1.7, 1.1)) * 2.0 - TIME * 4.0);
	float body = mix(0.07 + rim * 0.45, 0.4 + rim * 0.35, joint);
	ALBEDO = mix(color.rgb, vec3(1.0, 0.85, 0.7), pop * 0.6);
	ALPHA = clamp((body * flow * (0.3 + 0.7 * v_bright) + pop * 0.45) * fade, 0.0, 1.0);
}
"""

## Dashed x-ray line from a burrowing torpedo down to the core (dashes flow toward the core).
const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.62, 0.16, 1.0);
uniform float fade = 1.0;
uniform float seg_len = 10.0;
varying float v_s;

void vertex() {
	v_s = (0.5 - VERTEX.y) * seg_len;
}

void fragment() {
	float f = fract(v_s * 1.1 - TIME * 2.4);
	float dash = smoothstep(0.0, 0.08, f) * (1.0 - smoothstep(0.5, 0.58, f));
	float body = 1.0 - pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 2.0);
	ALBEDO = color.rgb * 1.3;
	ALPHA = clamp((0.1 + 0.8 * dash) * (0.4 + 0.6 * body) * fade, 0.0, 1.0);
}
"""

var player
var wrist_up := false            # hand_action: the wrist is raised (the radar page shows)

var _cool := 0.0
var _t := -1.0                   # s since the pulse; < 0 = nothing revealed
var _origin := Vector3.ZERO
var _body: Node3D
var _range := 130.0
var _my_team := "home"
## {node, d, shown, k, k_set, pop, label, meshes, mats, dia, dmat, lbl, under}
var _bots: Array = []
## {node, d, shown, k, pop, dia, dmat, ring, rmat, beam, bmat, lbl}
var _torps: Array = []
# Tunnel points of this pulse (world, dig radius, age s, distance from the origin, -1/0/1 checked).
var _pp := PackedVector3Array()
var _pr := PackedFloat32Array()
var _pa := PackedFloat32Array()
var _pd := PackedFloat32Array()
var _pok := PackedInt32Array()
var _order := PackedInt32Array()
var _grid := {}                  # Vector3i cell -> Array of point indices
var _next_pt := 0
var _accepted := 0
var _seg_n := 0
var _joint_n := 0
var _seg_d := PackedFloat32Array()     # reveal distance (nearer end) of each strand segment
var _seg_len := PackedFloat32Array()
var _radar_pts := PackedVector3Array()
var _segs: MultiMeshInstance3D
var _joints: MultiMeshInstance3D
var _tube_mat: ShaderMaterial
var _joint_mat: ShaderMaterial
# Wave
var _wave: MeshInstance3D
var _wave_mat: ShaderMaterial
var _flash: OmniLight3D
# Shared resources
var _xray_shader: Shader
var _mark_shader: Shader
var _beam_shader: Shader
var _gem_mesh: Mesh
var _ring_mesh: Mesh
var _beam_mesh: Mesh
# Wrist / misc
var _wrist: Node
var _wrist_seek := 0.0
var _push_t := 0.0
var _push_on := false
var _label_t := 0.0
var _summary := false
var _blip_t := 0.0
var _tun_seen := false
var _tun_m := 0.0
var _tun_m_t := 0.0
# Sounds (synthesized on a worker thread).
var _audio: Array = []
var _ai := 0
var _task := -1
var _mutex := Mutex.new()
var _snd := {}


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_build_shared()
	_build_wave()
	_segs = _make_mm(_tube_mesh(), _tube_mat)
	_joints = _make_mm(_joint_mesh(), _joint_mat)
	for i in 4:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_audio.append(p)
	_task = WorkerThreadPool.add_task(_build_snd, false, "scan_audio")


func _exit_tree() -> void:
	_restore_overlays()
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


# --- API ------------------------------------------------------------------------------------------

func can_pulse() -> bool:
	return _cool <= 0.0


func cooldown_left() -> float:
	return _cool


func revealing() -> bool:
	return _t >= 0.0


## Q while it recharges: an error beep and how long it still takes.
func deny() -> void:
	_play("deny", -9.0, 1.0)
	HudLevel.alert("Tarayıcı şarj oluyor — %d sn" % ceili(_cool), 1, "scan_deny", 1.4)


## What the current reveal shows (revealed so far).
func counts() -> Dictionary:
	var a := _count_arr()
	return {"bots": a[0], "torpedoes": a[1], "tunnel_m": a[2], "veins": a[3], "caches": a[4]}


## Sends a scan pulse from the player. False while it recharges.
func pulse() -> bool:
	if not can_pulse() or player == null or not is_instance_valid(player):
		return false
	_clear()
	_cool = Balance.SCAN_COOLDOWN
	_range = Balance.SCAN_RANGE
	var feet: Vector3 = player.global_position
	_body = Game.dominant_body(feet)
	_origin = feet + _up(feet) * 0.4
	_my_team = Game.team_of(player)
	_t = 0.0
	_summary = false
	_tun_seen = false
	_gather_bots()
	_gather_torps()
	_gather_tunnels()
	_vn_gather()                       # veins, meteor cores, buried caches (end of file)
	_wave.visible = true
	_flash.global_position = _origin + _up(feet) * 0.8
	_flash.visible = true
	_update_wave()
	_play("sweep", -5.0, 1.0)
	pulsed.emit(_origin)
	return true


# --- Per frame ------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _cool > 0.0:
		_cool = maxf(_cool - delta, 0.0)
		if _cool <= 0.0:
			_play("ready", -16.0, 1.0)
	if _t >= 0.0:
		_t += delta
		if _t >= Balance.SCAN_TIME or player == null or not is_instance_valid(player):
			_clear()
		else:
			_update_wave()
			_process_tunnels()
			_update_tunnels(delta)
			_update_bots(delta)
			_update_torps(delta)
			_vn_update(delta)          # veins, meteor cores, buried caches (end of file)
			if not _summary and _wave_r() >= _range:
				_summary = true
				_announce()
	_blip_t -= delta
	_push_wrist(delta)


func _wave_r() -> float:
	return maxf(_t, 0.0) * Balance.SCAN_WAVE_SPEED


## 1 during the reveal, falling to 0 over its last FADE_OUT s.
func _fade() -> float:
	return clampf((Balance.SCAN_TIME - _t) / FADE_OUT, 0.0, 1.0)


func _update_wave() -> void:
	var r := _wave_r()
	var k := r / maxf(_range, 1.0)
	_flash.light_energy = 2.4 * exp(-_t * 5.0)
	_flash.visible = _flash.light_energy > 0.03
	if k >= 1.0:
		_wave.visible = false
		return
	_wave.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * (r + 3.0)), _origin)
	_wave_mat.set_shader_parameter("origin", _origin)
	_wave_mat.set_shader_parameter("radius", r)
	_wave_mat.set_shader_parameter("fade", (1.0 - smoothstep(0.6, 1.0, k)) * minf(_t * 12.0, 1.0))


func _announce() -> void:
	var c := _count_arr()
	if Game.hud:
		var parts := PackedStringArray()
		if c[0] > 0:
			parts.append("%d bot" % c[0])
		if c[1] > 0:
			parts.append("%d torpido" % c[1])
		if c[2] > 0:
			parts.append("%d m tünel" % c[2])
		parts.append_array(_vn_announce_parts())   # damar / sandık (end of file)
		if parts.is_empty():
			HudLevel.alert("Tarama: %d m içinde düşman izi yok" % int(_range), 0, "scan", 2.5)
		else:
			# Torpedoes boring toward a core: critical (the alarm below is its sound).
			HudLevel.alert("Tarama: " + " · ".join(parts), 2 if c[1] > 0 else 0, "scan", 3.5, c[1] <= 0)
	if c[1] > 0:
		_play("alarm", -10.0, 1.0)


# --- Bots ---------------------------------------------------------------------------------------

func _enemy(n: Object) -> bool:
	var tm := Game.team_of(n)
	return tm != "" and tm != _my_team


func _gather_bots() -> void:
	for n in get_tree().get_nodes_in_group("war_ai"):
		if not (n is Node3D) or not _enemy(n):
			continue
		if n.has_method("is_dead") and n.is_dead():
			continue
		var d := (n as Node3D).global_position.distance_to(_origin)
		if d > _range:
			continue
		_bots.append({"node": n, "d": d, "shown": false, "k": 0.0, "k_set": -1.0, "pop": 0.0, "label": false,
				"meshes": [], "mats": [], "dia": null, "dmat": null, "lbl": null, "under": false})
	_bots.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	for i in mini(_bots.size(), int(LABELS_BY_LEVEL[clampi(HudLevel.shown_level(), 0, 2)])):
		_bots[i]["label"] = true


func _show_bot(b: Dictionary) -> void:
	b["shown"] = true
	b["pop"] = 1.0
	var n: Node = b["node"]
	# X-ray overlay on the skinned suit (restored when the reveal ends).
	var a = n.get("astronaut")
	var root: Node = a if a is Node else n
	for c in root.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi == null or mi.skin == null or mi.material_overlay != null:
			continue
		var m := ShaderMaterial.new()
		m.shader = _xray_shader
		m.set_shader_parameter("color", ENEMY)
		m.set_shader_parameter("k", 0.0)
		mi.material_overlay = m
		(b["meshes"] as Array).append(mi)
		(b["mats"] as Array).append(m)
	var dm := _mark_mat(ENEMY)
	b["dmat"] = dm
	b["dia"] = _mesh_child(_gem_mesh, dm)
	if b["label"]:
		b["lbl"] = _label(ENEMY.lightened(0.3))


func _update_bots(delta: float) -> void:
	var r := _wave_r()
	var f := _fade()
	var cp: Vector3 = player.camera.global_position if player.camera != null else player.global_position
	var me: Vector3 = player.global_position
	_label_t -= delta
	var relabel := _label_t <= 0.0
	if relabel:
		_label_t = 0.2
	var idx := 0
	for b: Dictionary in _bots:
		idx += 1
		var n = b["node"]
		var valid := is_instance_valid(n)
		if not b["shown"]:
			if not valid or float(b["d"]) > r or (n.has_method("is_dead") and n.is_dead()):
				continue
			_show_bot(b)
			_blip(1.0)
		var dead: bool = not valid or (n.has_method("is_dead") and n.is_dead())
		b["k"] = move_toward(float(b["k"]), 0.0 if dead else 1.0, delta * (2.5 if dead else 4.0))
		b["pop"] = maxf(float(b["pop"]) - delta * 3.0, 0.0)
		var a := float(b["k"]) * f
		if absf(a - float(b["k_set"])) > 0.01 or (a <= 0.0 and float(b["k_set"]) > 0.0):
			b["k_set"] = a
			for m: ShaderMaterial in b["mats"]:
				m.set_shader_parameter("k", a)
			(b["dmat"] as ShaderMaterial).set_shader_parameter("alpha", a * 0.85)
		var dia: MeshInstance3D = b["dia"]
		var lbl: Label3D = b["lbl"]
		if not valid or a <= 0.0:
			dia.visible = false
			if lbl != null:
				lbl.visible = false
			if dead and float(b["k"]) <= 0.0:
				_drop_overlay(b)
			continue
		var p: Vector3 = (n as Node3D).global_position
		var up := _up(p)
		var gem_p := p + up * 2.3
		var dist := cp.distance_to(gem_p)
		var s := clampf(dist * 0.022, 0.16, 1.4) * (1.0 + 0.7 * float(b["pop"]))
		var ub := VM.basis_y(up).rotated(up, _t * 2.0)
		dia.visible = true
		dia.global_transform = Transform3D(ub * Basis.from_scale(Vector3(s, s * 1.25, s)),
				gem_p + up * sin(_t * 3.0 + idx) * 0.06 * s)
		if lbl != null:
			lbl.visible = true
			lbl.global_position = gem_p + up * (0.55 * s + 0.12)
			lbl.modulate.a = a
			lbl.outline_modulate.a = 0.7 * a
			if relabel:
				var depth := _depth_below(p)
				b["under"] = depth > Balance.SCAN_TUNNEL_DEPTH
				var txt := "%s · %d m" % [_short_name(n), roundi(me.distance_to(p))]
				if dead:
					txt = "%s · düştü" % _short_name(n)
				elif b["under"]:
					txt += "\nderinlik %.0f m" % depth
				if lbl.text != txt:
					lbl.text = txt
		elif relabel:
			b["under"] = _depth_below(p) > Balance.SCAN_TUNNEL_DEPTH


func _short_name(n: Object) -> String:
	var cs := str(n.get("callsign")) if n.get("callsign") != null else ""
	if cs == "":
		return "Bot"
	var parts := cs.split(" — ")
	return parts[parts.size() - 1]


func _drop_overlay(b: Dictionary) -> void:
	var mats: Array = b["mats"]
	var meshes: Array = b["meshes"]
	for i in meshes.size():
		var mi = meshes[i]
		if is_instance_valid(mi) and (mi as MeshInstance3D).material_overlay == mats[i]:
			(mi as MeshInstance3D).material_overlay = null
	meshes.clear()
	mats.clear()


func _restore_overlays() -> void:
	for b: Dictionary in _bots:
		_drop_overlay(b)


# --- Torpedoes ----------------------------------------------------------------------------------

func _gather_torps() -> void:
	for n in get_tree().get_nodes_in_group("war_torpedo"):
		if not (n is Node3D) or not _enemy(n):
			continue
		var d := (n as Node3D).global_position.distance_to(_origin)
		if d > _range:
			continue
		_torps.append({"node": n, "d": d, "shown": false, "k": 0.0, "pop": 0.0, "dia": null, "dmat": null,
				"ring": null, "rmat": null, "beam": null, "bmat": null, "lbl": null})


func _show_torp(t: Dictionary) -> void:
	t["shown"] = true
	t["pop"] = 1.0
	t["dmat"] = _mark_mat(TORP)
	t["dia"] = _mesh_child(_gem_mesh, t["dmat"])
	t["rmat"] = _mark_mat(TORP)
	t["ring"] = _mesh_child(_ring_mesh, t["rmat"])
	var bm := ShaderMaterial.new()
	bm.shader = _beam_shader
	bm.set_shader_parameter("color", TORP)
	bm.render_priority = 9
	t["bmat"] = bm
	t["beam"] = _mesh_child(_beam_mesh, bm)
	t["lbl"] = _label(TORP.lightened(0.25))


func _update_torps(delta: float) -> void:
	var r := _wave_r()
	var f := _fade()
	var cp: Vector3 = player.camera.global_position if player.camera != null else player.global_position
	for t: Dictionary in _torps:
		var n = t["node"]
		var valid := is_instance_valid(n) and (n as Node).is_inside_tree()
		if not t["shown"]:
			if not valid or float(t["d"]) > r:
				continue
			_show_torp(t)
			_blip(0.72)
		t["k"] = move_toward(float(t["k"]), 1.0 if valid else 0.0, delta * (4.0 if valid else 3.0))
		t["pop"] = maxf(float(t["pop"]) - delta * 3.0, 0.0)
		var a := float(t["k"]) * f
		var dia: MeshInstance3D = t["dia"]
		var ring: MeshInstance3D = t["ring"]
		var beam: MeshInstance3D = t["beam"]
		var lbl: Label3D = t["lbl"]
		if not valid or a <= 0.0:
			dia.visible = false
			ring.visible = false
			beam.visible = false
			lbl.visible = false
			continue
		var p: Vector3 = (n as Node3D).global_position
		var body := Game.dominant_body(p)
		var c: Vector3 = body.global_position if body != null else Game.planet_center()
		var up := _up(p)
		var burrow: bool = n.has_method("is_burrowing") and bool(n.is_burrowing())
		var core_d: float = float(n.core_distance()) if n.has_method("core_distance") \
				else maxf(p.distance_to(c) - Balance.CORE_RADIUS, 0.0)
		var dist := cp.distance_to(p)
		var s := clampf(dist * 0.02, 0.14, 1.3)
		var beat := 0.5 + 0.5 * sin(_t * (9.0 if burrow else 5.0))
		dia.visible = true
		dia.global_transform = Transform3D(VM.basis_y(up).rotated(up, -_t * 3.0)
				* Basis.from_scale(Vector3.ONE * s * (0.9 + 0.2 * beat + 0.7 * float(t["pop"]))), p + up * 1.1 * s)
		(t["dmat"] as ShaderMaterial).set_shader_parameter("alpha", a * 0.9)
		ring.visible = true
		var rs := s * (1.6 + 0.9 * fmod(_t * 1.2, 1.0))
		ring.global_transform = Transform3D(VM.basis_y(cp - p) * Basis.from_scale(Vector3.ONE * rs), p)
		(t["rmat"] as ShaderMaterial).set_shader_parameter("alpha", a * 0.7 * (1.0 - fmod(_t * 1.2, 1.0)))
		# Dashed line to the core (only while it bores toward it).
		beam.visible = burrow
		if burrow:
			var dir := (p - c).normalized() if p.distance_to(c) > 0.01 else up
			var end := c + dir * Balance.CORE_RADIUS
			var ln := maxf(p.distance_to(end), 0.05)
			var br := clampf(dist * 0.0035, 0.04, 0.3)
			var bb := VM.basis_y(p - end)
			beam.global_transform = Transform3D(Basis(bb.x * br, bb.y * ln, bb.z * br), (p + end) * 0.5)
			var bm: ShaderMaterial = t["bmat"]
			bm.set_shader_parameter("seg_len", ln)
			bm.set_shader_parameter("fade", a)
		lbl.visible = true
		lbl.global_position = p + up * (2.2 * s + 0.2)
		lbl.modulate.a = a
		lbl.outline_modulate.a = 0.7 * a
		var txt := "TORPİDO · çekirdeğe %d m" % roundi(core_d) if burrow else "TORPİDO · uçuşta"
		if burrow and n.has_method("depth"):
			txt += "\nderinlik %.0f m" % float(n.depth())
		if lbl.text != txt:
			lbl.text = txt


# --- Tunnels ------------------------------------------------------------------------------------

func _reset_tunnels() -> void:
	_pp = PackedVector3Array()
	_pr = PackedFloat32Array()
	_pa = PackedFloat32Array()
	_pd = PackedFloat32Array()
	_pok = PackedInt32Array()
	_order = PackedInt32Array()
	_grid = {}
	_next_pt = 0
	_accepted = 0
	_seg_n = 0
	_joint_n = 0
	_seg_d = PackedFloat32Array()
	_seg_len = PackedFloat32Array()
	_radar_pts = PackedVector3Array()
	_tun_m = 0.0
	if _segs != null:
		_segs.multimesh.visible_instance_count = 0
		_segs.visible = false
		_joints.multimesh.visible_instance_count = 0
		_joints.visible = false


## Collects the enemy's logged dig points on this planet within range, bucketed by distance (the
## per-frame check then runs in about the order the wave reveals them) and gridded for linking.
func _gather_tunnels() -> void:
	_reset_tunnels()
	if _body == null or not is_instance_valid(_body):
		return
	var enemy := "rival" if _my_team == "home" else "home"
	var raw: Array = TunnelLog.points(_body, enemy)
	if raw.is_empty():
		return
	var nb := int(ceilf(_range / 4.0)) + 1
	var buckets: Array = []
	for i in nb:
		buckets.append([])
	for e: Dictionary in raw:
		var p: Vector3 = e["p"]
		var d := p.distance_to(_origin)
		if d > _range:
			continue
		var i := _pp.size()
		_pp.append(p)
		_pr.append(float(e["r"]))
		_pa.append(float(e["t"]))
		_pd.append(d)
		_pok.append(-1)
		var key := Vector3i((p / CELL).floor())
		if not _grid.has(key):
			_grid[key] = []
		(_grid[key] as Array).append(i)
		(buckets[mini(int(d / 4.0), nb - 1)] as Array).append(i)
	for bk: Array in buckets:
		for i in bk:
			_order.append(int(i))
	var n := _pp.size()
	if n == 0:
		return
	for mmi in [_segs, _joints]:
		var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
		mm.visible_instance_count = 0
		mm.instance_count = n
		mm.visible_instance_count = 0
		var c: Vector3 = _body.global_position
		var ext := float(_body.radius) + 20.0
		(mmi as MultiMeshInstance3D).custom_aabb = AABB(c - Vector3.ONE * ext, Vector3.ONE * ext * 2.0)


func _process_tunnels() -> void:
	if _next_pt >= _order.size():
		return
	var stride := maxi(1, _order.size() / RADAR_TUNNEL_MAX)
	var budget := POINT_BUDGET
	while _next_pt < _order.size() and budget > 0:
		var i := _order[_next_pt]
		_next_pt += 1
		budget -= 1
		if not _accept(i):
			continue
		_accepted += 1
		var bright := 0.2 + 0.8 * exp(-_pa[i] / 90.0)
		var r := _pr[i] * TUBE_K
		_add_joint(_pp[i], r * 1.15, bright)
		var j := _parent(i)
		if j >= 0:
			_add_seg(_pp[j], _pp[i], r, bright, minf(_pd[i], _pd[j]))
		if _accepted % stride == 0 and _radar_pts.size() < RADAR_TUNNEL_MAX:
			_radar_pts.append(_pp[i])


## A logged point counts when it lies deeper than SCAN_TUNNEL_DEPTH below the original surface and
## the ground there is still open (density < 0 is solid: refilled since). Cached.
func _accept(i: int) -> bool:
	if _pok[i] >= 0:
		return _pok[i] == 1
	var p := _pp[i]
	var ok := false
	if _body != null and is_instance_valid(_body):
		var depth := float(_body.radius) + float(_body.surface_height_at(p)) - p.distance_to(_body.global_position)
		ok = depth >= Balance.SCAN_TUNNEL_DEPTH
		if ok and _body.has_method("density_at"):
			ok = float(_body.density_at(p)) > -0.3
	_pok[i] = 1 if ok else 0
	return ok


## The nearest earlier (dug before) accepted point within the link distance, or -1.
func _parent(i: int) -> int:
	var p := _pp[i]
	var link := minf(maxf(LINK_MIN, LINK_K * _pr[i]), CELL)
	var key := Vector3i((p / CELL).floor())
	var best := -1
	var bd := link
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var arr = _grid.get(key + Vector3i(dx, dy, dz))
				if arr == null:
					continue
				for j in arr:
					if j >= i:
						continue
					var dd := p.distance_to(_pp[j])
					if dd < bd and _accept(j):
						bd = dd
						best = j
	return best


func _add_joint(p: Vector3, r: float, bright: float) -> void:
	var mm := _joints.multimesh
	if _joint_n >= mm.instance_count:
		return
	mm.set_instance_transform(_joint_n, Transform3D(Basis.from_scale(Vector3.ONE * r), p))
	mm.set_instance_custom_data(_joint_n, Color(bright, 0.0, 0.0, 0.0))
	_joint_n += 1
	mm.visible_instance_count = _joint_n


func _add_seg(a: Vector3, b: Vector3, r: float, bright: float, reveal_d: float) -> void:
	var mm := _segs.multimesh
	if _seg_n >= mm.instance_count:
		return
	var d := b - a
	var ln := d.length()
	if ln < 0.05:
		return
	var bb := VM.basis_y(d)
	mm.set_instance_transform(_seg_n, Transform3D(Basis(bb.x * r, bb.y * ln, bb.z * r), (a + b) * 0.5))
	mm.set_instance_custom_data(_seg_n, Color(bright, 0.0, 0.0, 0.0))
	_seg_n += 1
	mm.visible_instance_count = _seg_n
	_seg_d.append(reveal_d)
	_seg_len.append(ln)


func _update_tunnels(delta: float) -> void:
	var r := _wave_r()
	var f := _fade()
	_segs.visible = _seg_n > 0 and f > 0.0
	_joints.visible = _joint_n > 0 and f > 0.0
	for m: ShaderMaterial in [_tube_mat, _joint_mat]:
		m.set_shader_parameter("origin", _origin)
		m.set_shader_parameter("wave_r", r)
		m.set_shader_parameter("fade", f)
	# Revealed strand length (for the counts), a few times a second.
	_tun_m_t -= delta
	if _tun_m_t <= 0.0:
		_tun_m_t = 0.1
		var total := 0.0
		for i in _seg_n:
			if _seg_d[i] <= r:
				total += _seg_len[i]
		_tun_m = total
		if total > 0.0 and not _tun_seen:
			_tun_seen = true
			_blip(0.55)


# --- Wrist radar --------------------------------------------------------------------------------

## [bots, torpedoes, tunnel metres] revealed so far.
func _count_arr() -> Array:
	var nb := 0
	var nt := 0
	if _t >= 0.0:
		for b: Dictionary in _bots:
			var n = b["node"]
			if b["shown"] and is_instance_valid(n) and not (n.has_method("is_dead") and n.is_dead()):
				nb += 1
		for t: Dictionary in _torps:
			if t["shown"] and is_instance_valid(t["node"]):
				nt += 1
	return [nb, nt, roundi(_tun_m) if _t >= 0.0 else 0] + _vn_counts()   # + veins, caches (end of file)


func _push_wrist(delta: float) -> void:
	var on := wrist_up or _t >= 0.0
	_push_t -= delta
	if _push_t > 0.0 and on == _push_on:
		return
	_push_t = 0.05 if on else 0.25
	_push_on = on
	var w := _wrist_ui()
	if w == null or not w.has_method("set_scan"):
		return
	var d := {"on": on, "charge": 1.0 - _cool / maxf(Balance.SCAN_COOLDOWN, 0.01), "left": ceili(_cool)}
	if on:
		var r := _wave_r()
		d["pulse"] = -1.0
		if _t >= 0.0 and r < _range:
			# The wave front on the radar: straight-line distance -> angle around the planet.
			var rb := float(_body.radius) if _body != null and is_instance_valid(_body) else 60.0
			d["pulse"] = sqrt(2.0 * asin(clampf(r / (2.0 * rb), 0.0, 1.0)) / PI)
		d["reveal"] = clampf(1.0 - _t / Balance.SCAN_TIME, 0.0, 1.0) if _t >= 0.0 else 0.0
		d["reveal_s"] = ceili(Balance.SCAN_TIME - _t) if _t >= 0.0 else 0
		d["blips"] = _radar_blips()
		d["counts"] = _count_arr()
		d["scanned"] = _t >= 0.0
	w.set_scan(d)


## Radar blips [Vector2 (x right, y ahead; 1 = the far side of the planet), kind 0 bot / 1 torpedo /
## 2 tunnel, underground 0/1, alpha]. Azimuthal around the player: angle around the planet's centre
## -> distance from the radar centre (square root: the near field gets more room).
func _radar_blips() -> Array:
	var out: Array = []
	if _t < 0.0 or player == null:
		return out
	var pp: Vector3 = player.global_position
	var body := Game.dominant_body(pp)
	if body == null:
		return out
	var c := body.global_position
	var up := (pp - c).normalized()
	var fwd: Vector3 = -(player.head.global_transform.basis.z) if player.head != null else -player.global_transform.basis.z
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-6:
		fwd = -player.global_transform.basis.z
	fwd = fwd.normalized()
	var right := fwd.cross(up)
	var r := _wave_r()
	var f := _fade()
	for p in _radar_pts:
		if p.distance_to(_origin) <= r:
			out.append([_radar_xy(p, c, up, fwd, right), 2, 1, f])
	for b: Dictionary in _bots:
		var n = b["node"]
		if b["shown"] and is_instance_valid(n) and float(b["k"]) > 0.05:
			out.append([_radar_xy((n as Node3D).global_position, c, up, fwd, right), 0, 1 if b["under"] else 0,
					float(b["k"]) * f])
	for t: Dictionary in _torps:
		var n = t["node"]
		if t["shown"] and is_instance_valid(n):
			out.append([_radar_xy((n as Node3D).global_position, c, up, fwd, right), 1, 1, float(t["k"]) * f])
	out.append_array(_vn_blips(c, up, fwd, right, f))   # kinds 3 vein / 4 cache (end of file)
	return out


static func _radar_xy(p: Vector3, c: Vector3, up: Vector3, fwd: Vector3, right: Vector3) -> Vector2:
	var dir := p - c
	if dir.length_squared() < 1e-6:
		return Vector2.ZERO
	dir = dir.normalized()
	var cosv := clampf(dir.dot(up), -1.0, 1.0)
	var tan := dir - up * cosv
	if tan.length_squared() < 1e-8:
		return Vector2.ZERO
	tan = tan.normalized()
	return Vector2(tan.dot(right), tan.dot(fwd)) * sqrt(acos(cosv) / PI)


func _wrist_ui() -> Node:
	if _wrist != null and is_instance_valid(_wrist):
		return _wrist
	_wrist = null
	if player == null or not is_instance_valid(player) or not is_inside_tree():
		return null
	for n in get_tree().get_nodes_in_group("wrist_display"):
		if (player as Node).is_ancestor_of(n):
			_wrist = n
			break
	return _wrist


# --- Helpers ------------------------------------------------------------------------------------

func _clear() -> void:
	_restore_overlays()
	for b: Dictionary in _bots:
		for k in ["dia", "lbl"]:
			if b[k] != null and is_instance_valid(b[k]):
				(b[k] as Node).queue_free()
	_bots.clear()
	for t: Dictionary in _torps:
		for k in ["dia", "ring", "beam", "lbl"]:
			if t[k] != null and is_instance_valid(t[k]):
				(t[k] as Node).queue_free()
	_torps.clear()
	_reset_tunnels()
	_vn_clear()                        # veins, meteor cores, buried caches (end of file)
	if _wave != null:
		_wave.visible = false
	if _flash != null:
		_flash.visible = false
	_t = -1.0


func _up(p: Vector3) -> Vector3:
	var b := Game.dominant_body(p)
	var u := p - (b.global_position if b != null else Game.planet_center())
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


## How far below the original (unedited) surface a point lies (negative: above it).
func _depth_below(p: Vector3) -> float:
	var b := Game.dominant_body(p)
	if b == null or not b.has_method("surface_height_at"):
		return 0.0
	return float(b.radius) + float(b.surface_height_at(p)) - p.distance_to(b.global_position)


func _blip(pitch: float) -> void:
	if _blip_t > 0.0:
		return
	_blip_t = 0.06
	_play("blip", -13.0, pitch * randf_range(0.97, 1.03))


func _build_shared() -> void:
	_xray_shader = Shader.new()
	_xray_shader.code = XRAY_SHADER
	_mark_shader = Shader.new()
	_mark_shader.code = MARK_SHADER
	_beam_shader = Shader.new()
	_beam_shader.code = BEAM_SHADER
	var sm := SphereMesh.new()       # 4 segments x 2 rings: an octahedron "diamond"
	sm.radius = 0.32
	sm.height = 0.8
	sm.radial_segments = 4
	sm.rings = 2
	_gem_mesh = sm
	var tm := TorusMesh.new()
	tm.inner_radius = 0.42
	tm.outer_radius = 0.5
	tm.rings = 32
	tm.ring_segments = 4
	_ring_mesh = tm
	var cm := CylinderMesh.new()     # unit beam, scaled per torpedo (y = length, x/z = radius)
	cm.top_radius = 1.0
	cm.bottom_radius = 1.0
	cm.height = 1.0
	cm.radial_segments = 6
	cm.rings = 1
	cm.cap_top = false
	cm.cap_bottom = false
	_beam_mesh = cm
	var ts := Shader.new()
	ts.code = TUBE_SHADER
	_tube_mat = ShaderMaterial.new()
	_tube_mat.shader = ts
	_tube_mat.set_shader_parameter("color", TUNNEL)
	_tube_mat.set_shader_parameter("joint", 0.0)
	_tube_mat.render_priority = 6
	_joint_mat = ShaderMaterial.new()
	_joint_mat.shader = ts
	_joint_mat.set_shader_parameter("color", TUNNEL)
	_joint_mat.set_shader_parameter("joint", 1.0)
	_joint_mat.render_priority = 7


func _build_wave() -> void:
	_wave_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = WAVE_SHADER
	_wave_mat.shader = sh
	_wave_mat.set_shader_parameter("tint", TINT)
	_wave_mat.set_shader_parameter("band", WAVE_BAND)
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 48
	sm.rings = 24
	_wave = MeshInstance3D.new()
	_wave.mesh = sm
	_wave.material_override = _wave_mat
	_wave.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wave.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_wave.visible = false
	add_child(_wave)
	_flash = OmniLight3D.new()
	_flash.light_color = TINT
	_flash.omni_range = 12.0
	_flash.light_energy = 0.0
	_flash.shadow_enabled = false
	_flash.visible = false
	add_child(_flash)


func _tube_mesh() -> Mesh:
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.0
	cm.height = 1.0
	cm.radial_segments = 8
	cm.rings = 1
	cm.cap_top = false
	cm.cap_bottom = false
	return cm


func _joint_mesh() -> Mesh:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 10
	sm.rings = 5
	return sm


func _make_mm(mesh: Mesh, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.visible = false
	add_child(mi)
	return mi


func _mark_mat(c: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _mark_shader
	m.set_shader_parameter("tint", c)
	m.set_shader_parameter("alpha", 0.0)
	m.render_priority = 10
	return m


func _mesh_child(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.visible = false
	add_child(mi)
	return mi


func _label(c: Color) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0011
	l.font = UI.font(700)
	l.font_size = 22
	l.outline_size = 7
	l.outline_modulate = Color(0, 0, 0, 0.7)
	l.modulate = c
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.render_priority = 12
	l.outline_render_priority = 11
	l.visible = false
	add_child(l)
	return l


# --- Sounds -------------------------------------------------------------------------------------
#   sweep  the pulse: sub "whomp", a rising shimmer chirp, a sonar ping with echoes, an air swell
#   blip   a reveal ping (pitched per kind), deny  two low beeps (still charging)
#   ready  two rising tones (charged again), alarm  a torpedo was found

func _build_snd() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	var out := {"sweep": _wav(_sweep_s(rng), 0.75), "blip": _wav(_blip_s(), 0.55), "deny": _wav(_deny_s(), 0.6),
			"ready": _wav(_ready_s(), 0.4), "alarm": _wav(_alarm_s(), 0.55)}
	_mutex.lock()
	_snd = out
	_mutex.unlock()


func _play(name: String, vol: float, pitch: float) -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_mutex.lock()
	var st = _snd.get(name)
	_mutex.unlock()
	if st == null or _audio.is_empty():
		return
	var p: AudioStreamPlayer = _audio[_ai]
	_ai = (_ai + 1) % _audio.size()
	p.stream = st
	p.volume_db = vol
	p.pitch_scale = pitch
	p.play()


static func _wav(s: PackedFloat32Array, peak: float) -> AudioStreamWAV:
	var m := 0.0001
	for v in s:
		m = maxf(m, absf(v))
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i] / m * peak, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


static func _sweep_s(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(1.9 * RATE))
	var ph_sub := 0.0
	var ph_ch := 0.0
	var lp := 0.0
	var lp2 := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var fs := 38.0 + 34.0 * exp(-t * 9.0)
		ph_sub += TAU * fs / RATE
		var sub := sin(ph_sub) * exp(-t * 5.0) * minf(t * 300.0, 1.0)
		var u := clampf(t / 0.55, 0.0, 1.0)
		var fc := lerpf(260.0, 1900.0, u * u)
		ph_ch += TAU * fc * (1.0 + 0.012 * sin(t * 90.0)) / RATE
		var chirp := (sin(ph_ch) + 0.35 * sin(ph_ch * 2.003)) * sin(minf(t / 0.62, 1.0) * PI) * 0.5
		var ping := 0.0
		for e in 4:
			var te := t - 0.05 - e * 0.38
			if te > 0.0:
				ping += sin(TAU * 1320.0 * te) * exp(-te * 7.0) * minf(te * 600.0, 1.0) * pow(0.42, e)
		var nz := rng.randf() * 2.0 - 1.0
		lp += 0.18 * (nz - lp)
		lp2 += 0.02 * (lp - lp2)
		var air := (lp - lp2) * sin(minf(t / 1.3, 1.0) * PI) * 0.6
		s[i] = sub * 0.9 + chirp * 0.42 + ping * 0.55 + air * 0.35
	return s


static func _blip_s() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(0.1 * RATE))
	for i in s.size():
		var t := float(i) / RATE
		s[i] = (sin(TAU * 1850.0 * t) + 0.4 * sin(TAU * 2780.0 * t)) * exp(-t * 42.0) * minf(t * 500.0, 1.0)
	return s


static func _deny_s() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(0.22 * RATE))
	for i in s.size():
		var t := float(i) / RATE
		var on := 0.0
		for st in [0.0, 0.12]:
			var te: float = t - st
			if te > 0.0 and te < 0.075:
				on += minf(te * 400.0, 1.0) * minf((0.075 - te) * 400.0, 1.0)
		s[i] = tanh(sin(TAU * 330.0 * t) * 2.5) * on
	return s


static func _ready_s() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(0.24 * RATE))
	for i in s.size():
		var t := float(i) / RATE
		var f := 990.0 if t < 0.1 else 1480.0
		var te := t if t < 0.1 else t - 0.1
		s[i] = sin(TAU * f * t) * exp(-te * 22.0) * minf(te * 500.0, 1.0)
	return s


static func _alarm_s() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(0.5 * RATE))
	for i in s.size():
		var t := float(i) / RATE
		var k := int(t / 0.125)
		var te := t - k * 0.125
		var f := 880.0 if k % 2 == 0 else 660.0
		var env := minf(te * 300.0, 1.0) * minf(maxf(0.1 - te, 0.0) * 300.0, 1.0)
		s[i] = tanh(sin(TAU * f * t) * 1.8) * env
	return s


# =================================================================================================
# Veins and buried caches (2026-10-06; scripts/planet/veins.gd, the "buried_cache" group)
# =================================================================================================
# Hooks above (one line each): pulse -> _vn_gather; _process -> _vn_update; _clear -> _vn_clear;
# _announce -> _vn_announce_parts; _count_arr -> + _vn_counts (veins, caches); _radar_blips ->
# _vn_blips (kind 3 vein, 4 cache). Not team-filtered: veins, cores and caches belong to whoever digs
# them. Shown when the wave front reaches them, for the rest of the reveal (fading out at its end).
#   veins / meteor cores  a crystal x-ray capsule (the vein's own shape) drawn through the ground:
#                         cyan (ordinary), gold (rich, the contested zones), ember (meteor core);
#                         dug-out veins are left out; labels for the nearest LABEL_MAX
#   buried caches         nodes in group "buried_cache" with scan_point() (+ optional scan_label()):
#                         a green diamond over the point, tracked live, "Gömülü sandık · derinlik X m"

const VnVeins := preload("res://scripts/planet/veins.gd")
const VN_COLS := [Color(0.3, 0.88, 1.0), Color(1.0, 0.74, 0.25), Color(1.0, 0.5, 0.16)]
const VN_CACHE := Color(0.45, 1.0, 0.55)

## Crystal x-ray blob: a bright rim and a faint body, drifting facet bands and rare sparkles, a white
## pop as the wave front passes; drawn through everything.
const VN_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_test_disabled, depth_draw_never, shadows_disabled;

uniform vec4 color : source_color = vec4(0.3, 0.88, 1.0, 1.0);
uniform float alpha = 0.0;
uniform float pop = 0.0;

void fragment() {
	float rim = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.6);
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float facets = 0.75 + 0.25 * sin(dot(wp, vec3(5.1, 3.7, 4.3)) + TIME * 2.0);
	float spark = step(0.975, fract(sin(dot(floor(wp * 6.0), vec3(12.9898, 78.233, 37.719))) * 43758.5453 + TIME * 0.4));
	ALBEDO = mix(color.rgb, vec3(1.0, 0.96, 0.88), clamp(pop * 0.5 + spark * 0.6, 0.0, 1.0));
	ALPHA = clamp(((0.12 + rim * 0.75) * facets + pop * 0.35 + spark * 0.4) * alpha, 0.0, 1.0);
}
"""

## {kind ("vein" / "core" / "cache"), node (cache: the node; else null), pos (world), d, shown, k,
##  pop, mi, mat, lbl, label (bool), col, txt, depth, a, b, r}
var _vn: Array = []
var _vn_shader: Shader


## Read-only: what the current reveal marks right now (see the header). Empty when nothing is shown.
func revealed_targets() -> Array:
	var out: Array = []
	if _t < 0.0:
		return out
	var f := _fade()
	for b: Dictionary in _bots:
		var n = b["node"]
		if b["shown"] and is_instance_valid(n) and not (n.has_method("is_dead") and n.is_dead()) and float(b["k"]) * f > 0.05:
			out.append({"kind": "bot", "node": n, "pos": (n as Node3D).global_position, "alpha": float(b["k"]) * f})
	for t: Dictionary in _torps:
		var n = t["node"]
		if t["shown"] and is_instance_valid(n) and float(t["k"]) * f > 0.05:
			out.append({"kind": "torpedo", "node": n, "pos": (n as Node3D).global_position, "alpha": float(t["k"]) * f})
	for e: Dictionary in _vn:
		if not e["shown"] or float(e["k"]) * f <= 0.05:
			continue
		var nd = e["node"]
		if e["kind"] == "cache" and not is_instance_valid(nd):
			continue
		out.append({"kind": e["kind"], "node": nd if e["kind"] == "cache" else null, "pos": e["pos"], "alpha": float(e["k"]) * f})
	return out


func _vn_gather() -> void:
	_vn_clear()
	if _body == null or not is_instance_valid(_body):
		return
	if _vn_shader == null:
		_vn_shader = Shader.new()
		_vn_shader.code = VN_SHADER
	for v: Dictionary in VnVeins.veins(_body):
		var i := int(v["i"])
		if VnVeins.remaining(_body, i) < Balance.VEIN_SPENT:
			continue
		var p: Vector3 = v["c"]
		var d := p.distance_to(_origin)
		if d > _range:
			continue
		var rich := int(v["kind"]) == VnVeins.KIND_RICH
		var txt := ("Çok zengin damar ×%d" if rich else "Zengin damar ×%d") % roundi(float(v["mult"]))
		_vn.append(_vn_item("vein", null, p, d, VN_COLS[int(v["kind"])], txt, float(v["top"]), v["a"], v["b"], float(v["r"])))
	for dp: Dictionary in VnVeins.deposits(_body):
		var p: Vector3 = dp["pos"]
		var d := p.distance_to(_origin)
		if d > _range or float(dp["rem"]) < Balance.VEIN_SPENT:
			continue
		_vn.append(_vn_item("core", null, p, d, VN_COLS[2], "Göktaşı çekirdeği ~%d m³" % roundi(float(dp["amount"]) * float(dp["rem"])),
				-1.0, p, p, float(dp["r"])))
	for n in get_tree().get_nodes_in_group("buried_cache"):
		if not (n is Node3D) or not n.has_method("scan_point"):
			continue
		var sp = n.scan_point()
		if not (sp is Vector3):
			continue
		var d := (sp as Vector3).distance_to(_origin)
		if d > _range or Game.dominant_body(sp) != _body:
			continue
		var lb := "Gömülü sandık"
		if n.has_method("scan_label"):
			var s = n.scan_label()
			if s is String and s != "":
				lb = s
		_vn.append(_vn_item("cache", n, sp, d, VN_CACHE, lb, -1.0, sp, sp, 0.0))
	# Labels for the nearest LABEL_MAX veins / cores (caches always).
	var order: Array = range(_vn.size())
	order.sort_custom(func(x, y): return float(_vn[x]["d"]) < float(_vn[y]["d"]))
	var nl := 0
	var nl_max := int(VEIN_LABELS_BY_LEVEL[clampi(HudLevel.shown_level(), 0, 2)])   # (HUD level)
	for i in order:
		var e: Dictionary = _vn[i]
		if e["kind"] == "cache" or nl < nl_max:
			e["label"] = true
			if e["kind"] != "cache":
				nl += 1


func _vn_item(kind: String, node, p: Vector3, d: float, col: Color, txt: String, depth: float, a: Vector3, b: Vector3,
		r: float) -> Dictionary:
	return {"kind": kind, "node": node, "pos": p, "d": d, "shown": false, "k": 0.0, "pop": 0.0, "mi": null, "mat": null,
			"lbl": null, "label": false, "col": col, "txt": txt, "depth": depth, "a": a, "b": b, "r": r}


func _vn_show(e: Dictionary) -> void:
	e["shown"] = true
	e["pop"] = 1.0
	var col: Color = e["col"]
	if e["kind"] == "cache":
		var dm := _mark_mat(col)
		e["mat"] = dm
		e["mi"] = _mesh_child(_gem_mesh, dm)
	else:
		var a: Vector3 = e["a"]
		var b: Vector3 = e["b"]
		var r: float = maxf(float(e["r"]), 0.3)
		var cm := CapsuleMesh.new()
		cm.radius = r
		cm.height = a.distance_to(b) + 2.0 * r
		cm.radial_segments = 12
		cm.rings = 4
		var m := ShaderMaterial.new()
		m.shader = _vn_shader
		m.set_shader_parameter("color", col)
		m.set_shader_parameter("alpha", 0.0)
		m.render_priority = 8
		e["mat"] = m
		var mi := _mesh_child(cm, m)
		var axis := b - a
		var bas := VM.basis_y(axis) if axis.length_squared() > 1e-4 else VM.basis_y(_up(e["pos"]))
		mi.global_transform = Transform3D(bas, (a + b) * 0.5)
		e["mi"] = mi
	if e["label"]:
		e["lbl"] = _label(col.lightened(0.3))


func _vn_update(delta: float) -> void:
	var r := _wave_r()
	var f := _fade()
	var cp: Vector3 = player.camera.global_position if player.camera != null else player.global_position
	var first := false
	for e: Dictionary in _vn:
		var nd = e["node"]
		if e["kind"] == "cache":
			if not is_instance_valid(nd):
				if e["mi"] != null:
					(e["mi"] as Node3D).visible = false
				if e["lbl"] != null:
					(e["lbl"] as Node3D).visible = false
				continue
			var sp = nd.scan_point()
			if sp is Vector3:
				e["pos"] = sp
		if not e["shown"]:
			if float(e["d"]) > r:
				continue
			_vn_show(e)
			first = true
		e["k"] = move_toward(float(e["k"]), 1.0, delta * 4.0)
		e["pop"] = maxf(float(e["pop"]) - delta * 2.5, 0.0)
		var a := float(e["k"]) * f
		var p: Vector3 = e["pos"]
		var up := _up(p)
		var mi: MeshInstance3D = e["mi"]
		var mat: ShaderMaterial = e["mat"]
		mi.visible = a > 0.0
		if e["kind"] == "cache":
			var dist := cp.distance_to(p)
			var s := clampf(dist * 0.02, 0.14, 1.2) * (1.0 + 0.6 * float(e["pop"]))
			mi.global_transform = Transform3D(VM.basis_y(up).rotated(up, _t * 1.6) * Basis.from_scale(Vector3(s, s * 1.2, s)),
					p + up * (0.4 + 0.5 * s))
			mat.set_shader_parameter("alpha", a * 0.9)
		else:
			mat.set_shader_parameter("alpha", a)
			mat.set_shader_parameter("pop", float(e["pop"]))
		var lbl: Label3D = e["lbl"]
		if lbl != null:
			lbl.visible = a > 0.0
			lbl.global_position = p + up * (float(e["r"]) + 0.9)
			lbl.modulate.a = a
			lbl.outline_modulate.a = 0.7 * a
			var depth := float(e["depth"]) if float(e["depth"]) >= 0.0 else _depth_below(p)
			var txt := "%s\nderinlik %d m · %d m" % [e["txt"], maxi(roundi(depth), 0), roundi(player.global_position.distance_to(p))]
			if lbl.text != txt:
				lbl.text = txt
	if first:
		_blip(1.35)


func _vn_clear() -> void:
	for e: Dictionary in _vn:
		for k in ["mi", "lbl"]:
			if e[k] != null and is_instance_valid(e[k]):
				(e[k] as Node).queue_free()
	_vn.clear()


## [veins + cores, caches] revealed so far.
func _vn_counts() -> Array:
	var nv := 0
	var nc := 0
	if _t >= 0.0:
		for e: Dictionary in _vn:
			if not e["shown"]:
				continue
			if e["kind"] == "cache":
				nc += 1
			else:
				nv += 1
	return [nv, nc]


func _vn_announce_parts() -> PackedStringArray:
	var out := PackedStringArray()
	var c := _vn_counts()
	if int(c[0]) > 0:
		out.append("%d zengin damar" % int(c[0]))
	if int(c[1]) > 0:
		out.append("%d gömülü sandık" % int(c[1]))
	return out


## Radar blips of the veins / cores (kind 3) and caches (kind 4) revealed so far.
func _vn_blips(c: Vector3, up: Vector3, fwd: Vector3, right: Vector3, f: float) -> Array:
	var out: Array = []
	for e: Dictionary in _vn:
		if e["shown"] and float(e["k"]) > 0.05:
			out.append([_radar_xy(e["pos"], c, up, fwd, right), 4 if e["kind"] == "cache" else 3, 1, float(e["k"]) * f])
	return out
