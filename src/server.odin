package main

import "core:fmt"
import "core:time"
import "core:net"
import "core:os"
import "core:strconv"

// Headless dedicated server for Nexus Arena.
// - Fixed 60Hz deterministic tick
// - Three teams, bots fill each team up to TEAM_SIZE
// - Join handshake (Hello → Lobby → Join → Welcome)
// - Per-client interest-managed snapshots at 30Hz

MAX_CLIENTS   :: 16
TEAM_SIZE     :: 6          // humans + bots per team
INPUT_QUEUE   :: 32
INPUT_BUFFER_TARGET :: 3    // inputs we like to have queued (jitter buffer)
CLIENT_TIMEOUT_SEC :: 6.0

Client_Slot :: struct {
	addr:         net.Endpoint,
	entity_id:    Entity_ID,
	team:         Team_ID,
	last_packet:  time.Tick,

	// Pending inputs sorted by tick (ascending)
	input_ticks:  [INPUT_QUEUE]u32,
	inputs:       [INPUT_QUEUE]Input_State,
	input_count:  int,
	last_applied_tick: u32,
	has_applied:  bool,
}

Server :: struct {
	world:        Entity_World,
	network:      Network_Endpoint,
	tick_id:      u32,
	running:      bool,

	tick_times_ms: [60]f32,
	tick_idx:      int,
	total_ticks:   u64,
	start_time:    time.Tick,

	clients:       [MAX_CLIENTS]Client_Slot,
	client_count:  int,

	bots:          [MAX_BOTS]Bot,

	projectiles:   Projectile_World,
	lag_comp:      Lag_Comp_State,

	obelisks:      Obelisk_World,
	match:         Match,
}

server_init :: proc(port: u16) -> (server: Server, ok: bool) {
	fmt.println("=== Nexus Arena Headless Server ===")
	fmt.printf("Initializing on port %d, %d teams x %d slots\n", port, TEAM_COUNT, TEAM_SIZE)

	server.world = entity_world_init()
	server.start_time = time.tick_now()
	server.projectiles = projectile_world_init()
	server.lag_comp = lag_comp_init()
	server.obelisks = obelisk_world_init()
	server.match = match_init()

	// Test knobs: NEXUS_TEST_ESSENCE=50 (win threshold), NEXUS_TEST_FAST=10 (essence multiplier)
	{
		buf: [64]u8
		if v := os.get_env_buf(buf[:], "NEXUS_TEST_ESSENCE"); v != "" {
			if threshold, pok := strconv.parse_f32(v); pok && threshold > 0 {
				match_configure_test_mode(threshold, test_essence_multiplier)
			}
		}
	}
	{
		buf: [64]u8
		if v := os.get_env_buf(buf[:], "NEXUS_TEST_FAST"); v != "" {
			if mult, pok := strconv.parse_f32(v); pok && mult > 0 {
				match_configure_test_mode(test_essence_threshold, mult)
			}
		}
	}

	if port > 0 {
		if !network_init(&server.network, port) {
			fmt.eprintln("Warning: network init failed, running offline")
		}
	}

	bots_rebalance(&server)

	fmt.printf("Server ready: %d entities active\n", server.world.count)
	server.running = true
	return server, true
}

// ---------------------------------------------------------------------------
// Tick

server_tick :: proc(server: ^Server) {
	tick_start := time.tick_now()

	server_process_packets(server)
	server_check_timeouts(server)
	server_apply_client_inputs(server)

	bots_tick(server, SIMULATION_DT)

	server_update_resources(server, SIMULATION_DT)
	entity_tick_death_respawn(&server.world, SIMULATION_DT)

	simulate_world_step(&server.world)
	projectile_tick(&server.projectiles, &server.world, SIMULATION_DT)

	obelisk_tick(&server.obelisks, &server.world, SIMULATION_DT)
	if match_tick(&server.match, &server.obelisks, SIMULATION_DT) {
		server_round_reset(server)
	}

	for i in 1..<MAX_ENTITIES {
		if server.world.characters[i].active {
			lag_comp_record(&server.lag_comp, Entity_ID(i), server.world.characters[i].pos, server.tick_id)
		}
	}

	if server.tick_id % 2 == 0 {
		server_send_snapshots(server)
	}
	if server.tick_id % 6 == 0 {
		server_send_gamestate(server)
	}

	server.tick_id += 1
	server.total_ticks += 1

	tick_ms := f32(time.duration_milliseconds(time.tick_since(tick_start)))
	server.tick_times_ms[server.tick_idx] = tick_ms
	server.tick_idx = (server.tick_idx + 1) % len(server.tick_times_ms)
}

