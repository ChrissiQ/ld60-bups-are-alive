extends SceneTree
## Run: godot --headless --path . -s tests/lineage_store_test.gd
## LineageStore (native/src/lineage_store.cpp), the family tree on its own, apart from any BupSim:
##  - the two event streams captured at pre-pool (tools/gpu/golden/lineage_*), replayed into a store that starts from the stream's
##    initial records, give the final records of the capture, compared by id (the order of an export's records is not stable);
##  - a pre-pool export (golden/parity/lineage_export.bin.gz) imported into an empty store exports the same records;
##  - the cases of a pipette, freeze, thaw and trash on a store holding two or three dishes:
##    the running dish that holds a frozen dish's shared bup leaves): export_dish, release_dish, discard_frozen, the idempotent
##    import_bytes, the tombstones.
## Expected values are derived in each function's comment from the rules of the store: a replay applies the very events the capture
## applied, so every record equals the capture's field for field; the dish cases are worked out from the family trees built here.

const GOLDEN := "res://tools/gpu/golden/"
const RECORD_BYTES := 88
const BIRTH_BYTES := GpuLayout.BIRTH_WORDS * 4
const DEATH_BYTES := GpuLayout.DEATH_WORDS * 4

const A := 1  ## dish numbers of the synthetic cases
const A2 := 2
const C := 3


func _init() -> void:
	_replay("lineage_E_seed1")
	_replay("lineage_F_seed2_traits")
	_parity_import()
	_events_and_queries()
	_case_a_pipette_freeze_thaw()
	_case_b_shared_ancestor_changes_while_frozen()
	_case_c_same_blob_twice()
	_case_d_trash_after_pipette()
	_case_e_closure()
	_case_f_pruned_while_frozen()
	_case_g_discard_frozen()
	_case_h_holder_leaves_while_frozen()
	_pins_and_retarget()
	TestUtil.finish(self, "LINEAGE STORE TEST OK")


# ---- a store as the game makes one --------------------------------------------------------------------------------

static func _new_store() -> LineageStore:
	var store := LineageStore.new()
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	return store


## An export's records by id (their 88 bytes each) and its names by id.
static func _parse(bytes: PackedByteArray) -> Dictionary:
	var records := {}
	var names := {}
	var count := bytes.decode_u32(0)
	for i in count:
		var at := 4 + i * RECORD_BYTES
		records[bytes.decode_s64(at)] = bytes.slice(at, at + RECORD_BYTES)
	var at := 4 + count * RECORD_BYTES
	var name_count := bytes.decode_u32(at)
	at += 4
	for i in name_count:
		var id := bytes.decode_s64(at)
		var length := bytes.decode_u32(at + 8)
		names[id] = bytes.slice(at + 12, at + 12 + length).get_string_from_utf8()
		at += 12 + length
	return {"records": records, "names": names}


## Whether two exports hold the same records and names, and the first thing that differs if not.
static func _same_by_id(got: PackedByteArray, want: PackedByteArray) -> String:
	var g := _parse(got)
	var w := _parse(want)
	if g["records"].size() != w["records"].size():
		return "%d records, expected %d" % [g["records"].size(), w["records"].size()]
	for id: int in w["records"]:
		if not g["records"].has(id):
			return "record %d is missing" % id
		if g["records"][id] != w["records"][id]:
			var a: PackedByteArray = g["records"][id]
			var b: PackedByteArray = w["records"][id]
			for k in RECORD_BYTES:
				if a[k] != b[k]:
					return "record %d differs at byte %d" % [id, k]
	if g["names"] != w["names"]:
		return "the names differ"
	return ""


static func _living_ids(bytes: PackedByteArray) -> PackedInt64Array:
	var out := PackedInt64Array()
	var records: Dictionary = _parse(bytes)["records"]
	for id: int in records:
		if (records[id] as PackedByteArray).decode_s32(8 + 8 + 4) < 0:
			out.append(id)
	return out


# ---- the pre-pool streams -----------------------------------------------------------------------------------------

