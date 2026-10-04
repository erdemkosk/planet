extends Node3D
## Astronaut character body: the player's own body (shadow-only in first person, visible as the
## ragdoll) and the body of the phase-2 AI rival bot. The suit is one skinned mesh
## (scripts/player/astronaut_parts.gd: soft fabric loft with convolute joints, shell plates, gloves,
## boots, helmet with a reflective visor, life-support pack) on a Skeleton3D that mirrors a tree of
## Node3D bones. Animation, the ragdoll (scripts/player/ragdoll.gd) and the get-up all move the
## Node3D bones; the skeleton copies them every frame. Procedural animation: speed-matched walk/run
## with planted feet (two-bone leg IK + ground probes), idle breathing, jetpack, landing squash,
## holding items with arm IK (two-handed at the shoulder, one-handed forward). The zero-g and swim
## poses are dormant (their inputs stay false on the planets). Held props: set_held(icon) shows the
## prop registered under props[icon] (the guns add theirs, weapon_base.gd _build_tp_prop).
## Drive it each frame with animate(delta, {...}) (see the keys there). Origin at the feet, facing -Z.

const VM := preload("res://scripts/player/vm_parts.gd")
const AP := preload("res://scripts/player/astronaut_parts.gd")

## Skeleton proportions: leg bones and the IK use these (see astronaut_parts.gd).
const L_THIGH := 0.4
const L_SHIN := 0.39
const ANKLE_H := 0.1          # ankle joint above the sole
const HIP_DROP := 0.05        # hip joints below the pelvis origin

## Held items whose off hand holds the front: how far ahead of the grip (prop space, -Z).
const SUPPORT_Z := {"terrain": -0.1, "scanner": -0.07}

## Simple suit material for props / armor parts (no vertex data needed).
const SUIT_SHADER := """
shader_type spatial;
render_mode cull_back;

uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness = 0.7;
uniform float metallic = 0.0;
uniform float weave = 0.0;
uniform float rim = 0.25;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;

void fragment() {
	vec3 col = albedo.rgb;
	if (weave > 0.0) {
		float w = sin(UV.x * 220.0) * sin(UV.y * 120.0);
		col *= 1.0 - weave * (0.4 + 0.4 * w);
	}
	ALBEDO = col;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	RIM = rim;
	RIM_TINT = 0.4;
	EMISSION = emission * emission_energy;
}
"""

## The skinned suit. COLOR: r = cavity, g = dust, b = brightness, a = quilting (astronaut_parts.gd).
const BODY_SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness = 0.7;
uniform float metallic = 0.0;
uniform float fabric = 0.0;
uniform float coat = 0.0;
uniform float rim = 0.2;
uniform float rim_tint = 0.5;
uniform float dust = 0.5;
uniform vec3 dust_color : source_color = vec3(0.5, 0.44, 0.36);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Quilted padding: diamond cells, puffy between the stitch lines.
float quilt_h(vec2 uv) {
	vec2 q = vec2(uv.x + uv.y, uv.x - uv.y) * 14.0;
	vec2 f = abs(fract(q) - 0.5) * 2.0;
	return (1.0 - f.x * f.x) * (1.0 - f.y * f.y);
}

void fragment() {
	float ao = COLOR.r;
	float d = COLOR.g * dust;
	vec3 col = albedo.rgb * COLOR.b;
	float rough = roughness;
	vec2 uv = UV;
	float px = length(fwidth(uv));
	if (fabric > 0.0) {
		col *= 0.95 + 0.06 * vnoise(uv * 160.0) + 0.04 * vnoise(uv * 21.0);
		// Side seams of the soft suit.
		float sx = abs(fract(UV2.x * 2.0 + 0.5) - 0.5);
		col *= 1.0 - 0.22 * (1.0 - smoothstep(0.0015, 0.005, sx)) * (1.0 - smoothstep(0.004, 0.02, px));
		float quilt = COLOR.a * fabric * (1.0 - smoothstep(0.006, 0.02, px));
		if (quilt > 0.001) {
			float e = 0.0025;
			float h0 = quilt_h(uv);
			float hu = quilt_h(uv + vec2(e, 0.0));
			float hv = quilt_h(uv + vec2(0.0, e));
			vec2 g = vec2(hu - h0, hv - h0) / e * 0.0028 * quilt;
			NORMAL_MAP = normalize(vec3(-g.x, -g.y, 1.0)) * 0.5 + 0.5;
			ao *= mix(1.0, 0.88 + 0.12 * h0, quilt);
		}
	} else {
		rough *= 0.85 + 0.3 * vnoise(uv * 37.0);
	}
	float dn = clamp(d, 0.0, 1.0) * (0.45 + 0.55 * vnoise(uv * 15.0));
	col = mix(col, dust_color * (0.7 + 0.3 * COLOR.b), dn);
	rough = mix(rough, 0.95, dn);
	ALBEDO = col * mix(0.62, 1.0, ao);
	AO = ao;
	AO_LIGHT_AFFECT = 0.25;
	ROUGHNESS = rough;
	METALLIC = metallic * (1.0 - dn);
	RIM = rim;
	RIM_TINT = rim_tint;
	CLEARCOAT = coat * (1.0 - dn);
	CLEARCOAT_ROUGHNESS = 0.18;
}
"""

const VISOR_SHADER := """
shader_type spatial;
render_mode cull_back;

uniform vec3 tint : source_color = vec3(1.0, 0.72, 0.3);

void fragment() {
	vec3 r = reflect(-VIEW, NORMAL);
	vec3 rw = normalize((INV_VIEW_MATRIX * vec4(r, 0.0)).xyz);
	vec3 up = normalize(MODEL_MATRIX[1].xyz);
	float h = dot(rw, up);
	vec3 sky = mix(vec3(0.66, 0.78, 0.98), vec3(0.1, 0.2, 0.5), clamp(h * 1.3, 0.0, 1.0));
	vec3 ground = vec3(0.2, 0.16, 0.12) * (0.6 + 0.4 * clamp(-h * 3.0, 0.0, 1.0));
	vec3 env = mix(ground, sky, smoothstep(-0.05, 0.04, h));
	env += vec3(1.0) * pow(max(1.0 - abs(h) * 8.0, 0.0), 2.0) * 0.5;
	float fres = 0.35 + 0.65 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = vec3(0.012);
	ROUGHNESS = 0.05;
	SPECULAR = 1.0;
	METALLIC = 0.6;
	EMISSION = env * tint * fres * 0.85;
}
"""

const GLOW_SHADER := """
shader_type spatial;
render_mode cull_back;

uniform float energy = 2.6;

