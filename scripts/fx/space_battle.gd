extends Node3D
## Cosmetic background space battle ("Arka plan savaşı", Ayarlar › Görüntü: Kapalı / Düşük /
## Yüksek): a war raging far out in the sky around the two planets, purely for atmosphere. Nothing
## here touches gameplay: no physics, no collision, no raycasts, no groups, no sound, no network
## (each machine runs its own, seeded from the match seed in multiplayer). Pauses with the tree.
## Spawned by main.gd (not in the training ground).
##
## Layout: engagement zones (battle_zone.gd) on a wide arc around the planets' axis, ~45° or more
## from the sun and never between the planets, 900-3100 m from their midpoint: a carrier battle
## (1500 m), a battleship duel low past the sun (2300 m), a far fleet action high behind (2800 m,
## "Yüksek" only) and a fighter skirmish on the night side (1050 m); debris fields drift between
## them. The battle follows half of the camera's offset from the midpoint: less parallax than its
## depth (it reads as farther away) and it can never be approached. Normal depth testing: the
## planets hide it.
## Escalation: already lively at the start (intensity 0.55: most craft out, steady fire), full
## intensity after ~9 minutes;
## from ~3.5 minutes on a capital ship is crippled and blown apart every few minutes.
##
## Cost: craft AI at 10 Hz each (staggered), capital ships at 5 Hz, missiles at 20 Hz; every
## effect is a GPU-animated MultiMesh instance written once. ~12 instanced draws + 2 per capital
## ship. Budget < 0.5 ms / frame at "Yüksek".
## Parts: battle_fx.gd (clock, pools, presets), battle_wings.gd (craft, missiles, torpedoes),
## battle_fleet.gd (capital ships, wrecks, director), battle_models.gd, battle_shaders.gd,
## battle_zone.gd.

