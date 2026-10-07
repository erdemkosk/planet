extends Node
## Global state (autoload "Game"): constants, input map, references, the material counter, ammo,
## gravity and damage helpers.
##
## Material (generic soil, m³): the only resource. Digging adds it, raising / flattening ground and
## buying ammo spend it (cannons and the shuttle will too).
##   Game.material                 current amount
##   Game.add_material(d) -> float add (or with d < 0 remove); returns what actually changed
##   Game.spend_material(c) -> bool  all-or-nothing payment
##   signal material_changed(amount)
## Ammo: each kind has a reserve; a reload takes rounds from it and buys the shortfall from material
## at AMMO_COST m³ per round (take_ammo).
## Gravity: every planet pulls (planet.gd gravity_accel: linear inside, inverse square outside, no
## fade); gravity_at() sums them. "Up" on the ground comes from dominant_body().
## Damage: anything in group "damageable" implements take_damage(amount, from_pos, impulse) ->
## {"dmg": float, "killed": bool} and has hp / hp_max; deal_damage() / damage_target() route hits.

const Settings := preload("res://scripts/save/settings.gd")
const Bodies := preload("res://scripts/planet/bodies.gd")
const Balance := preload("res://scripts/war/balance.gd")     # START_MATERIAL (one cannon)

## Far clip of every gameplay camera: both planets (350 m apart, bodies.gd) and far beyond.
const CAM_FAR := 10000.0

const LAYER_TERRAIN := 1
const LAYER_SHIP := 2
const LAYER_VEHICLE := 4
const LAYER_PLAYER := 8          # characters (player, AI rival bot): what bullets and blasts hit
const LAYER_INTERACT := 16

## Group of everything that takes damage (player, AI rival bot, later the cores / cannons).
const DAMAGEABLE := "damageable"

# Untyped on purpose: scripted nodes we call custom methods on.
var planet                       # the player's home planet (planet.gd)
var rival                        # the AI rival's planet
var player
var hud
var controlled                   # what the player controls right now (the player, later the shuttle)
var sfx
var pause_menu
## Other panels that own the input while open (nodes with is_open()): the main menu, the
## multiplayer chat / loading cover / dialogs (scripts/net/net_overlay.gd).
var ui_panels: Array = []
## Sun direction (unit, toward the sun). Fixed: main.gd sets it side-on to the planets' axis.
var sun_dir := Vector3(0.0, 0.35, 1.0).normalized()

# --- Match end --------------------------------------------------------------------------------
## The match is decided: set (and match_ended emitted) when the victory / defeat screen appears
## (end_match(), from scripts/war/war_hud.gd show_end); reset_state() (a new match, "Yeniden
## başla") clears it. Gameplay overlays hide meanwhile (overlays_hidden(), scripts/ui/overlay_guard.gd),
## so do the view model and the quickbar.
var match_over := false
signal match_ended(won: bool)

## HUD density (Esc › Ayarlar › HUD; scripts/save/settings.gd hud_mode, scripts/ui/hud_mode.gd):
## 0 Sade (default), 1 Normal, 2 Detaylı. The signal fires when the player changes it.
signal hud_mode_changed(mode: int)


func hud_mode() -> int:
	return clampi(Settings.hud_mode, 0, 2)


# --- Material ---------------------------------------------------------------------------------
signal material_changed(amount: float)
## War (scripts/war/core.gd): a planet's core lost hp (`body` = that planet), or was destroyed.
signal core_damaged(body: Node3D, hp: float)
signal core_destroyed(body: Node3D)
var material := 0.0
var _material_shown := -1


## Co-op ("Birlikte") TEAM MATERIAL POOL (2026-10-06): with shared_pool on, `material` is the team's
## one pool on both machines ("TAKIM MALZEMESİ" in the HUD); the HOST owns it. A client's own changes
## (digging, builds, crafts, ammo, refunds) still go through add_material / spend_material: they apply
## to the client's copy at once and are emitted as pool_delta(d) for the network layer to forward
## (the host applies them with net_pool_delta); the host's value comes back with net_set_pool(v).
## PvP and single player: off (each player his own material).
var shared_pool := false
signal pool_delta(d: float)
var _pool_sync := false


