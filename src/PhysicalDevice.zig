const std = @import("std");
const build_options = @import("build_options");
const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");
const Instance = @import("Instance.zig");
const root = @import("root");
const PhysicalDevice = @This();

const log = @import("log.zig").vk_kickstart_log;

const vkb = dispatch.vkb;
const vki = dispatch.vki;

const InstanceWrapper = dispatch.InstanceWrapper;

const vkk_options = if (@hasDecl(root, "vkk_options")) root.vkk_options else struct {};
const physical_device_override = if (@hasDecl(vkk_options, "physical_device_override")) vkk_options.physical_device_override else struct {};

/// Max number of physical devices.
///
/// Can be overriden in root.
pub const max_handles = if (@hasDecl(physical_device_override, "max_handles"))
    physical_device_override.max_handles
else
    6;

/// Max number of enabled physical device extensions.
///
/// Can be overriden in root.
pub const max_enabled_extensions = if (@hasDecl(physical_device_override, "max_enabled_extensions"))
    physical_device_override.max_enabled_extensions
else
    16;

/// Max number of available physical device extensions.
///
/// Can be overriden in root.
pub const max_available_extensions = if (@hasDecl(physical_device_override, "max_available_extensions"))
    physical_device_override.max_available_extensions
else
    512;

/// Max number of available physical device queue families.
///
/// Can be overriden in root.
pub const max_queue_families = if (@hasDecl(physical_device_override, "max_queue_families"))
    physical_device_override.max_queue_families
else
    16;

/// Max number of unique queues. At this time: graphics, present, compute and transfer.
pub const max_unique_queues = 4;

pub const ExtensionArray = std.BoundedArray([vk.MAX_EXTENSION_NAME_SIZE]u8, max_enabled_extensions);

const PhysicalDeviceHandlesArray = std.BoundedArray(vk.PhysicalDevice, max_handles);
const PhysicalDeviceInfosArray = std.BoundedArray(PhysicalDeviceInfo, max_handles);
const PhysicalDeviceExtensionsArray = std.BoundedArray(vk.ExtensionProperties, max_available_extensions);
const PhysicalDeviceQueueFamiliesArray = std.BoundedArray(vk.QueueFamilyProperties, max_queue_families);

handle: vk.PhysicalDevice,
properties: vk.PhysicalDeviceProperties,
memory_properties: vk.PhysicalDeviceMemoryProperties,
features: vk.PhysicalDeviceFeatures,
features_11: vk.PhysicalDeviceVulkan11Features,
features_12: vk.PhysicalDeviceVulkan12Features,
features_13: vk.PhysicalDeviceVulkan13Features,
extensions: ExtensionArray,
graphics_queue_index: u32,
present_queue_index: u32,
transfer_queue_index: ?u32,
compute_queue_index: ?u32,

pub const QueuePreference = enum {
    /// No queue will be created.
    none,
    /// Dedicated (for transfer -> without compute, for computer -> without transfer).
    /// Both will not be the same family as the graphics queue.
    dedicated,
    /// Separate from graphics family.
    /// This mode will try to find a dedicated, but will fallback to a common for
    /// transfer and compute if no dedicated is found.
    separate,
};

pub const SelectOptions = struct {
    /// Vulkan render surface.
    surface: vk.SurfaceKHR,
    /// Name of the device to select.
    name: ?[*:0]const u8 = null,
    /// Required Vulkan version (minimum 1.1).
    required_api_version: u32 = @bitCast(vk.API_VERSION_1_1),
    /// Prefered physical device type.
    preferred_type: vk.PhysicalDeviceType = .discrete_gpu,
    /// Transfer queue preference.
    transfer_queue: QueuePreference = .none,
    /// Compute queue preference.
    compute_queue: QueuePreference = .none,
    /// Required local memory size.
    required_mem_size: vk.DeviceSize = 0,
    /// Required physical device features.
    required_features: vk.PhysicalDeviceFeatures = .{},
    /// Required physical device feature version 1.1.
    required_features_11: vk.PhysicalDeviceVulkan11Features = .{},
    /// Required physical device feature version 1.2.
    required_features_12: ?vk.PhysicalDeviceVulkan12Features = null,
    /// Required physical device feature version 1.3.
    required_features_13: ?vk.PhysicalDeviceVulkan13Features = null,
    /// Array of required physical device extensions to enable.
    /// Note: VK_KHR_swapchain and VK_KHR_subset (if available) are automatically enabled.
    required_extensions: []const [*:0]const u8 = &.{},
};

const Error = error{
    Overflow,
    Features12UnsupportedByInstance,
    Features13UnsupportedByInstance,
    EnumeratePhysicalDevicesFailed,
    EnumeratePhysicalDeviceExtensionsFailed,
    NoSuitableDeviceFound,
};

pub const SelectError = Error ||
    InstanceWrapper.EnumeratePhysicalDevicesError ||
    InstanceWrapper.EnumerateDeviceExtensionPropertiesError ||
    InstanceWrapper.GetPhysicalDeviceSurfaceSupportKHRError ||
    InstanceWrapper.GetPhysicalDeviceSurfaceFormatsKHRError;

