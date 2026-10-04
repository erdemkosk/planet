extends RefCounted
## Meshes and materials for space debris (scripts/space/space_debris.gd): a lumpy rock, a bent
## hull-plate scrap piece, ore shards, the halo billboard of crystal cores / pod beacons. One rock
## shader serves both the far MultiMesh fields (per-instance vein colour in COLOR, spin axis + rate
## in INSTANCE_CUSTOM, spun in world space about the instance origin by spin_time * rate: no CPU
## work per instance) and the few near physics bodies (instance uniform, use_inst = true; the
## physics body rotates them). The manager starts a body at exactly the angle the shader shows, so
## the hand-over is seamless. No shadows anywhere.

const FX_PRIORITY := 121          # transparent effects after the ocean / atmosphere passes (shuttle.gd)

const ROCK_SHADER := """
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, world_vertex_coords;
uniform vec3 col_a : source_color = vec3(0.23, 0.215, 0.2);
uniform vec3 col_b : source_color = vec3(0.36, 0.33, 0.30);
uniform float scrap = 0.0;
uniform bool use_inst = false;
uniform float spin_time = 0.0;
instance uniform vec4 inst_vein : source_color = vec4(0.0, 0.0, 0.0, 0.0);
varying vec3 lp;
varying vec4 vein;

vec3 rot_axis(vec3 v, vec3 ax, float a) {
	float c = cos(a);
	float s = sin(a);
	return v * c + cross(ax, v) * s + ax * dot(ax, v) * (1.0 - c);
}

void vertex() {
	lp = (inverse(MODEL_MATRIX) * vec4(VERTEX, 1.0)).xyz;
	if (use_inst) {
		vein = inst_vein;
	} else {
		vein = COLOR;
		float rate = INSTANCE_CUSTOM.w;
		if (abs(rate) > 0.0001) {
			vec3 ax = normalize(INSTANCE_CUSTOM.xyz + vec3(0.0001, 0.0002, 0.0003));
			float a = spin_time * rate;
			vec3 o = MODEL_MATRIX[3].xyz;
			VERTEX = o + rot_axis(VERTEX - o, ax, a);
			NORMAL = rot_axis(NORMAL, ax, a);
		}
	}
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(hash13(i), hash13(i + vec3(1.0, 0.0, 0.0)), f.x);
	float b = mix(hash13(i + vec3(0.0, 1.0, 0.0)), hash13(i + vec3(1.0, 1.0, 0.0)), f.x);
	float c = mix(hash13(i + vec3(0.0, 0.0, 1.0)), hash13(i + vec3(1.0, 0.0, 1.0)), f.x);
	float d = mix(hash13(i + vec3(0.0, 1.0, 1.0)), hash13(i + vec3(1.0, 1.0, 1.0)), f.x);
	return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

void fragment() {
	float n = vnoise(lp * 2.7) * 0.65 + vnoise(lp * 7.9) * 0.35;
	vec3 base = mix(col_a, col_b, n);
	float rough = 0.92;
	float metal_v = 0.0;
	if (scrap > 0.5) {
		// Hull plate: white / orange panels, scorched, scratched to bare metal.
		float panel = step(0.55, fract(lp.x * 0.9 + floor(lp.z * 1.7) * 0.37));
		vec3 paint = mix(vec3(0.74, 0.74, 0.72), vec3(0.82, 0.4, 0.12), panel);
		float burn = smoothstep(0.35, 0.75, vnoise(lp * 3.3 + vec3(7.0)));
		base = mix(paint, vec3(0.13, 0.12, 0.11), burn * 0.85);
		base = mix(base, vec3(0.52, 0.54, 0.57), smoothstep(0.62, 0.9, n) * 0.6);
		rough = mix(0.42, 0.8, burn);
		metal_v = mix(0.7, 0.2, burn);
	}
	// Ore veins: alpha < 0.5 = vein width (rich chunks wider), >= 0.5 = crystal core (wide, glowing).
	float s = vein.a;
	float w = s < 0.5 ? 0.025 + s * 0.22 : 0.13;
	float glow = s < 0.5 ? 0.0 : (s - 0.5) * 2.0;
	float vn = vnoise(lp * 2.1 + vec3(11.3, 4.1, 7.7));
	float vm = (1.0 - smoothstep(w * 0.5, w, abs(vn - 0.5))) * step(0.02, vein.r + vein.g + vein.b);
	ALBEDO = mix(base, vein.rgb * 0.8, vm * 0.85);
	ROUGHNESS = mix(rough, 0.3, vm);
	METALLIC = mix(metal_v, 0.55, vm);
	EMISSION = vein.rgb * (vm * (0.08 + glow * 2.6) + glow * 0.05);
}
"""

