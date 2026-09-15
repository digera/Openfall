package main

import "core:math"

// Shared deterministic character simulation.
// Used by both client (prediction) and server (authoritative).
// Determinism requirements:
// - Fixed timestep (60Hz = 1/60s)
// - No floating-point indeterminacy (careful with optimizations)
// - Same collision/physics rules everywhere

SIMULATION_TICK_RATE :: 60
SIMULATION_DT :: f32(1.0 / SIMULATION_TICK_RATE)

// Character dimensions (same as player constants)
CHARACTER_HEIGHT_M :: 1.72
CHARACTER_EYE_HEIGHT_M :: 1.56
CHARACTER_RADIUS_M :: 0.22
CHARACTER_WALK_SPEED :: f32(4.8)
CHARACTER_GRAVITY :: 22.0
CHARACTER_JUMP_VELOCITY :: 6.4

// Simulate one character for one tick.
// This is the shared kernel used by client and server.
simulate_character_step :: proc(
	char: ^Character_State,
	input: Input_State,
	dt: f32,
) {
	// Apply look input
	char.yaw += input.delta_yaw
	char.pitch += input.delta_pitch
	char.pitch = clampf(char.pitch, -CAM_PITCH_MAX, CAM_PITCH_MAX)
	
	// Horizontal movement
	simulate_character_move_xy(char, input, dt)
	
	// Vertical movement and jumping
	simulate_character_move_z(char, input, dt)
	
	// Clamp to room bounds (TODO: replace with spatial grid)
	char.pos.x = clampf(char.pos.x, ROOM_MIN.x + CHARACTER_RADIUS_M, ROOM_MAX.x - CHARACTER_RADIUS_M)
	char.pos.y = clampf(char.pos.y, ROOM_MIN.y + CHARACTER_RADIUS_M, ROOM_MAX.y - CHARACTER_RADIUS_M)
}

@(private)
simulate_character_move_xy :: proc(char: ^Character_State, input: Input_State, dt: f32) {
	wish_fwd := input.move_fwd
	wish_str := input.move_str
	wish_len := math.sqrt(wish_fwd * wish_fwd + wish_str * wish_str)
	
	if wish_len > 0 {
		// Normalize wish direction
		wish_fwd /= wish_len
		wish_str /= wish_len
		
		// Convert to world space based on yaw (pitch doesn't affect horizontal movement)
		look := camera_forward(char.yaw, 0)
		right := camera_right(char.yaw)
		
		step := CHARACTER_WALK_SPEED * dt
		vx := look.x * wish_fwd + right.x * wish_str
		vy := look.y * wish_fwd + right.y * wish_str
		
		// Try X movement
		try := char.pos
		try.x += vx * step
		if !simulate_character_blocked(try) {
			char.pos.x = try.x
		}
		
		// Try Y movement
		try = char.pos
		try.y += vy * step
		if !simulate_character_blocked(try) {
			char.pos.y = try.y
		}
	}
}

@(private)
simulate_character_move_z :: proc(char: ^Character_State, input: Input_State, dt: f32) {
	// Only snap to the floor when not already leaving it. Zeroing vel_z while
	// still at z=0 was cancelling jumps on the tick after they started.
	on_floor := char.pos.z <= ROOM_MIN.z + 0.001
	if on_floor && char.vel_z <= 0 {
		char.pos.z = ROOM_MIN.z
		char.vel_z = 0
		char.on_ground = true
	}

	if char.on_ground && input.jump {
		char.on_ground = false
		char.vel_z = CHARACTER_JUMP_VELOCITY
	}

	if !char.on_ground {
		char.vel_z -= CHARACTER_GRAVITY * dt

		try := char.pos
		try.z += char.vel_z * dt

		if try.z <= ROOM_MIN.z {
			char.pos.z = ROOM_MIN.z
			char.vel_z = 0
			char.on_ground = true
		} else if char.vel_z > 0 && simulate_character_blocked(try) {
			char.vel_z = 0
		} else if char.vel_z <= 0 && simulate_character_blocked(try) {
			char.vel_z = 0
			char.on_ground = true
		} else {
			char.pos.z = try.z
		}
	}
}

// Cylinder collision against room AABB (simplified from player_blocked).
// Tests multiple points on the character cylinder.
@(private)
simulate_character_blocked :: proc(pos: vec3) -> bool {
	// Sample points on the character cylinder
	offs := [6]vec3{
		{0, 0, 0.12},
		{0, 0, 0.32},
		{0, 0, CHARACTER_HEIGHT_M * 0.45},
		{0, 0, CHARACTER_HEIGHT_M * 0.88},
		{CHARACTER_RADIUS_M * 0.7, 0, CHARACTER_HEIGHT_M * 0.5},
		{-CHARACTER_RADIUS_M * 0.7, 0, CHARACTER_HEIGHT_M * 0.5},
	}
	
	for o in offs {
		q := pos + o
		if !room_inside(q, 0.02) {
			return true
		}
	}
	
	return false
}

// Simulate the entire world for one tick.
// This is the deterministic kernel that runs on the server.
simulate_world_step :: proc(world: ^Entity_World) {
	// Process all active entities
	for i in 1..<MAX_ENTITIES {
		if !world.characters[i].active {
			continue
		}

		// Copy out of the SOA array — a #soa pointer is not ^Character_State
		char := world.characters[i]
		simulate_character_step(&char, world.inputs[i], SIMULATION_DT)
		world.characters[i] = char
	}
}

