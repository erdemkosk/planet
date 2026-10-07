extends CanvasLayer
## Combat overlay (owned by scripts/items/hit_feel.gd): hit markers (white hit, gold weak point,
## steel armor, red kill with a burst ring), short popups under the crosshair ("ZAYIF NOKTA ×2",
## "ZIRH", kill streaks), floating damage numbers at the hit point, and full-screen suit effects on
## a lower layer: personal-shield hex shimmer (toward the hit side), shield break flash, heal pulse
## and the stim tint. Kills: a short warm screen-edge pulse (kill_pulse) and kill-feed lines top
## right under the HUD panel (feed: "Sen ➜ Rakip — Kazıcı (Keskin, kafadan)", 5 s, up to 5 lines).
## Structures and cores have their own confirm (struct_marker): square steel-blue brackets for a
## structure, violet diamond brackets with a ring for a core, doubled with an expanding frame on a
## kill; and an hp readout above the crosshair that updates in place (struct_info: "TOP · %62",
## "ÇEKİRDEK · 280/450"), so autofire never stacks popups. These, the popups and the feed also
## show from a seat (a cannon's shell landing on the enemy); body markers and numbers do not.
## Look: the design system (scripts/ui/ui_style.gd), scaled with the window height: outlined marks
## and caps popups, tabular damage numbers, glass kill-feed rows under the HUD's material plate
## (hud.gd right_column_y()) with an orange strip on your own lines and a gold headshot chip.
## Incoming enemy grenades: a child overlay, scripts/ui/grenade_warn.gd. Spotted-enemy / friend
## chevrons over heads: a child overlay, scripts/ui/unit_markers.gd. The radar (top right, under the
## material plate; the kill feed starts under it): a child overlay, scripts/ui/minimap.gd.
## HUD level (scripts/ui/hud_level.gd, Sade / Normal / Detaylı): hit markers, kill confirms and the
## structure / core brackets always; Sade: no popups but "ÇEKİRDEK YIKILDI", the hp readout only for
## cores, the kill feed only your own lines (FEED_MAX_LV); Normal+: popups (streaks, "KAFADAN",
## "ZIRH" ...), every readout; Detaylı: + the floating damage numbers (still behind the damage
## numbers setting, hit_feel.gd).

const UI := preload("res://scripts/ui/ui_style.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")
const Minimap := preload("res://scripts/ui/minimap.gd")   # the radar child (+ where the kill feed starts)
const Downed := preload("res://scripts/war/downed.gd")    # downed / revive / drag ("Downed", end of file)
const Revive := preload("res://scripts/war/revive.gd")
const FEED_MAX_LV := [2, 4, 5]          # kill feed lines per HUD level (Sade: only your own lines)
const FEED_LIFE := 5.0
const FEED_MAX := 5
const HEAD_COL := Color(1.0, 0.84, 0.36)
const ARMOR_COL := Color(0.64, 0.74, 0.86)

const HEX_SHADER := """
shader_type canvas_item;
uniform float strength = 0.0;
uniform float side = 0.0;          // -1 left, +1 right, 0 all around
uniform float broken = 0.0;
uniform vec4 tint : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform float t = 0.0;

float hex_edge(vec2 p) {
	p.y *= 1.1547;
	p.x += 0.5 * mod(floor(p.y), 2.0);
	vec2 f = fract(p) - 0.5;
	vec2 a = abs(f);
	float d = max(a.x * 0.866 + a.y * 0.5, a.y);
	return smoothstep(0.40, 0.48, d);
}

void fragment() {
	vec2 uv = UV;
	vec2 c = uv - 0.5;
	c.x *= 1.777;
	float r = length(c);
	float edge = smoothstep(0.25, 0.95, r);
	float dir = 1.0;
	if (abs(side) > 0.01) {
		dir = clamp(0.35 + side * (uv.x - 0.5) * 2.2, 0.0, 1.0);
	}
	float h = hex_edge(uv * vec2(34.0, 19.0) + vec2(0.0, t * 0.6));
	float wave = 0.6 + 0.4 * sin(r * 40.0 - t * 18.0);
	float a = strength * edge * dir * (0.25 + h * 0.75) * wave;
	vec3 col = mix(tint.rgb, vec3(1.0, 0.45, 0.35), broken);
	COLOR = vec4(col * (1.0 + h), clamp(a, 0.0, 0.85));
}
"""

## s a fresh hit marker holds at its full pop before it settles and fades (2026-10-06 tok: new, ~3 frames).
const MARK_HOLD := 0.05

var _low: CanvasLayer
var _hex: ColorRect
var _hex_mat: ShaderMaterial
var _tint: ColorRect
var _top: Control
var _font: Font
var _font_b: Font
var _font_n: Font
var _k := 1.0

