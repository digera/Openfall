package main

import "core:math"

// Server-authoritative projectiles. Everything here arcs under gravity; how a
// projectile ends is per-spell: ricochet a few times and pop, detonate on the
// first contact, or spear through a line of enemies.

MAX_PROJECTILES :: 256

// Projectiles fall on a lighter gravity than characters so the arc reads
// clearly without turning every spell into a mortar.
PROJECTILE_GRAVITY_Z :: f32(-9.8)

// Speed into a surface below which a contact scuffs along it instead of
// spending a ricochet, so a shot that grazes the floor keeps its ricochets.
PROJECTILE_BOUNCE_MIN_SPEED :: f32(1.2)

// A projectile this slow has come to rest against something: pop it instead of
// leaving it lying around for the rest of its fuse.
PROJECTILE_REST_SPEED :: f32(1.5)

// Arcane Missile: on a real ricochet (wall or floor, not a graze), lean the
// outgoing shot toward the nearest living enemy the bounce can see. Radius is
// lane-scale so a bank in a fight finds that fight, not the next one. Blend
// keeps the geometric bounce; 1 would replace it with a homing shot.
ARCANE_MISSILE_SEEK_RADIUS :: f32(12.0)
ARCANE_MISSILE_SEEK_BLEND  :: f32(0.6)

Projectile_ID :: u32

// Piercing uses one bit per entity to remember who has already been speared.
#assert(MAX_ENTITIES <= 64)

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
	gravity:       f32,

	bounces_left:  int,
	restitution:   f32,

	pierce_left:   int,
	pierced_mask:  u64,
	// Minions live in their own table, so a spear that has already gone through
	// one needs its own set of "do not hit twice" bits.
	pierced_minions: u64,

	damage:        f32,
	aoe_radius:    f32,
	aoe_frac:      f32,
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
				active       = true,
				id           = id,
				spell_id     = spell_cast.spell_id,
				owner_id     = spell_cast.caster_id,
				owner_team   = entity_get_team(entity_world, spell_cast.caster_id),
				pos          = origin,
				vel          = spell_cast.direction * def.proj_speed,
				lifetime     = def.proj_lifetime,
				radius       = def.proj_radius,
				gravity      = def.proj_gravity,
				bounces_left = def.proj_bounces,
				restitution  = def.proj_restitution,
				pierce_left  = def.proj_pierce,
				damage       = def.damage * spell_cast.charge_frac,
				aoe_radius   = def.aoe_radius,
				aoe_frac     = def.aoe_damage_frac,
				knockback    = def.knockback,
				slow_ticks   = def.slow_ticks,
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

// Nearest living enemy on the outgoing side of `n`, within
// ARCANE_MISSILE_SEEK_RADIUS of `from`, with a clear segment to their center.
//
// Scans the 64-slot SOA the same way projectile hits already do every sub-step.
// `spatial_grid.odin` is an unused full-scan stub that heap-allocates; a grid
// would cost more than this loop at MAX_ENTITIES. Seek only runs on a ricochet
// (at most three times per missile), not per tick.
@(private)
projectile_missile_seek :: proc(
	entity_world: ^Entity_World,
	from: vec3,
	n: vec3,
	owner_id: Entity_ID,
	owner_team: Team_ID,
) -> (dir: vec3, ok: bool) {
	nearest := INVALID_ENTITY
	nearest_dist_sq := ARCANE_MISSILE_SEEK_RADIUS * ARCANE_MISSILE_SEEK_RADIUS

	for entity_idx in 1..<MAX_ENTITIES {
		id := Entity_ID(entity_idx)
		if !entity_alive(entity_world, id) || id == owner_id {
			continue
		}
		if !teams_are_enemies(owner_team, entity_world.teams[entity_idx]) {
			continue
		}

		target_pos := entity_world.characters[entity_idx].pos
		center := target_pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
		d := center - from
		if dot_vec3(d, n) <= 0 {
			continue
		}
		dist_sq := d.x * d.x + d.y * d.y + d.z * d.z
		if dist_sq >= nearest_dist_sq {
			continue
		}
		if !world_segment_clear(from, center, 0.8) {
			continue
		}
		nearest = id
		nearest_dist_sq = dist_sq
	}

	if nearest == INVALID_ENTITY {
		return {}, false
	}
	center := entity_world.characters[nearest].pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
	d := center - from
	l := len_vec3(d)
	if l < 0.01 {
		return {}, false
	}
	return d / l, true
}

