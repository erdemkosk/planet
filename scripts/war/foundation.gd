extends Node3D
## Foundations for the war structures (cannon, buster, flak, armory, drilling rig): a concrete skirt
## under a pad's outline and steel piles under feet that reach down to the REAL ground, so nothing
## floats on a slope, over a footprint corner the build tool did not sample, or over a crater dug
## beside it. The node is a child of its structure (local frame = the structure's, +Y up); the
## structure puts it in its assembly list and calls refit() when placed and after every settle.
## The ground: a terrain physics ray (exactly the visible LOD0 mesh) where collision exists, else
## the cheap density march (an estimate; the node then refits itself once the camera comes close).
## The skirt also collides (ship layer, like the structures): it is solid under the pad.
##   Foundation.create(host, body, ring, piles, color) -> the node (already fitted)
##   refit(again := false)       (again: once more 1.5 s later, after a dig)
##   Foundation.ground_offset(node, body, w, up, above, below) -> float   (+ = ground above w; -INF none)
##   Foundation.support_drop(host, body, pts) -> float    how far to sink to rest on what is left
##   Foundation.polygon(n, r, y) / Foundation.rect(x0, x1, z0, z1, y, nx, nz) -> outline points

const SCRIPT_PATH := "res://scripts/war/foundation.gd"
const MAX_DEPTH := 8.0          # longest skirt / pile (m): a deep crater beside it shows a long footing
const EMBED := 0.3              # how far skirts and piles reach into the ground
const MIN_GAP := 0.05           # smaller gaps are left alone
const NEAR := 40.0              # an estimated fit is redone (with collision) once the camera is this close
const SEG := 0.9                # m: the skirt outline is probed at least this densely
const BATTER := 0.35            # the plinth face slopes out this much per metre of depth

var body: Node3D
var ring := PackedVector3Array()          # closed outline the skirt hangs from (local; may be empty)
var piles: Array = []                     # [local point, radius]: a pile from the point down
var color := Color(0.4, 0.39, 0.37)       # skirt colour (the pad's concrete)
var _approx := false
var _check_t := 0.0

static var _steel_mat: StandardMaterial3D


## Adds a fitted foundation under `host` (its child). ring / piles in host-local coordinates.
static func create(host: Node3D, p_body: Node3D, p_ring: PackedVector3Array, p_piles: Array, p_color: Color) -> Node3D:
	var f: Node3D = load(SCRIPT_PATH).new()
	f.name = "Foundation"
	f.body = p_body
	f.ring = p_ring
	f.piles = p_piles
	f.color = p_color
	host.add_child(f)
	f.refit()
	return f


