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

// Momentum. Nothing here makes anyone faster: speed comes from a Gust pad, an
// orb blast or a knockback, and these rules decide how much of it survives.
//
// In the air, above run speed, steering bends the heading without bleeding the
// pace; pulling back against it still brakes. Below run speed the air behaves
// as it always did.
//
// A jump pressed within HOP_EARLY_TICKS before touchdown, or HOP_LATE_TICKS
// after it, is a hop: the feet never grip and the whole speed carries into the
// next jump. The feet coast through that late window, so a landing is not
// already a skid before the player has had a chance to hop. Any other jump --
// Space held down through the landing, or pressed after the window -- leaves
// at run speed. Holding Space bounces; timing it is what keeps the speed.
//
// Every landing faster than HOP_SAFE_SPEED costs health (landing_damage), so a
// chain of hops is health traded for ground covered.
HOP_EARLY_TICKS   :: 3        // 50 ms
HOP_LATE_TICKS    :: 3        // 50 ms
HOP_RUN_SPEED     :: CHARACTER_WALK_SPEED * CHARACTER_SPRINT_MULT
CHARACTER_AIR_TURN :: f32(2.5) // 1/s: how fast air steering bends momentum above run speed
CHARACTER_MAX_SPEED :: f32(30.0)  // horizontal, m/s
CHARACTER_MAX_RISE  :: f32(20.0)  // upward, m/s: the most any blast can throw a body skyward

// Collision is swept in steps no longer than this, so a body flying at the
// speed cap still stops against a crate rather than half a tick short of it.
CHARACTER_SWEEP_STEP_M :: f32(0.3)

// How far under the feet to look for something to stand on. A body resting on
// a crate or a tower that walks off the edge starts to fall.
CHARACTER_GROUND_PROBE_M :: f32(0.05)

// Landing damage. A normal jump lands at about 6 m/s and a walk off a crate top
// at about 10; neither hurts. Coming down harder than FALL_SAFE_SPEED -- a rocket jump,
// a blast off a pillar -- does. Running into the ground faster than a sprint
// hurts too, which is what makes a long hop chain cost something.
FALL_SAFE_SPEED     :: f32(11.0)  // m/s downward: a drop of about 2.75 m is free
FALL_DAMAGE_PER_MPS :: f32(6.0)   // health per m/s past it
HOP_SAFE_SPEED      :: f32(8.0)   // m/s horizontal: sprint pace lands free
HOP_DAMAGE_PER_MPS  :: f32(1.2)   // health per m/s past it

// Bunny-hop bookkeeping. Small on purpose: it rides the snapshot to its owner
// as one byte.
Hop_State :: struct {
	jump_held:    bool, // jump was down last tick, so a press is the edge
	buffer_ticks: u8,   // counts down from HOP_EARLY_TICKS + 1 after a press
	ground_ticks: u8,   // ticks since touchdown, saturating; 0 while airborne
}

HOP_GROUND_TICKS_MAX :: 15

#assert(HOP_EARLY_TICKS + 1 <= 7)            // buffer_ticks has three bits on the wire
#assert(HOP_LATE_TICKS < HOP_GROUND_TICKS_MAX) // ground_ticks has four

// What the feet hit the ground with on the tick they touched down.
Landing :: struct {
	fall_speed: f32, // m/s downward
	run_speed:  f32, // m/s horizontal
}

// Health a landing costs. Zero for anything a normal jump or a sprint does.
landing_damage :: proc(landing: Landing) -> f32 {
	fall := max(landing.fall_speed - FALL_SAFE_SPEED, 0) * FALL_DAMAGE_PER_MPS
	run := max(landing.run_speed - HOP_SAFE_SPEED, 0) * HOP_DAMAGE_PER_MPS
	return fall + run
}

