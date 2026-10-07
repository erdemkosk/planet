extends Node3D
## Cesetler: a body left lying where someone died, for Balance.CORPSE_TIME s after its owner respawned
## (2026-10-05 the user: "cesetler belli süre yerde kalmalı"), sinking into the ground over the last
## CORPSE_SINK s. A separate astronaut (scripts/player/astronaut.gd) posed exactly like the dead body,
## bone for bone, so the owner's own astronaut resets for the respawn as before.
##   Corpse.leave(astronaut, ragdoll, team, kind) -> the ragdoll to free, or null
##       Called at the owner's respawn (rival bot ai_rival.gd _tick_dead, training dummy revive, the
##       player's _respawn) before it frees its ragdoll. A ragdoll whose physics still run is taken
##       over: it goes on driving the corpse's astronaut until it comes to rest (the owner's settle
##       callbacks are cut, a follow camera dropped) and null comes back. Otherwise the pose is copied
##       and the ragdoll comes back for the owner to free as before. No ragdoll: no corpse.
## No physics once at rest: the bones stay, the skeleton is synced once, the node only counts down.
## A blast nearby (Game.blast) throws it about as a short ragdoll again (at most CORPSE_RAGDOLL_MAX at
## once, the same launch caps as a fresh corpse); ground dug away under it (brush_applied) lets it drop
## into the hole. Cheap LOD at 2 Hz: the body casts a shadow only within CORPSE_SHADOW_RANGE of the
## camera, small details (lights, decals, props) are gone past DETAIL_RANGE, nothing is drawn past
## CORPSE_VIS_RANGE. At most CORPSE_MAX at once, the oldest goes first; the nodes are pooled (an
## astronaut is costly to build) as children of the current scene.
## Purely visual and local: every machine leaves corpses for the bodies it shows (a multiplayer client
## can call the same leave() for its bot puppets, net_bot.gd, and the other player's avatar,
## remote_avatar.gd, kind "peer"). Corpse.events():
##   corpse_spawned(id, pos, team, kind)    pos = the pelvis; kind "bot" / "dummy" / "player" / "peer"
##   corpse_removed(id)                     sunk (or the oldest made room for a new one)

const Balance := preload("res://scripts/war/balance.gd")
const Astronaut := preload("res://scripts/player/astronaut.gd")
const Ragdoll := preload("res://scripts/player/ragdoll.gd")
const PATH := "res://scripts/war/corpse.gd"

const LOD_PERIOD := 0.5
const DETAIL_RANGE := 45.0             # m: suit lights, decals, props, jet bits
const STILL_V := 0.35                  # m/s at the pelvis (× 1.5 at the chest): at rest...
const STILL_TIME := 0.8                # ...this long: the physics stop
const BLAST_REACH := 1.3               # × a blast's radius: corpses this near are thrown
const BLAST_SHOVE := 9.0               # m/s at the blast centre, falling off to 0 at the reach

## Signals for whoever wants to know (multiplayer, stats); see above.
class CorpseEvents extends RefCounted:
	signal corpse_spawned(id: int, pos: Vector3, team: String, kind: String)
	signal corpse_removed(id: int)

static var _events: CorpseEvents
static var _live: Array = []           # oldest first
static var _pool: Array = []           # hidden, ready to be posed again
static var _next_id := 1

var id := 0
var team := ""
var kind := ""
var astronaut                          # (name read by ragdoll.gd start(): owner.astronaut)
var _rag = null                        # live physics: taken over from the owner, or a blast's throw
var _rag_t := 0.0
var _still := 0.0
var _t := 0.0
var _sink_t := -1.0
var _sink_from := Vector3.ZERO
var _sink_up := Vector3.UP
var _lod_t := 0.0
var _shadow := -1
var _sync := 0                         # frames left to re-sync the skeleton after the physics stopped
var _skin: GeometryInstance3D
var _labels: Array = []


static func events() -> CorpseEvents:
	if _events == null:
		_events = CorpseEvents.new()
	return _events


## See the header. src: the dead body's astronaut.gd (posed by `rag`); returns what the owner frees.
static func leave(src, rag, p_team := "", p_kind := ""):
	if src == null or not is_instance_valid(src) or not (src as Node).is_inside_tree():
		return rag
	if rag == null or not is_instance_valid(rag) or rag.is_queued_for_deletion():
		return rag
	var scene: Node = (src as Node).get_tree().current_scene
	if scene == null:
		return rag
	var c = _take(scene)
	if c == null:
		return rag
	var took: bool = c._setup(src, rag, p_team, p_kind)
	return null if took else rag


