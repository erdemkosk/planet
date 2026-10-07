extends Node3D
## One buried cache's body (pooled by scripts/war/caches.gd: assign(rec, body) / release()). Models in
## the game's suit style, weathered and dirt-caked (a noise mask mixes the planet's soil colour over every
## painted part, object-space triplanar, so no face is clean):
##   crate   Eski ikmal sandığı: white panels, orange corner posts and band, dark skids, side handles, a
##           stencil plate, two front latches; the lid swings up on its back hinges
##   locker  Mühürlü ekipman dolabı: a gunmetal locker lying on its back, steel end caps, orange hazard
##           slats, vents, a red seal lamp (green once open); the door swings up
##   kitbag  Düşmüş askerin çantası: a weathered canvas duffel with straps and a side pocket, its flap,
##           and the fallen soldier's cracked helmet with a gold visor beside it
##   relic   Eski kalıntı: a faceted glowing crystal inside three obsidian shards on an ancient stone
##           ring with rune notches; soft pulsing glow and light; the shards bloom open
## Buried: model only (seen where the soil is dug thin). Dug free (on_exposed): a collider on the
## terrain layer (stand on it, loot lands on it), the F area (interact_button.gd; the player's interact
## ray ignores terrain, so it stays off while buried), a glint now and then. Open: CACHE_OPEN_TIME s of
## animation with sounds (play_open), then the manager spills the contents (spill_point()). A dug-free
## cache whose ground is dug away drops onto the next solid ground (the exact density).
## Tünel tarayıcı: in group "buried_cache" while assigned and unopened; scan_point() / scan_label().

const Balance := preload("res://scripts/war/balance.gd")
const InteractButton := preload("res://scripts/ships/interact_button.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # stencil text range per HUD level (_label)

const GROUP := "buried_cache"
const SIZES := {"crate": Vector3(1.06, 0.62, 0.68), "locker": Vector3(1.34, 0.44, 0.64),
		"kitbag": Vector3(1.0, 0.42, 0.5), "relic": Vector3(0.86, 0.8, 0.86)}
const CENTRES := {"crate": Vector3(0, -0.04, 0), "locker": Vector3(0, -0.04, 0), "kitbag": Vector3(0.1, -0.06, 0.04),
		"relic": Vector3(0, 0.0, 0)}
const PROMPTS := {"crate": "Eski ikmal sandığını aç", "locker": "Mühürlü dolabı aç", "kitbag": "Askerin çantasını karıştır",
		"relic": "Eski kalıntıya dokun"}
const LABELS := {"crate": "GÖMÜLÜ SANDIK", "locker": "GÖMÜLÜ SANDIK", "kitbag": "GÖMÜLÜ SANDIK", "relic": "TUHAF SİNYAL"}
const RELIC_COL := Color(0.5, 0.82, 1.0)
const GLINT_EVERY := Vector2(3.5, 6.5)  # s between the attention glints of a dug-free, unopened cache
const SETTLE_PERIOD := 0.3             # s between support checks (dug free)

var manager: Node                      # scripts/war/caches.gd
var rec_id := -1
var kind := ""
var _body: Node3D
var _rec: Dictionary = {}
var _vis: Node3D
var _lid: Node3D                       # crate lid / locker door / kitbag flap
var _latches: Array = []
var _petals: Array = []                # relic: [pivot, tangent axis]
var _core: Node3D
var _seal: MeshInstance3D
var _glow: StandardMaterial3D          # relic: this prop's own pulsing glow
var _light: OmniLight3D
var _glint: MeshInstance3D
var _area: Area3D
var _solid: StaticBody3D
var _shape: BoxShape3D
var _cshape: CollisionShape3D
var _open_k := 0.0                     # pose 0 closed .. 1 open
var _anim_t := -1.0                    # s into the open animation (-1: none)
var _sounds: Array = []                # [t, name, db, pitch] still to play in this animation
var _glint_t := 0.0
var _glint_s := 0.0
var _glint_next := 2.0
var _t := 0.0
var _settle_t := 0.0
var _vel := Vector3.ZERO
var _falling := false

static var _mats := {}
static var _meshes := {}
static var _mask: NoiseTexture2D
static var _star: ImageTexture


func _ready() -> void:
	visible = false
	_vis = Node3D.new()
	_vis.name = "Vis"
	add_child(_vis)
	_solid = StaticBody3D.new()
	_solid.collision_layer = 0
	_solid.collision_mask = 0
	_cshape = CollisionShape3D.new()
	_shape = BoxShape3D.new()
	_cshape.shape = _shape
	_solid.add_child(_cshape)
	add_child(_solid)
	_area = InteractButton.new()
	_area.setup(Vector3.ONE, _on_interact, _prompt)
	_area.collision_layer = 0
	add_child(_area)
	_glint = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 0.9)
	_glint.mesh = q
	_glint.material_override = _glint_mat()
	_glint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glint.visible = false
	add_child(_glint)
	_light = OmniLight3D.new()
	_light.light_color = RELIC_COL
	_light.omni_range = 3.2
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = 30.0
	_light.distance_fade_length = 8.0
	_light.visible = false
	add_child(_light)
	set_process(false)


