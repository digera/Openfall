package main

// The HUD: lobby, menus, vitals, hotbar, scoreboard and combat log, laid out
// on a character grid. It draws through a small text API that the platform
// backend provides:
//
//   hud_pos(col, row)          move the cursor to a cell
//   hud_color3f(r, g, b)       colour for what is written next
//   hud_puts(text)             write text at the cursor; "\n" starts the next line
//   hud_putc(c)                write one character
//
// The backend sets up the grid each frame and calls client_hud_draw with its
// size in cells.

import "core:fmt"
import "core:math"

hud_color :: proc(c: vec3) {
	hud_color3f(c.x, c.y, c.z)
}

hud_printf :: proc(format: string, args: ..any) {
	hud_puts(fmt.tprintf(format, ..args))
}

// A text line centred on the grid. Rows and columns are in character cells.
@(private = "file")
hud_center_text :: proc(cols: f32, row: f32, text: string) {
	col := cols * 0.5 - f32(len(text)) * 0.5
	hud_pos(max(col, 0), row)
	hud_puts(text)
}

// Lay out this frame's HUD on a character grid `cols` wide and `rows` tall.
client_hud_draw :: proc(gc: ^Game_Client, cols, rows: f32) {
	world := &gc.client_world

	// Stats line (always)
	hud_color3f(0.78, 0.76, 0.70)
	hud_printf("NEXUS ARENA  %.0f fps  %.1f ms", gc.frame_stats.last_fps, gc.frame_stats.frame_ms)
	if gc.frame_stats.gpu_ms > 0 {
		hud_printf("  gpu %.2f ms", gc.frame_stats.gpu_ms)
	}
	if gc.phase == .Playing || gc.phase == .In_Menu {
		rate, total := client_prediction_stats(&world.prediction)
		_, _, since := network_client_stats(&gc.network)
		hud_color3f(0.55, 0.53, 0.50)
		hud_printf("   corr %.1f%% (%d)  last pkt %.0fms  tick %d", rate * 100, total, since, world.client_tick)
	}
	hud_puts("\n")

	switch gc.phase {
	case .Connecting:
		hud_lobby_frame(gc, cols, rows, "SEARCHING FOR SERVER...")
	case .Team_Select:
		hud_lobby_frame(gc, cols, rows, "CHOOSE YOUR TEAM")
	case .Joining:
		hud_lobby_frame(gc, cols, rows, fmt.tprintf("JOINING %s...", team_name(gc.chosen_team)))
	case .Playing:
		hud_playing(gc, cols, rows)
	case .In_Menu:
		hud_in_game_menu(gc, cols, rows)
	}
}

@(private = "file")
hud_lobby_frame :: proc(gc: ^Game_Client, cols, rows: f32, title: string) {
	hud_color3f(0.95, 0.93, 0.86)
	hud_center_text(cols, rows * 0.28, "N E X U S   A R E N A")
	hud_color3f(0.62, 0.60, 0.68)
	hud_center_text(cols, rows * 0.28 + 1, "three teams. seven pylons of ore. one golden tower.")

	hud_color3f(0.90, 0.88, 0.80)
	hud_center_text(cols, rows * 0.42, title)

	if gc.phase == .Team_Select || gc.phase == .Joining {
		hud_color3f(0.62, 0.60, 0.56)
		hud_center_text(cols, rows * 0.42 + 1.5, "your name")
		name := player_name_display(&gc.player_name, 0, false)
		if gc.player_name.len == 0 {
			name = "(unnamed)"
		}
		if gc.name_editing {
			hud_color3f(0.98, 0.96, 0.88)
			hud_center_text(cols, rows * 0.42 + 2.5, fmt.tprintf("%s_", name))
		} else {
			hud_color3f(0.72, 0.70, 0.64)
			hud_center_text(cols, rows * 0.42 + 2.5, name)
		}

		base_row := rows * 0.42 + 5
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			allowed := client_team_allowed(gc, team)
			humans := int(gc.lobby.humans[i])
			bots := int(gc.lobby.bots[i])
			col := team_color(team)
			if !allowed {
				col = col * 0.35 + vec3{0.2, 0.2, 0.2}
			}
			hud_color(col)
			line := fmt.tprintf("[%d]  %-8s  %d players  %d bots%s", i + 1, team_name(team), humans, bots,
				allowed ? "" : "   (most populated - locked)")
			hud_center_text(cols, base_row + f32(i) * 2, line)
		}
		hud_color3f(0.55, 0.53, 0.50)
		hint := "press 1, 2 or 3 to join  -  Enter to rename  -  you cannot join the most populated team"
		if gc.name_editing {
			hint = "type a name, Enter when you are done  -  a blank name gets you one"
		}
		hud_center_text(cols, base_row + 7, hint)
		if gc.reject_timer > 0 {
			hud_color3f(1.0, 0.55, 0.45)
			msg := "that team is full or the most populated - pick another"
			#partial switch gc.reject_reason {
			case .Server_Full:  msg = "server is full"
			case .Invalid_Team: msg = "invalid team"
			}
			hud_center_text(cols, base_row + 9, msg)
		}
	}

	hud_color3f(0.42, 0.40, 0.38)
	hud_center_text(cols, rows - 1, fmt.tprintf("WASD move  /  Shift sprint  /  Space jump, on landing hop  /  E gust  /  G drop haul  /  1-%d spells  /  LMB cast  /  Z X C transfers  /  Esc unlock mouse", HOTBAR_SLOTS))
}

