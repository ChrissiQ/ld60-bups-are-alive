extends SceneTree
## Run: godot --headless --path . -s tests/pool_limits_test.gd
## The pool's memory budget worked out from what a machine reports (MachineMemory, PoolLimits.budget_for, working_budget_for, MemoryWatch),
## headless, with made-up machines. Expected values
## [derived from BUDGET_SHARE 0.4, BUDGET_FLOOR 1 GiB, DISCRETE_BUDGET 2 GiB, GROW_SHARE 0.5, SHORT_FREE_SHARE 0.1]:
##  - what a machine has free is `free` on Windows and macOS (never the engine's `available`: Windows' commit limit, macOS's free swap
##    added), `MemAvailable` on Linux when it is read, else `free`; a figure the engine gives as -1 is unknown;
##  - 16 GiB shared: 0.4 x 16 = 6.4 GiB; 8 GiB shared: 3.2 GiB; 64 GiB shared: 25.6 GiB (no upper cap); 2 GiB: the 1 GiB floor;
##  - memory of its own (discrete) or an adapter not known: CARD_SHARE 0.75 of what the card reports, its OS budget when given, else its
##    dedicated memory (8 GiB card, no budget: 6 GiB; 8 GiB card, the OS gives 7: 5.25 GiB; 16.08 GiB card on 32 GiB: 12.06 GiB; 24 GiB card, the OS gives 22, on 32 GiB: 0.4 x 32 = 12.8 GiB), and never over
##    0.4 of the physical memory (8 GiB card on 8 GiB: 3.2 GiB); a card whose size is not read: the 2 GiB default;
##  - on a card with a live budget and usage (usage counts what the pool holds), the working budget is held + 0.75 x (budget - usage):
##    7 budget, 2 used, 1 held: 1 + 3.75 = 4.75; the system's free memory is then not used;
##  - physical memory not reported: the floor;
##  - working budget = held + 0.5 x free, between the floor and the ceiling: 6.4 ceiling, 1 held, 10 free: 6.0; 2 free: 2.0; 0.2 free: the floor;
##    free not reported: the ceiling; short when free is under a tenth of physical;
##  - the watch lowers the working budget at once and raises it only when the figure has come back by a tenth of the ceiling or reaches the ceiling;
##    it reads on its timer (5 s) and before a growth (at most once a second), and never per call;
##  - a single buffer never passes `SimArena.BUFFER_MOST` (2 GiB): record slots are 112 bytes, so 19,000,000 slots (2.13 GB) fit and 20,000,000 (2.24 GB) do not;
##    list entries are 32 bytes, so 60,000,000 fit (1.92 GB) and 70,000,000 do not (2.24 GB); each with a budget far above the total, so only the buffer's size refuses.
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
	_cards()
	_working()
	_watch()
	_classes()
	_buffer_most()
	TestUtil.check(PoolLimits.new().memory_budget_bytes == 6 * GIB, "the tests' default budget is unchanged")
	var started := PoolLimits.from_settings()
	TestUtil.check(started.memory_budget_bytes >= PoolLimits.BUDGET_FLOOR, "from_settings gives a budget of at least the floor")
	TestUtil.check(PoolLimits.warning_state({"memory_need_fraction": 0.9}) == PoolLimits.WARN_NEAR and PoolLimits.warning_state({"memory_need_fraction": 0.89}) == "", "the warning stays at 0.9 of the budget, of what the dishes need")
	TestUtil.check(PoolLimits.warning_state({"memory_fraction": 0.99, "memory_need_fraction": 0.3}) == "", "a pool that holds 0.99 of the budget but is needed at 0.3 gives no warning")
	TestUtil.finish(self, "OK pool_limits_test")


func _machine_of(physical: int, free: int, available: int, os_name: String, adapter: int, linux_available := -1, card := {}) -> MachineMemory:
	return MachineMemory.from_report({"physical": physical, "free": free, "available": available, "stack": -1}, os_name, adapter, linux_available, card)


