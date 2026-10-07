extends "res://scripts/war/heroes/ult_base.gd"
## Kazıcı — Sismik Dalga. The caster slams the ground: a shock wave runs out HERO_QUAKE_R m at
## HERO_QUAKE_SPEED m/s along the ground (rings, dust bursts where its front is, a deep rumble, camera
## shake by distance). Host: every enemy the front passes takes HERO_QUAKE_DMG and a jolt (mostly up:
## a stagger, in this gravity a hop), and the enemy's tunnels and dugouts under it with at most
## HERO_QUAKE_ROOF m of roof come down (cave_in.gd quake: the usual collapse, burial and sinkhole; the
## terrain and its look reach a client through the cave-in / terrain channels).

const CaveIn := preload("res://scripts/war/cave_in.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")

var _pos := Vector3.ZERO
var _up := Vector3.UP
var _body: Node3D
var _hit := {}                           # instance id -> true (the front passed it)
var _dust_r := 0.0
var _soil := Color(0.42, 0.33, 0.22)
var _ring: MeshInstance3D


static func prepare(_heroes, caster: Node3D, data: Dictionary) -> String:
	if caster == null or not is_instance_valid(caster):
		return "Dalga başlatılamadı"
	var p := caster.global_position
	var b := Game.dominant_body(p)
	if b == null or Game.altitude(p) > 8.0:
		return "Sismik Dalga için yerde olmalısın"
	data["pos"] = p
	data["body"] = b
	data["up"] = (p - b.global_position).normalized()
	return ""


func _begin() -> void:
	_pos = data.get("pos", Vector3.ZERO)
	_body = data.get("body")
	_up = data.get("up", up_at(_pos))
	if _body == null or not is_instance_valid(_body):
		life = 0.0
		return
	life = Balance.HERO_QUAKE_R / Balance.HERO_QUAKE_SPEED + 1.6
	var sc = _body.get("soil_color")
	if sc is Color:
		_soil = sc
	# The slam.
	BuildFx.dust(self, _pos, _up, 2.5, _soil)
	BuildFx.shockwave(self, _pos, _up, Balance.HERO_QUAKE_R, _soil.lightened(0.25))
	_ring = HeroFx.ring(self, HeroData.color("kazici") if is_friend() else ENEMY_COL, 1.0)
	(_ring.material_override as ShaderMaterial).set_shader_parameter("fill", 0.0)
	HeroFx.play3d(self, "rumble", _pos + _up, 4.0, 30.0)
	if Game.sfx:
		Game.sfx.play("impact", -2.0, 0.6)
	var d := my_dist(_pos)
	var pl = Game.player
	if d < Balance.HERO_QUAKE_R * 3.0 and pl != null and pl.has_method("add_trauma"):
		pl.add_trauma(clampf(1.0 - d / (Balance.HERO_QUAKE_R * 3.0), 0.0, 1.0) * 0.9 + 0.1)
	if not is_friend() and d < Balance.HERO_QUAKE_R + 10.0:
		HudLevel.alert("SİSMİK DALGA — tüneller çöküyor!", 2, "hero_quake", 2.5)
	elif caster_is_me():
		HudLevel.alert("SİSMİK DALGA", 1, "hero_quake", 1.5, false)
	if authority():
		CaveIn.quake(_body, _pos, Balance.HERO_QUAKE_R, heroes.enemy_of(team), Balance.HERO_QUAKE_ROOF,
				Balance.HERO_QUAKE_MAX, Balance.HERO_QUAKE_SPEED, Balance.HERO_QUAKE_SPAN)


func _tick(_delta: float) -> void:
	if _body == null or not is_instance_valid(_body):
		finish("gone")
		return
	var front := minf(t * Balance.HERO_QUAKE_SPEED, Balance.HERO_QUAKE_R)
	if _ring != null:
		HeroFx.place(_ring, _pos, _up, 0.35)
		_ring.scale = Vector3(maxf(front, 0.5), 1.0, maxf(front, 0.5))
		(_ring.material_override as ShaderMaterial).set_shader_parameter("k", clampf(1.3 - front / Balance.HERO_QUAKE_R, 0.0, 1.0) * 1.4)
	# Dust where the front is (every ~3 m of its run).
	while _dust_r + 3.0 <= front:
		_dust_r += 3.0
		_dust_ring(_dust_r)
	if authority():
		_jolt(front)


func _dust_ring(r: float) -> void:
	var x := _up.cross(Vector3.RIGHT if absf(_up.x) < 0.9 else Vector3.FORWARD).normalized()
	var z := _up.cross(x)
	var n := clampi(int(r * 0.7), 4, 12)
	for i in n:
		var a := TAU * float(i) / float(n) + r
		var p := _pos + (x * cos(a) + z * sin(a)) * r
		var h: Dictionary = _body.raycast_density(p + _up * 6.0, p - _up * 8.0, 0.6, true)
		if not h.is_empty():
			BuildFx.dust(self, h["position"], _up, 1.0 + r * 0.05, _soil)


## Host: enemies the front reached (on the ground of this planet, not aboard / in a vehicle).
func _jolt(front: float) -> void:
	var foe: String = heroes.enemy_of(team)
	for n in heroes.units():
		if not is_instance_valid(n) or n.is_dead() or Game.team_of(n) != foe:
			continue
		var id: int = n.get_instance_id()
		if _hit.has(id):
			continue
		var p: Vector3 = (n as Node3D).global_position
		var d := p.distance_to(_pos)
		if d > front or d > Balance.HERO_QUAKE_R or Game.dominant_body(p) != _body:
			continue
		if n.get("vehicle") != null or Game.altitude(p) > 6.0:
			continue
		_hit[id] = true
		var k := 1.0 - 0.5 * d / Balance.HERO_QUAKE_R
		var out := (p - _pos)
		out -= _up * out.dot(_up)
		var imp := (_up * 0.85 + out.normalized() * 0.35).normalized() * Balance.HERO_QUAKE_IMPULSE * k
		var r := Game.damage_target(n, Balance.HERO_QUAKE_DMG * k, _pos, imp, team)
		if caster_is_me() and n != Game.player:
			var hfs = load("res://scripts/items/hit_feel.gd")
			var hf = hfs.inst() if hfs != null else null
			if hf != null:
				hf.target_hit(n, r, Balance.HERO_QUAKE_DMG * k, p + _up, {"big": k, "quiet": _hit.size() > 1, "weapon": "Sismik Dalga"})
