package main

// Vulkan renderer. For now it draws the scene with the reference ray tracer
// (the fragment stage of shaders/scene.glsl, compiled unchanged), so this
// backend is playable and timed on the GPU from the start; the analytic
// renderer replaces that pass. The HUD is instanced 8x8 glyphs on top.
//
// Everything drawn is decided in src/client (render_scene.odin, hud.odin).

import "core:fmt"
import "core:mem"
import "core:time"
import vk "vendor:vulkan"

HUD_MAX_GLYPHS    :: 8192
HUD_CELL_PX       :: f32(16)   // matches the Sokol backend's 8 px cells at half scale
HUD_ORIGIN_CELLS  :: f32(1)
HUD_TAB_CELLS     :: 4

// The push constants every pipeline reads (shaders/vk/push.glsl).
@(private = "file")
Push :: struct {
	eye_hw:   [4]f32,
	right_hh: [4]f32,
	up:       [4]f32,
	forward:  [4]f32,
	hud:      [4]f32,
}
#assert(size_of(Push) == 80)

// One HUD character (shaders/vk/hud.vert).
@(private = "file")
Hud_Glyph :: struct {
	cell:  [2]f32,
	code:  u32,
	color: u32,
}

@(private = "file")
Frame_Buffers :: struct {
	scene:       Vk_Buffer,   // Scene_Records, binding 1
	glyphs:      Vk_Buffer,   // [HUD_MAX_GLYPHS]Hud_Glyph, binding 0
	descriptors: vk.DescriptorSet,
}

Client_Renderer :: struct {
	dev:             Vk_Device,
	ready:           bool,
	set_layout:      vk.DescriptorSetLayout,
	pipeline_layout: vk.PipelineLayout,
	descriptor_pool: vk.DescriptorPool,
	scene_pipeline:  vk.Pipeline,
	hud_pipeline:    vk.Pipeline,
	font:            Vk_Buffer,   // HUD_FONT_8X8, binding 2
	buffers:         [VK_FRAMES]Frame_Buffers,
	scene:           Render_Scene,
}

SCENE_REF_VERT := #load("spv/scene_ref.vert.spv", []u32)
SCENE_REF_FRAG := #load("spv/scene_ref.frag.spv", []u32)
HUD_VERT       := #load("spv/hud.vert.spv", []u32)
HUD_FRAG       := #load("spv/hud.frag.spv", []u32)

client_renderer_init :: proc(r: ^Client_Renderer) {
	if !vk_init(&r.dev, platform_sdl_window()) || !renderer_create(r) {
		fmt.eprintln("[Renderer] Vulkan setup failed; nothing will be drawn")
		return
	}
	r.ready = true
	fmt.println("[Renderer] Vulkan ready")
}

client_renderer_shutdown :: proc(r: ^Client_Renderer) {
	d := &r.dev
	if d.device != nil {
		vk.DeviceWaitIdle(d.device)
		vk.DestroyPipeline(d.device, r.scene_pipeline, nil)
		vk.DestroyPipeline(d.device, r.hud_pipeline, nil)
		vk.DestroyPipelineLayout(d.device, r.pipeline_layout, nil)
		vk.DestroyDescriptorPool(d.device, r.descriptor_pool, nil)
		vk.DestroyDescriptorSetLayout(d.device, r.set_layout, nil)
		vk_buffer_destroy(d, &r.font)
		for &b in r.buffers {
			vk_buffer_destroy(d, &b.scene)
			vk_buffer_destroy(d, &b.glyphs)
		}
	}
	vk_shutdown(d)
}

