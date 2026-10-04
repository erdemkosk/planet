extends RefCounted
## Procedural vegetation meshes. Index order matches TerrainGen.Flora.
## Two versions per tree / bush / rock (planet.gd draws them with visibility ranges):
##  - far: cheap — crowns are clusters of smooth leaf clumps, pine tiers are cones;
##  - near (build_all()[2], null where there is none): NMS-style realism — crowns made of many
##    alpha-tested leaf cards (flora_textures.gd atlas) around a dark core with crown-volume normals,
##    smooth curved bark trunks with root flare, needle-branch cards on pines, textured palm fronds,
##    noise-sculpted smooth boulders. Cards go into a second surface with foliage_cards.gdshader.
## Vertex COLOR.rgb = base color, COLOR.a = tint mask (1 = multiplied by the per-instance tint from
## MultiMesh custom data), UV.x = emission mask, UV.y = surface kind (0 plain, 1 leaf clump, 2 rock,
## 3 card, 4 bark), UV2 = atlas coordinates on cards. See shaders/foliage*.gdshader.

const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const FOLIAGE_SHADER := preload("res://shaders/foliage.gdshader")
const CARD_SHADER := preload("res://shaders/foliage_cards.gdshader")
const FloraTextures := preload("res://scripts/planet/flora_textures.gd")

const BARK := Color(0.33, 0.23, 0.15, 0.0)
const PALE := Color(0.86, 0.82, 0.72, 0.0)

var _v := PackedVector3Array()
var _n := PackedVector3Array()
var _c := PackedColorArray()
var _uv := PackedVector2Array()
var _uv2 := PackedVector2Array()
var _rng := RandomNumberGenerator.new()
var _kind := 0.0              # UV.y written by _push: 0 plain, 1 leaves, 2 rock, 3 card, 4 bark
const LEAF := 1.0
const STONE := 2.0
const CARD := 3.0
const WOOD := 4.0


## Returns [far meshes (Array[Mesh] by Flora index), materials (Array[ShaderMaterial]),
## near meshes (Array, Mesh or null by Flora index)].
func build_all() -> Array:

	var meshes: Array = []
	var mats: Array = []
	meshes.resize(TerrainGen.FLORA_COUNT)
	var near: Array = []
	near.resize(TerrainGen.FLORA_COUNT)
	var near_specs := {
		TerrainGen.Flora.PINE: _pine_near,
		TerrainGen.Flora.BROADLEAF: _broadleaf_near,
		TerrainGen.Flora.PALM: _palm_near,
		TerrainGen.Flora.JUNGLE_TREE: _jungle_near,
		TerrainGen.Flora.BUSH: _bush_near,
		TerrainGen.Flora.ROCK: _rock_near,
	}
	# kind: [builder, sway (m at reference height), reference height, emission energy]
	var specs := {
		TerrainGen.Flora.PINE: [_pine, 0.10, 6.0, 0.0],
		TerrainGen.Flora.BROADLEAF: [_broadleaf, 0.14, 6.0, 0.0],
		TerrainGen.Flora.PALM: [_palm, 0.30, 7.0, 0.0],
		TerrainGen.Flora.JUNGLE_TREE: [_jungle, 0.18, 11.0, 0.0],
		TerrainGen.Flora.CACTUS: [_cactus, 0.0, 3.0, 0.0],
		TerrainGen.Flora.DEAD_TREE: [_dead, 0.05, 4.5, 0.0],
		TerrainGen.Flora.MUSHROOM: [_mushroom, 0.06, 5.0, 2.6],
		TerrainGen.Flora.BUSH: [_bush, 0.05, 1.2, 0.0],
		TerrainGen.Flora.ROCK: [_rock, 0.0, 1.0, 0.0],
		TerrainGen.Flora.GRASS: [_grass, 0.07, 0.5, 0.0],
		TerrainGen.Flora.FLOWER: [_flower, 0.06, 0.5, 0.0],
		TerrainGen.Flora.CRYSTAL_CLUSTER: [_crystals, 0.0, 1.0, 2.4],
		TerrainGen.Flora.GLOW_SHROOM: [_glow_shroom, 0.0, 0.5, 3.0],
		TerrainGen.Flora.CRYSTAL_SPIRE: [_spire, 0.0, 6.0, 1.3],
	}
	var leaf_tex: Texture2D = FloraTextures.atlas()
	for kind in specs:
		var sp: Array = specs[kind]
		var mat := ShaderMaterial.new()
		mat.shader = FOLIAGE_SHADER
		mat.set_shader_parameter("sway", sp[1])
		mat.set_shader_parameter("sway_height", sp[2])
		mat.set_shader_parameter("emission_energy", sp[3])
		mats.append(mat)
		_begin(int(kind) * 7919 + 13)
		(sp[0] as Callable).call()
		meshes[kind] = _commit(mat, null)
		if near_specs.has(kind):
			var cmat := ShaderMaterial.new()
			cmat.shader = CARD_SHADER
			cmat.set_shader_parameter("sway", sp[1])
			cmat.set_shader_parameter("sway_height", sp[2])
			cmat.set_shader_parameter("leaf_tex", leaf_tex)
			mats.append(cmat)
			_begin(int(kind) * 7919 + 13)      # same seed: near and far shapes line up
			(near_specs[kind] as Callable).call()
			near[kind] = _commit(mat, cmat)
	return [meshes, mats, near]


func _begin(seed_value: int) -> void:
	_v = PackedVector3Array()
	_n = PackedVector3Array()
	_c = PackedColorArray()
	_uv = PackedVector2Array()
	_uv2 = PackedVector2Array()
	_rng.seed = seed_value
	_kind = 0.0


