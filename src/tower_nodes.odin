package main

import "core:fmt"
import "core:math"
import "core:slice"

// Spiral shield-node tower authority.
//
// Gameplay is an array of overlapping ore nodes wrapped around a thin core.
// Node_ID is identity; spiral rank is derived from a sort on remaining HP
// (high HP at the bottom, damaged nodes rise). Hits address the Node_ID found
// at the impact point, never the slot, so a re-sort cannot hop damage onto a
// neighbour mid-bite. Core height matches the live node column (floor to the
// current cap) and is not synced. Minion hops restore a handful of nodes,
// scaled by the wave's own-ore bolster, so a flattened lane still takes about
// three unbuffed waves.
//
// The client draws this geometry analytically (core cylinder + node spheres).
// Chip scars live in the shader. See TOWERS.md.

// ---------------------------------------------------------------------------
// Tuning

MAX_NODES_PER_TOWER :: 32
TOWER_NODES_GOLD    :: 24
TOWER_NODES_NEAR    :: 12
TOWER_NODES_FAR     :: 12

#assert(TOWER_NODES_GOLD <= MAX_NODES_PER_TOWER)
#assert(TOWER_NODES_NEAR <= MAX_NODES_PER_TOWER)
#assert(TOWER_NODES_FAR  <= MAX_NODES_PER_TOWER)

// Thin last-stand column. Nodes are the destructible shell; this is what is
// left in the gaps once the shell is gone, not a fat pillar that swallows rays.
CORE_RADIUS :: f32(0.55)

// Phyllotaxis on a cylinder. Consecutive ranks are a golden step apart, so
// neighbours in space are Fibonacci parastichies -- overlapping blobs, not a
// string of beads with walkable holes.
SPIRAL_GOLDEN_ANGLE :: f32(2.399963229728653)

// Node spheres are one course of the column: they sit on the floor, kiss the
// cap, and wrap the core. Radius is a fraction of the full-tower pitch so a
// kill shortens the silhouette by one course instead of popping a boulder that
// was hanging through the floor. Must stay in lockstep with shaders/scene.glsl.
TOWER_NODE_RADIUS_STEPS :: f32(1.42)
TOWER_NODE_WRAP         :: f32(0.20)

// HP is in "amount" units after toughness. A team bite is 0.60, gold divides
// by 4.5, so these take a couple of seconds of beam per node rather than a
// minute, and a focused player can still drop a lane tower in a fight.
NODE_HP_TEAM :: f32(12.0)
NODE_HP_GOLD :: f32(16.0)

// Ore from a fully mined node. Fraction of HP removed pays out as you chip,
// so a bite that does not kill still sheds rock.
NODE_ORE_TEAM :: f32(8.0)
NODE_ORE_GOLD :: f32(18.0)

// Unbolstered hop restores two nodes: three fodder over three waves put back
// 6, which is half of a 12-node lane tower. Own-ore extra lets a farming team
// do it in one or two waves without a single hop rebuilding the whole thing.
TOWER_DONATE_BASE      :: 2
TOWER_DONATE_OWN_EXTRA :: 2

// Shader scars, not occupancy. Four is enough for a focused beam plus a
// couple of splash nicks; the shader reads this many per tower.
TOWER_WOUND_MAX :: 4
#assert(TOWER_WOUND_MAX * MAX_PYLONS == 28)

// ---------------------------------------------------------------------------
// Types

Node_ID :: u16

Tower_Node :: struct {
	id:     Node_ID,
	hp:     f32,
	max_hp: f32,
	alive:  bool,
}

// Client-visual bite mark, tower-local. Collision ignores this; the shader
// powders the face so a chip reads before the node dies.
Tower_Wound :: struct {
	pos:    vec3,
	radius: f32,
}

Tower :: struct {
	pylon_id: Pylon_ID,
	base:     vec3,
	yaw:      f32,
	owner:    Team_ID,
	ore:      Ore_Kind,
	tough:    f32,
	seed:     f32,

	design_height: f32,
	design_radius: f32,
	node_radius:   f32,
	spiral_radius: f32,
	stack_step:    f32,

	nodes:        [MAX_NODES_PER_TOWER]Tower_Node,
	live_count:   int,
	max_count:    int,
	next_node_id: Node_ID,

	// rank 0 = highest HP. Sorting is for internal bookkeeping only;
	// spiral position is a stable function of array index, not rank.
	sorted_indices: [MAX_NODES_PER_TOWER]int,

	core_height: f32,
	intact:      f32,
	version:     u32,

	ore_debt:   f32,
	last_miner: Entity_ID,
	last_bite:  vec3,
	last_bite_n: vec3,

	wounds:      [TOWER_WOUND_MAX]Tower_Wound,
	wound_count: int,

	touched: bool,
}

Tower_World :: struct {
	towers: [MAX_PYLONS]Tower,
	count:  int,
	dirty:  [MAX_PYLONS]bool,
}

