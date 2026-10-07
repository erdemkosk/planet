extends "res://scripts/items/weapon_base.gd"
## Delici Raylı Tüfek ("Raylı", item id "rail"; crafted at the Silahlık, scripts/war/craft.gd; its key
## comes from the loadout; WEIGHT 0.9 = mobility while carried): a charged
## railgun whose beam goes THROUGH the ground. The way to hit an enemy in a tunnel from the surface or
## from another tunnel.
##   Charge   hold LMB: the charge builds over Balance.RAIL_CHARGE_TIME (a rising whine, the coils and
##            the rail channel glow brighter, the gun trembles and pulls in, a ring at the crosshair);
##            release to fire. Below RAIL_MIN_CHARGE the release only vents (no round used). R while
##            charging vents the charge instead of reloading. The charge is held as long as LMB is.
##   Beam     straight from the eye along the aim (no drop), out to RAIL_RANGE m. It passes through up
##            to RAIL_MAX_SOIL × charge m of soil (measured on the planets' density fields:
##            rail_beam.gd soil_profile, so it works through rock and far from any collision) and
##            through every damageable on its way: bots, players, structures, torpedoes (own team
##            skipped). Targets: physics rays (characters / structures / vehicles, repeated with
##            exclusions) + a scan of the bots, players and torpedoes whose upright axis passes within
##            RAIL_HIT_RADIUS of the line (underground, far side). Damage of the n-th target:
##            RAIL_DAMAGE × charge × (1 - RAIL_TARGET_FALLOFF)^n × (1 - RAIL_SOIL_FALLOFF × soil m
##            before it), helmet × RAIL_HEAD_MULT, through gun_feel.gd body_hit (hit point, hit
##            reactions, markers, kill feed: "Raylı"). The beam look: rail_beam.gd (core, sheath, a
##            corkscrew that lingers ~1 s, glowing entry / exit scorches, exit spray, lights). The bore:
##            rail_beam.gd bore() on the host / single player.
##   After    cooldown RAIL_COOLDOWN × charge (≥ 0.35 s): a vent hiss, a ready blip.
##   Scope    RMB: RAIL_ZOOM× (the view model hides, scripts/items/rail_scope.gd draws the eyepiece,
##            the soil along the aim against what this charge reaches, the distance to the surface).
##            Scoped AND charging, every enemy bot / player within RAIL_XRAY_RANGE m in a
##            RAIL_XRAY_CONE_DEG cone shows THROUGH the soil (tunnel_scanner.gd's x-ray overlay, in
##            magenta) with a bracket and "12 m · toprak 4 m" (green: this charge gets through).
##   Ammo     magazine RAIL_MAG, R reloads (a power cell under the receiver), "ammo_rail" at
##            Game.AMMO_COST (RAIL_AMMO_COST m³ a round).
##   Sound    the crack + an electric tail + body on the Weapons bus; in vacuum only the suit-borne
##            thump. The charge whine follows the charge (VacSuit bus in vacuum).
## Multiplayer: rail_fired(from, to, charge) for every shot (from = the muzzle, to = where the beam
## ended): replay it on the other machine with RailBeam.replay(scene, from, to, charge, team) (the
## look, and the bore there when that machine is the host). Hits go through Game.damage_target as
## usual (a client's become claims). Game.shot_fired fires too (weapon_base.gd).

signal rail_fired(from: Vector3, to: Vector3, charge: float)

const Balance := preload("res://scripts/war/balance.gd")
const RailBeam := preload("res://scripts/items/rail_beam.gd")
const RailScope := preload("res://scripts/items/rail_scope.gd")
const TunnelScanner := preload("res://scripts/items/tunnel_scanner.gd")

const BORE_Y := 0.074
const SCOPE_Y := 0.128
const EYEPIECE_Z := 0.112
const CELL_REST := Vector3(0.0, 0.0, -0.13)
const CELL_AXIS := Vector3(0.0, -0.993, -0.12)
const CYAN := Color(0.38, 0.95, 1.0)
const VIOLET := Color(0.72, 0.36, 1.0)
const XRAY_COL := Color(1.0, 0.35, 0.82)
const WEIGHT := 0.9                       # mobility factor while carried (the loadout applies it)
const XRAY_MAX := 6                       # enemies outlined at once (the nearest)
const XRAY_SOIL_MAX := 4                  # ...of which this many get a soil measurement

static var _xray_shader: Shader

# --- State (HUD, multiplayer) ----------------------------------------------------------------------
var panel_name := "Delici Raylı Tüfek"
var handling_len := 1.08                  # handling.gd: wall pull-back length
var charge := 0.0                         # 0..1 while LMB is held
var charging := false
var scoped := false
var cool := 0.0                           # s left of the cooldown after a shot
var cool_total := 0.0
var soil_ahead := -1.0                    # m of soil along the aim (scoped readout; -1 unknown)
var surface_ahead := -1.0                 # m to where the beam would enter the ground

var _shot_charge := 1.0
var _full := false
var _discharge := 0.0                     # coil flash after a shot
var _vent_t := -1.0
var _mag_s := 1.0
var _vm_hidden := false
var _aim_t := 0.0
var _xray := {}                           # instance id -> {node, meshes, mats, k, want, soil, dist}
var _xray_t := 0.0
var _scope
var _hum: AudioStreamPlayer
var _light: OmniLight3D
var _rail_mat: ShaderMaterial
var _coil_mat: ShaderMaterial
var _cap_mat: ShaderMaterial
var _cell_mat: ShaderMaterial
var _seg_mats: Array = []
var _mag: Node3D
var _mag_grab: Node3D
var grip_point: Node3D                    # hand anchors (build_model): pistol grip, trigger
var trigger_point: Node3D


