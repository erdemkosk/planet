extends CanvasLayer
## On-screen UI (Turkish), in the design system's look (scripts/ui/ui_style.gd: wrist-screen glass
## plates, suit-white frames, orange accents). Laid out for 1080p, scaled with the window height:
##   - crosshair (scripts/ui/crosshair.gd): tinted by the drill mode, ring over interactables, the
##     jetpack fuel arc while it burns or refills; guns hide it and draw their own
##   - top right: MALZEME (material, m³; a gain floats "+NN", a big spend ticks the counter down with a
##     red "−NN m³"); craft pills and the kill feed stack under it (right_column_y())
##   - bottom left: CAN, the suit-integrity plate: the number, a 20-segment bar (green → amber → red)
##     with a damage trail (the lost part stays light, then drains) and a green glow on healed
##     segments, "DÜŞÜK" / "KRİTİK" and a red pulse at low health (the edge vignette is damage_ui.gd),
##     the jetpack fuel line while it is not full
##   - bottom right: the held item: a gun's name, fire mode / ammo chips, magazine (big) / reserve,
##     the magazine bar (or the reload, the railgun's charge), "DOLDURULUYOR", the price of a round
##     once the reserve is gone; the Kinetik İtici's charges; the drill's mode and brush (hidden while
##     the build tool's card bar is up)
##   - the quickbar (scripts/ui/quickbar.gd, `quickbar`) at the bottom centre
##   - the interact prompt above it: a key cap ([F], [F basılı tut] shows "BASILI TUT") and the text;
##     the hold-F ring of a gun on the ground (scripts/war/weapon_drop.gd) fills around the key
##   - ONE alert channel in the upper third (alert(), show_message): at most ALERT_MAX glass lines;
##     priority 0 info (cyan; dropped in Sade), 1 normal (orange), 2 critical (red, an alert icon, a
##     sound, a little longer); a `key` replaces / refreshes its line in place instead of stacking;
##     more lines wait in a short queue (higher priority pre-empts, stale info is dropped)
##   - the objective line (top left, "HEDEF"): what to do next against the rival core
##   - the red damage flash, direction arcs and low-health vignette (scripts/ui/damage_ui.gd)
##   - a black fade for respawns
## HUD density (scripts/ui/hud_mode.gd, Esc › Ayarlar › HUD): Sade (default) keeps the crosshair, CAN
## and the held item; MALZEME shows on a change (digging, a spend, a pickup) for MAT_SHOW s, always
## while the build tool's cards / the Silahlık / the İkmal menu are up and when a purchase fails; the
## objective line on events (match start, the first cannon, our core hit, their shield up); Left Alt
## held shows it all. Normal: the usual layout without key hints, the objective as a compact line.
## Detaylı: everything, the objective plate always.
## The plates and the prompt are in group "gameplay_overlay" (scripts/ui/overlay_guard.gd hides them
## on the end screen, the pause menu and modal panels); the alerts and the fade are not.
## API used by the game: set_prompt(text), alert(text, priority, key, secs), show_message(text,
## seconds) (= alert priority 1), on_player_damaged(amount, from_pos), fade_to_black(t) /
## fade_from_black(t) -> Tween, blocks_input(), `crosshair`, right_column_y(), `stats` (this match:
## "mined" / "spent" m³, "deaths"; the end screen reads it), objective_event(why).

const UI := preload("res://scripts/ui/ui_style.gd")
const Crosshair := preload("res://scripts/ui/crosshair.gd")
const DamageUi := preload("res://scripts/ui/damage_ui.gd")
const Quickbar := preload("res://scripts/ui/quickbar.gd")
const WeaponDrop := preload("res://scripts/war/weapon_drop.gd")
const HudMode := preload("res://scripts/ui/hud_mode.gd")
const Balance := preload("res://scripts/war/balance.gd")

const ALERT_MAX := 2                     # alert lines on screen at once
const ALERT_QUEUE := 4                   # lines kept waiting
const ALERT_IN := 0.15                   # s: a line drops in
const ALERT_OUT := 0.22                  # s: ...and fades out
const INFO_STALE := 1.5                  # s: a waiting info line older than this is dropped
const NORMAL_STALE := 5.0                # ...a waiting normal one (critical lines wait)
const MAT_SHOW := 2.5                    # s: Sade shows MALZEME this long after a change
const OBJ_SHOW := 6.0                    # s: Sade shows the objective this long after an event
const PANEL_W := 236.0                   # the material plate
const VITAL_W := 320.0
const WEAPON_W := 300.0
const MARGIN := 24.0
const SEGMENTS := 20

var crosshair: Control
var damage: Control
var quickbar: Control
var stats := {"mined": 0.0, "spent": 0.0, "deaths": 0}
var _root: Control
var _panel: Control
var _prompt: Control
var _toast: Control                      # the alert lines' canvas
var _mat: Control                        # MALZEME's own canvas (it fades on its own in Sade)
var _obj: Control                        # the objective line
var _fade: ColorRect
## Restarts (to the new line's life) whenever a NEW alert line appears; scripts/ui/helmet_fx.gd
## watches it for the comms click.
var _toast_t := 0.0
# Alerts: on screen {text, pri, key, t (s left), life, age, out (fade-out 0..1, 0 = live), y (eased
# slot), seq, bump}; waiting {text, pri, key, secs, wait, seq}.
var _alerts: Array = []
var _alert_q: Array = []
var _alert_seq := 0
var _alert_snd_ms := -100000
# The objective line.
var _obj_text := ""
var _obj_short := ""
var _obj_crit := false
var _obj_a := 0.0
var _obj_check := 0.0
var _obj_start := false                  # the match-start event fired
var _obj_cannons := -1                   # our cannons last look (-1 = not looked yet)
var _obj_shield := false                 # the rival core's shield last look
var _obj_hit_ms := -100000               # our core's last hit
var _obj_hit_ev_ms := -100000            # ...and the last "under fire" event (at most every 15 s)
var _obj_low := false                    # the "finish it" event fired (rival core <= 25 %)
var _obj_shield_s = null                 # scripts/war/core_shield.gd (loaded when it exists)
var _mat_a := 1.0                        # (read back by tests: MALZEME wanted)
var _font: Font
var _font_b: Font
var _font_n: Font
var _t := 0.0
var _sig := 0
# Material.
var _mat_pulse := 0.0
var _last_mat := -1.0
var _spend_t := -1.0                     # a big spend: the counter ticks down, "−NN m³" floats off
var _spend_from := 0.0
var _spend_amt := 0.0
var _gain_amt := 0.0                     # gains of the last moment ("+NN")
var _gain_t := 0.0
# Health.
var _hp_frac := 1.0
var _trail := 1.0                        # damage trail (share), drains after TRAIL_HOLD
var _trail_hold := 0.0
var _heal_from := 1.0                    # healed segments glow from here up to the health
var _heal_t := 0.0
var _hit := 0.0                          # plate flash on a hit
var _was_dead := false
var _fuel_vis := 0.0
# Prompt.
var _p_raw := ""
var _p_key := ""
var _p_hold := ""
var _p_text := ""
var _p_a := 0.0
var _p_shown := ""                       # the last non-empty prompt (kept while it fades out)


func _ready() -> void:
	layer = 5
	_font = UI.font(500)
	_font_b = UI.font(700)
	_font_n = UI.font_num(700)
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UI.make_theme()
	add_child(_root)

	damage = DamageUi.new()
	damage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(damage)

	crosshair = Crosshair.new()
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(crosshair)

	_panel = _canvas(_draw_panel)
	_panel.add_to_group("gameplay_overlay")      # hidden on the end screen / menus (overlay_guard.gd)
	_mat = _canvas(_draw_mat)
	_mat.add_to_group("gameplay_overlay")
	_prompt = _canvas(_draw_prompt)
	_prompt.add_to_group("gameplay_overlay")
	_obj = _canvas(_draw_objective)
	_obj.add_to_group("gameplay_overlay")
	_obj.modulate.a = 0.0
	_toast = _canvas(_draw_toast)
	_toast.visible = false
	if Game.has_signal("hud_mode_changed"):
		Game.hud_mode_changed.connect(_on_hud_mode)
	Game.core_damaged.connect(_on_core_damaged)

	quickbar = Quickbar.new()
	quickbar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(quickbar)

	_fade = ColorRect.new()
	_fade.color = Color(0.0, 0.01, 0.015, 0)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_fade)


