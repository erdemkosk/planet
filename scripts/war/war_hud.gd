extends CanvasLayer
## War overlay, in the design system's look (scripts/ui/ui_style.gd), laid out for 1080p and scaled
## with the window height:
##   top centre   the "alan" cluster: YURT ÇEKİRDEĞİ (left) and RAKİP ÇEKİRDEĞİ (right): segmented
##                bars anchored at the outer edges, a damage trail, a white flash and a glow when hit,
##                the hp and your distance to that core; between them the area chip: where you are
##                (YURT / RAKİP / UZAY and the planet's name), the match time and the next drop-pod
##                raid when it is known (read from the rival team: "ÇIKARMA 1:20", "HAZIRLANIYOR")
##   compass      a ribbon under it: the other planet's bearing, enemy drop pods, the inbound rival
##                skiff, enemy torpedoes, and radar contacts (red pips) from `compass_source` (a
##                Callable returning positions / nodes / {"pos"} dictionaries; the Radar Kulesi hooks
##                in there; a script "res://scripts/war/radar.gd" with a static contacts_for(team) is
##                picked up by itself)
##   warnings     stacked under it: red alert plates (hazard stripes, a warning triangle) blinking
##                "RAKİP SENİ GÖRDÜ" while a rival Uçaksavar (or a bot's rifle) is on the player's
##                skiff, "RAKİP MEKİĞİ YAKLAŞIYOR · NN m" (and a bracket / screen-edge arrow on it),
##                "DÜŞMAN ÇIKARMASI GELİYOR! · NN m" while an enemy drop pod (scripts/war/drop_pod.gd)
##                is in the air (bracket / arrow), "RAKİP KAZIYOR · NN m" while a raider digs toward our
##                core, "DÜŞMAN TORPİDOSU KAZIYOR · çekirdeğe NN m" (diamond / arrow) while a rival
##                drilling torpedo (scripts/war/torpedo.gd, group "war_torpedo") burrows into our
##                planet, `radar_alert` (e.g. "Yeraltında düşman kazısı tespit edildi") while set; and
##                cyan info plates with a progress line "TORPİDO · çekirdeğe NN m" while ours burrows
##   name tag     under the crosshair when aiming at a bot within 70 m: "Rakip — Kazıcı" (red) or
##                "Dost — …" (green, the single-player allies) with a segmented hp bar
##   end screen   on its own layer (50): a frosted backdrop, "MAÇ SONU", ZAFER / YENİLGİ, the stats of
##                the match (time, kills, headshots, structures destroyed, material dug, deaths, the
##                cores), Yeniden başla / Çık (multiplayer: the host restarts both), the world line.
## API: war (scripts/war/war.gd), show_end(won), compass_source, radar_alert.
## HUD density (scripts/ui/hud_mode.gd): the core plates, the area chip and the compass live on their
## own canvas (_plates) and fade. Sade: only while a core takes damage (CORE_REVEAL s), while a core is
## at or below ENDGAME of its hp, while an enemy torpedo / raider digs toward our core, at the match
## start and while Alt is held; the red warning plates become one critical alert line each on onset
## (Game.hud.alert, the world markers and edge arrows stay); the name tag is just its hp bar. Normal:
## all of it, at most two warning / info plates. Detaylı: everything. Whenever the plates are down a
## tiny always-on strip takes their place (_draw_strip: both cores' hp bars and every zone's owner).

const UI := preload("res://scripts/ui/ui_style.gd")
const Kit := preload("res://scripts/save/menu_kit.gd")
const Flak := preload("res://scripts/war/flak.gd")
const RandomWorld := preload("res://scripts/planet/random_world.gd")
const Balance := preload("res://scripts/war/balance.gd")

const BAR_W := 250.0
const CHIP_W := 220.0
const TOP_H := 56.0
const TOP_Y := 14.0
const COMPASS_W := 440.0
const COMPASS_H := 18.0
const COMPASS_FOV := 75.0                # degrees each side of the ribbon's centre
const SPACE_ALT := 40.0                  # m above the surface: "UZAY"
const RADAR_PATHS := ["res://scripts/war/radar_tower.gd", "res://scripts/war/radar.gd"]
const SHIELD_PATH := "res://scripts/war/core_shield.gd"
const HudMode := preload("res://scripts/ui/hud_mode.gd")
const CORE_REVEAL := 4.0                 # s: Sade shows the core plates this long after a core hit
const ENDGAME := 0.25                    # a core at or below this share of its hp: plates stay up

var war                              # scripts/war/war.gd
## Radar contacts for the compass (the Radar Kulesi): a Callable returning an Array of Vector3 / Node3D /
## {"pos": Vector3} (called ~8× a second); and a warning line shown while non-empty.
var compass_source: Callable
var radar_alert := ""
var _top: Control
var _plates: Control                 # the core plates, the area chip, the compass (they fade in Sade)
var _strip: Control                  # the always-on mini strip while the plates are hidden (_draw_strip)
var _cp: Node                        # scripts/war/control_points.gd (looked up once a second until found)
var _cp_look := 0.0
var _plate_budget := 99              # warning / info plates still allowed this frame (HUD density)
var _torp_close := false             # Sade: the "torpedo nearly at the core" alert went out
var _dig_was := false
var _end: Control
var _font: Font
var _font_b: Font
var _font_n: Font
var _flash := {"home": 0.0, "rival": 0.0}
var _last := {"home": -1.0, "rival": -1.0}
var _trail := {"home": 1.0, "rival": 1.0}
var _trail_hold := {"home": 0.0, "rival": 0.0}
var _seen := false
var _seen_t := 0.0
var _seen_check := 0.0
var _inbound: Node3D
var _inbound_was := false
var _tag_bot: Node3D
var _tag_t := 0.0
var _torps_enemy: Array = []         # rival torpedoes burrowing into our planet
var _torps_own: Array = []           # ours burrowing into theirs
var _torp_t := 0.0
var _pod: Node3D                     # the nearest enemy drop pod in flight (scripts/war/drop_pod.gd)
var _pod_was := false
var _pod_t := 0.0
var _t := 0.0
var _match_t := 0.0
var _time_s := "0:00"
var _time_i := -1
var _raid_s := ""
var _raid_col := UI.WARN
var _area := ""                      # YURT / RAKİP / UZAY
var _area_col := UI.SCREEN_CYAN
var _world := ""
var _dist := {"home": -1.0, "rival": -1.0}
var _contacts: Array = []            # radar contacts (Vector3)
var _contacts_under: Array = []      # ...underground (bool, parallel)
var _radar_script = null
var _radar_look := 0.0
var _radar_has_fn := false
var _has_radar := false                # a standing radar of ours (the compass shows "RADAR")
var _shield_script = null
var _shield := {"home": false, "rival": false}   # a standing Çekirdek Kalkanı per side
var _kills0 := {}                    # the combat HUD's tallies when the match began


func _ready() -> void:
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = UI.font(500)
	_font_b = UI.font(700)
	_font_n = UI.font_num(700)
	_strip = Control.new()
	_strip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.draw.connect(_draw_strip)
	_strip.add_to_group("gameplay_overlay")      # (hidden on the end screen / menus, overlay_guard.gd)
	_strip.modulate.a = 0.0
	add_child(_strip)
	_plates = Control.new()
	_plates.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_plates.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plates.draw.connect(_draw_plates)
	add_child(_plates)
	_top = Control.new()
	_top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.draw.connect(_draw_top)
	add_child(_top)
	var cs = _combat_stats()
	_kills0 = (cs as Dictionary).duplicate() if cs is Dictionary else {}