## The stream of `name`, applied to a store that starts from its initial records. Expected [derived]: the capture's BupSim applied
## these births, deaths, pins and names with the code that LineageStore keeps, so every record of the final export is the capture's,
## byte for byte by id, with the same names; and the record, living and pinned counts of the _final.txt.
func _replay(stem: String) -> void:
	var path := GOLDEN + stem
	var facts := {}
	for line in FileAccess.get_file_as_string(path + "_final.txt").split("\n", false):
		var kv := line.split("=")
		facts[kv[0]] = kv[1] if kv.size() > 1 else ""
	var initial := FileAccess.get_file_as_bytes(path + "_initial.bin")
	var store := _new_store()
	store.import_bytes(initial, PackedInt64Array(), _living_ids(initial), 0)
	TestUtil.check(store.export_bytes().size() == initial.size() and _same_by_id(store.export_bytes(), initial) == "", "%s: the initial records import unchanged" % stem)
	var f := FileAccess.open_compressed(path + "_events.bin", FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	f.big_endian = false
	var ops := int(facts["ops"])
	var batches := 0
	var births := 0
	var deaths := 0
	for i in ops:
		match f.get_8():
			0:
				var end := f.get_double()
				var step := f.get_double()
				var nb := f.get_32()
				var nd := f.get_32()
				var b := f.get_buffer(nb)
				var d := f.get_buffer(nd)
				store.apply_events(b, d, end, step)
				batches += 1
				births += nb / BIRTH_BYTES
				deaths += nd / DEATH_BYTES
			1:
				store.pin(f.get_64(), 1)
			2:
				var id := f.get_64()
				store.set_custom_name(id, f.get_buffer(f.get_32()).get_string_from_utf8())
	var problem := _same_by_id(store.export_bytes(), FileAccess.get_file_as_bytes(path + "_final.bin"))
	TestUtil.check(problem == "", "%s: the replay gives the capture's final records by id (%s)" % [stem, problem])
	TestUtil.check(store.record_count() == int(facts["records"]), "%s: %d records (capture %s)" % [stem, store.record_count(), facts["records"]])
	TestUtil.check(store.alive_ids().size() == int(facts["alive"]), "%s: %d alive (capture %s)" % [stem, store.alive_ids().size(), facts["alive"]])
	TestUtil.check(batches == int(facts["batches"]) and births == int(facts["births"]) and deaths == int(facts["deaths"]), "%s: the stream's batches, births and deaths are the capture's" % stem)
	for id in facts["pinned"].split(" ", false):
		TestUtil.check(store.holds(int(id)) >= 1, "%s: pinned id %s is held" % [stem, id])


## A pre-pool export of a dish with husks (golden/parity/lineage_export.txt: 254 records, 250 alive). Expected [derived]: every
## dead record in an export of a live sim has a living descendant or a pin, so an import with the living ids prunes nothing: 254 records
## again, the same by id.
func _parity_import() -> void:
	var f := FileAccess.open_compressed(GOLDEN + "parity/lineage_export.bin.gz", FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	var bytes := f.get_buffer(f.get_length())
	var store := _new_store()
	var living := _living_ids(bytes)
	store.import_bytes(bytes, PackedInt64Array(), living, 0)
	TestUtil.check(living.size() == 250 and store.record_count() == 254, "the parity export imports to 254 records, 250 alive (%d, %d)" % [store.record_count(), living.size()])
	TestUtil.check(_same_by_id(store.export_bytes(), bytes) == "", "the parity export comes back the same by id")


# ---- the events and the queries -------------------------------------------------------------------------------------

static func _id(dish: int, counter: int) -> int:
	return (dish << GpuLayout.ID_DISH_SHIFT) | counter


## A birth event: the genes follow from the id so that each record is its own.
static func _birth(id: int, parent: int, step := 0, divisions := 0) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(BIRTH_BYTES)
	e.encode_u32(GpuLayout.EB_ID_LO * 4, id & 0xFFFFFFFF)
	e.encode_u32(GpuLayout.EB_ID_HI * 4, id >> 32)
	e.encode_u32(GpuLayout.EB_PARENT_LO * 4, parent & 0xFFFFFFFF)
	e.encode_u32(GpuLayout.EB_PARENT_HI * 4, parent >> 32)
	e.encode_u32(GpuLayout.EB_STEP * 4, step)
	e.encode_u32(GpuLayout.EB_DIVISIONS * 4, divisions)
	e.encode_u32(GpuLayout.EB_TRAITS * 4, 3 | (5 << 20) | (1 << 30))
	var k := float(id & 0xFFFF)
	for w in 4:
		e.encode_float((GpuLayout.EB_SPEED + w) * 4, 1.0 + k + w)
	e.encode_float(GpuLayout.EB_HUE * 4, 0.25)
	e.encode_float(GpuLayout.EB_SAT * 4, 0.5)
	e.encode_float(GpuLayout.EB_VAL * 4, 0.75)
	e.encode_float(GpuLayout.EB_HARM * 4, 0.125)
	e.encode_float(GpuLayout.EB_MUTATOR * 4, 2.0)
	return e


static func _death(id: int, dish: int, step := 0, mass := 6.0) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(DEATH_BYTES)
	e.encode_u32(GpuLayout.ED_ID_LO * 4, id & 0xFFFFFFFF)
	e.encode_u32(GpuLayout.ED_ID_HI * 4, id >> 32)
	e.encode_u32(GpuLayout.ED_STEP * 4, GpuLayout.death_step_word(step, dish))
	e.encode_u32(GpuLayout.ED_TRAITS * 4, 7 | (9 << 20))
	e.encode_float(GpuLayout.ED_MASS * 4, mass)
	e.encode_float(GpuLayout.ED_ENERGY * 4, 1.5)
	e.encode_float(GpuLayout.ED_BIRTH_MASS * 4, 4.0)
	for w in 4:
		e.encode_float((GpuLayout.ED_SPEED + w) * 4, 10.0 + w)
	return e


## Births at minute `minute` of the store's clock (a batch of one step that ends there).
static func _born(store: LineageStore, minute: int, list: Array) -> void:
	var b := PackedByteArray()
	for e: PackedByteArray in list:
		b.append_array(e)
	store.apply_events(b, PackedByteArray(), minute * 60.0, 20.0)


static func _died(store: LineageStore, minute: int, list: Array) -> void:
	var d := PackedByteArray()
	for e: PackedByteArray in list:
		d.append_array(e)
	store.apply_events(PackedByteArray(), d, minute * 60.0, 20.0)


## Births and deaths. Expected [derived]: a record is stamped with the minute of its step (a step k of a batch ending at t ends at t + k * 20 s);
## a death keeps the genes and figures of the event, the reserve it could hold is RESERVE_PER_MASS * mass, the dish number in the death's
## step word is the record's home and leaves the step's place alone; a dead record with a living descendant stays and one without goes,
## and the parents it leaves unheld with it.
func _events_and_queries() -> void:
	var store := _new_store()
	var a1 := _id(A, 1)
	var a2 := _id(A, 2)
	var a3 := _id(A, 3)
	_born(store, 10, [_birth(a1, 0), _birth(a2, a1, 3, 1), _birth(a3, a2, 3, 2)])
	var r2 := store.info(a2)
	TestUtil.check(r2["born"] == int((10 * 60.0 + 3 * 20.0) / 60.0) and r2["parent"] == a1 and r2["divisions"] == 1 and r2["alive"] and r2["home"] == A, "a birth is stamped with its step's minute, with its parent and its dish")
	TestUtil.check(r2["donor"] and r2["reach"] == 5 and r2["mutations"] == 3 and is_equal_approx(r2["mutator"], 2.0), "a birth's packed word gives the F factor, the reach word and the mutations")
	TestUtil.check(store.chain(a3) == PackedInt64Array([a1, a2, a3]) and store.holds(a1) == 1, "the chain is the oldest first; a parent is held by its child")
	_born(store, 11, [_birth(a2, 0)])
	TestUtil.check(store.info(a2)["parent"] == a1 and store.record_count() == 3, "a birth given again is passed over")
	_died(store, 20, [_death(a2, C, 2, 6.5)])
	var d := store.info(a2)
	TestUtil.check(not d["alive"] and d["died"] == int((20 * 60.0 + 40.0) / 60.0) and d["home"] == C, "a death is stamped with its step's minute (the step word's low bits) and sets the home from its dish bits")
	TestUtil.check(is_equal_approx(d["max_energy"], Cell.RESERVE_PER_MASS * 6.5) and d["mass"] == 6.5 and d["energy"] == 1.5 and d["birth_mass"] == 4.0 and d["reach"] == 9 and d["size_gene"] == 13.0 and d["divisions"] == 7, "a death keeps the figures of the event")
	TestUtil.check(is_equal_approx(d["div_mass"], 4.0 + Cell.ADD_MASS_FACTOR * 13.0 * 13.0), "div_mass is the birth mass plus what the size gene adds")
	TestUtil.check(store.has_record(a2) and store.has_record(a1), "a dead record with a living descendant stays")
	_died(store, 30, [_death(a3, A)])
	TestUtil.check(not store.has_record(a3) and not store.has_record(a2) and store.has_record(a1) and store.holds(a1) == 0, "the last descendant's death frees the dead line above it, up to the living ancestor")
	_died(store, 35, [_death(a1, A)])
	TestUtil.check(store.record_count() == 0, "a dead record nothing holds goes at once")
	TestUtil.check(store.info(a3).is_empty() and store.chain(a3).is_empty(), "a freed record has no info and no chain")
	_born(store, 40, [_birth(a1, 0), _birth(a2, a1), _birth(a3, a1)])
	TestUtil.check(store.living_descendants_of(PackedInt64Array([a1, a2, a3])) == PackedInt32Array([3, 1, 1]), "living_descendants_of counts the line, itself included")
	store.retarget_ids(PackedInt64Array([a2]), C)
	TestUtil.check(store.living_descendants_of(PackedInt64Array([a1, a2, a3]), C) == PackedInt32Array([1, 1, 0]) and store.living_descendants_of(PackedInt64Array([a1]), A) == PackedInt32Array([2]), "living_descendants_of with a dish counts the bups whose home it is")
	TestUtil.check(store.info(a2)["home"] == C and store.info(a2)["parent"] == a1 and store.info(a2)["alive"], "retarget_ids changes the home and nothing else")
	store.set_custom_name(a3, "Kept")
	TestUtil.check(store.custom_name(a3) == "Kept" and store.info(a3)["name"] == "Kept", "a name is kept with the record")


# ---- the dishes' cases ----------------------------------------------------------------------------------------------

## What a store says, to compare before and after: every record's info and holds, and every living bup's chain.
static func _snapshot(store: LineageStore, ids: Array) -> Dictionary:
	var out := {}
	for id: int in ids:
		if store.has_record(id):
			out[id] = [store.info(id), store.holds(id), store.chain(id)]
	return out


## Dish A (number 1) has a1 (a founder, dead by the freeze), a2 (child of a1), a3 (child of a2) and a5 (child of a1). A pipette moved
## a2 to dish C: it is alive there with its id (`id >> 44` still 1) and its home 3, and C's c1 was born of it. A watches a3 (holder A) and
## C's c1 (holder C) is pinned. A's living bups are a3 and a5. Times: births at minute 10, a1's death at 50, the freeze at 500.
func _pipetted_store(with_c_pin := true) -> LineageStore:
	var store := _new_store()
	_born(store, 10, [_birth(_id(A, 1), 0), _birth(_id(A, 2), _id(A, 1)), _birth(_id(A, 3), _id(A, 2)), _birth(_id(A, 5), _id(A, 1))])
	_died(store, 50, [_death(_id(A, 1), A)])
	store.retarget_ids(PackedInt64Array([_id(A, 2)]), C)
	_born(store, 60, [_birth(_id(C, 1), _id(A, 2))])
	store.pin(_id(A, 3), A)
	if with_c_pin:
		store.pin(_id(C, 1), C)
	return store


func _all_ids() -> Array:
	return [_id(A, 1), _id(A, 2), _id(A, 3), _id(A, 5), _id(C, 1)]


func _a_live() -> PackedInt64Array:
	return PackedInt64Array([_id(A, 3), _id(A, 5)])


## (a) pipette, freeze, thaw. Expected [derived]: the freeze's closure is a1, a2, a3, a5 (every ancestor of A's living bups and of its pin,
## the shared a2 and the dead a1 among them). The release drops A's pin; a3 and a5 become not alive at minute 500 and, held by nothing, go;
## a1 and a2 stay (a2 is C's bup and a1 is held by it), so 3 records stay. The thaw inserts a3 and a5 only, makes them alive in A, takes
## nothing from a1 and a2, pins a3 for A again: every record, hold and chain is as before the freeze and the count is the same.
func _case_a_pipette_freeze_thaw() -> void:
	var store := _pipetted_store()
	var ids := _all_ids()
	var before := _snapshot(store, ids)
	var count := store.record_count()
	var exported := store.export_dish(A, _a_live())
	TestUtil.check(exported["ids"] == PackedInt64Array([_id(A, 1), _id(A, 2), _id(A, 3), _id(A, 5)]), "(a) the export lists the ancestors of A's bups and pins (%s)" % str(exported["ids"]))
	store.release_dish(A, _a_live(), 500, exported["ids"])
	TestUtil.check(not store.has_record(_id(A, 3)) and not store.has_record(_id(A, 5)) and store.record_count() == 3, "(a) the release frees what only A needed (%d records)" % store.record_count())
	TestUtil.check(store.info(_id(A, 2))["alive"] and store.holds(_id(A, 3)) == -1, "(a) the pipetted bup is still alive in C")
	TestUtil.check(store.chain(_id(C, 1)) == PackedInt64Array([_id(A, 1), _id(A, 2), _id(C, 1)]), "(a) C's chain is whole while A is frozen")
	store.import_bytes(exported["bytes"], PackedInt64Array([_id(A, 3)]), _a_live(), A)
	var after := _snapshot(store, ids)
	TestUtil.check(store.record_count() == count, "(a) the count after the thaw is the count before (%d, %d)" % [store.record_count(), count])
	TestUtil.check(after == before, "(a) every record, hold and chain is as before the freeze")
	TestUtil.check(store.info(_id(A, 3))["alive"] and store.info(_id(A, 3))["home"] == A and store.info(_id(A, 3))["died"] == -1 and store.info(_id(A, 2))["home"] == C, "(a) A's bups are alive again with home A; the pipetted one is C's")
	TestUtil.check(store.holds(_id(C, 1)) == before[_id(C, 1)][1], "(a) C's pins and holds did not change")
	TestUtil.check(store.claim_count() == 0 and store.tombstone_count() == 0, "(a) no claim or tombstone is left")


## (b) while A is frozen the shared a2 is renamed in C and dies there. Expected [derived]: the store keeps its record whole through the
## thaw: the new name, its death at the minute of the event (700) and the figures of that death, not the blob's.
func _case_b_shared_ancestor_changes_while_frozen() -> void:
	var store := _pipetted_store()
	var exported := store.export_dish(A, _a_live())
	store.release_dish(A, _a_live(), 500, exported["ids"])
	store.set_custom_name(_id(A, 2), "Renamed")
	_died(store, 700, [_death(_id(A, 2), C, 0, 9.0)])
	store.set_time(900 * 60.0)
	store.import_bytes(exported["bytes"], PackedInt64Array(), _a_live(), A)
	var r := store.info(_id(A, 2))
	TestUtil.check(r["name"] == "Renamed" and not r["alive"] and r["died"] == 700 and r["mass"] == 9.0, "(b) the renamed ancestor keeps its name and the death it had in C")
	TestUtil.check(store.chain(_id(A, 3)) == PackedInt64Array([_id(A, 1), _id(A, 2), _id(A, 3)]) and store.chain(_id(C, 1)).size() == 3, "(b) the chains through it are whole")


## (c) the same blob twice. Expected [derived]: the second import finds every id in the store, sets the living ones alive again (they
## are) and pins nothing the dish already pins: the store's export is the same bytes, and the holds are the same.
func _case_c_same_blob_twice() -> void:
	var store := _pipetted_store()
	var exported := store.export_dish(A, _a_live())
	store.release_dish(A, _a_live(), 500, exported["ids"])
	store.import_bytes(exported["bytes"], PackedInt64Array([_id(A, 3)]), _a_live(), A)
	var once := store.export_bytes()
	var holds := _snapshot(store, _all_ids())
	store.import_bytes(exported["bytes"], PackedInt64Array([_id(A, 3)]), _a_live(), A)
	TestUtil.check(store.export_bytes() == once, "(c) a second import of the same blob changes no byte of the store")
	TestUtil.check(_snapshot(store, _all_ids()) == holds, "(c) nor a hold, a home or a chain")


## (d) trash after the pipette, no export. Expected [derived]: A's pin is dropped, a3 and a5 freed, and a1 and a2 stay for C's c1 (and a2
## is C's alive bup): every chain and record of C as before (a1's holds fall by one, a5 being gone) and C's pin; a record only A needed is
## gone and none is marked dead at the trash time.
func _case_d_trash_after_pipette() -> void:
	var store := _pipetted_store()
	var kept := [_id(A, 1), _id(A, 2), _id(C, 1)]
	var before := _snapshot(store, kept)
	store.release_dish(A, _a_live(), 800)
	var after := _snapshot(store, kept)
	var same := true
	for id: int in kept:
		same = same and after[id][0] == before[id][0] and after[id][2] == before[id][2]
	TestUtil.check(same and store.holds(_id(A, 1)) == before[_id(A, 1)][1] - 1, "(d) the chains and records C needs are as before the trash")
	TestUtil.check(not store.has_record(_id(A, 3)) and not store.has_record(_id(A, 5)) and store.record_count() == 3, "(d) what only A needed is gone")
	TestUtil.check(store.info(_id(A, 2))["alive"] and store.info(_id(A, 2))["died"] == -1, "(d) the bup C holds is not marked dead by the trash")
	TestUtil.check(store.holds(_id(C, 1)) == before[_id(C, 1)][1] and store.claim_count() == 0 and store.tombstone_count() == 0, "(d) C's pin is kept and a trash claims nothing")


## (e) the closure. Expected [derived]: with A also pinning a6 (a dead record held only by that pin) and C pinning a7 (a child of a2 born in A,
## id dish 1, held only by C's pin), the export of A lists a1, a2, a3, a5, a6 and not a7 (it is neither an ancestor nor on A's pins, though its
## id says dish 1) and not c1 (home C).
func _case_e_closure() -> void:
	var store := _pipetted_store()
	_born(store, 70, [_birth(_id(A, 6), 0), _birth(_id(A, 7), _id(A, 2))])
	store.pin(_id(A, 6), A)
	store.pin(_id(A, 7), C)
	_died(store, 80, [_death(_id(A, 6), A), _death(_id(A, 7), C)])
	TestUtil.check(store.has_record(_id(A, 6)) and store.has_record(_id(A, 7)), "(e) the pinned dead records stay")
	var exported := store.export_dish(A, _a_live())
	var ids: PackedInt64Array = exported["ids"]
	var want := PackedInt64Array([_id(A, 1), _id(A, 2), _id(A, 3), _id(A, 5), _id(A, 6)])
	TestUtil.check(ids == want, "(e) the export lists the ancestors, the live bups and what A's pins hold, and nothing by id or home (%s)" % str(ids))
	TestUtil.check(not ids.has(_id(A, 7)) and not ids.has(_id(C, 1)), "(e) a record only C's pin holds is not A's to export, though its id says dish 1")
	TestUtil.check(_parse(exported["bytes"])["records"].size() == want.size(), "(e) the bytes hold exactly those records")


## (f) a shared ancestor is pruned while A is frozen. Expected [derived]: a2 is alive in C at the freeze and in A's blob. At 700 it dies
## in C and at 710 c1, its last descendant, dies: c1 goes, a2 goes, and so does a1 (held by a2 only), each leaving a tombstone since A
## claims them: a2's is 700. The thaw at 900 inserts them dead with the tombstones' times (a2 700), not 900, with the chains of a3 and a5
## as before, and no tombstone or claim left. No record has died = 900.
func _case_f_pruned_while_frozen() -> void:
	var store := _pipetted_store(false)
	var chain_a3 := store.chain(_id(A, 3))
	var exported := store.export_dish(A, _a_live())
	store.release_dish(A, _a_live(), 500, exported["ids"])
	TestUtil.check(store.claim_count() == 4, "(f) the freeze registers a claim for each id of the blob")
	_died(store, 700, [_death(_id(A, 2), C, 0, 9.0)])
	_died(store, 710, [_death(_id(C, 1), C)])
	TestUtil.check(not store.has_record(_id(A, 2)) and not store.has_record(_id(A, 1)), "(f) a2 and a1 are pruned")
	TestUtil.check(store.tombstone(_id(A, 2)) == 700 and store.tombstone(_id(A, 1)) == 50 and store.tombstone_count() == 2, "(f) a tombstone keeps each one's true death (a2 700, a1 50)")
	store.set_time(900 * 60.0)
	store.import_bytes(exported["bytes"], PackedInt64Array(), _a_live(), A)
	TestUtil.check(store.has_record(_id(A, 2)) and not store.info(_id(A, 2))["alive"] and store.info(_id(A, 2))["died"] == 700, "(f) a2 comes back dead at 700, not at the thaw")
	TestUtil.check(store.info(_id(A, 1))["died"] == 50, "(f) a1 comes back with its own death")
	TestUtil.check(store.chain(_id(A, 3)) == chain_a3 and store.chain(_id(A, 5)).size() == 2, "(f) the chains through them are as before the freeze")
	TestUtil.check(store.tombstone(_id(A, 2)) == -1 and store.tombstone_count() == 0 and store.claim_count() == 0, "(f) no tombstone or claim is left")
	var at_thaw := 0
	for id: int in _parse(store.export_bytes())["records"]:
		if store.info(id)["died"] == 900:
			at_thaw += 1
	TestUtil.check(at_thaw == 0, "(f) no record died at the thaw's time")


## (g) discard_frozen. Expected [derived]: A and A2 each list a2 and a1; once both are frozen and a2 is pruned, the tombstones of a2 and a1
## are claimed by both. Discarding A leaves them (A2 claims); discarding A2 deletes them and the claims map is empty; a thaw of A with A2
## still frozen leaves A2's claims and the tombstones; a discard inserts no record.
func _case_g_discard_frozen() -> void:
	for thaw_first in [false, true]:
		var store := _pipetted_store(false)
		_born(store, 61, [_birth(_id(A2, 8), _id(A, 2))])  # (A2's living bup, a child of the shared a2)
		var a_live := _a_live()
		var a2_live := PackedInt64Array([_id(A2, 8)])
		var blob_a := store.export_dish(A, a_live)
		store.release_dish(A, a_live, 500, blob_a["ids"])
		var blob_a2 := store.export_dish(A2, a2_live)
		store.release_dish(A2, a2_live, 510, blob_a2["ids"])
		_died(store, 700, [_death(_id(A, 2), C)])
		_died(store, 710, [_death(_id(C, 1), C)])
		TestUtil.check(store.tombstone(_id(A, 2)) == 700 and store.tombstone(_id(A, 1)) == 50, "(g) a2 and a1 are tombstoned (claims %d)" % store.claim_count())
		var records := store.record_count()
		if thaw_first:
			store.import_bytes(blob_a["bytes"], PackedInt64Array(), a_live, A)
			TestUtil.check(store.tombstone(_id(A, 2)) == 700 and store.claim_count() > 0, "(g) a thaw of A with A2 frozen leaves A2's claim and a2's tombstone")
			store.discard_frozen(A2)
			TestUtil.check(store.tombstone_count() == 0 and store.claim_count() == 0, "(g) then the trash of A2 leaves nothing")
		else:
			store.discard_frozen(A)
			TestUtil.check(store.tombstone(_id(A, 2)) == 700 and store.tombstone(_id(A, 1)) == 50 and store.claim_count() > 0, "(g) discarding A leaves the tombstones A2 claims")
			store.discard_frozen(A2)
			TestUtil.check(store.tombstone_count() == 0 and store.claim_count() == 0 and store.record_count() == records, "(g) discarding A2 deletes them, empties the claims and writes no record")


## (h) the dish holding a shared bup leaves while A is frozen. A is frozen at 500 claiming a1, a2, a3, a5; a2 is alive in C with its child
## c1. Then C leaves at 800, trashed or frozen. Expected [derived: the release frees a2 (C's live bup, dead from 800, nothing holding it
## once c1 goes) and a1 (dead at 50, held by a2 only), and A claims both, so each is tombstoned at its `died`: a2 at 800, a1 at 50; c1,
## which A does not claim, leaves none, also when C's own freeze claims it, since C's claims come after the freeing]. The thaw of A at 900
## brings a2 back dead at 800 and a1 at 50, never at 900. A trash leaves no claim and no tombstone after A's thaw; a freeze leaves C's
## claims and the tombstones of a1 and a2, which C also claims, until C is thawed or discarded.
func _case_h_holder_leaves_while_frozen() -> void:
	for freeze_c in [false, true]:
		var how := "frozen" if freeze_c else "trashed"
		var store := _pipetted_store(false)
		var blob_a := store.export_dish(A, _a_live())
		store.release_dish(A, _a_live(), 500, blob_a["ids"])
		var c_live := PackedInt64Array([_id(A, 2), _id(C, 1)])
		if freeze_c:
			var blob_c := store.export_dish(C, c_live)
			store.release_dish(C, c_live, 800, blob_c["ids"])
		else:
			store.release_dish(C, c_live, 800)
		TestUtil.check(not store.has_record(_id(A, 2)) and not store.has_record(_id(A, 1)) and not store.has_record(_id(C, 1)), "(h, C %s) a2, a1 and c1 leave the store" % how)
		TestUtil.check(store.tombstone(_id(A, 2)) == 800 and store.tombstone(_id(A, 1)) == 50 and store.tombstone(_id(C, 1)) == -1 and store.tombstone_count() == 2, "(h, C %s) a2 is tombstoned at C's release (800), a1 at its death (50), c1 not (a2 %d, a1 %d, c1 %d)" % [how, store.tombstone(_id(A, 2)), store.tombstone(_id(A, 1)), store.tombstone(_id(C, 1))])
		store.set_time(900 * 60.0)
		store.import_bytes(blob_a["bytes"], PackedInt64Array(), _a_live(), A)
		var r2 := store.info(_id(A, 2))
		TestUtil.check(store.has_record(_id(A, 2)) and not r2["alive"] and r2["died"] == 800 and store.info(_id(A, 1))["died"] == 50, "(h, C %s) A's thaw brings a2 back dead at 800 (not the thaw's 900) and a1 at 50 (a2 died %s)" % [how, r2.get("died", "none")])
		TestUtil.check(store.chain(_id(A, 3)) == PackedInt64Array([_id(A, 1), _id(A, 2), _id(A, 3)]), "(h, C %s) a3's chain is whole after the thaw" % how)
		if freeze_c:
			TestUtil.check(store.claim_count() == 3 and store.tombstone_count() == 2, "(h, C frozen) C's claims (a1, a2, c1) and the tombstones C claims stay (claims %d, tombstones %d)" % [store.claim_count(), store.tombstone_count()])
			store.discard_frozen(C)
		TestUtil.check(store.claim_count() == 0 and store.tombstone_count() == 0, "(h, C %s) no claim or tombstone is left in the end" % how)


## Pins by holder. Expected [derived]: each pin raises the record's holds by one and its dish's release drops exactly its own; an unpin by a
## holder that has no pin changes nothing; a pinned dead record stays and goes with its last pin.
func _pins_and_retarget() -> void:
	var store := _new_store()
	var x := _id(A, 1)
	_born(store, 10, [_birth(x, 0)])
	TestUtil.check(store.pin(x, A) and store.pin(x, A) and store.pin(x, C) and store.holds(x) == 3 and not store.pin(_id(A, 99), A), "a pin raises the holds, and a missing record cannot be pinned")
	_died(store, 20, [_death(x, A)])
	TestUtil.check(store.has_record(x), "a pinned dead record stays")
	store.unpin(x, 7)
	TestUtil.check(store.holds(x) == 3, "an unpin by a holder with no pin changes nothing")
	store.release_dish(A, PackedInt64Array(), 30)
	TestUtil.check(store.holds(x) == 1 and store.has_record(x), "a release drops the dish's pins and only those")
	store.unpin(x, C)
	TestUtil.check(not store.has_record(x), "the last unpin frees the dead record")
