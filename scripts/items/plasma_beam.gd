extends Node3D
## The Plazma Kesici's beam in the world (scripts/items/plasma_cutter.gd), one persistent node per
## cutter: the local player's (driven every frame by the gun) and the other player's replay in
## multiplayer (driven by net_players.gd beam events, `remote = true`). Look and sound only: the
## cutting (planet brush, synced by net_terrain.gd) and the damage (Game.damage_target, a client's
## become claims) are the shooter's machine's, in the gun.
##
## Look while on (everything world space; the node itself sits at the identity, top_level):
##   core      a thin white-hot rod emitter -> cut, pulses running along it, a flicker
##   sheath    a wider electric-blue glow round it, rippling, whiter toward the cut
##   haze      a refracting heat-shimmer sleeve round the beam and a shimmer billboard rising off the
##             cut (screen-texture distortion)
##   flare     a small blue-white star and light at the emitter
##   hit       a flickering white-orange light and hot spot, a fountain of sparks along the surface
##             normal, molten slag drops that fall toward the planet and cool white -> orange -> dark,
##             smoke (soil) or a dark burn puff (bodies), a frying sizzle loop
##   molten    glowing rims on the freshly cut soil: a pool of MOLTEN_MAX decals laid along the cut
##             (one every MOLTEN_GAP s, at once when the cut moved MOLTEN_STEP m), cooling white ->
##             yellow -> orange -> dark red over MOLTEN_LIFE s, the scorch fading last
## Remote (`remote`): the emitter end follows `tip` (the avatar's third-person muzzle), the cut end
## eases toward the last received point (NET_LERP), the beam drops after NET_TIMEOUT s without news;
## the gun's own hiss loop plays here in 3D (the local gun plays its 2D one).
##
## Surfaces (surf): SURF_AIR (beam ends in the air: no hit effects), SURF_SOIL, SURF_BODY (a
## character), SURF_METAL (a structure / vehicle: sparks, no rims).
##
## Sounds (static, synthesized once on a worker thread; prewarm() / stream(name)):
##   plasma_loop (seamless: buzz, roar, whine, crackle), plasma_sizzle (seamless frying),
##   plasma_ignite, plasma_stop, plasma_vent (steam, cooling ticks), plasma_alarm, plasma_ready

const DigFx := preload("res://scripts/items/dig_fx.gd")

const SURF_AIR := 0
const SURF_SOIL := 1
const SURF_BODY := 2
const SURF_METAL := 3

# --- Look -------------------------------------------------------------------------------------------
const CORE_COL := Color(1.0, 0.97, 0.92)
const GLOW_COL := Color(0.55, 0.78, 1.0)
const HOT_COL := Color(1.0, 0.66, 0.32)
const CORE_R := 0.02
const SHEATH_R := 0.07
const HAZE_R := 0.15
const CORE_E := 6.0                    # emission of the core / sheath at full heat-free power
const SHEATH_E := 2.6
const HAZE_STRENGTH := 0.012           # screen-UV shift of the shimmer sleeve
const HIT_LIGHT_E := 3.2
const HIT_LIGHT_R := 4.5
const FLARE_LIGHT_E := 1.4
const MOLTEN_MAX := 20
const MOLTEN_LIFE := 5.0
const MOLTEN_GAP := 0.09
const MOLTEN_STEP := 0.28
const MOLTEN_SIZE := 1.45
const MOLTEN_E := 4.5                  # rim emission when fresh
const MOLTEN_DEPTH := 1.3
const MOLTEN_CAM_MIN := 1.3            # m: no rim this close to the camera (its box would catch the view model)
const GRAVITY := 7.85                  # m/s² the slag falls with (the planets' surface gravity, roughly)
const NET_TIMEOUT := 0.4
const NET_LERP := 18.0

const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 col_core : source_color = vec4(1.0, 0.97, 0.92, 1.0);
uniform vec4 col_glow : source_color = vec4(0.55, 0.78, 1.0, 1.0);
uniform float energy = 4.0;
uniform float kind = 0.0;          // 0 core, 1 sheath
uniform float len = 5.0;
uniform float fade = 1.0;
uniform float heat = 0.0;
varying float v_along;

float hash(float n) { return fract(sin(n) * 43758.5453); }
float vnoise(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
}

void vertex() {
	v_along = VERTEX.y + 0.5;
}

