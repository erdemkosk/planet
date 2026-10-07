extends Node3D
## Zengin damarlar, the look and the feel (scripts/planet/veins.gd has the data). One node, child of
## the war (scripts/war/war.gd), on every machine; purely local (no game state, nothing to sync):
##   - the terrain shader's vein uniforms per planet (moon_terrain.gdshader vein_a / vein_b / vein_col:
##     the veins and the meteor cores, glow = Veins.glow(remaining)), refreshed every UNIFORM_DT s
##   - every brush on a planet (planet.brush_applied, also the replayed ones in multiplayer):
##     Veins.mark_edit, and where it cuts into a vein crystal clusters sprout from the dug wall
##     (VEIN_CRYSTALS_PER_VEIN per vein, VEIN_CRYSTALS_MAX in all, the oldest recycled); a cluster
##     whose wall is dug away shatters with a chime
##   - the local player's drill in a vein / meteor core: gold-cyan sparkles and crystal chips at the
##     bit with a soft light, a rising chime ladder (a three-note "jackpot" on the way in), the toast
##     "Zengin damar! ×8" (HUD + a wrist pop + a "×8" rising at the bit), "Damar · +NN m³" when the
##     run ends, "Damar tükendi" when it is dug out
## The drill credits the bonus itself (terrain_tool.gd × Veins.mult_at); here only the show.

