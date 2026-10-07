extends RefCounted
## Weapon handling shared by every hand item (AAA-style feel on top of each gun's own pose):
##   Wall pull-back  probe_wall(): a few rays from the eye along the view, as long as the item
##                   (SPEC "len"); terrain, structures (Game.LAYER_SHIP) and vehicles, never
##                   characters. Only geometry AHEAD counts: grazing hits (a tunnel floor / wall
##                   seen along the tunnel) are weighted down by how squarely the ray meets them.
##                   The view model springs the item back toward the chest and tilts it up
##                   (wall_xf(), per handling kind; mild for the drill / build tool); aiming is
##                   eased out above Balance.WALL_ADS_BLOCK and firing blocked above
##                   Balance.WALL_FIRE_BLOCK (viewmodel.blocks_ads() / blocks_fire()).
##   Inspect (Y)     Inspect: a timeline in camera space about the grip: the gun rolls to show its
##                   right side (ejection port), flips to the left side while the left hand comes to
##                   the magazine and taps it twice, then returns. Holding Y pauses on the left-side
##                   view (HOLD_U) until released. The drill / build tool do a simple turn-and-look.
##                   Cancelled by fire, aim, reload, sprint, a swap, a melee or a wall; foley
##                   (cloth, grip, tick, taps, gear) is timed to it.
##   Aim foley       ads_foley(): cloth rustle + gear / sling shift + a soft grip touch on every aim
##                   in / out; heavier per weapon (SPEC "weight"), the sniper adds a scope tick, the
##                   launchers a clunk. Fast toggles never stack: a short gap plays the grip only, and
##                   the level follows how far (and how fast: the aim spring) the gun travels.
##   Melee pose      melee_xf(): the buttstroke (long guns: the gun turns ~100°, the stock leads
##                   forward-left) or a jab (launchers, tools), used by scripts/player/melee.gd.
## Gun hooks (rifle.gd and weapon_base.gd, each owning one Hand as `_hd`):
##   gun_physics(g, real, pressed, alt) -> bool   after the gun's _ads_want: inspect input / cancel,
##                                                aim block, aim foley; true = do not fire this step
##   gun_pose(g, pose, dt, on) -> Transform3D      at the end of _update_pose (the inspect pose)
##   gun_post(g)                                  after _animate_model (inspect left hand, touch hook)
## A gun may define _inspect_touch(u: float, w: float) (special touch while inspecting) and
## _inspect_point() -> Vector3 (gun-frame point the left hand checks; default: its _mag_grab node,
## else SPEC "touch", else just behind the left grip).
## Sounds are the named handling sets of sfx.gd (FOLEY_SETS: "cloth", "gear", "grip", "tick",
## "clunk", "tap", ...): better recordings dropped in under those names replace them.

const Balance := preload("res://scripts/war/balance.gd")

const MASK_WORLD := 1 | 2 | 4          # Game.LAYER_TERRAIN | LAYER_SHIP (structures) | LAYER_VEHICLE
## Wrist offset from a point the left hand holds / touches (camera space, like the reload code).
const WRIST := Vector3(-0.035, -0.085, 0.05)
const HOLD_U := 0.66                   # gun inspect: where holding Y pauses (left side, hand on the mag)