pub fn select(
    instance: vk.Instance,
    options: SelectOptions,
) SelectError!PhysicalDevice {
    std.debug.assert(instance != .null_handle);
    std.debug.assert(options.required_api_version >= @as(u32, @bitCast(vk.API_VERSION_1_1)));
    std.debug.assert(options.surface != .null_handle);

    const physical_device_handles = try getPhysicalDevices(instance);

    const instance_version = try vkb().enumerateInstanceVersion();
    var physical_device_infos = try PhysicalDeviceInfosArray.init(0);
    for (physical_device_handles.constSlice()) |handle| {
        const physical_device_info = try getPhysicalDeviceInfo(handle, options.surface, instance_version);
        try physical_device_infos.append(physical_device_info);
    }

    for (physical_device_infos.slice()) |*info| {
        info.suitable = try isDeviceSuitable(info, options.surface, options);
    }

    if (build_options.verbose) {
        log.debug("----- physical device selection -----", .{});
        log.debug("found {d} physical device{s}", .{
            physical_device_handles.len,
            if (physical_device_handles.len < 2) "" else "s",
        });

        for (physical_device_infos.constSlice()) |info| {
            const device_name: [*:0]const u8 = @ptrCast(&info.properties.device_name);
            log.debug("{s}", .{device_name});

            log.debug(" suitable: {s}", .{if (info.suitable) "yes" else "no"});
            log.debug(" api version: {d}.{d}.{d}", .{
                @as(*const vk.Version, @ptrCast(&info.properties.api_version)).major,
                @as(*const vk.Version, @ptrCast(&info.properties.api_version)).minor,
                @as(*const vk.Version, @ptrCast(&info.properties.api_version)).patch,
            });
            log.debug(" device type: {s}", .{@tagName(info.properties.device_type)});
            const local_memory_size = getLocalMemorySize(&info.memory_properties);
            log.debug(" local memory size: {:.2}", .{std.fmt.fmtIntSizeBin(local_memory_size)});

            log.debug(" queue family count: {d}", .{info.queue_families.len});
            log.debug(" graphics queue family: {s}", .{if (info.graphics_queue_index != null) "yes" else "no"});
            log.debug(" present queue family: {s}", .{if (info.present_queue_index != null) "yes" else "no"});
            log.debug(" dedicated transfer queue family: {s}", .{if (info.dedicated_transfer_queue_index != null) "yes" else "no"});
            log.debug(" dedicated compute queue family: {s}", .{if (info.dedicated_compute_queue_index != null) "yes" else "no"});
            log.debug(" separate transfer queue family: {s}", .{if (info.separate_transfer_queue_index != null) "yes" else "no"});
            log.debug(" separate compute queue family: {s}", .{if (info.separate_compute_queue_index != null) "yes" else "no"});

            log.debug(" portability extension available: {s}", .{if (info.portability_ext_available) "yes" else "no"});

            log.debug(" available extensions:", .{});
            for (info.available_extensions.constSlice()) |ext| {
                const ext_name: [*:0]const u8 = @ptrCast(&ext.extension_name);
                log.debug(" - {s}", .{ext_name});
            }

            log.debug(" available features:", .{});
            printAvailableFeatures(vk.PhysicalDeviceFeatures, info.features);
            log.debug(" available features (vulkan 1.1):", .{});
            printAvailableFeatures(vk.PhysicalDeviceVulkan11Features, info.features_11);
            if (info.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_2))) {
                log.debug(" available features (vulkan 1.2):", .{});
                printAvailableFeatures(vk.PhysicalDeviceVulkan12Features, info.features_12);
            }
            if (info.properties.api_version >= @as(u32, @bitCast(vk.API_VERSION_1_3))) {
                log.debug(" available features (vulkan 1.3):", .{});
                printAvailableFeatures(vk.PhysicalDeviceVulkan13Features, info.features_13);
            }
        }
    }

    std.sort.insertion(PhysicalDeviceInfo, physical_device_infos.slice(), options, comparePhysicalDevices);

    const selected = &physical_device_infos.constSlice()[0];
    if (!selected.suitable) return error.NoSuitableDeviceFound;

    const extension_count = if (selected.portability_ext_available)
        options.required_extensions.len + 2
    else
        options.required_extensions.len + 1;
    std.debug.assert(max_enabled_extensions >= extension_count);

    var extensions = try ExtensionArray.init(0);

    for (options.required_extensions) |ext| {
        try setExtension(&extensions, ext);
    }

    if (selected.portability_ext_available) {
        try setExtension(&extensions, vk.extensions.khr_portability_subset.name);
    }

    try setExtension(&extensions, vk.extensions.khr_swapchain.name);

    if (build_options.verbose) {
        const device_name: [*:0]const u8 = @ptrCast(&selected.properties.device_name);
        log.debug("selected {s}", .{device_name});
    }

    return .{
        .handle = selected.handle,
        .features = options.required_features,
        .features_11 = options.required_features_11,
        .features_12 = if (options.required_features_12) |features| features else .{},
        .features_13 = if (options.required_features_13) |features| features else .{},
        .properties = selected.properties,
        .memory_properties = selected.memory_properties,
        .extensions = extensions,
        .graphics_queue_index = selected.graphics_queue_index.?,
        .present_queue_index = selected.present_queue_index.?,
        .transfer_queue_index = switch (options.transfer_queue) {
            .none => null,
            .dedicated => selected.dedicated_transfer_queue_index,
            .separate => selected.separate_transfer_queue_index,
        },
        .compute_queue_index = switch (options.compute_queue) {
            .none => null,
            .dedicated => selected.dedicated_compute_queue_index,
            .separate => selected.separate_compute_queue_index,
        },
    };
}

