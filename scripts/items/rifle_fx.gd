extends Node3D
## World-space effects for the rifle, all pooled: ballistic bullets (fast tracer streaks with drop
## that start at the muzzle and converge onto the true eye-line trajectory, widened with distance
## so they stay visible), tranquilizer darts, impact bursts per surface (a hot flash + ground-colored
## dust + clods on terrain, metal sparks, alien goo sprays on creatures: back toward the shooter and
## out along the shot, with a goo splat decal where the spray lands), bullet-hole decals, brass
## casings that bounce and tink, muzzle smoke, muzzle light, 3D sounds.
## Suit hits (astronauts, no gore): sparks, a jet of escaping air / vapour, suit fragments, a padded
## thwack and a hiss; head hits crack the visor (a pooled crack decal riding on the head bone).
## Bullets fired by someone else's gun (a remote player's weapon, rifle.player != Game.player) whizz
## / snap past the local listener (HitFeel.near_miss). Everything is pooled and capped.
## Weapon-feel pass (2026-10-05, the user: "silahlar güçsüz", "görsel zayıf", "ses zayıf"):
##   - bullets also sweep the helmets (GunFeel.helmet_sweep): the helmet pokes out of the hit
##     capsule, so a round over the top of a head no longer flies through (a head hit now);
##   - tracers: thicker, hotter streaks with a bright billboard tip, readable in daylight;
##   - impacts scale with the round's calibre `cal` (1 = rifle round, ~0.6 a pellet, ~2.2 the
##     sniper): terrain a ground-coloured dust puff + a fast dirt jet + flying clods + a spark flash
##     and a bigger hole; metal a shower of sparks; suits sparks, a strong vapour jet, fragments and
##     the recorded suit hit (bimp/suit: thump + crunch + plate tick); heavy rounds thud
##     (bimp/dirt_heavy). At most IMPACT_SND_FRAME impact sounds per physics frame (a blast of pellets
##     is one or two thuds, not nine).
## Cover-erosion pass (2026-10-06, "Mermilerin siperi aşındırması"): a terrain hit also leaves dust
## that hangs a moment ("haze"), a dark scuff of disturbed soil that GROWS with repeated hits on the
## same spot (pooled, N_SCUFFS), and feeds scripts/war/erosion.gd (Erosion.add_impact: the host bites
## the cover away under sustained fire; the impact `erode` weight comes from the calibre). Bullets of
## another side's gun (foreign, shooter's team != ours) draw the enemy-red tracer (Balance.EF_ENEMY_COLOR).

const SndLib := preload("res://scripts/audio/snd_lib.gd")
const GunFeel := preload("res://scripts/items/gun_feel.gd")
const Erosion := preload("res://scripts/war/erosion.gd")
const N_SCUFFS := 16             # growing scuff decals (repeated hits on one spot)
const SCUFF_JOIN := 0.45         # m: a hit this close to a live scuff grows it
const SCUFF_MAX := 1.3           # m: largest scuff
const SCUFF_LIFE := 40.0         # s
const MASK := 1 | 2 | 4 | 8 | 32     # terrain | ship | vehicle | characters (Game.LAYER_PLAYER) | 32
const IMPACT_SND_FRAME := 3
const N_TRACERS := 28
const N_DECALS := 48
const N_SHELLS := 18
const N_EMIT := 10               # pooled emitters per burst type
const N_CRACKS := 6              # visor crack decals per gun
const CRACK_LIFE := 16.0         # s (a bot respawns after Balance.AI_RESPAWN = 15 s)
const NEAR_MISS_R := 2.6         # m: foreign bullets passing the listener this close whizz

static var _tex_crack: Texture2D
const CONVERGE := 14.0           # meters over which the visible tracer joins the eye-line path
const SPLAT_GAP := 0.06          # min seconds between two goo splat decals (rapid fire)

static var _tex_splat: Texture2D
static var _tex_scuff: Texture2D

var rifle                        # owner (scripts/items/rifle.gd)
var bullets_in_flight := 0
var _bullets: Array = []
var _tracers: Array = []         # pooled {mi, mat, busy}
var _darts: Array = []           # pooled dart meshes {node, busy}
var _emit := {}                  # kind -> {"list": Array, "i": int}
var _decals: Array = []          # {node, t, life}
var _decal_i := 0
var _shells: Array = []          # {mi, vel, spin, t, bounces}
var _shell_i := 0
var _puffs: Array = []           # {mi, mat, t, dur, size}
var _lights: Array = []          # {light, t, dur, energy}
var _audio: Array = []
var _audio_i := 0
var _tex_dot: Texture2D
var _tex_hole: Texture2D
var _tex_hole_big: Texture2D
var _streams := {}               # name -> Array[AudioStream]
var _sphere_mesh: SphereMesh
var _brass_mat: Material
var _shell_meshes := {}           # "rifle" / "pistol" / "hull" -> CylinderMesh (true size)
var _hull_mat: StandardMaterial3D
var _cam_pos := Vector3.ZERO
var _splat_t := 0
var _cracks: Array = []          # {node: Decal, t, life}
var _crack_i := 0
var _snd_frame := -1             # impact sounds this physics frame (IMPACT_SND_FRAME)
var _snd_count := 0
var _scuffs: Array = []          # {node: Decal, t, life, hits} (created on the first terrain hit)
var _scuff_i := 0


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_tex_dot = _make_dot()
	_tex_hole = _make_decal_tex(0)
	_tex_hole_big = _make_decal_tex(1)
	_sphere_mesh = SphereMesh.new()
	_sphere_mesh.radius = 1.0
	_sphere_mesh.height = 2.0
	_sphere_mesh.radial_segments = 12
	_sphere_mesh.rings = 6
	if _tex_splat == null:
		_tex_splat = _make_splat_tex()
	# Tracer: a hot streak (thin at the tail, fat at the head) plus a bright billboard tip.
	var tracer_mesh := CylinderMesh.new()
	tracer_mesh.top_radius = 0.008
	tracer_mesh.bottom_radius = 0.0145
	tracer_mesh.height = 1.0
	tracer_mesh.radial_segments = 6
	tracer_mesh.rings = 1
	var tip_mesh := QuadMesh.new()
	tip_mesh.size = Vector2(0.16, 0.16)
	for i in N_TRACERS:
		var mi := MeshInstance3D.new()
		mi.mesh = tracer_mesh
		var m := _add_mat(Color(1.0, 0.85, 0.55), 14.0)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		var tip := MeshInstance3D.new()
		tip.mesh = tip_mesh
		var tm := _add_mat(Color(1.0, 0.9, 0.7), 18.0)
		tm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		tm.albedo_texture = _tex_dot
		tip.material_override = tm
		tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tip.visible = false
		add_child(tip)
		_tracers.append({"mi": mi, "mat": m, "tip": tip, "tip_mat": tm, "busy": false})
	for i in 6:
		_darts.append({"node": _make_dart(), "busy": false})
	_emit["dust"] = _make_pool("dust")
	_emit["debris"] = _make_pool("debris")
	_emit["sparks"] = _make_pool("sparks")
	_emit["goo"] = _make_pool("goo")
	_emit["smoke"] = _make_pool("smoke")
	_emit["msmoke"] = _make_pool("msmoke")
	_emit["zap"] = _make_pool("zap")
	_emit["vapor"] = _make_pool("vapor")
	_emit["frag"] = _make_pool("frag")
	_emit["spray"] = _make_pool("spray")
	_emit["haze"] = _make_pool("haze")
	for i in N_DECALS:
		var d := Decal.new()
		d.visible = false
		d.upper_fade = 0.3
		d.lower_fade = 0.3
		d.normal_fade = 0.4
		add_child(d)
		_decals.append({"node": d, "t": 0.0, "life": 0.0})
	var brass := StandardMaterial3D.new()
	brass.albedo_color = Color(0.8, 0.6, 0.33)
	brass.metallic = 0.85
	brass.roughness = 0.45
	brass.emission_enabled = true                  # a faint glint so the brass reads in shade too
	brass.emission = Color(0.3, 0.21, 0.08)
	brass.emission_energy_multiplier = 0.1
	# Case meshes at true size (scale 1): a bottle-necked rifle case (5.56: 45 mm, 9.6 mm at the base),
	# a straight pistol case (9 mm: 19 mm × 9.9 mm) and a shotgun hull (12 ga: 68 mm × 20 mm). The old
	# single stubby 34 × 11.6 mm mesh scaled ×1.2 read as a gold bar next to the eye.
	_shell_meshes = {"rifle": _case_mesh(0.0034, 0.0048, 0.045), "pistol": _case_mesh(0.0048, 0.005, 0.019),
			"hull": _case_mesh(0.0099, 0.0103, 0.068)}
	var shell_mesh: Mesh = _shell_meshes["rifle"]
	for i in N_SHELLS:
		var mi := MeshInstance3D.new()
		mi.mesh = shell_mesh
		mi.material_override = brass
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_shells.append({"mi": mi, "vel": Vector3.ZERO, "spin": Vector3.ZERO, "t": 99.0, "bounces": 0, "scale": 1.0})
	for i in 10:
		var mi := MeshInstance3D.new()
		mi.mesh = _sphere_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		var m := _add_mat(Color.WHITE, 2.0)
		mi.material_override = m
		add_child(mi)
		_puffs.append({"mi": mi, "mat": m, "t": 99.0, "dur": 0.1, "size": 0.3})
	for i in 4:
		var l := OmniLight3D.new()
		l.shadow_enabled = false
		l.visible = false
		l.omni_attenuation = 0.85                  # a flatter falloff: the pulse lights the tunnel walls around you
		add_child(l)
		_lights.append({"light": l, "t": 99.0, "dur": 0.1, "energy": 1.0})
	for i in 18:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 10.0
		p.max_distance = 140.0
		p.max_db = 6.0
		add_child(p)
		_audio.append(p)
	# Recorded bullet impacts (assets/audio/sonniss/bimp: Mechanical Wave rock / dirt, Gamemaster
	# metal and concrete, Gorification flesh); energy hits keep the Kenney force-field zaps.
	_streams["dirt"] = SndLib.set_of("bimp/dirt")
	_streams["rock"] = SndLib.set_of("bimp/rock")
	_streams["metal"] = SndLib.set_of("bimp/metal")
	_streams["flesh"] = SndLib.set_of("bimp/flesh")
	_streams["hiss"] = SndLib.set_of("foley/hiss")
	# Weapon-feel pass: suit hits (Gamemaster body thump + a dry Gorification crunch + a metal plate
	# tick) and heavy-round ground thuds (Gamemaster concrete + Mechanical Wave rock into dirt + a low
	# thump); empty sets (not imported yet) fall back to flesh / dirt.
	_streams["suit"] = SndLib.set_of("bimp/suit")
	_streams["dirt_heavy"] = SndLib.set_of("bimp/dirt_heavy")
	_streams["zap"] = _ogg_set("scifi/forceField_00%d", 5)


