extends Node3D
## Enemy fire readability ("Düşman ateşinin okunması"): the bots' rifle shots drawn so you see who
## shoots at you, from where, and where the rounds go. The bots' bullets are not physical rounds (the
## hit is decided by ai_rival.gd _shoot_update's hit-chance model, at once); this draws them:
##   EnemyFire.shot(muzzle, end, team, hit)   one bot shot (end: the hit point, or its miss point)
##   - Muzzle flash, every shot: a small additive star billboard and a halo quad
##     (DebrisMesh.halo_material) that never gets smaller than ~EF_FLASH_PX × distance, so a shooter
##     stays a few bright pixels at 80 m+. The real light stays the bot's own OmniLight3D under the
##     team's light budget (AI_LIGHT_MAX, rival_team.gd set_light).
##   - Tracer, on 2 of 3 shots (EF_TRACER_EVERY): a pooled streak that FLIES from the muzzle at
##     EF_TRACER_SPEED m/s (not an instant line), the player's tracer look (rifle_fx.gd: a hot
##     cylinder streak, widened with the camera distance so it stays visible at 100 m+, a bright
##     billboard head) but thicker and RED / orange-red for the enemy side (EF_ENEMY_COLOR), warm for
##     our side (ally bots). Suppressive misses already pass close (ai_rival.gd), so they streak by.
##   - A miss runs on EF_MISS_EXTEND m past its aim point; ONE physics ray (terrain / ship / vehicle)
##     finds where it lands when the line passes within EF_RAY_NEAR m of the camera; when the round
##     arrives there it kicks up the usual dirt (rifle_fx.gd impact_terrain through a shared RifleFx:
##     dust, clods, a hole, a thud) and adds erosion (scripts/war/erosion.gd, the bot rifle's weight
##     EROSION_W_BOT): sustained enemy fire wears the player's cover down. On the multiplayer host a
##     miss passing within EF_RAY_NEAR of the other player (no physics collision there) marches the
##     density instead (planet.raycast_density, fast) for the erosion only.
##   - Impacts on hulls (ship / vehicle layers): sparks and a ping (impact_metal).
## Everything is pooled and capped (EF_* in balance.gd); far shots nobody sees (beyond EF_FX_RANGE
## from the camera) draw nothing. One node per scene (inst()), created on the first shot.
## Multiplayer: purely local. The host draws its bots' shots here; a client draws them from the
## synced shots (Net.bots.on_bot_shot -> net_bot.gd) once that calls EnemyFire.shot(muzzle, end,
## team, false, 0.3) (see the report: scripts/net is not edited here). A remote player's shots
## (remote_avatar.gd shot_fx) can come through here too with their team, for the enemy tint.

