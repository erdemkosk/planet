extends Node
## The Plazma Kesici's heat gauge (scripts/items/plasma_cutter.gd) on its own overlay, next to the
## weapon_base.gd crosshair (weapon_hud.gd), drawn in the design system's look (ui_style.gd) and
## scaled with the window height:
##   heat arc   SEGS segments on an arc right of the crosshair, filling bottom -> top: cyan while
##              cool, amber past WARN_AT, red past CRIT_AT (blinking while the beam runs that hot);
##              the last stretch of the track is marked red (the overheat zone); the % at its top end
##   vent       the arc turns orange and drains with the vent; under the crosshair "AŞIRI ISINDI ·
##              SOĞUTUYOR" (forced) or "SOĞUTUYOR" (R) over a thin draining bar
## Lean by design (the minimal HUD): no panel of its own; toasts go through the cutter's _toast
## (Game.hud.alert where it exists).
##   slot       the Kesme Düzlemi sweep: a progress ring round the crosshair and its name under it
##   denied     a short red shake of the arc when a trigger is refused (venting, too hot to cut)

const UI := preload("res://scripts/ui/ui_style.gd")

const ARC_R := 46.0                    # px at 1080p
const ARC_SPAN := 1.15                 # rad, centred on the right of the crosshair
const SEGS := 12
const SEG_GAP := 0.022                 # rad between segments
const WARN_AT := 0.55
const CRIT_AT := 0.82

var weapon                             # owner (plasma_cutter.gd)
var _layer: CanvasLayer
var _top: Control
var _t := 0.0
var _shown := 0.0
var _deny := 0.0


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.add_to_group("gameplay_overlay")       # hidden on the end screen / menus (overlay_guard.gd)
	_layer.layer = 11
	add_child(_layer)
	_top = Control.new()
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_top.draw.connect(_draw_top)
	_layer.add_child(_top)


## A refused trigger (the arc shakes red for a moment).
func denied() -> void:
	_deny = 1.0


func _process(delta: float) -> void:
	_t += delta
	_deny = maxf(_deny - delta * 2.5, 0.0)
	var vis: bool = weapon != null and weapon.hud_visible()
	_top.visible = vis
	if not vis:
		return
	_shown = lerpf(_shown, float(weapon.heat_frac()), 1.0 - exp(-14.0 * delta))
	_top.queue_redraw()


## Gauge colour at heat share h (cyan -> amber -> red).
static func heat_col(h: float) -> Color:
	if h < WARN_AT:
		return UI.SCREEN_CYAN.lerp(UI.WARN, smoothstep(WARN_AT - 0.15, WARN_AT, h))
	return UI.WARN.lerp(UI.CRIT, smoothstep(CRIT_AT - 0.1, CRIT_AT + 0.05, h))


func _draw_top() -> void:
	var vs := _top.size
	var k := UI.scale_k(vs)
	var c := (vs * 0.5).round() + Vector2(sin(_t * 70.0) * 3.0 * _deny * k, 0.0)
	var r := ARC_R * k
	var w := maxf(4.0 * k, 2.5)
	var venting: bool = weapon.venting
	var slotting: bool = weapon.slotting
	var beaming: bool = weapon.beaming
	var h := clampf(_shown, 0.0, 1.0)
	var col := heat_col(h)
	if venting:
		col = UI.SUIT_ORANGE
	elif h > CRIT_AT and beaming:
		col = Color(col, 0.55 + 0.45 * sin(_t * 18.0))
	if _deny > 0.0:
		col = col.lerp(UI.CRIT, _deny)
	# The arc: bottom (a0) to top (a1) on the right of the crosshair (screen angles: + is down).
	var a0 := ARC_SPAN * 0.5
	var step := ARC_SPAN / float(SEGS)
	var lit := h * float(SEGS)
	for i in SEGS:
		var sa := a0 - float(i) * step
		var sb := sa - step + SEG_GAP
		var zone := float(i) >= CRIT_AT * float(SEGS)
		_top.draw_arc(c, r, sb, sa, 4, Color(UI.OUTLINE, 0.55), w + 2.0, true)
		_top.draw_arc(c, r, sb, sa, 4, Color(UI.CRIT if zone else UI.SUIT_WHITE, 0.22 if zone else 0.12), w, true)
		var f := clampf(lit - float(i), 0.0, 1.0)
		if f > 0.0:
			_top.draw_arc(c, r, sa - (step - SEG_GAP) * f, sa, 4, Color(col, 0.92 * col.a), w, true)
	# The % at the top end of the arc.
	var top := c + Vector2(cos(-a0), sin(-a0)) * r
	var pct := "%d%%" % int(roundf(h * 100.0))
	UI.draw_text(_top, UI.font_num(700), top + Vector2(6.0 * k, -2.0 * k), pct, UI.fs(11, k), Color(col.lightened(0.25), 0.95), 2)
	UI.draw_text(_top, UI.font_caps(700, 1), top + Vector2(6.0 * k, -15.0 * k), "ISI", UI.fs(9, k), Color(UI.DIM, 0.8), 2)
	# The vent: what happened and how long it still takes.
	if venting:
		var blink := 0.6 + 0.4 * sin(_t * 9.0)
		var title := "AŞIRI ISINDI  ·  SOĞUTUYOR" if weapon.vent_forced else "SOĞUTUYOR"
		var fs := UI.fs(13, k)
		UI.draw_text_c(_top, UI.font_caps(800, 2), c + Vector2(0, 56.0 * k), title, fs, Color(UI.SUIT_ORANGE.lightened(0.15), blink), 3)
		var u := clampf(float(weapon.vent_t) / maxf(float(weapon.vent_total), 0.01), 0.0, 1.0)
		var bar := Rect2(c + Vector2(-50.0, 64.0) * k, Vector2(100.0, 3.0) * k)
		_top.draw_rect(bar, Color(UI.SUIT_WHITE, 0.12))
		_top.draw_rect(Rect2(bar.position, Vector2(bar.size.x * (1.0 - u), bar.size.y)), Color(UI.SUIT_ORANGE, 0.9))
	elif slotting:
		var p: float = clampf(float(weapon.slot_progress()), 0.0, 1.0)
		UI.draw_ring(_top, c, 28.0 * k, p, Color(UI.SCREEN_CYAN.lerp(Color.WHITE, 0.3), 0.95), maxf(3.0 * k, 2.0))
		UI.draw_text_c(_top, UI.font_caps(800, 2), c + Vector2(0, 56.0 * k), "KESME DÜZLEMİ", UI.fs(12, k),
				Color(UI.SCREEN_CYAN.lightened(0.3), 0.92), 3)
	elif h > CRIT_AT and beaming:
		UI.draw_text_c(_top, UI.font_caps(800, 2), c + Vector2(0, 56.0 * k), "ISI KRİTİK", UI.fs(12, k),
				Color(UI.CRIT.lightened(0.1), 0.5 + 0.5 * sin(_t * 14.0)), 3)