void fragment() {
	ALBEDO = COLOR.rgb * 0.15;
	ROUGHNESS = 0.35;
	EMISSION = COLOR.rgb * energy;
}
"""

const FLAME_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform float power = 1.0;
varying float v_t;

void vertex() {
	v_t = clamp(0.5 - VERTEX.y, 0.0, 1.0);   // 0 at the nozzle (top), 1 at the tip
}

void fragment() {
	float t = v_t;
	float n = 0.75 + 0.25 * sin(TIME * 60.0 + UV.x * 25.0) * sin(TIME * 37.0 - t * 12.0);
	vec3 hot = vec3(2.2, 2.0, 1.7);
	vec3 warm = vec3(2.0, 0.6, 0.1);
	ALBEDO = mix(hot, warm, smoothstep(0.0, 0.55, t));
	float edge = pow(abs(dot(NORMAL, VIEW)), 0.7);
	ALPHA = clamp(pow(1.0 - t, 1.2) * edge * n * power * 2.2, 0.0, 1.0);
}
"""

static var _suit_shader: Shader
static var _mats := {}
static var _body_mesh: ArrayMesh
static var _body_skin: Skin

var preview := false             # true for the inventory character preview (no probes / tilt)

# Bones (pivots).
var hips: Node3D
var spine: Node3D
var chest: Node3D
var head: Node3D
var thigh := [null, null]       # [left, right]
var shin := [null, null]
var foot := [null, null]
var shoulder := [null, null]
var elbow := [null, null]
var hand := [null, null]

var props := {}                  # item icon id -> Node3D held in the right hand
var prop_tips := {}              # item icon id -> Node3D at the muzzle (beam start)
var _prop_glow: StandardMaterial3D
var _flames: Array = []          # [MeshInstance3D, ...]
var _jet_particles: Array = []   # [GPUParticles3D] flame + spark jets
var _flame_mat: ShaderMaterial
var _lights_mat: StandardMaterial3D
var _status_mat: StandardMaterial3D
var _lamp_mat: StandardMaterial3D
var _meshes: Array = []          # every MeshInstance3D except flames (for shadow mode)
var _first_person := false
var _skel: Skeleton3D
var _body: MeshInstance3D
var _bone_nodes: Array = []      # Node3D per skeleton bone 0..15
var _held := ""
var _grip := [0.0, 0.0]          # closed-hand amount per hand (0 = relaxed open hand)
var _grip_shown := [-1, -1]

var _t := 0.0
var _phase := 0.0                # gait cycle 0..1: the left foot plants at 0, the right at 0.5
var _move := 0.0
var _run := 0.0
var _air := 0.0
var _jet := 0.0
var _float := 0.0
var _aim := 0.0
var _two_hand := 0.0
var _swim := 0.0
var _swim_move := 0.0
var _swim_ph := 0.0
var _rot := {}                   # bone -> current Vector3 rotation (smoothed)
var _rest := {}                  # bone -> rest local transform
var _bones: Array = []
var _hips_y := 0.94
var _speed := 0.0
var _vloc := Vector3.ZERO
var _acc := Vector3.ZERO
var _land := 0.0
var _was_grounded := true
var _ground := 1.0
var _foot_off := [0.0, 0.0]
var _mdir := Vector3.FORWARD
var _flyk := 0.0                 # Superman flight pose blend
var _fly_dir := Vector3.UP       # body-space flight direction the head points along
var _bank := 0.0
var _look := Vector2.ZERO        # idle glance (yaw, pitch)
var _look_to := Vector2.ZERO
var _look_t := 2.0


static func mat(c: Color, rough := 0.7, metal := 0.0, weave := 0.0, rim := 0.25) -> ShaderMaterial:
	var key := "%s|%.2f|%.2f|%.2f|%.2f" % [c.to_html(), rough, metal, weave, rim]
	if _mats.has(key):
		return _mats[key]
	if _suit_shader == null:
		_suit_shader = Shader.new()
		_suit_shader.code = SUIT_SHADER
	var m := ShaderMaterial.new()
	m.shader = _suit_shader
	m.set_shader_parameter("albedo", c)
	m.set_shader_parameter("roughness", rough)
	m.set_shader_parameter("metallic", metal)
	m.set_shader_parameter("weave", weave)
	m.set_shader_parameter("rim", rim)
	_mats[key] = m
	return m


