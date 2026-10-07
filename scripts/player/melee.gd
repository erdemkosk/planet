extends Node
## Dipçik vuruşu (V, on foot only: player.vehicle == null, not ragdolled or dead; V is the skiff's
## chase cam only while piloting). Owned by the view model (viewmodel.melee), which reads
## pose_xf(kind) every frame and applies it to whatever is held.
##   Swing    ~Balance.MELEE_TIME s: long guns turn and lead with the stock (a buttstroke),
##            launchers and the tools jab (scripts/items/handling.gd melee_xf); the camera lunges
##            forward with a dip and the FOV punches in (MELEE_FOV_PUNCH, more on a hit). Wind-up
##            cloth + gear rustle, then a heavy whoosh.
##   Strike   at MELEE_HIT_AT: the nearest living character (anything damageable with an astronaut
##            body, not of our team) inside MELEE_RANGE + MELEE_RADIUS of the eye, close to the view
##            line or within MELEE_CONE_DEG of the crosshair, with a clear line to it, takes
##            Game.damage_target(MELEE_DAMAGE): 2 hits kill a bot; on a multiplayer client it becomes
##            a host claim by itself. A survivor is shoved (MELEE_KNOCKBACK; a bot also gets a
##            fling() stagger), reels (hit_react) and the hit gets HitFeel markers / kill feed
##            ("Dipçik"), suit sparks and vapour and a meaty layered impact. Otherwise a ray / short
##            sphere sweep finds terrain (a dirt thud, dust and clods, a tiny shake) or a structure /
##            vehicle (a clang and sparks); a miss is the whoosh alone.
##   Rules    MELEE_COOLDOWN between swings; not while the hands are busy (grenade, scanner),
##            mid-swap or with empty hands; it interrupts the held item's reload and inspect
##            (item.melee_interrupt()).
## Multiplayer: player.melee_swung(from, dir) fires on every swing (the remote side can replay it).

const Balance := preload("res://scripts/war/balance.gd")
const Handling := preload("res://scripts/items/handling.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")
const RIFLE_PATH := "res://scripts/items/rifle.gd"     # ground_color() (loaded lazily: no preload cycle)

var player
var t := -1.0                      # s into the current swing, -1 idle
var cooldown := 0.0
var kind := "rifle"                # handling kind of the item that swings
var swings := 0                    # tests / stats
var hits := 0

var _hit_done := false
var _weight := 0.5
var _lunge := 0.0
var _cam_off := Vector3.ZERO       # what this node added to camera.position
var _fov_added := 0.0              # what this node added to camera.fov (last write)
var _fov_written := -1.0
var _fov_hit := 0.0
var _sphere: SphereShape3D


func _ready() -> void:
	process_priority = 50          # after the items, which write the camera FOV themselves
	_sphere = SphereShape3D.new()
	_sphere.radius = 0.12


func busy() -> bool:
	return t >= 0.0


## Camera-space swing pose for an item of handling kind `k` (identity when idle).
func pose_xf(k: String) -> Transform3D:
	if t < 0.0:
		return Transform3D()
	return Handling.melee_xf(t / Balance.MELEE_TIME, k)


func _unhandled_input(event: InputEvent) -> void:
	if not InputMap.has_action("melee") or event.is_echo() or not event.is_action_pressed("melee"):
		return
	if swing():
		get_viewport().set_input_as_handled()


## Starts a swing when allowed; true when it started.
func swing() -> bool:
	var p = player
	if p == null or t >= 0.0 or cooldown > 0.0:
		return false
	if p.vehicle != null or p.is_ragdolled() or p.is_dead() or p.get("waiting_ground") == true:
		return false
	if Game.ui_panel_open() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return false
	if p.has_method("hands_busy") and p.hands_busy():
		return false
	var it = p.items[p.current_item] if p.current_item < p.items.size() else null
	if it == null or Handling.kind_of(it) == "none" or not p.viewmodel.is_raised():
		return false
	kind = Handling.kind_of(it)
	_weight = float(Handling.spec(it)["weight"])
	t = 0.0
	_hit_done = false
	cooldown = Balance.MELEE_COOLDOWN
	swings += 1
	if it.has_method("melee_interrupt"):
		it.melee_interrupt()
	var pt := lerpf(1.06, 0.9, _weight)
	_snd("cloth", -15.0, 1.0)
	_snd("gear", -19.0, pt)
	_snd("swing", -6.0 + _weight * 2.0, pt, 0.05)
	var cam: Camera3D = p.camera
	if p.has_signal("melee_swung"):
		p.emit_signal("melee_swung", cam.global_position, -cam.global_transform.basis.z)
	return true