client_renderer_draw :: proc(r: ^Client_Renderer, gc: ^Game_Client) {
	if !r.ready {
		return
	}
	w, h := platform_pixel_size()
	if w <= 0 || h <= 0 {
		return
	}
	t0 := time.tick_now()
	scene := &r.scene
	render_scene_build(scene, &gc.scene, gc, f32(w) / f32(h))

	cols, rows := hud_begin(f32(w), f32(h))
	client_hud_draw(gc, cols, rows)

	cmd, ok := vk_begin_frame(&r.dev, {0.02, 0.02, 0.04, 1})
	if !ok {
		return
	}
	// The slot's fence has been waited, so its buffers are free to rewrite.
	fb := &r.buffers[r.dev.frame_index]
	mem.copy(fb.scene.mapped, &scene.records, size_of(Scene_Records))
	glyph_count := hud_state.count
	mem.copy(fb.glyphs.mapped, &hud_state.glyphs, glyph_count * size_of(Hud_Glyph))

	v := &scene.view
	push := Push{
		eye_hw   = {v.eye.x, v.eye.y, v.eye.z, v.half_w},
		right_hh = {v.right.x, v.right.y, v.right.z, v.half_h},
		up       = {v.up.x, v.up.y, v.up.z, 0},
		forward  = {v.forward.x, v.forward.y, v.forward.z, 0},
		hud      = {f32(r.dev.extent.width), f32(r.dev.extent.height), HUD_CELL_PX, 0},
	}
	vk.CmdPushConstants(cmd, r.pipeline_layout, {.VERTEX}, 0, size_of(Push), &push)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, r.pipeline_layout, 0, 1, &fb.descriptors, 0, nil)

	vk.CmdBindPipeline(cmd, .GRAPHICS, r.scene_pipeline)
	vk.CmdDraw(cmd, 3, 1, 0, 0)
	if glyph_count > 0 {
		vk.CmdBindPipeline(cmd, .GRAPHICS, r.hud_pipeline)
		vk.CmdDraw(cmd, 4, u32(glyph_count), 0, 0)
	}
	vk_end_frame(&r.dev)

	gc.frame_stats.gpu_ms = r.dev.gpu_ms
	frame_ms := f32(time.duration_milliseconds(time.tick_since(t0)))
	frame_stats_update(&gc.frame_stats, scene, gc, frame_ms, int(w), int(h))
}

// ---------------------------------------------------------------------------

@(private = "file")
renderer_create :: proc(r: ^Client_Renderer) -> bool {
	d := &r.dev

	bindings := [?]vk.DescriptorSetLayoutBinding{
		{binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX}},
		{binding = 1, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		{binding = 2, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}
	if vk.CreateDescriptorSetLayout(d.device, &vk.DescriptorSetLayoutCreateInfo{
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings    = &bindings[0],
	}, nil, &r.set_layout) != .SUCCESS {
		return false
	}
	if vk.CreatePipelineLayout(d.device, &vk.PipelineLayoutCreateInfo{
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &r.set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &vk.PushConstantRange{stageFlags = {.VERTEX}, size = size_of(Push)},
	}, nil, &r.pipeline_layout) != .SUCCESS {
		return false
	}

	pool_sizes := [?]vk.DescriptorPoolSize{
		{type = .STORAGE_BUFFER, descriptorCount = VK_FRAMES},
		{type = .UNIFORM_BUFFER, descriptorCount = 2 * VK_FRAMES},
	}
	if vk.CreateDescriptorPool(d.device, &vk.DescriptorPoolCreateInfo{
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = VK_FRAMES,
		poolSizeCount = len(pool_sizes),
		pPoolSizes    = &pool_sizes[0],
	}, nil, &r.descriptor_pool) != .SUCCESS {
		return false
	}

	ok: bool
	if r.font, ok = vk_buffer_create(d, size_of(HUD_FONT_8X8), {.UNIFORM_BUFFER}); !ok {
		return false
	}
	mem.copy(r.font.mapped, &HUD_FONT_8X8, size_of(HUD_FONT_8X8))

	for &b in r.buffers {
		if b.scene, ok = vk_buffer_create(d, size_of(Scene_Records), {.UNIFORM_BUFFER}); !ok {
			return false
		}
		if b.glyphs, ok = vk_buffer_create(d, HUD_MAX_GLYPHS * size_of(Hud_Glyph), {.STORAGE_BUFFER}); !ok {
			return false
		}
		if vk.AllocateDescriptorSets(d.device, &vk.DescriptorSetAllocateInfo{
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = r.descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts        = &r.set_layout,
		}, &b.descriptors) != .SUCCESS {
			return false
		}
		infos := [3]vk.DescriptorBufferInfo{
			{buffer = b.glyphs.buffer, range = vk.DeviceSize(b.glyphs.size)},
			{buffer = b.scene.buffer, range = vk.DeviceSize(b.scene.size)},
			{buffer = r.font.buffer, range = vk.DeviceSize(r.font.size)},
		}
		writes: [3]vk.WriteDescriptorSet
		for i in 0 ..< 3 {
			writes[i] = {
				sType           = .WRITE_DESCRIPTOR_SET,
				dstSet          = b.descriptors,
				dstBinding      = u32(i),
				descriptorCount = 1,
				descriptorType  = i == 0 ? .STORAGE_BUFFER : .UNIFORM_BUFFER,
				pBufferInfo     = &infos[i],
			}
		}
		vk.UpdateDescriptorSets(d.device, len(writes), &writes[0], 0, nil)
	}

	r.scene_pipeline = pipeline_create(r, SCENE_REF_VERT, SCENE_REF_FRAG, .TRIANGLE_LIST)
	r.hud_pipeline = pipeline_create(r, HUD_VERT, HUD_FRAG, .TRIANGLE_STRIP)
	return r.scene_pipeline != 0 && r.hud_pipeline != 0
}

// A pipeline with no vertex input, no depth and no blending, drawing into the
// frame's render pass with the viewport set per frame.
@(private = "file")
pipeline_create :: proc(r: ^Client_Renderer, vert, frag: []u32, topology: vk.PrimitiveTopology) -> (p: vk.Pipeline) {
	d := &r.dev
	vs := vk_shader_module(d, vert)
	fs := vk_shader_module(d, frag)
	defer vk.DestroyShaderModule(d.device, vs, nil)
	defer vk.DestroyShaderModule(d.device, fs, nil)

	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vs, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fs, pName = "main"},
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	blend := vk.PipelineColorBlendAttachmentState{colorWriteMask = {.R, .G, .B, .A}}
	if vk.CreateGraphicsPipelines(d.device, 0, 1, &vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(stages),
		pStages             = &stages[0],
		pVertexInputState   = &vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO},
		pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo{
			sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = topology,
		},
		pViewportState      = &vk.PipelineViewportStateCreateInfo{
			sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount  = 1,
		},
		pRasterizationState = &vk.PipelineRasterizationStateCreateInfo{
			sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			cullMode    = {},
			frontFace   = .COUNTER_CLOCKWISE,
			lineWidth   = 1,
		},
		pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo{
			sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		},
		pColorBlendState    = &vk.PipelineColorBlendStateCreateInfo{
			sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = 1,
			pAttachments    = &blend,
		},
		pDynamicState       = &vk.PipelineDynamicStateCreateInfo{
			sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = len(dynamic_states),
			pDynamicStates    = &dynamic_states[0],
		},
		layout              = r.pipeline_layout,
		renderPass          = d.render_pass,
	}, nil, &p) != .SUCCESS {
		fmt.eprintln("[Vulkan] vkCreateGraphicsPipelines failed")
		return 0
	}
	return
}

