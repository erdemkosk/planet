extends "res://scripts/items/weapon_base.gd"
## Plazma Kesici (item id "plasma"; a POWER weapon, meant to come by the İkmal kapsülü supply pod;
## WEIGHT 0.95): a short-range plasma beam that is a weapon and a very fast drill at once. When an
## enemy runs into a tunnel you cut through the wall after him. No ammo: heat only.
##   Beam      hold LMB: a white-hot beam from the eye along the aim, out to RANGE m. Every beam tick
##             (TICK_HZ, the multiplayer terrain batch rate) one trace: the soil on the exact density
##             field (_soil_march from TRACE_BACK m before the terrain collider: the cut advances at
##             once, before the chunk's collision is re-meshed; ~0.1-0.2 ms), characters / structures /
##             vehicles by a physics ray, plus a scan of the bots and players whose upright axis passes
##             within HIT_RADIUS of the beam (a forgiving aim).
##   Cut       soil first on the beam: one DIG brush of BORE_R m at CARVE_AHEAD m inside the surface,
##             CARVE_RATE density / s (3 × the drill's terrain_tool.gd RATE), through Dig.dig_at ->
##             planet.apply_brush (synced like the drill: the host's ops go out, a client's apply at
##             once and go to the host). The cut soil gives material at MATERIAL_K × the drill's cap
##             (Balance.DRILL_MAX_RATE m³/s): the drill stays the economic tool. An enemy core under
##             the cut takes the drill's core damage × CORE_K (Core.drill_all).
##   Burn      a target first on the beam takes DPS hp/s (structures × STRUCT_K), flushed DAMAGE_HZ
##             times a second through Game.damage_target (a client's become claims to the host), with
##             HitFeel markers (a confirm click every 3rd flush), a flinch (astronaut hit_react) every
##             FLINCH_GAP s and an afterburn of BURN_DPS for BURN_TIME s once it leaves the beam
##             (characters only). Own side's structures / players / torpedoes stop the beam unhurt;
##             cores are only cut (above).
##   Heat      the beam heats HEAT_RISE / s (HEAT_MAX: ~4.5 s from cold); idle it cools HEAT_COOL / s
##             after HEAT_COOL_DELAY s. At HEAT_MAX it overheats: a forced VENT_TIME s vent (steam out of
##             the side flaps, the coils glowing, an alarm and a long hiss), no firing, heat down to
##             VENT_END_HEAT. R vents by hand (VENT_MANUAL_K s per heat unit, down to 0) when there is
##             VENT_MANUAL_MIN heat or more.
##   Slot      hold RMB: "Kesme Düzlemi". The wall within SLOT_RANGE m ahead gets a door-sized slot
##             (SLOT_W × SLOT_H, SLOT_DEPTH m deep, standing on the floor under you; aimed steeply up
##             or down a hatch along the aim instead): a grid of brushes swept left -> over the top
##             -> right in SLOT_TIME s while the beam traces the arch. Costs SLOT_HEAT heat over the
##             sweep and needs the heat at or below SLOT_MAX_START; letting go stops it where it is.
##   Look      plasma_beam.gd (core, glow, heat shimmer, sparks, slag, molten rims cooling white ->
##             orange -> dark, a light at the cut, the sizzle); the view model's coils, chamber, tip
##             and gauge glow with the heat, the flaps open and steam on a vent.
##   HUD       plasma_hud.gd (the heat arc, the vent, the slot ring); the main HUD plate reads
##             hud_panel_lines() (mag_count() -1: no ammo block).
## Multiplayer: plasma_beam(state, from, to, surf, heat) while the beam or the slot runs (NET_HZ, and
## state 0 once when it stops): state 0 off / 1 beam / 2 slot, from = the emitter, to = the cut end
## (world), surf = PlasmaBeam.SURF_*, heat 0..1. net_players.gd sends it (body-local) and the other
## machine drives a remote plasma_beam.gd from the avatar's third-person muzzle. Terrain and damage
## travel their usual ways (net_terrain.gd, damage claims); Game.shot_fired goes out NOISE_HZ times a
## second (the bots hear it).

signal plasma_beam(state: int, from: Vector3, to: Vector3, surf: int, heat: float)

