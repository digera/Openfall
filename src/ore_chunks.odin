package main

import "core:math"

// Ore chunks: the lumps that come off a pylon and can be carried home.
//
// These are deliberately *not* voxel bodies. The towers are a core plus node
// spheres; what falls off them is cargo. A chunk is a grainy ellipsoid that
// samples its parent pylon's own noise field, so it still reads as a piece of
// that rock.
//
// Chunks are server-authoritative and replicated as small snapshot records.

// 64 is the sim pool. Snapshots and the shader only show the nearest eight
// (MAX_SNAPSHOT_CHUNKS / NCHUNK), so a hail of pebbles wastes both: most of
// the floor is invisible, and the eight you can see are tiny. Same-kind lumps
// that have settled next to each other collapse into one pile.
MAX_ORE_CHUNKS :: 64

// Physics. Heavier than a projectile and quick to settle: a floor covered in
// still-bouncing rubble is unreadable.
CHUNK_GRAVITY     :: f32(20.0)
CHUNK_BOUNCE      :: f32(0.32)
CHUNK_FRICTION    :: f32(4.5)
CHUNK_SETTLE_SPEED :: f32(0.55)
CHUNK_LIFETIME    :: f32(75.0)   // unclaimed ore sinks back into the ground
CHUNK_FADE        :: f32(4.0)    // warning before it goes

// A chunk is worth this much of its ore, scaled by size.
CHUNK_ORE_BASE :: f32(8.0)

CHUNK_PICKUP_R :: f32(1.1)
// Resting same-kind lumps closer than this become one pile. About a pickup
// radius: a mining site collapses into a handful of readable rocks instead of
// a shower the snapshot window cannot show.
CHUNK_MERGE_R  :: f32(1.15)

CHUNK_RADIUS_MIN :: f32(0.20)
CHUNK_RADIUS_MAX :: f32(0.70)
CHUNK_RADIUS_REF :: f32(0.28)

Ore_Chunk_ID :: u16

Ore_Chunk :: struct {
	active: bool,
	id:     Ore_Chunk_ID,
	ore:    Ore_Kind,
	pos:    vec3,
	vel:    vec3,
	radius: f32,
	seed:   f32,
	amount: f32,   // ore credited on pickup
	age:    f32,
	rest:   bool,  // settled on the ground and ready to be taken

	// Which tower it came off, so the shader can shade it with that tower's
	// vein colour rather than inventing a new material.
	source: Pylon_ID,
}

Ore_Chunk_World :: struct {
	chunks:  [MAX_ORE_CHUNKS]Ore_Chunk,
	count:   int,
	next_id: Ore_Chunk_ID,
}

ore_chunk_world_init :: proc(world: ^Ore_Chunk_World) {
	world^ = {}
	world.next_id = 1
}

ore_chunk_world_reset :: proc(world: ^Ore_Chunk_World) {
	for i in 0 ..< MAX_ORE_CHUNKS {
		world.chunks[i].active = false
	}
	world.count = 0
}

@(private = "file")
ore_chunk_claim :: proc(world: ^Ore_Chunk_World) -> ^Ore_Chunk {
	for i in 0 ..< MAX_ORE_CHUNKS {
		if !world.chunks[i].active {
			c := &world.chunks[i]
			c^ = Ore_Chunk{}
			c.active = true
			c.id = world.next_id
			world.next_id += 1
			if world.next_id == 0 {
				world.next_id = 1
			}
			world.count += 1
			return c
		}
	}
	// Floor is full. Prefer the oldest resting chunk; if everything is still
	// bouncing, take the oldest lump of any kind. Refusing to pay out reads
	// as the tower not breaking, and a full shower must not delete a haul.
	oldest_rest := -1
	best_rest := f32(-1)
	oldest_any := -1
	best_any := f32(-1)
	for i in 0 ..< MAX_ORE_CHUNKS {
		c := &world.chunks[i]
		if !c.active {
			continue
		}
		if c.age > best_any {
			best_any = c.age
			oldest_any = i
		}
		if c.rest && c.age > best_rest {
			best_rest = c.age
			oldest_rest = i
		}
	}
	oldest := oldest_rest >= 0 ? oldest_rest : oldest_any
	if oldest < 0 {
		return nil
	}
	c := &world.chunks[oldest]
	c^ = Ore_Chunk{}
	c.active = true
	c.id = world.next_id
	world.next_id += 1
	if world.next_id == 0 {
		world.next_id = 1
	}
	return c
}

// Volume-matched radius so a merged pile reads as more rock, not a brighter
// pebble. Cube-root of (amount / base) keeps a 100-unit haul about a torso
// wide instead of a millstone.
ore_chunk_radius_for :: proc(amount: f32) -> f32 {
	u := max(amount / CHUNK_ORE_BASE, 0.2)
	return clampf(CHUNK_RADIUS_REF * math.pow(u, 1.0 / 3.0), CHUNK_RADIUS_MIN, CHUNK_RADIUS_MAX)
}

@(private = "file")
ore_chunk_fill_loose :: proc(c: ^Ore_Chunk, kind: Ore_Kind, at: vec3, amount: f32, vel: vec3) {
	c.ore = kind
	ti := team_index(ore_team(kind))
	c.source = Pylon_ID(ti >= 0 ? ti + 1 : 0)
	c.pos = at
	c.vel = vel
	c.amount = amount
	c.radius = ore_chunk_radius_for(amount)
	h := hash_u32(u32(c.id) * 2246822519 + 911)
	c.seed = f32((h >> 16) & 0xFFFF) / f32(0x10000) * 8
}

