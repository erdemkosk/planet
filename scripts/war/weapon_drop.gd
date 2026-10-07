extends Node3D
## Silah ganimeti (2026-10-05, CoD style): a gun lying on the ground. Tunables: balance.gd "Weapon
## drops" (WDROP_*). (2026-10-06: no carry limit any more, so a pickup never swaps a gun out.)
## Sources (spawned on the host / in single player only; a multiplayer client asks the host):
##   rival bot  its rifle (drop_bot, from ai_rival.gd _die): WDROP_BOT_MAG of a magazine left plus
##              WDROP_RESERVE_MAGS magazines of reserve
##   player     the gun in his hand (drop_player, from player.gd _die): a COPY with its magazine
##              (the gun's save_state(): mags, ammo type, fire mode) plus WDROP_RESERVE_MAGS of
##              reserve. His loadout guns stay his; the respawn re-equips the gun held last.
##   supply pod a called-in power weapon (scripts/war/supply_pod.gd, on the host): a full magazine and
##              SUPPLY_RESERVE × its CRAFT_RESERVE, through drop_data (so it syncs like the rest)
##   (drop_gun(item, pos, vel, reserve_mags) drops a copy of any gun item, e.g. for later uses)
## Taking it (the local player, local_tick from player.gd _process): within WDROP_PICKUP_R of the feet
## the nearest gun is focused, the prompt (prompt_text, player.gd _update_interact) says
## "[F basılı tut] Tüfek al · ganimet" (a gun you already carry: "Mermi al (+N) — Tüfek"); F held
## WDROP_HOLD s takes it (the HUD quickbar draws hold_progress() as a ring). F must go down while the
## gun is focused. The taker: player.gd take_dropped_gun(data): a gun not carried yet becomes a loot
## gun (Game.add_loot_gun: carried with the others, key 3 … by Game.GUN_ORDER, lost on death) with the
## dropped magazine / mode and reserve; one already carried gives its rounds to the reserve.
## Lies WDROP_TIME s, blinking for the last WDROP_BLINK s; at most WDROP_MAX lie in the world (the
## oldest expires first). Falls with the planets' gravity (Game.gravity_at) onto the real ground like
## loot.gd: a physics ray against Game.LAYER_TERRAIN, else the EXACT density (the far planet has no
## collision there); drops again when the ground under it is dug away; a blast nearby pops it up.
## Look: the gun's own third-person model (the astronaut prop players and bots hold, duplicated) lying
## on its side, a soft ring and light in the gun's colour, its name and magazine over it up close
## (brighter while focused).
##
## Multiplayer (host authoritative; single player never touches it). WeaponDrop.events():
##   drop_spawned(id, data)      host: a new gun on the ground   -> client: spawn_mirror(id, data)
##   drop_taken(id, by)          host: gone. by = TAKER_LOCAL (the host's player) or TAKER_PEER (the
##                               client's player: claim(id, TAKER_PEER) returned its data)
##                               -> client: taken(id, by == TAKER_PEER)  (optional 3rd arg: the data
##                               claim() returned, if the client's mirror is already gone)
##   drop_expired(id)            host: timed out / pushed out by WDROP_MAX -> client: taken(id, false)
##   pickup_requested(id)        client: our player held F on a mirror -> host: claim(id, TAKER_PEER)
##                               (the first claim wins; at most one request a second per gun)
##   drop_requested(data)        client: our player dropped a gun (death / swap) -> host: drop_data(data)
##   snapshot() -> [[id, data, age], ...]   late join: spawn_mirror(id, data, age) for each
## data: a Dictionary of plain values: {"item": item id ("rifle"...), "pos": Vector3 (world),
##   "vel": Vector3 (launch, m/s), "state": the gun's save_state() Dictionary ({"mag"} or
##   {"mags", "ammo", "fire_mode"}), "ammo": ammo id of the reserve ("" = none), "reserve": int rounds}

const Balance := preload("res://scripts/war/balance.gd")
const PATH := "res://scripts/war/weapon_drop.gd"

const TAKER_LOCAL := "local"
const TAKER_PEER := "peer"

