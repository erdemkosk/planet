extends Node3D
## Co-op build awareness (2026-10-06; the user: "co-op'ta inşa daha kolay ... herkes anlayabilsin"):
##   - the PARTNER'S BUILD INTENT: while the co-op partner holds the İnşa Aracı on a spot, his hologram
##     shows here faintly (cyan, his name over it) and a small note at the top: "ALİ · Taret
##     yerleştiriyor" (hidden ~1.2 s after his last update);
##   - BUILD PINGS: middle click / B with the build tool drops a "BURAYA KUR: <yapı>" marker (a light
##     beam, a ground ring, the label with who and how far) that both players see for
##     Balance.BUILD_PING_TIME s (at most BUILD_PING_MAX per player);
##   - TEAM NOTIFICATIONS: "Arkadaşın (Ali) Uçaksavar kurdu".
## The network layer (scripts/net/net_world.gd, the MP agent) forwards the local side and feeds the
## remote side; in single player only the local pings show.
##   BuildIntent.inst() -> this node (made on first use under the current scene)
##   signal intent_out(data)          the local player's intent, at most 5 Hz while it changes, and
##                                    {"on": false} once when he stops: {"on", "id" (build kind),
##                                    "name" (display name), "xf" (Transform3D), "ok" (can build)}
##   signal ping_out(pos, label)      a local ping to forward (label: the piece's name)
##   BuildIntent.set_local(data)      (scripts/war/build_tool.gd, every placement check)
##   BuildIntent.show_remote(data, who)   the partner's intent (same shape)
##   BuildIntent.ping(pos, label, who, local := true)
##   BuildIntent.notify_built(who, piece_name)
## Group "gameplay_overlay" on its 2D note (scripts/ui/overlay_guard.gd hides it with the menus).

const UI := preload("res://scripts/ui/ui_style.gd")
const Balance := preload("res://scripts/war/balance.gd")
const BaseKit := preload("res://scripts/war/base_kit.gd")
const BuildPreview := preload("res://scripts/war/build_preview.gd")
const SCRIPT_PATH := "res://scripts/war/build_intent.gd"
const GHOST_COL := Color(0.45, 0.9, 1.0)
const PING_COL := Color(1.0, 0.6, 0.22)
const REMOTE_HOLD := 1.2               # s the partner's ghost stays without an update
const OUT_PERIOD := 0.2                # s between two intent_out messages

signal intent_out(data: Dictionary)
signal ping_out(pos: Vector3, label: String)

static var _inst: Node = null

var _local := {}
var _local_on := false
var _out_t := 0.0
var _out_dirty := false
var _remote := {}
var _remote_who := ""
var _remote_t := 0.0
var _ghost: Node3D
var _ghost_kind := ""
var _ghost_label: Label3D
var _ghost_mat: StandardMaterial3D
var _pings: Array = []                 # {node, label, beam_mat, ring_mat, t, who, text, pos}
var _canvas: CanvasLayer
var _note: Control
var _font_b: Font
var _font: Font


## The node (created under the current scene on first use; gone with the scene).
static func inst() -> Node:
	if _inst != null and is_instance_valid(_inst) and (_inst as Node).is_inside_tree():
		return _inst
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var n: Node3D = load(SCRIPT_PATH).new()
	n.name = "BuildIntent"
	tree.current_scene.add_child(n)
	_inst = n
	return n


static func set_local(data: Dictionary) -> void:
	var n = inst()
	if n != null:
		n.call("_set_local", data)


static func show_remote(data: Dictionary, who: String) -> void:
	var n = inst()
	if n != null:
		n.call("_show_remote", data, who)


static func ping(pos: Vector3, label: String, who: String, local := true) -> void:
	var n = inst()
	if n != null:
		n.call("_ping", pos, label, who, local)


static func notify_built(who: String, piece_name: String) -> void:
	if Game.hud == null:
		return
	var w := who.strip_edges()
	Game.hud.show_message(("Arkadaşın (%s) %s kurdu" % [w, piece_name]) if w != "" else ("Arkadaşın %s kurdu" % piece_name), 2.6)


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_font_b = UI.font(700)
	_font = UI.font(500)
	_canvas = CanvasLayer.new()
	_canvas.layer = 5
	add_child(_canvas)
	_note = Control.new()
	_note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_note.add_to_group("gameplay_overlay")
	_note.draw.connect(_draw_note)
	_canvas.add_child(_note)
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost_mat.no_depth_test = false
	_ghost_mat.albedo_color = Color(GHOST_COL, 0.13)