server_round_reset :: proc(server: ^Server) {
	obelisk_world_reset(&server.obelisks)
	projectile_clear_all(&server.projectiles)
	entity_respawn_all(&server.world)
	for i in 0..<MAX_BOTS {
		if server.bots[i].active {
			bot_reset_ai(&server.bots[i])
		}
	}
	fmt.println("[Server] Round reset: obelisks neutral, everyone respawned")
}

// ---------------------------------------------------------------------------
// Packets

server_process_packets :: proc(server: ^Server) {
	buffer: [MAX_PACKET_SIZE]u8

	for _ in 0..<200 {
		n, from, ok := network_receive(&server.network, buffer[:])
		if !ok {
			break
		}
		ptype, hdr_ok := packet_header(buffer[:n])
		if !hdr_ok {
			continue
		}

		slot := server_find_client(server, from)

		#partial switch ptype {
		case .Client_Hello:
			if slot >= 0 {
				server.clients[slot].last_packet = time.tick_now()
				server_send_welcome(server, slot)
			} else {
				server_send_lobby(server, from, .None)
			}

		case .Client_Join:
			join, jok := deserialize_client_join(buffer[:n])
			if !jok {
				continue
			}
			if slot >= 0 {
				// Already in: idempotent welcome
				server.clients[slot].last_packet = time.tick_now()
				server_send_welcome(server, slot)
				continue
			}
			reject := server_validate_join(server, join.team)
			if reject != .None {
				server_send_lobby(server, from, reject)
				continue
			}
			new_slot := server_register_client(server, from, join.team)
			if new_slot >= 0 {
				server_send_welcome(server, new_slot)
				server_send_gamestate_to(server, new_slot)
			} else {
				server_send_lobby(server, from, .Server_Full)
			}

		case .Client_Input:
			if slot < 0 {
				continue // unknown endpoint; it must Join first
			}
			pkt, pok := deserialize_client_input(buffer[:n])
			if !pok {
				continue
			}
			client := &server.clients[slot]
			client.last_packet = time.tick_now()
			for k in 0..<int(pkt.count) {
				tick := pkt.newest_tick - u32(k)
				client_queue_input(client, tick, pkt.inputs[k])
			}
		}
	}
}

server_find_client :: proc(server: ^Server, addr: net.Endpoint) -> int {
	for i in 0..<server.client_count {
		c := &server.clients[i]
		if c.addr.address == addr.address && c.addr.port == addr.port {
			return i
		}
	}
	return -1
}

// Insert an input into a client's sorted pending queue (dedup by tick).
client_queue_input :: proc(client: ^Client_Slot, tick: u32, input: Input_State) {
	if client.has_applied && tick <= client.last_applied_tick {
		return
	}
	for i in 0..<client.input_count {
		if client.input_ticks[i] == tick {
			return
		}
	}
	if client.input_count >= INPUT_QUEUE {
		// Drop the oldest
		for i in 0..<INPUT_QUEUE - 1 {
			client.input_ticks[i] = client.input_ticks[i + 1]
			client.inputs[i] = client.inputs[i + 1]
		}
		client.input_count -= 1
	}
	// Sorted insert
	pos := client.input_count
	for pos > 0 && client.input_ticks[pos - 1] > tick {
		client.input_ticks[pos] = client.input_ticks[pos - 1]
		client.inputs[pos] = client.inputs[pos - 1]
		pos -= 1
	}
	client.input_ticks[pos] = tick
	client.inputs[pos] = input
	client.input_count += 1
}

