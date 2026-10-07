extends Node3D
## Malzeme ganimeti: a canister of material lying where someone died (2026-10-05 the user: "kişinin
## topladığı malzemeler yere düşüp kalmalı, onu toplatabilir oyuncu bu sayede"). Tunables: balance.gd
## "Corpses and loot".
## Sources (spawned on the host / in single player only; a multiplayer client's own death asks the host):
##   rival bot  what it dug since its respawn (ai_rival.gd lt_carried: its share of the team income,
##              rival_team.gd _lt_carry) or picked up, LOOT_MIN..LOOT_CARRY_MAX, out of the team pool
##   player     LOOT_PLAYER_SHARE of Game.material where he died (drop_player, from player.gd _die); he
##              can walk back for it after the respawn (not in the Eğitim Alanı: unlimited material)
##   dummy      LOOT_DUMMY from a killable training dummy (training_dummy.gd _die)
## The pickup falls with the planets' gravity (Game.gravity_at) onto the real ground: a physics ray
## against Game.LAYER_TERRAIN first, else the EXACT density (planet.raycast_density(..., false): the
## fast march skips ±1.3 m of terrain detail and leaves things floating). It drops again when the
## ground under it is dug away and a blast nearby pops it up. It lies LOOT_TIME s, blinking for the last
## LOOT_BLINK s; a drop within LOOT_MERGE_R of another pickup adds to that one. Look: a dark canister
## with two glowing amber bands and a heap of the planet's soil on top, bobbing and turning, a soft
## light, a ring on the ground, "+N m³" over it while the camera is within LOOT_LABEL_R.
## Taking it: the local player walks within LOOT_PICKUP_R of it (automatic) or presses F looking at it
## (an interact_button.gd Area3D): Game.add_material(N), "+N m³ malzeme", a pickup sound and a short
## warm screen flash. A rival bot (single player / co-op host) walking over one that has lain on its own
## planet for LOOT_BOT_GRACE s takes it into the pool (and carries it: it drops again where it dies).
##
## Multiplayer (host authoritative; single player never touches it). Loot.events():
##   loot_spawned(id, pos, amount)   host: a new pickup     -> client: spawn_mirror(id, pos, amount)
##   loot_updated(id, amount)        host: a drop merged in -> client: set_amount(id, amount)
##   loot_taken(id, by)              host: gone. by = TAKER_LOCAL (the host's player), TAKER_PEER (the
##                                   client's player: claim(id, TAKER_PEER) returned the amount) or
##                                   TAKER_RIVAL (a bot)    -> client: taken(id, by == TAKER_PEER, amount)
##   loot_expired(id)                host: timed out        -> client: taken(id, false)
##   pickup_requested(id)            client: our player reached a mirror -> host: claim(id, TAKER_PEER)
##                                   (the first claim wins; at most one request a second per pickup)
##   drop_requested(pos, amount)     client: our player died; his share is already off Game.material
##                                   -> host: drop(pos, amount)
##   snapshot() -> [[id, pos, amount, age], ...]   late join: spawn_mirror(id, pos, amount, age) each

const Balance := preload("res://scripts/war/balance.gd")
const InteractButton := preload("res://scripts/ships/interact_button.gd")
const PATH := "res://scripts/war/loot.gd"

const TAKER_LOCAL := "local"
const TAKER_PEER := "peer"
const TAKER_RIVAL := "rival"

const REST_H := 0.26                   # m: canister centre over the ground (its foot ~6 cm above it)
const BOB := 0.03                      # m up and down
const DRAG := 0.15                     # 1/s while falling (thin air)
const BOUNCE_V := 3.0                  # m/s into the ground: a hop instead of a stop (twice at most)
const CHECK_PERIOD := 0.25             # s: ground support / rival bots while lying
const BLAST_REACH := 1.4               # × a blast's radius: pickups this near pop up...
const BLAST_POP := 6.0                 # ...with this many m/s at the centre
const COLOR := Color(1.0, 0.62, 0.22)

