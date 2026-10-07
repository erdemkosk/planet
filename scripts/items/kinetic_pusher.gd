extends "res://scripts/items/weapon_base.gd"
## Kinetik İtici (key 6): a gravity / shock "pusher" in the white / orange / dark kit with cyan
## energy parts. Model: a white capacitor housing with charge cells on top (one lit per charge, the
## refilling one pulses), a rear heat sink, a cage of white rails around a stack of copper coils with
## glowing inner rings (brighter the fuller the capacitor, flickering when starved), a dark field
## emitter dish at the front with a glowing face, rim and spike, three claws around it, a vertical
## front grip (left hand).
## No bullets: a capacitor of Balance.PUSH_CHARGES charges refills one every PUSH_RECHARGE s (also
## holstered, with a chime), and every blast costs PUSH_COST m³ of material (Game.spend_material);
## short of either: a dry click, an error and a message. R does not reload (only a hint).
## LMB: a PUSH_WINDUP wind-up (rising capacitor whine, coils flare, the claws pinch in, the gun
## trembles and pulls back), then the blast: a cone of PUSH_CONE_DEG half angle out to PUSH_RANGE.
##   Look: a refracting shock cone and two pressure rings racing out, cyan sparks off the dish, a
##   pale air burst, dust scoured off the ground inside the cone, a lamp flash, the muzzle star;
##   the coil stack slams back and the claws flare. Sound: a heavy "whump", a body thump, an electric
##   crackle and an air whoosh (in vacuum only the suit-borne thump). Strong arm recoil, camera kick
##   and FOV punch; the shooter is shoved back (PUSH_RECOIL m/s).
##   Effect (apply_push): every character of the other side in the cone and in sight (physics ray
##   on terrain + the planet's density field) takes PUSH_DAMAGE and is shoved at
##   lerp(PUSH_SPEED_MAX, PUSH_SPEED_MIN, dist / range) along the shove direction tipped up by
##   PUSH_UP_BIAS of its own up: rival bots through fling() (scripts/war/ai_rival.gd: stagger, a
##   flight that lands hard, or off into space), others with ragdoll(impulse, s). Ragdoll limbs
##   (corpses) and loose rigid bodies get an impulse (mass capped, PUSH_BODY_K); enemy projectiles in
##   flight (groups "war_shell", "war_torpedo", "war_rocket": vel / team / is_live()) are deflected
##   by PUSH_SHELL_K of the push.
##   Speeds fall off as min + (max - min) × (1 - d / range)^PUSH_FALLOFF: bots closer than ~2.5 m are
##   launched into space, ~2.5-11.5 m thrown in big arcs, farther staggered. Players get PUSH_PLAYER_K
##   of it as a ragdoll fling; grenades (group "grenade_sim", projectiles.gd shove) PUSH_GRENADE_K.
##   Ground tearing (tear_points: a fan of density raycasts through the cone plus probes down along
##   its axis, nearest first, PUSH_TEAR_STAMPS at most): host / single player only, a scoop of DIG
##   brushes along the cone's footprint (Dig.dig_at → planet.apply_brush, synced to clients), two
##   per physics frame (Tearer), marked with the shooter's team for torpedo.gd (own torpedoes are
##   not hurt). Every machine shows the torn mass: pooled flying rock / soil chunks (Chunks, at most
##   PUSH_CHUNKS, DebrisMesh rocks tinted by the ground) arcing under Game.gravity_at, bouncing,
##   settling and sinking; dirt sprays, a dust ring and a refracting shock ring on the ground, a
##   deep crunch; surface rocks freed by the carve are thrown along the blast (planet.add_push_zone
##   → flora_debris launch_flora); players near the impact get camera shake.
## RMB: focus (no zoom): the emitter comes to the centre, the cone narrows to PUSH_FOCUS_CONE and
## reaches PUSH_FOCUS_RANGE farther (the falloff stretches with it).
## HUD: the hotbar / panel show "charges / capacity" (round_cost 0: the panel's "after the reserve"
## price line would be wrong here, every blast costs material); the overlay draws the real cone
## ring, the charge pips with the refill, the per-blast cost and "ŞARJ OLUYOR" / "MALZEME YOK".
## Multiplayer: pusher_fired(from, dir, cfg) fires for every blast (cfg: range, cone (deg),
## speed_max, speed_min, up_bias, damage, body_k, shell_k). Replay it with
## KineticPusher.replay(parent, from, dir, cfg, team, shooter). Host-authoritative: on a client the
## blast is the look only (and local ragdoll limbs); the host's replay damages, flings and deflects.
## The capacitor charges (mag) are local state of the shooter.

signal pusher_fired(from: Vector3, dir: Vector3, cfg: Dictionary)

const WEIGHT := 0.93                      # mobility factor while held (item.gd carry_weight; loadout)
const Balance := preload("res://scripts/war/balance.gd")
const Rockets := preload("res://scripts/items/rockets.gd")
const Dig := preload("res://scripts/player/dig.gd")
const HudLvl := preload("res://scripts/ui/hud_level.gd")   # toasts: "pusher" (0), "no_mat" (1); not HudLevel (weapon_base / PusherHud names)
const Torpedo := preload("res://scripts/war/torpedo.gd")
const DebrisMesh := preload("res://scripts/space/debris_mesh.gd")

const BY := 0.062                         # emitter axis above the grip
const DISH_Z := -0.43
const COIL_Z := [-0.13, -0.19, -0.25, -0.31]
const ENERGY := Color(0.45, 0.85, 1.0)
const SHOCK_LIFE := 0.42

## Refracting shock surface (world space): bends what is behind it, brightest toward the wide end of
## the cone (band_on 1) or evenly (rings, band_on 0), rippling, fading with `fade`.
const SHOCK_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform vec4 tint : source_color = vec4(0.55, 0.88, 1.0, 1.0);
uniform float fade = 1.0;
uniform float strength = 0.035;
uniform float glow = 0.35;
uniform float band_on = 1.0;

varying float along;

void vertex() {
	along = clamp(VERTEX.y + 0.5, 0.0, 1.0);
}

