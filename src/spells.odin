package main

// Spell system

HEALTH_MAX  :: f32(300)
MANA_MAX    :: f32(300)
STAMINA_MAX :: f32(300)
// Stamina recovers fastest, mana in the middle, health slowest. The middle
// rate sits near 3/s; the spread is what keeps a transfer worth pressing.
HEALTH_REGEN_PER_SEC  :: f32(2)
MANA_REGEN_PER_SEC    :: f32(4)
STAMINA_REGEN_PER_SEC :: f32(8)

// Every transfer is the same exchange: pay 40 up front, gain 32 across the
// cooldown, and the drip ends when the cooldown does. A full loop returns
// about half of what it spent.
TRANSFER_COST        :: f32(40)
TRANSFER_GAIN        :: f32(32)
TRANSFER_COOLDOWN_SEC :: f32(8)

Spell_ID :: enum u8 {
	None = 0,

	Arcane_Missile = 1,    // bouncing bolt, pops after its ricochets run out
	Arcane_Orb     = 2,    // heavy lob, large splash on first contact
	Blink          = 3,    // short directional teleport
	Frost_Lance    = 4,    // straight piercing lance, heavy damage + slow
	Friendly_Heal  = 5,    // wind-up: ally gets an instant mend, self gets a mana transfer
	Call_Lightning = 6,    // hitscan bolt: the body under the crosshair at release
	Thunderbolt    = 7,    // held beam that arcs between nearby enemies
	Stamina_To_Mana   = 8, // instant: stamina buys mana over the cooldown
	Health_To_Stamina = 9, // instant: health buys stamina over the cooldown
	Gust              = 10, // instant: a wind rune on the floor ahead that throws whoever steps on it
}

// Spells bound to hotbar slots 1..HOTBAR_SLOTS. Friendly Heal lives on C, so
// the combat row closes up: what was 4, 5 and 6 is now 3, 4 and 5.
HOTBAR_SLOTS :: 5
HOTBAR := [HOTBAR_SLOTS]Spell_ID{.Arcane_Missile, .Arcane_Orb, .Frost_Lance, .Call_Lightning, .Thunderbolt}

// The keys beside the number row: E drops a Gust rune, Z and X are the
// transfers, C winds Friendly Heal. Gust sits on a key of its own because it is
// cast mid-hop, where swapping slots and back would cost the timing.
KEY_BINDS := [4]struct{key: string, spell: Spell_ID}{
	{"E", .Gust},
	{"Z", .Stamina_To_Mana},
	{"X", .Health_To_Stamina},
	{"C", .Friendly_Heal},
}

Spell_Target_Filter :: enum u8 {
	Any      = 0, // No filtering
	Enemy    = 1, // Hostile entities only
	Friendly = 2, // Friendly entities only (not self)
}

Spell_Def :: struct {
	id:            Spell_ID,
	name:          string,
	short_name:    string,
	mana_cost:     f32,
	cooldown_sec:  f32,
	cast_time:     f32,   // seconds of wind-up before a full-power fire

	payload:       Spell_Payload_Type,
	target_filter: Spell_Target_Filter, // who the sticky crosshair may hold; a strike does not use it

	proj_speed:    f32,
	proj_lifetime: f32,
	proj_radius:   f32,
	proj_gravity:  f32,   // fraction of PROJECTILE_GRAVITY_Z applied in flight
	proj_bounces:  int,   // ricochets off walls and floor before the projectile pops
	proj_restitution: f32, // speed kept per ricochet
	proj_pierce:   int,    // enemies speared before the projectile stops

	damage:          f32,
	aoe_radius:      f32,
	aoe_damage_frac: f32,   // splash damage as a fraction of `damage`
	knockback:       f32,
	slow_ticks:      int,

	// A blast that reaches its own caster. Zero for everything but the orb:
	// the share of the splash damage and of the knockback the caster takes
	// from their own detonation, so an orb at your feet is a jump you pay for.
	self_damage_frac:    f32,
	self_knockback_frac: f32,

	heal:          f32,   // health restored to each recipient at full charge
	range:         f32,   // blink distance, strike reach, heal reach, or beam length

	// Beams. `mana_cost` is what it takes to light one, not what it spends;
	// `cooldown_sec` is the rest forced on a beam that ran its caster dry.
	beam_dps:          f32,   // damage per second
	beam_mana_per_sec: f32,
	beam_chain_range:  f32,   // how far an arc jumps from the last body it hit
	beam_chain_count:  int,   // how many times
	beam_chain_frac:   f32,   // damage each jump deals, as a fraction of the beam's

	// Transfer. The cost leaves the source the moment the cast fires. The gain
	// drips into the destination for exactly the cooldown, then stops.
	transfer_from: Vital,
	transfer_to:   Vital,
	transfer_cost: f32,
	transfer_gain: f32,
}

