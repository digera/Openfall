package main

import "core:fmt"

// Match state machine: Waiting → Active → Ended → (auto) Waiting

Match_State :: enum u8 {
	Waiting,
	Active,
	Ended,
}

Match_Result :: enum u8 {
	None,
	Team_Wins,   // see Match.winner
	Draw,
}

Match :: struct {
	state:          Match_State,
	result:         Match_Result,
	winner:         Team_ID,

	// Four currencies per team: one ore per rival team plus the gold from the
	// centre. Which ore you are holding is what decides what your next minion
	// wave can do, so they are tracked separately rather than summed.
	wallets:        [TEAM_COUNT][ORE_COUNT]f32,
	// Scoreboard. The sum of everything a team has banked, spent or not.
	// It never ends the round; the centre does.
	essence:        [TEAM_COUNT]f32,

	// The golden pylon has been flattened and the stump is up for rebuilding.
	// `centre_build` is the voxels each team's waves have put back into it
	// since; whoever has laid the most when it is fully rebuilt wins.
	centre_open:    bool,
	centre_build:   [TEAM_COUNT]f32,

	match_time:     f32,
	ended_time:     f32,     // seconds spent in Ended

	round_number:   int,
	rounds_played:  int,
}

WARMUP_DURATION :: f32(8.0)
ENDED_DURATION  :: f32(12.0)

// Zero, and off. Essence is a scoreboard: a team that mines gold all match
// without ever touching the centre has a fine score and has not won anything.
// NEXUS_TEST_ESSENCE puts a threshold back so a test can finish a round in
// seconds without waiting for the golden pylon to come down.
test_essence_threshold := f32(0)
test_essence_multiplier := f32(1.0)

@(private = "file")
match_quiet: bool

match_configure_test_mode :: proc(win_threshold: f32, essence_multiplier: f32) {
	test_essence_threshold = win_threshold
	test_essence_multiplier = essence_multiplier
	fmt.printf("[Match] Test mode: win at %.0f essence, %.1fx generation\n",
		test_essence_threshold, test_essence_multiplier)
}

match_init :: proc() -> Match {
	match_selftest()
	return Match{
		state        = .Waiting,
		result       = .None,
		round_number = 1,
	}
}

// Returns true when the match just transitioned back to Waiting (caller resets the world).
match_tick :: proc(match: ^Match, dt: f32) -> (restarted: bool) {
	switch match.state {
	case .Waiting:
		match.match_time += dt
		if match.match_time >= WARMUP_DURATION {
			match_start(match)
		}

	case .Active:
		match.match_time += dt

		if test_essence_threshold > 0 {
			for i in 0..<TEAM_COUNT {
				if match.essence[i] >= test_essence_threshold {
					match_end(match, .Team_Wins, team_from_index(i))
					return false
				}
			}
		}

	case .Ended:
		match.ended_time += dt
		if match.ended_time >= ENDED_DURATION {
			match_reset(match)
			return true
		}
	}
	return false
}

// Bank ore a player walked over. Instant, no carry. The only way essence moves.
//
// Gold is worth more than ore because there is one source of it and everyone has
// to fight in the open for it.
match_credit_ore :: proc(match: ^Match, team: Team_ID, kind: Ore_Kind, amount: f32) {
	idx := team_index(team)
	slot := ore_index_of(kind)
	if idx < 0 || slot < 0 || amount <= 0 {
		return
	}
	match.wallets[idx][slot] += amount
	match.essence[idx] += amount * ore_score_value(kind) * test_essence_multiplier
}

ore_score_value :: proc(kind: Ore_Kind) -> f32 {
	return kind == .Gold ? 3.0 : 1.0
}

// Spend from a wallet, if it can be paid in full. Returns false and takes
// nothing when it cannot -- a partial spend would be a half-summoned minion.
match_spend_ore :: proc(match: ^Match, team: Team_ID, kind: Ore_Kind, amount: f32) -> bool {
	idx := team_index(team)
	slot := ore_index_of(kind)
	if idx < 0 || slot < 0 {
		return false
	}
	if match.wallets[idx][slot] < amount {
		return false
	}
	match.wallets[idx][slot] -= amount
	return true
}