var _mark_t := 0.0
var _mark_cls := "hit"
var _mark_dur := 0.3
var _mark_age := 0.0
var _mark_w := 0.3
var _popups: Array = []            # {text, col, t}
var _nums: Array = []              # {pos, val, cls, t, off}
var _hex_k := 0.0
var _hex_side := 0.0
var _hex_broken := 0.0
var _heal_k := 0.0
var _stim_k := 0.0
var _t := 0.0
var _was_busy := false
var _edge: TextureRect
var _edge_k := 0.0
var _feed: Array = []              # {killer, victim, detail, mine, t}
var _smark_t := 0.0                # structure / core marker
var _smark_dur := 0.4
var _smark_age := 0.0
var _smark_w := 0.3
var _smark_kind := "structure"
var _smark_kill := false
var _sinfo := ""                   # hp readout above the crosshair
var _sinfo_col := Color.WHITE
var _sinfo_t := 0.0
var _sinfo_age := 0.0
var _sinfo_bump := 0.0
var _in_seat := false
## Tallies for the end screen (scripts/war/war_hud.gd; this HUD outlives a match, the war HUD keeps
## the counts it started with): body kills ("kill" markers), headshot kills, structures destroyed.
var stats := {"kills": 0, "heads": 0, "structs": 0}


func _ready() -> void:
	layer = 12
	add_to_group("gameplay_overlay")             # hidden on the end screen / menus (overlay_guard.gd)
	_font = UI.font(600)
	_font_b = UI.font(800)
	_font_n = UI.font_num(800)
	_low = CanvasLayer.new()
	_low.add_to_group("gameplay_overlay")
	_low.layer = 9
	add_child(_low)
	_hex = ColorRect.new()
	_hex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = HEX_SHADER
	_hex_mat = ShaderMaterial.new()
	_hex_mat.shader = sh
	_hex.material = _hex_mat
	_hex.visible = false
	_low.add_child(_hex)
	_tint = ColorRect.new()
	_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tint.color = Color(0, 0, 0, 0)
	_tint.visible = false
	_low.add_child(_tint)
	# Kill pulse: warm light at the screen edges only (centre stays clear, never near white).
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.62, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.8, 0.55, 0.0), Color(1.0, 0.75, 0.5, 0.0), Color(1.0, 0.62, 0.38, 0.55)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.05, 0.5)
	gt.width = 128
	gt.height = 128
	_edge = TextureRect.new()
	_edge.texture = gt
	_edge.stretch_mode = TextureRect.STRETCH_SCALE
	_edge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edge.visible = false
	_low.add_child(_edge)
	_top = Control.new()
	_top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.draw.connect(_draw_top)
	add_child(_top)
	add_child(preload("res://scripts/ui/grenade_warn.gd").new())   # incoming enemy grenade markers
	add_child(preload("res://scripts/ui/unit_markers.gd").new())   # spotted-enemy / friend chevrons
	add_child(Minimap.new())                                         # the radar (top right, under the material plate)
	add_child(load("res://scripts/war/heroes/hero_hud.gd").new())   # the ultimate's ring right of CAN (scripts/war/heroes)


# --- API -------------------------------------------------------------------------------------

## cls: "hit", "head", "weak", "armor", "stun", "kill". `weight` 0..1: how big the hit was (the
## marker pops larger for heavy hits).
func marker(cls: String, weight := 0.3) -> void:
	if cls == "kill":
		stats["kills"] = int(stats["kills"]) + 1
	var rank := {"hit": 0, "armor": 1, "stun": 1, "head": 2, "weak": 3, "kill": 4}
	if _mark_t > 0.0 and int(rank.get(cls, 0)) < int(rank.get(_mark_cls, 0)):
		_mark_t = maxf(_mark_t, 0.12)
		_mark_age = minf(_mark_age, 0.03)
		return
	var again := _mark_t > 0.0 and cls == _mark_cls and _mark_age < 0.12   # rapid fire: no 20 Hz pop flicker
	_mark_cls = cls
	_mark_dur = 0.55 if cls == "kill" else (0.38 if cls in ["weak", "head"] else 0.28)
	_mark_t = _mark_dur
	if not again:
		_mark_age = 0.0
	_mark_w = maxf(clampf(weight, 0.0, 1.0), _mark_w if again else 0.0)


func popup(text: String, col: Color) -> void:
	if HudLevel.level() == HudLevel.SADE and text != "ÇEKİRDEK YIKILDI":
		return
	for p in _popups:
		if p["text"] == text and float(p["t"]) < 0.3:
			p["t"] = 0.0
			return
	_popups.append({"text": text, "col": col, "t": 0.0})
	while _popups.size() > 3:
		_popups.pop_front()


## Floating damage number at world point `pos` (merges hits on the same spot within 0.12 s).
func number(pos: Vector3, val: float, cls: String) -> void:
	if val < 0.5 or HudLevel.level() < HudLevel.DETAYLI:
		return
	for n in _nums:
		if float(n["t"]) < 0.12 and (n["pos"] as Vector3).distance_to(pos) < 1.2:
			n["val"] = float(n["val"]) + val
			if cls in ["kill", "weak"]:
				n["cls"] = cls
			return
	_nums.append({"pos": pos, "val": val, "cls": cls, "t": 0.0, "off": Vector2(randf_range(-14, 14), randf_range(-6, 6))})
	while _nums.size() > 14:
		_nums.pop_front()


