extends RefCounted
## Articulated first-person gloves (scripts/player/viewmodel.gd builds one per hand) and the grip
## solver that wraps their fingers around whatever the hand holds.
##   Glove  a padded palm block (metacarpal pads, a rubber palm pad, the thenar under the thumb, an
##          armour plate on the back with a knuckle guard and an orange strip), four 3-phalanx fingers
##          and a thumb (2 phalanges on its metacarpal). Every phalanx is one rounded segment with a
##          knuckle cap and a rubber fingertip, on its own node: it turns about its joint centre, so
##          the joint sphere keeps the surface closed at any bend. One material (vm_parts.gd
##          glove_skin: knit fabric, rubber pads, armour plates), one draw call per part.
##   Frame  right hand (the left is its mirror x → -x): the handle axis is +Y through the origin
##          (the index finger on top), -Z forward, the back of the hand on +X. The fingers flex about
##          +Y (they wrap the handle across the front), the thumb about -Y (round the back), so a
##          closed grip opposes them on the far side. The wrist W and FOREARM are the ones the sleeve,
##          the wrist computer and the arm solve use (viewmodel.gd, weapon_base.gd HAND_FOREARM).
##   Pose   PackedFloat32Array(20): per digit [spread, flex1, flex2, flex3] for the index, middle,
##          ring, pinky and thumb (the thumb's flex3 unused). Spread tilts a digit toward the index
##          side (+), flex curls it toward the palm.
##   Solve  solve(): every digit closes its joints in order (the later ones straight) until one of
##          its segments meets a shape at GAP, or the joint's limit: each phalanx ends tangent to
##          what it holds, no intersection and no floating fingertips. The shapes are the item's
##          real geometry (every primitive its build_model() baked, vm_parts.gd bake_log, shapes_of)
##          plus a thin rod on the fist axis, so a finger that holds nothing closes into a fist. The
##          trigger finger instead lays the pad of its last phalanx on the trigger face (IK).
## Grip descriptors (data-driven: a new gun only declares its handle). An item may declare
## `grip_left` / `grip_right` (Dictionary, read with get()); else GRIPS[item_id]; else the defaults.
##   grip_left  "at"    Vector3  point on the handle's axis where the hand's top edge (index side)
##                               sits, in the space of left_grip's parent (the gun, or a moving part
##                               such as the shotgun's pump: the hand rides along with it)
##              "axis"  Vector3  handle direction toward the index finger (vertical foregrip: up;
##                               handguard / pump / forend: toward the muzzle)
##              "palm"  Vector3  from the axis toward the palm: where the hand comes from (vertical
##                               grip: (-0.98, 0, 0.17), left and a little behind; handguard: under
##                               and a little left (-0.35, -0.94, 0))
##              "r"     float    handle radius (half the width along "palm" for a box): sets how far
##                               the palm sits from the axis
##              "spread" Array   optional 5 digit tilts (rad, + toward the index side)
##              Without "at" the left_grip node itself is the hand frame (its +Y the handle axis
##              through its origin, the old fist convention) with r = R_DEFAULT.
##   grip_right "trig_y" float   index finger height on the trigger (VM.grip guns: the pistol grip
##                               at the model origin, the trigger box of every gun at z -0.034)
##              "trig_c" / "trig_hd" / "trig_hh"  a non-standard trigger blade: box centre, half depth,
##                               half height (tilted 0.25 rad like VM's)
##              "at" / "axis" / "palm" / "r"  a pistol grip that is not VM.grip (model space, as for the
##                               left hand; "palm" points back-right): the view model shifts the arm
##                               onto it (viewmodel.gd right_arm), never the gun
##              "spread" Array   optional, as above; "trigger": false = the index wraps the grip too.
## Optional: grip_left "roll" (rad) caps the wrist-screen roll about the handle (default 0.12 on a
## vertical grip, 0 on a handguard / pump: the screen strap slides instead).
## Checks (the clipping probe): every finger segment and palm part is measured against the gun's
## exact primitives; the solve keeps every gap ≥ GAP (0.8 mm) and wrapped segments at GAP.
## The fingers then find their curls against the gun's real shapes by themselves (once per item,
## cached by the view model; the pump stroke and the wrist-screen roll move the whole hand about the
## handle, which keeps every finger on it).

const VM := preload("res://scripts/player/vm_parts.gd")

const N := 5
const GAP := 0.0008                         # m between a solved finger and what it holds
const R_PALM := 0.0215                      # handle radius the palm hugs at ~2 mm (VM.grip, raked)
const R_DEFAULT := 0.0175
const N_PALM := Vector3(0.866, 0.0, 0.5)    # right hand: from the handle axis toward the palm
const W := Vector3(0.026, -0.07, 0.05)      # wrist centre (viewmodel.gd _build_arm, wrist_geom)
const FOREARM := Vector3(0.4, -0.32, 0.86)
const HAND_TOP := -0.0022                   # top edge of the index finger on the handle (hand y)
const ROD_R := 0.0105                       # the rod an empty fist closes on

# Digits: index, middle, ring, pinky, thumb (right hand). MCP joint: (radius from the handle axis,
# angle from +X toward the front -Z in degrees, height). The thumb's is its MCP behind the handle.
const MCP := [Vector3(0.040, 6.0, -0.012), Vector3(0.041, 14.0, -0.0335), Vector3(0.040, 12.0, -0.0535),
		Vector3(0.038, 6.0, -0.0715), Vector3(0.038, -58.0, -0.018)]
const OUTWARD := [0.35, 0.35, 0.35, 0.35, 0.3]     # rad a straight digit points away from the handle
const LEN := [[0.042, 0.025, 0.020], [0.046, 0.028, 0.021], [0.043, 0.027, 0.020], [0.034, 0.020, 0.018],
		[0.032, 0.027]]
const RAD := [[0.0096, 0.009, 0.0085], [0.0101, 0.0097, 0.0091], [0.0096, 0.0092, 0.0087],
		[0.0087, 0.0083, 0.0079], [0.0112, 0.0105]]
