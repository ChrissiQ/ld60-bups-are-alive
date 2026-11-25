extends SceneTree
## Run: godot --headless --path . -s tests/pool_growth_test.gd
## What the arena's growth calls decide when the grown size does not fit the memory budget, headless (no device: only the answers that make
## no buffers, so no remake runs). Every budget below is the bytes `estimate_bytes` gives for a chosen set of capacities, so what fits is known
## by construction. Caps: 4096 slots, 65536 cells and bins, 1024 clouds and husks, 12288 entries, 1024 events.
## Expected values [derived from SimArena.GROW 1.5, FILL 0.9 and the 256-slot alignment]:
##  - a growth never makes a class smaller: with the budget at exactly what the buffers hold, so that no growth fits, an ask that is over FILL
##    of the class but within it (4000 slots, 1000 clouds, 12000 entries, 1000 husks) is answered true and the capacity stays (4096, 1024,
##    12288, 1024), with no growth counted;
##  - past the class (an ask over its capacity) when the growth by 1.5 does not fit but the ask does, the class grows once to the most that
##    fits, a multiple of 256 slots, between the ask and the growth by 1.5: 5000 slots (aligned 5120; the growth by 1.5 is 6144) with the budget
##    at the bytes of 5632 slots answer 5632 (the bytes grow with every 256 slots, so 5888 is over);
##  - a reserve (what the classes grown after the slots are asked for) keeps room for them: with 1,100 cloud slots reserved (their buffers and
##    entries cost less than one step of 256 slots) the answer is one step lower, 5376; with a reserve the budget cannot hold at all the ask
##    itself is answered, 5120, so a reserve cannot refuse what the budget alone would grow;
##  - when not even the ask fits (8000 slots) the answer is 0 and the capacity stays;
##  - the largest buffer still bounds a growth to the most that fits: with a budget far above the total, 18,000,000 slots asked (room for them
##    over FILL is 20,000,000, 2.24 GB in one buffer) answer the most that fits under BUFFER_MOST: 2 GiB at 112 bytes a slot is 19,173,961
##    slots, 19,173,888 as a multiple of 256.
const GIB := 1024 * 1024 * 1024


func _init() -> void:
	_never_smaller()
	_most_that_fits()
	_reserve()
	_buffer_bound()
	TestUtil.finish(self, "OK pool_growth_test")


func _arena() -> SimArena:
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
	return arena


func _held(arena: SimArena, slots: int, clouds := 0) -> int:
	var cloud_room := maxi(clouds, arena.cloud_cap)
	return arena.estimate_bytes(slots, arena.cell_cap, arena.bin_cap, cloud_room, arena.husk_cap, arena.event_cap, maxi(arena.entry_cap, GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_room))


func _never_smaller() -> void:
	var arena := _arena()
	arena.limits.memory_budget_bytes = _held(arena, arena.slot_cap)
	TestUtil.check(arena.slot_cap_for(4000) == 4096, "no growth fits: 4000 slots keep the 4096")
	TestUtil.check(arena.ensure_slots(4000) and arena.slot_cap == 4096, "ensure_slots(4000) is true and the capacity stays")
	TestUtil.check(arena.ensure_clouds(1000) and arena.cloud_cap == 1024, "ensure_clouds(1000) is true and the capacity stays")
	TestUtil.check(arena.ensure_husks(1000) and arena.husk_cap == 1024, "ensure_husks(1000) is true and the capacity stays")
	TestUtil.check(arena.ensure_entries(12000) and arena.entry_cap == 12288, "ensure_entries(12000) is true and the capacity stays")
	TestUtil.check(arena.growths.is_empty() and arena.shrinks.is_empty() and arena.flushes == 0, "nothing was grown, shrunk or flushed")
	TestUtil.check(not arena.ensure_slots(8000) and arena.slot_cap == 4096, "8000 slots do not fit: refused, the capacity stays")


func _most_that_fits() -> void:
	var arena := _arena()
	arena.limits.memory_budget_bytes = _held(arena, 5632)
	TestUtil.check(arena.slot_cap_for(5000) == 5632, "5000 slots, a budget for 5632: the most that fits, 5632 (not the growth by 1.5, 6144)")
	TestUtil.check(arena.slot_cap_for(5632) == 5632, "an ask of exactly what fits is answered with it")
	TestUtil.check(arena.slot_cap_for(5700) == 0, "an ask past the most that fits (5700, aligned 5888): 0")


func _reserve() -> void:
	var arena := _arena()
	arena.limits.memory_budget_bytes = _held(arena, 5632)
	TestUtil.check(arena.slot_cap_for(5000, 0, {"cloud": 1100}) == 5376, "1,100 clouds reserved: one step of 256 slots lower, 5376")
	TestUtil.check(arena.slot_cap_for(5000, 0, {"cloud": 1000000}) == 5120, "a reserve the budget cannot hold: the ask itself, 5120")
	TestUtil.check(arena.slot_cap_for(5000, 0, {}) == 5632, "no reserve: 5632")


func _buffer_bound() -> void:
	var arena := _arena()
	var most := arena.slot_cap_for(18000000)
	TestUtil.check(most == 19173888, "18,000,000 slots asked, room over FILL is past a buffer's most: grows to 19,173,888 (got %d)" % most)
	TestUtil.check(arena.fits(most, 0, 0, 0, 0) and not arena.fits(most + 256, 0, 0, 0, 0), "it is the most that fits: one step more does not")
