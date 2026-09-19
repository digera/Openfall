package main

import "core:net"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"

// Nexus Arena UDP protocol (v9).
//
// Client → Server
//   Hello            probe; server answers with Lobby
//   Join{team,name}  request a team under a name; server answers Welcome or Lobby(reject)
//   Input            newest tick + up to 3 redundant inputs (loss tolerant)
// Server → Client
//   Lobby            team populations + join verdict
//   Welcome          entity id + team
//   Snapshot         per-client world state, 30Hz, nearest-N entities
//   GameState        match / obelisk state, 10Hz
//   Roster           who is playing and how they are doing, 2Hz, everyone
//
// The snapshot is interest-managed: it carries the nearest handful of bodies
// because that is all you can see. Names and the scoreline are the opposite
// shape -- you need them for players you cannot see, and they barely change --
// so they ride their own slow packet instead of inflating every body in every
// snapshot and squeezing out the bodies themselves.
//
// Combat events do belong in the snapshot: they are per-client, they are
// wanted the instant they happen, and they are gone a second later.

PROTOCOL_VERSION :: u8(9)  // bumped for the roster packet and combat events
MAX_PACKET_SIZE  :: 1400

Packet_Type :: enum u8 {
	Invalid          = 0,
	Client_Hello     = 1,
	Server_Snapshot  = 2,
	Server_Welcome   = 3,
	Server_GameState = 4,
	Client_Join      = 5,
	Client_Input     = 6,
	Server_Lobby     = 7,
	Server_Roster    = 8,
}

INPUT_REDUNDANCY :: 3

MAX_SNAPSHOT_ENTITIES      :: 21  // one body traded for the combat event block
MAX_SNAPSHOT_PROJECTILES   :: 12
MAX_SNAPSHOT_STRIKES       :: 4
MAX_SNAPSHOT_BEAMS         :: 4
MAX_SNAPSHOT_COMBAT_EVENTS :: 8

// Everyone who can be in a match at once. Checked against MAX_CLIENTS +
// MAX_BOTS where those are in scope; the client build has neither, so the
// roster has to name its own bound.
MAX_ROSTER_ENTRIES :: 40

// ---------------------------------------------------------------------------
// Packet structs (host representation)

Client_Input_Packet :: struct {
	newest_tick: u32,
	count:       u8,
	inputs:      [INPUT_REDUNDANCY]Input_State, // [0] is newest (tick = newest_tick), [k] is newest_tick - k
}

Client_Join_Packet :: struct {
	team: Team_ID,
	name: Player_Name,  // what they would like to be called; the server decides
}

Lobby_Reject :: enum u8 {
	None = 0,
	Team_Most_Populated = 1,
	Server_Full = 2,
	Invalid_Team = 3,
}

Server_Lobby_Packet :: struct {
	humans:    [TEAM_COUNT]u8,
	bots:      [TEAM_COUNT]u8,
	team_size: u8,
	reject:    Lobby_Reject,
}

Server_Welcome_Packet :: struct {
	your_entity_id: Entity_ID,
	team:           Team_ID,
}

Snapshot_Entity :: struct {
	id:            Entity_ID,
	pos:           vec3,
	vel:           vec3,
	yaw:           f32,
	pitch:         f32,
	on_ground:     bool,
	dead:          bool,
	is_bot:        bool,
	health:        f32,
	mana:          f32,
	stamina:       f32,
	team:          Team_ID,
	slow_ticks:    int,

	// What is in this entity's hand: the spell it is winding up and how far the
	// wind-up has come. This is the cast orb everyone else sees, so it is state
	// rather than an event -- a player who looks away and back must find the
	// same charge still building. A beam has no wind-up and reports a full
	// charge for as long as it is lit.
	channel_spell: Spell_ID,
	channel_frac:  f32,
}

Snapshot_Projectile :: struct {
	id:       Projectile_ID,
	spell_id: Spell_ID,
	owner_id: Entity_ID,
	pos:      vec3,
	vel:      vec3,
	lifetime: f32,
	radius:   f32,
}

// A strike that landed recently. Strikes are instantaneous, so unlike a
// projectile there is no object whose disappearance the client can watch for;
// the server keeps each one in its snapshots for a few frames and the client
// deduplicates by `seq`, so one dropped packet does not lose the bolt.
Snapshot_Strike :: struct {
	seq:      u8,
	owner_id: Entity_ID,
	pos:      vec3,   // where it landed: the target's feet
}

