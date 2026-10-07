extends "res://scripts/war/cannon.gd"
## Delici Top (bunker buster), built with the İnşa Aracı (Balance.BUSTER_COST). A cannon underneath
## (scripts/war/cannon.gd: the seat API, aiming, the arc preview, damage, settling on dug ground,
## the multiplayer structure sync all come from there; its behaviour is unchanged) with its own
## look and shell: a squat howitzer on a reinforced octagonal pad with hazard-striped edges and four
## hydraulic stabilizer jacks, a heavy turret with armoured trunnion cheeks, a thick short barrel
## (jacket, reinforcing hoops, glowing team band, hazard-striped muzzle collar) raised by two
## hydraulic rams that follow the elevation, and a rack of drill-tipped penetrators (one goes
## missing while the next is being loaded).
## Groups "damageable", "war_structure", "war_buster", deliberately NOT "war_cannon" (the rival AI
## would take it for a cheap cannon; it learns the buster separately). Footprint BUSTER_FOOTPRINT.
##
## Player (team "home"): F mans it ("Delici topa geç"), the same arc preview and controls as the
## cannon, the overlay titled "DELİCİ TOP". LMB fires a penetrator (scripts/war/buster_shell.gd):
## BUSTER_SHELL_COST material, BUSTER_RELOAD s. AI: fire(true, on_impact) like Cannon.fire (paid).
##   Buster.spawn(parent, body, xf, team, animate := true) -> the buster
##   fire(paid := false, on_impact := Callable()) -> bool
## Multiplayer: net_world.gd registers it as a structure (its base script is cannon.gd) and replays
## it on the other peer by this script's path; the shot goes through Net.world.on_shell_fired
## (BusterShell.fire) and the other peer's copy plays net_fire_fx() (overridden: the buster's look
## and BUSTER_RELOAD).

const BusterShell := preload("res://scripts/war/buster_shell.gd")
const Torpedo := preload("res://scripts/war/torpedo.gd")
const HudLvl := preload("res://scripts/ui/hud_level.gd")   # toasts: "no_mat" (1), "buster" (1); not HudLevel (cannon.gd may name one)

const CRADLE_Y := 1.0                 # trunnion height above the turret base
const SLEEVE_LEN := 1.05              # hydraulic ram: cylinder from the deck anchor...
const ROD_LEN := 1.2                  # ...and the piston rod from the barrel lug
const RACK_N := 4

var _rams: Array = []                 # [sleeve, rod, deck anchor (turret frame), lug (cradle frame)]
var _rack_shells: Array = []
var _band: StandardMaterial3D
var _hiss: AudioStreamPlayer3D
var _hiss_t := -1.0
var _t := 0.0


static func spawn(parent: Node, p_body: Node3D, xf: Transform3D, p_team: String, animate := true) -> Node3D:
	var c: Node3D = load("res://scripts/war/buster.gd").new()
	c.team = p_team
	c.body = p_body
	c.name = "Buster_" + p_team
	c.transform = xf
	parent.add_child(c)
	if animate:
		c.begin_assembly()
	return c


func _init() -> void:
	hp = Balance.BUSTER_HP
	hp_max = Balance.BUSTER_HP


func _ready() -> void:
	super._ready()
	remove_from_group("war_cannon")
	add_to_group("war_buster")
	set_meta("footprint_r", Balance.BUSTER_FOOTPRINT)
	_hiss = AudioStreamPlayer3D.new()
	_hiss.stream = Snd.rand("foley/hiss", 1.05, 1.5)
	_hiss.unit_size = 10.0
	_hiss.max_distance = 300.0
	_hiss.volume_db = 2.0
	add_child(_hiss)
	_update_rams()


## Foundation (cannon.gd / scripts/war/foundation.gd): the wider octagonal pad and a pile under
## each stabilizer jack.
func _foundation_shape() -> Array:
	var piles: Array = []
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		piles.append([Vector3(-2.98 * sin(a), 0.0, -2.98 * cos(a)), 0.18])
	return [Foundation.polygon(8, 2.64, -0.15), piles, Color(0.34, 0.33, 0.31)]


# =================================================================================================
# Model
# =================================================================================================

