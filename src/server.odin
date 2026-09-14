package main

import "core:fmt"
import "core:time"
import "core:math"
import "core:math/rand"
import "core:net"

// Headless dedicated server for Nexus Arena.
// Phase 1 Goals:
// - Fixed 60Hz deterministic tick
// - ~16 bot entities with jump/strafe behavior
// - Measure tick time and verify stability
// - Network scaffold ready (but bots don't need network yet)

Server :: struct {
	world:           Entity_World,
	network:         Network_Endpoint,
	tick_id:         u32,
	running:         bool,
	bot_count:       int,
	bot_ids:         [16]Entity_ID,
	
	// Performance metrics
	tick_times_ms:   [60]f32,  // Rolling window of tick times
	tick_idx:        int,
	total_ticks:     u64,
	start_time:      time.Tick,
	
	// Network state
	connected_clients: [MAX_CLIENTS]net.Endpoint,
	client_entity_ids: [MAX_CLIENTS]Entity_ID,  // Entity ID for each client
	client_count:      int,
	last_snapshot_tick: u32,
}

MAX_CLIENTS :: 16
SNAPSHOT_RATE :: 30  // Send snapshots at 30Hz (every 2 ticks at 60Hz)

// Bot AI state
Bot_AI :: struct {
	think_timer:   f32,
	move_dir:      f32,  // Target movement direction
	strafe_dir:    f32,  // Target strafe direction
	jump_timer:    f32,
	turn_speed:    f32,
	target_yaw:    f32,
}

bot_ais: [16]Bot_AI

// Initialize server
server_init :: proc(port: u16, bot_count: int) -> (server: Server, ok: bool) {
	fmt.println("=== Nexus Arena Headless Server ===")
	fmt.printf("Initializing server on port %d with %d bots...\n", port, bot_count)
	
	server.world = entity_world_init()
	server.bot_count = min(bot_count, 16)
	server.start_time = time.tick_now()
	
	// Initialize network (optional for Phase 1 bot testing)
	if port > 0 {
		if !network_init(&server.network, port) {
			fmt.eprintln("Warning: Network initialization failed, running offline")
		}
	}
	
	// Spawn bots
	fmt.printf("Spawning %d bots...\n", server.bot_count)
	for i in 0..<server.bot_count {
		// Spawn bots in a rough circle
		angle := f32(i) * (2.0 * math.PI / f32(server.bot_count))
		radius := f32(4.0)
		center := (ROOM_MIN + ROOM_MAX) * 0.5
		pos := vec3{
			center.x + math.cos(angle) * radius,
			center.y + math.sin(angle) * radius,
			ROOM_MIN.z,
		}
		
		bot_id := entity_spawn(&server.world, pos)
		if bot_id == INVALID_ENTITY {
			fmt.eprintf("Failed to spawn bot %d\n", i)
			continue
		}
		
		server.bot_ids[i] = bot_id
		
		// Initialize bot AI
		bot_ais[i] = Bot_AI{
			move_dir = rand.float32_range(-1, 1),
			strafe_dir = rand.float32_range(-1, 1),
			jump_timer = rand.float32_range(0, 2),
			turn_speed = rand.float32_range(0.5, 2.0),
			target_yaw = rand.float32_range(0, 2.0 * math.PI),
		}
		
		// Set initial yaw
		idx, ok := entity_get_character_mut(&server.world, bot_id)
		if ok {
			server.world.characters[idx].yaw = bot_ais[i].target_yaw
		}
	}
	
	fmt.printf("Server initialized: %d bots spawned, %d entities active\n", 
		server.bot_count, server.world.count)
	
	server.running = true
	return server, true
}

// Update bot AI for one tick
server_update_bot_ai :: proc(server: ^Server, bot_idx: int, dt: f32) {
	if bot_idx >= server.bot_count {
		return
	}
	
	bot_id := server.bot_ids[bot_idx]
	char, ok := entity_get_character(&server.world, bot_id)
	if !ok {
		return
	}
	
	ai := &bot_ais[bot_idx]
	
	// Think timer - change movement every 1-3 seconds
	ai.think_timer -= dt
	if ai.think_timer <= 0 {
		ai.think_timer = rand.float32_range(1.0, 3.0)
		ai.move_dir = rand.float32_range(-1, 1)
		ai.strafe_dir = rand.float32_range(-1, 1)
		ai.target_yaw = rand.float32_range(0, 2.0 * math.PI)
		ai.turn_speed = rand.float32_range(0.5, 2.0)
	}
	
	// Jump timer - jump every 1-2 seconds
	ai.jump_timer -= dt
	should_jump := false
	if ai.jump_timer <= 0 && char.on_ground {
		ai.jump_timer = rand.float32_range(1.0, 2.0)
		should_jump = true
	}
	
	// Smooth turn toward target yaw
	yaw_diff := ai.target_yaw - char.yaw
	// Normalize to [-PI, PI]
	for yaw_diff > math.PI {
		yaw_diff -= 2.0 * math.PI
	}
	for yaw_diff < -math.PI {
		yaw_diff += 2.0 * math.PI
	}
	
	delta_yaw := clampf(yaw_diff * ai.turn_speed * dt, -0.1, 0.1)
	
	// Set input for this bot
	input := Input_State{
		move_fwd = ai.move_dir,
		move_str = ai.strafe_dir,
		jump = should_jump,
		delta_yaw = delta_yaw,
		delta_pitch = 0,
	}
	
	entity_set_input(&server.world, bot_id, input)
}