projectile_tick :: proc(world: ^Projectile_World, entity_world: ^Entity_World, dt: f32) {
	for i in 0..<MAX_PROJECTILES {
		if !world.projectiles[i].active {
			continue
		}
		proj := &world.projectiles[i]

		proj.lifetime -= dt
		if proj.lifetime <= 0 {
			projectile_expire(world, entity_world, i)
			continue
		}

		proj.vel.z += PROJECTILE_GRAVITY_Z * proj.gravity * dt

		// Sub-step fast projectiles so they can't tunnel through a player.
		steps := max(1, int(math.ceil(len_vec3(proj.vel) * dt / 0.4)))
		sub_dt := dt / f32(steps)

		for s in 0..<steps {
			new_pos := proj.pos + proj.vel * sub_dt

			if !projectile_step_entities(world, entity_world, i, new_pos) {
				break
			}

			// Walls, ceiling and cover. Bisect the last free centre so the
			// bounce, splash and mining stamp sit on the face that was hit,
			// not a sub-step back along the flight. The floor path below
			// already names that resting centre directly.
			if !world_point_free(new_pos, proj.radius) {
				contact, blocked := world_last_free(proj.pos, new_pos, proj.radius)
				n := world_surface_normal(contact, blocked, proj.radius)
				if !projectile_surface_contact(world, entity_world, i, contact, n) {
					break
				}
				continue
			}

			// The floor is its own case: the walkable volume only reports a
			// point as blocked once its centre has sunk below the floor plane,
			// which would let projectiles bury themselves before reacting.
			if new_pos.z - proj.radius <= WORLD_FLOOR_Z {
				contact := vec3{new_pos.x, new_pos.y, WORLD_FLOOR_Z + proj.radius}
				if !projectile_surface_contact(world, entity_world, i, contact, {0, 0, 1}) {
					break
				}
				continue
			}

			proj.pos = new_pos
		}
	}
}

// Sweep one sub-step against enemies. Returns false when the projectile is
// gone (detonated on a target).
@(private)
projectile_step_entities :: proc(world: ^Projectile_World, entity_world: ^Entity_World, slot: int, at: vec3) -> bool {
	proj := &world.projectiles[slot]

	for entity_idx in 1..<MAX_ENTITIES {
		id := Entity_ID(entity_idx)
		if !entity_alive(entity_world, id) || id == proj.owner_id {
			continue
		}
		if !teams_are_enemies(proj.owner_team, entity_world.teams[entity_idx]) {
			continue
		}
		if proj.pierced_mask & (u64(1) << u64(entity_idx)) != 0 {
			continue
		}
		if !projectile_hits_character(at, proj.radius, entity_world.characters[entity_idx].pos) {
			continue
		}

		if proj.pierce_left > 0 {
			// Spear straight through: full damage, no detonation.
			proj.pierce_left -= 1
			proj.pierced_mask |= u64(1) << u64(entity_idx)
			projectile_apply_direct(world, entity_world, slot, id)
			continue
		}

		projectile_impact(world, entity_world, slot, at, id)
		return false
	}

	// Lane bodies, after the players. A minion is a worse thing to detonate on
	// than a person, so it only catches the shot nobody else did, and a spear
	// with pierce left goes through it the same way.
	if mslot, mhit := minion_sphere_hit(g_minions, proj.owner_team, at, proj.radius, proj.pierced_minions); mhit {
		if proj.pierce_left > 0 {
			proj.pierce_left -= 1
			proj.pierced_minions |= u64(1) << u64(mslot)
			minion_damage(g_minions, mslot, proj.damage)
			return true
		}
		minion_damage(g_minions, mslot, proj.damage)
		projectile_impact(world, entity_world, slot, at, INVALID_ENTITY)
		return false
	}
	return true
}

// Resolve a contact with the world. Returns false when the projectile is gone.
@(private)
projectile_surface_contact :: proc(
	world: ^Projectile_World,
	entity_world: ^Entity_World,
	slot: int,
	contact: vec3,
	n: vec3,
) -> bool {
	proj := &world.projectiles[slot]
	vn := dot_vec3(proj.vel, n)

	if proj.bounces_left <= 0 {
		projectile_impact(world, entity_world, slot, contact, INVALID_ENTITY)
		return false
	}

	if vn > -PROJECTILE_BOUNCE_MIN_SPEED {
		// Grazing or settling: slide along the surface, keep the ricochet.
		proj.pos = contact + n * 0.002
		proj.vel -= n * vn
		if len2_vec3(proj.vel) < PROJECTILE_REST_SPEED * PROJECTILE_REST_SPEED {
			projectile_impact(world, entity_world, slot, contact, INVALID_ENTITY)
			return false
		}
	} else {
		proj.bounces_left -= 1
		proj.pos = contact + n * (proj.radius * 0.25 + 0.01)
		bounce_vel := (proj.vel - n * (2 * vn)) * proj.restitution
		if proj.spell_id == .Arcane_Missile {
			bounce_speed := len_vec3(bounce_vel)
			if bounce_speed > 0.01 {
				if seek, found := projectile_missile_seek(
					entity_world,
					proj.pos,
					n,
					proj.owner_id,
					proj.owner_team,
				); found {
					bounce_dir := bounce_vel / bounce_speed
					blended := bounce_dir * (1 - ARCANE_MISSILE_SEEK_BLEND) + seek * ARCANE_MISSILE_SEEK_BLEND
					blended_len := len_vec3(blended)
					if blended_len > 0.01 && dot_vec3(blended, n) > 0.05 * blended_len {
						bounce_vel = (blended / blended_len) * bounce_speed
					}
				}
			}
		}
		proj.vel = bounce_vel
	}

	// Wedged into a corner: pop rather than sit inside geometry.
	if !world_point_free(proj.pos, proj.radius) {
		projectile_impact(world, entity_world, slot, contact, INVALID_ENTITY)
		return false
	}
	return true
}

