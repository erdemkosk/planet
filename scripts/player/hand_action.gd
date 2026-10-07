extends Node
## Left-hand actions (child of the player; player.gd starts them on foot only and calls cancel()
## when it ragdolls or boards a vehicle):
##   El bombası (G): the left hand brings a grenade up and the pin pings out, which takes one from
##     the crafted stack Game.grenades (made at a Silahlık; none: an error, the hand stays down). The fuse
##     (GRENADE_FUSE) runs from the pin. Hold G to cook it: it beeps (faster near the end, the LED in
##     the fist blinks along) and a thin predicted arc in the team colour shows where it lands, with
##     the blast radius projected on the ground there. Release G to throw: a wind-up over the shoulder
##     and a swing; it leaves the hand along the aim (GRENADE_THROW_SPEED) with a slight lob
##     (GRENADE_LOB) plus your own velocity, with a small camera kick. Held too long, it is thrown
##     anyway GRENADE_AUTO_THROW s before it would go off. Interrupted after the pin (ragdoll,
##     vehicle, death): the live grenade drops at the hand with your velocity and still goes off.
##     Flight, bounces and the blast: scripts/items/projectiles.gd ("hand", MODE_BOUNCE) ->
##     Explosion.spawn (damage, crater, Game.blast).
##   Tünel tarayıcı (Q): the left wrist comes up into view (~1.2 s) and sends the scan pulse of
##     scripts/items/tunnel_scanner.gd (the wave, the x-ray reveal of the enemy, the wrist radar).
##     Free, Balance.SCAN_COOLDOWN between pulses; Q while it charges: an error beep and the seconds
##     left. Firing (tool_use) while the wrist is up lowers it early.
## Drives the view model's left arm (scripts/player/viewmodel.gd: left_w blend, left_target wrist,
## left_elbow forearm direction, camera space) and dips the held item (right_lower). Items can't be
## used while busy() (player.hands_busy()).
##
## API: player, left_w, left_target, left_elbow, right_lower, busy(), start_grenade(), start_scan(),
## cancel(); proj (our grenades in flight), scanner (the TunnelScanner), thrown (count).
## Multiplayer: grenade_thrown(pos, vel, fuse, cfg) fires for every grenade that leaves the hand
## (thrown or dropped). Replay it elsewhere with
## Projectiles.launch(pos, vel, "hand", Projectiles.MODE_BOUNCE, fuse, cfg). The scan is local
## (scanner.pulsed(origin) if a remote wave is wanted).

signal grenade_thrown(pos: Vector3, vel: Vector3, fuse: float, cfg: Dictionary)

const Projectiles := preload("res://scripts/items/projectiles.gd")
const VM := preload("res://scripts/player/vm_parts.gd")
## Where the grenade sits in the left fist (scripts/player/viewmodel.gd GRENADE_AT: its fingers are solved
## round a ball there).
const GRENADE_AT := Vector3(0.009, -0.04, -0.005)
const ArsenalAudio := preload("res://scripts/items/arsenal_audio.gd")
const Balance := preload("res://scripts/war/balance.gd")
const TunnelScanner := preload("res://scripts/items/tunnel_scanner.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")   # the "why not" toast: key "deny" (1)

# Left wrist targets (camera space) and forearm directions (toward the elbow).
const LOW := Vector3(-0.28, -0.6, -0.28)
const ELBOW := Vector3(-0.35, -0.8, 0.45)
const READY := Vector3(-0.2, -0.24, -0.46)
const WINDUP := Vector3(-0.27, -0.05, -0.36)
const WINDUP_ELBOW := Vector3(-0.45, -0.55, 0.7)
const RELEASE := Vector3(-0.05, -0.16, -0.68)
const RELEASE_ELBOW := Vector3(-0.25, -0.75, 0.6)
## Wrist turned to the eye: forearm across the lower left, the wrist screen ~25° left and down of
## the crosshair (the view model turns it to face the eye), the fist below the crosshair.
const WRIST := Vector3(-0.05, -0.12, -0.382)
const WRIST_ELBOW := Vector3(-0.855, -0.252, 0.453)
## Where the grenade leaves the hand (head space).
const THROW_FROM := Vector3(-0.1, -0.06, -0.55)
const PIN_POS := Vector3(-0.012, 0.055, 0.0)

