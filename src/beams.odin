package main

// Server-authoritative beams: spells that work on whoever is in front of them
// for every tick they are held -- burning what the crosshair is on, or mending
// an ally in a wider cone. There is no beam object; the beam is a state of its
// caster. The wind-up bookkeeping in server_advance_channel decides whether a
// beam is lit, this decides what it does while it is.

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

		// A heal beam picks who it mends before it is paid for. With nobody
		// hurt in front of it there is nothing to buy, so it idles: lit, free,
		// and pointing where the caster is looking until someone needs it.
		mend := INVALID_ENTITY
		if def.beam_heals {
			mend = heal_beam_target(world, id, def, origin, dir, world.inputs[i].target_id)
			if mend == INVALID_ENTITY {
				state.beam = {end = origin + dir * world_ray_hit(origin, dir, def.range), hit = INVALID_ENTITY}
				continue
			}
		}

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

		if def.beam_heals {
			beam_mend(world, mend, def.beam_dps * dt)
			// The beam bends to whoever it mends rather than running along the
			// crosshair, so a player can see which ally it picked.
			state.beam = {end = strike_center(world.characters[mend].pos), hit = mend}
		} else {
			beam_trace(world, id, def, origin, dir, def.beam_dps * dt, &state.beam)
		}
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
	state.beam = {}
}

// Trace one beam: the world clips it, the first hostile body along it takes
// `damage`, and the arcs jump from body to body behind it. Writes where it
// ended and who it touched into `out` for the snapshot.
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

	out^ = {end = origin + dir * hit_dist, hit = hit}
	if hit == INVALID_ENTITY {
		return
	}
	beam_damage(world, hit, damage)

	// Arcs: from the last body struck to the nearest hostile one not yet
	// struck, within jump range and in the open. Each jump is worth a
	// fraction of the beam so a crowd is hurt, not deleted.
	struck: u64 = u64(1) << u64(hit)
	from := world.characters[hit].pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
	for out.chain_count < def.beam_chain_count {
		next := INVALID_ENTITY
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
			next_d2 = d2
			next_center = center
		}
		if next == INVALID_ENTITY {
			break
		}
		beam_damage(world, next, damage * def.beam_chain_frac)
		out.chains[out.chain_count] = next
		out.chain_count += 1
		struck |= u64(1) << u64(next)
		from = next_center
	}
}

// Who a heal beam mends this tick, in order of preference: the ally the
// crosshair has picked out, the nearest wounded ally in the beam's cone, or the
// caster themselves. INVALID_ENTITY means there is nobody to mend -- everyone
// in front of the beam is already whole -- and the caller idles the beam rather
// than spending mana on nothing. `sticky` is the caster's soft target, trusted
// no further than any other client claim: it is re-checked here like a strike's.
heal_beam_target :: proc(world: ^Entity_World, caster_id: Entity_ID, def: ^Spell_Def, origin, dir: vec3, sticky: Entity_ID) -> Entity_ID {
	// The crosshair's own pick wins, so with two wounded allies in the cone the
	// player chooses which one the beam follows.
	if heal_beam_can_mend(world, caster_id, sticky) &&
	   heal_beam_in_reach(def, origin, dir, world.characters[sticky].pos) {
		return sticky
	}

	best := INVALID_ENTITY
	best_d2 := f32(0)
	for i in 1..<MAX_ENTITIES {
		id := Entity_ID(i)
		if !heal_beam_can_mend(world, caster_id, id) {
			continue
		}
		pos := world.characters[i].pos
		if !heal_beam_in_reach(def, origin, dir, pos) {
			continue
		}
		d2 := len2_vec3(strike_center(pos) - origin)
		if best == INVALID_ENTITY || d2 < best_d2 {
			best = id
			best_d2 = d2
		}
	}
	if best != INVALID_ENTITY {
		return best
	}

	// Nobody in front of it: the beam curls back on the caster, which is all a
	// player alone in a lane gets out of it.
	if world.characters[caster_id].health < HEALTH_MAX {
		return caster_id
	}
	return INVALID_ENTITY
}

// Is `target_id` someone this caster's heal beam has any business mending: a
// living teammate other than themselves, with health missing to put back.
@(private = "file")
heal_beam_can_mend :: proc(world: ^Entity_World, caster_id, target_id: Entity_ID) -> bool {
	if !entity_alive(world, target_id) {
		return false
	}
	if !spell_target_valid_for_filter(.Friendly, caster_id, target_id, world.teams[caster_id], world.teams[target_id]) {
		return false
	}
	return world.characters[target_id].health < HEALTH_MAX
}

// Sixty small hits a second: no per-hit log line, the kill shows up in [Death].
@(private = "file")
beam_damage :: proc(world: ^Entity_World, target_id: Entity_ID, damage: f32) {
	target := world.characters[target_id]
	target.health -= damage
	world.characters[target_id] = target
}

// The same in reverse, and just as quiet: the health bar is the feedback.
@(private = "file")
beam_mend :: proc(world: ^Entity_World, target_id: Entity_ID, healing: f32) {
	target := world.characters[target_id]
	target.health = min(target.health + healing, HEALTH_MAX)
	world.characters[target_id] = target
}