/// Returns the physical device's name.
pub fn name(self: *const PhysicalDevice) []const u8 {
    const str: [*:0]const u8 = @ptrCast(&self.properties.device_name);
    return std.mem.span(str);
}

/// Returns an array of the extensions required to be enabled when creating the logical device.
///
/// Buffer is used as the output.
pub fn getExtensions(
    self: *const PhysicalDevice,
    buffer: [][*:0]const u8,
) [][*:0]const u8 {
    std.debug.assert(buffer.len >= self.extensions.len);

    for (0..self.extensions.len) |i| {
        buffer[i] = @ptrCast(&self.extensions.buffer[i]);
    }
    return buffer[0..self.extensions.len];
}

fn printAvailableFeatures(comptime T: type, features: T) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("must be a struct");
    inline for (info.@"struct".fields) |field| {
        if (field.type == vk.Bool32) {
            log.debug(" - {s}: {s}", .{ field.name, if (@field(features, field.name) != 0) "yes" else "no" });
        }
    }
}

const PhysicalDeviceInfo = struct {
    handle: vk.PhysicalDevice,
    features: vk.PhysicalDeviceFeatures,
    features_11: vk.PhysicalDeviceVulkan11Features,
    features_12: vk.PhysicalDeviceVulkan12Features,
    features_13: vk.PhysicalDeviceVulkan13Features,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    available_extensions: PhysicalDeviceExtensionsArray,
    queue_families: PhysicalDeviceQueueFamiliesArray,
    graphics_queue_index: ?u32,
    present_queue_index: ?u32,
    dedicated_transfer_queue_index: ?u32,
    dedicated_compute_queue_index: ?u32,
    separate_transfer_queue_index: ?u32,
    separate_compute_queue_index: ?u32,
    portability_ext_available: bool,
    suitable: bool = true,
};

fn setExtension(buffer: *ExtensionArray, ext: [*:0]const u8) !void {
    const len = std.mem.len(ext) + 1;
    const ptr = try buffer.addOne();
    @memcpy(ptr[0..len], ext[0..len]);
}

fn getPresentQueue(
    handle: vk.PhysicalDevice,
    families: []const vk.QueueFamilyProperties,
    surface: vk.SurfaceKHR,
) !?u32 {
    for (families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const idx: u32 = @intCast(i);

        if (try vki().getPhysicalDeviceSurfaceSupportKHR(handle, idx, surface) == vk.TRUE) {
            return idx;
        }
    }
    return null;
}

fn getQueueStrict(
    families: []const vk.QueueFamilyProperties,
    wanted_flags: vk.QueueFlags,
    unwanted_flags: vk.QueueFlags,
) ?u32 {
    for (families, 0..) |family, i| {
        if (family.queue_count == 0) continue;

        const idx: u32 = @intCast(i);

        const has_wanted = family.queue_flags.contains(wanted_flags);
        const no_unwanted = family.queue_flags.intersect(unwanted_flags).toInt() == vk.QueueFlags.toInt(.{});
        if (has_wanted and no_unwanted) {
            return idx;
        }
    }
    return null;
}

fn getQueueNoGraphics(
    families: []const vk.QueueFamilyProperties,
    wanted_flags: vk.QueueFlags,
    unwanted_flags: vk.QueueFlags,
) ?u32 {
    var index: ?u32 = null;
    for (families, 0..) |family, i| {
        if (family.queue_count == 0 or family.queue_flags.graphics_bit) continue;

        const idx: u32 = @intCast(i);

        const has_wanted = family.queue_flags.contains(wanted_flags);
        const no_unwanted = family.queue_flags.intersect(unwanted_flags).toInt() == vk.QueueFlags.toInt(.{});
        if (has_wanted) {
            if (no_unwanted) return idx;
            if (index == null) index = idx;
        }
    }
    return index;
}

fn comparePhysicalDevices(options: SelectOptions, a: PhysicalDeviceInfo, b: PhysicalDeviceInfo) bool {
    if (a.suitable != b.suitable) {
        return a.suitable;
    }

    const a_is_prefered_type = a.properties.device_type == options.preferred_type;
    const b_is_prefered_type = b.properties.device_type == options.preferred_type;
    if (a_is_prefered_type != b_is_prefered_type) {
        return a_is_prefered_type;
    }

    const local_memory_a = getLocalMemorySize(&a.memory_properties);
    const local_memory_b = getLocalMemorySize(&b.memory_properties);
    if (local_memory_a != local_memory_b) {
        return local_memory_a >= local_memory_b;
    }

    if (a.properties.api_version != b.properties.api_version) {
        return a.properties.api_version >= b.properties.api_version;
    }

    return true;
}