STAMINA_SPRINT_DRAIN   :: f32(24.0)   // per second while sprinting
STAMINA_SPRINT_MIN     :: f32(40.0)   // empty bar must climb back to here before sprint will start

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
	char.landing = {}

	// A press is the edge, not the key being down. The buffer lets a press a
	// few ticks before touchdown still count once the feet arrive.
	pressed := input.jump && !char.hop.jump_held
	char.hop.jump_held = input.jump
	if pressed {
		char.hop.buffer_ticks = HOP_EARLY_TICKS + 1
	} else if char.hop.buffer_ticks > 0 {
		char.hop.buffer_ticks -= 1
	}

	if char.dead {
		char.vel = {}
		char.sprint_active = false
		char.hop.buffer_ticks = 0
		char.hop.ground_ticks = 0
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
	// A sprint already running may drain the bar to empty. Starting one takes
	// a real reserve: one tick of regen at 0 is enough to satisfy `> 0`, and
	// holding Shift would otherwise sprint forever on an empty bar.
	wants_sprint := input.sprint && moving && char.on_ground && !aim_locking
	sprinting := false
	if wants_sprint {
		if char.sprint_active {
			sprinting = char.stamina > 0
		} else {
			sprinting = char.stamina >= STAMINA_SPRINT_MIN
		}
	}
	char.sprint_active = sprinting

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
	speed *= carry_speed_mult(char.carrying_ore)
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
	pace := len_vec3(vel_xy)
	if char.on_ground {
		// Just landed and still flying: coast through the hop window rather
		// than skid, so a late hop has something left to carry.
		coasting := char.hop.ground_ticks <= HOP_LATE_TICKS && pace > HOP_RUN_SPEED
		if !coasting {
			k := min(CHARACTER_GROUND_ACCEL * dt, 1.0)
			vel_xy += (wish - vel_xy) * k
			if !moving && len2_vec3(vel_xy) < 0.02 * 0.02 {
				vel_xy = {}
			}
		}
	} else if moving {
		wish_pace := len_vec3(wish)
		heading := pace > 1e-3 ? vel_xy * (1.0 / pace) : vec3{}
		wish_dir := wish_pace > 1e-3 ? wish * (1.0 / wish_pace) : vec3{}
		if pace > wish_pace && dot_vec3(heading, wish_dir) > -0.25 {
			// Faster than legs could go: the air steers the heading and
			// keeps the pace. Straight back is the only way to shed it.
			k := min(CHARACTER_AIR_TURN * dt, 1.0)
			bent := norm_vec3(heading + (wish_dir - heading) * k)
			vel_xy = bent * pace
		} else {
			k := min(CHARACTER_AIR_ACCEL * dt, 1.0)
			vel_xy += (wish - vel_xy) * k
		}
	}
	vel_xy = clamp_horizontal(vel_xy, CHARACTER_MAX_SPEED)

	// Move with axis-separated sliding against the world, swept in short
	// steps so a fast body meets a wall where the wall is.
	step := vel_xy * dt
	sweeps := max(int(math.ceil(len_vec3(step) / CHARACTER_SWEEP_STEP_M)), 1)
	sub := step * (1.0 / f32(sweeps))
	for _ in 0..<sweeps {
		if sub.x == 0 && sub.y == 0 {
			break
		}
		try := char.pos + sub
		if !simulate_character_blocked(try) {
			char.pos = try
			continue
		}
		try = char.pos
		try.x += sub.x
		if !simulate_character_blocked(try) {
			char.pos.x = try.x
		} else {
			vel_xy.x = 0
			sub.x = 0
		}
		try = char.pos
		try.y += sub.y
		if !simulate_character_blocked(try) {
			char.pos.y = try.y
		} else {
			vel_xy.y = 0
			sub.y = 0
		}
	}

	char.vel.x = vel_xy.x
	char.vel.y = vel_xy.y
}

@(private)
clamp_horizontal :: proc(v: vec3, limit: f32) -> vec3 {
	l2 := v.x * v.x + v.y * v.y
	if l2 <= limit * limit {
		return v
	}
	k := limit / math.sqrt(l2)
	return {v.x * k, v.y * k, v.z}
}

