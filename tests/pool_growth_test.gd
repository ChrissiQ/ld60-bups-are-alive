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
##    slots, 19,173,888 as a multiple of 256;
##  - which path a remake of the slot classes (4096 slots held, 6144 made) takes is decided by `SimArena._fits_unflushed`, the budget against
##    `_unflushed_peak`: the bytes held now (every buffer's size, set here as `make_all` would) plus the bytes freed and not yet released
##    (`_pending_free`) plus every new buffer of the classes. Held H, the classes' old bytes O and new bytes N (N less O is the class's
##    growth; every figure within TOL of the unrounded sums, since each buffer is made at least 16 bytes and a multiple of 16):
##      the peak is H + N, and H + N + p with p bytes pending;
##      with the budget at the final total H + N - O plus TOL, where both copies cannot be held, the unflushed remake does not fit (it takes
##      the ordered path, which `_sequence_peak` bounds): O is some hundreds of kilobytes, far over TOL;
##      with the budget at H + N plus TOL it fits;
##      with O bytes pending (an earlier remake's old buffers not yet released) the same budget no longer fits, and fits again after
##      `synced()`, which sets the pending bytes to 0. The windowed `tests/sim/pool_remake_test.gd` makes the remakes themselves on a device.
const GIB := 1024 * 1024 * 1024
const TOL := 1024


func _init() -> void:
	_never_smaller()
	_most_that_fits()
	_reserve()
	_buffer_bound()
	_remake_path()
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


func _remake_path() -> void:
	var arena := _arena()
	for nm: String in SimArena.BUFFERS:
		arena.sizes[nm] = SimArena._rounded(arena._bytes_of(nm))
	var held := arena.bytes_now()
	var old_class := 0
	for nm: String in SimArena.BUFFERS:
		if SimArena.SLOT_CLASSES.has(SimArena.BUFFERS[nm][0]):
			old_class += int(arena.sizes[nm])
	var before := arena.estimate_bytes(4096, arena.cell_cap, arena.bin_cap, arena.cloud_cap, arena.husk_cap, arena.event_cap, arena.entry_cap)
	var after := arena.estimate_bytes(6144, arena.cell_cap, arena.bin_cap, arena.cloud_cap, arena.husk_cap, arena.event_cap, arena.entry_cap)
	var new_class := after - before + old_class
	arena.slot_cap = 6144  # (`_remake` is called with the new capacity already set)
	var classes: Array = SimArena.SLOT_CLASSES
	TestUtil.check(old_class > 100 * TOL, "the slot classes' old bytes are far over the tolerance (%d)" % old_class)
	TestUtil.check(absi(arena._unflushed_peak(classes) - (held + new_class)) <= TOL, "no bytes pending: the peak is the held plus the new buffers (%d, expected %d)" % [arena._unflushed_peak(classes), held + new_class])
	arena._pending_free = 5000
	TestUtil.check(absi(arena._unflushed_peak(classes) - (held + new_class + 5000)) <= TOL, "5000 bytes pending are added to the peak")
	arena._pending_free = 0
	arena.limits.memory_budget_bytes = held + new_class - old_class + TOL
	TestUtil.check(not arena._fits_unflushed(classes), "a budget at the final total: both copies do not fit, the remake is ordered")
	arena.limits.memory_budget_bytes = held + new_class + TOL
	TestUtil.check(arena._fits_unflushed(classes), "a budget at the held plus the new buffers: the remake is unflushed")
	arena._pending_free = old_class
	TestUtil.check(not arena._fits_unflushed(classes), "the old buffers of an earlier remake still pending: the same budget no longer fits")
	arena.synced()
	TestUtil.check(arena._pending_free == 0 and arena._fits_unflushed(classes), "after synced() nothing is pending and it fits again")