## Indexed mesh: identical vertices are shared (smooth leaf clumps shrink ~5x), which matters with
## thousands of instances drawn in the main and shadow passes. Card triangles (alpha-tested) go to
## their own surface with `card_mat`; everything else uses `mat`.
func _commit(mat: Material = null, card_mat: Material = null) -> ArrayMesh:
	var m := ArrayMesh.new()
	for pass_i in 2:
		var v := PackedVector3Array()
		var n := PackedVector3Array()
		var c := PackedColorArray()
		var uv := PackedVector2Array()
		var uv2 := PackedVector2Array()
		var idx := PackedInt32Array()
		var seen := {}
		for t in range(0, _v.size() - 2, 3):
			var is_card := _uv[t].y > 2.5 and _uv[t].y < 3.5
			if is_card != (pass_i == 1):
				continue
			for k in 3:
				var i := t + k
				var key := [_v[i], _n[i], _c[i], _uv[i], _uv2[i]]
				var at: int = seen.get(key, -1)
				if at < 0:
					at = v.size()
					seen[key] = at
					v.append(_v[i])
					n.append(_n[i])
					c.append(_c[i])
					uv.append(_uv[i])
					uv2.append(_uv2[i])
				idx.append(at)
		if idx.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = n
		arrays[Mesh.ARRAY_COLOR] = c
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_INDEX] = idx
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		m.surface_set_material(m.get_surface_count() - 1, card_mat if pass_i == 1 else mat)
	return m


# ------------------------------------------------------------------------------------------
# Primitive helpers
# ------------------------------------------------------------------------------------------

func _shade(col: Color, amount := 0.12) -> Color:
	var f := 1.0 - _rng.randf() * amount
	return Color(col.r * f, col.g * f, col.b * f, col.a)


## Triangle with a flat normal pointing away from `center` (Godot front faces are clockwise).
func _tri(a: Vector3, b: Vector3, c: Vector3, col: Color, center: Vector3, emit := 0.0) -> void:
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-14:
		return
	n = n.normalized()
	if n.dot((a + b + c) / 3.0 - center) < 0.0:
		var t := b
		b = c
		c = t
		n = -n
	_push(a, n, col, emit)
	_push(b, n, col, emit)
	_push(c, n, col, emit)


func _push(p: Vector3, n: Vector3, col: Color, emit: float, uv2 := Vector2.ZERO) -> void:
	_v.append(p)
	_n.append(n)
	_c.append(col)
	_uv.append(Vector2(emit, _kind))
	_uv2.append(uv2)


## Triangle with per-vertex normals and colors; winding fixed so it faces away from `center`.
func _tri_n(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3,
		ca: Color, cb: Color, cc: Color, center: Vector3) -> void:
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-14:
		return
	if n.dot((a + b + c) / 3.0 - center) < 0.0:
		_push(a, na, ca, 0.0)
		_push(c, nc, cc, 0.0)
		_push(b, nb, cb, 0.0)
	else:
		_push(a, na, ca, 0.0)
		_push(b, nb, cb, 0.0)
		_push(c, nc, cc, 0.0)


