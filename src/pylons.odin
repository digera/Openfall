package main

import "core:fmt"
import "core:math"

// Ore pylons: the seven mineable towers that replace the old capture points.
//
// A pylon is a standing stack of coarse ore cells. You break it with spells,
// remaining cells fall down their column, and minions can stack cells back up
// to -- never past -- the original height of that column. Six belong to teams,
// two per team, one near the lane mouth and one far down it. The seventh is
// the golden pylon in the centre plaza: much tougher, owned by nobody, and the
// only source of gold. The pretty rock is a client SDF of this occupancy.
//
// You cannot mine your own team's pylons. That is the whole shape of the mode:
// your towers are your ore reserve and someone else has to come take it.
//
// Pylons are not entities. They have no Entity_ID, no health bar and no hitbox
// in the character sense, which is exactly why targeted spells cannot touch
// them -- Call Lightning has nothing to lock onto and needs no special case.
// Only positional damage carves ore.

Pylon_ID :: u8
MAX_PYLONS :: 7

// The four currencies. One ore per team plus the gold that only the centre
// yields.
Ore_Kind :: enum u8 {
	None    = 0,
	Ember   = 1,  // Alpha
	Tide    = 2,  // Beta
	Verdant = 3,  // Gamma
	Gold    = 4,
}

ORE_COUNT :: 4

ore_index_of :: proc(kind: Ore_Kind) -> int {
	switch kind {
	case .Ember:   return 0
	case .Tide:    return 1
	case .Verdant: return 2
	case .Gold:    return 3
	case .None:    return -1
	}
	return -1
}

ore_from_index :: proc(i: int) -> Ore_Kind {
	switch i {
	case 0: return .Ember
	case 1: return .Tide
	case 2: return .Verdant
	case 3: return .Gold
	}
	return .None
}

ore_from_wire :: proc(v: u8) -> Ore_Kind {
	if v > u8(Ore_Kind.Gold) {
		return .None
	}
	return Ore_Kind(v)
}

// A team's own ore. Gold belongs to no team.
team_ore :: proc(team: Team_ID) -> Ore_Kind {
	switch team {
	case .Alpha: return .Ember
	case .Beta:  return .Tide
	case .Gamma: return .Verdant
	case .None, .Spectator: return .None
	}
	return .None
}

ore_team :: proc(kind: Ore_Kind) -> Team_ID {
	switch kind {
	case .Ember:   return .Alpha
	case .Tide:    return .Beta
	case .Verdant: return .Gamma
	case .Gold, .None: return .None
	}
	return .None
}

// Matches `ore_tint` in shaders/scene.glsl so the HUD reads in the same colours
// as the rock it is counting.
ore_color :: proc(kind: Ore_Kind) -> vec3 {
	switch kind {
	case .Ember:   return {1.00, 0.44, 0.24}
	case .Tide:    return {0.34, 0.68, 1.00}
	case .Verdant: return {0.42, 0.95, 0.52}
	case .Gold:    return {1.00, 0.82, 0.32}
	case .None:    return {0.55, 0.55, 0.58}
	}
	return {0.55, 0.55, 0.58}
}

ore_name :: proc(kind: Ore_Kind) -> string {
	switch kind {
	case .Ember:   return "ember"
	case .Tide:    return "tide"
	case .Verdant: return "verdant"
	case .Gold:    return "gold"
	case .None:    return "none"
	}
	return "none"
}

// ---------------------------------------------------------------------------
// Tuning

// Lane pylons are slim enough to walk around inside a 9 m lane; the golden one
// only has to fit the plaza.
PYLON_NEAR_HEIGHT :: f32(14.0)
PYLON_NEAR_RADIUS :: f32(2.4)
PYLON_FAR_HEIGHT  :: f32(12.0)
PYLON_FAR_RADIUS  :: f32(2.2)
PYLON_GOLD_HEIGHT :: f32(19.0)
PYLON_GOLD_RADIUS :: f32(3.6)

// Divides incoming carve amount. The golden pylon is meant to take a
// coordinated effort over minutes, not one player with a beam.
PYLON_TOUGHNESS_TEAM :: f32(1.0)
PYLON_TOUGHNESS_GOLD :: f32(4.5)

// Ore accounting. One killed cell is worth this much ore, scaled by how rich
// the vein is where the bite landed.
ORE_PER_VOXEL     :: f32(1.0)
ORE_VEIN_BONUS    :: f32(2.2)
// Ore accumulated before a carryable chunk pops out of the rock face.
ORE_PER_CHUNK     :: f32(8.0)

