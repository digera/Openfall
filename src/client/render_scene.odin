package main

// Scene building: everything the renderer needs for one frame, gathered from
// the client world into Render_Scene. This is where the camera is placed, the
// robes are simulated, the nearest wisps are chosen and every object is packed
// into its record. It knows nothing about the GPU; a backend uploads the
// records as they are.

import "core:fmt"
import "core:math"

// The eye for one view. `half_w` and `half_h` are the tangents of the half
// field of view, so a ray through normalized screen point (x, y) in [-1, 1] is
// forward + right * x * half_w + up * y * half_h.
Render_View :: struct {
	eye:     vec3,
	right:   vec3,
	up:      vec3,
	forward: vec3,
	half_w:  f32,
	half_h:  f32,
}

RENDER_MAX_WISPS :: 16

// One frame of the scene: the view, and the records of everything in it.
Render_Scene :: struct {
	view:          Render_View,
	using records: Scene_Records,
}

// One array of vec4 records per kind of thing, unused slots zero. The packing
// of each record is documented beside the matching field of fs_params in
// shaders/scene.glsl, which reads them in this layout: the block is all vec4s,
// so it is the same bytes under std140 and can be uploaded as it is.
Scene_Records :: struct {
	cam_data:        vec4,
	fx:              vec4,
	fx2:             vec4,
	hand_pos:        vec4,
	hand_cast:       vec4,
	floor_boxes:     [2 * NUM_FLOOR_BOXES]vec4,
	solid_boxes:     [2 * NUM_SOLID_BOXES]vec4,
	pylons:          [MAX_PYLONS]vec4,
	pylon_shape:     [MAX_PYLONS]vec4,
	pylon_bound:     [MAX_PYLONS]vec4,
	pylon_node_meta: [MAX_PYLONS]vec4,
	pylon_collapse:  [MAX_PYLONS]vec4,
	pylon_laid:      [MAX_PYLONS]vec4,
	pylon_wounds:    [MAX_PYLONS * TOWER_WOUND_MAX]vec4,
	chunks:          [MAX_SNAPSHOT_CHUNKS]vec4,
	chunk_fx:        [MAX_SNAPSHOT_CHUNKS]vec4,
	minions:         [MAX_SNAPSHOT_MINIONS]vec4,
	minion_fx:       [MAX_SNAPSHOT_MINIONS]vec4,
	projectiles:     [MAX_SNAPSHOT_PROJECTILES]vec4,
	proj_vel:        [MAX_SNAPSHOT_PROJECTILES]vec4,
	wisps:           [RENDER_MAX_WISPS]vec4,
	wisp_cast:       [RENDER_MAX_WISPS]vec4,
	wisp_aim:        [RENDER_MAX_WISPS]vec4,
	robes:           [RENDER_MAX_WISPS]vec4,
	robe_waists:     [RENDER_MAX_WISPS]vec4,
	robe_fx:         [RENDER_MAX_WISPS]vec4,
	impacts:         [MAX_CLIENT_IMPACTS]vec4,
	lightning:       [MAX_CLIENT_STRIKES]vec4,
	beams:           [MAX_SNAPSHOT_BEAMS]vec4,
	beam_ends:       [MAX_SNAPSHOT_BEAMS]vec4,
	beam_chains:     [MAX_SNAPSHOT_BEAMS * BEAM_MAX_CHAINS]vec4,
	target_mark:     vec4,
	pads:            [MAX_SNAPSHOT_PADS]vec4,
}

// State the scene builder carries from frame to frame.
Scene_Builder :: struct {
	world_t: f32,
	robes:   [MAX_ENTITIES]Robe_State,

	// Where each wisp's cast orb ended up this frame. A beam pours out of the
	// orb rather than out of the middle of the robe, and the beam pass runs
	// after the wisps, so the positions have to outlive the loop that made them.
	// w is 1 where there is an orb at all.
	orbs:    [MAX_ENTITIES]vec4,
}