const LIMIT := [[1.55, 1.85, 1.25], [1.55, 1.85, 1.25], [1.6, 1.85, 1.25], [1.65, 1.85, 1.25], [1.25, 1.45]]
const CMC := Vector3(0.032, -0.052, 0.047)          # thumb metacarpal base (inside the palm)
# Metacarpal pads from the wrist (base) to each finger's MCP, and their radii.
const MC_BASE := [Vector3(0.034, -0.048, 0.05), Vector3(0.036, -0.058, 0.052), Vector3(0.035, -0.068, 0.05),
		Vector3(0.031, -0.078, 0.046)]
const MC_R := [0.0112, 0.0118, 0.0112, 0.0102]

# Glove colours (vertex colour; alpha = part kind for the glove shader).
const C_FABRIC := Color(0.27, 0.28, 0.31, 0.0)
const C_RUBBER := Color(0.15, 0.155, 0.17, 1.0 / 3.0)
const C_PLATE := Color(0.46, 0.48, 0.51, 2.0 / 3.0)
const C_ACCENT := Color(0.95, 0.42, 0.08, 1.0)
const C_SEAM := Color(0.17, 0.175, 0.19, 0.0)

# Preset poses ([spread, f1, f2, f3] per digit).
const REST := [0.06, 0.22, 0.32, 0.18, 0.0, 0.28, 0.42, 0.22, -0.04, 0.34, 0.48, 0.26, -0.1, 0.4, 0.52, 0.28,
		0.05, 0.2, 0.22, 0.0]
const CUP := [0.04, 0.5, 0.72, 0.38, 0.0, 0.56, 0.82, 0.42, -0.04, 0.62, 0.88, 0.44, -0.1, 0.68, 0.9, 0.44,
		0.1, 0.38, 0.32, 0.0]
const LOOSE_FIST := [0.03, 0.8, 1.05, 0.6, 0.0, 0.88, 1.15, 0.65, -0.03, 0.95, 1.2, 0.65, -0.08, 1.0, 1.2, 0.62,
		0.1, 0.5, 0.45, 0.0]
## Flat open hand (a palm slap, a press with the heel of the hand; scripts/items/reload_anim.gd): the
## fingers a little hyperextended at the knuckles so they lie in the palm's plane, slightly fanned.
const OPEN_PALM := [0.1, -0.24, 0.06, 0.04, 0.02, -0.26, 0.06, 0.04, -0.06, -0.24, 0.08, 0.05, -0.15, -0.2, 0.1, 0.06,
		0.1, 0.08, 0.1, 0.0]
## Thumb of a press [spread, flex1, flex2, -] (digit 4): straightened up along the handle toward the
## index side (a negative spread lifts the thumb tip that way), e.g. onto a magazine release paddle.
const THUMB_PRESS := [-0.45, 0.12, 0.08, 0.0]

const CAP := 0
const CONE := 1
const BOX := 2
const SPH := 3
const ELL := 4
const TOR := 5
const PLANE := 6

const STEP := 0.1                           # joint sweep step (rad) before the bisection
const REACH_C := Vector3(0.0, -0.04, -0.01) # hand-frame centre of everything a hand can touch
const REACH_R := 0.15

## Per item_id (guns that declare nothing themselves). Right hands: the pistol grip at the model
## origin; trig_y keeps the trigger finger clear of each gun's receiver / magazine well. Left hands:
## handguard C-clamps on the long guns (palm under, fingers up the far side, thumb up the near side),
## the pump on the shotgun, the vertical front grips on the pusher / launchers / drill, the box handle
## on the build tool. Coordinates in the space of each gun's left_grip parent.
const GRIPS := {
	"rifle": {"right": {"trig_y": -0.003},
		"left": {"at": Vector3(0.0, 0.062, -0.2725), "axis": Vector3(0, 0, -1), "palm": Vector3(-0.35, -0.94, 0.0), "r": 0.033}},
	"sniper": {"right": {"trig_y": -0.0085, "spread": [0.0, -0.26, -0.08, 0.08, 0.12]},
		"left": {"at": Vector3(0.0, 0.058, -0.3125), "axis": Vector3(0, 0, -1), "palm": Vector3(-0.35, -0.94, 0.0), "r": 0.031}},
	"rail": {"right": {"trig_y": -0.003},
		"left": {"at": Vector3(0.0, 0.033, -0.447), "axis": Vector3(0, 0, -1), "palm": Vector3(0.05, -1.0, 0.0), "r": 0.0355}},
	"shotgun": {"right": {"trig_y": -0.002},
		"left": {"at": Vector3(0.0, 0.034, -0.0615), "axis": Vector3(0, 0, -1), "palm": Vector3(-0.3, -0.95, 0.0), "r": 0.027}},
	"pusher": {"right": {"trig_y": -0.0068, "spread": [0.0, -0.24, -0.07, 0.08, 0.12]},
		"left": {"at": Vector3(0.0, -0.0005, -0.232), "axis": Vector3(0, 0.07, -0.004), "palm": Vector3(-0.984, 0, 0.173), "r": 0.0182}},
	"rocket": {"right": {"trig_y": -0.0075, "spread": [0.0, -0.24, -0.07, 0.08, 0.12]},
		"left": {"at": Vector3(0.0, 0.026, -0.3011), "axis": Vector3(0, 0.095, -0.004), "palm": Vector3(-0.984, 0, 0.173), "r": 0.0192}},
	"torpedo": {"right": {"trig_y": -0.0094, "spread": [0.0, -0.26, -0.08, 0.08, 0.12]},
		"left": {"at": Vector3(0.0, -0.0025, -0.258), "axis": Vector3(0, 0.06, -0.008), "palm": Vector3(-0.984, 0, 0.173), "r": 0.0165}},
	"terrain": {"right": {"trig_y": -0.0025},
		"left": {"at": Vector3(0.0, -0.0005, -0.17), "axis": Vector3(0, 0.066, -0.009), "palm": Vector3(-0.984, 0, 0.173), "r": 0.0165}},
	"build": {"right": {"trigger": false},      # no trigger on the constructor: the index wraps too
		"left": {"at": Vector3(0.0, 0.013, -0.13), "axis": Vector3(0, 1, 0), "palm": Vector3(-0.984, 0, 0.173), "r": 0.016, "roll": 0.08}},
	# Uzi-style: a raked rounded-box grip with the magazine through it, the support hand cupping the
	# handguard and the stock's butt plate under it.
	"smg": {"right": {"at": Vector3(0.0, -0.0022, 0.0041), "axis": Vector3(0, 0.99875, -0.04998),
			"palm": Vector3(0.866, -0.025, 0.4994), "r": 0.0275, "trig_y": -0.0062,
			"trig_c": Vector3(0.0, -0.004, -0.032), "trig_hd": 0.0035, "trig_hh": 0.011},
		"left": {"at": Vector3(0.0, 0.0, -0.1985), "axis": Vector3(0, 0, -1), "palm": Vector3(-0.35, -0.94, 0.0), "r": 0.0255}},
}