## A strip of diagonal hazard stripes (yellow with black slashes) of `length` × `height`, centred at
## `pos` with basis `b` (x along the strip, z out of its face).
func _hazard(parent: Node3D, pos: Vector3, b: Basis, length: float, height: float, yellow: Material, black: Material) -> void:
	var n := Node3D.new()
	n.transform = Transform3D(b, pos)
	parent.add_child(n)
	_box(n, Vector3.ZERO, Vector3(length, height, 0.03), yellow)
	var step := 0.2
	var count := int(floorf((length - height * 0.7) / step))
	var shear := Basis(Vector3(1, 0, 0), Vector3(0.7, 1, 0), Vector3(0, 0, 1))
	for i in count:
		var x := -length * 0.5 + height * 0.35 + step * (float(i) + 0.5)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.08, height, 0.034)
		mi.mesh = bm
		mi.material_override = black
		mi.transform = Transform3D(shear, Vector3(x, 0, 0.002))
		n.add_child(mi)


func _build_model() -> void:
	var home := team == "home"
	var concrete := _mat(Color(0.34, 0.33, 0.31), 0.0, 0.93)
	var steel := _mat(Color(0.21, 0.22, 0.23), 0.85, 0.36)
	var dark := _mat(Color(0.08, 0.08, 0.09), 0.6, 0.5)
	var yellow := _mat(Color(0.95, 0.7, 0.08), 0.15, 0.55)
	var black := _mat(Color(0.04, 0.04, 0.04), 0.1, 0.7)
	_paint = _mat(Color(0.27, 0.29, 0.31) if home else Color(0.31, 0.22, 0.2), 0.45, 0.5)
	var accent := Color(0.35, 0.85, 1.0) if home else Color(0.95, 0.25, 0.15)
	_band = _mat(accent, 0.1, 0.5)
	_band.emission_enabled = true
	_band.emission = accent
	_band.emission_energy_multiplier = 1.2
	var drill_mat := _mat(Color(0.62, 0.64, 0.68), 0.92, 0.24)
	drill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# --- Pad: octagonal slab, steel rim, hazard stripes all round, four stabilizer jacks.
	var pad := Node3D.new()
	add_child(pad)
	_cyl(pad, Vector3(0, 0.2, 0), 2.5, 2.7, 0.8, concrete, "y", 8)
	_cyl(pad, Vector3(0, 0.62, 0), 2.46, 2.5, 0.06, steel, "y", 8)
	for k in 8:
		var u := (float(k) + 0.5) / 8.0 * TAU
		var out := Vector3(sin(u), 0, cos(u))
		var along := Vector3(cos(u), 0, -sin(u))
		_hazard(pad, out * 2.37 + Vector3(0, 0.47, 0), Basis(along, Vector3.UP, out), 1.5, 0.14, yellow, black)
		_cyl(pad, out * 2.0 + Vector3(0, 0.67, 0), 0.08, 0.08, 0.1, steel, "y", 8)
	for i in 4:
		var leg := Node3D.new()
		leg.rotation.y = TAU * float(i) / 4.0 + PI * 0.25
		pad.add_child(leg)
		_box(leg, Vector3(0, 0.42, -2.55), Vector3(0.4, 0.3, 0.9), _paint)
		_box(leg, Vector3(0, 0.58, -2.55), Vector3(0.42, 0.03, 0.92), yellow)
		_cyl(leg, Vector3(0, 0.38, -2.98), 0.16, 0.16, 0.5, steel, "y", 12)
		_cyl(leg, Vector3(0, 0.12, -2.98), 0.09, 0.09, 0.3, _mat(Color(0.7, 0.72, 0.75), 0.9, 0.2), "y", 10)
		_cyl(leg, Vector3(0, 0.03, -2.98), 0.3, 0.34, 0.07, dark, "y", 12)
	_parts.append([pad, pad.transform, 0.0])

	# --- Turret (yaw): slewing ring, deck, armoured trunnion cheeks, rack, console, tanks.
	_turret = Node3D.new()
	_turret.position = Vector3(0, 0.65, 0)
	add_child(_turret)
	_cyl(_turret, Vector3(0, 0.14, 0), 1.65, 1.75, 0.28, steel, "y", 32)
	_cyl(_turret, Vector3(0, 0.3, 0), 1.5, 1.55, 0.06, dark, "y", 32)
	_box(_turret, Vector3(0, 0.38, 0.15), Vector3(3.0, 0.16, 3.0), _paint)
	_hazard(_turret, Vector3(0, 0.38, -1.36), Basis(), 2.9, 0.12, yellow, black)
	for sx in [-1.0, 1.0]:
		_box(_turret, Vector3(0.86 * sx, 1.0, 0.1), Vector3(0.3, 1.2, 1.6), _paint)
		_box(_turret, Vector3(0.86 * sx, 0.78, -0.82), Vector3(0.32, 0.85, 0.12), _paint, Vector3(0.55, 0, 0))
		_box(_turret, Vector3(0.86 * sx, 1.62, 0.1), Vector3(0.34, 0.05, 1.62), steel)
		var br := _cyl(_turret, Vector3(0.86 * sx, CRADLE_Y, 0.0), 0.27, 0.27, 0.38, steel, "y", 18)
		br.rotation = Vector3(0, 0, PI * 0.5)
		var cap := _cyl(_turret, Vector3(1.06 * sx, CRADLE_Y, 0.0), 0.16, 0.16, 0.05, _band, "y", 16)
		cap.rotation = Vector3(0, 0, PI * 0.5)
		# Hydraulic accumulators outboard.
		var tank := _cyl(_turret, Vector3(1.22 * sx, 0.62, 0.55), 0.16, 0.16, 1.1, steel, "z", 14)
		tank.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_box(_turret, Vector3(1.22 * sx, 0.5, 0.55), Vector3(0.3, 0.08, 0.9), dark)
		# Deck anchor of this side's ram.
		_box(_turret, Vector3(0.56 * sx, 0.5, 0.05), Vector3(0.2, 0.16, 0.26), dark)
	# Rack of drill-tipped penetrators behind the right cheek.
	var rack := Node3D.new()
	rack.position = Vector3(0.95, 0.46, 1.05)
	_turret.add_child(rack)
	_box(rack, Vector3(0, 0.05, 0), Vector3(0.9, 0.1, 0.9), dark)
	for sz in [-0.42, 0.42]:
		_box(rack, Vector3(0, 0.45, sz), Vector3(0.9, 0.06, 0.06), steel)
	for sx2 in [-0.42, 0.42]:
		for sz2 in [-0.42, 0.42]:
			_box(rack, Vector3(sx2, 0.3, sz2), Vector3(0.06, 0.6, 0.06), steel)
	_rack_shells.clear()
	for i in RACK_N:
		var sh := Node3D.new()
		sh.position = Vector3(-0.2 + 0.4 * float(i % 2), 0.1, -0.2 + 0.4 * float(i >> 1))
		rack.add_child(sh)
		_cyl(sh, Vector3(0, 0.34, 0), 0.15, 0.15, 0.62, steel, "y", 16)
		_cyl(sh, Vector3(0, 0.46, 0), 0.155, 0.155, 0.06, _band, "y", 16)
		_cyl(sh, Vector3(0, 0.2, 0), 0.155, 0.155, 0.04, yellow, "y", 16)
		var nose := MeshInstance3D.new()
		nose.mesh = Torpedo.drill_mesh(0.3, 0.155)
		nose.material_override = drill_mat
		nose.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, 0.65, 0))
		sh.add_child(nose)
		_rack_shells.append(sh)
	# Fire-control console on the left with a lit screen.
	_box(_turret, Vector3(-1.15, 0.78, 1.0), Vector3(0.5, 0.64, 0.42), dark)
	var screen := _mat(Color(0.05, 0.1, 0.12), 0.0, 0.4)
	screen.emission_enabled = true
	screen.emission = accent
	screen.emission_energy_multiplier = 0.9
	_box(_turret, Vector3(-1.15, 0.92, 1.215), Vector3(0.36, 0.22, 0.012), screen)
	_box(_turret, Vector3(-1.15, 1.13, 1.0), Vector3(0.52, 0.04, 0.44), steel)
	_box(_turret, Vector3(0, 0.47, 1.85), Vector3(1.3, 0.08, 0.6), dark)
	_parts.append([_turret, _turret.transform, 0.25])

	# --- Cradle (pitch) and the recoiling barrel group: breech, jacket, hoops, tube, muzzle collar.
	_cradle = Node3D.new()
	_cradle.position = Vector3(0, CRADLE_Y, 0)
	_turret.add_child(_cradle)
	for sx in [-1.0, 1.0]:
		var pin := _cyl(_cradle, Vector3(0.6 * sx, 0, 0), 0.2, 0.2, 0.26, steel, "y", 16)
		pin.rotation = Vector3(0, 0, PI * 0.5)
		# Ram lugs under the barrel.
		_box(_cradle, Vector3(0.53 * sx, -0.5, -1.35), Vector3(0.16, 0.2, 0.26), dark)
	_box(_cradle, Vector3(0, -0.47, -1.35), Vector3(1.1, 0.1, 0.32), steel)
	_recoil = Node3D.new()
	_cradle.add_child(_recoil)
	_box(_recoil, Vector3(0, 0, 0.12), Vector3(1.0, 0.95, 0.6), steel)
	_box(_recoil, Vector3(0, 0.0, 0.43), Vector3(0.8, 0.75, 0.04), dark)
	_box(_recoil, Vector3(0.36, 0.22, 0.46), Vector3(0.08, 0.08, 0.3), dark, Vector3(0.5, 0, 0))
	_cyl(_recoil, Vector3(0, 0, -0.82), 0.5, 0.5, 1.35, _paint, "z", 28)
	for z in [-0.35, -1.0, -1.45]:
		_cyl(_recoil, Vector3(0, 0, z), 0.53, 0.53, 0.09, steel, "z", 28)
	_cyl(_recoil, Vector3(0, 0, -2.12), 0.4, 0.43, 1.3, steel, "z", 28)
	_cyl(_recoil, Vector3(0, 0, -2.2), 0.41, 0.41, 0.1, _band, "z", 28)
	_cyl(_recoil, Vector3(0, 0, -2.93), 0.52, 0.5, 0.36, dark, "z", 28)
	_cyl(_recoil, Vector3(0, 0, -2.84), 0.525, 0.525, 0.06, yellow, "z", 28)
	_cyl(_recoil, Vector3(0, 0, -2.93), 0.526, 0.526, 0.06, black, "z", 28)
	_cyl(_recoil, Vector3(0, 0, -3.02), 0.525, 0.525, 0.06, yellow, "z", 28)
	_cyl(_recoil, Vector3(0, 0, -3.09), 0.36, 0.36, 0.03, _mat(Color(0.02, 0.02, 0.02), 0.2, 0.9), "z", 24)
	_muzzle = Node3D.new()
	_muzzle.position = Vector3(0, 0, -3.25)
	_recoil.add_child(_muzzle)
	_parts.append([_cradle, _cradle.transform, 0.5])

	# --- Hydraulic rams (deck anchor -> barrel lug), re-aimed every frame.
	_rams.clear()
	for sx in [-1.0, 1.0]:
		var sleeve := _cyl(_turret, Vector3.ZERO, 0.09, 0.09, SLEEVE_LEN, steel, "y", 14)
		var rod := _cyl(_turret, Vector3.ZERO, 0.045, 0.045, ROD_LEN, _mat(Color(0.75, 0.77, 0.8), 0.95, 0.15), "y", 10)
		_rams.append([sleeve, rod, Vector3(0.56 * sx, 0.55, 0.05), Vector3(0.53 * sx, -0.5, -1.35)])

	for mi in find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Collision (terrain-like obstacle on the ship layer) + interaction.
	_body = StaticBody3D.new()
	_body.collision_layer = Game.LAYER_SHIP
	_body.collision_mask = 0
	_body.set_meta("interact_target", self)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(3.2, 2.2, 3.4)
	cs.shape = bs
	cs.position = Vector3(0, 1.3, 0)
	_body.add_child(cs)
	var cs2 := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 2.6
	cyl.height = 0.8
	cs2.shape = cyl
	cs2.position = Vector3(0, 0.2, 0)
	_body.add_child(cs2)
	add_child(_body)

	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.68, 0.38)
	_flash.omni_range = 26.0
	_flash.light_energy = 0.0
	_flash.shadow_enabled = false
	_muzzle.add_child(_flash)

	_cam = Camera3D.new()
	_cam.near = 0.1
	_cam.far = Game.CAM_FAR
	_cam.fov = Settings.fov
	_turret.add_child(_cam)


