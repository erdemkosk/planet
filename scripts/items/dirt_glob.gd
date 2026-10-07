extends Node3D
## Toprak Topu's soil globs in flight and what they do where they land (scripts/items/dirt_launcher.gd
## owns one manager; a multiplayer replay uses its own, scripts/net/net_players.gd "Toprak Topu").
## The manager sits at the world origin (top_level); every glob is a small node it steps each physics
## frame. All the gameplay numbers of the weapon are the consts below.
##   kinds    KIND_GLOB (LMB, "Toprak Gülle") a fist-sized glob; KIND_WALL (RMB, "Toprak Duvar") a
##            heavier, slower one that raises a wall
##   flight   leaves at SPEED, Game.gravity_at pulls it into an arc; Ballistics.segment_hit every step
##            (physics: terrain, structures, vehicles, characters; plus the planets' density field)
##            and a fat test against the characters' capsules (GLOB_R): a glob brushing a shoulder hits
##   look     a lumpy, tumbling ball in the planet's soil colour (soil_color), clods dribbling off it
##            under gravity and a faint dust wisp; a heavy whoosh. At the impact: a wet splat blob that
##            slaps flat and sinks into the new soil, a dust burst, flying clods (the Kinetik İtici's
##            pooled chunks), a dirt spray, a deep thud; camera shake nearby
##   terrain  (the shooter's machine only, "owned") RAISE brushes through Dig.dig_at -> planet.apply_brush
##            (the multiplayer net hook replicates them; a client predicts its own like the drill):
##              gülle: a mound (MOUND_R, grown in MOUND_STEPS stamps over MOUND_TIME s) round the impact,
##                     on the ground, a wall or a tunnel roof alike (it narrows / plugs what it hits)
##              duvar: a wall standing on the ground across the shot, WALL_COLS columns × WALL_ROWS rows
##                     of stamps (~4.5 m wide, ~2.5 m high, ~1.5 m thick), rising row by row over
##                     WALL_TIME s, each column on its own ground
##            Never over a head: every stamp is scaled down so that no character (the shooter too)
##            gets soil at HEAD_H over its feet (_head_safe, the exact trilinear read of the brush).
##   hits     a direct hit (owned): DIRECT_DMG through Game.damage_target (a client's is a claim) with a
##            heavy shove (KNOCK_*: under player.gd RAGDOLL_PUSH for players, a hit-reactor stagger for
##            bots / dummies), the flinch at the struck part, a HitFeel marker; a duvar still raises its
##            wall on the ground under the body
##   burial   a mound / wall that lands at an enemy's feet (BURY_REACH), or a direct hit once the shove
##            has played (BURY_DELAY_DIRECT): a soil collar is raised round the legs (chest high, the
##            head kept free), then the body is buried through scripts/war/cave_in.gd (CaveIn.bury, head
##            free: stuck until the drill / melee / jump-mash or its own timer gets it out; bots dig out).
##            Not the shooter, not his own side, not airborne / down bodies, and never the same body
##            twice within BURY_COOLDOWN s (no chain burial).
## Multiplayer: a glob is fully described by (pos, vel, kind): the launcher emits dirt_fired and the
## other machine replays it with launch(..., owned = false): the look only. The owner's machine decides
## the terrain (synced brushes), the hits (Game.damage_target: host-authoritative claims) and the
## burials: request_bury() buries on the host / in single player (CaveIn.bury; for the other player's
## avatar cave_in.gd's `buried` event carries it to his machine), a client claims it from the host
## (net_players.gd claim_dirt_bury); the terrain ops are flushed first so the collar is there before
## the body is held in it. execute_bury() runs on the deciding machine.
##   globs.launch(pos, vel, kind, team, owned, exclude_rids = [], shooter = null) -> Node3D
##   DirtGlob.predict(from, vel, space, exclude, max_t) -> {} | {"position", "normal", "body", "time"}
##   DirtGlob.request_bury(node, feet) / DirtGlob.execute_bury(node) -> bool

