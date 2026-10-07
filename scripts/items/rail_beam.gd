extends Node3D
## The Delici Raylı Tüfek's shot in the world (scripts/items/railgun.gd) and the helpers the gun and
## the multiplayer replay share. Everything here is local look / host-side terrain; damage is dealt by
## the shooter's machine (railgun.gd; a client's hits become claims through Game.damage_target).
##
## Look of one shot (one node, frees itself after LIFE s):
##   core      a bright white-cyan rod muzzle -> end, gone in ~0.25 s
##   sheath    a wider cyan-violet glow around it (~0.45 s)
##   corkscrew two plasma strands spiralling around the line (shader on one cylinder), widening and
##             fading over ~1 s
##   marks     where the beam went INTO the ground and came OUT of it: a glowing violet scorch (Decal,
##             emission fading over ~4 s) with a hot spot billboard; at an exit a spray of dust, rock
##             bits and glowing slag along the beam, at an entry a smaller puff back at the shooter
##   lights    a muzzle flash, a short light at every mark and at the end (a buried glow when the soil
##             stopped it)
##   sound     replay only (the shooter's gun plays its own 2D report): a 3D crack + electric tail at
##             the muzzle, a dirt burst at the exits (in vacuum: a dull thump only)
##
## Helpers (static):
##   soil_profile(from, dir, length) -> Array of [t0, t1]: the solid soil along the line (metres from
##       `from`, sorted), from the planets' density fields: works through rock and far from any collision.
##   soil_total(segs) / soil_before(segs, t) / soil_between(a, b)
##   spawn(parent, muzzle, to, charge, segs, origin, dir, with_sound) -> the FX node (segs measured
##       from `origin` along `dir`, e.g. the shooter's eye)
##   bore(segs, origin, dir, team)  the thin bore: small DIG stamps along the soil part (host / single
##       player only: Net.is_client() does nothing; synced like any dig). Balance.RAIL_BORE_*.
##   replay(parent, from, to, charge, team) -> FX  for the multiplayer layer: the other player's shot
##       (rail_fired(from, to, charge) on their railgun): the same look, the bore on the host.
##   prewarm() / stream(name)  synthesized sounds, built once on a worker thread:
##       rail_hum (loop, the charge whine: pitch it up with the charge), rail_crack, rail_tail,
##       rail_vent, rail_ready, rail_fizzle

