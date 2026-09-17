package main

// Client renderer: fullscreen analytic ray tracer (shaders/scene.glsl) plus a
// debug-text HUD. Also owns the camera feel (bob, landing dip, kicks, flashes).

import "core:fmt"
import "core:time"
import "core:math"
import "core:strings"
import sapp "sokol:app"
import sdtx "sokol:debugtext"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

camera_forward :: proc(yaw, pitch: f32) -> vec3 {
	cp := math.cos(pitch)
	return {math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch)}
}

camera_right :: proc(yaw: f32) -> vec3 {
	return {math.sin(yaw), -math.cos(yaw), 0}
}

SDTX_ORIGIN_CELLS :: f32(1)
SDTX_CHAR_PX      :: f32(8)
SDTX_CANVAS_SCALE :: f32(0.5)

Client_Renderer :: struct {
	pip:         sg.Pipeline,
	bind:        sg.Bindings,
	pass_action: sg.Pass_Action,

	fps_accum:    f64,
	fps_presents: int,
	last_fps:     f32,
	frame_ms:     f32,
	world_t:      f32,
	perf_accum:   f64,
	perf_frames:  int,
}

// ---------------------------------------------------------------------------
// Camera feel

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
	case .Self_Heal:      // handled when the health actually comes back
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

// ---------------------------------------------------------------------------

client_renderer_init :: proc(r: ^Client_Renderer) {
	sg.setup({
		environment = sglue.environment(),
		logger = {func = slog.func},
	})
	sdtx.setup({
		fonts = {0 = sdtx.font_c64()},
		logger = {func = slog.func},
	})

	verts := [?]f32{-1, -1, 3, -1, -1, 3}
	r.bind.vertex_buffers[0] = sg.make_buffer({
		data = {ptr = &verts, size = size_of(verts)},
	})

	r.pip = sg.make_pipeline({
		shader = sg.make_shader(scene_shader_desc(sg.query_backend())),
		layout = {attrs = {ATTR_scene_position = {format = .FLOAT2}}},
		depth = {write_enabled = false, compare = .ALWAYS},
		label = "scene",
	})

	r.pass_action = {
		colors = {0 = {load_action = .CLEAR, clear_value = {0.02, 0.02, 0.04, 1}}},
	}

	fmt.println("[Renderer] Sokol ready, backend:", sg.query_backend())
}

client_renderer_shutdown :: proc(r: ^Client_Renderer) {
	sdtx.shutdown()
	sg.shutdown()
}

// Render type codes for the shader's spell_tint; an appearance, not the
// Spell_ID, so spells that share a look can share a code.
@(private = "file")
spell_type_code :: proc(spell: Spell_ID) -> f32 {
	#partial switch spell {
	case .Arcane_Missile: return 1
	case .Arcane_Orb:     return 2
	case .Blink:          return 3
	case .Frost_Lance:    return 4
	case .Call_Lightning: return 5
	case .Thunderbolt:    return 6
	}
	return 1
}

@(private = "file")
pack_box :: proc(b: ^World_Box) -> (a, c: vec4) {
	return vec4{b.center.x, b.center.y, b.center.z, math.sin(b.yaw)},
	       vec4{b.half.x, b.half.y, b.half.z, math.cos(b.yaw)}
}

