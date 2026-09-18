package main

// Client-only combat audio. Snapshot-derived one-shots plus retriggered
// Wirebang grains for charge wind-ups and the thunderbolt beam.
//
// Anything that happens in the world is played at the place it happens, heard
// from the camera's eye and facing. Anything that happens to the local player
// - their own cast, their own pain, the hit they just landed - is played flat
// on the listener, because it has no position they could hear it from.

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

// A wind-up or beam heard on someone else, one slot per entity. The local
// player's own loop is a single global state because there can only be one of
// it; other people's are not, and collapsing them would put two wisps charging
// at opposite ends of the plaza in the middle of the listener's head.
Remote_Loop :: struct {
	kind:  Audio_Loop,
	timer: f32,
}

Client_Audio :: struct {
	eng: ma.engine,
	ok:  bool,

	warmed:          bool,
	session_entity:  Entity_ID,
	loop:            Audio_Loop,
	loop_timer:      f32,
	loop_charge:     f32,
	remote_loops:    [MAX_ENTITIES]Remote_Loop,
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
	if !sfx.init(&client_audio.eng) {
		fmt.eprintln("[Audio] failed to cache SFX scripts")
		ma.engine_uninit(&client_audio.eng)
		client_audio.ok = false
		return
	}
	client_audio.ok = true
	client_audio.prev_on_ground = true
	fmt.println("[Audio] SFX scripts cached")
}

client_audio_shutdown :: proc() {
	if client_audio.ok {
		sfx.uninit()
		ma.engine_uninit(&client_audio.eng)
	}
	client_audio = {}
}

