package main

// Greybox client renderer
// Renders basic geometry, floor, and entity cylinders

import "core:fmt"
import "core:time"
import "core:math"
import sapp "sokol:app"
import sdtx "sokol:debugtext"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

Client_Renderer :: struct {
	pip:          sg.Pipeline,
	bind:         sg.Bindings,
	pass_action:  sg.Pass_Action,
	
	// Stats
	fps_accum:    f64,
	fps_presents: int,
	last_fps:     f32,
	frame_ms:     f32,
}

client_renderer_init :: proc(r: ^Client_Renderer) {
	sg.setup({
		environment = sglue.environment(),
		logger = {func = slog.func},
	})
	sdtx.setup({
		fonts = {0 = sdtx.font_c64()},
		logger = {func = slog.func},
	})
	
	// Full-screen triangle vertices
	verts := [?]f32{-1, -1, 3, -1, -1, 3}
	r.bind.vertex_buffers[0] = sg.make_buffer({
		data = {ptr = &verts, size = size_of(verts)},
	})
	
	r.pip = sg.make_pipeline({
		shader = sg.make_shader(scene_shader_desc(sg.query_backend())),
		layout = {
			attrs = {
				ATTR_scene_position = {format = .FLOAT2},
			},
		},
		depth = {
			write_enabled = false,
			compare       = .ALWAYS,
		},
		label = "scene",
	})
	
	r.pass_action = {
		colors = {
			0 = {load_action = .CLEAR, clear_value = {0.05, 0.06, 0.08, 1}},
		},
	}
	
	fmt.println("[Client Renderer] Initialized (Sokol + raymarched scene)")
}

client_renderer_shutdown :: proc(r: ^Client_Renderer) {
	sg.shutdown()
}

client_renderer_draw :: proc(r: ^Client_Renderer, client_world: ^Client_World) {
	t0 := time.tick_now()
	
	// Get predicted local character state
	local_char := client_world.prediction.predicted_char
	
	// Build camera from predicted state
	aspect := sapp.widthf() / sapp.heightf()
	eye := vec3{local_char.pos.x, local_char.pos.y, local_char.pos.z + PLAYER_EYE_M}
	
	// Camera basis
	fwd := camera_forward(local_char.yaw, local_char.pitch)
	right := camera_right(local_char.yaw)
	up := norm_vec3(cross_vec3(right, fwd))
	
	half_h := math.tan(f32(CAM_FOV_DEG) * math.PI / 360.0)
	half_w := half_h * max(aspect, 0.01)
	
	// Set up shader uniforms
	vs_params := Vs_Params{
		cam_pos     = eye,
		half_w      = half_w,
		cam_right   = right,
		half_h      = half_h,
		cam_up      = up,
		cam_forward = fwd,
	}
	
	// Collect entity positions for rendering
	// Pack remote entities into the shader
	entity_count := 0
	entity_positions: [16]vec4
	
	for i in 0..<MAX_ENTITIES {
		remote := &client_world.remote_entities[i]
		if !remote.active || entity_count >= 16 {
			continue
		}
		
		// Pack position + radius
		entity_positions[entity_count] = vec4{
			remote.display_state.pos.x,
			remote.display_state.pos.y,
			remote.display_state.pos.z + CHARACTER_HEIGHT_M * 0.5,  // Center of cylinder
			CHARACTER_RADIUS_M,
		}
		entity_count += 1
	}
	
	// Build fragment shader params
	fs_params := Fs_Params{
		room_min   = ROOM_MIN,
		world_t    = f32(time.duration_seconds(time.tick_since(time.Tick{}))),
		room_max   = ROOM_MAX,
		flash      = 0,
		lamp_pos   = eye,
		kick       = 0,
		gun_grip   = {},
		gun_on     = 0,  // No gun for now
		gun_muzzle = {},
		gun_right  = {},
		gun_up     = {},
		impact0    = {},
		impact1    = {},
		impact2    = {},
		impact3    = {},
		impact4    = {},
		impact5    = {},
		impact6    = {},
		impact7    = {},
	}
	
	// Draw HUD overlay
	client_renderer_overlay(r, client_world, local_char)
	
	// Render scene
	sg.begin_pass({action = r.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(r.pip)
	sg.apply_bindings(r.bind)
	sg.apply_uniforms(UB_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
	sg.apply_uniforms(UB_fs_params, {ptr = &fs_params, size = size_of(fs_params)})
	sg.draw(0, 3, 1)
	sdtx.draw()
	sg.end_pass()
	sg.commit()
	
	// Update FPS stats
	r.frame_ms = f32(time.duration_milliseconds(time.tick_since(t0)))
	r.fps_accum += sapp.frame_duration()
	r.fps_presents += 1
	if r.fps_accum >= 0.5 {
		r.last_fps = f32(r.fps_presents) / f32(r.fps_accum)
		r.fps_accum = 0
		r.fps_presents = 0
	}
}

client_renderer_overlay :: proc(r: ^Client_Renderer, client_world: ^Client_World, local_char: Character_State) {
	w := sapp.widthf() * SDTX_CANVAS_SCALE
	h := sapp.heightf() * SDTX_CANVAS_SCALE
	sdtx.canvas(w, h)
	sdtx.origin(SDTX_ORIGIN_CELLS, SDTX_ORIGIN_CELLS)
	sdtx.home()
	sdtx.font(0)
	
	// FPS and frame time
	sdtx.color3f(0.82, 0.80, 0.72)
	sdtx.printf("NEXUS ARENA  %.0f fps  %.1f ms\n", r.last_fps, r.frame_ms)
	
	// Prediction stats
	rate, total := client_prediction_stats(&client_world.prediction)
	sdtx.color3f(0.65, 0.62, 0.58)
	sdtx.printf("Predictions: %d  Mispredict: %.1f%%\n", total, rate * 100)
	
	// Network stats
	sent, recv, rtt := network_client_stats(&game_client.network)
	sdtx.printf("Network: %d sent / %d recv  RTT: ~%.0fms\n", sent, recv, rtt)
	
	// Position and state
	sdtx.color3f(0.55, 0.52, 0.48)
	sdtx.printf("Pos: (%.2f, %.2f, %.2f)  ", local_char.pos.x, local_char.pos.y, local_char.pos.z)
	sdtx.printf("Yaw: %.2f  ", local_char.yaw)
	if local_char.on_ground {
		sdtx.puts("GROUND")
	} else {
		sdtx.puts("AIR")
	}
	sdtx.puts("\n")
	
	// Remote entities
	remote_count := 0
	for i in 0..<MAX_ENTITIES {
		if client_world.remote_entities[i].active {
			remote_count += 1
		}
	}
	sdtx.printf("Remote entities: %d\n", remote_count)
	
	// Crosshair
	col := w / SDTX_CHAR_PX * 0.5 - SDTX_ORIGIN_CELLS
	row := h / SDTX_CHAR_PX * 0.5 - SDTX_ORIGIN_CELLS
	sdtx.color3f(0.72, 0.70, 0.64)
	sdtx.pos(col, row)
	sdtx.puts("+")
	
	// Instructions
	sdtx.pos(SDTX_ORIGIN_CELLS, h / SDTX_CHAR_PX - 3 - SDTX_ORIGIN_CELLS)
	sdtx.color3f(0.45, 0.42, 0.38)
	sdtx.puts("Click to lock mouse | WASD move | Space jump | ESC unlock")
}