func _canvas(fn: Callable) -> Control:
	var c := Control.new()
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(fn)
	_root.add_child(c)
	return c


# --- API ------------------------------------------------------------------------------------------

## "[F] " + text; a text that brings its own key ("[F basılı tut] Tüfek al", a gun on the ground) as is.
func set_prompt(text: String) -> void:
	var t := "" if text == "" else (text if text.begins_with("[") else "[F] " + text)
	if t == _p_raw:
		return
	_p_raw = t
	if t == "":
		return                                 # (the last one fades out)
	_p_shown = t
	_p_key = ""
	_p_hold = ""
	_p_text = t
	if t.begins_with("["):
		var e := t.find("]")
		if e > 0:
			var inner := t.substr(1, e - 1).strip_edges()
			_p_text = t.substr(e + 1).strip_edges()
			var sp := inner.find(" ")
			_p_key = inner if sp < 0 else inner.substr(0, sp)
			_p_hold = "" if sp < 0 else UI.upper_tr(inner.substr(sp + 1).strip_edges())
	_prompt.queue_redraw()


## The old toast: an alert of priority 1 (deduplicated by its text).
func show_message(text: String, seconds := 2.5) -> void:
	alert(text, 1, "", seconds)


## THE alert channel (every toast goes through here). priority: 0 info (dropped in Sade), 1 normal,
## 2 critical (always shown, a sound unless `sound` is false because the caller plays its own, a
## little longer). key: a line with the same key (default: the same text) is replaced / refreshed in
## place, never stacked; an empty text with a key takes that line down. At most ALERT_MAX lines on
## screen; more wait in a short queue (a higher priority pre-empts the weakest line, waiting info
## goes stale). A line that mentions material ("malzeme" / "m³") also brings up MALZEME in Sade.
func alert(text: String, priority: int = 1, key: String = "", secs: float = 2.0, sound := true) -> void:
	var pri := clampi(priority, 0, 2)
	var k := key if key != "" else text
	if text == "":
		_alert_drop(k)
		return
	if pri == 0 and HudMode.mode() == HudMode.SADE:
		return
	var life := maxf(secs, 0.5)
	if pri == 2:
		life = maxf(life * 1.3, 2.8)
	if pri >= 1 and _mentions_material(text):
		HudMode.reveal("material", maxf(life, MAT_SHOW))
	_toast.visible = true
	# The same key: in place (a line fading out comes back; a live one is preferred).
	var same: Dictionary = {}
	for a in _alerts:
		if a["key"] == k and (same.is_empty() or float(a["out"]) <= 0.0):
			same = a
	if not same.is_empty() and (float(same["out"]) <= 0.0 or _live_alerts().size() < ALERT_MAX):
		var news: bool = same["text"] != text or float(same["out"]) > 0.0 or int(same["pri"]) < pri
		if news:
			same["bump"] = 1.0
			if pri == 2 and sound:
				_alert_sound()
		_alert_q = _alert_q.filter(func(q) -> bool: return q["key"] != k)
		same["text"] = text
		same["pri"] = pri
		same["t"] = life
		same["life"] = life
		same["out"] = 0.0
		_toast.queue_redraw()
		return
	if pri == 2 and sound:
		_alert_sound()
	for q in _alert_q:
		if q["key"] == k:
			q["text"] = text
			q["pri"] = pri
			q["secs"] = life
			return
	_alert_seq += 1
	var live := _live_alerts()
	if live.size() < ALERT_MAX:
		_alert_show(text, pri, k, life, _alert_seq)
		return
	# Full: pre-empt the weakest line (lowest priority, then the oldest) when this one outranks it.
	var weak: Dictionary = live[0]
	for a in live:
		if int(a["pri"]) < int(weak["pri"]) or (int(a["pri"]) == int(weak["pri"]) and int(a["seq"]) < int(weak["seq"])):
			weak = a
	if pri > int(weak["pri"]):
		weak["out"] = 0.0001
		if int(weak["pri"]) >= 1 and float(weak["t"]) > 0.8:
			_alert_queue(str(weak["text"]), int(weak["pri"]), str(weak["key"]), float(weak["t"]), int(weak["seq"]))
		_alert_show(text, pri, k, life, _alert_seq)
	else:
		_alert_queue(text, pri, k, life, _alert_seq)


## The alert lines on screen and waiting, oldest first: [[text, priority, key], ...] (tests, debugging).
func alert_lines(include_queue := false) -> Array:
	var out: Array = []
	for a in _live_alerts():
		out.append([a["text"], a["pri"], a["key"]])
	if include_queue:
		for q in _alert_q:
			out.append([q["text"], q["pri"], q["key"]])
	return out


func _live_alerts() -> Array:
	return _alerts.filter(func(a) -> bool: return float(a["out"]) <= 0.0)


func _alert_show(text: String, pri: int, k: String, life: float, seq: int) -> void:
	var slot := float(_live_alerts().size())
	_alerts.append({"text": text, "pri": pri, "key": k, "t": life, "life": life, "age": 0.0, "out": 0.0, "y": slot,
			"seq": seq, "bump": 0.0})
	_toast_t = life                               # (a new line: helmet_fx.gd's comms click)
	_toast.visible = true
	_toast.queue_redraw()


func _alert_queue(text: String, pri: int, k: String, secs: float, seq: int) -> void:
	_alert_q.append({"text": text, "pri": pri, "key": k, "secs": secs, "wait": 0.0, "seq": seq})
	while _alert_q.size() > ALERT_QUEUE:
		var drop := 0
		for i in _alert_q.size():
			var q: Dictionary = _alert_q[i]
			var d: Dictionary = _alert_q[drop]
			if int(q["pri"]) < int(d["pri"]) or (int(q["pri"]) == int(d["pri"]) and int(q["seq"]) < int(d["seq"])):
				drop = i
		_alert_q.remove_at(drop)


func _alert_drop(k: String) -> void:
	for a in _alerts:
		if a["key"] == k and float(a["out"]) <= 0.0:
			a["out"] = 0.0001
	_alert_q = _alert_q.filter(func(q) -> bool: return q["key"] != k)


## Per frame: lines age and fade out, waiting lines go stale or move up into a free slot, the slots ease.
func _alert_tick(delta: float) -> void:
	for a in _alerts:
		a["age"] = float(a["age"]) + delta
		a["bump"] = maxf(float(a["bump"]) - delta * 3.0, 0.0)
		if float(a["out"]) > 0.0:
			a["out"] = float(a["out"]) + delta / ALERT_OUT
		else:
			a["t"] = float(a["t"]) - delta
			if float(a["t"]) <= 0.0:
				a["out"] = 0.0001
	_alerts = _alerts.filter(func(a) -> bool: return float(a["out"]) < 1.0)
	for q in _alert_q:
		q["wait"] = float(q["wait"]) + delta
	_alert_q = _alert_q.filter(_alert_fresh)
	while _live_alerts().size() < ALERT_MAX and not _alert_q.is_empty():
		var best := 0
		for i in _alert_q.size():
			var q: Dictionary = _alert_q[i]
			var b: Dictionary = _alert_q[best]
			if int(q["pri"]) > int(b["pri"]) or (int(q["pri"]) == int(b["pri"]) and int(q["seq"]) < int(b["seq"])):
				best = i
		var n: Dictionary = _alert_q[best]
		_alert_q.remove_at(best)
		_alert_show(str(n["text"]), int(n["pri"]), str(n["key"]), float(n["secs"]), int(n["seq"]))
	# Slots: critical first, then by age; each line eases to its slot (no popping).
	var live := _live_alerts()
	live.sort_custom(_alert_order)
	for i in live.size():
		var a: Dictionary = live[i]
		a["y"] = lerpf(float(a["y"]), float(i), 1.0 - exp(-14.0 * delta))
	_toast_t = maxf(_toast_t - delta, 0.0)
	if _alerts.is_empty() and _alert_q.is_empty():
		if _toast.visible:
			_toast.visible = false
	else:
		_toast.queue_redraw()


