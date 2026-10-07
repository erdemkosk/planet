extends "res://scripts/war/heroes/ult_base.gd"
## Avcı — Faz Pelerini. HERO_CLOAK_TIME s: the caster's body fades (GeometryInstance3D.transparency →
## HERO_CLOAK_ALPHA) under a refraction shimmer (material_overlay, HeroFx.cloak_material: the world
## behind bent through the suit, a faint edge) — readable up close, nearly gone at range. Faster
## (Heroes.speed_mult: the player via the player.gd patch, bots via the ai_rival.gd patch); bots do not
## see the caster beyond HERO_CLOAK_SEE_R m (Heroes.hidden_from, ai_rival.gd patch). A shot fired by
## the caster ends it (Heroes._on_shot). The local caster sees his own hands faded and a shimmer at
## the screen edges (hero_hud.gd). material_overlay is shared with the scanner's / railgun's x-ray:
## only a free (null) overlay is taken and only ours is given back; the transparency is restored.
## Every machine runs its copy; the caster's own machine (or the host) ends it.

const SPEED_META := "hero_speed_mult"

var _mat: ShaderMaterial
var _vm_mat: ShaderMaterial
var _geo := {}                           # instance id -> [GeometryInstance3D, old transparency, is_vm]
var _scan_t := 0.0
var _k := 0.0


static func prepare(_heroes, caster: Node3D, data: Dictionary) -> String:
	if caster == null or not is_instance_valid(caster):
		return "Pelerin açılamadı"
	if caster.get("vehicle") != null:
		return "Araçta pelerin açılmaz"
	data["pos"] = caster.global_position
	return ""


func owns() -> bool:
	return authority() or caster_is_me()


func _begin() -> void:
	life = Balance.HERO_CLOAK_TIME
	if not caster_ok():
		life = 0.0
		return
	var col: Color = HeroData.color("avci") if is_friend() else Color(1.0, 0.55, 0.45)
	_mat = HeroFx.cloak_material(col)
	_vm_mat = HeroFx.cloak_material(HeroData.color("avci"))
	_vm_mat.set_shader_parameter("rim", 0.6)
	heroes.set_cloak(caster, self)
	_collect()
	if caster_is_me():
		caster.set_meta(SPEED_META, Balance.HERO_CLOAK_SPEED)
		HudLevel.alert("FAZ PELERİNİ — ateş edince bozulur", 1, "hero_cloak", 2.0, false)
		HeroFx.play2d("shimmer", -4.0)
	else:
		HeroFx.play3d(self, "shimmer", caster.global_position + caster.global_transform.basis.y, -2.0, 10.0)
		var d := my_dist(caster.global_position)
		if not is_friend() and d < 60.0:
			HudLevel.alert("Düşman Avcı görünmez oldu — yakında!", 2 if d < 35.0 else 1, "hero_cloak", 2.5)


func _collect() -> void:
	var a = caster.get("astronaut")
	var roots: Array = [a if a is Node else caster]
	if caster_is_me():
		var vm = caster.get("viewmodel")
		if vm is Node:
			roots.append(vm)
	for i in roots.size():
		var root: Node = roots[i]
		var is_vm := i > 0
		for c in root.find_children("*", "GeometryInstance3D", true, false):
			var g := c as GeometryInstance3D
			if g == null or _geo.has(g.get_instance_id()):
				continue
			_geo[g.get_instance_id()] = [g, g.transparency, is_vm]
			if g is MeshInstance3D and (g as MeshInstance3D).material_overlay == null:
				(g as MeshInstance3D).material_overlay = _vm_mat if is_vm else _mat


func _tick(delta: float) -> void:
	if not caster_ok() or (caster.has_method("is_dead") and caster.is_dead()) or caster.get("vehicle") != null:
		finish("gone")
		return
	var fade_out := clampf((life - t) / 0.4, 0.0, 1.0)
	_k = minf(clampf(t / 0.35, 0.0, 1.0), fade_out)
	# (a gun swap brings new meshes)
	_scan_t -= delta
	if _scan_t <= 0.0:
		_scan_t = 0.5
		_collect()
	var flick := 1.0 - 0.06 * absf(sin(t * 23.0))
	for id in _geo:
		var e: Array = _geo[id]
		var g = e[0]
		if not is_instance_valid(g):
			continue
		var target := (0.6 if bool(e[2]) else Balance.HERO_CLOAK_ALPHA) * flick
		(g as GeometryInstance3D).transparency = lerpf(float(e[1]), target, _k)
	_mat.set_shader_parameter("k", _k)
	_vm_mat.set_shader_parameter("k", _k * 0.8)


## The suit's look back as it was.
func _end(why: String) -> bool:
	for id in _geo:
		var e: Array = _geo[id]
		var g = e[0]
		if not is_instance_valid(g):
			continue
		(g as GeometryInstance3D).transparency = float(e[1])
		if g is MeshInstance3D and ((g as MeshInstance3D).material_overlay == _mat or (g as MeshInstance3D).material_overlay == _vm_mat):
			(g as MeshInstance3D).material_overlay = null
	_geo.clear()
	if heroes != null and is_instance_valid(heroes) and caster != null and is_instance_valid(caster):
		heroes.set_cloak(caster, null)
	if caster_ok():
		if caster.has_meta(SPEED_META):
			caster.remove_meta(SPEED_META)
		if caster_is_me():
			HeroFx.play2d("shimmer", -6.0, 0.8)
			if why == "fired":
				HudLevel.alert("Pelerin bozuldu", 0, "hero_cloak", 1.2)
		else:
			HeroFx.play3d(get_parent(), "shimmer", caster.global_position + caster.global_transform.basis.y, -4.0, 10.0, 0.8)
	return false
