package main

// Graphical client: connection state machine, fixed-step prediction with
// render interpolation, input, and hand-off to the renderer.

import "core:fmt"
import "core:math"
import "core:os"
import "base:runtime"
import sapp "sokol:app"
import slog "sokol:log"

HELLO_INTERVAL   :: f32(0.5)
JOIN_INTERVAL    :: f32(0.4)
LOBBY_REFRESH    :: f32(1.0)
CONNECTION_LOSS_SEC :: f64(5.0)

Game_Client :: struct {
	network:        Network_Client,
	phase:          Client_Phase,
	client_world:   Client_World,
	renderer:       Client_Renderer,
	fx:             Camera_FX,

	// Look (client-authoritative, never overwritten by the server)
	view_yaw:       f32,
	view_pitch:     f32,

	// Movement input carried between frames
	move_input:     Input_State,
	selected_slot:  int,              // index into HOTBAR

	// Fixed-step accumulator
	sim_accum:      f32,
	render_alpha:   f32,

	// Redundant input history (newest first)
	input_history:  [INPUT_REDUNDANCY]Input_State,
	history_count:  int,

	// Lobby
	lobby:          Server_Lobby_Packet,
	have_lobby:     bool,
	chosen_team:    Team_ID,
	hello_timer:    f32,
	join_timer:     f32,
	reject_timer:   f32,
	reject_reason:  Lobby_Reject,
	last_packet_time: f64,

	// Local cooldown mirror (server is authoritative; this drives the HUD)
	cooldowns:      [Spell_ID]f32,
	cast_pulse:     f32,
	last_cast:      Spell_ID,
	charging_spell: Spell_ID,
	charge_accum:   f32,
}

game_client: Game_Client

client_init :: proc "c" () {
	context = runtime.default_context()
	fmt.println("=== Nexus Arena Client ===")

	server_host := DEFAULT_SERVER_HOST
	ip_buf: [256]u8
	if env_ip := os.get_env_buf(ip_buf[:], "SERVER_IP"); env_ip != "" {
		server_host = env_ip
	}
	if !network_client_init(&game_client.network, server_host, SERVER_PORT) {
		fmt.eprintln("Failed to initialize network client")
		return
	}

	loss_buf: [64]u8
	if v := os.get_env_buf(loss_buf[:], "NEXUS_SIM_LOSS"); v != "" {
		network_client_sim_loss(&game_client.network, 0.05)
	}

	game_client.client_world = client_world_init()
	game_client.phase = .Connecting
	game_client.selected_slot = 0
	game_client.last_packet_time = 0
	camera_fx_init(&game_client.fx)

	client_renderer_init(&game_client.renderer)
	fmt.println("Client initialized, looking for server...")
}

client_frame :: proc "c" () {
	context = runtime.default_context()

	gc := &game_client
	dt := f32(clamp(sapp.frame_duration(), 0.0, 0.1))
	gc.client_world.local_time += f64(dt)

	client_poll_network(gc)

	switch gc.phase {
	case .Connecting:
		client_release_mouse()
		gc.hello_timer -= dt
		if gc.hello_timer <= 0 {
			network_client_send_hello(&gc.network)
			gc.hello_timer = HELLO_INTERVAL
		}

	case .Team_Select:
		client_release_mouse()
		gc.hello_timer -= dt
		if gc.hello_timer <= 0 {
			network_client_send_hello(&gc.network)
			gc.hello_timer = LOBBY_REFRESH
		}
		gc.reject_timer = max(gc.reject_timer - dt, 0)
		for slot in 1..=TEAM_COUNT {
			if input_consume_slot(slot) {
				team := team_from_index(slot - 1)
				if client_team_allowed(gc, team) {
					gc.chosen_team = team
					network_client_send_join(&gc.network, team)
					gc.join_timer = JOIN_INTERVAL
					gc.phase = .Joining
				} else {
					gc.reject_reason = .Team_Most_Populated
					gc.reject_timer = 2.0
				}
			}
		}
		for slot in TEAM_COUNT + 1..=HOTBAR_SLOTS {
			_ = input_consume_slot(slot)
		}
		_ = input_consume_click()

	case .Joining:
		client_release_mouse()
		gc.join_timer -= dt
		if gc.join_timer <= 0 {
			network_client_send_join(&gc.network, gc.chosen_team)
			gc.join_timer = JOIN_INTERVAL
		}

	case .Playing:
		if gc.client_world.local_time - gc.last_packet_time > CONNECTION_LOSS_SEC {
			fmt.println("[Client] Connection lost, returning to lobby")
			client_reset_to_lobby(gc)
			break
		}
		client_handle_input(gc, dt)
		client_step_simulation(gc, dt)
	}

	client_world_update(&gc.client_world, dt)
	client_update_target(gc)
	camera_fx_update(&gc.fx, gc, dt)

	for spell in Spell_ID {
		gc.cooldowns[spell] = max(gc.cooldowns[spell] - dt, 0)
	}
	gc.cast_pulse = max(gc.cast_pulse - dt * 3.5, 0)

	client_renderer_draw(&gc.renderer, gc)
}

