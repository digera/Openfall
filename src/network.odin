package main

import "core:net"
import "core:fmt"
import "core:mem"

// Network protocol for Nexus Arena.
// Phase 1: Minimal bit-packed UDP protocol.
// - Client -> Server: Input packets
// - Server -> Client: Delta snapshots
//
// Future: Compression, delta encoding, prediction, lag compensation.

PROTOCOL_VERSION :: u8(1)
MAX_PACKET_SIZE :: 1400 // Safe UDP payload size

// Packet types
Packet_Type :: enum u8 {
	Invalid = 0,
	Client_Input = 1,    // Client -> Server: inputs for this tick
	Server_Snapshot = 2, // Server -> Client: world state snapshot
}

// Client input packet
// Sent from client to server each tick (60Hz)
Client_Input_Packet :: struct {
	tick_id:     u32,  // Client tick ID
	move_fwd:    i8,   // Forward/back [-127, 127]
	move_str:    i8,   // Strafe [-127, 127]
	jump:        bool, // Jump button
	delta_yaw:   i16,  // Yaw delta * 1000 (milliradian precision)
	delta_pitch: i16,  // Pitch delta * 1000
}

// Server snapshot packet
// Sent from server to clients at 20-30Hz (lower than tick rate)
Server_Snapshot_Packet :: struct {
	tick_id:      u32,                        // Server tick ID
	entity_count: u8,                         // Number of entities in this snapshot
	entities:     [MAX_ENTITIES]Snapshot_Entity, // Entity states
}

// Entity state in snapshot
Snapshot_Entity :: struct {
	id:        Entity_ID, // Entity ID
	pos:       vec3,      // Position
	yaw:       f32,       // Yaw angle
	pitch:     f32,       // Pitch angle
	vel_z:     f32,       // Vertical velocity
	on_ground: bool,      // Ground flag
}

// Network endpoint
Network_Endpoint :: struct {
	socket:   net.UDP_Socket,
	bound:    bool,
	port:     u16,
}

// Initialize network endpoint
network_init :: proc(endpoint: ^Network_Endpoint, port: u16) -> bool {
	socket, err := net.make_bound_udp_socket(net.IP4_Any, int(port))
	if err != nil {
		fmt.eprintln("Failed to bind UDP socket:", err)
		return false
	}
	
	endpoint.socket = socket
	endpoint.bound = true
	endpoint.port = port
	
	// Set non-blocking
	net.set_blocking(socket, false)
	
	fmt.printf("Network endpoint bound to UDP port %d\n", port)
	return true
}

// Shutdown network endpoint
network_shutdown :: proc(endpoint: ^Network_Endpoint) {
	if endpoint.bound {
		net.close(endpoint.socket)
		endpoint.bound = false
	}
}

// Serialize client input packet to bytes
serialize_client_input :: proc(packet: ^Client_Input_Packet, buffer: []u8) -> int {
	if len(buffer) < size_of(Client_Input_Packet) + 2 {
		return 0
	}
	
	pos := 0
	buffer[pos] = u8(PROTOCOL_VERSION); pos += 1
	buffer[pos] = u8(Packet_Type.Client_Input); pos += 1
	
	// Tick ID (4 bytes)
	mem.copy(&buffer[pos], &packet.tick_id, 4); pos += 4
	
	// Movement (2 bytes)
	buffer[pos] = transmute(u8)packet.move_fwd; pos += 1
	buffer[pos] = transmute(u8)packet.move_str; pos += 1
	
	// Jump (1 byte)
	buffer[pos] = packet.jump ? 1 : 0; pos += 1
	
	// Look deltas (4 bytes)
	mem.copy(&buffer[pos], &packet.delta_yaw, 2); pos += 2
	mem.copy(&buffer[pos], &packet.delta_pitch, 2); pos += 2
	
	return pos
}

