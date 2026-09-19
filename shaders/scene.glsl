@header package main
@header import sg "sokol:gfx"

@ctype vec3 vec3
@ctype vec4 vec4

@vs vs
layout(binding=0) uniform vs_params {
    vec3 cam_pos;
    float half_w;
    vec3 cam_right;
    float half_h;
    vec3 cam_up;
    float _pad0;
    vec3 cam_forward;
    float _pad1;
};

in vec2 position;
out vec3 ray_origin;
out vec3 ray_dir;

void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    ray_origin = cam_pos;
    ray_dir = cam_forward + cam_right * (position.x * half_w) + cam_up * (position.y * half_h);
}
@end

@fs fs
// Analytic ray tracer for the Nexus Arena greybox.
// World = union of yaw-rotated boxes (walkable) minus solid cover boxes.
layout(binding=1) uniform fs_params {
    vec4 cam_data;          // xyz cam pos, w world time
    vec4 fx;                // x hurt, y flash, z local team, w cast pulse
    vec4 fx2;               // x hit marker, y dead, z match ended, w mend
    vec4 hand_pos;          // xyz hand orb position, w scale
    vec4 hand_cast;         // x spell render code being charged (0 = none), y charge 0..1
    vec4 floor_boxes[22];   // pairs: (center.xyz, sin yaw), (half.xyz, cos yaw)
    vec4 solid_boxes[30];   // pairs, same layout
    vec4 pylons[7];         // xyz base centre on the floor, w yaw
    vec4 pylon_shape[7];    // x height, y circumradius, z noise seed, w ore kind
    vec4 pylon_bound[7];    // x local z0, y local z1, z radius, w fraction standing
    vec4 chunks[8];         // xyz pos, w radius (0 = none)
    vec4 chunk_fx[8];       // x ore kind, y seed, z 1 if settled
    vec4 projectiles[12];   // xyz pos, w = type + radius
    vec4 proj_vel[12];      // xyz vel
    vec4 wisps[16];         // xyz pos, w = team + hp (0 = none)
    vec4 wisp_cast[16];     // xyz cast orb centre, w = spell render code (0 = not casting)
    vec4 wisp_aim[16];      // xyz aim direction (unit), w = charge 0..1
    vec4 robes[16];         // xyz hem ring centre, w = body yaw
    vec4 robe_waists[16];   // xyz waist ring centre, w = hem yaw (pleat twist)
    vec4 robe_fx[16];       // x flutter 0..1, y seconds since this wisp died (0 = alive)
    vec4 impacts[8];        // xyz pos, w = type + age (0 = none)
    vec4 lightning[4];      // xyz ground pos, w = life 1 -> 0 (0 = none)
    vec4 beams[4];          // xyz origin, w = spell render code (0 = none)
    vec4 beam_ends[4];      // xyz far end, w = 1 if it ends on a body
    vec4 beam_chains[8];    // xyz chain target, w = 1 valid; 2 per beam
    vec4 target_mark;       // xyz sticky target centre, w = 0 none, 1 hostile, 2 friendly
};

// Every pylon's damage field, stacked along Z into one volume: slab i covers
// [i*PYLON_NZ, (i+1)*PYLON_NZ). One byte per voxel, 255 = untouched ore.
layout(binding=0) uniform texture3D pylon_tex;
layout(binding=0) uniform sampler pylon_smp;

in vec3 ray_origin;
in vec3 ray_dir;
out vec4 frag_color;

const int NFLOOR = 11;
const int NSOLID = 15;
const int NPYLON = 7;
const int NCHUNK = 8;

const int MAT_NONE = 0;
const int MAT_WALL = 1;
const int MAT_FLOOR = 2;
const int MAT_SKY = 3;
const int MAT_SOLID = 4;
const int MAT_PYLON = 5;
const int MAT_WISP = 6;
const int MAT_PROJ = 7;
const int MAT_HAND = 8;
const int MAT_ROBE = 9;
const int MAT_CAST_ORB = 10;
const int MAT_CHUNK = 11;

const vec3 MOON_DIR = normalize(vec3(0.35, -0.55, 0.75));

#define WORLD_T (cam_data.w)

// ---------------------------------------------------------------------------
// Helpers

vec3 rot_z(vec3 v, float s, float c) {      // world -> box local
    return vec3(c * v.x + s * v.y, -s * v.x + c * v.y, v.z);
}
vec3 unrot_z(vec3 v, float s, float c) {    // box local -> world
    return vec3(c * v.x - s * v.y, s * v.x + c * v.y, v.z);
}

float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

vec3 team_tint(float team) {
    if (team < 0.5) return vec3(0.78, 0.78, 0.84);
    if (team < 1.5) return vec3(1.00, 0.40, 0.30);
    if (team < 2.5) return vec3(0.38, 0.66, 1.00);
    return vec3(0.42, 0.95, 0.50);
}

vec3 team_core(float team) {
    if (team < 0.5) return vec3(0.95, 0.95, 1.00);
    if (team < 1.5) return vec3(1.00, 0.90, 0.72);
    if (team < 2.5) return vec3(0.84, 0.94, 1.00);
    return vec3(0.88, 1.00, 0.86);
}

vec3 spell_tint(float type) {
    if (type < 1.5) return vec3(0.78, 0.46, 1.00);   // missile: violet
    if (type < 2.5) return vec3(0.52, 0.48, 1.00);   // orb: indigo
    if (type < 3.5) return vec3(1.00, 1.00, 1.00);   // blink
    if (type < 4.5) return vec3(0.50, 0.92, 1.00);   // frost: cyan
    if (type < 5.5) return vec3(0.82, 0.90, 1.00);   // lightning: white-blue
    if (type < 6.5) return vec3(0.62, 0.80, 1.00);   // thunderbolt: electric blue
    return vec3(0.50, 0.95, 0.65);                   // heal beam: soft green
}

// A beam that mends reads green where one that burns reads white-hot, so which
// of the two is lit on a teammate is clear from across a lane.
bool beam_mends(float type) { return type > 6.5; }

// Held rather than charged: the beams, Thunderbolt (6) and Friendly Heal (7).
// A beam reports a full charge for as long as it is lit, so anything keyed to a
// wind-up nearing its release -- the white flash at the top of one -- would be
// stuck on for a whole beam and would burn its colour out. There is no release
// to warn about: the beam is already happening.
//
// Keyed off the render code like beam_mends above, so a spell that changes
// between a held beam and a wind-up has to be moved in both.
bool spell_is_held(float type) { return type > 5.5; }

vec3 beam_core(float type) {
    return beam_mends(type) ? vec3(0.55, 1.00, 0.70) : vec3(0.95, 0.98, 1.00);
}

// The orb in the player's own hand. It idles in the team's light, and turns
// more and more into the charging spell's as the wind-up runs -- the same orb
// every opponent sees on this wisp (wisp_cast), seen from the inside, so the
// two must read as one object.
float hand_cast_blend() {
    return hand_cast.x < 0.5 ? 0.0 : (0.35 + 0.65 * hand_cast.y);
}

vec3 hand_tint() {
    return mix(team_tint(fx.z), spell_tint(hand_cast.x), hand_cast_blend());
}

vec3 hand_core() {
    return mix(team_core(fx.z), mix(spell_tint(hand_cast.x), vec3(1.0), 0.5), hand_cast_blend());
}

bool intersect_sphere(vec3 ro, vec3 rd, vec3 c, float r, float tmin, float tmax, out float t, out vec3 n) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    vec3 oc = ro - c;
    float b = dot(oc, rd);
    float h = b * b - dot(oc, oc) + r * r;
    // NOTE: every path below must stay NaN-free (no sqrt of negatives, no
    // normalize of zero). The HLSL backend flattens this control flow and a
    // NaN computed on a not-taken path can leak into the out params.
    float s = sqrt(max(h, 0.0));
    float t0 = -b - s;
    float t1 = -b + s;
    float tt = (t0 < tmin) ? t1 : t0;
    if (h < 0.0 || tt < tmin || tt > tmax) return false;
    t = tt;
    n = ((ro + rd * t) - c) / max(r, 1e-4);
    return true;
}

// Conservative bounding-sphere test: true if the ray could hit anything
// inside the sphere before tmax (including when the origin is inside).
bool bounds_hit(vec3 ro, vec3 rd, vec3 c, float r, float tmax) {
    vec3 oc = ro - c;
    float b = dot(oc, rd);
    float cc = dot(oc, oc) - r * r;
    if (cc < 0.0) return true;
    float h = b * b - cc;
    float t = -b - sqrt(max(h, 0.0));
    return h >= 0.0 && t > 0.0 && t < tmax;
}

bool intersect_ellipsoid(vec3 ro, vec3 rd, vec3 c, vec3 rad, float tmin, float tmax, out float t, out vec3 n) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    vec3 o = (ro - c) / rad;
    vec3 d = rd / rad;
    float a = dot(d, d);
    float b = dot(o, d);
    float cc = dot(o, o) - 1.0;
    float h = b * b - a * cc;
    // NaN-free on all paths (see intersect_sphere).
    float s = sqrt(max(h, 0.0));
    float ia = 1.0 / max(a, 1e-8);
    float t0 = (-b - s) * ia;
    float t1 = (-b + s) * ia;
    float tt = (t0 < tmin) ? t1 : t0;
    if (h < 0.0 || tt < tmin || tt > tmax) return false;
    t = tt;
    vec3 p = ro + rd * t;
    vec3 g = (p - c) / (rad * rad);
    n = g * inversesqrt(max(dot(g, g), 1e-12));
    return true;
}

// Soft glow from a point along the ray (closest approach), limited to [0, tmax].
float corona(vec3 ro, vec3 rd, float tmax, vec3 c, float radius) {
    vec3 oc = c - ro;
    float tca = dot(oc, rd);
    float t = clamp(tca, 0.04, tmax);
    float d = length((ro + rd * t) - c);
    float g = 1.0 - smoothstep(radius * 0.4, radius * 3.0, d);
    g *= g;
    float along = smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(tmax - 0.4, tmax + 0.2, tca));
    return g * along;
}

// Glow from a line segment (projectile trail).
float segment_glow(vec3 ro, vec3 rd, float tmax, vec3 a, vec3 b, float radius) {
    vec3 ab = b - a;
    vec3 w0 = ro - a;
    float bb = dot(rd, ab);
    float c = dot(ab, ab);
    float d = dot(rd, w0);
    float e = dot(ab, w0);
    float den = c - bb * bb;
    float s = (den > 1e-5) ? clamp((e - bb * d) / den, 0.0, 1.0) : 0.0;
    vec3 q = a + ab * s;
    float t = clamp(dot(q - ro, rd), 0.04, tmax);
    float dist = length((ro + rd * t) - q);
    float g = 1.0 - smoothstep(radius * 0.3, radius * 2.6, dist);
    g *= g;
    float along = 1.0 - smoothstep(tmax - 0.4, tmax + 0.2, dot(q - ro, rd));
    return g * along * (0.35 + 0.65 * s);
}

