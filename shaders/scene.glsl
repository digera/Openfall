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
layout(binding=1) uniform fs_params {
    vec3 room_min;
    float world_t;
    vec3 room_max;
    float flash;
    vec3 lamp_pos;
    float kick;
    vec3 gun_grip;
    float gun_on;
    vec3 gun_muzzle;
    float local_team;
    vec3 gun_right;
    float _pad_r;
    vec3 gun_up;
    float _pad_u;
    vec4 impact0;
    vec4 impact1;
    vec4 impact2;
    vec4 impact3;
    vec4 impact4;
    vec4 impact5;
    vec4 impact6;
    vec4 impact7;
    vec4 projectiles[16];
    vec4 wisps[16];
};

in vec3 ray_origin;
in vec3 ray_dir;
out vec4 frag_color;

const uint MAT_WALL = 1u;
const uint MAT_FLOOR = 2u;
const uint MAT_CEIL = 3u;
const uint MAT_GUN_METAL = 4u;
const uint MAT_GUN_GRIP = 5u;
const uint MAT_FLASH = 6u;
const uint MAT_PROJECTILE = 7u;
const uint MAT_WISP = 8u;

bool intersect_aabb(vec3 ro, vec3 inv, vec3 bmin, vec3 bmax, out float t0, out float t1) {
    vec3 tbot = (bmin - ro) * inv;
    vec3 ttop = (bmax - ro) * inv;
    vec3 ts = min(ttop, tbot);
    vec3 tb = max(ttop, tbot);
    t0 = max(max(ts.x, ts.y), ts.z);
    t1 = min(min(tb.x, tb.y), tb.z);
    return t1 >= max(t0, 0.0);
}

float lamp(vec3 p, vec3 n, vec3 lp, float intensity, float r2, vec3 tint) {
    vec3 l = lp - p;
    float d2 = dot(l, l);
    if (d2 > r2 * 6.0) {
        return 0.0;
    }
    float att = intensity / (1.0 + d2 * 2.8);
    float nd = max(dot(n, normalize(l)), 0.0);
    return att * (0.25 + 0.75 * nd);
}

float sd_box(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sd_capsule(vec3 p, vec3 a, vec3 b, float r) {
    vec3 pa = p - a;
    vec3 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

vec3 gun_local(vec3 p) {
    vec3 z = normalize(gun_muzzle - gun_grip);
    vec3 x = normalize(gun_right);
    vec3 y = normalize(gun_up);
    vec3 d = p - gun_grip;
    return vec3(dot(d, x), dot(d, y), dot(d, z));
}

float gun_metal_sd(vec3 l) {
    float rec = sd_box(l - vec3(0.0, 0.012, 0.10), vec3(0.018, 0.020, 0.10));
    float slide = sd_box(l - vec3(0.0, 0.028, 0.12), vec3(0.016, 0.009, 0.11));
    float bar = sd_capsule(l, vec3(0.0, 0.016, 0.18), vec3(0.0, 0.016, 0.36), 0.007);
    float guard = sd_box(l - vec3(0.0, -0.010, 0.078), vec3(0.007, 0.016, 0.016));
    return min(min(rec, slide), min(bar, guard));
}

float gun_grip_sd(vec3 l) {
    return sd_box(l - vec3(0.0, -0.042, 0.048), vec3(0.012, 0.044, 0.022));
}

float gun_map(vec3 p) {
    vec3 l = gun_local(p);
    return min(gun_metal_sd(l), gun_grip_sd(l));
}

bool gun_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out uint mat) {
    t = 0.0;
    n = vec3(0.0, 0.0, 1.0);
    mat = 0u;
    vec3 pc = 0.5 * (gun_grip + gun_muzzle);
    float pr = 0.5 * length(gun_muzzle - gun_grip) + 0.16;
    vec3 oc = ro - pc;
    float b = dot(oc, rd);
    float h = b * b - dot(oc, oc) + pr * pr;
    if (h < 0.0) {
        return false;
    }
    float ts = -b - sqrt(h);
    t = ts > 0.02 ? ts : 0.02;
    if (t >= tmax) {
        return false;
    }
    for (int i = 0; i < 28; i++) {
        vec3 p = ro + rd * t;
        float d = gun_map(p);
        if (d < 0.0008) {
            float e = 0.0014;
            n = normalize(vec3(
                gun_map(p + vec3(e, 0, 0)) - gun_map(p - vec3(e, 0, 0)),
                gun_map(p + vec3(0, e, 0)) - gun_map(p - vec3(0, e, 0)),
                gun_map(p + vec3(0, 0, e)) - gun_map(p - vec3(0, 0, e))
            ));
            vec3 l = gun_local(p);
            mat = gun_grip_sd(l) < gun_metal_sd(l) + 0.0005 ? MAT_GUN_GRIP : MAT_GUN_METAL;
            return true;
        }
        t += max(d, 0.0008);
        if (t >= tmax || t > 2.4) {
            return false;
        }
    }
    return false;
}

bool flash_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n) {
    t = 0.0;
    n = vec3(0.0, 0.0, 1.0);
    if (flash < 0.12) {
        return false;
    }
    float rad = 0.018 + 0.034 * flash;
    vec3 oc = ro - gun_muzzle;
    float b = dot(oc, rd);
    float h = b * b - dot(oc, oc) + rad * rad;
    if (h < 0.0) {
        return false;
    }
    t = -b - sqrt(h);
    if (t < 0.02 || t >= tmax) {
        return false;
    }
    n = normalize((ro + rd * t) - gun_muzzle);
    return true;
}

