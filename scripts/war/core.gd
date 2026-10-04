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

const CORE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back;
uniform vec3 hot : source_color = vec3(1.0, 0.95, 0.85);
uniform vec3 col : source_color = vec3(0.3, 0.85, 1.0);
uniform float energy = 3.0;
uniform float pulse = 0.0;
uniform float damage = 0.0;      // 0 healthy .. 1 nearly destroyed (flickers, cracks)
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

void vertex() {
	lp = VERTEX;
}

void fragment() {
	float fres = pow(1.0 - abs(dot(NORMAL, VIEW)), 2.0);
	float n = vnoise(lp * 0.55 + vec3(TIME * 0.35, -TIME * 0.2, TIME * 0.27));
	float n2 = vnoise(lp * 1.7 - vec3(TIME * 0.6));
	float swirl = smoothstep(0.35, 0.8, n * 0.7 + n2 * 0.3);
	vec3 c = mix(col, hot, swirl * 0.7 + (1.0 - fres) * 0.25);
	float crack = damage * smoothstep(0.62, 0.7, n2) * (0.5 + 0.5 * sin(TIME * 23.0));
	float e = energy * (0.85 + 0.25 * pulse) * (1.0 - damage * 0.35) + crack * 3.0;
	ALBEDO = c * e;
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
	_col = Color(0.35, 0.88, 1.0) if team == "home" else Color(1.0, 0.22, 0.1)
	var hot := Color(1.0, 0.93, 0.78) if team == "home" else Color(1.0, 0.75, 0.45)
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
	_shell_mat.albedo_color = Color(_col.r, _col.g, _col.b, 0.18)
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
	_light.light_energy = 3.0
	_light.shadow_enabled = false
	_light.light_specular = 0.3
	add_child(_light)


func _process(delta: float) -> void:
	_t += delta
	_hit_flash = maxf(_hit_flash - delta * 2.0, 0.0)
	var dmg := 1.0 - hp / hp_max
	var pulse := sin(_t * (1.6 + dmg * 4.0)) * 0.5 + 0.5
	if destroyed:
		_light.light_energy = move_toward(_light.light_energy, 0.0, delta * 2.0)
		_mat.set_shader_parameter("energy", maxf(float(_mat.get_shader_parameter("energy")) - delta * 2.0, 0.15))
		return
	_mat.set_shader_parameter("pulse", pulse)
	_mat.set_shader_parameter("damage", dmg)
	_mat.set_shader_parameter("energy", 3.0 + _hit_flash * 4.0)
	var flick := 1.0 - dmg * 0.4 * (0.5 + 0.5 * sin(_t * 17.0 + sin(_t * 5.3) * 3.0))
	_light.light_energy = (2.6 + pulse * 0.8 + _hit_flash * 5.0) * flick
	_shell_mat.albedo_color.a = 0.14 + pulse * 0.08 + _hit_flash * 0.3


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
	hp = maxf(hp - amount, 0.0)
	_hit_flash = clampf(_hit_flash + amount / 20.0, 0.0, 1.0)
	Game.core_damaged.emit(body, hp)
	if hp <= 0.0:
		destroyed = true
		Game.core_destroyed.emit(body)