## Personal shield took a hit: hex shimmer (side -1 left, +1 right, 0 around), strength 0..1.
func shield_hit(side: float, strength: float) -> void:
	_hex_k = maxf(_hex_k, clampf(strength, 0.25, 1.0))
	_hex_side = side
	_hex_broken = 0.0


func shield_break() -> void:
	_hex_k = 1.2
	_hex_side = 0.0
	_hex_broken = 1.0


func heal_pulse() -> void:
	_heal_k = 1.0


## Kill: a short warm pulse at the screen edges (k 0..1).
func kill_pulse(k := 0.7) -> void:
	_edge_k = maxf(_edge_k, clampf(k, 0.0, 1.0))


## Kill feed line: killer ➜ victim (detail). mine: the local player took part (highlighted).
func feed(killer: String, victim: String, detail := "", mine := true) -> void:
	if mine and killer == "Sen" and detail.contains("kafadan"):
		stats["heads"] = int(stats["heads"]) + 1
	var lv := HudLevel.level()
	if lv == HudLevel.SADE and not mine:
		return
	_feed.append({"killer": killer, "victim": victim, "detail": detail, "mine": mine, "t": 0.0})
	while _feed.size() > mini(int(FEED_MAX_LV[clampi(lv, 0, 2)]), FEED_MAX):
		_feed.pop_front()


func set_stim(k: float) -> void:
	_stim_k = clampf(k, 0.0, 1.0)


## Structure / core confirm marker. kind "structure" (steel-blue square brackets) or "core" (violet
## diamond brackets); `weight` 0..1 sets the pop; killed: doubled brackets and an expanding frame.
func struct_marker(kind: String, weight := 0.3, killed := false) -> void:
	if killed and kind == "structure":
		stats["structs"] = int(stats["structs"]) + 1
	var again :=_smark_t > 0.0 and kind == _smark_kind and _smark_age < 0.12 and not killed
	if _smark_t > 0.0 and _smark_kill and not killed and _smark_age < 0.5:
		return                          # a kill frame stays up
	_smark_kind = kind
	_smark_kill = killed
	_smark_dur = 0.8 if killed else (0.5 if kind == "core" else 0.34)
	_smark_t = _smark_dur
	if not again:
		_smark_age = 0.0
	_smark_w = maxf(clampf(weight, 0.0, 1.0), _smark_w if again else 0.0)


## The hp readout above the crosshair ("TOP · %62"): replaced in place, fades 1.3 s after the last
## update.
func struct_info(text: String, col: Color) -> void:
	if HudLevel.level() == HudLevel.SADE and not text.begins_with("ÇEKİRDEK"):
		return
	if _sinfo_t <= 0.0:
		_sinfo_age = 0.0
	if text != _sinfo:
		_sinfo_bump = 1.0
	_sinfo = text
	_sinfo_col = col
	_sinfo_t = 1.3


# --- Update / draw ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var rd := delta / maxf(Engine.time_scale, 0.01)
	_t += rd
	_mark_t = maxf(_mark_t - rd, 0.0)
	_mark_age += rd
	for i in range(_popups.size() - 1, -1, -1):
		_popups[i]["t"] = float(_popups[i]["t"]) + rd
		if float(_popups[i]["t"]) > 1.0:
			_popups.remove_at(i)
	for i in range(_nums.size() - 1, -1, -1):
		_nums[i]["t"] = float(_nums[i]["t"]) + rd
		if float(_nums[i]["t"]) > 0.9:
			_nums.remove_at(i)
	_hex_k = maxf(_hex_k - rd * (1.6 if _hex_broken < 0.5 else 1.0), 0.0)
	_hex.visible = _hex_k > 0.01
	if _hex.visible:
		_hex_mat.set_shader_parameter("strength", minf(_hex_k, 1.0) * 0.8)
		_hex_mat.set_shader_parameter("side", _hex_side)
		_hex_mat.set_shader_parameter("broken", _hex_broken)
		_hex_mat.set_shader_parameter("t", _t)
	_heal_k = maxf(_heal_k - rd * 1.2, 0.0)
	var tc := Color(0, 0, 0, 0)
	if _heal_k > 0.0:
		tc = Color(0.3, 1.0, 0.5, 0.12 * _heal_k)
	if _stim_k > 0.0:
		var s := Color(1.0, 0.75, 0.25, 0.05 * _stim_k * (0.8 + 0.2 * sin(_t * 4.0)))
		tc = s if tc.a < s.a else tc
	_tint.color = tc
	_tint.visible = tc.a > 0.003
	_edge_k = maxf(_edge_k - rd * 2.8, 0.0)
	_edge.visible = _edge_k > 0.005
	if _edge.visible:
		_edge.modulate.a = _edge_k * _edge_k * 0.55
	for i in range(_feed.size() - 1, -1, -1):
		_feed[i]["t"] = float(_feed[i]["t"]) + rd
		if float(_feed[i]["t"]) > FEED_LIFE:
			_feed.remove_at(i)
	_smark_t = maxf(_smark_t - rd, 0.0)
	_smark_age += rd
	_sinfo_t = maxf(_sinfo_t - rd, 0.0)
	_sinfo_age += rd
	_sinfo_bump = maxf(_sinfo_bump - rd * 8.0, 0.0)
	var p = Game.player
	_in_seat = p != null and p.get("vehicle") != null
	# In a seat only the structure / core confirms, popups and the feed show (no body markers).
	_top.visible = p != null and (not _in_seat or _smark_t > 0.0 or _sinfo_t > 0.0 or not _popups.is_empty()
			or not _feed.is_empty())
	var busy := _mark_t > 0.0 or not _popups.is_empty() or not _nums.is_empty() or not _feed.is_empty() \
			or _smark_t > 0.0 or _sinfo_t > 0.0 or Downed.any()      # (downed: markers, panel, rings)
	if _top.visible and (busy or _was_busy):
		_top.queue_redraw()
	_was_busy = busy