## Per item_id: len = m from the eye to the muzzle at the hip (wall probe), weight 0..1 (foley
## level / pitch), kind = handling style, wall = share of the full pull-back pose (tools: mild),
## touch = gun-frame point the left hand checks during the inspect (optional).
const SPEC := {
	"terrain": {"len": 0.8, "weight": 0.35, "kind": "tool", "wall": 0.6},
	"build": {"len": 0.72, "weight": 0.25, "kind": "tool", "wall": 0.55},
	"rifle": {"len": 1.0, "weight": 0.45, "kind": "rifle", "wall": 1.0},
	"shotgun": {"len": 0.98, "weight": 0.55, "kind": "rifle", "wall": 1.0, "touch": Vector3(0.0, 0.006, -0.13)},
	"sniper": {"len": 1.12, "weight": 0.75, "kind": "sniper", "wall": 1.0},
	"pusher": {"len": 0.9, "weight": 0.62, "kind": "rifle", "wall": 1.0},
	"rocket": {"len": 1.0, "weight": 0.9, "kind": "launcher", "wall": 1.0, "touch": Vector3(-0.1, 0.146, -0.1)},
	"torpedo": {"len": 1.04, "weight": 1.0, "kind": "launcher", "wall": 1.0, "touch": Vector3(-0.088, 0.142, -0.06)},
	"hands": {"len": 0.0, "weight": 0.1, "kind": "none", "wall": 0.0},
}
const DEFAULT_SPEC := {"len": 0.85, "weight": 0.5, "kind": "rifle", "wall": 1.0}

## Full pull-back pose per kind: [offset (camera space), rotation (euler, about the grip)].
## Long guns go to a high port (muzzle up, a little left, canted), launchers drop off the line and
## come back, tools tip up.
const WALL_POSE := {
	"tool": [Vector3(-0.015, -0.02, 0.1), Vector3(0.42, 0.16, 0.24)],
	"rifle": [Vector3(-0.035, -0.035, 0.14), Vector3(0.72, 0.24, 0.42)],
	"sniper": [Vector3(-0.04, -0.04, 0.17), Vector3(0.66, 0.22, 0.4)],
	"launcher": [Vector3(0.0, -0.07, 0.16), Vector3(0.42, 0.12, 0.18)],
}

# Melee swing keys [u, offset, euler] (camera space, about the grip). Strike = keys 1 -> 2.
const STROKE := [
	[0.0, Vector3.ZERO, Vector3.ZERO],
	[0.2, Vector3(0.05, -0.02, 0.09), Vector3(-0.18, -0.55, -0.3)],       # wind-up: back and right
	[0.36, Vector3(-0.16, 0.05, -0.17), Vector3(0.12, -1.75, -0.5)],      # strike: stock leads forward-left
	[0.5, Vector3(-0.15, 0.04, -0.14), Vector3(0.1, -1.68, -0.45)],       # follow-through
	[1.0, Vector3.ZERO, Vector3.ZERO],
]
const JAB := [
	[0.0, Vector3.ZERO, Vector3.ZERO],
	[0.2, Vector3(0.02, -0.02, 0.08), Vector3(-0.1, 0.1, 0.1)],           # drawn back
	[0.36, Vector3(-0.05, 0.03, -0.2), Vector3(0.08, -0.15, -0.12)],      # thrust
	[0.5, Vector3(-0.045, 0.025, -0.17), Vector3(0.06, -0.12, -0.1)],
	[1.0, Vector3.ZERO, Vector3.ZERO],
]

# Inspect keys [u, offset, euler] and foley [u, set, dB, pitch].
const INSPECT_GUN := [
	[0.0, Vector3.ZERO, Vector3.ZERO],
	[0.15, Vector3(-0.055, 0.06, 0.05), Vector3(0.14, -0.32, 1.05)],      # right side up (ejection port)
	[0.36, Vector3(-0.06, 0.066, 0.045), Vector3(0.18, -0.4, 1.12)],
	[0.5, Vector3(-0.035, 0.045, 0.03), Vector3(0.1, 0.42, -0.85)],       # flipped: left side, magazine
	[0.66, Vector3(-0.04, 0.05, 0.035), Vector3(0.12, 0.46, -0.92)],
	[0.84, Vector3(-0.012, 0.012, 0.01), Vector3(0.03, 0.1, -0.18)],
	[1.0, Vector3.ZERO, Vector3.ZERO],
]
const INSPECT_GUN_FX := [[0.01, "cloth", -19.0, 1.0], [0.12, "grip", -21.0, 1.04], [0.2, "tick", -25.0, 1.0],
		[0.38, "cloth", -21.0, 0.95], [0.43, "gear", -25.0, 1.0], [0.535, "tap", -17.0, 1.0],
		[0.595, "tap", -20.0, 1.07], [0.7, "cloth", -21.0, 1.02], [0.86, "grip", -22.0, 0.95],
		[0.95, "gear", -26.0, 1.05]]
