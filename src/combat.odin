package main

// One place where damage happens.
//
// Every spell used to subtract from `health` itself, which meant the scoreline
// and the combat log would each have had to be wired into projectiles, splash,
// beams and strikes separately. Routing all four through `combat_apply_damage`
// means a new damage source is scored and logged for free, and the two
// features can never disagree about who hit whom.

// ---------------------------------------------------------------------------
// Combat log

MAX_COMBAT_EVENTS_PER_ENTITY :: 8

// How long an event lingers on the server after its last update. Long enough
// that a client losing several snapshots in a row still hears about the hit,
// short enough that the per-entity ring never fills in a real fight.
COMBAT_LOG_LINGER_SEC :: f32(1.5)

// Damage from the same spell and the same person inside this window is one
// line that counts up rather than a new line. Without it a lit beam would
// push sixty "hit you for 3" events a second through an eight-slot ring and
// nothing else would ever be visible.
COMBAT_LOG_COALESCE_SEC :: f32(1.0)

Combat_Event_Type :: enum u8 {
	Damage_Dealt = 0,
	Damage_Taken = 1,
	Kill         = 2,
	Death        = 3,
}

Combat_Event :: struct {
	live:       bool,
	seq:        u8,   // identity: the client updates a line it has already seen
	event_type: Combat_Event_Type,
	other:      Entity_ID,
	spell_id:   Spell_ID,
	damage:     f32,
	age:        f32,  // since the last update, not since creation
}

Combat_Log :: struct {
	events:   [MAX_ENTITIES][MAX_COMBAT_EVENTS_PER_ENTITY]Combat_Event,
	next_seq: u8,
}

combat_log_tick :: proc(log: ^Combat_Log, dt: f32) {
	for i in 1..<MAX_ENTITIES {
		for j in 0..<MAX_COMBAT_EVENTS_PER_ENTITY {
			e := &log.events[i][j]
			if !e.live {
				continue
			}
			e.age += dt
			if e.age >= COMBAT_LOG_LINGER_SEC {
				e.live = false
			}
		}
	}
}

combat_log_clear_entity :: proc(log: ^Combat_Log, id: Entity_ID) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return
	}
	log.events[id] = {}
}

// Add to a matching recent line, or start a new one. Returns nothing: callers
// record for both parties and neither cares which happened.
@(private = "file")
combat_log_push :: proc(
	log: ^Combat_Log,
	owner: Entity_ID,
	event_type: Combat_Event_Type,
	other: Entity_ID,
	spell: Spell_ID,
	damage: f32,
	seq: u8,
) {
	if owner == INVALID_ENTITY || owner >= MAX_ENTITIES {
		return
	}
	slots := &log.events[owner]

	for j in 0..<MAX_COMBAT_EVENTS_PER_ENTITY {
		e := &slots[j]
		if e.live && e.event_type == event_type && e.other == other && e.spell_id == spell &&
		   e.age < COMBAT_LOG_COALESCE_SEC {
			e.damage += damage
			e.age = 0
			return
		}
	}

	// A free slot, else the one that has gone longest without an update.
	slot := 0
	oldest: f32 = -1
	for j in 0..<MAX_COMBAT_EVENTS_PER_ENTITY {
		e := &slots[j]
		if !e.live {
			slot = j
			break
		}
		if e.age > oldest {
			oldest = e.age
			slot = j
		}
	}
	slots[slot] = Combat_Event{
		live       = true,
		seq        = seq,
		event_type = event_type,
		other      = other,
		spell_id   = spell,
		damage     = damage,
	}
}

@(private = "file")
combat_log_next_seq :: proc(log: ^Combat_Log) -> u8 {
	log.next_seq += 1
	if log.next_seq == 0 {
		log.next_seq = 1
	}
	return log.next_seq
}

// The attacker's "you hit them" and the victim's "they hit you" are one event
// with one sequence number, so the two clients agree about what happened even
// though each is only told its own half.
combat_log_record_damage :: proc(log: ^Combat_Log, attacker, victim: Entity_ID, spell: Spell_ID, damage: f32) {
	seq := combat_log_next_seq(log)
	combat_log_push(log, attacker, .Damage_Dealt, victim, spell, damage, seq)
	combat_log_push(log, victim, .Damage_Taken, attacker, spell, damage, seq)
}

combat_log_record_kill :: proc(log: ^Combat_Log, attacker, victim: Entity_ID, spell: Spell_ID) {
	seq := combat_log_next_seq(log)
	combat_log_push(log, attacker, .Kill, victim, spell, 0, seq)
	combat_log_push(log, victim, .Death, attacker, spell, 0, seq)
}

// Fill a client's share of the snapshot: only the lines addressed to it.
combat_log_gather :: proc(
	log: ^Combat_Log,
	id: Entity_ID,
	out: ^[MAX_SNAPSHOT_COMBAT_EVENTS]Snapshot_Combat_Event,
) -> (count: int) {
	if id == INVALID_ENTITY || id >= MAX_ENTITIES {
		return 0
	}
	for j in 0..<MAX_COMBAT_EVENTS_PER_ENTITY {
		if count >= MAX_SNAPSHOT_COMBAT_EVENTS {
			break
		}
		e := &log.events[id][j]
		if !e.live {
			continue
		}
		out[count] = Snapshot_Combat_Event{
			seq        = e.seq,
			event_type = e.event_type,
			other_id   = e.other,
			spell_id   = e.spell_id,
			damage     = u16(clampf(e.damage, 0, 65535)),
		}
		count += 1
	}
	return count
}

// ---------------------------------------------------------------------------
// Damage

// Take `damage` off `victim` and record it everywhere it needs recording.
// Death itself is not decided here: `entity_tick_death_respawn` owns that
// transition, and it is the only thing that awards a kill, so a body that
// drops to zero from splash, a beam or a fall is counted exactly once.
combat_apply_damage :: proc(world: ^Entity_World, attacker, victim: Entity_ID, spell: Spell_ID, damage: f32) {
	if victim == INVALID_ENTITY || victim >= MAX_ENTITIES || damage <= 0 {
		return
	}
	if !world.characters[victim].active {
		return
	}

	world.characters[victim].health -= damage
	world.stats[victim].damage_taken += damage

	// Self-damage costs health but is nobody's work and nobody's kill.
	if attacker == INVALID_ENTITY || attacker >= MAX_ENTITIES || attacker == victim {
		return
	}
	if world.characters[attacker].active {
		world.stats[attacker].damage_dealt += damage
	}
	world.last_attacker[victim] = attacker
	world.last_attack_spell[victim] = spell
	combat_log_record_damage(&world.combat_log, attacker, victim, spell, damage)
}

// Called from the death transition. Credits the kill if someone earned it.
combat_record_death :: proc(world: ^Entity_World, victim: Entity_ID) {
	if victim == INVALID_ENTITY || victim >= MAX_ENTITIES {
		return
	}
	world.stats[victim].deaths += 1

	killer := world.last_attacker[victim]
	if killer == INVALID_ENTITY || killer >= MAX_ENTITIES || killer == victim {
		return
	}
	if world.characters[killer].active {
		world.stats[killer].kills += 1
	}
	combat_log_record_kill(&world.combat_log, killer, victim, world.last_attack_spell[victim])
}

// Match restart: the scoreline goes back to zero, names stay.
combat_reset_stats :: proc(world: ^Entity_World) {
	world.stats = {}
	world.combat_log = {}
	for i in 1..<MAX_ENTITIES {
		world.last_attacker[i] = INVALID_ENTITY
		world.last_attack_spell[i] = .None
	}
}