vec3 wisp_team_tint(float packed) {
    if (packed < 0.0) {
        return vec3(0.40, 0.72, 1.0);
    }
    return vec3(1.0, 0.36, 0.28);
}

vec3 wisp_core_tint(float packed) {
    if (packed < 0.0) {
        return vec3(0.82, 0.94, 1.0);
    }
    return vec3(1.0, 0.90, 0.70);
}

vec3 wisp_center(vec4 w, float phase) {
    return w.xyz + vec3(
        0.045 * sin(world_t * 1.37 + phase),
        0.045 * cos(world_t * 1.11 + phase * 0.83),
        0.11 * sin(world_t * 2.07 + phase)
    );
}

vec3 self_wisp_center() {
    return lamp_pos + vec3(
        0.02 * sin(world_t * 1.37),
        0.02 * cos(world_t * 1.11),
        -0.66 + 0.07 * sin(world_t * 2.07)
    );
}

vec3 self_wisp_team_tint() {
    if (local_team > 1.5) {
        return vec3(0.40, 0.72, 1.0);
    }
    if (local_team > 0.5) {
        return vec3(1.0, 0.36, 0.28);
    }
    return vec3(0.78, 0.52, 1.0);
}

vec3 self_wisp_core_tint() {
    if (local_team > 1.5) {
        return vec3(0.82, 0.94, 1.0);
    }
    if (local_team > 0.5) {
        return vec3(1.0, 0.90, 0.70);
    }
    return vec3(0.96, 0.88, 1.0);
}

bool intersect_sphere(vec3 ro, vec3 rd, vec3 c, float r, float tmin, float tmax, out float t, out vec3 n) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    vec3 oc = ro - c;
    float b = dot(oc, rd);
    float h = b * b - dot(oc, oc) + r * r;
    if (h < 0.0) {
        return false;
    }
    float s = sqrt(h);
    t = -b - s;
    if (t < tmin) {
        t = -b + s;
    }
    if (t < tmin || t > tmax) {
        return false;
    }
    n = normalize((ro + rd * t) - c);
    return true;
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
    if (h < 0.0 || a < 1e-8) {
        return false;
    }
    float s = sqrt(h);
    t = (-b - s) / a;
    if (t < tmin) {
        t = (-b + s) / a;
    }
    if (t < tmin || t > tmax) {
        return false;
    }
    vec3 p = ro + rd * t;
    n = normalize((p - c) / (rad * rad));
    return true;
}

