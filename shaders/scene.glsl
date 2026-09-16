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
    vec4 fx2;               // x hit marker, y dead, z match ended, w unused
    vec4 hand_pos;          // xyz hand orb position, w scale
    vec4 floor_boxes[22];   // pairs: (center.xyz, sin yaw), (half.xyz, cos yaw)
    vec4 solid_boxes[18];   // pairs, same layout
    vec4 obelisks[4];       // xyz pos, w owner team
    vec4 obelisk_fx[4];     // x capturing team, y progress, z state, w essence mult
    vec4 projectiles[12];   // xyz pos, w = type + radius
    vec4 proj_vel[12];      // xyz vel
    vec4 wisps[16];         // xyz pos, w = team + hp (0 = none)
    vec4 impacts[8];        // xyz pos, w = type + age (0 = none)
};

in vec3 ray_origin;
in vec3 ray_dir;
out vec4 frag_color;

const int NFLOOR = 11;
const int NSOLID = 9;

const int MAT_NONE = 0;
const int MAT_WALL = 1;
const int MAT_FLOOR = 2;
const int MAT_SKY = 3;
const int MAT_SOLID = 4;
const int MAT_OBELISK = 5;
const int MAT_WISP = 6;
const int MAT_PROJ = 7;
const int MAT_HAND = 8;

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
    return vec3(0.50, 0.92, 1.00);                   // frost: cyan
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
// Obelisks: hovering crystal + orbiting motes

// Crystal hover height is animated on the CPU (obelisk_fx.w).
vec3 obelisk_crystal_center(int i) {
    return obelisks[i].xyz + vec3(0.0, 0.0, obelisk_fx[i].w);
}

