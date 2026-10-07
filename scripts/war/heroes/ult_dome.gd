extends "res://scripts/war/heroes/ult_base.gd"
## Muhafız — Kalkan Kubbesi. A HERO_DOME_R m energy dome at the caster's feet for HERO_DOME_TIME s with
## HERO_DOME_HP hp. It stops what comes from OUTSIDE: the players' rounds and grenades (a StaticBody3D
## sphere on collision layer 32, which rifle_fx.gd / projectiles.gd rays include and no character,
## ragdoll or vehicle collides with; a ray that starts inside a sphere does not hit it, so shots from
## inside pass), blasts that reach it (group "damageable": it takes the damage) and the bots' rifle
## rounds (ai_rival.gd asks Heroes.dome_blocks, PATCHES.md). Walking through is free (both ways).
## Never within HERO_DOME_CORE_CLEAR m of a core: no stacking with the Çekirdek Kalkanı (core_shield.gd);
## it never touches core damage. Every machine builds its copy (the collision too, so a client's own
## rounds stop on it); the host owns the hp: broken / expired -> ult_ended.
##   blocks(from, to) -> bool   the segment enters the dome from outside
##   entry(from, to) -> Vector3 where it meets the shell
##   take_damage(amount, from_pos, impulse) -> {"dmg", "killed"}

const LAYER := 32

var hp := Balance.HERO_DOME_HP
var hp_max := Balance.HERO_DOME_HP
var _r := Balance.HERO_DOME_R
var _shell: MeshInstance3D
var _mat: ShaderMaterial
var _flash := 0.0
var _hum: AudioStreamPlayer3D
var _broken := false


static func prepare(_heroes, caster: Node3D, data: Dictionary) -> String:
	if caster == null or not is_instance_valid(caster):
		return "Kubbe kurulamadı"
	var p := caster.global_position
	var b := Game.dominant_body(p)
	if b == null or Game.altitude(p) > 12.0:
		return "Kubbe yerde kurulur"
	var tree := caster.get_tree()
	for c in tree.get_nodes_in_group("war_core"):
		if c is Node3D and (c as Node3D).global_position.distance_to(p) < Balance.HERO_DOME_CORE_CLEAR:
			return "Çekirdeğin yanında kubbe kurulamaz (Çekirdek Kalkanı)"
	data["pos"] = p
	data["body"] = b
	data["up"] = (p - b.global_position).normalized()
	return ""


func _begin() -> void:
	life = Balance.HERO_DOME_TIME
	var p: Vector3 = data.get("pos", Vector3.ZERO)
	var up: Vector3 = data.get("up", up_at(p))
	HeroFx.place(self, p, up, 0.0)
	add_to_group("hero_dome")
	add_to_group(Game.DAMAGEABLE)
	var col: Color = HeroData.color("muhafiz") if is_friend() else Color(1.0, 0.45, 0.25)
	_shell = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = _r
	sm.height = _r * 2.0
	sm.radial_segments = 40
	sm.rings = 20
	_shell.mesh = sm
	_mat = HeroFx.shell_material(col)
	_mat.set_shader_parameter("appear", 0.0)
	_shell.material_override = _mat
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shell)
	var sb := StaticBody3D.new()
	sb.collision_layer = LAYER
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = _r
	cs.shape = sph
	sb.add_child(cs)
	add_child(sb)
	var ring := HeroFx.ring(self, col, _r)
	ring.position = Vector3(0, 0.15, 0)
	(ring.material_override as ShaderMaterial).set_shader_parameter("fill", 0.05)
	(ring.material_override as ShaderMaterial).set_shader_parameter("k", 0.6)
	var st := HeroFx.sound("hum")
	if st != null:
		_hum = AudioStreamPlayer3D.new()
		_hum.stream = st
		_hum.unit_size = 8.0
		_hum.max_distance = 90.0
		_hum.volume_db = -10.0
		add_child(_hum)
		_hum.play()
	HeroFx.play3d(self, "sweep", p + up, -4.0, 16.0, 0.7)
	if caster_is_me():
		HudLevel.alert("KALKAN KUBBESİ — %d sn" % int(life), 1, "hero_dome", 2.0, false)
	elif not is_friend() and my_dist(p) < 45.0:
		HudLevel.alert("Düşman kalkan kubbesi — patlayıcıyla kır ya da içeri gir", 1, "hero_dome", 2.5)


func _tick(delta: float) -> void:
	_flash = maxf(_flash - delta * 3.0, 0.0)
	if _mat == null:
		return
	_mat.set_shader_parameter("appear", clampf(t / 0.5, 0.0, 1.0))
	var fade := clampf((life - t) / 1.2, 0.0, 1.0)
	var blink := 1.0 if life - t > 2.5 else 0.6 + 0.4 * sin(t * 18.0)
	var dmg_k := 0.6 + 0.4 * hp / maxf(hp_max, 1.0)
	_mat.set_shader_parameter("strength", fade * blink * dmg_k)
	_mat.set_shader_parameter("flash", _flash)
	if _hum != null:
		_hum.volume_db = -10.0 + linear_to_db(maxf(fade, 0.01))


## The segment from -> to comes from outside and enters the dome.
func blocks(from: Vector3, to: Vector3) -> bool:
	if ended:
		return false
	var c := global_position
	if from.distance_to(c) <= _r:
		return false
	var seg := to - from
	var l2 := seg.length_squared()
	if l2 < 1e-6:
		return false
	var u := clampf((c - from).dot(seg) / l2, 0.0, 1.0)
	return (from + seg * u).distance_to(c) < _r


## Where from -> to meets the shell (from outside), or `to`.
func entry(from: Vector3, to: Vector3) -> Vector3:
	var c := global_position
	var d := (to - from)
	var L := d.length()
	if L < 1e-4:
		return to
	d /= L
	var oc := from - c
	var b := oc.dot(d)
	var cc := oc.dot(oc) - _r * _r
	var disc := b * b - cc
	if disc < 0.0:
		return to
	var s := -b - sqrt(disc)
	return from + d * clampf(s, 0.0, L)


func is_dead() -> bool:
	return ended


func take_damage(amount: float, _from_pos := Vector3.ZERO, _impulse := Vector3.ZERO) -> Dictionary:
	if ended or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	_flash = minf(_flash + 0.35 + amount / 120.0, 1.0)
	if not authority():
		return {"dmg": amount, "killed": false}
	hp -= amount
	if hp <= 0.0:
		_broken = true
		finish("broken")
	return {"dmg": amount, "killed": false}


func _end(why: String) -> bool:
	for c in get_children():
		if c is StaticBody3D:
			(c as Node).queue_free()
	remove_from_group("hero_dome")
	remove_from_group(Game.DAMAGEABLE)
	if why == "broken" or _broken:
		HeroFx.play3d(get_parent(), "deny", global_position + global_transform.basis.y * 2.0, 2.0, 20.0, 0.6)
		if Game.sfx:
			Game.sfx.play("impact", -6.0, 1.4)
	var tw := create_tween()
	tw.tween_method(func(v: float):
		if _mat != null:
			_mat.set_shader_parameter("strength", v)
			_mat.set_shader_parameter("flash", v * (1.0 if why == "broken" else 0.0)), 1.0, 0.0, 0.35)
	tw.tween_callback(queue_free)
	return true
