extends Control
## Damage feedback: red edge vignette (pulses on hits, stays faint at low health) and directional
## hit arcs around the screen centre pointing toward where the damage came from.

var _pulse := 0.0
var _low := 0.0
var _hits: Array = []          # [{"pos": Vector3, "t": float, "k": float}]
var _tex: GradientTexture2D
var _t := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.55, 0.8, 1.0])
	g.colors = PackedColorArray([Color(0.6, 0.0, 0.0, 0.0), Color(0.6, 0.0, 0.0, 0.0),
			Color(0.75, 0.02, 0.02, 0.35), Color(0.55, 0.0, 0.0, 0.85)])
	_tex = GradientTexture2D.new()
	_tex.gradient = g
	_tex.fill = GradientTexture2D.FILL_RADIAL
	_tex.fill_from = Vector2(0.5, 0.5)
	_tex.fill_to = Vector2(1.08, 0.5)
	_tex.width = 256
	_tex.height = 256


func hit(amount: float, source_pos: Vector3) -> void:
	_pulse = minf(_pulse + clampf(amount / 25.0, 0.25, 1.0), 1.2)
	if source_pos != Vector3.ZERO:
		_hits.append({"pos": source_pos, "t": 0.0, "k": clampf(amount / 25.0, 0.35, 1.0)})
		if _hits.size() > 6:
			_hits.remove_at(0)
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	var p = Game.player
	var hp: float = 1.0
	if p != null and p.get("hp") != null:
		hp = float(p.hp) / maxf(float(p.hp_max), 1.0)
	var low_target := clampf((0.35 - hp) / 0.35, 0.0, 1.0)
	_low = lerpf(_low, low_target, 1.0 - exp(-3.0 * delta))
	_pulse = maxf(_pulse - delta * 1.6, 0.0)
	for i in range(_hits.size() - 1, -1, -1):
		_hits[i]["t"] += delta
		if _hits[i]["t"] > 1.6:
			_hits.remove_at(i)
	if _pulse > 0.0 or _low > 0.01 or not _hits.is_empty():
		queue_redraw()
	visible = _pulse > 0.0 or _low > 0.01 or not _hits.is_empty()


func _draw() -> void:
	var a := clampf(_pulse * 0.8 + _low * (0.45 + 0.15 * sin(_t * 3.5)), 0.0, 1.0)
	if a > 0.01:
		draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false, Color(1, 1, 1, a))
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.16
	for h in _hits:
		var local: Vector3 = cam.global_transform.affine_inverse() * (h["pos"] as Vector3)
		var ang := atan2(local.x, -local.z)          # 0 = in front, + = to the right
		var fade := clampf(1.0 - (h["t"] - 0.6), 0.0, 1.0)
		var col := Color(1.0, 0.18, 0.12, 0.85 * fade * h["k"])
		var start := -PI * 0.5 + ang - 0.32
		draw_arc(c, r, start, start + 0.64, 24, col, 7.0, true)
		draw_arc(c, r + 9.0, start + 0.12, start + 0.52, 18, Color(col, col.a * 0.5), 3.0, true)