## The material the local player spends from: his own, or the team pool in co-op.
func team_material() -> float:
	return material


## Network layer, both machines, at the co-op match start (off for PvP / leaving). start >= 0: the
## pool's starting amount (the host's; e.g. 2 × Balance.START_MATERIAL for two players).
func set_shared_pool(on: bool, start := -1.0) -> void:
	shared_pool = on
	if on and start >= 0.0:
		net_set_pool(start)


## Client: the host's pool value (no pool_delta).
func net_set_pool(v: float) -> void:
	_pool_sync = true
	add_material(maxf(v, 0.0) - material)
	_pool_sync = false


## Host: a client's change to the pool (clamped at 0).
func net_pool_delta(d: float) -> void:
	_pool_sync = true
	add_material(d)
	_pool_sync = false


## Adds (or with a negative d removes) material, never below 0. Returns the change applied.
func add_material(d: float) -> float:
	var before := material
	material = maxf(material + d, 0.0)
	var shown := int(floorf(material + 0.0001))
	if shown != _material_shown:
		_material_shown = shown
		material_changed.emit(material)
	if shared_pool and not _pool_sync and material != before and Net.is_client():
		pool_delta.emit(material - before)        # (the network layer forwards it to the host's pool)
	return material - before


## Pays `cost` if there is enough (true), otherwise nothing changes (false).
func spend_material(cost: float) -> bool:
	if cost <= 0.0:
		return true
	if material + 0.0001 < cost:
		return false
	add_material(-cost)
	return true


# --- Ammo -------------------------------------------------------------------------------------
signal ammo_changed
## m³ of material per round when the reserve runs short (bought automatically on reload).
## (2026-10-06 economy pass: mortar 9 -> 12: its ~20 m³ crater gave a Mk IV drill's auto-collect ~10 m³
## back, more than the round cost; 12 m³ ≈ 1.3 s of digging, a fifth of a cannon shell.)
const AMMO_COST := {"ammo_std": 0.1, "ammo_ap": 0.3, "ammo_shell": 0.25, "ammo_rocket": 8.0, "ammo_sniper": 0.6,
		"ammo_rail": Balance.RAIL_AMMO_COST, "ammo_smg": Balance.SMG_AMMO_COST, "ammo_mortar": 12.0,
		"ammo_pistol": Balance.PISTOL_AMMO_COST, "ammo_magnum": Balance.REVOLVER_AMMO_COST}   # (sidearms)
## Reserve at the start of a game before the loadout's (set_loadout tops its guns up to
## Balance.LOADOUT_RESERVE × CRAFT_RESERVE; a picked-up gun brings its own along).
const AMMO_START := {"ammo_std": 0, "ammo_ap": 0, "ammo_shell": 0, "ammo_rocket": 0, "ammo_sniper": 0, "ammo_rail": 0,
		"ammo_smg": 0, "ammo_mortar": 0, "ammo_pistol": 0, "ammo_magnum": 0}
var ammo := {}