fn getLocalMemorySize(memory_properties: *const vk.PhysicalDeviceMemoryProperties) vk.DeviceSize {
    var size: vk.DeviceSize = 0;
    const heap_count = memory_properties.memory_heap_count;
    for (memory_properties.memory_heaps[0..heap_count]) |heap| {
        if (heap.flags.device_local_bit) {
            // NOTE: take the sum instead to account for small local fast heap?
            size = @max(size, heap.size);
        }
    }

    return size;
}

fn isDeviceSuitable(
    device: *const PhysicalDeviceInfo,
    surface: vk.SurfaceKHR,
    options: SelectOptions,
) !bool {
    if (options.name) |n| {
        const device_name: [*:0]const u8 = @ptrCast(&device.properties.device_name);
        if (std.mem.orderZ(u8, n, device_name) != .eq) return false;
    }

    if (device.properties.api_version < options.required_api_version) return false;

    if (options.transfer_queue == .dedicated and device.dedicated_transfer_queue_index == null) return false;
    if (options.transfer_queue == .separate and device.separate_transfer_queue_index == null) return false;
    if (options.compute_queue == .dedicated and device.dedicated_compute_queue_index == null) return false;
    if (options.compute_queue == .separate and device.separate_compute_queue_index == null) return false;

    if (!supportsRequiredFeatures(device.features, options.required_features)) return false;
    if (!supportsRequiredFeatures11(device.features_11, options.required_features_11)) return false;
    if (!supportsRequiredFeatures12(device.features_12, options.required_features_12)) return false;
    if (!supportsRequiredFeatures13(device.features_13, options.required_features_13)) return false;

    for (options.required_extensions) |ext| {
        if (!isExtensionAvailable(device.available_extensions.constSlice(), ext)) {
            return false;
        }
    }

    if (device.graphics_queue_index == null or device.present_queue_index == null) return false;
    if (!isExtensionAvailable(device.available_extensions.constSlice(), vk.extensions.khr_swapchain.name)) {
        return false;
    }
    if (!try isCompatibleWithSurface(device.handle, surface)) {
        return false;
    }

    const heap_count = device.memory_properties.memory_heap_count;
    for (device.memory_properties.memory_heaps[0..heap_count]) |heap| {
        if (heap.flags.device_local_bit and heap.size >= options.required_mem_size) {
            break;
        }
    } else {
        return false;
    }

    return true;
}