# =================================================================================================
# Public effects
# =================================================================================================

## Launches a bullet (or dart) from the eye along vel; the visible streak starts at `muzzle`.
## width: tracer thickness multiplier (the sniper's heavy round draws a brighter, fatter streak).
func bullet(eye: Vector3, vel: Vector3, muzzle: Vector3, ammo: int, col: Color, dart: bool, pierce: int, width := 1.0) -> void:
	var foreign: bool = rifle != null and rifle.get("player") != null and rifle.player != Game.player
	var b := {"pos": eye, "vel": vel, "off": muzzle - eye, "dist": 0.0, "life": 3.0, "ammo": ammo, "dart": dart,
			"pierce": pierce, "pierced": 0, "ignore": null, "vis": null, "prev": muzzle, "w": width,
			"foreign": foreign, "whizzed": false, "from": eye, "conv": _aim_distance(eye, vel)}
	if dart:
		for d in _darts:
			if not d["busy"]:
				d["busy"] = true
				b["vis"] = d
				break
	else:
		for tr in _tracers:
			if not tr["busy"]:
				tr["busy"] = true
				b["vis"] = tr
				var m: StandardMaterial3D = tr["mat"]
				var hot := Color(1.0, 0.86, 0.58).lerp(col, 0.35)
				if foreign and Game.team_of(rifle.player) != Game.team_of(Game.player):
					hot = preload("res://scripts/war/balance.gd").EF_ENEMY_COLOR     # (the other side's gun: enemy red)
				m.albedo_color = hot
				m.emission = hot
				var tm: StandardMaterial3D = tr["tip_mat"]
				var tip_c := hot.lightened(0.45)
				tm.albedo_color = tip_c
				tm.emission = tip_c
				break
	_bullets.append(b)


## How far the eye ray of a shot runs before it hits something (the tracer meets the eye line there):
## one physics ray (the player excluded), clamped 2..120 m; nothing in the way (sky, far planet): 60 m.
func _aim_distance(eye: Vector3, vel: Vector3) -> float:
	if not is_inside_tree() or vel.length_squared() < 1e-4:
		return CONVERGE
	var dir := vel.normalized()
	var ex: Array = []
	var pl = rifle.get("player") if rifle != null else null
	if pl is CollisionObject3D:
		ex.append((pl as CollisionObject3D).get_rid())
	var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 120.0, MASK, ex)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return 60.0
	return clampf(eye.distance_to(hit["position"]), 2.0, 120.0)


func muzzle_light(p: Vector3, col: Color, energy: float, dur := 0.05, light_range := 9.0) -> void:
	var best: Dictionary = _lights[0]
	for li in _lights:
		if float(li["t"]) >= float(li["dur"]):
			best = li
			break
	var l: OmniLight3D = best["light"]
	l.global_position = p
	l.light_color = col
	l.omni_range = light_range
	l.light_energy = energy
	l.visible = true
	best["t"] = 0.0
	best["dur"] = maxf(dur, 0.05)
	best["energy"] = energy
	best["fresh"] = true      # shots come from the physics step: render one frame at full strength


## Smoke wisp drifting from the muzzle after a shot (`k` scales the puff: the shotgun / sniper more).
func muzzle_smoke(p: Vector3, fwd: Vector3, up: Vector3, k := 1.0) -> void:
	_burst("msmoke", p, (fwd * 0.8 + up * 0.4).normalized(), Color(0.82, 0.82, 0.84), 1.0, clampf(k, 0.5, 2.5))


## Small gas puff (dart gun).
func muzzle_puff(p: Vector3, fwd: Vector3) -> void:
	_burst("msmoke", p, fwd, Color(0.9, 0.95, 1.0), 0.4)


