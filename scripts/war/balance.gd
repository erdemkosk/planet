extends RefCounted
## Every war tunable in one place (cores, cannons, shells, building, the drill's material rate,
## the AI rival). Times in seconds, distances in metres, material in m³ (Game.material).
##
## Tuned for the planet layout in scripts/planet/bodies.gd (PLANET_RADIUS 60 m, PLANET_DISTANCE
## 350 m, surface gravity 0.8 g; 2026-10-06, was R 30): escape speed from one planet ~30.7 m/s, the
## slowest shell that clears the saddle between the planets ~22 m/s (straight up from the point
## facing the other planet); the other planet is ~22° across, its near surface 230 m and its base
## ~270 m away; a core lies ~57 m down; the horizon ~14 m away (a standing enemy's head shows to
## ~23 m on average, 30-40 m from a rise). Re-check the cannon speeds, the drop pods, the flak and the
## AI ranges / aim numbers below when those change (headless probes measured them, see each block).
## The shell crater is deliberately NOT scaled with the planet (user's call): the core's blast reach
## is (CORE_BLAST_K).
##
## Balance target (estimates; the shelling numbers from a crater-stacking probe):
##   - Economy (2026-10-06 economy pass: "oyun daha yavaş, tok hissettirmeli; hiç kazmaya gerek
##     olmuyor"): the drill pays DRILL_MAX_RATE = 10 m³/s while it works (~8-9.5 with the heat vents),
##     the zones + the core pump ~2.9 m³/s for your own planet (zone_income, CORE_PUMP): a player who
##     digs half the time earns ~7.5 m³/s, a third of it passive. Both sides start with START_MATERIAL
##     (half a cannon); a cannon (CANNON_COST) is ~1 min of digging, a shell (SHELL_COST) ~6 s. The
##     bonuses (veins, meteor cores, caches, crater auto-collect) are spikes of ~5-35 s of digging.
##     (Before: ~5 m³/s of real drilling, but ~23 m³/s passive: digging was optional.)
##   - First contact ~1.5-2 min in: a drop pod (POD_FIRST_AFTER), a skiff raid from ~3 min
##     (RAID_FIRST_AFTER), then a pod or a raid about every 2-2.5 min (2026-10-06 tok: was ~1 / ~2 /
##     ~1.5 min; the user: "oyun daha yavaş, tok hissettirmeli").
##   - Shells fly ~8-14 s and deal core damage only from holes deeper than ~19 m (CORE_BLAST_K ×
##     SHELL_CRATER_R = 38.5 m reach from the core's surface). The AI's shelling spreads 5-20 m around
##     its aim point: 12-30 shells dig its hole only ~12-28 m deep. A careful gunner who keeps landing
##     in one hole (~3-4 m deeper a shell: they hit its walls) digs ~45 m in ~25 shells (~135 damage)
##     and kills the core with ~6-8 more: ~30 shells (R 30: ~16-18). The Delici Top penetrator lands
##     in the deepest crater and bores BUSTER_PENETRATE m on: probe, 9-10 penetrators after 12-24 AI
##     shells kill CORE_HP 300 (10-58 a shot, each deepens the hole); 3 Sondaj torpidosu
##     (TORPEDO_CORE_DAMAGE) or ~50 s of an enemy drill at the core (CORE_DRILL_DPS) too.
##   - The rival team (8 bots) earns about what a half-digging player does (TEAM_INCOME_CAP, its zones
##     and pump) and fires at most one shell per AI_TEAM_FIRE_GAP s (twice that while it saves for
##     structures). (Before the economy pass: its base complete in ~2-3 min, its Delici Top firing from
##     ~3 min, our core gone ~11-13 min in unless we defend; slower now, see the economy probe.)

# --- Material from digging ------------------------------------------------------------------------
## Upper limit on how fast the drill turns dug soil into material (m³/s). A larger brush digs a
## bigger hole but not faster than this. The AI rival uses the same limit (× AI_GATHER_MULT).
## 2026-10-06 the user: "much faster digging": 12 -> 30 (the brush digs 40-200 m³/s, this is the limit).
## 2026-10-06 economy pass ("oyun daha yavaş, tok hissettirmeli; hiç kazmaya gerek olmuyor"): 30 -> 10.
## Measured (headless probe, the real dig path): the old per-frame min(soil, cap) met whole-voxel lumps
## and paid ~5-9 m³/s with the default 2.2 m brush, ~20-27 with a 3.5-5 m one; terrain_tool.gd now
## banks the soil and pays it out at this rate (DRILL_BANK_TIME), so it is the real m³/s whatever the
## brush (the 2.2 m one supplies ~12-19 m³/s of soil): probe ~10 m³/s while aimed, ~8.5-9 with the heat
## vents' jams. A cannon ≈ 1 min of digging, a shell ≈ 6 s.
const DRILL_MAX_RATE := 10.0
## s of the cap the drill banks at most (the lumps of soil wait there to be paid out; a huge brush
## does not bank minutes of material).
const DRILL_BANK_TIME := 0.3

# --- Cores ----------------------------------------------------------------------------------------
const CORE_RADIUS := 2.75
## 2026-10-06 (R 60: the core ~57 m down, the crater kept): 320 -> 300, so three torpedoes
## (TORPEDO_CORE_DAMAGE 110) or ~9-10 Delici Top shots into a shelled area kill it.
const CORE_HP := 300.0
## Shell / penetrator damage to a core at 0 m from its surface; falls to 0 at CORE_BLAST_K × the
## crater radius (unscaled; the reach does not grow with CRATER_SCALE): a shell 38.5 m, a Delici Top
## penetrator 31.5 m. (R 60: was 34 and K 2.0 = 11 m for a 27 m deep core; probe: the AI's 30 shells dig
## its hole only ~12-24 m deep, ~35-45 m from the core: ~0-60 damage in all at K 7, none at K 4.5.)
const CORE_SHELL_DAMAGE := 40.0
const CORE_BLAST_K := 8.0  # 2026-10-06 R60: 7 -> 8 saves ~4-5 careful shells (~25 to kill)
## Enemy drill brush overlapping a core: damage per second.
const CORE_DRILL_DPS := 6.0
const CORE_LIGHT_RANGE := 14.0         # the core's light reaches tunnel walls this far from the centre

# --- Building -------------------------------------------------------------------------------------
const BUILD_RANGE := 22.0              # m from the eye to the placement point
const BUILD_MAX_SLOPE_DEG := 22.0      # ground normal vs. up
const BUILD_MAX_STEP := 1.6            # m of height difference across the footprint
const CANNON_COST := 600.0
## Material both sides start a match with. Kept on respawn; Game.reset_state() and the AI rival read it.
## 2026-10-06 economy pass: was CANNON_COST (a cannon at second 0); now half of one, so the match opens
## with digging: the first cannon ~25 s in for a focused digger, ~40 s digging half the time, ~1 min
## 50 s on the zones + the core pump alone; the rival's ~40-50 s in (its first pod ~1.3 min).
const START_MATERIAL := 300.0          # (CANNON_COST = 600)
const SHUTTLE_COST_HINT := 3000.0      # suggestion for scripts/craft/skiff.gd BUILD_COST
## Where each build-tool entry may stand (scripts/war/build_tool.gd; the multiplayer host checks a
## client's request with the same build_site_reason()): "home" = only on the builder's own planet,
## "any" = own or enemy planet (a foothold: an Uçaksavar to cover it, a skiff to get home),
## "enemy" = only on the enemy planet (the Sondaj Kulesi: its torpedo burrows to THAT planet's core).
## Keyed by entry id or, when a script path is given, by its file name (what actually gets built);
## anything unknown is "home". A structure built on the enemy planet keeps the builder's team.
const BUILD_SITE := {"armory": "home", "cannon": "home", "buster": "home", "flak": "any", "skiff": "any",
		"armed_skiff": "any", "torpedo_rig": "enemy", "auto_miner": "any"}


## "home" / "any" / "enemy" for a build entry (see BUILD_SITE).
static func build_site(kind: String, script_path := "") -> String:
	var key := script_path.get_file().get_basename() if script_path != "" else kind
	return str(BUILD_SITE.get(key, BASE_BUILD_SITE.get(key, "home")))      # (base pieces: end of file)


## Whether a build entry may stand under the ground (BUILD_UNDERGROUND, end of file).
static func build_underground(kind: String, script_path := "") -> bool:
	var key := script_path.get_file().get_basename() if script_path != "" else kind
	return bool(BUILD_UNDERGROUND.get(key, BUILD_UNDERGROUND.get(kind, false)))


## Why entry `kind` (script_path: what the build request names, "" = by kind) cannot stand on the
## planet under it; on_own: that planet is the builder's own. "" = it may.
static func build_site_reason(kind: String, script_path: String, on_own: bool) -> String:
	match build_site(kind, script_path):
		"any":
			return ""
		"enemy":
			return "" if not on_own else "Sadece düşman gezegenine kurulur"
	return "" if on_own else "Sadece kendi gezegenine kurulur"

# --- Cannon ---------------------------------------------------------------------------------------
const CANNON_HP := 300.0
const CANNON_FOOTPRINT := 3.2          # radius (m) kept clear around a cannon
const CANNON_RELOAD := 6.0
## Muzzle speed range (m/s). 2026-10-06, R 60 (headless probe, spawn-side cannons to the sub-point
## facing them / to our base): 27 -> ~12-16 s (lands at 15-85° elevation), 30 -> ~10-12.5 s
## (35-65°), 33 -> ~9-10.5 s, 36 -> ~7.5-9.5 s, 42 -> ~6-7 s. Below ~26 the shot barely clears the
## saddle between the planets (~22 m/s straight up from the sub-point) and turns erratic (1° -> 25-60 m).
## Escape speed is ~30.7 m/s now: the whole range clears the saddle, the faster half leaves our planet
## for good; above ~36 flights drop under ~8 s (and a drop pod could not brake in its retro band).
## 1° of barrel error moves the impact ~4.5 m at the sub-point, 6-12 m at a base (oblique arrival).
## (Was 21..34 for R 30: ~24 s down to ~10.5 s.)
const CANNON_SPEED_MIN := 28.0
const CANNON_SPEED_MAX := 36.0
const CANNON_PITCH_MIN := 5.0          # degrees above the local horizon
const CANNON_PITCH_MAX := 85.0
const SHELL_COST := 60.0               # (2026-10-06: 40; ~3 s of digging at the faster drill, was ~5 s)

# --- Shell ----------------------------------------------------------------------------------------
## Every explosive crater (planet.crater: shells, buster, torpedo end, Explosion "crater" cfgs:
## grenades, rockets, wrecks) is carved CRATER_SCALE × its radius, CRATER_SCALE × CRATER_DEPTH_SCALE ×
## its depth (cap 22 m, planet.gd); drilling, tunnels and other brushes are not. Explosion damage radii
## are × BLAST_RADIUS_SCALE (damage unchanged), the explosion FX × CRATER_SCALE^0.75 (capped).
## 2026-10-05: the user found 3.0 too much ("krater aşırı oldu, 3'te 1'ine düşür"): back to 1.0.
const CRATER_SCALE := 1.0
const CRATER_DEPTH_SCALE := 1.15
const BLAST_RADIUS_SCALE := 1.56             # (1.25 × 1.25)
const SHELL_LIFE := 40.0               # s before a shell that hit nothing is removed
const SHELL_CRATER_R := 5.5            # crater radius before CRATER_SCALE (carved: 5.5 m)
const SHELL_CRATER_DEPTH := 6.5        # density change at the centre before the scales (carved: ~7.5 m)
const SHELL_DAMAGE := 220.0            # area damage at the centre (players, bots, cannons)
const SHELL_BLAST_R := 7.5
const SHELL_IMPULSE := 16.0

# --- Uçaksavar (flak, scripts/war/flak.gd + flak_round.gd) -----------------------------------------
const FLAK_COST := 300.0
const FLAK_HP := 160.0
const FLAK_FOOTPRINT := 2.4            # radius (m) kept clear around it
const FLAK_TURN_RATE := 120.0          # deg/s: quick traverse
const FLAK_PITCH_MIN := -5.0           # degrees above the local horizon
const FLAK_PITCH_MAX := 88.0
const FLAK_SPEED := 110.0              # m/s muzzle speed of a round
const FLAK_INTERVAL := 0.55            # s between rounds (the twin barrels alternate)
const FLAK_ROUND_LIFE := 4.0           # s: a round bursts by itself after this (~430 m)
const FLAK_ROUND_COST := 0.0           # m³ per round for the player (2026-10-06 "küçük vergileri kaldır": 2 -> 0; the AI's rounds are free)
const FLAK_FUSE_R := 7.0               # proximity fuse: bursts at the closest pass within this
const FLAK_BLAST_R := 8.0              # burst damage radius (linear falloff, Game.area_damage)
const FLAK_DAMAGE := 60.0              # at the centre: ~37 at 3 m -> the skiff (180 hp) takes 4-6
const FLAK_IMPULSE := 4.0
const FLAK_SHELL_KILL_R := 6.0         # point defence: a burst this close destroys a cannon shell
# Automatic fire control (an unmanned Uçaksavar against enemy skiffs).
const FLAK_RANGE := 290.0              # covers a take-off from the other base (~270 m away; R 30: 330 / 310)
const FLAK_MIN_ALT := 3.0              # m above the ground: the skiff counts as airborne
const FLAK_REACT_MIN := 1.0            # s of continuous sight before it opens fire
const FLAK_REACT_MAX := 2.0
const FLAK_LOSE_TIME := 1.5            # s out of sight before it forgets the target
const FLAK_ERR_START := 4.5            # deg aim error on a fresh / jinking target (~21 m at 270 m)...
const FLAK_ERR_MIN := 0.6              # ...shrinking toward this on a steady one (~3 m)...
const FLAK_SETTLE := 3.0               # ...with this time constant (s of steady flight)
const FLAK_EVADE_ACCEL := 3.0          # m/s² change of the target's acceleration that counts as evasive

## Friendly fire: own-team structures (cannons, Uçaksavar, skiffs) take this share of the damage
## from their own side's shells, bullets and flak.
const FRIENDLY_FIRE := 0.25

# --- Rival team (scripts/war/rival_team.gd: the shared pool, roles, raids; ai_rival.gd: a bot) -----
const BOT_COUNT := 8                   # rival bots (spawned a few at a time over BOT_SPAWN_TIME s; 2026-10-06: 3)
const BOT_SPAWN_TIME := 1.0
const AI_SPAWN_SPACING := 7.0         # m between (re)spawn points on a spiral around the base
                                       # (radius 3 + spacing × √(count / π): ~14 m for 8, ~36 m for 70)
## Roles by share of the living bots: at least 1 engineer and, from 3 bots up, at least 1 guard;
## 8 bots = 2 Mühendis (one builds, one is free to fire the cannons, the Delici Top and the drop pods),
## 4 Kazıcı, 2 Muhafız; while the engineers are dead a guard takes the job (the miners keep digging),
## and the respawned bot fills the free role.
const ROLE_MINER_SHARE := 0.5          # Kazıcı
const ROLE_ENGINEER_SHARE := 0.2       # Mühendis (AI_MAX_BUILDERS build at a time, the rest fire,
                                       # repair or haul / dig; 2026-10-06: 0.1 = 1 of 3 bots)
