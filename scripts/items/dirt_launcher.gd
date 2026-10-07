extends "res://scripts/items/weapon_base.gd"
## Toprak Topu (item id "dirt"; a side weapon): throws the soil your drill dug as ammunition. Where a
## glob lands a mound or a wall of soil stands at once: plug a tunnel, raise cover, bury the enemy.
## The more you dig, the more you can shoot.
##   Ammo     the team's material IS the ammunition (no magazine, no reserve, no reload): every shot pays
##            DirtGlob.COST[kind] m³ through Game.add_material(-cost) (the co-op pool handles itself).
##            Short of it: a dry click, the hopper rattles empty and a hint ("matkapla kaz").
##   LMB      "Toprak Gülle": a soil glob in an arc (Game.gravity_at); a mound (~3 m across, ~1 m high)
##            grows where it lands; a direct hit: small damage, a heavy shove, a stagger, and the soil
##            takes the legs (scripts/items/dirt_glob.gd: burial through scripts/war/cave_in.gd).
##   RMB      "Toprak Duvar": a heavier, slower glob that raises a wall across the shot (~4.5 × 2.5 m,
##            standing on the ground): instant cover, a tunnel plug. Costs more, cycles slower.
##            (No aiming down sights: RMB is the second fire mode. R only shows a hint.)
##   Feel     a thick, wet "thunk" (recorded launcher thump pitched down, a sub-bass body, a wet soil
##            slap, the air release hiss), a dirt spray and an air puff out of the bell, a heavy kick
##            that rocks the stubby launcher back, camera kick and screen punch; the duvar kicks harder.
## Model: a stubby, wide white barrel with orange bands and a flared dark bell (a soil plug sits in the
## mouth while there is a shot), a clear hopper on top showing the soil (its level follows the
## material, an agitator paddle turns after each shot), a compressor tank with a pressure gauge under
## the barrel, a vertical front grip (left hand), a short rubber butt.
## HUD: the panel (scripts/ui/hud.gd) shows gülle / duvar shots affordable ("12 / 3"); the overlay
## (DirtHud below) the predicted landing points of both (a ring and the wall's footprint), the cost of
## each button with what the material buys, "TOPRAK YOK" when it buys nothing.
## Multiplayer: dirt_fired(pos, vel, kind) for every shot; the other machine replays it with
## DirtGlob launch(..., owned = false) (scripts/net/net_players.gd "Toprak Topu"). The terrain, the hits
## and the burials are decided on the shooter's machine (synced brushes, damage claims, bury claims).

signal dirt_fired(pos: Vector3, vel: Vector3, kind: int)

const WEIGHT := 0.95                       # mobility factor while held (item.gd carry_weight)
const DirtGlob := preload("res://scripts/items/dirt_glob.gd")
const Ballistics := preload("res://scripts/items/ballistics.gd")
const Rockets := preload("res://scripts/items/rockets.gd")

# --- Tuning (index = kind: [gülle, duvar]; the gameplay numbers are in dirt_glob.gd) ------------------
const COOLDOWN := [0.55, 1.05]              # s between shots (the duvar's glob cycles slower)
const CONVERGE := 22.0                     # m: the glob's path crosses the eye ray here
const SHOVE := [0.6, 1.3]                  # m/s the shooter is pushed back
const GUN_KICK := [10.0, 15.0]             # view-model kick (weapon_base gun_kick)
const KICK_PITCH := [0.06, 0.1]            # camera kick (rad)
const SHAKE := [0.45, 0.7]
const FOV_PUNCH := [-3.5, -6.0]
const PUNCH := [0.32, 0.55]                # ScreenPunch
const HOPPER_SHOTS := 20                   # gülle shots a full hopper shows (panel segments, model fill)
const HINT_GAP := 1.6                      # s between the "no soil" hints
const PREVIEW_GAP := 0.1                   # s between the landing predictions (HUD)
const PRESS_BUFFER_ALT := 0.14             # s an RMB press during the cooldown stays queued

# --- Model (gun frame: grip at the origin, -Z forward) ------------------------------------------------
const BY := 0.1                            # bore axis over the grip
const BORE_R := 0.052
const MUZZLE_Z := -0.4
const BELL_R := 0.068
const HOP_Z := -0.075                      # the hopper on top
const HOP_Y0 := 0.2
const HOP_H := 0.07
const HOP_R := 0.046
const FRONT_Z := -0.27                     # the vertical front grip
const TANK_Y := BY - 0.078                 # the compressor tank under the barrel

