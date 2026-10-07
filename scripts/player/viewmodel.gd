extends Node3D
## First-person arms: astronaut suit sleeves, gloved hands, a wrist computer on the left arm and
## the held item in the right hand. Handles bob, sway, breathing, recoil and the swap animation.
## Weapon handling for every item (scripts/items/handling.gd): the wall pull-back (probed each
## physics step: wall_target, sprung into `wall`; guns ask blocks_ads() / blocks_fire()), the melee
## swing pose of the child `melee` (scripts/player/melee.gd, V), the drill / build tool inspect
## (Y; guns run their own) and the draw / holster foley of a swap.
## Two-handed grips (item.left_grip): the left rig turns about the fist axis and the wrist computer
## may slide around the forearm so its screen faces the eye with any gun (wrist_face_search; items
## may set wrist_face / wrist_roll_limit / wrist_slide_limit). The screen shows health (CAN) on top
## and flashes on hits (scripts/player/wrist_display.gd).
## Gloves (scripts/player/vm_hand.gd): jointed fingers. Every item's model records its primitives as
## it bakes; its grips are solved against them on a worker thread (cached per item node): the right
## hand three fingers round the pistol grip, the index on the trigger (it squeezes while firing), the
## thumb over; the left hand on the item's grip_left handle (C-clamp on handguards and the pump,
## wrapped round vertical grips), the palm offset to the handle's size. Off the grip the fingers
## open into a cupped magazine hold, a grenade fist, a shell pinch, the wrist-scan fist or a relaxed
## rest. Arms and item hide while the match is over (Game.match_over), the tree is paused or a UI
## panel is open (_ui_hidden).
## Motion: the drill / build tool share the guns' layer (scripts/items/gun_feel.gd Carry + Motion):
## the two-handed run carry with its stride sway, walk bob, breathing, look sway, jump lift, landing
## dip and crouch / slide cant.

const VM := preload("res://scripts/player/vm_parts.gd")
const WristDisplay := preload("res://scripts/player/wrist_display.gd")
const Handling := preload("res://scripts/items/handling.gd")
const Melee := preload("res://scripts/player/melee.gd")
const Balance := preload("res://scripts/war/balance.gd")
const VMHand := preload("res://scripts/player/vm_hand.gd")
const GunFeel := preload("res://scripts/items/gun_feel.gd")

## Grenade in the left fist (scripts/player/hand_action.gd puts its prop here): the ball sits in the
## palm, its fuse head above the index finger.
const GRENADE_AT := Vector3(0.009, -0.04, -0.005)
const GRENADE_R := Vector3(0.031, 0.037, 0.031)
## Shotgun shell in the left fist during a reload (shotgun.gd's prop: centre and axis, r 0.0105).
const SHELL_A := Vector3(-0.004, -0.012, 0.004)
const SHELL_B := Vector3(-0.004, 0.058, -0.0257)
## Sniper bolt knob in the right hand while it works the bolt (sniper.gd _bolt_pose: the knob sits
## 2.8 cm down the fist axis).
const BOLT_KNOB := Vector3(0.0, -0.028, 0.0)
## Fallback grips until an item's solve arrives (the rifle's, from the probe).
const GRIP_R0 := [0.31, 0.45, 1.05, 0.52, -0.1, 1.19, 1.06, 0.65, -0.02, 1.26, 0.89, 0.84, 0.09, 1.33, 0.44, 0.92,
		0.1, 0.77, 0.92, 0.0]
const GRIP_L0 := [0.0, 0.59, 1.1, 0.0, 0.0, 0.54, 1.19, -0.09, 0.0, 0.54, 1.17, 0.02, 0.0, 0.54, 0.86, 0.03,
		0.0, 0.56, 0.59, 0.0]

const RIGHT_POS := Vector3(0.3, -0.195, -0.53)
const RIGHT_ROT := Vector3(-0.05, 0.15, 0.0)
const LEFT_WRIST := Vector3(-0.34, -0.43, -0.48)       # camera space, idle (one-handed items: lowered)
const LEFT_ELBOW_DIR := Vector3(-0.5, -0.45, 0.74)
const LOWER_TIME := 0.25
const RAISE_TIME := 0.38

var player
var right_rig: Node3D
var right_hand: Node3D
var left_rig: Node3D
var left_hand: Node3D

var _models := {}            # item -> model root
var _current = null          # item whose model is shown
var _pending = null          # item to show after lowering
var _on_mid: Callable
var _swap := 1.0             # 0 = raised, 1 = lowered (start lowered, raise on spawn)
var _swap_dir := -1          # +1 lowering, -1 raising, 0 idle
var _t := 0.0
var _bob_phase := 0.0
var _bob_amt := 0.0
var _sway := Vector2.ZERO
var _look := Vector2.ZERO
var _sprint := 0.0
var _carry := GunFeel.Carry.new()       # the drill / build tool's motion layer (the guns run their own)
var _motion := GunFeel.Motion.new()
var _use := 0.0
var _kick := 0.0
var _kick_vel := 0.0
var _lw_h := Vector3.ZERO      # left wrist, forearm dir, screen normal and screen center in hand frame
var _ldir_h := Vector3.BACK
var _ln_h := Vector3.UP
var _lscreen_h := Vector3.ZERO
var _lgrip := 0.0
var _hold := Vector3.ZERO
var _swim := 0.0
var _swim_ph := 0.0
var _last_grip_xf := Transform3D()
var _jitter := Vector3.ZERO
# Weapon handling.
var melee                        # scripts/player/melee.gd (V)
var wall_target := 0.0           # 0..1 pull-back the probe asks for (physics step)
var wall := 0.0                  # sprung pull-back actually shown
var _wall_v := 0.0
var _tool_insp = Handling.Inspect.new()

# Wrist computer.
var _wrist_timer := 0.0
var _wrist_vp: SubViewport
var _wrist_ui
var _wrist_hp := -1.0                   # health last seen (a drop flashes the screen)
# Wrist screen facing on a left grip (wrist_face_search).
var _wrist_root: Node3D                 # the wrist computer mount (own bake: it slides around the forearm)
var _wrist_xf0 := Transform3D()         # its rest transform in the hand frame
var _wgeom: Array = []                  # wrist_geom()
var _ln_cur := Vector3.UP               # screen normal with the current slide (hand frame)
var _wf_item = null                     # item the cached solution belongs to (null: none / off)
var _wf_ref := Transform3D()            # grip pose (camera space) of the last search
var _wf_cool := 0.0                     # s until the next re-search may run
var _wf_roll_t := 0.0                   # target roll / slide (rad)
var _wf_slide_t := 0.0
var _wf_roll := 0.0                     # shown (sprung toward the targets)
var _wf_slide := 0.0
var _wf_slide_shown := 0.0              # slide last written to the mount
var _wf_slides := {}                    # item -> its searched slide (the strap stays put per item)
var _ha_comp := 1.0                     # share of the slide a hand action's pose follows (_left_pose comp)
# Gloves (scripts/player/vm_hand.gd): jointed fingers whose grip on each item is solved against the
# item's own geometry once (worker thread) and cached by item node.
var right_arm: Node3D                   # the right sleeve + glove (offset per item: grip_right frame)
var _glove_r := {}
var _glove_l := {}
var _prims := {}                        # item -> its build_model() bake record (vm_parts.gd bake_log)
var _grips := {}                        # item -> {"r", "rp" (trigger pulled), "l", "loff", "rf", "roll"}
var _grip_jobs := {}                    # item -> [task id, job Dictionary]
var _grip_redo := {}                    # item -> true: its model changed while a solve ran (refresh_grip)
var _hand_job := []                     # [task id, job]: grenade / shell / bolt poses
var _hand_poses := {}                   # "grenade", "shell", "bolt" -> pose
var _pose_r := PackedFloat32Array()     # shown finger poses (they follow the targets fast)
var _pose_l := PackedFloat32Array()
var _trig := 0.0                        # trigger squeeze 0..1
var _ui_hide := false                   # match over / paused / a UI panel: no arms or item
var _last_loff := Vector3.ZERO          # palm offset of the last left grip (hand frame)


