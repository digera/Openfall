// Death and respawn
package main

import "core:fmt"

RESPAWN_DELAY_SEC :: f32(4.0)

entity_tick_death_respawn :: proc(entity_world: ^Entity_World, chunks: ^Ore_Chunk_World, dt: f32) {
	for i in 1..<MAX_ENTITIES {
		if !entity_world.characters[i].active {
			continue
		}
		char := entity_world.characters[i]
		id := Entity_ID(i)

		if char.health <= 0 && !char.dead {
			char.dead = true
			char.health = 0
			char.vel = {}
			char.respawn_timer = RESPAWN_DELAY_SEC
			// The one death transition in the game, so the one place a kill is
			// credited. A body that drops to zero from a beam, a splash it
			// never saw, or three people at once is counted here exactly once.
			combat_record_death(entity_world, id)
			if SERVER_VERBOSE {
				fmt.printf("[Death] Entity %d died\n", i)
			}
		}

		if char.dead {
			// Retry while the body is down: a full chunk pool must not delete
			// the haul. Respawn still clears whatever could not be placed.
			entity_drop_carried_ore(&char, chunks, id, {})
			char.respawn_timer -= dt
			if char.respawn_timer <= 0 {
				entity_drop_carried_ore(&char, chunks, id, {})
				entity_respawn(&char, entity_world.teams[i], i)
				entity_clear_attacker(entity_world, id)
			}
		}

		entity_world.characters[i] = char
	}
}

// Spawn one loose chunk per kind still held. `heading` with length is a live
// toss along look; a zero heading scatters at the feet (death). Leaves the
// amount on the body if the floor is full, so a later tick (or the last tick
// before respawn) can try again instead of silently burning the ore.
entity_drop_carried_ore :: proc(char: ^Character_State, chunks: ^Ore_Chunk_World, id: Entity_ID, heading: vec3) {
	if chunks == nil {
		return
	}
	toss := len2_vec3(heading) > 1e-6
	right: vec3
	kind_n := 0
	if toss {
		right = camera_right(char.yaw)
		for k in 0 ..< ORE_COUNT {
			if char.carrying_ore[k] > 0 {
				kind_n += 1
			}
		}
	}
	kind_i := 0
	for k in 0 ..< ORE_COUNT {
		amt := char.carrying_ore[k]
		if amt <= 0 {
			continue
		}
		kind := ore_from_index(k)
		at := char.pos + vec3{0, 0, 0.35}
		ok: ^Ore_Chunk
		if toss {
			spread := kind_n > 1 ? f32(kind_i) - f32(kind_n - 1) * 0.5 : f32(0)
			at += heading * 0.55 + right * spread * 0.25
			vel := heading * 3.6 + right * spread * 0.85 + vec3{0, 0, 2.1}
			ok = ore_chunk_spawn_tossed(chunks, kind, at, amt, vel)
			kind_i += 1
		} else {
			ok = ore_chunk_spawn_loose(chunks, kind, at, amt)
		}
		if ok == nil {
			continue
		}
		if SERVER_VERBOSE {
			fmt.printf("[Ore] Entity %d dropped %.0f %s\n", id, amt, ore_name(kind))
		}
		char.carrying_ore[k] = 0
	}
}

// Reset a character at its team's spawn with full resources.
entity_respawn :: proc(char: ^Character_State, team: Team_ID, slot: int) {
	char.pos = team_spawn_position(team, slot)
	char.vel = {}
	char.on_ground = true
	char.health = HEALTH_MAX
	char.mana = MANA_MAX
	char.stamina = STAMINA_MAX
	char.sprint_active = false
	char.slow_ticks = 0
	char.dead = false
	char.respawn_timer = 0
	char.carrying_ore = {}
	// Face the center (look is client-authoritative, so this only sticks for bots)
	if team != .None {
		char.yaw = wrap_angle(team_angle(team) + 3.14159265)
	}
}

// A fresh body owes nobody a kill.
entity_clear_attacker :: proc(entity_world: ^Entity_World, id: Entity_ID) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return
	}
	entity_world.last_attacker[id] = INVALID_ENTITY
	entity_world.last_attack_spell[id] = .None
}

// Respawn every active entity (round reset).
entity_respawn_all :: proc(entity_world: ^Entity_World) {
	for i in 1..<MAX_ENTITIES {
		if !entity_world.characters[i].active {
			continue
		}
		char := entity_world.characters[i]
		entity_respawn(&char, entity_world.teams[i], i)
		entity_clear_attacker(entity_world, Entity_ID(i))
		entity_world.characters[i] = char
		entity_world.spell_states[i] = {}
		// Keep the yaw in the input so the next tick doesn't snap it back.
		entity_world.inputs[i].yaw = char.yaw
	}
}