var sprint_style := "hug"                  # gun_feel.gd: the run pose, pulled in against the chest
var handling_len := 0.5                    # handling.gd: a short gun (wall pull-back)
var panel_name := "Toprak Topu"
var grip_right := {"trig_y": -0.0075, "spread": [0.0, -0.24, -0.07, 0.08, 0.12]}   # (viewmodel.gd)
var globs                                  # dirt_glob.gd manager
var preview := Vector3.INF                 # predicted landing point of a gülle (world; INF none)
var preview_wall: Array = []               # [end a, end b] of a duvar's footprint (world) or []
var spent_t := 0.0                         # HUD: the last shot's cost flashes (1 -> 0)
var spent_kind := 0
var _kind := 0
var _alt_prev := false
var _alt_buf := 0.0
var _hint_t := 0.0
var _measure_t := 0.0
var _soil_t := 0.0
var _soil_col := Color(0.45, 0.35, 0.24)
var _fill := 0.0
var _fill_root: Node3D
var _fill_mat: ShaderMaterial
var _plug: Node3D
var _plug_mat: ShaderMaterial
var _agitator: Node3D
var _agit_v := 0.0
var _needle: Node3D
var _press := 1.0                          # compressor pressure (gauge): drops on a shot, recovers
var _plug_t := 1.0                         # the plug sliding back into the bell after a shot (0 -> 1)


func _init() -> void:
	item_id = "dirt"
	item_name = "Toprak Topu"
	item_desc = "Sol tık: toprak gülle (%s m³) · Sağ tık: toprak duvar (%s m³) · cephane: kazdığın toprak." \
			% [_num(DirtGlob.COST[0]), _num(DirtGlob.COST[1])]
	icon = "dirt"
	slot_key = 0                           # the loadout decides its key
	short_name = "Toprak Topu"
	accent = Color(0.92, 0.64, 0.34)
	ammo_id = ""
	ammo_title = "TOPRAK"
	base_mag = HOPPER_SHOTS
	can_ads = false
	auto_fire = false
	fire_rate = 1.0 / float(COOLDOWN[0])
	spread_hip = 0.004
	spread_ads = 0.004
	bloom_add = 0.0
	bloom_max = 0.0
	first_shot_k = 1.0
	hip_pos = Vector3(0.18, -0.215, -0.34)
	hip_bore_y = BY
	hip_converge = CONVERGE
	hip_cant = 0.05
	sprint_pos = Vector3(0.12, -0.25, -0.3)
	sprint_rot = Vector3(0.1, 0.8, 0.45)
	reload_pos = Vector3(0.16, -0.22, -0.36)
	reload_rot = Vector3(0.2, 0.5, 0.3)
	recoil_pivot = Vector3(0.0, 0.07, 0.12)
	kick_pitch = KICK_PITCH[0]
	kick_yaw = 0.015
	kick_roll = 0.025
	gun_kick = GUN_KICK[0]
	shake_amt = SHAKE[0]
	fov_punch_amt = FOV_PUNCH[0]
	recoil_climb = 0.0
	recoil_h = PackedFloat32Array([0.0, 0.5, -0.4])
	recoil_hold = 0.08
	recoil_recover = 0.8
	recoil_view = 0.55
	noise_radius = 40.0
	crosshair_style = "launcher"
	hit_big = 0.5
	head_mult = 0.0
	muzzle_energy = 0.0
	punch_db = -5.0
	tail_db = -80.0
	draw_time = 0.6
	holster_time = 0.4
	# The left hand on the vertical front grip (the rocket launcher's grip, moved to FRONT_Z).
	grip_left = {"at": Vector3(0.0, 0.026, FRONT_Z - 0.0011), "axis": Vector3(0, 0.095, -0.004),
			"palm": Vector3(-0.984, 0, 0.173), "r": 0.0192}


static func _num(v) -> String:
	return String.num(float(v), 0 if is_equal_approx(float(v), roundf(float(v))) else 1).replace(".", ",")


func _ready() -> void:
	super._ready()
	globs = DirtGlob.new()
	globs.name = "DirtGlobs"
	add_child(globs)
	_snd["slap"] = Snd.set_of("melee/dirt")
	_snd["puff"] = Snd.set_of("whoosh/puff")
	_snd["dirt_hit"] = Snd.set_of("bimp/dirt")
	# Own overlay: landing previews, costs, "TOPRAK YOK".
	if hud != null:
		hud.queue_free()
	hud = DirtHud.new()
	hud.weapon = self
	add_child(hud)
	mag = shots(0)


# =================================================================================================
# HUD / panel queries (the material is the ammunition)
# =================================================================================================

## Shots of `kind` the material buys now.
func shots(kind: int) -> int:
	return clampi(int(floorf((Game.material + 0.0001) / float(DirtGlob.COST[kind]))), 0, 999)


func cost(kind: int) -> float:
	return float(DirtGlob.COST[kind])


func can_afford(kind: int) -> bool:
	return Game.material + 0.0001 >= cost(kind)


## Panel "big / small": gülle / duvar shots affordable.
func mag_count() -> int:
	return mini(shots(0), 99)


func reserve_stock() -> int:
	return mini(shots(1), 99)