// Which bar a transfer reads or writes.
Vital :: enum u8 {
	None = 0,
	Health,
	Mana,
	Stamina,
}

Spell_Payload_Type :: enum u8 {
	None = 0,
	Projectile,
	Teleport,
	Strike,     // hitscan: the hostile body under the crosshair when the wind-up ends
	Heal,       // instant health to a soft-targeted ally; the caster's mend is a transfer
	Beam,       // does its work every tick it is held; the release is nothing
	Transfer,   // spends one bar up front and drips another until the cooldown ends
	Pad,        // lays a Gust rune `range` ahead of the caster (gust_pads.odin)
}

SPELL_DEFS := [Spell_ID]Spell_Def{
	.None = {},

	// Ricochets down lanes and around cover. A bounce leans toward a nearby
	// visible enemy without replacing the bank; the pop is what does the work.
	.Arcane_Missile = {
		id               = .Arcane_Missile,
		name             = "Arcane Missile",
		short_name       = "MISSILE",
		mana_cost        = 12,
		cooldown_sec     = 0.2,
		cast_time        = 0.6,
		payload          = .Projectile,
		target_filter    = .Enemy,
		proj_speed       = 24,
		proj_lifetime    = 3.2,
		proj_radius      = 0.16,
		proj_gravity     = 0.45,
		proj_bounces     = 3,
		proj_restitution = 0.72,
		damage           = 18,
		aoe_radius       = 2.2,
		aoe_damage_frac  = 0.5,
	},

	// Lobbed: detonates on the first thing it touches, wide splash, and throws
	// everything in it -- its caster included. Aimed at your own feet it is a
	// rocket jump: a little of your own health and a hard landing for a lot of
	// height and speed.
	.Arcane_Orb = {
		id              = .Arcane_Orb,
		name            = "Arcane Orb",
		short_name      = "ORB",
		mana_cost       = 40,
		cooldown_sec    = 7.0,
		cast_time       = 1.2,
		payload         = .Projectile,
		target_filter   = .Enemy,
		proj_speed      = 26,
		proj_lifetime   = 4.0,
		proj_radius     = 0.45,
		proj_gravity    = 0.6,
		damage          = 55,
		aoe_radius      = 6.5,
		aoe_damage_frac = 0.75,
		knockback       = 20.0,
		self_damage_frac    = 0.3,
		self_knockback_frac = 0.75,
	},

	.Blink = {
		id            = .Blink,
		name          = "Blink",
		short_name    = "BLINK",
		mana_cost     = 20,
		cooldown_sec  = 8.0,
		cast_time     = 0.4,
		payload       = .Teleport,
		target_filter = .Any,
		range         = 11,
	},

	// Dead straight: no drop, holds its heading until a wall or a body.
	// Spears everyone lined up behind the first target.
	.Frost_Lance = {
		id            = .Frost_Lance,
		name          = "Frost Lance",
		short_name    = "LANCE",
		mana_cost     = 32,
		cooldown_sec  = 4.5,
		cast_time     = 0.9,
		payload       = .Projectile,
		target_filter = .Enemy,
		proj_speed    = 16,
		proj_lifetime = 5.0,
		proj_radius   = 0.28,
		proj_gravity  = 0,
		proj_pierce   = 4,
		damage        = 68,
		slow_ticks    = 180, // 3 s
	},

	// Sustain, not an escape. The caster pays 40 mana and receives 32 health
	// dripped across the cooldown; that drip is the self mend, and it ends
	// when the cooldown does. A teammate under the crosshair still gets the
	// instant 50, if they are in reach when it fires. A heal with nobody
	// missing health is refused rather than eating the mana.
	.Friendly_Heal = {
		id            = .Friendly_Heal,
		name          = "Friendly Heal",
		short_name    = "HEAL",
		mana_cost     = TRANSFER_COST,
		cooldown_sec  = TRANSFER_COOLDOWN_SEC,
		cast_time     = 1.0,
		payload       = .Heal,
		target_filter = .Friendly,
		range         = 18,
		heal          = 50,
		transfer_from = .Mana,
		transfer_to   = .Health,
		transfer_cost = TRANSFER_COST,
		transfer_gain = TRANSFER_GAIN,
	},

	// Placed when the button comes up, not locked when the wind-up starts.
	// The ray has to meet a hostile body or the bolt fizzles with the mana
	// unspent; cover and a minion in the way count as a miss. The long
	// wind-up is still the tell. Unlike Heal there is no soft target, so a
	// cursor that has drifted off the body spends the 1.8 s on nothing.
	.Call_Lightning = {
		id              = .Call_Lightning,
		name            = "Call Lightning",
		short_name      = "BOLT",
		mana_cost       = 60,
		cooldown_sec    = 8.0,
		cast_time       = 1.8,
		payload         = .Strike,
		target_filter   = .Enemy,
		range           = 24,
		damage          = 85,
		aoe_radius      = 2.5,
		aoe_damage_frac = 0.4,
	},

	// Quake's lightning gun, on a mana budget. Nothing up front and no
	// wind-up; it draws mana every tick it is held and hurts whatever the
	// crosshair is on, then arcs to the two nearest enemies behind them for
	// half as much. A full pool buys about four seconds, roughly two kills
	// with perfect tracking, which is less than the same mana in lances. The
	// beam is paid for in aim, not in cast time.
	.Thunderbolt = {
		id                = .Thunderbolt,
		name              = "Thunderbolt",
		short_name        = "THUNDER",
		mana_cost         = 10,    // needed to light it, not spent
		cooldown_sec      = 2.0,   // only after it runs the caster dry
		payload           = .Beam,
		target_filter     = .Enemy,
		range             = 20.8,
		beam_dps          = 55,
		beam_mana_per_sec = 24,
		beam_chain_range  = 6,
		beam_chain_count  = 2,
		beam_chain_frac   = 0.5,
	},

	// Tap. No wind-up, because it is cast on the move: the rune lands `range`
	// ahead, where the next stride or the next hop's landing will meet it.
	// Darkfall's Begone, by another name.
	.Gust = {
		id            = .Gust,
		name          = "Gust",
		short_name    = "GUST",
		mana_cost     = 30,
		cooldown_sec  = 2.0,
		payload       = .Pad,
		target_filter = .Any,
		range         = 1.5,
	},

	// Tap. The stamina is gone immediately; the mana arrives over the cooldown.
	.Stamina_To_Mana = {
		id            = .Stamina_To_Mana,
		name          = "Stamina to Mana",
		short_name    = "STA>MP",
		cooldown_sec  = TRANSFER_COOLDOWN_SEC,
		payload       = .Transfer,
		transfer_from = .Stamina,
		transfer_to   = .Mana,
		transfer_cost = TRANSFER_COST,
		transfer_gain = TRANSFER_GAIN,
	},

	// Tap. Refused if the cost would leave the caster on 0 health.
	.Health_To_Stamina = {
		id            = .Health_To_Stamina,
		name          = "Health to Stamina",
		short_name    = "HP>STA",
		cooldown_sec  = TRANSFER_COOLDOWN_SEC,
		payload       = .Transfer,
		transfer_from = .Health,
		transfer_to   = .Stamina,
		transfer_cost = TRANSFER_COST,
		transfer_gain = TRANSFER_GAIN,
	},
}