## A pooled corpse node (or a new one); the oldest live one is retired when CORPSE_MAX are out.
static func _take(scene: Node):
	_live = _live.filter(func(c): return is_instance_valid(c) and not c.is_queued_for_deletion() and c.is_inside_tree())
	_pool = _pool.filter(func(c): return is_instance_valid(c) and not c.is_queued_for_deletion() \
			and c.is_inside_tree() and c.get_parent() == scene)
	while _live.size() >= maxi(Balance.CORPSE_MAX, 1):
		var old = _live[0]
		old.retire()
		_live.erase(old)
	var c = _pool.pop_back() if not _pool.is_empty() else null
	if c == null:
		c = load(PATH).new()
		scene.add_child(c)
	_live.append(c)
	return c


## Perf pass 2026-10-07: building a corpse node (its own astronaut) costs ~15-20 ms, paid in the frame
## a body is left (an owner's respawn) while the pool is still short. prewarm(n) builds up to `n` pooled
## (hidden) ones ahead, one every PREWARM_GAP s, under the current scene: call it once the world has
## loaded (main.gd, behind the loading cover), so the first corpses of a match cost nothing.
const PREWARM_GAP := 0.25
static var _prewarming := false


static func prewarm(n := 3) -> void:
	if _prewarming:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_prewarming = true
	var scene: Node = tree.current_scene
	while scene != null and is_instance_valid(scene) and scene.is_inside_tree():
		_pool = _pool.filter(func(c): return is_instance_valid(c) and not c.is_queued_for_deletion() \
				and c.is_inside_tree() and c.get_parent() == scene)
		if _pool.size() + _live.size() >= mini(n, maxi(Balance.CORPSE_MAX, 1)):
			break
		var c = load(PATH).new()
		scene.add_child(c)                 # (_ready: id 0, hidden, no processing)
		_pool.append(c)
		await tree.create_timer(PREWARM_GAP, false).timeout
		if tree.current_scene != scene:
			break
	_prewarming = false


static func _live_rags() -> int:
	var n := 0
	for c in _live:
		if is_instance_valid(c) and c._rag != null:
			n += 1
	return n


func _ready() -> void:
	process_priority = 110                 # after the ragdoll moved the bones (astronaut.gd syncs at 100)
	astronaut = Astronaut.new()
	add_child(astronaut)
	astronaut.set_first_person(false)
	astronaut.set_process(false)           # synced here, only when the pose changes
	astronaut.set_held("")                 # empty, open hands
	for n in astronaut.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if gi is MeshInstance3D and (gi as MeshInstance3D).skin != null:
			_skin = gi
			gi.visibility_range_end = Balance.CORPSE_VIS_RANGE
			continue
		gi.visibility_range_end = DETAIL_RANGE
		gi.visibility_range_end_margin = 5.0
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if gi is Label3D:
			_labels.append(gi)
	Game.blast.connect(_on_blast)
	for pl in [Game.planet, Game.rival]:
		if pl != null and is_instance_valid(pl) and (pl as Object).has_signal("brush_applied"):
			pl.brush_applied.connect(_on_ground_edit)
	if id == 0:                            # (built for the pool before any _setup)
		visible = false
		set_process(false)
		set_physics_process(false)


func _exit_tree() -> void:
	if _rag != null and is_instance_valid(_rag) and not _rag.is_queued_for_deletion():
		_rag.queue_free()
	_rag = null
	_live.erase(self)
	_pool.erase(self)


## Poses this corpse like `src` (and takes over `rag` while its physics run). True: rag taken.
func _setup(src, rag, p_team: String, p_kind: String) -> bool:
	id = _next_id
	_next_id += 1
	team = p_team
	kind = p_kind
	_t = 0.0
	_sink_t = -1.0
	_lod_t = 0.0
	_shadow = -1
	_still = 0.0
	_rag_t = 0.0
	visible = true
	var pel: Vector3 = src.hips.global_position
	global_transform = Transform3D(_frame(_up_at(pel)), pel)
	astronaut.global_transform = (src as Node3D).global_transform
	_copy_pose(src)
	if src.get("team_palette") != null:      # the dead body's friend / enemy suit, no distance rim
		astronaut.set_team_palette(int(src.team_palette), false)
	_center()
	var tag := _tag_of(src)
	if tag != "":
		for l in _labels:
			(l as Label3D).text = tag
	var took := false
	_rag = null
	var bodies = rag.get("bodies")
	if bodies is Dictionary and not (bodies as Dictionary).is_empty():
		_adopt(rag)
		took = true
	astronaut.sync_skeleton()
	_sync = 1
	set_process(true)
	set_physics_process(_rag != null)
	_lod(true)
	events().corpse_spawned.emit(id, pel, team, kind)
	return took