func reserve_count() -> int:
	return shots(0)


func mag_capacity() -> int:
	return HOPPER_SHOTS


## 0: no "price after the reserve" line on the panel (every shot is paid in material; the overlay
## shows the prices).
func round_cost() -> float:
	return 0.0


func ammo_short() -> String:
	return "GÜLLE / DUVAR"


func status_text() -> String:
	return "%d" % mini(shots(0), 99)


func hud_hint() -> String:
	return "Sol tık: gülle %s m³  ·  Sağ tık: duvar %s m³  ·  cephane: kazdığın toprak" % [_num(cost(0)), _num(cost(1))]


func reload_label() -> String:
	return "TOPRAK"


## Nothing per gun to keep (the ammunition is the material).
func save_state() -> Dictionary:
	return {}


func load_state(_d: Dictionary) -> void:
	pass


# =================================================================================================
# Firing
# =================================================================================================

func _idle_tick(_delta: float) -> void:
	# (A button held through the draw does not fire: a fresh press is needed.)
	_alt_prev = Input.is_action_pressed("tool_alt")
	_alt_buf = 0.0


func _trigger(_trig: bool, pressed: bool, alt: bool, delta: float) -> void:
	var alt_pressed := alt and not _alt_prev
	_alt_prev = alt
	if alt_pressed and (player.viewmodel.blocks_fire() or _hd.inspect.active()):
		alt_pressed = false
	if alt_pressed and _cooldown > 0.0:
		_alt_buf = PRESS_BUFFER_ALT
	elif _alt_buf > 0.0:
		_alt_buf -= delta
		if _cooldown <= 0.0 and _alt_buf > 0.0:
			alt_pressed = true
			_alt_buf = 0.0
	if _cooldown > 0.0 or _since_sprint < sprint_to_fire or not player.viewmodel.is_raised():
		return
	if pressed:
		_shoot(DirtGlob.KIND_GLOB)
	elif alt_pressed:
		_shoot(DirtGlob.KIND_WALL)


## Pays the shot's soil, then the shared shot (recoil, sound, _fire_shot).
func _shoot(kind: int) -> void:
	if not can_afford(kind):
		_no_material(kind)
		return
	Game.add_material(-cost(kind))
	_kind = kind
	gun_kick = GUN_KICK[kind]
	kick_pitch = KICK_PITCH[kind]
	shake_amt = SHAKE[kind]
	fov_punch_amt = FOV_PUNCH[kind]
	mag = maxi(shots(0), 1)                # (fire() takes one from the shown count)
	fire()
	_cooldown = float(COOLDOWN[kind])
	spent_t = 1.0
	spent_kind = kind
	mag = shots(0)


func _fire_shot(eye: Vector3, fwd: Vector3, cb: Basis, muzzle: Vector3) -> void:
	var dir := _spread_dir(fwd, cb, current_spread())
	var ex: Array = [player.get_rid()]
	var lp := launch_params(eye, dir, muzzle, _kind)
	var start: Vector3 = lp[0]
	var vel: Vector3 = lp[1]
	# Muzzle already inside a wall (point blank): the glob starts at the eye.
	if not Ballistics.segment_hit(eye, start, get_world_3d().direct_space_state, ex).is_empty():
		start = eye
	globs.launch(start, vel, _kind, "home", true, ex, player)
	dirt_fired.emit(start, vel, _kind)
	player.velocity -= fwd * float(SHOVE[_kind])
	_press = 0.25 if _kind == DirtGlob.KIND_WALL else 0.55
	_plug_t = 0.0
	_agit_v += 18.0 if _kind == DirtGlob.KIND_WALL else 11.0


## [start, velocity] of a glob fired along dir: from the bell, converging with the eye ray CONVERGE m
## out, plus the shooter's own motion.
func launch_params(eye: Vector3, dir: Vector3, muzzle: Vector3, kind: int) -> Array:
	var aim_p := eye + dir * CONVERGE
	var d2 := (aim_p - muzzle).normalized().lerp(dir, 0.5).normalized()
	var pv: Vector3 = player.velocity if player != null else Vector3.ZERO
	return [muzzle, d2 * float(DirtGlob.SPEED[kind]) + pv]


func _dry_fire() -> void:
	_no_material(0)


func _no_material(kind: int) -> void:
	_play("dry", -6.0, 0.85)
	_play("cyl_click", -12.0, 0.7)
	if Game.sfx:
		Game.sfx.play("error", -12.0)
	hud.empty_flash()
	_agit_v += 4.0                          # the empty paddle rattles
	if Game.hud and _hint_t <= 0.0:
		_hint_t = HINT_GAP
		Game.hud.show_message("Toprak yetersiz: %s için %s m³ gerekli — matkapla kaz" % [DirtGlob.KIND_NAMES[kind],
				_num(cost(kind))], 2.0)