g_towers: ^Tower_World

@(private = "file") tower_serial: u32 = 1

// ---------------------------------------------------------------------------
// Init / Reset

tower_world_init :: proc(world: ^Tower_World) {
	world.count = MAX_PYLONS
	for i in 0 ..< MAX_PYLONS {
		t := &world.towers[i]
		t^ = Tower{}
		t.pylon_id = Pylon_ID(i)
		t.base = pylon_base_position(i)
		t.base.z = WORLD_FLOOR_Z
		tower_configure(t, i)
		tower_build_full(t)
		world.dirty[i] = true
	}
	g_towers = world
	tower_selftest()
	fmt.printf("[Tower] %d shield-node towers (gold %d, near %d, far %d)\n",
		MAX_PYLONS, TOWER_NODES_GOLD, TOWER_NODES_NEAR, TOWER_NODES_FAR)
}

tower_world_reset :: proc(world: ^Tower_World) {
	for i in 0 ..< world.count {
		t := &world.towers[i]
		tower_build_full(t)
		t.touched = false
		t.ore_debt = 0
		world.dirty[i] = true
	}
}

@(private = "file")
tower_configure :: proc(t: ^Tower, i: int) {
	if i == 0 {
		t.owner = .None
		t.ore = .Gold
		t.tough = PYLON_TOUGHNESS_GOLD
		t.max_count = TOWER_NODES_GOLD
		t.design_height = PYLON_GOLD_HEIGHT
		t.design_radius = PYLON_GOLD_RADIUS
	} else if i <= 3 {
		t.owner = team_from_index(i - 1)
		t.ore = team_ore(t.owner)
		t.tough = PYLON_TOUGHNESS_TEAM
		t.max_count = TOWER_NODES_NEAR
		t.design_height = PYLON_NEAR_HEIGHT
		t.design_radius = PYLON_NEAR_RADIUS
	} else {
		t.owner = team_from_index(i - 4)
		t.ore = team_ore(t.owner)
		t.tough = PYLON_TOUGHNESS_TEAM
		t.max_count = TOWER_NODES_FAR
		t.design_height = PYLON_FAR_HEIGHT
		t.design_radius = PYLON_FAR_RADIUS
	}
	tower_layout(t)
	h := hash_u32(u32(i) * 2654435761 + 17)
	t.seed = f32(h & 0xFFFF) / f32(0x10000) * 8
	t.yaw = f32((h >> 16) & 0xFFFF) / f32(0x10000) * (2 * PI_F32)
}

// Floor-to-cap packing for a full tower. Rank 0 sits on the floor, the last
// rank kisses the design height, and the live column is that stack truncated
// from the top as nodes die.
@(private = "file")
tower_layout :: proc(t: ^Tower) {
	n := t.max_count
	if n < 1 {
		n = 1
	}
	pitch := t.design_height / f32(n)
	r := pitch * TOWER_NODE_RADIUS_STEPS
	cap := t.design_height * 0.35
	if r > cap {
		r = cap
	}
	t.node_radius = r
	if n > 1 {
		t.stack_step = (t.design_height - 2 * r) / f32(n - 1)
	} else {
		t.stack_step = t.design_height
	}
	t.spiral_radius = CORE_RADIUS + r * TOWER_NODE_WRAP
}

tower_column_height :: proc(t: ^Tower, live: int) -> f32 {
	if live <= 0 {
		return 0
	}
	if live == 1 {
		h := 2 * t.node_radius
		if h > t.design_height {
			return t.design_height
		}
		return h
	}
	return 2 * t.node_radius + f32(live - 1) * t.stack_step
}

tower_build_full :: proc(t: ^Tower) {
	t.live_count = 0
	t.next_node_id = 1
	hp := t.ore == .Gold ? NODE_HP_GOLD : NODE_HP_TEAM
	for i in 0 ..< t.max_count {
		node := &t.nodes[i]
		node.id = t.next_node_id
		t.next_node_id += 1
		if t.next_node_id == 0 {
			t.next_node_id = 1
		}
		node.hp = hp
		node.max_hp = hp
		node.alive = true
		t.live_count += 1
	}
	for i in t.max_count ..< MAX_NODES_PER_TOWER {
		t.nodes[i] = {}
	}
	tower_recompute(t)
	tower_resort_nodes(t)
	tower_clear_wounds(t)
	tower_bump(t)
}

tower_recompute :: proc(t: ^Tower) {
	t.core_height = tower_column_height(t, t.live_count)
	t.intact = t.max_count > 0 ? f32(t.live_count) / f32(t.max_count) : 0
}

@(private = "file")
tower_bump :: proc(t: ^Tower) {
	tower_serial += 1
	if tower_serial == 0 {
		tower_serial = 1
	}
	t.version = tower_serial
}

@(private = "file")
tower_touch :: proc(world: ^Tower_World, t: ^Tower) {
	t.touched = true
	world.dirty[t.pylon_id] = true
	tower_bump(t)
}

