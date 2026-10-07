extends Control
## Incoming grenade warning: every live ENEMY hand grenade within GRENADE_HUD_RANGE m of the player
## gets a marker: at the grenade's screen position, or on the screen edge pointing toward it when it
## is off screen or behind. A round glass plate (the design system, scripts/ui/ui_style.gd) with a
## grenade glyph, the fuse left as a ring (UI.draw_ring), a pulsing outer ring that beats faster as
## the fuse burns down, and the distance in metres; amber (UI.WARN) outside the blast radius, red
## (UI.CRIT) inside it. Pops in when first seen.
## Tracking (read only, cheap): every Projectiles instance (scripts/items/projectiles.gd, group
## "grenade_sim") holds its grenades in `_list` ({node, kind, fuse, cfg}); a "hand" one whose cfg is
## not player_owned and whose team is not ours is an enemy grenade: the rival team's throws
## (RivalTeam.events().grenade_thrown, its shared "RivalGrenades"), and in multiplayer the replays of
## the other side's throws (net_bots.gd / net_players.gd, team = Net.local_team(side)).
## A child of the combat overlay (combat_hud.gd) and in group "gameplay_overlay" (hidden on the end
## screen, menus, pause: overlay_guard.gd).

const UI := preload("res://scripts/ui/ui_style.gd")
const Balance := preload("res://scripts/war/balance.gd")

var _items: Array = []                   # {pos, d, fuse, r, age}
var _seen := {}                          # grenade node instance id -> msec first seen (pop-in)
var _t := 0.0
var _font_n: Font


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("gameplay_overlay")
	_font_n = UI.font_num(800)
	visible = false


func _process(delta: float) -> void:
	_t += delta / maxf(Engine.time_scale, 0.01)
	_scan()
	visible = not _items.is_empty()
	if visible:
		queue_redraw()


func _scan() -> void:
	_items.clear()
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or not (pl is Node3D):
		return
	if pl.has_method("is_dead") and pl.is_dead():
		return
	var me: Vector3 = (pl as Node3D).global_position + (pl as Node3D).global_transform.basis.y * 0.9
	var mine := Game.team_of(pl)
	var now := Time.get_ticks_msec()
	for sim in get_tree().get_nodes_in_group("grenade_sim"):
		var list = sim.get("_list")
		if not (list is Array):
			continue
		for g in list:
			if not (g is Dictionary) or str(g.get("kind", "")) != "hand":
				continue
			var node = g.get("node")
			if node == null or not is_instance_valid(node) or not (node is Node3D) or not (node as Node3D).visible:
				continue
			var cfg = g.get("cfg")
			if not (cfg is Dictionary) or bool(cfg.get("player_owned", false)) or str(cfg.get("team", "")) == mine:
				continue
			var p := (node as Node3D).global_position
			var d := p.distance_to(me)
			if d > Balance.GRENADE_HUD_RANGE:
				continue
			var id := (node as Object).get_instance_id()
			if not _seen.has(id):
				_seen[id] = now
			_items.append({"pos": p, "d": d, "fuse": float(g.get("fuse", 0.0)),
					"r": float(cfg.get("radius", Balance.GRENADE_RADIUS)), "age": float(now - int(_seen[id])) * 0.001})
	if _seen.size() > 24:
		for id in _seen.keys():
			if not is_instance_id_valid(id):
				_seen.erase(id)


func _draw() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var k := UI.scale_k(size)
	var c := size * 0.5
	var margin := 72.0 * k
	var inner := Rect2(Vector2(margin, margin), size - Vector2(margin, margin) * 2.0)
	for it in _items:
		var p: Vector3 = it["pos"]
		var behind := cam.is_position_behind(p)
		var sp := Vector2.ZERO if behind else cam.unproject_position(p)
		var edge := Vector2.ZERO                 # off screen: the direction toward it (screen space)
		if behind or not inner.has_point(sp):
			var dir2: Vector2
			if behind:
				var local := cam.global_transform.affine_inverse() * p
				dir2 = Vector2(local.x, -local.y)
			else:
				dir2 = sp - c
			if dir2.length_squared() < 1e-4:
				dir2 = Vector2(0.0, 1.0)
			edge = dir2.normalized()
			var half := c - Vector2(margin, margin)
			var t := minf(half.x / maxf(absf(edge.x), 1e-4), half.y / maxf(absf(edge.y), 1e-4))
			sp = c + edge * t
		_draw_marker(sp, it, edge, k)


