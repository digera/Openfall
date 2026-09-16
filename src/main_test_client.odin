package main

// Headless client test: joins the least populated team, drives a circular
// movement pattern for 30 seconds and reports prediction/network stats.

import "core:fmt"
import "core:time"
import "core:math"

Test_Client :: struct {
	network:       Network_Client,
	client_world:  Client_World,
	phase:         Client_Phase,
	lobby:         Server_Lobby_Packet,
	chosen_team:   Team_ID,
	history:       [INPUT_REDUNDANCY]Input_State,
	history_count: int,
	view_yaw:      f32,
	test_duration: f64,
}

main :: proc() {
	fmt.println("=== Nexus Arena - Headless Client Test ===")

	client := Test_Client{}
	if !network_client_init(&client.network, "localhost", SERVER_PORT) {
		fmt.eprintln("Failed to initialize network client")
		return
	}
	network_client_sim_loss(&client.network, 0.02)

	client.client_world = client_world_init()
	client.phase = .Connecting

	test_start := time.tick_now()
	tick_interval := time.Duration(1_000_000_000 / SIMULATION_TICK_RATE)
	next_tick := time.tick_now()
	last_stats := time.tick_now()
	last_hello := time.tick_now()
	last_hello._nsec -= i64(time.Second)
	angle: f32 = 0

	for {
		now := time.tick_now()
		client.test_duration = f64(time.tick_diff(test_start, now)) / f64(time.Second)
		client.client_world.local_time = client.test_duration
		if client.test_duration >= 30 {
			break
		}

		for _ in 0..<32 {
			packet, ok := network_client_poll(&client.network)
			if !ok {
				break
			}
			#partial switch packet.kind {
			case .Server_Lobby:
				client.lobby = packet.lobby
				if packet.lobby.reject != .None {
					fmt.printf("[Test] Join rejected: %v\n", packet.lobby.reject)
					client.phase = .Team_Select
				} else if client.phase == .Connecting {
					client.phase = .Team_Select
				}
			case .Server_Welcome:
				if client.phase != .Playing {
					client.client_world.local_entity_id = packet.welcome.your_entity_id
					client.client_world.local_team = packet.welcome.team
					client.view_yaw = wrap_angle(team_angle(packet.welcome.team) + f32(math.PI))
					client.phase = .Playing
					fmt.printf("[Test] Joined %s as entity %d\n", team_name(packet.welcome.team), packet.welcome.your_entity_id)
				}
			case .Server_Snapshot:
				if client.phase == .Playing {
					snap := packet.snapshot
					client_world_apply_snapshot(&client.client_world, &snap)
				}
			case .Server_GameState:
				client.client_world.game_state = packet.gamestate
				client.client_world.have_game_state = true
			}
		}

		switch client.phase {
		case .Connecting:
			if time.tick_since(last_hello) > time.Millisecond * 500 {
				network_client_send_hello(&client.network)
				last_hello = time.tick_now()
			}
		case .Team_Select:
			// Pick the least populated team
			counts: [TEAM_COUNT]int
			best := 0
			for i in 0..<TEAM_COUNT {
				counts[i] = int(client.lobby.humans[i])
				if counts[i] < counts[best] {
					best = i
				}
			}
			client.chosen_team = team_from_index(best)
			network_client_send_join(&client.network, client.chosen_team)
			client.phase = .Joining
			last_hello = time.tick_now()
		case .Joining:
			if time.tick_since(last_hello) > time.Millisecond * 400 {
				network_client_send_join(&client.network, client.chosen_team)
				last_hello = time.tick_now()
			}
		case .Playing:
			if time.tick_since(next_tick) >= 0 {
				angle += 0.03
				client.view_yaw = wrap_angle(client.view_yaw + 0.01)
				input := Input_State{
					move_fwd = math.cos(angle),
					move_str = math.sin(angle),
					jump     = client.client_world.client_tick % 120 == 0,
					yaw      = client.view_yaw,
					pitch    = 0,
				}
				q := input_quantize(input)
				client.client_world.client_tick += 1
				client_prediction_step(&client.client_world.prediction, client.client_world.client_tick, q)

				for i := INPUT_REDUNDANCY - 1; i > 0; i -= 1 {
					client.history[i] = client.history[i - 1]
				}
				client.history[0] = q
				client.history_count = min(client.history_count + 1, INPUT_REDUNDANCY)
				packet := Client_Input_Packet{
					newest_tick = client.client_world.client_tick,
					count       = u8(client.history_count),
					inputs      = client.history,
				}
				network_client_send_input(&client.network, &packet)
				next_tick._nsec += i64(tick_interval)
			}
		}

		client_world_update(&client.client_world, 0.001)

		if time.tick_since(last_stats) >= time.Second * 5 {
			test_client_print_stats(&client)
			last_stats = time.tick_now()
		}
		time.sleep(time.Millisecond)
	}

	fmt.println("\n=== Test Complete ===")
	test_client_print_stats(&client)
	network_client_shutdown(&client.network)
}

test_client_print_stats :: proc(client: ^Test_Client) {
	local_char := client.client_world.prediction.predicted_char
	rate, total := client_prediction_stats(&client.client_world.prediction)
	sent, recv, since := network_client_stats(&client.network)

	remote_count := 0
	for i in 0..<MAX_ENTITIES {
		if client.client_world.remote_entities[i].active {
			remote_count += 1
		}
	}

	fmt.printf("[Stats @ %.1fs] %v | Pos (%.2f,%.2f,%.2f) | Predictions %d (%.1f%% corrected) | Net %d/%d pkts, last recv %.0fms | Remotes %d\n",
		client.test_duration, client.phase,
		local_char.pos.x, local_char.pos.y, local_char.pos.z,
		total, rate * 100, sent, recv, since, remote_count)
}
