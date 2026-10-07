extends Node3D
## A target of the Eğitim Alanı (scripts/training/training.gd): an astronaut body
## (scripts/player/astronaut.gd, so head shots, hit reactions, hit markers, damage numbers and the
## kill feed work exactly as on a rival bot) that takes every weapon and never fights back.
##   kind  KIND_STD      Balance.AI_HP, the same as a rival bot
##         KIND_ARMOR    ×3 hp
##         KIND_IMMORTAL never dies (a DPS meter): the hp bar drops, stops at 1 and refills
##                       IMMORTAL_REFILL s after the last hit
##   move  MOVE_STILL · MOVE_STRAFE (side steps across its post) · MOVE_CIRCLE (walks a ring round
##         its post) · MOVE_RUN (sprints a wider ring) · MOVE_HOP (side steps with jet hops)
## It faces the player when near, stands on the real (dug / blasted) ground and drops into a crater
## blown under it. Killed: a ragdoll (the pusher's shock wave shoves its limbs), back on its post
## after RESPAWN s. A fling (scripts/items/kinetic_pusher.gd) of Balance.AI_FLING_KO or more sends
## it flying as a ragdoll, even when immortal; a weaker one slides it and it walks back.
## Groups "damageable" + "war_ai" (the scanner's x-ray, the pusher's ragdoll shove; the collider's
## "ai_bot" meta gives the war HUD name tag) + "training_dummy". Team "rival".
##   place(body, point, face_to)   put it on a planet (call after add_child)
##   set_kind(k) / set_move(m)
##   take_damage(amount, from_pos, impulse) -> {"dmg", "killed"}
##   fling(v, from_pos)   is_dead()   revive()   status()

const Balance := preload("res://scripts/war/balance.gd")
const Astronaut := preload("res://scripts/player/astronaut.gd")
const Ragdoll := preload("res://scripts/player/ragdoll.gd")

const GROUP := "training_dummy"
enum { KIND_STD, KIND_ARMOR, KIND_IMMORTAL }
enum { MOVE_STILL, MOVE_STRAFE, MOVE_CIRCLE, MOVE_RUN, MOVE_HOP }
const KIND_NAMES := ["Standart", "Zırhlı", "Ölümsüz"]
const MOVE_NAMES := ["Sabit", "Yan adım", "Daire", "Koşu", "Zıplama"]
const KIND_COLORS := [Color(1.0, 0.6, 0.2), Color(0.45, 0.72, 1.0), Color(0.82, 0.5, 1.0)]
const KIND_HP_STD := Balance.AI_HP
const ARMOR_K := 3.0
const IMMORTAL_HP := 1000.0
const IMMORTAL_REFILL := 2.5           # s after the last hit
const RESPAWN := 3.0                   # s on the ground before it stands on its post again
const STRAFE_W := 3.5                  # m each side of the post
const STRAFE_SPEED := 3.8              # m/s peak (a rival bot strafes ~3.5-4)
const CIRCLE_R := 3.5
const CIRCLE_SPEED := Balance.AI_WALK_SPEED
const RUN_R := 6.0
const RUN_SPEED := Balance.AI_RUN_SPEED
const HOP_PERIOD := 1.6                # s: a hop (HOP_AIR of it in the air), then a step
const HOP_AIR := 0.9
const HOP_H := 1.4                     # m apex
const FACE_RANGE := 90.0               # m: nearer than this it turns toward the player
const NEAR_POSE := 45.0                # m from the camera: posed every frame (else ~10 Hz)
const LABEL_RANGE := 60.0

var trainer                            # training.gd (stats), may be null
var body: Node3D                       # the planet it stands on
var kind := KIND_STD
var move := MOVE_STILL
var team := "rival"
var callsign := "Hedef"
var hp := Balance.AI_HP
var hp_max := Balance.AI_HP
var astronaut
var dead := false