## One marker at sp; `edge` (unit, screen space) = off screen toward it (an arrow points out there).
func _draw_marker(sp: Vector2, it: Dictionary, edge: Vector2, k: float) -> void:
	var d: float = it["d"]
	var inside := d <= float(it["r"])
	var col: Color = UI.CRIT if inside else UI.WARN
	var age: float = it["age"]
	var pop := 1.0 + 0.4 * clampf(1.0 - age / 0.16, 0.0, 1.0)
	var a := clampf(age / 0.08, 0.0, 1.0)
	var fuse_k := clampf(float(it["fuse"]) / Balance.GRENADE_FUSE, 0.0, 1.0)
	var hz := lerpf(1.6, 6.0, 1.0 - fuse_k) * (1.4 if inside else 1.0)
	var beat := fmod(_t * hz, 1.0)
	var r := 21.0 * k * pop
	# Pulsing outer ring (expands and fades each beat) and a soft glow when inside the blast.
	if inside:
		draw_circle(sp, r * 1.55, Color(col, 0.12 * a * (1.0 - beat)))
	draw_arc(sp, r + (4.0 + 12.0 * beat) * k, 0.0, TAU, 40, Color(col, 0.85 * a * (1.0 - beat)), maxf(2.0 * k, 1.5), true)
	# The plate: wrist-screen glass, a thin frame, the fuse ring.
	draw_circle(sp, r, Color(UI.GLASS, UI.GLASS_A * a))
	draw_arc(sp, r, 0.0, TAU, 40, Color(UI.SUIT_WHITE, 0.22 * a), maxf(1.0 * k, 1.0), true)
	UI.draw_ring(self, sp, r - 3.5 * k, fuse_k, Color(col, a), maxf(2.6 * k, 2.0), false)
	_glyph(sp + Vector2(0.0, 1.5 * k), 7.0 * k * pop, Color(col.lightened(0.1), a))
	# Off screen: a chevron on the outer side pointing toward it.
	if edge != Vector2.ZERO:
		var tip := sp + edge * (r + 13.0 * k)
		var side := Vector2(-edge.y, edge.x)
		var base := sp + edge * (r + 5.0 * k)
		var tri := PackedVector2Array([tip, base + side * 6.0 * k, base - side * 6.0 * k])
		draw_colored_polygon(tri, Color(col, a))
		draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color(UI.OUTLINE, UI.OUTLINE.a * a), maxf(1.0 * k, 1.0), true)
	# Distance: under the plate on screen, on the inner side at the edge.
	var txt := "%d m" % int(ceilf(d))
	var fsz := UI.fs(13.0, k)
	var lp := sp + Vector2(0.0, r + 16.0 * k)
	if edge != Vector2.ZERO:
		lp = sp - edge * (r + 14.0 * k) + Vector2(0.0, fsz * 0.36)
	UI.draw_text_c(self, _font_n, lp, txt, fsz, Color(col.lightened(0.15) if inside else UI.TEXT, a), 3)


## Grenade glyph (centre c, body radius s): a round body, the fuse head on top and the lever down
## its side, outlined.
func _glyph(c: Vector2, s: float, col: Color) -> void:
	var ol := Color(UI.OUTLINE, UI.OUTLINE.a * col.a)
	var head := Rect2(c + Vector2(-s * 0.38, -s * 1.55), Vector2(s * 0.76, s * 0.6))
	draw_circle(c, s + 1.2, ol)
	draw_rect(head.grow(1.0), ol)
	draw_circle(c, s, col)
	draw_rect(head, col)
	draw_line(c + Vector2(s * 0.38, -s * 1.3), c + Vector2(s * 1.05, -s * 0.2), ol, maxf(s * 0.42, 2.0), true)
	draw_line(c + Vector2(s * 0.38, -s * 1.3), c + Vector2(s * 1.05, -s * 0.2), col, maxf(s * 0.24, 1.2), true)
	draw_arc(c + Vector2(-s * 0.15, -s * 0.15), s * 0.55, PI * 1.05, PI * 1.6, 8, Color(UI.SUIT_WHITE, 0.55 * col.a), maxf(s * 0.16, 1.0), true)
