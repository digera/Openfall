package main

import "core:fmt"
import "core:math"
import "core:math/rand"

// Server-side bots. Each team spawns BOTS_PER_TEAM bots (default 1),
// independent of how many humans have joined. Override at runtime with the
// BOTS_PER_TEAM environment variable.
//
// Behaviour: pick an enemy ore pylon, walk there through the lane graph with
// local obstacle steering, mine it, and fight anything hostile with
// line-of-sight on the way.

BOTS_PER_TEAM :: 1
MAX_BOTS      :: TEAM_COUNT * TEAM_SIZE

Bot_Mode :: enum u8 {
	Travel,
	Mine,
}

Bot :: struct {
	active: bool,
	id:     Entity_ID,
	team:   Team_ID,

	mode:            Bot_Mode,
	objective:       int,      // pylon index
	objective_timer: f32,

	// Working a tower. Set when the bot is in range of its objective with no
	// player to fight, and it drives the aim and the beam the same way a
	// player target does.
	mining:          bool,
	mine_point:      vec3,

	target:          Entity_ID,
	target_timer:    f32,
	target_pos:      vec3,     // last known
	target_vel:      vec3,

	aim_yaw:         f32,
	aim_pitch:       f32,
	aim_err_yaw:     f32,
	aim_err_pitch:   f32,
	aim_err_timer:   f32,

	strafe_dir:      f32,
	strafe_timer:    f32,
	steer:           f32,      // -1 / 0 / +1 lateral avoidance
	steer_timer:     f32,
	orbit_phase:     f32,
	stuck_pos:       vec3,
	stuck_timer:     f32,

	cast_timer:      f32,
	next_spell:      Spell_ID, // chosen ahead of the shot so the aim can lead it
	charge_spell:    Spell_ID, // spell currently being wound up, .None when idle
	charge_time:     f32,
	beam_hold:       f32,      // how long this burst of a beam is kept on the target
	jump_timer:      f32,
	think_offset:    int,
}

BOT_DEBUG_STUCK   :: #config(NEXUS_BOT_DEBUG, false)
BOT_SIGHT_RANGE   :: f32(34.0)
BOT_TURN_RATE     :: f32(5.5)   // rad/s toward aim
BOT_AIM_NOISE     :: f32(0.055) // rad
BOT_PROBE_DIST    :: f32(1.7)

// How close a bot gets before it starts working a tower. Comfortably inside
// beam range so it does not lose the rock every time it strafes.
BOT_MINE_STANDOFF :: f32(9.0)
// Bots aim low on purpose. Chewing the base undercuts the tower and drops the
// whole top of it, which is both the efficient way to mine and the reason they
// look like they know what they are doing.
BOT_MINE_HEIGHT_FRAC :: f32(0.28)

// ---------------------------------------------------------------------------
// Roster management

bots_count_per_team :: proc(server: ^Server) -> [TEAM_COUNT]int {
	counts: [TEAM_COUNT]int
	for i in 0..<MAX_BOTS {
		if server.bots[i].active {
			idx := team_index(server.bots[i].team)
			if idx >= 0 {
				counts[idx] += 1
			}
		}
	}
	return counts
}

// Keep each team at server.bots_per_team bots, independent of human count.
bots_rebalance :: proc(server: ^Server) {
	current := bots_count_per_team(server)

	for team in TEAMS {
		ti := team_index(team)
		desired := server.bots_per_team

		// Too many: retire bots on this team (prefer dead ones)
		for current[ti] > desired {
			victim := -1
			for i in 0..<MAX_BOTS {
				b := &server.bots[i]
				if b.active && b.team == team {
					if victim < 0 || server.world.characters[b.id].dead {
						victim = i
					}
				}
			}
			if victim < 0 {
				break
			}
			entity_destroy(&server.world, server.bots[victim].id)
			server.bots[victim] = {}
			current[ti] -= 1
		}

		// Too few: spawn
		for current[ti] < desired {
			slot := -1
			for i in 0..<MAX_BOTS {
				if !server.bots[i].active {
					slot = i
					break
				}
			}
			if slot < 0 {
				break
			}
			spawn := team_spawn_position(team, 5 + current[ti])
			yaw := wrap_angle(team_angle(team) + f32(math.PI))
			id := entity_spawn(&server.world, spawn, team, yaw)
			if id == INVALID_ENTITY {
				break
			}
			player_name_set(&server.world.names[id], fmt.tprintf("Wisp-%02d", id))
			b := &server.bots[slot]
			b^ = Bot{active = true, id = id, team = team, think_offset = slot}
			bot_reset_ai(b)
			b.aim_yaw = yaw
			current[ti] += 1
		}
	}
}

