extends RefCounted
## Shared feel of the player's guns: rifle.gd and every weapon_base.gd gun (shotgun, sniper and the
## launchers), so they all kick, move and hit the same way.
##   Recoil     a learnable pattern: every shot of a string kicks up a little more (climb) and
##              sideways along the gun's horizontal table, plus a little noise; the string resets
##              after a short pause. The camera recovers on a spring after a short hold.
##   Motion     view-model inertia on top of the gun's own pose: strafing cant, forward / back
##              lean, a landing dip spring, and the crouch / slide cant.
##   body_hit() the one place a bullet or pellet hits a damageable: head zone (a sphere around
##              the helmet of `target.astronaut`), damage multiplier, a lethal shot launches the
##              ragdoll along the bullet, a directional hit-reaction pose, suit / metal impact
##              effects, visor crack, HitFeel markers and the kill feed.
##   stance_*   accuracy / recoil modifiers from the shooter's stance (crouch, slide), shared.
## Handling on top of this (wall pull-back, inspect on Y, aim foley, the melee pose) lives in
## scripts/items/handling.gd; the melee itself (V) in scripts/player/melee.gd.

const HitFeel := preload("res://scripts/items/hit_feel.gd")

## Helmet sphere in head-bone space (astronaut_parts.gd _helmet: centre ~0.15 m above the bone).
const HELMET_OFF := Vector3(0.0, 0.15, -0.01)
const HELMET_R := 0.2

## 2026-10-06 tok (the user: "vuruşlar ... çok daha tok olsun"): heavier recoil on every gun that kicks
## through weapon_base.gd (the rifle carries the same in its AMMO table): the camera kick × KICK_K, the
## visible gun kick × GUN_KICK_K (harder, still short: the spring is unchanged), the snap part recovers
## at × SNAP_RECOVER_K and the view climb (Climb) eases in over ~95 ms (was ~70), holds a little longer
## and comes back at CLIMB_RECOVER /s (was 6): slower, smoother.
const KICK_K := 1.15
const GUN_KICK_K := 1.2
const SNAP_RECOVER_K := 0.75
const CLIMB_RECOVER := 4.5


# =================================================================================================
# Recoil pattern
# =================================================================================================

class Recoil extends RefCounted:
	const STRING_GAP := 0.32          # s without a shot ends the string (the pattern restarts)
	var n := 0                        # shots in the current string
	var since := 9.0                  # s since the last shot

	func tick(delta: float) -> void:
		since += delta

	## Camera kick of the next shot: x = pitch up, y = yaw (rad). `climb`: extra pitch per shot of a
	## string (0.35 = the 6th shot kicks 35 % harder); `pattern`: horizontal kick per shot index in
	## units of `yaw` (the gun's learnable drift), repeated; `first`: the first round's pitch × (the
	## MW-like snap of a fresh string, then a steadier climb).
	func next(pitch: float, yaw: float, climb: float, pattern: PackedFloat32Array, first := 1.0) -> Vector2:
		if since > STRING_GAP:
			n = 0
		since = 0.0
		var i := n
		n += 1
		var up := pitch * (1.0 + climb * minf(float(i), 6.0) / 6.0) * randf_range(0.93, 1.07)
		if i == 0:
			up *= first
		var h := 0.0
		if pattern.size() > 0:
			h = pattern[i % pattern.size()]
		return Vector2(up, yaw * (h + randf_range(-0.3, 0.3)))


