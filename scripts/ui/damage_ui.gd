extends Control
## Damage feedback: red edge vignette (pulses on hits, stays faint at low health) and directional
## hit arcs around the screen centre pointing toward where the damage came from. Heavy hits (>= 25)
## muffle the world for a moment (FeelFx.muffle_hit: the shared Master low-pass of
## scripts/ui/feel_fx.gd, opening again over ~0.7 s); a hit with a source feeds the suppression
## meter. The heartbeat thumps in the helmet below 35 % health (faster as health drops) and under
## suppression (FeelFx.suppression > 0.3: quicker and a little louder) and, faintly, when spent
## (HelmetFx.exhaustion() > 0.7, scripts/ui/helmet_fx.gd); the strongest sets rate and level; it
## stops when dead. The one heartbeat (helmet_fx.gd breathes, this beats).

const HitFeel := preload("res://scripts/items/hit_feel.gd")
const FeelFx := preload("res://scripts/ui/feel_fx.gd")
const HelmetFx := preload("res://scripts/ui/helmet_fx.gd")

var _pulse := 0.0
var _beat_t := 0.0
var _low := 0.0
var _hits: Array = []          # [{"pos": Vector3, "t": float, "k": float}]
var _tex: GradientTexture2D
var _t := 0.0
var _beat_k := 0.0             # the vignette swells with each heartbeat (low health), then eases
const UI := preload("res://scripts/ui/ui_style.gd")
## Direction wedges (every HUD density shows them): full for HIT_HOLD s, then gone over HIT_FADE s;
## hits within ~25° of a wedge still up refresh it (MERGE_DOT) instead of stacking.
const HIT_HOLD := 0.45
const HIT_FADE := 0.55
const MERGE_DOT := 0.9


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Edge vignette: a deep suit-alarm red at the very edge, clear in the middle (never black).
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.58, 0.82, 1.0])
	g.colors = PackedColorArray([Color(0.7, 0.04, 0.04, 0.0), Color(0.7, 0.04, 0.04, 0.0),
			Color(0.78, 0.06, 0.05, 0.3), Color(0.6, 0.03, 0.03, 0.72)])
	_tex = GradientTexture2D.new()
	_tex.gradient = g
	_tex.fill = GradientTexture2D.FILL_RADIAL
	_tex.fill_from = Vector2(0.5, 0.5)
	_tex.fill_to = Vector2(1.08, 0.5)
	_tex.width = 256
	_tex.height = 256


func _ready() -> void:
	# The feel module listens for blasts from the start of the match (not only after a first hit).
	_boot.call_deferred()


func _boot() -> void:
	HitFeel.inst()
	FeelFx.inst()
	HelmetFx.inst()


func hit(amount: float, source_pos: Vector3) -> void:
	_pulse = minf(_pulse + clampf(amount / 25.0, 0.25, 1.0), 1.2)
	if source_pos != Vector3.ZERO:
		# Fire from (about) the same direction refreshes its wedge instead of stacking another one.
		var kk := clampf(amount / 25.0, 0.35, 1.0)
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		var merged := false
		if cam != null:
			var d0 := (source_pos - cam.global_position).normalized()
			for h in _hits:
				var d1 := ((h["pos"] as Vector3) - cam.global_position).normalized()
				if d0.dot(d1) > MERGE_DOT:
					h["pos"] = source_pos
					h["t"] = 0.0
					h["k"] = maxf(float(h["k"]), kk)
					merged = true
					break
		if not merged:
			_hits.append({"pos": source_pos, "t": 0.0, "k": kk})
			if _hits.size() > 6:
				_hits.remove_at(0)
	var ff = FeelFx.inst()
	if amount >= 25.0:
		ff.muffle_hit(clampf(amount / 60.0, 0.5, 1.0))
	if source_pos != Vector3.ZERO:            # fire from somewhere (not a fall / crash)
		ff.suppress(clampf(0.2 + amount / 60.0, 0.2, 0.6))
	queue_redraw()


## "Lub-dub" in the helmet: low health 70 → 110 bpm as health drops; suppression 83 → 103 bpm,
## a little quieter than the low-health beat; spent (exertion 0.7 → 1) 80 → 97 bpm, quieter still.
## The strongest wins.
func _update_heartbeat(delta: float, hp: float, dead: bool) -> void:
	var s := 0.0
	if Game.has_meta("feel_fx"):
		var ff = Game.get_meta("feel_fx")
		if is_instance_valid(ff):
			s = float(ff.suppression)
	var ex := HelmetFx.exhaustion()
	var low := hp < 0.35
	var sup := s > 0.3
	var spent := ex > 0.7
	if dead or not (low or sup or spent):
		_beat_t = 0.0
		return
	_beat_t -= delta
	if _beat_t > 0.0:
		return
	var gap := 9.0
	var vol := -80.0
	if low:
		var k := clampf((0.35 - hp) / 0.3, 0.0, 1.0)
		gap = lerpf(0.86, 0.55, k)
		vol = lerpf(-15.0, -7.0, k)
	if sup:
		var ks := clampf((s - 0.3) / 0.7, 0.0, 1.0)
		gap = minf(gap, lerpf(0.72, 0.58, ks))
		vol = maxf(vol, lerpf(-22.0, -13.0, ks))
	if spent:
		var ke := clampf((ex - 0.7) / 0.3, 0.0, 1.0)
		gap = minf(gap, lerpf(0.75, 0.62, ke))
		vol = maxf(vol, lerpf(-27.0, -19.0, ke))
	_beat_t = gap
	HitFeel.inst().play_ui("heartbeat", vol, randf_range(0.98, 1.02))
	if low:
		_beat_k = 1.0                           # the low-health vignette swells with the beat