void fragment() {
	float rim = 1.0 - abs(dot(NORMAL, VIEW));
	float front = mix(1.0, smoothstep(0.3, 1.0, along), band_on);
	float ripple = 0.5 + 0.5 * sin(along * 38.0 - TIME * 42.0);
	float w = fade * front * (0.3 + 0.7 * rim);
	vec2 off = NORMAL.xy * strength * w * (0.6 + 0.4 * ripple);
	vec3 bg = textureLod(screen_tex, SCREEN_UV + off, 0.0).rgb;
	ALBEDO = bg + tint.rgb * glow * w * (0.4 + 0.6 * rim);
	ALPHA = clamp(w * 1.6, 0.0, 1.0);
}
"""

## The shock wave of one blast (cone + two rings + a travelling light); frees itself.
class Shock extends Node3D:
	const LIFE := 0.42
	var reach := 9.0
	var cone := 0.49                       # half angle (rad)
	var shader: Shader
	var t := 0.0
	var _pivot: Node3D
	var _cone_mat: ShaderMaterial
	var _rings: Array = []
	var _ring_mats: Array = []
	var _light: OmniLight3D

	func _ready() -> void:
		_pivot = Node3D.new()
		add_child(_pivot)
		var cm := CylinderMesh.new()
		cm.top_radius = 1.0
		cm.bottom_radius = 0.06
		cm.height = 1.0
		cm.radial_segments = 32
		cm.rings = 4
		cm.cap_top = false
		cm.cap_bottom = false
		_cone_mat = _mat(1.0, 0.035, 0.35)
		var mi := MeshInstance3D.new()
		mi.mesh = cm
		mi.material_override = _cone_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0, 0.5, 0)
		_pivot.add_child(mi)
		for k in 2:
			var tm := TorusMesh.new()
			tm.inner_radius = 0.86
			tm.outer_radius = 1.0
			tm.rings = 40
			tm.ring_segments = 8
			var m := _mat(0.0, 0.05, 0.6)
			_ring_mats.append(m)
			var ri := MeshInstance3D.new()
			ri.mesh = tm
			ri.material_override = m
			ri.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(ri)
			_rings.append(ri)
		_light = OmniLight3D.new()
		_light.light_color = Color(0.5, 0.85, 1.0)
		_light.omni_range = 12.0
		_light.light_energy = 9.0
		_light.shadow_enabled = false
		add_child(_light)
		_update()

	func _mat(band: float, strength: float, glow: float) -> ShaderMaterial:
		var m := ShaderMaterial.new()
		m.shader = shader
		m.set_shader_parameter("band_on", band)
		m.set_shader_parameter("strength", strength)
		m.set_shader_parameter("glow", glow)
		return m

	func _process(delta: float) -> void:
		t += delta
		if t >= LIFE:
			queue_free()
			return
		_update()

	func _update() -> void:
		var u := clampf(t / 0.17, 0.0, 1.0)
		var front := 1.0 - (1.0 - u) * (1.0 - u) * (1.0 - u)
		var length := maxf(front * reach, 0.25)
		var tc := tan(cone)
		_pivot.scale = Vector3(tc * length, length, tc * length)
		var fade := clampf(1.0 - (t - 0.06) / 0.34, 0.0, 1.0)
		fade *= fade
		_cone_mat.set_shader_parameter("fade", fade)
		for k in _rings.size():
			var d := length * (1.0 - 0.38 * k)
			(_rings[k] as Node3D).position = Vector3(0, d, 0)
			(_rings[k] as Node3D).scale = Vector3.ONE * maxf(tc * d, 0.1)
			(_ring_mats[k] as ShaderMaterial).set_shader_parameter("fade", fade * (1.0 - 0.45 * k))
		_light.position = Vector3(0, length * 0.5, 0)
		_light.light_energy = 9.0 * clampf(1.0 - t / 0.16, 0.0, 1.0)


var pushed := 0                           # characters shoved by the last blast
var deflected := 0                        # projectiles deflected by the last blast
var _wind_t := -1.0                       # wind-up time (-1: idle)
var _charge_t := 0.0                      # refill progress of the next charge (s)
var _blast_t := 9.0
var _ready_flash := 0.0
var _hint_t := 0.0
var _fx_root: Node3D
var _coils: Node3D
var _prongs: Array = []
var _prong_xf: Array = []
var _coil_mat: ShaderMaterial
var _dish_mat: ShaderMaterial
var _tip_mat: ShaderMaterial
var _rim_mat: ShaderMaterial
var _cell_mats: Array = []
static var _shock_sh: Shader


func _init() -> void:
	item_id = "pusher"
	item_name = "Kinetik İtici"
	# (Free shots since the territory economy: PUSH_COST 0 -> no cost text.)
	var cost_s := (" (%s m³/atış)" % String.num(Balance.PUSH_COST, 1)) if Balance.PUSH_COST > 0.0 else ""
	item_desc = "Sol tık: şok dalgası%s · Sağ tık: odak (dar koni, uzun menzil) · kapasitör kendiliğinden dolar." % cost_s
	icon = "pusher"
	slot_key = 0                          # the loadout (keys 1 / 2) carries it
	accent = ENERGY
	ammo_id = ""
	ammo_title = "KAPASİTÖR"
	base_mag = Balance.PUSH_CHARGES
	fire_rate = 1.6
	aim_speed = 0.8
	short_name = "İtici"
	head_mult = 0.0
	sight_rear = Vector3(0.0, 0.1, 0.05)
	ads_eye = Vector3(0.0, -0.075, -0.3)       # focus: the emitter centred below the crosshair (dish clear of it)
	hip_pos = Vector3(0.165, -0.215, -0.37)
	hip_bore_y = BY
	hip_converge = 8.0
	sprint_pos = Vector3(0.15, -0.17, -0.38)
	sprint_rot = Vector3(-0.25, 0.6, 0.3)
	recoil_pivot = Vector3(0.0, 0.05, 0.16)
	spread_hip = 0.0
	spread_ads = 0.0
	bloom_add = 0.0
	bloom_max = 0.0
	kick_pitch = 0.15
	kick_yaw = 0.03
	kick_roll = 0.05
	gun_kick = 19.0
	shake_amt = 0.85
	fov_punch_amt = -9.0
	recoil_climb = 0.0
	recoil_h = PackedFloat32Array([0.0, 0.5, -0.4])
	recoil_hold = 0.08
	recoil_recover = 0.8
	noise_radius = 40.0
	crosshair_style = "pusher"
	hit_big = 0.7
	muzzle_energy = 22.0
	punch_db = 0.0
	tail_db = -9.0                     # open air: the rolling outdoor tail (weapon_base _shot_body)
	draw_time = 0.7
	holster_time = 0.45


func _ready() -> void:
	super._ready()
	_fx_root = Node3D.new()
	_fx_root.name = "PusherFx"
	add_child(_fx_root)
	_fx_root.top_level = true
	_fx_root.global_transform = Transform3D.IDENTITY
	_snd["whoosh"] = Snd.set_of("whoosh/whoosh")
	# Weapon-feel pass: a real blast under the synthesized shock (Bluezone tank cannon, pitched up tight).
	_snd["cannon"] = Snd.set_of("weap/cannon")
	# Own overlay: cone ring, charge pips, cost, "ŞARJ OLUYOR" / "MALZEME YOK".
	if hud != null:
		hud.queue_free()
	hud = PusherHud.new()
	hud.weapon = self
	add_child(hud)


# =================================================================================================
# HUD queries
# =================================================================================================

func status_text() -> String:
	return "%d/%d" % [mag, Balance.PUSH_CHARGES]


## Panel "mag / reserve": charges / capacity.
func reserve_stock() -> int:
	return Balance.PUSH_CHARGES


## 0: hides the panel's "after the reserve" price line (every blast costs material; the overlay
## shows the per-blast cost instead).
func round_cost() -> float:
	return 0.0


func reload_label() -> String:
	return "ŞARJ"


func mode_text() -> String:
	return "ODAK" if ads > 0.5 else ""


## Half angle of the cone right now (deg): narrower while focusing (RMB).
func cone_deg() -> float:
	return lerpf(Balance.PUSH_CONE_DEG, Balance.PUSH_CONE_DEG * Balance.PUSH_FOCUS_CONE, clampf(ads, 0.0, 1.0))


func cone_range() -> float:
	return lerpf(Balance.PUSH_RANGE, Balance.PUSH_RANGE * Balance.PUSH_FOCUS_RANGE, clampf(ads, 0.0, 1.0))


func current_spread() -> float:
	return deg_to_rad(cone_deg())


func windup_frac() -> float:
	return clampf(_wind_t / Balance.PUSH_WINDUP, 0.0, 1.0) if _wind_t >= 0.0 else 0.0


## Refill progress of the charge being recharged (1 when full).
func charge_frac() -> float:
	return clampf(_charge_t / Balance.PUSH_RECHARGE, 0.0, 1.0) if mag < Balance.PUSH_CHARGES else 1.0


func max_charges() -> int:
	return Balance.PUSH_CHARGES


func shot_cost() -> float:
	return Balance.PUSH_COST


func can_afford() -> bool:
	return Game.material + 0.0001 >= Balance.PUSH_COST


## The numbers of one blast now (pusher_fired cfg; replay() reads the same keys).
func push_cfg() -> Dictionary:
	var c := default_cfg()
	c["range"] = cone_range()
	c["cone"] = cone_deg()
	return c


static func default_cfg() -> Dictionary:
	return {"range": Balance.PUSH_RANGE, "cone": Balance.PUSH_CONE_DEG, "speed_max": Balance.PUSH_SPEED_MAX,
			"speed_min": Balance.PUSH_SPEED_MIN, "up_bias": Balance.PUSH_UP_BIAS, "damage": Balance.PUSH_DAMAGE,
			"body_k": Balance.PUSH_BODY_K, "shell_k": Balance.PUSH_SHELL_K}


# =================================================================================================
# Input / firing
# =================================================================================================

## Click: starts the wind-up (the blast follows in _physics_process); no auto fire.
func _trigger(_trig: bool, pressed: bool, _alt: bool, _delta: float) -> void:
	if _wind_t >= 0.0 or not pressed:
		return
	if _cooldown > 0.0 or _since_sprint < sprint_to_fire or not player.viewmodel.is_raised():
		return
	if mag <= 0:
		_dry_fire()
		return
	if not can_afford():
		_no_material()
		return
	_wind_t = 0.0
	_play("selector", -12.0, 1.4)
	_play("push_charge", -4.0, randf_range(0.97, 1.03))
	_rk_vel += Vector4(-0.15, 0.0, 0.0, 0.02)


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if _wind_t < 0.0:
		return
	if not can_operate() or player == null or player.vehicle != null:
		_wind_t = -1.0
		return
	_wind_t += delta
	if _wind_t >= Balance.PUSH_WINDUP:
		_wind_t = -1.0
		if mag > 0:
			fire()


## Pays the blast's material, then the shared shot (charge, recoil, flash, sound, _fire_shot).
func fire() -> void:
	if not Game.spend_material(Balance.PUSH_COST):
		_no_material()
		return
	super.fire()
	_blast_t = 0.0


func _fire_shot(eye: Vector3, fwd: Vector3, _cb: Basis, muzzle: Vector3) -> void:
	var cfg := push_cfg()
	var r := apply_push(_fx_root, eye, fwd, cfg, "home", player)
	pushed = int(r.get("pushed", 0))
	deflected = int(r.get("deflected", 0))
	spawn_fx(_fx_root, muzzle, fwd, cfg, eye)
	pusher_fired.emit(eye, fwd, cfg)
	player.velocity -= fwd * Balance.PUSH_RECOIL
	if deflected > 0 and Game.hud:
		HudLvl.alert("Mermi saptırıldı!", 0, "pusher", 1.4)


func _dry_fire() -> void:
	_play("dry", -6.0, 1.2)
	if Game.sfx:
		Game.sfx.play("error", -12.0)
	hud.empty_flash()


func _no_material() -> void:
	_play("dry", -8.0, 0.9)
	if Game.sfx:
		Game.sfx.play("error", -10.0)
	hud.empty_flash()
	if Game.hud and _hint_t <= 0.0:
		_hint_t = 1.5
		if Balance.PUSH_COST > 0.0:
			HudLvl.alert("Malzeme yetersiz: atış başına %s m³ gerekli" % String.num(Balance.PUSH_COST, 1), 1, "no_mat", 2.0)


## R: nothing to reload (the capacitor refills by itself), only a hint.
func reload() -> void:
	if _hint_t > 0.0:
		return
	_hint_t = 1.5
	_play("selector", -14.0, 0.8)
	if Game.hud:
		HudLvl.alert("Kinetik İtici doldurulmaz: kapasitör kendiliğinden şarj olur", 0, "pusher", 2.0)


func _on_state_changed() -> void:
	super._on_state_changed()
	if not active or not equipped:
		_wind_t = -1.0


func _muzzle_fx(muzzle: Vector3, fwd: Vector3, _up: Vector3, _cb: Basis) -> void:
	_flash_t = 1.0
	_randomize_flash(1.0)
	fx.muzzle_light(muzzle + fwd * 1.0, ENERGY, muzzle_energy, 0.14, 18.0)
	ScreenPunch.kick(0.7)


func _fire_sound() -> void:
	var space := _space_kind()
	_set_space(space)
	if space == 3:
		# Vacuum: the blow through the suit only.
		_play("push_whump", -2.0, randf_range(0.9, 1.0), true)
		_play("boom_body", -6.0, 0.8, true)
		_shot_body(space, 0.75, -80.0)
		return
	_play("push_whump", 0.0, randf_range(0.95, 1.05), true)
	_play("cannon", -7.0, randf_range(1.12, 1.2), true, 1.4)
	_play("boom_body", -7.0, randf_range(0.8, 0.9), true)
	_play("push_crackle", -7.0, randf_range(0.92, 1.1))
	_play("whoosh", -6.0, randf_range(0.8, 0.95))
	_shot_body(space, 0.75, -14.0)
	if space == 2 and (_snd.get("gtail", []) as Array).is_empty():
		_play("tail", -17.0, 0.9, true)


func _cam_fov(_e: float) -> float:
	return Settings.fov


func _cam_look(e: float) -> float:
	return lerpf(1.0, 0.9, e)


func _hip_sway() -> float:
	return 1.7


## Wind-up: the gun trembles and pulls back as the coils load.
func _pose_extra() -> Transform3D:
	var w := windup_frac()
	if w <= 0.0:
		return Transform3D()
	var j := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * 0.004 * w
	return Transform3D(Basis.from_euler(j), Vector3(0.0, 0.0, 0.012 * w))


# =================================================================================================
# The blast (static: the local shot and a replay of another machine's shot use the same code)
# =================================================================================================

## Applies one blast from `from` along `fwd` (cfg: see default_cfg) for side `team`, fired by
## `shooter` (excluded; may be null). Characters of another side in the cone and in sight are
## damaged and shoved (bots: fling(); others: ragdoll()), ragdoll limbs and loose rigid bodies get
## an impulse, enemy projectiles are deflected. On a multiplayer client only the look (local ragdoll
## limbs); the host's replay does the rest. Returns {"pushed", "deflected"}.
static func apply_push(ctx: Node3D, from: Vector3, fwd: Vector3, cfg: Dictionary, team: String, shooter: Node3D) -> Dictionary:
	var out := {"pushed": 0, "deflected": 0}
	if ctx == null or not ctx.is_inside_tree():
		return out
	var tree := ctx.get_tree()
	var space := ctx.get_world_3d().direct_space_state
	var reach := float(cfg.get("range", Balance.PUSH_RANGE))
	var cone := deg_to_rad(float(cfg.get("cone", Balance.PUSH_CONE_DEG)))
	var ex: Array = []
	if shooter is CollisionObject3D:
		ex.append((shooter as CollisionObject3D).get_rid())
	var client := Net.is_client()
	if not client:
		var owned: bool = shooter != null and shooter == Game.player
		var src: Vector3 = shooter.global_position if shooter != null and is_instance_valid(shooter) else from
		var dmg := float(cfg.get("damage", Balance.PUSH_DAMAGE))
		var first := true
		for n in tree.get_nodes_in_group(Game.DAMAGEABLE):
			if n == shooter or not (n is Node3D) or not is_instance_valid(n):
				continue
			if Game.team_of(n) == team or n.is_in_group("war_structure"):
				continue
			if n.has_method("is_dead") and n.is_dead():
				continue
			var nd := n as Node3D
			var up_t := nd.global_transform.basis.y
			var chest := nd.global_position + up_t * 0.9
			var to := chest - from
			var d := to.length()
			if d > reach + 0.4 or d < 0.01:
				continue
			var dn := to / d
			# The cone plus the body's own width (a bot right beside the barrel still gets it).
			if acos(clampf(fwd.dot(dn), -1.0, 1.0)) > cone + atan(0.45 / maxf(d, 0.3)):
				continue
			if not clear_line(space, from, chest, ex):
				continue
			var v := _speed(cfg, d, reach)
			var dir := _shove_dir(dn, fwd, up_t, float(cfg.get("up_bias", Balance.PUSH_UP_BIAS)))
			var r := Game.damage_target(nd, dmg, src, Vector3.ZERO, team)
			if n.has_method("fling"):
				n.fling(dir * v, src)
			elif n.has_method("ragdoll"):
				n.ragdoll(dir * v * Balance.PUSH_PLAYER_K, 2.0)
			out["pushed"] = int(out["pushed"]) + 1
			var killed: bool = n.has_method("is_dead") and n.is_dead()
			var ast = nd.get("astronaut")
			if not killed and ast != null and ast.has_method("hit_react"):
				ast.hit_react(dir, 1.0, false)
			if owned and not r.is_empty():
				var res: Dictionary = r.duplicate()
				if killed:
					res["killed"] = true
				HitFeel.inst().target_hit(nd, res, float(r.get("dmg", dmg)), chest,
						{"big": 0.55, "quiet": not first, "weapon": "Kinetik İtici"})
				first = false
		out["deflected"] = _deflect(tree, from, fwd, cfg, team, reach, cone)
		# Tear the ground out along the cone's footprint (synced brushes; the look is in spawn_fx).
		_tear_ground(ctx, from, fwd, cfg, team)
	_shove_bodies(tree, space, from, fwd, cfg, reach, cone, not client)
	# Grenades flying or lying in the cone go with the blast.
	var gk := Balance.PUSH_GRENADE_K
	for gs in tree.get_nodes_in_group("grenade_sim"):
		if gs.has_method("shove"):
			gs.shove(from, fwd, reach, cone, _speed(cfg, 0.0, reach) * gk, _speed(cfg, reach, reach) * gk)
	return out


## Replays another machine's blast (pusher_fired): the look and a 3D whump everywhere, the effect on
## the host / in single player. parent: a node in the world; team: the firing side as seen here;
## shooter: its body here (excluded, may be null).
static func replay(parent: Node3D, from: Vector3, dir: Vector3, cfg: Dictionary, team: String, shooter: Node3D = null) -> Dictionary:
	var c := default_cfg()
	c.merge(cfg, true)
	c["range"] = clampf(float(c["range"]), 1.0, 25.0)
	c["cone"] = clampf(float(c["cone"]), 2.0, 60.0)
	c["speed_max"] = clampf(float(c["speed_max"]), 0.0, 40.0)
	c["speed_min"] = clampf(float(c["speed_min"]), 0.0, 40.0)
	c["damage"] = clampf(float(c["damage"]), 0.0, 30.0)
	var d := dir.normalized() if dir.length_squared() > 1e-6 else Vector3.FORWARD
	spawn_fx(parent, from + d * 0.7, d, c, from)
	_sound_at(parent, from + d * 0.7)
	return apply_push(parent, from, d, c, team, shooter)


## Line of sight from a to b: no terrain collider in between, and (where a planet has no collision,
## or the collider lags an edit) no solid density either.
static func clear_line(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, ex: Array = []) -> bool:
	var q := PhysicsRayQueryParameters3D.create(a, b, Game.LAYER_TERRAIN, ex)
	if not space.intersect_ray(q).is_empty():
		return false
	var body := Game.dominant_body(b)
	if body != null and body.has_method("raycast_density"):
		var h: Dictionary = body.raycast_density(a, b, 0.4)
		if not h.is_empty() and float(h["distance"]) < a.distance_to(b) - 0.5:
			return false
	return true


## Push speed at distance d: min + (max - min) × (1 - d / reach)^PUSH_FALLOFF (strong only up close).
static func _speed(cfg: Dictionary, d: float, reach: float) -> float:
	var lo := float(cfg.get("speed_min", Balance.PUSH_SPEED_MIN))
	var hi := float(cfg.get("speed_max", Balance.PUSH_SPEED_MAX))
	var k := pow(1.0 - clampf(d / maxf(reach, 0.1), 0.0, 1.0), Balance.PUSH_FALLOFF)
	return lo + (hi - lo) * k


## Away from the emitter (a little toward the aim), never into the ground, tipped up by up_bias.
static func _shove_dir(dn: Vector3, fwd: Vector3, up: Vector3, up_bias: float) -> Vector3:
	var shove := dn.lerp(fwd, 0.35)
	var down := shove.dot(up)
	if down < 0.0:
		shove -= up * down * 0.85
	if shove.length_squared() < 1e-4:
		shove = fwd
	return (shove.normalized() + up * up_bias).normalized()


static func _up_of(p: Vector3) -> Vector3:
	var g: Vector3 = Game.gravity_at(p)
	if g.length_squared() > 1e-6:
		return -g.normalized()
	var b := Game.dominant_body(p)
	var u := p - (b.global_position if b != null else Game.planet_center())
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


## Enemy projectiles in flight inside the cone get pushed (a cannon shell can be sent back).
static func _deflect(tree: SceneTree, from: Vector3, fwd: Vector3, cfg: Dictionary, team: String, reach: float, cone: float) -> int:
	var n_def := 0
	var k := float(cfg.get("shell_k", Balance.PUSH_SHELL_K))
	for g in ["war_shell", "war_torpedo", "war_rocket"]:
		for n in tree.get_nodes_in_group(g):
			if not (n is Node3D) or not is_instance_valid(n) or Game.team_of(n) == team:
				continue
			if n.has_method("is_live") and not n.is_live():
				continue
			var vv = n.get("vel")
			if not (vv is Vector3):
				continue
			var to := (n as Node3D).global_position - from
			var d := to.length()
			if d > reach + 1.0 or d < 0.01:
				continue
			if acos(clampf(fwd.dot(to / d), -1.0, 1.0)) > cone + atan(0.6 / maxf(d, 0.3)):
				continue
			var dir := (to / d).lerp(fwd, 0.5).normalized()
			n.set("vel", (vv as Vector3) + dir * _speed(cfg, d, reach) * k)
			n_def += 1
	return n_def


## Ragdoll limbs (bots' corpses, found through their owners: the limbs have no collision layer) and,
## with `loose`, other rigid bodies (the skiff, wreck parts) in the cone get an impulse.
static func _shove_bodies(tree: SceneTree, space: PhysicsDirectSpaceState3D, from: Vector3, fwd: Vector3, cfg: Dictionary,
		reach: float, cone: float, loose: bool) -> void:
	var bodies: Array = []
	var up_bias := float(cfg.get("up_bias", Balance.PUSH_UP_BIAS))
	for g in ["war_ai", "net_player"]:
		for n in tree.get_nodes_in_group(g):
			var rd = n.get("_ragdoll")
			if rd == null or not is_instance_valid(rd):
				continue
			var bd = rd.get("bodies")
			if bd is Dictionary and not (bd as Dictionary).is_empty():
				_shove_ragdoll((bd as Dictionary).values(), from, fwd, cfg, reach, cone, up_bias)
				bodies.append_array((bd as Dictionary).values())     # (never shoved again below)
	if loose:
		var sq := PhysicsShapeQueryParameters3D.new()
		var sph := SphereShape3D.new()
		sph.radius = reach
		sq.shape = sph
		sq.transform = Transform3D(Basis(), from)
		sq.collision_mask = Game.LAYER_VEHICLE | Game.LAYER_SHIP
		for h in space.intersect_shape(sq, 16):
			var c = h.get("collider")
			if c is RigidBody3D and not bodies.has(c):
				bodies.append(c)
	var k := float(cfg.get("body_k", Balance.PUSH_BODY_K))
	for b in bodies:
		if not (b is RigidBody3D) or not is_instance_valid(b) or (b as RigidBody3D).freeze:
			continue
		if _is_ragdoll_limb(b):
			continue                      # shoved as a whole by _shove_ragdoll
		var rb := b as RigidBody3D
		var to := rb.global_position - from
		var d := to.length()
		if d > reach or d < 0.01:
			continue
		if acos(clampf(fwd.dot(to / d), -1.0, 1.0)) > cone + atan(0.3 / maxf(d, 0.3)):
			continue
		var dir := _shove_dir(to / d, fwd, _up_of(rb.global_position), float(cfg.get("up_bias", Balance.PUSH_UP_BIAS)))
		rb.apply_central_impulse(dir * _speed(cfg, d, reach) * minf(rb.mass, Balance.PUSH_BODY_MASS_CAP) * k)


## A ragdoll (all limbs of one body) in the cone: ONE velocity change for every limb, taken from the
## limb nearest the blast, so the body flies as a whole. (Shoving each limb on its own, by its own
## distance and mass, tore the joints apart and stretched the arms and legs.)
static func _shove_ragdoll(limbs: Array, from: Vector3, fwd: Vector3, cfg: Dictionary, reach: float, cone: float,
		up_bias: float) -> void:
	var best_d := INF
	var best: RigidBody3D = null
	for b in limbs:
		if not (b is RigidBody3D) or not is_instance_valid(b) or (b as RigidBody3D).freeze:
			continue
		var to: Vector3 = (b as RigidBody3D).global_position - from
		var d := to.length()
		if d > reach or d < 0.01:
			continue
		if acos(clampf(fwd.dot(to / d), -1.0, 1.0)) > cone + atan(0.3 / maxf(d, 0.3)):
			continue
		if d < best_d:
			best_d = d
			best = b
	if best == null:
		return
	var to_b := best.global_position - from
	var dir := _shove_dir(to_b / maxf(best_d, 0.01), fwd, _up_of(best.global_position), up_bias)
	var dv := dir * _speed(cfg, best_d, reach)
	for b in limbs:
		if b is RigidBody3D and is_instance_valid(b) and not (b as RigidBody3D).freeze:
			(b as RigidBody3D).linear_velocity += dv


static func _is_ragdoll_limb(b: Object) -> bool:
	var p = (b as Node).get_parent() if b is Node else null
	return p != null and p.get("bodies") is Dictionary and p.get("player") != null


# =================================================================================================
# Look of a blast
# =================================================================================================

static func _shock_shader() -> Shader:
	if _shock_sh == null:
		_shock_sh = Shader.new()
		_shock_sh.code = SHOCK_SHADER
	return _shock_sh


## The look of one blast at `muzzle` along `fwd` (a replay too): the shock cone and rings racing out
## to cfg.range, cyan sparks off the dish, a pale air burst, dust scoured off the ground in the cone
## (probes from `eye`), a travelling light.
static func spawn_fx(parent: Node3D, muzzle: Vector3, fwd: Vector3, cfg: Dictionary, eye: Vector3) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var reach := float(cfg.get("range", Balance.PUSH_RANGE))
	var cone_d := float(cfg.get("cone", Balance.PUSH_CONE_DEG))
	var sh := Shock.new()
	sh.reach = reach
	sh.cone = deg_to_rad(cone_d)
	sh.shader = _shock_shader()
	parent.add_child(sh)
	sh.global_transform = Transform3D(Rockets._basis_y(fwd), muzzle)
	Rockets.puff(parent, muzzle, fwd, {"amount": 26, "life": 0.3, "vmin": 4.0, "vmax": 13.0, "damp": 4.0,
			"spread": cone_d * 0.8, "size": 0.09, "scale": [1.0, 0.8, 0.3], "radius": 0.05, "add": true,
			"color": Color(3.0, 3.0, 3.0), "ramp": [[0.0, Color(0.85, 0.97, 1.0, 1.0)], [0.5, Color(0.45, 0.85, 1.0, 0.9)],
				[1.0, Color(0.2, 0.5, 1.0, 0.0)]]})
	Rockets.puff(parent, muzzle + fwd * 0.3, fwd, {"amount": 18, "life": 0.9, "vmin": 6.0, "vmax": 16.0, "damp": 6.0,
			"spread": cone_d * 0.7, "size": 0.7, "scale": [0.3, 1.4, 2.4], "radius": 0.1,
			"ramp": [[0.0, Color(0.9, 0.95, 1.0, 0.0)], [0.1, Color(0.88, 0.93, 1.0, 0.28)], [1.0, Color(0.85, 0.9, 0.95, 0.0)]]})
	_ground_dust(parent, eye, fwd, reach, deg_to_rad(cone_d))
	_tear_fx(parent, eye, fwd, cfg)


## Where the shock meets the ground: rays fanned through the cone and probes straight down from
## along its axis; each hit throws a burst of dust (the planet's soil colour) outward.
static func _ground_dust(parent: Node3D, eye: Vector3, fwd: Vector3, reach: float, cone: float) -> void:
	var space := parent.get_world_3d().direct_space_state
	var ex: Array = []
	var pl = Game.player
	if pl is CollisionObject3D:
		ex.append((pl as CollisionObject3D).get_rid())
	var up := _up_of(eye)
	var side := fwd.cross(up)
	if side.length_squared() < 1e-4:
		side = fwd.cross(Vector3.RIGHT)
	side = side.normalized()
	var vert := side.cross(fwd).normalized()
	var tc := tan(cone)
	var dirs: Array = [fwd]
	for k in 6:
		var a := TAU * float(k) / 6.0 + randf() * 0.5
		dirs.append((fwd + (side * cos(a) + vert * sin(a)) * tc * 0.85).normalized())
	var spots := 0
	for dd in dirs:
		if spots >= 6:
			break
		var dv: Vector3 = dd
		var h := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + dv * reach, Game.LAYER_TERRAIN, ex))
		if h.is_empty():
			continue
		var p: Vector3 = h["position"]
		var n: Vector3 = h["normal"]
		var along := dv - n * dv.dot(n)
		var out_dir := n * 0.6 + (along.normalized() * 0.8 if along.length_squared() > 1e-4 else Vector3.ZERO)
		_dust(parent, p, n, out_dir.normalized(), 1.0 - eye.distance_to(p) / reach * 0.6)
		spots += 1
	var flat := fwd - up * fwd.dot(up)
	if flat.length_squared() < 1e-4:
		return
	flat = flat.normalized()
	for s in [2.0, 4.5, 7.0]:
		if float(s) > reach or spots >= 8:
			break
		var c: Vector3 = eye + fwd * float(s)
		var h2 := space.intersect_ray(PhysicsRayQueryParameters3D.create(c, c - up * 2.6, Game.LAYER_TERRAIN, ex))
		if h2.is_empty():
			continue
		var p2: Vector3 = h2["position"]
		var n2: Vector3 = h2["normal"]
		_dust(parent, p2, n2, (n2 * 0.5 + flat).normalized(), 1.0 - p2.distance_to(c) / 2.6 * 0.5)
		spots += 1


static func _dust(parent: Node3D, p: Vector3, n: Vector3, dir: Vector3, k: float) -> void:
	var col: Color = Rifle.ground_color(p, n)
	var g: Vector3 = Game.gravity_at(p)
	Rockets.puff(parent, p + n * 0.05, dir, {"amount": maxi(int(16.0 * k), 4), "life": 1.6, "vmin": 2.0,
			"vmax": 8.0 * k + 1.0, "damp": 3.5, "spread": 32.0, "size": 0.55, "scale": [0.4, 1.3, 2.4], "radius": 0.25,
			"gravity": g * 0.06, "ramp": [[0.0, Color(col, 0.0)], [0.08, Color(col, 0.75)], [1.0, Color(col.lightened(0.15), 0.0)]]})


## A positional whump for a replayed blast (the local shot plays its layers through the gun).
static func _sound_at(parent: Node3D, pos: Vector3) -> void:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or not (pl.get("items") is Array):
		return
	var st: AudioStream = null
	for it in pl.items:
		if it != null and it.has_method("synth_stream"):
			st = it.synth_stream("push_whump")
			break
	if st == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = st
	p.unit_size = 10.0
	p.max_distance = 200.0
	parent.add_child(p)
	p.global_position = pos
	p.play()
	p.finished.connect(p.queue_free)


# =================================================================================================
# Tearing the ground: where the cone meets it, the carve (host) and the flying mass (everyone)
# =================================================================================================

static var _tear_key := ""
static var _tear_pts: Array = []

## Where the cone meets the ground: [[position, normal, distance from `from`], ...], nearest first,
## at least 1.6 m apart, PUSH_TEAR_STAMPS at most. Density raycasts (they work far from any collider,
## e.g. the host replaying a distant client's blast): a fan through the cone (axis, a ring at 55 %
## and one at the rim) and probes straight down along the axis inside the cone's radius there (a
## level shot skims the ground). Deterministic, cached for the blast (carve and look agree).
static func tear_points(from: Vector3, fwd: Vector3, cfg: Dictionary) -> Array:
	var key := "%s|%s|%s|%s" % [from.snapped(Vector3.ONE * 0.01), fwd.snapped(Vector3.ONE * 0.001), cfg.get("range"), cfg.get("cone")]
	if key == _tear_key:
		return _tear_pts
	var reach := float(cfg.get("range", Balance.PUSH_RANGE))
	var cone := deg_to_rad(float(cfg.get("cone", Balance.PUSH_CONE_DEG)))
	var body := Game.dominant_body(from)
	var cands: Array = []
	if body != null and body.has_method("raycast_density"):
		var up := _up_of(from)
		var side := fwd.cross(up)
		if side.length_squared() < 1e-4:
			side = fwd.cross(Vector3.RIGHT)
		side = side.normalized()
		var vert := side.cross(fwd).normalized()
		var tc := tan(cone)
		var dirs: Array = [fwd]
		for ring in [0.55, 0.95]:
			for k in 8:
				var a := TAU * float(k) / 8.0 + (0.39 if float(ring) > 0.9 else 0.0)
				dirs.append((fwd + (side * cos(a) + vert * sin(a)) * tc * float(ring)).normalized())
		for dd in dirs:
			var dv: Vector3 = dd
			var h: Dictionary = body.raycast_density(from, from + dv * reach, 0.6, true)
			if not h.is_empty():
				cands.append([h["position"], h["normal"], float(h["distance"])])
		for s in [2.5, 5.0, 8.0, 11.0, 14.0, 17.0]:
			if float(s) > reach:
				break
			var c: Vector3 = from + fwd * float(s)
			var h2: Dictionary = body.raycast_density(c, c - up * (float(s) * tc + 0.3), 0.5, true)
			if not h2.is_empty():
				cands.append([h2["position"], h2["normal"], from.distance_to(h2["position"])])
	cands.sort_custom(func(a, b): return float(a[2]) < float(b[2]))
	var out: Array = []
	for cd in cands:
		var ok := true
		for o in out:
			if (o[0] as Vector3).distance_to(cd[0]) < 1.6:
				ok = false
				break
		if ok:
			out.append(cd)
		if out.size() >= Balance.PUSH_TEAR_STAMPS:
			break
	_tear_key = key
	_tear_pts = out
	return out


## Strength 0..1 of the blast at distance d (1 at the emitter).
static func _tear_k(d: float, reach: float) -> float:
	return 1.0 - clampf(d / maxf(reach, 0.1), 0.0, 1.0)


## The blast's direction along the ground at a tear point (the soil is thrown that way).
static func _tear_flat(fwd: Vector3, n: Vector3) -> Vector3:
	var flat := fwd - n * fwd.dot(n)
	return flat.normalized() if flat.length_squared() > 1e-4 else n.cross(Vector3.RIGHT).normalized()


## Host / single player: DIG brushes scooping the ground out along the cone's footprint, applied
## over the next physics frames (Tearer); synced by the planet's net hook like any dig.
static func _tear_ground(ctx: Node3D, from: Vector3, fwd: Vector3, cfg: Dictionary, team: String) -> void:
	var pts := tear_points(from, fwd, cfg)
	if pts.is_empty():
		return
	var reach := float(cfg.get("range", Balance.PUSH_RANGE))
	var t := Tearer.new()
	t.team = team
	t.body = Game.dominant_body(from)
	for pt in pts:
		var p: Vector3 = pt[0]
		var n: Vector3 = pt[1]
		var k := _tear_k(float(pt[2]), reach)
		var r := lerpf(float(Balance.PUSH_TEAR_R[0]), float(Balance.PUSH_TEAR_R[1]), k)
		var amount := lerpf(float(Balance.PUSH_TEAR_DEPTH[0]), float(Balance.PUSH_TEAR_DEPTH[1]), k)
		# Centred a little below and ahead of the surface point: a scoop open toward the blast.
		t.stamps.append([p - n * 0.4 + _tear_flat(fwd, n) * 0.4, r, amount])
	ctx.add_child(t)


## Applies queued DIG stamps two per physics frame, then frees itself. Own-team torpedoes ignore
## the brushes (torpedo.gd _carving).
class Tearer extends Node:
	var body: Node3D
	var team := ""
	var stamps: Array = []

	func _physics_process(_delta: float) -> void:
		var n := 0
		while not stamps.is_empty() and n < 2:
			var s: Array = stamps.pop_front()
			if body != null and is_instance_valid(body):
				Torpedo._carving = team
				Dig.dig_at(body, s[0], float(s[1]), Dig.MODE_DIG, float(s[2]))
				Torpedo._carving = ""
			n += 1
		if stamps.is_empty():
			queue_free()


## The look of the torn ground (every machine): per tear point a spray of flying rock / soil chunks
## along the blast, a dirt burst and a dust plume in the ground colour, the rocks freed there thrown
## too (planet.add_push_zone); at the nearest point a flat dust ring, a refracting shock ring on the
## ground, a deep crunch, and camera shake for the local player nearby.
static func _tear_fx(parent: Node3D, from: Vector3, fwd: Vector3, cfg: Dictionary) -> void:
	var pts := tear_points(from, fwd, cfg)
	if pts.is_empty() or parent == null or not parent.is_inside_tree():
		return
	var reach := float(cfg.get("range", Balance.PUSH_RANGE))
	var body := Game.dominant_body(from)
	var pool := chunks()
	var first := true
	for pt in pts:
		var p: Vector3 = pt[0]
		var n: Vector3 = pt[1]
		var k := _tear_k(float(pt[2]), reach)
		var flat := _tear_flat(fwd, n)
		var col: Color = Rifle.ground_color(p, n)
		var throw_dir := (flat * 0.75 + n * 0.65).normalized()
		var v := lerpf(6.0, 16.0, k)
		if pool != null:
			pool.tint(col)
			var count := int(roundf(lerpf(3.0, 8.0, k)))
			for i in count:
				var jit := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.45
				var dv := (throw_dir + jit).normalized()
				if dv.dot(n) < 0.15:
					dv = (dv + n * 0.4).normalized()
				pool.spawn(p + n * 0.25 + jit * 0.4, dv * v * randf_range(0.6, 1.15), randf_range(0.1, 0.3) * lerpf(0.7, 1.25, k))
		if body != null and body.has_method("add_push_zone"):
			body.add_push_zone(p, lerpf(1.3, 2.4, k) + 1.4, throw_dir * v * 0.9)
		var dbr = body.get("_debris") if body != null else null
		if dbr != null and dbr.has_method("_dirt"):
			dbr._dirt(p, n, int(lerpf(10.0, 24.0, k)), lerpf(1.2, 2.6, k), col.darkened(0.2))
		Rockets.puff(parent, p + n * 0.1, throw_dir, {"amount": int(lerpf(10.0, 22.0, k)), "life": 2.2, "vmin": 2.0,
				"vmax": 4.0 + 9.0 * k, "damp": 2.6, "spread": 40.0, "size": 0.9, "scale": [0.4, 1.4, 3.0], "radius": 0.4,
				"gravity": Game.gravity_at(p) * 0.05, "ramp": [[0.0, Color(col, 0.0)], [0.06, Color(col, 0.85)],
					[1.0, Color(col.lightened(0.2), 0.0)]]})
		if first:
			first = false
			# Dust ring racing out along the ground, a shock ring, the crunch, shake nearby.
			Rockets.puff(parent, p + n * 0.15, n, {"amount": 34, "life": 1.3, "vmin": 7.0, "vmax": 13.0, "damp": 4.5,
					"spread": 88.0, "size": 0.7, "scale": [0.5, 1.2, 2.2], "radius": 0.3, "explosive": 0.98,
					"ramp": [[0.0, Color(col, 0.0)], [0.05, Color(col.lightened(0.1), 0.6)], [1.0, Color(col.lightened(0.25), 0.0)]]})
			var ring := GroundRing.new()
			ring.shader = _shock_shader()
			ring.reach = lerpf(3.5, 7.0, k)
			parent.add_child(ring)
			ring.global_transform = Transform3D(Rockets._basis_y(n), p + n * 0.12)
			if Game.sfx:
				Game.sfx.play_at("explosion_crunch", p, lerpf(-6.0, 0.0, k), 0.75)
				Game.sfx.play_at("impact", p, lerpf(-8.0, -2.0, k), 0.6)
			var pl = Game.player
			if pl != null and is_instance_valid(pl) and pl.has_method("add_trauma"):
				var dpl: float = (pl as Node3D).global_position.distance_to(p)
				if dpl < 24.0:
					pl.add_trauma(0.5 * (1.0 - dpl / 24.0) * lerpf(0.5, 1.0, k))


## A flat refracting ring racing out along the ground from the impact (local +Y = ground normal).
class GroundRing extends Node3D:
	const LIFE := 0.5
	var reach := 5.0
	var shader: Shader
	var t := 0.0
	var _mi: MeshInstance3D
	var _mat: ShaderMaterial

	func _ready() -> void:
		var tm := TorusMesh.new()
		tm.inner_radius = 0.82
		tm.outer_radius = 1.0
		tm.rings = 48
		tm.ring_segments = 8
		_mat = ShaderMaterial.new()
		_mat.shader = shader
		_mat.set_shader_parameter("band_on", 0.0)
		_mat.set_shader_parameter("strength", 0.06)
		_mat.set_shader_parameter("glow", 0.25)
		_mi = MeshInstance3D.new()
		_mi.mesh = tm
		_mi.material_override = _mat
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi)
		_update()

	func _process(delta: float) -> void:
		t += delta
		if t >= LIFE:
			queue_free()
			return
		_update()

	func _update() -> void:
		var u := clampf(t / LIFE, 0.0, 1.0)
		var r := maxf(reach * (1.0 - (1.0 - u) * (1.0 - u)), 0.2)
		_mi.scale = Vector3(r, r * 0.35, r)
		var fade := (1.0 - u) * (1.0 - u)
		_mat.set_shader_parameter("fade", fade)


## The pooled chunk spray (one for the session, under the Game autoload).
static func chunks() -> Chunks:
	if Game.has_meta("push_chunks"):
		var c = Game.get_meta("push_chunks")
		if is_instance_valid(c):
			return c as Chunks
	var n := Chunks.new()
	n.name = "PushChunks"
	Game.add_child(n)
	Game.set_meta("push_chunks", n)
	return n


## Up to PUSH_CHUNKS flying rock / soil chunks in one MultiMesh (DebrisMesh rock, tinted by the
## ground of the latest blast): ballistic under Game.gravity_at, terrain ray per step, bouncing with
## a rattle, then resting, sinking and shrinking away. Physics-lite and pooled: no bodies, ~1 ray
## per chunk per physics frame.
class Chunks extends Node3D:
	var n := Balance.PUSH_CHUNKS
	var _mm: MultiMesh
	var _mat: ShaderMaterial
	var _pos := PackedVector3Array()
	var _vel := PackedVector3Array()
	var _axis := PackedVector3Array()
	var _ang := PackedFloat32Array()
	var _rate := PackedFloat32Array()
	var _size := PackedFloat32Array()
	var _age := PackedFloat32Array()
	var _rest := PackedFloat32Array()       # -1 flying, else age when it came to rest
	var _live := PackedByteArray()
	var _next := 0
	var _snd_t := 0
	var _any := false

	func _ready() -> void:
		_mat = DebrisMesh.rock_material(Color(0.3, 0.25, 0.2), Color(0.45, 0.38, 0.3), false, false)
		_mm = MultiMesh.new()
		_mm.transform_format = MultiMesh.TRANSFORM_3D
		_mm.use_colors = true
		_mm.use_custom_data = true
		_mm.mesh = DebrisMesh.rock_mesh()
		_mm.instance_count = n
		for i in n:
			_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * 0.0001), Vector3.ZERO))
			_mm.set_instance_color(i, Color(0, 0, 0, 0))
			_mm.set_instance_custom_data(i, Color(0, 0, 0, 0))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = _mm
		mmi.material_override = _mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mmi)
		_pos.resize(n)
		_vel.resize(n)
		_axis.resize(n)
		_ang.resize(n)
		_rate.resize(n)
		_size.resize(n)
		_age.resize(n)
		_rest.resize(n)
		_live.resize(n)
		_live.fill(0)

	## Ground colour of the latest blast (one material for the pool).
	func tint(col: Color) -> void:
		_mat.set_shader_parameter("col_a", col.darkened(0.35))
		_mat.set_shader_parameter("col_b", col.lightened(0.08))

	func spawn(p: Vector3, v: Vector3, size: float) -> void:
		var i := _next
		_next = (_next + 1) % n
		_pos[i] = p
		_vel[i] = v
		_axis[i] = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
		_ang[i] = randf() * TAU
		_rate[i] = randf_range(4.0, 14.0) * (1.0 if randf() < 0.5 else -1.0)
		_size[i] = size
		_age[i] = 0.0
		_rest[i] = -1.0
		_live[i] = 1
		_any = true

	func _physics_process(delta: float) -> void:
		if not _any:
			return
		var space := get_world_3d().direct_space_state
		var any := false
		for i in n:
			if _live[i] == 0:
				continue
			any = true
			_age[i] += delta
			var p: Vector3 = _pos[i]
			if _rest[i] < 0.0:
				var v: Vector3 = _vel[i] + Game.gravity_at(p) * delta
				var np := p + v * delta
				var q := PhysicsRayQueryParameters3D.create(p, np, Game.LAYER_TERRAIN)
				var hit := space.intersect_ray(q)
				if not hit.is_empty():
					var hn: Vector3 = hit["normal"]
					var sp := v.length()
					var vn := hn * v.dot(hn)
					v = (v - vn) * 0.55 - vn * 0.3
					_rate[i] *= 0.6
					np = (hit["position"] as Vector3) + hn * _size[i] * 0.6
					if sp > 4.0 and Game.sfx and Time.get_ticks_msec() - _snd_t > 90:
						_snd_t = Time.get_ticks_msec()
						Game.sfx.play_at("mine", np, lerpf(-22.0, -10.0, clampf(sp / 14.0, 0.0, 1.0)), randf_range(0.85, 1.15), 6.0)
					if v.length() < 1.3:
						_rest[i] = _age[i]
						v = Vector3.ZERO
				_vel[i] = v
				_pos[i] = np
				_ang[i] += _rate[i] * delta
			elif _age[i] > _rest[i] + 1.4 and _age[i] < _rest[i] + 2.4:
				# Sinking into the ground.
				var g := Game.gravity_at(p)
				if g.length_squared() > 1e-6:
					_pos[i] = p + g.normalized() * delta * 0.35
			var life := 6.0
			var shrink := 1.0
			if _rest[i] >= 0.0:
				shrink = 1.0 - smoothstep(_rest[i] + 1.4, _rest[i] + 2.4, _age[i])
				life = _rest[i] + 2.4
			if _age[i] >= life or shrink <= 0.0:
				_live[i] = 0
				_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * 0.0001), Vector3.ZERO))
				continue
			var b := Basis(_axis[i], _ang[i]).scaled(Vector3(1.0, 0.78, 0.9) * _size[i] * shrink)
			_mm.set_instance_transform(i, Transform3D(b, _pos[i]))
		_any = any


# =================================================================================================
# Per frame: capacitor, glow, coils, claws
# =================================================================================================

func _tick(delta: float, _on: bool) -> void:
	_hint_t = maxf(_hint_t - delta, 0.0)
	_blast_t += delta
	_ready_flash = maxf(_ready_flash - delta * 3.0, 0.0)
	# The capacitor refills one charge at a time (also while holstered).
	if mag < Balance.PUSH_CHARGES:
		_charge_t += delta
		if _charge_t >= Balance.PUSH_RECHARGE:
			_charge_t = 0.0
			mag += 1
			_ready_flash = 1.0
			if equipped and active:
				_play("push_ready", -13.0, 1.0 + 0.06 * mag)
	else:
		_charge_t = 0.0


func _animate_model(delta: float) -> void:
	super._animate_model(delta)
	if model == null or _coil_mat == null:
		return
	var wind := windup_frac()
	var blast := exp(-_blast_t * 9.0)
	var lvl := float(mag) / float(maxi(Balance.PUSH_CHARGES, 1))
	var flick := 1.0
	if mag <= 0 or not can_afford():
		flick = 0.55 + 0.45 * sin(_t * 23.0) * sin(_t * 7.0)      # starved: the coils sputter
	var hot := ENERGY.lerp(Color(0.9, 0.97, 1.0), clampf(wind + blast, 0.0, 1.0))
	_coil_mat.set_shader_parameter("color", hot)
	_coil_mat.set_shader_parameter("energy", (0.6 + 2.2 * lvl) * flick + wind * 7.0 + blast * 12.0 + _ready_flash * 3.0)
	_dish_mat.set_shader_parameter("color", hot)
	_dish_mat.set_shader_parameter("energy", (0.4 + 1.2 * lvl) * flick + wind * 5.0 + blast * 16.0)
	_rim_mat.set_shader_parameter("energy", (0.8 + 1.5 * lvl) * flick + wind * 4.0 + blast * 10.0)
	_tip_mat.set_shader_parameter("energy", 1.5 * flick + wind * 8.0 + blast * 20.0)
	for i in _cell_mats.size():
		var e := 0.15
		if i < mag:
			e = 4.0 + _ready_flash * 2.0
		elif i == mag:
			e = 0.3 + 2.4 * charge_frac() * (0.75 + 0.25 * sin(_t * 12.0))
		(_cell_mats[i] as ShaderMaterial).set_shader_parameter("energy", e)
	# The coil stack slams back with the blast; the claws pinch in while charging and flare out.
	_coils.position = Vector3(0.0, 0.0, 0.016 * blast - 0.004 * wind)
	var spread := 0.32 * blast - 0.12 * wind
	for k in _prongs.size():
		(_prongs[k] as Node3D).transform = (_prong_xf[k] as Transform3D) * Transform3D(Basis(Vector3.RIGHT, spread), Vector3.ZERO)


# =================================================================================================
# Model
# =================================================================================================

## White capacitor housing (charge cells on top, heat sink behind), a white rail cage around four
## copper coils with glowing inner rings (a node that recoils), a dark emitter dish with a glowing
## face, rim and spike, three claws (animated), a front grip, a power cable.
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
	var copper := VM.mat(Color(0.78, 0.46, 0.24), 0.3, 0.9)
	_coil_mat = VM.glow(ENERGY, 2.0)
	_dish_mat = VM.glow(ENERGY, 1.5)
	_tip_mat = VM.glow(Color(0.8, 0.95, 1.0), 3.0)
	_rim_mat = VM.glow(ENERGY, 1.2)
	# Grip, trigger, guard.
	VM.grip(_gun, orange)
	VM.box(_gun, Vector3(0, 0.0, -0.034), Vector3(0.007, 0.024, 0.008), dark, Basis(Vector3.RIGHT, 0.25))
	VM.capsule(_gun, Vector3(0, -0.022, -0.022), Vector3(0, -0.022, -0.072), 0.0045, steel)      # low: room for the trigger finger
	VM.capsule(_gun, Vector3(0, -0.022, -0.072), Vector3(0, 0.02, -0.084), 0.0045, steel)
	# Capacitor housing.
	VM.soft_box(_gun, Vector3(0, 0.045, -0.01), Vector3(0.058, 0.062, 0.2), 0.012, white)
	VM.soft_box(_gun, Vector3(0, 0.0135, -0.02), Vector3(0.05, 0.013, 0.16), 0.006, dark)
	for sx in [-1.0, 1.0]:
		VM.box(_gun, Vector3(0.0295 * sx, 0.052, -0.01), Vector3(0.003, 0.012, 0.17), orange)
		VM.soft_box(_gun, Vector3(0.031 * sx, 0.03, 0.03), Vector3(0.006, 0.02, 0.08), 0.003, gray)
	# Charge cells on a cradle on top (one per charge).
	VM.soft_box(_gun, Vector3(0, 0.079, 0.005), Vector3(0.056, 0.008, 0.15), 0.003, dark)
	_cell_mats.clear()
	var nc := clampi(Balance.PUSH_CHARGES, 1, 5)
	for i in nc:
		var z := 0.065 - i * (0.12 / maxf(float(nc - 1), 1.0))
		var cm := VM.glow(ENERGY, 0.3)
		_cell_mats.append(cm)
		VM.seg(_gun, Vector3(-0.019, 0.091, z), Vector3(0.019, 0.091, z), 0.0105, 0.0105, cm, 14)
		for sx in [-1.0, 1.0]:
			VM.seg(_gun, Vector3(0.019 * sx, 0.091, z), Vector3(0.026 * sx, 0.091, z), 0.012, 0.012, dark, 14)
		VM.ring(_gun, Vector3(0, 0.091, z), Vector3.RIGHT, 0.0112, 0.0018, steel)
	# Rear heat sink.
	for i in 5:
		VM.box(_gun, Vector3(0, 0.046, 0.094 + i * 0.008), Vector3(0.05, 0.05, 0.003), dark)
	VM.soft_box(_gun, Vector3(0, 0.046, 0.13), Vector3(0.048, 0.05, 0.012), 0.004, gray)
	# Barrel core, the rail cage, the top spine with its stripe.
	VM.seg(_gun, Vector3(0, BY, -0.1), Vector3(0, BY, -0.37), 0.016, 0.016, dark, 14)
	for sx in [-1.0, 1.0]:
		VM.soft_box(_gun, Vector3(0.05 * sx, BY, -0.225), Vector3(0.01, 0.024, 0.27), 0.004, white)
	VM.soft_box(_gun, Vector3(0, BY + 0.05, -0.225), Vector3(0.022, 0.01, 0.27), 0.004, white)
	VM.box(_gun, Vector3(0, BY + 0.0555, -0.225), Vector3(0.008, 0.002, 0.24), orange)
	VM.soft_box(_gun, Vector3(0, BY, -0.095), Vector3(0.11, 0.06, 0.02), 0.006, gray)
	# Power cable on the left.
	VM.capsule(_gun, Vector3(-0.03, 0.03, -0.09), Vector3(-0.041, 0.026, -0.13), 0.0055, rubber)
	VM.capsule(_gun, Vector3(-0.041, 0.026, -0.13), Vector3(-0.044, 0.04, -0.15), 0.0055, rubber)
	# Front grip under the cage (left hand).
	VM.soft_box(_gun, Vector3(0, BY - 0.05, -0.23), Vector3(0.024, 0.02, 0.06), 0.006, dark)
	VM.capsule(_gun, Vector3(0, -0.07, -0.228), Vector3(0, 0.0, -0.232), 0.017, rubber)
	for i in 3:
		VM.ring(_gun, Vector3(0, -0.052 + i * 0.02, -0.229), Vector3.UP, 0.0182, 0.004, dark)
	VM.seg(_gun, Vector3(0, -0.094, -0.227), Vector3(0, -0.08, -0.228), 0.02, 0.019, orange)
	left_grip = VM.node(_gun, Vector3(0, -0.035, -0.23), hand_basis(Vector3(-0.42, -0.62, 0.66), Vector3(0, 1, 0)))
	# The coil stack (its own node: it recoils).
	_coils = VM.node(_gun)
	for i in COIL_Z.size():
		var z: float = COIL_Z[i]
		VM.ring(_coils, Vector3(0, BY, z), Vector3.FORWARD, 0.043, 0.014, copper)
		VM.ring(_coils, Vector3(0, BY, z), Vector3.FORWARD, 0.03, 0.006, _coil_mat)
		for sx in [-1.0, 1.0]:
			VM.box(_coils, Vector3(0.045 * sx, BY, z), Vector3(0.008, 0.02, 0.016), dark)
	# Emitter dish: dark bowl, orange rim, glowing rim ring and face, the spike.
	VM.seg(_gun, Vector3(0, BY, -0.36), Vector3(0, BY, DISH_Z), 0.028, 0.082, dark, 28)
	VM.ring(_gun, Vector3(0, BY, DISH_Z), Vector3.FORWARD, 0.086, 0.009, orange)
	VM.ring(_gun, Vector3(0, BY, DISH_Z - 0.004), Vector3.FORWARD, 0.077, 0.004, _rim_mat)
	VM.seg(_gun, Vector3(0, BY, DISH_Z - 0.001), Vector3(0, BY, DISH_Z - 0.003), 0.072, 0.072, _dish_mat, 28)
	VM.capsule(_gun, Vector3(0, BY, DISH_Z - 0.004), Vector3(0, BY, DISH_Z - 0.03), 0.007, steel)
	VM.sphere(_gun, Vector3(0, BY, DISH_Z - 0.036), 0.009, _tip_mat)
	# Three claws around the rim (local +Y outward, -Z forward; they flare about local X).
	_prongs.clear()
	_prong_xf.clear()
	for k in 3:
		var a := PI * 0.5 + k * TAU / 3.0
		var rad := Vector3(cos(a), sin(a), 0.0)
		var b := Basis(rad.cross(Vector3.BACK), rad, Vector3.BACK)
		var pn := VM.node(_gun, Vector3(0, BY, DISH_Z + 0.012) + rad * 0.078, b)
		VM.capsule(pn, Vector3.ZERO, Vector3(0, -0.012, -0.065), 0.0055, white)
		VM.box(pn, Vector3(0, 0.002, -0.02), Vector3(0.012, 0.006, 0.03), dark)
		VM.sphere(pn, Vector3(0, -0.012, -0.068), 0.0045, _tip_mat)
		_prongs.append(pn)
		_prong_xf.append(pn.transform)
	_muzzle = VM.node(_gun, Vector3(0, BY, DISH_Z - 0.04))
	_make_flash(_gun, Vector3(0, BY, DISH_Z - 0.06), 1.9, Color(0.5, 0.85, 1.0))
	var skip: Array = [_coils, _flash_root, _muzzle, left_grip] + _prongs
	VM.bake(_gun, skip)
	VM.bake(_coils)
	for pn in _prongs:
		VM.bake(pn)
	return model


func _build_tp(p: Node3D) -> Node3D:
	var white := _tp_mat(Color(0.9, 0.91, 0.92), 0.35, 0.0)
	var orange := _tp_mat(Color(0.95, 0.42, 0.08), 0.55, 0.0)
	var dark := _tp_mat(Color(0.16, 0.17, 0.19), 0.4, 0.6)
	var copper := _tp_mat(Color(0.78, 0.46, 0.24), 0.3, 0.9)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = ENERGY
	glow.emission_enabled = true
	glow.emission = ENERGY
	glow.emission_energy_multiplier = 3.0
	VM.capsule(p, Vector3(0, -0.06, 0.005), Vector3(0, 0.01, 0), 0.018, dark)
	VM.box(p, Vector3(0, 0.045, -0.01), Vector3(0.058, 0.062, 0.2), white)
	VM.box(p, Vector3(0.03, 0.052, -0.01), Vector3(0.003, 0.012, 0.17), orange)
	VM.box(p, Vector3(0, 0.09, 0.005), Vector3(0.05, 0.02, 0.13), glow)
	VM.seg(p, Vector3(0, BY, -0.1), Vector3(0, BY, -0.37), 0.016, 0.016, dark, 8)
	for z in COIL_Z:
		VM.ring(p, Vector3(0, BY, float(z)), Vector3.FORWARD, 0.043, 0.014, copper)
	VM.seg(p, Vector3(0, BY, -0.36), Vector3(0, BY, DISH_Z), 0.028, 0.082, dark, 12)
	VM.seg(p, Vector3(0, BY, DISH_Z - 0.001), Vector3(0, BY, DISH_Z - 0.003), 0.072, 0.072, glow, 12)
	VM.capsule(p, Vector3(0, -0.07, -0.23), Vector3(0, 0.0, -0.23), 0.017, dark)
	return VM.node(p, Vector3(0, BY, DISH_Z - 0.04))


# =================================================================================================
# HUD overlay: the cone ring, charge pips, cost and state messages
# =================================================================================================

class PusherHud extends "res://scripts/items/weapon_hud.gd":
	func _draw_top() -> void:
		var w = weapon
		var vs := _top.size
		var c := vs * 0.5
		var col: Color = w.accent_color()
		var a := 1.0 - float(w.get("_sprint_w"))
		var cam: Camera3D = w.player.camera if w.player != null else null
		var fov := deg_to_rad(cam.fov if cam != null else 75.0)
		var half := vs.y * 0.5
		var wind: float = w.windup_frac()
		# The real cone: its edge projected on the screen (shrinks with focus, pinches while charging).
		var r := clampf(tan(deg_to_rad(float(w.cone_deg()))) / tan(fov * 0.5) * half, 14.0, half * 0.85)
		r *= 1.0 - 0.12 * wind
		var ring := Color(col.lightened(0.2 + 0.5 * wind), (0.5 + 0.45 * wind) * a)
		if a > 0.02:
			for k in 4:
				var s := k * PI * 0.5 + 0.2
				_top.draw_arc(c + Vector2(1, 1), r, s, s + PI * 0.5 - 0.4, 32, Color(0, 0, 0, 0.4 * a), 3.0, true)
				_top.draw_arc(c, r, s, s + PI * 0.5 - 0.4, 32, ring, 1.8, true)
			for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
				var dv: Vector2 = d
				_top.draw_line(c + dv * (r - 8.0), c + dv * (r + 1.0), ring, 2.0, true)
			_top.draw_circle(c + Vector2(1, 1), 1.9, Color(0, 0, 0, 0.55 * a))
			_top.draw_circle(c, 1.5, Color(col.lightened(0.4), a))
		# Charges: one pip each, the refilling one fills up.
		var n: int = w.max_charges()
		var mag: int = w.mag
		var frac: float = w.charge_frac()
		var pw := 16.0
		var gap := 5.0
		var x0 := c.x - (n * pw + (n - 1) * gap) * 0.5
		var y := c.y + 30.0
		for i in n:
			var p := Vector2(x0 + i * (pw + gap), y)
			_top.draw_rect(Rect2(p, Vector2(pw, 5.0)), Color(0, 0, 0, 0.45), true)
			if i < mag:
				_top.draw_rect(Rect2(p, Vector2(pw, 5.0)), Color(col, 0.95), true)
			elif i == mag:
				_top.draw_rect(Rect2(p, Vector2(pw * frac, 5.0)), Color(col, 0.45), true)
		var cost := "%s m³/atış" % String.num(float(w.shot_cost()), 1)
		if not w.can_afford():
			var blink := 0.55 + 0.45 * sin(_t * 9.0)
			_text_c(c + Vector2(0, 56), "MALZEME YOK  ·  " + cost, 13, Color(1.0, 0.42, 0.36, blink), _font_b)
		elif mag <= 0:
			var blink2 := 0.55 + 0.45 * sin(_t * 7.0)
			_text_c(c + Vector2(0, 56), "ŞARJ OLUYOR  %d%%" % int(frac * 100.0), 13, Color(col.lightened(0.3), blink2), _font_b)
		elif float(w.shot_cost()) > 0.0:
			_text_c(c + Vector2(0, 54), cost, 10, Color(1, 1, 1, 0.45 * a), _font)
		if w.player != null and w.player.get("interact_target") != null:
			_top.draw_arc(c, 18.0, 0, TAU, 40, Color(1.0, 0.85, 0.45, 0.9 * a), 2.0, true)


## Inspect (Y, scripts/items/handling.gd): the field coils glow up and flicker while the gun is
## turned to the side.
func _inspect_touch(u: float, w: float) -> void:
	if _coil_mat == null:
		return
	var k := smoothstep(0.12, 0.3, u) * (1.0 - smoothstep(0.62, 0.8, u)) * w
	if k > 0.001:
		var e := float(_coil_mat.get_shader_parameter("energy"))
		_coil_mat.set_shader_parameter("energy", e + k * (3.0 + sin(u * 70.0) * 0.8))
