extends RefCounted
## Shared look and sound of the ultimates (scripts/war/heroes/): shaders, the ground ring marker, the
## sky beam and a few synthesized cues. Static; the sounds are built once on a worker thread
## (prewarm(), called by heroes.gd) and cached.
##   HeroFx.ring(parent, col, radius) -> MeshInstance3D   flat ring on the ground (place() it)
##   HeroFx.place(node, pos, up)                          orient a node to the ground at pos
##   HeroFx.beam(parent, col, height) -> MeshInstance3D   thin vertical light column
##   HeroFx.shell_material(col) -> ShaderMaterial         the dome's hex shell (strength, flash, appear)
##   HeroFx.cloak_material(col) -> ShaderMaterial         refraction shimmer (material_overlay)
##   HeroFx.lens_material() -> ShaderMaterial             the gravity well's bent light
##   HeroFx.sound(name) -> AudioStream                    "ready", "sweep", "hum", "rumble", "shimmer",
##                                                        "suck", "warn", "deny" (null until built)
##   HeroFx.play3d(parent, name, pos, db, unit, pitch) / HeroFx.play2d(name, db, pitch)

const RATE := 22050

const RING_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec4 col : source_color = vec4(1.0, 0.3, 0.2, 1.0);
uniform float k = 1.0;           // overall strength
uniform float fill = 0.12;       // inner disc
uniform float danger = 0.0;      // 1: rotating hazard ticks
void fragment() {
	vec2 p = UV - 0.5;
	float r = length(p) * 2.0;
	float ring = smoothstep(0.86, 0.93, r) * (1.0 - smoothstep(0.96, 1.0, r));
	float inner = (1.0 - smoothstep(0.0, 0.95, r)) * fill;
	float a = atan(p.y, p.x);
	float ticks = step(0.5, fract(a * 6.0 / 6.2832 + TIME * 0.25)) * smoothstep(0.7, 0.75, r) * (1.0 - smoothstep(0.82, 0.86, r));
	float pulse = 0.75 + 0.25 * sin(TIME * 7.0);
	float v = (ring * 1.2 + inner + ticks * danger * 0.9) * pulse * k;
	ALBEDO = col.rgb * v;
	ALPHA = 1.0;
}
"""

const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec4 col : source_color = vec4(1.0, 0.3, 0.2, 1.0);
uniform float k = 1.0;
void fragment() {
	float edge = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 0.6);
	float fade = 1.0 - UV.y;
	float flick = 0.8 + 0.2 * sin(TIME * 23.0 + UV.y * 30.0);
	ALBEDO = col.rgb * (1.0 - edge) * fade * flick * k * 1.4;
	ALPHA = 1.0;
}
"""

const SHELL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec4 col : source_color = vec4(0.5, 0.7, 1.0, 1.0);
uniform float strength = 1.0;
uniform float flash = 0.0;
uniform float appear = 1.0;      // 0..1: the deploy sweep (bottom to top)
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
	float fres = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 2.2);
	vec2 uv = vec2(atan(d.z, d.x) * 4.0, acos(clamp(d.y, -1.0, 1.0)) * 7.0);
	float edge = 1.0 - smoothstep(0.0, 0.08, hexd(uv));
	float scan = 0.55 + 0.45 * sin(d.y * 10.0 - TIME * 2.2);
	float front = smoothstep(appear * 2.2 - 1.15, appear * 2.2 - 1.0, d.y);
	float sweep = (1.0 - front) * smoothstep(appear * 2.2 - 1.35, appear * 2.2 - 1.05, d.y) * (1.0 - smoothstep(0.95, 1.0, appear));
	float vis = 1.0 - front;
	float kk = (0.22 * fres + 0.2 * edge * scan) * strength * vis + flash * (0.4 * fres + 0.5 * edge) * vis + sweep * 0.8;
	ALBEDO = min(col.rgb * kk * 1.6, vec3(1.2));
	ALPHA = 1.0;
}
"""

const CLOAK_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, shadows_disabled, fog_disabled;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.45, 1.0, 0.75, 1.0);
uniform float k = 1.0;           // 0..1 the cloak's strength (fades in / out)
uniform float rim = 0.35;
void fragment() {
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	vec2 wob = vec2(sin(TIME * 7.0 + SCREEN_UV.y * 70.0), cos(TIME * 5.3 + SCREEN_UV.x * 55.0)) * 0.0035;
	vec2 off = NORMAL.xy * (0.012 + 0.02 * fres) * k + wob * k;
	vec3 bg = textureLod(screen_tex, SCREEN_UV + off, 0.0).rgb;
	ALBEDO = bg + tint.rgb * fres * rim * k;
	ALPHA = clamp(k, 0.0, 1.0);
}
"""