## The view climb you fight (2026-10-05, the user: "geri tepmeyi iyi hissedelim, seri atışta"; MW
## 2019 as the bar). Most of each round's camera kick (the gun's recoil_view share, the rest stays a
## snap on the gun's _recoil spring) turns the player's VIEW itself (player.gd add_view_kick), eased
## in over ~70 ms: a full-auto string climbs step by step and the player pulls down against it. The
## mouse pull eats the climb first (`unrec` only keeps what the player has NOT brought back), so once
## the string ends (no round for `hold` s) only that rest recovers, `back` of it, smoothly at
## `recover` /s: a controlled spray stays on target, an uncontrolled one settles most of the way back.
## Rifle full auto (9/s, ADS, nothing fitted): ~0.9° a round after a ~1.2° first snap, ~27° over a
## 30-round magazine if not pulled down (the probe in the attachment report).
class Climb extends RefCounted:
	var hold := 0.16                  # s after the last round before the recovery starts (tok: 0.12 -> 0.16)
	var recover := CLIMB_RECOVER      # recovery rate (1/s) (tok: 6 -> 4.5)
	var back := 0.88                  # share of the uncompensated climb that recovers
	var ease := 24.0                  # kick ease-in rate (1/s; 90 % in ~95 ms) (tok: 32 -> 24)
	var pending := Vector2.ZERO       # kick still to ease into the view (pitch, yaw rad)
	var unrec := Vector2.ZERO         # applied, neither recovered nor pulled back
	var since := 9.0
	var _cut := true

	## A round's view kick (x pitch up, y yaw left, rad).
	func shot(k: Vector2) -> void:
		pending += k
		since = 0.0
		_cut = false

	func reset() -> void:
		pending = Vector2.ZERO
		unrec = Vector2.ZERO
		since = 9.0
		_cut = true

	## One frame: the view rotation to add now (pitch, yaw rad). look: the player's own mouse look
	## this frame (pitch, yaw rad; player.gd look_frame).
	func step(delta: float, look: Vector2) -> Vector2:
		since += delta
		if unrec.x > 0.0 and look.x < 0.0:
			unrec.x = maxf(unrec.x + look.x, 0.0)
		if unrec.y * look.y < 0.0:
			unrec.y = 0.0 if absf(look.y) >= absf(unrec.y) else unrec.y + look.y
		var e := pending * (1.0 - exp(-ease * delta))
		if pending.length_squared() < 1e-12:
			e = pending
		pending -= e
		unrec += e
		var out := e
		if since > hold:
			if not _cut:
				_cut = true
				unrec *= back
			var r := unrec * (1.0 - exp(-recover * delta))
			unrec -= r
			out -= r
		return out

	## Per frame from the gun's _process: steps and turns the player's view (nothing while `on` is
	## false: put away, in a vehicle, ragdolled; the rest is dropped).
	func update(p, delta: float, on: bool) -> void:
		if not on or p == null or not p.has_method("add_view_kick"):
			if pending != Vector2.ZERO or unrec != Vector2.ZERO:
				reset()
			return
		var lf = p.get("look_frame")
		var v := step(delta, lf if lf is Vector2 else Vector2.ZERO)
		if v.length_squared() > 1e-14:
			p.add_view_kick(v)


# =================================================================================================
# View-model motion inertia
# =================================================================================================

class Motion extends RefCounted:
	var strafe := 0.0
	var surge := 0.0
	var land := 0.0
	var land_v := 0.0
	var was_ground := true
	var v_up_prev := 0.0
	var slide := 0.0
	var crouch := 0.0

	## Extra pose (camera space, applied about the grip) from the player's movement. aim 0..1 damps it.
	func update(p, dt: float, aim: float) -> Transform3D:
		if p == null:
			return Transform3D()
		var b: Basis = p.global_transform.basis
		var lv: Vector3 = b.inverse() * (p.velocity as Vector3)
		var r := 1.0 - exp(-7.0 * dt)
		strafe = lerpf(strafe, clampf(lv.x / 6.0, -1.3, 1.3), r)
		surge = lerpf(surge, clampf(-lv.z / 6.5, -1.0, 1.5), r * 0.8)
		var g: bool = p.is_on_floor()
		if g and not was_ground:
			land_v -= clampf(-v_up_prev / 9.0, 0.12, 1.0) * 2.4
		was_ground = g
		v_up_prev = lv.y
		land_v += (-land * 170.0 - land_v * 15.0) * dt
		land += land_v * dt
		slide = lerpf(slide, float(p.get("slide_k")) if p.get("slide_k") != null else 0.0, r)
		crouch = lerpf(crouch, float(p.get("crouch_k")) if p.get("crouch_k") != null else 0.0, r)
		var k := 1.0 - aim * 0.8
		# Crouched: a little lower and canted in; sliding: dropped and canted hard (the slide is part of
		# crouch_k, so its cant comes on top).
		var off := Vector3(-strafe * 0.014 * k - slide * 0.02 * k,
				land * 0.03 - slide * 0.035 * k - crouch * 0.011 * k, surge * 0.01 * k)
		var rot := Vector3(land * 0.07 - surge * 0.012 * k + slide * 0.06 * k, slide * 0.08 * k,
				-strafe * 0.06 * k + slide * 0.26 * k + crouch * 0.035 * k)
		return Transform3D(Basis.from_euler(rot), off)