// Mining cadence. A held beam bites at a fixed rate rather than every tick,
// so mining has an audible rhythm instead of melting the rock smoothly.
MINE_BITE_HZ   :: f32(10.0)
MINE_BITE_DT   :: 1.0 / MINE_BITE_HZ
MINE_BITE_MIN_R :: f32(0.30)

MAX_SNAPSHOT_OCC_PYLONS :: 2

// ---------------------------------------------------------------------------

Pylon :: struct {
	id:    Pylon_ID,
	owner: Team_ID,   // .None for the golden pylon
	ore:   Ore_Kind,
	base:  vec3,      // world position of the base centre, on the floor
	yaw:   f32,       // rotation about Z, so the hexagons are not all aligned
	shape: Pylon_Shape,
	tough: f32,

	// Local-space bound cylinder of what is left standing. Shrinks as the pylon
	// is mined down so the marcher stops paying for empty air.
	bound_z0: f32,
	bound_z1: f32,
	bound_r:  f32,

	intact:  f32,  // 0..1 fraction of the original pylon still standing
	touched: bool,

	// Fractional ore owed to whoever is mining, paid out in whole chunks.
	ore_debt:   f32,
	last_miner: Entity_ID,
	// Where the most recent bite landed, so a chunk pops out of the right face.
	last_bite:   vec3,
	last_bite_n: vec3,
}

Pylon_World :: struct {
	pylons: [MAX_PYLONS]Pylon,
	grids:  [MAX_PYLONS]^Ore_Grid,
	count:  int,
	// Occupancy changed this tick: up to two go out in the 30 Hz snapshot.
	dirty: [MAX_PYLONS]bool,
}

// The live pylon world. Both the server and the client keep one, and
// `world_point_free` consults it for collision, so it is reachable the same way
// the map boxes are.
g_pylons: ^Pylon_World

pylon_world_init :: proc(world: ^Pylon_World) {
	world.count = MAX_PYLONS
	for i in 0 ..< MAX_PYLONS {
		p := &world.pylons[i]
		p^ = Pylon{}
		p.id = Pylon_ID(i)
		p.base = pylon_base_position(i)
		p.base.z = WORLD_FLOOR_Z

		if i == 0 {
			p.owner = .None
			p.ore = .Gold
			p.shape = {height = PYLON_GOLD_HEIGHT, radius = PYLON_GOLD_RADIUS}
			p.tough = PYLON_TOUGHNESS_GOLD
		} else if i <= 3 {
			p.owner = team_from_index(i - 1)
			p.ore = team_ore(p.owner)
			p.shape = {height = PYLON_NEAR_HEIGHT, radius = PYLON_NEAR_RADIUS}
			p.tough = PYLON_TOUGHNESS_TEAM
		} else {
			p.owner = team_from_index(i - 4)
			p.ore = team_ore(p.owner)
			p.shape = {height = PYLON_FAR_HEIGHT, radius = PYLON_FAR_RADIUS}
			p.tough = PYLON_TOUGHNESS_TEAM
		}
		h := hash_u32(u32(i) * 2654435761 + 17)
		p.shape.seed = f32(h & 0xFFFF) / f32(0x10000) * 8
		p.yaw = f32((h >> 16) & 0xFFFF) / f32(0x10000) * (2 * PI_F32)

		if world.grids[i] == nil {
			world.grids[i] = new(Ore_Grid)
		}
		ore_grid_build(world.grids[i], p.shape)
		p.bound_z0, p.bound_z1, p.bound_r = ore_grid_bound(world.grids[i])
		p.intact = 1
		world.dirty[i] = true
	}
	g_pylons = world
	ore_grid_selftest()
	fmt.printf("[Pylon] %d ore pylons raised (%d cells each, %.2f m)\n",
		MAX_PYLONS, PYLON_VOX, PYLON_CELL)
}

// Raise every pylon back to whole. Used on round reset.
pylon_world_reset :: proc(world: ^Pylon_World) {
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		ore_grid_build(world.grids[i], p.shape)
		p.bound_z0, p.bound_z1, p.bound_r = ore_grid_bound(world.grids[i])
		p.intact = 1
		p.touched = false
		p.ore_debt = 0
		world.dirty[i] = true
	}
}