const AI_MAX_BUILDERS := 1             # (kept at 1: the second engineer stays free as the pod gunner)
# --- Team economy ---
## The pool earns min(TEAM_INCOME_CAP, digging bots × DRILL_MAX_RATE × AI_GATHER_MULT) m³/s, plus its
## zones and core pump (control_points.gd) and prospecting (VN_BOT_GATHER). The terrain itself is dug by
## at most AI_MAX_BRUSHES bots at a time (rotating, matters with many bots), the others dig with the
## animation and FX only.
## 2026-10-06 economy pass (headless probe, 8 bots): only ~0.8-1.8 bots are "digging" on average (pod
## crews, guards, zone fights), so one digger is worth 6 m³/s and the cap is 7: ~5 m³/s from the bots +
## ~2.9 from 6 zones and the pump ≈ a player who digs half the time (~7.5 m³/s). Before: up to 8 +
## 8 pump + 2.5 a zone = ~31 m³/s (1870 m³/min), the pool piled up ~9500 m³ unspent in 8 min.
const TEAM_INCOME_CAP := 7.0           # (8; 25 before the zones; 10 for 3 bots)
const AI_MAX_BRUSHES := 4
const AI_BRUSH_SLOT := 6.0             # s a bot keeps a real brush before it rotates on
## Team-wide pace of cannon fire: at least this many s between two rival shells (twice that while
## it still saves for structures). ~3 shells / min at most (2026-10-06: 25 s).
const AI_TEAM_FIRE_GAP := 20.0
# --- Performance budget for many bots ---
## LOD by distance to the camera AND by rank (nearest first): near = full rate (think ~8 Hz, move
## 15 Hz, pose + foot IK every frame, cover search), mid = think 2 Hz, move 8 Hz, pose 12 Hz;
## far = think ~1.3 Hz, move 4 Hz, pose 3 Hz (2 Hz off screen), no cover search, no shadow.
const AI_LOD_NEAR := 40.0              # m (2026-10-06, R 60: 25; the fights reach ~40 m now)
const AI_LOD_MID := 90.0               # m (60)
const AI_NEAR_MAX := 10                # at most this many bots near...
const AI_MID_MAX := 30                 # ...and this many near + mid, however close they stand
const AI_SEPARATION := 1.4             # m: bots push each other apart closer than this (crowd)
const AI_STRUCT_CLEARANCE := 0.8       # m: and keep this clear of structure footprints
const AI_LIGHT_MAX := 6                # bots with real lights (helmet lamp, muzzle flash): the nearest
const AI_FX_MAX := 6                   # dig beam / particle FX: the nearest diggers; others dust puffs
const AI_VOICE_MAX := 8                # bots that may play sounds: the nearest
const AI_MAX_SHOOTERS := 5             # bots allowed to fire at the player at once (the rest reposition)
const AI_LOS_PER_FRAME := 3            # density line-of-sight marches per physics frame, team-wide
const AI_COVER_EVALS_PER_FRAME := 4    # cover candidates tested per physics frame, team-wide
const AI_RAGDOLL_MAX := 6              # live ragdolls; older (and settled) corpses freeze in place
const AI_HELP_MAX := 6                 # allies answering one call for help
## 2026-10-06 tok ("vuruşlar ... çok daha tok olsun"): longer fights with the same punch per hit: every
## hp pool × 1.35 (player.gd HP_MAX too), the damage per hit unchanged (hit reactions keep their weight):
## rifle 3 -> 4 body hits, SMG 6 -> 8, a bot's rifle on the player 6 -> 8 (100 -> 135).
const AI_HP := 135.0
const AI_RESPAWN := 13.0               # s: the corpse is left and the bot boards its wave (respawn_waves.gd; = RESPAWN_TIME, 10 → 13)
const AI_WALK_SPEED := 2.7             # (2026-10-06 tok: 3.2 -> 2.7)
const AI_RUN_SPEED := 5.0              # sprinting between cover, fleeing (2026-10-06 tok: 6.0 -> 5.0)
const AI_STRAFE_SPEED := 3.1           # (2026-10-06 tok: 3.8 -> 3.1)
## A strafe lasts its picked time × this (2026-10-06 tok: new, 1.0 before): fewer left-right flips. A near
## miss no longer cuts a strafe that still has more than AI_STRAFE_HOLD s to run (a hit still does).
const AI_STRAFE_TIME_K := 1.5
const AI_STRAFE_HOLD := 0.4
const AI_THINK := 0.25                 # work decisions
const AI_COMBAT_THINK := 0.15          # combat decisions (~7 Hz per bot, staggered)
const AI_DIG_HZ := 5.0                 # real brushes per second for a bot holding a brush slot
const AI_DIG_RADIUS := 2.0
const AI_DIG_RATE := 16.0              # same density rate as the player's drill (terrain_tool.gd RATE; 7 before 2026-10-06)
## Per digging bot, × DRILL_MAX_RATE (the team total is capped at TEAM_INCOME_CAP).
const AI_GATHER_MULT := 0.6            # (0.45 of DRILL_MAX_RATE 30 = 13.5 a digger; now 6)
# Where the bots work on the planet, m from the base (2026-10-06, R 60: ~×1.5 the R 30 values).
const AI_MINE_MIN := 7.0               # miners' pits (each bot its own spot on a spiral; 8 bots: 7-22 m)...
const AI_MINE_MAX := 45.0              # (5 / 30)
const AI_PIT_DEPTH := 3.0              # ...a pit this deep: move on
const AI_GUARD_RADIUS := 32.0          # guards patrol this far around the base (6-14 m around structures; 22)
const AI_BUILD_AHEAD := 20.0           # structures up to this far toward our planet... (14)
const AI_BUILD_SIDE := 16.0            # ...and this far to either side (12)
# Combat (on foot). The horizon is ~14 m away on the 60 m planet (eye height, flat ground); over the
# hills a standing head shows to ~23 m on average, 30-40 m from a rise (2026-10-06 probe; R 30: ~16 m).
const AI_SIGHT_RANGE := 60.0           # sees the player on foot on its planet this far (line of sight; 40) (2026-10-06 tok: 70 -> 60)
const AI_PREFERRED_RANGE := 18.0       # likes to fight from about this far (12)
const AI_NEAR_MISS := 2.0              # a shot passing this close counts as being shot at
const AI_HELP_RANGE := 45.0            # calls allies within this when attacked (30)
const AI_CALM_AFTER := 10.0            # s without seeing / hearing the enemy: back to work
const AI_FLEE_HP := 0.35               # flees (breaks line of sight) below this share of hp
const AI_REGEN := 3.0                  # hp/s once AI_REGEN_DELAY s passed without damage
const AI_REGEN_DELAY := 8.0
const AI_MAG := 15                     # rounds, then a reload window
const AI_RELOAD := 2.4
const AI_ACC_MOVING := 0.55            # hit chance multipliers: moving...
const AI_ACC_UNDER_FIRE := 0.7         # ...being shot at...
const AI_ACC_SETTLED := 1.3            # ...standing still / peeking from cover for 1 s
const AI_FLINCH := 0.35                # s of no shooting after a hit
const AI_DODGE_CHANCE := 0.15          # a dodge (slide / jump / jet hop) when a shot passes close (× agility) (2026-10-06 tok: 0.3 -> 0.15)
const AI_JET_HOP := 6.0                # m/s up for a jet hop over an obstacle or a dodge
const AI_CLIMB_SPEED := 3.5            # m/s jet climb out of a deep pit / shaft
# Combat movement like a player (ai_rival.gd "Slides and jumps"): the player's slide rules
# (stance.gd), real jumps under gravity, believable reaction delays, cooldowns, a per-bot agility.
# 2026-10-06 tok: the slide mirrors the player's heavier one (stance.gd): a smaller burst that carries.
const AI_SLIDE_BOOST := 1.25           # × the running speed at the start... (tok: 1.35 -> 1.25)
const AI_SLIDE_MAX := 7.5              # ...capped (m/s) (tok: 9.5 -> 7.5)
const AI_SLIDE_FRICTION := 4.0         # m/s² + AI_SLIDE_DRAG × speed: ~0.8 s on the flat (tok: 5.0 -> 4.0)
const AI_SLIDE_DRAG := 0.3             # (tok: 0.35 -> 0.3)
const AI_SLIDE_SLOPE := 1.0            # share of the gravity along the floor (downhill: longer)
const AI_SLIDE_END := 2.2              # m/s: slower ends it
const AI_SLIDE_MAX_T := 1.4            # s (up to 1.8× while still fast downhill)
const AI_SLIDE_STEER := 1.1            # rad/s toward the cover it slides into (2026-10-06 tok: 1.5 -> 1.1)
const AI_SLIDE_CD := 5.0               # s between slides (scaled by agility) (2026-10-06 tok: 2.5 -> 5.0)
const AI_JUMP_V := 4.6                 # m/s: a real jump (~1.35 m at 0.8 g)
const AI_JUMP_SIDE := 3.5              # m/s sideways in a jump-strafe (2026-10-06 tok: 4.5 -> 3.5)
const AI_AIR_ACCEL := 2.0              # m/s² of steering in the air (the arc stays an arc)
const AI_DODGE_CD := 4.0               # s between dodges (scaled by agility) (2026-10-06 tok: 2.2 -> 4.0)
const AI_REACT_MIN := 0.3              # s: a reaction comes this long after the threat... (2026-10-06 tok: 0.2 -> 0.3)
const AI_REACT_MAX := 0.75             # ...up to this (× the bot's reaction trait) (2026-10-06 tok: 0.5 -> 0.75)
const AI_PEEK_JUMP := 0.1              # chance a peek from cover is a jump-peek over the rim (× agility) (2026-10-06 tok: 0.25 -> 0.1)
const AI_ACC_SLIDE := 0.5              # hit chance × while sliding...
const AI_ACC_AIR := 0.4                # ...and while in the air
const AI_RIFLE_STRUCT_DAMAGE := 8.0    # raiders shooting our cannons / Uçaksavar
const AI_REPAIR_RATE := 12.0           # hp/s the engineer repairs a damaged structure...
const AI_REPAIR_COST := 0.5            # ...for this many m³ per hp
# Raids (raiders fly the team's skiff to our planet; the skiff's AI pilot: scripts/craft/skiff.gd).
# On since 2026-10-05; the timing / crew / variant knobs: "AI pilot and skiff raids" at the end.
# Off: the raider role is only a base guard ("Muhafız") and the team never builds or touches a skiff.
const RAIDS_ENABLED := true
# 2026-10-06 the user: first contact at about 1 minute (pods, POD_FIRST_AFTER), so the raids come sooner
# and more often too; the R 30 values in brackets. Later the same day ("oyun daha yavaş, tok
# hissettirmeli") back toward a calmer match (tok notes).
const RAID_FIRST_AFTER := 180.0        # s into the match before the first raid (240) (2026-10-06 tok: 120 -> 180)
const RAID_MIN_INTERVAL := 160.0       # s between raids (210) (2026-10-06 tok: 120 -> 160)
const RAID_MAX_TIME := 180.0           # s on our planet before they fly home anyway (240)
const RAID_RETREAT_HP := 0.4           # a raider below this share of hp calls the retreat
const RAID_LAND_MIN := 25.0            # landing site: this far from our base... (15)
const RAID_LAND_MAX := 40.0            # ...at most, preferably hidden behind terrain (25)
const RAID_CALM_TIME := 8.0            # s unopposed before the digger starts the shaft
const RAID_DIG_RATE := 0.8             # m/s the shaft deepens (~70 s down to the core ~57 m down; 0.4)
const RAID_DIG_RADIUS := 1.5
const RAID_STRUCT_RANGE := 55.0        # raiders look for our structures this far from the landing (35)
const AI_MAX_CANNONS := 3
const AI_MAX_FLAKS := 2                # Uçaksavar: built alternately with the cannons
const AI_RESERVE := 80.0               # material the AI keeps before spending on shells
## Aim error. 1° of barrel error moves the impact ~4.5 m at the point facing them (6-12 m at our
## base, oblique arrival). Probe (R 60, 2026-10-06, spawn-side cannons, 40 shots each): at 3° the
## impacts land ~6-10 m off on average (none off the planet), at 0.5° ~1.2-2.7 m (4.7-5.4 m at our
## base from a side cannon). The R 30 numbers were about the same (7.5-11 / 1.6-4.5 m): kept.
const AI_AIM_ERROR_START := 3.0        # degrees of random aim error on the first shot...
const AI_AIM_ERROR_MIN := 0.5          # ...shrinking toward this (~1-3 m: inside the 5.5 m crater)...
const AI_AIM_ERROR_DECAY := 0.72       # ...by this factor after every impact it observes
const AI_SPEED_ERROR := 0.02           # relative muzzle-speed error, scaled like the aim error
## The AI's firing solution: muzzle speeds tried (fractions of CANNON_SPEED_MIN..MAX: 28.8, 31.2, 33.6
## and 35.6 m/s, ~13 s down to ~8 s flights; the elevation is refined around the best grid hit), the
## worst landing it still accepts, and its adjust-fire limits. (R 60 probe: every spot around the
## base solves to < 0.3 m at the point facing them, < 5 m at our base; was [0.35, 0.55, 0.75, 0.95]
## of 21..34.)
const AI_SOLVE_SPEEDS := [0.1, 0.4, 0.7, 0.95]
const AI_SOLVE_MAX_MISS := 12.0        # m: no trajectory lands this close -> try another cannon
const AI_CORRECTION_MAX := 15.0        # m: adjust-fire offset limit
const AI_OBSERVE_RANGE := 30.0         # m: impacts farther than this from the aim point are ignored
const AI_TARGET_CANNON_CHANCE := 0.35  # chance to shell one of our cannons instead of the core region
const AI_FIGHT_RANGE := 48.0           # rifle range on foot (hit chance halves out here; 35 at R 30) (2026-10-06 tok: 55 -> 48)
const AI_RIFLE_INTERVAL := 0.36        # s between rifle shots (bursts of AI_RIFLE_BURST) (2026-10-06 tok: 0.32 -> 0.36)
const AI_RIFLE_BURST := 3
const AI_RIFLE_PAUSE := 1.1
const AI_RIFLE_DAMAGE := 18.0           # (2026-10-05: was 12; see "Smarter, more dangerous bots" at the end)
const AI_RIFLE_HIT := 0.45             # hit chance at point blank, falls to half at AI_FIGHT_RANGE
## The bot's rifle against the player's skiff (with the player aboard) when it sees it close.
const AI_SKIFF_RIFLE_RANGE := 60.0     # (45 at R 30)
const AI_SKIFF_RIFLE_DAMAGE := 4.0     # low: the skiff has 180 hp
const AI_SKIFF_REACT := 1.5            # s of sight before it starts shooting

# ==================================================================================================
# New weapons (2026-10-05). Each block belongs to one file set; tune them here.
# ==================================================================================================

# --- El bombası (G, scripts/player/hand_action.gd; flies in scripts/items/projectiles.gd "hand") ---
const GRENADE_COST := 12.0             # m³ of material per grenade (paid when the pin comes out)
const GRENADE_FUSE := 3.5              # s from the pin (hold G to cook it)
const GRENADE_THROW_SPEED := 15.0      # m/s: ~28 m at 45° on 0.8 g, never near escape (~30.7)
const GRENADE_RADIUS := 5.0
const GRENADE_DAMAGE := 160.0          # at the centre (linear falloff) (2026-10-06 tok: 130 -> 160 with AI_HP 135: kill radius ~1.0 m, was 1.35)
const GRENADE_DIRECT := 25.0           # a direct hit on a character before it goes off
const GRENADE_IMPULSE := 10.0          # (2026-10-06 tok: 12 -> 10: a blast shoves, it does not fling)
const GRENADE_CRATER := 1.8            # crater radius (m): digs a bot out of a shallow trench
const GRENADE_LOB := 2.8               # m/s added along the view's up (a slight lob over the aim)
const GRENADE_AUTO_THROW := 0.5        # s of fuse left when an over-cooked grenade leaves the hand anyway

# --- Tünel tarayıcı (Q, wrist; scripts/items/tunnel_scanner.gd, scripts/war/tunnel_log.gd) ---------
const SCAN_RANGE := 130.0              # m (straight line): the whole planet you stand on (R 60: 120 m across; 90 at R 30)
const SCAN_TIME := 8.0                 # s the markers stay
const SCAN_COOLDOWN := 20.0            # s from one pulse to the next
const SCAN_TUNNEL_DEPTH := 1.2         # m below the original surface before a dug spot counts as a tunnel
const SCAN_WAVE_SPEED := 60.0          # m/s of the pulse wave: crosses the planet (120 m) in ~2 s (40)

# --- Roketatar (key 7, scripts/items/rocket_launcher.gd; the rocket flies in scripts/items/rockets.gd) 
const ROCKET_SPEED := 26.0             # m/s off the tube... (2026-10-06 tok: 30 -> 26, a heavier round you see go)
const ROCKET_MAX_SPEED := 66.0         # ...motor accelerates it to this... (2026-10-06 tok: 80 -> 66; 100 m in ~2 s)
const ROCKET_BURN := 1.6               # ...for this many s, then it coasts (gravity pulls)
const ROCKET_LIFE := 8.0
## 2026-10-05 the user found the guns weak ("silahlar güçsüz"): 170 -> 200 so the inner blast is a sure
## kill (a bot within ~3.5 m of the burst: falloff f = 1 - d / (radius × 1.56 × 1.1), damage × (0.55 f² + 0.45 f);
## was ~2.8 m); a direct hit (+ROCKET_DIRECT) always kills. 2026-10-06 tok (AI_HP 135): 200 -> 240, the inner
## kill ~3.0 m (3.5 at 200 / 100 hp).
const ROCKET_DAMAGE := 240.0           # blast at the centre
const ROCKET_DIRECT := 70.0            # + direct hit
const ROCKET_RADIUS := 5.5
const ROCKET_IMPULSE := 12.0           # (2026-10-06 tok: 15 -> 12)
const ROCKET_CRATER := 2.4
const ROCKET_RELOAD := 2.6             # s (single tube)
const ROCKET_SELF_MULT := 0.6          # share of the blast the shooter takes (point-blank shots hurt)
const ROCKET_AIRBURST := 0.5           # damage / radius share of a rocket that times out in the air
const ROCKET_KICK := 1.0               # m/s the shot shoves the shooter back (light: a recoilless tube)

# --- Kinetik itici (key 6, scripts/items/kinetic_pusher.gd) ----------------------------------------
## A rare, heavy blast: 2 charges, slow refill, 10 m³ a shot. It shoves along a 34° cone out to 16 m,
## tears the ground out along the cone's footprint (a scoop / trench of DIG brushes, host only, synced)
## and throws the torn soil and the surface rocks out as flying chunks.
const PUSH_RANGE := 16.0               # m
const PUSH_CONE_DEG := 34.0            # half angle of the shock cone
const PUSH_SPEED_MAX := 34.0           # m/s given at point blank (> the into-space fling ~26 m/s; 28 at R 30)
const PUSH_SPEED_MIN := 7.0            # m/s at PUSH_RANGE
const PUSH_FALLOFF := 2.0              # speed = min + (max - min) × (1 - d / range)^this: space < ~2.5 m, big arcs to ~11.5 m
const PUSH_UP_BIAS := 0.45             # share of "up" mixed into the push direction (gets them airborne)
const PUSH_DAMAGE := 15.0
const PUSH_PLAYER_K := 0.8             # players (ragdoll fling) get this share of the speed
const PUSH_CHARGES := 2                # capacitor charges...
const PUSH_RECHARGE := 4.5             # ...s to refill one...
const PUSH_COST := 0.0                 # ...paid in m³ of material per shot (2026-10-06 "küçük vergileri kaldır": 10 -> 0)
const PUSH_WINDUP := 0.22              # s of coil whine between the click and the blast
const PUSH_FOCUS_CONE := 0.45          # RMB focus: the cone narrows to this share...
const PUSH_FOCUS_RANGE := 1.35         # ...and reaches this much farther
const PUSH_RECOIL := 3.5               # m/s the blast shoves the shooter back
const PUSH_BODY_K := 1.4               # loose rigid bodies: impulse = dir × speed × mass × this...
const PUSH_BODY_MASS_CAP := 140.0      # ...with the mass capped (the skiff is thrown, not just rocked)
const PUSH_SHELL_K := 1.4              # projectiles in flight (enemy shells, torpedoes, rockets) get dir × speed × this
const PUSH_GRENADE_K := 0.8            # grenades in flight / lying in the cone get dir × speed × this
const PUSH_TEAR_STAMPS := 7            # ground tearing: DIG brushes per blast at most (2 per physics frame)...
const PUSH_TEAR_R := [1.3, 2.4]        # ...radius far .. near (m)...
const PUSH_TEAR_DEPTH := [1.0, 2.8]    # ...and density change at the centre (≈ m dug) far .. near
const PUSH_CHUNKS := 40                # flying rock / soil chunks alive at once (pooled)
## A bot shoved faster than this loses its footing (ai_rival.gd fling()): it flies a kinematic arc
## and lands hard; at 0.85 × the local escape speed (~26 m/s on the surface; R 30: ~18) it goes ragdoll into
## space instead (the team respawns it). With the pusher falloff: closer than ~2.5 m a launch into space,
## ~2.5-11.5 m a big arc, farther a stagger. (2026-10-06: PUSH_SPEED_MAX 28 -> 34 keeps a band at all.)
const AI_FLING_KO := 9.0
const AI_FLING_ESCAPE_K := 0.85
const AI_FLING_LAND_SAFE := 9.0        # m/s of landing / wall speed a flung bot takes without harm...
const AI_FLING_LAND_DMG := 4.0         # ...then this many hp per m/s above it

# --- Sondaj torpidosu (scripts/war/torpedo.gd) ------------------------------------------------------
# The player no longer FIRES it: it is set into the ground by a Sondaj Kulesi (build tool, enemy
# planet only, scripts/war/torpedo_rig.gd; Torpedo.plant). The hand launcher
# (scripts/items/torpedo_launcher.gd, was key 8) is out of the loadout and the armory; the flight
# numbers below are still used by the AI's launches (AI_TORPEDO_LAUNCHES) and a launched torpedo.
const TORPEDO_COST := 250.0            # m³ per torpedo (expensive)
const TORPEDO_SPEED_MIN := 28.0        # launch speed range (mouse wheel), same as the cannon:
const TORPEDO_SPEED_MAX := 36.0        # reaches the other planet in ~8-14 s (21..34 at R 30)
const TORPEDO_LIFE := 40.0             # s of flight before a miss is removed
const TORPEDO_RELOAD := 6.0
## Sondaj Kulesi (drilling rig): one torpedo per rig, about one shot's worth = the old launcher's
## craft price (500) + one torpedo (TORPEDO_COST). After the build it arms for TORPEDO_RIG_ARM_TIME s
## (winch lowers the torpedo, the drill spins up, sparks and dust), then the torpedo burrows from
## there straight toward the core (PLANT -> BURROW, its own hp and interception). The rig stays as a
## structure with its own hp; destroyed while arming, no torpedo.
const TORPEDO_RIG_COST := 500.0 + TORPEDO_COST
const TORPEDO_RIG_HP := 300.0
const TORPEDO_RIG_FOOTPRINT := 2.2     # radius (m) kept clear around it
const TORPEDO_RIG_ARM_TIME := 6.0      # s from the end of the assembly to the torpedo biting in
const TORPEDO_BURROW_SPEED := 2.0      # m/s through the soil toward the core (~30 s from the surface, ~57 m; 1.1 at R 30)
const TORPEDO_DIG_RADIUS := 1.0        # the tunnel it leaves (defenders can follow it down)
const TORPEDO_HP := 60.0               # bullets / blasts / an enemy drill kill it
const TORPEDO_CORE_DAMAGE := 110.0     # reaching the core (CORE_HP 300)
const TORPEDO_HEAR_RANGE := 70.0       # m: its drilling is audible this far (the defender hears it; 50)
const TORPEDO_DRILL_DPS := 30.0        # an enemy drill biting into it (60 hp: ~2 s of drilling)
const TORPEDO_BLAST_R := 7.0           # the blast at the core (area damage around the tunnel's end)...
const TORPEDO_BLAST_DAMAGE := 160.0
const TORPEDO_END_CRATER := 3.5        # ...and the cavity it leaves there (m)
const TORPEDO_DEATH_R := 3.0           # killed on the way: a small blast, no core damage
const TORPEDO_DEATH_DAMAGE := 35.0

# --- Delici top (bunker buster; build tool; scripts/war/buster.gd extends cannon.gd) --------------
const BUSTER_COST := 1100.0            # m³ to build
const BUSTER_HP := 260.0
const BUSTER_FOOTPRINT := 3.0
const BUSTER_RELOAD := 22.0            # s: slow
const BUSTER_SHELL_COST := 140.0       # m³ per penetrator
const BUSTER_PENETRATE := 25.0         # m it bores on through the soil after the impact (10 at R 30)...
                                       # (2026-10-06: the core is ~57 m down; 25 m under a 20-30 m deep crater
                                       # puts the blast ~5-15 m from it: ~30-50 a shot, none from fresh ground)
const BUSTER_BORE_TIME := 1.2          # ...over this many s, then explodes down there (0.7)
const BUSTER_CRATER_R := 4.5
const BUSTER_CRATER_DEPTH := 6.0
const BUSTER_DAMAGE := 180.0           # area damage at the (deep) blast
const BUSTER_BLAST_R := 6.0
const BUSTER_CORE_DAMAGE := 60.0       # Core.blast_all max (a plain shell: CORE_SHELL_DAMAGE 40; was 50), to 0 at
                                       # CORE_BLAST_K × BUSTER_CRATER_R = 31.5 m from the core's surface
const BUSTER_IMPULSE := 18.0
const BUSTER_BORE_RADIUS := 1.1        # the shaft it bores (a second shot down the same hole goes deeper)

# --- Silahlık (armory, build tool; scripts/war/armory.gd) and crafting (scripts/war/craft.gd) -------
## A match starts with the drill (1) and the build tool (2) only; every gun is made at a Silahlık
## (F: the crafting panel) and keeps its key: 3 rifle, 4 shotgun, 5 sniper, 6 pusher, 7 rocket
## (the torpedo is built now: Sondaj Kulesi, TORPEDO_RIG_COST). Grenades (G) come in stacks.
## Crafted guns survive death; a new match takes them away.
const ARMORY_COST := 400.0             # m³ to build
const ARMORY_HP := 420.0
const ARMORY_FOOTPRINT := 3.2          # radius (m) kept clear around it
const CRAFT_COST := {"rifle": 150.0, "shotgun": 200.0, "sniper": 350.0, "pusher": 300.0, "rocket": 450.0,
		"grenade": 60.0, "rail": RAIL_CRAFT_COST, "smg": SMG_CRAFT_COST, "dirt": 200.0, "plasma": 400.0, "mortar": 450.0,
		"pistol": PISTOL_CRAFT_COST, "revolver": REVOLVER_CRAFT_COST, "mpistol": MPISTOL_CRAFT_COST}   # (sidearms: SIDEARMS block)
const CRAFT_TIME := {"rifle": 5.0, "shotgun": 6.0, "sniper": 9.0, "pusher": 8.0, "rocket": 10.0,
		"grenade": 4.0, "rail": RAIL_CRAFT_TIME, "smg": SMG_CRAFT_TIME, "dirt": 5.0, "plasma": 8.0, "mortar": 9.0,
		"pistol": PISTOL_CRAFT_TIME, "revolver": REVOLVER_CRAFT_TIME, "mpistol": MPISTOL_CRAFT_TIME}
const GRENADE_STACK := 5               # grenades per craft...
const GRENADE_MAX := 15                # ...carried at most
## Reserve a freshly made gun brings along (on top of its full magazine; reloads still buy the rest).
const CRAFT_RESERVE := {"rifle": {"ammo_std": 60, "ammo_ap": 10}, "shotgun": {"ammo_shell": 16},
		"sniper": {"ammo_sniper": 10}, "rocket": {"ammo_rocket": 3}, "rail": {"ammo_rail": RAIL_RESERVE},
		"smg": {"ammo_smg": SMG_RESERVE}, "mortar": {"ammo_mortar": 6},
		"pistol": {"ammo_pistol": PISTOL_RESERVE}, "revolver": {"ammo_magnum": REVOLVER_RESERVE},
		"mpistol": {"ammo_pistol": MPISTOL_RESERVE}}
