extends Node3D
## İkmal kapsülü (supply pod, 2026-10-06; the user: crafting guns at the Silahlık slowed the game
## down). A power weapon (Balance.SUPPLY_GUNS, priced in SUPPLY_COST) is called in anywhere for
## material (the menu: scripts/war/supply_menu.gd, Tab). A small white / orange capsule (an enemy's:
## dark with red bands) drops from SUPPLY_ALT m up on a scripted, slanted path, brakes on its retro
## jets and touches down SUPPLY_DELAY s after the call, SUPPLY_DIST m from the caller (in front of him
## first, clear of structures); SUPPLY_GUN_POP s later its lid blows off and the gun pops out as an
## ordinary ground pickup (scripts/war/weapon_drop.gd: hold F; a loot gun, lost on death) with a full
## magazine and SUPPLY_RESERVE × its CRAFT_RESERVE. The empty pod stays SUPPLY_WRECK_TIME s as cover.
## Everyone sees it come: a halo and a smoke trail in flight, a light beam over the landing spot; the
## caller's side also reads "İKMAL · 5" over it (through the ground).
## Air defence (chosen: YES, a counter to power weapons): in flight it is in groups "war_shell"
## (team / vel / is_live() / shot_down(pos): enemy Uçaksavar bursts and point defence, the armed skiff,
## the Kinetik İtici) and "war_drop_pod" (the unmanned Uçaksavar and the Otomatik Taret engage it;
## linear_velocity), like the rival's troop pod (scripts/war/drop_pod.gd, not touched; net_id stays -1
## so net_drops.gd never takes it for one). SUPPLY_HITS hits destroy it: no gun, no refund.
## The path is a function of time in the landing planet's frame (the same on every machine): it falls
## at ~24-29 m/s along a slant that turns vertical over the last ~40 m, then brakes from ~25 m to
## SUPPLY_LAND_SPEED over SUPPLY_RETRO_T s.
##
## API (static; the local player's call)
##   SupplyPod.cost(gun) -> float           SUPPLY_COST less the Silahlık's İkmal indirimi (UPG_POD_*)
##   SupplyPod.cooldown_left() -> float     SupplyPod.cooldown_total() -> float
##   SupplyPod.blocked(gun) -> String       why it cannot be called now ("" = it can; not the spot)
##   SupplyPod.call_in(gun) -> String       finds the spot, pays (co-op: the team pool), starts the
##                                          cooldown, sends the pod ("" or why not)
##   SupplyPod.gun_name(gun) -> String      SupplyPod.mine_incoming() -> [{gun, left}]
##   SupplyPod.reset()                      a new match (Game.reset_state)
##   SupplyPod.tick()                       per frame (scripts/war/supply_menu.gd): a client's
##                                          unanswered request is paid back after SUPPLY_REPLY_TIMEOUT
## Multiplayer (host authoritative; single player never touches it). SupplyPod.events():
##   pod_spawned(id, data)        host: a pod is coming (its own or a client's) -> client: spawn_mirror(id, data)
##   pod_landed(id, pos)          host: touchdown                               -> client: net_land(id, pos)
##   pod_destroyed(id, pos)       host: shot down                               -> client: net_destroy(id, pos)
##   call_requested(req, gun, to) client: our player called (already paid)      -> host: host_request(req, gun, to)
##                                returns "" (accepted: its pod_spawned carries data.req = req) or why
##                                not                                            -> client: refused(req, why)
##   snapshot() -> [[id, data], ...]   host: pods still in flight for a late joiner (spawn_mirror each;
##                                landed ones are left out: the gun itself is a WeaponDrop, synced).
## data: plain values {"gun", "side" (ABSOLUTE side: 0 Yurt / 1 Rakip, Net.abs_side; spawn_mirror
##   turns it into the local team), "to" (world: the ground point), "dir" (world unit tangent it
##   slants in from), "land_in" (s), "req" (the client's request id; -1 = the host's own)}. The gun
##   pops out through WeaponDrop.drop_data on the host (already synced: wdrop).