## R: nothing to reload (the soil comes from digging), only a hint.
func reload() -> void:
	if _hint_t > 0.0:
		return
	_hint_t = HINT_GAP
	_play("selector", -14.0, 0.8)
	if Game.hud:
		Game.hud.show_message("Toprak Topu doldurulmaz: kazdığın toprak cephanedir", 2.0)


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, up: Vector3, _cb: Basis) -> void:
	ScreenPunch.kick(float(PUNCH[_kind]))
	var k := 1.0 if _kind == DirtGlob.KIND_GLOB else 1.5
	var col := _soil_col
	var g: Vector3 = Game.gravity_at(muzzle)
	# A spray of dirt out of the bell, an air puff, a few crumbs dropping off the lip.
	Rockets.puff(globs, muzzle + fwd * 0.12, (fwd + up * 0.1).normalized(), {"amount": int(14 * k), "life": 1.1,
			"vmin": 2.0, "vmax": 7.0 * k, "damp": 3.0, "spread": 22.0, "size": 0.45 * k, "scale": [0.4, 1.2, 2.2],
			"radius": 0.06, "gravity": g * 0.1, "ramp": [[0.0, Color(col.lightened(0.1), 0.0)], [0.07, Color(col.lightened(0.1), 0.6)],
				[1.0, Color(col.lightened(0.3), 0.0)]]})
	Rockets.puff(globs, muzzle + fwd * 0.08, fwd, {"amount": 8, "life": 0.35, "vmin": 4.0, "vmax": 10.0, "damp": 6.0,
			"spread": 28.0, "size": 0.5, "scale": [0.5, 1.4, 2.0], "radius": 0.04,
			"ramp": [[0.0, Color(0.9, 0.9, 0.88, 0.0)], [0.1, Color(0.9, 0.9, 0.88, 0.25)], [1.0, Color(0.9, 0.9, 0.9, 0.0)]]})
	Rockets.puff(globs, muzzle + fwd * 0.05, -up, {"amount": int(6 * k), "life": 0.7, "vmin": 0.5, "vmax": 1.8,
			"damp": 0.3, "spread": 40.0, "size": 0.06, "scale": [1.0, 1.0, 0.6], "radius": 0.04, "gravity": g,
			"ramp": [[0.0, Color(col.darkened(0.3), 1.0)], [1.0, Color(col.darkened(0.2), 0.0)]]})


## The thick wet "thunk": the recorded launcher thump pitched down, a sub-bass body, a wet soil slap,
## the air release; in vacuum only what the suit carries.
func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	var wall := _kind == DirtGlob.KIND_WALL
	var pitch := randf_range(0.94, 1.04) * (0.82 if wall else 1.0)
	if space == 3:
		_play("thump", -2.0, 0.55 * pitch, true)
		_play("boom_body", -6.0, 0.7 * pitch, true)
		_shot_body(space, 0.6, -80.0)
		return
	_play("launch", -1.0, 0.72 * pitch, true)
	_play("thump", -3.0, 0.52 * pitch, true)
	_play("boom_body", -9.0, 0.62 * pitch, true)
	_play("slap", -4.0 if wall else -6.0, 0.78 * pitch)
	_play("puff", -9.0, 0.7 * pitch)
	_play("hiss", -16.0, 1.5)
	_shot_body(space, 0.62, -15.0)


# =================================================================================================
# Per frame: the shown count, the soil colour, the landing previews, the model
# =================================================================================================

func _tick(delta: float, on: bool) -> void:
	mag = shots(0)
	_hint_t = maxf(_hint_t - delta, 0.0)
	spent_t = maxf(spent_t - delta * 1.4, 0.0)
	_press = move_toward(_press, 1.0, delta * 0.9)
	_plug_t = minf(_plug_t + delta / 0.35, 1.0)
	_soil_t -= delta
	if _soil_t <= 0.0 and player != null:
		_soil_t = 0.5
		var c := DirtGlob.soil_at(player.global_position)
		if not c.is_equal_approx(_soil_col):
			_soil_col = c
			if _fill_mat != null:
				_fill_mat.set_shader_parameter("albedo", c.darkened(0.12))
			if _plug_mat != null:
				_plug_mat.set_shader_parameter("albedo", c.darkened(0.28))
	_measure_t -= delta
	if on and _measure_t <= 0.0:
		_measure_t = PREVIEW_GAP
		_measure()
	elif not on:
		preview = Vector3.INF
		preview_wall = []