const INSPECT_TOOL := [
	[0.0, Vector3.ZERO, Vector3.ZERO],
	[0.22, Vector3(-0.05, 0.05, 0.04), Vector3(0.22, 0.32, -0.95)],       # turned: the left side
	[0.45, Vector3(-0.055, 0.056, 0.042), Vector3(0.25, 0.36, -1.0)],
	[0.7, Vector3(-0.025, 0.03, 0.02), Vector3(0.12, -0.25, 0.55)],       # a glance at the other side
	[1.0, Vector3.ZERO, Vector3.ZERO],
]
const INSPECT_TOOL_FX := [[0.01, "cloth", -21.0, 1.0], [0.18, "grip", -23.0, 1.05], [0.6, "cloth", -22.0, 0.97],
		[0.9, "grip", -24.0, 0.95]]


# =================================================================================================
# Per-item data, input
# =================================================================================================

static func spec(it) -> Dictionary:
	if it == null:
		return SPEC["hands"]
	var s: Dictionary = SPEC.get(str(it.get("item_id")), DEFAULT_SPEC)
	# An item may carry its own length (m) as `handling_len`.
	var own = it.get("handling_len")
	if own != null:
		s = s.duplicate()
		s["len"] = float(own)
	return s


static func kind_of(it) -> String:
	return str(spec(it)["kind"])


## Input action held / just pressed (false while the action is not bound yet, game.gd binds it).
static func held(action: String) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


static func just_pressed(action: String) -> bool:
	return InputMap.has_action(action) and Input.is_action_just_pressed(action)


static func _sfx(name: String, db: float, pitch: float, delay := 0.0) -> void:
	var s = Game.sfx
	if s == null or not is_instance_valid(s):
		return
	if delay > 0.0 and s.has_method("play_later"):
		s.play_later(name, delay, db, pitch)
	else:
		s.play(name, db, pitch)


# =================================================================================================
# Wall pull-back
# =================================================================================================

## 0..1 pull-back target for the held item of player p (0 = free, 1 = muzzle at the face).
static func probe_wall(p, it) -> float:
	var sp := spec(it)
	var length := float(sp["len"])
	if length <= Balance.WALL_NEAR or float(sp["wall"]) <= 0.0:
		return 0.0
	var cam: Camera3D = p.camera
	var xf := cam.global_transform
	var eye := xf.origin
	var space: PhysicsDirectSpaceState3D = p.get_world_3d().direct_space_state
	var ex: Array = [p.get_rid()]
	var best := 0.0
	# The view line, the hip muzzle line (low right) and between: the gun sits low right.
	for local: Vector3 in [Vector3(0.0, 0.0, -1.0), Vector3(0.15, -0.14, -1.0), Vector3(0.07, -0.06, -1.0)]:
		var d: Vector3 = (xf.basis * local).normalized()
		var q := PhysicsRayQueryParameters3D.create(eye, eye + d * length, MASK_WORLD, ex)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var dist := eye.distance_to(hit["position"])
		var n: Vector3 = hit["normal"]
		# The ground under the player is no wall (looking down at your feet, a slope, a step):
		# an upward-facing surface below the chest never pulls the gun back.
		var upv: Vector3 = p.global_transform.basis.y
		if n.dot(upv) > 0.75 and ((hit["position"] as Vector3) - eye).dot(upv) < -0.45:
			continue
		# Only what is in front: a surface met at a grazing angle (tunnel floor / walls along the
		# view) barely counts; a wall faced squarely counts fully.
		var facing := clampf((-n.dot(d) - 0.15) / 0.45, 0.0, 1.0)
		var pen := clampf((length - dist) / (length - Balance.WALL_NEAR), 0.0, 1.0)
		best = maxf(best, pen * facing)
	return best