## Ground hit: a hot spark flash, a ground-coloured dust puff, a fast dirt jet, flying clods and a
## bullet hole, all scaled by the calibre `cal` (1 = rifle round; default 1.6 heavy / 1.0); heavy
## rounds thud (bimp/dirt_heavy). Then the chip: dust that hangs a moment, a dark scuff that grows
## with repeated hits, and the cover erosion (Erosion.add_impact) with weight `erode` (< 0: from the
## calibre, Erosion.erosion_weight; 0: none) for `team` ("": the gun owner's side).
func impact_terrain(p: Vector3, n: Vector3, dir: Vector3, ground: Color, dart: bool, heavy: bool, cal := -1.0,
		erode := -1.0, team := "") -> void:
	if dart:
		_burst("dust", p, n, ground, 0.3)
		_sound("dirt", p, -14.0, 1.5)
		return
	var c := cal if cal > 0.0 else (1.6 if heavy else 1.0)
	var sc := clampf(sqrt(c), 0.7, 1.7)
	var rock := ground.r < 0.45 and absf(ground.r - ground.g) < 0.05
	_puff(p + n * 0.05, Color(1.0, 0.84, 0.6), 0.06, 0.24 * sc)
	_burst("sparks", p, n, Color(1.0, 0.75, 0.4), clampf((0.6 if rock else 0.3) * c, 0.12, 1.0), sc)
	_burst("dust", p, n.lerp(-dir, 0.25).normalized(), ground, clampf(0.55 + 0.3 * c, 0.3, 1.0), sc)
	_burst("spray", p, n.lerp(-dir, 0.15).normalized(), ground.darkened(0.1), clampf(0.5 + 0.35 * c, 0.3, 1.0), sc)
	_burst("debris", p, n.lerp(-dir, 0.3).normalized(), ground.darkened(0.25), clampf(0.45 + 0.4 * c, 0.3, 1.0), sc)
	_decal(p, n, 0.2 * sc, _tex_hole, Color(0.08, 0.065, 0.05, 0.97), 30.0)
	if c >= 1.4 and _has("dirt_heavy"):
		_sound("dirt_heavy", p, lerpf(-5.0, 0.0, clampf(c - 1.4, 0.0, 1.0)), randf_range(0.95, 1.08))
	else:
		_sound("rock" if rock else "dirt", p, -10.0 + 6.0 * clampf(c, 0.4, 1.4), randf_range(0.95, 1.2))
	# The chip (cover erosion pass): hanging dust, the growing scuff, the erosion itself.
	_burst("haze", p + n * 0.15, n.lerp(-dir, 0.35).normalized(), ground.lightened(0.12), clampf(0.4 + 0.3 * c, 0.3, 1.0), sc)
	_scuff(p, n, ground, sc)
	var w := erode if erode >= 0.0 else Erosion.erosion_weight(c)
	if w > 0.0:
		var tm := team
		if tm == "" and rifle != null and rifle.get("player") != null:
			tm = Game.team_of(rifle.player)
		Erosion.add_impact(p, n, w, tm)


## A dark scuff of disturbed soil around repeated hits: the nearest live scuff within SCUFF_JOIN m
## grows (with the square root of its hits, to SCUFF_MAX) and darkens, its centre drifting toward
## the new hits; else the next pooled one starts small. Fades over its last 4 s of SCUFF_LIFE.
func _scuff(p: Vector3, n: Vector3, ground: Color, sc: float) -> void:
	if _tex_scuff == null:
		_tex_scuff = _make_scuff_tex()
	var best: Dictionary = {}
	var bd := SCUFF_JOIN * SCUFF_JOIN
	for s in _scuffs:
		if float(s["life"]) <= 0.0:
			continue
		var d := (s["node"] as Decal).global_position.distance_squared_to(p)
		if d < bd:
			bd = d
			best = s
	var node: Decal
	if best.is_empty():
		while _scuffs.size() < N_SCUFFS:
			var nd := Decal.new()
			nd.visible = false
			nd.upper_fade = 0.3
			nd.lower_fade = 0.3
			nd.normal_fade = 0.35
			nd.texture_albedo = _tex_scuff
			add_child(nd)
			_scuffs.append({"node": nd, "t": 0.0, "life": 0.0, "hits": 0})
		best = _scuffs[_scuff_i]
		_scuff_i = (_scuff_i + 1) % _scuffs.size()
		best["hits"] = 0
		node = best["node"]
		node.global_transform = Transform3D(_basis_y(n).rotated(n.normalized(), randf() * TAU), p)
	else:
		node = best["node"]
	var hits := int(best["hits"]) + 1
	best["hits"] = hits
	if hits > 1:
		node.global_position = node.global_position.lerp(p, 1.0 / float(hits))
	var size := minf(sc * (0.3 + 0.16 * sqrt(float(hits - 1))), SCUFF_MAX)
	node.size = Vector3(size, maxf(size * 0.8, 0.5), size)
	var dark := ground.darkened(0.55)
	node.modulate = Color(dark.r, dark.g, dark.b, clampf(0.42 + 0.06 * float(hits), 0.42, 0.9))
	node.albedo_mix = 1.0
	node.visible = true
	best["t"] = 0.0
	best["life"] = SCUFF_LIFE


## Hull / metal hit: a hot flash, a shower of sparks off the ricochet line and along the normal, a
## wisp of smoke, a dent and a ricochet ping (bigger with the calibre `cal`).
func impact_metal(p: Vector3, n: Vector3, dir: Vector3, dart: bool, cal := 1.0) -> void:
	if dart:
		_burst("zap", p, n, Color(0.6, 0.9, 1.0), 0.4)
		_sound("metal", p, -14.0, 1.8)
		return
	var sc := clampf(sqrt(cal), 0.7, 1.7)
	_puff(p + n * 0.03, Color(1.0, 0.9, 0.7), 0.05, 0.2 * sc)
	_burst("sparks", p, n.lerp(dir.bounce(n), 0.5).normalized(), Color(1.0, 0.8, 0.45), 1.0, sc)
	_burst("sparks", p, n, Color(1.0, 0.66, 0.3), clampf(0.5 * cal, 0.2, 1.0), sc * 0.8)
	_burst("smoke", p, n, Color(0.45, 0.45, 0.47), 0.3)
	_decal(p, n, 0.12 * sc, _tex_hole_big, Color(0.05, 0.05, 0.06, 0.95), 30.0)
	_sound("metal", p, -4.0 + 2.0 * clampf(cal - 1.0, -1.0, 1.0), randf_range(1.0, 1.3))


## Creature hit: a splash of its alien body fluid (non-gory, glowing). Darts: a soft blue puff.
func impact_creature(p: Vector3, n: Vector3, dir: Vector3, goo: Color, dart: bool, heavy: bool) -> void:
	if dart:
		_burst("zap", p, n, Color(0.45, 0.9, 1.0), 0.6)
		_puff(p, Color(0.4, 0.85, 1.0), 0.12, 0.18)
		_sound("zap", p, -10.0, 1.6)
		return
	# Back-spray toward the shooter, a jet out along the shot, a bright puff, a splat where it lands.
	_burst("goo", p, (n - dir * 0.6).normalized(), goo, 1.0 if heavy else 0.8)
	_burst("goo", p, (dir + _up_at(p) * 0.15).normalized(), goo.lightened(0.2), 0.9 if heavy else 0.55)
	_puff(p, goo.lightened(0.15), 0.09, 0.38 if heavy else 0.26)
	_goo_splat(p, dir, goo, heavy)
	_sound("flesh", p, -2.0 if heavy else -4.0, randf_range(0.9, 1.15))


