package main

import "core:math"

// Shared deterministic character simulation.
// Used by both client (prediction) and server (authoritative).
// Determinism requirements:
// - Fixed timestep (60Hz)
// - f32 math only, identical code paths on both ends
// - Same collision rules (world_map.odin)

SIMULATION_TICK_RATE :: 60
SIMULATION_DT :: f32(1.0 / SIMULATION_TICK_RATE)

CHARACTER_HEIGHT_M     :: 1.72
CHARACTER_EYE_HEIGHT_M :: 1.56
CHARACTER_RADIUS_M     :: 0.22

CHARACTER_WALK_SPEED   :: f32(5.4)
CHARACTER_SPRINT_MULT  :: f32(1.45)
CHARACTER_SLOW_MULT    :: f32(0.55)
CHARACTER_GROUND_ACCEL :: f32(14.0)   // exponential approach rate (1/s)
CHARACTER_AIR_ACCEL    :: f32(2.2)
CHARACTER_GRAVITY      :: f32(22.0)
CHARACTER_JUMP_VELOCITY :: f32(6.6)

STAMINA_SPRINT_DRAIN   :: f32(24.0)   // per second while sprinting
STAMINA_SPRINT_MIN     :: f32(5.0)    // need at least this much to start sprinting

// Aim lock burns the bar faster than a sprint, so tracking is bought with the
// legs: about three and a half seconds of help on a full bar, and none of it
// spent running. The client asks for the lock and the server charges for it,
// so the cost cannot be dodged by a client that stops sending the flag; that
// also stops the assist it is asking for.
STAMINA_AIM_LOCK_DRAIN :: f32(28.0)   // per second while locked onto a target
STAMINA_AIM_LOCK_MIN   :: f32(20.0)   // need this much before a lock will engage

// Simulate one character for one tick.
simulate_character_step :: proc(char: ^Character_State, input: Input_State, dt: f32) {
	// Look is absolute; wrap/clamp defensively.
	char.yaw = wrap_angle(input.yaw)
	char.pitch = clampf(input.pitch, -CAM_PITCH_MAX, CAM_PITCH_MAX)

	if char.slow_ticks > 0 {
		char.slow_ticks -= 1
	}

	if char.dead {
		char.vel = {}
		return
	}

	simulate_character_move_xy(char, input, dt)
	simulate_character_move_z(char, input, dt)
}

@(private)
simulate_character_move_xy :: proc(char: ^Character_State, input: Input_State, dt: f32) {
	wish_fwd := input.move_fwd
	wish_str := input.move_str
	wish_len := math.sqrt(wish_fwd * wish_fwd + wish_str * wish_str)
	moving := wish_len > 0.001

	// Aim lock and sprint draw on the same bar and cannot be held together:
	// tracking costs you the ability to close or break away while it runs.
	aim_locking := input.aim_lock && char.stamina > 0
	sprinting := input.sprint && moving && char.on_ground && char.stamina > 0 && !aim_locking

	if aim_locking {
		char.stamina = max(char.stamina - STAMINA_AIM_LOCK_DRAIN * dt, 0)
	} else if sprinting {
		char.stamina = max(char.stamina - STAMINA_SPRINT_DRAIN * dt, 0)
	} else {
		char.stamina = min(char.stamina + STAMINA_REGEN_PER_SEC * dt, STAMINA_MAX)
	}

	speed := CHARACTER_WALK_SPEED
	if sprinting {
		speed *= CHARACTER_SPRINT_MULT
	}
	if char.slow_ticks > 0 {
		speed *= CHARACTER_SLOW_MULT
	}

	wish := vec3{}
	if moving {
		if wish_len > 1 {
			wish_fwd /= wish_len
			wish_str /= wish_len
		}
		look := camera_forward(char.yaw, 0)
		right := camera_right(char.yaw)
		wish = {
			(look.x * wish_fwd + right.x * wish_str) * speed,
			(look.y * wish_fwd + right.y * wish_str) * speed,
			0,
		}
	}

	// Exponential approach toward the wish velocity. On the ground this gives
	// crisp starts and stops; in the air it gives limited steering while
	// preserving momentum.
	vel_xy := vec3{char.vel.x, char.vel.y, 0}
	if char.on_ground {
		k := min(CHARACTER_GROUND_ACCEL * dt, 1.0)
		vel_xy += (wish - vel_xy) * k
		if !moving && len2_vec3(vel_xy) < 0.02 * 0.02 {
			vel_xy = {}
		}
	} else if moving {
		k := min(CHARACTER_AIR_ACCEL * dt, 1.0)
		vel_xy += (wish - vel_xy) * k
	}

	// Move with axis-separated sliding against the world.
	step := vel_xy * dt
	try := char.pos + step
	if !simulate_character_blocked(try) {
		char.pos = try
	} else {
		try = char.pos
		try.x += step.x
		if !simulate_character_blocked(try) {
			char.pos.x = try.x
		} else {
			vel_xy.x = 0
		}
		try = char.pos
		try.y += step.y
		if !simulate_character_blocked(try) {
			char.pos.y = try.y
		} else {
			vel_xy.y = 0
		}
	}

	char.vel.x = vel_xy.x
	char.vel.y = vel_xy.y
}

