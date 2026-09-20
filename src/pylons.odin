package main

// Ore vocabulary: the shared constants, types and helpers for the four
// currencies and the seven tower placements. Gameplay authority for mining,
// collision and scoring is the spiral shield-node system in tower_nodes.odin.
//
// You cannot mine your own team's pylons. That is the whole shape of the mode:
// your towers are your ore reserve and someone else has to come take it.

Pylon_ID :: u8
MAX_PYLONS :: 7

// The four currencies. One ore per team plus the gold that only the centre
// yields.
Ore_Kind :: enum u8 {
	None    = 0,
	Ember   = 1,  // Alpha
	Tide    = 2,  // Beta
	Verdant = 3,  // Gamma
	Gold    = 4,
}

ORE_COUNT :: 4

ore_index_of :: proc(kind: Ore_Kind) -> int {
	switch kind {
	case .Ember:   return 0
	case .Tide:    return 1
	case .Verdant: return 2
	case .Gold:    return 3
	case .None:    return -1
	}
	return -1
}

ore_from_index :: proc(i: int) -> Ore_Kind {
	switch i {
	case 0: return .Ember
	case 1: return .Tide
	case 2: return .Verdant
	case 3: return .Gold
	}
	return .None
}

ore_from_wire :: proc(v: u8) -> Ore_Kind {
	if v > u8(Ore_Kind.Gold) {
		return .None
	}
	return Ore_Kind(v)
}

// A team's own ore. Gold belongs to no team.
team_ore :: proc(team: Team_ID) -> Ore_Kind {
	switch team {
	case .Alpha: return .Ember
	case .Beta:  return .Tide
	case .Gamma: return .Verdant
	case .None, .Spectator: return .None
	}
	return .None
}

ore_team :: proc(kind: Ore_Kind) -> Team_ID {
	switch kind {
	case .Ember:   return .Alpha
	case .Tide:    return .Beta
	case .Verdant: return .Gamma
	case .Gold, .None: return .None
	}
	return .None
}

// Matches `ore_tint` in shaders/scene.glsl so the HUD reads in the same colours
// as the rock it is counting.
ore_color :: proc(kind: Ore_Kind) -> vec3 {
	switch kind {
	case .Ember:   return {1.00, 0.44, 0.24}
	case .Tide:    return {0.34, 0.68, 1.00}
	case .Verdant: return {0.42, 0.95, 0.52}
	case .Gold:    return {1.00, 0.82, 0.32}
	case .None:    return {0.55, 0.55, 0.58}
	}
	return {0.55, 0.55, 0.58}
}

ore_name :: proc(kind: Ore_Kind) -> string {
	switch kind {
	case .Ember:   return "ember"
	case .Tide:    return "tide"
	case .Verdant: return "verdant"
	case .Gold:    return "gold"
	case .None:    return "none"
	}
	return "none"
}

// ---------------------------------------------------------------------------
// Tower placement and shape constants

// Lane pylons stay well under the 14 m arena ceiling so the whole column is
// in view from the floor. Gold is taller, still with headroom.
PYLON_NEAR_HEIGHT :: f32(6.0)
PYLON_NEAR_RADIUS :: f32(2.4)
PYLON_FAR_HEIGHT  :: f32(5.5)
PYLON_FAR_RADIUS  :: f32(2.2)
PYLON_GOLD_HEIGHT :: f32(9.0)
PYLON_GOLD_RADIUS :: f32(3.6)

// Divides incoming carve amount. The golden pylon is meant to take a
// coordinated effort over minutes, not one player with a beam.
PYLON_TOUGHNESS_TEAM :: f32(1.0)
PYLON_TOUGHNESS_GOLD :: f32(4.5)

// Mining cadence. A held beam bites at a fixed rate rather than every tick,
// so mining has an audible rhythm instead of melting the rock smoothly.
MINE_BITE_HZ    :: f32(10.0)
MINE_BITE_DT    :: 1.0 / MINE_BITE_HZ
MINE_BITE_MIN_R :: f32(0.30)
