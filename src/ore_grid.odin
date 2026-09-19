package main

import "core:math"

// Coarse occupancy for ore pylons.
//
// Authority is an 8x8x20 HP grid, one metre cells, packed to the floor in each
// column. The pretty rock is a client shader of this occupancy; it is not
// replicated and the server never marches it. Gravity forbids holes, so the
// wire form is just 64 column heights.
//
// This grid is the collision surface. The visual SDF can sit a little further
// out (grain), and PYLON_COLLIDE_SLACK is the pad that keeps them aligned.

PYLON_NX  :: 8
PYLON_NY  :: 8
PYLON_NZ  :: 20
PYLON_VOX :: PYLON_NX * PYLON_NY * PYLON_NZ  // 1,280

PYLON_CELL   :: f32(1.0)
PYLON_HALF_X :: f32(PYLON_NX) * PYLON_CELL * 0.5  // 4 m
PYLON_HALF_Y :: f32(PYLON_NY) * PYLON_CELL * 0.5  // 4 m
PYLON_TALL   :: f32(PYLON_NZ) * PYLON_CELL        // 20 m

// A few bites to kill a cell. Gold divides incoming damage by toughness, so
// the centre still takes a coordinated effort.
CELL_HP :: u8(8)

// Occupancy on the wire: one height byte per column. Gravity packs every
// column to z = 0, so this is the whole occupancy.
PYLON_OCC_BYTES :: PYLON_NX * PYLON_NY  // 64

// Extra radius around a cell AABB so the visual iso (up to half a cell out)
// is not walkable air.
PYLON_COLLIDE_SLACK :: f32(0.35)

Ore_Grid :: struct {
	hp:    [PYLON_VOX]u8,
	max_h: [PYLON_NX * PYLON_NY]u8,  // original layers this column may hold
	body_solid: int,
	solid:      int,
	version:    u32,
}

@(private = "file") ore_grid_serial: u32 = 1

ore_grid_bump :: proc(grid: ^Ore_Grid) {
	ore_grid_serial += 1
	grid.version = ore_grid_serial
}

ore_index :: #force_inline proc(x, y, z: int) -> int {
	return x + y * PYLON_NX + z * PYLON_NX * PYLON_NY
}

ore_col_index :: #force_inline proc(x, y: int) -> int {
	return x + y * PYLON_NX
}

ore_unindex :: #force_inline proc(i: int) -> (x, y, z: int) {
	return i % PYLON_NX, (i / PYLON_NX) % PYLON_NY, i / (PYLON_NX * PYLON_NY)
}

ore_voxel_center :: #force_inline proc(x, y, z: int) -> vec3 {
	return {
		(f32(x) + 0.5) * PYLON_CELL - PYLON_HALF_X,
		(f32(y) + 0.5) * PYLON_CELL - PYLON_HALF_Y,
		(f32(z) + 0.5) * PYLON_CELL,
	}
}

ore_grid_in_bounds :: #force_inline proc(x, y, z: int) -> bool {
	return x >= 0 && x < PYLON_NX && y >= 0 && y < PYLON_NY && z >= 0 && z < PYLON_NZ
}

ore_grid_occupied :: #force_inline proc(grid: ^Ore_Grid, x, y, z: int) -> bool {
	return ore_grid_in_bounds(x, y, z) && grid.hp[ore_index(x, y, z)] > 0
}

ore_grid_column_h :: proc(grid: ^Ore_Grid, x, y: int) -> int {
	if x < 0 || x >= PYLON_NX || y < 0 || y >= PYLON_NY {
		return 0
	}
	h := 0
	for z in 0 ..< PYLON_NZ {
		if grid.hp[ore_index(x, y, z)] == 0 {
			break
		}
		h += 1
	}
	return h
}

ore_local_to_cell :: proc(p: vec3) -> (x, y, z: int) {
	x = int(math.floor(p.x / PYLON_CELL + f32(PYLON_NX) * 0.5))
	y = int(math.floor(p.y / PYLON_CELL + f32(PYLON_NY) * 0.5))
	z = int(math.floor(p.z / PYLON_CELL))
	return
}

// ---------------------------------------------------------------------------
// Build