## Multiplayer hooks (see above).
class LootEvents extends RefCounted:
	signal loot_spawned(id: int, pos: Vector3, amount: float)
	signal loot_updated(id: int, amount: float)
	signal loot_taken(id: int, by: String)
	signal loot_expired(id: int)
	signal pickup_requested(id: int)
	signal drop_requested(pos: Vector3, amount: float)

static var _events: LootEvents
static var _all := {}                  # id -> loot node (live pickups and mirrors)
static var _next_id := 1
static var _mats := {}

var id := 0
var amount := 0.0
var mirror := false                    # a client's copy of the host's pickup
var _spawn_pos := Vector3.ZERO
var _vel := Vector3.ZERO
var _resting := false
var _bounces := 0
var _walls := 0                        # steps in a row against a wall / ceiling
var _age := 0.0
var _spin := 0.0
var _check_t := 0.0
var _req_ms := -100000
var _gone := false
var _vis: Node3D
## Render interpolation while falling (perf pass 2026-10-07: 60 Hz steps stutter on a 144 Hz screen).
var _ri_on := false
var _ri_from := Vector3.ZERO
var _ri_to := Vector3.ZERO
var _heap: MeshInstance3D
var _ring: MeshInstance3D
var _light: OmniLight3D
var _label: Label3D
var _area: Area3D


static func events() -> LootEvents:
	if _events == null:
		_events = LootEvents.new()
	return _events


# =================================================================================================
# API (static)
# =================================================================================================

## Drops `amt` m³ at `pos` (world) with launch velocity `vel`: a new pickup, or added to one within
## LOOT_MERGE_R. Host / single player; a multiplayer client only asks (drop_requested) and gets null.
static func drop(pos: Vector3, amt: float, vel := Vector3.ZERO) -> Node3D:
	if amt <= 0.0:
		return null
	if Net.is_client():
		events().drop_requested.emit(pos, amt)
		return null
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	for l in _list():
		if not l.mirror and l._where().distance_to(pos) < Balance.LOOT_MERGE_R:
			l.set_amount_local(l.amount + amt)
			l._age = 0.0                   # (fresh again)
			events().loot_updated.emit(l.id, l.amount)
			return l
	var n = _make(tree.current_scene, _next_id, pos, amt, false)
	_next_id += 1
	n._vel = vel
	events().loot_spawned.emit(n.id, pos, amt)
	return n


## Multiplayer client: the host's pickup `p_id` (loot_spawned / a late join's snapshot).
static func spawn_mirror(p_id: int, pos: Vector3, amt: float, age := 0.0) -> Node3D:
	var old = find(p_id)
	if old != null:
		old.set_amount_local(amt)
		return old
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var n = _make(tree.current_scene, p_id, pos, amt, true)
	n._age = age
	return n


## Host: someone takes pickup `p_id` (TAKER_LOCAL / TAKER_PEER / TAKER_RIVAL). Returns the amount
## (0: already gone). The local player's material is granted here; the others' by the caller.
static func claim(p_id: int, by: String) -> float:
	var l = find(p_id)
	if l == null or l.mirror or l._gone:
		return 0.0
	var amt: float = l.amount
	_all.erase(p_id)
	l._vanish()
	if by == TAKER_LOCAL:
		_grant_local(amt)
	events().loot_taken.emit(p_id, by)
	return amt


## Multiplayer client: the host says pickup `p_id` is gone; by_me: our player got it (amt: the host's
## amount, < 0 = the mirror's).
static func taken(p_id: int, by_me: bool, amt := -1.0) -> void:
	var l = find(p_id)
	var a := amt
	if l != null:
		if a < 0.0:
			a = l.amount
		_all.erase(p_id)
		l._vanish()
	if by_me and a > 0.0:
		_grant_local(a)


## Multiplayer client: the host's pickup changed (loot_updated).
static func set_amount(p_id: int, amt: float) -> void:
	var l = find(p_id)
	if l != null:
		l.set_amount_local(amt)


static func find(p_id: int) -> Node3D:
	var l = _all.get(p_id)
	if l == null or not is_instance_valid(l) or l.is_queued_for_deletion() or l._gone:
		_all.erase(p_id)
		return null
	return l


