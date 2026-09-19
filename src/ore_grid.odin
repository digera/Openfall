package main

// Volumetric damage for ore pylons.
//
// Every pylon owns a density grid in its local frame: 255 = untouched ore,
// 0 = mined away. The rendered surface is the 0.5 iso of the trilinearly
// filtered density, intersected with the procedural body SDF (pylon_sdf.odin).
// Carving only ever removes density, so the body SDF stays the outer envelope
// and mining can never invent rock that was never there.
//
// The grid is not replicated. It is *reproduced*: the server sends quantized
// carve events and every client applies the identical kernel. That is only safe
// if the kernel is bit-exact on every machine, so `ore_grid_erode` contains no
// floating point at all -- positions, radii and amounts arrive as integers and
// stay integers until the density byte is written. Floats appear only in
// sampling and normals, which are cosmetic.
//
// The domain is deliberately not a cube. An obelisk is tall and thin, and a
// cube grid would spend most of its voxels on empty air while leaving the
// silhouette coarse in the one axis that reads.

PYLON_NX   :: 32
PYLON_NY   :: 32
PYLON_NZ   :: 80
PYLON_VOX  :: PYLON_NX * PYLON_NY * PYLON_NZ  // 81,920

// One cell is 25 cm. Chosen so the cell size is an exact fixed-point value and
// so broken chunks read as fist-to-boulder sized lumps rather than gravel.
PYLON_CELL   :: f32(0.25)
PYLON_HALF_X :: f32(PYLON_NX) * PYLON_CELL * 0.5  // 4 m
PYLON_HALF_Y :: f32(PYLON_NY) * PYLON_CELL * 0.5  // 4 m
PYLON_TALL   :: f32(PYLON_NZ) * PYLON_CELL        // 20 m

// A voxel counts as rock above this. Matching the 0.5 iso the marcher draws.
PYLON_SOLID :: u8(128)

// Fixed-point scale for the carve kernel: integer units per metre. 1024 keeps
// a whole grid coordinate exact (one cell is 256 units) and leaves room for
// squared distances across the domain to stay inside i32.
ORE_FX      :: i32(1024)
ORE_CELL_FX :: i32(256)  // PYLON_CELL * ORE_FX

// Local frame: X and Y are centred on the pylon axis, Z runs from 0 at the
// base to PYLON_TALL at the tip. Keeping Z one-sided means the base sits on the
// floor plane with no half-cell fudge.
ORE_ORIGIN_X_FX :: i32(PYLON_NX) * ORE_CELL_FX / 2  // 4096
ORE_ORIGIN_Y_FX :: i32(PYLON_NY) * ORE_CELL_FX / 2

Ore_Grid :: struct {
	density: [PYLON_VOX]u8,
	// Bit set: this voxel's centre is inside the procedural body. Rasterised
	// once at build so connectivity never has to evaluate noise again.
	body: [PYLON_VOX / 8]u8,

	body_solid: int,  // voxels solid in the untouched pylon; the "full" mass
	solid:      int,  // voxels solid right now, maintained incrementally
	version:    u32,  // bumped on every density change (GPU upload, resync)
	checked:    u32,  // version last examined for connectivity
}

// Versions come from one counter so a grid copied into a slot never repeats the
// version the GPU last saw there.
@(private = "file") ore_grid_serial: u32 = 1

ore_grid_bump :: proc(grid: ^Ore_Grid) {
	ore_grid_serial += 1
	grid.version = ore_grid_serial
}

ore_index :: #force_inline proc(x, y, z: int) -> int {
	return x + y * PYLON_NX + z * PYLON_NX * PYLON_NY
}

ore_unindex :: #force_inline proc(i: int) -> (x, y, z: int) {
	return i % PYLON_NX, (i / PYLON_NX) % PYLON_NY, i / (PYLON_NX * PYLON_NY)
}

// Voxel centre in fixed point. Exact: no rounding anywhere in the carve path.
ore_voxel_center_fx :: #force_inline proc(x, y, z: int) -> [3]i32 {
	return {
		i32(2 * x + 1) * (ORE_CELL_FX / 2) - ORE_ORIGIN_X_FX,
		i32(2 * y + 1) * (ORE_CELL_FX / 2) - ORE_ORIGIN_Y_FX,
		i32(2 * z + 1) * (ORE_CELL_FX / 2),
	}
}