# =================================================================================================
# Pool API (caches.gd)
# =================================================================================================

## Take cache `rec` on `body`: its model, place, pose and state.
func assign(rec: Dictionary, body: Node3D) -> void:
	_rec = rec
	_body = body
	rec_id = int(rec["id"])
	kind = str(rec["kind"])
	_falling = false
	_vel = Vector3.ZERO
	_anim_t = -1.0
	_sounds.clear()
	_glint_t = 0.0
	_glint_next = randf_range(0.6, 2.0)
	_build()
	_place()
	var opened := bool(rec["opened"])
	_open_k = 1.0 if opened else 0.0
	_pose(_open_k, 1.0 if opened else 0.0)
	var sz: Vector3 = SIZES.get(kind, Vector3.ONE)
	_shape.size = sz
	_cshape.position = CENTRES.get(kind, Vector3.ZERO)
	var ab := _area.get_child(0) as CollisionShape3D
	if ab != null and ab.shape is BoxShape3D:
		(ab.shape as BoxShape3D).size = sz + Vector3(0.3, 0.35, 0.3)
	_area.position = CENTRES.get(kind, Vector3.ZERO)
	visible = true
	set_process(true)
	_refresh_state()


## Back to the pool.
func release() -> void:
	rec_id = -1
	_rec = {}
	_body = null
	kind = ""
	visible = false
	set_process(false)
	_solid.collision_layer = 0
	_area.collision_layer = 0
	_light.visible = false
	_glint.visible = false
	if is_in_group(GROUP):
		remove_from_group(GROUP)
	for c in _vis.get_children():
		c.queue_free()


func on_exposed() -> void:
	_refresh_state()
	_glint_next = randf_range(1.5, 3.0)


func on_opened() -> void:
	_refresh_state()


## Instantly open (a late join's already opened cache).
func set_open_pose() -> void:
	_anim_t = -1.0
	_sounds.clear()
	_open_k = 1.0
	_pose(1.0, 1.0)


## Play the open animation (local: our own F; else someone else's open, seen from here).
func play_open(_local: bool) -> void:
	if _anim_t >= 0.0 or _open_k >= 1.0:
		return
	_anim_t = 0.0
	_sounds = _open_sounds()
	_area.collision_layer = 0
	if Game.hud and _local:
		Game.hud.set_prompt("")


## A client's request got no answer: closed again (F works again).
func cancel_open() -> void:
	_anim_t = -1.0
	_sounds.clear()
	_open_k = 0.0
	_pose(0.0, 0.0)
	_refresh_state()


## A short star glint over the top (strength ~1).
func glint(strength := 1.0) -> void:
	_glint_t = 0.45
	_glint_s = strength
	_glint.visible = true


## Where the contents spill from (world): just over its top.
func spill_point() -> Vector3:
	return global_position + up_dir() * 0.55


func up_dir() -> Vector3:
	if _body != null and is_instance_valid(_body):
		var r := global_position - _body.global_position
		if r.length_squared() > 1e-4:
			return r.normalized()
	return global_transform.basis.y


# --- Tünel tarayıcı (scripts/items/tunnel_scanner.gd reads group "buried_cache") ----------------------

func scan_point() -> Vector3:
	return global_position


func scan_label() -> String:
	return str(LABELS.get(kind, "GÖMÜLÜ SANDIK"))


# =================================================================================================
# State, per frame
# =================================================================================================

func _refresh_state() -> void:
	if rec_id < 0:
		return
	var exposed := bool(_rec.get("exposed", false))
	var opened := bool(_rec.get("opened", false))
	var busy := bool(_rec.get("opening", false)) or int(_rec.get("pending_ms", 0)) > 0
	_solid.collision_layer = Game.LAYER_TERRAIN if exposed else 0
	_area.collision_layer = Game.LAYER_INTERACT if exposed and not opened and not busy and _anim_t < 0.0 else 0
	_light.visible = kind == "relic" and exposed
	if opened:
		if is_in_group(GROUP):
			remove_from_group(GROUP)
	elif not is_in_group(GROUP):
		add_to_group(GROUP)


func _on_interact() -> void:
	if manager != null and is_instance_valid(manager) and rec_id >= 0:
		manager.request_open(rec_id)


func _prompt() -> String:
	if rec_id < 0 or bool(_rec.get("opened", false)) or bool(_rec.get("opening", false)):
		return ""
	return str(PROMPTS.get(kind, "Sandığı aç"))