// ---------------------------------------------------------------------------
// Geometry

tower_outer_radius :: proc(t: ^Tower) -> f32 {
	return t.spiral_radius + t.node_radius
}

// Node spiral position from ARRAY INDEX (stable), not rank (HP-sorted).
// Critical fix: damage and death must not move geometry. Holes stay where you aimed.
tower_node_spiral_pos :: proc(t: ^Tower, array_index: int) -> vec3 {
	if array_index < 0 || array_index >= t.max_count {
		return {}
	}
	z := t.node_radius + f32(array_index) * t.stack_step
	angle := f32(array_index) * SPIRAL_GOLDEN_ANGLE
	return {math.cos(angle) * t.spiral_radius, math.sin(angle) * t.spiral_radius, z}
}

tower_node_world_pos :: proc(t: ^Tower, array_index: int) -> vec3 {
	return tower_to_world(t, tower_node_spiral_pos(t, array_index))
}

tower_to_world :: proc(t: ^Tower, local: vec3) -> vec3 {
	s := math.sin(t.yaw)
	c := math.cos(t.yaw)
	return t.base + vec3{c * local.x - s * local.y, s * local.x + c * local.y, local.z}
}

tower_dir_to_world :: proc(t: ^Tower, v: vec3) -> vec3 {
	s := math.sin(t.yaw)
	c := math.cos(t.yaw)
	return {c * v.x - s * v.y, s * v.x + c * v.y, v.z}
}

tower_to_local :: proc(t: ^Tower, world_pos: vec3) -> vec3 {
	d := world_pos - t.base
	s := math.sin(-t.yaw)
	c := math.cos(-t.yaw)
	return {c * d.x - s * d.y, s * d.x + c * d.y, d.z}
}

tower_dir_to_local :: proc(t: ^Tower, v: vec3) -> vec3 {
	s := math.sin(-t.yaw)
	c := math.cos(-t.yaw)
	return {c * v.x - s * v.y, s * v.x + c * v.y, v.z}
}

// ---------------------------------------------------------------------------
// Sorting

Tower_Node_Sort_Key :: struct {
	hp:      f32,
	node_id: Node_ID,
	index:   int,
}

tower_resort_nodes :: proc(t: ^Tower) {
	keys: [MAX_NODES_PER_TOWER]Tower_Node_Sort_Key
	n := 0
	for i in 0 ..< t.max_count {
		if t.nodes[i].alive {
			keys[n] = {hp = t.nodes[i].hp, node_id = t.nodes[i].id, index = i}
			n += 1
		}
	}
	t.live_count = n
	if n > 1 {
		slice.sort_by(keys[:n], proc(a, b: Tower_Node_Sort_Key) -> bool {
			if a.hp != b.hp {
				return a.hp > b.hp
			}
			return a.node_id < b.node_id
		})
	}
	for rank in 0 ..< n {
		t.sorted_indices[rank] = keys[rank].index
	}
	for rank in n ..< MAX_NODES_PER_TOWER {
		t.sorted_indices[rank] = -1
	}
}

tower_node_at_rank :: proc(t: ^Tower, rank: int) -> ^Tower_Node {
	if rank < 0 || rank >= t.live_count {
		return nil
	}
	idx := t.sorted_indices[rank]
	if idx < 0 || idx >= t.max_count {
		return nil
	}
	return &t.nodes[idx]
}

// ---------------------------------------------------------------------------
// Queries

tower_get :: proc(world: ^Tower_World, id: Pylon_ID) -> ^Tower {
	if int(id) >= world.count {
		return nil
	}
	return &world.towers[id]
}

tower_standing :: proc(world: ^Tower_World, id: Pylon_ID) -> bool {
	t := tower_get(world, id)
	return t != nil && t.live_count > 0
}

tower_mineable_by :: proc(t: ^Tower, team: Team_ID) -> bool {
	if t.owner == .None {
		return true
	}
	return t.owner != team
}

tower_node_ore :: proc(t: ^Tower) -> f32 {
	return t.ore == .Gold ? NODE_ORE_GOLD : NODE_ORE_TEAM
}

// Remaining HP over the original full tower, including chips. `intact` is
// still live_count / max_count for scoring and rebuild; this is what the
// shader and HUD use so a grind reads before the first node dies.
tower_mass_frac :: proc(t: ^Tower) -> f32 {
	if t == nil || t.max_count <= 0 {
		return 0
	}
	sum: f32 = 0
	cap: f32 = 0
	for i in 0 ..< t.max_count {
		cap += max(t.nodes[i].max_hp, 0)
		if t.nodes[i].alive {
			sum += max(t.nodes[i].hp, 0)
		}
	}
	if cap <= 0.01 {
		return t.intact
	}
	return clampf(sum / cap, 0, 1)
}

tower_clear_wounds :: proc(t: ^Tower) {
	t.wounds = {}
	t.wound_count = 0
}

