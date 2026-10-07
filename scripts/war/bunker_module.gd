extends "res://scripts/war/base_piece.gd"
## Sığınak Modülü (bunker module), built with the İnşa Aracı (Üs category; Balance.BUNKER_*), on the
## surface or in a dug cavity. A reinforced room shell: 4 × 4 m outside, 2.8 m high (3.4 × 3.4 × 2.5 m
## inside), cast concrete walls 0.3 m thick between steel corner columns, a roof slab on steel edge
## channels, a doorway (1.6 × 2.2 m) with a steel portal in the FRONT (+Z) and the BACK (-Z) wall.
## Inside: a ceiling lamp strip (a warm, dim light), a cable tray, a vent, a wall locker; stencils by
## the doorways. On the surface sandbags are banked against its side walls (half buried); under the
## ground the soil above shelters it (Explosion -> BaseKit.blast_shelter).
## Blasts × BUNKER_BLAST_MULT, bullets in full. Solid cover: players walk in through the doorways.
## Modules snap doorway to doorway (BaseKit.snap: a corridor); a Takviyeli Duvar plugs a doorway or
## carries a face on sideways; a Zırhlı Kapı fits a doorway; a turret / light may stand inside.
## Group "war_bunker". Multiplayer state: hp only.

const Dig := preload("res://scripts/player/dig.gd")

const H := 2.8                          # outer height (floor top at y = 0)
const HALF := 2.0                       # outer half size
const WALL := 0.3
const DOOR_W := 1.6
const DOOR_H := 2.2
const ROOF := 0.3

var _lamp_light: OmniLight3D
var _lamp_mat: StandardMaterial3D
var _status_mats: Array = []
var _berm: Node3D


static func footprint() -> Vector3:
	return Vector3(HALF, H * 0.5, HALF)


func piece_kind() -> String:
	return "bunker_module"


func piece_name() -> String:
	return "Sığınak Modülü"


func piece_group() -> String:
	return "war_bunker"


func piece_hp() -> float:
	return Balance.BUNKER_HP


func footprint_r() -> float:
	return Balance.BUNKER_FOOTPRINT


func blast_mult() -> float:
	return Balance.BUNKER_BLAST_MULT


func shelter_point() -> Vector3:
	return global_position + global_transform.basis.y.normalized() * 1.3


## The two doorway centres (world, floor level), front then back.
func doorways() -> Array:
	return [global_transform * Vector3(0, 0, HALF), global_transform * Vector3(0, 0, -HALF)]


func _foundation_shape() -> Array:
	return [Foundation.rect(-HALF, HALF, -HALF, HALF, -0.25, 4, 4), [], Color(0.4, 0.39, 0.37)]