func _init() -> void:
	item_id = "rail"
	item_name = "Delici Raylı Tüfek"
	item_desc = "Sol tık basılı: şarj et, bırak: ateş — ışın toprağı deler · Sağ tık: 2,5× dürbün (şarj ederken düşmanlar toprağın içinden görünür) · R: şarjör / şarjı boşalt · Orta tık basılı: nişangah eklentisi."
	icon = "rail"
	slot_key = 0                          # the loadout (Silahlık) decides its key
	short_name = "Raylı"
	accent = CYAN.lerp(VIOLET, 0.35)
	ammo_id = "ammo_rail"
	ammo_title = "RAY MERMİSİ · DELİCİ"
	base_mag = Balance.RAIL_MAG
	reload_kind = "mag"
	reload_time = Balance.RAIL_RELOAD
	reload_empty_time = Balance.RAIL_RELOAD + 0.5
	fire_rate = 4.0                       # (the cooldown after a shot is set in fire())
	sight_rear = Vector3(0.0, SCOPE_Y, EYEPIECE_Z)
	ads_eye = Vector3(0.0, 0.0, -0.09)
	hip_pos = Vector3(0.17, -0.22, -0.36)
	hip_bore_y = BORE_Y
	hip_converge = 16.0
	sprint_pos = Vector3(0.14, -0.17, -0.38)
	sprint_rot = Vector3(-0.22, 0.6, 0.32)
	reload_pos = Vector3(0.12, -0.19, -0.4)
	reload_rot = Vector3(0.22, 0.25, 0.4)
	recoil_pivot = Vector3(0.0, 0.05, 0.28)
	aim_speed = 0.45
	spread_hip = 0.012
	spread_ads = 0.0
	bloom_add = 0.0
	bloom_max = 0.0
	first_shot_k = 1.0
	kick_pitch = 0.11
	kick_yaw = 0.02
	kick_roll = 0.03
	gun_kick = 14.0
	shake_amt = 0.8
	fov_punch_amt = -5.0
	noise_radius = 120.0
	crosshair_style = "ticks"
	hit_big = 0.9
	hit_punch = 2.2
	muzzle_energy = 12.0
	punch_db = -1.0
	recoil_climb = 0.0
	recoil_h = PackedFloat32Array([0.5, -0.45, 0.3, -0.6])
	recoil_hold = 0.1
	recoil_recover = 0.6
	head_mult = Balance.RAIL_HEAD_MULT
	kill_launch = 7.0
	ads_k = 80.0
	ads_c = 12.5
	draw_time = 0.8
	holster_time = 0.5


func _ready() -> void:
	super._ready()
	RailBeam.prewarm()
	_hum = AudioStreamPlayer.new()
	_hum.bus = Rifle._weapons_bus()
	add_child(_hum)
	_light = OmniLight3D.new()
	_light.top_level = true
	_light.light_color = VIOLET.lerp(CYAN, 0.35)
	_light.omni_range = 3.2
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	_light.visible = false
	add_child(_light)
	_scope = RailScope.new()
	_scope.weapon = self
	add_child(_scope)


func _exit_tree() -> void:
	_drop_all_xray()
	super._exit_tree()


func _stream(name: String) -> AudioStream:
	var s := RailBeam.stream(name)
	if s != null:
		return s
	return super._stream(name)


func mode_text() -> String:
	if charging:
		return "%d%%" % int(charge * 100.0)
	return ""


func reload_label() -> String:
	return "HÜCRE DEĞİŞİYOR"


## m of soil the current charge goes through (the scope's ERİŞİM).
func reach() -> float:
	return Balance.RAIL_MAX_SOIL * maxf(charge, Balance.RAIL_MIN_CHARGE)


## 0..1 how far into the eyepiece (rail_scope.gd).
func scope_k() -> float:
	if player == null or not equipped or not active or player.vehicle != null or not _has_scope():
		return 0.0
	return smoothstep(0.72, 0.97, clampf(ads, 0.0, 1.0))


## The gun's own scope is on (no reflex / holo attachment in its place, attachments.gd): the 2.5×,
## the eyepiece readouts and the x-ray.
func _has_scope() -> bool:
	return att_kit.optic() == ""


## The enemies the x-ray shows right now: [{node, k, soil, dist}] (rail_scope.gd brackets).
func xray_marks() -> Array:
	var out: Array = []
	for id in _xray:
		var e: Dictionary = _xray[id]
		if float(e["k"]) > 0.02 and is_instance_valid(e["node"]):
			out.append(e)
	return out


func _on_state_changed() -> void:
	super._on_state_changed()
	if not active or not equipped:
		_cancel_charge(false)
		_drop_all_xray()
		_set_vm_hidden(false)
		if _light != null:
			_light.visible = false


## R while charging vents the charge instead of reloading.
func reload() -> void:
	if charging:
		_cancel_charge(true)
		return
	super.reload()


func _sprint_allowed() -> bool:
	return not charging


func _idle_tick(_delta: float) -> void:
	if charging:
		_cancel_charge(false)


# =================================================================================================
# Charge and fire
# =================================================================================================

func _trigger(trig: bool, pressed: bool, _alt: bool, delta: float) -> void:
	if reloading or not player.viewmodel.is_raised():
		if charging:
			_cancel_charge(false)
		return
	if charging:
		if trig and mag > 0:
			charge = minf(charge + delta / maxf(Balance.RAIL_CHARGE_TIME, 0.05), 1.0)
			if charge >= 1.0 and not _full:
				_full = true
				_play("rail_ready", -14.0, 1.35)
				_rk_vel += Vector4(0.25, 0.0, 0.0, -0.1)
			return
		# Still held but blocked (wall pull-back, inspect): keep the charge, do not fire.
		var held := debug_trigger or (not debug_ignore_input and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
				and Input.is_action_pressed("tool_use"))
		if held and mag > 0:
			return
		if charge >= Balance.RAIL_MIN_CHARGE and mag > 0:
			fire()
		else:
			_cancel_charge(true)
		return
	if _cooldown > 0.0 or _since_sprint < sprint_to_fire:
		return
	if not trig:
		return
	if mag <= 0:
		if pressed:
			_dry_fire()
		return
	charging = true
	_full = false
	charge = 0.0
	_play("selector", -16.0, 1.4)
	_rk_vel += Vector4(-0.3, 0.0, 0.0, 0.08)