## Points the two rams from their deck anchors to the barrel lugs (they stretch with the elevation).
func _update_rams() -> void:
	if _cradle == null:
		return
	for r in _rams:
		var a: Vector3 = r[2]
		var b: Vector3 = _cradle.transform * (r[3] as Vector3)
		var d := b - a
		if d.length_squared() < 1e-4:
			continue
		var dir := d.normalized()
		var bb := _basis_y(dir)
		(r[0] as Node3D).transform = Transform3D(bb, a + dir * SLEEVE_LEN * 0.5)
		(r[1] as Node3D).transform = Transform3D(bb, b - dir * ROD_LEN * 0.5)


# =================================================================================================
# Firing
# =================================================================================================

## Fires one penetrator. paid = the material was already taken (the AI); the player's buster takes
## BUSTER_SHELL_COST from Game.material. Returns true when it fired.
func fire(paid := false, on_impact := Callable()) -> bool:
	if not ready_to_fire():
		if pilot != null and Game.sfx:
			Game.sfx.play("click", -8.0, 0.7)
		return false
	if not paid and not Game.spend_material(Balance.BUSTER_SHELL_COST):
		if pilot != null:
			if Game.hud:
				HudLvl.alert("Yetersiz malzeme — delici mermi %d m³" % int(Balance.BUSTER_SHELL_COST), 1, "no_mat", 2.0)
			if Game.sfx:
				Game.sfx.play("error", -10.0)
		return false
	var dir := barrel_dir()
	reload_t = Balance.BUSTER_RELOAD
	BusterShell.fire(get_tree().current_scene, muzzle_position() + dir * 0.6, dir * speed(), team, [_body.get_rid()], on_impact)
	_fire_fx(dir)
	return true