func _process(delta: float) -> void:
	if rec_id < 0:
		return
	_t += delta
	var exposed := bool(_rec.get("exposed", false))
	var opened := bool(_rec.get("opened", false))
	# The open animation and its sounds.
	if _anim_t >= 0.0:
		_anim_t += delta
		var T := maxf(Balance.CACHE_OPEN_TIME, 0.1)
		while not _sounds.is_empty() and _anim_t >= float(_sounds[0][0]) * T:
			var s: Array = _sounds.pop_front()
			if Game.sfx:
				Game.sfx.play_at(str(s[1]), global_position, float(s[2]), float(s[3]))
		var ph := clampf(_anim_t / T, 0.0, 1.0)
		_open_k = ph
		_pose(ph, _anim_t / T)
		if _anim_t >= T * 1.25:
			_anim_t = -1.0
			_open_k = 1.0
			_refresh_state()
	elif kind == "relic":
		_pose(_open_k, 1.0 + _t)            # (the glow keeps pulsing)
	# Attention glints while dug free and unopened.
	if exposed and not opened and _anim_t < 0.0:
		_glint_next -= delta
		if _glint_next <= 0.0:
			_glint_next = randf_range(GLINT_EVERY.x, GLINT_EVERY.y)
			glint(0.7)
	if _glint_t > 0.0:
		_glint_t -= delta
		var g := clampf(_glint_t / 0.45, 0.0, 1.0)
		var sc := sin(g * PI) * _glint_s
		_glint.scale = Vector3.ONE * maxf(sc, 0.01)
		_glint.visible = _glint_t > 0.0
	# Relic light.
	if _light.visible:
		var pulse := 0.5 + 0.5 * sin(_t * 2.1)
		_light.light_energy = (0.35 + 0.55 * pulse) * (0.45 if opened else 1.0) + (1.6 if _anim_t >= 0.0 else 0.0)
	# Dug free and the ground under it gone: it drops.
	if exposed:
		_settle(delta)


## Whether the ground under it is gone; falls onto the next solid ground (exact density).
func _settle(dt: float) -> void:
	if _body == null or not is_instance_valid(_body):
		return
	if not _falling:
		_settle_t -= dt
		if _settle_t > 0.0:
			return
		_settle_t = SETTLE_PERIOD
		if _supported():
			return
		_falling = true
		_vel = Vector3.ZERO
	var up := up_dir()
	var p := global_position
	_vel += Game.gravity_at(p) * dt
	var nxt := p + _vel * dt
	var foot := _foot_depth()
	if float(_body.density_at(nxt - up * foot)) < 0.0:
		var h: Dictionary = _body.raycast_density(p - up * (foot - 0.3), nxt - up * (foot + 0.05), 0.08, false)
		if not h.is_empty():
			nxt = (h["position"] as Vector3) + up * foot
		_falling = false
		_vel = Vector3.ZERO
		if Game.sfx:
			Game.sfx.play_at("impact", nxt, -10.0, 0.85)
	global_position = nxt
	if not _rec.is_empty():
		_rec["local"] = nxt - _body.global_position


func _foot_depth() -> float:
	var sz: Vector3 = SIZES.get(kind, Vector3.ONE)
	var c: Vector3 = CENTRES.get(kind, Vector3.ZERO)
	return sz.y * 0.5 - c.y


## Solid ground under its middle or any of four points under its footprint.
func _supported() -> bool:
	var sz: Vector3 = SIZES.get(kind, Vector3.ONE)
	var b := global_transform.basis
	var down := -up_dir()
	var foot := _foot_depth() + 0.15
	var base := global_position + down * foot
	for o in [Vector3.ZERO, Vector3(0.4, 0, 0.4), Vector3(-0.4, 0, 0.4), Vector3(0.4, 0, -0.4), Vector3(-0.4, 0, -0.4)]:
		var off: Vector3 = b * Vector3((o as Vector3).x * sz.x, 0.0, (o as Vector3).z * sz.z)
		if float(_body.density_at(base + off)) < 0.0:
			return true
	return false


func _place() -> void:
	if _body == null or not is_instance_valid(_body):
		return
	var pos: Vector3 = _body.global_position + (_rec["local"] as Vector3)
	var up: Vector3 = (pos - _body.global_position).normalized()
	var tilt: Vector2 = _rec.get("tilt", Vector2.ZERO)
	var max_tilt := 0.32 if kind == "relic" else 0.18
	var ref := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := up.cross(ref).normalized()
	var z := x.cross(up)
	var b := Basis(x, up, z) * Basis(Vector3.UP, float(_rec.get("yaw", 0.0)))
	b = b * Basis(Vector3.RIGHT, tilt.x * max_tilt) * Basis(Vector3.BACK, tilt.y * max_tilt)
	global_transform = Transform3D(b.orthonormalized(), pos)
	_glint.position = Vector3(0.25, 0.42, 0.2)
	_light.position = Vector3(0, 0.35, 0)


# =================================================================================================
# Animation
# =================================================================================================