bool obelisk_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out int idx, out float part) {
    bool hit = false;
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    idx = 0;
    part = 0.0;
    for (int i = 0; i < 4; i++) {
        vec3 c = obelisk_crystal_center(i);
        float et;
        vec3 en;
        // Bounding sphere around crystal, motes and plinth
        if (!bounds_hit(ro, rd, obelisks[i].xyz + vec3(0.0, 0.0, 2.2), 3.4, t)) continue;
        if (intersect_ellipsoid(ro, rd, c, vec3(0.55, 0.55, 1.9), 0.04, t, et, en)) {
            t = et; n = en; idx = i; part = 0.0; hit = true;
        }
        // Plinth
        if (intersect_ellipsoid(ro, rd, obelisks[i].xyz + vec3(0.0, 0.0, 0.18), vec3(1.15, 1.15, 0.22), 0.04, t, et, en)) {
            t = et; n = en; idx = i; part = 2.0; hit = true;
        }
        for (int k = 0; k < 3; k++) {
            float a = WORLD_T * (0.9 + 0.25 * float(k)) + float(k) * 2.094 + float(i);
            vec3 m = c + vec3(cos(a) * 1.25, sin(a) * 1.25, 0.9 * sin(a * 0.7 + float(k)));
            if (intersect_sphere(ro, rd, m, 0.11, 0.04, t, et, en)) {
                t = et; n = en; idx = i; part = 1.0; hit = true;
            }
        }
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Wisps (players)

// Wisp positions arrive pre-animated (bob applied on the CPU once per frame).
vec3 wisp_center(vec4 w, float phase) {
    return w.xyz;
}

bool wisp_hit_parts(vec3 ro, vec3 rd, vec3 c, float life, float tmin, float tmax, out float t, out vec3 n, out float part) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    part = 0.0;
    float scale = 0.82 + 0.18 * life;

    // Cheap reject: bounding sphere
    if (!bounds_hit(ro, rd, c, 0.55 * scale, tmax)) return false;

    bool hit = false;
    float best = tmax;
    float et;
    vec3 en;
    vec3 mantle = vec3(0.17, 0.17, 0.40) * scale;
    if (intersect_ellipsoid(ro, rd, c, mantle, tmin, best, et, en)) {
        best = et; n = en; part = 0.0; hit = true;
    }
    vec3 core_c = c + vec3(0.0, 0.0, 0.06 * scale);
    if (intersect_sphere(ro, rd, core_c, 0.07 * scale, tmin, best, et, en)) {
        best = et; n = en; part = 1.0; hit = true;
    }
    float a1 = WORLD_T * 2.55 + c.x * 3.1;
    float a2 = WORLD_T * 1.85 + c.y * 2.4;
    float a3 = WORLD_T * 3.15 + c.z * 1.7;
    vec3 m1 = c + vec3(cos(a1), sin(a1), 0.28 * sin(a1 * 1.35)) * (0.24 * scale);
    vec3 m2 = c + vec3(cos(a2 + 2.094), sin(a2 + 2.094), 0.22 * cos(a2 * 1.2)) * (0.20 * scale);
    vec3 m3 = c + vec3(cos(a3 + 4.188), sin(a3 + 4.188), 0.16 * sin(a3 * 0.9)) * (0.17 * scale);
    if (intersect_sphere(ro, rd, m1, 0.042 * scale, tmin, best, et, en)) { best = et; n = en; part = 2.0; hit = true; }
    if (intersect_sphere(ro, rd, m2, 0.032 * scale, tmin, best, et, en)) { best = et; n = en; part = 2.0; hit = true; }
    if (intersect_sphere(ro, rd, m3, 0.024 * scale, tmin, best, et, en)) { best = et; n = en; part = 2.0; hit = true; }
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
        float wteam = floor(w.w);
        float whp = fract(w.w);
        vec3 c = wisp_center(w, float(i) * 2.21);
        float wt, wp;
        vec3 wn;
        if (wisp_hit_parts(ro, rd, c, whp, 0.04, t, wt, wn, wp)) {
            t = wt; n = wn; part = wp; team = wteam; hp = whp; hit = true;
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

    int ob_idx = 0;
    float ob_part = 0.0;
    float ot;
    vec3 on;
    if (obelisk_trace(ro, rd, best, ot, on, ob_idx, ob_part)) {
        best = ot; hit_n = on; mat = MAT_OBELISK;
    }

    float wisp_team = 0.0, wisp_hp = 1.0, wisp_part = 0.0;
    float wt;
    vec3 wn;
    if (wisp_trace(ro, rd, best, wt, wn, wisp_team, wisp_hp, wisp_part)) {
        best = wt; hit_n = wn; mat = MAT_WISP;
    }

    float proj_type = 0.0;
    float pt;
    vec3 pn;
    if (projectile_trace(ro, rd, best, pt, pn, proj_type)) {
        best = pt; hit_n = pn; mat = MAT_PROJ;
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
    if (dot(hit_n, rd) > 0.0) hit_n = -hit_n;

    float glow_tmax = (mat == MAT_SKY) ? 400.0 : hit_t;

    // --- Volumetric-ish glows (wisps, projectiles, impacts, obelisks) --------
    vec3 aura = vec3(0.0);
    for (int i = 0; i < 16; i++) {
        vec4 w = wisps[i];
        if (w.w < 0.5) continue;
        float team = floor(w.w);
        float hpv = fract(w.w);
        vec3 c = wisp_center(w, float(i) * 2.21);
        float g = corona(ro, rd, glow_tmax, c, 0.40 + 0.10 * hpv) * (0.5 + 0.5 * hpv);
        aura += team_tint(team) * g * (0.55 + 0.2 * sin(WORLD_T * 3.4 + float(i)));
        aura += team_core(team) * g * 0.18;
    }
    for (int i = 0; i < 12; i++) {
        vec4 p = projectiles[i];
        if (p.w < 0.5) continue;
        float ptype = floor(p.w);
        float radius = fract(p.w);
        vec3 tint = spell_tint(ptype);
        aura += tint * corona(ro, rd, glow_tmax, p.xyz, radius * 3.0) * 0.9;
        vec3 v = proj_vel[i].xyz;
        float trail_len = (ptype > 1.5 && ptype < 2.5) ? 0.5 : 1.8;
        vec3 tail = p.xyz - normalize(v + vec3(1e-4)) * trail_len;
        aura += tint * segment_glow(ro, rd, glow_tmax, tail, p.xyz, radius * 1.6) * 0.55;
    }
    for (int i = 0; i < 8; i++) {
        vec4 im = impacts[i];
        if (im.w < 0.5) continue;
        float itype = floor(im.w);
        float age = fract(im.w);
        float grow = 1.0 - age;
        float rad = (itype > 1.5 && itype < 2.5) ? 0.6 + 3.2 * grow : 0.25 + 1.3 * grow;
        vec3 tint = spell_tint(itype);
        float g = corona(ro, rd, glow_tmax, im.xyz, rad) * age * age;
        aura += tint * g * 1.6;
        aura += vec3(1.0) * g * age * 0.6;
    }
    if (hand_pos.w > 0.001) {
        vec3 ht = mix(team_core(fx.z), team_tint(fx.z), 0.5);
        aura += ht * corona(ro, rd, glow_tmax, hand_pos.xyz, 0.06 * hand_pos.w) * (0.35 + 0.9 * fx.w);
    }
    for (int i = 0; i < 4; i++) {
        vec3 c = obelisk_crystal_center(i);
        float owner = obelisks[i].w;
        vec3 tint = team_tint(owner);
        float pulse = 0.75 + 0.25 * sin(WORLD_T * 2.2 + float(i));
        aura += tint * corona(ro, rd, glow_tmax, c, 1.1) * 0.45 * pulse;
        if (obelisk_fx[i].z > 1.5 && obelisk_fx[i].z < 2.5) {
            // Capturing: pulse in the capturing team's color
            aura += team_tint(obelisk_fx[i].x) * corona(ro, rd, glow_tmax, c, 1.6) * 0.35 * (0.5 + 0.5 * sin(WORLD_T * 6.0));
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
        // Obelisk decals: owner disc, capture progress ring
        for (int i = 0; i < 4; i++) {
            vec2 d = hp.xy - obelisks[i].xy;
            float od = length(d);
            float owner = obelisks[i].w;
            float radius = 3.6;
            if (od < radius + 0.4) {
                vec3 otint = team_tint(owner);
                float disc = 1.0 - smoothstep(radius - 0.3, radius, od);
                albedo = mix(albedo, albedo * 0.55 + otint * 0.22, disc * (owner > 0.5 ? 0.85 : 0.35));
                float edge = 1.0 - smoothstep(0.0, 0.16, abs(od - radius));
                emissive += otint * edge * 0.45;
                // progress arc
                float prog = obelisk_fx[i].y;
                float state = obelisk_fx[i].z;
                if (state > 1.5 && state < 2.5 && prog > 0.0) {
                    float ang = (atan(d.y, d.x) + 3.14159265) / 6.2831853;
                    float arc_r = radius - 0.55;
                    float arc = 1.0 - smoothstep(0.0, 0.18, abs(od - arc_r));
                    arc *= step(ang, prog);
                    emissive += team_tint(obelisk_fx[i].x) * arc * 0.9;
                }
                if (state > 0.5 && state < 1.5) {
                    // contested: flicker
                    emissive += vec3(1.0, 0.85, 0.5) * edge * 0.5 * (0.5 + 0.5 * sin(WORLD_T * 10.0));
                }
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
    } else if (mat == MAT_OBELISK) {
        float owner = obelisks[ob_idx].w;
        vec3 tint = team_tint(owner);
        vec3 core = team_core(owner);
        float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
        float fres = pow(1.0 - ndv, 2.5);
        float pulse = 0.7 + 0.3 * sin(WORLD_T * 2.2 + float(ob_idx));
        if (ob_part < 0.5) {
            albedo = mix(tint, core, 0.35) * 0.35;
            emissive = mix(tint, core, 0.25) * (0.9 + 0.6 * pulse) * (0.45 + 0.55 * fres) + core * pow(ndv, 6.0) * 0.5;
            float facets = 0.85 + 0.15 * sin(hp.z * 9.0 + atan(hp.y - obelisks[ob_idx].y, hp.x - obelisks[ob_idx].x) * 6.0);
            emissive *= facets;
        } else if (ob_part < 1.5) {
            albedo = core * 0.3;
            emissive = core * 1.4 + tint * 0.6;
        } else {
            albedo = vec3(0.30, 0.30, 0.34);
            emissive = tint * 0.25 * pulse;
            spec_pow = 32.0;
            spec_amt = 0.2;
        }
    } else if (mat == MAT_WISP) {
        vec3 tint = team_tint(wisp_team);
        vec3 core = team_core(wisp_team);
        float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
        float fres = pow(1.0 - ndv, 2.4);
        float pulse = 0.62 + 0.38 * sin(WORLD_T * (3.1 + 6.0 * (1.0 - wisp_hp)));
        vec3 body = mix(core, tint, 0.42 + 0.40 * (1.0 - ndv));
        if (wisp_part > 1.5) {
            emissive = mix(core, tint, 0.18) * (1.15 + 0.55 * pulse);
        } else if (wisp_part > 0.5) {
            emissive = core * (1.05 + 0.35 * pulse) + tint * fres * 0.35;
        } else {
            emissive = body * (0.72 + 0.38 * pulse) + tint * fres * 0.95 + core * pow(ndv, 5.0) * 0.55;
        }
        emissive *= 0.55 + 0.45 * wisp_hp;
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
    } else if (mat == MAT_HAND) {
        vec3 tint = team_tint(fx.z);
        vec3 core = team_core(fx.z);
        float ndv = clamp(dot(hit_n, -rd), 0.0, 1.0);
        float fres = pow(1.0 - ndv, 2.0);
        emissive = mix(core, tint, 0.5 + 0.5 * fres) * (0.9 + 1.6 * fx.w) + core * pow(ndv, 6.0) * 0.6;
        albedo = vec3(0.0);
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
            vec3 c = wisp_center(w, float(i) * 2.21);
            color += albedo * point_light(hp, hit_n, c, team_tint(team), 2.4 + 1.2 * hpv, 10.0);
        }
        for (int i = 0; i < 4; i++) {
            vec3 c = obelisk_crystal_center(i);
            color += albedo * point_light(hp, hit_n, c, team_tint(obelisks[i].w), 14.0, 24.0);
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
            color += albedo * point_light(hp, hit_n, hand_pos.xyz, team_tint(fx.z), 0.9 + 1.4 * fx.w, 6.0);
        }
    }

    // Distance fog toward the horizon color
    float fog = 1.0 - exp(-hit_t * 0.011);
    if (mat == MAT_WISP || mat == MAT_PROJ || mat == MAT_HAND) fog *= 0.5;
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