func _draw_top() -> void:
	var c := _top.size * 0.5
	_k = UI.scale_k(_top.size)
	var k := _k
	if _mark_t > 0.0 and not _in_seat:
		_draw_marker(c)
	if _smark_t > 0.0:
		_draw_struct_marker(c)
	if _sinfo_t > 0.0 and _sinfo != "":
		var sa := clampf(_sinfo_age / 0.06, 0.0, 1.0) * clampf(_sinfo_t / 0.35, 0.0, 1.0)
		var sz := UI.fs(14.0 * (1.0 + 0.12 * _sinfo_bump), k)
		var sw := UI.draw_text_c(_top, UI.font_caps(800, 1), c + Vector2(0, -44.0 * k), _sinfo, sz, Color(_sinfo_col, sa), 3)
		_top.draw_rect(Rect2(c + Vector2(-sw * 0.5, -38.0 * k), Vector2(sw, 1.5 * k)), Color(_sinfo_col, 0.45 * sa))
	var y := c.y + 38.0 * k
	for p in _popups:
		var t: float = p["t"]
		var a := clampf(t / 0.06, 0.0, 1.0) * clampf((1.0 - t) / 0.35, 0.0, 1.0)
		var col: Color = p["col"]
		var size := 15 if not String(p["text"]).begins_with("×") else 19
		var pop := 1.0 + 0.25 * maxf(0.0, 1.0 - t / 0.12)
		UI.draw_text_c(_top, UI.font_caps(800, 2), Vector2(c.x, y - t * 10.0 * k), p["text"], UI.fs(size * pop, k), Color(col, a), 3)
		y += 21.0 * k
	if Downed.any():
		_draw_downed(c)
	_draw_feed()
	var cam := get_viewport().get_camera_3d()
	if cam == null or _in_seat:
		return
	for n in _nums:
		var wp: Vector3 = n["pos"]
		if cam.is_position_behind(wp):
			continue
		var sp := cam.unproject_position(wp)
		var t: float = n["t"]
		var a := clampf((0.9 - t) / 0.3, 0.0, 1.0)
		var cls: String = n["cls"]
		var col := Color(0.95, 0.97, 0.98)
		var sz := 14
		match cls:
			"weak", "head":
				col = HEAD_COL
				sz = 17
			"armor":
				col = ARMOR_COL
			"kill":
				col = UI.CRIT.lightened(0.1)
				sz = 18
		var off: Vector2 = n["off"]
		var pop := 1.0 + 0.3 * maxf(0.0, 1.0 - t / 0.08)
		var pos := sp + off * k + Vector2(0, (-26.0 * t - 8.0) * k)
		UI.draw_text_c(_top, _font_n, pos, "%d" % int(roundf(float(n["val"]))), UI.fs(sz * pop, k), Color(col, a), 3)


