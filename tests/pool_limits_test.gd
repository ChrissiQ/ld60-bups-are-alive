extends SceneTree
## Run: godot --headless --path . -s tests/pool_limits_test.gd
## The pool's memory budget worked out from what a machine reports (MachineMemory, PoolLimits.budget_for, working_budget_for, MemoryWatch),
## headless, with made-up machines. Expected values
## [derived from BUDGET_SHARE 0.4, BUDGET_FLOOR 1 GiB, BUDGET_CAP 8 GiB, DISCRETE_BUDGET 2 GiB, GROW_SHARE 0.5, SHORT_FREE_SHARE 0.1]:
##  - what a machine has free is `free` on Windows and macOS (never the engine's `available`: Windows' commit limit, macOS's free swap
##    added), `MemAvailable` on Linux when it is read, else `free`; a figure the engine gives as -1 is unknown;
##  - 16 GiB shared: 0.4 x 16 = 6.4 GiB; 8 GiB shared: 3.2 GiB; 64 GiB shared: the 8 GiB cap; 2 GiB: the 1 GiB floor;
##  - memory of its own (discrete) or an adapter not known: at most the 2 GiB default whatever the system memory is (1 GiB when that is under 2.5 GiB);
##  - physical memory not reported: the floor;
##  - working budget = held + 0.5 x free, between the floor and the ceiling: 6.4 ceiling, 1 held, 10 free: 6.0; 2 free: 2.0; 0.2 free: the floor;
##    free not reported: the ceiling; short when free is under a tenth of physical;
##  - the watch lowers the working budget at once and raises it only when the figure has come back by a tenth of the ceiling or reaches the ceiling;
##    it reads on its timer (5 s) and before a growth (at most once a second), and never per call;
##  - `PoolLimits.new()` keeps the 6 GiB the tests set their own budgets from; the warning is at WARN_FRACTION of whatever budget is set.
const GIB := 1024 * 1024 * 1024
const MAC := "macOS"
const WIN := "Windows"
const LIN := "Linux"
const INTEGRATED := RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU
const DISCRETE := RenderingDevice.DEVICE_TYPE_DISCRETE_GPU
const OTHER := RenderingDevice.DEVICE_TYPE_OTHER

var _clock_reads := 0
var _machine: MachineMemory


func _init() -> void:
	_meanings()
	_budgets()
	_working()
	_watch()
	_classes()
	TestUtil.check(PoolLimits.new().memory_budget_bytes == 6 * GIB, "the tests' default budget is unchanged")
	var started := PoolLimits.from_settings()
	TestUtil.check(started.memory_budget_bytes >= PoolLimits.BUDGET_FLOOR and started.memory_budget_bytes <= PoolLimits.BUDGET_CAP, "from_settings gives a budget between the floor and the cap")
	TestUtil.check(PoolLimits.warning_state({"memory_fraction": 0.9}) == PoolLimits.WARN_NEAR and PoolLimits.warning_state({"memory_fraction": 0.89}) == "", "the warning stays at 0.9")
	TestUtil.finish(self, "OK pool_limits_test")


func _machine_of(physical: int, free: int, available: int, os_name: String, adapter: int, linux_available := -1) -> MachineMemory:
	return MachineMemory.from_report({"physical": physical, "free": free, "available": available, "stack": -1}, os_name, adapter, linux_available)


func _meanings() -> void:
	var mac := _machine_of(16 * GIB, 10 * GIB, 30 * GIB, MAC, INTEGRATED)  # (the engine's available adds free swap)
	TestUtil.check(mac.available == 10 * GIB and mac.physical == 16 * GIB and mac.shared == 1, "macOS: free is what is available, the engine's available (swap added) is not used")
	var win := _machine_of(16 * GIB, 9 * GIB, 40 * GIB, WIN, DISCRETE)  # (the engine's available is the commit limit)
	TestUtil.check(win.available == 9 * GIB and win.shared == 0, "Windows: free is what is available, not the commit limit")
	var lin := _machine_of(32 * GIB, 2 * GIB, 10 * GIB, LIN, INTEGRATED, 24 * GIB)  # (MemFree 2 GiB with 22 GiB of cache)
	TestUtil.check(lin.available == 24 * GIB, "Linux: MemAvailable when it was read")
	var lin2 := _machine_of(32 * GIB, 2 * GIB, 10 * GIB, LIN, INTEGRATED)
	TestUtil.check(lin2.available == 2 * GIB, "Linux without MemAvailable: free")
	var none := _machine_of(-1, -1, -1, "Other", OTHER)
	TestUtil.check(none.physical == -1 and none.available == -1 and none.shared == -1, "nothing reported: everything unknown")
	var cpu := _machine_of(8 * GIB, 4 * GIB, 4 * GIB, LIN, RenderingDevice.DEVICE_TYPE_CPU)
	TestUtil.check(cpu.shared == 1, "software rendering shares the system's memory")
	var over := _machine_of(8 * GIB, 12 * GIB, -1, WIN, INTEGRATED)
	TestUtil.check(over.available == 8 * GIB, "available is never more than the physical memory")
	TestUtil.check(MachineMemory.read(INTEGRATED).physical != 0, "the real machine reports a figure or -1, never 0")


