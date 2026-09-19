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

// A beam's bite, and how much rock a whole second of it removes. Amount is
// scaled by toughness into node HP, so gold takes several bites to kill a node.
BEAM_BITE_AMOUNT :: f32(0.60)
// A detonation is one big stamp rather than a series of bites.
BLAST_AMOUNT     :: f32(0.85)
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
		at := origin + dir * t
		radius := max(MINE_BITE_MIN_R, tw.node_radius * 1.15)
		ore, ok := tower_mine(towers, tower_id, at, radius, BEAM_BITE_AMOUNT, id, world.teams[i])
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
// already knows it ran into something solid but not what.
//
// Reads the tower world through the global rather than taking it as an argument
// because the projectile system is shared with the client and has no server
// handle to thread through -- the same reason `world_point_free` finds the map
// boxes that way.
mining_blast :: proc(at: vec3, radius: f32, owner: Entity_ID, team: Team_ID) {
	if g_towers == nil {
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
	ore, mined := tower_mine(g_towers, id, at, r, BLAST_AMOUNT, owner, team)
	if !mined {
		return
	}
	tower_credit_ore(g_towers, id, ore)
}

// ---------------------------------------------------------------------------
// Harvest + Carry

// Simple carry rule: one chunk at a time. Multiple chunks stack into one carry slot.
ORE_CARRY_LIMIT :: f32(999.0)  // effectively no limit; chunks merge

// Players walking over settled ore pick it up into personal carry.
mining_harvest_tick :: proc(
	chunks: ^Ore_Chunk_World,
	world:  ^Entity_World,
	match:  ^Match,
) {
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
		at := char.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
		index, ok := ore_chunk_find_pickup(chunks, at)
		if !ok {
			continue
		}
		c := &chunks.chunks[index]
		// If carrying different ore, cannot pick up
		if char.carrying_ore != .None && char.carrying_ore != c.ore {
			continue
		}
		// If at limit, cannot pick up more
		if char.carrying_ore_amount >= ORE_CARRY_LIMIT {
			continue
		}
		// Pick up into carry
		pickup := min(c.amount, ORE_CARRY_LIMIT - char.carrying_ore_amount)
		char.carrying_ore = c.ore
		char.carrying_ore_amount += pickup
		if SERVER_VERBOSE {
			server_log("[Ore] %d picked up %.0f %s (now carrying %.0f)", id, pickup, ore_name(c.ore), char.carrying_ore_amount)
		}
		ore_chunk_consume(chunks, index)
	}
}

// Dump zone: standing in your team's base banks carried ore to wallet.
DUMP_ZONE_RADIUS :: f32(8.0)  // dump apron around base center

mining_dump_tick :: proc(world: ^Entity_World, match: ^Match, dt: f32) {
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
		if char.carrying_ore == .None || char.carrying_ore_amount <= 0 {
			continue
		}
		// Check if inside team dump zone
		dump_center := team_dump_position(team)
		d := vec3{char.pos.x - dump_center.x, char.pos.y - dump_center.y, 0}
		if len2_vec3(d) <= DUMP_ZONE_RADIUS * DUMP_ZONE_RADIUS {
			// Bank to team wallet
			match_credit_ore(match, team, char.carrying_ore, char.carrying_ore_amount)
			if SERVER_VERBOSE {
				server_log("[Ore] %d banked %.0f %s", id, char.carrying_ore_amount, ore_name(char.carrying_ore))
			}
			char.carrying_ore = .None
			char.carrying_ore_amount = 0
		}
	}
}

// Team dump position: at the back of each base
team_dump_position :: proc(team: Team_ID) -> vec3 {
	if team == .None || team == .Spectator {
		return {0, 0, WORLD_FLOOR_Z}
	}
	d := team_dir(team)
	p := d * (WORLD_SPAWN_R + 2.0)  // slightly behind spawn line
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
