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
## Two paths ([derived from `_remake`: it makes every buffer without a wait when the bytes held, the bytes freed and not yet released and every
## new buffer fit the budget, and takes the order above otherwise]). The ordered checks above and below run with the budget at the remake's
## final total plus TOL: both copies cannot be held (the class's old bytes are megabytes, far over TOL), the final total fits, so `ordered_remakes`
## counts each of them and `fast_remakes` none (6 ordered remakes in all, 0 fast). With the budget at 6 GiB, far over everything:
##  - the slots remake (16384 held, 15000 asked, 24576 made) makes no flush, counts one `fast_remakes` and no `ordered_remakes`, and the
##    device holds, read as an offset from D0 before any wait, the class's new total (its old buffers are still counted, which is why the
##    peak may not pass the budget unchecked); `_pending_free` is the class's old bytes; after one submit and wait the device holds the new total
##    less the old, and `synced()` sets `_pending_free` to 0;
##  - its data is what the ordered path leaves: each kept buffer holds the old bytes (a pattern written before, one prime-length block repeated,
##    distinct per buffer) and then its fill byte (0 or 0xFF), each other buffer is all fill, and every buffer of the class equals the one the
##    ordered path made, byte for byte;
##  - two remakes in a row with no wait between (slots, then entries; H held at the start, N1 the slot classes' new bytes, NE the entries' new
##    bytes; the budget H + N1 + NE - TOL): the first passes unflushed (peak H + N1), the second would hold H + N1 + NE (the first's old buffers
##    still pending), over the budget by TOL, so it takes the ordered path (2 flushes, `_pending_free` 0 after it): the device never holds more than
##    N1 over before, and the budget bounds it. With a submit and wait and `synced()` between, the second passes unflushed too (H + N1 - O1 + NE
##    fits): 0 flushes, 2 fast remakes, 0 ordered.
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
	rd.submit()
	rd.sync()
	_fast_remake(rd)
	_stacking(rd, false)
	_stacking(rd, true)
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
	arena.limits.memory_budget_bytes = _est(arena, SLOTS_TO) + TOL  # (the final total: both copies do not fit, so the ordered path)
	arena.ensure_slots(SLOTS_ASKED)
	TestUtil.show(arena.slot_cap == SLOTS_TO and int(arena.growths.get("slot", 0)) == 1, "%d slots asked: grown once from %d to %d (got %d)" % [SLOTS_ASKED, SLOTS_FROM, SLOTS_TO, arena.slot_cap])
	TestUtil.show(arena.ordered_remakes == 1 and arena.fast_remakes == 0, "slots: the ordered path ran (ordered %d, fast %d)" % [arena.ordered_remakes, arena.fast_remakes])
	_check_remake("slots", rd, arena, SimArena.SLOT_CLASSES, SLOTS_FROM, entries, d0, flushes0)


func _entries_remake(rd: RenderingDevice, arena: ProbeArena) -> void:
	var d0 := _usage(rd)
	arena.marks.clear()
	var flushes0 := arena.flushes
	var from := arena.entry_cap
	arena.limits.memory_budget_bytes = _est(arena, arena.slot_cap, 0, 0, int(from * 1.5)) + TOL
	arena.ensure_entries(int(from * 0.95))
	TestUtil.show(arena.entry_cap == int(from * 1.5), "entries asked over FILL: grown by 1.5 (%d to %d)" % [from, arena.entry_cap])
	TestUtil.show(arena.ordered_remakes == 2 and arena.fast_remakes == 0, "entries: the ordered path ran (ordered %d, fast %d)" % [arena.ordered_remakes, arena.fast_remakes])
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
	TestUtil.show(arena.ordered_remakes == 6 and arena.fast_remakes == 0, "every remake of these tests took the ordered path (ordered %d, fast %d)" % [arena.ordered_remakes, arena.fast_remakes])


## The bytes of the buffers of `classes` (slot classes and the entries) at these capacities, as `_make_sized` makes them.
static func _class_bytes(classes: Array, slots: int, entries: int) -> int:
	var total := 0
	for nm: String in SimArena.BUFFERS:
		if classes.has(SimArena.BUFFERS[nm][0]):
			total += _bytes(nm, slots, entries)
	return total


## `n` bytes of one block of 4093 bytes (a prime, so a copy that lands at a wrong offset shows) repeated, different for each `seed`.
static func _pattern(n: int, seed: int) -> PackedByteArray:
	var block := PackedByteArray()
	block.resize(4093)
	for i in 4093:
		block[i] = (i * 7 + seed) & 0xFF
	var out := PackedByteArray()
	while out.size() < n:
		out.append_array(block)
	out.resize(n)
	return out


