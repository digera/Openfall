package main

// Cloth simulation for the wisps' robes. Pure CPU state, independent of how
// the robe is drawn.
//
// The cloth physics are adapted from the cloak in oil-paint by blendi
// (https://patch.gg/blendi/oil-paint, src/figure/cloak.js), used under the
// MIT License:
//
//   Copyright (c) blendi
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the
//   following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//   USE OR OTHER DEALINGS IN THE SOFTWARE.

import "core:math"

// A wisp's robe, one per remote entity. Keyed by entity id rather than by the
// distance-sorted wisp slot, which reshuffles every frame.
//
// The robe is a real piece of cloth: a tube of points round the body, ROBE_COLS
// round and ROBE_ROWS down, held together by threads of fixed length, the top
// row sewn to the shoulder ring. It hangs under its own weight and is pushed by
// the air it moves through, so travel lifts it out behind, a stop swings it
// forward past the body, and a turn wrings it because the shoulders come round
// before the hem does. Threads pull when stretched and barely push when slack,
// so the cloth folds rather than springs. A core of light it cannot pass
// through stands in for a body, and the floor stops the hem.
//
// It is stepped in world space at a fixed ROBE_STEP_SEC whatever the frame
// rate, each step sewing the collar on where the shoulders were at that step's
// moment, so the cloth moves the same at 30 frames a second as at 240. A turn
// comes round through the facing rather than across the ring, so a flick
// sweeps the collar round instead of dragging it through the middle. A Blink
// carries the cloth with the body rather than flinging it eleven metres.
//
// The shader (robe_trace) draws the robe through rings, not the grid, so what
// leaves here is what it reads: the centres of the waist and hem rows, how far
// the hem has been wrung round, and how hard the air is pulling at it.
Robe_State :: struct {
	waist_off:   vec3,   // waist ring from the shoulder ring
	hem_off:     vec3,   // hem ring from the waist ring
	hem_yaw:     f32,    // the yaw the pleats have caught up to
	flutter:     f32,    // 0..1 smoothed air speed at the hem; drives the hem ripple
	settled:     bool,   // false until the entity has been drawn once
	death_t:     f32,    // seconds since the wisp died, 0 while it lives, held at DEATH_ANIM_SEC once it is gone
	was_dead:    bool,   // what death_t was last advanced against, to catch the death and the way back
	death_hp:    f32,    // the size it was the last frame it lived; it swells from the body everyone just saw

	p:           [ROBE_POINTS]vec3,   // the cloth, row-major from the shoulder row down
	prev:        [ROBE_POINTS]vec3,   // where each point was a step ago; Verlet keeps velocity as this difference
	shoulder:    vec3,   // the shoulder ring at the end of the last frame, swept from across the next
	travel:      vec3,   // how far the shoulders went in that frame
	yaw:         f32,
	scale:       f32,
	collar:      vec3,   // where the shoulder row was sewn on at the last step, which the rings are measured from
	collar_yaw:  f32,
	floor_z:     f32,    // what the hem lands on
	left:        f32,    // time not yet stepped
	cloth_t:     f32,    // the cloth's own clock, for the ripples the air sends down it
}

ROBE_COLS         :: 10   // round the body
ROBE_ROWS         :: 6    // shoulder row (sewn on) to hem row
ROBE_WAIST_ROW    :: 2
ROBE_POINTS       :: ROBE_COLS * ROBE_ROWS

ROBE_SHOULDER_Z_M   :: f32(0.45)   // shoulder ring above the wisp centre, at full size; matches the shader
ROBE_WAIST_DROP_M   :: f32(0.55)   // shoulder ring to waist ring, at full size
ROBE_HEM_DROP_M     :: f32(0.70)   // waist ring to hem ring
ROBE_R_SHOULDER_M   :: f32(0.24)   // side-to-side ring radii, as the shader draws them
ROBE_R_WAIST_M      :: f32(0.37)
ROBE_R_HEM_M        :: f32(0.55)
ROBE_DEPTH          :: f32(0.82)   // front-to-back over side-to-side, as the shader draws it

