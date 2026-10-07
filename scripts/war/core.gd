extends Node3D
## A planet's glowing core: a pulsing sphere (radius Balance.CORE_RADIUS) at the planet's centre with
## a shadowless OmniLight that lights the tunnel walls as you dig toward it. Destroying the rival's
## core wins the match, losing our own loses it (scripts/war/war.gd).
##
##   Core.spawn(planet, team)               -> the core (child of the planet node, at its centre)
##   core.blast(pos, crater_r, max_damage)  shell impact: damage falls off over CORE_BLAST_K × crater_r
##                                          from the core's surface
##   Core.drill_all(point, radius, team, dt) an ENEMY drill brush overlapping a core: CORE_DRILL_DPS
##   core.hp, core.hp_max, core.team ("home" / "rival"), core.body (its planet)
## Signals go through Game: Game.core_damaged(body, hp), Game.core_destroyed(body).
## Group "war_core". It is NOT in group "damageable" (bullets and plain area damage ignore it).

const Balance := preload("res://scripts/war/balance.gd")
const GROUP := "war_core"
const CORE_SHIELD_PATH := "res://scripts/war/core_shield.gd"   # × Balance.CORE_SHIELD_MULT while one stands

## Team colours (sRGB): the plasma body, its brighter (still saturated) currents and the dark veins.
## Home: violet / indigo plasma, rival: crimson magma. war_hud.gd and bodies.gd (core_color, the
## rock tint toward the core) use the same hues.
const HOME_COL := Color("7a3cff")
const HOME_HOT := Color("a77bff")
const HOME_VEIN := Color("2a0a6e")
const RIVAL_COL := Color("c4122e")
const RIVAL_HOT := Color("e8433a")
const RIVAL_VEIN := Color("3a0408")
const ENERGY := 1.05                    # surface brightness: the dominant channel stays < ~1.4 (no white clip)
const LIGHT_ENERGY := 1.5               # tunnel light: tints the walls without washing them out

## Plasma ball, unshaded but never near-white: a slow domain-warped flow (fbm) between the body
## colour and its currents, dark veins drifting over it, a soft fresnel rim, a slow pulse; as hp
## drops, dark cracks with hot edges spread and the pulse speeds up and stutters. ALBEDO is
## clamped per channel so the tonemapper never clips it to white.
const CORE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back;
uniform vec3 col : source_color = vec3(0.48, 0.24, 1.0);
uniform vec3 hot : source_color = vec3(0.65, 0.48, 1.0);
uniform vec3 vein : source_color = vec3(0.16, 0.04, 0.43);
uniform float energy = 1.05;
uniform float pulse = 0.0;
uniform float damage = 0.0;      // 0 healthy .. 1 nearly destroyed (cracks, erratic pulse)
uniform float flash = 0.0;       // a hit
varying vec3 lp;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec3(1.7, 9.2, 3.1);
		a *= 0.5;
	}
	return s;
}

void vertex() {
	lp = VERTEX;
}

