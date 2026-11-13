extends SceneTree
## Run: godot --headless --path . -s tests/dish_codec_test.gd
## DishCodec's blob format, on blobs built here (no device).
##
## Expected values, written before the first run:
## - Round trip: a blob with records, device blocks, clouds, husks, a world, history, watch list and lineage bytes, written, put through JSON text
##   and read back, is the same blob: every block byte for byte, the spec and the world as dictionaries (equal and equal in hash), the
##   host's history keys, watch list (order kept), lineage bytes and nutrients_placed [derived: the blocks are bytes and the spec and
##   world are binary variants, so nothing is rounded]. The lineage bytes imported into an empty LineageStore give the family tree the
##   source store exported: the same record count, the same `info` for every id [derived: import_bytes inserts every id of an export].
## - Malformed blobs refused: a dict that is of another format, lacks a block, has a block that does not decompress to its size or of the wrong size for
##   its part (a record, the dish's state, a grid, a slot, the lineage), a spec out of range in its radius, a world with a missing or
##   non-finite number: read_blob returns null each time, and the dictionary it was given is as it was (nothing is built on it). A limit,
##   upkeep, feed or medium out of range is made safe, not refused: limit 0 with 5 bups reads as 5, upkeep 1000 as 100, a feed of -3 as 0,
##   a medium of 1000 as 100. Lineage bytes LineageStore.import_bytes cannot read whole are refused: a count with no count of names
##   after it (4 bytes, and a record with none), a name cut short by a byte, a byte past the names; read are none at all, a lineage of
##   no records (8 bytes) and one of two records and two names, which the store then holds (the second named "Ada").
## - Save in a format this reader does not know: a dictionary with "cells", "lineage" as a block and "moved_out" is refused, as is a file
##   of version 2: SaveGame.read gives {} for it.
## - Save file round trip: a tracker at index 2 holding 1234.5678 seconds, and a dish, written with SaveGame.write to a scratch file and read back: the
##   tracker's index is 2 and its held time within 0.001 of 1234.5678, and the dish blob reads back equal to the one written.

const SCRATCH := "user://dish_codec_test_save.json"
## A lineage export recorded from the CPU simulation the pooled world replaced.
const LINEAGE_GOLDEN := "res://tools/gpu/golden/parity/lineage_export.bin.gz"
const NUMBER := 7


func _init() -> void:
	var source := _blob()
	var original := source["blob"] as DishBlob
	var written := DishCodec.write_blob(original)
	var parsed: Variant = JSON.parse_string(JSON.stringify(written))
	_round_trip(original, parsed, source["store"])
	_refusals(written)
	_safe_values(original)
	_old_formats(written)
	_goal_tracker_through_a_save(original, written)
	SaveGame.delete(SCRATCH)
	TestUtil.finish(self, "DISH CODEC TEST OK")


# ---- a blob made by hand ------------------------------------------------------------------------------------------------