@(private)
simulate_character_move_z :: proc(char: ^Character_State, input: Input_State, dt: f32) {
	// Walked off a crate or a tower: nothing under the feet any more.
	if char.on_ground && char.pos.z > WORLD_FLOOR_Z + 0.001 {
		below := char.pos - vec3{0, 0, CHARACTER_GROUND_PROBE_M}
		if !simulate_character_blocked(below) {
			char.on_ground = false
		}
	}

	on_floor := char.pos.z <= WORLD_FLOOR_Z + 0.001
	if on_floor && char.vel.z <= 0 && !char.on_ground {
		char.pos.z = WORLD_FLOOR_Z
		character_touchdown(char)
	}

	if !char.on_ground {
		char.vel.z -= CHARACTER_GRAVITY * dt
		try := char.pos
		try.z += char.vel.z * dt

		if try.z <= WORLD_FLOOR_Z {
			char.pos.z = WORLD_FLOOR_Z
			character_touchdown(char)
		} else if simulate_character_blocked(try) {
			// Hit something above, or came down onto a crate or a tower. A
			// fast fall stops a whole tick's drop short of the surface, so
			// close the gap before standing on it; otherwise the probe above
			// would find air under the feet and drop them again.
			if try.z < char.pos.z {
				gap := char.pos.z - try.z
				for _ in 0..<5 {
					gap *= 0.5
					down := char.pos - vec3{0, 0, gap}
					if !simulate_character_blocked(down) {
						char.pos = down
					}
				}
				character_touchdown(char)
			}
			char.vel.z = 0
		} else {
			char.pos.z = try.z
		}
	}

	// Jump after the fall has been resolved, so a hop leaves on the very tick
	// the feet arrive and never grips. A buffered press jumps then even if the
	// key has already come up.
	if char.on_ground && (input.jump || char.hop.buffer_ticks > 0) {
		timed := char.hop.buffer_ticks > 0 && char.hop.ground_ticks <= HOP_LATE_TICKS
		if !timed {
			vel_xy := clamp_horizontal(vec3{char.vel.x, char.vel.y, 0}, HOP_RUN_SPEED)
			char.vel.x = vel_xy.x
			char.vel.y = vel_xy.y
		}
		char.on_ground = false
		char.vel.z = CHARACTER_JUMP_VELOCITY
		char.hop.buffer_ticks = 0
		char.hop.ground_ticks = 0
	} else if char.on_ground && char.hop.ground_ticks < HOP_GROUND_TICKS_MAX {
		char.hop.ground_ticks += 1
	}
}

// Feet meet something solid. Records what they hit it with before the fall is
// stopped, so the server can charge for a hard landing.
@(private)
character_touchdown :: proc(char: ^Character_State) {
	char.landing = Landing{
		fall_speed = max(-char.vel.z, 0),
		run_speed  = math.sqrt(char.vel.x * char.vel.x + char.vel.y * char.vel.y),
	}
	char.vel.z = 0
	char.on_ground = true
	char.hop.ground_ticks = 0
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

// A blast throws a body along `dir` in all three axes: one under the feet
// throws it up, one beside it throws it sideways. However flat or downward the
// shove, at least BLAST_MIN_LIFT of it goes upward, so the feet leave the floor
// and ground friction cannot swallow the throw on the next tick. Lift adds to a
// rise already under way, which is what makes jumping into your own orb go
// higher than standing on it.
BLAST_MIN_LIFT :: f32(0.35)

character_apply_blast :: proc(char: ^Character_State, dir: vec3, strength: f32) {
	if char.dead || strength <= 0 {
		return
	}
	d := norm_vec3(dir)
	if len2_vec3(d) < 0.5 {
		d = {0, 0, 1}
	}
	vel_xy := clamp_horizontal(vec3{char.vel.x + d.x * strength, char.vel.y + d.y * strength, 0}, CHARACTER_MAX_SPEED)
	char.vel.x = vel_xy.x
	char.vel.y = vel_xy.y
	char.vel.z = min(max(char.vel.z, 0) + max(d.z, BLAST_MIN_LIFT) * strength, CHARACTER_MAX_RISE)
	character_leave_ground(char)
}

// Up off the floor now, so the next tick flies rather than grips.
character_leave_ground :: proc(char: ^Character_State) {
	char.on_ground = false
	char.hop.ground_ticks = 0
	if char.pos.z <= WORLD_FLOOR_Z {
		char.pos.z = WORLD_FLOOR_Z + 0.01
	}
}