var _ragdoll = null                    # (name read by the kinetic pusher's ragdoll shove)
var _dead_t := 0.0
var _anchor := Vector3.ZERO            # its post on the ground (world)
var _facing := Vector3.FORWARD         # the way it faces at its post (tangent)
var _t := 0.0                          # movement clock
var _knock := Vector3.ZERO             # slide offset from a weak fling / hit (tangent, m)
var _knock_v := Vector3.ZERO
var _r_shown := -1.0                   # shown distance of the feet from the planet centre
var _r_goal := -1.0
var _probe_acc := 99.0
var _probe_dir := Vector3.ZERO
var _foot := Vector3.ZERO
var _prev_foot := Vector3.INF
var _vel := Vector3.ZERO
var _air := false
var _pose_acc := 0.0
var _label_acc := 0.0
var _hit_ms := -100000
var _first_hit_ms := -1
var _col: StaticBody3D
var _cap_cs: CollisionShape3D
var _label: Label3D
var _halo: MeshInstance3D
var _halo_mat: StandardMaterial3D


func _ready() -> void:
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_ai")
	add_to_group(GROUP)
	astronaut = Astronaut.new()
	add_child(astronaut)
	astronaut.set_first_person(false)
	astronaut.set_process(false)          # posed here, at its own rate
	for n in astronaut.find_children("*", "Label3D", true, false):
		(n as Label3D).text = "HEDEF"
	_col = StaticBody3D.new()
	_col.collision_layer = Game.LAYER_PLAYER
	_col.collision_mask = 0
	_col.set_meta("ai_bot", self)
	_cap_cs = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	_cap_cs.shape = cap
	_cap_cs.position = Vector3(0, 0.9, 0)
	_col.add_child(_cap_cs)
	add_child(_col)
	# A glowing ring above the head in the kind's colour, and the name / hp / range plate.
	_halo_mat = StandardMaterial3D.new()
	_halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_halo = MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.2
	tor.outer_radius = 0.24
	tor.rings = 24
	tor.ring_segments = 6
	_halo.mesh = tor
	_halo.material_override = _halo_mat
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.position = Vector3(0, 2.12, 0)
	add_child(_halo)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Same small size on screen at any range (it used to grow huge up close and pile up); the name
	# and an hp bar show in the war HUD when aimed at (collider meta "ai_bot").
	_label.fixed_size = true
	_label.font_size = 28
	_label.pixel_size = 0.0011
	_label.outline_size = 8
	_label.outline_modulate = Color(0, 0, 0, 0.75)
	_label.position = Vector3(0, 2.5, 0)
	_label.visibility_range_end = LABEL_RANGE
	_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_label)
	_apply_kind()
	astronaut.animate(0.016, {"speed": 0.0, "grounded": true, "probe": false})
	astronaut.sync_skeleton()


func _exit_tree() -> void:
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null


## Puts it on `p_body` at `point` (on or near the ground), facing `face_to` (world).
func place(p_body: Node3D, point: Vector3, face_to: Vector3) -> void:
	body = p_body
	var up: Vector3 = body.up_at(point)
	_anchor = _ground_at(point)
	var f := face_to - _anchor
	f -= up * f.dot(up)
	if f.length_squared() < 1e-4:
		f = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	_facing = f.normalized()
	_r_goal = (_anchor - body.global_position).length()
	_r_shown = _r_goal
	_probe_acc = 0.0
	_probe_dir = (_anchor - body.global_position).normalized()
	_t = 0.0
	_knock = Vector3.ZERO
	_knock_v = Vector3.ZERO
	_prev_foot = Vector3.INF
	_update_body(0.0)


func set_kind(k: int) -> void:
	kind = clampi(k, 0, KIND_NAMES.size() - 1)
	if is_inside_tree():
		_apply_kind()


func set_move(m: int) -> void:
	move = clampi(m, 0, MOVE_NAMES.size() - 1)
	_t = 0.0