bot_reset_ai :: proc(b: ^Bot) {
	b.mode = .Travel
	b.objective = -1
	b.objective_timer = 0
	b.target = INVALID_ENTITY
	b.target_timer = 0
	b.strafe_dir = rand.float32() < 0.5 ? -1 : 1
	b.strafe_timer = rand.float32_range(0.6, 1.5)
	b.steer = 0
	b.steer_timer = 0
	b.orbit_phase = rand.float32_range(0, 6.283)
	b.cast_timer = rand.float32_range(0.4, 1.2)
	b.charge_spell = .None
	b.charge_time = 0
	b.jump_timer = rand.float32_range(1, 4)
	b.aim_err_timer = 0
}

// ---------------------------------------------------------------------------
// Per-tick AI

bots_tick :: proc(server: ^Server, dt: f32) {
	if server.match.state == .Ended {
		// Celebrate: stand still
		for i in 0..<MAX_BOTS {
			b := &server.bots[i]
			if b.active {
				in_ := server.world.inputs[b.id]
				in_.move_fwd = 0
				in_.move_str = 0
				in_.jump = false
				in_.cast_spell = .None
				server.world.inputs[b.id] = in_
			}
		}
		return
	}

	for i in 0..<MAX_BOTS {
		b := &server.bots[i]
		if !b.active {
			continue
		}
		char, ok := entity_get_character(&server.world, b.id)
		if !ok {
			b.active = false
			continue
		}
		if char.dead {
			server.world.inputs[b.id] = Input_State{yaw = char.yaw}
			b.target = INVALID_ENTITY
			b.mode = .Travel
			// Dying drops the wind-up, and with it the orb in the hand.
			b.charge_spell = .None
			b.charge_time = 0
			beam_quench(&server.world, b.id)
			continue
		}
		bot_update(server, b, char, dt)
	}
}

