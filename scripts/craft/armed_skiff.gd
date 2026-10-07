extends "res://scripts/craft/skiff.gd"
## "Silahlı Mekik": the Mekik (skiff.gd) with guns. The same pod, flight model, cockpit, cameras,
## seat / damage / multiplayer APIs; heavier (240 hp, ~12 % slower, ~15 % slower to turn), in a dark
## olive armour livery with yellow / black hazard stripes and "SM-0N" lettering (skiff_build.gd
## "armed" mesh set: chin guns, rocket pods).
##
## Build contract (scripts/war/build_tool.gd entry "armed_skiff"): GDScript does not let a subclass
## redeclare its parent's BUILD_COST / DISPLAY_NAME / HP_MAX, so the variant's values are
## ARMED_BUILD_COST / ARMED_NAME / ARMED_HP and static build_info() -> {"cost", "name", "hp"};
## static footprint() (wider: the pods, longer: the barrels), place(body, xf), team as the Mekik.
##
## Weapons (seated pilot):
##   LMB  twin rotary cannon under the nose: the barrels spin up (~0.2 s) then fire 14 rounds/s,
##        alternating sides; fast tracer rounds (260 m/s + the ship's velocity, gravity drop) aimed at
##        the boresight 250 m ahead. Hits deal GUN_DAMAGE through Game.damage_target (bots, players,
##        structures, skiffs, torpedoes: anything "damageable" a physics / density ray reaches) and
##        burst enemy shells / rockets passing within SHELL_KILL_R (shot_down). No ammo: heat. Each
##        round heats the barrels; at 100 % they lock (AŞIRI ISINDI) until cooled to 30 %. The dash
##        shows TOP ISISI, the barrels glow.
##   RMB  rocket salvo: the 4 rockets in the pods (0.13 s apart, alternating pods), unguided, the
##        Roketatar's rockets (scripts/items/rockets.gd launch(): group "war_rocket", flak can shoot
##        them, the Kinetik İtici deflects them; Explosion.spawn + planet crater, CRATER_SCALE
##        applies). ROCKET_COST m³ of material each (a human pilot); then a ROCKET_RELOAD s reload.
##   Free look moves to Alt held or the middle mouse button (RMB fires rockets).
##   Gunsight (2D, the ship's overlay layer): the boresight ring with the heat arc and rocket
##   ticks, a lead pip on the nearest enemy in front (its velocity, ours, the drop), a bracket on it.
##   Recoil shake, muzzle flashes (a light under the nose; the flash cards outside), sounds on the
##   Skiff bus (hull-muffled inside, silent in vacuum outside).
## Multiplayer: every shot fired here emits weapon_fired(kind, pos, vel) ("gun" per round, "rocket"
## per rocket); the other machine replays it on its copy of this skiff with net_fire(kind, pos, vel).
## Damage is host-authoritative: rounds and rockets deal damage only where not Net.is_client() (the
## host's replay of a client's shot is the real one; Explosion.spawn skips damage on clients).
## AI: a bot flies it (skiff.gd "AI pilot", the rival's raids): the "AI gunner" section picks targets,
## flies attack runs and pulls the same triggers (_ai_trig / _ai_salvo into _weapons_step). The
## rival's copy wears "rival_armed" (gunmetal, red / black hazard stripes, "RK-0N").

