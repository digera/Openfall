#version 450
#extension GL_GOOGLE_include_directive : require

// HUD text: one instanced quad per character, drawn as a 4-vertex strip.

#include "push.glsl"

struct Glyph {
    vec2 cell;    // top-left corner, in text cells from the viewport's corner
    uint code;    // ASCII
    uint color;   // RGBA8
};

layout(std430, set = 0, binding = 0) readonly buffer Hud_Glyphs {
    Glyph glyphs[];
};

layout(location = 0) out vec2 texel;
layout(location = 1) flat out uint code;
layout(location = 2) flat out vec4 color;

void main() {
    Glyph g = glyphs[gl_InstanceIndex];
    vec2 corner = vec2(gl_VertexIndex & 1, gl_VertexIndex >> 1);
    vec2 px = (g.cell + corner) * pc.hud.z;
    gl_Position = vec4(px / pc.hud.xy * 2.0 - 1.0, 0.0, 1.0);
    texel = corner * 8.0;
    code = g.code;
    color = unpackUnorm4x8(g.color);
}
