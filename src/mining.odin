package main

import "core:fmt"

// Turning spells into mined ore.
//
// Pylons are not entities, so none of the targeted combat paths can touch them.
// Only positional damage carves: a projectile stamps a blast sphere where it
// lands, and a held beam bites on a fixed cadence. Call Lightning and Heal name
// an Entity_ID and therefore cannot reach a tower at all, which is the behaviour
// we want and costs no special case to get.
//
// The bite cadence is the load-bearing choice here. A beam could carve every
// tick, but then mining would melt the rock in a single hold. At ten bites a
// second the tower comes apart with an audible rhythm, and node HP on the
// wire moves as soon as a bite actually removes rock.

// Per-entity mining cadence. Lives beside the pylons rather than in the spell
// state because it is a property of chewing rock, not of casting.
Mining_State :: struct {
	bite_timer: [MAX_ENTITIES]f32,
}

// A beam bite is combat DPS on the mining cadence, so a second of Thunderbolt
// on a node is the same budget that kills a fodder. Toughness then scales that
// into node HP, so gold still takes several bites more than a lane slot.
BLAST_RADIUS_MULT :: f32(0.55)

// Which spells can work rock at all. A beam is a cutting tool; a bolt of
// lightning aimed at a person is not.
spell_mines :: proc(id: Spell_ID) -> bool {
	def := &SPELL_DEFS[id]
	return def.payload == .Beam || def.payload == .Projectile
}

mining_reset :: proc(state: ^Mining_State) {
	state^ = {}
}

// One tick of every lit beam against the towers.
//
// Runs after `beams_tick` so a beam that just went out this tick does not get a
// free bite. The raycast is independent of the beam's own trace because the beam
// stops at whatever `world_point_free` says is solid -- which now includes ore --
// and what we need here is specifically *which* pylon and *where* on it.
mining_beams_tick :: proc(
	state:   ^Mining_State,
	towers:  ^Tower_World,
	chunks:  ^Ore_Chunk_World,
	world:   ^Entity_World,
	dt:      f32,
	allowed: bool,
) {
	if towers == nil {
		return
	}
	for i in 1 ..< MAX_ENTITIES {
		id := Entity_ID(i)
		ss := &world.spell_states[i]
		if !allowed || !spell_state_beaming(ss) || !entity_alive(world, id) {
			state.bite_timer[i] = 0
			continue
		}
		if !spell_mines(ss.channel_spell) {
			continue
		}

		state.bite_timer[i] += dt
		if state.bite_timer[i] < MINE_BITE_DT {
			continue
		}
		// Carry the remainder rather than dropping it, so the bite rate does not
		// drift with the tick rate.
		state.bite_timer[i] -= MINE_BITE_DT

		def := &SPELL_DEFS[ss.channel_spell]
		char := world.characters[i]
		origin := vec3{char.pos.x, char.pos.y, char.pos.z + PLAYER_EYE_M}
		dir := camera_forward(char.yaw, char.pitch)

		t, tower_id, _, hit := tower_raycast(towers, origin, dir, def.range)
		if !hit {
			continue
		}
		// A body in front of the rock shields it: you cannot mine through a
		// player standing against the tower, or through the wave that walked in
		// to defend it -- which is the whole point of sending one.
		if body_blocks_beam(world, id, origin, dir, t) {
			continue
		}
		if _, _, blocked := minion_raycast(g_minions, world.teams[i], origin, dir, t); blocked {
			continue
		}
		tw := tower_get(towers, tower_id)
		if tw == nil {
			continue
		}
		amount := def.beam_dps * MINE_BITE_DT
		if amount <= 0 {
			continue
		}
		at := origin + dir * t
		radius := max(MINE_BITE_MIN_R, tw.node_radius * 1.15)
		ore, ok := tower_mine(towers, tower_id, at, radius, amount, id, world.teams[i])
		if !ok {
			continue
		}
		tower_credit_ore(towers, tower_id, ore)
		_ = chunks
	}
}

// Is a hostile body between the caster's eye and the rock at `dist`? Mirrors
// how `beam_trace` picks its victim, so the beam cannot both damage a player and
// chew the tower behind them in the same tick.
@(private = "file")
body_blocks_beam :: proc(world: ^Entity_World, caster: Entity_ID, origin, dir: vec3, dist: f32) -> bool {
	team := world.teams[caster]
	for i in 1 ..< MAX_ENTITIES {
		id := Entity_ID(i)
		if id == caster || !entity_alive(world, id) {
			continue
		}
		if !teams_are_enemies(team, world.teams[i]) {
			continue
		}
		if _, ok := ray_cylinder_hit(origin, dir, world.characters[i].pos, CHARACTER_RADIUS_M, CHARACTER_HEIGHT_M, dist); ok {
			return true
		}
	}
	return false
}

