extends RefCounted
## Samples chunk density grids on the GPU with a compute shader on a local RenderingDevice.
##
## The shader is an exact port of Godot's FastNoiseLite (OpenSimplex2S, FBm / Ridged fractals) and of
## TerrainGen._surf / _density / _cave, so CPU-side queries (surface_height, density_at,
## brush edits) agree with the GPU terrain to ~1e-4 m. Keep the GLSL below in sync with terrain_gen.gd.
## Several bodies share one pipeline: each chunk carries a body index, body parameters live in a
## storage buffer (see body_params()).
##
## A RenderingDevice must only be used from the thread that created it: create AND use one instance
## from the same (dedicated) thread (gpu_service.gd does this). init() returns false when compute is
## unavailable (headless, Compatibility renderer).

const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const BATCH := 32
const MAX_BODIES := 32        # bodies (and their re-registration on a scene reload)
const PARAMS := 24            # floats per body
const SAMPLES := TerrainGen.S * TerrainGen.S * TerrainGen.S
const GROUP := 64

var rd: RenderingDevice
var shader := RID()
var pipeline := RID()
var params_buf := RID()
var out_buf := RID()
var flags_buf := RID()
var bodies_buf := RID()
var uniform_set := RID()
var error := ""


## PARAMS floats describing a body for the shader (6 vec4, see main() in the GLSL). The last two
## carry the asteroid shape (TerrainGen a_warp / a_warp_freq / a_axes) and the hill frequency.
static func body_params(cfg: Dictionary) -> PackedFloat32Array:
	var r := float(cfg.get("radius", 150.0))
	var axes: Vector3 = cfg.get("a_axes", Vector3.ONE)
	return PackedFloat32Array([
		r, float(cfg.get("kind", 1)), float(cfg.get("seed", 1337)), float(cfg.get("cave_min_r", 1.0e6)),
		float(cfg.get("m_amp_cont", 0.0)), float(cfg.get("m_freq_cont", 1.0 / 300.0)),
		float(cfg.get("m_amp_hill", 0.0)), float(cfg.get("m_amp_mount", 0.0)),
		float(cfg.get("m_maria", 0.0)), float(cfg.get("m_terrace", 0.0)),
		float(cfg.get("m_crevasse", 0.0)), float(cfg.get("m_crater_amp", 0.0)),
		float(cfg.get("m_crater_cell", 50.0)), float(cfg.get("m_crater_density", 0.0)),
		float(cfg.get("m_volcano", 0.0)), float(cfg.get("m_pool_level", -1000.0)),
		float(cfg.get("cave_entrance", 0.0)), float(cfg.get("a_warp", 0.0)),
		float(cfg.get("a_warp_freq", 0.01)), 1.0 if cfg.has("a_axes") else 0.0,
		axes.x, axes.y, axes.z, float(cfg.get("m_freq_hill", 1.0 / 60.0))])


func init() -> bool:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		error = "no local RenderingDevice"
		return false
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = GLSL
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv == null or spirv.compile_error_compute != "":
		error = "compile: " + (spirv.compile_error_compute if spirv else "null")
		free_resources()
		return false
	shader = rd.shader_create_from_spirv(spirv, "planet_density")
	if not shader.is_valid():
		error = "shader_create_from_spirv failed"
		free_resources()
		return false
	pipeline = rd.compute_pipeline_create(shader)
	params_buf = rd.storage_buffer_create(BATCH * 16)
	out_buf = rd.storage_buffer_create(BATCH * SAMPLES * 4)
	flags_buf = rd.storage_buffer_create(BATCH * 8)
	bodies_buf = rd.storage_buffer_create(MAX_BODIES * PARAMS * 4)
	var uniforms: Array[RDUniform] = []
	var bufs := [params_buf, out_buf, flags_buf, bodies_buf]
	for i in bufs.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = i
		u.add_id(bufs[i])
		uniforms.append(u)
	uniform_set = rd.uniform_set_create(uniforms, shader, 0)
	if not pipeline.is_valid() or not uniform_set.is_valid():
		error = "pipeline / uniform set creation failed"
		free_resources()
		return false
	return true