client_cleanup :: proc "c" () {
	context = runtime.default_context()
	network_client_shutdown(&game_client.network)
	client_renderer_shutdown(&game_client.renderer)

	rate, total := client_prediction_stats(&game_client.client_world.prediction)
	fmt.printf("[Client] Prediction: %d ticks, %.1f%% corrected\n", total, rate * 100)
	sent, recv, _ := network_client_stats(&game_client.network)
	fmt.printf("[Client] Network: %d sent, %d recv\n", sent, recv)
}

// ---------------------------------------------------------------------------

@(private = "file")
client_release_mouse :: proc() {
	if sapp.mouse_locked() {
		sapp.lock_mouse(false)
	}
	_, _ = input_consume_look()
}

client_team_allowed :: proc(gc: ^Game_Client, team: Team_ID) -> bool {
	if !gc.have_lobby {
		return true
	}
	counts: [TEAM_COUNT]int
	for i in 0..<TEAM_COUNT {
		counts[i] = int(gc.lobby.humans[i])
	}
	idx := team_index(team)
	if idx < 0 || counts[idx] >= int(gc.lobby.team_size) {
		return false
	}
	return team_join_allowed(counts, team)
}

client_reset_to_lobby :: proc(gc: ^Game_Client) {
	client_world_reset_session(&gc.client_world)
	gc.phase = .Connecting
	gc.have_lobby = false
	gc.hello_timer = 0
	gc.history_count = 0
	gc.sim_accum = 0
}

client_poll_network :: proc(gc: ^Game_Client) {
	for _ in 0..<64 {
		packet, ok := network_client_poll(&gc.network)
		if !ok {
			break
		}
		gc.last_packet_time = gc.client_world.local_time

		#partial switch packet.kind {
		case .Server_Lobby:
			gc.lobby = packet.lobby
			gc.have_lobby = true
			if packet.lobby.reject != .None {
				gc.reject_reason = packet.lobby.reject
				gc.reject_timer = 3.0
				if gc.phase == .Joining {
					gc.phase = .Team_Select
				}
			} else if gc.phase == .Connecting {
				gc.phase = .Team_Select
				fmt.println("[Client] Lobby received")
			}

		case .Server_Welcome:
			if gc.phase != .Playing {
				client_world_reset_session(&gc.client_world)
				gc.client_world.local_entity_id = packet.welcome.your_entity_id
				gc.client_world.local_team = packet.welcome.team
				gc.view_yaw = wrap_angle(team_angle(packet.welcome.team) + f32(math.PI))
				gc.view_pitch = 0
				gc.history_count = 0
				gc.sim_accum = 0
				gc.cooldowns = {}
				gc.phase = .Playing
				fmt.printf("[Client] Joined %s as entity %d\n", team_name(packet.welcome.team), packet.welcome.your_entity_id)
			}

		case .Server_Snapshot:
			if gc.phase == .Playing {
				snap := packet.snapshot
				client_world_apply_snapshot(&gc.client_world, &snap)
			}

		case .Server_GameState:
			gc.client_world.game_state = packet.gamestate
			gc.client_world.have_game_state = true
		}
	}
}