## Suit hit on an astronaut (no gore): sparks, a strong jet of escaping air / vapour out of the hole
## (and a puff out along the shot for big rounds), white and orange suit fragments, a hot flash, the
## recorded suit hit (thump + crunch + plate tick) and a hiss of air. Scaled by the calibre `cal`
## (default 1.6 heavy / 1.0). No decal: the target moves.
func impact_suit(p: Vector3, n: Vector3, dir: Vector3, heavy: bool, cal := -1.0) -> void:
	var c := cal if cal > 0.0 else (1.6 if heavy else 1.0)
	var sc := clampf(sqrt(c), 0.75, 1.6)
	var out := (n * 0.65 - dir * 0.35).normalized()
	_burst("sparks", p, n.lerp(-dir, 0.3).normalized(), Color(1.0, 0.82, 0.5), clampf(0.45 * c, 0.25, 1.0), sc)
	_burst("vapor", p, out, Color(0.92, 0.95, 1.0), clampf(0.7 + 0.25 * c, 0.5, 1.0), sc * 1.15)
	if c >= 0.8:
		_burst("vapor", p, (dir + n * 0.2).normalized(), Color(0.9, 0.93, 1.0), clampf(0.35 * c, 0.2, 0.8), sc)
	_burst("frag", p, (n + dir * 0.4).normalized(), Color.WHITE, clampf(0.4 + 0.3 * c, 0.3, 1.0), sc)
	_puff(p + n * 0.03, Color(1.0, 0.86, 0.62), 0.06, 0.2 * sc)
	if _has("suit"):
		_sound("suit", p, lerpf(-6.0, 0.0, clampf((c - 0.6) / 1.4, 0.0, 1.0)), randf_range(0.95, 1.06))
	else:
		_sound("flesh", p, -5.0 if heavy else -7.0, randf_range(0.95, 1.1))
		_sound("metal", p, -15.0, randf_range(1.05, 1.2))
	if heavy or randf() < 0.4:
		_sound("hiss", p, -14.0, randf_range(1.0, 1.15))


## Head hit: a cracked-glass decal on the visor at `point` (world), riding on the head bone `head`
## (it follows the animation and the ragdoll) and fading after CRACK_LIFE s.
func visor_crack(head: Node3D, point: Vector3, dir: Vector3) -> void:
	if head == null or not is_instance_valid(head) or not head.is_inside_tree():
		return
	if _tex_crack == null:
		_tex_crack = _make_crack_tex()
	# Re-use the crack already on this helmet, else the next pooled decal (capped).
	var d: Dictionary = {}
	for c in _cracks:
		if is_instance_valid(c["node"]) and (c["node"] as Node).get_parent() == head:
			d = c
			break
	if d.is_empty():
		while _cracks.size() < N_CRACKS:
			_cracks.append({"node": null, "t": 0.0, "life": 0.0})
		d = _cracks[_crack_i]
		_crack_i = (_crack_i + 1) % N_CRACKS
	var node: Decal = d["node"] if is_instance_valid(d["node"]) else null
	if node == null:
		node = Decal.new()
		node.texture_albedo = _tex_crack
		node.texture_emission = _tex_crack
		node.emission_energy = 0.6
		node.upper_fade = 0.2
		node.lower_fade = 0.2
		node.normal_fade = 0.3
		node.cull_mask = 0xFFFFF
		head.add_child(node)
		d["node"] = node
	elif node.get_parent() != head:
		node.reparent(head, false)
	node.size = Vector3(0.17, 0.12, 0.17)
	node.modulate = Color(0.95, 0.97, 1.0, 1.0)
	node.albedo_mix = 1.0
	node.global_transform = Transform3D(_basis_y(-dir).rotated(-dir, randf() * TAU), point)
	node.visible = true
	d["t"] = 0.0
	d["life"] = CRACK_LIFE


## A goo splat decal on the ground (or wall) behind the creature where the exit spray lands.
func _goo_splat(p: Vector3, dir: Vector3, goo: Color, heavy: bool) -> void:
	var now := Time.get_ticks_msec()
	if now - _splat_t < int(SPLAT_GAP * 1000.0) or not is_inside_tree():
		return
	_splat_t = now
	var up := _up_at(p)
	var d := (dir - up * 0.7).normalized()
	var q := PhysicsRayQueryParameters3D.create(p + dir * 0.3, p + d * 3.5, 1 | 2)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	var c := goo.darkened(0.15)
	_decal(hit["position"], hit["normal"], randf_range(0.5, 0.75) * (1.35 if heavy else 1.0), _tex_splat,
			Color(c.r, c.g, c.b, 0.9), 22.0)


## Local "up" (against gravity; works on the moons too). Weightless: away from the nearest world's
## centre (worlds are not at the scene origin).
static func _up_at(p: Vector3) -> Vector3:
	var g: Vector3 = Game.gravity_at(p)
	if g.length_squared() > 1e-6:
		return -g.normalized()
	var b := Game.body_at(p)
	var u := p - (b.global_position if b != null else Game.planet_center())
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


## Spent casing ejected to the right; it bounces on the ground and tinks.
## hull = true: a red shotgun hull (plastic body, brass head) instead of a brass casing.
## big: a magnum rifle case (the sniper, ×1.3); pistol: a short 9 mm case (the SMG).
func shell(p: Vector3, vel: Vector3, big: bool, hull := false, pistol := false) -> void:
	var s: Dictionary = _shells[_shell_i]
	_shell_i = (_shell_i + 1) % _shells.size()
	s["vel"] = vel
	s["spin"] = Vector3(randf_range(-40, 40), randf_range(-25, 25), randf_range(-40, 40))
	s["t"] = 0.0
	s["bounces"] = 0
	s["scale"] = 1.3 if big and not hull else 1.0            # the meshes are true size (_shell_meshes)
	s["near"] = false
	# Ejected next to the eye (the player's own gun): scaled like the view model it leaves (vm_parts.gd
	# VM_K) and thrown right, up and only a little back, so the cases clear the view to the side
	# instead of tumbling across the middle; _step_shells keeps one that passes the cheek from
	# looming over the screen (near).
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null and p.distance_to(cam.global_position) < 1.5:
		var cb := cam.global_transform.basis
		s["scale"] = float(s["scale"]) * preload("res://scripts/player/vm_parts.gd").fov_scale()
		s["near"] = true
		s["d0"] = p.distance_to(cam.global_position)
		var up_c := vel.dot(cb.y)
		vel += cb.x * 1.4 + cb.z * 0.6 - cb.y * maxf(up_c - 1.2, 0.0) * 0.6
		s["vel"] = vel
	var mi: MeshInstance3D = s["mi"]
	if _hull_mat == null:
		_brass_mat = mi.material_override
		_hull_mat = StandardMaterial3D.new()
		_hull_mat.albedo_color = Color(0.8, 0.14, 0.1)
		_hull_mat.roughness = 0.45
	mi.material_override = _hull_mat if hull else _brass_mat
	if not _shell_meshes.is_empty():
		mi.mesh = _shell_meshes["hull" if hull else ("pistol" if pistol else "rifle")]
	mi.global_transform = Transform3D(Basis().scaled(Vector3.ONE * float(s["scale"])), p)
	mi.visible = true


