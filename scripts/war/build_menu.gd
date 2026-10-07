extends CanvasLayer
## The İnşa Aracı's selection UI (owned by scripts/war/build_tool.gd, shown while it is held on
## foot), in the design system's look (scripts/ui/ui_style.gd: wrist-screen glass, suit-white
## frames, orange on what is active). Laid out for 1080p and scaled with the window height (and down
## further when a long category would not fit the width). Everything is drawn (no card nodes):
##   header   "İNŞA", the category tabs when the tool has them (tool.categories / tool.category,
##            entries tagged "cat"; Q / E switch them: the orange underline glides to the new tab and
##            its cards slide in from that side), and the material on the right (flashes red when a
##            build is refused for material)
##   cards    one per entry of the shown category: the rendered thumbnail of the real model
##            (scripts/war/build_preview.gd) on a soft spotlight (the selected card's model turns
##            gently and a glint sweeps it), where it may stand (YURT / DÜŞMAN / HER YER chip,
##            Balance.build_site), the name, the cost in m³ (big; red when short), GÖVDE, an
##            affordability bar (how much of the cost you have) with "HAZIR" or "EKSİK NN m³", and
##            two lines of role. The selected card lifts, pops and gets the orange strip.
##            Variants (an entry's "variants" [entry-shaped dictionaries] + "variant"; the selected card
##            follows tool.variant_index; T / Shift + wheel cycle them in build_tool.gd): caps chips under
##            the name (label: "variant_name" / "label" / "tur" / "short" / "name"), the active one
##            under an orange plate that glides to it; on a switch the old model slides out and the
##            new one in, the name and cost slide over; too many chips to fit: pips + the active name.
##            Without "variants" a card is drawn as before.
##   hints    key caps: wheel select · T tür (with variants) · Q / E category · R 45° · RMB free turn ·
##            LMB build. Three categories or fewer: wider, centred, calmer tabs.
## Under the crosshair: the verdict pill in the hologram's colours (scripts/war/build_holo.gd: cyan-white
## "KURULABİLİR · −NN m³", amber fixable reason, red blocked reason, grey hint) that
## shakes and flashes when a build is refused (tool.refuse_k), and the rotation dial with the angle (tool.rot_deg, or
## the tool's target rotation), which lights up when it turns.
## Data from the tool (duck-typed, any of it may be missing): entries, index, can_build, aim_valid,
## reason, menu_wanted(), categories, category, all_entries, rot_deg.

const UI := preload("res://scripts/ui/ui_style.gd")
const BuildPreview := preload("res://scripts/war/build_preview.gd")
const Balance := preload("res://scripts/war/balance.gd")
const BuildHolo := preload("res://scripts/war/build_holo.gd")

const CARD_W := 176.0
const CARD_H := 242.0                      # (+10: the "NE İŞE YARAR" line, 2026-10-06)
const THUMB_H := 108.0
const GAP := 10.0
const LIFT := 16.0
const HEAD := 46.0                        # header row above the cards (and the lift)
const BOTTOM := 120.0                     # cards' bottom above the window's bottom (the quickbar)
const SLIDE := 70.0                       # px a category's cards slide in from
const VAR_ROW := 22.0                     # the variant chips' row (cards grow by it when a card has variants)
## Kept for older references.
const ACCENT := Color(0.4, 0.92, 1.0)
const COST_COL := Color(1.0, 0.66, 0.3)
const BAD := Color(1.0, 0.42, 0.36)
const GOOD := Color(0.45, 0.95, 0.62)

var tool                                  # build_tool.gd

var _root: Control
var _bar: Control
var _ver: Control
var _font: Font
var _font_b: Font
var _font_n: Font
var _cards: Array = []                    # {key, idx, lift, vars, vi, vswap, vdir, chip_x} + the active variant's
                                          #  {id, name, label, cost_s, hp_s, desc, site, price, short_s, under, modular}
var _has_variants := false                # some card of the shown category has variants (the "T: tür" hint)
var _on_own := true                       # the player stands on our planet (the site check)
var _sig := ""
var _sig_t := 0.0
var _sig_n := -1
var _cat := -1
var _cat_dir := 0.0
var _cat_k := 1.0
var _cats: Array = []
var _counts: Array = []
var _tab_x := 0.0                         # the gliding underline (px, eased toward _tab_tx / _tab_tw)
var _tab_w := 0.0
var _tab_tx := 0.0
var _tab_tw := 0.0
var _shown := 0.0
var _t := 0.0
var _sel := -1                            # the selected card (index into _cards)
var _mat_i := -1
var _refuse := 0.0
var _refuse_mat := 0.0
var _tool_refuse := 0.0
var _rot_deg := 0.0
var _rot_flash := 0.0
var _rot_known := false
var _v_text := ""
var _v_kind := 0                          # 0 none, 1 can build, 2 blocked (red), 3 a hint (grey), 4 fixable (amber)
var _v_key := ""
var _mat_s := "0"
var _rot_i := -1
var _rot_s := "0°"
var _spot: GradientTexture2D
var _floor: GradientTexture2D


func _ready() -> void:
	layer = 6
	add_to_group("gameplay_overlay")             # hidden on the end screen / menus (overlay_guard.gd)
	_font = UI.font(500)
	_font_b = UI.font(700)
	_font_n = UI.font_num(700)
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.modulate.a = 0.0
	add_child(_root)
	_bar = Control.new()
	_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.draw.connect(_draw_bar)
	_root.add_child(_bar)
	_ver = Control.new()
	_ver.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ver.draw.connect(_draw_verdict)
	_root.add_child(_ver)
	_spot = _radial(Color(0.45, 0.85, 1.0, 0.3), Vector2(0.5, 0.66), Vector2(0.5, 0.0))
	_floor = _radial(Color(0.0, 0.02, 0.03, 0.55), Vector2(0.5, 0.5), Vector2(1.0, 0.5))


