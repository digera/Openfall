package main

import "core:math"

// The procedural body of an ore pylon: a tapered hexagonal obelisk with a
// pyramidal cap, roughened by grain noise so it reads as raw ore rather than
// cut stone.
//
// On the server this field is used once, to stamp each column's max height.
// Hits and collision use the coarse occupancy grid. The GPU keeps a twin of
// the hull and grain for shading; the marched surface is occupancy plus grain.
//
// Visual only. Occupancy is authoritative; grain can sit ±PYLON_GRAIN_AMP
// outside the hull, and PYLON_COLLIDE_SLACK is what stops you walking through
// the extra rock you can see.

PYLON_GRAIN_AMP  :: f32(0.16)  // surface displacement, as a fraction of base radius
PYLON_GRAIN_FREQ :: f32(2.10)
PYLON_CAP_START  :: f32(0.82)  // height fraction where the pyramidal cap begins
PYLON_CAP_WAIST  :: f32(0.62)  // radius at the shoulder, as a fraction of the base

Pylon_Shape :: struct {
	height: f32,
	radius: f32,  // circumradius of the hexagon at the base
	seed:   f32,
}

pylon_grain_amp :: proc(shape: Pylon_Shape) -> f32 {
	return shape.radius * PYLON_GRAIN_AMP
}

// ---------------------------------------------------------------------------
// Noise (integer hash: bit-identical to the GLSL twin)

pylon_uhash :: proc(x, y, z: i32) -> u32 {
	n := u32(x) * 1597334677 ~ u32(y) * 3812015801 ~ u32(z) * 3299493293
	n = (n << 13) ~ n
	n = n * (n * n * 15731 + 789221) + 1376312589
	return n
}

pylon_hash31 :: proc(x, y, z: i32) -> f32 {
	return f32(pylon_uhash(x, y, z) & 0x7fffffff) / f32(0x7fffffff)
}

pylon_vnoise :: proc(p: vec3) -> f32 {
	ix := i32(math.floor(p.x))
	iy := i32(math.floor(p.y))
	iz := i32(math.floor(p.z))
	fx := fract_f32(p.x)
	fy := fract_f32(p.y)
	fz := fract_f32(p.z)
	ux := fx * fx * (3 - 2 * fx)
	uy := fy * fy * (3 - 2 * fy)
	uz := fz * fz * (3 - 2 * fz)
	n000 := pylon_hash31(ix, iy, iz)
	n100 := pylon_hash31(ix + 1, iy, iz)
	n010 := pylon_hash31(ix, iy + 1, iz)
	n110 := pylon_hash31(ix + 1, iy + 1, iz)
	n001 := pylon_hash31(ix, iy, iz + 1)
	n101 := pylon_hash31(ix + 1, iy, iz + 1)
	n011 := pylon_hash31(ix, iy + 1, iz + 1)
	n111 := pylon_hash31(ix + 1, iy + 1, iz + 1)
	nx00 := lerpf(n000, n100, ux)
	nx10 := lerpf(n010, n110, ux)
	nx01 := lerpf(n001, n101, ux)
	nx11 := lerpf(n011, n111, ux)
	return lerpf(lerpf(nx00, nx10, uy), lerpf(nx01, nx11, uy), uz)
}

pylon_fbm2 :: proc(p: vec3) -> f32 {
	return pylon_vnoise(p) * 0.65 + pylon_vnoise(p * 2.13) * 0.35
}

pylon_grain :: proc(p: vec3, shape: Pylon_Shape) -> f32 {
	s := shape.seed
	q := p * (PYLON_GRAIN_FREQ / max(shape.radius, 0.5)) + vec3{s, s * 0.3, -s}
	return pylon_fbm2(q)
}

// Ore veining: where the rock is rich. Drives the vein glow on intact faces and
// how much ore a bite yields, so a player learns to read the good seams.
pylon_ridged :: proc(p: vec3) -> f32 {
	n := pylon_vnoise(p)
	r := 1 - abs(n * 2 - 1)
	return r * r
}

pylon_vein :: proc(p: vec3, shape: Pylon_Shape) -> f32 {
	s := shape.seed
	q := p * 0.9 + vec3{s * 1.7, s * 0.4, s * 2.1}
	v := pylon_ridged(q)
	v = max(v, pylon_ridged(p * 1.7 + vec3{s, s * 2, -s}) * 0.55)
	return pow_f32(saturate(v), 6.0)
}

// ---------------------------------------------------------------------------
// Silhouette