bool wisp_hit_parts(vec3 ro, vec3 rd, vec3 c, float life, float tmin, float tmax, out float t, out vec3 n, out float part) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    part = 0.0;
    bool hit = false;
    float best = tmax;
    float scale = 0.82 + 0.18 * life;

    float et;
    vec3 en;
    vec3 mantle = vec3(0.17, 0.17, 0.40) * scale;
    if (intersect_ellipsoid(ro, rd, c, mantle, tmin, best, et, en)) {
        best = et;
        n = en;
        part = 0.0;
        hit = true;
    }

    float st;
    vec3 sn;
    vec3 core_c = c + vec3(0.0, 0.0, 0.06 * scale);
    if (intersect_sphere(ro, rd, core_c, 0.07 * scale, tmin, best, st, sn)) {
        best = st;
        n = sn;
        part = 1.0;
        hit = true;
    }

    float a1 = world_t * 2.55 + c.x * 3.1;
    float a2 = world_t * 1.85 + c.y * 2.4;
    float a3 = world_t * 3.15 + c.z * 1.7;
    vec3 m1 = c + vec3(cos(a1), sin(a1), 0.28 * sin(a1 * 1.35)) * (0.24 * scale);
    vec3 m2 = c + vec3(cos(a2 + 2.094), sin(a2 + 2.094), 0.22 * cos(a2 * 1.2)) * (0.20 * scale);
    vec3 m3 = c + vec3(cos(a3 + 4.188), sin(a3 + 4.188), 0.16 * sin(a3 * 0.9)) * (0.17 * scale);

    if (intersect_sphere(ro, rd, m1, 0.042 * scale, tmin, best, st, sn)) {
        best = st;
        n = sn;
        part = 2.0;
        hit = true;
    }
    if (intersect_sphere(ro, rd, m2, 0.032 * scale, tmin, best, st, sn)) {
        best = st;
        n = sn;
        part = 2.0;
        hit = true;
    }
    if (intersect_sphere(ro, rd, m3, 0.024 * scale, tmin, best, st, sn)) {
        best = st;
        n = sn;
        part = 2.0;
        hit = true;
    }
    t = best;
    return hit;
}

bool wisp_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out vec3 tint, out vec3 core, out float part, out float packed_hp) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    tint = vec3(1.0);
    core = vec3(1.0);
    part = 0.0;
    packed_hp = 1.0;
    bool hit = false;
    float best = tmax;

    for (int i = 0; i < 16; i++) {
        vec4 w = wisps[i];
        if (abs(w.w) < 0.001) {
            continue;
        }
        float phase = float(i) * 2.21;
        vec3 c = wisp_center(w, phase);
        float wt, wp;
        vec3 wn;
        if (wisp_hit_parts(ro, rd, c, abs(w.w), 0.04, best, wt, wn, wp)) {
            best = wt;
            n = wn;
            part = wp;
            packed_hp = abs(w.w);
            tint = wisp_team_tint(w.w);
            core = wisp_core_tint(w.w);
            hit = true;
        }
    }

    float st, sp;
    vec3 sn;
    if (wisp_hit_parts(ro, rd, self_wisp_center(), 1.0, 0.12, best, st, sn, sp)) {
        best = st;
        n = sn;
        part = sp;
        packed_hp = 1.0;
        tint = self_wisp_team_tint();
        core = self_wisp_core_tint();
        hit = true;
    }

    t = best;
    return hit;
}

float wisp_corona(vec3 ro, vec3 rd, float tmax, vec3 c, float radius) {
    vec3 oc = c - ro;
    float tca = dot(oc, rd);
    float t = clamp(tca, 0.04, tmax);
    float d = length((ro + rd * t) - c);
    float g = 1.0 - smoothstep(radius, radius * 3.2, d);
    g *= g;
    float along = smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(tmax - 0.05, tmax, t));
    return g * along;
}