func _process(delta: float) -> void:
	cooldown = maxf(cooldown - delta, 0.0)
	var p = player
	if p == null:
		return
	if t >= 0.0:
		if p.vehicle != null or p.is_ragdolled():
			t = -1.0
		else:
			t += delta
			if not _hit_done and t >= Balance.MELEE_HIT_AT:
				_hit_done = true
				_strike()
			if t >= Balance.MELEE_TIME:
				t = -1.0
	_camera(delta)


## Lunge (camera forward + dip with the strike) and FOV punch, added on top of what the player /
## items set this frame.
func _camera(delta: float) -> void:
	var cam: Camera3D = player.camera
	var target := 0.0
	if t >= 0.0:
		var u := t / Balance.MELEE_TIME
		target = smoothstep(0.15, 0.36, u) * (1.0 - smoothstep(0.5, 1.0, u))
	_lunge = lerpf(_lunge, target, 1.0 - exp(-30.0 * delta))
	if _lunge < 0.001 and target <= 0.0:
		_lunge = 0.0
	var off := Vector3(0.0, -0.025, -0.09) * _lunge
	if off != _cam_off:
		cam.position += off - _cam_off
		_cam_off = off
	_fov_hit = lerpf(_fov_hit, 0.0, 1.0 - exp(-9.0 * delta))
	var add := Balance.MELEE_FOV_PUNCH * _lunge + _fov_hit
	if absf(add) < 0.005 and absf(_fov_added) < 0.005:
		_fov_added = 0.0
		return
	# Items rewrite the FOV every frame: then that is the base; otherwise take ours back out.
	var base := cam.fov - _fov_added if absf(cam.fov - _fov_written) < 0.01 else cam.fov
	cam.fov = base + add
	_fov_written = cam.fov
	_fov_added = add


# =================================================================================================
# The strike
# =================================================================================================

func _strike() -> void:
	var p = player
	var cam: Camera3D = p.camera
	var from: Vector3 = cam.global_position - cam.global_transform.basis * _cam_off
	var dir: Vector3 = -cam.global_transform.basis.z
	var pt := lerpf(1.05, 0.92, _weight)
	var body := _find_target(from, dir)
	if not body.is_empty():
		_hit_body(body["node"], body["point"], from, dir, pt)
		return
	var hit := _sweep(from, dir)
	if hit.is_empty():
		_snd("cloth", -21.0, 1.08)               # follow-through; the whoosh carries the miss
		return
	hits += 1
	var pos: Vector3 = hit["point"]
	var n: Vector3 = hit["normal"]
	var col = hit.get("collider")
	var terrain: bool = col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & Game.LAYER_TERRAIN) != 0
	var fx = _fx()
	if terrain:
		var ground := Color(0.45, 0.38, 0.26)
		var rifle = load(RIFLE_PATH)
		if rifle != null:
			ground = rifle.ground_color(pos, n)
		if fx != null and fx.has_method("_burst"):
			fx._burst("dust", pos, n.lerp(-dir, 0.3).normalized(), ground, 0.9)
			fx._burst("debris", pos, n.lerp(-dir, 0.2).normalized(), ground.darkened(0.25), 0.55)
		_snd("melee_dirt", -5.0, pt)
		_feel(0.1, 0.25)
	else:
		if fx != null and fx.has_method("_burst"):
			fx._burst("sparks", pos, n.lerp(dir.bounce(n), 0.5).normalized(), Color(1.0, 0.8, 0.45), 0.8)
		_snd("melee_metal", -6.0, pt)
		_feel(0.12, 0.3)


func _hit_body(tgt: Node, point: Vector3, from: Vector3, dir: Vector3, pt: float) -> void:
	hits += 1
	var up: Vector3 = (tgt as Node3D).global_transform.basis.y
	var lat := dir - up * dir.dot(up)
	lat = lat.normalized() if lat.length_squared() > 1e-4 else dir
	var dmg := Balance.MELEE_DAMAGE
	var hp0 = tgt.get("hp")
	var lethal: bool = hp0 != null and float(hp0) > 0.0 and float(hp0) <= dmg + 0.001
	var imp := lat * Balance.MELEE_KILL_LAUNCH + up * Balance.MELEE_KILL_LAUNCH * 0.35 if lethal else lat * Balance.MELEE_KNOCKBACK
	var r := Game.damage_target(tgt, dmg, (player as Node3D).global_position, imp, Game.team_of(player), point)
	if r.is_empty():
		r = {"dmg": dmg, "killed": false}
	if not bool(r.get("killed", false)):
		if tgt.has_method("fling") and not Net.is_client():
			tgt.fling(lat * Balance.MELEE_FLING, (player as Node3D).global_position)
		var ast = tgt.get("astronaut")
		if ast != null and ast.has_method("hit_react"):
			ast.hit_react(lat, 1.3, false)
	var fx = _fx()
	if fx != null and fx.has_method("impact_suit"):
		fx.impact_suit(point, (from - point).normalized(), dir, true)
	HitFeel.inst().target_hit(tgt, r, dmg, point, {"big": 0.7, "weapon": "Dipçik"})
	_snd("melee_flesh", -4.0, pt)
	_feel(0.18, 0.5)