func _draw_marker(c: Vector2) -> void:
	# (2026-10-06 tok, the hit's "impact pause": the first MARK_HOLD s it holds at full size and
	# strength, then snaps in and fades as before.)
	var k := clampf(_mark_t / maxf(_mark_dur - MARK_HOLD, 0.01), 0.0, 1.0)
	var s := _k
	var e := 1.0 - k
	var col := Color(0.96, 0.97, 0.98)
	# Snaps in from 1.45x over 60 ms (bigger for heavy hits), then drifts out as it fades.
	var pop := 1.0 + (0.25 + _mark_w * 0.35) * clampf(1.0 - maxf(_mark_age - MARK_HOLD, 0.0) / 0.06, 0.0, 1.0)
	var g := (6.0 + e * 6.0) * pop
	var l := (9.0 + _mark_w * 3.0) * pop
	var w := 2.2 + _mark_w * 0.6
	match _mark_cls:
		"head":
			col = HEAD_COL
			l = 11.0 * pop
			w = 2.8
		"weak":
			col = Color(1.0, 0.78, 0.2)
			l = 12.5 * pop
			w = 3.2
		"armor":
			col = ARMOR_COL
			l = 7.0 * pop
		"stun":
			col = UI.SCREEN_CYAN
		"kill":
			col = UI.CRIT
			g = (8.0 + e * 5.0) * pop
			l = 14.0 * pop
			w = 3.6
	g *= s
	l *= s
	w *= s
	for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var dv: Vector2 = (d as Vector2).normalized()
		_top.draw_line(c + dv * (g - 1.0), c + dv * (g + l + 1.0), Color(UI.OUTLINE, UI.OUTLINE.a * k), w + 2.5 * s, true)
		_top.draw_line(c + dv * g, c + dv * (g + l), Color(col, k), w, true)
	if _mark_cls == "kill":
		# Burst ring + a small diamond, a soft glow behind.
		_top.draw_circle(c, (16.0 + e * 10.0) * s, Color(UI.CRIT, 0.08 * k))
		_top.draw_arc(c, (20.0 + e * 22.0) * s, 0, TAU, 40, Color(UI.CRIT.lightened(0.15), 0.75 * k), (2.5 * k + 0.5) * s, true)
		var q := 5.0 * s
		var pts := PackedVector2Array([c + Vector2(0, -q), c + Vector2(q, 0), c + Vector2(0, q), c + Vector2(-q, 0)])
		_top.draw_colored_polygon(pts, Color(UI.CRIT.lightened(0.1), k))
	elif _mark_cls == "armor":
		# Cracked plate glyph under the marker.
		var o := c + Vector2(0, 26) * s
		var pts2 := PackedVector2Array([o + Vector2(-7, -6) * s, o + Vector2(7, -6) * s, o + Vector2(6, 3) * s, o + Vector2(0, 8) * s,
				o + Vector2(-6, 3) * s, o + Vector2(-7, -6) * s])
		_top.draw_polyline(pts2, Color(col, 0.9 * k), 1.6 * s, true)
		_top.draw_polyline(PackedVector2Array([o + Vector2(-1, -6) * s, o + Vector2(1, -1) * s, o + Vector2(-2, 2) * s, o + Vector2(1, 7) * s]),
				Color(col, 0.9 * k), 1.4 * s, true)
	elif _mark_cls == "weak":
		_top.draw_arc(c, 6.0 * s, 0, TAU, 20, Color(col, 0.9 * k), 2.0 * s, true)


## Structure / core marker: brackets snap in from 1.4x (heavier hits pop more) and drift out as
## they fade. Structure: square corners, steel blue. Core: diamond corners and a thin ring, violet.
## A kill doubles the brackets and sends a frame outward.
func _draw_struct_marker(c: Vector2) -> void:
	var k := _smark_t / _smark_dur
	var s := _k
	var e := 1.0 - k
	var core := _smark_kind == "core"
	var col := UI.HOME if core else Color(0.55, 0.78, 1.0)
	if _smark_kill:
		col = col.lightened(0.25)
	var pop := 1.0 + (0.25 + _smark_w * 0.35) * clampf(1.0 - _smark_age / 0.07, 0.0, 1.0)
	var hs := (14.0 + e * 5.0 + (4.0 if _smark_kill else 0.0)) * pop * s       # half size
	var arm := (6.0 + _smark_w * 3.0) * pop * s
	var w := (2.2 + _smark_w * 0.8 + (0.8 if _smark_kill else 0.0)) * s
	var a := k if not _smark_kill else clampf(k * 1.6, 0.0, 1.0)
	var rings := [hs, hs + 7.0 * s] if _smark_kill else [hs]
	for r in rings:
		var rr: float = r
		for q in 4:
			var lines := _bracket(c, rr * (1.3 if core else 1.0), arm, q, core)
			for ln in lines:
				var p0: Vector2 = ln[0]
				var p1: Vector2 = ln[1]
				_top.draw_line(p0, p1, Color(UI.OUTLINE, UI.OUTLINE.a * a), w + 2.5 * s, true)
				_top.draw_line(p0, p1, Color(col, a), w, true)
	if core:
		_top.draw_arc(c, hs * 0.55, 0, TAU, 32, Color(col, 0.7 * a), 1.6 * s, true)
	if _smark_kill:
		var fr := hs + (10.0 + e * 26.0) * s
		if core:
			_top.draw_arc(c, fr * 1.2, 0, TAU, 48, Color(col, 0.7 * k), (2.5 * k + 0.5) * s, true)
		else:
			_top.draw_rect(Rect2(c - Vector2(fr, fr), Vector2(fr, fr) * 2.0), Color(col, 0.7 * k), false, (2.5 * k + 0.5) * s)


## Corner q (0..3) of a bracket frame of half size `hs`: two short lines of length `arm`. Square
## corners for a structure, the corners of a diamond (top / right / bottom / left) for a core.
func _bracket(c: Vector2, hs: float, arm: float, q: int, diamond: bool) -> Array:
	if diamond:
		var dirs := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]
		var d: Vector2 = dirs[q]
		var p := c + d * hs
		var t := Vector2(-d.y, d.x)
		var back := -d.normalized()
		return [[p, p + (back + t).normalized() * arm], [p, p + (back - t).normalized() * arm]]
	var sx := -1.0 if q == 0 or q == 3 else 1.0
	var sy := -1.0 if q < 2 else 1.0
	var pc := c + Vector2(sx, sy) * hs
	return [[pc, pc - Vector2(sx * arm, 0.0)], [pc, pc - Vector2(0.0, sy * arm)]]


