package main

// Combat log: recent damage/kill events per entity for client HUD display.
// Events are kept for COMBAT_LOG_LINGER_SEC and replicated to the entity's
// client owner in snapshots for deduplication across lost packets.

MAX_COMBAT_EVENTS_PER_ENTITY :: 16
COMBAT_LOG_LINGER_SEC :: f32(1.0)

Combat_Event :: struct {
	live:       bool,
	seq:        u8,
	event_type: Combat_Event_Type,
	attacker:   Entity_ID,
	victim:     Entity_ID,
	spell_id:   Spell_ID,
	damage:     f32,
	age:        f32,
}

Combat_Log :: struct {
	events:     [MAX_ENTITIES][MAX_COMBAT_EVENTS_PER_ENTITY]Combat_Event,
	next_seq:   u8,
}

combat_log_init :: proc() -> Combat_Log {
	return Combat_Log{next_seq = 1}
}

combat_log_tick :: proc(log: ^Combat_Log, dt: f32) {
	for i in 1..<MAX_ENTITIES {
		for j in 0..<MAX_COMBAT_EVENTS_PER_ENTITY {
			if log.events[i][j].live {
				log.events[i][j].age += dt
				if log.events[i][j].age >= COMBAT_LOG_LINGER_SEC {
					log.events[i][j].live = false
				}
			}
		}
	}
}

combat_log_record_damage :: proc(log: ^Combat_Log, entity_world: ^Entity_World, attacker, victim: Entity_ID, spell: Spell_ID, damage: f32) {
	if attacker == INVALID_ENTITY || victim == INVALID_ENTITY {
		return
	}
	if attacker == victim {
		return
	}

	seq := log.next_seq
	log.next_seq += 1

	combat_log_record_event(log, attacker, Combat_Event{
		live       = true,
		seq        = seq,
		event_type = .Damage_Dealt,
		attacker   = attacker,
		victim     = victim,
		spell_id   = spell,
		damage     = damage,
	})

	combat_log_record_event(log, victim, Combat_Event{
		live       = true,
		seq        = seq,
		event_type = .Damage_Taken,
		attacker   = attacker,
		victim     = victim,
		spell_id   = spell,
		damage     = damage,
	})

	char := entity_world.characters[victim]
	char.last_attacker = attacker
	char.last_attack_spell = spell
	entity_world.characters[victim] = char
}

combat_log_record_kill :: proc(log: ^Combat_Log, attacker, victim: Entity_ID, spell: Spell_ID) {
	if attacker == INVALID_ENTITY || victim == INVALID_ENTITY {
		return
	}
	if attacker == victim {
		return
	}

	seq := log.next_seq
	log.next_seq += 1

	combat_log_record_event(log, attacker, Combat_Event{
		live       = true,
		seq        = seq,
		event_type = .Kill,
		attacker   = attacker,
		victim     = victim,
		spell_id   = spell,
	})

	combat_log_record_event(log, victim, Combat_Event{
		live       = true,
		seq        = seq,
		event_type = .Death,
		attacker   = attacker,
		victim     = victim,
		spell_id   = spell,
	})
}

@(private = "file")
combat_log_record_event :: proc(log: ^Combat_Log, entity_id: Entity_ID, event: Combat_Event) {
	if entity_id >= MAX_ENTITIES {
		return
	}

	for i in 0..<MAX_COMBAT_EVENTS_PER_ENTITY {
		if !log.events[entity_id][i].live {
			log.events[entity_id][i] = event
			return
		}
	}

	oldest := 0
	oldest_age := log.events[entity_id][0].age
	for i in 1..<MAX_COMBAT_EVENTS_PER_ENTITY {
		if log.events[entity_id][i].age > oldest_age {
			oldest = i
			oldest_age = log.events[entity_id][i].age
		}
	}
	log.events[entity_id][oldest] = event
}

combat_log_get_events :: proc(log: ^Combat_Log, entity_id: Entity_ID, out: ^[MAX_SNAPSHOT_COMBAT_EVENTS]Snapshot_Combat_Event) -> (count: int) {
	if entity_id >= MAX_ENTITIES {
		return 0
	}

	count = 0
	for i in 0..<MAX_COMBAT_EVENTS_PER_ENTITY {
		if count >= MAX_SNAPSHOT_COMBAT_EVENTS {
			break
		}
		e := &log.events[entity_id][i]
		if !e.live {
			continue
		}

		other_id := e.attacker if e.event_type == .Damage_Taken || e.event_type == .Death else e.victim
		out[count] = Snapshot_Combat_Event{
			seq        = e.seq,
			event_type = e.event_type,
			other_id   = other_id,
			spell_id   = e.spell_id,
			damage     = u8(clampf(e.damage, 0, 255)),
		}
		count += 1
	}
	return count
}