// Consume one queued input per client per tick. If the buffer runs long,
// skip ahead (keeping any cast intent); if it runs dry, repeat the last input.
server_apply_client_inputs :: proc(server: ^Server) {
	for i in 0..<server.client_count {
		client := &server.clients[i]
		id := client.entity_id
		if id == INVALID_ENTITY {
			continue
		}

		if client.input_count == 0 {
			server.world.inputs[id].cast_spell = .None
			continue
		}

		// Catch up if we've accumulated too much
		pending_cast := Spell_ID.None
		for client.input_count > INPUT_BUFFER_TARGET + 2 {
			if client.inputs[0].cast_spell != .None {
				pending_cast = client.inputs[0].cast_spell
			}
			client_pop_input(client)
		}

		input := client.inputs[0]
		tick := client.input_ticks[0]
		client_pop_input(client)
		client.last_applied_tick = tick
		client.has_applied = true

		if input.cast_spell == .None {
			input.cast_spell = pending_cast
		}
		server.world.inputs[id] = input

		if input.cast_spell != .None {
			server_handle_spell_cast(server, id, input.cast_spell, server.tick_id)
		}
	}
}

@(private = "file")
client_pop_input :: proc(client: ^Client_Slot) {
	if client.input_count == 0 {
		return
	}
	for i in 0..<client.input_count - 1 {
		client.input_ticks[i] = client.input_ticks[i + 1]
		client.inputs[i] = client.inputs[i + 1]
	}
	client.input_count -= 1
}

server_check_timeouts :: proc(server: ^Server) {
	for i := 0; i < server.client_count; {
		elapsed := time.duration_seconds(time.tick_since(server.clients[i].last_packet))
		if elapsed > CLIENT_TIMEOUT_SEC {
			fmt.printf("[Server] Client %v timed out (%.1fs), removing entity %d\n",
				server.clients[i].addr, elapsed, server.clients[i].entity_id)
			server_remove_client(server, i)
		} else {
			i += 1
		}
	}
}

server_remove_client :: proc(server: ^Server, idx: int) {
	entity_destroy(&server.world, server.clients[idx].entity_id)
	last := server.client_count - 1
	if idx != last {
		server.clients[idx] = server.clients[last]
	}
	server.clients[last] = {}
	server.client_count -= 1
	bots_rebalance(server)
}

// ---------------------------------------------------------------------------
// Join flow

server_human_counts :: proc(server: ^Server) -> [TEAM_COUNT]int {
	counts: [TEAM_COUNT]int
	for i in 0..<server.client_count {
		idx := team_index(server.clients[i].team)
		if idx >= 0 {
			counts[idx] += 1
		}
	}
	return counts
}

server_validate_join :: proc(server: ^Server, team: Team_ID) -> Lobby_Reject {
	if server.client_count >= MAX_CLIENTS {
		return .Server_Full
	}
	if team_index(team) < 0 {
		return .Invalid_Team
	}
	counts := server_human_counts(server)
	if counts[team_index(team)] >= TEAM_SIZE {
		return .Team_Most_Populated
	}
	if !team_join_allowed(counts, team) {
		return .Team_Most_Populated
	}
	return .None
}

server_register_client :: proc(server: ^Server, addr: net.Endpoint, team: Team_ID) -> int {
	if server.client_count >= MAX_CLIENTS {
		return -1
	}
	counts := server_human_counts(server)
	spawn_slot := counts[team_index(team)]
	spawn_pos := team_spawn_position(team, spawn_slot)
	yaw := wrap_angle(team_angle(team) + 3.14159265)

	player_id := entity_spawn(&server.world, spawn_pos, team, yaw)
	if player_id == INVALID_ENTITY {
		fmt.eprintln("[Server] Failed to spawn player entity")
		return -1
	}

	idx := server.client_count
	server.clients[idx] = Client_Slot{
		addr        = addr,
		entity_id   = player_id,
		team        = team,
		last_packet = time.tick_now(),
	}
	server.client_count += 1

	fmt.printf("[Server] Client %v joined %s as entity %d (%d clients)\n",
		addr, team_name(team), player_id, server.client_count)

	bots_rebalance(server)
	return idx
}

