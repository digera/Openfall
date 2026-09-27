package main

// Cloth simulation for the wisps' robes. Pure CPU state, independent of how
// the robe is drawn.

import "core:math"

// A wisp's robe, one per remote entity. Keyed by entity id rather than by the
// distance-sorted wisp slot, which reshuffles every frame. The cloth is a
// two-link chain: a waist ring hangs from the shoulders on a short rope and the
// hem ring hangs from the waist on a longer one. Each link is a damped pendulum
// pushed back by drag from travel, so motion arrives at the waist first and
// reaches the hem a beat later: the robe bends and flows rather than tilting
// as one piece. The pleat pattern's yaw lags the body's so a turn twists the
// cloth. The shader (robe_trace) draws the surface through these two points.
//
// Simulated in the wearer's frame: the rings are offsets from what they hang
// from, and the wearer's acceleration enters as an inertial force. At a steady
// walk the cloth then sits exactly where the drag puts it whatever the frame
// rate, a stop throws the body's momentum into the hem as a forward swing, and
// a Blink moves the cloth with the body without disturbing it.
Robe_State :: struct {
	waist_off: vec3,   // waist ring from the shoulder ring
	waist_vel: vec3,   // in the wearer's frame
	hem_off:   vec3,   // hem ring from the waist ring
	hem_vel:   vec3,
	prev_vel:  vec3,   // wearer velocity last frame, for the inertial force
	hem_yaw:   f32,    // the yaw the pleats have caught up to
	flutter:   f32,    // 0..1 smoothed travel speed; drives the hem ripple
	settled:   bool,   // false until the entity has been drawn once
	death_t:   f32,    // seconds since the wisp died, 0 while it lives, held at DEATH_ANIM_SEC once it is gone
	was_dead:  bool,   // what death_t was last advanced against, to catch the death and the way back
	death_hp:  f32,    // the size it was the last frame it lived; it swells from the body everyone just saw
}

ROBE_SHOULDER_Z_M   :: f32(0.45)   // shoulder ring above the wisp centre, at full size; matches the shader
ROBE_WAIST_ROPE_M   :: f32(0.55)   // shoulder ring to waist ring, at full size
ROBE_HEM_ROPE_M     :: f32(0.70)   // waist ring to hem ring
ROBE_WAIST_DRAG_S   :: f32(0.015)  // metres of trail per m/s of travel; the cloth is snug at the waist
ROBE_WAIST_TRAIL_M  :: f32(0.08)
ROBE_HEM_DRAG_S     :: f32(0.045)  // and loose at the hem
ROBE_HEM_TRAIL_M    :: f32(0.26)
ROBE_WAIST_SWING_M  :: f32(0.09)   // how far each ring may swing out before the cloth meets the body
ROBE_HEM_SWING_M    :: f32(0.28)
ROBE_WAIST_SPRING   :: f32(90.0)   // stiff and quick: follows the body closely
ROBE_WAIST_DAMPING  :: f32(10.0)
ROBE_HEM_SPRING     :: f32(40.0)   // soft: swings at ~1 Hz, one visible overshoot
ROBE_HEM_DAMPING    :: f32(5.0)
ROBE_JOLT_MAX_MPS   :: f32(8.0)    // most the wearer's velocity may change in one frame, for the cloth's purposes
ROBE_SIM_DT_MIN     :: f32(1.0 / 1000.0)
ROBE_SIM_DT_MAX     :: f32(1.0 / 30.0)

// A killed wisp swells where it fell and bursts into a flash the colour of its
// team. The phases are timed here and read by the shader off robe_fx[i].y, so
// every client that can see it sees the same swell and the same burst; these
// match DEATH_SWELL_SEC and DEATH_POP_SEC in the shader.
DEATH_SWELL_SEC     :: f32(0.40)   // how long the robe fills before it goes
DEATH_POP_SEC       :: f32(0.12)   // how long the flash it bursts into lasts
DEATH_ANIM_SEC      :: DEATH_SWELL_SEC + DEATH_POP_SEC

// Drag from moving through the air, pushing the cloth back against travel, up
// to what the rope allows.
@(private = "file")
robe_drag :: proc(vel: vec3, per_mps, limit: f32) -> vec3 {
	drag := vec3{-vel.x, -vel.y, 0} * per_mps
	if l := len_vec3(drag); l > limit {
		drag = drag * (limit / l)
	}
	return drag
}

