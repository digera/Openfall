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
	Self_Heal      = 5,    // wind-up self heal, nothing leaves the caster
	Call_Lightning = 6,    // bolt from the sky onto the crosshair's target
}

// Spells bound to hotbar slots 1..HOTBAR_SLOTS. Blink keeps its definition but
// loses the third slot: sustain buys more there than a second way to move does.
HOTBAR_SLOTS :: 5
HOTBAR := [HOTBAR_SLOTS]Spell_ID{.Arcane_Missile, .Arcane_Orb, .Self_Heal, .Frost_Lance, .Call_Lightning}

Spell_Def :: struct {
	id:            Spell_ID,
	name:          string,
	short_name:    string,
	mana_cost:     f32,
	cooldown_sec:  f32,
	cast_time:     f32,   // seconds of hold for a full-power cast

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

	heal:          f32,   // health restored to the caster at full charge
	range:         f32,   // blink distance, or how far a strike can reach its target
}

Spell_Payload_Type :: enum u8 {
	None = 0,
	Projectile,
	Teleport,
	Heal,
	Strike,     // lands on the targeted entity the moment it is released
}

SPELL_DEFS := [Spell_ID]Spell_Def{
	.None = {},

	// Ricochets down lanes and around cover; the pop is what does the work.
	.Arcane_Missile = {
		id               = .Arcane_Missile,
		name             = "Arcane Missile",
		short_name       = "MISSILE",
		mana_cost        = 12,
		cooldown_sec     = 1.2,
		cast_time        = 0.6,
		payload          = .Projectile,
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
		proj_speed      = 10,
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
		range         = 11,
	},

	// Drifts in slowly and spears everyone lined up behind the first target.
	.Frost_Lance = {
		id            = .Frost_Lance,
		name          = "Frost Lance",
		short_name    = "LANCE",
		mana_cost     = 32,
		cooldown_sec  = 4.5,
		cast_time     = 0.9,
		payload       = .Projectile,
		proj_speed    = 13,
		proj_lifetime = 5.0,
		proj_radius   = 0.28,
		proj_gravity  = 0.1,
		proj_pierce   = 4,
		damage        = 68,
		slow_ticks    = 180, // 3 s
	},

	// Sustain, not an escape: the wind-up is long enough to be punished and a
	// full heal is worth less than one lance, so trading into a healing
	// opponent still wins.
	.Self_Heal = {
		id            = .Self_Heal,
		name          = "Self Heal",
		short_name    = "HEAL",
		mana_cost     = 30,
		cooldown_sec  = 5.0,
		cast_time     = 1.0,
		payload       = .Heal,
		heal          = 45,
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
		range           = 24,
		damage          = 85,
		aoe_radius      = 2.5,
		aoe_damage_frac = 0.4,
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

// In reach: in range and in the open. This is what the release demands.
strike_target_in_reach :: proc(def: ^Spell_Def, eye, look, target_pos: vec3) -> bool {
	return strike_target_in_range(def, eye, look, target_pos) &&
	       world_segment_clear(eye, strike_center(target_pos))
}

// Releasing below this fraction of the cast time fizzles instead of casting,
// so tapping the button can never stand in for a real wind-up.
SPELL_MIN_CHARGE :: f32(0.2)

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
	// A heal at full health is pure loss: refuse it instead of eating the mana.
	if def.payload == .Heal && char.health >= HEALTH_MAX {
		return false
	}
	return true
}

// How much of a spell a given hold is worth. Spells with no cast time are
// always full power.
spell_charge_frac :: proc(def: ^Spell_Def, held_sec: f32) -> f32 {
	if def.cast_time <= 0 {
		return 1
	}
	return clampf(held_sec / def.cast_time, 0, 1)
}

Entity_Spell_State :: struct {
	cooldowns: [Spell_ID]f32,

	// Server-owned wind-up. The client reports which spell it is holding, the
	// server decides how long it has actually been held.
	channel_spell: Spell_ID,
	channel_time:  f32,
}

Spell_Cast :: struct {
	caster_id:   Entity_ID,
	spell_id:    Spell_ID,
	origin:      vec3,
	direction:   vec3,
	tick:        u32,
	charge_frac: f32,
}