func setup(p, items: Array) -> void:
	player = p
	right_rig = VM.node(self)
	right_hand = VM.node(right_rig)
	# The arm and glove hang under right_arm: an item whose pistol grip is not VM.grip's shifts the
	# arm to it (grip_right frame), never the gun (its sights stay on the camera axis).
	right_arm = VM.node(right_hand)
	_build_arm(right_arm, 1.0)
	VM.bake(right_arm)
	_glove_r = VMHand.build(right_arm, 1.0)
	left_rig = VM.node(self)
	left_hand = VM.node(left_rig)
	_build_arm(left_hand, -1.0)
	_build_wrist_computer(left_hand)
	VM.bake(left_hand, [_wrist_root])
	VM.bake(_wrist_root)
	_glove_l = VMHand.build(left_hand, -1.0)        # after the bakes: its joints must stay free
	_pose_r = VMHand.pose_of(VMHand.REST)
	_pose_l = VMHand.pose_of(VMHand.REST)
	_queue_hand_poses()
	if p.has_signal("hit_reacted"):
		p.hit_reacted.connect(_on_hit_reacted)
	for it in items:
		_register(it)
	melee = Melee.new()
	melee.name = "Melee"
	melee.player = p
	add_child(melee)
	_apply(0.0)
	_prewarm_thumbs.call_deferred()


## Every gun's thumbnail (quickbar, Silahlık cards: scripts/war/build_preview.gd renders each from a
## freshly built model, ~40-100 ms of CPU a gun) is queued here, at spawn while the world still
## builds, instead of all at once when a loadout change asks for them: Game.unlock_all_weapons()
## made the next ~0.5 s run at 10-20 fps (7 guns, one every 3 frames). Cached for the whole run, so
## a respawn or a later match queues nothing.
func _prewarm_thumbs() -> void:
	if not is_inside_tree():
		return
	var craft = load("res://scripts/war/craft.gd")
	var bp = load("res://scripts/war/build_preview.gd")
	if craft == null or bp == null:
		return
	var entries: Array = []
	for r in craft.recipes():
		if r is Dictionary and (r as Dictionary).has("item_script"):
			entries.append({"id": str(r.get("thumb_id", "craft_" + str(r.get("id", "")))), "item_script": r["item_script"]})
	if not entries.is_empty():
		bp.request_thumbs(get_tree(), entries)


## Registers an item added after setup (research-gated weapons): builds its hidden model.
func add_item(it) -> void:
	if _models.has(it):
		return
	_register(it)


## Builds an item's model (hidden, recording its primitives for the glove fingers), places its
## left_grip on the handle its grip_left descriptor names and queues its grip solve.
func _register(it) -> void:
	VM.bake_log = []
	var m: Node3D = it.build_model()
	_prims[it] = VM.bake_log
	VM.bake_log = null
	m.visible = false
	right_hand.add_child(m)
	_models[it] = m
	var ld := _grip_desc(it, "left")
	if it.left_grip != null and ld.has("at"):
		it.left_grip.transform = VMHand.frame_of(ld, -1.0)
	_queue_grip(it)


func remove_item(it) -> void:
	if not _models.has(it):
		return
	if _grip_jobs.has(it):
		WorkerThreadPool.wait_for_task_completion(int(_grip_jobs[it][0]))
		_grip_jobs.erase(it)
	(_models[it] as Node3D).queue_free()
	_models.erase(it)
	_prims.erase(it)
	_grips.erase(it)
	_grip_redo.erase(it)
	_wf_slides.erase(it)
	if _wf_item == it:
		_wf_item = null
	if _current == it:
		_current = null
	if _pending == it:
		_pending = null


## Starts the lower → switch → raise animation. on_mid is called when the arm is fully down.
func swap_to(item, on_mid: Callable) -> void:
	_pending = item
	_on_mid = on_mid
	# (The same item again: raised after a get-up / respawn, nothing was put away.)
	if _current != null and item != _current and _swap_dir != 1 and _swap < 0.9 and _t > 0.5:
		_swap_foley("holster", _current)
	_tool_insp.cancel()
	if _current == null and _swap >= 1.0:
		_swap_dir = 1  # already lowered: switch immediately on next frame
	elif _swap_dir != 1:
		_swap_dir = 1


## Usable a moment before the raise fully settles (the smoothstep tail is slow and reads as lag).
func is_raised() -> bool:
	return (_swap_dir == 0 and _swap <= 0.0) or (_swap_dir == -1 and _swap <= 0.12)


func add_look(rel: Vector2) -> void:
	_look += rel


## Aiming is eased out: the muzzle is close to a wall (the target, so it starts at once) or a melee
## swing runs.
func blocks_ads() -> bool:
	return wall_target > Balance.WALL_ADS_BLOCK or wall > Balance.WALL_ADS_BLOCK + 0.1 or melee_busy()


## No firing: the gun is (almost) fully pulled back from a wall, or a melee swing runs.
func blocks_fire() -> bool:
	return wall > Balance.WALL_FIRE_BLOCK or melee_busy()


func melee_busy() -> bool:
	return melee != null and melee.busy()


# =================================================================================================
# Gloves: grip descriptors, the solves, finger poses
# =================================================================================================

## An item's grip descriptor ("left" / "right"): its own grip_left / grip_right, else
## VMHand.GRIPS[item_id], else {} (defaults: see scripts/player/vm_hand.gd).
func _grip_desc(it, hand: String) -> Dictionary:
	var own = it.get("grip_" + hand)
	if own is Dictionary:
		return own
	var t: Dictionary = VMHand.GRIPS.get(str(it.get("item_id")), {})
	return t.get(hand, {})


