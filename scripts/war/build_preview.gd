extends Node
## Build-menu visuals shared by the İnşa Aracı (scripts/war/build_tool.gd) and its card bar
## (scripts/war/build_menu.gd):
##   BuildPreview.model(parent, entry) -> Node3D
##       the REAL structure model (cannon.gd / flak.gd / buster.gd build it in _ready; the skiff
##       from skiff_build.gd's meshes) as an inert prop: processing off, out of every group
##       (no damage, no AI / flak / build checks), collisions off, lights and particles hidden,
##       never registered by the multiplayer sync (meta "net_id" -1). Barrel posed at a nice angle.
##   BuildPreview.hologram(root, material)  every surface drawn with the hologram material
##   BuildPreview.holo_material() -> ShaderMaterial  a 3-pass chain (HOLO_FILL); set its uniforms
##       with holo_set(m, name, value) (col, origin, up, height, flash, appear, alert, vis)
##   BuildPreview.wireframe(root)  barycentric mesh copies so the hologram draws its crease lines
##   BuildPreview.ring_texture() -> Texture2D  footprint ring for the ground Decal
##   BuildPreview.request_thumbs(tree, entries)  renders each entry's model ONCE into a transparent
##       SubViewport (own world, studio light), copies it to BuildPreview.thumbs[id] and frees it;
##       the cache lives for the whole run. One model per couple of frames, in the background.

const SKIFF_BUILD := "res://scripts/craft/skiff_build.gd"
const THUMB_SIZE := Vector2i(320, 224)

## Hologram (the build ghost): three passes chained with next_pass, drawn in this order by
## render_priority (holo_material()):
##   HOLO_FILL   (3) the back faces: a soft inner glow, so the ghost reads as a volume
##   HOLO_DEPTH  (4) writes the ghost's depth only (alpha 0): of the shell below, only the surface
##               nearest the eye draws, so the hologram is a clean translucent solid instead of a
##               tangle of every inner face
##   HOLO_SHELL  (5) the look: a layered fresnel rim whose channels fall off at different rates (a
##               faint chromatic edge), crisp edge lines (barycentrics in COLOR from wire_mesh(); a
##               mesh without them simply has none), drifting scanlines with a fine interference,
##               a bright build slice rising through it with a trail, a faint flicker. Pulled 0.3 %
##               toward the eye so it always passes its own depth pass.
## Uniforms (set them on every pass: holo_set()): col, origin / up (the base and its up), height,
## flash (0..1 whitens: the build snap), appear (0..1: the ghost prints itself in from the base, a
## bright cut line at the top), alert (refused click: brighter edges), vis (overall fade).
const HOLO_FILL := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_front, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 col : source_color = vec4(0.62, 0.95, 1.0, 1.0);
uniform vec3 origin = vec3(0.0);
uniform vec3 up = vec3(0.0, 1.0, 0.0);
uniform float height = 3.0;
uniform float appear = 1.0;
uniform float flash = 0.0;
uniform float vis = 1.0;
varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float h = dot(wpos - origin, up);
	if (h > appear * (height + 0.4) - 0.2) {
		discard;
	}
	float hn = clamp(h / max(height, 0.1), 0.0, 1.0);
	float bands = 0.5 + 0.5 * sin(h * 24.0 - TIME * 2.0);
	ALBEDO = mix(col.rgb * 0.8, vec3(1.0), flash * 0.6);
	ALPHA = clamp((0.06 + 0.04 * bands) * (1.0 - hn * 0.4) + flash * 0.2, 0.0, 1.0) * vis;
}
"""

const HOLO_DEPTH := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_always, shadows_disabled, fog_disabled;

uniform vec3 origin = vec3(0.0);
uniform vec3 up = vec3(0.0, 1.0, 0.0);
uniform float height = 3.0;
uniform float appear = 1.0;
varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float h = dot(wpos - origin, up);
	if (h > appear * (height + 0.4) - 0.2) {
		discard;
	}
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
"""

const HOLO_SHELL := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_never, shadows_disabled, fog_disabled, skip_vertex_transform;