## Uploads the parameters of all bodies (PARAMS floats each, index = position in the array).
func set_bodies(params: PackedFloat32Array) -> void:
	var n := mini(params.size(), MAX_BODIES * PARAMS)
	if n > 0:
		rd.buffer_update(bodies_buf, 0, n * 4, params.slice(0, n).to_byte_array())


## chunks: Array of Vector4i(origin.x, origin.y, origin.z, lod | body_index << 8), at most BATCH.
## Returns [PackedFloat32Array densities (SAMPLES per chunk), PackedInt32Array sign flags
## (bit0 some solid, bit1 some air), PackedFloat32Array min |density| per chunk].
func compute(chunks: Array, debug_mode := 0) -> Array:
	var n := mini(chunks.size(), BATCH)
	var pb := PackedInt32Array()
	pb.resize(n * 4)
	for i in n:
		var c: Vector4i = chunks[i]
		pb[i * 4] = c.x
		pb[i * 4 + 1] = c.y
		pb[i * 4 + 2] = c.z
		pb[i * 4 + 3] = c.w
	rd.buffer_update(params_buf, 0, n * 16, pb.to_byte_array())
	rd.buffer_clear(flags_buf, 0, BATCH * 8)
	var pc := PackedInt32Array([n, 0, debug_mode, 0]).to_byte_array()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, (n * SAMPLES + GROUP - 1) / GROUP, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var dens := rd.buffer_get_data(out_buf, 0, n * SAMPLES * 4).to_float32_array()
	var raw := rd.buffer_get_data(flags_buf, 0, n * 8).to_int32_array()
	var signs := PackedInt32Array()
	signs.resize(n)
	var bits := PackedInt32Array()
	bits.resize(n)
	for i in n:
		signs[i] = raw[i * 2]
		bits[i] = 0x7F800000 - raw[i * 2 + 1]
	return [dens, signs, bits.to_byte_array().to_float32_array()]


func free_resources() -> void:
	if rd == null:
		return
	for r in [uniform_set, bodies_buf, flags_buf, out_buf, params_buf, pipeline, shader]:
		if r.is_valid():
			rd.free_rid(r)
	uniform_set = RID()
	shader = RID()
	pipeline = RID()
	rd.free()
	rd = null


## Compares GPU chunks of one (already uploaded) body with its CPU density function.
## Returns the worst absolute difference near the surface (< 0.05 means the GPU path is usable).
func self_test(body_index: int, gen: TerrainGen) -> float:
	var dirs := [Vector3(0.55, 0.42, 0.72), Vector3(-0.3, 0.9, 0.1), Vector3(0.1, -0.2, -0.95), Vector3(0.8, 0.05, -0.5)]
	var chunks := []
	for d: Vector3 in dirs:
		var dir := d.normalized()
		var p := dir * (gen.radius + gen.surface_height(dir) - 6.0)
		var o := Vector3i(p.floor()) - Vector3i(8, 8, 8)
		chunks.append(Vector4i(o.x, o.y, o.z, 0 | (body_index << 8)))
		chunks.append(Vector4i(o.x - 32, o.y - 32, o.z - 32, 2 | (body_index << 8)))
	var t0 := Time.get_ticks_usec()
	var res := compute(chunks)
	var gpu_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var dens: PackedFloat32Array = res[0]
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for ci in chunks.size():
		var c: Vector4i = chunks[ci]
		var step := 1 << (c.w & 255)
		gen.no_caves = (c.w & 255) >= 2
		for k in 60:
			var si := rng.randi_range(0, SAMPLES - 1)
			var x := si % TerrainGen.S
			var y := (si / TerrainGen.S) % TerrainGen.S
			var z := si / (TerrainGen.S * TerrainGen.S)
			var cpu := gen.density_base(Vector3(c.x + x * step, c.y + y * step, c.z + z * step))
			var g := dens[ci * SAMPLES + si]
			if absf(cpu) < 30.0:
				worst = maxf(worst, absf(cpu - g))
	print("GPU density: body %d self-test %d chunks in %.2f ms, max |gpu - cpu| = %.5f" % [
			body_index, chunks.size(), gpu_ms, worst])
	return worst


