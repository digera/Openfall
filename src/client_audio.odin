package main

// Client-only combat audio. Snapshot-derived one-shots plus retriggered
// Wirebang grains for charge wind-ups and the thunderbolt beam.

import "core:fmt"
import ma "vendor:miniaudio"
import sfx "game:sfx"

Audio_Loop :: enum u8 {
	Off,
	Missile_Charge,
	Orb_Charge,
	Lance_Charge,
	Blink_Charge,
	Heal_Charge,
	Lightning_Charge,
	Thunder_Beam,
}

Client_Audio :: struct {
	eng: ma.engine,
	ok:  bool,

	warmed:          bool,
	session_entity:  Entity_ID,
	loop:            Audio_Loop,
	loop_timer:      f32,
	loop_charge:     f32,
	thunder_hit_timer: f32,

	prev_hit_marker: f32,
	prev_on_ground:  bool,
	prev_vel_z:      f32,
	prev_dead:       [MAX_ENTITIES]bool,
	prev_proj_ids:   [MAX_SNAPSHOT_PROJECTILES]u32,
	prev_proj_count: int,

	confirm_id:     Entity_ID,
	confirm_until:  f64,
	last_heal_cast: f64,
}

client_audio: Client_Audio

client_audio_init :: proc() {
	if ma.engine_init(nil, &client_audio.eng) != .SUCCESS {
		fmt.eprintln("[Audio] miniaudio engine init failed")
		client_audio.ok = false
		return
	}
	client_audio.ok = true
	client_audio.prev_on_ground = true
	fmt.println("[Audio] miniaudio engine ready")
}

client_audio_shutdown :: proc() {
	if client_audio.ok {
		ma.engine_uninit(&client_audio.eng)
	}
	client_audio = {}
}

client_audio_reset :: proc() {
	client_audio.warmed = false
	client_audio.loop = .Off
	client_audio.loop_timer = 0
	client_audio.thunder_hit_timer = 0
	client_audio.confirm_id = INVALID_ENTITY
	client_audio.session_entity = INVALID_ENTITY
}

client_audio_play :: proc(cue: sfx.Cue) {
	if !client_audio.ok {
		return
	}
	sfx.play_cue(&client_audio.eng, cue)
}

client_sfx_note_fizzle :: proc(gc: ^Game_Client) {
	if gc.charging_spell == .None {
		return
	}
	if SPELL_DEFS[gc.charging_spell].payload == .Beam {
		return
	}
	if gc.charge_accum > 0.04 {
		client_audio_play(.Fizzle)
	}
}

client_sfx_play_cast :: proc(spell: Spell_ID) {
	#partial switch spell {
	case .Arcane_Missile:
		client_audio_play(.Missile_Cast)
	case .Arcane_Orb:
		client_audio_play(.Orb_Cast)
	case .Frost_Lance:
		client_audio_play(.Lance_Cast)
	case .Friendly_Heal:
		client_audio_play(.Heal_Tick)
		client_audio.last_heal_cast = game_client.client_world.local_time
	case .Call_Lightning:
		client_audio_play(.Lightning_Cast)
	case .Blink:
		// Arrival is the sound; the wind-up is the charge grain.
	}
}

@(private = "file")
spell_audio_loop :: proc(spell: Spell_ID) -> Audio_Loop {
	#partial switch spell {
	case .Arcane_Missile:
		return .Missile_Charge
	case .Arcane_Orb:
		return .Orb_Charge
	case .Frost_Lance:
		return .Lance_Charge
	case .Blink:
		return .Blink_Charge
	case .Friendly_Heal:
		return .Heal_Charge
	case .Call_Lightning:
		return .Lightning_Charge
	case .Thunderbolt:
		return .Thunder_Beam
	}
	return .Off
}

@(private = "file")
loop_cue :: proc(kind: Audio_Loop) -> (sfx.Cue, bool) {
	switch kind {
	case .Off:
		return .Fizzle, false
	case .Missile_Charge:
		return .Missile_Charge, true
	case .Orb_Charge:
		return .Orb_Charge, true
	case .Lance_Charge:
		return .Lance_Charge, true
	case .Blink_Charge:
		return .Blink_Charge, true
	case .Heal_Charge:
		return .Heal_Loop, true
	case .Lightning_Charge:
		return .Lightning_Charge, true
	case .Thunder_Beam:
		return .Thunder_Loop, true
	}
	return .Fizzle, false
}