static func _radial(col: Color, from: Vector2, to: Vector2) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, col)
	g.set_color(1, Color(col, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = from
	gt.fill_to = to
	gt.width = 128
	gt.height = 128
	return gt


# =================================================================================================
# Data
# =================================================================================================

func _entries() -> Array:
	var e = tool.get("entries")
	return e if e is Array else []


## Entries of every category (for the tab counts and the thumbnails).
func _all_entries() -> Array:
	var a = tool.get("all_entries")
	return a if a is Array and not (a as Array).is_empty() else _entries()


func _categories() -> Array:
	var c = tool.get("categories")
	return c if c is Array else []


func _category() -> int:
	var c = tool.get("category")
	return int(c) if c != null else 0


## The cards of the shown category (all entries without categories).
func _rebuild(entries: Array, cat_name: String) -> void:
	var old := {}
	for c in _cards:
		old[str(c["key"])] = c
	_cards.clear()
	for i in entries.size():
		var e = entries[i]
		if not (e is Dictionary):
			continue
		var d := e as Dictionary
		if cat_name != "" and d.has("cat") and str(d["cat"]) != cat_name:
			continue
		# Variants (Top: Standart / Delici, ...): the card shows the active one, chips for all.
		var vars: Array = []
		var vl = d.get("variants")
		if vl is Array:
			for v in vl:
				if v is Dictionary:
					vars.append(_card_data(v as Dictionary, d))
		if vars.is_empty():
			vars.append(_card_data(d, d))
		var key := str(d.get("card", d.get("id", "")))          # (the card id: stable across its variants)
		var c := {"key": key, "idx": i, "lift": 0.0, "vars": vars, "vi": -1, "vswap": 0.0, "vdir": 1.0, "chip_x": 0.0}
		if old.has(key):
			c["lift"] = float(old[key]["lift"])
		_set_variant(c, clampi(int(d.get("variant", 0)), 0, vars.size() - 1), false)
		c["chip_x"] = float(c["vi"])
		_cards.append(c)
	_mat_i = -1
	# Thumbnails of every entry and every variant.
	var th: Array = []
	for e in _all_entries():
		if not (e is Dictionary):
			continue
		var vv = (e as Dictionary).get("variants")
		if vv is Array and not (vv as Array).is_empty():
			for v in vv:
				if v is Dictionary:
					th.append(v)
		else:
			th.append(e)
	BuildPreview.request_thumbs(get_tree(), th)


## One variant's (or a plain entry's) card data; `base` fills in what the variant leaves out.
func _card_data(v: Dictionary, base: Dictionary) -> Dictionary:
	var id := str(v.get("id", base.get("id", "")))
	var scr = v.get("script", base.get("script"))
	var sp := (scr as Script).resource_path if scr is Script else ""
	var price := float(v.get("cost", base.get("cost", 0.0)))
	var hp := float(v.get("hp", base.get("hp", 0.0)))
	var nm := str(v.get("name", base.get("name", "")))
	var label := ""
	for kk in ["variant_name", "label", "tur", "short"]:
		if v.has(kk) and str(v[kk]) != "":
			label = str(v[kk])
			break
	if label == "":
		label = nm
	return {"id": id, "name": nm, "label": UI.upper_tr(label), "cost_s": "%d" % int(price),
			"hp_s": ("GÖVDE %d" % int(hp)) if hp > 0.0 else "",
			"desc": str(v.get("what", base.get("what", v.get("desc", base.get("desc", ""))))),     # ("NE İŞE YARAR")
			"site": Balance.build_site(id, sp), "sp": sp, "price": price, "short_s": "",
			"under": bool(v.get("under", base.get("under", false))), "modular": bool(v.get("modular", base.get("modular", false)))}


## Whether the card's active variant may stand on the planet the player is on (Balance.BUILD_SITE).
func _site_check(c: Dictionary) -> void:
	c["site_bad"] = Balance.build_site_reason(str(c.get("id", "")), str(c.get("sp", "")), _on_own) != ""


## Card c shows variant vi: its fields are copied onto the card (the drawing reads them there);
## `anim`: a switch (the thumbnail and the text slide over, the chip highlight glides).
func _set_variant(c: Dictionary, vi: int, anim := true) -> void:
	var vars: Array = c["vars"]
	vi = clampi(vi, 0, vars.size() - 1)
	if vi == int(c["vi"]):
		return
	if anim and int(c["vi"]) >= 0:
		c["vswap"] = 1.0
		c["vdir"] = 1.0 if vi > int(c["vi"]) else -1.0
		c["prev_id"] = str(c.get("id", ""))
	c["vi"] = vi
	var v: Dictionary = vars[vi]
	for kk in v:
		c[kk] = v[kk]
	var short := float(c["price"]) - Game.material
	c["short_s"] = ("EKSİK %d m³" % int(ceilf(short))) if short > 0.001 else ""
	c["desc_key"] = -1
	_site_check(c)


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	var want: bool = tool != null and is_instance_valid(tool) and bool(tool.call("menu_wanted"))
	_shown = move_toward(_shown, 1.0 if want else 0.0, delta * (7.0 if want else 9.0))
	_root.modulate.a = _shown
	_root.visible = _shown > 0.001
	if not _root.visible:
		return
	_t += delta
	# The planet under the player: which cards may stand here ("BURADA KURULAMAZ").
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl is Node3D:
		var own: bool = Game.dominant_body((pl as Node3D).global_position) == Game.planet
		if own != _on_own:
			_on_own = own
			for c in _cards:
				_site_check(c)
	var entries := _entries()
	var cats := _categories()
	var cat := clampi(_category(), 0, maxi(cats.size() - 1, 0))
	# What the bar shows: rebuilt when the entries or the category change (checked 5× a second, at
	# once when the count or the category changes).
	_sig_t -= delta
	if _sig_t <= 0.0 or entries.size() != _sig_n or cat != _cat or cats.size() != _cats.size():
		_sig_t = 0.2
		_sig_n = entries.size()
		var s := ""
		for e in entries:
			if e is Dictionary:
				s += str((e as Dictionary).get("card", (e as Dictionary).get("id", ""))) + ","
		s += "|%d|%d" % [cat, cats.size()]
		if s != _sig:
			_sig = s
			if _cat >= 0 and cat != _cat and not cats.is_empty():
				_cat_dir = 1.0 if cat > _cat else -1.0
				_cat_k = 0.0
				if Game.sfx:
					Game.sfx.play("click", -12.0, 1.3)
			_cat = cat
			_cats = cats.duplicate()
			_count_cats(cats)
			_rebuild(entries, str(cats[cat]) if not cats.is_empty() else "")
	_cat_k = move_toward(_cat_k, 1.0, delta / 0.28)
	_tab_x = UI.approach(_tab_x, _tab_tx, 16.0, delta)
	_tab_w = UI.approach(_tab_w, _tab_tw, 16.0, delta)
	# Selection, lift, material.
	var index := int(tool.get("index")) if tool.get("index") != null else -1
	var tvi = tool.get("variant_index")
	_sel = -1
	_has_variants = false
	for i in _cards.size():
		var c: Dictionary = _cards[i]
		var on := int(c["idx"]) == index
		if on:
			_sel = i
		c["lift"] = move_toward(float(c["lift"]), 1.0 if on else 0.0, delta * 6.5)
		# The active variant: the entry's "variant" (the selected card: tool.variant_index).
		var nv := (c["vars"] as Array).size()
		if nv > 1:
			_has_variants = true
			var vi := int(c["vi"])
			var ix := int(c["idx"])
			if on and tvi != null:
				vi = int(tvi)
			elif ix < entries.size() and entries[ix] is Dictionary:
				vi = int((entries[ix] as Dictionary).get("variant", vi))
			if vi != int(c["vi"]):
				_set_variant(c, vi)
		c["vswap"] = maxf(float(c["vswap"]) - delta / 0.32, 0.0)
		c["chip_x"] = UI.approach(float(c["chip_x"]), float(c["vi"]), 18.0, delta)
	var mi := int(floorf(Game.material + 0.0001))
	if mi != _mat_i:
		_mat_i = mi
		_mat_s = "%d" % mi
		for c in _cards:
			for v in c["vars"]:
				var vs := float(v["price"]) - Game.material
				v["short_s"] = ("EKSİK %d m³" % int(ceilf(vs))) if vs > 0.001 else ""
			var short := float(c["price"]) - Game.material
			c["short_s"] = ("EKSİK %d m³" % int(ceilf(short))) if short > 0.001 else ""
	# A refused build (LMB while it cannot be built): the verdict shakes, a short card flashes.
	var can := bool(tool.get("can_build"))
	var rk = tool.get("refuse_k")                 # build_tool.gd: 1 on a refused click, decays
	var refused := false
	if rk != null:
		refused = float(rk) > _tool_refuse + 0.3
		_tool_refuse = float(rk)
	elif want and not can and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_action_just_pressed("tool_use"):
		refused = true
	if refused:
		_refuse = 1.0
		if _sel >= 0 and str(_cards[_sel]["short_s"]) != "":
			_refuse_mat = 1.0
	_refuse = maxf(maxf(_refuse - delta * 2.2, 0.0), _tool_refuse if rk != null else 0.0)
	_refuse_mat = maxf(_refuse_mat - delta * 1.6, 0.0)
	# Rotation readout.
	var rd = tool.get("rot_deg")
	var deg := 0.0
	_rot_known = true
	if rd != null:
		deg = float(rd)
	elif tool.get("_rot_t") != null:
		deg = rad_to_deg(float(tool.get("_rot_t")))
	else:
		_rot_known = false
	deg = fposmod(deg, 360.0)
	if absf(angle_difference(deg_to_rad(deg), deg_to_rad(_rot_deg))) > 0.004:
		_rot_flash = 1.0
	_rot_deg = deg
	var ri := int(roundf(deg)) % 360
	if ri != _rot_i:
		_rot_i = ri
		_rot_s = "%d°" % ri
	_rot_flash = maxf(_rot_flash - delta * 2.0, 0.0)
	# The verdict.
	var r = tool.get("reason")
	var price := int(_cards[_sel]["price"]) if _sel >= 0 else 0
	var aim := bool(tool.get("aim_valid"))
	var under: bool = tool.get("underground") == true
	var snap: bool = tool.get("snapped") == true
	var vk := "%s|%s|%d|%s|%s|%s" % [can, aim, price, r, under, snap]
	if vk != _v_key:
		_v_key = vk
		var rs := str(r) if r != null else ""
		if can:
			_v_kind = 1
			_v_text = "KURULABİLİR  ·  sol tık" + (("  ·  −%d m³" % price) if price > 0 else "")
			if under:
				_v_text += "  ·  yeraltı"
			if snap:
				_v_text += "  ·  kenetlendi"
		elif rs != "":
			_v_kind = 2 if aim else 3
			# The hologram's amber "fixable here" (slope, uneven, too close) vs red "blocked".
			if aim and tool.has_method("_ghost_state") and int(tool.call("_ghost_state")) == 1:
				_v_kind = 4
			_v_text = rs
		else:
			_v_kind = 0
			_v_text = ""
	_bar.queue_redraw()
	_ver.queue_redraw()


func _count_cats(cats: Array) -> void:
	_counts.clear()
	var all := _all_entries()
	for cn in cats:
		var n := 0
		for e in all:
			if e is Dictionary and str((e as Dictionary).get("cat", "")) == str(cn):
				n += 1
		_counts.append(n)


# =================================================================================================
# Drawing: the bar
# =================================================================================================

func _draw_bar() -> void:
	var vs := _bar.size
	var k := UI.scale_k(vs)
	var n := _cards.size()
	var row_w := maxf(n * CARD_W + maxf(n - 1, 0) * GAP, 720.0)
	var s := minf(k, (vs.x - 48.0) / row_w)                  # card scale (fits the width)
	var cw := CARD_W * s
	var ch := (CARD_H + (VAR_ROW if _has_variants else 0.0)) * s
	var total := n * cw + maxf(n - 1, 0) * GAP * s
	var bottom := vs.y - BOTTOM * k
	var top := bottom - ch
	var x0 := vs.x * 0.5 - total * 0.5
	var head_w := maxf(total, 720.0 * s)
	var hx0 := vs.x * 0.5 - head_w * 0.5
	_draw_header(Rect2(hx0, top - (HEAD + LIFT) * s, head_w, HEAD * s), s)
	# The recommendation's line over the header (build_tool.gd recommend_card / recommend_reason).
	var rc := str(tool.get("recommend_card")) if tool.get("recommend_card") != null else ""
	var rr := str(tool.get("recommend_reason")) if tool.get("recommend_reason") != null else ""
	if rc != "" and rr != "":
		var rname := rc
		for e in _all_entries():
			if e is Dictionary and str((e as Dictionary).get("card", "")) == rc:
				rname = str((e as Dictionary).get("card_name", (e as Dictionary).get("name", rc)))
				break
		var rf := UI.font_caps(700, 2)
		var rfs := UI.fs(10, s)
		var lead := "ÖNERİLEN · " + UI.upper_tr(rname)
		var tfs := UI.fs(13, s)
		var lw := UI.text_w(rf, lead, rfs)
		var tw := UI.text_w(_font_b, rr, tfs)
		var pw := lw + tw + 34.0 * s
		# (left of the header strip, on its line: clear of the verdict over it and the guide plate)
		var py := top - (HEAD + LIFT) * s + HEAD * s * 0.5 - 12.0 * s
		var pr := Rect2(Vector2(maxf(hx0 - 22.0 * s - pw, 12.0 * k), py), Vector2(pw, 24.0 * s))
		UI.draw_chamfer(_bar, pr, 6.0 * s, Color(UI.GLASS, 0.78), Color(UI.SUIT_ORANGE, 0.7))
		_bar.draw_rect(Rect2(pr.position + Vector2(8.0 * s, 6.0 * s), Vector2(3.0 * s, 12.0 * s)), UI.SUIT_ORANGE)
		UI.draw_text(_bar, rf, Vector2(pr.position.x + 16.0 * s, pr.get_center().y + rfs * 0.36), lead, rfs, UI.SUIT_ORANGE.lightened(0.2), 0)
		UI.draw_text(_bar, _font_b, Vector2(pr.position.x + 24.0 * s + lw, pr.get_center().y + tfs * 0.36), rr, tfs, UI.TEXT, 2)
	if n == 0:
		UI.draw_text_c(_bar, _font, Vector2(vs.x * 0.5, top + ch * 0.5), "Bu kategoride yapı yok", UI.fs(15, s), UI.DIM)
	# Category switch: the new cards slide in from that side and fade up.
	var ck := UI.smooth(_cat_k)
	var slide := _cat_dir * (1.0 - ck) * SLIDE * s
	var mat := Game.material
	for i in n:
		var c: Dictionary = _cards[i]
		var lift := UI.smooth(float(c["lift"]))
		var pop := 1.0 + 0.04 * lift
		var w := cw * pop
		var h := ch * pop
		var cx := x0 + i * (cw + GAP * s) + cw * 0.5 + slide * (1.0 + i * 0.08)
		var r := Rect2(Vector2(cx - w * 0.5, bottom - h - LIFT * s * lift), Vector2(w, h))
		_draw_card(c, r, s * pop, lift, mat, ck * (1.0 if i == _sel else 0.9))
	_draw_hints(Vector2(vs.x * 0.5, vs.y - 98.0 * k), k)


func _draw_header(r: Rect2, s: float) -> void:
	var y := r.position.y + r.size.y * 0.5
	# A glass strip behind the whole header row (legible over sky, snow and the view model).
	UI.draw_chamfer(_bar, Rect2(r.position + Vector2(-10.0 * s, 4.0 * s), r.size + Vector2(20.0 * s, -6.0 * s)), 8.0 * s,
			Color(UI.GLASS, 0.62), Color(UI.SUIT_WHITE, 0.08))
	var fs_t := UI.fs(16, s)
	var caps := UI.font_caps(700, maxi(int(roundf(3.0 * s)), 1))
	# "İNŞA" with the orange tick.
	_bar.draw_rect(Rect2(r.position.x, y - 9.0 * s, 3.0 * s, 18.0 * s), UI.SUIT_ORANGE)
	UI.draw_text(_bar, caps, Vector2(r.position.x + 10.0 * s, y + fs_t * 0.36), "İNŞA", fs_t, UI.SUIT_WHITE)
	var x := r.position.x + 10.0 * s + UI.text_w(caps, "İNŞA", fs_t) + 22.0 * s
	# Category tabs (Q / E).
	if not _cats.is_empty():
		x += UI.draw_key(_bar, Vector2(x, y - 10.0 * s), "Q", s, false, 0.9, 11) + 8.0 * s
		# Few categories (3): wider, calmer tabs (a fixed width, more letter spacing).
		var calm := _cats.size() <= 3
		var tf := UI.font_caps(700, maxi(int(roundf((3.0 if calm else 1.5) * s)), 1))
		var tfs := UI.fs(14 if calm else 13, s)
		var th := (30.0 if calm else 28.0) * s
		for i in _cats.size():
			var tname := UI.upper_tr(str(_cats[i]))
			var cnt := str(_counts[i]) if i < _counts.size() else ""
			var tw := UI.text_w(tf, tname, tfs)
			var cwid := UI.text_w(_font_n, cnt, UI.fs(10, s)) if cnt != "" else 0.0
			var w := tw + cwid + 26.0 * s
			if calm:
				w = maxf(w, 132.0 * s)
			var on := i == _cat
			var tr := Rect2(Vector2(x, y - th * 0.5), Vector2(w, th))
			UI.draw_chamfer(_bar, tr, 6.0 * s, Color(UI.GLASS_HI if on else UI.GLASS, 0.86 if on else 0.55),
					Color(UI.SUIT_WHITE, 0.4 if on else 0.12))
			var tx0 := x + 10.0 * s
			if calm:
				tx0 = x + (w - tw - (cwid + 4.0 * s if cnt != "" else 0.0)) * 0.5     # (centred)
			UI.draw_text(_bar, tf, Vector2(tx0, y + tfs * 0.36), tname, tfs, UI.SUIT_WHITE if on else UI.DIM)
			if cnt != "":
				UI.draw_text(_bar, _font_n, Vector2(tx0 + tw + 4.0 * s, y - 2.0 * s), cnt, UI.fs(10, s),
						Color(UI.SUIT_ORANGE if on else UI.FAINT, 0.95))
			# The recommended card's tab: a pulsing orange dot (build_tool.gd card_category()).
			if tool.has_method("card_category") and str(tool.get("recommend_card")) != "" \
					and int(tool.call("card_category", str(tool.get("recommend_card")))) == i:
				_bar.draw_circle(Vector2(x + w - 5.0 * s, y - th * 0.5 + 5.0 * s), 3.5 * s, Color(UI.SUIT_ORANGE, 0.7 + 0.3 * sin(_t * 5.0)))
			if on:
				_tab_tx = x
				_tab_tw = w
				if _tab_w <= 0.5:
					_tab_x = x
					_tab_w = w
			x += w + 6.0 * s
		# The gliding underline.
		_bar.draw_rect(Rect2(Vector2(_tab_x + 6.0 * s, y + th * 0.5 + 2.0 * s), Vector2(maxf(_tab_w - 12.0 * s, 0.0), 2.5 * s)),
				UI.SUIT_ORANGE)
		x += 2.0 * s
		UI.draw_key(_bar, Vector2(x, y - 10.0 * s), "E", s, false, 0.9, 11)
	else:
		UI.draw_text(_bar, _font, Vector2(x, y + UI.fs(13, s) * 0.36), "teker: seç  ·  sol tık: kur", UI.fs(13, s), UI.DIM)
	# Material on the right (flashes red on a refusal for material).
	var right := r.end.x
	var mfs := UI.fs(22, s)
	var mcol := UI.TEXT.lerp(UI.BAD, _refuse_mat)
	var unit := " m³"
	right -= UI.draw_text_r(_bar, _font, right, y + mfs * 0.36, unit, UI.fs(14, s), UI.DIM)
	right -= UI.draw_text_r(_bar, _font_n, right, y + mfs * 0.36, _mat_s, mfs, mcol) + 10.0 * s
	var lf := UI.font_caps(700, maxi(int(roundf(2.0 * s)), 1))
	UI.draw_text_r(_bar, lf, right, y + UI.fs(11, s) * 0.36, "TAKIM" if Game.get("shared_pool") == true else "MALZEME",
			UI.fs(11, s), Color(UI.DIM, 0.95))                 # (co-op: the team pool; the HUD says TAKIM MALZEMESİ)
	# A hairline under the header.
	_bar.draw_rect(Rect2(r.position.x, r.end.y - 1.0, r.size.x, 1.0), Color(UI.SUIT_WHITE, 0.1))


## One card in r (s: its scale, lift 0..1 selected, a: alpha).
func _draw_card(c: Dictionary, r: Rect2, s: float, lift: float, mat: float, a: float) -> void:
	var price := float(c["price"])
	var afford := mat + 0.001 >= price
	var accent := UI.SUIT_ORANGE if afford else UI.BAD
	var dim := 1.0 if afford else 0.72
	a *= lerpf(0.88, 1.0, lift)
	var flash := _refuse_mat * lift
	# A darker underlay: the cards stay readable over snow and the bright view model.
	UI.draw_chamfer(_bar, r, UI.CUT * s, Color(UI.GLASS, 0.6 * a))
	UI.draw_glass(_bar, r, s, accent, lift, a)
	if flash > 0.01:
		UI.draw_chamfer(_bar, r, UI.CUT * s, Color(UI.BAD, 0.12 * flash), Color(UI.BAD, 0.9 * flash), 2)
	var p := r.position
	var pad := 8.0 * s
	# Thumbnail box: a dark well, the spotlight, a floor shadow, the model.
	var tb := Rect2(p + Vector2(pad, pad + 2.0 * s), Vector2(r.size.x - pad * 2.0, THUMB_H * s))
	UI.draw_chamfer(_bar, tb, 6.0 * s, Color(0.01, 0.035, 0.045, 0.6 * a), Color(UI.SUIT_WHITE, 0.06 * a))
	var spot_col := Color(1, 1, 1, a * lerpf(0.7, 1.0, lift))
	_bar.draw_texture_rect(_spot, tb, false, spot_col if afford else Color(1.0, 0.6, 0.55, a * 0.6))
	var fl := Rect2(Vector2(tb.get_center().x - tb.size.x * 0.34, tb.end.y - tb.size.y * 0.2), Vector2(tb.size.x * 0.68, tb.size.y * 0.14))
	_bar.draw_texture_rect(_floor, fl, false, Color(1, 1, 1, a))
	# The model (a variant switch: the old one slides out and fades, the new one slides in and grows).
	var sw_k := UI.smooth(1.0 - float(c["vswap"]))
	var vdir := float(c["vdir"])
	var tin := tb.grow(-4.0 * s)
	if sw_k < 0.999 and c.has("prev_id"):
		var ptex = BuildPreview.thumbs.get(str(c["prev_id"]))
		if ptex is Texture2D and not (ptex is PlaceholderTexture2D):
			var pr := Rect2(tin.position - Vector2(vdir * sw_k * tin.size.x * 0.22, 0.0), tin.size).grow(-tin.size.y * 0.1 * sw_k)
			_draw_thumb(ptex, pr, lift, Color(dim, dim, dim * 1.02, a * (1.0 - sw_k)))
	var tex = BuildPreview.thumbs.get(str(c["id"]))
	if tex is Texture2D and not (tex is PlaceholderTexture2D):
		var nr := Rect2(tin.position + Vector2(vdir * (1.0 - sw_k) * tin.size.x * 0.22, 0.0), tin.size).grow(-tin.size.y * 0.1 * (1.0 - sw_k))
		_draw_thumb(tex, nr, lift, Color(dim, dim, dim * 1.02, a * sw_k))
	if lift > 0.05 and afford:
		_glint(tb, s, a * lift)
	# Where it may stand.
	var site := str(c["site"])
	var stx := "HER YER" if site == "any" else ("DÜŞMAN" if site == "enemy" else "YURT")
	var scol := UI.SCREEN_CYAN if site == "any" else (UI.RIVAL if site == "enemy" else UI.HOME)
	var sfs := UI.fs(9.5, s)
	var sf := UI.font_caps(700, 1)
	# The chips in a row, each measured; one that would not fit inside the well is left out.
	var cx0 := tb.position.x + 5.0 * s
	var cy0 := tb.position.y + 5.0 * s
	var climit := tb.end.x - 5.0 * s
	cx0 = _tag_chip(stx, scol, cx0, cy0, climit, sf, sfs, s, a)
	# May stand underground (in a tunnel / a cavity); a modular piece (snaps to its kind).
	if bool(c.get("under", false)):
		cx0 = _tag_chip("YERALTI", UI.WARN, cx0, cy0, climit, sf, sfs, s, a)
	if bool(c.get("modular", false)):
		cx0 = _tag_chip("MODÜLER", UI.SUIT_WHITE, cx0, cy0, climit, sf, sfs, s, a)
	# Name (a variant switch slides it over and fades it up), the variant chips, cost, hull.
	var x := p.x + pad + 2.0 * s
	var y := tb.end.y + 25.0 * s
	var tx := x + vdir * (1.0 - sw_k) * 10.0 * s
	var ta := a * lerpf(0.25, 1.0, sw_k)
	UI.draw_text(_bar, _font_b, Vector2(tx, y), str(c["name"]), UI.fs(16, s), Color(UI.TEXT if lift < 0.5 else Color(1.0, 0.99, 0.97), ta), 2)
	if (c["vars"] as Array).size() > 1:
		_draw_chips(c, Rect2(Vector2(x, y + 7.0 * s), Vector2(r.size.x - (pad + 2.0 * s) * 2.0, 16.0 * s)), s, a, lift)
		y += VAR_ROW * s
	y += 26.0 * s
	var cfs := UI.fs(22, s)
	var ccol := Color(UI.SUIT_ORANGE.lightened(0.15) if afford else UI.BAD, ta)
	UI.draw_text(_bar, _font_n, Vector2(tx, y), str(c["cost_s"]), cfs, ccol, 2)
	var cw := UI.text_w(_font_n, str(c["cost_s"]), cfs)
	UI.draw_text(_bar, _font, Vector2(tx + cw + 3.0 * s, y), "m³", UI.fs(13, s), Color(UI.DIM, ta), 2)
	if str(c["hp_s"]) != "":
		UI.draw_text_r(_bar, UI.font_caps(700, 1), r.end.x - pad - 2.0 * s, y - 2.0 * s, str(c["hp_s"]), UI.fs(11.5, s),
				Color(UI.TEXT, 0.85 * a), 2)
	# Affordability: how much of the cost you have, then HAZIR / EKSİK NN m³.
	y += 9.0 * s
	var br := Rect2(Vector2(x, y), Vector2(r.size.x - (pad + 2.0 * s) * 2.0, 3.0 * s))
	var have := clampf(mat / maxf(price, 1.0), 0.0, 1.0)
	_bar.draw_rect(br, Color(UI.SUIT_WHITE, 0.1 * a))
	var bc := UI.GOOD if afford else (UI.WARN if have > 0.66 else UI.BAD)
	_bar.draw_rect(Rect2(br.position, Vector2(br.size.x * have, br.size.y)), Color(bc, 0.9 * a))
	y += 18.0 * s
	# The state: not on this planet (Balance.BUILD_SITE) beats affordability.
	var st := "HAZIR" if afford else str(c["short_s"])
	var stc := bc.lightened(0.15)
	if bool(c.get("site_bad", false)):
		st = "BURADA KURULAMAZ"
		stc = UI.BAD.lightened(0.1)
	UI.draw_text(_bar, UI.font_caps(700, 1), Vector2(x, y), st, UI.fs(11, s), Color(stc, a), 2)
	# "NE İŞE YARAR": the plain one-liner (build_tool.gd WHAT), two lines at most, wrapped by words, an
	# ellipsis when it goes on (cached per size).
	y += 15.0 * s
	UI.draw_text(_bar, UI.font_caps(700, 1), Vector2(x, y), "NE İŞE YARAR", UI.fs(9, s), Color(UI.SCREEN_CYAN, 0.8 * a), 0)
	y += 1.0 * s
	var dfs := UI.fs(11.5, s)
	var dkey := dfs * 10000 + int(br.size.x)
	if int(c.get("desc_key", -1)) != dkey:
		c["desc_key"] = dkey
		c["desc_lines"] = UI.wrap_lines(_font, str(c["desc"]), dfs, br.size.x, 2)
	var ly := y + dfs
	for ln in c["desc_lines"]:
		UI.draw_text(_bar, _font, Vector2(x, ly), str(ln), dfs, Color(UI.TEXT, 0.86 * a), 0)
		ly += dfs + 3.0 * s
	# "ÖNERİLEN" (build_tool.gd recommend_card): an orange tab on the card's top edge.
	if str(c.get("key", "")) == str(tool.get("recommend_card")) and str(tool.get("recommend_card")) != "":
		var bf := UI.font_caps(700, 2)
		var bfs := UI.fs(10, s)
		var bw := UI.text_w(bf, "ÖNERİLEN", bfs) + 16.0 * s
		var pulse := 0.85 + 0.15 * sin(_t * 4.0)
		var br2 := Rect2(Vector2(tb.end.x - bw - 4.0 * s, tb.end.y - 22.0 * s), Vector2(bw, 18.0 * s))   # (in the well)
		UI.draw_chamfer(_bar, br2, 5.0 * s, Color(UI.SUIT_ORANGE, pulse * a), Color(1.0, 0.85, 0.6, 0.9 * a))
		_bar.draw_string(bf, br2.position + Vector2(8.0 * s, 13.0 * s), "ÖNERİLEN", HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, Color(UI.INK, a))


## A small caps chip at (x, y) if it fits before `limit`; returns the x after it.
func _tag_chip(t: String, col: Color, x: float, y: float, limit: float, f: Font, fsz: int, s: float, a: float) -> float:
	var w := UI.text_w(f, t, fsz) + 10.0 * s
	if x + w > limit:
		return x
	var r := Rect2(Vector2(x, y), Vector2(w, 15.0 * s))
	UI.draw_chamfer(_bar, r, 4.0 * s, Color(col, 0.2 * a), Color(col, 0.6 * a))
	_bar.draw_string(f, r.position + Vector2(5.0 * s, 11.0 * s), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, Color(col.lightened(0.35), a))
	return x + w + 4.0 * s


## The variant chips in r: one caps chip per variant, the active one under an orange plate that
## glides to it on a switch (chip_x); too many to fit: pips and the active one's name. The selected
## card shows a small [T] at the end.
func _draw_chips(c: Dictionary, r: Rect2, s: float, a: float, lift: float) -> void:
	var vars: Array = c["vars"]
	var n := vars.size()
	var f := UI.font_caps(700, 1)
	var fsz := UI.fs(9.5, s)
	var gap := 4.0 * s
	var pad := 6.0 * s
	var key_w := 0.0
	if lift > 0.5:
		key_w = roundf(UI.fs(9, s) * 1.45) + 4.0 * s
	var avail := r.size.x - key_w
	var widths: Array = []
	var total := -gap
	for v in vars:
		var w := UI.text_w(f, str(v["label"]), fsz) + pad * 2.0
		widths.append(w)
		total += w + gap
	var cx := float(c["chip_x"])
	if total <= avail:
		# The gliding highlight between the chips' rects.
		var xs: Array = []
		var x := r.position.x
		for i in n:
			xs.append(x)
			x += float(widths[i]) + gap
		var i0 := clampi(int(floorf(cx)), 0, n - 1)
		var i1 := clampi(i0 + 1, 0, n - 1)
		var u := clampf(cx - float(i0), 0.0, 1.0)
		var hx := lerpf(float(xs[i0]), float(xs[i1]), u)
		var hw := lerpf(float(widths[i0]), float(widths[i1]), u)
		for i in n:
			UI.draw_chamfer(_bar, Rect2(Vector2(float(xs[i]), r.position.y), Vector2(float(widths[i]), r.size.y)), 4.0 * s,
					Color(UI.SUIT_WHITE, 0.05 * a), Color(UI.SUIT_WHITE, 0.16 * a))
		UI.draw_chamfer(_bar, Rect2(Vector2(hx, r.position.y), Vector2(hw, r.size.y)), 4.0 * s,
				Color(UI.SUIT_ORANGE, lerpf(0.55, 0.92, lift) * a))
		var vi := int(c["vi"])
		for i in n:
			var on := i == vi
			_bar.draw_string(f, Vector2(float(xs[i]) + pad, r.position.y + r.size.y * 0.5 + fsz * 0.36), str(vars[i]["label"]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, Color(UI.INK, a) if on else Color(UI.DIM, 0.95 * a))
	else:
		# Pips and the active variant's name.
		var px := r.position.x + 4.0 * s
		var cy := r.get_center().y
		for i in n:
			var pc := Vector2(px + i * 10.0 * s, cy)
			_bar.draw_circle(pc, 3.0 * s, Color(UI.SUIT_WHITE, 0.18 * a))
		_bar.draw_circle(Vector2(px + cx * 10.0 * s, cy), 3.2 * s, Color(UI.SUIT_ORANGE, a))
		UI.draw_text(_bar, f, Vector2(px + n * 10.0 * s + 4.0 * s, cy + fsz * 0.36), str(c["label"]), fsz, Color(UI.SUIT_ORANGE.lightened(0.25), a), 0)
	if key_w > 0.0:
		UI.draw_key(_bar, Vector2(r.end.x - key_w + 4.0 * s, r.position.y + 1.0 * s), "T", s, false, 0.85 * a, 9)


## The thumbnail, centred in r; the selected card's model turns gently (a slow turntable wobble:
## squash in x with a little skew) and breathes.
func _draw_thumb(tex: Texture2D, r: Rect2, lift: float, mod: Color) -> void:
	var ts := tex.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0:
		return
	var sc := minf(r.size.x / ts.x, r.size.y / ts.y)
	var sz := ts * sc
	var ph := _t * 1.1
	var sx := lerpf(1.0, 0.93 + 0.07 * cos(ph), lift)
	var sk := 0.05 * sin(ph) * lift
	var br := 1.0 + 0.025 * lift * sin(_t * 2.2)
	var xf := Transform2D(0.0, Vector2(sx * br, br), sk, r.get_center())
	_bar.draw_set_transform_matrix(xf)
	_bar.draw_texture_rect(tex, Rect2(-sz * 0.5, sz), false, mod)
	_bar.draw_set_transform_matrix(Transform2D.IDENTITY)


## A soft light band sweeping across the selected card's thumbnail every ~2.4 s.
func _glint(tb: Rect2, s: float, a: float) -> void:
	var ph := fmod(_t * 0.42, 1.0)
	if ph > 0.55:
		return
	var u := ph / 0.55
	var bw := 18.0 * s
	var skew := tb.size.y * 0.35
	var x := lerpf(tb.position.x - skew, tb.end.x, u)
	var x0b := clampf(x, tb.position.x, tb.end.x)
	var x1b := clampf(x + bw, tb.position.x, tb.end.x)
	var x0t := clampf(x + skew, tb.position.x, tb.end.x)
	var x1t := clampf(x + skew + bw, tb.position.x, tb.end.x)
	if x1b - x0b < 0.5 and x1t - x0t < 0.5:
		return
	var al := sin(u * PI) * 0.09 * a
	_bar.draw_colored_polygon(PackedVector2Array([Vector2(x0b, tb.end.y), Vector2(x1b, tb.end.y), Vector2(x1t, tb.position.y),
			Vector2(x0t, tb.position.y)]), Color(1.0, 0.98, 0.94, al))


## The key hints, centred at c (baseline).
func _draw_hints(c: Vector2, k: float) -> void:
	var items: Array = [["Teker", "seç"], ["R", "45°"], ["Sağ tık", "serbest döndür"], ["Sol tık", "kur"]]
	if not _cats.is_empty():
		items.insert(1, ["Q / E", "kategori"])
	if _has_variants:
		items.insert(1, ["T", "tür"])
	items.append(["Orta tık", "işaret"])          # (build_tool.gd: a "BURAYA KUR" ping; B too)
	items.append(["H", "yardım"])                 # (the first-time guide, build_guide.gd)
	var fsz := UI.fs(12, k)
	var gap := 18.0 * k
	var total := 0.0
	var kf := UI.font(700)
	for it in items:
		total += maxf(UI.text_w(kf, str(it[0]), UI.fs(11, k)) + 10.0 * k, roundf(UI.fs(11, k) * 1.45)) + 6.0 * k \
				+ UI.text_w(_font, str(it[1]), fsz) + gap
	var x := c.x - (total - gap) * 0.5
	# A glass strip behind the row (legible over bright ground).
	var pr := Rect2(Vector2(x - 12.0 * k, c.y - fsz * 1.3), Vector2(total - gap + 24.0 * k, fsz * 1.95))
	UI.draw_chamfer(_bar, pr, 6.0 * k, Color(UI.GLASS, 0.72), Color(UI.SUIT_WHITE, 0.1))
	for it in items:
		x += UI.draw_key(_bar, Vector2(x, c.y - fsz * 1.0), str(it[0]), k, false, 0.85, 11) + 6.0 * k
		UI.draw_text(_bar, _font, Vector2(x, c.y), str(it[1]), fsz, Color(UI.TEXT, 0.85), 2)
		x += UI.text_w(_font, str(it[1]), fsz) + gap


# =================================================================================================
# Drawing: the verdict under the crosshair and the rotation dial
# =================================================================================================

func _draw_verdict() -> void:
	_draw_sell_undo()
	if _v_kind == 0 and not _rot_known:
		return
	var vs := _ver.size
	var k := UI.scale_k(vs)
	var c := vs * 0.5 + Vector2(0.0, 52.0 * k)
	var pop := 1.0 + 0.12 * _refuse * _refuse
	var fsz := UI.fs(15 * pop, k)
	# The hologram's colours (scripts/war/build_holo.gd): cyan-white can build, amber fixable, red blocked.
	var col := BuildHolo.VALID_COL
	match _v_kind:
		2:
			col = BuildHolo.BLOCK_COL
		3:
			col = UI.DIM
		4:
			col = BuildHolo.FIX_COL
	var h := 30.0 * k * pop
	var tw := UI.text_w(_font_b, _v_text, fsz) if _v_kind != 0 else 0.0
	var dial := 54.0 * k if _rot_known and _v_kind != 3 else 0.0
	var w := (tw + h + 22.0 * k) if _v_kind != 0 else 0.0
	var shake := sin(_t * 70.0) * 7.0 * k * _refuse * _refuse
	var x := c.x - (w + (dial + 8.0 * k if w > 0.0 and dial > 0.0 else dial)) * 0.5 + shake
	if _v_kind != 0:
		var r := Rect2(Vector2(x, c.y - h * 0.5), Vector2(w, h))
		var red := _refuse if _v_kind == 2 or _v_kind == 4 else 0.0
		UI.draw_chamfer(_ver, r, 7.0 * k, Color(UI.GLASS, 0.72).lerp(Color(col.darkened(0.75), 0.82), red),
				Color(col, 0.55 + 0.4 * red), 1)
		# The icon: ✓ (can build), ✕ (refused), i (hint).
		var ic := Vector2(x + h * 0.5 + 2.0 * k, c.y)
		var ir := h * 0.32
		_ver.draw_circle(ic, ir, Color(col, 0.22))
		_ver.draw_arc(ic, ir, 0.0, TAU, 24, Color(col, 0.9), maxf(1.5 * k, 1.0), true)
		var lw := maxf(2.0 * k, 1.5)
		if _v_kind == 1:
			_ver.draw_polyline(PackedVector2Array([ic + Vector2(-0.45, 0.02) * ir, ic + Vector2(-0.1, 0.38) * ir,
					ic + Vector2(0.5, -0.35) * ir]), col, lw, true)
		elif _v_kind == 2 or _v_kind == 4:
			_ver.draw_line(ic + Vector2(-0.38, -0.38) * ir, ic + Vector2(0.38, 0.38) * ir, col, lw, true)
			_ver.draw_line(ic + Vector2(0.38, -0.38) * ir, ic + Vector2(-0.38, 0.38) * ir, col, lw, true)
		else:
			_ver.draw_line(ic + Vector2(0, -0.05) * ir, ic + Vector2(0, 0.5) * ir, col, lw, true)
			_ver.draw_circle(ic + Vector2(0, -0.4) * ir, lw * 0.6, col)
		UI.draw_text(_ver, _font_b, Vector2(x + h + 6.0 * k, c.y + fsz * 0.36), _v_text, fsz,
				col.lightened(0.15).lerp(Color(1.0, 0.85, 0.8), red * 0.5), 3)
		x += w + 8.0 * k
	if dial > 0.0:
		# The rotation dial: a ring, north tick, the needle at the angle, "45°".
		var dc := Vector2(x + 14.0 * k, c.y)
		var dr := 11.0 * k
		var dcol := UI.SUIT_WHITE.lerp(UI.SUIT_ORANGE, _rot_flash)
		_ver.draw_circle(dc, dr + 3.0 * k, Color(UI.GLASS, 0.7))
		_ver.draw_arc(dc, dr, 0.0, TAU, 32, Color(dcol, 0.45 + 0.4 * _rot_flash), maxf(1.2 * k, 1.0), true)
		for q in 8:
			var qa := q * PI * 0.25
			var qd := Vector2(sin(qa), -cos(qa))
			_ver.draw_line(dc + qd * (dr - 2.5 * k), dc + qd * dr, Color(UI.SUIT_WHITE, 0.35), 1.0, true)
		var ra := deg_to_rad(_rot_deg)
		var nd := Vector2(sin(ra), -cos(ra))
		_ver.draw_line(dc, dc + nd * (dr - 1.0 * k), Color(UI.SUIT_ORANGE, 0.95), maxf(2.0 * k, 1.5), true)
		_ver.draw_circle(dc, 2.0 * k, UI.SUIT_WHITE)
		UI.draw_text(_ver, _font_n, Vector2(dc.x + dr + 7.0 * k, c.y + UI.fs(13, k) * 0.36), _rot_s,
				UI.fs(13, k), dcol, 3)


## Over the crosshair: "[X basılı tut] Sök: Taret — %50 iade (+150 m³)" with the hold ring on the key
## (build_tool.gd sell_text / sell_ok / sell_k), or why it cannot be taken down. Under the verdict:
## "[Z] Geri al: Taret · 7 sn" while the last build can still be undone (undo_left / undo_name).
func _draw_sell_undo() -> void:
	var vs := _ver.size
	var k := UI.scale_k(vs)
	var st := str(tool.get("sell_text")) if tool.get("sell_text") != null else ""
	if st != "":
		var ok: bool = tool.get("sell_ok") == true
		var hold := clampf(float(tool.get("sell_k")) if tool.get("sell_k") != null else 0.0, 0.0, 1.0)
		var txt := st
		if txt.begins_with("["):
			txt = txt.substr(txt.find("]") + 1).strip_edges()
		var fsz := UI.fs(14, k)
		var kr := 12.0 * k
		var tw := UI.text_w(_font_b, txt, fsz)
		var ctrl_w := UI.text_w(UI.font(700), "Ctrl", UI.fs(11, k)) + 10.0 * k      # Ctrl + X held (X alone: back to the gun)
		var w := (ctrl_w + 8.0 * k + kr * 2.0 + 14.0 * k if ok else 0.0) + tw + 28.0 * k
		var h := 32.0 * k
		var c := Vector2(vs.x * 0.5, vs.y * 0.5 - 64.0 * k)
		var r := Rect2(Vector2(c.x - w * 0.5, c.y - h * 0.5), Vector2(w, h))
		var col := UI.SUIT_ORANGE if ok else UI.DIM
		UI.draw_chamfer(_ver, r, 7.0 * k, Color(UI.GLASS, 0.8), Color(col, 0.55 + 0.4 * hold), 1)
		var x := r.position.x + 12.0 * k
		if ok:
			x += UI.draw_key(_ver, Vector2(x, c.y - UI.fs(11, k) * 0.73), "Ctrl", k, false, 0.9, 11) + 8.0 * k
			var kc := Vector2(x + kr, c.y)
			_ver.draw_circle(kc, kr, Color(UI.SUIT_WHITE, 0.92))
			var kf := UI.fs(13, k)
			_ver.draw_string(_font_b, Vector2(kc.x - UI.text_w(_font_b, "X", kf) * 0.5, kc.y + kf * 0.36), "X", HORIZONTAL_ALIGNMENT_LEFT, -1, kf, UI.INK)
			if hold > 0.0:
				UI.draw_ring(_ver, kc, kr + 4.0 * k, hold, UI.SUIT_ORANGE, maxf(3.0 * k, 2.0))
			x += kr * 2.0 + 14.0 * k
		UI.draw_text(_ver, _font_b, Vector2(x, c.y + fsz * 0.36), txt, fsz, UI.TEXT if ok else UI.DIM, 3)
	var ul := float(tool.get("undo_left")) if tool.get("undo_left") != null else 0.0
	if ul > 0.0:
		var ut := "Geri al: %s · %d sn" % [str(tool.get("undo_name")), int(ceilf(ul))]
		var ufs := UI.fs(13, k)
		var cy := vs.y * 0.5 + 92.0 * k
		var kw0 := UI.text_w(UI.font(700), "Ctrl+Z", UI.fs(11, k)) + 10.0 * k
		var uw := kw0 + 8.0 * k + UI.text_w(_font, ut, ufs) + 24.0 * k
		var ur := Rect2(Vector2(vs.x * 0.5 - uw * 0.5, cy - 13.0 * k), Vector2(uw, 26.0 * k))
		var fade := clampf(ul / 1.0, 0.0, 1.0)
		UI.draw_chamfer(_ver, ur, 6.0 * k, Color(UI.GLASS, 0.72 * fade), Color(UI.SUIT_WHITE, 0.18 * fade))
		var kx := ur.position.x + 12.0 * k
		kx += UI.draw_key(_ver, Vector2(kx, cy - UI.fs(11, k) * 0.73), "Ctrl+Z", k, false, 0.9 * fade, 11) + 8.0 * k
		UI.draw_text(_ver, _font, Vector2(kx, cy + ufs * 0.36), ut, ufs, Color(UI.TEXT, 0.9 * fade), 2)