func _process(delta: float) -> void:
	if war == null:
		return
	_t += delta
	var paused := get_tree().paused
	if not paused and not bool(Game.get("match_over")):
		_match_t += delta
	var ti := int(_match_t)
	if ti != _time_i:
		_time_i = ti
		_time_s = "%d:%02d" % [ti / 60, ti % 60]
	for k in ["home", "rival"]:
		var c = war.home_core if k == "home" else war.rival_core
		if c == null or not is_instance_valid(c):
			continue
		var mx := maxf(float(c.hp_max), 1.0)
		if float(c.hp) <= mx * ENDGAME:
			HudMode.reveal("cores", 0.5)              # (the last stretch: the plates stay up)
		if _last[k] >= 0.0 and c.hp < _last[k]:
			_flash[k] = 1.0
			HudMode.reveal("cores", CORE_REVEAL)
			if float(_trail[k]) < float(_last[k]) / mx:
				_trail[k] = float(_last[k]) / mx
			_trail_hold[k] = UI.TRAIL_HOLD
		_last[k] = c.hp
		_flash[k] = maxf(float(_flash[k]) - delta * 1.5, 0.0)
		var f := clampf(float(c.hp) / mx, 0.0, 1.0)
		if float(_trail[k]) > f:
			if float(_trail_hold[k]) > 0.0:
				_trail_hold[k] = float(_trail_hold[k]) - delta
			else:
				_trail[k] = maxf(float(_trail[k]) - UI.TRAIL_RATE * 0.6 * delta, f)
		else:
			_trail[k] = f
	# "Seen" warning, the area, the raid timer, the radar (checked ~8 times a second).
	_seen_check -= delta
	if _seen_check <= 0.0:
		_seen_check = 0.12
		var was := _seen
		_seen = Flak.rival_tracking(get_tree())
		if not _seen:
			for a in get_tree().get_nodes_in_group("war_ai"):
				if a.get("shooting_skiff") == true:
					_seen = true
		if _seen and not was:
			_seen_t = 0.0
			if Game.sfx:
				Game.sfx.play("error", -12.0, 1.4)
			_say("RAKİP SENİ GÖRDÜ", "war_seen", 2.5)
		var tm = war.team
		# (a multiplayer client has no rival team: skiff.gd ai_inbound finds a crewed rival puppet)
		_inbound = tm.inbound_skiff() if tm != null and is_instance_valid(tm) else load("res://scripts/craft/skiff.gd").call("ai_inbound", get_tree())
		if _inbound != null and not _inbound_was and Game.sfx:
			Game.sfx.play("error", -8.0, 0.8)
		if _inbound != null and not _inbound_was:
			_say("RAKİP MEKİĞİ YAKLAŞIYOR", "war_inbound", 3.0)
		_inbound_was = _inbound != null
		var dig: bool = tm != null and is_instance_valid(tm) and float(tm.get("raid_dig_dist")) >= 0.0
		if dig and not _dig_was:
			_say("RAKİP ÇEKİRDEĞE KAZIYOR  ·  %d m" % int(tm.raid_dig_dist), "war_dig", 3.0, true)
		_dig_was = dig
		if dig or not _torps_enemy.is_empty():
			HudMode.reveal("cores", 0.5)             # (a threat to our core: its plate stays up)
		_scan_torpedoes()
		_scan_pods()
		_scan_area()
		_scan_raid()
		_scan_radar(0.12)
	_seen_t += delta
	_torp_t += delta
	_pod_t += delta
	# Name tag: a bot under the crosshair.
	_tag_t -= delta
	if _tag_t <= 0.0:
		_tag_t = 0.1
		_tag_bot = _aimed_bot()
	var plates_on := HudMode.shown("cores")
	HudMode.fade(_plates, plates_on, 0.2, 0.7)
	if _plates.modulate.a > 0.0:
		_plates.queue_redraw()
	# The mini strip takes over whenever the plates are down (cross-fade: never both, never neither).
	HudMode.fade(_strip, not plates_on, 0.35, 0.2)
	if _strip.modulate.a > 0.0:
		_strip.queue_redraw()
	_cp_look -= delta
	if (_cp == null or not is_instance_valid(_cp)) and _cp_look <= 0.0:
		_cp_look = 1.0
		_cp = get_tree().get_first_node_in_group("control_points")
	_top.queue_redraw()


## Sade: a warning plate's onset as one critical line of the HUD's alert channel (Normal / Detaylı
## draw the plates instead). sound false: this HUD already played its alarm.
func _say(text: String, key: String, secs: float, sound := false) -> void:
	if HudMode.mode() != HudMode.SADE:
		return
	if Game.hud != null and is_instance_valid(Game.hud) and Game.hud.has_method("alert"):
		Game.hud.alert(text, 2, key, secs, sound)


func _aimed_bot() -> Node3D:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var from := cam.global_position
	var to := from - cam.global_transform.basis.z * 70.0
	var q := PhysicsRayQueryParameters3D.create(from, to, Game.LAYER_PLAYER | Game.LAYER_TERRAIN | Game.LAYER_SHIP)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl is CollisionObject3D:
		q.exclude = [(pl as CollisionObject3D).get_rid()]
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var col = hit["collider"]
	if col is Node and (col as Node).has_meta("ai_bot"):
		var b = (col as Node).get_meta("ai_bot")
		if b is Node3D and is_instance_valid(b) and not b.is_dead():
			return b
	return null


## Where the player is: YURT / RAKİP / UZAY, the planet's name, the distance to each core.
func _scan_area() -> void:
	# A standing Çekirdek Kalkanı per side (scripts/war/core_shield.gd CoreShield.active_for(team)).
	if _shield_script == null and ResourceLoader.exists(SHIELD_PATH):
		var ss = load(SHIELD_PATH)
		if ss is Script and (ss as Script).can_instantiate():
			_shield_script = ss
	if _shield_script != null:
		_shield["home"] = bool(_shield_script.call("active_for", "home"))
		_shield["rival"] = bool(_shield_script.call("active_for", "rival"))
	var p = Game.player
	if p == null or not is_instance_valid(p) or not (p is Node3D):
		return
	var pos: Vector3 = (p as Node3D).global_position
	var b: Node3D = Game.dominant_body(pos)
	var alt := Game.altitude(pos)
	if b == null or alt > SPACE_ALT:
		_area = "UZAY"
		_area_col = UI.SCREEN_CYAN
		_world = "geçişte"
	else:
		var home: bool = war.core_of(b) == war.home_core
		_area = "YURT" if home else "RAKİP"
		_area_col = UI.HOME if home else UI.RIVAL
		var c = b.get("cfg")
		_world = str((c as Dictionary).get("world_name", "")) if c is Dictionary else ""
		if _world == "":
			_world = "kendi gezegenin" if home else "düşman gezegeni"
	for k in ["home", "rival"]:
		var core = war.home_core if k == "home" else war.rival_core
		_dist[k] = pos.distance_to((core as Node3D).global_position) if core != null and is_instance_valid(core) else -1.0


## The next drop-pod raid, read from the rival team (single player / host only; nothing in PvP or on
## a client): "ÇIKARMA 1:20", "ÇIKARMA YAKIN", "ÇIKARMA HAZIRLANIYOR".
func _scan_raid() -> void:
	_raid_s = ""
	var tm = war.team
	if not Balance.POD_RAIDS_ENABLED or tm == null or not is_instance_valid(tm):
		return
	if tm.get("_pod_mustering") == true:
		_raid_s = "ÇIKARMA HAZIRLANIYOR"
		_raid_col = UI.CRIT
		return
	var nx = tm.get("_pod_next")
	var mt = tm.get("_match_t")
	if nx == null or mt == null:
		return
	var left := float(nx) - float(mt)
	if left > 0.0:
		var li := int(ceilf(left))
		_raid_s = "ÇIKARMA %d:%02d" % [li / 60, li % 60]
		_raid_col = UI.WARN if left < 30.0 else UI.DIM
	else:
		_raid_s = "ÇIKARMA YAKIN"
		_raid_col = UI.WARN


## Radar contacts for the compass: compass_source, else a radar script's contacts_for("home").
func _scan_radar(dt: float) -> void:
	_contacts.clear()
	var src: Array = []
	if compass_source.is_valid():
		var r = compass_source.call()
		if r is Array:
			src = r
	else:
		_radar_look -= dt
		if _radar_script == null and _radar_look <= 0.0:
			_radar_look = 3.0
			for path in RADAR_PATHS:
				if ResourceLoader.exists(path):
					var s = load(path)
					if s is Script and (s as Script).can_instantiate():
						for m in (s as Script).get_script_method_list():
							if str(m.get("name", "")) == "contacts_for":
								_radar_script = s
							elif str(m.get("name", "")) == "has_radar":
								_radar_has_fn = true
				if _radar_script != null:
					break
		if _radar_script != null:
			var pl = Game.player
			var team: String = Game.team_of(pl) if pl != null and is_instance_valid(pl) else "home"
			var r2 = _radar_script.call("contacts_for", team)
			if r2 is Array:
				src = r2
			_has_radar = bool(_radar_script.call("has_radar", team)) if _radar_has_fn else not src.is_empty()
	if compass_source.is_valid():
		_has_radar = true
	_contacts_under.clear()
	for c in src:
		if c is Vector3:
			_contacts.append(c)
			_contacts_under.append(false)
		elif c is Object and is_instance_valid(c) and c is Node3D:
			_contacts.append((c as Node3D).global_position)
			_contacts_under.append(false)
		elif c is Dictionary:
			# The Radar Kulesi's {"pos", "kind", "under", "node"} (scripts/war/radar_tower.gd): the live
			# node position when it still exists, else the scan's.
			var d := c as Dictionary
			var n = d.get("node")
			var v = d.get("pos", d.get("position", null))
			if n is Object and is_instance_valid(n) and n is Node3D:
				v = (n as Node3D).global_position
			if v is Vector3:
				_contacts.append(v)
				_contacts_under.append(bool(d.get("under", false)) or str(d.get("kind", "")) == "dig")


# =================================================================================================
# Drawing
# =================================================================================================