void fragment() {
	float facing = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float d = v_along * len;
	float pulse = 0.7 + 0.3 * vnoise(d * 2.5 - TIME * 42.0);
	float flick = 0.82 + 0.18 * vnoise(TIME * 53.0);
	// The cut end runs hotter (white-yellow), the emitter end electric blue; a hot gun yellows it.
	vec3 glow = mix(col_glow.rgb, vec3(1.0, 0.8, 0.55), smoothstep(0.55, 1.0, v_along) * 0.6 + heat * 0.25);
	vec3 c;
	float a;
	if (kind < 0.5) {
		float core = pow(facing, 1.4);
		c = mix(glow, col_core.rgb, 0.45 + 0.55 * core) * energy * pulse * flick;
		a = 0.3 + 0.7 * core;
	} else {
		float g = pow(facing, 2.6);
		float rip = 0.65 + 0.35 * sin(d * 7.0 - TIME * 61.0);
		c = glow * energy * flick;
		a = g * 0.55 * rip * pulse;
	}
	a *= smoothstep(0.0, 0.03, v_along);
	ALBEDO = c;
	ALPHA = clamp(a * fade, 0.0, 1.0);
}
"""

const HAZE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float strength = 0.012;
uniform float fade = 1.0;
uniform float len = 5.0;
uniform float billboard = 0.0;
varying float v_along;
varying vec2 v_uv;

void vertex() {
	v_along = VERTEX.y + 0.5;
	v_uv = UV;
	if (billboard > 0.5) {
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
}

void fragment() {
	float w;
	vec2 n;
	if (billboard > 0.5) {
		float r = length(v_uv - vec2(0.5));
		w = 1.0 - smoothstep(0.12, 0.5, r);
		n = vec2(sin(v_uv.y * 23.0 + TIME * 13.0), cos(v_uv.x * 19.0 - TIME * 17.0 + v_uv.y * 9.0));
	} else {
		w = pow(clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.5);
		n = vec2(sin(v_along * len * 9.0 - TIME * 21.0), cos(v_along * len * 7.0 + TIME * 17.0));
	}
	w *= fade;
	ALBEDO = textureLod(screen_tex, SCREEN_UV + n * strength * w, 0.0).rgb;
	ALPHA = clamp(w, 0.0, 1.0);
}
"""

static var _beam_shader: Shader
static var _haze_shader: Shader
static var _unit_cyl: CylinderMesh
static var _glow_tex: Texture2D
static var _rim_tex: Texture2D
static var _scorch_tex: Texture2D
static var _gen: RefCounted = null
static var _task := -1
static var _snd := {}

var remote := false                    # the other player's cutter (see the header)
var tip: Node3D = null                 # remote: the avatar's third-person muzzle
var flare_size := 0.07                 # emitter star (m): small next to the local view, bigger remote

var _on := false
var _vis := 0.0                        # beam fade 0..1 (a quick ignite / collapse)
var _a := Vector3.ZERO
var _b := Vector3.ZERO
var _n := Vector3.UP
var _surf := SURF_AIR
var _heat := 0.0
var _slot := false
var _t := 0.0
# Remote targets.
var _net_from := Vector3.ZERO
var _net_to := Vector3.ZERO
var _net_age := 99.0
var _net_fresh := false
var _norm_t := 0.0
# Parts.
var _core: MeshInstance3D
var _sheath: MeshInstance3D
var _haze: MeshInstance3D
var _core_m: ShaderMaterial
var _sheath_m: ShaderMaterial
var _haze_m: ShaderMaterial
var _rise: MeshInstance3D
var _rise_m: ShaderMaterial
var _flare: MeshInstance3D
var _flare_m: StandardMaterial3D
var _spot: MeshInstance3D
var _spot_m: StandardMaterial3D
var _hit_light: OmniLight3D
var _flare_light: OmniLight3D
var _sparks: CPUParticles3D
var _slag: CPUParticles3D
var _smoke: CPUParticles3D
var _smoke_ramp: Gradient
var _molten: Array = []                # [Decal, age]
var _molten_t := 0.0
var _molten_last := Vector3.INF
var _sizzle: AudioStreamPlayer3D
var _loop: AudioStreamPlayer3D         # remote only
var _oneshot: AudioStreamPlayer3D      # remote only


# =================================================================================================
# Creation and driving
# =================================================================================================