# --- Arsenal (the loadout; every carried gun has a key) ------------------------------------------
## 2026-10-06 (the user: crafting guns slowed the game down): everyone spawns ARMED. `crafted`
## (item_id -> true; the old name is kept for its readers) is now the LOADOUT: slot A (loadout_a, one
## of Balance.LOADOUT_A: rifle / SMG / shotgun) and slot B (loadout_b, one of Balance.LOADOUT_B: a sidearm
## or Toprak Topu),
## picked at the match start and on every respawn ride (scripts/war/respawn_ship.gd with
## scripts/war/loadout_panel.gd; set_loadout). Power weapons come by İkmal kapsülü
## (scripts/war/supply_pod.gd, Tab) and bot rifles / cache guns lie on the ground: a gun picked up
## that is not in the loadout is a LOOT gun (loot_guns): carried like the others, lost on death.
## Keys 1 drill, 2 build tool, then 3, 4, 5 … the carried guns in the fixed order GUN_ORDER compacted
## to the ones you have (a 10th gun would be 0); the wheel cycles them while a gun is held. The
## Silahlık sells permanent upgrades only (`upgrades`: Balance.UPG_*; drill tiers: drill_tiers.gd).
## The loadout, grenades and upgrades are kept through death (a respawn tops the loadout's reserve and
## the grenades up: loadout_refill); reset_state() (a new match) starts them over. Per machine: in
## multiplayer every player picks and carries for himself.
##   loadout_a / loadout_b     the picks (kept between matches)   set_loadout(a, b)   loadout_refill()
##   upgrade_level(id) / set_upgrade(id, level)   ("pod", "pouch")  grenade_max()
##   owns(id)                  the drill / build tool always; a gun in the loadout
##   can_hold(id)              owned, or a loot gun                is_loot_gun(id)
##   carried_guns() -> Array   the carried gun ids in key order (owned + loot, GUN_ORDER first, any
##                             other gun after them)
##   gun_index(id) -> int      its place in carried_guns() (-1)    gun_key(id) -> int  3, 4, … (0: none)
##   key_label(index) -> String  "3" … "9", "0" (the 8th gun), "" beyond
##   add_loot_gun(id)          a picked-up gun you have not made    lose_loot_guns()  death
##   loadout_id(i) / loadout_slot_of(id)   old names of carried_guns()[i] / gun_index(id)
##   signal loadout_changed    any change of the guns carried (a loadout pick, a pickup, a death's
##                             loss, a respawn's re-equip) or of the grenades; the player, the
##                             quickbar, the view model and multiplayer read the state above
signal loadout_changed
const FREE_ITEMS := ["terrain", "build", "hands"]
## The guns' key order (keys 3, 4, 5 … compacted to the carried ones); a gun not listed goes after.
## (2026-10-07: slot A's guns first, then slot B's sidearms / Toprak Topu: the primary on 1, the sidearm on 2.)
const GUN_ORDER := ["rifle", "smg", "shotgun", "pistol", "revolver", "mpistol", "dirt", "sniper", "pusher", "rocket",
		"rail", "mortar", "plasma"]
const FIRST_GUN_KEY := 1               # (2026-10-06: 3 -> 1, the tools moved to Z / X)
var crafted := {}
var grenades := 0
var loot_guns := {}
var loadout_a := ""                       # "" = Balance.LOADOUT_A[0]
var loadout_b := ""                       # "" = Balance.LOADOUT_B[0]
var upgrades := {}                        # Silahlık upgrade id ("pod", "pouch") -> level


## The loadout picks (the defaults when unset or no longer offered).
func loadout_pick_a() -> String:
	return loadout_a if loadout_a in Balance.LOADOUT_A else str(Balance.LOADOUT_A[0])


func loadout_pick_b() -> String:
	return loadout_b if loadout_b in Balance.LOADOUT_B else str(Balance.LOADOUT_B[0])


## Picks the loadout (slot A, slot B) and carries exactly those two (a loot gun of the same kind becomes
## a loadout gun; a gun no longer picked goes). top_up: their reserve raised to the starter amount.
## Eğitim Alanı (meta "training"): the pick is recorded but no gun goes (unlock_all_weapons gave them all).
func set_loadout(a: String, b: String, top_up := true) -> void:
	loadout_a = a if a in Balance.LOADOUT_A else loadout_pick_a()
	loadout_b = b if b in Balance.LOADOUT_B else loadout_pick_b()
	var keep: Dictionary = crafted if has_meta("training") else {}
	crafted = {loadout_a: true, loadout_b: true}
	crafted.merge(keep)
	loot_guns.erase(loadout_a)
	loot_guns.erase(loadout_b)
	if top_up:
		_top_up_reserve()
	loadout_changed.emit()


