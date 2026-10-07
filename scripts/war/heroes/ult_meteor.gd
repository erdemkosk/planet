extends "res://scripts/war/heroes/ult_base.gd"
## Topçu — Göktaşı Yağmuru. data: "pos" (world, on the ground), "body" (the planet), "far" (aimed across
## at the other planet: wider), "n" (meteors). Every machine: a hazard ring and a sky beam on the spot
## (red for the side it falls on, the caster's orange for his own side) for the warning and the strike,
## the alerts ("GÖKTAŞI YAĞMURU GELİYOR!" to anyone near it on the other side). Host: the meteors go
## through meteor_shower.gd strike() (streaks, blasts, craters, cave-in stress, the war HUD's markers,
## its net events), each impact hurting only the caster's enemies (Heroes.area_hit).

const Explosion := preload("res://scripts/items/explosion.gd")
const MeteorShower := preload("res://scripts/war/meteor_shower.gd")

var _pos := Vector3.ZERO
var _body: Node3D
var _up := Vector3.UP
var _spread := 12.0
var _ring: MeshInstance3D
var _beam: MeshInstance3D
var _root: Node3D
var _fallback: Array = []                # no MeteorShower node: [time s, point]


## Validates / completes the data (the caster's machine, again on the host for a claim). "" = ok.
static func prepare(_heroes, caster: Node3D, data: Dictionary) -> String:
	var body = data.get("body")
	if not (data.get("pos") is Vector3) or not (body is Node3D) or not is_instance_valid(body):
		return "Hedef yok"
	var pos: Vector3 = data["pos"]
	if caster != null and is_instance_valid(caster):
		var d := caster.global_position.distance_to(pos)
		var lim := Balance.HERO_METEOR_RANGE_FAR if Game.dominant_body(caster.global_position) != body else Balance.HERO_METEOR_RANGE
		if d > lim + 25.0:
			return "Hedef menzil dışında"
		data["far"] = Game.dominant_body(caster.global_position) != body
	data["up"] = (pos - (body as Node3D).global_position).normalized()
	if not data.has("n"):
		data["n"] = randi_range(Balance.HERO_METEOR_COUNT.x, Balance.HERO_METEOR_COUNT.y)
	return ""


