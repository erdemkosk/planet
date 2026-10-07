extends "res://scripts/war/heroes/ult_base.gd"
## Gözcü — Uydu Taraması. HERO_SCAN_TIME s: for the caster's side every enemy on the planet he stands on
## shows on the radar (scripts/ui/minimap.gd draws scripts/war/shot_pings.gd's enemy pings: refreshed
## every HERO_SCAN_TICK s, a public method only; see PATCHES.md for a proper reveal hook) and as red
## diamonds through walls (hero_hud.gd reads Heroes.reveal). Everyone sees the sweep: a light pillar on
## the caster and a ring racing round the planet; the scanned side hears it and is told. Purely a
## read-out: no world change, so it runs the same on every machine (no host part).
## (Not the Tünel tarayıcı's x-ray: no silhouettes, no tunnels.)

const ShotPings := preload("res://scripts/war/shot_pings.gd")

var _body: Node3D
var _tick_t := 0.0
var _root: Node3D
var _pillar: MeshInstance3D
var _wave: MeshInstance3D
var _centre := Vector3.ZERO


static func prepare(_heroes, caster: Node3D, data: Dictionary) -> String:
	if caster == null or not is_instance_valid(caster):
		return "Tarama yapılamadı"
	var b := Game.dominant_body(caster.global_position)
	if b == null:
		return "Gezegen yok"
	data["body"] = b
	data["pos"] = caster.global_position
	return ""


func _begin() -> void:
	life = Balance.HERO_SCAN_TIME
	_body = data.get("body")
	_centre = data.get("pos", Vector3.ZERO)
	if _body == null or not is_instance_valid(_body):
		life = 0.0
		return
	var col: Color = HeroData.color("gozcu") if is_friend() else ENEMY_COL
	_root = Node3D.new()
	add_child(_root)
	HeroFx.place(_root, _centre, up_at(_centre), 0.0)
	_pillar = HeroFx.beam(_root, col, 140.0)
	# The sweep: a bubble from the caster that grows past the planet (its edge runs over the ground).
	_wave = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 48
	sm.rings = 24
	_wave.mesh = sm
	_wave.material_override = HeroFx.shell_material(col)
	_wave.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wave.extra_cull_margin = 400.0
	add_child(_wave)
	HeroFx.play3d(self, "sweep", _centre + up_at(_centre) * 2.0, 2.0, 40.0)
	if is_friend():
		heroes.reveal = {"until": Time.get_ticks_msec() + int(life * 1000.0), "team": heroes.enemy_of(team), "body": _body}
		if caster_is_me():
			HudLevel.alert("UYDU TARAMASI — düşmanlar %d sn görünür" % int(life), 1, "hero_scan", 2.5, false)
		else:
			HudLevel.alert("Dost Gözcü taradı — düşmanlar radarda", 1, "hero_scan", 2.5)
		_ping()
	elif my_dist(_centre) < INF:
		HudLevel.alert("DÜŞMAN UYDU TARAMASI — yerin görünüyor!", 2, "hero_scan", 3.0)


func _tick(delta: float) -> void:
	if _body == null or not is_instance_valid(_body):
		finish("gone")
		return
	# The sweep bubble: past the antipode in ~1.6 s, fading as it goes.
	if _wave != null:
		var k := clampf(t / 1.6, 0.0, 1.0)
		var r := lerpf(2.0, float(_body.radius) * 2.3, k * (2.0 - k))
		_wave.global_transform = Transform3D(Basis().scaled(Vector3.ONE * r), _centre)
		(_wave.material_override as ShaderMaterial).set_shader_parameter("strength", (1.0 - k) * 1.6)
		if k >= 1.0:
			_wave.queue_free()
			_wave = null
	if _pillar != null:
		(_pillar.material_override as ShaderMaterial).set_shader_parameter("k", clampf((life - t) / 1.5, 0.0, 1.0))
	if is_friend():
		_tick_t -= delta
		if _tick_t <= 0.0:
			_tick_t = Balance.HERO_SCAN_TICK
			_ping()


## Every enemy on the planet as a radar ping (minimap.gd: the other side's loud pings).
func _ping() -> void:
	var foe: String = heroes.enemy_of(team)
	for n in heroes.units():
		if not is_instance_valid(n) or n.is_dead() or Game.team_of(n) != foe:
			continue
		var p: Vector3 = (n as Node3D).global_position
		if Game.dominant_body(p) != _body:
			continue
		ShotPings.add(p + (n as Node3D).global_transform.basis.y * 1.0, foe, true)


func _end(_why: String) -> bool:
	if heroes != null and is_instance_valid(heroes) and is_friend():
		var rv: Dictionary = heroes.reveal
		if rv.get("body") == _body:
			heroes.reveal = {}
	return false
