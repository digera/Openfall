package main

import "core:fmt"
import wb "wb:wirebang"

Library_Entry :: struct {
	id:   string,
	make: proc() -> wb.Patch,
}

LIBRARY := [?]Library_Entry {
	{"missile_charge", make_missile_charge},
	{"missile_cast", make_missile_cast},
	{"missile_impact", make_missile_impact},
	{"orb_charge", make_orb_charge},
	{"orb_cast", make_orb_cast},
	{"orb_impact", make_orb_impact},
	{"lance_charge", make_lance_charge},
	{"lance_cast", make_lance_cast},
	{"lance_impact", make_lance_impact},
	{"blink_charge", make_blink_charge},
	{"blink_arrive", make_blink_arrive},
	{"heal_loop", make_heal_loop},
	{"heal_tick", make_heal_tick},
	{"lightning_charge", make_lightning_charge},
	{"lightning_cast", make_lightning_cast},
	{"lightning_strike", make_lightning_strike},
	{"thunder_loop", make_thunder_loop},
	{"thunder_hit", make_thunder_hit},
	{"hit_confirm", make_hit_confirm},
	{"hurt", make_hurt},
	{"death", make_death},
	{"kill", make_kill},
	{"respawn", make_respawn},
	{"fizzle", make_fizzle},
	{"land", make_land},
	{"jump", make_jump},
}

@(private)
out_node :: proc() -> wb.Graph_Node {
	return {id = "out", kind = .Out, x = 860, y = 200, name = "out"}
}

@(private)
osc :: proc(id: string, y: f32, name: string, type: wb.Osc_Type, freq, freq_end, dur: f32, delay := f32(0), jitter := f32(0.06), ramp := wb.Ramp_Curve.Exp) -> wb.Graph_Node {
	return {
		id = id,
		kind = .Osc,
		x = 40,
		y = y,
		name = name,
		params = wb.Osc_Params{type = type, freq = freq, freq_end = freq_end, ramp = ramp, duration = dur, delay = delay, jitter = jitter},
	}
}

@(private)
noise :: proc(id: string, y: f32, name: string, dur: f32, delay := f32(0)) -> wb.Graph_Node {
	return {id = id, kind = .Noise, x = 40, y = y, name = name, params = wb.Noise_Params{duration = dur, delay = delay}}
}

@(private)
filter :: proc(id: string, y: f32, name: string, type: wb.Filter_Type, freq, freq_end, q, ramp: f32, jitter := f32(0.08)) -> wb.Graph_Node {
	return {
		id = id,
		kind = .Filter,
		x = 240,
		y = y,
		name = name,
		params = wb.Filter_Params{type = type, freq = freq, freq_end = freq_end, q = q, ramp_time = ramp, jitter = jitter},
	}
}

@(private)
gain :: proc(id: string, y: f32, name: string, peak, dur: f32, delay := f32(0), jitter := f32(0.06)) -> wb.Graph_Node {
	return {id = id, kind = .Gain, x = 520, y = y, name = name, params = wb.Gain_Params{peak = peak, duration = dur, delay = delay, jitter = jitter}}
}

@(private)
shaper :: proc(id: string, y: f32, name: string, amount: f32) -> wb.Graph_Node {
	return {id = id, kind = .Shaper, x = 380, y = y, name = name, params = wb.Shaper_Params{amount = amount}}
}

@(private)
panner :: proc(id: string, y: f32, name: string, pan: f32) -> wb.Graph_Node {
	return {id = id, kind = .Panner, x = 680, y = y, name = name, params = wb.Panner_Params{pan = pan}}
}

@(private)
delay :: proc(id: string, y: f32, name: string, time, mix, fb: f32) -> wb.Graph_Node {
	return {id = id, kind = .Delay, x = 680, y = y, name = name, params = wb.Delay_Params{time = time, mix = mix, feedback = fb}}
}

@(private)
link :: proc(pairs: [][2]string) -> []wb.Graph_Edge {
	edges := make([]wb.Graph_Edge, len(pairs), context.temp_allocator)
	for p, i in pairs {
		edges[i] = {
			id   = fmt.tprintf("e_%d", i + 1),
			from = p[0],
			to   = p[1],
		}
	}
	return edges
}