const DRAG := 0.15                     # 1/s while falling (thin air)
const BOUNCE_V := 3.0                  # m/s into the ground: a hop instead of a stop (twice at most)
const CHECK_PERIOD := 0.25             # s: ground support while lying
const BLAST_REACH := 1.4               # × a blast's radius: guns this near pop up...
const BLAST_POP := 5.0                 # ...with this many m/s at the centre
const SETTLE := 0.4                    # s after the drop before it can be taken
const NAMES := {"rifle": "Tüfek", "shotgun": "Pompalı", "sniper": "Keskin Nişancı", "pusher": "Kinetik İtici",
		"rocket": "Roketatar", "rail": "Raylı Tüfek", "smg": "Hafif Makineli", "dirt": "Toprak Topu", "plasma": "Plazma Kesici", "mortar": "Havan",
		"pistol": "Tabanca", "revolver": "Altıpatlar", "mpistol": "Makineli Tabanca"}

## Multiplayer hooks (see above).
class WeaponDropEvents extends RefCounted:
	signal drop_spawned(id: int, data: Dictionary)
	signal drop_taken(id: int, by: String)
	signal drop_expired(id: int)
	signal pickup_requested(id: int)
	signal drop_requested(data: Dictionary)

static var _events: WeaponDropEvents
static var _all := {}                  # id -> drop node (live guns and mirrors)
static var _next_id := 1
# The local player's focus and F hold (local_tick).
static var _focus_id := -1
static var _hold := 0.0
static var _armed := false

var id := 0
var data := {}
var mirror := false                    # a client's copy of the host's gun
var _spawn_pos := Vector3.ZERO
var _vel := Vector3.ZERO
var _resting := false
var _bounces := 0
var _walls := 0
var _age := 0.0
var _check_t := 0.0
var _req_ms := -100000
var _gone := false
var _focus_k := 0.0
var _vis: Node3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _light: OmniLight3D
var _label: Label3D
var _col := Color(0.4, 0.88, 1.0)
# Render interpolation while falling (as loot.gd): the position at the last two physics ticks; _process
# draws between them, _physics_process puts the sim position back first.
var _ri_on := false
var _ri_from := Vector3.ZERO
var _ri_to := Vector3.ZERO


static func events() -> WeaponDropEvents:
	if _events == null:
		_events = WeaponDropEvents.new()
	return _events


# =================================================================================================
# API (static)
# =================================================================================================

static func make_data(item_id: String, pos: Vector3, vel: Vector3, state: Dictionary, ammo_id: String, reserve: int) -> Dictionary:
	return {"item": item_id, "pos": pos, "vel": vel, "state": state.duplicate(true), "ammo": ammo_id,
			"reserve": maxi(reserve, 0)}


## A gun on the ground (host / single player). A multiplayer client only asks (drop_requested) and
## gets null. Over WDROP_MAX the oldest gun expires.
static func drop_data(d: Dictionary) -> Node3D:
	if str(d.get("item", "")) == "":
		return null
	if Net.is_client():
		events().drop_requested.emit(d.duplicate(true))
		return null
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var live: Array = []
	for w in _list():
		if not w.mirror:
			live.append(w)
	while live.size() >= Balance.WDROP_MAX:
		var oldest = live[0]
		for w in live:
			if float(w._age) > float(oldest._age):
				oldest = w
		live.erase(oldest)
		oldest._expire()
	var n = _make(tree.current_scene, _next_id, d, false)
	_next_id += 1
	events().drop_spawned.emit(n.id, n.data.duplicate(true))
	return n


## Gun item `it` (one of player.items) drops a COPY of itself at pos: its magazine (save_state) and
## reserve_mags magazines of its current ammo as reserve.
static func drop_gun(it: Object, pos: Vector3, vel: Vector3, reserve_mags := 0.0) -> Node3D:
	if it == null or not is_gun(it):
		return null
	var state: Dictionary = it.call("save_state") if it.has_method("save_state") else {}
	var reserve := 0
	if reserve_mags > 0.0:
		reserve = maxi(int(roundf(float(_mag_cap(it)) * reserve_mags)), 1)
	return drop_data(make_data(str(it.get("item_id")), pos, vel, state, gun_ammo_id(it), reserve))