// Deserialize client input packet from bytes
deserialize_client_input :: proc(buffer: []u8) -> (packet: Client_Input_Packet, ok: bool) {
	if len(buffer) < size_of(Client_Input_Packet) + 2 {
		return {}, false
	}
	
	pos := 0
	version := buffer[pos]; pos += 1
	if version != PROTOCOL_VERSION {
		return {}, false
	}
	
	ptype := Packet_Type(buffer[pos]); pos += 1
	if ptype != .Client_Input {
		return {}, false
	}
	
	mem.copy(&packet.tick_id, &buffer[pos], 4); pos += 4
	packet.move_fwd = transmute(i8)buffer[pos]; pos += 1
	packet.move_str = transmute(i8)buffer[pos]; pos += 1
	packet.jump = buffer[pos] != 0; pos += 1
	mem.copy(&packet.delta_yaw, &buffer[pos], 2); pos += 2
	mem.copy(&packet.delta_pitch, &buffer[pos], 2); pos += 2
	
	return packet, true
}

// Serialize server snapshot to bytes
serialize_server_snapshot :: proc(packet: ^Server_Snapshot_Packet, buffer: []u8) -> int {
	if len(buffer) < MAX_PACKET_SIZE {
		return 0
	}
	
	pos := 0
	buffer[pos] = u8(PROTOCOL_VERSION); pos += 1
	buffer[pos] = u8(Packet_Type.Server_Snapshot); pos += 1
	
	// Tick ID (4 bytes)
	mem.copy(&buffer[pos], &packet.tick_id, 4); pos += 4
	
	// Entity count (1 byte)
	buffer[pos] = packet.entity_count; pos += 1
	
	// Entity data
	for i in 0..<int(packet.entity_count) {
		entity := &packet.entities[i]
		
		// Entity ID (4 bytes)
		mem.copy(&buffer[pos], &entity.id, 4); pos += 4
		
		// Position (12 bytes)
		mem.copy(&buffer[pos], &entity.pos, 12); pos += 12
		
		// Angles (8 bytes)
		mem.copy(&buffer[pos], &entity.yaw, 4); pos += 4
		mem.copy(&buffer[pos], &entity.pitch, 4); pos += 4
		
		// Velocity Z (4 bytes)
		mem.copy(&buffer[pos], &entity.vel_z, 4); pos += 4
		
		// Flags (1 byte)
		buffer[pos] = entity.on_ground ? 1 : 0; pos += 1
	}
	
	return pos
}

// Send packet to address
network_send :: proc(endpoint: ^Network_Endpoint, buffer: []u8, size: int, to: net.Endpoint) -> bool {
	if !endpoint.bound || size <= 0 {
		return false
	}
	
	_, err := net.send_udp(endpoint.socket, buffer[:size], to)
	return err == nil
}

// Receive packet (non-blocking)
network_receive :: proc(endpoint: ^Network_Endpoint, buffer: []u8) -> (bytes_read: int, from: net.Endpoint, ok: bool) {
	if !endpoint.bound {
		return 0, {}, false
	}
	
	n, ep, err := net.recv_udp(endpoint.socket, buffer)
	if err != nil {
		return 0, {}, false
	}
	
	return n, ep, true
}

// Convert input state to network packet format
input_to_packet :: proc(input: Input_State, tick_id: u32) -> Client_Input_Packet {
	return Client_Input_Packet{
		tick_id = tick_id,
		move_fwd = i8(clampf(input.move_fwd, -1, 1) * 127),
		move_str = i8(clampf(input.move_str, -1, 1) * 127),
		jump = input.jump,
		delta_yaw = i16(input.delta_yaw * 1000),
		delta_pitch = i16(input.delta_pitch * 1000),
	}
}

// Convert network packet to input state
packet_to_input :: proc(packet: Client_Input_Packet) -> Input_State {
	return Input_State{
		move_fwd = f32(packet.move_fwd) / 127.0,
		move_str = f32(packet.move_str) / 127.0,
		jump = packet.jump,
		delta_yaw = f32(packet.delta_yaw) / 1000.0,
		delta_pitch = f32(packet.delta_pitch) / 1000.0,
	}
}