// A beam being held this tick. It starts at its owner's eye, which the client
// already knows, so only the far end travels; arcs are named by entity so the
// client draws them to the bodies it is already interpolating.
Snapshot_Beam :: struct {
	owner_id:    Entity_ID,
	spell_id:    Spell_ID,  // which beam it is, so the client can colour it
	end:         vec3,
	hit:         bool,      // the far end is a body, not the world
	chain_count: u8,
	chains:      [BEAM_MAX_CHAINS]Entity_ID,
}

// One line of the receiving client's combat log. Sent only to the entity it
// concerns, and replayed for as long as the server holds it, so a lost packet
// costs nothing: `seq` names the line, and a line the client already has is
// updated in place rather than repeated. That is also how a beam reads as a
// single tally counting up instead of sixty lines a second.
Snapshot_Combat_Event :: struct {
	seq:        u8,
	event_type: Combat_Event_Type,
	other_id:   Entity_ID,  // the victim for dealt/kill, the attacker for taken/death
	spell_id:   Spell_ID,
	damage:     u16,        // running total for this line, whole HP
}

Server_Snapshot_Packet :: struct {
	tick_id:          u32,
	ack_input_tick:   u32,   // newest client input tick the server has applied
	entity_count:     u8,
	entities:         [MAX_SNAPSHOT_ENTITIES]Snapshot_Entity,
	projectile_count: u8,
	projectiles:      [MAX_SNAPSHOT_PROJECTILES]Snapshot_Projectile,
	strike_count:     u8,
	strikes:          [MAX_SNAPSHOT_STRIKES]Snapshot_Strike,
	beam_count:       u8,
	beams:            [MAX_SNAPSHOT_BEAMS]Snapshot_Beam,
	combat_event_count: u8,
	combat_events:      [MAX_SNAPSHOT_COMBAT_EVENTS]Snapshot_Combat_Event,
}

// Everyone in the match, whether or not they are in view. The same packet
// backs the name over a target's head and the scoreboard behind Tab.
Roster_Entry :: struct {
	id:     Entity_ID,
	team:   Team_ID,
	is_bot: bool,
	name:   Player_Name,
	stats:  Combat_Stats,
}

Server_Roster_Packet :: struct {
	count:   u8,
	entries: [MAX_ROSTER_ENTRIES]Roster_Entry,
}

Snapshot_Obelisk :: struct {
	state:     u8,
	owner:     u8,
	capturing: u8,
	progress:  f32,
}

Server_GameState_Packet :: struct {
	match_state:  u8,
	match_result: u8,
	winner:       u8,
	essence:      [TEAM_COUNT]f32,
	match_time:   f32,
	humans:       [TEAM_COUNT]u8,
	obelisks:     [MAX_OBELISKS]Snapshot_Obelisk,
}

// ---------------------------------------------------------------------------
// Byte cursor helpers

Byte_Writer :: struct {
	buf: []u8,
	pos: int,
	ok:  bool,
}

bw_init :: proc(buf: []u8) -> Byte_Writer {
	return {buf = buf, pos = 0, ok = true}
}

bw_u8 :: proc(w: ^Byte_Writer, v: u8) {
	if w.pos + 1 > len(w.buf) { w.ok = false; return }
	w.buf[w.pos] = v
	w.pos += 1
}

bw_i8 :: proc(w: ^Byte_Writer, v: i8) { bw_u8(w, transmute(u8)v) }

bw_i16 :: proc(w: ^Byte_Writer, v: i16) {
	if w.pos + 2 > len(w.buf) { w.ok = false; return }
	vv := v
	mem.copy(&w.buf[w.pos], &vv, 2)
	w.pos += 2
}

bw_u16 :: proc(w: ^Byte_Writer, v: u16) {
	if w.pos + 2 > len(w.buf) { w.ok = false; return }
	vv := v
	mem.copy(&w.buf[w.pos], &vv, 2)
	w.pos += 2
}

bw_u32 :: proc(w: ^Byte_Writer, v: u32) {
	if w.pos + 4 > len(w.buf) { w.ok = false; return }
	vv := v
	mem.copy(&w.buf[w.pos], &vv, 4)
	w.pos += 4
}

bw_f32 :: proc(w: ^Byte_Writer, v: f32) {
	if w.pos + 4 > len(w.buf) { w.ok = false; return }
	vv := v
	mem.copy(&w.buf[w.pos], &vv, 4)
	w.pos += 4
}

bw_vec3 :: proc(w: ^Byte_Writer, v: vec3) {
	bw_f32(w, v.x); bw_f32(w, v.y); bw_f32(w, v.z)
}

