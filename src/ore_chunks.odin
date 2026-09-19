package main

import "core:math"

// Ore chunks: the lumps that come off a pylon and can be carried home.
//
// These are deliberately *not* voxel bodies. Giving every fragment its own
// density grid the way a single-player miner can afford would mean another 80 KB
// and another sphere-trace per fragment per pixel, and there are dozens of them
// on the floor at once. The towers are the sculpted objects; what falls off them
// is cargo. A chunk is a grainy ellipsoid that samples its parent pylon's own
// noise field, so it still reads as a piece of that rock.
//
// Chunks are server-authoritative and replicated as small snapshot records.

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

	// Which pylon it came off, so the shader can shade it with that pylon's
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
	// Floor is full. Replace the oldest resting chunk rather than refusing to
	// pay out: ore that never appears reads as the tower not breaking.
	oldest := -1
	best := f32(-1)
	for i in 0 ..< MAX_ORE_CHUNKS {
		if world.chunks[i].rest && world.chunks[i].age > best {
			best = world.chunks[i].age
			oldest = i
		}
	}
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

// Spawn one chunk in the pylon's local frame, thrown along `dir_local`.
@(private = "file")
ore_chunk_spawn :: proc(
	world:  ^Ore_Chunk_World,
	p:      ^Pylon,
	local:  vec3,
	dir_local: vec3,
	speed:  f32,
	radius: f32,
	amount: f32,
) -> ^Ore_Chunk {
	c := ore_chunk_claim(world)
	if c == nil {
		return nil
	}
	c.ore = p.ore
	c.source = p.id
	c.pos = pylon_to_world(p, local)
	c.vel = pylon_dir_to_world(p, dir_local) * speed
	c.vel.z += speed * 0.35
	c.radius = radius
	c.amount = amount
	// Seed off the pylon and the id so each lump is a different rock but the
	// family resemblance to its tower survives.
	h := hash_u32(u32(c.id) * 2246822519 + u32(p.id) * 668265263)
	c.seed = p.shape.seed + f32(h & 0xFFFF) / f32(0x10000) * 3
	return c
}

// One chunk popping out of the face a player is currently mining.
ore_chunk_spawn_at_face :: proc(world: ^Ore_Chunk_World, p: ^Pylon) {
	n := p.last_bite_n
	if len2_vec3(n) < 1e-6 {
		n = {1, 0, 0}
	}
	// Push the spawn point clear of the rock so it does not start embedded.
	local := p.last_bite + n * 0.45
	ore_chunk_spawn(world, p, local, n, 3.4, 0.30, CHUNK_ORE_BASE)
}

// A whole island sheared off. Its volume becomes several chunks scattered around
// the centroid, so knocking the top off a tower showers ore rather than dropping
// one implausibly large boulder.
ore_chunk_burst :: proc(world: ^Ore_Chunk_World, p: ^Pylon, centroid: vec3, voxels: int) {
	if voxels < PYLON_ISLAND_MIN_VOX {
		// Rubble: one small chunk so the ore is not simply lost.
		ore_chunk_spawn(world, p, centroid, {0, 0, 1}, 1.5, 0.22, CHUNK_ORE_BASE * 0.4)
		return
	}
	total := f32(voxels) * ORE_PER_VOXEL
	n := clamp_int(voxels / 14, 2, 8)
	each := total / f32(n)
	// Size each lump by the volume it represents, so a big collapse drops big
	// rocks and a graze drops pebbles.
	r := clampf(ore_grid_equivalent_radius(voxels / n) * 0.8, 0.20, 0.62)
	spread := ore_grid_equivalent_radius(voxels) * 0.6
	for k in 0 ..< n {
		h := hash_u32(u32(k) * 374761393 + u32(p.id) * 2654435761 + u32(voxels))
		a := f32(h & 0xFFFF) / f32(0x10000) * (2 * PI_F32)
		up := f32((h >> 16) & 0xFF) / 255.0
		dir := vec3{math.cos(a), math.sin(a), up * 0.8}
		off := vec3{math.cos(a), math.sin(a), 0} * spread * (f32((h >> 24) & 0xFF) / 255.0)
		ore_chunk_spawn(world, p, centroid + off, norm_vec3(dir), 2.2 + up * 2.6, r, each)
	}
}

// Step every chunk. Collides against the map and the pylons so ore that falls
// off a tower lands beside it instead of through it.
ore_chunk_tick :: proc(world: ^Ore_Chunk_World, dt: f32) {
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