@(private = "file")
hud_in_game_menu :: proc(gc: ^Game_Client, cols, rows: f32) {
	// Draw a simple pause menu
	hud_color3f(0.95, 0.93, 0.86)
	hud_center_text(cols, rows * 0.25, "GAME MENU")
	
	hud_color3f(0.70, 0.68, 0.65)
	hud_center_text(cols, rows * 0.25 + 2, "Press ESC to resume")

	base_row := rows * 0.40
	
	// Team join options
	if gc.have_lobby {
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			allowed := client_team_allowed(gc, team)
			humans := int(gc.lobby.humans[i])
			bots := int(gc.lobby.bots[i])
			col := team_color(team)
			if !allowed {
				col = col * 0.35 + vec3{0.2, 0.2, 0.2}
			}
			hud_color(col)
			
			current_marker := ""
			if team == gc.client_world.local_team {
				current_marker = "  (current)"
			}
			
			line := fmt.tprintf("[%d]  Join %s  -  %d players  %d bots%s%s", 
				i + 1, team_name(team), humans, bots,
				allowed ? "" : "  (locked)",
				current_marker)
			hud_center_text(cols, base_row + f32(i) * 2, line)
		}
	} else {
		// Fallback if no lobby data
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			col := team_color(team)
			hud_color(col)
			line := fmt.tprintf("[%d]  Join %s", i + 1, team_name(team))
			hud_center_text(cols, base_row + f32(i) * 2, line)
		}
	}

	// Spectate option
	hud_color3f(0.70, 0.70, 0.70)
	spectate_marker := ""
	if gc.is_spectating {
		spectate_marker = "  (current)"
	}
	hud_center_text(cols, base_row + f32(TEAM_COUNT) * 2, fmt.tprintf("[4]  Spectate%s", spectate_marker))

	hud_color3f(0.50, 0.48, 0.45)
	hud_center_text(cols, base_row + f32(TEAM_COUNT) * 2 + 3, "Choose an option or press ESC to return to the game")
}