## Where a gülle and a duvar fired now would land (the HUD's ring and wall footprint).
func _measure() -> void:
	var cam: Camera3D = player.camera
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var space := get_world_3d().direct_space_state
	var ex: Array = [player.get_rid()]
	var muzzle := muzzle_world()
	var lp := launch_params(eye, fwd, muzzle, DirtGlob.KIND_GLOB)
	var h := DirtGlob.predict(lp[0], lp[1], space, ex)
	preview = h["position"] if not h.is_empty() else Vector3.INF
	preview_wall = []
	var lw := launch_params(eye, fwd, muzzle, DirtGlob.KIND_WALL)
	var hw := DirtGlob.predict(lw[0], lw[1], space, ex)
	if hw.is_empty():
		return
	var p: Vector3 = hw["position"]
	var body: Node3D = Game.dominant_body(p)
	if body == null:
		return
	var up: Vector3 = body.up_at(p)
	var flat := fwd - up * fwd.dot(up)
	if flat.length_squared() < 1e-4:
		return
	var side := up.cross(flat.normalized()).normalized()
	var half := (DirtGlob.WALL_COLS - 1) * 0.5 * DirtGlob.WALL_STEP + DirtGlob.WALL_R * 0.6
	var base := p - flat.normalized() * DirtGlob.WALL_BACK + up * 0.05
	preview_wall = [base - side * half, base + side * half]


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _fill_root == null:
		return
	# Hopper level: the material against a full hopper of gülle shots (display only).
	var want := clampf(Game.material / (float(HOPPER_SHOTS) * cost(0)), 0.0, 1.0)
	_fill = lerpf(_fill, want, 1.0 - exp(-6.0 * delta))
	_fill_root.scale = Vector3(1.0, maxf(_fill, 0.015), 1.0)
	_fill_root.visible = _fill > 0.004
	# The agitator turns after a shot (rattles when empty), the gauge needle shows the pressure.
	_agit_v = move_toward(_agit_v, 0.0, delta * 14.0)
	_agitator.rotation.y = fmod(_agitator.rotation.y + _agit_v * delta, TAU)
	_needle.rotation.z = lerpf(1.1, -1.1, _press) + sin(_t * 31.0) * 0.02 * (1.0 - _press)
	# The soil plug in the bell: gone on the shot, slides back from the neck while there is soil.
	var have := can_afford(0)
	_plug.visible = have and _plug_t > 0.15
	_plug.position = Vector3(0.0, BY, MUZZLE_Z + 0.03 + 0.09 * (1.0 - _smooth(_plug_t)))


# =================================================================================================
# Model
# =================================================================================================

