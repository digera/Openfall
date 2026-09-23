package main

import "core:fmt"
import "core:math"
import "core:slice"

// Spiral shield-node tower authority.
//
// Gameplay is an array of overlapping ore nodes on a tapered helix. Node_ID is
// identity. Spiral position is a function of array index (slot 0 on the floor,
// last slot a crown on the axis) so a bite leaves a hole instead of sliding a
// healthier neighbour under the aim. HP is still sorted for bookkeeping; that
// sort must not move geometry. Hits address the Node_ID found at the impact
// point.
//
// Holes stay until the column is unsound: a run of three or more empty slots
// with live rock still above them. Every few seconds that tower then has a
// chance to collapse — live nodes pack into the lowest slots, the shaft
// shortens to the new cap, and identity (id, HP, who laid it) rides with the
// node. Minion
// hops still fill the first dead slot, which after a collapse is the new top.
//
// Collision stays on the node spheres. The client welds those same live slots
// into one lumpy column (smooth-union + grain) so the silhouette reads as ore
// rather than a grape cluster. The thin core is last-stand only: it is absent
// while the shell is up, and only drawn / raycast once few nodes remain.
// Collapse is a helix settle driven by collapse_t; the shader smears along
// that same from-to path. Chip scars live in the shader. See docs/TOWERS.md.

// ---------------------------------------------------------------------------
// Tuning

MAX_NODES_PER_TOWER :: 32
TOWER_NODES_GOLD    :: 24
TOWER_NODES_NEAR    :: 12
TOWER_NODES_FAR     :: 12

#assert(TOWER_NODES_GOLD <= MAX_NODES_PER_TOWER)
#assert(TOWER_NODES_NEAR <= MAX_NODES_PER_TOWER)
#assert(TOWER_NODES_FAR  <= MAX_NODES_PER_TOWER)
#assert(MAX_NODES_PER_TOWER <= 32) // GPU alive mask is two 16-bit floats

// Thin last-stand column. Nodes are the destructible shell; this stick only
// exists once the shell is stripped down to TOWER_CORE_EXPOSE_LIVE nodes.
CORE_RADIUS :: f32(0.55)
TOWER_CORE_EXPOSE_LIVE :: 2

// Phyllotaxis on a tapering cone. Consecutive slots are a golden step apart, so
// neighbours in space are Fibonacci parastichies -- overlapping blobs, with
// holes that read once a slot dies. Must stay in lockstep with shaders/scene.glsl.
SPIRAL_GOLDEN_ANGLE :: f32(2.399963229728653)

// Node spheres are one course of the column: slot 0 sits on the floor, the
// last slot kisses the cap. Radius is a fraction of the full-tower pitch so a
// dead slot is a missing course, not a boulder that was hanging through the
// floor. Wrap is the base helix radius as a fraction of node radius — tight
// enough that golden-angle neighbours overlap into a shaft once welded.
TOWER_NODE_RADIUS_STEPS :: f32(1.42)
TOWER_NODE_WRAP         :: f32(0.52)

// Silhouette: the helix necks in toward the top, and the last slot sits almost
// on the axis so the column has a crown instead of a grape stuck on the side.
TOWER_SPIRAL_TAPER :: f32(0.38)
TOWER_CROWN_RADIAL :: f32(0.10)
TOWER_CROWN_START  :: f32(0.82)

// GPU smooth-union and grain. Collision stays on the analytic spheres; the
// bound cylinder is padded so the marched surface is not clipped.
TOWER_WELD_K     :: f32(0.40)
TOWER_GRAIN_AMP  :: f32(0.12)

// Same budget as a fodder. Mining applies combat damage (beam
// DPS on the bite cadence, projectile damage on a blast) so a slot dies like
// a wave body; gold still divides that incoming amount by toughness.
NODE_HP :: MINION_FODDER_HP

// Wire byte for one node. 0 is dead. Otherwise the low 6 bits are hp in
// 1..63 and the high 2 bits are the team that laid the node (0 means the
// tower's own ore — gold, until a wave spends a body on the centre).
// Sixty-three steps still cross the chip threshold; the two spare bits are
// how a rebuilt centre shows whose rock is whose without growing the packet.
NODE_HP_WIRE_LEVELS :: 63
NODE_LAID_SHIFT     :: 6

// Ore from a fully mined node. Paid once, when the node dies: one chunk on
// the ground maps to one dead slot. Chips scar the face but do not shed ore.
NODE_ORE_TEAM :: f32(8.0)
NODE_ORE_GOLD :: f32(18.0)

// One hop restores two nodes. Three free fodder over three waves put back 6,
// which is half of a 12-node lane tower. Own ore buys another fodder, not a
// bigger hop.
TOWER_DONATE_BASE :: 2