func _budgets() -> void:
	TestUtil.check(_near(PoolLimits.budget_for(_machine_of(16 * GIB, 10 * GIB, -1, MAC, INTEGRATED)), 6.4 * GIB), "16 GiB shared: 6.4 GiB")
	TestUtil.check(_near(PoolLimits.budget_for(_machine_of(16 * GIB, 1 * GIB, -1, MAC, INTEGRATED)), 6.4 * GIB), "the budget is the ceiling whatever is free now: the working budget follows what is free")
	TestUtil.check(_near(PoolLimits.budget_for(_machine_of(8 * GIB, 5 * GIB, -1, WIN, INTEGRATED)), 3.2 * GIB), "8 GiB shared: 3.2 GiB")
	TestUtil.check(PoolLimits.budget_for(_machine_of(64 * GIB, 50 * GIB, -1, WIN, INTEGRATED)) == 8 * GIB, "64 GiB shared: the cap")
	TestUtil.check(PoolLimits.budget_for(_machine_of(32 * GIB, 20 * GIB, -1, WIN, DISCRETE)) == 2 * GIB, "a discrete card, 32 GiB of system memory: 2 GiB")
	TestUtil.check(PoolLimits.budget_for(_machine_of(32 * GIB, 20 * GIB, -1, LIN, OTHER)) == 2 * GIB, "an adapter not known: 2 GiB")
	TestUtil.check(_near(PoolLimits.budget_for(_machine_of(4 * GIB, 2 * GIB, -1, WIN, DISCRETE)), 1.6 * GIB), "a discrete card, 4 GiB of system memory: 0.4 x 4")
	TestUtil.check(PoolLimits.budget_for(_machine_of(2 * GIB, 1 * GIB, -1, WIN, INTEGRATED)) == GIB, "2 GiB: the floor")
	TestUtil.check(PoolLimits.budget_for(_machine_of(-1, -1, -1, "Other", OTHER)) == GIB, "nothing reported: the floor")
	TestUtil.check(PoolLimits.budget_for(_machine_of(-1, 4 * GIB, -1, "Other", INTEGRATED)) == GIB, "no physical memory: the floor")


func _working() -> void:
	var ceiling := int(6.4 * GIB)
	TestUtil.check(_near(PoolLimits.working_budget_for(_machine_of(16 * GIB, 10 * GIB, -1, MAC, INTEGRATED), GIB, ceiling), 6.0 * GIB), "held 1, free 10: 6")
	TestUtil.check(_near(PoolLimits.working_budget_for(_machine_of(16 * GIB, 2 * GIB, -1, MAC, INTEGRATED), GIB, ceiling), 2.0 * GIB), "held 1, free 2: 2")
	TestUtil.check(PoolLimits.working_budget_for(_machine_of(16 * GIB, int(0.2 * GIB), -1, MAC, INTEGRATED), 0, ceiling) == GIB, "almost nothing free: the floor")
	TestUtil.check(PoolLimits.working_budget_for(_machine_of(16 * GIB, 30 * GIB, -1, MAC, INTEGRATED), 3 * GIB, ceiling) == ceiling, "plenty free: the ceiling")
	TestUtil.check(PoolLimits.working_budget_for(_machine_of(16 * GIB, -1, -1, MAC, INTEGRATED), 3 * GIB, ceiling) == ceiling, "free not reported: the ceiling")
	TestUtil.check(PoolLimits.working_budget_for(_machine_of(16 * GIB, 0, -1, MAC, INTEGRATED), 3 * GIB, GIB / 2) == GIB / 2, "a ceiling under the floor stays the ceiling")
	TestUtil.check(PoolLimits.is_short(_machine_of(16 * GIB, int(1.5 * GIB), -1, MAC, INTEGRATED)), "1.5 of 16 GiB free is short")
	TestUtil.check(not PoolLimits.is_short(_machine_of(16 * GIB, 2 * GIB, -1, MAC, INTEGRATED)), "2 of 16 GiB free is not")
	TestUtil.check(not PoolLimits.is_short(_machine_of(-1, -1, -1, "Other", OTHER)), "nothing reported is not short")