## The charge let go: a fizzle and a vent when `audible` (released too early, R).
func _cancel_charge(audible: bool) -> void:
	if not charging and charge <= 0.0:
		return
	var had := charge
	charging = false
	charge = 0.0
	_full = false
	if audible and had > 0.05:
		_play("rail_fizzle", -10.0, randf_range(0.95, 1.05))
		_play("rail_vent", -18.0, 1.2)
		_discharge = maxf(_discharge, 0.3 * had)


func fire() -> void:
	var k := clampf(charge, 0.0, 1.0)
	_shot_charge = k
	var e := _smooth(clampf(ads, 0.0, 1.0))
	# The kick, shake and punch follow the charge (a small charge is a small shot).
	kick_pitch = lerpf(0.035, 0.11, k)
	kick_yaw = lerpf(0.008, 0.02, k)
	gun_kick = lerpf(5.0, 15.0, k)
	shake_amt = lerpf(0.25, 0.85, k)
	fov_punch_amt = lerpf(-1.5, -5.0, k) * lerpf(1.0, 0.25, e)
	charging = false
	charge = 0.0
	_full = false
	super.fire()
	_cooldown = maxf(Balance.RAIL_COOLDOWN * k, 0.35)
	cool = _cooldown
	cool_total = _cooldown
	_discharge = 1.0
	_vent_t = 0.22
	if player.has_method("add_trauma"):
		player.add_trauma(0.05 + 0.15 * k)
	ScreenPunch.kick(0.2 + 0.5 * k)            # the small screen kick (chromatic split, weapon_base.gd)


func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var k := _shot_charge
	var dir := _spread_dir(fwd, cb, current_spread())
	var shot := _trace(eye, dir, k)
	var segs: Array = shot["segs"]
	var my_team := Game.team_of(player)
	var n := 0
	for h: Dictionary in shot["targets"]:
		var t := float(h["t"])
		var soil := RailBeam.soil_before(segs, t)
		var dmg := Balance.RAIL_DAMAGE * k * pow(1.0 - Balance.RAIL_TARGET_FALLOFF, float(n)) \
				* maxf(1.0 - Balance.RAIL_SOIL_FALLOFF * soil, 0.05)
		if dmg < 1.0:
			break
		var node: Node = h["node"]
		if not is_instance_valid(node):
			continue
		GunFeel.body_hit(self, node, h["point"], -dir, dir, {"dmg": dmg, "head": head_mult, "push": 2.5 * k,
				"launch": kill_launch * k, "big": 0.45 + 0.5 * k, "name": short_name, "heavy": k > 0.5, "team": my_team})
		hits += 1
		n += 1
	var to: Vector3 = shot["end"]
	last_impact = to
	var scene: Node = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
	RailBeam.spawn(scene, muzzle, to, k, segs, eye, dir, false)
	RailBeam.bore(segs, eye, dir, my_team)
	rail_fired.emit(muzzle, to, k)


## The beam from `eye` along `dir` at charge k: {"end", "segs" (soil intervals up to the end),
## "targets": [{node, t, point}] sorted along the beam}.
func _trace(eye: Vector3, dir: Vector3, k: float) -> Dictionary:
	var rng := Balance.RAIL_RANGE
	var segs := RailBeam.soil_profile(eye, dir, rng)
	var budget := Balance.RAIL_MAX_SOIL * k
	var t_end := rng
	var acc := 0.0
	var kept: Array = []
	for g in segs:
		var a := float(g[0])
		var b := float(g[1])
		if acc + (b - a) >= budget:
			t_end = a + (budget - acc)
			kept.append([a, t_end])
			break
		acc += b - a
		kept.append([a, b])
	var found := {}
	var end := eye + dir * t_end
	# Physics: characters, structures, vehicles (no terrain: the soil is the density march above).
	var space := get_world_3d().direct_space_state
	var ex: Array = [player.get_rid()]
	for i in 12:
		var q := PhysicsRayQueryParameters3D.create(eye, end, Game.LAYER_PLAYER | Game.LAYER_SHIP | Game.LAYER_VEHICLE, ex)
		var h := space.intersect_ray(q)
		if h.is_empty():
			break
		ex.append(h["rid"])
		var dn := Game.damageable_of(h["collider"])
		if dn == null or not _target_ok(dn):
			continue
		var t := eye.distance_to(h["position"])
		var id := dn.get_instance_id()
		if not found.has(id) or t < float(found[id]["t"]):
			found[id] = {"node": dn, "t": t, "point": h["position"]}
	# Scan: bodies whose upright axis (torpedoes: their length) passes close to the line, wherever
	# they are (underground, out of collision range).
	for grp in ["war_ai", "net_player", "war_torpedo"]:
		for nd in get_tree().get_nodes_in_group(grp):
			if not (nd is Node3D) or found.has(nd.get_instance_id()) or not _target_ok(nd):
				continue
			var n3 := nd as Node3D
			var a := n3.global_position
			var b := a
			if grp == "war_torpedo":
				var z := n3.global_transform.basis.z.normalized()
				a = n3.global_position - z * 0.65
				b = n3.global_position + z * 0.65
			else:
				var up := n3.global_transform.basis.y.normalized()
				a = n3.global_position + up * 0.12
				b = n3.global_position + up * 1.72
			var r := _seg_seg(eye, end, a, b)
			if float(r[0]) <= Balance.RAIL_HIT_RADIUS:
				found[nd.get_instance_id()] = {"node": nd, "t": float(r[1]), "point": r[2]}
	var targets: Array = found.values()
	targets.sort_custom(func(x, y): return float(x["t"]) < float(y["t"]))
	return {"end": end, "segs": kept, "targets": targets}


## May the beam hurt n? (Alive, not us, not our own side's structures / players / torpedoes.)
func _target_ok(n: Node) -> bool:
	if n == player or n.is_in_group("war_core"):
		return false
	if n.has_method("is_dead") and bool(n.call("is_dead")):
		return false
	var my_team := Game.team_of(player)
	if Game.team_of(n) == my_team and (n.is_in_group("war_structure") or n.is_in_group("net_player")
			or n.is_in_group("war_torpedo") or n.is_in_group("skiff")):
		return false
	return true


