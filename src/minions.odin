package main

import "core:fmt"
import "core:math"

// Lane minions: the layer that spends the four wallets.
//
// Every WAVE_PERIOD_SEC each team gets a wave out of its base. The base wave
// is free. Each coloured ore then buys at most one extra body, and only while
// the wallet still holds WAVE_ORE_COST: own ore is one more fodder, a rival's
// ore is one pusher aimed at the *other* rival's lane. Leftover ore waits for
// the next wave, so a stack of 100 is ten waves of one extra, not a flood.
// Gold is the exception: the whole stack still buys one heavy that stays home.
//
// Minions are deliberately not entities. A Character_State carries mana, a
// spell bar, a name and a roster slot, and there are only MAX_ENTITIES of them
// for every human and bot in the match; a wave would eat the table and the
// snapshot both. What a minion actually needs is a position, a team, some
// health and one job, so it gets its own pool and its own small snapshot
// record. The cost of that choice is that nothing which names an Entity_ID can
// touch them: Call Lightning and Friendly Heal pass them by, exactly the way
// they pass a pylon by, and only positional damage -- projectiles, splash and
// beams -- finds them.
//
// See MINIONS.md for the design this implements.

MAX_MINIONS          :: 48
MAX_MINIONS_PER_TEAM :: 16

Minion_ID :: u16

Minion_Kind :: enum u8 {
	None   = 0,
	Fodder = 1,  // the default wave: drops ore, rebuilds towers, explodes
	Pusher = 2,  // bought with a rival's ore, walks the third team's lane
	Heavy  = 3,  // bought with gold, holds its own lane
}

Minion_Mode :: enum u8 {
	Advance,  // walking toward its objective
	Rush,     // committed to a body or another minion
	Rebuild,  // at a damaged friendly pylon, about to become part of it
}

// ---------------------------------------------------------------------------
// Tuning
//
// Everything in this block is a starting number, not a design decision. The
// design is in which wallet buys what; how much of it a wave gets is meant to
// be moved around once something has actually walked a lane.

WAVE_PERIOD_SEC  :: f32(30.0)
WAVE_FODDER_BASE :: 3        // what a team that banked nothing still gets

// One extra body per coloured ore per wave, paid up front. 100 ore is ten
// waves of one extra, then the wallet is empty. Gold does not use this.
WAVE_ORE_COST :: f32(10.0)

// Gold buys one heavy, and only while the last one is dead. The whole stack
// is dumped into that one body: HEAVY_GOLD_COST is the 1.0x HP mark.
HEAVY_GOLD_COST :: f32(90.0)

MINION_FODDER_HP :: f32(55.0)
MINION_PUSHER_HP :: f32(85.0)
MINION_HEAVY_HP  :: f32(420.0)

MINION_SPEED_FODDER :: f32(3.6)
MINION_SPEED_PUSHER :: f32(3.9)
MINION_SPEED_HEAVY  :: f32(2.7)

// Body. Fatter and shorter than a wisp so a wave reads as a different thing
// from a lane full of players at a glance.
MINION_RADIUS_M :: f32(0.34)
MINION_HEIGHT_M :: f32(1.05)

// A rush commits inside MINION_AGGRO_R and is dropped past MINION_LEASH_R, so
// fodder cannot be walked away from their lane by one player kiting them.
MINION_AGGRO_R    :: f32(9.0)
MINION_LEASH_R    :: f32(17.0)
MINION_CONTACT_R  :: f32(1.35)
MINION_RETARGET_S :: f32(0.25)

// The suicide. Fodder go off hard enough that a choke held alone is a real
// risk; a pusher's burst is smaller because a wave can bring one per rival,
// and the heavy has none at all -- 420 health dying in your face would be a wipe
// nobody could read coming.
MINION_BURST_DAMAGE_FODDER :: f32(26.0)
MINION_BURST_RADIUS_FODDER :: f32(3.0)
MINION_BURST_DAMAGE_PUSHER :: f32(17.0)
MINION_BURST_RADIUS_PUSHER :: f32(2.6)
MINION_BURST_KNOCKBACK     :: f32(5.0)

// The heavy holds ground instead of trading itself in, so it needs something
// to hold it with.
HEAVY_SWIPE_DAMAGE :: f32(30.0)
HEAVY_SWIPE_RADIUS :: f32(2.8)
HEAVY_SWIPE_CD     :: f32(1.4)

// A fodder that reaches a damaged friendly tower becomes part of it: one
// donation, then it is gone. Three waves of the free fodder put half a lane
// tower back. An extra fodder bought with own ore is another body that can hop.
MINION_BUILD_RADIUS :: f32(3.4)
MINION_BUILD_REACH  :: f32(2.6)  // how close to the rock a hop has to get

