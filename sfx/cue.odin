package sfx

import ma "vendor:miniaudio"

// One-shot cues. Each value is a Wirebang Live-export script in this package.
// init() runs the scripts once and caches PCM; play_cue() plays the cache.

Cue :: enum u8 {
	Missile_Charge,
	Missile_Cast,
	Missile_Impact,
	Orb_Charge,
	Orb_Cast,
	Orb_Impact,
	Lance_Charge,
	Lance_Cast,
	Lance_Impact,
	Blink_Charge,
	Blink_Arrive,
	Transfer_Mana,
	Transfer_Stamina,
	Transfer_Heal,
	Lightning_Charge,
	Lightning_Cast,
	Lightning_Strike,
	Thunder_Loop,
	Thunder_Hit,
	Hit_Confirm,
	Hurt,
	Death,
	Kill,
	Respawn,
	Fizzle,
	Land,
	Jump,
}

@(private)
play_script :: proc(engine: ^ma.engine, cue: Cue) {
	switch cue {
	case .Missile_Charge:    play_missile_charge(engine)
	case .Missile_Cast:      play_missile_cast(engine)
	case .Missile_Impact:    play_missile_impact(engine)
	case .Orb_Charge:        play_orb_charge(engine)
	case .Orb_Cast:          play_orb_cast(engine)
	case .Orb_Impact:        play_orb_impact(engine)
	case .Lance_Charge:      play_lance_charge(engine)
	case .Lance_Cast:        play_lance_cast(engine)
	case .Lance_Impact:      play_lance_impact(engine)
	case .Blink_Charge:      play_blink_charge(engine)
	case .Blink_Arrive:      play_blink_arrive(engine)
	case .Transfer_Mana:     play_transfer_mana(engine)
	case .Transfer_Stamina:  play_transfer_stamina(engine)
	case .Transfer_Heal:     play_transfer_heal(engine)
	case .Lightning_Charge:  play_lightning_charge(engine)
	case .Lightning_Cast:    play_lightning_cast(engine)
	case .Lightning_Strike:  play_lightning_strike(engine)
	case .Thunder_Loop:      play_thunder_loop(engine)
	case .Thunder_Hit:       play_thunder_hit(engine)
	case .Hit_Confirm:       play_hit_confirm(engine)
	case .Hurt:              play_hurt(engine)
	case .Death:             play_death(engine)
	case .Kill:              play_kill(engine)
	case .Respawn:           play_respawn(engine)
	case .Fizzle:            play_fizzle(engine)
	case .Land:              play_land(engine)
	case .Jump:              play_jump(engine)
	}
}