@(private = "file")
pylon_touch :: proc(world: ^Pylon_World, p: ^Pylon, g: ^Ore_Grid) {
	p.intact = ore_grid_intact(g)
	p.bound_z0, p.bound_z1, p.bound_r = ore_grid_bound(g)
	p.touched = true
	world.dirty[p.id] = true
}

pylon_get :: proc(world: ^Pylon_World, id: Pylon_ID) -> ^Pylon {
	if int(id) >= world.count {
		return nil
	}
	return &world.pylons[id]
}

pylon_grid :: proc(world: ^Pylon_World, id: Pylon_ID) -> ^Ore_Grid {
	if int(id) >= world.count {
		return nil
	}
	return world.grids[id]
}

// Standing at all? A pylon mined to nothing is a stump waiting for minions.
pylon_standing :: proc(world: ^Pylon_World, id: Pylon_ID) -> bool {
	g := pylon_grid(world, id)
	return g != nil && g.solid > 0
}

// ---------------------------------------------------------------------------
// Frames

pylon_to_local :: proc(p: ^Pylon, world_pos: vec3) -> vec3 {
	d := world_pos - p.base
	s := math.sin(-p.yaw)
	c := math.cos(-p.yaw)
	return {c * d.x - s * d.y, s * d.x + c * d.y, d.z}
}

pylon_dir_to_local :: proc(p: ^Pylon, v: vec3) -> vec3 {
	s := math.sin(-p.yaw)
	c := math.cos(-p.yaw)
	return {c * v.x - s * v.y, s * v.x + c * v.y, v.z}
}

pylon_to_world :: proc(p: ^Pylon, local: vec3) -> vec3 {
	s := math.sin(p.yaw)
	c := math.cos(p.yaw)
	return p.base + vec3{c * local.x - s * local.y, s * local.x + c * local.y, local.z}
}

pylon_dir_to_world :: proc(p: ^Pylon, v: vec3) -> vec3 {
	s := math.sin(p.yaw)
	c := math.cos(p.yaw)
	return {c * v.x - s * v.y, s * v.x + c * v.y, v.z}
}

// ---------------------------------------------------------------------------
// Mining rules

// Your own towers are your ore reserve: you cannot chip them for a quick score,
// and you cannot demolish them to deny an enemy. The golden pylon is fair game
// for everyone.
pylon_mineable_by :: proc(p: ^Pylon, team: Team_ID) -> bool {
	if p.owner == .None {
		return true
	}
	return p.owner != team
}

// ---------------------------------------------------------------------------
// Tracing

pylon_cylinder_reject :: proc(p: ^Pylon, wp: vec3, pad: f32) -> bool {
	dx := wp.x - p.base.x
	dy := wp.y - p.base.y
	reach := p.bound_r + pad
	if reach <= 0 {
		reach = p.shape.radius + pad
	}
	if dx * dx + dy * dy > reach * reach {
		return true
	}
	if wp.z < p.base.z + p.bound_z0 - pad || wp.z > p.base.z + p.bound_z1 + pad {
		return true
	}
	return false
}

// Nearest pylon along a ray. `t` is the distance to the cell face.
pylon_raycast :: proc(world: ^Pylon_World, ro, rd: vec3, max_t: f32) -> (t: f32, id: Pylon_ID, hit: bool) {
	best := max_t
	found := -1
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		g := world.grids[i]
		if g == nil || g.solid == 0 {
			continue
		}
		local_ro := pylon_to_local(p, ro)
		local_rd := pylon_dir_to_local(p, rd)
		d, _, _, _, _, ok := ore_grid_raycast(g, local_ro, local_rd, best)
		if ok && d < best {
			best = d
			found = i
		}
	}
	if found < 0 {
		return 0, 0, false
	}
	return best, Pylon_ID(found), true
}

// Does a pylon occupy this point? Cheap cylinder reject first: this is on the
// movement solver's hot path, which probes several points per entity per tick.
pylon_blocks_point :: proc(world: ^Pylon_World, wp: vec3, pad: f32) -> bool {
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		g := world.grids[i]
		if g == nil || g.solid == 0 {
			continue
		}
		if pylon_cylinder_reject(p, wp, pad) {
			continue
		}
		if ore_grid_blocks_point(g, pylon_to_local(p, wp), pad) {
			return true
		}
	}
	return false
}

pylon_normal_world :: proc(world: ^Pylon_World, id: Pylon_ID, wp: vec3) -> vec3 {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil || g == nil {
		return {0, 0, 1}
	}
	n := ore_grid_normal(g, pylon_to_local(p, wp))
	return pylon_dir_to_world(p, n)
}