ore_grid_build :: proc(grid: ^Ore_Grid, shape: Pylon_Shape) {
	ore_grid_bump(grid)
	grid.body_solid = 0
	grid.solid = 0
	for &h in grid.hp {
		h = 0
	}
	for &m in grid.max_h {
		m = 0
	}

	for y in 0 ..< PYLON_NY {
		for x in 0 ..< PYLON_NX {
			max_z := -1
			for z in 0 ..< PYLON_NZ {
				c := ore_voxel_center(x, y, z)
				if pylon_sdf_hull(c, shape) < 0 {
					max_z = z
				}
			}
			if max_z < 0 {
				continue
			}
			layers := u8(max_z + 1)
			grid.max_h[ore_col_index(x, y)] = layers
			for z in 0 ..= max_z {
				grid.hp[ore_index(x, y, z)] = CELL_HP
				grid.body_solid += 1
				grid.solid += 1
			}
		}
	}
}

ore_grid_clear :: proc(grid: ^Ore_Grid) {
	for &h in grid.hp {
		h = 0
	}
	grid.solid = 0
	ore_grid_bump(grid)
}

ore_grid_intact :: proc(grid: ^Ore_Grid) -> f32 {
	if grid.body_solid <= 0 {
		return 0
	}
	return f32(grid.solid) / f32(grid.body_solid)
}

ore_grid_recount :: proc(grid: ^Ore_Grid) {
	n := 0
	for i in 0 ..< PYLON_VOX {
		if grid.hp[i] > 0 {
			n += 1
		}
	}
	grid.solid = n
}

// ---------------------------------------------------------------------------
// Gravity: pack a column down onto the floor.

ore_grid_compact_column :: proc(grid: ^Ore_Grid, x, y: int) -> bool {
	if x < 0 || x >= PYLON_NX || y < 0 || y >= PYLON_NY {
		return false
	}
	write := 0
	moved := false
	for z in 0 ..< PYLON_NZ {
		src := ore_index(x, y, z)
		hp := grid.hp[src]
		if hp == 0 {
			continue
		}
		if write != z {
			grid.hp[ore_index(x, y, write)] = hp
			grid.hp[src] = 0
			moved = true
		}
		write += 1
	}
	return moved
}

ore_grid_compact_all :: proc(grid: ^Ore_Grid) -> bool {
	moved := false
	for y in 0 ..< PYLON_NY {
		for x in 0 ..< PYLON_NX {
			if ore_grid_compact_column(grid, x, y) {
				moved = true
			}
		}
	}
	if moved {
		ore_grid_recount(grid)
		ore_grid_bump(grid)
	}
	return moved
}

// ---------------------------------------------------------------------------
// Damage / build

// Subtract HP at (x,y,z) and compact that column. Returns HP actually removed
// and whether a cell died.
ore_grid_damage_cell :: proc(grid: ^Ore_Grid, x, y, z: int, loss: u8) -> (removed: int, killed: bool) {
	if loss == 0 || !ore_grid_in_bounds(x, y, z) {
		return 0, false
	}
	i := ore_index(x, y, z)
	was := grid.hp[i]
	if was == 0 {
		return 0, false
	}
	now := was
	if loss >= now {
		now = 0
	} else {
		now -= loss
	}
	grid.hp[i] = now
	removed = int(was - now)
	if now == 0 {
		killed = true
		grid.solid -= 1
		ore_grid_compact_column(grid, x, y)
	}
	ore_grid_bump(grid)
	return removed, killed
}

// Add HP to the top of column (x,y), or a new cell on top, capped at max_h.
ore_grid_deposit_top :: proc(grid: ^Ore_Grid, x, y: int, add: u8) -> (gained: int) {
	if add == 0 || x < 0 || x >= PYLON_NX || y < 0 || y >= PYLON_NY {
		return 0
	}
	max_h := int(grid.max_h[ore_col_index(x, y)])
	if max_h <= 0 {
		return 0
	}
	h := ore_grid_column_h(grid, x, y)
	if h > 0 {
		top := ore_index(x, y, h - 1)
		was := grid.hp[top]
		if was < CELL_HP {
			room := CELL_HP - was
			put := add
			if put > room {
				put = room
			}
			grid.hp[top] = was + put
			ore_grid_bump(grid)
			return 0
		}
	}
	if h >= max_h {
		return 0
	}
	put := add
	if put > CELL_HP {
		put = CELL_HP
	}
	grid.hp[ore_index(x, y, h)] = put
	grid.solid += 1
	ore_grid_bump(grid)
	return 1
}