## A beam node under `parent` (a world node: the gun keeps its own as a top_level child).
static func make(parent: Node, is_remote := false) -> Node3D:
	var b: Node3D = load("res://scripts/items/plasma_beam.gd").new()
	b.name = "PlasmaBeam"
	b.set("remote", is_remote)
	b.set("flare_size", 0.22 if is_remote else 0.07)
	parent.add_child(b)
	return b


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_shared()
	_core_m = _beam_mat(0.0, CORE_E)
	_sheath_m = _beam_mat(1.0, SHEATH_E)
	_haze_m = ShaderMaterial.new()
	_haze_m.shader = _haze_shader
	_haze_m.set_shader_parameter("strength", HAZE_STRENGTH)
	_haze_m.render_priority = 1
	_core = _cyl(_core_m)
	_sheath = _cyl(_sheath_m)
	_haze = _cyl(_haze_m)
	# Shimmer rising off the cut (a billboard of the same haze).
	_rise_m = ShaderMaterial.new()
	_rise_m.shader = _haze_shader
	_rise_m.set_shader_parameter("billboard", 1.0)
	_rise_m.set_shader_parameter("strength", 0.02)
	_rise_m.render_priority = 1
	var rq := QuadMesh.new()
	rq.size = Vector2(0.9, 1.3)
	_rise = _mi(rq, _rise_m)
	_flare_m = _glow_mat(GLOW_COL.lerp(Color.WHITE, 0.45), 2.6)
	var fq := QuadMesh.new()
	fq.size = Vector2.ONE
	_flare = _mi(fq, _flare_m)
	_spot_m = _glow_mat(HOT_COL.lerp(Color.WHITE, 0.4), 3.0)
	var sq := QuadMesh.new()
	sq.size = Vector2.ONE
	_spot = _mi(sq, _spot_m)
	_hit_light = _light(HOT_COL.lerp(Color.WHITE, 0.25), HIT_LIGHT_R)
	_flare_light = _light(GLOW_COL, 2.6)
	_sparks = _make_sparks()
	_slag = _make_slag()
	_smoke = _make_smoke()
	_sizzle = _audio3d(10.0, 40.0)
	if remote:
		_loop = _audio3d(9.0, 70.0)
		_oneshot = _audio3d(9.0, 60.0)
	_set_parts(false)


## Local gun, every frame while the beam is on: emitter (world), cut end, the surface normal there,
## SURF_*, heat 0..1, slot = the Kesme Düzlemi sweep (a tighter, brighter beam).
func drive(from: Vector3, to: Vector3, normal: Vector3, surf: int, heat: float, slot := false) -> void:
	_on = true
	_a = from
	_b = to
	_n = normal if normal.length_squared() > 0.01 else (from - to).normalized()
	_surf = surf
	_heat = heat
	_slot = slot


## Local gun: the beam is off (the hit effects run out, the rims keep cooling).
func idle() -> void:
	_on = false


## Remote: one received beam event. state 0 off, 1 beam, 2 slot sweep.
func net_update(state: int, from: Vector3, to: Vector3, surf: int, heat: float) -> void:
	if state <= 0:
		if _on and _oneshot != null:
			_play_once("plasma_stop", -6.0, randf_range(0.95, 1.05))
		_on = false
		_net_age = 99.0
		return
	if not _on and _oneshot != null:
		_play_once("plasma_ignite", -4.0, randf_range(0.95, 1.05))
	if not _on or _net_age > NET_TIMEOUT:
		_b = to                            # (a fresh beam starts at its point, no sweep from the old one)
	_on = true
	_net_from = from
	_net_to = to
	_net_age = 0.0
	_net_fresh = true
	_surf = clampi(surf, SURF_AIR, SURF_METAL)
	_heat = clampf(heat, 0.0, 1.0)
	_slot = state == 2


func is_on() -> bool:
	return _on


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	if remote:
		_remote_tick(delta)
	_vis = move_toward(_vis, 1.0 if _on else 0.0, delta * (14.0 if _on else 9.0))
	var shown := _vis > 0.001
	_set_parts(shown)
	if shown:
		_update_beam()
	_update_hit(delta)
	_update_molten(delta)
	_update_audio(delta)


func _remote_tick(delta: float) -> void:
	_net_age += delta
	if _on and _net_age > NET_TIMEOUT:
		_on = false                        # the off event got lost / the player left
	if not _on:
		return
	_b = _b.lerp(_net_to, 1.0 - exp(-NET_LERP * delta))
	if tip != null and is_instance_valid(tip) and tip.is_inside_tree():
		_a = tip.global_position
	else:
		_a = _net_from
	# The surface normal at the cut: the density field's (a few times a second), else back along the beam.
	_norm_t -= delta
	if _norm_t <= 0.0 or _net_fresh:
		_norm_t = 0.12
		_net_fresh = false
		_n = (_a - _b).normalized()
		if _surf == SURF_SOIL:
			var body := Game.dominant_body(_b)
			if body != null and body.has_method("density_normal"):
				var dn: Vector3 = body.density_normal(_b)
				if dn.length_squared() > 0.01:
					_n = dn.normalized()