// Hexagon of circumradius r, centred on the origin.
pylon_sd_hex :: proc(p: vec2, r: f32) -> f32 {
	// (-sqrt(3)/2, 1/2, 1/sqrt(3))
	kx := f32(-0.8660254)
	ky := f32(0.5)
	kz := f32(0.57735)
	q := vec2{abs(p.x), abs(p.y)}
	d := 2 * min(kx * q.x + ky * q.y, 0)
	q -= vec2{kx, ky} * d
	q -= vec2{clampf(q.x, -kz * r, kz * r), r}
	return len_vec2(q) * (q.y >= 0 ? 1 : -1)
}

// Circumradius of the shaft at height z. Two straight segments: a gently
// tapering shaft, then a sharp cap. Continuous at the shoulder, which is all
// the marcher needs.
pylon_radius_at :: proc(z: f32, shape: Pylon_Shape) -> f32 {
	t := clampf(z / max(shape.height, 0.01), 0, 1)
	waist := shape.radius * PYLON_CAP_WAIST
	if t <= PYLON_CAP_START {
		return lerpf(shape.radius, waist, t / PYLON_CAP_START)
	}
	return waist * (1 - (t - PYLON_CAP_START) / (1 - PYLON_CAP_START))
}

// Smooth body without grain. The grid rasteriser uses this to decide whether
// a cell centre is inside the original silhouette.
pylon_sdf_hull :: proc(p: vec3, shape: Pylon_Shape) -> f32 {
	r := pylon_radius_at(p.z, shape)
	d_xy := pylon_sd_hex({p.x, p.y}, max(r, 0.001))
	half := shape.height * 0.5
	d_z := abs(p.z - half) - half
	outside := vec2{max(d_xy, 0), max(d_z, 0)}
	return min(max(d_xy, d_z), 0) + len_vec2(outside)
}

pylon_sdf_body :: proc(p: vec3, shape: Pylon_Shape) -> f32 {
	d := pylon_sdf_hull(p, shape)
	return d + pylon_grain_amp(shape) * (pylon_grain(p, shape) * 2 - 1)
}

// How far the true surface can lag behind the hull distance. The taper tilts
// the sides and the grain adds slope, so a naive full step overshoots and the
// marcher punches through thin walls.
pylon_step_scale :: proc(shape: Pylon_Shape) -> f32 {
	cap_slope := (shape.radius * PYLON_CAP_WAIST) / max((1 - PYLON_CAP_START) * shape.height, 0.01)
	taper := math.sqrt(1 + cap_slope * cap_slope)
	fbm_w := f32(0.65 + 0.35 * 2.13)
	grain_slope := 2.6 * (PYLON_GRAIN_AMP * 2) * PYLON_GRAIN_FREQ * fbm_w
	return 1 / (taper + grain_slope)
}

// Is this point on a mined face rather than on the pylon's original skin? Cut
// faces are shaded as raw exposed ore, which is the visual cue that a tower has
// been worked on.
PYLON_CUT_BODY :: f32(-0.02)

pylon_on_cut :: proc(p: vec3, shape: Pylon_Shape) -> bool {
	return pylon_sdf_body(p, shape) < PYLON_CUT_BODY
}

// ---------------------------------------------------------------------------
// Tracing

// Bound cylinder for a whole, untouched pylon.
pylon_bound_whole :: proc(shape: Pylon_Shape) -> (z0, z1, radius: f32) {
	amp := pylon_grain_amp(shape)
	return -amp, shape.height + amp, shape.radius + amp
}

// Clip a ray to a Z-aligned cylinder in local space. Twin of `pylon_bound_clip`
// in shaders/scene.glsl.
pylon_bound_clip :: proc(ro, rd: vec3, z0, z1, radius: f32, max_t: f32) -> (t0, t1: f32, hit: bool) {
	enter := f32(0)
	exit := max_t

	// Z slab.
	if abs(rd.z) < 1e-6 {
		if ro.z < z0 || ro.z > z1 {
			return 0, 0, false
		}
	} else {
		inv := 1 / rd.z
		a := (z0 - ro.z) * inv
		b := (z1 - ro.z) * inv
		if a > b {
			a, b = b, a
		}
		enter = max(enter, a)
		exit = min(exit, b)
	}

	// Infinite cylinder about the Z axis.
	qa := rd.x * rd.x + rd.y * rd.y
	qc := ro.x * ro.x + ro.y * ro.y - radius * radius
	if qa < 1e-12 {
		if qc > 0 {
			return 0, 0, false
		}
	} else {
		qb := ro.x * rd.x + ro.y * rd.y
		disc := qb * qb - qa * qc
		if disc < 0 {
			return 0, 0, false
		}
		root := math.sqrt(disc)
		enter = max(enter, (-qb - root) / qa)
		exit = min(exit, (-qb + root) / qa)
	}

	if enter > exit {
		return 0, 0, false
	}
	return max(enter, 0), exit, true
}