// Two quant steps of the 8-bit wire. Pack/unpack of the same HP must not look
// like a chip, or every snapshot would stamp a scar.
tower_hp_wire_eps :: proc(max_hp: f32) -> f32 {
	return max(max_hp, 0.01) * (2.0 / 255.0)
}

// Outer skin of a node, away from the core. Mining from a lane hits this
// face, so a scar stamped here stays on the beam even after the damaged
// node rises up the spiral.
tower_node_outward_face :: proc(t: ^Tower, center: vec3) -> vec3 {
	xy := vec3{center.x, center.y, 0}
	if len2_vec3(xy) < 0.0001 {
		return center + vec3{t.node_radius, 0, 0}
	}
	return center + norm_vec3(xy) * t.node_radius
}

tower_stamp_wound :: proc(t: ^Tower, pos: vec3, radius: f32) {
	if t == nil || t.node_radius < 0.05 {
		return
	}
	r := clampf(radius, t.node_radius * 0.18, t.node_radius * 0.80)
	merge_r := t.node_radius * 0.70
	merge_r2 := merge_r * merge_r
	for i in 0 ..< t.wound_count {
		w := &t.wounds[i]
		d := pos - w.pos
		if d.x * d.x + d.y * d.y + d.z * d.z <= merge_r2 {
			w.pos = {(w.pos.x + pos.x) * 0.5, (w.pos.y + pos.y) * 0.5, (w.pos.z + pos.z) * 0.5}
			w.radius = min(t.node_radius * 0.80, w.radius + r * 0.40)
			return
		}
	}
	if t.wound_count < TOWER_WOUND_MAX {
		t.wounds[t.wound_count] = {pos, r}
		t.wound_count += 1
		return
	}
	smallest := 0
	for i in 1 ..< TOWER_WOUND_MAX {
		if t.wounds[i].radius < t.wounds[smallest].radius {
			smallest = i
		}
	}
	t.wounds[smallest] = {pos, r}
}

tower_donate_count :: proc(build_r: f32) -> int {
	extra := clampf((build_r - MINION_BUILD_RADIUS) / max(OWN_ORE_BUILD_GAIN, 0.01), 0, 1)
	n := TOWER_DONATE_BASE + int(math.round(extra * f32(TOWER_DONATE_OWN_EXTRA)))
	if n < 1 {
		return 1
	}
	return n
}

tower_node_at_point :: proc(t: ^Tower, wp: vec3, pad: f32) -> (node_id: Node_ID, array_index: int, ok: bool) {
	local := tower_to_local(t, wp)
	reach := t.node_radius + pad
	reach2 := reach * reach
	best_d2 := reach2
	best_index := -1
	best_id := Node_ID(0)
	for idx in 0 ..< t.max_count {
		node := &t.nodes[idx]
		if !node.alive {
			continue
		}
		pos := tower_node_spiral_pos(t, idx)
		dx := local.x - pos.x
		dy := local.y - pos.y
		dz := local.z - pos.z
		d2 := dx * dx + dy * dy + dz * dz
		if d2 <= best_d2 {
			best_d2 = d2
			best_index = idx
			best_id = node.id
		}
	}
	if best_index < 0 {
		return 0, -1, false
	}
	return best_id, best_index, true
}

tower_in_bound :: proc(t: ^Tower, wp: vec3, pad: f32) -> bool {
	dx := wp.x - t.base.x
	dy := wp.y - t.base.y
	max_r := tower_outer_radius(t) + pad
	if dx * dx + dy * dy > max_r * max_r {
		return false
	}
	if wp.z < t.base.z - pad || wp.z > t.base.z + t.core_height + pad {
		return false
	}
	return true
}

tower_blocks_point :: proc(world: ^Tower_World, wp: vec3, pad: f32) -> bool {
	for i in 0 ..< world.count {
		t := &world.towers[i]
		if t.live_count == 0 {
			continue
		}
		if !tower_in_bound(t, wp, pad) {
			continue
		}
		local := tower_to_local(t, wp)
		core_r := CORE_RADIUS + pad
		if local.z >= -pad && local.z <= t.core_height + pad {
			if local.x * local.x + local.y * local.y <= core_r * core_r {
				return true
			}
		}
		if _, _, hit := tower_node_at_point(t, wp, pad); hit {
			return true
		}
	}
	return false
}