func _update_beam() -> void:
	var d := _b - _a
	var len := d.length()
	if len < 0.02:
		_core.visible = false
		_sheath.visible = false
		_haze.visible = false
		return
	var jit := 1.0 + randf_range(-0.12, 0.12)
	var k := _vis
	var sk := 0.8 if _slot else 1.0
	for m: ShaderMaterial in [_core_m, _sheath_m]:
		m.set_shader_parameter("len", len)
		m.set_shader_parameter("heat", _heat)
		m.set_shader_parameter("fade", k)
	_haze_m.set_shader_parameter("len", len)
	_haze_m.set_shader_parameter("fade", k)
	_core_m.set_shader_parameter("energy", CORE_E * (1.25 if _slot else 1.0))
	_place(_core, CORE_R * jit * sk * (0.6 + 0.4 * k))
	_place(_sheath, SHEATH_R * (1.0 + randf_range(-0.08, 0.08)) * sk * (0.5 + 0.5 * k))
	_place(_haze, HAZE_R)
	# The emitter star and its light.
	_flare.global_position = _a
	_flare.scale = Vector3.ONE * flare_size * randf_range(0.85, 1.15) * maxf(k, 0.02)
	_flare_m.albedo_color.a = k
	_flare_light.global_position = _a + d / len * 0.15
	_flare_light.light_energy = FLARE_LIGHT_E * k * randf_range(0.8, 1.0)


func _update_hit(delta: float) -> void:
	var hitting := _on and _surf != SURF_AIR and _vis > 0.3
	var g := _gravity(_b)
	var flick := 0.75 + 0.25 * sin(_t * 41.0) * sin(_t * 23.0 + 1.3) + randf_range(-0.08, 0.08)
	_hit_light.visible = hitting
	_spot.visible = hitting
	_rise.visible = hitting and _surf == SURF_SOIL
	if hitting:
		_hit_light.global_position = _b + _n * 0.35
		_hit_light.light_energy = HIT_LIGHT_E * flick * (1.3 if _slot else 1.0)
		_spot.global_position = _b + _n * 0.05
		_spot.scale = Vector3.ONE * randf_range(0.38, 0.52) * (0.75 if _surf == SURF_BODY else 1.0)
		_spot_m.albedo_color.a = 0.85 + 0.15 * flick
		_rise.global_position = _b + _n * 0.25 - g.normalized() * 0.55
	_set_emit(_sparks, hitting, _b + _n * 0.04, _n, g * 0.55)
	_set_emit(_slag, hitting and _surf == SURF_SOIL, _b + _n * 0.06, _n, g)
	_set_emit(_smoke, hitting and _surf != SURF_METAL, _b + _n * 0.12, _n, -g * 0.07)
	if hitting:
		var sc := Color(0.32, 0.29, 0.26) if _surf == SURF_SOIL else Color(0.12, 0.11, 0.11)
		_smoke_ramp.set_color(0, Color(sc.r, sc.g, sc.b, 0.55))
		_smoke_ramp.set_color(1, Color(sc.r, sc.g, sc.b, 0.0))
	# Molten rims along the cut (soil only).
	_molten_t -= delta
	if hitting and _surf == SURF_SOIL:
		var moved := _molten_last == Vector3.INF or _molten_last.distance_to(_b) > MOLTEN_STEP
		var cam := get_viewport().get_camera_3d()
		var near := cam != null and cam.global_position.distance_to(_b) < MOLTEN_CAM_MIN
		if moved and not near:
			_molten_t = MOLTEN_GAP
			_molten_last = _b
			_add_molten(_b, _n)
		elif _molten_t <= 0.0 and not near:
			# Holding on one spot keeps the newest rim white-hot instead of stacking more on it.
			_molten_t = MOLTEN_GAP
			_reheat_newest()
	elif not hitting:
		_molten_last = Vector3.INF


func _set_emit(cp: CPUParticles3D, on: bool, p: Vector3, dir: Vector3, grav: Vector3) -> void:
	if on:
		cp.global_position = p
		cp.direction = dir
		cp.gravity = grav
	if cp.emitting != on:
		cp.emitting = on


## The cooling of every rim: white-hot -> yellow -> orange -> dark red -> the scorch fades.
func _update_molten(delta: float) -> void:
	for e: Array in _molten:
		var dc: Decal = e[0]
		if not dc.visible:
			continue
		var age := float(e[1]) + delta
		e[1] = age
		if age >= MOLTEN_LIFE:
			dc.visible = false
			continue
		var u := age / MOLTEN_LIFE
		dc.modulate = Color(cool_color(age), 1.0 - smoothstep(0.7, 1.0, u))
		dc.emission_energy = MOLTEN_E * pow(1.0 - u, 2.2) + 0.05


