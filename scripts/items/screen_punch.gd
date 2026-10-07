extends CanvasLayer
## A short screen impulse for the heavy guns (weapon-feel pass, 2026-10-05, the user: "görsel zayıf"):
## the shotgun, the sniper and the rocket launcher kick the picture with a radial chromatic split and a
## faint radial smear toward the edges that fade out in ~0.12 s. Under the HUD (layer 2; the HUD is 5,
## feel_fx.gd's concussion 3). Cheap: the full-screen pass is hidden whenever the impulse is spent.
##   ScreenPunch.kick(k)   k 0..1 (stacks, capped at 1); local player only, call from the gun's fire()

## 2026-10-06 tok ("vuruşlar ... çok daha tok olsun"): a stronger but shorter punch: the split / smear
## × 1.25 (0.016 / 0.012 -> 0.02 / 0.015 in the shader), the fade 0.12 -> 0.1 s.
const FADE := 0.1                       # s from a full kick to nothing
const SHADER := """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float k = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 c = uv - 0.5;
	float r = length(c);
	float edge = smoothstep(0.05, 0.75, r);
	vec2 d = c * k * 0.02 * edge;
	vec3 col = vec3(texture(screen_tex, uv + d).r, texture(screen_tex, uv).g, texture(screen_tex, uv - d).b);
	vec3 smear = texture(screen_tex, uv - c * k * 0.015).rgb;
	col = mix(col, smear, 0.25 * k * smoothstep(0.2, 0.8, r));
	COLOR = vec4(col, 1.0);
}
"""

var _k := 0.0
var _rect: ColorRect
var _mat: ShaderMaterial


static func inst() -> Node:
	if Game.has_meta("screen_punch"):
		var s = Game.get_meta("screen_punch")
		if is_instance_valid(s):
			return s
	var n: Node = load("res://scripts/items/screen_punch.gd").new()
	n.name = "ScreenPunch"
	Game.add_child(n)
	Game.set_meta("screen_punch", n)
	return n


static func kick(k: float) -> void:
	var s = inst()
	if s != null:
		s.add(k)


func _ready() -> void:
	layer = 2
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rect = ColorRect.new()
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_rect.material = _mat
	_rect.visible = false
	add_child(_rect)


func add(k: float) -> void:
	_k = clampf(maxf(_k, 0.0) + k, 0.0, 1.0)
	if _rect != null:
		_rect.visible = true
		_mat.set_shader_parameter("k", _k * _k)


func _process(delta: float) -> void:
	if _k <= 0.0:
		return
	_k = maxf(_k - delta / FADE, 0.0)
	_mat.set_shader_parameter("k", _k * _k)
	if _k <= 0.0:
		_rect.visible = false