# =================================================================================================
# Local intent (forwarded by the network layer)
# =================================================================================================

func _set_local(data: Dictionary) -> void:
	var on := bool(data.get("on", false))
	if not on and not _local_on:
		return
	if on and _local_on and str(data.get("id", "")) == str(_local.get("id", "")) and bool(data.get("ok", false)) == bool(_local.get("ok", false)) \
			and (data.get("xf", Transform3D()) as Transform3D).origin.distance_to((_local.get("xf", Transform3D()) as Transform3D).origin) < 0.15:
		return
	_local = data.duplicate()
	_local_on = on
	_out_dirty = true


func _process(delta: float) -> void:
	# The local intent out, throttled.
	_out_t -= delta
	if _out_dirty and _out_t <= 0.0:
		_out_t = OUT_PERIOD
		_out_dirty = false
		intent_out.emit(_local if _local_on else {"on": false})
	# The partner's ghost.
	_remote_t -= delta
	var show := _remote_t > 0.0 and bool(_remote.get("on", false))
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.visible = show
		if show:
			var xf: Transform3D = _remote.get("xf", Transform3D())
			_ghost.global_transform = xf
			var pulse := 0.1 + 0.05 * sin(Time.get_ticks_msec() * 0.006)
			var col := GHOST_COL if bool(_remote.get("ok", true)) else Color(1.0, 0.55, 0.35)
			_ghost_mat.albedo_color = Color(col, pulse)
			_ghost_label.modulate = Color(col.lightened(0.35), 0.95)
	_note.visible = show
	if show:
		_note.queue_redraw()
	_tick_pings(delta)


# =================================================================================================
# The partner's intent
# =================================================================================================

func _show_remote(data: Dictionary, who: String) -> void:
	_remote = data.duplicate()
	_remote_who = who
	if not bool(data.get("on", false)):
		_remote_t = 0.0
		return
	_remote_t = REMOTE_HOLD
	var kind := str(data.get("id", ""))
	if kind != _ghost_kind or _ghost == null or not is_instance_valid(_ghost):
		_make_ghost(kind)
	if _ghost_label != null:
		_ghost_label.text = "%s\n%s" % [who, str(data.get("name", BaseKit.display_name(kind)))]


func _make_ghost(kind: String) -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost_kind = kind
	_ghost = Node3D.new()
	_ghost.name = "PartnerGhost"
	_ghost.top_level = true
	add_child(_ghost)
	var e := {"id": kind}
	var path := str(BaseKit.PIECES.get(kind, BaseKit.LEGACY.get(kind, "")))
	if kind == "armed_skiff":
		path = "res://scripts/craft/armed_skiff.gd"
	elif kind == "skiff":
		path = "res://scripts/craft/skiff.gd"
	if path != "" and ResourceLoader.exists(path):
		e["script"] = load(path)
	var m := BuildPreview.model(_ghost, e)
	if m == null:
		var bm := BoxMesh.new()
		var h := BaseKit.half_of(kind)
		bm.size = h * 2.0
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.position = Vector3(0, h.y, 0)
		_ghost.add_child(mi)
	BuildPreview.hologram(_ghost, _ghost_mat)
	_ghost_label = Label3D.new()
	_ghost_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_ghost_label.no_depth_test = true
	_ghost_label.fixed_size = true
	_ghost_label.pixel_size = 0.0011
	_ghost_label.font_size = 26
	_ghost_label.outline_size = 8
	_ghost_label.position = Vector3(0, BaseKit.half_of(kind).y * 2.0 + 0.8, 0)
	_ghost.add_child(_ghost_label)


func _draw_note() -> void:
	var vs := _note.size
	var k := UI.scale_k(vs)
	var who := UI.upper_tr(_remote_who if _remote_who != "" else "Arkadaşın")
	var txt := "%s yerleştiriyor" % str(_remote.get("name", "yapı"))
	var fsz := UI.fs(14, k)
	var cf := UI.font_caps(700, 2)
	var ww := UI.text_w(cf, who, UI.fs(11, k))
	var tw := UI.text_w(_font_b, txt, fsz)
	var w := ww + tw + 48.0 * k
	var h := 30.0 * k
	var r := Rect2(Vector2(vs.x * 0.5 - w * 0.5, vs.y * 0.16), Vector2(w, h))
	UI.draw_glass(_note, r, k, UI.SCREEN_CYAN, 0.0, 0.9, false, 8.0)
	_note.draw_circle(Vector2(r.position.x + 14.0 * k, r.get_center().y), 4.0 * k, Color(GHOST_COL, 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.008)))
	UI.draw_text(_note, cf, Vector2(r.position.x + 26.0 * k, r.get_center().y + UI.fs(11, k) * 0.36), who, UI.fs(11, k), GHOST_COL.lightened(0.3), 2)
	UI.draw_text(_note, _font_b, Vector2(r.position.x + 34.0 * k + ww, r.get_center().y + fsz * 0.36), txt, fsz, UI.TEXT, 2)


