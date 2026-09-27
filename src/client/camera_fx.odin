package main

// Camera feel: head bob, landing dip, cast kicks, strafe lean and the flashes
// driven by what the prediction reports. Renderer-independent; the scene
// builder reads it when it places the eye.

import "core:math"

Camera_FX :: struct {
	bob_phase:   f32,
	bob_amount:  f32,
	land_dip:    f32,
	land_vel:    f32,
	hurt:        f32,
	mend:        f32,
	flash:       f32,
	fov_kick:    f32,
	cast_kick:   f32,
	roll:        f32,
	sprint_blend: f32,
	prev_on_ground: bool,
	prev_vel_z:  f32,
}

camera_fx_init :: proc(fx: ^Camera_FX) {
	fx^ = {}
	fx.prev_on_ground = true
}

camera_fx_on_cast :: proc(fx: ^Camera_FX, spell: Spell_ID) {
	#partial switch spell {
	case .Arcane_Missile: fx.cast_kick += 0.010
	case .Arcane_Orb:     fx.cast_kick += 0.028; fx.fov_kick = max(fx.fov_kick, 0.35)
	case .Frost_Lance:    fx.cast_kick += 0.020
	case .Call_Lightning: fx.cast_kick += 0.030; fx.fov_kick = max(fx.fov_kick, 0.40)
	case .Blink:          // handled when the teleport lands
	case .Friendly_Heal:  fx.cast_kick += 0.012
	}
}

camera_fx_update :: proc(fx: ^Camera_FX, gc: ^Game_Client, dt: f32) {
	pred := &gc.client_world.prediction
	char := pred.predicted_char

	// Head bob scales with horizontal speed, only on the ground
	speed := math.sqrt(char.vel.x * char.vel.x + char.vel.y * char.vel.y)
	target_bob: f32 = 0
	if char.on_ground && !char.dead && pred.initialized {
		target_bob = clampf(speed / CHARACTER_WALK_SPEED, 0, 1.3)
	}
	fx.bob_amount += (target_bob - fx.bob_amount) * min(dt * 9.0, 1.0)
	fx.bob_phase += dt * (6.8 + speed * 0.45) * (char.on_ground ? 1.0 : 0.25)

	// Landing dip: a damped spring kicked by the impact velocity
	if !fx.prev_on_ground && char.on_ground && fx.prev_vel_z < -2.5 {
		fx.land_vel -= clampf(-fx.prev_vel_z * 0.035, 0.05, 0.30)
	}
	fx.prev_on_ground = char.on_ground
	fx.prev_vel_z = char.vel.z
	fx.land_vel += (-fx.land_dip * 220.0 - fx.land_vel * 16.0) * dt
	fx.land_dip += fx.land_vel * dt

	// Events from reconciliation
	if pred.damage_taken > 0 {
		fx.hurt = min(fx.hurt + pred.damage_taken / 45.0, 1.0)
		pred.damage_taken = 0
	}
	// Health arriving is the only confirmation a heal landed, so the mend
	// bloom is driven off the snapshot rather than off the release.
	if pred.healed > 0 {
		fx.mend = min(fx.mend + pred.healed / 45.0, 1.0)
		pred.healed = 0
	}
	if pred.teleported {
		fx.flash = 1.0
		fx.fov_kick = 1.0
		pred.teleported = false
	}
	if pred.launched {
		fx.fov_kick = max(fx.fov_kick, 0.6)
		pred.launched = false
	}
	if pred.respawned {
		fx.flash = 0.7
		pred.respawned = false
	}

	fx.hurt *= math.exp(-dt * 2.6)
	fx.mend *= math.exp(-dt * 2.2)
	fx.flash *= math.exp(-dt * 5.5)
	fx.fov_kick *= math.exp(-dt * 6.5)
	fx.cast_kick *= math.exp(-dt * 11.0)

	// A lit beam shivers the view a little for as long as it is held.
	if _, lit := client_world_local_beam(&gc.client_world); lit {
		t := f32(gc.client_world.local_time)
		fx.cast_kick = max(fx.cast_kick, 0.0025 + 0.0025 * math.sin(t * 41.0) * math.sin(t * 13.0))
	}

	// Lean into strafes
	right := camera_right(gc.view_yaw)
	lateral := char.vel.x * right.x + char.vel.y * right.y
	target_roll := -lateral * 0.006
	fx.roll += (target_roll - fx.roll) * min(dt * 8.0, 1.0)

	sprinting := gc.move_input.sprint && speed > CHARACTER_WALK_SPEED * 1.1 && char.on_ground
	fx.sprint_blend += ((sprinting ? 1.0 : 0.0) - fx.sprint_blend) * min(dt * 6.0, 1.0)
}