server_send_lobby :: proc(server: ^Server, to: net.Endpoint, reject: Lobby_Reject) {
	humans := server_human_counts(server)
	bots := bots_count_per_team(server)
	packet := Server_Lobby_Packet{team_size = TEAM_SIZE, reject = reject}
	for i in 0..<TEAM_COUNT {
		packet.humans[i] = u8(humans[i])
		packet.bots[i] = u8(bots[i])
	}
	buffer: [32]u8
	size := serialize_server_lobby(&packet, buffer[:])
	network_send(&server.network, buffer[:], size, to)
}

server_send_welcome :: proc(server: ^Server, slot: int) {
	client := &server.clients[slot]
	welcome := Server_Welcome_Packet{your_entity_id = client.entity_id, team = client.team}
	buffer: [16]u8
	size := serialize_server_welcome(&welcome, buffer[:])
	network_send(&server.network, buffer[:], size, client.addr)
}

// ---------------------------------------------------------------------------
// Snapshots (per client, nearest entities first, self always included)

server_send_snapshots :: proc(server: ^Server) {
	if server.client_count == 0 {
		return
	}
	buffer: [MAX_PACKET_SIZE]u8

	for ci in 0..<server.client_count {
		client := &server.clients[ci]
		self_id := client.entity_id
		self_pos := server.world.characters[self_id].pos

		snapshot := Server_Snapshot_Packet{
			tick_id        = server.tick_id,
			ack_input_tick = client.has_applied ? client.last_applied_tick : 0,
		}

		// Gather (dist², id) for active entities
		cand_ids:  [MAX_ENTITIES]Entity_ID
		cand_dist: [MAX_ENTITIES]f32
		cand_n := 0
		for i in 1..<MAX_ENTITIES {
			if !server.world.characters[i].active {
				continue
			}
			d := server.world.characters[i].pos - self_pos
			cand_ids[cand_n] = Entity_ID(i)
			cand_dist[cand_n] = Entity_ID(i) == self_id ? -1 : len2_vec3(d)
			cand_n += 1
		}
		// Partial selection of the nearest MAX_SNAPSHOT_ENTITIES
		take := min(cand_n, MAX_SNAPSHOT_ENTITIES)
		for k in 0..<take {
			best := k
			for j in k + 1..<cand_n {
				if cand_dist[j] < cand_dist[best] {
					best = j
				}
			}
			if best != k {
				cand_ids[k], cand_ids[best] = cand_ids[best], cand_ids[k]
				cand_dist[k], cand_dist[best] = cand_dist[best], cand_dist[k]
			}
			id := cand_ids[k]
			char := server.world.characters[id]
			snapshot.entities[k] = Snapshot_Entity{
				id         = id,
				pos        = char.pos,
				vel        = char.vel,
				yaw        = char.yaw,
				pitch      = char.pitch,
				on_ground  = char.on_ground,
				dead       = char.dead,
				health     = char.health,
				mana       = char.mana,
				stamina    = char.stamina,
				team       = server.world.teams[id],
				slow_ticks = char.slow_ticks,
			}
		}
		snapshot.entity_count = u8(take)

		// Nearest projectiles
		pidx:  [MAX_PROJECTILES]int
		pdist: [MAX_PROJECTILES]f32
		pn := 0
		for i in 0..<MAX_PROJECTILES {
			if !server.projectiles.projectiles[i].active {
				continue
			}
			pidx[pn] = i
			pdist[pn] = len2_vec3(server.projectiles.projectiles[i].pos - self_pos)
			pn += 1
		}
		ptake := min(pn, MAX_SNAPSHOT_PROJECTILES)
		for k in 0..<ptake {
			best := k
			for j in k + 1..<pn {
				if pdist[j] < pdist[best] {
					best = j
				}
			}
			if best != k {
				pidx[k], pidx[best] = pidx[best], pidx[k]
				pdist[k], pdist[best] = pdist[best], pdist[k]
			}
			proj := server.projectiles.projectiles[pidx[k]]
			snapshot.projectiles[k] = Snapshot_Projectile{
				id       = proj.id,
				spell_id = proj.spell_id,
				owner_id = proj.owner_id,
				pos      = proj.pos,
				vel      = proj.vel,
				lifetime = proj.lifetime,
				radius   = proj.radius,
			}
		}
		snapshot.projectile_count = u8(ptake)

		size := serialize_server_snapshot(&snapshot, buffer[:])
		if size > 0 {
			network_send(&server.network, buffer[:], size, client.addr)
		}
	}
}