@(private)
simulate_character_move_z :: proc(char: ^Character_State, input: Input_State, dt: f32) {
	on_floor := char.pos.z <= WORLD_FLOOR_Z + 0.001
	if on_floor && char.vel.z <= 0 {
		char.pos.z = WORLD_FLOOR_Z
		char.vel.z = 0
		char.on_ground = true
	}

	if char.on_ground && input.jump {
		char.on_ground = false
		char.vel.z = CHARACTER_JUMP_VELOCITY
	}

	if !char.on_ground {
		char.vel.z -= CHARACTER_GRAVITY * dt
		try := char.pos
		try.z += char.vel.z * dt

		if try.z <= WORLD_FLOOR_Z {
			char.pos.z = WORLD_FLOOR_Z
			char.vel.z = 0
			char.on_ground = true
		} else if simulate_character_blocked(try) {
			// Hit something above or the world shape changed under us; stop vertical motion.
			char.vel.z = 0
			if try.z < char.pos.z {
				char.on_ground = true
			}
		} else {
			char.pos.z = try.z
		}
	}
}

// Cylinder collision against the world. Samples points on the character cylinder.
@(private)
simulate_character_blocked :: proc(pos: vec3) -> bool {
	offs := [6]vec3{
		{0, 0, 0.12},
		{0, 0, 0.32},
		{0, 0, CHARACTER_HEIGHT_M * 0.45},
		{0, 0, CHARACTER_HEIGHT_M * 0.88},
		{CHARACTER_RADIUS_M * 0.7, 0, CHARACTER_HEIGHT_M * 0.5},
		{-CHARACTER_RADIUS_M * 0.7, 0, CHARACTER_HEIGHT_M * 0.5},
	}
	for o in offs {
		if !world_point_free(pos + o, CHARACTER_RADIUS_M) {
			return true
		}
	}
	return false
}

// Simulate the entire world for one tick (server).
simulate_world_step :: proc(world: ^Entity_World) {
	for i in 1..<MAX_ENTITIES {
		if !world.characters[i].active {
			continue
		}
		char := world.characters[i]
		simulate_character_step(&char, world.inputs[i], SIMULATION_DT)
		world.characters[i] = char
	}
}

// Apply an impulse (knockback) to a character. Lifts slightly so friction
// doesn't eat it immediately.
character_apply_impulse :: proc(char: ^Character_State, dir: vec3, strength: f32) {
	if char.dead {
		return
	}
	d := norm_vec3(vec3{dir.x, dir.y, 0})
	char.vel.x += d.x * strength
	char.vel.y += d.y * strength
	char.vel.z = max(char.vel.z, strength * 0.35)
	char.on_ground = false
	if char.pos.z <= WORLD_FLOOR_Z {
		char.pos.z = WORLD_FLOOR_Z + 0.01
	}
}
