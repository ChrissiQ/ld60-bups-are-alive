extends SceneTree
## Run: godot --headless --path . -s tests/record_codec_test.gd
## RecordCodec.info_from_record against the pooled world's record layout (gpu/gpu_layout.gd), headless.
## Expected values, each word read at the place the layout names (R_*) and each figure worked out here from
## the game's constants (Cell, Biology) and the formulas the step kernel uses (gpu/kernels_field.gd `apply`: upkeep = scale x (base +
## per_mass x mass) + drag x speed² x size + sense_upkeep x sense, with size = sqrt(mass)) [derived]:
##  - records made as the world loads them (Scenario.founder_records with every flag on: donors, acetate keys, all founders' words) and
##    records made by hand with every word set to its own value (ids past 2^32, a raised ceiling word, a donor), 200 in all: the
##    dictionary's id, pos, dir, energy, mass, birth_mass, divisions, speed, sense, metabolism, size_gene, hue, sat, val, harm, mutator,
##    mutations equal the words (as float32, ids as the two uint words joined), exactly;
##  - max_energy = RESERVE_PER_MASS x mass; length = mass x MASS_UM; size = sqrt(mass); div_mass = birth_mass + ADD_MASS_FACTOR x
##    size_gene² (within 1e-6 relative: the codec rounds the building size to float32, as the kernel keeps it); donor is the donor word above 0.5; reach is
##    the reach word rounded to a whole number; sense_range = sense x sqrt(size / REFERENCE_SIZE);
##  - upkeep is the kernel's formula above, within 1e-6 relative (the codec rounds the drag term to float32, as the kernel keeps it);
##  - `born`, `steering` and the dish's upkeep scale are the arguments given (0, 0.5 and 1 by default);
##  - an index past the end, or below 0, gives an empty dictionary.

const COUNT := 200


func _init() -> void:
	SimConstants.apply()
	var constants := SimConstants.build()
	var records := Scenario.small(100, 3000.0).seed(5).with_all_flags().founder_records(1)
	records.append_array(_by_hand(100))
	TestUtil.check(records.size() == COUNT * GpuLayout.RECORD_BYTES, "%d records made (%d bytes)" % [COUNT, records.size()])
	var donors := 0
	var keys := 0
	var big_ids := 0
	for i in COUNT:
		var info := RecordCodec.info_from_record(records, i, constants)
		_check_record(records, i, info)
		donors += 1 if info["donor"] else 0
		keys += 1 if Genome.key_level(info["reach"]) == 2 else 0
		big_ids += 1 if info["id"] > 0xFFFFFFFF else 0
	TestUtil.check(donors >= 20 and keys >= 20 and big_ids >= 50, "the sample holds donors (%d), keys (%d) and ids past 2^32 (%d)" % [donors, keys, big_ids])
	var given := RecordCodec.info_from_record(records, 3, constants, 77, 0.9, 3.0)
	var plain := RecordCodec.info_from_record(records, 3, constants)
	TestUtil.check(plain["born"] == 0 and plain["steering"] == 0.5, "born and steering default to 0 and 0.5")
	TestUtil.check(given["born"] == 77 and given["steering"] == 0.9, "born and steering are the arguments given")
	var scale := 3.0
	var mass: float = given["mass"]
	var expect: float = scale * (Cell.BASE_UPKEEP + Cell.MAINTENANCE_PER_MASS * mass) + Cell.DRAG_UPKEEP * given["speed"] * given["speed"] * sqrt(mass) + Cell.SENSE_UPKEEP * given["sense"]
	TestUtil.check(absf(given["upkeep"] - expect) <= 1e-6 * expect, "an upkeep scale of 3 multiplies the base and per-mass parts only (%s against %s)" % [given["upkeep"], expect])
	TestUtil.check(RecordCodec.info_from_record(records, COUNT, constants).is_empty(), "an index past the end gives an empty dictionary")
	TestUtil.check(RecordCodec.info_from_record(records, -1, constants).is_empty(), "an index below 0 gives an empty dictionary")
	TestUtil.finish(self, "RECORD CODEC TEST OK")