// Missing this much rock and a friendly tower is worth diverting a wave to.
// Deliberately not "any damage at all": a wave that peeled off for a 2% graze
// would never reach the centre.
PYLON_REBUILD_FRAC :: f32(0.85)

// The golden pylon must be fully rebuilt (every original node live) before
// the team that put most of it there has won the round. Chip damage does not
// delay the claim: `intact` is live_count / max_count, not remaining HP.
CENTRE_CLAIM_FRAC :: f32(1.0)

// Only fodder pay out, and only in their own team's ore. This is the renewable
// trickle the whole economy runs on: kill their wave, walk over their rock.
MINION_ORE_DROP :: f32(10.0)

// How many live nodes close the centre race. 1.0 of 24 is 24; a fractional
// threshold rounds up so 0.80 of 24 would be 20, not 19.
centre_claim_nodes :: proc(t: ^Tower) -> int {
	if t == nil || t.max_count <= 0 {
		return 0
	}
	needed := int(math.ceil(CENTRE_CLAIM_FRAC * f32(t.max_count)))
	if needed < 1 {
		needed = 1
	} else if needed > t.max_count {
		needed = t.max_count
	}
	return needed
}

centre_claim_ready :: proc(t: ^Tower) -> bool {
	return t != nil && t.max_count > 0 && t.live_count >= centre_claim_nodes(t)
}

// ---------------------------------------------------------------------------

Minion :: struct {
	active: bool,
	id:     Minion_ID,
	kind:   Minion_Kind,
	team:   Team_ID,  // who it fights for
	lane:   Team_ID,  // whose corridor it walks; its own, except for pushers

	pos: vec3,        // feet, on the floor plane
	yaw: f32,

	health:     f32,
	health_max: f32,
	speed:      f32,
	build_r:    f32,  // rebuild radius; fodder carry MINION_BUILD_RADIUS

	mode:        Minion_Mode,
	objective:   Pylon_ID,
	has_pylon:   bool,   // objective is a tower to walk to, not just the centre
	rebuilding:  bool,   // that tower is friendly and wants rock, not mining

	prey_entity: Entity_ID,
	prey_slot:   int,     // index into minions, -1 for none
	prey_id:     Minion_ID,
	retarget:    f32,

	swipe_cd: f32,
	wiggle:    f32,  // committed lateral when the stream stalls, -1 / 0 / +1
	wiggle_t:  f32,
	stuck_t:   f32,
	stuck_at:  vec3,
	age:      f32,
}

Minion_World :: struct {
	minions: [MAX_MINIONS]Minion,
	count:   int,
	next_id: Minion_ID,

	wave_timer:  f32,
	wave_number: int,
}

// The live pool. Reachable the way `g_towers` is, because the damage paths that
// have to find minions -- projectile splash, the blast that carves rock -- are
// shared with the client and have no server handle to thread through. Nil on a
// client, which is what makes those paths no-ops there.
g_minions: ^Minion_World

minion_world_init :: proc(world: ^Minion_World) {
	world^ = {}
	world.next_id = 1
	g_minions = world
}

minion_world_reset :: proc(world: ^Minion_World) {
	for i in 0 ..< MAX_MINIONS {
		world.minions[i].active = false
	}
	world.count = 0
	world.wave_timer = 0
	world.wave_number = 0
}

minion_kind_name :: proc(kind: Minion_Kind) -> string {
	switch kind {
	case .Fodder: return "fodder"
	case .Pusher: return "pusher"
	case .Heavy:  return "heavy"
	case .None:   return "none"
	}
	return "none"
}

// The third team: the one that is neither `a` nor `b`. This is the whole
// triangle -- raid one neighbour, and what you buy with their rock walks at the
// other one, so a successful strip can never be turned into more automated
// pressure on the team you just stripped.
team_third :: proc(a, b: Team_ID) -> Team_ID {
	ia := team_index(a)
	ib := team_index(b)
	if ia < 0 || ib < 0 || ia == ib {
		return .None
	}
	return team_from_index(3 - ia - ib)
}