const HitFeel := preload("res://scripts/items/hit_feel.gd")
const Rockets := preload("res://scripts/items/rockets.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Rifle := preload("res://scripts/items/rifle.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

const ARMED_BUILD_COST := 600.0
const ARMED_NAME := "Silahlı Mekik"
const ARMED_HP := 240.0
const ARMED_MASS := 1150.0
const ARMED_SPEED_K := 0.88          # cruise ~19 m/s, boost ~31 m/s
const ARMED_AGILITY_K := 0.85
# --- Rotary cannon ---------------------------------------------------------------------------------
const GUN_RATE := 14.0               # rounds / s (both guns)
const GUN_SPEED := 260.0             # m/s off the muzzle (+ the ship's velocity)
const GUN_DAMAGE := 9.0
const GUN_IMPULSE := 2.5
const GUN_SPREAD := 0.0045           # rad
const GUN_LIFE := 1.8                # s (~470 m)
const GUN_SPINUP := 0.18
const GUN_CONVERGE := 250.0          # m: the barrels meet the boresight here
const HEAT_PER_ROUND := 0.042        # ~24 rounds (1.7 s) from cold to locked
const HEAT_COOL := 0.38              # /s after a short pause...
const HEAT_COOL_LOCKED := 0.5        # ...and while locked
const HEAT_RESUME := 0.3
const SHELL_KILL_R := 1.3
const TRACER_POOL := 48
# --- Rockets ---------------------------------------------------------------------------------------
const SALVO := 4
const SALVO_GAP := 0.13
const ROCKET_RELOAD := 4.5
const ROCKET_COST := 4.0             # m³ of material per rocket
const ROCKET_LAUNCH := 38.0          # m/s off the tube (+ the ship's velocity; the motor does the rest)
const ROCKET_CFG := {"radius": 3.6, "damage": 95.0, "direct": 40.0, "impulse": 10.0, "crater": 1.6, "self_mult": 0.5}
# --- Gunsight --------------------------------------------------------------------------------------
const SIGHT_RANGE := 420.0
const SIGHT_CONE := 0.4              # rad: targets within this of the nose get the lead pip

## A shot fired here (multiplayer replays it with net_fire on the other machine).
signal weapon_fired(kind: String, pos: Vector3, vel: Vector3)

static var _rocket_mgr: Node3D
static var _tracer_mat: StandardMaterial3D
static var _flash_mat: StandardMaterial3D
static var _tracer_mesh: BoxMesh
static var _mg: AudioStream

var heat := 0.0
var overheated := false
var rockets_left := SALVO
var lead_pip := Vector3.INF          # where to put the boresight (world), INF = no target
var sight_target: Node3D = null

var _spin := 0.0
var _spin_ang := 0.0
var _gun_acc := 0.0
var _gun_side := 0
var _idle_t := 0.0
var _salvo_left := 0
var _salvo_t := 0.0
var _reload_t := 0.0
var _rounds: Array = []              # {"p", "v", "t", "mi", "owned"}
var _pool: Array = []                # idle tracer MeshInstance3Ds
var _barrels: Array = []
var _flashes: Array = []             # [MeshInstance3D, time left]
var _flash_light: OmniLight3D
var _flash_e := 0.0
var _tips: Array = []
var _barrel_mat: StandardMaterial3D
var _snd: Array = []
var _snd_i := 0
var _spin_snd: AudioStreamPlayer3D
var _fx_t := 0.0
var _scan_t := 0.0
var _tgt_prev := Vector3.ZERO
var _tgt_vel := Vector3.ZERO


func _init() -> void:
	hp = ARMED_HP
	hp_max = ARMED_HP
	speed_k = ARMED_SPEED_K
	agility_k = ARMED_AGILITY_K


func _ready() -> void:
	super._ready()
	mass = ARMED_MASS


## Wider than the Mekik (the rocket pods) and longer (the barrels).
static func footprint() -> Vector3:
	return Vector3(1.5, 1.02, 2.65)


## The build-menu entry's values (scripts/war/build_tool.gd).
static func build_info() -> Dictionary:
	return {"cost": ARMED_BUILD_COST, "name": ARMED_NAME, "hp": ARMED_HP}


func _livery() -> String:
	return "rival_armed" if team == "rival" else "armed"


func _registration() -> String:
	return super._registration() if team == "rival" else "SM-01"


func hud_name() -> String:
	return ARMED_NAME


func get_interact_prompt() -> String:
	return super.get_interact_prompt().replace("Mekiğe bin", "Silahlı Mekiğe bin")


func _free_look_held() -> bool:
	return Input.is_physical_key_pressed(KEY_ALT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)


func hint_text() -> String:
	if landed:
		return "BOŞLUK / W kalk  ·  Sol tık top  ·  Sağ tık roket  ·  Alt / orta tık bak  ·  V kamera  ·  L ışık  ·  F in"
	if _hint_t > 0.0:
		return "Fare yön  ·  W/S itki  ·  A/D dön  ·  Q/E yana  ·  Boşluk/Ctrl  ·  Shift takviye  ·  Sol tık top  ·  Sağ tık roket  ·  Alt bak"
	return ""


# ==================================================================================================
# Construction
# ==================================================================================================

func _build_extra() -> void:
	var ms := Build.meshes(_livery())
	_mesh(ms["weapons"], _mat_ext, true, 1 | VIS_HULL)
	_barrel_mat = StandardMaterial3D.new()
	_barrel_mat.albedo_color = Color(0.36, 0.37, 0.39)
	_barrel_mat.metallic = 0.35
	_barrel_mat.roughness = 0.38
	_barrel_mat.emission_enabled = true
	_barrel_mat.emission = Color(1.0, 0.36, 0.08)
	_barrel_mat.emission_energy_multiplier = 0.0
	_ensure_shared()
	for sx: float in [-1.0, 1.0]:
		var piv := Node3D.new()
		piv.position = Vector3(sx * Build.GUN_X, Build.GUN_Y, Build.GUN_PIVOT_Z)
		_visual.add_child(piv)
		var bm := MeshInstance3D.new()
		bm.mesh = ms["barrels"]
		bm.material_override = _barrel_mat
		bm.layers = 1 | VIS_HULL
		piv.add_child(bm)
		_barrels.append(piv)
		var fl := MeshInstance3D.new()
		fl.mesh = ms["flash"]
		fl.material_override = _flash_mat
		fl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fl.position = Vector3(sx * Build.GUN_X, Build.GUN_Y, Build.GUN_MUZZLE_Z)
		fl.visible = false
		_visual.add_child(fl)
		_flashes.append([fl, 0.0])
	for i in SALVO:
		var tip := MeshInstance3D.new()
		tip.mesh = Build.rocket_tip_mesh()
		tip.material_override = _mat_ext
		tip.position = _tube_local(i) + Vector3(0.0, 0.0, 0.02)
		_visual.add_child(tip)
		_tips.append(tip)
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.72, 0.38)
	_flash_light.omni_range = 5.0
	_flash_light.light_energy = 0.0
	_flash_light.visible = false
	_flash_light.light_cull_mask = 0xFFFFF & ~VIS_CABIN       # the cabin does not strobe
	_flash_light.position = Vector3(0.0, Build.GUN_Y + 0.05, Build.GUN_MUZZLE_Z - 0.2)
	_visual.add_child(_flash_light)
	# Collision for the pods and the gun housings (bullets / blasts find them).
	var along := Basis(Vector3.RIGHT, PI * 0.5)
	for sx: float in [-1.0, 1.0]:
		_capsule(Build.POD_R + 0.01, 1.3, Transform3D(along, Vector3(sx * Build.POD_X, Build.POD_Y, -0.32)))
	var gb := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.8, 0.16, 0.5)
	gb.shape = bs
	gb.position = Vector3(0.0, Build.GUN_Y, -1.95)
	add_child(gb)
	# Tracer pool (world space).
	for i in TRACER_POOL:
		var mi := MeshInstance3D.new()
		mi.mesh = _tracer_mesh
		mi.material_override = _tracer_mat
		mi.top_level = true
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_pool.append(mi)
	# Gun sounds on the Skiff bus (skiff_audio.gd: muffled through the hull, silent in vacuum).
	if _mg == null:
		_mg = Snd.rand("weap/mg", 1.06, 1.5)
	for i in 6:
		var p := AudioStreamPlayer3D.new()
		p.bus = SkiffAudio.BUS
		p.unit_size = 14.0
		p.max_distance = 400.0
		p.position = Vector3(0.0, Build.GUN_Y, -2.2)
		add_child(p)
		_snd.append(p)
	_spin_snd = AudioStreamPlayer3D.new()
	_spin_snd.stream = Snd.loop("shuttle/servo_loop")
	_spin_snd.bus = SkiffAudio.BUS
	_spin_snd.unit_size = 8.0
	_spin_snd.volume_db = -80.0
	_spin_snd.position = Vector3(0.0, Build.GUN_Y, -1.9)
	add_child(_spin_snd)
	if _spin_snd.stream != null:
		_spin_snd.play()
		_spin_snd.stream_paused = true
	var sight := Sight.new()
	sight.ship = self
	_overlay_layer.add_child(sight)