const Balance := preload("res://scripts/war/balance.gd")
const Dig := preload("res://scripts/player/dig.gd")
const Core := preload("res://scripts/war/core.gd")
const PlasmaBeam := preload("res://scripts/items/plasma_beam.gd")
const PlasmaHud := preload("res://scripts/items/plasma_hud.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const UI := preload("res://scripts/ui/ui_style.gd")

# --- Tuning ----------------------------------------------------------------------------------------
const WEIGHT := 0.95                   # mobility factor while held (item.gd carry_weight)
const RANGE := 9.0                     # m: beam reach from the eye
const TICK_HZ := 15.0                  # beam ticks / s: trace, cut, damage (the net terrain batch rate)
const TICK_EPS := 0.002                # s of slack: a 1/15 s tick lands on every 4th 60 Hz physics step
const TRACE_STEP := 0.4                # m: the soil march (planet.raycast_density, exact density)
const TRACE_BACK := 0.6                # m before the terrain collider the march starts
const BORE_R := 1.15                   # m: brush radius of the cut
const CARVE_RATE := 48.0               # density / s at the bore centre (drill RATE 16: 3 ×)
const CARVE_AHEAD := 0.3               # m: the brush centre inside the surface along the beam
const MATERIAL_K := 0.4                # material credit cap: × Balance.DRILL_MAX_RATE m³/s
const CORE_K := 1.0                    # × the drill's core damage (Balance.CORE_DRILL_DPS)
const DPS := 90.0                      # hp / s to a character on the beam
const STRUCT_K := 0.8                  # × DPS to structures / vehicles / torpedoes
const DAMAGE_HZ := 10.0                # damage flushes / s (one claim per target each in multiplayer)
const HIT_RADIUS := 0.32               # m: the scan's reach round the beam (bots / players)
const BURN_DPS := 10.0                 # afterburn hp / s...
const BURN_TIME := 1.2                 # ...this long after leaving the beam
const FLINCH_GAP := 0.3                # s between the hit reactions on one target
const PUSH := 0.6                      # m/s impulse per flush along the beam (lethal: KILL_LAUNCH)
const KILL_LAUNCH := 3.5
const NOISE_HZ := 4.0                  # Game.shot_fired / s while beaming
const NET_HZ := 12.0                   # beam events / s
# Heat.
const HEAT_MAX := 100.0
const HEAT_RISE := 22.0                # / s beaming (cold to overheat ~4.5 s)
const HEAT_IGNITE := 1.5               # every ignition (a tap is not free)
const HEAT_COOL := 30.0                # / s idle...
const HEAT_COOL_DELAY := 0.45          # ...from this long after the beam stops
const VENT_TIME := 2.5                 # s of the forced vent
const VENT_END_HEAT := 20.0            # heat left after the forced vent
const VENT_MANUAL_MIN := 15.0          # R vents from this much heat
const VENT_MANUAL_K := 0.018           # s of hand vent per heat unit (100: 1.8 s)
# Kesme Düzlemi (RMB).
const SLOT_W := 1.3                    # m door width
const SLOT_H := 2.2                    # m door height (from the floor)
const SLOT_DEPTH := 3.0                # m into the wall
const SLOT_FRONT := 0.35               # m in front of the wall face the first slice starts
const SLOT_TIME := 1.0                 # s of the sweep
const SLOT_HEAT := 40.0                # heat over the whole sweep
const SLOT_MAX_START := 55.0           # no sweep above this heat
const SLOT_RANGE := 4.0                # m: the wall must be this close
const SLOT_R := 1.0                    # m: brush radius of one stamp
const SLOT_STEP := 0.55                # m between stamps (width, height, depth)
const SLOT_AMOUNT := 16.0              # density per stamp (overlapping stamps add up)
const SLOT_FLOOR := 0.15               # m the door's sill sits under the feet
const SLOT_STEEP := 0.55               # |aim · up| above this: a hatch along the aim
# Look.
const BORE_Y := 0.058
const COIL_COLD := Color(0.45, 0.7, 1.0)
const GLOW := Color(0.55, 0.78, 1.0)

# --- State (HUD, tests, multiplayer) ---------------------------------------------------------------
var panel_name := "Plazma Kesici"
var handling_len := 0.55                # handling.gd: wall pull-back length (blocks only very close)
var sprint_style := "smg"               # gun_feel.gd carry pose while running
## Grip descriptors (scripts/player/vm_hand.gd): the pistol grip, the vertical fore-grip under the coils.
var grip_right := {"trig_y": -0.0025}
var heat := 0.0
var beaming := false
var slotting := false
var venting := false
var vent_forced := false
var vent_t := 0.0
var vent_total := 1.0
var cool := 0.0                         # s until fully cool (hud.gd redraws the plate while > 0)
var cool_total := 1.0
var grip_point: Node3D
var trigger_point: Node3D
# Test counters.
var stat_soil := 0.0                    # m³ cut
var stat_credit := 0.0                  # m³ of material credited
var stat_dmg := 0.0                     # hp dealt (claimed)
var stat_ticks := 0
var stat_tick_usec := 0                 # µs spent in beam / slot ticks

var _beam: Node3D                       # plasma_beam.gd (local)
var _phud
var _hum: AudioStreamPlayer
var _tick_acc := 0.0
var _net_t := 0.0
var _noise_t := 0.0
var _cool_wait := 0.0
var _alt_prev := false
var _hit_t := 0.0                       # m from the eye to the cut end (last tick)
var _hit_n := Vector3.UP
var _hit_surf := 0
var _acc := {}                          # instance id -> {node, dmg, p, dir}
var _burn := {}                         # instance id -> {node, t, dir}
var _flinch := {}                       # instance id -> s until the next flinch
var _dmg_t := 0.0
var _flush_i := 0
var _vent_from := 0.0
var _vent_to := 0.0
var _fire_w := 0.0                      # 0..1 beam on (eased, the glow / tremble)
# Kesme Düzlemi.
var _slot_t := 0.0
var _slot_stamps: Array = []            # [u, world point] sorted by u
var _slot_i := 0
var _slot_base := Vector3.ZERO          # door sill centre on the wall face
var _slot_x := Vector3.RIGHT
var _slot_y := Vector3.UP
var _slot_z := Vector3.FORWARD          # into the wall
var _slot_pt := Vector3.ZERO
# Model parts.
var _coil_mat: ShaderMaterial
var _chamber_mat: ShaderMaterial
var _tip_mat: ShaderMaterial
var _seg_mats: Array = []
var _flaps: Array = []                  # [hinge node, side]
var _vent_l: Node3D
var _vent_r: Node3D
var _steam: Array = []                  # CPUParticles3D (world space) at the vents


func _init() -> void:
	item_id = "plasma"
	item_name = "Plazma Kesici"
	item_desc = "Sol tık basılı: plazma ışını — yakın menzilde yakar, toprağı çok hızlı keser · Sağ tık basılı: kesme düzlemi (önündeki duvara kapı açar) · R: soğut. Ateş ettikçe ısınır; aşırı ısınınca kendini soğutur."
	icon = "plasma"
	slot_key = 0                         # the loadout decides its key
	short_name = "Plazma"
	accent = Color(0.62, 0.82, 1.0)
	ammo_id = ""
	ammo_title = "PLAZMA · ISI"
	base_mag = 1                         # (no ammo: the magazine stays full, heat is the limit)
	can_ads = false                      # RMB is the Kesme Düzlemi
	auto_fire = true
	fire_rate = 20.0
	hip_pos = Vector3(0.15, -0.2, -0.33)
	hip_bore_y = BORE_Y
	hip_converge = 7.0
	hip_cant = 0.06
	sprint_pos = Vector3(0.13, -0.17, -0.34)
	sprint_rot = Vector3(-0.25, 0.55, 0.35)
	reload_pos = Vector3(0.12, -0.18, -0.36)
	reload_rot = Vector3(0.2, 0.3, 0.5)
	recoil_pivot = Vector3(0.0, 0.04, 0.1)
	sprint_to_fire = 0.12
	spread_hip = 0.004
	spread_ads = 0.004
	bloom_add = 0.0
	bloom_max = 0.0
	first_shot_k = 1.0
	gun_kick = 1.0
	shake_amt = 0.0
	noise_radius = 40.0
	crosshair_style = "ticks"
	hit_big = 0.1
	head_mult = 0.0
	kill_launch = KILL_LAUNCH
	draw_time = 0.55
	holster_time = 0.35
	grip_left = {"at": Vector3(0.0, -0.0005, -0.2), "axis": Vector3(0, 0.066, -0.009),
			"palm": Vector3(-0.984, 0, 0.173), "r": 0.0165}


func _ready() -> void:
	super._ready()
	PlasmaBeam.prewarm()
	_beam = PlasmaBeam.make(self, false)
	_phud = PlasmaHud.new()
	_phud.weapon = self
	add_child(_phud)
	_hum = AudioStreamPlayer.new()
	_hum.bus = Rifle._weapons_bus()
	add_child(_hum)
	for i in 2:
		_steam.append(_make_steam())


func _exit_tree() -> void:
	PlasmaBeam.finish()
	super._exit_tree()


func _stream(sname: String) -> AudioStream:
	var s := PlasmaBeam.stream(sname)
	if s != null:
		return s
	return super._stream(sname)


# =================================================================================================
# Item / HUD queries
# =================================================================================================

func heat_frac() -> float:
	return clampf(heat / HEAT_MAX, 0.0, 1.0)


func slot_progress() -> float:
	return clampf(_slot_t / SLOT_TIME, 0.0, 1.0) if slotting else 0.0


## No ammo: the HUD plate and the quickbar skip their ammo block (hud.gd / quickbar.gd _mag).
func mag_count() -> int:
	return -1


func reserve_count() -> int:
	return 1


func reserve_stock() -> int:
	return -1


func round_cost() -> float:
	return 0.0


func status_text() -> String:
	return "%d%%" % int(roundf(heat_frac() * 100.0))


func mode_text() -> String:
	return ""


func reload_label() -> String:
	return "SOĞUTUYOR"


func current_spread() -> float:
	return 0.004


## The main HUD's weapon plate (hud.gd): [big line, small line, small line colour].
func hud_panel_lines() -> Array:
	var hp := int(roundf(heat_frac() * 100.0))
	if venting:
		var left := maxf(vent_total - vent_t, 0.0)
		return ["SOĞUTUYOR  %d%%" % hp, ("aşırı ısındı · %s s" if vent_forced else "elle soğutma · %s s") % String.num(left, 1).replace(".", ","),
				UI.SUIT_ORANGE]
	if slotting:
		return ["KESME DÜZLEMİ  %d%%" % int(slot_progress() * 100.0), "ısı %d%%" % hp, UI.SCREEN_CYAN]
	return ["ISI  %d%%" % hp, "Sol: ışın · Sağ: kesme düzlemi · R: soğut", PlasmaHud.heat_col(heat_frac())]


func save_state() -> Dictionary:
	var d := super.save_state()
	d["heat"] = heat
	return d


func load_state(d: Dictionary) -> void:
	mag = 1
	heat = clampf(float(d.get("heat", 0.0)), 0.0, HEAT_MAX * 0.9)


func _on_state_changed() -> void:
	super._on_state_changed()
	if not active or not equipped:
		_stop_all()


func _sprint_allowed() -> bool:
	return not (beaming or slotting)


func _idle_tick(delta: float) -> void:
	_stop_all()
	_alt_prev = false
	_damage_tick(delta)


## R: vent by hand (from VENT_MANUAL_MIN heat; nothing while the beam or a sweep runs).
func reload() -> void:
	if venting or beaming or slotting:
		return
	if heat < VENT_MANUAL_MIN:
		if Game.sfx:
			Game.sfx.play("click", -12.0, 1.2)
		return
	_start_vent(false)


func toggle_mode() -> void:
	pass


# =================================================================================================
# Trigger: the beam, the slot, the vent
# =================================================================================================

func _trigger(trig: bool, pressed: bool, alt: bool, delta: float) -> void:
	var alt_press := alt and not _alt_prev
	_alt_prev = alt
	if venting or not player.viewmodel.is_raised():
		_stop_all()
		if venting and (pressed or alt_press):
			_deny("")
		_damage_tick(delta)
		return
	if slotting:
		if alt:
			_slot_tick(delta)
		else:
			_end_slot(false)
		_damage_tick(delta)
		return
	if alt_press and not beaming:
		_start_slot()
		if slotting:
			_damage_tick(delta)
			return
	if trig and not alt and _since_sprint >= sprint_to_fire:
		if not beaming:
			_start_beam()
		_beam_tick(delta)
	elif beaming:
		_stop_beam()
	_damage_tick(delta)


func _start_beam() -> void:
	beaming = true
	heat = minf(heat + HEAT_IGNITE, HEAT_MAX)
	_tick_acc = 1.0 / TICK_HZ                # the first trace at once
	_net_t = 0.0
	_noise_t = 0.0
	_play("plasma_ignite", -7.0, randf_range(0.96, 1.04), true)
	_rk_vel += Vector4(0.6, randf_range(-0.2, 0.2), randf_range(-0.2, 0.2), 0.25)


func _stop_beam() -> void:
	if not beaming:
		return
	beaming = false
	_cool_wait = HEAT_COOL_DELAY
	_play("plasma_stop", -10.0, randf_range(0.95, 1.05), true)
	_send_net(0)


func _stop_all() -> void:
	_stop_beam()
	if slotting:
		_end_slot(false)


func _beam_tick(delta: float) -> void:
	_use_t = 0.12
	_since_shot = 0.0
	heat = minf(heat + HEAT_RISE * delta, HEAT_MAX)
	_cool_wait = HEAT_COOL_DELAY
	_tick_acc += delta
	if _tick_acc >= 1.0 / TICK_HZ - TICK_EPS:
		var dt := minf(_tick_acc, 0.2)
		_tick_acc = 0.0
		var t0 := Time.get_ticks_usec()
		_beam_step(dt)
		stat_ticks += 1
		stat_tick_usec += Time.get_ticks_usec() - t0
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var dir := -cam.global_transform.basis.z
	_noise_t -= delta
	if _noise_t <= TICK_EPS:
		_noise_t = 1.0 / NOISE_HZ
		Game.shot_fired.emit(eye, dir, "home")         # the rival bots react (ai_rival.gd)
	_net_t -= delta
	if _net_t <= TICK_EPS:
		_net_t = 1.0 / NET_HZ
		_send_net(1)
	if heat >= HEAT_MAX:
		_start_vent(true)


## One beam tick: trace, cut the soil or burn the target.
func _beam_step(dt: float) -> void:
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var dir := -cam.global_transform.basis.z
	var tr := _trace(eye, dir)
	_hit_t = float(tr["t"])
	_hit_n = tr["n"]
	_hit_surf = int(tr["surf"])
	var p: Vector3 = eye + dir * _hit_t
	last_impact = p
	var team := Game.team_of(player)
	if _hit_surf == PlasmaBeam.SURF_SOIL:
		var body: Node3D = tr["body"]
		var up: Vector3 = player.global_transform.basis.y
		var soil := Dig.dig_at(body, p + dir * CARVE_AHEAD, BORE_R, Dig.MODE_DIG, CARVE_RATE * dt, eye, up, -1.0, team)
		_credit(soil, dt)
		Core.drill_all(get_tree(), p, BORE_R, team, dt * CORE_K)
	elif tr["target"] != null:
		var t: Node = tr["target"]
		var k := STRUCT_K if not _is_char(t) else 1.0
		_hurt(t, DPS * k * dt, p, dir)


## Cut soil -> material, capped at MATERIAL_K of the drill's rate.
func _credit(soil: float, dt: float) -> void:
	if soil <= 0.0:
		return
	stat_soil += soil
	var got := Game.add_material(minf(soil, Balance.DRILL_MAX_RATE * MATERIAL_K * dt))
	stat_credit += maxf(got, 0.0)


## What the beam from `eye` along `dir` meets first: {"t" (m), "surf" (PlasmaBeam.SURF_*), "n" (the
## surface normal), "target" (a damageable or null), "body" (the planet, soil hits)}.
func _trace(eye: Vector3, dir: Vector3) -> Dictionary:
	var out := {"t": RANGE, "surf": PlasmaBeam.SURF_AIR, "n": -dir, "target": null, "body": null}
	var space := get_world_3d().direct_space_state
	var ex: Array = [player.get_rid()]
	# Soil: the edited density field (exact right after our own cut). The march starts TRACE_BACK m
	# before the terrain's collision: cutting only moves the surface away, so a collider not yet
	# re-meshed is still a safe lower bound (and the march, the tick's main cost, stays short). No
	# collider within RANGE: no ground there to cut.
	var body: Node3D = Game.dominant_body(eye)
	if body != null and body.has_method("density_at"):
		var hc := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + dir * RANGE, Game.LAYER_TERRAIN, ex))
		if not hc.is_empty():
			var tc := eye.distance_to(hc["position"])
			var t0 := maxf(tc - TRACE_BACK, 0.0)
			var ts := _soil_march(body, eye + dir * t0, dir, RANGE - t0)
			if ts >= 0.0:
				out["t"] = t0 + ts
				out["surf"] = PlasmaBeam.SURF_SOIL
				# The collider's normal while it is at the surface, else (inside our cut) back along the beam.
				out["n"] = hc["normal"] if absf(t0 + ts - tc) < 0.35 else -dir
				out["body"] = body
	var t_end := float(out["t"])
	# Characters, structures, vehicles (physics), up to the soil.
	for i in 4:
		var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * t_end, Game.LAYER_PLAYER | Game.LAYER_SHIP | Game.LAYER_VEHICLE, ex)
		var h := space.intersect_ray(q)
		if h.is_empty():
			break
		var dn := Game.damageable_of(h["collider"])
		if dn == player:
			ex.append(h["rid"])
			continue
		out["t"] = eye.distance_to(h["position"])
		out["n"] = h["normal"]
		out["body"] = null
		if dn != null and _target_ok(dn):
			out["target"] = dn
			out["surf"] = PlasmaBeam.SURF_BODY if _is_char(dn) else PlasmaBeam.SURF_METAL
		else:
			out["surf"] = PlasmaBeam.SURF_METAL       # own side's / an undamageable hull: the beam stops
		t_end = float(out["t"])
		break
	# The scan: bots / players whose upright axis passes close to the beam (a forgiving aim).
	var end := eye + dir * t_end
	for grp in ["war_ai", "net_player"]:
		for nd in get_tree().get_nodes_in_group(grp):
			if not (nd is Node3D) or nd == out["target"] or not _target_ok(nd):
				continue
			var n3 := nd as Node3D
			var up := n3.global_transform.basis.y.normalized()
			var a := n3.global_position + up * 0.15
			if a.distance_squared_to(eye) > (RANGE + 2.5) * (RANGE + 2.5):
				continue
			var r := _seg_seg(eye, end, a, n3.global_position + up * 1.75)
			if float(r[0]) <= HIT_RADIUS and float(r[1]) < t_end:
				t_end = float(r[1])
				out["t"] = t_end
				out["target"] = nd
				out["surf"] = PlasmaBeam.SURF_BODY
				out["n"] = -dir
				out["body"] = null
				end = eye + dir * t_end
	return out