## Applies a Motion transform to a camera-space gun pose, rotating about the grip.
static func apply_motion(pose: Transform3D, m: Transform3D) -> Transform3D:
	return Transform3D(m.basis * pose.basis, pose.origin + m.origin)


# =================================================================================================
# Carry: sprint pose and gait sway, walk bob, breathing, look sway, jump / fall lift
# =================================================================================================
## Every held item moves the same way (weapon_base.gd, rifle.gd, the view model's drill / build
## tool), on the body's gait clock (astronaut._phase: the left foot plants at 0, the right at 0.5;
## player.gd footsteps and head bob use it too), so gun, steps and view keep one rhythm.
##   Sprint  both hands stay on the item; it swings into the item's carry pose (SPRINT_STYLE) on a
##           spring (~0.22 s in, a touch quicker out), and rides the stride: a bounce per step, a
##           lateral swing and roll per stride (toward the planted foot), scaled by the style and by
##           the real speed. As the run ends a short raise (a spring kicked up into the ready, a
##           little overshoot) brings it back to fire (the guns keep firing blocked for
##           sprint_to_fire).
##   Walk    a figure-eight tied to the steps (dip per step, sway and cant per stride), amplitudes
##           tuned for the 4 steps/s of WALK 5.0 m/s; nearly gone when aiming.
##   Idle    breathing: a slow rise, pitch and roll, fading as the walk starts.
##   Look    the item lags turns on a soft spring that overshoots ~12 % and settles (MW-like).
##   Air     vertical speed lifts / drops it (the landing impact dip is Motion's).

## Carry poses at a full run (camera space, grip at the origin; euler YXZ: x muzzle up, y muzzle left,
## z the top canted left) and the gait sway of each (vertical bounce, lateral swing, roll).
##   rifle     low ready across the chest, muzzle down-left, canted inward
##   sniper    the same, heavier and lower
##   smg       compact, tucked closer
##   hug       the pusher's emitter pulled in against the chest, nose up-left
##   shoulder  launchers: the tube shouldered and tipped up, swinging little sideways
##   tool      drill / build tool carried low in both hands, nozzle down-left
const SPRINT_STYLE := {
	"rifle": {"pos": Vector3(0.115, -0.25, -0.355), "rot": Vector3(-0.44, 0.8, 0.62), "sway": Vector3(1.0, 1.0, 1.0)},
	"sniper": {"pos": Vector3(0.11, -0.265, -0.35), "rot": Vector3(-0.5, 0.74, 0.58), "sway": Vector3(0.9, 0.85, 0.85)},
	"smg": {"pos": Vector3(0.1, -0.235, -0.32), "rot": Vector3(-0.38, 0.72, 0.55), "sway": Vector3(1.05, 1.1, 1.1)},
	"hug": {"pos": Vector3(0.07, -0.25, -0.29), "rot": Vector3(0.12, 0.85, 0.5), "sway": Vector3(0.85, 0.8, 0.7)},
	"shoulder": {"pos": Vector3(0.23, -0.27, -0.26), "rot": Vector3(0.5, -0.14, -0.32), "sway": Vector3(1.2, 0.45, 0.35)},
	"tool": {"pos": Vector3(0.0, -0.075, 0.05), "rot": Vector3(-0.55, 0.45, 0.35), "sway": Vector3(0.9, 0.9, 0.9)},
}
## item_id -> carry style (others: their own sprint_pos / sprint_rot with the rifle sway).
const SPRINT_OF := {"rifle": "rifle", "shotgun": "rifle", "smg": "smg", "sniper": "sniper", "rail": "sniper",
		"pusher": "hug", "rocket": "shoulder", "torpedo": "shoulder", "terrain": "tool", "build": "tool"}


## The carry style of an item (its own `sprint_style` name if it declares one).
static func sprint_style(it) -> Dictionary:
	var own = it.get("sprint_style") if it != null else null
	var name := str(own) if own != null else str(SPRINT_OF.get(str(it.get("item_id")) if it != null else "", ""))
	return SPRINT_STYLE.get(name, {})


## The run pose of a gun (camera space, about the grip): its style's, else sprint_pos / sprint_rot.
static func sprint_pose(it, style: Dictionary) -> Transform3D:
	if style.has("pos"):
		return Transform3D(Basis.from_euler(style["rot"]), style["pos"])
	return Transform3D(Basis.from_euler(it.get("sprint_rot")), it.get("sprint_pos"))


