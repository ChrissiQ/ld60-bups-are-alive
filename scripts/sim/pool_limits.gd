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
const BUDGET_SHARE := 0.4  ## of the memory the buffers may share with the system (the whole of it when the graphics memory is the system's): the host side's copies of a dish's grid and the rest of the process add up to a quarter on top, which keeps the process near half of the memory
const BUDGET_FLOOR := 1024 * 1024 * 1024  ## the least: the pool has to hold a few big dishes
const BUDGET_CAP := 8 * 1024 * 1024 * 1024  ## the most: more than any dish or crowd the interface allows needs
const CARD_SHARE := 0.75  ## of what the system lets the process use on a card with memory of its own (the card's budget, else its dedicated memory), the share the buffers may take: the rest holds the interface's drawing, the engine's own textures and what other programs use; the same share of what is still free bounds a growth
const DISCRETE_BUDGET := 2 * 1024 * 1024 * 1024  ## the budget for a card with memory of its own whose size could not be read (the native query is not there or the driver did not answer): a 4 GB card has to hold the interface's drawing besides
const GROW_SHARE := 0.5  ## of the system memory free now (a card with a live budget uses CARD_SHARE of its own free memory instead), what the pool may take on top of what it holds
const SHORT_FREE_SHARE := 0.1  ## of the physical memory: below this much free the machine is short and the pool gives back what it uses little
const LOW_BUPS := 500000  ## low-memory mode: the most bups a dish may be given as its limit (about 0.5 GB of buffers a dish at its limit)
const LOW_DISHES := 10  ## low-memory mode: the most dishes running at once
const LOW_GRID := 200  ## low-memory mode: the most cells across a dish's nutrient grid (about 21 MB a dish)
const GIB := 1024 * 1024 * 1024
const WARN_NEAR := "near"
const WARN_STALLED := "stalled"
const MACHINE_ENOUGH := "enough"
const MACHINE_LOW := "low"
const MACHINE_BELOW := "below"
const MIN_PHYSICAL := 3 * 1024 * 1024 * 1024  ## under this much memory the default game (about 0.9 GB of process at 100,000 bups) leaves the system too little
const MIN_FREE := 1024 * 1024 * 1024  ## under this much free at start the default game does not fit beside what is running
const ENOUGH_BUDGET := 2 * 1024 * 1024 * 1024  ## a budget under this cannot hold the largest dish the interface allows (about 1.85 GB of buffers) whole

var d_max := GpuLayout.D_MAX  ## dish rows (fixed by the layout)
var memory_budget_bytes := 6 * 1024 * 1024 * 1024  ## what the arena may hold now (the working budget); `from_settings` works the game's out from what the machine reports (`budget_for`) and the memory watch moves it, the tests set their own
var machine: MachineMemory  ## what the machine reported when the limits were made (null in the tests)
var watch: MemoryWatch  ## keeps `memory_budget_bytes` in step with the free memory (null: it stays where it is set)
var payload_rows := 64  ## rows of PAYLOAD_TEX_WIDTH texels the payload textures start with
var frame_queue_size := 2  ## the main device's frames in flight: a texture is written again only after this many frames and one more
var from_source := false  ## compile the kernels from GpuKernels.all() on the device instead of loading the imported SPIR-V (tools)


## The limits with `frame_queue_size` read from the project's settings and the budget from what the machine reports (the main thread calls
## this; the sim thread never reads a setting). The sim thread starts the memory watch on them (`start_watch`).
static func from_settings() -> PoolLimits:
	UserSettings.load_once()
	var limits := PoolLimits.new()
	limits.frame_queue_size = int(ProjectSettings.get_setting("rendering/rendering_device/vsync/frame_queue_size", 2))
	limits.machine = MachineMemory.read(RenderingServer.get_video_adapter_type(), MachineMemory.card_handles())
	limits.memory_budget_bytes = budget_for(limits.machine)
	return limits


