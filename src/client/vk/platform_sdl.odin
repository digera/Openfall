package main

// SDL3 platform backend: SDL owns the window and the event loop, and forwards
// them to the client (see the contract at the top of
// src/client/main_client.odin). The GPU side is Vulkan (vk_device.odin).

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

@(private = "file")
Platform :: struct {
	window:        ^sdl.Window,
	running:       bool,
	last_counter:  u64,
	frame_seconds: f64,
	mouse_locked:  bool,
}

@(private = "file")
platform: Platform

platform_run :: proc(title: cstring, width, height: i32) {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("[Platform] SDL_Init failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.Quit()

	platform.window = sdl.CreateWindow(title, width, height, {.VULKAN, .RESIZABLE})
	if platform.window == nil {
		fmt.eprintln("[Platform] SDL_CreateWindow failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyWindow(platform.window)
	// Text arrives as TEXT_INPUT events, which the layout has already turned
	// into characters; the name field reads those rather than key codes.
	_ = sdl.StartTextInput(platform.window)

	client_init()
	platform.running = true
	platform.last_counter = sdl.GetPerformanceCounter()
	for platform.running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			sdl_event(&event)
		}
		now := sdl.GetPerformanceCounter()
		platform.frame_seconds = f64(now - platform.last_counter) / f64(sdl.GetPerformanceFrequency())
		platform.last_counter = now
		client_frame()
	}
	client_cleanup()
}

platform_frame_duration :: proc() -> f64 {
	return platform.frame_seconds
}

platform_mouse_locked :: proc() -> bool {
	return platform.mouse_locked
}

platform_lock_mouse :: proc(lock: bool) {
	if lock == platform.mouse_locked {
		return
	}
	if sdl.SetWindowRelativeMouseMode(platform.window, lock) {
		platform.mouse_locked = lock
	}
}

// The window for the Vulkan side to build its surface on.
platform_sdl_window :: proc() -> ^sdl.Window {
	return platform.window
}

// The drawable size in pixels, which is what the swapchain has to match.
platform_pixel_size :: proc() -> (width, height: i32) {
	_ = sdl.GetWindowSizeInPixels(platform.window, &width, &height)
	return
}

@(private = "file")
sdl_event :: proc(e: ^sdl.Event) {
	#partial switch e.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		platform.running = false
	case .MOUSE_MOTION:
		input_on_mouse_move(e.motion.x, e.motion.y, e.motion.xrel, e.motion.yrel)
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		button: Mouse_Button
		switch e.button.button {
		case sdl.BUTTON_LEFT: button = .Left
		case sdl.BUTTON_RIGHT: button = .Right
		case sdl.BUTTON_MIDDLE: button = .Middle
		case: return
		}
		input_on_mouse_button(button, e.button.down, e.button.x, e.button.y)
	case .KEY_DOWN, .KEY_UP:
		if key, ok := sdl_key(e.key.scancode); ok {
			input_on_key(key, e.key.down, e.key.repeat)
		}
	case .TEXT_INPUT:
		for c in transmute([]u8)string(e.text.text) {
			input_on_char(u32(c))
		}
	case .WINDOW_FOCUS_GAINED:
		input_on_focus(true)
	case .WINDOW_FOCUS_LOST:
		input_on_focus(false)
	}
}

// Physical key positions, so the bindings sit in the same place on every
// layout; typed text comes separately through TEXT_INPUT.
@(private = "file")
sdl_key :: proc(code: sdl.Scancode) -> (key: Key, ok: bool) {
	#partial switch code {
	case .W: return .W, true
	case .A: return .A, true
	case .S: return .S, true
	case .D: return .D, true
	case .LSHIFT, .RSHIFT: return .Shift, true
	case .TAB: return .Tab, true
	case .RETURN, .KP_ENTER: return .Enter, true
	case .BACKSPACE: return .Backspace, true
	case .SPACE: return .Space, true
	case .ESCAPE: return .Escape, true
	case .E: return .E, true
	case .G: return .G, true
	case .Z: return .Z, true
	case .X: return .X, true
	case .C: return .C, true
	case ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9:
		return Key(int(Key.Num_1) + int(code) - int(sdl.Scancode._1)), true
	}
	return {}, false
}
