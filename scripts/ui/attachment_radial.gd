extends CanvasLayer
## The attachment radial (eklenti çarkı; scripts/items/attachments.gd): hold the middle mouse button
## on a gun that has attachment mounts (rifle.gd / weapon_base.gd open it) and a wheel comes up over a
## soft blur. The inner ring is the gun's slots (NAMLU · NİŞANGAH · ALT NAMLU) as sectors, the outer
## ring that slot's options in its sector: the gun's own part first, then every compatible attachment
## (owned: its silhouette and short name; locked: greyed with its price, 2026-10-06: bought on the spot
## with material: "Satın al · N m³", Game.spend_material + Attachments.unlock(id), then fitted; the
## Silahlık's EKLENTİLER tab stays an alternative shop). The mouse moves the selector (mouse look is held while it is open; the game runs on,
## fire and aim are held: Attachments.radial_on), the panel beside the wheel shows the hovered one's
## name, state, stat changes (green better, red worse) and description.
##   release the middle button on an entry: fit it (the gun's Kit.fit: the left hand reaches to the
##   mount, foley, the part swaps); a quick tap leaves the wheel open: then left click fits, right
##   click / middle / Esc closes; right click or Esc always cancels.
## Closes itself when the gun is put away, a vehicle / ragdoll / death takes the player, the mouse is
## freed or Game.overlays_hidden() (match over, pause, a panel). In group "gameplay_overlay"
## (scripts/ui/overlay_guard.gd); its own visibility lives on an inner Control so the guard's
## hide / restore never fights it. The HUD session may restyle it (ui_style.gd tokens only).
##   AttachmentRadial.open_for(gun)      AttachmentRadial.is_open() -> bool