static func glow_mat(c: Color, energy := 3.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


## Shared skinned suit mesh (built once) with its materials.
static func body_mesh() -> ArrayMesh:
	if _body_mesh != null:
		return _body_mesh
	_body_mesh = AP.build_mesh()
	var sh := Shader.new()
	sh.code = BODY_SHADER
	# [albedo, roughness, metallic, fabric, coat, rim, dust]
	var spec := {
		AP.M_FABRIC: [Color(0.76, 0.76, 0.74), 0.88, 0.0, 1.0, 0.0, 0.3, 0.8],
		AP.M_SHELL: [Color(0.92, 0.92, 0.91), 0.32, 0.0, 0.0, 0.6, 0.1, 0.5],
		AP.M_GREY: [Color(0.5, 0.52, 0.55), 0.55, 0.15, 0.0, 0.1, 0.15, 0.6],
		AP.M_DARK: [Color(0.13, 0.14, 0.16), 0.72, 0.0, 0.0, 0.0, 0.25, 0.6],
		AP.M_ORANGE: [Color(0.93, 0.4, 0.07), 0.45, 0.0, 0.0, 0.35, 0.15, 0.6],
		AP.M_METAL: [Color(0.62, 0.64, 0.67), 0.3, 0.75, 0.0, 0.0, 0.1, 0.4],
	}
	for id in spec:
		var p: Array = spec[id]
		var m := ShaderMaterial.new()
		m.shader = sh
		m.set_shader_parameter("albedo", p[0])
		m.set_shader_parameter("roughness", p[1])
		m.set_shader_parameter("metallic", p[2])
		m.set_shader_parameter("fabric", p[3])
		m.set_shader_parameter("coat", p[4])
		m.set_shader_parameter("rim", p[5])
		m.set_shader_parameter("dust", p[6])
		_body_mesh.surface_set_material(id, m)
	var vm := ShaderMaterial.new()
	var vsh := Shader.new()
	vsh.code = VISOR_SHADER
	vm.shader = vsh
	_body_mesh.surface_set_material(AP.M_VISOR, vm)
	var gm := ShaderMaterial.new()
	var gsh := Shader.new()
	gsh.code = GLOW_SHADER
	gm.shader = gsh
	_body_mesh.surface_set_material(AP.M_GLOW, gm)
	_body_skin = AP.skin()
	return _body_mesh


func _ready() -> void:
	process_priority = 100        # sync the skeleton after animation / ragdoll moved the bones
	_build()


# ------------------------------------------------------------------------------------------
# Construction
# ------------------------------------------------------------------------------------------

func _build() -> void:
	_lights_mat = glow_mat(Color(0.75, 0.95, 1.0), 4.0)
	_status_mat = glow_mat(Color(0.3, 1.0, 0.5), 3.0)
	_lamp_mat = glow_mat(Color(1.0, 0.93, 0.8), 0.3)
	_hips_y = AP.HIPS_Y

	# Node3D bones (the public rig) + the skeleton that mirrors them.
	_bone_nodes.resize(AP.NODE_BONES)
	for i in AP.NODE_BONES:
		var par: Node3D = self if AP.BONE_PARENT[i] < 0 else _bone_nodes[AP.BONE_PARENT[i]]
		_bone_nodes[i] = VM.node(par, AP.bone_local(i))
	hips = _bone_nodes[AP.HIPS]
	spine = _bone_nodes[AP.SPINE]
	chest = _bone_nodes[AP.CHEST]
	head = _bone_nodes[AP.HEAD]
	thigh = [_bone_nodes[AP.THIGH_L], _bone_nodes[AP.THIGH_R]]
	shin = [_bone_nodes[AP.SHIN_L], _bone_nodes[AP.SHIN_R]]
	foot = [_bone_nodes[AP.FOOT_L], _bone_nodes[AP.FOOT_R]]
	shoulder = [_bone_nodes[AP.SHOULDER_L], _bone_nodes[AP.SHOULDER_R]]
	elbow = [_bone_nodes[AP.ELBOW_L], _bone_nodes[AP.ELBOW_R]]
	hand = [_bone_nodes[AP.HAND_L], _bone_nodes[AP.HAND_R]]

	_skel = Skeleton3D.new()
	add_child(_skel)
	for i in AP.BONE_COUNT:
		_skel.add_bone(AP.BONE_NAMES[i])
	for i in AP.BONE_COUNT:
		if AP.BONE_PARENT[i] >= 0:
			_skel.set_bone_parent(i, AP.BONE_PARENT[i])
		var rest := Transform3D(Basis(), AP.bone_local(i))
		_skel.set_bone_rest(i, rest)
		_skel.set_bone_pose(i, rest)
	_body = MeshInstance3D.new()
	_body.mesh = body_mesh()
	_body.skin = _body_skin
	_body.custom_aabb = AABB(Vector3(-2.4, -2.4, -2.4), Vector3(4.8, 4.8, 4.8))
	_body.skeleton = NodePath("..")          # Godot 4.7 defaults to an empty path (no skinning)
	_skel.add_child(_body)

	_build_lights()
	_build_decals()
	_build_jets()
	_build_props()

	var skip: Array = _bone_nodes.duplicate() + _flames + props.values()
	for p in props.values():
		VM.bake(p, skip + prop_tips.values())
	_collect_meshes(self)
	set_first_person(false)
	_bones = [hips, spine, chest, head] + thigh + shin + foot + shoulder + elbow + hand
	for b in _bones:
		_rot[b] = Vector3.ZERO
		_rest[b] = b.transform
	_set_grip(0, 0.0)
	_set_grip(1, 0.0)


## Animated emissive bits (separate small meshes): pack light strips, status LEDs, headlamp lens.
func _build_lights() -> void:
	for sx in [-1.0, 1.0]:
		VM.box(chest, Vector3(sx * 0.1, 0.2, 0.287), Vector3(0.007, 0.16, 0.006), _lights_mat)
	for k in 4:
		VM.box(chest, Vector3(-0.045 + k * 0.03, 0.27, 0.2905), Vector3(0.016, 0.008, 0.004),
				_status_mat if k < 3 else glow_mat(Color(1, 0.6, 0.2), 3.0))
	var dir := AP.LAMP_DIR.normalized()
	var lens := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0175
	cm.bottom_radius = 0.0175
	cm.height = 0.004
	cm.radial_segments = 16
	cm.rings = 1
	lens.mesh = cm
	lens.material_override = _lamp_mat
	lens.transform = Transform3D(AP.basis_y(dir), AP.LAMP_POS + dir * 0.0005)
	head.add_child(lens)
	for c in chest.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Name tag on the chest and the Turkish flag on the left upper arm.
func _build_decals() -> void:
	var tag := Label3D.new()
	tag.text = "KAŞİF"
	tag.font_size = 40
	tag.pixel_size = 0.0007
	tag.shaded = true
	tag.double_sided = false
	tag.modulate = Color(0.95, 0.95, 1.0)
	tag.outline_size = 0
	tag.transform = Transform3D(Basis(Vector3.UP, PI - 0.3), Vector3(0.1, 0.306, -0.1435))
	chest.add_child(tag)
	var flag := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.05, 0.034)
	flag.mesh = qm
	var fm := StandardMaterial3D.new()
	fm.albedo_texture = _flag_texture()
	fm.roughness = 0.8
	flag.material_override = fm
	flag.set_meta("no_bake", true)
	flag.transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-0.068, -0.168, 0.0))
	shoulder[0].add_child(flag)


func _build_jets() -> void:
	_flame_mat = ShaderMaterial.new()
	var fsh := Shader.new()
	fsh.code = FLAME_SHADER
	_flame_mat.shader = fsh
	for np in AP.NOZZLES:
		var fl := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.05
		cm.bottom_radius = 0.0
		cm.height = 1.0
		cm.radial_segments = 10
		cm.rings = 1
		fl.mesh = cm
		fl.material_override = _flame_mat
		fl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fl.position = (np as Vector3) - Vector3(0, 0.2, 0)
		fl.visible = false
		chest.add_child(fl)
		_flames.append(fl)
		_jet_particles.append(_make_jet_particles(chest, np))


