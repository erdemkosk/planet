extends Node
## Yeniden doğuş dalgaları (2026-10-07; the user: "ölünce çok hızlı yeniden doğuluyor, bir avantaj elde
## edemiyoruz"). Child "RespawnWaves" of the RespawnShips manager (scripts/war/respawn_ship.gd), on every
## machine. Bots no longer come back one by one ~10 s after dying: each team's dead ride ONE dropship on
## that team's wave clock, so a kill buys a real window. Tunables: balance.gd "Respawn waves".
##   Clock     per team, a wave slot every RESPAWN_WAVE s (our clock runs RESPAWN_WAVE_HOME_OFS behind the
##             rival's: the two sides' waves alternate). Nobody dead: nothing flies.
##   Entry     RespawnShip.enqueue_dead(unit) -> enqueue(unit) here, the moment a unit is CONFIRMED dead:
##             today a bot's _die (rival_team.gd / ally_team.gd on_bot_died); later the downed system
##             (scripts/war/downed.gd) when the unit gives up / bleeds out / is finished. The local player
##             is not queued: his own fixed RESPAWN_TIME ride (enqueue_dead forwards him to player_died).
##             Fallback: respawn_ship.gd _bot_hold queues a dead bot nobody queued (dated to its death).
##   Seat      a bot rides the first slot >= entry + RESPAWN_WAVE_MIN (>= RESPAWN_TIME: never back before
##             the player would be). A first slot later than entry + RESPAWN_WAVE_MAX is pulled forward to
##             that (the team's clock shifts there; the units already waiting keep their earlier slots).
##             A squad wiped at once is gone for 13..30 s and comes back together.
##   Dispatch  respawn_ship.gd _poll_bots takes each due wave (take_due: RESPAWN_LEAD s before its slot)
##             and sends one ship for it (RESPAWN_SHIP_CAP seats; a bigger wave gets a second ship). The
##             bots step off from the slot on (RESPAWN_STAGGER apart). No ship (no carrier / no landing
##             spot): they appear at the base at the slot.
##   Numbers   down_weight(unit): 1 dead (riding / waiting for a wave), 0.5 downed but not confirmed yet
##             (Downed.is_downed in scripts/war/downed.gd, when that file exists; looked up lazily), else 0.
##             team_down(team) = the team's sum (cached per frame); is_team_down(team) = >= CP_DOWN_MIN:
##             control_points.gd _tick lets the enemy take that team's zones × CP_DOWN_TAKE_K and the
##             team itself capture × CP_DOWN_CAP_K.
##   Wipe      polled 4× a second (host / single player): a unit just went down (its weight rose) at P;
##             every unit of its team within WIPE_RADIUS of P is down (weight >= 0.5), at least WIPE_MIN of
##             them, one confirmed -> a priority-1 alert line (key "wave_wipe"): the side that did it
##             "RAKİP SAVUNMASIZ — bas!", the side it happened to "Savunma düştü — dalga 14 sn" (at most
##             every WIPE_GAP s per team).
##   HUD       a tiny red "DALGA 0:14" just right of the rival core plate (war_hud.gd's top cluster, at its
##             1080p geometry) while the enemy has a wave coming; nothing otherwise (the sparse HUD).
## Multiplayer: the bots are host-simulated, so the clock, the queue and the wipe check run on the host
## (and in single player). events() -> scripts/net/net_drops.gd "Respawn waves" (reliable):
##   waves_changed(home_s, rival_s)  s to each team's next wave (-1 none; host-local teams), on change
##   team_wiped(team, secs)          a wipe of `team` (host-local), secs = that team's next wave (-1 none)
## The client applies them in its own local teams: net_waves(home_s, rival_s) / net_wipe(team, secs).
## Training (Game meta "training"): no queue, no alerts, no label.
##
## API (static; null-safe without a live instance)
##   enqueue(unit, entry_ms = -1)   the entry (see above); entry_ms < 0 = now
##   down_weight(unit) -> float     team_down(team) -> float     is_team_down(team) -> bool
##   wave_left(team) -> float       s to that team's next wave (-1 none), host or client
##   units_of(team) -> Array        the units that count (the local player, bots, remote players)

const Balance := preload("res://scripts/war/balance.gd")
const UI := preload("res://scripts/ui/ui_style.gd")