const Veins := preload("res://scripts/planet/veins.gd")
const Balance := preload("res://scripts/war/balance.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # toasts: "vein" (found, 1), "vein_end" (run total, 0)
const Bodies := preload("res://scripts/planet/bodies.gd")

const GROUP := "vein_fx"
## Crystal colours per kind (Veins.KIND_*), linear: ordinary crystal cyan, rich gold, meteor ember-gold.
const COLS := [Color(0.22, 0.8, 1.0), Color(1.0, 0.7, 0.2), Color(1.0, 0.48, 0.14)]
const UNIFORM_DT := 0.4
const RANGE := 10.0                  # the drill's reach (terrain_tool.gd RANGE)
const CHIME_GAP := 0.17              # s between the ladder's notes while digging a vein
const LADDER := [1.0, 1.125, 1.25, 1.5, 1.6667, 2.0, 2.25, 2.5, 3.0, 3.3333, 4.0]
const SESSION_END := 1.6             # s out of a vein before its run ends ("+NN m³")
const RATE := 44100

var _uni_t := 0.0
var _uni_last := {}                  # planet id -> last packed key (skip unchanged uploads)
var _hooked := {}                    # planet id -> true
var _started := false
# Crystal clusters: {node, body, vein (key), base (body-local), n (body-local normal), t}
var _clusters: Array = []
var _per_vein := {}                  # key -> clusters spawned
var _spawn_ms := {}                  # key -> last spawn ms
var _check_i := 0
var _check_t := 0.0
var _cl_mesh: Mesh
var _vein_mats := {}                 # key -> StandardMaterial3D (glow fades with the vein)
# The local player's drill.
var _sess := ""                      # current vein key ("" = none)
var _sess_kind := 0
var _sess_mult := 1.0
var _sess_gain := 0.0
var _sess_out := 0.0                 # s since the drill last bit into it
var _sess_body: Node3D
var _sess_i := -1
var _toast_ms := {}                  # key -> ms of its last toast
var _chime_t := 0.0
var _step := 0
var _queue: Array = []               # [delay s, pitch, vol]
var _mat_last := -1.0
var _sparks: GPUParticles3D
var _spark_pm: ParticleProcessMaterial
var _chips: GPUParticles3D
var _chip_pm: ParticleProcessMaterial
var _chip_mat: StandardMaterial3D
var _light: OmniLight3D
var _fx_on := 0.0
# Sounds (synthesized on a worker thread).
var _audio: Array = []
var _ai := 0
var _task := -1
var _mutex := Mutex.new()
var _snd := {}


func _ready() -> void:
	add_to_group(GROUP)
	name = "VeinFx"
	top_level = true
	global_transform = Transform3D.IDENTITY
	_build_fx()
	_cl_mesh = cluster_mesh()
	for i in 5:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_audio.append(p)
	_task = WorkerThreadPool.add_task(_build_snd, false, "vein_audio")
	Game.material_changed.connect(_on_material)


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	Veins.clear_deposits()


func _process(delta: float) -> void:
	if not _started:
		# The first frame, after main._ready (the combat POIs are built by then): a fresh vein set.
		_started = true
		Veins.reset()
	_hook_planets()
	_uni_t -= delta
	if _uni_t <= 0.0:
		_uni_t = UNIFORM_DT
		for b in Bodies.all():
			if is_instance_valid(b):
				_push_uniforms(b)
	_check_t -= delta
	if _check_t <= 0.0:
		_check_t = 0.25
		_check_clusters()
	_play_queue(delta)


func _physics_process(delta: float) -> void:
	_drill_feel(delta)


# --- Shader uniforms ------------------------------------------------------------------------------

func _push_uniforms(body: Node3D) -> void:
	var mat = body.get("terrain_material")
	if not (mat is ShaderMaterial):
		return
	var list: Array = []
	var c := body.global_position
	for v: Dictionary in Veins.veins(body):
		var rem := Veins.remaining(body, int(v["i"]))
		list.append([(v["a"] as Vector3) - c, (v["b"] as Vector3) - c, float(v["r"]), int(v["kind"]), Veins.glow(rem)])
	for dp: Dictionary in Veins.deposits(body):
		var p: Vector3 = (dp["pos"] as Vector3) - c
		list.append([p, p, float(dp["r"]), Veins.KIND_METEOR, Veins.glow(float(dp["rem"]))])
	var mx := Balance.VEIN_SHADER_MAX
	if list.size() > mx:
		var cam := get_viewport().get_camera_3d()
		var cp: Vector3 = (cam.global_position if cam != null else c) - c
		list.sort_custom(func(x, y): return cp.distance_squared_to(x[0]) < cp.distance_squared_to(y[0]))
		list.resize(mx)
	var a := PackedFloat32Array()
	var b := PackedFloat32Array()
	var col := PackedFloat32Array()
	a.resize(mx * 4)
	b.resize(mx * 4)
	col.resize(mx * 4)
	for i in list.size():
		var e: Array = list[i]
		var pa: Vector3 = e[0]
		var pb: Vector3 = e[1]
		var cc: Color = COLS[int(e[3])]
		a[i * 4] = pa.x
		a[i * 4 + 1] = pa.y
		a[i * 4 + 2] = pa.z
		a[i * 4 + 3] = float(e[2])
		b[i * 4] = pb.x
		b[i * 4 + 1] = pb.y
		b[i * 4 + 2] = pb.z
		col[i * 4] = cc.r
		col[i * 4 + 1] = cc.g
		col[i * 4 + 2] = cc.b
		col[i * 4 + 3] = snappedf(float(e[4]), 0.02)
	var key := hash([a, b, col])
	var bid := body.get_instance_id()
	if _uni_last.get(bid, -1) == key:
		return
	_uni_last[bid] = key
	var sm := mat as ShaderMaterial
	sm.set_shader_parameter("vein_a", a)
	sm.set_shader_parameter("vein_b", b)
	sm.set_shader_parameter("vein_col", col)
	sm.set_shader_parameter("vein_count", list.size())
	# The crystal clusters of each vein glow with it.
	for k in _vein_mats:
		var parts := str(k).split(":")
		if parts.size() != 3 or int(parts[0]) != bid:
			continue
		var g := Veins.glow(Veins.deposit_remaining(int(parts[2])) if parts[1] == "m" else Veins.remaining(body, int(parts[2])))
		(_vein_mats[k] as StandardMaterial3D).emission_energy_multiplier = 0.25 + 1.6 * g


# --- Brushes: exposure, crystal clusters ----------------------------------------------------------

func _hook_planets() -> void:
	for b in Bodies.all():
		if not is_instance_valid(b):
			continue
		var id: int = b.get_instance_id()
		if _hooked.has(id) or not b.has_signal("brush_applied"):
			continue
		_hooked[id] = true
		b.brush_applied.connect(_on_brush.bind(b))


func _on_brush(center: Vector3, radius: float, body: Node3D) -> void:
	Veins.mark_edit(body, center, radius)
	var inf := Veins.info_at(body, center)
	if inf.is_empty():
		# The brush centre is outside: does its sphere reach a vein's surface?
		inf = _touching(body, center, radius)
		if inf.is_empty():
			return
	var key := _key(body, int(inf["kind"]), int(inf["i"]))
	var now := Time.get_ticks_msec()
	if int(_per_vein.get(key, 0)) >= Balance.VEIN_CRYSTALS_PER_VEIN or now - int(_spawn_ms.get(key, -100000)) < 350:
		return
	_spawn_ms[key] = now
	_spawn_cluster(body, center, inf, key)


## A vein whose capsule this brush sphere cuts ({} none): {"kind", "i", "a", "b", "r"} body-local.
func _touching(body: Node3D, center: Vector3, radius: float) -> Dictionary:
	var c := body.global_position
	for v: Dictionary in Veins.veins(body):
		var a: Vector3 = v["a"]
		var b: Vector3 = v["b"]
		if Veins._seg_dist(center, a, b) - float(v["r"]) < radius:
			return {"kind": int(v["kind"]), "i": int(v["i"]), "full": float(v["mult"])}
	for dp: Dictionary in Veins.deposits(body):
		if center.distance_to(dp["pos"]) - float(dp["r"]) < radius:
			return {"kind": Veins.KIND_METEOR, "i": int(dp["id"]), "full": float(dp["mult"])}
	return {}


func _key(body: Node3D, kind: int, i: int) -> String:
	return "%d:%s:%d" % [body.get_instance_id(), "m" if kind == Veins.KIND_METEOR else "v", i]


## A cluster on the dug wall where the brush met the vein: from the brush centre (air now) toward the
## vein's surface, the first solid ground still inside the vein.
func _spawn_cluster(body: Node3D, center: Vector3, inf: Dictionary, key: String) -> void:
	var c := body.global_position
	var q := center
	var r := 1.0
	if int(inf["kind"]) == Veins.KIND_METEOR:
		for dp: Dictionary in Veins.deposits(body):
			if int(dp["id"]) == int(inf["i"]):
				q = dp["pos"]
				r = float(dp["r"])
	else:
		for v: Dictionary in Veins.veins(body):
			if int(v["i"]) == int(inf["i"]):
				var a: Vector3 = v["a"]
				var ab: Vector3 = (v["b"] as Vector3) - a
				var t := clampf((center - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
				q = a + ab * t
				r = float(v["r"])
	var out := center - q
	var up := (center - c).normalized()
	if out.length_squared() < 0.01:
		out = up
	out = out.normalized()
	var jit := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.55
	var target := q + (out + jit).normalized() * r * 0.85
	var from := center if body.density_at(center) > 0.0 else center + out * 1.5
	var h: Dictionary = body.raycast_density(from, target + (target - from).normalized() * 0.8, 0.2, false)
	if h.is_empty():
		return
	var w: Vector3 = h["position"]
	var inside := Veins.info_at(body, w)
	if inside.is_empty() or float(inside["mult"]) < 1.5:
		return
	var n: Vector3 = h["normal"]
	var mi := MeshInstance3D.new()
	mi.mesh = _cl_mesh
	mi.material_override = _vein_mat(key, int(inf["kind"]))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var s := randf_range(0.55, 1.0) * (1.25 if int(inf["kind"]) != Veins.KIND_NORMAL else 1.0)
	var bas := _basis_y(n.lerp(up, 0.25).normalized()).rotated(n, randf() * TAU)
	body.add_child(mi)
	mi.global_transform = Transform3D(bas, w - n * 0.12)
	_clusters.append({"node": mi, "body": body, "key": key, "base": w - n * 0.25 - c, "t": Time.get_ticks_msec()})
	_per_vein[key] = int(_per_vein.get(key, 0)) + 1
	# Grows in.
	mi.scale = Vector3.ONE * 0.01
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3.ONE * s, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	while _clusters.size() > Balance.VEIN_CRYSTALS_MAX:
		_shatter(0, false)


func _vein_mat(key: String, kind: int) -> StandardMaterial3D:
	if _vein_mats.has(key):
		return _vein_mats[key]
	var cc: Color = COLS[kind]
	var m := StandardMaterial3D.new()
	m.albedo_color = cc.lerp(Color.WHITE, 0.25)
	m.metallic = 0.15
	m.roughness = 0.12
	m.emission_enabled = true
	m.emission = cc
	m.emission_energy_multiplier = 1.6
	m.rim_enabled = true
	m.rim = 0.6
	m.rim_tint = 0.3
	_vein_mats[key] = m
	return m


## Clusters whose wall is gone shatter (a few per tick, round-robin).
func _check_clusters() -> void:
	var n := _clusters.size()
	for k in mini(n, 12):
		if _clusters.is_empty():
			return
		_check_i = _check_i % _clusters.size()
		var cl: Dictionary = _clusters[_check_i]
		var body = cl["body"]
		if not is_instance_valid(body) or not is_instance_valid(cl["node"]):
			_clusters.remove_at(_check_i)
			continue
		var base: Vector3 = (body as Node3D).global_position + (cl["base"] as Vector3)
		if float(body.density_at(base)) > 0.25:
			_shatter(_check_i, true)
			continue
		_check_i += 1


func _shatter(i: int, show: bool) -> void:
	var cl: Dictionary = _clusters[i]
	_clusters.remove_at(i)
	var mi = cl["node"]
	if not is_instance_valid(mi):
		return
	if show:
		var p: Vector3 = (mi as Node3D).global_position
		_burst(p, (p - (cl["body"] as Node3D).global_position).normalized(), (mi as MeshInstance3D).material_override)
		var cam := get_viewport().get_camera_3d()
		if cam != null and cam.global_position.distance_to(p) < 25.0:
			_play("shatter", -14.0, randf_range(0.92, 1.12))
	(mi as Node).queue_free()


## A short sparkle burst where a cluster shattered.
func _burst(p: Vector3, up: Vector3, mat) -> void:
	var g := GPUParticles3D.new()
	g.one_shot = true
	g.amount = 14
	g.lifetime = 0.6
	g.explosiveness = 1.0
	g.local_coords = false
	var pm := (_spark_pm.duplicate() as ParticleProcessMaterial)
	pm.gravity = -up * 5.0
	if mat is StandardMaterial3D:
		pm.color = (mat as StandardMaterial3D).emission
	g.process_material = pm
	g.draw_pass_1 = _sparks.draw_pass_1
	add_child(g)
	g.global_transform = Transform3D(_basis_y(up), p)
	g.emitting = true
	get_tree().create_timer(1.2).timeout.connect(g.queue_free)


# --- The local player's drill -----------------------------------------------------------------------

func _drill_feel(delta: float) -> void:
	var pl = Game.player
	var tool = pl.get("tool") if pl != null and is_instance_valid(pl) else null
	var on := false
	var hit := Vector3.ZERO
	var nrm := Vector3.UP
	var body: Node3D = null
	var inf := {}
	if tool != null and is_instance_valid(tool) and bool(tool.get("using")) and int(tool.get("work_mode")) == 0 \
			and pl.camera != null:
		var from: Vector3 = pl.aim_origin()
		var dir: Vector3 = -(pl.camera as Camera3D).global_transform.basis.z
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * RANGE, Game.LAYER_TERRAIN)
		var h := get_world_3d().direct_space_state.intersect_ray(q)
		if not h.is_empty():
			hit = h["position"]
			nrm = h["normal"]
			body = Game.dominant_body(hit)
			if body != null:
				inf = Veins.info_at(body, hit)
				on = not inf.is_empty() and float(inf["mult"]) > 1.5
	if on:
		var kind := int(inf["kind"])
		var key := _key(body, kind, int(inf["i"]))
		if key != _sess:
			_end_session(false)
			_begin_session(key, body, kind, int(inf["i"]), float(inf["full"]), hit)
		_sess_out = 0.0
		_chime_t -= delta
		if _chime_t <= 0.0:
			_chime_t = CHIME_GAP * randf_range(0.9, 1.15)
			_step = mini(_step + 1, LADDER.size() - 1)
			_play("chime", -15.0 + minf(float(_step), 6.0) * 0.4, LADDER[_step] * (0.5 if kind == Veins.KIND_METEOR else 1.0))
		var col: Color = COLS[kind]
		_fx_on = 1.0
		_sparks.global_transform = Transform3D(_basis_y(nrm), hit + nrm * 0.1)
		_spark_pm.gravity = -(hit - body.global_position).normalized() * 6.0
		_spark_pm.color = col.lerp(Color.WHITE, 0.2)
		_sparks.emitting = true
		_chips.global_transform = Transform3D(_basis_y(nrm), hit + nrm * 0.05)
		_chip_pm.gravity = _spark_pm.gravity * 1.4
		_chip_mat.emission = col
		_chip_mat.albedo_color = col.lerp(Color.WHITE, 0.3)
		_chips.emitting = true
		_light.global_position = hit + nrm * 0.5
		_light.light_color = col
		# The run is over once the vein is dug out.
		if _sess_i >= 0 and _sess_body != null and is_instance_valid(_sess_body):
			var rem := Veins.deposit_remaining(_sess_i) if _sess_kind == Veins.KIND_METEOR else Veins.remaining(_sess_body, _sess_i)
			if rem < Balance.VEIN_SPENT:
				_end_session(true)
	else:
		_sparks.emitting = false
		_chips.emitting = false
		if _sess != "":
			_sess_out += delta
			if _sess_out > SESSION_END:
				_end_session(false)
	_fx_on = move_toward(_fx_on, 0.0, delta * 3.0)
	_light.visible = _fx_on > 0.02
	_light.light_energy = (0.9 + randf() * 0.35) * _fx_on


func _begin_session(key: String, body: Node3D, kind: int, i: int, mult: float, hit: Vector3) -> void:
	_sess = key
	_sess_body = body
	_sess_kind = kind
	_sess_i = i
	_sess_mult = mult
	_sess_gain = 0.0
	_sess_out = 0.0
	_step = 0
	_chime_t = 0.25
	var now := Time.get_ticks_msec()
	if now - int(_toast_ms.get(key, -1000000)) < int(Balance.VEIN_TOAST_GAP * 1000.0):
		return
	_toast_ms[key] = now
	# The jackpot: a quick rising three-note arpeggio, the toasts.
	var base := 0.5 if kind == Veins.KIND_METEOR else 1.0
	_queue.append([0.0, base * 1.0, -11.0])
	_queue.append([0.07, base * 1.25, -11.0])
	_queue.append([0.14, base * 1.5, -10.0])
	_queue.append([0.21, base * 2.0, -9.0])
	var m := roundi(mult)
	var txt := "Zengin damar! ×%d" % m
	if kind == Veins.KIND_RICH:
		txt = "Çok zengin damar! ×%d" % m
	elif kind == Veins.KIND_METEOR:
		txt = "Göktaşı çekirdeği! ×%d" % m
	if Game.hud:
		HudLevel.alert(txt, 1, "vein", 2.2)
	var w := _wrist()
	if w != null and w.has_method("drill_pop"):
		w.drill_pop("×%d" % m, COLS[kind])
	_float_label(hit, "×%d" % m, COLS[kind])


func _end_session(spent: bool) -> void:
	if _sess == "":
		return
	if spent:
		_queue.append([0.0, 2.0, -10.0])
		_queue.append([0.09, 2.5, -10.0])
		_queue.append([0.18, 3.0, -9.0])
		_queue.append([0.3, 4.0, -8.0])
	var what := "Göktaşı çekirdeği" if _sess_kind == Veins.KIND_METEOR else "Damar"
	if Game.hud and _sess_gain >= 1.0:
		var line := "%s tükendi · +%d m³" if spent else "%s · +%d m³"
		HudLevel.alert(line % [what, roundi(_sess_gain)], 0, "vein_end", 2.4)
	elif Game.hud and spent:
		HudLevel.alert("%s tükendi" % what, 0, "vein_end", 1.8)
	_sess = ""
	_sess_i = -1
	_sess_body = null


func _on_material(amount: float) -> void:
	if _mat_last >= 0.0 and amount > _mat_last and _sess != "":
		_sess_gain += amount - _mat_last
	_mat_last = amount


func _wrist() -> Node:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or not is_inside_tree():
		return null
	for n in get_tree().get_nodes_in_group("wrist_display"):
		if (pl as Node).is_ancestor_of(n):
			return n
	return null


## "×8" rising from the bit and fading.
func _float_label(p: Vector3, txt: String, col: Color) -> void:
	var l := Label3D.new()
	l.text = txt
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0016
	l.font = UI.font_num(700)
	l.font_size = 30
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.6)
	l.modulate = col.lerp(Color.WHITE, 0.35)
	l.render_priority = 12
	l.outline_render_priority = 11
	add_child(l)
	var up := (p - Game.dominant_body(p).global_position).normalized() if Game.dominant_body(p) != null else Vector3.UP
	l.global_position = p + up * 0.4
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "global_position", p + up * 1.6, 1.1).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(l, "modulate:a", 0.0, 1.1).set_delay(0.35)
	tw.chain().tween_callback(l.queue_free)


