package main

// Server-authoritative beams: spells that work on whoever is in front of them
// for every tick they are held. There is no beam object; the beam is a state
// of its caster. The wind-up bookkeeping in server_advance_channel decides
// whether a beam is lit, this decides what it does while it is.

// One tick of every lit beam. Runs after the world has moved so the trace
// sees bodies where they are, not where they were. With `allowed` false (the
// match is over) every beam is put out instead.
beams_tick :: proc(world: ^Entity_World, dt: f32, allowed: bool) {
	for i in 1..<MAX_ENTITIES {
		id := Entity_ID(i)
		state := &world.spell_states[i]
		if !spell_state_beaming(state) {
			continue
		}
		if !allowed || !entity_alive(world, id) {
			beam_quench(world, id)
			continue
		}
		def := &SPELL_DEFS[state.channel_spell]
		char := world.characters[i]

		origin := vec3{char.pos.x, char.pos.y, char.pos.z + PLAYER_EYE_M}
		dir := camera_forward(char.yaw, char.pitch)

		// Running dry ends the beam and rests it. Without the rest, holding
		// the button at zero mana would relight it every few ticks of regen.
		drain := def.beam_mana_per_sec * dt
		if char.mana < drain {
			state.cooldowns[state.channel_spell] = def.cooldown_sec
			beam_quench(world, id)
			if SERVER_VERBOSE {
				server_log("[Combat] %s from %d sputtered out", def.short_name, id)
			}
			continue
		}
		char.mana -= drain
		world.characters[i] = char

		beam_trace(world, id, def, origin, dir, def.beam_dps * dt, &state.beam)
	}
}

// Light `spell` on `id` if they can pay to start it. A beam spends nothing on
// release, so this is the only place its cost and cooldown are asked about.
beam_light :: proc(world: ^Entity_World, id: Entity_ID, spell: Spell_ID) -> bool {
	state := &world.spell_states[id]
	if !spell_castable(spell, world.characters[id], state.cooldowns[spell]) {
		return false
	}
	state.channel_spell = spell
	state.channel_time = 0
	state.channel_committed = false
	state.release_aim = false
	state.beam = {}
	if SERVER_VERBOSE {
		server_log("[Combat] Entity %d lit %s", id, SPELL_DEFS[spell].name)
	}
	return true
}

// Put out whatever `id` is channeling. Harmless on a caster who is not.
beam_quench :: proc(world: ^Entity_World, id: Entity_ID) {
	state := &world.spell_states[id]
	state.channel_spell = .None
	state.channel_time = 0
	state.channel_committed = false
	state.release_aim = false
	state.beam = {}
}

