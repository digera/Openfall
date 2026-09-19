package main

import "core:math"

vec2 :: distinct [2]f32
vec3 :: distinct [3]f32
vec4 :: distinct [4]f32
mat4 :: distinct [4][4]f32

lerpf :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

clampf :: proc(v, lo, hi: f32) -> f32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

saturate :: proc(v: f32) -> f32 {
	return clampf(v, 0, 1)
}

dot_vec3 :: proc(a, b: vec3) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

len_vec3 :: proc(v: vec3) -> f32 {
	return math.sqrt(dot_vec3(v, v))
}

// Alias for consistency
length_vec3 :: proc(v: vec3) -> f32 {
	return len_vec3(v)
}

len2_vec3 :: proc(v: vec3) -> f32 {
	return dot_vec3(v, v)
}

// Linear interpolation for vec3
lerpv3 :: proc(a, b: vec3, t: f32) -> vec3 {
	return vec3{
		lerpf(a.x, b.x, t),
		lerpf(a.y, b.y, t),
		lerpf(a.z, b.z, t),
	}
}

norm_vec3 :: proc(v: vec3) -> vec3 {
	l := len_vec3(v)
	if l == 0 {
		return {}
	}
	return {v.x / l, v.y / l, v.z / l}
}

cross_vec3 :: proc(a, b: vec3) -> vec3 {
	return {
		(a.y * b.z) - (a.z * b.y),
		(a.z * b.x) - (a.x * b.z),
		(a.x * b.y) - (a.y * b.x),
	}
}

// Ray against a Z-up cylinder standing on `base` -- the character hitbox shape,
// shared by server hit registration and client target selection so the two
// always agree on what the crosshair is covering. `dir` must be unit length;
// a ray that starts inside the cylinder reports a distance of zero.
ray_cylinder_hit :: proc(origin, dir, base: vec3, radius, height, max_dist: f32) -> (dist: f32, hit: bool) {
	// Clip the ray against the horizontal slab the cylinder occupies...
	t_enter: f32 = 0
	t_exit := max_dist
	z_lo := base.z
	z_hi := base.z + height
	if abs(dir.z) < 1e-6 {
		if origin.z < z_lo || origin.z > z_hi {
			return 0, false
		}
	} else {
		inv := 1.0 / dir.z
		t0 := (z_lo - origin.z) * inv
		t1 := (z_hi - origin.z) * inv
		if t0 > t1 {
			t0, t1 = t1, t0
		}
		t_enter = max(t_enter, t0)
		t_exit = min(t_exit, t1)
	}

	// ...then against the infinite cylinder around its axis.
	mx := origin.x - base.x
	my := origin.y - base.y
	a := dir.x * dir.x + dir.y * dir.y
	c := mx * mx + my * my - radius * radius
	if a < 1e-12 {
		// Aimed straight up or down: only a ray already over the disc can hit.
		if c > 0 {
			return 0, false
		}
	} else {
		b := mx * dir.x + my * dir.y
		disc := b * b - a * c
		if disc < 0 {
			return 0, false
		}
		root := math.sqrt(disc)
		t_enter = max(t_enter, (-b - root) / a)
		t_exit = min(t_exit, (-b + root) / a)
	}

	if t_enter > t_exit {
		return 0, false
	}
	return t_enter, true
}

hash_u32 :: proc(n: u32) -> u32 {
	x := n
	x = (x ~ (x >> 16)) * 0x7FEB_352D
	x = (x ~ (x >> 15)) * 0x846C_A68B
	return x ~ (x >> 16)
}

PI_F32    :: f32(math.PI)
SQRT3_F32 :: f32(1.7320508)

sqrt_f32 :: proc(v: f32) -> f32 {
	return math.sqrt(v)
}

pow_f32 :: proc(v, e: f32) -> f32 {
	return math.pow(v, e)
}

// Round half away from zero. Named rather than inlined because it sits on the
// quantization path the server and every client must agree on.
round_f32 :: proc(v: f32) -> f32 {
	if v >= 0 {
		return math.floor(v + 0.5)
	}
	return -math.floor(-v + 0.5)
}

clamp_i32 :: proc(v, lo, hi: i32) -> i32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

clamp_int :: proc(v, lo, hi: int) -> int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Floor division. Odin's `/` truncates toward zero, which would fold the two
// cells either side of the origin onto the same index.
div_floor_i32 :: proc(a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) {
		q -= 1
	}
	return q
}

fract_f32 :: proc(v: f32) -> f32 {
	return v - math.floor(v)
}

// 2D box/hex helpers for the pylon silhouette. Kept here beside the other
// shared geometry so the GLSL twins in shaders/scene.glsl have one place to
// be checked against.
max_vec2 :: proc(v: vec2, s: f32) -> vec2 {
	return {max(v.x, s), max(v.y, s)}
}

len_vec2 :: proc(v: vec2) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}
