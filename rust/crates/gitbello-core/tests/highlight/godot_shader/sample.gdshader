shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Line comment
uniform vec4 albedo : source_color = vec4(1.0);
uniform float speed : hint_range(0.0, 10.0, 0.1) = 1.5;
uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
varying vec3 world_pos;
const int STEPS = 8;

/* Block comment */
void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    VERTEX.y += sin(TIME * speed) * 0.25;
}

void fragment() {
    vec4 tex = texture(noise, UV + TIME * 0.1);
    if (tex.r < 0.5) {
        discard;
    }
    ALBEDO = albedo.rgb * tex.rgb;
    ALPHA = clamp(tex.a, 0.0, 1.0) * PI;
}
