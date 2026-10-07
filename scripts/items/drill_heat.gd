extends RefCounted
## Drill heat and the active vent (matkap ısınması, 2026-10-06; Gears of War's active reload as a
## cooling mini-game). Pure logic, no nodes: the tool (scripts/player/terrain_tool.gd) ticks it every
## physics frame and calls vent() on R; the gauges (drill side strip, wrist, quickbar) read the state.
## Numbers: Balance "Drill heat and upgrades".
##
## Heat rises while the drill works (DRILL_HEAT_RISE × power × the brush size factor, × DRILL_SUPER_HEAT
## during SÜPER KAZI) and falls DRILL_HEAT_COOL × cool per second once the drill has rested
## DRILL_HEAT_COOL_DELAY s. Past DRILL_VENT_OPEN of heat_max the vent window opens: `marker` sweeps
## 0 → 1 over `sweep` s (and again, until something happens) across a gauge with an amber zone `good`
## and a white sweet spot `sweet` inside it (gauge shares, placed per window). vent():
##   in the sweet spot  PERFECT: heat 0 and SÜPER KAZI for DRILL_SUPER_T s
##   in the zone        GOOD: heat − DRILL_VENT_GOOD_COOL × heat_max
##   elsewhere          JAM: locked DRILL_JAM_T s, heat easing to DRILL_JAM_END
##   no window          NONE (nothing happens; the tool clicks)
## Reaching heat_max: OVERHEAT, locked DRILL_OVERHEAT_T s, heat easing to DRILL_OVERHEAT_END.
## tick() returns the events of the frame (EV_*), for the sounds and the effects.

const Balance := preload("res://scripts/war/balance.gd")

enum { NONE, PERFECT, GOOD, JAM }
enum { LOCK_NONE, LOCK_JAM, LOCK_OVERHEAT }
const EV_WINDOW := "window"         # the vent window opened
const EV_SWEEP := "sweep"           # the marker wrapped round for another pass
const EV_CLOSED := "closed"         # the window closed by itself (cooled below DRILL_VENT_CLOSE)
const EV_OVERHEAT := "overheat"
const EV_UNLOCK := "unlock"         # a lockout ended
const EV_SUPER_END := "super_end"

var heat := 0.0
var heat_max := 100.0
var cool := 1.0                     # tier cooling multiplier
var sweep := 1.6                    # s per marker pass
var window := false
var marker := 0.0                   # 0..1 along the gauge
var good := Vector2(0.45, 0.79)     # amber zone (gauge shares)
var sweet := Vector2(0.55, 0.68)    # white sweet spot
var lock_kind := LOCK_NONE
var lock_t := 0.0                   # s of lockout left
var lock_total := 1.0
var super_t := 0.0                  # s of SÜPER KAZI left
var idle_t := 0.0                   # s since the drill last worked
var last_vent := NONE               # the last vent's result (for the gauges' flash)
var vent_flash := 0.0               # 1 → 0 after a vent (the gauges flash its colour)
var rng := RandomNumberGenerator.new()

var _lock_from := 0.0
var _lock_to := 0.0


func _init() -> void:
	rng.randomize()


## Applies a tier (DrillTiers.stats()): heat_max, cool, sweep. Heat keeps its share.
func configure(s: Dictionary) -> void:
	var share := frac()
	heat_max = maxf(float(s.get("heat_max", 100.0)), 1.0)
	cool = float(s.get("cool", 1.0))
	sweep = maxf(float(s.get("sweep", 1.6)), 0.3)
	heat = share * heat_max


func frac() -> float:
	return clampf(heat / maxf(heat_max, 1.0), 0.0, 1.0)


func locked() -> bool:
	return lock_kind != LOCK_NONE


func super_on() -> bool:
	return super_t > 0.0


## Heat per second working with this power (0..1) and brush radius (m).
static func rise_rate(power: float, radius: float, boosted: bool) -> float:
	var k := Balance.DRILL_HEAT_RADIUS_K
	var size_k := clampf(1.0 - k + k * radius / 2.2, 0.6, 2.6)
	return Balance.DRILL_HEAT_RISE * (0.35 + 0.65 * clampf(power, 0.0, 1.0)) * size_k \
			* (Balance.DRILL_SUPER_HEAT if boosted else 1.0)


