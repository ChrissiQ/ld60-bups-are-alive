extends SceneTree
## Run: godot --headless --path . -s tests/gpu_native_test.gd
## The native calls the GPU path rests on (see gpu/gpu_world.gd): the bups as the GPU's records and back
## (BupSim.export_state_bytes / import_state_bytes, ids past 2^32 included), bup_info from a record (info_from_state), steering at a
## point (steering_at), the family records from the GPU's births and deaths (apply_events) against the same births and deaths made by
## the CPU's own step, the living ids from the records (alive_ids), the sources' part of a step on its own (step_world), and the field
## as packed arrays (NutrientField.export_packed / import_packed). Headless: nothing here needs a GPU.

const RECORD_BYTES := 96


func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


func _init() -> void:
	SimConstants.apply()
	_records_round_trip()
	_events_against_the_cpu()
	_world_emissions()
	_packed_field()
	TestUtil.finish(self, "GPU NATIVE TEST OK")


static func _id_of(records: PackedByteArray, i: int) -> int:
	return records.decode_u32(i * RECORD_BYTES) | (records.decode_u32(i * RECORD_BYTES + 21 * 4) << 32)


## A genome with every heritable figure away from the founder's, from the sim's own random numbers (so a run is the same every time).
static func _genome(sim: BupSim) -> Dictionary:
	var g := Genome.founder()
	g["speed"] = 10.0 + 40.0 * sim.random_float()
	g["sense"] = 20.0 + 100.0 * sim.random_float()
	g["metabolism"] = 0.6 + 0.8 * sim.random_float()
	g["size"] = 3.0 + 2.0 * sim.random_float()
	g["hue"] = sim.random_float()
	g["sat"] = 0.4 + 0.5 * sim.random_float()
	g["val"] = 0.6 + 0.4 * sim.random_float()
	g["harm"] = 0.3 * sim.random_float()
	g["mutations"] = int(10.0 * sim.random_float())
	return g


