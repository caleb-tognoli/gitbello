// The image viewer's Difference mode (M7.7): pixels that differ between the
// old and new image in the changed colour, the rest as a faint grey copy of
// the new image. Both images sit at the top-left of the drawn rect, which
// spans the larger of the two; a pixel outside one image counts as
// transparent there. Pixels are sampled exactly (nearest).
shader_type canvas_item;

uniform sampler2D old_tex : filter_nearest;
uniform sampler2D new_tex : filter_nearest;
uniform vec2 old_size = vec2(1.0);
uniform vec2 new_size = vec2(1.0);
uniform vec2 area_size = vec2(1.0);
uniform bool has_old = false;
uniform bool has_new = false;
uniform vec4 changed_color : source_color = vec4(1.0, 0.2, 0.75, 1.0);
uniform float threshold = 0.004;

void fragment() {
	vec2 px = UV * area_size;
	vec4 o = vec4(0.0);
	vec4 n = vec4(0.0);
	if (has_old && px.x < old_size.x && px.y < old_size.y) {
		o = texture(old_tex, px / old_size);
	}
	if (has_new && px.x < new_size.x && px.y < new_size.y) {
		n = texture(new_tex, px / new_size);
	}
	vec4 d = abs(n - o);
	float m = max(max(d.r, d.g), max(d.b, d.a));
	if (m > threshold) {
		COLOR = vec4(changed_color.rgb, mix(0.6, 1.0, clamp(m * 4.0, 0.0, 1.0)));
	} else {
		float grey = dot(n.rgb, vec3(0.299, 0.587, 0.114));
		COLOR = vec4(vec3(grey), n.a * 0.25);
	}
}