@(private = "file")
bot_update :: proc(server: ^Server, b: ^Bot, char: Character_State, dt: f32) {
	eye := char.pos + vec3{0, 0, PLAYER_EYE_M}

	// --- Objective -------------------------------------------------------
	b.objective_timer -= dt
	if b.objective < 0 || b.objective_timer <= 0 || bot_objective_done(server, b) {
		b.objective = bot_pick_objective(server, b, char.pos)
		b.objective_timer = rand.float32_range(2.5, 4.5)
	}
	obj := &server.pylons.pylons[clamp_int(b.objective, 0, MAX_PYLONS - 1)]
	obj_pos := obj.base
	to_obj := obj_pos - char.pos
	to_obj.z = 0
	obj_dist := len_vec3(to_obj)

	// Stand off far enough not to be inside the rock, close enough to hold a
	// beam on it. Hysteresis so a bot at the boundary does not flicker.
	stand := obj.shape.radius + BOT_MINE_STANDOFF
	if obj_dist < stand {
		b.mode = .Mine
	} else if obj_dist > stand * 1.25 {
		b.mode = .Travel
	}
	b.mine_point = obj_pos + vec3{0, 0, obj.shape.height * BOT_MINE_HEIGHT_FRAC}

	// --- Target ----------------------------------------------------------
	b.target_timer -= dt
	if b.target_timer <= 0 {
		b.target = bot_find_target(server, b, eye)
		b.target_timer = 0.25
	}
	have_target := false
	if b.target != INVALID_ENTITY {
		if entity_alive(&server.world, b.target) {
			t := server.world.characters[b.target]
			b.target_pos = t.pos
			b.target_vel = t.vel
			have_target = true
		} else {
			b.target = INVALID_ENTITY
		}
	}

	// A bot is mining when it is stood at its tower with nothing else to do.
	// Decided before movement because it changes where the bot wants to be.
	b.mining = b.mode == .Mine && pylon_standing(&server.pylons, obj.id) &&
		pylon_mineable_by(obj, b.team)

	// --- Movement direction ----------------------------------------------
	move_dir := vec3{}
	if b.mode == .Travel {
		wp := nav_next_waypoint(char.pos, obj_pos)
		move_dir = norm_vec3(vec3{wp.x - char.pos.x, wp.y - char.pos.y, 0})
	} else {
		// Circle the tower at mining distance so bots working the same rock
		// spread around it instead of stacking on one face.
		b.orbit_phase += dt * 0.5
		ring := vec3{math.cos(b.orbit_phase), math.sin(b.orbit_phase), 0} * (obj.shape.radius + BOT_MINE_STANDOFF * 0.6)
		goal := obj_pos + ring
		d := vec3{goal.x - char.pos.x, goal.y - char.pos.y, 0}
		if len2_vec3(d) > 0.6 * 0.6 {
			move_dir = norm_vec3(d) * 0.6
		}
	}

	// Combat footwork: strafe, and back off if too close
	if have_target {
		b.strafe_timer -= dt
		if b.strafe_timer <= 0 {
			b.strafe_dir = -b.strafe_dir
			b.strafe_timer = rand.float32_range(0.7, 1.6)
		}
		to_t := vec3{b.target_pos.x - char.pos.x, b.target_pos.y - char.pos.y, 0}
		tdist := len_vec3(to_t)
		if tdist > 0.01 {
			tdir := to_t / tdist
			side := vec3{-tdir.y, tdir.x, 0} * b.strafe_dir
			move_dir += side * 0.8
			if tdist < 7 && b.mode != .Mine {
				move_dir -= tdir * 0.6
			}
			if b.mode == .Travel && tdist < 16 {
				// Don't blindly run past a fight
				move_dir *= 0.55
			}
		}
	}

	// Stuck detection: barely moving while trying to travel
	b.stuck_timer += dt
	if b.stuck_timer >= 1.5 {
		moved := len_vec3(vec3{char.pos.x - b.stuck_pos.x, char.pos.y - b.stuck_pos.y, 0})
		if b.mode == .Travel && moved < 0.8 && !have_target {
			b.steer = b.steer == 0 ? (rand.float32() < 0.5 ? -1 : 1) : -b.steer
			b.steer_timer = 1.2
			b.jump_timer = 0
		}
		b.stuck_pos = char.pos
		b.stuck_timer = 0
	}

	// Local obstacle steering: when the path ahead is blocked, commit to a
	// side for a while (re-randomizing every probe makes bots oscillate).
	b.steer_timer -= dt
	if len2_vec3(move_dir) > 0.01 {
		md := norm_vec3(move_dir)
		probe := char.pos + md * BOT_PROBE_DIST + vec3{0, 0, 0.6}
		if !world_point_free(probe, 0.35) {
			if b.steer == 0 || b.steer_timer <= 0 {
				left := rotate_xy(md, 0.9)
				right := rotate_xy(md, -0.9)
				lf := world_point_free(char.pos + left * BOT_PROBE_DIST + vec3{0, 0, 0.6}, 0.35)
				rf := world_point_free(char.pos + right * BOT_PROBE_DIST + vec3{0, 0, 0.6}, 0.35)
				if lf && !rf {
					b.steer = 1
				} else if rf && !lf {
					b.steer = -1
				} else if b.steer == 0 {
					b.steer = rand.float32() < 0.5 ? -1 : 1
				}
				b.steer_timer = 1.0
			}
		} else if b.steer_timer <= 0 {
			b.steer = 0
		}
		if b.steer != 0 {
			move_dir = rotate_xy(md, 0.9 * b.steer) * len_vec3(move_dir)
		}
	}

	// --- Aim -------------------------------------------------------------
	desired_yaw := char.yaw
	desired_pitch: f32 = 0
	if have_target {
		b.aim_err_timer -= dt
		if b.aim_err_timer <= 0 {
			b.aim_err_yaw = rand.float32_range(-BOT_AIM_NOISE, BOT_AIM_NOISE)
			b.aim_err_pitch = rand.float32_range(-BOT_AIM_NOISE, BOT_AIM_NOISE) * 0.6
			b.aim_err_timer = rand.float32_range(0.3, 0.6)
		}
		chest := b.target_pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.55}
		dist := len_vec3(chest - eye)

		// Aim for the spell that is actually about to be cast: they differ
		// enough in speed and drop that one shared lead misses with all of them.
		// Anything that is not a projectile lands where the bot is looking, so
		// it gets no lead at all.
		if b.next_spell == .None {
			b.next_spell = bot_pick_spell(server, b, char, dist)
		}
		aim_spell := b.charge_spell != .None ? b.charge_spell : b.next_spell
		lead := chest
		if aim_spell == .None || SPELL_DEFS[aim_spell].payload == .Projectile {
			aim_def := &SPELL_DEFS[aim_spell == .None ? .Arcane_Missile : aim_spell]
			flight := dist / max(aim_def.proj_speed, 1)
			lead = chest + b.target_vel * flight * 0.8
			lead.z -= 0.5 * PROJECTILE_GRAVITY_Z * aim_def.proj_gravity * flight * flight
		}

		d := lead - eye
		hd := math.sqrt(d.x * d.x + d.y * d.y)
		desired_yaw = math.atan2(d.y, d.x) + b.aim_err_yaw
		desired_pitch = math.atan2(d.z, hd) + b.aim_err_pitch
	} else if b.mining {
		// Rock does not dodge, so there is no lead and no aim error worth
		// modelling -- just look at the spot being cut.
		b.next_spell = .None
		d := b.mine_point - eye
		hd := math.sqrt(d.x * d.x + d.y * d.y)
		desired_yaw = math.atan2(d.y, d.x)
		desired_pitch = math.atan2(d.z, hd)
	} else {
		b.next_spell = .None
		if len2_vec3(move_dir) > 0.01 {
			desired_yaw = math.atan2(move_dir.y, move_dir.x)
		}
	}

	// Smooth turn
	yaw_diff := wrap_angle(desired_yaw - b.aim_yaw)
	max_step := BOT_TURN_RATE * dt
	b.aim_yaw = wrap_angle(b.aim_yaw + clampf(yaw_diff, -max_step, max_step))
	pitch_diff := desired_pitch - b.aim_pitch
	b.aim_pitch = clampf(b.aim_pitch + clampf(pitch_diff, -max_step, max_step), -1.2, 1.2)

	when BOT_DEBUG_STUCK {
		if abs(char.pos.x - 33) < 1.5 && abs(char.pos.y + 16) < 1.5 && server.tick_id % 30 == 0 {
			server_log("[BotDbg] id=%d pos=(%.2f,%.2f) mode=%v tgt=%d steer=%.0f st=%.2f move=(%.2f,%.2f) obj=%d",
				b.id, char.pos.x, char.pos.y, b.mode, b.target, b.steer, b.steer_timer, move_dir.x, move_dir.y, b.objective)
		}
	}

	// --- Build input -----------------------------------------------------
	look := camera_forward(b.aim_yaw, 0)
	right := camera_right(b.aim_yaw)
	fwd := dot_vec3(move_dir, look)
	str := dot_vec3(move_dir, right)
	mag := math.sqrt(fwd * fwd + str * str)
	if mag > 1 {
		fwd /= mag
		str /= mag
	}

	b.jump_timer -= dt
	jump := false
	if b.jump_timer <= 0 {
		b.jump_timer = rand.float32_range(2.5, 6.0)
		jump = b.mode == .Travel && !have_target && rand.float32() < 0.35
	}
	if b.steer != 0 && b.steer_timer > 0.65 && rand.float32() < 0.02 {
		jump = true
	}

	sprint := b.mode == .Travel && !have_target && char.stamina > 30

	input := Input_State{
		move_fwd = fwd,
		move_str = str,
		jump     = jump,
		sprint   = sprint,
		yaw      = b.aim_yaw,
		pitch    = b.aim_pitch,
	}
	server.world.inputs[b.id] = input

	// --- Cast ------------------------------------------------------------
	// Bots wind up the same way players do: commit to a spell, hold it for its
	// cast time while tracking, then release at full charge. Losing the target
	// mid-wind-up drops the charge, so they telegraph just like a player does.
	b.cast_timer -= dt
	if b.charge_spell != .None && SPELL_DEFS[b.charge_spell].payload == .Beam {
		// A beam is held rather than released: light it, keep it on the target
		// for a burst, and let go when the burst is up, the target is gone, or
		// the server has already put it out for want of mana.
		if b.charge_time == 0 && !beam_light(&server.world, b.id, b.charge_spell) {
			b.charge_spell = .None
			b.cast_timer = 0.3
		} else {
			b.charge_time += dt
			lit := spell_state_beaming(&server.world.spell_states[b.id])
			// Mining holds far longer than a duel: the burst length exists so a
			// bot does not stand in the open lasering one player forever, and a
			// tower is not going to shoot back.
			if (!have_target && !b.mining) || !lit || b.charge_time >= b.beam_hold {
				beam_quench(&server.world, b.id)
				b.charge_spell = .None
				b.charge_time = 0
				b.cast_timer = rand.float32_range(0.6, 1.2)
			}
		}
	} else if b.charge_spell != .None {
		// A self-cast needs neither a target nor settled aim, so a bot that is
		// backing out of a fight can still finish the heal it started.
		self_cast := SPELL_DEFS[b.charge_spell].payload == .Heal
		if !have_target && !self_cast {
			b.charge_spell = .None
			b.charge_time = 0
			b.cast_timer = 0.2
		} else {
			b.charge_time += dt
			def := &SPELL_DEFS[b.charge_spell]
			// The aim gate can't stall the release forever, or a bot that never
			// settles would hold its charge for the rest of the match.
			aimed := self_cast || abs(yaw_diff) < 0.12
			if b.charge_time >= def.cast_time && (aimed || b.charge_time >= def.cast_time + 0.6) {
				// The cast reads the entity's yaw/pitch, which the sim sets from
				// input next tick; apply our aim now so the shot goes where we look.
				c := server.world.characters[b.id]
				c.yaw = b.aim_yaw
				c.pitch = b.aim_pitch
				server.world.characters[b.id] = c
				ok := server_handle_spell_cast(server, b.id, b.charge_spell, 1.0, server.tick_id, b.target)
				b.charge_spell = .None
				b.charge_time = 0
				b.cast_timer = ok ? rand.float32_range(0.45, 1.0) : 0.15
			}
		}
	} else if b.cast_timer <= 0 && bot_wants_heal(server, b, char) {
		// Healing outranks shooting: a bot this low gets more out of the heal
		// than out of one more missile.
		b.charge_spell = .Friendly_Heal
		b.charge_time = 0
	} else if have_target && b.cast_timer <= 0 && abs(yaw_diff) < 0.12 {
		spell := b.next_spell
		if spell == .None {
			spell = bot_pick_spell(server, b, char, len_vec3(b.target_pos - char.pos))
		}
		b.next_spell = .None
		if spell != .None {
			b.charge_spell = spell
			b.charge_time = 0
			b.beam_hold = rand.float32_range(1.2, 2.4)
		} else {
			b.cast_timer = 0.3
		}
	} else if b.mining && b.cast_timer <= 0 && abs(yaw_diff) < 0.25 {
		// The beam is the mining tool. Nothing else in the hotbar works rock at
		// a useful rate, so there is no choice to make here.
		char_now := server.world.characters[b.id]
		if spell_castable(.Thunderbolt, char_now, server.world.spell_states[b.id].cooldowns[.Thunderbolt]) {
			b.charge_spell = .Thunderbolt
			b.charge_time = 0
			b.beam_hold = rand.float32_range(3.5, 6.0)
		} else {
			b.cast_timer = 0.6
		}
	}

	// A bot times its own wind-up rather than going through the input path a
	// player's charge takes, but the orb a wisp holds up is read off the
	// entity's channel state. Mirror it there or bots would be the only thing
	// in the arena that casts without a telegraph. Beams keep their own
	// channel (beam_light / beam_quench), so leave those alone.
	if SPELL_DEFS[b.charge_spell].payload != .Beam {
		spell_state := &server.world.spell_states[b.id]
		spell_state.channel_spell = b.charge_spell
		spell_state.channel_time = b.charge_time
	}
}