const CRAFT_REFUND := 1.0              # share of the price back when the armory dies mid-craft

# --- AI use of the new weapons ---------------------------------------------------------------------
# The rival team (scripts/war/rival_team.gd "AI use of the new weapons", ai_rival.gd the same section).
## How often the team scans for torpedoes / assigns its weapon crews (s).
const AI_WX_SCAN := 0.5
# El bombası (combat): a bot whose target (the player) hid for a while, or sits in a pit / tunnel,
# lobs a grenade at the last known position. Only near bots (lod 0-1) that held a shooter token
# lately; GRENADE_COST from the pool; caps team-wide and per bot.
const AI_GRENADE_MIN_RANGE := 8.0      # m from the bot to the target...
const AI_GRENADE_MAX_RANGE := 25.0     # ...(the throw is capped at GRENADE_THROW_SPEED anyway)
const AI_GRENADE_HIDDEN_MIN := 2.5     # s out of sight before it throws at the last known position...
const AI_GRENADE_MEMORY := 12.0        # ...but not when that position is older than this
const AI_GRENADE_PIT_DEPTH := 1.2      # m below the original surface: the target is in a pit / tunnel
const AI_GRENADE_TOKEN_MEM := 6.0      # s: a bot that held a shooter token this recently may throw
const AI_GRENADE_TEAM_GAP := 6.0       # s between two grenades team-wide...
const AI_GRENADE_BOT_COOLDOWN := 15.0  # ...and per bot
const AI_GRENADE_RETRY := 3.0          # s before a bot tries again after a throw it could not solve
const AI_GRENADE_SOLVE_GAP := 0.25     # s between two arc solves team-wide (a solve costs ~1-2 ms)
## Lob arc: elevations tried (degrees, in this order), the worst predicted landing error it accepts
## (m, like projectiles.gd: Game.gravity_at + a little drag, the density field as the ground).
const AI_GRENADE_ELEVATIONS := [45.0, 60.0, 32.0]
const AI_GRENADE_ACCEPT := 3.0
const AI_GRENADE_ALLY_CLEAR := 6.5     # m: no throw when an ally stands this close to the landing
const AI_GRENADE_FUSE := 3.2           # s from the throw (the bot cooks it a little during the wind-up)
const AI_GRENADE_WINDUP := 0.55        # s of arm wind-up before it leaves the hand
const AI_GRENADE_WARN_RANGE := 8.0     # m: "El bombası!" when a bot grenade lands this close to the player
## Bots within GRENADE_RADIUS + this of a live grenade of the player sprint away (AI_GRENADE_FLEE_TIME s).
const AI_GRENADE_FLEE := 1.5
const AI_GRENADE_FLEE_TIME := 1.6
# Delici top: one is built after the base's cannons and Uçaksavar (rebuilt when destroyed); an
# engineer mans it like a cannon (the same incremental solve, aim error and adjust-fire) against the
# ground above our core: the near side facing them, preferring the deepest crater there.
const AI_MAX_BUSTERS := 1
const AI_BUSTER_FIRE_GAP := 35.0       # s between two penetrators (twice that while saving for a structure; 45)
const AI_BUSTER_STAND := 4.4           # m behind the breech where the gunner stands
const AI_BUSTER_TARGET_ARC := 12.0     # m around the near-side point searched for the deepest crater (7)
const AI_BUSTER_RETRY := 25.0          # s before trying again when no trajectory lands
const AI_BUSTER_TASK_TIME := 60.0      # s a gunner may take before the team gives the job up
# Sondaj torpidosu: the team launches one at us now and then (an engineer, else a guard, walks to a
# spot facing our planet, shoulders a launcher and fires; Torpedo.fire, TORPEDO_COST from the pool).
## OFF (2026-10-05): the torpedo is a built rig now (Sondaj Kulesi, enemy planet only) and the AI
## cannot reach our planet while RAIDS_ENABLED is false, so it launches none. Interception of OUR
## torpedoes on its planet (below) stays on whatever this says.
const AI_TORPEDO_LAUNCHES := false
const AI_TORPEDO_FIRST_AFTER := 180.0  # s into the match before the first...
const AI_TORPEDO_GAP := 165.0          # ...then one every this many s (while the pool affords it + reserve)
const AI_TORPEDO_RETRY := 30.0         # s after a launch that did not happen (no solution, interrupted)
const AI_TORPEDO_SPOT_AHEAD := 10.0    # m from the base toward our planet: the launch spot (7)
const AI_TORPEDO_AIM_TIME := 1.2       # s it holds the aim (tube raised) before it fires
const AI_TORPEDO_TASK_TIME := 60.0     # s the launcher may take before the team gives the job up
# Our torpedo burrowing into their planet: the nearest guards (then miners) dig down at it (their
# brush overlapping it hurts it, torpedo.gd TORPEDO_DRILL_DPS) and shoot it when they see it.
const AI_INTERCEPTORS := 2             # bots per torpedo
const AI_INTERCEPT_SIDE := 2.5         # m: the second interceptor digs this far to the side
const AI_INTERCEPT_DIG_RADIUS := 1.6   # brush radius (always a real brush, outside AI_MAX_BRUSHES)
const AI_INTERCEPT_DIG_RATE := 16.0    # density per second (the player's drill: 16; was 9 against a 1.1 m/s torpedo)
const AI_INTERCEPT_REACH := 1.8        # m from the bot's middle toward the drill head: the brush centre
const AI_INTERCEPT_CRAWL := 2.0        # m/s it squeezes sideways along its own tunnel toward the head
const AI_INTERCEPT_SHOOT_RANGE := 14.0 # m: shoots the torpedo when it sees it this close...
const AI_INTERCEPT_HIT := 0.4          # ...each round of a burst hits with this chance (AI_RIFLE_DAMAGE;
                                       # 0.4 × 18 = 7.2 per round, as 0.6 × 12 before the damage change)
const AI_INTERCEPT_EXIT_TIME := 50.0   # s it may take to climb back out of its hole afterwards (30: holes run deeper)
# Enemy footholds (rival_team.gd "Enemy footholds", ai_rival.gd foothold): structures we built on
# THEIR planet (Sondaj Kulesi, Uçaksavar; parked skiffs are left alone) get guards sent at them,
# rifles at AI_RIFLE_STRUCT_DAMAGE. A rig still arming comes first and also pulls miners.
const AI_FOOTHOLD_SCAN := 0.5          # s between the team's scans
const AI_FOOTHOLD_ATTACKERS := 3       # bots per foothold...
const AI_FOOTHOLD_RIG_ATTACKERS := 6   # ...per Sondaj Kulesi that is still arming

# --- Weapon feel (2026-10-05) ------------------------------------------------------------------------
# The user found the guns weak ("silahlar güçsüz", "öldürmek uzun"). Per-gun damage lives with each gun:
# rifle.gd AMMO (Standart 40: 3 body / 2 head, Delici 95: 2 body / 1 head), shotgun.gd (19 × 9 pellets,
# full to 9 m, 40 % at 28 m: one shell kills to ~10 m from the hip, two to ~15-18 m), sniper.gd
# BODY_DMG 110 (one body shot kills), ROCKET_DAMAGE above (inner blast ~3.5 m kills). Bots: AI_HP 100,
# AI_REGEN 3 hp/s only after AI_REGEN_DELAY 8 s without a hit (never between bursts). Every gun also
# buffers a click made during its cooldown (PRESS_BUFFER) and the helmet counts outside the hit capsule
# (gun_feel.gd helmet_sweep).
# 2026-10-06 tok ("vuruşlar ... çok daha tok olsun"): the hp pools grew (AI_HP / player HP_MAX 100 -> 135)
# and the damage per hit stayed, so every hit keeps its punch and a fight takes ~1/3 more of them:
# Standart 4 body / 2 head, Delici 2 / 1, SMG 8, shotgun one shell to ~6-7 m, sniper BODY_DMG 140 and
# RAIL_DAMAGE 140 (still one-shot bodies), ROCKET_DAMAGE 240 (inner ~3 m), GRENADE_DAMAGE 160, MELEE 70
# (2 hits). Full-auto rates ~-13 % (rifle 9 -> 7.8/s, SMG 15.5 -> 13.5/s), heavier recoil with a slower
# recovery (gun_feel.gd KICK_K / GUN_KICK_K / SNAP_RECOVER_K / CLIMB_RECOVER).

# --- Melee / handling ------------------------------------------------------------------------------
# Dipçik vuruşu (V, on foot: scripts/player/melee.gd) and the weapon handling of every hand item
# (scripts/items/handling.gd: wall pull-back, inspect, aim foley).
const MELEE_DAMAGE := 70.0             # 2 hits kill a bot (AI_HP 135) or a player (HP_MAX 135) (2026-10-06 tok: 55 -> 70)
const MELEE_RANGE := 1.6               # m from the eye
const MELEE_RADIUS := 0.35             # m: half thickness of the swept volume (a body this far off the line counts)
const MELEE_CONE_DEG := 30.0           # aim help: a body this far off the crosshair inside the range still gets hit
const MELEE_TIME := 0.45               # s, the whole swing (wind-up, strike, recovery)
const MELEE_HIT_AT := 0.16             # s into the swing: the strike lands
const MELEE_COOLDOWN := 0.8            # s from one swing to the next
const MELEE_KNOCKBACK := 4.0           # m/s shove on a survivor along the swing (players: velocity) (2026-10-06 tok: 5 -> 4)
const MELEE_FLING := 5.5               # m/s stagger handed to a bot's fling() (< AI_FLING_KO: no knock-out) (2026-10-06 tok: 6.5 -> 5.5)
const MELEE_KILL_LAUNCH := 4.5         # m/s ragdoll launch along the swing on a kill (2026-10-06 tok: 6 -> 4.5)
const MELEE_FOV_PUNCH := -4.0          # degrees at the strike (a hit adds half again)
const WALL_NEAR := 0.3                 # m from the eye to a wall: the gun is fully pulled back
const WALL_ADS_BLOCK := 0.4            # pull-back target above this: no aiming (eased out)
const WALL_FIRE_BLOCK := 0.8           # pull-back above this: no firing

# --- Hit reactions -----------------------------------------------------------------------------------
# scripts/player/hit_reactor.gd (rival bots, training dummies) and its PlayerFeel (the player). All hits
# of one physics frame on a body are ONE impact (a shotgun blast = one reaction, every pellet's bone
# kept). Impact score = Σ damage × (1 + damage / HR_HEAVY_DMG) + |Σ impulse| × HR_IMPULSE_K, × up to
# HR_NEAR_BONUS at point blank. A meter of recent scores (half-life HR_METER_HALF) picks the tier:
#   below HR_STAGGER     flinch: per-bone springs at the struck bones + a short skid back
#   from HR_STAGGER      stagger: a shove along the shot with a little hop, a skid with ground
#                        friction, stumbling steps, torso bent, arms out; no shooting
#   from HR_DOWN_SOFT    one impact's score also gives a rising chance (to 1 at HR_KNOCKDOWN) of...
#   HR_KNOCKDOWN         ...knockdown: a ragdoll launched with the impulse (+ a kick at each struck
#                        bone), lies HR_DOWN_MIN..MAX s once settled, then the animated get-up
# e.g. rifle hit ~60 (flinch, ~0.25 m skid; 0.45 m before the 2026-10-06 tok), a 3-round string ~120-140 (stagger), sniper body ~145
# (stagger ~2.5 m, ~1/3 off its feet), shotgun at 10 m ~160, point blank ~290 (knockdown), a rocket
# close by ~300 (knockdown).
const HR_HEAVY_DMG := 120.0
const HR_IMPULSE_K := 8.0              # score per m/s of impulse
const HR_NEAR_BONUS := 1.3             # score × within HR_NEAR_FULL m of the shooter...
const HR_NEAR_FULL := 2.5
const HR_NEAR_ZERO := 7.0              # ...fading to × 1 here
const HR_METER_HALF := 0.3             # s
const HR_STAGGER := 100.0
const HR_DOWN_SOFT := 110.0
const HR_KNOCKDOWN := 220.0
const HR_LEG_SWEEP := 150.0            # leg hits this strong sweep it off its feet
# Knockback along the shot (tangent): HR_KB_K × sqrt(score) m/s (at least the hits' own |Σ impulse|),
# skidding to rest with HR_KB_FRICTION m/s² on the ground (none in the air); a stagger hops with
# HR_KB_LIFT m/s up per m/s.
# 2026-10-06 tok ("karakter vb aşırı hızlı, çok daha tok olsun"): hits shove less and plant the body
# longer instead: a shorter, slower skid, a lower hop, a longer stagger, aim spoiled a bit longer.
const HR_KB_K := 0.3                   # (tok: 0.375 -> 0.3)
const HR_KB_MAX := 5.0                 # (tok: 7 -> 5)
const HR_KB_FRICTION := 11.0           # (tok: 9 -> 11)
const HR_KB_LIFT := 0.15               # (tok: 0.25 -> 0.15)
const HR_FLINCH_REF := 60.0            # score of a full-strength (1.0) bone spring kick
const HR_FLINCH_AIM := 0.16            # s a flinch spoils a bot's aim (twice that on hard hits) (tok: 0.12 -> 0.16)
const HR_STAGGER_MIN := 0.75           # s of a stagger... (tok: 0.5 -> 0.75)
const HR_STAGGER_MAX := 1.4            # ...(plus the time in the air) (tok: 1.0 -> 1.4)
const HR_LIMP_MOVE := 0.7              # walking speed × while limping at full
# Shoves without damage (Kinetik İtici below AI_FLING_KO, the melee fling): by speed.
const HR_PUSH_STAGGER := 3.0           # m/s: a stagger from here...
const HR_PUSH_DOWN := 7.0              # ...a knockdown from here (MELEE_FLING 6.5 stays a stagger)
const HR_PUSH_KB := 0.6                # a stumble skids with this part of the shove (a knockdown: all)
# Knockdown.
const HR_DOWN_MIN := 1.3               # s it lies once settled (the harder the hit, the longer)... (2026-10-06 tok: 1.0 -> 1.3)
const HR_DOWN_MAX := 2.5               # (2026-10-06 tok: 2.0 -> 2.5)
const HR_DOWN_TIMEOUT := 5.0           # ...but up after this many s whatever
## 2026-10-05 the user: "ölünce uzaya fırlıyorlar, aşırı olmaması lazım": every corpse / knockdown
## launch is capped (hit_reactor.gd _cap_v): along the ground HR_CORPSE_MAX / HR_DOWN_LAUNCH_MAX,
## upward HR_CORPSE_UP_MAX. ~6.5 m/s + a 2.5 m/s hop on 0.8 g = ~4 m through the air, then a tumble.
## Only the Kinetik İtici's into-space band (ai_rival.gd fling) skips it.
## 2026-10-06 tok: bodies fall heavily instead of flying: ~4.5 m/s + a 1.6 m/s hop = ~1.8 m through the air.
const HR_CORPSE_MAX := 4.5             # m/s along the ground: a fresh corpse (tok: 6.5 -> 4.5)
const HR_CORPSE_UP_MAX := 1.6          # m/s up: corpses and knockdowns (tok: 2.5 -> 1.6)
const HR_DOWN_LAUNCH_MAX := 5.0        # m/s along the ground: a knockdown (was 11; tok: 7 -> 5)
const HR_BONE_IMPULSE := 2.5           # m/s × the part's mass: the kick at a struck ragdoll part
const HR_PART_KICK_BUDGET := 1.2       # full-strength part kicks per ragdoll per physics frame (a shotgun's 9 share it)
# Share of a corpse / knockdown launch given to EVERY part alike; the rest goes into the torso
# (chest + pelvis) AT the hit point (hit_reactor.gd _torso_kick), so the body topples / twists by
# where it was hit and the limbs, starting slower, trail and flop (1.0 = the old rigid launch).
const HR_RAG_UNIFORM := 0.45
const HR_GETUP_TIME := 1.5             # s (player.gd's get-up, ported) (2026-10-06 tok: 1.3 -> 1.5)
# Kills: the rest of the same blast throws the corpse too.
const HR_KILL_LAUNCH_MIN := 4.0        # m/s at least for a knockdown-strength kill (point-blank shotgun; was 9; tok: 5.5 -> 4)
const HR_DEATH_WINDOW := 2             # physics frames after the death in which hits still throw it
# The player (PlayerFeel).
# 2026-10-06 tok: a hit pushes the player less but slows / jolts him longer (it lands, not flings).
const HR_P_KB_PER_DMG := 0.05          # m/s knockback kick per hp of damage, on top of the hit's impulse... (tok: 0.07 -> 0.05)
const HR_P_KB_MAX := 3.5               # ...at most (and always under player.gd RAGDOLL_PUSH in all) (tok: 5 -> 3.5)
const HR_P_LIFT := 0.12                # up part of the kick (tok: 0.18 -> 0.12)
const HR_P_CROUCH_RESIST := 0.5        # kick × at full crouch
const HR_P_TAG_REF := 30.0             # damage of a full-strength hit (tagging, punch, jolt)
const HR_P_TAG_SLOW := 0.55            # speed lost at full strength... (tok: 0.5 -> 0.55)
const HR_P_TAG_TIME := 0.6             # ...for this long (0.25 s at the weakest), easing back (tok: 0.45 -> 0.6)
const HR_P_HEAVY := 35.0               # damage from which a hit makes the player stumble
const HR_P_HEAVY_IMPULSE := 4.0        # ...or an impulse this big (m/s; RAGDOLL_PUSH tumbles)
const HR_P_PUNCH := 0.08               # rad of aim punch at full strength (tok: 0.07 -> 0.08)

# ==================================================================================================
# Enemy AI: drop-pod raids, smarter and more dangerous bots (2026-10-05)
# ==================================================================================================

# --- Çıkarma kapsülü (scripts/war/drop_pod.gd; rival_team.gd + ai_rival.gd "Drop-pod raids") --------
## The rival fires troop pods from a ready cannon at a (preferably hidden) spot RAID_LAND_MIN..MAX m
## from our base; the crew fight to the death on our planet (the player, our structures, a shaft
## toward our core) and respawn at their base as usual. Independent of RAIDS_ENABLED (skiff raids).
const POD_RAIDS_ENABLED := true
## 2026-10-06 the user: first contact at about 1 minute: the first pod is fired ~45-60 s in (muster
## ~10-20 s, flight ~8-14 s), then one about every 1.5 min (R 30 values in brackets).
## Later the same day ("oyun daha yavaş, tok hissettirmeli"): a calmer match, the first pod ~1.5-2 min
## in, then every 2-2.7 min (tok notes).
const POD_FIRST_AFTER := 90.0          # s into the match before the first pod (210)... (2026-10-06 tok: 45 -> 90)
const POD_INTERVAL_MIN := 120.0        # ...then one every 120-160 s after the last launch (150-210; later (tok: 75 -> 120)
const POD_INTERVAL_MAX := 160.0        #    while the team cannot spare the crew or pay for it) (tok: 105 -> 160)
const POD_RETRY := 20.0                # s before the team looks again when something was missing (20) (tok: 15 -> 20)
const POD_COST := 160.0                # m³ from the pool per pod (AI_RESERVE is kept on top)
const POD_CREW_FIRST := 3              # crew of the first pods... (2: 8 bots now)
const POD_CREW_LATE := 4               # ...and from the POD_CREW_LATE_FROM-th pod on (3)
const POD_CREW_LATE_FROM := 3
const POD_HOME_KEEP := 2               # living bots that always stay home (the gunner among them; 1)
## Bots the team may add (permanently, counted in the team: they work, fight and respawn at the base
## like the others) when it cannot spare a full crew of its own. 0 = never (2026-10-06: was 1 for
## BOT_COUNT 3; 8 bots spare a full crew, and the team stays at BOT_COUNT).
const POD_REINFORCE_MAX := 0
const POD_MUSTER_TIME := 40.0          # s for the crew to climb in and the gunner to lay the cannon (60)
                                       # (then it fires with whoever is aboard; +20 s: called off)
const POD_BOARD_DIST := 5.5            # m from the cannon's centre where a crew member climbs in
const POD_AIM_ERROR_K := 0.5           # share of the team's cannon aim error on a pod shot
const POD_HITS := 2                    # Uçaksavar bursts / skiff-gun hits that destroy it in flight
const POD_LIFE := 45.0                 # s of flight before a pod that hit nothing is lost (crew dead)
const POD_GUIDE_RANGE := 90.0          # m from its landing spot the pod steers toward it...
const POD_GUIDE_ACCEL := 4.0           # ...with at most this much sideways thrust (m/s²: ~15-20 m)
## Retro burn (drop_pod.gd _thrust, 2026-10-06): under POD_RETRO_ALT, as soon as the pod comes down
## faster than its braking curve sqrt(LAND² + 2 × 0.5 × (RETRO_DECEL - g) × alt), it follows that
## curve (thrust at most POD_RETRO_DECEL) and steers onto the landing spot. Probe, R 60, spots 25-40 m
## from our base, 28-36 m/s shots with the aim error: the burn lights ~25-50 m up, touchdown 6.5-10
## m/s, 0.1-2.5 m from the spot (the old burn along the flight stopped ~30 m up and glided ~100 m off).
const POD_RETRO_ALT := 60.0            # m above the ground: the highest the retro-thrusters light (50)...
const POD_RETRO_DECEL := 20.0          # ...thrust at most this (m/s², ~12 net of gravity)...
const POD_LAND_SPEED := 7.0            # ...down to about this touchdown speed (m/s)
const POD_LAND_DAMAGE := 45.0          # the thump: area damage at the centre (whoever is under it)...
const POD_LAND_RADIUS := 3.0
const POD_LAND_IMPULSE := 6.0
const POD_DENT_R := 1.6                # ...and a small dent, no crater (planet.crater, × CRATER_SCALE)
const POD_DENT_DEPTH := 0.6
const POD_DOOR_DELAY := 0.4            # s from the touchdown to the doors blowing off (crew out)
const POD_WRECK_TIME := 75.0           # s the empty pod stays on the ground (cover), then sinks
const POD_SEEK_RANGE := 150.0          # m: a crew member with nothing in reach heads for the player
                                       # (the whole 60 m planet: 120 m across; 120 at R 30)