func _build_piece() -> void:
	var home := team == "home"
	var conc := concrete()
	var conc_d := concrete(true)
	_paint = _mat(Color(0.84, 0.85, 0.84) if home else Color(0.22, 0.21, 0.21), 0.15 if home else 0.5, 0.5)
	var stripe := _mat(Color(0.95, 0.42, 0.08) if home else Color(0.72, 0.12, 0.08), 0.0, 0.5)
	var steel := _mat(Color(0.32, 0.33, 0.35), 0.82, 0.4)
	var gun := _mat(Color(0.12, 0.125, 0.135), 0.7, 0.38)
	var seam := _mat(Color(0.2, 0.2, 0.2), 0.0, 0.95)
	var haz := hazard()
	var inner_w := HALF - WALL                       # 1.7: the inner face
	var side_w := (HALF * 2.0 - WALL * 2.0 - DOOR_W) * 0.5   # 0.9: wall beside a doorway

	# --- Floor slab.
	var floor_p := _part(0.0)
	_box(floor_p, Vector3(0, -0.125, 0), Vector3(HALF * 2.0, 0.25, HALF * 2.0), conc_d)
	for sz: float in [1.0, -1.0]:
		_box(floor_p, Vector3(0, 0.012, sz * (HALF - WALL * 0.5)), Vector3(DOOR_W, 0.025, WALL), haz)   # sills
	_box(floor_p, Vector3(0, 0.006, 0), Vector3(inner_w * 2.0 - 0.1, 0.012, inner_w * 2.0 - 0.1), gun)   # steel deck plate
	_col_box(Vector3(0, -0.125, 0), Vector3(HALF * 2.0, 0.25, HALF * 2.0))

	# --- Side walls (x = ±), solid.
	var walls := _part(0.15)
	for sx: float in [1.0, -1.0]:
		_box(walls, Vector3(sx * (HALF - WALL * 0.5), (H - ROOF) * 0.5, 0), Vector3(WALL, H - ROOF, HALF * 2.0), conc)
		_col_box(Vector3(sx * (HALF - WALL * 0.5), (H - ROOF) * 0.5, 0), Vector3(WALL, H - ROOF, HALF * 2.0))
		for k in [-1.0, 0.0, 1.0]:                   # formwork panel seams outside
			_box(walls, Vector3(sx * (HALF + 0.002), (H - ROOF) * 0.5, float(k) * 1.33), Vector3(0.006, H - ROOF - 0.1, 0.03), seam)
	# --- Front / back walls with the doorways.
	var fronts := _part(0.3)
	for sz: float in [1.0, -1.0]:
		var zc := sz * (HALF - WALL * 0.5)
		for sx: float in [1.0, -1.0]:
			var xc := sx * (DOOR_W * 0.5 + side_w * 0.5)
			_box(fronts, Vector3(xc, (H - ROOF) * 0.5, zc), Vector3(side_w, H - ROOF, WALL), conc)
			_col_box(Vector3(xc, (H - ROOF) * 0.5, zc), Vector3(side_w, H - ROOF, WALL))
		var lh := H - ROOF - DOOR_H
		_box(fronts, Vector3(0, DOOR_H + lh * 0.5, zc), Vector3(DOOR_W, lh, WALL), conc)
		_col_box(Vector3(0, DOOR_H + lh * 0.5, zc), Vector3(DOOR_W, lh, WALL))
		# Steel portal around the doorway (posts + header), proud of the face.
		var zo := sz * (HALF + 0.03)
		for sx: float in [1.0, -1.0]:
			_box(fronts, Vector3(sx * (DOOR_W * 0.5 + 0.06), DOOR_H * 0.5, zo), Vector3(0.12, DOOR_H + 0.12, 0.08), steel)
		_box(fronts, Vector3(0, DOOR_H + 0.06, zo), Vector3(DOOR_W + 0.24, 0.12, 0.08), steel)
		# Status lamp over the doorway (team colour), a stencil beside it.
		_status_mats.append(_lamp(fronts, Vector3(0, DOOR_H + 0.2, sz * (HALF + 0.07)), _col_team, 0.045, 2.5))
		var num := "SG-%02d" % (absi(hash(str(get_instance_id()))) % 90 + 10)
		_label(fronts, Vector3(sz * 1.25, 1.75, sz * (HALF + 0.012)), num, 54, Color(0.12, 0.12, 0.12) if home else Color(0.85, 0.82, 0.78),
				Vector3(0, 0.0 if sz > 0.0 else PI, 0))
	# --- Roof slab on steel edge channels, corner columns, the team band.
	var roof := _part(0.5)
	_box(roof, Vector3(0, H - ROOF * 0.5, 0), Vector3(HALF * 2.0, ROOF, HALF * 2.0), conc)
	_col_box(Vector3(0, H - ROOF * 0.5, 0), Vector3(HALF * 2.0, ROOF, HALF * 2.0))
	for s: float in [1.0, -1.0]:
		_box(roof, Vector3(0, H - 0.06, s * (HALF + 0.03)), Vector3(HALF * 2.0 + 0.1, 0.16, 0.07), steel)
		_box(roof, Vector3(s * (HALF + 0.03), H - 0.06, 0), Vector3(0.07, 0.16, HALF * 2.0 + 0.1), steel)
		_box(roof, Vector3(0, H - 0.25, s * (HALF + 0.035)), Vector3(HALF * 2.0 - 0.3, 0.09, 0.02), _paint)
		_box(roof, Vector3(0, H - 0.31, s * (HALF + 0.037)), Vector3(HALF * 2.0 - 0.3, 0.03, 0.02), stripe)
	var cols := _part(0.62)
	for sx: float in [1.0, -1.0]:
		for sz: float in [1.0, -1.0]:
			var c := Vector3(sx * (HALF - 0.02), H * 0.5, sz * (HALF - 0.02))
			_box(cols, c, Vector3(0.2, H + 0.04, 0.06), steel, Vector3(0, PI * 0.25 * sx * sz, 0))
			_box(cols, c, Vector3(0.06, H + 0.04, 0.2), steel, Vector3(0, PI * 0.25 * sx * sz, 0))
			_box(cols, Vector3(c.x, 0.15, c.z), Vector3(0.26, 0.3, 0.26), haz)
	# Roof vent and an antenna stub.
	_cyl(roof, Vector3(0.9, H + 0.12, -0.9), 0.14, 0.17, 0.24, gun, Vector3.ZERO, 12)
	_cyl(roof, Vector3(0.9, H + 0.26, -0.9), 0.2, 0.2, 0.04, steel, Vector3.ZERO, 12)
	_seg(roof, Vector3(-1.4, H, 1.4), Vector3(-1.4, H + 0.9, 1.4), 0.012, steel, 6)
	_lamp(roof, Vector3(-1.4, H + 0.92, 1.4), Color(1.0, 0.25, 0.15), 0.03, 2.0)
	# --- Interior: lamp strip, cable tray, vent grille, a locker.
	var inside := _part(0.8)
	_lamp_mat = _mat(Color(1.0, 0.88, 0.7), 0.0, 0.3, 2.2)
	_box(inside, Vector3(0, H - ROOF - 0.04, 0), Vector3(0.12, 0.05, 2.2), gun)
	_box(inside, Vector3(0, H - ROOF - 0.07, 0), Vector3(0.08, 0.012, 2.0), _lamp_mat)
	for sx: float in [1.0, -1.0]:
		_box(inside, Vector3(sx * (inner_w - 0.08), H - ROOF - 0.12, 0), Vector3(0.1, 0.05, inner_w * 2.0 - 0.1), steel)
		_seg(inside, Vector3(sx * (inner_w - 0.06), H - ROOF - 0.09, -1.5), Vector3(sx * (inner_w - 0.06), H - ROOF - 0.09, 1.5), 0.02, gun, 6)
	_box(inside, Vector3(inner_w - 0.02, 1.9, -0.9), Vector3(0.03, 0.35, 0.5), gun)
	for k in 5:
		_box(inside, Vector3(inner_w - 0.04, 1.76 + k * 0.065, -0.9), Vector3(0.02, 0.02, 0.44), steel)
	_box(inside, Vector3(-(inner_w - 0.22), 0.9, -1.0), Vector3(0.4, 1.8, 0.55), _paint)
	_box(inside, Vector3(-(inner_w - 0.43), 0.9, -1.0), Vector3(0.01, 1.7, 0.02), seam)
	_box(inside, Vector3(-(inner_w - 0.22), 1.82, -1.0), Vector3(0.42, 0.04, 0.57), stripe)
	_lamp_light = OmniLight3D.new()
	_lamp_light.light_color = Color(1.0, 0.86, 0.7)
	_lamp_light.omni_range = 4.6
	_lamp_light.omni_attenuation = 1.3
	_lamp_light.light_energy = 0.0
	_lamp_light.shadow_enabled = false
	_lamp_light.position = Vector3(0, H - ROOF - 0.35, 0)
	inside.add_child(_lamp_light)