## Multiplayer: the other peer fired this buster (its penetrator comes as the shell event).
func net_fire_fx() -> void:
	_fire_fx(barrel_dir())


## The heavy shot: deep boom, long recoil, two smoke clouds, dust off the pad, the rams hiss.
func _fire_fx(dir: Vector3) -> void:
	reload_t = Balance.BUSTER_RELOAD
	_recoil_v = 9.5
	_flash_t = 1.0
	_cam_kick_v += 5.0
	_muzzle_smoke(muzzle_position(), dir)
	_muzzle_smoke(muzzle_position() + dir * 1.6, dir)
	BuildFx.dust(get_parent(), global_position, global_transform.basis.y, 3.8, Color(0.55, 0.5, 0.42))
	_audio.pitch_scale = randf_range(0.7, 0.78)
	_audio.play()
	_boom_low.pitch_scale = randf_range(0.42, 0.5)
	_boom_low.volume_db = -1.0
	_boom_low.play()
	_hiss_t = 0.4
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pilot == null and pl.has_method("add_trauma"):
		var d: float = pl.global_position.distance_to(global_position)
		if d < 70.0:
			pl.add_trauma(0.55 * (1.0 - d / 70.0))


func _process(delta: float) -> void:
	super._process(delta)
	_t += delta
	_update_rams()
	# The next penetrator is missing from the rack while it is being loaded.
	if not _rack_shells.is_empty():
		(_rack_shells[0] as Node3D).visible = reload_t <= 0.0 or _build_t >= 0.0
	if _hiss_t >= 0.0:
		_hiss_t -= delta
		if _hiss_t < 0.0 and _hiss != null:
			_hiss.pitch_scale = randf_range(0.7, 0.85)
			_hiss.play()
	if _band != null:
		var ready := reload_t <= 0.0 and not is_destroyed
		_band.emission_energy_multiplier = (1.2 + 0.5 * sin(_t * 3.0)) if ready else 0.35


