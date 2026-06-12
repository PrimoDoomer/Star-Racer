shader_type canvas_item;

// Minimal flat menu backdrop: a clean vertical gradient with a single soft
// accent glow and a gentle vignette to frame the foreground panels. Kept
// almost static (a very slow drift on the glow) to stay calm and readable.

uniform vec3 top_color: source_color = vec3(0.09, 0.11, 0.15);
uniform vec3 bottom_color: source_color = vec3(0.04, 0.05, 0.07);
uniform vec3 accent_color: source_color = vec3(0.12, 0.3, 0.6);
uniform float vignette: hint_range(0.0, 1.0) = 0.5;

void fragment() {
	// Smooth vertical gradient, lighter at the top.
	float t = smoothstep(0.0, 1.0, UV.y);
	vec3 color = mix(top_color, bottom_color, t);

	// Soft accent glow rising from the lower-centre, very subtly drifting.
	vec2 g = vec2(UV.x - 0.5 + sin(TIME * 0.08) * 0.06, UV.y - 1.05);
	float glow = exp(-dot(g, g) * 3.2);
	color += accent_color * glow * 0.35;

	// Gentle radial vignette so the panels sit on a slightly darker frame.
	vec2 d = UV - 0.5;
	float r = dot(d, d);
	color *= mix(1.0, 1.0 - vignette, clamp(r * 1.6, 0.0, 1.0));

	COLOR = vec4(color, 1.0);
}
