extends RefCounted
## HUD density for the world-side readability code (scripts/ui/unit_markers.gd, the weapon overlays,
## the combat overlay, world Label3Ds, toasts). One lookup (level()) over the HUD setting
## (Esc › Ayarlar › HUD: Sade / Normal / Detaylı, scripts/ui/hud_mode.gd + settings.gd hud_mode).
##   HudLevel.level() -> int            SADE / NORMAL / DETAYLI
##   HudLevel.shown_level() -> int      the same, DETAYLI while the "show all" key is held (HudMode.peek)
##   HudLevel.alert(text, pri, key, secs, sound)
##                                      THE toast for these files: Game.hud.alert when the HUD has it
##                                      (priority 0 info: dropped in Sade, 1 normal, 2 critical with a
##                                      sound; key replaces the line in place), else show_message (info
##                                      dropped in Sade there too)
##   HudLevel.label_alpha(p, near_sade, look_deg) -> float
##                                      cheap world label gate (distance + one dot product, no rays):
##                                      Sade within near_sade m or looked at within look_deg°, Normal
##                                      ~2× that, Detaylı always; 0..1 with a soft edge
## Static and local (nothing goes over the network).

const HudMode := preload("res://scripts/ui/hud_mode.gd")

const SADE := 0
const NORMAL := 1
const DETAYLI := 2

## World labels: Sade shows a label within LABEL_NEAR m or when looked at (LABEL_LOOK_DEG), Normal
## within LABEL_NORMAL_K × that range or a wider look cone, Detaylı always.
const LABEL_NEAR := 16.0
const LABEL_LOOK_DEG := 6.0
const LABEL_NORMAL_K := 2.2
const LABEL_LOOK_MAX := 120.0            # m: a label farther than this needs Normal+ even when looked at


## The HUD level. The ONE place the setting is read.
static func level() -> int:
	return HudMode.mode()


## level(), but DETAYLI while the "show all" key is held (on foot, no panel open).
static func shown_level() -> int:
	return DETAYLI if HudMode.peek() else level()


## One toast. priority: 0 info (dropped in Sade), 1 normal, 2 critical (always, with the HUD's alert
## sound unless `sound` is false because the caller plays its own). key: a stable id per event type
## so repeats replace the line instead of stacking.
static func alert(text: String, priority := 1, key := "", secs := 2.0, sound := true) -> void:
	var h = Game.hud
	if h == null or not is_instance_valid(h):
		return
	if h.has_method("alert"):
		if sound:
			h.alert(text, priority, key, secs)
		else:
			h.alert(text, priority, key, secs, false)
		return
	if priority <= 0 and level() == SADE:
		return
	if h.has_method("show_message"):
		h.show_message(text, secs)


## World label visibility 0..1 for a label at world point p (see the header). near_sade: its Sade
## range (m); look_deg: the Sade look cone (°). Cheap: one distance and one dot product.
static func label_alpha(p: Vector3, near_sade := LABEL_NEAR, look_deg := LABEL_LOOK_DEG) -> float:
	var lv := shown_level()
	if lv >= DETAYLI:
		return 1.0
	var vp := (Engine.get_main_loop() as SceneTree).root if Engine.get_main_loop() is SceneTree else null
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null:
		return 1.0
	var near := near_sade * (LABEL_NORMAL_K if lv == NORMAL else 1.0)
	var cone := deg_to_rad(look_deg * (1.8 if lv == NORMAL else 1.0))
	var to := p - cam.global_position
	var d := to.length()
	var a := 1.0 - smoothstep(near * 0.8, near, d)
	if a < 1.0 and d > 0.01 and d < LABEL_LOOK_MAX * (2.0 if lv == NORMAL else 1.0):
		var c := (-cam.global_transform.basis.z).dot(to / d)
		var lim := cos(cone)
		var soft := cos(cone * 1.5)
		a = maxf(a, clampf((c - soft) / maxf(lim - soft, 1e-4), 0.0, 1.0))
	return a