@(private)
patch :: proc(name, fn: string, nodes: []wb.Graph_Node, edges: []wb.Graph_Edge) -> wb.Patch {
	return wb.patch_from_slices(name, fn, nodes, edges)
}

// Arcane Missile: Diablo-2 magic-missile sparkle. Rising grain while charging,
// a saw zip on release, a bright pop on bounce-out.

make_missile_charge :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 60, "shimmer", .Triangle, 420, 720, 0.13, 0, 0.05, .Lin),
		gain("gain_1", 60, "shimmerAmp", 0.10, 0.13, 0, 0.05),
		noise("noise_1", 240, "glint", 0.05, 0.02),
		filter("filter_1", 240, "glintBp", .Bandpass, 4200, 6400, 4.2, 0.04, 0.06),
		gain("gain_2", 240, "glintAmp", 0.05, 0.05, 0.02, 0.08),
	}
	return patch("Missile Charge", "play_missile_charge", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
	}))
}

make_missile_cast :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "zip", .Sawtooth, 1680, 260, 0.09, 0, 0.07, .Exp),
		gain("gain_1", 40, "zipAmp", 0.16, 0.09, 0, 0.05),
		noise("noise_1", 220, "air", 0.025, 0),
		filter("filter_1", 220, "airHp", .Highpass, 4500, 0, 0.7, 0, 0),
		gain("gain_2", 220, "airAmp", 0.07, 0.025, 0, 0.1),
		osc("osc_2", 400, "poke", .Sine, 240, 90, 0.04, 0, 0.08, .Exp),
		gain("gain_3", 400, "pokeAmp", 0.10, 0.04, 0, 0.08),
	}
	return patch("Missile Cast", "play_missile_cast", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "gain_3"}, {"gain_3", "out"},
	}))
}

make_missile_impact :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		noise("noise_1", 40, "spark", 0.03, 0),
		filter("filter_1", 40, "sparkBp", .Bandpass, 2800, 780, 1.8, 0.025, 0.1),
		shaper("shaper_1", 40, "crunch", 5),
		gain("gain_1", 40, "sparkAmp", 0.20, 0.03, 0, 0.08),
		osc("osc_1", 240, "ping", .Triangle, 1480, 420, 0.035, 0, 0.08, .Exp),
		gain("gain_2", 240, "pingAmp", 0.10, 0.035, 0, 0.08),
		osc("osc_2", 420, "body", .Sine, 190, 70, 0.055, 0, 0.07, .Exp),
		gain("gain_3", 420, "bodyAmp", 0.12, 0.055, 0, 0.06),
	}
	return patch("Missile Impact", "play_missile_impact", nodes[:], link([][2]string{
		{"noise_1", "filter_1"}, {"filter_1", "shaper_1"}, {"shaper_1", "gain_1"}, {"gain_1", "out"},
		{"osc_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "gain_3"}, {"gain_3", "out"},
	}))
}

// Arcane Orb: UT flak / Q3 rocket. Heavy rumble on the wind-up, a fat whoomp
// on the throw, a delayed boom on first contact.

make_orb_charge :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "rumble", .Sine, 52, 88, 0.18, 0, 0.04, .Lin),
		gain("gain_1", 40, "rumbleAmp", 0.16, 0.18, 0, 0.04),
		noise("noise_1", 230, "pressure", 0.18, 0),
		filter("filter_1", 230, "pressureLp", .Lowpass, 180, 260, 0.8, 0.14, 0.05),
		gain("gain_2", 230, "pressureAmp", 0.08, 0.18, 0, 0.06),
		osc("osc_2", 420, "grind", .Square, 48, 36, 0.10, 0.02, 0.08, .Exp),
		gain("gain_3", 420, "grindAmp", 0.04, 0.10, 0.02, 0.1),
	}
	return patch("Orb Charge", "play_orb_charge", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "gain_3"}, {"gain_3", "out"},
	}))
}