## The player died (Loot.on_player_death, before Game.lose_loot_guns): the gun in his hand drops where
## he falls (a loadout gun: a copy, it stays his), and so does EVERY carried loot gun (supply-pod /
## picked-up guns, lost on death anyway) with its rounds, so the enemy can take the call-in
## (2026-10-06, the user: "ölmek maliyetli bir şey olmalı"). WDROP_MAX still caps the guns lying about.
static func drop_player(p: Node3D) -> void:
	if p == null or not is_instance_valid(p) or not p.is_inside_tree() or not p.has_method("current"):
		return
	var feet := p.global_position
	var up := _up_at(feet)
	var v: Vector3 = p.call("hud_velocity") if p.has_method("hud_velocity") else Vector3.ZERO
	var held = p.call("current")
	var k := 0
	if held != null and is_gun(held):
		_drop_carried(held, feet + up * 1.1, v.limit_length(6.0) * 0.4 + up * 1.6 + _jitter(up, 1.0))
		k += 1
	var list = p.get("items")
	if not (list is Array):
		return
	for it in list:
		if it == null or it == held or not is_gun(it) or not Game.is_loot_gun(str(it.get("item_id"))):
			continue
		_drop_carried(it, feet + up * (1.1 + 0.3 * float(k)), up * 1.8 + _jitter(up, 2.0))
		k += 1


## One carried gun of a dying player: a loadout gun drops a copy with WDROP_RESERVE_MAGS of reserve; a
## loot gun drops with ALL the reserve of its ammo (taken off the player) unless a loadout gun shares
## that ammo (then the same half magazine).
static func _drop_carried(it: Object, pos: Vector3, vel: Vector3) -> void:
	var gid := str(it.get("item_id"))
	var aid := gun_ammo_id(it)
	if not Game.is_loot_gun(gid) or aid == "" or _loadout_ammo(aid):
		drop_gun(it, pos, vel, Balance.WDROP_RESERVE_MAGS)
		return
	var state: Dictionary = it.call("save_state") if it.has_method("save_state") else {}
	var reserve := Game.ammo_reserve(aid)
	Game.ammo[aid] = 0
	Game.ammo_changed.emit()
	drop_data(make_data(gid, pos, vel, state, aid, reserve))


## Whether ammo `aid` belongs to a loadout gun too (Game.crafted; Balance.CRAFT_RESERVE lists its ammo).
static func _loadout_ammo(aid: String) -> bool:
	for gid in Game.crafted:
		if (Balance.CRAFT_RESERVE.get(gid, {}) as Dictionary).has(aid):
			return true
	return false


## A rival bot died (ai_rival.gd _die): its rifle drops. Host / single player only.
static func drop_bot(bot: Node3D) -> void:
	if Net.is_client() or bot == null or not is_instance_valid(bot) or not bot.is_inside_tree():
		return
	var it = _local_item("rifle")
	var state := {}
	var cap := 30
	if it != null:
		cap = _mag_cap(it)
		state = _with_mag_frac(it, it.call("save_state"), randf_range(Balance.WDROP_BOT_MAG.x, Balance.WDROP_BOT_MAG.y))
		state.erase("att")                 # a bot's rifle: none of the player's attachments (attachments.gd)
	var up := _up_at(bot.global_position)
	var bv = bot.get("velocity")
	var vel: Vector3 = (bv as Vector3).limit_length(6.0) * 0.3 if bv is Vector3 else Vector3.ZERO
	drop_data(make_data("rifle", bot.global_position + up * 1.1, vel + up * 1.8 + _jitter(up, 1.0), state, "ammo_std",
			maxi(int(roundf(float(cap) * Balance.WDROP_RESERVE_MAGS)), 1)))


## Multiplayer client: the host's gun `p_id` (drop_spawned / a late join's snapshot).
static func spawn_mirror(p_id: int, d: Dictionary, age := 0.0) -> Node3D:
	var old = find(p_id)
	if old != null:
		return old
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var n = _make(tree.current_scene, p_id, d, true)
	n._age = age
	return n


## Host: someone takes gun `p_id` (TAKER_LOCAL / TAKER_PEER). Returns its data with the current
## position ({} = already gone). The local player gets it here; the peer through taken() on his side.
static func claim(p_id: int, by: String) -> Dictionary:
	var w = find(p_id)
	if w == null or w.mirror or w._gone:
		return {}
	var d: Dictionary = w.data.duplicate(true)
	d["pos"] = w._where()
	_all.erase(p_id)
	w._vanish()
	if by == TAKER_LOCAL:
		_grant_local(d)
	events().drop_taken.emit(p_id, by)
	return d


