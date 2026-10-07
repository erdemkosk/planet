extends "res://scripts/items/item.gd"
## Tüfek (key 3, crafted at a Silahlık) firing real bullets: ballistic projectiles with drop (Game.gravity_at) and tracers.
## Ammo types (each keeps its own loaded magazine in the gun; reserves live in Game.ammo and a
## reload buys any shortfall from material, Game.take_ammo):
##   STANDART      full-metal-jacket: TEK (single shots), SERİ (full auto, 9 rounds/s) or ÜÇLÜ (3-round burst)
##   DELİCİ        armor-piercing, heavy hit, punches through one target
## Timing is deliberately realistic: 0.6 s draw, ~0.3 s raise to the iron sights (spring with a
## small overshoot), 0.25 s sprint-to-fire, 2.4 s tactical / 3.0 s empty reload, and switching
## ammo means a magazine change. LMB fires, RMB aims (rear aperture + front post on the screen
## center, mild zoom, half walking speed), R reloads, T switches ammo, B cycles the fire mode (fire_mode: TEK -> SERİ -> ÜÇLÜ;
## set_fire_mode(), effective_fire_mode(), mode_text(); Delici is single shot only). Hold the middle
## mouse button: the attachment radial (scripts/ui/attachment_radial.gd; scripts/items/attachments.gd:
## muzzle / optic / underbarrel on mounts built in build_model, `att_kit`, get_attachments() /
## set_attachments(), signal attachments_changed, save_state()["att"]).
## Recoil (2026-10-05, "geri tepmeyi iyi hissedelim, seri atışta"; MW 2019 the bar): RECOIL_VIEW of each
## round's camera kick climbs the VIEW (gun_feel.gd Climb: you pull down against it; the rest you did
## not pull back recovers after the string), the rest is a snap on the _recoil spring; a bigger first
## round (RECOIL_FIRST), a steadier string; full auto ~27° over a magazine if not pulled down.
## Each shot: recorded gunshot + low body + sub-bass punch + bolt clack + outdoor tail and terrain
## slap-back, camera kick (with a little roll) that snaps in and recovers fast, 6-8 cm kickback and
## muzzle climb, bolt cycling, muzzle flash, light, smoke and brass. Hits on anything in group
## "damageable" go through Game.damage_target (the AI rival bot later). Reloads (2026-10-07, "MW gibi
## değil, yapay"): a keyed choreography (scripts/items/reload_anim.gd): the gun cants and rolls toward
## the left hand, which strips the magazine with the thumb on the release, takes it below the frame to
## the pouch, brings the new one up, front lip first, rocks and seats it (the gun bumps), slaps it; an
## empty one drops free (scripts/items/mag_drop.gd) and the palm slaps the bolt catch; head motion,
## a secondary spring, randomized timing / amplitude.
## Shared feel (scripts/items/gun_feel.gd, same as the weapon_base guns): a learnable recoil pattern
## (RECOIL_H, a steady climb per shot of a string, camera hold-then-recover), first-shot accuracy,
## stance modifiers, view-model inertia, head zone (×2), kill launch, hit reactions, suit impacts,
## kill feed; in vacuum only the suit-borne thump.
## Handling (scripts/items/handling.gd, `_hd`): wall pull-back (aim eased out, no fire when fully
## back), inspect (hold Y: the left hand checks the magazine), aim-in / out foley, melee_interrupt().

const Settings := preload("res://scripts/save/settings.gd")
const GunFeel := preload("res://scripts/items/gun_feel.gd")
## Horizontal recoil pattern (× kick_yaw per round of a string, 30 = a magazine): a drift to the
## right over the first rounds, back across to the left, then right again (an S you can learn).
const RECOIL_H := [0.0, 0.3, 0.5, 0.7, 0.6, 0.4, 0.1, -0.3, -0.6, -0.9, -1.0, -0.9, -0.6, -0.3, 0.0, 0.3, 0.6, 0.7,
		0.6, 0.3, -0.1, -0.4, -0.6, -0.5, -0.2, 0.2, 0.5, 0.5, 0.3, 0.0]
const WEIGHT := 1.0                    # mobility factor while held (item.gd carry_weight; loadout)
const RECOIL_CLIMB := 0.12             # a steady string (was 0.35: each round kicked harder)
const RECOIL_FIRST := 1.45             # the first round's snap
const RECOIL_VIEW := 0.74              # share of the camera kick that climbs the view (the rest springs back)
const RECOIL_HOLD := 0.08             # (2026-10-06 tok: 0.06 -> 0.08: the snap holds a beat longer)
const Attachments := preload("res://scripts/items/attachments.gd")
const AttachmentRadial := preload("res://scripts/ui/attachment_radial.gd")
const ScreenPunch := preload("res://scripts/items/screen_punch.gd")
const FIRST_SHOT_REST := 0.35
const HEAD_MULT := 2.0
const RifleFx := preload("res://scripts/items/rifle_fx.gd")
const Snd := preload("res://scripts/audio/snd_lib.gd")
const RifleHud := preload("res://scripts/items/rifle_hud.gd")
const WeaponAudio := preload("res://scripts/items/weapon_audio.gd")
const Viewmodel := preload("res://scripts/player/viewmodel.gd")
const HitFeel := preload("res://scripts/items/hit_feel.gd")
const Handling := preload("res://scripts/items/handling.gd")   # wall pull-back, inspect (Y), aim foley, melee (V)

const HIP_FOV := 75.0
const ADS_FOV := 58.0
const SIGHT_Y := 0.134                               # sight line height in the gun frame (tall: the receiver stays under the view when aiming)
const SIGHT_REAR := Vector3(0.0, SIGHT_Y, 0.03)      # rear sight aperture centre (gez)
const SIGHT_FRONT_Z := -0.43                         # front sight post (arpacık)
const ADS_EYE := Vector3(0.0, 0.0, -0.115)           # rear notch position in camera space when aiming (eye relief ~11 cm: the stock passes behind the eye)
# Weapon poses in camera space (the grip is the rig origin, the gun points along its -Z).
const HIP_POS := Vector3(0.165, -0.215, -0.4)        # grip at the hip: low right, stock to the shoulder
const HIP_CONVERGE := 11.0                            # bore aims at the crosshair this far ahead (m)
const HIP_CANT := 0.07                                # slight inward roll
const SPRINT_POS := Vector3(0.15, -0.16, -0.4)
const SPRINT_ROT := Vector3(-0.2, 0.62, 0.3)          # lowered, muzzle across the body, canted
const RELOAD_POS := Vector3(0.15, -0.2, -0.4)
const RELOAD_ROT := Vector3(0.1, 0.2, 0.3)            # tilted to show the magazine well
const RECOIL_PIVOT := Vector3(0.0, 0.05, 0.24)        # the gun rotates about the stock
const AIM_SPEED := 0.5                               # walking speed multiplier while aiming
const SPRINT_TO_FIRE := 0.25
const MAG_REST := Vector3(0.0, 0.02, -0.085)
const MAG_AXIS := Vector3(0.0, -0.993, -0.12)        # magazine slides out along this (model space)
# Reload choreography (scripts/items/reload_anim.gd; RELOAD_POS / RELOAD_ROT above are no longer used).
const ReloadAnim := preload("res://scripts/items/reload_anim.gd")
const MagDrop := preload("res://scripts/items/mag_drop.gd")
const VMHand := preload("res://scripts/player/vm_hand.gd")
## Where the left hand holds the magazine (magazine space, a grip descriptor like grip_left): the hand's
## index edge 3 cm above the body's centre, the palm on its left side; the fingers' wrap is solved
## against the magazine's own shapes (viewmodel.gd, left_hold), all clear by 0.8 mm.
const MAG_HOLD := {"at": Vector3(0.0, -0.0132, -0.0002), "axis": Vector3(0.0, 0.9928, 0.1197), "palm": Vector3(-1.0, 0.0, 0.0), "r": 0.018}
const MAG_LIP := Vector3(0.0, 0.006, -0.022)          # front lip (magazine space): goes in first
const MAG_BASE := Vector3(0.0, -0.0944, -0.0153)      # base plate bottom (magazine space): the slap
const MAG_BOX_C := Vector3(0.0, -0.05, -0.006)        # dropped magazine's collision box (magazine space)
const MAG_BOX_S := Vector3(0.034, 0.112, 0.055)
const BOLT_CATCH := Vector3(-0.027, 0.03, -0.075)     # bolt catch, left side above the well (empty reloads)
const RELOAD_PIVOT := Vector3(0.0, 0.03, -0.07)       # the reload offset turns about the receiver over the well
const RELOAD_POUCH := Vector3(-0.17, -0.55, -0.26)    # camera space: the belt pouch, below the frame

## dmg per round (player hp 100); impulse = shove on a hit body (x 0.15, m/s); pierce = bodies an
## AP round passes through; roll = camera roll kick; burst_kick = camera kick × of the 2nd / 3rd round
## of a burst. "punch" / "armor" / "stun" are unused for now.
## 2026-10-05 the user found the guns weak ("silahlar güçsüz", "öldürmek uzun"): Standart 38 -> 40
## (still 3 body / 2 head on a 100 hp bot, with margin), Delici 88 -> 95 (2 body / 1 head); the camera
## kick the player has to pull down is about 40 % smaller (3.3° -> 1.9° a round: follow-up rounds and
## bursts land where you aim) while the visible gun kick, shake and FOV punch got bigger; harder
## shoves on survivors (impulse).
## 2026-10-06 tok ("vuruşlar ... çok daha tok olsun"; hp 100 -> 135: Standart 4 body / 2 head, Delici
## 2 / 1): rates ~-13 % (Standart 5.5 / 11 / 9 -> 4.8 / 9.5 / 7.8, Delici 2.2 -> 1.95), the camera kick
## × 1.15 and the visible gun kick × 1.2 (gun_feel.gd KICK_K / GUN_KICK_K, the weapon_base guns' share).
const AMMO := [
	{"id": "ammo_std", "name": "STANDART", "short": "STD", "title": "Standart Mermi (FMJ)",
		"color": Color(1.0, 0.78, 0.38), "dmg": 40.0, "rate": 4.8, "auto": false, "mag": 30, "burst_rate": 9.5,
		"auto_rate": 7.8, "auto_kick": 0.8,
		"reload": 2.4, "reload_empty": 3.0, "speed": 780.0, "spread": 0.0105, "ads_spread": 0.0003,
		"kick_pitch": 0.039, "kick_yaw": 0.021, "roll": 0.014, "vm_kick": 0.75, "gun_kick": 9.0, "shake": 0.5,
		"fov_punch": -2.8, "stun": 0.0, "impulse": 9.0, "punch": 1.0, "armor": 0.15, "noise": 50.0, "pierce": 0,
		"dart": false, "sound": "shot", "flash": 1.25, "sub": -7.0, "burst_kick": 0.55},
	{"id": "ammo_ap", "name": "DELİCİ", "short": "DLC", "title": "Delici Mermi (AP)",
		"color": Color(1.0, 0.45, 0.3), "dmg": 95.0, "rate": 1.95, "auto": false, "mag": 10,
		"reload": 2.5, "reload_empty": 3.1, "speed": 850.0, "spread": 0.008, "ads_spread": 0.0002,
		"kick_pitch": 0.067, "kick_yaw": 0.025, "roll": 0.024, "vm_kick": 1.3, "gun_kick": 12.6, "shake": 0.75,
		"fov_punch": -4.2, "stun": 0.0, "impulse": 16.0, "punch": 1.6, "armor": 0.7, "noise": 65.0, "pierce": 1,
		"dart": false, "sound": "heavy", "flash": 1.7, "sub": -4.0},
]
## A click during the cooldown is kept this long and fires the moment the gun is ready (a fast
## clicker no longer loses shots).
const PRESS_BUFFER := 0.14
## Fire modes (fire_mode). TEK: one round per click at up to "rate"; SERİ: full auto at "auto_rate"
## while held, each round's camera kick × "auto_kick" (the climb of gun_feel's recoil string and the
## bloom still grow, so long strings at range spread out); ÜÇLÜ: 3 rounds at "burst_rate" per click.
enum { FIRE_SEMI, FIRE_AUTO, FIRE_BURST }
const FIRE_MODE_NAMES := ["TEK", "SERİ", "ÜÇLÜ"]

