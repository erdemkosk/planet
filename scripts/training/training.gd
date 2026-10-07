extends Node
## Eğitim Alanı (training ground), started from the main menu (scripts/ui/main_menu.gd): the normal
## world (scripts/main.gd) with the home planet swapped for a calm grey test planet "Eğitim" (same
## size, gravity and crater scale as the match, so every weapon feels the same), every gun crafted,
## no rival team, no match end, and training dummies (scripts/training/training_dummy.gd) to shoot,
## blow up and fling. Single player only (Net stays inactive).
## The mode flags live on the Game autoload as metas, so shared scripts check them without a preload:
##   Game.has_meta("training")       the mode is on (main.gd: the planet + this node; war.gd: no AI,
##                                   no end screen; core.gd: a core never drops below 1 hp, refilled
##                                   here; pause_menu.gd: "Ana Menü")
##   Game.has_meta("training_god")   the player cannot die (player.gd take_damage)
## Keys: H the panel (scripts/training/training_panel.gd: place dummies by kind and movement, ready
## layouts, revive / remove, the toggles, reset the ground, start the real rival team, main menu),
## J a dummy at the crosshair with the panel's current kind and movement.
## Stats (the box top left reads `stats` + dps()): last hit and its range, DPS over the last second,
## the current burst (damage, length, rate; a 2 s pause starts a new one), hits, kills, time to
## kill, the last fling speed and the last core damage.

const Bodies := preload("res://scripts/planet/bodies.gd")
const Balance := preload("res://scripts/war/balance.gd")
const Settings := preload("res://scripts/save/settings.gd")
const Dummy := preload("res://scripts/training/training_dummy.gd")
const TrainingPanel := preload("res://scripts/training/training_panel.gd")
const MENU_SCENE := "res://scenes/menu.tscn"

const META := "training"
const META_GOD := "training_god"
const GROUP := "training"
const MAX_DUMMIES := 32
const MATERIAL_FLOOR := 5000.0          # unlimited material: topped up to MATERIAL_FILL below this
const MATERIAL_FILL := 9999.0
const CORE_REFILL := 4.0                # s after the last core hit its hp is full again
const BURST_GAP := 2000                 # ms without a hit ends a burst

## Toggles (kept through "Alanı sıfırla", a scene reload).
static var infinite := true
static var numbers := true
static var place_kind := Dummy.KIND_STD
static var place_move := Dummy.MOVE_STILL
static var _numbers_user := false

var panel                               # training_panel.gd
var dummies: Array = []
var stats := {}
var ai_started := false
var _window: Array = []                 # [msec, dmg] of the last second
var _next_id := 1
var _core_hp := {}                      # core -> last seen hp
var _core_hit_ms := {}
var _refill_t := 0.0


# =================================================================================================
# Mode (static: the main menu / pause menu call these)
# =================================================================================================

static func active() -> bool:
	return Game.has_meta(META)


static func god() -> bool:
	return Game.has_meta(META_GOD)


static func set_god(on: bool) -> void:
	if on:
		Game.set_meta(META_GOD, true)
	elif Game.has_meta(META_GOD):
		Game.remove_meta(META_GOD)


## The main menu's "Eğitim Alanı": a fresh state with the mode on (then load scenes/main.tscn).
static func begin() -> void:
	if not Game.has_meta(META):
		_numbers_user = Settings.damage_numbers
	Game.set_meta(META, true)
	set_god(true)
	Game.reset_state()


## Leaves the mode (back to the menu, or the menu opened for any other reason).
static func end() -> void:
	if Game.has_meta(META):
		Settings.damage_numbers = _numbers_user
		Game.remove_meta(META)
	set_god(false)


## The home planet's preset overrides in training: a cool grey test ground, gentler relief.
static func planet_overrides() -> Dictionary:
	var r := Bodies.PLANET_RADIUS
	return {
		"display_name": "Eğitim", "seed": 1357,
		"col_low": Color(0.35, 0.38, 0.41), "col_high": Color(0.47, 0.49, 0.52), "col_rock": Color(0.34, 0.35, 0.37),
		"col_dust": Color(0.52, 0.53, 0.55), "col_mare": Color(0.31, 0.33, 0.36),
		"col_pool": Color(0.3, 0.3, 0.32), "col_crack": Color(0.2, 0.2, 0.22),
		"strata": [Color(0.45, 0.43, 0.41), Color(0.37, 0.36, 0.36), Color(0.28, 0.28, 0.30)],
		"rock_tint": Color(0.44, 0.45, 0.47), "soil_color": Color(0.46, 0.43, 0.39),
		"m_amp_cont": r / 24.0, "m_amp_hill": r / 60.0, "m_amp_mount": r / 48.0,
		"m_crater_amp": 0.1, "m_crater_density": 0.12,
	}