pylon_surface_normal :: proc(world: ^Pylon_World, wp: vec3, pad: f32) -> (n: vec3, ok: bool) {
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		g := world.grids[i]
		if g == nil || g.solid == 0 {
			continue
		}
		if pylon_cylinder_reject(p, wp, pad) {
			continue
		}
		local := pylon_to_local(p, wp)
		if ore_grid_blocks_point(g, local, pad) {
			return pylon_dir_to_world(p, ore_grid_normal(g, local)), true
		}
	}
	return {}, false
}

pylon_at_point :: proc(world: ^Pylon_World, wp: vec3, pad: f32) -> (id: Pylon_ID, ok: bool) {
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		g := world.grids[i]
		if g == nil || g.solid == 0 {
			continue
		}
		if pylon_cylinder_reject(p, wp, pad) {
			continue
		}
		if ore_grid_blocks_point(g, pylon_to_local(p, wp), pad) {
			return Pylon_ID(i), true
		}
	}
	return 0, false
}

// World position of the current top of the column nearest `wp`. Minions jump here.
pylon_column_top_world :: proc(world: ^Pylon_World, id: Pylon_ID, wp: vec3) -> (pos: vec3, ok: bool) {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil || g == nil {
		return {}, false
	}
	local := pylon_to_local(p, wp)
	x, y, _ := ore_local_to_cell(local)
	x = clamp_int(x, 0, PYLON_NX - 1)
	y = clamp_int(y, 0, PYLON_NY - 1)
	h := ore_grid_column_h(g, x, y)
	top := ore_voxel_center(x, y, max(h - 1, 0))
	if h == 0 {
		top.z = 0
	} else {
		top.z = f32(h) * PYLON_CELL
	}
	return pylon_to_world(p, top), true
}

// ---------------------------------------------------------------------------
// Carving

pylon_hp_loss :: proc(amount, tough: f32) -> u8 {
	n := int(math.round(amount / max(tough, 0.01) * f32(CELL_HP)))
	return u8(clamp_int(n, 1, int(CELL_HP)))
}

// Take a bite out of a pylon at a world point. Damages the hit cell and any
// neighbour whose centre is inside `radius`.
pylon_mine :: proc(
	world:  ^Pylon_World,
	id:     Pylon_ID,
	at:     vec3,
	radius: f32,
	amount: f32,
	miner:  Entity_ID,
	team:   Team_ID,
) -> (ore: f32, ok: bool) {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil || g == nil || g.solid == 0 {
		return 0, false
	}
	if !pylon_mineable_by(p, team) {
		return 0, false
	}

	local := pylon_to_local(p, at)
	cx, cy, cz := ore_local_to_cell(local)
	loss := pylon_hp_loss(amount, p.tough)
	reach := max(radius, MINE_BITE_MIN_R)
	reach2 := reach * reach
	removed := 0
	killed := 0
	hit_n := ore_grid_normal(g, local)

	x0 := clamp_int(cx - 1, 0, PYLON_NX - 1)
	x1 := clamp_int(cx + 1, 0, PYLON_NX - 1)
	y0 := clamp_int(cy - 1, 0, PYLON_NY - 1)
	y1 := clamp_int(cy + 1, 0, PYLON_NY - 1)
	z0 := clamp_int(cz - 1, 0, PYLON_NZ - 1)
	z1 := clamp_int(cz + 1, 0, PYLON_NZ - 1)
	for z := z1; z >= z0; z -= 1 {
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				c := ore_voxel_center(x, y, z)
				d := c - local
				if d.x * d.x + d.y * d.y + d.z * d.z > reach2 && !(x == cx && y == cy && z == cz) {
					continue
				}
				hp, dead := ore_grid_damage_cell(g, x, y, z, loss)
				removed += hp
				if dead {
					killed += 1
				}
			}
		}
	}
	if removed == 0 {
		return 0, false
	}

	p.last_miner = miner
	p.last_bite = local
	p.last_bite_n = hit_n
	pylon_touch(world, p, g)

	vein := pylon_vein(local, p.shape)
	cells := f32(killed) + f32(removed) / (f32(CELL_HP) * 4)
	ore = cells * ORE_PER_VOXEL * (1 + vein * ORE_VEIN_BONUS)
	return ore, true
}