## Colour of molten slag `age` s after the cut (also the drops' ramp and the gun's cooling glow).
static func cool_color(age: float) -> Color:
	if age < 0.25:
		return Color(1.0, 0.96, 0.84).lerp(Color(1.0, 0.8, 0.45), age / 0.25)
	if age < 1.2:
		return Color(1.0, 0.8, 0.45).lerp(Color(1.0, 0.45, 0.14), (age - 0.25) / 0.95)
	if age < 3.0:
		return Color(1.0, 0.45, 0.14).lerp(Color(0.62, 0.12, 0.04), (age - 1.2) / 1.8)
	return Color(0.62, 0.12, 0.04).lerp(Color(0.18, 0.05, 0.03), clampf((age - 3.0) / 2.0, 0.0, 1.0))


func _add_molten(p: Vector3, n: Vector3) -> void:
	# A cooled-out decal of the pool, else a new one, else the oldest still cooling.
	var pick: Array = []
	for e: Array in _molten:
		if not (e[0] as Decal).visible:
			pick = e
			break
	if pick.is_empty() and _molten.size() < MOLTEN_MAX:
		var nd := Decal.new()
		nd.texture_albedo = _scorch_tex
		nd.texture_emission = _rim_tex
		nd.albedo_mix = 0.9
		nd.upper_fade = 0.25
		nd.lower_fade = 0.25
		nd.normal_fade = 0.0
		nd.cull_mask = 1
		add_child(nd)
		pick = [nd, 0.0]
		_molten.append(pick)
	if pick.is_empty():
		for e: Array in _molten:
			if pick.is_empty() or float(e[1]) > float(pick[1]):
				pick = e
	pick[1] = 0.0
	var dc: Decal = pick[0]
	var s := MOLTEN_SIZE * randf_range(0.85, 1.15)
	dc.size = Vector3(s, MOLTEN_DEPTH, s)
	dc.global_transform = Transform3D(_basis_y(n).rotated(n, randf() * TAU), p)
	dc.modulate = cool_color(0.0)
	dc.emission_energy = MOLTEN_E
	dc.visible = true


func _reheat_newest() -> void:
	var newest: Array = []
	for e: Array in _molten:
		if (e[0] as Decal).visible and (newest.is_empty() or float(e[1]) < float(newest[1])):
			newest = e
	if newest.is_empty():
		_add_molten(_b, _n)
	else:
		newest[1] = 0.0


func _update_audio(_delta: float) -> void:
	var air := 1.0
	if Game.sfx != null and is_instance_valid(Game.sfx) and Game.sfx.get("listener_air") != null:
		air = float(Game.sfx.get("listener_air"))
	var mute := air < 0.05                         # vacuum: no sound carries (the gun has its suit thump)
	var hitting := _on and _surf != SURF_AIR and not mute
	_loop_vol(_sizzle, "plasma_sizzle", hitting, _b,
			{SURF_SOIL: -4.0, SURF_BODY: -2.0, SURF_METAL: -7.0}.get(_surf, -10.0), 0.9 + 0.2 * _heat)
	if _loop != null:
		_loop_vol(_loop, "plasma_loop", _on and not mute, _a, -3.0 if _slot else -5.0, 0.95 + 0.15 * _heat)


func _loop_vol(p: AudioStreamPlayer3D, sname: String, on: bool, at: Vector3, vol: float, pitch: float) -> void:
	if on:
		if not p.playing:
			var st := stream(sname)
			if st == null:
				return
			p.stream = st
			p.volume_db = vol - 18.0
			p.play(randf() * 0.8)
		p.global_position = at
		p.volume_db = move_toward(p.volume_db, vol, 2.5)
		p.pitch_scale = pitch
	elif p.playing:
		p.volume_db -= 3.0
		if p.volume_db < -40.0:
			p.stop()


func _play_once(sname: String, vol: float, pitch: float) -> void:
	var st := stream(sname)
	if st == null or _oneshot == null:
		return
	_oneshot.stream = st
	_oneshot.volume_db = vol
	_oneshot.pitch_scale = pitch
	_oneshot.global_position = _a if _a != Vector3.ZERO else _net_from
	_oneshot.play()


func _set_parts(on: bool) -> void:
	for n: Node3D in [_core, _sheath, _haze, _flare]:
		if n != null:
			n.visible = on
	if _flare_light != null:
		_flare_light.visible = on