// E Z X C sit on their own row, centered above the number row. Name, then the
// wind-up or the cooldown, same as a spell slot.
@(private = "file")
hud_key_cluster :: proc(gc: ^Game_Client, world: ^Client_World, local: Character_State, cols, rows: f32) {
	slot_w: f32 = 14
	origin := cols * 0.5 - slot_w * f32(len(KEY_BINDS)) * 0.5
	for i in 0..<len(KEY_BINDS) {
		bind := KEY_BINDS[i]
		spell := bind.spell
		def := &SPELL_DEFS[spell]
		cd := gc.cooldowns[spell]
		col := origin + f32(i) * slot_w

		hud_pos(col, rows - 5)
		hud_color3f(0.82, 0.78, 0.62)
		hud_printf("%s %-6s", bind.key, def.short_name)

		hud_pos(col, rows - 4)
		ready := spell_castable(spell, local, cd)
		if spell == gc.charging_spell {
			charge := spell_charge_frac(def, gc.charge_accum)
			if charge < SPELL_MIN_CHARGE {
				hud_color3f(0.45, 0.5, 0.6)
			} else {
				hud_color3f(0.3, 0.85, 1.0)
			}
			filled := int(charge * 8)
			for k in 0..<8 {
				hud_putc(k < filled ? '#' : '.')
			}
		} else if cd > 0 {
			hud_color3f(0.45, 0.45, 0.5)
			frac := 1.0 - cd / def.cooldown_sec
			filled := int(frac * 6)
			for k in 0..<6 {
				hud_putc(k < filled ? '=' : '.')
			}
			hud_printf(" %.0f", cd)
		} else if def.payload == .Heal && !client_heal_has_work(world, local) {
			hud_color3f(0.5, 0.7, 0.55)
			hud_puts("full hp")
		} else if def.payload == .Transfer && vital_can_spend(local, def.transfer_from, def.transfer_cost) && vital_full(local, def.transfer_to) {
			hud_color3f(0.5, 0.7, 0.55)
			hud_puts("full")
		} else if !ready {
			hud_color3f(0.45, 0.55, 0.85)
			if def.payload == .Transfer {
				hud_printf("%.0f %s", def.transfer_cost, vital_label(def.transfer_from))
			} else {
				hud_printf("%.0f mp", def.mana_cost)
			}
		} else {
			hud_color3f(0.5, 0.75, 0.55)
			hud_puts("========")
		}
	}
}