## Transform of node n in the space of its ancestor `root`.
static func _rel(n: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D()
	while n != null and n != root:
		xf = n.transform * xf
		n = n.get_parent() as Node3D
	return xf


## An item's model changed (an attachment fitted or removed, scripts/items/attachments.gd: parts shown
## / hidden, a foregrip's grip_left descriptor): its left_grip goes to the handle the descriptor names
## now and both hands are solved again against the visible parts (hidden ones are skipped by
## VMHand.shapes_of). The old grip stays shown until the new solve lands; the wrist strap is searched
## again for the new hold.
func refresh_grip(it) -> void:
	if not _models.has(it):
		return
	var ld := _grip_desc(it, "left")
	if it.left_grip != null and ld.has("at"):
		it.left_grip.transform = VMHand.frame_of(ld, -1.0)
	_wf_slides.erase(it)
	if _wf_item == it:
		_wf_item = null
	if _grip_jobs.has(it):
		_grip_redo[it] = true
		return
	_queue_grip(it, true)


## Gathers what an item's grip solve needs (its own shapes in each hand frame, from the primitives
## its model baked) and solves it on a worker thread; _poll_jobs() collects it. force: solve again
## although a grip is cached (refresh_grip).
func _queue_grip(it, force := false) -> void:
	if (_grips.has(it) and not force) or _grip_jobs.has(it) or not _models.has(it):
		return
	var m: Node3D = _models[it]
	var log: Array = _prims.get(it, [])
	var rd := _grip_desc(it, "right")
	var rf := VMHand.right_frame(rd)
	var job := {"rf": rf, "sr": VMHand.shapes_of(log, m, rf.affine_inverse()),
			"spec_r": VMHand.right_spec(rd, rf), "spec_rp": VMHand.right_spec(rd, rf, true)}
	if it.left_grip != null:
		var ld := _grip_desc(it, "left")
		var off := VMHand.palm_offset(-1.0, float(ld.get("r", VMHand.R_DEFAULT)))
		var hf := _rel(it.left_grip, m) * Transform3D(Basis(), off)
		job["sl"] = VMHand.shapes_of(log, m, hf.affine_inverse())
		job["spec_l"] = {"spread": ld.get("spread", [])}
		job["loff"] = off
		# The wrist-screen roll turns the hand about the handle: a little on a vertical grip, none on
		# a handguard / pump (the screen strap slides instead): the grip stays exactly as solved.
		job["roll"] = float(ld.get("roll", 0.12 if absf(hf.basis.y.y) > 0.7 else 0.0))
	# A part the left hand holds during a reload (item.left_hold: a grip descriptor in that part's own
	# space + "root", its bake root; scripts/items/reload_anim.gd): the fingers wrap its real shapes.
	var hd = it.get("left_hold")
	if hd is Dictionary and (hd as Dictionary).get("root") is Node3D and (hd as Dictionary).has("at"):
		var hfr := VMHand.hold_frame(hd)
		job["sh"] = VMHand.shapes_under(log, hd["root"], hfr.affine_inverse())
		job["spec_h"] = {"spread": (hd as Dictionary).get("spread", [])}
	_grip_jobs[it] = [WorkerThreadPool.add_task(_solve_job.bind(job), false, "grip_solve"), job]


static func _solve_job(job: Dictionary) -> void:
	var r := VMHand.solve(1.0, job["sr"], job["spec_r"])
	job["r"] = r
	job["rp"] = VMHand.with_trigger(r, 1.0, job["sr"], job["spec_rp"])
	if job.has("sl"):
		job["l"] = VMHand.solve(-1.0, job["sl"], job["spec_l"])
	if job.has("sh") and not (job["sh"] as Array).is_empty():
		job["hold"] = VMHand.solve(-1.0, job["sh"], job.get("spec_h", {}))


## The left fist's grenade, the shotgun shell and the sniper's bolt knob (worker thread, once).
func _queue_hand_poses() -> void:
	var job := {}
	_hand_job = [WorkerThreadPool.add_task(_hand_job_run.bind(job), false, "hand_poses"), job]


static func _hand_job_run(job: Dictionary) -> void:
	job["grenade"] = VMHand.solve(-1.0, [VMHand.ell_shape(GRENADE_AT, GRENADE_R)], {})
	job["shell"] = VMHand.solve(-1.0, [VMHand.cap_shape(SHELL_A, SHELL_B, 0.0108)], {})
	job["bolt"] = VMHand.solve(1.0, [VMHand.sphere_shape(BOLT_KNOB, 0.0118)], {})


func _poll_jobs() -> void:
	for it in _grip_jobs.keys():
		var e: Array = _grip_jobs[it]
		if not WorkerThreadPool.is_task_completed(int(e[0])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(e[0]))
		var job: Dictionary = e[1]
		_grips[it] = {"r": job.get("r"), "rp": job.get("rp"), "l": job.get("l"), "loff": job.get("loff", Vector3.ZERO),
				"rf": job["rf"], "roll": float(job.get("roll", WF_ROLL_MAX)), "hold": job.get("hold")}
		_grip_jobs.erase(it)
		if it == _current:
			right_arm.transform = job["rf"]
		if _grip_redo.has(it):
			_grip_redo.erase(it)
			_queue_grip(it, true)
	if not _hand_job.is_empty() and WorkerThreadPool.is_task_completed(int(_hand_job[0])):
		WorkerThreadPool.wait_for_task_completion(int(_hand_job[0]))
		_hand_poses = _hand_job[1]
		_hand_job = []


func _exit_tree() -> void:
	for it in _grip_jobs:
		WorkerThreadPool.wait_for_task_completion(int(_grip_jobs[it][0]))
	_grip_jobs.clear()
	if not _hand_job.is_empty():
		WorkerThreadPool.wait_for_task_completion(int(_hand_job[0]))
		_hand_job = []


## Left palm offset of an item's grip (hand frame, after the wrist roll).
func _left_off(it) -> Vector3:
	var g: Dictionary = _grips.get(it, {})
	if g.has("loff"):
		return g["loff"]
	return VMHand.palm_offset(-1.0, float(_grip_desc(it, "left").get("r", VMHand.R_DEFAULT)))


## Finger poses: the right hand on the item's solved grip (the trigger squeezes while firing, the
## sniper's bolt hand closes on the knob), the left on its grip or off it (a reload reach holds the
## magazine / shell, a grenade or the wrist scan, relaxed at rest). gk: how far the left rig is on its
## grip; reach_w: the reload / inspect reach. They follow their targets fast (no pops).
func _update_fingers(it, delta: float, gk: float, reach_w: float, ha) -> void:
	var g: Dictionary = _grips.get(it, {}) if it != null else {}
	var rest := VMHand.pose_of(VMHand.REST)
	var tr := rest
	if it != null and _models.has(it) and (_models[it] as Node3D).visible:
		var base: PackedFloat32Array = g["r"] if g.get("r") is PackedFloat32Array else VMHand.pose_of(GRIP_R0)
		var pulled: PackedFloat32Array = g["rp"] if g.get("rp") is PackedFloat32Array else base
		var want: bool = it.using or (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_action_pressed("tool_use") \
				and is_raised() and not Game.ui_panel_open())
		_trig = move_toward(_trig, 1.0 if want else 0.0, delta / (0.05 if want else 0.09))
		tr = VMHand.lerp_pose(base, pulled, _trig)
		var hw = it.get("_hand_w")
		if hw != null and float(hw) > 0.001 and _hand_poses.get("bolt") is PackedFloat32Array:
			tr = VMHand.lerp_pose(tr, _hand_poses["bolt"], clampf(float(hw), 0.0, 1.0))
	var tl := rest
	if gk > 0.0 and it != null:
		var lg: PackedFloat32Array = g["l"] if g.get("l") is PackedFloat32Array else VMHand.pose_of(GRIP_L0)
		tl = VMHand.lerp_pose(rest, lg, gk)
	if reach_w > 0.001 and it != null:
		var hold := VMHand.pose_of(VMHand.CUP)
		# Open early on the way off the grip, close late on the way back onto it.
		var rw := 1.0 - (1.0 - reach_w) * (1.0 - reach_w)
		var lf = it.get("left_fingers")
		if lf is Dictionary and not (lf as Dictionary).is_empty():
			hold = _left_finger_mix(g, lf)       # the item's own channels (reload_anim.gd), its grip included
			rw = reach_w
		elif str(it.get("item_id")) == "shotgun" and _hand_poses.get("shell") is PackedFloat32Array:
			hold = _hand_poses["shell"]
		tl = VMHand.lerp_pose(tl, hold, rw)
	if ha != null:
		var hw2 := clampf(float(ha.left_w), 0.0, 1.0)
		if hw2 > 0.001:
			var hp := VMHand.pose_of(VMHand.LOOSE_FIST)
			if str(ha.get("state")) == "grenade" and _hand_poses.get("grenade") is PackedFloat32Array:
				hp = _hand_poses["grenade"]
			tl = VMHand.lerp_pose(tl, hp, hw2)
	var mt = player.get("mantle")           # a ledge climb: the left fingers hook over / lie on the edge
	if mt != null and float(mt.vm_left_w) > 0.001:
		tl = VMHand.lerp_pose(tl, mt.vm_left_pose(), clampf(float(mt.vm_left_w), 0.0, 1.0))
	if _swim > 0.01:
		tr = VMHand.lerp_pose(tr, rest, _swim)
		tl = VMHand.lerp_pose(tl, rest, _swim)
	var k := 1.0 - exp(-28.0 * delta) if delta > 0.0 else 1.0
	_pose_r = VMHand.lerp_pose(_pose_r, tr, k)
	_pose_l = VMHand.lerp_pose(_pose_l, tl, k)
	VMHand.apply(_glove_r, _pose_r)
	VMHand.apply(_glove_l, _pose_l)


## Left finger pose from an item's channel weights (item.left_fingers, scripts/items/reload_anim.gd):
## grip (its solved grip), relaxed, wrap_mag (its solved left_hold, else a cup), open_palm, fist,
## shell (the shotgun shell pinch), normalized; thumb_press (0..1) then turns the thumb into a press.
func _left_finger_mix(g: Dictionary, lf: Dictionary) -> PackedFloat32Array:
	var acc := PackedFloat32Array()
	acc.resize(VMHand.N * 4)
	var ws := 0.0
	for ch: String in ["grip", "relaxed", "wrap_mag", "open_palm", "fist", "shell"]:
		var w := maxf(float(lf.get(ch, 0.0)), 0.0)
		if w <= 0.0:
			continue
		var p: PackedFloat32Array
		match ch:
			"grip":
				p = g["l"] if g.get("l") is PackedFloat32Array else VMHand.pose_of(GRIP_L0)
			"relaxed":
				p = VMHand.pose_of(VMHand.REST)
			"wrap_mag":
				p = g["hold"] if g.get("hold") is PackedFloat32Array else VMHand.pose_of(VMHand.CUP)
			"open_palm":
				p = VMHand.pose_of(VMHand.OPEN_PALM)
			"fist":
				p = VMHand.pose_of(VMHand.LOOSE_FIST)
			_:
				p = _hand_poses["shell"] if _hand_poses.get("shell") is PackedFloat32Array else VMHand.pose_of(VMHand.CUP)
		for k in acc.size():
			acc[k] += p[k] * w
		ws += w
	if ws < 1e-4:
		return VMHand.pose_of(VMHand.REST)
	for k in acc.size():
		acc[k] /= ws
	var th := clampf(float(lf.get("thumb_press", 0.0)), 0.0, 1.0)
	if th > 0.0:
		for k in 4:
			acc[16 + k] = lerpf(acc[16 + k], float(VMHand.THUMB_PRESS[k]), th)
	return acc


## Arms and item hidden: the match is over (the end screen), the game is paused or a UI panel is up
## (pause menu, crafting / armory). Guarded so it works whatever the war / UI code provides.
func _ui_hidden() -> bool:
	if get_tree() != null and get_tree().paused:
		return true
	if "match_over" in Game and bool(Game.get("match_over")):
		return true
	return Game.has_method("ui_panel_open") and Game.ui_panel_open()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED and right_rig != null:
		right_rig.visible = false
		left_rig.visible = false


## Draw / holster foley of a swap: cloth plus a metal touch, heavier for heavier items.
func _swap_foley(set_name: String, it) -> void:
	if Game.sfx == null or not is_instance_valid(Game.sfx):
		return
	var sp := Handling.spec(it)
	if str(sp["kind"]) == "none":
		return
	var w := float(sp["weight"])
	Game.sfx.play(set_name, (-18.0 if set_name == "draw" else -20.0) + w * 3.0, lerpf(1.06, 0.88, w))
	if set_name == "draw" and str(sp["kind"]) == "launcher":
		Game.sfx.play_later("clunk", 0.24, -20.0, 0.95)


## Wall probe (rays along the view, scripts/items/handling.gd) and the drill / build tool inspect
## input (Y; guns handle their own).
func _physics_process(_delta: float) -> void:
	if player == null:
		return
	var it = _current
	var on_foot: bool = player.vehicle == null and not player.is_ragdolled() and not player.is_dead()
	wall_target = Handling.probe_wall(player, it) if it != null and on_foot and _swap < 0.5 else 0.0
	if it != null and it.get("pose_override") == null:
		if it.using:
			wall_target *= 0.35          # the drill / build tool at work: the nozzle stays out
		var real: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not Game.ui_panel_open()
		_tool_insp.hold = real and Handling.held("inspect")
		if real and Handling.just_pressed("inspect") and not _tool_insp.busy() and it.equipped and on_foot \
				and is_raised() and not it.using and not melee_busy() and wall_target < 0.2 and not player.hands_busy():
			_tool_insp.start("tool")
		if _tool_insp.busy() and (it.using or not it.equipped or not on_foot or melee_busy() or wall_target > 0.3 \
				or player.hands_busy() or _sprint > 0.4 or (real and (Handling.held("tool_use") or Handling.held("tool_alt")))):
			_tool_insp.cancel()
	elif _tool_insp.active():
		_tool_insp.cancel()


## Gauntlet, cuff and sleeve running from the wrist back toward the (off-screen) elbow.
func _build_arm(h: Node3D, side: float) -> void:
	var s := side
	var w := Vector3(0.026 * s, -0.07, 0.05)
	var dir := Vector3(0.4 * s, -0.32, 0.86).normalized()
	var g := VM.glove_skin(false, Color(VMHand.C_FABRIC, 1.0), 0)
	var white := VM.suit_white()
	var orange := VM.suit_orange()
	var gray := VM.suit_gray()
	var steel := VM.metal()
	# Glove gauntlet flaring into the cuff (the glove's knit fabric), a stitched seam and an orange
	# band hugging it (a flush band, not a loose ring), tucked into the metal wrist bearing.
	VM.seg(h, w - dir * 0.02, w + dir * 0.078, 0.032, 0.0515, g)
	VM.seg(h, w + dir * 0.012, w + dir * 0.016, 0.0392, 0.04, VM.glove_skin(false, Color(VMHand.C_SEAM, 1.0), 0))
	VM.seg(h, w + dir * 0.055, w + dir * 0.068, 0.0481, 0.0507, orange)
	# Metal wrist bearing with a dark groove.
	VM.seg(h, w + dir * 0.072, w + dir * 0.098, 0.054, 0.054, steel)
	VM.seg(h, w + dir * 0.083, w + dir * 0.088, 0.0551, 0.0551, VM.dark_metal())
	# Sleeve with accordion joints and an orange band.
	VM.seg(h, w + dir * 0.098, w + dir * 0.6, 0.056, 0.074, white, 22)
	for d in [0.125, 0.148, 0.171]:
		VM.ring(h, w + dir * d, dir, 0.06 + d * 0.02, 0.012, gray)
	VM.seg(h, w + dir * 0.26, w + dir * 0.305, 0.067, 0.069, orange, 22)
	VM.ring(h, w + dir * 0.26, dir, 0.069, 0.004, VM.dark_metal())
	VM.ring(h, w + dir * 0.305, dir, 0.0705, 0.004, VM.dark_metal())
	for d in [0.42, 0.45, 0.48]:
		VM.ring(h, w + dir * d, dir, 0.074 + d * 0.01, 0.013, gray)
	# Small control pad / pocket on top of the forearm.
	var up := (Vector3.UP - dir * dir.dot(Vector3.UP)).normalized()
	var across := dir.cross(up).normalized()
	var b := Basis(across, up, dir)
	if side > 0.0:
		var pc := w + dir * 0.21 + up * 0.058 - across * 0.012
		VM.soft_box(h, pc, Vector3(0.045, 0.014, 0.06), 0.005, gray, b)
		var led := VM.glow(Color(0.3, 1.0, 0.5), 3.0)
		for i in 3:
			VM.box(h, pc + b * Vector3(-0.012 + i * 0.012, 0.008, -0.016), Vector3(0.007, 0.003, 0.007),
					led if i == 0 else VM.glow(Color(1.0, 0.55, 0.15), 2.0 + i), b)


## Wrist computer on the left forearm (scripts/player/wrist_display.gd: health on top, jetpack fuel,
## material, gravity, lamp, scanner, held item). Its mount `_wrist_root` is baked on its own so it
## can slide around the forearm (wrist_face_search); the frame comes from wrist_geom().
func _build_wrist_computer(h: Node3D) -> void:
	_wgeom = wrist_geom()
	var w: Vector3 = _wgeom[0]
	var dir: Vector3 = _wgeom[1]
	var up: Vector3 = _wgeom[2]          # screen normal: turned about the forearm toward the view centre
	var across := up.cross(dir).normalized()
	var b := Basis(across, up, dir)
	var c: Vector3 = _wgeom[3]
	_lw_h = w
	_ldir_h = dir
	_ln_h = up
	_ln_cur = up
	_lscreen_h = c
	var root := VM.node(h, c, b)
	_wrist_root = root
	_wrist_xf0 = root.transform
	var dark := VM.mat(Color(0.12, 0.13, 0.15), 0.4, 0.5)
	VM.soft_box(root, Vector3.ZERO, Vector3(0.082, 0.024, 0.104), 0.008, dark)
	VM.box(root, Vector3(0, -0.012, 0), Vector3(0.092, 0.01, 0.05), VM.suit_orange())
	VM.box(root, Vector3(0, 0.0125, 0), Vector3(0.07, 0.002, 0.09), VM.mat(Color(0.01, 0.02, 0.03), 0.15, 0.1, 0.0, 0.6))
	# Screen: a SubViewport texture on a plane (local XZ, +Y faces the viewer, -Z toward the hand).
	_wrist_vp = SubViewport.new()
	_wrist_vp.size = Vector2i(256, 312)
	_wrist_vp.transparent_bg = false
	_wrist_vp.disable_3d = true
	_wrist_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_wrist_vp)
	_wrist_ui = WristDisplay.new()
	_wrist_ui.size = Vector2(256, 312)
	_wrist_vp.add_child(_wrist_ui)
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.068, 0.083)
	var scr := VM.mesh_inst(root, pm, VM.screen_mat(_wrist_vp.get_texture(), 1.5))
	scr.position = Vector3(0, 0.0138, 0)