const Balance := preload("res://scripts/war/balance.gd")
const RifleFx := preload("res://scripts/items/rifle_fx.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const Erosion := preload("res://scripts/war/erosion.gd")
const ShotPings := preload("res://scripts/war/shot_pings.gd")   # radar pings (minimap.gd)

const MASK := 1 | 2 | 4                  # terrain | ship | vehicle (characters are not hit: the model decides)
const N_TRACERS := 40
const N_FLASH := 24
const N_ROUNDS := 64
## Readability (2026-10-06): the other side's muzzle flash is a warmer red-orange than ours and its
## min-pixel halo is a little larger, so an enemy shooter at 80 m+ reads as a red spark, an ally's as
## a gold one (the tracers already split EF_ENEMY_COLOR / EF_FRIEND_COLOR).
const ENEMY_FLASH := Color(1.0, 0.36, 0.12)
const ENEMY_FLASH_PX_K := 1.35

static var _tex_star: Texture2D

var shots := 0                           # (tests)
var _fx                                  # RifleFx: impact effects (dust, clods, holes, sparks, sounds)
var _tracers: Array = []                 # {mi, mat, tip, tip_mat, busy}
var _flashes: Array = []                 # {star, star_mat, halo, halo_mat, t, dur}
var _flash_i := 0
var _rounds: Array = []                  # {a, dir, len, d, vis, impact, team, cal}
var _n := 0
var _cam_pos := Vector3.ZERO
var _tex_dot: Texture2D


## The scene's EnemyFire (created on first use; null outside a game scene).
static func inst() -> Node3D:
	if Game.has_meta("enemy_fire"):
		var e = Game.get_meta("enemy_fire")
		if is_instance_valid(e) and (e as Node).is_inside_tree():
			return e
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var n: Node3D = load("res://scripts/war/enemy_fire.gd").new()
	n.name = "EnemyFire"
	tree.current_scene.add_child(n)
	Game.set_meta("enemy_fire", n)
	return n


## One shot by `team` from `muzzle` toward `end`. hit: it struck its target at `end` (the streak
## stops there); a miss runs on `extend` m past `end` (default EF_MISS_EXTEND; pass a small value when
## `end` is already a ray's hit point) until the ground stops it. cal: the impact calibre (1 rifle).
## flash = false: no muzzle star / halo (a suppressed shot: the multiplayer replay of a remote player's).
## loud = false: a suppressed gun; it does not reveal the shooter on the radar (scripts/war/shot_pings.gd,
## scripts/ui/minimap.gd: every shot is recorded here, the radar shows the other side's loud ones).
static func shot(muzzle: Vector3, end: Vector3, team: String, hit := false, extend := -1.0, cal := 1.0, flash := true,
		loud := true) -> void:
	ShotPings.add(muzzle, team, loud)
	var e = inst()
	if e != null:
		e._shot(muzzle, end, team, hit, extend, cal, flash)


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_fx = RifleFx.new()
	_fx.name = "ImpactFx"
	add_child(_fx)
	_tex_dot = _make_dot()
	if _tex_star == null:
		_tex_star = _make_star()
	# Tracer: fat bright head, thin tail (+Y = the flight direction), and a billboard head glow.
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.021
	cyl.bottom_radius = 0.008
	cyl.height = 1.0
	cyl.radial_segments = 6
	cyl.rings = 1
	var tip_mesh := QuadMesh.new()
	tip_mesh.size = Vector2(0.22, 0.22)
	for i in N_TRACERS:
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		var m := _add_mat(Balance.EF_ENEMY_COLOR, 14.0)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		var tip := MeshInstance3D.new()
		tip.mesh = tip_mesh
		var tm := _add_mat(Balance.EF_ENEMY_COLOR.lightened(0.4), 18.0)
		tm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		tm.albedo_texture = _tex_dot
		tip.material_override = tm
		tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tip.visible = false
		add_child(tip)
		_tracers.append({"mi": mi, "mat": m, "tip": tip, "tip_mat": tm, "busy": false})
	# Muzzle flash: a star billboard (close) + a min-pixel halo (far).
	var star_mesh := QuadMesh.new()
	star_mesh.size = Vector2.ONE * Balance.EF_FLASH_SIZE
	for i in N_FLASH:
		var star := MeshInstance3D.new()
		star.mesh = star_mesh
		var sm := _add_mat(Balance.EF_FLASH_COLOR, 9.0)
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		sm.albedo_texture = _tex_star
		star.material_override = sm
		star.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		star.visible = false
		add_child(star)
		var halo := MeshInstance3D.new()
		halo.mesh = DebrisMesh.quad_mesh()
		var hm := DebrisMesh.halo_material(Balance.EF_FLASH_COLOR, Balance.EF_FLASH_SIZE * 1.3, Balance.EF_FLASH_PX)
		halo.material_override = hm
		halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		halo.custom_aabb = AABB(Vector3.ONE * -10.0, Vector3.ONE * 20.0)
		halo.visible = false
		add_child(halo)
		_flashes.append({"star": star, "star_mat": sm, "halo": halo, "halo_mat": hm, "t": 1.0, "dur": 0.1})


func _shot(muzzle: Vector3, end: Vector3, team: String, hit: bool, extend: float, cal: float, flash := true) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_cam_pos = cam.global_position
	var seg := end - muzzle
	var len := seg.length()
	if len < 0.05:
		return
	var dir := seg / len
	var total := len + (0.0 if hit else (extend if extend >= 0.0 else Balance.EF_MISS_EXTEND))
	var dm := muzzle.distance_to(_cam_pos)
	var u := clampf((_cam_pos - muzzle).dot(dir), 0.0, total)
	var pass_d := (muzzle + dir * u).distance_to(_cam_pos)
	var seen := dm < Balance.EF_FX_RANGE or pass_d < Balance.EF_FX_RANGE
	shots += 1
	if seen and flash and dm < Balance.EF_FX_RANGE:
		_flash(muzzle, team)
	var impact := {}
	if not hit:
		impact = _landing(muzzle, dir, total, pass_d, dm)
		if not impact.is_empty():
			total = float(impact["dist"])
	if not seen and impact.is_empty():
		return
	_n += 1
	var vis = null
	if seen and (Balance.EF_TRACER_EVERY <= 1 or _n % Balance.EF_TRACER_EVERY != 0):
		vis = _take_tracer(team)
	if _rounds.size() >= N_ROUNDS:
		_finish(_rounds.pop_front())
	_rounds.append({"a": muzzle, "dir": dir, "len": total, "d": 0.0, "vis": vis, "impact": impact, "team": team,
			"cal": cal})


## Where a miss lands: one physics ray near the camera; on the multiplayer host a density march near
## the other player (erosion only). {} = it flies on out of sight.
func _landing(muzzle: Vector3, dir: Vector3, total: float, pass_d: float, dm: float) -> Dictionary:
	var a := muzzle + dir * minf(1.5, total * 0.5)        # (not its own cover rim at the muzzle)
	var b := muzzle + dir * total
	if pass_d < Balance.EF_RAY_NEAR or dm < Balance.EF_RAY_NEAR:
		var q := PhysicsRayQueryParameters3D.create(a, b, MASK)
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty():
			return {}
		var col: Object = hit["collider"]
		var terrain: bool = col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & 1) != 0
		return {"pos": hit["position"], "n": hit["normal"], "terrain": terrain, "far": false,
				"dist": muzzle.distance_to(hit["position"])}
	if not (Net.active and not Net.is_client()):
		return {}
	for pl in get_tree().get_nodes_in_group("net_player"):
		if not (pl is Node3D) or not is_instance_valid(pl):
			continue
		var pp := (pl as Node3D).global_position
		var ur := clampf((pp - muzzle).dot(dir), 0.0, total)
		if (muzzle + dir * ur).distance_to(pp) > Balance.EF_RAY_NEAR:
			continue
		var body: Node3D = Game.dominant_body(pp)
		if body == null or not body.has_method("raycast_density"):
			return {}
		var from := muzzle + dir * maxf(ur - 12.0, minf(1.5, total * 0.5))
		var h: Dictionary = body.raycast_density(from, b, 0.75, true)
		if h.is_empty():
			return {}
		return {"pos": h["position"], "n": h["normal"], "terrain": true, "far": true,
				"dist": muzzle.distance_to(h["position"])}
	return {}