// The golden pylon is the round.
//
// While it stands it is only the richest rock in the arena. The moment it is
// gone the centre is a stump every team's wave will hop, and the team that has
// laid the most when every node is live takes the round. That is the one win
// condition that belongs to this map: three teams fighting over who gets to
// finish the tower they all just knocked down. A tie on rock laid is a draw.
match_centre_tick :: proc(match: ^Match, towers: ^Tower_World) {
	if match.state != .Active {
		return
	}
	t := tower_get(towers, 0)
	if t == nil {
		return
	}
	if !match.centre_open {
		if t.live_count == 0 {
			match.centre_open = true
			match.centre_build = {}
			if !match_quiet {
				fmt.println("[Match] The golden pylon is down. Rebuild the centre to win the round.")
			}
		}
		return
	}
	if !centre_claim_ready(t) {
		return
	}
	best := 0
	tie := false
	for i in 1..<TEAM_COUNT {
		if match.centre_build[i] > match.centre_build[best] {
			best = i
			tie = false
		} else if match.centre_build[i] == match.centre_build[best] {
			tie = true
		}
	}
	// Somebody has to have built it. A centre that filled itself is a bug, not
	// a winner.
	if match.centre_build[best] <= 0 {
		return
	}
	if tie {
		if !match_quiet {
			fmt.printf("[Match] The golden pylon is whole. Draw (%.0f / %.0f / %.0f)\n",
				match.centre_build[0], match.centre_build[1], match.centre_build[2])
		}
		match_end(match, .Draw, .None)
		return
	}
	if !match_quiet {
		fmt.printf("[Match] The golden pylon is whole. %s laid the most (%.0f / %.0f / %.0f)\n",
			team_name(team_from_index(best)),
			match.centre_build[0], match.centre_build[1], match.centre_build[2])
	}
	match_end(match, .Team_Wins, team_from_index(best))
}

// Rock one team's wave has put back into the centre stump.
match_credit_centre :: proc(match: ^Match, team: Team_ID, voxels: int) {
	idx := team_index(team)
	if idx < 0 || voxels <= 0 || !match.centre_open {
		return
	}
	match.centre_build[idx] += f32(voxels)
}

match_start :: proc(match: ^Match) {
	match.state = .Active
	match.match_time = 0
	match.essence = {}
	match.wallets = {}
	match.centre_open = false
	match.centre_build = {}
	match.result = .None
	match.winner = .None
	fmt.printf("[Match] Round %d started (bring the centre down, then build it back)\n", match.round_number)
}

match_end :: proc(match: ^Match, result: Match_Result, winner: Team_ID) {
	match.state = .Ended
	match.result = result
	match.winner = winner
	match.ended_time = 0
	match.rounds_played += 1

	if !match_quiet {
		if result == .Team_Wins {
			fmt.printf("[Match] Round over. %s wins (%.0f / %.0f / %.0f)\n",
				team_name(winner), match.essence[0], match.essence[1], match.essence[2])
		} else {
			fmt.printf("[Match] Round over. Draw (%.0f / %.0f / %.0f)\n",
				match.essence[0], match.essence[1], match.essence[2])
		}
	}
}

match_reset :: proc(match: ^Match) {
	match.state = .Waiting
	match.result = .None
	match.winner = .None
	match.essence = {}
	match.wallets = {}
	match.centre_open = false
	match.centre_build = {}
	match.match_time = 0
	match.ended_time = 0
	match.round_number += 1
	fmt.printf("[Match] Warmup for round %d\n", match.round_number)
}

// ---------------------------------------------------------------------------
// Self-test

@(private = "file")
match_selftest_ran: bool

@(private = "file")
match_test_set_live :: proc(t: ^Tower, live: int) {
	n := live
	if n < 0 {
		n = 0
	} else if n > t.max_count {
		n = t.max_count
	}
	for i in 0 ..< t.max_count {
		alive := i < n
		t.nodes[i].alive = alive
		t.nodes[i].hp = alive ? 1 : 0
		t.nodes[i].max_hp = 1
	}
	t.live_count = n
	tower_recompute(t)
}

