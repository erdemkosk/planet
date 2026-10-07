extends Node3D
## Base of one running ultimate (scripts/war/heroes/ult_*.gd), a child of the Heroes node
## (heroes.gd) on EVERY machine: the host / single player runs the world effects (damage, craters,
## cave-ins: authority()), every machine draws it (a client from Heroes.net_started). top_level, in
## world space.
## Contract: setup(heroes, fx_id, caster, team, hero, data) before add_child; then _begin() (the
## subclass), _tick(delta) each frame; finish(why) ends it (owns(): announced through the hub as
## ult_ended so the other machine drops its copy). data: world positions + planet nodes (see heroes.gd).

const Balance := preload("res://scripts/war/balance.gd")
const HeroData := preload("res://scripts/war/heroes/hero_data.gd")
const HeroFx := preload("res://scripts/war/heroes/hero_fx.gd")
const HudLevel := preload("res://scripts/ui/hud_level.gd")

const FRIEND_COL := Color(0.45, 0.88, 1.0)
const ENEMY_COL := Color(1.0, 0.3, 0.2)

var heroes                       # heroes.gd
var fx_id := 0
var caster: Node3D               # the unit that fired it (the player, a bot, a remote avatar; may be freed)
var team := ""                   # the caster's side (local team string)
var hero := ""
var data := {}
var t := 0.0
var life := 10.0                 # s until it ends on its own
var ended := false


func setup(h, id: int, c: Node3D, tm: String, hr: String, d: Dictionary) -> void:
	heroes = h
	fx_id = id
	caster = c
	team = tm
	hero = hr
	data = d
	name = "Ult_%s_%d" % [hr, id]


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_begin()


func _process(delta: float) -> void:
	if ended:
		return
	t += delta
	_tick(delta)
	if not ended and t >= life:
		finish("expired")


## (subclass) start: build the look, alerts, the host's effects.
func _begin() -> void:
	pass


## (subclass) every frame.
func _tick(_delta: float) -> void:
	pass


## (subclass) the end's look; return true to free later yourself (a fade), false = freed now.
func _end(_why: String) -> bool:
	return false


## Host / single player: the world effects run here.
func authority() -> bool:
	return not Net.is_client()


## This machine announces the end (ult_ended): the host; the caster's own machine for his cloak.
func owns() -> bool:
	return authority()


## The local player is on the caster's side.
func is_friend() -> bool:
	return heroes != null and team == heroes.my_team()


func caster_is_me() -> bool:
	return caster != null and is_instance_valid(caster) and caster == Game.player


func caster_ok() -> bool:
	return caster != null and is_instance_valid(caster) and caster.is_inside_tree()


func side_col() -> Color:
	return FRIEND_COL if is_friend() else ENEMY_COL


## The local player's distance to p on the same planet (INF: elsewhere / dead).
func my_dist(p: Vector3) -> float:
	var pl = Game.player
	if pl == null or not is_instance_valid(pl) or (pl.has_method("is_dead") and pl.is_dead()):
		return INF
	var b := Game.dominant_body(p)
	if b != null and Game.dominant_body((pl as Node3D).global_position) != b:
		return INF
	return (pl as Node3D).global_position.distance_to(p)


func up_at(p: Vector3) -> Vector3:
	var b := Game.dominant_body(p)
	var c: Vector3 = b.global_position if b != null else Game.planet_center()
	var u := p - c
	return u.normalized() if u.length_squared() > 1e-6 else Vector3.UP


## The other machine ended it (Heroes.net_ended): no announcement.
func stop_remote(why := "net") -> void:
	if ended:
		return
	ended = true
	if not _end(why):
		queue_free()


func finish(why := "done") -> void:
	if ended:
		return
	ended = true
	if owns() and heroes != null and is_instance_valid(heroes):
		heroes.announce_end(fx_id, why)
	if not _end(why):
		queue_free()