const Dig := preload("res://scripts/player/dig.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Rockets := preload("res://scripts/items/rockets.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const KineticPusher := preload("res://scripts/items/kinetic_pusher.gd")   # its pooled flying chunks (chunks())
const BuildFx := preload("res://scripts/war/build_fx.gd")                # the ground dust burst (the duvar's rise)
const CAVE_IN_PATH := "res://scripts/war/cave_in.gd"                    # (load()ed at use: another feature's file)

const KIND_GLOB := 0
const KIND_WALL := 1
const KIND_NAMES := ["gülle", "duvar"]

# --- Tuning (index = kind: [gülle, duvar]) ----------------------------------------------------------
const COST := [5.0, 30.0]               # (2026-10-07 economy: [4, 14] -> [5, 30]) m³ of material per shot (Game.add_material; the co-op pool too)
const SPEED := [34.0, 25.0]             # m/s out of the muzzle
const GLOB_R := [0.2, 0.3]              # m: the glob's size (look) and its reach onto a character's capsule
const LIFE := 6.0                       # s in the air at most (then it crumbles)
const DIRECT_DMG := [14.0, 20.0]        # hp of a direct hit
## 2026-10-06 tok (hit reactions that land instead of fling): players 5.0 / 5.4 -> 4.2 / 4.6 m/s, the
## lift 1.4 / 1.8 -> 1.0 / 1.3. KNOCK_BOT stays: it is the stagger score (|impulse| × HR_IMPULSE_K);
## the skid it gives is capped by Balance.HR_KB_MAX (now 5 m/s: ~1.1 m, was ~2.7 m at 7).
const KNOCK_PLAYER := [4.2, 4.6]        # m/s along the shot for players (+ KNOCK_UP: under RAGDOLL_PUSH 7.5)
const KNOCK_BOT := [11.5, 12.0]         # m/s for bots / dummies: past hit_reactor.gd's stagger score (HR_STAGGER)
const KNOCK_UP := [1.0, 1.3]            # m/s up with it
# The mound (gülle).
const MOUND_R := 1.7                    # brush radius (m): ~3 m across, ~1 m high on flat ground
const MOUND_A := 3.0                    # brush strength (≈ m of density at the centre), in MOUND_STEPS parts
const MOUND_STEPS := 3
const MOUND_TIME := 0.15                # s the mound grows over
# The wall (duvar).
const WALL_COLS := 5
const WALL_STEP := 0.95                 # m between the columns (≈ 4.5 m wide with the radius)
const WALL_ROWS := [0.35, 1.25, 2.05]   # m over the ground of each row of stamps
const WALL_R := 1.15
const WALL_A := [4.0, 4.0, 3.4]
const WALL_TIME := 0.24                 # s from the bottom row to the top one
const WALL_BACK := 0.35                 # m the wall stands back from the impact toward the shooter
const WALL_STEEP := 0.55                # a hit on a face steeper than this (normal·up) builds on the ground below it
# Burial.
const BURY_REACH := [1.5, 1.2]          # m (flat) from the mound centre / the wall line to the feet
const BURY_DELAY_DIRECT := 0.4          # s after a direct hit (the shove plays first)
const COLLAR_UP := 0.3                  # m over the feet: the collar's centre...
const COLLAR_R := 1.45                  # ...radius...
const COLLAR_A := 4.0                   # ...and strength (in two stamps, COLLAR_TIME s)
const COLLAR_TIME := 0.1
const CHEST_H := 1.0                    # cave_in.gd's "chest": soil here holds the body
const HEAD_H := [1.45, 1.8]             # never soil at these heights over a character's feet (eye 1.72)...
const CROUCH_H := [1.05, 1.4]           # ...crouched (eye ~1.25: no chest-deep burial then)...
const DOWN_H := [0.35, 0.8]             # ...or over a body lying down
const HEAD_MARGIN := 0.3                # density kept at least this far into the air there
const BURY_COOLDOWN := 6.0              # s: the same body cannot be buried by this gun again
# Feel.
const SHAKE_R := 14.0                   # m: camera shake reach of an impact
const SHAKE := [0.22, 0.38]

const SPLAT_LIFE := 0.34


## One glob in flight (stepped by the manager).
class Glob extends Node3D:
	var kind := 0
	var vel := Vector3.ZERO
	var age := 0.0
	var team := "home"
	var owned := false                 # this machine's shot: terrain, hits and burials are decided here
	var exclude: Array = []
	var shooter: Node3D = null
	var done := false
	var col := Color(0.45, 0.35, 0.24)
	var axis := Vector3.RIGHT
	var spin := 0.0
	var ball: Node3D
	var clods: GPUParticles3D
	var wisp: GPUParticles3D
	var whoosh: AudioStreamPlayer3D


## The wet blob that slaps flat on the impact and sinks into the soil (covers the re-mesh).
class Splat extends MeshInstance3D:
	var t := 0.0
	var size := 1.0
	var mat: StandardMaterial3D

	func _process(delta: float) -> void:
		t += delta
		var u := t / SPLAT_LIFE
		if u >= 1.0:
			queue_free()
			return
		var grow := 1.0 - pow(1.0 - clampf(u / 0.25, 0.0, 1.0), 3.0)
		var flat := lerpf(0.75, 0.32, clampf(u / 0.3, 0.0, 1.0))
		var sink := clampf((u - 0.45) / 0.55, 0.0, 1.0)
		scale = Vector3(size * (0.35 + 0.75 * grow), size * flat * (1.0 - 0.8 * sink), size * (0.35 + 0.75 * grow))
		position -= global_transform.basis.y.normalized() * delta * 0.6 * sink
		mat.albedo_color.a = 1.0 - sink * sink


var launched := 0
var impacts := 0
var last_impact := Vector3.INF
var last_hit: Node = null
var stamps := 0                          # brushes applied (tests)
var soil_placed := 0.0                   # m³ (tests)
var burials := 0                         # burials requested (tests)
var _list: Array = []                    # live Glob nodes
var _dead: Array = []                    # [Glob, s until freed] (their clods still falling)
var _jobs: Array = []                    # timed stamps and burials (owned shots): see _step_jobs
var _audio: Array = []
var _audio_i := 0
var _streams := {}
var _chars: Array = []
var _chars_frame := -1
static var _bury_ms := {}                # instance id -> msec of its last burial by this gun (BURY_COOLDOWN)
static var _clod_mesh: BoxMesh
static var _clod_mat: StandardMaterial3D
static var _wisp_mat: StandardMaterial3D


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	for i in 6:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 9.0
		p.max_distance = 160.0
		add_child(p)
		_audio.append(p)
	for n: String in ["bimp/dirt_heavy", "bimp/dirt", "whoosh/whoosh", "melee/dirt"]:
		var st: AudioStream = Snd.rand(n, 1.06, 1.5)
		if st != null:
			_streams[n] = st


func in_flight() -> int:
	return _list.size()


func busy() -> bool:
	return not _list.is_empty() or not _jobs.is_empty()


# =================================================================================================
# Launch / flight
# =================================================================================================

## Fires a glob from `pos` (world) at `vel` for side `p_team`. owned: this machine's own shot (terrain,
## hits, burials); a replay of another machine's shot is the look only. exclude_rids: physics RIDs it
## flies through (the shooter's collider); shooter: the firing character (never hit, never buried).
func launch(pos: Vector3, vel: Vector3, kind: int, p_team: String, owned: bool, exclude_rids: Array = [],
		shooter: Node3D = null) -> Node3D:
	var g := Glob.new()
	g.kind = clampi(kind, 0, 1)
	g.vel = vel
	g.team = p_team
	g.owned = owned
	g.exclude = exclude_rids
	g.shooter = shooter
	g.col = soil_at(pos)
	g.axis = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
	add_child(g)
	g.global_position = pos
	_build_glob(g)
	_list.append(g)
	launched += 1
	return g


## One flight step (the same rule as predict()).
static func advance(p: Vector3, v: Vector3, dt: float) -> Array:
	var g: Vector3 = Game.gravity_at(p)
	return [p + v * dt + g * (0.5 * dt * dt), v + g * dt]


## Where a glob launched from `from` at `vel` lands: {} or {"position", "normal", "body", "time"}.
static func predict(from: Vector3, vel: Vector3, space: PhysicsDirectSpaceState3D, exclude: Array = [],
		max_t := 3.0, dt := 1.0 / 20.0) -> Dictionary:
	var p := from
	var v := vel
	var t := 0.0
	while t < max_t:
		var res := advance(p, v, dt)
		var np: Vector3 = res[0]
		var hit := Ballistics.segment_hit(p, np, space, exclude)
		if not hit.is_empty():
			hit["time"] = t
			return hit
		p = np
		v = res[1]
		t += dt
	return {}


func _physics_process(delta: float) -> void:
	for i in range(_dead.size() - 1, -1, -1):
		_dead[i][1] = float(_dead[i][1]) - delta
		if float(_dead[i][1]) <= 0.0:
			var dn = _dead[i][0]
			if is_instance_valid(dn):
				(dn as Node).queue_free()
			_dead.remove_at(i)
	_step_jobs()
	if _list.is_empty():
		return
	var space := get_world_3d().direct_space_state
	for g in _list.duplicate():
		if not is_instance_valid(g):
			_list.erase(g)
			continue
		_step(g as Glob, delta, space)


func _step(g: Glob, delta: float, space: PhysicsDirectSpaceState3D) -> void:
	var p := g.global_position
	var res := advance(p, g.vel, delta)
	var np: Vector3 = res[0]
	g.age += delta
	var hit := Ballistics.segment_hit(p, np, space, g.exclude)
	var hit_t := 2.0
	if not hit.is_empty():
		hit_t = p.distance_to(hit["position"]) / maxf(p.distance_to(np), 1e-4)
	# A character's capsule within the glob's size of the path (a glob brushing a shoulder hits).
	var ch: Node3D = null
	var ch_t := 2.0
	var ch_p := Vector3.ZERO
	for n in characters():
		var nd := n as Node3D
		if nd == g.shooter or not _alive(nd):
			continue
		var up := nd.global_transform.basis.y
		var a := nd.global_position + up * 0.3
		var b := nd.global_position + up * 1.6
		if minf(a.distance_to(p), b.distance_to(p)) > np.distance_to(p) + 3.0:
			continue
		var cp := _seg_closest(p, np, a, b)
		if (cp[0] as Vector3).distance_to(cp[1]) <= 0.42 + float(GLOB_R[g.kind]) and float(cp[2]) < ch_t:
			ch_t = float(cp[2])
			ch = nd
			ch_p = cp[1] + ((cp[0] as Vector3) - (cp[1] as Vector3)).limit_length(0.4)
	if ch != null and ch_t <= hit_t:
		_impact(g, ch_p, (p - ch_p).normalized(), ch, null)
		return
	if not hit.is_empty():
		var t := Game.damageable_of(hit.get("body")) if hit.get("body") is Object else null
		if t != null and t.get("astronaut") == null and not t.is_in_group("net_player"):
			t = null                                 # (a structure: the soil splats on it)
		_impact(g, hit["position"], hit["normal"], t, hit.get("body"))
		return
	g.vel = res[1]
	g.global_position = np
	if g.age >= LIFE:
		_crumble(g)


## Closest points of segments p0-p1 and q0-q1: [on p, on q, t along p (0..1)].
static func _seg_closest(p0: Vector3, p1: Vector3, q0: Vector3, q1: Vector3) -> Array:
	var d1 := p1 - p0
	var d2 := q1 - q0
	var r := p0 - q0
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-8 and e <= 1e-8:
		return [p0, q0, 0.0]
	if a <= 1e-8:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-8:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var den := a * e - b * b
			s = clampf((b * f - c * e) / den, 0.0, 1.0) if den > 1e-8 else 0.0
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return [p0 + d1 * s, q0 + d2 * t, s]


func _process(delta: float) -> void:
	for g in _list:
		if not is_instance_valid(g):
			continue
		var gl := g as Glob
		gl.spin += delta * (9.0 if gl.kind == KIND_GLOB else 6.0)
		# Tumbling, a little stretched along the flight.
		var d := gl.vel.normalized() if gl.vel.length_squared() > 0.01 else Vector3.FORWARD
		var st := Basis(Quaternion(Vector3.FORWARD, d)) * Basis.from_scale(Vector3(0.92, 0.92, 1.12))
		gl.ball.basis = st * Basis(gl.axis, gl.spin)


# =================================================================================================
# Impact
# =================================================================================================

func _impact(g: Glob, point: Vector3, n: Vector3, target: Node, collider) -> void:
	if g.done:
		return
	g.global_position = point
	var dir := g.vel.normalized() if g.vel.length_squared() > 1e-4 else -n
	var body: Node3D = Game.dominant_body(point)
	var up: Vector3 = body.up_at(point) if body != null and body.has_method("up_at") else -Game.gravity_at(point).normalized()
	var nn := n.normalized() if n.length_squared() > 0.01 else -dir
	splat_fx(self, point, nn, dir, g.kind, g.col, target != null)
	if g.owned:
		if target != null:
			_direct_hit(g, target as Node3D, point, dir)
			# The duvar still stands where it struck: on the ground under the body.
			if g.kind == KIND_WALL and body != null:
				var gp := ground_below(body, point + up * 0.2, up, 2.5)
				if gp != Vector3.INF:
					_wall(g, body, gp, up, dir, up)
		elif body != null and _terrain_hit(collider):
			if g.kind == KIND_GLOB:
				_mound(g, body, point, up)
			else:
				_wall(g, body, point, nn, dir, up)
	impacts += 1
	last_impact = point
	_finish(g)


## Ground (a planet or one of its collision chunks), not a structure / vehicle.
static func _terrain_hit(collider) -> bool:
	if collider == null or not is_instance_valid(collider):
		return true                                  # (the density field: the far planet)
	if collider is Node and (collider as Node).has_method("apply_brush"):
		return true
	if collider is CollisionObject3D:
		return ((collider as CollisionObject3D).collision_layer & Game.LAYER_TERRAIN) != 0 \
				and Game.damageable_of(collider) == null
	return false


func _direct_hit(g: Glob, t: Node3D, point: Vector3, dir: Vector3) -> void:
	last_hit = t
	if Game.team_of(t) == g.team:
		return                                       # (soil on a friend: the look only)
	var is_pl: bool = t == Game.player or t.is_in_group("net_player")
	var up_t := t.global_transform.basis.y
	var flat := dir - up_t * dir.dot(up_t)
	flat = flat.normalized() if flat.length_squared() > 1e-4 else -t.global_transform.basis.z
	var k: float = float(KNOCK_PLAYER[g.kind]) if is_pl else float(KNOCK_BOT[g.kind])
	var imp := flat * k + up_t * float(KNOCK_UP[g.kind])
	var src: Vector3 = g.shooter.global_position if g.shooter != null and is_instance_valid(g.shooter) else point - dir * 10.0
	var dmg := float(DIRECT_DMG[g.kind])
	var r := Game.damage_target(t, dmg, src, imp, g.team, point)
	var killed: bool = bool(r.get("killed", false)) or not _alive(t)
	var ast = t.get("astronaut")
	if not killed and ast != null and ast.has_method("hit_react"):
		ast.hit_react(dir, 0.8 + 0.3 * float(g.kind), false)
	if not r.is_empty():
		HitFeel.inst().target_hit(t, r, dmg, point, {"big": 0.5 + 0.2 * float(g.kind), "weapon": "Toprak Topu"})
	if not killed and not _bury_queued(t):
		_jobs.append({"kind": "bury", "node": t, "team": g.team, "shooter": g.shooter,
				"at": Time.get_ticks_msec() + int(BURY_DELAY_DIRECT * 1000.0)})


## The gülle's mound round `point`, grown over MOUND_TIME s; enemies at its foot are buried.
func _mound(g: Glob, body: Node3D, point: Vector3, up: Vector3) -> void:
	var now := Time.get_ticks_msec()
	for i in MOUND_STEPS:
		var at := now + int(MOUND_TIME * 1000.0 * float(i) / float(maxi(MOUND_STEPS - 1, 1)))
		_queue_stamp(body, point, MOUND_R, MOUND_A / float(MOUND_STEPS), at)
	_queue_buries(g, body, point, up, Vector3.ZERO, float(BURY_REACH[KIND_GLOB]), 0.0,
			now + int(MOUND_TIME * 1000.0) + 20)


## The duvar's wall across the shot, standing on the ground at (or under) the impact.
func _wall(g: Glob, body: Node3D, point: Vector3, n: Vector3, dir: Vector3, up: Vector3) -> void:
	var flat := dir - up * dir.dot(up)
	if flat.length_squared() < 1e-4:
		flat = -n - up * (-n).dot(up)
	if flat.length_squared() < 1e-4:
		flat = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	flat = flat.normalized()
	var base := point
	if n.dot(up) < WALL_STEEP:
		# A wall face / a roof: build on the ground in front of it.
		var gp := ground_below(body, point - flat * 0.6 + up * 0.3, up, 4.5)
		if gp != Vector3.INF:
			base = gp
	base -= flat * WALL_BACK
	var side := up.cross(flat).normalized()
	var now := Time.get_ticks_msec()
	var order: Array = []
	for c in WALL_COLS:
		order.append(c)
	var mid := (WALL_COLS - 1) * 0.5
	order.sort_custom(func(a, b): return absf(float(a) - mid) < absf(float(b) - mid))
	var rows: int = WALL_ROWS.size()
	for ri in rows:
		for oi in order.size():
			var c: int = order[oi]
			var off := (float(c) - mid) * WALL_STEP
			var col_base := base + side * off
			var gp := ground_below(body, col_base + up * 1.2, up, 3.7)
			if gp != Vector3.INF:
				col_base = gp
			var at := now + int(WALL_TIME * 1000.0 * float(ri) / float(maxi(rows - 1, 1))) + oi * 12
			_queue_stamp(body, col_base + up * float(WALL_ROWS[ri]), WALL_R, float(WALL_A[ri]), at)
	_queue_buries(g, body, base, up, side, float(BURY_REACH[KIND_WALL]), (WALL_COLS - 1) * 0.5 * WALL_STEP + 0.6,
			now + int(WALL_TIME * 1000.0) + 40)


## A standing character's feet (its node origin), or INF in the air (no ground within 0.9 m under it; feet
## already in soil count as standing).
static func feet_of(body: Node3D, n: Node3D) -> Vector3:
	var f := n.global_position
	var up: Vector3 = body.up_at(f)
	var h: Dictionary = body.raycast_density(f + up * 0.05, f - up * 0.9, 0.2, false)
	return Vector3.INF if h.is_empty() else f


## Ground under `from` along -up within `reach` m (the density field: also a dug / unbuilt chunk).
static func ground_below(body: Node3D, from: Vector3, up: Vector3, reach: float) -> Vector3:
	if body == null or not body.has_method("raycast_density"):
		return Vector3.INF
	var h: Dictionary = body.raycast_density(from, from - up * reach, 0.25, false)
	if h.is_empty():
		return Vector3.INF
	return h["position"]


## Enemies whose feet are within `reach` (flat) of `center` (or of the segment center ± side × half):
## a burial job each at `at`.
func _queue_buries(g: Glob, body: Node3D, center: Vector3, up: Vector3, side: Vector3, reach: float, half: float,
		at: int) -> void:
	for n in characters():
		var nd := n as Node3D
		if nd == g.shooter or not _alive(nd) or Game.team_of(nd) == g.team:
			continue
		if Game.dominant_body(nd.global_position) != body:
			continue
		var rel := nd.global_position - center
		var h := rel.dot(up)
		if absf(h) > 1.8:
			continue
		var fl := rel - up * h
		if half > 0.0:
			var along := clampf(fl.dot(side), -half, half)
			fl -= side * along
		if fl.length() > reach or _bury_queued(nd):
			continue
		_jobs.append({"kind": "bury", "node": nd, "team": g.team, "shooter": g.shooter, "at": at})


## A burial of `n` is already on its way (a direct hit and the wall's foot: one collar, one burial).
func _bury_queued(n: Node) -> bool:
	for j in _jobs:
		if (str(j["kind"]) == "bury" or str(j["kind"]) == "bury_check") and j["node"] == n:
			return true
	return false


func _queue_stamp(body: Node3D, p: Vector3, r: float, a: float, at: int) -> void:
	_jobs.append({"kind": "stamp", "body": body, "lp": p - body.global_position, "r": r, "a": a, "at": at})


## Due jobs (a few per frame): stamps (RAISE brushes, head-safe), burials (collar, then bury).
func _step_jobs() -> void:
	if _jobs.is_empty():
		return
	var now := Time.get_ticks_msec()
	var n := 0
	var i := 0
	while i < _jobs.size() and n < 6:
		var j: Dictionary = _jobs[i]
		if int(j["at"]) > now:
			i += 1
			continue
		_jobs.remove_at(i)
		n += 1
		match str(j["kind"]):
			"stamp":
				var body = j["body"]
				if body != null and is_instance_valid(body):
					var bn := body as Node3D
					stamp(bn, bn.global_position + (j["lp"] as Vector3), float(j["r"]), float(j["a"]))
			"bury":
				_bury_job(j, now)
			"bury_check":
				_bury_check(j)


## A burial: stage 0 raises the collar round the legs (two stamps), stage 1 checks the chest is in
## soil and buries.
func _bury_job(j: Dictionary, now: int) -> void:
	var nd = j["node"]
	if nd == null or not is_instance_valid(nd) or not _can_bury(nd as Node3D, str(j["team"])):
		return
	var node := nd as Node3D
	var body: Node3D = Game.dominant_body(node.global_position)
	if body == null:
		return
	var up: Vector3 = body.up_at(node.global_position)
	var feet := feet_of(body, node)
	if feet == Vector3.INF:
		return                                       # in the air: the soil misses the legs
	stamp(body, feet + up * COLLAR_UP, COLLAR_R, COLLAR_A * 0.5)
	_jobs.append({"kind": "stamp", "body": body, "lp": feet + up * COLLAR_UP - body.global_position, "r": COLLAR_R,
			"a": COLLAR_A * 0.5, "at": now + int(COLLAR_TIME * 500.0)})
	_jobs.append({"kind": "bury_check", "node": node, "team": j["team"], "body": body,
			"lf": feet - body.global_position, "at": now + int(COLLAR_TIME * 1000.0) + 10})


func _bury_check(j: Dictionary) -> void:
	var nd = j["node"]
	var b = j["body"]
	if nd == null or not is_instance_valid(nd) or b == null or not is_instance_valid(b):
		return
	var node := nd as Node3D
	var body := b as Node3D
	if not _can_bury(node, str(j["team"])):
		return
	# Where the body stands now (a shove may still be skidding it out of the collar).
	var feet: Vector3 = body.global_position + (j["lf"] as Vector3)
	var up: Vector3 = body.up_at(feet)
	var now_f := feet_of(body, node)
	if now_f == Vector3.INF or now_f.distance_to(feet) > 1.6:
		return
	feet = now_f
	if float(body.density_at(feet + up * CHEST_H)) >= 0.0:
		# Not chest high here (a slope, a skid, a guard near a head): one more push at the hips.
		stamp(body, feet + up * 0.75, 1.1, 2.5)
		if float(body.density_at(feet + up * CHEST_H)) >= 0.0:
			return
	burials += 1
	request_bury(node, feet)


func _can_bury(n: Node3D, team: String) -> bool:
	if not _alive(n) or Game.team_of(n) == team:
		return false
	if n == Game.player:
		return false                                 # (the shooter is never in the jobs; a replay has none)
	if n.has_method("is_down") and bool(n.call("is_down")):
		return false
	if n.has_method("is_ragdolled") and bool(n.call("is_ragdolled")):
		return false
	if n.get("in_vehicle") == true or n.get("vehicle") != null:
		return false
	if n.has_method("is_aboard") and bool(n.call("is_aboard")):
		return false
	var last = _bury_ms.get(n.get_instance_id())
	if last != null and Time.get_ticks_msec() - int(last) < int(BURY_COOLDOWN * 1000.0):
		return false
	return true


# =================================================================================================
# Stamps (RAISE brushes) and the head guard
# =================================================================================================

## One RAISE brush at world `p`, scaled down so that it puts no soil at a character's head. Returns
## the soil placed (m³, positive).
func stamp(body: Node3D, p: Vector3, r: float, a: float) -> float:
	var a2 := head_safe(body, p, r, a, characters())
	if a2 < 0.08:
		return 0.0
	var moved := Dig.dig_at(body, p, r, Dig.MODE_RAISE, a2)
	stamps += 1
	soil_placed += maxf(-moved, 0.0)
	return -moved


## The largest strength (<= a) of a RAISE brush (p, r) that keeps every character's head in the air
## (HEAD_H over its feet; DOWN_H for a body lying down): the brushed density at those points is read
## exactly like planet.gd (trilinear between the 1 m samples it edits), so the guard holds to the voxel.
static func head_safe(body: Node3D, p: Vector3, r: float, a: float, chars: Array) -> float:
	var o: Vector3 = body.global_position
	var lc := p - o
	for n in chars:
		var nd := n as Node3D
		if nd == null or not is_instance_valid(nd):
			continue
		var f := nd.global_position
		if f.distance_to(p) > r + 3.0:
			continue
		var up: Vector3 = body.up_at(f)
		var down: bool = (nd.has_method("is_down") and bool(nd.call("is_down"))) \
				or (nd.has_method("is_ragdolled") and bool(nd.call("is_ragdolled"))) \
				or (nd.has_method("is_dead") and bool(nd.call("is_dead")))
		var hs: Array = DOWN_H if down else (CROUCH_H if _crouched(nd) else HEAD_H)
		for h in hs:
			var l := f + up * float(h) - o
			var b := l.floor()
			var fr := l - b
			var v0 := 0.0
			var w := 0.0
			for ci in 8:
				var cx := ci & 1
				var cy := (ci >> 1) & 1
				var cz := (ci >> 2) & 1
				var corner := b + Vector3(cx, cy, cz)
				var wt := (fr.x if cx == 1 else 1.0 - fr.x) * (fr.y if cy == 1 else 1.0 - fr.y) * (fr.z if cz == 1 else 1.0 - fr.z)
				if wt <= 0.0:
					continue
				var cur := minf(float(body.density_at(o + corner)), 4.0)
				v0 += wt * cur
				var dd := corner.distance_to(lc)
				if dd < r:
					var s := 1.0 - dd / r
					w += wt * s * s * (3.0 - 2.0 * s)
			if w <= 1e-5:
				continue
			# After the brush: v0 - a * w; keep it >= HEAD_MARGIN (already in soil: add none there).
			a = minf(a, maxf((v0 - HEAD_MARGIN) / w, 0.0))
	return a


# =================================================================================================
# Characters
# =================================================================================================

## The astronaut-bodied characters on this machine: the player, rival / ally bots (or their client
## puppets), training dummies, the other player's avatar. Cached per physics frame.
func characters() -> Array:
	var f := Engine.get_physics_frames()
	if f == _chars_frame:
		return _chars
	_chars_frame = f
	_chars = []
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.is_inside_tree() and pl.get("vehicle") == null:
		_chars.append(pl)
	if not is_inside_tree():
		return _chars
	for n in get_tree().get_nodes_in_group(Game.DAMAGEABLE):
		if n == pl or not (n is Node3D) or not is_instance_valid(n):
			continue
		if n.is_in_group("war_structure") or n.is_in_group("war_core"):
			continue
		if n.get("astronaut") == null and not n.is_in_group("net_player"):
			continue
		_chars.append(n)
	return _chars


## Crouching (the player / the other player's avatar: crouch_k; a bot: _crouch_k).
static func _crouched(n: Node) -> bool:
	var c = n.get("crouch_k")
	if c == null:
		c = n.get("_crouch_k")
	return (c is float or c is int) and float(c) > 0.4


static func _alive(n: Node) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	if n.has_method("is_dead"):
		return not bool(n.call("is_dead"))
	return n.get("dead") != true


# =================================================================================================
# Burial (the deciding machine: see the header)
# =================================================================================================

## The owner's burial of `node` (feet: where its collar stands). Host / single player: here (the other
## player's avatar too: CaveIn.bury emits its `buried` event and his machine buries itself; the
## terrain ops are flushed first so his collar arrives before that). Client: a claim to the host
## (net_players.gd "Toprak Topu", terrain flushed first).
static func request_bury(node: Node3D, feet: Vector3) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node != Game.player and Net.is_client():
		if Net.players != null and Net.players.has_method("claim_dirt_bury"):
			Net.players.call("claim_dirt_bury", node, feet)
		return
	if node.is_in_group("net_player") and Net.live() and Net.terrain != null and Net.terrain.has_method("flush"):
		Net.terrain.call("flush")
	execute_bury(node)


## Buries `node` (head free) through cave_in.gd's CaveIn.bury, unless it is already buried, dead or
## was buried by this gun less than BURY_COOLDOWN s ago. True when it was buried.
static func execute_bury(node: Node3D) -> bool:
	if node == null or not is_instance_valid(node) or not _alive(node):
		return false
	var id := node.get_instance_id()
	var now := Time.get_ticks_msec()
	var last = _bury_ms.get(id)
	if last != null and now - int(last) < int(BURY_COOLDOWN * 1000.0):
		return false
	var ci = _cave_in()
	if ci == null:
		return false
	if bool(ci.call("is_buried", node)):
		return false
	ci.call("bury", node, 0.0)
	_bury_ms[id] = now
	return true


static func _cave_in():
	if not ResourceLoader.exists(CAVE_IN_PATH):
		return null
	var s = load(CAVE_IN_PATH)
	if s == null or not (s is GDScript) or not (s as GDScript).can_instantiate():
		return null
	return s


# =================================================================================================
# The look
# =================================================================================================

## The soil colour of the planet under `p` (planet.gd soil_color).
static func soil_at(p: Vector3) -> Color:
	var b: Node3D = Game.dominant_body(p)
	if b != null and b.get("soil_color") is Color:
		return b.get("soil_color")
	return Color(0.45, 0.35, 0.24)


func _build_glob(g: Glob) -> void:
	var r := float(GLOB_R[g.kind])
	g.ball = Node3D.new()
	g.add_child(g.ball)
	var wet := StandardMaterial3D.new()
	wet.albedo_color = g.col.darkened(0.28)
	wet.roughness = 0.62
	var dry := StandardMaterial3D.new()
	dry.albedo_color = g.col.darkened(0.05)
	dry.roughness = 0.95
	# A lumpy ball: a core and a few clumps stuck on it.
	_sphere(g.ball, Vector3.ZERO, r, wet)
	var lumps := [Vector3(0.55, 0.3, 0.1), Vector3(-0.45, 0.2, -0.4), Vector3(0.1, -0.55, 0.35), Vector3(-0.2, 0.5, 0.45)]
	for i in lumps.size():
		var lp: Vector3 = lumps[i]
		_sphere(g.ball, lp * r, r * randf_range(0.42, 0.6), dry if i % 2 == 0 else wet)
	# Clods dribbling off it and a faint dust wisp (world space).
	if _clod_mesh == null:
		_clod_mesh = BoxMesh.new()
		_clod_mesh.size = Vector3.ONE * 0.07
		_clod_mat = StandardMaterial3D.new()
		_clod_mat.vertex_color_use_as_albedo = true
		_clod_mat.roughness = 1.0
		_clod_mesh.material = _clod_mat
		_wisp_mat = StandardMaterial3D.new()
		_wisp_mat.vertex_color_use_as_albedo = true
		_wisp_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_wisp_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_wisp_mat.albedo_texture = DigFx.soft_texture()
		_wisp_mat.roughness = 1.0
	var grav: Vector3 = Game.gravity_at(g.global_position)
	g.clods = _emitter(g, 22 if g.kind == KIND_GLOB else 34, 0.9, grav, false, g.col)
	g.wisp = _emitter(g, 14, 0.7, grav * 0.05, true, g.col)
	# A heavy whoosh leaving the muzzle.
	var st: AudioStream = _streams.get("whoosh/whoosh")
	if st != null:
		g.whoosh = AudioStreamPlayer3D.new()
		g.whoosh.stream = st
		g.whoosh.unit_size = 5.0
		g.whoosh.max_distance = 70.0
		g.whoosh.volume_db = -6.0
		g.whoosh.pitch_scale = 0.62 if g.kind == KIND_GLOB else 0.5
		g.add_child(g.whoosh)
		g.whoosh.play()


static func _sphere(parent: Node3D, pos: Vector3, r: float, m: Material) -> void:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)