func _process(delta: float) -> void:
	if player == null:
		return
	_t += delta
	_poll_jobs()
	_update_swap(delta)
	_apply(delta)
	# Nothing carried ("Boş eller"): no arms in view, unless a hand action (grenade, medkit) uses them.
	# None either over the end screen, a pause or a UI panel.
	var empty: bool = _current != null and str(_current.get("item_id")) == "hands"
	var busy: bool = player.has_method("hands_busy") and player.hands_busy()
	_ui_hide = _ui_hidden()
	var show_arms := (not empty or busy) and not _ui_hide
	if right_rig != null and right_rig.visible != show_arms:
		right_rig.visible = show_arms
		left_rig.visible = show_arms
	# Any drop in health flashes the wrist screen and shows the new value at once.
	var hp := float(player.hp)
	if hp < _wrist_hp - 0.01:
		_wrist_ui.flash_hit()
		_wrist_timer = 0.0
	_wrist_hp = hp
	_wrist_timer -= delta
	if _wrist_timer <= 0.0:
		_wrist_timer = 0.2
		_update_wrist()


func _update_swap(delta: float) -> void:
	if _swap_dir == 1:
		# Items may set holster_time / draw_time (e.g. a rifle takes longer than a hand tool).
		var lt: float = LOWER_TIME
		if _current != null and _current.get("holster_time") != null:
			lt = float(_current.get("holster_time"))
		lt *= 0.6        # swaps were 0.9-1.5 s in total; putting away is the part nobody wants to watch
		_swap = minf(_swap + delta / maxf(lt, 0.01), 1.0)
		if _swap >= 1.0:
			if _current != null and _models.has(_current):
				_models[_current].visible = false
			_current = _pending
			_pending = null
			if _current != null and _models.has(_current):
				_models[_current].visible = true
				_queue_grip(_current)
				right_arm.transform = (_grips[_current] as Dictionary).get("rf", Transform3D()) if _grips.has(_current) else Transform3D()
			if _current != null and _t > 0.5:
				_swap_foley("draw", _current)
			if _on_mid.is_valid():
				_on_mid.call()
			_swap_dir = -1
	elif _swap_dir == -1:
		var rt: float = RAISE_TIME
		if _current != null and _current.get("draw_time") != null:
			rt = float(_current.get("draw_time"))
		rt *= 0.75
		_swap = maxf(_swap - delta / maxf(rt, 0.01), 0.0)
		if _swap <= 0.0:
			_swap_dir = 0