## A spent case: a tapered cylinder, `top` radius at the mouth, `bottom` at the head (true size, m).
static func _case_mesh(top: float, bottom: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = h
	m.radial_segments = 10
	m.rings = 1
	return m


# =================================================================================================
# Simulation
# =================================================================================================

func _physics_process(delta: float) -> void:
	_step_bullets(delta)
	_step_shells(delta)


func _step_bullets(delta: float) -> void:
	bullets_in_flight = _bullets.size()
	if _bullets.is_empty():
		return
	var space := get_world_3d().direct_space_state
	var ex: Array = []
	var shooter: Node = null
	if rifle != null and rifle.player != null:
		ex.append(rifle.player.get_rid())
		shooter = rifle.player
	var vcam := get_viewport().get_camera_3d()
	if vcam != null:
		_cam_pos = vcam.global_position
	var keep: Array = []
	for b in _bullets:
		var p: Vector3 = b["pos"]
		var start := p
		var v: Vector3 = b["vel"]
		v += Game.gravity_at(p) * delta
		var np := p + v * delta
		var done := false
		# Up to two segments per step (a piercing round continues past the body it hit).
		for pass_i in 2:
			var seg := np - p
			var len := seg.length()
			if len < 1e-4:
				break
			var dir := seg / len
			var exb: Array = ex if b["ignore"] == null else ex + [b["ignore"]]
			var q := PhysicsRayQueryParameters3D.create(p, np, MASK, exb)
			var hit := space.intersect_ray(q)
			var info := {}
			if not hit.is_empty():
				info = _classify(hit)
			# The helmet pokes out of the hit capsule: a round entering one before anything else is a
			# head hit on that body (it stops there).
			var hz := GunFeel.helmet_sweep(p, np, shooter)
			var helmet := false
			if not hz.is_empty() and hz["target"] != b.get("ignore_t") \
					and (info.is_empty() or p.distance_to(info["point"]) > float(hz["dist"])):
				info = {"type": "body", "target": hz["target"], "point": hz["point"], "normal": hz["normal"], "collider": null}
				helmet = true
			if info.is_empty():
				break
			var stop := true
			if rifle != null:
				stop = rifle.bullet_hit(info, dir, int(b["ammo"]), int(b["pierced"])) or helmet
			if stop:
				done = true
				np = info["point"]
				break
			# Pierced through a body: keep flying from just past the hit, ignoring that collider.
			b["pierced"] = int(b["pierced"]) + 1
			var hc = info.get("collider")
			b["ignore"] = (hc as CollisionObject3D).get_rid() if hc is CollisionObject3D else null
			b["ignore_t"] = info.get("target")             # nor its helmet
			var hp: Vector3 = info["point"]
			p = hp + dir * 0.05
			v *= 0.75
			np = p + v * delta * 0.5
		b["dist"] = float(b["dist"]) + start.distance_to(np)
		b["life"] = float(b["life"]) - delta
		b["pos"] = np
		b["vel"] = v
		if not done and b["foreign"] and not b["whizzed"]:
			_near_miss_check(b, start, np)
		if done or float(b["life"]) <= 0.0:
			_release(b)
			continue
		_draw_bullet(b, np, delta)
		keep.append(b)
	_bullets = keep


## Someone else's bullet passed the listener within NEAR_MISS_R this step: whizz / snap once.
func _near_miss_check(b: Dictionary, a: Vector3, c: Vector3) -> void:
	var seg := c - a
	var l2 := seg.length_squared()
	if l2 < 1e-6:
		return
	var u := clampf((_cam_pos - a).dot(seg) / l2, 0.0, 1.0)
	var q := a + seg * u
	if q.distance_to(_cam_pos) > NEAR_MISS_R or (b["from"] as Vector3).distance_to(_cam_pos) < 6.0:
		return
	b["whizzed"] = true
	var hf = load("res://scripts/items/hit_feel.gd").inst()
	if hf != null and hf.has_method("near_miss"):
		hf.near_miss(q, seg / sqrt(l2), (b["vel"] as Vector3).length())


## What a bullet hit: "body" (a node in group "damageable", or its child; info["target"]),
## "terrain" (the terrain layer) or "metal" (anything else).
func _classify(hit: Dictionary) -> Dictionary:
	var col: Object = hit["collider"]
	var target: Node = Game.damageable_of(col)
	if target != null:
		return {"type": "body", "target": target, "point": hit["position"], "normal": hit["normal"], "collider": col}
	var t := "metal"
	if col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & 1) != 0:
		t = "terrain"
	return {"type": t, "point": hit["position"], "normal": hit["normal"], "collider": col}


## Places the tracer streak (or dart) for a bullet whose true position is `pos`.
func _draw_bullet(b: Dictionary, pos: Vector3, delta: float) -> void:
	var vis = b["vis"]
	if vis == null:
		return
	var v: Vector3 = b["vel"]
	var speed := v.length()
	var dir := v / maxf(speed, 1e-4)
	# The muzzle offset shrinks linearly with the distance flown, so the drawn head runs in a STRAIGHT
	# line from the muzzle to the point the eye ray hits ("conv"); a fixed 14 m kinked there and, with
	# the gun swung off centre (strafing, sliding), the rounds looked bent.
	var k := clampf(1.0 - float(b["dist"]) / float(b.get("conv", CONVERGE)), 0.0, 1.0)
	var off: Vector3 = b["off"]
	var head := pos + off * k
	if b["dart"]:
		var node: Node3D = vis["node"]
		node.visible = true
		node.global_transform = Transform3D(_basis_y(-dir), head)
		return
	var mi: MeshInstance3D = vis["mi"]
	var prev: Vector3 = b["prev"]
	# Heavy rounds (width > 1, the sniper) draw a longer streak: at 2400 m/s a step is 40 m.
	var max_len := 9.0 * maxf(float(b.get("w", 1.0)), 1.0)
	var len := minf(clampf(speed * delta * 1.25, 1.2, max_len), head.distance_to(prev) + 0.6)
	b["prev"] = head
	var tip: MeshInstance3D = vis.get("tip")
	if len < 0.05:
		mi.visible = false
		if tip != null:
			tip.visible = false
		return
	var bas := _basis_y(dir)
	# Wider with distance so far tracers stay a visible streak instead of a sub-pixel line.
	var dc := head.distance_to(_cam_pos)
	var w := clampf(dc * 0.08, 1.0, 10.0) * float(b.get("w", 1.0))
	mi.global_transform = Transform3D(Basis(bas.x * w, bas.y * len, bas.z * w), head - dir * len * 0.5)
	mi.visible = true
	if tip != null:
		# The bright head of the round: a billboard glow that keeps a few pixels at range.
		tip.global_transform = Transform3D(Basis().scaled(Vector3.ONE * clampf(dc * 0.05, 1.0, 6.0) * sqrt(float(b.get("w", 1.0)))), head)
		tip.visible = true


func _release(b: Dictionary) -> void:
	var vis = b["vis"]
	if vis == null:
		return
	vis["busy"] = false
	if b["dart"]:
		(vis["node"] as Node3D).visible = false
	else:
		(vis["mi"] as Node3D).visible = false
		var tip = vis.get("tip")
		if tip != null:
			(tip as Node3D).visible = false