static func _ensure_shared() -> void:
	if _tracer_mat == null:
		_tracer_mat = StandardMaterial3D.new()
		_tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_tracer_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_tracer_mat.albedo_color = Color(2.2, 1.35, 0.5, 0.85)
		_tracer_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_tracer_mesh = BoxMesh.new()
		_tracer_mesh.size = Vector3(0.04, 0.04, 1.0)
	if _flash_mat == null:
		_flash_mat = StandardMaterial3D.new()
		_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_flash_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_flash_mat.albedo_texture = DigFx.soft_texture()
		_flash_mat.albedo_color = Color(1.9, 1.25, 0.6, 1.0)


## Tube i (0..3, the firing order: left top, right top, left bottom, right bottom) in the ship frame.
static func _tube_local(i: int) -> Vector3:
	var sx := -1.0 if i % 2 == 0 else 1.0
	var t: Vector2 = Build.POD_TUBES[mini(i / 2, Build.POD_TUBES.size() - 1)]
	return Vector3(sx * Build.POD_X + t.x, Build.POD_Y + t.y, Build.POD_Z0)


# ==================================================================================================
# Firing (local pilot)
# ==================================================================================================

func _weapons_input(event: InputEvent) -> bool:
	# The fire buttons belong to the guns while seated (nothing else should react to them).
	if event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var bi := (event as InputEventMouseButton).button_index
		return bi == MOUSE_BUTTON_LEFT or bi == MOUSE_BUTTON_RIGHT
	return false


func _weapons_step(delta: float) -> void:
	var trigger := false
	var salvo := false
	if pilot != null and not Game.ui_panel_open() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		trigger = Input.is_action_pressed("tool_use")
		salvo = Input.is_action_pressed("tool_alt")
	elif pilot == null and _bot != null:
		trigger = _ai_trig                 # a bot flies it: the AI gunner (end of file)
		salvo = _ai_salvo
	_ai_trig = false
	_ai_salvo = false
	_gun_step(delta, trigger)
	_rocket_step(delta, salvo)


func _gun_step(delta: float, trigger: bool) -> void:
	var want := trigger and not overheated
	_idle_t = 0.0 if want else _idle_t + delta
	_spin = move_toward(_spin, 1.0 if want else 0.0, delta / (GUN_SPINUP if want else 0.7))
	if want and _spin >= 0.999:
		_gun_acc += delta * GUN_RATE
		while _gun_acc >= 1.0:
			_gun_acc -= 1.0
			_fire_round()
			heat = minf(heat + HEAT_PER_ROUND, 1.0)
			if heat >= 1.0:
				_lock_guns()
				break
	else:
		_gun_acc = 0.0
	if overheated:
		heat = maxf(heat - HEAT_COOL_LOCKED * delta, 0.0)
		if heat <= HEAT_RESUME:
			overheated = false
			if pilot != null and Game.sfx:
				Game.sfx.play("ding", -14.0, 1.3)
	elif _idle_t > 0.25:
		heat = maxf(heat - HEAT_COOL * delta, 0.0)


func _lock_guns() -> void:
	overheated = true
	_spin = minf(_spin, 0.6)
	if pilot != null:
		_flash("TOP AŞIRI ISINDI — soğuyor")
		if Game.sfx:
			Game.sfx.play("error", -10.0, 0.9)
	_audio.shot("shuttle/hiss_loop", -12.0, 1.25, Vector3(0.0, Build.GUN_Y, -2.1))


func _fire_round() -> void:
	var side := _gun_side
	_gun_side = 1 - _gun_side
	var sx := -1.0 if side == 0 else 1.0
	var xf := global_transform.orthonormalized()
	var muzzle := xf * Vector3(sx * Build.GUN_X, Build.GUN_Y, Build.GUN_MUZZLE_Z)
	var nose := -xf.basis.z
	var conv := xf * Build.EYE + nose * GUN_CONVERGE
	var dir := (conv - muzzle).normalized()
	var b := Build._basis_y(dir)
	var a := randf() * TAU
	dir = (dir + (b.x * cos(a) + b.z * sin(a)) * randf() * GUN_SPREAD).normalized()
	var vel := dir * GUN_SPEED + (Vector3.ZERO if freeze else linear_velocity)
	_spawn_round(muzzle, vel, true)
	weapon_fired.emit("gun", muzzle, vel)
	_muzzle_fx(side)
	_gun_sound()
	_shake = minf(_shake + 0.012, 0.32)
	_jolt += Vector3(0.0, 0.0, 0.004)


