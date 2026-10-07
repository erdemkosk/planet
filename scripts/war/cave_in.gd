extends Node3D
## Cave-ins ("Tünel çökertme", 2026-10-06) and the shared side of the quick entrench ("Hızlı siper";
## the player's key and slam: scripts/player/entrench.gd; bots: ai_rival.gd "Cave-ins and entrench").
## One instance, made by main.gd; tunables: balance.gd "Cave-ins and entrench" (CAVE_*, ENTRENCH_*).
##
## Weak roofs (host / single player only; a client gets the brushes through the planet's net hook and
## the look through the events below):
##   - Every dig (planet.gd brush_applied with a non-RAISE brush of at least CAVE_MIN_BRUSH_R) and every
##     Game.blast queues a roof check at that point (coalesced, one check per CAVE_ANALYSE_GAP s).
##     analyse() looks up from the point for a ceiling (or, from open air, down through a thin crust
##     into a cavity under it), measures the soil over it (roof) and the cavity's narrowest width just
##     under it (span, 4 lines through the middle) on a cached trilinear read of the density corners.
##     Roof < CAVE_ROOF_THIN and span >= CAVE_SPAN_MIN: a weak roof (a "site"), kept body-local (the
##     floating origin moves the planets, not their insides).
##   - A site's stress (0..1) builds with digging under / near it (CAVE_DIG_STRESS / s × severity;
##     without a player near the dig, i.e. bots: × CAVE_AI_DIG_K and never past CAVE_WARN), blasts
##     (CAVE_BLAST_STRESS, falling off to 0 at CAVE_BLAST_REACH × the blast radius) and bullets that
##     strike the roof (Game.shot_fired traced onto the roof: CAVE_SHOT_STRESS each, × 2 once it
##     groans). Below CAVE_WARN it drains (CAVE_DECAY / s). At CAVE_WARN it GROANS: cracking, dust
##     trickles and falling clods under the roof, faster as it goes; it creeps on (CAVE_CREEP / s) and
##     comes down at 1 after at least CAVE_WARN_MIN s. A RAISE brush near it (sealing / propping with
##     the drill's YÜKSELT) re-checks it: a roof that is no longer weak settles.
##   - The collapse: the site is re-checked, then up to 3 FLATTEN brushes CAVE_FILL_GAP s apart (the
##     middle, then along the cavity's long axis where the roof is weak too) pull everything under a
##     plane CAVE_FILL_OVER m over the old ceiling to soil and cut the crust above it away: the cavity
##     fills, the ground over it drops into a shallow sinkhole. A big dust burst, falling rocks, a
##     rumble and camera shake. Never within CAVE_STRUCT_MARGIN of a structure (a core: 8 m).
##   - Burial: after each fill brush every character whose chest is now in soil is buried: the player,
##     bots, dummies (CAVE_BURY_DMG through Game.damage_target, × 0.6 with the head free), the remote
##     player gets the damage through the same call (net_world) and buries itself from the event.
##     Standing on the crust when it drops: CAVE_DROP_DMG. A killed body gets a small pocket dug round
##     it (no corpse sealed in soil).
##   - Buried (the local player): held in place (player.gd _physics_process -> hold_player), the view
##     goes dark brown (head under) or dark at the edges (head free), the world is muffled
##     (FeelFx.muffle_hit) and you breathe hard (FeelFx.suppress). Out: hold the drill's trigger
##     (CAVE_DIG_OUT_DRILL s), melee V (CAVE_DIG_OUT_MELEE each) or tap Space (CAVE_DIG_OUT_JUMP each),
##     or on your own after CAVE_AUTO_FREE s; dig_out() carves the way up. With the head under the soil
##     you suffocate: CAVE_SUFFOCATE_DMG / s after CAVE_SUFFOCATE_DELAY s. Bots: stuck CAVE_BOT_DIG_T
##     s (suffocating), then dig out (ai_rival.gd ci_bury); dummies get dug out after the same time.
##
## Entrench: entrench(body, feet, fwd, up, team, src) queues the berm (3 RAISE brushes in a crescent
## ENTRENCH_DIST ahead, ~1.1 m high, ~2.5 m wide) and the scrape at the feet (DIG), ENTRENCH_BRUSH_GAP
## s apart, on THIS machine (a client predicts its own; the brushes sync like the drill's). Bots stand
## behind the berm as cover on their own (density line of sight).
##
## Static API:
##   CaveIn.events() -> Events        signals for the multiplayer layer (host side, world positions):
##       cave_warning(pos)            a roof groans at pos (its ceiling); again every CAVE_WARN_PING s
##                                    while it does (a client: net_warning(pos))
##       cave_collapse(pos, radius)   it came down: pos = the fill plane at its middle, radius = the
##                                    fill brush radius (a client: net_collapse(pos, radius))
##       entrenched(pos, dir)         someone raised a berm (feet, flat facing); any machine, also a
##                                    client's own (others: net_entrenched(pos, dir) = the look only)
##       buried(target, depth)        bury() / a collapse buried `target` (a remote player's avatar:
##                                    forward it; his machine calls CaveIn.bury(Game.player, depth))
##   CaveIn.bury(node, depth)         bury a character (the player / a bot / a dummy) as a collapse does:
##                                    stuck, suffocating, digs out (no hit of its own: the caller's
##                                    damage is the hit). depth = m of soil over the head (> 0: the head
##                                    is under, it suffocates; 0: the head is free; < 0: dropped into
##                                    rubble, stuck briefly, not in soil). Host for others (a remote
##                                    player: the buried event, his machine buries him); the local player
##                                    on any machine. Calling it again while buried only deepens it.
##   CaveIn.is_buried(node) -> bool
##   CaveIn.hold_player(p, delta) -> bool   player.gd _physics_process: true while buried (skip it)
##   CaveIn.entrench(body, feet, fwd, up, team := "", src = null) -> bool
##   CaveIn.analyse(body, point) -> Dictionary   the roof check (tests / debug): "unstable", "why",
##                                    and when weak "m", "ceil", "top", "roof", "span", "height", ...
##   CaveIn.dig_out(body, feet, up)   the way out of the soil (2 DIG brushes)
##   CaveIn.quake(body, centre, radius, foe, roof_thin, max_n, speed) -> int   host: the Kazıcı's
##                                    Sismik Dalga brings `foe`'s tunnels down (scripts/war/heroes)
##   CaveIn.net_warning(pos) / net_collapse(pos, radius) / net_entrenched(pos, dir)   client look

