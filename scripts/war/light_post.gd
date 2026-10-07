extends "res://scripts/war/base_piece.gd"
## Işık Direği (light post), İnşa Aracı (Üs; Balance.LIGHT_*): cheap, for tunnels and bunkers. A
## weighted steel foot plate with a ballast block, a slim pole with its cable, and a caged work lamp:
## a warm-white OmniLight (LIGHT_COLOR, LIGHT_ENERGY, LIGHT_RANGE m, a soft falloff, no shadows): it
## lights a tunnel without blowing it out. Flickers when hit. Group "war_light". Multiplayer: hp only.

const POLE_H := 1.6
const LAMP_Y := 1.66

var _light: OmniLight3D
var _lens: StandardMaterial3D
var _flicker := 0.0


static func footprint() -> Vector3:
	return Vector3(0.3, 0.9, 0.3)


func piece_kind() -> String:
	return "light_post"


func piece_name() -> String:
	return "Işık Direği"


func piece_group() -> String:
	return "war_light"


func piece_hp() -> float:
	return Balance.LIGHT_HP


func footprint_r() -> float:
	return Balance.LIGHT_FOOTPRINT


func _foundation_shape() -> Array:
	return [PackedVector3Array(), [[Vector3(0, 0.0, 0), 0.06]], Color(0.33, 0.33, 0.34)]


func _build_piece() -> void:
	var home := team == "home"
	_paint = _mat(Color(0.95, 0.42, 0.08) if home else Color(0.72, 0.12, 0.08), 0.1, 0.5)
	var steel := _mat(Color(0.34, 0.35, 0.37), 0.85, 0.38)
	var dark := _mat(Color(0.1, 0.105, 0.11), 0.7, 0.42)
	var bolt := _mat(Color(0.55, 0.56, 0.58), 0.9, 0.3)
	var foot := _part(0.0)
	_box(foot, Vector3(0, 0.025, 0), Vector3(0.5, 0.05, 0.5), steel)
	_box(foot, Vector3(0.12, 0.1, 0.0), Vector3(0.18, 0.12, 0.3), concrete(true))
	for sx: float in [1.0, -1.0]:
		for sz: float in [1.0, -1.0]:
			_cyl(foot, Vector3(sx * 0.2, 0.06, sz * 0.2), 0.02, 0.02, 0.025, bolt, Vector3.ZERO, 6)
	var pole := _part(0.12)
	_cyl(pole, Vector3(0, 0.05 + POLE_H * 0.5, 0), 0.032, 0.04, POLE_H, _paint, Vector3.ZERO, 10)
	_cyl(pole, Vector3(0, 0.2, 0), 0.05, 0.05, 0.08, hazard(), Vector3.ZERO, 10)
	_seg(pole, Vector3(0.05, 0.06, 0.06), Vector3(0.045, POLE_H - 0.1, 0.03), 0.009, dark, 5)
	_box(pole, Vector3(0, 0.95, 0.05), Vector3(0.08, 0.12, 0.04), dark)                 # switch box
	_col_box(Vector3(0, 0.05 + POLE_H * 0.5, 0), Vector3(0.12, POLE_H, 0.12))
	_col_box(Vector3(0, 0.05, 0), Vector3(0.5, 0.1, 0.5))
	# Caged lamp head, tilted a little forward.
	var head := _part(0.25)
	var lamp := Node3D.new()
	lamp.position = Vector3(0, LAMP_Y, 0)
	lamp.rotation = Vector3(0.3, 0, 0)
	head.add_child(lamp)
	_cyl(lamp, Vector3(0, 0.05, 0), 0.07, 0.1, 0.12, dark, Vector3.ZERO, 14)
	_lens = _mat(Balance.LIGHT_COLOR, 0.0, 0.25, 2.5)
	var lm := _cyl(lamp, Vector3(0, -0.02, 0), 0.095, 0.095, 0.02, _lens, Vector3.ZERO, 14)
	lm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for k in 4:
		var a := TAU * float(k) / 4.0
		var d := Vector3(cos(a), 0, sin(a))
		_seg(lamp, d * 0.1 + Vector3(0, 0.0, 0), d * 0.11 + Vector3(0, -0.12, 0), 0.006, steel, 4)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.1
	ring.outer_radius = 0.115
	ring.rings = 16
	ring.ring_segments = 4
	var rm := MeshInstance3D.new()
	rm.mesh = ring
	rm.material_override = steel
	rm.position = Vector3(0, -0.12, 0)
	lamp.add_child(rm)
	_light = OmniLight3D.new()
	_light.light_color = Balance.LIGHT_COLOR
	_light.omni_range = Balance.LIGHT_RANGE
	_light.omni_attenuation = 1.15
	_light.light_energy = 0.0
	_light.light_specular = 0.25
	_light.shadow_enabled = false
	_light.position = Vector3(0, -0.15, 0)
	lamp.add_child(_light)


func _animate(delta: float) -> void:
	if has_meta("build_preview"):
		return
	var on := _build_t < 0.0 and not is_destroyed
	if _hit_t > 0.5:
		_flicker = 0.6
	_flicker = maxf(_flicker - delta, 0.0)
	var k := 1.0
	if _flicker > 0.0:
		k = 0.25 if int(_t * 19.0) % 3 == 0 else 1.0
	var want := Balance.LIGHT_ENERGY * k if on else 0.0
	_light.light_energy = lerpf(_light.light_energy, want, 1.0 - exp(-delta * 8.0))
	_lens.emission_energy_multiplier = 0.3 + 2.4 * clampf(_light.light_energy / maxf(Balance.LIGHT_ENERGY, 0.01), 0.0, 1.0)