# Phase lengths (s).
const T_DRAW := 0.22
const T_PIN := 0.18
const T_WINDUP := 0.14
const T_THROW := 0.13
const T_RELEASE := 0.07           # into the swing: the grenade leaves the hand
const T_RECOVER := 0.32
const T_SCAN_RAISE := 0.26
const T_SCAN_LOOK := 0.68
const T_SCAN_LOWER := 0.28

# Predicted arc: integrated like projectiles.gd (60 Hz steps, gravity of both planets, drag), one
# physics ray per RAY_STEPS steps, re-traced every ARC_RATE s and eased in between.
const ARC_POINTS := 44
const ARC_SUB := 1.0 / 60.0
const RAY_STEPS := 4
const ARC_MAX_T := 5.0
const ARC_RATE := 0.1
const TEAM_COL := Color(0.4, 0.88, 1.0)      # home side (war_hud.gd)
const RIVAL_COL := Color(1.0, 0.32, 0.2)     # rival side (MP versus)
const LAND_HALF_H := 2.5

const ARC_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 color : source_color = vec4(0.4, 0.88, 1.0, 1.0);
uniform float fade = 1.0;
uniform float total = 10.0;

void fragment() {
	float s = UV.x;                                     // metres along the arc
	float across = abs(UV.y * 2.0 - 1.0);
	float core = 1.0 - smoothstep(0.3, 1.0, across);
	float f = fract(s * 0.85 - TIME * 1.6);
	float dash = smoothstep(0.08, 0.2, f) * (1.0 - smoothstep(0.62, 0.74, f));
	float start = smoothstep(0.5, 2.4, s);
	float tail = 1.0 - 0.4 * smoothstep(total - 1.5, total, s);
	ALBEDO = color.rgb * 1.15;
	ALPHA = clamp(core * (0.16 + 0.5 * dash) * start * tail * fade * color.a, 0.0, 1.0);
}
"""

## Landing marker: a deferred decal (the back faces of a box around the landing point, drawn without
## a depth test; each pixel rebuilds the scene point behind it from the depth buffer), so the blast
## ring lies on whatever ground is there. Dashed ring at the blast radius, a faint fill, a centre
## target, a ripple running out at the beep tempo. Pixels near the eye (the arms) are skipped.
const LAND_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 color : source_color = vec4(0.4, 0.88, 1.0, 1.0);
uniform float radius = 5.0;
uniform float half_h = 2.5;
uniform float fade = 1.0;
uniform float urgency = 0.0;

varying vec3 v_c;
varying vec3 v_x;
varying vec3 v_y;
varying vec3 v_z;

void vertex() {
	v_c = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_x = normalize((MODELVIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz);
	v_y = normalize((MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	v_z = normalize((MODELVIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 p = vp.xyz / vp.w;
	if (-p.z < 0.9) {
		discard;
	}
	vec3 d = p - v_c;
	vec3 l = vec3(dot(d, v_x), dot(d, v_y), dot(d, v_z));
	float r = length(l.xz);
	if (r > radius * 1.12 || abs(l.y) > half_h) {
		discard;
	}
	float aa = clamp(fwidth(r), 0.004, radius * 0.05);
	float ang = atan(l.z, l.x);
	float dash = step(0.32, fract(ang / 6.2831853 * 28.0 + TIME * 0.15));
	float rim = (1.0 - smoothstep(aa * 0.7, aa * 1.9, abs(r - radius))) * dash;
	float fill = (1.0 - smoothstep(radius * 0.15, radius, r)) * 0.05 + smoothstep(radius * 0.55, radius, r) * step(r, radius) * 0.07;
	float dot_c = 1.0 - smoothstep(0.09, 0.09 + aa * 2.0, r);
	float ring_c = 1.0 - smoothstep(aa * 0.6, aa * 1.8, abs(r - 0.42));
	float rr = fract(TIME * mix(0.7, 2.6, urgency)) * radius;
	float ripple = (1.0 - smoothstep(0.0, 0.18 + aa, abs(r - rr))) * (1.0 - rr / radius) * 0.4;
	float fy = 1.0 - smoothstep(half_h * 0.6, half_h, abs(l.y));
	float a = (rim * 0.6 + fill + dot_c * 0.85 + ring_c * 0.55 + ripple) * fy * fade;
	ALBEDO = color.rgb * 1.15;
	ALPHA = clamp(a * color.a, 0.0, 1.0);
}
"""