## Pose for open share k (0..1); t: the animation clock in units of CACHE_OPEN_TIME (relic glow, seal).
func _pose(k: float, t: float) -> void:
	match kind:
		"crate":
			var kl := smoothstep(0.0, 0.3, k)
			for l in _latches:
				(l as Node3D).rotation = Vector3(1.25 * kl, 0, 0)
			var kk := _ease_back(clampf((k - 0.25) / 0.75, 0.0, 1.0))
			if _lid != null:
				_lid.rotation = Vector3(-1.95 * kk, 0, 0)
		"locker":
			var kd := _ease_back(clampf((k - 0.3) / 0.7, 0.0, 1.0))
			if _lid != null:
				_lid.rotation = Vector3(-1.8 * kd, 0, 0)
			if _seal != null:
				var green := k >= 0.25
				var blink := k > 0.0 and k < 0.25 and fmod(t * 12.0, 1.0) < 0.5
				_seal.material_override = _mat("seal_green" if green else ("seal_off" if blink else "seal_red"))
		"kitbag":
			var kf := smoothstep(0.0, 1.0, clampf((k - 0.15) / 0.85, 0.0, 1.0))
			if _lid != null:
				_lid.rotation = Vector3(-2.5 * kf, 0, 0)
		"relic":
			var kp := _ease_back(clampf((k - 0.1) / 0.9, 0.0, 1.0))
			for pe in _petals:
				var pv: Node3D = pe[0]
				pv.basis = Basis(pe[1] as Vector3, lerpf(-0.12, 0.62, kp))
			if _core != null:
				_core.position = Vector3(0, 0.05 + 0.14 * kp, 0)
				_core.rotation = Vector3(0, t * 0.9, 0)
			if _glow != null:
				var pulse := 0.5 + 0.5 * sin(_t * 2.1)
				var flare := 0.0
				if _anim_t >= 0.0:
					flare = sin(clampf(_anim_t / maxf(Balance.CACHE_OPEN_TIME, 0.1), 0.0, 1.0) * PI) * 5.0
				var spent := 0.4 if bool(_rec.get("opened", false)) and _anim_t < 0.0 else 1.0
				_glow.emission_energy_multiplier = (1.2 + 1.4 * pulse) * spent + flare


static func _ease_back(x: float) -> float:
	var c1 := 1.4
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)


## [share of CACHE_OPEN_TIME, sound, dB, pitch] for this kind's open.
func _open_sounds() -> Array:
	match kind:
		"crate":
			return [[0.0, "clunk", -6.0, 0.9], [0.12, "clunk", -8.0, 1.05], [0.28, "servo", -12.0, 0.9],
					[0.95, "impact_light", -9.0, 0.8]]
		"locker":
			return [[0.0, "blip", -10.0, 1.1], [0.12, "blip", -10.0, 1.1], [0.26, "clunk", -6.0, 0.8],
					[0.32, "servo", -10.0, 0.85], [1.0, "impact_light", -8.0, 0.75]]
		"kitbag":
			return [[0.0, "cloth_long", -6.0, 0.95], [0.3, "gear", -8.0, 1.0], [0.75, "cloth", -9.0, 0.9]]
		"relic":
			return [[0.0, "whoosh", -9.0, 0.85], [0.1, "ding", -9.0, 0.7], [0.4, "ding", -10.0, 1.05],
					[0.75, "ding", -12.0, 1.4]]
	return []


# =================================================================================================
# Models
# =================================================================================================

func _build() -> void:
	for c in _vis.get_children():
		_vis.remove_child(c)
		c.queue_free()
	_lid = null
	_latches = []
	_petals = []
	_core = null
	_seal = null
	_glow = null
	var soil := Color(0.42, 0.33, 0.22)
	if _body != null and _body.get("soil_color") is Color:
		soil = _body.get("soil_color")
	match kind:
		"locker":
			_build_locker(soil)
		"kitbag":
			_build_kitbag(soil)
		"relic":
			_build_relic(soil)
		_:
			_build_crate(soil)