## Makes the watch that keeps the working budget in step with the free memory; the adapter's type and the card's handles are what
## `from_settings` read (on the main thread: the sim thread reads the machine again with them).
func start_watch() -> void:
	if machine == null or watch != null:
		return
	var adapter := machine.adapter_type
	var handles := machine.handles
	watch = MemoryWatch.new(self, func() -> MachineMemory: return MachineMemory.read(adapter, handles))


## The budget for a machine. Graphics memory that is the system's: BUDGET_SHARE of the physical memory. Otherwise (a card with memory of its
## own, or an adapter not known to be integrated): CARD_SHARE of what the system lets the process use of the card (`card_budget`; else
## `card_dedicated`), DISCRETE_BUDGET when the card's size is not known, and never more than BUDGET_SHARE of the physical memory when that is
## known (the host side's copies of the buffers live there). Held between BUDGET_FLOOR and BUDGET_CAP; nothing usable reported: the floor.
static func budget_for(m: MachineMemory) -> int:
	if m.shared == 1:
		if m.physical <= 0:
			return BUDGET_FLOOR
		return clampi(int(BUDGET_SHARE * m.physical), BUDGET_FLOOR, BUDGET_CAP)
	var card := m.card_budget if m.card_budget > 0 else m.card_dedicated
	var budget := CARD_SHARE * card if card > 0 else float(DISCRETE_BUDGET)
	if m.physical > 0:
		budget = minf(budget, BUDGET_SHARE * m.physical)
	elif card <= 0:
		return BUDGET_FLOOR
	return clampi(int(budget), BUDGET_FLOOR, BUDGET_CAP)


## Whether low-memory mode is on for a machine: it is not classed enough.
static func is_low_memory(m: MachineMemory) -> bool:
	return classify(m) != MACHINE_ENOUGH


## The working budget with `held` bytes in the buffers and the machine as it is now: what the pool holds plus what it may still take, held
## between BUDGET_FLOOR and `ceiling`. On a card with memory of its own that reports a live budget and usage (usage counts what the pool
## holds), what it may still take is CARD_SHARE of the budget not yet used; otherwise GROW_SHARE of the system memory free. Neither
## reported: the ceiling.
static func working_budget_for(m: MachineMemory, held: int, ceiling: int) -> int:
	var more := -1
	if m.shared == 0 and m.card_budget > 0 and m.card_usage >= 0:
		more = int(CARD_SHARE * maxi(m.card_budget - m.card_usage, 0))
	elif m.available > 0:
		more = int(GROW_SHARE * m.available)
	if more < 0:
		return ceiling
	return clampi(held + more, mini(BUDGET_FLOOR, ceiling), ceiling)


## Whether the machine is short of memory: what is free is under SHORT_FREE_SHARE of the physical memory (false when either is not reported).
static func is_short(m: MachineMemory) -> bool:
	return m.physical > 0 and m.available > 0 and m.available < SHORT_FREE_SHARE * m.physical


## How a machine is classed at start: MACHINE_BELOW when it has less than MIN_PHYSICAL or less than MIN_FREE free (a figure not reported
## is not held against it), MACHINE_LOW when it is not below but its budget is under ENOUGH_BUDGET or its physical memory is not known,
## else MACHINE_ENOUGH.
static func classify(m: MachineMemory) -> String:
	if (m.physical > 0 and m.physical < MIN_PHYSICAL) or (m.available > 0 and m.available < MIN_FREE):
		return MACHINE_BELOW
	if m.physical <= 0 or budget_for(m) < ENOUGH_BUDGET:
		return MACHINE_LOW
	return MACHINE_ENOUGH


## The memory warning a timing dictionary (a snapshot's) calls for: WARN_STALLED while an iteration is refused for want of room (the
## simulation waits), WARN_NEAR while the buffers hold WARN_FRACTION of the budget or more, else "".
static func warning_state(timing: Dictionary) -> String:
	if String(timing.get("refused_iteration", "")) != "":
		return WARN_STALLED
	if float(timing.get("memory_fraction", 0.0)) >= WARN_FRACTION:
		return WARN_NEAR
	return ""
