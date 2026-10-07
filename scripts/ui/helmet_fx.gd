extends Node
## Inside the helmet: the suit you fight in, heard and seen from inside. Local only (nothing here is
## networked). Metro's gas mask, Dead Space, ODST: close, heavy, a little muffled, kept subtle.
##
## Breathing: the game's one breathing voice (feel_fx.gd's suppression breath and the sniper's
## breath hold come through here). The user's recording (assets/audio/helmet/breath_*, licence
## assets/audio/LICENSE_Pixabay.txt) was cut offline into 4 inhales / 4 exhales, cleaned (the
## handling rumble high-passed, a light denoise, a gentle expander in the gaps), helmet-coloured
## (close body ~230 Hz, a slightly boxy 560 Hz, a gentle top roll-off, a 2.7 / 4.4 ms visor
## reflection) and loudness-matched (inhales -23 LUFS, exhales -20) at three intensities: calm (slow
## nose breaths: stretched ×1.25, darker, softer onsets), exert (mouth breaths, as recorded), panic
## (×1.37 faster, 5 % higher, sharper), plus the sniper's hold (an intake caught short) and release
## (a relieved sigh). How hard you breathe:
##   exertion  `exertion` 0..1, an oxygen debt. Sprinting +0.085/s at full speed, the jetpack
##             +0.05/s, walking, sliding and the drill a little; a jump +0.03, a landing +0.015 ..
##             0.115 by the fall speed, a melee swing +0.06, getting up +0.08, damage taken. It
##             recovers 0.05/s standing (0.035 walking, ×1.25 crouched), never while sprinting or
##             burning the jet: from spent to calm in ~20-30 s.
##   stress    max(suppression × 0.95 (feel_fx.gd), blast deafness × 0.8, low health (45 % → 12 %)
##             × 0.8, a recent hit (damage / 35, fading over ~6 s)).
##   target    max(exertion', stress) + 0.2 × min(exertion', stress) (exertion' = smoothstep(0, 0.85,
##             exertion)); `intensity` follows it in ~1 s going up and ~4 s coming down.
## Rhythm: inhale, a short catch, exhale, a pause. Durations come from the samples; the catch and the
## pause shrink with intensity (calm ~13 breaths / min, exerted ~24, panicked ~45) with natural
## jitter, and a scare cuts a long pause short. The set is picked per breath (blended odds near the
## boundaries), never the same variant twice in a row; two players alternate so tails overlap.
## Sniper (sniper.gd _update_breath → sniper_breath()): Shift in the scope plays the hold intake,
## then silence while the breath is held (the view rests on full lungs); letting go sighs; running
## out gasps and forces a few panicked breaths. Death: one last breath out.
##
## Helmet acoustics: the outside world reaches the ear through the helmet. On the world buses
## (HELM_BUSES: "Env", "Weapons", "Skiff") three named effects sit right after the room
## (acoustics.gd's reverb) and before the feel_fx.gd muffle ("dmg_muffle" / "feel_duck"), sfx.gd's
## vacuum low-pass and any limiter: "helm_body" (low shelf +2 dB below ~250 Hz: body, heavier
## thumps), "helm_air" (high shelf -3 dB above ~6.5 kHz) and "helm_er" (two visor reflections, 2.8 /
## 4.5 ms, -18 / -21 dB, panned apart). Found by name, re-validated every second, never duplicated
## (AudioServer outlives scene reloads). The breathing and the suit live dry on their own "Helmet"
## bus (→ Master): close, untouched by the world muffle, heard in vacuum too. Body-conducted low end:
## the guns already carry sub "punch" / "thump" layers (weapon_base.gd _shot_body); the footsteps
## (on the body's gait clock, like sfx.gd's gear) and the landings get a synthesized sub thud here.
##
## Suit bed (on the Helmet bus): a life-support blower loop (assets/audio/helmet/suit_fan.wav, from
## the Sonniss BluezoneCorp cargo-ship cockpit tone plus a faint airflow hiss), felt more than heard,
## working a little harder (+5 dB, +5 % pitch) as you breathe harder and +2.5 dB in vacuum; rare
## synthesized suit creaks (stick-slip) on jumps, landings, slides, crouching and melee; joint servo
## whirrs (suit_servo_NN, 3maze motors, swept up in pitch) on hard landings and getting up; a comms
## click on a new HUD message (hud.gd's toast timer watched read-only), at most once a second.
##
## Visor. The surface is a depth-masked full-screen quad in the 3D pass (VISOR_SHADER, right after
## motion_blur.gd's): a very faint darkening and soft blur at the extreme rim (a superellipse: the
## corners close first, the chin a little heavier; no colour fringe), a few short scratches and dust
## that catch light faintly only in a small glare zone round the sun when you look toward it
## (Game.sun_dir against the view, the planet and the rock in between checked), condensation patches
## at the lower edge that bloom on every exhale of heavy
## breathing and clear when calm. None of it ever touches the view model (nearer than 0.6 m / its
## depth slice) or a ~0.05 screen-height margin around it, nor the crosshair area. Cracks (the bots'
## visor-crack style: an impact star, jagged radial cracks, broken rings; upper half and sides only)
## after a heavy hit (>= 25 damage at once: a white flash and a glass crack) or below 30 % health,
## kept until fully healed, then fading: a CanvasLayer at 2 (CRACK_SHADER, under feel_fx's
## concussion pass (3), the scope (4) and the HUD (5)), drawn only while there is a crack or a flash.
##
## Breath camera: the view rises a little on every inhale and settles on the exhale (0.8 mm and
## 0.03° calm, 4 mm and 0.2° spent), on foot only. Position as a delta on camera.position (like
## melee.gd, so the two compose), pitch added after the player resets the camera rotation
## (process_priority, like feel_fx.gd's tremble); much less while aiming down sights.
##
## Setting "Kask efektleri" (Settings.helmet_fx: 0 Kapalı, 1 Düşük, 2 Orta = default): off hides the
## visor, bypasses the helmet colouring and silences the suit bed, the body thuds and the breath
## camera; the breathing then only plays when it is hard (intensity > 0.35, as the old suppression
## breath did) and for the sniper's hold. Low halves most of it.
##
##   HelmetFx.inst()        the instance (child of the Game autoload, made on first use)
##   HelmetFx.peek()        the instance or null (never creates)
##   HelmetFx.exhaustion()  exertion 0..1 (damage_ui.gd's heartbeat)
##   sniper_breath(kind)    "in" / "out" / "gasp"; false when the sounds are not ready (fallback)
##   comms()                the helmet comms click (played on new HUD toasts by itself)
##   exertion, stress, intensity   current levels (0..1)

const Settings := preload("res://scripts/save/settings.gd")
const WeaponAudio := preload("res://scripts/items/weapon_audio.gd")

const BUS := "Helmet"
const DIR := "res://assets/audio/helmet/"
const HELM_BUSES := ["Env", "Weapons", "Skiff"]
const FX_BODY := "helm_body"
const FX_AIR := "helm_air"
const FX_ER := "helm_er"
## Effects the helmet colouring must stay in front of (feel_fx.gd's muffle and duck, sfx.gd's vacuum
## low-pass); limiters are matched by type.
const FX_BEFORE := ["dmg_muffle", "feel_duck", "snd_vacuum_lp"]
const RATE := 44100
const SETS := ["calm", "exert", "panic"]
const HEAVY_HIT := 25.0                    # damage at once that cracks the visor
const CRACK_HP := 0.3                      # below this health fraction a crack appears anyway
const MAX_CRACKS := 3
const COMMS_GAP := 1.0

