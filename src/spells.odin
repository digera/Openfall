package main

// Spell system

HEALTH_MAX  :: f32(100)
MANA_MAX    :: f32(100)
STAMINA_MAX :: f32(100)
STAMINA_REGEN_PER_SEC :: f32(20)
MANA_REGEN_PER_SEC    :: f32(12)

Spell_ID :: enum u8 {
	None = 0,

	Arcane_Missile = 1,    // fast projectile
	Arcane_Orb     = 2,    // slow heavy AoE with knockback
	Blink          = 3,    // short directional teleport
	Frost_Shard    = 4,    // projectile + slow
}

// Spells bound to hotbar slots 1..4
HOTBAR := [4]Spell_ID{.Arcane_Missile, .Arcane_Orb, .Blink, .Frost_Shard}

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
	proj_gravity:  bool,

	damage:        f32,
	aoe_radius:    f32,
	knockback:     f32,
	slow_ticks:    int,

	range:         f32,   // blink distance
}

Spell_Payload_Type :: enum u8 {
	None = 0,
	Projectile,
	Teleport,
}

SPELL_DEFS := [Spell_ID]Spell_Def{
	.None = {},

	.Arcane_Missile = {
		id            = .Arcane_Missile,
		name          = "Arcane Missile",
		short_name    = "MISSILE",
		mana_cost     = 10,
		cooldown_sec  = 0.55,
		payload       = .Projectile,
		proj_speed    = 48,
		proj_lifetime = 2.5,
		proj_radius   = 0.16,
		damage        = 18,
	},

	.Arcane_Orb = {
		id            = .Arcane_Orb,
		name          = "Arcane Orb",
		short_name    = "ORB",
		mana_cost     = 35,
		cooldown_sec  = 4.0,
		payload       = .Projectile,
		proj_speed    = 16,
		proj_lifetime = 5.0,
		proj_radius   = 0.45,
		damage        = 55,
		aoe_radius    = 3.5,
		knockback     = 9.0,
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

	.Frost_Shard = {
		id            = .Frost_Shard,
		name          = "Frost Shard",
		short_name    = "FROST",
		mana_cost     = 18,
		cooldown_sec  = 1.8,
		payload       = .Projectile,
		proj_speed    = 32,
		proj_lifetime = 3.5,
		proj_radius   = 0.22,
		damage        = 26,
		slow_ticks    = 150, // 2.5 s
	},
}

spell_valid :: proc(id: Spell_ID) -> bool {
	return id != .None && int(id) < len(SPELL_DEFS) && SPELL_DEFS[id].payload != .None
}

Entity_Spell_State :: struct {
	cooldowns: [Spell_ID]f32,
}

Spell_Cast :: struct {
	caster_id: Entity_ID,
	spell_id:  Spell_ID,
	origin:    vec3,
	direction: vec3,
	tick:      u32,
}