vec3 wisp_glow_field(vec3 ro, vec3 rd, float tmax) {
    vec3 glow = vec3(0.0);
    for (int i = 0; i < 16; i++) {
        vec4 w = wisps[i];
        if (abs(w.w) < 0.001) {
            continue;
        }
        float hp = abs(w.w);
        float phase = float(i) * 2.21;
        vec3 c = wisp_center(w, phase);
        float g = wisp_corona(ro, rd, tmax, c, 0.38 + 0.10 * hp);
        g *= 0.55 + 0.45 * hp;
        glow += wisp_team_tint(w.w) * g * (0.55 + 0.25 * sin(world_t * 3.4 + phase));
        glow += wisp_core_tint(w.w) * g * 0.22;
    }
    float sg = wisp_corona(ro, rd, tmax, self_wisp_center(), 0.30);
    glow += self_wisp_team_tint() * sg * 0.35;
    return glow;
}

bool projectile_trace(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out float spell_type) {
    t = tmax;
    n = vec3(0.0, 0.0, 1.0);
    spell_type = 0.0;
    bool hit = false;
    
    for (int i = 0; i < 16; i++) {
        vec4 proj = projectiles[i];
        if (proj.w <= 0.0) {
            continue;
        }
        
        vec3 center = proj.xyz;
        float radius = abs(proj.w);
        spell_type = sign(proj.w);
        
        vec3 oc = ro - center;
        float b = dot(oc, rd);
        float c = dot(oc, oc) - radius * radius;
        float disc = b * b - c;
        
        if (disc < 0.0) {
            continue;
        }
        
        float t_hit = -b - sqrt(disc);
        if (t_hit >= 0.02 && t_hit < t) {
            t = t_hit;
            n = normalize((ro + rd * t) - center);
            hit = true;
        }
    }
    
    return hit;
}

bool room_hit(vec3 ro, vec3 rd, vec3 inv, out float t, out vec3 n, out uint mat) {
    t = 0.0;
    n = vec3(0.0, 0.0, 1.0);
    mat = 0u;
    float t0, t1;
    if (!intersect_aabb(ro, inv, room_min, room_max, t0, t1)) {
        return false;
    }
    t = t0 > 0.02 ? t0 : t1;
    if (t < 0.0) {
        return false;
    }
    vec3 p = ro + rd * t;
    vec3 c = 0.5 * (room_min + room_max);
    vec3 ext = max(room_max - room_min, vec3(1e-4));
    vec3 d = (p - c) / (0.5 * ext);
    vec3 ad = abs(d);
    n = vec3(0.0);
    if (ad.x > ad.y && ad.x > ad.z) {
        n.x = -sign(d.x);
        mat = MAT_WALL;
    } else if (ad.y > ad.z) {
        n.y = -sign(d.y);
        mat = MAT_WALL;
    } else {
        n.z = -sign(d.z);
        mat = n.z > 0.0 ? MAT_FLOOR : MAT_CEIL;
    }
    return true;
}

float scorch(vec3 hp, vec4 im) {
    if (im.w <= 0.001) {
        return 0.0;
    }
    float d = length(hp - im.xyz);
    return (1.0 - smoothstep(0.0, 0.11, d)) * im.w;
}