func _build_crate(soil: Color) -> void:
	var white := _mat("white", soil)
	var orange := _mat("orange", soil)
	var dark := _mat("dark")
	var steel := _mat("steel")
	_box(_vis, Vector3(1.0, 0.4, 0.62), Vector3(0, -0.1, 0), white, Basis(), true)
	_box(_vis, Vector3(1.012, 0.06, 0.632), Vector3(0, -0.13, 0), orange)
	for z in [-0.22, 0.22]:
		_box(_vis, Vector3(1.04, 0.06, 0.09), Vector3(0, -0.33, z), dark)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(_vis, Vector3(0.075, 0.44, 0.075), Vector3(sx * 0.475, -0.1, sz * 0.285), orange)
		_box(_vis, Vector3(0.03, 0.045, 0.24), Vector3(sx * 0.515, -0.02, 0), dark)
	_box(_vis, Vector3(0.36, 0.08, 0.006), Vector3(-0.2, -0.03, 0.312), dark)
	_label(_vis, "İKMAL-%02d" % (rec_id % 100), Vector3(-0.2, -0.03, 0.317), Color(0.85, 0.85, 0.8, 0.9))
	_box(_vis, Vector3(0.16, 0.025, 0.006), Vector3(0.24, -0.03, 0.312), orange)
	# Inside (seen once the lid is up): dark floor, a canister and a small orange case.
	_box(_vis, Vector3(0.9, 0.012, 0.52), Vector3(0, 0.104, 0), _mat("interior"))
	_cyl(_vis, 0.07, 0.12, Vector3(0.22, 0.13, -0.06), Basis(Vector3.BACK, PI * 0.5), steel)
	_box(_vis, Vector3(0.22, 0.07, 0.16), Vector3(-0.2, 0.135, 0.06), orange)
	for sx in [-0.3, 0.3]:
		_cyl(_vis, 0.022, 0.12, Vector3(sx, 0.1, -0.318), Basis(Vector3.BACK, PI * 0.5), steel)
	# Lid on the back hinges.
	_lid = Node3D.new()
	_lid.position = Vector3(0, 0.1, -0.31)
	_vis.add_child(_lid)
	_box(_lid, Vector3(1.02, 0.14, 0.64), Vector3(0, 0.075, 0.31), white, Basis(), true)
	_box(_lid, Vector3(1.03, 0.035, 0.65), Vector3(0, 0.01, 0.31), orange)
	for sx in [-1.0, 1.0]:
		_box(_lid, Vector3(0.08, 0.012, 0.645), Vector3(sx * 0.36, 0.149, 0.31), orange)
	_box(_lid, Vector3(0.16, 0.03, 0.04), Vector3(0, 0.1, 0.64), dark)       # lid handle
	_dirt(_lid, [Vector3(0.24, 0.15, 0.42), Vector3(-0.28, 0.15, 0.2), Vector3(0.05, 0.15, 0.08)], soil)
	# Front latches (flip down first).
	for sx in [-0.3, 0.3]:
		var lp := Node3D.new()
		lp.position = Vector3(sx, 0.07, 0.318)
		_vis.add_child(lp)
		_box(lp, Vector3(0.07, 0.11, 0.025), Vector3(0, 0.03, 0.0), dark)
		_box(lp, Vector3(0.05, 0.02, 0.03), Vector3(0, 0.075, 0.005), steel)
		_latches.append(lp)


func _build_locker(soil: Color) -> void:
	var gm := _mat("gunmetal", soil)
	var orange := _mat("orange", soil)
	var dark := _mat("dark")
	var steel := _mat("steel")
	_box(_vis, Vector3(1.3, 0.32, 0.58), Vector3(0, -0.06, 0), gm, Basis(), true)
	for sx in [-1.0, 1.0]:
		_box(_vis, Vector3(0.06, 0.37, 0.62), Vector3(sx * 0.64, -0.05, 0), steel)
		_box(_vis, Vector3(0.02, 0.05, 0.3), Vector3(sx * 0.675, -0.04, 0), dark)
	for i in 6:
		_box(_vis, Vector3(0.045, 0.34, 0.006), Vector3(-0.56 + float(i) * 0.085, -0.06, 0.292), orange, Basis(Vector3.BACK, 0.6))
	_label(_vis, "EKİPMAN · 3B", Vector3(0.18, -0.07, 0.293), Color(0.85, 0.85, 0.82, 0.85))
	_box(_vis, Vector3(1.18, 0.012, 0.5), Vector3(0, 0.102, 0), _mat("interior"))
	_box(_vis, Vector3(0.78, 0.045, 0.09), Vector3(-0.05, 0.12, 0.06), dark)      # a long case inside
	_box(_vis, Vector3(0.2, 0.05, 0.16), Vector3(0.42, 0.12, -0.08), orange)
	_seal = _box(_vis, Vector3(0.075, 0.035, 0.02), Vector3(0.48, 0.06, 0.298), _mat("seal_red"))
	for sx in [-0.4, 0.0, 0.4]:
		_cyl(_vis, 0.022, 0.14, Vector3(sx, 0.1, -0.295), Basis(Vector3.BACK, PI * 0.5), steel)
	_lid = Node3D.new()
	_lid.position = Vector3(0, 0.1, -0.29)
	_vis.add_child(_lid)
	_box(_lid, Vector3(1.22, 0.06, 0.58), Vector3(0, 0.03, 0.29), gm, Basis(), true)
	for i in 4:
		_box(_lid, Vector3(0.24, 0.01, 0.025), Vector3(-0.32, 0.062, 0.12 + float(i) * 0.06), dark)
	_box(_lid, Vector3(0.9, 0.006, 0.06), Vector3(0.12, 0.062, 0.47), orange)
	_box(_lid, Vector3(0.18, 0.025, 0.03), Vector3(0.36, 0.075, 0.52), steel)
	_dirt(_lid, [Vector3(-0.35, 0.07, 0.4), Vector3(0.3, 0.07, 0.18)], soil)