## Multiplayer client: the host says gun `p_id` is gone; by_me: our player got it (d: the host's
## claim data when our mirror is already gone; else the mirror's own).
static func taken(p_id: int, by_me: bool, d: Dictionary = {}) -> void:
	var w = find(p_id)
	var got: Dictionary = d.duplicate(true)
	if w != null:
		if got.is_empty():
			got = w.data.duplicate(true)
			got["pos"] = w._where()
		_all.erase(p_id)
		w._vanish()
	if by_me and not got.is_empty():
		_grant_local(got)


static func find(p_id: int) -> Node3D:
	var w = _all.get(p_id)
	if w == null or not is_instance_valid(w) or w.is_queued_for_deletion() or w._gone:
		_all.erase(p_id)
		return null
	return w


## Every live gun of the host: [[id, data (pos = where it lies now), age], ...] (a late join).
static func snapshot() -> Array:
	var out: Array = []
	for w in _list():
		if not w.mirror:
			var d: Dictionary = w.data.duplicate(true)
			d["pos"] = w._where()
			d["vel"] = Vector3.ZERO
			out.append([w.id, d, w._age])
	return out


# --- Local player: focus, prompt, F hold ------------------------------------------------------------

## Every frame from player.gd (on foot): focus the nearest gun around the feet; F held takes it.
static func local_tick(p: Node3D, delta: float) -> void:
	var best = null
	if p != null and is_instance_valid(p) and _can_take(p):
		var feet := p.global_position
		var up := _up_at(feet)
		var best_d := INF
		for w in _list():
			if float(w._age) < SETTLE:
				continue
			var rel: Vector3 = (w as Node3D).global_position - feet
			var h := rel.dot(up)
			if h < -1.0 or h > 1.8:
				continue
			var dist := (rel - up * h).length()
			if dist <= Balance.WDROP_PICKUP_R and dist < best_d:
				best = w
				best_d = dist
	var fid: int = best.id if best != null else -1
	if fid != _focus_id:
		_focus_id = fid
		_hold = 0.0
		_armed = false
	var down := Input.is_action_pressed("interact") and not Game.ui_panel_open()
	if best == null or not down:
		_hold = 0.0
		_armed = best != null           # F has to go down while this gun is focused
		return
	if not _armed:
		return
	_hold += delta
	if _hold >= Balance.WDROP_HOLD:
		_hold = 0.0
		_armed = false
		best._take_local()


## The focused gun's prompt ("" = none). player.gd shows it when nothing else is aimed at.
static func prompt_text() -> String:
	var w = find(_focus_id)
	if w == null:
		return ""
	var gid := str(w.data.get("item", ""))
	var nm := item_name(gid)
	if Game.can_hold(gid):
		return "[F basılı tut] Mermi al (+%d) — %s" % [_rounds(w.data), nm]
	return "[F basılı tut] %s al  ·  ganimet" % nm


## 0..1 of the F hold on the focused gun (-1: nothing focused).
static func hold_progress() -> float:
	if find(_focus_id) == null:
		return -1.0
	return clampf(_hold / maxf(Balance.WDROP_HOLD, 0.05), 0.0, 1.0)


# --- Helpers ----------------------------------------------------------------------------------------

## A gun (not the drill / build tool / bare hands).
static func is_gun(it: Object) -> bool:
	if it == null:
		return false
	var gid := str(it.get("item_id"))
	return gid != "" and not (gid in Game.FREE_ITEMS)


## The ammo id the gun's reserve is counted in (the rifle: its loaded type).
static func gun_ammo_id(it: Object) -> String:
	var a = it.get("ammo_id")
	if a is String and a != "":
		return a
	var am = it.get("AMMO")
	var t = it.get("ammo_type")
	if am is Array and t is int and int(t) >= 0 and int(t) < (am as Array).size() and am[t] is Dictionary:
		return str((am[t] as Dictionary).get("id", ""))
	return ""


## Rounds loaded in a save_state() (the rifle: the loaded type's magazine).
static func state_rounds(st: Dictionary) -> int:
	var m = st.get("mags")
	if m is Array:
		var i := int(st.get("ammo", 0))
		return int(m[i]) if i >= 0 and i < (m as Array).size() else 0
	return int(st.get("mag", 0))


