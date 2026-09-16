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
	key_w:          bool,
	key_a:          bool,
	key_s:          bool,
	key_d:          bool,
	key_space:      bool,
	key_shift:      bool,
	jump:           bool,      // latched press
	slot_press:     [4]bool,   // latched 1..4 presses
	window_focused: bool,
}

input: Input = {
	window_focused = true,
}

@(private)
input_clear_held :: proc() {
	input.held_left = false
	input.key_w = false
	input.key_a = false
	input.key_s = false
	input.key_d = false
	input.key_space = false
	input.key_shift = false
	input.look_dx = 0
	input.look_dy = 0
	input.click_left = false
	input.jump = false
	input.slot_press = {}
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
	case .MOUSE_UP:
		if e.mouse_button == .LEFT {
			input.held_left = false
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
		case .SPACE:
			input.key_space = true
			input.jump = true
		case ._1: input.slot_press[0] = true
		case ._2: input.slot_press[1] = true
		case ._3: input.slot_press[2] = true
		case ._4: input.slot_press[3] = true
		case .ESCAPE:
			sapp.lock_mouse(false)
			input_clear_held()
		}
	case .KEY_UP:
		#partial switch e.key_code {
		case .W: input.key_w = false
		case .A: input.key_a = false
		case .S: input.key_s = false
		case .D: input.key_d = false
		case .LEFT_SHIFT, .RIGHT_SHIFT: input.key_shift = false
		case .SPACE: input.key_space = false
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

// slot is 1-based
input_consume_slot :: proc(slot: int) -> bool {
	if slot < 1 || slot > 4 {
		return false
	}
	if input.slot_press[slot - 1] {
		input.slot_press[slot - 1] = false
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