Byte_Reader :: struct {
	buf: []u8,
	pos: int,
	ok:  bool,
}

br_init :: proc(buf: []u8) -> Byte_Reader {
	return {buf = buf, pos = 0, ok = true}
}

br_u8 :: proc(r: ^Byte_Reader) -> u8 {
	if r.pos + 1 > len(r.buf) { r.ok = false; return 0 }
	v := r.buf[r.pos]
	r.pos += 1
	return v
}

br_i8 :: proc(r: ^Byte_Reader) -> i8 { return transmute(i8)br_u8(r) }

br_i16 :: proc(r: ^Byte_Reader) -> i16 {
	if r.pos + 2 > len(r.buf) { r.ok = false; return 0 }
	v: i16
	mem.copy(&v, &r.buf[r.pos], 2)
	r.pos += 2
	return v
}

br_u16 :: proc(r: ^Byte_Reader) -> u16 {
	if r.pos + 2 > len(r.buf) { r.ok = false; return 0 }
	v: u16
	mem.copy(&v, &r.buf[r.pos], 2)
	r.pos += 2
	return v
}

br_u32 :: proc(r: ^Byte_Reader) -> u32 {
	if r.pos + 4 > len(r.buf) { r.ok = false; return 0 }
	v: u32
	mem.copy(&v, &r.buf[r.pos], 4)
	r.pos += 4
	return v
}

br_f32 :: proc(r: ^Byte_Reader) -> f32 {
	if r.pos + 4 > len(r.buf) { r.ok = false; return 0 }
	v: f32
	mem.copy(&v, &r.buf[r.pos], 4)
	r.pos += 4
	return v
}

br_vec3 :: proc(r: ^Byte_Reader) -> vec3 {
	x := br_f32(r); y := br_f32(r); z := br_f32(r)
	return {x, y, z}
}

// Names go length-prefixed and are re-sanitized on the way in, because the
// bytes of a name reach a HUD on every machine in the match and the only thing
// standing between a hostile client and that HUD is this procedure.
bw_name :: proc(w: ^Byte_Writer, n: Player_Name) {
	count := min(int(n.len), MAX_PLAYER_NAME_LEN)
	bw_u8(w, u8(count))
	for i in 0..<count {
		bw_u8(w, n.text[i])
	}
}

br_name :: proc(r: ^Byte_Reader) -> Player_Name {
	out: Player_Name
	count := int(br_u8(r))
	if count > MAX_PLAYER_NAME_LEN {
		r.ok = false
		return {}
	}
	for i in 0..<count {
		c := br_u8(r)
		if c >= 32 && c < 127 {
			out.text[out.len] = c
			out.len += 1
		}
	}
	return out
}

// Quantization helpers (shared so client prediction sees exactly what the server sees)
ANGLE_QUANT :: f32(10000.0)

quant_angle :: proc(a: f32) -> i16 {
	v := math.round(wrap_angle(a) * ANGLE_QUANT)
	return i16(clampf(v, -32767, 32767))
}

dequant_angle :: proc(q: i16) -> f32 {
	return f32(q) / ANGLE_QUANT
}

quant_axis :: proc(v: f32) -> i8 {
	return i8(math.round(clampf(v, -1, 1) * 127))
}

dequant_axis :: proc(q: i8) -> f32 {
	return f32(q) / 127.0
}

quant_u8 :: proc(v: f32, scale: f32) -> u8 {
	return u8(clampf(math.round(v * scale), 0, 255))
}

// Effect positions to the centimetre in six bytes rather than twelve. The
// arena is ~75 m across, so +-327 m is not a limit anyone will find.
bw_pos_cm :: proc(w: ^Byte_Writer, v: vec3) {
	for k in 0..<3 {
		bw_i16(w, i16(clampf(math.round(v[k] * 100), -32767, 32767)))
	}
}

br_pos_cm :: proc(r: ^Byte_Reader) -> vec3 {
	x := f32(br_i16(r)) / 100.0
	y := f32(br_i16(r)) / 100.0
	z := f32(br_i16(r)) / 100.0
	return {x, y, z}
}

// Entity ids ride as one byte; anything past the table is nobody.
@(private = "file")
entity_id_from_wire :: proc(raw: u8) -> Entity_ID {
	id := Entity_ID(raw)
	return id < MAX_ENTITIES ? id : INVALID_ENTITY
}

// A hostile client can put any byte on the wire, and Spell_ID indexes an
// enumerated array, so anything that is not a real spell becomes .None here.
@(private = "file")
spell_id_from_wire :: proc(raw: u8) -> Spell_ID {
	id := Spell_ID(raw)
	return spell_valid(id) ? id : .None
}

