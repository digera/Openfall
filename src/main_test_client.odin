package main

// Headless client test: joins the least populated team, drives a circular
// movement pattern for 30 seconds and reports prediction/network stats.

import "core:fmt"
import "core:time"
import "core:math"
import "core:math/rand"
import "core:os"

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
	player_name:   Player_Name,
	fight:         bool,

	// Wall handling for fight mode. Walking straight at the middle of the
	// arena runs into cover; when that happens, veer for a while.
	stuck_ref:     vec3,
	stuck_timer:   f32,
	detour:        f32,
	detour_timer:  f32,
}

main :: proc() {
	fmt.println("=== Nexus Arena - Headless Client Test ===")

	client := Test_Client{}
	// NEXUS_TEST_NAME lets two of these be told apart in the roster.
	{
		buf: [64]u8
		requested := os.get_env_buf(buf[:], "NEXUS_TEST_NAME")
		if requested == "" {
			requested = "TestBot"
		}
		player_name_set(&client.player_name, requested)
	}
	// NEXUS_TEST_FIGHT walks to the middle and shoots, which is the only way
	// to exercise the combat log and the scoreline from a headless client.
	{
		buf: [8]u8
		client.fight = os.get_env_buf(buf[:], "NEXUS_TEST_FIGHT") != ""
	}
	if !network_client_init(&client.network, "localhost", server_port_from_env()) {
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
			case .Server_Roster:
				roster := packet.roster
				client_world_apply_roster(&client.client_world, &roster)
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
			network_client_send_join(&client.network, client.chosen_team, client.player_name)
			client.phase = .Joining
			last_hello = time.tick_now()
		case .Joining:
			if time.tick_since(last_hello) > time.Millisecond * 400 {
				network_client_send_join(&client.network, client.chosen_team, client.player_name)
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
				if client.fight {
					input = test_client_fight_input(&client)
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

// Head for the middle of the arena and keep an Arcane Missile winding at the
// nearest hostile body. `cast_spell` every tick is a standing commit: the
// server fires it the moment the bar is full and the wind-up starts again.
test_client_fight_input :: proc(client: ^Test_Client) -> Input_State {
	world := &client.client_world
	me := world.prediction.predicted_char

	target := INVALID_ENTITY
	best: f32 = 1e30
	for i in 1..<MAX_ENTITIES {
		remote := &world.remote_entities[i]
		if !remote.active || remote.display_state.dead {
			continue
		}
		if !teams_are_enemies(world.local_team, remote.team) {
			continue
		}
		d := len2_vec3(remote.display_state.pos - me.pos)
		if d < best {
			best = d
			target = remote.id
		}
	}

	// Aim at the target if there is one, otherwise at the centre we are
	// walking toward.
	aim_at := vec3{0, 0, 0}
	if target != INVALID_ENTITY {
		aim_at = world.remote_entities[target].display_state.pos
	}
	to := aim_at - me.pos
	client.view_yaw = wrap_angle(math.atan2(to.y, to.x))

	// Have we got anywhere lately?
	client.stuck_timer += SIMULATION_DT
	if client.stuck_timer >= 0.5 {
		if len2_vec3(me.pos - client.stuck_ref) < 0.25 && client.detour_timer <= 0 {
			client.detour = rand.float32() < 0.5 ? -1.2 : 1.2
			client.detour_timer = 1.5
		}
		client.stuck_ref = me.pos
		client.stuck_timer = 0
	}
	move_yaw := client.view_yaw
	if client.detour_timer > 0 {
		client.detour_timer -= SIMULATION_DT
		move_yaw = wrap_angle(client.view_yaw + client.detour)
	}

	eye := me.pos + vec3{0, 0, PLAYER_EYE_M}
	chest := aim_at + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
	dz := chest.z - eye.z
	flat := math.sqrt(to.x * to.x + to.y * to.y)
	pitch := flat > 0.01 ? math.atan2(dz, flat) : 0

	// Movement axes are relative to where we are looking, so project the
	// direction we want to walk onto the look frame rather than assuming one.
	want := vec3{math.cos(move_yaw), math.sin(move_yaw), 0}
	look := camera_forward(client.view_yaw, 0)
	right := camera_right(client.view_yaw)

	return Input_State{
		move_fwd     = dot_vec3(want, look),
		move_str     = dot_vec3(want, right),
		sprint       = true,
		jump         = client.client_world.client_tick % 180 == 0,
		yaw          = client.view_yaw,
		pitch        = clampf(pitch, -CAM_PITCH_MAX, CAM_PITCH_MAX),
		charge_spell = .Arcane_Missile,
		cast_spell   = .Arcane_Missile,
		target_id    = target,
	}
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

	roster_count := 0
	for i in 1..<MAX_ENTITIES {
		if client.client_world.roster[i].present {
			roster_count += 1
		}
	}

	fmt.printf("[Stats @ %.1fs] %v | Pos (%.2f,%.2f,%.2f) | Predictions %d (%.1f%% corrected) | Net %d/%d pkts, last recv %.0fms | Remotes %d | Roster %d\n",
		client.test_duration, client.phase,
		local_char.pos.x, local_char.pos.y, local_char.pos.z,
		total, rate * 100, sent, recv, since, remote_count, roster_count)

	test_client_print_roster(client)
	test_client_print_combat_log(client)
}

// The scoreboard the graphical client draws behind Tab, as text.
test_client_print_roster :: proc(client: ^Test_Client) {
	world := &client.client_world
	for i in 1..<MAX_ENTITIES {
		slot := &world.roster[i]
		if !slot.present {
			continue
		}
		id := Entity_ID(i)
		fmt.printf("    %-8s %-18s k %d  d %d  dealt %.0f  taken %.0f%s\n",
			team_name(slot.team), client_world_name(world, id),
			slot.stats.kills, slot.stats.deaths,
			slot.stats.damage_dealt, slot.stats.damage_taken,
			id == world.local_entity_id ? "  <- me" : "")
	}
}

test_client_print_combat_log :: proc(client: ^Test_Client) {
	world := &client.client_world
	for i in 0..<MAX_COMBAT_LOG_LINES {
		line := &world.combat_log[i]
		if !line.live {
			continue
		}
		fmt.printf("    [log] %v %s dmg %d (%s) age %.1fs\n",
			line.event_type, client_world_name(world, line.other_id),
			line.damage, SPELL_DEFS[line.spell_id].short_name, line.age)
	}
}