@(private = "file")
loop_interval :: proc(kind: Audio_Loop, charge: f32) -> f32 {
	t := clampf(charge, 0, 1)
	switch kind {
	case .Off:
		return 1
	case .Missile_Charge:
		return lerpf(0.14, 0.07, t)
	case .Orb_Charge:
		return lerpf(0.18, 0.10, t)
	case .Lance_Charge:
		return lerpf(0.13, 0.07, t)
	case .Blink_Charge:
		return lerpf(0.12, 0.06, t)
	case .Heal_Charge:
		return lerpf(0.18, 0.10, t)
	case .Lightning_Charge:
		return lerpf(0.20, 0.09, t)
	case .Thunder_Beam:
		return 0.075
	}
	return 0.12
}

@(private = "file")
impact_cue :: proc(spell: Spell_ID) -> (sfx.Cue, bool) {
	#partial switch spell {
	case .Arcane_Missile:
		return .Missile_Impact, true
	case .Arcane_Orb:
		return .Orb_Impact, true
	case .Frost_Lance:
		return .Lance_Impact, true
	}
	return .Fizzle, false
}

client_audio_update :: proc(gc: ^Game_Client, dt: f32) {
	if !client_audio.ok {
		return
	}
	if gc.phase != .Playing {
		client_audio_reset()
		return
	}

	world := &gc.client_world
	if client_audio.session_entity != world.local_entity_id {
		client_audio.session_entity = world.local_entity_id
		client_audio.warmed = false
	}

	if !client_audio.warmed {
		client_audio_capture(gc)
		client_audio.warmed = true
		client_audio_update_loop(gc, dt)
		return
	}

	client_audio_update_loop(gc, dt)
	client_audio_world_events(gc, dt)
	client_audio_local_events(gc)
	client_audio_capture_projectiles(world)
}

@(private = "file")
client_audio_desired_loop :: proc(gc: ^Game_Client) -> (kind: Audio_Loop, charge: f32) {
	if gc.charging_spell != .None {
		def := &SPELL_DEFS[gc.charging_spell]
		return spell_audio_loop(gc.charging_spell), spell_charge_frac(def, gc.charge_accum)
	}

	world := &gc.client_world
	best_frac: f32 = 0
	for i in 0 ..< MAX_ENTITIES {
		remote := &world.remote_entities[i]
		if !remote.active || remote.channel_spell != .Call_Lightning {
			continue
		}
		kind = .Lightning_Charge
		if remote.channel_frac > best_frac {
			best_frac = remote.channel_frac
		}
	}
	if kind == .Lightning_Charge {
		return kind, best_frac
	}

	if client_world_beams_current(world) {
		for i in 0 ..< world.beam_count {
			if world.beams[i].spell_id == .Thunderbolt {
				return .Thunder_Beam, 1
			}
		}
	}
	return .Off, 0
}

@(private = "file")
client_audio_update_loop :: proc(gc: ^Game_Client, dt: f32) {
	kind, charge := client_audio_desired_loop(gc)
	if kind != client_audio.loop {
		client_audio.loop = kind
		client_audio.loop_timer = 0
	}
	client_audio.loop_charge = charge
	if kind == .Off {
		return
	}
	client_audio.loop_timer -= dt
	if client_audio.loop_timer <= 0 {
		if cue, ok := loop_cue(kind); ok {
			client_audio_play(cue)
		}
		client_audio.loop_timer = loop_interval(kind, charge)
	}
}