## Additive soft glow billboard that never shrinks below a few pixels (crystal cores and salvage
## pod beacons stay findable from far away). `dim` fades it inside an atmosphere.
const HALO_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 tint : source_color = vec4(0.5, 0.95, 1.0, 1.0);
uniform float base_size = 2.5;
uniform float px = 0.005;
uniform float pulse_rate = 0.0;
uniform float blink = 0.0;
uniform float dim = 1.0;
varying float k;

void vertex() {
	vec4 cv = VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0);
	float d = max(-cv.z, 0.01);
	float sz = max(base_size, d * px);
	// COLOR.a: per-instance on / off (MultiMesh colours; plain meshes have none = 1).
	k = clamp(base_size / sz, 0.35, 1.0) * COLOR.a;
	vec3 v = cv.xyz + vec3(VERTEX.x, VERTEX.y, 0.0) * sz;
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
}

void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	float g = pow(max(1.0 - r, 0.0), 2.4);
	float p = 1.0;
	if (pulse_rate > 0.0) {
		p = 0.7 + 0.3 * sin(TIME * pulse_rate);
	}
	if (blink > 0.0) {
		p *= step(0.82, fract(TIME * blink)) * 0.85 + 0.15;
	}
	ALBEDO = tint.rgb * 1.6;
	ALPHA = clamp(g * k * p * dim * tint.a, 0.0, 1.0);
}
"""

static var _cache := {}


## Unit-radius lumpy rock (~150 triangles), smooth normals.
static func rock_mesh() -> Mesh:
	if _cache.has("rock"):
		return _cache["rock"]
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 12
	sm.rings = 7
	var arrays := sm.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# Weld the seam so the displacement stays closed, then dent it (sum of low-frequency waves).
	for i in verts.size():
		var v := verts[i]
		var k := 1.0 + 0.16 * sin(v.x * 3.1 + v.y * 1.7) * cos(v.z * 2.6 - v.x * 1.3) \
				+ 0.09 * sin(v.y * 5.3 + v.z * 4.1) + 0.06 * cos(v.x * 7.7 - v.z * 6.1)
		if v.y > 0.55:
			k -= (v.y - 0.55) * 0.35          # one flatter facet
		verts[i] = v * k
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in idx:
		st.add_vertex(verts[i])
	st.index()
	st.generate_normals()
	var m := st.commit()
	_cache["rock"] = m
	return m


## A bent, torn hull plate with a stiffener rib (scrap from USS-07), ~1 m across at scale 1.
static func scrap_mesh() -> Mesh:
	if _cache.has("scrap"):
		return _cache["scrap"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_bent_box(st, Vector3(1.1, 0.07, 0.8), Vector3.ZERO, 0.35, 5)
	_bent_box(st, Vector3(1.0, 0.18, 0.08), Vector3(0.0, 0.12, 0.1), 0.35, 5)
	_bent_box(st, Vector3(0.08, 0.14, 0.6), Vector3(0.32, 0.1, 0.0), 0.1, 2)
	st.generate_normals()
	var m := st.commit()
	_cache["scrap"] = m
	return m


## Box of `size` centred at `c`, bent along x (y += bend * x²) and torn at the ends.
static func _bent_box(st: SurfaceTool, size: Vector3, c: Vector3, bend: float, seg: int) -> void:
	var h := size * 0.5
	var xs: Array = []
	for i in seg + 1:
		xs.append(-h.x + size.x * float(i) / float(seg))
	var f := func(x: float, y: float, z: float) -> Vector3:
		var tear := 0.06 * sin(z * 17.0 + x * 5.0) * smoothstep(h.x * 0.6, h.x, absf(x))
		return Vector3(x + tear, y + bend * x * x, z) + c
	for i in seg:
		var x0: float = xs[i]
		var x1: float = xs[i + 1]
		for sy: float in [-1.0, 1.0]:
			var a: Vector3 = f.call(x0, sy * h.y, -h.z)
			var b: Vector3 = f.call(x1, sy * h.y, -h.z)
			var cc: Vector3 = f.call(x1, sy * h.y, h.z)
			var d: Vector3 = f.call(x0, sy * h.y, h.z)
			if sy > 0.0:
				_quad(st, a, d, cc, b)
			else:
				_quad(st, a, b, cc, d)
		for sz: float in [-1.0, 1.0]:
			var a2: Vector3 = f.call(x0, -h.y, sz * h.z)
			var b2: Vector3 = f.call(x1, -h.y, sz * h.z)
			var c2: Vector3 = f.call(x1, h.y, sz * h.z)
			var d2: Vector3 = f.call(x0, h.y, sz * h.z)
			if sz > 0.0:
				_quad(st, a2, b2, c2, d2)
			else:
				_quad(st, a2, d2, c2, b2)
	for sx: float in [-1.0, 1.0]:
		var x: float = h.x * sx
		var a3: Vector3 = f.call(x, -h.y, -h.z)
		var b3: Vector3 = f.call(x, h.y, -h.z)
		var c3: Vector3 = f.call(x, h.y, h.z)
		var d3: Vector3 = f.call(x, -h.y, h.z)
		if sx > 0.0:
			_quad(st, a3, b3, c3, d3)
		else:
			_quad(st, a3, d3, c3, b3)


## a b c d counter-clockwise seen from outside; Godot's front faces wind clockwise.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(b)
	st.add_vertex(a)
	st.add_vertex(d)
	st.add_vertex(c)


## Axis-aligned box with flat normals and one vertex colour.
static func _cbox(st: SurfaceTool, c: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var faces: Array = [[Vector3.RIGHT, Vector3.UP, Vector3.BACK], [Vector3.LEFT, Vector3.BACK, Vector3.UP],
			[Vector3.UP, Vector3.BACK, Vector3.RIGHT], [Vector3.DOWN, Vector3.RIGHT, Vector3.BACK],
			[Vector3.BACK, Vector3.RIGHT, Vector3.UP], [Vector3.FORWARD, Vector3.UP, Vector3.RIGHT]]
	st.set_color(col)
	for fc: Array in faces:
		var n: Vector3 = fc[0]
		var u: Vector3 = fc[1]
		var v: Vector3 = fc[2]
		var hn := absf(n.x) * h.x + absf(n.y) * h.y + absf(n.z) * h.z
		var hu := absf(u.x) * h.x + absf(u.y) * h.y + absf(u.z) * h.z
		var hv := absf(v.x) * h.x + absf(v.y) * h.y + absf(v.z) * h.z
		var cf := c + n * hn
		st.set_normal(n)
		_quad(st, cf - u * hu - v * hv, cf + u * hu - v * hv, cf + u * hu + v * hv, cf - u * hu + v * hv)


## Salvage pod body (1.5 x 0.9 x 1.0 m, long axis x): white shell, orange bands, dark end caps
## and grab rails. One surface, vertex colours.
static func pod_body_mesh() -> Mesh:
	if _cache.has("pod_body"):
		return _cache["pod_body"]
	var white := Color(0.8, 0.81, 0.83)
	var orange := Color(0.88, 0.42, 0.1)
	var dark := Color(0.14, 0.15, 0.17)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_cbox(st, Vector3(0, -0.05, 0), Vector3(1.5, 0.72, 0.92), white)
	for sx: float in [-1.0, 1.0]:
		_cbox(st, Vector3(sx * 0.55, -0.05, 0), Vector3(0.12, 0.76, 0.96), orange)
		_cbox(st, Vector3(sx * 0.74, -0.04, 0), Vector3(0.06, 0.86, 1.0), dark)
	for sz: float in [-1.0, 1.0]:
		_cbox(st, Vector3(0, 0.02, sz * 0.5), Vector3(0.62, 0.05, 0.05), dark)
		_cbox(st, Vector3(-0.3, 0.02, sz * 0.485), Vector3(0.05, 0.05, 0.03), dark)
		_cbox(st, Vector3(0.3, 0.02, sz * 0.485), Vector3(0.05, 0.05, 0.03), dark)
	_cbox(st, Vector3(0, 0.3, 0), Vector3(1.22, 0.02, 0.8), Color(0.05, 0.06, 0.07))    # opening rim (seen when open)
	var m := st.commit()
	_cache["pod_body"] = m
	return m


## Lid, built around its hinge (back top edge): closed it sits flush on the body.
static func pod_lid_mesh() -> Mesh:
	if _cache.has("pod_lid"):
		return _cache["pod_lid"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_cbox(st, Vector3(0, 0.045, 0.43), Vector3(1.3, 0.09, 0.86), Color(0.78, 0.79, 0.81))
	_cbox(st, Vector3(0, 0.1, 0.43), Vector3(1.3, 0.02, 0.18), Color(0.88, 0.42, 0.1))
	_cbox(st, Vector3(0, 0.07, 0.86), Vector3(0.4, 0.05, 0.05), Color(0.14, 0.15, 0.17))
	var m := st.commit()
	_cache["pod_lid"] = m
	return m


static func pod_material() -> StandardMaterial3D:
	if _cache.has("pod_mat"):
		return _cache["pod_mat"]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.55
	m.metallic = 0.3
	_cache["pod_mat"] = m
	return m


## Beacon lamp: lit (unopened pod) or dark (emptied).
static func beacon_material(lit: bool) -> StandardMaterial3D:
	var key := "beacon_on" if lit else "beacon_off"
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 1.0, 0.55) if lit else Color(0.2, 0.22, 0.22)
	m.emission_enabled = lit
	m.emission = Color(0.3, 1.0, 0.55)
	m.emission_energy_multiplier = 4.0
	_cache[key] = m
	return m


static func sphere_mesh(r: float) -> Mesh:
	var key := "sphere_%.3f" % r
	if _cache.has(key):
		return _cache[key]
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 10
	sm.rings = 5
	_cache[key] = sm
	return sm


## Small crystal shard (ore pickup), ~0.13 m.
static func shard_mesh() -> Mesh:
	if _cache.has("shard"):
		return _cache["shard"]
	var sm := SphereMesh.new()
	sm.radius = 0.065
	sm.height = 0.16
	sm.radial_segments = 5
	sm.rings = 2
	_cache["shard"] = sm
	return sm


static func quad_mesh() -> Mesh:
	if _cache.has("quad"):
		return _cache["quad"]
	var q := QuadMesh.new()
	q.size = Vector2(1.0, 1.0)
	_cache["quad"] = q
	return q


static func rock_shader() -> Shader:
	if _cache.has("rock_sh"):
		return _cache["rock_sh"]
	var s := Shader.new()
	s.code = ROCK_SHADER
	_cache["rock_sh"] = s
	return s


static func halo_shader() -> Shader:
	if _cache.has("halo_sh"):
		return _cache["halo_sh"]
	var s := Shader.new()
	s.code = HALO_SHADER
	_cache["halo_sh"] = s
	return s


## Rock / scrap material. use_inst: for a single MeshInstance3D (vein from the instance uniform).
static func rock_material(col_a: Color, col_b: Color, scrap: bool, use_inst: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = rock_shader()
	m.set_shader_parameter("col_a", col_a)
	m.set_shader_parameter("col_b", col_b)
	m.set_shader_parameter("scrap", 1.0 if scrap else 0.0)
	m.set_shader_parameter("use_inst", use_inst)
	return m


static func halo_material(tint: Color, base_size: float, px: float, pulse_rate := 0.0, blink := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = halo_shader()
	m.render_priority = FX_PRIORITY
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("base_size", base_size)
	m.set_shader_parameter("px", px)
	m.set_shader_parameter("pulse_rate", pulse_rate)
	m.set_shader_parameter("blink", blink)
	return m


## Glowing ore shard material per ore id (cached).
static func shard_material(col: Color) -> StandardMaterial3D:
	var key := "shard_" + col.to_html()
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col.darkened(0.2)
	m.roughness = 0.25
	m.metallic = 0.3
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 1.8
	_cache[key] = m
	return m


## Soft round dot for particles.
static func soft_dot() -> Texture2D:
	if _cache.has("dot"):
		return _cache["dot"]
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 32
	t.height = 32
	_cache["dot"] = t
	return t