## Metres from `from` along `dir` to the soil (the exact, edited density: the mesh's; density_fast
## leaves out the ±1.3 m detail noise of unedited ground and would stop the beam short of a wall),
## TRACE_STEP samples and a linear crossing between the last two; -1 when none within `length`.
static func _soil_march(body: Node3D, from: Vector3, dir: Vector3, length: float) -> float:
	var prev := float(body.density_at(from))
	if prev < 0.0:
		return 0.0
	var t := 0.0
	while t < length:
		var tn := minf(t + TRACE_STEP, length)
		var d := float(body.density_at(from + dir * tn))
		if d < 0.0:
			return t + (tn - t) * clampf(prev / maxf(prev - d, 1e-5), 0.0, 1.0)
		prev = d
		t = tn
	return -1.0


func _is_char(n: Node) -> bool:
	return n.is_in_group("war_ai") or n.is_in_group("net_player") or n.get("astronaut") != null


## May the beam hurt n? (Alive, not us, not our own side's structures / players / torpedoes / bots;
## cores take the cut only.)
func _target_ok(n: Node) -> bool:
	if n == player or n.is_in_group("war_core"):
		return false
	if n.has_method("is_dead") and bool(n.call("is_dead")):
		return false
	if Game.team_of(n) == Game.team_of(player) and (n.is_in_group("war_structure") or n.is_in_group("net_player")
			or n.is_in_group("war_torpedo") or n.is_in_group("skiff") or n.is_in_group("war_ally")):
		return false
	return true