func _apply_kind() -> void:
	match kind:
		KIND_ARMOR:
			hp_max = Balance.AI_HP * ARMOR_K
		KIND_IMMORTAL:
			hp_max = IMMORTAL_HP
		_:
			hp_max = Balance.AI_HP
	hp = hp_max
	_first_hit_ms = -1
	var c: Color = KIND_COLORS[kind]
	_halo_mat.albedo_color = c
	_label.modulate = c.lightened(0.35)
	_refresh_label()


func is_dead() -> bool:
	return dead


func status() -> String:
	return "%s · %s · %s · %s" % [callsign, KIND_NAMES[kind], MOVE_NAMES[move],
			"yerde" if dead else "%d/%d can" % [int(ceilf(hp)), int(hp_max)]]


# =================================================================================================
# Hits
# =================================================================================================

func take_damage(amount: float, from_pos := Vector3.ZERO, impulse := Vector3.ZERO) -> Dictionary:
	if dead:
		_hr_dead_hit(impulse)                # the rest of a killing blast still throws it (end of file)
	if dead or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	var now := Time.get_ticks_msec()
	if _first_hit_ms < 0 or hp >= hp_max - 0.01:
		_first_hit_ms = now
	_hit_ms = now
	var killed := false
	if kind == KIND_IMMORTAL:
		hp = maxf(hp - amount, 1.0)
	else:
		hp = maxf(hp - amount, 0.0)
		killed = hp <= 0.0
	var ttk := float(now - _first_hit_ms) / 1000.0 if killed else -1.0
	if trainer != null and is_instance_valid(trainer):
		trainer.on_dummy_hit(self, amount, killed, ttk)
	_hr_get().on_hit(amount, from_pos, impulse)   # hit reactions: skid / stagger / knockdown (end of file)
	if killed:
		_die(impulse)
	_refresh_label()
	return {"dmg": amount, "killed": killed}


## The Kinetik İtici's shove (velocity v, m/s). Hard enough: off it flies as a ragdoll (also when
## immortal; not a kill). Weaker: it slides, then walks back to its post.
func fling(v: Vector3, _from_pos := Vector3.ZERO) -> void:
	if dead:
		return
	var speed := v.length()
	if trainer != null and is_instance_valid(trainer):
		trainer.on_dummy_flung(self, speed)
	if speed >= Balance.AI_FLING_KO:
		_die(v)
		return
	_hr_get().on_push(v, _from_pos)          # skid / stagger / knockdown by speed (end of file)


func _die(impulse: Vector3) -> void:
	if dead:
		return
	dead = true
	_dead_t = 0.0
	_cap_cs.set_deferred("disabled", true)
	_label.visible = false
	_halo.visible = false
	if kind != KIND_IMMORTAL:                # loot: a killable dummy drops a little material (scripts/war/loot.gd)
		preload("res://scripts/war/loot.gd").drop(global_position + _up(), Balance.LOOT_DUMMY, _up() * 2.2)
	if not _hr_keep_ragdoll(impulse):        # hit reactions: a knocked-down body goes on as the corpse
		_ragdoll = Ragdoll.new()
		get_parent().add_child(_ragdoll)
		_ragdoll.no_float_recover = true
		_ragdoll.start(self, _hr_launch(_vel + impulse), 60.0, [], false)


## Back on its post, full hp.
func revive() -> void:
	if dead and kind != KIND_IMMORTAL:       # corpses: the body stays where it fell (scripts/war/corpse.gd)
		_ragdoll = preload("res://scripts/war/corpse.gd").leave(astronaut, _ragdoll, team, "dummy")
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null
	if _reactor != null:
		_reactor.reset()                     # (hit reactions)
	dead = false
	_dead_t = 0.0
	hp = hp_max
	_first_hit_ms = -1
	_knock = Vector3.ZERO
	_knock_v = Vector3.ZERO
	_air = false
	astronaut.transform = Transform3D.IDENTITY
	astronaut.reset_pose()
	_cap_cs.set_deferred("disabled", false)
	_label.visible = true
	_halo.visible = true
	_probe_acc = 99.0
	_prev_foot = Vector3.INF
	if body != null and is_instance_valid(body):
		_update_body(0.0)
	astronaut.animate(0.016, {"speed": 0.0, "grounded": true, "probe": false})
	astronaut.sync_skeleton()
	_refresh_label()