## Stubby white barrel with orange bands and a flared dark bell, a clear hopper showing the soil (fill
## and agitator are their own nodes), the compressor tank with a gauge under the barrel, the vertical
## front grip, a rubber butt, the soil plug in the bell.
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	var rubber := VM.rubber()
	var gray := VM.mat(Color(0.3, 0.32, 0.35), 0.45, 0.4)
	var black := VM.mat(Color(0.05, 0.045, 0.04), 0.7, 0.1)
	# Pistol grip, trigger and guard (the rocket launcher's: same hand solve), the receiver.
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.023, -0.022), Vector3(0, -0.023, -0.072), 0.0045, steel)
	VM.capsule(_gun, Vector3(0, -0.023, -0.072), Vector3(0, 0.022, -0.084), 0.0045, steel)
	VM.soft_box(_gun, Vector3(0, 0.032, -0.04), Vector3(0.05, 0.05, 0.15), 0.01, gray)
	VM.box(_gun, Vector3(0.0255, 0.032, -0.04), Vector3(0.003, 0.012, 0.11), orange)
	# The wide barrel: white with orange bands, a dark breech cap and a rubber butt.
	VM.seg(_gun, Vector3(0, BY, 0.06), Vector3(0, BY, MUZZLE_Z + 0.07), BORE_R, BORE_R, white, 24)
	VM.ring(_gun, Vector3(0, BY, -0.05), Vector3.FORWARD, BORE_R + 0.004, 0.01, orange)
	VM.ring(_gun, Vector3(0, BY, -0.22), Vector3.FORWARD, BORE_R + 0.004, 0.01, orange)
	VM.ring(_gun, Vector3(0, BY, -0.14), Vector3.FORWARD, BORE_R + 0.003, 0.005, dark)
	VM.seg(_gun, Vector3(0, BY, 0.05), Vector3(0, BY, 0.1), BORE_R + 0.004, BORE_R + 0.002, dark, 24)
	VM.seg(_gun, Vector3(0, BY, 0.1), Vector3(0, BY, 0.13), BORE_R - 0.004, BORE_R - 0.01, rubber, 20)
	for i in 3:
		VM.ring(_gun, Vector3(0, BY, 0.105 + i * 0.01), Vector3.BACK, BORE_R - 0.003, 0.003, black)
	# The flared bell: dark, a lip, an orange ring, the black throat.
	VM.seg(_gun, Vector3(0, BY, MUZZLE_Z + 0.08), Vector3(0, BY, MUZZLE_Z), BORE_R + 0.004, BELL_R, dark, 24)
	VM.ring(_gun, Vector3(0, BY, MUZZLE_Z + 0.002), Vector3.FORWARD, BELL_R + 0.003, 0.009, dark)
	VM.ring(_gun, Vector3(0, BY, MUZZLE_Z + 0.06), Vector3.FORWARD, BORE_R + 0.009, 0.006, orange)
	VM.seg(_gun, Vector3(0, BY, MUZZLE_Z + 0.012), Vector3(0, BY, MUZZLE_Z + 0.008), BELL_R - 0.008, BELL_R - 0.008, black, 24)
	_muzzle = VM.node(_gun, Vector3(0, BY, MUZZLE_Z - 0.03))
	# The hopper on top: a feed neck, a clear drum with the soil inside, a white cap with an orange lid.
	VM.seg(_gun, Vector3(0, BY + BORE_R - 0.004, HOP_Z), Vector3(0, HOP_Y0 + 0.004, HOP_Z), 0.022, 0.026, dark, 16)
	VM.seg(_gun, Vector3(0, HOP_Y0 - 0.004, HOP_Z), Vector3(0, HOP_Y0 + 0.008, HOP_Z), HOP_R + 0.004, HOP_R + 0.004, white, 24)
	VM.seg(_gun, Vector3(0, HOP_Y0 + HOP_H - 0.006, HOP_Z), Vector3(0, HOP_Y0 + HOP_H + 0.01, HOP_Z), HOP_R + 0.005, HOP_R + 0.002, white, 24)
	VM.seg(_gun, Vector3(0, HOP_Y0 + HOP_H + 0.01, HOP_Z), Vector3(0, HOP_Y0 + HOP_H + 0.02, HOP_Z), HOP_R - 0.006, HOP_R - 0.014, orange, 20)
	VM.box(_gun, Vector3(0, HOP_Y0 + HOP_H + 0.023, HOP_Z), Vector3(0.03, 0.008, 0.01), dark)
	for sx in [-1.0, 1.0]:                  # two struts the drum hangs between
		VM.capsule(_gun, Vector3(sx * (HOP_R + 0.003), HOP_Y0, HOP_Z), Vector3(sx * (HOP_R + 0.003), HOP_Y0 + HOP_H, HOP_Z), 0.004, gray, 8)
	var drum := VM.seg(_gun, Vector3(0, HOP_Y0 + 0.008, HOP_Z), Vector3(0, HOP_Y0 + HOP_H - 0.006, HOP_Z), HOP_R, HOP_R, VM.glass(), 28)
	_fill_mat = VM.mat(_soil_col.darkened(0.12), 0.95, 0.0, 0.35).duplicate() as ShaderMaterial
	_fill_root = VM.node(_gun, Vector3(0, HOP_Y0 + 0.008, HOP_Z))
	VM.seg(_fill_root, Vector3.ZERO, Vector3(0, HOP_H - 0.016, 0), HOP_R - 0.004, HOP_R - 0.004, _fill_mat, 20)
	VM.sphere(_fill_root, Vector3(0.012, HOP_H - 0.018, 0.008), 0.02, _fill_mat)
	_agitator = VM.node(_gun, Vector3(0, HOP_Y0 + 0.02, HOP_Z))
	VM.capsule(_agitator, Vector3(0, 0, 0), Vector3(0, HOP_H - 0.03, 0), 0.004, steel, 8)
	VM.box(_agitator, Vector3(0, 0.006, 0), Vector3(HOP_R * 1.6, 0.006, 0.008), steel)
	VM.box(_agitator, Vector3(0, 0.024, 0), Vector3(0.008, 0.006, HOP_R * 1.5), steel)
	# The compressor tank under the barrel, its gauge on the left (needle = pressure).
	VM.seg(_gun, Vector3(0, TANK_Y, -0.06), Vector3(0, TANK_Y, -0.24), 0.026, 0.026, gray, 18)
	VM.sphere(_gun, Vector3(0, TANK_Y, -0.24), 0.026, gray)
	VM.ring(_gun, Vector3(0, TANK_Y, -0.1), Vector3.FORWARD, 0.029, 0.006, orange)
	VM.box(_gun, Vector3(0, (TANK_Y + BY) * 0.5, -0.16), Vector3(0.018, BY - TANK_Y - 0.02, 0.07), dark)
	VM.seg(_gun, Vector3(-0.026, TANK_Y + 0.006, -0.12), Vector3(-0.036, TANK_Y + 0.006, -0.12), 0.016, 0.016, steel, 16)
	VM.seg(_gun, Vector3(-0.0362, TANK_Y + 0.006, -0.12), Vector3(-0.0368, TANK_Y + 0.006, -0.12), 0.0135, 0.0135, VM.mat(Color(0.9, 0.9, 0.86), 0.5), 16)
	_needle = VM.node(_gun, Vector3(-0.0372, TANK_Y + 0.006, -0.12), Basis(Vector3.UP, -PI * 0.5))
	VM.box(_needle, Vector3(0, 0.005, 0), Vector3(0.0016, 0.011, 0.0008), VM.glow(Color(1.0, 0.35, 0.2), 2.0))
	# The vertical front grip (left hand), under the tank.
	VM.soft_box(_gun, Vector3(0, TANK_Y - 0.026, FRONT_Z), Vector3(0.026, 0.02, 0.05), 0.006, dark)
	VM.capsule(_gun, Vector3(0, -0.07, FRONT_Z + 0.002), Vector3(0, 0.025, FRONT_Z - 0.002), 0.018, rubber)
	for i in 3:
		VM.ring(_gun, Vector3(0, -0.05 + i * 0.022, FRONT_Z + 0.001), Vector3.UP, 0.0192, 0.004, dark)
	VM.seg(_gun, Vector3(0, -0.094, FRONT_Z + 0.003), Vector3(0, -0.08, FRONT_Z + 0.002), 0.021, 0.02, orange)
	left_grip = VM.node(_gun, Vector3(0, -0.02, FRONT_Z), hand_basis(Vector3(-0.42, -0.62, 0.66), Vector3(0, 1, 0)))
	# The soil plug in the bell (moves on the shot).
	_plug_mat = VM.mat(_soil_col.darkened(0.28), 0.7, 0.0, 0.4).duplicate() as ShaderMaterial
	_plug = VM.node(_gun, Vector3(0, BY, MUZZLE_Z + 0.03))
	VM.ellipsoid(_plug, Vector3.ZERO, Vector3(BORE_R - 0.006, BORE_R - 0.006, 0.03), _plug_mat)
	VM.sphere(_plug, Vector3(0.018, 0.012, -0.022), 0.016, _plug_mat)
	VM.sphere(_plug, Vector3(-0.015, -0.01, -0.02), 0.013, _plug_mat)
	var skip: Array = [_fill_root, _agitator, _needle, _plug, _muzzle, left_grip, drum]
	VM.bake(_gun, skip)
	VM.bake(_fill_root)
	VM.bake(_plug)
	return model


