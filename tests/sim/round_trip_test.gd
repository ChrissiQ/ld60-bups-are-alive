extends SceneTree
## The pipette and the freezer move bups and dishes without changing them.
##
## Expected values, written before the first run:
## - a pipette of radius 150 µm at (0, 0) in a dish of 40 founders after 60 steps moves some number m of bups (m reported, > 0) into a
##   new dish (the pipette's); the reply equals DS_MOVED_OUT of the source and DS_MOVED_IN of the new dish
##   (moved_out == moved_in == m) [derived: the retarget pass counts each move twice, once at each end].
## - the bups moved keep their ids, genes and reach words (records compared by id, words R_SPEED..R_REACH) and their positions are
##   shifted by exactly the pipette centre in float32 (centre (0,0): unchanged) [derived].
## - no bup is made or lost: the source's ids before the pass are, after it, the source's and the new dish's, with none in both and none
##   new; the counts are n - m and m, and the stats the pass ends with count them (ST_COUNT) [derived: the pass moves records only].
## - into a dish that is there (row 1, after 60 steps of its one founder), a pipette of radius 300 µm at (150, 0): the destination's
##   records are its own first, unchanged and in their order, then the moved bups in the source's order (by id); DS_MOVED_IN is the
##   reply; its next id keeps its own number and its counter is past every moved bup's [derived: pool_pip_final, pool_pip_scatter].
## - freeze then thaw gives a dish whose records, field, clouds, husks, DS words (but the start) and stats equal the dump just before
##   the freeze, word for word [derived: `gather` reads what `load_dish` writes back].
## - the family tree across the pipette, the freeze, the thaw and the trash (no export or import: one shared LineageStore) is checked in
##   the game build, where the store is: tools/gpu/game_check.gd `edits`.
## Needs a GPU. Windowed only.

const COMPARED := ["records", "field", "clouds", "husks", "dstate", "stats"]


func _init() -> void:
	if not SimHarness.begin(self, "round_trip_test", "SimCore"):
		return
	var s := Scenario.small(40, 600.0).seed(8)
	var h := SimHarness.make([s, Scenario.small(1, 600.0).seed(9)], {"tally": true}).step(60)
	var source_before := h.dump(0)
	var src_count_before := h.count(0)
	var ids_before := _ids(source_before["records"])
	var moved := h.pipette(0, Vector2.ZERO, 150.0)
	var dest := h.last_pipette_row
	TestUtil.show(moved > 0 and dest >= 0, "the pipette moved %d bups into a new dish (row %d)" % [moved, dest])
	h.step(0)
	var ds := h.dstate(0)
	TestUtil.show(ds[GpuLayout.DS_MOVED_OUT] == moved, "DS_MOVED_OUT %d equals the reply %d" % [ds[GpuLayout.DS_MOVED_OUT], moved])
	TestUtil.show(h.dstate(dest)[GpuLayout.DS_MOVED_IN] == moved, "DS_MOVED_IN %d of the new dish equals the reply %d" % [h.dstate(dest)[GpuLayout.DS_MOVED_IN], moved])
	TestUtil.show(h.count(0) == src_count_before - moved, "the source lost %d bups" % moved)
	TestUtil.show(h.count(dest) == moved, "the new dish holds the %d" % moved)
	var src_ids := _ids(h.dump(0)["records"])
	var dst_ids := _ids(h.dump(dest)["records"])
	var both := 0
	for id: int in src_ids:
		if dst_ids.has(id):
			both += 1
	var union := src_ids.duplicate()
	union.append_array(dst_ids)
	union.sort()
	var want := ids_before.duplicate()
	want.sort()
	TestUtil.show(both == 0 and union == want, "the source's ids before are the source's and the new dish's after, none in both, none new (%d in both)" % both)
	for row: int in [0, dest]:
		var st: PackedByteArray = h.dump(row)["stats"]
		TestUtil.show(int(st.decode_float(GpuLayout.ST_COUNT * 4)) == h.count(row), "the stats after the pass count row %d's %d bups (ST_COUNT %d)" % [row, h.count(row), int(st.decode_float(GpuLayout.ST_COUNT * 4))])
	_moved_bups_unchanged(source_before["records"], h.dump(dest)["records"], moved)
	_into_a_dish_there(h)
	var d_before := h.dump(dest)
	var blob: Variant = h.freeze(dest)
	var thawed := h.thaw(blob)
	var d_after := h.dump(thawed)
	TestUtil.show(thawed >= 0 and h.count(thawed) == moved, "the thawed dish has its %d bups" % moved)
	for section: String in COMPARED:
		var line := SimHarness.diff({section: d_before[section]}, {section: d_after[section]})
		TestUtil.show(line == "", "after the freeze and the thaw the dish's %s are as before%s" % [section, ": " + line if line != "" else ""])
	TestUtil.finish(self, "OK round_trip_test (the family tree's part: tools/gpu/game_check.gd edits)")