const Balance := preload("res://scripts/war/balance.gd")
const Dig := preload("res://scripts/player/dig.gd")
const TunnelLog := preload("res://scripts/war/tunnel_log.gd")   # quake(): the other side's tunnels
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # toasts: key "cave" (on / near you: 2), "cave_tip" (1)
const Bodies := preload("res://scripts/planet/bodies.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const BuildFx := preload("res://scripts/war/build_fx.gd")
const DigFx := preload("res://scripts/items/dig_fx.gd")
const FeelFx := preload("res://scripts/ui/feel_fx.gd")

const CAVE_WARN_PING := 1.0            # s between cave_warning events while a roof groans
const SOIL_FALLBACK := Color(0.42, 0.33, 0.22)
const OVERLAY_GROUP := "gameplay_overlay"   # (scripts/ui/overlay_guard.gd hides the hint in menus)
## Recorded sets (assets/audio/sonniss, snd_lib.gd): cracking roof, settling soil, dirt, rocks, rumble.
const SOUNDS := {"crack": "bimp/crack", "settle": "amb/settle", "dirt": "bimp/dirt", "dirt_heavy": "bimp/dirt_heavy",
		"rock": "bimp/rock", "debris": "expl/debris", "far": "expl/far", "thump": "feel/thump", "melee_dirt": "melee/dirt"}

const BURY_SHADER := """
shader_type canvas_item;
render_mode unshaded;
uniform float k = 0.0;        // head under the soil: the whole view
uniform float edge = 0.0;     // stuck with the head free: the edges only
uniform float t = 0.0;
uniform vec3 soil = vec3(0.16, 0.11, 0.07);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 c = UV - 0.5;
	c.x *= 1.7;
	float r = length(c);
	float vig = smoothstep(0.2, 0.95, r);
	float g = hash(floor(FRAGCOORD.xy / 3.0) + floor(t * 9.0));
	float crumb = hash(floor(FRAGCOORD.xy / 14.0));
	float a = max(k * (0.88 + 0.1 * vig), edge * vig * 0.9);
	vec3 col = soil * (0.55 + 0.35 * crumb + 0.25 * g) * (1.0 - 0.45 * vig);
	COLOR = vec4(col, clamp(a, 0.0, 0.97));
}
"""


class Events extends RefCounted:
	signal cave_warning(pos: Vector3)
	signal cave_collapse(pos: Vector3, radius: float)
	signal entrenched(pos: Vector3, dir: Vector3)
	signal buried(target: Node3D, depth: float)


## Corner-cached trilinear density reads for one roof check (planet.gd _sample per 1 m corner).
class Sampler extends RefCounted:
	var body: Node3D
	var o := Vector3.ZERO
	var cache := {}
	var fast := false

	func _init(b: Node3D) -> void:
		body = b
		o = b.global_position
		fast = b.has_method("_sample")

	func corner(v: Vector3i) -> float:
		var c = cache.get(v)
		if c == null:
			c = float(body.call("_sample", v)) if fast else float(body.density_at(o + Vector3(v)))
			cache[v] = c
		return float(c)

	func d(w: Vector3) -> float:
		var p := w - o
		var f := p.floor()
		var b := Vector3i(f)
		var t := p - f
		var x00 := lerpf(corner(b), corner(b + Vector3i(1, 0, 0)), t.x)
		var x10 := lerpf(corner(b + Vector3i(0, 1, 0)), corner(b + Vector3i(1, 1, 0)), t.x)
		var x01 := lerpf(corner(b + Vector3i(0, 0, 1)), corner(b + Vector3i(1, 0, 1)), t.x)
		var x11 := lerpf(corner(b + Vector3i(0, 1, 1)), corner(b + Vector3i(1, 1, 1)), t.x)
		return lerpf(lerpf(x00, x10, t.y), lerpf(x01, x11, t.y), t.z)

	## The first point from `a` along unit `dir` within `dist` m that is soil (want_solid) / air:
	## marched `step` m at a time, the crossing bisected. Vector3.INF: none.
	func march(a: Vector3, dir: Vector3, dist: float, step: float, want_solid: bool) -> Vector3:
		var t := 0.0
		var prev := 0.0
		while t < dist:
			t = minf(t + step, dist)
			if (d(a + dir * t) < 0.0) == want_solid:
				var lo := prev
				var hi := t
				for i in 4:
					var m := (lo + hi) * 0.5
					if (d(a + dir * m) < 0.0) == want_solid:
						hi = m
					else:
						lo = m
				return a + dir * hi
			prev = t
		return Vector3.INF


static var _events: Events
static var _inst: Node3D
static var stat_checks := 0              # roof checks run (tests / debug)
static var stat_collapses := 0

var _hooked := {}                        # planet instance id -> true (brush_applied connected)
var _hook_t := 0.0
var _queue: Array = []                   # roof checks: {body, lp, blast, player, check}
var _check_t := 0.0
var _sites: Array = []                   # weak roofs (see _new_site)
var _brushes: Array = []                 # timed brushes: {body, lp, r, mode, amount, pp, pn, at, kind, team, site}
var _self_brush := false                 # our own brushes are not digs
var _remote_warn: Array = []             # client: [world pos, until ms]
var _remote_checks: Array = []           # client: [world pos, radius, at ms]
var _others: Array = []                  # buried dummies etc.: {node, until, tick, full, body}
var _bots: Array = []                    # buried bots (ai_rival ci_bury): cleared when they die
var _seal_tip := false
var _hit_ms := {}                        # instance id -> ms of its last cave-in hit
var _rng := RandomNumberGenerator.new()
# The local player buried.
var _pl_on := false
var _pl_full := false
var _pl_rubble := false                  # dropped with a crust: stuck, but not in soil
var _pl_t := 0.0
var _pl_k := 0.0
var _pl_tick := 0.0
var _pl_breath := 0.0
var _pl_vis := 0.0
var _pl_edge := 0.0
var _pl_drill := false
# Nodes.
var _audio: Array = []
var _audio_i := 0
var _streams := {}
var _clods: Array = []
var _clod_i := 0
var _trickles: Array = []
var _trickle_i := 0
var _cloud: CPUParticles3D
var _layer: CanvasLayer
var _rect: ColorRect
var _mat: ShaderMaterial
var _hint: Label
var _bar_bg: ColorRect
var _bar: ColorRect


static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


func _init() -> void:
	name = "CaveIn"


func _ready() -> void:
	_inst = self
	top_level = true
	global_transform = Transform3D.IDENTITY
	_rng.randomize()
	if not Game.blast.is_connected(_on_blast):
		Game.blast.connect(_on_blast)
	if not Game.shot_fired.is_connected(_on_shot):
		Game.shot_fired.connect(_on_shot)
	for i in 8:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 10.0
		p.max_distance = 140.0
		add_child(p)
		_audio.append(p)
	for n: String in SOUNDS:
		var st: AudioStream = Snd.rand(str(SOUNDS[n]), 1.06, 1.5)
		if st != null:
			_streams[n] = st
	_build_fx()
	_build_overlay()
	_hook_planets()


func _exit_tree() -> void:
	if _inst == self:
		_inst = null
	if _pl_on:
		_pl_release()


# =================================================================================================
# Static API
# =================================================================================================

static func _live() -> Node3D:
	return _inst if _inst != null and is_instance_valid(_inst) and _inst.is_inside_tree() else null


## player.gd _physics_process: while buried the body stays where the soil holds it.
static func hold_player(p, _delta: float) -> bool:
	var me := _live()
	if me == null or not me._pl_on or p != Game.player:
		return false
	p.velocity = Vector3.ZERO
	p.set("_last_vel", Vector3.ZERO)         # (no "shove" ragdoll from the stale velocity on release)
	return true


## Buries a character as a collapse does (see the header). depth: m of soil over the head (<= 0: the
## head is free).
static func bury(node: Node3D, depth: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node.has_method("is_dead") and node.is_dead():
		return
	var me := _live()
	var full := depth > 0.0
	var span: Vector2 = Balance.CAVE_BOT_DIG_T
	var dur := randf_range(span.x, span.y) * (1.0 if full else (0.6 if depth == 0.0 else 0.4)) + clampf(depth, 0.0, 3.0) * 0.5
	if node == Game.player:
		if me != null:
			me._pl_bury(full, depth < 0.0)
	elif node.is_in_group("net_player"):
		pass                                 # (his own machine buries him: the event below)
	elif Net.is_client():
		return
	elif node.has_method("ci_bury"):
		node.ci_bury(dur, full)
		if me != null and not me._bots.has(node):
			me._bots.append(node)
	elif me != null:
		for e in me._others:
			if e["node"] == node:
				return
		me._others.append({"node": node, "until": Time.get_ticks_msec() + int(dur * 1000.0),
				"tick": Time.get_ticks_msec() + int(Balance.CAVE_SUFFOCATE_DELAY * 1000.0), "full": full,
				"soil": depth >= 0.0, "body": Game.dominant_body(node.global_position)})
	events().buried.emit(node, depth)


static func is_buried(node: Node3D) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var me := _live()
	if node == Game.player:
		return me != null and me._pl_on
	if node.has_method("ci_buried"):
		return bool(node.ci_buried())
	if me != null:
		for e in me._others:
			if e["node"] == node:
				return true
	return false


## The way out of the soil from feet (2 DIG brushes: a pocket round the body, a shaft over the head).
## Any machine (a client's own: predicted like the drill).
static func dig_out(body: Node3D, feet: Vector3, up: Vector3) -> void:
	if body == null or not is_instance_valid(body) or not body.has_method("apply_brush"):
		return
	var me := _live()
	if me != null:
		me._self_brush = true
	Dig.dig_at(body, feet + up * 1.0, 1.45, Dig.MODE_DIG, 6.0)
	Dig.dig_at(body, feet + up * 2.3, 1.25, Dig.MODE_DIG, 5.0)
	if me != null:
		me._self_brush = false
		var soil := _soil_of(body)
		BuildFx.dust(me, feet + up * 1.2, up, 1.2, soil)
		me._play("dirt_heavy", feet + up * 1.0, -4.0, 0.95)


## The quick entrench (see the header). feet: on the ground; fwd: the facing (flattened here); up: the
## planet's up there. False when there is no ground ahead to raise a berm on.
static func entrench(body: Node3D, feet: Vector3, fwd: Vector3, up: Vector3, team := "", _src = null) -> bool:
	if body == null or not is_instance_valid(body) or not body.has_method("apply_brush"):
		return false
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-4:
		return false
	fwd = fwd.normalized()
	var right := fwd.cross(up).normalized()
	var plan: Array = []
	var hits := 0
	for s in [0.0, -Balance.ENTRENCH_HALF_W, Balance.ENTRENCH_HALF_W]:
		var k := float(s) / Balance.ENTRENCH_HALF_W
		var p := feet + fwd * (Balance.ENTRENCH_DIST - Balance.ENTRENCH_CURL * k * k) + right * float(s)
		var h: Dictionary = body.raycast_density(p + up * 1.6, p - up * 2.2, 0.25, false)
		var g := p
		if not h.is_empty() and float(h["distance"]) > 0.01:
			g = h["position"]
			hits += 1
		plan.append({"r": Balance.ENTRENCH_R, "mode": Dig.MODE_RAISE, "amount": Balance.ENTRENCH_AMOUNT,
				"p": g + up * Balance.ENTRENCH_LIFT, "kind": "berm"})
	if hits == 0:
		return false
	plan.append({"r": Balance.ENTRENCH_SCRAPE_R, "mode": Dig.MODE_DIG, "amount": Balance.ENTRENCH_SCRAPE_AMOUNT,
			"p": feet - up * 0.05, "kind": "scrape"})
	var me := _live()
	for i in plan.size():
		var b: Dictionary = plan[i]
		if me != null:
			me._queue_brush(body, b["p"], float(b["r"]), int(b["mode"]), float(b["amount"]), Vector3.ZERO, up,
					Balance.ENTRENCH_BRUSH_GAP * i, str(b["kind"]), "")
		else:
			Dig.dig_at(body, b["p"], float(b["r"]), int(b["mode"]), float(b["amount"]))
	if me != null:
		me._entrench_look(body, feet, fwd, up)
	events().entrenched.emit(feet, fwd)
	return true


## Client: a remote roof groans at pos (keeps the look alive ~1.6 s per call).
static func net_warning(pos: Vector3) -> void:
	var me := _live()
	if me == null:
		return
	for e in me._remote_warn:
		if (e[0] as Vector3).distance_to(pos) < 1.5:
			e[1] = Time.get_ticks_msec() + 1600
			return
	me._remote_warn.append([pos, Time.get_ticks_msec() + 1600])
	me._warn_start_look(pos, Game.dominant_body(pos))


## Client: a roof came down (the look; the soil arrives through the terrain sync, then the local player
## is buried if his chest ends up in it).
static func net_collapse(pos: Vector3, radius: float) -> void:
	var me := _live()
	if me == null:
		return
	var body := Game.dominant_body(pos)
	me._collapse_look(pos, body.up_at(pos) if body != null else Vector3.UP, radius, body)
	var now := Time.get_ticks_msec()
	for dt in [250, 550, 950, 1500]:
		me._remote_checks.append([pos, radius, now + int(dt)])
	me._remote_warn = me._remote_warn.filter(func(e): return (e[0] as Vector3).distance_to(pos) > radius + 2.0)


## Another machine's berm: the dust and the thump (its brushes come through the terrain sync).
static func net_entrenched(pos: Vector3, dir: Vector3) -> void:
	var me := _live()
	if me == null:
		return
	var body := Game.dominant_body(pos)
	if body == null:
		return
	me._entrench_look(body, pos, dir, body.up_at(pos))


# =================================================================================================
# The roof check
# =================================================================================================

## Is there a weak roof over (or under the crust below) world point p? See the header.
static func analyse(body: Node3D, p: Vector3, roof_thin := -1.0, span_min := -1.0) -> Dictionary:
	var out := {"unstable": false, "why": ""}
	if body == null or not is_instance_valid(body) or not body.has_method("density_at"):
		out["why"] = "no body"
		return out
	stat_checks += 1
	var s := Sampler.new(body)
	var up: Vector3 = body.up_at(p)
	if s.d(p) < 0.0:
		var moved := false
		for k in [0.4, 0.8, -0.4, 1.2, -0.8]:
			if s.d(p + up * float(k)) >= 0.0:
				p += up * float(k)
				moved = true
				break
		if not moved:
			out["why"] = "in soil"
			return out
	var cb := s.march(p, up, Balance.CAVE_CEIL_PROBE, 0.1, true)          # (fine: a crust can be 0.2 m)
	if cb == Vector3.INF:
		# Open sky: a thin crust under p with a cavity below it (a blast or a man on the roof)?
		var g := s.march(p, -up, 3.0, 0.1, true)
		if g == Vector3.INF:
			out["why"] = "open"
			return out
		var under := s.march(g, -up, Balance.CAVE_ROOF_THIN + 0.4, 0.1, false)
		if under == Vector3.INF:
			out["why"] = "solid ground"
			return out
		cb = s.march(under - up * 0.35, up, 0.8, 0.1, true)
		if cb == Vector3.INF:
			out["why"] = "crust lost"
			return out
	var lv := cb - up * Balance.CAVE_SPAN_DEPTH
	if s.d(lv) < 0.0:
		lv = cb - up * 0.3
		if s.d(lv) < 0.0:
			out["why"] = "slot"
			return out
	var x := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	var z := up.cross(x).normalized()
	var span := INF
	var span_dir := x
	var span_off := 0.0
	var long := -1.0
	var long_dir := x
	var long_a := 0.0
	var long_b := 0.0
	for k in 4:
		var a := float(k) * PI * 0.25
		var dir := (x * cos(a) + z * sin(a)).normalized()
		var dp := _wall(s, lv, dir)
		var dn := _wall(s, lv, -dir)
		if dp + dn < span:
			span = dp + dn
			span_dir = dir
			span_off = (dp - dn) * 0.5
		if dp + dn > long:
			long = dp + dn
			long_dir = dir
			long_a = dp
			long_b = dn
	out["span"] = span
	if span < (span_min if span_min > 0.0 else Balance.CAVE_SPAN_MIN):
		out["why"] = "narrow"
		return out
	var m := lv + span_dir * span_off
	if s.d(m) < 0.0:
		m = lv
	var cbm := s.march(m, up, Balance.CAVE_SPAN_DEPTH + 1.5, 0.1, true)
	if cbm == Vector3.INF:
		# The middle of the span is open (a sub-voxel crust vanishes between the 1 m corners): the
		# column we came up has one, and a roof that thin is failing anyway.
		m = lv
		cbm = cb
	var top := s.march(cbm, up, _rt(roof_thin) + 0.25, 0.08, false)
	if top == Vector3.INF:
		out["why"] = "thick roof"
		return out
	var roof := (top - cbm).dot(up)
	out["roof"] = roof
	if roof > _rt(roof_thin):
		out["why"] = "thick roof"
		return out
	var fl := s.march(m, -up, Balance.CAVE_FLOOR_PROBE, 0.3, true)
	var height := (cbm - fl).dot(up) if fl != Vector3.INF else Balance.CAVE_FLOOR_PROBE + (cbm - m).dot(up)
	var over := (minf(span, 12.0) - Balance.CAVE_SPAN_MIN) / Balance.CAVE_SPAN_MIN
	var thin := clampf((Balance.CAVE_ROOF_THIN - roof) / Balance.CAVE_ROOF_THIN, 0.0, 1.0)
	out["unstable"] = true
	out["m"] = m
	out["ceil"] = cbm
	out["top"] = top
	out["height"] = height
	out["up"] = up
	out["long_dir"] = long_dir
	out["long_a"] = long_a
	out["long_b"] = long_b
	out["sev"] = clampf(0.6 + over + 0.6 * thin, 0.6, 2.0)
	return out


## analyse()'s roof limit: CAVE_ROOF_THIN, or the caller's (the Kazıcı's quake brings thicker ones down).
static func _rt(roof_thin: float) -> float:
	return roof_thin if roof_thin > 0.0 else Balance.CAVE_ROOF_THIN


## Sismik Dalga (scripts/war/heroes/ult_quake.gd; host / single player): `foe`'s tunnels and dugouts
## (scripts/war/tunnel_log.gd) within `radius` m of `centre` whose roof is at most `roof_thin` m thick
## (and at least `span_min` m wide: drilled tunnels too) come down as a wave running out at `speed` m/s: the usual collapse
## (fill brushes, burial, sinkhole, look, cave_collapse events). Up to max_n of them; known weak roofs
## within the radius (any side's) start to groan at once. Returns the collapses queued.
static func quake(body: Node3D, centre: Vector3, radius: float, foe: String, roof_thin := 3.0, max_n := 6,
		speed := 30.0, span_min := 1.6) -> int:
	var me := _live()
	if me == null or Net.is_client() or body == null or not is_instance_valid(body):
		return 0
	for st in me._sites:
		if st["body"] == body and (body.global_position + (st["lp"] as Vector3)).distance_to(centre) < radius:
			me._stress(st, 1.0, false)
	var cands: Array = []
	for e in TunnelLog.points(body, foe):
		var d := (e["p"] as Vector3).distance_to(centre)
		if d < radius:
			cands.append([d, e["p"]])
	cands.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var picked: Array = []
	var n := 0
	var tries := 0
	for c in cands:
		if n >= max_n or tries >= max_n * 3:
			break
		var p: Vector3 = c[1]
		var near := false
		for q in picked:
			if (q as Vector3).distance_to(p) < 4.0:
				near = true
				break
		if near:
			continue
		picked.append(p)
		tries += 1
		var res := analyse(body, p, roof_thin, span_min)
		if not bool(res["unstable"]):
			continue
		var site: Dictionary = me._site_from(body, res)
		if site.is_empty():
			continue
		n += 1
		me.get_tree().create_timer(float(c[0]) / maxf(speed, 1.0) + 0.1).timeout.connect(func():
			if is_instance_valid(me) and me.is_inside_tree() and is_instance_valid(body):
				me._collapse(site, roof_thin, span_min))
	return n


## m from p along dir (tangent) to the cavity wall, capped at CAVE_SPAN_PROBE.
static func _wall(s: Sampler, p: Vector3, dir: Vector3) -> float:
	var w := s.march(p, dir, Balance.CAVE_SPAN_PROBE, 0.4, true)
	return Balance.CAVE_SPAN_PROBE if w == Vector3.INF else p.distance_to(w)


# =================================================================================================
# Events (host)
# =================================================================================================

func _hook_planets() -> void:
	for b in Bodies.all():
		if b == null or not is_instance_valid(b) or not b.has_signal("brush_applied"):
			continue
		var id: int = b.get_instance_id()
		if _hooked.has(id):
			continue
		_hooked[id] = true
		b.brush_applied.connect(_on_brush.bind(b))


func _on_brush(center: Vector3, radius: float, body: Node3D) -> void:
	if _self_brush or Net.is_client() or radius < Balance.CAVE_MIN_BRUSH_R:
		return
	# planet.gd remembers every non-RAISE brush in _recent_brush with the edit's time: a dig / flatten.
	var rb = body.get("_recent_brush")
	var dig: bool = rb is Array and not (rb as Array).is_empty() \
			and int((rb as Array).back()[2]) == int(body.get("_last_edit_usec"))
	var lp := center - body.global_position
	var near_pl := _player_near(center, 7.0)
	var now := Time.get_ticks_msec()
	for st in _sites:
		if st["body"] != body:
			continue
		var d := lp.distance_to(st["lp"])
		if d > float(st["r"]) + radius + Balance.CAVE_STRESS_R:
			continue
		if not dig:
			_enqueue(body, st["lp"] - (st["up"] as Vector3) * 0.4, 0.0, false, true)
			continue
		var dt := clampf(float(now - int(st["dig_ms"])) * 0.001, 0.0, 0.25)
		st["dig_ms"] = now
		var add := Balance.CAVE_DIG_STRESS * float(st["sev"]) * dt
		_stress(st, add if near_pl else add * Balance.CAVE_AI_DIG_K, not near_pl)
	if dig:
		_enqueue(body, lp, 0.0, near_pl, false)


func _on_blast(pos: Vector3, radius: float, _team: String) -> void:
	if Net.is_client():
		return
	var body := Game.dominant_body(pos)
	if body == null or not body.has_method("density_at"):
		return
	var lp := pos - body.global_position
	for st in _sites:
		if st["body"] != body:
			continue
		var reach := maxf(radius, 1.0) * Balance.CAVE_BLAST_REACH + float(st["r"])
		var d := lp.distance_to(st["lp"])
		if d < reach:
			_stress(st, Balance.CAVE_BLAST_STRESS * float(st["sev"]) * (1.0 - d / reach), false)
	_enqueue(body, lp, maxf(radius, 1.0), true, false)


func _on_shot(from: Vector3, dir: Vector3, _team: String) -> void:
	if _sites.is_empty() or Net.is_client():
		return
	for st in _sites:
		var body: Node3D = st["body"]
		if body == null or not is_instance_valid(body):
			continue
		var w: Vector3 = body.global_position + (st["lp"] as Vector3)
		var t := (w - from).dot(dir)
		if t < 0.0 or t > 250.0:
			continue
		var r := float(st["r"])
		if (from + dir * t).distance_to(w) > r + 1.5:
			continue
		var now := Time.get_ticks_msec()
		if now - int(st["shot_ms"]) < 60:
			continue
		st["shot_ms"] = now
		var h: Dictionary = body.raycast_density(from, from + dir * (t + r + 3.0), 0.5, true)
		if h.is_empty():
			continue
		var hp: Vector3 = h["position"]
		var top: Vector3 = body.global_position + (st["top_lp"] as Vector3)
		if hp.distance_to(w) < r * 1.1 or hp.distance_to(top) < r * 1.1:
			_stress(st, Balance.CAVE_SHOT_STRESS * (2.0 if bool(st["warn"]) else 1.0), false)


func _enqueue(body: Node3D, lp: Vector3, blast: float, from_player: bool, check: bool) -> void:
	for e in _queue:
		if e["body"] == body and (e["lp"] as Vector3).distance_to(lp) < 1.6:
			e["blast"] = maxf(float(e["blast"]), blast)
			e["player"] = bool(e["player"]) or from_player
			e["check"] = bool(e["check"]) and check
			return
	if _queue.size() >= 12:
		_queue.pop_front()
	_queue.append({"body": body, "lp": lp, "blast": blast, "player": from_player, "check": check})


func _player_near(p: Vector3, r: float) -> bool:
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and (pl as Node3D).global_position.distance_to(p) < r:
		return true
	for n in get_tree().get_nodes_in_group("net_player"):
		if n is Node3D and (n as Node3D).global_position.distance_to(p) < r:
			return true
	return false


# =================================================================================================
# Sites
# =================================================================================================

func _process(delta: float) -> void:
	_hook_t -= delta
	if _hook_t <= 0.0:
		_hook_t = 1.0
		_hook_planets()
	_step_brushes()
	if not Net.is_client():
		_check_t -= delta
		if _check_t <= 0.0 and not _queue.is_empty():
			_check_t = Balance.CAVE_ANALYSE_GAP
			_run_check(_queue.pop_front())
		_step_sites(delta)
		_step_others()
	else:
		_step_remote()
	_step_player(delta)


func _run_check(e: Dictionary) -> void:
	var body: Node3D = e["body"]
	if body == null or not is_instance_valid(body):
		return
	var lp: Vector3 = e["lp"]
	var res := analyse(body, body.global_position + lp)
	var hit := -1
	for i in _sites.size():
		var st: Dictionary = _sites[i]
		if st["body"] == body and (st["lp"] as Vector3).distance_to(lp) < float(st["r"]) + 0.5:
			hit = i
			break
	if not bool(res["unstable"]):
		if bool(e["check"]) and hit >= 0:
			var st2: Dictionary = _sites[hit]
			_sites.remove_at(hit)
			_play("settle", body.global_position + (st2["lp"] as Vector3), -10.0, 1.0)
		return
	var site := _site_from(body, res)
	if site.is_empty():
		return
	for st in _sites:
		if st["body"] == body and (st["lp"] as Vector3).distance_to(site["lp"]) < maxf(float(st["r"]), 2.5):
			for k in ["lp", "top_lp", "plane_lp", "up", "roof", "span", "height", "sev", "r", "r_fill", "fills"]:
				st[k] = site[k]
			return
	if bool(e["check"]):
		return
	var blast := float(e["blast"])
	if blast > 0.0:
		var d := (lp - (site["lp"] as Vector3)).length()
		var reach := blast * Balance.CAVE_BLAST_REACH + float(site["r"])
		site["stress"] = Balance.CAVE_BLAST_STRESS * float(site["sev"]) * clampf(1.0 - d / reach, 0.0, 1.0)
	elif bool(e["player"]):
		site["stress"] = Balance.CAVE_DIG_STRESS * float(site["sev"]) * 0.25
	if _sites.size() >= Balance.CAVE_MAX_SITES:
		var calm := 0
		for i in _sites.size():
			if float(_sites[i]["stress"]) < float(_sites[calm]["stress"]):
				calm = i
		_sites.remove_at(calm)
	_sites.append(site)
	if float(site["stress"]) >= Balance.CAVE_WARN:
		_start_warning(site)


## A site from a weak-roof analysis: body-local points, the fill brushes planned, {} near structures.
func _site_from(body: Node3D, res: Dictionary) -> Dictionary:
	var o := body.global_position
	var up: Vector3 = res["up"]
	var ceil_p: Vector3 = res["ceil"]
	var span := float(res["span"])
	var height := float(res["height"])
	var r_fill := clampf(maxf(span * 0.5, height * 0.8) / 0.72 + 0.3, Balance.CAVE_FILL_R_MIN, Balance.CAVE_FILL_R_MAX)
	var plane := ceil_p + up * Balance.CAVE_FILL_OVER
	var m: Vector3 = res["m"]
	var mid := plane - up * minf(height * 0.3, 1.0)
	mid += (m - mid) - up * (m - mid).dot(up)        # (under the middle of the span)
	var fills: Array = [mid - o]
	var ld: Vector3 = res["long_dir"]
	var s := Sampler.new(body)
	for side in [[ld, float(res["long_a"])], [-ld, float(res["long_b"])]]:
		var dir: Vector3 = side[0]
		var ext: float = side[1]
		if ext < r_fill * 0.85:
			continue
		var q := m + dir * minf(ext - 0.5, r_fill * 1.1)
		var c := s.march(q, up, Balance.CAVE_SPAN_DEPTH + 1.5, 0.25, true)
		if c == Vector3.INF:
			continue
		if s.march(c, up, Balance.CAVE_ROOF_THIN + 0.2, 0.2, false) == Vector3.INF:
			continue                             # (a thick roof there holds)
		fills.append(mid + dir * minf(ext - 0.5, r_fill * 1.1) - o)
	# Never under / onto a structure or near a core.
	var tree := get_tree()
	for n in tree.get_nodes_in_group("war_structure"):
		if n is Node3D and is_instance_valid(n):
			var fr := float(n.get_meta("footprint_r", 1.5))
			for f in fills:
				if (n as Node3D).global_position.distance_to(o + (f as Vector3)) < r_fill + fr + Balance.CAVE_STRUCT_MARGIN:
					return {}
	for n in tree.get_nodes_in_group("war_core"):
		if n is Node3D and (n as Node3D).global_position.distance_to(ceil_p) < 8.0 + r_fill:
			return {}
	return {"body": body, "lp": ceil_p - o, "top_lp": (res["top"] as Vector3) - o, "plane_lp": plane - o, "up": up,
			"roof": float(res["roof"]), "span": span, "height": height, "sev": float(res["sev"]),
			"r": maxf(span * 0.5, 2.0), "r_fill": r_fill, "fills": fills, "stress": 0.0, "warn": false,
			"warn_t": 0.0, "ping": 0.0, "fx": 0.0, "dig_ms": Time.get_ticks_msec(), "shot_ms": 0,
			"idle": 0.0, "hinted": false}


## Adds stress; ai = from bots' digging (never past CAVE_WARN on its own).
func _stress(st: Dictionary, add: float, ai: bool) -> void:
	if add <= 0.0:
		return
	var s := float(st["stress"])
	if ai:
		if s < Balance.CAVE_WARN - 0.05:
			s = minf(s + add, Balance.CAVE_WARN - 0.05)
	else:
		s += add
	st["stress"] = s
	st["idle"] = 0.0
	if s >= Balance.CAVE_WARN and not bool(st["warn"]):
		_start_warning(st)


func _start_warning(st: Dictionary) -> void:
	st["warn"] = true
	st["warn_t"] = 0.0
	st["ping"] = CAVE_WARN_PING
	var body: Node3D = st["body"]
	var w: Vector3 = body.global_position + (st["lp"] as Vector3)
	_warn_start_look(w, body)
	events().cave_warning.emit(w)
	# Readable: the player near it hears it and is told.
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and (pl as Node3D).global_position.distance_to(w) < float(st["r"]) + 8.0:
		if Game.hud:
			HudLevel.alert("Tavan çatırdıyor — çökebilir!", 2, "cave", 2.2)
		if not _seal_tip:
			_seal_tip = true
			get_tree().create_timer(2.4).timeout.connect(func():
				if Game.hud and is_instance_valid(Game.hud):
					HudLevel.alert("İpucu: Matkapla YÜKSELT (sağ tık) tüneli kapatır, tavanı destekler.", 1, "cave_tip", 3.0))


func _step_sites(delta: float) -> void:
	var i := 0
	while i < _sites.size():
		var st: Dictionary = _sites[i]
		var body: Node3D = st["body"]
		if body == null or not is_instance_valid(body):
			_sites.remove_at(i)
			continue
		if not bool(st["warn"]):
			st["stress"] = maxf(float(st["stress"]) - Balance.CAVE_DECAY * delta, 0.0)
			st["idle"] = float(st["idle"]) + delta
			if float(st["stress"]) <= 0.0 and float(st["idle"]) > 45.0:
				_sites.remove_at(i)
				continue
			i += 1
			continue
		st["warn_t"] = float(st["warn_t"]) + delta
		st["stress"] = float(st["stress"]) + Balance.CAVE_CREEP * delta
		var w: Vector3 = body.global_position + (st["lp"] as Vector3)
		var k := clampf((float(st["stress"]) - Balance.CAVE_WARN) / (1.0 - Balance.CAVE_WARN), 0.0, 1.0)
		st["fx"] = float(st["fx"]) - delta
		if float(st["fx"]) <= 0.0:
			st["fx"] = lerpf(0.75, 0.22, k) * _rng.randf_range(0.7, 1.3)
			_warn_tick_look(w, st["up"], float(st["r"]), k, body)
		st["ping"] = float(st["ping"]) - delta
		if float(st["ping"]) <= 0.0:
			st["ping"] = CAVE_WARN_PING
			events().cave_warning.emit(w)
		if float(st["stress"]) >= 1.0 and float(st["warn_t"]) >= Balance.CAVE_WARN_MIN:
			_sites.remove_at(i)
			_collapse(st)
			continue
		i += 1


## The roof comes down (host): re-checked, then the fill brushes, the burial and the look.
func _collapse(st: Dictionary, roof_thin := -1.0, span_min := -1.0) -> void:
	var body: Node3D = st["body"]
	var o := body.global_position
	var up: Vector3 = st["up"]
	var res := analyse(body, o + (st["lp"] as Vector3) - up * 0.4, roof_thin, span_min)
	if not bool(res["unstable"]):
		_play("settle", o + (st["lp"] as Vector3), -8.0, 0.9)
		return
	var fresh := _site_from(body, res)
	if fresh.is_empty():
		return
	st = fresh
	stat_collapses += 1
	var plane_w: Vector3 = o + (st["plane_lp"] as Vector3)
	var r_fill := float(st["r_fill"])
	# Who stands on the crust (drops with it).
	var on_crust: Array = []
	var roof := float(st["roof"])
	for n in _targets(body):
		var f: Vector3 = (n as Node3D).global_position
		var hh := (f - plane_w).dot(up)
		var lat := f - plane_w - up * hh
		if hh > -0.3 and hh < roof + 0.8 and lat.length() < r_fill * 0.65:
			on_crust.append(n)
	var fills: Array = st["fills"]
	for i in fills.size():
		_queue_brush(body, o + (fills[i] as Vector3), r_fill, Dig.MODE_FLATTEN, Balance.CAVE_FILL_AMOUNT, plane_w, up,
				Balance.CAVE_FILL_GAP * i, "fill", "", {"crust": on_crust if i == 0 else [], "r": r_fill})
	_collapse_look(plane_w, up, r_fill, body)
	events().cave_collapse.emit(plane_w, r_fill)


## Every character that can be buried on `body`: the player, remote players, bots, dummies.
func _targets(body: Node3D) -> Array:
	var out: Array = []
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and not pl.is_dead() and pl.vehicle == null:
		out.append(pl)
	for n in get_tree().get_nodes_in_group(Game.DAMAGEABLE):
		if n == pl or not (n is Node3D) or not (n.is_in_group("war_ai") or n.has_method("ci_bury")):
			continue                             # (characters only: bots, allies, dummies)
		if n.has_method("is_dead") and n.is_dead():
			continue
		if n.has_method("is_aboard") and n.is_aboard():
			continue
		if Game.dominant_body((n as Node3D).global_position) != body:
			continue
		out.append(n)
	for n in get_tree().get_nodes_in_group("net_player"):
		if n is Node3D and not out.has(n) and not (n.has_method("is_dead") and n.is_dead()):
			out.append(n)
	return out


## After a fill brush: whoever's chest is now in soil is buried (the head too: fully); whoever stood
## on the crust drops with it into the rubble (stuck, head free) a moment later.
func _bury_pass(body: Node3D, center: Vector3, r: float, crust: Array) -> void:
	var s := Sampler.new(body)
	var up: Vector3 = body.up_at(center)
	var now := Time.get_ticks_msec()
	for n in _targets(body):
		var nd := n as Node3D
		var f := nd.global_position
		if f.distance_to(center) > r + 2.5:
			continue
		var id := nd.get_instance_id()
		if is_buried(nd) or now - int(_hit_ms.get(id, -100000)) < 2500:
			continue                             # (one hit per collapse, also for remote players)
		var chest := s.d(f + up * 1.0) < 0.0
		if not chest:
			if crust.has(n):
				_hit_ms[id] = now
				_hurt(n, Balance.CAVE_DROP_DMG, f + up * 3.0)
				get_tree().create_timer(Balance.CAVE_DROP_DELAY).timeout.connect(_rubble.bind(nd))
			continue
		_hit_ms[id] = now
		var full := s.d(f + up * 1.6) < 0.0
		var r2 := _hurt(n, Balance.CAVE_BURY_DMG * (1.0 if full else 0.6), f + up * 3.0)
		if bool(r2.get("killed", false)) or (n.has_method("is_dead") and n.is_dead()):
			_queue_brush(body, f + up * 0.9, 1.3, Dig.MODE_DIG, 6.0, Vector3.ZERO, up, 0.15, "pocket", "")
			continue
		bury(nd, 0.6 if full else 0.0)
	if _hit_ms.size() > 64:
		for k in _hit_ms.keys():
			if now - int(_hit_ms[k]) > 5000:
				_hit_ms.erase(k)


## Dropped with the crust: stuck in the rubble (not in soil) for a moment.
func _rubble(n: Node3D) -> void:
	if n != null and is_instance_valid(n) and not (n.has_method("is_dead") and n.is_dead()):
		bury(n, -1.0)


func _hurt(n: Node, amount: float, from: Vector3) -> Dictionary:
	if n == Game.player and Net.is_client():
		return n.take_damage(amount, from, Vector3.ZERO)       # (a claim to the host)
	return Game.damage_target(n, amount, from, Vector3.ZERO, "")


# =================================================================================================
# Timed brushes (entrench, fills, pockets)
# =================================================================================================

func _queue_brush(body: Node3D, p: Vector3, r: float, mode: int, amount: float, pp: Vector3, pn: Vector3,
		delay: float, kind: String, team: String, extra := {}) -> void:
	var o := body.global_position
	_brushes.append({"body": body, "lp": p - o, "r": r, "mode": mode, "amount": amount, "pp": pp - o, "pn": pn,
			"at": Time.get_ticks_msec() + int(delay * 1000.0), "kind": kind, "team": team, "extra": extra})


func _step_brushes() -> void:
	if _brushes.is_empty():
		return
	var now := Time.get_ticks_msec()
	var n := 0
	var i := 0
	while i < _brushes.size() and n < 2:
		var b: Dictionary = _brushes[i]
		if int(b["at"]) > now:
			i += 1
			continue
		_brushes.remove_at(i)
		var body: Node3D = b["body"]
		if body == null or not is_instance_valid(body):
			continue
		n += 1
		var o := body.global_position
		var p: Vector3 = o + (b["lp"] as Vector3)
		var up: Vector3 = b["pn"]
		_self_brush = true
		Dig.dig_at(body, p, float(b["r"]), int(b["mode"]), float(b["amount"]), o + (b["pp"] as Vector3), up, -1.0, str(b["team"]))
		_self_brush = false
		var soil := _soil_of(body)
		match str(b["kind"]):
			"berm":
				BuildFx.dust(self, p - up * Balance.ENTRENCH_LIFT, up, 1.0, soil)
				_play("dirt", p, -3.0, 0.9)
			"scrape":
				_play("dirt", p, -9.0, 1.1)
			"fill":
				var ex: Dictionary = b["extra"]
				_play("dirt_heavy", p, 2.0, 0.8)
				_play("rock", p, -2.0, 0.85)
				BuildFx.dust(self, o + (b["pp"] as Vector3), up, float(ex.get("r", 3.0)), soil)
				if not Net.is_client():
					_bury_pass(body, p, float(ex.get("r", 3.0)), ex.get("crust", []))


# =================================================================================================
# Buried: the local player, dummies, bots (host bookkeeping)
# =================================================================================================

func _pl_bury(full: bool, rubble := false) -> void:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.vehicle != null or pl.is_ragdolled():
		return
	if _pl_on:
		_pl_full = _pl_full or full
		_pl_rubble = _pl_rubble and rubble
		return
	_pl_on = true
	_pl_full = full
	_pl_rubble = rubble
	_pl_t = 0.0
	_pl_k = 0.0
	_pl_tick = Balance.CAVE_SUFFOCATE_DELAY
	_pl_breath = 0.0
	pl.velocity = Vector3.ZERO
	if pl.hand_action != null:
		pl.hand_action.cancel()
	if pl.has_method("add_trauma"):
		pl.add_trauma(0.6)
	_play2d("thump", -2.0, 0.8)
	_play2d("dirt_heavy", 0.0, 0.85)
	if Game.hud:
		HudLevel.alert("Toprak altında kaldın!" if full else ("Göçükle birlikte düştün!" if rubble else "Toprağa saplandın!"), 2, "cave", 2.0,
				false)                         # (its own thump / dirt sounds)


func _pl_release() -> void:
	_pl_on = false
	_pl_full = false
	_pl_rubble = false
	_pl_k = 0.0


## The local player gets out: the way up is dug, a small pop upward.
func _pl_free() -> void:
	var pl = Game.player
	var rubble := _pl_rubble
	_pl_release()
	if pl == null or not is_instance_valid(pl):
		return
	var up: Vector3 = pl.global_transform.basis.y
	if not rubble:
		dig_out(Game.dominant_body(pl.global_position), pl.global_position, up)
	pl.velocity = up * 3.0
	_play2d("dirt_heavy", -2.0, 1.05)
	if Game.hud:
		HudLevel.alert("Kurtuldun!", 1, "cave", 1.2)


func _step_player(delta: float) -> void:
	var tv := 0.0
	var te := 0.0
	if _pl_on:
		var pl = Game.player
		if pl == null or not is_instance_valid(pl) or pl.is_dead() or pl.vehicle != null or pl.is_ragdolled():
			_pl_release()
		else:
			_pl_t += delta
			var body := Game.dominant_body(pl.global_position)
			var up: Vector3 = pl.global_transform.basis.y
			var f: Vector3 = pl.global_position
			# Dug out from outside (or by the drill's own beam): free at once. (Rubble: no soil to check.)
			if not _pl_rubble and body != null and float(body.density_at(f + up * 1.0)) >= 0.0 \
					and float(body.density_at(f + up * 1.6)) >= 0.0:
				_pl_release()
				pl.velocity = up * 1.5
			else:
				var gain := delta / (Balance.CAVE_AUTO_FREE * (1.0 if _pl_full else (0.5 if not _pl_rubble else 0.25)))
				var cap := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not Game.ui_panel_open()
				var drill: bool = cap and pl.current() == pl.tool \
						and (Input.is_action_pressed("tool_use") or Input.is_action_pressed("tool_alt"))
				if drill:
					gain += delta / Balance.CAVE_DIG_OUT_DRILL
				if drill and not _pl_drill:
					_play2d("dirt", -8.0, 1.0)
				_pl_drill = drill
				if cap and Input.is_action_just_pressed("melee"):
					gain += Balance.CAVE_DIG_OUT_MELEE
					_play2d("melee_dirt", -4.0, 0.9)
				if cap and Input.is_action_just_pressed("jump"):
					gain += Balance.CAVE_DIG_OUT_JUMP * (1.0 if _pl_full else 1.8)
					_play2d("dirt", -10.0, 1.15)
					if pl.has_method("add_trauma"):
						pl.add_trauma(0.08)
				_pl_k += gain
				FeelFx.inst().muffle_hit(0.95 if _pl_full else 0.6)
				_pl_breath -= delta
				if _pl_breath <= 0.0:
					_pl_breath = 0.5
					FeelFx.inst().suppress(0.12 if _pl_full else 0.06)
				if _pl_full:
					_pl_tick -= delta
					if _pl_tick <= 0.0:
						_pl_tick = 1.0
						if body != null and pl.hp <= Balance.CAVE_SUFFOCATE_DMG and not Game.has_meta("training_god"):
							dig_out(body, f, up)             # (no corpse sealed in the soil)
							_pl_release()
						_hurt(pl, Balance.CAVE_SUFFOCATE_DMG, f + up * 3.0)
				if _pl_on and _pl_k >= 1.0:
					_pl_free()
		tv = 1.0 if _pl_full else 0.0
		te = 1.0
	_pl_vis = move_toward(_pl_vis, tv if _pl_on else 0.0, delta * (5.0 if _pl_on else 2.5))
	_pl_edge = move_toward(_pl_edge, te if _pl_on else 0.0, delta * (5.0 if _pl_on else 2.5))
	var vis_on := _pl_vis > 0.001 or _pl_edge > 0.001
	_layer.visible = vis_on
	if vis_on:
		_mat.set_shader_parameter("k", _pl_vis)
		_mat.set_shader_parameter("edge", _pl_edge)
		_mat.set_shader_parameter("t", float(Time.get_ticks_msec()) * 0.001)
	_hint.visible = _pl_on
	_bar_bg.visible = _pl_on
	if _pl_on:
		_hint.text = ("TOPRAĞIN ALTINDASIN" if _pl_full else "TOPRAĞA SAPLANDIN") \
				+ "\nKurtul: [Boşluk] çırpın · [V] vur · Matkapla kaz"
		_bar.size.x = _bar_bg.size.x * clampf(_pl_k, 0.0, 1.0)


func _step_others() -> void:
	if not _bots.is_empty():
		for b in _bots.duplicate():
			if not is_instance_valid(b) or not b.ci_buried():
				_bots.erase(b)
			elif b.is_dead():
				b.ci_clear()
				_bots.erase(b)
	if _others.is_empty():
		return
	var now := Time.get_ticks_msec()
	var i := 0
	while i < _others.size():
		var e: Dictionary = _others[i]
		var n = e["node"]
		if not is_instance_valid(n) or (n.has_method("is_dead") and n.is_dead()):
			_others.remove_at(i)
			continue
		var nd := n as Node3D
		var up: Vector3 = nd.global_transform.basis.y
		if bool(e["full"]) and now >= int(e["tick"]):
			e["tick"] = now + 1000
			_hurt(n, Balance.CAVE_SUFFOCATE_DMG, nd.global_position + up * 3.0)
		if now >= int(e["until"]):
			_others.remove_at(i)
			if bool(e["soil"]):
				var body: Node3D = e["body"] if e["body"] != null and is_instance_valid(e["body"]) else Game.dominant_body(nd.global_position)
				dig_out(body, nd.global_position, up)
			continue
		i += 1


func _step_remote() -> void:
	var now := Time.get_ticks_msec()
	if not _remote_warn.is_empty():
		var keep: Array = []
		for e in _remote_warn:
			if int(e[1]) < now:
				continue
			keep.append(e)
			var body := Game.dominant_body(e[0])
			if _rng.randf() < get_process_delta_time() * 2.2 and body != null:
				_warn_tick_look(e[0], body.up_at(e[0]), 2.5, 0.5, body)
		_remote_warn = keep
	if _remote_checks.is_empty():
		return
	var pl = Game.player
	var keep2: Array = []
	for c in _remote_checks:
		if int(c[2]) > now:
			keep2.append(c)
			continue
		if pl == null or not is_instance_valid(pl) or _pl_on:
			continue
		var f: Vector3 = pl.global_position
		if f.distance_to(c[0]) > float(c[1]) + 2.5:
			continue
		var body := Game.dominant_body(f)
		var up: Vector3 = pl.global_transform.basis.y
		if body != null and float(body.density_at(f + up * 1.0)) < 0.0:
			_pl_bury(float(body.density_at(f + up * 1.6)) < 0.0)
	_remote_checks = keep2


# =================================================================================================
# The look (every machine)
# =================================================================================================

static func _soil_of(body) -> Color:
	if body != null and is_instance_valid(body) and body.get("soil_color") is Color:
		return body.get("soil_color")
	return SOIL_FALLBACK


func _build_fx() -> void:
	var soft := DigFx.soft_texture()
	var dust_q := QuadMesh.new()
	dust_q.size = Vector2(0.22, 0.22)
	var dm := StandardMaterial3D.new()
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.vertex_color_use_as_albedo = true
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.albedo_texture = soft
	dust_q.material = dm
	for i in 4:
		var p := CPUParticles3D.new()
		p.one_shot = true
		p.emitting = false
		p.local_coords = false
		p.amount = 28
		p.lifetime = 1.3
		p.explosiveness = 0.15
		p.mesh = dust_q
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		p.emission_sphere_radius = 0.18
		p.spread = 8.0
		p.initial_velocity_min = 0.2
		p.initial_velocity_max = 0.6
		p.scale_amount_min = 0.6
		p.scale_amount_max = 1.6
		var g := Gradient.new()
		g.set_color(0, Color(0.5, 0.42, 0.32, 0.7))
		g.set_color(1, Color(0.5, 0.42, 0.32, 0.0))
		p.color_ramp = g
		add_child(p)
		_trickles.append(p)
	var box := BoxMesh.new()
	box.size = Vector3(0.11, 0.08, 0.1)
	var cm := StandardMaterial3D.new()
	cm.vertex_color_use_as_albedo = true
	cm.roughness = 1.0
	box.material = cm
	for i in 4:
		var c := CPUParticles3D.new()
		c.one_shot = true
		c.emitting = false
		c.local_coords = false
		c.amount = 12
		c.lifetime = 1.5
		c.explosiveness = 0.6
		c.mesh = box
		c.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		c.emission_sphere_radius = 0.4
		c.spread = 25.0
		c.initial_velocity_min = 0.0
		c.initial_velocity_max = 0.8
		c.angular_velocity_min = -360.0
		c.angular_velocity_max = 360.0
		c.scale_amount_min = 0.6
		c.scale_amount_max = 1.8
		add_child(c)
		_clods.append(c)
	var big := QuadMesh.new()
	big.size = Vector2(2.4, 2.4)
	big.material = dm
	_cloud = CPUParticles3D.new()
	_cloud.one_shot = true
	_cloud.emitting = false
	_cloud.local_coords = false
	_cloud.amount = 48
	_cloud.lifetime = 3.6
	_cloud.explosiveness = 0.85
	_cloud.mesh = big
	_cloud.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_cloud.spread = 80.0
	_cloud.initial_velocity_min = 1.0
	_cloud.initial_velocity_max = 4.5
	_cloud.damping_min = 1.2
	_cloud.damping_max = 2.4
	_cloud.scale_amount_min = 0.8
	_cloud.scale_amount_max = 2.6
	var cg := Gradient.new()
	cg.set_color(0, Color(0.5, 0.42, 0.32, 0.6))
	cg.set_color(1, Color(0.5, 0.42, 0.32, 0.0))
	_cloud.color_ramp = cg
	add_child(_cloud)


func _build_overlay() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 3
	_layer.visible = false
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = BURY_SHADER
	_mat.shader = sh
	_rect.material = _mat
	_layer.add_child(_rect)
	var top := CanvasLayer.new()
	top.layer = 6
	top.add_to_group(OVERLAY_GROUP)
	add_child(top)
	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.offset_top = -170.0
	_hint.offset_bottom = -110.0
	_hint.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_color_override("font_color", Color(1.0, 0.86, 0.62))
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_hint.add_theme_constant_override("outline_size", 6)
	_hint.visible = false
	top.add_child(_hint)
	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(0, 0, 0, 0.55)
	_bar_bg.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bar_bg.offset_left = -130.0
	_bar_bg.offset_right = 130.0
	_bar_bg.offset_top = -100.0
	_bar_bg.offset_bottom = -92.0
	_bar_bg.visible = false
	top.add_child(_bar_bg)
	_bar = ColorRect.new()
	_bar.color = Color(1.0, 0.7, 0.3, 0.95)
	_bar.position = Vector2.ZERO
	_bar.size = Vector2(0.0, 8.0)
	_bar_bg.add_child(_bar)


func _play(n: String, at: Vector3, db: float, pitch: float, unit := 10.0) -> void:
	var st: AudioStream = _streams.get(n)
	if st == null or _audio.is_empty():
		return
	var p: AudioStreamPlayer3D = _audio[_audio_i]
	_audio_i = (_audio_i + 1) % _audio.size()
	p.stream = st
	p.unit_size = unit
	p.max_distance = maxf(140.0, unit * 12.0)
	p.volume_db = db
	p.pitch_scale = pitch
	p.global_position = at
	p.play()


func _play2d(n: String, db: float, pitch: float) -> void:
	if Game.sfx == null:
		return
	var st: AudioStream = _streams.get(n)
	if st == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = st
	p.volume_db = db
	p.pitch_scale = pitch
	p.bus = "Master"
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


func _trickle(at: Vector3, up: Vector3, col: Color, n: int) -> void:
	var p: CPUParticles3D = _trickles[_trickle_i]
	_trickle_i = (_trickle_i + 1) % _trickles.size()
	p.global_position = at
	p.direction = -up
	p.gravity = -up * 6.0
	p.amount = n
	var g := p.color_ramp
	g.set_color(0, Color(col.r * 1.15, col.g * 1.15, col.b * 1.15, 0.75))
	g.set_color(1, Color(col.r, col.g, col.b, 0.0))
	p.restart()
	p.emitting = true


func _clod(at: Vector3, up: Vector3, col: Color, n: int, spread: float) -> void:
	var c: CPUParticles3D = _clods[_clod_i]
	_clod_i = (_clod_i + 1) % _clods.size()
	c.global_position = at
	c.direction = -up
	c.gravity = -up * 8.0
	c.amount = n
	c.emission_sphere_radius = spread
	c.color = col.darkened(0.15)
	c.restart()
	c.emitting = true


## The start of a groan: a sharp crack, a puff from the roof.
func _warn_start_look(w: Vector3, body) -> void:
	var up: Vector3 = body.up_at(w) if body != null else Vector3.UP
	var soil := _soil_of(body)
	_play("crack", w, 0.0, 0.8)
	_play("settle", w, -2.0, 0.85)
	_trickle(w - up * 0.15, up, soil, 28)
	_clod(w - up * 0.2, up, soil, 6, 0.5)


## One beat of a groaning roof: a crack or settle somewhere under it, dust and clods; k 0..1 = how close.
func _warn_tick_look(w: Vector3, up: Vector3, r: float, k: float, body) -> void:
	var soil := _soil_of(body)
	var x := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	var z := up.cross(x)
	var a := _rng.randf() * TAU
	var p := w + (x * cos(a) + z * sin(a)) * _rng.randf_range(0.0, r * 0.65) - up * 0.15
	if _rng.randf() < 0.55:
		_play("crack", p, lerpf(-8.0, 0.0, k), _rng.randf_range(0.75, 1.0))
	else:
		_play("settle", p, lerpf(-6.0, 1.0, k), _rng.randf_range(0.8, 1.0))
	_trickle(p, up, soil, int(lerpf(14.0, 34.0, k)))
	if _rng.randf() < 0.35 + 0.5 * k:
		_clod(p, up, soil, int(lerpf(3.0, 9.0, k)), 0.3 + 0.4 * k)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var d := (pl as Node3D).global_position.distance_to(w)
		if d < r + 4.0:
			pl.add_trauma(0.04 + 0.08 * k)


## The collapse: rumble, rocks falling through the dust, a burst out of the sinkhole, camera shake.
func _collapse_look(plane_w: Vector3, up: Vector3, r: float, body) -> void:
	var soil := _soil_of(body)
	_play("far", plane_w, 6.0, 0.6, 22.0)
	_play("debris", plane_w, 3.0, 0.8, 16.0)
	_play("dirt_heavy", plane_w - up * 1.0, 3.0, 0.75, 14.0)
	_cloud.global_position = plane_w + up * 0.5
	_cloud.direction = up
	_cloud.gravity = -up * 0.6
	_cloud.emission_sphere_radius = maxf(r * 0.6, 1.0)
	var cg := _cloud.color_ramp
	cg.set_color(0, Color(soil.r * 1.2, soil.g * 1.2, soil.b * 1.2, 0.6))
	cg.set_color(1, Color(soil.r, soil.g, soil.b, 0.0))
	_cloud.restart()
	_cloud.emitting = true
	BuildFx.dust(self, plane_w - up * 1.2, up, r, soil)
	BuildFx.shockwave(self, plane_w, up, r * 1.6, soil)
	for i in 3:
		_clod(plane_w - up * 0.2, up, soil, 12, r * 0.5)
	var pl = Game.player
	if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
		var d := (pl as Node3D).global_position.distance_to(plane_w)
		var k := clampf(1.0 - d / (r * 6.0 + 10.0), 0.0, 1.0)
		if k > 0.0:
			pl.add_trauma(0.25 + 0.75 * k * k)
		if d < r * 3.0 + 6.0:
			_play2d("thump", lerpf(-12.0, 0.0, k), 0.7)


func _entrench_look(body: Node3D, feet: Vector3, fwd: Vector3, up: Vector3) -> void:
	var soil := _soil_of(body)
	var p := feet + fwd * Balance.ENTRENCH_DIST
	_play("thump", feet + up * 0.3, -6.0, 1.1, 6.0)
	_play("dirt_heavy", p, -2.0, 1.0)
	BuildFx.dust(self, p, up, 1.4, soil)