# =================================================================================================
# Setup
# =================================================================================================

func _ready() -> void:
	name = "Training"
	add_to_group(GROUP)
	_reset_stats()
	_bind_key("training_panel", KEY_H)
	_bind_key("training_place", KEY_J)
	Game.unlock_all_weapons()           # after reset_state (main menu / reset): every gun, 15 grenades
	Settings.damage_numbers = numbers
	Game.core_damaged.connect(_on_core_damaged)
	panel = TrainingPanel.new()
	panel.trainer = self
	add_child(panel)
	_spawn_default.call_deferred()
	if Game.hud and Game.hud.has_method("show_message"):
		Game.hud.show_message("EĞİTİM ALANI  ·  H: panel  ·  J: nişangaha hedef", 5.0)


func _bind_key(action: String, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)


func _reset_stats() -> void:
	stats = {"last": 0.0, "last_d": 0.0, "last_name": "", "last_kill": false, "hits": 0, "total": 0.0,
			"kills": 0, "ttk": -1.0, "burst": 0.0, "burst_hits": 0, "burst_t0": 0, "burst_t1": -100000,
			"fling": 0.0, "core": 0.0, "core_name": ""}
	_window.clear()


func reset_stats() -> void:
	_reset_stats()


# =================================================================================================
# Every frame: unlimited material / grenades, god mode, core refill
# =================================================================================================

func _process(delta: float) -> void:
	_refill_t -= delta
	if _refill_t <= 0.0:
		_refill_t = 0.25
		if infinite:
			if Game.material < MATERIAL_FLOOR:
				Game.add_material(MATERIAL_FILL - Game.material)
			if Game.grenades < Balance.GRENADE_MAX:
				Game.grenades = Balance.GRENADE_MAX
				Game.loadout_changed.emit()
		_refill_cores()
	var pl = Game.player
	if god() and pl != null and is_instance_valid(pl) and not pl.is_dead():
		pl.hp = pl.hp_max


func _refill_cores() -> void:
	var now := Time.get_ticks_msec()
	for c in get_tree().get_nodes_in_group("war_core"):
		if c.hp < c.hp_max and now - int(_core_hit_ms.get(c, 0)) > int(CORE_REFILL * 1000.0):
			c.hp = c.hp_max
			_core_hp[c] = c.hp


func _on_core_damaged(b: Node3D, hp: float) -> void:
	for c in get_tree().get_nodes_in_group("war_core"):
		if c.body != b:
			continue
		var before := float(_core_hp.get(c, c.hp_max))
		stats["core"] = maxf(before - hp, 0.0)
		stats["core_name"] = str(b.display_name)
		_core_hp[c] = hp
		_core_hit_ms[c] = Time.get_ticks_msec()


# =================================================================================================
# Dummies
# =================================================================================================

## A dummy on `body` at `point` (the ground is found there), facing `face_to`. null when full.
func add_dummy(body: Node3D, point: Vector3, face_to: Vector3, kind: int, move: int) -> Node3D:
	_prune()
	if body == null or dummies.size() >= MAX_DUMMIES:
		if Game.hud and Game.hud.has_method("show_message"):
			Game.hud.show_message("En çok %d hedef" % MAX_DUMMIES, 2.0)
		return null
	var d: Node3D = Dummy.new()
	d.trainer = self
	d.kind = kind
	d.move = move
	d.callsign = "Hedef %d" % _next_id
	d.name = "Dummy%d" % _next_id
	_next_id += 1
	add_child(d)
	d.place(body, point, face_to)
	dummies.append(d)
	return d


func _prune() -> void:
	dummies = dummies.filter(func(d) -> bool: return is_instance_valid(d))


func clear_dummies() -> void:
	_prune()
	for d in dummies:
		(d as Node).queue_free()
	dummies.clear()
	_next_id = 1


func remove_last() -> void:
	_prune()
	if not dummies.is_empty():
		(dummies.pop_back() as Node).queue_free()


func revive_all() -> void:
	_prune()
	for d in dummies:
		d.revive()


## The panel's kind and movement onto every dummy.
func apply_to_all(kind: int, move: int) -> void:
	_prune()
	for d in dummies:
		d.set_kind(kind)
		d.set_move(move)
		d.revive()


