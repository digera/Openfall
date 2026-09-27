package main

// Vulkan device, swapchain and frame pacing for the Vulkan backend.
//
// Targets Vulkan 1.1 with classic render passes rather than dynamic
// rendering: that is what every mobile driver supports, it tells a tiled GPU
// the most about what each attachment needs, and it is what multiview and
// fragment density maps attach to. Frames in flight each own their command
// buffer, fence, per-frame buffers and a pair of GPU timestamps around the
// frame's work.

import "base:runtime"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

VK_FRAMES :: 2

// Validation layers on in debug builds, when the loader has them.
VK_VALIDATION :: #config(OPENFALL_VK_VALIDATION, ODIN_DEBUG)

// A buffer in host-visible, coherent memory, mapped for its whole life. The
// per-frame data is a few kilobytes, so there is no staging copy to a
// device-local buffer.
Vk_Buffer :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	mapped: rawptr,
	size:   int,
}

Vk_Frame :: struct {
	cmd_pool:    vk.CommandPool,
	cmd:         vk.CommandBuffer,
	fence:       vk.Fence,
	image_ready: vk.Semaphore,
	timed:       bool,   // its timestamps were written and can be read back
}

Vk_Device :: struct {
	instance:        vk.Instance,
	messenger:       vk.DebugUtilsMessengerEXT,
	surface:         vk.SurfaceKHR,
	physical:        vk.PhysicalDevice,
	device:          vk.Device,
	queue:           vk.Queue,
	queue_family:    u32,
	memory_props:    vk.PhysicalDeviceMemoryProperties,

	render_pass:     vk.RenderPass,
	swapchain:       vk.SwapchainKHR,
	format:          vk.Format,
	extent:          vk.Extent2D,
	images:          [dynamic]vk.Image,
	views:           [dynamic]vk.ImageView,
	framebuffers:    [dynamic]vk.Framebuffer,
	render_done:     [dynamic]vk.Semaphore,   // one per swapchain image

	frames:          [VK_FRAMES]Vk_Frame,
	frame_index:     int,
	image_index:     u32,

	query_pool:      vk.QueryPool,
	timestamp_ns:    f32,    // nanoseconds per timestamp tick; 0 if the queue cannot time
	gpu_ms:          f32,    // GPU time of the most recent frame that has finished
}

@(private = "file")
vk_check :: proc(r: vk.Result, what: string, loc := #caller_location) -> bool {
	if r != .SUCCESS {
		fmt.eprintfln("[Vulkan] %s failed: %v (%v)", what, r, loc)
		return false
	}
	return true
}

@(private = "file")
vk_debug_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	types: vk.DebugUtilsMessageTypeFlagsEXT,
	data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user: rawptr,
) -> b32 {
	context = runtime.default_context()
	fmt.eprintln("[Vulkan]", data.pMessage)
	return false
}