## Closest approach of segments p1-q1 and p2-q2: [distance, t along the first (m from p1), point on it].
static func _seg_seg(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> Array:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-8:
		return [p1.distance_to(p2), 0.0, p1]
	var c := d1.dot(r)
	if e <= 1e-8:
		s = clampf(-c / a, 0.0, 1.0)
	else:
		var b := d1.dot(d2)
		var den := a * e - b * b
		s = clampf((b * f - c * e) / den, 0.0, 1.0) if den > 1e-8 else 0.0
		t = (b * s + f) / e
		if t < 0.0:
			t = 0.0
			s = clampf(-c / a, 0.0, 1.0)
		elif t > 1.0:
			t = 1.0
			s = clampf((b - c) / a, 0.0, 1.0)
	var c1 := p1 + d1 * s
	var c2 := p2 + d2 * t
	return [c1.distance_to(c2), sqrt(a) * s, c1]


## Scoped the view model is hidden: the beam starts just under the eye instead.
func muzzle_world() -> Vector3:
	if ads > 0.85 and player != null and _vm_hidden:
		var cam: Camera3D = player.camera
		var cb := cam.global_transform.basis
		return cam.global_position - cb.z * 0.7 - cb.y * 0.08 + cb.x * 0.035
	return super.muzzle_world()


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, _cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(0.9 + 0.7 * _shot_charge)
	fx.muzzle_light(muzzle + fwd * 0.5, VIOLET.lerp(CYAN, 0.3), muzzle_energy * (0.4 + 0.6 * _shot_charge), 0.08, 14.0)
	fx.muzzle_smoke(muzzle + fwd * 0.1, fwd, up)


func _hit_damage(_p: Vector3, _ammo: int) -> float:
	return Balance.RAIL_DAMAGE


func _fire_sound() -> void:
	var k := _shot_charge
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		# Vacuum: no crack, only the blow through the suit.
		_play("boom_body", lerpf(-9.0, -3.0, k), randf_range(0.95, 1.05) * lerpf(1.2, 0.92, k), true)
		_play("thump", lerpf(-8.0, -3.0, k), 0.85, true)
		_shot_body(space, 0.9, -80.0)
		return
	_play("rail_crack", lerpf(-9.0, 0.0, k), randf_range(0.96, 1.04) * lerpf(1.25, 1.0, k), true)
	_play("rail_tail", lerpf(-18.0, -5.0, k), randf_range(0.95, 1.05), true)
	_play("boom_body", lerpf(-12.0, -5.0, k), 1.15, true)
	_shot_body(space, 1.05, lerpf(-18.0, -9.0, k))
	if space == 2:
		_play("tail", lerpf(-20.0, -12.0, k), 1.25, true)
	elif space == 1:
		_play("tail", -16.0, 1.1, true, 0.4)


# =================================================================================================
# Per frame: charge look and sound, cooldown, scope, x-ray
# =================================================================================================

func _tick(delta: float, on: bool) -> void:
	if cool > 0.0:
		cool = maxf(cool - delta, 0.0)
		if cool <= 0.0 and cool_total >= 0.5 and on:
			_play("rail_ready", -15.0, 1.0)
	if _vent_t > 0.0:
		_vent_t -= delta
		if _vent_t <= 0.0:
			_play("rail_vent", lerpf(-20.0, -11.0, _shot_charge), randf_range(0.95, 1.05))
	_discharge = maxf(_discharge - delta * 2.6, 0.0)
	_update_hum(delta)
	_update_glow(on)
	# Tremble while charging (the viewmodel kicks a little, more near full).
	if charging and on:
		var tk := charge * charge * (1.6 if _full else 1.0)
		_rk_vel += Vector4(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-0.3, 0.3)) * tk * 0.15
	_mag_s = lerpf(_mag_s, Balance.RAIL_ZOOM, 1.0 - exp(-10.0 * delta))
	var e := clampf(ads, 0.0, 1.0)
	scoped = on and e > 0.88 and _has_scope()
	_set_vm_hidden(on and e > 0.9 and _has_scope())
	if on and scoped:
		_aim_t -= delta
		if _aim_t <= 0.0:
			_aim_t = 0.2
			_measure_aim()
	else:
		soil_ahead = -1.0
		surface_ahead = -1.0
	_update_xray(delta, on)


func _update_hum(_delta: float) -> void:
	if _hum == null:
		return
	var want := charging and charge > 0.0
	if want:
		if not _hum.playing:
			var st := RailBeam.stream("rail_hum")
			if st == null:
				return
			_hum.stream = st
			_hum.play()
		_hum.bus = "VacSuit" if GunFeel.in_vacuum() else Rifle._weapons_bus()
		var flutter := (sin(_t * 31.0) * 0.012 + sin(_t * 13.0) * 0.008) if _full else 0.0
		_hum.pitch_scale = 0.55 + 1.95 * charge + flutter
		_hum.volume_db = lerpf(-24.0, -7.0, charge) + (2.0 * sin(_t * 22.0) if _full else 0.0)
	elif _hum.playing:
		_hum.volume_db -= 4.0
		if _hum.volume_db < -40.0:
			_hum.stop()