static func _gravity(p: Vector3) -> Vector3:
	var body := Game.dominant_body(p)
	if body == null or not is_instance_valid(body):
		return Vector3.DOWN * GRAVITY
	var d: Vector3 = body.global_position - p
	return d.normalized() * GRAVITY if d.length_squared() > 0.01 else Vector3.DOWN * GRAVITY


# =================================================================================================
# Parts
# =================================================================================================

func _shared() -> void:
	if _beam_shader == null:
		_beam_shader = Shader.new()
		_beam_shader.code = BEAM_SHADER
		_haze_shader = Shader.new()
		_haze_shader.code = HAZE_SHADER
	if _unit_cyl == null:
		_unit_cyl = CylinderMesh.new()
		_unit_cyl.top_radius = 1.0
		_unit_cyl.bottom_radius = 1.0
		_unit_cyl.height = 1.0
		_unit_cyl.radial_segments = 10
		_unit_cyl.rings = 1
		_unit_cyl.cap_top = false
		_unit_cyl.cap_bottom = false
	if _glow_tex == null:
		_glow_tex = _radial_tex(0)
		_rim_tex = _radial_tex(1)
		_scorch_tex = _radial_tex(2)
	prewarm()


func _beam_mat(kind: float, energy: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _beam_shader
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("col_core", CORE_COL)
	m.set_shader_parameter("col_glow", GLOW_COL)
	m.render_priority = 3
	return m


## Additive glow billboard (the emitter star, the hot spot).
func _glow_mat(c: Color, gain: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.albedo_texture = _glow_tex
	m.albedo_color = Color(c.r * gain, c.g * gain, c.b * gain, 1.0)
	m.disable_receive_shadows = true
	m.render_priority = 4
	return m


func _cyl(m: Material) -> MeshInstance3D:
	return _mi(_unit_cyl, m)


func _mi(mesh: Mesh, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.extra_cull_margin = 4.0
	add_child(mi)
	return mi


func _light(c: Color, rng: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = c
	l.omni_range = rng
	l.light_energy = 0.0
	l.shadow_enabled = false
	l.visible = false
	add_child(l)
	return l


static func _basis_y(d: Vector3) -> Basis:
	var y := d.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y).normalized())


func _place(mi: MeshInstance3D, r: float) -> void:
	var d := _b - _a
	var bb := _basis_y(d)
	mi.global_transform = Transform3D(Basis(bb.x * r, bb.y * d.length(), bb.z * r), (_a + _b) * 0.5)


## Bright stretched sparks thrown off the cut.
func _make_sparks() -> CPUParticles3D:
	var cp := _particles(56, 0.42)
	cp.spread = 55.0
	cp.initial_velocity_min = 2.0
	cp.initial_velocity_max = 6.5
	cp.damping_min = 0.8
	cp.damping_max = 2.0
	cp.particle_flag_align_y = true
	var q := QuadMesh.new()
	q.size = Vector2(0.01, 0.06)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	q.material = m
	cp.mesh = q
	var gr := Gradient.new()
	gr.set_color(0, Color(3.0, 2.7, 2.2, 1.0))
	gr.set_color(1, Color(1.6, 0.45, 0.1, 0.0))
	gr.add_point(0.35, Color(2.6, 1.6, 0.6, 1.0))
	cp.color_ramp = gr
	return cp


## Molten drops: out of the cut a little, then falling toward the planet, cooling on the way.
func _make_slag() -> CPUParticles3D:
	var cp := _particles(14, 1.5)
	cp.spread = 70.0
	cp.initial_velocity_min = 0.3
	cp.initial_velocity_max = 1.8
	cp.damping_min = 0.0
	cp.damping_max = 0.3
	cp.scale_amount_min = 0.5
	cp.scale_amount_max = 1.3
	var sm := SphereMesh.new()
	sm.radius = 0.022
	sm.height = 0.05
	sm.radial_segments = 6
	sm.rings = 3
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	sm.material = m
	cp.mesh = sm
	var gr := Gradient.new()
	gr.set_color(0, Color(3.0, 2.6, 1.7))
	gr.set_color(1, Color(0.16, 0.07, 0.04))
	gr.add_point(0.25, Color(2.4, 1.1, 0.3))
	gr.add_point(0.6, Color(0.9, 0.24, 0.05))
	cp.color_ramp = gr
	return cp


func _make_smoke() -> CPUParticles3D:
	var cp := _particles(12, 1.5)
	cp.spread = 35.0
	cp.initial_velocity_min = 0.4
	cp.initial_velocity_max = 1.4
	cp.damping_min = 0.6
	cp.damping_max = 1.2
	cp.scale_amount_min = 0.7
	cp.scale_amount_max = 2.0
	var q := QuadMesh.new()
	q.size = Vector2.ONE * 0.45
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	cp.mesh = q
	_smoke_ramp = Gradient.new()
	_smoke_ramp.set_color(0, Color(0.32, 0.29, 0.26, 0.55))
	_smoke_ramp.set_color(1, Color(0.32, 0.29, 0.26, 0.0))
	cp.color_ramp = _smoke_ramp
	return cp


func _particles(amount: int, life: float) -> CPUParticles3D:
	var cp := CPUParticles3D.new()
	cp.amount = amount
	cp.lifetime = life
	cp.local_coords = false
	cp.emitting = false
	cp.randomness = 0.4
	add_child(cp)
	return cp


func _audio3d(unit: float, max_d: float) -> AudioStreamPlayer3D:
	var a := AudioStreamPlayer3D.new()
	a.unit_size = unit
	a.max_distance = max_d
	add_child(a)
	return a


## 64² radial textures: 0 the glow (white core, orange falloff), 1 the molten rim (a bright ring with
## a softer middle: the bore's lip), 2 the scorch (dark, soft edge).
static func _radial_tex(kind: int) -> Texture2D:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(n, n) * 0.5
	for y in n:
		for x in n:
			var r := (Vector2(x + 0.5, y + 0.5) - c).length() / (n * 0.5)
			var edge := 1.0 - smoothstep(0.85, 1.0, r)
			match kind:
				0:
					var a := clampf(exp(-r * r * 16.0) + exp(-r * r * 4.0) * 0.55, 0.0, 1.0) * edge
					var col := Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.7, 0.4), clampf(r * 1.5, 0.0, 1.0))
					img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
				1:
					var ring := exp(-pow((r - 0.52) / 0.2, 2.0))
					var mid := exp(-r * r * 7.0) * 0.45
					var w := clampf(ring + mid, 0.0, 1.0) * edge
					img.set_pixel(x, y, Color(w, w, w, w))
				_:
					var a2 := clampf(1.0 - smoothstep(0.4, 1.0, r), 0.0, 1.0) * 0.8
					img.set_pixel(x, y, Color(0.05, 0.035, 0.03, a2))
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
	_task = WorkerThreadPool.add_task(g.build, false, "plasma_audio")