## The always-on mini strip (top centre, whenever the big plates are down; the user: "hangi kale kimde
## ve iki çekirdeğin canı hep görünsün"): our core's thin hp bar (violet, filling from the outer left),
## our zones' letter chips, a divider, the rival planet's chips, their core's bar (red, from the outer
## right). Chips: filled in the owner's colour (neutral: glass grey), a pulse while contested, a red
## blink while the enemy stands in one of ours, a hairline under one that changes hands. Bars: a white
## flash on a hit, a pulse below 30 %, a cyan hairline over a shielded core. No numbers (Alt / the
## plates have them). A zone event (HudMode "zones") lights the strip up for a moment.
const STRIP_BAR := 110.0
const STRIP_CHIP := 15.0
const STRIP_GAP := 3.0


func _draw_strip() -> void:
	if war == null or _end != null or Game.match_over:
		return
	var ci := _strip
	var vs := ci.size
	var k := UI.scale_k(vs)
	var cx := vs.x * 0.5
	var y := TOP_Y * k
	var ch := STRIP_CHIP * k
	var zh: Array = []
	var zr: Array = []
	if _cp != null and is_instance_valid(_cp) and _cp.has_method("zones_of"):
		zh = _cp.zones_of(Game.planet)
		zr = _cp.zones_of(Game.rival)
	var side_w := func(n: int) -> float: return float(n) * (ch + STRIP_GAP * k)
	var mid := 12.0 * k
	var bar_w := STRIP_BAR * k
	var pad := 8.0 * k
	var w: float = pad * 2.0 + bar_w * 2.0 + float(side_w.call(zh.size())) + float(side_w.call(zr.size())) + mid + 8.0 * k
	var back := Rect2(Vector2(cx - w * 0.5, y - 5.0 * k), Vector2(w, ch + 10.0 * k))
	var lit := 1.0 if HudMode.revealed("zones") else 0.0
	UI.draw_glass(ci, back, k, UI.SUIT_ORANGE, lit * 0.45, 0.62, false, 6.0)
	# Our core's bar (outer left), our chips leftward from the divider; theirs mirrored.
	var by := y + ch * 0.5 - 2.5 * k
	_strip_bar(ci, Rect2(Vector2(back.position.x + pad, by), Vector2(bar_w, 5.0 * k)), "home", k)
	_strip_bar(ci, Rect2(Vector2(back.end.x - pad - bar_w, by), Vector2(bar_w, 5.0 * k)), "rival", k)
	ci.draw_rect(Rect2(Vector2(cx - 0.5 * k, y + 2.0 * k), Vector2(maxf(1.0 * k, 1.0), ch - 4.0 * k)), Color(UI.SUIT_WHITE, 0.3))
	var x := cx - mid * 0.5 - float(side_w.call(zh.size())) + STRIP_GAP * k
	for z in zh:
		_strip_chip(ci, Rect2(Vector2(x, y), Vector2(ch, ch)), z, k)
		x += ch + STRIP_GAP * k
	x = cx + mid * 0.5
	for z in zr:
		_strip_chip(ci, Rect2(Vector2(x, y), Vector2(ch, ch)), z, k)
		x += ch + STRIP_GAP * k


func _strip_bar(ci: Control, r: Rect2, key: String, k: float) -> void:
	var core = war.home_core if key == "home" else war.rival_core
	var home := key == "home"
	var col := UI.HOME if home else UI.RIVAL
	var frac := 0.0
	if core != null and is_instance_valid(core):
		frac = clampf(float(core.hp) / maxf(float(core.hp_max), 1.0), 0.0, 1.0)
	var fl := float(_flash.get(key, 0.0))
	if frac < 0.3 and frac > 0.0:
		col = col.lerp(UI.CRIT.lightened(0.2), 0.3 + 0.3 * sin(_t * TAU * 1.2))
	col = col.lerp(Color(1.0, 0.97, 0.95), fl * 0.6)
	ci.draw_rect(r.grow(1.0), Color(UI.OUTLINE, 0.55))
	ci.draw_rect(r, Color(col, 0.18))
	var fw := r.size.x * frac
	ci.draw_rect(Rect2(Vector2(r.position.x if home else r.end.x - fw, r.position.y), Vector2(fw, r.size.y)), col)
	var tr := clampf(float(_trail.get(key, frac)), frac, 1.0)
	if tr > frac + 0.002:
		var tw := r.size.x * (tr - frac)
		ci.draw_rect(Rect2(Vector2(r.position.x + fw if home else r.end.x - fw - tw, r.position.y), Vector2(tw, r.size.y)),
				Color(1.0, 0.93, 0.88, 0.75))
	if frac <= 0.0:
		ci.draw_rect(r, Color(UI.CRIT, 0.9), false, maxf(1.0 * k, 1.0))
	if bool(_shield.get(key, false)):
		ci.draw_rect(Rect2(r.position - Vector2(0, 3.0 * k), Vector2(r.size.x, maxf(1.2 * k, 1.0))),
				Color(UI.SCREEN_CYAN, 0.6 + 0.2 * sin(_t * 2.5)))


func _strip_chip(ci: Control, r: Rect2, z: Dictionary, k: float) -> void:
	var own := str(z.get("owner", ""))
	var fill := Color(0.45, 0.5, 0.55, 0.55)
	var ink := UI.TEXT
	if own == "home":
		fill = Color(UI.HOME, 0.9)
		ink = UI.INK
	elif own == "rival":
		fill = Color(UI.RIVAL, 0.9)
		ink = UI.INK
	var border := Color(UI.SUIT_WHITE, 0.2)
	var bw := 1
	var contested := bool(z.get("contested", false))
	var raided: bool = own == "home" and int(z.get("r", 0)) > 0
	if raided and fmod(_t, UI.BLINK) < UI.BLINK * 0.6:
		border = UI.CRIT
		bw = 2
	elif contested:
		border = Color(UI.WARN, 0.6 + 0.4 * sin(_t * 10.0))
		bw = 2
	UI.draw_chamfer(ci, r, 3.0 * k, fill, border, bw)
	UI.draw_text_c(ci, UI.font_caps(700, 1), Vector2(r.get_center().x, r.end.y - 4.0 * k), str(z.get("letter", "?")),
			UI.fs(9, k), ink, 0 if own != "" else 2)
	var p := float(z.get("progress", 0.0))
	var full: bool = (own == "home" and p >= 0.999) or (own == "rival" and p <= -0.999) or (own == "" and absf(p) < 0.001)
	if not full:
		var br := Rect2(Vector2(r.position.x, r.end.y + 1.5 * k), Vector2(r.size.x, maxf(1.5 * k, 1.5)))
		ci.draw_rect(br, Color(0, 0, 0, 0.45))
		ci.draw_rect(Rect2(br.position, Vector2(br.size.x * absf(p), br.size.y)), UI.HOME if p > 0.0 else UI.RIVAL)


## The top cluster on its own canvas (it fades as a whole in Sade): the core plates, the area chip and
## the compass. The drawing helpers draw on `_top`, so it points at `_plates` meanwhile.
func _draw_plates() -> void:
	if war == null or _end != null:
		return
	var keep := _top
	_top = _plates
	var vs := _top.size
	var k := UI.scale_k(vs)
	var cx := vs.x * 0.5
	var y := TOP_Y * k
	var gap := 8.0 * k
	var chip := Rect2(Vector2(cx - CHIP_W * k * 0.5, y), Vector2(CHIP_W * k, TOP_H * k))
	_core_bar(Rect2(Vector2(chip.position.x - gap - BAR_W * k, y), Vector2(BAR_W * k, TOP_H * k)), "home", k)
	_core_bar(Rect2(Vector2(chip.end.x + gap, y), Vector2(BAR_W * k, TOP_H * k)), "rival", k)
	_area_chip(chip, k)
	var cy := chip.end.y + 6.0 * k
	_compass(Rect2(Vector2(cx - COMPASS_W * k * 0.5, cy), Vector2(COMPASS_W * k, COMPASS_H * k)), get_viewport().get_camera_3d(), k)
	_top = keep