const Balance := preload("res://scripts/war/balance.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # the beacon's "İKMAL" tag: HudLevel.label_alpha
const DigFx := preload("res://scripts/items/dig_fx.gd")
const FlakRound := preload("res://scripts/war/flak_round.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const WeaponDrop := preload("res://scripts/war/weapon_drop.gd")
const PATH := "res://scripts/war/supply_pod.gd"

const GROUP := "war_drop_pod"
const HALF_H := 0.85                   # capsule centre to the shield / the lid
const RADIUS := 0.52                   # at the shield
const SINK := 0.2                      # m the landed pod sits in the ground
const HOME_HULL := Color(0.88, 0.89, 0.88)
const HOME_BAND := Color(1.0, 0.55, 0.18)
const ENEMY_HULL := Color(0.22, 0.21, 0.21)
const ENEMY_BAND := Color(1.0, 0.25, 0.15)

class SupplyEvents extends RefCounted:
	signal pod_spawned(id: int, data: Dictionary)
	signal pod_landed(id: int, pos: Vector3)
	signal pod_destroyed(id: int, pos: Vector3)
	signal call_requested(req: int, gun: String, to: Vector3)

static var _events: SupplyEvents
static var _all := {}                  # id -> pod (host: real; client: mirrors)
static var _next_id := 1
static var _next_req := 1
static var _pending := {}              # client: req -> {"gun", "cost", "ms"}
static var _cool_until := 0            # the local player's next call (Time msec)
static var _peer_ms := -10000000       # host: the client's last accepted call

var id := 0
var data := {}
var mirror := false                    # a client's copy of the host's pod
var local_owner := false               # called by this machine's player
var team := "home"
var gun := ""
var vel := Vector3.ZERO
var net_id := -1                       # (not a troop pod: net_drops.gd never matches it)
var net_puppet := false
## The unmanned Uçaksavar / the turret read a target's velocity as linear_velocity.
var linear_velocity: Vector3:
	get:
		return vel

var _body: Node3D
var _to_l := Vector3.ZERO              # the landing point in the body's frame
var _dir_l := Vector3.ZERO             # the slant direction in the body's frame
var _total := 7.0
var _life := 0.0
var _done := false                     # landed, destroyed: no longer an air target
var _landed := false
var _popped := false
var _hits := 0
var _retro := false
var _spin := 0.0
var _vis: Node3D
var _lid: Node3D
var _jets: Array = []
var _jet_p: CPUParticles3D
var _trail: GPUParticles3D
var _halo: MeshInstance3D
var _light: OmniLight3D
var _roar: AudioStreamPlayer3D
var _burn: AudioStreamPlayer3D
var _accent: StandardMaterial3D
var _col: StaticBody3D
var _beacon: Node3D
var _beam_mat: StandardMaterial3D
var _ring_mat: StandardMaterial3D
var _tag: Label3D
var _beacon_a := 1.0


static func events() -> SupplyEvents:
	if _events == null:
		_events = SupplyEvents.new()
	return _events


# =================================================================================================
# API (static)
# =================================================================================================

## A new match: no cooldown, no open request (the old scene's pods go with it).
static func reset() -> void:
	_pending = {}
	_cool_until = 0
	_peer_ms = -10000000
	_all = {}


static func gun_name(g: String) -> String:
	return WeaponDrop.item_name(g)


## The share off the price from the Silahlık's İkmal indirimi.
static func discount() -> float:
	var lv := clampi(Game.upgrade_level("pod"), 0, Balance.UPG_POD_DISCOUNT.size() - 1)
	return float(Balance.UPG_POD_DISCOUNT[lv])


static func cost(g: String) -> float:
	return roundf(float(Balance.SUPPLY_COST.get(g, 0.0)) * (1.0 - discount()))


static func cooldown_left() -> float:
	return maxf(float(_cool_until - Time.get_ticks_msec()) / 1000.0, 0.0)


static func cooldown_total() -> float:
	return Balance.SUPPLY_COOLDOWN


## A multiplayer client waits for the host's word on a call.
static func waiting() -> bool:
	return not _pending.is_empty()


## Why the local player cannot call `g` right now ("" = he can). The landing spot is checked by call_in.
static func blocked(g: String) -> String:
	if not (g in Balance.SUPPLY_GUNS):
		return "Bilinmeyen silah"
	if Game.match_over:
		return "Maç bitti"
	var p = Game.player
	if p == null or not is_instance_valid(p) or (p.has_method("is_dead") and p.is_dead()) or p.get("vehicle") != null:
		return "Yalnızca yayayken çağrılır"
	if not _pending.is_empty():
		return "İstek gönderildi…"
	var cl := cooldown_left()
	if cl > 0.05:
		return "İkmal hazırlanıyor: %d sn" % ceili(cl)
	if Game.can_hold(g):
		return "Zaten elinde"
	var c := cost(g)
	if Game.material + 0.001 < c:
		return "Yetersiz malzeme: %d m³ eksik" % int(ceilf(c - Game.material))
	return ""


## The local player calls `g` in. Returns "" (on its way / requested) or why not.
static func call_in(g: String) -> String:
	var why := blocked(g)
	if why != "":
		return why
	var spot := find_spot(Game.player)
	if spot.has("why"):
		return str(spot["why"])
	var c := cost(g)
	if not Game.spend_material(c):
		return "Yetersiz malzeme"
	_cool_until = Time.get_ticks_msec() + int(Balance.SUPPLY_COOLDOWN * 1000.0)
	var to: Vector3 = spot["pos"]
	if Game.sfx:
		Game.sfx.play("craft", -6.0, 0.9)
	if Net.is_client():
		var req := _next_req
		_next_req += 1
		_pending[req] = {"gun": g, "cost": c, "ms": Time.get_ticks_msec()}
		events().call_requested.emit(req, g, to)
		toast("İkmal kapsülü istendi: %s" % gun_name(g), 2.2, 0)
		return ""
	_spawn_host(_data(g, "home", to, Balance.SUPPLY_DELAY, -1), true)
	toast("İkmal kapsülü yolda: %s  ·  %d sn" % [gun_name(g), int(roundf(Balance.SUPPLY_DELAY))], 2.6)
	return ""


## The local player's pods still in flight: [{"gun", "left"}].
static func mine_incoming() -> Array:
	var out: Array = []
	for k in _all.keys():
		var n = _all[k]
		if n == null or not is_instance_valid(n) or not n.local_owner or n._landed or n._done:
			continue
		out.append({"gun": n.gun, "left": maxf(n._total - n._life, 0.0)})
	return out


## Per frame (the menu node): a client's request the host never answered is paid back.
static func tick() -> void:
	if _pending.is_empty():
		return
	var now := Time.get_ticks_msec()
	for req in _pending.keys():
		if now - int(_pending[req]["ms"]) > int(Balance.SUPPLY_REPLY_TIMEOUT * 1000.0):
			refused(int(req), "sunucu yanıt vermedi")


## Where a pod called by `p` lands: {"pos": the ground point (world), "body"} or {"why": reason}.
static func find_spot(p) -> Dictionary:
	if p == null or not is_instance_valid(p) or not (p is Node3D):
		return {"why": "Kapsül çağrılamaz"}
	var feet: Vector3 = (p as Node3D).global_position
	var body: Node3D = Game.dominant_body(feet)
	if body == null or not body.has_method("raycast_density"):
		return {"why": "Kapsül buraya inemez"}
	var c := body.global_position
	var up := (feet - c).normalized()
	var g := _surface(body, up)
	if g.is_empty():
		return {"why": "Kapsül buraya inemez"}
	if (g["position"] as Vector3).distance_to(c) - feet.distance_to(c) > Balance.SUPPLY_MAX_DEPTH:
		return {"why": "Yer altındasın: kapsül inemez, yüzeye çık"}
	var cam = p.get("camera")
	var fwd: Vector3 = -(cam as Node3D).global_transform.basis.z if cam is Node3D else -(p as Node3D).global_transform.basis.z
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	fwd = fwd.normalized()
	var avoid := _obstacles()
	var dn := Balance.SUPPLY_DIST
	for d in [lerpf(dn.x, dn.y, 0.3), dn.x, lerpf(dn.x, dn.y, 0.65), dn.y]:
		for a in [0.0, 35.0, -35.0, 70.0, -70.0, 110.0, -110.0, 150.0, -150.0, 180.0]:
			var n := (feet + fwd.rotated(up, deg_to_rad(a)) * float(d) - c).normalized()
			var h := _surface(body, n)
			if h.is_empty() or (h["normal"] as Vector3).dot(n) < 0.35:
				continue                       # (nothing / a steep wall or an overhang)
			var pos: Vector3 = h["position"]
			var ok := true
			for o: Array in avoid:
				if pos.distance_to(o[0]) < float(o[1]):
					ok = false
					break
			if ok:
				return {"pos": pos, "body": body}
	return {"why": "İniş yeri yok: açık bir yere çık"}


## Host: a client's call (call_requested; it paid on its side). "" = accepted (its pod_spawned carries
## data.req = req), else why not (send it back: the client's refused(req, why) pays back).
static func host_request(req: int, g: String, to: Vector3) -> String:
	if Net.is_client():
		return "Yalnızca sunucu"
	if not (g in Balance.SUPPLY_GUNS):
		return "Bilinmeyen silah"
	if Game.match_over:
		return "Maç bitti"
	var now := Time.get_ticks_msec()
	if now - _peer_ms < int(Balance.SUPPLY_COOLDOWN * Balance.SUPPLY_HOST_GAP * 1000.0):
		return "İkmal hazırlanıyor"
	var body: Node3D = Game.dominant_body(to)
	if body == null or not body.has_method("raycast_density"):
		return "İniş yeri yok"
	var gh := _surface(body, (to - body.global_position).normalized())
	if gh.is_empty() or (gh["position"] as Vector3).distance_to(to) > 3.0:
		return "İniş yeri değişti"
	_peer_ms = now
	_spawn_host(_data(g, Net.local_team(Net.other_side()), gh["position"], Balance.SUPPLY_DELAY, req), false)
	return ""


## Client: the host's pod `p_id` (pod_spawned / a late join's snapshot).
static func spawn_mirror(p_id: int, d: Dictionary) -> Node3D:
	var old = find(p_id)
	if old != null:
		return old
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var req := int(d.get("req", -1))
	var mine := req >= 0 and _pending.has(req)
	if mine:
		_pending.erase(req)
		toast("İkmal kapsülü yolda: %s  ·  %d sn" % [gun_name(str(d.get("gun", ""))), ceili(float(d.get("land_in", 0.0)))], 2.6)
	return _make(tree.current_scene, p_id, d, true, mine)


static func net_land(p_id: int, pos: Vector3) -> void:
	var n = find(p_id)
	if n != null:
		n._net_land(pos)


static func net_destroy(p_id: int, pos: Vector3) -> void:
	var n = find(p_id)
	if n != null:
		n._net_destroy(pos)


## Client: the host refused request `req`: the price comes back, the cooldown clears.
static func refused(req: int, why: String) -> void:
	var e = _pending.get(req)
	if e == null:
		return
	_pending.erase(req)
	Game.add_material(float(e["cost"]))
	_cool_until = 0
	toast("İkmal kapsülü gelmedi: %s  (+%d m³ iade)" % [why, int(e["cost"])], 3.0)
	if Game.sfx:
		Game.sfx.play("error", -10.0)


static func find(p_id: int) -> Node3D:
	var n = _all.get(p_id)
	if n == null or not is_instance_valid(n) or n.is_queued_for_deletion():
		_all.erase(p_id)
		return null
	return n


## Host: every pod still in flight: [[id, data (land_in = the time left)], ...] (a late join).
static func snapshot() -> Array:
	var out: Array = []
	for k in _all.keys():
		var n = find(int(k))
		if n == null or n.mirror or n._done:
			continue
		var d: Dictionary = n.data.duplicate(true)
		d["land_in"] = maxf(n._total - n._life, 0.5)
		out.append([n.id, d])
	return out


## One line of the HUD's alert channel for every pod message (key "supply": a newer one replaces it).
static func toast(s: String, t := 2.5, pri := 1) -> void:
	if Game.hud != null and is_instance_valid(Game.hud):
		if Game.hud.has_method("alert"):
			Game.hud.alert(s, pri, "supply", t)
		else:
			Game.hud.show_message(s, t)


# --- Helpers ----------------------------------------------------------------------------------------

## The open ground straight above direction n from the body's centre: {"position", "normal"} or {}.
static func _surface(body: Node3D, n: Vector3) -> Dictionary:
	var c := body.global_position
	var r := float(body.get("radius"))
	var top := r + float(body.get("max_height")) + 6.0
	return body.raycast_density(c + n * top, c + n * maxf(r - 20.0, 1.0), 0.6, true)


## [position, keep-out radius] of what a pod must not land on.
static func _obstacles() -> Array:
	var out: Array = []
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return out
	for n in tree.get_nodes_in_group("war_structure"):
		if n is Node3D and is_instance_valid(n):
			out.append([(n as Node3D).global_position, float(n.get_meta("footprint_r", 3.0)) + Balance.SUPPLY_CLEAR])
	for g: Array in [["skiff", 6.0], [GROUP, 2.0], ["respawn_ship", 8.0]]:
		for n in tree.get_nodes_in_group(str(g[0])):
			if n is Node3D and is_instance_valid(n):
				out.append([(n as Node3D).global_position, float(g[1]) + Balance.SUPPLY_CLEAR])
	return out


## The tangent a pod over `to` slants in from: away from the other planet (any tangent if degenerate).
static func _slant_dir(to: Vector3, body: Node3D) -> Vector3:
	var up := (to - body.global_position).normalized()
	var other: Node3D = Game.rival if body == Game.planet else Game.planet
	var away := Vector3.ZERO
	if other != null and is_instance_valid(other):
		away = to - other.global_position
	away -= up * away.dot(up)
	if away.length_squared() < 0.01:
		away = up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT)
	return away.normalized()


static func _data(g: String, p_team: String, to: Vector3, land_in: float, req: int) -> Dictionary:
	var body: Node3D = Game.dominant_body(to)
	return {"gun": g, "side": Net.abs_side(p_team), "to": to, "dir": _slant_dir(to, body) if body != null else Vector3.RIGHT,
			"land_in": land_in, "req": req}


static func _spawn_host(d: Dictionary, mine: bool) -> Node3D:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var p_id := _next_id
	_next_id += 1
	var n := _make(tree.current_scene, p_id, d, false, mine)
	events().pod_spawned.emit(p_id, d.duplicate(true))
	return n


static func _make(scene: Node, p_id: int, d: Dictionary, is_mirror: bool, mine: bool) -> Node3D:
	var n = load(PATH).new()
	n.id = p_id
	n.data = d.duplicate(true)
	n.mirror = is_mirror
	n.net_puppet = is_mirror
	n.local_owner = mine
	n.gun = str(d.get("gun", ""))
	n.team = Net.local_team(int(d.get("side", 0)))
	_all[p_id] = n
	scene.add_child(n)
	return n


# =================================================================================================
# The pod
# =================================================================================================

func _ready() -> void:
	top_level = true
	var to = data.get("to")
	var dir = data.get("dir")
	var to_w: Vector3 = to if to is Vector3 else Vector3.ZERO
	_body = Game.dominant_body(to_w)
	if _body == null:
		queue_free()
		return
	_to_l = _body.global_transform.affine_inverse() * to_w
	_dir_l = _body.global_transform.basis.inverse() * (dir if dir is Vector3 else Vector3.RIGHT)
	_total = maxf(float(data.get("land_in", Balance.SUPPLY_DELAY)), 1.0)
	add_to_group("war_shell")
	add_to_group(GROUP)
	_build_model()
	_build_fx()
	_build_beacon()
	global_position = _path_pos(0.0)
	vel = (_path_pos(0.05) - global_position) / 0.05
	_orient(0.0)


func _exit_tree() -> void:
	if _all.get(id) == self:
		_all.erase(id)


## Still flying (an air target).
func is_live() -> bool:
	return not _done


# --- Flight -------------------------------------------------------------------------------------------

func _retro_t() -> float:
	return minf(Balance.SUPPLY_RETRO_T, _total * 0.45)


## Height of the shield over the landing point at time t: a fall from 0.8 v to v, then the retro burn
## from v to SUPPLY_LAND_SPEED (v solves the two for SUPPLY_ALT; continuous in height and speed).
func _height(t: float) -> float:
	var tr := _retro_t()
	var tf := _total - tr
	var vl := Balance.SUPPLY_LAND_SPEED
	var vr := (Balance.SUPPLY_ALT - vl * tr * 0.5) / (0.9 * tf + tr * 0.5)
	if t < tf:
		var v0 := 0.8 * vr
		return Balance.SUPPLY_ALT - (v0 * t + 0.5 * ((vr - v0) / tf) * t * t)
	var s := minf(t - tf, tr)
	var hr := (vr + vl) * 0.5 * tr
	return maxf(hr - (vr * s - 0.5 * ((vr - vl) / tr) * s * s), 0.0)


func _path_pos(t: float) -> Vector3:
	var h := _height(t)
	var lat := Balance.SUPPLY_TILT * h * clampf(h / 40.0, 0.0, 1.0)
	var xf := _body.global_transform
	var to := xf * _to_l
	var up := (to - xf.origin).normalized()
	return to + up * (h + HALF_H - SINK) + (xf.basis * _dir_l).normalized() * lat


func _physics_process(delta: float) -> void:
	if _done:
		return
	if _body == null or not is_instance_valid(_body):
		_finish()
		return
	_life += delta
	var p := _path_pos(minf(_life, _total))
	vel = (p - global_position) / maxf(delta, 1e-4)
	global_position = p
	if not _retro and _life >= _total - _retro_t():
		_start_retro()
	_orient(delta)
	if _life >= _total:
		_touchdown()


func _process(delta: float) -> void:
	_tick_beacon(delta)


func _start_retro() -> void:
	_retro = true
	for j in _jets:
		(j as Node3D).visible = true
	_jet_p.emitting = true
	_light.light_energy = 4.0
	if _burn.stream != null:
		_burn.play()
	_oneshot(Snd.one("shuttle/boost"), 12.0, -4.0, 1.15)


## Shield first along the flight, slowly spinning; the retro flames flicker.
func _orient(delta: float) -> void:
	if vel.length_squared() < 0.25:
		return
	_spin += delta * (0.5 if _retro else 1.6)
	var y := -vel.normalized()
	var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := y.cross(ref).normalized()
	_vis.basis = Basis(x, y, x.cross(y)).rotated(y, _spin)
	if _retro:
		var k := 0.8 + 0.4 * randf()
		for j in _jets:
			(j as Node3D).scale = Vector3(1.0, k, 1.0)
		_light.light_energy = 3.5 + 1.5 * randf()


# --- Touchdown, the gun -------------------------------------------------------------------------------

func _touchdown() -> void:
	_done = true
	remove_from_group("war_shell")
	var to := _body.global_transform * _to_l
	var up := (to - _body.global_position).normalized()
	var point := to
	var normal := up
	var gh: Dictionary = _body.raycast_density(to + up * 4.0, to - up * 8.0, 0.25, false)
	if not gh.is_empty():
		point = gh["position"]
		normal = gh["normal"]
	_land_at(point, up, normal)
	if not mirror:
		events().pod_landed.emit(id, point)


## Client: the host's touchdown at `pos` (lands there, or moves there if it already landed).
func _net_land(pos: Vector3) -> void:
	if not is_inside_tree():
		return
	var up := (pos - _body.global_position).normalized() if _body != null and is_instance_valid(_body) else Vector3.UP
	if _landed:
		if global_position.distance_to(pos + up * (HALF_H - SINK)) > 0.6:
			global_position = pos + up * (HALF_H - SINK)
		return
	_done = true
	remove_from_group("war_shell")
	_land_at(pos, up, up)


func _land_at(point: Vector3, up: Vector3, normal: Vector3) -> void:
	_landed = true
	_done = true
	var stand := up
	if normal.dot(up) > 0.5:
		stand = (up * 0.8 + normal * 0.2).normalized()
	global_transform = Transform3D(_basis_up(stand, true), point + stand * (HALF_H - SINK))
	_vis.transform = Transform3D.IDENTITY
	vel = Vector3.ZERO
	_burn_off()
	_roar.stop()
	_trail.emitting = false
	_halo.visible = false
	create_tween().tween_property(_light, "light_energy", 0.0, 0.5)
	_oneshot(Snd.rand("impact/thud", 1.05, 1.0), 14.0, 0.0, 0.95)
	_oneshot(Snd.one("impact/metal_heavy_01"), 12.0, -4.0, 1.1)
	var soil: Color = _body.get("soil_color") if _body.get("soil_color") is Color else Color(0.5, 0.45, 0.4)
	BuildFx.dust(get_parent(), point, up, 2.2, soil)
	BuildFx.dust(get_parent(), point, up, 1.0, soil.lightened(0.15))
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var dpl: float = (pl as Node3D).global_position.distance_to(point)
		if dpl < 25.0:
			pl.add_trauma(0.3 * (1.0 - dpl / 25.0))
	# Cover for whoever fights around it.
	_col = StaticBody3D.new()
	_col.collision_layer = Game.LAYER_SHIP
	_col.collision_mask = 0
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = RADIUS - 0.08
	sh.height = HALF_H * 2.0
	cs.shape = sh
	_col.add_child(cs)
	add_child(_col)
	get_tree().create_timer(Balance.SUPPLY_GUN_POP).timeout.connect(_pop.bind(point, stand))
	get_tree().create_timer(Balance.SUPPLY_WRECK_TIME).timeout.connect(_sink_away)


## The lid blows off and the gun pops out (the host spawns it: WeaponDrop, synced).
func _pop(point: Vector3, up: Vector3) -> void:
	if not is_inside_tree() or _popped:
		return
	_popped = true
	if _lid != null:
		var tw := _lid.create_tween()
		tw.set_parallel(true)
		tw.tween_property(_lid, "position", _lid.position + Vector3(randf_range(-0.6, 0.6), 1.6, randf_range(0.6, 1.2)), 0.3) \
				.set_ease(Tween.EASE_OUT)
		tw.tween_property(_lid, "rotation", Vector3(randf_range(1.0, 2.2), randf_range(-1.0, 1.0), 0.0), 0.5)
		tw.chain().tween_property(_lid, "scale", Vector3.ONE * 0.01, 0.4).set_delay(1.2)
	_oneshot(Snd.one("shuttle/decompress"), 10.0, 0.0, 1.25)
	BuildFx.dust(get_parent(), point + up * 1.3, up, 0.9, Color(0.8, 0.8, 0.8))
	if not mirror and not Net.is_client():
		var out := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized().rotated(up, randf() * TAU)
		var cap := 1
		var it = _gun_item(gun)
		if it != null and it.has_method("mag_capacity"):
			cap = maxi(int(it.mag_capacity()), 1)
		var res: Dictionary = Balance.CRAFT_RESERVE.get(gun, {})
		var ammo_id := ""
		var reserve := 0
		for a in res:
			ammo_id = str(a)
			reserve = int(roundf(float(res[a]) * Balance.SUPPLY_RESERVE))
			break
		WeaponDrop.drop_data(WeaponDrop.make_data(gun, point + up * 1.2 + out * 0.8, up * 2.6 + out * 2.0, {"mag": cap},
				ammo_id, reserve))
	if local_owner:
		toast("İkmal kapsülü indi: %s  ·  [F basılı tut] al" % gun_name(gun), 3.0)
		if Game.sfx:
			Game.sfx.play("ding", -8.0, 1.1)


## The local player's item of gun `g` (its magazine size).
static func _gun_item(g: String) -> Object:
	var p = Game.player
	if p == null or not is_instance_valid(p) or not (p.get("items") is Array):
		return null
	for it in p.items:
		if it != null and str(it.get("item_id")) == g:
			return it
	return null


## The empty pod sinks into the ground and goes.
func _sink_away() -> void:
	if not is_inside_tree():
		return
	if _col != null:
		_col.queue_free()
		_col = null
	remove_from_group(GROUP)
	var tw := create_tween()
	tw.tween_property(self, "global_position", global_position - global_transform.basis.y * (HALF_H * 2.0 + 0.4), 3.0) \
			.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(queue_free)


# --- Air defence ----------------------------------------------------------------------------------------

## Hit in the air by an enemy flak burst / turret string / skiff gun: SUPPLY_HITS of them destroy it.
func shot_down(_by_pos: Vector3) -> void:
	if _done or mirror:
		return
	_hits += 1
	if _hits < Balance.SUPPLY_HITS:
		FlakRound.burst_fx(get_parent(), global_position, 0.5)
		var pm := _trail.process_material as ParticleProcessMaterial
		if pm != null:
			pm.color = Color(0.08, 0.075, 0.07, 0.75)
		_accent.emission_energy_multiplier = 0.3
		if local_owner:
			toast("İkmal kapsülün isabet aldı!", 1.4)
		return
	var pos := global_position
	_destroy(pos)
	events().pod_destroyed.emit(id, pos)


func _net_destroy(pos: Vector3) -> void:
	if _landed or not is_inside_tree():
		return
	global_position = pos
	_destroy(pos)


func _destroy(pos: Vector3) -> void:
	_done = true
	FlakRound.burst_fx(get_parent(), pos, 1.5)
	if local_owner:
		toast("İkmal kapsülün havada vuruldu: %s gitti" % gun_name(gun), 2.6, 2)
	_finish()


## Hides the pod, lets the trail fade, then frees it.
func _finish() -> void:
	_done = true
	remove_from_group("war_shell")
	remove_from_group(GROUP)
	if _vis != null:
		_vis.visible = false
	if _halo != null:
		_halo.visible = false
	if _light != null:
		_light.visible = false
	if _beacon != null:
		_beacon.visible = false
	if _jet_p != null:
		_burn_off()
	if _roar != null:
		_roar.stop()
	if _trail != null:
		_trail.emitting = false
	set_physics_process(false)
	if is_inside_tree():
		await get_tree().create_timer(3.0).timeout
	queue_free()


# =================================================================================================
# Look
# =================================================================================================

func _mat(c: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	return m


func _cyl(parent: Node3D, pos: Vector3, r_top: float, r_bot: float, h: float, mat: Material, seg := 18) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


## The capsule along local +Y (lid up, heat shield down = forward in flight).
func _build_model() -> void:
	_vis = Node3D.new()
	add_child(_vis)
	var home := team == "home"
	var hull := _mat(HOME_HULL if home else ENEMY_HULL, 0.08 if home else 0.5, 0.42)
	var dark := _mat(Color(0.08, 0.085, 0.09), 0.5, 0.5)
	var scorch := _mat(Color(0.16, 0.11, 0.08), 0.15, 0.9)
	var col := HOME_BAND if home else ENEMY_BAND
	_accent = _mat(col, 0.1, 0.5)
	_accent.emission_enabled = true
	_accent.emission = col
	_accent.emission_energy_multiplier = 1.1
	_cyl(_vis, Vector3(0, -0.05, 0), 0.4, RADIUS, 1.3, hull)
	_cyl(_vis, Vector3(0, -0.77, 0), RADIUS + 0.03, RADIUS - 0.1, 0.15, scorch)
	_cyl(_vis, Vector3(0, -0.88, 0), RADIUS - 0.12, 0.2, 0.08, scorch)
	_cyl(_vis, Vector3(0, 0.36, 0), 0.43, 0.44, 0.07, _accent)
	_cyl(_vis, Vector3(0, -0.42, 0), 0.485, 0.495, 0.07, _accent)
	for i in 3:
		var p := Node3D.new()
		p.rotation.y = TAU * float(i) / 3.0
		_vis.add_child(p)
		_box(p, Vector3(0, -0.03, 0.455), Vector3(0.1, 0.62, 0.03), _accent, Vector3(-0.085, 0, 0))
		_box(p, Vector3(0.16, 0.12, 0.445), Vector3(0.12, 0.05, 0.03), dark, Vector3(-0.085, 0, 0))
	_lid = Node3D.new()
	_lid.position = Vector3(0, 0.66, 0)
	_vis.add_child(_lid)
	_cyl(_lid, Vector3.ZERO, 0.26, 0.4, 0.12, dark, 16)
	_cyl(_lid, Vector3(0, 0.09, 0), 0.08, 0.13, 0.08, hull, 10)
	var flame := StandardMaterial3D.new()
	flame.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flame.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flame.albedo_color = Color(2.2, 1.3, 0.55, 0.85)
	flame.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		var d := Vector3(cos(a), 0.0, sin(a))
		_cyl(_vis, d * 0.46 + Vector3(0, -0.6, 0), 0.04, 0.07, 0.15, dark, 8)
		var f := _cyl(_vis, d * 0.48 + Vector3(0, -1.15, 0), 0.06, 0.01, 0.9, flame, 8)
		f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		f.visible = false
		_jets.append(f)
	for mi in _vis.find_children("*", "MeshInstance3D", true, false):
		if not _jets.has(mi):
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _build_fx() -> void:
	var col := HOME_BAND if team == "home" else ENEMY_BAND
	_halo = MeshInstance3D.new()
	_halo.mesh = DebrisMesh.quad_mesh()
	_halo.material_override = DebrisMesh.halo_material(col, 2.6, 0.007, 6.0)
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.custom_aabb = AABB(Vector3.ONE * -50.0, Vector3.ONE * 100.0)
	add_child(_halo)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.65, 0.4)
	_light.omni_range = 9.0
	_light.light_energy = 0.9
	_light.shadow_enabled = false
	add_child(_light)
	# The smoke trail left behind (world space).
	_trail = GPUParticles3D.new()
	_trail.amount = 56
	_trail.lifetime = 2.4
	_trail.local_coords = false
	_trail.visibility_aabb = AABB(Vector3.ONE * -2000.0, Vector3.ONE * 4000.0)
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 180.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.7
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.5
	pm.damping_max = 1.0
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.5))
	sc.add_point(Vector2(1, 1.6))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.45))
	g.set_color(1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	pm.color = Color(0.82, 0.8, 0.78, 0.45)
	_trail.process_material = pm
	var tm := StandardMaterial3D.new()
	tm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	tm.vertex_color_use_as_albedo = true
	tm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tm.albedo_texture = DigFx.soft_texture()
	var q := QuadMesh.new()
	q.size = Vector2(1.1, 1.1)
	q.material = tm
	_trail.draw_pass_1 = q
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_trail)
	_trail.emitting = true
	# Retro exhaust (forward in flight, down when landing).
	_jet_p = CPUParticles3D.new()
	_jet_p.emitting = false
	_jet_p.amount = 28
	_jet_p.lifetime = 0.5
	_jet_p.local_coords = false
	var jq := QuadMesh.new()
	jq.size = Vector2(0.6, 0.6)
	var jm := StandardMaterial3D.new()
	jm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	jm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	jm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	jm.vertex_color_use_as_albedo = true
	jm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	jm.albedo_texture = DigFx.soft_texture()
	jq.material = jm
	_jet_p.mesh = jq
	_jet_p.direction = Vector3.DOWN
	_jet_p.spread = 20.0
	_jet_p.initial_velocity_min = 8.0
	_jet_p.initial_velocity_max = 13.0
	_jet_p.damping_min = 6.0
	_jet_p.damping_max = 10.0
	_jet_p.gravity = Vector3.ZERO
	_jet_p.scale_amount_min = 0.6
	_jet_p.scale_amount_max = 1.4
	var jg := Gradient.new()
	jg.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	jg.colors = PackedColorArray([Color(1.0, 0.75, 0.4, 0.9), Color(0.8, 0.4, 0.2, 0.4), Color(0.3, 0.28, 0.26, 0.0)])
	_jet_p.color_ramp = jg
	_jet_p.position = Vector3(0, -0.75, 0)
	_vis.add_child(_jet_p)
	# Sound: a low roar in flight, the retro burn.
	_roar = AudioStreamPlayer3D.new()
	_roar.stream = Snd.loop("shuttle/reentry_roar")
	_roar.unit_size = 9.0
	_roar.max_distance = 450.0
	_roar.volume_db = -12.0
	_roar.pitch_scale = 1.3
	add_child(_roar)
	if _roar.stream != null:
		_roar.play()
	_burn = AudioStreamPlayer3D.new()
	_burn.stream = Snd.loop("shuttle/vtol")
	_burn.unit_size = 10.0
	_burn.max_distance = 300.0
	_burn.volume_db = -6.0
	_burn.pitch_scale = 1.3
	add_child(_burn)