// One link of the chain: a ring on a rope of fixed length below what it hangs
// from, sprung toward `target`, pushed by the `inertial` force of its frame
// accelerating, and allowed to swing out at most `swing` sideways before the
// cloth meets the body. Position-based: integrate, project onto the
// constraints, then take the velocity from the displacement that actually
// happened, so being stopped by the rope or the body shows up as momentum.
// Returns the ring's acceleration, which is the inertial force felt by
// whatever hangs from it.
@(private = "file")
robe_link :: proc(off, vel: ^vec3, target, inertial: vec3, rope, swing, spring, damping, dt: f32) -> (acc: vec3) {
	prev_off := off^
	prev_vel := vel^
	vel^ += ((target - off^) * spring - vel^ * damping + inertial) * dt
	d := off^ + vel^ * dt

	lateral := math.sqrt(d.x * d.x + d.y * d.y)
	if lateral > swing {
		d.x *= swing / lateral
		d.y *= swing / lateral
		lateral = swing
	}
	// Hanging below at rope length: the ring lifts as it swings out
	d.z = -math.sqrt(max(rope * rope - lateral * lateral, 0))
	off^ = d
	vel^ = (d - prev_off) * (1.0 / dt)
	return (vel^ - prev_vel) * (1.0 / dt)
}

// One frame of cloth motion. `vel` is the wearer's velocity (server-
// authoritative, interpolated), `yaw` its facing, `scale` the wisp's size (it
// shrinks as it is hurt), `dead` whether the server says the wisp is down.
robe_simulate :: proc(st: ^Robe_State, vel: vec3, yaw, scale, world_t, phase, dt: f32, dead: bool) {
	// A wisp that dies swells and bursts where it fell, and respawns somewhere
	// else, so the cloth it comes back in starts at rest rather than carrying on
	// from the balloon it went out as.
	if dead != st.was_dead {
		st.was_dead = dead
		st.death_t = 0
		if !dead {
			st.settled = false
		}
	}

	waist_rope := ROBE_WAIST_ROPE_M * scale
	hem_rope := ROBE_HEM_ROPE_M * scale
	if !st.settled {
		st.waist_off = {0, 0, -waist_rope}
		st.waist_vel = {}
		st.hem_off = {0, 0, -hem_rope}
		st.hem_vel = {}
		st.prev_vel = vel
		st.hem_yaw = yaw
		st.flutter = 0
		st.settled = true
		// A wisp already down the first time it is simulated burst while this
		// client was not watching it; it stays gone rather than replaying a
		// death nobody saw.
		st.was_dead = dead
		st.death_t = dead ? DEATH_ANIM_SEC : 0
	}

	if dead {
		st.death_t = min(st.death_t + dt, DEATH_ANIM_SEC)
	}

	// The wearer speeding up throws the cloth back; stopping throws it forward.
	// A snapshot that teleports the velocity is taken as a hard jolt, not a
	// launch.
	jolt := st.prev_vel - vel
	if l := len_vec3(jolt); l > ROBE_JOLT_MAX_MPS {
		jolt = jolt * (ROBE_JOLT_MAX_MPS / l)
	}
	inertial := jolt * (1.0 / dt)
	st.prev_vel = vel

	waist_target := vec3{0, 0, -waist_rope} + robe_drag(vel, ROBE_WAIST_DRAG_S, ROBE_WAIST_TRAIL_M)
	waist_acc := robe_link(&st.waist_off, &st.waist_vel, waist_target, inertial, waist_rope, ROBE_WAIST_SWING_M * scale,
		ROBE_WAIST_SPRING, ROBE_WAIST_DAMPING, dt)

	// The hem hangs from the waist and feels the waist's acceleration too, so
	// motion works its way down the cloth a beat at a time.
	hem_target := vec3{0, 0, -hem_rope} + robe_drag(vel, ROBE_HEM_DRAG_S, ROBE_HEM_TRAIL_M)
	// A slow wander so a wisp standing still is never quite still.
	hem_target.x += 0.03 * math.sin(world_t * 0.9 + phase)
	hem_target.y += 0.03 * math.cos(world_t * 0.7 + phase * 1.3)
	robe_link(&st.hem_off, &st.hem_vel, hem_target, inertial - waist_acc, hem_rope, ROBE_HEM_SWING_M * scale,
		ROBE_HEM_SPRING, ROBE_HEM_DAMPING, dt)

	// Pleats catch up with the body's facing a beat late
	st.hem_yaw = wrap_angle(st.hem_yaw + wrap_angle(yaw - st.hem_yaw) * min(dt * 7.0, 1.0))
	speed := math.sqrt(vel.x * vel.x + vel.y * vel.y)
	st.flutter += (clampf(speed / CHARACTER_WALK_SPEED, 0, 1) - st.flutter) * min(dt * 5.0, 1.0)
}
