shader_type canvas_item;

// Flat menu backdrop: a near-solid dark fill with a barely-there vertical
// gradient and a gentle vignette to frame the foreground panels. No animated
// glow and no neon accent — kept calm and readable.

uniform vec3 top_color: source_color = vec3(0.1, 0.115, 0.14);
uniform vec3 bottom_color: source_color = vec3(0.075, 0.085, 0.105);
uniform float vignette: hint_range(0.0, 1.0) = 0.32;

void fragment() {
	// Very subtle vertical gradient, slightly lighter at the top.
	float t = smoothstep(0.0, 1.0, UV.y);
	vec3 color = mix(top_color, bottom_color, t);

	// Gentle radial vignette so the panels sit on a slightly darker frame.
	vec2 d = UV - 0.5;
	float r = dot(d, d);
	color *= mix(1.0, 1.0 - vignette, clamp(r * 1.6, 0.0, 1.0));

	COLOR = vec4(color, 1.0);
}