void main() {
    vec3 ro = ray_origin;
    vec3 rd = normalize(ray_dir);
    vec3 inv = 1.0 / rd;

    float hit_t = -1.0;
    vec3 hit_n = vec3(0.0, 0.0, 1.0);
    uint hit_mat = 0u;
    bool is_gun = false;
    bool is_flash = false;
    bool is_projectile = false;
    bool is_wisp = false;
    float proj_spell_type = 0.0;
    vec3 wisp_tint = vec3(1.0);
    vec3 wisp_core = vec3(1.0);
    float wisp_part = 0.0;
    float wisp_hp = 1.0;

    float rt;
    vec3 rn;
    uint rm;
    if (room_hit(ro, rd, inv, rt, rn, rm)) {
        hit_t = rt;
        hit_n = rn;
        hit_mat = rm;
    }

    float best = hit_t > 0.0 ? hit_t : 2.4;
    
    // Check projectiles
    float pt;
    vec3 pn;
    float ptype;
    if (projectile_trace(ro, rd, best, pt, pn, ptype)) {
        hit_t = pt;
        hit_n = pn;
        hit_mat = MAT_PROJECTILE;
        proj_spell_type = ptype;
        is_projectile = true;
        best = pt;
    }

    float wt;
    vec3 wn;
    vec3 wcol;
    vec3 wcore;
    float wpart;
    float whp;
    if (wisp_trace(ro, rd, best, wt, wn, wcol, wcore, wpart, whp)) {
        hit_t = wt;
        hit_n = wn;
        hit_mat = MAT_WISP;
        wisp_tint = wcol;
        wisp_core = wcore;
        wisp_part = wpart;
        wisp_hp = whp;
        is_wisp = true;
        is_projectile = false;
        best = wt;
    }
    
    if (gun_on > 0.5) {
        float gt;
        vec3 gn;
        uint gm;
        if (gun_trace(ro, rd, best, gt, gn, gm)) {
            hit_t = gt;
            hit_n = gn;
            hit_mat = gm;
            is_gun = true;
            is_projectile = false;
            is_wisp = false;
            best = gt;
        }
        float ft;
        vec3 fn;
        if (flash_trace(ro, rd, best, ft, fn)) {
            hit_t = ft;
            hit_n = fn;
            hit_mat = MAT_FLASH;
            is_flash = true;
            is_gun = false;
            is_projectile = false;
            is_wisp = false;
        }
    }

    vec3 bg = vec3(0.028, 0.030, 0.038);
    float glow_tmax = hit_t > 0.0 ? hit_t : 24.0;
    vec3 aura = wisp_glow_field(ro, rd, glow_tmax);
    if (hit_t < 0.0) {
        vec3 empty = bg + aura;
        frag_color = vec4(clamp(empty, vec3(0.0), vec3(1.0)), 1.0);
        return;
    }

    vec3 hp = ro + rd * hit_t;
    if (dot(hit_n, rd) > 0.0) {
        hit_n = -hit_n;
    }

    vec3 albedo = vec3(0.42, 0.40, 0.36);
    if (hit_mat == MAT_FLOOR) {
        float cx = floor(hp.x * 2.0);
        float cy = floor(hp.y * 2.0);
        float chk = mod(cx + cy, 2.0);
        albedo = mix(vec3(0.38, 0.36, 0.32), vec3(0.22, 0.21, 0.19), chk);
    } else if (hit_mat == MAT_CEIL) {
        albedo = vec3(0.55, 0.54, 0.50);
    } else if (hit_mat == MAT_WALL) {
        albedo = vec3(0.62, 0.58, 0.50);
        if (abs(hit_n.x) > 0.8 && hit_n.x < 0.0) {
            albedo = vec3(0.52, 0.42, 0.34);
        }
    } else if (hit_mat == MAT_GUN_METAL) {
        albedo = vec3(0.16, 0.17, 0.18);
    } else if (hit_mat == MAT_GUN_GRIP) {
        albedo = vec3(0.22, 0.12, 0.08);
    } else if (hit_mat == MAT_FLASH) {
        albedo = vec3(1.0, 0.82, 0.42);
    } else if (hit_mat == MAT_PROJECTILE) {
        // Color by spell type: 1=Missile(purple), 2=Orb(blue), 3=Blink(white), 4=Frost(cyan)
        if (proj_spell_type == 1.0) {
            albedo = vec3(0.82, 0.42, 0.92);  // Arcane purple
        } else if (proj_spell_type == 2.0) {
            albedo = vec3(0.52, 0.62, 0.92);  // Arcane blue
        } else if (proj_spell_type == 3.0) {
            albedo = vec3(0.92, 0.92, 0.98);  // Blink white
        } else if (proj_spell_type == 4.0) {
            albedo = vec3(0.42, 0.82, 0.92);  // Frost cyan
        } else {
            albedo = vec3(0.92, 0.82, 0.42);  // Default yellow
        }
    } else if (hit_mat == MAT_WISP) {
        albedo = mix(wisp_tint, wisp_core, wisp_part > 0.5 ? 0.85 : 0.35);
    }

    float burn = 0.0;
    burn = max(burn, scorch(hp, impact0));
    burn = max(burn, scorch(hp, impact1));
    burn = max(burn, scorch(hp, impact2));
    burn = max(burn, scorch(hp, impact3));
    burn = max(burn, scorch(hp, impact4));
    burn = max(burn, scorch(hp, impact5));
    burn = max(burn, scorch(hp, impact6));
    burn = max(burn, scorch(hp, impact7));
    if (!is_gun && !is_flash && !is_projectile && !is_wisp && burn > 0.0) {
        albedo *= 1.0 - burn * 0.82;
        albedo += vec3(0.12, 0.04, 0.01) * burn;
    }

    vec3 color = albedo * 0.04;
    if (is_flash) {
        color = albedo * (0.85 + 1.4 * flash);
    } else if (is_projectile) {
        // Projectiles glow brightly
        float ndv = max(dot(hit_n, -rd), 0.0);
        float fresnel = pow(1.0 - ndv, 2.0);
        color = albedo * (0.85 + 0.65 * fresnel);
    } else if (is_wisp) {
        float ndv = max(dot(hit_n, -rd), 0.0);
        float fresnel = pow(1.0 - ndv, 2.4);
        float pulse = 0.62 + 0.38 * sin(world_t * (3.1 + 6.0 * (1.0 - wisp_hp)));
        vec3 body = mix(wisp_core, wisp_tint, 0.42 + 0.40 * (1.0 - ndv));
        if (wisp_part > 1.5) {
            body = mix(wisp_core, wisp_tint, 0.18);
            color = body * (1.15 + 0.55 * pulse);
        } else if (wisp_part > 0.5) {
            color = wisp_core * (1.05 + 0.35 * pulse) + wisp_tint * fresnel * 0.35;
        } else {
            color = body * (0.72 + 0.38 * pulse);
            color += wisp_tint * fresnel * 0.95;
            color += wisp_core * pow(ndv, 5.0) * 0.55;
        }
        color *= 0.55 + 0.45 * wisp_hp;
    } else if (is_gun) {
        float ndv = max(dot(hit_n, -rd), 0.0);
        float wrap = 0.22 + 0.78 * ndv;
        float spec = pow(ndv, hit_mat == MAT_GUN_METAL ? 32.0 : 8.0);
        spec *= hit_mat == MAT_GUN_METAL ? 0.38 : 0.06;
        color = albedo * wrap * vec3(0.95, 0.88, 0.78) + vec3(1.0, 0.96, 0.88) * spec;
        color += albedo * lamp(hp, hit_n, lamp_pos, 1.4, 8.0, vec3(1.0, 0.92, 0.78)) * 0.35;
        if (flash > 0.25) {
            color += vec3(1.0, 0.78, 0.38) * flash * (hit_mat == MAT_GUN_METAL ? 0.55 : 0.18);
        }
    } else {
        color += albedo * lamp(hp, hit_n, lamp_pos, 3.2, 48.0, vec3(1.0, 0.92, 0.78)) * vec3(1.0, 0.93, 0.82);
        color += albedo * vec3(0.08, 0.09, 0.11);
        if (flash > 0.2) {
            color += albedo * lamp(hp, hit_n, gun_muzzle, 2.2 * flash, 4.0, vec3(1.0, 0.72, 0.32)) * vec3(1.0, 0.78, 0.40);
        }
        for (int i = 0; i < 16; i++) {
            vec4 w = wisps[i];
            if (abs(w.w) < 0.001) {
                continue;
            }
            vec3 wc = wisp_center(w, float(i) * 2.21);
            vec3 wtint = wisp_team_tint(w.w);
            float intensity = 1.35 + 1.1 * abs(w.w);
            color += albedo * lamp(hp, hit_n, wc, intensity, 9.0, wtint) * wtint;
        }
        vec3 sc = self_wisp_center();
        vec3 stint = self_wisp_team_tint();
        color += albedo * lamp(hp, hit_n, sc, 1.7, 6.5, stint) * stint;
    }

    float fog = (is_gun || is_flash || is_projectile || is_wisp) ? 0.0 : clamp(hit_t / 28.0, 0.0, 1.0);
    fog *= fog;
    color = mix(color, bg, fog);
    color += aura * (is_wisp ? 0.18 : 1.0);
    color = clamp(color, vec3(0.0), vec3(1.0));
    frag_color = vec4(color, 1.0);
}
@end

@program scene vs fs
