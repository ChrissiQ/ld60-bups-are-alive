#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

// What the graphics card the game renders with reports about its own memory, which the engine does not expose. One static query; it reads
// the operating system's or the graphics API's figures and never throws: where it cannot tell, `known` is false and nothing else is set.
//   Windows: DXGI (the adapter's dedicated video memory; the budget the system gives this process and what it uses now).
//   Linux: Vulkan, loaded at run time (the device-local heaps; the budget and usage too when the driver has VK_EXT_memory_budget).
//   Other systems (macOS: the memory is the system's): not known.
// It may be called from any thread once the handles are read (the handles are plain integers, which the main thread gets from the render
// server).
class GpuMemory : public godot::RefCounted {
	GDCLASS(GpuMemory, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	// `driver`: the render server's current driver name ("d3d12", "vulkan", "metal"...). `logical`, `physical` and `instance`: the integers
	// `RenderingDevice.get_driver_resource` gives for DRIVER_RESOURCE_LOGICAL_DEVICE, _PHYSICAL_DEVICE and _TOPMOST_OBJECT (0 when not
	// available). `adapter_name`: `RenderingServer.get_video_adapter_name()`.
	// Returns { known: bool, dedicated: int (bytes of the card's own memory), budget: int (bytes the system lets this process use now, 0 when
	// the API does not say), usage: int (bytes this process uses now, 0 when it does not say), api: String }.
	static godot::Dictionary query(const godot::String &p_driver, int64_t p_logical, int64_t p_physical, int64_t p_instance, const godot::String &p_adapter_name);
};