ore_voxel_center :: #force_inline proc(x, y, z: int) -> vec3 {
	c := ore_voxel_center_fx(x, y, z)
	return {f32(c.x) / f32(ORE_FX), f32(c.y) / f32(ORE_FX), f32(c.z) / f32(ORE_FX)}
}

ore_body_bit :: #force_inline proc(grid: ^Ore_Grid, i: int) -> bool {
	return grid.body[i >> 3] & (1 << u8(i & 7)) != 0
}

// Rock for the purposes of connectivity and mass. The body bit is required so
// that a carve which merely grazes empty air cannot register as structure.
ore_is_solid :: #force_inline proc(grid: ^Ore_Grid, i: int) -> bool {
	return grid.density[i] > PYLON_SOLID && ore_body_bit(grid, i)
}

// ---------------------------------------------------------------------------
// Build

// Rasterise a fresh, untouched pylon. `shape` drives the silhouette; see
// pylon_sdf.odin.
ore_grid_build :: proc(grid: ^Ore_Grid, shape: Pylon_Shape) {
	ore_grid_bump(grid)
	grid.checked = 0
	grid.body_solid = 0
	grid.solid = 0
	// Density starts full everywhere, including outside the body. That looks
	// wrong and is load-bearing: the carve field must report "solid" wherever
	// nothing has been mined, or its half-cell band would fight the body SDF at
	// the pristine surface and shave the pylon thinner than its own silhouette.
	// The body bitmask, not the density, is what says where rock can exist --
	// which is why everything structural goes through `ore_is_solid`.
	for &d in grid.density {
		d = 255
	}
	for &b in grid.body {
		b = 0
	}

	// The grain displaces the surface by at most this much, so a voxel further
	// than `amp` from the smooth hull is decided without touching the noise.
	amp := pylon_grain_amp(shape)
	for z in 0 ..< PYLON_NZ {
		for y in 0 ..< PYLON_NY {
			for x in 0 ..< PYLON_NX {
				p := ore_voxel_center(x, y, z)
				hull := pylon_sdf_hull(p, shape)
				inside: bool
				if hull < -amp {
					inside = true
				} else if hull > amp {
					inside = false
				} else {
					inside = pylon_sdf_body(p, shape) < 0
				}
				if inside {
					i := ore_index(x, y, z)
					grid.body[i >> 3] |= 1 << u8(i & 7)
					grid.body_solid += 1
					grid.solid += 1
				}
			}
		}
	}
}

// Wipe every voxel. Used when a pylon is reduced to nothing and is waiting to
// be rebuilt.
ore_grid_clear :: proc(grid: ^Ore_Grid) {
	for &d in grid.density {
		d = 0
	}
	grid.solid = 0
	ore_grid_bump(grid)
}

// ---------------------------------------------------------------------------
// Sampling (cosmetic: floats are fine here)

// Trilinear density at a local point, matching the GPU's texel-centre sampling
// and clamp-to-edge so the CPU marcher and the shader agree on the surface.
ore_grid_sample :: proc(grid: ^Ore_Grid, p: vec3) -> f32 {
	tx := clampf(p.x / PYLON_CELL + f32(PYLON_NX) * 0.5 - 0.5, 0, f32(PYLON_NX) - 1)
	ty := clampf(p.y / PYLON_CELL + f32(PYLON_NY) * 0.5 - 0.5, 0, f32(PYLON_NY) - 1)
	tz := clampf(p.z / PYLON_CELL - 0.5, 0, f32(PYLON_NZ) - 1)
	x0 := int(tx)
	y0 := int(ty)
	z0 := int(tz)
	x1 := min(x0 + 1, PYLON_NX - 1)
	y1 := min(y0 + 1, PYLON_NY - 1)
	z1 := min(z0 + 1, PYLON_NZ - 1)
	fx := tx - f32(x0)
	fy := ty - f32(y0)
	fz := tz - f32(z0)
	d := &grid.density
	c00 := lerpf(f32(d[ore_index(x0, y0, z0)]), f32(d[ore_index(x1, y0, z0)]), fx)
	c10 := lerpf(f32(d[ore_index(x0, y1, z0)]), f32(d[ore_index(x1, y1, z0)]), fx)
	c01 := lerpf(f32(d[ore_index(x0, y0, z1)]), f32(d[ore_index(x1, y0, z1)]), fx)
	c11 := lerpf(f32(d[ore_index(x0, y1, z1)]), f32(d[ore_index(x1, y1, z1)]), fx)
	c0 := lerpf(c00, c10, fy)
	c1 := lerpf(c01, c11, fy)
	return lerpf(c0, c1, fz) / 255
}

