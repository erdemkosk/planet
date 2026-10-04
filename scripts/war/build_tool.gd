extends "res://scripts/items/item.gd"
## İnşa Aracı (key 4): builds structures on your own planet from material.
## R / mouse wheel cycles the entries: "Top" (scripts/war/cannon.gd), "Uçaksavar"
## (scripts/war/flak.gd) and, once the shuttle exists, "Mekik" (res://scripts/craft/skiff.gd,
## loaded at runtime only: const BUILD_COST, DISPLAY_NAME, static footprint() -> half extents,
## place(body, xf) after add_child).
## A ghost shows the placement on the ground: green when it can be built (on our planet, flat
## enough, clear of other structures and of you, enough material), red otherwise with the reason on
## the HUD. LMB builds: the material is spent, the structure assembles with dust and sound.

const Balance := preload("res://scripts/war/balance.gd")
const Cannon := preload("res://scripts/war/cannon.gd")
const Flak := preload("res://scripts/war/flak.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const SKIFF_PATH := "res://scripts/craft/skiff.gd"
const OK_COL := Color(0.35, 1.0, 0.55)
const BAD_COL := Color(1.0, 0.32, 0.25)

var entries: Array = []           # {"id", "name", "cost", "half": Vector3, "radius"}
var index := 0
var aim_valid := false
var can_build := false
var reason := ""

var _ghost: Node3D
var _ghost_mat: StandardMaterial3D
var _ghost_kind := ""
var _ring: MeshInstance3D
var _xf := Transform3D()
var _check_t := 0.0
var _use_t := 0.0
var _screen: ShaderMaterial
var _t := 0.0


func _init() -> void:
	item_id = "build"
	item_name = "İnşa Aracı"
	item_desc = "Kendi gezegenine top, uçaksavar (ve mekik) kurar. R / teker: seç · Sol tık: kur."
	icon = "build"


func _ready() -> void:
	_refresh_entries()


## The buildable entries (the shuttle once scripts/craft/skiff.gd exists).
func _refresh_entries() -> void:
	entries = [{"id": "cannon", "name": "Top", "cost": Balance.CANNON_COST, "half": Vector3(2.5, 1.7, 2.5),
			"radius": Balance.CANNON_FOOTPRINT},
			{"id": "flak", "name": "Uçaksavar", "cost": Balance.FLAK_COST, "half": Vector3(1.9, 1.4, 1.9),
			"radius": Balance.FLAK_FOOTPRINT}]
	if ResourceLoader.exists(SKIFF_PATH):
		var s = load(SKIFF_PATH)
		if s is Script and (s as Script).can_instantiate():
			var half := Vector3(3.0, 1.5, 4.0)
			for m in (s as Script).get_script_method_list():
				if str(m.get("name", "")) == "footprint":
					half = s.call("footprint")
					break
			var consts: Dictionary = (s as Script).get_script_constant_map()
			var cost := float(consts.get("BUILD_COST", Balance.SHUTTLE_COST_HINT))
			var nm := str(consts.get("DISPLAY_NAME", "Mekik"))
			entries.append({"id": "skiff", "name": nm, "cost": cost, "half": half, "radius": maxf(half.x, half.z),
					"script": s})
	index = clampi(index, 0, entries.size() - 1)


func current_entry() -> Dictionary:
	return entries[index] if index < entries.size() else {}


# =================================================================================================
# Model (view model: a handheld constructor with a screen and an emitter fork)
# =================================================================================================

func build_model() -> Node3D:
	model = Node3D.new()
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	VM.grip(model, orange)
	VM.soft_box(model, Vector3(0, 0.06, -0.06), Vector3(0.11, 0.07, 0.2), 0.015, white)
	VM.box(model, Vector3(0, 0.1, -0.05), Vector3(0.09, 0.008, 0.15), dark)
	_screen = VM.glow(OK_COL, 2.0)
	VM.box(model, Vector3(0, 0.105, -0.05), Vector3(0.075, 0.004, 0.12), _screen)
	for sx in [-1.0, 1.0]:
		VM.seg(model, Vector3(0.04 * sx, 0.06, -0.16), Vector3(0.05 * sx, 0.06, -0.26), 0.008, 0.005, steel, 8)
		VM.sphere(model, Vector3(0.05 * sx, 0.06, -0.265), 0.008, VM.glow(Color(0.4, 0.9, 1.0), 4.0))
	VM.box(model, Vector3(0, 0.03, -0.16), Vector3(0.05, 0.03, 0.04), orange)
	VM.box(model, Vector3(0, 0.0, -0.13), Vector3(0.03, 0.05, 0.03), dark)
	left_grip = VM.node(model, Vector3(0, 0.0, -0.14), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	VM.bake(model, [left_grip])
	return model


func accent_color() -> Color:
	return Color(0.4, 0.9, 1.0)


func crosshair_color() -> Color:
	return OK_COL if can_build else (BAD_COL if aim_valid else Color(0.8, 0.85, 0.9))


func status_text() -> String:
	return str(current_entry().get("name", ""))


## Right-panel lines for the HUD (scripts/ui/hud.gd): [title, detail, detail colour].
func hud_panel_lines() -> Array:
	var e := current_entry()
	var title := "%s  ·  %d m³" % [str(e.get("name", "")), int(e.get("cost", 0.0))]
	var detail := reason if reason != "" else "Sol tık: kur"
	return [title, detail, OK_COL if can_build else BAD_COL]


func hud_hint() -> String:
	var parts := PackedStringArray()
	for i in entries.size():
		var e: Dictionary = entries[i]
		var txt := "%s %d m³" % [e["name"], int(e["cost"])]
		parts.append(("[color=#7fe0ff][b]%s[/b][/color]" % txt) if i == index else ("[color=#6f8090]%s[/color]" % txt))
	return "%s   [color=#8fa3b5]R / teker: seç · Sol tık: kur[/color]" % "  ›  ".join(parts)


func _on_state_changed() -> void:
	if active and equipped:
		_refresh_entries()
	elif _ghost != null:
		_ghost.visible = false
		_ring.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not can_operate():
		return
	if event.is_action_pressed("tool_mode") or event.is_action_pressed("brush_up"):
		_cycle(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("brush_down"):
		_cycle(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tool_use") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_build()
		get_viewport().set_input_as_handled()


func _cycle(step: int) -> void:
	_refresh_entries()
	index = posmod(index + step, entries.size())
	_ghost_kind = ""
	kick = maxf(kick, 0.2)
	_check_t = 0.0
	if Game.sfx:
		Game.sfx.play("click", -10.0, 1.0 + index * 0.1)


# =================================================================================================
# Placement
# =================================================================================================

func _physics_process(delta: float) -> void:
	_check_t -= delta
	if not can_operate():
		aim_valid = false
		can_build = false
		if _ghost != null:
			_ghost.visible = false
			_ring.visible = false
		return
	var cam := get_parent() as Camera3D
	var from: Vector3 = player.aim_origin()
	var dir := -cam.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * Balance.BUILD_RANGE, Game.LAYER_TERRAIN)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		aim_valid = false
		can_build = false
		reason = "Zemine nişan al"
		if _ghost != null:
			_ghost.visible = false
			_ring.visible = false
		return
	aim_valid = true
	var e := current_entry()
	_ensure_ghost(e)
	if _check_t <= 0.0:
		_check_t = 0.1
		_validate(hit["position"], hit["normal"], dir, e)
	var col := OK_COL if can_build else BAD_COL
	_ghost_mat.albedo_color = Color(col.r, col.g, col.b, 0.32 + 0.08 * sin(_t * 6.0))
	(_ring.material_override as StandardMaterial3D).albedo_color = Color(col.r, col.g, col.b, 0.8)
	_ghost.visible = true
	_ring.visible = true
	_ghost.global_transform = _xf
	_ring.global_transform = Transform3D(_xf.basis, _xf.origin + _xf.basis.y * 0.15)
	if _screen != null:
		_screen.set_shader_parameter("color", col)


func _process(delta: float) -> void:
	_t += delta
	_use_t = maxf(_use_t - delta, 0.0)
	using = _use_t > 0.0


## Placement transform and validity for entry `e` at ground point p (normal n), looking along dir.
func _validate(p: Vector3, n: Vector3, dir: Vector3, e: Dictionary) -> void:
	can_build = false
	var body: Node3D = Game.dominant_body(p)
	var up: Vector3 = body.up_at(p) if body != null else n
	var fwd := dir - up * dir.dot(up)
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(Vector3.RIGHT)
	var z := -fwd.normalized()
	var x := up.cross(z).normalized()
	var b := Basis(x, up, x.cross(up))
	var r: float = float(e.get("radius", 3.0))
	# Footprint samples: ground height relative to p along up.
	var lowest := 0.0
	var highest := 0.0
	var flat_ok := true
	if body != null and body.has_method("raycast_density"):
		for i in 8:
			var a := TAU * float(i) / 8.0
			var s := p + (x * cos(a) + z * sin(a)) * r * 0.8
			var h: Dictionary = body.raycast_density(s + up * 4.0, s - up * 6.0, 0.5, true)
			if h.is_empty():
				flat_ok = false
				break
			var off: float = ((h["position"] as Vector3) - p).dot(up)
			lowest = minf(lowest, off)
			highest = maxf(highest, off)
	_xf = Transform3D(b, p + up * lowest)
	if body != Game.planet:
		reason = "Yalnız kendi gezegenine kurabilirsin"
		return
	if n.dot(up) < cos(deg_to_rad(Balance.BUILD_MAX_SLOPE_DEG)):
		reason = "Zemin çok eğimli"
		return
	if not flat_ok or highest - lowest > Balance.BUILD_MAX_STEP:
		reason = "Zemin düz değil"
		return
	for s in get_tree().get_nodes_in_group("war_structure"):
		if not (s is Node3D):
			continue
		var sr := float(s.get_meta("footprint_r", 3.0))
		if (s as Node3D).global_position.distance_to(_xf.origin) < r + sr:
			reason = "Başka bir yapıya çok yakın"
			return
	if player.global_position.distance_to(_xf.origin) < r + 0.6:
		reason = "Çok yakınsın — biraz geri çekil"
		return
	if Game.material + 0.001 < float(e.get("cost", 0.0)):
		reason = "Yetersiz malzeme (%d / %d m³)" % [int(Game.material), int(e.get("cost", 0.0))]
		return
	reason = ""
	can_build = true


func _build() -> void:
	var e := current_entry()
	if e.is_empty():
		return
	if not can_build:
		if Game.sfx:
			Game.sfx.play("error", -10.0)
		if Game.hud and reason != "":
			Game.hud.show_message(reason, 1.8)
		return
	if not Game.spend_material(float(e["cost"])):
		return
	var scene: Node = get_tree().current_scene
	var xf := _xf
	match str(e["id"]):
		"cannon":
			Cannon.spawn(scene, Game.planet, xf, "home", true)
		"flak":
			Flak.spawn(scene, Game.planet, xf, "home", true)
		"skiff":
			var sk: Node3D = (e["script"] as Script).new()
			sk.transform = xf
			scene.add_child(sk)
			sk.add_to_group("war_structure")
			sk.set_meta("footprint_r", float(e["radius"]))
			if sk.has_method("place"):
				sk.place(Game.planet, xf)
			BuildFx.assemble(scene, xf, e["half"])
	_use_t = 0.35
	kick = maxf(kick, 0.4)
	can_build = false
	_check_t = 0.0
	if Game.hud:
		Game.hud.show_message("%s kuruldu (-%d m³)" % [e["name"], int(e["cost"])], 2.0)


## The placement ghost for the current entry (a cannon / Uçaksavar silhouette or the shuttle's box)
## and the footprint ring.
func _ensure_ghost(e: Dictionary) -> void:
	var kind := str(e.get("id", ""))
	if _ghost != null and _ghost_kind == kind:
		return
	if _ghost != null:
		_ghost.queue_free()
		_ring.queue_free()
	_ghost_kind = kind
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost = Node3D.new()
	_ghost.top_level = true
	add_child(_ghost)
	if kind == "cannon":
		_gpart(CylinderMesh.new(), Vector3(0, 0.15, 0), Vector3(2.4, 0.7, 2.4))
		_gpart(CylinderMesh.new(), Vector3(0, 0.66, 0), Vector3(1.5, 0.32, 1.5))
		_gpart(BoxMesh.new(), Vector3(0, 1.4, 0.1), Vector3(1.4, 1.3, 1.9))
		var bar := _gpart(CylinderMesh.new(), Vector3(0, 2.6, -2.2), Vector3(0.2, 5.6, 0.2))
		bar.rotation = Vector3(-PI * 0.5 + 0.7, 0, 0)
	elif kind == "flak":
		_gpart(CylinderMesh.new(), Vector3(0, 0.32, 0), Vector3(1.45, 0.5, 1.45))
		_gpart(BoxMesh.new(), Vector3(0, 1.2, 0.25), Vector3(1.5, 0.7, 1.5))
		for sx in [-0.24, 0.24]:
			var gun := _gpart(CylinderMesh.new(), Vector3(sx, 2.3, -1.4), Vector3(0.07, 3.2, 0.07))
			gun.rotation = Vector3(-PI * 0.5 + 0.75, 0, 0)
		_gpart(CylinderMesh.new(), Vector3(0, 2.55, 0.85), Vector3(0.5, 0.15, 0.5))
	else:
		var half: Vector3 = e.get("half", Vector3(3, 1.5, 4))
		_gpart(BoxMesh.new(), Vector3(0, half.y, 0), half * 2.0)
	var tm := TorusMesh.new()
	var r: float = float(e.get("radius", 3.0))
	tm.inner_radius = r - 0.12
	tm.outer_radius = r
	tm.rings = 48
	tm.ring_segments = 4
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring = MeshInstance3D.new()
	_ring.mesh = tm
	_ring.material_override = rm
	_ring.top_level = true
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)


## A ghost part: boxes get `size`, cylinders radius size.x and height size.y.
func _gpart(m: PrimitiveMesh, pos: Vector3, size: Vector3) -> MeshInstance3D:
	if m is CylinderMesh:
		(m as CylinderMesh).top_radius = size.x
		(m as CylinderMesh).bottom_radius = size.x
		(m as CylinderMesh).height = size.y
		(m as CylinderMesh).radial_segments = 24
	elif m is BoxMesh:
		(m as BoxMesh).size = size
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _ghost_mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.add_child(mi)
	return mi