## Closest approach of segments p1-q1 and p2-q2: [distance, m along the first from p1, point on it].
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
	return [c1.distance_to(p2 + d2 * t), sqrt(a) * s, c1]


# =================================================================================================
# Damage (accumulated per target, flushed DAMAGE_HZ times a second; the afterburn)
# =================================================================================================

func _hurt(t: Node, dmg: float, p: Vector3, dir: Vector3) -> void:
	var id := t.get_instance_id()
	if _acc.has(id):
		var e: Dictionary = _acc[id]
		e["dmg"] = float(e["dmg"]) + dmg
		e["p"] = p
		e["dir"] = dir
	else:
		_acc[id] = {"node": t, "dmg": dmg, "p": p, "dir": dir}
	if _is_char(t):
		_burn[id] = {"node": t, "t": BURN_TIME, "dir": dir}


func _damage_tick(delta: float) -> void:
	for id in _flinch.keys():
		_flinch[id] = float(_flinch[id]) - delta
		if float(_flinch[id]) <= 0.0:
			_flinch.erase(id)
	_dmg_t += delta
	if _dmg_t < 1.0 / DAMAGE_HZ - TICK_EPS:
		return
	var win := _dmg_t
	_dmg_t = 0.0
	if _acc.is_empty() and _burn.is_empty():
		return
	# Afterburn: burning characters not on the beam this window.
	for id in _burn.keys():
		var b: Dictionary = _burn[id]
		var n = b["node"]
		b["t"] = float(b["t"]) - win
		if not is_instance_valid(n) or float(b["t"]) <= 0.0 or (n.has_method("is_dead") and bool(n.call("is_dead"))):
			_burn.erase(id)
			continue
		if not _acc.has(id):
			var p: Vector3 = (n as Node3D).global_position + (n as Node3D).global_transform.basis.y * 1.1
			_acc[id] = {"node": n, "dmg": BURN_DPS * win, "p": p, "dir": b["dir"], "burn": true}
	_flush_i += 1
	for id in _acc:
		var e: Dictionary = _acc[id]
		var n = e["node"]
		if is_instance_valid(n):
			_apply(n, float(e["dmg"]), e["p"], e["dir"], e.has("burn"))
	_acc.clear()


