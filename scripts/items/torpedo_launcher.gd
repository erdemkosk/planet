extends "res://scripts/items/weapon_base.gd"
## OUT OF THE LOADOUT (2026-10-05): the player no longer fires the torpedo; it is built as a Sondaj
## Kulesi on the enemy planet (scripts/war/torpedo_rig.gd). Not in player.gd's items nor in the
## armory's recipes; kept for scripts/net/remote_avatar.gd (held-item model by id "torpedo").
## Sondaj Torpidosu (was key 8): a heavy shoulder launcher for the drilling torpedo
## (scripts/war/torpedo.gd). White composite tube with orange bands, a dark front shroud with the
## loaded torpedo's fluted drill nose sticking out of it, a flared rear venturi, a holographic sight
## on the left, a vertical foregrip, and a little power display on top of the tube.
##   - Single shot. Every torpedo costs Balance.TORPEDO_COST material, paid when it is FIRED
##     (Game.spend_material; short: an error, a message, nothing fires). Loading is free.
##   - Mouse wheel ("brush_up" / "brush_down"): launch power between TORPEDO_SPEED_MIN and _MAX
##     (like the cannon's charge), shown on the tube's segment display and under the crosshair.
##   - RMB: raises the sight and shows the flight: Ballistics.trace from the launch point with the
##     launch velocity (the player's own velocity included), a thin dashed arc in the team colour,
##     the impact ring, the HUD range-finder mark (aim_preview()) and a readout: power, flight time,
##     distance and the target ("HEDEF: Rakip gezegen" / "Kendi gezegenin — torpido kazmaz" / "Iska").
##   - LMB: fires (excluding the player's own body, with the player's velocity): recoil, launch
##     roar, a big backblast of fire, smoke and dust behind the shoulder; Game.shot_fired via the base.
##   - Reload (Balance.TORPEDO_RELOAD, by itself after the shot, or R): the muzzle tips up into view,
##     the left hand unclips a new torpedo from the back, brings it to the muzzle, slides it in tail
##     first and twists the lock collar; the display flashes ready.
##   - HUD panel (scripts/ui/hud.gd): mag = a loaded torpedo the material can pay for, reserve = how
##     many more it buys, "yedek bitince: 250 m³/mermi" = the price of every torpedo.
## Multiplayer: signal torpedo_launched(pos, vel, team) on every shot (the torpedo itself also emits
## Torpedo.events().launched, which covers the AI's launches too).

signal torpedo_launched(pos: Vector3, vel: Vector3, team: String)