@(private = "file")
team_from_wire :: proc(raw: u8) -> Team_ID {
	return raw <= u8(Team_ID.Gamma) ? Team_ID(raw) : .None
}

@(private = "file")
combat_event_type_from_wire :: proc(raw: u8) -> Combat_Event_Type {
	return raw <= u8(Combat_Event_Type.Death) ? Combat_Event_Type(raw) : .Damage_Dealt
}

// Round-trip an input through the wire representation. The client predicts
// with the result so its simulation matches the server bit-for-bit.
input_quantize :: proc(input: Input_State) -> Input_State {
	out := input
	out.move_fwd = dequant_axis(quant_axis(input.move_fwd))
	out.move_str = dequant_axis(quant_axis(input.move_str))
	out.yaw = dequant_angle(quant_angle(input.yaw))
	out.pitch = dequant_angle(quant_angle(clampf(input.pitch, -CAM_PITCH_MAX, CAM_PITCH_MAX)))
	return out
}

// NEXUS_PORT moves both ends off SERVER_PORT, so a second server can be run
// beside a live one without either noticing.
server_port_from_env :: proc() -> u16 {
	buf: [16]u8
	if v := os.get_env_buf(buf[:], "NEXUS_PORT"); v != "" {
		if port, ok := strconv.parse_int(v); ok && port > 0 && port < 65536 {
			return u16(port)
		}
	}
	return SERVER_PORT
}

// ---------------------------------------------------------------------------
// Endpoint

Network_Endpoint :: struct {
	socket: net.UDP_Socket,
	bound:  bool,
	port:   u16,
}

network_init :: proc(endpoint: ^Network_Endpoint, port: u16) -> bool {
	socket, err := net.make_bound_udp_socket(net.IP4_Any, int(port))
	if err != nil {
		fmt.eprintln("Failed to bind UDP socket:", err)
		return false
	}
	endpoint.socket = socket
	endpoint.bound = true
	endpoint.port = port
	net.set_blocking(socket, false)
	if port != 0 {
		fmt.printf("Network endpoint bound to UDP port %d\n", port)
	}
	return true
}

network_shutdown :: proc(endpoint: ^Network_Endpoint) {
	if endpoint.bound {
		net.close(endpoint.socket)
		endpoint.bound = false
	}
}

network_send :: proc(endpoint: ^Network_Endpoint, buffer: []u8, size: int, to: net.Endpoint) -> bool {
	if !endpoint.bound || size <= 0 {
		return false
	}
	_, err := net.send_udp(endpoint.socket, buffer[:size], to)
	return err == nil
}

network_receive :: proc(endpoint: ^Network_Endpoint, buffer: []u8) -> (bytes_read: int, from: net.Endpoint, ok: bool) {
	if !endpoint.bound {
		return 0, {}, false
	}
	n, ep, err := net.recv_udp(endpoint.socket, buffer)
	if err != nil || n <= 0 {
		return 0, {}, false
	}
	return n, ep, true
}

// Peek at header
packet_header :: proc(buffer: []u8) -> (ptype: Packet_Type, ok: bool) {
	if len(buffer) < 2 || buffer[0] != PROTOCOL_VERSION {
		return .Invalid, false
	}
	return Packet_Type(buffer[1]), true
}

@(private = "file")
write_header :: proc(w: ^Byte_Writer, ptype: Packet_Type) {
	bw_u8(w, PROTOCOL_VERSION)
	bw_u8(w, u8(ptype))
}

@(private = "file")
read_header :: proc(r: ^Byte_Reader, expect: Packet_Type) -> bool {
	if br_u8(r) != PROTOCOL_VERSION {
		return false
	}
	return Packet_Type(br_u8(r)) == expect && r.ok
}

// ---------------------------------------------------------------------------
// Client → Server

serialize_client_hello :: proc(buffer: []u8) -> int {
	w := bw_init(buffer)
	write_header(&w, .Client_Hello)
	return w.ok ? w.pos : 0
}

serialize_client_join :: proc(packet: ^Client_Join_Packet, buffer: []u8) -> int {
	w := bw_init(buffer)
	write_header(&w, .Client_Join)
	bw_u8(&w, u8(packet.team))
	bw_name(&w, packet.name)
	return w.ok ? w.pos : 0
}