// Signed "carve" distance: positive in removed space, ~0 on the mined face,
// negative in remaining ore. Only a true distance within about half a cell,
// which is why every marcher caps its step once inside the body.
ore_grid_carve_sdf :: proc(grid: ^Ore_Grid, p: vec3) -> f32 {
	return (0.5 - ore_grid_sample(grid, p)) * PYLON_CELL
}

// ---------------------------------------------------------------------------
// Carve (integer only -- must stay bit-exact across machines)

// A carve as it travels on the wire and as both sides apply it. Quantizing at
// the source and then eroding with the quantized values is what makes the
// server and a client reach the same density byte.
Ore_Carve :: struct {
	pos_fx:    [3]i32,  // local position, ORE_FX units per metre
	radius_fx: i32,     // ORE_FX units per metre
	amount:    u8,      // density removed at the centre, 0..255
}

// Wire form. Local coordinates are bounded by the grid domain so 16 bits at
// 1/1024 m is comfortable; radius rides in 1/64 m steps, amount in 1/255.
ORE_CARVE_RADIUS_STEP :: i32(16)  // ORE_FX / 64

ore_carve_quantize :: proc(local: vec3, radius: f32, amount: f32) -> Ore_Carve {
	q := Ore_Carve{}
	q.pos_fx = {
		i32(round_f32(local.x * f32(ORE_FX))),
		i32(round_f32(local.y * f32(ORE_FX))),
		i32(round_f32(local.z * f32(ORE_FX))),
	}
	steps := i32(round_f32(radius * f32(ORE_FX) / f32(ORE_CARVE_RADIUS_STEP)))
	q.radius_fx = clamp_i32(steps, 1, 255) * ORE_CARVE_RADIUS_STEP
	q.amount = u8(clamp_i32(i32(round_f32(amount * 255)), 0, 255))
	return q
}

ore_carve_radius_wire :: proc(c: Ore_Carve) -> u8 {
	return u8(clamp_i32(c.radius_fx / ORE_CARVE_RADIUS_STEP, 0, 255))
}

ore_carve_from_wire :: proc(x, y, z: i16, radius, amount: u8) -> Ore_Carve {
	return Ore_Carve{
		pos_fx    = {i32(x), i32(y), i32(z)},
		radius_fx = i32(radius) * ORE_CARVE_RADIUS_STEP,
		amount    = amount,
	}
}