# =================================================================================================
# Manned
# =================================================================================================

func get_interact_prompt() -> String:
	var p := super.get_interact_prompt()
	if p == "Topa geç":
		return "Delici topa geç"
	if p == "Top kuruluyor…":
		return "Delici top kuruluyor…"
	return p


func hud_name() -> String:
	return "Delici Top"


## The cannon's preview with the buster's crater ring.
func _make_preview_nodes() -> void:
	super._make_preview_nodes()
	var tm := _ring.mesh as TorusMesh
	if tm != null:
		tm.inner_radius = Balance.BUSTER_CRATER_R - 0.6
		tm.outer_radius = Balance.BUSTER_CRATER_R


func _draw_overlay() -> void:
	var vs := _ov.size
	var c := vs * 0.5
	# Sight reticle (heavier than the cannon's: a square bracket and the ring).
	var rc := Color(1.0, 0.8, 0.35, 0.85)
	_ov.draw_arc(c, 22.0, 0, TAU, 48, Color(0, 0, 0, 0.4), 3.0, true)
	_ov.draw_arc(c, 22.0, 0, TAU, 48, rc, 1.5, true)
	for q in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var qv: Vector2 = q
		_ov.draw_line(c + qv * 34.0, c + Vector2(qv.x * 34.0, qv.y * 24.0), rc, 2.0, true)
		_ov.draw_line(c + qv * 34.0, c + Vector2(qv.x * 24.0, qv.y * 34.0), rc, 2.0, true)
	# Readout panel (bottom centre).
	var w := 540.0
	var h := 128.0
	var o := Vector2(c.x - w * 0.5, vs.y - h - 28.0)
	_ov.draw_style_box(UI.box(Color(0.05, 0.05, 0.04, 0.72), 12, Color(1.0, 0.75, 0.2, 0.4), 1, 0), Rect2(o, Vector2(w, h)))
	_text(o + Vector2(18, 24), "DELİCİ TOP", 13, Color(1.0, 0.78, 0.3), _font_b)
	_text(o + Vector2(118, 24), "penetrasyon %d m  ·  krater %.1f m" % [int(Balance.BUSTER_PENETRATE), Balance.BUSTER_CRATER_R],
			11, UI.DIM, _font)
	var line1 := "AÇI %d°   ·   YÖN %d°   ·   BARUT %d m/s" % [int(round(rad_to_deg(pitch))),
			int(round(fposmod(rad_to_deg(-yaw), 360.0))), int(round(speed()))]
	_text(o + Vector2(18, 50), line1, 17, UI.TEXT, _font_b)
	var kind := _target_kind()
	var l2 := ""
	var c2 := UI.GOOD
	match kind:
		"rival":
			var p: Vector3 = _preview["position"]
			l2 = "İSABET: RAKİP GEZEGEN  ·  %d m  ·  uçuş %d sn" % [int(p.distance_to(global_position)), int(round(float(_preview.get("time", 0.0))))]
		"self":
			l2 = "DİKKAT: delici kendi gezegenimize düşer"
			c2 = UI.WARN
		_:
			l2 = "ISKA: delici gezegeni kaçırıyor"
			c2 = UI.BAD
	_text(o + Vector2(18, 76), l2, 15, c2, _font_b)
	var rl := "HAZIR" if reload_t <= 0.0 else "DOLDURULUYOR %.1f sn" % reload_t
	_text(o + Vector2(18, 100), "%s   ·   delici mermi %d m³   ·   malzeme %d m³" % [rl, int(Balance.BUSTER_SHELL_COST), int(Game.material)],
			13, UI.DIM if reload_t > 0.0 else UI.TEXT, _font)
	var bar := Rect2(o + Vector2(18, 108), Vector2(w - 36, 4))
	_ov.draw_rect(bar, Color(1, 1, 1, 0.08))
	_ov.draw_rect(Rect2(bar.position, Vector2(bar.size.x * (1.0 - reload_t / Balance.BUSTER_RELOAD), bar.size.y)), Color(1.0, 0.75, 0.25))
	_text(o + Vector2(18, h - 4), "Fare: nişan  ·  Teker: barut  ·  Sol tık: ateş  ·  F: in", 11, UI.FAINT, _font)
	_text(Vector2(vs.x - 240, vs.y - 40), "DELİCİ TOP %d / %d" % [int(ceilf(hp)), int(hp_max)], 13,
			UI.BAD if hp < hp_max * 0.35 else UI.DIM, _font_b)


# =================================================================================================
# Damage
# =================================================================================================

func _destroy() -> void:
	if is_destroyed:
		return
	remove_from_group("war_buster")
	super._destroy()
	if Game.hud and team == "home":
		HudLvl.alert("Delici topumuz yok edildi!", 1, "buster", 2.5)