## A waiting line still worth showing (info goes stale after INFO_STALE s, normal after NORMAL_STALE).
func _alert_fresh(q: Dictionary) -> bool:
	var w := float(q["wait"])
	match int(q["pri"]):
		0:
			return w <= INFO_STALE
		1:
			return w <= NORMAL_STALE
	return true


## Slot order: critical first, then the older line above.
func _alert_order(x: Dictionary, y: Dictionary) -> bool:
	if int(x["pri"]) != int(y["pri"]):
		return int(x["pri"]) > int(y["pri"])
	return int(x["seq"]) < int(y["seq"])


func _alert_sound() -> void:
	var now := Time.get_ticks_msec()
	if now - _alert_snd_ms < 600:
		return
	_alert_snd_ms = now
	if Game.sfx:
		Game.sfx.play("blip", -9.0, 0.85)


static func _mentions_material(text: String) -> bool:
	var s := text.to_lower()
	return s.contains("malzeme") or s.contains("m³")


## The HUD density changed (Ayarlar): Sade drops the info lines; the widgets follow on their own.
func _on_hud_mode(m: int) -> void:
	if m == HudMode.SADE:
		for a in _alerts:
			if int(a["pri"]) == 0 and float(a["out"]) <= 0.0:
				a["out"] = 0.0001
		_alert_q = _alert_q.filter(func(q) -> bool: return int(q["pri"]) > 0)
	_panel.queue_redraw()
	_mat.queue_redraw()
	_obj.queue_redraw()


func on_player_damaged(amount: float, from_pos: Vector3) -> void:
	damage.hit(amount, from_pos)
	_hit = 1.0


## The pause menu (and later other panels) owns the mouse.
func blocks_input() -> bool:
	return Game.ui_panel_open()


func fade_to_black(t := 0.6) -> Tween:
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, t)
	return tw


func fade_from_black(t := 0.8) -> Tween:
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 0.0, t)
	return tw


## Top-right column: the y (px) under the material plate where the craft pills (craft_menu.gd,
## include_pills false) and then the kill feed (combat_hud.gd: under the pills too) stack.
func right_column_y(include_pills := true) -> float:
	var k := UI.scale_k(_root.size if _root != null else Vector2(1920, 1080))
	var y := _top_y(k) + (74.0 + 10.0) * k
	if include_pills and is_inside_tree():
		for a in get_tree().get_nodes_in_group("war_armory"):
			if bool(a.get("crafting")) and a.get("job") is Dictionary and bool((a.get("job") as Dictionary).get("local", false)):
				y += 34.0 * k
	return y


func _top_y(k: float) -> float:
	return (MARGIN + (26.0 if Net.active else 0.0)) * k        # (multiplayer: the room line is above)


func _supply_menu_open() -> bool:
	if not Game.has_meta("supply_menu"):
		return false
	var m = Game.get_meta("supply_menu")
	return m != null and is_instance_valid(m) and bool(m.get("_open"))


## The Silahlık menu (scripts/war/craft_menu.gd, a Game.ui_panels panel) is open.
func _armory_open() -> bool:
	for pn in Game.ui_panels:
		if pn != null and is_instance_valid(pn) and pn.has_method("is_open") and pn.is_open():
			var s = pn.get_script()
			if s is Script and (s as Script).resource_path.ends_with("craft_menu.gd"):
				return true
	return false


# --- The objective line ---------------------------------------------------------------------------
# Top left: "HEDEF" and what to do next ("Rakip çekirdeği 300/300 — top, Delici ya da Sondaj ile vur";
# our core under fire: "SAVUN", red). Sade: for OBJ_SHOW s on an event (the match start, our first
# cannon, our core hit, their shield up, their core low) and while Alt is held; Normal: a compact line
# (the plate on events); Detaylı: the plate always. Not in the Eğitim Alanı (its own panel is there).

## Something about the goal happened: Sade shows the line for a while. why: "start", "cannon",
## "core_hit", "shield", "low", or anything else (just say it again).
func objective_event(why := "") -> void:
	_obj_update()
	if _obj_text != "":
		HudMode.reveal("objective", OBJ_SHOW + (2.0 if why == "start" else 0.0))
	if why == "start":
		HudMode.reveal("cores", OBJ_SHOW + 2.0)          # (a first look at the cores and the zones too)
		HudMode.reveal("zones", OBJ_SHOW + 2.0)


func _war() -> Node:
	return get_tree().get_first_node_in_group("war_controller") if is_inside_tree() else null


func _on_core_damaged(body: Node3D, _hp: float) -> void:
	if body == null or body != Game.planet:
		return
	var now := Time.get_ticks_msec()
	_obj_hit_ms = now
	if now - _obj_hit_ev_ms > 15000:
		_obj_hit_ev_ms = now
		objective_event("core_hit")


func _obj_tick(delta: float) -> void:
	_obj_check -= delta
	if _obj_check <= 0.0:
		_obj_check = 0.5
		_obj_scan()
	var m := HudMode.mode()
	var full := m == HudMode.DETAYLI or HudMode.peek() or HudMode.revealed("objective")
	var want := _obj_text != "" and (full or m == HudMode.NORMAL)
	_obj_a = move_toward(_obj_a, 1.0 if full else 0.0, delta * 4.0)     # compact line <-> plate
	HudMode.fade(_obj, want, 0.25, 0.8)
	if want or _obj.modulate.a > 0.0:
		_obj.queue_redraw()


## Every 0.5 s: the events (first look at the match while playing, our first cannon, their shield,
## their core low) and the line's text.
func _obj_scan() -> void:
	var w := _war()
	if w == null or Game.has_meta("training") or Game.match_over:
		_obj_text = ""
		return
	var p = Game.player
	var playing: bool = p != null and is_instance_valid(p) and not (p.has_method("is_dead") and p.is_dead()) \
			and p.get("vehicle") == null and not Game.ui_panel_open()
	var events: Array = []
	if not _obj_start and playing:
		_obj_start = true
		events.append("start")
	var n := 0
	for g in ["war_cannon", "war_buster"]:
		for c in get_tree().get_nodes_in_group(g):
			if Game.team_of(c) == "home" and c.get("destroyed") != true:
				n += 1
	if _obj_cannons == 0 and n > 0:
		events.append("cannon")
	_obj_cannons = n
	if _obj_shield_s == null:
		_obj_shield_s = load("res://scripts/war/core_shield.gd") if ResourceLoader.exists("res://scripts/war/core_shield.gd") else false
	var sh: bool = _obj_shield_s is Script and bool(_obj_shield_s.call("active_for", "rival"))
	if sh and not _obj_shield:
		events.append("shield")
	_obj_shield = sh
	var rc = w.get("rival_core")
	if not _obj_low and rc != null and is_instance_valid(rc) and float(rc.hp) > 0.0 and float(rc.hp) <= float(rc.hp_max) * 0.25:
		_obj_low = true
		events.append("low")
	_obj_update()
	for e in events:
		objective_event(str(e))


