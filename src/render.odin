package main

import "core:fmt"
import "core:time"
import sapp "sokol:app"
import sdtx "sokol:debugtext"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

Renderer :: struct {
	pip:          sg.Pipeline,
	bind:         sg.Bindings,
	pass_action:  sg.Pass_Action,
	player:       Player,
	camera:       Camera,
	impacts:      [IMPACT_CAP]Impact,
	world_t:      f32,
	fps_accum:    f64,
	fps_presents: int,
	last_fps:     f32,
	frame_ms:     f32,
	sim_acc:      f32,
}

SDTX_ORIGIN_CELLS :: f32(1)
SDTX_CHAR_PX :: f32(8)
SDTX_CANVAS_SCALE :: f32(0.5)

renderer: Renderer

renderer_init :: proc() {
	sg.setup({
		environment = sglue.environment(),
		logger = {func = slog.func},
	})
	sdtx.setup({
		fonts = {0 = sdtx.font_c64()},
		logger = {func = slog.func},
	})

	renderer.player = player_spawn()
	renderer.camera = camera_from_player(renderer.player, sapp.widthf() / sapp.heightf())

	verts := [?]f32{-1, -1, 3, -1, -1, 3}
	renderer.bind.vertex_buffers[0] = sg.make_buffer({
		data = {ptr = &verts, size = size_of(verts)},
	})

	renderer.pip = sg.make_pipeline({
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
	renderer.pass_action = {
		colors = {
			0 = {load_action = .CLEAR, clear_value = {0.03, 0.032, 0.04, 1}},
		},
	}

	fmt.println("Odin FPS — empty room, a guy, a gun")
	fmt.println("  backend:", sg.query_backend())
	fmt.println("  click to lock  WASD walk  Space jump  LMB fire")
}

renderer_shutdown :: proc() {
	sg.shutdown()
}

renderer_overlay :: proc() {
	w := sapp.widthf() * SDTX_CANVAS_SCALE
	h := sapp.heightf() * SDTX_CANVAS_SCALE
	sdtx.canvas(w, h)
	sdtx.origin(SDTX_ORIGIN_CELLS, SDTX_ORIGIN_CELLS)
	sdtx.home()
	sdtx.font(0)
	sdtx.color3f(0.82, 0.80, 0.72)
	sdtx.printf("ODIN FPS  %.0f fps  %.1f ms\n", renderer.last_fps, renderer.frame_ms)
	sdtx.color3f(0.55, 0.52, 0.48)
	sdtx.printf("shots %d   click lock  WASD  Space  LMB\n", renderer.player.shots)

	col := w / SDTX_CHAR_PX * 0.5 - SDTX_ORIGIN_CELLS
	row := h / SDTX_CHAR_PX * 0.5 - SDTX_ORIGIN_CELLS
	if renderer.player.flash > 0.15 {
		sdtx.color3f(1.0, 0.86, 0.40)
	} else {
		sdtx.color3f(0.72, 0.70, 0.64)
	}
	sdtx.pos(col, row)
	sdtx.puts("+")
}

renderer_impact_vec :: proc(i: int) -> vec4 {
	im := renderer.impacts[i]
	if !im.live {
		return {}
	}
	return {im.pos.x, im.pos.y, im.pos.z, im.age}
}

renderer_draw :: proc() {
	basis := camera_basis(renderer.camera, sapp.widthf() / sapp.heightf())
	vs_params := Vs_Params {
		cam_pos     = basis.pos,
		half_w      = basis.half_w,
		cam_right   = basis.right,
		half_h      = basis.half_h,
		cam_up      = basis.up,
		cam_forward = basis.forward,
	}

	grip, muzzle, gr, gu := camera_gun_pose(
		renderer.camera,
		renderer.player.kick,
		renderer.player.hold_t,
	)

	fs_params := Fs_Params {
		room_min   = ROOM_MIN,
		world_t    = renderer.world_t,
		room_max   = ROOM_MAX,
		flash      = renderer.player.flash,
		lamp_pos   = basis.pos,
		kick       = renderer.player.kick,
		gun_grip   = grip,
		gun_on     = 1,
		gun_muzzle = muzzle,
		gun_right  = gr,
		gun_up     = gu,
		impact0    = renderer_impact_vec(0),
		impact1    = renderer_impact_vec(1),
		impact2    = renderer_impact_vec(2),
		impact3    = renderer_impact_vec(3),
		impact4    = renderer_impact_vec(4),
		impact5    = renderer_impact_vec(5),
		impact6    = renderer_impact_vec(6),
		impact7    = renderer_impact_vec(7),
	}

	renderer_overlay()
	sg.begin_pass({action = renderer.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(renderer.pip)
	sg.apply_bindings(renderer.bind)
	sg.apply_uniforms(UB_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
	sg.apply_uniforms(UB_fs_params, {ptr = &fs_params, size = size_of(fs_params)})
	sg.draw(0, 3, 1)
	sdtx.draw()
	sg.end_pass()
	sg.commit()
}

renderer_frame :: proc() {
	t0 := time.tick_now()
	max_dt := input.window_focused ? f64(0.05) : f64(0.5)
	dt := min(sapp.frame_duration(), max_dt)

	if !sapp.mouse_locked() {
		if input_consume_click() && input.window_focused {
			sapp.lock_mouse(true)
		}
		_, _ = input_consume_look()
		_ = input_consume_jump()
	} else {
		player_apply_look(&renderer.player)
		renderer.camera = camera_from_player(renderer.player, sapp.widthf() / sapp.heightf())
	}

	renderer.sim_acc += f32(dt)
	for renderer.sim_acc >= FIXED_DT {
		renderer.sim_acc -= FIXED_DT
		if sapp.mouse_locked() {
			player_tick(&renderer.player, renderer.impacts[:], FIXED_DT)
		}
	}
	renderer.world_t += f32(dt)
	renderer.camera = camera_from_player(renderer.player, sapp.widthf() / sapp.heightf())

	renderer_draw()

	renderer.frame_ms = f32(time.duration_milliseconds(time.tick_since(t0)))
	renderer.fps_accum += sapp.frame_duration()
	renderer.fps_presents += 1
	if renderer.fps_accum >= 0.5 {
		renderer.last_fps = f32(renderer.fps_presents) / f32(renderer.fps_accum)
		renderer.fps_accum = 0
		renderer.fps_presents = 0
	}
}