// Erode a soft sphere of density.
//
// Falloff is `amount * (1 - d^2/r^2)^2`, the same shape as a smooth blast, done
// in Q16 fixed point. `lost` counts body voxels that crossed from rock to void;
// `removed_q8` is body density removed in 1/256ths of a voxel, which is what
// the ore yield is paid out of -- a scar that has not yet punched through still
// earns its ore.
ore_grid_erode :: proc(grid: ^Ore_Grid, c: Ore_Carve) -> (lost: int, removed_q8: i64) {
	if c.amount == 0 || c.radius_fx <= 0 {
		return 0, 0
	}

	// Voxel index range the sphere can touch. Integer division floors toward
	// zero for negatives, so bias into positive space first.
	lo: [3]int
	hi: [3]int
	origin_fx := [3]i32{ORE_ORIGIN_X_FX, ORE_ORIGIN_Y_FX, 0}
	dims := [3]int{PYLON_NX, PYLON_NY, PYLON_NZ}
	for k in 0 ..< 3 {
		a := c.pos_fx[k] - c.radius_fx + origin_fx[k]
		b := c.pos_fx[k] + c.radius_fx + origin_fx[k]
		lo[k] = clamp_int(int(div_floor_i32(a, ORE_CELL_FX)), 0, dims[k] - 1)
		hi[k] = clamp_int(int(div_floor_i32(b, ORE_CELL_FX)) + 1, 0, dims[k] - 1)
	}

	r2 := i64(c.radius_fx) * i64(c.radius_fx)
	if r2 == 0 {
		return 0, 0
	}
	changed := false
	for z in lo[2] ..= hi[2] {
		for y in lo[1] ..= hi[1] {
			for x in lo[0] ..= hi[0] {
				i := ore_index(x, y, z)
				was := grid.density[i]
				if was == 0 {
					continue
				}
				cen := ore_voxel_center_fx(x, y, z)
				dx := i64(cen.x - c.pos_fx.x)
				dy := i64(cen.y - c.pos_fx.y)
				dz := i64(cen.z - c.pos_fx.z)
				d2 := dx * dx + dy * dy + dz * dz
				if d2 >= r2 {
					continue
				}
				// k in Q16, then squared back down to Q16.
				k_q := ((r2 - d2) << 16) / r2
				k2_q := (k_q * k_q) >> 16
				// amount is already 0..255 == 0..1 scaled by 255, so
				// (amount/255 * k^2) * 255 is just amount * k^2.
				loss := (i64(c.amount) * k2_q) >> 16
				if loss <= 0 {
					continue
				}
				now := i64(was) - loss
				if now < 0 {
					now = 0
				}
				grid.density[i] = u8(now)
				changed = true

				if !ore_body_bit(grid, i) {
					continue
				}
				removed_q8 += ((i64(was) - now) << 8) / 255
				if was > PYLON_SOLID && grid.density[i] <= PYLON_SOLID {
					lost += 1
					grid.solid -= 1
				}
			}
		}
	}
	if changed {
		ore_grid_bump(grid)
	}
	return lost, removed_q8
}

// Restore density in a sphere, clamped to the original body. This is how
// minions rebuild: they can only put back ore that the pylon's own SDF says
// belongs there, so a rebuilt tower can never grow past its silhouette.
ore_grid_deposit :: proc(grid: ^Ore_Grid, c: Ore_Carve) -> (gained: int) {
	if c.amount == 0 || c.radius_fx <= 0 {
		return 0
	}
	lo: [3]int
	hi: [3]int
	origin_fx := [3]i32{ORE_ORIGIN_X_FX, ORE_ORIGIN_Y_FX, 0}
	dims := [3]int{PYLON_NX, PYLON_NY, PYLON_NZ}
	for k in 0 ..< 3 {
		a := c.pos_fx[k] - c.radius_fx + origin_fx[k]
		b := c.pos_fx[k] + c.radius_fx + origin_fx[k]
		lo[k] = clamp_int(int(div_floor_i32(a, ORE_CELL_FX)), 0, dims[k] - 1)
		hi[k] = clamp_int(int(div_floor_i32(b, ORE_CELL_FX)) + 1, 0, dims[k] - 1)
	}
	r2 := i64(c.radius_fx) * i64(c.radius_fx)
	if r2 == 0 {
		return 0
	}
	changed := false
	for z in lo[2] ..= hi[2] {
		for y in lo[1] ..= hi[1] {
			for x in lo[0] ..= hi[0] {
				i := ore_index(x, y, z)
				if !ore_body_bit(grid, i) {
					continue  // never build outside the original pylon
				}
				was := grid.density[i]
				if was == 255 {
					continue
				}
				cen := ore_voxel_center_fx(x, y, z)
				dx := i64(cen.x - c.pos_fx.x)
				dy := i64(cen.y - c.pos_fx.y)
				dz := i64(cen.z - c.pos_fx.z)
				d2 := dx * dx + dy * dy + dz * dz
				if d2 >= r2 {
					continue
				}
				k_q := ((r2 - d2) << 16) / r2
				k2_q := (k_q * k_q) >> 16
				add := (i64(c.amount) * k2_q) >> 16
				if add <= 0 {
					continue
				}
				now := i64(was) + add
				if now > 255 {
					now = 255
				}
				grid.density[i] = u8(now)
				changed = true
				if was <= PYLON_SOLID && grid.density[i] > PYLON_SOLID {
					gained += 1
					grid.solid += 1
				}
			}
		}
	}
	if changed {
		ore_grid_bump(grid)
	}
	return gained
}

