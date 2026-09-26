package main

// Gust: a wind rune dropped on the floor a stride ahead of its caster. Whoever
// steps on it is thrown up and on along the way they were already going, once
// per rune per body. Caster, ally and enemy alike: a rune left on an escape
// route is a rune the chaser can ride too.
//
// It adds speed; it does not set it. A second rune stacks on the first, and a
// timed hop off the landing keeps all of it (simulation.odin), so a chain of
// runes and hops is how anyone goes fast -- paid for in mana for the runes and
// in health for every landing faster than a sprint.
//
// The touch is decided by the same procedure on both ends. The server's call
// is final; the owning client runs it in its prediction too, so the launch
// happens the tick the feet reach the rune instead of a round trip later.

MAX_GUST_PADS       :: 24
GUST_PAD_LIFETIME   :: f32(5.0)
GUST_PAD_RADIUS_M   :: f32(0.9)
GUST_PAD_REACH_Z    :: f32(0.5)   // feet up to this far above the rune still touch it
GUST_BOOST_SPEED    :: f32(9.0)   // added along the rider's heading, m/s
GUST_LIFT_SPEED     :: f32(8.0)   // up: a 1.45 m arc that lands just short of fall damage

#assert(GUST_LIFT_SPEED < FALL_SAFE_SPEED)
#assert(MAX_ENTITIES <= 64) // riders is one bit per entity

Gust_Pad :: struct {
	active: bool,
	id:     u8,        // identity on the wire; wraps, and 0 is never used
	owner:  Entity_ID,
	team:   Team_ID,   // the caster's, for the colour of the rune
	pos:    vec3,      // centre, on the surface it lies on
	life:   f32,       // seconds left
	riders: u64,       // bit per entity already launched by this rune
}

Gust_Pad_World :: struct {
	pads:    [MAX_GUST_PADS]Gust_Pad,
	next_id: u8,
}

// Are these feet on the rune? Shared with the client's prediction.
gust_pad_touches :: proc(pad_pos, feet: vec3) -> bool {
	dx := feet.x - pad_pos.x
	dy := feet.y - pad_pos.y
	dz := feet.z - pad_pos.z
	return dx * dx + dy * dy <= GUST_PAD_RADIUS_M * GUST_PAD_RADIUS_M &&
	       dz >= -0.2 && dz <= GUST_PAD_REACH_Z
}

// Throw a body off a rune: up, and on along its heading. A body standing still
// goes the way it is facing. Shared with the client's prediction.
gust_launch :: proc(char: ^Character_State) {
	if char.dead {
		return
	}
	heading := vec3{char.vel.x, char.vel.y, 0}
	pace := len_vec3(heading)
	dir := pace > 1.0 ? heading * (1.0 / pace) : camera_forward(char.yaw, 0)
	vel_xy := clamp_horizontal(heading + dir * GUST_BOOST_SPEED, CHARACTER_MAX_SPEED)
	char.vel.x = vel_xy.x
	char.vel.y = vel_xy.y
	char.vel.z = max(char.vel.z, GUST_LIFT_SPEED)
	character_leave_ground(char)
}

// Where a rune cast by `char` lands: `reach` ahead along the look, on whatever
// is under that spot -- the floor, or the top of a crate. A spot inside a wall
// or a crate puts it at the caster's own feet instead.
gust_pad_spot :: proc(char: Character_State, reach: f32) -> vec3 {
	spot := char.pos + camera_forward(char.yaw, 0) * reach
	if !world_point_free(spot + vec3{0, 0, 0.2}, 0.1) {
		spot = char.pos
	}
	for spot.z > WORLD_FLOOR_Z {
		below := spot - vec3{0, 0, 0.1}
		if below.z <= WORLD_FLOOR_Z {
			spot.z = WORLD_FLOOR_Z
			break
		}
		if !world_point_free(below, 0) {
			break
		}
		spot = below
	}
	return spot
}

// Lay a rune. A full pool gives up its oldest.
gust_pad_place :: proc(world: ^Gust_Pad_World, owner: Entity_ID, team: Team_ID, pos: vec3) {
	slot := 0
	least := f32(1e30)
	for i in 0..<MAX_GUST_PADS {
		if !world.pads[i].active {
			slot = i
			break
		}
		if world.pads[i].life < least {
			least = world.pads[i].life
			slot = i
		}
	}
	world.next_id += 1
	if world.next_id == 0 {
		world.next_id = 1
	}
	world.pads[slot] = Gust_Pad{
		active = true,
		id     = world.next_id,
		owner  = owner,
		team   = team,
		pos    = pos,
		life   = GUST_PAD_LIFETIME,
	}
}

gust_pad_ridden_by :: proc(pad: ^Gust_Pad, id: Entity_ID) -> bool {
	return pad.riders & (u64(1) << u64(id)) != 0
}

// Server: age the runes and launch anyone standing on one they have not ridden.
// Runs after movement, the same place in the tick the client's prediction
// checks, so both ends see the feet where they finished the step.
gust_pads_tick :: proc(world: ^Gust_Pad_World, entities: ^Entity_World, dt: f32) {
	for i in 0..<MAX_GUST_PADS {
		pad := &world.pads[i]
		if !pad.active {
			continue
		}
		pad.life -= dt
		if pad.life <= 0 {
			pad.active = false
			continue
		}
		for e in 1..<MAX_ENTITIES {
			id := Entity_ID(e)
			if !entity_alive(entities, id) || gust_pad_ridden_by(pad, id) {
				continue
			}
			char := entities.characters[e]
			if !gust_pad_touches(pad.pos, char.pos) {
				continue
			}
			gust_launch(&char)
			entities.characters[e] = char
			pad.riders |= u64(1) << u64(id)
		}
	}
}

gust_pads_clear :: proc(world: ^Gust_Pad_World) {
	world.pads = {}
}