# =================================================================================================
# Pings
# =================================================================================================

func _ping(pos: Vector3, label: String, who: String, local: bool) -> void:
	# At most BUILD_PING_MAX per player: the oldest of his goes.
	var mine: Array = []
	for p in _pings:
		if str(p["who"]) == who:
			mine.append(p)
	while mine.size() >= Balance.BUILD_PING_MAX:
		var old: Dictionary = mine.pop_front()
		_free_ping(old)
		_pings.erase(old)
	var up := Vector3.UP
	var b: Node3D = Game.dominant_body(pos)
	if b != null and b.has_method("up_at"):
		up = b.up_at(pos)
	var root := Node3D.new()
	root.top_level = true
	add_child(root)
	var ref := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := up.cross(ref).normalized()
	root.global_transform = Transform3D(Basis(x, up, x.cross(up)), pos)
	var beam_mat := _add_mat(PING_COL, 0.35)
	var cm := CylinderMesh.new()
	cm.top_radius = 0.02
	cm.bottom_radius = 0.09
	cm.height = 9.0
	cm.radial_segments = 8
	cm.rings = 1
	var beam := MeshInstance3D.new()
	beam.mesh = cm
	beam.material_override = beam_mat
	beam.position = Vector3(0, 4.5, 0)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(beam)
	var ring_mat := _add_mat(PING_COL, 0.7)
	var tm := TorusMesh.new()
	tm.inner_radius = 0.95
	tm.outer_radius = 1.1
	tm.rings = 32
	tm.ring_segments = 4
	var ring := MeshInstance3D.new()
	ring.mesh = tm
	ring.material_override = ring_mat
	ring.position = Vector3(0, 0.15, 0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	var lbl := Label3D.new()
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = 0.0012
	lbl.font_size = 28
	lbl.outline_size = 9
	lbl.modulate = PING_COL.lightened(0.35)
	lbl.position = Vector3(0, 3.2, 0)
	root.add_child(lbl)
	var text := "BURAYA KUR: %s" % label
	_pings.append({"node": root, "label": lbl, "beam_mat": beam_mat, "ring_mat": ring_mat, "ring": ring,
			"t": Balance.BUILD_PING_TIME, "who": who, "text": text, "pos": pos, "upd": 0.0})
	if Game.sfx:
		Game.sfx.play("blip", -4.0, 1.25)
	if local:
		ping_out.emit(pos, label)
	elif Game.hud:
		Game.hud.show_message("%s: BURAYA KUR — %s" % [who, label], 2.5)


func _add_mat(col: Color, a: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(col, a)
	return m


func _tick_pings(delta: float) -> void:
	if _pings.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	for p in _pings.duplicate():
		p["t"] = float(p["t"]) - delta
		var t := float(p["t"])
		if t <= 0.0:
			_free_ping(p)
			_pings.erase(p)
			continue
		var fade := clampf(t / 3.0, 0.0, 1.0)
		var pulse := 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.007)
		(p["beam_mat"] as StandardMaterial3D).albedo_color.a = 0.35 * fade * pulse
		(p["ring_mat"] as StandardMaterial3D).albedo_color.a = 0.7 * fade
		var ring: Node3D = p["ring"]
		var rs := 1.0 + 0.25 * fmod(Time.get_ticks_msec() * 0.001, 1.2)
		ring.scale = Vector3(rs, 1.0, rs)
		p["upd"] = float(p["upd"]) - delta
		if float(p["upd"]) <= 0.0:
			p["upd"] = 0.25
			var lbl: Label3D = p["label"]
			var d := cam.global_position.distance_to(p["pos"]) if cam != null else 0.0
			lbl.text = "%s\n%s · %d m · %d s" % [str(p["text"]), str(p["who"]), int(d), int(ceilf(t))]
			lbl.modulate.a = fade


func _free_ping(p: Dictionary) -> void:
	var n = p.get("node")
	if n != null and is_instance_valid(n):
		(n as Node).queue_free()
