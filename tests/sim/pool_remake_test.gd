extends SceneTree
## Run: tools/run_windowed.sh <outfile> -- --path . -s tests/sim/pool_remake_test.gd
## What a remake of a class does to the device's buffer memory (`SimArena._remake`), read from the device itself
## (`RenderingDevice.get_memory_usage(MEMORY_BUFFERS)`) before each flush and after it, and at the end. Windowed (a local device).
## It skips, with the reason, where the device's figure cannot show a remake: it must count a buffer as soon as it is made, keep counting it
## after `free_rid` until the next submit and wait, and drop it then.
##
## Expected values [derived from `_remake`'s order and the BUFFERS table; D0 is the device's buffer bytes before the remake; sizes are
## rounded up to 16 bytes, so each figure is compared within TOL]:
##  - a remake of the slot classes (16384 slots held, 15000 asked: grown by 1.5 to 24576) makes 6 flushes: the buffers that are not kept
##    freed (1), each of the four kept ones (BUPS, BUPS2, BLKDISH, BLKDISH2) made, copied and its old one freed (4), the others made (1);
##  - read as offsets from D0, before the first flush the device holds 0 (a free waits for its flush) and after it minus the not-kept
##    buffers' old bytes; before the flush of a kept buffer, what it held after the flush before plus the new copy (the old one is still
##    counted), and after it that less the old copy; before and after the last flush, the figure after the kept ones plus the not-kept
##    buffers' new bytes, which is the class's new total less its old total;
##  - so the most the device holds in a remake of a grown class is its final total (D0 plus the class's growth): the not-kept buffers
##    freed first cover the kept ones' old copies. An order that frees at the next wait would hold D0 plus the class's whole new size;
##  - a read after the remake equals the last figure, and equals it again after one more submit and wait: nothing is left waiting to free;
##  - a remake of the entries (neither buffer kept; held 196608, asked 186777: grown by 1.5 to 294912) makes 2 flushes: offsets 0 then
##    minus the old bytes before and after the first, minus the old and then plus the growth before and after the second;
##  - the peak `_sequence_peak` gives for each class grown by 1.5 from the limits' sizes is its final total (the figure printed per class,
##    in the INFO lines): every kept buffer's step stays under it;
##  - through the budget, with it at the bytes of 26,624 slots and 24,576 held: 24,000 asked keep the 24,576 (true, no remake, no flush);
##    26,000 asked grow once to 26,624, the most that fits (6 flushes, the second growth counted); 26,400 asked, within that, keep it;
##    27,000 asked are refused, nothing changes; no shrink is counted;
##  - the husks, with the budget at the bytes of 5000 husks and 4096 held: 4000 asked keep them (no flush); 4600 asked grow once to 5000
##    (3 flushes: the freed five, HUSK made, the five made);
##  - the clouds, 16384 held, budget at 20,000: 17,000 asked grow once to 20,000 (3 flushes; the entries need no more than they hold);
##  - the entries, budget at 5000 more than held: an ask within the held keeps them; an ask 1000 past them grows once to the held plus 5000
##    (2 flushes).
## What it cannot show: the device's figure is what the device was asked to hold, not what the driver keeps resident (a driver may keep a freed
## block for reuse); that a backend whose wait can time out has finished the work when `_flush` returns; and the pictures' buffers
## (`ensure_draw` releases first in the same way and is not read here).

const MIB := 1048576
const TOL := 65536
const SLOTS_FROM := 16384
const SLOTS_ASKED := 15000
const SLOTS_TO := 24576


## An arena whose flushes read the device's buffer bytes before and after, as [before, after] a flush.
class ProbeArena extends SimArena:
	var marks: Array = []

	func _flush() -> void:
		var before := rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)
		super()
		marks.append([before, rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)])