deserialize_client_join :: proc(buffer: []u8) -> (packet: Client_Join_Packet, ok: bool) {
	r := br_init(buffer)
	if !read_header(&r, .Client_Join) {
		return {}, false
	}
	packet.team = Team_ID(br_u8(&r))
	packet.name = br_name(&r)
	return packet, r.ok
}

@(private = "file")
input_flags :: proc(input: Input_State) -> u8 {
	f: u8 = 0
	if input.jump   { f |= 1 }
	if input.sprint { f |= 2 }
	return f
}

serialize_client_input :: proc(packet: ^Client_Input_Packet, buffer: []u8) -> int {
	w := bw_init(buffer)
	write_header(&w, .Client_Input)
	bw_u32(&w, packet.newest_tick)
	count := min(int(packet.count), INPUT_REDUNDANCY)
	bw_u8(&w, u8(count))
	for i in 0..<count {
		in_ := packet.inputs[i]
		bw_i8(&w, quant_axis(in_.move_fwd))
		bw_i8(&w, quant_axis(in_.move_str))
		bw_u8(&w, input_flags(in_))
		bw_i16(&w, quant_angle(in_.yaw))
		bw_i16(&w, quant_angle(in_.pitch))
		bw_u8(&w, u8(in_.charge_spell))
		bw_u8(&w, u8(in_.cast_spell))
		bw_u8(&w, u8(in_.target_id))
	}
	return w.ok ? w.pos : 0
}

deserialize_client_input :: proc(buffer: []u8) -> (packet: Client_Input_Packet, ok: bool) {
	r := br_init(buffer)
	if !read_header(&r, .Client_Input) {
		return {}, false
	}
	packet.newest_tick = br_u32(&r)
	count := min(int(br_u8(&r)), INPUT_REDUNDANCY)
	packet.count = u8(count)
	for i in 0..<count {
		in_: Input_State
		in_.move_fwd = dequant_axis(br_i8(&r))
		in_.move_str = dequant_axis(br_i8(&r))
		flags := br_u8(&r)
		in_.jump = flags & 1 != 0
		in_.sprint = flags & 2 != 0
		in_.yaw = dequant_angle(br_i16(&r))
		in_.pitch = dequant_angle(br_i16(&r))
		in_.charge_spell = spell_id_from_wire(br_u8(&r))
		in_.cast_spell = spell_id_from_wire(br_u8(&r))
		in_.target_id = entity_id_from_wire(br_u8(&r))
		packet.inputs[i] = in_
	}
	return packet, r.ok
}

// ---------------------------------------------------------------------------
// Server → Client

serialize_server_lobby :: proc(packet: ^Server_Lobby_Packet, buffer: []u8) -> int {
	w := bw_init(buffer)
	write_header(&w, .Server_Lobby)
	for i in 0..<TEAM_COUNT { bw_u8(&w, packet.humans[i]) }
	for i in 0..<TEAM_COUNT { bw_u8(&w, packet.bots[i]) }
	bw_u8(&w, packet.team_size)
	bw_u8(&w, u8(packet.reject))
	return w.ok ? w.pos : 0
}

deserialize_server_lobby :: proc(buffer: []u8) -> (packet: Server_Lobby_Packet, ok: bool) {
	r := br_init(buffer)
	if !read_header(&r, .Server_Lobby) {
		return {}, false
	}
	for i in 0..<TEAM_COUNT { packet.humans[i] = br_u8(&r) }
	for i in 0..<TEAM_COUNT { packet.bots[i] = br_u8(&r) }
	packet.team_size = br_u8(&r)
	packet.reject = Lobby_Reject(br_u8(&r))
	return packet, r.ok
}

serialize_server_welcome :: proc(packet: ^Server_Welcome_Packet, buffer: []u8) -> int {
	w := bw_init(buffer)
	write_header(&w, .Server_Welcome)
	bw_u8(&w, u8(packet.your_entity_id))
	bw_u8(&w, u8(packet.team))
	return w.ok ? w.pos : 0
}

deserialize_server_welcome :: proc(buffer: []u8) -> (packet: Server_Welcome_Packet, ok: bool) {
	r := br_init(buffer)
	if !read_header(&r, .Server_Welcome) {
		return {}, false
	}
	packet.your_entity_id = Entity_ID(br_u8(&r))
	packet.team = Team_ID(br_u8(&r))
	return packet, r.ok
}

