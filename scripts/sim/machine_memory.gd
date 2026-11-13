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

const UNKNOWN := -1

var physical := UNKNOWN
var available := UNKNOWN
var adapter_type := RenderingDevice.DEVICE_TYPE_OTHER
var shared := UNKNOWN


## What this machine reports now. `adapter_type` is `RenderingServer.get_video_adapter_type()`, read once on the main thread (the render
## server is not called from other threads); the memory figures are read here and may be read from any thread.
static func read(adapter: int = RenderingDevice.DEVICE_TYPE_OTHER) -> MachineMemory:
	var linux_available := UNKNOWN
	if OS.get_name() in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		linux_available = _meminfo_available()
	return from_report(OS.get_memory_info(), OS.get_name(), adapter, linux_available)


## The report for the engine's `info` (the keys of `OS.get_memory_info()`), the system's name (`OS.get_name()`), the adapter's type and, on
## Linux, `MemAvailable` in bytes (-1 when it could not be read). Pure: the tests make machines out of it.
static func from_report(info: Dictionary, os_name: String, adapter: int, mem_available := UNKNOWN) -> MachineMemory:
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
	return {"physical": physical, "available": available, "adapter_type": adapter_type, "shared": shared}