minion_count_for :: proc(world: ^Minion_World, team: Team_ID) -> (total: int, heavies: int) {
	for i in 0 ..< MAX_MINIONS {
		m := &world.minions[i]
		if !m.active || m.team != team {
			continue
		}
		total += 1
		if m.kind == .Heavy {
			heavies += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Spawning

// Where a wave forms up: in front of its own base, fanned across the lane mouth
// so the bodies do not all start inside one another.
minion_spawn_position :: proc(team: Team_ID, slot: int) -> vec3 {
	d := team_dir(team)
	side := vec3{-d.y, d.x, 0}
	lateral := f32((slot % 5) - 2) * 1.5
	back := f32((slot / 5) % 3) * 1.6
	p := d * (WORLD_BASE_R - 4.0 + back) + side * lateral
	p.z = WORLD_FLOOR_Z
	return p
}

@(private = "file")
minion_claim :: proc(world: ^Minion_World) -> ^Minion {
	for i in 0 ..< MAX_MINIONS {
		if world.minions[i].active {
			continue
		}
		m := &world.minions[i]
		m^ = Minion{}
		m.active = true
		m.id = world.next_id
		world.next_id += 1
		if world.next_id == 0 {
			world.next_id = 1
		}
		world.count += 1
		return m
	}
	return nil
}

minion_spawn :: proc(
	world:   ^Minion_World,
	kind:    Minion_Kind,
	team:    Team_ID,
	lane:    Team_ID,
	slot:    int,
	hp_mult: f32,
	build_r: f32,
) -> ^Minion {
	m := minion_claim(world)
	if m == nil {
		return nil
	}
	m.kind = kind
	m.team = team
	m.lane = lane
	m.pos = minion_spawn_position(team, slot)
	m.yaw = wrap_angle(team_angle(team) + PI_F32)
	switch kind {
	case .Fodder: m.health_max = MINION_FODDER_HP * hp_mult; m.speed = MINION_SPEED_FODDER
	case .Pusher: m.health_max = MINION_PUSHER_HP;           m.speed = MINION_SPEED_PUSHER
	case .Heavy:  m.health_max = MINION_HEAVY_HP * hp_mult;  m.speed = MINION_SPEED_HEAVY
	case .None:   m.health_max = 1;                          m.speed = 0
	}
	m.health = m.health_max
	m.build_r = build_r
	m.prey_entity = INVALID_ENTITY
	m.prey_slot = -1
	m.objective = 0
	return m
}

// One team's wave. The free fodder always walk. Each coloured ore then pays
// WAVE_ORE_COST for one extra body, at most one per colour, and the rest of
// the stack stays in the wallet. Gold is still dumped whole into one heavy.
//
// Spend only after the body exists. A failed claim must not eat the ore.
minion_wave_spawn :: proc(world: ^Minion_World, match: ^Match, team: Team_ID) {
	ti := team_index(team)
	if ti < 0 {
		return
	}
	alive, heavies := minion_count_for(world, team)
	room := MAX_MINIONS_PER_TEAM - alive
	if room <= 0 {
		return
	}
	slot := 0

	fodder := min(WAVE_FODDER_BASE, room)
	for _ in 0 ..< fodder {
		if minion_spawn(world, .Fodder, team, team, slot, 1, MINION_BUILD_RADIUS) == nil {
			break
		}
		slot += 1
	}
	room -= fodder

	// --- Own ore: one extra fodder on your own lane -------------------------
	own := team_ore(team)
	if room > 0 && match.wallets[ti][ore_index_of(own)] >= WAVE_ORE_COST {
		if minion_spawn(world, .Fodder, team, team, slot, 1, MINION_BUILD_RADIUS) != nil {
			match_spend_ore(match, team, own, WAVE_ORE_COST)
			slot += 1
			room -= 1
			fodder += 1
		}
	}

	// --- Rival ore: one pusher per colour, aimed around the triangle --------
	// Ember in the wallet sends a body at Tide, Tide sends one at Ember, and
	// the same rotation for the third colour. Steal from one neighbour, hit
	// the other.
	pushers := 0
	for rival in TEAMS {
		if rival == team || room <= 0 {
			continue
		}
		kind := team_ore(rival)
		target_lane := team_third(team, rival)
		if target_lane == .None {
			continue
		}
		if match.wallets[ti][ore_index_of(kind)] < WAVE_ORE_COST {
			continue
		}
		if minion_spawn(world, .Pusher, team, target_lane, slot, 1, 0) == nil {
			break
		}
		match_spend_ore(match, team, kind, WAVE_ORE_COST)
		slot += 1
		room -= 1
		pushers += 1
	}

	// --- Gold: one heavy, dump the whole stack, scale the body --------------
	//
	// Only while the last one is dead. Leftover gold is not a save for later:
	// HEAVY_GOLD_COST is the 1.0x mark, more gold is a thicker bodyguard, less
	// is a thinner one. Scaling one body reads in a 4.5 m lane; stacking
	// several would not.
	heavy := 0
	gold := match.wallets[ti][ore_index_of(.Gold)]
	if room > 0 && heavies == 0 && gold > 0 && match_spend_ore(match, team, .Gold, gold) {
		hp := clampf(gold / HEAVY_GOLD_COST, 0.35, 2.5)
		if minion_spawn(world, .Heavy, team, team, slot, hp, 0) != nil {
			heavy = 1
		}
	}

	if SERVER_VERBOSE {
		server_log("[Wave] %s: %d fodder, %d pushers, %d heavy",
			team_name(team), fodder, pushers, heavy)
	}
}

// ---------------------------------------------------------------------------
// Queries used by the damage paths

minion_alive :: proc(world: ^Minion_World, slot: int) -> bool {
	if world == nil || slot < 0 || slot >= MAX_MINIONS {
		return false
	}
	return world.minions[slot].active && world.minions[slot].health > 0
}

// Centre of the body, which is what everything aims at and lights.
minion_center :: proc(m: ^Minion) -> vec3 {
	return m.pos + vec3{0, 0, MINION_HEIGHT_M * 0.5}
}

// Nearest minion hostile to `team` along a ray. Mirrors `tower_raycast` so the
// three things a beam can land on -- a body, a minion, a tower -- are all found
// the same way.
minion_raycast :: proc(world: ^Minion_World, team: Team_ID, ro, rd: vec3, max_t: f32) -> (t: f32, slot: int, hit: bool) {
	if world == nil {
		return 0, -1, false
	}
	best := max_t
	found := -1
	for i in 0 ..< MAX_MINIONS {
		m := &world.minions[i]
		if !m.active || m.health <= 0 || !teams_are_enemies(team, m.team) {
			continue
		}
		if d, ok := ray_cylinder_hit(ro, rd, m.pos, MINION_RADIUS_M, MINION_HEIGHT_M, best); ok {
			best = d
			found = i
		}
	}
	if found < 0 {
		return 0, -1, false
	}
	return best, found, true
}

// First minion hostile to `team` whose body a sphere at `at` is touching.
minion_sphere_hit :: proc(world: ^Minion_World, team: Team_ID, at: vec3, radius: f32, skip_mask: u64 = 0) -> (slot: int, hit: bool) {
	if world == nil {
		return -1, false
	}
	for i in 0 ..< MAX_MINIONS {
		m := &world.minions[i]
		if !m.active || m.health <= 0 || !teams_are_enemies(team, m.team) {
			continue
		}
		if skip_mask & (u64(1) << u64(i)) != 0 {
			continue
		}
		dx := at.x - m.pos.x
		dy := at.y - m.pos.y
		reach := radius + MINION_RADIUS_M
		if dx * dx + dy * dy > reach * reach {
			continue
		}
		dz := at.z - m.pos.z
		if dz < -radius || dz > MINION_HEIGHT_M + radius {
			continue
		}
		return i, true
	}
	return -1, false
}

// Take health off one minion. Death is not resolved here: `minions_tick` reaps
// anything at zero, so a burst that kills three of them cannot recurse through
// this call and blow up the stack in a crowd.
minion_damage :: proc(world: ^Minion_World, slot: int, amount: f32) {
	if world == nil || slot < 0 || slot >= MAX_MINIONS || amount <= 0 {
		return
	}
	m := &world.minions[slot]
	if !m.active {
		return
	}
	m.health -= amount
}

// A blast at `at`: every minion hostile to `team` inside `radius` takes up to
// `damage`, falling off to half at the edge. Same shape as `splash_damage`, and
// called from it, so one detonation cannot treat bodies and minions differently.
minion_splash :: proc(world: ^Minion_World, at: vec3, team: Team_ID, damage, radius: f32) {
	if world == nil || radius <= 0 || damage <= 0 {
		return
	}
	for i in 0 ..< MAX_MINIONS {
		m := &world.minions[i]
		if !m.active || m.health <= 0 || !teams_are_enemies(team, m.team) {
			continue
		}
		d := minion_center(m) - at
		dist := len_vec3(d)
		if dist > radius {
			continue
		}
		if !world_segment_clear(at, minion_center(m), 0.8) {
			continue
		}
		m.health -= damage * (1.0 - 0.5 * (dist / radius))
	}
}

// ---------------------------------------------------------------------------
// Objectives

// Is this tower one a minion of `team` should be putting rock back into?
//
// Its own team's towers when they are visibly broken, and the centre stump once
// the golden pylon is gone -- from then on the centre is everybody's to rebuild
// until every node is live, and whoever has laid the most then takes the round.
minion_rebuildable :: proc(towers: ^Tower_World, match: ^Match, id: Pylon_ID, team: Team_ID) -> bool {
	t := tower_get(towers, id)
	if t == nil {
		return false
	}
	if t.owner == .None {
		return match.centre_open && !centre_claim_ready(t)
	}
	return t.owner == team && t.intact < PYLON_REBUILD_FRAC
}

// Nearest damaged friendly tower, or none.
//
// Nearest rather than "the one furthest down the lane": with two hurt towers in
// one corridor, chip damage on the far pylon would otherwise vacuum up the wave
// that should be saving the inner one.
minion_pick_rebuild :: proc(towers: ^Tower_World, match: ^Match, at: vec3, team: Team_ID) -> (id: Pylon_ID, ok: bool) {
	best := -1
	best_d := f32(1e9)
	for i in 0 ..< towers.count {
		if !minion_rebuildable(towers, match, Pylon_ID(i), team) {
			continue
		}
		t := &towers.towers[i]
		d := len_vec3(vec3{t.base.x - at.x, t.base.y - at.y, 0})
		if d < best_d {
			best_d = d
			best = i
		}
	}
	if best < 0 {
		return 0, false
	}
	return Pylon_ID(best), true
}

// Deepest standing tower in a rival's corridor: what a pusher walks at.
@(private = "file")
minion_pick_push_target :: proc(towers: ^Tower_World, lane: Team_ID) -> (goal: vec3, ok: bool) {
	best := -1
	best_r := f32(-1)
	for i in 1 ..< towers.count {
		t := &towers.towers[i]
		if t.owner != lane || !tower_standing(towers, t.pylon_id) {
			continue
		}
		r := len_vec3(vec3{t.base.x, t.base.y, 0})
		if r > best_r {
			best_r = r
			best = i
		}
	}
	if best < 0 {
		return {}, false
	}
	return towers.towers[best].base, true
}

// Where this minion is trying to get to, and whether that place is a tower it
// intends to become part of.
@(private = "file")
minion_choose_objective :: proc(m: ^Minion, towers: ^Tower_World, match: ^Match) -> (goal: vec3) {
	m.has_pylon = false
	m.rebuilding = false

	switch m.kind {
	case .Fodder:
		if id, ok := minion_pick_rebuild(towers, match, m.pos, m.team); ok {
			m.objective = id
			m.has_pylon = true
			m.rebuilding = true
			return towers.towers[id].base
		}
		// Nothing of ours needs rock: walk at the golden centre like the doc says.
		m.objective = 0
		return pylon_base_position(0)

	case .Pusher:
		if goal, ok := minion_pick_push_target(towers, m.lane); ok {
			return goal
		}
		// Their towers are already down: keep walking their lane anyway.
		return team_dir(m.lane) * WORLD_LANE_R1

	case .Heavy:
		// A bodyguard, not a pusher: it sits on the near tower of its own lane
		// and lets the fight come to it.
		m.objective = Pylon_ID(team_index(m.team) + 1)
		m.has_pylon = true
		return pylon_base_position(int(m.objective))

	case .None:
	}
	return m.pos
}

// ---------------------------------------------------------------------------
// Prey

// The first enemy in range, body or minion, whichever is nearer. Bodies win
// ties: a wave that walks past a player to trade itself into another wave is
// not doing the job it was bought for.
@(private = "file")
minion_pick_prey :: proc(m: ^Minion, world: ^Minion_World, entities: ^Entity_World, self_slot: int) {
	m.prey_entity = INVALID_ENTITY
	m.prey_slot = -1
	m.prey_id = 0
	if m.kind == .Heavy {
		// The heavy does not chase; its swipe finds whatever walks into it.
		return
	}
	eye := minion_center(m)
	best := MINION_AGGRO_R * MINION_AGGRO_R

	for i in 1 ..< MAX_ENTITIES {
		id := Entity_ID(i)
		if !entity_alive(entities, id) || !teams_are_enemies(m.team, entities.teams[i]) {
			continue
		}
		d2 := len2_vec3(entities.characters[i].pos - m.pos)
		if d2 < best {
			best = d2
			m.prey_entity = id
		}
	}
	if m.prey_entity != INVALID_ENTITY {
		return
	}
	for i in 0 ..< MAX_MINIONS {
		if i == self_slot {
			continue
		}
		o := &world.minions[i]
		if !o.active || o.health <= 0 || !teams_are_enemies(m.team, o.team) {
			continue
		}
		d2 := len2_vec3(o.pos - m.pos)
		if d2 < best {
			best = d2
			m.prey_slot = i
			m.prey_id = o.id
		}
	}
}

// Where the thing this minion is rushing currently stands.
@(private = "file")
minion_prey_pos :: proc(m: ^Minion, world: ^Minion_World, entities: ^Entity_World) -> (at: vec3, ok: bool) {
	if m.prey_entity != INVALID_ENTITY {
		if !entity_alive(entities, m.prey_entity) {
			return {}, false
		}
		return entities.characters[m.prey_entity].pos, true
	}
	if m.prey_slot >= 0 && m.prey_slot < MAX_MINIONS {
		o := &world.minions[m.prey_slot]
		if !o.active || o.health <= 0 || o.id != m.prey_id {
			return {}, false
		}
		return o.pos, true
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Movement

@(private = "file")
minion_rot_xy :: proc(d: vec3, a: f32) -> vec3 {
	c := math.cos(a)
	s := math.sin(a)
	return {c * d.x - s * d.y, s * d.x + c * d.y, 0}
}

// Same corridor in the lane graph: a charge can run straight (crates are a
// local problem). Different corridor: the void between lanes is a wall, and
// the flow field is what knows to go via the plaza.
@(private = "file")
minion_same_corridor :: proc(from, to: vec3) -> bool {
	rf := world_region(from)
	rt := world_region(to)
	if rf.kind == .Plaza && rt.kind == .Plaza {
		return true
	}
	if rf.kind != .Plaza && rt.kind != .Plaza && rf.team == rt.team {
		return true
	}
	return false
}

// Probe a fan around `desired` and pick the opening that still points at the
// goal. Roomy gaps beat tight ones, so a crate in a 9 m lane always loses to
// the centreline side rather than the wall pocket the old hash-steer picked.
@(private = "file")
minion_clear_dir :: proc(pos: vec3, desired: vec3) -> vec3 {
	dir := norm_vec3(vec3{desired.x, desired.y, 0})
	if len2_vec3(dir) < 0.01 {
		return {}
	}
	angles := [7]f32{0, 0.40, -0.40, 0.80, -0.80, 1.20, -1.20}
	best := dir
	best_score := f32(-1)
	for a in angles {
		d := minion_rot_xy(dir, a)
		probe := pos + d * 1.35 + vec3{0, 0, MINION_HEIGHT_M * 0.5}
		if !world_point_free(probe, MINION_RADIUS_M) {
			continue
		}
		score: f32 = 1
		if world_point_free(probe, MINION_RADIUS_M + 0.55) {
			score = 3
		} else if world_point_free(probe, MINION_RADIUS_M + 0.25) {
			score = 2
		}
		score -= abs(a) * 0.15
		if score > best_score {
			best_score = score
			best = d
		}
	}
	if best_score < 0 {
		return dir
	}
	return best
}

@(private = "file")
minion_nudge_free :: proc(m: ^Minion) {
	if minion_spot_free(m.pos) {
		return
	}
	for k in 0 ..< 8 {
		a := f32(k) * (PI_F32 * 0.25)
		try := m.pos + vec3{math.cos(a), math.sin(a), 0} * 0.30
		if minion_spot_free(try) {
			m.pos = try
			m.pos.z = WORLD_FLOOR_Z
			return
		}
	}
}

// Walk toward `goal`. Advance and rebuild follow a flow field so crates and
// standing towers are downhill, not a coin-flip. A same-lane rush still
// charges the body -- the field would drag it toward a pylon -- but uses the
// same clearance fan so a crate between them is a detour, not a pin.
// Deliberately lighter than the character solver: no jump, no air, floor only.
@(private = "file")
minion_move :: proc(m: ^Minion, goal: vec3, dt: f32) {
	minion_nudge_free(m)

	to_goal := vec3{goal.x - m.pos.x, goal.y - m.pos.y, 0}
	if len2_vec3(to_goal) < 0.04 {
		return
	}

	dir: vec3
	use_flow := m.mode != .Rush || !minion_same_corridor(m.pos, goal)
	if use_flow {
		field := nav_flow_field_for(goal)
		if flow, ok := nav_flow_dir(field, m.pos); ok {
			if len2_vec3(flow) < 0.01 {
				return
			}
			dir = flow
		}
	}
	if len2_vec3(dir) < 0.01 {
		wp := nav_next_waypoint(m.pos, goal)
		dir = norm_vec3(vec3{wp.x - m.pos.x, wp.y - m.pos.y, 0})
	}
	if len2_vec3(dir) < 0.01 {
		return
	}

	// Spread the stream a little so a wave is a ribbon, not a single file.
	h := hash_u32(u32(m.id) * 2654435761)
	lat := (f32(h & 255) / 255.0) * 2.0 - 1.0
	side := vec3{-dir.y, dir.x, 0}
	dir = norm_vec3(dir + side * (0.16 * lat))

	m.wiggle_t -= dt
	if m.wiggle_t <= 0 {
		m.wiggle = 0
	}
	m.stuck_t += dt
	if m.stuck_t >= 0.65 {
		moved := vec3{m.pos.x - m.stuck_at.x, m.pos.y - m.stuck_at.y, 0}
		if len2_vec3(moved) < 0.35 * 0.35 {
			left := minion_rot_xy(dir, 1.1)
			right := minion_rot_xy(dir, -1.1)
			lf := world_point_free(m.pos + left * 1.4 + vec3{0, 0, MINION_HEIGHT_M * 0.5}, MINION_RADIUS_M)
			rf := world_point_free(m.pos + right * 1.4 + vec3{0, 0, MINION_HEIGHT_M * 0.5}, MINION_RADIUS_M)
			if lf && !rf {
				m.wiggle = 1
			} else if rf && !lf {
				m.wiggle = -1
			} else {
				m.wiggle = (h & 1) == 0 ? -1 : 1
			}
			m.wiggle_t = 0.9
		}
		m.stuck_at = m.pos
		m.stuck_t = 0
	}
	if m.wiggle != 0 {
		dir = norm_vec3(dir + side * (0.85 * m.wiggle))
	}

	dir = minion_clear_dir(m.pos, dir)
	if len2_vec3(dir) < 0.01 {
		return
	}

	step := dir * (m.speed * dt)
	try := m.pos + step
	if minion_spot_free(try) {
		m.pos = try
	} else {
		// Slide along the thing we hit, not along the world axes -- lanes are
		// at 120° and axis-separation is what parked waves on crate faces.
		from := m.pos + vec3{0, 0, MINION_HEIGHT_M * 0.5}
		hit := try + vec3{0, 0, MINION_HEIGHT_M * 0.5}
		n := world_surface_normal(from, hit, MINION_RADIUS_M)
		n.z = 0
		n = norm_vec3(n)
		slide := dir - n * (n.x * dir.x + n.y * dir.y)
		if len2_vec3(slide) > 0.01 {
			slide = norm_vec3(slide)
			try2 := m.pos + slide * (m.speed * dt)
			if minion_spot_free(try2) {
				m.pos = try2
				dir = slide
			}
		}
	}
	m.pos.z = WORLD_FLOOR_Z
	m.yaw = math.atan2(dir.y, dir.x)
}

minion_spot_free :: proc(pos: vec3) -> bool {
	offs := [3]vec3{
		{0, 0, 0.12},
		{0, 0, MINION_HEIGHT_M * 0.5},
		{0, 0, MINION_HEIGHT_M * 0.9},
	}
	for o in offs {
		if !world_point_free(pos + o, MINION_RADIUS_M) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Tick

minions_tick :: proc(
	world:    ^Minion_World,
	entities: ^Entity_World,
	towers:   ^Tower_World,
	chunks:   ^Ore_Chunk_World,
	match:    ^Match,
	dt:       f32,
	live:     bool,
) {
	// Waiting is not a match. A wave that walked out during warmup would still
	// be on the floor when the wallets were zeroed, and Ended is a freeze until
	// the round reset clears the pool.
	if !live || match.state != .Active {
		return
	}

	nav_flow_sync(towers)

	// --- Waves ---------------------------------------------------------------
	world.wave_timer -= dt
	if world.wave_timer <= 0 {
		world.wave_timer += WAVE_PERIOD_SEC
		world.wave_number += 1
		for team in TEAMS {
			minion_wave_spawn(world, match, team)
		}
		if SERVER_VERBOSE {
			minions_report(world)
		}
	}

	// --- Think and move ------------------------------------------------------
	for i in 0 ..< MAX_MINIONS {
		m := &world.minions[i]
		if !m.active || m.health <= 0 {
			continue
		}
		m.age += dt
		m.swipe_cd = max(m.swipe_cd - dt, 0)

		m.retarget -= dt
		if m.retarget <= 0 {
			m.retarget = MINION_RETARGET_S
			minion_pick_prey(m, world, entities, i)
		}

		goal := minion_choose_objective(m, towers, match)

		if prey, ok := minion_prey_pos(m, world, entities); ok {
			// Leashed to the lane: chase too far and the rush is dropped, so one
			// player cannot walk a whole wave off its job.
			if len2_vec3(prey - m.pos) < MINION_LEASH_R * MINION_LEASH_R {
				m.mode = .Rush
				goal = prey
			} else {
				m.prey_entity = INVALID_ENTITY
				m.prey_slot = -1
				m.mode = .Advance
			}
		} else {
			m.prey_entity = INVALID_ENTITY
			m.prey_slot = -1
			m.mode = m.rebuilding ? .Rebuild : .Advance
		}

		// The heavy does not chase, so the rush branch never fires for it. It
		// swipes whatever is already standing against it, on its own cadence.
		if m.kind == .Heavy {
			minion_heavy_swipe(world, entities, m, i)
		}

		// Arrived at something?
		if m.mode == .Rush {
			if len2_vec3(vec3{goal.x - m.pos.x, goal.y - m.pos.y, 0}) <= MINION_CONTACT_R * MINION_CONTACT_R {
				// The suicide. Zeroing health rather than bursting here puts
				// it through the one death path, so a rush that connects and
				// a rush that is shot down go off identically.
				m.health = 0
				continue
			}
		} else if m.mode == .Rebuild && m.has_pylon {
			t := tower_get(towers, m.objective)
			if t != nil {
				reach := t.design_radius + MINION_BUILD_REACH
				if len2_vec3(vec3{t.base.x - m.pos.x, t.base.y - m.pos.y, 0}) <= reach * reach {
					minion_donate(world, towers, match, m, i)
					continue
				}
			}
		}

		minion_move(m, goal, dt)
	}

	// --- Reap ----------------------------------------------------------------
	for i in 0 ..< MAX_MINIONS {
		m := &world.minions[i]
		if !m.active || m.health > 0 {
			continue
		}
		minion_die(world, entities, chunks, m, i)
	}
}

// A fodder reaching a damaged friendly tower is spent on it: the donation lands
// on the seam between the rock that is still there and the silhouette that is
// not, and the body is gone. That is why a flattened tower comes back in waves
// rather than continuously -- it costs bodies, and the bodies were going to the
// centre.
@(private = "file")
minion_donate :: proc(world: ^Minion_World, towers: ^Tower_World, match: ^Match, m: ^Minion, slot: int) {
	t := tower_get(towers, m.objective)
	if t == nil {
		minion_remove(world, slot)
		return
	}
	gained, ok := tower_build(towers, m.objective, tower_donate_count(m.build_r), m.team)
	if ok && gained > 0 && t.owner == .None {
		match_credit_centre(match, m.team, gained)
	}
	minion_remove(world, slot)
}

// The heavy's swipe: everything hostile standing against it, players and
// minions alike. No projectile, no wind-up -- it is the price of walking into
// the thing that is holding the lane.
@(private = "file")
minion_heavy_swipe :: proc(world: ^Minion_World, entities: ^Entity_World, m: ^Minion, slot: int) {
	if m.swipe_cd > 0 {
		return
	}
	at := minion_center(m)
	reach2 := HEAVY_SWIPE_RADIUS * HEAVY_SWIPE_RADIUS
	hit := false
	for i in 1 ..< MAX_ENTITIES {
		id := Entity_ID(i)
		if !entity_alive(entities, id) || !teams_are_enemies(m.team, entities.teams[i]) {
			continue
		}
		center := entities.characters[i].pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
		if len2_vec3(center - at) > reach2 {
			continue
		}
		combat_apply_damage(entities, INVALID_ENTITY, id, .None, HEAVY_SWIPE_DAMAGE)
		hit = true
	}
	for i in 0 ..< MAX_MINIONS {
		if i == slot {
			continue
		}
		o := &world.minions[i]
		if !o.active || o.health <= 0 || !teams_are_enemies(m.team, o.team) {
			continue
		}
		if len2_vec3(minion_center(o) - at) > reach2 {
			continue
		}
		o.health -= HEAVY_SWIPE_DAMAGE
		hit = true
	}
	if hit {
		m.swipe_cd = HEAVY_SWIPE_CD
	}
}

// One death path for every way a minion can stop existing except the donation:
// the burst, then the ore, then the slot.
//
// The burst is nobody's kill. A minion has no Entity_ID to credit, which is the
// same reason a tower cannot be targeted -- there is nothing on the other end of
// `combat_apply_damage` to name.
@(private = "file")
minion_die :: proc(world: ^Minion_World, entities: ^Entity_World, chunks: ^Ore_Chunk_World, m: ^Minion, slot: int) {
	at := minion_center(m)
	damage: f32 = 0
	radius: f32 = 0
	switch m.kind {
	case .Fodder: damage = MINION_BURST_DAMAGE_FODDER; radius = MINION_BURST_RADIUS_FODDER
	case .Pusher: damage = MINION_BURST_DAMAGE_PUSHER; radius = MINION_BURST_RADIUS_PUSHER
	case .Heavy, .None:
	}
	if damage > 0 {
		// `splash_damage` reaches the lane bodies as well as the players, so
		// the burst is one call: a fodder that goes off in a crowd hurts both
		// halves of it without either being counted twice.
		splash_damage(entities, at, INVALID_ENTITY, m.team, INVALID_ENTITY, .None,
			damage, radius, MINION_BURST_KNOCKBACK)
	}

	// Only fodder pay out, and only in their own team's ore. A pusher or a heavy
	// was bought with ore that is already spent; killing one is the reward.
	if m.kind == .Fodder {
		ore_chunk_spawn_loose(chunks, team_ore(m.team), m.pos + vec3{0, 0, 0.35}, MINION_ORE_DROP)
	}
	minion_remove(world, slot)
}

@(private = "file")
minion_remove :: proc(world: ^Minion_World, slot: int) {
	if slot < 0 || slot >= MAX_MINIONS {
		return
	}
	if world.minions[slot].active {
		world.minions[slot].active = false
		world.count -= 1
	}
}

minions_report :: proc(world: ^Minion_World) {
	counts: [TEAM_COUNT]int
	for i in 0 ..< MAX_MINIONS {
		m := &world.minions[i]
		if !m.active {
			continue
		}
		if ti := team_index(m.team); ti >= 0 {
			counts[ti] += 1
		}
	}
	fmt.printf("[Minions] wave %d in %.0fs | %d/%d/%d\n",
		world.wave_number, world.wave_timer, counts[0], counts[1], counts[2])
}
