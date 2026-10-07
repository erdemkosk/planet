extends Node3D
## Çıkarma işaretçisi: the beacon of a control zone (scripts/war/control_points.gd). Built here, in
## the game's white / orange hardware language with the owner's colour as light: a dark octagonal
## footing sunk into the ground (never floats on a slope), three braced legs, a white mast with an
## orange collar, an emitter head with a spinning halo, the zone letter over it, a soft light, a
## tall additive light column seen from the other planet, and the zone's edge projected on the
## ground (a Decal, so it follows the terrain).
## Colours: ours UI.HOME (violet, our core's), theirs UI.RIVAL (red), neutral pale steel. While the
## zone changes hands the head and the column blend toward the team that is winning it and the halo
## spins faster; contested: they flicker between both.
##   set_state(owner, progress, contested)   from control_points.gd (≤ 5 Hz; eased here per frame)
## Readability (2026-10-07, the user: "kaleler çok abartılı"): at rest it is subtle (a thin, low-alpha
## owner-coloured ring, a faint column, a small dim halo and light); it brightens (_emph) only while
## the zone is contested or the local player stands in it. The floating letter: none in HUD Sade,
## smaller and nearer in Normal, as before in Detaylı (Game.hud_mode()).

const Balance := preload("res://scripts/war/balance.gd")
const UI := preload("res://scripts/ui/ui_style.gd")

const NEUTRAL := Color(0.78, 0.82, 0.86)
const MAST_H := 4.6
const HEAD_Y := 4.85