@(private = "file")
hud_playing :: proc(gc: ^Game_Client, cols, rows: f32) {
	world := &gc.client_world
	pred := &world.prediction
	local := pred.predicted_char
	gs := &world.game_state

	// Spectator mode: show simplified HUD
	if gc.is_spectating {
		hud_color3f(0.70, 0.70, 0.70)
		hud_center_text(cols, rows * 0.1, "SPECTATING")
		hud_color3f(0.50, 0.50, 0.50)
		hud_center_text(cols, rows * 0.1 + 1, "Press ESC to open menu and join a team")
		
		// Show match status
		if world.have_game_state {
			state := Match_State(gs.match_state)
			status := ""
			switch state {
			case .Waiting:
				status = fmt.tprintf("WARMUP  %d", int(max(WARMUP_DURATION - gs.match_time, 0)))
			case .Active:
				m := int(gs.match_time) / 60
				s := int(gs.match_time) % 60
				status = fmt.tprintf("%02d:%02d", m, s)
			case .Ended:
				if Match_Result(gs.match_result) == .Team_Wins {
					status = fmt.tprintf("%s WINS", team_name(Team_ID(gs.winner)))
				} else {
					status = "DRAW"
				}
			}
			hud_color3f(0.80, 0.78, 0.75)
			hud_center_text(cols, rows * 0.15, status)
			
			// Scores
			line_w: f32 = 0
			parts: [TEAM_COUNT]string
			for i in 0..<TEAM_COUNT {
				parts[i] = fmt.tprintf("%s %4.0f", team_name(team_from_index(i)), gs.essence[i])
				line_w += f32(len(parts[i]))
			}
			line_w += 3 * 2
			col := cols * 0.5 - line_w * 0.5
			hud_pos(col, rows * 0.15 + 1)
			for i in 0..<TEAM_COUNT {
				team := team_from_index(i)
				hud_color(team_color(team))
				hud_puts(parts[i])
				if i < TEAM_COUNT - 1 {
					hud_color3f(0.5, 0.5, 0.5)
					hud_puts(" /")
				}
			}
		}
		return
	}

	// --- Match header (top center) --------------------------------------------
	if world.have_game_state {
		state := Match_State(gs.match_state)
		status := ""
		switch state {
		case .Waiting:
			status = fmt.tprintf("WARMUP  %d", int(max(WARMUP_DURATION - gs.match_time, 0)))
		case .Active:
			m := int(gs.match_time) / 60
			s := int(gs.match_time) % 60
			status = fmt.tprintf("%02d:%02d", m, s)
		case .Ended:
			if Match_Result(gs.match_result) == .Team_Wins {
				status = fmt.tprintf("%s WINS", team_name(Team_ID(gs.winner)))
			} else {
				status = "DRAW"
			}
		}
		hud_color3f(0.95, 0.93, 0.86)
		hud_center_text(cols, 1, status)

		// Scores
		line_w: f32 = 0
		parts: [TEAM_COUNT]string
		for i in 0..<TEAM_COUNT {
			parts[i] = fmt.tprintf("%s %4.0f", team_name(team_from_index(i)), gs.essence[i])
			line_w += f32(len(parts[i]))
		}
		line_w += 3 * 2
		col := cols * 0.5 - line_w * 0.5
		hud_pos(col, 2)
		for i in 0..<TEAM_COUNT {
			team := team_from_index(i)
			hud_color(team_color(team))
			if team == world.local_team {
				hud_puts(">")
			} else {
				hud_puts(" ")
			}
			hud_puts(parts[i])
			if i < TEAM_COUNT - 1 {
				hud_color3f(0.5, 0.5, 0.5)
				hud_puts(" /")
			}
		}

		// The round, once the golden pylon is down: whose rock is going back
		// into the stump. This replaces the pylon row it sits on, because from
		// the moment the centre opens it is the only line that decides anything.
		if gs.centre_open {
			share_w := f32(TEAM_COUNT) * 11
			hud_pos(cols * 0.5 - share_w * 0.5, 3)
			hud_color3f(0.95, 0.88, 0.55)
			hud_puts("CENTRE ")
			for i in 0..<TEAM_COUNT {
				hud_color(team_color(team_from_index(i)))
				hud_printf("%s %3d%% ", team_name(team_from_index(i)), int(f32(gs.centre_share[i]) / 255.0 * 100))
			}
		} else {
			// Towers: remaining mass, chips included. G is the golden one in
			// the centre, then the near-lane towers and the far ones.
			hud_pos(cols * 0.5 - f32(MAX_PYLONS) * 4.0, 3)
			for i in 0..<MAX_PYLONS {
				t := &world.towers.towers[i]
				hud_color(ore_color(tower_display_ore(t)))
				label := i == 0 ? "G" : fmt.tprintf("%d", i)
				hud_printf("[%s %3d]", label, int(tower_mass_frac(t) * 100 + 0.5))
				hud_puts(" ")
			}
		}

		// The wallet: what the local team has banked, one column per ore.
		// Enemy ore buys extra pushers that walk the *other* rival's lane, so a
		// stack of Ember on Verdant's HUD is a Tide problem, not an Ember one.
		if world.local_team != .None && world.local_team != .Spectator {
			w := &gs.wallets[team_index(world.local_team)]
			line := f32(ORE_COUNT) * 9
			hud_pos(cols * 0.5 - line * 0.5, 4)
			for k in 0..<ORE_COUNT {
				kind := ore_from_index(k)
				hud_color(ore_color(kind))
				hud_printf("%-7s %3d ", ore_name(kind), int(w[k]))
			}
		}
	}

	// --- Vitals (bottom left) --------------------------------------------------
	hud_y := rows - 8
	hud_pos(0, hud_y)
	hud_color3f(1.0, 0.42, 0.36)
	hud_puts("HP ")
	draw_bar(local.health, HEALTH_MAX, 22)
	hud_printf(" %3.0f", local.health)

	hud_pos(0, hud_y + 1)
	hud_color3f(0.45, 0.66, 1.0)
	hud_puts("MP ")
	draw_bar(local.mana, MANA_MAX, 22)
	hud_printf(" %3.0f", local.mana)

	hud_pos(0, hud_y + 2)
	hud_color3f(0.55, 0.9, 0.5)
	hud_puts("ST ")
	draw_bar(local.stamina, STAMINA_MAX, 22)
	hud_printf(" %3.0f", local.stamina)

	if local.slow_ticks > 0 {
		hud_pos(0, hud_y + 3)
		hud_color3f(0.5, 0.92, 1.0)
		hud_puts("SLOWED")
	}

	// Haul sits with the vitals, not the combat log. Bottom-right is already
	// the kill feed; a capacity readout next to HP is what you glance at
	// while turning for home.
	haul := carry_total(local.carrying_ore)
	if haul > 0 {
		row := hud_y + 3
		if local.slow_ticks > 0 {
			row = hud_y + 4
		}
		hud_pos(0, row)
		base := ore_color(carry_dominant(local.carrying_ore))
		glow := world.haul_pulse * world.haul_pulse
		hud_color(base * (1.0 + glow * 0.8) + vec3{glow * 0.4, glow * 0.4, glow * 0.4})
		hud_printf("HAUL %.0f/%.0f  ", haul, CARRY_CAPACITY_MAX)
		// G is ignored in your own dump — standing there already banks — so the
		// haul line says BANKING instead of offering a drop that will not fire.
		// The server owns the dump; this hint lives for the snapshot delay
		// while predicted haul is still in the pack.
		if in_dump_zone(local.pos, world.local_team) {
			pulse := 0.7 + 0.3 * math.sin(f32(world.local_time) * 3.0)
			hud_color3f(0.85 * pulse, 0.95 * pulse, 0.50 * pulse)
			hud_puts("BANKING")
		} else {
			hud_puts("[G drop]")
		}
	}

	// --- Hotbar (bottom center) ------------------------------------------------
	slot_w: f32 = 14
	start := cols * 0.5 - slot_w * f32(HOTBAR_SLOTS) * 0.5
	for i in 0..<HOTBAR_SLOTS {
		spell := HOTBAR[i]
		col := start + f32(i) * slot_w
		def := &SPELL_DEFS[spell]
		cd := gc.cooldowns[spell]
		selected := i == gc.selected_slot
		ready := spell_castable(spell, local, cd)

		hud_pos(col, rows - 3)
		if selected {
			hud_color3f(1.0, 0.95, 0.6)
			hud_printf("[%d] %-8s", i + 1, def.short_name)
		} else {
			hud_color3f(0.6, 0.58, 0.54)
			hud_printf(" %d  %-8s", i + 1, def.short_name)
		}

		hud_pos(col, rows - 2)
		if spell == gc.charging_spell && def.payload == .Beam {
			// A beam has no wind-up to show; the bar crackles while the server
			// keeps it lit and the mana drain, drawn to its right, is the
			// thing to watch.
			_, lit := client_world_local_beam(world)
			if !lit {
				hud_color3f(0.45, 0.5, 0.6)
			} else {
				hud_color3f(0.75, 0.88, 1.0)
			}
			phase := int(world.local_time * 24)
			for k in 0..<10 {
				hud_putc((k + phase) % 3 == 0 ? '~' : '#')
			}
			hud_printf(" -%.0f/s", def.beam_mana_per_sec)
		} else if spell == gc.charging_spell {
			// Wind-up: dim early, bright once the bar is well on its way.
			// Letting go does not stop this — an early release still fills.
			charge := spell_charge_frac(def, gc.charge_accum)
			if charge < SPELL_MIN_CHARGE {
				hud_color3f(0.45, 0.5, 0.6)
			} else {
				hud_color3f(0.3, 0.85, 1.0)
			}
			filled := int(charge * 10)
			for k in 0..<10 {
				hud_putc(k < filled ? '#' : '.')
			}
			hud_printf(" %3.0f%%", charge * 100)
		} else if cd > 0 {
			hud_color3f(0.45, 0.45, 0.5)
			frac := 1.0 - cd / def.cooldown_sec
			filled := int(frac * 10)
			for k in 0..<10 {
				hud_putc(k < filled ? '=' : '.')
			}
			hud_printf(" %.1f", cd)
		} else if def.payload == .Heal && !client_heal_has_work(world, local) {
			// Nothing to mend: say so rather than blaming the mana.
			hud_color3f(0.5, 0.7, 0.55)
			hud_puts("at full hp")
		} else if !ready {
			hud_color3f(0.45, 0.55, 0.85)
			hud_printf("need %.0f mp", def.mana_cost)
		} else {
			hud_color3f(0.5, 0.75, 0.55)
			hud_puts("==========")
		}
	}

	hud_key_cluster(gc, world, local, cols, rows)

	// --- Center ----------------------------------------------------------------
	cx := cols * 0.5
	cy := rows * 0.5
	if local.dead {
		hud_color3f(1.0, 0.5, 0.45)
		hud_center_text(cols, cy - 1, "YOU WERE UNMADE")
		hud_color3f(0.8, 0.78, 0.72)
		hud_center_text(cols, cy + 1, fmt.tprintf("respawning in %.0f", max(local.respawn_timer, 0)))
	} else {
		if world.hit_marker > 0.05 {
			hud_color3f(1.0, 0.9, 0.5)
			hud_pos(cx - 1, cy - 1); hud_puts("\\ /")
			hud_pos(cx - 1, cy + 1); hud_puts("/ \\")
		}
		hud_color3f(0.85, 0.83, 0.78)
		hud_pos(cx, cy)
		hud_puts("+")
		hud_target_panel(world, cols, cy + 2)
	}

	if !platform_mouse_locked() {
		hud_color3f(0.95, 0.9, 0.7)
		hud_center_text(cols, cy + 4, "click to capture the mouse")
	}

	if world.have_game_state && Match_State(gs.match_state) == .Waiting {
		hud_color3f(0.7, 0.68, 0.62)
		hud_center_text(cols, 6, "carry ore back to your base dump to bank it - your own rock thickens the next wave")
		hud_center_text(cols, 7, "bring the golden tower down, then finish it: most rock laid wins")
	}

	// Taking a tower does not open a push; it turns the owner's waves into a
	// repair crew. That is the one rule of this mode nobody guesses, so it is
	// said out loud the first time a friendly tower is missing enough rock
	// that the next wave will hop it, and again once the centre is the prize.
	if world.have_game_state && Match_State(gs.match_state) == .Active {
		if gs.centre_open {
			hud_color3f(0.95, 0.88, 0.55)
			hud_center_text(cols, 6, "the centre is open - finish the tower, most rock laid wins")
		} else if world.local_team != .None && world.local_team != .Spectator {
			own := team_index(world.local_team)
			near := own + 1
			far := own + 4
			if gs.towers[near].intact < PYLON_REBUILD_FRAC || gs.towers[far].intact < PYLON_REBUILD_FRAC {
				hud_color3f(0.85, 0.78, 0.55)
				hud_center_text(cols, 6, "your waves are rebuilding the tower - flattening a lane stalls that team")
			}
		}
	}

	hud_combat_log(world, cols, rows)
	if input.key_tab {
		hud_scoreboard(world, cols, rows)
	}
}