func _take_tracer(team: String):
	for tr in _tracers:
		if not tr["busy"]:
			tr["busy"] = true
			var enemy := team != _my_team()
			var c: Color = Balance.EF_ENEMY_COLOR if enemy else Balance.EF_FRIEND_COLOR
			var m: StandardMaterial3D = tr["mat"]
			m.albedo_color = c
			m.emission = c
			var tc := c.lightened(0.45)
			var tm: StandardMaterial3D = tr["tip_mat"]
			tm.albedo_color = tc
			tm.emission = tc
			return tr
	return null


func _flash(p: Vector3, team := "") -> void:
	var f: Dictionary = _flashes[_flash_i]
	_flash_i = (_flash_i + 1) % _flashes.size()
	f["t"] = 0.0
	f["dur"] = Balance.EF_FLASH_TIME * randf_range(0.85, 1.2)
	var enemy := team != "" and team != _my_team()
	var fc: Color = ENEMY_FLASH if enemy else Balance.EF_FLASH_COLOR
	var star: MeshInstance3D = f["star"]
	star.global_transform = Transform3D(Basis().scaled(Vector3.ONE * randf_range(0.8, 1.2)), p)
	star.visible = true
	var halo: MeshInstance3D = f["halo"]
	halo.global_position = p
	halo.visible = true
	var hm := f["halo_mat"] as ShaderMaterial
	hm.set_shader_parameter("dim", 1.0)
	hm.set_shader_parameter("tint", fc)
	hm.set_shader_parameter("px", Balance.EF_FLASH_PX * (ENEMY_FLASH_PX_K if enemy else 1.0))
	var sm := f["star_mat"] as StandardMaterial3D
	sm.albedo_color = Color(fc, 1.0)
	sm.emission = fc