## One physics frame. working: the drill bit into something this frame. Returns the events.
func tick(dt: float, working: bool, power := 1.0, radius := 2.2) -> Array:
	var ev: Array = []
	vent_flash = maxf(vent_flash - dt * 2.5, 0.0)
	if super_t > 0.0:
		super_t -= dt
		if super_t <= 0.0:
			super_t = 0.0
			ev.append(EV_SUPER_END)
	if locked():
		lock_t -= dt
		var k := 1.0 - clampf(lock_t / maxf(lock_total, 0.01), 0.0, 1.0)
		heat = lerpf(_lock_from, _lock_to, k * k * (3.0 - 2.0 * k))
		if lock_t <= 0.0:
			lock_t = 0.0
			lock_kind = LOCK_NONE
			heat = _lock_to
			idle_t = 0.0
			ev.append(EV_UNLOCK)
		return ev
	if working:
		idle_t = 0.0
		heat += rise_rate(power, radius, super_on()) * dt
	else:
		idle_t += dt
		if idle_t >= Balance.DRILL_HEAT_COOL_DELAY:
			heat = maxf(heat - Balance.DRILL_HEAT_COOL * cool * dt, 0.0)
	if heat >= heat_max:
		_lock(LOCK_OVERHEAT, Balance.DRILL_OVERHEAT_T, Balance.DRILL_OVERHEAT_END)
		ev.append(EV_OVERHEAT)
		return ev
	var f := frac()
	if not window and f >= Balance.DRILL_VENT_OPEN:
		_open_window()
		ev.append(EV_WINDOW)
	elif window and f < Balance.DRILL_VENT_CLOSE:
		window = false
		ev.append(EV_CLOSED)
	if window:
		marker += dt / sweep
		if marker >= 1.0:
			marker = fmod(marker, 1.0)
			ev.append(EV_SWEEP)
	return ev


## R: vents if the window is open. Returns PERFECT / GOOD / JAM, or NONE (no window, or locked).
func vent() -> int:
	if locked() or not window:
		return NONE
	window = false
	var r := JAM
	if marker >= sweet.x and marker <= sweet.y:
		r = PERFECT
		heat = 0.0
		super_t = Balance.DRILL_SUPER_T
	elif marker >= good.x and marker <= good.y:
		r = GOOD
		heat = maxf(heat - Balance.DRILL_VENT_GOOD_COOL * heat_max, 0.0)
	else:
		_lock(LOCK_JAM, Balance.DRILL_JAM_T, Balance.DRILL_JAM_END)
	last_vent = r
	vent_flash = 1.0
	return r


## Extra heat at once (the burst bore): a share of heat_max. Returns true when it overheated.
func add_heat(share: float) -> bool:
	if locked():
		return false
	heat += share * heat_max
	if heat >= heat_max:
		_lock(LOCK_OVERHEAT, Balance.DRILL_OVERHEAT_T, Balance.DRILL_OVERHEAT_END)
		return true
	return false


## The vent result where the marker is right now (what a press would give): for tests / hints.
func would_vent() -> int:
	if locked() or not window:
		return NONE
	if marker >= sweet.x and marker <= sweet.y:
		return PERFECT
	if marker >= good.x and marker <= good.y:
		return GOOD
	return JAM


func reset() -> void:
	heat = 0.0
	window = false
	marker = 0.0
	lock_kind = LOCK_NONE
	lock_t = 0.0
	super_t = 0.0
	idle_t = 0.0
	vent_flash = 0.0


func _open_window() -> void:
	window = true
	marker = 0.0
	var hz := Balance.DRILL_VENT_ZONE * 0.5
	var c := rng.randf_range(Balance.DRILL_VENT_ZONE_C.x, Balance.DRILL_VENT_ZONE_C.y)
	good = Vector2(c - hz, c + hz)
	var hs := Balance.DRILL_VENT_SWEET * 0.5
	var sc := clampf(c + rng.randf_range(-0.07, 0.07), good.x + hs + 0.02, good.y - hs - 0.02)
	sweet = Vector2(sc - hs, sc + hs)


func _lock(kind: int, t: float, end_share: float) -> void:
	lock_kind = kind
	lock_t = t
	lock_total = t
	_lock_from = heat if kind != LOCK_OVERHEAT else heat_max
	_lock_to = minf(end_share * heat_max, _lock_from)
	window = false
	super_t = 0.0