// Mouse look is applied to the view immediately (not quantized to sim ticks);
// movement keys are gathered into move_input for the next sim ticks.
client_handle_input :: proc(gc: ^Game_Client, dt: f32) {
	if !sapp.mouse_locked() {
		if input_consume_click() && input.window_focused {
			sapp.lock_mouse(true)
		}
		_, _ = input_consume_look()
		gc.move_input = {}
		_ = input_consume_jump()
		return
	}

	dx, dy := input_consume_look()
	gc.view_yaw = wrap_angle(gc.view_yaw - dx * CAM_LOOK_SENS)
	gc.view_pitch = clampf(gc.view_pitch - dy * CAM_LOOK_SENS, -CAM_PITCH_MAX, CAM_PITCH_MAX)

	fwd: f32 = 0
	str: f32 = 0
	if input.key_w { fwd += 1 }
	if input.key_s { fwd -= 1 }
	if input.key_d { str += 1 }
	if input.key_a { str -= 1 }
	l := math.sqrt(fwd * fwd + str * str)
	if l > 1 {
		fwd /= l
		str /= l
	}
	gc.move_input.move_fwd = fwd
	gc.move_input.move_str = str
	gc.move_input.sprint = input.key_shift
	// Hold Space to jump; also latch a press that landed between sim ticks.
	if input_consume_jump() || input.key_space {
		gc.move_input.jump = true
	}

	for slot in 1..=HOTBAR_SLOTS {
		if input_consume_slot(slot) {
			gc.selected_slot = slot - 1
		}
	}
}

// Aiming is the only thing that picks a target, so anything that stops the
// player aiming drops it the same way it drops a charge. When switching spells,
// clear the target if it's invalid for the new spell's filter, or retarget
// under the crosshair if a valid one is there.
client_update_target :: proc(gc: ^Game_Client) {
	pred := &gc.client_world.prediction
	if gc.phase != .Playing || !sapp.mouse_locked() || !pred.initialized || pred.predicted_char.dead {
		gc.client_world.target_id = INVALID_ENTITY
		return
	}
	// The cast origin the server will use, not the bobbing render camera.
	eye := pred.predicted_char.pos + vec3{0, 0, PLAYER_EYE_M}
	look := camera_forward(gc.view_yaw, gc.view_pitch)

	// Get the currently selected spell's filter
	spell := HOTBAR[gc.selected_slot]
	filter := SPELL_DEFS[spell].target_filter

	// If the current target doesn't match the new filter, clear it and try to retarget
	if !client_world_target_valid_for_spell(&gc.client_world, gc.client_world.target_id, filter) {
		gc.client_world.target_id = INVALID_ENTITY
	}

	client_world_acquire_target(&gc.client_world, eye, look, filter)
}

// Run as many 60Hz ticks as the accumulator allows, predicting locally and
// sending each input (with two previous ones) to the server.
client_step_simulation :: proc(gc: ^Game_Client, dt: f32) {
	gc.sim_accum += dt
	ticks := 0
	for gc.sim_accum >= FIXED_DT && ticks < 5 {
		gc.sim_accum -= FIXED_DT
		ticks += 1

		input := gc.move_input
		input.yaw = gc.view_yaw
		input.pitch = gc.view_pitch
		input.target_id = gc.client_world.target_id
		input.cast_spell, input.charge_spell = client_decide_cast(gc)

		qinput := input_quantize(input)
		gc.client_world.client_tick += 1
		client_prediction_step(&gc.client_world.prediction, gc.client_world.client_tick, qinput)

		// History shift (newest first)
		for i := INPUT_REDUNDANCY - 1; i > 0; i -= 1 {
			gc.input_history[i] = gc.input_history[i - 1]
		}
		gc.input_history[0] = qinput
		gc.history_count = min(gc.history_count + 1, INPUT_REDUNDANCY)

		packet := Client_Input_Packet{
			newest_tick = gc.client_world.client_tick,
			count       = u8(gc.history_count),
			inputs      = gc.input_history,
		}
		network_client_send_input(&gc.network, &packet)
	}
	if ticks == 5 && gc.sim_accum > FIXED_DT {
		gc.sim_accum = 0 // we fell too far behind; drop the remainder
	}
	if ticks > 0 {
		gc.move_input.jump = false
	}
	gc.render_alpha = gc.sim_accum / FIXED_DT
}