func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		_cam_pos = cam.global_position
	for f in _flashes:
		var t: float = f["t"]
		var dur: float = f["dur"]
		if t >= dur:
			continue
		t += delta
		f["t"] = t
		if t >= dur:
			(f["star"] as Node3D).visible = false
			(f["halo"] as Node3D).visible = false
			continue
		var k := 1.0 - t / dur
		(f["star_mat"] as StandardMaterial3D).albedo_color.a = k
		(f["halo_mat"] as ShaderMaterial).set_shader_parameter("dim", k * k)
	if _rounds.is_empty():
		return
	var keep: Array = []
	for r in _rounds:
		var d: float = float(r["d"]) + Balance.EF_TRACER_SPEED * delta
		r["d"] = d
		if d >= float(r["len"]):
			_finish(r)
			continue
		_draw(r, d, delta)
		keep.append(r)
	_rounds = keep


## Places the streak of round r whose head has flown d m.
func _draw(r: Dictionary, d: float, delta: float) -> void:
	var vis = r["vis"]
	if vis == null:
		return
	var dir: Vector3 = r["dir"]
	var head: Vector3 = (r["a"] as Vector3) + dir * d
	var l := minf(clampf(Balance.EF_TRACER_SPEED * delta * 1.3, 1.5, Balance.EF_TRACER_LEN), d)
	var mi: MeshInstance3D = vis["mi"]
	var tip: MeshInstance3D = vis["tip"]
	if l < 0.05:
		mi.visible = false
		tip.visible = false
		return
	var bas := RifleFx._basis_y(dir)
	var dc := head.distance_to(_cam_pos)
	var w := clampf(dc * 0.08, 1.0, 10.0) * Balance.EF_TRACER_WIDTH
	mi.global_transform = Transform3D(Basis(bas.x * w, bas.y * l, bas.z * w), head - dir * l * 0.5)
	mi.visible = true
	tip.global_transform = Transform3D(Basis().scaled(Vector3.ONE * clampf(dc * 0.05, 1.0, 6.0)), head)
	tip.visible = dc > 1.5                   # (a round arriving at the camera: no glow blob over the view)


## The round arrived (or was dropped): free its streak, then its impact.
func _finish(r: Dictionary) -> void:
	var vis = r["vis"]
	if vis != null:
		vis["busy"] = false
		(vis["mi"] as Node3D).visible = false
		(vis["tip"] as Node3D).visible = false
	var imp: Dictionary = r["impact"]
	if imp.is_empty():
		return
	var p: Vector3 = imp["pos"]
	var n: Vector3 = imp["n"]
	var dir: Vector3 = r["dir"]
	var cal: float = r["cal"]
	var team: String = r["team"]
	var near := not bool(imp["far"]) and p.distance_to(_cam_pos) < Balance.EF_IMPACT_FX_RANGE
	# Erosion weight: EROSION_W_BOT for a rifle round (cal 1), scaled like the guns' for other calibres.
	var w := Balance.EROSION_W_BOT * Erosion.erosion_weight(cal) / Balance.EROSION_W_RIFLE
	if bool(imp["terrain"]):
		if near:
			_fx.impact_terrain(p, n, dir, Rifle.ground_color(p, n), false, false, cal, w, team)
		else:
			Erosion.add_impact(p, n, w, team)
	elif near:
		_fx.impact_metal(p, n, dir, false, cal)


func _my_team() -> String:
	var pl = Game.player
	return Game.team_of(pl) if pl != null and is_instance_valid(pl) else "home"


func _add_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m


func _make_dot() -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 64
	t.height = 64
	return t


## Procedural muzzle star: a hot core, a soft glow and four long / four short spikes (white, alpha).
static func _make_star() -> Texture2D:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(n) * 2.0 - Vector2.ONE
			var r := u.length()
			var ang := atan2(u.y, u.x)
			var core := clampf(1.0 - r / 0.22, 0.0, 1.0)
			var glow := pow(clampf(1.0 - r, 0.0, 1.0), 2.2) * 0.55
			var long := pow(absf(cos(ang * 2.0)), 40.0) * clampf(1.0 - r, 0.0, 1.0)
			var short := pow(absf(cos(ang * 2.0 + PI * 0.5)), 60.0) * clampf(1.0 - r * 1.7, 0.0, 1.0) * 0.6
			var a := clampf(maxf(maxf(core, glow), maxf(long, short)), 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