ROBE_STEP_SEC       :: f32(1.0 / 120.0)
ROBE_MAX_STEPS      :: 6       // per frame; a longer hitch drops the rest rather than catching up
ROBE_ITERATIONS     :: 4       // thread passes per step
ROBE_KEEP           :: f32(0.992)  // velocity a point keeps per step; the rest is lost to the cloth itself
ROBE_GRAVITY        :: f32(9.8)
ROBE_AIR_DRAG       :: f32(1.45)   // 1/s: how hard the air drags the cloth along with it, across
ROBE_AIR_DRAG_UP    :: f32(0.5)    // and up and down, where the cloth shows the air its edge
ROBE_RUB            :: f32(2.5)    // 1/s: cloth moving against the body loses it to rubbing, so a swing settles in one overshoot
ROBE_AIR_FLUTTER    :: f32(0.45)   // ripples per m/s of air, sent down the cloth and growing to the hem
ROBE_SLACK          :: f32(0.12)   // how hard a slack thread pushes, against a taut one pulling
ROBE_BREEZE_MPS     :: f32(0.4)    // the still air of the arena moves a little, so a wisp at rest is never quite still

// The core of light inside the robe, the body the cloth lies on: a capsule
// about the wisp centre, x scale. Narrower than the shoulder ring so the collar
// is never inside it.
ROBE_CORE_LOW_M     :: f32(-0.30)
ROBE_CORE_HIGH_M    :: f32(0.30)
ROBE_CORE_R_M       :: f32(0.20)
ROBE_THICKNESS_M    :: f32(0.022)  // the cloth's own, kept off the core and the floor

// The shader traces the robe inside a sphere of 1.3 x scale about the wisp
// centre, so the rings it is given are kept where the drawn bell still fits.
ROBE_WAIST_REACH_M  :: f32(0.16)   // waist ring sideways from below the shoulders
ROBE_HEM_REACH_M    :: f32(0.48)   // hem ring sideways from below the shoulders
ROBE_WAIST_RISE_M   :: f32(0.25)   // least the waist ring stays below the shoulders
ROBE_HEM_RISE_M     :: f32(0.30)   // least the hem ring stays below the waist

ROBE_TELEPORT_M     :: f32(2.0)    // a shoulder move longer than this in a frame is a Blink, not travel
ROBE_TELEPORT_MPS   :: f32(40.0)   // nor faster than this: past CHARACTER_MAX_SPEED with a fall on top
ROBE_SIM_DT_MAX     :: f32(0.05)   // longest frame the cloth takes whole; a hitch past it is not caught up

// A killed wisp swells where it fell and bursts into a flash the colour of its
// team. The phases are timed here and read by the shader off robe_fx[i].y, so
// every client that can see it sees the same swell and the same burst; these
// match DEATH_SWELL_SEC and DEATH_POP_SEC in the shader.
DEATH_SWELL_SEC     :: f32(0.40)   // how long the robe fills before it goes
DEATH_POP_SEC       :: f32(0.12)   // how long the flash it bursts into lasts
DEATH_ANIM_SEC      :: DEATH_SWELL_SEC + DEATH_POP_SEC

// A thread between two points of the cloth, its length as the robe was cut at
// full size, and how stiff it is: 1 along the weave, less across it and less
// again for the long threads that keep the cloth from creasing too sharply.
@(private = "file")
Robe_Link :: struct {
	a, b:   i32,
	rest:   f32,
	stiff:  f32,
	wa, wb: f32,   // each end's share of the correction: none for a sewn-on point, all of it opposite one
}

// Round and down, two shears and two bends per point, less
// the threads that would run between two points of the sewn-on shoulder row.
@(private = "file")
ROBE_MAX_LINKS :: ROBE_POINTS * 6