## Camera-space pull-back pose of weight w (0..1) for handling kind `kind`.
static func wall_xf(w: float, kind: String, amount := 1.0) -> Transform3D:
	if w <= 0.001 or not WALL_POSE.has(kind):
		return Transform3D()
	var k := smoothstep(0.0, 1.0, clampf(w, 0.0, 1.05)) * amount
	var pr: Array = WALL_POSE[kind]
	return Transform3D(Basis.from_euler((pr[1] as Vector3) * k), (pr[0] as Vector3) * k)


## Pre-applies a camera-space offset (rotation about the grip / rig origin) to a pose.
static func apply(pose: Transform3D, off: Transform3D) -> Transform3D:
	return Transform3D(off.basis * pose.basis, pose.origin + off.origin)


# =================================================================================================
# Keyed poses (melee, inspect)
# =================================================================================================

## [offset, euler] at u along `keys`; segment `fast` eases in (accelerates into the hit).
static func keyed(keys: Array, u: float, fast := -1) -> Array:
	return Keys.at(keys, u, fast)


class Keys extends RefCounted:
	static func at(keys: Array, u: float, fast := -1) -> Array:
		u = clampf(u, 0.0, 1.0)
		for i in range(1, keys.size()):
			var b: Array = keys[i]
			if u <= float(b[0]) or i == keys.size() - 1:
				var a: Array = keys[i - 1]
				var x := clampf((u - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-4), 0.0, 1.0)
				var s := x * x if i == fast else x * x * (3.0 - 2.0 * x)
				return [(a[1] as Vector3).lerp(b[1], s), (a[2] as Vector3).lerp(b[2], s)]
		return [Vector3.ZERO, Vector3.ZERO]


## Melee swing pose at u (0..1 of the swing) for an item kind.
static func melee_xf(u: float, kind: String) -> Transform3D:
	if u <= 0.0 or u >= 1.0 or kind == "none":
		return Transform3D()
	var keys: Array = STROKE if kind == "rifle" or kind == "sniper" else JAB
	var r := keyed(keys, u, 2)
	return Transform3D(Basis.from_euler(r[1]), r[0])


# =================================================================================================
# Inspect timeline
# =================================================================================================

class Inspect extends RefCounted:
	var style := "gun"
	var dur := 2.6
	var hold_u := HOLD_U
	var t := -1.0                      # timeline (s), -1 idle
	var hold := false                  # Y held: pause at hold_u
	var held_t := 0.0                  # s spent paused (idle micro motion)
	var out := 1.0                     # 1 playing, eases to 0 when cancelled
	var cancelled := false
	var ev := 0
	var scale := 1.0                   # rotation scale (launchers turn less)

	func start(st: String, rot_scale := 1.0) -> void:
		style = st
		dur = 2.6 if st == "gun" else 1.7
		hold_u = HOLD_U if st == "gun" else 0.45
		t = 0.0
		held_t = 0.0
		out = 1.0
		cancelled = false
		ev = 0
		scale = rot_scale

	func active() -> bool:
		return t >= 0.0

	## Playing and not cancelled.
	func busy() -> bool:
		return t >= 0.0 and not cancelled

	func cancel() -> void:
		if t >= 0.0:
			cancelled = true

	func u() -> float:
		return clampf(t / dur, 0.0, 1.0)

	## Advances the timeline; returns the foley events crossed this frame ([set, dB, pitch]).
	func update(dt: float) -> Array:
		var fired: Array = []
		if t < 0.0:
			return fired
		if cancelled:
			out = move_toward(out, 0.0, dt / 0.16)
			if out <= 0.0:
				t = -1.0
			return fired
		if hold and t / dur >= hold_u:
			held_t += dt
		else:
			t += dt
		var fx: Array = INSPECT_GUN_FX if style == "gun" else INSPECT_TOOL_FX
		while ev < fx.size() and u() >= float(fx[ev][0]):
			fired.append([fx[ev][1], fx[ev][2], fx[ev][3]])
			ev += 1
		if t >= dur:
			t = -1.0
		return fired

	## Camera-space offset (about the grip) of the current inspect pose.
	func pose() -> Transform3D:
		if t < 0.0:
			return Transform3D()
		var keys: Array = INSPECT_GUN if style == "gun" else INSPECT_TOOL
		var r: Array = Keys.at(keys, u())
		var rot: Vector3 = r[1] * scale
		if held_t > 0.0:
			var h := minf(held_t / 0.4, 1.0)
			rot += Vector3(sin(held_t * 1.3) * 0.02, sin(held_t * 0.9 + 0.5) * 0.035, sin(held_t * 1.1) * 0.045) * h
		var k := out * out * (3.0 - 2.0 * out)
		return Transform3D(Basis.from_euler(rot * k), (r[0] as Vector3) * k)

	## Left hand on the magazine (0..1) and the tap bump (0..1) of the gun inspect.
	func reach_w() -> float:
		if t < 0.0 or style != "gun":
			return 0.0
		var x := u()
		var a := clampf((x - 0.38) / 0.12, 0.0, 1.0)
		var b := clampf((x - 0.68) / 0.12, 0.0, 1.0)
		return a * a * (3.0 - 2.0 * a) * (1.0 - b * b * (3.0 - 2.0 * b)) * out

	func tap() -> float:
		if t < 0.0 or style != "gun":
			return 0.0
		var x := u()
		return sin(clampf((x - 0.53) / 0.04, 0.0, 1.0) * PI) + 0.7 * sin(clampf((x - 0.59) / 0.04, 0.0, 1.0) * PI)


