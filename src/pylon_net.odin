package main

import "core:fmt"

// Keeping every client's pylons looking like the server's.
//
// A pylon's density field is 80 KB. It cannot be snapshotted, so it is not
// replicated -- it is reproduced. The server sends the quantized bites, every
// client runs the identical integer kernel from ore_grid.odin, and the fields
// stay equal because they are built from the same operations in the same order.
//
// Two things break that chain, and both have to be caught rather than hoped
// away. A client can miss bites, because the snapshot carries a fixed window of
// recent ones and a long enough stall rolls them off. And a collapse is not a
// bite at all: when a slab shears off, the server deletes a whole island of
// voxels, which no stream of carves describes. Either way the client notices a
// gap in the sequence and asks for the pylon wholesale, run-length coded.
//
// The grid on a client is cosmetic. The server alone decides what broke, what it
// yielded and what it collides with, so the worst a desync can do is show a
// slightly wrong crater for the fraction of a second before the resync lands.

PYLON_EVENT_RING :: 64

Pylon_Carve_Event :: struct {
	seq:   u16,
	pylon: Pylon_ID,
	build: bool,  // putting ore back rather than taking it out
	carve: Ore_Carve,
}

// Append a bite to the outgoing ring. The sequence is global across pylons so a
// client can detect a gap with one comparison instead of seven.
pylon_record_event :: proc(world: ^Pylon_World, id: Pylon_ID, carve: Ore_Carve, build := false) {
	ev := Pylon_Carve_Event{
		seq   = world.next_seq,
		pylon = id,
		build = build,
		carve = carve,
	}
	world.next_seq += 1
	if world.next_seq == 0 {
		world.next_seq = 1  // 0 means "nothing yet"
	}
	world.events[world.event_head % PYLON_EVENT_RING] = ev
	world.event_head += 1
}

// The most recent bites, oldest first, for a snapshot.
//
// Every bite therefore appears in several consecutive snapshots, which is what
// makes ordinary packet loss free. A client that stalls long enough for a bite
// to roll off the window resyncs instead, so the window is a bandwidth/latency
// trade rather than a correctness one.
pylon_recent_events :: proc(world: ^Pylon_World, dst: []Pylon_Carve_Event) -> int {
	n := min(len(dst), min(world.event_head, PYLON_EVENT_RING))
	start := world.event_head - n
	for k in 0 ..< n {
		dst[k] = world.events[(start + k) % PYLON_EVENT_RING]
	}
	return n
}

// ---------------------------------------------------------------------------
// Client-side application

Pylon_Client_Sync :: struct {
	// Highest bite applied. Everything up to here is accounted for.
	applied_seq: u16,
	// Pylons known to be wrong, waiting on a resync from the server.
	want:        u8,  // bit per pylon
	request_cd:  f32,
	primed:      bool,  // a first sync has landed; before that, ignore gaps
}

// Apply the bites from one snapshot, in order, and notice what was missed.
//
// Events arrive oldest-first and overlap heavily with the previous snapshot, so
// the normal path is "most of these are already applied, apply the tail".
pylon_client_apply :: proc(
	world: ^Pylon_World,
	sync:  ^Pylon_Client_Sync,
	events: []Pylon_Carve_Event,
) {
	if len(events) == 0 {
		return
	}
	for ev in events {
		if ev.seq == 0 {
			continue
		}
		// Already have it. u16 wrap is handled by comparing distance rather
		// than magnitude: a match runs nowhere near 65,535 bites.
		if seq_le_u16(ev.seq, sync.applied_seq) {
			continue
		}
		expected := sync.applied_seq + 1
		if sync.applied_seq == 0 {
			expected = ev.seq
		}
		if ev.seq != expected && sync.primed {
			// A gap: the bites in between are gone, so this pylon's field can
			// no longer be derived. Mark it and wait for the full copy.
			pylon_client_mark_stale(sync, ev.pylon)
		}
		pylon_apply_event(world, ev)
		sync.applied_seq = ev.seq
	}
}

pylon_client_mark_stale :: proc(sync: ^Pylon_Client_Sync, id: Pylon_ID) {
	if int(id) >= MAX_PYLONS {
		return
	}
	sync.want |= 1 << u8(id)
}