func _card(dedicated: int, budget := 0, usage := 0, api := "dxgi") -> Dictionary:
	return {"known": true, "dedicated": dedicated, "budget": budget, "usage": usage, "api": api}


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
	TestUtil.check(_near(PoolLimits.budget_for(_machine_of(64 * GIB, 50 * GIB, -1, WIN, INTEGRATED)), 25.6 * GIB), "64 GiB shared: 0.4 x 64, no cap")
	TestUtil.check(PoolLimits.budget_for(_machine_of(32 * GIB, 20 * GIB, -1, WIN, DISCRETE)) == 2 * GIB, "a discrete card of unknown size, 32 GiB of system memory: 2 GiB")
	TestUtil.check(PoolLimits.budget_for(_machine_of(32 * GIB, 20 * GIB, -1, LIN, OTHER)) == 2 * GIB, "an adapter not known: 2 GiB")
	TestUtil.check(_near(PoolLimits.budget_for(_machine_of(4 * GIB, 2 * GIB, -1, WIN, DISCRETE)), 1.6 * GIB), "a discrete card of unknown size, 4 GiB of system memory: 0.4 x 4")
	TestUtil.check(PoolLimits.budget_for(_machine_of(2 * GIB, 1 * GIB, -1, WIN, INTEGRATED)) == GIB, "2 GiB: the floor")
	TestUtil.check(PoolLimits.budget_for(_machine_of(-1, -1, -1, "Other", OTHER)) == GIB, "nothing reported: the floor")
	TestUtil.check(PoolLimits.budget_for(_machine_of(-1, 4 * GIB, -1, "Other", INTEGRATED)) == GIB, "no physical memory: the floor")


func _cards() -> void:
	var win := func(card: Dictionary, physical := 32 * GIB) -> MachineMemory: return _machine_of(physical, physical / 2, -1, WIN, DISCRETE, -1, card)
	var m: MachineMemory = win.call(_card(8 * GIB, 7 * GIB, 2 * GIB))
	TestUtil.check(m.card_dedicated == 8 * GIB and m.card_budget == 7 * GIB and m.card_usage == 2 * GIB and m.card_api == "dxgi", "the card's figures are kept")
	TestUtil.check(_near(PoolLimits.budget_for(m), 5.25 * GIB), "8 GiB card, the system gives 7: 0.75 x 7")
	TestUtil.check(_near(PoolLimits.budget_for(win.call(_card(8 * GIB))), 6.0 * GIB), "8 GiB card, no system budget: 0.75 x 8")
	TestUtil.check(_near(PoolLimits.budget_for(win.call(_card(24 * GIB, 22 * GIB))), 12.8 * GIB), "24 GiB card on 32 GiB: 0.4 x 32, under 0.75 x 22")
	TestUtil.check(_near(PoolLimits.budget_for(win.call(_card(16 * GIB, int(16.08 * GIB)))), 0.75 * int(16.08 * GIB)), "16.08 GiB card budget on 32 GiB: 0.75 x 16.08, about 12 GiB, not 8")
	TestUtil.check(_near(PoolLimits.budget_for(win.call(_card(8 * GIB), 8 * GIB)), 3.2 * GIB), "8 GiB card on 8 GiB of system memory: 0.4 x 8")
	TestUtil.check(PoolLimits.budget_for(win.call(_card(1 * GIB))) == GIB, "a 1 GiB card: the floor")
	TestUtil.check(PoolLimits.budget_for(win.call({"known": false})) == 2 * GIB, "a card of unknown size: 2 GiB")
	TestUtil.check(PoolLimits.budget_for(win.call({"known": true, "dedicated": 0, "budget": 0, "usage": 0, "api": "dxgi"})) == 2 * GIB, "a card that reports 0: unknown")
	var mac := _machine_of(16 * GIB, 10 * GIB, -1, MAC, INTEGRATED, -1, {"known": false})
	TestUtil.check(mac.card_dedicated == -1 and mac.card_api == "" and _near(PoolLimits.budget_for(mac), 6.4 * GIB), "a Mac: no card figures, 0.4 of the memory it shares")
	var shared := _machine_of(16 * GIB, 10 * GIB, -1, WIN, INTEGRATED, -1, _card(512 * 1024 * 1024))
	TestUtil.check(_near(PoolLimits.budget_for(shared), 6.4 * GIB), "an integrated adapter's small dedicated figure does not count: its memory is the system's")
	var unknown_type := _machine_of(16 * GIB, 10 * GIB, -1, LIN, OTHER, -1, _card(12 * GIB, 0, 0, "vulkan"))
	TestUtil.check(unknown_type.shared == 0 and _near(PoolLimits.budget_for(unknown_type), 6.4 * GIB), "an adapter type not given but a card size read: a card (0.75 x 12 = 9, held to 0.4 x 16)")
	TestUtil.check(m.card_usage == 2 * GIB and _machine_of(16 * GIB, 8 * GIB, -1, LIN, DISCRETE, -1, _card(8 * GIB, 0, 3 * GIB, "vulkan")).card_usage == -1, "a usage without a budget is not kept")
	var live: MachineMemory = win.call(_card(8 * GIB, 7 * GIB, 2 * GIB))
	TestUtil.check(_near(PoolLimits.working_budget_for(live, GIB, 6 * GIB), 4.75 * GIB), "live card: 1 held + 0.75 x (7 - 2)")
	TestUtil.check(PoolLimits.working_budget_for(live, GIB, int(4.5 * GIB)) == int(4.5 * GIB), "held to the ceiling")
	live.card_usage = 7 * GIB
	TestUtil.check(PoolLimits.working_budget_for(live, 3 * GIB, 6 * GIB) == 3 * GIB, "the card full: what the pool holds")
	live.card_usage = 8 * GIB
	TestUtil.check(PoolLimits.working_budget_for(live, 0, 6 * GIB) == GIB, "over its budget: the floor")
	var nolive: MachineMemory = win.call(_card(8 * GIB))
	TestUtil.check(PoolLimits.working_budget_for(nolive, GIB, 6 * GIB) == 6 * GIB and PoolLimits.working_budget_for(nolive, GIB, 6 * GIB) != PoolLimits.working_budget_for(live, GIB, 6 * GIB), "no live card figures: the system's free memory decides (16 GiB free: the ceiling)")
	var w := _watch_card()
	TestUtil.check(w, "the watch follows a card's live budget")