func _records_round_trip() -> void:
	var sim := BupSim.new()
	sim.reset(10000.0, 3)
	sim.set_limit(5000)
	sim.set_upkeep_scale(3.0)  # (bup_info's upkeep follows it: so must info_from_state's)
	var field := sim.get_field()
	field.deposit_disc(Vector2(2000.0, -1000.0), 4000.0, 2.0e6)  # (a slope, for the steering)
	for i in 1000:
		var g := _genome(sim)
		var born := Cell.mass_to_add(g)
		var id := (1 << 32) + 5 + 3 * i if i % 2 == 0 else 1 + i  # (half of them numbered past 2^32)
		sim.add_bup(sim.random_point(9000.0), g, 30.0 + 50.0 * sim.random_float(), sqrt(born * (1.0 + sim.random_float())), born, i % 7, Vector2.from_angle(sim.random_float() * TAU), id)
	sim.step(20.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 20.0)
	sim.render_buffer(1.0, 600)  # (the first 600 now have a last picture, the rest none)
	sim.step(20.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 40.0)
	var ids := sim.bup_ids()
	var state := sim.export_state_bytes()
	check(ids.size() > 900 and state.size() == ids.size() * RECORD_BYTES, "export_state_bytes gives a 96-byte record per bup (%d bytes for %d bups)" % [state.size(), ids.size()])
	var high := 0
	var ids_ok := true
	for i in ids.size():
		ids_ok = ids_ok and _id_of(state, i) == ids[i]
		high += 1 if ids[i] >= (1 << 32) else 0
	check(ids_ok and high > 400, "each record holds its bup's id in words 0 and 21 (%d of them past 2^32)" % high)
	var floats := state.to_float32_array()
	var drawn := 0
	var undrawn := 0
	for i in ids.size():
		if floats[i * 24 + 22] >= 1e30 and floats[i * 24 + 23] >= 1e30:
			undrawn += 1
		elif absf(floats[i * 24 + 22]) <= 10000.0 and absf(floats[i * 24 + 23]) <= 10000.0:
			drawn += 1
	check(drawn > 0 and undrawn > 0 and drawn + undrawn == ids.size(), "words 22 and 23 hold where it was last drawn, or a value from 1e30 up if nowhere yet (%d drawn, %d not)" % [drawn, undrawn])
	var other := BupSim.new()
	other.reset(10000.0, 3)
	other.import_state_bytes(state)
	check(other.export_state_bytes() == state, "import_state_bytes then export_state_bytes gives the same bytes")
	check(other.get_next_id() > ids[ids.size() - 1] and other.get_next_id() >= (1 << 32), "after an import the next id is past every id in the state (%d)" % other.get_next_id())
	check(other.record_count() == 0, "import_state_bytes leaves the family records alone")
	sim.import_state_bytes(state)
	check(sim.export_state_bytes() == state and sim.bup_ids() == ids, "importing a dish's own state into it changes nothing")
	var info_ok := 0
	var steer_ok := 0
	for i in ids.size():
		if sim.info_from_state(state, i) == sim.bup_info(ids[i]):
			info_ok += 1
		var info := sim.bup_info(ids[i])
		if sim.steering_at(info["pos"], info["speed"], sim.bup_sense_range(ids[i])) == sim.bup_steering(ids[i]):
			steer_ok += 1
	check(info_ok == ids.size(), "info_from_state gives bup_info's dictionary for every record (%d of %d)" % [info_ok, ids.size()])
	check(steer_ok == ids.size(), "steering_at gives bup_steering for a bup's place, speed and sense range (%d of %d)" % [steer_ok, ids.size()])
	check(sim.info_from_state(state, ids.size()).is_empty() and sim.info_from_state(state, -1).is_empty(), "info_from_state of a record that is not there is empty")
	var sorted := ids.duplicate()
	sorted.sort()
	check(sim.alive_ids() == sorted, "alive_ids gives the living bups' ids from the records, in order")