func _apply(t: Node, dmg: float, p: Vector3, dir: Vector3, afterburn: bool) -> void:
	if dmg <= 0.01 or not _target_ok(t):
		return
	var hp0 = t.get("hp")
	var lethal: bool = hp0 != null and float(hp0) > 0.0 and float(hp0) <= dmg + 0.001
	var up := Vector3.UP
	if t is Node3D:
		up = (t as Node3D).global_transform.basis.y
	var imp: Vector3 = (dir * KILL_LAUNCH + up * KILL_LAUNCH * 0.3) if lethal else dir * PUSH
	var src: Vector3 = (player as Node3D).global_position if player is Node3D else p - dir * 5.0
	var r := Game.damage_target(t, dmg, src, imp, Game.team_of(player), p)
	if r.is_empty():
		return
	stat_dmg += dmg
	hits += 1
	var killed := bool(r.get("killed", false))
	var id := t.get_instance_id()
	# The burn's flinch (the hit reactor), not on every flush.
	var ast = t.get("astronaut")
	if not killed and not afterburn and ast is Node3D and ast.has_method("hit_react") and not _flinch.has(id):
		_flinch[id] = FLINCH_GAP
		ast.hit_react(dir, 0.3, false)
	var quiet := not killed and _flush_i % 3 != 0
	HitFeel.inst().target_hit(t, r, dmg, p, {"big": hit_big, "weapon": short_name, "quiet": quiet,
			"number": not quiet})


# =================================================================================================
# Heat and the vent
# =================================================================================================

func _start_vent(forced: bool) -> void:
	_stop_all()
	venting = true
	vent_forced = forced
	vent_t = 0.0
	_vent_from = heat
	_vent_to = VENT_END_HEAT if forced else 0.0
	vent_total = VENT_TIME if forced else maxf(heat * VENT_MANUAL_K, 0.3)
	_play("plasma_vent", -6.0 if forced else -9.0, 1.0 if forced else 1.15, true)
	if forced:
		_play("plasma_alarm", -9.0, 1.0)
		_rk_vel += Vector4(-1.2, 0.3, 0.6, -0.2)
		_toast("Plazma Kesici aşırı ısındı — soğutuluyor", 1, "plasma_heat", 1.8)
	else:
		_rk_vel += Vector4(-0.5, 0.0, 0.3, 0.0)


func _deny(msg: String) -> void:
	if _phud != null:
		_phud.denied()
	if Game.sfx:
		Game.sfx.play("error", -13.0)
	if msg != "":
		_toast(msg, 0, "plasma_slot", 1.6)


## A toast through the HUD's alert queue (priority 0 info / 1 normal / 2 critical, `key` dedupes)
## where the HUD has one, else its plain message line.
func _toast(text: String, priority: int, key: String, secs: float) -> void:
	if Game.hud == null:
		return
	if Game.hud.has_method("alert"):
		Game.hud.alert(text, priority, key, secs)
	else:
		Game.hud.show_message(text, secs)


## Per frame (weapon_base _process): heat and the vent, the cooling time, the beam's look, the hum,
## the glow, steam.
func _tick(delta: float, on: bool) -> void:
	if venting:
		vent_t += delta
		var u := clampf(vent_t / maxf(vent_total, 0.01), 0.0, 1.0)
		heat = lerpf(_vent_from, _vent_to, _smooth(u))
		if u >= 1.0:
			venting = false
			heat = _vent_to
			_play("plasma_ready", -14.0, 1.0)
	elif not beaming and not slotting:
		_cool_wait -= delta
		if _cool_wait <= 0.0:
			heat = maxf(heat - HEAT_COOL * delta, 0.0)
	cool = (vent_total - vent_t) if venting else (heat / HEAT_COOL + maxf(_cool_wait, 0.0) if heat > 0.01 else 0.0)
	cool_total = maxf(cool_total, cool) if cool > 0.0 else 1.0
	_fire_w = move_toward(_fire_w, 1.0 if (beaming or slotting) else 0.0, delta * (12.0 if (beaming or slotting) else 5.0))
	_update_beam_look(on)
	_update_hum(on)
	_update_steam(delta, on)
	if (beaming or slotting) and on:
		# The beam's tremble, braced in the hands; a light continuous camera buzz.
		var tk := 0.5 + 0.8 * heat_frac()
		_rk_vel += Vector4(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(0.0, 0.6)) * tk * 0.18
		_trauma = maxf(_trauma, 0.12 + 0.12 * heat_frac())


func _update_beam_look(on: bool) -> void:
	if _beam == null:
		return
	if not on or player == null or not (beaming or slotting):
		_beam.idle()
		return
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var to: Vector3 = _slot_pt if slotting else eye - cam.global_transform.basis.z * _hit_t
	_beam.drive(muzzle_world(), to, _hit_n, PlasmaBeam.SURF_SOIL if slotting else _hit_surf, heat_frac(), slotting)


func _update_hum(on: bool) -> void:
	if _hum == null:
		return
	if (beaming or slotting) and on:
		if not _hum.playing:
			var st := PlasmaBeam.stream("plasma_loop")
			if st == null:
				return
			_hum.stream = st
			_hum.volume_db = -20.0
			_hum.play(randf() * 0.8)
		var vac := GunFeel.in_vacuum()
		_hum.bus = "VacSuit" if vac else Rifle._weapons_bus()
		_hum.volume_db = move_toward(_hum.volume_db, (-14.0 if vac else -8.0) + (2.0 if slotting else 0.0), 3.0)
		_hum.pitch_scale = 0.95 + 0.18 * heat_frac() + randf_range(-0.01, 0.01)
	elif _hum.playing:
		_hum.volume_db -= 3.5
		if _hum.volume_db < -40.0:
			_hum.stop()


func _send_net(state: int) -> void:
	if player == null:
		return
	var cam: Camera3D = player.camera
	var to: Vector3 = _slot_pt if state == 2 else cam.global_position - cam.global_transform.basis.z * _hit_t
	if state == 0:
		to = last_impact if last_impact.is_finite() else cam.global_position
	plasma_beam.emit(state, muzzle_world(), to, PlasmaBeam.SURF_SOIL if state == 2 else _hit_surf, heat_frac())


# =================================================================================================
# Kesme Düzlemi (RMB): a door-sized slot swept in SLOT_TIME
# =================================================================================================