// Shader scars, not occupancy. Four is enough for a focused beam plus a
// couple of splash nicks; the shader reads this many per tower.
TOWER_WOUND_MAX :: 4
#assert(TOWER_WOUND_MAX * MAX_PYLONS == 28)

// Collapse: a hole of this many consecutive empty slots, with live rock
// still above it, makes the column eligible to pack down. Rolls every
// PERIOD seconds; bigger holes are more eager. ANIM is the client settle.
TOWER_COLLAPSE_GAP              :: 3
TOWER_COLLAPSE_PERIOD           :: f32(3.0)
TOWER_COLLAPSE_CHANCE           :: f32(0.40)
TOWER_COLLAPSE_CHANCE_PER_EXTRA :: f32(0.12)
TOWER_COLLAPSE_CHANCE_MAX       :: f32(0.85)
TOWER_COLLAPSE_ANIM             :: f32(0.90)

// ---------------------------------------------------------------------------
// Types

Node_ID :: u16

Tower_Node :: struct {
	id:      Node_ID,
	hp:      f32,
	max_hp:  f32,
	alive:   bool,
	// .None means "this tower's own ore". On the centre, a team id is the
	// wave that spent the body: the shell draws in that colour so a fight
	// at the stump can see who is building it.
	laid_by: Team_ID,
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

	// rank 0 = highest HP. Sorting is bookkeeping only; spiral position is
	// a stable function of array index, not rank.
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

	// Server: time since the last collapse roll while a hole is open.
	collapse_timer: f32,
	collapse_rolls: u32,

	// Client visual only. Authority is the packed slots the moment the
	// server collapses; these let the shader corkscrew from the gappy
	// mask to the packed one. SDF welding can drive off collapse_t.
	collapse_from_mask:   u32,
	collapse_from_height: f32,
	collapse_t:           f32,
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

// Floor-to-cap packing for a full tower. Slot 0 sits on the floor, the last
// slot kisses the design height. A kill omits the sphere; it does not reflow
// the helix until a collapse packs live nodes into the lowest slots.
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
	t.spiral_radius = r * TOWER_NODE_WRAP
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
	hp := NODE_HP
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
		node.laid_by = .None
		t.live_count += 1
	}
	for i in t.max_count ..< MAX_NODES_PER_TOWER {
		t.nodes[i] = {}
	}
	tower_recompute(t)
	tower_resort_nodes(t)
	tower_clear_wounds(t)
	tower_clear_collapse_visual(t)
	t.collapse_timer = 0
	t.collapse_rolls = 0
	tower_bump(t)
}

tower_highest_live :: proc(t: ^Tower) -> int {
	hi := -1
	n := t.max_count
	if n > MAX_NODES_PER_TOWER {
		n = MAX_NODES_PER_TOWER
	}
	for i in 0 ..< n {
		if t.nodes[i].alive {
			hi = i
		}
	}
	return hi
}

tower_recompute :: proc(t: ^Tower) {
	// Shaft covers the highest occupied slot so a live cap still sits
	// inside the bound, and a packed collapse actually shortens the tower.
	// Flattened towers drop the core so they stop blocking.
	if t.live_count <= 0 {
		t.core_height = 0
	} else {
		hi := tower_highest_live(t)
		t.core_height = tower_column_height(t, hi + 1)
	}
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
	// Weld and grain push the marched surface a little past the sphere union.
	pad := t.node_radius * (TOWER_WELD_K * 0.25 + TOWER_GRAIN_AMP)
	return t.spiral_radius + t.node_radius + pad
}

tower_core_exposed :: proc(t: ^Tower) -> bool {
	return t.live_count > 0 && t.live_count <= TOWER_CORE_EXPOSE_LIVE && t.core_height > 0.01
}

// Helix radius at a slot. Foot is full spiral_radius, shaft tapers, last slot
// is the crown. Twin of pylon_slot_radial in shaders/scene.glsl.
tower_slot_radial :: proc(t: ^Tower, array_index: int) -> f32 {
	n := t.max_count
	if n <= 1 {
		return t.spiral_radius * TOWER_CROWN_RADIAL
	}
	u := f32(array_index) / f32(n - 1)
	u2 := u * u
	rad := lerpf(t.spiral_radius, t.spiral_radius * TOWER_SPIRAL_TAPER, u2)
	if u > TOWER_CROWN_START {
		cap := (u - TOWER_CROWN_START) / (1 - TOWER_CROWN_START)
		rad = lerpf(rad, t.spiral_radius * TOWER_CROWN_RADIAL, cap * cap)
	}
	return rad
}