## Every live pickup of the host: [[id, pos, amount, age], ...] (a late join).
static func snapshot() -> Array:
	var out: Array = []
	for l in _list():
		if not l.mirror:
			out.append([l.id, l._where(), l.amount, l._age])
	return out


## What dying costs the local player, all of it (2026-10-06, the user: "ölmek maliyetli bir şey
## olmalı"). The ONE function the death path calls (player.gd _die; later the DOWNED system's confirmed
## death): his material share drops here (drop_player), the gun in hand and every carried loot gun
## drop with their rounds (weapon_drop.gd drop_player), then the loot guns are gone (Game.lose_loot_guns).
static func on_player_death(p: Node3D) -> void:
	drop_player(p)
	var wd = load("res://scripts/war/weapon_drop.gd")
	if wd is Script and (wd as Script).can_instantiate():
		wd.drop_player(p)
	Game.lose_loot_guns()


## The player died (on_player_death): LOOT_PLAYER_SHARE of his material drops where he lies, at most
## LOOT_PLAYER_MAX (half of that from a co-op team pool, Game.shared_pool: the partner's half of it is
## not his to lose).
static func drop_player(p: Node3D) -> void:
	if p == null or not is_instance_valid(p) or not p.is_inside_tree() or Game.has_meta("training"):
		return
	var amt := floorf(minf(Game.material * Balance.LOOT_PLAYER_SHARE * (0.5 if Game.shared_pool else 1.0),
			Balance.LOOT_PLAYER_MAX))
	if amt < Balance.LOOT_PLAYER_MIN:
		return
	Game.add_material(-amt)
	var feet := p.global_position
	var up := _up_at(feet)
	drop(feet + up * 1.0, amt, up * 2.2 + _jitter(up, 0.8))
	if Game.hud:
		Game.hud.alert("Öldün — %d m³ malzemen yere düştü, yeniden doğuluyor…" % int(amt), 1, "death", 4.0)


## A random sideways velocity (tangent to `up`) of up to k m/s.
static func _jitter(up: Vector3, k: float) -> Vector3:
	var v := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
	v -= up * v.dot(up)
	return v.limit_length(1.0) * k


static func _list() -> Array:
	var out: Array = []
	for k in _all.keys():
		var l = _all[k]
		if l == null or not is_instance_valid(l) or l.is_queued_for_deletion() or l._gone:
			_all.erase(k)
			continue
		out.append(l)
	return out


## A pickup node; added deferred (a kill may come from inside a physics query: an Area3D is built).
static func _make(scene: Node, p_id: int, pos: Vector3, amt: float, is_mirror: bool) -> Node3D:
	var n = load(PATH).new()
	n.id = p_id
	n.amount = amt
	n.mirror = is_mirror
	n._spawn_pos = pos
	_all[p_id] = n
	scene.add_child.call_deferred(n)
	return n


## The local player got `amt` m³.
static func _grant_local(amt: float) -> void:
	Game.add_material(amt)
	if Game.sfx:
		Game.sfx.play("ding", -6.0, 1.2)
		Game.sfx.play("grip", -9.0, 0.95)
	if Game.hud:
		Game.hud.alert("+%d m³ malzeme" % roundi(amt), 0, "loot", 2.0)
	_flash()


## A short warm flash over the view (under the HUD).
static func _flash() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 4
	var r := ColorRect.new()
	r.color = Color(1.0, 0.72, 0.32, 0.14)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(r)
	tree.current_scene.add_child(layer)
	var tw := layer.create_tween()
	tw.tween_property(r, "color:a", 0.0, 0.45).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(layer.queue_free)


# =================================================================================================
# The pickup
# =================================================================================================

func _ready() -> void:
	if _gone:                              # (taken before it was even added)
		queue_free()
		return
	_build()
	global_transform = Transform3D(_frame(_up_at(_spawn_pos)), _spawn_pos)
	var body: Node3D = Game.dominant_body(_spawn_pos)
	var soil = body.get("soil_color") if body != null else null
	_heap.material_override = _soil_mat(soil if soil is Color else Color(0.42, 0.33, 0.22))
	set_amount_local(amount)
	if not mirror:
		Game.blast.connect(_on_blast)