func _rocket_step(delta: float, salvo: bool) -> void:
	if _reload_t > 0.0:
		_reload_t -= delta
		if _reload_t <= 0.0:
			rockets_left = SALVO
			for t: Node3D in _tips:
				t.visible = true
			_audio.gear()
	if salvo and _salvo_left == 0 and rockets_left > 0 and _reload_t <= 0.0:
		_salvo_left = rockets_left
		_salvo_t = 0.0
	if _salvo_left > 0:
		_salvo_t -= delta
		if _salvo_t <= 0.0:
			_salvo_t = SALVO_GAP
			if pilot != null and not Game.spend_material(ROCKET_COST):
				_flash("Roket için malzeme yok (%d m³)" % int(ROCKET_COST))
				if Game.sfx:
					Game.sfx.play("error", -10.0)
				_salvo_left = 0
			else:
				_fire_rocket()
				_salvo_left -= 1
	if _salvo_left == 0 and rockets_left < SALVO and _reload_t <= 0.0:
		_reload_t = ROCKET_RELOAD


func _fire_rocket() -> void:
	var i := SALVO - rockets_left
	rockets_left -= 1
	var xf := global_transform.orthonormalized()
	var p := xf * (_tube_local(i) + Vector3(0.0, 0.0, -0.12))
	var nose := -xf.basis.z
	var aim := xf * Build.EYE + nose * 150.0
	var vel := (aim - p).normalized() * ROCKET_LAUNCH + (Vector3.ZERO if freeze else linear_velocity)
	_launch_rocket(p, vel, true)
	weapon_fired.emit("rocket", p, vel)
	if i < _tips.size():
		(_tips[i] as Node3D).visible = false
	# Backblast out of the pod's tail, a flash, a kick.
	var tail := xf * (_tube_local(i) + Vector3(0.0, 0.0, 1.35))
	Rockets.puff(get_parent(), tail, xf.basis.z, {"amount": 10, "life": 1.2, "vmin": 2.0, "vmax": 5.0, "spread": 25.0,
			"size": 0.7, "scale": [0.5, 1.4, 2.4], "ramp": [[0.0, Color(0.85, 0.83, 0.8, 0.0)], [0.1, Color(0.85, 0.83, 0.8, 0.5)],
			[1.0, Color(0.9, 0.9, 0.9, 0.0)]], "gravity": -Game.gravity_at(tail) * 0.05})
	_flash_e = maxf(_flash_e, 3.0)
	_shake = minf(_shake + 0.07, 0.4)
	_jolt += Vector3(0.0, 0.0, 0.012)


func _launch_rocket(p: Vector3, vel: Vector3, owned: bool) -> void:
	var mgr := _rockets()
	if mgr == null:
		return
	var cfg: Dictionary = ROCKET_CFG.duplicate()
	var mine: bool = owned and pilot != null and pilot == Game.player
	cfg["player_owned"] = mine
	mgr.call("launch", p, vel, team, cfg, [get_rid()], pilot if mine else null)
	_audio.shot("weap/launch", -6.0, randf_range(1.05, 1.15), Vector3(0.0, Build.POD_Y, -0.9), true)


## One rockets.gd manager for every armed skiff, in the scene (rockets outlive their skiff).
func _rockets() -> Node3D:
	if _rocket_mgr != null and is_instance_valid(_rocket_mgr) and _rocket_mgr.is_inside_tree():
		return _rocket_mgr
	var scene := get_tree().current_scene
	if scene == null:
		return null
	_rocket_mgr = Rockets.new()
	_rocket_mgr.name = "SkiffRockets"
	scene.add_child(_rocket_mgr)
	return _rocket_mgr


## Multiplayer: a shot this skiff fired on the other machine (its weapon_fired), replayed here.
## The host's replay deals the damage; a client's is the look only.
func net_fire(kind: String, pos: Vector3, vel: Vector3) -> void:
	if destroyed:
		return
	match kind:
		"gun":
			_spawn_round(pos, vel.limit_length(GUN_SPEED + 80.0), false)
			var lp := global_transform.affine_inverse() * pos
			_muzzle_fx(0 if lp.x < 0.0 else 1)
			_gun_sound()
			_spin = 1.0
			_idle_t = 0.0
		"rocket":
			_launch_rocket(pos, vel.limit_length(120.0), false)
			for t: Node3D in _tips:
				if t.visible:
					t.visible = false
					break


# ==================================================================================================
# Rounds in flight
# ==================================================================================================

func _spawn_round(p: Vector3, v: Vector3, owned: bool) -> void:
	var mi: MeshInstance3D = _pool.pop_back() if not _pool.is_empty() else null
	if mi == null:
		# Pool exhausted: recycle the oldest round.
		var old: Dictionary = _rounds.pop_front()
		mi = old["mi"]
	_rounds.append({"p": p, "v": v, "t": 0.0, "mi": mi, "owned": owned})


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not _rounds.is_empty():
		_step_rounds(delta)