## Back to the pool (sunk, or the oldest when a new one needs the room).
func retire() -> void:
	if _rag != null and is_instance_valid(_rag) and not _rag.is_queued_for_deletion():
		_rag.queue_free()
	_rag = null
	visible = false
	set_process(false)
	set_physics_process(false)
	_live.erase(self)
	if not _pool.has(self):
		_pool.append(self)
	if id != 0:
		events().corpse_removed.emit(id)


func _copy_pose(src) -> void:
	var a = astronaut
	var pairs := [[a.hips, src.hips], [a.spine, src.spine], [a.chest, src.chest], [a.head, src.head]]
	for i in 2:
		pairs.append_array([[a.thigh[i], src.thigh[i]], [a.shin[i], src.shin[i]], [a.foot[i], src.foot[i]],
				[a.shoulder[i], src.shoulder[i]], [a.elbow[i], src.elbow[i]], [a.hand[i], src.hand[i]]])
	for p in pairs:
		(p[0] as Node3D).transform = (p[1] as Node3D).transform


## The chest name tag of the dead ("RAKİP", "HEDEF", "KAŞİF").
static func _tag_of(src) -> String:
	var ls: Array = (src as Node).find_children("*", "Label3D", true, false)
	return (ls[0] as Label3D).text if not ls.is_empty() else ""


## The owner's ragdoll goes on driving OUR astronaut: its bone map is rebuilt from our bones by part
## name (ragdoll.gd _parts), the owner's `finished` callbacks are cut (a bot's would freeze a newer
## ragdoll of its own), a follow camera (the player's) is dropped.
func _adopt(rag) -> void:
	var sig: Signal = rag.finished
	for c in sig.get_connections():
		sig.disconnect(c["callable"])
	var cam = rag.get("cam")
	if cam != null and is_instance_valid(cam):
		(cam as Node).queue_free()
	rag.set("cam", null)
	rag.set("astronaut", astronaut)
	rag.set("player", self)
	var bone_of = rag.get("_bone_of")
	if bone_of is Dictionary:
		for d in rag._parts():
			(bone_of as Dictionary)[d[0]] = d[1]
	rag.set("_fixed", [astronaut.spine] + astronaut.hand + astronaut.foot)
	_rag = rag
	_rag_t = 0.0
	_still = 0.0


func _physics_process(delta: float) -> void:
	if _rag == null:
		set_physics_process(false)
		return
	if not is_instance_valid(_rag) or _rag.is_queued_for_deletion() or (_rag.bodies as Dictionary).is_empty():
		_freeze()                          # (a bot team's ragdoll cap may stop it first)
		return
	_rag_t += delta
	var pv: float = (_rag.bodies["pelvis"] as RigidBody3D).linear_velocity.length()
	var cv: float = (_rag.bodies["chest"] as RigidBody3D).linear_velocity.length()
	if pv < STILL_V and cv < STILL_V * 1.5:
		_still += delta
	else:
		_still = maxf(_still - delta * 0.5, 0.0)
	if (_still > STILL_TIME and _rag_t > 0.4) or _rag_t > Balance.CORPSE_SETTLE_MAX:
		_freeze()


## At rest: the physics go, the pose stays; the node moves to the pelvis (the sink, the LOD).
func _freeze() -> void:
	if _rag != null and is_instance_valid(_rag) and not _rag.is_queued_for_deletion():
		_rag.set_process(false)            # (no last drive of the bones this frame)
		_rag.set_physics_process(false)
		_rag.queue_free()
	_rag = null
	set_physics_process(false)
	_center()
	astronaut.sync_skeleton()
	_sync = 2


## Node and astronaut origin onto the pelvis, the pose kept (hips is the only root bone): the sink
## and the LOD measure from the body, and the skinned mesh's culling box (astronaut.gd custom_aabb,
## ±2.4 m around the astronaut origin) holds it however far the body was thrown from where it died.
func _center() -> void:
	var hg: Transform3D = astronaut.hips.global_transform
	global_transform = Transform3D(_frame(_up_at(hg.origin)), hg.origin)
	astronaut.transform = Transform3D.IDENTITY
	astronaut.hips.global_transform = hg