## Coils and the rail channel glow with the charge, flash on the shot; the charge bar on the side;
## a small violet light at the muzzle.
func _update_glow(on: bool) -> void:
	var k := charge
	var g := 0.25 + 7.0 * pow(k, 1.5) + 11.0 * _discharge
	if _rail_mat != null:
		_rail_mat.set_shader_parameter("energy", g * (1.0 + (0.25 * sin(_t * 40.0) if _full else 0.0)))
		_rail_mat.set_shader_parameter("flicker", 0.35 * k)
		_rail_mat.set_shader_parameter("color", CYAN.lerp(Color(0.95, 0.9, 1.0), _discharge))
	if _coil_mat != null:
		_coil_mat.set_shader_parameter("energy", 0.3 + 5.0 * k + 8.0 * _discharge)
		_coil_mat.set_shader_parameter("flicker", 0.25 * k)
	if _cap_mat != null:
		_cap_mat.set_shader_parameter("energy", 0.5 + 3.5 * k + (1.5 if cool <= 0.0 and mag > 0 else 0.0))
		_cap_mat.set_shader_parameter("color", VIOLET.lerp(CYAN, 0.5 + 0.5 * k) if cool <= 0.0 else Color(1.0, 0.45, 0.25))
	for i in _seg_mats.size():
		var lit := k * float(_seg_mats.size()) > float(i) + 0.05
		var m: ShaderMaterial = _seg_mats[i]
		m.set_shader_parameter("energy", (4.0 if lit else 0.25) + (1.5 * sin(_t * 20.0) if _full and lit else 0.0))
	var le := 2.2 * k + 5.0 * _discharge
	_light.visible = on and le > 0.02
	if _light.visible and player != null:
		_light.global_position = muzzle_world() - player.camera.global_transform.basis.z * 0.15
		_light.light_energy = le


## Soil along the aim (scope readout): total within RAIL_RANGE, and where the beam would enter.
func _measure_aim() -> void:
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var segs := RailBeam.soil_profile(eye, fwd, Balance.RAIL_RANGE)
	soil_ahead = RailBeam.soil_total(segs)
	surface_ahead = float(segs[0][0]) if not segs.is_empty() else -1.0


## Hold the gun a touch tighter while charging.
func _pose_extra() -> Transform3D:
	var c := charge
	return Transform3D(Basis.from_euler(Vector3(0.015 * c, 0.0, -0.02 * c)), Vector3(-0.004 * c, 0.003 * c, 0.016 * c))


func _cam_fov(e: float) -> float:
	if not _has_scope():
		return super._cam_fov(e)                 # a reflex / holo: the attachment's ADS FOV
	var base: float = Settings.fov
	var t1 := _smooth(e / 0.6)
	var pre := base - 6.0 * t1
	var t2 := _smooth((e - 0.6) / 0.4)
	var zt := tan(deg_to_rad(base) * 0.5) / maxf(_mag_s, 1.0)
	var pt := tan(deg_to_rad(pre) * 0.5)
	return rad_to_deg(2.0 * atan(lerpf(pt, zt, t2)))


func _cam_look(e: float) -> float:
	if not _has_scope():
		return super._cam_look(e)
	var f := _cam_fov(e)
	return clampf(tan(deg_to_rad(f) * 0.5) / tan(deg_to_rad(Settings.fov) * 0.5), 0.15, 1.0)


func _set_vm_hidden(h: bool) -> void:
	if h == _vm_hidden or player == null:
		return
	_vm_hidden = h
	var vm = player.get("viewmodel")
	if vm == null:
		return
	if h:
		vm.visible = false
	elif not player.is_ragdolled() and not (player.has_method("is_dead") and player.is_dead()):
		vm.visible = true


# --- X-ray (scoped + charging) ---------------------------------------------------------------------

func _update_xray(delta: float, on: bool) -> void:
	var live := on and scoped and charging
	if live:
		_xray_t -= delta
		if _xray_t <= 0.0:
			_xray_t = 0.2
			_scan_xray()
	for id in _xray.keys():
		var e: Dictionary = _xray[id]
		var n = e["node"]
		var valid: bool = is_instance_valid(n) and not (n.has_method("is_dead") and bool(n.call("is_dead")))
		var want: bool = live and valid and bool(e["want"])
		e["k"] = move_toward(float(e["k"]), 1.0 if want else 0.0, delta * (6.0 if want else 4.0))
		var k := float(e["k"])
		for m: ShaderMaterial in e["mats"]:
			m.set_shader_parameter("k", k)
		if k <= 0.0 and not want:
			_drop_xray(e)
			_xray.erase(id)


## Enemy bots / players within RAIL_XRAY_RANGE in the aim cone: outlined, the nearest measured.
func _scan_xray() -> void:
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var cone := cos(deg_to_rad(Balance.RAIL_XRAY_CONE_DEG))
	var my_team := Game.team_of(player)
	var cands: Array = []
	for grp in ["war_ai", "net_player"]:
		for n in get_tree().get_nodes_in_group(grp):
			if not (n is Node3D) or n == player:
				continue
			var tm := Game.team_of(n)
			if tm == "" or tm == my_team:
				continue
			if n.has_method("is_dead") and bool(n.call("is_dead")):
				continue
			var c: Vector3 = (n as Node3D).global_position + (n as Node3D).global_transform.basis.y * 1.0
			var to := c - eye
			var d := to.length()
			if d > Balance.RAIL_XRAY_RANGE or d < 0.5 or fwd.dot(to / d) < cone:
				continue
			cands.append([d, n, c])
	cands.sort_custom(func(x, y): return float(x[0]) < float(y[0]))
	for id in _xray:
		_xray[id]["want"] = false
	for i in mini(cands.size(), XRAY_MAX):
		var n: Node3D = cands[i][1]
		var id := n.get_instance_id()
		if not _xray.has(id):
			_xray[id] = _make_xray(n)
		var e: Dictionary = _xray[id]
		e["want"] = true
		e["dist"] = float(cands[i][0])
		if i < XRAY_SOIL_MAX:
			e["soil"] = RailBeam.soil_between(eye, cands[i][2])


func _make_xray(n: Node3D) -> Dictionary:
	if _xray_shader == null:
		_xray_shader = Shader.new()
		_xray_shader.code = TunnelScanner.XRAY_SHADER
	var e := {"node": n, "meshes": [], "mats": [], "k": 0.0, "want": true, "soil": -1.0, "dist": 0.0}
	var a = n.get("astronaut")
	var root: Node = a if a is Node else n
	for c in root.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi == null or mi.skin == null or mi.material_overlay != null:
			continue                       # (another overlay, e.g. the scanner's, already shows it)
		var m := ShaderMaterial.new()
		m.shader = _xray_shader
		m.set_shader_parameter("color", XRAY_COL)
		m.set_shader_parameter("k", 0.0)
		mi.material_overlay = m
		(e["meshes"] as Array).append(mi)
		(e["mats"] as Array).append(m)
	return e