// Alive bits 0..max_count-1, packed for the GPU as two 16-bit integers.
// Do not bitcast a u32 through f32: a 32-node mask can look like NaN.
tower_alive_mask :: proc(t: ^Tower) -> u32 {
	mask: u32 = 0
	n := t.max_count
	if n > MAX_NODES_PER_TOWER {
		n = MAX_NODES_PER_TOWER
	}
	for k in 0 ..< n {
		if t.nodes[k].alive {
			mask |= u32(1) << u32(k)
		}
	}
	return mask
}

// Node spiral position from ARRAY INDEX, not HP rank.
// Damage and death leave holes; only collapse reassigns indices.
tower_node_spiral_pos :: proc(t: ^Tower, array_index: int) -> vec3 {
	if array_index < 0 || array_index >= t.max_count {
		return {}
	}
	z := t.node_radius + f32(array_index) * t.stack_step
	angle := f32(array_index) * SPIRAL_GOLDEN_ANGLE
	rad := tower_slot_radial(t, array_index)
	return {math.cos(angle) * rad, math.sin(angle) * rad, z}
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
	// Half a wire step. An identical unpack does not scar; crossing a bucket does.
	return max(max_hp, 0.01) * (0.5 / f32(NODE_HP_WIRE_LEVELS))
}