class Carry extends RefCounted:
	var sprint := 0.0                 # sprung run weight (the pose blend; clamp it to 0..1)
	var sprint_v := 0.0
	var raise := 0.0                  # the sprint-to-fire raise (spring)
	var raise_v := 0.0
	var was_sprint := false
	var walk := 0.0
	var run := 0.0
	var ph := 0.0                     # gait phase (rad)
	var sway := Vector2.ZERO
	var sway_v := Vector2.ZERO
	var air := 0.0
	var t := 0.0

	## One frame: sprinting = the run pose is wanted, aim 0..1, look = mouse counts this frame in
	## 60 fps units, k_sway = the item's look-sway scale, style = SPRINT_STYLE entry ({} = the rifle
	## sway). Returns the movement layer (camera space, about the grip) for apply_motion().
	func update(p, dt: float, sprinting: bool, aim: float, look: Vector2, k_sway: float, style: Dictionary) -> Transform3D:
		if p == null:
			return Transform3D()
		dt = minf(dt, 0.033)
		t += dt
		var target := 1.0 if sprinting else 0.0
		var k := 200.0 if sprinting else 240.0
		sprint_v += ((target - sprint) * k - sprint_v * (26.0 if sprinting else 28.0)) * dt
		sprint = clampf(sprint + sprint_v * dt, -0.05, 1.05)
		if was_sprint and not sprinting:
			raise_v += 2.4
		was_sprint = sprinting
		raise_v += (-raise * 190.0 - raise_v * 17.0) * dt
		raise += raise_v * dt
		var up: Vector3 = p.global_transform.basis.y
		var vel: Vector3 = p.velocity
		var v_up := vel.dot(up)
		var hs := (vel - up * v_up).length()
		var grounded: bool = p.is_on_floor()
		var r := 1.0 - exp(-6.0 * dt)
		# (player.gd WALK / SPRINT; 2026-10-06 tok: 5.0 / 8.2 -> 4.2 / 6.8, the sway keeps its size)
		walk = lerpf(walk, clampf(hs / 4.2, 0.0, 1.0) if grounded else 0.0, r)
		run = lerpf(run, clampf(hs / 6.8, 0.6, 1.1) if grounded else 0.4, r)
		if grounded and p.get("astronaut") != null:
			ph = float(p.astronaut._phase) * TAU
		else:
			ph += dt * 3.0
		var sw := clampf(sprint, 0.0, 1.0)
		var sv: Vector3 = style.get("sway", Vector3.ONE)
		var off := Vector3.ZERO
		var rot := Vector3.ZERO
		# Walk: a figure-eight (dip per step, sway + cant per stride), a little behind the footfall.
		var wk := walk * (1.0 - aim * 0.85) * (1.0 - sw)
		var s1 := sin(ph - 0.5)
		var c2 := cos(2.0 * ph - 1.0)
		off += Vector3(0.0045 * s1, -0.0026 * c2, 0.0) * wk
		rot += Vector3(-0.006 * c2, 0.006 * sin(ph - 0.6), 0.012 * s1) * wk
		# Run: a bounce per step, a swing and roll per stride, scaled by the style and the speed.
		var rk := sw * run
		var r1 := sin(ph - 0.35)
		var r2 := cos(2.0 * ph - 0.7)
		off += Vector3(0.013 * r1 * sv.y, -0.0085 * r2 * sv.x, 0.004 * r2) * rk
		rot += Vector3(-0.03 * r2 * sv.x, 0.04 * sin(ph - 0.5) * sv.y, 0.075 * r1 * sv.z) * rk
		# Idle breathing, fading as the walk starts.
		var bk := (1.0 - walk) * (1.0 - aim * 0.85) * (1.0 - sw)
		off += Vector3(0.0, 0.0017 * sin(t * 1.45), 0.0) * bk
		rot += Vector3(0.004 * sin(t * 1.45 + 0.7), 0.0025 * sin(t * 0.53), 0.0035 * sin(t * 0.71)) * bk
		# Look sway: lag on a soft spring with a slight overshoot.
		var tgt := Vector2(clampf(-look.x * 0.0013, -0.07, 0.07), clampf(-look.y * 0.0013, -0.06, 0.06)) * k_sway
		sway_v += ((tgt - sway) * 170.0 - sway_v * 14.5) * dt
		sway += sway_v * dt
		off += Vector3(sway.x * 0.12, sway.y * 0.1, 0.0)
		rot += Vector3(sway.y * 0.9, sway.x * 1.1, sway.x * 0.7)
		# Air: rising drops it, falling lifts it (the landing dip is Motion's).
		air = lerpf(air, clampf(-v_up * 0.006, -0.04, 0.05), 1.0 - exp(-5.0 * dt))
		off.y += air * (1.0 - aim * 0.6)
		rot.x -= air * 0.5 * (1.0 - aim * 0.6)
		# Sprint-to-fire raise: up into the ready with a little overshoot.
		off += Vector3(0.0, 0.012, -0.008) * raise
		rot.x += 0.13 * raise
		return Transform3D(Basis.from_euler(rot), off)