# --- Building ---------------------------------------------------------------------------------------

func _build_fx() -> void:
	var soft := DigFx.soft_texture()
	_spark_pm = ParticleProcessMaterial.new()
	_spark_pm.direction = Vector3.UP
	_spark_pm.spread = 55.0
	_spark_pm.initial_velocity_min = 1.6
	_spark_pm.initial_velocity_max = 4.2
	_spark_pm.scale_min = 0.5
	_spark_pm.scale_max = 1.2
	_spark_pm.damping_min = 1.0
	_spark_pm.damping_max = 2.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	_spark_pm.color_ramp = rt
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.vertex_color_use_as_albedo = true
	sm.albedo_texture = soft
	sm.albedo_color = Color(1.6, 1.5, 1.3)
	var q := QuadMesh.new()
	q.size = Vector2(0.07, 0.07)
	q.material = sm
	_sparks = GPUParticles3D.new()
	_sparks.amount = 40
	_sparks.lifetime = 0.7
	_sparks.local_coords = false
	_sparks.process_material = _spark_pm
	_sparks.draw_pass_1 = q
	_sparks.emitting = false
	_sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sparks.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	add_child(_sparks)
	_chip_pm = ParticleProcessMaterial.new()
	_chip_pm.direction = Vector3.UP
	_chip_pm.spread = 40.0
	_chip_pm.initial_velocity_min = 1.2
	_chip_pm.initial_velocity_max = 3.0
	_chip_pm.angular_velocity_min = -540.0
	_chip_pm.angular_velocity_max = 540.0
	_chip_pm.scale_min = 0.6
	_chip_pm.scale_max = 1.3
	_chip_mat = StandardMaterial3D.new()
	_chip_mat.emission_enabled = true
	_chip_mat.emission_energy_multiplier = 2.0
	_chip_mat.roughness = 0.15
	_chip_mat.metallic = 0.2
	var pm := PrismMesh.new()
	pm.size = Vector3(0.045, 0.09, 0.045)
	pm.material = _chip_mat
	_chips = GPUParticles3D.new()
	_chips.amount = 18
	_chips.lifetime = 0.9
	_chips.local_coords = false
	_chips.process_material = _chip_pm
	_chips.draw_pass_1 = pm
	_chips.emitting = false
	_chips.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_chips.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	add_child(_chips)
	_light = OmniLight3D.new()
	_light.omni_range = 4.5
	_light.shadow_enabled = false
	_light.visible = false
	add_child(_light)