func _step_shells(delta: float) -> void:
	var space := get_world_3d().direct_space_state
	var cam := get_viewport().get_camera_3d()
	for s in _shells:
		var t: float = s["t"]
		if t > 2.6:
			continue
		var mi: MeshInstance3D = s["mi"]
		t += delta
		s["t"] = t
		if t > 2.6:
			mi.visible = false
			continue
		var v: Vector3 = s["vel"]
		var p := mi.global_position
		v += Game.gravity_at(p) * delta
		var np := p + v * delta
		if v.length_squared() > 0.04:
			var q := PhysicsRayQueryParameters3D.create(p, np, 1 | 2 | 4)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				var n: Vector3 = hit["normal"]
				var hp: Vector3 = hit["position"]
				var speed := v.length()
				v = v.bounce(n) * 0.32 + Vector3(randf_range(-0.3, 0.3), 0, randf_range(-0.3, 0.3))
				if v.dot(n) < 0.4 and speed > 1.0:
					v += n * 0.4
				s["spin"] = Vector3(s["spin"]) * 0.5
				np = hp + n * 0.012
				var bn: int = s["bounces"]
				if bn < 3 and speed > 1.0 and rifle != null:
					var st: AudioStream = rifle.synth_stream("tink")
					if st != null:
						_sound_stream(st, hp, -18.0 - bn * 5.0, randf_range(0.85, 1.25))
				s["bounces"] = bn + 1
				if speed < 0.8:
					v = Vector3.ZERO
					s["spin"] = Vector3.ZERO
		s["vel"] = v
		var sp: Vector3 = s["spin"]
		var bas := mi.global_transform.basis
		if sp.length_squared() > 0.01:
			bas = bas.rotated(sp.normalized(), sp.length() * delta)
		var sc: float = float(s["scale"]) * clampf((2.6 - t) * 2.0, 0.0, 1.0)
		if s.get("near", false) and cam != null:
			# Passing the cheek: never larger on screen than where it left the port (no case looming
			# over the view).
			sc *= clampf(np.distance_to(cam.global_position) / maxf(float(s.get("d0", 0.25)), 0.05), 0.3, 1.0)
		mi.global_transform = Transform3D(bas.orthonormalized().scaled(Vector3.ONE * maxf(sc, 0.001)), np)


func _process(delta: float) -> void:
	for f in _puffs:
		var t: float = f["t"]
		var dur: float = f["dur"]
		if t >= dur:
			continue
		t += delta
		f["t"] = t
		var mi: MeshInstance3D = f["mi"]
		if t >= dur:
			mi.visible = false
			continue
		var k := t / dur
		mi.scale = Vector3.ONE * float(f["size"]) * (0.4 + 0.6 * sqrt(k))
		(f["mat"] as StandardMaterial3D).albedo_color.a = (1.0 - k) * (1.0 - k)
	for li in _lights:
		var t: float = li["t"]
		var dur: float = li["dur"]
		if t >= dur:
			continue
		if li.get("fresh", false):
			li["fresh"] = false
			continue
		t += delta
		li["t"] = t
		var l: OmniLight3D = li["light"]
		if t >= dur:
			l.visible = false
			continue
		var k := 1.0 - t / dur
		l.light_energy = float(li["energy"]) * k * k
	for d in _decals:
		var life: float = d["life"]
		if life <= 0.0:
			continue
		var t: float = float(d["t"]) + delta
		d["t"] = t
		var node: Decal = d["node"]
		if t >= life:
			node.visible = false
			d["life"] = 0.0
			continue
		node.albedo_mix = clampf((life - t) / 3.0, 0.0, 1.0)
	for c in _cracks:
		var life: float = c["life"]
		if life <= 0.0:
			continue
		var cn = c["node"]
		if not is_instance_valid(cn):
			c["life"] = 0.0
			continue
		var t: float = float(c["t"]) + delta
		c["t"] = t
		var dn := cn as Decal
		if t >= life:
			dn.visible = false
			c["life"] = 0.0
			continue
		dn.albedo_mix = clampf((life - t) / 3.0, 0.0, 1.0)
		dn.emission_energy = 0.6 * dn.albedo_mix
	for s in _scuffs:
		var life: float = s["life"]
		if life <= 0.0:
			continue
		var t: float = float(s["t"]) + delta
		s["t"] = t
		var sn: Decal = s["node"]
		if t >= life:
			sn.visible = false
			s["life"] = 0.0
			continue
		sn.albedo_mix = clampf((life - t) / 4.0, 0.0, 1.0)


func _exit_tree() -> void:
	# Cracks ride on other characters' heads: take them along when this gun goes away.
	for c in _cracks:
		if is_instance_valid(c["node"]):
			(c["node"] as Node).queue_free()
	_cracks.clear()


# =================================================================================================
# Internals
# =================================================================================================

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


static func _basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


