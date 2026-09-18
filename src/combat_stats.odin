package main

// Combat stats tracking (server-authoritative)

// Apply damage and track it. Returns true if the target died from this damage.
combat_apply_damage :: proc(world: ^Entity_World, attacker_id, target_id: Entity_ID, damage: f32) -> (killed: bool) {
	if target_id == INVALID_ENTITY || target_id >= MAX_ENTITIES {
		return false
	}
	if !world.characters[target_id].active {
		return false
	}

	target := &world.characters[target_id]
	was_alive := !target.dead && target.health > 0

	target.health -= damage
	target.damage_taken += damage

	// Track damage dealt on the attacker
	if attacker_id != INVALID_ENTITY && attacker_id < MAX_ENTITIES && world.characters[attacker_id].active {
		world.characters[attacker_id].damage_dealt += damage
	}

	// Check for kill
	if was_alive && target.health <= 0 {
		target.dead = true
		target.health = 0
		target.deaths += 1
		if attacker_id != INVALID_ENTITY && attacker_id < MAX_ENTITIES && world.characters[attacker_id].active && attacker_id != target_id {
			world.characters[attacker_id].kills += 1
		}
		return true
	}
	return false
}

// Reset all combat stats (called on match restart)
combat_reset_stats :: proc(world: ^Entity_World) {
	for i in 1..<MAX_ENTITIES {
		if world.characters[i].active {
			world.characters[i].kills = 0
			world.characters[i].deaths = 0
			world.characters[i].damage_dealt = 0
			world.characters[i].damage_taken = 0
		}
	}
}