func _apply(delta: float) -> void:
	var p = player
	var vel: Vector3 = p.velocity
	var up: Vector3 = p.global_transform.basis.y
	var v_up := vel.dot(up)
	var h_speed := (vel - up * v_up).length()
	var grounded: bool = p.is_on_floor() and not p.zero_g
	var rate := 1.0 - exp(-10.0 * delta)

	# Movement layer (gun_feel.gd Carry + Motion, the same as the guns'): the drill / build tool's
	# two-handed run carry and stride sway, the walk bob on the gait clock, breathing, look sway (heavy
	# items lag more: sway_scale), the jump lift, the landing dip and the crouch / slide cant. It runs
	# for every item (the idle left arm follows it), the guns pose themselves the same way.
	var it = _current
	var inertia := 1.0
	if it != null and it.get("sway_scale") != null:
		inertia = clampf(float(it.get("sway_scale")), 0.2, 3.0)
	var lk := _look * (1.0 / 60.0) / maxf(delta, 0.001)      # per-frame mouse counts → 60 fps units
	_look = Vector2.ZERO
	var sk = p.get("_sprint_k")
	var sprinting: bool = grounded and h_speed > 6.0 and (float(sk) > 0.5 if sk != null else Input.is_action_pressed("sprint"))
	var style := GunFeel.sprint_style(it) if it != null else {}
	var mv := _carry.update(p, delta, sprinting, 0.0, lk, inertia * 0.85, style)
	var mo := _motion.update(p, delta, 0.0)
	_sprint = clampf(_carry.sprint, 0.0, 1.0)
	_sway = _carry.sway
	_bob_phase = _carry.ph
	_bob_amt = _carry.walk

	# Tool use: steady shake + pushback. Kick: spring impulse (scan pulse, mode switch, beacon).
	var using: bool = it != null and it.using
	_use = lerpf(_use, 1.0 if using else 0.0, rate)
	if it != null and it.kick > 0.0:
		_kick_vel += it.kick * 9.0
		it.kick = 0.0
	_kick_vel += (-_kick * 220.0 - _kick_vel * 22.0) * delta
	_kick += _kick_vel * delta
	_jitter = _jitter.lerp(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)), rate * 2.0)


	var zero_g_drift := Vector3(sin(_t * 0.6), sin(_t * 0.83), 0.0) * (0.006 if p.zero_g else 0.0)
	var common := mv.origin + zero_g_drift        # the idle left arm rides the same motion

	# Swap curve: ease in/out.
	var e := _swap * _swap * (3.0 - 2.0 * _swap)
	if it != null:
		_hold = _hold.lerp(it.hold_offset, 1.0 - exp(-12.0 * delta)) if _swap < 0.999 else it.hold_offset
	# Run carry (offsets from the rest hold): the item's style, else the tools' low two-handed carry.
	var run: Dictionary = style if style.has("pos") and it.get("pose_override") == null else GunFeel.SPRINT_STYLE["tool"]
	var se := _sprint * _sprint * (3.0 - 2.0 * _sprint)
	var rp := RIGHT_POS + zero_g_drift + _hold
	rp += (run["pos"] as Vector3) * se
	rp += Vector3(0.0, -0.26, 0.06) * e
	var buzz := Vector3(sin(_t * 71.0), sin(_t * 63.0 + 1.0), 0.0) * 0.0018 * _use
	rp += Vector3(0, 0, 0.014 * _use + _kick * 0.05) + _jitter * 0.0035 * _use + buzz
	var rr := RIGHT_ROT + (run["rot"] as Vector3) * se
	rr += Vector3(-0.95, 0.15, 0.25) * e
	rr += Vector3(_kick * 0.6 + _use * 0.03, 0, 0) + _jitter * 0.02 * _use
	# Swimming: breaststroke — the tool hand reaches forward and sweeps out.
	var swimming: bool = p.get("swimming") == true
	_swim = lerpf(_swim, 1.0 if swimming else 0.0, rate * 0.4)
	_swim_ph += delta * (1.5 + vel.length() * 0.9)
	if _swim > 0.01:
		var sw := _swim_ph
		rp += Vector3(0.06 * maxf(0.0, cos(sw)), -0.06 + 0.03 * sin(sw), -0.1 * sin(sw)) * _swim
		rr += Vector3(0.25 * sin(sw) - 0.2, -0.35 * maxf(0.0, cos(sw)), 0.2) * _swim
	right_rig.transform = GunFeel.apply_motion(GunFeel.apply_motion(Transform3D(Basis.from_euler(rr), rp), mv), mo)
	# Items may move the whole hand+item rig (e.g. a rifle raised to the sights) so the hand
	# stays locked on the grip instead of the item sliding out of the hand.
	if it != null and it.get("rig_offset") is Transform3D:
		right_rig.transform = right_rig.transform * (it.get("rig_offset") as Transform3D)
	# Items with their own full pose (camera space: hip / aim / sprint / reload / recoil / bob /
	# sway all computed by the item) only get the swap lowering from here.
	if it != null and it.get("pose_override") is Transform3D and _swim < 0.01:
		var po: Transform3D = it.get("pose_override")
		var lower := Basis.from_euler(Vector3(-0.95, 0.15, 0.25) * e)
		right_rig.transform = Transform3D(lower * po.basis, po.origin + Vector3(0.0, -0.26, 0.06) * e)
	_handling(it, delta)

	# Left arm: solve the rig from camera-space targets (wrist position, forearm direction and
	# the wrist screen facing the eye), so the pose is easy to tune and always readable.
	# Items with a second handle (left_grip) get a two-handed hold; otherwise the left arm rests
	# low, out of the way.
	var lcommon := Vector3(-common.x, common.y * 0.9, 0) + Vector3(0, -0.03 * e, 0) + Vector3(0, -0.04, 0.02) * _sprint
	var has_grip: bool = it != null and it.left_grip != null and _models.has(it) and _models[it].visible
	var grip_h := Transform3D()                 # the left grip in the right hand frame
	if has_grip:
		grip_h = right_hand.global_transform.affine_inverse() * it.left_grip.global_transform
		_last_grip_xf = right_rig.transform * grip_h
		_last_loff = _left_off(it)
	# On the grip, the left rig turns about the fist axis so the wrist screen faces the eye (and the
	# mount may sit slid around the forearm): wrist_face_search. Updates _ln_cur for _left_pose.
	var wroll := _wrist_face(it, has_grip, grip_h, e, delta)
	var idle_xf := _left_pose(LEFT_WRIST + lcommon, LEFT_ELBOW_DIR, 0.25)
	_lgrip = move_toward(_lgrip, 1.0 if has_grip else 0.0, delta * 4.0)
	var gk := _lgrip * _lgrip * (3.0 - 2.0 * _lgrip) * (1.0 - _swim)
	if _swim > 0.01:
		var sw2 := _swim_ph
		var swim_xf := _left_pose(Vector3(-0.2 - 0.07 * maxf(0.0, cos(sw2)), -0.2 + 0.03 * sin(sw2), -0.5 - 0.1 * sin(sw2)) + lcommon, Vector3(-0.35, -0.3, 0.88), 0.2)
		idle_xf = idle_xf.interpolate_with(swim_xf, _swim)
	var grip_xf := _last_grip_xf * Transform3D(Basis(Vector3.UP, wroll), Vector3.ZERO) if wroll != 0.0 else _last_grip_xf
	# The palm sits on the handle surface whatever its size (the roll turns the hand about the handle
	# axis, the offset follows it, so the fingers stay wrapped).
	grip_xf = grip_xf * Transform3D(Basis(), _last_loff)
	var lxf := idle_xf.interpolate_with(grip_xf, gk) if gk > 0.0 else idle_xf
	# Items can pull the left hand off its grip (e.g. a magazine change): left_reach is the
	# camera-space wrist target, left_reach_w the blend and left_reach_elbow the forearm direction.
	# Solving the pose from camera-space targets keeps the sleeve pointing out of view. The hand keeps
	# its authored roll there (comp 0: hand-held magazines / shells), even with a slid strap.
	var reach_w := 0.0
	if has_grip and it.get("left_reach_w") != null:
		var rw := clampf(float(it.get("left_reach_w")), 0.0, 1.0)
		reach_w = rw
		if rw > 0.001:
			var elbow: Vector3 = LEFT_ELBOW_DIR
			if it.get("left_reach_elbow") != null:
				elbow = it.get("left_reach_elbow")
			var reach_xf := _reach_pose(it, elbow, lcommon)
			lxf = lxf.interpolate_with(reach_xf, rw)
	# Hand actions (player.hand_action: grenade G, wrist scan Q) take the left arm and dip the held
	# item out of the way. The scan raises the screen as the strap sits (comp 1); the grenade keeps
	# the authored fist (comp 0). Between actions the weight holds, so nothing pops while the arm
	# lowers; it is set at once when an action starts from the rest.
	var ha = p.get("hand_action")
	if ha != null:
		var hw := clampf(float(ha.left_w), 0.0, 1.0)
		var hs := str(ha.get("state"))
		if hs == "scan" or hs == "grenade":
			var want := 1.0 if hs == "scan" else 0.0
			_ha_comp = want if hw < 0.05 else move_toward(_ha_comp, want, delta * 4.0)
		if hw > 0.001:
			lxf = lxf.interpolate_with(_left_pose(ha.left_target + lcommon * 0.5, ha.left_elbow, 0.3, _ha_comp), hw)
		var rl := clampf(float(ha.right_lower), 0.0, 1.0)
		if rl > 0.001:
			right_rig.transform = Transform3D(Basis.from_euler(Vector3(-0.5, 0.25, 0.15) * rl), Vector3(0.04, -0.11, 0.05) * rl) * right_rig.transform
	# A ledge climb (player.mantle, scripts/player/mantle.gd): the gloves plant on the edge, the item tucks.
	var mt = p.get("mantle")
	if mt != null and mt.vm_on():
		lxf = mt.vm_left(lxf)
		right_rig.transform = mt.vm_right(right_rig.transform, right_arm.transform)
	left_rig.transform = lxf
	_update_fingers(it, delta, gk, reach_w, ha)