## {blob, store}: five bups, a grid, clouds and husks of made-up numbers (the floats not exactly representable in decimal), a world with
## a source and plankton, a history, a watch list and the lineage of the recorded export (its living bups the dish's).
func _blob() -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var spec := DishSpec.new()
	spec.number = NUMBER
	spec.radius = 300.0
	spec.resolution = StartConditions.MIN_NUTRIENT_RESOLUTION
	spec.limit = 1000
	spec.seed = 9223372036854775000  # (past a double's 53 bits)
	spec.step = 4321
	spec.feed_density = 9.1
	spec.bloom_density = 2.3
	spec.upkeep = 1.7
	var blob := DishBlob.new()
	blob.spec = spec.to_dict()
	blob.records = _random_bytes(rng, 5 * GpuLayout.RECORD_BYTES)
	blob.dstate = _random_bytes(rng, GpuLayout.DS_WORDS * 4)
	blob.dstate.encode_u32(GpuLayout.DS_COUNT * 4, 5)
	var n := DishGrid.cells_across(spec.radius, spec.resolution)
	blob.conc = _random_floats(rng, n * n)
	blob.conc2 = _random_floats(rng, n * n)
	blob.dplo = _random_bytes(rng, n * n * 4)
	blob.dphi = _random_bytes(rng, n * n * 4)
	blob.clouds = _random_floats(rng, 3 * 8)
	blob.husks = _random_floats(rng, 2 * 8)
	var world := DishWorld.new(spec.radius, 5)
	world.set_bloom(2.3)
	world.apply({"op": "add_source", "pos": Vector2(12.5, -40.25), "rate": 4.1})
	world.apply({"op": "add_plankton", "pos": Vector2(-30.1, 77.7)})
	world.apply({"op": "add_plankton", "pos": Vector2(100.3, 5.9)})
	world.events(0.0, 3, 20.0)
	blob.world = world.save()
	var history := DishHistory.new()
	for i in 4:
		var stats := {"count": 10 + i, "harm": 0.01 * i, "mutator": 1.0, "donor": 0.1, "key": 0.0, "generation": 2.0 + i}
		for gene in Genome.GENES:
			stats[gene] = rng.randf()
		history.record((i + 1) * DishHistory.INTERVAL, stats)
	var f := FileAccess.open_compressed(LINEAGE_GOLDEN, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	var golden := f.get_buffer(f.get_length())
	var store := LineageStore.new()
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	var live := _living_ids(golden)
	store.import_bytes(golden, PackedInt64Array(), live, NUMBER)
	var watched := PackedInt64Array([live[3], live[1], live[7]])
	for id in watched:
		store.pin(id, NUMBER)
	var exported := store.export_dish(NUMBER, live)
	blob.host = {"history": history.write(), "watched": watched, "lineage": exported["bytes"], "nutrients_placed": 3}
	return {"blob": blob, "store": store}


static func _random_bytes(rng: RandomNumberGenerator, size: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(size)
	for i in size:
		out[i] = rng.randi() & 0xFF
	return out


static func _random_floats(rng: RandomNumberGenerator, count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	for i in count:
		out[i] = rng.randf() * 100.0 / 3.0
	return out


static func _living_ids(export: PackedByteArray) -> PackedInt64Array:
	var out := PackedInt64Array()
	var count := export.decode_u32(0)
	for i in count:
		var at := 4 + i * DishCodec.LINEAGE_RECORD_BYTES
		if export.decode_s32(at + 8 + 8 + 4) < 0:
			out.append(export.decode_s64(at))
	return out


# ---- round trip ----------------------------------------------------------------------------------------------------------------

func _round_trip(original: DishBlob, parsed: Variant, store: LineageStore) -> void:
	var back := DishCodec.read_blob(parsed)
	TestUtil.check(back != null, "the blob reads back after JSON text")
	if back == null:
		return
	for part: String in ["records", "dstate", "conc", "conc2", "dplo", "dphi", "clouds", "husks"]:
		TestUtil.check(back.get(part) == original.get(part), "%s are the same after a save" % part)
	TestUtil.check(back.spec == original.spec and back.spec.hash() == original.spec.hash(), "the spec is the same, the 64-bit seed too (%s)" % back.spec.get("seed"))
	TestUtil.check(back.world == original.world and back.world.hash() == original.world.hash(), "the world is the same (plankton, sources, bloom, generator state)")
	TestUtil.check(back.host["history"] == original.host["history"], "the history is the same")
	TestUtil.check(back.host["watched"] == original.host["watched"], "the watch list keeps its order")
	TestUtil.check(back.host["lineage"] == original.host["lineage"], "the lineage bytes are the same")
	TestUtil.check(back.host["nutrients_placed"] == 3, "nutrients_placed is the same")
	TestUtil.check(not back.host.has("moved_out") and not written_has_moved_out(DishCodec.write_blob(original)), "no moved_out is kept")
	var fresh := LineageStore.new()
	fresh.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	fresh.import_bytes(back.host["lineage"], back.host["watched"], _living_ids(back.host["lineage"]), NUMBER)
	var exported := store.export_dish(NUMBER, _living_ids(original.host["lineage"]))
	TestUtil.check(fresh.record_count() == (exported["ids"] as PackedInt64Array).size(), "the merged family tree has the %d records exported (%d)" % [(exported["ids"] as PackedInt64Array).size(), fresh.record_count()])
	var same := true
	for id: int in exported["ids"]:
		same = same and fresh.info(id) == store.info(id)
	TestUtil.check(same, "every merged record has the figures of the source store's")
	for id in back.host["watched"]:
		TestUtil.check(fresh.holds(id) > 0, "the watched bup %d is held after the merge" % id)


## Lineage bytes as LineageStore.export_dish writes them: `records` records (ids 1 on, the rest 0), a name for each of the first of them
## from `names`, then `drop` bytes taken off the end.
static func _lineage(records: int, names: Array, drop: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4 + records * DishCodec.LINEAGE_RECORD_BYTES + 4)
	out.encode_u32(0, records)
	for i in records:
		out.encode_s64(4 + i * DishCodec.LINEAGE_RECORD_BYTES, i + 1)
	out.encode_u32(4 + records * DishCodec.LINEAGE_RECORD_BYTES, names.size())
	for i in names.size():
		var text: PackedByteArray = String(names[i]).to_utf8_buffer()
		var head := PackedByteArray()
		head.resize(12)
		head.encode_s64(0, i + 1)
		head.encode_u32(8, text.size())
		out.append_array(head + text)
	return out.slice(0, out.size() - drop)


static func written_has_moved_out(d: Dictionary) -> bool:
	return d.has("moved_out")


# ---- malformed blobs refused ----------------------------------------------------------------------------------------------------------------

func _refusals(written: Dictionary) -> void:
	var cases := {
		"another format": func(d: Dictionary) -> void: d["format"] = DishCodec.FORMAT + 1,
		"no format": func(d: Dictionary) -> void: d.erase("format"),
		"a block missing": func(d: Dictionary) -> void: d.erase("conc2"),
		"a block that does not decompress to its size": func(d: Dictionary) -> void: d["records"]["raw"] = int(d["records"]["raw"]) + 112,
		"a block cut short": func(d: Dictionary) -> void: d["meta"]["z"] = str(d["meta"]["z"]).substr(0, 20),
		"records of the wrong size": func(d: Dictionary) -> void: d["records"] = DishCodec.pack_bytes(PackedByteArray([1, 2, 3])),
		"a state of the wrong size": func(d: Dictionary) -> void: d["dstate"] = DishCodec.pack_bytes(PackedByteArray([1, 2, 3, 4])),
		"a grid of the wrong size": func(d: Dictionary) -> void: d["conc"] = DishCodec.pack_bytes(PackedByteArray([0, 0, 0, 0])),
		"a slot block of the wrong size": func(d: Dictionary) -> void: d["clouds"] = DishCodec.pack_bytes(PackedByteArray([0, 0, 0, 0])),
		"lineage bytes that claim more records than they hold": func(d: Dictionary) -> void: d["lineage"] = DishCodec.pack_bytes(PackedByteArray([200, 0, 0, 0, 1, 2])),
		"lineage bytes of a count alone (no count of names)": func(d: Dictionary) -> void: d["lineage"] = DishCodec.pack_bytes(PackedByteArray([0, 0, 0, 0])),
		"lineage bytes of a record and no count of names": func(d: Dictionary) -> void: d["lineage"] = DishCodec.pack_bytes(_lineage(1, [], 4)),
		"lineage bytes with a name cut short": func(d: Dictionary) -> void: d["lineage"] = DishCodec.pack_bytes(_lineage(1, ["bup"], 1)),
		"lineage bytes with more after the names": func(d: Dictionary) -> void: d["lineage"] = DishCodec.pack_bytes(_lineage(1, ["bup"], 0) + PackedByteArray([0])),
	}
	for what: String in cases:
		var d: Dictionary = written.duplicate(true)
		cases[what].call(d)
		TestUtil.check(DishCodec.read_blob(d) == null, "refused: %s" % what)
	var wrong_count: Dictionary = written.duplicate(true)
	var state: PackedByteArray = DishCodec.unpack_bytes(wrong_count["dstate"])
	state.encode_u32(GpuLayout.DS_COUNT * 4, 6)
	wrong_count["dstate"] = DishCodec.pack_bytes(state)
	TestUtil.check(DishCodec.read_blob(wrong_count) == null, "refused: a count in the state that is not the records'")
	var meta_edits := {
		"a radius out of range": func(m: Dictionary) -> void: m["spec"]["radius"] = 1.0e9,
		"a radius that is not finite": func(m: Dictionary) -> void: m["spec"]["radius"] = INF,
		"a spec number missing": func(m: Dictionary) -> void: m["spec"].erase("limit"),
		"a world number that is not finite": func(m: Dictionary) -> void: m["world"]["time"] = NAN,
		"a world number missing": func(m: Dictionary) -> void: m["world"].erase("rng_state"),
		"a plankton with no place": func(m: Dictionary) -> void: m["world"]["plankton"][0].erase("pos"),
		"a source of the wrong kind": func(m: Dictionary) -> void: m["world"]["sources"][1] = 5,
		"a watch list of text": func(m: Dictionary) -> void: m["host"]["watched"] = ["a"],
		"a history that is not one": func(m: Dictionary) -> void: m["host"]["history"] = 5,
	}
	for what: String in meta_edits:
		var d: Dictionary = written.duplicate(true)
		var meta: Dictionary = bytes_to_var(DishCodec.unpack_bytes(d["meta"]))
		meta_edits[what].call(meta)
		d["meta"] = DishCodec.pack_bytes(var_to_bytes(meta))
		TestUtil.check(DishCodec.read_blob(d) == null, "refused: %s" % what)
	for kept: Array in [[PackedByteArray(), "no lineage"], [_lineage(0, [], 0), "a lineage of no records (8 bytes)"], [_lineage(2, ["bup", "Ada"], 0), "two records and two names"]]:
		var d: Dictionary = written.duplicate(true)
		d["lineage"] = DishCodec.pack_bytes(kept[0])
		TestUtil.check(DishCodec.read_blob(d) != null, "read: lineage bytes of %s" % kept[1])
	var named := LineageStore.new()
	named.import_bytes(_lineage(2, ["bup", "Ada"], 0), PackedInt64Array(), PackedInt64Array([1, 2]), NUMBER)
	TestUtil.check(named.has_record(1) and named.has_record(2) and String(named.info(2).get("name", "")) == "Ada", "the store reads every lineage the codec lets through (2 records, the second named Ada: %s)" % [named.info(2)])
	var before := written.hash()
	DishCodec.read_blob(written)
	TestUtil.check(written.hash() == before, "reading leaves the dictionary as it was")
	TestUtil.check(DishCodec.read_blob({}) == null and DishCodec.read_blob({"nope": 1}) == null, "refused: garbage")


func _safe_values(original: DishBlob) -> void:
	var edited := DishBlob.new()
	edited.spec = original.spec.duplicate()
	edited.spec["limit"] = 0
	edited.spec["upkeep"] = 1000.0
	edited.spec["feed_density"] = -3.0
	edited.spec["medium_thickness"] = 1000.0
	for part: String in ["records", "dstate", "conc", "conc2", "dplo", "dphi", "clouds", "husks", "world", "host"]:
		edited.set(part, original.get(part))
	var back := DishCodec.read_blob(DishCodec.write_blob(edited))
	TestUtil.check(back != null, "out-of-range limit, upkeep, feed and medium are not refused")
	if back == null:
		return
	TestUtil.check(back.spec["limit"] == 5, "a limit of 0 with 5 bups reads as 5 (%s)" % back.spec["limit"])
	TestUtil.check(back.spec["upkeep"] == 100.0, "an upkeep of 1000 reads as 100 (%s)" % back.spec["upkeep"])
	TestUtil.check(back.spec["feed_density"] == 0.0, "a feed of -3 reads as 0 (%s)" % back.spec["feed_density"])
	TestUtil.check(back.spec["medium_thickness"] == StartConditions.MAX_MEDIUM_THICKNESS, "a medium of 1000 reads as %s (%s)" % [StartConditions.MAX_MEDIUM_THICKNESS, back.spec["medium_thickness"]])


# ---- unknown save format ----------------------------------------------------------------------------------------------------------------

func _old_formats(written: Dictionary) -> void:
	var old := {"next_id": 5, "radius": 300.0, "cells": written["records"], "lineage": written["lineage"], "moved_out": [], "time": 0.0}
	TestUtil.check(DishCodec.read_blob(old) == null, "refused: a dish save in a format this reader does not know")
	var file := FileAccess.open(SCRATCH, FileAccess.WRITE)
	file.store_string(JSON.stringify({"version": 2, "dish": old, "goals": {}}))
	file.close()
	TestUtil.check(SaveGame.read(SCRATCH).is_empty() and not SaveGame.has_save(SCRATCH), "refused: a save file of version 2")


# ---- save file round trip ----------------------------------------------------------------------------------------------------------------

func _goal_tracker_through_a_save(original: DishBlob, written: Dictionary) -> void:
	var tracker := GoalTracker.new()
	tracker.index = 2
	tracker.held = 1234.5678
	TestUtil.check(SaveGame.write({"dish": written, "goals": tracker.to_dict()}, SCRATCH), "the scratch save is written")
	var saved := SaveGame.read(SCRATCH)
	TestUtil.check(not saved.is_empty(), "the scratch save is read")
	if saved.is_empty():
		return
	var again := GoalTracker.new()
	again.from_dict(saved["goals"])
	TestUtil.check(again.index == 2, "the goal tracker's index is restored (%d)" % again.index)
	TestUtil.check(absf(again.held - 1234.5678) < 0.001, "the goal tracker's held time is restored (%s)" % again.held)
	var back := DishCodec.read_blob(saved["dish"])
	TestUtil.check(back != null and back.records == original.records and back.world == original.world and back.spec == original.spec, "the dish in the save file is the dish that was written")