// Render type codes for the shader's spell_tint; an appearance, not the
// Spell_ID, so spells that share a look can share a code. Zero is nothing to
// draw, which is what a cast orb asks about.
@(private = "file")
spell_type_code :: proc(spell: Spell_ID) -> f32 {
	#partial switch spell {
	case .Arcane_Missile: return 1
	case .Arcane_Orb:     return 2
	case .Blink:          return 3
	case .Frost_Lance:    return 4
	case .Call_Lightning: return 5
	case .Thunderbolt:    return 6
	case .Friendly_Heal:  return 7
	}
	return 0
}

// Where a wisp holds its cast orb: out past the right hand and carried along
// the aim, so it rises when they look up and drops when they look down. Close
// enough to the robe that the light spills onto the cloth, far enough out that
// even the heaviest orb clears the cloth instead of sinking into it.
CAST_ORB_SIDE_M  :: f32(0.28)   // out to the wisp's right of centre
CAST_ORB_REACH_M :: f32(0.40)   // forward along the aim
CAST_ORB_RISE_M  :: f32(0.14)   // above the wisp's centre

@(private = "file")
cast_orb_pos :: proc(center: vec3, yaw: f32, aim: vec3, scale: f32) -> vec3 {
	return center +
	       camera_right(yaw) * (CAST_ORB_SIDE_M * scale) +
	       aim * (CAST_ORB_REACH_M * scale) +
	       vec3{0, 0, CAST_ORB_RISE_M * scale}
}

@(private = "file")
pack_box :: proc(b: ^World_Box) -> (a, c: vec4) {
	return vec4{b.center.x, b.center.y, b.center.z, math.sin(b.yaw)},
	       vec4{b.half.x, b.half.y, b.half.z, math.cos(b.yaw)}
}