var player
var left_w := 0.0
var left_target := LOW
var left_elbow := ELBOW
var right_lower := 0.0
var state := ""                 # "", "grenade", "scan"
var phase := ""
var proj: Node3D                # scripts/items/projectiles.gd: our grenades in flight
var scanner: Node3D             # scripts/items/tunnel_scanner.gd
var thrown := 0

var _t := 0.0
var _fuse := 0.0
var _beep_t := 0.0
var _led := 0.0
var _pin_out := false
var _released := false
var _failed := false
var _pin_t := -1.0
var _tap := 0.0
var _tap_v := 0.0
var _from_w := 0.0
var _from_target := LOW
var _from_elbow := ELBOW
var _from_lower := 0.0
var _grenade_vm: Node3D
var _pin_vm: Node3D
var _led_mat: ShaderMaterial
# Sounds (built on a worker thread).
var _audio: Array = []
var _ai := 0
var _task := -1
var _mutex := Mutex.new()
var _ready_snd := {}
# Predicted arc + landing marker.
var _arc: MeshInstance3D
var _arc_mesh: ImmediateMesh
var _arc_mat: ShaderMaterial
var _land: MeshInstance3D
var _land_mat: ShaderMaterial
var _arc_tgt := PackedVector3Array()
var _arc_disp := PackedVector3Array()
var _arc_fade := 0.0
var _arc_timer := 0.0
var _arc_fresh := true
var _hit := false
var _hit_p := Vector3.ZERO
var _hit_n := Vector3.UP
var _land_p := Vector3.ZERO
var _land_n := Vector3.UP
var _land_a := 0.0
# One-time controls hint.
static var _hinted := false
var _hint_t := 7.0


func _ready() -> void:
	proj = Projectiles.new()
	proj.player = player
	add_child(proj)
	scanner = TunnelScanner.new()
	scanner.player = player
	add_child(scanner)
	for i in 3:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_audio.append(p)
	_task = WorkerThreadPool.add_task(_build_snd, false, "hand_audio")
	_build_arc()


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _build_snd() -> void:
	var gen := ArsenalAudio.new()
	var out := {}
	for n in ["pin", "spoon", "beep", "cloth"]:
		out[n] = gen.make(n)
	_mutex.lock()
	_ready_snd = out
	_mutex.unlock()


## True while the left hand is in use (items can't fire). The tail of putting the hand back is free.
func busy() -> bool:
	if state == "":
		return false
	if (phase == "recover" or phase == "lower") and left_w < 0.35:
		return false
	return true


func explosion_cfg() -> Dictionary:
	return {"radius": Balance.GRENADE_RADIUS, "damage": Balance.GRENADE_DAMAGE, "impulse": Balance.GRENADE_IMPULSE,
			"self_mult": 0.6, "crater": Balance.GRENADE_CRATER, "direct": Balance.GRENADE_DIRECT,
			"player_owned": true, "team": _team()}


## Our side ("home" for the local player; Game.team_of reads a "team" property / meta if MP sets one).
func _team() -> String:
	var t := Game.team_of(player) if player != null else ""
	return t if t != "" else "home"


## G pressed: bring a grenade up (hold G to cook it, release to throw).
func start_grenade() -> void:
	if busy() or not _can_act():
		return
	if Game.grenades <= 0:
		_deny("Bomban yok — Silahlık'tan satın al")
		return
	_ensure_props()
	var col := TEAM_COL if _team() == "home" else RIVAL_COL
	_arc_mat.set_shader_parameter("color", col)
	_land_mat.set_shader_parameter("color", col)
	_begin("grenade", "draw")
	_fuse = Balance.GRENADE_FUSE
	_beep_t = 0.0
	_led = 0.0
	_pin_out = false
	_released = false
	_failed = false
	_pin_t = -1.0
	if _pin_vm != null:
		_pin_vm.position = PIN_POS
		_pin_vm.rotation = Vector3.ZERO
	_play("cloth", -14.0, 1.1)