## The display name of gun `gid` (the local player's item, else a fallback).
static func item_name(gid: String) -> String:
	var it = _local_item(gid)
	if it != null:
		var sn = it.get("short_name")
		if sn is String and sn != "" and str(it.get("item_name")).length() > 16:
			return sn
		return str(it.get("item_name"))
	return str(NAMES.get(gid, gid))


static func _local_item(gid: String) -> Object:
	var p = Game.player
	if p == null or not is_instance_valid(p) or gid == "":
		return null
	var list = p.get("items")
	if not (list is Array):
		return null
	for it in list:
		if it != null and str(it.get("item_id")) == gid:
			return it
	return null


static func _mag_cap(it: Object) -> int:
	if it != null and it.has_method("mag_capacity"):
		return maxi(int(it.call("mag_capacity")), 1)
	return 10


## A copy of `st` with every magazine k full (the rifle: its standard type loaded).
static func _with_mag_frac(it: Object, st: Dictionary, k: float) -> Dictionary:
	var out := st.duplicate(true)
	if out.has("mag"):
		out["mag"] = clampi(int(roundf(float(_mag_cap(it)) * k)), 1, _mag_cap(it))
	var m = out.get("mags")
	if m is Array:
		var arr: Array = m
		for i in arr.size():
			var cap := maxi(int(it.call("mag_capacity", i)), 1) if it.has_method("mag_capacity") else 10
			arr[i] = clampi(int(roundf(float(cap) * k)), 1, cap) if i == 0 else 0
		out["mags"] = arr
		out["ammo"] = 0
	return out


static func _rounds(d: Dictionary) -> int:
	var st = d.get("state")
	return int(d.get("reserve", 0)) + (state_rounds(st) if st is Dictionary else 0)


static func _can_take(p: Node3D) -> bool:
	if not p.is_inside_tree() or (p.has_method("is_dead") and p.call("is_dead")) or p.get("vehicle") != null:
		return false
	if p.has_method("is_ragdolled") and p.call("is_ragdolled"):
		return false
	if p.get("interact_target") != null:
		return false                     # (looking at a door / a structure: F is that one's)
	return true


## A random sideways velocity (tangent to `up`) of up to k m/s.
static func _jitter(up: Vector3, k: float) -> Vector3:
	var v := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
	v -= up * v.dot(up)
	return v.limit_length(1.0) * k


static func _list() -> Array:
	var out: Array = []
	for k in _all.keys():
		var w = _all[k]
		if w == null or not is_instance_valid(w) or w.is_queued_for_deletion() or w._gone:
			_all.erase(k)
			continue
		out.append(w)
	return out


## A gun node; added deferred (a kill may come from inside a physics query).
static func _make(scene: Node, p_id: int, d: Dictionary, is_mirror: bool) -> Node3D:
	var n = load(PATH).new()
	n.id = p_id
	n.data = d.duplicate(true)
	n.mirror = is_mirror
	var pos = d.get("pos")
	n._spawn_pos = pos if pos is Vector3 else Vector3.ZERO
	var vel = d.get("vel")
	n._vel = vel if vel is Vector3 else Vector3.ZERO
	_all[p_id] = n
	scene.add_child.call_deferred(n)
	return n


## The local player gets the gun (player.gd swaps it in).
static func _grant_local(d: Dictionary) -> void:
	var p = Game.player
	if p != null and is_instance_valid(p) and p.has_method("take_dropped_gun"):
		p.call("take_dropped_gun", d)


# =================================================================================================
# The gun on the ground
# =================================================================================================

func _ready() -> void:
	if _gone:                              # (taken before it was even added)
		queue_free()
		return
	_build()
	global_transform = Transform3D(_frame(_up_at(_spawn_pos)), _spawn_pos)
	if not mirror:
		Game.blast.connect(_on_blast)


func _where() -> Vector3:
	if _ri_on:
		return _ri_to                      # (the sim position, not the drawn one)
	return global_position if is_inside_tree() else _spawn_pos


func _physics_process(delta: float) -> void:
	if _gone:
		return
	if _ri_on:                             # (the sim position back: _process drew it between ticks)
		global_position = _ri_to
		_ri_on = false
	_age += delta
	if _age >= Balance.WDROP_TIME:
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