const LENS_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, shadows_disabled, fog_disabled;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.8, 0.5, 1.0, 1.0);
uniform float k = 1.0;
void fragment() {
	float c = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - c, 2.5);
	vec2 off = -NORMAL.xy * 0.06 * c * k;
	vec3 bg = textureLod(screen_tex, SCREEN_UV + off, 0.0).rgb;
	float core = smoothstep(0.82, 0.97, c);
	ALBEDO = mix(bg * (1.0 - 0.5 * c * k), vec3(0.0), core * k) + tint.rgb * fres * 0.9 * k;
	ALPHA = clamp(k, 0.0, 1.0);
}
"""

static var _shaders := {}
static var _snd := {}
static var _task := -1
static var _mutex := Mutex.new()
static var _pending := {}


static func _shader(key: String, code: String) -> Shader:
	var s = _shaders.get(key)
	if s == null:
		s = Shader.new()
		(s as Shader).code = code
		_shaders[key] = s
	return s


static func _mat(key: String, code: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader(key, code)
	return m


static func ring(parent: Node, col: Color, radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := PlaneMesh.new()
	q.size = Vector2(radius * 2.0, radius * 2.0)
	mi.mesh = q
	var m := _mat("ring", RING_SHADER)
	m.set_shader_parameter("col", col)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 4.0
	parent.add_child(mi)
	return mi


## Puts `node` at pos with its +Y along up (the ring sits a little above the ground).
static func place(node: Node3D, pos: Vector3, up: Vector3, lift := 0.25) -> void:
	if node == null or not node.is_inside_tree():
		return
	var u := up.normalized() if up.length_squared() > 1e-6 else Vector3.UP
	var x := u.cross(Vector3.FORWARD if absf(u.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(u).normalized()
	node.global_transform = Transform3D(Basis(x, u, z), pos + u * lift)


static func beam(parent: Node, col: Color, height: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.18
	c.bottom_radius = 0.35
	c.height = height
	c.radial_segments = 12
	c.rings = 1
	mi.mesh = c
	var m := _mat("beam", BEAM_SHADER)
	m.set_shader_parameter("col", col)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(0, height * 0.5, 0)
	parent.add_child(mi)
	return mi


static func shell_material(col: Color) -> ShaderMaterial:
	var m := _mat("shell", SHELL_SHADER)
	m.set_shader_parameter("col", col)
	return m


static func cloak_material(col: Color) -> ShaderMaterial:
	var m := _mat("cloak", CLOAK_SHADER)
	m.set_shader_parameter("tint", col)
	return m


static func lens_material() -> ShaderMaterial:
	return _mat("lens", LENS_SHADER)


## Drops the cached shaders and sounds (heroes.gd at the match's end; rebuilt on demand).
static func clear_cache() -> void:
	_shaders.clear()
	if _task < 0:
		_snd.clear()
		_pending = {}


## Every shader of the ultimates (tests: compile them all).
static func shader_codes() -> Dictionary:
	return {"ring": RING_SHADER, "beam": BEAM_SHADER, "shell": SHELL_SHADER, "cloak": CLOAK_SHADER, "lens": LENS_SHADER}


# --- Sounds ---------------------------------------------------------------------------------------

static func prewarm() -> void:
	if _task >= 0 or not _snd.is_empty():
		return
	_task = WorkerThreadPool.add_task(_build, false, "hero_audio")


static func sound(nm: String) -> AudioStream:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_mutex.lock()
		_snd = _pending
		_mutex.unlock()
	return _snd.get(nm)


static func play3d(parent: Node, nm: String, pos: Vector3, db := 0.0, unit := 12.0, pitch := 1.0) -> AudioStreamPlayer3D:
	var st := sound(nm)
	if st == null or parent == null or not parent.is_inside_tree():
		return null
	var a := AudioStreamPlayer3D.new()
	a.stream = st
	a.unit_size = unit
	a.max_distance = unit * 25.0
	a.volume_db = db
	a.pitch_scale = pitch
	parent.add_child(a)
	a.global_position = pos
	a.play()
	a.finished.connect(a.queue_free)
	return a


static func play2d(nm: String, db := 0.0, pitch := 1.0) -> void:
	var st := sound(nm)
	var tree := Engine.get_main_loop() as SceneTree
	if st == null or tree == null or tree.root == null:
		return
	var a := AudioStreamPlayer.new()
	a.stream = st
	a.volume_db = db
	a.pitch_scale = pitch
	tree.root.add_child(a)
	a.play()
	a.finished.connect(a.queue_free)


static func _build() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7741
	var out := {}
	out["ready"] = _wav(_chime([660.0, 880.0, 1320.0], 0.09, 0.9), false)
	out["sweep"] = _wav(_sweep(rng), false)
	out["hum"] = _wav(_hum(2.0, 110.0), true)
	out["rumble"] = _wav(_rumble(rng, 2.6), false)
	out["shimmer"] = _wav(_shimmer(rng, 0.9), false)
	out["suck"] = _wav(_suck(rng, 2.0), true)
	out["warn"] = _wav(_siren(1.1), false)
	out["deny"] = _wav(_chime([330.0, 247.0], 0.08, 0.35), false)
	_mutex.lock()
	_pending = out
	_mutex.unlock()


static func _wav(s: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32000.0))
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


## Rising notes, each `step` s apart, ringing out over `dur` s.
static func _chime(notes: Array, step: float, dur: float) -> PackedFloat32Array:
	var n := int((dur + step * notes.size()) * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	for j in notes.size():
		var f := float(notes[j])
		var o := int(step * j * RATE)
		for i in range(o, n):
			var t := float(i - o) / RATE
			var e := exp(-t * 5.0) * minf(t * 300.0, 1.0)
			s[i] += (sin(TAU * f * t) + 0.3 * sin(TAU * f * 2.01 * t)) * e * 0.22
	return s


## A radar sweep: a falling tone with a ping and a long tail.
static func _sweep(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 1.6
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := lerpf(1900.0, 420.0, minf(t / 0.9, 1.0))
		ph += TAU * f / RATE
		var e := exp(-t * 2.4) * minf(t * 80.0, 1.0)
		s[i] = (sin(ph) * 0.35 + sin(ph * 0.5) * 0.15) * e + rng.randf_range(-1, 1) * 0.03 * exp(-t * 6.0)
	return s


## A low electric hum (loop: whole cycles).
static func _hum(dur: float, f: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		s[i] = (sin(TAU * f * t) * 0.3 + sin(TAU * f * 2.0 * t) * 0.15 + sin(TAU * f * 3.0 * t) * 0.07) \
				* (0.85 + 0.15 * sin(TAU * 2.0 * t))
	return s


## A deep ground rumble with cracks.
static func _rumble(rng: RandomNumberGenerator, dur: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var t := float(i) / RATE
		lp += (rng.randf_range(-1, 1) - lp) * 0.02
		lp2 += (lp - lp2) * 0.05
		var e := minf(t * 12.0, 1.0) * exp(-t * 1.3)
		var crack := rng.randf_range(-1, 1) * 0.35 if rng.randf() < 0.002 * exp(-t) else 0.0
		s[i] = (lp2 * 9.0 + sin(TAU * 38.0 * t) * 0.35 * exp(-t * 2.0)) * e + crack
	return s


## A glassy shimmer whoosh (cloak on / off).
static func _shimmer(rng: RandomNumberGenerator, dur: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var hp := 0.0
	var prev := 0.0
	for i in n:
		var t := float(i) / RATE
		var w := rng.randf_range(-1, 1)
		hp = 0.92 * (hp + w - prev)
		prev = w
		var e := sin(PI * minf(t / dur, 1.0))
		s[i] = hp * 0.12 * e + sin(TAU * (2400.0 + 900.0 * sin(t * 9.0)) * t) * 0.05 * e
	return s


## A swirling inward rush (loop).
static func _suck(rng: RandomNumberGenerator, dur: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		lp += (rng.randf_range(-1, 1) - lp) * (0.08 + 0.06 * sin(TAU * 1.0 * t))
		s[i] = lp * 0.9 + sin(TAU * 55.0 * t) * 0.25 + sin(TAU * 82.5 * t) * 0.12
	return s


## Two-tone warning.
static func _siren(dur: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := 880.0 if fmod(t, 0.36) < 0.18 else 660.0
		ph += TAU * f / RATE
		var e := minf(t * 60.0, 1.0) * minf((dur - t) * 8.0, 1.0)
		s[i] = (sin(ph) * 0.25 + (1.0 if sin(ph) > 0.0 else -1.0) * 0.05) * e
	return s
