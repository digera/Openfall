package main

import "core:fmt"
import "core:net"
import "core:time"

// Client-side UDP endpoint talking to one server.

Network_Client :: struct {
	endpoint:       Network_Endpoint,
	server_addr:    net.Endpoint,

	last_send_time: time.Tick,
	last_recv_time: time.Tick,

	packets_sent:   int,
	packets_recv:   int,
	bytes_sent:     int,
	bytes_recv:     int,

	// Simulated packet loss for testing (outgoing only)
	sim_loss_rate:  f32,
}

// One decoded server packet.
Client_Packet :: struct {
	kind:       Packet_Type,
	snapshot:   Server_Snapshot_Packet,
	welcome:    Server_Welcome_Packet,
	gamestate:  Server_GameState_Packet,
	lobby:      Server_Lobby_Packet,
	roster:     Server_Roster_Packet,
}

network_client_resolve_host :: proc(server_host: string, server_port: u16) -> (ep: net.Endpoint, ok: bool) {
	host := server_host
	if host == "" {
		host = DEFAULT_SERVER_HOST
	}
	if host == "localhost" || host == "127.0.0.1" {
		return net.Endpoint{address = net.IP4_Loopback, port = int(server_port)}, true
	}

	resolved, err := net.resolve_ip4(host)
	if err != nil {
		fmt.eprintf("Failed to resolve server address '%s': %v\n", host, err)
		return {}, false
	}
	resolved.port = int(server_port)
	return resolved, true
}

network_client_init :: proc(client: ^Network_Client, server_host: string, server_port: u16) -> bool {
	if !network_init(&client.endpoint, 0) {
		fmt.eprintln("Failed to initialize client network")
		return false
	}

	ep, ok := network_client_resolve_host(server_host, server_port)
	if !ok {
		network_shutdown(&client.endpoint)
		return false
	}

	client.server_addr = ep
	client.last_send_time = time.tick_now()
	client.last_recv_time = time.tick_now()

	fmt.printf("Client initialized, server: %s (%v):%d\n", server_host, ep.address, server_port)
	return true
}

network_client_shutdown :: proc(client: ^Network_Client) {
	network_shutdown(&client.endpoint)
}

@(private = "file")
client_send_raw :: proc(client: ^Network_Client, buffer: []u8, size: int) -> bool {
	if size <= 0 {
		return false
	}
	if network_send(&client.endpoint, buffer, size, client.server_addr) {
		client.packets_sent += 1
		client.bytes_sent += size
		client.last_send_time = time.tick_now()
		return true
	}
	return false
}

network_client_send_hello :: proc(client: ^Network_Client) -> bool {
	buffer: [16]u8
	return client_send_raw(client, buffer[:], serialize_client_hello(buffer[:]))
}

network_client_send_join :: proc(client: ^Network_Client, team: Team_ID, name := Player_Name{}) -> bool {
	buffer: [32]u8
	packet := Client_Join_Packet{team = team, name = name}
	return client_send_raw(client, buffer[:], serialize_client_join(&packet, buffer[:]))
}

// Send the newest input plus up to two previous ones for loss tolerance.
network_client_send_input :: proc(client: ^Network_Client, packet: ^Client_Input_Packet) -> bool {
	if client.sim_loss_rate > 0 {
		loss_check := f32(hash_u32(packet.newest_tick) & 0xFFFF) / 65536.0
		if loss_check < client.sim_loss_rate {
			return true // dropped on purpose
		}
	}
	buffer: [64]u8
	return client_send_raw(client, buffer[:], serialize_client_input(packet, buffer[:]))
}

// Poll one packet from the server. Returns ok=false when none is pending.
network_client_poll :: proc(client: ^Network_Client) -> (packet: Client_Packet, ok: bool) {
	buffer: [MAX_PACKET_SIZE]u8
	n, _, recv_ok := network_receive(&client.endpoint, buffer[:])
	if !recv_ok || n < 2 {
		return {}, false
	}
	client.packets_recv += 1
	client.bytes_recv += n
	client.last_recv_time = time.tick_now()

	ptype, hdr_ok := packet_header(buffer[:n])
	if !hdr_ok {
		return {}, false
	}
	packet.kind = ptype

	#partial switch ptype {
	case .Server_Snapshot:
		snap, snap_ok := deserialize_server_snapshot(buffer[:n])
		if !snap_ok { return {}, false }
		packet.snapshot = snap
		return packet, true
	case .Server_Welcome:
		w, w_ok := deserialize_server_welcome(buffer[:n])
		if !w_ok { return {}, false }
		packet.welcome = w
		return packet, true
	case .Server_GameState:
		gs, gs_ok := deserialize_server_gamestate(buffer[:n])
		if !gs_ok { return {}, false }
		packet.gamestate = gs
		return packet, true
	case .Server_Lobby:
		lb, lb_ok := deserialize_server_lobby(buffer[:n])
		if !lb_ok { return {}, false }
		packet.lobby = lb
		return packet, true
	case .Server_Roster:
		rs, rs_ok := deserialize_server_roster(buffer[:n])
		if !rs_ok { return {}, false }
		packet.roster = rs
		return packet, true
	}
	return {}, false
}

network_client_stats :: proc(client: ^Network_Client) -> (sent: int, recv: int, since_recv_ms: f32) {
	since_recv := time.tick_since(client.last_recv_time)
	return client.packets_sent, client.packets_recv, f32(time.duration_milliseconds(since_recv))
}

network_client_sim_loss :: proc(client: ^Network_Client, loss_rate: f32) {
	client.sim_loss_rate = clampf(loss_rate, 0, 1)
	fmt.printf("[Client] Simulated packet loss: %.1f%%\n", loss_rate * 100)
}