make_orb_cast :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "whoomp", .Sine, 88, 34, 0.16, 0, 0.05, .Exp),
		gain("gain_1", 40, "whoompAmp", 0.28, 0.16, 0, 0.04),
		noise("noise_1", 230, "push", 0.10, 0),
		filter("filter_1", 230, "pushBp", .Bandpass, 620, 180, 0.9, 0.08, 0.08),
		shaper("shaper_1", 230, "pushDrive", 4),
		gain("gain_2", 230, "pushAmp", 0.12, 0.10, 0, 0.07),
		delay("delay_1", 230, "slap", 0.07, 0.22, 0.18),
	}
	return patch("Orb Cast", "play_orb_cast", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "shaper_1"}, {"shaper_1", "gain_2"},
		{"gain_2", "delay_1"}, {"delay_1", "out"},
	}))
}

make_orb_impact :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		noise("noise_1", 40, "blast", 0.09, 0),
		filter("filter_1", 40, "blastBp", .Bandpass, 920, 140, 0.85, 0.07, 0.08),
		shaper("shaper_1", 40, "smash", 14),
		gain("gain_1", 40, "blastAmp", 0.26, 0.09, 0, 0.06),
		osc("osc_1", 230, "boom", .Sine, 68, 26, 0.30, 0, 0.05, .Exp),
		gain("gain_2", 230, "boomAmp", 0.34, 0.30, 0, 0.04),
		osc("osc_2", 420, "edge", .Square, 170, 48, 0.04, 0, 0.1, .Exp),
		gain("gain_3", 420, "edgeAmp", 0.07, 0.04, 0, 0.1),
		delay("delay_1", 230, "hall", 0.12, 0.32, 0.40),
	}
	return patch("Orb Impact", "play_orb_impact", nodes[:], link([][2]string{
		{"noise_1", "filter_1"}, {"filter_1", "shaper_1"}, {"shaper_1", "gain_1"},
		{"gain_1", "delay_1"}, {"delay_1", "out"},
		{"osc_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "gain_3"}, {"gain_3", "out"},
	}))
}

// Frost Lance: EQ ice-bolt / D2 glacial spike. Crystal scrape, shard throw,
// a three-tone shatter on the hit.

make_lance_charge :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "crystal", .Triangle, 1760, 2480, 0.12, 0, 0.04, .Lin),
		gain("gain_1", 40, "crystalAmp", 0.09, 0.12, 0, 0.05),
		noise("noise_1", 230, "scrape", 0.09, 0),
		filter("filter_1", 230, "scrapeHp", .Highpass, 6200, 0, 0.8, 0, 0),
		gain("gain_2", 230, "scrapeAmp", 0.06, 0.09, 0, 0.08),
		osc("osc_2", 420, "ping", .Sine, 3100, 3100, 0.04, 0.03, 0.06, .Exp),
		filter("filter_2", 420, "pingBp", .Bandpass, 3100, 3600, 8.0, 0.03, 0.05),
		gain("gain_3", 420, "pingAmp", 0.05, 0.04, 0.03, 0.08),
	}
	return patch("Lance Charge", "play_lance_charge", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "filter_2"}, {"filter_2", "gain_3"}, {"gain_3", "out"},
	}))
}

make_lance_cast :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "shard", .Sawtooth, 2360, 520, 0.11, 0, 0.06, .Exp),
		gain("gain_1", 40, "shardAmp", 0.17, 0.11, 0, 0.05),
		osc("osc_2", 230, "whistle", .Triangle, 3400, 1100, 0.08, 0, 0.07, .Exp),
		gain("gain_2", 230, "whistleAmp", 0.08, 0.08, 0, 0.07),
		noise("noise_1", 420, "iceAir", 0.03, 0),
		filter("filter_1", 420, "iceHp", .Highpass, 5200, 0, 0.7, 0, 0),
		gain("gain_3", 420, "iceAirAmp", 0.06, 0.03, 0, 0.1),
	}
	return patch("Lance Cast", "play_lance_cast", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"osc_2", "gain_2"}, {"gain_2", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_3"}, {"gain_3", "out"},
	}))
}

