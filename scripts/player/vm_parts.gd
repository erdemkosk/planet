extends RefCounted
## Procedural building blocks for the first-person view model (arms, gloves, held items).
## All view-model materials use a shader that squeezes depth toward the near plane, so the
## arms and the held item always draw on top of world geometry (no clipping into walls).

const VM_SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness = 0.6;
uniform float metallic = 0.0;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float weave = 0.0;      // fabric pattern strength
uniform float rim = 0.25;       // fresnel rim light (keeps arms readable in the dark)
uniform float fill = 0.035;     // tiny self-illumination so the suit never goes pitch black

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	// Reverse-Z: 1 = near plane. Keep the view model in the [0.92, 1] depth slice.
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	vec3 col = albedo.rgb;
	if (weave > 0.0) {
		float w = sin(UV.x * 260.0) * sin(UV.y * 140.0);
		float n = fract(sin(dot(floor(UV * vec2(260.0, 140.0)), vec2(12.9898, 78.233))) * 43758.5453);
		col *= 1.0 - weave * (0.35 + 0.35 * w + 0.3 * n);
	}
	ALBEDO = col;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = emission * emission_energy + col * (fill + rim * f * 0.25);
}
"""

const GLOW_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform vec4 color : source_color = vec4(1.0);
uniform float energy = 3.0;
uniform float flicker = 0.0;

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	float f = 1.0 - flicker * (0.5 + 0.5 * sin(TIME * 47.0 + UV.y * 30.0));
	float edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALBEDO = color.rgb * energy * f * (0.75 + 0.5 * edge);
}
"""

const SCREEN_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform float energy = 1.6;

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	vec3 c = texture(tex, UV).rgb;
	c *= 0.9 + 0.1 * sin(UV.y * 500.0 + TIME * 5.0);
	ALBEDO = c * energy;
}
"""

## See-through tinted glass (optic windows), drawn in the view-model depth slice.
const GLASS_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform vec4 tint : source_color = vec4(0.3, 0.7, 0.75, 0.12);

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);
}

void fragment() {
	float edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALBEDO = tint.rgb;
	ALPHA = clamp(tint.a + edge * 0.25, 0.0, 1.0);
}
"""

static var _glass_shader: Shader


