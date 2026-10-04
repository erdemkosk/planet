extends RefCounted
## Build effects shared by the build tool, cannons and the AI: a dust burst, a hologram box that
## sweeps up and fades over the assembly, and the assembly sounds.
##   BuildFx.assemble(parent, xf, half_extents, color := CYAN)

const DigFx := preload("res://scripts/items/dig_fx.gd")

const CYAN := Color(0.4, 0.9, 1.0)


## Dust burst + hologram sweep + sounds at transform `xf` (basis y = up) for a structure of
## `half_extents` (m). Lasts ~1.4 s.
static func assemble(parent: Node, xf: Transform3D, half_extents: Vector3, color := CYAN) -> void:
	var up := xf.basis.y.normalized()
	dust(parent, xf.origin, up, maxf(half_extents.x, half_extents.z), Color(0.5, 0.45, 0.38))
	# Hologram: a translucent box that grows from the ground and fades.
	var box := BoxMesh.new()
	box.size = half_extents * 2.0
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(color.r, color.g, color.b, 0.35)
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	var base := Transform3D(xf.basis.orthonormalized(), xf.origin + up * half_extents.y)
	mi.global_transform = base.scaled_local(Vector3(1.0, 0.02, 1.0))
	var upd := func(k: float) -> void:
		if is_instance_valid(mi):
			var sy := maxf(k, 0.02)
			mi.global_transform = Transform3D(base.basis * Basis.from_scale(Vector3(1.0, sy, 1.0)),
					xf.origin + up * half_extents.y * sy)
			m.albedo_color.a = 0.35 * (1.0 - k * 0.6)
	var tw := mi.create_tween()
	tw.tween_method(upd, 0.0, 1.0, 1.1)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.4)
	tw.tween_callback(mi.queue_free)
	var sfx = Game.sfx
	if sfx != null:
		sfx.play_at("servo", xf.origin, -4.0, 0.8, 16.0)
		sfx.play_at("impact", xf.origin, -6.0, 0.8, 16.0)
		sfx.play("craft", -10.0, 0.9)


## One-shot dust and clod burst on the ground.
static func dust(parent: Node, pos: Vector3, up: Vector3, radius: float, col: Color) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 36
	p.lifetime = 1.8
	p.explosiveness = 0.9
	var q := QuadMesh.new()
	q.size = Vector2(1.4, 1.4)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = DigFx.soft_texture()
	q.material = m
	p.mesh = q
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = maxf(radius * 0.6, 0.5)
	p.direction = up
	p.spread = 75.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 4.0
	p.damping_min = 1.0
	p.damping_max = 2.0
	p.gravity = -up * 1.5
	p.scale_amount_min = 0.8
	p.scale_amount_max = 2.2
	var g := Gradient.new()
	g.set_color(0, Color(col.r, col.g, col.b, 0.55))
	g.set_color(1, Color(col.r, col.g, col.b, 0.0))
	p.color_ramp = g
	parent.add_child(p)
	p.global_position = pos + up * 0.3
	p.emitting = true
	p.finished.connect(p.queue_free)
