extends Node3D
## Shared base of the base-building pieces (scripts/war/base_kit.gd lists them: Sığınak Modülü,
## Takviyeli Duvar, Zırhlı Kapı, Otomatik Taret, Çekirdek Kalkanı, Radar Kulesi, Işık Direği).
## The structure contract of the cannon / armory / auto-miner:
##   team ("home" / "rival"), body (its planet), hp, hp_max, is_destroyed, owner_peer (multiplayer: the
##   client who asked for it, 0 = here), begin_assembly() (the parts drop into place, BuildFx dust and
##   hologram), _destroy() (an explosion, out of every group, freed), take_damage(amount, from, impulse)
##   -> {"dmg", "killed"}, hud_name(), is_dead(); the multiplayer structure state fields _yaw_t /
##   _pitch_t / tracking / charge (scripts/net/net_world.gd sends them host -> client, 10 B).
## Groups "damageable", "war_structure", "war_base" + the piece's own (piece_group()).
## Blasts (damage without a hit point: Game.hit_pos == INF, i.e. Explosion / area damage) are cut to
## blast_mult(); the soil over an underground piece shelters it before that (Explosion ->
## BaseKit.blast_shelter). A Foundation (skirt / piles) fills any gap down to the real ground; dug away
## from under it, the piece settles onto what is left (Foundation.support_drop).
## Look: NMS-style realism: cast concrete with a fine grain (triplanar noise albedo + normal map),
## painted steel, team stripes (home white / orange, rival gunmetal / red), hazard bands, small lamps.
## Subclasses override the virtuals below (never the static footprint(): each declares its own).
## On a multiplayer client the piece only shows what the host sends (_tick_client); _tick runs on the
## host / in single player.

