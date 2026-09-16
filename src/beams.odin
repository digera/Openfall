package main

// Server-authoritative beam channels. Continuous hitscan weapons like
// Thunderbolt that apply damage every tick while held and can chain to
// multiple targets.

MAX_BEAMS :: 32

Beam_ID :: u32

// Active beam channel state
Beam :: struct {
	active:         bool,
	id:             Beam_ID,
	spell_id:       Spell_ID,
	owner_id:       Entity_ID,
	owner_team:     Team_ID,

	// Current beam target and chain
	primary_hit:    bool,
	primary_pos:    vec3,
	primary_target: Entity_ID,
	
	chain_count:    int,
	chain_targets:  [8]Entity_ID,  // chain sequence
	chain_positions: [8]vec3,      // hit positions for VFX
}

Beam_World :: struct {
	beams:    #soa[MAX_BEAMS]Beam,
	count:    int,
	next_id:  Beam_ID,
}

beam_world_init :: proc() -> Beam_World {
	return Beam_World{next_id = 1}
}

beam_spawn :: proc(world: ^Beam_World, owner_id: Entity_ID, spell_id: Spell_ID, owner_team: Team_ID) -> Beam_ID {
	if world.count >= MAX_BEAMS {
		return 0
	}
	for i in 0..<MAX_BEAMS {
		if !world.beams[i].active {
			id := world.next_id
			world.next_id += 1
			world.count += 1

			world.beams[i] = Beam{
				active     = true,
				id         = id,
				spell_id   = spell_id,
				owner_id   = owner_id,
				owner_team = owner_team,
			}
			return id
		}
	}
	return 0
}

beam_destroy :: proc(world: ^Beam_World, slot: int) {
	if slot < 0 || slot >= MAX_BEAMS {
		return
	}
	if world.beams[slot].active {
		world.beams[slot].active = false
		world.count -= 1
	}
}

beam_find_by_owner :: proc(world: ^Beam_World, owner_id: Entity_ID) -> (slot: int, found: bool) {
	for i in 0..<MAX_BEAMS {
		if world.beams[i].active && world.beams[i].owner_id == owner_id {
			return i, true
		}
	}
	return 0, false
}

// Update beam for one tick: trace ray, find targets, apply damage
beam_tick :: proc(world: ^Beam_World, entity_world: ^Entity_World, slot: int, dt: f32) {
	beam := &world.beams[slot]
	if !beam.active {
		return
	}

	caster, ok := entity_get_character(entity_world, beam.owner_id)
	if !ok || caster.dead {
		beam_destroy(world, slot)
		return
	}

	def := &SPELL_DEFS[beam.spell_id]
	damage_this_tick := def.beam_dps * dt

	// Trace beam from caster eye
	origin := vec3{caster.pos.x, caster.pos.y, caster.pos.z + PLAYER_EYE_M}
	direction := camera_forward(caster.yaw, caster.pitch)

	// Reset beam state for this tick
	beam.primary_hit = false
	beam.primary_target = INVALID_ENTITY
	beam.chain_count = 0

	// Find primary target (hitscan along direction)
	hit_dist, hit_id := beam_raycast_entities(entity_world, origin, direction, def.range, beam.owner_id, beam.owner_team)
	
	if hit_id != INVALID_ENTITY {
		beam.primary_hit = true
		beam.primary_target = hit_id
		beam.primary_pos = origin + direction * hit_dist

		// Apply primary damage
		if idx, ok := entity_get_character_mut(entity_world, hit_id); ok {
			entity_world.characters[idx].health -= damage_this_tick
			if SERVER_VERBOSE {
				server_log("[Beam] %s from %d hit %d for %.1f (%.0f HP left)",
					def.short_name, beam.owner_id, hit_id, damage_this_tick,
					entity_world.characters[idx].health)
			}
		}

		// Chain lightning
		if def.beam_chain_count > 0 {
			beam_apply_chains(world, entity_world, beam, slot, damage_this_tick, def)
		}
	} else {
		// Beam hit nothing, just extends to max range
		beam.primary_pos = origin + direction * def.range
	}
}