func _init() -> void:
	if not SimHarness.begin(self, "pool_remake_test", "the pooled core (SimCore)"):
		return
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		SimHarness.skip(self, "pool_remake_test", "no local rendering device", "a window")
		return
	var why := _figure_problem(rd)
	if why != "":
		SimHarness.skip(self, "pool_remake_test", why, "a driver whose buffer memory figure follows a free at the next submit and wait")
		return
	var limits := PoolLimits.new()
	var arena := ProbeArena.new(rd, limits)
	arena.make_all({})
	rd.submit()
	rd.sync()
	_peaks(arena)
	_slots_remake(rd, arena)
	_entries_remake(rd, arena)
	_budgeted(arena, limits)
	arena.free_all()
	TestUtil.finish(self, "OK pool_remake_test")


func _usage(rd: RenderingDevice) -> int:
	return rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)


## "" when the device's figure counts a made buffer at once, still counts it after `free_rid`, and drops it after a submit and wait; else
## what it did not do.
func _figure_problem(rd: RenderingDevice) -> String:
	var n := 64 * MIB
	var d0 := _usage(rd)
	var rid := rd.storage_buffer_create(n)
	var made_at_once := _usage(rd) - d0
	rd.buffer_clear(rid, 0, n)
	rd.submit()
	rd.sync()
	var made := _usage(rd) - d0
	rd.free_rid(rid)
	var freed := _usage(rd) - d0
	rd.submit()
	rd.sync()
	var after := _usage(rd) - d0
	print("INFO device buffer memory, as bytes over before: made %+d, made and submitted %+d, freed (before a wait) %+d, after a wait %+d" % [made_at_once, made, freed, after])
	if made_at_once < n - TOL or made < n - TOL:
		return "the device's buffer memory figure did not count a made buffer (%d and %d of %d bytes)" % [made_at_once, made, n]
	if freed < n - TOL:
		return "the figure dropped at free_rid, so the wait for a free cannot be seen (%d of %d bytes still counted)" % [freed, n]
	if after > TOL:
		return "the figure did not drop after a submit and wait (%d bytes left)" % after
	return ""


static func _r16(n: int) -> int:
	return maxi(16, ((n + 15) / 16) * 16)


## The bytes of buffer `nm` of the slot classes and the entries at these capacities, as `_make_sized` makes it.
static func _bytes(nm: String, slots: int, entries: int) -> int:
	var e: Array = SimArena.BUFFERS[nm]
	var unit: int = e[1]
	match e[0]:
		"slot": return _r16(slots * unit)
		"block": return _r16((slots / GpuLayout.BLK_SLOTS + 1) * unit)
		"bucket": return _r16(GpuKernelsLife.conj_buckets(slots) * unit)
		"bucketbits": return _r16((GpuKernelsLife.conj_buckets(slots) / 32 + 1) * unit)
		"entry": return _r16(entries * unit)
	return 0


## Checks one remake against the order's figures. `classes` are the classes remade; `from_*` the capacities before, the arena's the ones after.
func _check_remake(label: String, rd: RenderingDevice, arena: ProbeArena, classes: Array, from_slots: int, from_entries: int, d0: int, flushes0: int) -> void:
	var kept: Array[String] = []
	var scratch: Array[String] = []
	for nm: String in SimArena.BUFFERS:
		var e: Array = SimArena.BUFFERS[nm]
		if classes.has(e[0]):
			(kept if e[2] else scratch).append(nm)
	var scratch_old := 0
	var scratch_new := 0
	for nm in scratch:
		scratch_old += _bytes(nm, from_slots, from_entries)
		scratch_new += _bytes(nm, arena.slot_cap, arena.entry_cap)
	var class_old := scratch_old
	var class_new := scratch_new
	var expected: Array = [[0, -scratch_old]]  # offsets from D0: [before the flush, after it]
	var held := -scratch_old
	for nm in kept:
		var old_bytes := _bytes(nm, from_slots, from_entries)
		var new_bytes := _bytes(nm, arena.slot_cap, arena.entry_cap)
		class_old += old_bytes
		class_new += new_bytes
		expected.append([held + new_bytes, held + new_bytes - old_bytes])
		held += new_bytes - old_bytes
	expected.append([held + scratch_new, held + scratch_new])
	var made := arena.flushes - flushes0
	TestUtil.show(made == expected.size() and arena.marks.size() == expected.size(), "%s: %d flushes (expected %d)" % [label, made, expected.size()])
	var peak := -scratch_old
	var matches := true
	for k in mini(arena.marks.size(), expected.size()):
		var got_before: int = arena.marks[k][0] - d0
		var got_after: int = arena.marks[k][1] - d0
		peak = maxi(peak, got_before)
		if absi(got_before - int(expected[k][0])) > TOL or absi(got_after - int(expected[k][1])) > TOL:
			matches = false
			print("  flush %d: before %+d (expected %+d), after %+d (expected %+d)" % [k, got_before, expected[k][0], got_after, expected[k][1]])
	TestUtil.show(matches, "%s: the device held what the order says before and after every flush" % label)
	var final_offset := class_new - class_old
	TestUtil.show(peak <= maxi(final_offset, 0) + TOL, "%s: most held %+.2f MB over before; the class's growth is %+.2f MB, an order that frees at the next wait would hold %+.2f MB" % [label, peak / float(MIB), final_offset / float(MIB), class_new / float(MIB)])
	TestUtil.show(absi((_usage(rd) - d0) - final_offset) <= TOL, "%s: after the remake the device holds %+.2f MB over before (expected %+.2f)" % [label, (_usage(rd) - d0) / float(MIB), final_offset / float(MIB)])
	rd.submit()
	rd.sync()
	TestUtil.show(absi((_usage(rd) - d0) - final_offset) <= TOL, "%s: one more submit and wait changes nothing" % label)