## A respawn: the loadout guns' reserve up to the starter amount (Balance.LOADOUT_RESERVE × CRAFT_RESERVE),
## their magazines full, the grenades up to Balance.LOADOUT_GRENADES (never down).
func loadout_refill() -> void:
	_top_up_reserve()
	grenades = maxi(grenades, mini(Balance.LOADOUT_GRENADES, grenade_max()))
	var p = player
	if p != null and is_instance_valid(p) and p.get("items") is Array:
		for it in p.items:
			if it == null or not crafted.has(str(it.get("item_id"))) or not it.has_method("save_state") \
					or not it.has_method("load_state"):
				continue
			var st: Dictionary = it.save_state()
			st.erase("att")                       # (the fitted attachments stay as they are)
			var m = st.get("mags")
			if m is Array and it.has_method("mag_capacity"):
				for i in (m as Array).size():
					m[i] = maxi(int(m[i]), int(it.mag_capacity(i)))
			elif st.has("mag") and it.has_method("mag_capacity"):
				st["mag"] = maxi(int(st["mag"]), int(it.mag_capacity()))
			it.load_state(st)
	loadout_changed.emit()


func _top_up_reserve() -> void:
	for gid in crafted:
		var res: Dictionary = Balance.CRAFT_RESERVE.get(gid, {})
		for a in res:
			var want := int(roundf(float(res[a]) * Balance.LOADOUT_RESERVE))
			ammo[a] = maxi(ammo_reserve(str(a)), want)
	ammo_changed.emit()


## The level of Silahlık upgrade `id` ("pod": İkmal indirimi, "pouch": Bomba kemeri; 0 = none).
func upgrade_level(id: String) -> int:
	return int(upgrades.get(id, 0))


func set_upgrade(id: String, level: int) -> void:
	upgrades[id] = maxi(level, upgrade_level(id))
	loadout_changed.emit()


## Grenades carried at most (Balance.GRENADE_MAX + the Bomba kemeri upgrade).
func grenade_max() -> int:
	var lv := clampi(upgrade_level("pouch"), 0, Balance.UPG_POUCH.size() - 1)
	return Balance.GRENADE_MAX + int(Balance.UPG_POUCH[lv])


## The player may hold item `id` (the drill and the build tool always; the loadout's guns).
func owns(id: String) -> bool:
	return id in FREE_ITEMS or bool(crafted.get(id, false))


## Owned, or a loot gun picked up from the ground.
func can_hold(id: String) -> bool:
	return owns(id) or loot_guns.has(id)


func is_loot_gun(id: String) -> bool:
	return loot_guns.has(id) and not bool(crafted.get(id, false))


## Owned for the rest of the match on top of the loadout (old crafting callers; a loot gun of that kind
## becomes an owned one). The next set_loadout() drops it again.
func unlock(id: String) -> void:
	crafted[id] = true
	loot_guns.erase(id)
	loadout_changed.emit()


## Every carried gun id in key order: GUN_ORDER compacted to the ones held, then any other.
func carried_guns() -> Array:
	var out: Array = []
	# (2026-10-07) The loadout's picks lead: the primary on key 1, the sidearm on 2, whatever loot gun
	# is picked up (it goes after them). Not in the Eğitim Alanı (every gun carried, plain GUN_ORDER).
	if not has_meta("training"):
		for id in [loadout_pick_a(), loadout_pick_b()]:
			if bool(crafted.get(id, false)) and not out.has(id):
				out.append(id)
	for id in GUN_ORDER:
		if out.has(str(id)):
			continue
		if can_hold(str(id)):
			out.append(str(id))
	var extra: Array = []
	for d in [crafted, loot_guns]:
		for id in d:
			var s := str(id)
			if not (s in GUN_ORDER) and not (s in FREE_ITEMS) and not extra.has(s) and can_hold(s):
				extra.append(s)
	extra.sort()
	out.append_array(extra)
	return out


func gun_index(id: String) -> int:
	return carried_guns().find(id) if id != "" else -1


## The number key of carried gun `id` (3, 4, … 9, 10 = the 0 key), 0 = not carried.
func gun_key(id: String) -> int:
	var i := gun_index(id)
	return FIRST_GUN_KEY + i if i >= 0 else 0