const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 col : source_color = vec4(0.7, 0.5, 1.0, 1.0);
uniform float strength = 0.3;
void fragment() {
	float rim = abs(dot(NORMAL, VIEW));
	float fade = pow(clamp(UV.y, 0.0, 1.0), 1.6);
	float a = strength * fade * smoothstep(0.0, 0.7, rim);
	ALBEDO = col.rgb;
	ALPHA = a;
}
"""

static var _ring_tex: ImageTexture
static var _beam_sh: Shader

var letter := "A"
var zone_name := ""

var _owner := ""
var _progress := 0.0
var _contested := false
var _col := NEUTRAL
var _emph := 0.0                         # 0 at rest .. 1 contested / the local player inside (eased)
var _label_mode := -1                    # the HUD density the letter was set up for
var _spin := 0.6
var _t := 0.0
var _head_mat: StandardMaterial3D
var _halo_mat: StandardMaterial3D
var _beam_mat: ShaderMaterial
var _halo: MeshInstance3D
var _light: OmniLight3D
var _label: Label3D
var _decal: Decal


func _ready() -> void:
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.15, 0.16, 0.18)
	dark.metallic = 0.55
	dark.roughness = 0.5
	var white := StandardMaterial3D.new()
	white.albedo_color = UI.SUIT_WHITE.darkened(0.08)
	white.metallic = 0.2
	white.roughness = 0.38
	var orange := StandardMaterial3D.new()
	orange.albedo_color = UI.SUIT_ORANGE
	orange.roughness = 0.45
	# Footing: a bevelled octagon on a deep plinth (sunk 1.6 m: no gap on a slope).
	_mesh(_cyl(1.05, 1.35, 0.32, 8), dark, Vector3(0, 0.12, 0))
	_mesh(_cyl(1.3, 1.3, 1.6, 8), dark, Vector3(0, -0.84, 0))
	_mesh(_cyl(0.42, 0.5, 0.22, 12), white, Vector3(0, 0.38, 0))
	# Three braced legs from the footing's rim to the mast.
	for i in 3:
		var a := TAU * float(i) / 3.0 + 0.3
		var foot := Vector3(cos(a) * 0.95, 0.25, sin(a) * 0.95)
		var top := Vector3(cos(a) * 0.1, 2.5, sin(a) * 0.1)
		var leg := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.11, foot.distance_to(top), 0.11)
		leg.mesh = bm
		leg.material_override = dark
		var yax := (top - foot).normalized()
		var xax := yax.cross(Vector3(cos(a), 0, sin(a))).normalized()
		leg.transform = Transform3D(Basis(xax, yax, xax.cross(yax)), (foot + top) * 0.5)
		add_child(leg)
	# Mast, collar, head.
	_mesh(_cyl(0.075, 0.1, MAST_H - 0.3, 10), white, Vector3(0, 0.3 + (MAST_H - 0.3) * 0.5, 0))
	_mesh(_cyl(0.16, 0.16, 0.22, 12), orange, Vector3(0, 2.5, 0))
	_mesh(_cyl(0.2, 0.12, 0.3, 12), dark, Vector3(0, HEAD_Y - 0.35, 0))
	_head_mat = StandardMaterial3D.new()
	_head_mat.albedo_color = Color(0.1, 0.1, 0.12)
	_head_mat.emission_enabled = true
	_head_mat.emission_energy_multiplier = 0.9
	var head := SphereMesh.new()
	head.radius = 0.2
	head.height = 0.4
	_mesh(head, _head_mat, Vector3(0, HEAD_Y, 0))
	_halo_mat = StandardMaterial3D.new()
	_halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var tor := TorusMesh.new()
	tor.inner_radius = 0.33
	tor.outer_radius = 0.36
	tor.rings = 32
	tor.ring_segments = 6
	_halo = _mesh(tor, _halo_mat, Vector3(0, HEAD_Y, 0))
	_halo.rotation = Vector3(0.35, 0, 0.2)
	# Light, letter, column, ground ring.
	_light = OmniLight3D.new()
	_light.omni_range = 5.0
	_light.light_energy = 0.3
	_light.shadow_enabled = false
	_light.position = Vector3(0, HEAD_Y, 0)
	add_child(_light)
	_label = Label3D.new()
	_label.text = letter
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.font_size = 40
	_label.pixel_size = 0.0014
	_label.outline_size = 10
	_label.outline_modulate = Color(0, 0.02, 0.035, 0.7)
	_label.position = Vector3(0, HEAD_Y + 0.85, 0)
	_label.visibility_range_end = 160.0
	_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_label)
	if _beam_sh == null:
		_beam_sh = Shader.new()
		_beam_sh.code = BEAM_SHADER
	_beam_mat = ShaderMaterial.new()
	_beam_mat.shader = _beam_sh
	var beam := MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.35
	bc.bottom_radius = 0.12
	bc.height = 70.0
	bc.radial_segments = 16
	bc.rings = 1
	bc.cap_top = false
	bc.cap_bottom = false
	beam.mesh = bc
	beam.material_override = _beam_mat
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.position = Vector3(0, HEAD_Y + 35.0, 0)
	add_child(beam)
	_decal = Decal.new()
	var d := Balance.CP_RADIUS * 2.0 + 1.0
	_decal.size = Vector3(d, 10.0, d)
	_decal.texture_albedo = _ring_texture()
	_decal.texture_emission = _ring_emission()     # black where the ring is clear (the emission ignores alpha)
	_decal.emission_energy = 0.35                  # (_apply_colour raises it while contested / inside)
	_decal.albedo_mix = 0.6
	_decal.upper_fade = 0.25
	_decal.lower_fade = 0.25
	_decal.cull_mask = 1
	add_child(_decal)
	_apply_colour(true)


func _mesh(m: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


static func _cyl(top: float, bottom: float, h: float, seg: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c


func set_state(p_owner: String, progress: float, contested: bool) -> void:
	_owner = p_owner
	_progress = progress
	_contested = contested


func _process(delta: float) -> void:
	_t += delta
	var moving: bool = _contested or (_owner == "home" and _progress < 0.999) or (_owner == "rival" and _progress > -0.999) \
			or (_owner == "" and absf(_progress) > 0.001)
	_spin = move_toward(_spin, 4.5 if moving else 0.6, delta * 3.0)
	_halo.rotate_object_local(Vector3.UP, _spin * delta)
	# Brighter only while it matters: contested, or the local player stands in the zone.
	var inside := false
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl is Node3D and pl.get("vehicle") == null:
		inside = (pl as Node3D).global_position.distance_to(global_position) < Balance.CP_RADIUS + 1.5
	_emph = move_toward(_emph, 1.0 if (_contested or inside) else (0.4 if moving else 0.0), delta * 2.5)
	_update_label()
	_apply_colour(false, delta)


## The floating letter by HUD density: none in Sade (the HUD's strip / capture plate carry it), small
## and near in Normal, the full one in Detaylı.
func _update_label() -> void:
	var m := clampi(int(Game.hud_mode()), 0, 2) if Game.has_method("hud_mode") else 2
	if m == _label_mode:
		return
	_label_mode = m
	_label.visible = m > 0
	_label.font_size = 40 if m == 2 else 28
	_label.visibility_range_end = 160.0 if m == 2 else 70.0


## The colour the beacon shows: the owner's; while it changes hands a blend toward the side that
## leads (the sign of the progress); contested: a flicker between both teams.
func _target_colour() -> Color:
	if _contested:
		return UI.HOME if fmod(_t, 0.5) < 0.25 else UI.RIVAL
	var lead := UI.HOME if _progress > 0.0 else UI.RIVAL
	var k := absf(_progress)
	if _owner == "":
		return NEUTRAL.lerp(lead, k * 0.7)
	var own := UI.HOME if _owner == "home" else UI.RIVAL
	return NEUTRAL.lerp(own, clampf(k, 0.35, 1.0))


func _apply_colour(now: bool, delta := 0.0) -> void:
	var c := _target_colour()
	_col = c if now else _col.lerp(c, 1.0 - exp(-8.0 * delta))
	var e := _emph
	_head_mat.emission = _col
	_head_mat.emission_energy_multiplier = lerpf(0.9, 1.8, e)
	_halo_mat.albedo_color = _col.darkened(lerpf(0.45, 0.0, e))
	_light.light_color = _col
	_light.light_energy = lerpf(0.3, 0.7, e)
	_label.modulate = _col.lightened(0.25)
	_beam_mat.set_shader_parameter("col", _col)
	var pulse := lerpf(0.09, 0.26, e) + (0.08 * sin(_t * 6.0) if _contested else 0.0)
	_beam_mat.set_shader_parameter("strength", pulse)
	_decal.modulate = Color(_col, lerpf(0.4, 0.85, e))
	_decal.emission_energy = lerpf(0.35, 1.1, e)


static var _ring_emit: ImageTexture


## The ring's emission: its alpha as brightness on black (a decal's emission texture ignores alpha,
## a white one lit everything inside the decal's box).
static func _ring_emission() -> ImageTexture:
	if _ring_emit != null:
		return _ring_emit
	var img := _ring_texture().get_image()
	img.decompress()
	img.clear_mipmaps()
	for y in img.get_height():
		for x in img.get_width():
			var a := img.get_pixel(x, y).a
			a = a if a > 0.2 else 0.0           # only the ring lines glow, not the faint fill
			img.set_pixel(x, y, Color(a, a, a, 1.0))
	img.generate_mipmaps()
	_ring_emit = ImageTexture.create_from_image(img)
	return _ring_emit


## The zone edge projected on the ground: a solid outer ring, a dashed inner one and a faint fill.
static func _ring_texture() -> ImageTexture:
	if _ring_tex != null:
		return _ring_tex
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var v := (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var a := 0.0
			if r <= 1.0:
				# (toned down 2026-10-07: a thin outer line, a faint dashed inner one, almost no fill)
				a = 0.02 * smoothstep(0.3, 0.95, r)
				var outer := 1.0 - smoothstep(0.006, 0.013, absf(r - 0.955))
				a = maxf(a, outer * 0.7)
				var ang := atan2(v, u)
				var dash := 1.0 if fmod(ang / TAU * 36.0 + 36.0, 1.0) < 0.45 else 0.0
				var inner := (1.0 - smoothstep(0.003, 0.008, absf(r - 0.88))) * dash
				a = maxf(a, inner * 0.3)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	_ring_tex = ImageTexture.create_from_image(img)
	return _ring_tex