tower_raycast :: proc(world: ^Tower_World, ro, rd: vec3, max_t: f32) -> (t: f32, id: Pylon_ID, node_id: Node_ID, hit: bool) {
	rd_len := len_vec3(rd)
	if rd_len < 1e-8 {
		return 0, 0, 0, false
	}
	rdn := rd / rd_len
	best := max_t
	found_tower := -1
	found_node := Node_ID(0)

	for i in 0 ..< world.count {
		tw := &world.towers[i]
		if tw.live_count == 0 {
			continue
		}
		local_ro := tower_to_local(tw, ro)
		local_rd := tower_dir_to_local(tw, rdn)
		outer := tower_outer_radius(tw)
		_, _, clip_hit := tower_bound_clip(local_ro, local_rd, -0.02, tw.core_height + 0.02, outer, best)
		if !clip_hit {
			continue
		}

		for idx in 0 ..< tw.max_count {
			node := &tw.nodes[idx]
			if !node.alive {
				continue
			}
			center := tower_node_world_pos(tw, idx)
			if d, ok := ray_sphere_hit(ro, rdn, center, tw.node_radius, best); ok {
				best = d
				found_tower = i
				found_node = node.id
			}
		}
		if tw.core_height > 0.01 {
			if d, ok := ray_cylinder_hit(ro, rdn, tw.base, CORE_RADIUS, tw.core_height, best); ok {
				best = d
				found_tower = i
				found_node = 0
			}
		}
	}

	if found_tower < 0 {
		return 0, 0, 0, false
	}
	return best, Pylon_ID(found_tower), found_node, true
}