## A dummy where the crosshair points (terrain of any planet, up to 700 m). false: nothing there.
func place_at_crosshair() -> bool:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or pl.camera == null:
		return false
	var cam: Camera3D = pl.camera
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	var to := from + dir * 700.0
	var hit_pos := Vector3.INF
	var q := PhysicsRayQueryParameters3D.create(from, to, Game.LAYER_TERRAIN)
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		hit_pos = hit["position"]
	else:
		# Far terrain has no collision shape: march the density fields.
		var best := INF
		for b in Bodies.all():
			if not is_instance_valid(b):
				continue
			var h: Dictionary = b.raycast_density(from, to, 0.75, true)
			if not h.is_empty() and float(h["distance"]) < best:
				best = float(h["distance"])
				hit_pos = h["position"]
	if hit_pos == Vector3.INF:
		if Game.hud and Game.hud.has_method("show_message"):
			Game.hud.show_message("Nişangahta zemin yok", 1.6)
		return false
	var d := add_dummy(Bodies.nearest(hit_pos), hit_pos, from, place_kind, place_move)
	if d != null and Game.sfx:
		Game.sfx.play("ding", -12.0, 1.3)
	return d != null


## A dummy `ahead` m in front of the player (along the ground, the way the camera looks).
func place_in_front(ahead := 7.0) -> void:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl):
		return
	var body: Node3D = Game.dominant_body((pl as Node3D).global_position)
	var origin: Vector3 = (pl as Node3D).global_position
	var up: Vector3 = body.up_at(origin)
	var f: Vector3 = -pl.camera.global_transform.basis.z if pl.camera != null else -(pl as Node3D).global_transform.basis.z
	f -= up * f.dot(up)
	if f.length_squared() < 1e-4:
		f = -(pl as Node3D).global_transform.basis.z
	f = f.normalized()
	add_dummy(body, _arc_point(body, origin, f, f.cross(up).normalized(), ahead, 0.0), origin, place_kind, place_move)


## The point `ahead` m forward and `side` m right of `origin` along the planet's surface.
func _arc_point(body: Node3D, origin: Vector3, fwd: Vector3, right: Vector3, ahead: float, side: float) -> Vector3:
	var c: Vector3 = body.global_position
	var d0 := (origin - c).normalized()
	var t := fwd * ahead + right * side
	var l := t.length()
	if l < 0.01:
		return origin
	var r: float = float(body.radius)
	var axis := d0.cross(t / l).normalized()
	var d1 := d0.rotated(axis, l / r)
	return c + d1 * (r + float(body.surface_height_at(c + d1 * r)))


# =================================================================================================
# Ready layouts
# =================================================================================================

## The starting range in front of the spawn, plus a far group on the rival planet.
func _spawn_default() -> void:
	layout_range()
	layout_far()


func _player_frame() -> Dictionary:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or Game.planet == null:
		return {}
	var body: Node3D = Game.planet
	var origin: Vector3 = (pl as Node3D).global_position
	var up: Vector3 = body.up_at(origin)
	var f: Vector3 = -pl.camera.global_transform.basis.z if pl.camera != null else -(pl as Node3D).global_transform.basis.z
	f -= up * f.dot(up)
	if f.length_squared() < 1e-4:
		f = up.cross(Vector3.RIGHT)
	f = f.normalized()
	return {"body": body, "origin": origin, "fwd": f, "right": f.cross(up).normalized()}


## Atış poligonu: still targets at 6 / 10 / 14 m, an armoured and an immortal (DPS) one beside
## them, and three moving ones (strafe, ring, hops). On a 30 m planet the horizon is ~10 m away:
## the far ones show from the chest up.
func layout_range() -> void:
	var fr := _player_frame()
	if fr.is_empty():
		return
	var spec := [
		# The still row is staggered sideways so no target hides behind a nearer one.
		[6.0, 0.0, Dummy.KIND_STD, Dummy.MOVE_STILL],
		[10.0, -2.5, Dummy.KIND_STD, Dummy.MOVE_STILL],
		[14.0, 2.5, Dummy.KIND_STD, Dummy.MOVE_STILL],
		[7.0, -4.5, Dummy.KIND_IMMORTAL, Dummy.MOVE_STILL],
		[7.0, 4.5, Dummy.KIND_ARMOR, Dummy.MOVE_STILL],
		[12.0, -8.5, Dummy.KIND_STD, Dummy.MOVE_STRAFE],
		[12.0, 7.5, Dummy.KIND_STD, Dummy.MOVE_CIRCLE],
		[9.0, 10.0, Dummy.KIND_STD, Dummy.MOVE_HOP],
	]
	for s in spec:
		var p := _arc_point(fr["body"], fr["origin"], fr["fwd"], fr["right"], float(s[0]), float(s[1]))
		add_dummy(fr["body"], p, fr["origin"], int(s[2]), int(s[3]))


## Kalabalık: eight dummies packed 8 m ahead (grenades, rockets, the pusher).
func layout_crowd() -> void:
	var fr := _player_frame()
	if fr.is_empty():
		return
	for i in 8:
		var a := TAU * float(i) / 8.0
		var p := _arc_point(fr["body"], fr["origin"], fr["fwd"], fr["right"], 9.0 + cos(a) * 2.2, sin(a) * 2.2)
		add_dummy(fr["body"], p, fr["origin"], Dummy.KIND_STD, Dummy.MOVE_STILL)