func _mesh(parent: Node3D, m: Mesh, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = material
	parent.add_child(mi)
	return mi


# --- Pose access (used by the ragdoll) -------------------------------------------------------

func rest_local(b: Node3D) -> Transform3D:
	return _rest.get(b, Transform3D.IDENTITY)


func save_pose() -> Dictionary:
	var d := {"__root": transform}
	for b in _bones:
		d[b] = b.transform
	return d


func load_pose(d: Dictionary) -> void:
	transform = d["__root"]
	for b in _bones:
		b.transform = d[b]


## Back to the rest pose (after a ragdoll); the animation blends on from there.
func reset_pose() -> void:
	transform = Transform3D.IDENTITY
	for b in _bones:
		b.transform = _rest[b]
		_rot[b] = Vector3.ZERO


## Copies the Node3D bones into the skeleton (after animation / ragdoll / get-up moved them).
func _process(_delta: float) -> void:
	sync_skeleton()


func sync_skeleton() -> void:
	if _skel == null or not is_visible_in_tree():
		return
	for i in AP.NODE_BONES:
		var t: Transform3D = (_bone_nodes[i] as Node3D).transform
		_skel.set_bone_pose_position(i, t.origin)
		_skel.set_bone_pose_rotation(i, t.basis.get_rotation_quaternion())


## Hand i: 0 = relaxed open hand, 1 = closed around a handle (swaps the glove variants).
func _set_grip(i: int, g: float) -> void:
	_grip[i] = g
	var shown := 1 if g > 0.5 else 0
	if shown == _grip_shown[i] or _skel == null:
		return
	_grip_shown[i] = shown
	var open_b := AP.HAND_L_OPEN if i == 0 else AP.HAND_R_OPEN
	var grip_b := AP.HAND_L_GRIP if i == 0 else AP.HAND_R_GRIP
	_skel.set_bone_pose_scale(open_b, Vector3.ONE * (0.001 if shown == 1 else 1.0))
	_skel.set_bone_pose_scale(grip_b, Vector3.ONE * (1.0 if shown == 1 else 0.001))


## Simplified held items for third person (grip at the hand, pointing along the hand's -Y).
func _build_props() -> void:
	var white := mat(Color(0.9, 0.91, 0.92), 0.32, 0.0, 0.0, 0.2)
	var orange := mat(Color(0.93, 0.4, 0.07), 0.5, 0.0, 0.0, 0.15)
	var dark := mat(Color(0.16, 0.17, 0.19), 0.45, 0.5, 0.0, 0.15)
	var steel := mat(Color(0.62, 0.64, 0.67), 0.3, 0.75, 0.0, 0.1)
	_prop_glow = glow_mat(Color(1.0, 0.55, 0.15), 3.5)
	var base := Basis(Vector3.RIGHT, -PI * 0.5)
	# Terrain tool.
	var p := VM.node(hand[1], Vector3(0, -0.09, 0), base)
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.capsule(p, Vector3(0, 0.05, 0.07), Vector3(0, 0.05, -0.12), 0.041, white, 16)
	VM.seg(p, Vector3(0, 0.05, 0.02), Vector3(0, 0.05, -0.035), 0.0435, 0.0435, orange, 16)
	VM.seg(p, Vector3(0, 0.05, -0.12), Vector3(0, 0.05, -0.2), 0.03, 0.027, dark, 14)
	for k in 3:
		VM.ring(p, Vector3(0, 0.05, -0.14 - k * 0.022), Vector3.FORWARD, 0.038, 0.008, _prop_glow)
	VM.seg(p, Vector3(0, 0.05, -0.2), Vector3(0, 0.05, -0.245), 0.03, 0.017, steel, 14)
	VM.box(p, Vector3(-0.044, 0.058, -0.04), Vector3(0.004, 0.006, 0.11), _prop_glow)
	props["terrain"] = p
	prop_tips["terrain"] = VM.node(p, Vector3(0, 0.05, -0.26))
	# Scanner.
	p = VM.node(hand[1], Vector3(0, -0.09, 0), base)
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	var slab := VM.node(p, Vector3(-0.05, 0.06, -0.03), Basis(Vector3.RIGHT, 0.8))
	VM.soft_box(slab, Vector3.ZERO, Vector3(0.17, 0.026, 0.11), 0.011, mat(Color(0.2, 0.21, 0.23), 0.45, 0.4))
	VM.box(slab, Vector3(0, 0.014, 0), Vector3(0.14, 0.003, 0.088), glow_mat(Color(0.3, 0.85, 1.0), 2.0))
	for sx in [-1.0, 1.0]:
		VM.capsule(slab, Vector3(sx * 0.086, 0, 0.048), Vector3(sx * 0.086, 0, -0.048), 0.013, orange, 8)
	VM.seg(slab, Vector3(0.07, 0.01, -0.05), Vector3(0.075, 0.1, -0.056), 0.003, 0.002, steel, 6)
	props["scanner"] = p
	prop_tips["scanner"] = VM.node(p, Vector3(0, 0.06, -0.1))
	# Beacon: held upright in the fist like a torch (rod along the grip axis, light on top).
	p = VM.node(hand[1], AP.GRIP, Basis(Vector3.RIGHT, -PI * 0.5))
	VM.seg(p, Vector3(0, -0.07, 0), Vector3(0, 0.17, 0), 0.016, 0.017, white)
	VM.seg(p, Vector3(0, 0.06, 0), Vector3(0, 0.085, 0), 0.02, 0.02, orange)
	VM.seg(p, Vector3(0, -0.075, 0), Vector3(0, -0.06, 0), 0.019, 0.019, dark)
	VM.sphere(p, Vector3(0, 0.2, 0), 0.026, glow_mat(Color(0.45, 0.88, 1.0), 4.0))
	props["beacon"] = p
	prop_tips["beacon"] = VM.node(p, Vector3(0, 0.2, 0))
	for k in props:
		props[k].visible = false


func _collect_meshes(n: Node) -> void:
	for c in n.get_children():
		if c is MeshInstance3D and not _flames.has(c):
			_meshes.append(c)
		_collect_meshes(c)


static func _flag_texture() -> ImageTexture:
	var w := 96
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var red := Color(0.89, 0.04, 0.09)
	var star := PackedVector2Array()
	var sc := Vector2(57, 32)
	for k in 10:
		var a := -PI * 0.5 + k * PI / 5.0 + PI     # pointing left-ish like the flag
		var r := 9.5 if k % 2 == 0 else 3.9
		star.append(sc + Vector2(cos(a), sin(a)) * r)
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5)
			var c := red
			if p.distance_to(Vector2(36, 32)) < 16.0 and p.distance_to(Vector2(40.5, 32)) >= 12.8:
				c = Color.WHITE
			elif Geometry2D.is_point_in_polygon(p, star):
				c = Color.WHITE
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# ------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------

## First person: the body only casts shadows (and the flames are hidden).
func set_first_person(fp: bool) -> void:
	_first_person = fp
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if fp else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for m in _meshes:
		if is_instance_valid(m):
			if not fp and m != _body and m.get_parent() == chest and (m as MeshInstance3D).material_override is StandardMaterial3D:
				m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			else:
				m.cast_shadow = mode
	for l in _labels(self):
		l.visible = not fp