# --- Smarter, more dangerous bots (ai_rival.gd "Pressure, cover and lethality") -----------------------
## Rifle against a player (AI_RIFLE_DAMAGE 18 above). Hit chance per round: AI_PR_HIT_CLOSE out to
## AI_PR_CLOSE m, then × AI_PR_CLOSE / distance (an angular target), × AI_ACC_MOVING / AI_ACC_SETTLED
## (still for AI_PR_SETTLE_TIME s or peeking from cover) / AI_ACC_UNDER_FIRE / AI_ACC_SLIDE /
## AI_ACC_AIR, × the first-shots factor (AI_PR_FIRST_SHOT_K rising to 1 over AI_PR_TRACK_TIME s of
## sight), × the target's sideways speed penalty, which the lead learnt while tracking softens
## (speed × AI_PR_LEAD_K when fully tracked). Bursts of AI_PR_BURST_MIN..MAX rounds AI_PR_BURST_GAP
## apart, AI_PR_BURST_PAUSE between (skiffs and structures keep the old AI_RIFLE_* rhythm).
## Estimates (not measured), a lone player standing in the open at 15 m against 2 bots with a usual
## settled / moving mix: 0.27 per round, ~1.5 rounds/s per bot after reloads and movement -> ~7 dps
## each, ~14 together: half his 100 hp in ~3.6 s, dead in ~7 s; strafing (5 m/s) ~15 % slower, a
## fresh contact ~30 % slower; shooting back (AI_ACC_UNDER_FIRE) ~30 % slower. At 8 m: dead in ~4 s
## against two. One bot alone at 15 m: ~14 s; at 25 m: ~25 s.
const AI_PR_HIT_CLOSE := 0.5
const AI_PR_CLOSE := 8.0
const AI_PR_SETTLE_TIME := 0.6
const AI_PR_TRACK_TIME := 1.8          # (2026-10-06 tok: 1.5 -> 1.8: a slower aim settle)
const AI_PR_FIRST_SHOT_K := 0.65
const AI_PR_LEAD_SPEED := 14.0         # m/s of sideways target speed that would make it unhittable unled
const AI_PR_LEAD_K := 0.35
const AI_PR_LEAD_MIN := 0.45           # the motion penalty never goes below this
const AI_PR_BURST_MIN := 2
const AI_PR_BURST_MAX := 4
const AI_PR_BURST_GAP := 0.21          # s between the rounds of a burst (2026-10-06 tok: 0.18 -> 0.21, ~-14 % cadence)
const AI_PR_BURST_PAUSE := 0.7         # s between bursts (× 0.8..1.25)
## Pressure: two or more bots on one player (per living player on the planet), or him reloading,
## below AI_PR_WEAK_HP, knocked over or stumbling from a heavy hit, or the bot clearly healthier:
## one bot lays suppressive fire, up to AI_PR_FLANKERS run to his side / rear, the rest push in.
const AI_PR_WEAK_HP := 0.4
const AI_PR_FLANKERS := 2
const AI_PR_FLANK_DIST := 14.0         # m from the player: the flank points... (10 at R 30)
const AI_PR_FLANK_ANGLE := 100.0       # ...this many degrees around him from the bot's side (± 25°)
const AI_PR_FLANK_TIME := 9.0          # s a flank run may take (2026-10-06 tok: 7 -> 9, the bots run slower)
const AI_PR_PUSH_RANGE := 10.0          # m: pushers close in to this, firing on the move (8)
const AI_PR_SUPPRESS_TIME := 4.0       # s of suppressive fire before it re-decides
const AI_PR_SUPPRESS_ACC := 0.4        # its rounds hit × this (they are meant to pin him)...
const AI_PR_SUPPRESS_MISS := 1.6       # ...its misses pass within this many m of him (near-miss cracks)
const AI_PR_SUPPRESS_MEMORY := 2.5     # s it keeps firing at the spot where he ducked out of sight
const AI_PR_SUPPRESS_BURST := 5        # rounds per suppressive burst...
const AI_PR_SUPPRESS_PAUSE := 0.45     # ...and the pause between them (× 0.8..1.2)
const AI_PR_SQUAD_RANGE := 60.0        # m: allies this close fighting the same player count (45)
## Outgunned (alone and shot at, or hurt below AI_PR_OUTGUN_HP while he is healthier): it takes cover
## even when not under fire, holds it AI_PR_COVER_HOLD × longer and peek-shoots.
const AI_PR_OUTGUN_HP := 0.6
const AI_PR_COVER_HOLD := 1.6
## Hunt: after losing sight of the player on its own planet (any planet the bot stands on) it searches
## his last known position and around it, along his last heading, instead of going back to work
## after AI_CALM_AFTER.
const AI_PR_HUNT_AFTER := 3.0          # s out of sight before the hunt starts
const AI_PR_HUNT_TIME := 40.0          # s from the last sighting before it gives up (30)
const AI_PR_HUNT_RADIUS := 14.0         # m: search points around the last known position (9)
const AI_PR_HUNT_LOOK := 2.0           # s it looks around at each search point

# ==================================================================================================
# CONTENT 2026-10-05: Delici Raylı Tüfek ("rail", scripts/items/railgun.gd + rail_beam.gd) and the
# Otomatik Kazıcı (build tool, scripts/war/auto_miner.gd). Their entries in CRAFT_COST / CRAFT_TIME /
# CRAFT_RESERVE / BUILD_SITE above point here.
# ==================================================================================================

# --- Delici Raylı Tüfek ----------------------------------------------------------------------------
## Hold LMB to charge (RAIL_CHARGE_TIME to full), release to fire; a shot below RAIL_MIN_CHARGE only
## vents. The beam is straight and PIERCES: soil (up to RAIL_MAX_SOIL m at full charge, × charge),
## bots, players, structures, torpedoes, out to RAIL_RANGE m. Damage of the n-th target (n = 0, 1, ...):
## RAIL_DAMAGE × charge × (1 - RAIL_TARGET_FALLOFF)^n × (1 - RAIL_SOIL_FALLOFF × soil m before it).
const RAIL_CRAFT_COST := 550.0
const RAIL_CRAFT_TIME := 11.0
const RAIL_RESERVE := 4                # rounds a freshly made railgun brings (one more magazine)
const RAIL_AMMO_COST := 6.0            # m³ per round (Game.AMMO_COST "ammo_rail")
const RAIL_MAG := 4
const RAIL_RELOAD := 2.6               # s (3.1 s empty)
const RAIL_CHARGE_TIME := 1.2          # s from zero to a full charge
const RAIL_MIN_CHARGE := 0.15          # a release below this only vents (no shot, no round used)
const RAIL_COOLDOWN := 1.5             # s after a full-charge shot (× the charge, at least 0.35 s)
const RAIL_DAMAGE := 140.0             # first target, full charge (2026-10-06 tok: 110 -> 140: still a one-shot body kill on AI_HP 135)
const RAIL_HEAD_MULT := 1.5            # helmet hit
const RAIL_TARGET_FALLOFF := 0.35      # -35 % per target already passed
const RAIL_SOIL_FALLOFF := 0.04        # -4 % per metre of soil before the target (18 m: 28 % left)
const RAIL_MAX_SOIL := 18.0            # m of soil a full charge goes through
const RAIL_RANGE := 120.0
const RAIL_HIT_RADIUS := 0.6           # m from the beam: a body (its upright axis) counts as hit
const RAIL_ZOOM := 2.5                 # RMB scope magnification
const RAIL_XRAY_RANGE := 30.0          # m: scoped and charging, enemies this close in the cone show through soil
const RAIL_XRAY_CONE_DEG := 22.0       # half angle of that cone around the aim
## The beam's bore through the soil it crossed (host / single player only, synced like any dig):
## small DIG stamps every RAIL_BORE_STEP m along the soil part, at most RAIL_BORE_MAX per shot.
## (The voxels are 1 m: a radius much below ~0.6 m rarely touches a voxel corner and digs nothing.)
const RAIL_BORE_R := 0.6
const RAIL_BORE_AMOUNT := 6.0
const RAIL_BORE_STEP := 1.5
const RAIL_BORE_MAX := 12

# --- Otomatik Kazıcı (auto-miner) -----------------------------------------------------------------
## Built anywhere (BUILD_SITE "any": on the enemy planet it steals their soil, × MINER_ENEMY_MULT).
## It digs a real shaft (MINER_SHAFT_R, down to MINER_MAX_DEPTH) and pays its OWNER while it digs:
## MINER_RATE m³/s at the top, × (1 - MINER_RATE_DEEP_K × depth / max) deeper; the drill sinks at
## MINER_DESCENT m/s, × (1 - MINER_DESCENT_DEEP_K × depth / max). At the bottom it runs dry:
## MINER_RATE_DRY m³/s. Paid in hopper loads of MINER_HOPPER m³.
## Payback (estimate): 12 m in ~153 s, ~290 m³ by then: the 300 m³ price in ~3.4 min, then 15 m³/min.
## (2026-10-06 economy pass: 350 m³, MINER_RATE 3, MINER_RATE_DRY 0.5 = 30 m³/min for good; the drill
## is ~10 m³/s now, so a few miners would have out-earned the zones.)
const MINER_COST := 300.0
const MINER_HP := 220.0
const MINER_FOOTPRINT := 2.4           # radius (m) kept clear around it
const MINER_SHAFT_R := 1.45            # brush radius: a ~2.5 m wide shaft (1 m voxels)
const MINER_MAX_DEPTH := 12.0          # m below the ground it was built on
const MINER_DESCENT := 0.1             # m/s at the top...
const MINER_DESCENT_DEEP_K := 0.4      # ...this much slower at the bottom (harder soil)
const MINER_RATE := 2.5                # m³/s at the top... (3)
const MINER_RATE_DEEP_K := 0.45        # ...this much less at the bottom
const MINER_RATE_DRY := 0.25           # m³/s once it reached MINER_MAX_DEPTH (0.5)
const MINER_ENEMY_MULT := 1.25         # output × on the enemy planet (risky, lucrative)
const MINER_START_DELAY := 2.5         # s of spin-up after the assembly
const MINER_HOPPER := 10.0             # m³ per hopper load (the owner is paid per load)
const MINER_DIG_STEP := 0.35           # m of descent between two real DIG brushes (cheap)
const MINER_DIG_AMOUNT := 6.0          # density change at the brush centre

# --- Corpses and loot ---------------------------------------------------------------------------------
# scripts/war/corpse.gd and scripts/war/loot.gd. 2026-10-05 the user: "cesetler belli süre yerde
# kalmalı ve kişinin topladığı malzemeler yere düşüp kalmalı, onu toplatabilir oyuncu bu sayede".
# Corpses: when a rival bot / a killable training dummy / the player respawns, its body stays where it
# fell (a separate posed astronaut, no physics once at rest) for CORPSE_TIME s, sinking into the ground
# over the last CORPSE_SINK s. A blast throws it about again (a short ragdoll); visual and local only.
const CORPSE_TIME := 80.0              # s a body lies after its owner respawned (the sink included)
const CORPSE_SINK := 4.0               # s: the last part of it, sinking into the ground...
const CORPSE_SINK_DEPTH := 1.5         # ...this many m
const CORPSE_MAX := 10                 # corpses at once (the oldest goes first; the nodes are pooled)
const CORPSE_SHADOW_RANGE := 40.0      # m from the camera: the body casts a shadow only nearer (30)
const CORPSE_VIS_RANGE := 200.0        # m: not drawn farther (the other planet's near side is ~230 m away; 260 at R 30)
const CORPSE_SETTLE_MAX := 8.0         # s a still tumbling ragdoll taken over may need to come to rest
const CORPSE_RAGDOLL_MAX := 3          # corpses thrown about by blasts at once (live physics)
# Loot ("Malzeme"): a canister of material where someone died; walk over it (or F) to take it.
#   rival bot  what it dug since its respawn (its share of the team income) or picked up, at least
#              LOOT_MIN, at most LOOT_CARRY_MAX m³, taken out of the team pool (no longer theirs)
#   player     LOOT_PLAYER_SHARE of Game.material, dropped where he died: he can walk back for it
#              after the respawn (or a rival bot takes it). Not in the Eğitim Alanı (unlimited there).
#   dummy      a killable training dummy LOOT_DUMMY (immortal ones never die)
# The host spawns every drop (a multiplayer client's own death asks it); claims go through it.
## The kill reward (the only one: no bounty besides this canister; the user, 2026-10-06: "düşman
## öldürmek avantaj sağlamıyor"). Economy pass: every kill drops 50-100 m³ = ~5-10 s of digging at
## DRILL_MAX_RATE 10 (a guard / pod crew the minimum, a busy miner up to the max), out of their pool:
## a swing of ~2× that between the sides. (Was 15..200 against ~23 m³/s of passive income: nothing.)
## Each dead member also stops 1/N of its team's CORE_PUMP until the respawn (control_points.gd).
const LOOT_CARRY_MAX := 100.0          # m³ a rival bot carries at most (200)
const LOOT_MIN := 50.0                 # m³ every bot kill drops at least (15)
## Dying costs (2026-10-06, the user: "ölmek maliyetli bir şey olmalı"; Loot.on_player_death is the
## one function the death path calls): LOOT_PLAYER_SHARE of the player's OWN material drops where he
## died, at most LOOT_PLAYER_MAX (a rich player is not wiped out); the enemy may take it, he or a
## teammate may walk back for it. Every carried supply-pod gun drops too, with its rounds
## (weapon_drop.gd drop_player_loot). No repair fee, no extra enemy bonus: the respawn wait and the
## core-pump pause (control_points.gd pump_share) are the team cost.
const LOOT_PLAYER_SHARE := 0.45        # part of the player's material dropped at his death spot... (0.25)
const LOOT_PLAYER_MAX := 400.0         # ...at most this (m³; two thirds of a cannon, ~40 s of digging)...
const LOOT_PLAYER_MIN := 1.0           # ...unless that is less than this (m³)
const LOOT_DUMMY := 20.0               # m³ from a killable training dummy (for testing)
const LOOT_TIME := 120.0               # s a pickup lies...
const LOOT_BLINK := 10.0               # ...blinking for the last this many s
const LOOT_PICKUP_R := 1.6             # m: walking this close takes it (F works from the interact range)
const LOOT_MERGE_R := 2.5              # m: a drop this close to another pickup adds to it
const LOOT_LABEL_R := 9.0              # m from the camera: "+N m³" floats over it
const LOOT_BOT_PICKUP_R := 1.3         # m: a rival bot walking over one on its own planet takes it...
const LOOT_BOT_GRACE := 20.0           # ...once it has lain this long (the player gets the first go)

# --- Hafif Makineli (Uzi-style SMG, "smg", scripts/items/smg.gd) --------------------------------------
## Close-range hose: SMG_RATE rounds/s, SMG_DAMAGE a round up to SMG_FALLOFF_START m, falling (smooth) to
## × SMG_FALLOFF_MIN at SMG_FALLOFF_END m. Body TTK up close ~0.32 s (6 rounds; the rifle's 3 × 38 at
## 5.5/s: ~0.36 s); at 20 m ~13 a round, at 30 m ~7. B / middle mouse: TEK (semi) ↔ SERİ (auto).
## 2026-10-06 tok (AI_HP 135, SMG_RATE 13.5): 8 rounds, ~0.52 s; the rifle's 4 at 7.8/s full auto ~0.38 s.
const SMG_CRAFT_COST := 180.0
const SMG_CRAFT_TIME := 6.0
const SMG_RESERVE := 96                # rounds a freshly made SMG brings (3 magazines)
const SMG_AMMO_COST := 0.06            # m³ per round (Game.AMMO_COST "ammo_smg")
const SMG_MAG := 32
const SMG_RATE := 13.5                 # rounds per second (2026-10-06 tok: 15.5 -> 13.5)
const SMG_DAMAGE := 17.5
const SMG_HEAD_MULT := 1.8
const SMG_FALLOFF_START := 12.0
const SMG_FALLOFF_END := 30.0
const SMG_FALLOFF_MIN := 0.4
const SMG_SPEED := 420.0               # m/s (pistol-calibre round)
const SMG_RELOAD := 1.6                # s (1.9 s empty: the knob is racked)
const SMG_TRACER_EVERY := 3            # every n-th round draws a tracer

# ==================================================================================================
# SIDEARMS (2026-10-07, the user: "herkes tüfekle başlasın, ikinci silah seçeneği olarak tabanca vs
# ekle"). Loadout slot B (LOADOUT_B): Tabanca "pistol" (scripts/items/pistol.gd), Altıpatlar "revolver"
# (revolver.gd), Makineli Tabanca "mpistol" (mpistol.gd). Backups: weaker at range than the primaries,
# much faster to draw (their draw_time / holster_time). Ammo: "ammo_pistol" (9 mm: pistol + mpistol)
# and "ammo_magnum" (the revolver); Game.AMMO_COST / AMMO_START carry them.
# Derived from the 2026-10-06 tok scale (HP 135 for bots and players; rifle Standart 40 / head ×2,
# 4.8 /s TEK, 7.8 /s SERİ, no falloff; SMG 17.5 / ×1.8 at 13.5 /s): Tabanca 0.75 × the rifle round at
# 1.17 × its TEK rate (5 body / 2 head + 1 body; ~0.71 s at the cap vs the rifle 0.63 TEK / 0.38 SERİ),
# Altıpatlar 1.75 × the rifle round at 0.31 × its TEK rate (2 body ~0.67 s; one head shot kills inside
# ~22 m), Makineli Tabanca 0.69 × the SMG round at 1.19 × its rate (12 rounds ~0.69 s vs the SMG 0.52).
# ==================================================================================================
# --- Tabanca (semi-auto, the default sidearm) ---
const PISTOL_CRAFT_COST := 100.0
const PISTOL_CRAFT_TIME := 4.0
const PISTOL_RESERVE := 45             # rounds the loadout brings (3 magazines)
const PISTOL_AMMO_COST := 0.05         # m³ per 9 mm round (cheap; Game.AMMO_COST "ammo_pistol")
const PISTOL_MAG := 15
const PISTOL_RATE := 5.6               # clicks / s at most
const PISTOL_DAMAGE := 30.0
const PISTOL_HEAD_MULT := 2.0
const PISTOL_FALLOFF_START := 15.0
const PISTOL_FALLOFF_END := 40.0
const PISTOL_FALLOFF_MIN := 0.55
const PISTOL_SPEED := 380.0            # m/s
const PISTOL_RELOAD := 1.35            # s
const PISTOL_RELOAD_EMPTY := 1.6       # s (the slide racked)
# --- Altıpatlar (heavy six-shot, round-by-round reload) ---
const REVOLVER_CRAFT_COST := 160.0
const REVOLVER_CRAFT_TIME := 5.0
const REVOLVER_RESERVE := 18           # rounds the loadout brings (3 cylinders)
const REVOLVER_AMMO_COST := 0.18       # m³ per magnum round (Game.AMMO_COST "ammo_magnum")
const REVOLVER_MAG := 6
const REVOLVER_RATE := 1.5             # shots / s at most (double action)
const REVOLVER_DAMAGE := 70.0
const REVOLVER_HEAD_MULT := 2.0           # 140: a head shot kills (HP 135) up close
const REVOLVER_FALLOFF_START := 18.0
const REVOLVER_FALLOFF_END := 45.0
const REVOLVER_FALLOFF_MIN := 0.55
const REVOLVER_SPEED := 450.0          # m/s
const REVOLVER_SHELL_START := 0.55     # s: the cylinder swung out, the empties ejected...
const REVOLVER_SHELL_EACH := 0.36      # ...each round thumbed in...
const REVOLVER_SHELL_END := 0.4        # ...swung shut (full: ~3.1 s)
# --- Makineli Tabanca (select-fire machine pistol) ---
const MPISTOL_CRAFT_COST := 150.0
const MPISTOL_CRAFT_TIME := 5.0
const MPISTOL_RESERVE := 80            # rounds the loadout brings (4 magazines; "ammo_pistol")
const MPISTOL_MAG := 20
const MPISTOL_RATE := 16.0             # rounds / s in SERİ
const MPISTOL_DAMAGE := 12.0
const MPISTOL_HEAD_MULT := 1.6
const MPISTOL_FALLOFF_START := 7.0
const MPISTOL_FALLOFF_END := 22.0
const MPISTOL_FALLOFF_MIN := 0.35
const MPISTOL_SPEED := 360.0           # m/s
const MPISTOL_RELOAD := 1.5            # s
const MPISTOL_RELOAD_EMPTY := 1.75     # s (the slide racked)
# ==================================================================================================

# --- Weapon drops (scripts/war/weapon_drop.gd; CoD style, 2026-10-05) -----------------------------------
# A dying bot drops its rifle, a dying player the gun in his hand (a COPY: his crafted guns stay his).
# Hold F over one to take it: a gun you do not carry joins your guns as a loot gun (lost on death),
# one you carry gives its rounds to the reserve.
const WDROP_TIME := 60.0               # s a dropped gun lies...
const WDROP_BLINK := 8.0               # ...blinking for the last this many s
const WDROP_MAX := 10                  # guns lying in the world at most (the oldest goes first)
const WDROP_PICKUP_R := 1.7            # m from the feet: "[F basılı tut] ... al"
const WDROP_HOLD := 0.5                # s of F held to take it
const WDROP_LABEL_R := 7.0             # m from the camera: its name floats over it
const WDROP_RESERVE_MAGS := 0.5        # a death drop brings this many magazines of reserve along
const WDROP_BOT_MAG := Vector2(0.35, 1.0)   # a bot's rifle: this part of a magazine left (random)