## Over the landing spot (top level, follows the planet): a thin light beam and a ground ring everyone
## sees; on the caller's side also "İKMAL · 5" through the ground.
func _build_beacon() -> void:
	var col := HOME_BAND if team == "home" else ENEMY_BAND
	_beacon = Node3D.new()
	_beacon.top_level = true
	add_child(_beacon)
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beam_mat.albedo_color = Color(col, 0.3)
	var beam := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.12
	cm.height = 36.0
	cm.radial_segments = 8
	cm.rings = 1
	beam.mesh = cm
	beam.material_override = _beam_mat
	beam.position = Vector3(0, 18.0, 0)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beacon.add_child(beam)
	_ring_mat = _beam_mat.duplicate() as StandardMaterial3D
	_ring_mat.albedo_color = Color(col, 0.5)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.9
	tm.outer_radius = 1.05
	tm.rings = 40
	tm.ring_segments = 4
	ring.mesh = tm
	ring.material_override = _ring_mat
	ring.position = Vector3(0, 0.06, 0)
	ring.scale = Vector3(1.0, 0.2, 1.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beacon.add_child(ring)
	if team == "home":
		_tag = Label3D.new()
		_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_tag.no_depth_test = true
		_tag.fixed_size = true
		_tag.pixel_size = 0.0011
		_tag.font_size = 30
		_tag.outline_size = 10
		_tag.modulate = col.lerp(Color.WHITE, 0.45)
		_tag.outline_modulate = Color(0.0, 0.02, 0.035, 0.7)
		_tag.position = Vector3(0, 2.6, 0)
		_tag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_beacon.add_child(_tag)
	_tick_beacon(0.0)


func _tick_beacon(delta: float) -> void:
	if _beacon == null or _body == null or not is_instance_valid(_body):
		return
	var to := _body.global_transform * _to_l
	_beacon.global_transform = Transform3D(_basis_up((to - _body.global_position).normalized(), false), to)
	if _popped:
		_beacon_a = move_toward(_beacon_a, 0.0, delta * 1.5)
		_beacon.visible = _beacon_a > 0.01
	var pulse := 0.75 + 0.25 * sin(_life * 7.0)
	_beam_mat.albedo_color.a = 0.3 * pulse * _beacon_a
	_ring_mat.albedo_color.a = 0.5 * pulse * _beacon_a
	if _tag != null:
		_tag.text = "İKMAL  ·  %d" % ceili(maxf(_total - _life, 0.0)) if not _landed else "İKMAL"
		# HUD level: Sade only near or looked at (wider in Normal, always in Detaylı); the beam stays.
		var la := HudLevel.label_alpha(_tag.global_position, 20.0, 6.0) if _tag.is_inside_tree() else 1.0
		_tag.visible = la > 0.01
		_tag.modulate.a = _beacon_a * la
		_tag.outline_modulate.a = 0.7 * _beacon_a * la


func _burn_off() -> void:
	_retro = false
	for j in _jets:
		(j as Node3D).visible = false
	_jet_p.emitting = false
	_burn.stop()


func _basis_up(up: Vector3, spin: bool) -> Basis:
	var ref := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := up.cross(ref).normalized()
	var b := Basis(x, up, x.cross(up))
	return b.rotated(up, randf() * TAU) if spin else b


## A one-shot positional sound at the pod (the pod outlives it).
func _oneshot(stream: AudioStream, unit: float, vol_db: float, pitch := 1.0) -> void:
	if stream == null:
		return
	var a := AudioStreamPlayer3D.new()
	a.stream = stream
	a.unit_size = unit
	a.max_distance = 400.0
	a.volume_db = vol_db
	a.pitch_scale = pitch
	add_child(a)
	a.play()
	a.finished.connect(a.queue_free)