func _build_tp(p: Node3D) -> Node3D:
	var white := _tp_mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tp_mat(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _tp_mat(Color(0.16, 0.17, 0.19), 0.4, 0.6)
	var rubber := _tp_mat(Color(0.08, 0.08, 0.09), 0.9, 0.0)
	var soil := _tp_mat(Color(0.4, 0.31, 0.21), 0.95, 0.0)
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.032, -0.04), Vector3(0.05, 0.05, 0.15), dark)
	VM.seg(p, Vector3(0, BY, 0.13), Vector3(0, BY, MUZZLE_Z + 0.07), BORE_R, BORE_R, white, 12)
	VM.ring(p, Vector3(0, BY, -0.05), Vector3.FORWARD, BORE_R + 0.004, 0.012, orange)
	VM.ring(p, Vector3(0, BY, -0.22), Vector3.FORWARD, BORE_R + 0.004, 0.012, orange)
	VM.seg(p, Vector3(0, BY, MUZZLE_Z + 0.08), Vector3(0, BY, MUZZLE_Z), BORE_R + 0.004, BELL_R, dark, 12)
	VM.seg(p, Vector3(0, BY + BORE_R - 0.004, HOP_Z), Vector3(0, HOP_Y0, HOP_Z), 0.022, 0.026, dark, 8)
	VM.seg(p, Vector3(0, HOP_Y0, HOP_Z), Vector3(0, HOP_Y0 + HOP_H, HOP_Z), HOP_R, HOP_R, soil, 12)
	VM.seg(p, Vector3(0, HOP_Y0 + HOP_H, HOP_Z), Vector3(0, HOP_Y0 + HOP_H + 0.016, HOP_Z), HOP_R + 0.004, HOP_R - 0.01, orange, 12)
	VM.seg(p, Vector3(0, TANK_Y, -0.06), Vector3(0, TANK_Y, -0.24), 0.026, 0.026, dark, 10)
	VM.capsule(p, Vector3(0, -0.07, FRONT_Z), Vector3(0, 0.025, FRONT_Z), 0.018, rubber)
	return VM.node(p, Vector3(0, BY, MUZZLE_Z - 0.03))


# =================================================================================================
# HUD overlay: the landing previews, the costs, "TOPRAK YOK"
# =================================================================================================