client_renderer_draw :: proc(r: ^Client_Renderer, gc: ^Game_Client) {
	t0 := time.tick_now()
	dt := f32(sapp.frame_duration())
	r.world_t += dt

	world := &gc.client_world
	pred := &world.prediction
	fx := &gc.fx
	playing := gc.phase == .Playing && pred.initialized

	// --- Camera --------------------------------------------------------------
	base_pos: vec3
	yaw := gc.view_yaw
	pitch := gc.view_pitch
	if playing {
		base_pos = client_prediction_render_pos(pred, gc.render_alpha)
	} else {
		// Lobby camera: slow orbit above the plaza looking at the center
		a := r.world_t * 0.10
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

	aspect := sapp.widthf() / sapp.heightf()
	fov := CAM_FOV_DEG + fx.fov_kick * 9.0 + fx.sprint_blend * 5.0
	half_h := math.tan(fov * math.PI / 360.0)
	half_w := half_h * max(aspect, 0.01)

	vs_params := Vs_Params{
		cam_pos     = eye,
		half_w      = half_w,
		cam_right   = right,
		half_h      = half_h,
		cam_up      = up,
		cam_forward = fwd,
	}

	// --- Fragment uniforms --------------------------------------------------
	fs_params: Fs_Params
	fs_params.cam_data = {eye.x, eye.y, eye.z, r.world_t}
	fs_params.fx = {fx.hurt, fx.flash, f32(u8(world.local_team)), gc.cast_pulse}
	dead: f32 = (playing && pred.predicted_char.dead) ? 1 : 0
	ended: f32 = (world.have_game_state && Match_State(world.game_state.match_state) == .Ended) ? 1 : 0
	fs_params.fx2 = {world.hit_marker, dead, ended, fx.mend}

	// Hand orb: lower right of the view, bobbing with the camera
	if playing && dead < 0.5 {
		hand := eye + fwd * 0.62 + right * (0.27 + bob_r * 0.5) + up * (-0.25 + bob_z * 0.4 - fx.cast_kick * 1.5)
		fs_params.hand_pos = {hand.x, hand.y, hand.z, 1.0 + gc.cast_pulse * 0.9}
	}

	for i in 0..<NUM_FLOOR_BOXES {
		a, c := pack_box(&world_floor_boxes[i])
		fs_params.floor_boxes[2 * i] = a
		fs_params.floor_boxes[2 * i + 1] = c
	}
	for i in 0..<NUM_SOLID_BOXES {
		a, c := pack_box(&world_solid_boxes[i])
		fs_params.solid_boxes[2 * i] = a
		fs_params.solid_boxes[2 * i + 1] = c
	}

	for i in 0..<MAX_OBELISKS {
		p := obelisk_position(i)
		owner: f32 = 0
		capturing: f32 = 0
		progress: f32 = 0
		state: f32 = 0
		if world.have_game_state {
			o := &world.game_state.obelisks[i]
			owner = f32(o.owner)
			capturing = f32(o.capturing)
			progress = o.progress
			state = f32(o.state)
		}
		hover := 2.7 + 0.12 * math.sin(r.world_t * 1.3 + f32(i) * 1.7)
		fs_params.obelisks[i] = {p.x, p.y, p.z, owner}
		fs_params.obelisk_fx[i] = {capturing, progress, state, hover}
	}

	// Nearest living remote players → wisps
	{
		ids: [MAX_ENTITIES]int
		dist: [MAX_ENTITIES]f32
		n := 0
		for i in 0..<MAX_ENTITIES {
			remote := &world.remote_entities[i]
			if !remote.active || remote.display_state.dead || remote.count == 0 {
				continue
			}
			ids[n] = i
			dist[n] = len2_vec3(remote.display_state.pos - eye)
			n += 1
		}
		take := min(n, 16)
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
			hp := clampf(remote.display_state.health / HEALTH_MAX, 0.05, 0.95)
			pos := remote.display_state.pos
			// Idle bob, animated here once per wisp rather than per pixel
			phase := f32(ids[k]) * 2.21
			pos.x += 0.045 * math.sin(r.world_t * 1.37 + phase)
			pos.y += 0.045 * math.cos(r.world_t * 1.11 + phase * 0.83)
			pos.z += CHARACTER_HEIGHT_M * 0.50 + 0.06 * math.sin(r.world_t * 2.07 + phase)
			fs_params.wisps[k] = {pos.x, pos.y, pos.z, f32(u8(remote.team)) + hp}
		}
	}

	for i in 0..<min(world.projectile_count, MAX_SNAPSHOT_PROJECTILES) {
		cp := &world.projectiles[i]
		pos := client_projectile_pos(cp, world.local_time)
		radius := clampf(cp.snap.radius, 0.05, 0.95)
		fs_params.projectiles[i] = {pos.x, pos.y, pos.z, spell_type_code(cp.snap.spell_id) + radius}
		fs_params.proj_vel[i] = {cp.snap.vel.x, cp.snap.vel.y, cp.snap.vel.z, 0}
	}

	for i in 0..<MAX_CLIENT_IMPACTS {
		im := &world.impacts[i]
		if !im.live {
			continue
		}
		fs_params.impacts[i] = {im.pos.x, im.pos.y, im.pos.z, spell_type_code(im.spell) + clampf(im.age, 0.01, 0.99)}
	}

	for i in 0..<MAX_CLIENT_STRIKES {
		s := &world.strikes[i]
		if !s.live {
			continue
		}
		fs_params.lightning[i] = {s.pos.x, s.pos.y, s.pos.z, clampf(s.life, 0.01, 1)}
	}

	if client_world_beams_current(world) {
		for i in 0..<world.beam_count {
			b := &world.beams[i]
			from: vec3
			to := b.end
		beam_spell_id := b.spell_id
		if b.owner_id == world.local_entity_id {
			if !playing || dead > 0.5 {
				continue
			}
			// Leaves the hand orb and lands where the crosshair says, traced
			// this frame the way the server will trace it.
			from = {fs_params.hand_pos.x, fs_params.hand_pos.y, fs_params.hand_pos.z}
			trace_eye := base_pos + vec3{0, 0, PLAYER_EYE_M}
			// Use the spell the client is actually channeling for responsive prediction.
			beam_spell := gc.charging_spell if spell_valid(gc.charging_spell) && SPELL_DEFS[gc.charging_spell].payload == .Beam else .Thunderbolt
			to = client_world_beam_end(world, &SPELL_DEFS[beam_spell], trace_eye, camera_forward(gc.view_yaw, gc.view_pitch))
			beam_spell_id = beam_spell
		} else {
			remote := &world.remote_entities[int(b.owner_id)]
			if !remote.active {
				continue
			}
			from = remote.display_state.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.55}
		}
		// Pass spell ID to shader for color (heal = soft green, damage = electric blue).
		fs_params.beams[i] = {from.x, from.y, from.z, f32(beam_spell_id)}
			fs_params.beam_ends[i] = {to.x, to.y, to.z, b.hit ? 1 : 0}
			// Chains arc to bodies, so they follow the interpolated remotes
			// rather than a position that was true a snapshot ago.
			for c in 0..<min(int(b.chain_count), BEAM_MAX_CHAINS) {
				target := &world.remote_entities[int(b.chains[c])]
				if !target.active {
					continue
				}
				p := target.display_state.pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
				fs_params.beam_chains[i * BEAM_MAX_CHAINS + c] = {p.x, p.y, p.z, 1}
			}
		}
	}

	// --- Draw -----------------------------------------------------------------
	client_renderer_overlay(r, gc)

	sg.begin_pass({action = r.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(r.pip)
	sg.apply_bindings(r.bind)
	sg.apply_uniforms(UB_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
	sg.apply_uniforms(UB_fs_params, {ptr = &fs_params, size = size_of(fs_params)})
	sg.draw(0, 3, 1)
	sdtx.draw()
	sg.end_pass()
	sg.commit()

	r.frame_ms = f32(time.duration_milliseconds(time.tick_since(t0)))
	r.fps_accum += sapp.frame_duration()
	r.fps_presents += 1
	if r.fps_accum >= 0.5 {
		r.last_fps = f32(r.fps_presents) / f32(r.fps_accum)
		r.fps_accum = 0
		r.fps_presents = 0
	}
	r.perf_accum += sapp.frame_duration()
	r.perf_frames += 1
	if r.perf_accum >= 5.0 {
		wisps := 0
		for i in 0..<16 {
			if fs_params.wisps[i].w > 0.5 {
				wisps += 1
			}
		}
		fmt.printf("[Perf] %.0f fps avg over %.0fs (%d wisps, %d projectiles, %dx%d)\n",
			f64(r.perf_frames) / r.perf_accum, r.perf_accum, wisps, world.projectile_count, sapp.width(), sapp.height())
		r.perf_accum = 0
		r.perf_frames = 0
	}
}

// ---------------------------------------------------------------------------
// HUD

@(private = "file")
sdtx_color :: proc(c: vec3) {
	sdtx.color3f(c.x, c.y, c.z)
}

@(private = "file")
sdtx_str :: proc(text: string) {
	sdtx.puts(strings.clone_to_cstring(text, context.temp_allocator))
}

@(private = "file")
hud_center_text :: proc(cols: f32, row: f32, text: string) {
	col := cols * 0.5 - f32(len(text)) * 0.5
	sdtx.pos(max(col, 0), row)
	sdtx_str(text)
}

client_renderer_overlay :: proc(r: ^Client_Renderer, gc: ^Game_Client) {
	w := sapp.widthf() * SDTX_CANVAS_SCALE
	h := sapp.heightf() * SDTX_CANVAS_SCALE
	cols := w / SDTX_CHAR_PX - 2 * SDTX_ORIGIN_CELLS
	rows := h / SDTX_CHAR_PX - 2 * SDTX_ORIGIN_CELLS
	sdtx.canvas(w, h)
	sdtx.origin(SDTX_ORIGIN_CELLS, SDTX_ORIGIN_CELLS)
	sdtx.home()
	sdtx.font(0)

	world := &gc.client_world

	// Stats line (always)
	sdtx.color3f(0.78, 0.76, 0.70)
	sdtx.printf("NEXUS ARENA  %.0f fps  %.1f ms", r.last_fps, r.frame_ms)
	if gc.phase == .Playing {
		rate, total := client_prediction_stats(&world.prediction)
		_, _, since := network_client_stats(&gc.network)
		sdtx.color3f(0.55, 0.53, 0.50)
		sdtx.printf("   corr %.1f%% (%d)  last pkt %.0fms  tick %d", rate * 100, total, since, world.client_tick)
	}
	sdtx.puts("\n")

	switch gc.phase {
	case .Connecting:
		hud_lobby_frame(gc, cols, rows, "SEARCHING FOR SERVER...")
	case .Team_Select:
		hud_lobby_frame(gc, cols, rows, "CHOOSE YOUR TEAM")
	case .Joining:
		hud_lobby_frame(gc, cols, rows, fmt.tprintf("JOINING %s...", team_name(gc.chosen_team)))
	case .Playing:
		hud_playing(gc, cols, rows)
	}
}

@(private = "file")
hud_lobby_frame :: proc(gc: ^Game_Client, cols, rows: f32, title: string) {
	sdtx.color3f(0.95, 0.93, 0.86)
	hud_center_text(cols, rows * 0.28, "N E X U S   A R E N A")
	sdtx.color3f(0.62, 0.60, 0.68)
	hud_center_text(cols, rows * 0.28 + 1, "three teams. four obelisks. one nexus.")

	sdtx.color3f(0.90, 0.88, 0.80)
	hud_center_text(cols, rows * 0.42, title)

	if gc.phase == .Team_Select || gc.phase == .Joining {
		base_row := rows * 0.42 + 3
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			allowed := client_team_allowed(gc, team)
			humans := int(gc.lobby.humans[i])
			bots := int(gc.lobby.bots[i])
			col := team_color(team)
			if !allowed {
				col = col * 0.35 + vec3{0.2, 0.2, 0.2}
			}
			sdtx_color(col)
			line := fmt.tprintf("[%d]  %-8s  %d players  %d bots%s", i + 1, team_name(team), humans, bots,
				allowed ? "" : "   (most populated - locked)")
			hud_center_text(cols, base_row + f32(i) * 2, line)
		}
		sdtx.color3f(0.55, 0.53, 0.50)
		hud_center_text(cols, base_row + 7, "press 1, 2 or 3 to join  -  you cannot join the most populated team")
		if gc.reject_timer > 0 {
			sdtx.color3f(1.0, 0.55, 0.45)
			msg := "that team is full or the most populated - pick another"
			#partial switch gc.reject_reason {
			case .Server_Full:  msg = "server is full"
			case .Invalid_Team: msg = "invalid team"
			}
			hud_center_text(cols, base_row + 9, msg)
		}
	}

	sdtx.color3f(0.42, 0.40, 0.38)
	hud_center_text(cols, rows - 1, fmt.tprintf("WASD move  /  Shift sprint  /  Space jump  /  1-%d spells  /  LMB cast  /  Esc unlock mouse", HOTBAR_SLOTS))
}