static var _base: Array = []                # MCP joint per digit (right hand)
static var _dir: Array = []                 # straight direction per digit
static var _axis: Array = []                # flexion axis per digit


# =================================================================================================
# Anatomy, poses
# =================================================================================================

static func _anat() -> void:
	if not _base.is_empty():
		return
	for i in N:
		var m: Vector3 = MCP[i]
		var phi := deg_to_rad(m.y)
		_base.append(Vector3(m.x * cos(phi), m.z, -m.x * sin(phi)))
		if i < 4:
			_dir.append(Vector3(-sin(phi), 0.0, -cos(phi)).rotated(Vector3.UP, -float(OUTWARD[i])))
			_axis.append(Vector3.UP)
		else:
			_dir.append(Vector3(sin(phi), 0.0, cos(phi)).rotated(Vector3.UP, float(OUTWARD[i])))
			_axis.append(Vector3.DOWN)


static func segs(i: int) -> int:
	return 2 if i == 4 else 3


static func pose_of(values: Array) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(N * 4)
	for k in mini(values.size(), N * 4):
		p[k] = float(values[k])
	return p


static func lerp_pose(a: PackedFloat32Array, b: PackedFloat32Array, w: float) -> PackedFloat32Array:
	if w <= 0.0:
		return a
	if w >= 1.0:
		return b
	var p := PackedFloat32Array()
	p.resize(N * 4)
	for k in N * 4:
		p[k] = lerpf(a[k], b[k], w)
	return p


## Palm offset of a hand on a handle of radius r (hand frame, applied after the wrist roll): the
## palm keeps its ~2 mm from the handle whatever its size.
static func palm_offset(side: float, r: float) -> Vector3:
	return Vector3(N_PALM.x * side, 0.0, N_PALM.z) * (r - R_PALM)


## Hand frame (in the space of left_grip's parent) from a grip descriptor with "at" / "axis" /
## "palm", for a hand of `side` (the left hand: -1).
static func frame_of(d: Dictionary, side := -1.0) -> Transform3D:
	var y: Vector3 = (d["axis"] as Vector3).normalized()
	var pw: Vector3 = d["palm"]
	pw = (pw - y * pw.dot(y)).normalized()
	var ph := Vector3(N_PALM.x * side, 0.0, N_PALM.z).normalized()
	# Hand basis B with B·Y = y and B·ph = pw (ph ⊥ Y): B = [x, y, z] solved from ph = (px, 0, pz).
	var pz := pw.cross(y)                   # = B·(ph × Y)
	var phz := ph.cross(Vector3.UP)
	# Columns: B·X and B·Z from the two orthonormal pairs (ph, phz) → (pw, pz).
	var bx := pw * ph.x + pz * phz.x
	var bz := pw * ph.z + pz * phz.z
	var b := Basis(bx.normalized(), y, bz.normalized()).orthonormalized()
	var origin: Vector3 = (d["at"] as Vector3) - y * HAND_TOP
	return Transform3D(b, origin)


## Hand frame in the space of a part the hand holds (a magazine: reload_anim.gd), from a grip
## descriptor ("at" / "axis" / "palm" / "r" as grip_left), the palm offset for its radius included:
## where the hand sits on it and the frame its fingers are solved in (viewmodel.gd "hold").
static func hold_frame(d: Dictionary, side := -1.0) -> Transform3D:
	return frame_of(d, side) * Transform3D(Basis(), palm_offset(side, float(d.get("r", R_DEFAULT))))


## Shapes (in a frame) of the primitives that one bake root merged (vm_parts.gd bake_log entries of
## `root`), wherever that part is now (a held magazine).
static func shapes_under(log: Array, root: Node3D, to_frame: Transform3D) -> Array:
	var out: Array = []
	for e: Array in log:
		if e[0] != root:
			continue
		var sh := shape_from_mesh(e[2], to_frame * (e[1] as Transform3D))
		if not sh.is_empty():
			out.append(sh)
	return out


## Base frame of digit i (hand frame, side ±1) with its spread: local X = flexion axis, -Z = the
## straight digit, +Y = palmar.
static func base_frame(i: int, side: float, spread: float) -> Transform3D:
	_anat()
	var m := Vector3(side, 1.0, 1.0)
	var b: Vector3 = (_base[i] as Vector3) * m
	var a: Vector3 = (_axis[i] as Vector3) * m * side
	var d: Vector3 = (_dir[i] as Vector3) * m
	var z := -d.normalized()
	var x := (a - z * a.dot(z)).normalized()
	var y := z.cross(x)
	return Transform3D(Basis(x, y, z) * Basis(Vector3.UP, -spread * side), b)


