extends SceneTree
## Bakes the terrain detail layers and writes a preview sheet: per layer, the lit height
## (from the gradient) times albedo/cavity, tiled 2x2 so seams show.
## `godot --path . -s res://tests/terrain_tex_dump.gd -- --out=<png>`

const TerrainTextures := preload("res://scripts/planet/terrain_textures.gd")

var _tex: Texture2DArray


func _initialize() -> void:
	var out := "user://terrain_detail.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var holder := Node.new()
	root.add_child(holder)
	await process_frame
	var t0 := Time.get_ticks_msec()
	TerrainTextures.request(holder, func(t): _tex = t)
	while _tex == null and Time.get_ticks_msec() - t0 < 10000:
		await process_frame
	if _tex == null:
		print("FAIL: no texture")
		quit(1)
		return
	print("detail ready after %d ms" % (Time.get_ticks_msec() - t0))
	var n := TerrainTextures.LAYERS
	var S := 256                       # preview each tile at half size, 2x2
	var sheet := Image.create(S * 2 * n, S * 2, false, Image.FORMAT_RGBA8)
	var L := Vector3(-0.5, -0.4, 0.75).normalized()
	for li in n:
		var img := _tex.get_layer_data(li)
		img.decompress()
		img.clear_mipmaps()
		img.resize(S, S, Image.INTERPOLATE_BILINEAR)
		for y in S:
			for x in S:
				var c := img.get_pixel(x, y)
				var g := Vector2(c.g * 2.0 - 1.0, c.b * 2.0 - 1.0) * TerrainTextures.GRAD_RANGE
				var nrm := Vector3(-g.x, -g.y, 1.0).normalized()
				var lit := clampf(nrm.dot(L), 0.0, 1.0) * 0.8 + 0.2
				var v := lit * (0.6 + 0.8 * c.r) * c.a * 0.75
				var col := Color(v, v, v)
				for ty in 2:
					for tx in 2:
						sheet.set_pixel(li * S * 2 + tx * S + x, ty * S + y, col)
	sheet.save_png(out)
	print("wrote ", out)
	quit()