class DirtHud extends "res://scripts/items/weapon_hud.gd":
	func _draw_top() -> void:
		var vs := _top.size
		var c := (vs * 0.5).round()
		var k := UI.scale_k(vs)
		var w = weapon
		var col: Color = w.accent_color()
		var a := 1.0 - float(w.get("_sprint_w"))
		var cam: Camera3D = w.player.camera if w.player != null else null
		var ol := Color(UI.OUTLINE, 0.7 * a)
		var tc := Color(0.95, 0.97, 0.98, 0.9 * a)
		var lw := maxf(2.0 * k, 1.5)
		# The crosshair: a centre dot in a small open bowl (the glob arcs down from it).
		if a > 0.02:
			_top.draw_arc(c, 9.0 * k, 0.35, PI - 0.35, 18, ol, lw + 2.0, true)
			_top.draw_arc(c, 9.0 * k, 0.35, PI - 0.35, 18, tc, lw, true)
			_top.draw_circle(c, 2.4 * k, ol)
			_top.draw_circle(c, 1.5 * k, Color(col.lightened(0.4), a))
		# The duvar's footprint (faint) and the gülle's landing ring with its range.
		if cam != null and a > 0.02:
			var pw: Array = w.preview_wall
			if pw.size() == 2 and not cam.is_position_behind(pw[0]) and not cam.is_position_behind(pw[1]):
				var s0 := cam.unproject_position(pw[0])
				var s1 := cam.unproject_position(pw[1])
				var wc := Color(UI.SUIT_WHITE, 0.4 * a) if w.can_afford(1) else Color(UI.BAD, 0.35 * a)
				_top.draw_line(s0, s1, Color(UI.OUTLINE, 0.35 * a), lw + 2.0, true)
				_top.draw_line(s0, s1, wc, lw * 0.8, true)
				for e in [s0, s1]:
					var ev: Vector2 = e
					_top.draw_line(ev + Vector2(0, -5.0 * k), ev + Vector2(0, 5.0 * k), wc, lw * 0.8, true)
			var ip: Vector3 = w.preview
			if ip != Vector3.INF and not cam.is_position_behind(ip):
				var sp := cam.unproject_position(ip)
				var pulse := 0.65 + 0.35 * sin(_t * 6.0)
				var rc := col if w.can_afford(0) else UI.BAD
				_top.draw_arc(sp, 8.0 * k, 0, TAU, 28, Color(UI.OUTLINE, 0.5 * a), lw + 2.0, true)
				_top.draw_arc(sp, 8.0 * k, 0, TAU, 28, Color(rc, 0.9 * pulse * a), lw, true)
				_top.draw_circle(sp, 1.8 * k, Color(rc.lightened(0.3), 0.9 * a))
				var dist := cam.global_position.distance_to(ip)
				UI.draw_text(_top, UI.font_num(700), sp + Vector2(12.0, 4.0) * k, "%d m" % int(dist), UI.fs(11, k),
						Color(rc.lightened(0.3), 0.85 * a), 3)
		# The two buttons: what each costs and how many the material buys.
		var y := c.y + 56.0 * k
		var f := UI.font_caps(700, 1)
		var fsz := UI.fs(11, k)
		var labels := ["GÜLLE", "DUVAR"]
		var parts: Array = []
		var total := 0.0
		for kind in 2:
			var s := "%s  %s m³  ×%d" % [labels[kind], w._num(w.cost(kind)), mini(int(w.shots(kind)), 99)]
			var tw := UI.text_w(f, s, fsz)
			parts.append([s, tw])
			total += tw + 30.0 * k
		total += 14.0 * k
		var x := c.x - total * 0.5
		for kind in 2:
			var s: String = parts[kind][0]
			var tw: float = parts[kind][1]
			var ok: bool = w.can_afford(kind)
			var flash: float = float(w.spent_t) if int(w.spent_kind) == kind else 0.0
			var key_w := UI.draw_key(_top, Vector2(x, y - 13.0 * k), "SOL" if kind == 0 else "SAĞ", k, flash > 0.3, 0.85, 9)
			var tcol := UI.TEXT if ok else UI.BAD
			tcol = tcol.lerp(UI.SUIT_ORANGE.lightened(0.2), flash)
			UI.draw_text(_top, f, Vector2(x + key_w + 6.0 * k, y), s, fsz, Color(tcol, 0.9), 2)
			x += key_w + 6.0 * k + tw + 24.0 * k
		# No soil at all: say how to get it.
		if not w.can_afford(0):
			var blink := 0.55 + 0.45 * sin(_t * 9.0)
			UI.draw_text_c(_top, _font_b, c + Vector2(0, 84.0 * k), "TOPRAK YOK  ·  matkapla kaz", UI.fs(14, k),
					Color(UI.CRIT.lightened(0.1), blink * (0.6 + 0.4 * minf(_empty_t + 0.5, 1.0))), 3)
		if w.player != null and w.player.get("interact_target") != null:
			_top.draw_arc(c, 18.0 * k, 0, TAU, 40, Color(UI.OUTLINE, 0.5 * a), lw + 2.0, true)
			_top.draw_arc(c, 18.0 * k, 0, TAU, 40, Color(UI.SUIT_ORANGE.lightened(0.15), 0.9 * a), lw * 0.8, true)