@(private = "file")
hud_playing :: proc(gc: ^Game_Client, cols, rows: f32) {
	world := &gc.client_world
	pred := &world.prediction
	local := pred.predicted_char
	gs := &world.game_state

	// --- Match header (top center) --------------------------------------------
	if world.have_game_state {
		state := Match_State(gs.match_state)
		status := ""
		switch state {
		case .Waiting:
			status = fmt.tprintf("WARMUP  %d", int(max(WARMUP_DURATION - gs.match_time, 0)))
		case .Active:
			m := int(gs.match_time) / 60
			s := int(gs.match_time) % 60
			status = fmt.tprintf("%02d:%02d", m, s)
		case .Ended:
			if Match_Result(gs.match_result) == .Team_Wins {
				status = fmt.tprintf("%s WINS", team_name(Team_ID(gs.winner)))
			} else {
				status = "DRAW"
			}
		}
		sdtx.color3f(0.95, 0.93, 0.86)
		hud_center_text(cols, 1, status)

		// Scores
		line_w: f32 = 0
		parts: [TEAM_COUNT]string
		for i in 0..<TEAM_COUNT {
			parts[i] = fmt.tprintf("%s %4.0f", team_name(team_from_index(i)), gs.essence[i])
			line_w += f32(len(parts[i]))
		}
		line_w += 3 * 2
		col := cols * 0.5 - line_w * 0.5
		sdtx.pos(col, 2)
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			sdtx_color(team_color(team))
			if team == world.local_team {
				sdtx.puts(">")
			} else {
				sdtx.puts(" ")
			}
			sdtx_str(parts[i])
			if i < TEAM_COUNT - 1 {
				sdtx.color3f(0.5, 0.5, 0.5)
				sdtx.puts(" /")
			}
		}

		// Obelisks: C = center, then lane owners
		sdtx.pos(cols * 0.5 - 9, 3)
		for i in 0..<MAX_OBELISKS {
			o := &gs.obelisks[i]
			owner := Team_ID(o.owner)
			st := Obelisk_State(o.state)
			sdtx_color(owner == .None ? vec3{0.5, 0.5, 0.5} : team_color(owner))
			label := i == 0 ? "C" : fmt.tprintf("%d", i)
			switch st {
			case .Neutral:   sdtx.printf("[%s -  ]", label)
			case .Contested: sdtx.printf("[%s !! ]", label)
			case .Capturing:
				sdtx_color(team_color(Team_ID(o.capturing)))
				sdtx.printf("[%s %2d%%]", label, int(o.progress * 100))
			case .Held:      sdtx.printf("[%s ## ]", label)
			}
			sdtx.puts(" ")
		}
	}

	// --- Vitals (bottom left) --------------------------------------------------
	hud_y := rows - 8
	sdtx.pos(0, hud_y)
	sdtx.color3f(1.0, 0.42, 0.36)
	sdtx.puts("HP ")
	draw_bar(local.health, HEALTH_MAX, 22)
	sdtx.printf(" %3.0f", local.health)

	sdtx.pos(0, hud_y + 1)
	sdtx.color3f(0.45, 0.66, 1.0)
	sdtx.puts("MP ")
	draw_bar(local.mana, MANA_MAX, 22)
	sdtx.printf(" %3.0f", local.mana)

	sdtx.pos(0, hud_y + 2)
	sdtx.color3f(0.55, 0.9, 0.5)
	sdtx.puts("ST ")
	draw_bar(local.stamina, STAMINA_MAX, 22)
	sdtx.printf(" %3.0f", local.stamina)

	if local.slow_ticks > 0 {
		sdtx.pos(0, hud_y + 3)
		sdtx.color3f(0.5, 0.92, 1.0)
		sdtx.puts("SLOWED")
	}

	// --- Hotbar (bottom center) ------------------------------------------------
	slot_w: f32 = 14
	start := cols * 0.5 - slot_w * f32(HOTBAR_SLOTS) * 0.5
	_, have_strike_target := client_world_strike_target(world)
	for i in 0..<HOTBAR_SLOTS {
		spell := HOTBAR[i]
		def := &SPELL_DEFS[spell]
		cd := gc.cooldowns[spell]
		selected := i == gc.selected_slot
		ready := spell_castable(spell, local, cd)
		col := start + f32(i) * slot_w

		sdtx.pos(col, rows - 3)
		if selected {
			sdtx.color3f(1.0, 0.95, 0.6)
			sdtx.printf("[%d] %-8s", i + 1, def.short_name)
		} else {
			sdtx.color3f(0.6, 0.58, 0.54)
			sdtx.printf(" %d  %-8s", i + 1, def.short_name)
		}

		sdtx.pos(col, rows - 2)
		if spell == gc.charging_spell && def.payload == .Beam {
			// A beam has no wind-up to show; the bar crackles while the server
			// keeps it lit and the mana drain, drawn to its right, is the
			// thing to watch.
			_, lit := client_world_local_beam(world)
			if lit {
				sdtx.color3f(0.75, 0.88, 1.0)
			} else {
				sdtx.color3f(0.45, 0.5, 0.6)
			}
			phase := int(world.local_time * 24)
			for k in 0..<10 {
				sdtx.putc((k + phase) % 3 == 0 ? '~' : '#')
			}
			sdtx.printf(" -%.0f/s", def.beam_mana_per_sec)
		} else if spell == gc.charging_spell {
			// Wind-up: dim until the release would actually produce a cast,
			// bright once it is past the minimum charge.
			charge := spell_charge_frac(def, gc.charge_accum)
			if charge < SPELL_MIN_CHARGE {
				sdtx.color3f(0.45, 0.5, 0.6)
			} else {
				sdtx.color3f(0.3, 0.85, 1.0)
			}
			filled := int(charge * 10)
			for k in 0..<10 {
				sdtx.putc(k < filled ? '#' : '.')
			}
			sdtx.printf(" %3.0f%%", charge * 100)
		} else if cd > 0 {
			sdtx.color3f(0.45, 0.45, 0.5)
			frac := 1.0 - cd / def.cooldown_sec
			filled := int(frac * 10)
			for k in 0..<10 {
				sdtx.putc(k < filled ? '=' : '.')
			}
			sdtx.printf(" %.1f", cd)
		} else if !ready {
			sdtx.color3f(0.45, 0.55, 0.85)
			sdtx.printf("need %.0f mp", def.mana_cost)
		} else if def.payload == .Strike && !have_strike_target {
			// Affordable and off cooldown, but nobody under the crosshair.
			sdtx.color3f(0.6, 0.6, 0.65)
			sdtx.puts("no target")
		} else {
			sdtx.color3f(0.5, 0.75, 0.55)
			sdtx.puts("==========")
		}
	}

	// --- Center ----------------------------------------------------------------
	cx := cols * 0.5
	cy := rows * 0.5
	if local.dead {
		sdtx.color3f(1.0, 0.5, 0.45)
		hud_center_text(cols, cy - 1, "YOU WERE UNMADE")
		sdtx.color3f(0.8, 0.78, 0.72)
		hud_center_text(cols, cy + 1, fmt.tprintf("respawning in %.0f", max(local.respawn_timer, 0)))
	} else {
		if world.hit_marker > 0.05 {
			sdtx.color3f(1.0, 0.9, 0.5)
			sdtx.pos(cx - 1, cy - 1); sdtx.puts("\\ /")
			sdtx.pos(cx - 1, cy + 1); sdtx.puts("/ \\")
		}
		sdtx.color3f(0.85, 0.83, 0.78)
		sdtx.pos(cx, cy)
		sdtx.puts("+")
		hud_target_panel(world, cols, cy + 2)
	}

	if !sapp.mouse_locked() {
		sdtx.color3f(0.95, 0.9, 0.7)
		hud_center_text(cols, cy + 4, "click to capture the mouse")
	}

	if world.have_game_state && Match_State(gs.match_state) == .Waiting {
		sdtx.color3f(0.7, 0.68, 0.62)
		hud_center_text(cols, 5, "hold obelisks to gather essence - the center is worth double")
	}
}