func _draw_top() -> void:
	if war == null or _end != null:
		return
	var vs := _top.size
	var k := UI.scale_k(vs)
	var cx := vs.x * 0.5
	var cam := get_viewport().get_camera_3d()
	var cy := (TOP_Y + TOP_H + 6.0) * k
	# The warnings (HUD density: Sade none, they went to the alert line; Normal two; Detaylı / Alt all).
	var md := HudMode.mode()
	_plate_budget = 99 if md == HudMode.DETAYLI or HudMode.peek() else (2 if md == HudMode.NORMAL else 0)
	var wy := cy + (COMPASS_H + 20.0) * k
	var step := 36.0 * k
	if _seen:
		_warn(cx, wy, "RAKİP SENİ GÖRDÜ", k, fmod(_seen_t, UI.BLINK) < UI.BLINK * 0.62)
		wy += step
	if radar_alert != "":
		_warn(cx, wy, radar_alert, k, fmod(_t, 1.0) < 0.7)
		wy += step
	if _inbound != null and is_instance_valid(_inbound) and cam != null:
		var sp: Vector3 = _inbound.global_position
		_warn(cx, wy, "RAKİP MEKİĞİ YAKLAŞIYOR  ·  %d m" % int(cam.global_position.distance_to(sp)), k, true)
		wy += step
		_marker(cam, sp, "MEKİK", k)
	if _pod != null and is_instance_valid(_pod) and cam != null:
		var pp: Vector3 = _pod.global_position
		_warn(cx, wy, "DÜŞMAN ÇIKARMASI GELİYOR!  ·  %d m" % int(cam.global_position.distance_to(pp)), k, fmod(_pod_t, 0.6) < 0.42)
		wy += step
		_marker(cam, pp, "ÇIKARMA", k)
	var tm = war.team
	if tm != null and is_instance_valid(tm) and float(tm.raid_dig_dist) >= 0.0:
		_warn(cx, wy, "RAKİP KAZIYOR  ·  çekirdeğe %d m" % int(tm.raid_dig_dist), k, true)
		wy += step
	wy = _draw_torpedoes(cx, wy, cam, k)
	wy = _mt_draw(cx, wy, cam, k)                # Göktaşı yağmuru (Meteor shower, end of file)
	_name_tag(vs, k)


## A core's plate: title and your distance to it, the hp, the segmented bar anchored at the outer
## edge (ours fills from the left, theirs from the right), the trail, the hit flash.
func _core_bar(r: Rect2, key: String, k: float) -> void:
	var core = war.home_core if key == "home" else war.rival_core
	var home := key == "home"
	var col := UI.HOME if home else UI.RIVAL
	var hp := 0.0
	var mx := 100.0
	if core != null and is_instance_valid(core):
		hp = float(core.hp)
		mx = maxf(float(core.hp_max), 1.0)
	var frac := clampf(hp / mx, 0.0, 1.0)
	var fl := float(_flash[key])
	var low := frac < 0.3 and frac > 0.0
	var pulse := (0.5 + 0.5 * sin(_t * TAU * 1.2)) if low else 0.0
	UI.draw_glass(_top, r, k, col, maxf(fl, pulse * 0.45))
	if fl > 0.01:
		UI.draw_chamfer(_top, r, UI.CUT * k, Color(col, 0.12 * fl), Color(col.lightened(0.4), 0.9 * fl), 2)
	var pad := 14.0 * k
	var caps := UI.font_caps(700, 2)
	var tfs := UI.fs(11, k)
	var title := "YURT ÇEKİRDEĞİ" if home else "RAKİP ÇEKİRDEĞİ"
	var d := float(_dist[key])
	var ds := ("%d m" % int(d)) if d >= 0.0 else ""
	var ty := r.position.y + 21.0 * k
	var tcol := col.lightened(0.3)
	var tw := UI.text_w(caps, title, tfs)
	var shielded := bool(_shield.get(key, false))
	if home:
		UI.draw_text(_top, caps, Vector2(r.position.x + pad, ty), title, tfs, tcol, 2)
		UI.draw_text_r(_top, _font_n, r.end.x - pad, ty, ds, UI.fs(12, k), UI.DIM, 2)
		if shielded:
			_shield_badge(Vector2(r.position.x + pad + tw + 12.0 * k, ty - 4.0 * k), k)
	else:
		UI.draw_text_r(_top, caps, r.end.x - pad, ty, title, tfs, tcol, 2)
		UI.draw_text(_top, _font_n, Vector2(r.position.x + pad, ty), ds, UI.fs(12, k), UI.DIM, 2)
		if shielded:
			_shield_badge(Vector2(r.end.x - pad - tw - 12.0 * k, ty - 4.0 * k), k)
	# The hp and the bar.
	var hs := ("%d" % int(ceilf(hp))) if hp > 0.0 else "YOK"
	var nfs := UI.fs(20, k)
	var nw := 52.0 * k
	var by := r.position.y + 33.0 * k
	var bar: Rect2
	var ncol := UI.TEXT.lerp(Color(1.0, 0.96, 0.94), fl) if hp > 0.0 else UI.CRIT
	if home:
		bar = Rect2(Vector2(r.position.x + pad, by), Vector2(r.size.x - pad * 2.0 - nw, 12.0 * k))
		UI.draw_text_r(_top, _font_n, r.end.x - pad, by + 12.0 * k, hs, nfs, ncol)
	else:
		bar = Rect2(Vector2(r.position.x + pad + nw, by), Vector2(r.size.x - pad * 2.0 - nw, 12.0 * k))
		UI.draw_text(_top, _font_n, Vector2(r.position.x + pad, by + 12.0 * k), hs, nfs, ncol)
	var bcol := col.lerp(Color(1.0, 0.97, 0.95), fl * 0.55)
	UI.draw_seg_bar(_top, bar, 16, frac, bcol, maxf(2.0 * k, 1.5), float(_trail[key]), Color(1.0, 0.93, 0.88, 0.8), not home)
	if shielded:
		# A shielded core: a thin cyan line over its bar.
		_top.draw_rect(Rect2(bar.position - Vector2(0, 3.0 * k), Vector2(bar.size.x, 1.5 * k)), Color(UI.SCREEN_CYAN, 0.6 + 0.2 * sin(_t * 2.5)))


## The Çekirdek Kalkanı badge: a small cyan shield centred at c.
func _shield_badge(c: Vector2, k: float) -> void:
	var s := 6.5 * k
	var pts := PackedVector2Array([c + Vector2(0, -s), c + Vector2(s * 0.85, -s * 0.6), c + Vector2(s * 0.7, s * 0.35),
			c + Vector2(0, s), c + Vector2(-s * 0.7, s * 0.35), c + Vector2(-s * 0.85, -s * 0.6)])
	_top.draw_colored_polygon(pts, Color(UI.SCREEN_CYAN, 0.25))
	var ol := PackedVector2Array(pts)
	ol.append(pts[0])
	_top.draw_polyline(ol, Color(UI.SCREEN_CYAN.lightened(0.2), 0.95), maxf(1.4 * k, 1.0), true)


## The area chip: where you are, the planet's name, the match time, the next raid.
func _area_chip(r: Rect2, k: float) -> void:
	UI.draw_glass(_top, r, k, _area_col, 0.0)
	var pad := 14.0 * k
	var y1 := r.position.y + 24.0 * k
	# A planet glyph in the area's colour.
	var gc := Vector2(r.position.x + pad + 6.0 * k, y1 - 5.0 * k)
	_top.draw_circle(gc, 6.0 * k, Color(_area_col, 0.9))
	_top.draw_arc(gc, 9.0 * k, -0.5, PI - 0.5, 16, Color(_area_col, 0.6), maxf(1.2 * k, 1.0), true)
	var afs := UI.fs(15, k)
	UI.draw_text(_top, UI.font_caps(700, 3), Vector2(gc.x + 14.0 * k, y1), _area, afs, _area_col.lightened(0.3), 2)
	UI.draw_text_r(_top, _font_n, r.end.x - pad, y1, _time_s, UI.fs(17, k), UI.TEXT, 2)
	var y2 := r.position.y + 45.0 * k
	UI.draw_text(_top, _font, Vector2(r.position.x + pad, y2), _world, UI.fs(12, k), UI.DIM, 2)
	if _raid_s != "":
		var rc := _raid_col
		if _raid_col == UI.CRIT:
			rc = Color(_raid_col, 0.6 + 0.4 * sin(_t * 8.0))
		UI.draw_text_r(_top, UI.font_caps(700, 1), r.end.x - pad, y2, _raid_s, UI.fs(10, k), rc, 2)


