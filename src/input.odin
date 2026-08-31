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
	jump:           bool,
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
	input.look_dx = 0
	input.look_dy = 0
	input.click_left = false
	input.jump = false
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
		case .W:
			input.key_w = true
		case .A:
			input.key_a = true
		case .S:
			input.key_s = true
		case .D:
			input.key_d = true
		case .SPACE:
			input.key_space = true
			input.jump = true
		case .ESCAPE:
			sapp.lock_mouse(false)
			input_clear_held()
		}
	case .KEY_UP:
		#partial switch e.key_code {
		case .W:
			input.key_w = false
		case .A:
			input.key_a = false
		case .S:
			input.key_s = false
		case .D:
			input.key_d = false
		case .SPACE:
			input.key_space = false
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

input_consume_look :: proc() -> (dx, dy: f32) {
	dx = input.look_dx
	dy = input.look_dy
	input.look_dx = 0
	input.look_dy = 0
	return
}

input_wish_xy :: proc() -> (fwd, str: f32) {
	if input.key_w {
		fwd += 1
	}
	if input.key_s {
		fwd -= 1
	}
	if input.key_d {
		str += 1
	}
	if input.key_a {
		str -= 1
	}
	return
}

input_look_ray :: proc(cam: Camera) -> (origin, dir: vec3) {
	w := sapp.widthf()
	h := sapp.heightf()
	basis := camera_basis(cam, w / h)
	origin = basis.pos
	dir = basis.forward
	return
}