## Kill feed: right-aligned glass rows under the material plate (and any craft pills,
## hud.gd right_column_y()), newest at the bottom: killer, a chevron, the victim, the detail chip
## (gold with a crosshair glyph for a headshot); the local player's lines get the orange strip.
func _draw_feed() -> void:
	if _feed.is_empty():
		return
	var k := _k
	var right := _top.size.x - 24.0 * k
	var y := 104.0 * k
	if Game.hud != null and is_instance_valid(Game.hud) and Game.hud.has_method("right_column_y"):
		var y0 := float(Game.hud.right_column_y(false))
		y = float(Game.hud.right_column_y()) - y0 + maxf(y0, Minimap.bottom_y(_top.size))   # (craft pills kept)
	else:
		y = maxf(y, Minimap.bottom_y(_top.size))     # (under the radar, scripts/ui/minimap.gd)
	var fsz := UI.fs(13, k)
	var dfs := UI.fs(10, k)
	var h := 26.0 * k
	var caps := UI.font_caps(700, 1)
	for f in _feed:
		var t: float = f["t"]
		var a := clampf(t / 0.12, 0.0, 1.0) * clampf((FEED_LIFE - t) / 0.6, 0.0, 1.0)
		var slide := (1.0 - UI.smooth(clampf(t / 0.18, 0.0, 1.0))) * 28.0 * k
		var killer := str(f["killer"])
		var victim := str(f["victim"])
		var detail := str(f["detail"])
		var head := detail.contains("kafadan")
		var kw := UI.text_w(_font_b, killer, fsz)
		var vw := UI.text_w(_font_b, victim, fsz)
		var dw := (UI.text_w(caps, UI.upper_tr(detail), dfs) + 12.0 * k + (12.0 * k if head else 0.0)) if detail != "" else 0.0
		var chev := 16.0 * k
		var w := kw + chev + vw + (dw + 8.0 * k if dw > 0.0 else 0.0) + 24.0 * k
		var r := Rect2(Vector2(right - w + slide, y), Vector2(w, h))
		var mine: bool = f["mine"]
		UI.draw_chamfer(_top, r, 6.0 * k, Color(UI.GLASS, 0.62 * a), Color(UI.SUIT_ORANGE if mine else UI.SUIT_WHITE, (0.45 if mine else 0.12) * a))
		if mine:
			_top.draw_rect(Rect2(r.position + Vector2(1.0, 5.0 * k), Vector2(3.0 * k, h - 10.0 * k)), Color(UI.SUIT_ORANGE, 0.95 * a))
		var x := r.position.x + 12.0 * k
		var by := r.get_center().y + fsz * 0.36
		UI.draw_text(_top, _font_b, Vector2(x, by), killer, fsz, Color(UI.SUIT_ORANGE.lightened(0.2) if killer == "Sen" else UI.SCREEN_CYAN, a), 2)
		x += kw + 4.0 * k
		var cy := r.get_center().y
		_top.draw_polyline(PackedVector2Array([Vector2(x + 2.0 * k, cy - 4.0 * k), Vector2(x + 7.0 * k, cy), Vector2(x + 2.0 * k, cy + 4.0 * k)]),
				Color(UI.SUIT_WHITE, 0.7 * a), maxf(1.5 * k, 1.0), true)
		x += chev - 4.0 * k
		UI.draw_text(_top, _font_b, Vector2(x, by), victim, fsz, Color(UI.RIVAL.lightened(0.15) if victim.begins_with("Rakip") else UI.TEXT, a), 2)
		x += vw + 8.0 * k
		if dw > 0.0:
			var dc := HEAD_COL if head else (UI.WARN if detail == DN_FEED else UI.DIM)
			var dr := Rect2(Vector2(x, cy - 8.0 * k), Vector2(dw, 16.0 * k))
			UI.draw_chamfer(_top, dr, 4.0 * k, Color(dc, 0.14 * a), Color(dc, 0.5 * a))
			var dx := dr.position.x + 6.0 * k
			if head:
				var hc := Vector2(dx + 4.0 * k, cy)
				_top.draw_arc(hc, 3.5 * k, 0.0, TAU, 12, Color(dc, a), maxf(1.2 * k, 1.0), true)
				_top.draw_circle(hc, 1.2 * k, Color(dc, a))
				dx += 12.0 * k
			_top.draw_string(caps, Vector2(dx, cy + dfs * 0.36), UI.upper_tr(detail), HORIZONTAL_ALIGNMENT_LEFT, -1, dfs, Color(dc.lightened(0.2), a))
		y += h + 5.0 * k


func _text_c(p: Vector2, s: String, size: int, col: Color, f: Font) -> void:
	UI.draw_text_c(_top, f, p, s, size, col, 3)


# =================================================================================================
# Downed (scripts/war/downed.gd, revive.gd): the local player's bleed-out panel, the revive icons over
# downed teammates, the hold ring while reviving, the drag line. Drawn on _top while Downed.any().
# =================================================================================================

const DN_FEED := "YERE SERİLDİ"         # the kill-feed detail of a down (downed.gd), chip in WARN
const DN_ICON_RANGE := 120.0            # m: revive icons over downed teammates this close

