extends RefCounted
## Every war tunable in one place (cores, cannons, shells, building, the drill's material rate,
## the AI rival). Times in seconds, distances in metres, material in m³ (Game.material).
##
## Tuned for the planet layout in scripts/planet/bodies.gd (PLANET_RADIUS 60 m, PLANET_DISTANCE
## 350 m, surface gravity 0.8 g): escape speed from one planet ~31 m/s, the slowest shell that
## clears the midpoint between the planets ~21 m/s. Re-check the cannon speeds, the crater, the
## flak and the AI ranges / aim numbers below when those change.
##
## Balance target (estimates, not measured):
##   - The drill credits at most DRILL_MAX_RATE m³/s, about 8 m³/s with normal pauses.
##   - Both sides start with START_MATERIAL = one cannon; the first shells (SHELL_COST each) and
##     every further cannon (CANNON_COST, ~1.2 min of digging) have to be dug for.
##   - A shuttle (suggested SHUTTLE_COST_HINT) takes ~6 min.
##   - A shell (SHELL_COST) takes ~5 s of digging and flies ~8-18 s. A core lies ~58 m down; a
##     shell hurts it from ~16 m off its surface (CORE_BLAST_K × SHELL_CRATER_R). ~6 hits in the
##     same hole (~7 m each) open the way, ~4 more finish it: ~10 hits, ~15-18 shells with misses.
##   - The rival team (BOT_COUNT bots) earns up to TEAM_INCOME_CAP (~2.5 players) and fires at most
##     one shell per AI_TEAM_FIRE_GAP s (~4 / min): its first cannon at once, the base complete
##     (5 cannons, 4 Uçaksavar) in ~3-4 min, our core gone ~5-7 min after its aim settles unless
##     we shoot its shells down / hit its cannons. Our side alone needs ~10-16 min: a match is
##     ~8-12 min, the player has to defend.

# --- Material from digging ------------------------------------------------------------------------
## Upper limit on how fast the drill turns dug soil into material (m³/s). A larger brush digs a
## bigger hole but not faster than this. The AI rival uses the same limit.
const DRILL_MAX_RATE := 12.0

# --- Cores ----------------------------------------------------------------------------------------
const CORE_RADIUS := 5.0
const CORE_HP := 100.0
## Shell damage to a core at 0 m from its surface; falls to 0 at CORE_BLAST_K × crater radius.
const CORE_SHELL_DAMAGE := 34.0
const CORE_BLAST_K := 3.0
## Enemy drill brush overlapping a core: damage per second.
const CORE_DRILL_DPS := 6.0
const CORE_LIGHT_RANGE := 26.0         # the core's light reaches tunnel walls this far from the centre

# --- Building -------------------------------------------------------------------------------------
const BUILD_RANGE := 22.0              # m from the eye to the placement point
const BUILD_MAX_SLOPE_DEG := 22.0      # ground normal vs. up
const BUILD_MAX_STEP := 1.6            # m of height difference across the footprint
const CANNON_COST := 600.0
## Material both sides start a match with: exactly one cannon (shells still have to be dug for).
## Kept on respawn; Game.reset_state() and the AI rival read it.
const START_MATERIAL := CANNON_COST
const SHUTTLE_COST_HINT := 3000.0      # suggestion for scripts/craft/skiff.gd BUILD_COST

# --- Cannon ---------------------------------------------------------------------------------------
const CANNON_HP := 300.0
const CANNON_FOOTPRINT := 3.2          # radius (m) kept clear around a cannon
const CANNON_RELOAD := 6.0
## Muzzle speed range (m/s). From a spawn-side cannon to the other planet: 25 -> ~15-18 s
## flights (high lobs), 30 -> ~10-11 s, 38 -> ~7-8 s (flat and fast). Escape speed is ~31 m/s,
## so the upper part of the range can also send a shell into space.
const CANNON_SPEED_MIN := 25.0
const CANNON_SPEED_MAX := 38.0
const CANNON_PITCH_MIN := 5.0          # degrees above the local horizon
const CANNON_PITCH_MAX := 85.0
const SHELL_COST := 40.0