// The worst case has to stay under MAX_PACKET_SIZE: the writer refuses an
// oversized packet and the client simply stops hearing from us in exactly the
// crowded fight where it matters most. Spelling the budget out as constants
// rather than a comment means adding a field to a snapshot record breaks the
// build here instead of breaking the game at sixteen players.
SNAPSHOT_HEADER_BYTES :: 2 + 4 + 4 + 5   // version+type, tick, ack, five counts
SNAPSHOT_ENTITY_BYTES :: 1 + 12 + 12 + 2 + 2 + 1 + 1 + 1 + 4 + 1 + 1 + 2
                                          // id, pos, vel, yaw, pitch, flags, hp, mana, stamina, team, slow, cast
SNAPSHOT_PROJECTILE_BYTES :: 4 + 1 + 1 + 12 + 12 + 1 + 1
SNAPSHOT_STRIKE_BYTES :: 1 + 1 + 6
SNAPSHOT_BEAM_BYTES   :: 1 + 1 + 6 + 1 + BEAM_MAX_CHAINS
SNAPSHOT_EVENT_BYTES  :: 1 + 1 + 1 + 1 + 2

SNAPSHOT_WORST_BYTES ::
	SNAPSHOT_HEADER_BYTES +
	MAX_SNAPSHOT_ENTITIES * SNAPSHOT_ENTITY_BYTES +
	MAX_SNAPSHOT_PROJECTILES * SNAPSHOT_PROJECTILE_BYTES +
	MAX_SNAPSHOT_STRIKES * SNAPSHOT_STRIKE_BYTES +
	MAX_SNAPSHOT_BEAMS * SNAPSHOT_BEAM_BYTES +
	MAX_SNAPSHOT_COMBAT_EVENTS * SNAPSHOT_EVENT_BYTES

#assert(SNAPSHOT_WORST_BYTES <= MAX_PACKET_SIZE)

// id, team, bot flag, kills, deaths, damage dealt, damage taken, length-prefixed name
ROSTER_ENTRY_BYTES :: 1 + 1 + 1 + 1 + 1 + 2 + 2 + 1 + MAX_PLAYER_NAME_LEN
ROSTER_WORST_BYTES :: 2 + 1 + MAX_ROSTER_ENTRIES * ROSTER_ENTRY_BYTES

#assert(ROSTER_WORST_BYTES <= MAX_PACKET_SIZE)

// The combat events cost one body out of the nearest twenty-two. That is the
// whole price of the feature, because names and the scoreline went into the
// roster packet instead of in here.
//
// Look angles ride as the same i16 an input is quantized to rather than as
// floats. That is lossless here -- the server's yaw and pitch come from a
// quantized input in the first place, so the client reconciles against exactly
// the numbers it predicted with -- and the four bytes it frees pay for the cast
// orb without costing anyone a body they could otherwise see.
serialize_server_snapshot :: proc(packet: ^Server_Snapshot_Packet, buffer: []u8) -> int {
	w := bw_init(buffer)
	write_header(&w, .Server_Snapshot)
	bw_u32(&w, packet.tick_id)
	bw_u32(&w, packet.ack_input_tick)

	ecount := min(int(packet.entity_count), MAX_SNAPSHOT_ENTITIES)
	bw_u8(&w, u8(ecount))
	for i in 0..<ecount {
		e := &packet.entities[i]
		bw_u8(&w, u8(e.id))
		bw_vec3(&w, e.pos)
		bw_vec3(&w, e.vel)
		bw_i16(&w, quant_angle(e.yaw))
		bw_i16(&w, quant_angle(e.pitch))
		flags: u8 = 0
		if e.on_ground { flags |= 1 }
		if e.dead      { flags |= 2 }
		if e.is_bot    { flags |= 4 }
		bw_u8(&w, flags)
		bw_u8(&w, quant_u8(e.health, 1))
		bw_u8(&w, quant_u8(e.mana, 1))
		bw_f32(&w, e.stamina)
		bw_u8(&w, u8(e.team))
		bw_u8(&w, u8(clamp(e.slow_ticks, 0, 255)))
		bw_u8(&w, u8(e.channel_spell))
		bw_u8(&w, quant_u8(e.channel_frac, 255))
	}

	pcount := min(int(packet.projectile_count), MAX_SNAPSHOT_PROJECTILES)
	bw_u8(&w, u8(pcount))
	for i in 0..<pcount {
		p := &packet.projectiles[i]
		bw_u32(&w, p.id)
		bw_u8(&w, u8(p.spell_id))
		bw_u8(&w, u8(p.owner_id))
		bw_vec3(&w, p.pos)
		bw_vec3(&w, p.vel)
		bw_u8(&w, quant_u8(p.lifetime, 20))   // 0.05 s resolution, max 12.75 s
		bw_u8(&w, quant_u8(p.radius, 100))    // cm
	}

	scount := min(int(packet.strike_count), MAX_SNAPSHOT_STRIKES)
	bw_u8(&w, u8(scount))
	for i in 0..<scount {
		s := &packet.strikes[i]
		bw_u8(&w, s.seq)
		bw_u8(&w, u8(s.owner_id))
		bw_pos_cm(&w, s.pos)
	}

	bcount := min(int(packet.beam_count), MAX_SNAPSHOT_BEAMS)
	bw_u8(&w, u8(bcount))
	for i in 0..<bcount {
		b := &packet.beams[i]
		bw_u8(&w, u8(b.owner_id))
		bw_u8(&w, u8(b.spell_id))
		bw_pos_cm(&w, b.end)
		chains := min(int(b.chain_count), BEAM_MAX_CHAINS)
		flags := u8(chains) << 1
		if b.hit { flags |= 1 }
		bw_u8(&w, flags)
		for j in 0..<BEAM_MAX_CHAINS {
			bw_u8(&w, j < chains ? u8(b.chains[j]) : 0)
		}
	}

	ccount := min(int(packet.combat_event_count), MAX_SNAPSHOT_COMBAT_EVENTS)
	bw_u8(&w, u8(ccount))
	for i in 0..<ccount {
		c := &packet.combat_events[i]
		bw_u8(&w, c.seq)
		bw_u8(&w, u8(c.event_type))
		bw_u8(&w, u8(c.other_id))
		bw_u8(&w, u8(c.spell_id))
		bw_u16(&w, c.damage)
	}
	return w.ok ? w.pos : 0
}