make_lance_impact :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 20, "shardA", .Triangle, 2200, 700, 0.05, 0, 0.08, .Exp),
		gain("gain_1", 20, "shardAAmp", 0.11, 0.05, 0, 0.08),
		osc("osc_2", 160, "shardB", .Triangle, 1540, 480, 0.06, 0.008, 0.08, .Exp),
		gain("gain_2", 160, "shardBAmp", 0.09, 0.06, 0.008, 0.08),
		osc("osc_3", 300, "shardC", .Triangle, 2860, 900, 0.04, 0.016, 0.1, .Exp),
		gain("gain_3", 300, "shardCAmp", 0.07, 0.04, 0.016, 0.1),
		noise("noise_1", 440, "shatter", 0.045, 0),
		filter("filter_1", 440, "shatterBp", .Bandpass, 4100, 1100, 2.4, 0.035, 0.08),
		gain("gain_4", 440, "shatterAmp", 0.12, 0.045, 0, 0.08),
		osc("osc_4", 560, "body", .Sine, 150, 55, 0.09, 0, 0.07, .Exp),
		gain("gain_5", 560, "bodyAmp", 0.14, 0.09, 0, 0.06),
	}
	return patch("Lance Impact", "play_lance_impact", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"osc_2", "gain_2"}, {"gain_2", "out"},
		{"osc_3", "gain_3"}, {"gain_3", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_4"}, {"gain_4", "out"},
		{"osc_4", "gain_5"}, {"gain_5", "out"},
	}))
}

// Blink: Q3 teleporter. A short spatial shimmer, then a delayed whoosh on arrival.

make_blink_charge :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 80, "fold", .Sine, 480, 760, 0.10, 0, 0.04, .Lin),
		gain("gain_1", 80, "foldAmp", 0.11, 0.10, 0, 0.05),
		noise("noise_1", 280, "veil", 0.08, 0),
		filter("filter_1", 280, "veilBp", .Bandpass, 1800, 4200, 2.8, 0.07, 0.06),
		gain("gain_2", 280, "veilAmp", 0.06, 0.08, 0, 0.08),
		panner("panner_1", 280, "shift", -0.28),
	}
	return patch("Blink Charge", "play_blink_charge", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "panner_1"}, {"panner_1", "out"},
	}))
}

make_blink_arrive :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		noise("noise_1", 40, "rush", 0.16, 0),
		filter("filter_1", 40, "rushBp", .Bandpass, 520, 2400, 2.0, 0.12, 0.05),
		gain("gain_1", 40, "rushAmp", 0.16, 0.16, 0, 0.05),
		panner("panner_1", 40, "toss", 0.30),
		osc("osc_1", 280, "drop", .Sine, 280, 70, 0.14, 0.02, 0.06, .Exp),
		gain("gain_2", 280, "dropAmp", 0.14, 0.14, 0.02, 0.06),
		delay("delay_1", 280, "space", 0.055, 0.34, 0.22),
	}
	return patch("Blink Arrive", "play_blink_arrive", nodes[:], link([][2]string{
		{"noise_1", "filter_1"}, {"filter_1", "gain_1"}, {"gain_1", "panner_1"}, {"panner_1", "out"},
		{"osc_1", "gain_2"}, {"gain_2", "delay_1"}, {"delay_1", "out"},
	}))
}

// Friendly Heal: EQ holy-light drone. Soft fifth, a chime when health actually lands.

make_heal_loop :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "root", .Sine, 523, 0, 0.20, 0, 0.02, .Exp),
		gain("gain_1", 40, "rootAmp", 0.09, 0.20, 0, 0.03),
		osc("osc_2", 220, "fifth", .Sine, 784, 0, 0.18, 0.03, 0.03, .Exp),
		gain("gain_2", 220, "fifthAmp", 0.07, 0.18, 0.03, 0.04),
		noise("noise_1", 400, "dust", 0.08, 0.04),
		filter("filter_1", 400, "dustBp", .Bandpass, 4800, 6200, 3.2, 0.06, 0.05),
		gain("gain_3", 400, "dustAmp", 0.035, 0.08, 0.04, 0.08),
	}
	return patch("Heal Loop", "play_heal_loop", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"osc_2", "gain_2"}, {"gain_2", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_3"}, {"gain_3", "out"},
	}))
}

make_heal_tick :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "pluck", .Triangle, 660, 990, 0.07, 0, 0.04, .Lin),
		gain("gain_1", 40, "pluckAmp", 0.16, 0.07, 0, 0.04),
		osc("osc_2", 220, "chime", .Sine, 1320, 1760, 0.12, 0.04, 0.03, .Lin),
		gain("gain_2", 220, "chimeAmp", 0.12, 0.12, 0.04, 0.04),
		noise("noise_1", 400, "sparkle", 0.035, 0.04),
		filter("filter_1", 400, "sparkleBp", .Bandpass, 5600, 7800, 3.6, 0.03, 0.05),
		gain("gain_3", 400, "sparkleAmp", 0.04, 0.035, 0.04, 0.08),
	}
	return patch("Heal Tick", "play_heal_tick", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"osc_2", "gain_2"}, {"gain_2", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_3"}, {"gain_3", "out"},
	}))
}

