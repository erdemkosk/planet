extends Node
## Hides the gameplay overlays while Game.overlays_hidden() (the match is over, the pause menu or a
## modal panel is open, the tree is paused): every CanvasItem / CanvasLayer in group GROUP (the
## crosshair, the gun read-outs and their crosshairs, hit markers and the damage vignette
## (combat_hud.gd), scopes, the build card bar, the cannon / flak / skiff seat overlays). Created by
## Game (game.gd _ready); runs while paused and after every other node (process_priority), so a
## script that sets its own overlay's `visible` each frame is overridden for that frame. When the
## block ends each node gets back the visibility it had (its own script takes over again).
##   node.add_to_group(OverlayGuard.GROUP)   (= "gameplay_overlay")

const GROUP := "gameplay_overlay"
const META := "_og_vis"                  # visibility saved when the guard hid the node

var _was := false


func _init() -> void:
	name = "OverlayGuard"
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000


func _process(_delta: float) -> void:
	var hide := Game.overlays_hidden()
	if not hide and not _was:
		return
	_was = hide
	for n in get_tree().get_nodes_in_group(GROUP):
		if not (n is CanvasItem or n is CanvasLayer):
			continue
		if hide:
			if not n.has_meta(META):
				n.set_meta(META, bool(n.get("visible")))
			if bool(n.get("visible")):
				n.set("visible", false)
		elif n.has_meta(META):
			n.set("visible", bool(n.get_meta(META)))
			n.remove_meta(META)