const Balance := preload("res://scripts/war/balance.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Torpedo := preload("res://scripts/war/torpedo.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const UI := preload("res://scripts/ui/ui_style.gd")

const TUBE_Y := 0.1                  # tube axis height above the grip (gun frame)
const TUBE_R := 0.062
const TUBE_FRONT := -0.56
const TUBE_BACK := 0.4
const SIGHT_X := -0.088              # holographic sight on the left of the tube
const SIGHT_Y := 0.142
const NOSE_R := 0.05                 # the torpedo's drill in the view model
const NOSE_LEN := 0.11
const HT_DRILL := 0.2                # hand torpedo: drill base this far ahead of its centre...
const HT_TAIL := 0.31                # ...tail this far behind
const HT_GRIP := 0.15                # where the hand holds it (ahead of the centre)
const POWER_STEP := 0.04
const AUTO_RELOAD := 0.75            # s after the shot before the reload starts by itself
const SEGMENTS := 8
const TEAM_COL := Color(0.45, 0.9, 1.0)
const HAND_OFF := Vector3(-0.03, -0.072, 0.065)   # wrist target from the point the fist holds (camera space)
const POUCH := Vector3(-0.27, -0.42, -0.2)        # the rack on the back / hip (camera space)

var launch_power := 0.55             # 0..1 between TORPEDO_SPEED_MIN and _MAX

var _nose: Node3D
var _nose_drill: Node3D
var _hand_torp: Node3D
var _segs: Array = []
var _led: ShaderMaterial
var _vt := 0.0
var _after_shot := 9.0
var _power_flash := 0.0
var _ready_flash := 0.0
var _twist := 0.0
var _pv := {}                        # Ballistics.trace result
var _pv_t := 0.0
var _aiming := false
var _arc_node: MeshInstance3D
var _arc_im: ImmediateMesh
var _ring_node: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _ov_layer: CanvasLayer
var _ov: Control
var _f: Font
var _fb: Font


func _init() -> void:
	item_id = "torpedo"
	item_name = "Sondaj Torpidosu"
	item_desc = "Çekirdeğe kazan torpido (%d m³). Teker: güç · Sağ tık: yörünge · Sol tık: ateş · R: doldur." % int(Balance.TORPEDO_COST)
	icon = "torpedo"
	slot_key = 8
	accent = Color(1.0, 0.8, 0.25)
	ammo_title = "SONDAJ TORPİDOSU"
	short_name = "Torpido"
	base_mag = 1
	reload_kind = "mag"
	reload_time = Balance.TORPEDO_RELOAD
	reload_empty_time = Balance.TORPEDO_RELOAD
	fire_rate = 0.5
	auto_fire = false
	can_ads = true
	ads_fov = 58.0
	aim_speed = 0.5
	ads_k = 85.0
	ads_c = 12.5
	sight_rear = Vector3(SIGHT_X, SIGHT_Y, 0.0)
	ads_eye = Vector3(0.0, 0.0, -0.3)
	hip_pos = Vector3(0.2, -0.205, -0.36)
	hip_bore_y = TUBE_Y
	hip_converge = 16.0
	hip_cant = 0.03
	sprint_pos = Vector3(0.17, -0.2, -0.36)
	sprint_rot = Vector3(-0.35, 0.55, 0.25)
	reload_pos = Vector3(0.12, -0.24, -0.44)
	reload_rot = Vector3(0.42, 0.42, 0.18)
	recoil_pivot = Vector3(0.0, 0.08, 0.15)
	spread_hip = 0.0
	spread_ads = 0.0
	bloom_add = 0.0
	bloom_max = 0.0
	kick_pitch = 0.11
	kick_yaw = 0.02
	kick_roll = 0.035
	recoil_climb = 0.0
	recoil_h = PackedFloat32Array([0.4, -0.3])
	recoil_hold = 0.12
	recoil_recover = 0.55
	gun_kick = 12.0
	shake_amt = 0.85
	fov_punch_amt = -7.0
	noise_radius = 90.0
	sprint_to_fire = 0.45
	muzzle_energy = 10.0
	punch_db = -1.0
	head_mult = 0.0
	first_shot_k = 1.0
	crosshair_style = "ticks"
	draw_time = 0.95
	holster_time = 0.6


func _ready() -> void:
	super._ready()
	_snd["rpg"] = Snd.set_of("weap/rpg")
	_f = UI.font(500)
	_fb = UI.font(700)
	_make_arc_nodes()
	_ov_layer = CanvasLayer.new()
	_ov_layer.add_to_group("gameplay_overlay")    # hidden on the end screen / menus (overlay_guard.gd)
	_ov_layer.layer = 11
	add_child(_ov_layer)
	_ov = Control.new()
	_ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ov.draw.connect(_draw_ov)
	_ov_layer.add_child(_ov)


# =================================================================================================
# Ammo / HUD queries (the torpedo is paid when fired: the panel counts what the material buys)
# =================================================================================================

func speed() -> float:
	return lerpf(Balance.TORPEDO_SPEED_MIN, Balance.TORPEDO_SPEED_MAX, launch_power)


func _affordable() -> bool:
	return Game.material + 0.001 >= Balance.TORPEDO_COST


## Loaded torpedoes that can be fired now (the HUD's big number).
func mag_count() -> int:
	return mag if _affordable() else 0


## More torpedoes the material pays for after the loaded one.
func reserve_stock() -> int:
	return maxi(int(floorf((Game.material + 0.001) / Balance.TORPEDO_COST)) - mag_count(), 0)


## Loading is free (the torpedo is paid when it fires): a reload never runs out.
func reserve_count() -> int:
	return 1


func round_cost() -> float:
	return Balance.TORPEDO_COST


func status_text() -> String:
	return "%d/%d" % [mag_count(), reserve_stock()]


func mode_text() -> String:
	return "%d m/s" % int(round(speed()))


func reload_label() -> String:
	return "TORPİDO YÜKLENİYOR"


func save_state() -> Dictionary:
	return {"mag": mag, "power": launch_power}


func load_state(d: Dictionary) -> void:
	super.load_state(d)
	launch_power = clampf(float(d.get("power", launch_power)), 0.0, 1.0)


## The HUD range finder (scripts/items/weapon_hud.gd) marks this point while aiming.
func aim_preview() -> Vector3:
	if _aiming and _pv.has("position"):
		return _pv["position"]
	return Vector3.INF


# =================================================================================================
# Input, firing
# =================================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not debug_ignore_input and can_operate():
		if event.is_action_pressed("brush_up"):
			_set_power(launch_power + POWER_STEP)
			get_viewport().set_input_as_handled()
			return
		elif event.is_action_pressed("brush_down"):
			_set_power(launch_power - POWER_STEP)
			get_viewport().set_input_as_handled()
			return
	super._unhandled_input(event)


func _set_power(p: float) -> void:
	var np := clampf(p, 0.0, 1.0)
	if is_equal_approx(np, launch_power):
		if Game.sfx:
			Game.sfx.play("click", -18.0, 0.7)
		return
	launch_power = np
	_power_flash = 1.0
	_pv_t = 0.0
	if Game.sfx:
		Game.sfx.play("click", -14.0, 0.8 + launch_power * 0.5)


## Pays for the torpedo, then the base shot (recoil, flash, sound, Game.shot_fired, _fire_shot).
func fire() -> void:
	if not _affordable():
		_cooldown = 0.6
		hud.empty_flash()
		_play("dry", -6.0, 0.8)
		if Game.sfx:
			Game.sfx.play("error", -10.0)
		if Game.hud:
			Game.hud.show_message("Yetersiz malzeme — torpido %d m³ (%d var)" % [int(Balance.TORPEDO_COST), int(Game.material)], 2.0)
		return
	if not Game.spend_material(Balance.TORPEDO_COST):
		return
	super.fire()
	_after_shot = 0.0


## Where the torpedo leaves: the muzzle as seen on screen, or the eye when the tube is in a wall.
func _launch_point() -> Vector3:
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var m := muzzle_world() + fwd * 0.12
	var q := PhysicsRayQueryParameters3D.create(eye, m, Game.LAYER_TERRAIN | Game.LAYER_SHIP)
	if player is CollisionObject3D:
		q.exclude = [(player as CollisionObject3D).get_rid()]
	if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return eye + fwd * 0.25
	return m


func _launch_velocity(fwd: Vector3) -> Vector3:
	return fwd * speed() + player.velocity


func _fire_shot(_eye: Vector3, fwd: Vector3, _cb: Basis, _muzzle_p: Vector3) -> void:
	var from := _launch_point()
	var v := _launch_velocity(fwd)
	var ex: Array = []
	if player is CollisionObject3D:
		ex.append((player as CollisionObject3D).get_rid())
	Torpedo.fire(get_tree().current_scene, from, v, "home", ex)
	torpedo_launched.emit(from, v, "home")


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(1.8)
	fx.muzzle_light(muzzle + fwd * 0.6, Color(1.0, 0.7, 0.35), muzzle_energy, 0.08, 14.0)
	fx.muzzle_smoke(muzzle + fwd * 0.2, fwd, up)
	fx.muzzle_smoke(muzzle + fwd * 0.6, fwd, up)
	_backblast(fwd, up, cb)
	if player.has_method("add_trauma"):
		player.add_trauma(0.3)


## Fire, smoke and dust blown out of the rear venturi over the right shoulder.
func _backblast(fwd: Vector3, up: Vector3, cb: Basis) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var eye: Vector3 = player.camera.global_position
	var rear := eye - fwd * 0.55 + cb.x * 0.22 - cb.y * 0.04
	# Hot core of the blast, then a thick cone of smoke.
	scene.add_child(_blast_particles(rear, -fwd, 26, 0.5, 0.9, 10.0, 26.0, true))
	scene.add_child(_blast_particles(rear - fwd * 0.4, -fwd, 34, 3.0, 1.6, 5.0, 18.0, false))
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.65, 0.3)
	l.omni_range = 9.0
	l.light_energy = 9.0
	l.shadow_enabled = false
	scene.add_child(l)
	l.global_position = rear - fwd * 0.8
	var tw := l.create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.16)
	tw.tween_callback(l.queue_free)
	# Dust kicked off the ground behind.
	var q := PhysicsRayQueryParameters3D.create(rear, rear - fwd * 4.0 - up * 2.5, Game.LAYER_TERRAIN)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		var hp: Vector3 = hit["position"]
		var b = Game.dominant_body(hp)
		var col: Color = b.get("soil_color") if b != null and b.get("soil_color") is Color else Color(0.5, 0.42, 0.32)
		BuildFx.dust(scene, hp, up, 1.6, col)