func _obj_update() -> void:
	_obj_text = ""
	_obj_short = ""
	_obj_crit = false
	var w := _war()
	if w == null or Game.has_meta("training"):
		return
	var hc = w.get("home_core")
	if hc != null and is_instance_valid(hc) and float(hc.hp) > 0.0 and Time.get_ticks_msec() - _obj_hit_ms < 8000:
		var hs := "%d/%d" % [int(ceilf(float(hc.hp))), int(float(hc.hp_max))]
		_obj_text = "Çekirdeğimiz saldırı altında %s — savun, saldıranı bul" % hs
		_obj_short = "Çekirdeğimiz %s — savun" % hs
		_obj_crit = true
		return
	var rc = w.get("rival_core")
	if rc == null or not is_instance_valid(rc):
		return
	var rs := "%d/%d" % [int(ceilf(maxf(float(rc.hp), 0.0))), int(float(rc.hp_max))]
	_obj_short = "Rakip çekirdeği %s" % rs
	if _obj_shield:
		_obj_text = "Rakip çekirdeği %s kalkanlı (hasar %%%d) — önce Çekirdek Kalkanı'nı yık" % [rs,
				int(roundf(Balance.CORE_SHIELD_MULT * 100.0))]
		_obj_short += "  ·  kalkanlı"
	elif _obj_cannons == 0:
		_obj_text = "Rakip çekirdeği %s — X ile top kur, sonra vur" % rs
	elif float(rc.hp) <= float(rc.hp_max) * 0.25:
		_obj_text = "Rakip çekirdeği %s — bitir! Top, Delici ya da Sondaj ile vur" % rs
	else:
		_obj_text = "Rakip çekirdeği %s — top, Delici ya da Sondaj ile vur" % rs


# --- Per frame ------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_t += delta
	var redraw := false
	# The alert lines, the objective line.
	_alert_tick(delta)
	_obj_tick(delta)
	# Prompt fade.
	var pa := move_toward(_p_a, 1.0 if _p_raw != "" else 0.0, delta * (9.0 if _p_raw != "" else 6.0))
	if pa != _p_a or WeaponDrop.hold_progress() >= 0.0:
		_p_a = pa
		_prompt.queue_redraw()
	# Material: gains float "+NN", a big spend ticks the counter down.
	var m := Game.material
	if _last_mat < 0.0:
		_last_mat = m
	var dm := m - _last_mat
	if dm > 0.001:
		_mat_pulse = 1.0
		stats["mined"] = float(stats["mined"]) + dm
		_gain_amt = (_gain_amt if _gain_t > 0.0 else 0.0) + dm
		_gain_t = 1.3
	elif dm < -0.001:
		stats["spent"] = float(stats["spent"]) - dm
	if dm < -4.999:
		_spend_from = _mat_display() if _spend_t >= 0.0 else _last_mat
		_spend_amt = (_spend_amt if _spend_t >= 0.0 and _spend_t < 0.6 else 0.0) - dm
		_spend_t = 0.0
	if _spend_t >= 0.0:
		_spend_t += delta
		if _spend_t > 1.4:
			_spend_t = -1.0
		redraw = true
	_last_mat = m
	if _mat_pulse > 0.0 or _gain_t > 0.0:
		redraw = true
	_mat_pulse = maxf(_mat_pulse - delta * 3.0, 0.0)
	_gain_t = maxf(_gain_t - delta, 0.0)
	# MALZEME in Sade: a spend or a real gain (a pickup, a refund; not the zones' / core pump's trickle)
	# brings it up for MAT_SHOW s.
	if dm < -0.5 or dm >= 1.5:
		HudMode.reveal("material", MAT_SHOW)
	var p = Game.player
	if p == null or not is_instance_valid(p):
		HudMode.fade(_mat, HudMode.shown("material"))
		return
	var it = p.items[p.current_item] if p.items.size() > p.current_item else null
	var on_foot: bool = p.vehicle == null and not p.is_ragdolled()
	# ...digging, the build tool's cards, the İkmal menu or the Silahlık up: it stays.
	if it != null and dm > 0.0005 and str(it.get("item_id")) == "terrain" and bool(it.get("using")):
		HudMode.reveal("material", MAT_SHOW)
	if (it != null and on_foot and it.has_method("menu_wanted") and bool(it.menu_wanted())) or _supply_menu_open() \
			or _armory_open():
		HudMode.reveal("material", 1.2)
	_mat_a = 1.0 if HudMode.shown("material") else 0.0
	HudMode.fade(_mat, _mat_a > 0.5)
	# Crosshair: the drill's colour and state, the interact ring, the jetpack fuel arc.
	crosshair.visible = on_foot
	if it != null:
		crosshair.color = it.crosshair_color() if it.has_method("crosshair_color") else it.accent_color()
		crosshair.using = it.using
		crosshair.valid = it.get("aim_valid") != false
	crosshair.has_target = p.interact_target != null
	crosshair.fuel = p.jet_fuel_frac()
	crosshair.jetting = p.jetting
	# Health: the trail waits, then drains; healed segments glow.
	var dead: bool = p.has_method("is_dead") and p.is_dead()
	if dead and not _was_dead:
		stats["deaths"] = int(stats["deaths"]) + 1
	_was_dead = dead
	var f := clampf(float(p.hp) / maxf(float(p.hp_max), 1.0), 0.0, 1.0)
	if f < _hp_frac - 0.0005:
		if _trail < _hp_frac:
			_trail = _hp_frac
		_trail_hold = UI.TRAIL_HOLD
	elif f > _hp_frac + 0.0005:
		_heal_from = minf(_hp_frac, _heal_from) if _heal_t > 0.0 else _hp_frac
		_heal_t = 0.9
		_trail = f
	_hp_frac = f
	if _trail > f:
		if _trail_hold > 0.0:
			_trail_hold -= delta
		else:
			_trail = maxf(_trail - UI.TRAIL_RATE * delta, f)
		redraw = true
	if _heal_t > 0.0:
		_heal_t = maxf(_heal_t - delta, 0.0)
		redraw = true
	if _hit > 0.0:
		_hit = maxf(_hit - delta * 2.5, 0.0)
		redraw = true
	if f < 0.35 and not dead:
		redraw = true                              # the low-health pulse
	var fuel_on: bool = bool(p.jetting) or float(p.jet_fuel_frac()) < 0.995
	var fv := move_toward(_fuel_vis, 1.0 if fuel_on else 0.0, delta * (5.0 if fuel_on else 1.5))
	if fv != _fuel_vis or fuel_on:
		_fuel_vis = fv
		redraw = true
	# The held item: redraw when what is shown changes (an int signature, no strings).
	var sig: int = int(floorf(m)) * 7 + int(ceilf(float(p.hp))) * 131 + int(p.current_item) * 9973
	if it != null:
		sig = sig * 31 + _mag(it)
		sig = sig * 31 + _reserve(it)
		if it.get("reloading") == true:
			redraw = true
		if it.get("charging") == true or (it.get("cool") != null and float(it.cool) > 0.0):
			redraw = true
		if it.get("radius") != null:
			sig = sig * 31 + int(float(it.radius) * 10.0)
		if it.get("work_mode") != null:
			sig = sig * 31 + int(it.work_mode)
		if it.get("fire_mode") != null:
			sig = sig * 31 + int(it.fire_mode)
		if it.get("ammo_type") != null:
			sig = sig * 31 + int(it.ammo_type)
		if it.has_method("max_charges"):
			redraw = true
		if it.has_method("menu_wanted"):
			sig = sig * 31 + (1 if it.menu_wanted() else 0)
	sig = sig * 7 + HudMode.mode() * 2 + (1 if HudMode.peek() else 0)      # (the key hints come and go)
	if redraw or sig != _sig:
		_sig = sig
		_panel.queue_redraw()
		_mat.queue_redraw()


func _mag(it) -> int:
	if it == null:
		return -1
	if it.has_method("mag_count"):
		return int(it.mag_count())
	if it.get("mag") != null:
		return int(it.mag)
	return -1