# =================================================================================================
# Movement and pose
# =================================================================================================

func _process(delta: float) -> void:
	if body == null or not is_instance_valid(body):
		return
	if dead:
		_dead_t += delta
		if _ragdoll != null and is_instance_valid(_ragdoll) and not (_ragdoll.bodies as Dictionary).is_empty():
			astronaut.sync_skeleton()
		if _dead_t >= RESPAWN:
			revive()
		return
	if kind == KIND_IMMORTAL and hp < hp_max and Time.get_ticks_msec() - _hit_ms > int(IMMORTAL_REFILL * 1000.0):
		hp = hp_max
		_first_hit_ms = -1
		_refresh_label()
	if _hr_tick(delta):                      # hit reactions: knocked down / getting up (end of file)
		return
	_t += 0.0 if _hr_busy() else delta       # (the pattern waits while it reels)
	if not preload("res://scripts/war/cave_in.gd").is_buried(self):   # (buried by a cave-in: held in the soil)
		_update_body(delta)
	var cam := get_viewport().get_camera_3d()
	var cam_d := cam.global_position.distance_to(global_position) if cam != null else 0.0
	_pose_acc += delta
	var recently_hit := Time.get_ticks_msec() - _hit_ms < 1200
	var rate := 0.0 if cam_d < NEAR_POSE and (move != MOVE_STILL or recently_hit) else 0.1
	if _pose_acc >= rate:
		var dt := _pose_acc
		_pose_acc = 0.0
		var b := global_transform.basis
		var up := b.y
		var hv := _vel - up * _vel.dot(up)
		astronaut.animate(minf(dt, 0.5), {"vel_local": b.inverse() * hv, "vel_up": _vel.dot(up), "speed": hv.length(),
				"grounded": not _air, "jetting": _air and move == MOVE_HOP, "jet_power": 0.8, "zero_g": false,
				"holding": false, "probe": false})
		astronaut.sync_skeleton()
	_label_acc += delta
	if _label_acc >= 0.15:
		_label_acc = 0.0
		_refresh_label(cam_d)