func _emitter(g: Glob, amount: int, life: float, grav: Vector3, wisp: bool, col: Color) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.amount = amount
	e.lifetime = life
	e.local_coords = false
	e.randomness = 0.4
	e.visibility_aabb = AABB(Vector3.ONE * -60.0, Vector3.ONE * 120.0)
	e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.2 if wisp else 0.4
	pm.initial_velocity_max = 0.8 if wisp else 1.6
	pm.damping_min = 1.0 if wisp else 0.2
	pm.damping_max = 2.0 if wisp else 0.5
	pm.gravity = grav
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = float(GLOB_R[g.kind]) * 0.8
	pm.angular_velocity_min = -360.0
	pm.angular_velocity_max = 360.0
	var cv := Curve.new()
	cv.max_value = 4.0
	if wisp:
		pm.scale_min = 0.8
		pm.scale_max = 1.4
		cv.add_point(Vector2(0.0, 0.5))
		cv.add_point(Vector2(1.0, 2.2))
	else:
		pm.scale_min = 0.5
		pm.scale_max = 1.5
		cv.add_point(Vector2(0.0, 1.0))
		cv.add_point(Vector2(0.7, 0.9))
		cv.add_point(Vector2(1.0, 0.0))
	var ct := CurveTexture.new()
	ct.curve = cv
	pm.scale_curve = ct
	var gr := Gradient.new()
	if wisp:
		gr.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
		gr.colors = PackedColorArray([Color(col.lightened(0.15), 0.0), Color(col.lightened(0.2), 0.32), Color(col.lightened(0.3), 0.0)])
	else:
		gr.offsets = PackedFloat32Array([0.0, 1.0])
		gr.colors = PackedColorArray([col.darkened(0.2), col.darkened(0.35)])
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	pm.color_ramp = gt
	e.process_material = pm
	if wisp:
		var q := QuadMesh.new()
		q.size = Vector2.ONE * 0.45
		q.material = _wisp_mat
		e.draw_pass_1 = q
	else:
		e.draw_pass_1 = _clod_mesh
	g.add_child(e)
	e.emitting = true
	return e