func _begin() -> void:
	_pos = data.get("pos", Vector3.ZERO)
	_body = data.get("body")
	if _body == null or not is_instance_valid(_body):
		life = 0.0
		return
	_up = (_pos - _body.global_position).normalized()
	_spread = Balance.HERO_METEOR_SPREAD_FAR if bool(data.get("far", false)) else Balance.HERO_METEOR_SPREAD
	var n := int(data.get("n", Balance.HERO_METEOR_COUNT.y))
	life = Balance.HERO_METEOR_WARN + float(n) * Balance.HERO_METEOR_GAP + Balance.HERO_METEOR_FLIGHT + 1.2
	# The mark: a hazard ring and a beam into the sky.
	var col: Color = HeroData.color("topcu") if is_friend() else ENEMY_COL
	_root = Node3D.new()
	add_child(_root)
	HeroFx.place(_root, _pos, _up, 0.0)
	_ring = HeroFx.ring(_root, col, _spread)
	_ring.position = Vector3(0, 0.3, 0)
	(_ring.material_override as ShaderMaterial).set_shader_parameter("danger", 1.0)
	(_ring.material_override as ShaderMaterial).set_shader_parameter("fill", 0.18)
	_beam = HeroFx.beam(_root, col, 90.0)
	HeroFx.play3d(self, "warn", _pos + _up * 2.0, -2.0, 25.0)
	# Who is told.
	var d := my_dist(_pos)
	if not is_friend():
		if d < _spread + 40.0:
			HudLevel.alert("GÖKTAŞI YAĞMURU GELİYOR!", 2, "hero_meteor", 3.5)
		elif d < INF:
			HudLevel.alert("Düşman Topçu göktaşı çağırdı", 1, "hero_meteor", 2.5)
	elif caster_is_me():
		HudLevel.alert("Göktaşı Yağmuru yolda — %d sn" % int(ceilf(Balance.HERO_METEOR_WARN + Balance.HERO_METEOR_FLIGHT)), 1, "hero_meteor", 2.5, false)
	elif d < _spread + 8.0:
		HudLevel.alert("Dost göktaşları buraya düşüyor — uzaklaş!", 2, "hero_meteor", 3.0)
	if not authority():
		return
	var ms = MeteorShower.instance(get_tree())
	if ms != null and ms.has_method("strike"):
		var k: int = ms.strike(_body, _pos, n, _spread, Balance.HERO_METEOR_WARN, Balance.HERO_METEOR_GAP, {
				"team": team, "flight": Balance.HERO_METEOR_FLIGHT, "start_dist": Balance.HERO_METEOR_START_DIST,
				"blast_r": Balance.HERO_METEOR_BLAST_R, "damage": 0.0, "impulse": Balance.HERO_METEOR_IMPULSE,
				"crater_r": Balance.HERO_METEOR_CRATER_R, "crater_depth": Balance.HERO_METEOR_CRATER_DEPTH,
				"core": false, "on_impact": _on_impact})
		if k > 0:
			return
	# (no meteor shower node: plain timed blasts)
	for i in n:
		var a := randf() * TAU
		var rr := _spread * sqrt(randf())
		var x := _up.cross(Vector3.RIGHT if absf(_up.x) < 0.9 else Vector3.FORWARD).normalized()
		var z := _up.cross(x)
		_fallback.append([Balance.HERO_METEOR_WARN + Balance.HERO_METEOR_FLIGHT + float(i) * Balance.HERO_METEOR_GAP,
				_pos + (x * cos(a) + z * sin(a)) * rr])


func _tick(_delta: float) -> void:
	if _root == null:
		return
	var warn_end := Balance.HERO_METEOR_WARN + Balance.HERO_METEOR_FLIGHT
	var k := 1.0 if t < warn_end else clampf((life - t) / maxf(life - warn_end, 0.1), 0.0, 1.0)
	if _ring != null:
		(_ring.material_override as ShaderMaterial).set_shader_parameter("k", k * (1.0 + 0.6 * clampf(t / warn_end, 0.0, 1.0)))
	if _beam != null:
		(_beam.material_override as ShaderMaterial).set_shader_parameter("k", k * (0.6 + 0.4 * sin(t * 12.0)))
	for i in range(_fallback.size() - 1, -1, -1):
		var f: Array = _fallback[i]
		if t >= float(f[0]):
			_fallback.remove_at(i)
			_fallback_hit(f[1])


## Host: one meteor struck at p (meteor_shower.gd strike's on_impact).
func _on_impact(p: Vector3) -> void:
	heroes.area_hit(p, Balance.HERO_METEOR_BLAST_R * Balance.BLAST_RADIUS_SCALE, Balance.HERO_METEOR_DAMAGE,
			Balance.HERO_METEOR_IMPULSE, team, caster if caster_ok() else null, "Göktaşı Yağmuru")


func _fallback_hit(p: Vector3) -> void:
	if _body == null or not is_instance_valid(_body):
		return
	var u := (p - _body.global_position).normalized()
	var h: Dictionary = _body.raycast_density(p + u * 20.0, p - u * 20.0, 0.5, true)
	var g: Vector3 = h["position"] if not h.is_empty() else p
	Explosion.spawn(g, u, {"radius": Balance.HERO_METEOR_BLAST_R, "damage": 0.0, "impulse": Balance.HERO_METEOR_IMPULSE,
			"crater": 0.0, "player_owned": false, "team": team})
	_on_impact(g)
	if _body.has_method("crater"):
		_body.crater(g, Balance.HERO_METEOR_CRATER_R, Balance.HERO_METEOR_CRATER_DEPTH)