@(private = "file")
robe_cut: struct {
	rest:      [ROBE_POINTS]vec3,   // body frame (x forward, y left, z up) from the shoulder ring centre, full size
	links:     [ROBE_MAX_LINKS]Robe_Link,
	n_links:   int,
	ready:     bool,
}

// The robe as it was cut: a bell from the shoulder ring through the waist ring
// to the hem, oval like the drawn robe. Thread lengths come from this.
@(private = "file")
robe_cut_cloth :: proc() {
	if robe_cut.ready {
		return
	}
	for j in 0..<ROBE_ROWS {
		z, r: f32
		if j <= ROBE_WAIST_ROW {
			f := f32(j) / f32(ROBE_WAIST_ROW)
			z = -ROBE_WAIST_DROP_M * f
			r = lerpf(ROBE_R_SHOULDER_M, ROBE_R_WAIST_M, f)
		} else {
			f := f32(j - ROBE_WAIST_ROW) / f32(ROBE_ROWS - 1 - ROBE_WAIST_ROW)
			z = -ROBE_WAIST_DROP_M - ROBE_HEM_DROP_M * f
			r = lerpf(ROBE_R_WAIST_M, ROBE_R_HEM_M, f)
		}
		for i in 0..<ROBE_COLS {
			a := f32(i) * (2 * math.PI / f32(ROBE_COLS))
			robe_cut.rest[i + j * ROBE_COLS] = {math.cos(a) * r * ROBE_DEPTH, math.sin(a) * r, z}
		}
	}
	link :: proc(a, b: int, stiff: f32) {
		// Two points of the shoulder row are both sewn on; nothing to hold
		if a < ROBE_COLS && b < ROBE_COLS {
			return
		}
		pa, pb := a < ROBE_COLS, b < ROBE_COLS
		robe_cut.links[robe_cut.n_links] = {
			a     = i32(a),
			b     = i32(b),
			rest  = len_vec3(robe_cut.rest[b] - robe_cut.rest[a]),
			stiff = stiff,
			wa    = pa ? 0 : (pb ? 1 : 0.5),
			wb    = pb ? 0 : (pa ? 1 : 0.5),
		}
		robe_cut.n_links += 1
	}
	for j in 0..<ROBE_ROWS {
		for i in 0..<ROBE_COLS {
			k := i + j * ROBE_COLS
			round1 := (i + 1) % ROBE_COLS + j * ROBE_COLS
			round2 := (i + 2) % ROBE_COLS + j * ROBE_COLS
			link(k, round1, 1)
			link(k, round2, 0.25)
			if j + 1 < ROBE_ROWS {
				link(k, k + ROBE_COLS, 1)
				link(k, round1 + ROBE_COLS, 0.6)
				link(round1, k + ROBE_COLS, 0.6)
			}
			if j + 2 < ROBE_ROWS {
				link(k, k + 2 * ROBE_COLS, 0.25)
			}
		}
	}
	robe_cut.ready = true
}

// The shoulder ring's point for column i, as worn: centre, facing and size.
@(private = "file")
robe_collar :: proc(i: int, shoulder: vec3, yaw, scale: f32) -> vec3 {
	r := robe_cut.rest[i]
	c, s := math.cos(yaw), math.sin(yaw)
	return shoulder + vec3{c * r.x - s * r.y, s * r.x + c * r.y, r.z} * scale
}

// The air round the robe: the arena's slow breeze, wandering in direction, a little out
// of step from one wisp to the next.
@(private = "file")
robe_air :: proc(t, phase: f32) -> vec3 {
	a := 0.9 * math.sin(t * 0.13 + phase) + 0.6 * math.sin(t * 0.31 + phase * 1.7)
	gust := 0.6 + 0.4 * math.sin(t * 0.9 + phase * 2.3)
	return vec3{math.cos(a), math.sin(a), 0} * (ROBE_BREEZE_MPS * gust)
}