void fragment() {
	vec3 d = normalize(lp);
	vec3 q = d * 2.4;
	// Slow flow: the pattern is warped by drifting noise.
	vec3 w = vec3(fbm(q + vec3(TIME * 0.05, 0.0, 0.0)), fbm(q + vec3(0.0, TIME * 0.04, 5.2)),
			fbm(q + vec3(3.1, 0.0, TIME * 0.045)));
	float f = fbm(q * 1.3 + w * 1.9 + vec3(0.0, TIME * 0.06, 0.0));
	vec3 c = mix(col, hot, smoothstep(0.42, 0.8, f) * 0.85);
	// Veins: thin dark ridges where a second warped noise crosses 0.5, drifting the other way.
	float vn = fbm(q * 2.2 + w * 1.3 - vec3(TIME * 0.03));
	float veins = 1.0 - smoothstep(0.0, 0.05, abs(vn - 0.5));
	c = mix(c, vein, veins * 0.8);
	// Damage: dark cracks spreading with it, their edges glowing hot.
	float cn = vnoise(d * 7.0 + w * 2.0);
	float crack_w = 0.012 + damage * 0.05;
	float crack = damage * (1.0 - smoothstep(crack_w * 0.5, crack_w, abs(cn - 0.5)));
	float crack_edge = damage * (1.0 - smoothstep(crack_w, crack_w * 2.2, abs(cn - 0.5))) - crack;
	c = mix(c, vein * 0.45, clamp(crack, 0.0, 1.0));
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	float e = energy * (0.8 + 0.3 * pulse) * (1.0 - damage * 0.2) * (1.0 + flash * 0.45);
	vec3 o = c * e + col * fres * 0.5 * e + hot * max(crack_edge, 0.0) * 0.6 * (0.6 + 0.4 * pulse);
	ALBEDO = min(o, vec3(1.45));
}
"""

var team := "home"
var body: Node3D
var hp := Balance.CORE_HP
var hp_max := Balance.CORE_HP
var destroyed := false
var _mat: ShaderMaterial
var _shell_mat: StandardMaterial3D
var _light: OmniLight3D
var _t := 0.0
var _hit_flash := 0.0
var _col := Color(0.3, 0.85, 1.0)


## Creates the core of `planet` for `team` ("home": warm cyan, "rival": red).
static func spawn(planet: Node3D, p_team: String) -> Node3D:
	var c: Node3D = load("res://scripts/war/core.gd").new()
	c.team = p_team
	c.body = planet
	c.name = "Core"
	planet.add_child(c)
	return c


func _ready() -> void:
	add_to_group(GROUP)
	_col = HOME_COL if team == "home" else RIVAL_COL
	var hot := HOME_HOT if team == "home" else RIVAL_HOT
	var sm := SphereMesh.new()
	sm.radius = Balance.CORE_RADIUS
	sm.height = Balance.CORE_RADIUS * 2.0
	sm.radial_segments = 48
	sm.rings = 24
	var sh := Shader.new()
	sh.code = CORE_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("col", _col)
	_mat.set_shader_parameter("hot", hot)
	_mat.set_shader_parameter("vein", HOME_VEIN if team == "home" else RIVAL_VEIN)
	_mat.set_shader_parameter("energy", ENERGY)
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# A soft outer glow shell.
	var gs := SphereMesh.new()
	gs.radius = Balance.CORE_RADIUS * 1.35
	gs.height = Balance.CORE_RADIUS * 2.7
	gs.radial_segments = 32
	gs.rings = 16
	_shell_mat = StandardMaterial3D.new()
	_shell_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shell_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shell_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_shell_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	_shell_mat.albedo_color = Color(_col.r, _col.g, _col.b, 0.1)
	var gm := MeshInstance3D.new()
	gm.mesh = gs
	gm.material_override = _shell_mat
	gm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(gm)
	# The light that shows in the tunnels (no shadows: it reaches the walls through the rock, which
	# is what makes the glow seep in as you get close).
	_light = OmniLight3D.new()
	_light.light_color = _col
	_light.omni_range = Balance.CORE_LIGHT_RANGE
	_light.omni_attenuation = 1.6
	_light.light_energy = LIGHT_ENERGY
	_light.shadow_enabled = false
	_light.light_specular = 0.3
	add_child(_light)


func _process(delta: float) -> void:
	_t += delta
	_hit_flash = maxf(_hit_flash - delta * 2.0, 0.0)
	var dmg := 1.0 - hp / hp_max
	# A slow breath when healthy; faster and stuttering as it is damaged.
	var ph := _t * (1.1 + dmg * 4.5) + dmg * 1.6 * sin(_t * 7.3) * sin(_t * 2.9)
	var pulse := sin(ph) * 0.5 + 0.5
	if destroyed:
		_light.light_energy = move_toward(_light.light_energy, 0.0, delta * 1.0)
		_mat.set_shader_parameter("energy", maxf(float(_mat.get_shader_parameter("energy")) - delta * 0.8, 0.12))
		return
	_mat.set_shader_parameter("pulse", pulse)
	_mat.set_shader_parameter("damage", dmg)
	_mat.set_shader_parameter("flash", _hit_flash)
	var flick := 1.0 - dmg * 0.35 * (0.5 + 0.5 * sin(_t * 17.0 + sin(_t * 5.3) * 3.0))
	_light.light_energy = LIGHT_ENERGY * (0.85 + pulse * 0.25 + _hit_flash * 0.6) * flick
	_shell_mat.albedo_color.a = 0.07 + pulse * 0.04 + _hit_flash * 0.12


## Shell impact at world `pos` with a crater of `crater_r`: damage falls off linearly from
## max_damage at the core's surface to 0 at CORE_BLAST_K × crater_r from it.
func blast(pos: Vector3, crater_r: float, max_damage: float) -> void:
	var reach := Balance.CORE_BLAST_K * crater_r
	var d := maxf(pos.distance_to(global_position) - Balance.CORE_RADIUS, 0.0)
	if d >= reach:
		return
	_damage(max_damage * (1.0 - d / reach))


## Shell impact against every core (scripts/war/shell.gd).
static func blast_all(tree: SceneTree, pos: Vector3, crater_r: float, max_damage: float) -> void:
	for c in tree.get_nodes_in_group(GROUP):
		c.blast(pos, crater_r, max_damage)


## A drill brush (world `point`, `radius`) used by `team` for `dt` seconds: an enemy core it
## overlaps takes CORE_DRILL_DPS × dt. Your own team's drill never hurts your core.
static func drill_all(tree: SceneTree, point: Vector3, radius: float, p_team: String, dt: float) -> void:
	for c in tree.get_nodes_in_group(GROUP):
		if c.team == p_team or c.destroyed:
			continue
		if point.distance_to(c.global_position) < radius + Balance.CORE_RADIUS:
			c._damage(Balance.CORE_DRILL_DPS * dt)


func _damage(amount: float) -> void:
	if destroyed or amount <= 0.0:
		return
	if Net.is_client():
		# Multiplayer: core hp is the host's (net_world.gd); a client's drill sends a claim.
		Net.world.claim_core_damage(self, amount)
		return
	# Çekirdek Kalkanı (scripts/war/core_shield.gd): a standing shield of this side cuts every hit.
	amount *= float(load(CORE_SHIELD_PATH).call("mult_for", team))
	hp = maxf(hp - amount, 0.0)
	if hp <= 0.0 and Game.has_meta("training"):
		hp = 1.0                  # Eğitim Alanı: a core never dies (scripts/training/training.gd refills it)
	_hit_flash = clampf(_hit_flash + amount / 20.0, 0.0, 1.0)
	Game.core_damaged.emit(body, hp)
	if hp <= 0.0:
		destroyed = true
		Game.core_destroyed.emit(body)


## Multiplayer client: the host's core hp (flash on a drop, destruction once).
func net_set_hp(h: float, is_destroyed: bool) -> void:
	if destroyed:
		return
	if h < hp - 0.01:
		_hit_flash = clampf(_hit_flash + (hp - h) / 20.0, 0.0, 1.0)
		hp = h
		Game.core_damaged.emit(body, hp)
	else:
		hp = h
	if is_destroyed:
		hp = 0.0
		destroyed = true
		Game.core_destroyed.emit(body)
