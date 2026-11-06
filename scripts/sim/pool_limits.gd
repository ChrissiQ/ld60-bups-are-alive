class_name PoolLimits
extends RefCounted
## The pooled world's starting sizes and its memory budget. The arena starts at these physical sizes and grows by
## 1.5 when a batch would pass 90% of one; it never grows past `memory_budget_bytes` (a dish, a thaw or a limit that would is refused).

var world_slots := 16384  ## bup record slots (the sum of the dishes' 256-aligned segments)
var field_cells := 65536  ## field cells (the dishes' 256-aligned blocks of n² cells)
var cloud_slots := 16384  ## physical cloud slots (each with ENTRIES_PER_SLOT list entries)
var husk_slots := 4096
var bins := 65536  ## cloud-list squares
const WARN_FRACTION := 0.90  ## the share of the memory budget at which the game warns that graphics memory is nearly full
const WARN_NEAR := "near"
const WARN_STALLED := "stalled"

var d_max := GpuLayout.D_MAX  ## dish rows (fixed by the layout)
var memory_budget_bytes := 6 * 1024 * 1024 * 1024  ## [placeholder]
var payload_rows := 64  ## rows of PAYLOAD_TEX_WIDTH texels the payload textures start with
var frame_queue_size := 2  ## the main device's frames in flight: a texture is written again only after this many frames and one more
var from_source := false  ## compile the kernels from GpuKernels.all() on the device instead of loading the imported SPIR-V (tools)


## The limits with `frame_queue_size` read from the project's settings (the main thread calls this; the sim thread never reads a setting).
static func from_settings() -> PoolLimits:
	var limits := PoolLimits.new()
	limits.frame_queue_size = int(ProjectSettings.get_setting("rendering/rendering_device/vsync/frame_queue_size", 2))
	return limits


## The memory warning a timing dictionary (a snapshot's) calls for: WARN_STALLED while an iteration is refused for want of room (the
## simulation waits), WARN_NEAR while the buffers hold WARN_FRACTION of the budget or more, else "".
static func warning_state(timing: Dictionary) -> String:
	if String(timing.get("refused_iteration", "")) != "":
		return WARN_STALLED
	if float(timing.get("memory_fraction", 0.0)) >= WARN_FRACTION:
		return WARN_NEAR
	return ""