static func glass(tint := Color(0.3, 0.7, 0.75, 0.12)) -> ShaderMaterial:
	if _glass_shader == null:
		_glass_shader = Shader.new()
		_glass_shader.code = prep(GLASS_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _glass_shader
	m.set_shader_parameter("tint", tint)
	return m


## Holographic weapon sight on a rail (weapon mods): riser, slim frame, tinted window and a glowing
## reticle dot exactly on the sight line y = sight_y (gun frame, -Z forward). Returns the root node.
static func holo_sight(parent: Node3D, z: float, rail_y: float, sight_y: float, dot := Color(1.0, 0.25, 0.2)) -> Node3D:
	var o := node(parent)
	var dark := dark_metal()
	var frame := mat(Color(0.2, 0.21, 0.23), 0.4, 0.5)
	var wz := z - 0.01
	var bottom := sight_y - 0.017
	soft_box(o, Vector3(0, (rail_y + bottom) * 0.5, z), Vector3(0.028, maxf(bottom - rail_y, 0.006), 0.05), 0.004, dark)
	box(o, Vector3(0, bottom, wz), Vector3(0.042, 0.006, 0.026), frame)
	for sx in [-1.0, 1.0]:
		box(o, Vector3(0.0195 * sx, sight_y, wz), Vector3(0.004, 0.04, 0.026), frame)
	box(o, Vector3(0, sight_y + 0.0185, wz), Vector3(0.043, 0.005, 0.026), frame)
	box(o, Vector3(0, sight_y + 0.0215, wz + 0.004), Vector3(0.014, 0.002, 0.012), suit_orange())
	var g := box(o, Vector3(0, sight_y, wz - 0.008), Vector3(0.035, 0.031, 0.0015), glass())
	g.set_meta("no_bake", true)
	var gm := glow(dot, 7.0)
	var d := sphere(o, Vector3(0, sight_y, wz - 0.012), 0.0017, gm)
	d.set_meta("no_bake", true)
	var rg := ring(o, Vector3(0, sight_y, wz - 0.012), Vector3.BACK, 0.0085, 0.0009, gm)
	rg.set_meta("no_bake", true)
	return o


## The camera FOV and the narrower FOV the arms are drawn with (less wide-angle distortion).
const CAM_FOV := 75.0
const VM_FOV := 70.0

static var _vm_shader: Shader
static var _glow_shader: Shader
static var _screen_shader: Shader
static var _mats := {}


## Projection scale applied to the view model in clip space.
static func fov_scale() -> float:
	return tan(deg_to_rad(CAM_FOV * 0.5)) / tan(deg_to_rad(VM_FOV * 0.5))


## Prepares view-model shader code (inserts the FOV scale). Other scripts use this too.
static func prep(code: String) -> String:
	return code.replace("VM_K", "%.5f" % fov_scale())


## World position that appears on screen where view-model point `p` is drawn
## (used to start world-space effects like the dig beam at the nozzle).
static func vm_to_world(cam: Camera3D, p: Vector3) -> Vector3:
	var k := fov_scale()
	var local := cam.global_transform.affine_inverse() * p
	return cam.global_transform * Vector3(local.x * k, local.y * k, local.z)


static func vm_shader() -> Shader:
	if _vm_shader == null:
		_vm_shader = Shader.new()
		_vm_shader.code = prep(VM_SHADER)
	return _vm_shader


## Unshaded screen showing a texture (e.g. a SubViewport).
static func screen_mat(tex: Texture2D, energy := 1.6) -> ShaderMaterial:
	if _screen_shader == null:
		_screen_shader = Shader.new()
		_screen_shader.code = prep(SCREEN_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _screen_shader
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("energy", energy)
	return m


## Cached lit material. Same parameters share one material.
static func mat(albedo: Color, rough := 0.6, metal := 0.0, weave := 0.0, rim := 0.25) -> ShaderMaterial:
	var key := "%s|%.2f|%.2f|%.2f|%.2f" % [albedo.to_html(), rough, metal, weave, rim]
	if _mats.has(key):
		return _mats[key]
	var m := ShaderMaterial.new()
	m.shader = vm_shader()
	m.set_shader_parameter("albedo", albedo)
	m.set_shader_parameter("roughness", rough)
	m.set_shader_parameter("metallic", metal)
	m.set_shader_parameter("weave", weave)
	m.set_shader_parameter("rim", rim)
	_mats[key] = m
	return m


## Unshaded emissive material (not cached so it can be recolored / animated per item).
static func glow(color: Color, energy := 3.0) -> ShaderMaterial:
	if _glow_shader == null:
		_glow_shader = Shader.new()
		_glow_shader.code = prep(GLOW_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _glow_shader
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("energy", energy)
	return m


# --- Common palette -------------------------------------------------------------------------

static func suit_white() -> ShaderMaterial:
	return mat(Color(0.86, 0.87, 0.85), 0.75, 0.0, 0.10)

static func suit_orange() -> ShaderMaterial:
	return mat(Color(0.95, 0.42, 0.08), 0.55, 0.0, 0.06)

static func suit_gray() -> ShaderMaterial:
	return mat(Color(0.55, 0.57, 0.6), 0.5, 0.2)

static func metal() -> ShaderMaterial:
	return mat(Color(0.62, 0.64, 0.68), 0.28, 0.85)

static func dark_metal() -> ShaderMaterial:
	return mat(Color(0.16, 0.17, 0.19), 0.35, 0.7)

static func glove() -> ShaderMaterial:
	return mat(Color(0.25, 0.26, 0.29), 0.75, 0.0, 0.06, 0.4)

static func glove_pad() -> ShaderMaterial:
	return mat(Color(0.42, 0.44, 0.47), 0.55, 0.0)

static func plastic_white() -> ShaderMaterial:
	return mat(Color(0.9, 0.91, 0.92), 0.32, 0.0)

static func rubber() -> ShaderMaterial:
	return mat(Color(0.09, 0.09, 0.1), 0.9, 0.0)


# --- Geometry -------------------------------------------------------------------------------

## Orthonormal basis whose Y axis points along `dir`.
static func basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


static func node(parent: Node3D, pos := Vector3.ZERO, b := Basis()) -> Node3D:
	var n := Node3D.new()
	n.transform = Transform3D(b, pos)
	parent.add_child(n)
	return n


static func mesh_inst(parent: Node3D, mesh: Mesh, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(mi)
	return mi


## Tapered cylinder from a (radius ra) to b (radius rb).
static func seg(parent: Node3D, a: Vector3, b: Vector3, ra: float, rb: float, m: Material, sides := 18) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.bottom_radius = ra
	cm.top_radius = rb
	cm.height = maxf(a.distance_to(b), 0.001)
	cm.radial_segments = sides
	cm.rings = 1
	var mi := mesh_inst(parent, cm, m)
	mi.transform = Transform3D(basis_y(b - a), (a + b) * 0.5)
	return mi


## Capsule whose cap centers are a and b.
static func capsule(parent: Node3D, a: Vector3, b: Vector3, r: float, m: Material, sides := 14) -> MeshInstance3D:
	var cm := CapsuleMesh.new()
	cm.radius = r
	cm.height = a.distance_to(b) + r * 2.0
	cm.radial_segments = sides
	cm.rings = 4
	var mi := mesh_inst(parent, cm, m)
	mi.transform = Transform3D(basis_y(b - a) if a.distance_to(b) > 1e-5 else Basis(), (a + b) * 0.5)
	return mi


## Torus ring around `axis` through `center`.
static func ring(parent: Node3D, center: Vector3, axis: Vector3, r_out: float, thick: float, m: Material) -> MeshInstance3D:
	var tm := TorusMesh.new()
	tm.inner_radius = r_out - thick
	tm.outer_radius = r_out
	tm.rings = 20
	tm.ring_segments = 8
	var mi := mesh_inst(parent, tm, m)
	mi.transform = Transform3D(basis_y(axis), center)
	return mi


static func ellipsoid(parent: Node3D, pos: Vector3, radii: Vector3, m: Material, b := Basis()) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 18
	sm.rings = 10
	var mi := mesh_inst(parent, sm, m)
	mi.transform = Transform3D(b * Basis.from_scale(radii), pos)
	return mi


static func sphere(parent: Node3D, pos: Vector3, r: float, m: Material) -> MeshInstance3D:
	return ellipsoid(parent, pos, Vector3.ONE * r, m)


static func box(parent: Node3D, pos: Vector3, size: Vector3, m: Material, b := Basis()) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := mesh_inst(parent, bm, m)
	mi.transform = Transform3D(b, pos)
	return mi


## Box with softened edges: a box core plus capsules along its four long edges (Z axis).
static func soft_box(parent: Node3D, pos: Vector3, size: Vector3, r: float, m: Material, b := Basis()) -> Node3D:
	var n := node(parent, pos, b)
	box(n, Vector3.ZERO, Vector3(size.x - r * 2.0, size.y, size.z), m)
	box(n, Vector3.ZERO, Vector3(size.x, size.y - r * 2.0, size.z), m)
	var hx := size.x * 0.5 - r
	var hy := size.y * 0.5 - r
	var hz := size.z * 0.5 - r
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			capsule(n, Vector3(sx * hx, sy * hy, hz), Vector3(sx * hx, sy * hy, -hz), r, m, 10)
	return n


## A pistol grip centered at the origin of the hand frame (vertical, Y up).
static func grip(parent: Node3D, accent: Material) -> void:
	capsule(parent, Vector3(0, -0.068, 0.008), Vector3(0, 0.012, -0.002), 0.0185, rubber())
	for i in 3:
		ring(parent, Vector3(0, -0.05 + i * 0.022, 0.006 - i * 0.002), Vector3(0, 1, -0.1), 0.0195, 0.004, dark_metal())
	seg(parent, Vector3(0, -0.092, 0.01), Vector3(0, -0.078, 0.009), 0.022, 0.02, accent)


## Merges all primitive MeshInstance3D descendants of `root` (except subtrees in `skip`) into
## one ArrayMesh with one surface per material. Cuts the view model's draw calls ~5x.
## Normals are transformed with the inverse-transpose so scaled spheres stay smooth.
static func bake(root: Node3D, skip: Array = []) -> MeshInstance3D:
	var groups := {}
	var victims: Array = []
	_bake_collect(root, Transform3D.IDENTITY, skip, groups, victims)
	if victims.is_empty():
		return null
	var am := ArrayMesh.new()
	for key in groups:
		var g: Dictionary = groups[key]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = g["v"]
		arrays[Mesh.ARRAY_NORMAL] = g["n"]
		arrays[Mesh.ARRAY_TEX_UV] = g["uv"]
		arrays[Mesh.ARRAY_INDEX] = g["i"]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		am.surface_set_material(am.get_surface_count() - 1, g["mat"])
	for v in victims:
		v.get_parent().remove_child(v)
		v.queue_free()
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(mi)
	return mi


static func _bake_collect(n: Node, xf: Transform3D, skip: Array, groups: Dictionary, victims: Array) -> void:
	for c in n.get_children():
		if skip.has(c) or not (c is Node3D):
			continue
		var cx: Transform3D = xf * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null and (c as MeshInstance3D).mesh.get_surface_count() == 1 and c.get_child_count() == 0 and not c.has_meta("no_bake"):
			var mi := c as MeshInstance3D
			var m: Material = mi.material_override
			var key := m.get_instance_id() if m else 0
			if not groups.has(key):
				groups[key] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(),
						"i": PackedInt32Array(), "mat": m}
			var g: Dictionary = groups[key]
			var arr: Array = mi.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var uvs = arr[Mesh.ARRAY_TEX_UV]
			var idx = arr[Mesh.ARRAY_INDEX]
			var nb := cx.basis.inverse().transposed()
			var base: int = g["v"].size()
			var gv: PackedVector3Array = g["v"]
			var gn: PackedVector3Array = g["n"]
			var guv: PackedVector2Array = g["uv"]
			var gi: PackedInt32Array = g["i"]
			for k in verts.size():
				gv.append(cx * verts[k])
				gn.append((nb * norms[k]).normalized())
				guv.append(uvs[k] if uvs != null and k < uvs.size() else Vector2.ZERO)
			if idx != null and idx.size() > 0:
				for k in idx.size():
					gi.append(base + idx[k])
			else:
				for k in verts.size():
					gi.append(base + k)
			g["v"] = gv
			g["n"] = gn
			g["uv"] = guv
			g["i"] = gi
			victims.append(mi)
		else:
			_bake_collect(c, cx, skip, groups, victims)
