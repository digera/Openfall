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
	Call_Lightning = 5,    // targeted lightning strike from above
}

// Spells bound to hotbar slots 1..5
HOTBAR := [5]Spell_ID{.Arcane_Missile, .Arcane_Orb, .Blink, .Frost_Lance, .Call_Lightning}

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

	range:           f32,   // blink distance / lightning max range
	cast_time:       f32,   // channel duration before spell fires (0 = instant)
}

Spell_Payload_Type :: enum u8 {
	None = 0,
	Projectile,
	Teleport,
	Lightning,    // targeted strike from above
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

	// Lightning strike from the sky: requires target, long cast, heavy hit.
	// If target dies/out of range during cast, spell fails and refunds mana/cooldown.
	.Call_Lightning = {
		id           = .Call_Lightning,
		name         = "Call Lightning",
		short_name   = "LIGHTNING",
		mana_cost    = 60,
		cooldown_sec = 8.0,
		payload      = .Lightning,
		cast_time    = 1.8,    // long channel before strike
		range        = 22,     // max target distance
		damage       = 85,     // hard single-target hit
		aoe_radius   = 2.5,    // small splash around impact
		aoe_damage_frac = 0.4, // moderate splash damage
	},
}

spell_valid :: proc(id: Spell_ID) -> bool {
	return id != .None && int(id) < len(SPELL_DEFS) && SPELL_DEFS[id].payload != .None
}

Entity_Spell_State :: struct {
	cooldowns:       [Spell_ID]f32,
	casting:         bool,
	cast_spell:      Spell_ID,
	cast_progress:   f32,      // time elapsed in cast
	cast_target_id:  Entity_ID, // for targeted spells like Call Lightning
}

Spell_Cast :: struct {
	caster_id:  Entity_ID,
	spell_id:   Spell_ID,
	origin:     vec3,
	direction:  vec3,
	tick:       u32,
	target_id:  Entity_ID, // for targeted spells (Lightning)
}

// Lightning strikes for VFX (client-side rendering)
MAX_LIGHTNING_STRIKES :: 8

Lightning_Strike :: struct {
	active:    bool,
	pos:       vec3,      // impact position
	age:       f32,       // 0..1, grows as strike fades
	height:    f32,       // bolt extends from pos.z to pos.z + height
}

Lightning_Strikes :: struct {
	strikes: [MAX_LIGHTNING_STRIKES]Lightning_Strike,
}

lightning_strikes_spawn :: proc(strikes: ^Lightning_Strikes, pos: vec3, height: f32) {
	for i in 0..<MAX_LIGHTNING_STRIKES {
		if !strikes.strikes[i].active {
			strikes.strikes[i] = Lightning_Strike{
				active = true,
				pos    = pos,
				age    = 0,
				height = height,
			}
			return
		}
	}
	// Replace oldest
	strikes.strikes[0] = Lightning_Strike{
		active = true,
		pos    = pos,
		age    = 0,
		height = height,
	}
}

lightning_strikes_update :: proc(strikes: ^Lightning_Strikes, dt: f32) {
	for i in 0..<MAX_LIGHTNING_STRIKES {
		if strikes.strikes[i].active {
			strikes.strikes[i].age += dt * 4.0 // quick fade
			if strikes.strikes[i].age >= 1.0 {
				strikes.strikes[i].active = false
			}
		}
	}
}