## The label of the key of the index-th carried gun: "3" … "9", "0", "" (no key).
static func key_label(index: int) -> String:
	var n := FIRST_GUN_KEY + index
	if index < 0 or n > 10:
		return ""
	return "0" if n == 10 else str(n)


## (Old names, kept for callers: the index-th carried gun / the index of a gun.)
func loadout_id(i: int) -> String:
	var g := carried_guns()
	return str(g[i]) if i >= 0 and i < g.size() else ""


func loadout_slot_of(id: String) -> int:
	return gun_index(id)


## A gun picked up from the ground that is not in your loadout: carried until you die.
func add_loot_gun(id: String) -> void:
	if id == "" or owns(id) or loot_guns.has(id):
		return
	loot_guns[id] = true
	loadout_changed.emit()


## Death: the loot guns are lost (the loadout stays).
func lose_loot_guns() -> void:
	if loot_guns.is_empty():
		return
	loot_guns.clear()
	loadout_changed.emit()


## Everything at once (training mode, cheats): every craftable gun owned, a full grenade pouch and
## each gun's starter reserve on top of the current one (all of them carried: keys 3 … 9).
func unlock_all_weapons() -> void:
	for id in Balance.CRAFT_COST:
		if str(id) != "grenade":
			crafted[str(id)] = true
	var att = load("res://scripts/items/attachments.gd")   # every weapon attachment too
	if att is Script and (att as Script).can_instantiate():
		att.unlock_all()
	var dt = load("res://scripts/items/drill_tiers.gd")      # the drill at Mk IV (drill_tiers.gd)
	if dt is Script and (dt as Script).can_instantiate():
		dt.unlock_all()
	grenades = Balance.GRENADE_MAX
	for gid in Balance.CRAFT_RESERVE:
		var res: Dictionary = Balance.CRAFT_RESERVE[gid]
		for a in res:
			ammo[a] = ammo_reserve(str(a)) + int(res[a])
	ammo_changed.emit()
	loadout_changed.emit()


## Takes one grenade from the stack (false: none left).
func take_grenade() -> bool:
	if grenades <= 0:
		return false
	grenades -= 1
	loadout_changed.emit()
	return true


func ammo_reserve(id: String) -> int:
	return int(ammo.get(id, 0))


## Rounds a reload could get: the reserve plus what the material can buy.
func ammo_available(id: String) -> int:
	var cost: float = float(AMMO_COST.get(id, 0.0))
	var buy := int(floorf(material / cost + 0.0001)) if cost > 0.0 else 0
	return ammo_reserve(id) + buy


## Takes up to n rounds: from the reserve first, the rest bought from material. Returns the rounds
## actually granted.
func take_ammo(id: String, n: int) -> int:
	if n <= 0:
		return 0
	var from_res := mini(ammo_reserve(id), n)
	ammo[id] = ammo_reserve(id) - from_res
	var got := from_res
	var cost: float = float(AMMO_COST.get(id, 0.0))
	if got < n and cost > 0.0:
		var buy := mini(n - got, int(floorf(material / cost + 0.0001)))
		if buy > 0:
			add_material(-cost * buy)
			got += buy
	ammo_changed.emit()
	return got


# --- Setup / input ----------------------------------------------------------------------------

func _ready() -> void:
	_setup_input()
	Settings.load_and_apply()      # mouse, FOV, volume, window (Esc › Ayarlar)
	reset_state()
	add_child(load("res://scripts/ui/overlay_guard.gd").new())   # hides crosshairs etc. (overlays_hidden())