func _build_kitbag(soil: Color) -> void:
	var fabric := _mat("fabric", soil)
	var strap := _mat("strap")
	var orange := _mat("orange", soil)
	var white := _mat("white", soil)
	var rot := Basis(Vector3.BACK, PI * 0.5)
	var bag := _mesh(_vis, _capsule_mesh(0.2, 0.86), fabric, Vector3(0, -0.08, 0), rot)
	bag.scale = Vector3(0.78, 1.0, 1.0)
	bag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var tm := _torus_mesh(0.196, 0.222)
	for x in [-0.22, 0.2]:
		var s := _mesh(_vis, tm, strap, Vector3(x, -0.08, 0), rot)
		s.scale = Vector3(0.8, 1.0, 1.0)
	_box(_vis, Vector3(0.3, 0.025, 0.05), Vector3(0, 0.085, 0), strap)              # carry strap
	_box(_vis, Vector3(0.26, 0.15, 0.07), Vector3(0.04, -0.09, 0.17), fabric)        # side pocket
	_box(_vis, Vector3(0.1, 0.07, 0.006), Vector3(-0.08, -0.07, 0.207), orange)      # unit patch
	_box(_vis, Vector3(0.36, 0.01, 0.14), Vector3(0, 0.072, 0.0), _mat("interior"))  # the opening
	# The flap, hinged at the back of the opening.
	_lid = Node3D.new()
	_lid.position = Vector3(0, 0.075, -0.075)
	_vis.add_child(_lid)
	_box(_lid, Vector3(0.42, 0.03, 0.18), Vector3(0, 0.02, 0.085), _mat("fabric_dark", soil))
	_box(_lid, Vector3(0.05, 0.035, 0.05), Vector3(0, 0.025, 0.17), strap)
	_dirt(_lid, [Vector3(0.12, 0.04, 0.08)], soil)
	# The fallen soldier's helmet beside it, visor cracked, half in the dirt.
	var hp := Node3D.new()
	hp.position = Vector3(0.62, -0.11, 0.14)
	hp.basis = Basis(Vector3(0.3, 0.2, 1.0).normalized(), 0.7)
	_vis.add_child(hp)
	_sphere(hp, 0.165, Vector3.ZERO, white)
	var visor := _sphere(hp, 0.135, Vector3(0.0, 0.01, 0.06), _mat("visor"))
	visor.scale = Vector3(1.0, 0.78, 0.75)
	var band := _mesh(hp, _torus_mesh(0.14, 0.17), orange, Vector3(0, -0.1, 0), Basis())
	band.scale = Vector3(1.0, 0.6, 1.0)
	_box(hp, Vector3(0.006, 0.09, 0.004), Vector3(0.03, 0.02, 0.163), _mat("dark"), Basis(Vector3.BACK, 0.5))  # the crack
	# Dog tags.
	_box(_vis, Vector3(0.05, 0.004, 0.028), Vector3(0.4, -0.2, 0.26), _mat("steel"), Basis(Vector3.UP, 0.4))
	_box(_vis, Vector3(0.05, 0.004, 0.028), Vector3(0.43, -0.198, 0.29), _mat("steel"), Basis(Vector3.UP, 1.1))


func _build_relic(soil: Color) -> void:
	var obs := _mat("obsidian")
	var stone := _mat("stone", soil)
	_glow = (_mat("relic_glow") as StandardMaterial3D).duplicate() as StandardMaterial3D
	var ring := _mesh(_vis, _torus_mesh(0.28, 0.42), stone, Vector3(0, -0.24, 0), Basis())
	ring.scale = Vector3(1.0, 0.75, 1.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for i in 8:
		var a := TAU * float(i) / 8.0
		_box(_vis, Vector3(0.05, 0.02, 0.025), Vector3(cos(a) * 0.35, -0.195, sin(a) * 0.35), _glow, Basis(Vector3.UP, -a))
	_cyl(_vis, 0.2, 0.06, Vector3(0, -0.25, 0), Basis(), stone)                     # the socket
	# The crystal.
	_core = Node3D.new()
	_core.position = Vector3(0, 0.05, 0)
	_vis.add_child(_core)
	_mesh(_core, _bipyramid_mesh(0.12, 0.6, 6, 0.08), _glow, Vector3.ZERO, Basis())
	# Three obsidian shards closed around it (they bloom open).
	var shard := _bipyramid_mesh(0.11, 0.66, 4, 0.12)
	for i in 3:
		var a := TAU * float(i) / 3.0 + 0.3
		var d := Vector3(cos(a), 0, sin(a))
		var pv := Node3D.new()
		pv.position = d * 0.07 + Vector3(0, -0.2, 0)
		_vis.add_child(pv)
		var m := _mesh(pv, shard, obs, d * 0.06 + Vector3(0, 0.3, 0), Basis(Vector3.UP, a))
		m.scale = Vector3(1.0, 1.0, 0.55)
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		# A thin glowing seam down the shard's inner face.
		_box(pv, Vector3(0.012, 0.42, 0.012), d * 0.012 + Vector3(0, 0.3, 0), _glow)
		_petals.append([pv, Vector3.UP.cross(d).normalized()])
	_dirt(_vis, [Vector3(0.3, -0.16, 0.1), Vector3(-0.22, -0.17, -0.25)], soil)


# --- Mesh helpers ---------------------------------------------------------------------------------

func _mesh(parent: Node3D, m: Mesh, mat: Material, pos: Vector3, b: Basis) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.transform = Transform3D(b, pos)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = 70.0
	parent.add_child(mi)
	return mi


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, b := Basis(), shadow := false) -> MeshInstance3D:
	var mi := _mesh(parent, _prim("box_%.3f_%.3f_%.3f" % [size.x, size.y, size.z]), mat, pos, b)
	if shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mi