## The same births and deaths, made once by the CPU's step and once given to apply_events as the GPU's events: the same records.
func _events_against_the_cpu() -> void:
	var cpu := BupSim.new()
	cpu.reset(1500.0, 11)
	cpu.set_limit(60)  # (so that births displace bups at the limit too)
	cpu.get_field().fill(32.0 * Dish.CONCENTRATION_PER_DENSITY)
	var records := BupSim.new()  # (only records: the GPU's bups would be elsewhere)
	records.reset(1500.0, 11)
	for i in 50:
		var g := _genome(cpu)
		var born := Cell.mass_to_add(g)
		var grown := born * (1.9 + 0.099 * cpu.random_float()) if i % 2 == 0 else born * (1.0 + 0.5 * cpu.random_float())
		var energy := 0.0 if i % 5 == 0 else Dish.FOUNDER_ENERGY  # (some starve at once)
		var pos := cpu.random_point(1000.0)
		var id := cpu.add_bup(pos, g, energy, sqrt(grown), born, 0, Vector2.RIGHT)
		records.add_bup(pos, g, energy, sqrt(grown), born, 0, Vector2.RIGHT, id)
		if i % 9 == 0:  # (watched: their records stay after they die)
			cpu.pin(id)
			records.pin(id)
	var births := PackedByteArray()
	var deaths := PackedByteArray()
	var steps := 60
	for k in steps:
		var before := {}
		for id in cpu.bup_ids():
			before[id] = cpu.bup_info(id)
		cpu.step(20.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 20.0 * (k + 1))
		var after := {}
		for id in cpu.bup_ids():
			after[id] = true
			if before.has(id):
				continue
			var info := cpu.bup_info(id)
			var e := PackedByteArray()
			e.resize(64)
			e.encode_u32(0, id & 0xFFFFFFFF); e.encode_u32(4, id >> 32)
			var parent: int = cpu.lineage_info(id)["parent"]
			e.encode_u32(8, parent & 0xFFFFFFFF); e.encode_u32(12, parent >> 32)
			e.encode_u32(16, k); e.encode_u32(20, info["divisions"]); e.encode_u32(24, info["mutations"])
			var words := [info["speed"], info["sense"], info["metabolism"], info["size_gene"], info["hue"], info["sat"], info["val"], info["harm"], info["mutator"]]
			for w in words.size():
				e.encode_float(28 + 4 * w, words[w])
			births.append_array(e)
		for id: int in before:
			if after.has(id):
				continue
			var kept := cpu.lineage_info(id)  # (the record, if it stayed: what the bup was when it died)
			var e := PackedByteArray()
			e.resize(40)
			e.encode_u32(0, id & 0xFFFFFFFF); e.encode_u32(4, id >> 32); e.encode_u32(8, k)
			e.encode_u32(12, kept["divisions"] if not kept.is_empty() else before[id]["divisions"])
			var gone: Dictionary = kept if not kept.is_empty() else before[id]
			e.encode_float(16, gone["mass"])
			e.encode_float(32, gone["energy"])
			e.encode_float(36, gone["birth_mass"])
			deaths.append_array(e)
	check(births.size() / 64 > 20 and deaths.size() / 40 > 10, "the CPU run has births and deaths to compare (%d and %d)" % [births.size() / 64, deaths.size() / 40])
	records.set_time(12345.0)
	records.apply_events(births, deaths, 20.0, 20.0)
	var by_id_cpu := {}
	for r: Dictionary in cpu.lineage_export():
		by_id_cpu[r["id"]] = r
	var by_id_gpu := {}
	for r: Dictionary in records.lineage_export():
		by_id_gpu[r["id"]] = r
	var keys_cpu := by_id_cpu.keys()
	var keys_gpu := by_id_gpu.keys()
	keys_cpu.sort()
	keys_gpu.sort()
	check(keys_cpu == keys_gpu, "apply_events keeps and frees the same records as the CPU's step (%d against %d)" % [keys_gpu.size(), keys_cpu.size()])
	var same := 0
	var dead_kept := 0
	for id in keys_cpu:
		if not by_id_gpu.has(id):
			continue
		var c: Dictionary = by_id_cpu[id].duplicate()
		var g: Dictionary = by_id_gpu[id].duplicate()
		var energy_close := absf(float(c["max_energy"]) - float(g["max_energy"])) <= 1e-6 * maxf(absf(float(c["max_energy"])), 1.0)
		c.erase("max_energy")
		g.erase("max_energy")
		if c == g and energy_close:
			same += 1
		if not c["alive"]:
			dead_kept += 1
	check(same == keys_cpu.size(), "every record apply_events made is the CPU's (%d of %d; the reserve at death to 1e-6)" % [same, keys_cpu.size()])
	check(dead_kept > 0, "some dead records were kept, so their deaths were compared too (%d)" % dead_kept)
	var alive_cpu := cpu.bup_ids()
	alive_cpu.sort()
	check(records.alive_ids() == alive_cpu, "alive_ids from the events' records are the CPU's living bups")
	check(is_equal_approx(records.lineage_info(keys_cpu[0])["born"], cpu.lineage_info(keys_cpu[0])["born"]), "records are stamped with their step's time")
	var again := records.lineage_export()
	var still_kept := PackedByteArray()  # (a birth whose record has since been freed cannot be told from a new one: a batch must be given once)
	for i in births.size() / 64:
		var id := births.decode_u32(i * 64) | (births.decode_u32(i * 64 + 4) << 32)
		if records.has_record(id):
			still_kept.append_array(births.slice(i * 64, i * 64 + 64))
	records.apply_events(still_kept, PackedByteArray(), 20.0, 20.0)
	check(still_kept.size() > 0 and records.lineage_export().size() == again.size(), "a birth given again while its record is kept is not recorded twice")
	var newest := 0
	for id in keys_cpu:
		newest = maxi(newest, id)
	check(records.get_next_id() > newest, "apply_events keeps the next id past every id born (%d, newest %d)" % [records.get_next_id(), newest])
	var added := records.add_bup(Vector2.ZERO, Genome.founder(), 10.0, -1.0, -1.0, 0, Vector2.RIGHT)
	check(records.lineage_info(added)["born"] == int(12345.0 / 60.0), "apply_events puts the sim's clock back as it was")