## The impact's look (every machine): the splat blob, a dust burst, clods and a dirt spray, a thud;
## camera shake for the local player nearby. on_body: it hit a character (smaller dust, no blob).
static func splat_fx(parent: Node3D, p: Vector3, n: Vector3, dir: Vector3, kind: int, col: Color, on_body: bool) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var k := 1.0 if kind == KIND_GLOB else 1.5
	var g: Vector3 = Game.gravity_at(p)
	var out := (n - dir * 0.35).normalized()
	# The wet blob slapping flat on the ground.
	if not on_body:
		var sp := Splat.new()
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 1.0
		sm.radial_segments = 14
		sm.rings = 7
		sp.mesh = sm
		sp.mat = StandardMaterial3D.new()
		sp.mat.albedo_color = col.darkened(0.25)
		sp.mat.roughness = 0.55
		sp.mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sp.material_override = sp.mat
		sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sp.size = 1.4 * k
		parent.add_child(sp)
		sp.global_transform = Transform3D(Rockets._basis_y(n), p + n * 0.05)
		sp.scale = Vector3.ONE * 0.3
	# Dust burst along the ground, a darker spray of wet clumps out of the hit.
	Rockets.puff(parent, p + n * 0.15, n, {"amount": int(18 * k), "life": 1.7, "vmin": 1.5, "vmax": 6.0 * k, "damp": 2.6,
			"spread": 70.0, "size": 0.8 * k, "scale": [0.45, 1.3, 2.6], "radius": 0.25 * k, "explosive": 0.95,
			"gravity": g * 0.04, "ramp": [[0.0, Color(col.lightened(0.1), 0.0)], [0.06, Color(col.lightened(0.12), 0.7)],
				[1.0, Color(col.lightened(0.25), 0.0)]]})
	Rockets.puff(parent, p + n * 0.1, out, {"amount": int(16 * k), "life": 0.85, "vmin": 3.0, "vmax": 8.0 * k, "damp": 0.6,
			"spread": 50.0, "size": 0.2 * k, "scale": [1.0, 1.0, 0.6], "radius": 0.12, "explosive": 0.98, "gravity": g,
			"ramp": [[0.0, Color(col.darkened(0.3), 1.0)], [0.8, Color(col.darkened(0.25), 0.9)], [1.0, Color(col.darkened(0.2), 0.0)]]})
	# Real flying clods that bounce and settle (the Kinetik İtici's pool).
	var pool = KineticPusher.chunks()
	if pool != null:
		pool.tint(col)
		for i in int(5 * k):
			var jit := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.6
			var dv := (out + jit).normalized()
			if dv.dot(n) < 0.2:
				dv = (dv + n * 0.6).normalized()
			pool.spawn(p + n * 0.25 + jit * 0.2, dv * randf_range(3.0, 7.0) * k, randf_range(0.07, 0.16) * k)
	var body: Node3D = Game.dominant_body(p)
	var dbr = body.get("_debris") if body != null else null
	if dbr != null and dbr.has_method("_dirt"):
		dbr._dirt(p, n, int(12 * k), 1.6 * k, col.darkened(0.15))
	# The duvar: the soil bursting up along the wall's footprint (cave_in.gd's entrench berm look).
	if kind == KIND_WALL and not on_body and body != null:
		var upw: Vector3 = body.up_at(p)
		var fl := dir - upw * dir.dot(upw)
		if fl.length_squared() > 1e-4:
			var side := upw.cross(fl.normalized()).normalized()
			for o in [-1.6, 0.0, 1.6]:
				BuildFx.dust(parent, p - fl.normalized() * WALL_BACK + side * float(o), upw, 1.1, col)
	# The thud: wet dirt, a body slap on a character, the ground's weight on a wall.
	var mgr = parent if parent.has_method("_play3d") else null
	if mgr != null:
		mgr._play3d("bimp/dirt_heavy", p, -1.0 if kind == KIND_GLOB else 2.0, randf_range(0.78, 0.9) / sqrt(k))
		if on_body:
			mgr._play3d("melee/dirt", p, -2.0, 0.85)
	if Game.sfx:
		Game.sfx.play_at("melee_dirt", p, -3.0 if kind == KIND_GLOB else 0.0, 0.8 if kind == KIND_GLOB else 0.65, 8.0)
		Game.sfx.play_at("mine", p, -9.0, 0.8, 6.0)
		if kind == KIND_WALL:
			Game.sfx.play_at("land_rock", p, -2.0, 0.85, 9.0)
			Game.sfx.play_at("impact", p, -10.0, 0.6, 8.0)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var dpl: float = (pl as Node3D).global_position.distance_to(p)
		if dpl < SHAKE_R:
			pl.add_trauma(float(SHAKE[kind]) * (1.0 - dpl / SHAKE_R))


