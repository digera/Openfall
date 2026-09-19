package main

import "core:fmt"
import "core:math"

// Ore pylons: the seven mineable towers that replace the old capture points.
//
// A pylon is a standing body of ore. You break it with spells, it sheds chunks
// you can carry home, and it can be rebuilt back up to -- never past -- its
// original silhouette. Six belong to teams, two per team, one near the lane
// mouth and one far down it. The seventh is the golden pylon in the centre
// plaza: much tougher, owned by nobody, and the only source of gold.
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

// Ore accounting. One voxel-equivalent of removed rock is worth this much ore,
// scaled by how rich the vein is where the bite landed.
ORE_PER_VOXEL     :: f32(1.0)
ORE_VEIN_BONUS    :: f32(2.2)
// Ore accumulated before a carryable chunk pops out of the rock face.
ORE_PER_CHUNK     :: f32(8.0)

// Mining cadence. A held beam bites at a fixed rate rather than every tick:
// it keeps the carve event stream inside the snapshot budget, keeps the server
// and clients on the same small number of identical operations, and gives
// mining an audible rhythm instead of melting the rock smoothly.
MINE_BITE_HZ   :: f32(10.0)
MINE_BITE_DT   :: 1.0 / MINE_BITE_HZ
// Bite radius in cells, and the floor under it.
MINE_BITE_CELLS :: f32(2.4)
MINE_BITE_MIN_R :: f32(0.30)

// Connectivity is not cheap (81,920 voxels). Run it on a fixed cadence per
// pylon after it has been touched, not per carve.
PYLON_CONNECT_DT :: f32(0.12)

// An island this small is rubble, not a slab: it becomes chunks without any
// pretence of being a body.
PYLON_ISLAND_MIN_VOX :: 6

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
	ore_debt:      f32,
	last_miner:    Entity_ID,
	connect_timer: f32,
	// Where the most recent bite landed, so a chunk pops out of the right face.
	last_bite:     vec3,
	last_bite_n:   vec3,
}

Pylon_World :: struct {
	pylons: [MAX_PYLONS]Pylon,
	grids:  [MAX_PYLONS]^Ore_Grid,
	count:  int,

	// Bites, in the exact quantized form both the server and every client
	// apply. See pylon_net.odin.
	events:    [PYLON_EVENT_RING]Pylon_Carve_Event,
	event_head: int,
	next_seq:   u16,

	// Set when a pylon's density can no longer be reconstructed from the event
	// stream and has to be sent wholesale.
	resync: [MAX_PYLONS]bool,
}

// Connectivity scratch. One shared buffer: labelling is never reentrant, and a
// per-call 82 KB allocation on the server tick is not worth it.
@(private = "file") pylon_labels: [PYLON_VOX]u8

// The live pylon world. Both the server and the client keep one, and
// `world_point_free` consults it for collision, so it is reachable the same way
// the map boxes are.
g_pylons: ^Pylon_World

pylon_world_init :: proc(world: ^Pylon_World) {
	world.count = MAX_PYLONS
	world.next_seq = 1
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
		// Seed and yaw from the slot so every machine builds the same rock
		// without replicating a single byte of shape.
		h := hash_u32(u32(i) * 2654435761 + 17)
		p.shape.seed = f32(h & 0xFFFF) / f32(0x10000) * 8
		p.yaw = f32((h >> 16) & 0xFFFF) / f32(0x10000) * (2 * PI_F32)

		if world.grids[i] == nil {
			world.grids[i] = new(Ore_Grid)
		}
		ore_grid_build(world.grids[i], p.shape)
		p.bound_z0, p.bound_z1, p.bound_r = pylon_bound_whole(p.shape)
		p.intact = 1
	}
	g_pylons = world
	fmt.printf("[Pylon] %d ore pylons raised (%d voxels each, %.2f m cells)\n",
		MAX_PYLONS, PYLON_VOX, PYLON_CELL)
}

// Raise every pylon back to whole. Used on round reset.
pylon_world_reset :: proc(world: ^Pylon_World) {
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		ore_grid_build(world.grids[i], p.shape)
		p.bound_z0, p.bound_z1, p.bound_r = pylon_bound_whole(p.shape)
		p.intact = 1
		p.touched = false
		p.ore_debt = 0
		p.connect_timer = 0
		world.resync[i] = true
	}
	world.event_head = 0
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