func _process(delta: float) -> void:
	if _gone or _vis == null:
		return
	if _ri_on:                             # falling: drawn between the last two physics ticks
		global_position = _ri_from.lerp(_ri_to, clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0))
	var focus := id == _focus_id
	_focus_k = move_toward(_focus_k, 1.0 if focus else 0.0, delta * 6.0)
	# The last WDROP_BLINK s: blinking, faster toward the end.
	var left := Balance.WDROP_TIME - _age
	var on := true
	if left < Balance.WDROP_BLINK:
		var hz := lerpf(6.0, 2.0, clampf(left / maxf(Balance.WDROP_BLINK, 0.1), 0.0, 1.0))
		on = fmod(_age * hz, 1.0) < 0.62
	_vis.visible = on
	_light.visible = on
	_light.light_energy = 0.55 + 0.6 * _focus_k
	_ring.visible = on and _resting
	var pulse := 1.0 + 0.06 * sin(_age * 3.0) + 0.12 * _focus_k
	_ring.scale = Vector3(pulse, 0.2, pulse)
	_ring_mat.albedo_color = Color(_col.r, _col.g, _col.b, 0.32 + 0.4 * _focus_k)
	# Name and magazine near the camera only, fading in over the last 2 m.
	var cam := get_viewport().get_camera_3d()
	var d := cam.global_position.distance_to(global_position) if cam != null else INF
	var lr: float = Balance.WDROP_LABEL_R * (0.45 if Game.hud_mode() == 0 else 1.0)    # (HUD Sade: up close or aimed at)
	var a := maxf(clampf((lr - d) / 2.0, 0.0, 1.0), _focus_k)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("is_dead") and pl.is_dead():
		a = 0.0                              # (not in the death camera / the respawn ride)
	_label.visible = on and a > 0.0
	if _label.visible:
		_label.modulate.a = a
		_label.outline_modulate.a = 0.7 * a
		_label.pixel_size = 0.0026 * (1.0 + 0.2 * _focus_k)


## One physics step through the air; lands on the terrain collision or, where none is built, on the
## exact density surface (as loot.gd).
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
		# A wall or a tunnel ceiling: lose the speed into it and keep falling.
		_vel -= n * minf(_vel.dot(n), 0.0)
		_vel *= 0.8
		_set_at(hp + n * 0.03)
		return
	var vn := -_vel.dot(up)
	if vn > BOUNCE_V and _bounces < 2:
		_bounces += 1
		_vel = (_vel - up * _vel.dot(up)) * 0.4 + up * vn * 0.25
		_set_at(hp + up * 0.02)
		if Game.sfx and _bounces == 1 and cam_near(14.0):
			Game.sfx.play_at("impact_light", hp, -10.0, randf_range(1.3, 1.6), 6.0)
		return
	_set_at(hp)
	_vel = Vector3.ZERO
	_walls = 0
	_resting = true
	_check_t = CHECK_PERIOD


func cam_near(r: float) -> bool:
	var cam := get_viewport().get_camera_3d()
	return cam != null and cam.global_position.distance_to(global_position) < r


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
	q.hit_back_faces = false
	if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return true
	var body: Node3D = Game.dominant_body(p)
	if body == null or not body.has_method("density_at"):
		return false
	return float(body.density_at(p - up * 0.15)) < 0.0


func _set_at(p: Vector3) -> void:
	global_transform = Transform3D(_frame(_up_at(p)), p)


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
		events().drop_expired.emit(id)
	_vanish()


## Gone (taken / expired): a quick shrink, then freed.
func _vanish() -> void:
	if _gone:
		return
	_gone = true
	if not is_inside_tree():
		return                             # (_ready frees it)
	_label.visible = false
	_ring.visible = false
	_light.visible = false
	var tw := create_tween()
	tw.tween_property(_vis, "scale", Vector3.ONE * 0.05, 0.14).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)


# =================================================================================================
# Look
# =================================================================================================