static func _ids(records: PackedByteArray) -> Array:
	var out := []
	for i in records.size() / GpuLayout.RECORD_BYTES:
		out.append(GpuLayout.id_of(records, i))
	return out


## The existing-destination path: row 1's own bups first, then the moved ones in the source's order.
func _into_a_dish_there(h: SimHarness) -> void:
	var own: PackedByteArray = h.dump(1)["records"]
	var own_count := own.size() / GpuLayout.RECORD_BYTES
	var src_before := _ids(h.dump(0)["records"])
	var moved := h.pipette(0, Vector2(150.0, 0.0), 300.0, 1)
	var src_after := _ids(h.dump(0)["records"])
	var went := []
	for id: int in src_before:
		if not src_after.has(id):
			went.append(id)
	var after: PackedByteArray = h.dump(1)["records"]
	TestUtil.show(moved > 0 and moved == went.size() and h.dstate(1)[GpuLayout.DS_MOVED_IN] == moved, "a pipette into row 1 moved %d bups (left the source %d, DS_MOVED_IN %d)" % [moved, went.size(), h.dstate(1)[GpuLayout.DS_MOVED_IN]])
	TestUtil.show(after.slice(0, own.size()) == own, "row 1's own %d bups come first, unchanged and in their order" % own_count)
	var ids := _ids(after)
	TestUtil.show(ids.slice(own_count) == went, "then the moved bups, in the source's order")
	var world_next: int = h.core.next_id()
	var most := 0
	for id: int in went:
		most = maxi(most, id)
	TestUtil.show(world_next > most, "the world's next id %d is past the moved bups' %d, and the moved bups kept their ids" % [world_next, most])


## Every record of the destination that is also in the source (by id) keeps its genes and reach, and its position (the centre is 0, 0).
func _moved_bups_unchanged(before: PackedByteArray, after: PackedByteArray, moved: int) -> void:
	var by_id := {}
	for i in before.size() / GpuLayout.RECORD_BYTES:
		by_id[GpuLayout.id_of(before, i)] = i
	var found := 0
	for j in after.size() / GpuLayout.RECORD_BYTES:
		var i: int = by_id.get(GpuLayout.id_of(after, j), -1)
		if i < 0:
			continue
		found += 1
		var words := [GpuLayout.R_X, GpuLayout.R_Y]
		words.append_array(range(GpuLayout.R_SPEED, GpuLayout.R_REACH + 1))
		for w in words:
			var a := before.decode_u32(i * GpuLayout.RECORD_BYTES + w * 4)
			var b := after.decode_u32(j * GpuLayout.RECORD_BYTES + w * 4)
			TestUtil.check(a == b, "moved bup %d word %d (%s) changed: 0x%08x -> 0x%08x" % [GpuLayout.id_of(after, j), w, CanonicalDump.word_name("records", w), a, b])
	TestUtil.show(found == moved, "%d of the %d moved bups found by id in the destination" % [found, moved])