func _read() -> MachineMemory:
	_clock_reads += 1
	return _machine


func _watch() -> void:
	var limits := PoolLimits.new()
	limits.memory_budget_bytes = int(6.4 * GIB)
	var w := MemoryWatch.new(limits, _read)
	var ceiling := int(6.4 * GIB)
	_machine = _machine_of(16 * GIB, 10 * GIB, -1, MAC, INTEGRATED)
	w.tick(0, 0)
	TestUtil.check(_near(limits.memory_budget_bytes, 5.0 * GIB) and _clock_reads == 1, "10 free, nothing held: 5 GiB, one read")
	w.tick(1000, 0)
	w.tick(4999, 0)
	TestUtil.check(_clock_reads == 1, "the timer reads once every 5 s, not per call")
	_machine = _machine_of(16 * GIB, int(1.5 * GIB), -1, MAC, INTEGRATED)
	w.before_growth(5000, GIB)
	TestUtil.check(_near(limits.memory_budget_bytes, 1.75 * GIB) and w.short and _clock_reads == 2, "free falls to 1.5, 1 held: 1.75 GiB at once, and short")
	w.before_growth(5500, GIB)
	TestUtil.check(_clock_reads == 2, "a read before a growth is at most once a second")
	_machine = _machine_of(16 * GIB, 6 * GIB, -1, MAC, INTEGRATED)
	w.tick(10000, GIB)
	TestUtil.check(_near(limits.memory_budget_bytes, 4.0 * GIB) and not w.short, "recovered to 6 free: 1 + 3 = 4 GiB (a rise of more than a tenth of the ceiling)")
	_machine = _machine_of(16 * GIB, int(6.5 * GIB), -1, MAC, INTEGRATED)
	w.tick(15000, GIB)
	TestUtil.check(_near(limits.memory_budget_bytes, 4.0 * GIB), "a small rise (0.25 GiB) is held back: hysteresis")
	_machine = _machine_of(16 * GIB, 40 * GIB, -1, MAC, INTEGRATED)
	w.tick(20000, GIB)
	TestUtil.check(limits.memory_budget_bytes == ceiling, "plenty free again: back to the ceiling")
	_machine = _machine_of(16 * GIB, int(9.9 * GIB), -1, MAC, INTEGRATED)
	w.tick(25000, GIB)
	TestUtil.check(_near(limits.memory_budget_bytes, 5.95 * GIB), "a small fall (9.9 free, 1 held: 5.95) lowers it at once too")
	_machine = null
	w.tick(30000, GIB)
	TestUtil.check(_near(limits.memory_budget_bytes, 5.95 * GIB) and w.reads == 6, "a reader that gives nothing changes nothing")
	var r := w.report()
	TestUtil.check(r["ceiling"] == ceiling and r["lowered"] == 3 and r["raised"] == 2, "the report counts the changes")


func _classes() -> void:
	var E := PoolLimits.MACHINE_ENOUGH
	var L := PoolLimits.MACHINE_LOW
	var B := PoolLimits.MACHINE_BELOW
	TestUtil.check(PoolLimits.classify(_machine_of(16 * GIB, 10 * GIB, -1, MAC, INTEGRATED)) == E, "16 GiB shared: enough")
	TestUtil.check(PoolLimits.classify(_machine_of(8 * GIB, 5 * GIB, -1, WIN, INTEGRATED)) == E, "8 GiB shared: enough (3.2 GiB budget)")
	TestUtil.check(PoolLimits.classify(_machine_of(32 * GIB, 20 * GIB, -1, WIN, DISCRETE)) == E, "discrete card, 32 GiB: enough (2 GiB budget)")
	TestUtil.check(PoolLimits.classify(_machine_of(4 * GIB, 2 * GIB, -1, WIN, INTEGRATED)) == L, "4 GiB shared: low (1.6 GiB budget)")
	TestUtil.check(PoolLimits.classify(_machine_of(-1, -1, -1, "Other", OTHER)) == L, "nothing reported: low")
	TestUtil.check(PoolLimits.classify(_machine_of(2 * GIB, 1 * GIB, -1, WIN, INTEGRATED)) == B, "2 GiB: below the minimum")
	TestUtil.check(PoolLimits.classify(_machine_of(16 * GIB, GIB / 2, -1, MAC, INTEGRATED)) == B, "16 GiB with 0.5 GiB free: below the minimum")
	TestUtil.check(PoolLimits.classify(_machine_of(3 * GIB, 2 * GIB, -1, LIN, INTEGRATED)) == L, "3 GiB with 2 free: low, not below")


func _near(a: int, b: float) -> bool:
	return absf(float(a) - b) <= 1.0