// Widest the crosshair may drift off a soft target between picking it and the
// release before the server calls it a different heal. Generous on purpose:
// the latch exists so that aim wobble during a wind-up is forgiven. Call
// Lightning does not use this; that bolt is a hitscan of the release ray.
SOFT_AIM_COS :: f32(0.766) // cos 40 deg

// Where a bolt or a mend is aimed: the target's centre. Splash starts here too.
strike_center :: proc(target_pos: vec3) -> vec3 {
	return target_pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
}

// Geometry of a soft target, shared by the server's heal check and the
// client's cast decision. Who the target is (alive, friendly, hurt) is
// checked by each side on its own view of the world.
//
// In range: close enough and roughly where the caster is looking. Cover does
// not stop a heal being started.
soft_target_in_range :: proc(def: ^Spell_Def, eye, look, target_pos: vec3) -> bool {
	to := strike_center(target_pos) - eye
	dist := len_vec3(to)
	if dist > def.range || dist < 1e-3 {
		return false
	}
	return dot_vec3(to, look) >= SOFT_AIM_COS * dist
}

// In reach: in range and in the open. This is what a heal landing on an ally demands.
soft_target_in_reach :: proc(def: ^Spell_Def, eye, look, target_pos: vec3) -> bool {
	return soft_target_in_range(def, eye, look, target_pos) &&
	       world_segment_clear(eye, strike_center(target_pos))
}