## The compass ribbon: ticks every 15°, the other planet, threats and radar contacts as pips;
## markers outside the ribbon sit at its ends.
func _compass(r: Rect2, cam: Camera3D, k: float) -> void:
	if cam == null:
		return
	UI.draw_chamfer(_top, r, 5.0 * k, Color(UI.GLASS, 0.42), Color(UI.SUIT_WHITE, 0.08))
	var origin := cam.global_position
	var body: Node3D = Game.dominant_body(origin)
	var up := (origin - body.global_position).normalized() if body != null else cam.global_transform.basis.y
	var fwd := -cam.global_transform.basis.z
	fwd = fwd - up * fwd.dot(up)
	if fwd.length_squared() < 0.0025:
		fwd = cam.global_transform.basis.y - up * cam.global_transform.basis.y.dot(up)
	fwd = fwd.normalized()
	var right := fwd.cross(up)
	var cx := r.get_center().x
	var half := r.size.x * 0.5 - 8.0 * k
	# Ticks.
	for i in range(-5, 6):
		var x := cx + float(i) / 5.0 * half
		var big := i % 3 == 0
		var th := (6.0 if big else 3.5) * k
		_top.draw_rect(Rect2(Vector2(x - 0.5, r.end.y - th - 2.0 * k), Vector2(1.0, th)), Color(UI.SUIT_WHITE, 0.32 if big else 0.18))
	# The centre caret.
	_top.draw_colored_polygon(PackedVector2Array([Vector2(cx - 5.0 * k, r.position.y - 1.0), Vector2(cx + 5.0 * k, r.position.y - 1.0),
			Vector2(cx, r.position.y + 5.0 * k)]), UI.SUIT_ORANGE)
	# The other planet.
	var other: Node3D = null
	if body == Game.planet:
		other = Game.rival
	elif body == Game.rival:
		other = Game.planet
	if other != null and is_instance_valid(other):
		var oc := UI.RIVAL if other == Game.rival else UI.HOME
		_pip(r, cx, half, _bearing(other.global_position - origin, fwd, right), oc, "RAKİP" if other == Game.rival else "YURT", k, 1)
	# Threats.
	if _pod != null and is_instance_valid(_pod):
		_pip(r, cx, half, _bearing(_pod.global_position - origin, fwd, right), UI.CRIT, "", k, 2)
	if _inbound != null and is_instance_valid(_inbound):
		_pip(r, cx, half, _bearing(_inbound.global_position - origin, fwd, right), UI.CRIT, "", k, 2)
	for t in _torps_enemy:
		if is_instance_valid(t):
			_pip(r, cx, half, _bearing((t.tip_position() as Vector3) - origin, fwd, right), UI.WARN, "", k, 3)
	for i in _contacts.size():
		var under: bool = i < _contacts_under.size() and bool(_contacts_under[i])
		_pip(r, cx, half, _bearing((_contacts[i] as Vector3) - origin, fwd, right), UI.CRIT, "", k, 4 if under else 0)
	# A standing radar of ours: "RADAR" at the ribbon's right end (a soft sweep when it has contacts).
	if _has_radar:
		var on := not _contacts.is_empty()
		var rc := UI.CRIT if on else UI.GOOD
		var lx := r.end.x + 8.0 * k
		_top.draw_circle(Vector2(lx + 3.0 * k, r.get_center().y), 3.0 * k, Color(rc, 0.6 + 0.4 * sin(_t * (6.0 if on else 2.0))))
		UI.draw_text(_top, UI.font_caps(700, 1), Vector2(lx + 10.0 * k, r.get_center().y + 4.0 * k), "RADAR", UI.fs(9, k),
				Color(rc.lightened(0.2), 0.9), 2)


func _bearing(d: Vector3, fwd: Vector3, right: Vector3) -> float:
	return rad_to_deg(atan2(d.dot(right), d.dot(fwd)))


## A compass marker at bearing `deg`: kind 0 dot, 1 planet (diamond + label), 2 threat (triangle),
## 3 torpedo (small diamond). Clamped to the ribbon's ends (dimmer there).
func _pip(r: Rect2, cx: float, half: float, deg: float, col: Color, label: String, k: float, kind: int) -> void:
	var out := absf(deg) > COMPASS_FOV
	var x := cx + clampf(deg / COMPASS_FOV, -1.0, 1.0) * half
	var y := r.get_center().y
	var a := 0.5 if out else 1.0
	var s := 4.5 * k
	match kind:
		1:
			_top.draw_colored_polygon(PackedVector2Array([Vector2(x, y - s * 1.2), Vector2(x + s, y), Vector2(x, y + s * 1.2),
					Vector2(x - s, y)]), Color(col, a))
			if label != "":
				UI.draw_text_c(_top, UI.font_caps(700, 1), Vector2(x, r.end.y + 12.0 * k), label, UI.fs(9, k), Color(col.lightened(0.3), a), 2)
		2:
			_top.draw_colored_polygon(PackedVector2Array([Vector2(x, y + s * 1.1), Vector2(x + s * 1.1, y - s * 0.8),
					Vector2(x - s * 1.1, y - s * 0.8)]), Color(col, a * (0.65 + 0.35 * sin(_t * 9.0))))
		3:
			var q := s * 0.8
			_top.draw_colored_polygon(PackedVector2Array([Vector2(x, y - q), Vector2(x + q, y), Vector2(x, y + q), Vector2(x - q, y)]),
					Color(col, a))
		4:
			# Underground (a radar dig contact): a hollow ring.
			_top.draw_arc(Vector2(x, y), s * 0.8, 0.0, TAU, 12, Color(col, a), maxf(1.5 * k, 1.0), true)
			_top.draw_arc(Vector2(x, y), s * 1.5, 0.0, TAU, 12, Color(col, 0.3 * a * (0.6 + 0.4 * sin(_t * 5.0))), 1.0, true)
		_:
			_top.draw_circle(Vector2(x, y), s * 0.7, Color(col, a))
			_top.draw_arc(Vector2(x, y), s * 1.4, 0.0, TAU, 12, Color(col, 0.35 * a), 1.0, true)


## A red alert plate centred at cx: hazard stripes and a warning triangle on the left; `on` false
## (the blink's off phase) dims it instead of hiding it.
func _warn(cx: float, y: float, txt: String, k: float, on := true) -> void:
	if _plate_budget <= 0:
		return                                   # (HUD density: no room for another plate)
	_plate_budget -= 1
	var fsz := UI.fs(14, k)
	var tw := UI.text_w(_font_b, txt, fsz)
	var hz := 26.0 * k
	var w := tw + hz + 40.0 * k
	var h := 30.0 * k
	var r := Rect2(Vector2(cx - w * 0.5, y), Vector2(w, h))
	var a := 1.0 if on else 0.55
	UI.draw_chamfer(_top, r, 7.0 * k, Color(0.2, 0.02, 0.025, 0.74 * a), Color(UI.CRIT, 0.85 * a), 1)
	UI.draw_hazard(_top, Rect2(r.position + Vector2(8.0 * k, 4.0 * k), Vector2(hz, h - 8.0 * k)), Color(UI.CRIT, 0.45 * a), 5.0 * k)
	UI.draw_alert_icon(_top, Vector2(r.position.x + hz + 20.0 * k, r.get_center().y), 7.0 * k, Color(UI.CRIT.lightened(0.2), a))
	var tc := Color(1.0, 0.62, 0.56).lerp(Color(1.0, 0.85, 0.82), 0.3 if on else 0.0)
	UI.draw_text(_top, _font_b, Vector2(r.position.x + hz + 32.0 * k, r.get_center().y + fsz * 0.36), txt, fsz, Color(tc, a), 3)


## A cyan info plate with a progress line along the bottom (our torpedo on its way down).
func _info(cx: float, y: float, txt: String, prog: float, k: float) -> void:
	if _plate_budget <= 0:
		return
	_plate_budget -= 1
	var fsz := UI.fs(14, k)
	var tw := UI.text_w(_font_b, txt, fsz)
	var w := tw + 32.0 * k
	var h := 30.0 * k
	var r := Rect2(Vector2(cx - w * 0.5, y), Vector2(w, h))
	UI.draw_chamfer(_top, r, 7.0 * k, Color(UI.GLASS, 0.74), Color(UI.SCREEN_CYAN, 0.7), 1)
	_top.draw_rect(Rect2(r.position + Vector2(10.0 * k, h - 5.0 * k), Vector2((w - 20.0 * k) * clampf(prog, 0.0, 1.0), 2.0 * k)),
			Color(UI.SCREEN_CYAN, 0.9))
	UI.draw_text(_top, _font_b, Vector2(r.position.x + 16.0 * k, r.get_center().y + fsz * 0.3), txt, fsz, UI.SCREEN_CYAN.lightened(0.25), 3)


## A world marker: corner brackets with the label and distance when on screen, else a chevron at the
## screen edge toward it.
func _marker(cam: Camera3D, p: Vector3, label: String, k: float) -> void:
	var vs := _top.size
	var c := vs * 0.5
	var red := Color(UI.CRIT, 0.95)
	var behind := cam.is_position_behind(p)
	var s := cam.unproject_position(p)
	var inside := not behind and s.x > 30.0 and s.y > 30.0 and s.x < vs.x - 30.0 and s.y < vs.y - 30.0
	var dist := cam.global_position.distance_to(p)
	if inside:
		var hs := 16.0 * k
		var rr := Rect2(s - Vector2(hs, hs), Vector2(hs, hs) * 2.0)
		UI.draw_corners(_top, rr.grow(1.0), 7.0 * k, Color(UI.OUTLINE, 0.6), 4.0 * k)
		UI.draw_corners(_top, rr, 7.0 * k, red, 2.0 * k)
		UI.draw_text_c(_top, UI.font_caps(700, 1), s + Vector2(0, hs + 14.0 * k), "%s  %d m" % [label, int(dist)], UI.fs(11, k), red, 3)
		return
	_edge_arrow(s, behind, c, vs, red, "%s %d m" % [label, int(dist)], k)


