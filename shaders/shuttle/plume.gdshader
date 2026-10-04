shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
// Engine / VTOL exhaust. CylinderMesh along local +Y: the nozzle end at y = -L/2 (wide), the tail at
// y = +L/2. `intensity` 0..~2, `stretch` lengthens the plume (vertex), `hot` blends to white-blue core.

uniform float intensity = 1.0;
uniform float stretch = 1.0;
uniform float hot = 0.0;
uniform float plume_length = 4.0;
uniform vec3 core_color : source_color = vec3(0.8, 0.95, 1.0);
uniform vec3 edge_color : source_color = vec3(0.15, 0.55, 1.0);

varying float t;

void vertex() {
	t = clamp(VERTEX.y / plume_length + 0.5, 0.0, 1.0);
	// Stretch from the nozzle end.
	VERTEX.y = (t * stretch - 0.5) * plume_length;
}

void fragment() {
	float fres = clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0);
	float core = pow(fres, 2.2);
	float fall = pow(max(1.0 - t, 0.0), 1.7);
	// Shock diamonds only at real thrust (an idling nozzle read as a strobing flicker), drifting
	// slowly; the living shimmer is a slow, shallow breath instead of a 50 Hz strobe.
	float dk = smoothstep(0.45, 1.2, intensity);
	float diamonds = 0.85 + 0.15 * sin(t * 24.0 - TIME * 14.0);
	float flick = 1.0 - 0.05 * (0.5 + 0.5 * sin(TIME * 7.0 + t * 5.0));
	vec3 col = mix(edge_color, core_color, clamp(core * (1.0 - t * 0.7) + hot * 0.4, 0.0, 1.0));
	float a = fall * (0.12 + core) * mix(1.0, diamonds, 0.5 * dk) * flick * intensity;
	ALBEDO = col * 2.4;
	ALPHA = clamp(a, 0.0, 1.0);
}