func _slots_remake(rd: RenderingDevice, arena: ProbeArena) -> void:
	var d0 := _usage(rd)
	arena.marks.clear()
	var flushes0 := arena.flushes
	var entries := arena.entry_cap
	arena.ensure_slots(SLOTS_ASKED)
	TestUtil.show(arena.slot_cap == SLOTS_TO and int(arena.growths.get("slot", 0)) == 1, "%d slots asked: grown once from %d to %d (got %d)" % [SLOTS_ASKED, SLOTS_FROM, SLOTS_TO, arena.slot_cap])
	_check_remake("slots", rd, arena, SimArena.SLOT_CLASSES, SLOTS_FROM, entries, d0, flushes0)


func _entries_remake(rd: RenderingDevice, arena: ProbeArena) -> void:
	var d0 := _usage(rd)
	arena.marks.clear()
	var flushes0 := arena.flushes
	var from := arena.entry_cap
	arena.ensure_entries(int(from * 0.95))
	TestUtil.show(arena.entry_cap == int(from * 1.5), "entries asked over FILL: grown by 1.5 (%d to %d)" % [from, arena.entry_cap])
	_check_remake("entries", rd, arena, ["entry"], arena.slot_cap, from, d0, flushes0)


## The peak of the sequence, for each class grown by 1.5 from the arena's sizes, against its final total.
func _peaks(arena: ProbeArena) -> void:
	var now := arena.estimate_bytes(arena.slot_cap, arena.cell_cap, arena.bin_cap, arena.cloud_cap, arena.husk_cap, arena.event_cap, arena.entry_cap)
	var cases := {
		"slot": [int(arena.slot_cap * 1.5), 0, 0, 0, 0, 0, 0],
		"cell": [0, arena.cell_cap / 2, 0, 0, 0, 0, 0],
		"bin": [0, 0, arena.bin_cap / 2, 0, 0, 0, 0],
		"cloud": [0, 0, 0, int(arena.cloud_cap * 1.5), 0, 0, 0],
		"husk": [0, 0, 0, 0, int(arena.husk_cap * 1.5), 0, 0],
		"entry": [0, 0, 0, 0, 0, 0, int(arena.entry_cap * 1.5)],
		"event": [0, 0, 0, 0, 0, int(arena.event_cap * 1.5), 0],
	}
	for cls: String in cases:
		var c: Array = cases[cls]
		var want := [maxi(c[0], arena.slot_cap), arena.cell_cap + c[1], arena.bin_cap + c[2], maxi(c[3], arena.cloud_cap), maxi(c[4], arena.husk_cap), maxi(c[5], arena.event_cap), maxi(c[6], arena.entry_cap)]
		var final_total := arena.estimate_bytes(want[0], want[1], want[2], want[3], want[4], want[5], want[6])
		var peak := arena._sequence_peak(want)
		print("INFO peak %s: held %.2f MB, final %.2f MB, sequence peak %.2f MB" % [cls, now / float(MIB), final_total / float(MIB), peak / float(MIB)])
		TestUtil.show(absi(peak - final_total) <= TOL, "%s grown by 1.5: the sequence's peak is the final total" % cls)