## Weapon handling on the right-hand rig (camera space, about the grip): the sprung wall pull-back,
## the melee swing and the drill / build tool inspect (with its foley).
func _handling(it, delta: float) -> void:
	var dt := minf(delta, 0.033)
	_wall_v += ((wall_target - wall) * 160.0 - _wall_v * 22.0) * dt
	wall = clampf(wall + _wall_v * dt, -0.05, 1.05)
	var fired: Array = _tool_insp.update(delta)
	if it == null or _swim > 0.01:
		return
	var sp := Handling.spec(it)
	var kind := str(sp["kind"])
	var w := float(sp["weight"])
	for f: Array in fired:
		if Game.sfx != null:
			Game.sfx.play(str(f[0]), float(f[1]) + w * 2.0, float(f[2]))
	var hx := Handling.wall_xf(wall, kind, float(sp["wall"]))
	if melee_busy():
		hx = Handling.apply(hx, melee.pose_xf(kind))
	if _tool_insp.active():
		hx = Handling.apply(hx, _tool_insp.pose())
	if hx != Transform3D():
		right_rig.transform = Handling.apply(right_rig.transform, hx)


## The reload / inspect reach target of the left hand: the item's camera-space wrist point left_reach
## and forearm direction (the wrist screen turned to the eye), or what the item sets itself (optional,
## read with get(); scripts/items/reload_anim.gd): left_reach_space 1 = left_reach and
## left_reach_basis are in the item model's own frame (they follow the gun exactly as shown this frame,
## wall pull-back and swap included), left_reach_basis_w blends to its own hand orientation.
func _reach_pose(it, elbow: Vector3, lcommon: Vector3) -> Transform3D:
	var wc: Vector3 = it.get("left_reach")
	var sp := 0.0
	if it.get("left_reach_space") != null:
		sp = clampf(float(it.get("left_reach_space")), 0.0, 1.0)
	var gun := right_rig.transform * right_hand.transform
	if sp > 0.0:
		wc = wc.lerp(gun * wc, sp)
	wc += lcommon * 0.5 * (1.0 - sp)
	var xf := _left_pose(wc, elbow, 0.3, 0.0)
	var bw := 0.0
	if it.get("left_reach_basis_w") != null and it.get("left_reach_basis") is Basis:
		bw = clampf(float(it.get("left_reach_basis_w")), 0.0, 1.0)
	if bw > 0.001:
		var b: Basis = (it.get("left_reach_basis") as Basis).orthonormalized()
		if sp > 0.0:
			b = Basis(Quaternion(b).slerp(Quaternion((gun.basis * b).orthonormalized()), sp))
		xf = xf.interpolate_with(Transform3D(b, wc - b * _lw_h), bw)
	return xf


## Left rig transform from a camera-space wrist position and forearm direction, with the wrist
## screen turned toward the eye. comp 0..1: how much of the current strap slide (wrist_face_search)
## the pose follows. 1 turns the screen as it now sits around the forearm (_ln_cur) to the eye; 0
## turns the unslid normal, i.e. keeps the authored hand roll (reload reaches, a grenade in the fist).
## Both normals are ⊥ the forearm, so the partial one is the slide scaled: R(D, φ·comp)·N.
func _left_pose(wc: Vector3, elbow_dir: Vector3, up_bias: float, comp := 1.0) -> Transform3D:
	var dc := elbow_dir.normalized()
	dc = dc.rotated(Vector3.UP, -_sway.x * 0.6).rotated(Vector3.RIGHT, _sway.y * 0.5)
	var screen_c := wc + dc * 0.115
	var nc := (-screen_c).normalized().lerp(Vector3.UP, up_bias)
	nc = nc.rotated(dc, cos(_bob_phase) * 0.03 * _bob_amt)
	var nh := _ln_cur
	if comp < 0.999:
		nh = _ln_h if comp <= 0.001 else Basis(_ldir_h, _wf_slide_shown * comp) * _ln_h
	var bl := _map_basis(_ldir_h, nh, dc, nc)
	return Transform3D(bl, wc - bl * _lw_h)


