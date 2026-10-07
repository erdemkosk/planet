extends "res://scripts/war/base_piece.gd"
## Çekirdek Kalkanı (core shield generator), İnşa Aracı (Üs; Balance.CORE_SHIELD_*). Only on your own
## planet, within CORE_SHIELD_RANGE m of your OWN core's surface (dig down to the core chamber), one
## per side (BaseKit.rule_reason). While it stands (assembled, not destroyed) its side's core takes
## × CORE_SHIELD_MULT (scripts/war/core.gd _damage asks CoreShield.mult_for(team)), and a hex-lattice
## energy shell glows around the core (flashes when the core is hit, collapses when the generator
## dies); a beam runs from the emitter to the shell. The enemy has to break the generator first.
## Model: a hexagonal steel-rimmed base, a painted column with three glowing coil rings and heat-sink
## fins, an emitter orb in a four-prong cage on top, a status console, cables into the floor.
## Group "war_core_shield". Multiplayer state: hp only (each machine draws its own shell).
##   CoreShield.active_for(team) -> bool       CoreShield.mult_for(team) -> float

const Snd := preload("res://scripts/audio/snd_lib.gd")

const SHELL_K := 1.75                   # shell radius × CORE_RADIUS
const ORB_Y := 1.72

const SHELL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec4 col : source_color = vec4(0.5, 0.3, 1.0, 1.0);
uniform float strength = 1.0;
uniform float flash = 0.0;
varying vec3 lp;

float hexd(vec2 p) {
	p.x *= 1.1547;
	p.y += mod(floor(p.x), 2.0) * 0.5;
	p = abs(fract(p) - 0.5);
	return abs(max(p.x * 1.5 + p.y, p.y * 2.0) - 1.0);
}

void vertex() {
	lp = VERTEX;
}

