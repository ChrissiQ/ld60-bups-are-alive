extends SceneTree
## The family records on the GPU path: scenario B (3 mm dish, 20k cap) for 2 sim-hours through the game's path (Dish.advance ->
## _advance_gpu -> GpuWorld on the main RenderingDevice), the CPU BupSim keeping only the records (from the GPU's events). At 1 h the
## batches in flight are finished by stalling (GpuWorld.finish_pending, as a switch to the CPU does), at 2 h by waiting for the
## readbacks. Each time: every id in a full readback of the GPU's bups has a living record, and as many records are alive as there are
## bups; no event, cloud or list overflow; the history samples all arrived.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/events_check.gd [-- seconds_per_frame [traits]]  (`traits` starts 200 donors with raised ceilings and the key, to check that records of their daughters keep them)

const Tools := preload("res://tools/gpu/world_tools.gd")

var dish: Dish
var per_frame := 1000.0 / 6.0  # (x10,000 at 60 frames a second)
var phase := 0
var waited := 0
var wait_started := 0  ## when the wait for the last results began (msec)
var traits_started := false  ## `traits` was asked for: some founders are donors with raised ceilings
var frames := 0
var started_usec := 0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		per_frame = float(a[0])
	SimConstants.apply()
	dish = Tools.make_dish(self, "B", 1)
	traits_started = a.size() > 1 and a[1] == "traits"
	if traits_started:  # (some donors with raised ceilings and the acetate key among the founders: their daughters carry them in the births' packed word)
		var genome := Genome.founder()
		genome["donor"] = true
		genome["reach"] = 0x0D | (2 << 8)
		for i in 200:
			dish.add_bup(Vector2(randf_range(-1000.0, 1000.0), randf_range(-1000.0, 1000.0)), genome, 30.0)
	Tools.load_onto_gpu(dish, 1)
	started_usec = Time.get_ticks_usec()


func _compare(label: String) -> void:
	var world := dish.gpu_world
	var state := Tools.read_bups(world.gpu)
	var count := state.size() / GpuSim.RECORD_BYTES
	var missing := 0
	for i in count:
		if not dish.sim.has_bup(GpuSim.id_of(state, i)):
			missing += 1
	var wrong := 0  # (the F factor and the reach word a record was born with are the GPU bup's own)
	var donors := 0
	var stale := 0
	var raised := 0
	for i in count:
		var info := dish.sim.lineage_info(GpuSim.id_of(state, i))
		var donor := state.decode_float(i * GpuSim.RECORD_BYTES + 14 * 4) > 0.5
		var reach := int(state.decode_float(i * GpuSim.RECORD_BYTES + 12 * 4) + 0.5)
		if info.is_empty() or bool(info["donor"]) != donor:
			wrong += 1
		if not info.is_empty() and int(info["reach"]) != reach:
			stale += 1  # (a record has the reach word of the bup's birth until it dies: a conjugation can change a living bup's)
		donors += 1 if donor else 0
		raised += 1 if reach > 0 else 0
	TestUtil.show(wrong == 0, "%s: every record has the F factor of its GPU bup (%d wrong; %d donors, %d with a raised ceiling or key; %d of them changed since birth)" % [label, wrong, donors, raised, stale])
	var dead_donors := 0
	var dead_raised := 0
	var dead := 0
	for record: Dictionary in dish.sim.lineage_export():
		if not record["alive"]:
			dead += 1
			dead_donors += 1 if record["donor"] else 0
			dead_raised += 1 if int(record["reach"]) > 0 else 0
	var bad_dead := 0
	for record: Dictionary in dish.sim.lineage_export():
		if not record["alive"] and (float(record["mass"]) <= 0.0 or float(record["birth_mass"]) <= 0.0 or float(record["energy"]) < 0.0 or float(record["div_mass"]) <= float(record["birth_mass"])):
			bad_dead += 1
	TestUtil.show(bad_dead == 0, "%s: every dead record has the mass, reserve and birth mass its death event carried (%d without, of %d)" % [label, bad_dead, dead])
	print("%s: %d dead records, %d with the F factor, %d with a raised ceiling or key" % [label, dead, dead_donors, dead_raised])
	var alive := dish.sim.alive_ids()
	TestUtil.show(missing == 0, "%s: every one of the GPU's %d bups has a living record (%d without)" % [label, count, missing])
	TestUtil.show(alive.size() == count, "%s: living records %d = GPU bups %d" % [label, alive.size(), count])
	var over := Tools.overflows(world.gpu)
	TestUtil.show(over["births_lost"] == 0 and over["deaths_lost"] == 0 and over["clouds_to_grid"] == 0 and over["list_entries_cut"] == 0, "%s: no overflow %s" % [label, str(over)])
	var samples: int = dish.history.fine["pop"].size()
	var expected := roundi((dish.time - dish.history.accum) / DishHistory.INTERVAL)  # (the samples the dish's history clock has taken)
	TestUtil.show(samples == expected, "%s: %d history samples for %.0f s (%d expected); last pop %d, GPU %d" % [label, samples, dish.time, expected, dish.history.fine["pop"][-1] if samples > 0 else -1, count])
	print("%s: records kept %d, time %.1f s, history clock %.6f s, frames %d" % [label, dish.sim.record_count(), dish.time, dish.history.accum, frames])


func _process(_delta: float) -> bool:
	frames += 1
	match phase:
		0:  # running to 1 h, then finish by stalling
			dish.advance(minf(per_frame, 3600.0 - dish.time))
			if dish.time >= 3600.0 - 1e-6:
				print("pending batches at 1 h: ", dish.gpu_world.pending_batches())
				dish.gpu_world.finish_pending()
				for sample: Dictionary in dish.gpu_world.take_history_samples():
					dish._record_history_from(sample["stats"])
				_compare("1 h, finish_pending")
				phase = 1
		1:  # running to 2 h, then wait for the results
			dish.advance(minf(per_frame, 7200.0 - dish.time))
			if dish.time >= 7200.0 - 1e-6:
				phase = 2
				wait_started = Time.get_ticks_msec()
		2:
			dish.gpu_world.bup_count()  # (as the dish's drawing asks every frame: the end of the frame sends what waits, the field's copy too)
			dish.gpu_world.poll()
			for sample: Dictionary in dish.gpu_world.take_history_samples():
				dish._record_history_from(sample["stats"])
			waited += 1
			if (dish.gpu_world.pending_batches() == 0 and not dish.gpu_world._changed and not dish.gpu_world._mirror_in_flight) or (waited > 60 and Time.get_ticks_msec() - wait_started > 3000):  # (frames AND time: a window that is not paced runs hundreds of frames a second, and the field's copy refreshes every 100 ms)
				print("waited %d frames for the last results" % waited)
				_compare("2 h, readbacks")
				var gpu := dish.gpu_world.gpu
				var conc := []
				RenderingServer.call_on_render_thread(func() -> void: conc.append(gpu.read_conc()))
				TestUtil.show(dish.field.values() == conc[0], "2 h: the CPU field's copy (refreshed from the GPU) equals the GPU's grid")
				print("real time %.2f s" % ((Time.get_ticks_usec() - started_usec) / 1e6))
				print("EVENTS CHECK " + ("OK" if TestUtil.failures.is_empty() else "FAILED (%d)" % TestUtil.failures.size()))
				phase = 3
				waited = 0
		3:
			waited += 1  # (a few frames for callbacks still on their way, then quit)
			if waited == 2:
				Tools.release(dish)
			if waited > 4:
				dish.queue_free()
				return true
	return false
