package main

import "base:runtime"
import sapp "sokol:app"

Input :: struct {
	mouse_x:        f32,
	mouse_y:        f32,
	look_dx:        f32,
	look_dy:        f32,
	click_left:     bool,
	held_left:      bool,
	held_right:     bool,
	key_w:          bool,
	key_a:          bool,
	key_s:          bool,
	key_d:          bool,
	key_space:      bool,
	key_shift:      bool,
	key_tab:        bool,      // held, for the scoreboard
	key_c:          bool,      // held: wind Friendly Heal without leaving the number row
	jump:           bool,      // latched press
	drop_press:     bool,      // latched G, toss the haul
	slot_press:     [HOTBAR_SLOTS]bool,   // latched number-key presses
	tap_press:      Spell_ID,            // latched E, Z or X; .None if none
	window_focused: bool,

	// Typed text for the name field, gathered from CHAR events so the layout
	// decides what a key means rather than us. Number keys therefore arrive
	// both here and in slot_press; the lobby picks which one it wants.
	text_chars:     [16]u8,
	text_count:     int,
	enter_press:    bool,
	backspace_press: bool,
}

input: Input = {
	window_focused = true,
}

@(private)
input_clear_held :: proc() {
	input.held_left = false
	input.held_right = false
	input.key_w = false
	input.key_a = false
	input.key_s = false
	input.key_d = false
	input.key_space = false
	input.key_shift = false
	input.key_tab = false
	input.key_c = false
	input.look_dx = 0
	input.look_dy = 0
	input.click_left = false
	input.jump = false
	input.drop_press = false
	input.slot_press = {}
	input.tap_press = .None
	input.text_count = 0
	input.enter_press = false
	input.backspace_press = false
}

input_event :: proc "c" (e: ^sapp.Event) {
	context = runtime.default_context()
	#partial switch e.type {
	case .MOUSE_MOVE:
		input.mouse_x = e.mouse_x
		input.mouse_y = e.mouse_y
		if sapp.mouse_locked() {
			input.look_dx += e.mouse_dx
			input.look_dy += e.mouse_dy
		}
	case .MOUSE_DOWN:
		input.mouse_x = e.mouse_x
		input.mouse_y = e.mouse_y
		if e.mouse_button == .LEFT {
			input.click_left = true
			input.held_left = true
		}
		if e.mouse_button == .RIGHT {
			input.held_right = true
		}
	case .MOUSE_UP:
		if e.mouse_button == .LEFT {
			input.held_left = false
		}
		if e.mouse_button == .RIGHT {
			input.held_right = false
		}
	case .KEY_DOWN:
		if e.key_repeat {
			break
		}
		#partial switch e.key_code {
		case .W: input.key_w = true
		case .A: input.key_a = true
		case .S: input.key_s = true
		case .D: input.key_d = true
		case .LEFT_SHIFT, .RIGHT_SHIFT: input.key_shift = true
		case .TAB: input.key_tab = true
		case .ENTER, .KP_ENTER: input.enter_press = true
		case .BACKSPACE: input.backspace_press = true
		case .SPACE:
			input.key_space = true
			input.jump = true
		case .G:
			input.drop_press = true
		case .E:
			if input.tap_press == .None {
				input.tap_press = .Gust
			}
		case .Z:
			if input.tap_press == .None {
				input.tap_press = .Stamina_To_Mana
			}
		case .X:
			if input.tap_press == .None {
				input.tap_press = .Health_To_Stamina
			}
		case .C:
			input.key_c = true
		case ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9:
			slot := int(e.key_code) - int(sapp.Keycode._1)
			if slot < HOTBAR_SLOTS {
				input.slot_press[slot] = true
			}
			// In menu phase, number keys select menu items
			if game_client.phase == .In_Menu {
				game_client.menu_selected = slot
			}
		case .ESCAPE:
			// If in the Playing phase and mouse is locked, open menu instead of just unlocking
			if game_client.phase == .Playing && sapp.mouse_locked() {
				game_client.phase = .In_Menu
				sapp.lock_mouse(false)
				input_clear_held()
			} else if game_client.phase == .In_Menu {
				// Close menu and resume playing
				game_client.phase = .Playing
				input_clear_held()
			} else {
				// In other phases (Connecting, Team_Select, Joining), just unlock
				sapp.lock_mouse(false)
				input_clear_held()
			}
		}
	case .KEY_UP:
		#partial switch e.key_code {
		case .W: input.key_w = false
		case .A: input.key_a = false
		case .S: input.key_s = false
		case .D: input.key_d = false
		case .LEFT_SHIFT, .RIGHT_SHIFT: input.key_shift = false
		case .TAB: input.key_tab = false
		case .C: input.key_c = false
		case .SPACE: input.key_space = false
		}
	case .CHAR:
		if input.text_count < len(input.text_chars) && e.char_code >= 32 && e.char_code < 127 {
			input.text_chars[input.text_count] = u8(e.char_code)
			input.text_count += 1
		}
	case .FOCUSED:
		input.window_focused = true
	case .UNFOCUSED:
		input.window_focused = false
		sapp.lock_mouse(false)
		input_clear_held()
	}
}

input_consume_click :: proc() -> bool {
	if input.click_left {
		input.click_left = false
		return true
	}
	return false
}

input_consume_jump :: proc() -> bool {
	if input.jump {
		input.jump = false
		return true
	}
	return false
}

input_consume_drop :: proc() -> bool {
	if input.drop_press {
		input.drop_press = false
		return true
	}
	return false
}

input_consume_tap :: proc() -> Spell_ID {
	spell := input.tap_press
	input.tap_press = .None
	return spell
}

// slot is 1-based
input_consume_slot :: proc(slot: int) -> bool {
	if slot < 1 || slot > HOTBAR_SLOTS {
		return false
	}
	if input.slot_press[slot - 1] {
		input.slot_press[slot - 1] = false
		return true
	}
	return false
}

// Everything typed since the last call. Callers that do not want text must
// still consume it, or a stray keystroke turns up in the name field later.
input_consume_text :: proc() -> []u8 {
	out := input.text_chars[:input.text_count]
	input.text_count = 0
	return out
}

input_consume_enter :: proc() -> bool {
	if input.enter_press {
		input.enter_press = false
		return true
	}
	return false
}

input_consume_backspace :: proc() -> bool {
	if input.backspace_press {
		input.backspace_press = false
		return true
	}
	return false
}

input_consume_look :: proc() -> (dx, dy: f32) {
	dx = input.look_dx
	dy = input.look_dy
	input.look_dx = 0
	input.look_dy = 0
	return
}