# ==================================================================================================
# BASE BUILDING (2026-10-05; the user: "üs kurma mantığı ... toprağın altına kurar ... bir sürü koruma,
# bunkerler"). scripts/war/base_kit.gd (rules, underground placement, blast shelter, snapping, the AI
# API), scripts/war/base_piece.gd (shared structure contract) and its pieces: bunker_module.gd (Sığınak
# Modülü), armor_wall.gd (Takviyeli Duvar), blast_door.gd (Zırhlı Kapı), sentry_turret.gd (Otomatik
# Taret), core_shield.gd (Çekirdek Kalkanı), radar_tower.gd (Radar Kulesi), light_post.gd (Işık Direği).
# Entry ids = the script file names (the keys below, in BASE_BUILD_SITE and in BUILD_UNDERGROUND).
# ==================================================================================================

## Where the new pieces may stand (read by build_site() after BUILD_SITE; same "home" / "any" / "enemy").
const BASE_BUILD_SITE := {"bunker_module": "any", "armor_wall": "any", "blast_door": "any",
		"sentry_turret": "any", "core_shield": "home", "radar_tower": "home", "light_post": "any"}
## Which build entries may stand UNDER the ground: in a dug cavity (a tunnel, a pit, a cavern) with soil
## straight over the spot within UNDERGROUND_PROBE m. Keyed like BUILD_SITE (entry id or script file
## name); missing = surface only. Cannons, Uçaksavar, Delici Top and the skiffs need open sky, the
## Sondaj Kulesi drills from the surface.
const BUILD_UNDERGROUND := {"bunker_module": true, "armor_wall": true, "blast_door": true,
		"sentry_turret": true, "core_shield": true, "radar_tower": true, "light_post": true, "armory": true,
		"auto_miner": true}
const UNDERGROUND_PROBE := 14.0        # m straight up from the floor: soil within this = a covered spot
const UNDERGROUND_LIFT := 0.6          # m over each footprint sample where the floor probe starts (must be air)
const HEADROOM_MARGIN := 0.1           # m of air kept over the structure's top
const BASE_SNAP_DIST := 3.2            # m from the aim point to a snap spot (module doorway, wall end)

# --- Blast shelter (Explosion area damage on structures, base_kit.gd blast_shelter) -----------------
## Soil between a blast and a structure soaks it up: the occlusion ray runs from SHELTER_LIFT m above the
## blast (along its normal) to the structure's middle; soil within the blast's own bite (its crater ×
## CRATER_SCALE, at least SHELTER_BITE_K × its damage radius: the hole it is about to blow) does not
## count. Damage × (1 - soil / SHELTER_SOIL_BLOCK), thinner than SHELTER_SOIL_MIN ignored. E.g. a shell
## (bite ~4 m) right over a module 2 m down hurts it in full (× BUNKER_BLAST_MULT); 8 m down it is safe
## until the crater reaches it (~2 shells in the same hole). Bots and players are not sheltered by this
## (grenades into pits still work); cores take their damage elsewhere (Core.blast_all).
const SHELTER_SOIL_BLOCK := 2.0
const SHELTER_SOIL_MIN := 0.25
const SHELTER_LIFT := 0.6
const SHELTER_BITE_K := 0.35
const SHELTER_STEP := 0.5

# --- Sığınak Modülü (bunker_module.gd) ------------------------------------------------------------
## A reinforced concrete / steel room shell (4 × 4 × 2.8 m outside, 3.4 m inside, doorways front and back,
## 1.6 × 2.2 m). Blasts × BUNKER_BLAST_MULT (bullets in full). Modules snap doorway to doorway.
const BUNKER_COST := 220.0
const BUNKER_HP := 900.0
const BUNKER_FOOTPRINT := 2.0          # (its box is checked exactly against the other base pieces)
const BUNKER_BLAST_MULT := 0.35
# --- Takviyeli Duvar (armor_wall.gd) --------------------------------------------------------------
const WALL_COST := 40.0
const WALL_HP := 380.0
const WALL_FOOTPRINT := 1.5
const WALL_BLAST_MULT := 0.5
# --- Zırhlı Kapı (blast_door.gd) ------------------------------------------------------------------
## Opens by itself for its own side (players, bots) within DOOR_OPEN_RANGE, stays shut for the enemy
## (who has to break it: DOOR_HP). Fits a module doorway or a ~2 m tunnel.
const DOOR_COST := 90.0
const DOOR_HP := 480.0
const DOOR_FOOTPRINT := 1.25
const DOOR_BLAST_MULT := 0.5
const DOOR_OPEN_RANGE := 3.2           # m from the door's middle
const DOOR_OPEN_TIME := 0.55           # s to slide open / shut
const DOOR_HOLD := 1.0                 # s it stays open after the last friend went through
# --- Otomatik Taret (sentry_turret.gd) ------------------------------------------------------------
## Twin MG on a pedestal: engages enemy bots / players / landed or descending drop pods within
## TURRET_RANGE m it can see. Bursts of TURRET_BURST rounds at TURRET_RATE, TURRET_PAUSE s apart; every
## round is a real ray with TURRET_SPREAD_DEG of scatter (most hit inside ~15 m, about half at 30 m):
## ~5 s to kill a lone bot in the open at 20 m. A burst costs its owner TURRET_BURST_COST m³ (the local
## player's material / the rival pool); an owner who cannot pay gets a slow trickle (pause × 3). A turret
## a multiplayer client built fires free (the host cannot charge the client's material).
const TURRET_COST := 300.0
const TURRET_HP := 260.0
const TURRET_FOOTPRINT := 1.3
const TURRET_BLAST_MULT := 0.8
const TURRET_RANGE := 45.0
const TURRET_TURN_RATE := 150.0        # deg/s
const TURRET_REACT := 0.6              # s of sight before the first burst
const TURRET_RATE := 8.0               # rounds/s in a burst (the barrels alternate) (2026-10-06 tok: 9 -> 8)
const TURRET_BURST := 6
const TURRET_PAUSE := 0.9
const TURRET_DAMAGE := 7.0
const TURRET_SPREAD_DEG := 1.1
const TURRET_FIRE_CONE_DEG := 4.0      # aim within this of the target before it fires
const TURRET_BURST_COST := 0.0         # (2026-10-06 "küçük vergileri kaldır": 0.6 -> 0)
const TURRET_POD_DAMAGE := 42.0        # rounds on a descending pod: every this much = one hit (POD_HITS)
const TURRET_SENSE := 0.25             # s between target scans
# --- Çekirdek Kalkanı (core_shield.gd) ------------------------------------------------------------
## Only near your OWN core (its surface within CORE_SHIELD_RANGE m: dig down to the core chamber), one
## per side. While it stands the core takes × CORE_SHIELD_MULT (core.gd _damage) under a visible energy
## shell: the enemy has to break the generator first.
const CORE_SHIELD_COST := 600.0
const CORE_SHIELD_HP := 520.0
const CORE_SHIELD_FOOTPRINT := 1.4
const CORE_SHIELD_BLAST_MULT := 0.7
const CORE_SHIELD_RANGE := 8.0
const CORE_SHIELD_MULT := 0.4
# --- Radar Kulesi (radar_tower.gd) ----------------------------------------------------------------
## Enemies within RADAR_RANGE m of a standing radar (bots, players, pods; diggers underground, and fresh
## enemy digs from the tunnel log) are contacts: Radar.contacts_for(team) for the HUD. A new underground
## contact warns "Yeraltında düşman kazısı tespit edildi" (at most every RADAR_WARN_GAP s).
const RADAR_COST := 260.0
const RADAR_HP := 220.0
const RADAR_FOOTPRINT := 1.4
const RADAR_RANGE := 90.0
const RADAR_SCAN := 0.5                # s between scans
const RADAR_DIG_RECENT := 8.0          # s: an enemy dig this fresh is a contact
const RADAR_WARN_GAP := 20.0
const RADAR_UNDER_DEPTH := 1.2         # m below the original surface: a contact counts as underground
# --- Işık Direği (light_post.gd) ------------------------------------------------------------------
const LIGHT_COST := 15.0
const LIGHT_HP := 60.0
const LIGHT_FOOTPRINT := 0.45
const LIGHT_RANGE := 9.0
const LIGHT_ENERGY := 0.85             # warm white, soft falloff: lights a tunnel without blowing it out
const LIGHT_COLOR := Color(1.0, 0.86, 0.68)

# --- Ally bots (single player only: scripts/war/ally_team.gd + ai_rival.gd "Ally bots") -----------
# The rival's bot AI with team "home" on our planet: 1 Muhafız (follows the player near the base or
# guards it; F on it toggles "Beni takip et" / "Üssü koru") and 1 Kazıcı (digs around the base for
# the PLAYER's material). They fight the rival's bots they see (drop-pod crews), respawn like them
# (AI_RESPAWN), and take FRIENDLY_FIRE from our hits. Not in multiplayer, not in the Eğitim Alanı.
const ALLY_COUNT := 2                  # 0 = none; roles in order: Muhafız, Kazıcı, Muhafız, Kazıcı...
const ALLY_MINER_RATE := 2.0           # m³/s to the player's material while the Kazıcı digs: about one
                                       # rival miner's share of TEAM_INCOME_CAP (2026-10-06 economy pass:
                                       # 10, half a busy player's drill at DRILL_MAX_RATE 30; 4 before that)
const ALLY_DIG_MIN := 15.0             # m from the base: its pits (clear of structures and the player) (12 at R 30)
const ALLY_DIG_MAX := 32.0
const ALLY_FOLLOW_RANGE := 50.0        # m from the base: the Muhafız follows the player within this
const ALLY_FOLLOW_DIST := 7.0          # m it keeps from him (catches up beyond ALLY_FOLLOW_FAR)
const ALLY_FOLLOW_FAR := 13.0
const ALLY_CAM_CLEAR := 3.2            # m: allies never stand closer to the player (his camera) than this
const ALLY_VIEW_CLEAR_DIST := 14.0     # m: while he drills, builds or aims, allies step out of his view
const ALLY_VIEW_CLEAR_DEG := 22.0      #    cone (this half angle) up to this far
const ALLY_POD_REACT := 90.0           # m: an enemy pod landing this close to an ally sends it there (70)

# --- AI pilot and skiff raids (2026-10-05: scripts/craft/skiff.gd "AI pilot", armed_skiff.gd "AI
# gunner", rival_team.gd "Skiff raids: crew, variant, timing, upkeep") ---------------------------------
## Timing: the team builds its skiff from RAID_FIRST_AFTER - RAID_BUILD_LEAD s on (the Silahlı Mekik
## when the pool pays ARMED_BUILD_COST + AI_RESERVE, else the plain Mekik), the first raid flies from
## RAID_FIRST_AFTER s on, the next RAID_MIN_INTERVAL s after the last one ended. Skiff raids and drop
## pods alternate: a raid starts only when the next pod is due within RAID_POD_MARGIN s and no pod is
## mustering, in flight or still fighting on our planet; a finished raid pushes the next pod
## POD_INTERVAL_MIN s out, and no pod is fired while a raid runs. Crew: RAID_SKIFF_CREW (guards first,
## then miners; never a pod crew / the gunner), POD_HOME_KEEP living bots always stay home.
const RAID_BUILD_LEAD := 30.0
const RAID_POD_MARGIN := 40.0
const RAID_SKIFF_CREW := 2             # the skiff seats two: the pilot and one more
const RAID_SKIFF_REBUILD := 60.0       # s after the skiff was lost (or captured) before another is built (90)
const RAID_SKIFF_MIN_HP := 0.6         # share of its hull the skiff needs before a raid...
const RAID_SKIFF_REPAIR := 3.0         # ...repaired this many hp/s while parked at home between raids...
const RAID_SKIFF_REPAIR_COST := 0.5    # ...for this many m³ per hp from the pool (AI_RESERVE kept)
const RAID_SKIFF_ABORT_HP := 0.3       # hull share on the way out below which it turns back home
# The Silahlı Mekik under a bot (armed_skiff.gd "AI gunner"): attack runs on the way in.
const AI_STRIKE_TIME := 25.0           # s of attack runs per sortie before it goes in to land
const AI_ARMED_BREAK_HP := 0.4         # hull share below which it stops attacking (lands / goes home)
const AI_GUN_RANGE := 220.0            # m: targets it picks and fires at
const AI_GUN_REACT := 0.7              # s on a new target before the first burst
const AI_GUN_ERR := 0.014              # rad of aim error (×1.8 while jinking, + target speed / 25 m/s)...
const AI_GUN_ERR_TIME := 0.6           # ...re-rolled this often (the bursts walk)
const AI_FIRE_CONE := 0.03             # rad (+ the target's size) the nose must be on the lead point
const AI_HEAT_HI := 0.78               # barrel heat where it stops a burst...
const AI_HEAT_LO := 0.3                # ...and the heat it waits for (it never locks the guns)
const AI_ROCKET_MIN := 45.0            # m: a rocket salvo at structures between these
const AI_ROCKET_MAX := 170.0
const AI_RUN_ALT := 14.0               # m over a ground target the run aims to pass
const AI_BREAK_DIST := 40.0            # m: breaks off the run this close...
const AI_EXTEND_TIME := 3.5            # ...extends away this long, then comes round again
const AI_RUN_MIN_CLEAR := 10.0         # m of ground clearance: closing lower than this breaks off too
## Target preference (× 100 in the score, minus 0.3 per m and 25 per rad off the nose).
const AI_TARGET_W := {"war_flak": 1.6, "war_cannon": 1.45, "war_buster": 1.25, "war_torpedo_rig": 1.2,
		"war_armory": 1.0, "war_miner": 0.9, "player": 1.3, "skiff": 1.5, "bot": 0.75}

# --- Respawn by dropship (scripts/war/respawn_ship.gd, dropship.gd, carrier.gd) --------------------
# 2026-10-05 the user: "Ölünce bizi gezegene bir uzay gemisi atsın, 10 sn sonra doğalım; düşmanda da
# bu olsun". From death to control again: RESPAWN_TIME for the player; the bots since 2026-10-07 in
# waves (RESPAWN_WAVE*, below).
const RESPAWN_TIME := 13.0             # s from death to stepping off the İniş Gemisi's ramp (the player; 2026-10-07 waves: 10 → 13)
const RESPAWN_CUT := 5.0               # s after death the view cuts into the docked dropship's cabin... (10 → 13 s pass: 4 → 5)
const RESPAWN_FADE := 0.35             # ...through this much black
const RESPAWN_LEAD := 8.0              # s before a bot WAVE's slot its ship is sent (= RESPAWN_TIME - RESPAWN_CUT; 6 → 8)
const RESPAWN_DOOR := 0.9              # s from the touchdown to the respawn: the ramp drops, you stand up
const RESPAWN_STAND := 0.6             # s the view takes from the jump seat to the ramp's foot
const RESPAWN_STAGGER := 0.45          # s between bots stepping off one ship
const RESPAWN_BATCH := 2.0             # s: a bot whose ship would land this close to another's rides that one
const RESPAWN_SHIP_CAP := 6            # bots per ship
const RESPAWN_GROUND := 2.5            # s a ship waits after its last passenger, then flies back up
const RESPAWN_MIN_FLIGHT := 3.0        # s: a late request still gets a ship (the bot waits aboard)
const CARRIER_ALT := 110.0             # m above the base radius (the jetpack gives out at 20 m)
const CARRIER_LOOP := 0.5              # rad: the carrier's slow loop in the sky above its base...
const CARRIER_PERIOD := 600.0          # ...once round every this many s (wall clock: the same on both machines)

# --- Respawn waves (2026-10-07) ---------------------------------------------------------------------
# The user: "ölünce çok hızlı yeniden doğuluyor, bir avantaj elde edemiyoruz". Bots no longer come back
# one by one: each team's dead ride ONE dropship on that team's wave clock (scripts/war/respawn_waves.gd;
# the dispatch: respawn_ship.gd). The player keeps his own fixed RESPAWN_TIME ride.
const RESPAWN_WAVE := 20.0             # s between a team's wave slots (nobody dead: no ship flies)
const RESPAWN_WAVE_MIN := 13.0         # s a dead bot waits at least (>= RESPAWN_TIME: never back before the player)
const RESPAWN_WAVE_MAX := 30.0         # s at most: a later slot is pulled forward to this (the team's clock shifts)
const RESPAWN_WAVE_HOME_OFS := 10.0    # s our clock runs behind the rival's (the two sides' waves alternate)
## Numbers advantage on the zones (control_points.gd _tick): a team whose weighted dead count
## (RespawnWaves.team_down: dead 1, downed 0.5) is at least CP_DOWN_MIN loses its zones faster and
## takes zones slower.
const CP_DOWN_MIN := 2.0               # weighted dead for the handicap
const CP_DOWN_TAKE_K := 1.5            # × the enemy's capture speed on a zone the down team holds / leans to
const CP_DOWN_CAP_K := 0.67            # × the down team's own capture speed
## Team wipe (respawn_waves.gd): everyone of a team within WIPE_RADIUS of a fresh death is down.
const WIPE_RADIUS := 60.0              # m around the death: "the fight"
const WIPE_MIN := 2                    # units down in there (a lone kill is no wipe)
const WIPE_GAP := 20.0                 # s between two wipe alerts about the same team
const WIPE_ALERT_SECS := 3.5           # s the alert line stays


# --- Digging tactics and the rival's base (2026-10-05, phase 2: ai_rival.gd / rival_team.gd "Digging
# tactics and the rival's base"; the pieces: scripts/war/base_kit.gd) ---------------------------------
## Every tactical brush (Dig.dig_at with the team: host only, synced, logged for the Tünel tarayıcı)
## takes a token from a team-wide bucket: DG_CARVE_PER_MIN a minute, DG_CARVE_BURST saved up at most.
## Digging out of a hole / tunnel never waits for it.
const DG_CARVE_PER_MIN := 300.0           # (150; 2026-10-07 flank tunnels: measured use was ~9 a minute)
const DG_CARVE_BURST := 60.0              # (40)
const DG_TUN_R := 1.55                 # tunnel brush radius: two per step (~2 m tall, ~2 m wide)...
const DG_TUN_AMOUNT := 12.0            # ...this much density each (twice where deeper than 3 m)
# Sapper tunnels: a raider (skiff or drop pod) lands DG_SAP_LAND_MIN..MAX m from our base and tunnels
# DG_SAP_DEPTH m under the ground: beside our cannon / Uçaksavar / turret and up behind it (it then
# attacks it), or to under our base and down the shaft to the core. One at a time.
const DG_SAPPER_FIRST := 75.0          # s into the match before the first one is planned (150: missed the first pod)
const DG_SAPPER_GAP := 90.0            # s after one ends before the next is planned (150)
const DG_SAPPER_CHANCE := 0.7          # chance a raid's landing spot is picked for a sapper (0.4)
const DG_SAP_LAND_MIN := 35.0
const DG_SAP_LAND_MAX := 55.0
const DG_SAP_DEPTH := 3.5              # m under the untouched surface
const DG_SAP_SLOPE := 0.6              # the ramps (down at the start, up at a pop-up)
const DG_SAP_STEP := 0.6               # m a tunnel step...
const DG_SAP_STEP_T := 1.3             # ...every this many s (~0.45 m/s)
const DG_SAP_RANGE := 70.0             # m from the landing: the structure it pops up behind (50)
const DG_SAP_POPUP := 0.6              # chance of a pop-up (else down to the core)
const DG_SAP_BEYOND := 6.0             # m behind the structure's footprint where it surfaces
const DG_SAP_SIDE := 4.0               # m beside the footprint the tunnel passes
const DG_SAP_CORE_SHORT := 8.0         # core: the tunnel ends this far from our base centre (then the shaft)
const DG_SAP_TIME := 200.0             # s at most for the tunnel
const DG_STUCK_T := 6.0                # s stuck underground while trying to move: it digs itself out...
const DG_EXIT_TIME := 40.0             # ...and is lifted out after this long (bots never stay stuck)
# Foxholes and escape pits (combat, no cover found).
const DG_FOX_CHANCE := 0.35            # per decision in a firefight without cover
const DG_FOX_COOLDOWN := 40.0          # s per bot
const DG_FOX_DEPTH := 1.2
const DG_FOX_RANGE_MIN := 10.0         # m to the enemy
const DG_FOX_RANGE_MAX := 70.0
const DG_FOX_HOLD := 14.0              # s it holds the foxhole (the cover tactic: crouch, peek, fire)
const DG_ESCAPE_CHANCE := 0.5          # low hp without cover: digs down instead of running
const DG_ESCAPE_DEPTH := 2.6
const DG_ESCAPE_TIME := 25.0           # s at most in the pit (or until DG_ESCAPE_HEAL of its hp)
const DG_ESCAPE_HEAL := 0.75
# Trenches: a guard digs a line of pits in front of a cannon (toward our planet), slowly.
const DG_TRENCH_FIRST := 90.0
const DG_TRENCH_GAP := 100.0
const DG_TRENCH_AHEAD := 7.0
const DG_TRENCH_SEGS := 5
const DG_TRENCH_SPACING := 1.4
const DG_TRENCH_DEPTH := 1.1
const DG_TRENCH_STEP_T := 2.0          # s per brush
# Counter-tunnelling: an enemy dig deeper than DG_COUNTER_MIN_DEPTH within DG_COUNTER_R m of the line
# from their base down to their core, fresher than DG_COUNTER_FRESH s (TunnelLog).
const DG_COUNTER_FRESH := 20.0         # (15)
const DG_COUNTER_MIN_DEPTH := 1.8      # (2.5)
const DG_COUNTER_R := 30.0             # (20)
const DG_COUNTER_GAP := 35.0           # s after one ends before the next (60)
const DG_COUNTER_STALE := 15.0         # s with no fresh enemy dig at the head: the digger left -> collapse
const DG_COUNTER_TIME := 140.0
const DG_COUNTER_FILL_R := 9.0         # m of the enemy tunnel caved in around the meeting point
const DG_COUNTER_STEP_T := 0.9         # s per tunnel step (faster: it is in a hurry)
# Ambush: a guard digs a pit 8-12 m off a path the player walked on their planet and waits in it.
const DG_AMBUSH_FIRST := 75.0          # (150)
const DG_AMBUSH_GAP := 70.0            # (150)
const DG_AMBUSH_WAIT := 150.0          # (100)
const DG_AMBUSH_DEPTH := 1.4
# Bunkers (only while the team has no Sığınak Modülü) and shelter from shelling.
const DG_BUNKER_FIRST := 120.0
const DG_BUNKER_GAP := 300.0
const DG_BUNKER_MAX := 1
const DG_BUNKER_DEPTH := 3.0           # m of the room floor under the surface (~1 m of soil overhead)
const DG_SHELTER_NEAR := 30.0          # m: an enemy blast this near in the last DG_SHELTER_MEM s = shelling (22)
const DG_SHELTER_MEM := 6.0
const DG_SHELTER_RANGE := 55.0         # m to the shelter it runs to (40)
const DG_SHELTER_TIME := 12.0          # s it stays after the last blast
# The core shield's shaft (the engineer digs down to the chamber BaseKit.suggest_spot gives).
const DG_SHAFT_RATE := 8.0             # density / s at the shaft floor (~1.2 m/s; 4 = ~0.6 m/s before the core went ~57 m down)

