package main

// Sokol renderer: uploads the frame's Render_Scene to the fullscreen analytic
// ray tracer (shaders/scene.glsl) and draws the HUD with sokol_debugtext.
// Everything it draws is decided in src/client (render_scene.odin, hud.odin).

import "core:fmt"
import "core:time"
import sapp "sokol:app"
import sdtx "sokol:debugtext"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

SDTX_ORIGIN_CELLS :: f32(1)
SDTX_CHAR_PX      :: f32(8)
SDTX_CANVAS_SCALE :: f32(0.5)

Client_Renderer :: struct {
	pip:         sg.Pipeline,
	bind:        sg.Bindings,
	pass_action: sg.Pass_Action,
	scene:       Render_Scene,
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

	verts := [?]f32{-1, -1, 3, -1, -1, 3}
	r.bind.vertex_buffers[0] = sg.make_buffer({
		data = {ptr = &verts, size = size_of(verts)},
	})

	r.pip = sg.make_pipeline({
		shader = sg.make_shader(scene_shader_desc(sg.query_backend())),
		layout = {attrs = {ATTR_scene_position = {format = .FLOAT2}}},
		depth = {write_enabled = false, compare = .ALWAYS},
		label = "scene",
	})

	r.pass_action = {
		colors = {0 = {load_action = .CLEAR, clear_value = {0.02, 0.02, 0.04, 1}}},
	}

	fmt.println("[Renderer] Sokol ready, backend:", sg.query_backend())
}

client_renderer_shutdown :: proc(r: ^Client_Renderer) {
	sdtx.shutdown()
	sg.shutdown()
}

client_renderer_draw :: proc(r: ^Client_Renderer, gc: ^Game_Client) {
	t0 := time.tick_now()
	scene := &r.scene
	render_scene_build(scene, &gc.scene, gc, sapp.widthf() / sapp.heightf())

	// The HUD is laid out before the pass and drawn inside it.
	cols, rows := hud_begin()
	client_hud_draw(gc, cols, rows)

	v := &scene.view
	vs_params := Vs_Params{
		cam_pos     = v.eye,
		half_w      = v.half_w,
		cam_right   = v.right,
		half_h      = v.half_h,
		cam_up      = v.up,
		cam_forward = v.forward,
	}
	fs_params := scene_uniforms(scene)

	sg.begin_pass({action = r.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(r.pip)
	sg.apply_bindings(r.bind)
	sg.apply_uniforms(UB_vs_params, {ptr = &vs_params, size = size_of(vs_params)})
	sg.apply_uniforms(UB_fs_params, {ptr = &fs_params, size = size_of(fs_params)})
	sg.draw(0, 3, 1)
	sdtx.draw()
	sg.end_pass()
	sg.commit()

	frame_ms := f32(time.duration_milliseconds(time.tick_since(t0)))
	frame_stats_update(&gc.frame_stats, scene, gc, frame_ms, int(sapp.width()), int(sapp.height()))
}

// The shader's uniform block is the scene's records verbatim; a size that
// drifts between the two is a compile error here.
@(private = "file")
scene_uniforms :: proc(s: ^Render_Scene) -> (u: Fs_Params) {
	u.cam_data = s.cam_data
	u.fx = s.fx
	u.fx2 = s.fx2
	u.hand_pos = s.hand_pos
	u.hand_cast = s.hand_cast
	u.floor_boxes = s.floor_boxes
	u.solid_boxes = s.solid_boxes
	u.pylons = s.pylons
	u.pylon_shape = s.pylon_shape
	u.pylon_bound = s.pylon_bound
	u.pylon_node_meta = s.pylon_node_meta
	u.pylon_collapse = s.pylon_collapse
	u.pylon_laid = s.pylon_laid
	u.pylon_wounds = s.pylon_wounds
	u.chunks = s.chunks
	u.chunk_fx = s.chunk_fx
	u.minions = s.minions
	u.minion_fx = s.minion_fx
	u.projectiles = s.projectiles
	u.proj_vel = s.proj_vel
	u.wisps = s.wisps
	u.wisp_cast = s.wisp_cast
	u.wisp_aim = s.wisp_aim
	u.robes = s.robes
	u.robe_waists = s.robe_waists
	u.robe_fx = s.robe_fx
	u.impacts = s.impacts
	u.lightning = s.lightning
	u.beams = s.beams
	u.beam_ends = s.beam_ends
	u.beam_chains = s.beam_chains
	u.target_mark = s.target_mark
	u.pads = s.pads
	return
}

// ---------------------------------------------------------------------------
// HUD text, on sokol_debugtext's character grid (see src/client/hud.odin)

@(private = "file")
hud_begin :: proc() -> (cols, rows: f32) {
	w := sapp.widthf() * SDTX_CANVAS_SCALE
	h := sapp.heightf() * SDTX_CANVAS_SCALE
	sdtx.canvas(w, h)
	sdtx.origin(SDTX_ORIGIN_CELLS, SDTX_ORIGIN_CELLS)
	sdtx.home()
	sdtx.font(0)
	return w / SDTX_CHAR_PX - 2 * SDTX_ORIGIN_CELLS, h / SDTX_CHAR_PX - 2 * SDTX_ORIGIN_CELLS
}

hud_pos :: proc(col, row: f32) {
	sdtx.pos(col, row)
}

hud_color3f :: proc(r, g, b: f32) {
	sdtx.color3f(r, g, b)
}

hud_puts :: proc(text: string) {
	sdtx.putr(cstring(raw_data(text)), len(text))
}

hud_putc :: proc(c: u8) {
	sdtx.putc(c)
}