## One remake of the slot classes from SLOTS_FROM to SLOTS_TO on a fresh arena whose kept buffers hold a pattern, under `budget`
## (0: the 6 GiB of PoolLimits). Returns what it counted and every buffer of the classes as it ended.
func _slots_run(rd: RenderingDevice, budget: int) -> Dictionary:
	var limits := PoolLimits.new()
	var arena := ProbeArena.new(rd, limits)
	arena.make_all({})
	var patterns := {}
	for nm: String in SimArena.BUFFERS:
		var e: Array = SimArena.BUFFERS[nm]
		if SimArena.SLOT_CLASSES.has(e[0]) and e[2]:
			patterns[nm] = _pattern(int(arena.sizes[nm]), nm.hash())
			rd.buffer_update(arena.buf(nm), 0, (patterns[nm] as PackedByteArray).size(), patterns[nm])
	rd.submit()
	rd.sync()
	if budget > 0:
		limits.memory_budget_bytes = budget
	else:
		budget = limits.memory_budget_bytes
	var d0 := _usage(rd)
	arena.marks.clear()
	var entries := arena.entry_cap
	arena.ensure_slots(SLOTS_ASKED)
	var out := {"slot_cap": arena.slot_cap, "flushes": arena.flushes, "marks": arena.marks.size(), "fast": arena.fast_remakes, "ordered": arena.ordered_remakes,
			"pending": arena._pending_free, "held": _usage(rd) - d0, "patterns": patterns, "entries": entries, "data": {}}
	rd.submit()
	rd.sync()
	out["held_after_wait"] = _usage(rd) - d0
	arena.synced()
	out["pending_after_synced"] = arena._pending_free
	for nm: String in SimArena.BUFFERS:
		if SimArena.SLOT_CLASSES.has(SimArena.BUFFERS[nm][0]):
			out["data"][nm] = rd.buffer_get_data(arena.buf(nm))
	arena.free_all()
	rd.submit()
	rd.sync()
	return out


func _fast_remake(rd: RenderingDevice) -> void:
	var fast := _slots_run(rd, 0)
	var probe_limits := PoolLimits.new()
	var probe := ProbeArena.new(rd, probe_limits)
	probe.make_all({})
	probe.slot_cap = SLOTS_TO
	var tight := probe.estimate_bytes(SLOTS_TO, probe.cell_cap, probe.bin_cap, probe.cloud_cap, probe.husk_cap, probe.event_cap, probe.entry_cap) + TOL
	probe.free_all()
	rd.submit()
	rd.sync()
	var ordered := _slots_run(rd, tight)
	var class_old := _class_bytes(SimArena.SLOT_CLASSES, SLOTS_FROM, int(fast["entries"]))
	var class_new := _class_bytes(SimArena.SLOT_CLASSES, SLOTS_TO, int(fast["entries"]))
	TestUtil.show(fast["slot_cap"] == SLOTS_TO and ordered["slot_cap"] == SLOTS_TO, "both arenas grew the slots to %d" % SLOTS_TO)
	TestUtil.show(fast["flushes"] == 0 and fast["marks"] == 0 and fast["fast"] == 1 and fast["ordered"] == 0, "plenty of room: no flush, one fast remake (flushes %d, fast %d, ordered %d)" % [fast["flushes"], fast["fast"], fast["ordered"]])
	TestUtil.show(ordered["flushes"] == 6 and ordered["fast"] == 0 and ordered["ordered"] == 1, "no room for both copies: the ordered path, 6 flushes (flushes %d, fast %d, ordered %d)" % [ordered["flushes"], ordered["fast"], ordered["ordered"]])
	TestUtil.show(absi(int(fast["held"]) - class_new) <= TOL, "fast: before any wait the device holds the new total, the old buffers still counted (%+.2f MB, expected %+.2f)" % [int(fast["held"]) / float(MIB), class_new / float(MIB)])
	TestUtil.show(absi(int(fast["held_after_wait"]) - (class_new - class_old)) <= TOL, "fast: after one submit and wait the old ones are gone (%+.2f MB, expected %+.2f)" % [int(fast["held_after_wait"]) / float(MIB), (class_new - class_old) / float(MIB)])
	TestUtil.show(absi(int(fast["pending"]) - class_old) <= TOL, "fast: the pending bytes are the class's old bytes (%d, expected %d)" % [fast["pending"], class_old])
	TestUtil.show(fast["pending_after_synced"] == 0 and ordered["pending"] == 0, "synced() clears the pending bytes, and an ordered remake leaves none")
	var same := true
	var as_derived := true
	for nm: String in SimArena.BUFFERS:
		var e: Array = SimArena.BUFFERS[nm]
		if not SimArena.SLOT_CLASSES.has(e[0]):
			continue
		if (fast["data"][nm] as PackedByteArray) != (ordered["data"][nm] as PackedByteArray):
			same = false
			print("  %s differs between the paths" % nm)
		var want := PackedByteArray()
		want.resize(_bytes(nm, SLOTS_TO, int(fast["entries"])))
		want.fill(e[3])
		if e[2]:
			var old: PackedByteArray = fast["patterns"][nm]
			for i in old.size():
				want[i] = old[i]
		if (fast["data"][nm] as PackedByteArray) != want:
			as_derived = false
			print("  %s is not the old bytes then the fill" % nm)
	TestUtil.show(same, "every buffer of the class is byte for byte what the ordered path made")
	TestUtil.show(as_derived, "each kept buffer is the old bytes then its fill, each other buffer is all fill")