const Attachments := preload("res://scripts/items/attachments.gd")
const UI := preload("res://scripts/ui/ui_style.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # toasts: "no_mat" (1), "attach" (bought, 1: it spends m³)

const R_DEAD := 30.0                 # px (1080p) of selector travel before anything is picked
const R_IN := 60.0                   # centre disc
const R_SLOT0 := 66.0                # slot band
const R_SLOT1 := 94.0
const R_OPT0 := 100.0                # option band
const R_OPT1 := 206.0
const TAP := 0.2                     # s: a release sooner than this with nothing picked keeps it open
const SHORT := {"suppressor": "Susturucu", "compensator": "Kompansatör", "flash_hider": "Alev Gizleyici",
		"choke": "Şok Daraltıcı", "reflex": "Refleks", "holo": "Holografik", "scope4": "Dürbün 4×",
		"foregrip": "Ön Tutamak", "laser": "Lazer"}
const EMPTY_SHORT := {"muzzle": "Standart", "optic": "Kendi", "under": "Boş"}
const SLOT_ORDER := ["optic", "muzzle", "under"]   # the optic centred on top, the muzzle right, under left

const BLUR_SHADER := """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float k = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 c = textureLod(screen_tex, uv, 2.6 * k).rgb;
	float r = length((uv - 0.5) * vec2(1.7, 1.0));
	c *= mix(1.0, 0.5 + 0.12 * smoothstep(0.1, 0.9, r), k);
	COLOR = vec4(c, k);
}
"""

var gun = null
var _open := false
var _k := 0.0                        # open animation 0..1
var _t_open := 0.0
var _sticky := false
var _cursor := Vector2.ZERO          # selector offset from the centre (1080p px)
var _hover := -1
var _entries: Array = []             # {slot, id, a0, a1, owned}
var _slots: Array = []               # {slot, a0, a1}
var _root: Control
var _bg: ColorRect
var _bg_mat: ShaderMaterial
var _wheel: Control
var _f_b: Font
var _f: Font
var _f_caps: Font
var _t := 0.0


static func inst() -> Node:
	if Game.has_meta("attachment_radial"):
		var s = Game.get_meta("attachment_radial")
		if is_instance_valid(s):
			return s
	var n: Node = load("res://scripts/ui/attachment_radial.gd").new()
	n.name = "AttachmentRadial"
	Game.add_child(n)
	Game.set_meta("attachment_radial", n)
	return n


static func open_for(g) -> void:
	var r = inst()
	if r != null:
		r.open(g)


static func is_open() -> bool:
	if not Game.has_meta("attachment_radial"):
		return false
	var s = Game.get_meta("attachment_radial")
	return is_instance_valid(s) and bool(s.get("_open"))


func _ready() -> void:
	layer = 7
	add_to_group("gameplay_overlay")
	_f_b = UI.font(700)
	_f = UI.font(500)
	_f_caps = UI.font_caps(700, 2)
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	_bg = ColorRect.new()
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = BLUR_SHADER
	_bg_mat = ShaderMaterial.new()
	_bg_mat.shader = sh
	_bg.material = _bg_mat
	_root.add_child(_bg)
	_wheel = Control.new()
	_wheel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wheel.draw.connect(_draw_wheel)
	_root.add_child(_wheel)


# =================================================================================================
# Open / close
# =================================================================================================

func open(g) -> void:
	if g == null or not is_instance_valid(g) or g.get("att_kit") == null:
		return
	var kit = g.att_kit
	if not kit.has_slots() or _blocked():
		return
	if bool(g.get("reloading")) or kit.busy():
		_sfx("error", -14.0, 1.0)
		return
	gun = g
	_open = true
	_sticky = false
	_t_open = 0.0
	_cursor = Vector2.ZERO
	_hover = -1
	Attachments.radial_gun = g
	_layout()
	_root.visible = true
	_sfx("open", -14.0, 1.15)
	_sfx("tick", -20.0, 1.3)


func close(sound := true) -> void:
	if not _open:
		return
	_open = false
	if Attachments.radial_gun == gun:
		Attachments.radial_gun = null
	if sound:
		_sfx("close", -16.0, 1.1)


func _blocked() -> bool:
	return Game.has_method("overlays_hidden") and Game.overlays_hidden()


## Entries round the wheel: every slot's options (the gun's own part first), each the same angle;
## the slots contiguous, the optic sector centred on top, then clockwise the muzzle, the underbarrel.
func _layout() -> void:
	_entries = []
	_slots = []
	var kit = gun.att_kit
	var have: Array = kit.slots()
	var order: Array = []
	for s in SLOT_ORDER:
		if s in have:
			order.append(s)
	var n := 0
	for s in order:
		n += (kit.options(s) as Array).size()
	if n == 0:
		return
	var w := TAU / float(n)
	var first: Array = kit.options(order[0])
	var a := -PI * 0.5 - w * float(first.size()) * 0.5
	for s in order:
		var opts: Array = kit.options(s)
		var a_s := a
		for id in opts:
			_entries.append({"slot": s, "id": str(id), "a0": a, "a1": a + w, "owned": Attachments.owned(str(id))})
			a += w
		_slots.append({"slot": s, "a0": a_s, "a1": a})


# =================================================================================================
# Input (while open: the selector, commit, cancel; mouse look held)
# =================================================================================================

func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventMouseMotion:
		var k := _scale()
		_cursor += (event as InputEventMouseMotion).relative / maxf(k, 0.01) * 0.9
		_cursor = _cursor.limit_length(R_OPT1 * 1.05)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_MIDDLE:
				if not mb.pressed:
					if _sticky:
						pass
					elif _hover < 0 and _t_open < TAP:
						_sticky = true              # a tap: stay open, click to pick
					else:
						_commit()
				elif _sticky:
					close()
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					close()
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if _hover >= 0:
						_commit()
					elif _sticky:
						close()
		get_viewport().set_input_as_handled()       # (no fire, aim or gun swap from the wheel)
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var pk := (event as InputEventKey).physical_keycode
		if event.is_action_pressed("slot_1") or event.is_action_pressed("slot_2") or event.is_action_pressed("slot_3") \
				or event.is_action_pressed("slot_4"):
			close(false)                            # a gun swap goes through and closes the wheel
		elif event.is_action_pressed("tool_mode") or event.is_action_pressed("inspect") or event.is_action_pressed("melee") \
				or event.is_action_pressed("throw_grenade") or event.is_action_pressed("scan_pulse") or pk == KEY_B or pk == KEY_T:
			get_viewport().set_input_as_handled()   # (no reload / mode / ammo / inspect from under the wheel)


func _commit() -> void:
	if _hover < 0 or _hover >= _entries.size() or gun == null or not is_instance_valid(gun):
		close()
		return
	var e: Dictionary = _entries[_hover]
	var kit = gun.att_kit
	var id := str(e["id"])
	if not Attachments.owned(id):
		# Locked: bought here and now with material (co-op: the team pool), then fitted below.
		var cost := Attachments.cost_of(id)
		if not Game.spend_material(cost):
			_sfx("error", -12.0, 1.0)
			if Game.hud:
				HudLevel.alert("Yetersiz malzeme: %d m³ eksik" % int(ceilf(cost - Game.material)), 1, "no_mat", 1.8)
			close(false)
			return
		Attachments.unlock(id)
		e["owned"] = true
		_sfx("craft", -8.0, 1.1)
		if Game.hud:
			HudLevel.alert("EKLENTİ SATIN ALINDI: %s  (−%d m³)" % [str(Attachments.def(id).get("name", id)), int(roundf(cost))], 1, "attach", 2.2)
	if kit.current(str(e["slot"])) == id:
		close()
		return
	if kit.fit(str(e["slot"]), id):
		_sfx("select", -14.0, 1.05)
		close(false)
	else:
		_sfx("error", -12.0, 1.0)
		close(false)


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	if _open:
		_t_open += delta
		var ok: bool = gun != null and is_instance_valid(gun) and bool(gun.get("equipped")) and bool(gun.get("active")) \
				and not _blocked() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		var p = gun.get("player") if ok else null
		if ok and (p == null or p.get("vehicle") != null or (p.has_method("is_ragdolled") and p.is_ragdolled()) \
				or (p.has_method("is_dead") and p.is_dead()) or bool(gun.get("reloading"))):
			ok = false
		if not ok:
			close(false)
	_k = move_toward(_k, 1.0 if _open else 0.0, delta / (UI.T_FAST if _open else UI.T_FAST * 0.8))
	if _k <= 0.0:
		if _root.visible:
			_root.visible = false
		if Attachments.radial_gun != null and not _open:
			Attachments.radial_gun = null
		return
	_root.visible = true
	_bg_mat.set_shader_parameter("k", UI.smooth(_k) * 0.9)
	if _open:
		_hover = _pick()
	_wheel.queue_redraw()


func _scale() -> float:
	return UI.scale_k(_wheel.size if _wheel != null else Vector2(1920, 1080))


func _pick() -> int:
	if _cursor.length() < R_DEAD:
		return -1
	var a := _cursor.angle()
	for i in _entries.size():
		var e: Dictionary = _entries[i]
		var a0 := float(e["a0"])
		var d := fposmod(a - a0, TAU)
		if d < float(e["a1"]) - a0:
			return i
	return -1


# =================================================================================================
# Drawing
# =================================================================================================

func _draw_wheel() -> void:
	if gun == null or not is_instance_valid(gun) or _entries.is_empty():
		return
	var kit = gun.att_kit
	var vs := _wheel.size
	var k := _scale()
	var e := UI.smooth(_k)
	var c := vs * 0.5
	var sc := k * lerpf(0.86, 1.0, e)
	var al := e
	var hov: Dictionary = _entries[_hover] if _hover >= 0 and _hover < _entries.size() else {}
	var hov_slot := str(hov.get("slot", ""))
	# Slot band.
	for s in _slots:
		var on := str(s["slot"]) == hov_slot
		var a0 := float(s["a0"]) + 0.012
		var a1 := float(s["a1"]) - 0.012
		_sector(c, R_SLOT0 * sc, R_SLOT1 * sc, a0, a1, Color(UI.GLASS_HI if on else UI.GLASS, (0.9 if on else 0.78) * al),
				Color(UI.SUIT_ORANGE if on else UI.SUIT_WHITE, (0.75 if on else 0.18) * al))
		var am := (a0 + a1) * 0.5
		var lp := c + Vector2.from_angle(am) * (R_SLOT0 + R_SLOT1) * 0.5 * sc
		var lab: String = Attachments.SLOT_NAMES.get(str(s["slot"]), "")
		var fs := UI.fs(UI.FS_TINY, k)
		UI.draw_text_c(_wheel, _f_caps, lp + Vector2(0, fs * 0.36), lab, fs,
				Color(UI.SUIT_ORANGE if on else UI.DIM, al), 2)
	# Option cells.
	for i in _entries.size():
		var en: Dictionary = _entries[i]
		var id := str(en["id"])
		var slot := str(en["slot"])
		var owned: bool = en["owned"]
		var cur: bool = kit.current(slot) == id
		var hv := i == _hover
		var a0 := float(en["a0"]) + 0.014
		var a1 := float(en["a1"]) - 0.014
		var fill := Color(UI.GLASS_HI if hv else UI.GLASS, (0.92 if hv else 0.8) * al)
		var edge := Color(UI.SUIT_WHITE, 0.16 * al)
		if hv:
			edge = Color(UI.SUIT_ORANGE if owned else (UI.WARN if Game.material + 0.001 >= Attachments.cost_of(id) else UI.BAD), 0.95 * al)
		elif cur:
			edge = Color(UI.SCREEN_CYAN, 0.6 * al)
		var r1 := R_OPT1 * sc * (1.03 if hv else 1.0)
		_sector(c, R_OPT0 * sc, r1, a0, a1, fill, edge)
		if cur:
			_wheel.draw_arc(c, R_OPT0 * sc + 3.0 * k, a0 + 0.02, a1 - 0.02, 16, Color(UI.SCREEN_CYAN, 0.9 * al), 3.0 * k, true)
		var am := (a0 + a1) * 0.5
		var dir := Vector2.from_angle(am)
		var ic := c + dir * (R_OPT0 + R_OPT1) * 0.47 * sc
		var col: Color
		if not owned:
			col = Color(UI.FAINT, 0.55 * al)
		elif hv:
			col = Color(UI.SUIT_WHITE, al)
		else:
			col = Color(UI.TEXT, 0.82 * al)
		var isz := 19.0 * sc
		if id == "":
			Attachments.draw_empty_icon(_wheel, slot, ic - Vector2(0, 6.0 * sc), isz, Color(col, col.a * 0.8))
		else:
			Attachments.draw_icon(_wheel, id, ic - Vector2(0, 6.0 * sc), isz, col)
		var nm: String = EMPTY_SHORT.get(slot, "") if id == "" else str(SHORT.get(id, id))
		var fs2 := UI.fs(UI.FS_TINY, k)
		UI.draw_text_c(_wheel, _f_b, ic + Vector2(0, 26.0 * sc), nm, fs2, Color(col, col.a), 2)
		if not owned:
			# Its price under the name (amber: affordable, a pick buys it; red: not enough material).
			var pc := Attachments.cost_of(id)
			UI.draw_text_c(_wheel, _f_b, ic + Vector2(0, 41.0 * sc), "%d m³" % int(roundf(pc)), UI.fs(10, k),
					Color(UI.WARN if Game.material + 0.001 >= pc else UI.BAD, (1.0 if hv else 0.75) * al), 2)
		elif cur:
			UI.draw_text_c(_wheel, _f_caps, ic + Vector2(0, 40.0 * sc), "TAKILI", UI.fs(10, k), Color(UI.SCREEN_CYAN, 0.9 * al), 2)
	# Centre: the gun, the hints, the selector.
	_wheel.draw_circle(c, R_IN * sc, Color(UI.GLASS, 0.82 * al))
	_wheel.draw_arc(c, R_IN * sc, 0.0, TAU, 48, Color(UI.SUIT_WHITE, 0.2 * al), 1.0, true)
	var gname := UI.upper_tr(str(gun.get("item_name")))
	var fsn := UI.fs(UI.FS_TINY, k)
	UI.draw_text_c(_wheel, _f_caps, c + Vector2(0, -10.0 * sc), _fit_w(gname, fsn, R_IN * 1.7 * sc), fsn, Color(UI.SUIT_ORANGE, al), 2)
	var hint := "tıkla: tak" if _sticky else "bırak: tak"
	UI.draw_text_c(_wheel, _f, c + Vector2(0, 8.0 * sc), hint, UI.fs(10, k), Color(UI.DIM, 0.9 * al), 2)
	UI.draw_text_c(_wheel, _f, c + Vector2(0, 21.0 * sc), "sağ tık: iptal", UI.fs(10, k), Color(UI.FAINT, 0.9 * al), 2)
	if _cursor.length() > 4.0:
		var cd := _cursor.normalized()
		var tip := c + cd * (R_IN - 2.0) * sc
		var side := Vector2(-cd.y, cd.x) * 6.0 * sc
		_wheel.draw_colored_polygon(PackedVector2Array([tip + cd * 7.0 * sc, tip + side, tip - side]),
				Color(UI.SUIT_ORANGE, (0.95 if _hover >= 0 else 0.45) * al))
	# The hovered entry's panel beside the wheel.
	if not hov.is_empty():
		_panel(c + Vector2((R_OPT1 + 26.0) * sc, -112.0 * sc), k, sc, al, hov, kit)


## Annular sector (ring r0..r1, angles a0..a1) filled, with an outline.
func _sector(c: Vector2, r0: float, r1: float, a0: float, a1: float, fill: Color, edge: Color) -> void:
	var n := maxi(int(ceilf((a1 - a0) / 0.06)), 3)
	var pts := PackedVector2Array()
	for i in n + 1:
		pts.append(c + Vector2.from_angle(lerpf(a0, a1, float(i) / n)) * r1)
	for i in n + 1:
		pts.append(c + Vector2.from_angle(lerpf(a1, a0, float(i) / n)) * r0)
	_wheel.draw_colored_polygon(pts, fill)
	var ol := pts.duplicate()
	ol.append(pts[0])
	_wheel.draw_polyline(ol, edge, 1.0, true)


func _panel(pos: Vector2, k: float, sc: float, al: float, en: Dictionary, kit) -> void:
	var id := str(en["id"])
	var slot := str(en["slot"])
	var d: Dictionary = Attachments.def(id)
	var w := 330.0 * sc
	var title: String = str(Attachments.EMPTY_NAMES.get(slot, "")) if id == "" else str(d.get("name", id))
	var desc: String = str(Attachments.EMPTY_DESC.get(slot, "")) if id == "" else str(d.get("desc", ""))
	var stats: Array = [] if id == "" else Attachments.stats_text(id)
	var owned := Attachments.owned(id)
	var cur: bool = kit.current(slot) == id
	var fs_t := UI.fs(UI.FS_LEAD, k)
	var fs_s := UI.fs(UI.FS_SMALL, k)
	var fs_x := UI.fs(UI.FS_TINY, k)
	var lines := _wrap(desc, _f, fs_x, w - 28.0 * sc)
	var h := (64.0 + 19.0 * stats.size() + 15.0 * lines.size() + 26.0) * sc
	var r := Rect2(pos, Vector2(w, h))
	UI.draw_glass(_wheel, r, k, UI.SUIT_ORANGE if owned else (UI.WARN if Game.material + 0.001 >= Attachments.cost_of(id) else UI.BAD), 0.6, al)
	var x := pos.x + 14.0 * sc
	var y := pos.y + 26.0 * sc
	UI.draw_text(_wheel, _f_b, Vector2(x, y), title, fs_t, Color(UI.TEXT, al))
	y += 18.0 * sc
	var cost := Attachments.cost_of(id)
	var afford := Game.material + 0.001 >= cost
	var state := "TAKILI" if cur else ("ELİNDE · TAKMAK İÇİN BIRAK" if owned else ("SATIN AL · BIRAK" if afford else "KİLİTLİ"))
	var sc_col := UI.SCREEN_CYAN if cur else (UI.DIM if owned else (UI.WARN if afford else UI.BAD))
	UI.draw_text(_wheel, _f_caps, Vector2(x, y), "%s · %s" % [Attachments.SLOT_NAMES.get(slot, ""), state], fs_x, Color(sc_col, al), 2)
	y += 8.0 * sc
	if not owned:
		y += 16.0 * sc
		var buy := ("Satın al · %d m³" % int(roundf(cost))) if afford else \
				("Satın al · %d m³  (%d eksik)" % [int(roundf(cost)), int(ceilf(cost - Game.material))])
		UI.draw_text(_wheel, _f_b, Vector2(x, y), buy, fs_s, Color(UI.WARN if afford else UI.BAD, al), 2)
	for s: Array in stats:
		y += 19.0 * sc
		var good: bool = s[2]
		UI.draw_text(_wheel, _f, Vector2(x, y), str(s[0]), fs_s, Color(UI.DIM, al), 2)
		UI.draw_text_r(_wheel, _f_b, pos.x + w - 14.0 * sc, y, str(s[1]), fs_s, Color(UI.GOOD if good else UI.BAD, al), 2)
	y += 8.0 * sc
	for ln in lines:
		y += 15.0 * sc
		UI.draw_text(_wheel, _f, Vector2(x, y), ln, fs_x, Color(UI.FAINT.lerp(UI.TEXT, 0.4), al), 0)


## Greedy word wrap to `width` px.
func _wrap(s: String, f: Font, size: int, width: float) -> Array:
	var out: Array = []
	var line := ""
	for word in s.split(" ", false):
		var t := word if line == "" else line + " " + word
		if UI.text_w(f, t, size) > width and line != "":
			out.append(line)
			line = word
		else:
			line = t
	if line != "":
		out.append(line)
	return out


## Cuts a label to fit `width` px (an ellipsis at the end).
func _fit_w(s: String, size: int, width: float) -> String:
	if UI.text_w(_f_caps, s, size) <= width:
		return s
	var t := s
	while t.length() > 3 and UI.text_w(_f_caps, t + "…", size) > width:
		t = t.substr(0, t.length() - 1)
	return t + "…"


func _sfx(n: String, db: float, pitch: float) -> void:
	if Game.sfx != null and is_instance_valid(Game.sfx):
		Game.sfx.play(n, db, pitch)