func _start_slot() -> void:
	if heat > SLOT_MAX_START:
		_deny("Kesme düzlemi için çok sıcak")
		return
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var dir := -cam.global_transform.basis.z
	var body: Node3D = Game.dominant_body(eye)
	var h: Dictionary = {}
	if body != null and body.has_method("raycast_density"):
		h = body.raycast_density(eye, eye + dir * SLOT_RANGE, 0.3)
	if h.is_empty():
		_deny("Kesme düzlemi: önünde duvar yok")
		return
	var hp: Vector3 = h["position"]
	var up: Vector3 = player.global_transform.basis.y
	if absf(dir.dot(up)) <= SLOT_STEEP:
		# A door: into the wall along the flattened aim, standing on the floor under the player.
		_slot_z = (dir - up * dir.dot(up)).normalized()
		_slot_y = up
		var feet: Vector3 = player.global_position
		_slot_base = hp - up * ((hp - feet).dot(up) + SLOT_FLOOR)
	else:
		# A hatch: along the aim, centred on the aim point, its "up" the player's facing.
		_slot_z = dir
		var fwd: Vector3 = -player.global_transform.basis.z
		_slot_y = (fwd - dir * fwd.dot(dir)).normalized()
		if _slot_y.length_squared() < 0.01:
			_slot_y = up
		_slot_base = hp - _slot_y * SLOT_H * 0.5
	_slot_x = _slot_z.cross(_slot_y).normalized()
	_slot_stamps = _slot_grid()
	_slot_i = 0
	_slot_t = 0.0
	_tick_acc = 0.0
	_net_t = 0.0
	slotting = true
	_hit_n = -_slot_z
	_slot_pt = _slot_outline(0.0)
	_play("plasma_ignite", -5.0, 0.9, true)
	_rk_vel += Vector4(0.8, 0.0, 0.0, 0.3)


## The stamps of the slot: [u (sweep order 0..1), world point], sorted by u. The sweep runs round
## the door's centre from the left sill over the top to the right sill; every depth slice of a cell
## goes with it.
func _slot_grid() -> Array:
	var out: Array = []
	var nx := maxi(int(ceilf((SLOT_W - SLOT_R * 0.6) / SLOT_STEP)) + 1, 1)
	var ny := maxi(int(ceilf((SLOT_H - SLOT_R * 0.7) / SLOT_STEP)) + 1, 1)
	var nz := maxi(int(ceilf((SLOT_DEPTH + SLOT_FRONT) / SLOT_STEP)) + 1, 1)
	var yc := SLOT_H * 0.4
	for ix in nx:
		var x := (float(ix) / float(maxi(nx - 1, 1)) - 0.5) * (SLOT_W - SLOT_R * 0.6) if nx > 1 else 0.0
		for iy in ny:
			var y := SLOT_R * 0.45 + float(iy) * (SLOT_H - SLOT_R * 0.7) / float(maxi(ny - 1, 1))
			# The arch: the upper corners round off.
			var top := (y - yc) / (SLOT_H - yc)
			if top > 0.0 and absf(x) / (SLOT_W * 0.5) > sqrt(maxf(1.0 - top * top, 0.0)) + 0.15:
				continue
			var a := atan2(y - yc, x)
			if a < -PI * 0.5:
				a += TAU
			var u := clampf((PI * 1.5 - a) / TAU, 0.0, 1.0)
			for iz in nz:
				var z := -SLOT_FRONT + float(iz) * SLOT_STEP
				out.append([u * 0.98 + float(iz) * 0.002, _slot_base + _slot_x * x + _slot_y * y + _slot_z * z])
	out.sort_custom(func(p, q): return float(p[0]) < float(q[0]))
	return out


## The beam's point on the door outline at sweep progress s (on the wall face).
func _slot_outline(s: float) -> Vector3:
	var yc := SLOT_H * 0.4
	var a := PI * 1.5 - s * TAU
	var x := cos(a) * SLOT_W * 0.5
	var sy := sin(a)
	var y := yc + sy * ((SLOT_H - yc) if sy > 0.0 else yc)
	return _slot_base + _slot_x * x + _slot_y * maxf(y, 0.1)


func _slot_tick(delta: float) -> void:
	_use_t = 0.12
	_since_shot = 0.0
	_slot_t += delta
	heat = minf(heat + SLOT_HEAT / SLOT_TIME * delta, HEAT_MAX)
	_cool_wait = HEAT_COOL_DELAY
	var s := clampf(_slot_t / SLOT_TIME, 0.0, 1.0)
	_slot_pt = _slot_outline(s)
	_tick_acc += delta
	if _tick_acc >= 1.0 / TICK_HZ - TICK_EPS or s >= 1.0:
		var dt := _tick_acc
		_tick_acc = 0.0
		var t0 := Time.get_ticks_usec()
		var team := Game.team_of(player)
		var up: Vector3 = player.global_transform.basis.y
		var soil := 0.0
		while _slot_i < _slot_stamps.size() and (float(_slot_stamps[_slot_i][0]) <= s or s >= 1.0):
			var p: Vector3 = _slot_stamps[_slot_i][1]
			var body := Game.dominant_body(p)
			if body != null:
				soil += Dig.dig_at(body, p, SLOT_R, Dig.MODE_DIG, SLOT_AMOUNT, p, up, -1.0, team)
			_slot_i += 1
		_credit(soil, maxf(dt, 1.0 / TICK_HZ))
		stat_ticks += 1
		stat_tick_usec += Time.get_ticks_usec() - t0
	_noise_t -= delta
	if _noise_t <= TICK_EPS:
		_noise_t = 1.0 / NOISE_HZ
		Game.shot_fired.emit(player.aim_origin(), _slot_z, "home")
	_net_t -= delta
	if _net_t <= TICK_EPS:
		_net_t = 1.0 / NET_HZ
		_send_net(2)
	if heat >= HEAT_MAX:
		_start_vent(true)
	elif _slot_i >= _slot_stamps.size() and s >= 1.0:
		_end_slot(true)


func _end_slot(done: bool) -> void:
	if not slotting:
		return
	slotting = false
	_cool_wait = HEAT_COOL_DELAY
	_play("plasma_stop", -9.0, 0.9 if done else 1.05, true)
	if done:
		_play("plasma_ready", -16.0, 0.85)
	_send_net(0)


# =================================================================================================
# Model animation (heat glow, flaps) and the vent steam
# =================================================================================================