## The visor surface: a full-screen quad drawn at the near plane in the transparent pass, right
## after motion_blur.gd's (render priority MIN + 1), reading the opaque screen and the depth buffer.
## Everything nearer than near_dist (on foot: the view model, which vm_parts.gd keeps in the
## [0.92, 1] reverse-Z slice) is left untouched, and a ring of depth taps keeps a margin of ~0.05
## screen heights around it, so the arms and the gun never get rim, glints or fog. Output is an
## alpha-blended layer stack over whatever is below (the motion blur survives): a soft blur and a
## faint darkening at the extreme rim (no colour fringe), the condensation, the sun glints (added).
## Positions are SCREEN_UV, y down.
const VISOR_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D grime_tex : repeat_disable, filter_linear_mipmap;
uniform sampler2D fog_tex : repeat_enable, filter_linear_mipmap;
uniform float near_dist = 0.6;      // m: nearer pixels (the view model) are left alone
uniform float rim = 0.2;            // helmet edge darkness
uniform float soft = 0.4;           // edge blur
uniform float sun = 0.0;            // sun ahead and unblocked 0..1
uniform vec2 sun_uv = vec2(0.5, 0.5);
uniform float fog = 0.0;            // condensation 0..1
uniform float t = 0.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float own_at(vec2 uv, float mask_z) {
	return step(mask_z, textureLod(depth_tex, clamp(uv, vec2(0.001), vec2(0.999)), 0.0).r);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	// Reverse-Z (larger = nearer): the depth value at near_dist; the view model's slice is always in.
	vec4 mc = PROJECTION_MATRIX * vec4(0.0, 0.0, -near_dist, 1.0);
	float mask_z = min(mc.z / mc.w, 0.9);
	float aspect = VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;
	vec2 q = uv * 2.0 - 1.0;
	float cdist = length(vec2((uv.x - 0.5) * aspect, uv.y - 0.5));
	vec2 g = textureLod(grime_tex, uv, 0.0).rg;
	float n = textureLod(fog_tex, uv * vec2(aspect, 1.0) * 0.8 + vec2(t * 0.004, t * 0.0015), 0.0).r;
	if (own_at(uv, mask_z) > 0.5) {
		discard;
	}
	// Helmet edge: a rounded superellipse, the corners close first, the chin a little heavier.
	vec2 qa = abs(q) * vec2(1.0, 1.0 + 0.05 * step(0.0, q.y));
	float e = pow(pow(qa.x, 5.0) + pow(qa.y, 5.0), 0.2);
	float edge = smoothstep(0.92, 1.16, e) * rim;
	float blur = smoothstep(0.86, 1.12, e) * soft;
	// Condensation on the lower visor (the mouth's side), patchy, never near the centre.
	float low_m = smoothstep(0.3, 0.95, q.y) * (0.8 + 0.2 * abs(q.x));
	float th = 1.0 - 0.85 * fog;
	float fm = smoothstep(th - 0.12, th + 0.18, low_m + (n - 0.5) * 0.5);
	fm *= (0.3 + 0.7 * fog) * step(0.001, fog) * smoothstep(0.24, 0.42, cdist);
	// Scratches (r) and dust (g) catch light only in a small glare zone round the sun (~0.25 screen
	// heights; none elsewhere: lit all over they read as rain), dim; the centre stays clean.
	float sd = length(vec2((uv.x - sun_uv.x) * aspect, uv.y - sun_uv.y));
	float cm = smoothstep(0.1, 0.3, cdist);
	float gz = exp(-sd * sd * 24.0);
	float gl = (g.r * 0.11 + g.g * 0.08) * sun * gz * cm
			+ 0.02 * sun * exp(-sd * sd * 6.0) * (0.4 + 0.6 * cm);
	if (edge < 0.001 && blur < 0.002 && fm < 0.002 && gl < 0.0005) {
		discard;
	}
	// A margin around the view model: a ring of depth taps (0.05 and 0.022 screen heights).
	float near_vm = 0.0;
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.7853982;
		vec2 o = vec2(cos(a) / aspect, sin(a));
		near_vm = max(near_vm, own_at(uv + o * 0.05, mask_z));
		if (i % 2 == 0) {
			near_vm = max(near_vm, own_at(uv + o * 0.022, mask_z));
		}
	}
	if (near_vm > 0.5) {
		discard;
	}
	// The layers, each over the last (premultiplied colour cp, transmittance tr).
	vec3 base = textureLod(screen_tex, uv, 0.0).rgb;
	vec3 cp = vec3(0.0);
	float tr = 1.0;
	if (blur > 0.002) {
		float w = clamp(blur, 0.0, 1.0);
		cp = cp * (1.0 - w) + textureLod(screen_tex, uv, 1.0 + blur).rgb * w;
		tr *= 1.0 - w;
	}
	if (fm > 0.002) {
		vec3 b = textureLod(screen_tex, uv, 3.5).rgb;
		float l = dot(b, vec3(0.2126, 0.7152, 0.0722));
		vec3 fc = mix(b, vec3(l), 0.35) * 1.05 + vec3(0.028, 0.03, 0.033);
		float w = clamp(fm, 0.0, 0.88);
		cp = cp * (1.0 - w) + fc * w;
		tr *= 1.0 - w;
	}
	if (gl > 0.0005) {
		// Added light (HDR-safe): a small share of the pixel replaced by itself plus the glint.
		float w = clamp(gl * 3.0, 0.0, 1.0);
		cp = cp * (1.0 - w) + (base + vec3(1.0, 0.95, 0.86) * gl / w) * w;
		tr *= 1.0 - w;
	}
	cp *= 1.0 - edge;
	tr *= 1.0 - edge;
	float alpha = 1.0 - tr;
	if (alpha < 0.001) {
		discard;
	}
	ALBEDO = cp / alpha;
	ALPHA = alpha;
}
"""

## Cracks and the hit flash: a CanvasLayer (2) over the picture, under feel_fx.gd's concussion pass
## (3), the scope (4) and the HUD (5); only drawn while there is a crack or a flash.
const CRACK_SHADER := """
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D crack_tex : repeat_disable, filter_linear_mipmap;
uniform vec4 crack_a = vec4(0.0);   // xy centre (UV), z size (screen heights), w angle
uniform vec4 crack_b = vec4(0.0);
uniform vec4 crack_c = vec4(0.0);
uniform vec3 crack_w = vec3(0.0);   // their weights 0..1
uniform float sun = 0.0;
uniform vec2 sun_uv = vec2(0.5, 0.5);
uniform float flash = 0.0;