// Floor of a legal heal. Charge-cast spells fire at full power, so this is
// the amount a full wind-up is worth when `def.heal` is read through charge.
HEAL_MIN_HP :: f32(20)

spell_heal_amount :: proc(def: ^Spell_Def, charge: f32) -> f32 {
	return lerpf(HEAL_MIN_HP, def.heal, charge)
}

// Put `amount` of health back, stopping at the cap. Returns how much actually
// landed, so a mend on a full bar is a no-op the caller can see.
character_mend :: proc(char: ^Character_State, amount: f32) -> f32 {
	before := char.health
	char.health = min(char.health + amount, HEALTH_MAX)
	return char.health - before
}

// HUD only: the charge bar stays dim until the wind-up has got this far.
SPELL_MIN_CHARGE :: f32(0.2)

// Does the target match the selected spell's targeting filter?
// Examples:
//   - Enemy filter: Alpha targeting Beta → true, Alpha targeting Alpha → false
//   - Friendly filter: Alpha targeting Alpha (not self) → true, Alpha targeting Beta → false
//   - Friendly filter: None targeting None → false (teamless entities can't be "friendly")
spell_target_valid_for_filter :: proc(filter: Spell_Target_Filter, caster_id, target_id: Entity_ID, caster_team, target_team: Team_ID) -> bool {
	if target_id == INVALID_ENTITY || caster_id == target_id {
		return false
	}
	switch filter {
	case .Any:
		return true
	case .Enemy:
		return teams_are_enemies(caster_team, target_team)
	case .Friendly:
		// Require same non-None team, excluding self
		if caster_team == .None || target_team == .None {
			return false
		}
		return caster_team == target_team && caster_id != target_id
	}
	return false
}

spell_valid :: proc(id: Spell_ID) -> bool {
	return id != .None && int(id) < len(SPELL_DEFS) && SPELL_DEFS[id].payload != .None
}

// Everything that has to be true before a wind-up may start or a release may
// fire. The server, the client's cast decision and the HUD all read this, so
// the bar never offers a cast the server would throw away. Death and the match
// state are the callers' business: they drop a charge rather than gate one.
// A transfer also needs its source pool and a destination that is not already
// full. Heal keeps the mana check only: a full health bar can still mend an ally.
spell_castable :: proc(id: Spell_ID, char: Character_State, cooldown: f32) -> bool {
	if !spell_valid(id) || cooldown > 0 {
		return false
	}
	def := &SPELL_DEFS[id]
	if def.payload == .Transfer {
		return vital_can_spend(char, def.transfer_from, def.transfer_cost) &&
		       !vital_full(char, def.transfer_to)
	}
	return char.mana >= def.mana_cost
}