// ---------------------------------------------------------------------------
// Connectivity

Ore_Component :: struct {
	count:    int,
	centroid: vec3,  // local space
	label:    u8,
}

// Label connected islands of remaining rock, largest first.
//
// The neighbourhood is the full 3x3x3, i.e. 26-connected: a diagonal sliver of
// ore still counts as attached. Using 6-connectivity here makes towers shed
// pieces that visibly still touch, which reads as a bug.
ore_grid_components :: proc(grid: ^Ore_Grid, labels: []u8, allocator := context.temp_allocator) -> []Ore_Component {
	assert(len(labels) == PYLON_VOX)
	for &l in labels {
		l = 0
	}
	stack := make([dynamic]i32, 0, 8192, allocator)
	comps := make([dynamic]Ore_Component, 0, 8, allocator)
	next: u8 = 1
	for start in 0 ..< PYLON_VOX {
		if labels[start] != 0 || !ore_is_solid(grid, start) {
			continue
		}
		if next == 255 {
			break
		}
		label := next
		next += 1
		comp := Ore_Component{label = label}
		sum := vec3{}
		clear(&stack)
		append(&stack, i32(start))
		labels[start] = label
		for len(stack) > 0 {
			i := int(pop(&stack))
			x, y, z := ore_unindex(i)
			comp.count += 1
			sum += ore_voxel_center(x, y, z)
			for nz in max(0, z - 1) ..= min(PYLON_NZ - 1, z + 1) {
				for ny in max(0, y - 1) ..= min(PYLON_NY - 1, y + 1) {
					for nx in max(0, x - 1) ..= min(PYLON_NX - 1, x + 1) {
						j := ore_index(nx, ny, nz)
						if labels[j] != 0 || !ore_is_solid(grid, j) {
							continue
						}
						labels[j] = label
						append(&stack, i32(j))
					}
				}
			}
		}
		comp.centroid = sum / f32(max(comp.count, 1))
		append(&comps, comp)
	}
	// Largest first: the biggest island is the one that stays standing.
	for i in 1 ..< len(comps) {
		j := i
		for j > 0 && comps[j].count > comps[j - 1].count {
			comps[j], comps[j - 1] = comps[j - 1], comps[j]
			j -= 1
		}
	}
	return comps[:]
}

// Which island is still standing on the ground. A pylon is rooted by its base,
// so the component owning the lowest solid voxels is the trunk and everything
// else is falling debris -- regardless of which is larger.
ore_grid_rooted_label :: proc(grid: ^Ore_Grid, labels: []u8) -> u8 {
	for z in 0 ..< PYLON_NZ {
		for y in 0 ..< PYLON_NY {
			for x in 0 ..< PYLON_NX {
				i := ore_index(x, y, z)
				if labels[i] != 0 && ore_is_solid(grid, i) {
					return labels[i]
				}
			}
		}
	}
	return 0
}

// Drop every voxel not in `keep` from this grid.
ore_grid_keep_labels :: proc(grid: ^Ore_Grid, labels: []u8, keep: ^[256]bool) {
	solid := 0
	for i in 0 ..< PYLON_VOX {
		l := labels[i]
		if l != 0 && !keep[l] {
			grid.density[i] = 0
		}
		if ore_is_solid(grid, i) {
			solid += 1
		}
	}
	grid.solid = solid
	ore_grid_bump(grid)
	grid.checked = grid.version
}

ore_grid_solid_count :: proc(grid: ^Ore_Grid) -> int {
	n := 0
	for i in 0 ..< PYLON_VOX {
		if ore_is_solid(grid, i) {
			n += 1
		}
	}
	return n
}

// Fraction of the untouched pylon still standing, 0..1.
ore_grid_intact :: proc(grid: ^Ore_Grid) -> f32 {
	if grid.body_solid <= 0 {
		return 0
	}
	return f32(grid.solid) / f32(grid.body_solid)
}