const Balance := preload("res://scripts/war/balance.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const Dig := preload("res://scripts/player/dig.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")

const CYAN := Color(0.38, 0.95, 1.0)
const VIOLET := Color(0.72, 0.36, 1.0)
const LIFE := 4.6                      # s the node lives (the scorch marks are the last to go)
const CORE_T := 0.25
const SHEATH_T := 0.45
const SPIRAL_T := 1.05
const MARK_T := 4.2
const PITCH := 0.75                    # m per turn of the corkscrew
const MAX_MARKS := 6

const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 col_a : source_color = vec4(0.38, 0.95, 1.0, 1.0);
uniform vec4 col_b : source_color = vec4(0.72, 0.36, 1.0, 1.0);
uniform float fade = 1.0;
uniform float energy = 4.0;
uniform float kind = 0.0;          // 0 core, 1 sheath, 2 corkscrew
uniform float turns = 40.0;
uniform float len = 10.0;
varying float v_along;
varying float v_around;

void vertex() {
	v_along = VERTEX.y + 0.5;
	v_around = atan(VERTEX.z, VERTEX.x) / 6.2831853 + 0.5;
}

void fragment() {
	float facing = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	vec3 c;
	float a;
	if (kind < 0.5) {
		float core = pow(facing, 1.3);
		c = mix(col_a.rgb, vec3(1.0), 0.55 + 0.45 * core) * energy;
		a = 0.3 + 0.7 * core;
	} else if (kind < 1.5) {
		float g = pow(facing, 2.2);
		float ripple = 0.8 + 0.2 * sin(v_along * len * 1.7 - TIME * 40.0);
		c = mix(col_b.rgb, col_a.rgb, g) * energy;
		a = g * 0.75 * ripple;
	} else {
		float s = fract(v_around * 2.0 + v_along * turns - TIME * 1.6);
		float band = smoothstep(0.30, 0.46, s) * (1.0 - smoothstep(0.54, 0.70, s));
		float flick = 0.6 + 0.4 * sin(v_along * len * 2.3 + TIME * 23.0);
		float hue = 0.5 + 0.5 * sin(v_along * len * 0.35 + TIME * 3.0);
		c = mix(col_a.rgb, col_b.rgb, hue) * energy;
		a = band * flick * (0.35 + 0.65 * facing);
	}
	ALBEDO = c;
	ALPHA = clamp(a * fade, 0.0, 1.0);
}
"""

static var _beam_shader: Shader
static var _unit_cyl: CylinderMesh
static var _glow_tex: Texture2D
static var _scorch_tex: Texture2D
static var _dirt_snd: AudioStream
static var _gen: RefCounted = null      # Synth (worker thread) until its streams are taken
static var _task := -1
static var _snd := {}

var _t := 0.0
var _core: MeshInstance3D
var _sheath: MeshInstance3D
var _spiral: MeshInstance3D
var _core_m: ShaderMaterial
var _sheath_m: ShaderMaterial
var _spiral_m: ShaderMaterial
var _len := 1.0
var _a := Vector3.ZERO
var _b := Vector3.ZERO
var _charge := 1.0
var _lights: Array = []                # [OmniLight3D, energy, life]
var _decals: Array = []                # [Decal, energy]
var _spots: Array = []                 # [MeshInstance3D, StandardMaterial3D, size]


# =================================================================================================
# Soil along a line (density fields)
# =================================================================================================

## Solid soil along from + dir * t, t in [0, length]: sorted [t0, t1] intervals. Marches each planet's
## terrain shell with density_fast (≤ 0.5 m near the surface, ≤ 1 m in rock, longer steps high in the
## air), refines every crossing with the exact density. Cheap enough per shot (~100-250 samples).
static func soil_profile(from: Vector3, dir: Vector3, length: float) -> Array:
	var out: Array = []
	for b in Bodies.all():
		if not is_instance_valid(b) or not (b as Node).has_method("density_fast"):
			continue
		var c: Vector3 = (b as Node3D).global_position
		var shell := float(b.get("radius")) + float(b.get("max_height")) + 2.0
		var oc := from - c
		var bb := oc.dot(dir)
		var disc := bb * bb - (oc.length_squared() - shell * shell)
		if disc <= 0.0:
			continue
		var sq := sqrt(disc)
		var t := maxf(-bb - sq, 0.0)
		var t_end := minf(-bb + sq, length)
		if t >= t_end:
			continue
		var d := float(b.density_fast(from + dir * t))
		var solid := d < 0.0
		var start := t
		var guard := 0
		while t < t_end and guard < 600:
			guard += 1
			var adv := 0.5
			if d > 2.0:
				adv = clampf(d * 0.6, 0.5, 2.0)        # in the air: the ground is at least ~d away
			elif d < -2.0:
				adv = 1.0                              # in rock: tunnels are ≥ ~2 m wide
			var tn := minf(t + adv, t_end)
			var dn := float(b.density_fast(from + dir * tn))
			var sn := dn < 0.0
			if sn != solid:
				var cross := _refine(b, from, dir, t, tn, solid)
				if sn:
					start = cross
				else:
					out.append([start, cross])
				solid = sn
			t = tn
			d = dn
		if solid:
			out.append([start, t_end])
	if out.size() > 1:
		out.sort_custom(func(x, y): return float(x[0]) < float(y[0]))
	return out


## Bisection of a solid / air crossing between ta (solid == solid_a) and tb with the exact density.
static func _refine(b, from: Vector3, dir: Vector3, ta: float, tb: float, solid_a: bool) -> float:
	var lo := ta
	var hi := tb
	for i in 6:
		var m := (lo + hi) * 0.5
		var sm := float(b.density_at(from + dir * m)) < 0.0
		if sm == solid_a:
			lo = m
		else:
			hi = m
	return (lo + hi) * 0.5


static func soil_total(segs: Array) -> float:
	var s := 0.0
	for g in segs:
		s += float(g[1]) - float(g[0])
	return s


## Metres of soil before distance t along the line.
static func soil_before(segs: Array, t: float) -> float:
	var s := 0.0
	for g in segs:
		var a := float(g[0])
		if a >= t:
			break
		s += minf(float(g[1]), t) - a
	return s


## Metres of soil on the straight line a -> b.
static func soil_between(a: Vector3, b: Vector3) -> float:
	var d := b - a
	var l := d.length()
	if l < 0.05:
		return 0.0
	return soil_total(soil_profile(a, d / l, l))


# =================================================================================================
# Bore (host / single player)
# =================================================================================================

## Small DIG stamps every RAIL_BORE_STEP m along the soil the beam crossed (at most RAIL_BORE_MAX).
static func bore(segs: Array, origin: Vector3, dir: Vector3, team: String) -> void:
	if Net.is_client():
		return
	var n := 0
	for g in segs:
		var t := float(g[0]) + 0.35
		var t1 := float(g[1]) - 0.2
		while t <= t1 and n < Balance.RAIL_BORE_MAX:
			var p := origin + dir * t
			var body := Game.dominant_body(p)
			if body != null:
				Dig.dig_at(body, p, Balance.RAIL_BORE_R, Dig.MODE_DIG, Balance.RAIL_BORE_AMOUNT,
						Vector3.ZERO, Vector3.UP, -1.0, team)
			n += 1
			t += Balance.RAIL_BORE_STEP
		if n >= Balance.RAIL_BORE_MAX:
			return


## The other player's shot (multiplayer): the look and, on the host, the bore. No damage here.
static func replay(parent: Node, from: Vector3, to: Vector3, charge: float, team := "") -> Node3D:
	if parent == null or not is_instance_valid(parent):
		return null
	var d := to - from
	var l := d.length()
	if l < 0.2 or l > Balance.RAIL_RANGE + 20.0:
		return null
	var dir := d / l
	var segs := soil_profile(from, dir, l + 0.3)
	var fx := spawn(parent, from, to, clampf(charge, 0.0, 1.0), segs, from, dir, true)
	bore(segs, from, dir, team)
	return fx


# =================================================================================================
# Spawn
# =================================================================================================

static func spawn(parent: Node, muzzle: Vector3, to: Vector3, charge: float, segs: Array, origin: Vector3,
		dir: Vector3, with_sound := false) -> Node3D:
	var fx: Node3D = load("res://scripts/items/rail_beam.gd").new()
	fx.name = "RailBeam"
	parent.add_child(fx)
	fx.call("_setup", muzzle, to, charge, segs, origin, dir, with_sound)
	return fx


func _setup(muzzle: Vector3, to: Vector3, charge: float, segs: Array, origin: Vector3, dir: Vector3,
		with_sound: bool) -> void:
	_shared()
	global_transform = Transform3D.IDENTITY
	_a = muzzle
	_b = to
	_charge = clampf(charge, 0.05, 1.0)
	_len = maxf(_a.distance_to(_b), 0.05)
	var k := _charge
	_core_m = _beam_mat(0.0, 5.0 + 5.0 * k)
	_sheath_m = _beam_mat(1.0, 2.2 + 2.0 * k)
	_spiral_m = _beam_mat(2.0, 2.6 + 2.4 * k)
	_spiral_m.set_shader_parameter("turns", _len / PITCH)
	for m: ShaderMaterial in [_core_m, _sheath_m, _spiral_m]:
		m.set_shader_parameter("len", _len)
	_core = _cyl(_core_m)
	_sheath = _cyl(_sheath_m)
	_spiral = _cyl(_spiral_m)
	_place(_core, lerpf(0.018, 0.034, k))
	_place(_sheath, lerpf(0.06, 0.11, k))
	_place(_spiral, lerpf(0.07, 0.12, k))
	# Muzzle flash light and a violet star at the muzzle.
	_light(_a + (_b - _a).normalized() * 0.4, VIOLET.lerp(CYAN, 0.4), 5.0 + 6.0 * k, 7.0, 0.14)
	_spot(_a, VIOLET.lerp(Color.WHITE, 0.3), 0.35 + 0.35 * k, 0.12)
	# Entry / exit marks along the soil (measured from `origin`), the spray at the exits.
	var marks := 0
	var t_end := origin.distance_to(to)
	for g in segs:
		if marks >= MAX_MARKS:
			break
		var t0 := float(g[0])
		var t1 := float(g[1])
		if t0 > 0.05 and t0 < t_end - 0.05:
			_mark(origin + dir * t0, dir, false)
			marks += 1
		if t1 < t_end - 0.05 and marks < MAX_MARKS:
			_mark(origin + dir * t1, dir, true)
			marks += 1
	# The end: open air (faint), buried in the soil (a dull glow under the ground), or a target.
	var buried := false
	for g in segs:
		if float(g[0]) < t_end - 0.05 and float(g[1]) >= t_end - 0.05:
			buried = true
	_light(_b - dir * (0.5 if buried else 0.0), VIOLET, (2.0 if buried else 1.2) * (0.5 + 0.5 * k), 5.0 if buried else 3.5, 0.45)
	if with_sound:
		_sounds(segs, origin, dir, t_end)


func _shared() -> void:
	if _beam_shader == null:
		_beam_shader = Shader.new()
		_beam_shader.code = BEAM_SHADER
	if _unit_cyl == null:
		_unit_cyl = CylinderMesh.new()
		_unit_cyl.top_radius = 1.0
		_unit_cyl.bottom_radius = 1.0
		_unit_cyl.height = 1.0
		_unit_cyl.radial_segments = 12
		_unit_cyl.rings = 1
		_unit_cyl.cap_top = false
		_unit_cyl.cap_bottom = false
	if _glow_tex == null:
		_glow_tex = _radial_tex(false)
		_scorch_tex = _radial_tex(true)
	if _dirt_snd == null:
		_dirt_snd = Snd.rand("bimp/dirt_heavy")


func _beam_mat(kind: float, energy: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _beam_shader
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("col_a", CYAN)
	m.set_shader_parameter("col_b", VIOLET)
	m.render_priority = 3
	return m


func _cyl(m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _unit_cyl
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.extra_cull_margin = 4.0
	add_child(mi)
	return mi


static func _basis_y(d: Vector3) -> Basis:
	var y := d.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


func _place(mi: MeshInstance3D, r: float) -> void:
	var bb := _basis_y(_b - _a)
	mi.global_transform = Transform3D(Basis(bb.x * r, bb.y * _len, bb.z * r), (_a + _b) * 0.5)


func _light(p: Vector3, c: Color, energy: float, rng: float, life: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = c
	l.light_energy = energy
	l.omni_range = rng
	l.shadow_enabled = false
	add_child(l)
	l.global_position = p
	_lights.append([l, energy, life])


## A hot-spot billboard (additive, fades over `life`).
func _spot(p: Vector3, c: Color, size: float, life: float) -> void:
	var q := QuadMesh.new()
	q.size = Vector2.ONE * size
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = _glow_tex
	m.albedo_color = Color(c.r * 2.5, c.g * 2.5, c.b * 2.5, 1.0)
	m.no_depth_test = false
	m.disable_receive_shadows = true
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.global_position = p
	_spots.append([mi, m, life])


## A scorch where the beam went in (exit = false) or came out (exit = true) of the ground.
func _mark(p: Vector3, dir: Vector3, exit: bool) -> void:
	var body := Game.dominant_body(p)
	var n := -dir if not exit else dir
	if body != null and body.has_method("density_normal"):
		n = body.density_normal(p)
	var up := (p - body.global_position).normalized() if body != null else n
	var soil := Color(0.42, 0.36, 0.27)
	if body != null and body.get("soil_color") is Color:
		soil = body.get("soil_color")
	# Glowing scorch on the surface (a Decal projects along its -Y: its +Y is the normal).
	var dc := Decal.new()
	dc.texture_albedo = _scorch_tex
	dc.texture_emission = _glow_tex
	dc.modulate = Color(1.0, 1.0, 1.0, 1.0)
	dc.emission_energy = 6.0 * (0.5 + 0.5 * _charge)
	dc.albedo_mix = 0.85
	dc.upper_fade = 0.3
	dc.lower_fade = 0.3
	var s := lerpf(0.7, 1.15, _charge) * (1.2 if exit else 0.9)
	dc.size = Vector3(s, 1.2, s)
	add_child(dc)
	dc.global_transform = Transform3D(_basis_y(n).rotated(n, randf() * TAU), p)
	_decals.append([dc, dc.emission_energy])
	_spot(p + n * 0.06, VIOLET.lerp(CYAN, 0.3), (0.55 if exit else 0.4) * (0.6 + 0.4 * _charge), 1.3)
	_light(p + n * 0.4, VIOLET, 2.5 * (0.5 + 0.5 * _charge), 4.0, 0.35)
	var g: Vector3 = -up * 7.85
	if exit:
		# Out of the ground: dust and rock bits blown along the beam, glowing slag.
		_burst(p, dir, 26.0, soil.lightened(0.15), 24, 1.7, 2.5, 8.0, 0.8, g * 0.12, false)
		_burst(p, dir, 34.0, soil.darkened(0.35), 14, 1.6, 4.0, 11.0, 0.09, g, true)
		_sparks(p, dir, g * 0.6)
	else:
		# Into the ground: a smaller puff back toward the shooter and a few sparks.
		var back := (-dir + n).normalized()
		_burst(p, back, 40.0, soil.lightened(0.15), 12, 1.2, 1.5, 4.5, 0.55, g * 0.12, false)
		_sparks(p, back, g * 0.6)


## A one-shot particle burst: soft dust quads (rock = false) or small solid chunks (rock = true).
func _burst(p: Vector3, d: Vector3, spread: float, col: Color, amount: int, life: float, vmin: float,
		vmax: float, size: float, grav: Vector3, rock: bool) -> void:
	var cp := CPUParticles3D.new()
	cp.one_shot = true
	cp.explosiveness = 0.92
	cp.amount = amount
	cp.lifetime = life
	cp.local_coords = false
	cp.direction = d.normalized()          # (the node has no rotation: local = world)
	cp.spread = spread
	cp.initial_velocity_min = vmin
	cp.initial_velocity_max = vmax
	cp.gravity = grav
	cp.damping_min = 0.5 if rock else 2.0
	cp.damping_max = 1.0 if rock else 4.0
	if rock:
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * size
		var rm := StandardMaterial3D.new()
		rm.albedo_color = col
		rm.roughness = 0.95
		bm.material = rm
		cp.mesh = bm
		cp.scale_amount_min = 0.5
		cp.scale_amount_max = 1.6
		cp.particle_flag_rotate_y = true
		cp.angular_velocity_min = -400.0
		cp.angular_velocity_max = 400.0
	else:
		var q := QuadMesh.new()
		q.size = Vector2.ONE * size
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_texture = DigFx.soft_texture()
		q.material = m
		cp.mesh = q
		cp.scale_amount_min = 0.6
		cp.scale_amount_max = 2.2
		var gr := Gradient.new()
		gr.set_color(0, Color(col.r, col.g, col.b, 0.6))
		gr.set_color(1, Color(col.r, col.g, col.b, 0.0))
		cp.color_ramp = gr
	add_child(cp)
	cp.global_position = p
	cp.emitting = true


## Glowing slag sparks (stretched along their flight).
func _sparks(p: Vector3, d: Vector3, grav: Vector3) -> void:
	var cp := CPUParticles3D.new()
	cp.one_shot = true
	cp.explosiveness = 0.95
	cp.amount = 18
	cp.lifetime = 0.55
	cp.local_coords = false
	cp.direction = d.normalized()
	cp.spread = 38.0
	cp.initial_velocity_min = 4.0
	cp.initial_velocity_max = 13.0
	cp.gravity = grav
	cp.particle_flag_align_y = true
	var q := QuadMesh.new()
	q.size = Vector2(0.02, 0.12)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	q.material = m
	cp.mesh = q
	var gr := Gradient.new()
	gr.set_color(0, Color(2.6, 2.2, 3.0, 1.0))
	gr.set_color(1, Color(1.4, 0.4, 2.2, 0.0))
	cp.color_ramp = gr
	add_child(cp)
	cp.global_position = p
	cp.emitting = true


## The replayed report: a 3D crack + tail at the muzzle, a dirt burst at each exit (vacuum: a thump).
func _sounds(segs: Array, origin: Vector3, dir: Vector3, t_end: float) -> void:
	var air := 1.0
	if Game.sfx != null and is_instance_valid(Game.sfx) and Game.sfx.get("listener_air") != null:
		air = float(Game.sfx.get("listener_air"))
	if air < 0.05:
		_snd3d(stream("rail_crack"), _a, -14.0, 0.55, 30.0)
		return
	_snd3d(stream("rail_crack"), _a, 2.0 * _charge - 2.0, randf_range(0.96, 1.04), 160.0)
	_snd3d(stream("rail_tail"), _a, -6.0, 1.0, 90.0)
	var n := 0
	for g in segs:
		var t1 := float(g[1])
		if t1 < t_end - 0.05 and n < 3:
			_snd3d(_dirt_snd, origin + dir * t1, -2.0, randf_range(0.85, 1.0), 45.0)
			n += 1


func _snd3d(st: AudioStream, p: Vector3, vol: float, pitch: float, max_d: float) -> void:
	if st == null:
		return
	var a := AudioStreamPlayer3D.new()
	a.stream = st
	a.volume_db = vol
	a.pitch_scale = pitch
	a.unit_size = 10.0
	a.max_distance = max_d
	add_child(a)
	a.global_position = p
	a.play()


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFE:
		queue_free()
		return
	var kc := clampf(1.0 - _t / CORE_T, 0.0, 1.0)
	_core.visible = kc > 0.0
	if _core.visible:
		_core_m.set_shader_parameter("fade", kc * kc)
	var ks := clampf(1.0 - _t / SHEATH_T, 0.0, 1.0)
	_sheath.visible = ks > 0.0
	if _sheath.visible:
		_sheath_m.set_shader_parameter("fade", ks)
		_place(_sheath, lerpf(0.06, 0.11, _charge) * (1.0 + 0.8 * (1.0 - ks)))
	var kp := clampf(1.0 - _t / SPIRAL_T, 0.0, 1.0)
	_spiral.visible = kp > 0.0
	if _spiral.visible:
		_spiral_m.set_shader_parameter("fade", kp * kp * (3.0 - 2.0 * kp))
		_place(_spiral, lerpf(0.07, 0.12, _charge) * (1.0 + 2.2 * (1.0 - kp)))
	for e in _lights:
		var l: OmniLight3D = e[0]
		if not is_instance_valid(l):
			continue
		var k := clampf(1.0 - _t / float(e[2]), 0.0, 1.0)
		l.light_energy = float(e[1]) * k * k
		l.visible = k > 0.0
	for e in _spots:
		var mi: MeshInstance3D = e[0]
		var k := clampf(1.0 - _t / float(e[2]), 0.0, 1.0)
		mi.visible = k > 0.0
		if mi.visible:
			var m: StandardMaterial3D = e[1]
			m.albedo_color.a = k
	for e in _decals:
		var dc: Decal = e[0]
		var k := clampf(1.0 - _t / MARK_T, 0.0, 1.0)
		dc.emission_energy = float(e[1]) * pow(k, 2.5)
		dc.modulate.a = minf(k * 1.6, 1.0)


# =================================================================================================
# Textures
# =================================================================================================

## 64² radial: the glow (white core, violet falloff) or the scorch (dark, soft edge).
static func _radial_tex(scorch: bool) -> Texture2D:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(n, n) * 0.5
	for y in n:
		for x in n:
			var r := (Vector2(x + 0.5, y + 0.5) - c).length() / (n * 0.5)
			if scorch:
				var a := clampf(1.0 - smoothstep(0.35, 1.0, r), 0.0, 1.0) * 0.85
				img.set_pixel(x, y, Color(0.04, 0.03, 0.05, a))
			else:
				var core := exp(-r * r * 18.0)
				var halo := exp(-r * r * 4.0) * 0.6
				var col := Color(1.0, 1.0, 1.0).lerp(Color(0.72, 0.36, 1.0), clampf(r * 1.6, 0.0, 1.0))
				var a2 := clampf(core + halo, 0.0, 1.0) * (1.0 - smoothstep(0.85, 1.0, r))
				img.set_pixel(x, y, Color(col.r, col.g, col.b, a2))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# =================================================================================================
# Sounds (synthesized once on a worker thread)
# =================================================================================================

static func prewarm() -> void:
	if not _snd.is_empty() or _task >= 0:
		return
	var g := Synth.new()
	_gen = g
	_task = WorkerThreadPool.add_task(g.build, false, "rail_audio")


static func stream(name: String) -> AudioStream:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		if _gen != null:
			_snd = _gen.get("out")
			_gen = null
	if _snd.is_empty() and _task < 0:
		prewarm()
	return _snd.get(name) as AudioStream


## Waits for a running synth task (scene teardown).
static func finish() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		if _gen != null:
			_snd = _gen.get("out")
			_gen = null


class Synth extends RefCounted:
	const RATE := 44100
	var out := {}

	func build() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = 90210
		var d := {}
		d["rail_hum"] = _wav(_hum(rng), 0.6, true)
		d["rail_crack"] = _wav(_crack(rng), 0.95, false)
		d["rail_tail"] = _wav(_tail(rng), 0.7, false)
		d["rail_vent"] = _wav(_vent(rng), 0.55, false)
		d["rail_ready"] = _wav(_ready_s(), 0.5, false)
		d["rail_fizzle"] = _wav(_fizzle(rng), 0.55, false)
		out = d

	static func _wav(s: PackedFloat32Array, peak: float, loop: bool) -> AudioStreamWAV:
		var m := 0.0001
		for v in s:
			m = maxf(m, absf(v))
		var data := PackedByteArray()
		data.resize(s.size() * 2)
		for i in s.size():
			data.encode_s16(i * 2, int(clampf(s[i] / m * peak, -1.0, 1.0) * 32000.0))
		var w := AudioStreamWAV.new()
		w.format = AudioStreamWAV.FORMAT_16_BITS
		w.mix_rate = RATE
		w.stereo = false
		w.data = data
		if loop:
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = s.size()
		return w

	## The charge whine (1 s seamless loop; the gun pitches it 0.55 -> 2.5 with the charge): a 220 Hz
	## buzz with harmonics, a capacitor whine at 1760 Hz with a 7 Hz tremolo, a little hiss.
	static func _hum(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := RATE
		var s := PackedFloat32Array()
		s.resize(n)
		var lp := 0.0
		var nz := PackedFloat32Array()
		nz.resize(n)
		for i in n:
			lp += 0.08 * ((rng.randf() * 2.0 - 1.0) - lp)
			nz[i] = lp
		for i in n:
			var t := float(i) / RATE
			var ph := TAU * 220.0 * t
			var buzz := tanh((sin(ph) + 0.5 * sin(ph * 2.0) + 0.3 * sin(ph * 3.0) + 0.15 * sin(ph * 5.0)) * 1.6)
			var whine := sin(TAU * 1760.0 * t) * (0.55 + 0.45 * sin(TAU * 7.0 * t))
			var shimmer := sin(TAU * 2640.0 * t) * 0.25 * (0.5 + 0.5 * sin(TAU * 11.0 * t))
			s[i] = buzz * 0.45 + whine * 0.32 + shimmer + nz[i] * 0.5
		# Crossfade the seam (the noise is not periodic).
		var x := int(0.05 * RATE)
		for i in x:
			var k := float(i) / float(x)
			s[n - x + i] = lerpf(s[n - x + i], s[i], k)
		return s

	## The shot: a hard transient, a falling zap chirp, a metallic ring, a low thump.
	static func _crack(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(1.0 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var ph := 0.0
		var hp_prev := 0.0
		var hp := 0.0
		for i in n:
			var t := float(i) / RATE
			var w := rng.randf() * 2.0 - 1.0
			hp = 0.86 * (hp + w - hp_prev)
			hp_prev = w
			var snap := hp * exp(-t * 160.0) * 1.6
			var f := 4200.0 * exp(-t * 26.0) + 150.0
			ph += TAU * f / RATE
			var zap := tanh(sin(ph) * 2.5) * exp(-t * 8.5) * 0.65
			var ring := (sin(TAU * 1830.0 * t) + 0.7 * sin(TAU * 2710.0 * t) + 0.45 * sin(TAU * 3950.0 * t)) * exp(-t * 7.0) * 0.16
			var thump := sin(TAU * (48.0 + 30.0 * exp(-t * 20.0)) * t) * exp(-t * 9.0) * 0.8
			var hiss := hp * exp(-t * 11.0) * 0.22
			s[i] = snap + zap + ring + thump + hiss
		return s

	## Electric tail: sparse decaying crackle, a mains-like buzz, ionised hiss.
	static func _tail(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(1.6 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var click := 0.0
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			if rng.randf() < 0.0035 * exp(-t * 2.2):
				click = (rng.randf() * 2.0 - 1.0) * (0.6 + 0.4 * rng.randf())
			click *= 0.93
			var w := rng.randf() * 2.0 - 1.0
			lp += 0.25 * (w - lp)
			var buzz := tanh((sin(TAU * 100.0 * t) + 0.6 * sin(TAU * 150.0 * t)) * 2.0) * exp(-t * 2.4) * 0.28 \
					* (0.6 + 0.4 * sin(TAU * 9.0 * t))
			var hiss := (w - lp) * exp(-t * 3.2) * 0.3
			s[i] = click * exp(-t * 1.4) + buzz + hiss
		return s

	## Capacitor vent after a shot: a rising, then dying hiss.
	static func _vent(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(0.75 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var lp := 0.0
		var lp2 := 0.0
		for i in n:
			var t := float(i) / RATE
			var w := rng.randf() * 2.0 - 1.0
			lp += 0.45 * (w - lp)
			lp2 += 0.06 * (lp - lp2)
			var env := minf(t / 0.06, 1.0) * exp(-t * 4.0)
			s[i] = (lp - lp2) * env
		return s

	## Ready again: two rising tones.
	static func _ready_s() -> PackedFloat32Array:
		var n := int(0.22 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		for i in n:
			var t := float(i) / RATE
			var f := 1320.0 if t < 0.09 else 1980.0
			var te := t if t < 0.09 else t - 0.09
			s[i] = sin(TAU * f * t) * exp(-te * 26.0) * minf(te * 500.0, 1.0)
		return s

	## A charge let go too early: a falling sine with a little crackle.
	static func _fizzle(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(0.3 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var ph := 0.0
		for i in n:
			var t := float(i) / RATE
			ph += TAU * (900.0 * exp(-t * 7.0) + 120.0) / RATE
			var cr := (rng.randf() * 2.0 - 1.0) * 0.25 * exp(-t * 10.0)
			s[i] = (sin(ph) * 0.7 + cr) * minf(t * 300.0, 1.0) * exp(-t * 7.0)
		return s