# --- Shell ----------------------------------------------------------------------------------------
const SHELL_LIFE := 45.0               # s before a shell that hit nothing is removed
const SHELL_CRATER_R := 5.5            # crater radius (planet.gd caps it at 12)
const SHELL_CRATER_DEPTH := 6.5        # density change at the crater centre (≈ metres)
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
const FLAK_ROUND_COST := 2.0           # m³ per round for the player (the AI's rounds are free)
const FLAK_FUSE_R := 7.0               # proximity fuse: bursts at the closest pass within this
const FLAK_BLAST_R := 8.0              # burst damage radius (linear falloff, Game.area_damage)
const FLAK_DAMAGE := 60.0              # at the centre: ~37 at 3 m -> the skiff (180 hp) takes 4-6
const FLAK_IMPULSE := 4.0
const FLAK_SHELL_KILL_R := 6.0         # point defence: a burst this close destroys a cannon shell
# Automatic fire control (an unmanned Uçaksavar against enemy skiffs).
const FLAK_RANGE := 300.0              # covers a take-off from the other base (~270 m away)
const FLAK_MIN_ALT := 4.0              # m above the ground: the skiff counts as airborne
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
const BOT_COUNT := 70                  # rival bots (spawned a few at a time over BOT_SPAWN_TIME s)
const BOT_SPAWN_TIME := 5.0
const AI_SPAWN_RADIUS := 40.0          # m: (re)spawn points spiral around the base out to this
## Roles by share of the living bots (at least 1 engineer; the rest are guards / raiders).
const ROLE_MINER_SHARE := 0.5          # Kazıcı
const ROLE_ENGINEER_SHARE := 0.1       # Mühendis (AI_MAX_BUILDERS build at a time, the rest fire,
                                       # repair or haul / dig)