fn supportsRequiredFeatures(available: vk.PhysicalDeviceFeatures, required: vk.PhysicalDeviceFeatures) bool {
    if (required.alpha_to_one == vk.TRUE and available.alpha_to_one == vk.FALSE) return false;
    if (required.depth_bias_clamp == vk.TRUE and available.depth_bias_clamp == vk.FALSE) return false;
    if (required.depth_bounds == vk.TRUE and available.depth_bounds == vk.FALSE) return false;
    if (required.depth_clamp == vk.TRUE and available.depth_clamp == vk.FALSE) return false;
    if (required.draw_indirect_first_instance == vk.TRUE and available.draw_indirect_first_instance == vk.FALSE) return false;
    if (required.dual_src_blend == vk.TRUE and available.dual_src_blend == vk.FALSE) return false;
    if (required.fill_mode_non_solid == vk.TRUE and available.fill_mode_non_solid == vk.FALSE) return false;
    if (required.fragment_stores_and_atomics == vk.TRUE and available.fragment_stores_and_atomics == vk.FALSE) return false;
    if (required.full_draw_index_uint_32 == vk.TRUE and available.full_draw_index_uint_32 == vk.FALSE) return false;
    if (required.geometry_shader == vk.TRUE and available.geometry_shader == vk.FALSE) return false;
    if (required.image_cube_array == vk.TRUE and available.image_cube_array == vk.FALSE) return false;
    if (required.independent_blend == vk.TRUE and available.independent_blend == vk.FALSE) return false;
    if (required.inherited_queries == vk.TRUE and available.inherited_queries == vk.FALSE) return false;
    if (required.large_points == vk.TRUE and available.large_points == vk.FALSE) return false;
    if (required.logic_op == vk.TRUE and available.logic_op == vk.FALSE) return false;
    if (required.multi_draw_indirect == vk.TRUE and available.multi_draw_indirect == vk.FALSE) return false;
    if (required.multi_viewport == vk.TRUE and available.multi_viewport == vk.FALSE) return false;
    if (required.occlusion_query_precise == vk.TRUE and available.occlusion_query_precise == vk.FALSE) return false;
    if (required.pipeline_statistics_query == vk.TRUE and available.pipeline_statistics_query == vk.FALSE) return false;
    if (required.robust_buffer_access == vk.TRUE and available.robust_buffer_access == vk.FALSE) return false;
    if (required.sample_rate_shading == vk.TRUE and available.sample_rate_shading == vk.FALSE) return false;
    if (required.sampler_anisotropy == vk.TRUE and available.sampler_anisotropy == vk.FALSE) return false;
    if (required.shader_clip_distance == vk.TRUE and available.shader_clip_distance == vk.FALSE) return false;
    if (required.shader_cull_distance == vk.TRUE and available.shader_cull_distance == vk.FALSE) return false;
    if (required.shader_float_64 == vk.TRUE and available.shader_float_64 == vk.FALSE) return false;
    if (required.shader_image_gather_extended == vk.TRUE and available.shader_image_gather_extended == vk.FALSE) return false;
    if (required.shader_int_16 == vk.TRUE and available.shader_int_16 == vk.FALSE) return false;
    if (required.shader_int_64 == vk.TRUE and available.shader_int_64 == vk.FALSE) return false;
    if (required.shader_resource_min_lod == vk.TRUE and available.shader_resource_min_lod == vk.FALSE) return false;
    if (required.shader_resource_residency == vk.TRUE and available.shader_resource_residency == vk.FALSE) return false;
    if (required.shader_tessellation_and_geometry_point_size == vk.TRUE and available.shader_tessellation_and_geometry_point_size == vk.FALSE) return false;
    if (required.shader_sampled_image_array_dynamic_indexing == vk.TRUE and available.shader_sampled_image_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_storage_buffer_array_dynamic_indexing == vk.TRUE and available.shader_storage_buffer_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_storage_image_array_dynamic_indexing == vk.TRUE and available.shader_storage_image_array_dynamic_indexing == vk.FALSE) return false;
    if (required.shader_storage_image_extended_formats == vk.TRUE and available.shader_storage_image_extended_formats == vk.FALSE) return false;
    if (required.shader_storage_image_multisample == vk.TRUE and available.shader_storage_image_multisample == vk.FALSE) return false;
    if (required.shader_storage_image_read_without_format == vk.TRUE and available.shader_storage_image_read_without_format == vk.FALSE) return false;
    if (required.shader_storage_image_write_without_format == vk.TRUE and available.shader_storage_image_write_without_format == vk.FALSE) return false;
    if (required.shader_uniform_buffer_array_dynamic_indexing == vk.TRUE and available.shader_uniform_buffer_array_dynamic_indexing == vk.FALSE) return false;
    if (required.sparse_binding == vk.TRUE and available.sparse_binding == vk.FALSE) return false;
    if (required.sparse_residency_2_samples == vk.TRUE and available.sparse_residency_2_samples == vk.FALSE) return false;
    if (required.sparse_residency_4_samples == vk.TRUE and available.sparse_residency_4_samples == vk.FALSE) return false;
    if (required.sparse_residency_8_samples == vk.TRUE and available.sparse_residency_8_samples == vk.FALSE) return false;
    if (required.sparse_residency_16_samples == vk.TRUE and available.sparse_residency_16_samples == vk.FALSE) return false;
    if (required.sparse_residency_aliased == vk.TRUE and available.sparse_residency_aliased == vk.FALSE) return false;
    if (required.sparse_residency_buffer == vk.TRUE and available.sparse_residency_buffer == vk.FALSE) return false;
    if (required.sparse_residency_image_2d == vk.TRUE and available.sparse_residency_image_2d == vk.FALSE) return false;
    if (required.sparse_residency_image_3d == vk.TRUE and available.sparse_residency_image_3d == vk.FALSE) return false;
    if (required.tessellation_shader == vk.TRUE and available.tessellation_shader == vk.FALSE) return false;
    if (required.texture_compression_astc_ldr == vk.TRUE and available.texture_compression_astc_ldr == vk.FALSE) return false;
    if (required.texture_compression_bc == vk.TRUE and available.texture_compression_bc == vk.FALSE) return false;
    if (required.texture_compression_etc2 == vk.TRUE and available.texture_compression_etc2 == vk.FALSE) return false;
    if (required.variable_multisample_rate == vk.TRUE and available.variable_multisample_rate == vk.FALSE) return false;
    if (required.vertex_pipeline_stores_and_atomics == vk.TRUE and available.vertex_pipeline_stores_and_atomics == vk.FALSE) return false;
    if (required.wide_lines == vk.TRUE and available.wide_lines == vk.FALSE) return false;

    return true;
}

