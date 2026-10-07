extends RefCounted
## The downed pose (scripts/war/downed.gd): an astronaut (scripts/player/astronaut.gd) down on its
## belly, the chest a little up on the forearms, the helmet lifted to look ahead; while it moves an
## army crawl (one forearm reaches ahead and pulls while the opposite knee draws up, then the other
## side); while dragged by the shoulder strap the arms trail along the body and the head hangs.
## Pure functions on the astronaut's Node3D bones (no state, no nodes): the owner keeps the crawl
## phase and calls apply() every pose step, then astronaut.sync_skeleton() when it syncs itself.
## The root (astronaut node) stays identity: the lying body is all in the bones, so a ragdoll made
## from it (the confirmed death) starts exactly from this pose. Unit space: origin at the feet of the
## standing body, -Z the way the head points (the crawl direction), Y up.
##   target(a, ph, move, drag, t) -> {bone: Transform3D}   ph crawl phase 0..1 (one full cycle = both
##                                                       sides), move 0..1 crawling, drag 0..1 dragged,
##                                                       t seconds (breathing)
##   apply(a, pose, from = {}, k = 1.0)                  sets the bones (blended from `from` by k)
##   capture(a) -> {bone: Transform3D}                   the current bone locals
##   rest(a) -> {bone: Transform3D}                      the rest pose (the get-up's goal)
##   CRAWL_STRIDE                                        m of travel per full crawl cycle

## Hips (pelvis origin) in unit space: low on the ground, behind the unit origin, so the body lies
## roughly centred on it (the head ~0.4 m ahead, the boots ~1.2 m behind).
const HIPS_AT := Vector3(0, 0.2, 0.28)
const PRONE := -1.5                    # hips pitch (rad): the body axis along -Z, the back up
const CRAWL_STRIDE := 0.55             # m per cycle (two pulls)


## The pose (bone locals). See the header for the inputs.
static func target(a, ph: float, move: float, drag: float, t: float) -> Dictionary:
	var d := {}
	var mv := clampf(move, 0.0, 1.0)
	var dg := clampf(drag, 0.0, 1.0)
	var br := sin(t * 2.4) * (0.025 + 0.02 * (1.0 - dg))          # laboured breathing: the back heaves
	var s := sin(ph * TAU)
	# Pelvis: rolls toward the side whose knee draws up, a slight lift with each pull.
	var hips_x := PRONE + 0.04 * mv * absf(s) * (1.0 - dg)
	var roll := 0.09 * mv * s * (1.0 - dg)
	d[a.hips] = Transform3D(Basis.from_euler(Vector3(hips_x, 0.0, roll)), HIPS_AT + Vector3(0, br * 0.4, 0))
	d[a.spine] = _rot(a, a.spine, Vector3(0.06 + br, 0.0, -roll * 0.6))
	# The chest comes up a little on the forearms (not while dragged: slack).
	d[a.chest] = _rot(a, a.chest, Vector3(lerpf(0.16, 0.02, dg) + br, 0.0, -roll * 0.4))
	# The helmet lifted to look ahead along the ground; dragged it lolls to one side.
	d[a.head] = _rot(a, a.head, Vector3(lerpf(1.0, 0.45, dg), 0.0, lerpf(0.0, 0.35, dg)))
	for i in 2:
		var sd := -1.0 if i == 0 else 1.0
		# This side's pull: 1 reaching ahead, 0 pulled back under the shoulder (sides alternate).
		var c := 0.5 + 0.5 * sin((ph + 0.5 * float(i)) * TAU)
		var reach := lerpf(0.45, c, mv)
		# Arms: forward along the ground, forearms on it (crawl); trailing at the sides (dragged).
		var sh := Vector3(lerpf(1.75, 2.45, reach), 0.0, sd * 0.4)
		var el := Vector3(lerpf(0.7, -0.2, reach), 0.0, 0.0)
		sh = sh.lerp(Vector3(0.25, 0.0, sd * 0.18), dg)
		el = el.lerp(Vector3(0.25, 0.0, 0.0), dg)
		d[a.shoulder[i]] = _rot(a, a.shoulder[i], sh)
		d[a.elbow[i]] = _rot(a, a.elbow[i], el)
		d[a.hand[i]] = _rot(a, a.hand[i], Vector3(lerpf(0.4, 0.1, dg), 0.0, 0.0))
		# Legs: the knee of the side opposite the reaching arm draws up and out along the ground.
		var knee := (1.0 - c) * mv * (1.0 - dg)
		d[a.thigh[i]] = _rot(a, a.thigh[i], Vector3(0.12 + 0.18 * knee, 0.0, sd * (0.12 + 0.48 * knee)))
		d[a.shin[i]] = _rot(a, a.shin[i], Vector3(-(0.25 + 0.35 * knee), 0.0, 0.0))
		d[a.foot[i]] = _rot(a, a.foot[i], Vector3(0.9 - 0.3 * knee, 0.0, 0.0))
	return d


## Sets the bones to `pose`; with `from` (a capture) and k < 1 blended between them.
static func apply(a, pose: Dictionary, from := {}, k := 1.0) -> void:
	if a == null or not is_instance_valid(a):
		return
	var kk := clampf(k, 0.0, 1.0)
	for b in pose:
		if b == null or not is_instance_valid(b):
			continue
		var x: Transform3D = pose[b]
		if kk < 1.0 and from.has(b):
			x = (from[b] as Transform3D).interpolate_with(x, kk)
		(b as Node3D).transform = x


## The current bone locals (the start of a blend).
static func capture(a) -> Dictionary:
	var d := {}
	if a == null or not is_instance_valid(a):
		return d
	for b in _bones(a):
		d[b] = (b as Node3D).transform
	return d


## The rest pose (bone locals): the get-up blends to it, then the owner's animation takes over.
static func rest(a) -> Dictionary:
	var d := {}
	if a == null or not is_instance_valid(a):
		return d
	for b in _bones(a):
		d[b] = a.rest_local(b)
	return d


## Smoothstep 0..1.
static func smooth(v: float) -> float:
	var k := clampf(v, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


static func _bones(a) -> Array:
	return [a.hips, a.spine, a.chest, a.head] + a.thigh + a.shin + a.foot + a.shoulder + a.elbow + a.hand


static func _rot(a, b: Node3D, e: Vector3) -> Transform3D:
	return Transform3D(Basis.from_euler(e), (a.rest_local(b) as Transform3D).origin)
