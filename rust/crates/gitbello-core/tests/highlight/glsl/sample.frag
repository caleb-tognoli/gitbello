#version 450 core
#define MAX_LIGHTS 4

layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

uniform sampler2D uTexture;
uniform float uTime; // seconds

/* Block comment */
struct Light {
    vec3 position;
    float intensity;
};

float falloff(float d) {
    return 1.0 / (1.0 + d * d);
}

void main() {
    vec4 color = texture(uTexture, vUv);
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (color.a < 0.5) discard;
        color.rgb *= falloff(float(i)) * 2.5e-1;
    }
    gl_FragDepth = gl_FragCoord.z;
    fragColor = color;
}

float4 PSMain(float4 pos : SV_Position) : SV_Target { return float4(1, 0, 0, 1); }