func _drop_xray(e: Dictionary) -> void:
	var meshes: Array = e["meshes"]
	var mats: Array = e["mats"]
	for i in meshes.size():
		var mi = meshes[i]
		if is_instance_valid(mi) and (mi as MeshInstance3D).material_overlay == mats[i]:
			(mi as MeshInstance3D).material_overlay = null
	meshes.clear()
	mats.clear()


func _drop_all_xray() -> void:
	for id in _xray:
		_drop_xray(_xray[id])
	_xray.clear()


# =================================================================================================
# Reload (a power cell under the receiver) and the model animation
# =================================================================================================

func _reload_events(u: float) -> void:
	var marks := [0.05, 0.14, 0.22, 0.6, 0.68, 0.82]
	while _reload_ev < marks.size() and u >= float(marks[_reload_ev]):
		match _reload_ev:
			0:
				_play("cloth", -16.0, randf_range(0.9, 1.1))
			1:
				_play("mag_release", -9.0, 1.1)
				_play("rail_vent", -20.0, 1.4)
			2:
				_play("mag_out", -8.0, 1.05)
			3:
				_play("mag_in", -6.0, 1.0)
				_rk_vel.w += 0.25
			4:
				_play("mag_slap", -5.0, 1.05)
				_rk_vel.x += 0.6
			5:
				_play("rail_ready", -16.0, 0.85)
		_reload_ev += 1


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _mag == null:
		return
	var u := reload_progress() if reloading else 0.0
	var drop := 0.0
	var vis := true
	var slap := 0.0
	if reloading:
		left_reach_w = _seg(u, 0.03, 0.13) * (1.0 - _seg(u, 0.74, 0.84))
		drop = lerpf(0.0, 0.05, _seg(u, 0.13, 0.22)) + lerpf(0.0, 0.4, _seg(u, 0.22, 0.38))
		if u > 0.44:
			drop = lerpf(0.45, 0.03, _seg(u, 0.46, 0.6)) * (1.0 - _seg(u, 0.6, 0.67))
		vis = u < 0.4 or u > 0.47
		slap = sin(clampf((u - 0.67) / 0.07, 0.0, 1.0) * PI)
		if left_reach_w > 0.0 and player != null:
			var cam_inv: Transform3D = player.camera.global_transform.affine_inverse()
			left_reach = cam_inv * _mag_grab.global_position + Vector3(0.0, 0.03 * slap, 0.0)
			left_reach_elbow = Vector3(-0.3, -0.85, 0.45)
	else:
		left_reach_w = 0.0
	_mag.position = CELL_REST + CELL_AXIS * drop
	var tumble := clampf((drop - 0.1) / 0.3, 0.0, 1.0)
	_mag.rotation = Vector3(tumble * 0.5, 0.0, tumble * 0.35)
	_mag.visible = vis
	if _cell_mat != null:
		_cell_mat.set_shader_parameter("energy", 2.4 if mag > 0 else 0.3)
	_gun.transform = Transform3D(Basis.from_euler(Vector3(slap * 0.025, 0.0, 0.0)), Vector3(0.0, slap * 0.005, 0.0))


# =================================================================================================
# Model
# =================================================================================================