// Coverage of one crack at p (screen-height units, origin top left).
float crack_at(vec2 p, float aspect, vec4 cr, float w) {
	vec2 c = vec2(cr.x * aspect, cr.y);
	vec2 d = (p - c) / max(cr.z, 0.001);
	float s = sin(cr.w);
	float co = cos(cr.w);
	vec2 r = vec2(d.x * co - d.y * s, d.x * s + d.y * co) + vec2(0.5);
	float inside = step(0.0, r.x) * step(0.0, r.y) * step(r.x, 1.0) * step(r.y, 1.0);
	return texture(crack_tex, r).a * inside * w;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = SCREEN_PIXEL_SIZE;
	float aspect = px.y / px.x;
	vec2 p = vec2(UV.x * aspect, UV.y);
	float cdist = length(vec2((UV.x - 0.5) * aspect, UV.y - 0.5));
	vec2 dir = normalize(UV * 2.0 - 1.0 + vec2(0.0001));
	float ca = crack_at(p, aspect, crack_a, crack_w.x) + crack_at(p, aspect, crack_b, crack_w.y)
			+ crack_at(p, aspect, crack_c, crack_w.z);
	ca = clamp(ca, 0.0, 1.0) * smoothstep(0.14, 0.26, cdist);
	float sd = length(vec2((UV.x - sun_uv.x) * aspect, UV.y - sun_uv.y));
	float glare = sun * (0.25 + 0.75 * exp(-sd * sd * 5.0));
	vec3 cp = vec3(0.0);
	float tr = 1.0;
	if (ca > 0.002) {
		// The broken glass bends the view a little, darkens it and its edges catch light.
		vec3 refr = textureLod(screen_tex, clamp(uv + dir * px * 3.0 * ca, vec2(0.001), vec2(0.999)), 0.6).rgb;
		float w = ca * 0.55;
		cp = refr * 0.55 * w + vec3(0.82, 0.88, 0.95) * ca * (0.22 + 0.5 * glare);
		tr = 1.0 - w;
	}
	float f = clamp(flash, 0.0, 1.0);
	cp = cp * (1.0 - f) + vec3(f);
	tr *= 1.0 - f;
	float alpha = 1.0 - tr;
	COLOR = vec4(cp / max(alpha, 0.0001), alpha);
}
"""

# Shared across instances / scene reloads (built once on a worker thread).
static var _assets := {}                   # name -> stream / image; "ready" when taken
static var _task := -1
static var _mutex := Mutex.new()
static var _out := {}

var exertion := 0.0
var stress := 0.0
var intensity := 0.0

var _t := 0.0
var _lv := -1                              # applied setting level
var _sets := {}                            # "in_calm" .. "out_panic" -> Array[AudioStream]
var _last_pick := {}                       # set key -> last index
var _bp: Array = []                        # two breath players (alternating)
var _bp_i := 0
var _fx: Array = []                        # one-shot pool (Helmet bus)
var _fx_i := 0
var _fan: AudioStreamPlayer
var _fan_db := -80.0
var _servo: AudioStreamPlayer
var _servo_t := 9.0
var _servo_len := 0.4
var _servo_pitch := 1.0
# Breathing.
var _phase := 0                            # 0 waiting to breathe in, 1 waiting to breathe out, 2 held
var _next := 1.5                           # when the next breath starts (_t)
var _pause_from := 0.0                     # when the pause after the last exhale began (_t)
var _cur_set := "calm"
var _held := false
var _boost := 0.0
var _hit_stress := 0.0
var _lung := 0.3
var _lung_a := 0.3
var _lung_b := 0.3
var _lung_t := 0.0
var _lung_d := 1.0
var _exhale_t := 9.0                       # s into the current exhale (fog)
var _exhale_len := 1.0
var _exhale_fog := 0.0
# Tracking the player.
var _pid := 0
var _was_dead := false
var _hp_prev := -1.0
var _floor_prev := true
var _air_t := 0.0
var _fall_v := 0.0
var _gait_half := -1
var _slide_prev := false
var _crouch_prev := false
var _creak_cd := 0.0
var _servo_cd := 0.0
var _comms_t := -9.0
var _toast_prev := 0.0
var _bus_check := 0.0
# Visor.
var _quad: MeshInstance3D                  # the visor surface (VISOR_SHADER)
var _qmat: ShaderMaterial
var _layer: CanvasLayer                    # cracks + flash (CRACK_SHADER)
var _rect: ColorRect
var _mat: ShaderMaterial
var _tex_ready := false
var _fog_base := 0.0
var _fog_pulse := 0.0
var _flash := 0.0
var _cracks: Array = []                    # {uv: Vector2, size: float, rot: float, w: float}
var _crack_fade := false
var _sun_vis := 0.0
var _sun_vis_t := 0.0
var _sun_check := 0.0
var _sun_uv := Vector2(0.5, 0.5)
# Breath camera.
var _cam: Camera3D
var _cam_off := Vector3.ZERO


static func inst() -> Node:
	var h := peek()
	if h != null:
		return h
	var n: Node = load("res://scripts/ui/helmet_fx.gd").new()
	n.name = "HelmetFx"
	Game.add_child(n)
	Game.set_meta("helmet_fx", n)
	return n


static func peek() -> Node:
	if Game.has_meta("helmet_fx"):
		var h = Game.get_meta("helmet_fx")
		if is_instance_valid(h):
			return h
	return null


## Exertion 0..1 (0 without the module).
static func exhaustion() -> float:
	var h = peek()
	return float(h.exertion) if h != null else 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	process_priority = 110                  # after the player resets its camera and the guns add to it
	_ensure_bus()
	for i in 2:
		_bp.append(_player())
	for i in 5:
		_fx.append(_player())
	_servo = _player()
	_fan = _player()
	_build_visor()
	_start_assets()


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_take_assets()
	_remove_cam_offset()
	_drive_helmet_buses(0, true)


func _player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = BUS
	add_child(p)
	return p


## Setting level: 0 off, 1 low, 2 medium.
func level() -> int:
	return clampi(int(Settings.helmet_fx), 0, 2)


# =================================================================================================
# Public API
# =================================================================================================

## The sniper's breath (sniper.gd): "in" (hold), "out" (let go), "gasp" (ran out). False when the
## recorded set is not loaded yet (the sniper then plays its own).
func sniper_breath(kind: String) -> bool:
	if _sets.is_empty():
		return false
	var a: Array = _assets.get("hold", [])
	var r: Array = _assets.get("release", [])
	var lv := level()
	var off_db := -3.0 if lv == 1 else (-2.0 if lv == 0 else 0.0)
	match kind:
		"in":
			if a.is_empty():
				return false
			var s: AudioStream = a[randi() % a.size()]
			var len := _breath_play(s, -14.0 + off_db, randf_range(0.97, 1.03))
			_held = true
			_phase = 2
			_lung_to(1.0, len * 0.9)
		"out", "gasp":
			if r.is_empty():
				return false
			var gasp := kind == "gasp"
			var s: AudioStream = r[randi() % r.size()]
			var len := _breath_play(s, (-9.0 if gasp else -13.0) + off_db, randf_range(1.02, 1.06) if gasp else randf_range(0.96, 1.02))
			_held = false
			_phase = 0
			_lung_to(0.0, len * 0.9)
			_start_exhale_fog(len, 0.6 if gasp else 0.2)
			if gasp:
				_boost = 0.9
				intensity = maxf(intensity, 0.75)    # the recovery breaths come at once
				exertion = minf(exertion + 0.12, 1.0)
				_pause_from = _t + len * 0.72
				_next = _pause_from + 0.04
			else:
				_pause_from = _t + len * 0.9
				_next = _pause_from + _pause_len(maxf(intensity, 0.3)) * 0.6
	return true


## A helmet comms click, at most once a second (a new HUD toast: _watch_toast).
func comms() -> void:
	if level() < 2 or _t - _comms_t < COMMS_GAP:
		return
	var s = _assets.get("comms")
	if s == null or not _alive():
		return
	_comms_t = _t
	_fx_play(s, -24.0, randf_range(0.98, 1.03))


func debug_state() -> Dictionary:
	return {"exertion": exertion, "stress": stress, "intensity": intensity, "phase": _phase,
			"held": _held, "lung": _lung, "fog": _fog_base, "cracks": _cracks.size(), "set": _cur_set,
			"sun": _sun_vis, "level": level()}


# =================================================================================================
# Per frame
# =================================================================================================

func _process(delta: float) -> void:
	_t += delta
	_poll_assets()
	var lv := level()
	_bus_check -= delta
	if lv != _lv or _bus_check <= 0.0:
		_bus_check = 1.0
		_lv = lv
		_ensure_bus()
		_drive_helmet_buses(lv, false)
	var p = Game.player
	if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
		_idle(delta)
		return
	_track(p, delta)
	_watch_toast()
	_update_exertion(p, delta)
	_update_intensity(p, delta)
	_update_breath(p, delta)
	_update_lung(delta)
	_update_bed(p, delta, lv)
	_update_camera(p, lv)
	_update_visor(p, delta, lv)


func _alive() -> bool:
	var p = Game.player
	return p != null and is_instance_valid(p) and not p.is_dead()


## A new HUD toast (hud.gd show_message restarts its timer `_toast_t`): the comms click. Read only,
## so hud.gd needs no hook; without that field it simply stays quiet.
func _watch_toast() -> void:
	var hud = Game.hud
	if hud == null or not is_instance_valid(hud):
		_toast_prev = 0.0
		return
	var tt = hud.get("_toast_t")
	if not (tt is float):
		return
	if float(tt) > _toast_prev + 0.05:
		comms()
	_toast_prev = float(tt)


## No player (menus, between scenes): quiet, nothing on screen, nothing on the camera.
func _idle(delta: float) -> void:
	_rect.visible = false
	_quad.visible = false
	_remove_cam_offset()
	_fan_db = maxf(_fan_db - delta * 30.0, -80.0)
	_fan.volume_db = _fan_db
	if _fan.playing and _fan_db <= -79.0:
		_fan.stop()
	_pid = 0
	_held = false


# =================================================================================================
# Events: hits, heals, death, steps, landings, jumps
# =================================================================================================

func _track(p, delta: float) -> void:
	var id: int = (p as Node).get_instance_id()
	var dead: bool = p.is_dead()
	var hpk := clampf(float(p.hp) / maxf(float(p.hp_max), 1.0), 0.0, 1.0)
	if id != _pid:
		# A new player (scene start / reload): wire its signals, start calm.
		_pid = id
		_hp_prev = float(p.hp)
		_was_dead = dead
		_floor_prev = true
		_gait_half = -1
		_cracks.clear()
		_fog_base = 0.0
		exertion = 0.0
		_held = false
		_cam = null
		_cam_off = Vector3.ZERO
		if p.has_signal("melee_swung") and not p.melee_swung.is_connected(_on_melee):
			p.melee_swung.connect(_on_melee)
		if p.has_signal("hit_reacted") and not p.hit_reacted.is_connected(_on_hit_reacted):
			p.hit_reacted.connect(_on_hit_reacted)
	_creak_cd = maxf(_creak_cd - delta, 0.0)
	_servo_cd = maxf(_servo_cd - delta, 0.0)
	# Death: one last breath out, then silence until the respawn.
	if dead and not _was_dead:
		_held = false
		_phase = 0
		var r: Array = _assets.get("release", [])
		if not r.is_empty():
			_breath_play(r[0], -7.0, 0.86)
		_lung_to(0.0, 1.2)
	elif _was_dead and not dead:
		_cracks.clear()
		_crack_fade = false
		_fog_base = 0.0
		_fog_pulse = 0.0
		exertion = 0.15
		intensity = 0.15
		_hit_stress = 0.0
		_pause_from = _t
		_next = _t + 1.0
		_hp_prev = float(p.hp)
	_was_dead = dead
	# Damage taken: stress, a little breath cost, and a heavy one cracks the visor.
	var hp := float(p.hp)
	var drop := _hp_prev - hp
	if drop > 0.5 and not dead:
		_hit_stress = maxf(_hit_stress, clampf(drop / 35.0, 0.25, 1.0))
		exertion = minf(exertion + drop / 300.0, 1.0)
		if drop >= HEAVY_HIT:
			_add_crack(true)
	_hp_prev = hp
	if not dead and hpk < CRACK_HP and _cracks.is_empty():
		_add_crack(false)
	if not _cracks.is_empty() and hpk >= 0.98:
		_crack_fade = true
	if dead or p.vehicle != null or p.is_ragdolled() or p.get("waiting_ground") == true:
		_floor_prev = true
		_air_t = 0.0
		_fall_v = 0.0
		_gait_half = -1
		return
	var on_floor: bool = p.is_on_floor()
	var up: Vector3 = p.global_transform.basis.y
	var vel: Vector3 = p.velocity
	var v_up := vel.dot(up)
	var hs := (vel - up * v_up).length()
	var sliding: bool = p.get("sliding") == true
	var crouched: bool = p.get("crouching") == true
	var crouch_k := clampf(float(p.get("crouch_k")) if p.get("crouch_k") != null else 0.0, 0.0, 1.0)
	# Footsteps (the body's gait: a foot plants at phase 0 and 0.5): a body-conducted sub thud.
	var st = p.get("stance")
	var steps_on: bool = st == null or not st.has_method("steps_on") or st.steps_on()
	if on_floor and hs > 1.0 and not sliding and steps_on and p.astronaut != null:
		var half := floori(float(p.astronaut._phase) * 2.0)
		if half != _gait_half:
			if _gait_half != -1:
				var run := maxf(clampf(float(p.get("_sprint_k")), 0.0, 1.0), clampf((hs - 5.0) / 3.2, 0.0, 1.0))
				_body_thud(lerpf(-31.0, -21.0, run) - crouch_k * 8.0, randf_range(0.94, 1.06), false)
			_gait_half = half
	elif not on_floor:
		_gait_half = -1
	# Landings and jumps.
	if on_floor:
		if not _floor_prev and (_air_t > 0.25 or _fall_v > 2.5):
			var k := clampf((_fall_v - 2.0) / 8.0, 0.0, 1.0)
			_body_thud(lerpf(-26.0, -7.0, k), lerpf(1.04, 0.86, k), true)
			exertion = minf(exertion + 0.015 + 0.1 * k, 1.0)
			if k > 0.2 and randf() < 0.4:
				_creak(lerpf(-27.0, -19.0, k))
			if k > 0.45 and randf() < 0.55:
				_servo_whirr(lerpf(-22.0, -15.0, k))
		_air_t = 0.0
		_fall_v = 0.0
	else:
		if _floor_prev and v_up > 1.2 and Input.is_action_pressed("jump"):
			exertion = minf(exertion + 0.03, 1.0)
			if randf() < 0.25:
				_creak(-26.0)
		_air_t += delta
		_fall_v = maxf(_fall_v, -v_up)
	_floor_prev = on_floor
	# Slide in, crouch / stand.
	if sliding and not _slide_prev:
		exertion = minf(exertion + 0.03, 1.0)
		if randf() < 0.3:
			_creak(-24.0)
	elif crouched != _crouch_prev and not sliding and randf() < 0.18:
		_creak(-28.0)
	_slide_prev = sliding
	_crouch_prev = crouched


func _on_melee(_from: Vector3, _dir: Vector3) -> void:
	exertion = minf(exertion + 0.06, 1.0)
	if randf() < 0.3:
		_creak(-24.0)


func _on_hit_reacted(kind: String, _dir: Vector3, _strength: float, _bone: String) -> void:
	if kind == "getup":
		exertion = minf(exertion + 0.08, 1.0)
		_servo_whirr(-17.0)
		_creak(-23.0)
	elif kind == "knockdown":
		_hit_stress = maxf(_hit_stress, 0.7)


# =================================================================================================
# Exertion, stress, intensity
# =================================================================================================

func _update_exertion(p, delta: float) -> void:
	var dead: bool = p.is_dead()
	var on_foot: bool = p.vehicle == null and not p.is_ragdolled() and not dead
	var up: Vector3 = p.global_transform.basis.y
	var vel: Vector3 = p.velocity
	var hs := (vel - up * vel.dot(up)).length()
	var on_floor: bool = on_foot and p.is_on_floor()
	var sprint := clampf(float(p.get("_sprint_k")), 0.0, 1.0) if on_foot else 0.0
	var jet: bool = on_foot and p.jetting
	var demand := 0.0
	if on_foot:
		if on_floor and hs > 1.0:
			demand += lerpf(0.003, 0.012, clampf(hs / 5.0, 0.0, 1.0))
			demand += 0.085 * sprint * clampf(hs / 6.0, 0.0, 1.0)
		if jet:
			demand += 0.05 * clampf(float(p.jet_effect()) * 1.3, 0.3, 1.0)
		if p.get("sliding") == true:
			demand += 0.02
		var tl = p.get("tool")
		if tl != null and tl.get("using") == true and p.current() == tl:
			demand += 0.006
	var rec := 0.0
	if sprint < 0.15 and not jet:
		var moving := clampf(hs / 5.0, 0.0, 1.0) if on_floor else 0.5
		rec = lerpf(0.05, 0.035, moving)
		if clampf(float(p.get("crouch_k")) if p.get("crouch_k") != null else 0.0, 0.0, 1.0) > 0.5:
			rec *= 1.25
	exertion = clampf(exertion + (demand - rec) * delta, 0.0, 1.0)


func _update_intensity(p, delta: float) -> void:
	var supp := 0.0
	var deaf := 0.0
	if Game.has_meta("feel_fx"):
		var ff = Game.get_meta("feel_fx")
		if is_instance_valid(ff):
			supp = float(ff.suppression)
			deaf = float(ff.deaf)
	var hpk := clampf(float(p.hp) / maxf(float(p.hp_max), 1.0), 0.0, 1.0)
	var low := 1.0 - smoothstep(0.12, 0.45, hpk)
	_hit_stress = maxf(_hit_stress - delta * 0.16, 0.0)
	_boost = maxf(_boost - delta * 0.25, 0.0)
	stress = maxf(maxf(supp * 0.95, deaf * 0.8), maxf(low * 0.8, _hit_stress))
	if p.is_dead():
		stress = 0.0
	var exk := smoothstep(0.0, 0.85, exertion)
	var tgt := clampf(maxf(exk, stress) + 0.2 * minf(exk, stress), 0.0, 1.0)
	tgt = maxf(tgt, _boost)
	intensity = lerpf(intensity, tgt, 1.0 - exp(-delta / (0.9 if tgt > intensity else 4.0)))


# =================================================================================================
# Breathing
# =================================================================================================

func _update_breath(p, _delta: float) -> void:
	if p.is_dead() or _sets.is_empty():
		return
	if _held:
		# The hold ends without a sound when the sniper is put away / drops out of the scope.
		var it = p.current() if p.has_method("current") else null
		if it == null or it.get("holding_breath") != true:
			sniper_breath("out")
		return
	if _phase == 2:
		_phase = 0
	if _t < _next:
		# A scare cuts a long pause short (the pause only: the exhale still sounding is left alone).
		if _phase == 0:
			var from := maxf(_t, _pause_from)
			var base := _pause_base(intensity)
			if _next - from > base * 1.25 + 0.15:
				_next = from + base * randf_range(0.8, 1.0)
		return
	_breathe(_phase == 0)


func _breathe(inhale: bool) -> void:
	if inhale:
		_cur_set = _pick_set(intensity)
	var key := ("in_" if inhale else "out_") + _cur_set
	var arr: Array = _sets.get(key, [])
	if arr.is_empty():
		_next = _t + 1.0
		return
	var i := randi() % arr.size()
	if arr.size() > 1 and i == int(_last_pick.get(key, -1)):
		i = (i + 1 + randi() % (arr.size() - 1)) % arr.size()
	_last_pick[key] = i
	var s: AudioStream = arr[i]
	var pitch := randf_range(0.97, 1.03) * lerpf(1.0, 1.02, intensity)
	var len := _breath_play(s, _breath_db(), pitch)
	if inhale:
		_lung_to(1.0, len * 0.85)
		_phase = 1
		_next = _t + len * lerpf(0.98, 0.9, intensity) + _catch_len(intensity)
	else:
		_lung_to(0.0, len * 0.95)
		_start_exhale_fog(len, smoothstep(0.3, 1.0, intensity) * 0.3)
		_phase = 0
		_pause_from = _t + len * lerpf(0.95, 0.8, intensity)
		_next = _pause_from + _pause_len(intensity)


## Plays a breath on the next of the two players; returns its length in seconds.
func _breath_play(s: AudioStream, db: float, pitch: float) -> float:
	var len := maxf(s.get_length(), 0.2) / pitch
	if db <= -70.0:
		return len
	var pl: AudioStreamPlayer = _bp[_bp_i]
	_bp_i = (_bp_i + 1) % _bp.size()
	pl.stream = s
	pl.volume_db = db
	pl.pitch_scale = pitch
	pl.play()
	return len


## The breath's level: barely there calm, close and loud spent / panicked.
func _breath_db() -> float:
	var db := lerpf(-27.0, -12.0, pow(intensity, 0.85)) + randf_range(-1.0, 1.0)
	match level():
		1:
			db -= 3.0
		0:
			if intensity < 0.35:
				return -80.0
			db -= 4.0
	return db


func _pick_set(k: float) -> String:
	if k < 0.22:
		return "calm"
	if k < 0.4:
		return "exert" if randf() < (k - 0.22) / 0.18 else "calm"
	if k < 0.7:
		return "exert"
	if k < 0.86:
		return "panic" if randf() < (k - 0.7) / 0.16 else "exert"
	return "panic"


## The catch between breathing in and out.
func _catch_len(k: float) -> float:
	return lerpf(0.22, 0.04, k) * randf_range(0.8, 1.25)


## The pause after breathing out (with jitter), and its mean.
func _pause_len(k: float) -> float:
	return _pause_base(k) * randf_range(0.85, 1.2)


func _pause_base(k: float) -> float:
	return lerpf(2.2, 0.15, pow(clampf(k, 0.0, 1.0), 0.7))


func _lung_to(v: float, dur: float) -> void:
	_lung_a = _lung
	_lung_b = v
	_lung_t = 0.0
	_lung_d = maxf(dur, 0.05)


func _update_lung(delta: float) -> void:
	_lung_t += delta
	var u := clampf(_lung_t / _lung_d, 0.0, 1.0)
	_lung = lerpf(_lung_a, _lung_b, u * u * (3.0 - 2.0 * u))
	# Condensation: an exhale blooms it (fast pulse + slow build-up), calm lets it clear.
	_exhale_t += delta
	if _exhale_t < _exhale_len:
		var r := delta / _exhale_len
		_fog_base = minf(_fog_base + _exhale_fog * r, 1.0)
		_fog_pulse = minf(_fog_pulse + r * smoothstep(0.2, 0.9, intensity) * 1.2, 1.0)
	_fog_base = maxf(_fog_base - _fog_base * delta / 6.0, 0.0)
	_fog_pulse = maxf(_fog_pulse - _fog_pulse * delta / 0.9, 0.0)


func _start_exhale_fog(len: float, amount: float) -> void:
	_exhale_t = 0.0
	_exhale_len = maxf(len * 0.8, 0.1)
	_exhale_fog = amount


# =================================================================================================
# Suit bed: fan, creaks, servos, body thuds
# =================================================================================================

func _update_bed(p, delta: float, lv: int) -> void:
	var fs = _assets.get("fan")
	var want := -80.0
	if fs != null and lv > 0 and not p.is_dead():
		want = lerpf(-29.0, -24.0, intensity) - (4.0 if lv == 1 else 0.0)
		var sfx = Game.sfx
		if sfx != null and is_instance_valid(sfx) and float(sfx.get("listener_air")) < 0.05:
			want += 2.5                     # vacuum: nothing outside, the suit is all you hear
	_fan_db = move_toward(_fan_db, want, delta * (8.0 if want > _fan_db else 20.0))
	if fs != null:
		if _fan.stream != fs:
			_fan.stream = fs
		if _fan_db > -79.0 and not _fan.playing:
			_fan.play(randf() * 6.0)
		elif _fan_db <= -79.0 and _fan.playing:
			_fan.stop()
		_fan.volume_db = _fan_db
		_fan.pitch_scale = 1.0 + 0.05 * intensity
	# The servo sweeps up while it runs.
	if _servo.playing:
		_servo_t += delta
		var u := clampf(_servo_t / _servo_len, 0.0, 1.0)
		_servo.pitch_scale = _servo_pitch * lerpf(0.86, 1.07, u * (2.0 - u))


func _fx_play(s: AudioStream, db: float, pitch: float) -> void:
	if s == null:
		return
	var pl: AudioStreamPlayer = _fx[_fx_i]
	_fx_i = (_fx_i + 1) % _fx.size()
	pl.stream = s
	pl.volume_db = db
	pl.pitch_scale = pitch
	pl.play()


## A sub thud felt through the suit: steps (light) and landings (heavy).
func _body_thud(db: float, pitch: float, landing: bool) -> void:
	var lv := level()
	if lv == 0:
		return
	_fx_play(_assets.get("sub_land" if landing else "sub_step"), db - (3.0 if lv == 1 else 0.0), pitch)


func _creak(db: float) -> void:
	var arr: Array = _assets.get("creak", [])
	if arr.is_empty() or level() == 0 or _creak_cd > 0.0:
		return
	_creak_cd = randf_range(1.8, 3.2)
	_fx_play(arr[randi() % arr.size()], db + randf_range(-2.0, 1.0) - (3.0 if level() == 1 else 0.0), randf_range(0.86, 1.14))


func _servo_whirr(db: float) -> void:
	var arr: Array = _assets.get("servo", [])
	if arr.is_empty() or level() == 0 or _servo_cd > 0.0:
		return
	_servo_cd = randf_range(2.5, 4.0)
	var s: AudioStream = arr[randi() % arr.size()]
	_servo_pitch = randf_range(0.92, 1.1)
	_servo_len = maxf(s.get_length(), 0.1) / _servo_pitch
	_servo_t = 0.0
	_servo.stream = s
	_servo.volume_db = db - (3.0 if level() == 1 else 0.0)
	_servo.pitch_scale = _servo_pitch * 0.86
	_servo.play()


# =================================================================================================
# Breath camera
# =================================================================================================

func _update_camera(p, lv: int) -> void:
	var cam = p.get("camera")
	if not (cam is Camera3D):
		return
	if cam != _cam:
		_cam = cam
		_cam_off = Vector3.ZERO
	var c := cam as Camera3D
	var on: bool = lv > 0 and c.current and p.vehicle == null and not p.is_ragdolled() and not p.is_dead()
	var want := Vector3.ZERO
	var rot := 0.0
	if on:
		var sc := 1.0 if lv == 2 else 0.6
		var b := (_lung - 0.5) * sc
		want = Vector3(0.0, b * lerpf(0.0008, 0.004, intensity), -b * lerpf(0.0002, 0.001, intensity))
		var it = p.current() if p.has_method("current") else null
		var ads := clampf(float(it.get("ads")), 0.0, 1.0) if it != null and it.get("ads") != null else 0.0
		rot = b * lerpf(0.0005, 0.0035, intensity) * (1.0 - 0.85 * ads)
	if want != _cam_off:
		c.position += want - _cam_off
		_cam_off = want
	if rot != 0.0:
		c.rotation.x += rot                 # (the player resets the rotation every frame on foot)


func _remove_cam_offset() -> void:
	if _cam != null and is_instance_valid(_cam) and _cam_off != Vector3.ZERO:
		_cam.position -= _cam_off
	_cam_off = Vector3.ZERO


# =================================================================================================
# Visor
# =================================================================================================

func _build_visor() -> void:
	# The surface (rim, glints, fog): a depth-masked quad in the 3D pass (VISOR_SHADER).
	var vs := Shader.new()
	vs.code = VISOR_SHADER
	_qmat = ShaderMaterial.new()
	_qmat.shader = vs
	_qmat.render_priority = Material.RENDER_PRIORITY_MIN + 1    # right after motion_blur.gd's quad
	var qm := QuadMesh.new()
	qm.size = Vector2(2.0, 2.0)
	_quad = MeshInstance3D.new()
	_quad.name = "HelmetVisorQuad"
	_quad.mesh = qm
	_quad.material_override = _qmat
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_quad.extra_cull_margin = 16384.0
	_quad.ignore_occlusion_culling = true
	_quad.visible = false
	add_child(_quad)
	# Cracks and the flash: a canvas pass (CRACK_SHADER), only while there is one.
	_layer = CanvasLayer.new()
	_layer.layer = 2
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = CRACK_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_rect.material = _mat
	_rect.visible = false
	_layer.add_child(_rect)
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.seed = 7
	fn.frequency = 0.012
	fn.fractal_octaves = 4
	var nt := NoiseTexture2D.new()
	nt.width = 256
	nt.height = 256
	nt.seamless = true
	nt.generate_mipmaps = true
	nt.noise = fn
	_qmat.set_shader_parameter("fog_tex", nt)


## A crack where the helmet took it: near an upper / side edge, never over the crosshair or the view
## model. `heavy`: with the white flash and the full glass crack.
func _add_crack(heavy: bool) -> void:
	_crack_fade = false
	var lv := level()
	var snd = _assets.get("crack")
	if heavy:
		_flash = 1.0
		if snd != null and lv > 0:
			_fx_play(snd, -6.0 - (3.0 if lv == 1 else 0.0), randf_range(0.92, 1.06))
	elif snd != null and lv > 0:
		_fx_play(snd, -15.0, randf_range(1.05, 1.15))
	if _cracks.size() >= MAX_CRACKS:
		_cracks.pop_front()
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.x / maxf(vs.y, 1.0)
	var uv := Vector2(0.5, 0.5)
	for attempt in 8:
		# The upper half and the sides: never down where the arms and the gun are.
		var a := randf_range(-PI - 0.1, 0.1)
		var r := randf_range(0.34, 0.5)                 # screen heights from the centre
		uv = Vector2(0.5 + cos(a) * r / aspect, 0.5 + sin(a) * r)
		uv = uv.clamp(Vector2(0.07, 0.08), Vector2(0.93, 0.92))
		var ok := true
		for c in _cracks:
			if ((c["uv"] as Vector2) - uv).length() < 0.18:
				ok = false
		if ok:
			break
	_cracks.append({"uv": uv, "size": randf_range(0.17, 0.28) * (1.0 if heavy else 0.75), "rot": randf() * TAU, "w": 0.0})


func _update_visor(p, delta: float, lv: int) -> void:
	_flash = maxf(_flash - delta / 0.16, 0.0)
	# Cracks snap in; once healed they fade and go.
	for i in range(_cracks.size() - 1, -1, -1):
		var c: Dictionary = _cracks[i]
		if _crack_fade:
			c["w"] = float(c["w"]) - delta / 2.5
			if float(c["w"]) <= 0.0:
				_cracks.remove_at(i)
		else:
			c["w"] = minf(float(c["w"]) + delta / 0.06, 1.0)
	if _cracks.is_empty():
		_crack_fade = false
	var cam := get_viewport().get_camera_3d()
	var show: bool = lv > 0 and _tex_ready and cam != null and cam == p.get("camera") and not p.is_dead()
	_quad.visible = show
	_rect.visible = show and (not _cracks.is_empty() or _flash > 0.0)
	if not show:
		return
	_quad.global_position = cam.global_position           # (culling only: the shader covers the screen)
	# The sun: ahead of the view and not behind the planet or the rock around us.
	_sun_check -= delta
	if _sun_check <= 0.0:
		_sun_check = 0.2
		_sun_vis_t = _sun_visible(cam)
	_sun_vis = lerpf(_sun_vis, _sun_vis_t, 1.0 - exp(-delta / 0.25))
	var fwd := -cam.global_transform.basis.z
	var sun := smoothstep(0.35, 0.97, fwd.dot(Game.sun_dir)) * _sun_vis
	if sun > 0.001:
		var sp: Vector3 = cam.global_position + Game.sun_dir * 500.0
		if not cam.is_position_behind(sp):
			var vs := get_viewport().get_visible_rect().size
			_sun_uv = cam.unproject_position(sp) / Vector2(maxf(vs.x, 1.0), maxf(vs.y, 1.0))
	var sc := 1.0 if lv == 2 else 0.6
	_qmat.set_shader_parameter("rim", 0.2 if lv == 2 else 0.12)
	_qmat.set_shader_parameter("soft", 0.4 if lv == 2 else 0.25)
	_qmat.set_shader_parameter("sun", sun * sc)
	_qmat.set_shader_parameter("sun_uv", _sun_uv)
	_qmat.set_shader_parameter("fog", clampf(_fog_base + _fog_pulse * 0.45, 0.0, 1.0) * sc)
	_qmat.set_shader_parameter("t", _t)
	if not _rect.visible:
		return
	_mat.set_shader_parameter("sun", sun * sc)
	_mat.set_shader_parameter("sun_uv", _sun_uv)
	_mat.set_shader_parameter("flash", _flash * _flash * (0.5 if lv == 2 else 0.3))
	var keys := ["crack_a", "crack_b", "crack_c"]
	var w := Vector3.ZERO
	for i in 3:
		var v := Vector4.ZERO
		if i < _cracks.size():
			var c: Dictionary = _cracks[i]
			var uv: Vector2 = c["uv"]
			v = Vector4(uv.x, uv.y, float(c["size"]), float(c["rot"]))
			w[i] = clampf(float(c["w"]), 0.0, 1.0)
		_mat.set_shader_parameter(keys[i], v)
	_mat.set_shader_parameter("crack_w", w)


func _sun_visible(cam: Camera3D) -> float:
	var pos := cam.global_position
	var s: Vector3 = Game.sun_dir
	var b = Game.dominant_body(pos)
	if b != null and b.get("radius") != null:
		var oc: Vector3 = pos - (b as Node3D).global_position
		var r := float(b.radius) * 0.96
		var bb := oc.dot(s)
		var cc := oc.length_squared() - r * r
		if cc < 0.0 or (bb < 0.0 and bb * bb - cc > 0.0):
			return 0.0                      # deep underground, or the planet is in the way (night side)
	var w := cam.get_world_3d()
	if w == null:
		return 1.0
	var q := PhysicsRayQueryParameters3D.create(pos, pos + s * 120.0, Game.LAYER_TERRAIN | Game.LAYER_SHIP)
	return 0.0 if not w.direct_space_state.intersect_ray(q).is_empty() else 1.0


# =================================================================================================
# Buses
# =================================================================================================

## The dry "Helmet" bus (breathing, suit) → Master.
func _ensure_bus() -> void:
	if AudioServer.get_bus_index(BUS) >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, BUS)
	AudioServer.set_bus_send(i, "Master")
	AudioServer.set_bus_volume_db(i, 0.0)


## The helmet colouring on the world buses at setting level `lv` (0 = bypassed). `remove`: take the
## effects off entirely (leaving the tree).
func _drive_helmet_buses(lv: int, remove: bool) -> void:
	for bn: String in HELM_BUSES:
		var bi := AudioServer.get_bus_index(bn)
		if bi <= 0:
			continue
		var ib := _fx_find(bi, FX_BODY)
		var ia := _fx_find(bi, FX_AIR)
		var ie := _fx_find(bi, FX_ER)
		var complete := ib >= 0 and ia >= 0 and ie >= 0 and ia == ib + 1 and ie == ia + 1 \
				and ie < _insert_at(bi, true)
		if remove or not complete:
			for n: String in [FX_ER, FX_AIR, FX_BODY]:
				var e := _fx_find(bi, n)
				while e >= 0:
					AudioServer.remove_bus_effect(bi, e)
					e = _fx_find(bi, n)
			if remove:
				continue
			if lv == 0:
				continue                    # added when first switched on
			var at := _insert_at(bi, false)
			var body := AudioEffectLowShelfFilter.new()
			body.resource_name = FX_BODY
			var air := AudioEffectHighShelfFilter.new()
			air.resource_name = FX_AIR
			var er := AudioEffectDelay.new()
			er.resource_name = FX_ER
			AudioServer.add_bus_effect(bi, body, at)
			AudioServer.add_bus_effect(bi, air, at + 1)
			AudioServer.add_bus_effect(bi, er, at + 2)
			ib = at
			ia = at + 1
			ie = at + 2
		_set_helmet_fx(bi, ib, ia, ie, lv)


func _set_helmet_fx(bi: int, ib: int, ia: int, ie: int, lv: int) -> void:
	var med := lv == 2
	var body := AudioServer.get_bus_effect(bi, ib) as AudioEffectLowShelfFilter
	if body != null:
		body.cutoff_hz = 250.0
		body.resonance = 0.5
		body.db = AudioEffectFilter.FILTER_6DB
		body.gain = pow(10.0, (2.0 if med else 1.0) / 40.0)     # RBJ shelf amplitude: gain² is the shelf
	var air := AudioServer.get_bus_effect(bi, ia) as AudioEffectHighShelfFilter
	if air != null:
		air.cutoff_hz = 6500.0
		air.resonance = 0.5
		air.db = AudioEffectFilter.FILTER_6DB
		air.gain = pow(10.0, (-3.0 if med else -1.5) / 40.0)
	var er := AudioServer.get_bus_effect(bi, ie) as AudioEffectDelay
	if er != null:
		er.dry = 1.0
		er.feedback_active = false
		er.tap1_active = true
		er.tap1_delay_ms = 2.8
		er.tap1_level_db = -18.0 if med else -24.0
		er.tap1_pan = -0.35
		er.tap2_active = true
		er.tap2_delay_ms = 4.5
		er.tap2_level_db = -21.0 if med else -27.0
		er.tap2_pan = 0.35
	for e in [ib, ia, ie]:
		if AudioServer.is_bus_effect_enabled(bi, e) != (lv > 0):
			AudioServer.set_bus_effect_enabled(bi, e, lv > 0)


## Where the helmet colouring goes on bus `bi`: before the muffle / duck / vacuum low-pass and any
## limiter, else at the end. `skip_own`: ignore our own effects while looking (validation).
func _insert_at(bi: int, skip_own := false) -> int:
	var n := AudioServer.get_bus_effect_count(bi)
	for e in n:
		var fx := AudioServer.get_bus_effect(bi, e)
		if fx == null:
			continue
		if skip_own and fx.resource_name in [FX_BODY, FX_AIR, FX_ER]:
			continue
		if fx.resource_name in FX_BEFORE or fx is AudioEffectHardLimiter or fx is AudioEffectLimiter:
			return maxi(e, 1)
	return n


func _fx_find(bi: int, fx_name: String) -> int:
	for e in AudioServer.get_bus_effect_count(bi):
		var x := AudioServer.get_bus_effect(bi, e)
		if x != null and x.resource_name == fx_name:
			return e
	return -1


# =================================================================================================
# Assets (worker thread, cached for the session)
# =================================================================================================

func _start_assets() -> void:
	if _assets.has("ready"):
		_take_local()
		return
	if _task < 0:
		_task = WorkerThreadPool.add_task(_build_assets, false, "helmet_fx_assets")


func _poll_assets() -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_take_assets()
	if _sets.is_empty() and _assets.has("ready"):
		_take_local()


static func _take_assets() -> void:
	_mutex.lock()
	if not _out.is_empty():
		var o := _out
		_out = {}
		# Textures are made here, on the main thread.
		if o.get("crack_img") is Image:
			o["crack_tex"] = ImageTexture.create_from_image(o["crack_img"])
		if o.get("grime_img") is Image:
			o["grime_tex"] = ImageTexture.create_from_image(o["grime_img"])
		o.erase("crack_img")
		o.erase("grime_img")
		o["ready"] = true
		_assets = o
	_mutex.unlock()


func _take_local() -> void:
	for d: String in ["in", "out"]:
		for s: String in SETS:
			_sets["%s_%s" % [d, s]] = _assets.get("%s_%s" % [d, s], [])
	if _assets.get("crack_tex") != null and _assets.get("grime_tex") != null:
		_mat.set_shader_parameter("crack_tex", _assets["crack_tex"])
		_qmat.set_shader_parameter("grime_tex", _assets["grime_tex"])
		_tex_ready = true


static func _build_assets() -> void:
	var o := {}
	var any := false
	for d: String in ["in", "out"]:
		for s: String in SETS:
			var arr: Array = []
			for i in range(1, 9):
				var st := _load_snd("breath_%s_%s_%02d" % [d, s, i])
				if st == null:
					break
				arr.append(st)
			any = any or not arr.is_empty()
			o["%s_%s" % [d, s]] = arr
	if not any:
		# No recordings (not imported / missing): the old synthesized helmet breath for every set.
		var gen := WeaponAudio.new()
		var bi: AudioStream = gen.make("breath_in")
		var bo: AudioStream = gen.make("breath_out")
		for s: String in SETS:
			o["in_" + s] = [bi]
			o["out_" + s] = [bo]
	o["hold"] = _load_set("breath_hold")
	o["release"] = _load_set("breath_release")
	o["servo"] = _load_set("suit_servo")
	var fan := _load_snd("suit_fan")
	if fan is AudioStreamWAV:
		var w := (fan as AudioStreamWAV).duplicate() as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(round(w.get_length() * float(w.mix_rate)))
		fan = w
	o["fan"] = fan
	o["sub_step"] = _wav(_sub(0.2, 46.0, 74.0, 40.0, 26.0, 0.12), 0.9)
	o["sub_land"] = _wav(_sub(0.42, 38.0, 80.0, 22.0, 11.0, 0.18), 0.9)
	var creaks: Array = []
	for i in 4:
		creaks.append(_wav(_creak_buf(9100 + i * 17, [0.22, 0.3, 0.38, 0.46][i]), 0.8))
	o["creak"] = creaks
	o["crack"] = _wav(_crack_buf(4242), 0.85)
	o["comms"] = _wav(_comms_buf(), 0.8)
	o["crack_img"] = _crack_img(4242)
	o["grime_img"] = _grime_img(77)
	_mutex.lock()
	_out = o
	_mutex.unlock()


## One sound of assets/audio/helmet: the imported resource, or (not imported yet: a fresh checkout
## run without the editor) the WAV read directly. null when missing.
static func _load_snd(n: String) -> AudioStream:
	var path := DIR + n + ".wav"
	if ResourceLoader.exists(path):
		var s := load(path) as AudioStream
		if s != null:
			return s
	if FileAccess.file_exists(path):
		return AudioStreamWAV.load_from_file(path)
	return null


static func _load_set(prefix: String) -> Array:
	var out: Array = []
	for i in range(1, 9):
		var s := _load_snd("%s_%02d" % [prefix, i])
		if s == null:
			break
		out.append(s)
	return out


# --- Synthesis ------------------------------------------------------------------------------------

static func _wav(buf: PackedFloat32Array, peak: float) -> AudioStreamWAV:
	var pk := 0.0001
	for v in buf:
		pk = maxf(pk, absf(v))
	var k := peak / pk
	var data := PackedByteArray()
	data.resize(buf.size() * 2)
	for i in buf.size():
		data.encode_s16(i * 2, int(clampf(buf[i] * k, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


## Body-conducted sub thud: a sine falling from f1 to f0 (rate kf), a 3 ms attack, decay ke, a touch
## of 2nd harmonic so it still reads on small speakers, softly saturated.
static func _sub(dur: float, f0: float, f1: float, kf: float, ke: float, harm: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var b := PackedFloat32Array()
	b.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		ph += TAU * (f0 + (f1 - f0) * exp(-t * kf)) / RATE
		var env := (1.0 - exp(-t / 0.003)) * exp(-t * ke)
		var fade := clampf(float(n - i) / (0.012 * RATE), 0.0, 1.0)
		b[i] = tanh((sin(ph) + harm * sin(2.0 * ph)) * env * 1.4) * fade
	return b


## Suit creak: stick-slip, an impulse train whose rate wanders (30-80 Hz) exciting three resonances
## of the shell / joint, under a swelling envelope, a little grit, muffled (heard through the suit).
static func _creak_buf(sd: int, dur: float) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = sd
	var n := int(dur * RATE)
	var b := PackedFloat32Array()
	b.resize(n)
	var f1 := rng.randf_range(480.0, 760.0)
	var fr := [f1, f1 * rng.randf_range(2.05, 2.6), f1 * rng.randf_range(3.6, 4.4)]
	var rr := [0.9962, 0.995, 0.9935]
	var gg := [1.0, 0.5, 0.22]
	var cw := [cos(TAU * fr[0] / RATE), cos(TAU * fr[1] / RATE), cos(TAU * fr[2] / RATE)]
	var y1 := [0.0, 0.0, 0.0]
	var y2 := [0.0, 0.0, 0.0]
	var base := rng.randf_range(32.0, 58.0)
	var wob_f := rng.randf_range(1.2, 2.8)
	var wob_ph := rng.randf() * TAU
	var shape := rng.randf_range(0.6, 1.5)
	var next_imp := 0.0
	var lp := 0.0
	var dc := 0.0
	for i in n:
		var t := float(i) / RATE
		var u := pow(t / dur, shape)
		var env := pow(sin(PI * clampf(u, 0.0, 1.0)), 0.8)
		var x := (rng.randf() * 2.0 - 1.0) * 0.012 * env
		if t >= next_imp:
			var rate := base * (1.0 + 0.4 * sin(TAU * wob_f * t + wob_ph))
			next_imp = t + rng.randf_range(0.85, 1.15) / rate
			x += env * rng.randf_range(0.6, 1.0)
		var o := 0.0
		for r in 3:
			var r0: float = rr[r]
			var yn: float = 2.0 * r0 * float(cw[r]) * float(y1[r]) - r0 * r0 * float(y2[r]) + x * (1.0 - r0) * 8.0
			y2[r] = y1[r]
			y1[r] = yn
			o += yn * float(gg[r])
		lp += 0.35 * (o - lp)               # ~3 kHz: through the suit
		dc += 0.002 * (lp - dc)
		b[i] = lp - dc
	return b


## Visor crack: a sharp break (glass resonances 2.3-8.1 kHz rung by clicks), the crack running on in
## smaller ticks, a short brittle hiss and the helmet shell's low knock.
static func _crack_buf(sd: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = sd
	var n := int(0.5 * RATE)
	var b := PackedFloat32Array()
	b.resize(n)
	var ev: Array = [[0, 1.0]]
	var te := 0.0
	for k in 8:
		te += rng.randf_range(0.006, 0.026) * (1.0 + float(k) * 0.4)
		ev.append([int(te * RATE), 0.55 * pow(0.78, float(k)) * rng.randf_range(0.7, 1.2)])
	var fr := [2350.0, 3720.0, 5900.0, 8150.0]
	var rr := [0.9988, 0.9984, 0.9978, 0.997]
	var gg := [1.0, 0.8, 0.6, 0.4]
	var cw: Array = []
	for f in fr:
		cw.append(cos(TAU * float(f) * rng.randf_range(0.96, 1.04) / RATE))
	var y1 := [0.0, 0.0, 0.0, 0.0]
	var y2 := [0.0, 0.0, 0.0, 0.0]
	var ei := 0
	var hp_prev := 0.0
	for i in n:
		var t := float(i) / RATE
		var x := 0.0
		while ei < ev.size() and int(ev[ei][0]) <= i:
			x += float(ev[ei][1])
			ei += 1
		var o := 0.0
		for r in 4:
			var r0: float = rr[r]
			var yn: float = 2.0 * r0 * float(cw[r]) * float(y1[r]) - r0 * r0 * float(y2[r]) + x * (1.0 - r0) * 30.0
			y2[r] = y1[r]
			y1[r] = yn
			o += yn * float(gg[r])
		var nz := rng.randf() * 2.0 - 1.0
		var hiss := (nz - hp_prev) * 0.5
		hp_prev = nz
		o += hiss * 0.3 * exp(-t * 30.0)
		o += sin(TAU * 170.0 * t) * 0.55 * exp(-t * 45.0) * minf(t * 2000.0, 1.0)
		b[i] = o * clampf(float(n - i) / (0.02 * RATE), 0.0, 1.0)
	return b


## Comms click: the key-up "tk" (two resonances), a short band-limited squelch, the release tick.
static func _comms_buf() -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 515
	var n := int(0.16 * RATE)
	var b := PackedFloat32Array()
	b.resize(n)
	var cw := [cos(TAU * 1900.0 / RATE), cos(TAU * 3300.0 / RATE)]
	var rr := [0.992, 0.99]
	var y1 := [0.0, 0.0]
	var y2 := [0.0, 0.0]
	var hp := 0.0
	var lp := 0.0
	var rel := int(0.085 * RATE)
	for i in n:
		var t := float(i) / RATE
		var x := 0.0
		if i == 0:
			x = 1.0
		elif i == rel:
			x = 0.45
		var o := 0.0
		for r in 2:
			var r0: float = rr[r]
			var yn: float = 2.0 * r0 * float(cw[r]) * float(y1[r]) - r0 * r0 * float(y2[r]) + x * (1.0 - r0) * 12.0
			y2[r] = y1[r]
			y1[r] = yn
			o += yn
		var nz := rng.randf() * 2.0 - 1.0
		lp += 0.42 * (nz - lp)              # ~3.4 kHz
		hp += 0.12 * (lp - hp)              # ~900 Hz
		if t > 0.004 and t < 0.09:
			o += (lp - hp) * 0.32 * exp(-(t - 0.004) * 38.0)
		b[i] = o * clampf(float(n - i) / (0.01 * RATE), 0.0, 1.0)
	return b


# --- Textures -------------------------------------------------------------------------------------

## Cracked visor glass, the bots' visor-crack style (rifle_fx.gd _make_crack_tex) at screen size: an
## impact star of jagged radial cracks (some branching), broken concentric rings, a pulverized
## centre. White, alpha = crack.
static func _crack_img(sd: int) -> Image:
	var n := 512
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = sd
	var c := Vector2(n, n) * 0.5
	var count := rng.randi_range(10, 13)
	for k in count:
		var ang := TAU * float(k) / float(count) + rng.randf_range(-0.25, 0.25)
		var p := c
		var length := rng.randf_range(0.26, 0.47) * n
		var steps := 16
		for s in steps:
			var q := p + Vector2(cos(ang), sin(ang)) * length / steps
			var a0 := 1.0 - float(s) / steps * 0.65
			_line(img, p, q, a0, a0 - 0.04, 0)
			if s < 6:
				var nrm := Vector2(-sin(ang), cos(ang)) * 0.6
				_line(img, p + nrm, q + nrm, a0 * 0.7, a0 * 0.7, 0)
			if s > 4 and s < 11 and rng.randf() < 0.07:
				# A branch splits off.
				var ba := ang + rng.randf_range(0.5, 0.9) * (1.0 if rng.randf() < 0.5 else -1.0)
				var bp := q
				var bl := length * rng.randf_range(0.12, 0.25)
				for bs in 6:
					var bq := bp + Vector2(cos(ba), sin(ba)) * bl / 6.0
					_line(img, bp, bq, a0 * 0.6 * (1.0 - bs / 7.0), a0 * 0.6 * (1.0 - (bs + 1) / 7.0), 0)
					bp = bq
					ba += rng.randf_range(-0.3, 0.3)
			p = q
			ang += rng.randf_range(-0.35, 0.35)
	for rad: float in [0.07, 0.15, 0.25]:
		var segs := 30
		var prev := Vector2.ZERO
		for s in segs + 1:
			var a := TAU * float(s) / segs
			var rr := rad * n * rng.randf_range(0.93, 1.07)
			var pt := c + Vector2(cos(a), sin(a)) * rr
			if s > 0 and rng.randf() > 0.35:
				_line(img, prev, pt, 0.72, 0.72, 0)
			prev = pt
	for y in range(int(c.y) - 9, int(c.y) + 10):
		for x in range(int(c.x) - 9, int(c.x) + 10):
			var d := Vector2(x, y).distance_to(c)
			if d < 8.0:
				var old := img.get_pixel(x, y)
				img.set_pixel(x, y, Color(1, 1, 1, maxf(old.a, clampf(1.0 - d / 8.0, 0.0, 1.0) * 0.9)))
	for k in 40:
		var fp := c + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(6.0, 18.0)
		_splat(img, fp.x, fp.y, rng.randf_range(0.4, 0.9), 0)
	img.generate_mipmaps()
	return img


## Visor wear at 16:9: short, sparse scratches (r) in a couple of wiping directions plus a few very
## faint wipe arcs, and dust (g): fine specks and a few soft smudges. (Long, dense, strong scratches
## read as rain over the sky whenever the sun was ahead.)
static func _grime_img(sd: int) -> Image:
	var w := 1024
	var h := 576
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = sd
	var d1 := rng.randf() * PI
	var d2 := d1 + rng.randf_range(0.6, 1.2)
	for k in 46:
		var p := Vector2(rng.randf() * w, rng.randf() * h)
		var r := rng.randf()
		var ang := (d1 if r < 0.4 else (d2 if r < 0.7 else rng.randf() * PI)) + rng.randf_range(-0.25, 0.25)
		var length := rng.randf_range(3.0, 13.0) * (1.0 + 1.2 * pow(rng.randf(), 4.0))
		var a := rng.randf_range(0.12, 0.45)
		for s in 3:
			var q := p + Vector2(cos(ang), sin(ang)) * length / 3.0
			_line(img, p, q, a, a * 0.85, 0)
			p = q
			ang += rng.randf_range(-0.08, 0.08)
	for k in 3:
		var cc := Vector2(rng.randf_range(-200.0, w + 200.0), rng.randf_range(-200.0, h + 200.0))
		var rad := rng.randf_range(220.0, 700.0)
		var a0 := rng.randf() * TAU
		var span := rng.randf_range(0.08, 0.22)
		var a := rng.randf_range(0.04, 0.1)
		var steps := int(rad * span / 3.0) + 2
		var prev := cc + Vector2(cos(a0), sin(a0)) * rad
		for s in range(1, steps + 1):
			var an := a0 + span * float(s) / steps
			var pt := cc + Vector2(cos(an), sin(an)) * rad
			var fade := sin(PI * float(s) / steps)
			_line(img, prev, pt, a * fade, a * fade, 0)
			prev = pt
	for k in 900:
		var p := Vector2(rng.randf() * w, rng.randf() * h)
		var r := 0.4 + 1.2 * pow(rng.randf(), 2.0)
		_disc(img, p, r, rng.randf_range(0.25, 0.85), 1)
	for k in 40:
		var p := Vector2(rng.randf() * w, rng.randf() * h)
		_disc(img, p, rng.randf_range(5.0, 14.0), rng.randf_range(0.05, 0.14), 1)
	img.generate_mipmaps()
	return img


## An anti-aliased line from a to b on channel ch (0 r / alpha for the crack image, 1 g).
static func _line(img: Image, a: Vector2, b: Vector2, alpha_a: float, alpha_b: float, ch: int) -> void:
	var steps := int(ceilf(a.distance_to(b) * 2.0)) + 1
	for i in steps + 1:
		var u := float(i) / float(steps)
		var p := a.lerp(b, u)
		_splat(img, p.x, p.y, lerpf(alpha_a, alpha_b, u), ch)


## A bilinear dot of strength `a` at (x, y): the crack image keeps white and raises alpha; the
## grime image raises channel ch.
static func _splat(img: Image, x: float, y: float, a: float, ch: int) -> void:
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var crack := img.get_width() == img.get_height()
	for oy in 2:
		for ox in 2:
			var px := x0 + ox
			var py := y0 + oy
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			var wgt := (fx if ox == 1 else 1.0 - fx) * (fy if oy == 1 else 1.0 - fy)
			var v := clampf(a * minf(wgt * 1.6, 1.0), 0.0, 1.0)
			var c := img.get_pixel(px, py)
			if crack:
				img.set_pixel(px, py, Color(1, 1, 1, maxf(c.a, v)))
			elif ch == 0:
				img.set_pixel(px, py, Color(maxf(c.r, v), c.g, 0, 1))
			else:
				img.set_pixel(px, py, Color(c.r, maxf(c.g, v), 0, 1))


## A soft disc of radius r on channel ch (grime: dust).
static func _disc(img: Image, p: Vector2, r: float, a: float, ch: int) -> void:
	var rr := ceili(r + 1.0)
	for y in range(int(p.y) - rr, int(p.y) + rr + 1):
		for x in range(int(p.x) - rr, int(p.x) + rr + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var d := Vector2(x + 0.5, y + 0.5).distance_to(p)
			var v := a * clampf(1.0 - (d - r * 0.5) / maxf(r * 0.5 + 0.7, 0.01), 0.0, 1.0)
			if v <= 0.0:
				continue
			var c := img.get_pixel(x, y)
			if ch == 0:
				img.set_pixel(x, y, Color(maxf(c.r, v), c.g, 0, 1))
			else:
				img.set_pixel(x, y, Color(c.r, maxf(c.g, v), 0, 1))
