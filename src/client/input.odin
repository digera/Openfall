package main

// Keyboard and mouse state for the graphical client. The platform backend
// translates its window events into the input_on_* calls below; everything
// else reads the state through the input_consume_* procedures.

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

// The keys the game binds, named by the platform backend. The digits must stay
// contiguous: a slot is its offset from Num_1.
Key :: enum u8 {
	W, A, S, D,
	Shift, Tab, Enter, Backspace, Space, Escape,
	E, G, Z, X, C,
	Num_1, Num_2, Num_3, Num_4, Num_5, Num_6, Num_7, Num_8, Num_9,
}

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
}

input_on_mouse_move :: proc(x, y, dx, dy: f32) {
	input.mouse_x = x
	input.mouse_y = y
	if platform_mouse_locked() {
		input.look_dx += dx
		input.look_dy += dy
	}
}

input_on_mouse_button :: proc(button: Mouse_Button, down: bool, x, y: f32) {
	if down {
		input.mouse_x = x
		input.mouse_y = y
	}
	#partial switch button {
	case .Left:
		if down {
			input.click_left = true
		}
		input.held_left = down
	case .Right:
		input.held_right = down
	}
}

// `repeat` is the OS auto-repeat of a held key; the game only wants the edge.
input_on_key :: proc(key: Key, down, repeat: bool) {
	if !down {
		#partial switch key {
		case .W: input.key_w = false
		case .A: input.key_a = false
		case .S: input.key_s = false
		case .D: input.key_d = false
		case .Shift: input.key_shift = false
		case .Tab: input.key_tab = false
		case .C: input.key_c = false
		case .Space: input.key_space = false
		}
		return
	}
	if repeat {
		return
	}
	switch key {
	case .W: input.key_w = true
	case .A: input.key_a = true
	case .S: input.key_s = true
	case .D: input.key_d = true
	case .Shift: input.key_shift = true
	case .Tab: input.key_tab = true
	case .Enter: input.enter_press = true
	case .Backspace: input.backspace_press = true
	case .Space:
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
	case .Num_1, .Num_2, .Num_3, .Num_4, .Num_5, .Num_6, .Num_7, .Num_8, .Num_9:
		slot := int(key) - int(Key.Num_1)
		if slot < HOTBAR_SLOTS {
			input.slot_press[slot] = true
		}
		// In menu phase, number keys select menu items
		if game_client.phase == .In_Menu {
			game_client.menu_selected = slot
		}
	case .Escape:
		// If in the Playing phase and mouse is locked, open menu instead of just unlocking
		if game_client.phase == .Playing && platform_mouse_locked() {
			game_client.phase = .In_Menu
			platform_lock_mouse(false)
			input_clear_held()
		} else if game_client.phase == .In_Menu {
			// Close menu and resume playing
			game_client.phase = .Playing
			input_clear_held()
		} else {
			// In other phases (Connecting, Team_Select, Joining), just unlock
			platform_lock_mouse(false)
			input_clear_held()
		}
	}
}

// One typed character, after the layout has decided what the key means.
input_on_char :: proc(char_code: u32) {
	if input.text_count < len(input.text_chars) && char_code >= 32 && char_code < 127 {
		input.text_chars[input.text_count] = u8(char_code)
		input.text_count += 1
	}
}

input_on_focus :: proc(focused: bool) {
	input.window_focused = focused
	if !focused {
		platform_lock_mouse(false)
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