## First-person model, the arsenal's white / orange / gunmetal kit: pistol grip and a skeleton stock,
## a white receiver with heat-sink fins and a five-segment charge bar on the left, a power cell under
## it, a capacitor bank (a dark housing with three white capacitors a side and glowing bands) over the
## fore-grip, then two long exposed steel rails with a glowing channel between them, held by orange
## yokes, wound with copper coils (glow lines) between them, a forked emitter at the muzzle; a scope
## with a violet-coated objective on top.
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	var rubber := VM.rubber()
	var gunm := VM.mat(Color(0.12, 0.13, 0.14), 0.3, 0.8)
	var copper := VM.mat(Color(0.74, 0.43, 0.22), 0.32, 0.9)
	var black := VM.mat(Color(0.03, 0.03, 0.035), 0.6, 0.2)
	_rail_mat = VM.glow(CYAN, 0.25)
	_coil_mat = VM.glow(VIOLET, 0.3)
	_cap_mat = VM.glow(VIOLET.lerp(CYAN, 0.5), 0.6)
	_cell_mat = VM.glow(VIOLET, 2.4)
	_seg_mats.clear()
	var by := BORE_Y
	# Grip, trigger and guard.
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.02, -0.02), Vector3(0, -0.02, -0.075), 0.0045, steel)
	VM.capsule(_gun, Vector3(0, -0.02, -0.075), Vector3(0, 0.012, -0.088), 0.0045, steel)
	# Receiver: white body, dark top cover, orange side bands, heat-sink fins.
	VM.soft_box(_gun, Vector3(0, 0.044, -0.075), Vector3(0.064, 0.068, 0.33), 0.014, white)
	VM.box(_gun, Vector3(0, 0.079, -0.075), Vector3(0.05, 0.006, 0.3), dark)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0325 * sx, 0.05, -0.1), Vector3(0.003, 0.016, 0.24), orange)
		for i in 7:
			VM.box(_gun, Vector3(0.034 * sx, 0.026, 0.05 - i * 0.02), Vector3(0.006, 0.018, 0.007), dark)
	# Charge bar on the left side (5 segments, lit with the charge).
	VM.box(_gun, Vector3(-0.0335, 0.066, -0.13), Vector3(0.003, 0.016, 0.115), black)
	for i in 5:
		var sm := VM.glow(CYAN.lerp(VIOLET, float(i) / 4.0), 0.25)
		_seg_mats.append(sm)
		VM.box(_gun, Vector3(-0.0352, 0.066, -0.084 - i * 0.022), Vector3(0.0015, 0.009, 0.017), sm)
	# Skeleton stock.
	VM.soft_box(_gun, Vector3(0, 0.062, 0.19), Vector3(0.04, 0.03, 0.2), 0.011, white)
	VM.soft_box(_gun, Vector3(0, 0.083, 0.2), Vector3(0.034, 0.02, 0.12), 0.009, orange)
	VM.box(_gun, Vector3(0, 0.095, 0.2), Vector3(0.026, 0.004, 0.1), rubber)
	VM.soft_box(_gun, Vector3(0, 0.03, 0.285), Vector3(0.042, 0.13, 0.034), 0.011, white)
	VM.soft_box(_gun, Vector3(0, 0.03, 0.306), Vector3(0.044, 0.136, 0.012), 0.005, rubber)
	VM.capsule(_gun, Vector3(0, 0.016, 0.08), Vector3(0, -0.024, 0.275), 0.0105, dark)
	# Power cell (the magazine; the left hand swaps it on reload).
	_mag = VM.node(_gun, CELL_REST)
	var mb := Basis(Vector3.RIGHT, 0.1)
	VM.soft_box(_mag, Vector3(0, -0.02, 0.0), Vector3(0.034, 0.05, 0.06), 0.008, dark, mb)
	VM.box(_mag, mb * Vector3(0, -0.047, 0.0), Vector3(0.036, 0.01, 0.064), orange, mb)
	for sx in [-1.0, 1.0]:
		VM.box(_mag, mb * Vector3(0.0175 * sx, -0.018, 0.0), Vector3(0.002, 0.03, 0.026), _cell_mat, mb)
	_mag_grab = VM.node(_mag, mb * Vector3(-0.03, -0.09, 0.02))
	# Capacitor bank over the fore-grip: housing, three capacitors a side with glowing bands.
	VM.soft_box(_gun, Vector3(0, 0.03, -0.37), Vector3(0.06, 0.036, 0.22), 0.008, dark)
	for sx in [-1.0, 1.0]:
		for j in 3:
			var cy := 0.03
			var cz0 := -0.275 - j * 0.066
			VM.seg(_gun, Vector3(0.036 * sx, cy, cz0), Vector3(0.036 * sx, cy, cz0 - 0.056), 0.011, 0.011, white, 14)
			VM.ring(_gun, Vector3(0.036 * sx, cy, cz0 - 0.028), Vector3.FORWARD, 0.0118, 0.002, _cap_mat)
			VM.seg(_gun, Vector3(0.036 * sx, cy, cz0 - 0.056), Vector3(0.036 * sx, cy, cz0 - 0.06), 0.009, 0.009, orange, 14)
		VM.capsule(_gun, Vector3(0.03 * sx, 0.046, -0.47), Vector3(0.026 * sx, by - 0.012, -0.55), 0.004, rubber, 8)
	VM.soft_box(_gun, Vector3(0, 0.006, -0.4), Vector3(0.05, 0.014, 0.1), 0.006, rubber)
	# Hand anchors (the hands rig): the right hand holds the pistol grip at the model origin (VM.grip,
	# "PistolGrip"), the index finger on "Trigger"; the support hand under the capacitor bank on the
	# rubber fore-grip pad ("LeftGrip" = item.left_grip, the same basis as the rifle / sniper).
	grip_point = VM.node(_gun, Vector3.ZERO)
	grip_point.name = "PistolGrip"
	trigger_point = VM.node(_gun, Vector3(0, 0.0, -0.034))
	trigger_point.name = "Trigger"
	left_grip = VM.node(_gun, Vector3(0, -0.006, -0.4), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	left_grip.name = "LeftGrip"
	# The rails: steel bars, dark outer plates, the glowing channel faces, a spine under them.
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0175 * sx, by, -0.585), Vector3(0.011, 0.034, 0.69), steel)
		VM.box(_gun, Vector3(0.0235 * sx, by, -0.585), Vector3(0.002, 0.026, 0.66), gunm)
		VM.box(_gun, Vector3(0.0118 * sx, by, -0.585), Vector3(0.0015, 0.014, 0.68), _rail_mat)
	VM.box(_gun, Vector3(0, by - 0.021, -0.56), Vector3(0.03, 0.006, 0.62), dark)
	# Yokes holding the rails.
	for z in [-0.27, -0.45, -0.63, -0.81]:
		VM.box(_gun, Vector3(0, by + 0.023, z), Vector3(0.056, 0.009, 0.026), dark)
		VM.box(_gun, Vector3(0, by - 0.026, z), Vector3(0.056, 0.009, 0.026), dark)
		for sx in [-1.0, 1.0]:
			VM.box(_gun, Vector3(0.0285 * sx, by, z), Vector3(0.007, 0.058, 0.026), orange)
	# Copper coils between the yokes, a glow line through each winding.
	for zc in [-0.36, -0.54, -0.72]:
		for j in 4:
			VM.ring(_gun, Vector3(0, by, zc - 0.024 + j * 0.016), Vector3.FORWARD, 0.031, 0.0065, copper)
		VM.ring(_gun, Vector3(0, by, zc), Vector3.FORWARD, 0.0322, 0.0016, _coil_mat)
	# Forked emitter at the muzzle.
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0185 * sx, by, -0.945), Vector3(0.008, 0.026, 0.032), gunm, Basis(Vector3.UP, 0.14 * sx))
	VM.ring(_gun, Vector3(0, by, -0.928), Vector3.FORWARD, 0.026, 0.004, dark)
	VM.ring(_gun, Vector3(0, by, -0.935), Vector3.FORWARD, 0.015, 0.003, _rail_mat)
	_muzzle = VM.node(_gun, Vector3(0, by, -0.965))
	# Scope: mounts, tube, eyepiece, objective bell with an orange ring, turret, a side readout (its
	# own node: a fitted reflex / holo replaces it, and with it the zoom and the x-ray).
	var scope := VM.node(_gun)
	var sy := SCOPE_Y
	for z in [0.01, -0.15]:
		VM.box(scope, Vector3(0, (0.082 + sy - 0.016) * 0.5, z), Vector3(0.014, sy - 0.016 - 0.082 + 0.004, 0.016), dark)
		VM.ring(scope, Vector3(0, sy, z), Vector3.FORWARD, 0.019, 0.0045, dark)
	VM.seg(scope, Vector3(0, sy, 0.07), Vector3(0, sy, -0.21), 0.0155, 0.0155, gunm, 20)
	VM.seg(scope, Vector3(0, sy, 0.07), Vector3(0, sy, 0.095), 0.0165, 0.02, gunm, 20)
	VM.seg(scope, Vector3(0, sy, 0.095), Vector3(0, sy, EYEPIECE_Z), 0.021, 0.0215, rubber, 20)
	VM.seg(scope, Vector3(0, sy, -0.21), Vector3(0, sy, -0.255), 0.0155, 0.025, gunm, 22)
	VM.seg(scope, Vector3(0, sy, -0.255), Vector3(0, sy, -0.29), 0.025, 0.0255, gunm, 22)
	VM.ring(scope, Vector3(0, sy, -0.255), Vector3.FORWARD, 0.026, 0.0035, orange)
	VM.seg(scope, Vector3(0, sy + 0.014, -0.07), Vector3(0, sy + 0.03, -0.07), 0.011, 0.011, gunm, 16)
	VM.seg(scope, Vector3(0, sy + 0.03, -0.07), Vector3(0, sy + 0.035, -0.07), 0.011, 0.0095, orange, 16)
	VM.box(scope, Vector3(-0.022, sy, -0.07), Vector3(0.012, 0.018, 0.04), dark)
	VM.box(scope, Vector3(-0.0285, sy, -0.07), Vector3(0.0015, 0.008, 0.028), _coil_mat)
	var g1 := VM.seg(scope, Vector3(0, sy, -0.286), Vector3(0, sy, -0.288), 0.023, 0.023, VM.glass(Color(0.5, 0.3, 0.9, 0.35)), 22)
	g1.set_meta("no_bake", true)
	var g2 := VM.ring(scope, Vector3(0, sy, -0.287), Vector3.FORWARD, 0.021, 0.0015, VM.glow(VIOLET, 1.2))
	g2.set_meta("no_bake", true)
	var g3 := VM.seg(scope, Vector3(0, sy, EYEPIECE_Z - 0.006), Vector3(0, sy, EYEPIECE_Z - 0.004), 0.019, 0.019, VM.glass(Color(0.05, 0.1, 0.16, 0.6)), 22)
	g3.set_meta("no_bake", true)
	# Muzzle flash: a violet star off the emitter.
	_make_flash(_gun, Vector3(0, by, -0.975), 1.3, Color(0.8, 0.5, 1.0))
	VM.bake(_gun, [_mag, _flash_root, _muzzle, left_grip, grip_point, trigger_point, scope])
	VM.bake(_mag, [_mag_grab])
	VM.bake(scope)
	# Attachment mount (attachments.gd): a reflex / holo on the top cover in place of the scope.
	# (The optics' sight line just under the own scope's axis: lower, the rail's top filled the window.)
	att_kit.build(self, _gun, {"optic": {"y": 0.082, "z": -0.04, "irons": SCOPE_Y - 0.006, "default": scope}})
	return model


