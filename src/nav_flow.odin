package main

import "core:fmt"
import "core:math"

// Minion flow fields.
//
// The lane graph in `nav_next_waypoint` is convex per corridor, but the
// corridors are not empty: staggered crates sit a couple of metres off the
// centreline, and standing towers sit on it. Walking straight at the next
// waypoint and hash-picking a 50° dodge is what pinned waves in the crate-wall
// pocket, or face-first into their own pylon. A flow field has no local
// minimum -- every walkable cell knows the downhill step toward its goal --
// so a wave streams through the wide gap instead of flipping a coin at the
// crate.
//
// Ten fields cover the destinations a minion actually has: the seven pylons
// and the three lane-ends a pusher walks when that lane is already flat.
// Occupancy is the static floor/cover map plus a disk per standing tower.
// The disk is a little fat so the continuous mover stays off the node
// spheres the disk is approximating. Goal cells are the walkable ring just
// outside that disk (or the stump itself once the tower is gone), which is
// also why a heavy holds the near pylon instead of walking into it.
//
// Rebuilt when a tower's standing bit flips, which is rare. Sampled every
// minion step. The client never allocates this.

FLOW_CELL   :: f32(0.5)
FLOW_ORIGIN :: f32(-128)
FLOW_N      :: 512
FLOW_CELLS  :: FLOW_N * FLOW_N

FLOW_FIELD_COUNT :: MAX_PYLONS + TEAM_COUNT // pylons 0..6, lane-ends 7..9

FLOW_INF :: u16(0xFFFF)

// A little fatter than the body so a discrete cell that grazes a wall is
// marked blocked and the stream stays in the open.
FLOW_PAD :: MINION_RADIUS_M + 0.08

FLOW_GOAL_R_CENTRE :: f32(3.4)
FLOW_GOAL_R_PYLON  :: f32(3.0)
FLOW_GOAL_R_LANE   :: f32(4.0)

FLOW_TOWER_SLACK :: f32(0.25)

FLOW_Q_CAP :: 1 << 16

Nav_Flow :: struct {
	walk_static: [FLOW_CELLS]u8, // 1 = floor minus cover, towers ignored
	walk:        [FLOW_CELLS]u8, // walk_static minus standing-tower disks
	cost:        [FLOW_FIELD_COUNT][FLOW_CELLS]u16,
	q:           [FLOW_Q_CAP]u32,
	standing:    u32,
	walkable:    int,
	ready:       bool,
}

g_nav: ^Nav_Flow

nav_flow_idx :: proc(ix, iy: int) -> int {
	return iy * FLOW_N + ix
}

nav_flow_in :: proc(ix, iy: int) -> bool {
	return uint(ix) < uint(FLOW_N) && uint(iy) < uint(FLOW_N)
}

nav_flow_cell_center :: proc(ix, iy: int) -> vec3 {
	return {
		FLOW_ORIGIN + (f32(ix) + 0.5) * FLOW_CELL,
		FLOW_ORIGIN + (f32(iy) + 0.5) * FLOW_CELL,
		WORLD_FLOOR_Z + MINION_HEIGHT_M * 0.5,
	}
}

nav_flow_cell_of :: proc(p: vec3) -> (ix, iy: int) {
	ix = int(math.floor((p.x - FLOW_ORIGIN) / FLOW_CELL))
	iy = int(math.floor((p.y - FLOW_ORIGIN) / FLOW_CELL))
	return
}

nav_flow_anchor :: proc(field: int) -> vec3 {
	if field < 0 {
		return {}
	}
	if field < MAX_PYLONS {
		return pylon_base_position(field)
	}
	ti := field - MAX_PYLONS
	p := team_dir(team_from_index(ti)) * WORLD_LANE_R1
	p.z = WORLD_FLOOR_Z
	return p
}

nav_flow_goal_r :: proc(field: int) -> f32 {
	if field <= 0 {
		return FLOW_GOAL_R_CENTRE
	}
	if field < MAX_PYLONS {
		return FLOW_GOAL_R_PYLON
	}
	return FLOW_GOAL_R_LANE
}

// Nearest baked destination to `goal`. Advance and rebuild always hit a pylon
// or a lane-end; a cross-lane rush uses this to path through the plaza.
nav_flow_field_for :: proc(goal: vec3) -> int {
	best := 0
	best_d := f32(1e18)
	for i in 0 ..< FLOW_FIELD_COUNT {
		a := nav_flow_anchor(i)
		dx := goal.x - a.x
		dy := goal.y - a.y
		d2 := dx * dx + dy * dy
		if d2 < best_d {
			best_d = d2
			best = i
		}
	}
	return best
}

