package main

// Three-way team system for Nexus Dominion.

TEAM_COUNT :: 3

Team_ID :: enum u8 {
	None  = 0,
	Alpha = 1, // Ember   (red)
	Beta  = 2, // Tide    (blue)
	Gamma = 3, // Verdant (green)
}

TEAMS :: [TEAM_COUNT]Team_ID{.Alpha, .Beta, .Gamma}

TEAM_ALPHA_COLOR :: vec3{1.00, 0.40, 0.30}
TEAM_BETA_COLOR  :: vec3{0.38, 0.66, 1.00}
TEAM_GAMMA_COLOR :: vec3{0.42, 0.95, 0.50}

team_name :: proc(team: Team_ID) -> string {
	switch team {
	case .Alpha: return "EMBER"
	case .Beta:  return "TIDE"
	case .Gamma: return "VERDANT"
	case .None:  return "NONE"
	}
	return "NONE"
}

team_color :: proc(team: Team_ID) -> vec3 {
	switch team {
	case .Alpha: return TEAM_ALPHA_COLOR
	case .Beta:  return TEAM_BETA_COLOR
	case .Gamma: return TEAM_GAMMA_COLOR
	case .None:  return {0.6, 0.6, 0.6}
	}
	return {0.6, 0.6, 0.6}
}

// 0..2 for real teams, -1 for None
team_index :: proc(team: Team_ID) -> int {
	switch team {
	case .Alpha: return 0
	case .Beta:  return 1
	case .Gamma: return 2
	case .None:  return -1
	}
	return -1
}

team_from_index :: proc(idx: int) -> Team_ID {
	switch idx {
	case 0: return .Alpha
	case 1: return .Beta
	case 2: return .Gamma
	}
	return .None
}

// No friendly fire; teamless entities are hostile to all.
teams_are_enemies :: proc(a, b: Team_ID) -> bool {
	if a == .None || b == .None {
		return true
	}
	return a != b
}

// Team-pick rule: you may not join a team that is strictly the most populated.
// If every team has the same count, every team is allowed.
team_join_allowed :: proc(counts: [TEAM_COUNT]int, team: Team_ID) -> bool {
	idx := team_index(team)
	if idx < 0 {
		return false
	}
	max_c := counts[0]
	min_c := counts[0]
	for c in counts {
		max_c = max(max_c, c)
		min_c = min(min_c, c)
	}
	if max_c == min_c {
		return true
	}
	return counts[idx] < max_c
}
