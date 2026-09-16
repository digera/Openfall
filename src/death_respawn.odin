// Death and respawn
package main

import "core:fmt"

RESPAWN_DELAY_SEC :: f32(4.0)

entity_tick_death_respawn :: proc(entity_world: ^Entity_World, dt: f32) {
	for i in 1..<MAX_ENTITIES {
		if !entity_world.characters[i].active {
			continue
		}
		char := entity_world.characters[i]

		if char.health <= 0 && !char.dead {
			char.dead = true
			char.health = 0
			char.vel = {}
			char.respawn_timer = RESPAWN_DELAY_SEC
			if SERVER_VERBOSE {
				fmt.printf("[Death] Entity %d died\n", i)
			}
		}

		if char.dead {
			char.respawn_timer -= dt
			if char.respawn_timer <= 0 {
				entity_respawn(&char, entity_world.teams[i], i)
			}
		}

		entity_world.characters[i] = char
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
	char.slow_ticks = 0
	char.dead = false
	char.respawn_timer = 0
	// Face the center (look is client-authoritative, so this only sticks for bots)
	if team != .None {
		char.yaw = wrap_angle(team_angle(team) + 3.14159265)
	}
}

// Respawn every active entity (round reset).
entity_respawn_all :: proc(entity_world: ^Entity_World) {
	for i in 1..<MAX_ENTITIES {
		if !entity_world.characters[i].active {
			continue
		}
		char := entity_world.characters[i]
		entity_respawn(&char, entity_world.teams[i], i)
		entity_world.characters[i] = char
		entity_world.spell_states[i] = {}
		// Keep the yaw in the input so the next tick doesn't snap it back.
		entity_world.inputs[i].yaw = char.yaw
	}
}