## Q pressed: raise the wrist and send a scan pulse (or say how long it still charges).
func start_scan() -> void:
	if not _can_act() or scanner == null or state == "scan":
		return
	if busy():
		return
	if not scanner.can_pulse():
		scanner.deny()
		return
	_begin("scan", "raise")
	_tap = 0.0
	_tap_v = 0.0
	_play("cloth", -16.0, 1.25)
	if Game.sfx:
		Game.sfx.play("servo", -24.0, 1.15)


## Drop whatever the hand is doing (death, ragdoll, entering a vehicle). A grenade whose pin is out
## falls from the hand and still goes off.
func cancel() -> void:
	if state == "grenade" and _pin_out and not _released:
		_release(true)
	state = ""
	phase = ""
	left_w = 0.0
	right_lower = 0.0
	_pin_t = -1.0
	if _grenade_vm != null:
		_grenade_vm.visible = false
	if scanner != null:
		scanner.wrist_up = false


func _process(delta: float) -> void:
	_tick_hint(delta)
	if state != "" and not _can_act():
		cancel()
	if scanner != null:
		scanner.wrist_up = state == "scan" and phase != "lower"
	_update_arc(delta)
	if state == "" and left_w <= 0.0 and right_lower <= 0.0 and _pin_t < 0.0:
		return
	_t += delta
	match state:
		"grenade":
			_tick_grenade(delta)
		"scan":
			_tick_scan(delta)
		_:
			left_w = move_toward(left_w, 0.0, delta * 4.0)
			right_lower = move_toward(right_lower, 0.0, delta * 3.0)
	_update_props(delta)


func _can_act() -> bool:
	return player != null and is_instance_valid(player) and player.vehicle == null \
			and not player.is_ragdolled() and not player.is_dead()


func _held() -> bool:
	return Input.is_action_pressed("throw_grenade")


# --- Grenade ------------------------------------------------------------------------------------

func _tick_grenade(delta: float) -> void:
	if _pin_out:
		_fuse -= delta
	if _pin_out and (phase == "pin" or phase == "hold"):
		_beep_t -= delta
		if _beep_t <= 0.0:
			var fresh := clampf((_fuse - 0.6) / 2.4, 0.0, 1.0)        # 1 just pulled .. 0 about to go
			_beep_t = lerpf(0.15, 0.8, fresh)
			_play("beep", lerpf(-10.0, -17.0, fresh), lerpf(1.35, 1.0, fresh))
			_led = 1.0
	match phase:
		"draw":
			_blend(READY, ELBOW, 1.0, 0.8, _ease(_t / T_DRAW))
			if _t >= T_DRAW:
				# The pin is out: one grenade of the crafted stack is spent (thrown or dropped).
				if not Game.take_grenade():
					_failed = true
					_deny("Bomban yok — Silahlık'tan satın al")
					_next("recover")
					return
				_pin_out = true
				_pin_t = 0.0
				_beep_t = 0.3
				_play("pin", -8.0, 1.0)
				_next("pin")
		"pin":
			left_target = READY + Vector3(0.0, 0.015 * sin(minf(_t / 0.12, 1.0) * PI), 0.0)
			if _t >= T_PIN:
				_next("hold")
		"hold":
			# The hand trembles a little more the longer it cooks.
			var cook := 1.0 - clampf(_fuse / Balance.GRENADE_FUSE, 0.0, 1.0)
			var amp := 0.0015 + 0.004 * cook * cook
			left_target = READY + Vector3(sin(_t * 2.3) * 0.004 + sin(_t * 23.0) * amp,
					sin(_t * 3.1) * 0.003 + sin(_t * 19.0 + 1.0) * amp, 0.0)
			if not _held() or _fuse <= Balance.GRENADE_AUTO_THROW + T_WINDUP + T_RELEASE:
				_next("windup")
				_kick_cam(Vector3(0.008, 0.006, 0.01))
				_play("cloth", -17.0, 1.35)
		"windup":
			_blend(WINDUP, WINDUP_ELBOW, 1.0, 0.8, _ease(_t / T_WINDUP))
			if _t >= T_WINDUP:
				_next("throw")
				if Game.sfx:
					Game.sfx.play("whoosh", -15.0, 1.3)
		"throw":
			_blend(RELEASE, RELEASE_ELBOW, 1.0, 0.8, _ease_out(_t / T_THROW))
			if _t >= T_RELEASE and not _released:
				_release(false)
			if _t >= T_THROW:
				_next("recover")
		"recover":
			_blend(LOW, ELBOW, 0.0, 0.0, _ease(_t / T_RECOVER))
			if _t >= T_RECOVER:
				_end()