## Joint centres of digit i for pose p: [MCP, PIP, DIP, tip] (thumb: [MCP, IP, tip]).
static func digit_points(i: int, side: float, p: PackedFloat32Array) -> PackedVector3Array:
	var f := base_frame(i, side, p[i * 4])
	var lens: Array = LEN[i]
	var xf := Transform3D(f.basis * Basis(Vector3.RIGHT, p[i * 4 + 1]), f.origin)
	var pts := PackedVector3Array([xf.origin])
	for k in lens.size():
		xf = xf * Transform3D(Basis(), Vector3(0.0, 0.0, -float(lens[k])))
		pts.append(xf.origin)
		if k + 1 < lens.size():
			xf = xf * Transform3D(Basis(Vector3.RIGHT, p[i * 4 + 2 + k]), Vector3.ZERO)
	return pts


# =================================================================================================
# Building the glove
# =================================================================================================

## Glove on `h` (hand node, side ±1): returns {"joints": [[j1, j2, j3], ...], "side"}. The palm is one
## merged mesh on h, each phalanx one merged mesh on its joint node.
static func build(h: Node3D, side: float) -> Dictionary:
	_merge(h, palm_parts(side))
	# Digits.
	var joints: Array = []
	for i in N:
		var lens: Array = LEN[i]
		var rads: Array = RAD[i]
		var chain: Array = []
		var parent: Node3D = h
		for k in lens.size():
			var j := Node3D.new()
			parent.add_child(j)
			if k > 0:
				j.position = Vector3(0.0, 0.0, -float(lens[k - 1]))
			chain.append(j)
			parent = j
		for k in lens.size():
			_phalanx(chain[k], float(lens[k]), float(rads[k]), k, k == lens.size() - 1)
		joints.append(chain)
	var g := {"joints": joints, "side": side}
	apply(g, pose_of(REST))
	return g


## The static palm block of a hand (side ±1) as [mesh, transform, colour] parts (hand frame).
static func palm_parts(side: float) -> Array:
	_anat()
	var m := Vector3(side, 1.0, 1.0)
	var parts: Array = []
	# Metacarpal pads (the palm block), the web between thumb and index, the thumb's metacarpal.
	for i in 4:
		parts.append(_cap((MC_BASE[i] as Vector3) * m, (_base[i] as Vector3) * m, float(MC_R[i]), C_FABRIC))
	for i in 3:
		var a: Vector3 = ((MC_BASE[i] as Vector3) + (_base[i] as Vector3)) * 0.5
		var b: Vector3 = ((MC_BASE[i + 1] as Vector3) + (_base[i + 1] as Vector3)) * 0.5
		parts.append(_cap(a * m, b * m, 0.0105, C_FABRIC))
	var bt: Vector3 = _base[4]
	parts.append(_cap(CMC * m, bt * m, 0.011, C_FABRIC))
	# The web between thumb and index, bowed out over the back of the handle (big handguards bulge
	# toward it).
	var web := (bt + (_base[0] as Vector3)) * 0.5
	var web_out := Vector3(web.x, 0.0, web.z).normalized() * 0.037 + Vector3(0.0, web.y, 0.0)
	parts.append(_cap(bt * m, web_out * m, 0.0085, C_FABRIC))
	parts.append(_cap(web_out * m, (_base[0] as Vector3) * m, 0.0085, C_FABRIC))
	# Rubber palm pad (the contact patch on the handle) and the thenar under the thumb.
	var pd := Vector3(cos(deg_to_rad(-30.0)), 0.0, -sin(deg_to_rad(-30.0)))
	parts.append(_ell(pd * 0.0345 + Vector3(0.0, -0.046, 0.0), Vector3(0.011, 0.027, 0.019),
			Basis(pd, Vector3.UP, pd.cross(Vector3.UP)), C_RUBBER, side))
	var tm := (CMC + bt) * 0.5
	var td := Vector3(-tm.x, 0.0, -tm.z).normalized()
	var tl := (bt - CMC).normalized()
	parts.append(_ell(tm + td * 0.0035, Vector3(0.0115, 0.02, 0.0125), _basis_yx(tl, td), C_RUBBER, side))
	# Armour plate on the back of the hand, the knuckle guard with its orange strip, a cuff seam.
	var back := Vector3(1.0, 0.0, 0.12).normalized()
	var mid := Vector3(0.0379 + 0.0108, -0.051, 0.02)
	var along := ((_base[1] as Vector3) - (MC_BASE[1] as Vector3)).normalized()
	parts.append(_ell(mid, Vector3(0.0042, 0.028, 0.03), _basis_yx(back.cross(along).normalized(), back), C_PLATE, side))
	var kn: Array = []
	for i in 4:
		var bi: Vector3 = _base[i]
		var out := Vector3(bi.x, 0.0, bi.z).normalized()
		kn.append(bi + out * float(RAD[i][0]) * 0.72)
	for i in 3:
		parts.append(_cap((kn[i] as Vector3) * m, (kn[i + 1] as Vector3) * m, 0.0056, C_PLATE))
	for i in 3:
		var o0: Vector3 = (kn[i] as Vector3) + Vector3((kn[i] as Vector3).x, 0.0, (kn[i] as Vector3).z).normalized() * 0.0042
		var o1: Vector3 = (kn[i + 1] as Vector3) + Vector3((kn[i + 1] as Vector3).x, 0.0, (kn[i + 1] as Vector3).z).normalized() * 0.0042
		parts.append(_cap(o0 * m, o1 * m, 0.0021, C_ACCENT))
	return parts