@(private = "file")
rotate_xy :: proc(v: vec3, a: f32) -> vec3 {
	c := math.cos(a)
	s := math.sin(a)
	return {c * v.x - s * v.y, s * v.x + c * v.y, v.z}
}

@(private = "file")
bot_objective_done :: proc(server: ^Server, b: ^Bot) -> bool {
	if b.objective < 0 || b.objective >= server.pylons.count {
		return true
	}
	p := &server.pylons.pylons[b.objective]
	// Nothing left to chew, or it was never ours to chew.
	if !pylon_standing(&server.pylons, p.id) {
		return true
	}
	return !pylon_mineable_by(p, b.team)
}

// Score every pylon and pick the best. Lower is better.
@(private = "file")
bot_pick_objective :: proc(server: ^Server, b: ^Bot, pos: vec3) -> int {
	best := -1
	best_score := f32(1e9)

	for i in 0..<server.pylons.count {
		p := &server.pylons.pylons[i]
		// Your own ore is off limits, and a stump has nothing to give.
		if !pylon_mineable_by(p, b.team) || !pylon_standing(&server.pylons, p.id) {
			continue
		}
		score := len_vec3(vec3{p.base.x - pos.x, p.base.y - pos.y, 0})

		// The golden pylon pays triple, so it is worth walking past a lane
		// tower for -- but it is also tough, so not worth crossing the map for.
		if p.ore == .Gold {
			score -= 25
		}
		// Finish what someone else started: a tower already half down is closer
		// to shedding its top, which is where the ore comes in quantity.
		score -= (1 - p.intact) * 30

		// Spread bots out, and give each one a standing preference so a team
		// does not move as a single clump.
		friends := 0
		for k in 0..<MAX_BOTS {
			o := &server.bots[k]
			if o.active && o.team == b.team && o.id != b.id && o.objective == i {
				friends += 1
			}
		}
		score += f32(friends) * 20
		score += f32((b.think_offset + i) % 3) * 4

		if score < best_score {
			best_score = score
			best = i
		}
	}
	// Everything mineable is gone: hold the centre, which is where it will come
	// back first.
	return best < 0 ? 0 : best
}