func _reserve(it) -> int:
	if it != null and it.has_method("reserve_stock"):
		return int(it.reserve_stock())
	return -1


## The material shown: during a big spend it counts down from the old amount over 0.6 s.
func _mat_display() -> float:
	if _spend_t < 0.0 or _spend_t >= 0.6:
		return Game.material
	var k := _spend_t / 0.6
	k = 1.0 - pow(1.0 - k, 3.0)
	return lerpf(_spend_from, Game.material, k)


# --- Drawing: the plates --------------------------------------------------------------------------

func _draw_panel() -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return
	var vs := _panel.size
	var k := UI.scale_k(vs)
	_draw_vitals(p, vs, k)
	var it = p.items[p.current_item] if p.items.size() > p.current_item else null
	if it != null and p.vehicle == null:
		if it.has_method("menu_wanted") and bool(it.menu_wanted()):
			return                                   # (the build tool's card bar says it all)
		_draw_item(it, vs, k)


## MALZEME on its own canvas (Sade fades it in and out: HudMode "material").
func _draw_mat() -> void:
	var p = Game.player
	if p == null or not is_instance_valid(p):
		return
	var vs := _mat.size
	_draw_material(vs, UI.scale_k(vs))


## MALZEME (top right).
func _draw_material(vs: Vector2, k: float) -> void:
	var w := PANEL_W * k
	var h := 74.0 * k
	var r := Rect2(Vector2(vs.x - MARGIN * k - w, _top_y(k)), Vector2(w, h))
	var spend := 1.0 - clampf(_spend_t / 1.4, 0.0, 1.0) if _spend_t >= 0.0 else 0.0
	UI.draw_glass(_mat, r, k, UI.SUIT_ORANGE, _mat_pulse * 0.55)
	if spend > 0.0:
		UI.draw_chamfer(_mat, r, UI.CUT * k, Color(UI.BAD, 0.08 * spend), Color(UI.BAD, 0.75 * spend), 2)
	var x := r.position.x + 16.0 * k
	_mat.draw_rect(Rect2(r.position.x + 1.0, r.position.y + 16.0 * k, 3.0 * k, h - 32.0 * k), Color(UI.SUIT_ORANGE, 0.9))
	# (Co-op "Birlikte": one pool for both players, Game.shared_pool.)
	UI.draw_text(_mat, UI.font_caps(700, 2), Vector2(x, r.position.y + 22.0 * k),
			"TAKIM MALZEMESİ" if Game.shared_pool else "MALZEME", UI.fs(11, k), UI.DIM, 2)
	# The amount (tabular figures), "m³".
	var amount := "%d" % int(floorf(_mat_display() + 0.0001))
	var big := UI.fs(36.0 + 3.0 * _mat_pulse, k)
	var col := UI.TEXT.lerp(UI.SUIT_ORANGE.lightened(0.2), _mat_pulse * 0.55).lerp(UI.BAD.lightened(0.2), spend * 0.6)
	UI.draw_text(_mat, _font_n, Vector2(x, r.position.y + 62.0 * k), amount, big, col)
	var aw := UI.text_w(_font_n, amount, big)
	UI.draw_text(_mat, _font, Vector2(x + aw + 5.0 * k, r.position.y + 62.0 * k), "m³", UI.fs(17, k), UI.DIM)
	# The gain / the spend, top right of the plate.
	var right := r.end.x - 14.0 * k
	if spend > 0.0:
		var rise := 10.0 * k * (1.0 - spend)
		UI.draw_text_r(_mat, _font_n, right, r.position.y + 24.0 * k - rise, "−%d m³" % int(roundf(_spend_amt)), UI.fs(15, k),
				Color(UI.BAD.lightened(0.15), spend))
	elif _gain_t > 0.0 and _gain_amt >= 0.5:
		var ga := clampf(_gain_t / 0.5, 0.0, 1.0)
		var rise2 := 8.0 * k * (1.0 - clampf(_gain_t / 1.3, 0.0, 1.0))
		UI.draw_text_r(_mat, _font_n, right, r.position.y + 24.0 * k - rise2, "+%d" % int(roundf(_gain_amt)), UI.fs(15, k),
				Color(UI.GOOD, ga))
	# A small soil cube.
	_cube(Vector2(right - 9.0 * k, r.position.y + 50.0 * k), 9.0 * k, UI.RES_COLORS[3])


func _cube(c: Vector2, s: float, col: Color) -> void:
	var top := PackedVector2Array([c + Vector2(0, -s), c + Vector2(s * 0.87, -s * 0.5), c, c + Vector2(-s * 0.87, -s * 0.5)])
	var left := PackedVector2Array([c + Vector2(-s * 0.87, -s * 0.5), c, c + Vector2(0, s), c + Vector2(-s * 0.87, s * 0.5)])
	var right := PackedVector2Array([c, c + Vector2(s * 0.87, -s * 0.5), c + Vector2(s * 0.87, s * 0.5), c + Vector2(0, s)])
	_mat.draw_colored_polygon(top, col.lightened(0.25))
	_mat.draw_colored_polygon(left, col)
	_mat.draw_colored_polygon(right, col.darkened(0.3))


