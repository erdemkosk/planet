extends CanvasLayer
## War overlay: the two core health bars at the top centre ("YURT ÇEKİRDEĞİ" / "RAKİP ÇEKİRDEĞİ",
## flashing when hit); under them the warnings: a blinking red "RAKİP SENİ GÖRDÜ" while a rival
## Uçaksavar (or a bot's rifle) is on the player's skiff, "RAKİP MEKİĞİ YAKLAŞIYOR" with the
## distance and a marker / screen-edge arrow toward it while the rival raid skiff flies at us, and
## "Rakip kazıyor: NN m" while a raider digs toward our core; a name tag ("Rakip — Kazıcı" + hp)
## under the crosshair when aiming at a rival bot within 70 m; and the end screen ("ZAFER" /
## "YENİLGİ" with Yeniden başla / Çık).

const UI := preload("res://scripts/ui/ui_style.gd")
const Kit := preload("res://scripts/save/menu_kit.gd")
const Flak := preload("res://scripts/war/flak.gd")

var war                              # scripts/war/war.gd
var _top: Control
var _end: Control
var _font: Font
var _font_b: Font
var _flash := {"home": 0.0, "rival": 0.0}
var _last := {"home": -1.0, "rival": -1.0}
var _seen := false
var _seen_t := 0.0
var _seen_check := 0.0
var _inbound: Node3D
var _inbound_was := false
var _tag_bot: Node3D
var _tag_t := 0.0


func _ready() -> void:
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = UI.font(500)
	_font_b = UI.font(700)
	_top = Control.new()
	_top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.draw.connect(_draw_top)
	add_child(_top)


func _process(delta: float) -> void:
	if war == null:
		return
	for k in ["home", "rival"]:
		var c = war.home_core if k == "home" else war.rival_core
		if c == null or not is_instance_valid(c):
			continue
		if _last[k] >= 0.0 and c.hp < _last[k]:
			_flash[k] = 1.0
		_last[k] = c.hp
		_flash[k] = maxf(float(_flash[k]) - delta * 1.5, 0.0)
	# "Seen" warning (checked ~8 times a second).
	_seen_check -= delta
	if _seen_check <= 0.0:
		_seen_check = 0.12
		var was := _seen
		_seen = Flak.rival_tracking(get_tree())
		if not _seen:
			for a in get_tree().get_nodes_in_group("war_ai"):
				if a.get("shooting_skiff") == true:
					_seen = true
		if _seen and not was:
			_seen_t = 0.0
			if Game.sfx:
				Game.sfx.play("error", -12.0, 1.4)
		var tm = war.team
		_inbound = tm.inbound_skiff() if tm != null and is_instance_valid(tm) else null
		if _inbound != null and not _inbound_was and Game.sfx:
			Game.sfx.play("error", -8.0, 0.8)
		_inbound_was = _inbound != null
	_seen_t += delta
	# Name tag: a rival bot under the crosshair.
	_tag_t -= delta
	if _tag_t <= 0.0:
		_tag_t = 0.1
		_tag_bot = _aimed_bot()
	_top.queue_redraw()


func _aimed_bot() -> Node3D:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var from := cam.global_position
	var to := from - cam.global_transform.basis.z * 70.0
	var q := PhysicsRayQueryParameters3D.create(from, to, Game.LAYER_PLAYER | Game.LAYER_TERRAIN | Game.LAYER_SHIP)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl is CollisionObject3D:
		q.exclude = [(pl as CollisionObject3D).get_rid()]
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var col = hit["collider"]
	if col is Node and (col as Node).has_meta("ai_bot"):
		var b = (col as Node).get_meta("ai_bot")
		if b is Node3D and is_instance_valid(b) and not b.is_dead():
			return b
	return null