## `n` records with every word its own value (genes, mass and position vary with the index; ids from 2^32 + 1; every third a donor,
## every fourth with a raised speed ceiling and the acetate key at level 1 or 2).
func _by_hand(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n * GpuLayout.RECORD_BYTES)
	for i in n:
		var o := i * GpuLayout.RECORD_BYTES
		var f := float(i)
		GpuLayout.set_id(out, i, (1 << 32) + 1 + i * 1000003)
		out.encode_float(o + GpuLayout.R_X * 4, -1500.0 + 31.5 * f)
		out.encode_float(o + GpuLayout.R_Y * 4, 900.0 - 17.25 * f)
		out.encode_float(o + GpuLayout.R_DX * 4, cos(f))
		out.encode_float(o + GpuLayout.R_DY * 4, sin(f))
		var mass := 3.0 + 0.37 * f
		out.encode_float(o + GpuLayout.R_MASS * 4, mass)
		out.encode_float(o + GpuLayout.R_ENERGY * 4, minf(Cell.RESERVE_PER_MASS * mass, 4.0 + 1.9 * f))
		out.encode_float(o + GpuLayout.R_BIRTH_MASS * 4, 2.0 + 0.01 * f)
		out.encode_float(o + GpuLayout.R_SPEED * 4, 5.0 + 0.4 * f)
		out.encode_float(o + GpuLayout.R_SENSE * 4, 20.0 + 1.3 * f)
		out.encode_float(o + GpuLayout.R_METABOLISM * 4, 0.5 + 0.02 * f)
		out.encode_float(o + GpuLayout.R_SIZE * 4, 1.5 + 0.015 * f)
		var reach := 0
		if i % 4 == 0:
			reach = 1 | ((1 + (i / 4) % 2) << 8)  # the speed ceiling raised once, the key at level 1 or 2
		out.encode_float(o + GpuLayout.R_REACH * 4, float(reach))
		out.encode_float(o + GpuLayout.R_MUTATOR * 4, 1.0 + 0.5 * (i % 7))
		out.encode_float(o + GpuLayout.R_DONOR * 4, 1.0 if i % 3 == 0 else 0.0)
		out.encode_float(o + GpuLayout.R_HARM * 4, 0.01 * f)
		out.encode_float(o + GpuLayout.R_HUE * 4, fmod(0.013 * f, 1.0))
		out.encode_float(o + GpuLayout.R_SAT * 4, 0.5 + 0.004 * f)
		out.encode_float(o + GpuLayout.R_VAL * 4, 0.6 + 0.003 * f)
		out.encode_float(o + GpuLayout.R_MUTATIONS * 4, float(i * 3))
		out.encode_float(o + GpuLayout.R_DIVISIONS * 4, float(i * 2 + 1))
	return out


func _word(records: PackedByteArray, i: int, word: int) -> float:
	return records.decode_float(i * GpuLayout.RECORD_BYTES + word * 4)


func _same_f32(a: float, b: float) -> bool:
	return RecordCodec.f32(a) == RecordCodec.f32(b)


func _check_record(records: PackedByteArray, i: int, info: Dictionary) -> void:
	var o := i * GpuLayout.RECORD_BYTES
	var id := records.decode_u32(o + GpuLayout.R_ID_LO * 4) + (records.decode_u32(o + GpuLayout.R_ID_HI * 4) << 32)
	var mass := _word(records, i, GpuLayout.R_MASS)
	var birth := _word(records, i, GpuLayout.R_BIRTH_MASS)
	var speed := _word(records, i, GpuLayout.R_SPEED)
	var sense := _word(records, i, GpuLayout.R_SENSE)
	var size_gene := _word(records, i, GpuLayout.R_SIZE)
	var ok: bool = info["id"] == id
	ok = ok and info["pos"] == Vector2(_word(records, i, GpuLayout.R_X), _word(records, i, GpuLayout.R_Y))
	ok = ok and info["dir"] == Vector2(_word(records, i, GpuLayout.R_DX), _word(records, i, GpuLayout.R_DY))
	ok = ok and info["energy"] == _word(records, i, GpuLayout.R_ENERGY) and info["mass"] == mass and info["birth_mass"] == birth
	ok = ok and info["speed"] == speed and info["sense"] == sense and info["metabolism"] == _word(records, i, GpuLayout.R_METABOLISM)
	ok = ok and info["size_gene"] == size_gene and info["harm"] == _word(records, i, GpuLayout.R_HARM)
	ok = ok and info["hue"] == _word(records, i, GpuLayout.R_HUE) and info["sat"] == _word(records, i, GpuLayout.R_SAT) and info["val"] == _word(records, i, GpuLayout.R_VAL)
	ok = ok and info["mutator"] == _word(records, i, GpuLayout.R_MUTATOR)
	ok = ok and info["mutations"] == int(_word(records, i, GpuLayout.R_MUTATIONS)) and info["divisions"] == int(_word(records, i, GpuLayout.R_DIVISIONS))
	TestUtil.check(ok, "record %d: the words come out as they are (id %d)" % [i, id])
	var size := sqrt(mass)
	var building := Cell.ADD_MASS_FACTOR * size_gene * size_gene
	var upkeep: float = Cell.BASE_UPKEEP + Cell.MAINTENANCE_PER_MASS * mass + Cell.DRAG_UPKEEP * speed * speed * size + Cell.SENSE_UPKEEP * sense
	var derived: bool = info["max_energy"] == Cell.RESERVE_PER_MASS * mass and info["length"] == mass * Cell.MASS_UM and info["size"] == size
	derived = derived and absf(info["div_mass"] - (birth + building)) <= 1e-6 * (birth + building)
	derived = derived and info["donor"] == (_word(records, i, GpuLayout.R_DONOR) > 0.5)
	derived = derived and info["reach"] == int(_word(records, i, GpuLayout.R_REACH) + 0.5)
	derived = derived and is_equal_approx(info["sense_range"], sense * sqrt(size / Cell.REFERENCE_SIZE))
	derived = derived and absf(info["upkeep"] - upkeep) <= 1e-6 * upkeep
	TestUtil.check(derived, "record %d: max_energy, length, size, div_mass, donor, reach, sense_range and upkeep follow from the words" % i)
