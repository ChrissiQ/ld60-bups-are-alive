extends SceneTree
## Run: godot --headless --path . -s tests/fake_lineage_test.gd
## The fake backend's lineage seam with a real LineageStore behind it: events fed through `FakeSimBackend.feed_lineage` reach the store's
## `apply_events`, and the store answers `info`, `chain` and `living_descendants_of` from them.
## Expected [derived from the store's rules, as in lineage_store_test]: a bup of step k in a batch whose first step ends at t is stamped
## with the minute of t + k * step_seconds; a dead record with a living descendant stays, one without goes at once and frees the dead
## line above it; living_descendants_of counts the bups alive in a line, itself included.

const BIRTH_BYTES := GpuLayout.BIRTH_WORDS * 4
const DEATH_BYTES := GpuLayout.DEATH_WORDS * 4
const DISH := 1


func _init() -> void:
	var store := LineageStore.new()
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	var fake := FakeSimBackend.new()
	fake.lineage = store
	var a1 := _id(1)
	var a2 := _id(2)
	var a3 := _id(3)

	# Iteration 1: a founder and two generations born at minute 10 (a2 and a3 in step 3: 600 + 60 s = minute 11).
	fake.feed_lineage(_births([_birth(a1, 0), _birth(a2, a1, 3, 1), _birth(a3, a2, 3, 2)]), PackedByteArray(), 600.0, 20.0)
	var i2 := store.info(a2)
	TestUtil.check(store.record_count() == 3, "three records after the births")
	TestUtil.check(i2["parent"] == a1 and i2["born"] == 11 and i2["divisions"] == 1 and i2["alive"] and i2["home"] == DISH, "info(a2): parent a1, born at minute 11, 1 division, alive, home 1")
	TestUtil.check(store.info(a1)["born"] == 10, "info(a1): born at minute 10 (step 0)")
	TestUtil.check(store.chain(a3) == PackedInt64Array([a1, a2, a3]), "chain(a3) is [a1, a2, a3], oldest first")
	TestUtil.check(store.living_descendants_of(PackedInt64Array([a1, a2, a3])) == PackedInt32Array([3, 2, 1]), "living_descendants_of [a1, a2, a3] is [3, 2, 1]")

	# Iteration 2: a3 dies at step 0 of a batch whose first step ends at minute 30. It has no descendants, so its record goes.
	fake.feed_lineage(PackedByteArray(), _deaths([_death(a3, 0)]), 1800.0, 20.0)
	TestUtil.check(not store.has_record(a3) and store.info(a3).is_empty() and store.chain(a3).is_empty(), "a3's record is freed at its death")
	TestUtil.check(store.chain(a2) == PackedInt64Array([a1, a2]) and store.living_descendants_of(PackedInt64Array([a1, a2])) == PackedInt32Array([2, 1]), "chain(a2) is [a1, a2]; living_descendants_of [a1, a2] is [2, 1]")

	# Iteration 3: a1 dies at step 2 of a batch ending at minute 40 (died = int((2400 + 40) / 60) = 40). a2 lives, so a1's record stays, dead.
	fake.feed_lineage(PackedByteArray(), _deaths([_death(a1, 2)]), 2400.0, 20.0)
	var i1 := store.info(a1)
	TestUtil.check(store.has_record(a1) and not i1["alive"] and i1["died"] == 40, "a1 is dead at minute 40 and kept for its living descendant")
	TestUtil.check(store.chain(a2) == PackedInt64Array([a1, a2]) and store.living_descendants_of(PackedInt64Array([a1, a2])) == PackedInt32Array([1, 1]), "chain(a2) is still [a1, a2]; living_descendants_of [a1, a2] is [1, 1]")

	# Iteration 4: a2 dies, nothing alive holds the line, both records go.
	fake.feed_lineage(PackedByteArray(), _deaths([_death(a2, 0)]), 3000.0, 20.0)
	TestUtil.check(store.record_count() == 0, "no record stays when the last bup of the line dies")

	TestUtil.check(fake.calls.is_empty(), "with a store set, feed_lineage logs no lineage_pending call")
	var plain := FakeSimBackend.new()
	plain.feed_lineage(PackedByteArray(), PackedByteArray(), 0.0, 20.0)
	TestUtil.check(plain.calls.size() == 1 and plain.calls[0]["kind"] == &"lineage_pending", "without a store it logs one lineage_pending call")
	TestUtil.finish(self, "FAKE LINEAGE TEST OK")


static func _id(counter: int) -> int:
	return (DISH << GpuLayout.ID_DISH_SHIFT) | counter


static func _births(list: Array) -> PackedByteArray:
	var b := PackedByteArray()
	for e: PackedByteArray in list:
		b.append_array(e)
	return b


static func _deaths(list: Array) -> PackedByteArray:
	return _births(list)


static func _birth(id: int, parent: int, step := 0, divisions := 0) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(BIRTH_BYTES)
	e.encode_u32(GpuLayout.EB_ID_LO * 4, id & 0xFFFFFFFF)
	e.encode_u32(GpuLayout.EB_ID_HI * 4, id >> 32)
	e.encode_u32(GpuLayout.EB_PARENT_LO * 4, parent & 0xFFFFFFFF)
	e.encode_u32(GpuLayout.EB_PARENT_HI * 4, parent >> 32)
	e.encode_u32(GpuLayout.EB_STEP * 4, step)
	e.encode_u32(GpuLayout.EB_DIVISIONS * 4, divisions)
	return e


static func _death(id: int, step := 0) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(DEATH_BYTES)
	e.encode_u32(GpuLayout.ED_ID_LO * 4, id & 0xFFFFFFFF)
	e.encode_u32(GpuLayout.ED_ID_HI * 4, id >> 32)
	e.encode_u32(GpuLayout.ED_STEP * 4, GpuLayout.death_step_word(step, DISH))
	e.encode_float(GpuLayout.ED_MASS * 4, 6.0)
	return e
