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
	// Score. For now the sum of everything a team has brought home, which is
	// what ends a round; the wave economy that actually spends the wallets is
	// the next phase.
	essence:        [TEAM_COUNT]f32,

	match_time:     f32,
	match_duration: f32,
	ended_time:     f32,     // seconds spent in Ended

	round_number:   int,
	rounds_played:  int,
}

ESSENCE_WIN_THRESHOLD  :: f32(1500.0)
DEFAULT_MATCH_DURATION :: f32(12 * 60)
WARMUP_DURATION        :: f32(8.0)
ENDED_DURATION         :: f32(12.0)

test_essence_threshold := ESSENCE_WIN_THRESHOLD
test_essence_multiplier := f32(1.0)

match_configure_test_mode :: proc(win_threshold: f32, essence_multiplier: f32) {
	test_essence_threshold = win_threshold
	test_essence_multiplier = essence_multiplier
	fmt.printf("[Match] Test mode: win at %.0f essence, %.1fx generation\n",
		test_essence_threshold, test_essence_multiplier)
}

match_init :: proc() -> Match {
	return Match{
		state          = .Waiting,
		result         = .None,
		match_duration = DEFAULT_MATCH_DURATION,
		round_number   = 1,
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

		for i in 0..<TEAM_COUNT {
			if match.essence[i] >= test_essence_threshold {
				match_end(match, .Team_Wins, team_from_index(i))
				return false
			}
		}
		if match.match_duration > 0 && match.match_time >= match.match_duration {
			best := 0
			tie := false
			for i in 1..<TEAM_COUNT {
				if match.essence[i] > match.essence[best] {
					best = i
					tie = false
				} else if match.essence[i] == match.essence[best] {
					tie = true
				}
			}
			if tie {
				match_end(match, .Draw, .None)
			} else {
				match_end(match, .Team_Wins, team_from_index(best))
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

// Bank ore a player carried home. The only way essence moves.
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

match_start :: proc(match: ^Match) {
	match.state = .Active
	match.match_time = 0
	match.essence = {}
	match.wallets = {}
	match.result = .None
	match.winner = .None
	fmt.printf("[Match] Round %d started (win at %.0f essence)\n", match.round_number, test_essence_threshold)
}

match_end :: proc(match: ^Match, result: Match_Result, winner: Team_ID) {
	match.state = .Ended
	match.result = result
	match.winner = winner
	match.ended_time = 0
	match.rounds_played += 1

	if result == .Team_Wins {
		fmt.printf("[Match] Round over. %s wins (%.0f / %.0f / %.0f)\n",
			team_name(winner), match.essence[0], match.essence[1], match.essence[2])
	} else {
		fmt.printf("[Match] Round over. Draw (%.0f / %.0f / %.0f)\n",
			match.essence[0], match.essence[1], match.essence[2])
	}
}

match_reset :: proc(match: ^Match) {
	match.state = .Waiting
	match.result = .None
	match.winner = .None
	match.essence = {}
	match.wallets = {}
	match.match_time = 0
	match.ended_time = 0
	match.round_number += 1
	fmt.printf("[Match] Warmup for round %d\n", match.round_number)
}