pylon_client_mark_all_stale :: proc(sync: ^Pylon_Client_Sync) {
	sync.want = (1 << MAX_PYLONS) - 1
}

// True when the client should ask for pylons again. Rate limited: a resync is
// several packets and a client that has fallen behind should not also flood.
pylon_client_should_request :: proc(sync: ^Pylon_Client_Sync, dt: f32) -> bool {
	if sync.request_cd > 0 {
		sync.request_cd -= dt
	}
	if sync.want == 0 || sync.request_cd > 0 {
		return false
	}
	sync.request_cd = 0.5
	return true
}

// Compare u16 sequence numbers across wraparound.
seq_le_u16 :: proc(a, b: u16) -> bool {
	return i16(a - b) <= 0
}

// ---------------------------------------------------------------------------
// Wholesale resync

// A resync payload is split into parts that each fit one datagram.
PYLON_SYNC_PART_BYTES :: 1200
// Budget for one pylon's run-length coded density. Comfortably above what a
// heavily mined pylon produces: only the thin shell of partially eroded voxels
// codes poorly, the untouched core and the mined-out void are long runs.
PYLON_SYNC_MAX_BYTES  :: 24 * 1024

// Shared scratch for encoding and decoding. Resyncs are infrequent and never
// concurrent, and 24 KB is not worth allocating per use.
@(private = "file") pylon_sync_buf: [PYLON_SYNC_MAX_BYTES]u8

Pylon_Sync_Kind :: enum u8 {
	Runs  = 0,  // payload is run-length coded density
	Whole = 1,  // no payload: rebuild the pylon untouched
}

// Encode one pylon for sending. `kind` is Whole in the pathological case where
// the density does not code inside the budget; the client then rebuilds the
// pristine pylon and lets the ongoing bite stream re-carve it, which is wrong
// for a moment and right thereafter.
pylon_sync_encode :: proc(world: ^Pylon_World, id: Pylon_ID) -> (payload: []u8, kind: Pylon_Sync_Kind) {
	g := pylon_grid(world, id)
	if g == nil {
		return nil, .Whole
	}
	n, ok := ore_grid_rle_encode(g, pylon_sync_buf[:])
	if !ok {
		fmt.printf("[Pylon %d] density did not code inside %d bytes; sending pristine\n",
			id, PYLON_SYNC_MAX_BYTES)
		return nil, .Whole
	}
	return pylon_sync_buf[:n], .Runs
}

// Reassembly state for one incoming pylon. Parts can arrive out of order, so
// the payload is written by offset and completion is counted.
Pylon_Sync_Rx :: struct {
	active:    bool,
	pylon:     Pylon_ID,
	kind:      Pylon_Sync_Kind,
	base_seq:  u16,
	total:     int,
	got:       int,
	parts:     int,
	got_parts: u16,  // bit per part; caps the split at 16 parts
	buf:       [PYLON_SYNC_MAX_BYTES]u8,
}

PYLON_SYNC_MAX_PARTS :: 16

pylon_sync_rx_begin :: proc(rx: ^Pylon_Sync_Rx, id: Pylon_ID, kind: Pylon_Sync_Kind, base_seq: u16, total, parts: int) -> bool {
	if parts > PYLON_SYNC_MAX_PARTS || total > PYLON_SYNC_MAX_BYTES {
		return false
	}
	if rx.active && rx.pylon == id && rx.base_seq == base_seq && rx.total == total {
		return true  // continuing an in-flight reassembly
	}
	rx.active = true
	rx.pylon = id
	rx.kind = kind
	rx.base_seq = base_seq
	rx.total = total
	rx.parts = parts
	rx.got = 0
	rx.got_parts = 0
	return true
}

pylon_sync_rx_part :: proc(rx: ^Pylon_Sync_Rx, part: int, data: []u8) -> (complete: bool) {
	if !rx.active || part < 0 || part >= rx.parts {
		return false
	}
	if rx.got_parts & (1 << u16(part)) != 0 {
		return rx.got == rx.total  // duplicate
	}
	off := part * PYLON_SYNC_PART_BYTES
	if off + len(data) > rx.total {
		return false
	}
	copy(rx.buf[off:off + len(data)], data)
	rx.got_parts |= 1 << u16(part)
	rx.got += len(data)
	return rx.got >= rx.total
}