const DOWNED_PATH := "res://scripts/war/downed.gd"
const POLL := 0.25
## The label: px at 1080p right of the screen centre / from the top. Just past war_hud.gd's rival core
## plate (CHIP_W / 2 + 8 + BAR_W = 368), level with its title line.
const LABEL_X := 378.0
const LABEL_Y := 16.0


class WaveEvents extends RefCounted:
	signal waves_changed(home_s: float, rival_s: float)
	signal team_wiped(team: String, secs: float)


static var _events: WaveEvents = null
static var _inst = null                  # the live instance (untyped: may be freed)
static var _downed_scr = null            # scripts/war/downed.gd once found (with a static is_downed)
static var _downed_looked := false
static var _cache_f := -1
static var _cache := {}                  # team -> weighted dead (this process frame)

var _anchor := {"home": 0, "rival": 0}   # ms: one slot of each team's clock (Time.get_ticks_msec)
var _q := {}                             # unit instance id -> {"unit": WeakRef, "team", "entry_ms", "wave_ms", "sent"}
var _poll_t := 0.0
var _last_w := {}                        # unit instance id -> down weight at the last poll (the wipe check)
var _wipe_ms := {"home": -1000000, "rival": -1000000}
var _sent := ""                          # the last waves_changed state (host)
var _net_ms := {"home": -1, "rival": -1}  # client: the host's next waves on our clock
var _layer: CanvasLayer
var _label: Label
var _label_s := -1


static func events() -> WaveEvents:
	if _events == null:
		_events = WaveEvents.new()
	return _events


static func inst():
	if _inst != null and is_instance_valid(_inst) and (_inst as Node).is_inside_tree():
		return _inst
	return null


func _ready() -> void:
	name = "RespawnWaves"
	_inst = self
	var now := Time.get_ticks_msec()
	_anchor["rival"] = now
	_anchor["home"] = now + int(Balance.RESPAWN_WAVE_HOME_OFS * 1000.0)
	_build_ui()


func _exit_tree() -> void:
	if _inst == self:
		_inst = null


## Bots think here: the host, or single player (not the Eğitim Alanı).
static func _sim() -> bool:
	return not Net.is_client() and not Game.has_meta("training")


# =================================================================================================
# Queue and clock (host / single player)
# =================================================================================================

## The entry: `unit` is confirmed dead now (entry_ms < 0) or since entry_ms (Time.get_ticks_msec).
static func enqueue(unit, entry_ms := -1) -> void:
	var m = inst()
	if m == null or unit == null or not is_instance_valid(unit) or not _sim():
		return
	m._enqueue(unit, entry_ms)


func _enqueue(unit, entry_ms: int) -> void:
	var key: int = (unit as Object).get_instance_id()
	if _q.has(key):
		return
	var team := Game.team_of(unit)
	if team != "home" and team != "rival":
		return
	var e := entry_ms if entry_ms >= 0 else Time.get_ticks_msec()
	var w := _slot(team, e + int(Balance.RESPAWN_WAVE_MIN * 1000.0))
	var cap := e + int(Balance.RESPAWN_WAVE_MAX * 1000.0)
	if w > cap:
		_anchor[team] = cap               # (the clock shifts: this slot comes forward)
		w = cap
	_q[key] = {"unit": weakref(unit), "team": team, "entry_ms": e, "wave_ms": w, "sent": false}


## The first slot of `team`'s clock at or after `t_ms`.
func _slot(team: String, t_ms: int) -> int:
	var a: int = _anchor[team]
	var p := maxi(int(Balance.RESPAWN_WAVE * 1000.0), 1000)
	var k := ceili(float(t_ms - a) / float(p))
	return a + k * p


## The waves due for a ship (RESPAWN_LEAD s or less before their slot), each handed out once:
## [{"team", "wave_ms", "units": Array}] (respawn_ship.gd _poll_bots).
func take_due(now: int) -> Array:
	var lead := int(Balance.RESPAWN_LEAD * 1000.0)
	var by := {}
	for key in _q.keys():
		var e: Dictionary = _q[key]
		if bool(e["sent"]) or int(e["wave_ms"]) - now > lead:
			continue
		var u = (e["unit"] as WeakRef).get_ref()
		if u == null:
			continue
		e["sent"] = true
		var wk := "%s:%d" % [e["team"], int(e["wave_ms"])]
		if not by.has(wk):
			by[wk] = {"team": e["team"], "wave_ms": int(e["wave_ms"]), "units": []}
		(by[wk]["units"] as Array).append(u)
	return by.values()