void fragment() {
	vec3 d = normalize(lp);
	float fres = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 2.4);
	vec2 uv = vec2(atan(d.z, d.x) * 3.2, acos(clamp(d.y, -1.0, 1.0)) * 6.0);
	float edge = 1.0 - smoothstep(0.0, 0.07, hexd(uv));
	float scan = 0.55 + 0.45 * sin(d.y * 9.0 - TIME * 1.6);
	float k = (0.18 * fres + 0.22 * edge * scan) * strength + flash * (0.35 * fres + 0.4 * edge);
	ALBEDO = min(col.rgb * k * 1.6, vec3(0.9));
	ALPHA = 1.0;
}
"""

static var _shell_shader: Shader

var _shell: MeshInstance3D
var _shell_mat: ShaderMaterial
var _beam: MeshInstance3D
var _beam_mat: StandardMaterial3D
var _coil_mats: Array = []
var _orb_mat: StandardMaterial3D
var _orb: Node3D
var _screen: Label3D
var _hum: AudioStreamPlayer3D
var _shell_k := 0.0
var _flash := 0.0
var _core: Node3D


static func footprint() -> Vector3:
	return Vector3(0.95, 1.0, 0.95)


## A standing (assembled, not destroyed) Çekirdek Kalkanı of `team` exists.
static func active_for(team: String) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return false
	for s in tree.get_nodes_in_group("war_core_shield"):
		if Game.team_of(s) == team and s.has_method("shield_active") and s.shield_active():
			return true
	return false


## Damage multiplier for `team`'s core (core.gd): CORE_SHIELD_MULT while a shield stands, else 1.
static func mult_for(team: String) -> float:
	return Balance.CORE_SHIELD_MULT if active_for(team) else 1.0


func piece_kind() -> String:
	return "core_shield"


func piece_name() -> String:
	return "Çekirdek Kalkanı"


func piece_group() -> String:
	return "war_core_shield"


func piece_hp() -> float:
	return Balance.CORE_SHIELD_HP


func footprint_r() -> float:
	return Balance.CORE_SHIELD_FOOTPRINT


func blast_mult() -> float:
	return Balance.CORE_SHIELD_BLAST_MULT


func shield_active() -> bool:
	return _build_t < 0.0 and not is_destroyed and not has_meta("build_preview")


func _foundation_shape() -> Array:
	return [Foundation.polygon(6, 0.92, 0.0), [], Color(0.3, 0.3, 0.31)]


func _build_piece() -> void:
	var home := team == "home"
	var glow_col := Color("a77bff") if home else Color("e8433a")
	_paint = _mat(Color(0.8, 0.81, 0.8) if home else Color(0.2, 0.19, 0.19), 0.3 if home else 0.6, 0.45)
	var stripe := _mat(Color(0.95, 0.42, 0.08) if home else Color(0.72, 0.12, 0.08), 0.0, 0.5)
	var steel := _mat(Color(0.34, 0.35, 0.37), 0.85, 0.38)
	var dark := _mat(Color(0.1, 0.105, 0.11), 0.7, 0.42)
	var copper := _mat(Color(0.72, 0.42, 0.24), 0.9, 0.35)
	# --- Base.
	var base := _part(0.0)
	_cyl(base, Vector3(0, 0.1, 0), 0.9, 0.95, 0.2, concrete(true), Vector3.ZERO, 6)
	_cyl(base, Vector3(0, 0.2, 0), 0.92, 0.92, 0.03, steel, Vector3.ZERO, 6)
	_cyl(base, Vector3(0, 0.22, 0), 0.7, 0.75, 0.04, hazard(), Vector3.ZERO, 6)
	for k in 3:
		var a := TAU * float(k) / 3.0 + 0.5
		var d := Vector3(cos(a), 0, sin(a))
		_seg(base, d * 0.45 + Vector3(0, 0.25, 0), d * 1.1 + Vector3(0, -0.05, 0), 0.04, dark, 8)    # cables
	_col_box(Vector3(0, 0.12, 0), Vector3(1.6, 0.24, 1.6))
	# --- Column, fins, coils.
	var col := _part(0.18)
	_cyl(col, Vector3(0, 0.85, 0), 0.26, 0.32, 1.3, _paint, Vector3.ZERO, 16)
	_cyl(col, Vector3(0, 0.36, 0), 0.34, 0.34, 0.06, stripe, Vector3.ZERO, 16)
	for k in 6:
		var a := TAU * float(k) / 6.0
		_box(col, Vector3(cos(a) * 0.36, 0.95, sin(a) * 0.36), Vector3(0.18, 0.95, 0.03), steel, Vector3(0, -a, 0))
	for y in [0.62, 0.95, 1.28]:
		var cm := _mat(glow_col, 0.0, 0.3, 2.5)
		_coil_mats.append(cm)
		var tm := TorusMesh.new()
		tm.inner_radius = 0.3
		tm.outer_radius = 0.38
		tm.rings = 28
		tm.ring_segments = 8
		var tor := MeshInstance3D.new()
		tor.mesh = tm
		tor.material_override = cm
		tor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tor.position = Vector3(0, float(y), 0)
		col.add_child(tor)
		var cw := TorusMesh.new()
		cw.inner_radius = 0.385
		cw.outer_radius = 0.41
		cw.rings = 28
		cw.ring_segments = 6
		var wind := MeshInstance3D.new()
		wind.mesh = cw
		wind.material_override = copper
		wind.position = Vector3(0, float(y) + 0.06, 0)
		col.add_child(wind)
	_col_box(Vector3(0, 0.95, 0), Vector3(0.8, 1.4, 0.8))
	# --- Emitter: orb in a four-prong cage.
	var em := _part(0.36)
	_cyl(em, Vector3(0, 1.53, 0), 0.2, 0.28, 0.1, dark, Vector3.ZERO, 16)
	_orb = Node3D.new()
	_orb.position = Vector3(0, ORB_Y, 0)
	em.add_child(_orb)
	_orb_mat = _mat(glow_col, 0.0, 0.2, 4.0)
	var om := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.15
	sm.height = 0.3
	sm.radial_segments = 16
	sm.rings = 8
	om.mesh = sm
	om.material_override = _orb_mat
	om.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_orb.add_child(om)
	for k in 4:
		var a := TAU * float(k) / 4.0 + PI * 0.25
		var d := Vector3(cos(a), 0, sin(a))
		_seg(em, d * 0.2 + Vector3(0, 1.55, 0), d * 0.26 + Vector3(0, 1.75, 0), 0.025, steel, 6)
		_seg(em, d * 0.26 + Vector3(0, 1.75, 0), d * 0.12 + Vector3(0, 1.98, 0), 0.022, steel, 6)
	# --- Console.
	var con := _part(0.5)
	_box(con, Vector3(0, 0.5, 0.78), Vector3(0.08, 0.6, 0.08), dark)
	_box(con, Vector3(0, 0.85, 0.8), Vector3(0.5, 0.3, 0.05), dark, Vector3(-0.5, 0, 0))
	_screen = _label(con, Vector3(0, 0.86, 0.835), "ÇEKİRDEK KALKANI", 26, glow_col.lightened(0.4), Vector3(-0.5, 0, 0))
	# --- Beam and shell (world space; not for previews).
	if has_meta("build_preview"):
		return
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_beam_mat.albedo_color = Color(glow_col.r, glow_col.g, glow_col.b, 0.0)
	var bm := CylinderMesh.new()
	bm.top_radius = 0.035
	bm.bottom_radius = 0.035
	bm.height = 1.0
	bm.radial_segments = 6
	bm.rings = 1
	_beam = MeshInstance3D.new()
	_beam.mesh = bm
	_beam.material_override = _beam_mat
	_beam.top_level = true
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.visible = false
	add_child(_beam)
	if _shell_shader == null:
		_shell_shader = Shader.new()
		_shell_shader.code = SHELL_SHADER
	_shell_mat = ShaderMaterial.new()
	_shell_mat.shader = _shell_shader
	_shell_mat.set_shader_parameter("col", glow_col)
	_shell_mat.set_shader_parameter("strength", 0.0)
	var ss := SphereMesh.new()
	ss.radius = Balance.CORE_RADIUS * SHELL_K
	ss.height = Balance.CORE_RADIUS * SHELL_K * 2.0
	ss.radial_segments = 48
	ss.rings = 24
	_shell = MeshInstance3D.new()
	_shell.mesh = ss
	_shell.material_override = _shell_mat
	_shell.top_level = true
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell.visible = false
	add_child(_shell)
	_hum = AudioStreamPlayer3D.new()
	_hum.stream = Snd.loop("foley/motor_loop")
	_hum.unit_size = 4.0
	_hum.max_distance = 25.0
	_hum.volume_db = -80.0
	_hum.pitch_scale = 0.45
	_hum.position = Vector3(0, 1.0, 0)
	add_child(_hum)


func _piece_ready() -> void:
	if has_meta("build_preview"):
		return
	_core = BaseKit.own_core(team, get_tree())
	if not Game.core_damaged.is_connected(_on_core_damaged):
		Game.core_damaged.connect(_on_core_damaged)


func _on_core_damaged(b: Node3D, _hp: float) -> void:
	if _core != null and is_instance_valid(_core) and _core.get("body") == b and shield_active():
		_flash = 1.0


func _on_assembled() -> void:
	if Game.hud and Game.team_of(self) == Game.team_of(Game.player):
		Game.hud.show_message("Çekirdek kalkanı devrede — çekirdek hasarı %d%%" % int(roundf(Balance.CORE_SHIELD_MULT * 100.0)), 3.0)


func _on_destroyed() -> void:
	if Game.hud and Game.team_of(self) == Game.team_of(Game.player):
		Game.hud.show_message("Çekirdek kalkanı çöktü!", 3.0)


func _animate(delta: float) -> void:
	if has_meta("build_preview"):
		return
	var on := shield_active()
	_shell_k = move_toward(_shell_k, 1.0 if on else 0.0, delta * (0.6 if on else 2.0))
	_flash = maxf(_flash - delta * 1.8, 0.0)
	var pulse := 0.85 + 0.15 * sin(_t * 2.4)
	for m in _coil_mats:
		(m as StandardMaterial3D).emission_energy_multiplier = (1.6 + 1.2 * pulse + _flash * 2.0) if on else 0.3
	_orb_mat.emission_energy_multiplier = (2.5 + 1.5 * sin(_t * 7.0) * 0.5 + _flash * 3.0) if on else 0.4
	_orb.rotation.y += delta * 1.5
	if _core == null or not is_instance_valid(_core):
		_core = BaseKit.own_core(team, get_tree())
	var show := _shell_k > 0.01 and _core != null and is_instance_valid(_core)
	_shell.visible = show
	_beam.visible = show
	if show:
		var cc: Vector3 = _core.global_position
		_shell.global_transform = Transform3D(Basis().scaled(Vector3.ONE * lerpf(0.85, 1.0, _shell_k)), cc)
		_shell_mat.set_shader_parameter("strength", _shell_k * pulse)
		_shell_mat.set_shader_parameter("flash", _flash)
		var a := global_transform * Vector3(0, ORB_Y, 0)
		var b := cc + (a - cc).normalized() * Balance.CORE_RADIUS * SHELL_K
		var ln := a.distance_to(b)
		if ln > 0.1:
			_beam.global_transform = Transform3D(_seg_basis(a, b) * Basis.from_scale(Vector3(1.0 + 0.4 * sin(_t * 31.0), ln, 1.0 + 0.4 * sin(_t * 31.0))),
					(a + b) * 0.5)
		_beam_mat.albedo_color.a = (0.35 + 0.25 * sin(_t * 23.0) + _flash * 0.4) * _shell_k
	if on and not _hum.playing:
		_hum.play()
	if _hum.playing:
		_hum.volume_db = lerpf(_hum.volume_db, -16.0 if on else -80.0, 1.0 - exp(-delta * 2.0))
		if not on and _hum.volume_db < -60.0:
			_hum.stop()
	var txt := "ÇEKİRDEK KALKANI\nKURULUYOR" if _build_t >= 0.0 else ("ÇEKİRDEK KALKANI\nAKTİF · HASAR %d%%" % int(roundf(Balance.CORE_SHIELD_MULT * 100.0)))
	if _screen.text != txt:
		_screen.text = txt
