extends RefCounted
## Shared state and GPU-animated effect pools of the background space battle (space_battle.gd):
## the battle clock, the RNG, the materials, and two ring buffers (MultiMesh) the shaders animate on
## their own (battle_shaders.gd):
##   streak(...)  bolts, heavy slugs, beams, engine / missile trails, sparks, venting
##   flash(...)   explosions, shock rings, flak, muzzle and shield flashes, fires
## An instance is written once when it is born (it may also be born in the future: t0 > now) and
## then lives on the GPU; a slot whose effect is still running is skipped when the ring wraps.
## Plus presets (pop / boom / huge / sparks / shield) and one blast light the hull shader reads.
## Purely cosmetic: no physics, no groups, no sound, no network.

const Shaders := preload("res://scripts/fx/battle_shaders.gd")
const Models := preload("res://scripts/fx/battle_models.gd")

## Streak modes (INSTANCE_CUSTOM.a in the streak shader).
const S_BOLT := 0.0
const S_CONST := 1.0
const S_BEAM := 2.0
const S_TRAIL := 3.0
const S_SPARK := 4.0
## Flash kinds.
const F_GLOW := 0.0
const F_RING := 1.0
const F_DOT := 2.0
const F_SHIELD := 3.0

## HDR colours (linear). Index 0 = home side (white / orange), 1 = rival side (dark / red).
const CORE := Color(1.0, 0.8, 0.55)
const FIRE := Color(1.0, 0.48, 0.16)
const RING := Color(1.0, 0.66, 0.36)
const SPARK := Color(1.0, 0.55, 0.2)
const EMBER := Color(1.0, 0.33, 0.08)
const WARP := Color(0.7, 0.85, 1.0)
const SHIELD := [Color(0.42, 0.7, 1.0), Color(1.0, 0.4, 0.14)]   # home bluish, rival orange-red

var now := 1.0                  # battle clock (s); only advances while the tree runs
var intensity := 0.55           # 0.55 at the start .. 1.0 later (escalation, space_battle.gd)
var rng := RandomNumberGenerator.new()
var root: Node3D

var hull_craft: ShaderMaterial  # fighters / bombers (MultiMesh, GPU dead reckoning)
var glow_craft: ShaderMaterial
var hull_cap: ShaderMaterial    # capital ships and their wreck sections (static meshes)
var glow_cap: ShaderMaterial
var hull_debris: ShaderMaterial # tumbling debris field
var streak_mat: ShaderMaterial
var flash_mat: ShaderMaterial
var _clocked: Array[ShaderMaterial] = []   # get t_now every frame
var _lit: Array[ShaderMaterial] = []       # get the blast light

var bounds := AABB()

var _s_rid: RID
var _s_buf := PackedFloat32Array()
var _s_exp := PackedFloat32Array()
var _s_n := 0
var _s_head := 0
var _s_dirty := false
var _f_rid: RID
var _f_buf := PackedFloat32Array()
var _f_exp := PackedFloat32Array()
var _f_n := 0
var _f_head := 0
var _f_dirty := false
var _h_rid: RID
var _h_buf := PackedFloat32Array()
var _h_dirty := false

var _l_pos := Vector3.ZERO
var _l_col := Color(0, 0, 0)
var _l_rad := 0.0
var _l_t0 := -100.0
var _l_life := 1.0
var _l_on := false


func setup(p_root: Node3D, n_streaks: int, n_flashes: int, n_heads: int, p_bounds: AABB, sun_dir: Vector3) -> void:
	root = p_root
	bounds = p_bounds
	var hull_sh := Shaders.shader(Shaders.HULL)
	var glow_sh := Shaders.shader(Shaders.GLOW)
	hull_craft = Shaders.material(hull_sh, {"sim_mode": 0, "sun_dir": sun_dir})
	glow_craft = Shaders.material(glow_sh, {"sim_mode": 0, "gain": 1.25})
	hull_cap = Shaders.material(hull_sh, {"sim_mode": 1, "sun_dir": sun_dir})
	glow_cap = Shaders.material(glow_sh, {"sim_mode": 1, "gain": 0.9})
	hull_debris = Shaders.material(hull_sh, {"sim_mode": 2, "sun_dir": sun_dir, "emis_gain": 1.0})
	streak_mat = Shaders.material(Shaders.shader(Shaders.STREAK), {})
	flash_mat = Shaders.material(Shaders.shader(Shaders.FLASH), {})
	_clocked = [hull_craft, glow_craft, glow_cap, hull_cap, hull_debris, streak_mat, flash_mat]
	_lit = [hull_craft, hull_cap, hull_debris]
	_s_n = n_streaks
	_s_rid = multimesh(Models.quad(0.0), streak_mat, _s_n, true).multimesh.get_rid()
	_s_buf.resize(_s_n * 16)
	_s_exp.resize(_s_n)
	_f_n = n_flashes
	_f_rid = multimesh(Models.quad(-1.0), flash_mat, _f_n, true).multimesh.get_rid()
	_f_buf.resize(_f_n * 16)
	_f_exp.resize(_f_n)
	_h_rid = multimesh(Models.quad(-1.0), flash_mat, n_heads, true).multimesh.get_rid()
	_h_buf.resize(n_heads * 16)
	# upload the empty (all hidden) pools once: fresh GPU buffers need not be zeroed
	_s_dirty = true
	_f_dirty = true
	_h_dirty = true