// Install a completed resync. Bites older than `base_seq` are already baked
// into the payload, so the client's applied sequence jumps forward and the
// overlapping tail of the snapshot window is correctly skipped.
pylon_sync_rx_commit :: proc(
	world: ^Pylon_World,
	sync:  ^Pylon_Client_Sync,
	rx:    ^Pylon_Sync_Rx,
) -> bool {
	p := pylon_get(world, rx.pylon)
	g := pylon_grid(world, rx.pylon)
	if p == nil || g == nil {
		rx.active = false
		return false
	}
	ok := true
	switch rx.kind {
	case .Whole:
		ore_grid_build(g, p.shape)
	case .Runs:
		ok = ore_grid_rle_decode(g, rx.buf[:rx.total])
	}
	if !ok {
		fmt.printf("[Pylon %d] resync payload rejected\n", rx.pylon)
		rx.active = false
		return false
	}
	p.intact = ore_grid_intact(g)
	p.bound_z0, p.bound_z1, p.bound_r = ore_grid_bound(g)
	p.touched = true
	sync.want &= ~(1 << u8(rx.pylon))
	sync.primed = true
	if seq_le_u16(sync.applied_seq, rx.base_seq) {
		sync.applied_seq = rx.base_seq
	}
	rx.active = false
	return true
}

// ---------------------------------------------------------------------------
// Server-side send scheduling

// Per-client resync progress. A resync is several datagrams; they go out a
// couple per tick so one late joiner cannot crowd out everybody's snapshots.
Pylon_Sync_Tx :: struct {
	pending:  u8,        // bit per pylon still owed
	pylon:    Pylon_ID,  // the one being sent
	kind:     Pylon_Sync_Kind,
	base_seq: u16,
	total:    int,
	parts:    int,
	next:     int,  // next part index to send
	sending:  bool,
}

PYLON_SYNC_PARTS_PER_TICK :: 2

pylon_sync_tx_request :: proc(tx: ^Pylon_Sync_Tx, mask: u8) {
	tx.pending |= mask & ((1 << MAX_PYLONS) - 1)
}

// Pick the next pylon to send, if any. Called when the current one finishes.
pylon_sync_tx_advance :: proc(tx: ^Pylon_Sync_Tx, world: ^Pylon_World) -> bool {
	if tx.sending {
		return true
	}
	if tx.pending == 0 {
		return false
	}
	for i in 0 ..< MAX_PYLONS {
		bit := u8(1) << u8(i)
		if tx.pending & bit == 0 {
			continue
		}
		tx.pending &= ~bit
		payload, kind := pylon_sync_encode(world, Pylon_ID(i))
		tx.pylon = Pylon_ID(i)
		tx.kind = kind
		// Everything up to the current sequence is baked into this payload.
		tx.base_seq = world.next_seq == 1 ? 0 : world.next_seq - 1
		tx.total = len(payload)
		tx.parts = max(1, (len(payload) + PYLON_SYNC_PART_BYTES - 1) / PYLON_SYNC_PART_BYTES)
		tx.next = 0
		tx.sending = true
		return true
	}
	return false
}

// Slice of the payload for part `index` of the pylon currently being sent.
pylon_sync_tx_part :: proc(tx: ^Pylon_Sync_Tx, world: ^Pylon_World, index: int) -> []u8 {
	if tx.kind == .Whole || tx.total == 0 {
		return nil
	}
	payload, _ := pylon_sync_encode(world, tx.pylon)
	off := index * PYLON_SYNC_PART_BYTES
	if off >= len(payload) {
		return nil
	}
	end := min(off + PYLON_SYNC_PART_BYTES, len(payload))
	return payload[off:end]
}

pylon_sync_tx_done_part :: proc(tx: ^Pylon_Sync_Tx) {
	tx.next += 1
	if tx.next >= tx.parts {
		tx.sending = false
	}
}