// A detonation against a tower. Called from the projectile impact path, which
// already knows it ran into something solid but not what. `amount` is the
// projectile's combat damage so an orb that pops a fodder also pops a node.
//
// Reads the tower world through the global rather than taking it as an argument
// because the projectile system is shared with the client and has no server
// handle to thread through -- the same reason `world_point_free` finds the map
// boxes that way.
mining_blast :: proc(at: vec3, radius: f32, amount: f32, owner: Entity_ID, team: Team_ID) {
	if g_towers == nil || amount <= 0 {
		return
	}
	pad := max(radius, 0.5) + 2.5
	id, ok := tower_at_point(g_towers, at, pad)
	if !ok {
		return
	}
	tw := tower_get(g_towers, id)
	if tw == nil {
		return
	}

	r := max(MINE_BITE_MIN_R, max(radius * BLAST_RADIUS_MULT, tw.node_radius * 0.85))
	ore, mined := tower_mine(g_towers, id, at, r, amount, owner, team)
	if !mined {
		return
	}
	tower_credit_ore(g_towers, id, ore)
}

// ---------------------------------------------------------------------------
// Harvest + Carry

// Shared across all ore kinds. A gold node is 18 and a lane node is 8, so a
// full pack is several prize lumps or a dozen ordinary chunks: you can stay
// out for a real haul, but you still cannot vacuum the floor.
CARRY_CAPACITY_MAX :: f32(100.0)

// Linear slow from 1.0 empty to CARRY_SPEED_MIN at a full pack. Load and
// speed share CARRY_CAPACITY_MAX, so a bigger haul always costs more legs.
// Applied in the shared simulation step so bots, players and client
// prediction all feel the same weight.
CARRY_SPEED_MIN :: f32(0.60)

// Full haul saturates a u8. 100.0 packs as 255, ~0.4 unit resolution, four
// bytes for four kinds instead of sixteen floats that would blow the MTU.
CARRY_WIRE_SCALE :: f32(2.55)

// Bots turn for home once they are holding most of a pack, and keep walking
// until the dump actually empties them.
CARRY_DUMP_THRESHOLD :: f32(60.0)

// Dump apron at the back of each base, matching the spawn fan. Shader rings
// in scene.glsl must stay on these two numbers.
DUMP_ZONE_BACK   :: f32(2.0)
DUMP_ZONE_RADIUS :: f32(8.0)

carry_total :: proc(carry: [ORE_COUNT]f32) -> f32 {
	sum := f32(0)
	for amt in carry {
		sum += amt
	}
	return sum
}

carry_dominant :: proc(carry: [ORE_COUNT]f32) -> Ore_Kind {
	kind := Ore_Kind.None
	best := f32(0)
	for k in 0 ..< ORE_COUNT {
		if carry[k] > best {
			best = carry[k]
			kind = ore_from_index(k)
		}
	}
	return kind
}

carry_speed_mult :: proc(carry: [ORE_COUNT]f32) -> f32 {
	load := saturate(carry_total(carry) / CARRY_CAPACITY_MAX)
	return lerpf(1.0, CARRY_SPEED_MIN, load)
}