## CAN: the suit-integrity plate (bottom left).
func _draw_vitals(p, vs: Vector2, k: float) -> void:
	var w := VITAL_W * k
	var h := 80.0 * k
	var r := Rect2(Vector2(MARGIN * k, vs.y - MARGIN * k - h), Vector2(w, h))
	var dead: bool = p.has_method("is_dead") and p.is_dead()
	var f := _hp_frac
	var hc := UI.hp_color(f)
	var low := f < 0.35 and not dead
	var pulse := 0.5 + 0.5 * sin(_t * TAU * UI.PULSE_HZ) if low else 0.0
	if low:
		hc = hc.lerp(UI.CRIT.lightened(0.1), 0.25 + 0.35 * pulse)
	var a := 0.55 if dead else 1.0
	UI.draw_glass(_panel, r, k, UI.CRIT if low else hc, maxf(pulse * 0.7, _hit * 0.8), a)
	if _hit > 0.01:
		UI.draw_chamfer(_panel, r, UI.CUT * k, Color(UI.CRIT, 0.1 * _hit), Color(UI.CRIT, 0.8 * _hit), 2)
	_panel.draw_rect(Rect2(r.position.x + 1.0, r.position.y + 16.0 * k, 3.0 * k, h - 32.0 * k), Color(hc, 0.95 * a))
	var x := r.position.x + 16.0 * k
	var caps := UI.font_caps(700, 2)
	UI.draw_text(_panel, caps, Vector2(x, r.position.y + 22.0 * k), "CAN", UI.fs(11, k), Color(UI.DIM, a), 2)
	if HudMode.mode() != HudMode.SADE or HudMode.peek():
		UI.draw_text(_panel, _font, Vector2(x + UI.text_w(caps, "CAN", UI.fs(11, k)) + 8.0 * k, r.position.y + 22.0 * k),
				"giysi bütünlüğü", UI.fs(11, k), Color(UI.FAINT, a), 2)
	# Status on the right of the header.
	var status := ""
	var scol := UI.WARN
	if dead:
		status = "BAĞLANTI YOK"
		scol = UI.FAINT
	elif f < 0.2:
		status = "KRİTİK"
		scol = UI.CRIT.lightened(0.15)
	elif f < 0.35:
		status = "DÜŞÜK"
	if status != "":
		var sa := 1.0 if status != "KRİTİK" else (0.55 + 0.45 * pulse)
		UI.draw_text_r(_panel, caps, r.end.x - 14.0 * k, r.position.y + 22.0 * k, status, UI.fs(11, k), Color(scol, sa * a), 2)
	# The number.
	var num := ("%d" % int(ceilf(float(p.hp)))) if not dead else "—"          # (dead / the respawn ride: no reading)
	var nfs := UI.fs(36, k)
	var ncol := hc.lerp(Color(1.0, 0.95, 0.92), 0.25 + 0.3 * pulse) if not dead else UI.FAINT
	UI.draw_text(_panel, _font_n, Vector2(x, r.position.y + 63.0 * k), num, nfs, ncol)
	var nw := UI.text_w(_font_n, num, nfs)
	if not dead:
		UI.draw_text(_panel, _font_n, Vector2(x + nw + 4.0 * k, r.position.y + 63.0 * k), "/%d" % int(p.hp_max), UI.fs(13, k),
				Color(UI.DIM, 0.8 * a), 2)
	# The segmented bar with the damage trail; healed segments glow green.
	var bx := r.position.x + 104.0 * k
	var bar := Rect2(Vector2(bx, r.position.y + 37.0 * k), Vector2(r.end.x - 14.0 * k - bx, 13.0 * k))
	var trail_col := Color(1.0, 0.93, 0.86, 0.85) if not low else Color(1.0, 0.7, 0.62, 0.9)
	UI.draw_seg_bar(_panel, bar, SEGMENTS, f if not dead else 0.0, Color(hc, a), maxf(2.0 * k, 1.5), _trail if not dead else -1.0, trail_col)
	if _heal_t > 0.0 and f > _heal_from and not dead:
		var ha := clampf(_heal_t / 0.9, 0.0, 1.0)
		var hx0 := bar.position.x + bar.size.x * _heal_from
		_panel.draw_rect(Rect2(Vector2(hx0, bar.position.y - 2.0 * k), Vector2(bar.size.x * (f - _heal_from), bar.size.y + 4.0 * k)),
				Color(UI.GOOD.lightened(0.3), 0.35 * ha))
	# Tick marks under every quarter.
	for q in range(1, 4):
		var tx := bar.position.x + bar.size.x * q * 0.25
		_panel.draw_rect(Rect2(Vector2(tx - 0.5, bar.end.y + 3.0 * k), Vector2(1.0, 3.0 * k)), Color(UI.SUIT_WHITE, 0.25 * a))
	# The jetpack while it is not full.
	if _fuel_vis > 0.01:
		var fuel := clampf(float(p.jet_fuel_frac()), 0.0, 1.0)
		var fa := _fuel_vis * a
		var fcol := UI.SCREEN_CYAN if fuel >= 0.25 else (UI.WARN if fuel >= 0.1 else UI.CRIT)
		if fuel < 0.1 and fmod(_t, 0.5) < 0.22:
			fcol = fcol.lightened(0.3)
		var fy := r.position.y + 66.0 * k
		UI.draw_text(_panel, UI.font_caps(700, 1), Vector2(bx, fy + 5.0 * k), "JET", UI.fs(10, k), Color(UI.DIM, fa), 2)
		var fx := bx + 30.0 * k
		var fr := Rect2(Vector2(fx, fy), Vector2(bar.end.x - fx, 3.0 * k))
		_panel.draw_rect(fr, Color(UI.SUIT_WHITE, 0.1 * fa))
		_panel.draw_rect(Rect2(fr.position, Vector2(fr.size.x * fuel, fr.size.y)), Color(fcol, 0.95 * fa))


## The held item (bottom right).
func _draw_item(it, vs: Vector2, k: float) -> void:
	var w := WEAPON_W * k
	var h := 80.0 * k
	var r := Rect2(Vector2(vs.x - MARGIN * k - w, vs.y - MARGIN * k - h), Vector2(w, h))
	var col: Color = it.accent_color() if it.has_method("accent_color") else UI.SCREEN_CYAN
	var reloading: bool = it.get("reloading") == true
	UI.draw_glass(_panel, r, k, col, 0.0)
	_panel.draw_rect(Rect2(r.position.x + 1.0, r.position.y + 16.0 * k, 3.0 * k, h - 32.0 * k), Color(col, 0.9))
	var x := r.position.x + 16.0 * k
	var right := r.end.x - 14.0 * k
	var top := r.position.y + 22.0 * k
	var caps := UI.font_caps(700, 2)
	var title: String = str(it.get("panel_name")) if it.get("panel_name") != null else str(it.item_name)
	UI.draw_text(_panel, caps, Vector2(x, top), UI.upper_tr(title), UI.fs(11, k), col.lightened(0.35), 2)
	var bar := Rect2(Vector2(x, r.end.y - 13.0 * k), Vector2(right - x, 4.0 * k))
	var mag := _mag(it)
	if it.has_method("max_charges"):
		_draw_pusher(it, r, x, right, bar, k, col)
	elif mag >= 0:
		# Chips: the fire mode, the ammo type.
		var cx := right
		if it.has_method("ammo_short"):
			cx -= _chip(Vector2(cx, top), str(it.ammo_short()), it.ammo_color() if it.has_method("ammo_color") else col, k) + 5.0 * k
		var mt := str(it.mode_text()) if it.has_method("mode_text") else ""
		if mt != "" and not reloading:
			_chip(Vector2(cx, top), mt, UI.SCREEN_CYAN, k)
		# Magazine (big) / reserve.
		var cap := maxi(int(it.call("mag_capacity")), 1) if it.has_method("mag_capacity") else maxi(mag, 1)
		var frac := clampf(float(mag) / float(cap), 0.0, 1.0)
		var mc := UI.TEXT if frac > 0.34 else (UI.WARN if mag > 0 else UI.CRIT)
		var mfs := UI.fs(40, k)
		var ms := str(mag)
		UI.draw_text(_panel, _font_n, Vector2(x, r.position.y + 62.0 * k), ms, mfs, mc)
		var reserve := _reserve(it)
		if reserve >= 0:
			UI.draw_text(_panel, _font_n, Vector2(x + UI.text_w(_font_n, ms, mfs) + 6.0 * k, r.position.y + 62.0 * k),
					"/ %d" % reserve, UI.fs(17, k), UI.DIM, 2)
		# Status on the right: the reload, empty, or the price of a round once the reserve is gone.
		var st := ""
		var sc := UI.DIM
		var cost: float = float(it.round_cost()) if it.has_method("round_cost") else 0.0
		if reloading:
			st = str(it.reload_label()) if it.has_method("reload_label") else "DOLDURULUYOR"
			sc = Color(UI.SUIT_ORANGE.lightened(0.2), 0.7 + 0.3 * sin(_t * 9.0))
		elif mag == 0:
			st = "BOŞ  ·  R" if reserve != 0 or cost > 0.0 else "MERMİ YOK"
			sc = Color(UI.CRIT.lightened(0.1), 0.6 + 0.4 * sin(_t * 9.0))
		elif reserve == 0 and cost > 0.0:
			st = "mermi %s m³" % String.num(cost, 2).replace(".", ",")
			sc = UI.WARN
		if st != "":
			UI.draw_text_r(_panel, UI.font_caps(700, 1), right, r.position.y + 58.0 * k, st, UI.fs(11, k), sc, 2)
		# The bar: the magazine (segments for small ones), the reload, the railgun's charge / cooldown.
		var fill := frac
		var bc := UI.SCREEN_CYAN if frac > 0.34 else (UI.WARN if mag > 0 else UI.CRIT)
		var segs := cap if cap <= 40 else 1
		if reloading and it.has_method("reload_progress"):
			fill = clampf(float(it.reload_progress()), 0.0, 1.0)
			bc = UI.SUIT_ORANGE
			segs = 1
		elif it.get("charging") == true and it.get("charge") != null:
			fill = clampf(float(it.charge), 0.0, 1.0)
			bc = col.lerp(Color(1.0, 0.98, 0.95), 0.3)
			segs = 1
		elif it.get("cool") != null and float(it.cool) > 0.0 and it.get("cool_total") != null:
			fill = 1.0 - clampf(float(it.cool) / maxf(float(it.cool_total), 0.01), 0.0, 1.0)
			bc = Color(col, 0.6)
			segs = 1
		if segs > 1:
			UI.draw_seg_bar(_panel, bar, segs, fill, bc, maxf((1.5 if segs > 16 else 2.5) * k, 1.0))
		else:
			_panel.draw_rect(bar, Color(UI.SUIT_WHITE, 0.1))
			_panel.draw_rect(Rect2(bar.position, Vector2(bar.size.x * fill, bar.size.y)), bc)
	elif it.get("radius") != null:
		# The drill: its mode (in its colour) and the brush radius.
		var mn := UI.upper_tr(str(it.mode_name())) if it.has_method("mode_name") else ""
		UI.draw_text(_panel, _font_b, Vector2(x, r.position.y + 58.0 * k), mn, UI.fs(28, k), col.lightened(0.15))
		var rs := "%s m" % String.num(float(it.radius), 1).replace(".", ",")
		var rw := UI.draw_text_r(_panel, _font_n, right, r.position.y + 58.0 * k, rs, UI.fs(20, k), UI.TEXT)
		UI.draw_text_r(_panel, UI.font_caps(700, 1), right - rw - 8.0 * k, r.position.y + 56.0 * k, "FIRÇA", UI.fs(10, k), UI.DIM, 2)
		if HudMode.mode() == HudMode.DETAYLI or HudMode.peek():          # (key hints: Detaylı / Alt only)
			UI.draw_text_r(_panel, _font, right, top, "Orta tık: mod  ·  R: soğut  ·  teker: fırça", UI.fs(11, k), UI.FAINT, 2)
		_panel.draw_rect(bar, Color(col, 0.35))
	elif it.has_method("hud_panel_lines"):
		var ln: Array = it.hud_panel_lines()
		UI.draw_text(_panel, _font_b, Vector2(x, r.position.y + 54.0 * k), str(ln[0]), UI.fs(18, k), UI.TEXT)
		UI.draw_text(_panel, _font, Vector2(x, r.end.y - 12.0 * k), str(ln[1]), UI.fs(13, k), ln[2] if ln.size() > 2 else UI.DIM, 2)