uniform vec4 col : source_color = vec4(0.62, 0.95, 1.0, 1.0);
uniform vec3 origin = vec3(0.0);
uniform vec3 up = vec3(0.0, 1.0, 0.0);
uniform float height = 3.0;
uniform float flash = 0.0;
uniform float appear = 1.0;
uniform float alert = 0.0;
uniform float vis = 1.0;
varying vec3 wpos;
varying vec3 bary;
varying float bary_on;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	bary = COLOR.rgb;
	bary_on = 1.0 - step(0.5, COLOR.a);
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * 0.997;
	NORMAL = normalize((VIEW_MATRIX * vec4(MODEL_NORMAL_MATRIX * NORMAL, 0.0)).xyz);
}

void fragment() {
	float h = dot(wpos - origin, up);
	float cut = appear * (height + 0.4) - 0.2;
	if (h > cut) {
		discard;
	}
	float hn = clamp(h / max(height, 0.1), 0.0, 1.0);
	float f = 1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	vec3 rim = vec3(pow(f, 3.0), pow(f, 2.4), pow(f, 1.9));
	float sl = abs(fract(h * 9.0 - TIME * 0.45) - 0.5) * 2.0;
	float scan = 1.0 - smoothstep(0.0, 0.3, sl);
	float fine = 0.5 + 0.5 * sin(h * 140.0 + TIME * 3.0);
	float sh = fract(TIME * 0.38) * (height + 1.0) - 0.5;
	float ds = h - sh;
	float slice = exp(-ds * ds * 260.0);
	float trail = 0.0;
	if (ds < 0.0) {
		trail = exp(ds * 3.0) * 0.3;
	}
	float e = min(bary.x, min(bary.y, bary.z));
	float ew = max(fwidth(e), 0.0001);
	float wire = (1.0 - smoothstep(ew * 0.6, ew * 1.8, e)) * bary_on;
	float cl = (1.0 - step(0.999, appear)) * exp(-abs(h - cut) * 18.0);
	float flick = 0.96 + 0.04 * sin(TIME * 31.0 + h * 4.0);
	vec3 c = col.rgb;
	vec3 hi = mix(c, vec3(1.0), 0.55);
	vec3 rgb = c * (0.4 + 0.08 * fine) + c * rim * 0.9 + hi * (scan * 0.15 + slice * 0.8 + trail * 0.25 + wire * 0.75 + cl);
	rgb = mix(rgb, vec3(1.0, 0.98, 0.95), flash * 0.75);
	float rim_a = (rim.r + rim.g + rim.b) * 0.333;
	float a = 0.07 + 0.42 * rim_a + scan * 0.07 + slice * 0.5 + trail * 0.1 + wire * 0.6 + cl * 0.8;
	a *= (1.0 - hn * 0.18) * flick;
	a += flash * 0.4 + alert * 0.25 * (wire + rim.g);
	ALBEDO = min(rgb, vec3(1.25));
	ALPHA = clamp(a, 0.0, 0.92) * vis;
}
"""

static var thumbs := {}              # entry id -> Texture2D
static var _ring: Texture2D
static var _holo_shader: Shader
static var _holo_fill_shader: Shader
static var _holo_depth_shader: Shader
static var _wire_budget := 0
static var _renderer: Node = null


# =================================================================================================
# Models
# =================================================================================================

static func model(parent: Node, e: Dictionary) -> Node3D:
	var id := str(e.get("id", ""))
	var scr = e.get("script")
	if id == "skiff" or id == "armed_skiff":
		return _skiff_model(parent, "armed" if id == "armed_skiff" else "home")
	# Crafting cards (scripts/war/craft_menu.gd): a gun's own first-person model, or a grenade.
	if e.has("item_script"):
		return _item_model(parent, str(e["item_script"]))
	if bool(e.get("grenade", false)):
		return _grenade_model(parent)
	if not (scr is Script):
		match id:
			"cannon":
				scr = load("res://scripts/war/cannon.gd")
			"flak":
				scr = load("res://scripts/war/flak.gd")
			"buster":
				scr = load("res://scripts/war/buster.gd")
	if not (scr is Script) or not (scr as Script).can_instantiate():
		return null
	var n = (scr as Script).new()
	if not (n is Node3D):
		if n is Node:
			(n as Node).free()
		return null
	var s := n as Node3D
	s.name = "BuildPreview_" + id
	s.set("team", "home")
	s.set_meta("net_id", -1)                  # never a networked structure
	s.set_meta("build_preview", true)
	s.process_mode = Node.PROCESS_MODE_DISABLED
	parent.add_child(s)
	_make_inert(s)
	# A nice pose: turret square on, barrel raised.
	var tur = s.get("_turret")
	if tur is Node3D:
		(tur as Node3D).rotation.y = 0.0
	var cra = s.get("_cradle")
	if cra is Node3D:
		(cra as Node3D).rotation.x = deg_to_rad(38.0 if id != "flak" else 30.0)
	if s.has_method("_update_rams"):
		s.call("_update_rams")
	return s


## A hand item's first-person model (its build_model(), without the item ever entering the tree).
static func _item_model(parent: Node, path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		return null
	var scr = load(path)
	if not (scr is Script) or not (scr as Script).can_instantiate():
		return null
	var it = (scr as Script).new()
	if not (it is Node) or not it.has_method("build_model"):
		if it is Node:
			(it as Node).free()
		return null
	var m: Node3D = it.build_model()
	if m != null and m.get_parent() != null:
		m.get_parent().remove_child(m)
	(it as Node).free()
	if m == null:
		return null
	m.name = "CraftPreview_" + path.get_file().get_basename()
	parent.add_child(m)
	_make_inert(m)
	return m


static func _grenade_model(parent: Node) -> Node3D:
	var pr = load("res://scripts/items/projectiles.gd").new()
	if not pr.has_method("_make_mesh"):
		(pr as Node).free()
		return null
	var m: Node3D = pr.call("_make_mesh", "hand")
	(pr as Node).free()
	if m == null:
		return null
	m.scale = Vector3.ONE * 3.0
	m.rotation = Vector3(0.35, 0.0, -0.4)
	parent.add_child(m)
	return m


## The Mekik's meshes (skiff_build.gd) in a livery: "home", or "armed" for the Silahlı Mekik
## (adds the gun housings, rocket pods and the barrel clusters).
static func _skiff_model(parent: Node, livery := "home") -> Node3D:
	if not ResourceLoader.exists(SKIFF_BUILD):
		return null
	var b = load(SKIFF_BUILD)
	var ms: Dictionary = b.call("meshes", livery)
	var root := Node3D.new()
	root.name = "BuildPreview_skiff"
	parent.add_child(root)
	var hull: Material = b.call("hull_material", false)
	var glass: Material = b.call("glass_material")
	for k in ["hull", "cabin", "glass", "weapons"]:
		if ms.has(k):
			var mi := MeshInstance3D.new()
			mi.mesh = ms[k]
			mi.material_override = glass if k == "glass" else hull
			root.add_child(mi)
	if ms.has("barrels"):
		var bc: Dictionary = (b as Script).get_script_constant_map()
		for sx: float in [-1.0, 1.0]:
			var bm := MeshInstance3D.new()
			bm.mesh = ms["barrels"]
			bm.material_override = hull
			bm.position = Vector3(sx * float(bc.get("GUN_X", 0.3)), float(bc.get("GUN_Y", 0.45)), float(bc.get("GUN_PIVOT_Z", -2.15)))
			root.add_child(bm)
	if ms.has("foot"):
		var feet = (b as Script).get_script_constant_map().get("FEET", [])
		for f in (feet if feet is Array else []):
			var fm := MeshInstance3D.new()
			fm.mesh = ms["foot"]
			fm.material_override = hull
			fm.position = f
			root.add_child(fm)
	return root


## Out of every group, no collisions, no lights / particles / labels / sound.
static func _make_inert(root: Node) -> void:
	for g in root.get_groups():
		if not str(g).begins_with("_"):
			root.remove_from_group(g)
	for n in root.find_children("*", "", true, false):
		if n is CollisionObject3D:
			(n as CollisionObject3D).collision_layer = 0
			(n as CollisionObject3D).collision_mask = 0
		elif n is CollisionShape3D:
			(n as CollisionShape3D).disabled = true
		if n is Light3D or n is GPUParticles3D or n is CPUParticles3D or n is Label3D or n is Decal \
				or n is Sprite3D:
			(n as Node3D).visible = false
		elif n is AudioStreamPlayer3D:
			(n as AudioStreamPlayer3D).stop()
			(n as AudioStreamPlayer3D).autoplay = false
		elif n is Camera3D:
			(n as Camera3D).current = false
		elif n is CanvasLayer:
			(n as CanvasLayer).visible = false


## Every surface of `root` drawn with `mat`, no shadows.
static func hologram(root: Node, mat: Material) -> void:
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if not gi.visible:
			continue
		gi.material_override = mat
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).material_override = mat


## A new hologram material chain (fill -> depth -> shell, see HOLO_FILL); one per ghost kind.
static func holo_material() -> ShaderMaterial:
	if _holo_shader == null:
		_holo_shader = Shader.new()
		_holo_shader.code = HOLO_SHELL
		_holo_fill_shader = Shader.new()
		_holo_fill_shader.code = HOLO_FILL
		_holo_depth_shader = Shader.new()
		_holo_depth_shader.code = HOLO_DEPTH
	var fill := ShaderMaterial.new()
	fill.shader = _holo_fill_shader
	fill.render_priority = 3
	var depth := ShaderMaterial.new()
	depth.shader = _holo_depth_shader
	depth.render_priority = 4
	var shell := ShaderMaterial.new()
	shell.shader = _holo_shader
	shell.render_priority = 5
	fill.next_pass = depth
	depth.next_pass = shell
	return fill


## Sets a uniform on every pass of a hologram chain.
static func holo_set(m: Material, param: StringName, value: Variant) -> void:
	var cur := m
	while cur != null:
		if cur is ShaderMaterial:
			(cur as ShaderMaterial).set_shader_parameter(param, value)
		cur = cur.next_pass


## Gives every mesh under `root` the barycentric copy of wire_mesh() (edge lines in HOLO_SHELL), up
## to `budget` triangles in all (one-time, when a ghost kind is first built).
static func wireframe(root: Node, budget := 60000) -> void:
	_wire_budget = budget
	var done := {}
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var key := mi.mesh.get_instance_id()
		if not done.has(key):
			done[key] = wire_mesh(mi.mesh)
		mi.mesh = done[key]


## A copy of `mesh` with every triangle on its own three vertices and their barycentric coordinates
## in COLOR.rgb (COLOR.a = 0 marks them; any other mesh draws no lines). An edge shared with a neighbour face that bends less than `crease` degrees (a curved
## surface, a quad's diagonal) is masked out, so only the creases and the outline draw. Unsupported
## meshes, or more than `max_tris` triangles (or the wireframe() budget), come back unchanged.
static func wire_mesh(mesh: Mesh, crease := 28.0, max_tris := 12000) -> Mesh:
	if mesh == null or not (mesh is ArrayMesh or mesh is PrimitiveMesh):
		return mesh
	var cos_c := cos(deg_to_rad(crease))
	var out := ArrayMesh.new()
	var used := 0
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			return mesh
		var arr := mesh.surface_get_arrays(s)
		if arr.size() < Mesh.ARRAY_MAX or not (arr[Mesh.ARRAY_VERTEX] is PackedVector3Array):
			return mesh
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms := PackedVector3Array()
		if arr[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			norms = arr[Mesh.ARRAY_NORMAL]
		var idx := PackedInt32Array()
		if arr[Mesh.ARRAY_INDEX] is PackedInt32Array:
			idx = arr[Mesh.ARRAY_INDEX]
		var indexed := not idx.is_empty()
		var ntri: int = (idx.size() if indexed else verts.size()) / 3
		used += ntri
		if ntri == 0 or used > max_tris or used > _wire_budget:
			return mesh
		# Weld the positions so faces that share an edge find each other (split normals duplicate them).
		var weld := {}
		var pid := PackedInt32Array()
		pid.resize(verts.size())
		for i in verts.size():
			var wk := Vector3i((verts[i] * 2000.0).round())
			if weld.has(wk):
				pid[i] = int(weld[wk])
			else:
				pid[i] = weld.size()
				weld[wk] = pid[i]
		var fn := PackedVector3Array()
		fn.resize(ntri)
		var corner := PackedInt32Array()
		corner.resize(ntri * 3)
		for t in ntri:
			for j in 3:
				corner[t * 3 + j] = idx[t * 3 + j] if indexed else t * 3 + j
			var va := verts[corner[t * 3]]
			fn[t] = (verts[corner[t * 3 + 1]] - va).cross(verts[corner[t * 3 + 2]] - va).normalized()
		# Edge slot j of triangle t joins corners j and j+1; a slot is hidden when the face across it
		# is nearly coplanar.
		var hide := PackedByteArray()
		hide.resize(ntri * 3)
		var edges := {}
		for t in ntri:
			for j in 3:
				var p0 := pid[corner[t * 3 + j]]
				var p1 := pid[corner[t * 3 + (j + 1) % 3]]
				var slot := t * 3 + j
				if p0 == p1:
					hide[slot] = 1
					continue
				var ek := mini(p0, p1) * 2097152 + maxi(p0, p1)
				if not edges.has(ek):
					edges[ek] = slot
					continue
				var other := int(edges[ek])
				if other >= 0:
					var ot: int = other / 3
					if fn[t].dot(fn[ot]) > cos_c:
						hide[slot] = 1
						hide[other] = 1
					edges[ek] = -1
		var ov := PackedVector3Array()
		ov.resize(ntri * 3)
		var on := PackedVector3Array()
		on.resize(ntri * 3)
		var oc := PackedColorArray()
		oc.resize(ntri * 3)
		for t in ntri:
			# Corner k's barycentric is 1 at k; the edge opposite corner k (slot k+1) masks component k.
			var mx := float(hide[t * 3 + 1])
			var my := float(hide[t * 3 + 2])
			var mz := float(hide[t * 3])
			for j in 3:
				var vi := corner[t * 3 + j]
				ov[t * 3 + j] = verts[vi]
				on[t * 3 + j] = norms[vi] if vi < norms.size() else fn[t]
				oc[t * 3 + j] = Color(minf((1.0 if j == 0 else 0.0) + mx, 1.0), minf((1.0 if j == 1 else 0.0) + my, 1.0),
						minf((1.0 if j == 2 else 0.0) + mz, 1.0), 0.0)        # alpha 0 = "barycentrics here"
		var oa := []
		oa.resize(Mesh.ARRAY_MAX)
		oa[Mesh.ARRAY_VERTEX] = ov
		oa[Mesh.ARRAY_NORMAL] = on
		oa[Mesh.ARRAY_COLOR] = oc
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, oa)
	_wire_budget -= used
	return out


## Visual AABB of everything visible under root (world space).
static func bounds(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n in root.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		if not vi.visible or not vi.is_visible_in_tree():
			continue
		var bb := vi.global_transform * vi.get_aabb()
		if first:
			out = bb
			first = false
		else:
			out = out.merge(bb)
	if first:
		return AABB(root.global_position - Vector3.ONE, Vector3.ONE * 2.0)
	return out


# =================================================================================================
# Footprint ring (Decal texture)
# =================================================================================================

static func ring_texture() -> Texture2D:
	if _ring != null:
		return _ring
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(n, n) * 0.5
	for y in n:
		for x in n:
			var d := (Vector2(x + 0.5, y + 0.5) - c) / (n * 0.5)
			var r := d.length()
			var a := 0.0
			# Outer ring, a thin inner ring, faint fill.
			a += exp(-pow((r - 0.93) * 38.0, 2.0)) * 0.95
			a += exp(-pow((r - 0.78) * 70.0, 2.0)) * 0.35
			if r < 0.93:
				a += 0.07
			# Tick marks every 15° on the outer band.
			var ang := atan2(d.y, d.x)
			var tick := absf(fmod(ang + TAU, deg_to_rad(15.0)) - deg_to_rad(7.5))
			if r > 0.8 and r < 0.9 and tick > deg_to_rad(6.6):
				a += 0.55
			# Centre cross.
			if r < 0.12 and (absf(d.x) < 0.012 or absf(d.y) < 0.012):
				a += 0.6
			a = clampf(a, 0.0, 1.0) if r < 1.0 else 0.0
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	_ring = ImageTexture.create_from_image(img)
	return _ring


# =================================================================================================
# Thumbnails
# =================================================================================================

## Renders the missing thumbnails in the background (one renderer at a time).
static func request_thumbs(tree: SceneTree, entries: Array) -> void:
	if tree == null:
		return
	var todo: Array = []
	for e in entries:
		if e is Dictionary and not thumbs.has(str((e as Dictionary).get("id", ""))):
			todo.append(e)
	if todo.is_empty():
		return
	if _renderer != null and is_instance_valid(_renderer):
		_renderer.call("enqueue", todo)
		return
	var r = load("res://scripts/war/build_preview.gd").new()
	r.name = "BuildThumbs"
	_renderer = r
	tree.root.add_child.call_deferred(r)
	r.call_deferred("enqueue", todo)


var _queue: Array = []
var _running := false


## Queues entries; the run starts once this renderer is in the tree (a second request_thumbs in the
## same frame lands here before the deferred add_child: it only queues, _ready starts the run).
func enqueue(list: Array) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for e in list:
		var id := str((e as Dictionary).get("id", ""))
		if thumbs.has(id) or _queue.any(func(q): return str(q.get("id", "")) == id):
			continue
		_queue.append(e)
	if not _running and is_inside_tree():
		_run()


func _ready() -> void:
	if not _running and not _queue.is_empty():
		_run()


func _run() -> void:
	_running = true
	await get_tree().process_frame
	while not _queue.is_empty():
		var e: Dictionary = _queue.pop_front()
		var id := str(e.get("id", ""))
		if thumbs.has(id):
			continue
		var tex := await _render(e)
		thumbs[id] = tex if tex != null else PlaceholderTexture2D.new()
	_running = false
	_renderer = null
	queue_free()


func _render(e: Dictionary) -> Texture2D:
	var vp := SubViewport.new()
	vp.size = THUMB_SIZE
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.62, 0.72)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.adjustment_enabled = true
	env.adjustment_contrast = 0.95
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	cam.fov = 28.0
	cam.near = 0.05
	cam.far = 200.0
	vp.add_child(cam)
	cam.current = true
	var key := DirectionalLight3D.new()
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.95, 0.88)
	vp.add_child(key)
	key.global_transform = Transform3D(Basis.looking_at(Vector3(0.55, -0.7, 0.45).normalized(), Vector3.UP), Vector3.ZERO)
	var rim := DirectionalLight3D.new()
	rim.light_energy = 0.55
	rim.light_color = Color(0.55, 0.8, 1.0)
	vp.add_child(rim)
	rim.global_transform = Transform3D(Basis.looking_at(Vector3(-0.7, -0.25, -0.65).normalized(), Vector3.UP), Vector3.ZERO)
	var holder := Node3D.new()
	vp.add_child(holder)
	var m := model(holder, e)
	if m == null:
		vp.queue_free()
		return null
	cam.current = true
	# 3/4 view from the front left, framed on its bounds.
	var bb := bounds(holder)
	var c := bb.get_center()
	var rad := maxf(bb.size.length() * 0.5, 0.5)
	var dir := Vector3(-0.85, 0.55, -1.0).normalized()
	var fit := 0.92
	if e.has("item_script"):
		# A gun: side on from the left, slightly from above, a little looser (view-model shading
		# draws it ~10 % larger).
		dir = Vector3(-1.0, 0.32, 0.18).normalized()
		fit = 1.12
	var dist := rad / tan(deg_to_rad(cam.fov * 0.5)) * fit
	cam.global_transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), c + dir * dist)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img == null or img.is_empty():
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