// Hang the cloth at rest from the shoulders, a little flared, as if just put on.
@(private = "file")
robe_hang :: proc(st: ^Robe_State, shoulder: vec3, yaw, scale, floor_z: f32) {
	c, s := math.cos(yaw), math.sin(yaw)
	for k in 0..<ROBE_POINTS {
		r := robe_cut.rest[k]
		st.p[k] = shoulder + vec3{c * r.x - s * r.y, s * r.x + c * r.y, r.z} * scale
		st.p[k].z = max(st.p[k].z, floor_z + ROBE_THICKNESS_M)
	}
	st.prev = st.p
	st.shoulder = shoulder
	st.collar = shoulder
	st.collar_yaw = yaw
	st.travel = {}
	st.yaw = yaw
	st.scale = scale
	st.floor_z = floor_z
	st.left = 0
}

// Outward normals of the cloth, from the neighbours round and down.
@(private = "file")
robe_normals :: proc(st: ^Robe_State, n: ^[ROBE_POINTS]vec3) {
	for j in 0..<ROBE_ROWS {
		up := max(j - 1, 0) * ROBE_COLS
		dn := min(j + 1, ROBE_ROWS - 1) * ROBE_COLS
		for i in 0..<ROBE_COLS {
			l := (i + ROBE_COLS - 1) % ROBE_COLS + j * ROBE_COLS
			r := (i + 1) % ROBE_COLS + j * ROBE_COLS
			across := st.p[r] - st.p[l]
			down := st.p[dn + i] - st.p[up + i]
			n[i + j * ROBE_COLS] = norm_vec3(cross_vec3(down, across))
		}
	}
}

// Keep the cloth off the core and out of the floor.
@(private = "file")
robe_collide :: proc(st: ^Robe_State, centre: vec3, scale: f32) #no_bounds_check {
	lo := centre.z + ROBE_CORE_LOW_M * scale
	hi := centre.z + ROBE_CORE_HIGH_M * scale
	r := ROBE_CORE_R_M * scale + ROBE_THICKNESS_M
	ground := st.floor_z + ROBE_THICKNESS_M
	for k in ROBE_COLS..<ROBE_POINTS {
		q := &st.p[k]
		axis := vec3{centre.x, centre.y, clampf(q.z, lo, hi)}
		d := q^ - axis
		d2 := len2_vec3(d)
		if d2 < r * r && d2 > 1e-10 {
			dl := math.sqrt(d2)
			q^ += d * ((r - dl) / dl)
		}
		if q.z < ground {
			q.z = ground
		}
	}
}