func _blast_particles(pos: Vector3, dir: Vector3, n: int, life: float, size: float, v_min: float, v_max: float,
		hot: bool) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = n
	p.lifetime = life
	p.local_coords = false
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = Torpedo.DigFx.soft_texture()
	if hot:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	q.material = m
	p.mesh = q
	p.direction = dir
	p.spread = 22.0 if hot else 28.0
	p.initial_velocity_min = v_min
	p.initial_velocity_max = v_max
	p.damping_min = 4.0 if hot else 3.0
	p.damping_max = 7.0 if hot else 6.0
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.6 if hot else 2.8
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.4))
	sc.add_point(Vector2(1, 1.8))
	p.scale_amount_curve = sc
	var g := Gradient.new()
	if hot:
		g.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
		g.colors = PackedColorArray([Color(2.6, 1.9, 1.1, 1.0), Color(1.6, 0.6, 0.18, 0.8), Color(0.3, 0.1, 0.05, 0.0)])
	else:
		g.offsets = PackedFloat32Array([0.0, 0.08, 1.0])
		g.colors = PackedColorArray([Color(1.0, 0.72, 0.42, 0.85), Color(0.62, 0.6, 0.57, 0.6), Color(0.55, 0.55, 0.55, 0.0)])
	p.color_ramp = g
	p.visibility_aabb = AABB(Vector3.ONE * -30.0, Vector3.ONE * 60.0)
	p.position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)
	return p


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		_play("boom_body", -3.0, 0.7, true)
		_play("thump", -4.0, 0.6, true)
		_shot_body(space, 0.7, -80.0)
		return
	_play("launch", -1.0, randf_range(0.82, 0.9), true)
	_play("rpg", -3.0, randf_range(0.9, 1.0), true, 1.4)
	_play("boom_body", -5.0, 0.72, true)
	_play("thump", -6.0, 0.62, true)
	_shot_body(space, 0.7, -10.0)
	if space == 2:
		_play("tail", -9.0, randf_range(0.7, 0.8), true)
	elif space == 1:
		_play("tail", -15.0, 0.95, true, 0.4)
	_play("hiss", -12.0, 0.8)


# =================================================================================================
# Reload (free; the next torpedo is paid when it fires)
# =================================================================================================

func _finish_mag_reload() -> void:
	reloading = false
	left_reach_w = 0.0
	mag = mag_capacity()
	_on_reload_done()


func _on_reload_done() -> void:
	mag = mag_capacity()
	_ready_flash = 1.0


