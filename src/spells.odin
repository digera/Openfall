package main

// Spell system

HEALTH_MAX  :: f32(100)
MANA_MAX    :: f32(100)
STAMINA_MAX :: f32(100)
STAMINA_REGEN_PER_SEC :: f32(20)
MANA_REGEN_PER_SEC    :: f32(12)

Spell_ID :: enum u8 {
	None = 0,

	Arcane_Missile = 1,    // bouncing bolt, pops after its ricochets run out
	Arcane_Orb     = 2,    // heavy lob, large splash on first contact
	Blink          = 3,    // short directional teleport
	Frost_Lance    = 4,    // straight piercing lance, heavy damage + slow
	Friendly_Heal  = 5,    // wind-up mend: caster and a targeted ally
	Call_Lightning = 6,    // bolt from the sky onto the crosshair's target
	Thunderbolt    = 7,    // held beam that arcs between nearby enemies
}

// Spells bound to hotbar slots 1..HOTBAR_SLOTS. Blink keeps its definition but
// loses the third slot: sustain buys more there than a second way to move does.
HOTBAR_SLOTS :: 6
HOTBAR := [HOTBAR_SLOTS]Spell_ID{.Arcane_Missile, .Arcane_Orb, .Friendly_Heal, .Frost_Lance, .Call_Lightning, .Thunderbolt}

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
	target_filter: Spell_Target_Filter, // what may be sticky-targeted while this spell is selected

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

	heal:          f32,   // health restored to each recipient at full charge
	range:         f32,   // blink distance, strike reach, heal reach, or beam length

	// Beams. `mana_cost` is what it takes to light one, not what it spends;
	// `cooldown_sec` is the rest forced on a beam that ran its caster dry.
	beam_dps:          f32,   // damage per second
	beam_mana_per_sec: f32,
	beam_chain_range:  f32,   // how far an arc jumps from the last body it hit
	beam_chain_count:  int,   // how many times
	beam_chain_frac:   f32,   // damage each jump deals, as a fraction of the beam's
}

Spell_Payload_Type :: enum u8 {
	None = 0,
	Projectile,
	Teleport,
	Strike,     // lands on the targeted entity when the wind-up completes
	Heal,       // restores health to the caster and a targeted ally
	Beam,       // does its work every tick it is held; the release is nothing
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

	// Lobbed: detonates on the first thing it touches, wide splash.
	.Arcane_Orb = {
		id              = .Arcane_Orb,
		name            = "Arcane Orb",
		short_name      = "ORB",
		mana_cost       = 40,
		cooldown_sec    = 7.0,
		cast_time       = 1.2,
		payload         = .Projectile,
		target_filter   = .Enemy,
		proj_speed      = 13,
		proj_lifetime   = 4.0,
		proj_radius     = 0.45,
		proj_gravity    = 0.6,
		damage          = 55,
		aoe_radius      = 6.5,
		aoe_damage_frac = 0.75,
		knockback       = 12.0,
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

	// Sustain, not an escape: a 1s wind-up on a long rest, and 50 health is
	// still less than one lance, so trading into a healing opponent wins.
	// The caster is always mended; a teammate under the crosshair is too,
	// if they are in reach when it fires. A heal with nobody missing health
	// is refused rather than eating the mana, so it cannot be pre-charged
	// before a fight.
	.Friendly_Heal = {
		id            = .Friendly_Heal,
		name          = "Friendly Heal",
		short_name    = "HEAL",
		mana_cost     = 40,
		cooldown_sec  = 14.0,
		cast_time     = 1.0,
		payload       = .Heal,
		target_filter = .Friendly,
		range         = 18,
		heal          = 50,
	},

	// The only spell that cannot be dodged, so everything else about it is
	// slow: the longest wind-up on the bar, the biggest mana bill, and it
	// needs the target in the open when it lands. The wind-up is the
	// counterplay -- step behind a pillar before the bolt comes down and the
	// caster has spent 1.8 s for nothing.
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
}

// Widest the crosshair may drift off a target between picking it and the
// release before the server calls it a different shot. Generous on purpose:
// the soft target exists so that aim wobble during a wind-up is forgiven.
STRIKE_AIM_COS :: f32(0.766) // cos 40 deg

// Where a strike lands (and where its splash starts): the target's centre.
strike_center :: proc(target_pos: vec3) -> vec3 {
	return target_pos + vec3{0, 0, CHARACTER_HEIGHT_M * 0.5}
}

// Geometry of a strike, shared by the server's validation and the client's
// cast decision so the bar never offers a bolt the server would refuse. Who
// the target is (alive, hostile) is checked by each side on its own view of
// the world.
//
// In range: close enough and roughly where the caster is looking. This is
// all a wind-up needs to start; cover does not stop a bolt being *called*.
strike_target_in_range :: proc(def: ^Spell_Def, eye, look, target_pos: vec3) -> bool {
	to := strike_center(target_pos) - eye
	dist := len_vec3(to)
	if dist > def.range || dist < 1e-3 {
		return false
	}
	return dot_vec3(to, look) >= STRIKE_AIM_COS * dist
}

// In reach: in range and in the open. This is what firing demands.
strike_target_in_reach :: proc(def: ^Spell_Def, eye, look, target_pos: vec3) -> bool {
	return strike_target_in_range(def, eye, look, target_pos) &&
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
spell_castable :: proc(id: Spell_ID, char: Character_State, cooldown: f32) -> bool {
	if !spell_valid(id) {
		return false
	}
	def := &SPELL_DEFS[id]
	if cooldown > 0 || char.mana < def.mana_cost {
		return false
	}
	return true
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
	channel_spell:     Spell_ID,
	channel_time:      f32,
	channel_committed: bool,

	// Where the held beam ended this tick, for the snapshot. Only meaningful
	// while channel_spell is a beam.
	beam: Beam_State,
}

BEAM_MAX_CHAINS :: 2

Beam_State :: struct {
	end:         vec3,                    // first thing the beam met: a body or the world
	hit:         Entity_ID,               // the body, if it was one
	chain_count: int,
	chains:      [BEAM_MAX_CHAINS]Entity_ID,
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