func _process(delta: float) -> void:
	_t += delta
	var p = Game.player
	var hp: float = 1.0
	var dead := false
	if p != null and p.get("hp") != null:
		hp = float(p.hp) / maxf(float(p.hp_max), 1.0)
		dead = p.has_method("is_dead") and p.is_dead()
	_update_heartbeat(delta, hp, dead)
	var low_target := clampf((0.35 - hp) / 0.35, 0.0, 1.0)
	_low = lerpf(_low, low_target, 1.0 - exp(-3.0 * delta))
	_pulse = maxf(_pulse - delta * 1.6, 0.0)
	_beat_k = maxf(_beat_k - delta * 2.6, 0.0)
	for i in range(_hits.size() - 1, -1, -1):
		_hits[i]["t"] += delta
		if _hits[i]["t"] > HIT_HOLD + HIT_FADE:
			_hits.remove_at(i)
	if _pulse > 0.0 or _low > 0.01 or not _hits.is_empty():
		queue_redraw()
	visible = _pulse > 0.0 or _low > 0.01 or not _hits.is_empty()


## The edge vignette (hit pulse; low health: a slow breathing plus a swell on each heartbeat) and the
## direction wedges: a curved plate around the centre with a pointed tip toward the source, a dark
## outline, held HIT_HOLD s then gone over HIT_FADE s (design system: UI.CRIT, scaled with the window
## height). Shown in every HUD density.
func _draw() -> void:
	var beat := _beat_k * _beat_k
	var a := clampf(_pulse * 0.8 + _low * (0.38 + 0.1 * sin(_t * 3.5) + 0.22 * beat), 0.0, 1.0)
	if a > 0.01:
		draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false, Color(1, 1, 1, a))
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var k := UI.scale_k(size)
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.16
	for h in _hits:
		var local: Vector3 = cam.global_transform.affine_inverse() * (h["pos"] as Vector3)
		var ang := atan2(local.x, -local.z)          # 0 = in front, + = to the right
		var t: float = h["t"]
		var fade := 1.0 - UI.smooth(clampf((t - HIT_HOLD) / HIT_FADE, 0.0, 1.0))
		var pop := 1.0 + 0.25 * maxf(0.0, 1.0 - t / 0.1)
		# Even a graze reads (0.7); a heavy hit is fully opaque and a little wider.
		var hk := float(h["k"])
		var al := lerpf(0.7, 1.0, hk) * fade
		_wedge(c, r * pop, ang, lerpf(0.28, 0.36, hk), lerpf(10.0, 13.0, hk) * k, Color(UI.CRIT, al), k)


## A direction wedge at angle `ang` (0 = up / in front, clockwise), half-width `half` (rad), thickness
## `th`: an arc plate with a tip pointing outward.
func _wedge(c: Vector2, r: float, ang: float, half: float, th: float, col: Color, k: float) -> void:
	var base := -PI * 0.5 + ang
	var n := 12
	var pts := PackedVector2Array()
	for i in n + 1:
		var u := base - half + 2.0 * half * float(i) / n
		var taper := 1.0 - 0.55 * absf(float(i) / n * 2.0 - 1.0)
		pts.append(c + Vector2(cos(u), sin(u)) * (r + th * taper))
	pts.append(c + Vector2(cos(base), sin(base)) * (r + th + 12.0 * k))      # the tip
	pts.append(pts[0])
	var inner := PackedVector2Array()
	for i in n + 1:
		var u := base + half - 2.0 * half * float(i) / n
		inner.append(c + Vector2(cos(u), sin(u)) * r)
	var poly := PackedVector2Array()
	for i in n + 1:
		poly.append(pts[i])
	for p in inner:
		poly.append(p)
	# A dark rim first, so the wedge reads on bright ground and sky as well (never pure black).
	var rim := PackedVector2Array(poly)
	rim.append(poly[0])
	draw_polyline(rim, Color(UI.OUTLINE, 0.55 * col.a), maxf(3.5 * k, 2.5), true)
	draw_colored_polygon(poly, Color(col, col.a * 0.8))
	var tip := PackedVector2Array([c + Vector2(cos(base - 0.07), sin(base - 0.07)) * (r + th * 0.9),
			c + Vector2(cos(base), sin(base)) * (r + th + 12.0 * k), c + Vector2(cos(base + 0.07), sin(base + 0.07)) * (r + th * 0.9)])
	draw_colored_polygon(tip, col)
	var edge := PackedVector2Array()
	for i in n + 1:
		edge.append(pts[i])
	draw_polyline(edge, Color(1.0, 0.75, 0.68, col.a * 0.8), maxf(1.5 * k, 1.0), true)