const Fx := preload("res://scripts/fx/battle_fx.gd")
const Zone := preload("res://scripts/fx/battle_zone.gd")
const Wings := preload("res://scripts/fx/battle_wings.gd")
const Fleet := preload("res://scripts/fx/battle_fleet.gd")
const Models := preload("res://scripts/fx/battle_models.gd")
const Settings := preload("res://scripts/save/settings.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const RandomWorld := preload("res://scripts/planet/random_world.gd")

const FOLLOW := 0.5             # share of the camera's offset from the midpoint the battle follows
const FOLLOW_MAX := 1500.0
const RAMP := 540.0             # seconds from the quiet opening to full intensity

## th = angle around the planets' axis from the sun (deg), r = distance from the midpoint, off =
## shift along the axis (+ toward Rakip), ext = semi-axes (along the axis, outward, third), lvl =
## lowest density that has it, caps = [home class, rival class] (battle_models.gd: 0 carrier H,
## 1 battleship H, 2 carrier R, 3 destroyer R), hi / lo = craft per density
## [home fighters, home bombers, rival fighters, rival bombers].
const ZONES := [
	{"th": -48.0, "r": 1500.0, "off": -360.0, "ext": Vector3(560, 240, 280), "lvl": 1,
		"caps": [0, 2], "hi": [9, 2, 9, 2], "lo": [5, 1, 5, 1]},
	{"th": 55.0, "r": 2300.0, "off": 420.0, "ext": Vector3(700, 300, 330), "lvl": 1,
		"caps": [1, 3], "hi": [7, 2, 7, 2], "lo": [4, 1, 4, 1]},
	{"th": -128.0, "r": 2800.0, "off": -160.0, "ext": Vector3(780, 300, 340), "lvl": 2,
		"caps": [1, 2], "hi": [5, 1, 5, 1], "lo": [0, 0, 0, 0]},
	{"th": 148.0, "r": 1050.0, "off": 220.0, "ext": Vector3(380, 160, 200), "lvl": 1,
		"caps": [], "hi": [4, 0, 4, 0], "lo": [3, 0, 3, 0]},
]
## Drifting debris fields (same placement terms; rad = semi-axes, n = chunks).
const FIELDS := [
	{"th": -88.0, "r": 1900.0, "off": 560.0, "rad": Vector3(320, 110, 200), "n": 90, "lvl": 1},
	{"th": 100.0, "r": 1350.0, "off": -480.0, "rad": Vector3(230, 90, 160), "n": 60, "lvl": 2},
]

var fx: Fx
var wings: Wings
var fleet: Fleet
var _level := -1
var _mid := Vector3.ZERO
var _start := 0.0
var _elapsed := 0.0             # battle time carried over a rebuild (density changed in Ayarlar)


func _ready() -> void:
	name = "SpaceBattle"


func _exit_tree() -> void:
	_teardown()


func _process(delta: float) -> void:
	var lvl := clampi(Settings.space_battle, 0, 2)
	if lvl != _level:
		_teardown()
		_level = lvl
		if lvl > 0 and not _build(lvl):
			_level = -1                 # the planets are not up yet: try again next frame
			return
	if fx == null:
		return
	fx.now += minf(delta, 0.1)
	fx.intensity = 0.55 + 0.45 * smoothstep(0.0, RAMP, fx.now - _start)
	_follow()
	wings.tick()
	fleet.tick()
	fx.push()


func _follow() -> void:
	var off := Vector3.ZERO
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		off = ((cam.global_position - _mid) * FOLLOW).limit_length(FOLLOW_MAX * FOLLOW)
	global_position = _mid + off


func _build(lvl: int) -> bool:
	var home := Bodies.by_preset("home")
	var rival := Bodies.by_preset("rival")
	if home == null or rival == null:
		return false
	var hp := home.global_position
	var rp := rival.global_position
	_mid = (hp + rp) * 0.5
	var ax := rp - hp
	ax = ax.normalized() if ax.length_squared() > 1.0 else Vector3.RIGHT
	var sun: Vector3 = Game.sun_dir
	var s_perp := sun - ax * sun.dot(ax)
	if s_perp.length_squared() < 0.01:
		s_perp = Vector3.UP - ax * ax.y
	s_perp = s_perp.normalized()
	var b_ax := ax.cross(s_perp).normalized()
	global_position = _mid
	fx = Fx.new()
	fx.rng.seed = _seed()
	_start = 1.0
	fx.now = _start + _elapsed           # a density change mid-match keeps the escalation
	var zones: Array[Zone] = []
	var cap_plan: Array = []
	var craft_plan: Array = []
	var box := AABB()
	for zd: Dictionary in ZONES:
		if int(zd["lvl"]) > lvl:
			continue
		var th := deg_to_rad(float(zd["th"]))
		var d := (s_perp * cos(th) + b_ax * sin(th)).normalized()
		var z := Zone.new()
		z.id = zones.size()
		z.a = ax
		z.d = d
		z.n = ax.cross(d).normalized()
		z.up = -d
		z.ext = zd["ext"]
		z.center = d * float(zd["r"]) + ax * float(zd["off"])
		zones.append(z)
		cap_plan.append(zd["caps"])
		craft_plan.append(zd["hi"] if lvl >= 2 else zd["lo"])
		var r := maxf(z.ext.x, maxf(z.ext.y, z.ext.z)) + 700.0
		var zb := AABB(z.center - Vector3.ONE * r, Vector3.ONE * (r * 2.0))
		box = zb if zones.size() == 1 else box.merge(zb)
	var heads := 40 if lvl >= 2 else 20
	fx.setup(self, 2560 if lvl >= 2 else 1280, 1024 if lvl >= 2 else 512, heads + 8, box, sun)
	fleet = Fleet.new()
	wings = Wings.new()
	fleet.setup(fx, zones, wings, cap_plan, heads)
	wings.setup(fx, zones, fleet, craft_plan, heads)
	for fd: Dictionary in FIELDS:
		if int(fd["lvl"]) <= lvl:
			_debris_field(fd, ax, s_perp, b_ax)
	return true


## The match's world seed (random_world.gd; identical on both machines in multiplayer, new each
## single-player match), else the multiplayer match id, else random. Purely local afterwards.
func _seed() -> int:
	var world: Dictionary = RandomWorld.current
	if world.has("seed"):
		return int(world["seed"]) ^ 0x5eed
	if Net.active and Net.cfg.has("match"):
		return int(Net.cfg["match"]) ^ 0x5eed
	return randi()


## A field of tumbling hull chunks (static instances; the hull shader spins them).
func _debris_field(fd: Dictionary, ax: Vector3, sp: Vector3, bx: Vector3) -> void:
	var rng := fx.rng
	var th := deg_to_rad(float(fd["th"]))
	var d := (sp * cos(th) + bx * sin(th)).normalized()
	var n_ax := ax.cross(d).normalized()
	var c := d * float(fd["r"]) + ax * float(fd["off"])
	var rad: Vector3 = fd["rad"]
	var count := int(fd["n"])
	var mm := fx.multimesh(Models.chunk(), fx.hull_debris, count, false, true).multimesh
	for i in count:
		var u := Vector3(rng.randfn(0.0, 0.45), rng.randfn(0.0, 0.45), rng.randfn(0.0, 0.45)).limit_length(1.0)
		var p := c + ax * (u.x * rad.x) + d * (u.y * rad.y) + n_ax * (u.z * rad.z)
		var s := rng.randf_range(1.5, 7.0) if rng.randf() < 0.85 else rng.randf_range(9.0, 22.0)
		var bs := Basis(fx.rand_dir(), rng.randf_range(0.0, TAU)) \
				* Basis.from_scale(Vector3(s * rng.randf_range(0.5, 1.0), s * rng.randf_range(0.3, 0.8), s))
		mm.set_instance_transform(i, Transform3D(bs, p))
		var dark := rng.randf() < 0.45
		var g := rng.randf_range(0.08, 0.16) if dark else rng.randf_range(0.45, 0.72)
		var tint := Color(g, g * 0.97, g * 0.95, 1.0)
		if dark and rng.randf() < 0.15:
			tint = Color(0.35, 0.05, 0.03, 1.0)
		elif not dark and rng.randf() < 0.2:
			tint = Color(0.8, 0.42, 0.12, 1.0)
		mm.set_instance_color(i, tint)
		var ember := float(rng.randi_range(1, 2)) if rng.randf() < 0.15 else 0.0
		var spin := fx.rand_dir() * rng.randf_range(0.03, 0.35)
		mm.set_instance_custom_data(i, Color(spin.x, spin.y, spin.z, rng.randf_range(0.0, TAU) + 10.0 * ember))


func _teardown() -> void:
	if fx != null:
		_elapsed = fx.now - _start
	if fleet != null:
		fleet.teardown()
		fleet.wings = null              # break the fleet <-> wings reference cycle
	if wings != null:
		wings.fleet = null
	for ch in get_children():
		ch.queue_free()
	fx = null
	wings = null
	fleet = null
