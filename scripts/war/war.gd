extends Node
## The match (child of main.gd, group "war_controller"): puts a core in each planet, spawns the
## rival team on its planet (scripts/war/rival_team.gd: several bots with roles), shows the war HUD
## (core bars, warnings, end screen) and decides the match when a core is destroyed:
##   rival core destroyed -> "ZAFER", our core destroyed -> "YENİLGİ" (Yeniden başla / Çık).
##   War.instance(tree)  -> this node (or null)
##   war.core_of(body)   -> that planet's core

const Core := preload("res://scripts/war/core.gd")
const WarHud := preload("res://scripts/war/war_hud.gd")
const RivalTeam := preload("res://scripts/war/rival_team.gd")
const GROUP := "war_controller"

var home_core: Node3D
var rival_core: Node3D
var team: Node                         # the rival team
var hud: CanvasLayer
var over := false


static func instance(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null


func _ready() -> void:
	add_to_group(GROUP)
	name = "War"
	home_core = Core.spawn(Game.planet, "home")
	rival_core = Core.spawn(Game.rival, "rival")
	hud = WarHud.new()
	hud.war = self
	add_child(hud)
	team = RivalTeam.new()
	get_parent().add_child.call_deferred(team)
	Game.core_destroyed.connect(_on_core_destroyed)


func core_of(body: Node3D) -> Node3D:
	if body == Game.planet:
		return home_core
	if body == Game.rival:
		return rival_core
	return null


func _on_core_destroyed(body: Node3D) -> void:
	if over:
		return
	over = true
	var won: bool = body == Game.rival
	# A moment to see it go (the core's light dies), then the end screen.
	await get_tree().create_timer(2.0).timeout
	if is_inside_tree():
		hud.show_end(won)
