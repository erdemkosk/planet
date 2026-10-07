extends RefCounted
## HeroAI: which character a bot plays and when it fires its ultimate (heroes.gd _bot_tick, host /
## single player, once a second while charged). Duck-typed on the bot (ai_rival.gd: team, index, role,
## hp, hp_max, body, global_position) plus the think context its one-line hook passes (PATCHES.md):
##   ctx "target" (Node or null), "visible" (bool), "threat" (Vector3, INF = none), "combat" (bool),
##       "under_fire" (bool), "eye" (Vector3)
##   HeroAI.pick_hero(bot) -> String               by role and index (stable for the bot's life)
##   HeroAI.decide(heroes, bot, hero, ctx) -> Dictionary   {} = not now; else the ult's data
## The rules want a payoff, so the player sees them used well, not wasted:
##   Topçu     a visible target 18..HERO_METEOR_RANGE m away with a second enemy near it, a player
##             (on foot, out in the open) or a structure: meteors on it (a few m of aim error)
##   Gözcü     in a fight that lost sight of its target, or 3+ enemies within 60 m
##   Muhafız   under fire and hurt (< 60 %) or with a teammate at its side
##   Kazıcı    4+ enemy tunnel points within the wave, or an enemy within 14 m in a fight
##   Avcı      in a fight and hurt (< 45 %: slip away), or its target 15..45 m away (close in unseen)
##   Mühendis  a visible target 10..HERO_WELL_RANGE m away with another enemy near it, or a player

const Balance := preload("res://scripts/war/balance.gd")
const TunnelLog := preload("res://scripts/war/tunnel_log.gd")

const ROLE_HEROES := [["kazici", "gozcu", "kazici"], ["topcu", "muhendis"], ["avci", "muhafiz", "topcu", "gozcu"]]


static func pick_hero(bot: Object) -> String:
	var role := int(bot.get("role")) if bot.get("role") != null else -1
	var idx := int(bot.get("index")) if bot.get("index") != null else 0
	if role >= 0 and role < ROLE_HEROES.size():
		var opts: Array = ROLE_HEROES[role]
		return str(opts[posmod(idx, opts.size())])
	var all := ["topcu", "gozcu", "muhafiz", "kazici", "avci", "muhendis"]
	return str(all[posmod(idx, all.size())])


static func decide(heroes: Node, bot: Node3D, hero: String, ctx: Dictionary) -> Dictionary:
	var team := Game.team_of(bot)
	var foe := "rival" if team == "home" else "home"
	var me := bot.global_position
	var body: Node3D = bot.get("body") if bot.get("body") is Node3D else Game.dominant_body(me)
	if body == null or not is_instance_valid(body):
		return {}
	var eye: Vector3 = ctx.get("eye", me + (me - body.global_position).normalized() * 1.5)
	var tgt = ctx.get("target")
	if tgt != null and not is_instance_valid(tgt):
		tgt = null
	var vis := bool(ctx.get("visible", false))
	var combat := bool(ctx.get("combat", false))
	var under_fire := bool(ctx.get("under_fire", false))
	var threat: Vector3 = ctx.get("threat", Vector3.INF)
	var hp := float(bot.get("hp")) if bot.get("hp") != null else 100.0
	var hp_max := maxf(float(bot.get("hp_max")) if bot.get("hp_max") != null else 100.0, 1.0)
	match hero:
		"topcu":
			if tgt == null or not vis:
				return {}
			var p: Vector3 = (tgt as Node3D).global_position
			var d := eye.distance_to(p)
			if d < 18.0 or d > Balance.HERO_METEOR_RANGE or Game.dominant_body(p) != body:
				return {}
			var worth: bool = _count(heroes, foe, p, Balance.HERO_METEOR_SPREAD, body) >= 2 \
					or (tgt as Node).is_in_group("war_structure") \
					or ((tgt == Game.player or (tgt as Node).is_in_group("net_player")) and tgt.get("vehicle") == null)
			if not worth:
				return {}
			var g := _ground(body, p + Vector3(randf_range(-3, 3), randf_range(-3, 3), randf_range(-3, 3)))
			return {} if g == Vector3.INF else {"pos": g, "body": body}
		"gozcu":
			if (combat and not vis and threat != Vector3.INF) or _count(heroes, foe, me, 60.0, body) >= 3:
				return {"bot": true}
		"muhafiz":
			if combat and under_fire and (hp < hp_max * 0.6 or _count(heroes, team, me, Balance.HERO_DOME_R, body) >= 2):
				return {"bot": true}
		"kazici":
			var near := 0
			for e in TunnelLog.points(body, foe):
				if (e["p"] as Vector3).distance_to(me) < Balance.HERO_QUAKE_R:
					near += 1
					if near >= 4:
						return {"bot": true}
			if combat and _count(heroes, foe, me, 14.0, body) >= 1:
				return {"bot": true}
		"avci":
			if combat and hp < hp_max * 0.45:
				return {"bot": true}
			if combat and tgt != null and vis:
				var d := me.distance_to((tgt as Node3D).global_position)
				if d > 15.0 and d < 45.0:
					return {"bot": true}
		"muhendis":
			if tgt == null or not vis or not (tgt as Node).has_method("is_dead"):
				return {}
			var p: Vector3 = (tgt as Node3D).global_position
			var d := me.distance_to(p)
			if d < 10.0 or d > Balance.HERO_WELL_RANGE or Game.dominant_body(p) != body:
				return {}
			if _count(heroes, foe, p, 8.0, body) >= 2 or tgt == Game.player or (tgt as Node).is_in_group("net_player"):
				var g := _ground(body, p)
				return {} if g == Vector3.INF else {"pos": g, "body": body, "from": eye}
	return {}


## Living units of `team` within r of p on `body`.
static func _count(heroes: Node, team: String, p: Vector3, r: float, body: Node3D) -> int:
	var n := 0
	for u in heroes.units():
		if not is_instance_valid(u) or u.is_dead() or Game.team_of(u) != team:
			continue
		var q: Vector3 = (u as Node3D).global_position
		if q.distance_to(p) < r and Game.dominant_body(q) == body:
			n += 1
	return n


## The ground under / around p (density march along the local up), INF = none.
static func _ground(body: Node3D, p: Vector3) -> Vector3:
	var up := (p - body.global_position).normalized()
	var h: Dictionary = body.raycast_density(p + up * 8.0, p - up * 12.0, 0.5, true)
	return h["position"] if not h.is_empty() else Vector3.INF