@(private = "file")
match_test_fresh :: proc() -> (m: Match, world: Tower_World) {
	m = Match{
		state = .Active,
	}
	world.count = 1
	t := &world.towers[0]
	t.pylon_id = 0
	t.owner = .None
	t.ore = .Gold
	t.max_count = TOWER_NODES_GOLD
	t.node_radius = 0.5
	t.stack_step = 1
	t.design_height = 8
	return
}

match_selftest :: proc() {
	if match_selftest_ran {
		return
	}
	match_selftest_ran = true
	match_quiet = true
	defer { match_quiet = false }

	// Flattening the gold tower opens the race and does not end the round.
	{
		m, world := match_test_fresh()
		t := &world.towers[0]
		match_test_set_live(t, 0)
		match_centre_tick(&m, &world)
		assert(m.centre_open, "flatten opens the centre")
		assert(m.state == .Active, "flatten does not end the round")
	}

	// The old 80% close must not win. One missing node must not win.
	{
		m, world := match_test_fresh()
		t := &world.towers[0]
		m.centre_open = true
		m.centre_build[1] = 20
		old_close := int(0.80 * f32(t.max_count) + 0.999)
		match_test_set_live(t, old_close)
		match_centre_tick(&m, &world)
		assert(m.state == .Active, "80% rebuilt does not win")
		assert(!centre_claim_ready(t), "80% is not a claim")

		match_test_set_live(t, t.max_count - 1)
		match_centre_tick(&m, &world)
		assert(m.state == .Active, "one missing node does not win")
		assert(minion_rebuildable(&world, &m, 0, .Alpha), "waves still hop a short centre")
	}

	// Every node live: most rock laid wins. Chips do not delay it.
	{
		m, world := match_test_fresh()
		t := &world.towers[0]
		m.centre_open = true
		m.centre_build[0] = 4
		m.centre_build[1] = 12
		m.centre_build[2] = 8
		match_test_set_live(t, t.max_count)
		for i in 0 ..< t.max_count {
			t.nodes[i].hp = 0.1
		}
		tower_recompute(t)
		assert(t.intact == 1, "chips do not change intact")
		assert(tower_mass_frac(t) < 1, "chips lower mass")
		assert(centre_claim_ready(t), "full live_count claims")
		assert(!minion_rebuildable(&world, &m, 0, .Alpha), "waves stop hopping a whole centre")
		match_centre_tick(&m, &world)
		assert(m.state == .Ended, "full rebuild ends the round")
		assert(m.result == .Team_Wins, "majority takes the round")
		assert(m.winner == .Beta, "highest centre_build wins")
	}

	// Equal rock laid is a draw, not Alpha-by-default.
	{
		m, world := match_test_fresh()
		t := &world.towers[0]
		m.centre_open = true
		m.centre_build[0] = 10
		m.centre_build[1] = 10
		m.centre_build[2] = 4
		match_test_set_live(t, t.max_count)
		match_centre_tick(&m, &world)
		assert(m.state == .Ended, "tied rebuild ends the round")
		assert(m.result == .Draw, "tied centre_build is a draw")
		assert(m.winner == .None, "a draw has no winner")
	}

	// A centre that filled itself is not a win.
	{
		m, world := match_test_fresh()
		t := &world.towers[0]
		m.centre_open = true
		match_test_set_live(t, t.max_count)
		match_centre_tick(&m, &world)
		assert(m.state == .Active, "zero centre_build does not end the round")
	}

	// Elapsed time does not end the round, even with a stacked scoreboard.
	{
		m, _ := match_test_fresh()
		m.match_time = 60 * 60
		m.essence = {999, 500, 100}
		_ = match_tick(&m, 1.0 / 60.0)
		assert(m.state == .Active, "clock does not end the round")
		assert(m.result == .None, "clock does not pick a winner")
	}
}
