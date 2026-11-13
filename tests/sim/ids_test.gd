extends SceneTree
## Bup ids are the world's: unique across every dish, sequential from 1, kept by a pipette, never recycled.
##
## Expected values [derived from the design: a newborn's id is the world's next id plus its rank among the
## pool's newborns in slot order; the pool's slot order is the same for a seed]:
## - a fresh world with dishes of 40, 30 and 20 founders: the founders' ids are 1..40, 41..70 and 71..90 in founder order, and the next id is 91.
## - after 200 steps of 20 s: invariants() is empty (ids unique across the three dishes), births happened (the next id is above 91), every
##   id held is below the next id, and none of the first 90 ids is held by a bup of another dish.
## - 20 steps more: every id that was not held before is at least the next id read before them (a later birth is greater than every earlier
##   id), and the next id never goes down.
## - a pipette from dish 1 moves m > 0 bups: the destination holds exactly those ids, the source holds none of them, the world's next id does
##   not change, and 100 steps later invariants() is empty again.
## - a dish frozen, stepped past and thawed holds the same ids it had, and the world's next id after the thaw is not below what it was;
##   100 steps later invariants() is empty.
## - two worlds made alike and run alike hold the same ids in every dish (determinism per seed).
## Needs a GPU (windowed).

const STEPS := 200


func _init() -> void:
	if not SimHarness.begin(self, "ids_test", "the pooled core (SimCore)"):
		return
	var h := _world()
	_fresh(h)
	h.step(100)
	_later(h)
	h.step(STEPS - 160)
	_after_births(h)
	_pipette(h)
	_freeze_thaw(h)
	_determinism()
	TestUtil.finish(self, "OK ids_test")


func _world() -> SimHarness:
	return SimHarness.make([Scenario.small(40, 600.0).seed(1), Scenario.small(30, 600.0).seed(2), Scenario.small(20, 600.0).seed(3)])


func _ids(h: SimHarness, row: int) -> PackedInt64Array:
	var recs: PackedByteArray = h.dump(row)["records"]
	var out := PackedInt64Array()
	for i in recs.size() / GpuLayout.RECORD_BYTES:
		out.append(GpuLayout.id_of(recs, i))
	return out


func _rows(h: SimHarness) -> Array:
	var rows := h.scenarios.keys()
	rows.sort()
	return rows


func _all_ids(h: SimHarness) -> Dictionary:
	var held := {}
	for row: int in _rows(h):
		for id in _ids(h, row):
			held[id] = row
	return held


func _fresh(h: SimHarness) -> void:
	var rows := _rows(h)
	var want := 1
	var in_order := true
	for row: int in rows:
		for id in _ids(h, row):
			in_order = in_order and id == want
			want += 1
	TestUtil.show(in_order and want == 91, "founders of three dishes hold ids 1..90 in founder order (ended at %d)" % want)
	TestUtil.show(h.core.next_id() == 91, "the world's next id is 91 (it is %d)" % h.core.next_id())


func _after_births(h: SimHarness) -> void:
	var next: int = h.core.next_id()
	TestUtil.show(h.invariants().is_empty(), "ids are unique across the three dishes after %d steps: %s" % [STEPS, "; ".join(h.invariants())])
	TestUtil.show(next > 91, "births happened (next id %d)" % next)
	var held := _all_ids(h)
	var below := true
	for id: int in held:
		below = below and id >= 1 and id < next
	TestUtil.show(below, "every id held is below the world's next id %d" % next)
	var founders_home := true
	var first := 1
	for row: int in _rows(h):
		for k in [40, 30, 20][_rows(h).find(row)]:
			var id: int = first + k
			if held.has(id):
				founders_home = founders_home and held[id] == row
		first += [40, 30, 20][_rows(h).find(row)]
	TestUtil.show(founders_home, "a founder id held now is held in the dish it began in")


func _later(h: SimHarness) -> void:
	var next: int = h.core.next_id()
	var held := _all_ids(h)
	h.step(60)
	var after_ids := _all_ids(h)
	var later := true
	var fresh := 0
	for id: int in after_ids:
		if not held.has(id):
			fresh += 1
			later = later and id >= next
	TestUtil.show(later and fresh > 0 and h.core.next_id() >= next, "60 steps on: %d new ids, each at least %d (every earlier id is below it); the next id is %d" % [fresh, next, h.core.next_id()])


func _pipette(h: SimHarness) -> void:
	var rows := _rows(h)
	var src: int = rows[0]
	var before := _ids(h, src)
	var next: int = h.core.next_id()
	var moved := h.pipette(src, Vector2.ZERO, 250.0)
	var dest := h.last_pipette_row
	var in_dest := _ids(h, dest)
	var in_src := _ids(h, src)
	var kept := moved > 0 and in_dest.size() == moved
	for id in in_dest:
		kept = kept and before.has(id) and not in_src.has(id)
	TestUtil.show(kept, "a pipette moved %d bups and the destination holds exactly their ids; the source holds none of them" % moved)
	TestUtil.show(h.core.next_id() == next, "a pipette takes no ids (next id %d, was %d)" % [h.core.next_id(), next])
	h.step(100)
	TestUtil.show(h.invariants().is_empty(), "ids are still unique across four dishes 100 steps after the pipette: %s" % "; ".join(h.invariants()))


func _freeze_thaw(h: SimHarness) -> void:
	var row: int = _rows(h)[1]
	var before := _ids(h, row)
	var blob: Variant = h.freeze(row)
	h.step(20)
	var next: int = h.core.next_id()
	var back := h.thaw(blob)
	TestUtil.show(_ids(h, back) == before, "a thawed dish holds the ids it had when frozen (%d bups)" % before.size())
	TestUtil.show(h.core.next_id() >= next, "thawing takes no ids (next id %d, was %d)" % [h.core.next_id(), next])
	h.step(100)
	TestUtil.show(h.invariants().is_empty(), "ids are unique 100 steps after the thaw: %s" % "; ".join(h.invariants()))


func _determinism() -> void:
	var a := _world()
	a.step(STEPS)
	var b := _world()
	b.step(STEPS)
	var same: bool = a.core.next_id() == b.core.next_id()
	for row: int in _rows(a):
		same = same and _ids(a, row) == _ids(b, row)
	TestUtil.show(same, "two worlds made alike and run alike hold the same ids in every dish (next id %d)" % a.core.next_id())