// Build this frame's scene. `aspect` is the viewport's width over its height.
render_scene_build :: proc(scene: ^Render_Scene, sb: ^Scene_Builder, gc: ^Game_Client, aspect: f32) {
	scene^ = {}
	dt := f32(platform_frame_duration())
	sb.world_t += dt
	// A hitch must not launch the hem springs, and the sim divides by dt
	robe_dt := clampf(dt, ROBE_SIM_DT_MIN, ROBE_SIM_DT_MAX)

	world := &gc.client_world
	pred := &world.prediction
	fx := &gc.fx
	in_match := gc.phase == .Playing || gc.phase == .In_Menu
	playing := in_match && pred.initialized && !gc.is_spectating
	tower_world_visual_tick(&world.towers, min(dt, 0.05))

	// --- Camera --------------------------------------------------------------
	base_pos: vec3
	yaw := gc.view_yaw
	pitch := gc.view_pitch
	if playing {
		base_pos = client_prediction_render_pos(pred, gc.render_alpha)
	} else if in_match {
		// Spectator / no body yet: free-look from above the plaza.
		base_pos = {0, 0, 6}
	} else {
		// Lobby camera: slow orbit above the plaza looking at the center
		a := sb.world_t * 0.10
		base_pos = {math.cos(a) * 12.5, math.sin(a) * 12.5, 4.5}
		yaw = wrap_angle(a + f32(math.PI))
		pitch = -0.22
	}

	right := camera_right(yaw)
	bob_z := math.sin(fx.bob_phase * 2.0) * 0.032 * fx.bob_amount
	bob_r := math.sin(fx.bob_phase) * 0.018 * fx.bob_amount
	eye := base_pos + vec3{0, 0, PLAYER_EYE_M + bob_z + fx.land_dip} + right * bob_r
	pitch = clampf(pitch - fx.cast_kick + math.sin(fx.bob_phase * 2.0) * 0.003 * fx.bob_amount, -CAM_PITCH_MAX - 0.1, CAM_PITCH_MAX + 0.1)

	fwd := camera_forward(yaw, pitch)
	up := norm_vec3(cross_vec3(right, fwd))
	// Roll
	if abs(fx.roll) > 1e-5 {
		c := math.cos(fx.roll)
		s := math.sin(fx.roll)
		nr := right * c + up * s
		nu := up * c - right * s
		right = nr
		up = nu
	}

	fov := CAM_FOV_DEG + fx.fov_kick * 9.0 + fx.sprint_blend * 5.0
	half_h := math.tan(fov * math.PI / 360.0)
	half_w := half_h * max(aspect, 0.01)

	scene.view = {
		eye     = eye,
		right   = right,
		up      = up,
		forward = fwd,
		half_w  = half_w,
		half_h  = half_h,
	}

	// --- Per-object records ------------------------------------------------
	scene.cam_data = {eye.x, eye.y, eye.z, sb.world_t}
	scene.fx = {fx.hurt, fx.flash, f32(u8(world.local_team)), gc.cast_pulse}
	dead: f32 = (playing && pred.predicted_char.dead) ? 1 : 0
	ended: f32 = (world.have_game_state && Match_State(world.game_state.match_state) == .Ended) ? 1 : 0
	scene.fx2 = {world.hit_marker, dead, ended, fx.mend}

	// Hand orb: lower right of the view, bobbing with the camera. It is this
	// player's end of the cast orb every opponent sees them holding, so it
	// takes the charging spell's colour and swells with the wind-up. What the
	// player reads in their own hand is what the arena reads on their wisp.
	if playing && dead < 0.5 {
		hand := eye + fwd * 0.62 + right * (0.27 + bob_r * 0.5) + up * (-0.25 + bob_z * 0.4 - fx.cast_kick * 1.5)
		code := spell_type_code(gc.charging_spell)
		charge: f32 = 0
		if code > 0 {
			charge = spell_charge_frac(&SPELL_DEFS[gc.charging_spell], gc.charge_accum)
		}
		scene.hand_pos = {hand.x, hand.y, hand.z, 1.0 + gc.cast_pulse * 0.9 + charge * 0.35}
		scene.hand_cast = {code, charge, 0, 0}
	}

	for i in 0..<NUM_FLOOR_BOXES {
		a, c := pack_box(&world_floor_boxes[i])
		scene.floor_boxes[2 * i] = a
		scene.floor_boxes[2 * i + 1] = c
	}
	for i in 0..<NUM_SOLID_BOXES {
		a, c := pack_box(&world_solid_boxes[i])
		scene.solid_boxes[2 * i] = a
		scene.solid_boxes[2 * i + 1] = c
	}

	for i in 0..<MAX_PYLONS {
		t := &world.towers.towers[i]
		display_h := tower_display_core_height(t)
		scene.pylons[i] = {t.base.x, t.base.y, t.base.z, t.yaw}
		scene.pylon_shape[i] = {display_h, t.design_radius, t.seed, f32(u8(t.ore))}
		if t.live_count <= 0 {
			scene.pylon_bound[i] = {0, 0, 0, 0}
			scene.pylon_node_meta[i] = {}
			scene.pylon_collapse[i] = {}
			scene.pylon_laid[i] = {}
		} else {
			mask := tower_alive_mask(t)
			scene.pylon_bound[i] = {f32(t.max_count), t.node_radius, tower_outer_radius(t), tower_mass_frac(t)}
			scene.pylon_node_meta[i] = {
				t.spiral_radius,
				t.stack_step,
				f32(mask & 0xFFFF),
				f32(mask >> 16),
			}
			if t.collapse_t > 0.001 {
				from := t.collapse_from_mask
				scene.pylon_collapse[i] = {
					t.collapse_t,
					t.collapse_from_height,
					f32(from & 0xFFFF),
					f32(from >> 16),
				}
			} else {
				scene.pylon_collapse[i] = {}
			}
			scene.pylon_laid[i] = {
				tower_laid_chunk(t, 0),
				tower_laid_chunk(t, 12),
				tower_laid_chunk(t, 24),
				f32(u8(tower_display_ore(t))),
			}
		}
		for k in 0 ..< TOWER_WOUND_MAX {
			idx := i * TOWER_WOUND_MAX + k
			if k < t.wound_count {
				w := t.wounds[k]
				scene.pylon_wounds[idx] = {w.pos.x, w.pos.y, w.pos.z, w.radius}
			} else {
				scene.pylon_wounds[idx] = {}
			}
		}
	}
	for i in 0..<MAX_SNAPSHOT_CHUNKS {
		c := &world.chunks[i]
		if !c.present {
			scene.chunks[i] = {}
			scene.chunk_fx[i] = {}
			continue
		}
		radius := c.radius
		if c.pickup_pop > 0 {
			radius *= 0.55 + 0.45 * c.pickup_pop
		}
		scene.chunks[i] = {c.pos.x, c.pos.y, c.pos.z, radius}
		// chunk_fx.w is one event: pickup lives in [1, 2), landing in [0, 1).
		vfx: f32
		if c.pickup_pop > 0 {
			vfx = 1.0 + min(c.pickup_pop, 0.999)
		} else {
			vfx = min(c.land_flash, 0.999)
		}
		scene.chunk_fx[i] = {f32(u8(c.ore)), c.seed / 8, c.rest ? 1 : 0, vfx}
	}
	// Minions go up as the ore they are made of rather than as a team colour:
	// their team is legible because their team's rock is, and it is the same
	// read as the tower they came out of and the lump they will drop.
	for i in 0..<MAX_SNAPSHOT_MINIONS {
		m := &world.minions[i]
		if !m.present {
			scene.minions[i] = {}
			scene.minion_fx[i] = {}
			continue
		}
		scene.minions[i] = {m.pos.x, m.pos.y, m.pos.z, f32(u8(team_ore(m.team))) + 1}
		seed := f32(hash_u32(u32(m.id) * 2654435761) & 0xFFFF) / f32(0x10000)
		scene.minion_fx[i] = {m.yaw, m.hp, f32(u8(m.kind)), seed}
	}

	// Nearest living remote players → wisps
	{
		sb.orbs = {}
		ids: [MAX_ENTITIES]int
		dist: [MAX_ENTITIES]f32
		n := 0
		for i in 0..<MAX_ENTITIES {
			remote := &world.remote_entities[i]
			if !remote.active || remote.count == 0 {
				// The robe of a wisp that left starts fresh when it is back
				sb.robes[i].settled = false
				continue
			}
			// A wisp that is down is still drawn while it swells and bursts, and
			// is gone from the arena once it has. One whose robe is not being
			// simulated died out of this client's sight, so it never starts: a
			// burst nobody watched is not replayed when it comes back into view.
			if remote.display_state.dead && (!sb.robes[i].settled || sb.robes[i].death_t >= DEATH_ANIM_SEC) {
				continue
			}
			ids[n] = i
			dist[n] = len2_vec3(remote.display_state.pos - eye)
			n += 1
		}
		take := min(n, RENDER_MAX_WISPS)
		for k in 0..<take {
			best := k
			for j in k + 1..<n {
				if dist[j] < dist[best] {
					best = j
				}
			}
			if best != k {
				ids[k], ids[best] = ids[best], ids[k]
				dist[k], dist[best] = dist[best], dist[k]
			}
			remote := &world.remote_entities[ids[k]]
			robe := &sb.robes[ids[k]]
			dead := remote.display_state.dead
			hp := clampf(remote.display_state.health / HEALTH_MAX, 0.05, 0.95)
			// The server zeroes health on death, so a wisp killed outright would
			// shrink on the frame it died. It swells from the body everyone just
			// saw instead.
			if dead {
				hp = robe.death_hp
			} else {
				robe.death_hp = hp
			}
			pos := remote.display_state.pos
			// Idle bob, animated here once per wisp rather than per pixel
			phase := f32(ids[k]) * 2.21
			pos.x += 0.045 * math.sin(sb.world_t * 1.37 + phase)
			pos.y += 0.045 * math.cos(sb.world_t * 1.11 + phase * 0.83)
			pos.z += CHARACTER_HEIGHT_M * 0.50 + 0.06 * math.sin(sb.world_t * 2.07 + phase)
			scene.wisps[k] = {pos.x, pos.y, pos.z, f32(u8(remote.team)) + hp}

			// The crosshair's target is framed where it is actually drawn, bob and
			// all, so the mark rides the body instead of hanging beside it.
			// Only a wisp near enough to be one of the sixteen gets one: a
			// frame around a body this client is not drawing marks nothing.
			if !dead && Entity_ID(ids[k]) == world.target_id {
				relation: f32 = teams_are_enemies(world.local_team, remote.team) ? 1 : 2
				scene.target_mark = {pos.x, pos.y, pos.z, relation}
			}

			// The robe hangs from the bobbing body and shrinks with the wisp
			// as it is hurt.
			scale := 0.82 + 0.18 * hp
			yaw := remote.display_state.yaw
			robe_simulate(robe, remote.display_state.vel, yaw, scale, sb.world_t, phase, robe_dt, dead)
			waist := pos + vec3{0, 0, ROBE_SHOULDER_Z_M * scale} + robe.waist_off
			hem := waist + robe.hem_off
			scene.robes[k] = {hem.x, hem.y, hem.z, yaw}
			scene.robe_waists[k] = {waist.x, waist.y, waist.z, robe.hem_yaw}
			haul := carry_total(remote.carrying_ore)
			scene.robe_fx[k] = {
				robe.flutter,
				robe.death_t,
				clampf(haul / CARRY_CAPACITY_MAX, 0, 1),
				f32(u8(carry_dominant(remote.carrying_ore))),
			}

			// The cast orb, held out along the aim so a glance says both what
			// is coming and who it is coming for. Where a wisp is pointing is
			// the only thing about it that carries down a lane, so the orb
			// rides the look direction rather than sitting on the body.
			code := spell_type_code(remote.channel_spell)
			if code > 0 && remote.channel_frac > 0.01 {
				aim := camera_forward(yaw, remote.display_state.pitch)
				orb := cast_orb_pos(pos, yaw, aim, scale)
				scene.wisp_cast[k] = {orb.x, orb.y, orb.z, code}
				scene.wisp_aim[k] = {aim.x, aim.y, aim.z, clampf(remote.channel_frac, 0, 1)}
				sb.orbs[ids[k]] = {orb.x, orb.y, orb.z, 1}
			}
		}
		// Wisps too far away to draw are not simulated either; their cloth
		// starts at rest when they come back into view rather than from stale
		// state.
		for k in take..<n {
			sb.robes[ids[k]].settled = false
		}
	}

	for i in 0..<min(world.projectile_count, MAX_SNAPSHOT_PROJECTILES) {
		cp := &world.projectiles[i]
		pos := client_projectile_pos(cp, world.local_time)
		radius := clampf(cp.snap.radius, 0.05, 0.95)
		scene.projectiles[i] = {pos.x, pos.y, pos.z, spell_type_code(cp.snap.spell_id) + radius}
		scene.proj_vel[i] = {cp.snap.vel.x, cp.snap.vel.y, cp.snap.vel.z, 0}
	}

	// Gust runes. Every player is on a team, so the team code keeps w off
	// zero; the fraction is how much of the rune's life is left.
	for i in 0..<min(world.prediction.pad_count, len(scene.pads)) {
		pad := &world.prediction.pads[i]
		if pad.life <= 0 || pad.team == .None {
			continue
		}
		life := clampf(pad.life / GUST_PAD_LIFETIME, 0.01, 0.99)
		scene.pads[i] = {pad.pos.x, pad.pos.y, pad.pos.z, f32(u8(pad.team)) + life}
	}

	for i in 0..<MAX_CLIENT_IMPACTS {
		im := &world.impacts[i]
		if !im.live {
			continue
		}
		scene.impacts[i] = {im.pos.x, im.pos.y, im.pos.z, spell_type_code(im.spell) + clampf(im.age, 0.01, 0.99)}
	}

	for i in 0..<MAX_CLIENT_STRIKES {
		s := &world.strikes[i]
		if !s.live {
			continue
		}
		scene.lightning[i] = {s.pos.x, s.pos.y, s.pos.z, clampf(s.life, 0.01, 1)}
	}

	if client_world_beams_current(world) {
		for i in 0..<world.beam_count {
			b := &world.beams[i]
			from: vec3
			to := b.end
			on_body := b.hit
			// The snapshot says which beam this is; a byte off the wire that is
			// not a spell falls back to the one beam everyone can see.
			def := &SPELL_DEFS[spell_valid(b.spell_id) ? b.spell_id : .Thunderbolt]
			if b.owner_id == world.local_entity_id {
				if !playing || dead > 0.5 {
					continue
				}
				// Leaves the hand orb and lands where the crosshair says, traced
				// this frame the way the server will trace it.
				from = {scene.hand_pos.x, scene.hand_pos.y, scene.hand_pos.z}
				trace_eye := base_pos + vec3{0, 0, PLAYER_EYE_M}
				look := camera_forward(gc.view_yaw, gc.view_pitch)
				to, on_body = client_world_beam_end(world, def, trace_eye, look)
			} else {
				remote := &world.remote_entities[int(b.owner_id)]
				if !remote.active {
					continue
				}
				// Out of the orb in their hand, the same one the wind-up
				// spells gather in. A beam owner too far away to be drawn as a
				// wisp has no orb this frame, so the chest stands in.
				orb := sb.orbs[int(b.owner_id)]
				if orb.w > 0.5 {
					from = {orb.x, orb.y, orb.z}
				} else {
					from = remote.display_state.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.55}
				}
			}
			scene.beams[i] = {from.x, from.y, from.z, spell_type_code(def.id)}
			scene.beam_ends[i] = {to.x, to.y, to.z, on_body ? 1 : 0}
			// Chains arc to bodies (players or minions), so they follow the
			// interpolated remotes or current minion snapshot positions.
			for c in 0..<min(int(b.chain_count), BEAM_MAX_CHAINS) {
				minion_id := b.chain_minion_ids[c]
				if minion_id > 0 {
					for mi in 0..<world.minion_count {
						m := &world.minions[mi]
						if m.id == minion_id && m.present {
							p := m.pos + vec3{0, 0, MINION_HEIGHT_M * 0.5}
							scene.beam_chains[i * BEAM_MAX_CHAINS + c] = {p.x, p.y, p.z, 1}
							break
						}
					}
					continue
				}
				eid := int(b.chains[c])
				if eid <= 0 || eid >= MAX_ENTITIES {
					continue
				}
				target := &world.remote_entities[eid]
				if !target.active {
					continue
				}
				p := target.display_state.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
				scene.beam_chains[i * BEAM_MAX_CHAINS + c] = {p.x, p.y, p.z, 1}
			}
		}
	}
}