nav_flow_init :: proc(towers: ^Tower_World) {
	if g_nav != nil {
		nav_flow_sync(towers)
		return
	}
	g_nav = new(Nav_Flow)
	n := g_nav
	for i in 0 ..< FLOW_CELLS {
		p := nav_flow_cell_center(i % FLOW_N, i / FLOW_N)
		n.walk_static[i] = world_map_point_free(p, FLOW_PAD) ? 1 : 0
	}
	n.standing = 0xFFFFFFFF // force the first stamp
	nav_flow_rebuild(towers)
	nav_flow_selftest()
}

nav_flow_standing_mask :: proc(towers: ^Tower_World) -> u32 {
	mask: u32 = 0
	if towers == nil {
		return 0
	}
	for i in 0 ..< towers.count {
		if towers.towers[i].live_count > 0 {
			mask |= u32(1) << u32(i)
		}
	}
	return mask
}

// Cheap no-op unless a tower came up or went down since the last bake.
nav_flow_sync :: proc(towers: ^Tower_World) {
	if g_nav == nil {
		nav_flow_init(towers)
		return
	}
	mask := nav_flow_standing_mask(towers)
	if mask == g_nav.standing && g_nav.ready {
		return
	}
	nav_flow_rebuild(towers)
}

@(private = "file")
nav_flow_rebuild :: proc(towers: ^Tower_World) {
	n := g_nav
	if n == nil {
		return
	}
	n.standing = nav_flow_standing_mask(towers)
	for i in 0 ..< FLOW_CELLS {
		n.walk[i] = n.walk_static[i]
	}
	if towers != nil {
		for i in 0 ..< towers.count {
			t := &towers.towers[i]
			if t.live_count <= 0 {
				continue
			}
			r := tower_outer_radius(t) + FLOW_PAD + FLOW_TOWER_SLACK
			nav_flow_stamp_disk(n, t.base.x, t.base.y, r)
		}
	}
	walkable := 0
	for i in 0 ..< FLOW_CELLS {
		if n.walk[i] != 0 {
			walkable += 1
		}
	}
	n.walkable = walkable
	for f in 0 ..< FLOW_FIELD_COUNT {
		nav_flow_integrate(n, f)
	}
	n.ready = true
	fmt.printf("[Nav] flow %d fields, %d walkable / %d cells (%.2f m), standing 0x%x\n",
		FLOW_FIELD_COUNT, walkable, FLOW_CELLS, FLOW_CELL, n.standing)
}

@(private = "file")
nav_flow_stamp_disk :: proc(n: ^Nav_Flow, x, y, r: f32) {
	if r <= 0 {
		return
	}
	r2 := r * r
	ix0, iy0 := nav_flow_cell_of({x - r, y - r, 0})
	ix1, iy1 := nav_flow_cell_of({x + r, y + r, 0})
	ix0 = clamp_int(ix0, 0, FLOW_N - 1)
	iy0 = clamp_int(iy0, 0, FLOW_N - 1)
	ix1 = clamp_int(ix1, 0, FLOW_N - 1)
	iy1 = clamp_int(iy1, 0, FLOW_N - 1)
	for iy in iy0 ..= iy1 {
		for ix in ix0 ..= ix1 {
			c := nav_flow_cell_center(ix, iy)
			dx := c.x - x
			dy := c.y - y
			if dx * dx + dy * dy <= r2 {
				n.walk[nav_flow_idx(ix, iy)] = 0
			}
		}
	}
}