## A crystal cluster: five hexagonal prisms with pointed tips fanning out of a common root (+Y up).
static func cluster_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var specs := [[0.0, 0.0, 0.42, 0.075], [0.55, 0.0, 0.3, 0.06], [0.5, 2.1, 0.26, 0.055], [0.6, 4.2, 0.22, 0.05],
			[0.3, 1.0, 0.18, 0.04]]
	for sp in specs:
		var tilt: float = sp[0]
		var az: float = sp[1]
		var L: float = float(sp[2]) * rng.randf_range(0.85, 1.15)
		var r: float = sp[3]
		var axis := Vector3(sin(tilt) * cos(az), cos(tilt), sin(tilt) * sin(az)).normalized()
		var b := _basis_y(axis)
		var tip := axis * (L + r * 1.6)
		var ring_lo: Array = []
		var ring_hi: Array = []
		for k in 6:
			var a := TAU * float(k) / 6.0
			var o: Vector3 = (b.x * cos(a) + b.z * sin(a)) * r
			ring_lo.append(o - axis * 0.05)
			ring_hi.append(o + axis * L)
		for k in 6:
			var k2 := (k + 1) % 6
			var p0: Vector3 = ring_lo[k]
			var p1: Vector3 = ring_lo[k2]
			var p2: Vector3 = ring_hi[k2]
			var p3: Vector3 = ring_hi[k]
			var n := (p1 - p0).cross(p3 - p0).normalized()
			if n.dot(p0 - (-axis * 0.05)) < 0.0:
				n = -n
			for v in [p0, p2, p1, p0, p3, p2]:
				st.set_normal(n)
				st.add_vertex(v)
			var nt := (p2 - p3).cross(tip - p3).normalized()
			if nt.dot(p3 + p2 - axis * L * 2.0) < 0.0:
				nt = -nt
			for v in [p3, tip, p2]:
				st.set_normal(nt)
				st.add_vertex(v)
	st.index()
	return st.commit()