// Trace one beam: the world clips it, the first hostile body (player or minion)
// along it takes `damage`, and the arcs jump from body to body behind it.
// Writes where it ended and who it touched into `out` for the snapshot.
beam_trace :: proc(world: ^Entity_World, caster_id: Entity_ID, def: ^Spell_Def, origin, dir: vec3, damage: f32, out: ^Beam_State) {
	caster_team := world.teams[caster_id]
	reach := world_ray_hit(origin, dir, def.range)

	hit := INVALID_ENTITY
	hit_dist := reach
	for i in 1..<MAX_ENTITIES {
		id := Entity_ID(i)
		if id == caster_id || !entity_alive(world, id) {
			continue
		}
		if !teams_are_enemies(caster_team, world.teams[i]) {
			continue
		}
		// Capping at the best distance so far keeps only the nearest body.
		dist, ok := ray_cylinder_hit(origin, dir, world.characters[i].pos, CHARACTER_RADIUS_M, CHARACTER_HEIGHT_M, hit_dist)
		if ok {
			hit = id
			hit_dist = dist
		}
	}

	// A minion in front of the player is a real body: it takes the primary
	// hit and the arcs can jump from it. Friendly minions are ignored by
	// minion_raycast, same team rule as players.
	hit_minion_slot := -1
	mt, mslot, mhit := minion_raycast(g_minions, caster_team, origin, dir, hit_dist)
	if mhit {
		hit = INVALID_ENTITY
		hit_minion_slot = mslot
		hit_dist = mt
	}

	out^ = {end = origin + dir * hit_dist, hit = hit, hit_minion = hit_minion_slot >= 0}

	if hit != INVALID_ENTITY {
		beam_damage(world, caster_id, hit, def.id, damage)
	} else if hit_minion_slot >= 0 {
		minion_damage(g_minions, hit_minion_slot, damage)
	} else {
		return
	}

	// Arcs: from the last body struck to the nearest hostile one (player or
	// minion) not yet struck, within jump range and in the open. Each jump
	// is worth a fraction of the beam so a crowd is hurt, not deleted.
	struck: u64 = 0
	if hit != INVALID_ENTITY {
		struck = u64(1) << u64(hit)
	}
	struck_minion_mask: u64 = 0
	if hit_minion_slot >= 0 {
		struck_minion_mask = u64(1) << u64(hit_minion_slot)
	}

	from: vec3
	if hit != INVALID_ENTITY {
		from = world.characters[hit].pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
	} else {
		from = minion_center(&g_minions.minions[hit_minion_slot])
	}

	for out.chain_count < def.beam_chain_count {
		next := INVALID_ENTITY
		next_minion_slot := -1
		next_d2 := def.beam_chain_range * def.beam_chain_range
		next_center: vec3

		for i in 1..<MAX_ENTITIES {
			id := Entity_ID(i)
			if id == caster_id || struck & (u64(1) << u64(i)) != 0 || !entity_alive(world, id) {
				continue
			}
			if !teams_are_enemies(caster_team, world.teams[i]) {
				continue
			}
			center := world.characters[i].pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
			d2 := len2_vec3(center - from)
			if d2 >= next_d2 {
				continue
			}
			if !world_segment_clear(from, center) {
				continue
			}
			next = id
			next_minion_slot = -1
			next_d2 = d2
			next_center = center
		}

		if g_minions != nil {
			for i in 0..<MAX_MINIONS {
				m := &g_minions.minions[i]
				if !m.active || m.health <= 0 {
					continue
				}
				if struck_minion_mask & (u64(1) << u64(i)) != 0 {
					continue
				}
				if !teams_are_enemies(caster_team, m.team) {
					continue
				}
				center := minion_center(m)
				d2 := len2_vec3(center - from)
				if d2 >= next_d2 {
					continue
				}
				if !world_segment_clear(from, center) {
					continue
				}
				next = INVALID_ENTITY
				next_minion_slot = i
				next_d2 = d2
				next_center = center
			}
		}

		if next == INVALID_ENTITY && next_minion_slot < 0 {
			break
		}

		if next != INVALID_ENTITY {
			beam_damage(world, caster_id, next, def.id, damage * def.beam_chain_frac)
			out.chains[out.chain_count] = next
			out.chain_minion_ids[out.chain_count] = 0
			out.chain_count += 1
			struck |= u64(1) << u64(next)
		} else {
			minion_damage(g_minions, next_minion_slot, damage * def.beam_chain_frac)
			out.chains[out.chain_count] = INVALID_ENTITY
			out.chain_minion_ids[out.chain_count] = g_minions.minions[next_minion_slot].id
			out.chain_count += 1
			struck_minion_mask |= u64(1) << u64(next_minion_slot)
		}
		from = next_center
	}
}

// Sixty small hits a second: no per-hit console line, the kill shows up in
// [Death]. The player's own combat log does see them, as one line whose tally
// climbs for as long as the beam is on them.
@(private = "file")
beam_damage :: proc(world: ^Entity_World, caster_id, target_id: Entity_ID, spell: Spell_ID, damage: f32) {
	combat_apply_damage(world, caster_id, target_id, spell, damage)
}