## Moves the body along its pattern, on the ground, turned toward the player.
func _update_body(delta: float) -> void:
	var c: Vector3 = body.global_position
	var up0: Vector3 = body.up_at(_anchor)
	var fwd0 := _facing
	var right0 := fwd0.cross(up0).normalized()
	var off := Vector3.ZERO
	var lift := 0.0
	_air = false
	match move:
		MOVE_STRAFE:
			off = right0 * sin(_t * STRAFE_SPEED / STRAFE_W) * STRAFE_W
		MOVE_CIRCLE:
			var a := _t * CIRCLE_SPEED / CIRCLE_R
			off = (right0 * cos(a) + fwd0 * sin(a)) * CIRCLE_R
		MOVE_RUN:
			var a2 := _t * RUN_SPEED / RUN_R
			off = (right0 * cos(a2) + fwd0 * sin(a2)) * RUN_R
		MOVE_HOP:
			off = right0 * sin(_t * STRAFE_SPEED * 0.8 / STRAFE_W) * STRAFE_W
			var ph := fmod(_t, HOP_PERIOD)
			if ph < HOP_AIR:
				var k := ph / HOP_AIR
				lift = HOP_H * 4.0 * k * (1.0 - k)
				_air = k > 0.04 and k < 0.96
	lift += _hr_lift()                       # hit reactions: a stagger's hop (end of file)
	_air = _air or _hr_lift() > 0.0
	# A weak fling / hit slides it; then it walks back to its post.
	if delta > 0.0:
		_knock += _knock_v * delta
		_knock_v *= exp(-3.5 * delta)
		if _knock_v.length() < 0.4:
			_knock = _knock.move_toward(Vector3.ZERO, Balance.AI_WALK_SPEED * delta)
	var p := _anchor + off + _knock
	var dir := (p - c).normalized()
	# The ground under it: probed now and then (often while moving), the height eased in between.
	_probe_acc += delta
	var probe_rate := 1.0 / 12.0 if (move != MOVE_STILL or _knock.length_squared() > 0.01) else 0.4
	if _probe_acc >= probe_rate or _r_goal < 0.0:
		_probe_acc = 0.0
		var g := _ground_at(c + dir * maxf(_r_goal, float(body.radius)))
		_r_goal = (g - c).length()
		_probe_dir = dir
	if _r_shown < 0.0 or delta <= 0.0:
		_r_shown = _r_goal
	else:
		_r_shown = lerpf(_r_shown, _r_goal, 1.0 - exp(-10.0 * delta))
	var foot := c + dir * _r_shown
	var up := dir
	var shown := foot + up * lift
	# Facing: toward the player when near (on the same planet), else its post's direction.
	var f := fwd0
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and (pl as Node3D).global_position.distance_to(shown) < FACE_RANGE:
		var to: Vector3 = (pl as Node3D).global_position - shown
		to -= up * to.dot(up)
		if to.length_squared() > 0.04:
			f = to.normalized()
	f -= up * f.dot(up)
	if f.length_squared() < 1e-4:
		f = fwd0
	var z := -f.normalized()
	var x := up.cross(z).normalized()
	global_transform = Transform3D(Basis(x, up, x.cross(up)), shown)
	if delta > 0.0 and _prev_foot != Vector3.INF and _prev_foot.distance_to(shown) < 5.0:
		_vel = _vel.lerp((shown - _prev_foot) / delta, 1.0 - exp(-12.0 * delta))
	else:
		_vel = Vector3.ZERO
	_prev_foot = shown
	_foot = foot


func _up() -> Vector3:
	if body != null and is_instance_valid(body):
		return body.up_at(global_position)
	return global_transform.basis.y


## The (edited) ground under / over p, along the planet's up. The ground the player SEES first: a
## physics ray against the terrain collision (built near the camera, where dummies are shot at); else
## the exact density. (The fast density march skips the ±1.3 m detail noise: dummies stood up to
## 1.3 m above the real ground in every dip, "havadalar".)
func _ground_at(p: Vector3) -> Vector3:
	var up: Vector3 = body.up_at(p)
	if is_inside_tree():
		var q := PhysicsRayQueryParameters3D.create(p + up * 4.0, p - up * 6.0, Game.LAYER_TERRAIN)
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			return hit["position"]
	var h: Dictionary = body.raycast_density(p + up * 4.0, p - up * 6.0, 0.3, false)
	if h.is_empty():
		h = body.raycast_density(p + up * 4.0, p - up * 45.0, 1.0, false)
	if h.is_empty():
		return p
	return h["position"]


func _refresh_label(cam_d := -1.0) -> void:
	if _label == null:
		return
	var hp_s := "%d / %d" % [int(ceilf(hp)), int(hp_max)]
	var d_s := ""
	if cam_d < 0.0:
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		cam_d = cam.global_position.distance_to(global_position) if cam != null else -1.0
	if cam_d >= 0.0:
		d_s = "  ·  %d m" % int(roundf(cam_d))
	var kind_s := "" if kind == KIND_STD else "%s  " % KIND_NAMES[kind]
	_label.text = "%s%s%s" % [kind_s, hp_s, d_s]