// ---------------------------------------------------------------------------
// HUD text (see src/client/hud.odin): a cursor on a grid of HUD_CELL_PX
// cells, collecting one glyph per visible character for the frame.

@(private = "file")
Hud_State :: struct {
	cursor: [2]f32,
	color:  u32,
	glyphs: [HUD_MAX_GLYPHS]Hud_Glyph,
	count:  int,
}

@(private = "file")
hud_state: Hud_State

@(private = "file")
hud_begin :: proc(width, height: f32) -> (cols, rows: f32) {
	hud_state.count = 0
	hud_state.cursor = {HUD_ORIGIN_CELLS, HUD_ORIGIN_CELLS}
	hud_state.color = 0xFFFFFFFF
	return width / HUD_CELL_PX - 2 * HUD_ORIGIN_CELLS, height / HUD_CELL_PX - 2 * HUD_ORIGIN_CELLS
}

hud_pos :: proc(col, row: f32) {
	hud_state.cursor = {HUD_ORIGIN_CELLS + col, HUD_ORIGIN_CELLS + row}
}

hud_color3f :: proc(r, g, b: f32) {
	to_u8 :: proc(v: f32) -> u32 {
		return u32(clamp(v, 0, 1) * 255 + 0.5)
	}
	hud_state.color = to_u8(r) | to_u8(g) << 8 | to_u8(b) << 16 | 0xFF << 24
}

hud_puts :: proc(text: string) {
	for i in 0 ..< len(text) {
		hud_putc(text[i])
	}
}

hud_putc :: proc(c: u8) {
	s := &hud_state
	switch c {
	case '\n':
		s.cursor = {HUD_ORIGIN_CELLS, s.cursor.y + 1}
	case '\r':
		s.cursor.x = HUD_ORIGIN_CELLS
	case '\t':
		col := s.cursor.x - HUD_ORIGIN_CELLS
		s.cursor.x = HUD_ORIGIN_CELLS + f32((int(col) / HUD_TAB_CELLS + 1) * HUD_TAB_CELLS)
	case:
		if c != ' ' && s.count < HUD_MAX_GLYPHS {
			s.glyphs[s.count] = {cell = s.cursor, code = u32(c), color = s.color}
			s.count += 1
		}
		s.cursor.x += 1
	}
}