func _step_rounds(delta: float) -> void:
	var space := get_world_3d().direct_space_state
	var ex: Array = [get_rid()]
	var threats: Array = []
	if not Net.is_client():
		for s in get_tree().get_nodes_in_group("war_shell") + get_tree().get_nodes_in_group("war_rocket"):
			if s is Node3D and is_instance_valid(s) and Game.team_of(s) != team and s.has_method("shot_down"):
				threats.append(s)
	for i in range(_rounds.size() - 1, -1, -1):
		var r: Dictionary = _rounds[i]
		var p: Vector3 = r["p"]
		var v: Vector3 = r["v"]
		var g := Game.gravity_at(p)
		var np := p + v * delta + g * (0.5 * delta * delta)
		var hit := Ballistics.segment_hit(p, np, space, ex)
		if not hit.is_empty():
			_round_hit(r, hit, (np - p).normalized())
			_release(i)
			continue
		for s: Node3D in threats:
			if not is_instance_valid(s) or (s.has_method("is_live") and not bool(s.call("is_live"))):
				continue
			var sp := s.global_position
			var ab := np - p
			var tt := clampf((sp - p).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
			if (p + ab * tt).distance_to(sp) < SHELL_KILL_R:
				s.call("shot_down", sp)
				_impact_fx(sp, -ab.normalized(), true)
				r["t"] = GUN_LIFE
				break
		r["p"] = np
		r["v"] = v + g * delta
		r["t"] = float(r["t"]) + delta
		if float(r["t"]) >= GUN_LIFE:
			_release(i)


func _release(i: int) -> void:
	var mi: MeshInstance3D = _rounds[i]["mi"]
	mi.visible = false
	_pool.append(mi)
	_rounds.remove_at(i)


func _round_hit(r: Dictionary, hit: Dictionary, dir: Vector3) -> void:
	var pos: Vector3 = hit["position"]
	var n: Vector3 = hit["normal"]
	var col = hit.get("body")
	var t: Node = Game.damageable_of(col) if col is Object else null
	if t != null and t != self and not Net.is_client():
		var res := Game.damage_target(t, GUN_DAMAGE, pos - dir * 6.0, dir * GUN_IMPULSE, team)
		if bool(r["owned"]) and pilot != null and pilot == Game.player and not res.is_empty():
			HitFeel.inst().target_hit(t, res, GUN_DAMAGE, pos, {"big": 0.15, "weapon": ARMED_NAME})
	_impact_fx(pos, n, t != null)


## A small burst where a round lands: sparks on a body, dust on the ground (throttled).
func _impact_fx(pos: Vector3, n: Vector3, metal: bool) -> void:
	if _fx_t > 0.0:
		return
	_fx_t = 0.05
	var parent := get_parent()
	var g := Game.gravity_at(pos)
	if metal:
		Rockets.puff(parent, pos, n, {"amount": 10, "life": 0.35, "vmin": 3.0, "vmax": 9.0, "spread": 60.0, "size": 0.12,
				"damp": 2.0, "add": true, "gravity": g * 0.6, "scale": [1.0, 0.8, 0.3],
				"ramp": [[0.0, Color(1.0, 0.9, 0.6, 1.0)], [1.0, Color(1.0, 0.45, 0.15, 0.0)]], "color": Color(2.0, 2.0, 2.0)})
	else:
		var gc := Rifle.ground_color(pos, n)
		Rockets.puff(parent, pos, n, {"amount": 8, "life": 0.9, "vmin": 1.0, "vmax": 3.5, "spread": 35.0, "size": 0.45,
				"damp": 2.5, "gravity": g * 0.3, "scale": [0.4, 1.0, 1.6],
				"ramp": [[0.0, Color(gc, 0.0)], [0.12, Color(gc, 0.7)], [1.0, Color(gc.lightened(0.15), 0.0)]]})
	if Game.sfx:
		Game.sfx.play_at("impact_light", pos, -13.0, randf_range(0.95, 1.25), 6.0)


# ==================================================================================================
# Effects, sound, gunsight target
# ==================================================================================================

func _muzzle_fx(side: int) -> void:
	if side < _flashes.size():
		var f: Array = _flashes[side]
		f[1] = 0.045
		var mi: MeshInstance3D = f[0]
		mi.visible = true
		mi.rotation.z = randf() * TAU
		mi.scale = Vector3.ONE * randf_range(0.75, 1.15)
	_flash_e = maxf(_flash_e, 2.2)


func _gun_sound() -> void:
	if _mg == null or _snd.is_empty():
		return
	var gate: float = float(_audio.get("_gate")) if _audio != null else 1.0
	if gate < 0.05:
		return
	var p: AudioStreamPlayer3D = _snd[_snd_i]
	_snd_i = (_snd_i + 1) % _snd.size()
	p.stream = _mg
	p.volume_db = -5.0 + linear_to_db(maxf(gate, 0.05))
	p.pitch_scale = randf_range(1.12, 1.22)
	p.play()


func _process(delta: float) -> void:
	super._process(delta)
	if destroyed:
		return
	_fx_t = maxf(_fx_t - delta, 0.0)
	# Barrels spin (opposite ways), glow with the heat.
	_spin_ang += _spin * 42.0 * delta
	for i in _barrels.size():
		(_barrels[i] as Node3D).rotation.z = _spin_ang * (1.0 if i == 0 else -1.0)
	_barrel_mat.emission_energy_multiplier = heat * heat * 3.2
	for f: Array in _flashes:
		f[1] = float(f[1]) - delta
		if float(f[1]) <= 0.0:
			(f[0] as Node3D).visible = false
	_flash_e = maxf(_flash_e - delta * 40.0, 0.0)
	_flash_light.light_energy = _flash_e
	_flash_light.visible = _flash_e > 0.02
	if _spin_snd.stream != null:
		var gate: float = float(_audio.get("_gate")) if _audio != null else 1.0
		var lv := _spin * gate
		_spin_snd.volume_db = linear_to_db(maxf(lv, 0.0001)) - 12.0
		_spin_snd.pitch_scale = 0.8 + 0.6 * _spin
		_spin_snd.stream_paused = lv < 0.01
	_draw_tracers()
	_update_sight(delta)


## Tracers: a streak behind each round along its velocity, drawn between physics steps.
func _draw_tracers() -> void:
	var lead := Engine.get_physics_interpolation_fraction() / float(Engine.physics_ticks_per_second)
	for r: Dictionary in _rounds:
		var mi: MeshInstance3D = r["mi"]
		var v: Vector3 = r["v"]
		var sp := v.length()
		if sp < 1.0:
			mi.visible = false
			continue
		var tip: Vector3 = (r["p"] as Vector3) + v * lead
		var ln := minf(sp * 0.028, 7.0) * clampf(float(r["t"]) * 30.0, 0.2, 1.0)
		var d := v / sp
		var b := Basis.looking_at(d, Vector3.UP if absf(d.y) < 0.98 else Vector3.RIGHT)
		mi.global_transform = Transform3D(b.scaled(Vector3(1.0, 1.0, ln)), tip - d * ln * 0.5)
		mi.visible = true


## The nearest enemy in front (bots, players, structures, skiffs, torpedoes) and the lead pip.
func _update_sight(delta: float) -> void:
	if pilot == null:
		lead_pip = Vector3.INF
		sight_target = null
		return
	var xf := global_transform.orthonormalized()
	var eye := xf * Build.EYE
	var nose := -xf.basis.z
	_scan_t -= delta
	if _scan_t <= 0.0:
		_scan_t = 0.12
		var best: Node3D = null
		var best_a := SIGHT_CONE
		for n in get_tree().get_nodes_in_group(Game.DAMAGEABLE):
			if n == self or n == pilot or not (n is Node3D) or not is_instance_valid(n):
				continue
			if Game.team_of(n) == team or (n.has_method("is_dead") and bool(n.call("is_dead"))):
				continue
			var tp := _aim_point(n as Node3D)
			var to := tp - eye
			var d := to.length()
			if d < 3.0 or d > SIGHT_RANGE:
				continue
			var a := nose.angle_to(to)
			if a < best_a:
				best_a = a
				best = n as Node3D
		if best != sight_target:
			sight_target = best
			_tgt_vel = Vector3.ZERO
			if best != null:
				_tgt_prev = _aim_point(best)
	if sight_target == null or not is_instance_valid(sight_target):
		sight_target = null
		lead_pip = Vector3.INF
		return
	var tp2 := _aim_point(sight_target)
	var tv := Vector3.ZERO
	var lv = sight_target.get("linear_velocity")
	var cv = sight_target.get("velocity")
	if lv is Vector3:
		tv = lv
	elif cv is Vector3:
		tv = cv
	else:
		if delta > 0.0:
			_tgt_vel = _tgt_vel.lerp((tp2 - _tgt_prev) / delta, 1.0 - exp(-6.0 * delta))
		tv = _tgt_vel
	_tgt_prev = tp2
	var sv := Vector3.ZERO if freeze else linear_velocity
	var t := eye.distance_to(tp2) / GUN_SPEED
	for k in 2:
		t = eye.distance_to(tp2 + (tv - sv) * t) / GUN_SPEED
	lead_pip = tp2 + (tv - sv) * t - Game.gravity_at(tp2) * (0.5 * t * t)


static func _aim_point(n: Node3D) -> Vector3:
	return n.global_position + n.global_transform.basis.y * 0.9


func _dash_extra(d: Dictionary) -> void:
	d["heat"] = heat
	d["overheat"] = overheated
	d["rockets"] = rockets_left
	d["rocket_reload"] = clampf(1.0 - _reload_t / ROCKET_RELOAD, 0.0, 1.0) if _reload_t > 0.0 else 0.0
	d["reg"] = "SİLAHLI MEKİK · SM-01"


# ==================================================================================================
# AI gunner (2026-10-05): a bot flies it (skiff.gd "AI pilot"; tunables: balance.gd "AI pilot and
# skiff raids")
# ==================================================================================================
# _ai_combat is skiff.gd's variant hook, every physics tick of a task (after the phase guidance,
# before the look-ahead and the stick). On the way to an ENEMY planet (CRUISE / APPROACH, hull at
# least AI_ARMED_BREAK_HP, AI_STRIKE_TIME s per sortie) it picks the best target within AI_GUN_RANGE
# (AI_TARGET_W: our Uçaksavar and cannons first, then the player on foot, enemy skiffs, the other
# structures, enemy-team bots) and flies attack runs at it: in toward a point AI_RUN_ALT over it (a
# flying skiff: at it), the nose on the lead point (its velocity, ours, the drop) plus an aim error
# re-rolled every AI_GUN_ERR_TIME; it breaks off at AI_BREAK_DIST (or closing low), extends
# AI_EXTEND_TIME s and comes round again. Guns: bursts of ~0.45-1 s while the nose is within
# AI_FIRE_CONE (+ the target's size), after AI_GUN_REACT s on the target, only with a clear density
# line of sight (never through a planet); the barrels cool from AI_HEAT_HI down to AI_HEAT_LO
# between bursts (it never locks them). Rockets: a full salvo at a structure AI_ROCKET_MIN..MAX m
# off. The shots are the player's own _fire_round / _fire_rocket (weapon_fired: the multiplayer
# replay; damage on the host only). The AI's rockets cost no material (ROCKET_COST is the player's).

const AiBal := preload("res://scripts/war/balance.gd")

var _ai_tgt: Node3D = null
var _ai_scan_t := 0.0
var _ai_trig := false
var _ai_salvo := false
var _ai_burst := 0.0
var _ai_rest := 0.0
var _ai_cool := false
var _ai_err := Vector3.ZERO
var _ai_err_t := 0.0
var _ai_los := false
var _ai_los_t := 0.0
var _ai_track := 0.0
var _ai_tprev := Vector3.INF
var _ai_tv := Vector3.ZERO
var _ai_strike := 0.0
var _ai_out := 0.0
var _ai_sortie := -1


func _ai_combat(delta: float) -> void:
	_ai_engaged = false
	if _ai_sortie != _ai_serial:
		_ai_sortie = _ai_serial
		_ai_strike = 0.0
		_ai_out = 0.0
		_ai_tgt = null
	if not _ai_may_engage():
		_ai_tgt = null
		_ai_burst = 0.0
		return
	_ai_scan_t -= delta
	if _ai_scan_t <= 0.0 or not _ai_valid(_ai_tgt):
		_ai_scan_t = 0.5
		var nt := _ai_pick_target()
		if nt != _ai_tgt:
			_ai_tgt = nt
			_ai_track = 0.0
			_ai_tprev = Vector3.INF
			_ai_tv = Vector3.ZERO
			_ai_los_t = 0.0
			_ai_err_t = 0.0
	if _ai_tgt == null:
		return
	_ai_engaged = true
	_ai_boost = false
	_ai_strike += delta
	_ai_track += delta
	var xf := global_transform.orthonormalized()
	var eye := xf * Build.EYE
	var tp := _aim_point(_ai_tgt)
	# Its velocity: a body's own, else measured.
	var tv := Vector3.ZERO
	var lv = _ai_tgt.get("linear_velocity")
	var cv = _ai_tgt.get("velocity")
	if lv is Vector3:
		tv = lv
	elif cv is Vector3:
		tv = cv
	elif _ai_tprev != Vector3.INF and delta > 0.0:
		_ai_tv = _ai_tv.lerp((tp - _ai_tprev) / delta, 1.0 - exp(-4.0 * delta))
		tv = _ai_tv
	_ai_tprev = tp
	var sv := linear_velocity
	var d := eye.distance_to(tp)
	var t := d / GUN_SPEED
	for k in 2:
		t = eye.distance_to(tp + (tv - sv) * t) / GUN_SPEED
	var lead := tp + (tv - sv) * t - Game.gravity_at(tp) * (0.5 * t * t)
	# Aim error: a fresh one every AI_GUN_ERR_TIME, worse while jinking and on a fast target.
	_ai_err_t -= delta
	if _ai_err_t <= 0.0:
		_ai_err_t = AiBal.AI_GUN_ERR_TIME
		var ld := (lead - eye).normalized()
		var e := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		e -= ld * e.dot(ld)
		var ek := AiBal.AI_GUN_ERR * ((1.8 if _jink_t > 0.0 else 1.0) + tv.length() / 25.0)
		_ai_err = e.normalized() * d * ek * sqrt(randf()) if e.length_squared() > 1e-4 else Vector3.ZERO
	var aim := lead + _ai_err
	# Line of sight through the density field (no firing through a planet or a hill).
	_ai_los_t -= delta
	if _ai_los_t <= 0.0:
		_ai_los_t = 0.25
		_ai_los = Ballistics.segment_hit(eye, tp - (tp - eye).normalized() * 1.8).is_empty()
	# The run: in, break off close, extend, come round.
	var up_t := _up
	var tb = Game.dominant_body(tp)
	if tb != null:
		up_t = tb.up_at(tp)
	var airborne := _ai_tgt.is_in_group("skiff") and not bool(_ai_tgt.get("landed"))
	if _ai_out > 0.0:
		_ai_out -= delta
		var away := global_position - tp
		away -= up_t * away.dot(up_t)
		away = away.normalized() if away.length_squared() > 1.0 else -xf.basis.z
		_ai_v_des = away * CRUISE * speed_k + up_t * 4.0
		_ai_nose_des = away
		_ai_burst = 0.0
		return
	var closing := (tp - global_position).dot(sv) > 0.0
	if d < AiBal.AI_BREAK_DIST or (closing and _clear < AiBal.AI_RUN_MIN_CLEAR and d < 80.0):
		_ai_out = AiBal.AI_EXTEND_TIME
		return
	var pass_pt := tp if airborne else tp + up_t * AiBal.AI_RUN_ALT
	_ai_v_des = (pass_pt - global_position).normalized() * clampf(d * 0.2, 9.0, CRUISE * speed_k)
	_ai_nose_des = (aim - eye).normalized()
	if not _ai_los or _ai_track < AiBal.AI_GUN_REACT:
		_ai_burst = 0.0
		return
	var ang := (-xf.basis.z).angle_to(aim - eye)
	var cone := AiBal.AI_FIRE_CONE + atan(1.5 / maxf(d, 1.0))
	if d < AiBal.AI_GUN_RANGE and ang < cone:
		_ai_gun_rhythm(delta)
	else:
		_ai_burst = 0.0
	if _ai_tgt.is_in_group("war_structure") and d > AiBal.AI_ROCKET_MIN and d < AiBal.AI_ROCKET_MAX \
			and ang < cone and rockets_left == SALVO and _reload_t <= 0.0 and _salvo_left == 0:
		_ai_salvo = true


## Bursts with short pauses; at AI_HEAT_HI it stops until the barrels are down to AI_HEAT_LO.
func _ai_gun_rhythm(delta: float) -> void:
	if overheated:
		return
	if _ai_cool:
		if heat > AiBal.AI_HEAT_LO:
			return
		_ai_cool = false
	if heat > AiBal.AI_HEAT_HI:
		_ai_cool = true
		_ai_burst = 0.0
		return
	if _ai_burst > 0.0:
		_ai_burst -= delta
		_ai_trig = true
		if _ai_burst <= 0.0:
			_ai_rest = randf_range(0.25, 0.6)
		return
	if _ai_rest > 0.0:
		_ai_rest -= delta
		return
	_ai_burst = randf_range(0.45, 1.0)
	_ai_trig = true


## Only on the way to an enemy planet, while the hull holds and the strike time lasts.
func _ai_may_engage() -> bool:
	if hp < hp_max * AiBal.AI_ARMED_BREAK_HP or not _ai_goto or _ai_arrive or _ai_strike >= AiBal.AI_STRIKE_TIME:
		return false
	if _ai_phase != AiPhase.CRUISE and _ai_phase != AiPhase.APPROACH:
		return false
	var own = Game.rival if team == "rival" else Game.planet
	return _ai_tbody != null and _ai_tbody != own


## An enemy (by team) that is alive, in the world and not inside something.
func _ai_valid(n) -> bool:
	if n == null or not is_instance_valid(n) or not (n is Node3D) or n == self or not (n as Node).is_inside_tree():
		return false
	if Game.team_of(n) == team or n.get("is_destroyed") == true or n.get("destroyed") == true:
		return false
	if n.has_method("is_dead") and bool(n.call("is_dead")):
		return false
	if n == Game.player or (n as Node).is_in_group("net_player"):
		return n.get("vehicle") == null      # in a skiff / at a gun: that one is the target
	return (n as Node3D).is_visible_in_tree()  # (a bot aboard a skiff / a pod is hidden)


func _ai_pick_target() -> Node3D:
	var eye := global_transform * Build.EYE
	var fwd := -global_transform.basis.z
	var w: Dictionary = AiBal.AI_TARGET_W
	var cands: Array = []
	for grp: String in ["war_flak", "war_cannon", "war_buster", "war_torpedo_rig", "war_armory", "war_miner"]:
		for s in get_tree().get_nodes_in_group(grp):
			cands.append([s, float(w.get(grp, 1.0))])
	for pl in [Game.player] + get_tree().get_nodes_in_group("net_player"):
		cands.append([pl, float(w.get("player", 1.0))])
	for s in get_tree().get_nodes_in_group("skiff"):
		cands.append([s, float(w.get("skiff", 1.0)) * (0.6 if bool(s.get("landed")) else 1.0)])
	for b in get_tree().get_nodes_in_group("war_ai"):
		cands.append([b, float(w.get("bot", 1.0))])
	var best: Node3D = null
	var best_s := -INF
	for c: Array in cands:
		var n = c[0]
		if not _ai_valid(n):
			continue
		var p := _aim_point(n as Node3D)
		var dd := eye.distance_to(p)
		if dd > AiBal.AI_GUN_RANGE or dd < 8.0:
			continue
		var sc := float(c[1]) * 100.0 - dd * 0.3 - fwd.angle_to(p - eye) * 25.0
		if n == _ai_tgt:
			sc += 15.0                         # (stays on its target)
		if sc > best_s:
			best_s = sc
			best = n
	return best


# ==================================================================================================
# Gunsight (2D, in the skiff's overlay layer)
# ==================================================================================================

class Sight extends Control:
	var ship

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if ship == null or not is_instance_valid(ship) or ship.pilot == null or ship.free_looking():
			return
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			return
		var cpos := cam.global_position
		var bore := _proj(cam, cpos + ship.nose_dir() * 250.0)
		if bore.x < -9000.0:
			return
		var heat: float = ship.heat
		var hot: bool = ship.overheated
		var col := Color(0.55, 1.0, 0.65, 0.85)
		if hot:
			col = Color(1.0, 0.35, 0.3, 0.9)
		# Boresight: a broken ring, a centre dot.
		for k in 4:
			var a0 := TAU * float(k) / 4.0 + 0.25
			draw_arc(bore, 22.0, a0, a0 + TAU / 4.0 - 0.5, 10, col, 2.0)
		draw_circle(bore, 2.0, col)
		# Heat arc (left, grows upward) and the rockets (ticks under the ring).
		var hc := Color(0.55, 1.0, 0.65, 0.8).lerp(Color(1.0, 0.75, 0.3, 0.9), smoothstep(0.45, 0.7, heat)).lerp(
				Color(1.0, 0.3, 0.25, 0.95), smoothstep(0.75, 0.95, heat))
		if heat > 0.01:
			draw_arc(bore, 30.0, PI * 0.75, PI * 0.75 + PI * 0.5 * heat, 16, hc, 3.0)
		var n: int = ship.rockets_left
		for i in 4:
			var x := bore.x - 15.0 + 10.0 * float(i)
			draw_rect(Rect2(Vector2(x - 3.0, bore.y + 30.0), Vector2(6.0, 9.0)),
					Color(1.0, 0.72, 0.3, 0.9) if i < n else Color(1, 1, 1, 0.15))
		# Lead pip and a bracket on the target.
		var tgt = ship.sight_target
		var pip: Vector3 = ship.lead_pip
		if tgt != null and is_instance_valid(tgt) and pip != Vector3.INF:
			var tp := _proj(cam, (tgt as Node3D).global_position + (tgt as Node3D).global_transform.basis.y * 0.9)
			var pp := _proj(cam, pip)
			var tc := Color(1.0, 0.55, 0.3, 0.9)
			if tp.x > -9000.0:
				var r := 14.0
				for c: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
					var o := tp + c * r
					draw_line(o, o - Vector2(c.x * 6.0, 0.0), tc, 2.0)
					draw_line(o, o - Vector2(0.0, c.y * 6.0), tc, 2.0)
			if pp.x > -9000.0:
				var on := pp.distance_to(bore) < 22.0
				var pc := Color(1.0, 0.3, 0.25, 1.0) if on else tc
				draw_colored_polygon(PackedVector2Array([pp + Vector2(0, -7), pp + Vector2(7, 0), pp + Vector2(0, 7),
						pp + Vector2(-7, 0)]), Color(pc, 0.35))
				draw_polyline(PackedVector2Array([pp + Vector2(0, -7), pp + Vector2(7, 0), pp + Vector2(0, 7),
						pp + Vector2(-7, 0), pp + Vector2(0, -7)]), pc, 2.0)
				if tp.x > -9000.0 and pp.distance_to(tp) > 10.0:
					draw_line(tp, pp, Color(tc, 0.35), 1.0)
			var d := cam.global_position.distance_to((tgt as Node3D).global_position)
			var f := get_theme_default_font()
			if f != null:
				draw_string(f, bore + Vector2(30.0, 36.0), "%d m" % roundi(d), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(tc, 0.85))

	func _proj(cam: Camera3D, p: Vector3) -> Vector2:
		if cam.is_position_behind(p):
			return Vector2(-9999, -9999)
		var s := cam.unproject_position(p)
		if s.x < -40.0 or s.y < -40.0 or s.x > size.x + 40.0 or s.y > size.y + 40.0:
			return Vector2(-9999, -9999)
		return s