vk_init :: proc(d: ^Vk_Device, window: ^sdl.Window) -> bool {
	vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))
	if vk.CreateInstance == nil {
		fmt.eprintln("[Vulkan] no Vulkan loader")
		return false
	}

	// --- Instance -----------------------------------------------------------
	ext_count: u32
	sdl_exts := sdl.Vulkan_GetInstanceExtensions(&ext_count)
	extensions := make([dynamic]cstring, context.temp_allocator)
	for i in 0 ..< ext_count {
		append(&extensions, sdl_exts[i])
	}
	layers := make([dynamic]cstring, context.temp_allocator)
	when VK_VALIDATION {
		if vk_has_layer("VK_LAYER_KHRONOS_validation") {
			append(&layers, "VK_LAYER_KHRONOS_validation")
			append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		} else {
			fmt.println("[Vulkan] validation layer not installed; running without it")
		}
	}

	app_info := vk.ApplicationInfo{
		sType            = .APPLICATION_INFO,
		pApplicationName = "Openfall",
		pEngineName      = "Openfall",
		apiVersion       = vk.API_VERSION_1_1,
	}
	if !vk_check(vk.CreateInstance(&vk.InstanceCreateInfo{
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
	}, nil, &d.instance), "vkCreateInstance") {
		return false
	}
	vk.load_proc_addresses_instance(d.instance)

	if len(layers) > 0 {
		_ = vk_check(vk.CreateDebugUtilsMessengerEXT(d.instance, &vk.DebugUtilsMessengerCreateInfoEXT{
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.WARNING, .ERROR},
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = vk_debug_callback,
		}, nil, &d.messenger), "vkCreateDebugUtilsMessengerEXT")
	}

	if !sdl.Vulkan_CreateSurface(window, d.instance, nil, &d.surface) {
		fmt.eprintln("[Vulkan] SDL_Vulkan_CreateSurface failed:", sdl.GetError())
		return false
	}

	// --- Physical device and queue -------------------------------------------
	if !vk_pick_device(d) {
		fmt.eprintln("[Vulkan] no device with a graphics queue that can present to the window")
		return false
	}
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(d.physical, &props)
	vk.GetPhysicalDeviceMemoryProperties(d.physical, &d.memory_props)
	fmt.printfln("[Vulkan] %s, Vulkan %d.%d.%d", cstring(&props.deviceName[0]),
		props.apiVersion >> 22, (props.apiVersion >> 12) & 0x3FF, props.apiVersion & 0xFFF)

	// --- Device -------------------------------------------------------------
	priority: f32 = 1
	device_exts := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
	if !vk_check(vk.CreateDevice(d.physical, &vk.DeviceCreateInfo{
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &vk.DeviceQueueCreateInfo{
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = d.queue_family,
			queueCount       = 1,
			pQueuePriorities = &priority,
		},
		enabledExtensionCount   = len(device_exts),
		ppEnabledExtensionNames = &device_exts[0],
	}, nil, &d.device), "vkCreateDevice") {
		return false
	}
	vk.load_proc_addresses_device(d.device)
	vk.GetDeviceQueue(d.device, d.queue_family, 0, &d.queue)

	// --- Timestamps ---------------------------------------------------------
	families := vk_queue_families(d.physical)
	if props.limits.timestampComputeAndGraphics && families[d.queue_family].timestampValidBits > 0 {
		d.timestamp_ns = props.limits.timestampPeriod
		_ = vk_check(vk.CreateQueryPool(d.device, &vk.QueryPoolCreateInfo{
			sType      = .QUERY_POOL_CREATE_INFO,
			queryType  = .TIMESTAMP,
			queryCount = 2 * VK_FRAMES,
		}, nil, &d.query_pool), "vkCreateQueryPool")
	} else {
		fmt.println("[Vulkan] queue has no timestamps; GPU time will not be shown")
	}

	// --- Swapchain and per-frame objects -------------------------------------
	d.format = vk_pick_format(d)
	if !vk_create_render_pass(d) {
		return false
	}
	w, h := platform_pixel_size()
	if !vk_create_swapchain(d, u32(w), u32(h)) {
		return false
	}
	for &f in d.frames {
		if !vk_check(vk.CreateCommandPool(d.device, &vk.CommandPoolCreateInfo{
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.TRANSIENT},
			queueFamilyIndex = d.queue_family,
		}, nil, &f.cmd_pool), "vkCreateCommandPool") {
			return false
		}
		if !vk_check(vk.AllocateCommandBuffers(d.device, &vk.CommandBufferAllocateInfo{
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = f.cmd_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}, &f.cmd), "vkAllocateCommandBuffers") {
			return false
		}
		if !vk_check(vk.CreateFence(d.device, &vk.FenceCreateInfo{
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}, nil, &f.fence), "vkCreateFence") {
			return false
		}
		if !vk_check(vk.CreateSemaphore(d.device, &vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}, nil, &f.image_ready), "vkCreateSemaphore") {
			return false
		}
	}
	return true
}

vk_shutdown :: proc(d: ^Vk_Device) {
	if d.device != nil {
		vk.DeviceWaitIdle(d.device)
		for &f in d.frames {
			vk.DestroySemaphore(d.device, f.image_ready, nil)
			vk.DestroyFence(d.device, f.fence, nil)
			vk.DestroyCommandPool(d.device, f.cmd_pool, nil)
		}
		vk_destroy_swapchain(d)
		vk.DestroySwapchainKHR(d.device, d.swapchain, nil)
		vk.DestroyRenderPass(d.device, d.render_pass, nil)
		vk.DestroyQueryPool(d.device, d.query_pool, nil)
		vk.DestroyDevice(d.device, nil)
	}
	if d.instance != nil {
		vk.DestroySurfaceKHR(d.instance, d.surface, nil)
		if d.messenger != 0 {
			vk.DestroyDebugUtilsMessengerEXT(d.instance, d.messenger, nil)
		}
		vk.DestroyInstance(d.instance, nil)
	}
	delete(d.images)
	delete(d.views)
	delete(d.framebuffers)
	delete(d.render_done)
	d^ = {}
}