// Nearest pylon along a ray. `t` is the distance to the surface.
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
		d := pylon_trace_local(local_ro, local_rd, p.shape, g, p.bound_z0, p.bound_z1, p.bound_r, best)
		if d >= 0 && d < best {
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
		dx := wp.x - p.base.x
		dy := wp.y - p.base.y
		reach := p.shape.radius * (1 + PYLON_GRAIN_AMP) + pad
		if dx * dx + dy * dy > reach * reach {
			continue
		}
		if wp.z < p.base.z - pad || wp.z > p.base.z + p.shape.height + pad {
			continue
		}
		if pylon_sdf_local(pylon_to_local(p, wp), p.shape, g) < pad {
			return true
		}
	}
	return false
}

// Surface normal at a world point, pointing out of the rock.
pylon_normal_world :: proc(world: ^Pylon_World, id: Pylon_ID, wp: vec3) -> vec3 {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil {
		return {0, 0, 1}
	}
	n := pylon_normal_local(pylon_to_local(p, wp), p.shape, g)
	return pylon_dir_to_world(p, n)
}

// Which pylon, if any, is occupying `wp`, and the way out of it. Used by
// `world_surface_normal` so anything that bounces off a tower bounces off the
// shape it has actually been mined into.
pylon_surface_normal :: proc(world: ^Pylon_World, wp: vec3, pad: f32) -> (n: vec3, ok: bool) {
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		g := world.grids[i]
		if g == nil || g.solid == 0 {
			continue
		}
		dx := wp.x - p.base.x
		dy := wp.y - p.base.y
		reach := p.shape.radius * (1 + PYLON_GRAIN_AMP) + pad
		if dx * dx + dy * dy > reach * reach {
			continue
		}
		local := pylon_to_local(p, wp)
		if pylon_sdf_local(local, p.shape, g) < pad {
			return pylon_dir_to_world(p, pylon_normal_local(local, p.shape, g)), true
		}
	}
	return {}, false
}