var _dn_near_t := 0.0
var _dn_near := ""                      # "Dost — Muhafız · 12 m" (the nearest teammate who could help)


func _draw_downed(c: Vector2) -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return
	var k := _k
	var cam := get_viewport().get_camera_3d()
	var t := _t
	if cam != null and not _in_seat:
		var my_team := Game.team_of(p)
		for u in Downed.units():
			if u == p or Game.team_of(u) != my_team:
				continue
			var cpos := Downed.body_center(u)
			var wp := cpos + (u as Node3D).global_transform.basis.y * 0.85
			if cam.is_position_behind(wp):
				continue
			var d := cam.global_position.distance_to(cpos)
			if d > DN_ICON_RANGE:
				continue
			_dn_icon(cam.unproject_position(wp), k, u, d, t)
	var ru := Revive.local_revive_unit()
	if ru != null:
		_dn_ring(c, k, Downed.revive_progress(ru), "AYAĞA KALDIRILIYOR", UI.GOOD)
	var du := Revive.local_drag_unit()
	if du != null:
		var y := c.y + 64.0 * k
		UI.draw_text_c(_top, UI.font_caps(800, 2), Vector2(c.x, y), "SÜRÜKLÜYORSUN", UI.fs(13, k), Color(UI.WARN, 0.95), 3)
		UI.draw_text_c(_top, _font, Vector2(c.x, y + 18.0 * k), "[F] bırak  ·  geri geri yürü", UI.fs(12, k), Color(UI.DIM, 0.9), 2)
	if Downed.is_downed(p):
		_dn_panel(c, k, p, t)
	elif Downed.is_rising(p):
		UI.draw_text_c(_top, UI.font_caps(800, 2), Vector2(c.x, _top.size.y * 0.74), "KALKIYORSUN…", UI.fs(15, k), Color(UI.GOOD, 0.9), 3)


## A downed teammate: a plus in a ring (amber, pulsing; the bleed-out left as the ring's arc), the
## revive progress as a green arc around it, the distance under it.
func _dn_icon(sp: Vector2, k: float, u, d: float, t: float) -> void:
	var near := clampf(1.0 - (d - 8.0) / 60.0, 0.45, 1.0)
	var r := 11.0 * k * near
	var left := Downed.bleed_frac(u)
	var urgent := left < 0.35
	var col: Color = UI.CRIT if urgent else UI.WARN
	var pulse := 0.75 + 0.25 * sin(t * (9.0 if urgent else 4.5))
	_top.draw_circle(sp, r * 1.25, Color(UI.GLASS, 0.55))
	_top.draw_arc(sp, r * 1.25, -PI * 0.5, -PI * 0.5 + TAU * left, 32, Color(col, 0.95 * pulse), maxf(2.0 * k, 1.5), true)
	var arm := r * 0.55
	var w := maxf(r * 0.32, 2.0)
	_top.draw_rect(Rect2(sp - Vector2(arm, w * 0.5), Vector2(arm * 2.0, w)), Color(col, pulse))
	_top.draw_rect(Rect2(sp - Vector2(w * 0.5, arm), Vector2(w, arm * 2.0)), Color(col, pulse))
	var rk := Downed.revive_progress(u)
	if Downed.reviver_of(u) != null and rk > 0.0:
		_top.draw_arc(sp, r * 1.6, -PI * 0.5, -PI * 0.5 + TAU * rk, 32, Color(UI.GOOD, 0.95), maxf(2.5 * k, 2.0), true)
	elif Downed.dragger_of(u) != null:
		UI.draw_text_c(_top, UI.font_caps(700, 1), sp + Vector2(0, -r * 1.6 - 4.0 * k), "SÜRÜKLENİYOR", UI.fs(9, k), Color(UI.DIM, 0.9), 2)
	UI.draw_text_c(_top, _font_n, sp + Vector2(0, r * 1.25 + 14.0 * k), "%d m" % int(roundf(d)), UI.fs(11, k), Color(UI.TEXT, 0.85 * near), 2)


## The hold ring round the crosshair (k 0..1) with its label under it.
func _dn_ring(c: Vector2, k: float, prog: float, label: String, col: Color) -> void:
	var r := 24.0 * k
	_top.draw_arc(c, r, 0.0, TAU, 48, Color(UI.GLASS, 0.6), maxf(5.0 * k, 3.0), true)
	_top.draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * clampf(prog, 0.0, 1.0), 48, Color(col, 0.95), maxf(3.5 * k, 2.0), true)
	UI.draw_text_c(_top, UI.font_caps(800, 2), c + Vector2(0, r + 22.0 * k), label, UI.fs(13, k), Color(col, 0.95), 3)
	var secs := maxf(float(Downed.Balance.DN_REVIVE_TIME) * (1.0 - prog), 0.0)
	UI.draw_text_c(_top, _font_n, c + Vector2(0, r + 40.0 * k), "%.1f s" % secs, UI.fs(12, k), Color(UI.DIM, 0.9), 2)


