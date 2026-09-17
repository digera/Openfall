package main

// Server-authoritative beams: spells that hurt whatever the crosshair is on
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

		origin := vec3{char.pos.x, char.pos.y, char.pos.z + PLAYER_EYE_M}
		dir := camera_forward(char.yaw, char.pitch)
		
		// Route to the appropriate trace: heal beams find friendlies, damage beams find enemies.
		if state.channel_spell == .Self_Heal {
			heal_beam_trace(world, id, def, origin, dir, def.beam_dps * dt, &state.beam)
			// Quench heal beam if it found no valid target (all friendlies out of range or self at full HP).
			if state.beam.hit == INVALID_ENTITY {
				beam_quench(world, id)
			}
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

// Trace one heal beam: finds the nearest living friendly (same team, not self)
// within a wide cone and heals them. If no friendlies are found, heals self as
// fallback. `healing` is the amount to restore this tick. Writes where the beam
// ended and who was healed into `out` for the snapshot.
heal_beam_trace :: proc(world: ^Entity_World, caster_id: Entity_ID, def: ^Spell_Def, origin, dir: vec3, healing: f32, out: ^Beam_State) {
	caster_team := world.teams[caster_id]
	reach := world_ray_hit(origin, dir, def.range)

	// Wide cone for friendly targeting: more forgiving than damage beams.
	// cos(30 deg) = ~0.866 gives a 60-degree total cone width (inside means dot >= COS * dist).
	HEAL_BEAM_AIM_COS :: f32(0.866)

	hit := INVALID_ENTITY
	hit_dist := reach
	for i in 1..<MAX_ENTITIES {
		id := Entity_ID(i)
		if id == caster_id || !entity_alive(world, id) {
			continue
		}
		// Heal same-team friendlies only (not None, not enemies).
		if caster_team == .None || world.teams[i] != caster_team {
			continue
		}

		target_pos := world.characters[i].pos
		center := target_pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
		to := center - origin
		dist := len_vec3(to)
		if dist < 1e-3 || dist > def.range {
			continue
		}
		// Wide cone check: accept targets inside cone (dot >= COS * dist).
		if dot_vec3(to, dir) < HEAL_BEAM_AIM_COS * dist {
			continue
		}
		// LOS check: prefer targets in the open.
		if !world_segment_clear(origin, center) {
			continue
		}
		// Capping at the best distance so far keeps only the nearest friendly.
		dist_cyl, ok := ray_cylinder_hit(origin, dir, target_pos, CHARACTER_RADIUS_M, CHARACTER_HEIGHT_M, hit_dist)
		if ok {
			hit = id
			hit_dist = dist_cyl
		}
	}

	// Fallback: if no friendlies found, heal self (unless already at full HP, to avoid mana waste).
	if hit == INVALID_ENTITY {
		caster := world.characters[caster_id]
		if caster.health < HEALTH_MAX {
			hit = caster_id
			hit_dist = 0 // beam ends at caster for visual feedback
		}
	}

	out^ = {end = origin + dir * hit_dist, hit = hit}
	if hit != INVALID_ENTITY {
		beam_heal(world, hit, healing)
	}
}

// Sixty small hits a second: no per-hit log line, the kill shows up in [Death].
@(private = "file")
beam_damage :: proc(world: ^Entity_World, target_id: Entity_ID, damage: f32) {
	target := world.characters[target_id]
	target.health -= damage
	world.characters[target_id] = target
}

// Restore health to a target, capped at HEALTH_MAX. No log spam; sixty small
// heals a second, the health bar is the feedback.
@(private = "file")
beam_heal :: proc(world: ^Entity_World, target_id: Entity_ID, healing: f32) {
	target := world.characters[target_id]
	target.health = min(target.health + healing, HEALTH_MAX)
	world.characters[target_id] = target
}
