extends SceneTree
## Whole runs, CPU against GPU. godot --path . [--rendering-driver metal --position 6000,6000] -s tools/gpu/validate_dynamics.gd -- mode scenario seed
##   GPU_FROM_SOURCE=1 compiles the kernels from gpu/kernels.gd at run time instead of using the imported shaders. NO_BUPS=1 runs the
##   dish without bups (what goes into the field: feed, bursts, sources).
##   mode: cpu | gpu     scenario: A (default dish until 1,000 bups) | B (3 mm dish, 20k cap, feed) | C (90 mm dish, 100k cap, feed) | D-F, L, S, M
##   (tools/gpu/world_tools.gd holds the table)
## An optional fourth argument is the number of sim-hours to run (0 or absent: the scenario's own), and an optional fifth the step's
## length in seconds, a number or a fraction ("100/60": the game's step at x100 and 60 frames a second; default 20). An hour must be a
## whole number of steps, and on the GPU a whole number of batches of 9. Prints one SAMPLE line per sim-hour: mode scenario seed hour
## pop speed sense metabolism size harm energy nutrient

const Tools := preload("res://tools/gpu/world_tools.gd")


func _hours(scenario: String) -> int:
	var extra := OS.get_cmdline_user_args()
	if extra.size() > 3 and int(extra[3]) > 0:
		return int(extra[3])  # (an optional fourth argument: the hours to run)
	return Tools.default_hours(scenario)


## The step's length (s): the optional fifth argument, a number or a fraction such as "1000/60".
func _step_seconds() -> float:
	var extra := OS.get_cmdline_user_args()
	if extra.size() <= 4:
		return 20.0
	var text: String = extra[4]
	if text.contains("/"):
		return float(text.get_slice("/", 0)) / float(text.get_slice("/", 1))
	return float(text)


## DUMP_FIELD=<path>: the grid at each sample, appended as raw floats (n*n each), to compare the fields of two runs.
func _dump(conc: PackedFloat32Array) -> void:
	var path := OS.get_environment("DUMP_FIELD")
	if path == "":
		return
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_buffer(conc.to_byte_array())
	f.close()


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var mode := a[0]; var scenario := a[1]; var seed_value := int(a[2])
	SimConstants.apply()
	var consts := SimConstants.build()
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(seed_value)
	var start := Tools.start_conditions(scenario)
	dish.strike(start)
	if OS.get_environment("NO_BUPS") == "1":
		dish.clear_bups()  # (NO_BUPS=1: the field alone, feed, plankton and sources, to compare what goes into it)
	Tools.place_sources(dish, scenario)
	var field := dish.field
	var hours := _hours(scenario)
	var step := _step_seconds()
	var per_hour := roundi(3600.0 / step)  # (steps in an hour: counted, so that rounding in the clock never moves a sample)
	assert(absf(per_hour * step - 3600.0) < 1e-6 * 3600.0 and per_hour % 9 == 0, "an hour must be a whole number of batches of 9 steps")
	if mode == "cpu":
		var next_hour := 1
		var reached := -1.0
		var steps_done := 0
		while steps_done < hours * per_hour:
			dish.step(step)
			steps_done += 1
			if scenario == "A" and reached < 0.0 and dish.population() >= 1000:
				reached = dish.time / 3600.0
				print("REACHED %s %s %d %.3f" % [mode, scenario, seed_value, reached])
				break
			if steps_done >= next_hour * per_hour:
				var st: Dictionary = dish.population_stats()
				var energy := 0.0
				var ex: PackedFloat32Array = dish.sim.export_state_bytes().to_float32_array()
				var np: int = ex.size() / GpuSim.STRIDE
				for i in np:
					energy += ex[i * GpuSim.STRIDE + 5]
				Tools.sample_line(mode, scenario, seed_value, next_hour, st["count"], [st["speed"], st["sense"], st["metabolism"], st["size"], st["harm"]], energy / maxf(np, 1), field.total())
				_dump(field.values())
				next_hour += 1
				if st["count"] == 0 and OS.get_environment("NO_BUPS") != "1":
					break
	else:
		var gpu := GpuSim.new(null, OS.get_environment("GPU_FROM_SOURCE") == "1")
		var feed_per_second: float = Dish.feed_per_second(start.feed_density)
		var with_world := scenario in ["D", "E", "F"]  # (plankton and sources: the CPU dish runs their part, recording what it would do to the field)
		var start_state: PackedByteArray = dish.sim.export_state_bytes()
		gpu.load_state(field.get_size(), field.get_spacing(), dish.radius, field.values(), field.export_owner(), start_state, consts, start.bup_limit, field.export_fill_weights(), feed_per_second, step, field.get_diffusion(), [], seed_value, 1.0, dish.sim.get_next_id())
		if with_world:
			field.set_recording(true)
			var zeros := []
			zeros.resize(field.get_size() * field.get_size())
			zeros.fill(0.0)
			field.load_values(zeros)
			dish.feed_density = 0.0
			dish.clear_bups()
		var steps_done := 0
		var next_hour := 1
		var area := field.get_spacing() * field.get_spacing()
		while steps_done < hours * per_hour:
			var events := {}
			if with_world:
				var world_events := GpuSim.WorldEvents.new()
				for st in 9:
					dish.step(step)
					world_events.add_step(field)
				events = world_events.as_dict()
			gpu.run_steps(9, events)  # (nine steps: three minutes of sim time at 20 s)
			steps_done += 9
			var cnt := gpu.counts()
			if scenario == "A" and cnt[0] >= 1000:
				print("REACHED %s %s %d %.3f" % [mode, scenario, seed_value, steps_done * step / 3600.0])
				break
			if steps_done >= next_hour * per_hour:
				var bups := gpu.read_bups().to_float32_array()
				var np := cnt[0]
				var sums := [0.0, 0.0, 0.0, 0.0, 0.0]
				var energy := 0.0
				for i in np:
					var o := i * GpuSim.STRIDE
					sums[0] += bups[o + 8]; sums[1] += bups[o + 9]; sums[2] += bups[o + 10]; sums[3] += bups[o + 11]; sums[4] += 1.0 - exp(-bups[o + 15])
					energy += bups[o + 5]
				var conc := gpu.read_conc()
				_dump(conc)
				var total := 0.0
				for v in conc:
					total += v
				total *= area
				if with_world:
					for pf in gpu.read_puffs():
						total += pf[2]
					total += field.total()  # (only what the sources have kept back: the recording field's own grid stays empty)
				for k in 5:
					sums[k] /= maxf(np, 1)
				Tools.sample_line(mode, scenario, seed_value, next_hour, np, sums, energy / maxf(np, 1), total)
				next_hour += 1
				if np == 0 and OS.get_environment("NO_BUPS") != "1":
					break
		print("OVERFLOWS %s %s %d %s" % [mode, scenario, seed_value, str(gpu.overflows())])  # (what found no room on the GPU over the run)
	quit(0)