func _make_dart() -> Node3D:
	var root := Node3D.new()
	root.visible = false
	add_child(root)
	var body := StandardMaterial3D.new()
	body.albedo_color = Color(0.85, 0.88, 0.92)
	body.metallic = 0.6
	body.roughness = 0.3
	var shaft := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.004
	cm.bottom_radius = 0.006
	cm.height = 0.09
	cm.radial_segments = 8
	cm.rings = 1
	shaft.mesh = cm
	shaft.material_override = body
	root.add_child(shaft)
	var tip := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.004
	tm.bottom_radius = 0.0
	tm.height = 0.03
	tm.radial_segments = 6
	tm.rings = 1
	tip.mesh = tm
	tip.material_override = body
	tip.position = Vector3(0, -0.06, 0)
	root.add_child(tip)
	var glow := _add_mat(Color(0.4, 0.9, 1.0), 4.0)
	for k in 2:
		var fin := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.03, 0.025, 0.003)
		fin.mesh = bm
		fin.material_override = glow
		fin.position = Vector3(0, 0.045, 0)
		fin.rotation.y = k * PI * 0.5
		root.add_child(fin)
	for c in root.get_children():
		(c as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


func _puff(p: Vector3, col: Color, dur: float, size: float) -> void:
	var best: Dictionary = _puffs[0]
	for f in _puffs:
		if float(f["t"]) >= float(f["dur"]):
			best = f
			break
	var mi: MeshInstance3D = best["mi"]
	mi.global_position = p
	var m: StandardMaterial3D = best["mat"]
	m.albedo_color = Color(col.r, col.g, col.b, 1.0)
	m.emission = col
	mi.scale = Vector3.ONE * size * 0.4
	mi.visible = true
	best["t"] = 0.0
	best["dur"] = dur
	best["size"] = size


func _decal(p: Vector3, n: Vector3, size: float, tex: Texture2D, col: Color, life: float) -> void:
	var d: Dictionary = _decals[_decal_i]
	_decal_i = (_decal_i + 1) % _decals.size()
	var node: Decal = d["node"]
	node.texture_albedo = tex
	node.modulate = col
	node.albedo_mix = 1.0
	node.size = Vector3(size, maxf(size * 0.8, 0.4), size)
	var b := _basis_y(n).rotated(n.normalized(), randf() * TAU)
	node.global_transform = Transform3D(b, p)
	node.visible = true
	d["t"] = 0.0
	d["life"] = life


## One pooled one-shot burst. `sc` scales the whole burst (particle size, speed and reach: the
## emitter's transform is baked into world-space particles) for the round's calibre.
func _burst(kind: String, p: Vector3, n: Vector3, col: Color, amount: float, sc := 1.0) -> void:
	var pool: Dictionary = _emit[kind]
	var list: Array = pool["list"]
	var i: int = pool["i"]
	pool["i"] = (i + 1) % list.size()
	var e: GPUParticles3D = list[i]
	var pm: ParticleProcessMaterial = e.process_material
	pm.color = col * 3.0 if (kind == "sparks" or kind == "zap") else col
	pm.gravity = Game.gravity_at(p) * float(e.get_meta("gk"))
	e.amount_ratio = clampf(amount, 0.05, 1.0)
	e.global_transform = Transform3D(_basis_y(n).scaled(Vector3.ONE * clampf(sc, 0.4, 2.5)), p)
	e.restart()


func _make_pool(kind: String) -> Dictionary:
	var list: Array = []
	for i in N_EMIT:
		list.append(_make_emitter(kind))
	return {"list": list, "i": 0}


func _make_emitter(kind: String) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.one_shot = true
	e.emitting = false
	e.explosiveness = 0.95
	e.local_coords = false
	e.fixed_fps = 0
	e.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.04
	var quad := QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = _tex_dot
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	var gk := 1.0
	match kind:
		"dust":
			e.amount = 22
			e.lifetime = 1.4
			pm.spread = 34.0
			pm.initial_velocity_min = 1.0
			pm.initial_velocity_max = 4.2
			pm.damping_min = 3.0
			pm.damping_max = 5.0
			pm.scale_min = 0.5
			pm.scale_max = 1.4
			pm.scale_curve = _curve(0.35, 1.0, 1.9)
			gk = 0.12
			quad.size = Vector2(0.4, 0.4)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 1.0
		"spray":
			# The dirt jet thrown up out of the hole: fast, narrow, dense, braking hard.
			e.amount = 16
			e.lifetime = 0.7
			e.explosiveness = 1.0
			pm.spread = 13.0
			pm.initial_velocity_min = 4.0
			pm.initial_velocity_max = 10.0
			pm.damping_min = 9.0
			pm.damping_max = 14.0
			pm.scale_min = 0.4
			pm.scale_max = 1.0
			pm.scale_curve = _curve(0.5, 1.0, 1.5)
			gk = 0.5
			quad.size = Vector2(0.18, 0.18)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 1.0
		"smoke", "msmoke":
			e.amount = 10 if kind == "smoke" else 8
			e.lifetime = 1.8 if kind == "smoke" else 1.0
			e.explosiveness = 0.8
			pm.spread = 25.0 if kind == "smoke" else 12.0
			pm.initial_velocity_min = 0.6
			pm.initial_velocity_max = 2.0 if kind == "smoke" else 1.6
			pm.damping_min = 1.5
			pm.damping_max = 2.5
			pm.scale_min = 0.6
			pm.scale_max = 1.2
			pm.scale_curve = _curve(0.3, 1.0, 2.4)
			gk = -0.04
			quad.size = Vector2(0.7, 0.7) if kind == "smoke" else Vector2(0.2, 0.2)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 1.0
			if kind == "msmoke":
				var fade2 := Gradient.new()
				fade2.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
				fade2.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.35), Color(1, 1, 1, 0)])
				var ramp2 := GradientTexture1D.new()
				ramp2.gradient = fade2
				pm.color_ramp = ramp2
		"debris":
			e.amount = 14
			e.lifetime = 1.3
			pm.spread = 32.0
			pm.initial_velocity_min = 2.0
			pm.initial_velocity_max = 6.5
			pm.angular_velocity_min = -540.0
			pm.angular_velocity_max = 540.0
			pm.scale_min = 0.5
			pm.scale_max = 1.2
			gk = 1.0
			var bm := BoxMesh.new()
			bm.size = Vector3(0.035, 0.028, 0.04)
			var dm := StandardMaterial3D.new()
			dm.vertex_color_use_as_albedo = true
			dm.roughness = 0.95
			bm.material = dm
			e.draw_pass_1 = bm
			pm.color_ramp = null
		"sparks", "zap":
			e.amount = 24 if kind == "sparks" else 16
			e.lifetime = 0.36 if kind == "sparks" else 0.25
			pm.spread = 50.0 if kind == "sparks" else 90.0
			pm.initial_velocity_min = 3.5
			pm.initial_velocity_max = 10.0 if kind == "sparks" else 5.0
			pm.damping_min = 2.0
			pm.damping_max = 4.0
			pm.scale_min = 0.5
			pm.scale_max = 1.1
			pm.particle_flag_align_y = true
			gk = 0.6 if kind == "sparks" else 0.0
			quad.size = Vector2(0.014, 0.12)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
			mat.billboard_keep_scale = true
			mat.albedo_texture = null
		"vapor":
			# Escaping suit air: a fast white jet that brakes hard and spreads.
			e.amount = 18
			e.lifetime = 0.85
			e.explosiveness = 0.9
			pm.spread = 15.0
			pm.initial_velocity_min = 3.0
			pm.initial_velocity_max = 8.5
			pm.damping_min = 7.0
			pm.damping_max = 10.0
			pm.scale_min = 0.5
			pm.scale_max = 1.2
			pm.scale_curve = _curve(0.3, 1.0, 2.6)
			gk = -0.02
			quad.size = Vector2(0.26, 0.26)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 1.0
			var fv := Gradient.new()
			fv.offsets = PackedFloat32Array([0.0, 0.1, 1.0])
			fv.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
			var rv := GradientTexture1D.new()
			rv.gradient = fv
			pm.color_ramp = rv
		"frag":
			# Suit fragments: white shell / orange fabric flakes tumbling away.
			e.amount = 8
			e.lifetime = 1.1
			pm.spread = 40.0
			pm.initial_velocity_min = 1.8
			pm.initial_velocity_max = 4.8
			pm.angular_velocity_min = -720.0
			pm.angular_velocity_max = 720.0
			pm.scale_min = 0.6
			pm.scale_max = 1.3
			gk = 1.0
			var cg := Gradient.new()
			cg.offsets = PackedFloat32Array([0.0, 0.55, 0.56, 1.0])
			cg.colors = PackedColorArray([Color(0.92, 0.92, 0.9), Color(0.92, 0.92, 0.9), Color(0.93, 0.42, 0.08), Color(0.35, 0.36, 0.38)])
			var ct := GradientTexture1D.new()
			ct.gradient = cg
			pm.color_initial_ramp = ct
			var fb := BoxMesh.new()
			fb.size = Vector3(0.022, 0.004, 0.017)
			var fm := StandardMaterial3D.new()
			fm.vertex_color_use_as_albedo = true
			fm.roughness = 0.5
			fb.material = fm
			e.draw_pass_1 = fb
			pm.color_ramp = null
		"goo":
			e.amount = 24
			e.lifetime = 0.8
			pm.spread = 30.0
			pm.initial_velocity_min = 2.0
			pm.initial_velocity_max = 6.5
			pm.damping_min = 0.5
			pm.damping_max = 1.2
			pm.scale_min = 0.45
			pm.scale_max = 1.4
			pm.scale_curve = _curve(1.0, 0.9, 0.3)
			gk = 1.0
			quad.size = Vector2(0.1, 0.1)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		"haze":
			# Dust that hangs a moment after the hit (cover erosion pass): a few big, slow, faint puffs
			# that barely fall and spread as they fade.
			e.amount = 6
			e.lifetime = 2.6
			e.explosiveness = 0.85
			pm.spread = 55.0
			pm.initial_velocity_min = 0.25
			pm.initial_velocity_max = 1.1
			pm.damping_min = 0.8
			pm.damping_max = 1.6
			pm.scale_min = 0.7
			pm.scale_max = 1.3
			pm.scale_curve = _curve(0.5, 1.2, 2.4)
			gk = 0.02
			quad.size = Vector2(0.6, 0.6)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.roughness = 1.0
			var fh := Gradient.new()
			fh.offsets = PackedFloat32Array([0.0, 0.12, 0.5, 1.0])
			fh.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.3), Color(1, 1, 1, 0.18), Color(1, 1, 1, 0)])
			var rh := GradientTexture1D.new()
			rh.gradient = fh
			pm.color_ramp = rh
	if kind != "debris" and kind != "frag":
		quad.material = mat
		e.draw_pass_1 = quad
	e.process_material = pm
	e.set_meta("gk", gk)
	add_child(e)
	return e