ORE_VOXEL_VOLUME :: PYLON_CELL * PYLON_CELL * PYLON_CELL

// Radius of a sphere with the same volume as `count` voxels. Used to size the
// chunks that fall off so a lump of ore looks as heavy as it is.
ore_grid_equivalent_radius :: proc(count: int) -> f32 {
	v := f32(count) * ORE_VOXEL_VOLUME
	return pow_f32(v * 3 / (4 * PI_F32), 1.0 / 3.0)
}

// Tight bound around the remaining rock: a Z-aligned cylinder.
//
// A sphere is the wrong shape for an obelisk. A whole 14 m pylon needs a 7.5 m
// bound sphere to hold a body only 2.8 m across, and a mined-down stump needs an
// even bigger one because the sphere is centred on where the tip used to be.
// Every pixel on screen tests every pylon, so that slack is paid for constantly.
// A cylinder fits both the tower and the stump, and clipping a ray against one
// is no more expensive.
//
// This has to test `ore_is_solid`, not raw density. Voxels outside the body are
// left at 255 on purpose -- see `ore_grid_build` -- so a density-only test would
// call the whole domain rock and the bound would never shrink.
ore_grid_bound :: proc(grid: ^Ore_Grid) -> (z0, z1, radius: f32) {
	r2: f32
	lo := f32(1e9)
	hi := f32(-1e9)
	any := false
	for i in 0 ..< PYLON_VOX {
		if !ore_is_solid(grid, i) {
			continue
		}
		x, y, z := ore_unindex(i)
		c := ore_voxel_center(x, y, z)
		r2 = max(r2, c.x * c.x + c.y * c.y)
		lo = min(lo, c.z)
		hi = max(hi, c.z)
		any = true
	}
	if !any {
		return 0, 0, 0
	}
	// Pad by a voxel diagonal: the bound has to contain the interpolated
	// surface, which sits up to half a cell outside the last solid centre.
	pad := SQRT3_F32 * PYLON_CELL
	return lo - pad, hi + pad, sqrt_f32(r2) + pad
}

// ---------------------------------------------------------------------------
// Checksum + run-length coding for resync

// Cheap order-independent-per-voxel digest of the density field. Sent with the
// pylon state so a client can notice it has drifted from the server and ask for
// the affected pylon again.
ore_grid_checksum :: proc(grid: ^Ore_Grid) -> u32 {
	h := u32(2166136261)
	for d in grid.density {
		h = (h ~ u32(d)) * 16777619
	}
	return h
}

// Encode density as (value, run length) pairs. An untouched pylon is one run,
// and even a heavily mined one is mostly long runs of 255 and 0, so a full
// resync is a few hundred bytes rather than 80 KB.
ore_grid_rle_encode :: proc(grid: ^Ore_Grid, dst: []u8) -> (n: int, ok: bool) {
	i := 0
	for i < PYLON_VOX {
		v := grid.density[i]
		run := 1
		for i + run < PYLON_VOX && grid.density[i + run] == v && run < 0xFFFF {
			run += 1
		}
		if n + 3 > len(dst) {
			return n, false
		}
		dst[n] = v
		dst[n + 1] = u8(run & 0xFF)
		dst[n + 2] = u8(run >> 8)
		n += 3
		i += run
	}
	return n, true
}

ore_grid_rle_decode :: proc(grid: ^Ore_Grid, src: []u8) -> bool {
	i := 0
	at := 0
	for i + 3 <= len(src) {
		v := src[i]
		run := int(src[i + 1]) | int(src[i + 2]) << 8
		i += 3
		if run == 0 || at + run > PYLON_VOX {
			return false
		}
		for k in 0 ..< run {
			grid.density[at + k] = v
		}
		at += run
	}
	if at != PYLON_VOX {
		return false
	}
	solid := 0
	for k in 0 ..< PYLON_VOX {
		if ore_is_solid(grid, k) {
			solid += 1
		}
	}
	grid.solid = solid
	ore_grid_bump(grid)
	grid.checked = grid.version
	return true
}