## One phalanx on joint node j (bone along -Z, palmar +Y): the rounded segment, a knuckle cap on the
## back of its joint (armoured on the first row), a seam line along each side, a rubber fingertip.
static func _phalanx(j: Node3D, l: float, r: float, k: int, tip: bool) -> void:
	var parts: Array = []
	parts.append(_cap(Vector3.ZERO, Vector3(0.0, 0.0, -l), r, C_FABRIC))
	if k == 0:
		parts.append(_ell(Vector3(0.0, -r * 0.5, -r * 0.2), Vector3(r * 0.86, r * 0.62, r * 1.0), Basis(), C_PLATE, 1.0))
	else:
		parts.append(_ell(Vector3(0.0, -r * 0.42, -r * 0.15), Vector3(r * 0.8, r * 0.6, r * 0.85), Basis(), C_FABRIC, 1.0))
	# Palmar pad (rubber), flush with the segment: it stays inside the collision radius.
	parts.append(_ell(Vector3(0.0, r * 0.32, -l * 0.5), Vector3(r * 0.84, r * 0.66, l * 0.42 + r * 0.25), Basis(), C_RUBBER, 1.0))
	for sx in [-1.0, 1.0]:
		parts.append(_cap(Vector3(sx * r * 0.93, 0.0, -r * 0.15), Vector3(sx * r * 0.93, 0.0, -l + r * 0.1), r * 0.12, C_SEAM))
	if tip:
		parts.append(_ell(Vector3(0.0, -r * 0.15, -l + r * 0.1), Vector3(r * 1.02, r * 0.9, r * 0.95), Basis(), C_RUBBER, 1.0))
	_merge(j, parts)


static func _basis_yx(y: Vector3, x_hint: Vector3) -> Basis:
	var yy := y.normalized()
	var x := (x_hint - yy * x_hint.dot(yy)).normalized()
	return Basis(x, yy, x.cross(yy))


static func _cap(a: Vector3, b: Vector3, r: float, c: Color) -> Array:
	var cm := CapsuleMesh.new()
	cm.radius = r
	cm.height = a.distance_to(b) + r * 2.0
	cm.radial_segments = 16
	cm.rings = 6
	var bb := VM.basis_y(b - a) if a.distance_to(b) > 1e-5 else Basis()
	return [cm, Transform3D(bb, (a + b) * 0.5), c]


## Ellipsoid part; its basis is mirrored for the left hand (side -1) along with the position.
static func _ell(pos: Vector3, radii: Vector3, b: Basis, c: Color, side: float) -> Array:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 18
	sm.rings = 10
	var mb := b
	var p := pos
	if side < 0.0:
		var mir := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
		mb = mir * b
		p = Vector3(-pos.x, pos.y, pos.z)
	return [sm, Transform3D(mb * Basis.from_scale(radii), p), c]