func _edge_arrow(s: Vector2, behind: bool, c: Vector2, vs: Vector2, col: Color, label: String, k: float) -> void:
	var d := s - c
	if behind:
		d = -d
	if d.length_squared() < 1.0:
		d = Vector2(0, 1)
	d = d.normalized()
	var r := minf(vs.x, vs.y) * 0.41
	var tip := c + d * r
	var side := Vector2(-d.y, d.x)
	var a := 16.0 * k
	var tri := PackedVector2Array([tip + d * a, tip - d * a * 0.25 + side * a * 0.7, tip - d * a * 0.05, tip - d * a * 0.25 - side * a * 0.7])
	_top.draw_colored_polygon(tri, col)
	var ol := PackedVector2Array(tri)
	ol.append(tri[0])
	_top.draw_polyline(ol, Color(UI.OUTLINE, 0.7), 1.5, true)
	UI.draw_text_c(_top, UI.font_caps(700, 1), tip - d * a * 1.3 + Vector2(0, 4.0 * k), label, UI.fs(10, k), col, 3)


## The bot under the crosshair: a plate with its name ("Rakip — …" red, "Dost — …" green) and a
## segmented hp bar.
func _name_tag(vs: Vector2, k: float) -> void:
	if _tag_bot == null or not is_instance_valid(_tag_bot):
		return
	var c := vs * 0.5
	var name_s: String = str(_tag_bot.callsign)
	var ally: bool = str(_tag_bot.get("team")) == Game.team_of(Game.player)   # (single-player ally bots, ally_team.gd)
	var col := UI.ALLY if ally else UI.RIVAL
	if HudMode.mode() == HudMode.SADE and not HudMode.peek():
		# Sade: no plate, no name: a short hp bar in the side's colour under the crosshair.
		var bw := 72.0 * k
		var fr := clampf(float(_tag_bot.hp) / maxf(float(_tag_bot.hp_max), 1.0), 0.0, 1.0)
		var br := Rect2(Vector2(c.x - bw * 0.5, c.y + 64.0 * k), Vector2(bw, 4.0 * k))
		_top.draw_rect(br.grow(1.5), Color(UI.OUTLINE, 0.5))
		UI.draw_seg_bar(_top, br, 8, fr, col, maxf(1.5 * k, 1.0))
		return
	var fsz := UI.fs(13, k)
	var tw := UI.text_w(_font_b, name_s, fsz)
	var w := maxf(tw, 90.0 * k) + 24.0 * k
	var r := Rect2(Vector2(c.x - w * 0.5, c.y + 64.0 * k), Vector2(w, 34.0 * k))
	UI.draw_chamfer(_top, r, 6.0 * k, Color(UI.GLASS, 0.66), Color(col, 0.55), 1)
	UI.draw_text_c(_top, _font_b, Vector2(c.x, r.position.y + 16.0 * k), name_s, fsz, col.lightened(0.25), 3)
	var f := clampf(float(_tag_bot.hp) / maxf(float(_tag_bot.hp_max), 1.0), 0.0, 1.0)
	UI.draw_seg_bar(_top, Rect2(Vector2(r.position.x + 12.0 * k, r.position.y + 23.0 * k), Vector2(w - 24.0 * k, 4.0 * k)), 10, f,
			col, maxf(1.5 * k, 1.0))


## The nearest enemy drop pod still in the air (group "war_drop_pod", is_live(); host or puppet
## pods alike); an alarm when one appears.
func _scan_pods() -> void:
	var cam := get_viewport().get_camera_3d()
	var from: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	var best: Node3D = null
	var best_d := INF
	for p in get_tree().get_nodes_in_group("war_drop_pod"):
		if not (p is Node3D) or not is_instance_valid(p) or str(p.get("team")) == "home" \
				or not p.has_method("is_live") or not p.is_live():
			continue
		var ps = p.get_script()
		if ps is Script and (ps as Script).resource_path == "res://scripts/war/supply_pod.gd":
			continue                    # (an enemy's İkmal kapsülü brings a gun, not troops: no alarm)
		var d := (p as Node3D).global_position.distance_to(from)
		if d < best_d:
			best_d = d
			best = p
	_pod = best
	if _pod != null and not _pod_was:
		_pod_t = 0.0
		if Game.sfx:
			Game.sfx.play("error", -5.0, 0.6)
		_say("DÜŞMAN ÇIKARMASI GELİYOR!  ·  %d m" % int(best_d), "war_pod", 3.0)
	_pod_was = _pod != null


# --- Drilling torpedoes (scripts/war/torpedo.gd) ----------------------------------------------------

## Sorts the burrowing torpedoes into ours / theirs (nearest the core first); an alarm when an
## enemy one starts.
func _scan_torpedoes() -> void:
	var had := _torps_enemy.size()
	_torps_enemy.clear()
	_torps_own.clear()
	for t in get_tree().get_nodes_in_group("war_torpedo"):
		if not is_instance_valid(t) or not t.has_method("is_burrowing") or not t.is_burrowing():
			continue
		if str(t.get("team")) == "home":
			_torps_own.append(t)
		else:
			_torps_enemy.append(t)
	var by_dist := func(a, b) -> bool: return float(a.core_distance()) < float(b.core_distance())
	_torps_enemy.sort_custom(by_dist)
	_torps_own.sort_custom(by_dist)
	if _torps_enemy.size() > had:
		_torp_t = 0.0
		if Game.sfx:
			Game.sfx.play("error", -6.0, 0.7)
		_say("DÜŞMAN TORPİDOSU KAZIYOR  ·  çekirdeğe %d m" % int(ceilf(float(_torps_enemy[0].core_distance()))), "war_torp", 3.0)
	# Sade: once more when the nearest is about to reach the core.
	var close: bool = not _torps_enemy.is_empty() and float(_torps_enemy[0].core_distance()) < 8.0
	if close and not _torp_close:
		_say("TORPİDO ÇEKİRDEĞE %d m!" % int(ceilf(float(_torps_enemy[0].core_distance()))), "war_torp", 3.0, true)
	_torp_close = close


## The torpedo lines under the other warnings (at most two of each side); returns the next y.
func _draw_torpedoes(cx: float, wy: float, cam: Camera3D, k: float) -> float:
	var n := 0
	var step := 36.0 * k
	for t in _torps_enemy:
		if n >= 2 or not is_instance_valid(t):
			continue
		n += 1
		var d := float(t.core_distance())
		# Blinks faster as it closes in.
		var rate := 0.35 if d < 8.0 else 0.8
		_warn(cx, wy, "DÜŞMAN TORPİDOSU KAZIYOR  ·  çekirdeğe %d m" % int(ceilf(d)), k, fmod(_torp_t, rate) < rate * 0.7 or n > 1)
		wy += step
		if cam != null:
			_torpedo_marker(cam, t.tip_position(), k)
	n = 0
	for t in _torps_own:
		if n >= 2 or not is_instance_valid(t):
			continue
		n += 1
		_info(cx, wy, "TORPİDO  ·  çekirdeğe %d m" % int(ceilf(float(t.core_distance()))), float(t.progress()), k)
		wy += step
	return wy


## An enemy torpedo underground: a red diamond with its distance when on screen, else an arrow at
## the screen edge toward it.
func _torpedo_marker(cam: Camera3D, p: Vector3, k: float) -> void:
	var vs := _top.size
	var c := vs * 0.5
	var pulse := 0.7 + 0.3 * sin(_torp_t * 9.0)
	var red := Color(UI.CRIT, 0.95 * pulse)
	var behind := cam.is_position_behind(p)
	var s := cam.unproject_position(p)
	var inside := not behind and s.x > 30.0 and s.y > 30.0 and s.x < vs.x - 30.0 and s.y < vs.y - 30.0
	var dist := cam.global_position.distance_to(p)
	if inside:
		var q := 13.0 * k
		var pts := PackedVector2Array([s + Vector2(0, -q), s + Vector2(q, 0), s + Vector2(0, q), s + Vector2(-q, 0), s + Vector2(0, -q)])
		_top.draw_polyline(pts, Color(UI.OUTLINE, 0.6), 4.0 * k, true)
		_top.draw_polyline(pts, red, 2.0 * k, true)
		_top.draw_circle(s, 2.5 * k, red)
		UI.draw_text(_top, UI.font_caps(700, 1), s + Vector2(q + 6.0 * k, 4.0 * k), "TORPİDO  %d m" % int(dist), UI.fs(11, k), red, 3)
		return
	_edge_arrow(s, behind, c, vs, red, "TORPİDO %d m" % int(dist), k)


# =================================================================================================
# The end screen
# =================================================================================================

## The combat HUD's tallies (scripts/ui/combat_hud.gd `stats`: kills, heads, structs), {} if none yet.
func _combat_stats():
	if not Game.has_meta("hit_feel"):
		return {}
	var hf = Game.get_meta("hit_feel")
	if hf == null or not is_instance_valid(hf):
		return {}
	var h = hf.get("hud")
	if h == null or not is_instance_valid(h):
		return {}
	var s = h.get("stats")
	return s if s is Dictionary else {}