fn supportsRequiredFeatures11(available: vk.PhysicalDeviceVulkan11Features, required: vk.PhysicalDeviceVulkan11Features) bool {
    if (required.storage_buffer_16_bit_access == vk.TRUE and available.storage_buffer_16_bit_access == vk.FALSE) return false;
    if (required.uniform_and_storage_buffer_16_bit_access == vk.TRUE and available.uniform_and_storage_buffer_16_bit_access == vk.FALSE) return false;
    if (required.storage_push_constant_16 == vk.TRUE and available.storage_push_constant_16 == vk.FALSE) return false;
    if (required.storage_input_output_16 == vk.TRUE and available.storage_input_output_16 == vk.FALSE) return false;
    if (required.multiview == vk.TRUE and available.multiview == vk.FALSE) return false;
    if (required.multiview_geometry_shader == vk.TRUE and available.multiview_geometry_shader == vk.FALSE) return false;
    if (required.multiview_tessellation_shader == vk.TRUE and available.multiview_tessellation_shader == vk.FALSE) return false;
    if (required.variable_pointers_storage_buffer == vk.TRUE and available.variable_pointers_storage_buffer == vk.FALSE) return false;
    if (required.variable_pointers == vk.TRUE and available.variable_pointers == vk.FALSE) return false;
    if (required.protected_memory == vk.TRUE and available.protected_memory == vk.FALSE) return false;
    if (required.sampler_ycbcr_conversion == vk.TRUE and available.sampler_ycbcr_conversion == vk.FALSE) return false;
    if (required.shader_draw_parameters == vk.TRUE and available.shader_draw_parameters == vk.FALSE) return false;

    return true;
}

fn supportsRequiredFeatures12(available: vk.PhysicalDeviceVulkan12Features, required: ?vk.PhysicalDeviceVulkan12Features) bool {
    if (required == null) return true;

    const req = required.?;
    if (req.sampler_mirror_clamp_to_edge == vk.TRUE and available.sampler_mirror_clamp_to_edge == vk.FALSE) return false;
    if (req.draw_indirect_count == vk.TRUE and available.draw_indirect_count == vk.FALSE) return false;
    if (req.storage_buffer_8_bit_access == vk.TRUE and available.storage_buffer_8_bit_access == vk.FALSE) return false;
    if (req.uniform_and_storage_buffer_8_bit_access == vk.TRUE and available.uniform_and_storage_buffer_8_bit_access == vk.FALSE) return false;
    if (req.storage_push_constant_8 == vk.TRUE and available.storage_push_constant_8 == vk.FALSE) return false;
    if (req.shader_buffer_int_64_atomics == vk.TRUE and available.shader_buffer_int_64_atomics == vk.FALSE) return false;
    if (req.shader_shared_int_64_atomics == vk.TRUE and available.shader_shared_int_64_atomics == vk.FALSE) return false;
    if (req.shader_float_16 == vk.TRUE and available.shader_float_16 == vk.FALSE) return false;
    if (req.shader_int_8 == vk.TRUE and available.shader_int_8 == vk.FALSE) return false;
    if (req.descriptor_indexing == vk.TRUE and available.descriptor_indexing == vk.FALSE) return false;
    if (req.shader_input_attachment_array_dynamic_indexing == vk.TRUE and available.shader_input_attachment_array_dynamic_indexing == vk.FALSE) return false;
    if (req.shader_uniform_texel_buffer_array_dynamic_indexing == vk.TRUE and available.shader_uniform_texel_buffer_array_dynamic_indexing == vk.FALSE) return false;
    if (req.shader_storage_texel_buffer_array_dynamic_indexing == vk.TRUE and available.shader_storage_texel_buffer_array_dynamic_indexing == vk.FALSE) return false;
    if (req.shader_uniform_buffer_array_non_uniform_indexing == vk.TRUE and available.shader_uniform_buffer_array_non_uniform_indexing == vk.FALSE) return false;
    if (req.shader_sampled_image_array_non_uniform_indexing == vk.TRUE and available.shader_sampled_image_array_non_uniform_indexing == vk.FALSE) return false;
    if (req.shader_storage_buffer_array_non_uniform_indexing == vk.TRUE and available.shader_storage_buffer_array_non_uniform_indexing == vk.FALSE) return false;
    if (req.shader_storage_image_array_non_uniform_indexing == vk.TRUE and available.shader_storage_image_array_non_uniform_indexing == vk.FALSE) return false;
    if (req.shader_input_attachment_array_non_uniform_indexing == vk.TRUE and available.shader_input_attachment_array_non_uniform_indexing == vk.FALSE) return false;
    if (req.shader_uniform_texel_buffer_array_non_uniform_indexing == vk.TRUE and available.shader_uniform_texel_buffer_array_non_uniform_indexing == vk.FALSE) return false;
    if (req.shader_storage_texel_buffer_array_non_uniform_indexing == vk.TRUE and available.shader_storage_texel_buffer_array_non_uniform_indexing == vk.FALSE) return false;
    if (req.descriptor_binding_uniform_buffer_update_after_bind == vk.TRUE and available.descriptor_binding_uniform_buffer_update_after_bind == vk.FALSE) return false;
    if (req.descriptor_binding_sampled_image_update_after_bind == vk.TRUE and available.descriptor_binding_sampled_image_update_after_bind == vk.FALSE) return false;
    if (req.descriptor_binding_storage_image_update_after_bind == vk.TRUE and available.descriptor_binding_storage_image_update_after_bind == vk.FALSE) return false;
    if (req.descriptor_binding_storage_buffer_update_after_bind == vk.TRUE and available.descriptor_binding_storage_buffer_update_after_bind == vk.FALSE) return false;
    if (req.descriptor_binding_uniform_texel_buffer_update_after_bind == vk.TRUE and available.descriptor_binding_uniform_texel_buffer_update_after_bind == vk.FALSE) return false;
    if (req.descriptor_binding_storage_texel_buffer_update_after_bind == vk.TRUE and available.descriptor_binding_storage_texel_buffer_update_after_bind == vk.FALSE) return false;
    if (req.descriptor_binding_update_unused_while_pending == vk.TRUE and available.descriptor_binding_update_unused_while_pending == vk.FALSE) return false;
    if (req.descriptor_binding_partially_bound == vk.TRUE and available.descriptor_binding_partially_bound == vk.FALSE) return false;
    if (req.descriptor_binding_variable_descriptor_count == vk.TRUE and available.descriptor_binding_variable_descriptor_count == vk.FALSE) return false;
    if (req.runtime_descriptor_array == vk.TRUE and available.runtime_descriptor_array == vk.FALSE) return false;
    if (req.sampler_filter_minmax == vk.TRUE and available.sampler_filter_minmax == vk.FALSE) return false;
    if (req.scalar_block_layout == vk.TRUE and available.scalar_block_layout == vk.FALSE) return false;
    if (req.imageless_framebuffer == vk.TRUE and available.imageless_framebuffer == vk.FALSE) return false;
    if (req.uniform_buffer_standard_layout == vk.TRUE and available.uniform_buffer_standard_layout == vk.FALSE) return false;
    if (req.shader_subgroup_extended_types == vk.TRUE and available.shader_subgroup_extended_types == vk.FALSE) return false;
    if (req.separate_depth_stencil_layouts == vk.TRUE and available.separate_depth_stencil_layouts == vk.FALSE) return false;
    if (req.host_query_reset == vk.TRUE and available.host_query_reset == vk.FALSE) return false;
    if (req.timeline_semaphore == vk.TRUE and available.timeline_semaphore == vk.FALSE) return false;
    if (req.buffer_device_address == vk.TRUE and available.buffer_device_address == vk.FALSE) return false;
    if (req.buffer_device_address_capture_replay == vk.TRUE and available.buffer_device_address_capture_replay == vk.FALSE) return false;
    if (req.buffer_device_address_multi_device == vk.TRUE and available.buffer_device_address_multi_device == vk.FALSE) return false;
    if (req.vulkan_memory_model == vk.TRUE and available.vulkan_memory_model == vk.FALSE) return false;
    if (req.vulkan_memory_model_device_scope == vk.TRUE and available.vulkan_memory_model_device_scope == vk.FALSE) return false;
    if (req.vulkan_memory_model_availability_visibility_chains == vk.TRUE and available.vulkan_memory_model_availability_visibility_chains == vk.FALSE) return false;
    if (req.shader_output_viewport_index == vk.TRUE and available.shader_output_viewport_index == vk.FALSE) return false;
    if (req.shader_output_layer == vk.TRUE and available.shader_output_layer == vk.FALSE) return false;
    if (req.subgroup_broadcast_dynamic_id == vk.TRUE and available.subgroup_broadcast_dynamic_id == vk.FALSE) return false;

    return true;
}

