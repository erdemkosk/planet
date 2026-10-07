extends RefCounted
## HUD density (Esc › Ayarlar › ARAYÜZ › "HUD": Sade / Normal / Detaylı; stored as Settings.hud_mode,
## read as Game.hud_mode(), signal Game.hud_mode_changed(mode)) and the contextual reveals the HUD
## widgets share. Static; the HUD is local (nothing here goes over the network).
##   Sade (0, default)  the crosshair, health and the held item's ammo / tool readout; everything else
##                      shows only while it matters (reveal()) or while the "show all" key is held,
##                      then fades
##   Normal (1)         the usual layout, de-cluttered (no key hints, at most two warning plates)
##   Detaylı (2)        everything
##
##   HudMode.mode() -> int               SADE / NORMAL / DETAYLI
##   HudMode.peek() -> bool              Left Alt held on foot (action "hud_show", game.gd), no panel open
##   HudMode.reveal(id, secs)            widget `id` shows for `secs` s (extends, never shortens)
##   HudMode.revealed(id) -> bool        that reveal is still running
##   HudMode.shown(id, from_mode) -> bool  mode() >= from_mode, or peek(), or revealed(id)
##   HudMode.fade(ci, on, t_in, t_out)   tweens ci.modulate:a to 1 / 0 when `on` changes (no popping)
## Widget ids in use: "material" (hud.gd), "quickbar" (quickbar.gd), "cores" (war_hud.gd top plates),
## "zones" (control_hud.gd chips), "objective" (hud.gd objective line).

const Settings := preload("res://scripts/save/settings.gd")

const SADE := 0
const NORMAL := 1
const DETAYLI := 2
const NAMES := ["Sade", "Normal", "Detaylı"]
const HOLD_ACTION := "hud_show"
const HOLD_KEY := "Alt"

static var _until := {}                  # widget id -> Time.get_ticks_msec() it stays shown until


static func mode() -> int:
	return clampi(Settings.hud_mode, SADE, DETAYLI)


## The "show all" key is held: on foot (in a vehicle Alt is the armed skiff's free look), no menu open.
static func peek() -> bool:
	if not InputMap.has_action(HOLD_ACTION) or not Input.is_action_pressed(HOLD_ACTION):
		return false
	var p = Game.player
	if p != null and is_instance_valid(p) and p.get("vehicle") != null:
		return false
	return not Game.ui_panel_open()


## Widget `id` is relevant for the next `secs` s.
static func reveal(id: String, secs := 2.5) -> void:
	var until := Time.get_ticks_msec() + int(maxf(secs, 0.0) * 1000.0)
	if until > int(_until.get(id, 0)):
		_until[id] = until


static func revealed(id: String) -> bool:
	return Time.get_ticks_msec() < int(_until.get(id, 0))


## Ends a reveal at once (the widget fades out).
static func conceal(id: String) -> void:
	_until.erase(id)


## Whether widget `id` should be up: always from `from_mode` on (NORMAL: hidden only in Sade; DETAYLI:
## only in Detaylı), else while revealed or while the key is held.
static func shown(id: String, from_mode := NORMAL) -> bool:
	return mode() >= from_mode or peek() or revealed(id)


## Fades `ci` in / out with a tween on modulate:a, only when `on` changes (call it every frame).
static func fade(ci: CanvasItem, on: bool, t_in := 0.18, t_out := 0.6) -> void:
	if ci == null or not is_instance_valid(ci):
		return
	if ci.has_meta("_hm_on") and bool(ci.get_meta("_hm_on")) == on:
		return
	ci.set_meta("_hm_on", on)
	if ci.has_meta("_hm_tw"):
		var old = ci.get_meta("_hm_tw")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	if not ci.is_inside_tree():
		ci.modulate.a = 1.0 if on else 0.0
		return
	var tw := ci.create_tween()
	tw.tween_property(ci, "modulate:a", 1.0 if on else 0.0, t_in if on else t_out) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	ci.set_meta("_hm_tw", tw)