func _draw_top() -> void:
	if war == null:
		return
	var w := _top.size.x
	var bw := 230.0
	var gap := 40.0
	var y := 18.0
	_bar(Vector2(w * 0.5 - gap * 0.5 - bw, y), bw, "YURT ÇEKİRDEĞİ", war.home_core, Color(0.4, 0.88, 1.0), _flash["home"])
	_bar(Vector2(w * 0.5 + gap * 0.5, y), bw, "RAKİP ÇEKİRDEĞİ", war.rival_core, Color(1.0, 0.32, 0.2), _flash["rival"])
	var wy := y + 50.0
	if _seen and fmod(_seen_t, 0.7) < 0.45:
		_warn(w, wy, "RAKİP SENİ GÖRDÜ")
	if _seen:
		wy += 32.0
	var cam := get_viewport().get_camera_3d()
	if _inbound != null and is_instance_valid(_inbound) and cam != null:
		var sp: Vector3 = _inbound.global_position
		var dist := cam.global_position.distance_to(sp)
		_warn(w, wy, "RAKİP MEKİĞİ YAKLAŞIYOR  ·  %d m" % int(dist))
		wy += 32.0
		_skiff_marker(cam, sp)
	var tm = war.team
	if tm != null and is_instance_valid(tm) and float(tm.raid_dig_dist) >= 0.0:
		_warn(w, wy, "Rakip kazıyor: %d m" % int(tm.raid_dig_dist))
		wy += 32.0
	if _tag_bot != null and is_instance_valid(_tag_bot):
		var c := _top.size * 0.5
		var name_s: String = str(_tag_bot.callsign)
		var tw := _font_b.get_string_size(name_s, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		_text(Vector2(c.x - tw * 0.5, c.y + 46.0), name_s, 14, Color(1.0, 0.5, 0.42), _font_b)
		var f := clampf(float(_tag_bot.hp) / maxf(float(_tag_bot.hp_max), 1.0), 0.0, 1.0)
		var r := Rect2(Vector2(c.x - 40.0, c.y + 54.0), Vector2(80.0, 4.0))
		_top.draw_rect(r, Color(0, 0, 0, 0.45))
		_top.draw_rect(Rect2(r.position, Vector2(r.size.x * f, r.size.y)), Color(1.0, 0.35, 0.28))


## A red warning plate centred at the top.
func _warn(w: float, y: float, txt: String) -> void:
	var fs := 15
	var tw := _font_b.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var o := Vector2(w * 0.5 - tw * 0.5 - 14.0, y)
	_top.draw_style_box(UI.box(Color(0.35, 0.02, 0.02, 0.55), 8, Color(1.0, 0.3, 0.25, 0.8), 1, 0),
			Rect2(o, Vector2(tw + 28.0, 26.0)))
	_text(o + Vector2(14, 19), txt, fs, Color(1.0, 0.42, 0.36), _font_b)


## The inbound skiff: a bracket on it when on screen, else an arrow at the screen edge toward it.
func _skiff_marker(cam: Camera3D, p: Vector3) -> void:
	var vs := _top.size
	var c := vs * 0.5
	var red := Color(1.0, 0.35, 0.3, 0.95)
	var behind := cam.is_position_behind(p)
	var s := cam.unproject_position(p)
	var inside := not behind and s.x > 30.0 and s.y > 30.0 and s.x < vs.x - 30.0 and s.y < vs.y - 30.0
	if inside:
		var k := 16.0
		for q in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var qv: Vector2 = q
			_top.draw_line(s + qv * k, s + Vector2(qv.x * k * 0.4, qv.y * k), red, 2.0, true)
			_top.draw_line(s + qv * k, s + Vector2(qv.x * k, qv.y * k * 0.4), red, 2.0, true)
		return
	var d := s - c
	if behind:
		d = -d
	if d.length_squared() < 1.0:
		d = Vector2(0, 1)
	d = d.normalized()
	var r := minf(vs.x, vs.y) * 0.42
	var tip := c + d * r
	var side := Vector2(-d.y, d.x)
	_top.draw_colored_polygon(PackedVector2Array([tip + d * 14.0, tip - d * 6.0 + side * 10.0, tip - d * 6.0 - side * 10.0]), red)


func _bar(o: Vector2, bw: float, title: String, core, col: Color, flash: float) -> void:
	var hp := 0.0
	var mx := 100.0
	if core != null and is_instance_valid(core):
		hp = core.hp
		mx = core.hp_max
	var frac := clampf(hp / maxf(mx, 1.0), 0.0, 1.0)
	var sb := UI.box(Color(0.03, 0.05, 0.08, 0.55), 10, Color(col, 0.3 + 0.5 * flash), 1, 0)
	_top.draw_style_box(sb, Rect2(o, Vector2(bw, 42)))
	_text(o + Vector2(12, 17), title, 11, Color(col.lightened(0.25), 0.95), _font_b)
	_text(o + Vector2(bw - 44, 17), "%d" % int(ceilf(hp)), 13, UI.TEXT, _font_b)
	var r := Rect2(o + Vector2(12, 26), Vector2(bw - 24, 6))
	_top.draw_rect(r, Color(1, 1, 1, 0.1))
	_top.draw_rect(Rect2(r.position, Vector2(r.size.x * frac, r.size.y)), col.lerp(Color.WHITE, flash * 0.6))


func _text(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	_top.draw_string(f, p + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.55 * col.a))
	_top.draw_string(f, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


## The end screen: the game pauses, the mouse is freed.
func show_end(won: bool) -> void:
	if _end != null:
		return
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_end = Control.new()
	_end.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_end.theme = UI.make_theme()
	add_child(_end)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_end.add_child(bg)
	create_tween().tween_property(bg, "color:a", 0.62, 0.6)
	var col := UI.vbox(_end, 10)
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	col.grow_horizontal = Control.GROW_DIRECTION_BOTH
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.custom_minimum_size = Vector2(520, 0)
	var tcol := UI.GOOD if won else UI.BAD
	var t := Kit.heading(col, "ZAFER" if won else "YENİLGİ", 64, tcol, 6)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sub := UI.label(col, "Rakibin çekirdeği yok edildi" if won else "Çekirdeğimiz yok oldu", 20, UI.TEXT, 600)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var gap := Control.new()
	gap.custom_minimum_size.y = 24
	col.add_child(gap)
	var again := Kit.menu_button(col, "Yeniden başla", "", "Yeni bir maç", 520.0)
	again.pressed.connect(_restart)
	Kit.menu_button(col, "Çık", "", "Masaüstüne dön", 520.0, true).pressed.connect(func() -> void: get_tree().quit())
	again.call_deferred("grab_focus")
	if Game.sfx:
		Game.sfx.play("craft" if won else "error", -4.0, 0.8 if won else 0.7)


func _restart() -> void:
	get_tree().paused = false
	Game.reset_state()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().reload_current_scene()