// Run one server tick
server_tick :: proc(server: ^Server) {
	tick_start := time.tick_now()
	
	// Process incoming packets
	server_process_packets(server)
	
	// Update bot AI
	for i in 0..<server.bot_count {
		server_update_bot_ai(server, i, SIMULATION_DT)
	}
	
	// Run simulation step (deterministic kernel)
	simulate_world_step(&server.world)
	
	// Send snapshots to clients (30Hz = every 2 ticks)
	if server.tick_id % 2 == 0 {
		server_send_snapshots(server)
	}
	
	server.tick_id += 1
	server.total_ticks += 1
	
	// Record tick time
	tick_duration := time.tick_since(tick_start)
	tick_ms := f32(time.duration_milliseconds(tick_duration))
	server.tick_times_ms[server.tick_idx] = tick_ms
	server.tick_idx = (server.tick_idx + 1) % len(server.tick_times_ms)
}

// Process incoming network packets
server_process_packets :: proc(server: ^Server) {
	buffer: [MAX_PACKET_SIZE]u8
	
	// Process up to 100 packets per tick
	for i in 0..<100 {
		n, from, ok := network_receive(&server.network, buffer[:])
		if !ok || n < 2 {
			break
		}
		
		// Check packet type
		if n < 2 {
			continue
		}
		
		ptype := Packet_Type(buffer[1])
		
		if ptype == .Client_Input {
			// Register client if new (spawns entity and sends welcome)
			entity_id, is_new := server_register_client(server, from)
			
			// If this is a new connection, send welcome packet
			if is_new && entity_id != INVALID_ENTITY {
				server_send_welcome(server, from, entity_id)
			}
			
			// Process input packet (Phase 2: not used yet, server runs bots only)
			// In Phase 3, this would apply player inputs
		}
	}
}

// Register a client connection and spawn player entity
server_register_client :: proc(server: ^Server, client_addr: net.Endpoint) -> (entity_id: Entity_ID, is_new: bool) {
	// Check if already registered
	for i in 0..<server.client_count {
		if server.connected_clients[i].port == client_addr.port {
			// Already registered, return existing entity ID
			return server.client_entity_ids[i], false
		}
	}
	
	// Add new client
	if server.client_count < MAX_CLIENTS {
		// Spawn player entity for this client
		// Place players in a circle around center, offset from bots
		angle := f32(server.client_count) * (2.0 * math.PI / f32(MAX_CLIENTS))
		radius := f32(6.0)  // Slightly larger radius than bots
		center := (ROOM_MIN + ROOM_MAX) * 0.5
		spawn_pos := vec3{
			center.x + math.cos(angle) * radius,
			center.y + math.sin(angle) * radius,
			ROOM_MIN.z,
		}
		
		player_id := entity_spawn(&server.world, spawn_pos)
		if player_id == INVALID_ENTITY {
			fmt.eprintf("[Server] Failed to spawn player entity for client\n")
			return INVALID_ENTITY, false
		}
		
		// Register client
		idx := server.client_count
		server.connected_clients[idx] = client_addr
		server.client_entity_ids[idx] = player_id
		server.client_count += 1
		
		fmt.printf("[Server] Client connected: %v → Entity ID %d (total clients: %d)\n", 
			client_addr, player_id, server.client_count)
		
		return player_id, true
	}
	
	return INVALID_ENTITY, false
}

// Send welcome packet to client with their entity ID
server_send_welcome :: proc(server: ^Server, client_addr: net.Endpoint, entity_id: Entity_ID) {
	welcome := Server_Welcome_Packet{
		your_entity_id = entity_id,
	}
	
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_welcome(&welcome, buffer[:])
	if size > 0 {
		network_send(&server.network, buffer[:], size, client_addr)
		fmt.printf("[Server] Sent welcome to client: Entity ID %d\n", entity_id)
	}
}