// Wait for this frame slot's previous use, read back its GPU time, acquire a
// swapchain image and open the frame's render pass, cleared. Returns false
// when there is nothing to draw into this frame (minimized, or the swapchain
// had to be rebuilt).
vk_begin_frame :: proc(d: ^Vk_Device, clear: [4]f32) -> (cmd: vk.CommandBuffer, ok: bool) {
	w, h := platform_pixel_size()
	if w <= 0 || h <= 0 {
		return nil, false
	}
	if u32(w) != d.extent.width || u32(h) != d.extent.height {
		if !vk_recreate_swapchain(d, u32(w), u32(h)) {
			return nil, false
		}
	}

	f := &d.frames[d.frame_index]
	vk.WaitForFences(d.device, 1, &f.fence, true, max(u64))
	if f.timed {
		ticks: [2]u64
		if vk.GetQueryPoolResults(d.device, d.query_pool, u32(2 * d.frame_index), 2, size_of(ticks), &ticks, size_of(u64), {._64}) == .SUCCESS {
			d.gpu_ms = f32(ticks[1] - ticks[0]) * d.timestamp_ns / 1e6
		}
		f.timed = false
	}

	#partial switch r := vk.AcquireNextImageKHR(d.device, d.swapchain, max(u64), f.image_ready, 0, &d.image_index); r {
	case .SUCCESS, .SUBOPTIMAL_KHR:
	case .ERROR_OUT_OF_DATE_KHR:
		vk_recreate_swapchain(d, u32(w), u32(h))
		return nil, false
	case:
		vk_check(r, "vkAcquireNextImageKHR")
		return nil, false
	}
	vk.ResetFences(d.device, 1, &f.fence)
	vk.ResetCommandPool(d.device, f.cmd_pool, {})

	cmd = f.cmd
	vk.BeginCommandBuffer(cmd, &vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	})
	if d.query_pool != 0 {
		vk.CmdResetQueryPool(cmd, d.query_pool, u32(2 * d.frame_index), 2)
		vk.CmdWriteTimestamp(cmd, {.TOP_OF_PIPE}, d.query_pool, u32(2 * d.frame_index))
	}

	clear_value := vk.ClearValue{color = {float32 = clear}}
	vk.CmdBeginRenderPass(cmd, &vk.RenderPassBeginInfo{
		sType           = .RENDER_PASS_BEGIN_INFO,
		renderPass      = d.render_pass,
		framebuffer     = d.framebuffers[d.image_index],
		renderArea      = {extent = d.extent},
		clearValueCount = 1,
		pClearValues    = &clear_value,
	}, .INLINE)
	vk.CmdSetViewport(cmd, 0, 1, &vk.Viewport{
		width    = f32(d.extent.width),
		height   = f32(d.extent.height),
		maxDepth = 1,
	})
	vk.CmdSetScissor(cmd, 0, 1, &vk.Rect2D{extent = d.extent})
	return cmd, true
}

// Close the render pass, submit and present.
vk_end_frame :: proc(d: ^Vk_Device) {
	f := &d.frames[d.frame_index]
	cmd := f.cmd
	vk.CmdEndRenderPass(cmd)
	if d.query_pool != 0 {
		vk.CmdWriteTimestamp(cmd, {.BOTTOM_OF_PIPE}, d.query_pool, u32(2 * d.frame_index + 1))
		f.timed = true
	}
	vk.EndCommandBuffer(cmd)

	wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	render_done := d.render_done[d.image_index]
	vk_check(vk.QueueSubmit(d.queue, 1, &vk.SubmitInfo{
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &f.image_ready,
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &cmd,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &render_done,
	}, f.fence), "vkQueueSubmit")

	r := vk.QueuePresentKHR(d.queue, &vk.PresentInfoKHR{
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &render_done,
		swapchainCount     = 1,
		pSwapchains        = &d.swapchain,
		pImageIndices      = &d.image_index,
	})
	if r == .ERROR_OUT_OF_DATE_KHR || r == .SUBOPTIMAL_KHR {
		w, h := platform_pixel_size()
		vk_recreate_swapchain(d, u32(w), u32(h))
	} else if r != .SUCCESS {
		vk_check(r, "vkQueuePresentKHR")
	}
	d.frame_index = (d.frame_index + 1) % VK_FRAMES
}

