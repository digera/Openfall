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
	Frost_Lance    = 4,    // slow piercing lance, heavy damage + slow
	Thunderbolt    = 5,    // hold-to-channel lightning beam with chaining
}

// Spells bound to hotbar slots 1..4
HOTBAR := [4]Spell_ID{.Arcane_Missile, .Arcane_Orb, .Thunderbolt, .Frost_Lance}

Spell_Def :: struct {
	id:            Spell_ID,
	name:          string,
	short_name:    string,
	mana_cost:     f32,
	cooldown_sec:  f32,

	payload:       Spell_Payload_Type,

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

	range:         f32,   // blink distance, beam range

	// Beam channel parameters
	beam_dps:         f32,  // damage per second for continuous beam
	beam_mana_per_sec: f32, // mana drain rate while channeling
	beam_chain_range:  f32, // chain lightning jump distance
	beam_chain_count:  int, // max number of chain jumps
}

Spell_Payload_Type :: enum u8 {
	None = 0,
	Projectile,
	Teleport,
	Beam_Channel,
}

SPELL_DEFS := [Spell_ID]Spell_Def{
	.None = {},

	// Ricochets down lanes and around cover; the pop is what does the work.
	.Arcane_Missile = {
		id               = .Arcane_Missile,
		name             = "Arcane Missile",
		short_name       = "MISSILE",
		mana_cost        = 12,
		cooldown_sec     = 0.8,
		payload          = .Projectile,
		proj_speed       = 30,
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
		cooldown_sec    = 5.0,
		payload         = .Projectile,
		proj_speed      = 12,
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
		cooldown_sec  = 6.0,
		payload       = .Teleport,
		range         = 11,
	},

	// Drifts in slowly and spears everyone lined up behind the first target.
	.Frost_Lance = {
		id            = .Frost_Lance,
		name          = "Frost Lance",
		short_name    = "LANCE",
		mana_cost     = 32,
		cooldown_sec  = 3.4,
		payload       = .Projectile,
		proj_speed    = 15,
		proj_lifetime = 5.0,
		proj_radius   = 0.28,
		proj_gravity  = 0.1,
		proj_pierce   = 4,
		damage        = 68,
		slow_ticks    = 180, // 3 s
	},

	// Quake-style continuous lightning beam with chaining.
	.Thunderbolt = {
		id                = .Thunderbolt,
		name              = "Thunderbolt",
		short_name        = "THUNDER",
		mana_cost         = 0,      // no upfront cost, drains while held
		cooldown_sec      = 0,      // no cooldown between uses
		payload           = .Beam_Channel,
		range             = 28,     // beam max range
		beam_dps          = 95,     // damage per second
		beam_mana_per_sec = 22,     // mana drain rate
		beam_chain_range  = 8,      // chain lightning jump distance
		beam_chain_count  = 3,      // max chain jumps
	},
}

spell_valid :: proc(id: Spell_ID) -> bool {
	return id != .None && int(id) < len(SPELL_DEFS) && SPELL_DEFS[id].payload != .None
}

Entity_Spell_State :: struct {
	cooldowns: [Spell_ID]f32,

	// Beam channel state
	channeling:         bool,
	channel_spell:      Spell_ID,
	channel_tick_accum: f32,  // accumulates to trigger beam tick damage
}

Spell_Cast :: struct {
	caster_id: Entity_ID,
	spell_id:  Spell_ID,
	origin:    vec3,
	direction: vec3,
	tick:      u32,
}
