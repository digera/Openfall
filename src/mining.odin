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
// tick, but then one miner would generate sixty replicated operations a second,
// which neither the snapshot window nor the determinism story can afford. At
// ten bites a second with proportionally more bite each, the rock comes apart at
// the same rate, the event stream stays small enough that ordinary packet loss
// is free, and mining gains an audible rhythm instead of melting smoothly.

// Per-entity mining cadence. Lives beside the pylons rather than in the spell
// state because it is a property of chewing rock, not of casting.
Mining_State :: struct {
	bite_timer: [MAX_ENTITIES]f32,
}

// A beam's bite, and how much rock a whole second of it removes. Density is in
// 0..1 at the centre of the bite, so this is "one bite takes 60% of the density
// where it lands" -- the falloff and the pylon's toughness do the rest.
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
	pylons:  ^Pylon_World,
	chunks:  ^Ore_Chunk_World,
	world:   ^Entity_World,
	dt:      f32,
	allowed: bool,
) {
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

		t, pylon_id, hit := pylon_raycast(pylons, origin, dir, def.range)
		if !hit {
			continue
		}
		// A body in front of the rock shields it: you cannot mine through a
		// player standing against the tower.
		if body_blocks_beam(world, id, origin, dir, t) {
			continue
		}
		at := origin + dir * t
		radius := max(MINE_BITE_MIN_R, PYLON_CELL * MINE_BITE_CELLS)
		ore, ok := pylon_mine(pylons, pylon_id, at, radius, BEAM_BITE_AMOUNT, id, world.teams[i])
		if !ok {
			continue
		}
		pylon_credit_ore(pylons, pylon_id, ore)
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
// Reads the pylon world through the global rather than taking it as an argument
// because the projectile system is shared with the client and has no server
// handle to thread through -- the same reason `world_point_free` finds the map
// boxes that way.
mining_blast :: proc(at: vec3, radius: f32, owner: Entity_ID, team: Team_ID) {
	if g_pylons == nil {
		return
	}
	// The blast has to find the rock it hit. A projectile stops a little short
	// of the surface, so probe with a generous pad.
	id, ok := pylon_at_point(g_pylons, at, max(radius, 0.5))
	if !ok {
		return
	}
	r := max(MINE_BITE_MIN_R, radius * BLAST_RADIUS_MULT)
	ore, mined := pylon_mine(g_pylons, id, at, r, BLAST_AMOUNT, owner, team)
	if !mined {
		return
	}
	pylon_credit_ore(g_pylons, id, ore)
}

// ---------------------------------------------------------------------------
// Harvest

// Players walking over settled ore pick it up. Phase 1 credits the team wallet
// on contact; carrying a lump home is Phase 2, and the wallet it pays into is
// already the one that will be used then.
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
		// Reach from the body's middle, not its feet, so ore resting against a
		// step is still collectable.
		at := world.characters[i].pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
		index, ok := ore_chunk_find_pickup(chunks, at)
		if !ok {
			continue
		}
		c := &chunks.chunks[index]
		match_credit_ore(match, team, c.ore, c.amount)
		if SERVER_VERBOSE {
			server_log("[Ore] %d collected %.0f %s", id, c.amount, ore_name(c.ore))
		}
		ore_chunk_consume(chunks, index)
	}
}

mining_report :: proc(pylons: ^Pylon_World) {
	fmt.print("[Pylon] standing:")
	for i in 0 ..< pylons.count {
		p := &pylons.pylons[i]
		fmt.printf(" %d:%s %.0f%%", i, ore_name(p.ore), p.intact * 100)
	}
	fmt.println()
}