fn supportsRequiredFeatures13(available: vk.PhysicalDeviceVulkan13Features, required: ?vk.PhysicalDeviceVulkan13Features) bool {
    if (required == null) return true;

    const req = required.?;
    if (req.robust_image_access == vk.TRUE and available.robust_image_access == vk.FALSE) return false;
    if (req.inline_uniform_block == vk.TRUE and available.inline_uniform_block == vk.FALSE) return false;
    if (req.descriptor_binding_inline_uniform_block_update_after_bind == vk.TRUE and available.descriptor_binding_inline_uniform_block_update_after_bind == vk.FALSE) return false;
    if (req.pipeline_creation_cache_control == vk.TRUE and available.pipeline_creation_cache_control == vk.FALSE) return false;
    if (req.private_data == vk.TRUE and available.private_data == vk.FALSE) return false;
    if (req.shader_demote_to_helper_invocation == vk.TRUE and available.shader_demote_to_helper_invocation == vk.FALSE) return false;
    if (req.shader_terminate_invocation == vk.TRUE and available.shader_terminate_invocation == vk.FALSE) return false;
    if (req.subgroup_size_control == vk.TRUE and available.subgroup_size_control == vk.FALSE) return false;
    if (req.compute_full_subgroups == vk.TRUE and available.compute_full_subgroups == vk.FALSE) return false;
    if (req.synchronization_2 == vk.TRUE and available.synchronization_2 == vk.FALSE) return false;
    if (req.texture_compression_astc_hdr == vk.TRUE and available.texture_compression_astc_hdr == vk.FALSE) return false;
    if (req.shader_zero_initialize_workgroup_memory == vk.TRUE and available.shader_zero_initialize_workgroup_memory == vk.FALSE) return false;
    if (req.dynamic_rendering == vk.TRUE and available.dynamic_rendering == vk.FALSE) return false;
    if (req.shader_integer_dot_product == vk.TRUE and available.shader_integer_dot_product == vk.FALSE) return false;
    if (req.maintenance_4 == vk.TRUE and available.maintenance_4 == vk.FALSE) return false;
    return true;
}