// Hold LMB to wind the selected spell up, release to throw it at whatever
// charge it reached. Mirrors the server's checks so the HUD stays responsive
// and we don't spam rejected casts; the server still times the charge itself.
client_decide_cast :: proc(gc: ^Game_Client) -> (cast_spell: Spell_ID, charge_spell: Spell_ID) {
	pred := &gc.client_world.prediction
	alive := pred.initialized && !pred.predicted_char.dead
	match_over := gc.client_world.have_game_state && Match_State(gc.client_world.game_state.match_state) == .Ended

	// Dying, unlocking the mouse or the match ending drop the wind-up on the
	// floor. Only letting go of the button fires.
	if !alive || match_over || !sapp.mouse_locked() {
		client_drop_charge(gc)
		return .None, .None
	}

	// The cast origin and look the server will judge a targeted spell by.
	eye := pred.predicted_char.pos + vec3{0, 0, PLAYER_EYE_M}
	look := camera_forward(gc.view_yaw, gc.view_pitch)

	if input.held_left {
		spell := HOTBAR[gc.selected_slot]
		def := &SPELL_DEFS[spell]
		if gc.charging_spell != spell {
			// A fresh hold, or the player swapped slots mid-charge. Picking the
			// spell up again once its cooldown ends is deliberate: holding
			// through the cooldown starts the next wind-up automatically.
			if !spell_castable(spell, pred.predicted_char, gc.cooldowns[spell]) {
				client_drop_charge(gc)
				return .None, .None
			}
			// A strike needs someone to call it on, in range, when it starts.
			// Cover is not asked about until the release: the target is free
			// to duck, and the caster is free to wait them out.
			if def.payload == .Strike {
				target, ok := client_world_strike_target(&gc.client_world)
				if !ok || !strike_target_in_range(def, eye, look, target.display_state.pos) {
					client_drop_charge(gc)
					return .None, .None
				}
			}
			gc.charging_spell = spell
			gc.charge_accum = 0
		}
		// Losing the target mid-hold (they died, or the crosshair moved on to
		// a teammate) drops the charge so the player can start over at once
		// rather than find out on release.
		if def.payload == .Strike {
			if _, ok := client_world_strike_target(&gc.client_world); !ok {
				client_drop_charge(gc)
				return .None, .None
			}
		}
		if def.payload == .Beam {
			// A beam is firing for as long as this is held, so the hand stays
			// lit. Mana reaching zero means the server has just put the beam
			// to rest; mirror the rest so the bar shows it, and let go of the
			// spell so holding through it relights the beam when it ends.
			gc.cast_pulse = max(gc.cast_pulse, 0.7)
			if pred.predicted_char.mana < 1 {
				gc.cooldowns[spell] = def.cooldown_sec
				client_drop_charge(gc)
				return .None, .None
			}
		}
		gc.charge_accum = min(gc.charge_accum + FIXED_DT, def.cast_time)
		return .None, gc.charging_spell
	}

	spell := gc.charging_spell
	if spell == .None {
		return .None, .None
	}
	def := &SPELL_DEFS[spell]
	charge := spell_charge_frac(def, gc.charge_accum)
	client_drop_charge(gc)
	// Letting go of a beam just puts it out; there is nothing to cast.
	if def.payload == .Beam || charge < SPELL_MIN_CHARGE {
		return .None, .None
	}
	// A strike whose target is out of reach fizzles here for the same reason
	// the server would refuse it, and without pretending a cooldown started.
	if def.payload == .Strike {
		target, ok := client_world_strike_target(&gc.client_world)
		if !ok || !strike_target_in_reach(def, eye, look, target.display_state.pos) {
			return .None, .None
		}
	}

	gc.cooldowns[spell] = def.cooldown_sec
	gc.cast_pulse = 1
	gc.last_cast = spell
	camera_fx_on_cast(&gc.fx, spell)
	return spell, .None
}

client_drop_charge :: proc(gc: ^Game_Client) {
	gc.charging_spell = .None
	gc.charge_accum = 0
}

main_client :: proc() {
	sapp.run({
		init_cb       = client_init,
		frame_cb      = client_frame,
		cleanup_cb    = client_cleanup,
		event_cb      = input_event,
		width         = WINDOW_W,
		height        = WINDOW_H,
		sample_count  = 1,
		high_dpi      = false,
		window_title  = "Nexus Arena",
		icon          = {sokol_default = true},
		logger        = {func = slog.func},
		swap_interval = 1,
	})
}

main :: proc() {
	main_client()
}