deserialize_server_snapshot :: proc(buffer: []u8) -> (packet: Server_Snapshot_Packet, ok: bool) {
	r := br_init(buffer)
	if !read_header(&r, .Server_Snapshot) {
		return {}, false
	}
	packet.tick_id = br_u32(&r)
	packet.ack_input_tick = br_u32(&r)

	ecount := min(int(br_u8(&r)), MAX_SNAPSHOT_ENTITIES)
	for i in 0..<ecount {
		e := &packet.entities[i]
		e.id = Entity_ID(br_u8(&r))
		e.pos = br_vec3(&r)
		e.vel = br_vec3(&r)
		e.yaw = dequant_angle(br_i16(&r))
		e.pitch = dequant_angle(br_i16(&r))
		flags := br_u8(&r)
		e.on_ground = flags & 1 != 0
		e.dead = flags & 2 != 0
		e.is_bot = flags & 4 != 0
		e.health = f32(br_u8(&r))
		e.mana = f32(br_u8(&r))
		e.stamina = br_f32(&r)
		e.team = Team_ID(br_u8(&r))
		e.slow_ticks = int(br_u8(&r))
		e.channel_spell = spell_id_from_wire(br_u8(&r))
		e.channel_frac = f32(br_u8(&r)) / 255.0
		if !r.ok {
			return {}, false
		}
	}
	packet.entity_count = u8(ecount)

	pcount := min(int(br_u8(&r)), MAX_SNAPSHOT_PROJECTILES)
	for i in 0..<pcount {
		p := &packet.projectiles[i]
		p.id = br_u32(&r)
		p.spell_id = Spell_ID(br_u8(&r))
		if !spell_valid(p.spell_id) {
			// Never let a wire byte index the spell table out of range.
			p.spell_id = .None
		}
		p.owner_id = Entity_ID(br_u8(&r))
		p.pos = br_vec3(&r)
		p.vel = br_vec3(&r)
		p.lifetime = f32(br_u8(&r)) / 20.0
		p.radius = f32(br_u8(&r)) / 100.0
		if !r.ok {
			return {}, false
		}
	}
	packet.projectile_count = u8(pcount)

	scount := min(int(br_u8(&r)), MAX_SNAPSHOT_STRIKES)
	for i in 0..<scount {
		s := &packet.strikes[i]
		s.seq = br_u8(&r)
		s.owner_id = entity_id_from_wire(br_u8(&r))
		s.pos = br_pos_cm(&r)
		if !r.ok {
			return {}, false
		}
	}
	packet.strike_count = u8(scount)

	bcount := min(int(br_u8(&r)), MAX_SNAPSHOT_BEAMS)
	for i in 0..<bcount {
		b := &packet.beams[i]
		b.owner_id = entity_id_from_wire(br_u8(&r))
		b.spell_id = spell_id_from_wire(br_u8(&r))
		b.end = br_pos_cm(&r)
		flags := br_u8(&r)
		b.hit = flags & 1 != 0
		b.chain_count = min(flags >> 1, BEAM_MAX_CHAINS)
		for j in 0..<BEAM_MAX_CHAINS {
			b.chains[j] = entity_id_from_wire(br_u8(&r))
		}
		if !r.ok {
			return {}, false
		}
	}
	packet.beam_count = u8(bcount)

	ccount := min(int(br_u8(&r)), MAX_SNAPSHOT_COMBAT_EVENTS)
	for i in 0..<ccount {
		c := &packet.combat_events[i]
		c.seq = br_u8(&r)
		c.event_type = combat_event_type_from_wire(br_u8(&r))
		c.other_id = entity_id_from_wire(br_u8(&r))
		c.spell_id = spell_id_from_wire(br_u8(&r))
		c.damage = br_u16(&r)
		if !r.ok {
			return {}, false
		}
	}
	packet.combat_event_count = u8(ccount)
	return packet, r.ok
}