fn isCompatibleWithSurface(handle: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = 0;
    var result = try vki().getPhysicalDeviceSurfaceFormatsKHR(handle, surface, &format_count, null);
    if (result != .success) return false;

    var present_mode_count: u32 = 0;
    result = try vki().getPhysicalDeviceSurfacePresentModesKHR(handle, surface, &present_mode_count, null);
    if (result != .success) return false;

    return format_count > 0 and present_mode_count > 0;
}

fn isExtensionAvailable(
    available_extensions: []const vk.ExtensionProperties,
    extension: [*:0]const u8,
) bool {
    for (available_extensions) |ext| {
        const n: [*:0]const u8 = @ptrCast(&ext.extension_name);
        if (std.mem.orderZ(u8, n, extension) == .eq) {
            return true;
        }
    }
    return false;
}

fn getPhysicalDeviceInfo(
    handle: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    api_version: u32,
) !PhysicalDeviceInfo {
    const properties = vki().getPhysicalDeviceProperties(handle);
    const memory_properties = vki().getPhysicalDeviceMemoryProperties(handle);

    var features = vk.PhysicalDeviceFeatures2{ .features = .{} };
    var features_11 = vk.PhysicalDeviceVulkan11Features{};
    var features_12 = vk.PhysicalDeviceVulkan12Features{};
    var features_13 = vk.PhysicalDeviceVulkan13Features{};

    features.p_next = &features_11;
    if (api_version >= @as(u32, @bitCast(vk.API_VERSION_1_2)))
        features_11.p_next = &features_12;
    if (api_version >= @as(u32, @bitCast(vk.API_VERSION_1_3)))
        features_12.p_next = &features_13;

    vki().getPhysicalDeviceFeatures2(handle, &features);

    var extension_count: u32 = 0;
    var result = try vki().enumerateDeviceExtensionProperties(handle, null, &extension_count, null);
    if (result != .success) return error.EnumeratePhysicalDeviceExtensionsFailed;

    std.debug.assert(max_available_extensions >= extension_count);

    var available_extensions = try PhysicalDeviceExtensionsArray.init(extension_count);
    while (true) {
        result = try vki().enumerateDeviceExtensionProperties(handle, null, &extension_count, &available_extensions.buffer);
        if (result == .success) break;
    }

    var family_count: u32 = 0;
    vki().getPhysicalDeviceQueueFamilyProperties(handle, &family_count, null);

    std.debug.assert(max_queue_families >= family_count);

    var queue_families = try PhysicalDeviceQueueFamiliesArray.init(family_count);
    vki().getPhysicalDeviceQueueFamilyProperties(handle, &family_count, &queue_families.buffer);

    const graphics_queue_index = getQueueStrict(queue_families.constSlice(), .{ .graphics_bit = true }, .{});
    const dedicated_transfer = getQueueStrict(
        queue_families.constSlice(),
        .{ .transfer_bit = true },
        .{ .graphics_bit = true, .compute_bit = true },
    );
    const dedicated_compute = getQueueStrict(
        queue_families.constSlice(),
        .{ .compute_bit = true },
        .{ .graphics_bit = true, .transfer_bit = true },
    );
    const separate_transfer = getQueueNoGraphics(
        queue_families.constSlice(),
        .{ .transfer_bit = true },
        .{ .compute_bit = true },
    );
    const separate_compute = getQueueNoGraphics(
        queue_families.constSlice(),
        .{ .compute_bit = true },
        .{ .transfer_bit = true },
    );
    const present_queue_index = try getPresentQueue(handle, queue_families.constSlice(), surface);

    const portability_ext_available = isExtensionAvailable(available_extensions.constSlice(), vk.extensions.khr_portability_subset.name);

    return .{
        .handle = handle,
        .features = features.features,
        .features_11 = features_11,
        .features_12 = features_12,
        .features_13 = features_13,
        .properties = properties,
        .memory_properties = memory_properties,
        .available_extensions = available_extensions,
        .queue_families = queue_families,
        .graphics_queue_index = graphics_queue_index,
        .present_queue_index = present_queue_index,
        .dedicated_transfer_queue_index = dedicated_transfer,
        .dedicated_compute_queue_index = dedicated_compute,
        .separate_transfer_queue_index = separate_transfer,
        .separate_compute_queue_index = separate_compute,
        .portability_ext_available = portability_ext_available,
    };
}

fn getPhysicalDevices(instance: vk.Instance) !PhysicalDeviceHandlesArray {
    var device_count: u32 = 0;
    var result = try vki().enumeratePhysicalDevices(instance, &device_count, null);
    if (result != .success) return error.EnumeratePhysicalDevicesFailed;

    var physical_devices = try PhysicalDeviceHandlesArray.init(device_count);

    while (true) {
        result = try vki().enumeratePhysicalDevices(instance, &device_count, &physical_devices.buffer);
        if (result == .success) break;
    }

    return physical_devices;
}