const GLSL := """
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Params { ivec4 chunks[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer Out { float dens[]; };
layout(set = 0, binding = 2, std430) restrict buffer Flags { uint flags[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Bodies { vec4 bodies[]; };
layout(push_constant, std430) uniform PC { int count; int seed; int pad0; int pad1; } pc;

const int S = 18;
const int SAMPLES = S * S * S;
// Per-invocation body parameters (see bodies.gd / GpuDensity.body_params).
float RADIUS;
float CAVE_MIN_R;
int KIND;
vec4 BP1;
vec4 BP2;
vec4 BP3;
vec4 BP4;        // (cave_entrance, asteroid warp m, warp frequency, asteroid shape on/off)
vec4 BP5;        // (asteroid semi-axes / radius, hill frequency)
bool NO_CAVES;   // coarse chunks (LOD >= 2) sample without caves (see TerrainGen.no_caves)
const vec3 WARP_O1 = vec3(131.7, -57.3, 89.1);    // TerrainGen.WARP_O1 / WARP_O2
const vec3 WARP_O2 = vec3(-73.9, 112.6, -41.3);
const float PI = 3.14159265358979;
const float CAVE_MAX_DEPTH = 80.0;

const int PRIME_X = 501125321;
const int PRIME_Y = 1136930381;
const int PRIME_Z = 1720413743;
const int PRIME_X2 = 1002250642;
const int PRIME_Y2 = -2021106534;
const int PRIME_Z2 = -854139810;

const float GRAD3[256] = float[256](
	0, 1, 1, 0,  0,-1, 1, 0,  0, 1,-1, 0,  0,-1,-1, 0,
	1, 0, 1, 0, -1, 0, 1, 0,  1, 0,-1, 0, -1, 0,-1, 0,
	1, 1, 0, 0, -1, 1, 0, 0,  1,-1, 0, 0, -1,-1, 0, 0,
	0, 1, 1, 0,  0,-1, 1, 0,  0, 1,-1, 0,  0,-1,-1, 0,
	1, 0, 1, 0, -1, 0, 1, 0,  1, 0,-1, 0, -1, 0,-1, 0,
	1, 1, 0, 0, -1, 1, 0, 0,  1,-1, 0, 0, -1,-1, 0, 0,
	0, 1, 1, 0,  0,-1, 1, 0,  0, 1,-1, 0,  0,-1,-1, 0,
	1, 0, 1, 0, -1, 0, 1, 0,  1, 0,-1, 0, -1, 0,-1, 0,
	1, 1, 0, 0, -1, 1, 0, 0,  1,-1, 0, 0, -1,-1, 0, 0,
	0, 1, 1, 0,  0,-1, 1, 0,  0, 1,-1, 0,  0,-1,-1, 0,
	1, 0, 1, 0, -1, 0, 1, 0,  1, 0,-1, 0, -1, 0,-1, 0,
	1, 1, 0, 0, -1, 1, 0, 0,  1,-1, 0, 0, -1,-1, 0, 0,
	0, 1, 1, 0,  0,-1, 1, 0,  0, 1,-1, 0,  0,-1,-1, 0,
	1, 0, 1, 0, -1, 0, 1, 0,  1, 0,-1, 0, -1, 0,-1, 0,
	1, 1, 0, 0, -1, 1, 0, 0,  1,-1, 0, 0, -1,-1, 0, 0,
	1, 1, 0, 0,  0,-1, 1, 0, -1, 1, 0, 0,  0,-1,-1, 0
);

int fast_floor(float f) { return f >= 0.0 ? int(f) : int(f) - 1; }

float grad_coord(int seed, int xp, int yp, int zp, float xd, float yd, float zd) {
	int h = (seed ^ xp ^ yp ^ zp) * 0x27d4eb2d;
	h ^= h >> 15;
	h &= 63 << 2;
	return xd * GRAD3[h] + yd * GRAD3[h | 1] + zd * GRAD3[h | 2];
}

float a4(float a) { return (a * a) * (a * a); }

// FastNoiseLite SingleOpenSimplex2S (3D), input already transformed.
float os2s(int seed, vec3 p) {
	int i = fast_floor(p.x);
	int j = fast_floor(p.y);
	int k = fast_floor(p.z);
	float xi = p.x - float(i);
	float yi = p.y - float(j);
	float zi = p.z - float(k);
	i *= PRIME_X;
	j *= PRIME_Y;
	k *= PRIME_Z;
	int seed2 = seed + 1293373;
	int xN = int(-0.5 - xi);
	int yN = int(-0.5 - yi);
	int zN = int(-0.5 - zi);
	float x0 = xi + float(xN);
	float y0 = yi + float(yN);
	float z0 = zi + float(zN);
	float a0 = 0.75 - x0 * x0 - y0 * y0 - z0 * z0;
	float value = a4(a0) * grad_coord(seed, i + (xN & PRIME_X), j + (yN & PRIME_Y), k + (zN & PRIME_Z), x0, y0, z0);
	float x1 = xi - 0.5;
	float y1 = yi - 0.5;
	float z1 = zi - 0.5;
	float a1 = 0.75 - x1 * x1 - y1 * y1 - z1 * z1;
	value += a4(a1) * grad_coord(seed2, i + PRIME_X, j + PRIME_Y, k + PRIME_Z, x1, y1, z1);
	float xAF0 = float((xN | 1) << 1) * x1;
	float yAF0 = float((yN | 1) << 1) * y1;
	float zAF0 = float((zN | 1) << 1) * z1;
	float xAF1 = float(-2 - (xN << 2)) * x1 - 1.0;
	float yAF1 = float(-2 - (yN << 2)) * y1 - 1.0;
	float zAF1 = float(-2 - (zN << 2)) * z1 - 1.0;

	bool skip5 = false;
	float a2 = xAF0 + a0;
	if (a2 > 0.0) {
		value += a4(a2) * grad_coord(seed, i + (~xN & PRIME_X), j + (yN & PRIME_Y), k + (zN & PRIME_Z),
				x0 - float(xN | 1), y0, z0);
	} else {
		float a3 = yAF0 + zAF0 + a0;
		if (a3 > 0.0) {
			value += a4(a3) * grad_coord(seed, i + (xN & PRIME_X), j + (~yN & PRIME_Y), k + (~zN & PRIME_Z),
					x0, y0 - float(yN | 1), z0 - float(zN | 1));
		}
		float a4v = xAF1 + a1;
		if (a4v > 0.0) {
			value += a4(a4v) * grad_coord(seed2, i + (xN & PRIME_X2), j + PRIME_Y, k + PRIME_Z,
					float(xN | 1) + x1, y1, z1);
			skip5 = true;
		}
	}

	bool skip9 = false;
	float a6 = yAF0 + a0;
	if (a6 > 0.0) {
		value += a4(a6) * grad_coord(seed, i + (xN & PRIME_X), j + (~yN & PRIME_Y), k + (zN & PRIME_Z),
				x0, y0 - float(yN | 1), z0);
	} else {
		float a7 = xAF0 + zAF0 + a0;
		if (a7 > 0.0) {
			value += a4(a7) * grad_coord(seed, i + (~xN & PRIME_X), j + (yN & PRIME_Y), k + (~zN & PRIME_Z),
					x0 - float(xN | 1), y0, z0 - float(zN | 1));
		}
		float a8 = yAF1 + a1;
		if (a8 > 0.0) {
			value += a4(a8) * grad_coord(seed2, i + PRIME_X, j + (yN & PRIME_Y2), k + PRIME_Z,
					x1, float(yN | 1) + y1, z1);
			skip9 = true;
		}
	}

	bool skipD = false;
	float aA = zAF0 + a0;
	if (aA > 0.0) {
		value += a4(aA) * grad_coord(seed, i + (xN & PRIME_X), j + (yN & PRIME_Y), k + (~zN & PRIME_Z),
				x0, y0, z0 - float(zN | 1));
	} else {
		float aB = xAF0 + yAF0 + a0;
		if (aB > 0.0) {
			value += a4(aB) * grad_coord(seed, i + (~xN & PRIME_X), j + (~yN & PRIME_Y), k + (zN & PRIME_Z),
					x0 - float(xN | 1), y0 - float(yN | 1), z0);
		}
		float aC = zAF1 + a1;
		if (aC > 0.0) {
			value += a4(aC) * grad_coord(seed2, i + PRIME_X, j + PRIME_Y, k + (zN & PRIME_Z2),
					x1, y1, float(zN | 1) + z1);
			skipD = true;
		}
	}

	if (!skip5) {
		float a5 = yAF1 + zAF1 + a1;
		if (a5 > 0.0) {
			value += a4(a5) * grad_coord(seed2, i + PRIME_X, j + (yN & PRIME_Y2), k + (zN & PRIME_Z2),
					x1, float(yN | 1) + y1, float(zN | 1) + z1);
		}
	}
	if (!skip9) {
		float a9 = xAF1 + zAF1 + a1;
		if (a9 > 0.0) {
			value += a4(a9) * grad_coord(seed2, i + (xN & PRIME_X2), j + PRIME_Y, k + (zN & PRIME_Z2),
					float(xN | 1) + x1, y1, float(zN | 1) + z1);
		}
	}
	if (!skipD) {
		float aD = xAF1 + yAF1 + a1;
		if (aD > 0.0) {
			value += a4(aD) * grad_coord(seed2, i + (xN & PRIME_X2), j + (yN & PRIME_Y2), k + PRIME_Z,
					float(xN | 1) + x1, float(yN | 1) + y1, z1);
		}
	}
	return value * 9.046026385208288;
}

vec3 fnl_transform(vec3 p, float freq) {
	p *= freq;
	float r = (p.x + p.y + p.z) * (2.0 / 3.0);
	return vec3(r) - p;
}

float single(int seed, vec3 p, float freq) {
	return os2s(seed, fnl_transform(p, freq));
}

float fbm(int seed, vec3 p, float freq, int octaves) {
	vec3 q = fnl_transform(p, freq);
	float amp = 0.5;
	float amp_fractal = 1.0;
	for (int i = 1; i < octaves; i++) {
		amp_fractal += amp;
		amp *= 0.5;
	}
	amp = 1.0 / amp_fractal;
	float sum = 0.0;
	for (int i = 0; i < octaves; i++) {
		sum += os2s(seed + i, q) * amp;
		q *= 2.0;
		amp *= 0.5;
	}
	return sum;
}

float ridged(int seed, vec3 p, float freq, int octaves) {
	vec3 q = fnl_transform(p, freq);
	float amp = 0.5;
	float amp_fractal = 1.0;
	for (int i = 1; i < octaves; i++) {
		amp_fractal += amp;
		amp *= 0.5;
	}
	amp = 1.0 / amp_fractal;
	float sum = 0.0;
	for (int i = 0; i < octaves; i++) {
		float n = abs(os2s(seed + i, q));
		sum += (n * -2.0 + 1.0) * amp;
		q *= 2.0;
		amp *= 0.5;
	}
	return sum;
}

float ss(float a, float b, float x) {
	float t = clamp((x - a) / (b - a), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// ---------------------------------------------------------------------------------------------
// Moons: mirror of TerrainGen._surf_moon / _craters / _volcanoes / _ihash.
uint ihash(int x, int y, int z, int s) {
	uint h = (uint(x) * 1597334677u) ^ (uint(y) * 1812015801u) ^ (uint(z) * 1798796415u) ^ (uint(s) * 1979697957u);
	h = (h ^ (h >> 15u)) * 1274126177u;
	h = (h ^ (h >> 13u)) * 1103515245u;
	return h ^ (h >> 16u);
}

float craters(vec3 p, int sd) {
	vec3 b = floor(p - vec3(0.5));
	int bx = int(b.x);
	int by = int(b.y);
	int bz = int(b.z);
	float off = 0.0;
	for (int k = 0; k < 8; k++) {
		int cx = bx + (k & 1);
		int cy = by + ((k >> 1) & 1);
		int cz = bz + ((k >> 2) & 1);
		uint hs = ihash(cx, cy, cz, sd);
		if (float(hs & 255u) > BP3.y * 255.0 + 0.25) {
			continue;
		}
		vec3 center = vec3(float(cx) + 0.25 + 0.5 * float((hs >> 8u) & 255u) / 255.0,
				float(cy) + 0.25 + 0.5 * float((hs >> 16u) & 255u) / 255.0,
				float(cz) + 0.25 + 0.5 * float((hs >> 24u) & 255u) / 255.0);
		float rad = 0.18 + 0.3 * float((hs >> 4u) & 255u) / 255.0;
		float d = distance(p, center) / rad;
		if (d > 1.7) {
			continue;
		}
		float bowl = d < 1.0 ? max(d * d - 1.0, -0.55) : 0.0;
		float rim = 0.32 * exp(-(d - 1.0) * (d - 1.0) * 14.0);
		off += (bowl + rim) * rad;
	}
	return off;
}

float volcanoes(vec3 p, int sd) {
	vec3 b = floor(p - vec3(0.5));
	int bx = int(b.x);
	int by = int(b.y);
	int bz = int(b.z);
	float off = 0.0;
	for (int k = 0; k < 8; k++) {
		int cx = bx + (k & 1);
		int cy = by + ((k >> 1) & 1);
		int cz = bz + ((k >> 2) & 1);
		uint hs = ihash(cx, cy, cz, sd + 7);
		if (float(hs & 255u) > 0.35 * 255.0 + 0.25) {
			continue;
		}
		vec3 center = vec3(float(cx) + 0.25 + 0.5 * float((hs >> 8u) & 255u) / 255.0,
				float(cy) + 0.25 + 0.5 * float((hs >> 16u) & 255u) / 255.0,
				float(cz) + 0.25 + 0.5 * float((hs >> 24u) & 255u) / 255.0);
		float d = distance(p, center) / 0.45;
		if (d >= 1.0) {
			continue;
		}
		float cone = (1.0 - d) * (1.0 - d) * 0.6 + (1.0 - d) * 0.4;
		off += cone - ss(0.22, 0.08, d) * 0.45;
	}
	return off;
}

vec4 surf_moon(vec3 dir, int sd) {
	vec3 q = dir * RADIUS;
	vec3 qn = q;
	if (BP4.y > 0.0) {
		qn = q + vec3(fbm(sd + 15, q, BP4.z, 2), fbm(sd + 15, q + WARP_O1, BP4.z, 2),
				fbm(sd + 15, q + WARP_O2, BP4.z, 2)) * BP4.y;
	}
	float c = fbm(sd, qn, BP1.y, 4);
	float nh = fbm(sd + 2, qn, BP5.w, 3);
	float l = single(sd + 3, q, 1.0 / 90.0);
	float h = c * BP1.x + nh * BP1.z;
	if (BP4.w > 0.0) {
		vec3 e = dir / BP5.xyz;
		h += RADIUS * (1.0 / sqrt(max(dot(e, e), 0.01)) - 1.0);
	}
	if (BP1.w > 0.0) {
		float mt = ridged(sd + 1, q, 1.0 / 150.0, 4) * 0.5 + 0.5;
		h += mt * mt * BP1.w * ss(-0.05, 0.3, c);
	}
	if (BP2.x > 0.0) {
		float mare = ss(-0.05, -0.25, c) * BP2.x;
		h = mix(h, -BP1.x * 0.25 + nh * 0.6, mare);
	}
	if (BP2.y > 0.0) {
		float k = h / BP2.y;
		float fk = floor(k);
		h = mix(h, (fk + ss(0.55, 0.9, k - fk)) * BP2.y, 0.85);
	}
	float crack = 0.0;
	if (BP2.z > 0.0) {
		crack = 1.0 - ss(0.0, 0.045, abs(l));
		h -= crack * BP2.z;
	}
	if (BP2.w > 0.0) {
		h += craters(q / BP3.x, sd) * BP2.w * BP3.x;
	}
	if (BP3.z > 0.0) {
		h += volcanoes(q / (BP3.x * 4.0), sd) * BP3.z;
	}
	float pool = 0.0;
	if (h < BP3.w) {
		pool = clamp((BP3.w - h) * 2.0, 0.0, 1.0);
		h = BP3.w - (BP3.w - h) * 0.04;
	}
	return vec4(h, pool, crack, l);
}

// The planets use the surface generator above (TerrainGen._surf).
vec4 surf(vec3 dir, int sd) {
	return surf_moon(dir, sd);
}

float cave(vec3 p, float r, float depth, float l, int sd) {
	float top = 4.0 - 8.0 * BP4.x * ss(-0.4, -0.52, l);
	if (depth < top) {
		return -100.0;
	}
	vec3 up = p / r;
	vec3 sq = p + up * ((r - RADIUS) * 1.2);
	float n1 = single(sd + 9, sq, 1.0 / 42.0);
	float n2 = single(sd + 10, sq, 1.0 / 42.0);
	float cv = (0.17 - max(abs(n1), abs(n2))) * 16.0;
	if (depth > 20.0) {
		float n3 = single(sd + 11, p + up * ((r - RADIUS) * 1.8), 1.0 / 75.0);
		cv = max(cv, (n3 - 0.55 - (1.0 - ss(20.0, 30.0, depth)) * 0.6) * 45.0);
	}
	float f = ss(top, top + 5.0, depth) * ss(CAVE_MIN_R, CAVE_MIN_R + 6.0, r)
			* (1.0 - ss(CAVE_MAX_DEPTH - 12.0, CAVE_MAX_DEPTH, depth));
	return cv - (1.0 - f) * 16.0;
}

float density(vec3 p, int sd) {
	if (KIND == 9) {
		// Debug (tests/test_gpu_noise.gd): raw single-octave noise, seed BP1.x, frequency BP1.y.
		return single(int(BP1.x), p, BP1.y);
	}
	float r = length(p);
	if (r < 1.0) {
		return -RADIUS;
	}
	vec4 s = surf(p / r, sd);
	float d = r - RADIUS - s.x;
	if (d > -8.0 && d < 8.0) {
		d += fbm(sd + 4, p, 1.0 / 16.0, 2) * 1.3;
	}
	if (!NO_CAVES && d < 4.0 && d > -CAVE_MAX_DEPTH && r > CAVE_MIN_R) {
		d = max(d, cave(p, r, -d, s.w, sd));
	}
	return d;
}

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint ci = gid / uint(SAMPLES);
	if (ci >= uint(pc.count)) {
		return;
	}
	int si = int(gid % uint(SAMPLES));
	ivec4 ch = chunks[ci];
	int bi = ch.w >> 8;
	int step = 1 << (ch.w & 255);
	NO_CAVES = (ch.w & 255) >= 2;
	vec4 b0 = bodies[bi * 6];
	RADIUS = b0.x;
	KIND = int(b0.y);
	int sd = int(b0.z);
	CAVE_MIN_R = b0.w;
	BP1 = bodies[bi * 6 + 1];
	BP2 = bodies[bi * 6 + 2];
	BP3 = bodies[bi * 6 + 3];
	BP4 = bodies[bi * 6 + 4];
	BP5 = bodies[bi * 6 + 5];
	int x = si % S;
	int y = (si / S) % S;
	int z = si / (S * S);
	vec3 p = vec3(float(ch.x + x * step), float(ch.y + y * step), float(ch.z + z * step));
	float d = density(p, sd);
	if (pc.pad0 != 0) {
		// Debug outputs for tests: 1 = surface height, 2 = cavern noise, 3 = r.
		float r = length(p);
		vec4 s = surf(p / r, sd);
		vec3 up = p / r;
		d = pc.pad0 == 1 ? s.x : (pc.pad0 == 2 ? single(sd + 11, p + up * ((r - RADIUS) * 1.8), 1.0 / 75.0) : r);
		if (pc.pad0 == 4) {
			d = craters(up * RADIUS / BP3.x, sd);
		} else if (pc.pad0 >= 100) {
			d = float(ihash(int(p.x), int(p.y), int(p.z), pc.pad0 - 100) & 0xFFFFFFu);
		}
	}
	dens[gid] = d;
	atomicOr(flags[ci * 2u], d < 0.0 ? 1u : 2u);
	// min |d| per chunk, stored inverted so that a zero-cleared buffer means "none yet".
	atomicMax(flags[ci * 2u + 1u], 0x7F800000u - floatBitsToUint(min(abs(d), 1.0e30)));
}
"""