tower_bound_clip :: proc(ro, rd: vec3, z0, z1, radius: f32, max_t: f32) -> (t0, t1: f32, hit: bool) {
	enter := f32(0)
	exit := max_t

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

tower_normal_world :: proc(world: ^Tower_World, id: Pylon_ID, wp: vec3) -> vec3 {
	t := tower_get(world, id)
	if t == nil {
		return {0, 0, 1}
	}
	local := tower_to_local(t, wp)

	_, idx, ok := tower_node_at_point(t, wp, t.node_radius)
	if ok {
		pos := tower_node_spiral_pos(t, idx)
		d := local - pos
		if len2_vec3(d) > 0.01 {
			return tower_dir_to_world(t, norm_vec3(d))
		}
	}

	if local.z >= 0 && local.z <= t.core_height {
		n := norm_vec3(vec3{local.x, local.y, 0})
		if len2_vec3(n) > 0.01 {
			return tower_dir_to_world(t, n)
		}
	}
	return {0, 0, 1}
}

tower_column_top_world :: proc(world: ^Tower_World, id: Pylon_ID, wp: vec3) -> (pos: vec3, ok: bool) {
	t := tower_get(world, id)
	if t == nil {
		return {}, false
	}
	local := tower_to_local(t, wp)
	local.z = t.core_height
	return tower_to_world(t, local), true
}

tower_at_point :: proc(world: ^Tower_World, wp: vec3, pad: f32) -> (id: Pylon_ID, ok: bool) {
	for i in 0 ..< world.count {
		t := &world.towers[i]
		if t.live_count == 0 {
			continue
		}
		if !tower_in_bound(t, wp, pad) {
			continue
		}
		local := tower_to_local(t, wp)
		core_r := CORE_RADIUS + pad
		if local.z >= -pad && local.z <= t.core_height + pad {
			if local.x * local.x + local.y * local.y <= core_r * core_r {
				return Pylon_ID(i), true
			}
		}
		if _, _, hit := tower_node_at_point(t, wp, pad); hit {
			return Pylon_ID(i), true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Mining / rebuild

tower_mine :: proc(
	world:  ^Tower_World,
	id:     Pylon_ID,
	at:     vec3,
	radius: f32,
	amount: f32,
	miner:  Entity_ID,
	team:   Team_ID,
) -> (ore: f32, ok: bool) {
	t := tower_get(world, id)
	if t == nil || t.live_count == 0 {
		return 0, false
	}
	if !tower_mineable_by(t, team) {
		return 0, false
	}

	local := tower_to_local(t, at)
	damage := amount / max(t.tough, 0.01)
	reach := max(radius, t.node_radius * 1.15)
	reach2 := reach * reach

	// Collect hit nodes by array index. Killing a node must not shorten the
	// loop, and geometry is stable (does not move when HP changes).
	hit_idx: [MAX_NODES_PER_TOWER]int
	n_hit := 0
	for idx in 0 ..< t.max_count {
		node := &t.nodes[idx]
		if !node.alive {
			continue
		}
		pos := tower_node_spiral_pos(t, idx)
		dx := local.x - pos.x
		dy := local.y - pos.y
		dz := local.z - pos.z
		if dx * dx + dy * dy + dz * dz > reach2 {
			continue
		}
		hit_idx[n_hit] = idx
		n_hit += 1
	}

	if n_hit == 0 {
		// Projectile and beam stops sit a hair short of the surface. Snap onto
		// the nearest live node so a core graze or a near miss still bites.
		fallback2 := (reach + t.node_radius) * (reach + t.node_radius)
		best_i := -1
		best_d2 := fallback2
		for idx in 0 ..< t.max_count {
			node := &t.nodes[idx]
			if !node.alive {
				continue
			}
			pos := tower_node_spiral_pos(t, idx)
			dx := local.x - pos.x
			dy := local.y - pos.y
			dz := local.z - pos.z
			d2 := dx * dx + dy * dy + dz * dz
			if d2 < best_d2 {
				best_d2 = d2
				best_i = idx
			}
		}
		if best_i >= 0 {
			hit_idx[0] = best_i
			n_hit = 1
		}
	}

	if n_hit == 0 {
		return 0, false
	}

	removed: f32 = 0
	killed := 0
	hit_n := vec3{0, 0, 1}
	for i in 0 ..< n_hit {
		idx := hit_idx[i]
		if idx < 0 || idx >= t.max_count {
			continue
		}
		node := &t.nodes[idx]
		if !node.alive {
			continue
		}
		before := node.hp
		node.hp -= damage
		if node.hp < 0 {
			node.hp = 0
		}
		lost := before - node.hp
		if lost <= 0 {
			continue
		}
		removed += lost
		// Ore payout is 1:1 with node death, not fractionally on chips.
		// Chips still damage HP and show scars for immediate feedback.
		if node.hp <= 0 {
			node.alive = false
			killed += 1
			ore += tower_node_ore(t)
		}
	}

	if removed <= 0 {
		return 0, false
	}

	t.last_miner = miner
	t.last_bite = local
	if _, idx, node_ok := tower_node_at_point(t, at, t.node_radius * 2); node_ok {
		pos := tower_node_spiral_pos(t, idx)
		d := local - pos
		if len2_vec3(d) > 0.01 {
			hit_n = norm_vec3(d)
		}
	}
	t.last_bite_n = hit_n
	hp_node := t.ore == .Gold ? NODE_HP_GOLD : NODE_HP_TEAM
	tower_stamp_wound(t, t.last_bite, t.node_radius * (0.22 + 0.30 * clampf(removed / max(hp_node, 0.01), 0, 1)))
	tower_resort_nodes(t)
	tower_recompute(t)
	tower_touch(world, t)
	_ = killed
	return ore, true
}

tower_build :: proc(world: ^Tower_World, id: Pylon_ID, count: int) -> (gained: int, ok: bool) {
	t := tower_get(world, id)
	if t == nil || count <= 0 {
		return 0, false
	}
	hp := t.ore == .Gold ? NODE_HP_GOLD : NODE_HP_TEAM
	for _ in 0 ..< count {
		if t.live_count >= t.max_count {
			break
		}
		placed := false
		for i in 0 ..< t.max_count {
			node := &t.nodes[i]
			if node.alive {
				continue
			}
			node.id = t.next_node_id
			t.next_node_id += 1
			if t.next_node_id == 0 {
				t.next_node_id = 1
			}
			node.hp = hp
			node.max_hp = hp
			node.alive = true
			gained += 1
			placed = true
			break
		}
		if !placed {
			break
		}
	}
	if gained == 0 {
		return 0, false
	}
	tower_resort_nodes(t)
	tower_recompute(t)
	tower_clear_wounds(t)
	tower_touch(world, t)
	return gained, true
}

tower_build_point :: proc(world: ^Tower_World, id: Pylon_ID, turn: int) -> vec3 {
	t := tower_get(world, id)
	if t == nil {
		return {}
	}
	z := t.core_height
	a := f32(turn) * SPIRAL_GOLDEN_ANGLE
	r := CORE_RADIUS * 0.8
	return {math.cos(a) * r, math.sin(a) * r, z}
}

tower_credit_ore :: proc(world: ^Tower_World, id: Pylon_ID, ore: f32) {
	t := tower_get(world, id)
	if t == nil {
		return
	}
	t.ore_debt += ore
}

tower_reserve :: proc(world: ^Tower_World, id: Pylon_ID) -> f32 {
	t := tower_get(world, id)
	if t == nil {
		return 0
	}
	return f32(t.live_count) * tower_node_ore(t)
}

// ---------------------------------------------------------------------------
// Wire

tower_pack_nodes :: proc(t: ^Tower, dst: []u8) -> int {
	if len(dst) < MAX_NODES_PER_TOWER {
		return 0
	}
	for i in 0 ..< MAX_NODES_PER_TOWER {
		dst[i] = 0
	}
	for i in 0 ..< t.max_count {
		node := &t.nodes[i]
		if !node.alive || node.hp <= 0 {
			continue
		}
		q := u8(clampf(node.hp / max(node.max_hp, 0.01) * 255, 1, 255))
		dst[i] = q
	}
	return MAX_NODES_PER_TOWER
}

tower_unpack_nodes :: proc(t: ^Tower, src: []u8) {
	if len(src) < t.max_count {
		return
	}
	old_live := t.live_count
	old_pos: [MAX_NODES_PER_TOWER]vec3
	old_hp: [MAX_NODES_PER_TOWER]f32
	had: [MAX_NODES_PER_TOWER]bool
	for idx in 0 ..< t.max_count {
		if !t.nodes[idx].alive {
			continue
		}
		old_pos[idx] = tower_node_spiral_pos(t, idx)
		old_hp[idx] = t.nodes[idx].hp
		had[idx] = true
	}

	hp_max := t.ore == .Gold ? NODE_HP_GOLD : NODE_HP_TEAM
	changed := false
	for i in 0 ..< t.max_count {
		node := &t.nodes[i]
		if node.max_hp <= 0 {
			node.max_hp = hp_max
		}
		if node.id == 0 {
			node.id = Node_ID(i + 1)
		}
		q := src[i]
		if q == 0 {
			if node.alive || node.hp != 0 {
				changed = true
			}
			node.alive = false
			node.hp = 0
			continue
		}
		hp := f32(q) / 255.0 * node.max_hp
		if !node.alive || abs(node.hp - hp) > 0.02 {
			changed = true
		}
		node.alive = true
		node.hp = hp
	}
	for i in t.max_count ..< MAX_NODES_PER_TOWER {
		if t.nodes[i].alive {
			changed = true
		}
		t.nodes[i] = {}
	}
	tower_resort_nodes(t)
	tower_recompute(t)
	if t.live_count > old_live {
		tower_clear_wounds(t)
	} else {
		n_chip := 0
		for i in 0 ..< t.max_count {
			eps := tower_hp_wire_eps(max(t.nodes[i].max_hp, old_hp[i]))
			if had[i] && old_hp[i] > t.nodes[i].hp + eps {
				n_chip += 1
			}
		}
		// A live bite hits a handful of overlapping nodes. A full GameState
		// catch-up chips most of the tower at once; skip scars there.
		if n_chip > 0 && n_chip <= TOWER_WOUND_MAX * 2 {
			for i in 0 ..< t.max_count {
				eps := tower_hp_wire_eps(max(t.nodes[i].max_hp, old_hp[i]))
				if !had[i] || old_hp[i] <= t.nodes[i].hp + eps {
					continue
				}
				lost := (old_hp[i] - t.nodes[i].hp) / max(old_hp[i], 0.01)
				face := tower_node_outward_face(t, old_pos[i])
				tower_stamp_wound(t, face, t.node_radius * (0.22 + 0.30 * clampf(lost, 0, 1)))
			}
		}
	}
	if changed {
		tower_bump(t)
	}
}

tower_collect_dirty :: proc(world: ^Tower_World, dst: []Pylon_ID) -> int {
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

tower_clear_dirty :: proc(world: ^Tower_World, ids: []Pylon_ID) {
	for id in ids {
		if int(id) < world.count {
			world.dirty[id] = false
		}
	}
}

// ---------------------------------------------------------------------------
// Tick

tower_world_tick :: proc(world: ^Tower_World, chunks: ^Ore_Chunk_World, dt: f32) {
	_ = dt
	for i in 0 ..< world.count {
		t := &world.towers[i]
		if !t.touched {
			continue
		}
		// One node death = one ore chunk with the node's full ore value (1:1 contract).
		// Skip the multi-chunk loop; spawn exactly one chunk per kill.
		if t.ore_debt > 0 {
			local := t.last_bite
			if len2_vec3(local) < 0.01 {
				local = {t.spiral_radius, 0, t.core_height * 0.5}
			}
			wp := tower_to_world(t, local)
			ore_chunk_spawn_loose(chunks, t.ore, wp + vec3{0, 0, 0.5}, t.ore_debt)
			t.ore_debt = 0
		}
	}
}

// ---------------------------------------------------------------------------
// Self-test

@(private = "file")
tower_selftest_ran: bool

tower_selftest :: proc() {
	if tower_selftest_ran {
		return
	}
	tower_selftest_ran = true

	world: Tower_World
	world.count = 1
	t := &world.towers[0]
	t.pylon_id = 0
	t.owner = .None
	t.ore = .Gold
	t.tough = 1
	t.max_count = 8
	t.design_height = 8
	t.design_radius = 2.4
	tower_layout(t)
	tower_build_full(t)
	assert(t.live_count == 8, "full tower live_count")
	assert(abs(t.core_height - t.design_height) < 0.001, "full tower meets the cap")
	seen: [MAX_NODES_PER_TOWER]bool
	for rank in 0 ..< t.live_count {
		idx := t.sorted_indices[rank]
		assert(idx >= 0 && idx < t.max_count, "sorted index in range")
		assert(!seen[idx], "sorted indices unique")
		seen[idx] = true
		assert(t.nodes[idx].alive, "sorted node alive")
	}

	// Fractional chip must register and scar, but does NOT pay ore (only death does).
	// This is the new 1:1 node-death-to-ore contract for clear FPS feedback.
	pos := tower_node_world_pos(t, 0)
	ore, ok := tower_mine(&world, 0, pos, t.node_radius, 0.60, 1, .Alpha)
	assert(ok, "fractional chip mines")
	assert(ore == 0, "chip does not yield ore (only death does)")
	assert(t.live_count == 8, "chip does not kill")
	assert(world.dirty[0], "chip dirties wire")
	assert(t.wound_count > 0, "chip stamps a scar")
	near := false
	for i in 0 ..< t.wound_count {
		d := t.wounds[i].pos - t.last_bite
		if len2_vec3(d) < (t.node_radius * 1.5) * (t.node_radius * 1.5) {
			near = true
		}
	}
	assert(near, "scar sits on the bite")
	assert(tower_mass_frac(t) < 1, "chip lowers mass")
	assert(t.intact == 1, "chip does not change intact")

	base := tower_node_spiral_pos(t, 0)
	assert(abs(base.z - t.node_radius) < 0.001, "rank 0 sits on the floor")
	radial := math.sqrt(base.x * base.x + base.y * base.y)
	assert(abs(radial - t.spiral_radius) < 0.001, "rank 0 on the spiral")
	top := tower_node_spiral_pos(t, t.live_count - 1)
	assert(abs(top.z + t.node_radius - t.design_height) < 0.001, "last node kisses the cap")
	assert(abs(t.core_height - tower_column_height(t, t.live_count)) < 0.001, "core tracks the live column")

	same: [MAX_NODES_PER_TOWER]u8
	tower_pack_nodes(t, same[:])
	wounds_before := t.wound_count
	tower_unpack_nodes(t, same[:])
	assert(t.wound_count == wounds_before, "identical unpack does not add scars")

	// Kill splash must visit every overlapping node even as they die.
	t.tough = 0.01
	_, ok = tower_mine(&world, 0, pos, t.node_radius * 3, 50, 1, .Alpha)
	assert(ok, "kill splash mines")
	assert(t.live_count < 8, "kill splash reduces live_count")
	assert(abs(t.core_height - tower_column_height(t, t.live_count)) < 0.001, "kill shortens core with the shell")
	if t.live_count > 0 {
		floor_pos := tower_node_spiral_pos(t, 0)
		assert(abs(floor_pos.z - t.node_radius) < 0.001, "remaining stack still sits on the floor")
		cap_pos := tower_node_spiral_pos(t, t.live_count - 1)
		assert(abs(cap_pos.z + t.node_radius - t.core_height) < 0.001, "remaining stack meets the live cap")
	}
	for rank in 0 ..< t.live_count {
		node := tower_node_at_rank(t, rank)
		assert(node != nil && node.alive, "post-kill ranks are live")
		if rank > 0 {
			prev := tower_node_at_rank(t, rank - 1)
			assert(prev.hp >= node.hp, "hp desc after resort")
		}
	}

	wire: [MAX_NODES_PER_TOWER]u8
	n := tower_pack_nodes(t, wire[:])
	assert(n == MAX_NODES_PER_TOWER, "pack fills the wire slot")
	alive := t.live_count
	tower_unpack_nodes(t, wire[:])
	assert(t.live_count == alive, "unpack preserves live_count")

	before := t.live_count
	gained, built := tower_build(&world, 0, 2)
	assert(built, "donate builds")
	assert(gained > 0, "donate gained")
	assert(t.live_count == min(before + gained, t.max_count), "donate live_count")
	assert(abs(t.core_height - tower_column_height(t, t.live_count)) < 0.001, "rebuild grows core with the shell")
	assert(t.wound_count == 0, "rebuild clears scars")

	// Analytic ray from outside hits the node we aimed at.
	center := tower_node_world_pos(t, 0)
	ro := center + vec3{6, 0, 0}
	rd := norm_vec3(center - ro)
	_, _, _, hit := tower_raycast(&world, ro, rd, 20)
	assert(hit, "raycast hits a standing tower")

	// Production layouts: shell and core share the pylon's floor and ceiling.
	counts := [3]int{TOWER_NODES_GOLD, TOWER_NODES_NEAR, TOWER_NODES_FAR}
	heights := [3]f32{PYLON_GOLD_HEIGHT, PYLON_NEAR_HEIGHT, PYLON_FAR_HEIGHT}
	for k in 0 ..< 3 {
		p: Tower
		p.max_count = counts[k]
		p.design_height = heights[k]
		p.ore = .Ember
		p.tough = 1
		tower_layout(&p)
		tower_build_full(&p)
		assert(p.design_height < WORLD_CEIL_Z, "production pylon fits under the arena ceiling")
		assert(p.live_count == p.max_count, "production live_count")
		assert(abs(p.core_height - p.design_height) < 0.002, "production full tower is floor to cap")
		lo := tower_node_spiral_pos(&p, 0)
		assert(abs(lo.z - p.node_radius) < 0.002, "production rank 0 on the floor")
		hi := tower_node_spiral_pos(&p, p.live_count - 1)
		assert(abs(hi.z + p.node_radius - p.design_height) < 0.002, "production last node at the cap")
		assert(p.node_radius < p.design_height / f32(p.max_count) * 2, "nodes are one course, not the old hex boulders")
	}
}