// Put ore back on columns near `at`. Each column in radius gets HP on its top
// (or a new cell), capped at the original height.
pylon_build :: proc(world: ^Pylon_World, id: Pylon_ID, at: vec3, radius, amount: f32) -> (gained: int, ok: bool) {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil || g == nil {
		return 0, false
	}
	local := pylon_to_local(p, at)
	add := pylon_hp_loss(max(amount, 0.25), 1)
	reach := max(radius, PYLON_CELL)
	cx, cy, _ := ore_local_to_cell(local)
	span := int(math.ceil(reach / PYLON_CELL)) + 1
	x0 := clamp_int(cx - span, 0, PYLON_NX - 1)
	x1 := clamp_int(cx + span, 0, PYLON_NX - 1)
	y0 := clamp_int(cy - span, 0, PYLON_NY - 1)
	y1 := clamp_int(cy + span, 0, PYLON_NY - 1)
	r2 := reach * reach
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			c := ore_voxel_center(x, y, 0)
			dx := c.x - local.x
			dy := c.y - local.y
			if dx * dx + dy * dy > r2 {
				continue
			}
			gained += ore_grid_deposit_top(g, x, y, add)
		}
	}
	if gained == 0 {
		// Always try the nearest column so a hop on a stump still lands.
		gained += ore_grid_deposit_top(g, clamp_int(cx, 0, PYLON_NX - 1), clamp_int(cy, 0, PYLON_NY - 1), add)
	}
	if gained == 0 && add == 0 {
		return 0, false
	}
	pylon_touch(world, p, g)
	return gained, gained > 0 || add > 0
}

// Where the next rebuild donation should land, in the pylon's local frame.
// Lowest incomplete column height, then the golden angle around the axis so
// consecutive hops rebuild a column rather than a spine.
pylon_build_point :: proc(world: ^Pylon_World, id: Pylon_ID, turn: int) -> vec3 {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil || g == nil {
		return {}
	}
	best_h := PYLON_NZ
	z := p.shape.height * 0.5
	for y in 0 ..< PYLON_NY {
		for x in 0 ..< PYLON_NX {
			max_h := int(g.max_h[ore_col_index(x, y)])
			if max_h <= 0 {
				continue
			}
			h := ore_grid_column_h(g, x, y)
			if h < max_h && h < best_h {
				best_h = h
				z = (f32(h) + 0.5) * PYLON_CELL
			}
		}
	}
	a := f32(turn) * 2.39996
	r := pylon_radius_at(z, p.shape) * 0.45
	return {math.cos(a) * r, math.sin(a) * r, z}
}

// Install occupancy from the wire. HP is reconstructed as full-or-empty.
pylon_apply_occupancy :: proc(world: ^Pylon_World, id: Pylon_ID, heights: []u8) {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil || g == nil || len(heights) < PYLON_OCC_BYTES {
		return
	}
	if ore_grid_heights_equal(g, heights) {
		return
	}
	ore_grid_unpack_heights(g, heights)
	pylon_touch(world, p, g)
}

pylon_collect_dirty :: proc(world: ^Pylon_World, dst: []Pylon_ID) -> int {
	n := 0
	for i in 0 ..< world.count {
		if !world.dirty[i] {
			continue
		}
		if n >= len(dst) {
			break
		}
		dst[n] = Pylon_ID(i)
		n += 1
	}
	return n
}

pylon_clear_dirty :: proc(world: ^Pylon_World, ids: []Pylon_ID) {
	for id in ids {
		if int(id) < world.count {
			world.dirty[id] = false
		}
	}
}

// Per-frame upkeep: chunk payouts. Gravity is applied on the damage that
// caused it, not on a cadence.
pylon_world_tick :: proc(world: ^Pylon_World, chunks: ^Ore_Chunk_World, dt: f32) {
	_ = dt
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		if !p.touched {
			continue
		}
		for p.ore_debt >= ORE_PER_CHUNK {
			p.ore_debt -= ORE_PER_CHUNK
			ore_chunk_spawn_at_face(chunks, p)
		}
	}
}

pylon_credit_ore :: proc(world: ^Pylon_World, id: Pylon_ID, ore: f32) {
	p := pylon_get(world, id)
	if p == nil {
		return
	}
	p.ore_debt += ore
}

pylon_reserve :: proc(world: ^Pylon_World, id: Pylon_ID) -> f32 {
	g := pylon_grid(world, id)
	if g == nil {
		return 0
	}
	return f32(g.solid) * ORE_PER_VOXEL
}