const FLASH_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 color : source_color = vec4(1.0, 0.8, 0.4, 1.0);
uniform float energy = 4.0;
uniform float seed = 0.0;
uniform float spikes = 5.0;

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION.xy *= VM_K;
	POSITION.z = mix(POSITION.z, POSITION.w, 0.92);      // the view model's depth slice: the gun hides the flash behind it
}

float hash(float n) {
	return fract(sin(n * 12.9898 + 4.1414) * 43758.5453);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float ang = atan(p.y, p.x);
	// A ragged star: arms of uneven length (re-seeded every shot), each arm's length picked by the
	// nearest peak so the arms change length only where the star is thinnest (no seams).
	float ph = ang * spikes * 0.5 + seed;
	float k = floor(ph / 3.14159 + 0.5);
	float len = 0.5 + 0.5 * hash(k + seed * 7.13);
	float star = 0.2 + 0.8 * len * pow(abs(cos(ph)), 5.0);
	float a = 1.0 - smoothstep(0.0, 1.0, r / star);
	a = a * a;
	// White-hot core, the gun's colour in the body, a deeper red-orange at the ragged edge.
	float core = 1.0 - smoothstep(0.0, 0.3, r);
	vec3 rim = mix(color.rgb * vec3(1.0, 0.5, 0.3), color.rgb, smoothstep(0.0, 0.5, a));
	ALBEDO = (rim * a + vec3(1.0, 0.97, 0.9) * core * 1.4) * energy;
	ALPHA = clamp(a + core, 0.0, 1.0);
}
"""

static var _flash_shader: Shader

## Builds the muzzle flash under `parent` at `pos` (gun frame, the bore along -Z), shared by every gun
## (weapon_base.gd _make_flash): two face-on ragged stars (a big one and a smaller one turned between
## its arms), two crossed plumes along the bore (× `long`: the sniper's long jet) and a thin side flare
## across the muzzle (the brake ports). `size` scales it all; returns [root, material].
static func build_flash(parent: Node3D, pos: Vector3, size: float, col: Color, long := 1.0) -> Array:
	var root := VM.node(parent, pos)
	# One flash shader for every gun (each gun its own material): compiled once, not per gun.
	if _flash_shader == null:
		_flash_shader = Shader.new()
		_flash_shader.code = VM.prep(FLASH_SHADER)
	var mat := ShaderMaterial.new()
	mat.shader = _flash_shader
	mat.set_shader_parameter("color", col)
	var q := QuadMesh.new()
	q.size = Vector2(0.2, 0.2) * size
	var front := VM.mesh_inst(root, q, mat)
	front.position = Vector3(0, 0, -0.02)
	var q2 := QuadMesh.new()
	q2.size = Vector2(0.13, 0.13) * size
	var front2 := VM.mesh_inst(root, q2, mat)
	front2.transform = Transform3D(Basis(Vector3.FORWARD, 0.63), Vector3(0, 0, -0.05 * size))
	var side := QuadMesh.new()
	side.size = Vector2(0.09 * size, 0.3 * size * long)
	for k in 2:
		var mi := VM.mesh_inst(root, side, mat)
		mi.transform = Transform3D(Basis(Vector3.FORWARD, k * PI * 0.5) * Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 0, -0.13 * size * long))
	var flare := QuadMesh.new()
	flare.size = Vector2(0.3, 0.045) * size
	var fl := VM.mesh_inst(root, flare, mat)
	fl.position = Vector3(0, 0, -0.01)
	root.visible = false
	return [root, mat]

# Read by the view model.
var pose_override := Transform3D()  # full camera-space pose of the hand + gun rig (view model)
var draw_time := 0.6
var holster_time := 0.35
var sway_scale := 1.5
var left_reach := Vector3.ZERO
var left_reach_w := 0.0
var left_reach_elbow := Vector3(-0.3, -0.8, 0.52)
# Optional view-model fields (viewmodel.gd _reach_pose / _left_finger_mix; reload_anim.gd sets them).
var left_reach_basis := Basis()     # the left hand's own orientation (hand frame axes)
var left_reach_basis_w := 0.0       # 0: automatic (wrist screen to the eye), 1: left_reach_basis
var left_reach_space := 0.0         # 0: camera space, 1: the gun model's frame
var left_fingers := {}              # left finger channel weights (grip, wrap_mag, open_palm, thumb_press, ...)
var left_hold := {}                 # MAG_HOLD + "root": the magazine node (the fingers' hold solve)

var ammo_type := 0
var mags := [30, 10]
var reloading := false
## Fire mode (B cycles TEK -> SERİ -> ÜÇLÜ, skipping what the loaded ammo cannot do:
## SERİ needs "auto_rate", ÜÇLÜ "burst_rate"; Delici is single shot only). The chosen mode is kept
## while Delici is loaded and comes back with Standart. effective_fire_mode() is what fires now.
var fire_mode := FIRE_SEMI
## The old burst toggle, derived (true = ÜÇLÜ); setting it picks ÜÇLÜ / TEK.
var burst_mode: bool:
	get:
		return fire_mode == FIRE_BURST
	set(v):
		fire_mode = FIRE_BURST if v else FIRE_SEMI
var _burst_left := 0
var last_impact := Vector3.INF     # tests: where the last bullet landed
var ads := 0.0                     # 0 hip .. 1 aiming down the sights (spring, may overshoot)
var debug_trigger := false         # test hooks
var debug_ads := false
var debug_ignore_input := false    # tests: ignore real mouse / keyboard input
var debug_sprint := false
var fx
var hud
var shots_fired := 0
var hits := 0

var _ads_vel := 0.0
var _reload_t := 0.0
var _reload_total := 1.0
var _reload_to := 0
var _reload_switch := false
var _reload_empty := false
var _reload_ev := 0
var _cooldown := 0.0
var _press_buf := 0.0              # s a click during the cooldown stays queued (PRESS_BUFFER)
var _trigger_prev := false
var _ads_want := false
var _bloom := 0.0
var _use_t := 0.0
var _recoil := Vector2.ZERO        # camera pitch / yaw offset (rad)
var _recoil_target := Vector2.ZERO
var _roll := 0.0                   # camera roll kick (spring)
var _roll_v := 0.0
var _trauma := 0.0
var _fov_punch := 0.0
var _t := 0.0
var _cam_dirty := false
var _heat := 0.0
var _flash_t := 0.0
var _rk := Vector4.ZERO            # gun recoil spring: pitch, yaw, roll (rad), kickback (m)
var _rk_vel := Vector4.ZERO
var _sprint_w := 0.0
var _look_acc := Vector2.ZERO
var _since_shot := 9.0
var _bolt_t := 9.0                 # time since the last shot (charging handle cycle)
var _sprint := false
var _since_sprint := 9.0
var _rc := GunFeel.Recoil.new()
var _motion := GunFeel.Motion.new()
var _carry := GunFeel.Carry.new()  # sprint pose + stride sway, bob, breathing, look sway (gun_feel.gd)
var _recoil_h := PackedFloat32Array(RECOIL_H)
var _hd = Handling.Hand.new()      # handling.gd: inspect, aim foley
var _ra = ReloadAnim.Player.new()  # reload choreography (gun offset, camera, left hand, magazine)
var _mag_hold := VMHand.hold_frame(MAG_HOLD)   # left hand frame in the magazine's space
var _mag_dropped := false          # this empty reload's old magazine already fell (mag_drop.gd)
var _climb := GunFeel.Climb.new()  # the view climb you pull against (gun_feel.gd)
## Attachments (attachments.gd): what is fitted, the stats layer, the parts, the fit animation.
var att_kit = Attachments.Kit.new()
var grip_left = null               # the left hand's descriptor while a foregrip is fitted (viewmodel.gd)
var _sbus := "Weapons"             # bus of the gunshot layers (the suppressed one while suppressed)
## Fitted attachments changed ({slot: id}): multiplayer syncs remote players' guns with it.
signal attachments_changed(state: Dictionary)

# Model parts.
var _gun: Node3D
var _muzzle: Node3D
var _eject: Node3D
var _bolt: Node3D
var _mag: Node3D
var _mag_grab: Node3D
var _flash_root: Node3D
var _flash_mat: ShaderMaterial
var _accent_glow: ShaderMaterial
var _mag_glow: ShaderMaterial
var _led_mat: ShaderMaterial
var _led_off: ShaderMaterial
var _leds: Array = []
var _tp_tip: Node3D

# Audio.
var _gun_audio: Array = []
var _gun_audio_i := 0
var _aux_audio: Array = []
var _aux_i := 0
var debug_audio_log := false      # tests: record every sound started
var _fades: Array = []             # [player, seconds until fade, base volume]
const FADE_LEN := 0.07
var audio_log: Array = []
var _snd := {}
var _synth := {}
var _synth_task := -1
var _synth_ready := {}
var _synth_mutex := Mutex.new()


func _init() -> void:
	item_id = "rifle"
	item_name = "Tüfek"
	item_desc = "Sol tık: ateş · Sağ tık: nişan al · R: şarjör · T: mermi türü (Standart, Delici) · B: atış modu (tek → seri → üçlü) · Orta tık basılı: eklentiler."
	icon = "rifle"
	slot_key = 0                       # crafted at a Silahlık; the loadout (keys 1 / 2) carries it
	att_kit.bind(self)


func _ready() -> void:
	fx = RifleFx.new()
	fx.rifle = self
	add_child(fx)
	hud = RifleHud.new()
	hud.rifle = self
	add_child(hud)
	_setup_audio()
	call_deferred("_build_tp_prop")


func _exit_tree() -> void:
	if _synth_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_synth_task = -1


# =================================================================================================
# Item interface
# =================================================================================================

func accent_color() -> Color:
	return ammo_color()


func status_text() -> String:
	return "%d/%d" % [mag_count(), reserve_count()]


func hud_hint() -> String:
	return "[color=#%s][b]%s · %s[/b][/color]  [color=#dfefff]%d[/color][color=#8fa3b5]/%d · Sağ tık: nişan · R: şarjör · T: mermi · B: mod · Orta tık: eklenti[/color]" % [
		ammo_color().to_html(false), ammo_name(), mode_text(), mag_count(), reserve_count()]


## Fire mode shown on the HUD ("TEK", "SERİ", "ÜÇLÜ"): the one that fires with the loaded ammo.
func mode_text() -> String:
	return FIRE_MODE_NAMES[effective_fire_mode()]


## Per-weapon save data (mags of both ammo types, the loaded type, the fire mode, the fitted
## attachments: a dropped gun carries them).
func save_state() -> Dictionary:
	return {"mags": mags.duplicate(), "ammo": ammo_type, "fire_mode": fire_mode, "att": att_kit.state()}


func load_state(d: Dictionary) -> void:
	var m = d.get("mags")
	if m is Array:
		for i in mini((m as Array).size(), mags.size()):
			mags[i] = clampi(int(m[i]), 0, mag_capacity(i))
	ammo_type = clampi(int(d.get("ammo", ammo_type)), 0, AMMO.size() - 1)
	fire_mode = clampi(int(d.get("fire_mode", fire_mode)), FIRE_SEMI, FIRE_BURST)
	if d.get("att") is Dictionary:
		set_attachments(d["att"])
	_set_colors()


## Fitted attachments {slot: id} (attachments.gd; multiplayer reads / writes these).
func get_attachments() -> Dictionary:
	return att_kit.state()


## Fits exactly `d` ({slot: id}) at once, no animation (a picked-up gun, a remote player's gun).
func set_attachments(d: Dictionary) -> void:
	att_kit.bind(self)
	att_kit.set_state(d)


## One HUD line of what is fitted ("Susturucu · Refleks"; "" with nothing).
func attachment_text() -> String:
	return att_kit.text()


func _on_state_changed() -> void:
	if not active or not equipped:
		_ads_want = false
		if reloading and not equipped:
			reloading = false     # put away mid-reload: start over next time
			left_reach_w = 0.0
		if not equipped:
			_ra.reset()
		_restore_camera()
	elif equipped:
		# Freshly raised: a little settle wobble.
		_rk_vel += Vector4(-1.0, randf_range(-0.6, 0.6), randf_range(-0.5, 0.5), 0.0)


# =================================================================================================
# HUD / query helpers
# =================================================================================================

func ammo_types() -> int:
	return AMMO.size()


func _ai(i: int) -> int:
	return ammo_type if i < 0 else i


func ammo_color(i := -1) -> Color:
	return AMMO[_ai(i)]["color"]


func ammo_name(i := -1) -> String:
	return AMMO[_ai(i)]["name"]


func ammo_short(i := -1) -> String:
	return AMMO[_ai(i)]["short"]


func ammo_title(i := -1) -> String:
	return AMMO[_ai(i)]["title"]


func mag_count(i := -1) -> int:
	return mags[_ai(i)]


func mag_capacity(i := -1) -> int:
	return int(roundf(float(AMMO[_ai(i)]["mag"]) * 1.0))


## Rounds a reload of this ammo type can still get (reserve + what the material can buy).
func reserve_count(i := -1) -> int:
	return Game.ammo_available(AMMO[_ai(i)]["id"])


## The reserve itself (HUD: "mag / reserve").
func reserve_stock(i := -1) -> int:
	return Game.ammo_reserve(AMMO[_ai(i)]["id"])


## Material per round of the current type when the reserve runs out (m³).
func round_cost() -> float:
	return float(Game.AMMO_COST.get(AMMO[ammo_type]["id"], 0.0))


func reload_progress() -> float:
	return clampf(_reload_t / maxf(_reload_total, 0.01), 0.0, 1.0)


func switching() -> bool:
	return reloading and _reload_switch


func hud_visible() -> bool:
	if player == null or not equipped or not active or player.vehicle != null:
		return false
	return true


## Muzzle position in the world (first person: where the view-model muzzle appears on screen).
func muzzle_world() -> Vector3:
	return _vm_world(_muzzle)


# =================================================================================================
# Input
# =================================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if debug_ignore_input or not can_operate():
		return
	var middle := event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE
	if middle:
		# Middle mouse held: the attachment radial (attachment_radial.gd). Consumed here, so the
		# "tool_mode" action (R + middle mouse) never reloads or switches the mode from it.
		if event.is_pressed():
			AttachmentRadial.open_for(self)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).physical_keycode == KEY_B:
		toggle_fire_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tool_mode"):
		reload()
		get_viewport().set_input_as_handled()
	# (No mouse wheel here: a stray scroll used to start a full magazine change mid-fight. T only.)
	elif event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).physical_keycode == KEY_T:
		switch_ammo(1)
		get_viewport().set_input_as_handled()


## True when ammo type `ammo` (-1 = the loaded one) can fire in mode `m`.
func mode_available(m: int, ammo := -1) -> bool:
	var a: Dictionary = AMMO[_ai(ammo)]
	match m:
		FIRE_AUTO:
			return a.has("auto_rate")
		FIRE_BURST:
			return a.has("burst_rate")
	return true


## The mode that fires with the loaded ammo (fire_mode, or TEK when the ammo cannot do it).
func effective_fire_mode() -> int:
	return fire_mode if mode_available(fire_mode) else FIRE_SEMI


## B: the next mode the loaded ammo can fire (TEK -> SERİ -> ÜÇLÜ -> TEK).
func toggle_fire_mode() -> void:
	if not mode_available(FIRE_AUTO) and not mode_available(FIRE_BURST):
		if Game.sfx:
			Game.sfx.play("error", -14.0)
		return
	var m := effective_fire_mode()
	for i in 3:
		m = (m + 1) % 3
		if mode_available(m):
			break
	set_fire_mode(m)


## Selects fire mode `m` (FIRE_SEMI / FIRE_AUTO / FIRE_BURST): the selector click, the HUD flash.
func set_fire_mode(m: int) -> void:
	fire_mode = clampi(m, FIRE_SEMI, FIRE_BURST)
	_burst_left = 0
	var pitch: float = [1.1, 0.95, 0.8][fire_mode]
	if Game.sfx:
		Game.sfx.play("click", -8.0, pitch)
	_play("selector", -10.0, pitch * 0.95)
	_rk_vel += Vector4(0.25, 0.0, 0.15, 0.0)     # the thumb on the selector nudges the gun
	hud.ammo_switched()


func reload() -> void:
	if reloading:
		return
	if mags[ammo_type] >= mag_capacity():
		return
	if reserve_count() <= 0:
		hud.empty_flash()
		if Game.sfx:
			Game.sfx.play("error", -12.0)
		return
	_start_reload(ammo_type, false)


## Switches to the next ammo type (step ±1): that is a full magazine change.
func switch_ammo(step: int) -> void:
	if reloading:
		return
	var n := AMMO.size()
	var to := (ammo_type + step + n) % n
	if mags[to] <= 0 and reserve_count(to) <= 0:
		hud.empty_flash()
		if Game.sfx:
			Game.sfx.play("error", -12.0)
		return
	_start_reload(to, true)
	_play("selector", -8.0, 0.85)
	hud.ammo_switched()


func _start_reload(to: int, is_switch: bool) -> void:
	var a: Dictionary = AMMO[to]
	_reload_empty = mags[ammo_type] <= 0
	reloading = true
	_reload_t = 0.0
	_reload_total = float(a["reload_empty"] if _reload_empty else a["reload"])
	_reload_to = to
	_reload_switch = is_switch
	_reload_ev = 0
	_ads_want = false
	# The choreography (reload_anim.gd), built from this gun's geometry as it is now (a fitted foregrip
	# moves the left grip): tactical with rounds left, a speed reload + bolt catch when empty.
	var geo := _reload_geo()
	_ra.start(ReloadAnim.mag_empty(geo) if _reload_empty else ReloadAnim.mag_tactical(geo))
	_mag_dropped = false


## Gun geometry for the reload builders (reload_anim.gd; gun frame unless noted).
func _reload_geo() -> Dictionary:
	return {"pivot": RELOAD_PIVOT, "mag_rest": MAG_REST, "mag_basis": Basis(), "mag_axis": MAG_AXIS, "lip": MAG_LIP,
		"base": MAG_BASE, "hold": _mag_hold, "grip": _left_grip_frame(), "catch": BOLT_CATCH,
		"pouch": RELOAD_POUCH, "nominal": _hip_pose(), "scale": 1.0}


## The left hand frame on its grip (handguard, or a fitted foregrip) in the gun frame, palm offset
## included: exactly where the view model puts the hand on it (viewmodel.gd grip_xf, roll 0).
func _left_grip_frame() -> Transform3D:
	if left_grip == null or model == null:
		return VMHand.hold_frame(VMHand.GRIPS["rifle"]["left"])
	var d: Dictionary = grip_left if grip_left is Dictionary else (VMHand.GRIPS.get(item_id, {}) as Dictionary).get("left", {})
	return ReloadAnim._model_xf(left_grip, model) * Transform3D(Basis(), VMHand.palm_offset(-1.0, float(d.get("r", VMHand.R_DEFAULT))))


func _finish_reload() -> void:
	reloading = false
	left_reach_w = 0.0
	_ra.finish()
	ammo_type = _reload_to
	var a: Dictionary = AMMO[ammo_type]
	var take := mini(int(a["mag"]) - mags[ammo_type], reserve_count())
	if take > 0:
		mags[ammo_type] += Game.take_ammo(a["id"], take)
	_set_colors()


## A melee swing started (scripts/player/melee.gd, V): the magazine change and the inspect are
## dropped (an ammo switch keeps the old type).
func melee_interrupt() -> void:
	reloading = false
	_ra.cancel()                       # the hand and the gun ease back (left_reach_w fades with it)
	_burst_left = 0
	Handling.gun_melee(self)


# =================================================================================================
# Firing
# =================================================================================================

func _physics_process(delta: float) -> void:
	_cooldown -= delta
	# (The attachment radial open on this gun holds fire and aim; attachments.gd.)
	if not can_operate() or player == null or player.vehicle != null or Attachments.radial_on(self):
		_trigger_prev = false
		_ads_want = false
		_burst_left = 0
		return
	var real := not debug_ignore_input and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var trig := (real and Input.is_action_pressed("tool_use")) or debug_trigger
	# just_pressed also catches a click shorter than one physics tick.
	var pressed := (trig and not _trigger_prev) or (real and Input.is_action_just_pressed("tool_use"))
	_trigger_prev = trig
	# Input buffer: a click while the gun still cycles fires the moment it is ready (PRESS_BUFFER).
	var buffered := false
	if pressed and _cooldown > 0.0:
		_press_buf = PRESS_BUFFER
	elif _press_buf > 0.0:
		_press_buf -= delta
		if _cooldown <= 0.0 and _press_buf > 0.0:
			pressed = true
			buffered = true
			_press_buf = 0.0
	var up: Vector3 = player.global_transform.basis.y
	var hv: Vector3 = player.velocity - up * player.velocity.dot(up)
	# Sprint pose follows the player's run (kept through a hop), not is_on_floor().
	_sprint = (debug_sprint or (real and Input.is_action_pressed("sprint"))) and hv.length() > 6.0 \
			and (float(player.get("_sprint_k")) > 0.5 or debug_sprint) and ads < 0.2
	_since_sprint = 0.0 if _sprint else _since_sprint + delta
	_ads_want = ((real and Input.is_action_pressed("tool_alt")) or debug_ads) and not _sprint and not reloading \
			and not att_kit.busy()
	# Handling (handling.gd): inspect (Y), wall / melee / inspect blocks, aim foley.
	if Handling.gun_physics(self, real, pressed, (real and Input.is_action_pressed("tool_alt")) or debug_ads):
		_burst_left = 0
		return
	if att_kit.busy():                         # fitting an attachment: the hands are on it
		_burst_left = 0
		return
	var a: Dictionary = AMMO[ammo_type]
	var mode := effective_fire_mode()
	var bursting := mode == FIRE_BURST
	if bursting and pressed and _burst_left <= 0 and _cooldown <= 0.0:
		_burst_left = 3
	if reloading or _cooldown > 0.0 or _since_sprint < SPRINT_TO_FIRE:
		return
	if not player.viewmodel.is_raised():
		return
	if bursting:
		if _burst_left <= 0:
			return
		_burst_left -= 1
	elif mode == FIRE_AUTO:
		if not (trig or buffered):                 # SERİ: fires while held
			return
	elif not (trig or buffered) or (not a["auto"] and not pressed):
		return
	if mags[ammo_type] <= 0:
		if pressed:
			if Game.sfx:
				Game.sfx.play("click", -4.0, 1.3)
			_play("dry", -6.0, 1.0)
			hud.empty_flash()
			if reserve_count() > 0:
				reload()
		return
	fire()


## Fires one round of the current ammo type.
func fire() -> void:
	var a: Dictionary = AMMO[ammo_type]
	mags[ammo_type] -= 1
	_cooldown = 1.0 / float(a["rate"])
	var mode := effective_fire_mode()
	if mode == FIRE_BURST:
		# Burst cadence inside the burst, then a pause before the next trigger pull counts.
		_cooldown = 1.0 / float(a["burst_rate"]) if _burst_left > 0 else 0.3
	elif mode == FIRE_AUTO:
		_cooldown = 1.0 / float(a["auto_rate"])
	shots_fired += 1
	var aim := clampf(ads, 0.0, 1.0)
	var cam: Camera3D = player.camera
	var eye: Vector3 = player.aim_origin()
	var cb := cam.global_transform.basis
	var fwd := -cb.z
	var up: Vector3 = player.global_transform.basis.y
	var dir := _spread_dir(fwd, cb, current_spread())
	_bloom = minf(_bloom + float(a["spread"]) * 0.45, float(a["spread"]) * 2.5)
	var muzzle := muzzle_world()
	# (A suppressor costs a little muzzle velocity: attachments.gd "velocity".)
	fx.bullet(eye, dir * float(a["speed"]) * att_kit.stat("velocity") + player.velocity, muzzle, ammo_type, a["color"],
			a["dart"], int(a["pierce"]))
	Game.shot_fired.emit(eye, dir, "home")         # rival bots it passes near react (ai_rival.gd)
	# Recoil (MW-like). Camera: RECOIL_VIEW of the kick climbs the view itself (gun_feel.gd Climb; the
	# player pulls down against it, what he does not pull back recovers after the string), the rest
	# is a snap on the _recoil spring that comes back between rounds; a bigger first round, a steady
	# string, the RECOIL_H drift; attachments scale the climb / sideways / shake. Gun: rotates up
	# about the stock and slides back, then settles (springs in _process).
	var aim_k := (1.0 - aim * 0.3) * GunFeel.stance_recoil(player)
	var auto := mode == FIRE_AUTO
	# Rounds 2-3 of a burst kick the camera less (a burst lands as a tight group); full auto a little
	# less per round (the climb still adds up round after round).
	if mode == FIRE_BURST and a.has("burst_kick") and _burst_left < 2:
		aim_k *= float(a["burst_kick"])
	elif auto:
		aim_k *= float(a.get("auto_kick", 1.0))
	kick = 0.0
	var rk := _rc.next(float(a["kick_pitch"]), float(a["kick_yaw"]), RECOIL_CLIMB * (0.6 if ammo_type == 1 else 1.0),
			_recoil_h, RECOIL_FIRST) * aim_k * Vector2(att_kit.stat("climb"), att_kit.stat("horiz"))
	_climb.shot(rk * RECOIL_VIEW)
	_recoil_target += rk * (1.0 - RECOIL_VIEW)
	_recoil_target.x = minf(_recoil_target.x, 0.18)
	_recoil = _recoil.lerp(_recoil_target, 0.35)      # the snap lands on the next frame
	_roll_v += randf_range(-1.0, 1.0) * float(a["roll"]) * 60.0 * aim_k
	# Shake and the FOV micro-punch per round, lighter in full auto (they stack) and aimed; a very light
	# screen punch on each full-auto round.
	_trauma = minf(_trauma + float(a["shake"]) * aim_k * att_kit.stat("shake") * (0.45 if auto else 1.0), 1.0)
	_fov_punch += float(a["fov_punch"]) * lerpf(1.0, 0.55, aim) * (0.45 if auto else 1.0)
	if auto:
		ScreenPunch.kick(0.1 * (1.0 - aim * 0.5))
	# Visible gun kick (big, snappy): part of it lands at once (the gun jumps on the shot frame), the
	# rest as velocity into the stiff recoil spring (_process), so it peaks ~45 ms after the shot and
	# is home in ~0.25 s: muzzle flip about the stock (a compensator tames half of it), a hard
	# back-thrust, a little roll (mostly to the right, the way a right-handed shooter's gun twists)
	# and a random jitter. Aimed it is mostly the back-thrust (the sights stay on, _update_pose).
	var gk: float = float(a["gun_kick"]) * (0.85 if auto else 1.0)
	var flip := lerpf(1.0, att_kit.stat("climb"), 0.5)
	var hip_k := 1.0 - aim * 0.55
	var back_k := lerpf(1.0, 0.65, aim)
	var roll_s := randf_range(-0.4, 1.0)
	var jit := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	_rk += Vector4(gk * 0.012 * hip_k * flip, jit.x * gk * 0.0022 * hip_k,
			roll_s * gk * 0.0055 * hip_k, gk * 0.007 * back_k)
	_rk_vel += Vector4(gk * (0.65 + 0.12 * jit.y) * hip_k * flip, jit.x * gk * 0.13 * hip_k,
			roll_s * gk * 0.17 * hip_k, gk * 0.32 * back_k)
	_since_shot = 0.0
	_bolt_t = 0.0
	_heat = minf(_heat + 0.07, 1.0)
	_use_t = 0.09
	var fl: float = a["flash"]
	if fl > 0.0:
		_flash_t = 1.0
		_randomize_flash(fl * 0.85 * att_kit.stat("flash"))
		if att_kit.stat("light") > 0.01:
			fx.muzzle_light(muzzle + fwd * 0.9, Color(1.0, 0.74, 0.4), 10.0 * fl * att_kit.stat("light"), 0.05, 16.0)
		fx.muzzle_smoke(muzzle + fwd * 0.15, fwd, up, fl * (0.6 if att_kit.suppressed() else 1.0))
		var side: Vector3 = cb.x
		fx.shell(_vm_world(_eject), side * randf_range(2.2, 3.2) + up * randf_range(1.4, 2.4) - fwd * 0.5 + player.velocity,
				ammo_type == 1)
	else:
		fx.muzzle_puff(muzzle + fwd * 0.1, fwd)
	_fire_sound()
	if mags[ammo_type] == 0 and reserve_count() > 0:
		_cooldown = maxf(_cooldown, 0.25)


func _spread_dir(fwd: Vector3, cb: Basis, spread: float) -> Vector3:
	if spread <= 0.0:
		return fwd
	var ang := randf() * TAU
	var r := sqrt(randf()) * spread
	return (fwd + cb.x * cos(ang) * r + cb.y * sin(ang) * r).normalized()


## A bullet hit something (called by the fx node). info: type ("body" with info["target"] = a
## damageable, "terrain", "metal"), point, normal, collider. Returns true when the bullet should stop
## (false = an AP round pierces on through a body).
func bullet_hit(info: Dictionary, dir: Vector3, ammo: int, pierced: int) -> bool:
	var a: Dictionary = AMMO[ammo]
	var p: Vector3 = info["point"]
	var n: Vector3 = info["normal"]
	last_impact = p
	match info["type"]:
		"body":
			var t = info["target"]
			var dmg: float = float(a["dmg"]) * (0.6 if pierced > 0 else 1.0)
			# Head zone, kill launch, hit reaction, suit / visor effects, markers, confirm sounds,
			# hit-stop, kill feed: scripts/items/gun_feel.gd + hit_feel.gd (shared by all guns).
			GunFeel.body_hit(self, t, p, n, dir, {"dmg": dmg, "head": HEAD_MULT, "push": float(a["impulse"]) * 0.15,
					"launch": 5.5 if ammo == 1 else 3.5, "big": 0.55 if ammo == 1 else 0.2, "heavy": ammo == 1,
					"name": "Tüfek"})
			hits += 1
			return pierced >= int(a["pierce"])
		"terrain":
			fx.impact_terrain(p, n, dir, _ground_color(p, n), false, ammo == 1)
		"metal":
			fx.impact_metal(p, n, dir, false)
	return true


# =================================================================================================
# Per-frame: aim, camera, weapon pose (hip / aim / sprint / reload + recoil, bob, sway)
# =================================================================================================

## Current cone half-angle of fire (rad): base spread (hip or aimed) + bloom + movement.
func current_spread() -> float:
	var a: Dictionary = AMMO[ammo_type]
	var aim := clampf(ads, 0.0, 1.0)
	var mv := 0.0
	if player != null:
		var up: Vector3 = player.global_transform.basis.y
		var hv: Vector3 = player.velocity - up * player.velocity.dot(up)
		mv = clampf(hv.length() / 6.0, 0.0, 1.0) * 0.016 * GunFeel.stance_move(player) + (0.0 if player.is_on_floor() else 0.018)
	# (A laser tightens the hip cone: attachments.gd "hip".)
	var base := lerpf(float(a["spread"]) * att_kit.stat("hip"), float(a["ads_spread"]), aim) * GunFeel.stance_spread(player)
	# First-shot accuracy: a rested rifle puts its first round tighter (tap fire pays off).
	if _since_shot > FIRST_SHOT_REST:
		base *= 0.5
	return base + (_bloom + mv) * (1.0 - aim * 0.6) * lerpf(att_kit.stat("hip"), 1.0, aim)


func _input(event: InputEvent) -> void:
	# Mouse look feeds the weapon sway (read only, never consumed).
	if event is InputEventMouseMotion and equipped and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look_acc += (event as InputEventMouseMotion).relative


func _process(delta: float) -> void:
	_t += delta
	var on := player != null and equipped and active and player.vehicle == null
	using = _use_t > 0.0
	_use_t = maxf(_use_t - delta, 0.0)
	var dt := minf(delta, 0.033)
	# Raise to the sights: a spring with a slight overshoot (~0.3 s in, ~0.25 s out); the attachments'
	# aim speed s scales its time (stiffness × s², damping × s).
	var want := _ads_want and on
	var asp: float = att_kit.ads_speed()
	var k := (110.0 if want else 170.0) * asp * asp
	var c := (13.5 if want else 25.0) * asp
	_ads_vel += (((1.0 if want else 0.0) - ads) * k - _ads_vel * c) * dt
	ads = clampf(ads + _ads_vel * dt, -0.05, 1.1)
	sway_scale = lerpf(1.6, 0.45, clampf(ads, 0.0, 1.0)) * att_kit.stat("sway")
	if reloading:
		_reload_t += delta
		_reload_events(dt)
		if _reload_t >= _reload_total:
			_finish_reload()
	else:
		_ra.idle(dt)                   # a cancelled reload eases out, the reload spring settles
	# Camera recoil: the kick snaps in, holds a moment (sustained fire climbs), then settles back on
	# a spring; a little roll on a stiff spring.
	_rc.tick(delta)
	_recoil = _recoil.lerp(_recoil_target, 1.0 - exp(-60.0 * delta))
	if _since_shot > RECOIL_HOLD:
		var rec := lerpf(10.5, 12.5, clampf(ads, 0.0, 1.0))
		_recoil_target = _recoil_target.lerp(Vector2.ZERO, 1.0 - exp(-rec * delta))
	_roll_v += (-_roll * 420.0 - _roll_v * 26.0) * dt
	_roll += _roll_v * dt
	_trauma = maxf(_trauma - delta * 2.6, 0.0)
	_fov_punch = lerpf(_fov_punch, 0.0, 1.0 - exp(-12.0 * delta))
	# Bloom recovers after a short pause (fast follow-ups keep it open).
	_since_shot += delta
	if _since_shot > 0.15:
		_bloom = maxf(_bloom - delta * 0.04, 0.0)
	_heat = maxf(_heat - delta * 0.3, 0.0)
	# Shots set _flash_t = 1 in the physics step; let that frame render at full strength first.
	_flash_t = maxf(_flash_t - delta / 0.05, 0.0) if _flash_t < 1.0 else 0.999
	# Gun recoil spring (pitch, yaw, roll, kickback): fast kick, damped settle ~0.25 s (stiffer since
	# the weapon-feel pass: a snappier return).
	_rk_vel += (-_rk * 340.0 - _rk_vel * 25.0) * dt
	_rk += _rk_vel * dt
	_bolt_t += delta
	_update_fades(delta)
	_climb.update(player, delta, on)   # the view climb (gun_feel.gd Climb)
	att_kit.tick(delta, on)            # attachments: fit animation, laser, 4× overlay
	if on:
		_apply_camera()
	else:
		_restore_camera()
	_update_pose(dt, on)
	_animate_model(dt)
	Handling.gun_post(self)            # inspect: the left hand checks the magazine
	att_kit.post()                     # fitting: the left hand on the mount


func _apply_camera() -> void:
	var cam: Camera3D = player.camera
	var e := _smooth(clampf(ads, 0.0, 1.0))
	var fk: float = float(player.get("fov_kick")) if player.get("fov_kick") != null else 0.0
	# The fitted optic's FOV (attachments.gd: the irons' ADS_FOV, a reflex / holo a little closer, the
	# 4× in tan space); the FOV punch shrinks with the zoom.
	var fov := att_kit.cam_fov(e, ADS_FOV) as float
	cam.fov = fov + _fov_punch * fov / maxf(Settings.fov, 1.0) + fk * (1.0 - e)
	var sh := _trauma * _trauma
	var shake := Vector3(sin(_t * 67.0) + sin(_t * 29.0) * 0.6, sin(_t * 59.0 + 1.3) + sin(_t * 19.0) * 0.5,
			sin(_t * 43.0 + 0.7)) * sh * 0.016
	# Slight breathing sway while aiming (a foregrip steadies it, the 4× shows more of it).
	var breath := Vector2(sin(_t * 1.1) * 0.0018 + sin(_t * 0.43) * 0.001, sin(_t * 0.8 + 1.0) * 0.0024) * e \
			* att_kit.stat("sway") * (1.6 if att_kit.is_scope() else 1.0)
	# Added on top of the player's own camera rotation (damage punches), which it resets each frame.
	cam.rotation += Vector3(_recoil.x + shake.x + breath.y, _recoil.y + shake.y + breath.x, shake.z + _roll)
	# The reload's head motion (reload_anim.gd: keyed ≤ 1.5° plus a little of its kicks), additive.
	cam.rotation += _ra.cam_rot()
	# The rifle draws its own crosshair (spread brackets) in rifle_hud.
	if Game.hud != null and Game.hud.get("crosshair") != null:
		Game.hud.crosshair.modulate.a = 0.0
	if "move_speed_mult" in player:
		player.set("move_speed_mult", lerpf(1.0, AIM_SPEED, e))
	if "look_scale" in player:
		player.set("look_scale", att_kit.cam_look(e, ADS_FOV))
	_cam_dirty = true


func _restore_camera() -> void:
	if not _cam_dirty or player == null:
		return
	_cam_dirty = false
	var cam: Camera3D = player.camera
	# Ease out of the aim instead of snapping the view (swapping while aimed / mid-recoil).
	if absf(cam.fov - Settings.fov) > 0.5:
		cam.create_tween().tween_property(cam, "fov", Settings.fov, 0.18)
	else:
		cam.fov = Settings.fov
	if "_punch" in player:
		player._punch += Vector3(cam.rotation.x, cam.rotation.y, 0.0)
	cam.rotation = Vector3.ZERO
	if Game.hud != null and Game.hud.get("crosshair") != null:
		Game.hud.crosshair.modulate.a = 1.0
	if "move_speed_mult" in player:
		player.set("move_speed_mult", 1.0)
	if "look_scale" in player:
		player.set("look_scale", 1.0)
	_recoil = Vector2.ZERO
	_recoil_target = Vector2.ZERO
	_roll = 0.0
	_roll_v = 0.0
	ads = 0.0
	_ads_vel = 0.0


static func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## Smooth 0..1 ramp of u between a and b.
static func _seg(u: float, a: float, b: float) -> float:
	return _smooth((u - a) / (b - a))


## Hip pose (camera space): grip low on the right, stock toward the shoulder, the bore converging
## on the crosshair a few meters ahead, a slight inward cant.
static func _hip_pose() -> Transform3D:
	var bore := HIP_POS + Vector3(0.0, 0.062, 0.0)
	var d := (Vector3(0.0, 0.0, -HIP_CONVERGE) - bore).normalized()
	var b := Basis.looking_at(d, Vector3.UP) * Basis(Vector3.BACK, HIP_CANT)
	return Transform3D(b, HIP_POS)


## Aim pose: gun straight ahead, rear notch on the camera axis.
## With an optic fitted its sight line (attachments.gd sight_y) goes on the axis instead (the eye
## stays at the same distance behind the rear sight's spot; a reflex / holo comes closer, sight_z).
func _ads_pose() -> Transform3D:
	var sp := SIGHT_REAR
	var oy: float = att_kit.sight_y()
	if oy > 0.0:
		sp.y = oy
		sp.z = att_kit.sight_z(sp.z, ADS_EYE.z)     # a reflex / holo comes closer (attachments.gd)
	return Transform3D(Basis(), ADS_EYE - sp)


static func _pose_from(origin: Vector3, euler: Vector3) -> Transform3D:
	return Transform3D(Basis.from_euler(euler), origin)


static func _blend(a: Transform3D, b: Transform3D, w: float) -> Transform3D:
	var q := Quaternion(a.basis.orthonormalized()).slerp(Quaternion(b.basis.orthonormalized()), clampf(w, 0.0, 1.0))
	return Transform3D(Basis(q), a.origin.lerp(b.origin, w))


## Full camera-space pose of the hand + gun rig, read by the view model (`pose_override`).
func _update_pose(dt: float, on: bool) -> void:
	if player == null:
		return
	var aim := clampf(ads, 0.0, 1.0)
	# Movement layer (gun_feel.gd Carry, shared with every gun): the run pose weight and its stride
	# sway, the walk bob, idle breathing, look sway, the jump / fall lift, the sprint-to-fire raise.
	var look := _look_acc * (1.0 / 60.0) / maxf(dt, 0.001)     # per-frame mouse counts → 60 fps units
	_look_acc = Vector2.ZERO
	var sk := lerpf(1.0, 0.25, aim) * (0.6 if reloading else 1.0) * att_kit.stat("sway")
	var style := GunFeel.sprint_style(self)
	var mv := _carry.update(player, dt, _sprint and on, aim, look, sk, style)
	_sprint_w = clampf(_carry.sprint, 0.0, 1.0)
	var hip := _hip_pose()
	var pose := _blend(hip, _ads_pose(), aim)
	if ads > 1.0:
		pose.origin = hip.origin.lerp(_ads_pose().origin, ads)
	var run_pose := GunFeel.sprint_pose(self, style) if style.has("pos") else _pose_from(SPRINT_POS, SPRINT_ROT)
	pose = _blend(pose, run_pose, _smooth(_sprint_w))
	# Reload choreography (reload_anim.gd): the gun cants / rolls about the receiver over the well,
	# bumps on the seat, slap and bolt (its spring), eases out when cancelled.
	pose = _ra.apply_gun(pose)
	var xf := GunFeel.apply_motion(pose, mv)
	# Recoil in the gun frame: rotate up about the stock, slide back along the bore.
	# Aimed, the camera carries the climb: the gun hardly turns (the sights stay on the reticle and the
	# barrel never rises into view), it bucks back into the shoulder instead.
	var rk_rot := Basis.from_euler(Vector3(_rk.x * (1.0 - 0.75 * aim), _rk.y * (1.0 - 0.55 * aim), _rk.z * (1.0 - 0.45 * aim)))
	var rk_xf := Transform3D(Basis(), RECOIL_PIVOT) * Transform3D(rk_rot, Vector3.ZERO) * Transform3D(Basis(), -RECOIL_PIVOT)
	rk_xf.origin += Vector3(0.0, 0.0, _rk.w * (1.0 - 0.35 * aim))
	# Movement inertia (strafe cant, landing dip, slide cant) about the grip.
	pose_override = GunFeel.apply_motion(xf * rk_xf, _motion.update(player, dt, aim))
	pose_override = Handling.gun_pose(self, pose_override, dt, on)      # inspect (Y)
	pose_override = att_kit.pose(pose_override)                         # fitting an attachment


func _animate_model(dt: float) -> void:
	if model == null:
		return
	# Reload choreography (scripts/items/reload_anim.gd; the gun's offset and the head motion are applied
	# in _update_pose / _apply_camera): the left hand (gun-frame target, its own orientation and finger
	# channels for the view model) and the magazine: seated, in the hand, in the pouch or dropped.
	hold_offset = Vector3.ZERO
	_gun.transform = Transform3D()
	var fresh := false
	if _ra.shown() and player != null:
		var st: int = ReloadAnim.drive(self, _ra, _mag, Transform3D(Basis(), MAG_REST), _mag_hold, dt)
		fresh = _ra.fresh()
		if st == ReloadAnim.MAG_DROPPED and not _mag_dropped:
			_mag_dropped = true
			_drop_mag()
	else:
		left_reach_w = 0.0
		ReloadAnim.release(self)
		_mag.transform = Transform3D(Basis(), MAG_REST)
		_mag.visible = true
	# The new magazine glows in its ammo colour from the moment it comes out of the pouch (T switch).
	var mc := ammo_color(_reload_to) if fresh else ammo_color()
	if _mag_glow.get_shader_parameter("color") != mc:
		_mag_glow.set_shader_parameter("color", mc)
	# Charging handle: snaps back in 0.04 s and springs home in 0.08 s per shot; held back on an empty
	# magazine (bolt hold-open) until the empty reload's bolt catch sends it home.
	var cyc := _smooth(_bolt_t / 0.04) if _bolt_t < 0.04 else 1.0 - _smooth((_bolt_t - 0.04) / 0.08)
	var pull := maxf(_ra.extra("charge"), 1.0 if mags[ammo_type] <= 0 and not reloading else 0.0)
	_bolt.position = Vector3(0.03, 0.082, maxf(cyc, pull) * 0.06)
	# Muzzle flash, heat strips, ammo counter LEDs.
	_flash_root.visible = _flash_t > 0.0
	if _flash_t > 0.0:
		_flash_mat.set_shader_parameter("energy", 16.0 * _flash_t)
	var col := ammo_color()
	_accent_glow.set_shader_parameter("energy", 2.5 + _heat * 5.0)
	var frac := float(mags[ammo_type]) / float(mag_capacity())
	for i in _leds.size():
		var lit := frac > (float(i) + 0.5) / _leds.size()
		(_leds[i] as MeshInstance3D).material_override = _led_mat if lit else _led_off
	_led_mat.set_shader_parameter("color", col)


## Reload foley, timed to the choreography's keys (reload_anim.gd mag_tactical / mag_empty "events":
## cloth, mag_release, mag_out, mag_in, mag_slap, bolt_back, bolt_fwd through _play; grip / gear / tap
## foley through Game.sfx). Their kicks go into the choreography's own spring, not the recoil spring.
func _reload_events(dt: float) -> void:
	for e: Dictionary in _ra.advance(reload_progress(), dt):
		var snd := str(e.get("snd", ""))
		if snd == "":
			continue
		var db := float(e.get("db", -8.0))
		var pitch := float(e.get("pitch", 1.0)) * randf_range(0.96, 1.04)
		if bool(e.get("sfx", false)):
			if Game.sfx != null and is_instance_valid(Game.sfx):
				Game.sfx.play(snd, db, pitch)
		else:
			_play(snd, db, pitch)
		_reload_ev += 1


## Empty reload: the old magazine falls free (scripts/items/mag_drop.gd; cosmetic, local only): a world
## copy where the view model draws it (vm_parts.gd fov_scale: same place and size on screen), with the
## player's velocity, a push down out of the well and a little out to the left, tumbling.
func _drop_mag() -> void:
	if player == null or _mag == null:
		return
	var src: MeshInstance3D = null
	for c in _mag.get_children():
		if c is MeshInstance3D:
			src = c
			break
	if src == null:
		return
	var cx: Transform3D = player.camera.global_transform
	var k := VM.fov_scale()
	var mc: Transform3D = pose_override * _gun.transform * _mag.transform          # camera space
	var at := cx * Vector3(mc.origin.x * k, mc.origin.y * k, mc.origin.z)
	var down := (cx.basis * (pose_override.basis * MAG_AXIS)).normalized()
	var vel: Vector3 = player.velocity + down * randf_range(1.2, 1.6) - cx.basis.x * randf_range(0.2, 0.45) + cx.basis.z * 0.15
	var spin := cx.basis * Vector3(randf_range(-4.0, 4.0), randf_range(-2.0, 2.0), randf_range(-6.0, -2.0))
	var parent: Node = get_tree().current_scene if is_inside_tree() else null
	MagDrop.spawn(parent, src, Transform3D(cx.basis * mc.basis, at), k, vel, spin, MAG_BOX_C, MAG_BOX_S,
			Basis(Vector3.RIGHT, 0.12), _stream("tink"))


func _randomize_flash(size: float) -> void:
	if _flash_root == null:
		return
	# Aimed: the flash sits far out at the muzzle, mostly behind the gun (smaller, MW-like).
	_flash_root.scale = Vector3.ONE * randf_range(0.85, 1.3) * size * lerpf(1.0, 0.55, clampf(ads, 0.0, 1.0))
	_flash_root.rotation.z = randf() * TAU
	_flash_mat.set_shader_parameter("seed", randf() * 10.0)
	_flash_mat.set_shader_parameter("spikes", float(randi_range(4, 6)))


func _set_colors() -> void:
	var col := ammo_color()
	if _accent_glow:
		_accent_glow.set_shader_parameter("color", col)
		_mag_glow.set_shader_parameter("color", col)
		_led_mat.set_shader_parameter("color", col)


## World position of a view-model node (as it appears on screen).
func _vm_world(n: Node3D) -> Vector3:
	var cam: Camera3D = player.camera
	if n == null:
		return cam.global_position - cam.global_transform.basis.z * 0.6
	return VM.vm_to_world(cam, n.global_position)


func _ground_color(p: Vector3, n: Vector3) -> Color:
	return ground_color(p, n)


## Dust colour of a bullet impact at p (normal n): the planet's ground colour on open ground, its
## rock colour on steep walls (shared by every gun and projectiles.gd).
static func ground_color(p: Vector3, n: Vector3) -> Color:
	var body: Node3D = Game.body_at(p)
	if body == null:
		return Color(0.45, 0.38, 0.26)
	var up := (p - body.global_position).normalized()
	var cfg: Dictionary = body.get("cfg") if body.get("cfg") is Dictionary else {}
	if n.dot(up) < 0.55:
		return cfg.get("col_rock", Color(0.42, 0.4, 0.38))
	return cfg.get("col_low", Color(0.45, 0.38, 0.26))


# =================================================================================================
# Audio. Every gunshot is layered on a dedicated "Weapons" bus (EQ -> glue compressor -> slap / reverb
# sized to the surroundings by acoustics.gd -> limiter):
#   shot    the recorded report with its own natural decay (weap/ar: a 1 m HK416 / L85 body + the
#           on-gun crack and bolt mechanics + AKM low weight, mastered dense; the AP round
#           weap/ar_heavy: AKM 7.62 + 5.56 body + mechanics, deeper)
#   thump   short synthesized low body (65-110 Hz) and punch: the sub kick (120 -> 42 Hz + snap)
#   action  bolt clack, dry and close (plain bus)
#   gtail   outdoors: a recorded rolling tail (12 gauge / AKM tails, pitched distant blasts) plus
#           the synthesized terrain slap-back (echo); in a tunnel a short dark tail (the room
#           reverb comes from acoustics.gd)
# Reload foley is synthesized and timed to the animation.
# =================================================================================================

## Recorded reports: the new sets carry their whole decay (only cut late, to spare voices); the old
## short cuts (weap/rifle_shot / rifle_heavy, the fallback before the new files are imported) are
## trimmed early as before.
const CRACK_LEN := {"shot": 0.3, "heavy": 0.4}
const REPORT_LEN := 0.85
const TAIL_GAP := 0.2              # s: an outdoor tail at most this often (rapid shots share one)
var _tail_t := 0                   # msec of the last outdoor tail
var _new_reports := false          # the weap/ar sets are loaded

func _setup_audio() -> void:
	var bus := _weapons_bus()
	for i in 32:                       # full auto at 9 rounds/s keeps ~6 layers of ~4 rounds alive
		var p := AudioStreamPlayer.new()
		p.bus = bus
		add_child(p)
		_gun_audio.append(p)
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_aux_audio.append(p)
	_snd["shot"] = Snd.set_of("weap/ar")
	_snd["heavy"] = Snd.set_of("weap/ar_heavy")
	_new_reports = not (_snd["shot"] as Array).is_empty() and not (_snd["heavy"] as Array).is_empty()
	if not _new_reports:
		_snd["shot"] = Snd.set_of("weap/rifle_shot")
		_snd["heavy"] = Snd.set_of("weap/rifle_heavy")
	_snd["gtail"] = Snd.set_of("weap/gtail")
	_snd["tick"] = Snd.set_of("hit/tick")
	_snd["kill"] = Snd.set_of("hit/kill")
	_synth_task = WorkerThreadPool.add_task(_build_synth, false, "weapon_audio")


func _build_synth() -> void:
	var gen := WeaponAudio.new()
	var out := {}
	for n in WeaponAudio.NAMES:
		out[n] = [gen.make(n)]
	_synth_mutex.lock()
	_synth_ready = out
	_synth_mutex.unlock()


func _load_set(pattern: String, n: int) -> Array:
	var out: Array = []
	for i in n:
		var path := pattern % i if pattern.contains("%") else pattern
		if ResourceLoader.exists(path):
			var s = load(path)
			if s != null:
				out.append(s)
	return out


## "Weapons" bus: tame the harsh 2-5 kHz, add low weight, glue with a compressor, a reverb that is
## re-sized to the surroundings per shot, and a limiter so nothing clips.
static func _weapons_bus() -> String:
	var name := "Weapons"
	var idx := AudioServer.get_bus_index(name)
	if idx >= 0:
		return name
	AudioServer.add_bus()
	idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, name)
	AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(idx, -2.5)
	# The recorded reports are mastered already (weap/ar*: weight at 100-250 Hz, 3 kHz tamed), so the
	# bus EQ only adds a little chest and takes the last edge off.
	var eq := AudioEffectEQ6.new()       # bands: 32, 100, 320, 1000, 3200, 10000 Hz
	eq.set_band_gain_db(0, 2.0)
	eq.set_band_gain_db(1, 3.0)
	eq.set_band_gain_db(2, 0.0)
	eq.set_band_gain_db(3, -0.5)
	eq.set_band_gain_db(4, -1.5)
	eq.set_band_gain_db(5, -0.5)
	AudioServer.add_bus_effect(idx, eq)
	# Gentle glue: the slowest attack Godot allows (2 ms) lets each shot's transient through, a soft
	# ratio holds the stacked bodies / tails of rapid fire together; the limiter below catches the peaks.
	var comp := AudioEffectCompressor.new()
	comp.threshold = -14.0
	comp.ratio = 2.5
	comp.attack_us = 2000.0
	comp.release_ms = 110.0
	comp.gain = 2.5
	AudioServer.add_bus_effect(idx, comp)
	var rv := AudioEffectReverb.new()
	rv.predelay_msec = 60.0
	rv.predelay_feedback = 0.2
	rv.room_size = 0.85
	rv.damping = 0.7
	rv.spread = 1.0
	rv.hipass = 0.2
	rv.wet = 0.16
	rv.dry = 1.0
	AudioServer.add_bus_effect(idx, rv)
	# Loud without clipping: a brick-wall ceiling with a short release (no pumping between shots).
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = -1.0
	lim.release = 0.08
	AudioServer.add_bus_effect(idx, lim)
	return name


## 0 = small room (almost dry, unused for now), 1 = tunnel / overhang, 2 = open air, 3 = vacuum.
func _space_kind() -> int:
	if GunFeel.in_vacuum():
		return 3
	var ac = Game.sfx.get("acoustics") if Game.sfx != null and is_instance_valid(Game.sfx) else null
	if ac != null and is_instance_valid(ac):
		return int(ac.space_kind())          # the measured room (scripts/audio/acoustics.gd)
	if player == null:
		return 2
	var hd: Vector3 = player.camera.global_position
	var upv: Vector3 = player.global_transform.basis.y
	var q := PhysicsRayQueryParameters3D.create(hd, hd + upv * 25.0, Game.LAYER_TERRAIN | Game.LAYER_SHIP)
	if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return 1
	return 2


func _set_space(kind: int) -> void:
	if Game.sfx != null and is_instance_valid(Game.sfx) and Game.sfx.get("acoustics") != null:
		return                               # acoustics.gd sizes the Weapons reverb continuously
	var idx := AudioServer.get_bus_index("Weapons")
	if idx < 0:
		return
	for e in AudioServer.get_bus_effect_count(idx):
		var rv := AudioServer.get_bus_effect(idx, e) as AudioEffectReverb
		if rv == null:
			continue
		match kind:
			0, 3:
				rv.room_size = 0.25
				rv.wet = 0.05
				rv.predelay_msec = 12.0
			1:
				rv.room_size = 0.6
				rv.wet = 0.18
				rv.predelay_msec = 35.0
			_:
				rv.room_size = 0.85
				rv.wet = 0.14
				rv.predelay_msec = 70.0


func _stream(name: String) -> AudioStream:
	if _synth_task >= 0 and WorkerThreadPool.is_task_completed(_synth_task):
		WorkerThreadPool.wait_for_task_completion(_synth_task)
		_synth_task = -1
		_synth_mutex.lock()
		_synth = _synth_ready
		_synth_mutex.unlock()
	var arr: Array = _snd.get(name, [])
	if arr.is_empty():
		arr = _synth.get(name, [])
	if arr.is_empty():
		return null
	return arr[randi() % arr.size()]


## Plays on the Weapons bus (gunshot layers) or the plain aux players. `cut` > 0 fades the sound
## out after that many seconds (used to trim the recorded crack).
func _play(name: String, vol := 0.0, pitch := 1.0, weapons_bus := false, cut := 0.0) -> AudioStream:
	var st := _stream(name)
	if st == null:
		return null
	var p: AudioStreamPlayer
	if weapons_bus:
		p = _gun_audio[_gun_audio_i]
		_gun_audio_i = (_gun_audio_i + 1) % _gun_audio.size()
		p.bus = _sbus                    # "Weapons", or the suppressed bus during a suppressed shot
	else:
		p = _aux_audio[_aux_i]
		_aux_i = (_aux_i + 1) % _aux_audio.size()
		# Handling foley in vacuum: only what the suit conducts (muffled).
		p.bus = "VacSuit" if GunFeel.in_vacuum() else "Master"
	p.stream = st
	p.volume_db = vol
	p.pitch_scale = pitch
	p.play()
	for f in _fades:
		if f[0] == p:
			_fades.erase(f)
			break
	if cut > 0.0:
		_fades.append([p, cut, vol])
	if debug_audio_log:
		audio_log.append(name)
	return st


## Trims sounds: after `cut` seconds the player fades to silence over FADE_LEN and stops.
func _update_fades(delta: float) -> void:
	if _fades.is_empty():
		return
	var keep: Array = []
	for f in _fades:
		var p: AudioStreamPlayer = f[0]
		f[1] = float(f[1]) - delta
		if float(f[1]) > 0.0:
			keep.append(f)
			continue
		var k := clampf(1.0 + float(f[1]) / FADE_LEN, 0.0, 1.0)
		if k <= 0.0 or not p.playing:
			p.stop()
			continue
		p.volume_db = float(f[2]) + linear_to_db(maxf(k * k, 0.0001))
		keep.append(f)
	_fades = keep


func _fire_sound() -> void:
	var a: Dictionary = AMMO[ammo_type]
	var sname: String = a["sound"]
	var pitch := randf_range(0.96, 1.04)
	if sname == "dart":
		_play("dart", -6.0, pitch)
		_play("action", -20.0, 1.3)
		return
	var space := _space_kind()
	_set_space(space)
	var heavy := sname == "heavy"
	if space == 3:
		# Vacuum: no crack, tail or echo; only the blow through the suit (Weapons bus low-passed).
		_play("thump", -4.0 if not heavy else -2.0, pitch * 0.9, true)
		_play("punch", -3.5 if not heavy else -1.5, pitch * 0.9, true)
		_play("action", -18.0, randf_range(0.95, 1.08))
		return
	if att_kit.suppressed():
		# Suppressed (attachments.gd): a muffled short report through the low-passed bus, the low body,
		# the bolt's clack close and clear; no crack layer, sub punch, outdoor tail or slap-back (a
		# short dark tail in a tunnel).
		var sp: Dictionary = Attachments.sup_sound(item_id)
		_sbus = Attachments.sup_bus()
		_play(sname, float(sp["db"]) + (1.5 if heavy else 0.0), float(sp["pitch"]) * pitch * (0.9 if heavy else 1.0), true,
				float(sp["cut"]))
		_play("thump", float(sp["thump"]) + (2.0 if heavy else 0.0), float(sp["tpitch"]) * pitch, true)
		_play("action", float(sp["action"]), float(sp["apitch"]) * randf_range(0.95, 1.08))
		if space == 1:
			_play("tail", -27.0, 1.3, true, 0.18)
		_sbus = "Weapons"
		return
	# The report (dense, with its own decay), the low body and sub kick, the bolt clack.
	var cut := REPORT_LEN if _new_reports else float(CRACK_LEN.get(sname, 0.3))
	_play(sname, -4.0 if not heavy else -3.0, pitch, true, cut)
	_play("thump", -10.0 if not heavy else -7.0, pitch * (0.9 if heavy else 1.0), true)
	_play("punch", -6.5 if not heavy else -4.0, pitch * (0.9 if heavy else 1.0), true)
	_play("action", -17.0 if not heavy else -15.0, randf_range(0.95, 1.08))
	if space == 2:
		# Open air: the rolling outdoor tail (one per TAIL_GAP: a burst shares it) and the slap-back.
		var now := Time.get_ticks_msec()
		if now - _tail_t >= int(TAIL_GAP * 1000.0):
			_tail_t = now
			if (_snd.get("gtail", []) as Array).is_empty():
				_play("tail", -17.0 if not heavy else -14.0, randf_range(0.92, 1.05), true)
			else:
				_play("gtail", -14.0 if not heavy else -11.0, randf_range(0.94, 1.04) * (0.94 if heavy else 1.0), true)
			_play("echo", -17.0 if not heavy else -14.0, randf_range(0.92, 1.04), true)
	elif space == 1:
		_play("tail", -21.0, 1.25, true, 0.25)


## Synthesized sound for the fx node (casing tink).
func synth_stream(name: String) -> AudioStream:
	return _stream(name)


# =================================================================================================
# Model
# =================================================================================================

## First-person model: white/orange rifle with iron sights (rear aperture + hooded front post with a
## glowing dot), hex handguard, glow strips, magazine (animated on reload), charging handle,
## ammo LEDs and a star-shaped muzzle flash (view-model space).
func build_model() -> Node3D:
	model = Node3D.new()
	_gun = VM.node(model)
	var white := VM.plastic_white()
	var orange := VM.suit_orange()
	var dark := VM.dark_metal()
	var steel := VM.metal()
	var rubber := VM.rubber()
	var gray := VM.mat(Color(0.3, 0.32, 0.35), 0.45, 0.4)
	var black := VM.mat(Color(0.03, 0.03, 0.035), 0.6, 0.2)
	var col := ammo_color()
	_accent_glow = VM.glow(col, 2.5)
	_mag_glow = VM.glow(col, 3.0)
	_led_mat = VM.glow(col, 4.0)
	_led_off = VM.glow(Color(0.1, 0.12, 0.14), 1.0)
	var by := 0.062                         # bore line height

	VM.grip(_gun, orange)
	# Trigger and guard.
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.02, -0.022), Vector3(0, -0.02, -0.072), 0.0045, steel)
	VM.capsule(_gun, Vector3(0, -0.02, -0.072), Vector3(0, 0.024, -0.084), 0.0045, steel)
	# Receiver: dark lower, white upper shell, orange side bands, vents.
	VM.soft_box(_gun, Vector3(0, 0.04, -0.04), Vector3(0.05, 0.05, 0.27), 0.012, gray)
	VM.soft_box(_gun, Vector3(0, 0.08, -0.05), Vector3(0.054, 0.036, 0.32), 0.014, white)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0275 * sx, 0.07, -0.05), Vector3(0.003, 0.01, 0.26), orange)
	for i in 4:
		VM.box(_gun, Vector3(-0.0285, 0.086, -0.13 - i * 0.02), Vector3(0.004, 0.014, 0.009), dark)
	# Stock: top bar, strut, rear plate, rubber butt pad.
	VM.soft_box(_gun, Vector3(0, 0.074, 0.165), Vector3(0.04, 0.03, 0.15), 0.012, white)
	VM.box(_gun, Vector3(0, 0.0905, 0.165), Vector3(0.03, 0.004, 0.12), orange)
	VM.capsule(_gun, Vector3(0, 0.03, 0.09), Vector3(0, 0.0, 0.245), 0.011, dark)
	VM.soft_box(_gun, Vector3(0, 0.04, 0.25), Vector3(0.036, 0.105, 0.035), 0.012, white)
	VM.soft_box(_gun, Vector3(0, 0.04, 0.273), Vector3(0.038, 0.112, 0.014), 0.006, rubber)
	# Handguard: hexagonal shroud with cut-outs, glowing under-strips.
	VM.seg(_gun, Vector3(0, by, -0.17), Vector3(0, by, -0.41), 0.033, 0.03, white, 6)
	for i in 5:
		for sx in [-1.0, 1.0]:
			VM.box(_gun, Vector3(0.029 * sx, by, -0.2 - i * 0.042), Vector3(0.008, 0.016, 0.024), dark)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.019 * sx, by - 0.027, -0.29), Vector3(0.004, 0.004, 0.19), _accent_glow)
	VM.box(_gun, Vector3(0, by + 0.03, -0.29), Vector3(0.014, 0.005, 0.22), dark)
	VM.ring(_gun, Vector3(0, by, -0.41), Vector3.FORWARD, 0.033, 0.006, orange)
	VM.ring(_gun, Vector3(0, by, -0.175), Vector3.FORWARD, 0.035, 0.005, dark)
	# Barrel, gas block and muzzle brake (the brake on its own node: a fitted muzzle device replaces it).
	VM.seg(_gun, Vector3(0, by, -0.41), Vector3(0, by, -0.56), 0.0115, 0.0115, steel, 12)
	VM.soft_box(_gun, Vector3(0, by + 0.004, -0.445), Vector3(0.024, 0.03, 0.03), 0.006, dark)
	var brake := VM.node(_gun)
	VM.soft_box(brake, Vector3(0, by, -0.575), Vector3(0.028, 0.026, 0.045), 0.008, dark)
	for z in [-0.565, -0.585]:
		for sx in [-1.0, 1.0]:
			VM.box(brake, Vector3(0.0145 * sx, by, z), Vector3(0.004, 0.016, 0.007), black)
	VM.ring(brake, Vector3(0, by, -0.598), Vector3.FORWARD, 0.011, 0.0035, steel)
	_muzzle = VM.node(_gun, Vector3(0, by, -0.605))
	# Receiver top rail (stays below the sight line; the optics clamp on it).
	VM.box(_gun, Vector3(0, 0.1, -0.075), Vector3(0.02, 0.006, 0.17), dark)
	for i in 7:
		VM.box(_gun, Vector3(0, 0.1035, -0.005 - i * 0.022), Vector3(0.022, 0.004, 0.008), dark)
	# Iron sights on their own node (hidden while an optic is fitted).
	var irons := VM.node(_gun)
	# Rear sight (gez): a protected aperture (ghost ring). A low base on the rail, a slim post holding a
	# thin ring round the sight line and two thin guard ears beside it: aimed, the front post sits in the
	# ring and the target shows all round it (the old notch block, 2.8 × 3.5 cm at 11 cm eye relief,
	# was a wall over a sixth of the view).
	var rz := SIGHT_REAR.z
	var ap_r := 0.0076                       # ring outer radius (the hole: 5.9 mm)
	var base_top := 0.1115
	VM.soft_box(irons, Vector3(0, (0.1015 + base_top) * 0.5, rz), Vector3(0.024, base_top - 0.1015, 0.02), 0.003, dark)
	VM.box(irons, Vector3(0, (base_top + SIGHT_Y - ap_r) * 0.5, rz), Vector3(0.005, SIGHT_Y - ap_r - base_top + 0.001, 0.008), dark)
	# (Short guard shoulders on the base: full-height ears beside the ring and beside the front post
	# read as stray vertical lines in the sight picture.)
	for sx in [-1.0, 1.0]:
		VM.box(irons, Vector3(0.0108 * sx, base_top + 0.0035, rz), Vector3(0.0034, 0.007, 0.012), dark)
	var ap := TorusMesh.new()
	ap.inner_radius = ap_r - 0.0017
	ap.outer_radius = ap_r
	ap.rings = 40
	ap.ring_segments = 8
	VM.mesh_inst(irons, ap, dark).transform = Transform3D(VM.basis_y(Vector3.BACK), Vector3(0, SIGHT_Y, rz))
	# Front sight (arpacık): tower on the gas block, thin post in a round hood (a globe: aimed it sits
	# concentric in the rear ring), glowing dot.
	var fz := SIGHT_FRONT_Z
	VM.box(irons, Vector3(0, (by + 0.02 + SIGHT_Y - 0.02) * 0.5 + 0.004, fz), Vector3(0.012, SIGHT_Y - 0.02 - by - 0.012, 0.016), dark)
	VM.box(irons, Vector3(0, SIGHT_Y - 0.0095, fz), Vector3(0.0035, 0.017, 0.006), black)
	VM.ring(irons, Vector3(0, SIGHT_Y - 0.002, fz), Vector3.BACK, 0.0105, 0.0022, dark)
	# (The tritium dot's centre exactly on the sight line, the post's tip just under it.)
	VM.sphere(irons, Vector3(0, SIGHT_Y, fz + 0.0035), 0.0016, VM.glow(Color(0.45, 1.0, 0.55), 4.0))
	# Underbarrel rail under the handguard (the foregrip / laser attachments clamp on it; the left hand
	# C-clamps the handguard behind it unless a foregrip is fitted).
	VM.soft_box(_gun, Vector3(0, 0.028, -0.34), Vector3(0.02, 0.016, 0.11), 0.005, dark)
	for i in 4:
		VM.box(_gun, Vector3(0, 0.0195, -0.3 - i * 0.026), Vector3(0.021, 0.003, 0.008), dark)
	left_grip = VM.node(_gun, Vector3(0, 0.004, -0.302), Basis(Vector3.UP, -0.35) * Basis(Vector3.RIGHT, 0.1))
	# Ejection port and charging handle (right side).
	VM.box(_gun, Vector3(0.0275, 0.082, -0.06), Vector3(0.004, 0.016, 0.04), black)
	_eject = VM.node(_gun, Vector3(0.036, 0.083, -0.06))
	_bolt = VM.node(_gun, Vector3(0.03, 0.082, 0.0))
	VM.capsule(_bolt, Vector3.ZERO, Vector3(0.02, 0.0, 0.004), 0.0055, steel)
	VM.sphere(_bolt, Vector3(0.022, 0.0, 0.004), 0.0085, orange)
	VM.box(_bolt, Vector3(-0.003, 0.0, -0.06), Vector3(0.004, 0.012, 0.035), steel)
	# Magazine (the left hand pulls it on reload; window glows in the ammo color).
	_mag = VM.node(_gun, MAG_REST)
	var mb := Basis(Vector3.RIGHT, 0.12)
	VM.soft_box(_mag, Vector3(0, -0.045, -0.004), Vector3(0.03, 0.1, 0.05), 0.01, dark, mb)
	VM.box(_mag, mb * Vector3(0, -0.088, 0.0) + Vector3(0, 0, -0.004), Vector3(0.034, 0.014, 0.055), orange, mb)
	for sx in [-1.0, 1.0]:
		VM.box(_mag, mb * Vector3(0.0158 * sx, -0.04, 0.0) + Vector3(0, 0, -0.004), Vector3(0.002, 0.05, 0.014), _mag_glow, mb)
	# Where the left wrist goes when it holds the magazine (just below and left of its base).
	_mag_grab = VM.node(_mag, mb * Vector3(-0.03, -0.13, 0.02))
	# The reload's hold on it (the view model solves the fingers against the magazine's own bake).
	left_hold = MAG_HOLD.duplicate()
	left_hold["root"] = _mag
	# Ammo counter LEDs on the left side.
	for i in 10:
		_leds.append(VM.box(_gun, Vector3(-0.0289, 0.047, 0.04 - i * 0.012), Vector3(0.002, 0.006, 0.008), _led_mat))
	# Muzzle flash: two ragged stars, two crossed plumes and a side flare (additive, view-model
	# space; build_flash). The rifle's is tight: a short plume.
	var fr := build_flash(_gun, Vector3(0, by, -0.61), 1.0, Color(1.0, 0.62, 0.22), 0.85)
	_flash_root = fr[0]
	_flash_mat = fr[1]
	VM.bake(_gun, [_mag, _bolt, _flash_root, _muzzle, _eject, left_grip, brake, irons] + _leds)
	VM.bake(_mag, [_mag_grab])
	VM.bake(_bolt)
	VM.bake(brake)
	VM.bake(irons)
	# Attachment mounts (attachments.gd builds every compatible part here, hidden until fitted; each
	# part bakes on its own so the hands' grip solve sees exactly what is shown).
	att_kit.build(self, _gun, {
		"muzzle": {"at": Vector3(0, by, -0.552), "r": 0.0115, "tip": -0.598, "sup_r": 0.019, "sup_len": 0.17,
			"shift": [_muzzle, _flash_root], "default": brake},
		"optic": {"y": 0.1055, "z": -0.05, "irons": SIGHT_Y, "default": irons},
		"under": {"grip": Vector3(0, 0.02, -0.305), "laser": Vector3(0, 0.02, -0.368)},
	})
	return model


# =================================================================================================
# Third-person prop (registered in the astronaut's held-item table)
# =================================================================================================

func _build_tp_prop() -> void:
	if player == null:
		return
	var ast = player.get("astronaut")
	if ast == null or not ("props" in ast) or not ("hand" in ast):
		return
	if ast.props.has("rifle"):
		_tp_tip = ast.prop_tips.get("rifle")
		att_kit.build_tp(ast.props["rifle"], _tp_tip, ast)     # the fitted attachments on the prop
		return
	var hands: Array = ast.hand
	if hands.size() < 2 or hands[1] == null:
		return
	var white := _tp_mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tp_mat(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _tp_mat(Color(0.16, 0.17, 0.19), 0.4, 0.6)
	var p := VM.node(hands[1], Vector3(0, -0.09, 0), Basis(Vector3.RIGHT, -PI * 0.5))
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.06, -0.05), Vector3(0.05, 0.07, 0.3), white)
	VM.box(p, Vector3(0, 0.05, 0.17), Vector3(0.036, 0.09, 0.15), white)
	VM.box(p, Vector3(0.027, 0.065, -0.05), Vector3(0.004, 0.012, 0.26), orange)
	VM.seg(p, Vector3(0, 0.062, -0.2), Vector3(0, 0.062, -0.41), 0.032, 0.03, white, 6)
	VM.seg(p, Vector3(0, 0.062, -0.41), Vector3(0, 0.062, -0.6), 0.012, 0.012, dark, 10)
	VM.box(p, Vector3(0, 0.1, -0.43), Vector3(0.012, 0.04, 0.016), dark)
	VM.box(p, Vector3(0, -0.03, -0.085), Vector3(0.03, 0.1, 0.05), dark)
	_tp_tip = VM.node(p, Vector3(0, 0.062, -0.61))
	p.visible = false
	ast.props["rifle"] = p
	ast.prop_tips["rifle"] = _tp_tip
	# Join the astronaut's first-person hiding (shadow-only body meshes) and its visual layer.
	var list = ast.get("_meshes")
	for mi in p.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).layers = 2
		if list is Array:
			list.append(mi)
	if ast.has_method("set_first_person"):
		ast.set_first_person(not player.is_ragdolled())
	att_kit.build_tp(p, _tp_tip, ast)                           # the fitted attachments on the prop


func _tp_mat(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m