func _build() -> void:
	var gid := str(data.get("item", ""))
	var it = _local_item(gid)
	if it != null and it.has_method("accent_color"):
		var ac = it.call("accent_color")
		if ac is Color:
			_col = ac
	_vis = Node3D.new()
	add_child(_vis)
	var yaw := Node3D.new()
	yaw.rotation.y = fmod(float(id) * 2.399, TAU)       # (the same on every machine)
	_vis.add_child(yaw)
	var m := _gun_model(gid)
	# The attachments the gun had fitted (its save_state "att"; scripts/items/attachments.gd), not the
	# ones the copied prop shows right now.
	var dst = data.get("state")
	var att = load("res://scripts/items/attachments.gd")
	if att != null:
		att.dress_tp(m, gid, (dst as Dictionary).get("att", {}) if dst is Dictionary else {})
	yaw.add_child(m)
	# Lying on its left side (the gun's +X up, the barrel horizontal), centred over the ring, its
	# lowest point just on the ground.
	var bb := _bounds(m)
	var c := bb.get_center()
	var b := Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1))
	m.transform = Transform3D(b, Vector3(c.y, -bb.position.x + 0.01, -c.z))
	var half := maxf(bb.size.z * 0.5, 0.3)
	var tm := TorusMesh.new()
	tm.inner_radius = half + 0.02
	tm.outer_radius = half + 0.08
	tm.rings = 48
	tm.ring_segments = 4
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ring_mat.albedo_color = Color(_col.r, _col.g, _col.b, 0.32)
	_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring = MeshInstance3D.new()
	_ring.mesh = tm
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.position = Vector3(0.0, 0.03, 0.0)
	_ring.scale = Vector3(1.0, 0.2, 1.0)
	_ring.visibility_range_end = 120.0
	add_child(_ring)
	_light = OmniLight3D.new()
	_light.light_color = _col
	_light.light_energy = 0.55
	_light.omni_range = 1.8
	_light.shadow_enabled = false
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = 25.0
	_light.distance_fade_length = 8.0
	_light.position = Vector3(0.0, 0.4, 0.0)
	add_child(_light)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 56
	_label.pixel_size = 0.0026
	_label.outline_size = 14
	_label.modulate = _col.lerp(Color.WHITE, 0.55)
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.7)
	_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_label.position = Vector3(0.0, 0.55, 0.0)
	_label.visible = false
	var st = data.get("state")
	var mag := state_rounds(st) if st is Dictionary else 0
	_label.text = "%s  ·  %d" % [item_name(gid), mag]
	add_child(_label)


## The gun's third-person model: the astronaut prop of that gun (as players and bots hold it), else
## its _build_tp, else a plain box.
func _gun_model(gid: String) -> Node3D:
	var it = _local_item(gid)
	var p = Game.player
	if p != null and is_instance_valid(p):
		var ast = p.get("astronaut")
		var props = ast.get("props") if ast != null else null
		var key := str(it.get("icon")) if it != null else gid
		if props is Dictionary and (props as Dictionary).has(key):
			var src = props[key]
			if src is Node3D and is_instance_valid(src):
				var dup := (src as Node3D).duplicate() as Node3D
				if dup != null:
					_prep(dup)
					return dup
	if it != null and it.has_method("_build_tp"):
		var root := Node3D.new()
		it.call("_build_tp", root)
		_prep(root)
		return root
	var box := Node3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.1, 0.62)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.21, 0.23)
	mat.metallic = 0.6
	mat.roughness = 0.4
	mi.material_override = mat
	mi.position = Vector3(0, 0.05, -0.25)
	box.add_child(mi)
	_prep(box)
	return box


## A world prop: seen by every camera, casting shadows, faded out far away.
static func _prep(root: Node3D) -> void:
	root.transform = Transform3D.IDENTITY
	root.visible = true
	for n in root.find_children("*", "VisualInstance3D", true, false):
		(n as VisualInstance3D).layers = 1
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			(n as GeometryInstance3D).visibility_range_end = 120.0


## The bounds of every mesh under root, in root's own frame.
static func _bounds(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var c: Node = mi
		var shown := true
		while c != null and c != root:
			if c is Node3D:
				xf = (c as Node3D).transform * xf
				shown = shown and (c as Node3D).visible     # (hidden attachment parts do not count)
			c = c.get_parent()
		if not shown:
			continue
		var bb: AABB = xf * mi.mesh.get_aabb()
		if first:
			out = bb
			first = false
		else:
			out = out.merge(bb)
	if first:
		out = AABB(Vector3(-0.04, -0.05, -0.6), Vector3(0.08, 0.15, 0.75))
	return out


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