## Uzak hedefler: five dummies on the rival planet's side facing the player (~300 m: the sniper,
## rockets, cannons, the torpedo).
func layout_far() -> void:
	var pl = Game.player
	var rb: Node3D = Game.rival
	if pl == null or not is_instance_valid(pl) or rb == null or not is_instance_valid(rb):
		return
	var eye: Vector3 = (pl as Node3D).global_position
	var c: Vector3 = rb.global_position
	var d0 := (eye - c).normalized()
	var right := d0.cross(Vector3.UP if absf(d0.y) < 0.9 else Vector3.RIGHT).normalized()
	var fwd := right.cross(d0).normalized()
	var r: float = float(rb.radius)
	for o in [Vector2(0, 0), Vector2(-3.5, 0), Vector2(3.5, 0), Vector2(0, 3.5), Vector2(0, -3.5)]:
		var t: Vector2 = o
		var tv := right * t.x + fwd * t.y
		var dir := d0 if tv.length() < 0.01 else d0.rotated(d0.cross(tv.normalized()).normalized(), tv.length() / r)
		var p := c + dir * (r + float(rb.surface_height_at(c + dir * r)))
		add_dummy(rb, p, eye, Dummy.KIND_STD, Dummy.MOVE_STILL)


# =================================================================================================
# Panel actions
# =================================================================================================

## Reloads the scene: fresh ground, the default layout (the toggles stay).
func reset_field() -> void:
	get_tree().paused = false
	Game.reset_state()                   # the next Training node re-arms every gun
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().reload_current_scene()


## The real rival team on the rival planet (scripts/war/rival_team.gd): it digs, builds, shells this
## planet. The cores still cannot die. Until the ground is reset.
func start_rival_team() -> void:
	if ai_started:
		return
	var war = get_tree().get_first_node_in_group("war_controller")
	if war != null and war.has_method("start_ai"):
		war.start_ai()
		ai_started = true
		if Game.hud and Game.hud.has_method("show_message"):
			Game.hud.show_message("Rakip takımı başladı", 3.0)


func to_menu() -> void:
	get_tree().paused = false
	end()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)


func set_numbers(on: bool) -> void:
	numbers = on
	Settings.damage_numbers = on


## The panel's choices and toggles (static: kept through a reset; the panel goes through these).
func place_choice() -> Array:
	return [place_kind, place_move]


func set_place_choice(kind: int, move: int) -> void:
	place_kind = kind
	place_move = move


func god_on() -> bool:
	return god()


func set_god_on(on: bool) -> void:
	set_god(on)


func infinite_on() -> bool:
	return infinite


func set_infinite(on: bool) -> void:
	infinite = on


func numbers_on() -> bool:
	return numbers


func dummy_count() -> int:
	_prune()
	return dummies.size()


# =================================================================================================
# Stats (training_dummy.gd reports here)
# =================================================================================================

func on_dummy_hit(d: Node3D, dmg: float, killed: bool, ttk: float) -> void:
	var now := Time.get_ticks_msec()
	if now - int(stats["burst_t1"]) > BURST_GAP:
		stats["burst"] = 0.0
		stats["burst_hits"] = 0
		stats["burst_t0"] = now
	stats["burst"] = float(stats["burst"]) + dmg
	stats["burst_hits"] = int(stats["burst_hits"]) + 1
	stats["burst_t1"] = now
	stats["last"] = dmg
	stats["last_kill"] = killed
	stats["last_name"] = str(d.get("callsign"))
	var pl = Game.player
	stats["last_d"] = (pl as Node3D).global_position.distance_to(d.global_position) if pl != null and is_instance_valid(pl) else 0.0
	stats["hits"] = int(stats["hits"]) + 1
	stats["total"] = float(stats["total"]) + dmg
	if killed:
		stats["kills"] = int(stats["kills"]) + 1
		stats["ttk"] = ttk
	_window.append([now, dmg])


func on_dummy_flung(_d: Node3D, speed: float) -> void:
	stats["fling"] = speed


## Damage per second over the last second.
func dps() -> float:
	var now := Time.get_ticks_msec()
	while not _window.is_empty() and now - int(_window[0][0]) > 1000:
		_window.pop_front()
	var s := 0.0
	for w in _window:
		s += float(w[1])
	return s


## The current burst: [damage, seconds, hits].
func burst() -> Array:
	var t := float(int(stats["burst_t1"]) - int(stats["burst_t0"])) / 1000.0
	return [float(stats["burst"]), t, int(stats["burst_hits"])]
