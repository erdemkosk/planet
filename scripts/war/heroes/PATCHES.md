# Heroes: patches for files owned by other sessions (phase 2)

The hero system (`scripts/war/heroes/`) runs without any of these patches. Each one below connects it to
a file another session owned when this was written. Line anchors are quoted as code, not line numbers,
because those files keep changing. Apply each patch as a small targeted Edit.

Every hook is a static call on `heroes.gd`. It is cheap and safe when the Heroes node is missing
(menus, other scenes). Wherever you need it, add:

```gdscript
const Heroes := preload("res://scripts/war/heroes/heroes.gd")
```

If a preload cycle error ever shows up, use `load("res://scripts/war/heroes/heroes.gd")` at the call
site instead.

---

## 1. loadout_panel.gd: the KARAKTER strip (the character picker)

`hero_picker.gd` is a self-drawn Control, `HeroPicker.SIZE = (756, 150)`. It sits under the loadout
cards in every mode: the armory tab, the ride and the match start.

```gdscript
# with the other consts
const HeroPicker := preload("res://scripts/war/heroes/hero_picker.gd")
const HERO_STRIP := 162.0                # the KARAKTER strip under the cards (HeroPicker.SIZE.y + 12)
# FRAMED_SIZE grows by the strip:
const FRAMED_SIZE := Vector2(860, 480 + 162)

var _hero: Control                       # the KARAKTER strip (scripts/war/heroes/hero_picker.gd)

# end of _ready():
	_hero = HeroPicker.new()
	add_child(_hero)
	_place_hero()

# end of setup(m) and of set_page_size(s):
	_place_hero()

# _cards(): the cards stop above the strip
	var bottom := (54.0 if _framed() else 30.0) + HERO_STRIP

# new helper
func _place_hero() -> void:
	if _hero == null:
		return
	var pad := 22.0 if _framed() else 0.0
	var bottom := 54.0 if _framed() else 30.0
	_hero.position = Vector2(pad, page_size.y - bottom - HeroPicker.SIZE.y)
	_hero.size = Vector2(page_size.x - pad * 2.0, HeroPicker.SIZE.y)
```

How the strip behaves:

- **Input:** a click picks a character, and ← / → cycle through them. These keys don't clash with the
  panel's own keys (1..9, Q/E, Enter).
- **When the pick applies:** a pick calls `Heroes.pick(id)`. It applies at once while you are dead,
  riding the respawn ship or still before your first spawn. Otherwise it waits for your next spawn,
  and the HUD shows "Sonraki doğuşta: X".
- **Footer:** optionally, add "← / →: karakter" to the footer hint.

## 2. ai_rival.gd: bots use ultimates, see through and get stopped by them (bots of both teams; ally bots are ai_rival.gd too)

### a) Think hook: register, charge and fire

In `func _think(dt)`, right after `_perceive(dt)`:

```gdscript
	_perceive(dt)
	Heroes.bot_tick(self, dt, {"target": _target, "visible": _target_visible, "threat": _threat_pos,
			"combat": mode == Mode.COMBAT, "under_fire": _now() - _threat_ms < 2000, "eye": _eye()})
```

What this hook does:

- **Where it runs:** the host and single player only (a no-op on a client).
- **Which character:** `hero_ai.gd pick_hero` chooses it by role and index.
- **Charge:** the bot gets the time charge × `HERO_BOT_CHARGE_K`, plus assists and zone captures.
- **When it fires:** charged bots ask `hero_ai.gd decide` once a second, never before
  `HERO_BOT_FIRST` s into the match.

### b) The cloak: no sight of a cloaked unit beyond HERO_CLOAK_SEE_R

In `_perceive`, the player branch:

```gdscript
				vis = _los_clear(me, chest) and not Heroes.hidden_from(pl, me)
```

In `_al_perceive`, the bot-vs-bot branch (`vis = _los_clear(me, chest)` after `chest = best.global_position + ...`):

```gdscript
			vis = _los_clear(me, chest) and not Heroes.hidden_from(best, me)
```

### c) Cloak speed: the move step

```gdscript
			want = flat / dist * minf(_move_speed * Heroes.speed_mult(self), dist / dt)
```

### d) Kalkan Kubbesi: the bots' rifle rounds stop on a dome from outside

In `_shoot_update`, replace

```gdscript
	var end := aimp
	if _target_visible and _rng.randf() < clampf(chance, 0.03, 0.9):
```

with

```gdscript
	var end := aimp
	var dome = Heroes.dome_blocks(me, aimp)      # Muhafız's dome (scripts/war/heroes/ult_dome.gd)
	if dome == null and _target_visible and _rng.randf() < clampf(chance, 0.03, 0.9):
```

and right after the hit / miss `if ... else ...` block (before `var tip: Node3D = astronaut.held_tip("rifle")`):

```gdscript
	if dome != null:
		end = dome.entry(me, end)
		Game.damage_target(dome, Balance.AI_RIFLE_DAMAGE, me, Vector3.ZERO, team, end)
```

The tracer then ends on the shell, which flashes and loses hp. A round fired from inside the dome
passes, because `dome_blocks` only matches shots coming from outside. `_wx_try_shoot` (the weapon
tasks) can get the same 3 lines if wanted.

## 3. player.gd: cloak speed (one line)

