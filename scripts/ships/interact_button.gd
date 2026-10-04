extends Area3D
## Generic interactable (on the INTERACT layer). `action` is called on F, `prompt_fn` returns the prompt.

var action: Callable
var prompt_fn: Callable


func setup(size: Vector3, act: Callable, prompt: Callable) -> void:
	action = act
	prompt_fn = prompt
	collision_layer = Game.LAYER_INTERACT
	collision_mask = 0
	monitoring = false
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	add_child(cs)


func interact(_player) -> void:
	if action.is_valid():
		action.call()


func get_interact_prompt() -> String:
	return prompt_fn.call() if prompt_fn.is_valid() else ""