// Recent combat, bottom right, out of the way of the crosshair, the vitals and
// the hotbar. Newest at the bottom, each line holding at full brightness and
// then fading rather than vanishing mid-read.
@(private = "file")
hud_combat_log :: proc(world: ^Client_World, cols, rows: f32) {
	// Oldest first, so the list reads downward the way a log should.
	order: [MAX_COMBAT_LOG_LINES]int
	count := 0
	for i in 0..<MAX_COMBAT_LOG_LINES {
		if !world.combat_log[i].live {
			continue
		}
		pos := count
		for pos > 0 && world.combat_log[order[pos - 1]].age < world.combat_log[i].age {
			order[pos] = order[pos - 1]
			pos -= 1
		}
		order[pos] = i
		count += 1
	}

	left := max(cols - 40, 0)
	top := rows - 6 - f32(count)
	for k in 0..<count {
		line := &world.combat_log[order[k]]
		other := client_world_name(world, line.other_id)
		spell := SPELL_DEFS[line.spell_id].short_name

		text: string
		col: vec3
		switch line.event_type {
		case .Damage_Dealt:
			text = fmt.tprintf("you hit %s for %d (%s)", other, line.damage, spell)
			col = {1.0, 0.82, 0.35}
		case .Damage_Taken:
			if line.other_id == world.local_entity_id {
				// Self-inflicted: a hard landing carries no spell.
				text = line.spell_id == .None ? fmt.tprintf("the landing cost you %d", line.damage) : fmt.tprintf("your own %s hit you for %d", spell, line.damage)
			} else {
				text = fmt.tprintf("%s hit you for %d (%s)", other, line.damage, spell)
			}
			col = {1.0, 0.45, 0.35}
		case .Kill:
			text = fmt.tprintf("you unmade %s", other)
			col = {0.55, 1.0, 0.45}
		case .Death:
			text = fmt.tprintf("%s unmade you", other)
			col = {1.0, 0.35, 0.35}
		}

		fade := clampf((COMBAT_LOG_HOLD_SEC + COMBAT_LOG_FADE_SEC - line.age) / COMBAT_LOG_FADE_SEC, 0, 1)
		hud_color(col * fade)
		hud_pos(left, top + f32(k))
		hud_puts(text)
	}
}