## Regular n-gon of radius r at height y, vertices where CylinderMesh puts them (x = sin, z = cos).
static func polygon(n: int, r: float, y: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(Vector3(sin(a) * r, y, cos(a) * r))
	return out


## Rectangle outline at height y, nx / nz segments per side.
static func rect(x0: float, x1: float, z0: float, z1: float, y: float, nx: int, nz: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in nx:
		out.append(Vector3(lerpf(x0, x1, float(i) / float(nx)), y, z0))
	for i in nz:
		out.append(Vector3(x1, y, lerpf(z0, z1, float(i) / float(nz))))
	for i in nx:
		out.append(Vector3(lerpf(x1, x0, float(i) / float(nx)), y, z1))
	for i in nz:
		out.append(Vector3(x0, y, lerpf(z1, z0, float(i) / float(nz))))
	return out


## Height of the ground at world point w along `up`, relative to w (m, + = the ground is above w),
## searched from `above` m over w to `below` m under it; -INF when there is none.
static func ground_offset(node: Node3D, p_body: Node3D, w: Vector3, up: Vector3, above := 2.0, below := 6.0) -> float:
	return float(_probe(node, p_body, w, up, above, below)[0])


## How far a structure should sink (along its up) to rest on what is left under it: the ground
## under a quarter of `pts` (local points of its base) is reached. 0 while it is still carried; never up.
static func support_drop(host: Node3D, p_body: Node3D, pts: PackedVector3Array) -> float:
	var xf := host.global_transform
	var up := xf.basis.y.normalized()
	var gaps: Array[float] = []
	for p in pts:
		var off := float(_probe(host, p_body, xf * p, up, 1.5, 40.0)[0])
		if not is_inf(off):
			gaps.append(-off)
	if gaps.is_empty():
		return 0.0
	gaps.sort()
	return maxf(gaps[mini(int(float(gaps.size()) / 4.0), gaps.size() - 1)], 0.0)


## [offset (see ground_offset), estimated]: estimated = found by the density march because no
## terrain collision was there (far from the camera).
static func _probe(node: Node3D, p_body: Node3D, w: Vector3, up: Vector3, above: float, below: float) -> Array:
	var top := w + up * above
	var dens := p_body != null and is_instance_valid(p_body) and p_body.has_method("density_at")
	if dens and float(p_body.density_at(top)) < 0.0:
		return [above, false]                       # buried deeper than we look
	if node != null and node.is_inside_tree():
		var q := PhysicsRayQueryParameters3D.create(top, w - up * below, Game.LAYER_TERRAIN)
		var hit := node.get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			return [((hit["position"] as Vector3) - w).dot(up), false]
	if not dens:
		return [-INF, false]
	# No collision here: march the cheap density (density is roughly the height above the ground).
	var span := above + below
	var t := 0.0
	var prev := float(p_body.density_fast(top))
	while t < span:
		var tn := minf(t + maxf(0.4, prev * 0.7), span)
		var d := float(p_body.density_fast(top - up * tn))
		if d < 0.0:
			var lo := t
			var hi := tn
			for i in 4:
				var m := (lo + hi) * 0.5
				if float(p_body.density_fast(top - up * m)) < 0.0:
					hi = m
				else:
					lo = m
			return [above - (lo + hi) * 0.5, true]
		prev = d
		t = tn
	return [-INF, false]


## Rebuilds the skirt and the piles for the structure's current place and the current ground.
## again: once more 1.5 s later (after a dig the terrain collision may still be catching up).
func refit(again := false) -> void:
	if again and is_inside_tree():
		get_tree().create_timer(1.5).timeout.connect(refit.bind(false))
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_approx = false
	var host := get_parent() as Node3D
	if host == null or body == null or not is_instance_valid(body) or not is_inside_tree():
		set_process(false)
		return
	var xf := host.global_transform
	var up := xf.basis.y.normalized()
	# The outline densified to SEG m pieces (the ground between two far-apart corners may dip under a
	# straight wall bottom: a slit of sky under the slab). Each point: its foot steps out by BATTER ×
	# its depth (a sloped plinth face, not a cliff) and reaches the ground measured under that foot.
	var top := _dense_ring()
	var c := Vector3.ZERO
	for p in top:
		c += p
	c /= maxf(float(top.size()), 1.0)
	var feet := PackedVector3Array()
	var any := false
	var nt := top.size()
	for i in nt:
		var p := top[i]
		var g := _gap(host, xf * p, up)
		# Outward in the slab's plane: the mean of the two adjacent pieces' outward normals.
		var out := _edge_out(top[(i + nt - 1) % nt], p, c) + _edge_out(p, top[(i + 1) % nt], c)
		out = out.normalized() if out.length_squared() > 1e-6 else Vector3.ZERO
		var q := p + out * (BATTER * maxf(g, 0.0))
		var g2 := maxf(_gap(host, xf * q, up), 0.0) if g > MIN_GAP else 0.0
		feet.append(q + Vector3.DOWN * (g2 + EMBED) if g > MIN_GAP else p + Vector3.DOWN * EMBED)
		if g > MIN_GAP:
			any = true
	if any and top.size() >= 3:
		_skirt(top, feet, c)
	for pl in piles:
		var p: Vector3 = pl[0]
		var g := _gap(host, xf * p, up)
		if g > MIN_GAP:
			_pile(p, float(pl[1]), g)
	_check_t = 0.5
	set_process(_approx)


## Ground depth below a world point along up (m, + = a gap under it), clamped to the skirt range.
func _gap(host: Node3D, w: Vector3, up: Vector3) -> float:
	var r := _probe(host, body, w, up, 1.5, MAX_DEPTH + 0.5)
	if bool(r[1]):
		_approx = true
	var off := float(r[0])
	return MAX_DEPTH if is_inf(off) else clampf(-off, -1.5, MAX_DEPTH)


## Estimated fit (no collision when it was made): redo it once the camera is near and the terrain
## under the structure collides.
func _process(delta: float) -> void:
	_check_t -= delta
	if _check_t > 0.0:
		return
	_check_t = 0.5
	var cam := get_viewport().get_camera_3d()
	var host := get_parent() as Node3D
	if cam == null or host == null or cam.global_position.distance_to(host.global_position) > NEAR:
		return
	var up := host.global_transform.basis.y.normalized()
	var q := PhysicsRayQueryParameters3D.create(host.global_position + up * 2.0, host.global_position - up * 4.0, Game.LAYER_TERRAIN)
	if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		refit()


## Horizontal outward normal of the outline piece a-b (away from the centre c).
static func _edge_out(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var o := (b - a).cross(Vector3.UP)
	o.y = 0.0
	if o.length_squared() < 1e-8:
		return Vector3.ZERO
	o = o.normalized()
	return -o if o.dot((a + b) * 0.5 - c) < 0.0 else o


## The outline with no piece longer than SEG m.
func _dense_ring() -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := ring.size()
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		var k := maxi(int(ceilf(a.distance_to(b) / SEG)), 1)
		for s in k:
			out.append(a.lerp(b, float(s) / float(k)))
	return out


## The plinth face: from each outline piece (top) down to its feet, and a solid hull. Light concrete
## darkening a little toward the ground (vertex colour), lit as a sloped face.
func _skirt(top: PackedVector3Array, feet: PackedVector3Array, c: Vector3) -> void:
	var n := top.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hull := PackedVector3Array()
	# (lighter than the pads' own concrete: a vertical face in shade read as a dark brown block)
	var hi_col := color.lightened(0.3)
	var low := hi_col.darkened(0.15)
	for i in n:
		var j := (i + 1) % n
		var a := top[i]
		var b := top[j]
		var a2 := feet[i]
		var b2 := feet[j]
		var out := _edge_out(a, b, c)
		if out == Vector3.ZERO:
			continue
		# Godot front faces are clockwise seen from outside (their right-hand normal points in).
		var tris: Array[Vector3] = [a, b, b2, a, b2, a2]
		if (b - a).cross(b2 - a).dot(out) > 0.0:
			tris = [a, b2, b, a, a2, b2]
		var nrm := (out + Vector3.UP * BATTER).normalized()
		for v in tris:
			st.set_normal(nrm)
			st.set_color(hi_col if v == a or v == b else low)
			st.add_vertex(v)
		hull.append(a)
		hull.append(a2)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.WHITE
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.9
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	add_child(mi)
	var sb := StaticBody3D.new()
	sb.collision_layer = Game.LAYER_SHIP
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cv := ConvexPolygonShape3D.new()
	cv.points = hull
	cs.shape = cv
	sb.add_child(cs)
	add_child(sb)


## A steel pile from p down to the ground (+ EMBED) with a footing plate where it meets it.
func _pile(p: Vector3, r: float, gap: float) -> void:
	if _steel_mat == null:
		_steel_mat = StandardMaterial3D.new()
		_steel_mat.albedo_color = Color(0.3, 0.31, 0.33)
		_steel_mat.metallic = 0.8
		_steel_mat.roughness = 0.42
	var h := gap + EMBED
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r * 1.15
	cm.height = h
	cm.radial_segments = 10
	cm.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = _steel_mat
	mi.position = p + Vector3.DOWN * (h * 0.5)
	add_child(mi)
	var pm := CylinderMesh.new()
	pm.top_radius = r * 1.9
	pm.bottom_radius = r * 2.2
	pm.height = 0.08
	pm.radial_segments = 12
	pm.rings = 1
	var plate := MeshInstance3D.new()
	plate.mesh = pm
	plate.material_override = _steel_mat
	plate.position = p + Vector3.DOWN * (gap - 0.02)
	add_child(plate)
