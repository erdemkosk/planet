extends Control
## The ultimate's HUD (child of the combat overlay, scripts/ui/combat_hud.gd): a charge ring with the
## character's icon right of the CAN plate (hud.gd's vitals, bottom left), "HAZIR" and the [E] key cap
## when full, a thin outer arc while your ultimate runs, "next spawn: X" over it after a pick; while
## aiming (E held) a line under the crosshair (what, how far, out of range = cancel); during a friendly
## Uydu Taraması red diamonds over the revealed enemies (through walls, HERO_SCAN_MARK_RANGE m); while
## you are cloaked a refraction shimmer at the screen edges.
## HUD level (scripts/ui/hud_mode.gd): Sade shows the ring faded below 90 % (full from 90 %, when
## ready, while aiming / running and while Alt is held); Normal + the percentage; Detaylı + the
## ultimate's name under it. Cheap: one Control, _draw each frame, no rays.

const UI := preload("res://scripts/ui/ui_style.gd")
const HudMode := preload("res://scripts/ui/hud_mode.gd")
const HeroData := preload("res://scripts/war/heroes/hero_data.gd")
const Heroes := preload("res://scripts/war/heroes/heroes.gd")
const Balance := preload("res://scripts/war/balance.gd")

const MARGIN := 24.0                     # hud.gd MARGIN / VITAL_W (the CAN plate)
const VITAL_W := 320.0
const RR := 30.0                         # ring radius at 1080p