# =================================================================================================
# Stance modifiers
# =================================================================================================

static func crouch_k(p) -> float:
	if p == null or p.get("crouch_k") == null:
		return 0.0
	return clampf(float(p.get("crouch_k")), 0.0, 1.0)


static func sliding(p) -> bool:
	return p != null and p.get("sliding") == true


## Spread multiplier: crouched 30 % tighter; suppression up to 35 % wider (scripts/ui/feel_fx.gd).
static func stance_spread(p) -> float:
	return (1.0 - 0.3 * crouch_k(p) * (0.0 if sliding(p) else 1.0)) * (HitFeel.FeelFx.spread_mult() if p != null and p == Game.player else 1.0)


## Movement-penalty multiplier: a slide shoots steadier than a run.
static func stance_move(p) -> float:
	return 0.5 if sliding(p) else 1.0


## Recoil multiplier: crouched 25 % less.
static func stance_recoil(p) -> float:
	return 1.0 - 0.25 * crouch_k(p) * (0.0 if sliding(p) else 1.0)


## True when the listener is in the vacuum between the planets (own guns: a suit-borne thump only).
static func in_vacuum() -> bool:
	if Game.sfx == null or not is_instance_valid(Game.sfx):
		return false
	var a = Game.sfx.get("listener_air")
	return a != null and float(a) < 0.05


# =================================================================================================
# Hits
# =================================================================================================

## Where a bullet (hit point p on the target's collider, flying along dir) passes through the helmet
## of target.astronaut: {"point": entry on the helmet, "center": helmet centre}, or {} (no head hit).
static func head_zone(t: Node, p: Vector3, dir: Vector3) -> Dictionary:
	if t == null:
		return {}
	var ast = t.get("astronaut")
	if not (ast is Node3D):
		return {}
	var hd = ast.get("head")
	if not (hd is Node3D) or not (hd as Node3D).is_inside_tree():
		return {}
	var c: Vector3 = (hd as Node3D).global_transform * HELMET_OFF
	var along := (c - p).dot(dir)
	if along < -0.3 or along > 1.0:
		return {}
	var miss := (p + dir * along).distance_to(c)
	if miss > HELMET_R:
		return {}
	var back := sqrt(maxf(HELMET_R * HELMET_R - miss * miss, 0.0))
	return {"point": p + dir * (along - back), "center": c}


## Helmets of the astronaut-bodied damageables (rival bots, training dummies, players), cached per
## physics frame: [[target, centre], ...]. Dead, hidden (a bot aboard a skiff) and seated ones are out.
static var _helm_frame := -1
static var _helms: Array = []

static func helmets() -> Array:
	var f := Engine.get_physics_frames()
	if f == _helm_frame:
		return _helms
	_helm_frame = f
	_helms = []
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return _helms
	for t in tree.get_nodes_in_group(Game.DAMAGEABLE):
		if not (t is Node3D) or not (t as Node3D).is_visible_in_tree():
			continue
		if (t.has_method("is_dead") and t.is_dead()) or t.get("vehicle") != null:
			continue
		var ast = t.get("astronaut")
		if not (ast is Node3D) or not (ast as Node3D).is_visible_in_tree():
			continue
		var hd = ast.get("head")
		if not (hd is Node3D) or not (hd as Node3D).is_inside_tree():
			continue
		_helms.append([t, (hd as Node3D).global_transform * HELMET_OFF])
	return _helms