func _curve(a: float, b: float, c: float) -> CurveTexture:
	var cv := Curve.new()
	cv.max_value = 3.0
	cv.add_point(Vector2(0.0, a))
	cv.add_point(Vector2(0.3, b))
	cv.add_point(Vector2(1.0, c))
	var ct := CurveTexture.new()
	ct.curve = cv
	return ct


## True when the recorded set `name` has sounds (new sets may not be imported yet).
func _has(name: String) -> bool:
	return _streams.has(name) and not (_streams[name] as Array).is_empty()


func _sound(name: String, p: Vector3, vol: float, pitch: float) -> void:
	if not _streams.has(name):
		return
	var arr: Array = _streams[name]
	if arr.is_empty():
		return
	# Impact sounds: at most IMPACT_SND_FRAME per physics frame (a shotgun blast is a few thuds, not nine).
	var f := Engine.get_physics_frames()
	if f != _snd_frame:
		_snd_frame = f
		_snd_count = 0
	if name != "hiss":
		_snd_count += 1
		if _snd_count > IMPACT_SND_FRAME:
			return
	if name != "zap":
		pitch = clampf(pitch, 0.85, 1.2) * randf_range(0.97, 1.03)   # recordings near their own pitch
	_sound_stream(arr[randi() % arr.size()], p, vol, pitch)


func _sound_stream(st: AudioStream, p: Vector3, vol: float, pitch: float) -> void:
	var pl: AudioStreamPlayer3D = _audio[_audio_i]
	_audio_i = (_audio_i + 1) % _audio.size()
	pl.stream = st
	pl.global_position = p
	pl.volume_db = vol
	pl.pitch_scale = pitch
	if Game.sfx != null and Game.sfx.has_method("route_player"):
		Game.sfx.route_player(pl)       # no sound in vacuum (sfx.gd medium rules)
	pl.play()


static func _ogg_set(pattern: String, n: int) -> Array:
	var out: Array = []
	for i in n:
		var path := "res://assets/audio/%s.ogg" % (pattern % i)
		if ResourceLoader.exists(path):
			var s = load(path)
			if s != null:
				out.append(s)
	return out


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


## Procedural goo splat: an irregular blob with a few droplets around it (alpha = coverage, white).
static func _make_splat_tex() -> Texture2D:
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 77
	noise.frequency = 0.07
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 5
	var drops: Array = []
	for i in 9:
		var a := rng2.randf() * TAU
		var r := rng2.randf_range(0.5, 0.85)
		drops.append([Vector2(cos(a), sin(a)) * r, rng2.randf_range(0.04, 0.09)])
	for y in n:
		for x in n:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(n) * 2.0 - Vector2.ONE
			var ang := atan2(u.y, u.x)
			var rr := u.length() * (1.0 + 0.25 * sin(ang * 5.0 + 1.3) + 0.35 * noise.get_noise_2d(x, y))
			var a := 1.0 - smoothstep(0.32, 0.42, rr)
			for dd in drops:
				var dl := (u - (dd[0] as Vector2)).length()
				a = maxf(a, 1.0 - smoothstep(float(dd[1]) * 0.7, float(dd[1]), dl))
			var shade := 0.85 + 0.15 * noise.get_noise_2d(x * 3.0, y * 3.0)
			img.set_pixel(x, y, Color(shade, shade, shade, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


## Procedural cracked visor glass: an impact star, jagged radial cracks and broken rings (white,
## alpha = crack coverage).
static func _make_crack_tex() -> Texture2D:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var c := Vector2(n, n) * 0.5
	# Radial cracks: jagged polylines from the centre.
	for k in 11:
		var ang := TAU * float(k) / 11.0 + rng.randf_range(-0.25, 0.25)
		var p := c
		var len := rng.randf_range(0.28, 0.48) * n
		var steps := 14
		for s in steps:
			var dir := Vector2(cos(ang), sin(ang))
			var q := p + dir * len / steps
			_crack_line(img, p, q, 1.0 - float(s) / steps * 0.6)
			p = q
			ang += rng.randf_range(-0.35, 0.35)
	# Broken concentric rings.
	for r in [0.1, 0.19, 0.3]:
		var segs := 26
		for s in segs:
			if rng.randf() < 0.35:
				continue
			var a0 := TAU * s / segs
			var a1 := TAU * (s + 1) / segs
			var rr := float(r) * n * rng.randf_range(0.92, 1.08)
			_crack_line(img, c + Vector2(cos(a0), sin(a0)) * rr, c + Vector2(cos(a1), sin(a1)) * rr, 0.75)
	# Pulverized impact point.
	for y in n:
		for x in n:
			var d := Vector2(x, y).distance_to(c)
			if d < 5.0:
				var a := clampf(1.0 - d / 5.0, 0.0, 1.0) * 0.9
				var old := img.get_pixel(x, y)
				img.set_pixel(x, y, Color(1, 1, 1, maxf(old.a, a)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _crack_line(img: Image, a: Vector2, b: Vector2, alpha: float) -> void:
	var steps := int(ceilf(a.distance_to(b) * 2.0)) + 1
	var sz := img.get_size()
	for i in steps + 1:
		var p := a.lerp(b, float(i) / float(steps))
		var x := int(p.x)
		var y := int(p.y)
		if x < 0 or y < 0 or x >= sz.x or y >= sz.y:
			continue
		var old := img.get_pixel(x, y)
		img.set_pixel(x, y, Color(1, 1, 1, maxf(old.a, alpha)))


## Procedural scuff of disturbed soil (cover erosion): a soft, irregular blotch with a few darker
## pits and grit specks (white, alpha = coverage; tinted by the decal's modulate).
static func _make_scuff_tex() -> Texture2D:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 311
	noise.frequency = 0.08
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 23
	var pits: Array = []
	for i in 7:
		var a := rng2.randf() * TAU
		pits.append([Vector2(cos(a), sin(a)) * rng2.randf_range(0.0, 0.45), rng2.randf_range(0.05, 0.11)])
	for y in n:
		for x in n:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(n) * 2.0 - Vector2.ONE
			var nz := noise.get_noise_2d(x, y)
			var r := u.length() * (1.0 + 0.3 * nz)
			var a := (1.0 - smoothstep(0.35, 0.95, r)) * 0.75
			var shade := 0.9 + 0.1 * noise.get_noise_2d(x * 2.5, y * 2.5)
			for pt in pits:
				var dl := (u - (pt[0] as Vector2)).length()
				var k := 1.0 - smoothstep(float(pt[1]) * 0.5, float(pt[1]), dl)
				a = maxf(a, k * 0.95)
				shade = minf(shade, lerpf(1.0, 0.6, k))
			if nz > 0.55:
				a = maxf(a, 0.6 * (1.0 - smoothstep(0.7, 1.05, u.length())))
			img.set_pixel(x, y, Color(shade, shade, shade, clampf(a, 0.0, 1.0)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Procedural bullet-hole textures: 0 dirt hole with a soft ring, 1 sharp metal dent.
func _make_decal_tex(kind: int) -> Texture2D:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 17 + kind
	noise.frequency = 0.09
	for y in n:
		for x in n:
			var u := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(n) * 2.0 - Vector2.ONE
			var r := u.length()
			var nz := noise.get_noise_2d(x, y)
			var core := 1.0 - smoothstep(0.12, 0.2, r)
			var ring := (1.0 - smoothstep(0.2, 0.62 + nz * 0.25, r)) * (0.55 if kind == 0 else 0.25)
			var a := maxf(core, ring)
			var c := Color(1, 1, 1).lerp(Color(0.55, 0.55, 0.55), core)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