@(private = "file")
nav_flow_integrate :: proc(n: ^Nav_Flow, field: int) {
	cost := n.cost[field][:]
	for i in 0 ..< FLOW_CELLS {
		cost[i] = FLOW_INF
	}
	anchor := nav_flow_anchor(field)
	goal_r := nav_flow_goal_r(field)
	goal_r2 := goal_r * goal_r

	head: u32 = 0
	tail: u32 = 0

	ix0, iy0 := nav_flow_cell_of({anchor.x - goal_r, anchor.y - goal_r, 0})
	ix1, iy1 := nav_flow_cell_of({anchor.x + goal_r, anchor.y + goal_r, 0})
	ix0 = clamp_int(ix0, 0, FLOW_N - 1)
	iy0 = clamp_int(iy0, 0, FLOW_N - 1)
	ix1 = clamp_int(ix1, 0, FLOW_N - 1)
	iy1 = clamp_int(iy1, 0, FLOW_N - 1)
	seeds := 0
	for iy in iy0 ..= iy1 {
		for ix in ix0 ..= ix1 {
			idx := nav_flow_idx(ix, iy)
			if n.walk[idx] == 0 {
				continue
			}
			c := nav_flow_cell_center(ix, iy)
			dx := c.x - anchor.x
			dy := c.y - anchor.y
			if dx * dx + dy * dy > goal_r2 {
				continue
			}
			cost[idx] = 0
			n.q[tail] = u32(idx)
			tail = (tail + 1) & u32(FLOW_Q_CAP - 1)
			seeds += 1
		}
	}
	if seeds == 0 {
		fmt.printf("[Nav] field %d has no goal cells at (%.1f, %.1f)\n", field, anchor.x, anchor.y)
		return
	}

	offs := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for head != tail {
		cur := int(n.q[head])
		head = (head + 1) & u32(FLOW_Q_CAP - 1)
		cx := cur % FLOW_N
		cy := cur / FLOW_N
		next := cost[cur] + 1
		if next == FLOW_INF {
			continue
		}
		for o in offs {
			nx := cx + o[0]
			ny := cy + o[1]
			if !nav_flow_in(nx, ny) {
				continue
			}
			ni := nav_flow_idx(nx, ny)
			if n.walk[ni] == 0 {
				continue
			}
			if next < cost[ni] {
				cost[ni] = next
				n.q[tail] = u32(ni)
				tail = (tail + 1) & u32(FLOW_Q_CAP - 1)
				if tail == head {
					head = (head + 1) & u32(FLOW_Q_CAP - 1)
				}
			}
		}
	}
}

// Unit XY direction that downhill-steps the field at `p`. false if we are off
// the baked map or the field never reached this cell (a hole, a stamp).
nav_flow_dir :: proc(field: int, p: vec3) -> (dir: vec3, ok: bool) {
	n := g_nav
	if n == nil || !n.ready || field < 0 || field >= FLOW_FIELD_COUNT {
		return {}, false
	}
	ix, iy := nav_flow_cell_of(p)
	if !nav_flow_in(ix, iy) {
		return {}, false
	}
	cost := n.cost[field][:]
	best := FLOW_INF
	bx, by := 0, 0
	// 8-neighbour step on a 4-connected cost so the stream can cut a corner
	// in the open without the integrator itself cutting through a wall gap.
	for oy in -1 ..= 1 {
		for ox in -1 ..= 1 {
			if ox == 0 && oy == 0 {
				continue
			}
			nx := ix + ox
			ny := iy + oy
			if !nav_flow_in(nx, ny) {
				continue
			}
			ni := nav_flow_idx(nx, ny)
			if n.walk[ni] == 0 {
				continue
			}
			c := cost[ni]
			if c < best {
				best = c
				bx = ox
				by = oy
			}
		}
	}
	self := cost[nav_flow_idx(ix, iy)]
	if best == FLOW_INF {
		return {}, false
	}
	if self != FLOW_INF && best >= self {
		// Already on a goal cell, or a flat pocket: stay put.
		return {}, true
	}
	d := vec3{f32(bx), f32(by), 0}
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 0.01 {
		return {}, true
	}
	return {d.x / l, d.y / l, 0}, true
}

nav_flow_cost_at :: proc(field: int, p: vec3) -> u16 {
	n := g_nav
	if n == nil || !n.ready || field < 0 || field >= FLOW_FIELD_COUNT {
		return FLOW_INF
	}
	ix, iy := nav_flow_cell_of(p)
	if !nav_flow_in(ix, iy) {
		return FLOW_INF
	}
	return n.cost[field][nav_flow_idx(ix, iy)]
}

@(private = "file")
nav_flow_selftest :: proc() {
	n := g_nav
	if n == nil || !n.ready {
		return
	}
	for team in TEAMS {
		p := minion_spawn_position(team, 2)
		c := nav_flow_cost_at(0, p)
		if c == FLOW_INF {
			fmt.printf("[Nav] spawn %s cannot reach the centre field\n", team_name(team))
			continue
		}
		reached := false
		for _ in 0 ..< 800 {
			if p.x * p.x + p.y * p.y <= 8 * 8 {
				reached = true
				break
			}
			d, ok := nav_flow_dir(0, p)
			if !ok || len2_vec3(d) < 0.01 {
				break
			}
			p += d * FLOW_CELL
			p.z = WORLD_FLOOR_Z
		}
		if !reached {
			fmt.printf("[Nav] follow from %s spawn did not reach the plaza\n", team_name(team))
		}
	}
}
