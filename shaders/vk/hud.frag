#version 450

// Samples the 8x8 font straight out of a uniform block: 128 glyphs of eight
// one-byte rows, packed four rows to a uint.

layout(std140, set = 0, binding = 2) uniform Hud_Font {
    uvec4 font[64];
};

layout(location = 0) in vec2 texel;
layout(location = 1) flat in uint code;
layout(location = 2) flat in vec4 color;
layout(location = 0) out vec4 frag_color;

void main() {
    ivec2 p = clamp(ivec2(texel), ivec2(0), ivec2(7));
    uint row = (code & 127u) * 8u + uint(p.y);
    uint word = font[row >> 4][(row >> 2) & 3u];
    uint bits = (word >> ((row & 3u) * 8u)) & 0xFFu;
    if (((bits >> uint(p.x)) & 1u) == 0u) {
        discard;
    }
    frag_color = color;
}