func _reload_events(u: float) -> void:
	var marks := [0.04, 0.14, 0.2, 0.42, 0.55, 0.69, 0.72, 0.79, 0.84, 0.88, 0.95]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -14.0, 0.9)
			1:
				_play("belt", -10.0, 0.9)                 # unclipped from the back rack
			2:
				_play("tink", -12.0, 0.8)
			3:
				_play("cloth", -15.0, 1.1)
			4:
				_play("action", -10.0, 0.75)              # the tail goes into the bore
			5:
				_play("shell_in", -5.0, 0.7)              # seated
			6:
				_play("mag_slap", -4.0, 0.75)
				_rk_vel += Vector4(0.6, 0.0, 0.1, 0.25)
			7:
				_play("bolt_back", -6.0, 0.8)             # the lock collar turns...
			8:
				_play("bolt_fwd", -4.0, 0.8)              # ...and locks
				_rk_vel += Vector4(0.3, 0.15, 0.0, 0.05)
			9:
				_play("beep", -10.0, 1.2)
				_ready_flash = 1.0
			10:
				_play("cloth", -16.0, 1.0)
		_reload_ev += 1


# =================================================================================================
# Per frame: auto reload, display, trajectory preview, overlay
# =================================================================================================

func _tick(delta: float, on: bool) -> void:
	_vt += delta
	_after_shot += delta
	_power_flash = maxf(_power_flash - delta * 3.0, 0.0)
	_ready_flash = maxf(_ready_flash - delta * 1.5, 0.0)
	if on and mag <= 0 and not reloading and _after_shot > AUTO_RELOAD and can_operate():
		reload()
	_update_display()
	_aiming = on and can_operate() and not debug_ignore_input and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and Input.is_action_pressed("tool_alt")
	if _aiming:
		_pv_t -= delta
		if _pv_t <= 0.0:
			_pv_t = 0.12
			_update_preview()
	else:
		_pv = {}
		_pv_t = 0.0
	if _arc_node != null:
		_arc_node.visible = _aiming and _pv.has("points")
		_ring_node.visible = _aiming and _pv.has("position")
		if _ring_node.visible:
			var t := 0.5 + 0.5 * sin(_vt * 6.0)
			var c := _kind_color(_target_kind())
			_ring_mat.albedo_color = Color(c.r, c.g, c.b, 0.55 + 0.3 * t)
	if _ov != null:
		_ov.visible = hud_visible()
		if _ov.visible:
			_ov.queue_redraw()


func _on_state_changed() -> void:
	super._on_state_changed()
	if not active or not equipped:
		_aiming = false
		_pv = {}
		if _arc_node != null:
			_arc_node.visible = false
			_ring_node.visible = false


func _update_preview() -> void:
	if player == null:
		return
	var cam: Camera3D = player.camera
	var fwd := -cam.global_transform.basis.z
	_pv = Ballistics.trace(_launch_point(), _launch_velocity(fwd), Balance.TORPEDO_LIFE, 0.08)
	_draw_arc()


## "rival" (an enemy core to drill for), "self" (our own planet: no drilling), "miss".
func _target_kind() -> String:
	if not _pv.has("position"):
		return "miss"
	var b = _pv.get("body")
	if b == null:
		return "miss"
	for c in get_tree().get_nodes_in_group("war_core"):
		if c.get("body") == b and str(c.get("team")) != "home" and not bool(c.get("destroyed")):
			return "rival"
	return "self"


func _kind_color(kind: String) -> Color:
	match kind:
		"rival":
			return TEAM_COL
		"self":
			return Color(1.0, 0.7, 0.3)
	return Color(1.0, 0.38, 0.32)


