extends SceneTree
## The family records on the GPU path: scenario B (3 mm dish, 20k cap) for 2 sim-hours through the game's path (Dish.advance ->
## _advance_gpu -> GpuWorld on the main RenderingDevice), the CPU BupSim keeping only the records (from the GPU's events). At 1 h the
## batches in flight are finished by stalling (GpuWorld.finish_pending, as a switch to the CPU does), at 2 h by waiting for the
## readbacks. Each time: every id in a full readback of the GPU's bups has a living record, and as many records are alive as there are
## bups; no event, cloud or list overflow; the history samples all arrived.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/events_check.gd [-- seconds_per_frame]

const Tools := preload("res://tools/gpu/world_tools.gd")

var dish: Dish
var per_frame := 1000.0 / 6.0  # (x10,000 at 60 frames a second)
var phase := 0
var waited := 0
var wait_started := 0  ## when the wait for the last results began (msec)
var failures := 0
var frames := 0
var started_usec := 0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		per_frame = float(a[0])
	SimConstants.apply()
	dish = Tools.make_dish(self, "B", 1)
	Tools.load_onto_gpu(dish, 1)
	started_usec = Time.get_ticks_usec()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


func _compare(label: String) -> void:
	var world := dish.gpu_world
	var state := Tools.read_bups(world.gpu)
	var count := state.size() / GpuSim.RECORD_BYTES
	var missing := 0
	for i in count:
		if not dish.sim.has_bup(GpuSim.id_of(state, i)):
			missing += 1
	var alive := dish.sim.alive_ids()
	_check(missing == 0, "%s: every one of the GPU's %d bups has a living record (%d without)" % [label, count, missing])
	_check(alive.size() == count, "%s: living records %d = GPU bups %d" % [label, alive.size(), count])
	var over := Tools.overflows(world.gpu)
	_check(over["births_lost"] == 0 and over["deaths_lost"] == 0 and over["clouds_to_grid"] == 0 and over["list_entries_cut"] == 0, "%s: no overflow %s" % [label, str(over)])
	var samples: int = dish.history["pop"].size()
	var expected := roundi((dish.time - dish._history_accum) / Dish.HISTORY_INTERVAL)  # (the samples the dish's history clock has taken)
	_check(samples == expected, "%s: %d history samples for %.0f s (%d expected); last pop %d, GPU %d" % [label, samples, dish.time, expected, dish.history["pop"][-1] if samples > 0 else -1, count])
	print("%s: records kept %d, time %.1f s, history clock %.6f s, frames %d" % [label, dish.sim.record_count(), dish.time, dish._history_accum, frames])


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
				_check(dish.field.values() == conc[0], "2 h: the CPU field's copy (refreshed from the GPU) equals the GPU's grid")
				print("real time %.2f s" % ((Time.get_ticks_usec() - started_usec) / 1e6))
				print("EVENTS CHECK " + ("OK" if failures == 0 else "FAILED (%d)" % failures))
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