# =================================================================================================
# Third-person model (the player's body, remote avatars)
# =================================================================================================

func _build_tp(p: Node3D) -> Node3D:
	return build_tp_model(p)


## Simplified model under prop root `p` (grip at the origin, -Z forward). Returns the muzzle node.
static func build_tp_model(p: Node3D) -> Node3D:
	var white := _mat3(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _mat3(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _mat3(Color(0.14, 0.15, 0.17), 0.35, 0.7)
	var steel := _mat3(Color(0.6, 0.62, 0.66), 0.3, 0.85)
	var copper := _mat3(Color(0.74, 0.43, 0.22), 0.32, 0.9)
	var glow := _mat3(VIOLET, 0.4, 0.0)
	glow.emission_enabled = true
	glow.emission = VIOLET.lerp(CYAN, 0.3)
	glow.emission_energy_multiplier = 2.5
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.044, -0.075), Vector3(0.064, 0.068, 0.33), white)
	VM.box(p, Vector3(0, 0.062, 0.19), Vector3(0.04, 0.03, 0.2), white)
	VM.box(p, Vector3(0, 0.083, 0.2), Vector3(0.034, 0.02, 0.12), orange)
	VM.box(p, Vector3(0, 0.03, 0.29), Vector3(0.044, 0.13, 0.04), white)
	VM.box(p, Vector3(0, -0.02, -0.13), Vector3(0.034, 0.05, 0.06), dark)
	VM.box(p, Vector3(0, 0.03, -0.37), Vector3(0.084, 0.036, 0.22), dark)
	for sx in [-1.0, 1.0]:
		VM.box(p, Vector3(0.0175 * sx, BORE_Y, -0.585), Vector3(0.011, 0.034, 0.69), steel)
	VM.box(p, Vector3(0, BORE_Y, -0.585), Vector3(0.02, 0.012, 0.68), glow)
	for zc in [-0.36, -0.54, -0.72]:
		VM.ring(p, Vector3(0, BORE_Y, zc), Vector3.FORWARD, 0.031, 0.012, copper)
	for z in [-0.27, -0.45, -0.63, -0.81]:
		VM.box(p, Vector3(0, BORE_Y, z), Vector3(0.06, 0.06, 0.02), orange)
	VM.seg(p, Vector3(0, SCOPE_Y, 0.1), Vector3(0, SCOPE_Y, -0.21), 0.017, 0.017, dark, 12)
	VM.seg(p, Vector3(0, SCOPE_Y, -0.21), Vector3(0, SCOPE_Y, -0.29), 0.017, 0.025, dark, 12)
	return VM.node(p, Vector3(0, BORE_Y, -0.97))


static func _mat3(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m
