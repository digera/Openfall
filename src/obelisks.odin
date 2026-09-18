package main

import "core:fmt"

// Nexus Obelisk capture points.
//
// Seven Obelisks: one in the center plaza (double essence), one near each lane
// mouth, and one far down each lane. Standing alone in a capture volume captures
// it; two or more teams present contest it. Held Obelisks generate essence for
// the owner.

Obelisk_ID :: u8
MAX_OBELISKS :: 7

Obelisk_State :: enum u8 {
	Neutral,
	Contested,
	Capturing,
	Held,
}

Obelisk :: struct {
	id:               Obelisk_ID,
	pos:              vec3,
	radius:           f32,
	essence_mult:     f32,
	state:            Obelisk_State,
	owner:            Team_ID,
	capturing_team:   Team_ID,
	capture_progress: f32,          // 0..1

	counts:           [TEAM_COUNT]int, // living players per team inside the volume
}

Obelisk_World :: struct {
	obelisks: [MAX_OBELISKS]Obelisk,
	count:    int,
}

CAPTURE_TIME    :: f32(6.0)
// Per owned obelisk (center counts double). Total map output with 7 obelisks is
// 8 essence/s (center=2, 6 lanes=6). Full map control reaches 1500 in ~3 minutes;
// holding 4-5 objectives takes ~5-7 minutes. Fits the 12 minute match limit.
ESSENCE_PER_SEC :: f32(3.6)
OBELISK_RADIUS  :: f32(3.6)
OBELISK_HEIGHT  :: f32(4.0)

obelisk_world_init :: proc() -> Obelisk_World {
	world := Obelisk_World{}
	for i in 0..<MAX_OBELISKS {
		world.obelisks[i] = Obelisk{
			id           = Obelisk_ID(i),
			pos          = obelisk_position(i),
			radius       = OBELISK_RADIUS,
			essence_mult = i == 0 ? 2.0 : 1.0,
			state        = .Neutral,
			owner        = .None,
		}
	}
	world.count = MAX_OBELISKS
	fmt.println("[Obelisk] Initialized 7 capture points (center + 6 lane objectives)")
	return world
}

obelisk_world_reset :: proc(world: ^Obelisk_World) {
	for i in 0..<world.count {
		o := &world.obelisks[i]
		o.state = .Neutral
		o.owner = .None
		o.capturing_team = .None
		o.capture_progress = 0
	}
}

obelisk_contains :: proc(obelisk: ^Obelisk, pos: vec3) -> bool {
	dx := pos.x - obelisk.pos.x
	dy := pos.y - obelisk.pos.y
	dz := pos.z - obelisk.pos.z
	return dx * dx + dy * dy <= obelisk.radius * obelisk.radius && dz >= -0.1 && dz <= OBELISK_HEIGHT
}

obelisk_tick :: proc(world: ^Obelisk_World, entity_world: ^Entity_World, dt: f32) {
	for i in 0..<world.count {
		obelisk := &world.obelisks[i]
		obelisk.counts = {}

		for eid in 1..<MAX_ENTITIES {
			if !entity_alive(entity_world, Entity_ID(eid)) {
				continue
			}
			idx := team_index(entity_world.teams[eid])
			if idx < 0 {
				continue
			}
			if obelisk_contains(obelisk, entity_world.characters[eid].pos) {
				obelisk.counts[idx] += 1
			}
		}

		obelisk_update_state(obelisk, dt)
	}
}

obelisk_update_state :: proc(obelisk: ^Obelisk, dt: f32) {
	present_teams := 0
	present := Team_ID.None
	for i in 0..<TEAM_COUNT {
		if obelisk.counts[i] > 0 {
			present_teams += 1
			present = team_from_index(i)
		}
	}

	if present_teams >= 2 {
		if obelisk.state != .Contested {
			obelisk.state = .Contested
		}
		return
	}

	if present_teams == 0 {
		// Nobody here: partial captures decay back toward the previous state.
		if obelisk.state == .Capturing || obelisk.state == .Contested {
			obelisk.capture_progress -= dt / CAPTURE_TIME * 0.5
			if obelisk.capture_progress <= 0 {
				obelisk.capture_progress = 0
				obelisk.state = obelisk.owner == .None ? .Neutral : .Held
				obelisk.capturing_team = .None
			} else if obelisk.state == .Contested {
				obelisk.state = .Capturing
			}
		}
		return
	}

	// Exactly one team present.
	if obelisk.state == .Held && obelisk.owner == present {
		return
	}

	if obelisk.state != .Capturing || obelisk.capturing_team != present {
		obelisk.state = .Capturing
		obelisk.capturing_team = present
		obelisk.capture_progress = 0
	}

	// More players capture faster, with diminishing returns.
	n := obelisk.counts[team_index(present)]
	rate := 1.0 + 0.35 * f32(min(n, 3) - 1)
	obelisk.capture_progress += dt / CAPTURE_TIME * rate

	if obelisk.capture_progress >= 1.0 {
		obelisk.state = .Held
		obelisk.owner = present
		obelisk.capturing_team = .None
		obelisk.capture_progress = 1.0
		fmt.printf("[Obelisk %d] Captured by %s\n", obelisk.id, team_name(present))
	}
}

obelisk_get :: proc(world: ^Obelisk_World, id: Obelisk_ID) -> ^Obelisk {
	if int(id) >= world.count {
		return nil
	}
	return &world.obelisks[id]
}