// Raycast against all valid enemy entities, return distance and entity hit
@(private)
beam_raycast_entities :: proc(
	entity_world: ^Entity_World,
	origin: vec3,
	direction: vec3,
	max_range: f32,
	owner_id: Entity_ID,
	owner_team: Team_ID,
) -> (dist: f32, target: Entity_ID) {
	closest_dist := max_range
	closest_id := INVALID_ENTITY

	for entity_idx in 1..<MAX_ENTITIES {
		id := Entity_ID(entity_idx)
		if !entity_alive(entity_world, id) || id == owner_id {
			continue
		}
		if !teams_are_enemies(owner_team, entity_world.teams[entity_idx]) {
			continue
		}

		char_pos := entity_world.characters[entity_idx].pos
		
		// Simple cylinder test for hitscan
		if hit_dist, hits := raycast_cylinder(origin, direction, char_pos, CHARACTER_RADIUS_M, CHARACTER_HEIGHT_M, max_range); hits {
			if hit_dist < closest_dist {
				closest_dist = hit_dist
				closest_id = id
			}
		}
	}

	return closest_dist, closest_id
}

// Simple ray vs cylinder intersection for beam hitscan
@(private)
raycast_cylinder :: proc(
	ray_origin: vec3,
	ray_dir: vec3,
	cylinder_base: vec3,
	radius: f32,
	height: f32,
	max_t: f32,
) -> (t: f32, hit: bool) {
	// Project ray to XY plane and check 2D circle intersection
	dx := ray_origin.x - cylinder_base.x
	dy := ray_origin.y - cylinder_base.y
	
	a := ray_dir.x * ray_dir.x + ray_dir.y * ray_dir.y
	if a < 1e-6 {
		// Ray is vertical, simple cylinder check
		if dx * dx + dy * dy <= radius * radius {
			dz := ray_origin.z - cylinder_base.z
			if dz < 0 && dz + ray_dir.z * max_t >= 0 {
				return -dz / ray_dir.z, true
			}
		}
		return 0, false
	}

	b := 2 * (dx * ray_dir.x + dy * ray_dir.y)
	c := dx * dx + dy * dy - radius * radius

	disc := b * b - 4 * a * c
	if disc < 0 {
		return 0, false
	}

	t0 := (-b - sqrt(disc)) / (2 * a)
	t1 := (-b + sqrt(disc)) / (2 * a)

	// Check both intersections for height bounds
	for _, test_t in []f32{t0, t1} {
		if test_t >= 0 && test_t <= max_t {
			z := ray_origin.z + ray_dir.z * test_t - cylinder_base.z
			if z >= 0 && z <= height {
				return test_t, true
			}
		}
	}

	return 0, false
}

// Find and damage chain targets
@(private)
beam_apply_chains :: proc(
	world: ^Beam_World,
	entity_world: ^Entity_World,
	beam: ^Beam,
	slot: int,
	damage: f32,
	def: ^Spell_Def,
) {
	MAX_CHAIN := 8
	hit_mask: u64 = 0  // track which entities we've already hit
	hit_mask |= u64(1) << u64(beam.primary_target)

	current_pos := beam.primary_pos
	chain_idx := 0

	for chain_idx < def.beam_chain_count && chain_idx < MAX_CHAIN - 1 {
		// Find nearest valid enemy within chain range
		next_id := INVALID_ENTITY
		next_dist := def.beam_chain_range
		next_pos := current_pos

		for entity_idx in 1..<MAX_ENTITIES {
			id := Entity_ID(entity_idx)
			if !entity_alive(entity_world, id) {
				continue
			}
			if !teams_are_enemies(beam.owner_team, entity_world.teams[entity_idx]) {
				continue
			}
			if hit_mask & (u64(1) << u64(entity_idx)) != 0 {
				continue  // already hit this tick
			}

			char := entity_world.characters[entity_idx]
			center := char.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
			d := len_vec3(center - current_pos)

			if d < next_dist {
				// Optional: LOS check (skip for now for performance)
				next_dist = d
				next_id = id
				next_pos = center
			}
		}

		if next_id == INVALID_ENTITY {
			break  // no more valid targets in range
		}

		// Apply chain damage
		if idx, ok := entity_get_character_mut(entity_world, next_id); ok {
			entity_world.characters[idx].health -= damage
			if SERVER_VERBOSE {
				server_log("[Beam] Chain %d to %d for %.1f (%.0f HP left)",
					chain_idx + 1, next_id, damage,
					entity_world.characters[idx].health)
			}
		}

		// Record chain for VFX
		beam.chain_targets[chain_idx] = next_id
		beam.chain_positions[chain_idx] = next_pos
		beam.chain_count += 1

		hit_mask |= u64(1) << u64(next_id)
		current_pos = next_pos
		chain_idx += 1
	}
}

beam_clear_all :: proc(world: ^Beam_World) {
	for i in 0..<MAX_BEAMS {
		world.beams[i].active = false
	}
	world.count = 0
}