## A fresh match: material for exactly one cannon (Balance.START_MATERIAL), the loadout armed (its
## starter reserve, Balance.LOADOUT_GRENADES grenades), no upgrades. Not called on respawn (material
## is kept).
func reset_state() -> void:
	match_over = false
	material = Balance.START_MATERIAL
	_material_shown = -1
	ammo = (AMMO_START as Dictionary).duplicate()
	loot_guns = {}
	upgrades = {}
	# Armed from the start: the loadout (slot A + slot B) with its starter reserve, a few grenades.
	set_loadout(loadout_pick_a(), loadout_pick_b())
	grenades = Balance.LOADOUT_GRENADES
	# Supply pods: the call cooldown and any open request (scripts/war/supply_pod.gd; same load guard).
	if ResourceLoader.has_cached("res://scripts/war/supply_pod.gd"):
		var sp = load("res://scripts/war/supply_pod.gd")
		if sp is Script and (sp as Script).can_instantiate():
			sp.reset()
	# Attachments unlocked last match are gone. (Only once that script is loaded: this also runs in our
	# own _ready, before the Game name exists for a script compiled then; nothing is owned yet anyway.)
	if ResourceLoader.has_cached("res://scripts/items/attachments.gd"):
		var att = load("res://scripts/items/attachments.gd")
		if att is Script and (att as Script).can_instantiate():
			att.reset()
	# The drill's upgrade tier too (scripts/items/drill_tiers.gd: back to Mk I; same load guard).
	if ResourceLoader.has_cached("res://scripts/items/drill_tiers.gd"):
		var dt = load("res://scripts/items/drill_tiers.gd")
		if dt is Script and (dt as Script).can_instantiate():
			dt.reset()
	add_material(0.0)
	ammo_changed.emit()
	loadout_changed.emit()


func _setup_input() -> void:
	_bind_keys("move_forward", [KEY_W])
	_bind_keys("move_back", [KEY_S])
	_bind_keys("move_left", [KEY_A])
	_bind_keys("move_right", [KEY_D])
	_bind_keys("jump", [KEY_SPACE])
	_bind_keys("descend", [KEY_CTRL, KEY_C])
	_bind_keys("sprint", [KEY_SHIFT])
	_bind_keys("interact", [KEY_F])
	_bind_keys("flashlight", [KEY_L])
	# Quickbar (player.gd, scripts/ui/quickbar.gd): 1, 2, 3 … 9, 0 the carried guns in Game.GUN_ORDER,
	# compacted to the ones you have (Game.carried_guns()); the wheel cycles them while a gun is held.
	# The tools are off the number row (2026-10-06, the user: "matkap ve inşaatı silah tuşlarına koyma,
	# kafa karıştırıyor"): Z the drill, X the build tool, the same key again back to the last gun;
	# Z held = Hızlı siper (player.gd _tool_key_input).
	for n in range(1, 10):
		_bind_keys("slot_%d" % n, [KEY_0 + n])
	_bind_keys("slot_10", [KEY_0])       # (a 10th carried gun)
	_bind_keys("tool_drill", [KEY_Z])    # Kazı Aracı (Matkap)
	_bind_keys("tool_build", [KEY_X])    # İnşa Aracı
	# On foot: hold Left Ctrl to crouch, C toggles (scripts/player/stance.gd). The same keys are the
	# shuttle's "descend"; the player ignores crouch inside a vehicle.
	_bind_keys("crouch", [KEY_CTRL])
	_bind_keys("crouch_toggle", [KEY_C])
	# Left hand (scripts/player/hand_action.gd), on foot only: G grenade (hold to cook), Q scanner.
	_bind_keys("throw_grenade", [KEY_G])
	_bind_keys("scan_pulse", [KEY_Q])
	# Weapon handling on foot: hold Y to inspect (scripts/items/handling.gd), V melee
	# (scripts/player/melee.gd; V is the skiff's chase cam only while piloting).
	_bind_keys("inspect", [KEY_Y])
	_bind_keys("melee", [KEY_V])
	# Hızlı siper (scripts/player/entrench.gd): Z held on foot (player.gd _tool_key_input calls its
	# start()); the "entrench" action stays without a key of its own (X is the build tool now).
	if not InputMap.has_action("entrench"):
		InputMap.add_action("entrench")
	# R: drill mode (drill) / reload (guns). Middle mouse: drill mode / gun fire mode.
	_bind_keys("tool_mode", [KEY_R])
	_bind_mouse("tool_mode", MOUSE_BUTTON_MIDDLE)
	_bind_mouse("tool_use", MOUSE_BUTTON_LEFT)
	_bind_mouse("tool_alt", MOUSE_BUTTON_RIGHT)
	_bind_mouse("brush_up", MOUSE_BUTTON_WHEEL_UP)
	_bind_mouse("brush_down", MOUSE_BUTTON_WHEEL_DOWN)
	# Tab on foot: the İkmal kapsülü menu (scripts/war/supply_menu.gd: 1-4 call a power weapon in).
	_bind_keys("supply_call", [KEY_TAB])
	# Left Alt held on foot: the whole HUD for a look (Sade hides the rest; scripts/ui/hud_mode.gd peek()).
	# (In the armed skiff Alt is its free look, armed_skiff.gd; peek() ignores vehicles.)
	_bind_keys("hud_show", [KEY_ALT])
	# E on foot: the character's ultimate (scripts/war/heroes/heroes.gd; hold to aim the targeted ones).
	# The build tool (category) and the Mk IV drill's bore keep E while held; the skiff uses it to yaw.
	_bind_keys("hero_ult", [KEY_E])