func _cyl(parent: Node3D, r: float, h: float, pos: Vector3, b: Basis, mat: Material) -> MeshInstance3D:
	return _mesh(parent, _prim("cyl_%.3f_%.3f" % [r, h]), mat, pos, b)


func _sphere(parent: Node3D, r: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	return _mesh(parent, _prim("sph_%.3f" % r), mat, pos, Basis())


## Lumps of the planet's soil stuck on top.
func _dirt(parent: Node3D, spots: Array, soil: Color) -> void:
	var m := _prim("sph_0.090")
	var mat := _mat("soil", soil)
	var i := 0
	for s in spots:
		var mi := _mesh(parent, m, mat, s as Vector3, Basis(Vector3.UP, float(i) * 1.7))
		mi.scale = Vector3(1.0 + 0.35 * float(i % 2), 0.42, 0.8 + 0.2 * float(i % 3))
		i += 1


func _label(parent: Node3D, text: String, pos: Vector3, col: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 40
	l.pixel_size = 0.0021
	l.outline_size = 0
	l.modulate = col
	l.shaded = true
	l.double_sided = false
	l.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	l.visibility_range_end = [12.0, 18.0, 25.0][clampi(HudLevel.level(), 0, 2)]   # (HUD level: Sade only up close)
	l.position = pos
	parent.add_child(l)


## Shared primitive meshes, one per shape (every prop uses the same few).
static func _prim(key: String) -> Mesh:
	var m: Mesh = _meshes.get(key)
	if m != null:
		return m
	var p := key.split("_")
	var a := float(p[1]) if p.size() > 1 else 0.0
	var b := float(p[2]) if p.size() > 2 else 0.0
	var c := float(p[3]) if p.size() > 3 else 0.0
	match p[0]:
		"box":
			var bm := BoxMesh.new()
			bm.size = Vector3(a, b, c)
			m = bm
		"cyl":
			var cm := CylinderMesh.new()
			cm.top_radius = a
			cm.bottom_radius = a
			cm.height = b
			cm.radial_segments = 14
			cm.rings = 1
			m = cm
		"sph":
			var sm := SphereMesh.new()
			sm.radius = a
			sm.height = a * 2.0
			sm.radial_segments = 18 if a > 0.1 else 8
			sm.rings = 9 if a > 0.1 else 5
			m = sm
		"cap":
			var pm := CapsuleMesh.new()
			pm.radius = a
			pm.height = b
			pm.radial_segments = 18
			pm.rings = 6
			m = pm
		"tor":
			var tm := TorusMesh.new()
			tm.inner_radius = a
			tm.outer_radius = b
			tm.rings = 28
			tm.ring_segments = 8
			m = tm
	_meshes[key] = m
	return m


static func _capsule_mesh(r: float, h: float) -> Mesh:
	return _prim("cap_%.3f_%.3f" % [r, h])


static func _torus_mesh(inner: float, outer: float) -> Mesh:
	return _prim("tor_%.3f_%.3f" % [inner, outer])


static func _bipyramid_mesh(r: float, h: float, sides: int, waist: float) -> Mesh:
	var key := "bip_%.3f_%.3f_%d_%.3f" % [r, h, sides, waist]
	var m: Mesh = _meshes.get(key)
	if m == null:
		m = _bipyramid(r, h, sides, waist)
		_meshes[key] = m
	return m


## A faceted double cone (flat normals): radius r at the waist (waist m above the middle), height h.
static func _bipyramid(r: float, h: float, sides: int, waist: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var top := Vector3(0, h * 0.5, 0)
	var bot := Vector3(0, -h * 0.5, 0)
	var ring: Array = []
	for i in sides:
		var a := TAU * float(i) / float(sides)
		ring.append(Vector3(cos(a) * r, waist, sin(a) * r))
	for i in sides:
		var p0: Vector3 = ring[i]
		var p1: Vector3 = ring[(i + 1) % sides]
		# Clockwise seen from outside (Godot's front faces).
		st.add_vertex(top)
		st.add_vertex(p0)
		st.add_vertex(p1)
		st.add_vertex(bot)
		st.add_vertex(p1)
		st.add_vertex(p0)
	st.generate_normals()
	return st.commit()


# --- Materials ------------------------------------------------------------------------------------

## Shared materials; painted parts take the soil colour as caked dirt (keyed per soil colour).
static func _mat(key: String, soil := Color(-1, 0, 0)) -> Material:
	var dirty := soil.r >= 0.0
	var mk := key + ("_" + soil.to_html(false) if dirty else "")
	if _mats.has(mk):
		return _mats[mk]
	var m := StandardMaterial3D.new()
	match key:
		"white":
			m.albedo_color = Color(0.74, 0.74, 0.71)
			m.roughness = 0.8
		"orange":
			m.albedo_color = Color(0.78, 0.38, 0.12)
			m.roughness = 0.72
		"gunmetal":
			m.albedo_color = Color(0.25, 0.27, 0.29)
			m.metallic = 0.35
			m.roughness = 0.62
		"dark":
			m.albedo_color = Color(0.1, 0.105, 0.115)
			m.metallic = 0.3
			m.roughness = 0.6
		"steel":
			m.albedo_color = Color(0.5, 0.51, 0.53)
			m.metallic = 0.55
			m.roughness = 0.45
		"interior":
			m.albedo_color = Color(0.06, 0.065, 0.07)
			m.roughness = 0.9
		"fabric":
			m.albedo_color = Color(0.6, 0.4, 0.2)
			m.roughness = 0.97
		"fabric_dark":
			m.albedo_color = Color(0.42, 0.28, 0.15)
			m.roughness = 0.97
		"strap":
			m.albedo_color = Color(0.14, 0.13, 0.12)
			m.roughness = 0.9
		"visor":
			m.albedo_color = Color(0.62, 0.46, 0.18)
			m.metallic = 0.5
			m.roughness = 0.18
		"seal_red", "seal_green", "seal_off":
			var c := Color(1.0, 0.2, 0.12) if key == "seal_red" else (Color(0.3, 1.0, 0.45) if key == "seal_green" else Color(0.25, 0.08, 0.06))
			m.albedo_color = c
			m.emission_enabled = key != "seal_off"
			m.emission = c
			m.emission_energy_multiplier = 3.0
		"obsidian":
			m.albedo_color = Color(0.07, 0.065, 0.09)
			m.metallic = 0.3
			m.roughness = 0.22
			m.rim_enabled = true
			m.rim = 0.6
			m.rim_tint = 0.4
		"stone":
			m.albedo_color = Color(0.32, 0.3, 0.33)
			m.roughness = 0.95
		"relic_glow":
			m.albedo_color = RELIC_COL
			m.emission_enabled = true
			m.emission = RELIC_COL
			m.emission_energy_multiplier = 2.0
		"soil":
			m.albedo_color = soil.darkened(0.08) if dirty else Color(0.42, 0.33, 0.22)
			m.roughness = 1.0
	if dirty and key != "soil":
		_dirt_detail(m, soil)
	_mats[mk] = m
	return m


## Caked dirt: the soil colour mixed in through a blotchy noise mask (object-space triplanar).
static func _dirt_detail(m: StandardMaterial3D, soil: Color) -> void:
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	img.fill(soil.darkened(0.12))
	m.detail_enabled = true
	m.detail_mask = _noise_mask()
	m.detail_albedo = ImageTexture.create_from_image(img)
	m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_1
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(1.3, 1.3, 1.3)


static func _noise_mask() -> NoiseTexture2D:
	if _mask == null:
		var n := FastNoiseLite.new()
		n.seed = 77
		n.frequency = 0.03
		n.fractal_octaves = 4
		var g := Gradient.new()
		g.set_color(0, Color(0, 0, 0))
		g.set_color(1, Color(1, 1, 1))
		g.set_offset(0, 0.45)
		g.set_offset(1, 0.7)
		_mask = NoiseTexture2D.new()
		_mask.width = 128
		_mask.height = 128
		_mask.seamless = true
		_mask.noise = n
		_mask.color_ramp = g
	return _mask


static func _glint_mat() -> Material:
	if _mats.has("_glint"):
		return _mats["_glint"]
	if _star == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		for y in 64:
			for x in 64:
				var u := (float(x) + 0.5) / 32.0 - 1.0
				var v := (float(y) + 0.5) / 32.0 - 1.0
				var a := exp(-absf(u) * 16.0) * exp(-absf(v) * 2.4) + exp(-absf(v) * 16.0) * exp(-absf(u) * 2.4) \
						+ exp(-(u * u + v * v) * 20.0)
				img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
		_star = ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = _star
	m.albedo_color = Color(1.0, 0.93, 0.78, 0.95)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats["_glint"] = m
	return m