vk_buffer_create :: proc(d: ^Vk_Device, size: int, usage: vk.BufferUsageFlags) -> (b: Vk_Buffer, ok: bool) {
	b.size = size
	if !vk_check(vk.CreateBuffer(d.device, &vk.BufferCreateInfo{
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size),
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}, nil, &b.buffer), "vkCreateBuffer") {
		return
	}
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(d.device, b.buffer, &req)
	type_index, found := vk_memory_type(d, req.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT})
	if !found {
		fmt.eprintln("[Vulkan] no host-visible coherent memory")
		return
	}
	if !vk_check(vk.AllocateMemory(d.device, &vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = type_index,
	}, nil, &b.memory), "vkAllocateMemory") {
		return
	}
	vk.BindBufferMemory(d.device, b.buffer, b.memory, 0)
	if !vk_check(vk.MapMemory(d.device, b.memory, 0, vk.DeviceSize(size), {}, &b.mapped), "vkMapMemory") {
		return
	}
	return b, true
}

vk_buffer_destroy :: proc(d: ^Vk_Device, b: ^Vk_Buffer) {
	if b.buffer != 0 {
		vk.DestroyBuffer(d.device, b.buffer, nil)
	}
	if b.memory != 0 {
		vk.FreeMemory(d.device, b.memory, nil)
	}
	b^ = {}
}

vk_shader_module :: proc(d: ^Vk_Device, code: []u32) -> (m: vk.ShaderModule) {
	vk_check(vk.CreateShaderModule(d.device, &vk.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code) * size_of(u32),
		pCode    = raw_data(code),
	}, nil, &m), "vkCreateShaderModule")
	return
}

// ---------------------------------------------------------------------------

@(private = "file")
vk_has_layer :: proc(name: string) -> bool {
	count: u32
	vk.EnumerateInstanceLayerProperties(&count, nil)
	props := make([]vk.LayerProperties, count, context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&count, raw_data(props))
	for &p in props {
		if strings.truncate_to_byte(string(p.layerName[:]), 0) == name {
			return true
		}
	}
	return false
}

@(private = "file")
vk_queue_families :: proc(physical: vk.PhysicalDevice) -> []vk.QueueFamilyProperties {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(physical, &count, nil)
	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(physical, &count, raw_data(families))
	return families
}

// The first device that can draw and present, preferring a discrete GPU.
@(private = "file")
vk_pick_device :: proc(d: ^Vk_Device) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(d.instance, &count, nil)
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(d.instance, &count, raw_data(devices))

	best_score := -1
	for physical in devices {
		if !vk_has_swapchain(physical) {
			continue
		}
		for fam, i in vk_queue_families(physical) {
			present: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(physical, u32(i), d.surface, &present)
			if .GRAPHICS not_in fam.queueFlags || !present {
				continue
			}
			props: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(physical, &props)
			score := 1
			#partial switch props.deviceType {
			case .DISCRETE_GPU: score = 3
			case .INTEGRATED_GPU: score = 2
			}
			if score > best_score {
				best_score = score
				d.physical = physical
				d.queue_family = u32(i)
			}
			break
		}
	}
	return best_score >= 0
}

@(private = "file")
vk_has_swapchain :: proc(physical: vk.PhysicalDevice) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(physical, nil, &count, nil)
	exts := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(physical, nil, &count, raw_data(exts))
	for &e in exts {
		if strings.truncate_to_byte(string(e.extensionName[:]), 0) == vk.KHR_SWAPCHAIN_EXTENSION_NAME {
			return true
		}
	}
	return false
}

// A plain UNORM format: the shaders tonemap and write display-ready colour,
// as they did on the GL path, so the swapchain must not encode it again.
@(private = "file")
vk_pick_format :: proc(d: ^Vk_Device) -> vk.Format {
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(d.physical, d.surface, &count, nil)
	formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(d.physical, d.surface, &count, raw_data(formats))
	for f in formats {
		if (f.format == .B8G8R8A8_UNORM || f.format == .R8G8B8A8_UNORM) && f.colorSpace == .SRGB_NONLINEAR {
			return f.format
		}
	}
	return formats[0].format
}

