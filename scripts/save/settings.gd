extends RefCounted
## Player settings (Esc › Ayarlar), stored in user://settings.cfg and applied at start-up
## (Game._ready → Settings.load_and_apply()). Everything is static: readers use the values directly
##   Settings.look(rel)  → mouse delta scaled by the sensitivity, Y flipped when inverted
##   Settings.fov        → first-person field of view (weapons ease back to it after aiming)
## The window mode is only touched when the player changed it here (the project default stays).

const PATH := "user://settings.cfg"

static var mouse_sens := 1.0        # multiplier on every mouse-look handler (0.3 .. 2.5)
static var invert_y := false
static var fov := 75.0              # degrees, on foot (60 .. 100)
static var master_volume := 1.0     # 0 .. 1
static var fullscreen := true
static var vsync := true
static var throttle_hold := false   # shuttle throttle: false = "sabit" (the lever stays where you leave it), true = "basılı tut"
static var damage_numbers := false  # floating damage numbers on hits (hit_feel.gd), off by default
static var motion_blur := 1         # camera motion blur (scripts/ui/motion_blur.gd): 0 off, 1 low (default), 2 medium
static var helmet_fx := 2           # inside-the-helmet effects (scripts/ui/helmet_fx.gd): 0 off, 1 low, 2 medium (default)
static var space_battle := 2        # cosmetic far-off space battle (scripts/fx/space_battle.gd): 0 off, 1 low, 2 high (default)
## HUD density (scripts/ui/hud_mode.gd): 0 Sade (default: crosshair, health, ammo; the rest only when
## it matters), 1 Normal, 2 Detaylı. Change it with set_hud_mode() (emits Game.hud_mode_changed).
static var hud_mode := 0
static var _has_window := false     # the window mode was chosen here at least once
static var _loaded := false


## Mouse motion in "pixels" after sensitivity and inversion; multiply by the handler's own scale.
static func look(rel: Vector2) -> Vector2:
	return Vector2(rel.x, -rel.y if invert_y else rel.y) * mouse_sens


static func load_and_apply() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		mouse_sens = clampf(float(cf.get_value("input", "mouse_sens", 1.0)), 0.3, 2.5)
		invert_y = bool(cf.get_value("input", "invert_y", false))
		fov = clampf(float(cf.get_value("view", "fov", 75.0)), 60.0, 100.0)
		motion_blur = clampi(int(cf.get_value("view", "motion_blur", 1)), 0, 2)
		helmet_fx = clampi(int(cf.get_value("view", "helmet_fx", 2)), 0, 2)
		space_battle = clampi(int(cf.get_value("view", "space_battle", 2)), 0, 2)
		master_volume = clampf(float(cf.get_value("audio", "master", 1.0)), 0.0, 1.0)
		vsync = bool(cf.get_value("display", "vsync", true))
		throttle_hold = bool(cf.get_value("input", "throttle_hold", false))
		damage_numbers = bool(cf.get_value("ui", "damage_numbers", false))
		hud_mode = clampi(int(cf.get_value("ui", "hud_mode", 0)), 0, 2)
		_has_window = cf.has_section_key("display", "fullscreen")
		fullscreen = bool(cf.get_value("display", "fullscreen", true))
	_loaded = true
	apply(false)


static func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("input", "mouse_sens", mouse_sens)
	cf.set_value("input", "invert_y", invert_y)
	cf.set_value("input", "throttle_hold", throttle_hold)
	cf.set_value("ui", "damage_numbers", damage_numbers)
	cf.set_value("ui", "hud_mode", hud_mode)
	cf.set_value("view", "fov", fov)
	cf.set_value("view", "motion_blur", motion_blur)
	cf.set_value("view", "helmet_fx", helmet_fx)
	cf.set_value("view", "space_battle", space_battle)
	cf.set_value("audio", "master", master_volume)
	cf.set_value("display", "vsync", vsync)
	if _has_window:
		cf.set_value("display", "fullscreen", fullscreen)
	cf.save(PATH)


## Pushes the values into the engine. window = true also applies the window mode (changed here).
static func apply(window := true) -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master_volume, 0.0001)))
	AudioServer.set_bus_mute(0, master_volume <= 0.001)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	if window or _has_window:
		var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
		if DisplayServer.window_get_mode() != want and not _debug_run():
			DisplayServer.window_set_mode(want)
	var pl = Game.player
	if pl != null and pl.get("camera") != null and not _weapon_aiming(pl):
		(pl.camera as Camera3D).fov = fov


## The HUD density (0 Sade, 1 Normal, 2 Detaylı); the widgets re-layout at once (Game.hud_mode_changed).
static func set_hud_mode(m: int) -> void:
	m = clampi(m, 0, 2)
	if m == hud_mode:
		return
	hud_mode = m
	if Game.has_signal("hud_mode_changed"):
		Game.emit_signal("hud_mode_changed", m)


static func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_has_window = true
	apply(true)


## Debug / test runners force a 1280x720 window (main.gd); leave it alone.
static func _debug_run() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots") or a.begins_with("--run=") or a.begins_with("--ui-shots"):
			return true
	return false


static func _weapon_aiming(pl) -> bool:
	var it = pl.items[pl.current_item] if pl.get("items") != null and pl.current_item < (pl.items as Array).size() else null
	return it != null and float(it.get("ads") if it.get("ads") != null else 0.0) > 0.05