## The sources' part of a step, alone (step_world), records the same clouds and deposits as a whole step does.
func _world_emissions() -> void:
	for radius in [90000.0, 3000.0]:  # (a coarse grid, where a source lets go of clouds; a fine one, where it feeds the grid)
		var whole := BupSim.new()
		whole.reset(radius, 5)
		var world := BupSim.new()
		world.reset(radius, 5)
		whole.get_field().set_recording(true)
		world.get_field().set_recording(true)
		var pos := PackedVector2Array([Vector2(0.3, 0.1) * radius, Vector2(-0.5, 0.2) * radius, Vector2(0.1, -0.6) * radius])
		var rates := PackedFloat32Array([20.0, 5.0, 60.0])
		var same := true
		var events := 0
		for k in 40:
			if k == 20:  # (a source taken away: what it kept is let go)
				pos.remove_at(1)
				rates.remove_at(1)
			whole.step(20.0, pos, rates, 0.0, 20.0 * (k + 1))
			world.step_world(20.0, pos, rates, 20.0 * (k + 1))
			var puffs_a: PackedFloat32Array = whole.get_field().take_recorded_puffs()
			var puffs_b: PackedFloat32Array = world.get_field().take_recorded_puffs()
			var cells_a: PackedInt32Array = whole.get_field().take_recorded_cells()
			var cells_b: PackedInt32Array = world.get_field().take_recorded_cells()
			var amounts_a: PackedFloat32Array = whole.get_field().take_recorded_amounts()
			var amounts_b: PackedFloat32Array = world.get_field().take_recorded_amounts()
			same = same and puffs_a == puffs_b and cells_a == cells_b and amounts_a == amounts_b
			events += puffs_a.size() / 5 + cells_a.size()
		check(same and events > 0, "step_world records the same clouds and deposits as step does, on a %d mm dish (%d events)" % [int(radius / 1000.0), events])


func _packed_field() -> void:
	var sim := BupSim.new()
	sim.reset(90000.0, 2)
	var field := sim.get_field()
	field.set_patchiness(0.2, 90000.0, 4)
	field.fill(8.0 * Dish.CONCENTRATION_PER_DENSITY)
	for i in 60:
		field.add_cloud(sim.random_point(80000.0), Dish.PLANKTON_PATCH_RADIUS, 300.0 * Dish.NUTRIENT_ENERGY)
	var packed := field.export_packed()
	var puffs: PackedFloat32Array = packed["puffs"]
	check(packed["conc"] == field.values() and puffs.size() == field.puff_count() * 5 and field.puff_count() == 60, "export_packed gives the grid and 5 floats a cloud")
	var other := BupSim.new()
	other.reset(90000.0, 9)
	other.get_field().import_packed(packed["conc"], puffs)
	var back := other.get_field().export_packed()
	check(back["conc"] == packed["conc"] and back["puffs"] == puffs, "import_packed then export_packed gives the same arrays")
	check(absf(other.get_field().total() - field.total()) <= 1e-6 * field.total(), "the nutrient is all there after import_packed (%f against %f)" % [other.get_field().total(), field.total()])
	var empty := PackedFloat32Array([1.0, 2.0, 0.0, 100.0, 1.0])
	other.get_field().import_packed(packed["conc"], empty)
	check(other.get_field().puff_count() == 0, "import_packed drops a cloud with nothing in it")