## Lets go of the grenade: thrown along the view (or dropped at the hand when interrupted).
func _release(drop: bool) -> void:
	_released = true
	if _grenade_vm != null:
		_grenade_vm.visible = false
	var fuse := maxf(_fuse, 0.05)
	var pos: Vector3
	var vel: Vector3
	if drop:
		pos = _hand_world()
		vel = player.velocity
	else:
		var s := _throw_state()
		pos = s[0]
		vel = s[1]
		_kick_cam(Vector3(-0.02, -0.012, -0.018))
	var cfg := explosion_cfg()
	proj.launch(pos, vel, "hand", Projectiles.MODE_BOUNCE, fuse, cfg)
	thrown += 1
	grenade_thrown.emit(pos, vel, fuse, cfg)
	_play("spoon", -12.0, 1.0)


## [start position, velocity] of a throw right now: from the hand along the aim (the head, without
## the camera shake) with the lob and our own velocity. Never starts inside a wall in front of us.
func _throw_state() -> Array:
	var hx: Transform3D = player.head.global_transform
	var b := hx.basis.orthonormalized()
	var pos := hx.origin + b * THROW_FROM
	var q := PhysicsRayQueryParameters3D.create(hx.origin, pos, _mask(), [player.get_rid()])
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		pos = hx.origin + ((hit["position"] as Vector3) - hx.origin) * 0.7
	var vel: Vector3 = -b.z * Balance.GRENADE_THROW_SPEED + b.y * Balance.GRENADE_LOB + player.velocity
	return [pos, vel]


func _hand_world() -> Vector3:
	if _grenade_vm != null and is_instance_valid(_grenade_vm) and _grenade_vm.is_inside_tree() and player.camera != null:
		return VM.vm_to_world(player.camera, _grenade_vm.global_position)
	return player.global_position + player.global_transform.basis.y * 1.2


static func _mask() -> int:
	return Game.LAYER_TERRAIN | Game.LAYER_SHIP | Game.LAYER_VEHICLE


# --- Wrist scan ---------------------------------------------------------------------------------

func _tick_scan(delta: float) -> void:
	# Wrist "tap" when the pulse goes out: a small spring.
	_tap_v += (-_tap * 260.0 - _tap_v * 20.0) * delta
	_tap += _tap_v * delta
	match phase:
		"raise":
			var k := _ease(_t / T_SCAN_RAISE)
			var kb := _ease_back(_t / T_SCAN_RAISE)
			left_target = _from_target.lerp(WRIST, kb)
			left_elbow = _from_elbow.lerp(WRIST_ELBOW, k)
			left_w = lerpf(_from_w, 1.0, k)
			right_lower = lerpf(_from_lower, 0.45, k)
			if _t >= T_SCAN_RAISE:
				_next("look")
				_tap_v = 9.0
				if scanner != null:
					scanner.pulse()
		"look":
			left_target = WRIST + Vector3(sin(_t * 1.7) * 0.002, sin(_t * 2.3) * 0.0015 + _tap * 0.012, _tap * 0.01)
			if _t >= T_SCAN_LOOK or Input.is_action_just_pressed("tool_use"):
				_next("lower")
		"lower":
			_blend(LOW, ELBOW, 0.0, 0.0, _ease(_t / T_SCAN_LOWER))
			if _t >= T_SCAN_LOWER:
				_end()