// Health never spends down to 0. The other bars just have to cover the cost.
vital_can_spend :: proc(char: Character_State, pool: Vital, amount: f32) -> bool {
	switch pool {
	case .Health:
		return char.health > amount
	case .Mana:
		return char.mana >= amount
	case .Stamina:
		return char.stamina >= amount
	case .None:
		return amount <= 0
	}
	return false
}

vital_full :: proc(char: Character_State, pool: Vital) -> bool {
	switch pool {
	case .Health:
		return char.health >= HEALTH_MAX
	case .Mana:
		return char.mana >= MANA_MAX
	case .Stamina:
		return char.stamina >= STAMINA_MAX
	case .None:
		return true
	}
	return true
}

vital_label :: proc(pool: Vital) -> string {
	switch pool {
	case .Health:
		return "hp"
	case .Mana:
		return "mp"
	case .Stamina:
		return "sta"
	case .None:
		return ""
	}
	return ""
}

// Pay a cast that spell_castable has already allowed.
spell_pay :: proc(char: ^Character_State, def: ^Spell_Def) {
	if def.payload == .Transfer {
		vital_spend(char, def.transfer_from, def.transfer_cost)
		return
	}
	char.mana -= def.mana_cost
}

vital_spend :: proc(char: ^Character_State, pool: Vital, amount: f32) {
	switch pool {
	case .Health:
		char.health -= amount
	case .Mana:
		char.mana -= amount
	case .Stamina:
		char.stamina -= amount
	case .None:
	}
}

vital_gain :: proc(char: ^Character_State, pool: Vital, amount: f32) {
	switch pool {
	case .Health:
		char.health = min(char.health + amount, HEALTH_MAX)
	case .Mana:
		char.mana = min(char.mana + amount, MANA_MAX)
	case .Stamina:
		char.stamina = min(char.stamina + amount, STAMINA_MAX)
	case .None:
	}
}

// How much of a spell a given hold is worth. Spells with no cast time are
// always full power. Charge-cast spells only fire at 1; this is the HUD bar.
spell_charge_frac :: proc(def: ^Spell_Def, held_sec: f32) -> f32 {
	if def.cast_time <= 0 {
		return 1
	}
	return clampf(held_sec / def.cast_time, 0, 1)
}

Entity_Spell_State :: struct {
	cooldowns: [Spell_ID]f32,

	// Server-owned wind-up. The client reports which spell it is winding, the
	// server decides how long it has actually been held. Once the button has
	// come up, `channel_committed` keeps that wind-up going until a full-power
	// fire — an early release is a commit, not a half-charged shot.
	// `release_aim` is the look on that commit. A hitscan fires along it even
	// when the bar fills a few ticks later and the caster has since looked away.
	channel_spell:     Spell_ID,
	channel_time:      f32,
	channel_committed: bool,
	release_aim:       bool,
	release_yaw:       f32,
	release_pitch:     f32,

	// Where the held beam ended this tick, for the snapshot. Only meaningful
	// while channel_spell is a beam.
	beam: Beam_State,
}

BEAM_MAX_CHAINS :: 2

Beam_State :: struct {
	end:         vec3,                    // first thing the beam met: a body or the world
	hit:         Entity_ID,               // the player, if the primary landed on one
	hit_minion:  bool,                    // primary landed on a minion; snapshot.hit is true either way
	chain_count: int,
	chains:      [BEAM_MAX_CHAINS]Entity_ID,
	// Minion IDs for chain targets. 0 means chains[i] is a player,
	// > 0 means a minion with that ID.
	chain_minion_ids: [BEAM_MAX_CHAINS]Minion_ID,
}

// Is the entity's held spell a beam that is actually firing?
spell_state_beaming :: proc(state: ^Entity_Spell_State) -> bool {
	return state.channel_spell != .None && SPELL_DEFS[state.channel_spell].payload == .Beam
}

Spell_Cast :: struct {
	caster_id:   Entity_ID,
	spell_id:    Spell_ID,
	origin:      vec3,
	direction:   vec3,
	tick:        u32,
	charge_frac: f32,
}