static func stream(sname: String) -> AudioStream:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		finish()
	if _snd.is_empty() and _task < 0:
		prewarm()
	return _snd.get(sname) as AudioStream


## Waits for a running synth task (scene teardown, tests).
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
		rng.seed = 63074
		var d := {}
		d["plasma_loop"] = _wav(_loop(rng), 0.6, true)
		d["plasma_sizzle"] = _wav(_sizzle(rng), 0.6, true)
		d["plasma_ignite"] = _wav(_ignite(rng), 0.8, false)
		d["plasma_stop"] = _wav(_stop(rng), 0.6, false)
		d["plasma_vent"] = _wav(_vent(rng), 0.7, false)
		d["plasma_alarm"] = _wav(_alarm(), 0.45, false)
		d["plasma_ready"] = _wav(_ready_s(), 0.45, false)
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

	## Crossfades the last `sec` into the start so a loop has no seam (the noise is not periodic).
	static func _seam(s: PackedFloat32Array, sec: float) -> void:
		var n := s.size()
		var x := int(sec * RATE)
		for i in x:
			var k := float(i) / float(x)
			s[n - x + i] = lerpf(s[n - x + i], s[i], k)

	## The beam (1.6 s seamless): a saturated 110 Hz arc buzz with a 5 Hz throb, the roar of the jet
	## (band-passed noise), a 2.25 kHz whine fluttering at 12.5 Hz, sparse crackle pops.
	static func _loop(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(1.6 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var lp1 := 0.0
		var lp2 := 0.0
		var pop := 0.0
		for i in n:
			var t := float(i) / RATE
			var w := rng.randf() * 2.0 - 1.0
			lp1 += 0.35 * (w - lp1)
			lp2 += 0.04 * (lp1 - lp2)
			var roar := (lp1 - lp2) * (0.8 + 0.2 * sin(TAU * 5.0 * t))
			var ph := TAU * 110.0 * t
			var buzz := tanh((sin(ph) + 0.5 * sin(ph * 2.0) + 0.3 * sin(ph * 3.0)) * 2.2) * (0.75 + 0.25 * sin(TAU * 5.0 * t))
			var whine := sin(TAU * 2250.0 * t) * 0.12 * (0.6 + 0.4 * sin(TAU * 12.5 * t))
			if rng.randf() < 0.0012:
				pop = (rng.randf() * 2.0 - 1.0) * (0.5 + 0.5 * rng.randf())
			pop *= 0.9
			s[i] = roar * 1.1 + buzz * 0.3 + whine + pop * 0.7
		_seam(s, 0.06)
		return s

	## Frying at the cut (1.4 s seamless): dense tiny crackles, bigger pops now and then, a hiss that
	## swells and dips.
	static func _sizzle(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(1.4 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var c := 0.0
		var big := 0.0
		var hp_prev := 0.0
		var hp := 0.0
		var env := 0.5
		for i in n:
			var t := float(i) / RATE
			if rng.randf() < 0.012:
				c = (rng.randf() * 2.0 - 1.0) * 0.5
			c *= 0.6
			if rng.randf() < 0.0004:
				big = (rng.randf() * 2.0 - 1.0)
			big *= 0.94
			var w := rng.randf() * 2.0 - 1.0
			hp = 0.8 * (hp + w - hp_prev)
			hp_prev = w
			if i % 2000 == 0:
				env = 0.35 + 0.65 * rng.randf()
			s[i] = c + big * 0.8 + hp * 0.18 * (env * 0.7 + 0.3 * sin(TAU * 2.5 * t) ** 2)
		_seam(s, 0.05)
		return s

	## Ignition: a rising zap through a whoosh.
	static func _ignite(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(0.4 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var ph := 0.0
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			ph += TAU * (300.0 + 2400.0 * pow(t / 0.4, 0.6)) / RATE
			var w := rng.randf() * 2.0 - 1.0
			lp += 0.3 * (w - lp)
			var env := minf(t / 0.015, 1.0) * exp(-t * 6.0)
			s[i] = (tanh(sin(ph) * 3.0) * 0.5 + lp * 0.9) * env
		return s

	## The beam collapses: a falling zap with a crackle.
	static func _stop(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(0.35 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var ph := 0.0
		for i in n:
			var t := float(i) / RATE
			ph += TAU * (1800.0 * exp(-t * 9.0) + 160.0) / RATE
			var cr := (rng.randf() * 2.0 - 1.0) * 0.35 * exp(-t * 14.0)
			s[i] = (tanh(sin(ph) * 2.0) * 0.6 + cr) * minf(t * 400.0, 1.0) * exp(-t * 8.0)
		return s

	## The vent (2.4 s): a hard pssht, steam hissing out and dying, metal ticking as it cools.
	static func _vent(rng: RandomNumberGenerator) -> PackedFloat32Array:
		var n := int(2.4 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		var lp := 0.0
		var lp2 := 0.0
		var tick := 0.0
		var tick_f := 3100.0
		var tick_t := 0.0
		for i in n:
			var t := float(i) / RATE
			var w := rng.randf() * 2.0 - 1.0
			lp += 0.55 * (w - lp)
			lp2 += 0.05 * (lp - lp2)
			var steam := (lp - lp2) * (minf(t / 0.03, 1.0) * (0.55 + 0.45 * exp(-t * 6.0)) * (1.0 - smoothstep(1.4, 2.35, t)))
			if t > 0.8 and rng.randf() < 0.00012:
				tick = 0.5 + 0.5 * rng.randf()
				tick_f = rng.randf_range(2600.0, 4200.0)
				tick_t = 0.0
			tick_t += 1.0 / RATE
			var tk := sin(TAU * tick_f * tick_t) * tick * exp(-tick_t * 60.0)
			s[i] = steam + tk * 0.4
		return s

	## Overheat warning: two falling square-ish beeps.
	static func _alarm() -> PackedFloat32Array:
		var n := int(0.42 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		for i in n:
			var t := float(i) / RATE
			var f := 1450.0 if t < 0.18 else 1080.0
			var te := t if t < 0.18 else t - 0.21
			var on := 1.0 if (t < 0.17 or (t > 0.21 and t < 0.4)) else 0.0
			s[i] = tanh(sin(TAU * f * t) * 3.0) * on * minf(te * 300.0, 1.0) * exp(-te * 4.0)
		return s

	## Cool again: two rising tones.
	static func _ready_s() -> PackedFloat32Array:
		var n := int(0.24 * RATE)
		var s := PackedFloat32Array()
		s.resize(n)
		for i in n:
			var t := float(i) / RATE
			var f := 980.0 if t < 0.1 else 1470.0
			var te := t if t < 0.1 else t - 0.1
			s[i] = sin(TAU * f * t) * exp(-te * 24.0) * minf(te * 500.0, 1.0)
		return s