## The Kinetik İtici: its capacitor charges (pips, the recharging one filling), m³ per blast.
func _draw_pusher(it, r: Rect2, x: float, right: float, bar: Rect2, k: float, col: Color) -> void:
	var n := clampi(int(it.max_charges()), 1, 6)
	var have := int(it.get("mag")) if it.get("mag") != null else 0
	var part: float = float(it.charge_frac()) if it.has_method("charge_frac") else 0.0
	var mfs := UI.fs(40, k)
	var hs := str(have)
	UI.draw_text(_panel, _font_n, Vector2(x, r.position.y + 62.0 * k), hs, mfs, UI.TEXT if have > 0 else UI.CRIT)
	UI.draw_text(_panel, _font_n, Vector2(x + UI.text_w(_font_n, hs, mfs) + 6.0 * k, r.position.y + 62.0 * k), "/ %d" % n,
			UI.fs(17, k), UI.DIM, 2)
	var pw := 22.0 * k
	var ph := 12.0 * k
	var gap := 5.0 * k
	var px0 := right - n * pw - (n - 1) * gap
	var py := r.position.y + 36.0 * k
	var pc := UI.SCREEN_CYAN
	for i in n:
		var pr := Rect2(Vector2(px0 + i * (pw + gap), py), Vector2(pw, ph))
		UI.draw_chamfer(_panel, pr, 3.0 * k, Color(UI.SUIT_WHITE, 0.08), Color(pc, 0.35))
		if i < have:
			UI.draw_chamfer(_panel, pr, 3.0 * k, pc)
		elif i == have and part > 0.0:
			_panel.draw_rect(Rect2(pr.position + Vector2(1, 1), Vector2((pw - 2.0) * part, ph - 2.0)), Color(pc, 0.5))
	var cost: float = float(it.shot_cost()) if it.has_method("shot_cost") else 0.0
	if cost > 0.0:
		UI.draw_text_r(_panel, UI.font_caps(700, 1), right, r.position.y + 64.0 * k, "%s m³ / atış" % String.num(cost, 0),
				UI.fs(10, k), UI.DIM, 2)
	_panel.draw_rect(bar, Color(UI.SUIT_WHITE, 0.1))
	var fr := (float(have) + (part if have < n else 0.0)) / float(n)
	_panel.draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(fr, 0.0, 1.0), bar.size.y)), Color(pc, 0.9))


