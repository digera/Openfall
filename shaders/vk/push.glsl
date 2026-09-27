// Push constants shared by every pipeline in the Vulkan backend. Each shader
// includes the whole block so the offsets agree; it is 80 bytes, well under
// the 128 every implementation guarantees.
layout(push_constant) uniform Push {
    vec4 eye_hw;     // xyz eye, w tan(half horizontal fov)
    vec4 right_hh;   // xyz right, w tan(half vertical fov)
    vec4 up;         // xyz up
    vec4 forward;    // xyz forward
    vec4 hud;        // xy viewport px, z px per text cell, w unused
} pc;