## The end screen: the game pauses, the mouse is freed.
func show_end(won: bool) -> void:
	if _end != null:
		return
	Game.end_match(won)                   # Game.match_over: crosshairs, scopes, hit markers hide
	if not Net.active:
		get_tree().paused = true          # (multiplayer: the match ends for both, nothing pauses)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Its own layer above every gameplay overlay (guns' read-outs 11, hit markers 12; this HUD is 6),
	# under the chat (55) and the pause menu (60).
	var end_layer := CanvasLayer.new()
	end_layer.layer = 50
	add_child(end_layer)
	_end = Control.new()
	_end.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_end.theme = UI.make_theme()
	end_layer.add_child(_end)
	# Laid out at 1080p, scaled with the window height.
	var evs := get_viewport().get_visible_rect().size
	var ek := clampf(evs.y / 1080.0, 0.75, 2.0)
	_end.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_end.position = Vector2.ZERO
	_end.size = evs / ek
	_end.scale = Vector2(ek, ek)
	_top.queue_redraw()
	# A frosted backdrop (the pause menu's), tinted toward the outcome.
	var bg := Kit.backdrop(_end)
	var bm: ShaderMaterial = bg.material
	bm.set_shader_parameter("side_dark", 0.0)
	bm.set_shader_parameter("amount", 0.0)
	create_tween().tween_method(func(v: float) -> void: bm.set_shader_parameter("amount", v), 0.0, 1.0, 0.6)
	var tcol := UI.GOOD if won else UI.BAD
	var tint := ColorRect.new()
	tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tint.color = Color(tcol.darkened(0.75), 0.0)
	_end.add_child(tint)
	create_tween().tween_property(tint, "color:a", 0.18, 0.8)
	# The panel.
	var holder := CenterContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_end.add_child(holder)
	var pnl := UI.panel(holder, UI.panel_box(34))
	pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	var col := UI.vbox(pnl, 10)
	col.custom_minimum_size = Vector2(620, 0)
	var kick := Kit.heading(col, "MAÇ SONU  ·  %s" % _time_s, 13, UI.SCREEN_CYAN, 4)
	kick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var t := Kit.heading(col, "ZAFER" if won else "YENİLGİ", 76, tcol, 10)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_constant_override("outline_size", 8)
	t.add_theme_color_override("font_outline_color", Color(tcol.darkened(0.8), 0.6))
	var sub := UI.label(col, "Rakibin çekirdeği yok edildi" if won else "Çekirdeğimiz yok oldu", 19, UI.TEXT, 600)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Accent rule: orange in the middle.
	var rule := UI.hbox(col, 0)
	rule.alignment = BoxContainer.ALIGNMENT_CENTER
	var rl := ColorRect.new()
	rl.color = UI.SUIT_ORANGE
	rl.custom_minimum_size = Vector2(120, 2)
	rl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.add_child(rl)
	_end_stats(col)
	var gap := Control.new()
	gap.custom_minimum_size.y = 8
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)
	if Net.active:
		# Multiplayer: the host restarts both; the client waits for that or leaves.
		var first: Button
		if Net.is_server:
			first = Kit.menu_button(col, "Yeniden başla", "", "İkiniz için yeni bir maç", 620.0)
			first.pressed.connect(Net.restart_match)
		else:
			var w := UI.label(col, "Host yeniden başlatabilir…", 16, UI.DIM, 500)
			w.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var lv := Kit.menu_button(col, "Odadan ayrıl", "", "Ana menüye dön", 620.0, true)
		lv.pressed.connect(func() -> void: Net.leave(""))
		(first if first != null else lv).call_deferred("grab_focus")
	else:
		var again := Kit.menu_button(col, "Yeniden başla", "", "Yeni bir maç", 620.0)
		again.pressed.connect(_restart)
		Kit.menu_button(col, "Çık", "", "Masaüstüne dön", 620.0, true).pressed.connect(func() -> void: get_tree().quit())
		again.call_deferred("grab_focus")
	_world_line(col)
	# Entrance: the panel fades in, the title settles from a little larger.
	pnl.modulate.a = 0.0
	t.pivot_offset = Vector2(310, 44)
	t.scale = Vector2(1.18, 1.18)
	var tw := create_tween().set_parallel()
	tw.tween_property(pnl, "modulate:a", 1.0, 0.35).set_delay(0.15)
	tw.tween_property(t, "scale", Vector2.ONE, 0.6).set_delay(0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if Game.sfx:
		Game.sfx.play("craft" if won else "error", -4.0, 0.8 if won else 0.7)


## The match in numbers: a 3 × 2 grid of stat tiles and the two cores.
func _end_stats(col: Control) -> void:
	var cs = _combat_stats()
	var c: Dictionary = cs if cs is Dictionary else {}
	var kills := int(c.get("kills", 0)) - int(_kills0.get("kills", 0))
	var heads := int(c.get("heads", 0)) - int(_kills0.get("heads", 0))
	var structs := int(c.get("structs", 0)) - int(_kills0.get("structs", 0))
	var hs: Dictionary = {}
	if Game.hud != null and is_instance_valid(Game.hud) and Game.hud.get("stats") is Dictionary:
		hs = Game.hud.get("stats")
	var tiles := [["SÜRE", _time_s, UI.TEXT], ["LEŞ", str(maxi(kills, 0)), UI.SUIT_ORANGE],
			["KAFADAN", str(maxi(heads, 0)), Color(1.0, 0.85, 0.35)], ["YIKILAN YAPI", str(maxi(structs, 0)), UI.SCREEN_CYAN],
			["KAZILAN", "%d m³" % int(float(hs.get("mined", 0.0))), UI.RES_COLORS[3].lightened(0.2)],
			["ÖLÜM", str(int(hs.get("deaths", 0))), UI.DIM]]
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(grid)
	for tl in tiles:
		var p := UI.panel(grid, UI.glass_box(10.0, Color(UI.SUIT_WHITE, 0.12), 8.0, 0.55))
		p.custom_minimum_size = Vector2(200, 0)
		var v := UI.vbox(p, 0)
		Kit.heading(v, str(tl[0]), 11, UI.DIM, 2)
		var b := UI.label(v, str(tl[1]), 26, tl[2], 700)
		b.add_theme_font_override("font", UI.font_num(700))
	# The cores at the end.
	var row := UI.hbox(col, 10)
	for key in ["home", "rival"]:
		var core = war.home_core if key == "home" else war.rival_core
		var ok: bool = core != null and is_instance_valid(core)
		var hp := float(core.hp) if ok else 0.0
		var mx := maxf(float(core.hp_max), 1.0) if ok else 1.0
		var ccol := UI.HOME if key == "home" else UI.RIVAL
		var p2 := UI.panel(row, UI.glass_box(10.0, Color(ccol, 0.35), 8.0, 0.55))
		p2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v2 := UI.vbox(p2, 4)
		var h2 := UI.hbox(v2, 8)
		var lt := Kit.heading(h2, "YURT ÇEKİRDEĞİ" if key == "home" else "RAKİP ÇEKİRDEĞİ", 11, ccol.lightened(0.3), 2)
		lt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var hv := UI.label(h2, ("%d / %d" % [int(ceilf(hp)), int(mx)]) if hp > 0.0 else "YOK EDİLDİ", 13,
				UI.TEXT if hp > 0.0 else UI.CRIT, 700)
		hv.add_theme_font_override("font", UI.font_num(700))
		var bar := UI.bar(v2, ccol, 240, 6)
		bar.value = clampf(hp / mx, 0.0, 1.0)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## The end screen's small print: this match's random planets and their seed (scripts/planet/
## random_world.gd; "Yeniden başla" draws a new one in single player).
func _world_line(col: Control) -> void:
	var w: Dictionary = RandomWorld.current
	if w.is_empty():
		return
	var s := RandomWorld.names_line(Game.planet, Game.rival)
	s = ("%s   ·   tohum %d" % [s, int(w.get("seed", 0))]) if s != "" else "Tohum %d" % int(w.get("seed", 0))
	var lb := UI.label(col, s, 13, UI.DIM, 500)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _restart() -> void:
	get_tree().paused = false
	Game.reset_state()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().reload_current_scene()


# =================================================================================================
# Meteor shower (Göktaşı yağmuru, scripts/war/meteor_shower.gd; 2026-10-06)
# =================================================================================================
# Hook above (one line): _draw_top -> _mt_draw. While a shower is on its way: a blinking alert plate
# "GÖKTAŞI YAĞMURU!  ·  YURT / RAKİP  ·  NN m" (the nearest impact site) and a gold marker (corner
# brackets on screen, a chevron at the screen edge) on every impact site still to come and every
# meteor in flight; afterwards a gold plate for the nearest meteor core ("GÖKTAŞI ÇEKİRDEĞİ · NN m ·
# kalan %NN", the bar = what is left of it) and markers on the nearest METEOR_HUD_MARKERS cores.
# Reads MeteorShower.hud_state() ~8 times a second (both machines: the client's comes from the replay).

const MT_GOLD := Color(1.0, 0.72, 0.26)
const MT_SCRIPT := "res://scripts/war/meteor_shower.gd"
const MT_CLUSTER_R := 14.0      # m: impact sites / cores closer than this share one marker
# HUD level (scripts/ui/hud_level.gd): in Sade the plates and markers show only within MT_SADE_NEAR m,
# everything when an impact site is within MT_ON_YOU m of you (a meteor falling on you: also a
# critical alert with its sound, every level); a shower starting elsewhere is one short toast in Sade.
const MT_HudLevel := preload("res://scripts/ui/hud_level.gd")
const MT_SADE_NEAR := 60.0
const MT_ON_YOU := 18.0
var _mt_script = null
var _mt_state := {}
var _mt_read := -1.0
var _mt_was_alert := false
var _mt_on_you := false


func _mt_draw(cx: float, wy: float, cam: Camera3D, k: float) -> float:
	if _mt_script == null:
		_mt_script = load(MT_SCRIPT) if ResourceLoader.exists(MT_SCRIPT) else false
	if not (_mt_script is Script) or cam == null:
		return wy
	if _t - _mt_read > 0.12:
		_mt_read = _t
		_mt_state = _mt_script.call("hud_state")
	if _mt_state.is_empty():
		return wy
	var step := 36.0 * k
	var cp := cam.global_position
	var mt_sade := MT_HudLevel.shown_level() == MT_HudLevel.SADE
	var alert_on := bool(_mt_state.get("alert", false))
	if not alert_on:
		_mt_was_alert = false
		_mt_on_you = false
	if alert_on:
		var near := INF
		for p: Vector3 in _mt_state.get("sites", []):
			near = minf(near, cp.distance_to(p))
		var b = _mt_state.get("body")
		var where := "YURT" if b != null and b == Game.planet else "RAKİP"
		var on_you := near < MT_ON_YOU
		if on_you and not _mt_on_you:
			MT_HudLevel.alert("GÖKTAŞI ÜSTÜNE DÜŞÜYOR — uzaklaş!", 2, "meteor_on_you", 2.6)
		_mt_on_you = _mt_on_you or on_you
		if not _mt_was_alert and mt_sade and near >= MT_SADE_NEAR:
			MT_HudLevel.alert("Göktaşı yağmuru: %s" % ("Yurt'a düşüyor" if where == "YURT" else "Rakip gezegene düşüyor"), 1, "meteor", 3.0)
		_mt_was_alert = true
		var txt := "GÖKTAŞI YAĞMURU!  ·  %s" % where
		if near < INF:
			txt += "  ·  %d m" % int(near)
		if not mt_sade or near < MT_SADE_NEAR:
			_warn(cx, wy, txt, k, fmod(_t, 0.6) < 0.42)
			wy += step
		for g: Array in _mt_cluster(_mt_state.get("sites", []), MT_CLUSTER_R):
			if not mt_sade or on_you or cp.distance_to(g[0]) < MT_SADE_NEAR:
				_mt_marker(cam, g[0], "GÖKTAŞI" if int(g[1]) < 2 else "GÖKTAŞI ×%d" % int(g[1]), k, true)
		if not mt_sade or on_you:
			for p: Vector3 in _mt_state.get("flying", []):
				_mt_marker(cam, p, "", k, false)
	var cores: Array = (_mt_state.get("cores", []) as Array).duplicate()
	if not cores.is_empty():
		cores.sort_custom(func(x, y): return cp.distance_squared_to(x["pos"]) < cp.distance_squared_to(y["pos"]))
		var c0: Dictionary = cores[0]
		var txt2 := "GÖKTAŞI ÇEKİRDEĞİ  ·  %d m  ·  kalan %%%d" % [int(cp.distance_to(c0["pos"])), roundi(float(c0["rem"]) * 100.0)]
		var c0_near := cp.distance_to(c0["pos"]) < MT_SADE_NEAR
		if not mt_sade or c0_near:              # (Sade: the plate only near the core)
			_mt_plate(cx, wy, txt2, float(c0["rem"]), k)
			wy += step
		# Cores a few metres apart (one shower's impacts land close) share ONE marker ("ÇEKİRDEK ×3"):
		# separate markers stacked their labels on top of each other.
		var near_pts: Array = []
		for i in mini(cores.size(), Balance.METEOR_HUD_MARKERS * 2):
			near_pts.append((cores[i] as Dictionary)["pos"])
		var groups := _mt_cluster(near_pts, MT_CLUSTER_R)
		# (HUD density Sade: only the nearest, and no edge chevron: loot, not a threat)
		var sade := HudMode.mode() == HudMode.SADE and not HudMode.peek()
		for gi in mini(groups.size(), 1 if sade else Balance.METEOR_HUD_MARKERS):
			var g: Array = groups[gi]
			if sade and cp.distance_to(g[0]) >= MT_SADE_NEAR:
				continue                         # (Sade: core markers only within MT_SADE_NEAR m)
			_mt_marker(cam, g[0], "ÇEKİRDEK" if int(g[1]) < 2 else "ÇEKİRDEK ×%d" % int(g[1]), k, not sade)
	return wy


## Greedy clustering of world points within `r` m (nearest-first input keeps the nearest groups
## first): [[centroid, count], ...].
func _mt_cluster(pts: Array, r: float) -> Array:
	var groups: Array = []                 # [sum Vector3, count, first point]
	for p: Vector3 in pts:
		var placed := false
		for g: Array in groups:
			if (g[2] as Vector3).distance_to(p) < r:
				g[0] = (g[0] as Vector3) + p
				g[1] = int(g[1]) + 1
				placed = true
				break
		if not placed:
			groups.append([p, 1, p])
	var out: Array = []
	for g: Array in groups:
		out.append([(g[0] as Vector3) / float(g[1]), int(g[1])])
	return out


## A gold world marker: corner brackets + label and distance on screen (a small diamond for a meteor
## in flight), else a chevron at the screen edge (labelled ones only).
func _mt_marker(cam: Camera3D, p: Vector3, label: String, k: float, edge: bool) -> void:
	var vs := _top.size
	var behind := cam.is_position_behind(p)
	var s := cam.unproject_position(p)
	var inside := not behind and s.x > 30.0 and s.y > 30.0 and s.x < vs.x - 30.0 and s.y < vs.y - 30.0
	var dist := cam.global_position.distance_to(p)
	var col := Color(MT_GOLD, 0.95)
	if inside:
		if label == "":
			var d := 6.0 * k
			_top.draw_colored_polygon(PackedVector2Array([s + Vector2(0, -d), s + Vector2(d, 0), s + Vector2(0, d), s + Vector2(-d, 0)]), col)
			return
		var hs := 14.0 * k
		var rr := Rect2(s - Vector2(hs, hs), Vector2(hs, hs) * 2.0)
		UI.draw_corners(_top, rr.grow(1.0), 6.0 * k, Color(UI.OUTLINE, 0.6), 4.0 * k)
		UI.draw_corners(_top, rr, 6.0 * k, col, 2.0 * k)
		_top.draw_circle(s, 2.5 * k, col)
		UI.draw_text_c(_top, UI.font_caps(700, 1), s + Vector2(0, hs + 14.0 * k), "%s  %d m" % [label, int(dist)], UI.fs(11, k), col, 3)
		return
	if edge and label != "":
		_edge_arrow(s, behind, vs * 0.5, vs, col, "%s %d m" % [label, int(dist)], k)


## A gold info plate with a bar along the bottom (what is left of the core).
func _mt_plate(cx: float, y: float, txt: String, prog: float, k: float) -> void:
	if _plate_budget <= 0:
		return                                   # (HUD density: no room for another plate)
	_plate_budget -= 1
	var fsz := UI.fs(14, k)
	var tw := UI.text_w(_font_b, txt, fsz)
	var w := tw + 32.0 * k
	var h := 30.0 * k
	var r := Rect2(Vector2(cx - w * 0.5, y), Vector2(w, h))
	UI.draw_chamfer(_top, r, 7.0 * k, Color(UI.GLASS, 0.74), Color(MT_GOLD, 0.75), 1)
	_top.draw_rect(Rect2(r.position + Vector2(10.0 * k, h - 5.0 * k), Vector2((w - 20.0 * k) * clampf(prog, 0.0, 1.0), 2.0 * k)),
			Color(MT_GOLD, 0.9))
	UI.draw_text(_top, _font_b, Vector2(r.position.x + 16.0 * k, r.get_center().y + fsz * 0.3), txt, fsz, MT_GOLD.lightened(0.2), 3)