// Frame rate and CPU frame time for the HUD's stats line, and a perf line on
// stdout every five seconds.
Frame_Stats :: struct {
	fps_accum:    f64,
	fps_presents: int,
	last_fps:     f32,
	frame_ms:     f32,
	perf_accum:   f64,
	perf_frames:  int,
	gpu_ms:       f32,   // GPU time of the latest finished frame; 0 if the backend cannot time it
}

// Called once per presented frame. `frame_ms` is the CPU time the backend
// spent building and submitting it; `width` and `height` are the viewport.
frame_stats_update :: proc(st: ^Frame_Stats, scene: ^Render_Scene, gc: ^Game_Client, frame_ms: f32, width, height: int) {
	dt := platform_frame_duration()
	st.frame_ms = frame_ms
	st.fps_accum += dt
	st.fps_presents += 1
	if st.fps_accum >= 0.5 {
		st.last_fps = f32(st.fps_presents) / f32(st.fps_accum)
		st.fps_accum = 0
		st.fps_presents = 0
	}
	st.perf_accum += dt
	st.perf_frames += 1
	if st.perf_accum >= 5.0 {
		wisps := 0
		for w in scene.wisps {
			if w.w > 0.5 {
				wisps += 1
			}
		}
		fmt.printf("[Perf] %.0f fps avg over %.0fs (%d wisps, %d projectiles, %dx%d)",
			f64(st.perf_frames) / st.perf_accum, st.perf_accum, wisps, gc.client_world.projectile_count, width, height)
		if st.gpu_ms > 0 {
			fmt.printf(" gpu %.2f ms", st.gpu_ms)
		}
		fmt.println()
		st.perf_accum = 0
		st.perf_frames = 0
	}
}