func _process(delta: float) -> void:
	_t += delta
	if _rag != null or _sync > 0:
		_sync = maxi(_sync - 1, 0)
		astronaut.sync_skeleton()
	if _sink_t < 0.0 and _t >= Balance.CORPSE_TIME - Balance.CORPSE_SINK:
		_begin_sink()
	if _sink_t >= 0.0:
		_sink_t += delta
		var k := clampf(_sink_t / maxf(Balance.CORPSE_SINK, 0.1), 0.0, 1.0)
		k = k * k * (3.0 - 2.0 * k)
		global_position = _sink_from - _sink_up * Balance.CORPSE_SINK_DEPTH * k
		if _sink_t >= Balance.CORPSE_SINK:
			retire()
		return
	_lod_t -= delta
	if _lod_t <= 0.0:
		_lod_t = LOD_PERIOD
		_lod(false)


func _begin_sink() -> void:
	if _rag != null:
		_freeze()
	_sink_t = 0.0
	_sink_from = global_position
	_sink_up = _up_at(global_position)
	if _skin != null:                      # (a shadow of a body half in the ground looks wrong)
		_skin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_shadow = 0


## 2 Hz: the body's shadow only near the camera.
func _lod(force: bool) -> void:
	if _skin == null or _sink_t >= 0.0:
		return
	var cam := get_viewport().get_camera_3d()
	var d := cam.global_position.distance_to(global_position) if cam != null else 0.0
	var want := 1 if d < Balance.CORPSE_SHADOW_RANGE else 0
	if want != _shadow or force:
		_shadow = want
		_skin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if want == 1 \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# =================================================================================================
# Thrown about again (blasts, ground dug away under it)
# =================================================================================================

func _on_blast(pos: Vector3, radius: float, _team: String) -> void:
	if not visible or id == 0 or _sink_t >= 0.0 or radius <= 0.0:
		return
	var c: Vector3 = astronaut.hips.global_position
	var reach := radius * BLAST_REACH
	var d := c.distance_to(pos)
	if d > reach:
		return
	var up := _up_at(c)
	var dir := (c - pos).normalized() if d > 0.05 else up
	var v := dir * BLAST_SHOVE * (1.0 - d / reach)
	# The caps of a fresh corpse (hit_reactor.gd _cap_v): a few metres with a hop, never into space.
	var vu := clampf(v.dot(up), 0.8, Balance.HR_CORPSE_UP_MAX)
	v = (v - up * v.dot(up)).limit_length(Balance.HR_CORPSE_MAX) + up * vu
	if v.length() < 1.0:
		return
	call_deferred("_shove", v)             # (blasts may come from inside a physics query)


func _on_ground_edit(center: Vector3, radius: float) -> void:
	if not visible or id == 0 or _sink_t >= 0.0 or _rag != null:
		return
	var c: Vector3 = astronaut.hips.global_position
	if c.distance_to(center) > radius + 1.5:
		return
	var body: Node3D = Game.dominant_body(c)
	if body == null or not body.has_method("density_at"):
		return
	var up := _up_at(c)
	if float(body.density_at(c - up * 0.45)) < 0.0:
		return                             # still lying on solid ground (the exact density)
	if _live_rags() < Balance.CORPSE_RAGDOLL_MAX:
		call_deferred("_shove", -up * 0.5)
		return
	# No physics slot: lower it onto the new ground as it lies.
	var h: Dictionary = body.raycast_density(c + up * 0.5, c - up * 8.0, 0.3, false)
	if not h.is_empty():
		global_position -= up * maxf((c - (h["position"] as Vector3)).dot(up) - 0.15, 0.0)


## A short ragdoll from the pose it lies in (or a kick to the one still running).
func _shove(v: Vector3) -> void:
	if not visible or _sink_t >= 0.0:
		return
	if _rag != null and is_instance_valid(_rag) and not (_rag.bodies as Dictionary).is_empty():
		for b in (_rag.bodies as Dictionary).values():
			(b as RigidBody3D).linear_velocity += v
		_still = 0.0
		_rag_t = minf(_rag_t, 1.0)
		return
	if _live_rags() >= Balance.CORPSE_RAGDOLL_MAX or get_parent() == null:
		return
	var r = Ragdoll.new()
	get_parent().add_child(r)
	r.no_float_recover = true
	r.start(self, v, 60.0, [], false)
	_rag = r
	_rag_t = 0.0
	_still = 0.0
	set_physics_process(true)


# =================================================================================================
# Helpers
# =================================================================================================

## "Up" at p: away from the centre of the world under it.
static func _up_at(p: Vector3) -> Vector3:
	var b: Node3D = Game.dominant_body(p)
	if b != null and is_instance_valid(b):
		var r := p - b.global_position
		if r.length_squared() > 1e-4:
			return r.normalized()
	return Vector3.UP


static func _frame(up: Vector3) -> Basis:
	var x := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	return Basis(x, up, x.cross(up))