## The local player's panel while down: title, the bleed-out bar (seconds left), who helps / how far
## help is, the give-up hold.
func _dn_panel(c: Vector2, k: float, p, t: float) -> void:
	var st = Downed.state_of(p)
	if st == null:
		return
	var y := _top.size.y * 0.66
	var w := 340.0 * k
	var left := Downed.bleed_frac(p)
	var urgent := left < 0.3
	var pulse := 0.8 + 0.2 * sin(t * (8.0 if urgent else 3.0))
	UI.draw_text_c(_top, UI.font_caps(800, 3), Vector2(c.x, y), "YERE SERİLDİN", UI.fs(22, k), Color(UI.CRIT, pulse), 3)
	y += 16.0 * k
	var bar := Rect2(Vector2(c.x - w * 0.5, y), Vector2(w, 9.0 * k))
	UI.draw_chamfer(_top, bar.grow(3.0 * k), 3.0 * k, Color(UI.GLASS, 0.7), Color(UI.SUIT_WHITE, 0.18))
	_top.draw_rect(Rect2(bar.position, Vector2(w * left, bar.size.y)), Color(UI.CRIT if urgent else UI.BAD, 0.95))
	UI.draw_text_r(_top, _font_n, bar.end.x, y + 26.0 * k, "%d s" % int(ceilf(maxf(st.bleed, 0.0))), UI.fs(12, k), Color(UI.TEXT, 0.9), 2)
	UI.draw_text(_top, _font, Vector2(bar.position.x, y + 26.0 * k), "kan kaybı", UI.fs(12, k), Color(UI.DIM, 0.85), 2)
	y += 52.0 * k
	var rv := Downed.reviver_of(p)
	if rv != null:
		var rk := Downed.revive_progress(p)
		UI.draw_text_c(_top, _font_b, Vector2(c.x, y), "%s seni kaldırıyor — %%%d" % [Downed._name_of(rv), int(rk * 100.0)], UI.fs(15, k), Color(UI.GOOD, 0.95), 3)
		var rb := Rect2(Vector2(c.x - w * 0.35, y + 8.0 * k), Vector2(w * 0.7, 4.0 * k))
		_top.draw_rect(rb, Color(UI.GLASS, 0.7))
		_top.draw_rect(Rect2(rb.position, Vector2(rb.size.x * rk, rb.size.y)), Color(UI.GOOD, 0.95))
	else:
		_dn_near_t -= get_process_delta_time()
		if _dn_near_t <= 0.0:
			_dn_near_t = 0.25
			_dn_near = _dn_helper_line(p, st)
		var dots := ".".repeat(1 + int(t * 2.0) % 3)
		UI.draw_text_c(_top, _font_b, Vector2(c.x, y), "Yardım bekleniyor" + dots, UI.fs(15, k), Color(UI.TEXT, 0.92), 3)
		UI.draw_text_c(_top, _font, Vector2(c.x, y + 19.0 * k), _dn_near, UI.fs(12, k), Color(UI.DIM, 0.9), 2)
	y += 46.0 * k
	# Give up: hold Space (the fill is the hold).
	var gk := Downed.giveup_frac(p)
	var label := "VAZGEÇ:  [Space] basılı tut"
	var lw := UI.text_w(UI.font_caps(700, 1), label, UI.fs(12, k)) + 24.0 * k
	var gr := Rect2(Vector2(c.x - lw * 0.5, y - 15.0 * k), Vector2(lw, 22.0 * k))
	UI.draw_chamfer(_top, gr, 5.0 * k, Color(UI.GLASS, 0.6), Color(UI.SUIT_WHITE, 0.2 + 0.5 * gk))
	if gk > 0.0:
		_top.draw_rect(Rect2(gr.position + Vector2(1.0, 1.0), Vector2((gr.size.x - 2.0) * gk, gr.size.y - 2.0)), Color(UI.CRIT, 0.35))
	UI.draw_text_c(_top, UI.font_caps(700, 1), Vector2(c.x, y), label, UI.fs(12, k), Color(UI.TEXT if gk <= 0.0 else UI.CRIT.lightened(0.3), 0.9), 2)


## "Dost — Muhafız geliyor · 9 m" (a medic on its way) / "En yakın: Oyuncu2 · 14 m" / "Yakında dost yok".
func _dn_helper_line(p, st) -> String:
	var pp: Vector3 = (p as Node3D).global_position
	if st.medic != null and is_instance_valid(st.medic):
		return "%s geliyor · %d m" % [Downed._name_of(st.medic), int((st.medic as Node3D).global_position.distance_to(pp))]
	var team := Game.team_of(p)
	var best: Node3D = null
	var bd := INF
	for g in ["net_player", "war_ai"]:
		for n in get_tree().get_nodes_in_group(g):
			if not is_instance_valid(n) or n == p or Game.team_of(n) != team or Downed.is_downed(n):
				continue
			if n.has_method("is_dead") and n.call("is_dead"):
				continue
			var d := (n as Node3D).global_position.distance_to(pp)
			if d < bd:
				bd = d
				best = n
	if best == null:
		return "Yakında dost yok"
	return "En yakın: %s · %d m" % [Downed._name_of(best), int(bd)]