## Unit icosphere: [points, faces]; subdiv 0 = 20 faces, 1 = 80.
static func _ico(subdiv: int) -> Array:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var pts: Array[Vector3] = [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2],
		[10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11],
		[6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for s in subdiv:
		var mids := {}
		var sub := []
		for f in faces:
			var m := []
			for e in 3:
				var a: int = f[e]
				var b: int = f[(e + 1) % 3]
				var key := mini(a, b) * 100000 + maxi(a, b)
				if not mids.has(key):
					mids[key] = pts.size()
					pts.append((pts[a] + pts[b]) * 0.5)
				m.append(mids[key])
			sub.append([f[0], m[0], m[2]])
			sub.append([f[1], m[1], m[0]])
			sub.append([f[2], m[2], m[1]])
			sub.append([m[0], m[1], m[2]])
		faces = sub
	for i in pts.size():
		pts[i] = pts[i].normalized()
	return [pts, faces]


## Leaf clump inside a tree crown. Normals blend the clump's own ellipsoid normal with the whole
## crown's, so a cluster of clumps shades like one soft volume with lumpy edges instead of a facet
## mosaic. Vertex color darkens toward the bottom and the inside of the crown (cheap AO).
func _clump(center: Vector3, radii: Vector3, crown_c: Vector3, crown_r: Vector3, subdiv := 1, jitter := 0.14, dark := 1.0) -> void:
	var ico := _ico(subdiv)
	var pts: Array = ico[0]
	var wp: Array[Vector3] = []
	var nn: Array[Vector3] = []
	var cc: Array[Color] = []
	for p: Vector3 in pts:
		var u := p * (1.0 + (_rng.randf() * 2.0 - 1.0) * jitter)
		var q := center + Vector3(u.x * radii.x, u.y * radii.y, u.z * radii.z)
		var n_own := Vector3(p.x / radii.x, p.y / radii.y, p.z / radii.z).normalized()
		var rel := (q - crown_c)
		var n_crown := Vector3(rel.x / (crown_r.x * crown_r.x), rel.y / (crown_r.y * crown_r.y), rel.z / (crown_r.z * crown_r.z)).normalized()
		nn.append((n_own * 0.4 + n_crown * 0.6).normalized())
		var rn := Vector3(rel.x / crown_r.x, rel.y / crown_r.y, rel.z / crown_r.z)
		var ao := clampf(0.5 + 0.32 * (rn.y * 0.5 + 0.5) + 0.25 * minf(rn.length(), 1.0), 0.45, 1.0)
		ao *= (1.0 - _rng.randf() * 0.05) * dark
		cc.append(Color(ao, ao, ao, 1.0))
		wp.append(q)
	for f in ico[1]:
		var a: int = f[0]
		var b: int = f[1]
		var c: int = f[2]
		_tri_n(wp[a], wp[b], wp[c], nn[a], nn[b], nn[c], cc[a], cc[b], cc[c], center)


## A crown: a few large clumps around the center plus smaller ones scattered over the envelope.
func _crown(c: Vector3, r: Vector3, big: int, small: int, small_r: float) -> void:
	_kind = LEAF
	for i in big:
		var a := TAU * float(i) / float(maxi(big, 1)) + _rng.randf() * 0.8
		var off := Vector3(cos(a) * r.x * 0.32, (_rng.randf() - 0.35) * r.y * 0.35, sin(a) * r.z * 0.32) if i > 0 else Vector3(0, r.y * 0.1, 0)
		var s := 0.62 + _rng.randf() * 0.12
		_clump(c + off, r * s, c, r, 1, 0.12)
	for i in small:
		var a := TAU * (float(i) + _rng.randf() * 0.6) / float(maxi(small, 1))
		var y := lerpf(-0.45, 0.85, _rng.randf())
		var d := Vector3(cos(a) * sqrt(1.0 - y * y), y, sin(a) * sqrt(1.0 - y * y))
		var p := c + Vector3(d.x * r.x, d.y * r.y, d.z * r.z) * 0.72
		var s := small_r * (0.8 + _rng.randf() * 0.4)
		_clump(p, Vector3(s, s * 0.82, s), c, r, 0, 0.16)
	_kind = 0.0


## Pine tier: a cone skirt with smooth normals and a jagged, drooping hem, darker underneath.
func _tier(base_y: float, r: float, h: float, sides: int, rot: float, droop: float, dark := 1.0, under_k := 0.42) -> void:
	_kind = LEAF
	var top := Vector3(0, base_y + h, 0)
	var center := Vector3(0, base_y + h * 0.3, 0)
	var ring: Array[Vector3] = []
	var rn: Array[Vector3] = []
	for i in sides:
		var a := rot + TAU * float(i) / float(sides)
		var tip := i % 2 == 0
		var rr := r * (1.0 if tip else 0.72) * (0.92 + _rng.randf() * 0.16)
		var y := base_y - (droop if tip else 0.0)
		ring.append(Vector3(cos(a) * rr, y, sin(a) * rr))
		rn.append(Vector3(cos(a) * h, r * 1.1, sin(a) * h).normalized())
	var lit := Color(dark, dark, dark, 1)
	var hem := Color(0.66 * dark, 0.66 * dark, 0.66 * dark, 1)
	var under := Color(under_k * dark, under_k * dark, under_k * dark, 1)
	var hub := Vector3(0, base_y + h * 0.18, 0)
	for i in sides:
		var j := (i + 1) % sides
		var nt := (rn[i] + rn[j] + Vector3.UP * 1.5).normalized()
		_tri_n(ring[i], ring[j], top, rn[i], rn[j], nt, hem, hem, lit, center)
		# Underside: shallow cone up to a hub on the trunk.
		var nd := Vector3.DOWN
		_tri_n(ring[j], ring[i], hub, nd, nd, nd, under, under, under, center + Vector3(0, h * 2.0, 0))
	_kind = 0.0


static func _frame(axis: Vector3) -> Basis:
	var ref := Vector3.FORWARD if absf(axis.y) > 0.9 else Vector3.UP
	var x := ref.cross(axis).normalized()
	var z := x.cross(axis).normalized()
	return Basis(x, axis, z)


## Tapered prism along `axis` (cone when r1 == 0).
func _frustum(base: Vector3, axis: Vector3, r0: float, r1: float, h: float, sides: int, col: Color,
		cap_bottom := false, emit := 0.0, rot := 0.0) -> void:
	axis = axis.normalized()
	var fb := _frame(axis)
	var top := base + axis * h
	var center := base + axis * (h * 0.4)
	for i in sides:
		var a0 := rot + TAU * i / sides
		var a1 := rot + TAU * (i + 1) / sides
		var d0 := fb.x * cos(a0) + fb.z * sin(a0)
		var d1 := fb.x * cos(a1) + fb.z * sin(a1)
		var p0 := base + d0 * r0
		var p1 := base + d1 * r0
		var fc := _shade(col)
		if r1 > 0.001:
			var q0 := top + d0 * r1
			var q1 := top + d1 * r1
			_tri(p0, p1, q1, fc, center, emit)
			_tri(p0, q1, q0, fc, center, emit)
			_tri(top, q0, q1, fc, center, emit)
		else:
			_tri(p0, p1, top, fc, center, emit)
		if cap_bottom:
			_tri(base, p1, p0, _shade(col), center, emit)


## Jittered low-poly ellipsoid (icosphere, 1 subdivision = 80 faces), flat shaded.
func _blob(center: Vector3, radii: Vector3, col: Color, jitter := 0.15, emit := 0.0, flat_bottom := -2.0, shade := 0.18) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var pts: Array[Vector3] = [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2],
		[10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11],
		[6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var mids := {}
	var sub := []
	for f in faces:
		var m := []
		for e in 3:
			var a: int = f[e]
			var b: int = f[(e + 1) % 3]
			var key := mini(a, b) * 1000 + maxi(a, b)
			if not mids.has(key):
				mids[key] = pts.size()
				pts.append((pts[a] + pts[b]) * 0.5)
			m.append(mids[key])
		sub.append([f[0], m[0], m[2]])
		sub.append([f[1], m[1], m[0]])
		sub.append([f[2], m[2], m[1]])
		sub.append([m[0], m[1], m[2]])
	var wp: Array[Vector3] = []
	for p in pts:
		var u := p.normalized() * (1.0 + (_rng.randf() * 2.0 - 1.0) * jitter)
		var q := Vector3(u.x * radii.x, u.y * radii.y, u.z * radii.z)
		q.y = maxf(q.y, flat_bottom * radii.y)
		wp.append(center + q)
	for f in sub:
		_tri(wp[f[0]], wp[f[1]], wp[f[2]], _shade(col, shade), center, emit)


## Double-sided drooping leaf strip (palm frond).
func _frond(start: Vector3, dir: Vector3, length: float, width: float, droop: float, col: Color) -> void:
	var side := dir.cross(Vector3.UP).normalized()
	var segs := 5
	var prev_c := start
	var prev_l := start
	var prev_r := start
	for k in range(1, segs + 1):
		var f := float(k) / segs
		var c := start + dir * (length * f) + Vector3.DOWN * (droop * f * f)
		var w := width * sin(PI * minf(f * 1.15, 1.0)) * 0.5
		var l := c + side * w + Vector3.DOWN * (w * 0.35)
		var r := c - side * w + Vector3.DOWN * (w * 0.35)
		var below := c + Vector3.DOWN * 5.0
		var fc := _shade(col)
		_tri(prev_l, l, c, fc, below)
		_tri(prev_l, c, prev_c, fc, below)
		_tri(prev_c, c, r, fc, below)
		_tri(prev_c, r, prev_r, fc, below)
		prev_c = c
		prev_l = l
		prev_r = r


# ------------------------------------------------------------------------------------------
# Near-range helpers: cards, smooth trunks, strips, boulders
# ------------------------------------------------------------------------------------------

## Atlas tile rect (flora_textures.gd: 0, 1 leaf clusters, 2 pine branch, 3 palm frond).
static func _tile_uv(tile: int, u: float, v: float) -> Vector2:
	var o := Vector2(float(tile % 2) * 0.5, float(tile / 2) * 0.5)
	return o + Vector2(lerpf(0.006, 0.494, u), lerpf(0.006, 0.494, v))


## Crown-volume normal at `q`: the ellipsoid normal around the crown, tipped up a little, so cards
## shade like one soft mass (lit top, shaded underside) instead of flat quads.
static func _crown_n(q: Vector3, c: Vector3, r: Vector3) -> Vector3:
	var rel := q - c
	var n := Vector3(rel.x / (r.x * r.x), rel.y / (r.y * r.y), rel.z / (r.z * r.z)).normalized()
	return (n + Vector3.UP * 0.25).normalized()


## One alpha-tested leaf card: quad at `p` spanned by `ax` / `ay` (unit), w x h, atlas `tile`.
func _card(p: Vector3, ax: Vector3, ay: Vector3, w: float, h: float, tile: int, col: Color,
		crown_c: Vector3, crown_r: Vector3) -> void:
	var k0 := _kind
	_kind = CARD
	var q := [p - ax * w * 0.5 - ay * h * 0.5, p + ax * w * 0.5 - ay * h * 0.5,
			p + ax * w * 0.5 + ay * h * 0.5, p - ax * w * 0.5 + ay * h * 0.5]
	var uv := [_tile_uv(tile, 0, 1), _tile_uv(tile, 1, 1), _tile_uv(tile, 1, 0), _tile_uv(tile, 0, 0)]
	var nn: Array[Vector3] = []
	for v: Vector3 in q:
		nn.append(_crown_n(v, crown_c, crown_r))
	for tri in [[0, 1, 2], [0, 2, 3]]:
		for i: int in tri:
			_push(q[i], nn[i], col, 0.0, uv[i])
	_kind = k0


## Crown of leaf cards around a dark core: cards sit in the outer shell (denser on top), face
## roughly outward with a random roll, and darken toward the bottom / inside.
func _card_crown(c: Vector3, r: Vector3, n: int, size: float, core := 0.66) -> void:
	_kind = LEAF
	_clump(c - Vector3(0, r.y * 0.08, 0), r * core, c, r, 1, 0.1, 0.62)
	for i in n:
		var y := lerpf(-0.55, 1.0, pow(_rng.randf(), 0.8))
		var a := _rng.randf() * TAU
		var d := Vector3(cos(a) * sqrt(1.0 - y * y), y, sin(a) * sqrt(1.0 - y * y))
		var k := lerpf(0.62, 1.02, sqrt(_rng.randf()))
		var p := c + Vector3(d.x * r.x, d.y * r.y, d.z * r.z) * k
		var out := Vector3(d.x / r.x, d.y / r.y, d.z / r.z).normalized()
		var face := (out + Vector3(_rng.randf_range(-0.6, 0.6), _rng.randf_range(-0.3, 0.7), _rng.randf_range(-0.6, 0.6))).normalized()
		var ref := Vector3.UP if absf(face.y) < 0.95 else Vector3.RIGHT
		var ax := face.cross(ref).normalized().rotated(face, _rng.randf() * TAU)
		var ay := face.cross(ax).normalized()
		var s := size * _rng.randf_range(0.8, 1.25)
		var ao := clampf(0.5 + 0.32 * (d.y * 0.5 + 0.5) + 0.22 * k, 0.5, 1.0) * (1.0 - _rng.randf() * 0.06)
		_card(p, ax, ay, s, s, 0 if _rng.randf() < 0.6 else 1, Color(ao, ao, ao, 1.0), c, r)
	_kind = 0.0


## Smooth tapered trunk / branch: `segs` rings of `sides` vertices with radial normals, a gentle
## bend (`curve` added at the top, quadratic), root flare at the base. Bark detail is in the shader.
func _trunk(base: Vector3, axis: Vector3, r0: float, r1: float, h: float, sides: int, segs: int,
		col: Color, curve := Vector3.ZERO, flare := 0.3) -> void:
	var k0 := _kind
	_kind = WOOD
	axis = axis.normalized()
	var fb := _frame(axis)
	var rings: Array = []
	var norms: Array = []
	for s in segs + 1:
		var t := float(s) / float(segs)
		var cen := base + axis * (h * t) + curve * (t * t)
		var r := lerpf(r0, r1, t) * (1.0 + flare * pow(1.0 - t, 6.0))
		var ring: Array[Vector3] = []
		var rn: Array[Vector3] = []
		for i in sides:
			var a := TAU * float(i) / float(sides)
			var d := fb.x * cos(a) + fb.z * sin(a)
			ring.append(cen + d * r * (1.0 + (_rng.randf() - 0.5) * 0.06))
			rn.append(d)
		rings.append(ring)
		norms.append(rn)
	for s in segs:
		var cc := base + axis * (h * (float(s) + 0.5) / float(segs)) + curve * pow((float(s) + 0.5) / float(segs), 2.0)
		var shade := lerpf(0.82, 1.0, float(s) / float(maxi(segs, 1)))
		var ca := Color(col.r * shade, col.g * shade, col.b * shade, col.a)
		for i in sides:
			var j := (i + 1) % sides
			var a: Vector3 = rings[s][i]
			var b: Vector3 = rings[s][j]
			var c2: Vector3 = rings[s + 1][j]
			var d2: Vector3 = rings[s + 1][i]
			_tri_n(a, b, c2, norms[s][i], norms[s][j], norms[s + 1][j], ca, ca, ca, cc)
			_tri_n(a, c2, d2, norms[s][i], norms[s + 1][j], norms[s + 1][i], ca, ca, ca, cc)
	_kind = k0


## Textured strip along `pts` (needle branch / palm frond): width `w`, atlas tile, u along the strip.
## `side` gives the strip's width direction at each point; normals = `nrm` (volume-ish).
func _strip(pts: Array, side: Vector3, w: float, tile: int, col: Color, nrm: Vector3) -> void:
	var k0 := _kind
	_kind = CARD
	var n := pts.size()
	for i in n - 1:
		var p0: Vector3 = pts[i]
		var p1: Vector3 = pts[i + 1]
		var u0 := float(i) / float(n - 1)
		var u1 := float(i + 1) / float(n - 1)
		var a := p0 - side * w * 0.5
		var b := p0 + side * w * 0.5
		var c2 := p1 + side * w * 0.5
		var d := p1 - side * w * 0.5
		var shade0 := lerpf(0.72, 1.0, u0)
		var shade1 := lerpf(0.72, 1.0, u1)
		var c0 := Color(col.r * shade0, col.g * shade0, col.b * shade0, col.a)
		var c1 := Color(col.r * shade1, col.g * shade1, col.b * shade1, col.a)
		_push(a, nrm, c0, 0.0, _tile_uv(tile, u0, 0.0))
		_push(b, nrm, c0, 0.0, _tile_uv(tile, u0, 1.0))
		_push(c2, nrm, c1, 0.0, _tile_uv(tile, u1, 1.0))
		_push(a, nrm, c0, 0.0, _tile_uv(tile, u0, 0.0))
		_push(c2, nrm, c1, 0.0, _tile_uv(tile, u1, 1.0))
		_push(d, nrm, c1, 0.0, _tile_uv(tile, u1, 0.0))
	_kind = k0


## Weathered boulder: icosphere `subdiv` displaced by layered noise (rounded, with a few flatter
## faces), squashed, flat-ish bottom, smooth area-weighted normals. Same seed → same shape at both
## detail levels.
func _boulder(subdiv: int) -> void:
	_kind = STONE
	var ico := _ico(subdiv)
	var pts: Array = ico[0]
	var faces: Array = ico[1]
	var nz := FastNoiseLite.new()
	nz.seed = 1234
	nz.frequency = 0.9
	nz.fractal_octaves = 3
	var wp: Array[Vector3] = []
	for p: Vector3 in pts:
		var d := nz.get_noise_3dv(p * 1.2) * 0.3 + nz.get_noise_3dv(p * 3.3 + Vector3(7, 3, 1)) * 0.07
		# Terracing: a soft quantisation of the radius gives a few flatter, broken faces.
		var r := 1.0 + d
		r = lerpf(r, roundf(r * 6.0) / 6.0, 0.35)
		var q := p * r
		q = Vector3(q.x * 1.05, q.y * 0.74, q.z * 0.95)
		q.y = maxf(q.y, -0.38) + 0.1
		wp.append(q)
	var acc: Array[Vector3] = []
	acc.resize(wp.size())
	for i in acc.size():
		acc[i] = Vector3.ZERO
	for f in faces:
		var a: int = f[0]
		var b: int = f[1]
		var c: int = f[2]
		var fn := (wp[b] - wp[a]).cross(wp[c] - wp[a])
		if fn.dot((wp[a] + wp[b] + wp[c]) / 3.0) < 0.0:
			fn = -fn
		acc[a] += fn
		acc[b] += fn
		acc[c] += fn
	var white := Color(1, 1, 1, 1)
	for f in faces:
		var a: int = f[0]
		var b: int = f[1]
		var c: int = f[2]
		_tri_n(wp[a], wp[b], wp[c], acc[a].normalized(), acc[b].normalized(), acc[c].normalized(),
				white, white, white, Vector3(0, 0.1, 0))
	_kind = 0.0


# ------------------------------------------------------------------------------------------
# Near-range plants
# ------------------------------------------------------------------------------------------

func _broadleaf_near() -> void:
	_trunk(Vector3.ZERO, Vector3.UP, 0.3, 0.15, 3.6, 10, 4, BARK, Vector3(0.12, 0, 0.05))
	_trunk(Vector3(0.05, 2.2, 0), Vector3(0.8, 1.0, 0.3), 0.12, 0.05, 1.9, 7, 2, BARK, Vector3(0, 0.15, 0), 0.0)
	_trunk(Vector3(0.05, 2.5, 0), Vector3(-0.7, 1.0, -0.5), 0.11, 0.05, 1.8, 7, 2, BARK, Vector3(0, 0.15, 0), 0.0)
	_trunk(Vector3(0.1, 2.9, 0), Vector3(0.1, 1.0, 0.9), 0.1, 0.04, 1.5, 6, 2, BARK, Vector3.ZERO, 0.0)
	_card_crown(Vector3(0, 4.6, 0), Vector3(2.6, 2.05, 2.6), 105, 1.9)


func _jungle_near() -> void:
	_trunk(Vector3.ZERO, Vector3.UP, 0.6, 0.3, 10.2, 12, 6, BARK, Vector3(0.3, 0, -0.2), 0.45)
	for k in 5:
		var a := TAU * k / 5.0 + 0.4
		var out := Vector3(cos(a), 0.0, sin(a))
		_trunk(out * 0.25 + Vector3(0, 1.6, 0), out * 0.9 + Vector3(0, -0.7, 0), 0.24, 0.07, 2.0, 7, 2, BARK, Vector3.ZERO, 0.0)
	_trunk(Vector3(0, 7.5, 0), Vector3(1.0, 0.8, 0.4), 0.17, 0.07, 2.6, 7, 2, BARK, Vector3(0, 0.3, 0), 0.0)
	_trunk(Vector3(0, 8.0, 0), Vector3(-0.9, 0.7, -0.6), 0.16, 0.07, 2.5, 7, 2, BARK, Vector3(0, 0.3, 0), 0.0)
	_card_crown(Vector3(0, 10.4, 0), Vector3(4.4, 1.9, 4.4), 160, 2.5, 0.6)


func _bush_near() -> void:
	_card_crown(Vector3(0, 0.55, 0), Vector3(0.95, 0.66, 0.95), 30, 0.95, 0.6)


## Conifer: smooth trunk, per tier a thin dark core cone plus drooping needle-branch cards.
func _pine_near() -> void:
	_trunk(Vector3.ZERO, Vector3.UP, 0.25, 0.05, 6.0, 9, 5, BARK, Vector3(0.05, 0, 0.03), 0.25)
	var tiers := [[0.9, 2.15, 1.9], [1.75, 1.85, 1.75], [2.6, 1.55, 1.6], [3.4, 1.25, 1.45], [4.15, 0.95, 1.3], [4.85, 0.62, 1.25], [5.45, 0.36, 0.9]]
	for i in tiers.size():
		var t: Array = tiers[i]
		var base_y: float = t[0]
		var rr: float = t[1]
		var hh: float = t[2]
		_tier(base_y + 0.15, rr * 0.6, hh * 0.85, 8, i * 0.71, 0.1, 0.78, 0.7)
		var n := 12 if i < 3 else (10 if i < 5 else 7)
		for b in n:
			var a := i * 0.71 + TAU * (float(b) + _rng.randf() * 0.35) / float(n)
			var dir := Vector3(cos(a), 0.0, sin(a))
			var L := rr * _rng.randf_range(0.95, 1.12)
			var droop := L * _rng.randf_range(0.28, 0.42)
			var y := base_y + hh * _rng.randf_range(0.15, 0.45)
			var pts: Array = []
			for s in 4:
				var f := float(s) / 3.0
				pts.append(Vector3(0, y, 0) + dir * (0.08 + L * f) + Vector3.DOWN * (droop * f * f) + Vector3.UP * (0.12 * f))
			var side := dir.cross(Vector3.UP).normalized()
			var ao := lerpf(0.66, 1.0, float(i) / float(tiers.size() - 1)) * _rng.randf_range(0.92, 1.0)
			_strip(pts, side, L * 1.3, 2, Color(ao, ao, ao, 1.0), (Vector3.UP * 0.75 + dir * 0.45).normalized())


func _palm_near() -> void:
	_trunk(Vector3.ZERO, Vector3.UP, 0.24, 0.16, 7.0, 9, 7, Color(0.44, 0.35, 0.23, 0.0), Vector3(1.7, 0, 0), 0.2)
	var top := Vector3(1.7, 7.0, 0.0)
	var leaf := Color(1, 1, 1, 1)
	for k in 10:
		var a := TAU * k / 10.0 + _rng.randf() * 0.3
		var dir := Vector3(cos(a), 0.0, sin(a))
		var L := _rng.randf_range(3.2, 3.9)
		var rise := _rng.randf_range(0.35, 0.8)
		var pts: Array = []
		for s in 6:
			var f := float(s) / 5.0
			pts.append(top + Vector3(0, 0.1, 0) + dir * (L * f) + Vector3.UP * (rise * f) + Vector3.DOWN * (2.2 * f * f))
		_strip(pts, dir.cross(Vector3.UP).normalized(), 2.3, 3, leaf, (Vector3.UP * 0.8 + dir * 0.4).normalized())
	for k in 3:
		var a := TAU * k / 3.0
		_blob(top + Vector3(cos(a) * 0.25, -0.25, sin(a) * 0.25), Vector3.ONE * 0.16, Color(0.36, 0.26, 0.12, 0.0), 0.05)


func _rock_near() -> void:
	_boulder(2)


# ------------------------------------------------------------------------------------------
# Plants
# ------------------------------------------------------------------------------------------

func _pine() -> void:
	_frustum(Vector3.ZERO, Vector3.UP, 0.22, 0.06, 5.6, 6, BARK)
	# Six drooping tiers, narrowing upward, each turned so the hem tips do not line up.
	var tiers := [[0.9, 2.05, 1.9], [1.75, 1.75, 1.75], [2.6, 1.45, 1.6], [3.4, 1.15, 1.45], [4.15, 0.85, 1.3], [4.85, 0.55, 1.25]]
	for i in tiers.size():
		var t: Array = tiers[i]
		_tier(t[0], t[1], t[2], 10, i * 0.71, 0.32 * t[1] / 2.0)


func _broadleaf() -> void:
	_frustum(Vector3.ZERO, Vector3.UP, 0.27, 0.16, 3.3, 7, BARK)
	_frustum(Vector3(0, 2.3, 0), Vector3(0.8, 1.0, 0.3), 0.11, 0.05, 1.7, 5, BARK)
	_frustum(Vector3(0, 2.6, 0), Vector3(-0.7, 1.0, -0.5), 0.1, 0.05, 1.6, 5, BARK)
	_crown(Vector3(0, 4.6, 0), Vector3(2.6, 2.05, 2.6), 3, 8, 0.95)


func _palm() -> void:
	var prev := Vector3.ZERO
	var segs := 7
	for i in range(1, segs + 1):
		var p := Vector3(0.035 * i * i, i * 1.0, 0.0)
		var ring := Color(0.48, 0.38, 0.25, 0.0) if i % 2 == 0 else Color(0.40, 0.31, 0.21, 0.0)
		_frustum(prev, p - prev, 0.22 - i * 0.012, 0.2 - i * 0.012, (p - prev).length(), 6, ring)
		prev = p
	var leaf := Color(1, 1, 1, 1)
	for k in 8:
		var a := TAU * k / 8.0 + _rng.randf() * 0.3
		var dir := Vector3(cos(a), 0.45, sin(a)).normalized()
		_frond(prev + Vector3(0, 0.1, 0), dir, 3.4, 0.9, 1.9, leaf)
	for k in 3:
		var a := TAU * k / 3.0
		_blob(prev + Vector3(cos(a) * 0.25, -0.25, sin(a) * 0.25), Vector3.ONE * 0.16, Color(0.36, 0.26, 0.12, 0.0), 0.05)


func _jungle() -> void:
	_frustum(Vector3.ZERO, Vector3.UP, 0.55, 0.3, 10.0, 8, BARK)
	for k in 4:
		var a := TAU * k / 4.0 + 0.4
		var out := Vector3(cos(a), 0.0, sin(a))
		_frustum(out * 0.25 + Vector3(0, 1.4, 0), out * 0.8 + Vector3(0, -0.6, 0), 0.22, 0.08, 1.9, 5, BARK)
	_frustum(Vector3(0, 7.5, 0), Vector3(1.0, 0.8, 0.4), 0.16, 0.08, 2.4, 5, BARK)
	_frustum(Vector3(0, 8.0, 0), Vector3(-0.9, 0.7, -0.6), 0.15, 0.08, 2.3, 5, BARK)
	_crown(Vector3(0, 10.4, 0), Vector3(4.4, 1.8, 4.4), 3, 9, 1.3)


func _cactus() -> void:
	var body := Color(1, 1, 1, 1)
	_frustum(Vector3.ZERO, Vector3.UP, 0.33, 0.29, 3.0, 8, body)
	_blob(Vector3(0, 3.0, 0), Vector3(0.29, 0.25, 0.29), body, 0.03)
	_frustum(Vector3(0.2, 1.3, 0), Vector3.RIGHT, 0.18, 0.18, 0.6, 7, body)
	_frustum(Vector3(0.72, 1.3, 0), Vector3.UP, 0.19, 0.17, 1.1, 7, body, true)
	_blob(Vector3(0.72, 2.4, 0), Vector3(0.17, 0.15, 0.17), body, 0.03)
	_frustum(Vector3(-0.2, 1.8, 0), Vector3.LEFT, 0.16, 0.16, 0.5, 7, body)
	_frustum(Vector3(-0.62, 1.8, 0), Vector3.UP, 0.17, 0.15, 0.75, 7, body, true)
	_blob(Vector3(-0.62, 2.55, 0), Vector3(0.15, 0.13, 0.15), body, 0.03)
	_blob(Vector3(0, 3.22, 0), Vector3(0.12, 0.08, 0.12), Color(0.95, 0.35, 0.55, 0.0), 0.1)


func _dead() -> void:
	var wood := Color(1, 1, 1, 1)
	_frustum(Vector3.ZERO, Vector3(0.05, 1, 0), 0.2, 0.12, 2.4, 6, wood)
	_frustum(Vector3(0.12, 2.35, 0), Vector3(-0.08, 1, 0.05), 0.12, 0.05, 2.0, 6, wood)
	var branches := [[1.6, 0.3, 1.5], [2.2, 2.4, 1.3], [2.8, 4.2, 1.1], [3.4, 1.2, 0.9], [1.1, 5.2, 1.0]]
	for br in branches:
		var a: float = br[1]
		var dir := Vector3(cos(a), 0.9, sin(a))
		_frustum(Vector3(0.06, br[0], 0), dir, 0.07, 0.02, br[2], 4, wood)


func _mushroom() -> void:
	_frustum(Vector3.ZERO, Vector3(0.1, 1, 0), 0.32, 0.22, 2.5, 7, PALE)
	_frustum(Vector3(0.25, 2.45, 0), Vector3(-0.05, 1, 0.05), 0.22, 0.18, 2.3, 7, PALE)
	var top := Vector3(0.14, 4.7, 0.1)
	var cap := Color(1, 1, 1, 1)
	_blob(top + Vector3(0, 0.35, 0), Vector3(2.3, 0.95, 2.3), cap, 0.1, 0.35, -0.15)
	_frustum(top + Vector3(0, 0.2, 0), Vector3.DOWN, 2.0, 0.25, 0.55, 12, Color(0.75, 0.75, 0.75, 1.0), false, 0.9)
	for k in 6:
		var a := TAU * k / 6.0 + 0.3
		var rr := 1.1 + (k % 2) * 0.55
		_blob(top + Vector3(cos(a) * rr, 0.95 - rr * 0.22, sin(a) * rr), Vector3(0.22, 0.12, 0.22),
				Color(0.95, 0.95, 0.9, 0.0), 0.05, 0.6)


func _bush() -> void:
	_crown(Vector3(0, 0.5, 0), Vector3(0.9, 0.6, 0.9), 2, 5, 0.38)


func _rock() -> void:
	_boulder(1)          # far: same shape as the near version, fewer faces


func _grass() -> void:
	# Curved blades (two segments: a quad to the bend, then the tip), dark at the root, light at the
	# tip, each a slightly different shade. Normals lean up so they light like the ground they grow on.
	for k in 12:
		var a := TAU * k / 12.0 + _rng.randf() * 0.5
		var out := Vector3(cos(a), 0, sin(a))
		var base := out * (0.03 + _rng.randf() * 0.12)
		var h := 0.26 + _rng.randf() * 0.4
		var lean := 0.08 + _rng.randf() * 0.2
		var side := out.cross(Vector3.UP).normalized() * (0.02 + _rng.randf() * 0.014)
		var mid := base + out * (lean * 0.3) + Vector3(0, h * 0.58, 0)
		var tip := base + out * lean + Vector3(0, h, 0)
		var n := (Vector3.UP * 2.0 + out * 0.6).normalized()
		var lum := _rng.randf_range(0.82, 1.08)
		var dark := Color(0.42 * lum, 0.42 * lum, 0.42 * lum, 1.0)
		var midc := Color(0.74 * lum, 0.74 * lum, 0.74 * lum, 1.0)
		var lite := Color(minf(1.0 * lum, 1.0), minf(1.0 * lum, 1.0), minf(0.96 * lum, 1.0), 1.0)
		var ms := side * 0.75
		_push(base - side, n, dark, 0.0)
		_push(mid - ms, n, midc, 0.0)
		_push(base + side, n, dark, 0.0)
		_push(base + side, n, dark, 0.0)
		_push(mid - ms, n, midc, 0.0)
		_push(mid + ms, n, midc, 0.0)
		_push(mid - ms, n, midc, 0.0)
		_push(tip, n, lite, 0.0)
		_push(mid + ms, n, midc, 0.0)


func _flower() -> void:
	var stem := Color(0.25, 0.45, 0.13, 0.0)
	for k in 3:
		var a := TAU * k / 3.0 + _rng.randf()
		var base := Vector3(cos(a), 0, sin(a)) * (0.12 + 0.08 * k)
		var h := 0.3 + _rng.randf() * 0.2
		var top := base + Vector3(0, h, 0)
		var s := Vector3(0.02, 0, 0)
		_push(base - s, Vector3.UP, stem, 0.0)
		_push(top, Vector3.UP, stem, 0.0)
		_push(base + s, Vector3.UP, stem, 0.0)
		_push(base - s.rotated(Vector3.UP, 1.57), Vector3.UP, stem, 0.0)
		_push(top, Vector3.UP, stem, 0.0)
		_push(base + s.rotated(Vector3.UP, 1.57), Vector3.UP, stem, 0.0)
		var petal := Color(1, 1, 1, 1)
		for p in 5:
			var pa := TAU * p / 5.0
			var d0 := Vector3(cos(pa - 0.45), 0.25, sin(pa - 0.45)) * 0.09
			var d1 := Vector3(cos(pa + 0.45), 0.25, sin(pa + 0.45)) * 0.09
			var tipp := Vector3(cos(pa), 0.12, sin(pa)) * 0.13
			_push(top, Vector3.UP, petal, 0.0)
			_push(top + d0 + tipp * 0.3, Vector3.UP, petal, 0.0)
			_push(top + tipp, Vector3.UP, petal, 0.0)
			_push(top, Vector3.UP, petal, 0.0)
			_push(top + tipp, Vector3.UP, petal, 0.0)
			_push(top + d1 + tipp * 0.3, Vector3.UP, petal, 0.0)
		_blob(top + Vector3(0, 0.02, 0), Vector3(0.035, 0.025, 0.035), Color(1.0, 0.85, 0.2, 0.0), 0.0)


func _crystals() -> void:
	var col := Color(1, 1, 1, 1)
	for k in 6:
		var a := TAU * k / 6.0 + _rng.randf() * 0.6
		var tilt := 0.15 + _rng.randf() * 0.5
		var dir := Vector3(cos(a) * tilt, 1.0, sin(a) * tilt).normalized()
		var h := 0.5 + _rng.randf() * 1.0
		var r := 0.08 + _rng.randf() * 0.07
		var base := Vector3(cos(a), 0, sin(a)) * 0.12
		_frustum(base, dir, r, r * 0.9, h, 6, col, false, 1.0)
		_frustum(base + dir * h, dir, r * 0.9, 0.0, r * 2.2, 6, col, false, 1.0)


func _glow_shroom() -> void:
	for k in 3:
		var a := TAU * k / 3.0 + _rng.randf()
		var base := Vector3(cos(a), 0, sin(a)) * (0.1 + 0.07 * k)
		var h := 0.18 + _rng.randf() * 0.22
		_frustum(base, Vector3.UP, 0.035, 0.028, h, 5, Color(0.85, 0.9, 0.85, 1.0), false, 0.25)
		_blob(base + Vector3(0, h + 0.03, 0), Vector3(0.13, 0.07, 0.13) * (0.8 + k * 0.2), Color(1, 1, 1, 1), 0.08, 1.0, -0.2)


func _spire() -> void:
	# Giant crystal: a tall hexagonal prism with a pointed tip and a ring of smaller shards.
	var col := Color(1, 1, 1, 1)
	_frustum(Vector3.ZERO + Vector3(0, -0.5, 0), Vector3(0.05, 1, 0.03), 0.65, 0.55, 5.5, 6, col, false, 0.55)
	_frustum(Vector3(0.28, 4.98, 0.17), Vector3(0.05, 1, 0.03), 0.55, 0.0, 1.6, 6, col, false, 0.8)
	for k in 5:
		var a := TAU * k / 5.0 + _rng.randf() * 0.5
		var out := Vector3(cos(a), 0, sin(a))
		var dir := (Vector3.UP + out * (0.35 + _rng.randf() * 0.35)).normalized()
		var h := 1.4 + _rng.randf() * 2.2
		var r := 0.22 + _rng.randf() * 0.18
		var base := out * (0.55 + _rng.randf() * 0.3) + Vector3(0, -0.3, 0)
		_frustum(base, dir, r, r * 0.85, h, 6, col, false, 0.5)
		_frustum(base + dir * h, dir, r * 0.85, 0.0, r * 2.4, 6, col, false, 0.8)