const Balance := preload("res://scripts/war/balance.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const Explosion := preload("res://scripts/items/explosion.gd")
const Foundation := preload("res://scripts/war/foundation.gd")
const BaseKit := preload("res://scripts/war/base_kit.gd")

const HOME_COL := Color(0.35, 0.88, 1.0)
const RIVAL_COL := Color(1.0, 0.28, 0.14)

signal destroyed(piece: Node3D)

var team := "home"
var body: Node3D
var hp := 100.0
var hp_max := 100.0
var is_destroyed := false
var owner_peer := 0
var underground := false               # soil over it (recomputed after nearby digs)
# Multiplayer structure state (net_world.gd): what each piece puts in them is in its header.
var _yaw_t := 0.0
var _pitch_t := 0.0
var tracking := false
var charge := 0.0

var _hit_t := 0.0
var _t := 0.0
var _build_t := -1.0
var _parts: Array = []                 # [node, rest transform, delay]
var _col_team := HOME_COL
var _paint: StandardMaterial3D         # the team paint (flashes on hits)
var _foundation: Node3D
var _ground_check := false
var _sb: StaticBody3D

static var _concrete: StandardMaterial3D
static var _concrete_dark: StandardMaterial3D
static var _hazard_tex: Texture2D


# =================================================================================================
# Virtuals
# =================================================================================================

func piece_kind() -> String:
	return ""


func piece_name() -> String:
	return "Yapı"


func piece_group() -> String:
	return "war_base_misc"


func piece_hp() -> float:
	return 100.0


func footprint_r() -> float:
	return 1.5


## Damage × this from blasts (Explosion / area damage); bullets in full.
func blast_mult() -> float:
	return 1.0


## Builds the model (parts via _part) and the collision (_col_box).
func _build_piece() -> void:
	pass


## [ring, piles, color] for Foundation.create (host-local), or [] for none.
func _foundation_shape() -> Array:
	return []


## After the model and the foundation (not for previews: check has_meta("build_preview") yourself).
func _piece_ready() -> void:
	pass


## Host / single player, every frame once assembled.
func _tick(_delta: float) -> void:
	pass


## Multiplayer client copy, every frame once assembled (the host's state is in the net fields).
func _tick_client(_delta: float) -> void:
	pass


## Every frame (also while assembling): looks and sounds.
func _animate(_delta: float) -> void:
	pass


func _on_assembled() -> void:
	pass


func _on_destroyed() -> void:
	pass


## Where blasts are measured to (world): the middle of the piece.
func shelter_point() -> Vector3:
	return global_position + global_transform.basis.y.normalized() * BaseKit.half_of(piece_kind()).y


# =================================================================================================
# Life
# =================================================================================================

func _ready() -> void:
	_col_team = HOME_COL if team == "home" else RIVAL_COL
	hp_max = piece_hp()
	hp = hp_max
	add_to_group(Game.DAMAGEABLE)
	add_to_group("war_structure")
	add_to_group("war_base")
	add_to_group(piece_group())
	set_meta("footprint_r", footprint_r())
	var preview := has_meta("build_preview")
	_sb = StaticBody3D.new()
	_sb.collision_layer = Game.LAYER_SHIP
	_sb.collision_mask = 0
	add_child(_sb)
	_build_piece()
	if not preview and body != null and is_instance_valid(body):
		var fs := _foundation_shape()
		if fs.size() >= 3:
			_foundation = Foundation.create(self, body, fs[0], fs[1], fs[2])
			_parts.append([_foundation, _foundation.transform, 0.0])
		underground = not is_inf(BaseKit.cover_above(body, global_position, global_transform.basis.y.normalized()))
		if body.has_signal("brush_applied"):
			body.brush_applied.connect(_on_brush)
	_piece_ready()


## The parts drop into place over ~1.5 s (built with the tool / by the network / by the AI).
func begin_assembly() -> void:
	# (BuildFx first: it reads the parts' meshes for the print before they are hidden / moved.)
	BuildFx.assemble(get_parent(), global_transform, BaseKit.half_of(piece_kind()), BuildFx.AUTO, self)
	_build_t = 0.0
	for p in _parts:
		(p[0] as Node3D).visible = false


func is_assembled() -> bool:
	return _build_t < 0.0


func _process(delta: float) -> void:
	_t += delta
	if _build_t >= 0.0:
		_tick_assembly(delta)
	elif not is_destroyed and not has_meta("build_preview"):
		if Net.is_client():
			_tick_client(delta)
		else:
			_tick(delta)
	_animate(delta)
	if _hit_t > 0.0 or (_paint != null and _paint.emission_enabled):
		_hit_t = maxf(_hit_t - delta * 3.0, 0.0)
		if _paint != null:
			_paint.emission_enabled = _hit_t > 0.0
			_paint.emission = Color(1.0, 0.35, 0.1) * _hit_t


func _tick_assembly(delta: float) -> void:
	_build_t += delta
	var done := true
	for p in _parts:
		var n: Node3D = p[0]
		var k := clampf((_build_t - float(p[2])) / 0.55, 0.0, 1.0)
		n.visible = k > 0.0
		var e := 1.0 - pow(1.0 - k, 3.0)
		n.transform = (p[1] as Transform3D).translated_local(Vector3(0, 1.8 * (1.0 - e), 0)).scaled_local(Vector3.ONE * lerpf(0.7, 1.0, e))
		if k < 1.0:
			done = false
	if done:
		_build_t = -1.0
		for p in _parts:
			(p[0] as Node3D).transform = p[1]
		if Game.sfx:
			Game.sfx.play_at("impact", global_position, -5.0, 0.8, 14.0)
		_on_assembled()


func hud_name() -> String:
	var mine := Game.team_of(self) == Game.team_of(Game.player)
	return piece_name() if mine else "Düşman " + piece_name()


func take_damage(amount: float, _from_pos := Vector3.ZERO, _impulse := Vector3.ZERO) -> Dictionary:
	if is_destroyed or amount <= 0.0:
		return {"dmg": 0.0, "killed": false}
	if Game.hit_pos == Vector3.INF:
		amount *= blast_mult()
	hp = maxf(hp - amount, 0.0)
	_hit_t = 1.0
	if hp <= 0.0:
		_destroy()
		return {"dmg": amount, "killed": true}
	return {"dmg": amount, "killed": false}


func is_dead() -> bool:
	return is_destroyed


func _destroy() -> void:
	if is_destroyed:
		return
	is_destroyed = true
	if Game.hud and not has_meta("build_preview"):
		if Game.team_of(self) == Game.team_of(Game.player):
			Game.hud.show_message("%s yok edildi!" % piece_name(), 2.2)
		else:
			Game.hud.show_message("Düşman %s yok edildi!" % piece_name().to_lower(), 2.2)
	destroyed.emit(self)
	_on_destroyed()
	var up := global_transform.basis.y.normalized()
	var h := BaseKit.half_of(piece_kind())
	Explosion.spawn(global_position + up * h.y, up, {"radius": clampf(maxf(h.x, h.z) * 1.4, 2.0, 4.5),
			"damage": 20.0, "impulse": 6.0, "crater": 0.0, "player_owned": false})
	remove_from_group("war_structure")
	remove_from_group("war_base")
	remove_from_group(piece_group())
	remove_from_group(Game.DAMAGEABLE)
	queue_free()


# =================================================================================================
# Ground
# =================================================================================================

## Ground dug near it: settle onto what is left, refit the foundation, re-check the cover.
func _on_brush(center: Vector3, r: float) -> void:
	if is_destroyed or _ground_check:
		return
	if center.distance_to(global_position) < r + footprint_r() * 1.5 + 3.0:
		_ground_check = true
		_settle.call_deferred()


func _settle() -> void:
	await get_tree().create_timer(1.2).timeout
	_ground_check = false
	if is_destroyed or body == null or not is_instance_valid(body) or not is_inside_tree():
		return
	var up: Vector3 = global_transform.basis.y.normalized()
	underground = not is_inf(BaseKit.cover_above(body, global_position, up))
	var h := BaseKit.half_of(piece_kind())
	var pts := PackedVector3Array()
	for i in 9:
		pts.append(Vector3(float(i % 3 - 1) * h.x * 0.85, 0.0, float(floori(i / 3.0) - 1) * h.z * 0.85))
	var drop := Foundation.support_drop(self, body, pts)
	if drop < 0.35:
		if _foundation != null and is_instance_valid(_foundation):
			_foundation.refit()
		return
	var tw := create_tween()
	tw.tween_property(self, "global_position", global_position - up * drop, clampf(sqrt(drop) * 0.3, 0.2, 1.2)) \
			.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(_refit_foundation)
	if Game.sfx:
		Game.sfx.play_at("impact", global_position, -6.0, 0.7, 12.0)


func _refit_foundation() -> void:
	if _foundation != null and is_instance_valid(_foundation):
		_foundation.refit()


# =================================================================================================
# Model helpers
# =================================================================================================

func _mat(c: Color, metal: float, rough: float, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	return m


## Cast concrete with a fine grain and pores (shared; triplanar in world space, so every slab lines up).
static func concrete(dark := false) -> StandardMaterial3D:
	if dark and _concrete_dark != null:
		return _concrete_dark
	if not dark and _concrete != null:
		return _concrete
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.035
	n.fractal_octaves = 5
	n.fractal_gain = 0.55
	var alb := NoiseTexture2D.new()
	alb.width = 256
	alb.height = 256
	alb.seamless = true
	alb.noise = n
	var g := Gradient.new()
	g.set_color(0, Color(0.62, 0.61, 0.58) if not dark else Color(0.36, 0.355, 0.35))
	g.set_color(1, Color(0.78, 0.77, 0.74) if not dark else Color(0.47, 0.46, 0.45))
	alb.color_ramp = g
	var nrm := NoiseTexture2D.new()
	nrm.width = 256
	nrm.height = 256
	nrm.seamless = true
	nrm.as_normal_map = true
	nrm.bump_strength = 3.0
	var n2 := FastNoiseLite.new()
	n2.noise_type = FastNoiseLite.TYPE_CELLULAR
	n2.frequency = 0.09
	nrm.noise = n2
	var m := StandardMaterial3D.new()
	m.albedo_texture = alb
	m.normal_enabled = true
	m.normal_texture = nrm
	m.normal_scale = 0.35
	m.roughness = 0.93
	m.metallic = 0.0
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(0.45, 0.45, 0.45)
	if dark:
		_concrete_dark = m
	else:
		_concrete = m
	return m


## Yellow / black hazard stripes (diagonal), for edges and door leaves.
static func hazard() -> StandardMaterial3D:
	if _hazard_tex == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		for y in 64:
			for x in 64:
				var band := int(floorf(float(x + y) / 16.0)) % 2 == 0
				img.set_pixel(x, y, Color(0.92, 0.7, 0.1) if band else Color(0.05, 0.05, 0.055))
		img.generate_mipmaps()
		_hazard_tex = ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.albedo_texture = _hazard_tex
	m.roughness = 0.6
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(1.6, 1.6, 1.6)
	return m


func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, pos: Vector3, r_top: float, r_bot: float, h: float, mat: Material, rot := Vector3.ZERO, seg := 16) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


static func _seg_basis(a: Vector3, b: Vector3) -> Basis:
	var y := (b - a).normalized()
	var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


func _seg(parent: Node3D, a: Vector3, b: Vector3, r: float, mat: Material, seg := 10) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = maxf(a.distance_to(b), 0.01)
	c.radial_segments = seg
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.transform = Transform3D(_seg_basis(a, b), (a + b) * 0.5)
	parent.add_child(mi)
	return mi


## A part of the assembly animation (drops into place after `delay` s).
func _part(delay: float, pos := Vector3.ZERO) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	add_child(n)
	_parts.append([n, n.transform, delay])
	return n


## A box collider on the ship layer (players and skiffs collide; bullets and blasts find the piece).
func _col_box(pos: Vector3, size: Vector3, rot := Vector3.ZERO) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	cs.rotation = rot
	_sb.add_child(cs)
	return cs


## A small glowing lamp (emissive lens; the light itself is the caller's).
func _lamp(parent: Node3D, pos: Vector3, col: Color, r := 0.05, glow := 3.0) -> StandardMaterial3D:
	var m := _mat(col, 0.0, 0.3, glow)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 10
	sm.rings = 5
	mi.mesh = sm
	mi.material_override = m
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return m


## A floating Label3D on a small panel (stencil / status text).
func _label(parent: Node3D, pos: Vector3, text: String, size := 40, col := Color(0.9, 0.95, 1.0), rot := Vector3.ZERO) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.0022
	l.modulate = col
	l.outline_size = 0
	l.shaded = false
	l.position = pos
	l.rotation = rot
	parent.add_child(l)
	return l


## Friends of this piece's side near world point p (players, the co-op partner, bots; not dead).
func _friends_near(p: Vector3, r: float) -> bool:
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and Game.team_of(pl) == team and not (pl.has_method("is_dead") and pl.is_dead()) \
			and (pl as Node3D).global_position.distance_to(p) < r:
		return true
	for grp in ["net_player", "war_ai"]:
		for n in get_tree().get_nodes_in_group(grp):
			if not (n is Node3D) or Game.team_of(n) != team:
				continue
			if n.has_method("is_dead") and n.is_dead():
				continue
			if (n as Node3D).global_position.distance_to(p) < r:
				return true
	return false
