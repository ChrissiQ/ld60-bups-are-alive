class_name MachineMemory
extends RefCounted
## What the machine reports about its memory, in one meaning on every platform, each figure -1 when the machine does not say. The engine's
## own `OS.get_memory_info()` means different things on different systems, so they are sorted out here and nowhere else:
##  - `physical`: the memory installed (usable by the system).
##  - `available`: the memory a program can take without the system swapping or compressing others out. Windows: `free` (the physical memory
##    available, standby cache included; the engine's `available` there is the commit limit, RAM plus page file, which is not free RAM). macOS:
##    `free` (the physical memory less what programs and the kernel hold, file cache not counted; the engine's `available` adds the swap file's
##    free space, which is disk, not memory). Linux: `MemAvailable` of /proc/meminfo (the engine's `free` is `MemFree`, which leaves the
##    reclaimable cache out and so reads far too low on a machine that has run a while; its `available` adds free swap).
##  - `adapter_type`: the engine's `RenderingDevice.DeviceType` of the graphics adapter (`DEVICE_TYPE_OTHER` when it does not say).
##  - `shared`: 1 when the graphics memory is the system's (an integrated adapter, or software rendering), 0 when the adapter has memory of its
##    own (a discrete card), -1 when not known.
##  - `card_dedicated`, `card_budget`, `card_usage`, `card_api`: what the native `GpuMemory` query reports of the graphics card (bytes of its own
##    memory; what the system lets this process use of it now and what the process uses now, each -1 when the API does not say; the API that
##    answered, "" when none did). All -1 and "" where the query is not there or cannot tell (macOS, whose graphics memory is the system's).
##    `handles` are the driver's handles the query needs, which only the main thread can read (`card_handles()`); a reading from another
##    thread passes them in.

const UNKNOWN := -1

var physical := UNKNOWN
var available := UNKNOWN
var adapter_type := RenderingDevice.DEVICE_TYPE_OTHER
var shared := UNKNOWN
var card_dedicated := UNKNOWN
var card_budget := UNKNOWN
var card_usage := UNKNOWN
var card_api := ""
var handles := {}


## What this machine reports now. `adapter_type` is `RenderingServer.get_video_adapter_type()`, read once on the main thread (the render
## server is not called from other threads); the memory figures are read here and may be read from any thread.
## `handles` is `card_handles()`, read once on the main thread.
static func read(adapter: int = RenderingDevice.DEVICE_TYPE_OTHER, handles := {}) -> MachineMemory:
	var linux_available := UNKNOWN
	if OS.get_name() in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		linux_available = _meminfo_available()
	var m := from_report(OS.get_memory_info(), OS.get_name(), adapter, linux_available, query_card(handles))
	m.handles = handles
	return m


## The driver's handles for the card query: the render server's driver name and adapter name and the integers `RenderingDevice` gives for
## the logical device, the physical device and the topmost object (0 when it has none, as with no main device). Main thread only; the
## calls are made directly, which holds while the project keeps the engine's default rendering thread model (rendering on the main thread).
static func card_handles() -> Dictionary:
	var out := {"driver": RenderingServer.get_current_rendering_driver_name(), "name": RenderingServer.get_video_adapter_name(), "logical": 0, "physical": 0, "instance": 0}
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		out["logical"] = rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0)
		out["physical"] = rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_PHYSICAL_DEVICE, RID(), 0)
		out["instance"] = rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_TOPMOST_OBJECT, RID(), 0)
	return out


## The native `GpuMemory` query's answer for `handles` (`{known: false}` when the extension is not loaded; may be called from any thread).
static func query_card(handles: Dictionary) -> Dictionary:
	if handles.is_empty() or not ClassDB.class_exists("GpuMemory"):
		return {"known": false}
	return ClassDB.class_call_static("GpuMemory", "query", String(handles.get("driver", "")), int(handles.get("logical", 0)), int(handles.get("physical", 0)), int(handles.get("instance", 0)), String(handles.get("name", "")))


## The report for the engine's `info` (the keys of `OS.get_memory_info()`), the system's name (`OS.get_name()`), the adapter's type and, on
## Linux, `MemAvailable` in bytes (-1 when it could not be read) and the card query's answer (`{known: false}`: none). Pure: the tests make
## machines out of it.
static func from_report(info: Dictionary, os_name: String, adapter: int, mem_available := UNKNOWN, card := {}) -> MachineMemory:
	var m := MachineMemory.new()
	m.physical = _positive(info.get("physical", UNKNOWN))
	var free := _positive(info.get("free", UNKNOWN))
	if os_name == "Linux" and mem_available > 0:
		m.available = mem_available
	else:
		m.available = free  # (never the engine's "available": the commit limit on Windows, free swap added elsewhere)
	if m.physical > 0 and m.available > m.physical:
		m.available = m.physical
	m.adapter_type = adapter
	match adapter:
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU, RenderingDevice.DEVICE_TYPE_CPU:
			m.shared = 1
		RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:
			m.shared = 0
	if card.get("known", false) == true:
		m.card_dedicated = _positive(card.get("dedicated", UNKNOWN))
		m.card_budget = _positive(card.get("budget", UNKNOWN))
		var usage := int(card.get("usage", UNKNOWN))
		m.card_usage = usage if m.card_budget > 0 and usage >= 0 else UNKNOWN
		m.card_api = String(card.get("api", ""))
		if m.shared == UNKNOWN and m.card_dedicated > 0:
			m.shared = 0
	return m


static func _positive(v: Variant) -> int:
	var n := int(v) if (v is int or v is float) else UNKNOWN
	return n if n > 0 else UNKNOWN


## `MemAvailable` of /proc/meminfo in bytes, -1 when the file or the line is not there.
static func _meminfo_available() -> int:
	var f := FileAccess.open("/proc/meminfo", FileAccess.READ)
	if f == null:
		return UNKNOWN
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("MemAvailable:"):
			var kb := line.replace("MemAvailable:", "").replace("kB", "").strip_edges()
			return int(kb) * 1024 if kb.is_valid_int() else UNKNOWN
	return UNKNOWN


## For the debug log.
func to_dict() -> Dictionary:
	return {"physical": physical, "available": available, "adapter_type": adapter_type, "shared": shared, "card_dedicated": card_dedicated, "card_budget": card_budget, "card_usage": card_usage, "card_api": card_api}