# =================================================================================================
# Flank tunnels and dig tells (2026-10-07, the user: "arkamıza kazarak gelmiyorlar, kazı yok";
# ai_rival.gd / rival_team.gd "Digging tactics" -> "Flank tunnel")
# =================================================================================================
# A player who holds a spot gets one bot (two when the team has DG_FLANK_PAIR_MIN on his planet)
# tunnelling round his side from where he cannot see it and bursting out behind him.
const DG_FLANK_FIRST := 45.0           # s into the match before the first flank
const DG_FLANK_GAP := 50.0             # s after one ends before the next
const DG_FLANK_HOLD_R := 6.0           # m: he "holds a spot" while he stays this near one point...
const DG_FLANK_HOLD_T := 18.0          # ...this long (s)...
const DG_FLANK_DUG_K := 0.6            # ...× this when he is dug in (a pit / tunnel / soil overhead)
const DG_FLANK_MIN_D := 14.0           # m: a flanker starts this far from him at least...
const DG_FLANK_MAX_D := 50.0           # ...at most
const DG_FLANK_MIN_HP := 0.5           # share of its hp a flanker needs
const DG_FLANK_PAIR_MIN := 4           # bots of ours on his planet for a pair (else one)
const DG_FLANK_PAIR_WAIT := 8.0        # s the first one under the lip waits for the other
const DG_FLANK_PAIR_DEG := 28.0        # ° between the pair's exits round him
const DG_FLANK_DEPTH := 2.4            # m under the untouched surface
const DG_FLANK_SIDE_R := 11.0          # m from him the tunnel passes his side
const DG_FLANK_BEHIND := Vector2(8.0, 13.0)   # m behind him (away from the fight) it surfaces
const DG_FLANK_R := 1.45               # its brush radius (two stacked per step, like DG_TUN_R)
const DG_FLANK_STEP_T := 0.7           # s per DG_SAP_STEP (0.6 m): ~0.85 m/s
const DG_FLANK_LIP := 4                # the last steps: it waits under them, then bursts out...
const DG_FLANK_BURST_T := 0.3          # ...this fast per step
const DG_FLANK_REPLAN := 7.0           # m he moved: the rest of the tunnel is planned again
const DG_FLANK_MAX_STEPS := 90         # (~54 m) longer than this: not worth it
const DG_FLANK_TIME := 110.0           # s at most for the whole task
const DG_FLANK_SUPPRESS := 4.0         # s two front bots pin him while the flankers come out
const DG_THUMP_R := 30.0               # m: tunnel thumps reach a player this far (the soil muffles them)
const DG_TELL_R := 12.0                # m: "Ayaklarının altından kazı sesi geliyor…" (once per tunnel)
const DG_SAP_LAND_NEAR := 24.0         # m from the planned landing a crew member may take the sapper (14)
const DG_AMBUSH_FAR := 45.0            # m: an ambush pit is dug while every player is this far from it
const DG_AMBUSH_MAX := 2               # ambushers at once (1)

# The rival's base pieces (BaseKit): the engineer builds them as the pool allows.
const BK_SHIELD_AFTER := 1             # cannons standing before the core shield (top priority then)
const BK_TURRETS := 2                  # Otomatik Taret near the cannons (after the cannons and Uçaksavar)
const BK_BUNKER_MODULES := 1           # Sığınak Modülü by the cannon cluster (the bots' shelter)
const BK_LIGHTS := 3                   # Işık Direği in its tunnels / bunker / shield chamber
const BK_RESERVE := 120.0              # pool kept on top of a piece's price

# --- Weapon attachments (scripts/items/attachments.gd; made at the Silahlık's EKLENTİLER tab,
# scripts/war/attachments_panel.gd, through the craft.gd recipes "att_<id>"; unlocked once, fitted to
# any compatible gun with the middle mouse radial). m³ / s per attachment; the Refleks is free.
const ATT_CRAFT_COST := {"att_suppressor": 110.0, "att_compensator": 80.0, "att_flash_hider": 50.0, "att_choke": 60.0,
		"att_reflex": 70.0, "att_holo": 90.0, "att_scope4": 140.0, "att_foregrip": 60.0, "att_laser": 70.0}
const ATT_CRAFT_TIME := {"att_suppressor": 6.0, "att_compensator": 5.0, "att_flash_hider": 4.0, "att_choke": 4.0,
		"att_reflex": 4.0, "att_holo": 5.0, "att_scope4": 7.0, "att_foregrip": 4.0, "att_laser": 4.0}

# --- Easy building (2026-10-06; the user: "co-op'ta inşa daha kolay ... herkes anlayabilsin") --------
# scripts/war/build_tool.gd (+ build_guide.gd, build_intent.gd): undo / sell, pings, recommendations.
const UNDO_TIME := 10.0                # s after a build in which Z takes it back for the full price
const SELL_REFUND := 0.5               # share of the price back when X (held) takes a structure down
const SELL_HOLD := 1.0                 # s X is held for it
const BUILD_PING_TIME := 20.0          # s a "BURAYA KUR" ping stays (both players see it)
const BUILD_PING_MAX := 3              # pings per player at once (a new one replaces the oldest)
const RECO_LOW_INCOME := 4.0           # m³/s over the last minute: below this the miner is recommended
                                       # (1.5; 2026-10-06 economy pass: the zones + pump alone pay ~2.75)
const RECO_CORE_HP := 0.85             # our core under this share of its hp: the core shield is recommended

# --- Reactions and body language (2026-10-06: ai_rival.gd "Reactions and body language",
# scripts/war/bot_cues.gd the "!" glyph and callout lines, astronaut.gd "Body language" the poses) ---
const BL_RANGE := 80.0                 # m from the camera: gestures, callouts, idle life (gameplay
                                       # parts, the spotting beat and the marking, run at any distance)
const BL_SAY_RANGE := 50.0             # m: a callout's line shows over the speaker's head (38)
const BL_SPOT_FORGET := 12.0           # s unseen before seeing him again is a new sighting
const BL_SPOT_BEAT := 0.95             # s from the sighting to its first shot (startle, point, callout) (2026-10-06 tok: 0.75 -> 0.95)
const BL_MARK_RANGE := 55.0            # m: teammates this near turn to the spot it reports...
const BL_MARK_LOOK := 3.0              # ...look there this long, and idle ones take cover facing it
const BL_CALL_GAP := 2.2               # s between two callouts team-wide...
const BL_CALL_CD := 7.0                # ...and per bot
const BL_SIGNAL_CD := 9.0              # s between two hand signals of a bot (move up / hold / cover me)
const BL_SQUAD_RANGE := 25.0           # m: a hand signal needs a teammate this near
const BL_COWER_K := 3.0                # a blast within its radius × this (outside the damage) makes it cower...
const BL_COWER_TIME := 1.3             # ...this long (crouched, hunched, a forearm over the visor)
const BL_DOWN_RANGE := 35.0            # m: a teammate's death this near: a look, a pause, "X düştü!"
const BL_WOUND_HP := 0.35              # below this share of hp: the limp, a hand on the side, "Yaralıyım!"
const BL_PINNED := 0.7                 # suppression (bot.suppression()) above this: hunched, "Bastırıldım!"
const BL_IDLE_GAP := Vector2(14.0, 30.0)   # s between two idle gestures (look around, stretch, rifle, visor)
const BL_REST_GAP := Vector2(45.0, 90.0)   # s of digging before a miner rests...
const BL_REST_TIME := 5.0                  # ...this long
const BL_INSPECT_GAP := Vector2(55.0, 95.0)    # s between an idle engineer's structure inspections
const BL_GREET_R := 6.0                # m: an ally greets the player coming this close...
const BL_GREET_CD := 45.0              # ...at most this often
const BL_NICE_SHOT_R := 25.0           # m: an ally this near a kill of the player's: thumbs up
const BL_HEAR_RANGE := 60.0            # m: gunfire heard (a suppressed gun: × its "noise" stat, ~21 m; 45 at R 30)
const BL_HEAR_CD := 4.0                # s between two hearing reactions of a bot
const BL_SUPP_FUZZ := 0.45             # a suppressed shot heard only as a near miss: where it came from is
                                       # guessed along the bullet's line with this much distance error

# ==================================================================================================
# COMBAT FEEL 2026-10-06: cover erosion, enemy fire readability, bot suppression
# ==================================================================================================

# --- Cover erosion ("Mermilerin siperi aşındırması"; scripts/war/erosion.gd, fed by rifle_fx.gd
# impact_terrain and enemy_fire.gd). Every terrain hit adds its weight to a cell of a sparse per-planet
# grid; past the threshold the host bites one small dig brush there (Dig.dig_at, team "", synced by the
# planet's net hook) and the cell drops to EROSION_RESET × the threshold. ~9 rifle hits on one spot:
# the first notch; every ~5 more: the next.
const EROSION_CELL := 0.8              # m: grid cell (local to the planet node)
const EROSION_THRESHOLD := 9.0         # weight for a bite
const EROSION_DECAY := 0.2             # weight / s a cell loses (scattered fire never bites)
const EROSION_RESET := 0.45            # share of the threshold a cell keeps after a bite
const EROSION_W_PELLET := 0.4          # weight per hit: shotgun pellet (impact calibre ~0.65)...
const EROSION_W_SMG := 0.7             # ...SMG (0.7)...
const EROSION_W_RIFLE := 1.0           # ...rifle round (1.0)...
const EROSION_W_AP := 2.0              # ...AP round (1.6)...
const EROSION_W_SNIPER := 4.0          # ...sniper (2.2)
const EROSION_W_BOT := 1.0             # a bot's rifle miss (enemy_fire.gd)
const EROSION_BRUSH_R := 0.55          # m: the bite (centred on the nearest solid voxel corner: one corner)
const EROSION_BRUSH_AMOUNT := 0.6      # density taken off that corner (~0.6 m of the surface)
const EROSION_BRUSH_DEPTH := 0.35      # m under the impact the corner is looked for
const EROSION_BRUSH_RATE := 4.0        # bites / s, all shooters together (net_terrain batches at 15 Hz)
const EROSION_BRUSH_BURST := 2.0       # token bucket depth
const EROSION_STRUCT_MARGIN := 1.0     # m beyond a structure's footprint_r: never bitten
const EROSION_CORE_MARGIN := 2.5       # m beyond CORE_RADIUS: never bitten
const EROSION_FEET_R := 1.2            # m: the column under a player's feet is never bitten
const EROSION_MAX_CELLS := 3000        # cells per planet (decayed ones are pruned first)

# --- Enemy fire readability ("Düşman ateşinin okunması"; scripts/war/enemy_fire.gd, the bots' shots
# from ai_rival.gd _shoot_update; the incoming-grenade marker: scripts/ui/grenade_warn.gd).
const EF_TRACER_SPEED := 420.0         # m/s the drawn streak flies (the hit itself is instant)
const EF_TRACER_EVERY := 3             # every 3rd shot draws no streak (2 of 3 do)
const EF_TRACER_LEN := 6.0             # m: longest streak
const EF_TRACER_WIDTH := 1.6           # × the player's tracer thickness (widened with distance too)
const EF_ENEMY_COLOR := Color(1.0, 0.2, 0.07)    # the other side's tracers (also foreign guns, rifle_fx.gd)
const EF_FRIEND_COLOR := Color(1.0, 0.8, 0.45)   # our side's (ally bots)
const EF_FLASH_COLOR := Color(1.0, 0.62, 0.3)
const EF_FLASH_SIZE := 0.45            # m: muzzle star
const EF_FLASH_PX := 0.014             # its halo never smaller than this × distance (~10 px at 1080p)
const EF_FLASH_TIME := 0.08            # s
const EF_MISS_EXTEND := 40.0           # m a miss flies on past its aim point
const EF_RAY_NEAR := 30.0              # m: misses passing the camera this close get a ray (impacts, erosion)
const EF_IMPACT_FX_RANGE := 90.0       # m: impact dust / sparks only this close to the camera
const EF_FX_RANGE := 300.0             # m: shots farther than this from the camera draw nothing
const GRENADE_HUD_RANGE := 10.0        # m: live enemy hand grenades this near get the HUD marker

# --- Bot suppression ("Botların baskı altında kalması"; ai_rival.gd "Suppression"). A meter 0..1 fed
# by near misses (within AI_SUP_NEAR_R), bullet impacts (within AI_SUP_IMPACT_R, erosion.gd), nearby
# blasts and hits; pinned above AI_SUP_PIN (until it falls under AI_SUP_RELEASE): it ducks into cover
# or crouches, peeks less often and shorter, its bursts lose accuracy, it never advances / flanks,
# and falls back when exposed. It drains AI_SUP_DECAY / s once AI_SUP_HOLD s pass without fire
# (AI_SUP_DECAY_FIRE while still under fire): ~2-3 s from pinned to calm.
const AI_SUP_NEAR_R := 3.0             # m: a round passing this close cracks
const AI_SUP_NEAR_MISS := 0.2          # meter per crack (× 1 at 0 m .. × 0.5 at AI_SUP_NEAR_R)
const AI_SUP_IMPACT_R := 2.2           # m: a bullet impact this close throws dirt at it
const AI_SUP_IMPACT := 0.09            # meter per impact × its erosion weight (capped at 2)
const AI_SUP_BLAST := 0.75             # meter for a blast at the bot (falls off to 0 at 3 × its radius)
const AI_SUP_HIT := 0.25               # meter per hit taken
const AI_SUP_HOLD := 0.7               # s after the last event before it drains
const AI_SUP_DECAY := 0.4              # meter / s (a full meter: released ~2.2 s, calm ~3 s after the fire)
const AI_SUP_DECAY_FIRE := 0.12        # meter / s while events keep coming
const AI_SUP_PIN := 0.55               # pinned from here...
const AI_SUP_RELEASE := 0.3            # ...until it falls below this
const AI_SUP_ACC_RATTLED := 0.85       # hit chance × this just under the pin (× 1 calm)...
const AI_SUP_ACC_PIN := 0.6            # ...× this once pinned...
const AI_SUP_ACC := 0.4                # ...down to × this at a full meter
const AI_SUP_SPREAD := 1.8             # miss spread × this at a full meter (wild bursts)
const AI_SUP_PEEK := 0.45              # pinned in cover: peeks × this long...
const AI_SUP_HIDE := 2.2               # ...and hides × this long
const AI_SUP_FLINCH_R := 1.2           # m: a crack this close makes it flinch (no aim for AI_SUP_FLINCH s)
const AI_SUP_FLINCH := 0.22
const AI_SUP_FALLBACK := 2.0           # s it runs back from the threat when pinned in the open

# --- Mantle ---------------------------------------------------------------------------------------
# Ledge grab and climb (2026-10-06; scripts/player/mantle.gd): jump at a crater rim, a tunnel mouth or
# a structure and the hands plant on the edge, pull up and over. Heights from the feet; m, s, m/s.
const MANTLE_MIN_H := 0.45             # lowest ledge a jump on the ground mantles (lower: the jump clears it)
const MANTLE_AIR_MIN_H := 0.3          # lowest in the air (the capsule would catch on the lip)
const MANTLE_MAX_H := 1.9              # highest ledge the hands reach
const MANTLE_VAULT_H := 1.0            # about here a quick one-handed vault turns into a full mantle
const MANTLE_REACH := 0.55             # m past the capsule (r 0.35) a wall is grabbed...
const MANTLE_REACH_LEAD := 0.06        # ...plus this many seconds of the run-in speed (no bump first)
const MANTLE_LEDGE_IN := 0.3           # m past the wall face the top is probed
const MANTLE_MAX_SLOPE := 45.0         # degrees: the top must be walkable
const MANTLE_WALL_FACING := 0.4        # wall normal · (-forward) at least this (~66°)
const MANTLE_MAX_FALL := 6.5           # falling faster than this: no catch
const MANTLE_T_RISE := Vector2(0.2, 0.38)     # s the pull up takes, lowest .. highest ledge
const MANTLE_T_OVER := Vector2(0.14, 0.26)    # s over onto the top
const MANTLE_KEEP_SPEED := Vector2(0.9, 0.65) # share of the run-in speed kept, vault .. full mantle...
const MANTLE_EXIT_SPEED := Vector2(1.8, 7.5)  # ...within these (m/s forward at the end)
const MANTLE_COOLDOWN := 0.3           # s after one before the next
const MANTLE_HIT_ABORT := 3.0          # m/s of outside velocity change (a hit's knockback) lose the grab
const MANTLE_EXERTION := Vector2(0.04, 0.09)  # helmet_fx.gd exertion added, vault .. full mantle
const MANTLE_CAM_DIP := 0.07           # rad the view dips at the pull
const MANTLE_CAM_ROLL := 0.045         # rad of roll toward the leading (left) hand
const MANTLE_FOV := 4.0                # degrees of FOV ease over the top