## Keeps the wrist-facing roll / slide of the held item's left grip up to date (see the section
## "Wrist screen facing" below) and returns the roll to apply this frame (rad, about the fist axis).
## Item change: its slide (searched once at its rest pose, then cached per item) and a fresh roll.
## Same item: a roll-only re-search when its grip pose moved > 2.5 cm or ~7° since the last search
## (at most every 0.1 s; not during a melee swing or while the left hand is off the grip for a
## reload / hand action). The shown values follow on a spring, snapped while the arm is down in a
## swap. The roll fades to 65 % at full aim (the sight picture wins).
func _wrist_face(it, has_grip: bool, grip_h: Transform3D, e: float, delta: float) -> float:
	_wf_cool -= delta
	var on: bool = has_grip and it.get("wrist_face") != false
	var snap := false
	var ads := 0.0
	if on:
		if it.get("ads") != null:
			ads = clampf(float(it.get("ads")), 0.0, 1.0)
		# The right rig at rest: the live one once raised; while the swap still lowers it, the item's
		# own pose (pose_override) or the default hold, so a search never sees the lowered arm.
		var rig := right_rig.transform
		if e > 0.05:
			if it.get("pose_override") is Transform3D:
				rig = it.get("pose_override")
			else:
				rig = Transform3D(Basis.from_euler(RIGHT_ROT), RIGHT_POS + it.hold_offset)
		var grip := rig * grip_h
		var rl := WF_ROLL_MAX
		if it.get("wrist_roll_limit") != null:
			rl = clampf(float(it.get("wrist_roll_limit")), 0.0, PI)
		# The roll turns the hand about its handle: capped per grip (none until the grip is solved).
		rl = minf(rl, float((_grips.get(it, {}) as Dictionary).get("roll", 0.0)))
		var sl := PI
		if it.get("wrist_slide_limit") != null:
			sl = clampf(float(it.get("wrist_slide_limit")), 0.0, PI)
		if grip.origin.z > -0.15:
			pass                    # no pose yet (the item has not run a frame): search next frame
		elif it != _wf_item:
			if not _wf_slides.has(it):
				_wf_slides[it] = wrist_face_search(grip, rig, _wgeom, 0.0, 0.0, 0.0, true, rl, sl).y
			_wf_item = it
			_wf_slide_t = float(_wf_slides[it])
			_wf_roll_t = wrist_face_search(grip, rig, _wgeom, 0.0, _wf_slide_t, ads, false, rl, sl).x
			_wf_ref = grip
			_wf_cool = 0.1
			snap = e > 0.6 or _lgrip < 0.2
		elif _wf_cool <= 0.0 and not melee_busy() and not _left_hand_away(it) and _wf_moved(grip):
			_wf_roll_t = wrist_face_search(grip, rig, _wgeom, _wf_roll_t, _wf_slide_t, ads, false, rl, sl).x
			_wf_ref = grip
			_wf_cool = 0.1
	else:
		# No grip (one-handed item, empty hands) or the item keeps its authored hold: no roll, the
		# strap back on the outer wrist (snapped while the arm is down in a swap).
		if _wf_item != null:
			snap = e > 0.6
		_wf_item = null
		_wf_roll_t = 0.0
		_wf_slide_t = 0.0
	_wf_roll = _wf_roll_t if snap else lerpf(_wf_roll, _wf_roll_t, 1.0 - exp(-8.0 * delta))
	_wf_slide = _wf_slide_t if snap else lerpf(_wf_slide, _wf_slide_t, 1.0 - exp(-5.0 * delta))
	if absf(_wf_slide - _wf_slide_shown) > 0.0005 and _wrist_root != null:
		# Slide about the forearm line (W, D) of the hand frame: x → W + R(x − W).
		_wf_slide_shown = _wf_slide
		var r := Basis(_ldir_h, _wf_slide)
		_wrist_root.transform = Transform3D(r, _lw_h - r * _lw_h) * _wrist_xf0
		_ln_cur = r * _ln_h
	return _wf_roll * (1.0 - 0.35 * ads)


## The left hand is off its grip (a reload reach, a hand action, a ledge): no roll re-search then, it
## would swing the arm to suit the gun's reload pose just as the hand comes back.
func _left_hand_away(it) -> bool:
	if it.get("left_reach_w") != null and float(it.get("left_reach_w")) > 0.05:
		return true
	var mt = player.get("mantle")
	if mt != null and float(mt.vm_left_w) > 0.05:
		return true
	var ha = player.get("hand_action")
	return ha != null and float(ha.left_w) > 0.05


## The grip pose moved enough since the last search to search the roll again.
func _wf_moved(grip: Transform3D) -> bool:
	if grip.origin.distance_to(_wf_ref.origin) > 0.025:
		return true
	return (_wf_ref.basis.inverse() * grip.basis).get_rotation_quaternion().get_angle() > 0.12


## Hit reactions (scripts/player/hit_reactor.gd) flash the wrist screen too (the health drop is
## caught in _process as well).
func _on_hit_reacted(kind: String, _dir: Vector3, _strength: float, _bone: String) -> void:
	if kind != "getup" and _wrist_ui != null:
		_wrist_ui.flash_hit()


## Rotation that maps (dir_a, up_a) onto (dir_b, up_b) (ups are orthogonalized to the dirs).
static func _map_basis(dir_a: Vector3, up_a: Vector3, dir_b: Vector3, up_b: Vector3) -> Basis:
	var da := dir_a.normalized()
	var ua := (up_a - da * up_a.dot(da)).normalized()
	var db := dir_b.normalized()
	var ub := (up_b - db * up_b.dot(db)).normalized()
	var ba := Basis(da, ua, da.cross(ua))
	var bb := Basis(db, ub, db.cross(ub))
	return bb * ba.inverse()


# =================================================================================================
# Wrist screen facing on a two-handed grip
# =================================================================================================
## A left_grip fixes where the fist is, not how the arm turns around it, so the wrist computer could
## face the muzzle or show its edge. For every item with a left grip (current and future), two
## corrections turn the screen toward the eye. A small search finds them, they are cached, and the
## shown values follow on a spring:
##   roll  : the whole left rig turns about the fist axis (hand-local +Y through the grip point, i.e.
##           the foregrip / handguard / forend the fist wraps), so the glove stays on the grip and the
##           forearm swings around it. Applied as G' = G · R_y(θ) = (B·R_y(θ), o): for an orthonormal
##           B, B·R_y(θ) = R(B·ŷ, θ)·B, a rotation by θ about the camera-space fist axis B·ŷ through
##           the grip point o, which stays put. Searched again when the grip pose changes a lot
##           (aim, sprint, wall pull-back), not during a melee swing or while the hand is off the
##           grip (reload reach, grenade / scan).
##   slide : the wrist computer turns around the forearm, like a strap the player positioned to read
##           it. The mount rotates by φ about the hand-frame line (W, D):
##           x → W + R(D, φ)(x − W). One value per item, searched at its rest pose and kept while
##           aiming or sprinting, so the strap stays put. The search prefers the slide. The slide
##           range is ±50°. If even that can't make the screen readable (facing < WF_GOOD), the
##           range grows to ±180°: the screen is worn on the inner wrist, as soldiers wear watches to
##           read them on a rifle. This happens with a horizontal forend such as the pump's: the fist
##           axis runs down the barrel and the screen normal is 36° off it, so no roll can turn the
##           outer wrist toward the eye.
## The grip is a hard constraint: the roll turns the hand about its handle (the palm keeps its offset,
## the solved fingers stay wrapped), but it is capped to ±7° on vertical grips and 0 on handguards and
## pumps (their grips were solved against nearby rails / strips at roll 0), so the slide carries the
## screen and the hand never twists off the gun.
## Cost (wrist_face_cost, lower is better), camera space with the eye at the origin:
##   −n·ê                       n the screen normal, ê the unit vector from the screen centre to the eye
##   + forearm limits           d = wrist → elbow should go down, back toward the body, not across to
##                              the right: d.y ≤ −0.25, d.z ≥ 0.3, d.x ≤ 0.1 (hinges)
##   + hand over the gun        the back of the hand or the wrist rising > 2 cm above the grip point
##                              along the gun's up (toward the sight line)
##   + sleeve over the centre   forearm samples within ~18° of the crosshair (×3 while aiming)
##   + screen out of view, or behind the gun body (a capsule along the bore of the hand frame)
##   + text tilt                the text's top runs toward the hand: > 35° off upright costs
##   + 0.6·|θ| + 0.15·|φ|       prefer no change, the slide before the roll (beyond 50°: +0.1/rad,
##                              that pass only runs when ±50° cannot be read)
##   + 0.15·|θ − θ_now|         hysteresis on re-searches (no flip-flop between two near optima)
## Per-item overrides, read with get() (absent = automatic):
##   wrist_face := false        keep the authored hold
##   wrist_roll_limit (rad)     max |θ|; wrist_slide_limit (rad): max |φ|.
const WF_ROLL_MAX := 0.12                       # 7°: the grip is a hard constraint (handguards: 0)
const WF_SLIDE_MAX := 0.873                     # 50°: the strap slide
const WF_GOOD := 0.45                           # facing below this within ±50°: try the inner wrist
const WF_KNUCKLE := Vector3(-0.05, -0.025, 0.0) # back of the left hand (hand frame)