// Call Lightning: D2 / EQ sky-bolt. Long low telegraph, a rising call on
// release, then the delayed smash when the snapshot strike appears.

make_lightning_charge :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "omen", .Sine, 42, 64, 0.20, 0, 0.04, .Lin),
		gain("gain_1", 40, "omenAmp", 0.14, 0.20, 0, 0.04),
		noise("noise_1", 230, "roll", 0.20, 0),
		filter("filter_1", 230, "rollLp", .Lowpass, 160, 220, 0.7, 0.16, 0.05),
		gain("gain_2", 230, "rollAmp", 0.10, 0.20, 0, 0.05),
		osc("osc_2", 420, "hint", .Square, 86, 60, 0.07, 0.05, 0.1, .Exp),
		gain("gain_3", 420, "hintAmp", 0.035, 0.07, 0.05, 0.1),
	}
	return patch("Lightning Charge", "play_lightning_charge", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "gain_3"}, {"gain_3", "out"},
	}))
}

make_lightning_cast :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		noise("noise_1", 60, "call", 0.14, 0),
		filter("filter_1", 60, "callBp", .Bandpass, 320, 1700, 1.3, 0.12, 0.06),
		gain("gain_1", 60, "callAmp", 0.14, 0.14, 0, 0.05),
		osc("osc_1", 280, "rise", .Sine, 110, 210, 0.12, 0, 0.05, .Lin),
		gain("gain_2", 280, "riseAmp", 0.12, 0.12, 0, 0.05),
	}
	return patch("Lightning Cast", "play_lightning_cast", nodes[:], link([][2]string{
		{"noise_1", "filter_1"}, {"filter_1", "gain_1"}, {"gain_1", "out"},
		{"osc_1", "gain_2"}, {"gain_2", "out"},
	}))
}

make_lightning_strike :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		noise("noise_1", 20, "crack", 0.07, 0),
		filter("filter_1", 20, "crackBp", .Bandpass, 1900, 180, 0.7, 0.055, 0.08),
		shaper("shaper_1", 20, "smash", 16),
		gain("gain_1", 20, "crackAmp", 0.28, 0.07, 0, 0.06),
		noise("noise_2", 200, "sizzle", 0.04, 0.008),
		filter("filter_2", 200, "sizzleHp", .Highpass, 4200, 0, 0.7, 0, 0),
		gain("gain_2", 200, "sizzleAmp", 0.10, 0.04, 0.008, 0.1),
		osc("osc_1", 380, "thunder", .Sine, 82, 28, 0.38, 0, 0.05, .Exp),
		gain("gain_3", 380, "thunderAmp", 0.32, 0.38, 0, 0.04),
		osc("osc_2", 540, "edge", .Square, 210, 46, 0.035, 0, 0.12, .Exp),
		gain("gain_4", 540, "edgeAmp", 0.08, 0.035, 0, 0.12),
		delay("delay_1", 20, "tail", 0.18, 0.42, 0.52),
	}
	return patch("Lightning Strike", "play_lightning_strike", nodes[:], link([][2]string{
		{"noise_1", "filter_1"}, {"filter_1", "shaper_1"}, {"shaper_1", "gain_1"},
		{"gain_1", "delay_1"}, {"delay_1", "out"},
		{"noise_2", "filter_2"}, {"filter_2", "gain_2"}, {"gain_2", "out"},
		{"osc_1", "gain_3"}, {"gain_3", "out"},
		{"osc_2", "gain_4"}, {"gain_4", "out"},
	}))
}

// Thunderbolt: Quake 3 lightning gun. Harsh saw drone + crackle while held,
// a tighter zap when the beam is on a body.