# --- Drill heat and upgrades ------------------------------------------------------------------------
# The drill heats while it works and vents on R (scripts/items/drill_heat.gd, the logic; the tool
# scripts/player/terrain_tool.gd): past DRILL_VENT_OPEN of its heat a vent window opens, a marker
# sweeps the heat gauge (drill side strip, wrist, quickbar) over DRILL_VENT_SWEEP s; R in the white
# sweet spot = instant cool + SÜPER KAZI (DRILL_SUPER_T s at DRILL_SUPER_MULT rate), in the amber zone
# = a partial cool, anywhere else = a jam (DRILL_JAM_T s lockout); ignored to the top = an overheat
# lockout. Upgrades Mk II-IV (scripts/items/drill_tiers.gd) are made at the Silahlık through the
# craft.gd recipes "drill_mk2" .. "drill_mk4" (each needs the one before; a new match resets them).
# Per-tier arrays: [Mk I (base), Mk II, Mk III, Mk IV]. The rates scale the tool's RATE and
# DRILL_MAX_RATE above, whatever those are tuned to.
const DRILL_HEAT_MAX := [100.0, 115.0, 130.0, 150.0]    # heat units (the gauge's full scale)
const DRILL_HEAT_RISE := 8.0           # heat / s working at full power with the default 2.2 m brush...
const DRILL_HEAT_RADIUS_K := 0.45      # ...× (1 − K + K × radius / 2.2): a 5 m brush heats ~1.6 ×
const DRILL_HEAT_COOL := 16.0          # heat / s idle (× DRILL_TIER_COOL)...
const DRILL_HEAT_COOL_DELAY := 0.5     # ...from this long after the drill stops
const DRILL_VENT_OPEN := 0.6           # heat share that opens the vent window (Mk I: ~7.5 s of digging)
const DRILL_VENT_CLOSE := 0.5          # it closes again below this (stopped digging and cooled)
const DRILL_VENT_SWEEP := [1.6, 1.5, 1.4, 1.3]           # s the marker takes across the gauge (repeats)
const DRILL_VENT_ZONE := 0.34          # gauge share of the amber (good) zone: ~0.54 s at Mk I
const DRILL_VENT_SWEET := 0.13         # the white sweet spot inside it: ~0.21 s at Mk I
const DRILL_VENT_ZONE_C := Vector2(0.42, 0.78)   # the zone's centre is placed in here, per window
const DRILL_VENT_GOOD_COOL := 0.5      # a good vent takes this share of the max heat off
const DRILL_SUPER_T := 7.0             # s of SÜPER KAZI after a perfect vent...
const DRILL_SUPER_MULT := 1.4          # ...dig rate and material cap × this...
const DRILL_SUPER_HEAT := 0.6          # ...heat rise × this (the next window comes ~10 s after the vent)
const DRILL_JAM_T := 2.2               # s locked after a missed vent; heat eases down to...
const DRILL_JAM_END := 0.45            # ...this share meanwhile
const DRILL_OVERHEAT_T := 3.2          # s locked after an ignored window reaches the top...
const DRILL_OVERHEAT_END := 0.25       # ...heat down to this share by the end
const DRILL_TIER_RATE := [1.0, 1.2, 1.4, 1.65]  # (2026-10-07: 1.3 / 1.65 / 2.1; the bank pays tiers in full now)         # × the tool's RATE and × DRILL_MAX_RATE
const DRILL_TIER_RADIUS := [5.0, 5.5, 6.0, 6.25]          # max brush radius (m; the net encodes ≤ 6.3)
const DRILL_TIER_COOL := [1.0, 1.25, 1.5, 1.8]            # × DRILL_HEAT_COOL
## Mk III+: soil a crater (planet.gd crater_done: shells, rockets, grenades, either side's) throws out
## within DRILL_AUTO_RADIUS m of you (plus the crater's radius) is credited at this share (half at
## the edge), at most DRILL_AUTO_MAX m³ per crater. Probe (2026-10-06): a cannon shell's crater throws
## ~110-125 m³ (Mk III ~40, Mk IV ~55-60 = ~5 s of Mk I digging), a rocket's ~10 (Mk IV 5 < its 8 m³
## round: no farming), a grenade's ~3, a meteor's / a 3 m crater ~20 (Mk IV ~10).
const DRILL_AUTO_SHARE := [0.0, 0.0, 0.35, 0.5]
const DRILL_AUTO_RADIUS := [0.0, 0.0, 18.0, 24.0]
const DRILL_AUTO_MAX := 50.0           # (120; 2026-10-06 economy pass: one crater ≤ ~5 s of digging)
## Mk IV: hold E for the burst bore: after DRILL_BORE_CHARGE s it drives a straight DRILL_BORE_LEN m
## tunnel (radius DRILL_BORE_RADIUS) along the view from the aim point in DRILL_BORE_T s; the soil is
## credited at DRILL_BORE_CREDIT, at most the drill's own rate cap (DRILL_MAX_RATE × tier × SÜPER) over
## one bore cycle (CHARGE + T + COOLDOWN; 2026-10-06 economy pass, was uncapped; probe: ~12 m³ of soil
## a bore = ~9 m³ credited, ~5.6 m³/s held on, under the cap anyway); each bore adds DRILL_BORE_HEAT
## of the max heat. Held on, it bores again after DRILL_BORE_COOLDOWN s.
const DRILL_BORE_CHARGE := 0.3
const DRILL_BORE_LEN := 3.0
const DRILL_BORE_RADIUS := 1.25
const DRILL_BORE_T := 0.5
const DRILL_BORE_STEP := 0.5           # m between the shaft's brushes (16 density each, like the buster)
const DRILL_BORE_CREDIT := 0.75
const DRILL_BORE_HEAT := 0.3
const DRILL_BORE_COOLDOWN := 0.8
const DRILL_CRAFT_COST := {"drill_mk2": 250.0, "drill_mk3": 550.0, "drill_mk4": 1000.0}
const DRILL_CRAFT_TIME := {"drill_mk2": 8.0, "drill_mk3": 12.0, "drill_mk4": 16.0}
## Juice: a "+N" material popup on the wrist (with a rising tick ladder) every DRILL_POP_T s of
## digging; the camera holds a faint shake (player trauma) while boring.
const DRILL_POP_T := 0.5
const DRILL_SHAKE := 0.2               # trauma held digging at full power (SÜPER KAZI 0.26, bore 0.5)

# --- Buried caches ---------------------------------------------------------------------------------
# Gömülü sandıklar ve eski kalıntılar (2026-10-06; scripts/war/caches.gd, cache_prop.gd, cache_buffs.gd):
# a few old caches lie buried in each planet, placed from the planet's seed (the same on every
# machine). Digging one free (air within CACHE_EXPOSE_R of its centre) shows it: a dirt burst, a
# glint, a chime, "Gömülü sandık bulundu!"; F opens it (CACHE_OPEN_TIME s) and spills what it holds.
# Deeper (and in the contested front) = rarer kinds and richer contents. Bots ignore them.
const CACHE_COUNT := Vector2i(12, 18)      # caches per planet (min, max)
const CACHE_DEPTH := Vector2(2.0, 14.0)    # m from the original ground down to a cache's centre...
const CACHE_DEPTH_BIAS := 1.6              # ...lerp(min, max, rand^this): most lie shallow
const CACHE_SPACING := 9.0                 # m (along the surface) between two caches at least
const CACHE_BASE_CLEAR := 16.0             # m (along the surface) kept clear around each base
const CACHE_CONTESTED_SHARE := 0.35        # share placed in the contested front...
const CACHE_FRONT_ANGLE := 50.0            # ...within this many degrees of the point facing the other planet
const CACHE_POI_REACH := 6.0               # (with combat areas, scripts/planet/poi.gd: around a site, ≤ its footprint + this m)
const CACHE_POI_MIN_DEPTH := 4.0           # m: under a site's footprint (trenches, stamped terrain) a cache lies at least this deep
const CACHE_CONTESTED_BONUS := 0.25        # richness added there (0..1; the depth gives 0..0.75)
const CACHE_NODE_R := 25.0                 # m from the player: a cache gets its model and collider (pooled)
const CACHE_POOL := 6                      # models at most at once
const CACHE_EXPOSE_R := 0.8                # m: air this close to the centre digs it free
const CACHE_TINK_R := 4.0                  # m: our drill this close to a buried one: a metallic tink
const CACHE_TINK_GAP := 1.1                # s between two tinks of one cache
const CACHE_FOUND_R := 30.0                # m: dug free this close to us = burst, chime, toast
const CACHE_OPEN_TIME := 0.8               # s of the lid / latch animation before the contents spill
## Kinds: weights at the poorest (x) and the richest (y) roll (crate common, relic rare).
const CACHE_KIND_W := {"crate": Vector2(70.0, 28.0), "kitbag": Vector2(18.0, 24.0), "locker": Vector2(10.0, 30.0),
		"relic": Vector2(2.0, 18.0)}
## Contents: rolls per kind (min, max) from weighted tables. "mat" material (CACHE_MAT m³ by the
## richness, to the opener), "gren" grenades (CACHE_GRENADES, capped at GRENADE_MAX; one grenade roll per
## cache, a second becomes "mat"), "att" an attachment the opener does not own yet (else CACHE_ATT_FALLBACK
## m³), "gun" a gun on the ground (CACHE_GUN_W; one per cache, a second becomes "att"). Relics always hold
## a buff (CACHE_RELIC_W) on top. Probe (2000 rolls each): gun in ~3 % of crates, ~12 % of kit bags, ~27 %
## of lockers; ~0.15 / 0.4 / 0.85 / 0.35 attachments per crate / bag / locker / relic.
const CACHE_ROLLS := {"crate": Vector2i(1, 2), "kitbag": Vector2i(2, 2), "locker": Vector2i(2, 3), "relic": Vector2i(1, 1)}
const CACHE_TABLE := {
	"crate": {"mat": 60.0, "gren": 28.0, "att": 10.0, "gun": 2.0},
	"kitbag": {"mat": 35.0, "gren": 40.0, "att": 19.0, "gun": 6.0},
	"locker": {"mat": 40.0, "gren": 15.0, "att": 33.0, "gun": 12.0},
	"relic": {"mat": 65.0, "att": 35.0},
}
## (2026-10-06 economy pass: 40..250; a planet held ~1550-1900 m³ in 8-12 bundles of ~150-190 m³, ~6 s
## of digging at DRILL_MAX_RATE 30. Now (probe) bundles of ~110-150 m³ = ~11-15 s at 10 m³/s, a whole
## cache ≤ ~27 s.)
const CACHE_MAT := Vector2(30.0, 200.0)    # m³ per material bundle: poorest .. richest
const CACHE_GRENADES := Vector2i(2, 4)     # grenades per roll
const CACHE_ATT_FALLBACK := 120.0          # m³ instead of an attachment when every one is owned
const CACHE_GUN_W := {"shotgun": 22.0, "smg": 22.0, "sniper": 18.0, "pusher": 12.0, "rocket": 14.0, "rail": 12.0}
const CACHE_GUN_RESERVE := 1.0             # × the gun's CRAFT_RESERVE comes along as reserve
## Relic buffs (scripts/war/cache_buffs.gd), one each, CACHE_BUFF_TIME s. "quiet" (bots hear you
## less) stays 0 until ai_rival.gd's hearing reads CacheBuffs.noise_mult().
const CACHE_RELIC_W := {"dig": 30.0, "shield": 30.0, "scan": 25.0, "quiet": 0.0}
const CACHE_BUFF_TIME := Vector2(60.0, 90.0)
const CACHE_DIG_MULT := 1.5                # "Kazı hızı +50 %": our drill's strength × this
const CACHE_SHIELD_HP := 60.0              # "Kalkan": damage it absorbs, then it breaks
const CACHE_QUIET_MULT := 0.5              # "Sessiz adım": bots' hearing range × this (once hooked)
const CACHE_SCAN_RATE := 3.0               # "Tarayıcı şarjı": recharged at once, then × this fast

# --- Veins and meteors ---------------------------------------------------------------------------------
# Zengin damarlar (scripts/planet/veins.gd: capsules placed from the planet seed; the drill credits its
# soil × the vein's multiplier, the same generic soil) and Göktaşı yağmuru (scripts/war/meteor_shower.gd,
# host / single player: rich meteor cores in fresh craters). m, s, m³; Vector2 = (min, max).
const VEIN_COUNT_MIN := 12             # ordinary veins per planet...
const VEIN_COUNT_MAX := 20
## 2026-10-06 economy pass (probe, the drill dug straight at each vein): the drill pays ~50-80 % of a
## vein's nominal extra (vol × (mult - 1)) before the brush has carved it out. Now an ordinary vein
## (~18-27 m³) ≈ +40 m³ (~4 s of digging at DRILL_MAX_RATE 10), a rich one (~25-50 m³) ≈ +90-180 m³
## (~9-18 s). (Was ×4-6 / ×8-10 against a drill that really paid ~5-9 m³/s.)
const VEIN_MULT_MIN := 3               # ...worth × this much soil (whole numbers) (4)
const VEIN_MULT_MAX := 4               # (6)
const VEIN_LEN := Vector2(2.0, 5.0)    # capsule axis length
const VEIN_R := Vector2(0.8, 1.4)      # capsule radius
const VEIN_DEPTH := Vector2(1.5, 15.0) # centre below the original surface (shallow ones more often)
const VEIN_COVER := 1.4                # at least this much original soil over a vein's top
const VEIN_EDGE := 0.5                 # the multiplier falls to 1 over this many m outside a vein
const RICH_COUNT_MIN := 4              # rich veins per planet, in the contested zones...
const RICH_COUNT_MAX := 8
const RICH_MULT_MIN := 6               # ...worth × this much (8)
const RICH_MULT_MAX := 8               # (10)
const RICH_LEN := Vector2(3.0, 5.5)
const RICH_R := Vector2(1.1, 1.7)
const RICH_DEPTH := Vector2(2.5, 8.0)
const RICH_SPREAD := 10.0              # m (arc) around a contested centre
const VEIN_HOTSPOTS := 2               # random contested hot spots on the facing half (no POIs)
const VEIN_DRILL_K := 0.45             # Veins.drill_rate_k inside a vein (optional for the drill)
const VEIN_GLOW_FULL := 0.35           # a vein glows fully until this share is left...
const VEIN_SPENT := 0.05               # ...and is dark (spent) below this
const VEIN_SHADER_MAX := 40            # capsules the terrain shader takes per planet (veins + cores)
const VEIN_CRYSTALS_PER_VEIN := 6      # crystal clusters sprouting from the dug walls (vein_fx.gd)...
const VEIN_CRYSTALS_MAX := 48          # ...in all
const VEIN_TOAST_GAP := 8.0            # s before the same vein toasts "Zengin damar!" again
const VEIN_BONUS_RATE := 60.0          # m³/s Veins.vein_bonus pays out its bank at most (optional drill path)
# Göktaşı yağmuru
const METEOR_FIRST := 150.0            # s into the match before the first shower...
const METEOR_GAP := Vector2(180.0, 300.0)   # ...then one every this many s
const METEOR_COUNT := Vector2i(2, 4)   # meteors per shower ((3, 6); 2026-10-06 economy pass)
const METEOR_WARN := 6.0               # s of "GÖKTAŞI YAĞMURU!" before the first one strikes
const METEOR_STAGGER := Vector2(0.5, 1.6)   # s between launches
const METEOR_FLIGHT := 3.6             # s from METEOR_START_DIST out to the impact
const METEOR_START_DIST := 230.0
const METEOR_RIVAL_SHARE := 0.6        # share of showers on the rival planet (the rest on ours)
const METEOR_SPREAD := 16.0            # m (arc) of the impacts around the shower's centre...
const METEOR_SPACING := 6.0            # ...at least this far apart...
const METEOR_STRUCT_CLEAR := 10.0      # ...and this far from any structure
## m³ a core is worth (× its multiplier over its volume). 2026-10-06 economy pass: (150, 300) = 5-10 s
## of the old drill. Probe: the drill pays ~100-110 % of the amount in ~1.5 s: a core ≈ 20-38 s of
## digging, a shower (2-4 cores) ≈ 1-2 min of it, on our planet every ~10 min (METEOR_RIVAL_SHARE).
const METEOR_AMOUNT := Vector2(200.0, 350.0)
const METEOR_CORE_R := 1.6             # the core's sphere under the crater floor
const METEOR_CORE_FLOOR := 0.5         # the crater floor lies this far above the core's centre
const METEOR_MULT := Vector2(6.0, 30.0)     # the core's multiplier is clamped to this
const METEOR_LIFE := 240.0             # s a core lasts before it crumbles
const METEOR_CRATER_R := 3.0           # planet.crater radius...
const METEOR_CRATER_DEPTH := 3.0       # ...and depth (both × CRATER_SCALE as usual)
const METEOR_BLAST_R := 6.0            # the impact blast (Explosion: damage, shove; team "meteor")
const METEOR_DAMAGE := 70.0
const METEOR_IMPULSE := 12.0
const METEOR_HUD_MARKERS := 4          # war_hud.gd: markers for the nearest cores
# Rival bots prospecting (rival_team.gd / ai_rival.gd "Prospecting")
const VN_TEAM_SCAN := 2.0              # s between the team's target scans
const VN_MAX_BOTS := 3                 # bots prospecting at once (all targets; a meteor core takes one off a vein)...
const VN_BOTS_PER_METEOR := 2          # ...per meteor core...
const VN_BOTS_PER_VEIN := 1            # ...per rich vein
const VN_BOT_VEIN_RANGE := 60.0        # m (arc) from the base: rich veins the team goes for
const VN_BOT_VEIN_DEPTH := 5.0         # m of soil over a vein's top at most
const VN_BOT_VEIN_LEFT := 0.25         # a vein is left once less than this share is solid
const VN_BOT_DIG_R := 1.3              # its brush (a real one, outside AI_MAX_BRUSHES)...
const VN_BOT_DIG_RATE := 6.0           # ...density / s (AI_DIG_HZ ticks; AI_DIG_RATE 7)
const VN_BOT_GATHER := 0.5             # pool bonus: the dug share's worth (Veins.take_gain) × this
const VN_BOT_TIMEOUT := 120.0          # s on one target at most

# --- Supply pods / loadout --------------------------------------------------------------------------
# 2026-10-06 (the user: crafting guns at the Silahlık slowed the game down). Everyone spawns armed: the
# loadout's slot A (LOADOUT_A) and slot B (one of LOADOUT_B), picked at the match start and on every
# respawn ride (scripts/war/respawn_ship.gd + loadout_panel.gd; Game.set_loadout). Power weapons
# (SUPPLY_GUNS) are called in anywhere by İkmal kapsülü (scripts/war/supply_pod.gd, the menu
# scripts/war/supply_menu.gd on Tab): pay SUPPLY_COST, a small pod lands next to you SUPPLY_DELAY s
# later (the enemy's Uçaksavar / Otomatik Taret may shoot it down) and the gun pops out as a ground
# pickup (hold F; a loot gun: lost on death). The Silahlık sells permanent upgrades only, instantly.
## 2026-10-07 (the user: "herkes tüfekle başlasın; ikinci silah seçeneği olarak tabanca vs"): slot A is
## the primary (ANA SİLAH: rifle by default, or the SMG / shotgun), slot B the sidearm or utility (YAN
## SİLAH: Tabanca by default, Altıpatlar, Makineli Tabanca, Toprak Topu). Game.GUN_ORDER lists the A
## choices before the B ones, so the primary is on key 1 and the sidearm on key 2.
const LOADOUT_A := ["rifle", "smg", "shotgun"]           # slot A choices (the first is the default)
const LOADOUT_B := ["pistol", "revolver", "mpistol", "dirt"]  # slot B choices (the first is the default)
const LOADOUT_GRENADES := 2            # grenades at the match start; a respawn tops them up to this
const LOADOUT_RESERVE := 1.0           # × the loadout guns' CRAFT_RESERVE: the start, a respawn tops up to it
const LOADOUT_START_PICK := true       # the A / B picker comes up once at the match start (not in training)
const SUPPLY_GUNS := ["sniper", "pusher", "rocket", "rail", "plasma", "mortar"]   # the call-in menu's order (keys 1-6)
## m³ per pod. The old craft prices (350 / 300 / 450 / 550) bought a gun for good; a pod gun is lost on
## death. 2026-10-06 economy pass (DRILL_MAX_RATE 30 -> 10, the zones ~2.9 m³/s): prices kept, now
## ~20-35 s of digging each (were ~10-15 s): a power weapon is an investment, about half a cannon.
const SUPPLY_COST := {"sniper": 240.0, "pusher": 200.0, "rocket": 280.0, "rail": 340.0, "plasma": 260.0, "mortar": 300.0}
const SUPPLY_COOLDOWN := 45.0          # s from a call to the next one (per player; a refused call clears it)
const SUPPLY_DELAY := 7.0              # s from the call to the touchdown
const SUPPLY_ALT := 150.0              # m above the landing spot it starts (the surfaces are ~190-230 m apart)
const SUPPLY_TILT := 0.45              # m sideways per m of height up high (~24° slant), vertical over the last ~40 m
const SUPPLY_RETRO_T := 1.6            # s of retro braking before the touchdown...
const SUPPLY_LAND_SPEED := 5.0         # ...down to this (m/s)
const SUPPLY_DIST := Vector2(5.0, 10.0)   # m from the caller where it may land (in front of him first)
const SUPPLY_CLEAR := 2.5              # m kept from structures (beyond their footprint), skiffs and pods
const SUPPLY_MAX_DEPTH := 3.5          # m under the open ground at most: deeper, the call is refused
const SUPPLY_HITS := 2                 # enemy flak bursts / turret strings that destroy it in flight
const SUPPLY_GUN_POP := 0.6            # s from the touchdown to the gun popping out
const SUPPLY_RESERVE := 1.0            # × the gun's CRAFT_RESERVE comes along (on top of a full magazine)
const SUPPLY_WRECK_TIME := 40.0        # s the empty pod stays (cover), then sinks away
const SUPPLY_REPLY_TIMEOUT := 6.0      # multiplayer client: no word from the host in this long = refund
const SUPPLY_HOST_GAP := 0.8           # host: a client's calls at most this × SUPPLY_COOLDOWN apart
# Silahlık upgrades (craft.gd upgrade_recipes(): instant, kept until the match ends, each level needs
# the one before; Game.upgrade_level). İkmal indirimi: cheaper pods. Bomba kemeri: more grenades carried.
const UPG_POD_DISCOUNT := [0.0, 0.15, 0.3]   # share off SUPPLY_COST at level 0, 1, 2
const UPG_POD_COST := [0.0, 260.0, 520.0]    # m³ for level 1, 2
const UPG_POUCH := [0, 5, 10]                # grenades carried over GRENADE_MAX at level 0, 1, 2
const UPG_POUCH_COST := [0.0, 160.0, 320.0]