// Outer skin of a node, away from the core. Mining from a lane hits this
// face, so a scar stamped here stays on the beam at the stable slot.
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
	_ = build_r
	return TOWER_DONATE_BASE
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
		if tower_core_exposed(t) {
			core_r := CORE_RADIUS + pad
			if local.z >= -pad && local.z <= t.core_height + pad {
				if local.x * local.x + local.y * local.y <= core_r * core_r {
					return true
				}
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
		if tower_core_exposed(tw) {
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

	if tower_core_exposed(t) && local.z >= 0 && local.z <= t.core_height {
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
		if tower_core_exposed(t) {
			core_r := CORE_RADIUS + pad
			if local.z >= -pad && local.z <= t.core_height + pad {
				if local.x * local.x + local.y * local.y <= core_r * core_r {
					return Pylon_ID(i), true
				}
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

	// Collect by array index. A kill cannot slide a neighbour under this
	// splash; only a later collapse reassigns slots.
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
		if node.hp <= 0 {
			node.alive = false
			node.laid_by = .None
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
	tower_stamp_wound(t, t.last_bite, t.node_radius * (0.22 + 0.30 * clampf(removed / max(NODE_HP, 0.01), 0, 1)))
	tower_resort_nodes(t)
	tower_recompute(t)
	tower_touch(world, t)
	_ = killed
	return ore, true
}

// `by` is the wave that spent the bodies. Lane towers already draw as their
// owner; on the centre it is the only thing that makes a new course readable
// as Ember, Tide, or Verdant instead of gold.
tower_build :: proc(world: ^Tower_World, id: Pylon_ID, count: int, by: Team_ID = .None) -> (gained: int, ok: bool) {
	t := tower_get(world, id)
	if t == nil || count <= 0 {
		return 0, false
	}
	hp := NODE_HP
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
			node.laid_by = by
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
// Collapse

tower_packed_mask :: proc(live: int) -> u32 {
	if live <= 0 {
		return 0
	}
	if live >= 32 {
		return 0xFFFFFFFF
	}
	return (u32(1) << u32(live)) - 1
}

tower_is_packed :: proc(t: ^Tower) -> bool {
	return tower_alive_mask(t) == tower_packed_mask(t.live_count)
}

// Longest consecutive dead run that still has live rock above it. Trailing
// empties at the cap do not count: compacting them would be a no-op.
tower_longest_unsupported_gap :: proc(t: ^Tower) -> int {
	best := 0
	run := 0
	n := t.max_count
	if n > MAX_NODES_PER_TOWER {
		n = MAX_NODES_PER_TOWER
	}
	for i in 0 ..< n {
		if t.nodes[i].alive {
			if run > best {
				best = run
			}
			run = 0
		} else {
			run += 1
		}
	}
	return best
}

tower_collapse_pending :: proc(t: ^Tower) -> bool {
	if t.live_count <= 0 {
		return false
	}
	if tower_is_packed(t) {
		return false
	}
	return tower_longest_unsupported_gap(t) >= TOWER_COLLAPSE_GAP
}

tower_collapse_chance :: proc(gap: int) -> f32 {
	extra := gap - TOWER_COLLAPSE_GAP
	if extra < 0 {
		extra = 0
	}
	c := TOWER_COLLAPSE_CHANCE + f32(extra) * TOWER_COLLAPSE_CHANCE_PER_EXTRA
	if c > TOWER_COLLAPSE_CHANCE_MAX {
		return TOWER_COLLAPSE_CHANCE_MAX
	}
	return c
}

// Pack live nodes into the lowest slots. Identity and HP ride with the node.
// Returns whether anything actually moved.
tower_compact_nodes :: proc(t: ^Tower) -> bool {
	write := 0
	moved := false
	n := t.max_count
	if n > MAX_NODES_PER_TOWER {
		n = MAX_NODES_PER_TOWER
	}
	for read in 0 ..< n {
		if !t.nodes[read].alive {
			continue
		}
		if write != read {
			t.nodes[write] = t.nodes[read]
			t.nodes[read] = {}
			moved = true
		}
		write += 1
	}
	return moved
}

tower_collapse_apply :: proc(world: ^Tower_World, t: ^Tower) -> bool {
	if t == nil || !tower_compact_nodes(t) {
		return false
	}
	tower_resort_nodes(t)
	tower_recompute(t)
	tower_clear_wounds(t)
	tower_touch(world, t)
	return true
}

tower_collapse_tick :: proc(world: ^Tower_World, t: ^Tower, dt: f32) {
	if !tower_collapse_pending(t) {
		t.collapse_timer = 0
		return
	}
	t.collapse_timer += dt
	if t.collapse_timer < TOWER_COLLAPSE_PERIOD {
		return
	}
	t.collapse_timer = 0
	t.collapse_rolls += 1
	h := hash_u32(u32(t.pylon_id) * 2654435761 + t.collapse_rolls * 2246822519 + t.version)
	roll := f32(h & 0xFFFF) / 65536.0
	if roll < tower_collapse_chance(tower_longest_unsupported_gap(t)) {
		tower_collapse_apply(world, t)
	}
}

tower_clear_collapse_visual :: proc(t: ^Tower) {
	t.collapse_from_mask = 0
	t.collapse_from_height = 0
	t.collapse_t = 0
}

tower_begin_collapse_visual :: proc(t: ^Tower, from_mask: u32, from_height: f32) {
	t.collapse_from_mask = from_mask
	t.collapse_from_height = from_height
	t.collapse_t = 1
}

tower_collapse_ease :: proc(t: f32) -> f32 {
	u := clampf(1 - t, 0, 1)
	return u * u * (3 - 2 * u)
}

tower_display_core_height :: proc(t: ^Tower) -> f32 {
	if t.collapse_t <= 0.001 {
		return t.core_height
	}
	u := tower_collapse_ease(t.collapse_t)
	return t.collapse_from_height * (1 - u) + t.core_height * u
}

tower_world_visual_tick :: proc(world: ^Tower_World, dt: f32) {
	step := dt / TOWER_COLLAPSE_ANIM
	if step < 0 {
		step = 0
	}
	for i in 0 ..< world.count {
		t := &world.towers[i]
		if t.collapse_t <= 0 {
			continue
		}
		t.collapse_t -= step
		if t.collapse_t < 0 {
			t.collapse_t = 0
		}
	}
}

tower_unpack_is_collapse :: proc(old_mask: u32, old_live: int, new_mask: u32, new_live: int) -> bool {
	if old_live != new_live || new_live <= 0 {
		return false
	}
	if old_mask == new_mask {
		return false
	}
	if new_mask != tower_packed_mask(new_live) {
		return false
	}
	return old_mask != tower_packed_mask(old_live)
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
		dst[i] = tower_pack_node_byte(node^)
	}
	return MAX_NODES_PER_TOWER
}

// Low 6 bits: hp 1..63. High 2 bits: Team_ID 0..3. A zero byte is dead,
// so a live node never stores a zero hp field.
tower_pack_node_byte :: proc(node: Tower_Node) -> u8 {
	if !node.alive || node.hp <= 0 {
		return 0
	}
	q := u8(clampf(node.hp / max(node.max_hp, 0.01) * f32(NODE_HP_WIRE_LEVELS), 1, f32(NODE_HP_WIRE_LEVELS)))
	team := u8(node.laid_by)
	if team > 3 {
		team = 0
	}
	return q | (team << NODE_LAID_SHIFT)
}

tower_unpack_node_byte :: proc(q: u8) -> (hp_frac: f32, laid: Team_ID, alive: bool) {
	if q == 0 {
		return 0, .None, false
	}
	laid = Team_ID((q >> NODE_LAID_SHIFT) & 3)
	hp_q := int(q) & NODE_HP_WIRE_LEVELS
	if hp_q < 1 {
		hp_q = 1
	}
	return f32(hp_q) / f32(NODE_HP_WIRE_LEVELS), laid, true
}

// Twelve nodes, two bits each, packed into a float the shader can recover.
// 2^24-1 is the largest integer a float32 holds exactly, and 12*2 bits is
// exactly that wide, so a round trip does not swap two teams.
tower_laid_chunk :: proc(t: ^Tower, start: int) -> f32 {
	v: u32 = 0
	for i in 0 ..< 12 {
		idx := start + i
		if idx < 0 || idx >= t.max_count || idx >= MAX_NODES_PER_TOWER {
			continue
		}
		node := &t.nodes[idx]
		if !node.alive {
			continue
		}
		team := u32(node.laid_by)
		if team > 3 {
			team = 0
		}
		v |= team << u32(i * 2)
	}
	return f32(v)
}

// What the centre should glow as from a lane away.
//
// Lane towers are their owner's ore. The centre stays gold until a wave
// lays rock, then the glow follows whichever team currently holds the most
// live courses. A tie reads as the top course, which is the rock you are
// about to mine or defend. Per-node colour is separate: a minority course
// still draws as the team that placed it.
tower_display_ore :: proc(t: ^Tower) -> Ore_Kind {
	if t == nil || t.owner != .None {
		if t == nil {
			return .None
		}
		return t.ore
	}
	counts: [TEAM_COUNT]int
	top := Team_ID.None
	for i in 0 ..< t.max_count {
		node := &t.nodes[i]
		if !node.alive {
			continue
		}
		ti := team_index(node.laid_by)
		if ti < 0 {
			continue
		}
		counts[ti] += 1
		top = node.laid_by
	}
	best_n := 0
	best_teams := 0
	best := Team_ID.None
	for i in 0 ..< TEAM_COUNT {
		if counts[i] > best_n {
			best_n = counts[i]
			best = team_from_index(i)
			best_teams = 1
		} else if best_n > 0 && counts[i] == best_n {
			best_teams += 1
		}
	}
	if best_n == 0 {
		return t.ore
	}
	if best_teams > 1 {
		ti := team_index(top)
		if ti >= 0 && counts[ti] == best_n {
			return team_ore(top)
		}
	}
	return team_ore(best)
}

tower_stamp_unpack_chips :: proc(t: ^Tower, had: [MAX_NODES_PER_TOWER]bool, old_hp: [MAX_NODES_PER_TOWER]f32, old_pos: [MAX_NODES_PER_TOWER]vec3) {
	n_chip := 0
	for i in 0 ..< t.max_count {
		eps := tower_hp_wire_eps(max(t.nodes[i].max_hp, old_hp[i]))
		if had[i] && old_hp[i] > t.nodes[i].hp + eps {
			n_chip += 1
		}
	}
	// A live bite hits a handful of overlapping nodes. A full GameState
	// catch-up chips most of the tower at once; skip scars there.
	if n_chip <= 0 || n_chip > TOWER_WOUND_MAX * 2 {
		return
	}
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

tower_unpack_nodes :: proc(t: ^Tower, src: []u8) {
	if len(src) < t.max_count {
		return
	}
	old_live := t.live_count
	old_mask := tower_alive_mask(t)
	old_height := t.core_height
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

	hp_max := NODE_HP
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
		frac, laid, alive := tower_unpack_node_byte(q)
		if !alive {
			if node.alive || node.hp != 0 || node.laid_by != .None {
				changed = true
			}
			node.alive = false
			node.hp = 0
			node.laid_by = .None
			continue
		}
		hp := frac * node.max_hp
		if !node.alive || node.laid_by != laid || abs(node.hp - hp) > 0.02 {
			changed = true
		}
		node.alive = true
		node.hp = hp
		node.laid_by = laid
	}
	for i in t.max_count ..< MAX_NODES_PER_TOWER {
		if t.nodes[i].alive {
			changed = true
		}
		t.nodes[i] = {}
	}
	tower_resort_nodes(t)
	tower_recompute(t)
	new_mask := tower_alive_mask(t)
	if tower_unpack_is_collapse(old_mask, old_live, new_mask, t.live_count) {
		tower_begin_collapse_visual(t, old_mask, old_height)
		tower_clear_wounds(t)
	} else {
		if old_mask != new_mask {
			tower_clear_collapse_visual(t)
		}
		if t.live_count > old_live {
			tower_clear_wounds(t)
		} else {
			tower_stamp_unpack_chips(t, had, old_hp, old_pos)
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
	for i in 0 ..< world.count {
		t := &world.towers[i]
		tower_collapse_tick(world, t, dt)
		// One dead node = one chunk carrying that node's full ore. Splash that
		// kills N nodes credits N * node_ore, so this loop emits N chunks.
		payout := tower_node_ore(t)
		for t.ore_debt + 0.001 >= payout && payout > 0.001 {
			t.ore_debt -= payout
			local := t.last_bite
			if len2_vec3(local) < 0.01 {
				local = {t.spiral_radius, 0, t.core_height * 0.5}
			}
			wp := tower_to_world(t, local)
			ore_chunk_spawn_loose(chunks, t.ore, wp + vec3{0, 0, 0.5}, payout)
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

	// Fractional chip must register and scar, but does not pay ore.
	pos := tower_node_world_pos(t, 0)
	slot5_before := tower_node_spiral_pos(t, 5)
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
	slot5_after_chip := tower_node_spiral_pos(t, 5)
	assert(abs(slot5_after_chip.x - slot5_before.x) < 0.0001, "chip does not move slot 5 x")
	assert(abs(slot5_after_chip.y - slot5_before.y) < 0.0001, "chip does not move slot 5 y")
	assert(abs(slot5_after_chip.z - slot5_before.z) < 0.0001, "chip does not move slot 5 z")

	base := tower_node_spiral_pos(t, 0)
	assert(abs(base.z - t.node_radius) < 0.001, "slot 0 sits on the floor")
	radial := math.sqrt(base.x * base.x + base.y * base.y)
	assert(abs(radial - t.spiral_radius) < 0.001, "slot 0 on the spiral")
	top := tower_node_spiral_pos(t, t.max_count - 1)
	assert(abs(top.z + t.node_radius - t.design_height) < 0.001, "last slot kisses the cap")
	crown := math.sqrt(top.x * top.x + top.y * top.y)
	assert(crown < t.spiral_radius * TOWER_CROWN_RADIAL + 0.02, "last slot is the crown")
	assert(crown < radial * 0.35, "crown sits tighter than the foot")
	assert(!tower_core_exposed(t), "full shell hides the last-stand core")
	assert(abs(t.core_height - tower_column_height(t, t.max_count)) < 0.001, "standing core stays at design height")

	same: [MAX_NODES_PER_TOWER]u8
	tower_pack_nodes(t, same[:])
	wounds_before := t.wound_count
	tower_unpack_nodes(t, same[:])
	assert(t.wound_count == wounds_before, "identical unpack does not add scars")

	// Isolated kill: one low-HP slot dies, neighbours keep their positions,
	// ore pays exactly one node, core does not shrink.
	for i in 0 ..< t.max_count {
		t.nodes[i].hp = t.nodes[i].max_hp
		t.nodes[i].alive = true
	}
	t.nodes[3].hp = 0.05
	tower_resort_nodes(t)
	tower_recompute(t)
	kill_pos := tower_node_world_pos(t, 3)
	slot7_before := tower_node_spiral_pos(t, 7)
	ore, ok = tower_mine(&world, 0, kill_pos, t.node_radius, 0.60, 1, .Alpha)
	assert(ok, "kill bite mines")
	assert(!t.nodes[3].alive, "low slot dies")
	assert(t.nodes[7].alive, "far slot survives a local bite")
	assert(abs(ore - tower_node_ore(t)) < 0.001, "one death pays one node of ore")
	slot7_after := tower_node_spiral_pos(t, 7)
	assert(abs(slot7_after.x - slot7_before.x) < 0.0001, "kill does not move slot 7 x")
	assert(abs(slot7_after.y - slot7_before.y) < 0.0001, "kill does not move slot 7 y")
	assert(abs(slot7_after.z - slot7_before.z) < 0.0001, "kill does not move slot 7 z")
	assert(abs(t.core_height - t.design_height) < 0.001, "kill leaves the shaft at design height")
	assert((tower_alive_mask(t) & (u32(1) << 3)) == 0, "dead slot cleared in alive mask")
	assert((tower_alive_mask(t) & (u32(1) << 7)) != 0, "live slot set in alive mask")

	// Kill splash must visit every overlapping node even as they die.
	t.tough = 0.01
	_, ok = tower_mine(&world, 0, pos, t.node_radius * 3, 50, 1, .Alpha)
	assert(ok, "kill splash mines")
	assert(t.live_count < 8, "kill splash reduces live_count")
	if t.live_count > 0 {
		hi := tower_highest_live(t)
		assert(abs(t.core_height - tower_column_height(t, hi + 1)) < 0.001, "shaft covers the highest live slot")
	} else {
		assert(t.core_height == 0, "flattened tower drops the core")
	}
	floor_pos := tower_node_spiral_pos(t, 0)
	assert(abs(floor_pos.z - t.node_radius) < 0.001, "slot 0 still on the floor after splash")
	cap_pos := tower_node_spiral_pos(t, t.max_count - 1)
	assert(abs(cap_pos.z + t.node_radius - t.design_height) < 0.001, "last slot still at the design cap")
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
	hi_rebuild := tower_highest_live(t)
	assert(abs(t.core_height - tower_column_height(t, hi_rebuild + 1)) < 0.001, "rebuild shaft covers the highest live slot")
	assert(t.wound_count == 0, "rebuild clears scars")

	// Analytic ray from outside hits the node we aimed at.
	center := tower_node_world_pos(t, 0)
	if !t.nodes[0].alive {
		for i in 0 ..< t.max_count {
			if t.nodes[i].alive {
				center = tower_node_world_pos(t, i)
				break
			}
		}
	}
	ro := center + vec3{6, 0, 0}
	rd := norm_vec3(center - ro)
	_, _, _, hit := tower_raycast(&world, ro, rd, 20)
	assert(hit, "raycast hits a standing tower")

	// A dead slot is omitted from collision; a live neighbour stays hittable.
	tower_build_full(t)
	t.nodes[2].alive = false
	t.nodes[2].hp = 0
	tower_resort_nodes(t)
	tower_recompute(t)
	dead_center := tower_node_world_pos(t, 2)
	live_center := tower_node_world_pos(t, 3)
	_, dead_idx, dead_ok := tower_node_at_point(t, dead_center, 0.01)
	assert(!dead_ok || dead_idx != 2, "dead slot is not a hit")
	_, live_idx, live_ok := tower_node_at_point(t, live_center, 0.05)
	assert(live_ok && live_idx == 3, "live neighbour still found at its slot")

	// Two-hole gap is stable; three empty with live rock above is eligible.
	tower_build_full(t)
	t.nodes[2].alive = false
	t.nodes[2].hp = 0
	t.nodes[3].alive = false
	t.nodes[3].hp = 0
	tower_resort_nodes(t)
	tower_recompute(t)
	assert(tower_longest_unsupported_gap(t) == 2, "two-hole gap length")
	assert(!tower_collapse_pending(t), "two-hole gap does not collapse")
	for _ in 0 ..< 8 {
		tower_collapse_tick(&world, t, TOWER_COLLAPSE_PERIOD)
	}
	assert(!t.nodes[2].alive && t.nodes[4].alive, "two-hole gap stays put")

	tower_build_full(t)
	t.nodes[5].alive = false
	t.nodes[5].hp = 0
	t.nodes[6].alive = false
	t.nodes[6].hp = 0
	t.nodes[7].alive = false
	t.nodes[7].hp = 0
	tower_resort_nodes(t)
	tower_recompute(t)
	assert(tower_longest_unsupported_gap(t) == 0, "trailing empties are not a hole")
	assert(!tower_collapse_pending(t), "a missing cap does not collapse")
	assert(abs(t.core_height - tower_column_height(t, 5)) < 0.001, "missing cap shortens the shaft")

	tower_build_full(t)
	for i in 1 ..= 3 {
		t.nodes[i].alive = false
		t.nodes[i].hp = 0
	}
	tower_resort_nodes(t)
	tower_recompute(t)
	assert(tower_longest_unsupported_gap(t) == 3, "three-hole gap length")
	assert(tower_collapse_pending(t), "three-hole gap is eligible")
	assert(abs(t.core_height - t.design_height) < 0.001, "gappy tower stays as tall as the cap")
	cap_id := t.nodes[7].id
	cap_hp := t.nodes[7].hp
	gappy_mask := tower_alive_mask(t)
	gappy_h := t.core_height
	gappy_live := t.live_count
	gappy_wire: [MAX_NODES_PER_TOWER]u8
	tower_pack_nodes(t, gappy_wire[:])
	assert(tower_collapse_apply(&world, t), "three-hole gap packs")
	assert(t.live_count == gappy_live, "collapse does not kill nodes")
	assert(tower_is_packed(t), "collapse packs to the floor")
	assert(t.nodes[4].id == cap_id && t.nodes[4].hp == cap_hp, "cap identity rides down")
	assert(!t.nodes[5].alive && !t.nodes[7].alive, "high slots empty after pack")
	assert(t.core_height < gappy_h, "collapse shortens the shaft")
	assert(abs(t.core_height - tower_column_height(t, t.live_count)) < 0.001, "packed shaft matches live span")
	assert(!tower_collapse_pending(t), "packed tower is not eligible")
	packed_wire: [MAX_NODES_PER_TOWER]u8
	tower_pack_nodes(t, packed_wire[:])
	tower_unpack_nodes(t, gappy_wire[:])
	tower_clear_collapse_visual(t)
	assert(!tower_is_packed(t), "gappy unpack restored holes")
	tower_unpack_nodes(t, packed_wire[:])
	assert(t.collapse_t == 1, "packed unpack starts the settle")
	assert(t.collapse_from_mask == gappy_mask, "settle remembers the gappy mask")
	assert(abs(t.collapse_from_height - gappy_h) < 0.001, "settle remembers the tall shaft")
	assert(t.wound_count == 0, "collapse does not stamp fake scars")

	before_top := t.live_count
	gained_top, built_top := tower_build(&world, 0, 1)
	assert(built_top && gained_top == 1, "donate after collapse")
	assert(t.nodes[before_top].alive, "donate grows the packed cap")
	assert(tower_is_packed(t), "donate on a packed tower stays packed")

	// Tick path: a 3-gap eventually packs.
	tower_build_full(t)
	for i in 0 ..= 2 {
		t.nodes[i].alive = false
		t.nodes[i].hp = 0
	}
	tower_resort_nodes(t)
	tower_recompute(t)
	assert(tower_collapse_pending(t), "hollow base is eligible")
	for _ in 0 ..< 80 {
		if tower_is_packed(t) {
			break
		}
		tower_collapse_tick(&world, t, TOWER_COLLAPSE_PERIOD)
	}
	assert(tower_is_packed(t), "hollow base eventually collapses")
	assert(t.nodes[0].alive && !t.nodes[5].alive, "base collapse drops the remaining shell")
	assert(t.core_height < t.design_height, "base collapse shrinks the tower")
	assert(tower_collapse_chance(6) > tower_collapse_chance(3), "bigger holes collapse more eagerly")

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
		assert(abs(lo.z - p.node_radius) < 0.002, "production slot 0 on the floor")
		hi := tower_node_spiral_pos(&p, p.max_count - 1)
		assert(abs(hi.z + p.node_radius - p.design_height) < 0.002, "production last slot at the cap")
		assert(p.node_radius < p.design_height / f32(p.max_count) * 2, "nodes are one course, not the old hex boulders")
		p.nodes[0].alive = false
		p.nodes[0].hp = 0
		tower_resort_nodes(&p)
		tower_recompute(&p)
		assert(abs(p.core_height - p.design_height) < 0.002, "production shaft stays up through holes")
		hi2 := tower_node_spiral_pos(&p, p.max_count - 1)
		assert(abs(hi2.z - hi.z) < 0.0001, "production cap slot does not move after a floor kill")
		cap_r := math.sqrt(hi.x * hi.x + hi.y * hi.y)
		assert(cap_r < p.spiral_radius * 0.35, "production crown sits near the axis")
	}

	// Last-stand core only appears once the shell is stripped.
	tower_build_full(t)
	for i in 2 ..< t.max_count {
		t.nodes[i].alive = false
		t.nodes[i].hp = 0
	}
	tower_resort_nodes(t)
	tower_recompute(t)
	assert(t.live_count == 2, "two nodes left")
	assert(tower_core_exposed(t), "stripped tower shows the last-stand core")

	// A rebuilt centre is the team's rock, not leftover gold. The wire and
	// the float the shader samples have to carry the same team bits.
	{
		cw: Tower_World
		cw.count = 1
		ct := &cw.towers[0]
		ct.pylon_id = 0
		ct.owner = .None
		ct.ore = .Gold
		ct.max_count = 8
		ct.design_height = 4
		tower_layout(ct)
		tower_build_full(ct)
		assert(tower_display_ore(ct) == .Gold, "an untouched centre is still gold")
		for i in 0 ..< ct.max_count {
			ct.nodes[i].alive = false
			ct.nodes[i].hp = 0
			ct.nodes[i].laid_by = .None
		}
		ct.live_count = 0
		tower_recompute(ct)
		g0, ok0 := tower_build(&cw, 0, 3, .Alpha)
		g1, ok1 := tower_build(&cw, 0, 1, .Beta)
		assert(ok0 && ok1 && g0 == 3 && g1 == 1, "centre donations land")
		assert(ct.nodes[0].laid_by == .Alpha && ct.nodes[2].laid_by == .Alpha, "early courses are the first team")
		assert(ct.nodes[3].laid_by == .Beta, "the next course is the second team")
		assert(tower_display_ore(ct) == .Ember, "the glow follows whoever holds the most courses")
		g2, ok2 := tower_build(&cw, 0, 2, .Beta)
		assert(ok2 && g2 == 2, "the second team can catch up")
		assert(tower_display_ore(ct) == .Tide, "a tie reads as the top course")
		wire: [MAX_NODES_PER_TOWER]u8
		tower_pack_nodes(ct, wire[:])
		assert(wire[0] == u8(NODE_HP_WIRE_LEVELS | (1 << NODE_LAID_SHIFT)), "full ember course packs team into the high bits")
		for i in 0 ..< ct.max_count {
			ct.nodes[i].laid_by = .None
		}
		tower_unpack_nodes(ct, wire[:])
		assert(ct.nodes[0].laid_by == .Alpha && ct.nodes[3].laid_by == .Beta && ct.nodes[5].laid_by == .Beta, "unpack restores who laid each course")
		assert(tower_display_ore(ct) == .Tide, "display ore survives the wire")
		chunk := tower_laid_chunk(ct, 0)
		back := u32(chunk + 0.5)
		expect: u32 = 0
		teams := [6]u32{1, 1, 1, 2, 2, 2}
		for i in 0 ..< 6 {
			expect |= teams[i] << u32(i * 2)
		}
		assert(back == expect, "laid bits survive a float uniform")
	}
}