client_audio_reset :: proc() {
	client_audio.warmed = false
	client_audio.loop = .Off
	client_audio.loop_timer = 0
	client_audio.remote_loops = {}
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

// Roughly where a wisp holds its cast orb: high enough on the body that a
// sound from it is not coming out of someone's shins.
AUDIO_HAND_M :: f32(CHARACTER_HEIGHT_M * 0.62)

// How far a sound carries. Every placed cue picks one: the same explosion has
// to be audible across a lane and the same charge grain has to stay the
// caster's business, and neither works with one falloff for both.
Audio_Carry :: enum u8 {
	Near, // spellwork in someone's hands
	Mid,  // casts, small impacts, a body being hit
	Far,  // orbs, sky bolts, thunder
}

@(private = "file")
CARRY_FALLOFF := [Audio_Carry]sfx.Emitter {
	.Near = {min_dist = 2.5, max_dist = 40,  rolloff = 1.3,  volume = 1},
	.Mid  = {min_dist = 5,   max_dist = 80,  rolloff = 1.0,  volume = 1},
	.Far  = {min_dist = 12,  max_dist = 170, rolloff = 0.85, volume = 1},
}

// Play `cue` at `pos` in world space.
client_audio_play_at :: proc(cue: sfx.Cue, carry: Audio_Carry, pos: vec3, volume: f32 = 1) {
	if !client_audio.ok {
		return
	}
	em := CARRY_FALLOFF[carry]
	em.pos = {pos.x, pos.y, pos.z}
	em.volume *= volume
	sfx.play_cue_at(&client_audio.eng, cue, em)
}

// The ear, moved to the camera every frame before anything is played from it.
// It takes the eye position and the look angles but none of the view kick:
// bob, land dip and cast recoil are there to be felt, and a pan that shivered
// with them would only be noise.
@(private = "file")
client_audio_update_listener :: proc(gc: ^Game_Client) {
	pred := &gc.client_world.prediction
	eye := client_prediction_render_pos(pred, gc.render_alpha) + vec3{0, 0, PLAYER_EYE_M}
	fwd := camera_forward(gc.view_yaw, gc.view_pitch)
	sfx.set_listener(&client_audio.eng, {eye.x, eye.y, eye.z}, {fwd.x, fwd.y, fwd.z}, {0, 0, 1})
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

@(private = "file")
cast_cue :: proc(spell: Spell_ID) -> (sfx.Cue, bool) {
	#partial switch spell {
	case .Arcane_Missile:
		return .Missile_Cast, true
	case .Arcane_Orb:
		return .Orb_Cast, true
	case .Frost_Lance:
		return .Lance_Cast, true
	case .Friendly_Heal:
		return .Heal_Tick, true
	case .Call_Lightning:
		return .Lightning_Cast, true
	case .Blink:
		// Arrival is the sound; the wind-up is the charge grain.
	}
	return .Fizzle, false
}

// The local player's own cast. Flat on the listener: it left their hands.
client_sfx_play_cast :: proc(spell: Spell_ID) {
	if cue, ok := cast_cue(spell); ok {
		client_audio_play(cue)
	}
	if spell == .Friendly_Heal {
		client_audio.last_heal_cast = game_client.client_world.local_time
	}
}

// Someone else's, played where what they threw entered the world.
client_sfx_play_cast_at :: proc(spell: Spell_ID, pos: vec3) {
	if cue, ok := cast_cue(spell); ok {
		client_audio_play_at(cue, spell == .Arcane_Orb ? .Far : .Mid, pos)
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

	client_audio_update_listener(gc)

	if !client_audio.warmed {
		client_audio_capture(gc)
		client_audio.warmed = true
		client_audio_update_loop(gc, dt)
		return
	}

	client_audio_update_loop(gc, dt)
	client_audio_update_remote_loops(gc, dt)
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
	// A beam the server has lit but the local charge has already dropped: the
	// sound follows the server, since that is what is doing the damage.
	if beam, lit := client_world_local_beam(&gc.client_world); lit && beam.spell_id == .Thunderbolt {
		return .Thunder_Beam, 1
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

// Everyone else's spellwork, one grain stream per caster from the orb in their
// hand. Every grain is a fresh one-shot placed where its caster is now, so a
// wind-up follows a wisp that is strafing while it charges without any voice
// having to be tracked and moved. What they are winding is in every snapshot
// for the cast orb's sake, which is the same thing the sound is: a telegraph
// that only counts as counterplay if it can be read from across the plaza.
@(private = "file")
client_audio_update_remote_loops :: proc(gc: ^Game_Client, dt: f32) {
	world := &gc.client_world
	for i in 0 ..< MAX_ENTITIES {
		slot := &client_audio.remote_loops[i]
		remote := &world.remote_entities[i]

		kind := Audio_Loop.Off
		if remote.active && !remote.display_state.dead && Entity_ID(i) != world.local_entity_id {
			kind = spell_audio_loop(remote.channel_spell)
		}
		if kind != slot.kind {
			slot.kind = kind
			slot.timer = 0
		}
		if kind == .Off {
			continue
		}
		slot.timer -= dt
		if slot.timer > 0 {
			continue
		}
		slot.timer = loop_interval(kind, remote.channel_frac)
		cue, ok := loop_cue(kind)
		if !ok {
			continue
		}
		// A beam is heard from the caster, since that is where it pours out of,
		// and carries further than a wind-up does.
		pos := remote.display_state.pos + vec3{0, 0, AUDIO_HAND_M}
		client_audio_play_at(cue, kind == .Thunder_Beam ? .Far : .Near, pos)
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
			client_audio_play_at(cue, im.spell == .Arcane_Orb ? .Far : .Mid, im.pos)
		}
	}

	for i in 0 ..< MAX_CLIENT_STRIKES {
		s := &world.strikes[i]
		if !s.live || s.life < 0.999 {
			continue
		}
		client_audio_play_at(.Lightning_Strike, .Far, s.pos)
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
		client_sfx_play_cast_at(cp.snap.spell_id, cp.snap.pos)
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
			// At the far end of the beam, where the body it is cooking is.
			client_audio_play_at(.Thunder_Hit, .Far, beam.end)
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