make_thunder_loop :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "buzz", .Sawtooth, 92, 0, 0.09, 0, 0.04, .Exp),
		gain("gain_1", 40, "buzzAmp", 0.10, 0.09, 0, 0.04),
		noise("noise_1", 230, "arc", 0.07, 0),
		filter("filter_1", 230, "arcBp", .Bandpass, 2400, 1600, 1.6, 0.05, 0.1),
		shaper("shaper_1", 230, "bite", 3),
		gain("gain_2", 230, "arcAmp", 0.11, 0.07, 0, 0.08),
		osc("osc_2", 420, "hum", .Square, 46, 0, 0.09, 0, 0.05, .Exp),
		gain("gain_3", 420, "humAmp", 0.05, 0.09, 0, 0.06),
	}
	return patch("Thunder Loop", "play_thunder_loop", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "shaper_1"}, {"shaper_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "gain_3"}, {"gain_3", "out"},
	}))
}

make_thunder_hit :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		noise("noise_1", 40, "snap", 0.022, 0),
		filter("filter_1", 40, "snapBp", .Bandpass, 3100, 620, 1.4, 0.018, 0.12),
		shaper("shaper_1", 40, "crunch", 7),
		gain("gain_1", 40, "snapAmp", 0.18, 0.022, 0, 0.1),
		osc("osc_1", 240, "thump", .Sine, 190, 62, 0.04, 0, 0.08, .Exp),
		gain("gain_2", 240, "thumpAmp", 0.12, 0.04, 0, 0.08),
		noise("noise_2", 420, "crackle", 0.014, 0.004),
		filter("filter_2", 420, "airHp", .Highpass, 5000, 0, 0.7, 0, 0),
		gain("gain_3", 420, "crackleAmp", 0.07, 0.014, 0.004, 0.1),
	}
	return patch("Thunder Hit", "play_thunder_hit", nodes[:], link([][2]string{
		{"noise_1", "filter_1"}, {"filter_1", "shaper_1"}, {"shaper_1", "gain_1"}, {"gain_1", "out"},
		{"osc_1", "gain_2"}, {"gain_2", "out"},
		{"noise_2", "filter_2"}, {"filter_2", "gain_3"}, {"gain_3", "out"},
	}))
}

// Combat commons: Q3 hit-beep, a flesh thud, an unmake wash, a UT kill sting.

make_hit_confirm :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 80, "tick", .Triangle, 2480, 1180, 0.014, 0, 0.05, .Exp),
		gain("gain_1", 80, "tickAmp", 0.18, 0.014, 0, 0.05),
		noise("noise_1", 280, "tickAir", 0.008, 0),
		filter("filter_1", 280, "tickHp", .Highpass, 5400, 0, 0.7, 0, 0),
		gain("gain_2", 280, "tickAirAmp", 0.05, 0.008, 0, 0.08),
	}
	return patch("Hit Confirm", "play_hit_confirm", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
	}))
}

make_hurt :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		noise("noise_1", 60, "flesh", 0.08, 0),
		filter("filter_1", 60, "fleshLp", .Lowpass, 760, 280, 0.8, 0.06, 0.08),
		shaper("shaper_1", 60, "bruise", 4),
		gain("gain_1", 60, "fleshAmp", 0.18, 0.08, 0, 0.07),
		osc("osc_1", 280, "gut", .Sine, 210, 68, 0.13, 0, 0.06, .Exp),
		gain("gain_2", 280, "gutAmp", 0.20, 0.13, 0, 0.05),
	}
	return patch("Hurt", "play_hurt", nodes[:], link([][2]string{
		{"noise_1", "filter_1"}, {"filter_1", "shaper_1"}, {"shaper_1", "gain_1"}, {"gain_1", "out"},
		{"osc_1", "gain_2"}, {"gain_2", "out"},
	}))
}

make_death :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "unmake", .Sawtooth, 360, 48, 0.42, 0, 0.04, .Exp),
		gain("gain_1", 40, "unmakeAmp", 0.16, 0.42, 0, 0.04),
		noise("noise_1", 230, "ash", 0.32, 0),
		filter("filter_1", 230, "ashBp", .Bandpass, 880, 160, 0.9, 0.26, 0.06),
		gain("gain_2", 230, "ashAmp", 0.12, 0.32, 0, 0.05),
		osc("osc_2", 420, "body", .Sine, 92, 28, 0.48, 0, 0.05, .Exp),
		gain("gain_3", 420, "bodyAmp", 0.22, 0.48, 0, 0.04),
		delay("delay_1", 40, "wash", 0.22, 0.48, 0.55),
	}
	return patch("Death", "play_death", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "delay_1"}, {"delay_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "gain_3"}, {"gain_3", "out"},
	}))
}

