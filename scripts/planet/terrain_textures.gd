extends RefCounted
## Tileable close-range detail for the ground shaders (terrain.gdshader): a Texture2DArray with
## one layer per surface kind, baked once on the GPU (shaders/terrain_detail_gen.gdshader) and
## cached as PNGs in user://cache (rebaked when VERSION changes).
##   layers: 0 soil / grassy ground   1 rock   2 sand   3 snow
##   texel:  R albedo luminance factor (0.5 = unchanged), G/B height gradient (0.5 = flat,
##           +-GRAD_RANGE m/m), A cavity (1 open, low in cracks)
## Usage: TerrainTextures.request(node, func(tex): material.set_shader_parameter(...))
## The callback runs immediately when the cache exists, otherwise a frame or two later.

const VERSION := 3
const SIZE := 512
const LAYERS := 4
const TILE_M := 2.0           # meters per tile, must match terrain.gdshader detail_tile
const GRAD_RANGE := 2.5       # must match terrain.gdshader
const GEN_SHADER := preload("res://shaders/terrain_detail_gen.gdshader")

static var _tex: Texture2DArray
static var _waiting: Array[Callable] = []
static var _baking := false


static func request(owner: Node, cb: Callable) -> void:
	if _tex != null:
		cb.call(_tex)
		return
	var imgs := _load_cache()
	if imgs.size() == LAYERS:
		_tex = _make_array(imgs)
		cb.call(_tex)
		return
	_waiting.append(cb)
	if _baking or DisplayServer.get_name() == "headless":
		return
	_baking = true
	_bake(owner)


static func _path(i: int) -> String:
	return "user://cache/terrain_detail_v%d_%d.png" % [VERSION, i]


static func _load_cache() -> Array[Image]:
	var out: Array[Image] = []
	for i in LAYERS:
		if not FileAccess.file_exists(_path(i)):
			return []
		var img := Image.load_from_file(_path(i))
		if img == null or img.get_width() != SIZE:
			return []
		img.convert(Image.FORMAT_RGBA8)
		out.append(img)
	return out


static func _make_array(imgs: Array[Image]) -> Texture2DArray:
	for img in imgs:
		img.generate_mipmaps()
	var arr := Texture2DArray.new()
	arr.create_from_images(imgs)
	return arr


static func _bake(owner: Node) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var rect := ColorRect.new()
	rect.size = Vector2(SIZE, SIZE)
	var mat := ShaderMaterial.new()
	mat.shader = GEN_SHADER
	mat.set_shader_parameter("tile_m", TILE_M)
	mat.set_shader_parameter("grad_range", GRAD_RANGE)
	rect.material = mat
	vp.add_child(rect)
	owner.add_child(vp)
	var imgs: Array[Image] = []
	var t0 := Time.get_ticks_msec()
	for i in LAYERS:
		mat.set_shader_parameter("layer", i)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		imgs.append(img)
	vp.queue_free()
	DirAccess.make_dir_recursive_absolute("user://cache")
	for f in DirAccess.get_files_at("user://cache"):
		if f.begins_with("terrain_detail_v") and not f.begins_with("terrain_detail_v%d_" % VERSION):
			DirAccess.remove_absolute("user://cache/" + f)
	for i in LAYERS:
		imgs[i].save_png(_path(i))
	print("terrain detail baked in %d ms" % (Time.get_ticks_msec() - t0))
	_tex = _make_array(imgs)
	_baking = false
	var cbs := _waiting.duplicate()
	_waiting.clear()
	for cb: Callable in cbs:
		if cb.is_valid():
			cb.call(_tex)