serialize_server_roster :: proc(packet: ^Server_Roster_Packet, buffer: []u8) -> int {
	w := bw_init(buffer)
	write_header(&w, .Server_Roster)
	count := min(int(packet.count), MAX_ROSTER_ENTRIES)
	bw_u8(&w, u8(count))
	for i in 0..<count {
		e := &packet.entries[i]
		bw_u8(&w, u8(e.id))
		bw_u8(&w, u8(e.team))
		bw_u8(&w, e.is_bot ? 1 : 0)
		bw_u8(&w, u8(min(e.stats.kills, 255)))
		bw_u8(&w, u8(min(e.stats.deaths, 255)))
		bw_u16(&w, u16(clampf(e.stats.damage_dealt, 0, 65535)))
		bw_u16(&w, u16(clampf(e.stats.damage_taken, 0, 65535)))
		bw_name(&w, e.name)
	}
	return w.ok ? w.pos : 0
}

deserialize_server_roster :: proc(buffer: []u8) -> (packet: Server_Roster_Packet, ok: bool) {
	r := br_init(buffer)
	if !read_header(&r, .Server_Roster) {
		return {}, false
	}
	count := min(int(br_u8(&r)), MAX_ROSTER_ENTRIES)
	for i in 0..<count {
		e := &packet.entries[i]
		e.id = entity_id_from_wire(br_u8(&r))
		e.team = team_from_wire(br_u8(&r))
		e.is_bot = br_u8(&r) != 0
		e.stats.kills = u16(br_u8(&r))
		e.stats.deaths = u16(br_u8(&r))
		e.stats.damage_dealt = f32(br_u16(&r))
		e.stats.damage_taken = f32(br_u16(&r))
		e.name = br_name(&r)
		if !r.ok {
			return {}, false
		}
	}
	packet.count = u8(count)
	return packet, r.ok
}

serialize_server_gamestate :: proc(packet: ^Server_GameState_Packet, buffer: []u8) -> int {
	w := bw_init(buffer)
	write_header(&w, .Server_GameState)
	bw_u8(&w, packet.match_state)
	bw_u8(&w, packet.match_result)
	bw_u8(&w, packet.winner)
	for i in 0..<TEAM_COUNT { bw_f32(&w, packet.essence[i]) }
	bw_f32(&w, packet.match_time)
	for i in 0..<TEAM_COUNT { bw_u8(&w, packet.humans[i]) }
	for i in 0..<MAX_OBELISKS {
		o := &packet.obelisks[i]
		bw_u8(&w, o.state)
		bw_u8(&w, o.owner)
		bw_u8(&w, o.capturing)
		bw_u8(&w, quant_u8(o.progress, 255))
	}
	return w.ok ? w.pos : 0
}

deserialize_server_gamestate :: proc(buffer: []u8) -> (packet: Server_GameState_Packet, ok: bool) {
	r := br_init(buffer)
	if !read_header(&r, .Server_GameState) {
		return {}, false
	}
	packet.match_state = br_u8(&r)
	packet.match_result = br_u8(&r)
	packet.winner = br_u8(&r)
	for i in 0..<TEAM_COUNT { packet.essence[i] = br_f32(&r) }
	packet.match_time = br_f32(&r)
	for i in 0..<TEAM_COUNT { packet.humans[i] = br_u8(&r) }
	for i in 0..<MAX_OBELISKS {
		o := &packet.obelisks[i]
		o.state = br_u8(&r)
		o.owner = br_u8(&r)
		o.capturing = br_u8(&r)
		o.progress = f32(br_u8(&r)) / 255.0
	}
	return packet, r.ok
}