func _bind_keys(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _bind_mouse(action: String, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# Esc: pause menu (it frees the mouse and closes itself on the next Esc).
		if pause_menu != null and is_instance_valid(pause_menu) and not pause_menu.is_open():
			pause_menu.open()
			get_viewport().set_input_as_handled()
		elif pause_menu == null:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("supply_call") and not (event is InputEventKey and (event as InputEventKey).alt_pressed) \
			and not ui_panel_open() and not match_over \
			and not load("res://scripts/war/downed.gd").is_downed(player):   # (downed: no supply menu; load()ed: autoload)
		# Tab: the İkmal kapsülü menu (scripts/war/supply_menu.gd checks on foot / alive itself).
		var sm = load("res://scripts/war/supply_menu.gd")
		if sm is Script and (sm as Script).can_instantiate():
			sm.toggle()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and not (event as InputEventMouseButton).button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
				MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT] and not ui_panel_open():
		# A click into the game takes the mouse back, but never while a menu is open.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F11:
		# F11: fullscreen <-> window (remembered, Esc › Ayarlar)
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		Settings.set_fullscreen(not full)
		Settings.save()


## A menu that needs the mouse is open (the pause menu).
func ui_panel_open() -> bool:
	if pause_menu != null and is_instance_valid(pause_menu) and pause_menu.is_open():
		return true
	for p in ui_panels:
		if p != null and is_instance_valid(p) and p.is_open():
			return true
	return false


## The victory / defeat screen appears (war_hud.gd show_end): match_over, match_ended(won). Once.
func end_match(won: bool) -> void:
	if match_over:
		return
	match_over = true
	match_ended.emit(won)


## Gameplay overlays (crosshairs, hit markers, scopes, gun read-outs, seat overlays) stay hidden
## now: the match is over, a menu / modal panel is open or the game is paused.
func overlays_hidden() -> bool:
	return match_over or ui_panel_open() or (is_inside_tree() and get_tree().paused)


# --- Gravity / bodies -------------------------------------------------------------------------

## Gravity at a world position: the sum of every planet's pull (m/s², pointing down).
func gravity_at(pos: Vector3) -> Vector3:
	var g := Vector3.ZERO
	for b in Bodies.all():
		if not is_instance_valid(b):
			continue
		var d: Vector3 = pos - (b as Node3D).global_position
		var dist := d.length()
		if dist < 0.001:
			continue
		g -= d / dist * float(b.gravity_accel(dist))
	return g


## The planet that pulls hardest at pos ("up" for walking, the world you are on).
func dominant_body(pos: Vector3) -> Node3D:
	var b := Bodies.dominant(pos)
	return b if b != null else planet


## Alias of dominant_body (older callers).
func body_at(pos: Vector3) -> Node3D:
	return dominant_body(pos)


## The home planet's centre.
func planet_center() -> Vector3:
	if planet != null and is_instance_valid(planet):
		return (planet as Node3D).global_position
	return Vector3.ZERO


## Height above the base radius of the dominant planet.
func altitude(pos: Vector3) -> float:
	var b := dominant_body(pos)
	if b == null:
		return 0.0
	return pos.distance_to(b.global_position) - float(b.radius)


## 1 at the surface, 0 at the top of the (thin) air and in the vacuum between the planets.
func atmosphere_factor(pos: Vector3) -> float:
	var b := dominant_body(pos)
	if b == null or not b.has_atmosphere or float(b.atmo_height) <= 0.0:
		return 0.0
	return clampf(1.0 - altitude(pos) / float(b.atmo_height), 0.0, 1.0)


# --- Damage -----------------------------------------------------------------------------------

## The damageable node a collider belongs to (itself or an ancestor in group "damageable"), or null.
func damageable_of(obj: Object) -> Node:
	var n := obj as Node
	while n != null:
		if n.is_in_group(DAMAGEABLE) and n.has_method("take_damage"):
			return n
		n = n.get_parent()
	return null


## Where the damage being dealt right now struck (world; Vector3.INF = unknown, e.g. a blast): set by
## damage_target(..., hit_point) around its take_damage call (take_damage's signature stays the same
## for every implementer), read by the receivers' hit reactions (scripts/player/hit_reactor.gd).
var hit_pos := Vector3.INF


## Applies damage to a damageable node. Returns its result ({} when it is not damageable).
## src_team ("home" / "rival", "" = unknown): own-team structures (group "war_structure") take only
## Balance.FRIENDLY_FIRE of it. hit_point: where it struck (bullet / melee / direct hit), published as
## Game.hit_pos during the take_damage call.
func damage_target(target: Node, amount: float, from_pos: Vector3, impulse := Vector3.ZERO, src_team := "",
		hit_point := Vector3.INF) -> Dictionary:
	if target == null or not is_instance_valid(target) or not target.has_method("take_damage"):
		return {}
	if Net.is_client():
		# Multiplayer: every hp is the host's; a client's hit becomes a claim (scripts/net/net_world.gd).
		return Net.world.claim_damage(target, amount, from_pos, impulse, hit_point)
	if src_team != "" and (target.is_in_group("war_structure") or target.is_in_group("net_player")
			or target.is_in_group("war_ally")) and team_of(target) == src_team:   # (war_ally: ally_team.gd bots)
		amount *= Balance.FRIENDLY_FIRE
	var prev_hit := hit_pos
	hit_pos = hit_point
	var r = target.take_damage(amount, from_pos, impulse)
	hit_pos = prev_hit
	return r if r is Dictionary else {}


## Area damage (explosions): every damageable within `radius` of `center` takes `amount` falling
## off linearly to 0 at the edge, plus an impulse (m/s at the centre) away from the blast.
func area_damage(center: Vector3, radius: float, amount: float, impulse := 0.0, exclude: Node = null, src_team := "") -> void:
	for n in get_tree().get_nodes_in_group(DAMAGEABLE):
		if n == exclude or not (n is Node3D) or not n.has_method("take_damage"):
			continue
		var p: Vector3 = (n as Node3D).global_position + (n as Node3D).global_transform.basis.y * 0.9
		var d := p.distance_to(center)
		if d > radius:
			continue
		var k := 1.0 - d / radius
		var dir := (p - center).normalized() if d > 0.01 else (n as Node3D).global_transform.basis.y
		damage_target(n, amount * k, center, dir * impulse * k, src_team)


## "home" or "rival": a node's `team` property, else its "team" meta, else "home" (the player's).
func team_of(n: Object) -> String:
	if n == null:
		return ""
	var t = n.get("team")
	if t is String and t != "":
		return t
	if n.has_meta("team"):
		return str(n.get_meta("team"))
	return "home"


# --- Combat events (the rival bots react to them, scripts/war/ai_rival.gd) ----------------------
## A gun fired a bullet / pellet from `from` along `dir` (unit): bots it passes close to take cover.
signal shot_fired(from: Vector3, dir: Vector3, team: String)
## Something exploded at `pos` (blast radius `radius`).
signal blast(pos: Vector3, radius: float, team: String)