// Which pylon covers this point at all, for mining hit resolution.
pylon_at_point :: proc(world: ^Pylon_World, wp: vec3, pad: f32) -> (id: Pylon_ID, ok: bool) {
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		g := world.grids[i]
		if g == nil || g.solid == 0 {
			continue
		}
		dx := wp.x - p.base.x
		dy := wp.y - p.base.y
		reach := p.shape.radius * (1 + PYLON_GRAIN_AMP) + pad
		if dx * dx + dy * dy > reach * reach {
			continue
		}
		if pylon_sdf_local(pylon_to_local(p, wp), p.shape, g) < pad {
			return Pylon_ID(i), true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Carving

// Take a bite out of a pylon at a world point.
//
// `amount` is the density removed at the centre of the bite, before toughness.
// The bite is quantized before it is applied, and the same quantized numbers are
// both written to this grid and queued for the clients -- that is the only
// reason the two ever agree.
//
// Returns the ore earned, in whole-chunk currency, and whether anything gave.
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
	carve := ore_carve_quantize(local, radius, amount / max(p.tough, 0.01))
	lost, removed_q8 := ore_grid_erode(g, carve)
	if removed_q8 == 0 {
		return 0, false
	}
	pylon_record_event(world, id, carve)

	p.touched = true
	p.last_miner = miner
	p.last_bite = local
	p.last_bite_n = pylon_normal_local(local, p.shape, g)
	p.intact = ore_grid_intact(g)

	// Richer veins pay better, so the seams are worth learning.
	vein := pylon_vein(local, p.shape)
	voxels := f32(removed_q8) / 256
	ore = voxels * ORE_PER_VOXEL * (1 + vein * ORE_VEIN_BONUS)
	_ = lost
	return ore, true
}

// Put ore back. Minions rebuild with this; the deposit is clamped to the
// original body so a tower can only grow back into its own shape.
pylon_build :: proc(world: ^Pylon_World, id: Pylon_ID, at: vec3, radius, amount: f32) -> (gained: int, ok: bool) {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil || g == nil {
		return 0, false
	}
	local := pylon_to_local(p, at)
	carve := ore_carve_quantize(local, radius, amount)
	gained = ore_grid_deposit(g, carve)
	if gained == 0 && carve.amount == 0 {
		return 0, false
	}
	pylon_record_event(world, id, carve, build = true)
	p.intact = ore_grid_intact(g)
	p.touched = true
	return gained, true
}

// Apply a bite that arrived from the server. Cosmetic-only on the client: the
// server has already decided what broke and what it was worth.
pylon_apply_event :: proc(world: ^Pylon_World, ev: Pylon_Carve_Event) {
	p := pylon_get(world, ev.pylon)
	g := pylon_grid(world, ev.pylon)
	if p == nil || g == nil {
		return
	}
	if ev.build {
		ore_grid_deposit(g, ev.carve)
	} else {
		ore_grid_erode(g, ev.carve)
	}
	p.intact = ore_grid_intact(g)
	p.touched = true
}

// ---------------------------------------------------------------------------
// Structure

// Look for ore that is no longer attached to the ground and shed it.
//
// A pylon is rooted by its base, so the island that owns the lowest solid voxel
// is the trunk and everything else is falling, however big it is. That is the
// rule that makes undercutting a tower work: chew through the middle and the
// whole top comes down, rather than hanging in the air because it happens to be
// the larger piece.
pylon_check_structure :: proc(world: ^Pylon_World, id: Pylon_ID, chunks: ^Ore_Chunk_World) -> (shed_voxels: int) {
	p := pylon_get(world, id)
	g := pylon_grid(world, id)
	if p == nil || g == nil || g.solid == 0 {
		return 0
	}
	if g.checked == g.version {
		return 0
	}
	g.checked = g.version

	comps := ore_grid_components(g, pylon_labels[:])
	if len(comps) <= 1 {
		p.intact = ore_grid_intact(g)
		return 0
	}
	rooted := ore_grid_rooted_label(g, pylon_labels[:])
	if rooted == 0 {
		return 0
	}

	keep: [256]bool
	keep[rooted] = true
	for comp in comps {
		if comp.label == rooted {
			continue
		}
		shed_voxels += comp.count
		// Detached ore falls as carryable chunks rather than becoming another
		// voxel body. The towers are the sculpted objects; what comes off them
		// is cargo, and cargo has to be cheap enough to have dozens of.
		ore_chunk_burst(chunks, p, comp.centroid, comp.count)
	}
	if shed_voxels > 0 {
		ore_grid_keep_labels(g, pylon_labels[:], &keep)
		p.intact = ore_grid_intact(g)
		p.bound_z0, p.bound_z1, p.bound_r = ore_grid_bound(g)
		// The client cannot derive a collapse from the bite stream, so the
		// pylon has to be resent.
		world.resync[id] = true
		fmt.printf("[Pylon %d] %d voxels sheared off (%.0f%% standing)\n",
			id, shed_voxels, p.intact * 100)
	}
	return shed_voxels
}

// Per-frame upkeep: structural checks on a cadence, chunk payouts.
pylon_world_tick :: proc(world: ^Pylon_World, chunks: ^Ore_Chunk_World, dt: f32) {
	for i in 0 ..< world.count {
		p := &world.pylons[i]
		if !p.touched {
			continue
		}
		p.connect_timer -= dt
		if p.connect_timer <= 0 {
			p.connect_timer = PYLON_CONNECT_DT
			pylon_check_structure(world, Pylon_ID(i), chunks)
		}
		// Pay out accumulated ore as chunks bursting off the mined face.
		for p.ore_debt >= ORE_PER_CHUNK {
			p.ore_debt -= ORE_PER_CHUNK
			ore_chunk_spawn_at_face(chunks, p)
		}
	}
}

// Credit mined ore toward the next chunk that pops out of the face.
pylon_credit_ore :: proc(world: ^Pylon_World, id: Pylon_ID, ore: f32) {
	p := pylon_get(world, id)
	if p == nil {
		return
	}
	p.ore_debt += ore
}

// Total ore still locked up in a pylon, for the HUD.
pylon_reserve :: proc(world: ^Pylon_World, id: Pylon_ID) -> f32 {
	g := pylon_grid(world, id)
	if g == nil {
		return 0
	}
	return f32(g.solid) * ORE_PER_VOXEL
}