static func heat_color(h: float) -> Color:
	var c := COIL_COLD.lerp(Color(1.0, 0.5, 0.15), smoothstep(0.2, 0.75, h))
	return c.lerp(Color(1.0, 0.9, 0.72), smoothstep(0.82, 1.0, h))


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _coil_mat == null:
		return
	var h := heat_frac()
	var fw := _fire_w
	var flick := 0.85 + 0.15 * sin(_t * 47.0) * sin(_t * 29.0 + 0.7)
	_coil_mat.set_shader_parameter("color", heat_color(h).lerp(Color(0.85, 0.92, 1.0), fw * (1.0 - h) * 0.5))
	_coil_mat.set_shader_parameter("energy", (0.25 + 5.0 * h * h + 3.0 * fw) * flick)
	_coil_mat.set_shader_parameter("flicker", 0.15 + 0.35 * h)
	var vent_k := 1.0 if venting else 0.0
	_chamber_mat.set_shader_parameter("color", GLOW.lerp(Color.WHITE, 0.6 * fw).lerp(Color(1.0, 0.6, 0.3), h * 0.5))
	_chamber_mat.set_shader_parameter("energy", (1.0 + 7.0 * fw * (0.8 + 0.2 * sin(_t * 31.0))) * (1.0 - 0.75 * vent_k))
	_tip_mat.set_shader_parameter("color", Color(1.0, 0.98, 0.95) if fw > 0.3 else heat_color(h).lerp(Color(1.0, 0.35, 0.1), 0.4))
	_tip_mat.set_shader_parameter("energy", 0.3 + 10.0 * fw * flick + 2.5 * h * (1.0 - fw))
	for i in _seg_mats.size():
		var lit := h * float(_seg_mats.size()) > float(i) + 0.1
		var m: ShaderMaterial = _seg_mats[i]
		var blink := 1.0
		if h > 0.82 and lit:
			blink = 0.55 + 0.45 * sin(_t * 16.0)
		m.set_shader_parameter("energy", (3.5 if lit else 0.2) * blink)
	# Vent flaps: open with the vent (a little at high heat), shaking open.
	var open := 1.0 if venting else smoothstep(0.75, 1.0, h) * 0.25
	for f: Array in _flaps:
		var hinge: Node3D = f[0]
		var sx := float(f[1])
		var cur := hinge.rotation.z
		var want := sx * open * 0.9
		hinge.rotation.z = lerpf(cur, want, 1.0 - exp(-14.0 * delta))


func _make_steam() -> CPUParticles3D:
	var cp := CPUParticles3D.new()
	cp.top_level = true
	# (World space right next to the eye: small, slow and short-lived, or it fills the screen.)
	cp.amount = 18
	cp.lifetime = 0.5
	cp.local_coords = false
	cp.emitting = false
	cp.spread = 25.0
	cp.initial_velocity_min = 0.2
	cp.initial_velocity_max = 0.55
	cp.damping_min = 0.6
	cp.damping_max = 1.0
	cp.scale_amount_min = 0.6
	cp.scale_amount_max = 1.5
	var q := QuadMesh.new()
	q.size = Vector2.ONE * 0.03
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	cp.mesh = q
	var gr := Gradient.new()
	gr.set_color(0, Color(0.92, 0.94, 0.97, 0.35))
	gr.set_color(1, Color(0.85, 0.88, 0.92, 0.0))
	cp.color_ramp = gr
	add_child(cp)
	return cp


func _update_steam(_delta: float, on: bool) -> void:
	if _steam.is_empty() or player == null:
		return
	var want := on and (venting or (heat_frac() > 0.85 and not beaming and not slotting))
	var cam: Camera3D = player.camera
	var cb := cam.global_transform.basis
	for i in _steam.size():
		var cp: CPUParticles3D = _steam[i]
		var src: Node3D = _vent_l if i == 0 else _vent_r
		if want and src != null and src.is_inside_tree():
			cp.global_position = VM.vm_to_world(cam, src.global_position)
			cp.direction = (cb.x * (-0.5 if i == 0 else 0.5) + cb.y * 0.8).normalized()
			cp.gravity = cb.y * 0.25
		if cp.emitting != want:
			cp.emitting = want


func _pose_extra() -> Transform3D:
	var k := _fire_w
	return Transform3D(Basis.from_euler(Vector3(0.01 * k, 0.0, -0.015 * k)), Vector3(-0.004 * k, 0.002 * k, 0.012 * k))


func _hip_sway() -> float:
	return 1.35


# =================================================================================================
# Model
# =================================================================================================