## Slots then entries with no wait between (or, with `wait`, a submit and wait and `synced()` between).
func _stacking(rd: RenderingDevice, wait: bool) -> void:
	var label := "synced between" if wait else "no wait between"
	var limits := PoolLimits.new()
	var arena := ProbeArena.new(rd, limits)
	arena.make_all({})
	rd.submit()
	rd.sync()
	var d0 := _usage(rd)
	var held := arena.bytes_now()
	var entries_to := int(arena.entry_cap * 1.5)
	var old_slots := _class_bytes(SimArena.SLOT_CLASSES, SLOTS_FROM, arena.entry_cap)
	var old_entries := _class_bytes(["entry"], SLOTS_FROM, arena.entry_cap)
	var new_slots := _class_bytes(SimArena.SLOT_CLASSES, SLOTS_TO, arena.entry_cap)
	var new_entries := _class_bytes(["entry"], SLOTS_TO, entries_to)
	var budget := held + new_slots + new_entries - TOL
	limits.memory_budget_bytes = budget
	arena.marks.clear()
	arena.ensure_slots(SLOTS_ASKED)
	TestUtil.show(arena.slot_cap == SLOTS_TO and arena.fast_remakes == 1 and arena.ordered_remakes == 0 and arena.flushes == 0, "%s: the first remake is unflushed (fast %d, ordered %d, flushes %d)" % [label, arena.fast_remakes, arena.ordered_remakes, arena.flushes])
	TestUtil.show(absi(arena._pending_free - old_slots) <= TOL, "%s: its old buffers are pending (%d, expected %d)" % [label, arena._pending_free, old_slots])
	var peak := _usage(rd) - d0
	if wait:
		rd.submit()
		rd.sync()
		arena.synced()
		TestUtil.show(arena._pending_free == 0, "%s: nothing pending after synced()" % label)
	arena.ensure_entries(int(arena.entry_cap * 0.95))
	TestUtil.show(arena.entry_cap == entries_to, "%s: the entries grew by 1.5 (%d)" % [label, arena.entry_cap])
	if wait:
		TestUtil.show(arena.fast_remakes == 2 and arena.ordered_remakes == 0 and arena.flushes == 0, "%s: the second remake is unflushed too (fast %d, ordered %d, flushes %d)" % [label, arena.fast_remakes, arena.ordered_remakes, arena.flushes])
		peak = maxi(peak, _usage(rd) - d0)
	else:
		TestUtil.show(arena.fast_remakes == 1 and arena.ordered_remakes == 1 and arena.flushes == 2, "%s: the second remake takes the ordered path, 2 flushes (fast %d, ordered %d, flushes %d)" % [label, arena.fast_remakes, arena.ordered_remakes, arena.flushes])
		TestUtil.show(arena._pending_free == 0, "%s: its flush leaves nothing pending" % label)
		for m: Array in arena.marks:
			peak = maxi(peak, int(m[0]) - d0)
		TestUtil.show(held + new_slots + new_entries > budget, "%s: unflushed it would have held %+.2f MB over before, more than the budget allows (%+.2f)" % [label, (new_slots + new_entries) / float(MIB), (budget - held) / float(MIB)])
	TestUtil.show(peak <= budget - held + TOL, "%s: the device never held more than the budget allows (most %+.2f MB over before, allowed %+.2f)" % [label, peak / float(MIB), (budget - held) / float(MIB)])
	rd.submit()
	rd.sync()
	var expected := new_slots - old_slots + new_entries - old_entries
	TestUtil.show(absi((_usage(rd) - d0) - expected) <= TOL, "%s: at the end the device holds %+.2f MB over before (expected %+.2f)" % [label, (_usage(rd) - d0) / float(MIB), expected / float(MIB)])
	arena.free_all()
	rd.submit()
	rd.sync()