## Built (host / single player): clears any soil left inside the room and in front of the doorways
## (uneven floors, cavity walls): small DIG brushes, not logged for the enemy's scanner, synced.
func _on_assembled() -> void:
	if Net.is_client() or body == null or not is_instance_valid(body):
		return
	for c in [Vector3(0, 0.85, 0), Vector3(0.85, 0.85, 0.85), Vector3(-0.85, 0.85, 0.85), Vector3(0.85, 0.85, -0.85),
			Vector3(-0.85, 0.85, -0.85), Vector3(0, 0.95, 1.6), Vector3(0, 0.95, -1.6)]:
		Dig.dig_at(body, global_transform * (c as Vector3), 1.0, Dig.MODE_DIG, 6.0)


## On the surface: sandbags banked against the side walls (half buried). Not under the ground.
func _piece_ready() -> void:
	if has_meta("build_preview") or underground:
		return
	_berm = _part(0.7)
	var bag := _mat(Color(0.46, 0.41, 0.31), 0.0, 0.97)
	var bm := BoxMesh.new()
	bm.size = Vector3(0.55, 0.22, 0.32)
	for sx: float in [1.0, -1.0]:
		for row in 4:
			var n := 6 - row
			for i in n:
				var z := lerpf(-HALF + 0.4, HALF - 0.4, (float(i) + 0.5 * float(row % 2)) / float(maxi(n, 1)))
				var mi := MeshInstance3D.new()
				mi.mesh = bm
				mi.material_override = bag
				mi.position = Vector3(sx * (HALF + 0.2 + 0.32 * float(3 - row) * 0.5), 0.11 + float(row) * 0.2, z)
				mi.rotation = Vector3(0.0, PI * 0.5 + randf_range(-0.12, 0.12), randf_range(-0.05, 0.05) * sx)
				_berm.add_child(mi)


func _animate(delta: float) -> void:
	if has_meta("build_preview"):
		return
	var on := _build_t < 0.0 and not is_destroyed
	var want := (Balance.LIGHT_ENERGY * 0.75 if on else 0.0)
	if _hit_t > 0.2:
		want *= 0.4 + 0.6 * float(int(_t * 23.0) % 2)          # flickers on a hit
	_lamp_light.light_energy = lerpf(_lamp_light.light_energy, want, 1.0 - exp(-delta * 6.0))
	_lamp_mat.emission_energy_multiplier = 0.2 + 2.0 * clampf(_lamp_light.light_energy / maxf(Balance.LIGHT_ENERGY, 0.01), 0.0, 1.0)
	var pulse := 1.5 + 1.0 * sin(_t * 2.2)
	for m in _status_mats:
		(m as StandardMaterial3D).emission_energy_multiplier = pulse if on else 0.3
