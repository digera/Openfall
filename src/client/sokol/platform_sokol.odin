package main

// Sokol platform backend: sokol_app owns the window and the event loop, and
// forwards them to the client (see the contract at the top of
// src/client/main_client.odin).

import "base:runtime"
import sapp "sokol:app"
import slog "sokol:log"

platform_run :: proc(title: cstring, width, height: i32) {
	sapp.run({
		init_cb       = sokol_init,
		frame_cb      = sokol_frame,
		cleanup_cb    = sokol_cleanup,
		event_cb      = sokol_event,
		width         = width,
		height        = height,
		sample_count  = 1,
		high_dpi      = false,
		window_title  = title,
		icon          = {sokol_default = true},
		logger        = {func = slog.func},
		swap_interval = 1,
	})
}

platform_frame_duration :: proc() -> f64 {
	return sapp.frame_duration()
}

platform_mouse_locked :: proc() -> bool {
	return sapp.mouse_locked()
}

platform_lock_mouse :: proc(lock: bool) {
	sapp.lock_mouse(lock)
}

@(private = "file")
sokol_init :: proc "c" () {
	context = runtime.default_context()
	client_init()
}

@(private = "file")
sokol_frame :: proc "c" () {
	context = runtime.default_context()
	client_frame()
}

@(private = "file")
sokol_cleanup :: proc "c" () {
	context = runtime.default_context()
	client_cleanup()
}

@(private = "file")
sokol_event :: proc "c" (e: ^sapp.Event) {
	context = runtime.default_context()
	#partial switch e.type {
	case .MOUSE_MOVE:
		input_on_mouse_move(e.mouse_x, e.mouse_y, e.mouse_dx, e.mouse_dy)
	case .MOUSE_DOWN, .MOUSE_UP:
		button: Mouse_Button
		switch e.mouse_button {
		case .LEFT: button = .Left
		case .RIGHT: button = .Right
		case .MIDDLE: button = .Middle
		case .INVALID: return
		}
		input_on_mouse_button(button, e.type == .MOUSE_DOWN, e.mouse_x, e.mouse_y)
	case .KEY_DOWN, .KEY_UP:
		if key, ok := sokol_key(e.key_code); ok {
			input_on_key(key, e.type == .KEY_DOWN, e.key_repeat)
		}
	case .CHAR:
		input_on_char(e.char_code)
	case .FOCUSED:
		input_on_focus(true)
	case .UNFOCUSED:
		input_on_focus(false)
	}
}

@(private = "file")
sokol_key :: proc(code: sapp.Keycode) -> (key: Key, ok: bool) {
	#partial switch code {
	case .W: return .W, true
	case .A: return .A, true
	case .S: return .S, true
	case .D: return .D, true
	case .LEFT_SHIFT, .RIGHT_SHIFT: return .Shift, true
	case .TAB: return .Tab, true
	case .ENTER, .KP_ENTER: return .Enter, true
	case .BACKSPACE: return .Backspace, true
	case .SPACE: return .Space, true
	case .ESCAPE: return .Escape, true
	case .E: return .E, true
	case .G: return .G, true
	case .Z: return .Z, true
	case .X: return .X, true
	case .C: return .C, true
	case ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9:
		return Key(int(Key.Num_1) + int(code) - int(sapp.Keycode._1)), true
	}
	return {}, false
}