// Hold Tab for the whole match: everyone the roster knows about, grouped by
// team. The roster is not interest-managed, so this is the real scoreline and
// not just the players who happen to be nearby.
@(private = "file")
hud_scoreboard :: proc(world: ^Client_World, cols, rows: f32) {
	ids: [MAX_ENTITIES]Entity_ID
	count := 0
	for i in 1..<MAX_ENTITIES {
		if world.roster[i].present {
			ids[count] = Entity_ID(i)
			count += 1
		}
	}
	if count == 0 {
		return
	}

	// Team first so the groups hold together, then kills, then fewest deaths.
	for i in 1..<count {
		id := ids[i]
		a := &world.roster[id]
		j := i
		for j > 0 {
			b := &world.roster[ids[j - 1]]
			better := int(a.team) < int(b.team) ||
				(a.team == b.team && a.stats.kills > b.stats.kills) ||
				(a.team == b.team && a.stats.kills == b.stats.kills && a.stats.deaths < b.stats.deaths)
			if !better {
				break
			}
			ids[j] = ids[j - 1]
			j -= 1
		}
		ids[j] = id
	}

	width: f32 = 46
	height := f32(count + TEAM_COUNT + 3)
	left := max(cols * 0.5 - width * 0.5, 0)
	top := max(rows * 0.5 - height * 0.5, 4)

	hud_color3f(0.95, 0.93, 0.86)
	hud_center_text(cols, top, "SCOREBOARD")
	hud_color3f(0.55, 0.53, 0.50)
	hud_pos(left, top + 1)
	hud_printf("%-18s %4s %4s %7s %7s", "name", "k", "d", "dealt", "taken")

	row := top + 2
	last_team := Team_ID.None
	for k in 0..<count {
		id := ids[k]
		slot := &world.roster[id]
		if slot.team != last_team {
			last_team = slot.team
			hud_color(team_color(slot.team) * 0.8)
			hud_pos(left, row)
			hud_puts(team_name(slot.team))
			row += 1
		}
		if id == world.local_entity_id {
			hud_color3f(1.0, 0.95, 0.6)
		} else if slot.is_bot {
			hud_color3f(0.62, 0.60, 0.56)
		} else {
			hud_color3f(0.86, 0.84, 0.79)
		}
		hud_pos(left, row)
		hud_printf("%-18s %4d %4d %7.0f %7.0f",
			client_world_name(world, id),
			slot.stats.kills, slot.stats.deaths,
			slot.stats.damage_dealt, slot.stats.damage_taken)
		row += 1
	}
}