server_build_gamestate :: proc(server: ^Server) -> Server_GameState_Packet {
	gs := Server_GameState_Packet{
		match_state  = u8(server.match.state),
		match_result = u8(server.match.result),
		winner       = u8(server.match.winner),
		essence      = server.match.essence,
		match_time   = server.match.match_time,
	}
	humans := server_human_counts(server)
	for i in 0..<TEAM_COUNT {
		gs.humans[i] = u8(humans[i])
	}
	for i in 0..<MAX_OBELISKS {
		o := &server.obelisks.obelisks[i]
		gs.obelisks[i] = Snapshot_Obelisk{
			state     = u8(o.state),
			owner     = u8(o.owner),
			capturing = u8(o.capturing_team),
			progress  = o.capture_progress,
		}
	}
	return gs
}

server_send_gamestate :: proc(server: ^Server) {
	if server.client_count == 0 {
		return
	}
	gs := server_build_gamestate(server)
	buffer: [128]u8
	size := serialize_server_gamestate(&gs, buffer[:])
	if size <= 0 {
		return
	}
	for i in 0..<server.client_count {
		network_send(&server.network, buffer[:], size, server.clients[i].addr)
	}
}

server_send_gamestate_to :: proc(server: ^Server, slot: int) {
	gs := server_build_gamestate(server)
	buffer: [128]u8
	size := serialize_server_gamestate(&gs, buffer[:])
	if size > 0 {
		network_send(&server.network, buffer[:], size, server.clients[slot].addr)
	}
}

// ---------------------------------------------------------------------------
// Resources & spells

server_update_resources :: proc(server: ^Server, dt: f32) {
	for i in 1..<MAX_ENTITIES {
		if !server.world.characters[i].active {
			continue
		}
		char := &server.world.characters[i]
		spell_state := &server.world.spell_states[i]

		if !char.dead {
			char.mana = min(char.mana + MANA_REGEN_PER_SEC * dt, MANA_MAX)
		}
		for spell_id in Spell_ID {
			if spell_state.cooldowns[spell_id] > 0 {
				spell_state.cooldowns[spell_id] = max(spell_state.cooldowns[spell_id] - dt, 0)
			}
		}
	}
}

// Validate and execute a spell cast. Returns true if the cast happened.
server_handle_spell_cast :: proc(server: ^Server, caster_id: Entity_ID, spell_id: Spell_ID, tick: u32) -> bool {
	if !entity_alive(&server.world, caster_id) {
		return false
	}
	if !spell_valid(spell_id) {
		return false
	}
	if server.match.state == .Ended {
		return false
	}

	def := &SPELL_DEFS[spell_id]
	spell_state := &server.world.spell_states[caster_id]
	if spell_state.cooldowns[spell_id] > 0 {
		return false
	}

	char := server.world.characters[caster_id]
	if char.mana < def.mana_cost {
		return false
	}

	char.mana -= def.mana_cost
	spell_state.cooldowns[spell_id] = def.cooldown_sec

	origin := vec3{char.pos.x, char.pos.y, char.pos.z + PLAYER_EYE_M}
	direction := camera_forward(char.yaw, char.pitch)

	switch def.payload {
	case .Projectile:
		spell_cast := Spell_Cast{
			caster_id = caster_id,
			spell_id  = spell_id,
			origin    = origin,
			direction = direction,
			tick      = tick,
		}
		projectile_spawn(&server.projectiles, &server.world, &spell_cast, def)

	case .Teleport:
		blink_dir := norm_vec3(vec3{direction.x, direction.y, 0})
		if len2_vec3(blink_dir) < 0.5 {
			blink_dir = camera_forward(char.yaw, 0)
		}
		// Walk the blink forward in small steps and stop at the last free spot.
		best := char.pos
		steps := 24
		for s in 1..=steps {
			cand := char.pos + blink_dir * (def.range * f32(s) / f32(steps))
			if blink_spot_free(cand) {
				best = cand
			} else {
				break
			}
		}
		char.pos = best
		char.vel.x = blink_dir.x * 3.0
		char.vel.y = blink_dir.y * 3.0

	case .None:
	}

	server.world.characters[caster_id] = char

	if SERVER_VERBOSE {
		server_log("[Combat] Entity %d cast %s", caster_id, def.name)
	}
	return true
}