In `_move_gravity`, at the `var speed := lerpf(WALK, SPRINT, ...)` line, append to the product:

```gdscript
	var speed := lerpf(WALK, SPRINT, _sprint_k * _sprint_k * (3.0 - 2.0 * _sprint_k)) * move_speed_mult \
			* float(stance.speed_mult()) * _weight * float(get_meta("hero_speed_mult", 1.0))
```

`ult_cloak.gd` sets and removes the `hero_speed_mult` meta (HERO_CLOAK_SPEED). No preload is needed.

## 4. downed.gd / revive.gd (Muhafız passive)

Wherever a revive's progress grows, multiply by the reviver's factor:

```gdscript
	progress += delta / Balance.DN_REVIVE_TIME * Heroes.revive_mult(reviver)
```

The factor is HERO_MUHAFIZ_REVIVE_K for a Muhafız and 1 for everyone else. A bot medic counts too,
because `Heroes.hero_of(bot)` knows its character.

## 5. unit_markers.gd and minimap.gd (read-only for the heroes session)

### unit_markers.gd: no chevron on a cloaked enemy

A cloaked enemy should get no "spotted" chevron unless they are within HERO_CLOAK_SEE_R. Where an
enemy unit's chevron is decided:

```gdscript
		if Heroes.hidden_from(n, cam.global_position):
			continue
```

### minimap.gd: Uydu Taraması

The scan already shows on the radar, through public API only. While a friendly scan runs,
`ult_scan.gd` calls `ShotPings.add(pos, enemy_team, true)` for every enemy on the planet every
HERO_SCAN_TICK s, so the enemies show as the usual fading red ping dots.

A cleaner version, if the minimap owner wants it (then drop `_ping()` in `ult_scan.gd`): in
`_update()`, after the pings loop, draw the revealed units as steady red dots:

```gdscript
	var rv: Dictionary = Heroes.state().get("reveal", {})
	if not rv.is_empty() and Time.get_ticks_msec() < int(rv.get("until", 0)) and rv.get("body") == body:
		for n in Heroes.inst().units():
			if is_instance_valid(n) and not n.is_dead() and Game.team_of(n) == str(rv["team"]):
				var m := map_point((n as Node3D).global_position, c, up, right, fwd, radius)
				_pg.append(to_disc(m)); _pg_age.append(0.6); _pg_rim.append(1 if m.z > RANGE_M else 0)
```

The ShotPings path has one side effect: `ShotPings.events().pinged` also fires for these
fake "shots". Nothing listens to it today, but if a listener is added (bots hearing pings, say), it
should ignore pings that sit exactly on a unit during a scan, or the cleaner minimap hook above should
be used instead.

## 6. Multiplayer (net_*.gd): wiring `Heroes.events()`

Everything in `data` is in world space with planet nodes, the same convention as MeteorShower's events.
On the wire, send `"body"` as `Net.body_index(body)` and `"pos"` / `"from"` body-local (`pos - body.global_position`).
`"up"` is a unit vector, `"far"` a bool and `"n"` an int.

### Casters

- The host's `Game.player` becomes the host's avatar (`net_player`) on the client.
- The client's avatar on the host becomes `Game.player` on the client.
- Bots map through the existing bot ids (`net_world.id_of` / `Net.bots.node_of`).
- The team is `Net.abs_side(team)` on the wire and `Net.local_team(abs)` on receipt.

### Signals and their handlers

| signal (emitter)                                   | send to   | receiver calls                                                         |
|----------------------------------------------------|-----------|------------------------------------------------------------------------|
| `hero_picked(hero)` (any machine, local player)    | other     | `Heroes.net_hero(<his avatar>, hero)`                                  |
| `ult_claimed(hero, data)` (CLIENT, charge spent)   | host      | `Heroes.net_claim(<client avatar>, hero, data)` (validated, then runs) |
| `ult_started(fx_id, caster, team, hero, data)` (HOST) | client | `Heroes.net_started(fx_id, <caster'>, Net.local_team(abs), hero, data)` |
| `ult_ended(fx_id, why)` (host; a client for its own cloak) | other | `Heroes.net_ended(fx_id, why)`                                    |

### What the existing channels already sync

- **Meteors:** `meteor_shower.gd` events (`strike()` emits `shower_started` / `meteor_incoming`
  with the hero's flight time).
- **Craters and collapses:** terrain ops plus `cave_in.gd` events.
- **Damage:** host hp.
- **The gravity well's pull:** each machine pulls its own player, so nothing extra is needed.

### Open item: the dome's hp from a client's rounds

The client's copy of a dome stops the client's own rounds locally (its collision is built on every
machine), but `Net.world.claim_damage` has no id for a dome, so those hits don't reach the host's hp.
If wanted, give domes an id range (for example `ID_DOME + fx_id`). On the host,
`Heroes.inst().running()[fx_id].take_damage(amount, from, impulse)` applies it.

### Fingerprint

The new HERO_* constants in balance.gd change `Net.fingerprint()`. Both builds must match.

## 7. Optional: the Eğitim Alanı panel

The training panel could get a "ULTİ DOLDUR" button: `Heroes.inst().charge = 1.0`. In training the
charge already runs × HERO_TRAINING_K.

`Heroes.inst().debug_fire(caster, hero, data)` fires any ultimate for any caster on the host. Tests use
it.