const EDGE_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float k = 0.0;
uniform vec4 tint : source_color = vec4(0.45, 1.0, 0.72, 1.0);
void fragment() {
	vec2 c = SCREEN_UV - 0.5;
	float r = length(c * vec2(1.6, 1.0));
	float edge = smoothstep(0.32, 0.78, r) * k;
	vec2 wob = vec2(sin(TIME * 6.0 + SCREEN_UV.y * 40.0), cos(TIME * 5.0 + SCREEN_UV.x * 36.0)) * 0.006 * edge;
	vec3 bg = textureLod(screen_tex, SCREEN_UV + wob - c * 0.025 * edge, 0.0).rgb;
	COLOR = vec4(bg * (1.0 - 0.15 * edge) + tint.rgb * 0.14 * edge, edge);
}
"""

var _t := 0.0
var _pop := 0.0
var _ready_k := 0.0
var _alpha := 1.0
var _cloak_k := 0.0
var _edge: ColorRect
var _edge_mat: ShaderMaterial
var _font: Font
var _font_b: Font
var _font_n: Font


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UI.font(600)
	_font_b = UI.font(800)
	_font_n = UI.font_num(800)
	_edge = ColorRect.new()
	_edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = EDGE_SHADER
	_edge_mat = ShaderMaterial.new()
	_edge_mat.shader = sh
	_edge.material = _edge_mat
	_edge.visible = false
	add_child(_edge)
	Heroes.events().charge_gained.connect(_on_gain)


func _on_gain(_amount: float, _why: String) -> void:
	_pop = 1.0


func _process(delta: float) -> void:
	_t += delta
	_pop = maxf(_pop - delta * 2.5, 0.0)
	var st := Heroes.state()
	var ready_now := not st.is_empty() and float(st.get("charge", 0.0)) >= 1.0
	_ready_k = move_toward(_ready_k, 1.0 if ready_now else 0.0, delta * 4.0)
	_cloak_k = move_toward(_cloak_k, 1.0 if bool(st.get("cloaked", false)) else 0.0, delta * 3.0)
	_edge.visible = _cloak_k > 0.01
	if _edge.visible:
		_edge_mat.set_shader_parameter("k", _cloak_k)
	queue_redraw()


func _draw() -> void:
	var st := Heroes.state()
	var pl = Game.player
	if st.is_empty() or pl == null or not is_instance_valid(pl) or Game.overlays_hidden() or str(st.get("hero", "")) == "":
		return
	var vs := size
	var k := UI.scale_k(vs)
	var hero := str(st["hero"])
	var col := HeroData.color(hero)
	var charge := float(st.get("charge", 0.0))
	var aiming := bool(st.get("aiming", false))
	var active := float(st.get("active", 0.0))
	var full := charge >= 1.0
	var mode := HudMode.mode()
	var sade := mode == HudMode.SADE and not HudMode.peek()
	var want := 1.0 if (not sade or charge >= 0.9 or aiming or active > 0.0) else 0.28
	if pl.is_dead():
		want *= 0.5
	_alpha = lerpf(_alpha, want, 0.15)
	var a := _alpha
	var c := Vector2((MARGIN + VITAL_W + 16.0 + RR) * k, vs.y - (MARGIN + 40.0) * k)
	var r := RR * k * (1.0 + 0.06 * _pop)
	# The disc, the track, the charge.
	draw_circle(c, r + 7.0 * k, Color(UI.GLASS, 0.72 * a))
	draw_arc(c, r + 7.0 * k, 0.0, TAU, 56, Color(UI.SUIT_WHITE, 0.14 * a), maxf(1.0 * k, 1.0), true)
	draw_arc(c, r, 0.0, TAU, 56, Color(UI.SUIT_WHITE, 0.1 * a), 4.0 * k, true)
	if charge > 0.001:
		draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * charge, 56, Color(col, (0.75 + 0.25 * _ready_k) * a), 4.0 * k, true)
	if _ready_k > 0.01:
		var pulse := 0.5 + 0.5 * sin(_t * TAU * 1.2)
		draw_arc(c, r + 3.5 * k + pulse * 2.5 * k, 0.0, TAU, 56, Color(col, (0.25 + 0.35 * pulse) * _ready_k * a), 2.0 * k, true)
	if active > 0.0:
		draw_arc(c, r + 10.0 * k, -PI * 0.5, -PI * 0.5 + TAU * active, 56, Color(UI.SUIT_WHITE, 0.8 * a), 2.0 * k, true)
	HeroData.draw_icon(self, hero, c, 14.0 * k, Color(col if full else col.lerp(UI.DIM, 0.35), a), 2.0 * k)
	# The read-out right of it.
	var x := c.x + r + 14.0 * k
	var caps := UI.font_caps(700, 2)
	if full:
		UI.draw_text(self, caps, Vector2(x, c.y - 2.0 * k), "HAZIR", UI.fs(14, k), Color(col.lightened(0.2), a), 2)
		UI.draw_key(self, Vector2(x, c.y + 6.0 * k), "E", k, true, a, 12)
	elif not sade or charge >= 0.9:
		UI.draw_text(self, _font_n, Vector2(x, c.y + 6.0 * k), "%d%%" % int(charge * 100.0), UI.fs(16, k), Color(UI.TEXT, 0.9 * a), 2)
	if mode == HudMode.DETAYLI or HudMode.peek() or full:
		UI.draw_text(self, caps, Vector2(x, c.y - 18.0 * k), UI.upper_tr(HeroData.ult_name(hero)), UI.fs(10, k), Color(UI.DIM, a), 2)
	var note := str(st.get("note", ""))
	if note != "":
		UI.draw_text(self, _font, Vector2(c.x - r, c.y - r - 14.0 * k), note, UI.fs(12, k), Color(UI.WARN, 0.9), 2)
	if aiming:
		_draw_aim(st, vs, k, col)
	_draw_reveal(st, k)


func _draw_aim(st: Dictionary, vs: Vector2, k: float, col: Color) -> void:
	var aim: Dictionary = st.get("aim", {})
	var hero := str(st["hero"])
	var txt := ""
	var tc := col
	if bool(aim.get("ok", false)):
		txt = "[E] bırak: %s  ·  %d m%s" % [HeroData.ult_name(hero), int(float(aim.get("dist", 0.0))),
				"  ·  KARŞI GEZEGEN" if bool(aim.get("far", false)) else ""]
	elif bool(aim.get("hit", false)):
		txt = "Menzil dışı (%d m)  ·  bırakırsan iptal" % int(float(aim.get("dist", 0.0)))
		tc = UI.WARN
	else:
		txt = "Yere nişan al  ·  bırakırsan iptal"
		tc = UI.DIM
	UI.draw_text_c(self, _font_b, Vector2(vs.x * 0.5, vs.y * 0.5 + 64.0 * k), txt, UI.fs(15, k), tc, 3)


func _draw_reveal(st: Dictionary, k: float) -> void:
	var rv: Dictionary = st.get("reveal", {})
	if rv.is_empty() or Time.get_ticks_msec() > int(rv.get("until", 0)):
		return
	var cam := get_viewport().get_camera_3d()
	var h := Heroes.inst()
	if cam == null or h == null:
		return
	var body = rv.get("body")
	var foe := str(rv.get("team", ""))
	var left := float(int(rv["until"]) - Time.get_ticks_msec()) / 1000.0
	var fade := clampf(left / 0.8, 0.0, 1.0)
	for u in h.units():
		if not is_instance_valid(u) or u.is_dead() or Game.team_of(u) != foe:
			continue
		var p: Vector3 = (u as Node3D).global_position + (u as Node3D).global_transform.basis.y * 1.2
		if body != null and Game.dominant_body(p) != body:
			continue
		var d := cam.global_position.distance_to(p)
		if d > Balance.HERO_SCAN_MARK_RANGE or cam.is_position_behind(p):
			continue
		var sp := cam.unproject_position(p)
		var s := lerpf(8.0, 4.5, clampf(d / Balance.HERO_SCAN_MARK_RANGE, 0.0, 1.0)) * k
		var pts := PackedVector2Array([sp + Vector2(0, -s), sp + Vector2(s, 0), sp + Vector2(0, s), sp + Vector2(-s, 0), sp + Vector2(0, -s)])
		draw_colored_polygon(pts, Color(1.0, 0.24, 0.16, 0.35 * fade))
		draw_polyline(pts, Color(1.0, 0.35, 0.25, 0.95 * fade), maxf(1.5 * k, 1.0), true)
		if HudMode.mode() == HudMode.DETAYLI:
			UI.draw_text_c(self, _font, sp + Vector2(0, s + 12.0 * k), "%d m" % int(d), UI.fs(10, k), Color(1.0, 0.6, 0.5, 0.8 * fade), 2)