## Per-gun handling state (rifle.gd / weapon_base.gd: `_hd`).
class Hand extends RefCounted:
	var inspect := Inspect.new()
	var ads_prev := false
	var ads_last := -9.0


# =================================================================================================
# Gun hooks
# =================================================================================================

## Physics step of a gun, right after it computed _ads_want: inspect start (Y) / cancel, the wall /
## melee / inspect aim block and the aim foley. Returns true when the gun must not fire this step.
static func gun_physics(g, real: bool, pressed: bool, alt: bool) -> bool:
	var h: Hand = g._hd
	var p = g.player
	var vm = p.viewmodel
	var insp := h.inspect
	insp.hold = real and held("inspect")
	if real and just_pressed("inspect") and not insp.busy() and _inspect_ok(g):
		insp.start("gun", 0.72 if kind_of(g) == "launcher" else 1.0)
	if insp.busy() and (pressed or alt or g.reloading or g._sprint or float(vm.wall_target) > 0.3 \
			or vm.melee_busy() or p.hands_busy()):
		insp.cancel()
	if g._ads_want and (vm.blocks_ads() or insp.busy()):
		g._ads_want = false
	ads_foley(g, h, g._ads_want, float(g.ads))
	return vm.blocks_fire() or (insp.active() and insp.out > 0.35)


static func _inspect_ok(g) -> bool:
	var p = g.player
	var vm = p.viewmodel
	return g.equipped and not g.reloading and not g._sprint and float(g.ads) < 0.15 and float(g._since_shot) > 1.0 \
			and vm.is_raised() and not vm.melee_busy() and float(vm.wall_target) < 0.2 and not p.hands_busy()


## Pose hook (end of the gun's _update_pose): advances the inspect, plays its foley, applies its pose.
static func gun_pose(g, pose: Transform3D, dt: float, on: bool) -> Transform3D:
	var h: Hand = g._hd
	var insp := h.inspect
	# Holding Y pauses the inspect on its left-side view: only while Y really is held this frame (the
	# physics step that sets `hold` is skipped while the gun cannot operate, which used to freeze it
	# there, the gun turned up-left with the hand on the magazine).
	insp.hold = insp.hold and held("inspect")
	if not on:
		insp.cancel()
		h.ads_prev = false               # put away aimed: no stray aim-out sound on the next draw
	elif g.player.hands_busy():
		insp.cancel()                    # the left hand is off to a grenade / the wrist scanner
	if not insp.active():
		return pose
	var w := float(spec(g)["weight"])
	for e: Array in insp.update(dt):
		_sfx(e[0], float(e[1]) + w * 2.0, float(e[2]) * lerpf(1.04, 0.9, w))
		if e[0] == "tap":
			g._rk_vel += Vector4(0.35, 0.0, 0.0, 0.01)
	return apply(pose, insp.pose())