func _play3d(name: String, at: Vector3, db: float, pitch: float) -> void:
	var st: AudioStream = _streams.get(name)
	if st == null or _audio.is_empty():
		return
	var p: AudioStreamPlayer3D = _audio[_audio_i]
	_audio_i = (_audio_i + 1) % _audio.size()
	p.stream = st
	p.volume_db = db
	p.pitch_scale = pitch
	p.global_position = at
	p.play()


## Out of time in the air: it falls apart (no terrain).
func _crumble(g: Glob) -> void:
	Rockets.puff(self, g.global_position, -Game.gravity_at(g.global_position).normalized(), {"amount": 12, "life": 1.2,
			"vmin": 0.5, "vmax": 2.5, "damp": 1.5, "spread": 180.0, "size": 0.6, "scale": [0.5, 1.2, 2.0], "radius": 0.2,
			"ramp": [[0.0, Color(g.col, 0.0)], [0.1, Color(g.col.lightened(0.15), 0.5)], [1.0, Color(g.col.lightened(0.25), 0.0)]]})
	_finish(g)


## Stops a glob: hides it, lets its clods fall, frees it later.
func _finish(g: Glob) -> void:
	if g.done:
		return
	g.done = true
	_list.erase(g)
	g.ball.visible = false
	g.clods.emitting = false
	g.wisp.emitting = false
	if g.whoosh != null:
		g.whoosh.stop()
	_dead.append([g, 1.0])