@(private = "file")
client_audio_world_events :: proc(gc: ^Game_Client, dt: f32) {
	world := &gc.client_world
	now := world.local_time

	for i in 0 ..< MAX_CLIENT_IMPACTS {
		im := &world.impacts[i]
		if !im.live || im.age < 0.999 {
			continue
		}
		if cue, ok := impact_cue(im.spell); ok {
			client_audio_play(cue)
		}
	}

	for i in 0 ..< MAX_CLIENT_STRIKES {
		s := &world.strikes[i]
		if !s.live || s.life < 0.999 {
			continue
		}
		client_audio_play(.Lightning_Strike)
	}

	for i in 0 ..< world.projectile_count {
		cp := &world.projectiles[i]
		if !cp.present {
			continue
		}
		if client_audio_saw_projectile(cp.snap.id) {
			continue
		}
		if cp.snap.owner_id == world.local_entity_id {
			continue
		}
		client_sfx_play_cast(cp.snap.spell_id)
	}

	if world.hit_marker > 0.05 && client_audio.prev_hit_marker <= 0.05 {
		client_audio_play(.Hit_Confirm)
	}
	if world.hit_marker > 0.4 && world.target_id != INVALID_ENTITY {
		client_audio.confirm_id = world.target_id
		client_audio.confirm_until = now + 1.6
	}
	client_audio.prev_hit_marker = world.hit_marker

	if beam, lit := client_world_local_beam(world); lit && beam.spell_id == .Thunderbolt && beam.hit {
		if world.target_id != INVALID_ENTITY {
			client_audio.confirm_id = world.target_id
			client_audio.confirm_until = now + 0.4
		}
		client_audio.thunder_hit_timer -= dt
		if client_audio.thunder_hit_timer <= 0 {
			client_audio_play(.Thunder_Hit)
			client_audio.thunder_hit_timer = 0.12
		}
	} else {
		client_audio.thunder_hit_timer = 0
	}

	for i in 0 ..< MAX_ENTITIES {
		remote := &world.remote_entities[i]
		dead_now := remote.active && remote.count > 0 && remote.states[0].dead
		if !client_audio.prev_dead[i] && dead_now {
			if Entity_ID(i) == client_audio.confirm_id && now <= client_audio.confirm_until {
				client_audio_play(.Kill)
			}
		}
		client_audio.prev_dead[i] = dead_now
	}
}

@(private = "file")
client_audio_local_events :: proc(gc: ^Game_Client) {
	pred := &gc.client_world.prediction
	char := pred.predicted_char
	now := gc.client_world.local_time

	if pred.died {
		client_audio_play(.Death)
		pred.died = false
	} else if pred.damage_taken > 0 {
		client_audio_play(.Hurt)
	}

	if pred.healed > 0 && now - client_audio.last_heal_cast > 0.45 {
		client_audio_play(.Heal_Tick)
	}

	if pred.teleported {
		client_audio_play(.Blink_Arrive)
	}
	if pred.respawned {
		client_audio_play(.Respawn)
	}

	if pred.initialized && !char.dead {
		if client_audio.prev_on_ground && !char.on_ground && char.vel.z > 2.0 {
			client_audio_play(.Jump)
		}
		if !client_audio.prev_on_ground && char.on_ground && client_audio.prev_vel_z < -2.5 {
			client_audio_play(.Land)
		}
	}
	client_audio.prev_on_ground = char.on_ground
	client_audio.prev_vel_z = char.vel.z
}

@(private = "file")
client_audio_capture :: proc(gc: ^Game_Client) {
	world := &gc.client_world
	pred := &world.prediction
	client_audio.prev_on_ground = pred.predicted_char.on_ground
	client_audio.prev_vel_z = pred.predicted_char.vel.z
	client_audio.prev_hit_marker = world.hit_marker
	client_audio_capture_projectiles(world)
	for i in 0 ..< MAX_ENTITIES {
		remote := &world.remote_entities[i]
		client_audio.prev_dead[i] = remote.active && remote.count > 0 && remote.states[0].dead
	}
}

@(private = "file")
client_audio_capture_projectiles :: proc(world: ^Client_World) {
	client_audio.prev_proj_count = 0
	for i in 0 ..< world.projectile_count {
		if !world.projectiles[i].present {
			continue
		}
		if client_audio.prev_proj_count >= MAX_SNAPSHOT_PROJECTILES {
			break
		}
		client_audio.prev_proj_ids[client_audio.prev_proj_count] = world.projectiles[i].snap.id
		client_audio.prev_proj_count += 1
	}
}

@(private = "file")
client_audio_saw_projectile :: proc(id: u32) -> bool {
	for i in 0 ..< client_audio.prev_proj_count {
		if client_audio.prev_proj_ids[i] == id {
			return true
		}
	}
	return false
}