func set_amount_local(amt: float) -> void:
	amount = amt
	if _label != null:
		_label.text = "+%d m³" % roundi(amount)


func _where() -> Vector3:
	return global_position if is_inside_tree() else _spawn_pos


func _prompt() -> String:
	return "Malzemeyi al (+%d m³)" % roundi(amount)


func _physics_process(delta: float) -> void:
	if _gone:
		return
	if _ri_on:                             # (the sim position back: _process drew it between ticks)
		global_position = _ri_to
		_ri_on = false
	_age += delta
	if _age >= Balance.LOOT_TIME:
		_expire()
		return
	if not _resting:
		var from := global_position
		_fall(delta)
		_ri_from = from
		_ri_to = global_position
		_ri_on = not _gone and from.distance_squared_to(_ri_to) < 25.0
	else:
		_check_t -= delta
		if _check_t <= 0.0:
			_check_t = CHECK_PERIOD
			if not _supported():
				_resting = false           # the ground went (dug, blown away): fall again
				_bounces = 0
				_vel = Vector3.ZERO
			elif not mirror:
				_bot_scan()
	if not _gone:
		_local_pickup()


func _process(delta: float) -> void:
	if _gone or _vis == null:
		return
	if _ri_on:                             # falling: drawn between the last two physics ticks
		global_position = _ri_from.lerp(_ri_to, clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0))
	_spin += delta * (1.1 if _resting else 6.0)
	_vis.rotation = Vector3(0.0, _spin, 0.0)
	_vis.position = Vector3(0.0, REST_H + (sin(_age * 2.4) * BOB if _resting else 0.0), 0.0)
	# The last LOOT_BLINK s: blinking, faster toward the end.
	var left := Balance.LOOT_TIME - _age
	var on := true
	if left < Balance.LOOT_BLINK:
		var hz := lerpf(6.0, 2.0, clampf(left / maxf(Balance.LOOT_BLINK, 0.1), 0.0, 1.0))
		on = fmod(_age * hz, 1.0) < 0.62
	_vis.visible = on
	_light.visible = on
	_ring.visible = on and _resting
	var pulse := 1.0 + 0.08 * sin(_age * 3.2)
	_ring.scale = Vector3(pulse, 0.2, pulse)
	# "+N m³" near the camera only, fading in over the last 2 m.
	var cam := get_viewport().get_camera_3d()
	var d := cam.global_position.distance_to(global_position) if cam != null else INF
	var lr: float = Balance.LOOT_LABEL_R * (0.45 if Game.hud_mode() == 0 else 1.0)     # (HUD Sade: only up close)
	var a := clampf((lr - d) / 2.0, 0.0, 1.0)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("is_dead") and pl.is_dead():
		a = 0.0                              # (not in the death camera / the respawn ride)
	_label.visible = on and a > 0.0
	if _label.visible:
		_label.modulate.a = a
		_label.outline_modulate.a = 0.7 * a


## One physics step through the air; lands on the terrain collision or, where none is built, on the
## exact density surface.
func _fall(dt: float) -> void:
	var p := global_position
	_vel += Game.gravity_at(p) * dt
	_vel *= exp(-DRAG * dt)
	var nxt := p + _vel * dt
	var hit := _ground_between(p, nxt)
	if hit.is_empty():
		_walls = 0
		_set_at(nxt)
		return
	var hp: Vector3 = hit["position"]
	var n: Vector3 = hit["normal"]
	var up := _up_at(hp)
	_walls += 1
	if n.dot(up) < 0.45 and _walls < 30:
		# A wall or a tunnel ceiling: lose the speed into it and keep falling (wedged in a crack: it
		# rests where it is after a while).
		_vel -= n * minf(_vel.dot(n), 0.0)
		_vel *= 0.8
		_set_at(hp + n * 0.03)
		return
	var vn := -_vel.dot(up)
	if vn > BOUNCE_V and _bounces < 2:
		_bounces += 1
		_vel = (_vel - up * _vel.dot(up)) * 0.45 + up * vn * 0.3
		_set_at(hp + up * 0.02)
		return
	_set_at(hp)
	_vel = Vector3.ZERO
	_walls = 0
	_resting = true
	_check_t = CHECK_PERIOD