## A small caps chip right-aligned at `right_top` (x = its right edge, y = the text baseline);
## returns its width.
func _chip(right_top: Vector2, s: String, col: Color, k: float) -> float:
	var f := UI.font_caps(700, 1)
	var fsz := UI.fs(10, k)
	var tw := UI.text_w(f, s, fsz)
	var w := tw + 12.0 * k
	var r := Rect2(Vector2(right_top.x - w, right_top.y - 12.0 * k), Vector2(w, 16.0 * k))
	UI.draw_chamfer(_panel, r, 4.0 * k, Color(col, 0.16), Color(col, 0.6))
	_panel.draw_string(f, Vector2(r.position.x + 6.0 * k, right_top.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, col.lightened(0.3))
	return w


# --- Drawing: the prompt and the toast ------------------------------------------------------------

## The interact prompt above the quickbar: [key] (BASILI TUT) text on a glass pill; the hold-F ring of
## a gun on the ground fills around the key.
func _draw_prompt() -> void:
	var hold := WeaponDrop.hold_progress()
	var p = Game.player
	var alive: bool = p != null and is_instance_valid(p) and p.get("vehicle") == null \
			and not (p.has_method("is_dead") and p.is_dead())
	if _p_a <= 0.01 or _p_shown == "" or not alive:
		return
	var vs := _prompt.size
	var k := UI.scale_k(vs)
	var a := _p_a
	var fsz := UI.fs(17, k)
	var h := 40.0 * k
	var kr := 13.0 * k                                    # the key disc
	var hold_w := UI.text_w(UI.font_caps(700, 1), _p_hold, UI.fs(10, k)) + 10.0 * k if _p_hold != "" else 0.0
	var key_w := kr * 2.0 if _p_key.length() <= 2 else UI.text_w(_font_b, _p_key, UI.fs(13, k)) + 14.0 * k
	var tw := UI.text_w(_font_b, _p_text, fsz)
	var w := 12.0 * k + key_w + 10.0 * k + hold_w + tw + 18.0 * k
	var c := Vector2(vs.x * 0.5, vs.y - 150.0 * k)
	var held = p.items[p.current_item] if p.items.size() > p.current_item else null
	if held != null and held.has_method("menu_wanted") and bool(held.menu_wanted()):
		c.y = vs.y * 0.5 - 100.0 * k                      # (the build card bar fills the bottom: above the crosshair)
	var slide := (1.0 - UI.smooth(a)) * 8.0 * k
	var r := Rect2(Vector2(c.x - w * 0.5, c.y - h * 0.5 + slide), Vector2(w, h))
	UI.draw_glass(_prompt, r, k, UI.SUIT_ORANGE, 0.0, a, false, 8.0)
	var x := r.position.x + 12.0 * k
	var cy := r.get_center().y
	if _p_key != "":
		if _p_key.length() <= 2:
			var kc := Vector2(x + kr, cy)
			_prompt.draw_circle(kc, kr, Color(UI.SUIT_WHITE, 0.92 * a))
			var kf := UI.fs(14, k)
			var kw := UI.text_w(_font_b, _p_key, kf)
			_prompt.draw_string(_font_b, Vector2(kc.x - kw * 0.5, kc.y + kf * 0.36), _p_key, HORIZONTAL_ALIGNMENT_LEFT, -1, kf,
					Color(UI.INK, a))
			# The hold ring.
			if hold >= 0.0:
				UI.draw_ring(_prompt, kc, kr + 4.5 * k, hold, Color(UI.SUIT_ORANGE, a), maxf(3.0 * k, 2.0))
				if hold >= 0.999:
					_prompt.draw_arc(kc, kr + 8.0 * k, 0.0, TAU, 32, Color(UI.SUIT_ORANGE, 0.5 * a), 1.5, true)
		else:
			UI.draw_key(_prompt, Vector2(x, cy - UI.fs(13, k) * 0.73), _p_key, k, false, a, 13)
		x += key_w + 10.0 * k
	if _p_hold != "":
		var hf := UI.font_caps(700, 1)
		var hr := Rect2(Vector2(x, cy - 8.0 * k), Vector2(hold_w - 4.0 * k, 16.0 * k))
		UI.draw_chamfer(_prompt, hr, 4.0 * k, Color(UI.SUIT_ORANGE, 0.18 * a), Color(UI.SUIT_ORANGE, 0.6 * a))
		_prompt.draw_string(hf, Vector2(x + 3.0 * k, cy + 4.0 * k), _p_hold, HORIZONTAL_ALIGNMENT_LEFT, -1, UI.fs(10, k),
				Color(UI.SUIT_ORANGE.lightened(0.35), a))
		x += hold_w
	UI.draw_text(_prompt, _font_b, Vector2(x, cy + fsz * 0.36), _p_text, fsz, Color(UI.TEXT, a))


## The alert lines: glass pills stacked in the upper third (critical on top), each easing to its slot;
## they drop in and fade out. Info: a cyan tick, a size smaller; normal: the orange tick; critical: a
## red frame, an alert icon, a pulse on arrival. A thin line along the bottom: how long it stays.
func _draw_toast() -> void:
	if _alerts.is_empty():
		return
	var vs := _toast.size
	var k := UI.scale_k(vs)
	var h := 40.0 * k
	var step := h + 8.0 * k
	var y0 := vs.y * 0.245
	for al in _alerts:
		var pri := int(al["pri"])
		var age := float(al["age"])
		var out := float(al["out"])
		var a := clampf(age / ALERT_IN, 0.0, 1.0) * (1.0 - clampf(out, 0.0, 1.0))
		if a <= 0.005:
			continue
		var txt := str(al["text"])
		var fsz := UI.fs(16 if pri == 0 else (19 if pri == 2 else 18), k)
		var icon_w := 22.0 * k if pri == 2 else 0.0
		var max_w := vs.x * 0.62
		txt = UI.ellipsize(_font_b, txt, fsz, max_w - 44.0 * k - icon_w)
		var w := UI.text_w(_font_b, txt, fsz) + 44.0 * k + icon_w
		var drop := (1.0 - UI.smooth(clampf(age / 0.2, 0.0, 1.0))) * -10.0 * k - out * 6.0 * k
		var r := Rect2(Vector2(vs.x * 0.5 - w * 0.5, y0 + float(al["y"]) * step + drop), Vector2(w, h))
		var col := UI.SCREEN_CYAN if pri == 0 else (UI.CRIT if pri == 2 else UI.SUIT_ORANGE)
		var bump := float(al["bump"])
		var hi := (0.45 + 0.4 * maxf(1.0 - age / 0.5, 0.0)) if pri == 2 else bump * 0.5
		UI.draw_glass(_toast, r, k, col, clampf(hi, 0.0, 1.0), a * 0.95, false, 9.0)
		if pri == 2:
			UI.draw_chamfer(_toast, r, 9.0 * k, Color(0, 0, 0, 0), Color(UI.CRIT, 0.85 * a), 1)
		_toast.draw_rect(Rect2(r.position + Vector2(10.0 * k, 11.0 * k), Vector2(3.0 * k, h - 22.0 * k)), Color(col, a))
		var life := clampf(float(al["t"]) / maxf(float(al["life"]), 0.01), 0.0, 1.0) if out <= 0.0 else 0.0
		_toast.draw_rect(Rect2(Vector2(r.position.x + 12.0 * k, r.end.y - 3.0 * k), Vector2((w - 24.0 * k) * life, 1.5 * k)),
				Color(col if pri == 2 else UI.SUIT_WHITE, 0.3 * a))
		var tx := r.position.x + 24.0 * k
		if pri == 2:
			UI.draw_alert_icon(_toast, Vector2(tx + 7.0 * k, r.get_center().y), 7.0 * k, Color(UI.CRIT.lightened(0.2), a))
			tx += icon_w
		var tc := UI.TEXT.lerp(Color(1.0, 0.86, 0.82), 0.5) if pri == 2 else (UI.TEXT.lerp(UI.SCREEN_CYAN, 0.25) if pri == 0 else UI.TEXT)
		UI.draw_text(_toast, _font_b, Vector2(tx, r.get_center().y + fsz * 0.36), txt, fsz, Color(tc, a))


## The objective line (top left): the compact Normal line and the HEDEF plate, cross-faded by _obj_a.
func _draw_objective() -> void:
	if _obj_text == "":
		return
	var vs := _obj.size
	var k := UI.scale_k(vs)
	var x0 := MARGIN * k
	var y0 := MARGIN * k
	var full := UI.smooth(clampf(_obj_a, 0.0, 1.0))
	var accent := UI.CRIT if _obj_crit else UI.SUIT_ORANGE
	var label := "SAVUN" if _obj_crit else "HEDEF"
	var caps := UI.font_caps(700, 2)
	if full < 0.999:
		var ca := 1.0 - full
		var lw := UI.text_w(caps, label, UI.fs(10, k))
		UI.draw_text(_obj, caps, Vector2(x0, y0 + 12.0 * k), label, UI.fs(10, k), Color(accent.lightened(0.2), 0.9 * ca), 2)
		UI.draw_text(_obj, _font_b, Vector2(x0 + lw + 8.0 * k, y0 + 12.0 * k), _obj_short if _obj_short != "" else _obj_text,
				UI.fs(13, k), Color(UI.TEXT, 0.85 * ca), 2)
	if full <= 0.001:
		return
	var fsz := UI.fs(17, k)
	var max_w := 560.0 * k
	var txt := UI.ellipsize(_font_b, _obj_text, fsz, max_w - 32.0 * k)
	var w := clampf(UI.text_w(_font_b, txt, fsz) + 34.0 * k, 220.0 * k, max_w)
	var h := 54.0 * k
	var r := Rect2(Vector2(x0, y0 - (1.0 - full) * 6.0 * k), Vector2(w, h))
	UI.draw_glass(_obj, r, k, accent, 0.35 if _obj_crit else 0.0, full)
	_obj.draw_rect(Rect2(r.position.x + 1.0, r.position.y + 12.0 * k, 3.0 * k, h - 24.0 * k), Color(accent, 0.95 * full))
	var x := r.position.x + 16.0 * k
	UI.draw_text(_obj, caps, Vector2(x, r.position.y + 20.0 * k), label, UI.fs(10, k), Color(accent.lightened(0.25), full), 2)
	# Sade: how to see it all again (the hold key), small at the right of the label row.
	if HudMode.mode() == HudMode.SADE and not HudMode.peek():
		var hs := "basılı: tümü"
		var hw := UI.text_w(_font, hs, UI.fs(10, k))
		UI.draw_text(_obj, _font, Vector2(r.end.x - 14.0 * k - hw, r.position.y + 20.0 * k), hs, UI.fs(10, k), Color(UI.FAINT, full), 2)
		var kw := UI.text_w(_font_b, HudMode.HOLD_KEY, UI.fs(9, k)) + 10.0 * k
		UI.draw_key(_obj, Vector2(r.end.x - 20.0 * k - hw - kw, r.position.y + 8.0 * k), HudMode.HOLD_KEY, k, false, full, 9)
	UI.draw_text(_obj, _font_b, Vector2(x, r.position.y + 43.0 * k), txt, fsz, Color(UI.TEXT, full), 3)