## The slot `unit` waits for (ms), -1 = not queued.
func wave_ms_of(unit) -> int:
	if unit == null or not is_instance_valid(unit):
		return -1
	var e = _q.get((unit as Object).get_instance_id())
	return int(e["wave_ms"]) if e is Dictionary else -1


## `unit` is back (stepped off / respawned): out of the queue.
func forget(unit) -> void:
	if unit != null and is_instance_valid(unit):
		_q.erase((unit as Object).get_instance_id())


## s to `team`'s next wave (-1 = none coming): the host's queue, or the host's word on a client.
static func wave_left(team: String) -> float:
	var m = inst()
	return float(m._left(team)) if m != null else -1.0


func _left(team: String) -> float:
	var now := Time.get_ticks_msec()
	if Net.is_client():
		var t: int = int(_net_ms.get(team, -1))
		return float(t - now) / 1000.0 if t > now else -1.0
	var best := _next_ms(team, now)
	return float(best - now) / 1000.0 if best >= 0 else -1.0


func _next_ms(team: String, now: int) -> int:
	var best := -1
	for e in _q.values():
		if e["team"] != team:
			continue
		var w: int = int(e["wave_ms"])
		if w > now and (best < 0 or w < best):
			best = w
	return best


# =================================================================================================
# Counting the dead
# =================================================================================================

## 1 confirmed dead (riding / waiting for a wave), 0.5 downed but not confirmed (scripts/war/downed.gd),
## 0 standing.
static func down_weight(unit) -> float:
	if unit == null or not is_instance_valid(unit):
		return 0.0
	var d = _downed()
	if d != null and bool(d.call("is_downed", unit)):
		return 0.5
	if (unit as Object).has_method("is_dead") and bool(unit.call("is_dead")):
		return 1.0
	return 0.0


## The downed system's script, looked up once (null while it does not exist).
static func _downed():
	if not _downed_looked:
		_downed_looked = true
		if ResourceLoader.exists(DOWNED_PATH):
			var s = load(DOWNED_PATH)
			if s is Script and (s as Script).get_script_method_list().any(func(m): return str(m.get("name", "")) == "is_downed"):
				_downed_scr = s
	return _downed_scr


## `team`'s weighted dead (sum of down_weight), cached per process frame.
static func team_down(team: String) -> float:
	var f := Engine.get_process_frames()
	if f != _cache_f:
		_cache_f = f
		_cache = {}
	if _cache.has(team):
		return float(_cache[team])
	var s := 0.0
	for u in units_of(team):
		s += down_weight(u)
	_cache[team] = s
	return s


static func is_team_down(team: String) -> bool:
	return team_down(team) >= Balance.CP_DOWN_MIN


## The units of `team` that count: the local player (home), the bots (group "war_ai", not the training
## dummies), remote players (group "net_player"), by Game.team_of.
static func units_of(team: String) -> Array:
	var out: Array = []
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return out
	var pl = Game.player
	if team == "home" and pl != null and is_instance_valid(pl) and (pl as Node).is_inside_tree():
		out.append(pl)
	for n in tree.get_nodes_in_group("war_ai"):
		if n is Node3D and not n.is_in_group("training_dummy") and Game.team_of(n) == team:
			out.append(n)
	for n in tree.get_nodes_in_group("net_player"):
		if n is Node3D and Game.team_of(n) == team:
			out.append(n)
	return out


# =================================================================================================
# Poll: queue upkeep, the wipe check, the client's state (host / single player)
# =================================================================================================

func _process(delta: float) -> void:
	_tick_label()
	_poll_t -= delta
	if _poll_t > 0.0:
		return
	_poll_t = POLL
	if not _sim():
		return
	_poll()