const AI_MAX_BUILDERS := 2
# --- Team economy (so 35 miners don't flood the planet with cannons) ---
## The pool earns min(TEAM_INCOME_CAP, digging bots × DRILL_MAX_RATE × AI_GATHER_MULT) m³/s: about
## 2-3 busy players. The terrain itself is dug by at most AI_MAX_BRUSHES bots at a time (rotating),
## the others dig with the animation and FX only.
const TEAM_INCOME_CAP := 20.0
const AI_MAX_BRUSHES := 4
const AI_BRUSH_SLOT := 6.0             # s a bot keeps a real brush before it rotates on
## Team-wide pace of cannon fire: at least this many s between two rival shells (twice that while
## it still saves for structures). ~4 shells / min at most.
const AI_TEAM_FIRE_GAP := 15.0
# --- Performance budget for many bots ---
const AI_LOD_NEAR := 40.0              # m from the camera: full rate (think ~8 Hz, move 15 Hz, IK every frame)
const AI_LOD_MID := 100.0              # beyond: far (think ~1.3 Hz, move 4 Hz, pose 3 Hz, no cover search)
const AI_LIGHT_MAX := 6                # bots with real lights (helmet lamp, muzzle flash): the nearest
const AI_FX_MAX := 6                   # dig beam / particle FX: the nearest diggers; others dust puffs
const AI_VOICE_MAX := 8                # bots that may play sounds: the nearest
const AI_MAX_SHOOTERS := 5             # bots allowed to fire at the player at once (the rest reposition)
const AI_LOS_PER_FRAME := 3            # density line-of-sight marches per physics frame, team-wide
const AI_COVER_EVALS_PER_FRAME := 4    # cover candidates tested per physics frame, team-wide
const AI_RAGDOLL_MAX := 6              # live ragdolls; older (and settled) corpses freeze in place
const AI_HELP_MAX := 6                 # allies answering one call for help
const AI_HP := 100.0
const AI_RESPAWN := 15.0
const AI_WALK_SPEED := 3.2
const AI_RUN_SPEED := 6.0              # sprinting between cover, fleeing
const AI_STRAFE_SPEED := 3.8
const AI_THINK := 0.25                 # work decisions
const AI_COMBAT_THINK := 0.15          # combat decisions (~7 Hz per bot, staggered)
const AI_DIG_HZ := 5.0                 # real brushes per second for a bot holding a brush slot
const AI_DIG_RADIUS := 3.0
const AI_DIG_RATE := 7.0               # same density rate as the player's drill
## Per digging bot, × DRILL_MAX_RATE (the team total is capped at TEAM_INCOME_CAP).
const AI_GATHER_MULT := 0.45
# Where the bots work on the (small) planet, m from the base.
const AI_MINE_MIN := 8.0               # miners' pits (each bot its own spot on a spiral)...
const AI_MINE_MAX := 45.0
const AI_PIT_DEPTH := 5.0              # ...a pit this deep: move on
const AI_GUARD_RADIUS := 32.0          # guards patrol this far around the base (6-14 m around structures)
const AI_BUILD_AHEAD := 14.0           # structures up to this far toward our planet...
const AI_BUILD_SIDE := 14.0            # ...and this far to either side
# Combat (on foot). The horizon is close on a 60 m planet (~14 m from eye height on flat ground).
const AI_SIGHT_RANGE := 70.0           # sees the player on foot on its planet this far (line of sight)
const AI_PREFERRED_RANGE := 18.0       # likes to fight from about this far
const AI_NEAR_MISS := 2.0              # a shot passing this close counts as being shot at
const AI_HELP_RANGE := 50.0            # calls allies within this when attacked
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
const AI_DODGE_CHANCE := 0.3           # jet hop when a shot passes close
const AI_JET_HOP := 6.0                # m/s up for a hop over an obstacle or a dodge
const AI_CLIMB_SPEED := 3.5            # m/s jet climb out of a deep pit / shaft
const AI_RIFLE_STRUCT_DAMAGE := 8.0    # raiders shooting our cannons / Uçaksavar
const AI_REPAIR_RATE := 12.0           # hp/s the engineer repairs a damaged structure...
const AI_REPAIR_COST := 0.5            # ...for this many m³ per hp
# Raids (raiders fly the team's skiff to our planet). DEFERRED: off until the skiff gets its AI
# pilot API (scripts/craft/skiff.gd: ai_board, ai_exit, ai_fly_to, ai_arrived). While off, the
# raider role is a base guard ("Muhafız") and the team never builds or touches a skiff.
const RAIDS_ENABLED := false
const RAID_FIRST_AFTER := 240.0        # s into the match before the first raid
const RAID_MIN_INTERVAL := 210.0       # s between raids
const RAID_MAX_TIME := 240.0           # s on our planet before they fly home anyway
const RAID_RETREAT_HP := 0.4           # a raider below this share of hp calls the retreat
const RAID_LAND_MIN := 30.0            # landing site: this far from our base...
const RAID_LAND_MAX := 50.0            # ...at most, preferably hidden behind terrain
const RAID_CALM_TIME := 8.0            # s unopposed before the digger starts the shaft
const RAID_DIG_RATE := 0.7             # m/s the shaft deepens (~85 s down to the core)
const RAID_DIG_RADIUS := 2.0
const RAID_STRUCT_RANGE := 70.0        # raiders look for our structures this far from the landing
const AI_MAX_CANNONS := 5
const AI_MAX_FLAKS := 4                # Uçaksavar: built alternately with the cannons
const AI_RESERVE := 80.0               # material the AI keeps before spending on shells
## Aim error. At these ranges 1° of barrel error moves the impact ~4 m: the first shot lands
## ~30 m off, the best ones ~4 m (under a crater radius).
const AI_AIM_ERROR_START := 7.5        # degrees of random aim error on the first shot...
const AI_AIM_ERROR_MIN := 1.0          # ...shrinking toward this...
const AI_AIM_ERROR_DECAY := 0.72       # ...by this factor after every impact it observes
const AI_SPEED_ERROR := 0.05           # relative muzzle-speed error, scaled like the aim error
## The AI's firing solution: muzzle speeds tried (fractions of CANNON_SPEED_MIN..MAX, the faster
## half: ~7-11 s flights), the worst landing it still accepts, and its adjust-fire limits.
const AI_SOLVE_SPEEDS := [0.35, 0.55, 0.75, 0.95]
const AI_SOLVE_MAX_MISS := 33.0        # m: no trajectory lands this close -> try another cannon
const AI_CORRECTION_MAX := 50.0        # m: adjust-fire offset limit
const AI_OBSERVE_RANGE := 80.0         # m: impacts farther than this from the aim point are ignored
const AI_TARGET_CANNON_CHANCE := 0.35  # chance to shell one of our cannons instead of the core region
const AI_FIGHT_RANGE := 60.0           # rifle range on foot (hit chance halves out here)
const AI_RIFLE_INTERVAL := 0.32        # s between rifle shots (bursts of AI_RIFLE_BURST)
const AI_RIFLE_BURST := 3
const AI_RIFLE_PAUSE := 1.1
const AI_RIFLE_DAMAGE := 12.0
const AI_RIFLE_HIT := 0.45             # hit chance at point blank, falls to half at AI_FIGHT_RANGE
## The bot's rifle against the player's skiff (with the player aboard) when it sees it close.
const AI_SKIFF_RIFLE_RANGE := 70.0
const AI_SKIFF_RIFLE_DAMAGE := 4.0     # low: the skiff has 180 hp
const AI_SKIFF_REACT := 1.5            # s of sight before it starts shooting