static func _basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var rf := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := rf.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


# --- Sounds -------------------------------------------------------------------------------------
#   chime    a glassy bell (the ladder plays it at rising pitches)
#   shatter  a crystal cluster breaking: bright clinks over a short noise burst

func _build_snd() -> void:
	var out := {"chime": _wav(_chime_s(), 0.6), "shatter": _wav(_shatter_s(), 0.55)}
	_mutex.lock()
	_snd = out
	_mutex.unlock()


func _play(nm: String, vol: float, pitch: float) -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_mutex.lock()
	var st = _snd.get(nm)
	_mutex.unlock()
	if st == null or _audio.is_empty():
		return
	var p: AudioStreamPlayer = _audio[_ai]
	_ai = (_ai + 1) % _audio.size()
	p.stream = st
	p.volume_db = vol
	p.pitch_scale = clampf(pitch, 0.1, 4.0)
	p.play()


func _play_queue(delta: float) -> void:
	for i in range(_queue.size() - 1, -1, -1):
		var e: Array = _queue[i]
		e[0] = float(e[0]) - delta
		if float(e[0]) <= 0.0:
			_play("chime", float(e[2]), float(e[1]))
			_queue.remove_at(i)


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


static func _chime_s() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(0.9 * RATE))
	var f := 880.0
	for i in s.size():
		var t := float(i) / RATE
		var att := minf(t * 900.0, 1.0)
		var v := sin(TAU * f * t) * exp(-t * 5.0)
		v += 0.45 * sin(TAU * f * 2.0 * t) * exp(-t * 8.0)
		v += 0.22 * sin(TAU * f * 3.01 * t) * exp(-t * 12.0)
		v += 0.12 * sin(TAU * f * 4.17 * t) * exp(-t * 18.0)
		v *= 1.0 + 0.04 * sin(TAU * 5.5 * t)
		s[i] = v * att
	return s


static func _shatter_s() -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var s := PackedFloat32Array()
	s.resize(int(0.5 * RATE))
	var clinks: Array = []
	for k in 7:
		clinks.append([rng.randf_range(0.0, 0.16), rng.randf_range(2400.0, 5200.0)])
	var hp := 0.0
	var prev := 0.0
	for i in s.size():
		var t := float(i) / RATE
		var nz := rng.randf() * 2.0 - 1.0
		hp = 0.7 * (hp + nz - prev)
		prev = nz
		var v := hp * exp(-t * 26.0) * 0.5
		for c in clinks:
			var tc: float = t - float(c[0])
			if tc > 0.0:
				v += sin(TAU * float(c[1]) * tc) * exp(-tc * 30.0) * 0.4
		s[i] = v
	return s