## A MultiMeshInstance3D under the battle root: 3D transforms + custom data, no shadows, culled
## against the whole battle volume; transparent pools sort as far away (behind everything else).
func multimesh(mesh: Mesh, mat: Material, count: int, _transparent: bool, colors := false) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.use_colors = colors
	mm.mesh = mesh
	mm.instance_count = count
	mm.custom_aabb = bounds
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	if mat != null:
		mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.custom_aabb = bounds
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# far behind everything in the transparent sort (additive pools, engine plumes)
	mi.sorting_offset = -3000.0
	root.add_child(mi)
	return mi


# --- Pools -----------------------------------------------------------------------------------

func _alloc_s(expire: float) -> int:
	var i := _s_head
	for _k in 4:
		if _s_exp[i] <= now:
			break
		i = (i + 1) % _s_n
	_s_head = (i + 1) % _s_n
	_s_exp[i] = expire
	return i


func _alloc_f(expire: float) -> int:
	var i := _f_head
	for _k in 4:
		if _f_exp[i] <= now:
			break
		i = (i + 1) % _f_n
	_f_head = (i + 1) % _f_n
	_f_exp[i] = expire
	return i


## A camera-facing ribbon: head at `o` at time t0 moving with `vel`, tail = head - axis.
func streak(o: Vector3, vel: Vector3, axis: Vector3, w: float, t0: float, life: float, col: Color, mode: float) -> void:
	var k := _alloc_s(t0 + life) * 16
	_s_buf[k] = vel.x
	_s_buf[k + 1] = axis.x
	_s_buf[k + 2] = w
	_s_buf[k + 3] = o.x
	_s_buf[k + 4] = vel.y
	_s_buf[k + 5] = axis.y
	_s_buf[k + 6] = t0
	_s_buf[k + 7] = o.y
	_s_buf[k + 8] = vel.z
	_s_buf[k + 9] = axis.z
	_s_buf[k + 10] = life
	_s_buf[k + 11] = o.z
	_s_buf[k + 12] = col.r
	_s_buf[k + 13] = col.g
	_s_buf[k + 14] = col.b
	_s_buf[k + 15] = mode
	_s_dirty = true


## A camera-facing billboard at `pos` (drifting with `vel`) growing from s0 to s1 metres; seed
## orients the shield ripple (F_SHIELD).
func flash(pos: Vector3, vel: Vector3, s0: float, s1: float, t0: float, life: float, kind: float, col: Color, inten: float,
		seed := 0.0) -> void:
	var k := _alloc_f(t0 + life) * 16
	_f_buf[k] = s0
	_f_buf[k + 1] = life
	_f_buf[k + 2] = vel.x
	_f_buf[k + 3] = pos.x
	_f_buf[k + 4] = s1
	_f_buf[k + 5] = kind
	_f_buf[k + 6] = vel.y
	_f_buf[k + 7] = pos.y
	_f_buf[k + 8] = t0
	_f_buf[k + 9] = seed
	_f_buf[k + 10] = vel.z
	_f_buf[k + 11] = pos.z
	_f_buf[k + 12] = col.r
	_f_buf[k + 13] = col.g
	_f_buf[k + 14] = col.b
	_f_buf[k + 15] = inten
	_f_dirty = true


## Projectile head `slot` (fixed slots, flash layout, kind F_DOT): a constant glowing dot at `pos`
## from t0, dead-reckoned with `vel`; it fades out by itself 0.25 s after the last update.
func head(slot: int, pos: Vector3, vel: Vector3, size: float, t0: float, col: Color, inten: float) -> void:
	var k := slot * 16
	_h_buf[k] = size
	_h_buf[k + 1] = 0.25
	_h_buf[k + 2] = vel.x
	_h_buf[k + 3] = pos.x
	_h_buf[k + 4] = size
	_h_buf[k + 5] = F_DOT
	_h_buf[k + 6] = vel.y
	_h_buf[k + 7] = pos.y
	_h_buf[k + 8] = t0
	_h_buf[k + 9] = 0.0
	_h_buf[k + 10] = vel.z
	_h_buf[k + 11] = pos.z
	_h_buf[k + 12] = col.r
	_h_buf[k + 13] = col.g
	_h_buf[k + 14] = col.b
	_h_buf[k + 15] = inten
	_h_dirty = true


func head_hide(slot: int) -> void:
	_h_buf[slot * 16 + 1] = 0.0
	_h_dirty = true


