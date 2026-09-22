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

	// Ore carry: per-kind amounts, sum capped at CARRY_CAPACITY_MAX
	carrying_ore: [ORE_COUNT]f32,
}

// Input for one entity for one tick. Look angles are absolute so a dropped
// packet can never desync the server's aim from the client's view.
Input_State :: struct {
	move_fwd:     f32,  // [-1, 1]
	move_str:     f32,  // [-1, 1]
	jump:         bool,
	sprint:       bool,
	aim_lock:     bool,
	drop:         bool,  // edge: toss carried ore onto the floor this tick
	yaw:          f32,  // absolute, wrapped to [-pi, pi]
	pitch:        f32,  // absolute, clamped
	// Charge-cast intent: `charge_spell` is the spell being wound up this tick
	// (still held, or already released and finishing), `cast_spell` is set only
	// on the tick it actually fires.
	charge_spell: Spell_ID,
	cast_spell:   Spell_ID,
	// The crosshair's target. Heal keeps this sticky and the server re-checks
	// the cone; nothing about the id is trusted. Call Lightning does not read
	// it — that bolt is a hitscan of the look at the moment of release.
	target_id:    Entity_ID,
}

// A player label as it lives in memory and on the wire. Deliberately not a
// `string`: a name arrives inside a packet buffer that is reused on the next
// receive, so anything holding a slice of it would be reading someone else's
// mail a millisecond later.
MAX_PLAYER_NAME_LEN :: 16

Player_Name :: struct {
	len:  u8,
	text: [MAX_PLAYER_NAME_LEN]u8,
}

// Match scoreline for one entity. Server-authoritative, replicated in the
// roster packet rather than the snapshot: it changes a few times a minute, and
// the scoreboard needs every player, not the nearest handful.
Combat_Stats :: struct {
	kills:        u16,
	deaths:       u16,
	damage_dealt: f32,
	damage_taken: f32,
}

Entity_World :: struct {
	characters:   #soa[MAX_ENTITIES]Character_State,
	inputs:       [MAX_ENTITIES]Input_State,
	spell_states: [MAX_ENTITIES]Entity_Spell_State,
	teams:        [MAX_ENTITIES]Team_ID,
	names:        [MAX_ENTITIES]Player_Name,
	stats:        [MAX_ENTITIES]Combat_Stats,

	// Who last drew blood, for kill credit. Damage records it; the death
	// transition reads it and then it is cleared on respawn.
	last_attacker:     [MAX_ENTITIES]Entity_ID,
	last_attack_spell: [MAX_ENTITIES]Spell_ID,

	// Recent damage and kills, per entity, waiting to be carried to that
	// entity's own client. Lives here rather than being threaded through every
	// damage call because it is indexed by entity and dies with the world.
	combat_log:   Combat_Log,

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
			// Slots are reused, so clear anything the previous occupant left
			// behind before the caller names them.
			world.names[i] = {}
			world.stats[i] = {}
			world.last_attacker[i] = INVALID_ENTITY
			world.last_attack_spell[i] = .None
			combat_log_clear_entity(&world.combat_log, id)
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
	// Forget them as anyone's killer. Ids are recycled, so a body that dies
	// after its attacker has left would otherwise hand the kill to whoever
	// took the slot next.
	for i in 1..<MAX_ENTITIES {
		if world.last_attacker[i] == id {
			world.last_attacker[i] = INVALID_ENTITY
			world.last_attack_spell[i] = .None
		}
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

// Copy `src` into fixed storage, keeping only printable ASCII. Everything a
// client sends about itself is hostile until proven otherwise, and a name goes
// straight onto everyone else's HUD.
player_name_set :: proc(dst: ^Player_Name, src: string) {
	dst^ = {}
	for i in 0..<len(src) {
		if dst.len >= MAX_PLAYER_NAME_LEN {
			break
		}
		c := src[i]
		if c >= 32 && c < 127 {
			dst.text[dst.len] = c
			dst.len += 1
		}
	}
}

// Label shown on the target HUD and the scoreboard. Falls back to the id when
// a name has not arrived yet, so a player who walks in mid-roster still has
// something to be called.
//
// The returned string views `name`, so it is only good for as long as the
// storage behind it: pass a pointer into the entity world or the client
// roster, never into a packet that is about to be overwritten.
player_name_display :: proc(name: ^Player_Name, id: Entity_ID, is_bot: bool) -> string {
	if name != nil && name.len > 0 {
		return string(name.text[:name.len])
	}
	return fmt.tprintf(is_bot ? "Wisp-%02d" : "Player-%02d", id)
}

// Is this entity a living, targetable combatant?
entity_alive :: proc(world: ^Entity_World, id: Entity_ID) -> bool {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return false
	}
	return world.characters[id].active && !world.characters[id].dead
}