## After the gun's _animate_model: the left hand checks the magazine (taps) while inspecting, and the
## gun's optional special touch.
static func gun_post(g) -> void:
	var insp: Inspect = g._hd.inspect
	if not insp.active() or g.reloading:
		return
	if g.has_method("_inspect_touch"):
		g._inspect_touch(insp.u(), insp.out)
	var rw := insp.reach_w()
	if rw <= 0.001 or g.player == null:
		return
	var gun: Transform3D = g.pose_override
	var wrist := Vector3.ZERO
	var mg = g.get("_mag_grab")
	if g.has_method("_inspect_point"):
		wrist = gun * (g._inspect_point() as Vector3) + WRIST
	elif mg is Node3D and (mg as Node3D).is_inside_tree():
		wrist = (g.player.camera.global_transform.affine_inverse() as Transform3D) * (mg as Node3D).global_position
	elif spec(g).has("touch"):
		wrist = gun * (spec(g)["touch"] as Vector3) + WRIST
	elif g.left_grip != null:
		wrist = gun * (g.left_grip.position + Vector3(0.0, -0.01, 0.09)) + WRIST
	else:
		return
	wrist += gun.basis.y * 0.02 * insp.tap()
	g.left_reach = wrist
	g.left_reach_w = rw
	g.left_reach_elbow = Vector3(-0.3, -0.82, 0.48)


## A melee swing started (scripts/player/melee.gd): no inspect, no reload, no aim.
static func gun_melee(g) -> void:
	g._hd.inspect.cancel()
	g._ads_want = false


# =================================================================================================
# Aim foley
# =================================================================================================

## Cloth + gear + grip on every aim in / out (edge of `want`), per weapon weight; quick toggles play
## the grip only and nothing stacks inside 90 ms. The level follows how far the gun travels.
static func ads_foley(g, h: Hand, want: bool, ads: float) -> void:
	if want == h.ads_prev:
		return
	h.ads_prev = want
	var now := Time.get_ticks_msec() * 0.001
	var gap := now - h.ads_last
	if gap < 0.09:
		return
	h.ads_last = now
	var travel := (1.0 - clampf(ads, 0.0, 1.0)) if want else clampf(ads, 0.0, 1.0)
	var lvl := linear_to_db(clampf(travel, 0.3, 1.0))
	# A snappier aim spring (weapon_base ads_k; the rifle's is 110) moves the gun faster: louder.
	var k = g.get("ads_k")
	lvl += linear_to_db(clampf((float(k) if k != null else 110.0) / 110.0, 0.6, 1.4)) * 0.5
	var sp := spec(g)
	var w := float(sp["weight"])
	var kind := str(sp["kind"])
	var quick := gap < 0.3
	var pt := lerpf(1.06, 0.88, w)
	var base := w * 2.5 + lvl
	if want:
		if not quick:
			_sfx("cloth", -19.0 + base, pt)
			_sfx("gear", -24.0 + base, pt)
		_sfx("grip", -21.0 + base, pt * 1.03)
		if kind == "sniper":
			_sfx("tick", -22.0 + base, 0.92, 0.16)          # the scope's eyepiece / ring settles
		elif kind == "launcher":
			_sfx("clunk", -18.0 + base, pt, 0.07)           # the tube onto the shoulder
	else:
		if not quick:
			_sfx("cloth", -21.0 + base, pt * 1.04)
		_sfx("grip", -24.0 + base, pt * 0.98)
		if kind == "launcher":
			_sfx("clunk", -23.0 + base, pt * 1.05, 0.05)