# --- Pose helpers -------------------------------------------------------------------------------

## Starts an action from wherever the arm is now (so one can follow the tail of another).
func _begin(st: String, ph: String) -> void:
	state = st
	_next(ph)


func _next(p: String) -> void:
	phase = p
	_t = 0.0
	_from_w = left_w
	_from_target = left_target
	_from_elbow = left_elbow
	_from_lower = right_lower


func _blend(target: Vector3, elbow: Vector3, w: float, lower: float, k: float) -> void:
	left_target = _from_target.lerp(target, k)
	left_elbow = _from_elbow.lerp(elbow, k)
	left_w = lerpf(_from_w, w, k)
	right_lower = lerpf(_from_lower, lower, k)


func _end() -> void:
	state = ""
	phase = ""


func _deny(msg: String) -> void:
	if Game.sfx:
		Game.sfx.play("error", -10.0)
	if Game.hud:
		HudLevel.alert(msg, 1, "deny", 1.8)


func _kick_cam(v: Vector3) -> void:
	var p = player.get("_punch")
	if p is Vector3:
		player.set("_punch", p + v)


static func _ease(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


static func _ease_out(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return 1.0 - (1.0 - x) * (1.0 - x) * (1.0 - x)


## Ease out with a small overshoot (~5 %) that settles back: a snappy raise.
static func _ease_back(x: float) -> float:
	x = clampf(x, 0.0, 1.0) - 1.0
	return 1.0 + 2.2 * x * x * x + 1.2 * x * x


# --- First-person grenade in the fist -------------------------------------------------------------

func _ensure_props() -> void:
	if _grenade_vm != null and is_instance_valid(_grenade_vm):
		return
	if player == null or player.viewmodel == null or player.viewmodel.get("left_hand") == null:
		return
	var lh: Node3D = player.viewmodel.left_hand
	# White body with two grooves, orange band, dark fuse head, the spoon along the side, the pin ring
	# and a red LED on top (blinks with the beeps once the pin is out).
	_grenade_vm = VM.node(lh, GRENADE_AT)      # in the palm; the fingers are solved round it
	var g := VM.node(_grenade_vm)
	VM.ellipsoid(g, Vector3.ZERO, Vector3(0.031, 0.037, 0.031), VM.plastic_white())
	VM.seg(g, Vector3(0, -0.006, 0), Vector3(0, 0.006, 0), 0.0322, 0.0322, VM.suit_orange(), 16)
	for y in [-0.018, 0.018]:
		VM.ring(g, Vector3(0, y, 0), Vector3.UP, 0.0278, 0.0011, VM.dark_metal())
	VM.seg(g, Vector3(0, 0.033, 0), Vector3(0, 0.052, 0), 0.012, 0.011, VM.dark_metal(), 12)
	VM.box(g, Vector3(0.016, 0.03, 0), Vector3(0.006, 0.05, 0.012), VM.metal(), Basis(Vector3.FORWARD, -0.25))
	VM.box(g, Vector3(0.0215, 0.006, 0), Vector3(0.004, 0.022, 0.01), VM.metal(), Basis(Vector3.FORWARD, -0.08))
	VM.bake(g)
	_led_mat = VM.glow(Color(1.0, 0.16, 0.1), 0.15)
	VM.sphere(_grenade_vm, Vector3(0, 0.0545, 0), 0.0042, _led_mat)
	_pin_vm = VM.node(_grenade_vm, PIN_POS)
	VM.ring(_pin_vm, Vector3(-0.012, 0.0, 0.0), Vector3.FORWARD, 0.011, 0.0022, VM.metal())
	VM.seg(_pin_vm, Vector3(-0.001, 0.0, 0.0), Vector3(0.014, 0.0, 0.0), 0.0012, 0.0012, VM.metal(), 6)
	_grenade_vm.visible = false


func _update_props(delta: float) -> void:
	if _grenade_vm == null or not is_instance_valid(_grenade_vm):
		return
	var show := state == "grenade" and not _released and not _failed and phase != "recover"
	_grenade_vm.visible = show
	_led = move_toward(_led, 0.0, delta * 9.0)
	if _led_mat != null:
		_led_mat.set_shader_parameter("energy", (0.5 + 7.0 * _led) if _pin_out else 0.15)
	if _pin_vm == null:
		return
	# The pin is flicked off by the thumb: it flies up and away (hand space) and is gone.
	if _pin_t >= 0.0:
		_pin_t += delta
		var t := _pin_t
		_pin_vm.position = PIN_POS + Vector3(-0.3, 0.42, 0.14) * t + Vector3(0.0, -1.5, 0.0) * t * t
		_pin_vm.rotation = Vector3(t * 9.0, t * 4.0, t * 26.0)
		if t > 0.3:
			_pin_t = -1.0
	_pin_vm.visible = (show and not _pin_out) or _pin_t >= 0.0


# --- Predicted arc --------------------------------------------------------------------------------

func _build_arc() -> void:
	_arc_mesh = ImmediateMesh.new()
	_arc = MeshInstance3D.new()
	_arc.mesh = _arc_mesh
	_arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arc.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_arc_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = ARC_SHADER
	_arc_mat.shader = sh
	_arc_mat.set_shader_parameter("color", TEAM_COL)
	_arc.material_override = _arc_mat
	_arc.visible = false
	add_child(_arc)
	_land = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	_land.mesh = bm
	_land.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_land.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_land_mat = ShaderMaterial.new()
	var sh2 := Shader.new()
	sh2.code = LAND_SHADER
	_land_mat.shader = sh2
	_land_mat.set_shader_parameter("color", TEAM_COL)
	_land_mat.set_shader_parameter("radius", Balance.GRENADE_RADIUS)
	_land_mat.set_shader_parameter("half_h", LAND_HALF_H)
	_land.material_override = _land_mat
	_land.visible = false
	add_child(_land)


func _update_arc(delta: float) -> void:
	var want := state == "grenade" and _pin_out and not _released and (phase == "pin" or phase == "hold") \
			and player != null and player.camera != null
	_arc_fade = move_toward(_arc_fade, 1.0 if want else 0.0, delta * (5.0 if want else 9.0))
	if _arc_fade <= 0.0:
		if _arc.visible:
			_arc.visible = false
			_land.visible = false
			_arc_mesh.clear_surfaces()
		_arc_fresh = true
		_land_a = 0.0
		return
	if want:
		_arc_timer -= delta
		if _arc_timer <= 0.0 or _arc_fresh:
			_arc_timer = ARC_RATE
			_trace_arc()
			if _arc_fresh:
				_arc_disp = _arc_tgt.duplicate()
				_land_p = _hit_p
				_land_n = _hit_n
				_arc_fresh = false
	if _arc_disp.size() != _arc_tgt.size():
		_arc_disp = _arc_tgt.duplicate()
	var k := 1.0 - exp(-16.0 * delta)
	for i in _arc_disp.size():
		_arc_disp[i] = _arc_disp[i].lerp(_arc_tgt[i], k)
	_land_p = _land_p.lerp(_hit_p, k)
	var ln := _land_n.lerp(_hit_n, k)
	_land_n = ln.normalized() if ln.length_squared() > 1e-6 else _hit_n
	_land_a = move_toward(_land_a, 1.0 if _hit else 0.0, delta * 6.0)
	_arc.visible = true
	_draw_ribbon()
	_arc_mat.set_shader_parameter("fade", _arc_fade)
	_land.visible = _land_a > 0.01
	if _land.visible:
		var b := VM.basis_y(_land_n)
		var d := Balance.GRENADE_RADIUS * 2.3
		_land.global_transform = Transform3D(Basis(b.x * d, b.y * LAND_HALF_H * 2.0, b.z * d), _land_p)
		_land_mat.set_shader_parameter("fade", _arc_fade * _land_a)
		_land_mat.set_shader_parameter("urgency", 1.0 - clampf((_fuse - 0.6) / 2.4, 0.0, 1.0))


## Integrates a throw made now (the same steps as projectiles.gd) until the first contact or the
## moment the fuse would run out, and resamples it to ARC_POINTS points evenly in time.
func _trace_arc() -> void:
	var s := _throw_state()
	var p: Vector3 = s[0]
	var v: Vector3 = s[1]
	var fuse_at_release := maxf(_fuse - T_WINDUP - T_RELEASE, 0.05)
	var t_max := minf(ARC_MAX_T, fuse_at_release)
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var ex := [player.get_rid()]
	var mask := _mask()
	var pts := PackedVector3Array([p])
	var times := PackedFloat32Array([0.0])
	var t := 0.0
	_hit = false
	var ray_from := p
	var ray_t := 0.0
	var n := 0
	while t < t_max:
		v += Game.gravity_at(p) * ARC_SUB
		v *= 1.0 - 0.015 * ARC_SUB
		p += v * ARC_SUB
		t += ARC_SUB
		n += 1
		if n % RAY_STEPS != 0 and t < t_max:
			continue
		var q := PhysicsRayQueryParameters3D.create(ray_from, p, mask, ex)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var hp: Vector3 = hit["position"]
			var seg := ray_from.distance_to(p)
			var f := ray_from.distance_to(hp) / seg if seg > 1e-5 else 1.0
			t = ray_t + (t - ray_t) * f
			pts.append(hp)
			times.append(t)
			_hit = true
			_hit_p = hp
			_hit_n = hit["normal"]
			break
		pts.append(p)
		times.append(t)
		ray_from = p
		ray_t = t
	if not _hit:
		_hit_p = pts[pts.size() - 1]
		_hit_n = _up_at(_hit_p)
	var tgt := PackedVector3Array()
	tgt.resize(ARC_POINTS)
	var j := 0
	var t_end: float = times[times.size() - 1]
	for i in ARC_POINTS:
		var tt := t_end * float(i) / float(ARC_POINTS - 1)
		while j < times.size() - 2 and times[j + 1] < tt:
			j += 1
		if times.size() < 2:
			tgt[i] = pts[0]
			continue
		var span := maxf(times[j + 1] - times[j], 1e-5)
		tgt[i] = pts[j].lerp(pts[j + 1], clampf((tt - times[j]) / span, 0.0, 1.0))
	_arc_tgt = tgt


static func _up_at(pos: Vector3) -> Vector3:
	var b := Game.dominant_body(pos)
	var u := pos - (b.global_position if b != null else Game.planet_center())
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


## Camera-facing ribbon along the eased arc; about constant on-screen width.
func _draw_ribbon() -> void:
	_arc_mesh.clear_surfaces()
	var n := _arc_disp.size()
	if n < 2:
		return
	var cam_p: Vector3 = player.camera.global_position
	_arc_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var s := 0.0
	for i in n:
		var p := _arc_disp[i]
		if i > 0:
			s += p.distance_to(_arc_disp[i - 1])
		var tan := _arc_disp[mini(i + 1, n - 1)] - _arc_disp[maxi(i - 1, 0)]
		var to_cam := cam_p - p
		var side := tan.cross(to_cam)
		side = side.normalized() if side.length_squared() > 1e-10 else Vector3.RIGHT
		var w := 0.006 + 0.0016 * to_cam.length()
		_arc_mesh.surface_set_uv(Vector2(s, 0.0))
		_arc_mesh.surface_add_vertex(p - side * w)
		_arc_mesh.surface_set_uv(Vector2(s, 1.0))
		_arc_mesh.surface_add_vertex(p + side * w)
	_arc_mesh.surface_end()
	_arc_mat.set_shader_parameter("total", s)


# --- Misc ---------------------------------------------------------------------------------------

## Once per session, after spawning: what G and Q do.
## (The one-time "G: El bombası · Q: Tünel tarayıcı" toast is gone: the HUD quickbar has G / Q slots.)
func _tick_hint(_delta: float) -> void:
	_hinted = true


func _play(name: String, vol: float, pitch: float) -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_mutex.lock()
	var st = _ready_snd.get(name)
	_mutex.unlock()
	if st == null or _audio.is_empty():
		return
	var p: AudioStreamPlayer = _audio[_ai]
	_ai = (_ai + 1) % _audio.size()
	p.stream = st
	p.volume_db = vol
	p.pitch_scale = pitch
	p.play()
