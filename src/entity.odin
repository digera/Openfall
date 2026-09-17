package main

import "core:fmt"

// Entity system using numeric IDs and #soa arrays for data-oriented design.

Entity_ID :: u32
INVALID_ENTITY :: Entity_ID(0)
MAX_ENTITIES :: 64

// Networked character state. Everything here is replicated in snapshots and
// stepped by the shared deterministic kernel in simulation.odin.
Character_State :: struct {
	pos:        vec3, // feet position (meters)
	vel:        vec3, // velocity (m/s); xy is horizontal momentum, z is fall/jump
	yaw:        f32,
	pitch:      f32,
	on_ground:  bool,
	active:     bool,

	health:     f32,
	mana:       f32,
	stamina:    f32,

	slow_ticks: int,  // remaining ticks of Frost slow (0 = not slowed)

	dead:           bool,
	respawn_timer:  f32,
}

// Input for one entity for one tick. Look angles are absolute so a dropped
// packet can never desync the server's aim from the client's view.
Input_State :: struct {
	move_fwd:     f32,  // [-1, 1]
	move_str:     f32,  // [-1, 1]
	jump:         bool,
	sprint:       bool,
	yaw:          f32,  // absolute, wrapped to [-pi, pi]
	pitch:        f32,  // absolute, clamped
	// Charge-cast intent: `charge_spell` is whatever the player is holding this
	// tick, `cast_spell` is set only on the tick they let go.
	charge_spell: Spell_ID,
	cast_spell:   Spell_ID,
}

Entity_World :: struct {
	characters:   #soa[MAX_ENTITIES]Character_State,
	inputs:       [MAX_ENTITIES]Input_State,
	spell_states: [MAX_ENTITIES]Entity_Spell_State,
	teams:        [MAX_ENTITIES]Team_ID,
	next_id:      Entity_ID,
	count:        int,
}

entity_world_init :: proc() -> Entity_World {
	world := Entity_World{}
	world.next_id = 1
	return world
}

entity_spawn :: proc(world: ^Entity_World, pos: vec3, team := Team_ID.None, yaw: f32 = 0) -> Entity_ID {
	if world.count >= MAX_ENTITIES {
		return INVALID_ENTITY
	}
	for i in 1..<MAX_ENTITIES {
		if !world.characters[i].active {
			id := Entity_ID(i)
			world.characters[i] = Character_State{
				pos       = pos,
				yaw       = yaw,
				pitch     = 0,
				on_ground = true,
				active    = true,
				health    = HEALTH_MAX,
				mana      = MANA_MAX,
				stamina   = STAMINA_MAX,
			}
			world.inputs[i] = Input_State{yaw = yaw}
			world.spell_states[i] = {}
			world.teams[i] = team
			world.count += 1
			return id
		}
	}
	return INVALID_ENTITY
}

entity_destroy :: proc(world: ^Entity_World, id: Entity_ID) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return
	}
	if world.characters[id].active {
		world.characters[id].active = false
		world.count -= 1
	}
}

entity_get_character :: proc(world: ^Entity_World, id: Entity_ID) -> (Character_State, bool) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return {}, false
	}
	if !world.characters[id].active {
		return {}, false
	}
	return world.characters[id], true
}

entity_get_character_mut :: proc(world: ^Entity_World, id: Entity_ID) -> (idx: int, ok: bool) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return 0, false
	}
	if !world.characters[int(id)].active {
		return 0, false
	}
	return int(id), true
}

entity_set_input :: proc(world: ^Entity_World, id: Entity_ID, input: Input_State) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return
	}
	world.inputs[id] = input
}

entity_get_team :: proc(world: ^Entity_World, id: Entity_ID) -> Team_ID {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return .None
	}
	return world.teams[id]
}

entity_set_team :: proc(world: ^Entity_World, id: Entity_ID, team: Team_ID) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return
	}
	world.teams[id] = team
}

// Label shown on the target HUD. Derived from the id rather than replicated so
// names cost nothing per snapshot and can never disagree between clients. When
// players eventually pick their own names this becomes a lookup.
entity_display_name :: proc(id: Entity_ID, is_bot: bool) -> string {
	return fmt.tprintf(is_bot ? "Wisp-%02d" : "Player-%02d", id)
}

// Is this entity a living, targetable combatant?
entity_alive :: proc(world: ^Entity_World, id: Entity_ID) -> bool {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return false
	}
	return world.characters[id].active && !world.characters[id].dead
}