// Fuse ran out. Anything with a splash still goes off where it stands.
@(private)
projectile_expire :: proc(world: ^Projectile_World, entity_world: ^Entity_World, slot: int) {
	proj := &world.projectiles[slot]
	if proj.aoe_radius > 0 && proj.aoe_frac > 0 {
		projectile_impact(world, entity_world, slot, proj.pos, INVALID_ENTITY)
		return
	}
	projectile_destroy(world, slot)
}

// Damage, slow and knockback on a body the projectile ran into.
@(private)
projectile_apply_direct :: proc(world: ^Projectile_World, entity_world: ^Entity_World, slot: int, target_id: Entity_ID) {
	proj := &world.projectiles[slot]

	combat_apply_damage(entity_world, proj.owner_id, target_id, proj.spell_id, proj.damage)

	// Copy out of the SOA array, mutate, store back. Read after the damage
	// landed so the health printed below is the health that is there.
	target := entity_world.characters[target_id]
	if proj.slow_ticks > 0 {
		target.slow_ticks = max(target.slow_ticks, proj.slow_ticks)
	}
	if proj.knockback > 0 {
		character_apply_impulse(&target, proj.vel, proj.knockback)
	}
	entity_world.characters[target_id] = target
	if SERVER_VERBOSE {
		server_log("[Combat] %s from %d hit %d for %.0f (%.0f HP left)",
			SPELL_DEFS[proj.spell_id].short_name, proj.owner_id, target_id, proj.damage, target.health)
	}
}

// Resolve a projectile impact: direct hit, splash, then destroy.
projectile_impact :: proc(world: ^Projectile_World, entity_world: ^Entity_World, slot: int, at: vec3, direct: Entity_ID) {
	proj := &world.projectiles[slot]

	if direct != INVALID_ENTITY {
		projectile_apply_direct(world, entity_world, slot, direct)
	}
	splash_damage(entity_world, at, proj.owner_id, proj.owner_team, direct, proj.spell_id, proj.damage * proj.aoe_frac, proj.aoe_radius, proj.knockback)
	// Ore takes the blast too, if there is any here. A detonation against a
	// tower carves the rock; one in open air finds nothing and costs a cylinder
	// test per pylon.
	if direct == INVALID_ENTITY {
		mining_blast(at, max(proj.aoe_radius, proj.radius * 3), proj.damage, proj.owner_id, proj.owner_team)
	}
	projectile_destroy(world, slot)
}

// A blast at `at`: everyone hostile within `radius` who is not `direct` (they
// already took the hit itself) loses up to `damage`, falling off to half at
// the edge. Shared by projectile detonations and strikes.
splash_damage :: proc(
	entity_world: ^Entity_World,
	at: vec3,
	owner_id: Entity_ID,
	owner_team: Team_ID,
	direct: Entity_ID,
	spell_id: Spell_ID,
	damage, radius, knockback: f32,
) {
	if radius <= 0 || damage <= 0 {
		return
	}
	// Every blast in the game comes through here, so putting the lane bodies in
	// the same call is what keeps a grenade from being good against players and
	// useless against a wave standing in the same crater.
	minion_splash(g_minions, at, owner_team, damage, radius)
	for entity_idx in 1..<MAX_ENTITIES {
		id := Entity_ID(entity_idx)
		if !entity_alive(entity_world, id) || id == owner_id || id == direct {
			continue
		}
		if !teams_are_enemies(owner_team, entity_world.teams[entity_idx]) {
			continue
		}
		target := entity_world.characters[entity_idx]
		center := target.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
		d := center - at
		dist := len_vec3(d)
		if dist > radius {
			continue
		}
		// Cover stops the blast, otherwise a wide splash reaches through walls.
		if !world_segment_clear(at, center, 0.8) {
			continue
		}
		falloff := 1.0 - 0.5 * (dist / radius)
		combat_apply_damage(entity_world, owner_id, id, spell_id, damage * falloff)
		if knockback > 0 {
			// Re-read: the damage above went through the array, not this copy.
			target = entity_world.characters[entity_idx]
			character_apply_impulse(&target, d, knockback * falloff)
			entity_world.characters[entity_idx] = target
		}
	}
}