make_kill :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "stabA", .Square, 880, 0, 0.04, 0, 0.03, .Exp),
		gain("gain_1", 40, "stabAAmp", 0.12, 0.04, 0, 0.04),
		osc("osc_2", 200, "stabB", .Sine, 1320, 0, 0.08, 0.04, 0.03, .Exp),
		gain("gain_2", 200, "stabBAmp", 0.14, 0.08, 0.04, 0.04),
		osc("osc_3", 360, "stabC", .Sine, 1760, 2200, 0.12, 0.08, 0.03, .Lin),
		gain("gain_3", 360, "stabCAmp", 0.12, 0.12, 0.08, 0.04),
	}
	return patch("Kill", "play_kill", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"osc_2", "gain_2"}, {"gain_2", "out"},
		{"osc_3", "gain_3"}, {"gain_3", "out"},
	}))
}

make_respawn :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 40, "reform", .Sine, 90, 220, 0.18, 0, 0.03, .Lin),
		gain("gain_1", 40, "reformAmp", 0.14, 0.18, 0, 0.04),
		osc("osc_2", 220, "over", .Triangle, 360, 720, 0.14, 0.05, 0.04, .Lin),
		gain("gain_2", 220, "overAmp", 0.10, 0.14, 0.05, 0.04),
		noise("noise_1", 400, "sparkle", 0.06, 0.08),
		filter("filter_1", 400, "sparkleBp", .Bandpass, 3800, 6800, 3.0, 0.05, 0.05),
		gain("gain_3", 400, "sparkleAmp", 0.045, 0.06, 0.08, 0.08),
	}
	return patch("Respawn", "play_respawn", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"osc_2", "gain_2"}, {"gain_2", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_3"}, {"gain_3", "out"},
	}))
}

make_fizzle :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 80, "deflate", .Sawtooth, 520, 90, 0.09, 0, 0.06, .Exp),
		gain("gain_1", 80, "deflateAmp", 0.10, 0.09, 0, 0.06),
		noise("noise_1", 280, "hiss", 0.07, 0),
		filter("filter_1", 280, "hissLp", .Lowpass, 700, 220, 0.8, 0.05, 0.08),
		gain("gain_2", 280, "hissAmp", 0.07, 0.07, 0, 0.08),
	}
	return patch("Fizzle", "play_fizzle", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
	}))
}

make_land :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 80, "body", .Sine, 78, 34, 0.09, 0, 0.05, .Exp),
		gain("gain_1", 80, "bodyAmp", 0.20, 0.09, 0, 0.05),
		noise("noise_1", 280, "dust", 0.025, 0),
		filter("filter_1", 280, "dustLp", .Lowpass, 420, 0, 0.8, 0, 0),
		gain("gain_2", 280, "dustAmp", 0.08, 0.025, 0, 0.1),
		osc("osc_2", 440, "click", .Triangle, 380, 110, 0.016, 0, 0.1, .Exp),
		gain("gain_3", 440, "clickAmp", 0.06, 0.016, 0, 0.1),
	}
	return patch("Land", "play_land", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
		{"osc_2", "gain_3"}, {"gain_3", "out"},
	}))
}

make_jump :: proc() -> wb.Patch {
	nodes := [?]wb.Graph_Node {
		out_node(),
		osc("osc_1", 80, "lift", .Sine, 210, 140, 0.045, 0, 0.06, .Exp),
		gain("gain_1", 80, "liftAmp", 0.10, 0.045, 0, 0.06),
		noise("noise_1", 280, "air", 0.02, 0),
		filter("filter_1", 280, "airHp", .Highpass, 2800, 0, 0.7, 0, 0),
		gain("gain_2", 280, "airAmp", 0.04, 0.02, 0, 0.1),
	}
	return patch("Jump", "play_jump", nodes[:], link([][2]string{
		{"osc_1", "gain_1"}, {"gain_1", "out"},
		{"noise_1", "filter_1"}, {"filter_1", "gain_2"}, {"gain_2", "out"},
	}))
}
