#version 450
#extension GL_GOOGLE_include_directive : require

// Fullscreen triangle feeding the reference ray tracer (the fragment stage of
// shaders/scene.glsl, compiled unchanged). No vertex buffer: the three
// corners come from the vertex index.

#include "push.glsl"

layout(location = 0) out vec3 ray_origin;
layout(location = 1) out vec3 ray_dir;

void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
    gl_Position = vec4(p, 0.0, 1.0);
    ray_origin = pc.eye_hw.xyz;
    // Vulkan's clip space has y pointing down the screen.
    ray_dir = pc.forward.xyz + pc.right_hh.xyz * (p.x * pc.eye_hw.w) - pc.up.xyz * (p.y * pc.right_hh.w);
}
