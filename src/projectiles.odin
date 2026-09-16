package main

import "core:math"

// Server-authoritative projectiles.

MAX_PROJECTILES :: 256

Projectile_ID :: u32

Projectile :: struct {
	active:        bool,
	id:            Projectile_ID,
	spell_id:      Spell_ID,
	owner_id:      Entity_ID,
	owner_team:    Team_ID,

	pos:           vec3,
	vel:           vec3,

	lifetime:      f32,
	radius:        f32,

	damage:        f32,
	aoe_radius:    f32,
	knockback:     f32,
	slow_ticks:    int,
}

Projectile_World :: struct {
	projectiles: #soa[MAX_PROJECTILES]Projectile,
	count:       int,
	next_id:     Projectile_ID,
}

projectile_world_init :: proc() -> Projectile_World {
	return Projectile_World{next_id = 1}
}

projectile_spawn :: proc(world: ^Projectile_World, entity_world: ^Entity_World, spell_cast: ^Spell_Cast, def: ^Spell_Def) -> Projectile_ID {
	if world.count >= MAX_PROJECTILES {
		return 0
	}
	for i in 0..<MAX_PROJECTILES {
		if !world.projectiles[i].active {
			id := world.next_id
			world.next_id += 1
			world.count += 1

			// Start slightly ahead of the eye so the caster never clips their own shot.
			origin := spell_cast.origin + spell_cast.direction * (CHARACTER_RADIUS_M + def.proj_radius + 0.15)

			world.projectiles[i] = Projectile{
				active     = true,
				id         = id,
				spell_id   = spell_cast.spell_id,
				owner_id   = spell_cast.caster_id,
				owner_team = entity_get_team(entity_world, spell_cast.caster_id),
				pos        = origin,
				vel        = spell_cast.direction * def.proj_speed,
				lifetime   = def.proj_lifetime,
				radius     = def.proj_radius,
				damage     = def.damage,
				aoe_radius = def.aoe_radius,
				knockback  = def.knockback,
				slow_ticks = def.slow_ticks,
			}
			return id
		}
	}
	return 0
}

projectile_destroy :: proc(world: ^Projectile_World, slot: int) {
	if slot < 0 || slot >= MAX_PROJECTILES {
		return
	}
	if world.projectiles[slot].active {
		world.projectiles[slot].active = false
		world.count -= 1
	}
}

projectile_clear_all :: proc(world: ^Projectile_World) {
	for i in 0..<MAX_PROJECTILES {
		world.projectiles[i].active = false
	}
	world.count = 0
}

// Sphere-vs-cylinder test against a character.
@(private)
projectile_hits_character :: proc(p: vec3, radius: f32, char_pos: vec3) -> bool {
	dx := p.x - char_pos.x
	dy := p.y - char_pos.y
	if dx * dx + dy * dy > (radius + CHARACTER_RADIUS_M) * (radius + CHARACTER_RADIUS_M) {
		return false
	}
	dz := p.z - char_pos.z
	return dz >= -radius && dz <= CHARACTER_HEIGHT_M + radius
}

projectile_tick :: proc(world: ^Projectile_World, entity_world: ^Entity_World, dt: f32) {
	GRAVITY :: vec3{0, 0, -9.8}

	for i in 0..<MAX_PROJECTILES {
		if !world.projectiles[i].active {
			continue
		}
		proj := &world.projectiles[i]

		proj.lifetime -= dt
		if proj.lifetime <= 0 {
			projectile_destroy(world, i)
			continue
		}

		def := &SPELL_DEFS[proj.spell_id]
		if def.proj_gravity {
			proj.vel += GRAVITY * dt
		}

		// Sub-step fast projectiles so they can't tunnel through a player.
		steps := max(1, int(math.ceil(len_vec3(proj.vel) * dt / 0.4)))
		sub_dt := dt / f32(steps)
		destroyed := false

		for s in 0..<steps {
			new_pos := proj.pos + proj.vel * sub_dt

			// Entities
			for entity_idx in 1..<MAX_ENTITIES {
				if !entity_alive(entity_world, Entity_ID(entity_idx)) {
					continue
				}
				if Entity_ID(entity_idx) == proj.owner_id {
					continue
				}
				if !teams_are_enemies(proj.owner_team, entity_world.teams[entity_idx]) {
					continue
				}
				if !projectile_hits_character(new_pos, proj.radius, entity_world.characters[entity_idx].pos) {
					continue
				}

				projectile_impact(world, entity_world, i, new_pos, Entity_ID(entity_idx))
				destroyed = true
				break
			}
			if destroyed {
				break
			}

			// World
			if !world_point_free(new_pos, proj.radius) {
				projectile_impact(world, entity_world, i, proj.pos, INVALID_ENTITY)
				destroyed = true
				break
			}

			proj.pos = new_pos
		}
	}
}

// Resolve a projectile impact: direct hit, splash, then destroy.
projectile_impact :: proc(world: ^Projectile_World, entity_world: ^Entity_World, slot: int, at: vec3, direct: Entity_ID) {
	proj := &world.projectiles[slot]

	if direct != INVALID_ENTITY {
		// Copy out of the SOA array, mutate, store back.
		target := entity_world.characters[direct]
		target.health -= proj.damage
		if proj.slow_ticks > 0 {
			target.slow_ticks = max(target.slow_ticks, proj.slow_ticks)
		}
		if proj.knockback > 0 {
			character_apply_impulse(&target, proj.vel, proj.knockback)
		}
		entity_world.characters[direct] = target
		if SERVER_VERBOSE {
			server_log("[Combat] %s from %d hit %d for %.0f (%.0f HP left)",
				SPELL_DEFS[proj.spell_id].short_name, proj.owner_id, direct, proj.damage, target.health)
		}
	}

	if proj.aoe_radius > 0 {
		for entity_idx in 1..<MAX_ENTITIES {
			id := Entity_ID(entity_idx)
			if !entity_alive(entity_world, id) || id == proj.owner_id || id == direct {
				continue
			}
			if !teams_are_enemies(proj.owner_team, entity_world.teams[entity_idx]) {
				continue
			}
			target := entity_world.characters[entity_idx]
			center := target.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
			d := center - at
			dist := len_vec3(d)
			if dist > proj.aoe_radius {
				continue
			}
			falloff := 1.0 - 0.5 * (dist / proj.aoe_radius)
			target.health -= proj.damage * 0.6 * falloff
			if proj.knockback > 0 {
				character_apply_impulse(&target, d, proj.knockback * falloff)
			}
			entity_world.characters[entity_idx] = target
		}
	}

	projectile_destroy(world, slot)
}