## Wrist computer frame in the left hand frame, slide 0: [wrist W, forearm D (wrist → elbow), screen
## normal N, screen centre C]. The screen sits 0.115 up the forearm and 0.058 off its axis, turned
## −0.55 rad about the forearm toward the view centre. N ⊥ D, so a slide keeps it on the sleeve.
static func wrist_geom() -> Array:
	var w := Vector3(-0.026, -0.07, 0.05)
	var dir := Vector3(-0.4, -0.32, 0.86).normalized()
	var up := (Vector3.UP - dir * dir.dot(Vector3.UP)).normalized()
	up = up.rotated(dir, -0.55).normalized()
	return [w, dir, up, w + dir * 0.115 + up * 0.058]


## Facing n·ê of the wrist screen (1 = square to the eye) for a left rig on `grip` (camera space)
## rolled by `roll` about the fist axis, with the mount slid by `slide` about the forearm.
static func wrist_face_dot(grip: Transform3D, g: Array, roll: float, slide: float) -> float:
	var w_h: Vector3 = g[0]
	var sb := Basis(g[1] as Vector3, slide)
	var b := grip.basis * Basis(Vector3.UP, roll)
	var n: Vector3 = b * (sb * (g[2] as Vector3))
	var c: Vector3 = grip.origin + b * (w_h + sb * ((g[3] as Vector3) - w_h))
	return n.dot(-c.normalized())


## Cost of a roll / slide (see the section header). grip: the left rig on the grip (camera space);
## gun: the right rig (gun frame: grip at the origin, -Z forward, +Y up); g: wrist_geom(); ads 0..1.
static func wrist_face_cost(grip: Transform3D, gun: Transform3D, g: Array, roll: float, slide: float, ads: float) -> float:
	var w_h: Vector3 = g[0]
	var d_h: Vector3 = g[1]
	var sb := Basis(d_h, slide)
	var b := grip.basis * Basis(Vector3.UP, roll)
	var o := grip.origin
	var w := o + b * w_h
	var d := b * d_h
	var n: Vector3 = b * (sb * (g[2] as Vector3))
	var c: Vector3 = o + b * (w_h + sb * ((g[3] as Vector3) - w_h))
	var cl := maxf(c.length(), 0.001)
	var cost := -n.dot(-c / cl)
	# Forearm: down, back toward the body, not across to the right.
	cost += 2.5 * maxf(0.0, d.y + 0.25) + 2.0 * maxf(0.0, 0.3 - d.z) + 1.5 * maxf(0.0, d.x - 0.1)
	# Back of the hand / wrist above the grip point along the gun's up.
	var gu := gun.basis.y.normalized()
	cost += 3.0 * maxf(0.0, maxf((b * WF_KNUCKLE).dot(gu), (b * w_h).dot(gu)) - 0.02)
	# Sleeve over the view centre: |xy| / -z < 0.32 is within ~18° of the crosshair.
	for t: float in [0.08, 0.2, 0.32, 0.44]:
		var q := w + d * t
		if q.z < -0.05:
			cost += (1.0 + 2.0 * ads) * maxf(0.0, 0.32 - Vector2(q.x, q.y).length() / -q.z)
	if c.z > -0.05:
		return cost + 2.0                                  # screen beside / behind the eye
	# Screen inside the view (vertical half-FOV ~37°: tan 0.77) and not behind the gun body.
	var sy := c.y / -c.z
	cost += 2.0 * maxf(0.0, -0.68 - sy) + 2.0 * maxf(0.0, sy - 0.6) + maxf(0.0, absf(c.x / -c.z) - 1.1)
	var cp := Geometry3D.get_closest_points_between_segments(Vector3.ZERO, c,
			gun * Vector3(0.0, 0.07, 0.15), gun * Vector3(0.0, 0.07, -0.45))
	if cp[0].length() < cl - 0.03 and cp[0].distance_to(cp[1]) < 0.045:
		cost += 1.0
	# Text tilt: its top runs toward the hand (-d); compare the projected direction to screen-up.
	var top := c - d * 0.02
	if top.z < -0.01:
		var up2 := Vector2(top.x, top.y) / -top.z - Vector2(c.x, c.y) / -c.z
		cost += 0.25 * maxf(0.0, absf(atan2(up2.x, up2.y)) - 0.6)
	var sa := absf(slide)
	return cost + 0.6 * absf(roll) + 0.15 * minf(sa, WF_SLIDE_MAX) + 0.1 * maxf(0.0, sa - WF_SLIDE_MAX)


## Best roll / slide for a grip pose: Vector3(roll, slide, facing there). full: the slide is searched
## too (else it stays slide0 and only the roll is searched, with hysteresis around roll0). Grid
## search (10° roll × 12.5° slide steps), then a 2.5° refine around the best; with full, a second
## pass up to ±slide_lim when the best stays below WF_GOOD (the inner wrist). ~250 cost evaluations
## for a full search (once per item), ~25 for a roll-only one.
static func wrist_face_search(grip: Transform3D, gun: Transform3D, g: Array, roll0: float, slide0: float,
		ads: float, full: bool, roll_lim := WF_ROLL_MAX, slide_lim := PI) -> Vector3:
	var hyst := 0.0 if full else 0.15
	var best := Vector3(0.0, slide0, INF)                # roll, slide, cost
	best = _wf_grid(grip, gun, g, ads, roll0, hyst, best, _wf_steps(-roll_lim, roll_lim, 0.1745),
			_wf_steps(-minf(slide_lim, WF_SLIDE_MAX), minf(slide_lim, WF_SLIDE_MAX), 0.218) if full else [slide0])
	if full and slide_lim > WF_SLIDE_MAX and wrist_face_dot(grip, g, best.x, best.y) < WF_GOOD:
		best = _wf_grid(grip, gun, g, ads, roll0, hyst, best, _wf_steps(-roll_lim, roll_lim, 0.1745),
				_wf_steps(-slide_lim, slide_lim, 0.2618))
	var rs := _wf_steps(maxf(best.x - 0.131, -roll_lim), minf(best.x + 0.131, roll_lim), 0.0436)
	var ss: Array = [best.y]
	if full:
		ss = _wf_steps(clampf(best.y - 0.131, -slide_lim, slide_lim), clampf(best.y + 0.131, -slide_lim, slide_lim), 0.0436)
	best = _wf_grid(grip, gun, g, ads, roll0, hyst, best, rs, ss)
	return Vector3(best.x, best.y, wrist_face_dot(grip, g, best.x, best.y))


static func _wf_grid(grip: Transform3D, gun: Transform3D, g: Array, ads: float, roll0: float, hyst: float,
		best: Vector3, rolls: Array, slides: Array) -> Vector3:
	for r: float in rolls:
		for s: float in slides:
			var k := wrist_face_cost(grip, gun, g, r, s, ads) + hyst * absf(r - roll0)
			if k < best.z:
				best = Vector3(r, s, k)
	return best


## a, a + step, ... up to b (b included).
static func _wf_steps(a: float, b: float, step: float) -> Array:
	var out: Array = []
	var n := maxi(int(ceilf((b - a) / step - 0.001)), 0)
	for i in n + 1:
		out.append(minf(a + i * step, b))
	return out


func _update_wrist() -> void:
	var p = player
	var fuel: float = clampf(p.jet_fuel_frac(), 0.0, 1.0)
	var it = _current
	var nm: String = it.item_name if it != null else ""
	var col: Color = it.accent_color() if it != null else Color.WHITE
	var blink := fmod(_t, 0.8) < 0.4
	if _wrist_ui.set_values(fuel, Game.material, 200.0, p.gravity_vec.length() / 9.81, nm, col, blink, 1.0, p.lamp_on(),
			float(p.hp), float(p.hp_max)):
		_wrist_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
