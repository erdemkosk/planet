extends "res://scripts/war/base_piece.gd"
## Takviyeli Duvar (reinforced wall segment), İnşa Aracı (Savunma; Balance.WALL_*): 3 m wide, 2.5 m
## high, 0.45 m thick. A cast concrete core on a wider footing beam, bolted steel facing plates on both
## faces, steel H-columns at the ends, a steel cap with the team stripe, and a narrow firing slit at
## chest height in the middle (you can shoot out of it; it is too narrow to climb). Cheap cover: blocks
## bullets (ship-layer collider) and blasts (× WALL_BLAST_MULT). Snaps end to end and at right-angle
## corners to other walls, plugs a Sığınak Modülü doorway from outside or carries a module's face on
## sideways (BaseKit.snap). Group "war_wall". Multiplayer state: hp only.

const W := 3.0
const HGT := 2.5
const T := 0.45
const SLIT_Y := 1.42                    # slit centre height
const SLIT_H := 0.2
const SLIT_W := 0.9


static func footprint() -> Vector3:
	return Vector3(W * 0.5, HGT * 0.5, T * 0.5)


func piece_kind() -> String:
	return "armor_wall"


func piece_name() -> String:
	return "Takviyeli Duvar"


func piece_group() -> String:
	return "war_wall"


func piece_hp() -> float:
	return Balance.WALL_HP


func footprint_r() -> float:
	return Balance.WALL_FOOTPRINT


func blast_mult() -> float:
	return Balance.WALL_BLAST_MULT


func _foundation_shape() -> Array:
	return [Foundation.rect(-W * 0.5, W * 0.5, -0.35, 0.35, 0.0, 3, 1), [], Color(0.4, 0.39, 0.37)]


func _build_piece() -> void:
	var home := team == "home"
	var conc := concrete()
	var conc_d := concrete(true)
	_paint = _mat(Color(0.84, 0.85, 0.84) if home else Color(0.22, 0.21, 0.21), 0.15 if home else 0.5, 0.5)
	var stripe := _mat(Color(0.95, 0.42, 0.08) if home else Color(0.72, 0.12, 0.08), 0.0, 0.5)
	var steel := _mat(Color(0.34, 0.35, 0.37), 0.82, 0.42)
	var plate := _mat(Color(0.27, 0.28, 0.29), 0.75, 0.5)
	var bolt := _mat(Color(0.55, 0.56, 0.58), 0.9, 0.3)
	var haz := hazard()
	# --- Footing beam.
	var foot := _part(0.0)
	_box(foot, Vector3(0, 0.15, 0), Vector3(W, 0.3, 0.7), conc_d)
	_col_box(Vector3(0, 0.15, 0), Vector3(W, 0.3, 0.7))
	# --- Concrete core: below the slit, beside it, above it.
	var core := _part(0.12)
	var lo_h := SLIT_Y - SLIT_H * 0.5 - 0.3
	_box(core, Vector3(0, 0.3 + lo_h * 0.5, 0), Vector3(W - 0.1, lo_h, 0.36), conc)
	_col_box(Vector3(0, 0.3 + lo_h * 0.5, 0), Vector3(W - 0.1, lo_h, 0.36))
	var side := (W - 0.1 - SLIT_W) * 0.5
	for sx: float in [1.0, -1.0]:
		_box(core, Vector3(sx * (SLIT_W * 0.5 + side * 0.5), SLIT_Y, 0), Vector3(side, SLIT_H, 0.36), conc)
		_col_box(Vector3(sx * (SLIT_W * 0.5 + side * 0.5), SLIT_Y, 0), Vector3(side, SLIT_H, 0.36))
	var top0 := SLIT_Y + SLIT_H * 0.5
	var hi_h := HGT - 0.08 - top0
	_box(core, Vector3(0, top0 + hi_h * 0.5, 0), Vector3(W - 0.1, hi_h, 0.36), conc)
	_col_box(Vector3(0, top0 + hi_h * 0.5, 0), Vector3(W - 0.1, hi_h, 0.36))
	# --- Steel facing plates (two faces × three panels, the slit left open), bolts in rows.
	var face := _part(0.3)
	for sz: float in [1.0, -1.0]:
		for i in 3:
			var xc := (float(i) - 1.0) * 0.97
			var z := sz * 0.2
			if i == 1:
				_box(face, Vector3(xc, 0.3 + (SLIT_Y - SLIT_H * 0.5 - 0.3) * 0.5, z), Vector3(0.93, SLIT_Y - SLIT_H * 0.5 - 0.32, 0.035), plate)
				_box(face, Vector3(xc, (top0 + HGT - 0.1) * 0.5 + 0.01, z), Vector3(0.93, HGT - 0.1 - top0 - 0.02, 0.035), plate)
				# Slit frame.
				_box(face, Vector3(xc, SLIT_Y - SLIT_H * 0.5 - 0.02, sz * 0.215), Vector3(SLIT_W + 0.06, 0.04, 0.03), steel)
				_box(face, Vector3(xc, SLIT_Y + SLIT_H * 0.5 + 0.02, sz * 0.215), Vector3(SLIT_W + 0.06, 0.04, 0.03), steel)
			else:
				_box(face, Vector3(xc, 0.3 + (HGT - 0.4) * 0.5, z), Vector3(0.93, HGT - 0.42, 0.035), plate)
			for row in [0.45, 1.25, 2.1]:
				for c in [-0.4, 0.4]:
					if i == 1 and absf(float(row) - SLIT_Y) < 0.3:
						continue
					_box(face, Vector3(xc + float(c), float(row), sz * 0.222), Vector3(0.035, 0.035, 0.012), bolt)
	# --- End columns, cap, stripe, hazard bands.
	var trim := _part(0.45)
	for sx: float in [1.0, -1.0]:
		var x := sx * (W * 0.5 - 0.07)
		_box(trim, Vector3(x, HGT * 0.5, 0), Vector3(0.14, HGT, 0.06), steel)
		for sz: float in [1.0, -1.0]:
			_box(trim, Vector3(x, HGT * 0.5, sz * 0.205), Vector3(0.14, HGT, 0.04), steel)
		_box(trim, Vector3(x, 0.45, 0), Vector3(0.16, 0.3, T + 0.02), haz)
		_col_box(Vector3(x, HGT * 0.5, 0), Vector3(0.14, HGT, T))
	_box(trim, Vector3(0, HGT - 0.04, 0), Vector3(W, 0.08, T + 0.04), steel)
	_box(trim, Vector3(0, HGT - 0.12, 0), Vector3(W - 0.3, 0.06, T + 0.05), _paint)
	_box(trim, Vector3(0, HGT - 0.165, 0), Vector3(W - 0.3, 0.025, T + 0.055), stripe)
