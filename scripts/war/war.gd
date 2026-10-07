extends Node
## The match (child of main.gd, group "war_controller"): puts a core in each planet, spawns the
## rival team on its planet (scripts/war/rival_team.gd: several bots with roles) and, in single
## player, our friendly bots on ours (scripts/war/ally_team.gd), shows the war HUD
## (core bars, warnings, end screen) and decides the match when a core is destroyed:
##   rival core destroyed -> "ZAFER", our core destroyed -> "YENİLGİ" (Yeniden başla / Çık).
##   War.instance(tree)  -> this node (or null)
##   war.core_of(body)   -> that planet's core

const Core := preload("res://scripts/war/core.gd")
const WarHud := preload("res://scripts/war/war_hud.gd")
const RivalTeam := preload("res://scripts/war/rival_team.gd")
const CraterAftermath := preload("res://scripts/war/crater_aftermath.gd")
const AllyTeam := preload("res://scripts/war/ally_team.gd")
const Balance := preload("res://scripts/war/balance.gd")
const GROUP := "war_controller"

var home_core: Node3D
var rival_core: Node3D
var team: Node                         # the rival team
var allies: Node                       # single player: our friendly bots (ally_team.gd), else null
var hud: CanvasLayer
var over := false


static func instance(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null


func _ready() -> void:
	add_to_group(GROUP)
	name = "War"
	Game.match_over = false               # a new match (reset_state() clears it too)
	home_core = Core.spawn(Game.planet, "home")
	rival_core = Core.spawn(Game.rival, "rival")
	hud = WarHud.new()
	hud.war = self
	add_child(hud)
	# Big craters: flying chunks + dust, and the floating-island check (host / single player).
	for p in [Game.planet, Game.rival]:
		var am: Node = CraterAftermath.new()
		am.planet = p
		am.name = "CraterAftermath_%s" % str(p.get("preset_name"))
		add_child(am)
	add_child(load("res://scripts/planet/vein_fx.gd").new())        # rich veins: glow, crystals, the drill's jackpot feel
	add_child(load("res://scripts/war/meteor_shower.gd").new())     # Göktaşı yağmuru (host decides; clients replay)
	add_child(load("res://scripts/war/heroes/heroes.gd").new())     # Kahramanlar: characters + ultimates (E)
	if Balance.CP_ENABLED and not Game.has_meta("training"):
		add_child(load("res://scripts/war/control_points.gd").new())    # Bölge kontrolü: zone + core income (not in training)
	if Net.ai_enabled() and not Game.has_meta("training"):    # Eğitim Alanı: no rival team (its panel can start it)
		start_ai()
	if not Net.active and not Game.has_meta("training") and Balance.ALLY_COUNT > 0:
		allies = AllyTeam.new()            # single player: friendly bots on our planet (ally_team.gd)
		get_parent().add_child.call_deferred(allies)
	Game.core_destroyed.connect(_on_core_destroyed)


## The AI rival team. Not on a multiplayer client (it sees the host's bots as puppets) and not in
## PvP; scripts/net/net.gd calls it when a PvP rival leaves and the host plays on against the AI.
func start_ai() -> void:
	if team != null and is_instance_valid(team):
		return
	team = RivalTeam.new()
	get_parent().add_child.call_deferred(team)


func core_of(body: Node3D) -> Node3D:
	if body == Game.planet:
		return home_core
	if body == Game.rival:
		return rival_core
	return null


func _on_core_destroyed(body: Node3D) -> void:
	if over or Game.has_meta("training"):     # Eğitim Alanı: no end screen
		return
	over = true
	var won: bool = body == Game.rival
	# A moment to see it go (the core's light dies), then the end screen.
	await get_tree().create_timer(2.0).timeout
	if is_inside_tree():
		hud.show_end(won)