## Merges [mesh, transform, colour] parts into one surface (vertex colours) under `parent`.
static func _merge(parent: Node3D, parts: Array) -> MeshInstance3D:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for pr: Array in parts:
		var mesh: Mesh = pr[0]
		var xf: Transform3D = pr[1]
		var c: Color = pr[2]
		var arr: Array = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var uvs = arr[Mesh.ARRAY_TEX_UV]
		var ii = arr[Mesh.ARRAY_INDEX]
		var nb := xf.basis.inverse().transposed()
		# A mirrored transform (negative determinant) flips the winding: swap two indices per triangle.
		var flip := xf.basis.determinant() < 0.0
		var base := v.size()
		for k in verts.size():
			v.append(xf * verts[k])
			var nn: Vector3 = (nb * norms[k]).normalized()
			n.append(nn)
			uv.append(uvs[k] if uvs != null and k < uvs.size() else Vector2.ZERO)
			col.append(c)
		if ii != null and ii.size() > 0:
			for t in range(0, ii.size(), 3):
				if flip:
					idx.append(base + ii[t])
					idx.append(base + ii[t + 2])
					idx.append(base + ii[t + 1])
				else:
					idx.append(base + ii[t])
					idx.append(base + ii[t + 1])
					idx.append(base + ii[t + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, VM.glove_skin(true))
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(mi)
	return mi


## Poses the glove's joint nodes.
static func apply(g: Dictionary, p: PackedFloat32Array) -> void:
	var side: float = g["side"]
	var joints: Array = g["joints"]
	for i in N:
		var chain: Array = joints[i]
		var f := base_frame(i, side, p[i * 4])
		(chain[0] as Node3D).transform = Transform3D(f.basis * Basis(Vector3.RIGHT, p[i * 4 + 1]), f.origin)
		for k in range(1, chain.size()):
			(chain[k] as Node3D).basis = Basis(Vector3.RIGHT, p[i * 4 + 1 + k])


# =================================================================================================
# Shapes (what the fingers must not enter)
# =================================================================================================

## Shapes in a frame from a vm_parts.gd bake_log record: each entry [bake root, transform relative to
## it, mesh]; `to_frame` maps the item model's space into the frame, `model` is the item model root
## (bake roots are found below it). Unknown meshes (quads, custom arrays) are skipped.
static func shapes_of(log: Array, model: Node3D, to_frame: Transform3D) -> Array:
	var out: Array = []
	for e: Array in log:
		var root = e[0]
		if not (root is Node3D) or not is_instance_valid(root):
			continue
		var rel := Transform3D()
		var nd: Node = root
		var ok := false
		while nd != null:
			if nd == model:
				ok = true
				break
			if not (nd as Node3D).visible:
				break                       # hidden props (a reload's spare torpedo): not there
			rel = (nd as Node3D).transform * rel
			nd = nd.get_parent()
		if not ok:
			continue
		var sh := shape_from_mesh(e[2], to_frame * rel * (e[1] as Transform3D))
		if not sh.is_empty():
			out.append(sh)
	return out


static func shape_from_mesh(mesh: Mesh, xf: Transform3D) -> Dictionary:
	var sc := xf.basis.get_scale()
	var rot := Transform3D(xf.basis.orthonormalized(), xf.origin)
	if mesh is CapsuleMesh:
		var cm := mesh as CapsuleMesh
		var r := cm.radius * maxf(sc.x, sc.z)
		var half := maxf(cm.height * 0.5 * sc.y - r, 0.0)
		return cap_shape(rot * Vector3(0.0, -half, 0.0), rot * Vector3(0.0, half, 0.0), r)
	if mesh is CylinderMesh:
		var cy := mesh as CylinderMesh
		var h := cy.height * 0.5 * sc.y
		var r1 := cy.bottom_radius * maxf(sc.x, sc.z)
		var r2 := cy.top_radius * maxf(sc.x, sc.z)
		return {"t": CONE, "ixf": rot.affine_inverse(), "h": h, "r1": r1, "r2": r2, "c": xf.origin,
				"br": sqrt(h * h + maxf(r1, r2) * maxf(r1, r2))}
	if mesh is BoxMesh:
		var hs := (mesh as BoxMesh).size * 0.5 * sc
		return {"t": BOX, "ixf": rot.affine_inverse(), "h": hs, "c": xf.origin, "br": hs.length()}
	if mesh is SphereMesh:
		var rad := sc * (mesh as SphereMesh).radius
		return {"t": ELL, "ixf": rot.affine_inverse(), "rad": rad, "c": xf.origin, "br": maxf(rad.x, maxf(rad.y, rad.z))}
	if mesh is TorusMesh:
		var tm := mesh as TorusMesh
		var big := (tm.inner_radius + tm.outer_radius) * 0.5 * sc.x
		var small := (tm.outer_radius - tm.inner_radius) * 0.5 * sc.x
		return {"t": TOR, "ixf": rot.affine_inverse(), "R": big, "r": small, "c": xf.origin, "br": big + small}
	return {}


static func cap_shape(a: Vector3, b: Vector3, r: float) -> Dictionary:
	return {"t": CAP, "a": a, "b": b, "r": r, "c": (a + b) * 0.5, "br": a.distance_to(b) * 0.5 + r}


static func sphere_shape(c: Vector3, r: float) -> Dictionary:
	return {"t": SPH, "c": c, "r": r, "br": r}


static func ell_shape(c: Vector3, radii: Vector3, b := Basis()) -> Dictionary:
	return {"t": ELL, "ixf": Transform3D(b, c).affine_inverse(), "rad": radii, "c": c, "br": maxf(radii.x, maxf(radii.y, radii.z))}


## Signed distance from p to a shape (negative inside).
static func sdf(sh: Dictionary, p: Vector3) -> float:
	match int(sh["t"]):
		CAP:
			return Geometry3D.get_closest_point_to_segment(p, sh["a"], sh["b"]).distance_to(p) - float(sh["r"])
		SPH:
			return p.distance_to(sh["c"]) - float(sh["r"])
		BOX:
			var q: Vector3 = (sh["ixf"] as Transform3D) * p
			var d: Vector3 = q.abs() - (sh["h"] as Vector3)
			return Vector3(maxf(d.x, 0.0), maxf(d.y, 0.0), maxf(d.z, 0.0)).length() + minf(maxf(d.x, maxf(d.y, d.z)), 0.0)
		CONE:
			var q: Vector3 = (sh["ixf"] as Transform3D) * p
			var h: float = sh["h"]
			var r1: float = sh["r1"]
			var r2: float = sh["r2"]
			var q2 := Vector2(Vector2(q.x, q.z).length(), q.y)
			var k1 := Vector2(r2, h)
			var k2 := Vector2(r2 - r1, 2.0 * h)
			var ca := Vector2(q2.x - minf(q2.x, r1 if q2.y < 0.0 else r2), absf(q2.y) - h)
			var cb := q2 - k1 + k2 * clampf((k1 - q2).dot(k2) / maxf(k2.dot(k2), 1e-12), 0.0, 1.0)
			var s := -1.0 if (cb.x < 0.0 and ca.y < 0.0) else 1.0
			return s * sqrt(minf(ca.dot(ca), cb.dot(cb)))
		ELL:
			var q: Vector3 = (sh["ixf"] as Transform3D) * p
			var r: Vector3 = sh["rad"]
			var k0 := (q / r).length()
			var k1 := (q / (r * r)).length()
			return k0 * (k0 - 1.0) / maxf(k1, 1e-9)
		TOR:
			var q: Vector3 = (sh["ixf"] as Transform3D) * p
			return Vector2(Vector2(q.x, q.z).length() - float(sh["R"]), q.y).length() - float(sh["r"])
		PLANE:
			return (p - (sh["p"] as Vector3)).dot(sh["n"])
	return 1.0


## Least distance from the segment a-b to a shape's surface (negative: the segment enters it).
static func seg_dist(sh: Dictionary, a: Vector3, b: Vector3) -> float:
	match int(sh["t"]):
		CAP:
			return seg_seg(a, b, sh["a"], sh["b"]) - float(sh["r"])
		SPH:
			return Geometry3D.get_closest_point_to_segment(sh["c"], a, b).distance_to(sh["c"]) - float(sh["r"])
		PLANE:
			return minf(sdf(sh, a), sdf(sh, b))
	var lo := 0.0
	var hi := 1.0
	var best := minf(sdf(sh, a), sdf(sh, b))
	if int(sh["t"]) == TOR:
		# Not convex: a coarse scan first, then the golden search around the best sample.
		var bi := 0
		var bv := INF
		for s in 9:
			var v := sdf(sh, a.lerp(b, s / 8.0))
			if v < bv:
				bv = v
				bi = s
		best = minf(best, bv)
		lo = maxf((bi - 1) / 8.0, 0.0)
		hi = minf((bi + 1) / 8.0, 1.0)
	var gr := 0.618034
	var x1 := hi - gr * (hi - lo)
	var x2 := lo + gr * (hi - lo)
	var f1 := sdf(sh, a.lerp(b, x1))
	var f2 := sdf(sh, a.lerp(b, x2))
	for _n in 11:
		if f1 < f2:
			hi = x2
			x2 = x1
			f2 = f1
			x1 = hi - gr * (hi - lo)
			f1 = sdf(sh, a.lerp(b, x1))
		else:
			lo = x1
			x1 = x2
			f1 = f2
			x2 = lo + gr * (hi - lo)
			f2 = sdf(sh, a.lerp(b, x2))
	return minf(best, minf(f1, f2))


## Distance between the segments p1-q1 and p2-q2 (Ericson's clamped closest points; Geometry3D's
## get_closest_points_between_segments misses the pair when one end clamps).
static func seg_seg(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> float:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-12 and e <= 1e-12:
		return r.length()
	if a <= 1e-12:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-12:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var den := a * e - b * b
			s = clampf((b * f - c * e) / den, 0.0, 1.0) if den > 1e-14 else 0.0
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return (p1 + d1 * s).distance_to(p2 + d2 * t)


## Shapes near a centre (bounding spheres within reach).
static func cull(shapes: Array, c: Vector3, r: float) -> Array:
	var out: Array = []
	for sh: Dictionary in shapes:
		if int(sh["t"]) == PLANE or (sh["c"] as Vector3).distance_to(c) < float(sh["br"]) + r:
			out.append(sh)
	return out


## Least clearance of digit i's segments from `from` on (segment surface to shape surface, m).
static func clearance(i: int, side: float, p: PackedFloat32Array, shapes: Array, from := 0) -> float:
	var pts := digit_points(i, side, p)
	var best := INF
	for s in range(from, segs(i)):
		var a: Vector3 = pts[s]
		var b: Vector3 = pts[s + 1]
		var r: float = RAD[i][s]
		var mid := (a + b) * 0.5
		var hl := a.distance_to(b) * 0.5
		for sh: Dictionary in shapes:
			if int(sh["t"]) != PLANE and mid.distance_to(sh["c"]) - float(sh["br"]) - hl - r > best:
				continue
			best = minf(best, seg_dist(sh, a, b) - r)
	return best


static func _clear(i: int, side: float, p: PackedFloat32Array, shapes: Array, from: int) -> bool:
	var pts := digit_points(i, side, p)
	for s in range(from, segs(i)):
		var a: Vector3 = pts[s]
		var b: Vector3 = pts[s + 1]
		var r: float = float(RAD[i][s]) + GAP
		var mid := (a + b) * 0.5
		var hl := a.distance_to(b) * 0.5
		for sh: Dictionary in shapes:
			if int(sh["t"]) != PLANE and mid.distance_to(sh["c"]) > float(sh["br"]) + hl + r:
				continue
			if seg_dist(sh, a, b) < r:
				return false
	return true


# =================================================================================================
# Grip solve
# =================================================================================================

## Grip pose of one hand (side ±1) on `shapes` (hand frame). spec: "spread" (5 rad), "trigger"
## (Vector3: the index pad target, hand frame) with "trigger_n" (the trigger face normal), "pull"
## (gap of the pad to the face, m).
static func solve(side: float, shapes: Array, spec: Dictionary) -> PackedFloat32Array:
	_anat()
	var p := pose_of([])
	var sp: Array = spec.get("spread", [])
	for i in N:
		p[i * 4] = float(sp[i]) if i < sp.size() else 0.0
	var near := cull(shapes, REACH_C * Vector3(side, 1, 1), REACH_R)
	var rod := cap_shape(Vector3(0.0, 0.004, 0.0), Vector3(0.0, -0.085, 0.0), ROD_R)
	for i in N:
		var reach := 0.0
		for l in LEN[i]:
			reach += float(l)
		var mine := cull(near, base_frame(i, side, p[i * 4]).origin, reach + 0.02)
		mine.append(rod)
		if i == 0 and spec.get("trigger") is Vector3:
			_trigger_ik(p, side, spec["trigger"], spec.get("trigger_n", Vector3(0, 0, -1)),
					float(spec.get("pull", 0.0025)), mine)
			continue
		_wrap(p, i, side, mine)
	return p


## Grip pose p with only the trigger finger solved again for spec (the squeezed trigger).
static func with_trigger(p: PackedFloat32Array, side: float, shapes: Array, spec: Dictionary) -> PackedFloat32Array:
	var q := p.duplicate()
	if not (spec.get("trigger") is Vector3):
		return q
	var near := cull(shapes, base_frame(0, side, q[0]).origin, 0.12)
	_trigger_ik(q, side, spec["trigger"], spec.get("trigger_n", Vector3(0, 0, -1)), float(spec.get("pull", 0.001)), near)
	return q


## Closes digit i's joints in order. Joint k turns its own segment until that segment meets a shape
## (the later ones are placed by their own joints after it): each phalanx ends tangent to the
## handle. A segment that starts inside something (a straight continuation poking into a magazine
## or a guard; it can't be inside the convex handle it continues a tangent of) first curls until it
## is out, then on until it touches.
static func _wrap(p: PackedFloat32Array, i: int, side: float, shapes: Array) -> void:
	var n := segs(i)
	for k in n:
		for kk in range(k + 1, n):
			p[i * 4 + 1 + kk] = 0.0
		_close(p, i, side, k, float(LIMIT[i][k]), shapes)
	# Relax: a fingertip bent backwards (it met something past the handle) lets the joint before it
	# open a little instead, so the tip curls onto the obstacle like a real one.
	var last := i * 4 + n
	var tries := 0
	while p[last] < -0.03 and tries < 12 and p[last - 1] > 0.05:
		p[last - 1] -= 0.05
		p[last] = 0.0
		_close(p, i, side, n - 1, float(LIMIT[i][n - 1]), shapes)
		tries += 1


static func _close(p: PackedFloat32Array, i: int, side: float, k: int, hi: float, shapes: Array) -> void:
	var idx := i * 4 + 1 + k
	var a := p[idx]
	if not _clear_seg(i, side, p, shapes, k):
		# Escape: the first clear angle further in; failing that, the nearest one opening out (the
		# segment then rests on what blocked it from outside rather than sinking into the handle).
		var e := a
		var found := false
		while e < hi:
			e = minf(e + STEP * 0.5, hi)
			p[idx] = e
			if _clear_seg(i, side, p, shapes, k):
				found = true
				break
		if not found:
			e = a
			while e > a - 0.8:
				e -= STEP * 0.5
				p[idx] = e
				if _clear_seg(i, side, p, shapes, k):
					return
			p[idx] = a
			return
		a = e
	while a < hi:
		var b := minf(a + STEP, hi)
		p[idx] = b
		if not _clear_seg(i, side, p, shapes, k):
			for _n in 6:
				var m := (a + b) * 0.5
				p[idx] = m
				if _clear_seg(i, side, p, shapes, k):
					a = m
				else:
					b = m
			p[idx] = a
			return
		a = b
	p[idx] = hi


## Segment k of digit i clear of every shape (GAP).
static func _clear_seg(i: int, side: float, p: PackedFloat32Array, shapes: Array, k: int) -> bool:
	var pts := digit_points(i, side, p)
	var a: Vector3 = pts[k]
	var b: Vector3 = pts[k + 1]
	var r: float = float(RAD[i][k]) + GAP
	var mid := (a + b) * 0.5
	var hl := a.distance_to(b) * 0.5
	for sh: Dictionary in shapes:
		if int(sh["t"]) != PLANE and mid.distance_to(sh["c"]) > float(sh["br"]) + hl + r:
			continue
		if seg_dist(sh, a, b) < r:
			return false
	return true


## Trigger finger: the spread puts the finger's plane through the target T (the centre the pad's
## segment must pass, `gap` in front of the trigger face along n), then a search over (flex1, flex2)
## with flex3 = 0.5 flex2 brings the middle of the last phalanx through T; of the near-best poses the
## first one clear of every shape wins.
static func _trigger_ik(p: PackedFloat32Array, side: float, face: Vector3, n: Vector3, gap: float, shapes: Array) -> void:
	var r3: float = RAD[0][2]
	var t := face + n.normalized() * (r3 + gap)
	# Spread: (T - B) · flexion axis = 0 (bisection on the spread).
	var lo := -0.6
	var hi := 0.6
	for _n in 24:
		var mid := (lo + hi) * 0.5
		var f := base_frame(0, side, mid)
		var g := (t - f.origin).dot(f.basis.x)
		var f_lo := base_frame(0, side, lo)
		if signf((t - f_lo.origin).dot(f_lo.basis.x)) == signf(g):
			lo = mid
		else:
			hi = mid
	p[0] = (lo + hi) * 0.5
	var cands: Array = []
	var step := 0.1
	for a in range(-2, 13):
		for b in range(0, 21):
			var e := _trig_err(p, side, a * step, b * step, t)
			cands.append([e, a * step, b * step])
	cands.sort_custom(func(x, y): return x[0] < y[0])
	# Refine the best few on a finer grid, then take the first clear one.
	var fine: Array = []
	for c in cands.slice(0, 6):
		for da in range(-5, 6):
			for db in range(-5, 6):
				var fa: float = c[1] + da * 0.02
				var fb: float = c[2] + db * 0.02
				fine.append([_trig_err(p, side, fa, fb, t), fa, fb])
	fine.sort_custom(func(x, y): return x[0] < y[0])
	# The first clear pose among the near-best; none clear: the one with the most clearance.
	var best_c := -INF
	var best: Array = fine[0]
	for c in fine.slice(0, 48):
		p[1] = c[1]
		p[2] = c[2]
		p[3] = c[2] * 0.5
		if _clear(0, side, p, shapes, 0):
			return
		var cl := clearance(0, side, p, shapes)
		if cl > best_c:
			best_c = cl
			best = c
	p[1] = best[1]
	p[2] = best[2]
	p[3] = best[2] * 0.5


static func _trig_err(p: PackedFloat32Array, side: float, f1: float, f2: float, t: Vector3) -> float:
	var q := p.duplicate()
	q[1] = f1
	q[2] = f2
	q[3] = f2 * 0.5
	var pts := digit_points(0, side, q)
	var d := Geometry3D.get_closest_point_to_segment(t, pts[2].lerp(pts[3], 0.3), pts[2].lerp(pts[3], 0.8)).distance_to(t)
	return d * d + 1e-6 * (f1 - 0.35) * (f1 - 0.35)


## Trigger face point (model space) at height y of a trigger blade (box centre c, half depth hd,
## half height hh, tilted `th` rad about X; the VM.grip guns: (0, 0, -0.034), 0.004, 0.012, 0.25)
## and the face normal.
static func trigger_face(y: float, c := Vector3(0.0, 0.0, -0.034), hd := 0.004, hh := 0.012, th := 0.25) -> Array:
	var v := clampf((y - c.y - hd * sin(th)) / cos(th), -hh + 0.0015, hh - 0.0015)
	var pt := c + Vector3(0.0, v * cos(th) + hd * sin(th), v * sin(th) - hd * cos(th))
	return [pt, Vector3(0.0, sin(th), -cos(th))]


## Right-hand frame (model space) of a grip_right descriptor: its "at" / "axis" / "palm" frame, else
## the model origin (the VM.grip pistol grip).
static func right_frame(d: Dictionary) -> Transform3D:
	if not d.has("at"):
		return Transform3D()
	return frame_of(d, 1.0) * Transform3D(Basis(), palm_offset(1.0, float(d.get("r", R_PALM))))


## Right-hand solve spec for a grip_right descriptor ("trig_y", optional "trig_c" / "trig_hd" /
## "trig_hh" for a non-standard blade); `frame` is right_frame(d).
static func right_spec(d: Dictionary, frame: Transform3D, pull := false) -> Dictionary:
	var spec := {"spread": d.get("spread", [0.0, -0.12, -0.03, 0.1, 0.12])}
	if d.get("trigger", true) != false:
		var tf := trigger_face(float(d.get("trig_y", 0.0)), d.get("trig_c", Vector3(0.0, 0.0, -0.034)),
				float(d.get("trig_hd", 0.004)), float(d.get("trig_hh", 0.012)))
		var inv := frame.affine_inverse()
		spec["trigger"] = inv * (tf[0] as Vector3)
		spec["trigger_n"] = inv.basis * (tf[1] as Vector3)
		spec["pull"] = 0.001 if pull else 0.0022
	return spec