# =================================================================================================
# Hit reactions (scripts/player/hit_reactor.gd; tunables: balance.gd "Hit reactions")
# =================================================================================================
# The same reactions as a rival bot, so they can be tried here: flinch springs at the struck bones and
# a skid back, a stagger (a shove with a little hop the reactor flies itself: own_air, a skid with
# ground friction, the walk cycle stumbling), a knockdown ragdoll and the get-up where it lies (then it
# walks back to its post). Immortal dummies floor at 1 hp, so they go down again and again.
# Hooks above: take_damage -> on_hit (alive; the hit point from Game.hit_pos; the trainer's stats call
# stays) and _hr_dead_hit (dead: the rest of a killing blast); fling() below AI_FLING_KO -> on_push;
# _die -> _hr_keep_ragdoll / _hr_launch; revive -> reset; _process -> _hr_tick (true while down: the
# rest waits; the pattern clock _t stops while it reels); _update_body -> _hr_lift (the hop).
# The skid rides on _knock_v (written while the reactor's shove lasts); the knockdown ragdoll is
# `_ragdoll` (the pusher's limb shove, revive and _exit_tree free it); the capsule lies along the body
# while down; the label and the halo hide meanwhile. gun_feel's hit_react after the damage is routed
# into the reactor by astronaut.gd (no double flinch).

const HitReactor := preload("res://scripts/player/hit_reactor.gd")

var _reactor = null
var _hr_off := Vector3.ZERO            # the pattern offset when it went down (to stand up where it lies)


func is_staggered() -> bool:
	return _reactor != null and _reactor.is_staggered()


func is_down() -> bool:
	return _reactor != null and _reactor.is_down()


func _hr_busy() -> bool:
	return _reactor != null and _reactor.busy()


func _hr_get():
	if _reactor == null:
		_reactor = HitReactor.new()
		_reactor.setup(self, astronaut, _cap_cs)
		_reactor.own_air = true
		_reactor.face_hint = _hr_face
		_reactor.went_down.connect(_hr_on_down)
		_reactor.getup_started.connect(_hr_on_getup)
		_reactor.recovered.connect(_hr_on_up)
	return _reactor


func _hr_dead_hit(impulse: Vector3) -> void:
	if _reactor != null:
		_reactor.on_dead_hit(impulse)


## _process: the reactor's tick and the skid into _knock_v; true while down (get-up, capsule).
func _hr_tick(delta: float) -> bool:
	if _reactor == null:
		return false
	_reactor.tick(delta)
	if _reactor.is_down():
		_reactor.process(delta)
		return true
	var kb: Vector3 = _reactor.kb_velocity()
	if kb.length_squared() > 0.0025:
		_knock_v = kb
	return false


func _hr_lift() -> float:
	return _reactor.lift_height() if _reactor != null else 0.0


## Stands up facing the player (as _update_body will turn it anyway).
func _hr_face() -> Vector3:
	var pl = Game.player
	if pl != null and is_instance_valid(pl):
		return (pl as Node3D).global_position - global_position
	return _facing


func _hr_on_down(rag: Node) -> void:
	_hr_off = global_position - _anchor - _knock
	_knock_v = Vector3.ZERO
	_ragdoll = rag
	_label.visible = false
	_halo.visible = false


func _hr_on_getup(xf: Transform3D) -> void:
	_knock = xf.origin - _anchor - _hr_off
	_knock_v = Vector3.ZERO
	if body != null and is_instance_valid(body):
		_r_goal = (xf.origin - body.global_position).length()
		_r_shown = _r_goal
	_prev_foot = Vector3.INF
	_probe_acc = 99.0


func _hr_on_up() -> void:
	_ragdoll = null                        # (the reactor freed it)
	_label.visible = true
	_halo.visible = true
	astronaut.animate(0.016, {"speed": 0.0, "grounded": true, "probe": false})
	astronaut.sync_skeleton()


## _die: a knocked-down body with live physics goes on as the corpse (true: _ragdoll is it).
func _hr_keep_ragdoll(impulse: Vector3) -> bool:
	if _reactor == null:
		return false
	var r = _reactor.take_corpse(impulse)
	if r == null:
		return false
	_ragdoll = r
	return true


func _hr_launch(v: Vector3) -> Vector3:
	return _hr_get().death_launch(v)         # (a first-shove KO without a reactor yet was uncapped)
