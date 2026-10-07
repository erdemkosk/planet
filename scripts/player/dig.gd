extends RefCounted
## Shared "dig at a point" core of the terrain tool (scripts/player/terrain_tool.gd), usable by the
## player and the AI rival alike. No input, camera, inventory or HUD here.
##
##   var soil := Dig.dig_at(body, point, radius, mode, amount, plane_point, plane_up)
##   -> soil volume in m³ (+ dug out, - placed); the caller credits / charges its own pool
##      (the player: Game.add_material; the AI: its own counter).
##
## Modes are planet.gd Brush values: 0 DIG, 1 RAISE, 2 FLATTEN. RAISE and FLATTEN place soil and
## must be paid for: pass `budget` (the material the caller can spend, m³) and the brush is scaled
## down so it never places more than that (budget < 0 = unlimited).
## team ("home" / "rival", "" = not logged): a dig is recorded in scripts/war/tunnel_log.gd, where
## the other side's Tünel tarayıcı finds it.
## Visuals for an AI digger: give it its own scripts/items/dig_fx.gd (tip_is_vm = false) and call
## fx.work(tip, tip_dir, point, normal, up, mode, radius, color, body.soil_color) each dig tick.

const TunnelLog := preload("res://scripts/war/tunnel_log.gd")

const MODE_DIG := 0
const MODE_RAISE := 1
const MODE_FLATTEN := 2

## Multiplayer (scripts/net/net_terrain.gd): the team of the dig being applied right now, so the
## other side can log it for its Tünel tarayıcı too.
static var net_team := ""
## Optional strength hook (scripts/war/cache_buffs.gd "Kazı hızı +50 %"): called as
## hook(point, mode, amount, plane_point, team) -> float before every brush; returns the amount to use.
static var amount_hook: Callable = Callable()


## Applies one brush tick to `body` (a planet.gd node) at world `point`. Returns the soil moved.
static func dig_at(body: Node3D, point: Vector3, radius: float, mode: int, amount: float,
		plane_point := Vector3.ZERO, plane_up := Vector3.UP, budget := -1.0, team := "") -> float:
	if body == null or not is_instance_valid(body) or amount <= 0.0:
		return 0.0
	if amount_hook.is_valid():
		amount = float(amount_hook.call(point, mode, amount, plane_point, team))
	if mode != MODE_DIG and budget >= 0.0:
		if budget <= 0.01:
			return 0.0
		# A full-strength placing brush moves about volume * amount / 4 m³ at most (EDIT_CLAMP 4):
		# scale the strength down when the budget is short.
		var vol := 4.0 / 3.0 * PI * radius * radius * radius
		var est := vol * minf(amount, 4.0) * 0.25
		if est > budget:
			amount *= clampf(budget / est, 0.05, 1.0)
	net_team = team
	var moved := float(body.apply_brush(point, radius, mode, amount, plane_point, plane_up))
	net_team = ""
	if mode == MODE_DIG and team != "" and moved > 0.0:
		TunnelLog.record(body, point, radius, team)
	return moved