func _watch_card() -> bool:
	var limits := PoolLimits.new()
	limits.memory_budget_bytes = int(5.25 * GIB)
	var m := _machine_of(32 * GIB, 16 * GIB, -1, WIN, DISCRETE, -1, _card(8 * GIB, 7 * GIB, 1 * GIB))
	_machine = m
	var w := MemoryWatch.new(limits, _read)
	w.tick(0, GIB)
	var ok := limits.memory_budget_bytes == int(5.25 * GIB)  # 1 + 0.75 x 6 = 5.5, held to the ceiling 5.25
	_machine = _machine_of(32 * GIB, 16 * GIB, -1, WIN, DISCRETE, -1, _card(8 * GIB, 4 * GIB, 3 * GIB))  # another program took the card's memory
	w.tick(5000, GIB)
	ok = ok and _near(limits.memory_budget_bytes, 1.75 * GIB)  # 1 + 0.75 x 1
	return ok


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
	_clock_reads = 0
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
	TestUtil.check(PoolLimits.classify(_machine_of(32 * GIB, 20 * GIB, -1, WIN, DISCRETE)) == L, "discrete card of unknown size, 32 GiB: low (2 GiB budget, under the 3 GiB the largest dish needs)")
	TestUtil.check(PoolLimits.classify(_machine_of(4 * GIB, 2 * GIB, -1, WIN, INTEGRATED)) == L, "4 GiB shared: low (1.6 GiB budget)")
	TestUtil.check(PoolLimits.classify(_machine_of(-1, -1, -1, "Other", OTHER)) == L, "nothing reported: low")
	TestUtil.check(PoolLimits.classify(_machine_of(2 * GIB, 1 * GIB, -1, WIN, INTEGRATED)) == B, "2 GiB: below the minimum")
	TestUtil.check(PoolLimits.classify(_machine_of(16 * GIB, GIB / 2, -1, MAC, INTEGRATED)) == B, "16 GiB with 0.5 GiB free: below the minimum")
	TestUtil.check(PoolLimits.classify(_machine_of(3 * GIB, 2 * GIB, -1, LIN, INTEGRATED)) == L, "3 GiB with 2 free: low, not below")


func _buffer_most() -> void:
	var limits := PoolLimits.new()
	limits.memory_budget_bytes = 256 * GIB
	var arena := SimArena.new(null, limits)
	arena.slot_cap = 4096
	arena.cell_cap = 65536
	arena.bin_cap = 65536
	arena.cloud_cap = 1024
	arena.husk_cap = 1024
	arena.entry_cap = 12288
	arena.event_cap = 1024
	TestUtil.check(arena.fits(19000000, 0, 0, 0, 0), "19,000,000 slots (112 bytes each, 2.13 GB) fit")
	TestUtil.check(not arena.fits(20000000, 0, 0, 0, 0), "20,000,000 slots (2.24 GB in one buffer) do not")
	TestUtil.check(arena.fits(0, 0, 0, 0, 0, 0, 60000000), "60,000,000 entries (32 bytes each, 1.92 GB) fit")
	TestUtil.check(not arena.fits(0, 0, 0, 0, 0, 0, 70000000), "70,000,000 entries (2.24 GB in one buffer) do not")
	TestUtil.check(not arena.ensure_slots(20000000) and arena.slot_cap == 4096, "a growth of the record slots past it is refused and nothing changes")
	TestUtil.check(not arena.ensure_entries(70000000) and arena.entry_cap == 12288, "a growth of the entries past it is refused and nothing changes")


func _near(a: int, b: float) -> bool:
	return absf(float(a) - b) <= 1.0