## The bytes at the arena's capacities with these classes raised (the way `_fits` counts them).
func _est(arena: ProbeArena, slots: int, husks := 0, clouds := 0, entries := 0) -> int:
	var cloud_room := maxi(clouds, arena.cloud_cap)
	return arena.estimate_bytes(slots, arena.cell_cap, arena.bin_cap, cloud_room, maxi(husks, arena.husk_cap), arena.event_cap, maxi(maxi(entries, arena.entry_cap), GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_room))


func _budgeted(arena: ProbeArena, limits: PoolLimits) -> void:
	limits.memory_budget_bytes = _est(arena, 26624)
	var flushes := arena.flushes
	TestUtil.show(arena.ensure_slots(24000) and arena.slot_cap == SLOTS_TO and arena.flushes == flushes and int(arena.growths.get("slot", 0)) == 1, "24000 slots asked with no room for the growth: the %d kept, no remake" % SLOTS_TO)
	TestUtil.show(arena.ensure_slots(26000) and arena.slot_cap == 26624 and arena.flushes == flushes + 6 and int(arena.growths.get("slot", 0)) == 2, "26000 asked: grown once to the most that fits, 26624 (got %d, %d flushes)" % [arena.slot_cap, arena.flushes - flushes])
	flushes = arena.flushes
	TestUtil.show(arena.ensure_slots(26400) and arena.slot_cap == 26624 and arena.flushes == flushes, "26400 asked, within it: kept, no remake")
	TestUtil.show(not arena.ensure_slots(27000) and arena.slot_cap == 26624 and arena.flushes == flushes, "27000 asked: refused, nothing changed")
	TestUtil.show(arena.shrinks.is_empty(), "no shrink was counted")
	limits.memory_budget_bytes = _est(arena, arena.slot_cap, 5000)
	flushes = arena.flushes
	TestUtil.show(arena.ensure_husks(4000) and arena.husk_cap == 4096 and arena.flushes == flushes, "4000 husks asked: the 4096 kept")
	TestUtil.show(arena.ensure_husks(4600) and arena.husk_cap == 5000 and arena.flushes == flushes + 3, "4600 husks asked: grown once to the most that fits, 5000 (got %d, %d flushes)" % [arena.husk_cap, arena.flushes - flushes])
	limits.memory_budget_bytes = _est(arena, arena.slot_cap, 0, 20000)
	flushes = arena.flushes
	TestUtil.show(arena.ensure_clouds(17000) and arena.cloud_cap == 20000 and arena.flushes == flushes + 3 and int(arena.growths.get("cloud", 0)) == 1, "17000 clouds asked: grown once to the most that fits, 20000 (got %d, %d flushes)" % [arena.cloud_cap, arena.flushes - flushes])
	var entry_most := arena.entry_cap + 5000
	limits.memory_budget_bytes = _est(arena, arena.slot_cap, 0, 0, entry_most)
	flushes = arena.flushes
	var entries_held := arena.entry_cap
	TestUtil.show(arena.ensure_entries(entries_held - 100) and arena.entry_cap == entries_held and arena.flushes == flushes, "entries asked within the held: kept")
	TestUtil.show(arena.ensure_entries(entries_held + 1000) and arena.entry_cap == entry_most and arena.flushes == flushes + 2, "entries asked past the held: grown once to the most that fits, %d (got %d, %d flushes)" % [entry_most, arena.entry_cap, arena.flushes - flushes])
	TestUtil.show(arena.shrinks.is_empty(), "no shrink was counted in the end")