## Sends the changed pools to the GPU and the clock / blast light to the materials.
func push() -> void:
	if _s_dirty:
		RenderingServer.multimesh_set_buffer(_s_rid, _s_buf)
		_s_dirty = false
	if _f_dirty:
		RenderingServer.multimesh_set_buffer(_f_rid, _f_buf)
		_f_dirty = false
	if _h_dirty:
		RenderingServer.multimesh_set_buffer(_h_rid, _h_buf)
		_h_dirty = false
	for m in _clocked:
		m.set_shader_parameter("t_now", now)
	var k := 1.0 - (now - _l_t0) / _l_life
	if k > 0.0 and now >= _l_t0:
		var lw := root.global_position + _l_pos
		var kk := k * k
		for m in _lit:
			m.set_shader_parameter("blast", Vector4(lw.x, lw.y, lw.z, _l_rad * (0.6 + 0.4 * k)))
			m.set_shader_parameter("blast_col", Vector3(_l_col.r, _l_col.g, _l_col.b) * kk)
		_l_on = true
	elif _l_on:
		for m in _lit:
			m.set_shader_parameter("blast", Vector4.ZERO)
		_l_on = false


# --- Presets ---------------------------------------------------------------------------------

func rand_dir() -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var a := rng.randf_range(0.0, TAU)
	var r := sqrt(maxf(1.0 - z * z, 0.0))
	return Vector3(r * cos(a), r * sin(a), z)


## A radial shell of glowing sparks.
func sparks(pos: Vector3, base_vel: Vector3, count: int, v0: float, v1: float, length: float,
		life: float, col: Color, t0: float, w := 1.4) -> void:
	for i in count:
		var d := rand_dir()
		var sp := rng.randf_range(v0, v1)
		streak(pos, base_vel + d * sp, d * (length * rng.randf_range(0.6, 1.2)), w, t0,
				life * rng.randf_range(0.6, 1.2), col * rng.randf_range(0.7, 1.3), S_SPARK)


## Small explosion (fighter popped, missile, flak kill).
func pop(pos: Vector3, vel: Vector3, size: float, t0: float) -> void:
	var v := vel * 0.5
	flash(pos, v, size * 0.2, size, t0, 0.38, F_GLOW, CORE, 1.8)
	flash(pos, v, size * 0.6, size * 1.6, t0, 0.8, F_GLOW, FIRE, 0.45)
	sparks(pos, v, 6, 20.0, 60.0, size * 0.18, 0.9, SPARK * 1.6, t0)


## Big explosion: flash, expanding shock ring, lingering glow, debris shell and slow embers.
func boom(pos: Vector3, vel: Vector3, size: float, t0: float) -> void:
	var v := vel * 0.4
	flash(pos, v, size * 0.15, size, t0, 0.55, F_GLOW, CORE, 1.9)
	flash(pos, v, size * 0.2, size * 1.8, t0, 0.85, F_RING, RING, 0.7)
	flash(pos, v, size * 0.8, size * 1.4, t0 + 0.05, 1.8, F_GLOW, FIRE, 0.4)
	sparks(pos, v, 12 + int(size * 0.12), 25.0, 95.0 + size, size * 0.18, 2.0, SPARK * 1.8, t0)
	sparks(pos, v, 4, 8.0, 25.0, size * 0.08, 3.5, EMBER, t0, 2.0)


## Huge blast (capital ship reactor): briefly lights that part of the sky and nearby hulls.
func huge(pos: Vector3, vel: Vector3, size: float, t0: float) -> void:
	flash(pos, vel, size * 0.05, size * 0.35, t0, 1.2, F_GLOW, CORE, 2.0)
	flash(pos, vel, size * 0.3, size * 0.9, t0, 3.2, F_GLOW, FIRE, 0.45)
	flash(pos, vel, size * 0.1, size, t0, 2.0, F_RING, RING, 0.42)
	flash(pos, vel, size * 0.05, size * 0.6, t0 + 0.25, 1.4, F_RING, WARP, 0.28)
	sparks(pos, vel, 40, 40.0, 170.0, size * 0.05, 5.0, SPARK * 1.8, t0, 3.0)
	sparks(pos, vel, 14, 10.0, 40.0, size * 0.02, 7.0, EMBER, t0, 4.0)
	light(pos, Color(1.0, 0.55, 0.25), size * 2.2, 3.0, t0)


## Shield hit: a soft, partial hexagonal ripple (flash shader kind 3) that fades within ~0.4 s;
## bluish on home ships, orange-red on rival ships. Never an opaque disc.
func shield(pos: Vector3, size: float, team: int, inten: float, t0: float, life := 0.38) -> void:
	flash(pos, Vector3.ZERO, size * 0.45, size, t0, life, F_SHIELD, SHIELD[team], inten, rng.randf_range(0.0, TAU))


## The blast light (one at a time; a stronger or newer one replaces a fading one).
func light(pos: Vector3, col: Color, radius: float, life: float, t0: float) -> void:
	var left := 1.0 - (now - _l_t0) / _l_life
	if left > 0.35 and radius < _l_rad:
		return
	_l_pos = pos
	_l_col = col
	_l_rad = radius
	_l_t0 = t0
	_l_life = life