// One step of ROBE_STEP_SEC with the shoulder ring at `shoulder`.
// `normals` are the cloth's at the start of the frame: the ripples they carry
// are slow beside a step, and finding them is a good part of a step's cost.
@(private = "file")
robe_step :: proc(st: ^Robe_State, normals: ^[ROBE_POINTS]vec3, shoulder, carry: vec3, yaw, scale, phase: f32) #no_bounds_check {
	st.cloth_t += ROBE_STEP_SEC
	wind := robe_air(st.cloth_t, phase)
	h2 := ROBE_STEP_SEC * ROBE_STEP_SEC

	for j in 1..<ROBE_ROWS {
		hang := f32(j) / f32(ROBE_ROWS - 1)
		for i in 0..<ROBE_COLS {
			k := i + j * ROBE_COLS
			v := (st.p[k] - st.prev[k]) * ROBE_KEEP
			v += (carry - v) * (ROBE_RUB * ROBE_STEP_SEC)
			// The air it meets: the wind less its own speed, felt across the
			// face of the cloth. It drags the cloth along with it and sends
			// ripples down it that grow toward the hem.
			rel := wind - v * (1.0 / ROBE_STEP_SEC)
			speed := len_vec3(rel)
			flutter := math.sin(st.cloth_t * 11 - f32(j) * 0.85 + f32(i) * 1.3 + phase) * ROBE_AIR_FLUTTER * speed * hang
			acc := normals[k] * flutter + vec3{rel.x * ROBE_AIR_DRAG, rel.y * ROBE_AIR_DRAG, rel.z * ROBE_AIR_DRAG_UP - ROBE_GRAVITY}
			st.prev[k] = st.p[k]
			st.p[k] += v + acc * h2
		}
	}
	for i in 0..<ROBE_COLS {
		st.p[i] = robe_collar(i, shoulder, yaw, scale)
		st.prev[i] = st.p[i]
	}

	centre := shoulder - vec3{0, 0, ROBE_SHOULDER_Z_M * scale}
	for it in 0..<ROBE_ITERATIONS {
		// Written out in scalars: this loop is most of the cloth's cost, and a
		// debug build does not inline the vector helpers.
		for &l in robe_cut.links[:robe_cut.n_links] {
			a, b := &st.p[l.a], &st.p[l.b]
			dx, dy, dz := b.x - a.x, b.y - a.y, b.z - a.z
			dl := max(math.sqrt(dx * dx + dy * dy + dz * dz), 1e-6)
			rest := l.rest * scale
			// Threads pull when stretched and barely push when slack: cloth
			// folds, it doesn't spring
			k := (dl - rest) / dl * (dl > rest ? l.stiff : l.stiff * ROBE_SLACK)
			ka, kb := k * l.wa, k * l.wb
			a.x += dx * ka; a.y += dy * ka; a.z += dz * ka
			b.x -= dx * kb; b.y -= dy * kb; b.z -= dz * kb
		}
		if it % 2 == 0 {
			robe_collide(st, centre, scale)
		}
	}
	robe_collide(st, centre, scale)
}

// The centre of row j.
@(private = "file")
robe_row_centre :: proc(st: ^Robe_State, j: int) -> vec3 {
	sum: vec3
	for i in 0..<ROBE_COLS {
		sum += st.p[i + j * ROBE_COLS]
	}
	return sum * (1.0 / f32(ROBE_COLS))
}

// Keep a ring sideways within `reach` of below the shoulders.
@(private = "file")
robe_reach :: proc(off: vec3, reach: f32) -> vec3 {
	o := off
	if l := math.sqrt(o.x * o.x + o.y * o.y); l > reach {
		o.x *= reach / l
		o.y *= reach / l
	}
	return o
}