@(private = "file")
vk_memory_type :: proc(d: ^Vk_Device, bits: u32, want: vk.MemoryPropertyFlags) -> (u32, bool) {
	for i in 0 ..< d.memory_props.memoryTypeCount {
		if bits & (1 << i) != 0 && d.memory_props.memoryTypes[i].propertyFlags >= want {
			return i, true
		}
	}
	return 0, false
}

// One colour attachment, cleared on load and stored for present. On a tiled
// GPU the whole frame lives in tile memory and is written out once.
@(private = "file")
vk_create_render_pass :: proc(d: ^Vk_Device) -> bool {
	color := vk.AttachmentDescription{
		format         = d.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}
	color_ref := vk.AttachmentReference{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL}
	// The acquire semaphore is waited at colour output, so the layout change
	// out of UNDEFINED has to wait there too.
	dependency := vk.SubpassDependency{
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	return vk_check(vk.CreateRenderPass(d.device, &vk.RenderPassCreateInfo{
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color,
		subpassCount    = 1,
		pSubpasses      = &vk.SubpassDescription{
			pipelineBindPoint    = .GRAPHICS,
			colorAttachmentCount = 1,
			pColorAttachments    = &color_ref,
		},
		dependencyCount = 1,
		pDependencies   = &dependency,
	}, nil, &d.render_pass), "vkCreateRenderPass")
}

@(private = "file")
vk_create_swapchain :: proc(d: ^Vk_Device, width, height: u32) -> bool {
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(d.physical, d.surface, &caps)
	extent := caps.currentExtent
	if extent.width == max(u32) {
		extent = {
			clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
			clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
		}
	}
	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 {
		image_count = min(image_count, caps.maxImageCount)
	}

	old := d.swapchain
	// FIFO is vsync, and the one mode every implementation has.
	if !vk_check(vk.CreateSwapchainKHR(d.device, &vk.SwapchainCreateInfoKHR{
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = d.surface,
		minImageCount    = image_count,
		imageFormat      = d.format,
		imageColorSpace  = .SRGB_NONLINEAR,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .FIFO,
		clipped          = true,
		oldSwapchain     = old,
	}, nil, &d.swapchain), "vkCreateSwapchainKHR") {
		return false
	}
	if old != 0 {
		vk.DestroySwapchainKHR(d.device, old, nil)
	}
	d.extent = extent

	count: u32
	vk.GetSwapchainImagesKHR(d.device, d.swapchain, &count, nil)
	resize(&d.images, int(count))
	vk.GetSwapchainImagesKHR(d.device, d.swapchain, &count, raw_data(d.images))
	resize(&d.views, int(count))
	resize(&d.framebuffers, int(count))
	resize(&d.render_done, int(count))
	for i in 0 ..< int(count) {
		if !vk_check(vk.CreateImageView(d.device, &vk.ImageViewCreateInfo{
			sType            = .IMAGE_VIEW_CREATE_INFO,
			image            = d.images[i],
			viewType         = .D2,
			format           = d.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}, nil, &d.views[i]), "vkCreateImageView") {
			return false
		}
		if !vk_check(vk.CreateFramebuffer(d.device, &vk.FramebufferCreateInfo{
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = d.render_pass,
			attachmentCount = 1,
			pAttachments    = &d.views[i],
			width           = extent.width,
			height          = extent.height,
			layers          = 1,
		}, nil, &d.framebuffers[i]), "vkCreateFramebuffer") {
			return false
		}
		if !vk_check(vk.CreateSemaphore(d.device, &vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}, nil, &d.render_done[i]), "vkCreateSemaphore") {
			return false
		}
	}
	return true
}

// Everything that belongs to the swapchain's images, but not the swapchain
// itself, which the next one is created from.
@(private = "file")
vk_destroy_swapchain :: proc(d: ^Vk_Device) {
	for fb in d.framebuffers {
		vk.DestroyFramebuffer(d.device, fb, nil)
	}
	for v in d.views {
		vk.DestroyImageView(d.device, v, nil)
	}
	for s in d.render_done {
		vk.DestroySemaphore(d.device, s, nil)
	}
	clear(&d.framebuffers)
	clear(&d.views)
	clear(&d.render_done)
	clear(&d.images)
}

@(private = "file")
vk_recreate_swapchain :: proc(d: ^Vk_Device, width, height: u32) -> bool {
	if width == 0 || height == 0 {
		return false
	}
	vk.DeviceWaitIdle(d.device)
	vk_destroy_swapchain(d)
	return vk_create_swapchain(d, width, height)
}