// Who the crosshair is holding, under the crosshair: name in team colour over a
// health bar. Nothing is drawn when there is no target, so the centre of the
// screen stays clean while the player is just moving around.
@(private = "file")
hud_target_panel :: proc(world: ^Client_World, cols: f32, row: f32) {
	if world.target_id == INVALID_ENTITY {
		return
	}
	remote := &world.remote_entities[world.target_id]

	hud_color(team_color(remote.team))
	hud_center_text(cols, row, client_world_name(world, remote.id))

	hp := remote.display_state.health
	frac := hp / HEALTH_MAX
	if frac > 0.6 {
		hud_color3f(0.5, 0.9, 0.5)
	} else if frac > 0.3 {
		hud_color3f(1.0, 0.8, 0.3)
	} else {
		hud_color3f(1.0, 0.4, 0.3)
	}
	hud_pos(cols * 0.5 - 10, row + 1)  // 16-cell bar plus " 100" centres at -10
	draw_bar(hp, HEALTH_MAX, 14)
	hud_printf(" %3.0f", hp)
	haul := carry_total(remote.carrying_ore)
	if haul > 0 {
		hud_color(ore_color(carry_dominant(remote.carrying_ore)))
		hud_center_text(cols, row + 2, fmt.tprintf("haul %.0f/%.0f", haul, CARRY_CAPACITY_MAX))
	}
}

draw_bar :: proc(value: f32, max_value: f32, width: int) {
	filled := int((value / max_value) * f32(width) + 0.5)
	filled = clamp(filled, 0, width)
	hud_putc('[')
	for i in 0..<filled {
		hud_putc('=')
	}
	for i in filled..<width {
		hud_putc(' ')
	}
	hud_putc(']')
}