// ---------------------------------------------------------------------------
// Wire: column heights

ore_grid_pack_heights :: proc(grid: ^Ore_Grid, dst: []u8) {
	assert(len(dst) >= PYLON_OCC_BYTES)
	for y in 0 ..< PYLON_NY {
		for x in 0 ..< PYLON_NX {
			dst[ore_col_index(x, y)] = u8(ore_grid_column_h(grid, x, y))
		}
	}
}

ore_grid_unpack_heights :: proc(grid: ^Ore_Grid, src: []u8) {
	assert(len(src) >= PYLON_OCC_BYTES)
	for &h in grid.hp {
		h = 0
	}
	solid := 0
	for y in 0 ..< PYLON_NY {
		for x in 0 ..< PYLON_NX {
			h := min(int(src[ore_col_index(x, y)]), int(grid.max_h[ore_col_index(x, y)]), PYLON_NZ)
			for z in 0 ..< h {
				grid.hp[ore_index(x, y, z)] = CELL_HP
				solid += 1
			}
		}
	}
	grid.solid = solid
	ore_grid_bump(grid)
}

ore_grid_heights_equal :: proc(grid: ^Ore_Grid, src: []u8) -> bool {
	if len(src) < PYLON_OCC_BYTES {
		return false
	}
	for y in 0 ..< PYLON_NY {
		for x in 0 ..< PYLON_NX {
			if u8(ore_grid_column_h(grid, x, y)) != src[ore_col_index(x, y)] {
				return false
			}
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Collision / tracing

ore_grid_bound :: proc(grid: ^Ore_Grid) -> (z0, z1, radius: f32) {
	r2: f32
	lo := f32(1e9)
	hi := f32(-1e9)
	any := false
	for i in 0 ..< PYLON_VOX {
		if grid.hp[i] == 0 {
			continue
		}
		x, y, z := ore_unindex(i)
		c := ore_voxel_center(x, y, z)
		r2 = max(r2, c.x * c.x + c.y * c.y)
		lo = min(lo, c.z - PYLON_CELL * 0.5)
		hi = max(hi, c.z + PYLON_CELL * 0.5)
		any = true
	}
	if !any {
		return 0, 0, 0
	}
	pad := PYLON_CELL * 0.5 + PYLON_COLLIDE_SLACK
	return lo, hi, sqrt_f32(r2) + pad
}

ore_grid_blocks_point :: proc(grid: ^Ore_Grid, p: vec3, pad: f32) -> bool {
	reach := pad + PYLON_COLLIDE_SLACK
	x0, y0, z0 := ore_local_to_cell(p - vec3{reach, reach, reach})
	x1, y1, z1 := ore_local_to_cell(p + vec3{reach, reach, reach})
	x0 = clamp_int(x0, 0, PYLON_NX - 1)
	y0 = clamp_int(y0, 0, PYLON_NY - 1)
	z0 = clamp_int(z0, 0, PYLON_NZ - 1)
	x1 = clamp_int(x1, 0, PYLON_NX - 1)
	y1 = clamp_int(y1, 0, PYLON_NY - 1)
	z1 = clamp_int(z1, 0, PYLON_NZ - 1)
	half := PYLON_CELL * 0.5 + reach
	for z in z0 ..= z1 {
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				if grid.hp[ore_index(x, y, z)] == 0 {
					continue
				}
				c := ore_voxel_center(x, y, z)
				if abs(p.x - c.x) <= half && abs(p.y - c.y) <= half && abs(p.z - c.z) <= half {
					return true
				}
			}
		}
	}
	return false
}

// Outward normal of the nearest occupied cell face at `p`.
ore_grid_normal :: proc(grid: ^Ore_Grid, p: vec3) -> vec3 {
	x, y, z := ore_local_to_cell(p)
	x = clamp_int(x, 0, PYLON_NX - 1)
	y = clamp_int(y, 0, PYLON_NY - 1)
	z = clamp_int(z, 0, PYLON_NZ - 1)
	c := ore_voxel_center(x, y, z)
	d := p - c
	ax := abs(d.x)
	ay := abs(d.y)
	az := abs(d.z)
	if ax >= ay && ax >= az {
		return {d.x >= 0 ? 1 : -1, 0, 0}
	}
	if ay >= az {
		return {0, d.y >= 0 ? 1 : -1, 0}
	}
	return {0, 0, d.z >= 0 ? 1 : -1}
}

@(private = "file")
ore_ray_aabb :: proc(ro, rd, bmin, bmax: vec3, max_t: f32) -> (t0, t1: f32, hit: bool) {
	t0 = 0
	t1 = max_t
	for k in 0 ..< 3 {
		o := ro[k]
		d := rd[k]
		lo := bmin[k]
		hi := bmax[k]
		if abs(d) < 1e-8 {
			if o < lo || o > hi {
				return 0, 0, false
			}
			continue
		}
		inv := 1 / d
		a := (lo - o) * inv
		b := (hi - o) * inv
		if a > b {
			a, b = b, a
		}
		t0 = max(t0, a)
		t1 = min(t1, b)
		if t0 > t1 {
			return 0, 0, false
		}
	}
	return t0, t1, true
}

// First occupied cell along a local-space ray. `n` is the face that was hit.
ore_grid_raycast :: proc(
	grid: ^Ore_Grid,
	ro, rd: vec3,
	max_t: f32,
) -> (t: f32, x, y, z: int, n: vec3, hit: bool) {
	if grid.solid == 0 || len2_vec3(rd) < 1e-12 {
		return 0, 0, 0, 0, {}, false
	}
	bmin := vec3{-PYLON_HALF_X, -PYLON_HALF_Y, 0}
	bmax := vec3{PYLON_HALF_X, PYLON_HALF_Y, PYLON_TALL}
	t0, t1, ok := ore_ray_aabb(ro, rd, bmin, bmax, max_t)
	if !ok {
		return 0, 0, 0, 0, {}, false
	}

	p := ro + rd * (t0 + 1e-4)
	gx, gy, gz := ore_local_to_cell(p)
	gx = clamp_int(gx, 0, PYLON_NX - 1)
	gy = clamp_int(gy, 0, PYLON_NY - 1)
	gz = clamp_int(gz, 0, PYLON_NZ - 1)

	step_x := rd.x >= 0 ? 1 : -1
	step_y := rd.y >= 0 ? 1 : -1
	step_z := rd.z >= 0 ? 1 : -1

	next_x := rd.x >= 0 ? (f32(gx + 1) * PYLON_CELL - PYLON_HALF_X) : (f32(gx) * PYLON_CELL - PYLON_HALF_X)
	next_y := rd.y >= 0 ? (f32(gy + 1) * PYLON_CELL - PYLON_HALF_Y) : (f32(gy) * PYLON_CELL - PYLON_HALF_Y)
	next_z := rd.z >= 0 ? (f32(gz + 1) * PYLON_CELL) : (f32(gz) * PYLON_CELL)

	t_max_x := abs(rd.x) < 1e-8 ? f32(1e30) : (next_x - ro.x) / rd.x
	t_max_y := abs(rd.y) < 1e-8 ? f32(1e30) : (next_y - ro.y) / rd.y
	t_max_z := abs(rd.z) < 1e-8 ? f32(1e30) : (next_z - ro.z) / rd.z
	t_del_x := abs(rd.x) < 1e-8 ? f32(1e30) : PYLON_CELL / abs(rd.x)
	t_del_y := abs(rd.y) < 1e-8 ? f32(1e30) : PYLON_CELL / abs(rd.y)
	t_del_z := abs(rd.z) < 1e-8 ? f32(1e30) : PYLON_CELL / abs(rd.z)

	face := vec3{}
	entered := t0
	for _ in 0 ..< PYLON_NX + PYLON_NY + PYLON_NZ + 4 {
		if ore_grid_occupied(grid, gx, gy, gz) {
			return max(entered, 0), gx, gy, gz, face, true
		}
		if t_max_x < t_max_y {
			if t_max_x < t_max_z {
				entered = t_max_x
				if entered > t1 {
					break
				}
				gx += step_x
				t_max_x += t_del_x
				face = {f32(-step_x), 0, 0}
				if gx < 0 || gx >= PYLON_NX {
					break
				}
			} else {
				entered = t_max_z
				if entered > t1 {
					break
				}
				gz += step_z
				t_max_z += t_del_z
				face = {0, 0, f32(-step_z)}
				if gz < 0 || gz >= PYLON_NZ {
					break
				}
			}
		} else {
			if t_max_y < t_max_z {
				entered = t_max_y
				if entered > t1 {
					break
				}
				gy += step_y
				t_max_y += t_del_y
				face = {0, f32(-step_y), 0}
				if gy < 0 || gy >= PYLON_NY {
					break
				}
			} else {
				entered = t_max_z
				if entered > t1 {
					break
				}
				gz += step_z
				t_max_z += t_del_z
				face = {0, 0, f32(-step_z)}
				if gz < 0 || gz >= PYLON_NZ {
					break
				}
			}
		}
	}
	return 0, 0, 0, 0, {}, false
}

ORE_VOXEL_VOLUME :: PYLON_CELL * PYLON_CELL * PYLON_CELL

ore_grid_equivalent_radius :: proc(count: int) -> f32 {
	v := f32(count) * ORE_VOXEL_VOLUME
	return pow_f32(v * 3 / (4 * PI_F32), 1.0 / 3.0)
}

// Column drop, rebuild cap, and pack/unpack. Runs once when pylons come up.
ore_grid_selftest :: proc() {
	g: Ore_Grid
	shape := Pylon_Shape{height = PYLON_NEAR_HEIGHT, radius = PYLON_NEAR_RADIUS, seed = 1}
	ore_grid_build(&g, shape)
	assert(g.solid > 0)
	assert(g.solid == g.body_solid)

	cx, cy, h0 := 0, 0, 0
	for y in 0 ..< PYLON_NY {
		for x in 0 ..< PYLON_NX {
			h := ore_grid_column_h(&g, x, y)
			if h > h0 {
				cx, cy, h0 = x, y, h
			}
		}
	}
	assert(h0 >= 2)

	_, killed := ore_grid_damage_cell(&g, cx, cy, 0, CELL_HP)
	assert(killed)
	h1 := ore_grid_column_h(&g, cx, cy)
	assert(h1 == h0 - 1)
	for z in 0 ..< h1 {
		assert(g.hp[ore_index(cx, cy, z)] > 0)
	}
	assert(g.hp[ore_index(cx, cy, h1)] == 0)

	for z := h1 - 1; z >= 0; z -= 1 {
		ore_grid_damage_cell(&g, cx, cy, z, CELL_HP)
	}
	assert(ore_grid_column_h(&g, cx, cy) == 0)

	max_h := int(g.max_h[ore_col_index(cx, cy)])
	assert(max_h > 0)
	for _ in 0 ..< max_h {
		gained := ore_grid_deposit_top(&g, cx, cy, CELL_HP)
		assert(gained == 1)
	}
	assert(ore_grid_column_h(&g, cx, cy) == max_h)
	assert(ore_grid_deposit_top(&g, cx, cy, CELL_HP) == 0)
	assert(ore_grid_column_h(&g, cx, cy) == max_h)

	wire: [PYLON_OCC_BYTES]u8
	ore_grid_pack_heights(&g, wire[:])
	g2: Ore_Grid
	g2.max_h = g.max_h
	ore_grid_unpack_heights(&g2, wire[:])
	assert(ore_grid_heights_equal(&g2, wire[:]))
	assert(pylon_hp_loss(1, PYLON_TOUGHNESS_GOLD) < pylon_hp_loss(1, PYLON_TOUGHNESS_TEAM))
	{
		own: Pylon
		own.owner = .Alpha
		assert(!pylon_mineable_by(&own, .Alpha))
		assert(pylon_mineable_by(&own, .Beta))
		own.owner = .None
		assert(pylon_mineable_by(&own, .Alpha))
	}
}
