extends RefCounted
## Procedural foliage textures for the near-range vegetation (flora_meshes.gd cards), generated once
## and cached as PNG in user://cache (regenerated when VERSION changes). Grey-scale albedo with
## alpha: the hue comes from the vertex colour and the per-instance biome tint in foliage.gdshader.
##   atlas()  RGBA 512x512, four 256x256 tiles:
##            0 broadleaf cluster   1 broadleaf cluster (sparser, larger leaves)
##            2 pine branch (twig + needles, trunk side at u = 0)   3 palm frond (rachis + leaflets)
## Mipmapped; the shader lowers the alpha cut with distance so thin needles do not vanish.

const VERSION := 5
const SIZE := 512
const TILE := 256

static var _tex: Texture2D


static func atlas() -> Texture2D:
	if _tex != null:
		return _tex
	var path := "user://cache/flora_atlas_v%d.png" % VERSION
	var img: Image = null
	if FileAccess.file_exists(path):
		img = Image.load_from_file(path)
	if img == null or img.get_width() != SIZE:
		img = _build()
		DirAccess.make_dir_recursive_absolute("user://cache")
		for f in DirAccess.get_files_at("user://cache"):
			if f.begins_with("flora_atlas_v") and f != path.get_file():
				DirAccess.remove_absolute("user://cache/" + f)
		img.save_png(path)
	img.generate_mipmaps()
	_tex = ImageTexture.create_from_image(img)
	return _tex


# ------------------------------------------------------------------------------------------
# Raster helpers on a PackedByteArray (RGBA8): max-blend so overlapping leaves keep the brightest
# coverage, luminance written where the new shape is in front.
# ------------------------------------------------------------------------------------------

static var _buf := PackedByteArray()
static var _rng := RandomNumberGenerator.new()


static func _build() -> Image:
	# Transparent texels carry a mid grey so mip levels fade leaf edges toward grey, not black.
	var blank := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	blank.fill(Color(150.0 / 255.0, 150.0 / 255.0, 150.0 / 255.0, 0.0))
	_buf = blank.get_data()
	_rng.seed = 4242
	_leaf_cluster(Vector2i(0, 0), 64, 0.15, 0.06)
	_leaf_cluster(Vector2i(TILE, 0), 34, 0.21, 0.085)
	_pine_branch(Vector2i(0, TILE))
	_palm_frond(Vector2i(TILE, TILE))
	return Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, _buf)


## Leaf: pointed ellipse from `base` toward `dir` (pixels), width `w` (pixels), midrib darker.
## Stamped along its axis (cost ~ length x width, not its bounding box).
static func _leaf(o: Vector2i, base: Vector2, dir: Vector2, w: float, lum: float) -> void:
	var L := dir.length()
	if L < 1.0:
		return
	var ax := dir / L
	var px := Vector2(-ax.y, ax.x)
	var steps := int(L / 0.6) + 1
	for i in steps:
		var t := float(i) / float(steps - 1) if steps > 1 else 0.0
		var half := w * 0.5 * pow(sin(PI * clampf(t * 0.92 + 0.04, 0.0, 1.0)), 0.8) * (1.0 - t * 0.25)
		var c := base + dir * t
		var sn := int(half / 0.6) + 1
		for j in range(-sn, sn + 1):
			var s := float(j) * 0.6
			if absf(s) > half:
				continue
			var p := c + px * s
			var x := int(p.x)
			var y := int(p.y)
			if x < 0 or y < 0 or x >= TILE or y >= TILE:
				continue
			var shade := lum * (0.82 + 0.18 * (absf(s) / maxf(half, 0.5))) * (0.9 + 0.1 * t)
			if absf(s) < 0.9 and t < 0.9:
				shade *= 0.8                               # midrib
			_put(o, x, y, shade, 1.0 if absf(s) < half - 0.6 else 0.6)