## The ground between a and b (world): {"position", "normal"}, or {} (still in the air).
func _ground_between(a: Vector3, b: Vector3) -> Dictionary:
	var seg := b - a
	var len := seg.length()
	var dir := seg / len if len > 1e-5 else -_up_at(a)
	var to := b + dir * 0.05
	var q := PhysicsRayQueryParameters3D.create(a, to, Game.LAYER_TERRAIN)
	q.hit_back_faces = false
	var h := get_world_3d().direct_space_state.intersect_ray(q)
	if not h.is_empty():
		return {"position": h["position"], "normal": h["normal"]}
	var body: Node3D = Game.dominant_body(b)
	if body == null or not body.has_method("density_at"):
		return {}
	if float(body.density_at(to)) >= 0.0:
		return {}                          # still in the air
	var r: Dictionary = body.raycast_density(a, to, 0.1, false)
	if not r.is_empty():
		return {"position": r["position"], "normal": r["normal"]}
	# It started inside the ground (spawned in rock, ground raised over it): out on top.
	var up := _up_at(b)
	r = body.raycast_density(b + up * 3.0, b - up * 0.5, 0.2, false)
	return {"position": r["position"] if not r.is_empty() else b, "normal": up}


## Still something solid right under it (the collision, else the exact density).
func _supported() -> bool:
	var p := global_position
	var up := _up_at(p)
	var q := PhysicsRayQueryParameters3D.create(p + up * 0.3, p - up * 0.25, Game.LAYER_TERRAIN)
	q.hit_back_faces = false               # (not the inside of a ceiling it touched)
	if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return true
	var body: Node3D = Game.dominant_body(p)
	if body == null or not body.has_method("density_at"):
		return false
	return float(body.density_at(p - up * 0.15)) < 0.0


func _set_at(p: Vector3) -> void:
	global_transform = Transform3D(_frame(_up_at(p)), p)


## The local player walks over it.
func _local_pickup() -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
		return
	if p.is_dead() or p.get("vehicle") != null or (p.has_method("is_ragdolled") and p.is_ragdolled()):
		return
	var feet: Vector3 = (p as Node3D).global_position
	var up := _up_at(feet)
	var rel := (global_position + up * REST_H) - feet
	var h := clampf(rel.dot(up), 0.0, 1.8)
	if (rel - up * h).length() <= Balance.LOOT_PICKUP_R:
		_take_local()


## Ours: the host / single player takes it at once, a client asks the host (at most once a second).
func _take_local() -> void:
	if _gone:
		return
	if mirror:
		var now := Time.get_ticks_msec()
		if now - _req_ms < 1000:
			return
		_req_ms = now
		events().pickup_requested.emit(id)
		return
	claim(id, TAKER_LOCAL)


## Rival bots (single player / co-op host) walking over it on their own planet.
func _bot_scan() -> void:
	if _age < Balance.LOOT_BOT_GRACE or not Net.ai_enabled() or Game.rival == null:
		return
	if Game.dominant_body(global_position) != Game.rival:
		return
	var t = get_tree().get_first_node_in_group("war_rival_team")
	var bots = t.get("bots") if t != null else null
	if not (bots is Array):
		return
	for b in bots:
		if b == null or not is_instance_valid(b) or b.is_dead() or b.is_aboard():
			continue
		if (b as Node3D).global_position.distance_to(global_position) < Balance.LOOT_BOT_PICKUP_R:
			var amt := claim(id, TAKER_RIVAL)
			if amt > 0.0 and b.has_method("lt_pickup"):
				b.lt_pickup(amt)
			return


func _on_blast(pos: Vector3, radius: float, _team: String) -> void:
	if _gone or radius <= 0.0 or not is_inside_tree():
		return
	var c := global_position
	var reach := radius * BLAST_REACH
	var d := c.distance_to(pos)
	if d > reach:
		return
	var up := _up_at(c)
	var dir := (c - pos).normalized() if d > 0.05 else up
	_vel += (dir * 0.6 + up * 0.8).normalized() * BLAST_POP * (1.0 - d / reach)
	_resting = false
	_bounces = 0