func _labels(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		if c is Label3D or (c is MeshInstance3D and c.mesh is QuadMesh):
			out.append(c)
		out.append_array(_labels(c))
	return out


## Which item the right hand shows ("" for none).
func set_held(icon_id: String) -> void:
	_held = icon_id
	for k in props:
		props[k].visible = k == icon_id
	_two_hand = 0.0 if icon_id == "beacon" or icon_id == "" else _two_hand
	_set_grip(1, 1.0 if icon_id != "" else 0.0)


func held_tip(icon_id: String) -> Node3D:
	return prop_tips.get(icon_id, null)


func set_tool_color(c: Color) -> void:
	_prop_glow.albedo_color = c
	_prop_glow.emission = c


# ------------------------------------------------------------------------------------------
# Animation
# ------------------------------------------------------------------------------------------

## s keys: vel_local (body-space velocity, -Z forward) or speed, grounded, vel_up, jetting, jet_power,
## zero_g, fly, vel3_local, rcs, rcs_roll, braking, swim, swim_speed, pitch (rad), yaw_rate (rad/s),
## holding, two_hand, using, exclude (RIDs), probe (false: skip the foot ground rays, e.g. far bots).
func animate(delta: float, s: Dictionary) -> void:
	_t += delta
	var dt := maxf(delta, 1e-4)
	var vloc: Vector3 = s.get("vel_local", Vector3(0, 0, -float(s.get("speed", 0.0))))
	var hv := Vector2(vloc.x, vloc.z)
	var speed := hv.length()
	var grounded: bool = s.get("grounded", true)
	var zero_g: bool = s.get("zero_g", false)
	var jetting: bool = s.get("jetting", false)
	var swim: bool = s.get("swim", false)
	var pitch: float = s.get("pitch", 0.0)
	var holding: bool = s.get("holding", false)
	var k := 1.0 - exp(-10.0 * delta)

	# --- State blends --------------------------------------------------------------------
	var acc := (vloc - _vloc) / dt
	_vloc = vloc
	_acc = _acc.lerp(acc.limit_length(20.0), 1.0 - exp(-5.0 * delta))
	_speed = lerpf(_speed, speed, 1.0 - exp(-8.0 * delta))
	var loco := grounded and not zero_g and not swim
	if loco and not _was_grounded:
		_land = clampf(-float(s.get("vel_up", -3.0)) / 7.0, 0.2, 1.0)
	_was_grounded = loco
	_land = maxf(_land - delta * 2.6, 0.0)
	_ground = move_toward(_ground, 1.0 if loco else 0.0, delta * 7.0)
	_run = lerpf(_run, clampf((_speed - 3.9) / 2.0, 0.0, 1.0) if loco else 0.0, 1.0 - exp(-5.0 * delta))
	_air = lerpf(_air, 1.0 if (not grounded and not zero_g and not swim) else 0.0, k * 0.6)
	_jet = lerpf(_jet, float(s.get("jet_power", 1.0)) if jetting else 0.0, 1.0 - exp(-14.0 * delta))
	_float = lerpf(_float, 1.0 if zero_g else 0.0, k * 0.4)
	_aim = lerpf(_aim, 1.0 if holding else 0.0, k)
	_two_hand = lerpf(_two_hand, 1.0 if s.get("two_hand", false) else 0.0, k)
	_swim = lerpf(_swim, 1.0 if swim else 0.0, k * 0.5)
	_swim_move = lerpf(_swim_move, clampf(float(s.get("swim_speed", 0.0)) / 2.4, 0.0, 1.0) if swim else 0.0, k * 0.4)
	_swim_ph += delta * (1.4 + _swim_move * 2.2)
	var jet_air := minf(_jet * 1.5, 1.0) * _air * (1.0 - _float)

	# --- Gait: speed-matched stride so planted feet do not slide -----------------------------
	var gait := clampf(_speed / 0.7, 0.0, 1.0) * _ground
	var stride := clampf(1.0 + 0.3 * _speed, 1.0, 3.0)           # metres per full cycle (2 steps)
	var stance := lerpf(0.6, 0.32, _run)                          # fraction of the cycle on the ground
	var reach := stance * stride * 0.5
	var lift := lerpf(0.1, 0.2, _run)
	if loco:
		_phase = fmod(_phase + delta * _speed / stride, 1.0)
	var ph := _phase * TAU
	var mdir := Vector3(hv.x, 0.0, hv.y).normalized() if speed > 0.05 else _mdir
	_mdir = _mdir.lerp(mdir, 1.0 - exp(-8.0 * delta)).normalized()
	var breathe := sin(_t * 1.8)
	var idle := 1.0 - gait

	# Idle glances: every few seconds the head turns a little somewhere else.
	_look_t -= delta
	if _look_t <= 0.0:
		_look_t = randf_range(2.5, 6.0)
		_look_to = Vector2(randf_range(-0.45, 0.45), randf_range(-0.12, 0.1)) if randf() < 0.7 else Vector2.ZERO
	_look = _look.lerp(_look_to * idle * _ground * (1.0 - _aim), 1.0 - exp(-2.5 * delta))

	# --- Pelvis: double bob per stride, sway over the stance foot, twist, hip drop, lean -----
	var bob_walk := -0.03 * (0.5 + 0.5 * cos(2.0 * ph))
	var bob_run := -0.035 * (0.5 - 0.5 * cos(2.0 * ph)) + 0.02
	var bob := lerpf(bob_walk, bob_run, _run) * gait
	var sway := -0.022 * sin(ph) * gait * (1.0 - _run * 0.6)
	sway += sin(_t * 0.45) * 0.018 * idle * _ground                 # idle weight shift
	var twist := 0.11 * cos(ph) * gait
	var drop := 0.045 * sin(ph) * gait + sin(_t * 0.45) * 0.03 * idle * _ground
	var lean := -(0.04 + 0.2 * _run) * gait - clampf(-_acc.z * 0.025, -0.18, 0.2) * _ground
	lean -= 0.12 * jet_air * clampf(speed / 3.0, 0.0, 1.0)
	var roll_turn := clampf(float(s.get("yaw_rate", 0.0)) * _speed * 0.03, -0.18, 0.18) * _ground
	var squash := 0.13 * _land * _land
	var low := minf(minf(_foot_off[0], _foot_off[1]), 0.0)
	var hy := _hips_y + bob + breathe * 0.003 - squash + low * _ground
	hy -= 0.05 * _air * (1.0 - _float)
	hips.position = Vector3(sway, hy, 0.0)
	var hips_rot := Vector3(lean, twist, drop + roll_turn)
	hips.rotation = hips_rot

	# --- Foot targets (root space, feet plane y = 0) + ground probes -----------------------
	var tgt := {}
	var foot_pitch := [0.0, 0.0]
	var targets := [Vector3.ZERO, Vector3.ZERO]
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var p := fmod(_phase + (0.0 if i == 0 else 0.5), 1.0)
		var off := 0.0
		var h := 0.0
		var fp := 0.0
		if p < stance:
			var u := p / stance
			off = lerpf(reach, -reach, u)
			fp = 0.25 * (1.0 - smoothstep(0.0, 0.18, u)) - 0.6 * smoothstep(0.7, 1.0, u)
		else:
			var u2 := (p - stance) / (1.0 - stance)
			var e := u2 * u2 * (3.0 - 2.0 * u2)
			off = lerpf(-reach, reach, e)
			h = lift * sin(PI * u2)
			# Running: the heel kicks up behind right after toe-off.
			h += _run * 0.24 * sin(PI * clampf(u2 * 1.7, 0.0, 1.0))
			fp = lerpf(-0.6, 0.25, smoothstep(0.0, 0.8, u2))
		var base := Vector3(side * (0.11 + 0.008 * idle), 0.0, 0.0)
		var t: Vector3 = base + _mdir * off * gait
		t.y = ANKLE_H + h * gait + _foot_off[i] * _ground
		targets[i] = t
		foot_pitch[i] = fp * gait
	if not preview and is_inside_tree() and _ground > 0.01 and s.get("probe", true):
		_probe_ground(targets, s.get("exclude", []), delta)

	# --- Legs: two-bone IK on the ground, posed angles in the air / water / zero-g ----------
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var pl := Vector3(_air_leg(i, side, swim))
		var ik := _leg_ik(i, targets[i], hips_rot, foot_pitch[i])
		var air_sh := _air_shin(i)
		var air_ft := _air_foot()
		# Jetpack: legs together, knees a little bent, toes pointed.
		pl = pl.lerp(Vector3(-0.06 + 0.06 * i, 0.0, side * 0.03), jet_air)
		air_sh = air_sh.lerp(Vector3(-0.32 - 0.08 * i, 0.0, 0.0), jet_air)
		air_ft = air_ft.lerp(Vector3(0.45, 0.0, 0.0), jet_air)
		tgt[thigh[i]] = pl.lerp(ik[0], _ground)
		tgt[shin[i]] = air_sh.lerp(ik[1], _ground)
		tgt[foot[i]] = air_ft.lerp(ik[2], _ground)

	# --- Arms: counter-swing with the legs, elbows bend more when running ------------------
	var swing := lerpf(0.3, 0.62, _run) * gait
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var arm := (-1.0 if i == 0 else 1.0) * cos(ph) * swing
		var sh := Vector3(arm - 0.04 * gait, 0.0, side * (0.13 + 0.03 * breathe * idle))
		var el := Vector3(0.2 + _run * 1.25 + maxf(0.0, arm) * 0.35 * (1.0 - _run), 0.0, 0.0)
		var hd := Vector3(0.05, -side * 0.15, 0.0)
		# Air / zero-g / jetpack / swim arm poses.
		var out_z := side * (0.35 + 0.15 * sin(_t * 0.6 + i))
		sh = sh.lerp(Vector3(0.15, 0, side * 0.32), _air * (1.0 - _float))
		sh = sh.lerp(Vector3(-0.12, side * 0.1, side * 0.36), jet_air)
		el = el.lerp(Vector3(0.45, 0, 0), jet_air)
		sh = sh.lerp(Vector3(0.3 + sin(_t * 0.5 + i) * 0.2, 0, out_z), _float)
		el = el.lerp(Vector3(0.5, 0, 0), _float)
		if _swim > 0.01:
			var sp := _swim_ph
			var stroke_sh := Vector3(1.9 + sin(sp) * 0.9, 0, side * (0.25 + maxf(0.0, cos(sp)) * 0.75))
			var stroke_el := Vector3(0.25 + maxf(0.0, -sin(sp)) * 0.9, 0, 0)
			var tread_sh := Vector3(0.5 + sin(_t * 2.4) * 0.15, 0, side * (0.75 + sin(_t * 2.4 + i) * 0.3))
			sh = sh.lerp(tread_sh.lerp(stroke_sh, _swim_move), _swim)
			el = el.lerp(Vector3(0.6, 0, 0).lerp(stroke_el, _swim_move), _swim)
		tgt[shoulder[i]] = sh
		tgt[elbow[i]] = el
		tgt[hand[i]] = hd

	# --- Weightless free flight ("Superman"): body follows the velocity, right arm forward,
	# left arm along the side, legs together with pointed feet. Braking swings it upright.
	var fly: bool = s.get("fly", false) and zero_g
	var v3: Vector3 = s.get("vel3_local", Vector3.ZERO)
	var sp3 := v3.length()
	var fly_t := clampf((sp3 - 1.5) / 8.0, 0.0, 1.0) if fly else 0.0
	if s.get("braking", false):
		fly_t = 0.0
	_flyk = lerpf(_flyk, fly_t, 1.0 - exp(-(5.0 if fly_t < _flyk else 2.5) * delta))
	if sp3 > 0.6 and fly:
		_fly_dir = _fly_dir.lerp(v3 / sp3, 1.0 - exp(-3.0 * delta)).normalized()
	var rcs: Vector3 = s.get("rcs", Vector3.ZERO)
	_bank = lerpf(_bank, clampf(float(s.get("yaw_rate", 0.0)) * 0.3 + rcs.x * 0.35, -0.6, 0.6) * _flyk, 1.0 - exp(-4.0 * delta))
	if _flyk > 0.01:
		var fk := _flyk
		tgt[shoulder[1]] = (tgt[shoulder[1]] as Vector3).lerp(Vector3(2.85, 0.0, 0.12), fk)
		tgt[elbow[1]] = (tgt[elbow[1]] as Vector3).lerp(Vector3(0.12, 0, 0), fk)
		tgt[hand[1]] = (tgt[hand[1]] as Vector3).lerp(Vector3(-0.2, 0, 0), fk)
		tgt[shoulder[0]] = (tgt[shoulder[0]] as Vector3).lerp(Vector3(0.05, 0.0, -0.14), fk)
		tgt[elbow[0]] = (tgt[elbow[0]] as Vector3).lerp(Vector3(0.15, 0, 0), fk)
		for i in 2:
			var side := -1.0 if i == 0 else 1.0
			var flut := sin(_t * 1.3 + i * 2.0) * 0.05
			tgt[thigh[i]] = (tgt[thigh[i]] as Vector3).lerp(Vector3(-0.08 + flut, 0.0, side * 0.02), fk)
			tgt[shin[i]] = (tgt[shin[i]] as Vector3).lerp(Vector3(-0.18 - flut, 0.0, 0.0), fk)
			tgt[foot[i]] = (tgt[foot[i]] as Vector3).lerp(Vector3(0.75, 0.0, 0.0), fk)

	# --- Torso & head: shoulders counter-rotate the pelvis, head stays level ---------------
	var aim_w := _aim * (1.0 - _flyk) * (1.0 - _swim)
	var blade := aim_w * _two_hand
	var chest_yaw := -twist * 1.5 * (1.0 - _aim * 0.6)
	var aim_p := clampf(pitch, -1.0, 1.0)
	tgt[spine] = Vector3(-lean * 0.25 + breathe * 0.012, chest_yaw * 0.4 - 0.12 * blade, -drop * 0.5)
	tgt[chest] = Vector3(breathe * 0.015 + sin(_t * 0.4) * 0.05 * _float - 0.04 * _land + aim_p * 0.2 * aim_w,
			chest_yaw * 0.6 - 0.22 * blade, -drop * 0.4 - roll_turn * 0.3)
	tgt[head] = Vector3(clampf(pitch, -0.9, 0.9) * (0.6 - 0.2 * aim_w) - lean * 0.8 + _look.y,
			-(twist + chest_yaw) * 0.9 + 0.34 * blade + _look.x,
			-(drop + roll_turn) * 0.6 + sin(_t * 0.3) * 0.03 * idle - 0.08 * blade)

	for b in tgt:
		if b == hips:
			continue
		var r: float = 22.0 if (b in thigh or b in shin or b in foot) and _ground > 0.5 else 14.0
		_rot[b] = (_rot.get(b, Vector3.ZERO) as Vector3).lerp(tgt[b], 1.0 - exp(-r * delta))
		b.rotation = _rot[b]

	# --- Holding an item: arm IK on top of the swing (two-handed at the shoulder) ----------
	if aim_w > 0.002:
		_hold_ik(aim_w, aim_p)
	_set_grip(1, 1.0 if _held != "" else 0.0)       # the fist closes around whatever is shown
	_set_grip(0, blade)

	# Swimming forward tips the whole body toward horizontal (pivot at the body center).
	# Weightless flight: the head points along the velocity, banking into turns.
	if not preview:
		var tilt := -1.25 * _swim_move * _swim
		var pb := Basis(Vector3.RIGHT, tilt)
		if _flyk > 0.01:
			var d := _fly_dir
			var ax := Vector3.UP.cross(d)
			var ang := acos(clampf(Vector3.UP.dot(d), -1.0, 1.0)) * _flyk
			if ax.length_squared() > 1e-6:
				pb = Basis(ax.normalized(), ang) * pb
			pb = Basis(pb.y.normalized(), _bank) * pb
			head.rotation.x += -ang * 0.55       # look ahead, not at the ground
		var c := Vector3(0, 0.9, 0)
		transform = Transform3D(pb, c - pb * c)
		head.rotation.x += -tilt * 0.8

	_update_fx()


## Jetpack flames / particles and the blinking pack lights.
func _update_fx() -> void:
	var show_flames := _jet > 0.05 and not _first_person
	for f in _flames:
		f.visible = show_flames
		if show_flames:
			var l := (0.25 + 0.25 * _jet) * randf_range(0.8, 1.15)
			f.scale = Vector3(1.0, l, 1.0) * lerpf(0.6, 1.0, _jet)
			f.position.y = (AP.NOZZLES[0] as Vector3).y - l * 0.5
	_flame_mat.set_shader_parameter("power", _jet)
	for jp in _jet_particles:
		jp.emitting = _jet > 0.08
		jp.amount_ratio = clampf(_jet, 0.2, 1.0)
	_lights_mat.emission_energy_multiplier = 3.5 + sin(_t * 2.0) * 0.5
	_status_mat.emission_energy_multiplier = 3.0 if fmod(_t, 1.6) < 1.3 else 0.6


## Root-space transform of the chest bone (current pose).
func _chest_xf() -> Transform3D:
	return hips.transform * spine.transform * chest.transform


## Arm IK for a held item, blended over the current arm pose by w. Two-handed: the stock sits in
## the right shoulder pocket, the gun points along the view pitch and the left hand holds the front.
## One-handed: the right hand holds the item forward at chest height.
func _hold_ik(w: float, pitch: float) -> void:
	var cx := _chest_xf()
	var f := Vector3(0.0, sin(pitch), -cos(pitch))
	var up := Vector3(0.0, cos(pitch), sin(pitch))
	var gb := Basis(Vector3.RIGHT, up, -f)                     # prop frame: +Y up, -Z forward
	var hb := gb * Basis(Vector3.RIGHT, PI * 0.5)              # hand basis that holds it
	var pocket := cx * Vector3(0.115, 0.29, -0.125)
	var g := Transform3D(gb, pocket - gb * Vector3(0.0, 0.05, 0.245))
	var w_two := g.origin - hb * AP.GRIP
	var w_one := cx.origin + Vector3(0.15, 0.08, 0.0) + f * 0.36 - hb * AP.GRIP
	var two := _two_hand
	var wr := w_one.lerp(w_two, two)
	_arm_ik(1, wr, hb, Vector3(0.65, -0.7, 0.3).lerp(Vector3(0.35, -0.9, 0.25), 1.0 - two), w)
	if two > 0.01:
		var sz: float = SUPPORT_Z.get(_held, -0.22)
		var lp := g * Vector3(0.0, 0.042, sz)
		var zl := -f
		var xl := up
		var lb := Basis(xl, zl.cross(xl), zl)
		var wl := lp - lb * AP.GRIP
		_arm_ik(0, wl, lb, Vector3(-0.3, -0.9, 0.15), w * two)


## Arm i: wrist target and hand basis (root space), elbow pole direction, blend weight.
func _arm_ik(i: int, wrist: Vector3, hb: Basis, pole: Vector3, w: float) -> void:
	_two_bone(shoulder[i], elbow[i], hand[i], _chest_xf(), AP.L_UPPER, AP.L_FORE, wrist, hb, pole, 1.0, w)


## Analytic two-bone IK in root space. a / b / c: upper, lower and end bone (each the child of the
## previous, identity rest rotation, bone pointing down -Y); parent_xf: root-space transform of a's
## parent; target: where c's origin should go; end_b: root-space basis for c; pole: the direction
## the middle joint points to; bend = +1 when the lower bone swings toward -Z (elbow), -1 toward +Z
## (knee). The rotations blend toward the solution by w.
func _two_bone(a: Node3D, b: Node3D, c: Node3D, parent_xf: Transform3D, la: float, lb: float, target: Vector3,
		end_b: Basis, pole: Vector3, bend: float, w: float) -> void:
	var S: Vector3 = parent_xf * a.position
	var d := target - S
	var dist := clampf(d.length(), 0.08, (la + lb) * 0.999)
	var dn := d.normalized()
	var ax := (la * la - lb * lb + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(la * la - ax * ax, 0.0))
	var pn := pole - dn * pole.dot(dn)
	if pn.length_squared() < 1e-6:
		pn = Vector3.DOWN - dn * Vector3.DOWN.dot(dn)
	pn = pn.normalized()
	var E := S + dn * ax + pn * h
	var W := S + dn * dist
	var u := (E - S).normalized()
	var fd := (W - E).normalized()
	var side := fd - u * fd.dot(u)
	if side.length_squared() < 1e-6:
		side = -pn
	side = side.normalized()
	var Y := -u
	var Z := -side * bend
	var X := Y.cross(Z).normalized()
	var upper := Basis(X, Y, Z)
	var ang := acos(clampf(u.dot(fd), -1.0, 1.0)) * bend
	var lower := upper * Basis(Vector3.RIGHT, ang)
	var a_l := (parent_xf.basis.inverse() * upper).orthonormalized()
	var b_l := Basis(Vector3.RIGHT, ang)
	var c_l := (lower.inverse() * end_b).orthonormalized()
	if w >= 0.999:
		a.basis = a_l
		b.basis = b_l
		c.basis = c_l
	else:
		a.basis = a.basis.orthonormalized().slerp(a_l, w)
		b.basis = b.basis.orthonormalized().slerp(b_l, w)
		c.basis = c.basis.orthonormalized().slerp(c_l, w)


## Analytic two-bone IK for one leg. `target` = ankle position in root space. Returns
## [thigh rotation, knee rotation, foot rotation] (knees bend forward, foot pitch absolute).
func _leg_ik(i: int, target: Vector3, hips_rot: Vector3, foot_pitch: float) -> Array:
	var hip_local: Vector3 = (thigh[i] as Node3D).position
	var t_h: Vector3 = hips.transform.affine_inverse() * target
	var d := t_h - hip_local
	var l := clampf(d.length(), 0.1, (L_THIGH + L_SHIN) * 0.999)
	var cos_k := clampf((L_THIGH * L_THIGH + L_SHIN * L_SHIN - l * l) / (2.0 * L_THIGH * L_SHIN), -1.0, 1.0)
	var knee := -(PI - acos(cos_k))
	var alpha := acos(clampf((L_THIGH * L_THIGH + l * l - L_SHIN * L_SHIN) / (2.0 * L_THIGH * l), -1.0, 1.0))
	var theta := atan2(-d.z, -d.y)
	var th_x := theta + alpha
	var th_z := atan2(d.x, -d.y)
	var f_x := foot_pitch - (hips_rot.x + th_x + knee)
	return [Vector3(th_x, 0.0, th_z), Vector3(knee, 0.0, 0.0), Vector3(f_x, 0.0, -th_z - hips_rot.z)]


## Leg pose when not walking on the ground (air / jetpack / zero-g / swim).
func _air_leg(i: int, side: float, swim: bool) -> Vector3:
	var th := 0.18 if i == 0 else -0.05
	var z := side * (0.04 + 0.04 * _air)
	var fl := sin(_t * 0.7 + i * 1.7)
	th = lerpf(th, 0.2 + fl * 0.12, _float)
	z = lerpf(z, side * 0.1, _float)
	if swim or _swim > 0.01:
		var kick := sin(_t * lerpf(2.2, 7.0, _swim_move) + i * PI)
		th = lerpf(th, kick * lerpf(0.35, 0.28, _swim_move), _swim)
		z = lerpf(z, side * 0.06, _swim)
	return Vector3(th, 0.0, z)


func _air_shin(i: int) -> Vector3:
	var kn := -0.45 if i == 0 else -0.25
	kn = lerpf(kn, -0.45 + sin(_t * 0.7 + i * 1.7) * 0.1, _float)
	if _swim > 0.01:
		var kick := sin(_t * lerpf(2.2, 7.0, _swim_move) + i * PI)
		kn = lerpf(kn, -0.35 - maxf(0.0, kick) * 0.35, _swim)
	return Vector3(kn, 0.0, 0.0)


func _air_foot() -> Vector3:
	return Vector3(lerpf(0.25, 0.6, _swim), 0.0, 0.0)


## Ground under each foot target (2 short raycasts): lifts/lowers the feet on slopes and steps
## and lowers the pelvis when a foot has to reach down.
func _probe_ground(targets: Array, exclude: Array, delta: float) -> void:
	var space := get_world_3d().direct_space_state
	var gx := global_transform
	var up := gx.basis.y.normalized()
	for i in 2:
		var t: Vector3 = targets[i]
		var wp: Vector3 = gx * Vector3(t.x, 0.0, t.z)
		var q := PhysicsRayQueryParameters3D.create(wp + up * 0.45, wp - up * 0.55, 1 | 2 | 4, exclude)
		var hit := space.intersect_ray(q)
		var want := 0.0
		if not hit.is_empty():
			want = clampf((hit["position"] - wp).dot(up), -0.35, 0.35)
		_foot_off[i] = lerpf(_foot_off[i], want, 1.0 - exp(-14.0 * delta))


## Helmet lamp lens glows when the headlamp is on (k = current brightness 0..1).
func set_lamp(on: bool, k: float) -> void:
	_lamp_mat.emission_energy_multiplier = 9.0 * k if on else 0.25


## Flame / spark particle jet under a backpack nozzle.
func _make_jet_particles(parent: Node3D, pos: Vector3) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 40
	p.lifetime = 0.26
	p.local_coords = true          # stays a tight cone even at 30 m/s flight
	p.emitting = false
	p.position = pos
	p.visibility_aabb = AABB(Vector3(-4, -6, -4), Vector3(8, 8, 8))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 7.0
	pm.initial_velocity_min = 5.0
	pm.initial_velocity_max = 8.0
	pm.gravity = Vector3.ZERO
	pm.damping_min = 4.0
	pm.damping_max = 8.0
	pm.scale_min = 0.6
	pm.scale_max = 1.2
	var sc := Curve.new()
	sc.add_point(Vector2(0, 1.0))
	sc.add_point(Vector2(1, 0.15))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	g.colors = PackedColorArray([Color(1.6, 1.4, 1.1, 0.9), Color(1.6, 0.6, 0.15, 0.7), Color(0.4, 0.15, 0.05, 0.0)])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = preload("res://scripts/items/dig_fx.gd").soft_texture()
	var q := QuadMesh.new()
	q.size = Vector2(0.14, 0.14)
	q.material = m
	p.draw_pass_1 = q
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(p)
	return p