static func _put(o: Vector2i, x: int, y: int, lum: float, a: float) -> void:
	var i := ((o.y + y) * SIZE + o.x + x) * 4
	var na := int(clampf(a, 0.0, 1.0) * 255.0)
	if na >= _buf[i + 3]:
		var v := int(clampf(lum, 0.0, 1.0) * 255.0)
		_buf[i] = v
		_buf[i + 1] = v
		_buf[i + 2] = v
		_buf[i + 3] = maxi(na, _buf[i + 3])


## Round cluster of leaves on short stems, darker toward the middle (self-shadowing).
static func _leaf_cluster(o: Vector2i, n: int, len_k: float, w_k: float) -> void:
	var c := Vector2(TILE, TILE) * 0.5
	for i in n:
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * TILE * 0.3
		var base := c + Vector2(cos(a), sin(a)) * r
		var ang := a + _rng.randf_range(-0.7, 0.7)
		var L := TILE * len_k * _rng.randf_range(0.85, 1.25)
		var tip := Vector2(cos(ang), sin(ang)) * L
		if (base + tip - c).length() > TILE * 0.48:
			tip *= (TILE * 0.48 - (base - c).length()) / maxf(L, 1.0)
		var lum := _rng.randf_range(0.62, 1.0) * lerpf(0.78, 1.0, r / (TILE * 0.3))
		_leaf(o, base, tip, TILE * w_k * _rng.randf_range(0.8, 1.15), lum)


## Conifer branch: twig along +u with needle pairs angled toward the tip, shorter at the tip.
static func _pine_branch(o: Vector2i) -> void:
	var y0 := TILE * 0.5
	for x in range(4, TILE - 6):
		for dy in range(-2, 3):
			_put(o, x, int(y0) + dy, 0.35, 1.0)
	# Side twigs first (they sit under the main needles): a full, flattened bough.
	for i in 9:
		var bx := TILE * (0.08 + i * 0.095)
		for side: float in [-1.0, 1.0]:
			var ang := deg_to_rad(_rng.randf_range(28.0, 48.0)) * side
			var L := TILE * lerpf(0.4, 0.18, bx / TILE) * _rng.randf_range(0.85, 1.1)
			var start := Vector2(bx, y0)
			var steps := 14
			for s in steps:
				var p := start + Vector2(cos(ang), sin(ang)) * L * (float(s) / float(steps))
				var n2 := L * (1.0 - float(s) / float(steps)) * 0.42 + 6.0
				for sd: float in [-1.0, 1.0]:
					var a2 := ang + deg_to_rad(_rng.randf_range(45.0, 70.0)) * sd
					_leaf(o, p, Vector2(cos(a2), sin(a2)) * n2, 3.2, _rng.randf_range(0.6, 0.92))
	# Main twig needles on top, brighter.
	for k in range(0, 3):
		var x := 6.0 + k * 1.1
		while x < TILE - 8:
			var t := x / TILE
			var L := lerpf(TILE * 0.2, TILE * 0.08, t) * _rng.randf_range(0.8, 1.15)
			for side: float in [-1.0, 1.0]:
				var ang := deg_to_rad(_rng.randf_range(38.0, 64.0)) * side
				_leaf(o, Vector2(x, y0), Vector2(cos(ang), sin(ang)) * L, 3.0, _rng.randf_range(0.72, 1.0))
			x += 3.2


## Palm frond: rachis along +u, long leaflets on both sides that sweep toward the tip.
static func _palm_frond(o: Vector2i) -> void:
	var y0 := TILE * 0.5
	for x in range(2, TILE - 4):
		for dy in range(-2, 3):
			_put(o, x, int(y0) + dy, 0.55, 1.0)
	var x := 10.0
	while x < TILE - 12:
		var t := x / TILE
		var L := TILE * 0.47 * sin(PI * clampf(t * 0.95 + 0.05, 0.0, 1.0))
		for side: float in [-1.0, 1.0]:
			var ang := deg_to_rad(68.0 - t * 20.0 + _rng.randf_range(-5.0, 5.0)) * side
			_leaf(o, Vector2(x, y0), Vector2(cos(ang), sin(ang)) * L, 8.5, _rng.randf_range(0.72, 1.0))
		x += 7.5