func _make_arc_nodes() -> void:
	_arc_im = ImmediateMesh.new()
	_arc_node = MeshInstance3D.new()
	_arc_node.mesh = _arc_im
	_arc_node.top_level = true
	_arc_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arc_node.custom_aabb = AABB(Vector3.ONE * -5000.0, Vector3.ONE * 10000.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_arc_node.material_override = m
	_arc_node.visible = false
	add_child(_arc_node)
	_arc_node.global_transform = Transform3D.IDENTITY
	# Impact ring (the size of the torpedo's entry hole, so you can place it).
	var tm := TorusMesh.new()
	tm.inner_radius = 1.25
	tm.outer_radius = 1.6
	tm.rings = 40
	tm.ring_segments = 6
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.no_depth_test = true
	_ring_mat.albedo_color = Color(TEAM_COL.r, TEAM_COL.g, TEAM_COL.b, 0.75)
	tm.material = _ring_mat
	_ring_node = MeshInstance3D.new()
	_ring_node.mesh = tm
	_ring_node.top_level = true
	_ring_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_node.visible = false
	add_child(_ring_node)


## The dashed arc (thin, team coloured, fading along the flight) and the impact ring.
func _draw_arc() -> void:
	if _arc_im == null:
		return
	_arc_im.clear_surfaces()
	var pts: PackedVector3Array = _pv.get("points", PackedVector3Array())
	if pts.size() >= 2:
		_arc_im.surface_begin(Mesh.PRIMITIVE_LINES)
		var n := pts.size()
		for i in range(0, n - 1):
			if (i / 3) % 2 == 1:
				continue
			var a := 0.75 * (1.0 - float(i) / float(n) * 0.65)
			_arc_im.surface_set_color(Color(TEAM_COL.r, TEAM_COL.g, TEAM_COL.b, a))
			_arc_im.surface_add_vertex(pts[i])
			_arc_im.surface_set_color(Color(TEAM_COL.r, TEAM_COL.g, TEAM_COL.b, a))
			_arc_im.surface_add_vertex(pts[i + 1])
		_arc_im.surface_end()
	if _pv.has("position"):
		var p: Vector3 = _pv["position"]
		var nrm: Vector3 = _pv.get("normal", Vector3.UP)
		_ring_node.global_transform = Transform3D(VM.basis_y(nrm), p + nrm * 0.4)


func _update_display() -> void:
	if _segs.is_empty():
		return
	var lit := maxi(int(ceilf(launch_power * float(SEGMENTS) - 0.001)), 1)
	for i in _segs.size():
		var m: ShaderMaterial = _segs[i]
		var k := float(i) / float(SEGMENTS - 1)
		var c := Color(0.35, 1.0, 0.55).lerp(Color(1.0, 0.7, 0.2), k)
		m.set_shader_parameter("color", c)
		m.set_shader_parameter("energy", (3.0 + _power_flash * 2.5 + _ready_flash * 2.0) if i < lit else 0.15)
	if _led != null:
		var lc := Color(0.35, 1.0, 0.5)
		var le := 3.5 + _ready_flash * 4.0
		if reloading or mag <= 0:
			lc = Color(1.0, 0.7, 0.2)
			le = 3.5 if fmod(_vt, 0.5) < 0.25 else 0.3
		elif not _affordable():
			lc = Color(1.0, 0.25, 0.2)
			le = 3.5 if fmod(_vt, 0.8) < 0.4 else 0.4
		_led.set_shader_parameter("color", lc)
		_led.set_shader_parameter("energy", le)


func _draw_ov() -> void:
	if player == null or not hud_visible():
		return
	var vs := _ov.size
	var c := vs * 0.5
	var a := 1.0 - clampf(ads, 0.0, 1.0) * 0.4
	# Power gauge under the crosshair: segments + speed.
	var gw := 104.0
	var gy := c.y + 66.0
	var lit := maxi(int(ceilf(launch_power * float(SEGMENTS) - 0.001)), 1)
	var sw := gw / float(SEGMENTS)
	for i in SEGMENTS:
		var r := Rect2(Vector2(c.x - gw * 0.5 + sw * i + 1.0, gy), Vector2(sw - 2.0, 5.0))
		var k := float(i) / float(SEGMENTS - 1)
		var col := Color(0.35, 1.0, 0.55).lerp(Color(1.0, 0.7, 0.2), k)
		_ov.draw_rect(r, Color(0, 0, 0, 0.4 * a))
		if i < lit:
			_ov.draw_rect(r, Color(col.r, col.g, col.b, (0.85 + 0.15 * _power_flash) * a))
	_text_c(Vector2(c.x, gy + 20.0), "GÜÇ %d m/s" % int(round(speed())), 12,
			Color(UI.TEXT.r, UI.TEXT.g, UI.TEXT.b, (0.7 + 0.3 * _power_flash) * a), _fb)
	if mag > 0 and not reloading and not _affordable():
		var blink := 0.55 + 0.45 * sin(_vt * 8.0)
		_text_c(Vector2(c.x, c.y + 46.0), "MALZEME YETERSİZ  ·  %d / %d m³" % [int(Game.material), int(Balance.TORPEDO_COST)], 13,
				Color(1.0, 0.42, 0.36, blink), _fb)
	if not _aiming:
		_text_c(Vector2(c.x, gy + 36.0), "Sağ tık: yörünge", 10, Color(UI.FAINT.r, UI.FAINT.g, UI.FAINT.b, 0.8 * a), _f)
		return
	# Aim readout.
	var w := 470.0
	var h := 80.0
	var o := Vector2(c.x - w * 0.5, gy + 40.0)
	_ov.draw_style_box(UI.box(Color(0.03, 0.05, 0.08, 0.68), 12, Color(TEAM_COL.r, TEAM_COL.g, TEAM_COL.b, 0.35), 1, 0), Rect2(o, Vector2(w, h)))
	var kind := _target_kind()
	var l1 := "GÜÇ %d m/s" % int(round(speed()))
	if _pv.has("position"):
		var p: Vector3 = _pv["position"]
		l1 += "   ·   uçuş %d sn   ·   %d m" % [int(round(float(_pv.get("time", 0.0)))), int(p.distance_to(player.global_position))]
	_text(o + Vector2(16, 26), l1, 16, UI.TEXT, _fb)
	var l2 := "Iska — torpido gezegeni kaçırıyor"
	var c2 := UI.BAD
	match kind:
		"rival":
			l2 = "HEDEF: Rakip gezegen  ·  çekirdeğe kazar"
			c2 = UI.GOOD
		"self":
			l2 = "Kendi gezegenin — torpido kazmaz"
			c2 = UI.WARN
	_text(o + Vector2(16, 50), l2, 14, c2, _fb)
	_text(o + Vector2(16, h - 9), "Teker: güç  ·  Sol tık: ateş (%d m³)  ·  malzeme %d m³" % [int(Balance.TORPEDO_COST), int(Game.material)],
			11, UI.FAINT, _f)


func _text(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	_ov.draw_string(f, p + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.55 * col.a))
	_ov.draw_string(f, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _text_c(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_text(p - Vector2(w * 0.5, 0), s, size, col, f)


# =================================================================================================
# Animation: the loaded nose, the reload choreography
# =================================================================================================

func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _gun == null or player == null:
		return
	var u := reload_progress() if reloading else -1.0
	# The loaded torpedo's drill idles; the lock collar turns during the reload.
	var tw := 0.0
	if u >= 0.0:
		tw = _seg(u, 0.78, 0.85) * PI * 0.5
	_twist = tw
	if _nose_drill != null:
		_nose_drill.rotation.z = fmod(_vt * 0.9, TAU) + _twist
	_nose.visible = mag > 0 or u >= 0.69
	var show_hand := false
	if u >= 0.0:
		var cam: Camera3D = player.camera
		var cam_xf := cam.global_transform
		var cam_inv := cam_xf.affine_inverse()
		var gun_xf := _gun.global_transform
		var gun_inv := gun_xf.affine_inverse()
		var grip_c: Vector3 = cam_inv * left_grip.global_position
		var at_grip := grip_c + HAND_OFF
		var pouch_g: Vector3 = gun_inv * (cam_xf * POUCH)
		# Carried pointing forward-up (camera frame), turned onto the tube's axis on the way.
		var held_b: Basis = gun_inv.basis.orthonormalized() * cam_xf.basis.orthonormalized() \
				* Basis.looking_at(Vector3(0.2, 0.45, -0.87).normalized(), Vector3.UP)
		var pre := Vector3(0, TUBE_Y, TUBE_FRONT - HT_TAIL - 0.04)        # tail just in front of the muzzle
		var home := Vector3(0, TUBE_Y, TUBE_FRONT + HT_DRILL)             # drill base at the muzzle
		var hold := Vector3(0, 0, -HT_GRIP)
		var tp := pre
		var tb := Basis()
		var reach := at_grip
		var rw := 1.0
		if u < 0.12:
			# Off the grip, down to the rack.
			rw = _seg(u, 0.0, 0.08)
			reach = at_grip.lerp(POUCH, _seg(u, 0.02, 0.12))
		elif u < 0.22:
			# Unclip it.
			reach = POUCH + Vector3(0.0, 0.012 * sin(u * 90.0), 0.0)
			show_hand = u > 0.16
			tb = held_b
			tp = pouch_g - tb * hold
		elif u < 0.5:
			# Bring it up in front of the muzzle, turning it onto the axis.
			show_hand = true
			var k := _seg(u, 0.22, 0.5)
			var q := Quaternion(held_b.orthonormalized()).slerp(Quaternion(), _seg(u, 0.26, 0.47))
			tb = Basis(q)
			var grip_pt := pouch_g.lerp(pre + hold, k) + Vector3(0, 0.07 * sin(k * PI), 0)
			tp = grip_pt - tb * hold
			reach = cam_inv * (gun_xf * grip_pt) + HAND_OFF
		elif u < 0.69:
			# Slide it in, tail first; the hand moves up to push on the nose.
			show_hand = true
			var k2 := _seg(u, 0.5, 0.69)
			tp = pre.lerp(home, k2)
			var push := Vector3(0, 0, -lerpf(HT_GRIP, HT_DRILL + NOSE_LEN + 0.02, _seg(u, 0.52, 0.66)))
			reach = cam_inv * (gun_xf * (tp + push)) + HAND_OFF
		elif u < 0.88:
			# Seated: the palm on the nose, the collar twisted to lock.
			var nose_pt := Vector3(0, TUBE_Y, TUBE_FRONT - NOSE_LEN - 0.02)
			reach = cam_inv * (gun_xf * nose_pt) + HAND_OFF + Vector3(0.015 * sin(_twist * 2.0), 0.0, 0.0)
		else:
			# Back to the foregrip.
			var nose_pt2 := Vector3(0, TUBE_Y, TUBE_FRONT - NOSE_LEN - 0.02)
			reach = (cam_inv * (gun_xf * nose_pt2) + HAND_OFF).lerp(at_grip, _seg(u, 0.88, 0.98))
			rw = 1.0 - _seg(u, 0.94, 1.0)
		left_reach_w = rw
		left_reach = reach
		left_reach_elbow = Vector3(-0.35, -0.8, 0.45)
		if show_hand:
			_hand_torp.transform = Transform3D(tb, tp)
	else:
		left_reach_w = 0.0
	_hand_torp.visible = show_hand


# =================================================================================================
# Model
# =================================================================================================

## The view-model drill bit material: the VM shader drawn double-sided (a generated mesh).
static func _vm_drill_mat() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = VM.prep(VM.VM_SHADER.replace("cull_back", "cull_disabled"))
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("albedo", Color(0.62, 0.64, 0.68))
	m.set_shader_parameter("roughness", 0.24)
	m.set_shader_parameter("metallic", 0.9)
	m.set_shader_parameter("rim", 0.3)
	return m


func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	var rubber := VM.rubber()
	var gray := VM.mat(Color(0.3, 0.32, 0.35), 0.45, 0.4)
	var black := VM.mat(Color(0.03, 0.03, 0.035), 0.6, 0.2)
	var team_glow := VM.glow(TEAM_COL, 3.5)
	var drill_m := _vm_drill_mat()
	var ty := TUBE_Y
	# Pistol grip, trigger and guard.
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.024, -0.022), Vector3(0, -0.024, -0.072), 0.0045, steel)      # low: room for the trigger finger
	VM.capsule(_gun, Vector3(0, -0.024, -0.072), Vector3(0, 0.022, -0.084), 0.0045, steel)
	# Fire-control block between the grip and the tube.
	VM.soft_box(_gun, Vector3(0, 0.0285, -0.045), Vector3(0.05, 0.045, 0.17), 0.01, gray)      # room for the trigger finger
	VM.box(_gun, Vector3(0, 0.046, -0.04), Vector3(0.036, 0.02, 0.22), dark)
	VM.box(_gun, Vector3(0.026, 0.03, -0.06), Vector3(0.004, 0.012, 0.05), orange)
	# The tube: white composite, orange bands, a rubber shoulder pad.
	VM.seg(_gun, Vector3(0, ty, TUBE_BACK - 0.07), Vector3(0, ty, TUBE_FRONT + 0.07), TUBE_R, TUBE_R, white, 24)
	for z in [-0.42, -0.15, 0.22]:
		VM.ring(_gun, Vector3(0, ty, z), Vector3.FORWARD, TUBE_R + 0.004, 0.006, orange)
	VM.box(_gun, Vector3(0, ty + TUBE_R + 0.002, -0.28), Vector3(0.016, 0.004, 0.2), dark)
	VM.soft_box(_gun, Vector3(0, ty - TUBE_R - 0.012, 0.15), Vector3(0.05, 0.03, 0.17), 0.01, rubber)
	# Front shroud, muzzle ring, the dark bore.
	VM.seg(_gun, Vector3(0, ty, TUBE_FRONT + 0.09), Vector3(0, ty, TUBE_FRONT), TUBE_R + 0.008, TUBE_R + 0.011, dark, 24)
	VM.ring(_gun, Vector3(0, ty, TUBE_FRONT + 0.004), Vector3.FORWARD, TUBE_R + 0.011, 0.008, steel)
	for i in 4:
		var a := TAU * (float(i) + 0.5) / 4.0
		VM.box(_gun, Vector3(cos(a) * (TUBE_R + 0.01), ty + sin(a) * (TUBE_R + 0.01), TUBE_FRONT + 0.05),
				Vector3(0.008, 0.008, 0.05), black)
	VM.seg(_gun, Vector3(0, ty, TUBE_FRONT + 0.03), Vector3(0, ty, TUBE_FRONT + 0.003), TUBE_R - 0.004, TUBE_R - 0.004, black, 18)
	# Rear venturi (flared) and its dark throat.
	VM.seg(_gun, Vector3(0, ty, TUBE_BACK - 0.08), Vector3(0, ty, TUBE_BACK + 0.04), TUBE_R + 0.004, TUBE_R + 0.024, dark, 24)
	VM.seg(_gun, Vector3(0, ty, TUBE_BACK + 0.0), Vector3(0, ty, TUBE_BACK + 0.035), TUBE_R - 0.01, TUBE_R + 0.012, black, 18)
	# Vertical foregrip for the left hand.
	VM.soft_box(_gun, Vector3(0, ty - TUBE_R - 0.012, -0.255), Vector3(0.034, 0.026, 0.06), 0.008, dark)
	VM.box(_gun, Vector3(0, 0.008, -0.255), Vector3(0.02, 0.016, 0.03), dark)
	VM.capsule(_gun, Vector3(0, -0.07, -0.25), Vector3(0, -0.01, -0.258), 0.0165, rubber)
	VM.seg(_gun, Vector3(0, -0.096, -0.249), Vector3(0, -0.083, -0.25), 0.019, 0.018, orange)
	left_grip = VM.node(_gun, Vector3(0, -0.006, -0.254), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	# Holographic sight on a bracket off the tube's left side.
	VM.box(_gun, Vector3(SIGHT_X + 0.018, ty + 0.014, -0.005), Vector3(0.034, 0.024, 0.07), dark)
	var sight := VM.node(_gun, Vector3(SIGHT_X, 0, 0))
	VM.holo_sight(sight, 0.0, ty + 0.022, SIGHT_Y, Color(1.0, 0.55, 0.15))
	# Power display on top of the tube, tilted toward the eye: 8 segments and a status LED.
	var disp := VM.node(_gun, Vector3(0.0, ty + TUBE_R + 0.024, 0.07), Basis(Vector3.RIGHT, -0.2))
	VM.box(_gun, Vector3(0.0, ty + TUBE_R + 0.008, 0.07), Vector3(0.014, 0.018, 0.014), dark)
	VM.soft_box(disp, Vector3.ZERO, Vector3(0.06, 0.03, 0.01), 0.004, dark)
	VM.box(disp, Vector3(0, 0, 0.0052), Vector3(0.052, 0.022, 0.001), black)
	_segs.clear()
	for i in SEGMENTS:
		var g := VM.glow(Color(0.35, 1.0, 0.55), 0.15)
		_segs.append(g)
		VM.box(disp, Vector3(-0.0175 + float(i) * 0.005, -0.002, 0.006), Vector3(0.0036, 0.012, 0.0012), g)
	_led = VM.glow(Color(0.35, 1.0, 0.5), 3.5)
	VM.sphere(disp, Vector3(-0.022, 0.0075, 0.0058), 0.0022, _led)
	VM.box(disp, Vector3(0.014, 0.0078, 0.006), Vector3(0.016, 0.0018, 0.001), orange)
	# The loaded torpedo: its fluted drill out of the muzzle, the cutter collar, the band inside.
	_nose = VM.node(_gun, Vector3(0, ty, TUBE_FRONT))
	_nose_drill = VM.node(_nose)
	VM.mesh_inst(_nose_drill, Torpedo.drill_mesh(NOSE_LEN, NOSE_R), drill_m)
	VM.seg(_nose_drill, Vector3(0, 0, 0.014), Vector3(0, 0, -0.004), NOSE_R + 0.005, NOSE_R + 0.004, dark, 16)
	for i in 6:
		var a2 := TAU * float(i) / 6.0
		VM.box(_nose_drill, Vector3(cos(a2) * (NOSE_R + 0.004), sin(a2) * (NOSE_R + 0.004), -0.002),
				Vector3(0.01, 0.008, 0.012), steel, Basis(Vector3.BACK, a2))
	VM.ring(_nose, Vector3(0, 0, 0.022), Vector3.FORWARD, NOSE_R + 0.003, 0.004, team_glow)
	# The torpedo the left hand loads (hidden until the reload): its centre at the origin, nose -Z.
	_hand_torp = VM.node(_gun)
	var ht_drill := VM.node(_hand_torp, Vector3(0, 0, -HT_DRILL))
	VM.mesh_inst(ht_drill, Torpedo.drill_mesh(NOSE_LEN, NOSE_R), drill_m)
	VM.seg(_hand_torp, Vector3(0, 0, -HT_DRILL + 0.014), Vector3(0, 0, -HT_DRILL - 0.004), NOSE_R + 0.005, NOSE_R + 0.004, dark, 16)
	VM.seg(_hand_torp, Vector3(0, 0, -HT_DRILL + 0.012), Vector3(0, 0, HT_TAIL - 0.06), NOSE_R - 0.002, NOSE_R - 0.002, white, 18)
	for z in [-0.12, 0.16]:
		VM.ring(_hand_torp, Vector3(0, 0, z), Vector3.FORWARD, NOSE_R + 0.001, 0.005, orange)
	VM.ring(_hand_torp, Vector3(0, 0, 0.0), Vector3.FORWARD, NOSE_R + 0.002, 0.004, team_glow)
	VM.seg(_hand_torp, Vector3(0, 0, HT_TAIL - 0.06), Vector3(0, 0, HT_TAIL), NOSE_R - 0.002, NOSE_R * 0.7, dark, 16)
	for i in 4:
		var a3 := TAU * (float(i) + 0.5) / 4.0
		VM.box(_hand_torp, Vector3(cos(a3) * (NOSE_R + 0.01), sin(a3) * (NOSE_R + 0.01), HT_TAIL - 0.07),
				Vector3(0.024, 0.004, 0.08), orange, Basis(Vector3.BACK, a3))
	_hand_torp.visible = false
	_muzzle = VM.node(_gun, Vector3(0, ty, TUBE_FRONT - 0.12))
	_make_flash(_gun, Vector3(0, ty, TUBE_FRONT - 0.14), 2.0, Color(1.0, 0.6, 0.25))
	VM.bake(_gun, [_flash_root, _muzzle, _nose, _hand_torp, disp, left_grip, sight])
	VM.bake(_nose_drill)
	VM.bake(_hand_torp)
	return model


func _build_tp(p: Node3D) -> Node3D:
	var white := _tp_mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tp_mat(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _tp_mat(Color(0.16, 0.17, 0.19), 0.4, 0.6)
	var rubber := _tp_mat(Color(0.08, 0.08, 0.09), 0.9, 0.0)
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, rubber)
	VM.box(p, Vector3(0, 0.03, -0.04), Vector3(0.05, 0.05, 0.16), dark)
	VM.seg(p, Vector3(0, TUBE_Y, TUBE_BACK - 0.07), Vector3(0, TUBE_Y, TUBE_FRONT + 0.07), TUBE_R, TUBE_R, white, 12)
	VM.seg(p, Vector3(0, TUBE_Y, TUBE_FRONT + 0.09), Vector3(0, TUBE_Y, TUBE_FRONT), TUBE_R + 0.008, TUBE_R + 0.011, dark, 12)
	VM.seg(p, Vector3(0, TUBE_Y, TUBE_BACK - 0.08), Vector3(0, TUBE_Y, TUBE_BACK + 0.04), TUBE_R + 0.004, TUBE_R + 0.024, dark, 12)
	for z in [-0.42, 0.22]:
		VM.seg(p, Vector3(0, TUBE_Y, z + 0.01), Vector3(0, TUBE_Y, z - 0.01), TUBE_R + 0.004, TUBE_R + 0.004, orange, 12)
	VM.box(p, Vector3(SIGHT_X, SIGHT_Y, 0.0), Vector3(0.04, 0.04, 0.05), dark)
	VM.capsule(p, Vector3(0, -0.07, -0.25), Vector3(0, -0.01, -0.258), 0.017, rubber)
	return VM.node(p, Vector3(0, TUBE_Y, TUBE_FRONT - 0.03))


## Inspect (Y, scripts/items/handling.gd): the drill nose spins two turns for a look (ending where
## it started, so nothing snaps) while the left hand checks the sight.
func _inspect_touch(u: float, w: float) -> void:
	if _nose_drill != null:
		_nose_drill.rotation.z += TAU * 2.0 * smoothstep(0.3, 0.75, u) * w