// A lump of ore spawned in world space: what comes off a tower or what a
// lane minion leaves where it fell. It borrows its team's near-lane tower
// as a source so a wave's ore is shaded as the same rock their towers are
// made of.
ore_chunk_spawn_loose :: proc(world: ^Ore_Chunk_World, kind: Ore_Kind, at: vec3, amount: f32) -> ^Ore_Chunk {
	c := ore_chunk_claim(world)
	if c == nil {
		return nil
	}
	h := hash_u32(u32(c.id) * 2246822519 + 911)
	a := f32(h & 0xFFFF) / f32(0x10000) * (2 * PI_F32)
	ore_chunk_fill_loose(c, kind, at, amount, {math.cos(a) * 1.2, math.sin(a) * 1.2, 2.4})
	return c
}

// Same as loose, but the caller names the toss. Used to throw a haul forward
// so it does not land in the picker's own pickup radius.
ore_chunk_spawn_tossed :: proc(world: ^Ore_Chunk_World, kind: Ore_Kind, at: vec3, amount: f32, vel: vec3) -> ^Ore_Chunk {
	c := ore_chunk_claim(world)
	if c == nil {
		return nil
	}
	ore_chunk_fill_loose(c, kind, at, amount, vel)
	return c
}

// Step every chunk. Collides against the map and the pylons so ore that falls
// off a tower lands beside it instead of through it.
ore_chunk_tick :: proc(world: ^Ore_Chunk_World, dt: f32) {
	if world.count <= 0 {
		return
	}
	for i in 0 ..< MAX_ORE_CHUNKS {
		c := &world.chunks[i]
		if !c.active {
			continue
		}
		c.age += dt
		if c.age >= CHUNK_LIFETIME {
			c.active = false
			world.count -= 1
			continue
		}
		if c.rest {
			continue
		}

		c.vel.z -= CHUNK_GRAVITY * dt
		want := c.pos + c.vel * dt

		// Floor first: the common case and the one that has to feel solid.
		if want.z <= WORLD_FLOOR_Z + c.radius {
			want.z = WORLD_FLOOR_Z + c.radius
			if c.vel.z < 0 {
				c.vel.z = -c.vel.z * CHUNK_BOUNCE
			}
			// Ground drag, then sleep once it stops sliding.
			damp := max(0, 1 - CHUNK_FRICTION * dt)
			c.vel.x *= damp
			c.vel.y *= damp
			if len_vec3({c.vel.x, c.vel.y, max(c.vel.z, 0)}) < CHUNK_SETTLE_SPEED {
				c.vel = {}
				c.rest = true
			}
		}

		// Walls, cover and standing ore all come back through world_point_free,
		// and world_surface_normal reads the pylon SDF gradient, so a lump
		// sliding down a mined face follows the shape it was cut from.
		pad := c.radius * 0.8
		if !world_point_free(want, pad) {
			n := world_surface_normal(c.pos, want, pad)
			c.vel = (c.vel - n * (2 * dot_vec3(c.vel, n))) * CHUNK_BOUNCE
			want = c.pos + n * (pad * 0.5)
		}
		c.pos = want
	}
	ore_chunk_consolidate(world)
}

// Collapse settled same-kind lumps that share a patch of floor. One pass is
// enough: a survivor that just absorbed a neighbour is still visited by later
// indices, so a clump becomes one pile the tick it stops bouncing.
@(private = "file")
ore_chunk_consolidate :: proc(world: ^Ore_Chunk_World) {
	if world.count < 2 {
		return
	}
	r2 := CHUNK_MERGE_R * CHUNK_MERGE_R
	for i in 0 ..< MAX_ORE_CHUNKS {
		a := &world.chunks[i]
		if !a.active || !a.rest {
			continue
		}
		for j in i + 1 ..< MAX_ORE_CHUNKS {
			b := &world.chunks[j]
			if !b.active || !b.rest || a.ore != b.ore {
				continue
			}
			if len2_vec3(a.pos - b.pos) > r2 {
				continue
			}
			total := a.amount + b.amount
			if total > 0.001 {
				a.pos = (a.pos * a.amount + b.pos * b.amount) * (1.0 / total)
				a.age = (a.age * a.amount + b.age * b.amount) / total
			}
			a.amount = total
			a.radius = ore_chunk_radius_for(total)
			a.pos.z = max(a.pos.z, WORLD_FLOOR_Z + a.radius)
			ore_chunk_consume(world, j)
		}
	}
}

// Nearest claimable chunk within reach of a point.
ore_chunk_find_pickup :: proc(world: ^Ore_Chunk_World, at: vec3) -> (id: int, ok: bool) {
	best := CHUNK_PICKUP_R * CHUNK_PICKUP_R
	found := -1
	for i in 0 ..< MAX_ORE_CHUNKS {
		c := &world.chunks[i]
		if !c.active || !c.rest {
			continue
		}
		d2 := len2_vec3(c.pos - at)
		if d2 < best {
			best = d2
			found = i
		}
	}
	if found < 0 {
		return 0, false
	}
	return found, true
}

ore_chunk_consume :: proc(world: ^Ore_Chunk_World, index: int) {
	if index < 0 || index >= MAX_ORE_CHUNKS {
		return
	}
	if world.chunks[index].active {
		world.chunks[index].active = false
		world.count -= 1
	}
}