// Glow from a crackling arc between `a` and `b`: the straight segment broken
// into pieces whose joints wander off the line and re-roll thirty times a
// second. `amp` is how far a joint may stray, `radius` the core thickness.
vec3 arc_glow(vec3 ro, vec3 rd, float tmax, vec3 a, vec3 b, float radius, float amp, float seed) {
    vec3 ab = b - a;
    float len = length(ab);
    if (len < 0.05) return vec3(0.0);
    vec3 dir = ab / len;
    vec3 side = normalize(cross(dir, abs(dir.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
    vec3 lift = cross(dir, side);
    float roll = floor(WORLD_T * 30.0) + seed * 13.0;
    const int N = 8;
    vec3 core = vec3(0.95, 0.98, 1.00);
    vec3 tint = vec3(0.45, 0.72, 1.00);
    vec3 sum = vec3(0.0);
    vec3 prev = a;
    for (int k = 1; k <= N; k++) {
        float f = float(k) / float(N);
        vec3 node = a + ab * f;
        if (k < N) {
            // Ends stay pinned so the arc always leaves the hand and lands
            // on the mark; the middle is where it wanders.
            float sway = amp * sin(f * 3.14159);
            node += side * (hash13(vec3(roll, float(k), seed)) - 0.5) * 2.0 * sway
                  + lift * (hash13(vec3(roll, float(k) + 5.0, seed)) - 0.5) * 2.0 * sway;
        }
        sum += core * segment_glow(ro, rd, tmax, prev, node, radius);
        prev = node;
    }
    // Soft halo along the straight line under the crackle.
    sum += tint * segment_glow(ro, rd, tmax, a, b, radius * 5.0) * 0.45;
    return sum;
}

// Four corner brackets framing the sticky target, in the target's own place in
// the world rather than pinned to the middle of the screen. Red says the mark
// is hostile, green says it is an ally the heal will reach. The frame is turned
// to face the eye, so it reads the same from any approach instead of thinning
// to a line when the arena is crossed sideways. Its span stays the width of a
// body, which is what makes it look like a frame around something; only the
// stroke thickens with range, so a mark across the plaza is still a mark rather
// than a sub-pixel shimmer.
vec3 target_mark_glow(vec3 ro, vec3 rd, float tmax, vec3 centre, float relation) {
    if (relation < 0.5) return vec3(0.0);
    vec3 tint = (relation < 1.5) ? vec3(1.00, 0.26, 0.16) : vec3(0.38, 1.00, 0.36);

    vec3 to_mark = centre - ro;
    float dist = length(to_mark);
    if (dist < 0.6) return vec3(0.0);
    vec3 view = to_mark / dist;
    // Standing directly over a target makes world up useless as a reference,
    // so the frame rolls onto another axis rather than going to pieces.
    vec3 ref = abs(view.z) < 0.99 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 right = normalize(cross(view, ref));
    vec3 up = cross(right, view);

    const float span = 0.62;   // half-width of the frame, about a robe across
    const float arm  = 0.26;   // how far each corner runs before it stops
    float thick = max(0.030, dist * 0.0025);

    vec3 sum = vec3(0.0);
    for (int i = 0; i < 4; i++) {
        float sx = (i == 0 || i == 2) ? -1.0 : 1.0;
        float sy = (i < 2) ? 1.0 : -1.0;
        vec3 corner = centre + right * (sx * span) + up * (sy * span);
        sum += segment_glow(ro, rd, tmax, corner, corner - right * (sx * arm), thick);
        sum += segment_glow(ro, rd, tmax, corner, corner - up * (sy * arm), thick);
    }
    return tint * sum * 1.4;
}

// ---------------------------------------------------------------------------
// World geometry

// Walk through the union of walkable boxes. Returns the wall/floor hit, or
// false with mat = MAT_SKY when the ray escapes upward.
// Nearest entry into any walkable box for a ray that starts outside the world.
float world_entry(vec3 ro, vec3 rd) {
    float best = -1.0;
    for (int i = 0; i < NFLOOR; i++) {
        vec4 c = floor_boxes[2 * i];
        vec4 hh = floor_boxes[2 * i + 1];
        vec3 h = hh.xyz;
        vec3 lo = rot_z(ro - c.xyz, c.w, hh.w);
        vec3 ld = rot_z(rd, c.w, hh.w);
        ld += vec3(equal(ld, vec3(0.0))) * 1e-6;
        vec3 inv = 1.0 / ld;
        vec3 t0s = (-h - lo) * inv;
        vec3 t1s = (h - lo) * inv;
        vec3 tmn = min(t0s, t1s);
        vec3 tmx = max(t0s, t1s);
        float tn = max(max(tmn.x, tmn.y), tmn.z);
        float tf = min(min(tmx.x, tmx.y), tmx.z);
        if (tf < max(tn, 0.0) || tn <= 0.0) continue;
        if (best < 0.0 || tn < best) best = tn;
    }
    return best;
}

bool world_trace(vec3 ro, vec3 rd, out float t, out vec3 n, out int mat) {
    float tcur = 0.0;
    vec3 ncur = vec3(0.0, 0.0, 1.0);
    for (int step = 0; step < 8; step++) {
        if (step == 0) {
            // Camera outside the walkable volume (lobby orbit): jump to the first box.
            bool inside = false;
            for (int i = 0; i < NFLOOR; i++) {
                vec4 c = floor_boxes[2 * i];
                vec4 hh = floor_boxes[2 * i + 1];
                vec3 lp = rot_z(ro - c.xyz, c.w, hh.w);
                if (all(lessThanEqual(abs(lp), hh.xyz))) { inside = true; break; }
            }
            if (!inside) {
                float te = world_entry(ro, rd);
                if (te < 0.0) {
                    t = 1e5; n = vec3(0.0, 0.0, -1.0); mat = MAT_SKY;
                    return false;
                }
                tcur = te;
            }
        }
        vec3 p = ro + rd * (tcur + 0.01);
        float best_exit = -1.0;
        vec3 best_n = vec3(0.0, 0.0, 1.0);
        for (int i = 0; i < NFLOOR; i++) {
            vec4 c = floor_boxes[2 * i];
            vec4 hh = floor_boxes[2 * i + 1];
            vec3 h = hh.xyz;
            float s = c.w;
            float co = hh.w;
            vec3 lp = rot_z(p - c.xyz, s, co);
            if (any(greaterThan(abs(lp), h))) continue;
            vec3 ld = rot_z(rd, s, co);
            vec3 sd = sign(ld);
            sd += vec3(equal(sd, vec3(0.0)));
            vec3 ald = max(abs(ld), vec3(1e-6));
            vec3 tt = (h - lp * sd) / ald;
            float te = min(tt.x, min(tt.y, tt.z));
            if (te > best_exit) {
                best_exit = te;
                vec3 ln = (te == tt.x) ? vec3(-sd.x, 0.0, 0.0) : ((te == tt.y) ? vec3(0.0, -sd.y, 0.0) : vec3(0.0, 0.0, -sd.z));
                best_n = unrot_z(ln, s, co);
            }
        }
        if (best_exit < 0.0) {
            if (step == 0) {
                t = 1e5; n = vec3(0.0, 0.0, -1.0); mat = MAT_SKY;
                return false;
            }
            t = tcur; n = ncur;
            mat = ncur.z > 0.5 ? MAT_FLOOR : (ncur.z < -0.5 ? MAT_SKY : MAT_WALL);
            return mat != MAT_SKY;
        }
        tcur = tcur + 0.01 + best_exit;
        ncur = best_n;
    }
    t = tcur; n = ncur;
    mat = ncur.z > 0.5 ? MAT_FLOOR : (ncur.z < -0.5 ? MAT_SKY : MAT_WALL);
    return mat != MAT_SKY;
}

bool solid_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n) {
    bool hit = false;
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    for (int i = 0; i < NSOLID; i++) {
        vec4 c = solid_boxes[2 * i];
        vec4 hh = solid_boxes[2 * i + 1];
        vec3 h = hh.xyz;
        float s = c.w;
        float co = hh.w;
        vec3 lo = rot_z(ro - c.xyz, s, co);
        vec3 ld = rot_z(rd, s, co);
        ld += vec3(equal(ld, vec3(0.0))) * 1e-6;
        vec3 inv = 1.0 / ld;
        vec3 t0s = (-h - lo) * inv;
        vec3 t1s = (h - lo) * inv;
        vec3 tmn = min(t0s, t1s);
        vec3 tmx = max(t0s, t1s);
        float tn = max(max(tmn.x, tmn.y), tmn.z);
        float tf = min(min(tmx.x, tmx.y), tmx.z);
        if (tf < max(tn, 0.0) || tn <= 0.02 || tn >= t) continue;
        t = tn;
        hit = true;
        vec3 ln = (tn == tmn.x) ? vec3(-sign(ld.x), 0.0, 0.0) : ((tn == tmn.y) ? vec3(0.0, -sign(ld.y), 0.0) : vec3(0.0, 0.0, -sign(ld.z)));
        n = unrot_z(ln, s, co);
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Ore pylons
//
// A pylon is a procedural hexagonal obelisk (the body) with everything mined
// out of it subtracted (the damage field, sampled from pylon_tex). Both halves
// have twins on the CPU: the body in src/pylon_sdf.odin, the field in
// src/ore_grid.odin. They must agree to the last bit, because the server
// decides what a spell carved out with those procs while the player aims with
// this shader -- so the integer hash below is integer on purpose, and any
// change here is a change there.

const float PYLON_GRAIN_AMP  = 0.16;
const float PYLON_GRAIN_FREQ = 2.10;
const float PYLON_CAP_START  = 0.82;
const float PYLON_CAP_WAIST  = 0.62;
const float PYLON_CUT_BODY   = -0.02;

const float PYLON_CELL   = 0.25;
const float PYLON_NX_F   = 32.0;
const float PYLON_NY_F   = 32.0;
const float PYLON_NZ_F   = 80.0;
const float PYLON_HALF_X = PYLON_NX_F * PYLON_CELL * 0.5;
const float PYLON_HALF_Y = PYLON_NY_F * PYLON_CELL * 0.5;
const float PYLON_ATLAS_NZ = PYLON_NZ_F * float(NPYLON);

// Fewer than the CPU's 192. The CPU marcher answers one query per bite and can
// afford to be thorough; this one runs per pixel per pylon, and what it loses is
// a rare sliver of ore seen edge-on at grazing incidence.
const int PYLON_TRACE_STEPS = 128;
const float PYLON_EPS = 0.012;

vec3 ore_tint(float ore) {
    if (ore < 1.5) return vec3(1.00, 0.44, 0.24);   // ember
    if (ore < 2.5) return vec3(0.34, 0.68, 1.00);   // tide
    if (ore < 3.5) return vec3(0.42, 0.95, 0.52);   // verdant
    return vec3(1.00, 0.82, 0.32);                  // gold
}

// The rock itself, before any vein light. Gold ore is warmer stone than the
// team ores so the centre reads as the prize from anywhere on the map.
vec3 ore_stone(float ore) {
    if (ore > 3.5) return vec3(0.30, 0.26, 0.17);
    return vec3(0.22, 0.21, 0.23);
}

uint pylon_uhash(int x, int y, int z) {
    uint n = uint(x) * 1597334677u ^ uint(y) * 3812015801u ^ uint(z) * 3299493293u;
    n = (n << 13) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return n;
}

float pylon_hash31(int x, int y, int z) {
    return float(pylon_uhash(x, y, z) & 0x7fffffffu) / 2147483647.0;
}

float pylon_vnoise(vec3 p) {
    vec3 ip = floor(p);
    int ix = int(ip.x);
    int iy = int(ip.y);
    int iz = int(ip.z);
    vec3 f = p - ip;
    vec3 u = f * f * (3.0 - 2.0 * f);
    float n000 = pylon_hash31(ix,     iy,     iz);
    float n100 = pylon_hash31(ix + 1, iy,     iz);
    float n010 = pylon_hash31(ix,     iy + 1, iz);
    float n110 = pylon_hash31(ix + 1, iy + 1, iz);
    float n001 = pylon_hash31(ix,     iy,     iz + 1);
    float n101 = pylon_hash31(ix + 1, iy,     iz + 1);
    float n011 = pylon_hash31(ix,     iy + 1, iz + 1);
    float n111 = pylon_hash31(ix + 1, iy + 1, iz + 1);
    float nx00 = mix(n000, n100, u.x);
    float nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x);
    float nx11 = mix(n011, n111, u.x);
    return mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z);
}

float pylon_fbm2(vec3 p) {
    return pylon_vnoise(p) * 0.65 + pylon_vnoise(p * 2.13) * 0.35;
}

float pylon_grain(vec3 p, float radius, float seed) {
    vec3 q = p * (PYLON_GRAIN_FREQ / max(radius, 0.5)) + vec3(seed, seed * 0.3, -seed);
    return pylon_fbm2(q);
}

// Where the rock is rich. Drives the vein light on an intact face and the
// brighter seams on a cut one, so a seam a player learns to look for is the same
// seam the server pays out more ore for.
float pylon_ridged(vec3 p) {
    float n = pylon_vnoise(p);
    float r = 1.0 - abs(n * 2.0 - 1.0);
    return r * r;
}

float pylon_vein(vec3 p, float seed) {
    vec3 q = p * 0.9 + vec3(seed * 1.7, seed * 0.4, seed * 2.1);
    float v = pylon_ridged(q);
    v = max(v, pylon_ridged(p * 1.7 + vec3(seed, seed * 2.0, -seed)) * 0.55);
    return pow(clamp(v, 0.0, 1.0), 6.0);
}

// Hexagon of circumradius r, centred on the origin.
float pylon_sd_hex(vec2 p, float r) {
    const float kx = -0.8660254;
    const float ky = 0.5;
    const float kz = 0.57735;
    vec2 q = abs(p);
    float d = 2.0 * min(kx * q.x + ky * q.y, 0.0);
    q -= vec2(kx, ky) * d;
    q -= vec2(clamp(q.x, -kz * r, kz * r), r);
    return length(q) * ((q.y >= 0.0) ? 1.0 : -1.0);
}

float pylon_radius_at(float z, float height, float radius) {
    float t = clamp(z / max(height, 0.01), 0.0, 1.0);
    float waist = radius * PYLON_CAP_WAIST;
    if (t <= PYLON_CAP_START) return mix(radius, waist, t / PYLON_CAP_START);
    return waist * (1.0 - (t - PYLON_CAP_START) / (1.0 - PYLON_CAP_START));
}

float pylon_sdf_hull(vec3 p, float height, float radius) {
    float r = pylon_radius_at(p.z, height, radius);
    float d_xy = pylon_sd_hex(p.xy, max(r, 0.001));
    float half_h = height * 0.5;
    float d_z = abs(p.z - half_h) - half_h;
    vec2 outside = vec2(max(d_xy, 0.0), max(d_z, 0.0));
    return min(max(d_xy, d_z), 0.0) + length(outside);
}

float pylon_sdf_body(vec3 p, float height, float radius, float seed) {
    float d = pylon_sdf_hull(p, height, radius);
    return d + radius * PYLON_GRAIN_AMP * (pylon_grain(p, radius, seed) * 2.0 - 1.0);
}

// How far the true surface can lag behind the hull distance: the taper tilts the
// sides and the grain adds slope, so a full step on the hull overshoots.
float pylon_step_scale(float height, float radius) {
    float cap_slope = (radius * PYLON_CAP_WAIST) / max((1.0 - PYLON_CAP_START) * height, 0.01);
    float taper = sqrt(1.0 + cap_slope * cap_slope);
    float fbm_w = 0.65 + 0.35 * 2.13;
    float grain_slope = 2.6 * (PYLON_GRAIN_AMP * 2.0) * PYLON_GRAIN_FREQ * fbm_w;
    return 1.0 / (taper + grain_slope);
}

// Trilinear density in pylon i's slab of the atlas. The clamp keeps the filter
// footprint inside the slab, so no pylon bleeds into its neighbour's base.
float pylon_density(int i, vec3 lp) {
    vec3 g = vec3((lp.x + PYLON_HALF_X) / PYLON_CELL,
                  (lp.y + PYLON_HALF_Y) / PYLON_CELL,
                  lp.z / PYLON_CELL);
    g = clamp(g, vec3(0.5), vec3(PYLON_NX_F - 0.5, PYLON_NY_F - 0.5, PYLON_NZ_F - 0.5));
    vec3 uvw = vec3(g.x / PYLON_NX_F,
                    g.y / PYLON_NY_F,
                    (g.z + float(i) * PYLON_NZ_F) / PYLON_ATLAS_NZ);
    // Explicit LOD, not `texture`: this is called from the marcher's loop, and an
    // implicit mip derivative inside a loop whose trip count varies per pixel is
    // a gradient instruction HLSL will not compile. There is one mip anyway.
    return textureLod(sampler3D(pylon_tex, pylon_smp), uvw, 0.0).r;
}

// Positive in mined-out space, ~0 on the cut face, negative in remaining ore.
// Only a true distance within about half a cell, which is why the marcher caps
// its step once it is inside the body.
float pylon_carve_sdf(int i, vec3 lp) {
    return (0.5 - pylon_density(i, lp)) * PYLON_CELL;
}

float pylon_sdf_local(int i, vec3 p, float height, float radius, float seed) {
    return max(pylon_sdf_body(p, height, radius, seed), pylon_carve_sdf(i, p));
}

// Clip a ray to a Z-aligned cylinder in local space. Twin of pylon_bound_clip
// in src/pylon_sdf.odin.
bool pylon_bound_clip(vec3 ro, vec3 rd, float z0, float z1, float radius, float max_t,
                      out float t0, out float t1) {
    float enter = 0.0;
    float exit = max_t;
    t0 = 0.0;
    t1 = 0.0;

    if (abs(rd.z) < 1e-6) {
        if (ro.z < z0 || ro.z > z1) return false;
    } else {
        float inv = 1.0 / rd.z;
        float a = (z0 - ro.z) * inv;
        float b = (z1 - ro.z) * inv;
        enter = max(enter, min(a, b));
        exit = min(exit, max(a, b));
    }

    float qa = rd.x * rd.x + rd.y * rd.y;
    float qc = ro.x * ro.x + ro.y * ro.y - radius * radius;
    if (qa < 1e-12) {
        if (qc > 0.0) return false;
    } else {
        float qb = ro.x * rd.x + ro.y * rd.y;
        float disc = qb * qb - qa * qc;
        if (disc < 0.0) return false;
        float root = sqrt(disc);
        enter = max(enter, (-qb - root) / qa);
        exit = min(exit, (-qb + root) / qa);
    }

    if (enter > exit) return false;
    t0 = max(enter, 0.0);
    t1 = exit;
    return true;
}

// Sphere-trace one pylon in its own frame. Negative on a miss. Twin of
// pylon_trace_local in src/pylon_sdf.odin.
float pylon_trace_local(int i, vec3 ro, vec3 rd, float height, float radius, float seed,
                        float z0, float z1, float bound_r, float max_t) {
    float t, end;
    if (!pylon_bound_clip(ro, rd, z0, z1, bound_r, max_t, t, end)) return -1.0;

    float amp = radius * PYLON_GRAIN_AMP;
    float step_scale = pylon_step_scale(height, radius);
    // The carve field is only a half-cell band, so inside the body the step has
    // to be capped or the ray tunnels straight through a mined wall.
    float max_step = PYLON_CELL * 0.5;

    for (int s = 0; s < PYLON_TRACE_STEPS; s++) {
        if (t > end) return -1.0;
        vec3 p = ro + rd * t;
        float hull = pylon_sdf_hull(p, height, radius);
        float prev = t;

        // Further out than the grain can reach: step on the hull and skip the
        // noise entirely, which is what makes approaching a tower cheap.
        if (hull > amp) {
            t += hull - amp;
            if (t <= prev) t = prev + PYLON_EPS;
            continue;
        }

        float body;
        float d;
        if (hull < -amp) {
            // Deep inside: the body is certainly negative, so only a carve can
            // stop the ray.
            body = hull + amp;
            d = pylon_carve_sdf(i, p);
        } else {
            body = pylon_sdf_body(p, height, radius, seed);
            d = body;
            if (body <= max_step) d = max(d, pylon_carve_sdf(i, p));
        }
        if (d < PYLON_EPS) return t;
        float adv = d * step_scale;
        if (body < max_step) adv = min(adv, max_step);
        t += adv;
        if (t <= prev) t = prev + PYLON_EPS;
    }
    return -1.0;
}

vec3 pylon_normal_local(int i, vec3 p, float height, float radius, float seed) {
    // Floored at a quarter cell: any tighter and the central difference reads
    // the trilinear ramp as noise and the cut faces come out sparkling.
    float e = max(clamp(radius * 0.006, 0.004, 0.03), PYLON_CELL * 0.25);
    return normalize(vec3(
        pylon_sdf_local(i, p + vec3(e, 0.0, 0.0), height, radius, seed) - pylon_sdf_local(i, p - vec3(e, 0.0, 0.0), height, radius, seed),
        pylon_sdf_local(i, p + vec3(0.0, e, 0.0), height, radius, seed) - pylon_sdf_local(i, p - vec3(0.0, e, 0.0), height, radius, seed),
        pylon_sdf_local(i, p + vec3(0.0, 0.0, e), height, radius, seed) - pylon_sdf_local(i, p - vec3(0.0, 0.0, e), height, radius, seed)));
}

// Nearest pylon along the ray. `local` comes back so the material stage can
// re-evaluate the body without redoing the transform.
bool pylon_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out int idx, out vec3 local) {
    bool hit = false;
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    idx = 0;
    local = vec3(0.0);
    for (int i = 0; i < NPYLON; i++) {
        vec4 b = pylon_bound[i];
        if (b.w <= 0.002 || b.y <= b.x) continue;   // mined flat: nothing to draw
        vec4 sh = pylon_shape[i];
        float yaw = pylons[i].w;
        float s = sin(yaw);
        float c = cos(yaw);
        vec3 lo = rot_z(ro - pylons[i].xyz, s, c);
        vec3 ld = rot_z(rd, s, c);
        float lt = pylon_trace_local(i, lo, ld, sh.x, sh.y, sh.z, b.x, b.y, b.z, t);
        if (lt < 0.0) continue;
        vec3 lp = lo + ld * lt;
        t = lt;
        n = unrot_z(pylon_normal_local(i, lp, sh.x, sh.y, sh.z), s, c);
        idx = i;
        local = lp;
        hit = true;
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Ore chunks
//
// Lumps knocked off a pylon, lying about waiting to be carried home. Drawn as
// analytic spheres with the grain field folded into the normal: at a third of a
// metre across the silhouette is a couple of pixels wide and what sells the
// rock is the shading, not the outline.
bool chunk_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out int idx) {
    bool hit = false;
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    idx = 0;
    for (int i = 0; i < NCHUNK; i++) {
        vec4 ch = chunks[i];
        if (ch.w < 0.01) continue;
        float et;
        vec3 en;
        if (intersect_sphere(ro, rd, ch.xyz, ch.w, 0.02, t, et, en)) {
            t = et; n = en; idx = i; hit = true;
        }
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Wisps (players)

// A wisp is a hooded robe with nothing inside it but light (robe_trace) and
// three motes orbiting it. Positions arrive pre-animated (bob applied on the
// CPU once per frame); `c` is the centre of the 1.72 m character.
vec3 wisp_center(vec4 w, float phase) {
    return w.xyz;
}

// Where the light comes from: the face inside the hood.
vec3 wisp_glow_center(vec4 w) {
    return w.xyz + vec3(0.0, 0.0, 0.52 * (0.82 + 0.18 * fract(w.w)));
}

// Death: a wisp that is killed swells where it fell, as though the light inside
// were filling the cloth, and then bursts into a flash the colour of its team.
// robe_fx[i].y is the seconds since it died (0 while it lives), timed on the CPU
// so every client sees the same swell and the same burst.
const float DEATH_SWELL_SEC = 0.40;   // how long the robe fills before it goes
const float DEATH_POP_SEC   = 0.12;   // how long the flash it bursts into lasts
const float DEATH_SWELL     = 1.8;    // how much bigger the robe is when it bursts
const float DEATH_GLOW      = 1.5;    // how much harder the light inside shines by then
const float DEATH_FLARE     = 4.0;    // how much harder the burst lights the stone than a living wisp

// How far the wisp has filled: 1 while it lives, easing out to DEATH_SWELL, so
// the swell is quick at first and slows as the cloth runs out.
float death_swell(float death_t) {
    if (death_t <= 0.0) return 1.0;
    float f = min(death_t / DEATH_SWELL_SEC, 1.0);
    return 1.0 + f * f * (DEATH_SWELL - 1.0);
}

// How much brighter the light inside is: 0 while the wisp lives, up to
// DEATH_GLOW just before it bursts.
float death_glow(float death_t) {
    if (death_t <= 0.0) return 0.0;
    float f = min(death_t / DEATH_SWELL_SEC, 1.0);
    return f * f * DEATH_GLOW;
}

// 0 -> 1 across the flash; below 0 while the robe is still filling, above 1 once
// the wisp is gone.
float death_pop_frac(float death_t) {
    return (death_t - DEATH_SWELL_SEC) / DEATH_POP_SEC;
}

// The body itself is gone from the moment it bursts.
bool death_burst(float death_t) {
    return death_t > DEATH_SWELL_SEC;
}

// How hard a wisp lights what is around it through its death: brighter as it
// fills, a flare as it bursts, and then out.
float death_light(float death_t) {
    float pop = death_pop_frac(death_t);
    if (pop <= 0.0) return 1.0 + death_glow(death_t);
    return DEATH_FLARE * max(1.0 - pop, 0.0);
}

// The motes only; the cloth and the face are the robe's. `swell` carries them out
// with the robe as it fills, so they are never swallowed by it.
bool wisp_hit_parts(vec3 ro, vec3 rd, vec3 c, float life, float swell, float tmin, float tmax, out float t, out vec3 n, out float part) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    part = 2.0;
    float scale = (0.82 + 0.18 * life) * swell;
    if (!bounds_hit(ro, rd, c, 0.55 * scale, tmax)) return false;

    bool hit = false;
    float best = tmax;
    float et;
    vec3 en;
    float a1 = WORLD_T * 2.55 + c.x * 3.1;
    float a2 = WORLD_T * 1.85 + c.y * 2.4;
    float a3 = WORLD_T * 3.15 + c.z * 1.7;
    vec3 m1 = c + vec3(cos(a1), sin(a1), 0.28 * sin(a1 * 1.35)) * (0.42 * scale);
    vec3 m2 = c + vec3(cos(a2 + 2.094), sin(a2 + 2.094), 0.22 * cos(a2 * 1.2)) * (0.36 * scale);
    vec3 m3 = c + vec3(cos(a3 + 4.188), sin(a3 + 4.188), 0.16 * sin(a3 * 0.9)) * (0.30 * scale);
    if (intersect_sphere(ro, rd, m1, 0.070 * scale, tmin, best, et, en)) { best = et; n = en; part = 2.0; hit = true; }
    if (intersect_sphere(ro, rd, m2, 0.055 * scale, tmin, best, et, en)) { best = et; n = en; part = 2.0; hit = true; }
    if (intersect_sphere(ro, rd, m3, 0.042 * scale, tmin, best, et, en)) { best = et; n = en; part = 2.0; hit = true; }
    t = best;
    return hit;
}

bool wisp_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out float team, out float hp, out float part) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    team = 0.0;
    hp = 1.0;
    part = 0.0;
    bool hit = false;
    for (int i = 0; i < 16; i++) {
        vec4 w = wisps[i];
        if (w.w < 0.5) continue;
        float death_t = robe_fx[i].y;
        // The motes go with the body when it bursts
        if (death_burst(death_t)) continue;
        float wteam = floor(w.w);
        float whp = fract(w.w);
        vec3 c = wisp_center(w, float(i) * 2.21);
        float wt, wp;
        vec3 wn;
        if (wisp_hit_parts(ro, rd, c, whp, death_swell(death_t), 0.04, t, wt, wn, wp)) {
            t = wt; n = wn; part = wp; team = wteam; hp = whp; hit = true;
        }
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Robes: every wisp is a hooded robe with nothing inside it but light.
//
// The body is two stacked open frusta, shoulder -> waist -> hem, so the profile
// bells out rather than tilting like a lampshade. The waist and hem ring
// centres are simulated on the CPU as a chain of pendulums (robe_waists[i].xyz,
// robes[i].xyz): motion reaches the waist first and the hem later, so the cloth
// bends and flows rather than tilting whole. The wall slopes are blended across
// the waist so the bend shades smoothly.
//
// The hood is an ellipsoid leaned back so its peak droops behind, draped over
// the shoulder ring, with an opening cut toward the front. Through it is the
// dark lining and, floating in the dark, the face: two eyes and a smile drawn
// as light on a disc, the only thing in there.
//
// The cross-section is an ellipse, narrower front-to-back like cloth on a body:
// the frusta are traced in a space stretched along the wearer's facing. The
// cloth is pleated into ridges that displace the surface, so the silhouette
// scallops; they are pinned to the body's yaw at the shoulder and to a lagging
// yaw at the hem, so a turn twists them, and ripples travel down them so the
// cloth is never still. The analytic frustum hit is bent onto the pleats with
// two Newton steps. The hem edge is cut by a travelling wave so it flutters.
// Two quadratics and a handful of refinements per wisp: no marching.

const float ROBE_SHOULDER_Z = 0.45;   // shoulder ring above the wisp centre, x scale
const float ROBE_R_SHOULDER = 0.24;   // side-to-side radii; front-to-back is x ROBE_DEPTH
const float ROBE_R_WAIST    = 0.37;
const float ROBE_R_HEM      = 0.55;
const float ROBE_DEPTH      = 0.82;
const float ROBE_WAIST_F    = 0.44;   // the waist ring's share of the drop (0.55 of 1.25 m)
const float ROBE_PLEATS     = 7.0;
const float ROBE_TMIN       = 0.04;

const vec3  HOOD_CENTER     = vec3(-0.03, 0.0, 0.58);   // body frame, x scale
const vec3  HOOD_RADII      = vec3(0.27, 0.30, 0.38);   // deep, wide, tall, in the leaned frame
const float HOOD_LEAN       = 0.38;                     // radians the peak leans back
const vec3  HOOD_OPEN_AXIS  = normalize(vec3(1.0, 0.0, -0.30));  // body frame: forward, a little down
const float HOOD_OPEN_COS   = 0.62;                     // half-angle ~52 degrees
const vec3  FACE_CENTER     = vec3(0.04, 0.0, 0.50);    // body frame, x scale; the disc faces forward

const float ROBE_PART_CLOTH = 0.0;
const float ROBE_PART_HOOD  = 1.0;
const float ROBE_PART_FACE  = 2.0;

// Into the space where the robe's cross-section is circular: stretched along
// the wearer's facing by 1 / ROBE_DEPTH about the wisp centre.
vec3 robe_space(vec3 p, vec3 c, vec3 fwd) {
    return p + fwd * (dot(p - c, fwd) * (1.0 / ROBE_DEPTH - 1.0));
}

// Body frame: x forward, y left, z up. Rotation only, so lengths are kept.
vec3 to_body(vec3 v, vec3 fwd) {
    return vec3(dot(v, fwd), dot(v, vec3(-fwd.y, fwd.x, 0.0)), v.z);
}
vec3 from_body(vec3 v, vec3 fwd) {
    return fwd * v.x + vec3(-fwd.y, fwd.x, 0.0) * v.y + vec3(0.0, 0.0, v.z);
}

// Hood frame: the body frame leaned back about the sideways axis, so the
// hood's tall axis runs up and behind.
vec3 to_hood(vec3 v) {
    float c = cos(HOOD_LEAN), s = sin(HOOD_LEAN);
    return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}
vec3 from_hood(vec3 v) {
    float c = cos(HOOD_LEAN), s = sin(HOOD_LEAN);
    return vec3(c * v.x - s * v.z, v.y, s * v.x + c * v.z);
}

// Both roots of a ray against an axis-aligned ellipsoid at the origin, near
// then far. A miss reports both as -1. NaN-free (see intersect_sphere).
vec2 ellipsoid_roots(vec3 o, vec3 d, vec3 rad) {
    vec3 oo = o / rad;
    vec3 dd = d / rad;
    float a = dot(dd, dd);
    float b = dot(oo, dd);
    float cc = dot(oo, oo) - 1.0;
    float h = b * b - a * cc;
    float s = sqrt(max(h, 0.0));
    float ia = 1.0 / max(a, 1e-8);
    return (h < 0.0) ? vec2(-1.0) : vec2((-b - s) * ia, (-b + s) * ia);
}

// The face as light on a forward-facing disc: two eyes and a smile, 0..1.
// uv is sideways, up from the face centre, in metres at full size.
float robe_face(vec2 uv) {
    // Happy eyes: narrow ellipses set a little apart, tilted up at the outer corners
    vec2 e = vec2(abs(uv.x) - 0.075, uv.y - 0.035 - abs(uv.x) * 0.25);
    float eye = 1.0 - smoothstep(0.80, 1.0, length(e / vec2(0.048, 0.030)));
    // Smile: an arc below, thicker at the middle
    vec2 m = uv - vec2(0.0, 0.02);
    float r = length(m);
    float below = smoothstep(0.30, 0.55, -m.y / max(r, 1e-4));
    float arc = 1.0 - smoothstep(0.012, 0.026, abs(r - 0.105));
    return max(eye, arc * below);
}

// Pleat depth as a fraction of radius: shallow at the shoulder where the cloth
// is pulled tight, deeper toward the hem where it hangs loose, and swelling in
// ripples that run down the cloth, faster when the wearer moves.
float robe_pleat_amp(float f, float flutter) {
    float ripple = 0.75 + 0.25 * sin(f * 7.0 - WORLD_T * (2.2 + 4.0 * flutter));
    return (0.012 + 0.045 * f) * ripple;
}

// Angle around the wearer and the pleat phase there: the pleats follow the
// body's yaw at the shoulder and the hem's lagging yaw at the bottom.
float robe_pleat_phase(vec3 p, vec3 c, float f, float yaw, float hem_yaw) {
    float around = atan(p.y - c.y, p.x - c.x);
    return (around - mix(yaw, hem_yaw, f)) * ROBE_PLEATS;
}

// Both roots of a ray against the open frustum from centre pa (radius ra) to
// centre pb (radius rb): t along the ray, y the axial fraction (0 at pa, 1 at
// pb; outside [0, 1] is off the finite surface). Roots are ordered near, far.
// NaN-free on all paths (see intersect_sphere): a miss reports y = -1.
void frustum_roots(vec3 ro, vec3 rd, vec3 pa, vec3 pb, float ra, float rb, out vec2 t, out vec2 y) {
    vec3 ba = pb - pa;
    vec3 oa = ro - pa;
    float m0 = dot(ba, ba);
    float m1 = dot(oa, ba);
    float m2 = dot(rd, ba);
    float m3 = dot(rd, oa);
    float m5 = dot(oa, oa);
    float rr = ra - rb;
    float hy = m0 + rr * rr;
    float k2 = m0 * m0 - m2 * m2 * hy;
    float k1 = m0 * m0 * m3 - m1 * m2 * hy + m0 * ra * rr * m2;
    float k0 = m0 * m0 * m5 - m1 * m1 * hy + m0 * ra * (rr * m1 * 2.0 - m0 * ra);
    float h = k1 * k1 - k2 * k0;
    float s = sqrt(max(h, 0.0));
    // A ray running along a generatrix makes the quadratic linear; nudge it
    // rather than divide by zero. Sign-preserving so the roots keep their order.
    if (abs(k2) < 1e-7) k2 = (k2 < 0.0) ? -1e-7 : 1e-7;
    float ik2 = 1.0 / k2;
    float t0 = (-k1 - s) * ik2;
    float t1 = (-k1 + s) * ik2;
    t = vec2(min(t0, t1), max(t0, t1));
    y = (h < 0.0) ? vec2(-1.0) : (m1 + t * m2) / max(m0, 1e-6);
}

// Outward normal of a frustum wall at p: the radial direction tipped along the
// axis by `slope`, the wall's change of radius per unit length. Passing a slope
// blended between neighbouring frusta shades their junction as one bend.
vec3 frustum_normal(vec3 p, vec3 pa, vec3 pb, float slope) {
    vec3 ba = pb - pa;
    vec3 axis = ba * inversesqrt(max(dot(ba, ba), 1e-8));
    vec3 q = p - pa;
    vec3 radial = q - axis * dot(q, axis);
    radial *= inversesqrt(max(dot(radial, radial), 1e-8));
    return normalize(radial - axis * slope);
}

float frustum_slope(vec3 pa, vec3 pb, float ra, float rb) {
    return (rb - ra) * inversesqrt(max(dot(pb - pa, pb - pa), 1e-8));
}

// How far up from the hem the flutter wave has cut the cloth at this angle
// around the hem, as a fraction of the lower frustum's drop. The wave is
// anchored to the cloth's own yaw and runs faster and deeper the faster the
// wearer moves.
float robe_hem_cut(float around, float hem_yaw, float flutter) {
    float phase = around * 3.0 - hem_yaw;
    float wave = 0.5 + 0.5 * sin(phase + WORLD_T * (2.5 + 7.0 * flutter));
    wave += 0.35 * sin(around * 5.0 + hem_yaw * 2.0 - WORLD_T * (3.7 + 5.0 * flutter));
    return 1.0 - (0.04 + 0.16 * flutter) * clamp(wave, 0.0, 1.0);
}

// Signed distance of p from the pleated cloth of one segment, measured radially
// (positive outside). Also reports where along the segment p sits.
float robe_cloth(vec3 p, vec3 pa, vec3 ba, float m0, float ra, float rb, float f0, float f1,
                 vec3 c, float yaw, float hem_yaw, float flutter) {
    vec3 q = p - pa;
    float yk = dot(q, ba) / m0;
    vec3 radial = q - ba * yk;
    float f = mix(f0, f1, yk);
    float r = mix(ra, rb, yk) * (1.0 + robe_pleat_amp(f, flutter) * sin(robe_pleat_phase(p, c, f, yaw, hem_yaw)));
    return length(radial) - r;
}

// Nearest hit on one open frustum of the robe, bent onto the pleats. Works in
// robe space (see robe_space); `t` is in that space's ray parameter. f0..f1 is
// the span of the shoulder-to-hem fraction this segment covers, slope_a/b the
// wall slopes to shade with at each end. The hem segment is cut by the flutter
// wave, and `f` is stretched so 1 lands on the cut edge.
bool robe_segment(vec3 ro, vec3 rd, vec3 pa, vec3 pb, float ra, float rb, float f0, float f1,
                  float slope_a, float slope_b, vec3 c, float yaw, float hem_yaw, float flutter,
                  bool is_hem, inout float t, inout vec3 n, inout float f) {
    vec3 ba = pb - pa;
    float m0 = max(dot(ba, ba), 1e-6);
    vec2 tt, yy;
    frustum_roots(ro, rd, pa, pb, ra, rb, tt, yy);
    bool hit = false;
    for (int k = 0; k < 2; k++) {
        float tk = (k == 0) ? tt.x : tt.y;
        float yk = (k == 0) ? yy.x : yy.y;
        // Slack on the span: the pleats move the surface a little either way
        if (yk < -0.06 || yk > 1.06 || tk < ROBE_TMIN || tk >= t) continue;
        // Two Newton steps from the smooth frustum onto the pleated cloth. A
        // grazing ray has no usable slope; it keeps the smooth hit.
        for (int it = 0; it < 2; it++) {
            float d0 = robe_cloth(ro + rd * tk, pa, ba, m0, ra, rb, f0, f1, c, yaw, hem_yaw, flutter);
            float d1 = robe_cloth(ro + rd * (tk + 0.01), pa, ba, m0, ra, rb, f0, f1, c, yaw, hem_yaw, flutter);
            float dd = (d1 - d0) * 100.0;
            tk += (abs(dd) > 0.15) ? clamp(-d0 / dd, -0.06, 0.06) : 0.0;
        }
        vec3 p = ro + rd * tk;
        yk = dot(p - pa, ba) / m0;
        if (yk < 0.0 || yk > 1.0 || tk < ROBE_TMIN || tk >= t) continue;
        float span = 1.0;
        if (is_hem) {
            vec2 rel = p.xy - pb.xy;
            span = robe_hem_cut(atan(rel.y, rel.x), hem_yaw, flutter);
            // Cut away below the wave; a notch shows the lining of the far wall.
            if (yk > span) continue;
        }
        t = tk;
        n = frustum_normal(p, pa, pb, mix(slope_a, slope_b, yk));
        f = mix(f0, f1, yk / span);
        hit = true;
    }
    return hit;
}

// The hood and the face inside it, in the body frame (origin at the wisp
// centre, x forward). `aux` is how close to the opening's rim a hood hit is
// (the cosine to the opening axis) or the brightness of the face pattern.
bool hood_trace(vec3 bro, vec3 brd, float scale, inout float t, inout vec3 bn, inout float part, inout float aux) {
    bool hit = false;
    vec3 hc = HOOD_CENTER * scale;
    vec3 hrad = HOOD_RADII * scale;
    vec3 hro = to_hood(bro - hc);
    vec3 hrd = to_hood(brd);
    vec2 tt = ellipsoid_roots(hro, hrd, hrad);
    for (int k = 0; k < 2; k++) {
        float tk = (k == 0) ? tt.x : tt.y;
        if (tk < ROBE_TMIN || tk >= t) continue;
        vec3 p = hro + hrd * tk;
        // The opening: a cone from the hood's centre toward the front. What it
        // cuts from the near wall leaves the far wall's lining to be seen.
        float open = dot(from_hood(p * inversesqrt(max(dot(p, p), 1e-8))), HOOD_OPEN_AXIS);
        if (open > HOOD_OPEN_COS) continue;
        t = tk;
        vec3 g = p / (hrad * hrad);
        bn = from_hood(g * inversesqrt(max(dot(g, g), 1e-12)));
        part = ROBE_PART_HOOD;
        aux = open;
        hit = true;
    }
    // The face: light on a disc facing forward inside the hood. Where the
    // pattern is dark the ray passes through.
    vec3 fc = FACE_CENTER * scale;
    if (abs(brd.x) > 1e-4) {
        float tf = (fc.x - bro.x) / brd.x;
        if (tf > ROBE_TMIN && tf < t) {
            vec3 q = bro + brd * tf;
            float face = robe_face((q.yz - fc.yz) / scale);
            if (face > 0.02) {
                t = tf;
                bn = vec3(1.0, 0.0, 0.0);
                part = ROBE_PART_FACE;
                aux = face;
                hit = true;
            }
        }
    }
    return hit;
}

// Nearest robe surface along the ray. For cloth, `aux` runs 0 at the shoulder
// ring to 1 at the (fluttering) hem edge, for the shading pass to place seams
// and pleats; see hood_trace for the hood and face.
bool robe_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out int idx, out float part, out float aux) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    idx = 0;
    part = ROBE_PART_CLOTH;
    aux = 0.0;
    bool hit = false;
    for (int i = 0; i < 16; i++) {
        vec4 w = wisps[i];
        if (w.w < 0.5) continue;
        float scale = 0.82 + 0.18 * fract(w.w);
        vec3 c = w.xyz;

        // A dying wisp fills out until it bursts, and then there is no robe left
        // to draw until it respawns.
        float death_t = robe_fx[i].y;
        if (death_burst(death_t)) continue;
        float swell = death_swell(death_t);

        // Hood peak to a hem trailing its full reach, x scale
        if (!bounds_hit(ro, rd, c, 1.3 * scale * swell, t)) continue;

        float yaw = robes[i].w;
        vec3 fwd = vec3(cos(yaw), sin(yaw), 0.0);

        vec3 bn = vec3(0.0, 0.0, 1.0);
        float bpart = ROBE_PART_CLOTH;
        float baux = 0.0;
        if (hood_trace(to_body(ro - c, fwd), to_body(rd, fwd), scale * swell, t, bn, bpart, baux)) {
            n = from_body(bn, fwd);
            idx = i;
            part = bpart;
            aux = baux;
            hit = true;
        }
        // Trace in the space where the cross-section is round; the ray is no
        // longer unit length there, so parameters convert by its length.
        vec3 sro = robe_space(ro, c, fwd);
        vec3 srd = rd + fwd * (dot(rd, fwd) * (1.0 / ROBE_DEPTH - 1.0));
        float slen = length(srd);
        srd /= slen;

        vec3 shoulder = c + vec3(0.0, 0.0, ROBE_SHOULDER_Z * scale);
        vec3 waist = robe_space(robe_waists[i].xyz, c, fwd);
        vec3 hem = robe_space(robes[i].xyz, c, fwd);
        float r_sh = ROBE_R_SHOULDER * scale * swell;
        float r_wa = ROBE_R_WAIST * scale * swell;
        float r_he = ROBE_R_HEM * scale * swell;
        float hem_yaw = robe_waists[i].w;
        float flutter = robe_fx[i].x;
        // The two walls meet at the waist with the mean of their slopes
        float slope_up = frustum_slope(shoulder, waist, r_sh, r_wa);
        float slope_lo = frustum_slope(waist, hem, r_wa, r_he);
        float slope_mid = 0.5 * (slope_up + slope_lo);

        float st = t * slen;
        vec3 sn = n;
        float sf = 0.0;
        bool seg = robe_segment(sro, srd, shoulder, waist, r_sh, r_wa, 0.0, ROBE_WAIST_F,
                                slope_up, slope_mid, c, yaw, hem_yaw, flutter, false, st, sn, sf);
        seg = robe_segment(sro, srd, waist, hem, r_wa, r_he, ROBE_WAIST_F, 1.0,
                           slope_mid, slope_lo, c, yaw, hem_yaw, flutter, true, st, sn, sf) || seg;
        if (!seg) continue;
        t = st / slen;
        // Normals come back through the inverse transpose of the stretch
        n = normalize(sn + fwd * (dot(sn, fwd) * (ROBE_DEPTH - 1.0)));
        idx = i;
        part = ROBE_PART_CLOTH;
        aux = sf;
        hit = true;
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Cast orbs: the spell in a wisp's hand
//
// Every wisp winding a spell up holds an orb out along its aim, and the orb is
// the whole telegraph: its colour names the spell, its size and its heat say
// how far the wind-up has come, and where it points is where the spell is
// going. That is what makes a cast answerable -- an opponent who can read
// "heavy orb, nearly full, pointed at me" has time to break line of sight,
// and one who cannot is only guessing.
//
// The shapes are the spell's own, so the orb rehearses what is about to
// happen: a lance tapers to a point along the aim, an orb swells round and
// heavy, a bolt gathers a column toward the sky it falls out of. Held beams
// keep an orb too, at full charge, and pour out of it.

// How big the orb is: per spell at full charge, scaled back while it fills. The
// floor is high enough that a wind-up is a thing in a hand from the first
// frame -- an orb that starts as a speck is a tell nobody reads in time -- and
// the growth from there is what says how much of it is left.
float cast_orb_radius(float code, float charge) {
    float base = 0.150;                     // friendly heal
    if (code < 1.5)      base = 0.105;      // missile: small and quick
    else if (code < 2.5) base = 0.215;      // orb: heavy enough to be read at range
    else if (code < 3.5) base = 0.115;      // blink
    else if (code < 4.5) base = 0.125;      // frost lance: the head of the spear
    else if (code < 5.5) base = 0.155;      // call lightning
    else if (code < 6.5) base = 0.130;      // thunderbolt
    return base * (0.60 + 0.40 * charge);
}

bool cast_orb_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out float code, out float charge) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    code = 0.0;
    charge = 0.0;
    bool hit = false;
    for (int i = 0; i < 16; i++) {
        vec4 cs = wisp_cast[i];
        if (cs.w < 0.5) continue;
        float ch = wisp_aim[i].w;
        vec3 aim = wisp_aim[i].xyz;
        float r = cast_orb_radius(cs.w, ch);
        // Bounds cover the orb and the spike a lance grows ahead of it
        if (!bounds_hit(ro, rd, cs.xyz + aim * (r * 2.0), r * 4.0, t)) continue;
        float et;
        vec3 en;
        if (intersect_sphere(ro, rd, cs.xyz, r, 0.04, t, et, en)) {
            t = et; n = en; code = cs.w; charge = ch; hit = true;
        }
        // Frost lance: the charge tapers along the aim into the shape it is
        // about to fly as, the same stack of shrinking spheres the projectile
        // itself is drawn from.
        if (cs.w > 3.5 && cs.w < 4.5) {
            for (int k = 1; k < 4; k++) {
                vec3 c = cs.xyz + aim * (r * 1.35 * float(k)) * (0.4 + 0.6 * ch);
                if (intersect_sphere(ro, rd, c, r * (0.80 - 0.20 * float(k)), 0.04, t, et, en)) {
                    t = et; n = en; code = cs.w; charge = ch; hit = true;
                }
            }
        }
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Projectiles

bool projectile_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out float type) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    type = 0.0;
    bool hit = false;
    for (int i = 0; i < 12; i++) {
        vec4 p = projectiles[i];
        if (p.w < 0.5) continue;
        float ptype = floor(p.w);
        float radius = fract(p.w);
        float pt;
        vec3 pn;
        if (ptype > 1.5 && ptype < 2.5) {
            // Orb: pulsing sphere
            radius *= 1.0 + 0.08 * sin(WORLD_T * 9.0 + p.x);
            if (intersect_sphere(ro, rd, p.xyz, radius, 0.04, t, pt, pn)) {
                t = pt; n = pn; type = ptype; hit = true;
            }
        } else if (ptype > 3.5) {
            // Frost lance: spear head with a tapering shaft behind it.
            vec3 dir = normalize(proj_vel[i].xyz + vec3(1e-4));
            if (!bounds_hit(ro, rd, p.xyz - dir * 0.6, 1.1, t)) continue;
            if (intersect_sphere(ro, rd, p.xyz, radius, 0.04, t, pt, pn)) {
                t = pt; n = pn; type = ptype; hit = true;
            }
            for (int k = 1; k < 4; k++) {
                vec3 c = p.xyz - dir * (radius * 1.5 * float(k));
                if (intersect_sphere(ro, rd, c, radius * (0.78 - 0.16 * float(k)), 0.04, t, pt, pn)) {
                    t = pt; n = pn; type = ptype; hit = true;
                }
            }
        } else {
            // Streaks elongated along velocity: approximate with sphere + small trailing sphere
            vec3 v = proj_vel[i].xyz;
            float sp = max(length(v), 1.0);
            vec3 dir = v / sp;
            if (intersect_sphere(ro, rd, p.xyz, radius, 0.04, t, pt, pn)) {
                t = pt; n = pn; type = ptype; hit = true;
            }
            if (intersect_sphere(ro, rd, p.xyz - dir * radius * 1.4, radius * 0.7, 0.04, t, pt, pn)) {
                t = pt; n = pn; type = ptype; hit = true;
            }
        }
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Lighting

vec3 point_light(vec3 p, vec3 n, vec3 lp, vec3 col, float intensity, float range) {
    vec3 l = lp - p;
    float d2 = dot(l, l);
    float r2 = range * range;
    if (d2 > r2) return vec3(0.0);
    float window = 1.0 - d2 / r2;
    window *= window;
    float att = intensity / (1.0 + d2 * 0.9);
    float nd = max(dot(n, l * inversesqrt(max(d2, 1e-6))), 0.0);
    return col * att * window * (0.18 + 0.82 * nd);
}

vec3 sky_color(vec3 rd) {
    float h = clamp(rd.z, -1.0, 1.0);
    vec3 horizon = vec3(0.085, 0.075, 0.140);
    vec3 zenith = vec3(0.010, 0.012, 0.030);
    vec3 col = mix(horizon, zenith, pow(max(h, 0.0), 0.5));
    // faint nebula band
    float band = exp(-abs(rd.y * 0.75 + rd.z * 0.6 - 0.12) * 5.0) * 0.06;
    col += vec3(0.30, 0.18, 0.45) * band * max(h, 0.0);
    // stars
    if (h > 0.02) {
        vec3 sd = rd * 240.0;
        vec3 cell = floor(sd);
        float hs = hash13(cell);
        if (hs > 0.992) {
            vec3 f = fract(sd) - 0.5;
            float star = 1.0 - smoothstep(0.0, 0.18, length(f));
            float tw = 0.7 + 0.3 * sin(WORLD_T * (2.0 + hs * 4.0) + hs * 40.0);
            col += vec3(0.9, 0.92, 1.0) * star * tw * smoothstep(0.02, 0.2, h) * 1.4;
        }
    }
    // moon
    float md = dot(rd, MOON_DIR);
    col += vec3(0.95, 0.95, 1.0) * smoothstep(0.9993, 0.9998, md) * 2.2;
    col += vec3(0.30, 0.32, 0.42) * pow(max(md, 0.0), 24.0) * 0.25;
    return col;
}

// Lane region: which team's corridor is this point in, and how strongly
float lane_team(vec3 p, out float strength) {
    float r = length(p.xy);
    float ang = atan(p.y, p.x);
    float best = 1.0;
    float best_diff = 10.0;
    for (int i = 0; i < 3; i++) {
        float ta = 1.5707963 + float(i) * 2.0943951;
        float d = abs(mod(ang - ta + 3.14159265, 6.28318530) - 3.14159265);
        if (d < best_diff) { best_diff = d; best = float(i + 1); }
    }
    strength = smoothstep(12.0, 22.0, r);
    return best;
}

// ---------------------------------------------------------------------------

void main() {
    vec3 ro = ray_origin;
    vec3 rd = normalize(ray_dir);

    float hit_t;
    vec3 hit_n;
    int mat;
    world_trace(ro, rd, hit_t, hit_n, mat);
    float best = hit_t;

    float st;
    vec3 sn;
    if (solid_trace(ro, rd, best, st, sn)) {
        best = st; hit_n = sn; mat = MAT_SOLID;
    }

    int py_idx = 0;
    vec3 py_local = vec3(0.0);
    float pyt;
    vec3 pyn;
    if (pylon_trace(ro, rd, best, pyt, pyn, py_idx, py_local)) {
        best = pyt; hit_n = pyn; mat = MAT_PYLON;
    }

    int ch_idx = 0;
    float cht;
    vec3 chn;
    if (chunk_trace(ro, rd, best, cht, chn, ch_idx)) {
        best = cht; hit_n = chn; mat = MAT_CHUNK;
    }

    float wisp_team = 0.0, wisp_hp = 1.0, wisp_part = 0.0;
    float wt;
    vec3 wn;
    if (wisp_trace(ro, rd, best, wt, wn, wisp_team, wisp_hp, wisp_part)) {
        best = wt; hit_n = wn; mat = MAT_WISP;
    }

    int robe_idx = 0;
    float robe_part = 0.0, robe_aux = 0.0;
    float rt;
    vec3 rn;
    if (robe_trace(ro, rd, best, rt, rn, robe_idx, robe_part, robe_aux)) {
        best = rt; hit_n = rn; mat = MAT_ROBE;
    }

    float proj_type = 0.0;
    float pt;
    vec3 pn;
    if (projectile_trace(ro, rd, best, pt, pn, proj_type)) {
        best = pt; hit_n = pn; mat = MAT_PROJ;
    }

    float cast_code = 0.0, cast_charge = 0.0;
    float cot;
    vec3 con;
    if (cast_orb_trace(ro, rd, best, cot, con, cast_code, cast_charge)) {
        best = cot; hit_n = con; mat = MAT_CAST_ORB;
    }

    // Hand orb (first person focus)
    if (hand_pos.w > 0.001) {
        float ht;
        vec3 hn;
        if (intersect_sphere(ro, rd, hand_pos.xyz, 0.028 * hand_pos.w, 0.02, best, ht, hn)) {
            best = ht; hit_n = hn; mat = MAT_HAND;
        }
    }

    hit_t = best;
    vec3 hp = ro + rd * hit_t;
    // Surfaces are two-sided; remember which side we are on for the robe lining.
    float backface = (dot(hit_n, rd) > 0.0) ? 1.0 : 0.0;
    if (backface > 0.5) hit_n = -hit_n;

    float glow_tmax = (mat == MAT_SKY) ? 400.0 : hit_t;

    // --- Volumetric-ish glows (wisps, projectiles, impacts, ore) -------------
    vec3 aura = vec3(0.0);
    for (int i = 0; i < 16; i++) {
        vec4 w = wisps[i];
        if (w.w < 0.5) continue;
        float team = floor(w.w);
        float hpv = fract(w.w);

        // The burst: the light that was inside thrown wide and out in a tenth of
        // a second, blooming from the point the face was lighting a moment ago so
        // the one reads as becoming the other.
        float death_t = robe_fx[i].y;
        float pop = death_pop_frac(death_t);
        if (pop > 0.0 && pop < 1.0) {
            float fade = 1.0 - pop;
            float flash = corona(ro, rd, glow_tmax, wisp_glow_center(w), 0.8 + 1.2 * pop) * fade * fade;
            aura += team_tint(team) * flash * 3.5;
            aura += vec3(1.0) * flash * fade * 1.2;
        }
        if (death_burst(death_t)) continue;

        // The face lights the air around the hood, wider and harder as a dying
        // wisp fills out
        vec3 c = wisp_glow_center(w);
        float g = corona(ro, rd, glow_tmax, c, (0.55 + 0.15 * hpv) * death_swell(death_t)) * (0.5 + 0.5 * hpv);
        aura += team_tint(team) * g * (0.55 + 0.2 * sin(WORLD_T * 3.4 + float(i))) * (1.0 + death_glow(death_t));
        aura += team_core(team) * g * 0.18;
    }
    // Cast orbs: the spell's light gathering in the hand, and the tell that
    // says where it is pointed. Each tell is shaped like what the spell will
    // do -- a missile's stutters, an orb's droops the way it will be lobbed, a
    // lance's runs dead straight and far, a bolt's climbs to the sky -- so the
    // spell is readable before the colour is, at any range the glow carries.
    for (int i = 0; i < 16; i++) {
        vec4 cs = wisp_cast[i];
        if (cs.w < 0.5) continue;
        float code = cs.w;
        float charge = wisp_aim[i].w;
        vec3 orb = cs.xyz;
        vec3 aim = wisp_aim[i].xyz;
        vec3 tint = spell_tint(code);
        float r = cast_orb_radius(code, charge);
        float t = WORLD_T + float(i) * 2.1;
        // How far along the aim the tell reaches, and how far the halo throws
        float reach = 0.6 + 2.4 * charge;
        float halo = corona(ro, rd, glow_tmax, orb, r * 3.2 + charge * 0.22);
        aura += tint * halo * (0.7 + 1.5 * charge);
        // The last quarter of a wind-up runs white, so the moment before a
        // release is unmistakable even when the colour has washed out. A held
        // beam never gets it: it would be on for the whole beam and would cost
        // the orb the colour that says which beam it is.
        if (!spell_is_held(code)) {
            aura += vec3(1.0) * halo * smoothstep(0.70, 1.0, charge) * 0.9;
        }

        if (code < 1.5) {
            // Arcane Missile: a short dart, re-lit fourteen times a second
            float flicker = 0.55 + 0.45 * step(0.5, fract(t * 14.0));
            aura += tint * segment_glow(ro, rd, glow_tmax, orb, orb + aim * (reach * 0.55), r * 0.9) * charge * flicker * 1.3;
        } else if (code < 2.5) {
            // Arcane Orb: the lob it will fly, sagging under its own weight,
            // and a slow heavy swell around the orb itself
            vec3 prev = orb;
            for (int k = 1; k <= 3; k++) {
                float f = float(k) / 3.0;
                vec3 node = orb + aim * (reach * f) - vec3(0.0, 0.0, reach * f * f * 0.55);
                aura += tint * segment_glow(ro, rd, glow_tmax, prev, node, r * 1.1) * charge * 0.7;
                prev = node;
            }
            aura += tint * corona(ro, rd, glow_tmax, orb, r * (4.2 + 1.4 * sin(t * 3.2))) * charge * 0.45;
        } else if (code < 3.5) {
            // Blink: nothing thrown and nowhere aimed, just a flash winding up
            aura += vec3(1.0) * halo * charge * 1.2;
        } else if (code < 4.5) {
            // Frost Lance: dead straight and the longest reach on the bar,
            // with the air shivering along it
            float shimmer = 0.75 + 0.25 * sin(t * 11.0) * sin(t * 7.3);
            aura += tint * segment_glow(ro, rd, glow_tmax, orb, orb + aim * (reach * 1.5), r * 0.75) * charge * shimmer * 1.5;
        } else if (code < 5.5) {
            // Call Lightning: a column reaching for the sky the bolt comes out
            // of, crackling as it fills, plus the line that says whose head it
            // is going to land on
            vec3 top = orb + vec3(0.0, 0.0, 1.6 + 6.0 * charge);
            float crackle = 0.6 + 0.4 * step(0.5, fract(t * 9.0 + hash13(orb) * 10.0));
            aura += tint * segment_glow(ro, rd, glow_tmax, orb, top, 0.11 + 0.10 * charge) * charge * crackle * 1.1;
            aura += tint * segment_glow(ro, rd, glow_tmax, orb, orb + aim * reach, r * 0.6) * charge * 0.55;
        } else if (code < 6.5) {
            // Thunderbolt: no wind-up to show, so the orb simply crackles for
            // as long as the beam pouring out of it is lit
            float crackle = 0.7 + 0.3 * sin(t * 18.0) * sin(t * 13.0);
            aura += tint * halo * charge * crackle * 0.9;
        } else {
            // Friendly Heal: the only orb that promises nobody harm, so it
            // breathes instead of crackling
            float breathe = 0.65 + 0.35 * sin(t * 5.0);
            aura += tint * corona(ro, rd, glow_tmax, orb, r * 4.2) * charge * breathe * 0.6;
        }
    }
    for (int i = 0; i < 12; i++) {
        vec4 p = projectiles[i];
        if (p.w < 0.5) continue;
        float ptype = floor(p.w);
        float radius = fract(p.w);
        vec3 tint = spell_tint(ptype);
        aura += tint * corona(ro, rd, glow_tmax, p.xyz, radius * 3.0) * 0.9;
        vec3 v = proj_vel[i].xyz;
        float trail_len = (ptype > 1.5 && ptype < 2.5) ? 0.5 : ((ptype > 3.5) ? 2.6 : 1.8);
        vec3 tail = p.xyz - normalize(v + vec3(1e-4)) * trail_len;
        aura += tint * segment_glow(ro, rd, glow_tmax, tail, p.xyz, radius * 1.6) * 0.55;
    }
    for (int i = 0; i < 8; i++) {
        vec4 im = impacts[i];
        if (im.w < 0.5) continue;
        float itype = floor(im.w);
        float age = fract(im.w);
        float grow = 1.0 - age;
        // Blast size tracks the spell's splash radius.
        float rad = 0.25 + 0.9 * grow;
        if (itype > 1.5 && itype < 2.5)      rad = 0.8 + 5.4 * grow;   // orb
        else if (itype < 1.5)                rad = 0.35 + 2.0 * grow;  // missile pop
        else if (itype > 4.5 && itype < 5.5) rad = 0.6 + 2.6 * grow;   // lightning ground flash
        vec3 tint = spell_tint(itype);
        float g = corona(ro, rd, glow_tmax, im.xyz, rad) * age * age;
        aura += tint * g * 1.6;
        aura += vec3(1.0) * g * age * 0.6;
    }
    if (hand_pos.w > 0.001) {
        vec3 ht = mix(hand_core(), hand_tint(), 0.5);
        aura += ht * corona(ro, rd, glow_tmax, hand_pos.xyz, 0.06 * hand_pos.w) * (0.35 + 0.9 * fx.w + 0.35 * hand_cast.y);
    }
    // Pylons: the ore inside lights the air around a standing tower, dimming as
    // the tower is eaten away, so how far a fight has got is visible from the
    // far end of a lane through smoke and glare.
    for (int i = 0; i < NPYLON; i++) {
        float standing = pylon_bound[i].w;
        if (standing <= 0.002) continue;
        vec3 tint = ore_tint(pylon_shape[i].w);
        float h = pylon_shape[i].x * standing;
        vec3 c = pylons[i].xyz + vec3(0.0, 0.0, h * 0.55);
        float pulse = 0.80 + 0.20 * sin(WORLD_T * 1.7 + float(i));
        aura += tint * corona(ro, rd, glow_tmax, c, pylon_shape[i].y * 1.2) * 0.22 * standing * pulse;
    }
    // Loose ore glints where it fell, which is the whole reason to look at the
    // floor in this mode.
    for (int i = 0; i < NCHUNK; i++) {
        if (chunks[i].w < 0.01) continue;
        vec3 tint = ore_tint(chunk_fx[i].x);
        float twinkle = 0.7 + 0.3 * sin(WORLD_T * 3.0 + chunk_fx[i].y * 6.283);
        aura += tint * corona(ro, rd, glow_tmax, chunks[i].xyz, chunks[i].w * 2.4) * 0.5 * twinkle;
    }

    aura += target_mark_glow(ro, rd, glow_tmax, target_mark.xyz, target_mark.w);

    // --- Lightning: a jagged bolt from well above the walls onto the target ---
    for (int i = 0; i < 4; i++) {
        vec4 L = lightning[i];
        if (L.w < 0.005) continue;
        float life = L.w;                             // 1 fresh -> 0 gone
        float spike = smoothstep(0.8, 1.0, life);     // the first ~90 ms
        float glow = life * life * 1.6 + spike * 2.4;
        vec3 ground = L.xyz;
        vec3 top = ground + vec3(0.0, 0.0, 40.0);
        // The path re-rolls a few times a second so the bolt crackles rather
        // than standing still while it fades.
        float roll = floor(WORLD_T * 22.0) + float(i) * 17.0;
        vec3 core = vec3(0.96, 0.98, 1.00);
        vec3 tint = vec3(0.55, 0.78, 1.00);
        vec3 prev = top;
        for (int k = 1; k <= 6; k++) {
            float f = float(k) / 6.0;
            vec3 node = mix(top, ground, f);
            if (k < 6) {
                float amp = 0.15 + 0.9 * sin(f * 3.14159);
                node.x += (hash13(vec3(roll, float(k), L.x)) - 0.5) * 2.0 * amp;
                node.y += (hash13(vec3(roll, float(k) + 7.0, L.y)) - 0.5) * 2.0 * amp;
            }
            // segment_glow brightens toward its second point: the impact end.
            aura += core * segment_glow(ro, rd, glow_tmax, prev, node, 0.16) * glow;
            if (k == 3) {
                // One side branch peeling off toward the ground.
                vec3 tip = node + vec3((hash13(vec3(roll, 31.0, L.x)) - 0.5) * 7.0,
                                       (hash13(vec3(roll, 37.0, L.y)) - 0.5) * 7.0, -5.0);
                aura += core * segment_glow(ro, rd, glow_tmax, node, tip, 0.08) * glow * 0.5;
            }
            prev = node;
        }
        // Wide soft halo down the whole column, and the sky blinks with a
        // fresh bolt no matter where the player is looking.
        aura += tint * segment_glow(ro, rd, glow_tmax, top, ground, 1.1) * glow * 0.35;
        aura += tint * spike * 0.05;
    }

    // --- Beams: a held arc from the caster to whatever it lands on ---
    for (int i = 0; i < 4; i++) {
        vec4 B = beams[i];
        if (B.w < 0.5) continue;
        vec3 core = beam_core(B.w);
        vec4 E = beam_ends[i];
        aura += core * arc_glow(ro, rd, glow_tmax, B.xyz, E.xyz, 0.07, 0.35, float(i));
        // The far end burns: hotter and wider on flesh than on stone.
        float flare = 0.10 + 0.10 * E.w + 0.03 * sin(WORLD_T * 47.0 + float(i));
        vec3 to_end = E.xyz - ro;
        float t_end = clamp(dot(to_end, rd), 0.04, glow_tmax);
        float d_end = length(ro + rd * t_end - E.xyz);
        float end_glow = 1.0 - smoothstep(flare, flare * 6.0, d_end);
        aura += core * end_glow * end_glow * (1.6 + 1.2 * E.w);
        // Chains fork from the landing point to nearby bodies.
        for (int c = 0; c < 2; c++) {
            vec4 C = beam_chains[i * 2 + c];
            if (C.w < 0.5) continue;
            aura += core * arc_glow(ro, rd, glow_tmax, E.xyz, C.xyz, 0.04, 0.5, float(i) * 3.0 + float(c) + 1.0) * 0.7;
        }
    }

    // --- Sky ---------------------------------------------------------------
    if (mat == MAT_SKY) {
        vec3 col = sky_color(rd) + aura;
        col = 1.0 - exp(-col * 1.5);
        frag_color = vec4(col, 1.0);
        return;
    }

    // --- Surface shading ---------------------------------------------------
    vec3 sky_here = sky_color(vec3(rd.x, rd.y, 0.02));
    vec3 albedo = vec3(0.4);
    vec3 emissive = vec3(0.0);
    float spec_pow = 0.0;
    float spec_amt = 0.0;

    if (mat == MAT_FLOOR) {
        float r = length(hp.xy);
        float strength;
        float lt = lane_team(hp, strength);
        vec3 stone = vec3(0.36, 0.36, 0.40);
        vec3 tint = team_tint(lt);
        albedo = mix(stone, stone * 0.7 + tint * 0.34, strength * 0.7);
        // 2 m grid, fading with distance
        vec2 g = abs(fract(hp.xy * 0.5) - 0.5);
        float line = 1.0 - smoothstep(0.0, 0.025, min(g.x, g.y));
        float fade = 1.0 - smoothstep(12.0, 45.0, hit_t);
        albedo *= 1.0 - 0.35 * line * fade;
        // Plaza rings
        float ring = 1.0 - smoothstep(0.0, 0.18, abs(r - 12.0));
        ring += 1.0 - smoothstep(0.0, 0.12, abs(r - 5.0));
        emissive += vec3(0.55, 0.50, 0.80) * ring * 0.10 * fade;
        // Pylon aprons: a ring of ore dust the colour of what the tower is made
        // of, scuffed and darkened where the rock has been worked, and a bright
        // rim that says how much of the tower is still up.
        for (int i = 0; i < NPYLON; i++) {
            vec2 d = hp.xy - pylons[i].xy;
            float od = length(d);
            float radius = pylon_shape[i].y * 1.7;
            if (od < radius + 0.4) {
                vec3 otint = ore_tint(pylon_shape[i].w);
                float standing = pylon_bound[i].w;
                float disc = 1.0 - smoothstep(radius - 0.5, radius, od);
                // Dust from what has come off: heavier the more has been mined.
                float dust = disc * (0.25 + 0.55 * (1.0 - standing));
                albedo = mix(albedo, albedo * 0.5 + otint * 0.20, dust);
                float edge = 1.0 - smoothstep(0.0, 0.16, abs(od - radius));
                emissive += otint * edge * 0.30 * standing;
            }
        }
        spec_pow = 24.0;
        spec_amt = 0.10;
    } else if (mat == MAT_WALL) {
        float strength;
        float lt = lane_team(hp, strength);
        vec3 tint = team_tint(lt);
        albedo = vec3(0.30, 0.30, 0.35);
        // Horizontal courses
        float course = smoothstep(0.0, 0.04, abs(fract(hp.z * 0.8) - 0.5) - 0.46);
        albedo *= 0.85 + 0.15 * course;
        // Glowing trim band
        float band = 1.0 - smoothstep(0.0, 0.10, abs(hp.z - 2.3) - 0.06);
        band += (1.0 - smoothstep(0.0, 0.06, abs(hp.z - 0.35) - 0.03)) * 0.6;
        emissive += mix(vec3(0.55, 0.50, 0.85), tint, strength) * band * 0.55;
        spec_pow = 12.0;
        spec_amt = 0.06;
    } else if (mat == MAT_SOLID) {
        albedo = vec3(0.34, 0.31, 0.30);
        // darken near the floor for cheap contact shading
        albedo *= 0.75 + 0.25 * smoothstep(0.0, 0.5, hp.z);
        emissive += vec3(0.45, 0.42, 0.70) * (1.0 - smoothstep(0.0, 0.08, abs(fract(hp.z * 1.0 + 0.5) - 0.5) - 0.44)) * 0.12;
        spec_pow = 16.0;
        spec_amt = 0.08;
    } else if (mat == MAT_PYLON) {
        vec4 sh = pylon_shape[py_idx];
        float ore = sh.w;
        vec3 tint = ore_tint(ore);
        vec3 stone = ore_stone(ore);
        float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);

        // A face that has been mined is behind the original silhouette, and that
        // is the whole read of the mode: worked rock glows because the seams
        // inside it are open to the air, untouched rock is dull.
        float body = pylon_sdf_body(py_local, sh.x, sh.y, sh.z);
        float cut = 1.0 - smoothstep(PYLON_CUT_BODY, PYLON_CUT_BODY - 0.12, body);
        float vein = pylon_vein(py_local, sh.z);

        albedo = stone * (0.72 + 0.45 * pylon_grain(py_local, sh.y, sh.z));
        // Fresh breaks are pale where the rock has been powdered.
        albedo = mix(albedo, albedo * 0.7 + vec3(0.30, 0.29, 0.30), (1.0 - cut) * 0.45);
        // Seams run through the whole body, so a cut across one exposes it in
        // cross-section and it burns; on the skin only a hint shows through.
        emissive += tint * vein * (0.14 + 2.4 * (1.0 - cut));
        emissive += tint * pow(1.0 - ndv, 3.0) * 0.12;
        spec_pow = 18.0;
        spec_amt = 0.05 + 0.12 * (1.0 - cut);
    } else if (mat == MAT_CHUNK) {
        vec4 ch = chunks[ch_idx];
        float ore = chunk_fx[ch_idx].x;
        float seed = chunk_fx[ch_idx].y * 8.0;
        vec3 tint = ore_tint(ore);
        // Roughen the sphere: the grain field perturbed along the gradient reads
        // as a broken lump without costing a march.
        vec3 lp = (hp - ch.xyz) * (1.0 / max(ch.w, 0.01));
        float e = 0.35;
        vec3 gn = vec3(
            pylon_grain(lp + vec3(e, 0.0, 0.0), 1.0, seed) - pylon_grain(lp - vec3(e, 0.0, 0.0), 1.0, seed),
            pylon_grain(lp + vec3(0.0, e, 0.0), 1.0, seed) - pylon_grain(lp - vec3(0.0, e, 0.0), 1.0, seed),
            pylon_grain(lp + vec3(0.0, 0.0, e), 1.0, seed) - pylon_grain(lp - vec3(0.0, 0.0, e), 1.0, seed));
        hit_n = normalize(hit_n + gn * 1.4);
        float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
        albedo = ore_stone(ore) * (0.85 + 0.5 * pylon_grain(lp, 1.0, seed));
        // All of a chunk is broken surface, so the seams are open all over it.
        emissive += tint * (0.55 + 0.9 * pylon_vein(lp * 2.0, seed)) * (0.5 + 0.5 * ndv);
        spec_pow = 20.0;
        spec_amt = 0.10;
    } else if (mat == MAT_WISP) {
        // Motes: sparks of the team's light orbiting the robe
        vec3 tint = team_tint(wisp_team);
        vec3 core = team_core(wisp_team);
        float pulse = 0.62 + 0.38 * sin(WORLD_T * (3.1 + 6.0 * (1.0 - wisp_hp)));
        emissive = mix(core, tint, 0.18) * (1.15 + 0.55 * pulse) * (0.55 + 0.45 * wisp_hp);
        albedo = vec3(0.0);
    } else if (mat == MAT_PROJ) {
        vec3 tint = spell_tint(proj_type);
        float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
        float fres = pow(1.0 - ndv, 2.0);
        emissive = tint * (1.1 + 0.9 * fres) + vec3(1.0) * pow(ndv, 8.0) * 0.8;
        if (proj_type > 3.5) {
            // frost: crystalline facets
            emissive *= 0.8 + 0.3 * abs(sin(hp.x * 40.0 + hp.z * 33.0));
        }
        albedo = vec3(0.0);
    } else if (mat == MAT_CAST_ORB) {
        // The orb burns in the spell's own colour and goes white-hot at the
        // top of the wind-up: the last tell before the release.
        vec3 tint = spell_tint(cast_code);
        float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
        float fres = pow(1.0 - ndv, 2.0);
        float hot = smoothstep(0.65, 1.0, cast_charge);
        emissive = mix(tint, vec3(1.0), hot * 0.55) * (0.85 + 1.5 * cast_charge + 1.1 * fres);
        emissive += vec3(1.0) * pow(ndv, 8.0) * (0.5 + 1.1 * hot);
        albedo = vec3(0.0);
    } else if (mat == MAT_HAND) {
        vec3 tint = hand_tint();
        vec3 core = hand_core();
        float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
        float fres = pow(1.0 - ndv, 2.0);
        emissive = mix(core, tint, 0.5 + 0.5 * fres) * (0.9 + 1.6 * fx.w + 0.5 * hand_cast.y) + core * pow(ndv, 6.0) * 0.6;
        albedo = vec3(0.0);
    } else if (mat == MAT_ROBE) {
        vec4 w = wisps[robe_idx];
        float team = floor(w.w);
        float whp = fract(w.w);
        vec3 tint = team_tint(team);
        vec3 core = team_core(team);
        float pulse = 0.62 + 0.38 * sin(WORLD_T * (3.1 + 6.0 * (1.0 - whp)));
        // Heavy matte cloth in the team's hue
        vec3 cloth = mix(tint, vec3(0.40, 0.38, 0.50), 0.45) * 0.28;

        if (robe_part > 1.5) {
            // The face: light in the dark, a little brighter as it pulses
            emissive = (core * (2.0 + 0.5 * pulse) + tint * 0.6) * robe_aux * (0.6 + 0.4 * whp);
            albedo = vec3(0.0);
        } else if (robe_part > 0.5) {
            // The hood: smooth cloth outside, and inside a lining lit only by
            // the face, with the team's trim stitched around the opening.
            float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
            float fres = pow(1.0 - ndv, 3.0);
            albedo = cloth * (1.0 - 0.6 * backface);
            emissive = mix(tint, core, 0.3) * (0.025 * fres + backface * 0.10);
            float rim = smoothstep(HOOD_OPEN_COS - 0.10, HOOD_OPEN_COS - 0.03, robe_aux);
            emissive += tint * rim * (0.9 + 0.3 * sin(WORLD_T * 2.6 + float(robe_idx)));
            spec_pow = 3.0;
            spec_amt = 0.012;
        } else {
            // Pleats: the surface was displaced by amp * sin(phase) radially, so
            // the normal tilts around the body by the derivative, -amp * N *
            // cos(phase). Measured in robe space so the lighting lines up with
            // the silhouette.
            float f = robe_aux;
            float yaw = robes[robe_idx].w;
            vec3 fwd = vec3(cos(yaw), sin(yaw), 0.0);
            float phase = robe_pleat_phase(robe_space(hp, w.xyz, fwd), w.xyz, f, yaw, robe_waists[robe_idx].w);
            float ridge = cos(phase);
            vec3 tangent = cross(vec3(0.0, 0.0, 1.0), hit_n);
            tangent *= inversesqrt(max(dot(tangent, tangent), 1e-6));
            hit_n = normalize(hit_n - tangent * ridge * robe_pleat_amp(f, robe_fx[robe_idx].x) * ROBE_PLEATS);
            float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
            float fres = pow(1.0 - ndv, 3.0);
            // The folds between ridges sit deeper in shadow than the lighting
            // alone would put them.
            albedo = cloth * (0.80 + 0.20 * sin(phase));
            // The light inside reaches the lining, brightest up near the face;
            // the outside only catches the faintest rim of it.
            emissive = mix(tint, core, 0.3) * (0.025 * fres + backface * (0.35 - 0.25 * f));
            // An embroidered seam follows the fluttering hem edge and reads as
            // the team's colour from across a lane.
            float seam = smoothstep(0.90, 0.975, f);
            emissive += tint * seam * (0.9 + 0.3 * sin(WORLD_T * 2.6 + float(robe_idx)));
            spec_pow = 3.0;
            spec_amt = 0.012;
        }
        // Cloth, hood and face all glow harder as a dying wisp fills, so what
        // bursts reads as the light that was inside it all along.
        emissive += tint * death_glow(robe_fx[robe_idx].y);
    }

    vec3 color = emissive;
    if (albedo.r + albedo.g + albedo.b > 0.0) {
        // Ambient (cool sky bounce), moon key light, and all the point lights
        float up = 0.5 + 0.5 * hit_n.z;
        vec3 ambient = vec3(0.30, 0.31, 0.42) * (0.55 + 0.45 * up);
        color += albedo * ambient;
        float moon = max(dot(hit_n, MOON_DIR), 0.0);
        color += albedo * vec3(0.80, 0.82, 1.00) * moon * 1.15;
        vec3 view = -rd;
        vec3 hvec = normalize(view + MOON_DIR);
        color += vec3(0.6, 0.62, 0.75) * pow(max(dot(hit_n, hvec), 0.0), max(spec_pow, 1.0)) * spec_amt * moon;

        for (int i = 0; i < 16; i++) {
            vec4 w = wisps[i];
            if (w.w < 0.5) continue;
            float team = floor(w.w);
            float hpv = fract(w.w);
            // A dying wisp lights the stone harder as it fills and flares as it
            // bursts, so the burst is on the ground as well as in the air.
            float lit = death_light(robe_fx[i].y);
            color += albedo * point_light(hp, hit_n, wisp_glow_center(w), team_tint(team), (2.4 + 1.2 * hpv) * lit, 10.0);
        }
        // A charging orb lights its own robe and the stone under it, so the
        // caster is lit by the spell they are about to throw.
        for (int i = 0; i < 16; i++) {
            vec4 cs = wisp_cast[i];
            if (cs.w < 0.5) continue;
            color += albedo * point_light(hp, hit_n, cs.xyz, spell_tint(cs.w), 0.8 + 3.2 * wisp_aim[i].w, 8.0);
        }
        // A standing pylon is the main light in its lane, from about mid-shaft,
        // and it dims as it comes down -- so a lane whose tower has been broken
        // genuinely goes dark.
        for (int i = 0; i < NPYLON; i++) {
            float standing = pylon_bound[i].w;
            if (standing <= 0.002) continue;
            vec3 c = pylons[i].xyz + vec3(0.0, 0.0, pylon_shape[i].x * standing * 0.5);
            color += albedo * point_light(hp, hit_n, c, ore_tint(pylon_shape[i].w), 9.0 * standing, 22.0);
        }
        for (int i = 0; i < NCHUNK; i++) {
            if (chunks[i].w < 0.01) continue;
            color += albedo * point_light(hp, hit_n, chunks[i].xyz, ore_tint(chunk_fx[i].x), 0.9, 4.0);
        }
        for (int i = 0; i < 12; i++) {
            vec4 p = projectiles[i];
            if (p.w < 0.5) continue;
            color += albedo * point_light(hp, hit_n, p.xyz, spell_tint(floor(p.w)), 2.2, 7.0);
        }
        for (int i = 0; i < 8; i++) {
            vec4 im = impacts[i];
            if (im.w < 0.5) continue;
            float age = fract(im.w);
            color += albedo * point_light(hp, hit_n, im.xyz, spell_tint(floor(im.w)), 9.0 * age * age, 9.0);
        }
        if (hand_pos.w > 0.001) {
            color += albedo * point_light(hp, hit_n, hand_pos.xyz, hand_tint(), 0.9 + 1.4 * fx.w + 0.6 * hand_cast.y, 6.0);
        }
        for (int i = 0; i < 4; i++) {
            float code = beams[i].w;
            if (code < 0.5) continue;
            float flicker = 0.85 + 0.15 * sin(WORLD_T * 53.0 + float(i) * 1.3);
            color += albedo * point_light(hp, hit_n, beam_ends[i].xyz, spell_tint(code), 6.0 * flicker, 8.0);
        }
    }

    // Distance fog toward the horizon color
    float fog = 1.0 - exp(-hit_t * 0.0066);
    if (mat == MAT_WISP || mat == MAT_PROJ || mat == MAT_HAND || mat == MAT_ROBE || mat == MAT_CAST_ORB) fog *= 0.5;
    color = mix(color, sky_here * 1.15, fog);
    color += aura;

    // Tonemap
    color = 1.0 - exp(-color * 1.5);

    // Screen-space effects. The un-normalized ray length grows toward the
    // screen edges, which gives a cheap radial factor.
    float edge = clamp((length(ray_dir) - 1.0) * 1.6, 0.0, 1.0);
    color *= 1.0 - 0.28 * edge * edge;
    // Hurt: red bleed from the edges
    color = mix(color, vec3(0.75, 0.05, 0.02), fx.x * (0.25 + 0.75 * edge) * 0.8);
    // Mend: the hurt vignette run backwards -- verdant, brightest at the
    // centre, and it lifts the image instead of staining it.
    color = mix(color, vec3(0.25, 0.85, 0.45), fx2.w * (0.85 - 0.55 * edge) * 0.22);
    // Blink / cast flash
    color = mix(color, team_core(fx.z), fx.y * 0.55);
    // Dead: desaturate
    if (fx2.y > 0.5) {
        float l = dot(color, vec3(0.3, 0.59, 0.11));
        color = mix(color, vec3(l) * 0.7, 0.75);
    }
    frag_color = vec4(clamp(color, 0.0, 1.0), 1.0);
}
@end

@program scene vs fs