## First-person model, the arsenal's white / orange / gunmetal kit: a pistol grip with a power pack
## behind it, a gunmetal receiver with white side plates, a heat gauge (6 segments) on the left, a
## glass plasma chamber with a glowing core on top, louvred vent flaps either side (open on a vent,
## steam), then four copper coils with glowing inner rings in a cage of three rods, a ceramic nozzle
## with a sooty lip and the emitter; a vertical fore-grip under the coils for the left hand.
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	var rubber := VM.rubber()
	var gunm := VM.mat(Color(0.22, 0.23, 0.25), 0.42, 0.75)
	var copper := VM.mat(Color(0.74, 0.43, 0.22), 0.32, 0.9)
	var ceramic := VM.mat(Color(0.8, 0.78, 0.74), 0.55, 0.05)
	var soot := VM.mat(Color(0.1, 0.095, 0.09), 0.8, 0.2)
	_coil_mat = VM.glow(COIL_COLD, 0.3)
	_chamber_mat = VM.glow(GLOW, 1.0)
	_tip_mat = VM.glow(Color(1.0, 0.95, 0.9), 0.4)
	_seg_mats.clear()
	_flaps.clear()
	var by := BORE_Y
	# Grip, trigger and guard.
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.02, -0.02), Vector3(0, -0.02, -0.07), 0.0045, steel)
	VM.capsule(_gun, Vector3(0, -0.02, -0.07), Vector3(0, 0.014, -0.082), 0.0045, steel)
	# Power pack behind the grip: a white shell, an orange band, a dark cap.
	VM.soft_box(_gun, Vector3(0, 0.052, 0.06), Vector3(0.056, 0.07, 0.1), 0.012, white)
	VM.box(_gun, Vector3(0, 0.052, 0.035), Vector3(0.058, 0.072, 0.012), orange)
	VM.seg(_gun, Vector3(0, 0.052, 0.108), Vector3(0, 0.052, 0.12), 0.026, 0.018, dark)
	# Receiver: gunmetal with white side plates and a dark top deck.
	VM.soft_box(_gun, Vector3(0, 0.05, -0.065), Vector3(0.062, 0.074, 0.16), 0.01, gunm)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0312 * sx, 0.056, -0.04), Vector3(0.003, 0.034, 0.09), white)
	VM.box(_gun, Vector3(0, 0.088, -0.065), Vector3(0.046, 0.004, 0.15), dark)
	# Heat gauge on the left side (lit with the heat).
	VM.box(_gun, Vector3(-0.0338, 0.076, -0.07), Vector3(0.003, 0.014, 0.104), soot)
	for i in 6:
		var sm := VM.glow(PlasmaHud.heat_col(float(i) / 5.0), 0.2)
		_seg_mats.append(sm)
		VM.box(_gun, Vector3(-0.0354, 0.076, -0.028 - i * 0.017), Vector3(0.0015, 0.008, 0.013), sm)
	# Plasma chamber on top: steel caps, the glowing core in a glass tube, two clamps, the posts.
	var cy := 0.106
	VM.seg(_gun, Vector3(0, cy, 0.02), Vector3(0, cy, 0.008), 0.017, 0.017, steel)
	VM.seg(_gun, Vector3(0, cy, -0.13), Vector3(0, cy, -0.142), 0.017, 0.017, steel)
	VM.seg(_gun, Vector3(0, cy, 0.008), Vector3(0, cy, -0.13), 0.0055, 0.0055, _chamber_mat, 10)
	var gl := VM.seg(_gun, Vector3(0, cy, 0.008), Vector3(0, cy, -0.13), 0.0145, 0.0145, VM.glass(Color(0.55, 0.75, 1.0, 0.18)), 18)
	gl.set_meta("no_bake", true)
	for z in [-0.035, -0.09]:
		VM.ring(_gun, Vector3(0, cy, z), Vector3.FORWARD, 0.0165, 0.004, dark)
	for z in [0.014, -0.136]:
		VM.box(_gun, Vector3(0, (0.09 + cy) * 0.5, z), Vector3(0.012, cy - 0.09, 0.01), dark)
	# Vent flaps either side, hinged at their top edge (steam leaves at _vent_l / _vent_r).
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0318 * sx, 0.03, -0.11), Vector3(0.002, 0.03, 0.044), soot)
		var hinge := VM.node(_gun, Vector3(0.033 * sx, 0.046, -0.11))
		for j in 3:
			VM.box(hinge, Vector3(0.0015 * sx, -0.006 - j * 0.0095, 0.0), Vector3(0.003, 0.008, 0.042), dark)
		_flaps.append([hinge, sx])
	_vent_l = VM.node(_gun, Vector3(-0.042, 0.03, -0.11))
	_vent_r = VM.node(_gun, Vector3(0.042, 0.03, -0.11))
	# Coils: a dark core tube, four copper windings with glowing inner rings, a cage of three rods.
	VM.seg(_gun, Vector3(0, by, -0.145), Vector3(0, by, -0.288), 0.021, 0.021, dark)
	for j in 4:
		var z := -0.166 - j * 0.032
		VM.ring(_gun, Vector3(0, by, z), Vector3.FORWARD, 0.033, 0.009, copper)
		VM.ring(_gun, Vector3(0, by, z), Vector3.FORWARD, 0.0345, 0.0022, _coil_mat)
	for j in 3:
		var a := PI * 0.5 + TAU * float(j) / 3.0
		var o := Vector3(cos(a) * 0.041, sin(a) * 0.041, 0.0)
		VM.capsule(_gun, Vector3(0, by, -0.142) + o, Vector3(0, by, -0.29) + o, 0.0032, steel, 8)
	VM.ring(_gun, Vector3(0, by, -0.143), Vector3.FORWARD, 0.045, 0.006, orange)
	VM.ring(_gun, Vector3(0, by, -0.29), Vector3.FORWARD, 0.045, 0.006, dark)
	# Nozzle: a ceramic cone, a sooty lip, the emitter.
	VM.seg(_gun, Vector3(0, by, -0.292), Vector3(0, by, -0.335), 0.026, 0.013, ceramic, 18)
	VM.ring(_gun, Vector3(0, by, -0.334), Vector3.FORWARD, 0.0135, 0.003, soot)
	VM.ring(_gun, Vector3(0, by, -0.336), Vector3.FORWARD, 0.0095, 0.0025, _tip_mat)
	VM.sphere(_gun, Vector3(0, by, -0.333), 0.0065, _tip_mat)
	_muzzle = VM.node(_gun, Vector3(0, by, -0.342))
	# Fore-grip under the coils (the left hand: grip_left above).
	VM.box(_gun, Vector3(0, 0.014, -0.2), Vector3(0.02, 0.026, 0.036), dark)
	VM.capsule(_gun, Vector3(0, -0.06, -0.192), Vector3(0, 0.0, -0.2), 0.0165, rubber)
	VM.seg(_gun, Vector3(0, -0.085, -0.19), Vector3(0, -0.072, -0.191), 0.019, 0.018, orange)
	# Hand anchors (the hands rig).
	grip_point = VM.node(_gun, Vector3.ZERO)
	grip_point.name = "PistolGrip"
	trigger_point = VM.node(_gun, Vector3(0, 0.0, -0.034))
	trigger_point.name = "Trigger"
	left_grip = VM.node(_gun, Vector3(0, 0.004, -0.196), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	left_grip.name = "LeftGrip"
	var skip: Array = [_muzzle, left_grip, grip_point, trigger_point, _vent_l, _vent_r]
	for f: Array in _flaps:
		skip.append(f[0])
	VM.bake(_gun, skip)
	for f: Array in _flaps:
		VM.bake(f[0])
	return model


# =================================================================================================
# Third-person model (the player's body, remote avatars)
# =================================================================================================

func _build_tp(p: Node3D) -> Node3D:
	return build_tp_model(p)


## Simplified model under prop root `p` (grip at the origin, -Z forward). Returns the emitter node.
static func build_tp_model(p: Node3D) -> Node3D:
	var white := _mat3(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _mat3(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _mat3(Color(0.14, 0.15, 0.17), 0.35, 0.7)
	var copper := _mat3(Color(0.74, 0.43, 0.22), 0.32, 0.9)
	var ceramic := _mat3(Color(0.8, 0.78, 0.74), 0.55, 0.05)
	var glow := _mat3(GLOW, 0.4, 0.0)
	glow.emission_enabled = true
	glow.emission = GLOW
	glow.emission_energy_multiplier = 2.5
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.052, 0.06), Vector3(0.056, 0.07, 0.1), white)
	VM.box(p, Vector3(0, 0.052, 0.035), Vector3(0.058, 0.072, 0.012), orange)
	VM.box(p, Vector3(0, 0.05, -0.065), Vector3(0.062, 0.074, 0.16), dark)
	VM.seg(p, Vector3(0, 0.106, 0.01), Vector3(0, 0.106, -0.14), 0.015, 0.015, glow, 8)
	VM.seg(p, Vector3(0, BORE_Y, -0.145), Vector3(0, BORE_Y, -0.29), 0.024, 0.024, dark, 10)
	for j in 4:
		VM.ring(p, Vector3(0, BORE_Y, -0.166 - j * 0.032), Vector3.FORWARD, 0.036, 0.011, copper)
	VM.ring(p, Vector3(0, BORE_Y, -0.215), Vector3.FORWARD, 0.0375, 0.004, glow)
	VM.seg(p, Vector3(0, BORE_Y, -0.29), Vector3(0, BORE_Y, -0.335), 0.026, 0.013, ceramic, 10)
	VM.capsule(p, Vector3(0, -0.06, -0.192), Vector3(0, 0.0, -0.2), 0.017, dark)
	return VM.node(p, Vector3(0, BORE_Y, -0.345))


static func _mat3(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m