func _poll() -> void:
	var now := Time.get_ticks_msec()
	for key in _q.keys():
		var u = (_q[key]["unit"] as WeakRef).get_ref()
		if u == null or down_weight(u) <= 0.0:
			_q.erase(key)                 # (freed, or brought back by something else)
	if Game.match_over:
		return
	# The wipe check: units whose weight rose since the last poll.
	var w_now := {}
	var fresh: Array = []
	for team: String in ["home", "rival"]:
		for u in units_of(team):
			var id: int = (u as Object).get_instance_id()
			var w := down_weight(u)
			w_now[id] = w
			if w > 0.0 and w > float(_last_w.get(id, 0.0)):
				fresh.append([u, team])
	_last_w = w_now
	for f: Array in fresh:
		_wipe_check(f[0], str(f[1]), now)
	# The client's countdowns: on change.
	var hm := _next_ms("home", now)
	var rm := _next_ms("rival", now)
	var key := "%d|%d" % [hm, rm]
	if key != _sent:
		_sent = key
		events().waves_changed.emit(float(hm - now) / 1000.0 if hm >= 0 else -1.0,
				float(rm - now) / 1000.0 if rm >= 0 else -1.0)


func _wipe_check(u: Node3D, team: String, now: int) -> void:
	if now - int(_wipe_ms[team]) < int(Balance.WIPE_GAP * 1000.0):
		return
	var p := u.global_position
	var n := 0
	var confirmed := 0
	for v in units_of(team):
		if (v as Node3D).global_position.distance_to(p) > Balance.WIPE_RADIUS:
			continue
		var w := down_weight(v)
		if w < 0.5:
			return                         # somebody still stands there
		n += 1
		if w >= 1.0:
			confirmed += 1
	if n < Balance.WIPE_MIN or confirmed < 1:
		return
	_wipe_ms[team] = now
	var secs := _left(team)
	events().team_wiped.emit(team, secs)
	_alert_wipe(team, secs)


## The alert, from our side: `team` (local) was wiped, its next wave in `secs` (-1 none).
static func _alert_wipe(team: String, secs: float) -> void:
	var text := "RAKİP SAVUNMASIZ — bas!"
	if team == "home":
		text = ("Savunma düştü — dalga %d sn" % ceili(secs)) if secs > 0.0 else "Savunma düştü"
	if Game.hud and Game.hud.has_method("alert"):
		Game.hud.alert(text, 1, "wave_wipe", Balance.WIPE_ALERT_SECS)
	elif Game.hud and Game.hud.has_method("show_message"):
		Game.hud.show_message(text, Balance.WIPE_ALERT_SECS)


## Client: the host's countdowns, in our local teams (scripts/net/net_drops.gd).
static func net_waves(home_s: float, rival_s: float) -> void:
	var m = inst()
	if m == null:
		return
	var now := Time.get_ticks_msec()
	m._net_ms["home"] = now + int(home_s * 1000.0) if home_s >= 0.0 else -1
	m._net_ms["rival"] = now + int(rival_s * 1000.0) if rival_s >= 0.0 else -1


## Client: the host saw `team` (our local team) wiped.
static func net_wipe(team: String, secs: float) -> void:
	if inst() == null or Game.match_over:
		return
	_alert_wipe(team, secs)


# =================================================================================================
# The label: "DALGA 0:14" beside the rival core plate while their wave is coming
# =================================================================================================

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 6
	_layer.add_to_group("gameplay_overlay")       # hidden on the end screen / menus (overlay_guard.gd)
	add_child(_layer)
	_label = UI.label(_layer, "", 15, UI.RIVAL, 700)
	_label.add_theme_font_override("font", UI.font_caps(700, 2))
	_label.add_theme_constant_override("outline_size", 6)
	_label.add_theme_color_override("font_outline_color", UI.OUTLINE)
	_label.visible = false


func _tick_label() -> void:
	if _label == null:
		return
	var left := _left("rival")
	var show := left > 0.0 and not Game.has_meta("training") and not Game.overlays_hidden()
	_label.visible = show
	if not show:
		_label_s = -1
		return
	var s := ceili(left)
	var vs := get_viewport().get_visible_rect().size
	var k := UI.scale_k(vs)
	if s != _label_s:
		_label_s = s
		_label.text = "DALGA %d:%02d" % [s / 60, s % 60]
		_label.add_theme_font_size_override("font_size", UI.fs(15.0, k))
	_label.position = Vector2(vs.x * 0.5 + LABEL_X * k, LABEL_Y * k)
