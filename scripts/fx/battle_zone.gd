extends RefCounted
## One engagement area of the background space battle (space_battle.gd): an ellipsoid far out in
## the sky (battle-local coordinates). The home side (white / orange) holds the -a end, the rival
## side (dark / red) the +a end.

var id := 0
var center := Vector3.ZERO
var a := Vector3.RIGHT          # wide axis, parallel to the planets' axis
var d := Vector3.UP             # outward, away from the planets
var n := Vector3.FORWARD        # third axis (capital ships cruise along it)
var up := Vector3.DOWN          # "dorsal" reference toward the planets (= -d): hulls show their tops
var ext := Vector3(500.0, 250.0, 250.0)   # semi-axes along a, d, n


## > 0 outside the ellipsoid (grows with the distance), < 0 inside.
func outside(p: Vector3) -> float:
	var r := p - center
	var x := r.dot(a) / ext.x
	var y := r.dot(d) / ext.y
	var z := r.dot(n) / ext.z
	return x * x + y * y + z * z - 1.0


## A random point in the zone; side -1 = home end, +1 = rival end, 0 = anywhere.
func rand_point(rng: RandomNumberGenerator, side: float, spread := 0.75) -> Vector3:
	var x := rng.randf_range(-1.0, 1.0) * spread
	if side != 0.0:
		x = side * rng.randf_range(0.15, 0.85)
	return center + a * (x * ext.x) + d * (rng.randf_range(-1.0, 1.0) * spread * ext.y) \
			+ n * (rng.randf_range(-1.0, 1.0) * spread * ext.z)