@(private = "file")
bot_find_target :: proc(server: ^Server, b: ^Bot, eye: vec3) -> Entity_ID {
	best := INVALID_ENTITY
	best_d := BOT_SIGHT_RANGE * BOT_SIGHT_RANGE
	for i in 1..<MAX_ENTITIES {
		id := Entity_ID(i)
		if id == b.id || !entity_alive(&server.world, id) {
			continue
		}
		if !teams_are_enemies(b.team, server.world.teams[i]) {
			continue
		}
		tpos := server.world.characters[i].pos
		d2 := len2_vec3(tpos - eye)
		if d2 >= best_d {
			continue
		}
		chest := tpos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.55}
		if !world_segment_clear(eye, chest, 0.8) {
			continue
		}
		best = id
		best_d = d2
	}
	return best
}

// Hurt enough that a full heal is nearly all value, and only while the heal
// would really land -- spell_castable keeps bots off a heal they cannot pay for.
@(private = "file")
bot_wants_heal :: proc(server: ^Server, b: ^Bot, char: Character_State) -> bool {
	if char.health > HEALTH_MAX * 0.45 {
		return false
	}
	return spell_castable(.Friendly_Heal, char, server.world.spell_states[b.id].cooldowns[.Friendly_Heal])
}

// Offence only: the chosen spell also drives the aim lead, so a self-cast has
// no business in here.
@(private = "file")
bot_pick_spell :: proc(server: ^Server, b: ^Bot, char: Character_State, dist: f32) -> Spell_ID {
	cds := &server.world.spell_states[b.id].cooldowns
	r := rand.float32()
	// The bolt cannot be dodged, so a bot that can afford it reaches for it
	// first at mid range, where a lance would take long enough to arrive to be
	// sidestepped. Point blank it is a waste of the wind-up.
	if dist > 8 && dist < SPELL_DEFS[.Call_Lightning].range - 3 && cds[.Call_Lightning] <= 0 &&
	   char.mana >= SPELL_DEFS[.Call_Lightning].mana_cost && r < 0.3 {
		return .Call_Lightning
	}
	// The orb only lands at short range now that it lobs, and the lance is too
	// slow to connect across the map.
	if dist < 13 && cds[.Arcane_Orb] <= 0 && char.mana >= SPELL_DEFS[.Arcane_Orb].mana_cost && r < 0.4 {
		return .Arcane_Orb
	}
	if dist < 24 && cds[.Frost_Lance] <= 0 && char.mana >= SPELL_DEFS[.Frost_Lance].mana_cost && r < 0.6 {
		return .Frost_Lance
	}
	// The beam wants a steady hand, which a bot only has up close, and enough
	// mana behind it that the burst is worth the lock-on it telegraphs.
	if dist < 12 && cds[.Thunderbolt] <= 0 && char.mana >= 45 && r < 0.85 {
		return .Thunderbolt
	}
	if cds[.Arcane_Missile] <= 0 && char.mana >= SPELL_DEFS[.Arcane_Missile].mana_cost {
		return .Arcane_Missile
	}
	return .None
}