@(private = "file")
blink_spot_free :: proc(pos: vec3) -> bool {
	offs := [4]vec3{
		{0, 0, 0.12},
		{0, 0, CHARACTER_HEIGHT_M * 0.5},
		{0, 0, CHARACTER_HEIGHT_M * 0.9},
		{0, 0, 0.6},
	}
	for o in offs {
		if !world_point_free(pos + o, CHARACTER_RADIUS_M + 0.05) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Main loop

server_avg_tick_time :: proc(server: ^Server) -> f32 {
	count := min(int(server.total_ticks), len(server.tick_times_ms))
	if count == 0 {
		return 0
	}
	sum: f32 = 0
	for i in 0..<count {
		sum += server.tick_times_ms[i]
	}
	return sum / f32(count)
}

server_max_tick_time :: proc(server: ^Server) -> f32 {
	count := min(int(server.total_ticks), len(server.tick_times_ms))
	m: f32 = 0
	for i in 0..<count {
		m = max(m, server.tick_times_ms[i])
	}
	return m
}

server_run :: proc(server: ^Server) {
	fmt.println("\n=== Server tick loop (60Hz) — Ctrl+C to stop ===\n")

	tick_interval := time.Duration(1_000_000_000 / SIMULATION_TICK_RATE)
	next_tick := time.tick_now()
	last_stats := time.tick_now()

	for server.running {
		if time.tick_since(next_tick) >= 0 {
			server_tick(server)
			next_tick._nsec += i64(tick_interval)
			if time.tick_since(next_tick) >= tick_interval * 4 {
				fmt.eprintln("WARNING: tick overrun, resyncing clock")
				next_tick = time.tick_now()
			}
		}

		if time.tick_since(last_stats) >= time.Second * 10 {
			server_print_stats(server)
			last_stats = time.tick_now()
		}

		// Sleep only if we have comfortable slack until the next tick
		remaining := time.Duration(-time.tick_since(next_tick))
		if remaining > time.Millisecond * 2 {
			time.sleep(time.Millisecond)
		}
	}

	server_shutdown(server)
}

server_print_stats :: proc(server: ^Server) {
	uptime_sec := f64(time.tick_since(server.start_time)) / f64(time.Second)
	humans := server_human_counts(server)
	fmt.printf("[Stats] up %.0fs | tick %d | entities %d | clients %d (%d/%d/%d) | proj %d | tick avg %.3fms max %.3fms | %s %.0f/%.0f/%.0f\n",
		uptime_sec, server.tick_id, server.world.count, server.client_count,
		humans[0], humans[1], humans[2], server.projectiles.count,
		server_avg_tick_time(server), server_max_tick_time(server),
		server.match.state == .Active ? "ACTIVE" : (server.match.state == .Waiting ? "WARMUP" : "ENDED"),
		server.match.essence[0], server.match.essence[1], server.match.essence[2])

	// One bot per team so lane traversal problems are visible in the log
	fmt.printf("        bots:")
	for team in TEAMS {
		for i in 0..<MAX_BOTS {
			b := &server.bots[i]
			if b.active && b.team == team {
				c := server.world.characters[b.id]
				fmt.printf(" %s(%.0f,%.0f %v obj%d%s)", team_name(team), c.pos.x, c.pos.y, b.mode, b.objective, c.dead ? " dead" : "")
				break
			}
		}
	}
	fmt.println()
}

server_shutdown :: proc(server: ^Server) {
	server.running = false
	network_shutdown(&server.network)
	fmt.println("Server stopped.")
}

main_server :: proc() {
	server, ok := server_init(SERVER_PORT)
	if !ok {
		fmt.eprintln("Failed to initialize server")
		return
	}
	server_run(&server)
}