// Players walking over settled ore pick it up into personal carry (multi-kind,
// shared 100 cap). Partial pickup leaves the remainder on the ground.
//
// One pass over the floor: each lump goes to the nearest living body in range
// that still has room. Walking a pile therefore vacuums it in a tick, and two
// people standing on the same scatter split it by who is closer to each rock
// rather than by entity-id order taking the whole heap.
mining_harvest_tick :: proc(chunks: ^Ore_Chunk_World, world: ^Entity_World) {
	if chunks.count <= 0 {
		return
	}
	reach2 := CHUNK_PICKUP_R * CHUNK_PICKUP_R
	for ci in 0 ..< MAX_ORE_CHUNKS {
		c := &chunks.chunks[ci]
		if !c.active || !c.rest {
			continue
		}
		slot := ore_index_of(c.ore)
		if slot < 0 {
			continue
		}
		best_i := -1
		best_d2 := reach2
		for i in 1 ..< MAX_ENTITIES {
			id := Entity_ID(i)
			if !entity_alive(world, id) {
				continue
			}
			team := world.teams[i]
			if team == .None || team == .Spectator {
				continue
			}
			char := &world.characters[i]
			if carry_total(char.carrying_ore) >= CARRY_CAPACITY_MAX {
				continue
			}
			// Reach from the body's middle, not its feet, so ore resting against a
			// step is still collectable.
			at := char.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
			d2 := len2_vec3(c.pos - at)
			if d2 < best_d2 {
				best_d2 = d2
				best_i = i
			}
		}
		if best_i < 0 {
			continue
		}
		char := &world.characters[best_i]
		total := carry_total(char.carrying_ore)
		pickup := min(c.amount, CARRY_CAPACITY_MAX - total)
		if pickup <= 0 {
			continue
		}
		char.carrying_ore[slot] += pickup
		if SERVER_VERBOSE {
			server_log("[Ore] %d picked up %.0f %s (now carrying %.0f / %.0f)",
				Entity_ID(best_i), pickup, ore_name(c.ore), carry_total(char.carrying_ore), CARRY_CAPACITY_MAX)
		}
		if pickup >= c.amount {
			ore_chunk_consume(chunks, ci)
		} else {
			c.amount -= pickup
			c.radius = ore_chunk_radius_for(c.amount)
		}
	}
}

// G tosses the pack onto the floor. Ignored in your own dump (standing there
// already banks) and while dead (death has its own drop). Newly tossed lumps
// are airborne, so harvest this tick cannot swallow them back.
mining_drop_tick :: proc(chunks: ^Ore_Chunk_World, world: ^Entity_World) {
	for i in 1 ..< MAX_ENTITIES {
		id := Entity_ID(i)
		if !world.inputs[i].drop {
			continue
		}
		if !entity_alive(world, id) {
			continue
		}
		char := world.characters[i]
		if carry_total(char.carrying_ore) <= 0 {
			continue
		}
		if in_dump_zone(char.pos, world.teams[i]) {
			continue
		}
		entity_drop_carried_ore(&char, chunks, id, camera_forward(char.yaw, 0))
		world.characters[i] = char
	}
}

// Client prediction: clear the pack so the legs speed up this tick. The server
// still owns the lumps on the floor; a failed spawn reconciles the ore back.
carry_apply_predicted_drop :: proc(char: ^Character_State, drop: bool) {
	if drop && !char.dead {
		char.carrying_ore = {}
	}
}

mining_dump_tick :: proc(world: ^Entity_World, match: ^Match) {
	for i in 1 ..< MAX_ENTITIES {
		id := Entity_ID(i)
		if !entity_alive(world, id) {
			continue
		}
		team := world.teams[i]
		char := &world.characters[i]
		if carry_total(char.carrying_ore) <= 0 || !in_dump_zone(char.pos, team) {
			continue
		}
		for k in 0 ..< ORE_COUNT {
			amt := char.carrying_ore[k]
			if amt <= 0 {
				continue
			}
			kind := ore_from_index(k)
			match_credit_ore(match, team, kind, amt)
			if SERVER_VERBOSE {
				server_log("[Ore] %d banked %.0f %s", id, amt, ore_name(kind))
			}
			char.carrying_ore[k] = 0
		}
	}
}

in_dump_zone :: proc(pos: vec3, team: Team_ID) -> bool {
	if team == .None || team == .Spectator {
		return false
	}
	c := team_dump_position(team)
	d := vec3{pos.x - c.x, pos.y - c.y, 0}
	return len2_vec3(d) <= DUMP_ZONE_RADIUS * DUMP_ZONE_RADIUS
}

// Back of the spawn fan, so walking into your own base to respawn or reset
// is also the banking trip. Enemy dumps do nothing.
team_dump_position :: proc(team: Team_ID) -> vec3 {
	if team == .None || team == .Spectator {
		return {0, 0, WORLD_FLOOR_Z}
	}
	p := team_dir(team) * (WORLD_SPAWN_R + DUMP_ZONE_BACK)
	p.z = WORLD_FLOOR_Z
	return p
}

mining_report :: proc(towers: ^Tower_World) {
	fmt.print("[Tower] standing:")
	for i in 0 ..< towers.count {
		t := &towers.towers[i]
		fmt.printf(" %d:%s %.0f%%", i, ore_name(t.ore), t.intact * 100)
	}
	fmt.println()
}