## Camera feel of a contact: shake, a short punch against the swing and more FOV punch.
func _feel(trauma: float, fov_k: float) -> void:
	if player.has_method("add_trauma"):
		player.add_trauma(trauma)
	if "_punch" in player:
		player._punch += Vector3(-0.022, randf_range(-0.015, 0.015), 0.018)
	_fov_hit += Balance.MELEE_FOV_PUNCH * fov_k


## The character the strike lands on: {"node", "point"} or {}.
func _find_target(from: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_score := INF
	var cone := cos(deg_to_rad(Balance.MELEE_CONE_DEG))
	var reach := Balance.MELEE_RANGE + Balance.MELEE_RADIUS
	var team := Game.team_of(player)
	for n in get_tree().get_nodes_in_group(Game.DAMAGEABLE):
		if n == player or not (n is Node3D) or n.get("astronaut") == null:
			continue
		if (n.has_method("is_dead") and n.is_dead()) or (n.get("hp") != null and float(n.get("hp")) <= 0.0):
			continue
		if Game.team_of(n) == team:
			continue
		var n3 := n as Node3D
		if n3.global_position.distance_squared_to(from) > (reach + 2.0) * (reach + 2.0):
			continue
		# The closest of a few points up the body (knees to helmet) to the view line.
		var up := n3.global_transform.basis.y
		var c := Vector3.INF
		var off := INF
		for k in 6:
			var q := n3.global_position + up * lerpf(0.45, 1.75, float(k) / 5.0)
			var along := (q - from).dot(dir)
			var o := (q - from - dir * maxf(along, 0.0)).length()
			if o < off:
				off = o
				c = q
		var to := c - from
		var dist := to.length()
		if dist > reach or to.dot(dir) < 0.05:
			continue
		if off > Balance.MELEE_RADIUS + 0.3 and to.normalized().dot(dir) < cone:
			continue
		var score := off + dist * 0.25
		if score >= best_score:
			continue
		# Nothing solid between (no hits through a tunnel wall).
		var rq := PhysicsRayQueryParameters3D.create(from, c, Handling.MASK_WORLD, [player.get_rid()])
		var block := (player as Node3D).get_world_3d().direct_space_state.intersect_ray(rq)
		if not block.is_empty() and from.distance_to(block["position"]) < dist - 0.25:
			continue
		best_score = score
		best = {"node": n, "point": c - dir * 0.15}
	return best


## Terrain / structure / vehicle in front: {"point", "normal", "collider"} or {}.
func _sweep(from: Vector3, dir: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = (player as Node3D).get_world_3d().direct_space_state
	var ex: Array = [player.get_rid()]
	var rq := PhysicsRayQueryParameters3D.create(from, from + dir * Balance.MELEE_RANGE, Handling.MASK_WORLD, ex)
	var hit := space.intersect_ray(rq)
	if not hit.is_empty():
		return {"point": hit["position"], "normal": hit["normal"], "collider": hit["collider"]}
	# A little wider: the stock / tube passes beside the view line.
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _sphere
	q.collision_mask = Handling.MASK_WORLD
	q.exclude = ex
	var start := from + dir * 0.2
	q.transform = Transform3D(Basis(), start)
	q.motion = dir * (Balance.MELEE_RANGE - 0.2)
	var r := space.cast_motion(q)
	if r.size() < 2 or r[1] >= 1.0:
		return {}
	q.transform = Transform3D(Basis(), start + q.motion * r[1])
	q.motion = Vector3.ZERO
	var info := space.get_rest_info(q)
	if info.is_empty():
		return {}
	return {"point": info["point"], "normal": info["normal"], "collider": instance_from_id(int(info["collider_id"]))}


## A RifleFx for impact effects: the held gun's, else any gun's (the drill has none).
func _fx():
	var it = player.items[player.current_item] if player.current_item < player.items.size() else null
	if it != null and it.get("fx") != null and it.fx.has_method("impact_suit"):
		return it.fx
	for o in player.items:
		if o.get("fx") != null and o.fx.has_method("impact_suit"):
			return o.fx
	return null


func _snd(name: String, db: float, pitch: float, delay := 0.0) -> void:
	var s = Game.sfx
	if s == null or not is_instance_valid(s):
		return
	if delay > 0.0 and s.has_method("play_later"):
		s.play_later(name, delay, db, pitch)
	else:
		s.play(name, db, pitch)
