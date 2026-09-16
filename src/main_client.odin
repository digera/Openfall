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
	selected_slot:  int,              // 0..3 into HOTBAR

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
}

game_client: Game_Client

client_init :: proc "c" () {
	context = runtime.default_context()
	fmt.println("=== Nexus Arena Client ===")

	server_host := "localhost"
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
		_ = input_consume_slot(4)
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

	for slot in 1..=4 {
		if input_consume_slot(slot) {
			gc.selected_slot = slot - 1
		}
	}
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
		input.cast_spell = client_decide_cast(gc)
		input.cast_held = input.held_left && sapp.mouse_locked()

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

// Decide whether this tick carries a cast. Mirrors the server's checks so
// the HUD cooldown is responsive and we don't spam rejected casts.
client_decide_cast :: proc(gc: ^Game_Client) -> Spell_ID {
	if !input.held_left || !sapp.mouse_locked() {
		return .None
	}
	pred := &gc.client_world.prediction
	if !pred.initialized || pred.predicted_char.dead {
		return .None
	}
	if gc.client_world.have_game_state && Match_State(gc.client_world.game_state.match_state) == .Ended {
		return .None
	}
	spell := HOTBAR[gc.selected_slot]
	def := &SPELL_DEFS[spell]

	// Beam channels: always send while held (mana check is per-tick on server)
	if def.payload == .Beam_Channel {
		gc.cast_pulse = 1
		gc.last_cast = spell
		return spell
	}

	// Regular spells: check cooldown and upfront mana cost
	if gc.cooldowns[spell] > 0 || pred.predicted_char.mana < def.mana_cost {
		return .None
	}
	gc.cooldowns[spell] = def.cooldown_sec
	gc.cast_pulse = 1
	gc.last_cast = spell
	camera_fx_on_cast(&gc.fx, spell)
	return spell
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