// Send world snapshot to all connected clients
server_send_snapshots :: proc(server: ^Server) {
	if server.client_count == 0 {
		return
	}
	
	// Build snapshot packet
	snapshot := Server_Snapshot_Packet{
		tick_id = server.tick_id,
		entity_count = 0,
	}
	
	// Add all active entities
	for i in 1..<MAX_ENTITIES {
		if !server.world.characters[i].active {
			continue
		}
		
		if int(snapshot.entity_count) >= MAX_ENTITIES {
			break
		}
		
		char := server.world.characters[i]
		snapshot.entities[snapshot.entity_count] = Snapshot_Entity{
			id = Entity_ID(i),
			pos = char.pos,
			yaw = char.yaw,
			pitch = char.pitch,
			vel_z = char.vel_z,
			on_ground = char.on_ground,
		}
		snapshot.entity_count += 1
	}
	
	// Serialize
	buffer: [MAX_PACKET_SIZE]u8
	size := serialize_server_snapshot(&snapshot, buffer[:])
	if size <= 0 {
		return
	}
	
	// Send to all clients
	for i in 0..<server.client_count {
		network_send(&server.network, buffer[:], size, server.connected_clients[i])
	}
}

// Get average tick time
server_avg_tick_time :: proc(server: ^Server) -> f32 {
	sum: f32 = 0
	count := min(int(server.total_ticks), len(server.tick_times_ms))
	if count == 0 {
		return 0
	}
	
	for i in 0..<count {
		sum += server.tick_times_ms[i]
	}
	
	return sum / f32(count)
}

// Get max tick time
server_max_tick_time :: proc(server: ^Server) -> f32 {
	max_time: f32 = 0
	count := min(int(server.total_ticks), len(server.tick_times_ms))
	
	for i in 0..<count {
		max_time = max(max_time, server.tick_times_ms[i])
	}
	
	return max_time
}

// Main server loop
server_run :: proc(server: ^Server) {
	fmt.println("\n=== Starting server tick loop (60Hz) ===")
	fmt.println("Press Ctrl+C to stop\n")
	
	tick_interval := time.Duration(1_000_000_000 / SIMULATION_TICK_RATE) // 16.666ms
	next_tick := time.tick_now()
	last_stats := time.tick_now()
	
	for server.running {
		now := time.tick_now()
		
		// Run tick if it's time
		if time.tick_since(next_tick) >= 0 {
			server_tick(server)
			next_tick._nsec += i64(tick_interval)
			
			// Detect tick overrun
			if time.tick_since(next_tick) >= tick_interval {
				fmt.eprintf("WARNING: Tick overrun! Server falling behind.\n")
				next_tick = time.tick_now()
			}
		}
		
		// Print stats every 5 seconds
		if time.tick_since(last_stats) >= time.Second * 5 {
			server_print_stats(server)
			last_stats = time.tick_now()
		}
		
		// Sleep briefly to avoid busy-wait
		time.sleep(time.Millisecond)
	}
	
	fmt.println("\nServer shutting down...")
	server_shutdown(server)
}

// Print server statistics
server_print_stats :: proc(server: ^Server) {
	uptime := time.tick_since(server.start_time)
	uptime_sec := f64(uptime) / f64(time.Second)
	
	avg_tick := server_avg_tick_time(server)
	max_tick := server_max_tick_time(server)
	
	fmt.printf("[Server Stats] Uptime: %.1fs | Ticks: %d | Entities: %d | Clients: %d | Avg tick: %.3fms | Max tick: %.3fms\n",
		uptime_sec, server.total_ticks, server.world.count, server.client_count, avg_tick, max_tick)
	
	// Print first few bot positions for verification
	fmt.printf("  Bot positions: ")
	for i in 0..<min(3, server.bot_count) {
		char, ok := entity_get_character(&server.world, server.bot_ids[i])
		if ok {
			fmt.printf("B%d=(%.2f,%.2f,%.2f) ", i, char.pos.x, char.pos.y, char.pos.z)
		}
	}
	fmt.println()
}

// Shutdown server
server_shutdown :: proc(server: ^Server) {
	server.running = false
	network_shutdown(&server.network)
	fmt.println("Server stopped.")
}

// Entry point for headless server
main_server :: proc() {
	// Configuration
	PORT :: 27015
	BOT_COUNT :: 16
	
	server, ok := server_init(PORT, BOT_COUNT)
	if !ok {
		fmt.eprintln("Failed to initialize server")
		return
	}
	
	server_run(&server)
}