## Where the segment a -> b first enters a helmet sphere (HELMET_R), skipping `skip` (the shooter):
## {"target", "point", "normal", "dist"} or {}. The helmet pokes ~0.15 m out of the 1.8 m hit capsule
## (helmet centre ~1.75 m), so a round grazing the top of a head used to fly through as a ghost miss;
## bullets (rifle_fx.gd) test this next to their ray and a helmet entry counts as a head hit.
static func helmet_sweep(a: Vector3, b: Vector3, skip: Node) -> Dictionary:
	var seg := b - a
	var len := seg.length()
	if len < 1e-5:
		return {}
	var d := seg / len
	var best := {}
	var best_t := len
	for h in helmets():
		if h[0] == skip:
			continue
		var c: Vector3 = h[1]
		var oc := a - c
		var bq := oc.dot(d)
		var cq := oc.length_squared() - HELMET_R * HELMET_R
		if cq > 0.0 and bq > 0.0:
			continue
		var disc := bq * bq - cq
		if disc < 0.0:
			continue
		var tt := maxf(-bq - sqrt(disc), 0.0)
		if tt < best_t:
			best_t = tt
			var p := a + d * tt
			best = {"target": h[0], "point": p, "normal": (p - c).normalized(), "dist": tt}
	return best


## A bullet / pellet of weapon `w` (has player, fx) hit damageable `t` at p (normal n, along dir).
## spec: "dmg", "head" (head multiplier, 0 = no head zone), "push" (m/s shove on a survivor),
## "launch" (m/s ragdoll launch along the bullet on a kill), "big" (0..1 feel weight), "name"
## (weapon short name for the kill feed), "heavy" (big impact effects), "cal" (impact effect calibre,
## 1 = rifle round; default 1.6 heavy / 1.0), "team" (default "home").
## Returns the take_damage result (with "headshot" added). The hit point p rides along as Game.hit_pos
## and the hit_react below is routed into a receiver's hit reactor (scripts/player/hit_reactor.gd):
## a blast's pellets become one reaction there, at their bones.
static func body_hit(w, t: Node, p: Vector3, n: Vector3, dir: Vector3, spec: Dictionary) -> Dictionary:
	var hm := float(spec.get("head", 2.0))
	var head := head_zone(t, p, dir) if hm > 0.0 else {}
	var dmg := float(spec.get("dmg", 20.0))
	if not head.is_empty():
		dmg *= hm
	var hp0 = t.get("hp")
	var lethal: bool = hp0 != null and float(hp0) > 0.0 and float(hp0) <= dmg + 0.001
	var up := Vector3.UP
	if t is Node3D:
		up = (t as Node3D).global_transform.basis.y
	var imp: Vector3
	if lethal:
		var l := float(spec.get("launch", 4.0))
		imp = dir * l + up * l * 0.3
	else:
		imp = dir * float(spec.get("push", 1.0))
	var pl = w.get("player") if w != null else null
	var src: Vector3 = (pl as Node3D).global_position if pl is Node3D else p - dir * 30.0
	var r := Game.damage_target(t, dmg, src, imp, str(spec.get("team", "home")), p)   # p: Game.hit_pos (hit reactions)
	var fx = w.get("fx") if w != null else null
	var ast = t.get("astronaut")
	if r.is_empty():
		if fx != null:
			fx.impact_metal(p, n, dir, false)
		return r
	if not head.is_empty():
		r["headshot"] = true
	var killed: bool = r.get("killed", false)
	var heavy: bool = bool(spec.get("heavy", false)) or dmg >= 50.0
	# Calibre of the impact effects (rifle_fx.gd: sparks, vapour jet, sound weight); a kill hits harder.
	var cal := float(spec.get("cal", 1.6 if heavy else 1.0)) * (1.25 if killed else 1.0)
	if ast is Node3D:
		if not killed and ast.has_method("hit_react"):
			ast.hit_react(dir, clampf(dmg / 60.0, 0.25, 1.2), not head.is_empty())
		if fx != null:
			if fx.has_method("impact_suit"):
				fx.impact_suit(p, n, dir, heavy, cal)
			else:
				fx.impact_metal(p, n, dir, false)
			if not head.is_empty() and fx.has_method("visor_crack"):
				fx.visor_crack(ast.head, head["point"], dir)
	elif fx != null:
		fx.impact_metal(p, n, dir, false, cal)
	HitFeel.inst().target_hit(t, r, dmg, p, {"big": float(spec.get("big", 0.3)), "weapon": str(spec.get("name", ""))})
	return r