func _expire() -> void:
	_all.erase(id)
	if not mirror:
		events().loot_expired.emit(id)
	_vanish()


## Gone (taken / expired): a quick shrink, then freed.
func _vanish() -> void:
	if _gone:
		return
	_gone = true
	if not is_inside_tree():
		return                             # (_ready frees it)
	if _area != null:
		_area.collision_layer = 0
	_label.visible = false
	_ring.visible = false
	_light.visible = false
	var tw := create_tween()
	tw.tween_property(_vis, "scale", Vector3.ONE * 0.05, 0.16).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)


# =================================================================================================
# Look
# =================================================================================================

func _build() -> void:
	_vis = Node3D.new()
	add_child(_vis)
	var shell := _mesh(_vis, _cyl(0.16, 0.16, 0.3), _mat("metal"), Vector3.ZERO)
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for y in [-0.085, 0.085]:
		_mesh(_vis, _cyl(0.167, 0.167, 0.03), _mat("band"), Vector3(0.0, y, 0.0))
	_mesh(_vis, _cyl(0.135, 0.152, 0.04), _mat("trim"), Vector3(0.0, 0.17, 0.0))
	_mesh(_vis, _cyl(0.12, 0.14, 0.03), _mat("trim"), Vector3(0.0, -0.165, 0.0))
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.26
	sm.radial_segments = 16
	sm.rings = 8
	_heap = _mesh(_vis, sm, _mat("trim"), Vector3(0.0, 0.18, 0.0))
	_heap.scale = Vector3(1.0, 0.45, 1.0)
	var tm := TorusMesh.new()
	tm.inner_radius = 0.36
	tm.outer_radius = 0.42
	tm.rings = 40
	tm.ring_segments = 4
	_ring = _mesh(self, tm, _mat("ring"), Vector3(0.0, 0.03, 0.0))
	_ring.scale = Vector3(1.0, 0.2, 1.0)
	_light = OmniLight3D.new()
	_light.light_color = COLOR
	_light.light_energy = 0.9
	_light.omni_range = 2.2
	_light.shadow_enabled = false
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = 25.0
	_light.distance_fade_length = 8.0
	_light.position = Vector3(0.0, 0.45, 0.0)
	add_child(_light)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 64
	_label.pixel_size = 0.003
	_label.outline_size = 16
	_label.modulate = Color(1.0, 0.88, 0.6)
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.7)
	_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_label.position = Vector3(0.0, 0.8, 0.0)
	_label.visible = false
	add_child(_label)
	_area = InteractButton.new()
	_area.setup(Vector3(0.8, 0.9, 0.8), _take_local, _prompt)
	_area.position = Vector3(0.0, 0.35, 0.0)
	add_child(_area)


func _mesh(parent: Node3D, m: Mesh, material: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = material
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = 150.0
	parent.add_child(mi)
	return mi


static func _cyl(top: float, bottom: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = 20
	c.rings = 1
	return c


## Shared materials (one set for every pickup).
static func _mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	match key:
		"metal":
			m.albedo_color = Color(0.19, 0.2, 0.22)
			m.metallic = 0.7
			m.roughness = 0.38
		"trim":
			m.albedo_color = Color(0.55, 0.57, 0.6)
			m.metallic = 0.8
			m.roughness = 0.3
		"band":
			m.albedo_color = COLOR
			m.emission_enabled = true
			m.emission = COLOR
			m.emission_energy_multiplier = 2.6
		"ring":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			m.albedo_color = Color(COLOR.r, COLOR.g, COLOR.b, 0.5)
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats[key] = m
	return m


## The heap of soil on top, in the planet's soil colour, faintly glowing.
static func _soil_mat(c: Color) -> Material:
	var key := "soil_" + c.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	m.emission_enabled = true
	m.emission = c.lerp(COLOR, 0.35)
	m.emission_energy_multiplier = 0.45
	_mats[key] = m
	return m


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