// One frame of cloth motion. `shoulder` is the shoulder ring centre as drawn
// (bob and all), `yaw` the wearer's facing, `scale` the wisp's size (it shrinks
// as it is hurt), `feet_z` and `on_ground` where the wearer stands, `dead`
// whether the server says the wisp is down.
robe_simulate :: proc(st: ^Robe_State, shoulder: vec3, yaw, scale, feet_z: f32, on_ground: bool, phase, dt: f32, dead: bool) {
	robe_cut_cloth()

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

	if !st.settled {
		robe_hang(st, shoulder, yaw, scale, feet_z)
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

	// What the hem lands on: where the feet are while they are down, and no
	// higher than they have fallen to while they are not.
	st.floor_z = on_ground ? feet_z : min(st.floor_z, feet_z)

	// A Blink, or a snapshot that jumps, takes the cloth along as it hangs: it
	// is the same robe somewhere else, not one hauled eleven metres in a frame.
	// What the wearer would have travelled anyway is left for the steps to
	// sweep, so the cloth keeps its trail through the jump.
	jump := shoulder - st.shoulder
	frame_dt := min(dt, ROBE_SIM_DT_MAX)
	if l := len_vec3(jump); l > ROBE_TELEPORT_M || l > ROBE_TELEPORT_MPS * max(frame_dt, ROBE_STEP_SEC) {
		carry := jump - st.travel
		for k in 0..<ROBE_POINTS {
			st.p[k] += carry
			st.prev[k] += carry
		}
		st.shoulder += carry
		st.collar += carry
	}

	// Each step takes the shoulders where they were at that step's own moment
	// in the frame, so the collar moves the same distance every step whether a
	// frame holds one step, none or five.
	behind := st.left
	st.left += frame_dt
	steps := int(st.left / ROBE_STEP_SEC)
	capped := steps > ROBE_MAX_STEPS
	if capped {
		steps = ROBE_MAX_STEPS
		st.left = 0
	} else {
		st.left -= f32(steps) * ROBE_STEP_SEC
	}
	from_shoulder, from_yaw, from_scale := st.shoulder, st.yaw, st.scale
	turn := wrap_angle(yaw - from_yaw)
	normals: [ROBE_POINTS]vec3
	if steps > 0 {
		robe_normals(st, &normals)
	}
	per_sec := 1.0 / max(frame_dt, 1e-6)
	carry := (shoulder - from_shoulder) * (capped ? 1.0 / f32(steps) : ROBE_STEP_SEC * per_sec)
	for s in 0..<steps {
		u := capped ? f32(s + 1) / f32(steps) : clampf((f32(s + 1) * ROBE_STEP_SEC - behind) * per_sec, 0, 1)
		st.collar = lerpv3(from_shoulder, shoulder, u)
		st.collar_yaw = from_yaw + turn * u
		robe_step(st, &normals, st.collar, carry, st.collar_yaw, lerpf(from_scale, scale, u), phase)
	}
	st.travel = shoulder - from_shoulder
	st.shoulder = shoulder
	st.yaw = yaw
	st.scale = scale

	// What the shader draws through: the centres of the waist and hem rows,
	// kept where the drawn bell fits. They are measured from the shoulders the
	// cloth was last stepped to, not this frame's: on a fast display some
	// frames take no step, and the robe must not judder against the body then.
	waist := robe_row_centre(st, ROBE_WAIST_ROW) - st.collar
	hem := robe_row_centre(st, ROBE_ROWS - 1) - st.collar
	waist = robe_reach(waist, ROBE_WAIST_REACH_M * scale)
	waist.z = min(waist.z, -ROBE_WAIST_RISE_M * scale)
	hem = robe_reach(hem, ROBE_HEM_REACH_M * scale)
	hem.z = min(hem.z, waist.z - ROBE_HEM_RISE_M * scale)
	st.waist_off = waist
	st.hem_off = hem - waist

	// How far the hem has been wrung round the body: each hem point's angle
	// about the hem's centre against where it was cut to hang, averaged on the
	// circle so a half-turn the wrong way cancels rather than spins.
	hc := st.collar + hem
	sx, sy: f32
	for i in 0..<ROBE_COLS {
		r := robe_cut.rest[i + (ROBE_ROWS - 1) * ROBE_COLS]
		q := st.p[i + (ROBE_ROWS - 1) * ROBE_COLS] - hc
		twist := wrap_angle(math.atan2(q.y, q.x) - (st.collar_yaw + math.atan2(r.y, r.x)))
		sx += math.cos(twist)
		sy += math.sin(twist)
	}
	st.hem_yaw = wrap_angle(st.collar_yaw + math.atan2(sy, sx))

	// The air the hem feels, from the cloth's own speed; the shader ripples and
	// cuts the hem harder the more there is.
	hem_speed: f32
	for i in 0..<ROBE_COLS {
		k := i + (ROBE_ROWS - 1) * ROBE_COLS
		hem_speed += len_vec3(st.p[k] - st.prev[k])
	}
	hem_speed *= 1.0 / (f32(ROBE_COLS) * ROBE_STEP_SEC)
	st.flutter += (clampf(hem_speed / CHARACTER_WALK_SPEED, 0, 1) - st.flutter) * min(dt * 5.0, 1.0)
}