# --- Cave-ins and entrench ------------------------------------------------------------------------
# Tunnel collapse ("Tünel çökertme", 2026-10-06; scripts/war/cave_in.gd, host-authoritative) and the
# quick foxhole ("Hızlı siper": X on foot, scripts/player/entrench.gd; pinned bots: ai_rival.gd
# "Cave-ins and entrench"). A roof is weak when the soil over a cavity is thinner than CAVE_ROOF_THIN
# and the cavity's narrowest width just under it is at least CAVE_SPAN_MIN. Its stress (0..1) builds
# with digging near it, blasts and bullets on it; at CAVE_WARN it groans (cracks, dust, clods; at least
# CAVE_WARN_MIN s), at 1 it comes down: FLATTEN brushes fill the cavity up to the old ceiling and drop
# the crust into a shallow sinkhole; whoever's chest ends up in the soil is buried. m, s, damage.
const CAVE_ROOF_THIN := 1.2            # m of soil over a cavity: thinner is a weak roof...
const CAVE_SPAN_MIN := 3.5             # ...over a cavity at least this wide (its narrowest width) under it
const CAVE_SPAN_DEPTH := 0.6           # m under the ceiling the width is measured
const CAVE_SPAN_PROBE := 7.0           # m each way the width probe looks
const CAVE_CEIL_PROBE := 5.0           # m up from a dug point a ceiling is looked for
const CAVE_FLOOR_PROBE := 6.0          # m down to the cavity floor
const CAVE_MIN_BRUSH_R := 0.9          # smaller brushes (erosion bites) never wake a roof
const CAVE_ANALYSE_GAP := 0.12         # s between roof checks (one at a time, queued and coalesced)
const CAVE_DIG_STRESS := 0.16          # stress per s of digging under / near a weak roof (× its severity 0.6-2)
const CAVE_AI_DIG_K := 0.3             # × that for digs with no player within 7 m (bots); they never pass CAVE_WARN
const CAVE_BLAST_STRESS := 0.75        # a blast at the roof (× severity), 0 at CAVE_BLAST_REACH × its radius
const CAVE_BLAST_REACH := 1.6
const CAVE_SHOT_STRESS := 0.045        # per bullet striking the roof (× 2 once it groans)
const CAVE_STRESS_R := 2.5             # m past a roof's radius digs still load it
const CAVE_WARN := 0.45                # the roof groans from here...
const CAVE_WARN_MIN := 1.4             # ...at least this long before it falls (s)
const CAVE_CREEP := 0.11               # stress per s once groaning (0.45 -> 1 in 5 s on its own)
const CAVE_DECAY := 0.02               # stress per s below CAVE_WARN
const CAVE_FILL_OVER := 0.15           # m over the old ceiling the fill plane sits
const CAVE_FILL_AMOUNT := 8.0          # FLATTEN strength of the fill brushes
const CAVE_FILL_R_MIN := 2.5           # fill brush radius range (from the span and the cavity height)
const CAVE_FILL_R_MAX := 5.0
const CAVE_FILL_GAP := 0.3             # s between the fill brushes (at most 3 per collapse)
const CAVE_STRUCT_MARGIN := 1.5        # m: no collapse this close to a structure's footprint (a core: 8 m)
const CAVE_BURY_DMG := 35.0            # buried by the fill (head free: × 0.6)
const CAVE_DROP_DMG := 8.0             # standing on the crust when it drops (then stuck in the rubble...
const CAVE_DROP_DELAY := 0.4           # ...from this many s later, once fallen; ~0.4 × CAVE_BOT_DIG_T / CAVE_AUTO_FREE × 0.25)
const CAVE_SUFFOCATE_DELAY := 1.5      # s buried (head under) before suffocating...
const CAVE_SUFFOCATE_DMG := 4.0        # ...this much per second
const CAVE_DIG_OUT_DRILL := 1.0        # s of the drill's trigger held to dig out...
const CAVE_DIG_OUT_MELEE := 0.4        # ...or this much per melee swing (V)...
const CAVE_DIG_OUT_JUMP := 0.14        # ...or per Space press (head free: × 1.8)
const CAVE_AUTO_FREE := 10.0           # s: out on your own anyway (head free: × 0.5)
const CAVE_BOT_DIG_T := Vector2(3.0, 5.5)   # s a buried bot / dummy is stuck before it digs out
const CAVE_MAX_SITES := 24             # weak roofs remembered at once (the calmest is forgotten)
# Quick entrench (X on foot, any item but the build tool): a left-hand slam, a crescent berm
# ENTRENCH_DIST ahead (3 RAISE brushes, ~1.1 m high, ~2.5 m wide) and a shallow scrape at the feet
# (DIG, ~0.4 m), ENTRENCH_BRUSH_GAP s apart.
const ENTRENCH_COST := 5.0             # m³ of material
const ENTRENCH_COOLDOWN := 7.0         # s from one to the next
const ENTRENCH_DIST := 1.55            # m to the berm's middle (crest ~1.0-1.3 m high at 1-2 m ahead,
const ENTRENCH_CURL := 0.25            # ...its ends this much closer (a crescent)  ~2.5 m wide; probed)
const ENTRENCH_HALF_W := 0.95          # m from the middle to the end brushes
const ENTRENCH_R := 1.05               # berm brush radius (1.0 sometimes misses voxel corners)...
const ENTRENCH_LIFT := 0.45            # ...centred this high over the ground...
const ENTRENCH_AMOUNT := 4.0           # ...this strong
const ENTRENCH_SCRAPE_R := 1.25        # the scrape at the feet (0.3-0.7 m deep): a crouched head is covered
const ENTRENCH_SCRAPE_AMOUNT := 1.2
const ENTRENCH_BRUSH_GAP := 0.2        # s between its brushes (4 in 0.6 s)
const ENTRENCH_AI_CHANCE := 0.35       # a pinned bot with no cover raises one (this chance per roll)...
const ENTRENCH_AI_COOLDOWN := 25.0     # ...one roll at most this often (s per bot)

# --- Combat areas (POI) ---------------------------------------------------------------------------
# (2026-10-06; scripts/planet/poi.gd + poi_props.gd: mesas, trenches, tunnel hills, ruined outposts,
# crash sites, crater ridges, stamped into the terrain density at world build on every machine.)
const POI_ENABLED := true
const POI_COUNT := Vector2i(5, 7)      # areas per planet (min, max; deterministic from the planet seed)
const POI_BASE_CLEAR_K := 0.5          # no area within max(this × radius, POI_BASE_CLEAR_MIN) m (surface
const POI_BASE_CLEAR_MIN := 25.0       # arc) of a base centre: spawn, build area, pods, dropship rings
const POI_NEAR_BAND := 18.0            # m past the clear zone: the band of the first three ("near") areas
const POI_FAR_MIN := 1.15              # rad × radius: the other areas at least this far (the far side)
const POI_LANDMARK_CONE := 1.45        # rad: outpost / crash within this of the point facing the other planet
const POI_GAP := 4.0                   # m of open ground between two areas' footprints
const POI_MESA_H := Vector2(3.0, 6.0)  # m: rock pillar heights
const POI_TRENCH_DEPTH := 1.8          # m
const POI_TUNNEL_R := 1.55             # m: tunnel arch radius, centre 0.45 m lower (floor ~2.2 m wide, ceiling 2.65 m)
const POI_TOWER_H := Vector2(14.0, 20.0)   # m: the comm tower (0.3 × radius, clamped)
const POI_BEACON_BLINK := 0.6          # Hz: the tower's red light (the wreck's amber one × 0.6)

# --- Bölge kontrolü (scripts/war/control_points.gd; 2026-10-06 the user: "habire bir şey kazmak
# zorundayım" -> "A: income from holding ground" + "C: drop the small taxes") ---------------------
## Income from holding ground on top of the drill. Every combat area (POI) carries a zone; a team's n
## held zones pay zone_income(n) = CP_INCOME × n^CP_INCOME_EXP m³/s together (diminishing), each
## living core pumps CORE_PUMP m³/s.
## 2026-10-06 economy pass (the user: "oyun daha yavaş, tok hissettirmeli; şu anda hiç kazmaya gerek
## olmuyor"): was CP_INCOME 2.5 a zone + CORE_PUMP 8 = ~23 m³/s for your own 6 zones, more than the
## drill. Now your own planet (6 zones) ≈ 1.0 + 1.9 ≈ 2.9 m³/s, all 12 zones ≈ 4.3: about a third of
## a player who digs half the time (the drill ~9-10 m³/s while it works, DRILL_MAX_RATE); one zone
## ≈ +0.45, taking one of theirs (your 7th) ≈ +0.25 for you and -0.26 for them.
const CP_ENABLED := true
const CP_RADIUS := 10.0                # m along the surface around the beacon that is "in the zone"
const CP_HEIGHT := 14.0                # m above the beacon's ground that still counts (25 m below: tunnels)
const CP_CAPTURE_TIME := 8.0           # s for one unit to take a neutral zone (an owned one: neutralise first, as long again)
const CP_CAPTURE_EXTRA := 0.5          # each further unit of the same team adds this much capture speed...
const CP_CAPTURE_MAX_K := 2.0          # ...up to this ×
const CP_DRIFT_K := 0.35               # an empty zone drifts back toward its owner at this share of the speed
const CP_INCOME := 0.45                # m³/s of the first held zone (none while contested) (2.5 each)
const CP_INCOME_EXP := 0.8             # n held zones pay CP_INCOME × n^this: 1 0.45, 3 1.08, 6 1.89, 12 3.28
const CORE_PUMP := 1.0                 # m³/s each team earns from its living core (Çekirdek pompası) (8)
const CP_RAID_RANGE := 140.0           # m: a rival pod crew on our planet goes for our zones this close
const CP_LAND_NEAR := 30.0             # m: a pod landing spot this close to one of our zones...
const CP_LAND_BONUS := 60.0            # ...scores this much more (rival_team.gd _pick_landing)
const CP_ALERT_GAP := 12.0             # s between two "saldırı altında" toasts for one zone
## Free cannon shells ("C: küçük vergileri kaldır"): a player's cannon refills one free shell every
## CANNON_FREE_RELOAD s and holds CANNON_FREE_MAX; SHELL_COST is paid only to fire beyond them.
## 2026-10-06 economy pass: 3 every 20 s was 3 free shells a minute PER CANNON (~180 m³/min each, more
## than a digging player earns): now a trickle of one a minute per cannon, two to open a salvo.
const CANNON_FREE_MAX := 2             # (3)
const CANNON_FREE_RELOAD := 60.0       # (20)
## Co-op material (2026-10-06, the user: "herkesin bakiyesi ayrı olsun, ortak kurulan yapılar bize ve
## herkese versin o parayı sadece"): false = every player his own Game.material, as in PvP
## (net_coop.gd begin). Personal: digging, kills, loot, pickups, caches, meteors. TEAM income pays
## EACH teammate in full: the zones and the core pump (control_points.gd, on every machine) and the
## auto-miners (auto_miner.gd _pay + net_world _on_miner_produced). true = the old shared team pool.
const COOP_SHARED_POOL := false


## m³/s that n held zones pay together (control_points.gd income_rate): CP_INCOME × n^CP_INCOME_EXP.
static func zone_income(n: int) -> float:
	return CP_INCOME * pow(float(n), CP_INCOME_EXP) if n > 0 else 0.0


# --- Downed / revive (scripts/war/downed.gd, revive.gd, downed_pose.gd, scripts/player/downed_view.gd;
# 2026-10-07 the user: "ölünce takım arkadaşı yerde canlandırabilsin; pes edebilelim; yerdeki
# sürüklenebilsin; vazgeçmediyse kaldırabiliriz") --------------------------------------------------
## A lethal hit puts the player, the co-op partner and the bots DOWN (lying, crawling) instead of
## dead, unless it is overkill (below). Down: DN_BLEED_TIME s to live; a teammate holding F within
## DN_REVIVE_RANGE m for DN_REVIVE_TIME s gets it up at DN_REVIVE_HP × hp_max; Space held
## DN_GIVEUP_HOLD s gives up; every hit on it drains the bleed-out (a melee or ~2 rifle rounds kill).
## Confirmed deaths (bled out / gave up / finished) go on into the normal death + respawn.
const DN_ENABLED := true
const DN_BLEED_TIME := 25.0            # s on the ground before bleeding out
const DN_BLEED_REPEAT := 0.6           # × per earlier down of this unit since its last respawn (25, 15, 9 s)
const DN_BLEED_MIN := 8.0              # s, never less
const DN_CRAWL_SPEED := 0.8            # m/s on the belly
const DN_BOT_CRAWL_MAX := 4.0          # m a downed bot crawls (toward its medic / away from the threat)
## Overkill: the lethal hit kills outright (the death ragdoll as before) when any of these hold.
const DN_OVERKILL_HIT := 150.0         # one hit this big (rocket centre 200, shell 220, buster 180, torpedo 160)
const DN_OVERKILL_EXCESS := 70.0       # damage beyond the hp that was left (a grenade on a hurt unit)
const DN_HEAD_KILL := 45.0             # a lethal head hit this big (sniper, rail; not a rifle / SMG round)
const DN_OVERKILL_IMPULSE := 16.0      # m/s of shove on the lethal hit (thrown by a blast)
const DN_SPACE_ALT := 30.0             # m above the ground: no going down out there (flung into space)
## Finishing: each hit on a downed unit takes DN_FINISH_FLAT + damage × DN_FINISH_PER_HP s of its
## bleed-out (rifle 18: ~12.8 s, two rounds kill from full; melee 55: ~25.8 s, one kills).
const DN_FINISH_FLAT := 6.5
const DN_FINISH_PER_HP := 0.35
const DN_REVIVE_TIME := 4.0            # s of a held revive (the bleed-out pauses meanwhile)
const DN_REVIVE_RANGE := 1.8           # m from the reviver to the downed body
const DN_REVIVE_HP := 0.3              # × hp_max after the revive
const DN_REVIVE_BREAK_DMG := 20.0      # damage the reviver takes during a revive that breaks it
const DN_GETUP_TIME := 1.0             # s of the get-up after a revive (no control)
const DN_STAGGER_TIME := 1.2           # s after it on unsteady legs...
const DN_STAGGER_SPEED := 2.2          # ...capped at this many m/s
const DN_TAP_MAX := 0.25               # s: F let go sooner on a downed teammate = a tap (grab / drop the strap)
const DN_DRAG_SPEED := 1.6             # m/s cap of whoever drags
const DN_DRAG_DIST := 0.95             # m from the dragger's feet to the strap (the downed one's shoulders)
const DN_DRAG_BREAK := 2.6             # m: farther and the strap slips out of the hand
const DN_GIVEUP_HOLD := 1.5            # s of Space held to give up
## Bots revive teammates (rare and deliberate, "tok"): DN_MEDIC_DELAY s after the down, with chance
## DN_MEDIC_CHANCE per down, the nearest free bot within DN_MEDIC_RANGE m (not fighting, nothing in
## sight; the downed one not hit for DN_MEDIC_SAFE s) walks over, crouches and holds DN_REVIVE_TIME s.
const DN_MEDIC_RANGE := 35.0
const DN_MEDIC_DELAY := 3.0
const DN_MEDIC_CHANCE := 0.7
const DN_MEDIC_SAFE := 4.0
const DN_MEDICS_MAX := 2               # bots of one team on a revive at once
const DN_MEDIC_GIVEUP := 25.0          # s a medic may take to get there and finish, then it gives up
## Enemy bots mostly leave a downed target alone (it can be revived); with this chance per down the
## bot nearest to it keeps shooting until it is dead.
const DN_FINISH_CHANCE := 0.35

# --- Heroes / ultimates (scripts/war/heroes/; 2026-10-07 the user: "karakterler süper güç versin,
# düşman takıma göktaşı yağdırmak gibi, hepsi farklı") --------------------------------------------
## Pick a character at the loadout picker (hero_picker.gd): one ULTIMATE on E (hold to aim, release to
## fire for the targeted ones) and one small passive. The ultimate charges slowly ("tok"): full after
## HERO_CHARGE_TIME s × the hero's HERO_*_CHARGE_K on its own, faster from kills, assists (an enemy dies
## near you), zone captures (control_points.gd: a zone turns to your side while you stand in it) and
## the drill biting. Kept through death; HERO_SWAP_KEEP of it survives a change of character.
const HERO_ENABLED := true
const HERO_CHARGE_TIME := 150.0        # s from empty to full on time alone (× the hero's _CHARGE_K)
const HERO_CHARGE_KILL := 0.10         # + per kill (your hit marker said "kill")
const HERO_CHARGE_ASSIST := 0.04       # + an enemy died within HERO_ASSIST_R m of you (not your kill)
const HERO_ASSIST_R := 25.0
const HERO_CHARGE_CAPTURE := 0.08      # + a zone turned to your side while you stood in it
const HERO_CHARGE_DIG := 0.004         # + per s of the drill biting soil (≈ +24 % a minute of digging)
const HERO_SWAP_KEEP := 0.5            # share of the charge kept when the character changes
const HERO_TRAINING_K := 8.0           # × the charge rate in the Eğitim Alanı
const HERO_FRIENDLY_K := 0.0           # × an ultimate's damage on its own side (0: none)
const HERO_BOT_CHARGE_K := 0.8         # × the bots' time charge (they also get assists and captures)
const HERO_BOT_THINK := 1.0            # s between a charged bot's "use it now?" checks (hero_ai.gd)
const HERO_BOT_FIRST := 90.0           # s into the match before any bot may use an ultimate
## Topçu: Göktaşı Yağmuru. Aim (E held) at ground up to HERO_METEOR_RANGE m (the other planet up to
## HERO_METEOR_RANGE_FAR m, wider), release: a red ring and a beam mark the spot for HERO_METEOR_WARN s,
## then HERO_METEOR_COUNT meteors HERO_METEOR_GAP s apart within HERO_METEOR_SPREAD m (meteor_shower.gd
## strike(): the usual streaks, blasts, craters, cave-in stress; no meteor cores). Passive: a cannon
## you sit at reloads × HERO_TOPCU_RELOAD_K.
const HERO_METEOR_CHARGE_K := 1.15
const HERO_METEOR_RANGE := 120.0
const HERO_METEOR_RANGE_FAR := 320.0
const HERO_METEOR_COUNT := Vector2i(4, 6)
const HERO_METEOR_SPREAD := 12.0
const HERO_METEOR_SPREAD_FAR := 16.0
const HERO_METEOR_WARN := 3.0
const HERO_METEOR_GAP := 0.75          # s between launches (6 meteors ≈ 4 s)
const HERO_METEOR_FLIGHT := 1.6        # s from HERO_METEOR_START_DIST m out to the impact
const HERO_METEOR_START_DIST := 140.0
const HERO_METEOR_BLAST_R := 6.0
const HERO_METEOR_DAMAGE := 80.0       # at the centre of each blast (falls off), enemies only
const HERO_METEOR_IMPULSE := 12.0
const HERO_METEOR_CRATER_R := 2.6      # planet.crater (× CRATER_SCALE as usual)
const HERO_METEOR_CRATER_DEPTH := 2.6
const HERO_TOPCU_RELOAD_K := 1.35
## Gözcü: Uydu Taraması. HERO_SCAN_TIME s: every enemy on the planet you stand on shows on the radar
## (minimap.gd red dots, refreshed every HERO_SCAN_TICK s) and as red diamonds through walls within
## HERO_SCAN_MARK_RANGE m (hero_hud.gd); the enemy hears and sees the sweep. Passive: the Tünel
## tarayıcı (Q) recharges × HERO_GOZCU_SCANNER_K.
const HERO_SCAN_CHARGE_K := 0.8
const HERO_SCAN_TIME := 7.0
const HERO_SCAN_TICK := 0.4
const HERO_SCAN_MARK_RANGE := 160.0
const HERO_GOZCU_SCANNER_K := 1.5
## Muhafız: Kalkan Kubbesi. A HERO_DOME_R m dome at your feet for HERO_DOME_TIME s: bullets, grenades
## and the bots' rifle rounds from OUTSIDE stop on it (shots from inside pass), HERO_DOME_HP hp; not
## within HERO_DOME_CORE_CLEAR m of a core (no stacking with the Çekirdek Kalkanı). Passive: your
## Hızlı siper is ready × HERO_MUHAFIZ_ENTRENCH_K sooner; revives (downed.gd) × HERO_MUHAFIZ_REVIVE_K.
const HERO_DOME_CHARGE_K := 1.0
const HERO_DOME_R := 6.0
const HERO_DOME_TIME := 10.0
const HERO_DOME_HP := 700.0
const HERO_DOME_CORE_CLEAR := 16.0
const HERO_MUHAFIZ_ENTRENCH_K := 2.0
const HERO_MUHAFIZ_REVIVE_K := 1.5
## Kazıcı: Sismik Dalga. A ground slam: a wave runs out HERO_QUAKE_R m at HERO_QUAKE_SPEED m/s;
## enemies it passes take HERO_QUAKE_DMG and a jolt (HERO_QUAKE_IMPULSE m/s, mostly up); the enemy's
## tunnels and dugouts (tunnel_log.gd) under it with at most HERO_QUAKE_ROOF m of soil over them come
## down (cave_in.gd quake: the usual collapse, burial and sinkhole; up to HERO_QUAKE_MAX of them).
## Passive: your drill digs × HERO_KAZICI_DIG_K (soil; the material is still capped per s).
const HERO_QUAKE_CHARGE_K := 1.0
const HERO_QUAKE_R := 20.0
const HERO_QUAKE_SPEED := 30.0
const HERO_QUAKE_DMG := 15.0
const HERO_QUAKE_IMPULSE := 7.0
const HERO_QUAKE_ROOF := 3.6            # m of roof at most (a tunnel dug 4-5 m down; deeper ones hold)
const HERO_QUAKE_SPAN := 1.6           # m: ...and at least this wide (a drilled tunnel; plain cave-ins need CAVE_SPAN_MIN)
const HERO_QUAKE_MAX := 6
const HERO_KAZICI_DIG_K := 1.3
## Avcı: Faz Pelerini. HERO_CLOAK_TIME s nearly invisible (a refraction shimmer; HERO_CLOAK_ALPHA of the
## body faded), × HERO_CLOAK_SPEED moving; bots do not see you beyond HERO_CLOAK_SEE_R m. Firing ends it.
## Passive: the bots hear your shots × HERO_AVCI_NOISE_K as far (cache_buffs.gd noise_mult).
const HERO_CLOAK_CHARGE_K := 0.9
const HERO_CLOAK_TIME := 7.0
const HERO_CLOAK_SPEED := 1.3
const HERO_CLOAK_SEE_R := 5.0
const HERO_CLOAK_ALPHA := 0.88
const HERO_AVCI_NOISE_K := 0.7
## Mühendis: Yerçekimi Kuyusu. Aim (E held) up to HERO_WELL_RANGE m, release: a singularity lobs there
## (HERO_WELL_FLIGHT s), pulls enemies and loose debris within HERO_WELL_R m toward a point just over it
## for HERO_WELL_TIME s (HERO_WELL_PULL m/s² at the edge, × 2 at the centre: in this low gravity it
## lifts you), then pops: HERO_WELL_POP_DMG within HERO_WELL_POP_R m. Passive: one more grenade on
## every spawn (up to the pouch).
const HERO_WELL_CHARGE_K := 1.0
const HERO_WELL_RANGE := 40.0
const HERO_WELL_FLIGHT := 0.9
const HERO_WELL_TIME := 3.5
const HERO_WELL_R := 11.0
const HERO_WELL_PULL := 9.0
const HERO_WELL_POP_R := 5.5
const HERO_WELL_POP_DMG := 75.0
const HERO_WELL_POP_IMPULSE := 10.0
