class_name PoolLimits
extends RefCounted
## The pooled world's starting sizes and its memory budget. The arena starts at these physical sizes and grows by
## 1.5 when a batch would pass 90% of one; it never grows past `memory_budget_bytes` (a dish, a thaw or a limit that would is refused).

var world_slots := 16384  ## bup record slots (the sum of the dishes' 256-aligned segments)
var field_cells := 65536  ## field cells (the dishes' 256-aligned blocks of n² cells)
var cloud_slots := 16384  ## physical cloud slots (each with ENTRIES_PER_SLOT list entries to start with)
var husk_slots := 4096
var bins := 65536  ## cloud-list squares
const WARN_FRACTION := 0.90  ## the share of the memory budget at which the game warns that graphics memory is nearly full
const BUDGET_SHARE := 0.4  ## of the physical memory: the buffers' share (the host side's copies of a dish's grid and the rest of the process add about a quarter on top, and the system and other programs need the rest)
const BUDGET_AVAILABLE_SHARE := 0.7  ## of the memory the system reports available when the game starts: a busy machine gets a smaller budget
const BUDGET_FLOOR := 1024 * 1024 * 1024  ## the least: the pool has to hold a few big dishes
const BUDGET_SEPARATE_CAP := 4 * 1024 * 1024 * 1024  ## the most when the adapter has memory of its own (or is not known to be integrated), whose size the engine does not report
const WARN_NEAR := "near"
const WARN_STALLED := "stalled"

var d_max := GpuLayout.D_MAX  ## dish rows (fixed by the layout)
var memory_budget_bytes := 6 * 1024 * 1024 * 1024  ## what the arena may hold; `from_settings` works the game's out from what the machine reports (`budget_for`), the tests set their own
var payload_rows := 64  ## rows of PAYLOAD_TEX_WIDTH texels the payload textures start with
var frame_queue_size := 2  ## the main device's frames in flight: a texture is written again only after this many frames and one more
var from_source := false  ## compile the kernels from GpuKernels.all() on the device instead of loading the imported SPIR-V (tools)


## The limits with `frame_queue_size` read from the project's settings (the main thread calls this; the sim thread never reads a setting).
static func from_settings() -> PoolLimits:
	var limits := PoolLimits.new()
	limits.frame_queue_size = int(ProjectSettings.get_setting("rendering/rendering_device/vsync/frame_queue_size", 2))
	var info := OS.get_memory_info()
	limits.memory_budget_bytes = budget_for(int(info.get("physical", -1)), int(info.get("available", -1)), RenderingServer.get_video_adapter_type() == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU)
	return limits


## The memory budget for a machine that reports `physical` bytes of memory and `available` bytes free to use now (either -1 when it does not say) and whose
## graphics adapter shares the system's memory (`shared`: an integrated adapter) or has memory of its own: BUDGET_SHARE of the physical memory, at most
## BUDGET_AVAILABLE_SHARE of what is available, at least BUDGET_FLOOR; with memory of its own at most BUDGET_SEPARATE_CAP. Nothing reported: the floor.
static func budget_for(physical: int, available: int, shared: bool) -> int:
	if physical <= 0:
		return BUDGET_FLOOR
	var budget := BUDGET_SHARE * physical
	if available > 0:
		budget = minf(budget, BUDGET_AVAILABLE_SHARE * available)
	if not shared:
		budget = minf(budget, BUDGET_SEPARATE_CAP)
	return maxi(int(budget), BUDGET_FLOOR)


## The memory warning a timing dictionary (a snapshot's) calls for: WARN_STALLED while an iteration is refused for want of room (the
## simulation waits), WARN_NEAR while the buffers hold WARN_FRACTION of the budget or more, else "".
static func warning_state(timing: Dictionary) -> String:
	if String(timing.get("refused_iteration", "")) != "":
		return WARN_STALLED
	if float(timing.get("memory_fraction", 0.0)) >= WARN_FRACTION:
		return WARN_NEAR
	return ""