// Who the crosshair is holding, under the crosshair: name in team colour over a
// health bar. Nothing is drawn when there is no target, so the centre of the
// screen stays clean while the player is just moving around.
@(private = "file")
hud_target_panel :: proc(world: ^Client_World, cols: f32, row: f32) {
	if world.target_id == INVALID_ENTITY {
		return
	}
	remote := &world.remote_entities[world.target_id]

	sdtx_color(team_color(remote.team))
	hud_center_text(cols, row, entity_display_name(remote.id, remote.is_bot))

	hp := remote.display_state.health
	frac := hp / HEALTH_MAX
	if frac > 0.6 {
		sdtx.color3f(0.5, 0.9, 0.5)
	} else if frac > 0.3 {
		sdtx.color3f(1.0, 0.8, 0.3)
	} else {
		sdtx.color3f(1.0, 0.4, 0.3)
	}
	sdtx.pos(cols * 0.5 - 10, row + 1)  // 16-cell bar plus " 100" centres at -10
	draw_bar(hp, HEALTH_MAX, 14)
	sdtx.printf(" %3.0f", hp)
}

draw_bar :: proc(value: f32, max_value: f32, width: int) {
	filled := int((value / max_value) * f32(width) + 0.5)
	filled = clamp(filled, 0, width)
	sdtx.putc('[')
	for i in 0..<filled {
		sdtx.putc('=')
	}
	for i in filled..<width {
		sdtx.putc(' ')
	}
	sdtx.putc(']')
}
