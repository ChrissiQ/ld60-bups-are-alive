extends SceneTree
## Whole runs through the game's own path: a real Dish driven by Dish.advance as scripts/main.gd drives it, the backend setting Off (CPU,
## the reference) against On (GPU), at a playback speed. Same scenarios and SAMPLE lines as tools/gpu/validate_dynamics.gd, so
## tools/gpu/compare_dynamics.py reads them unchanged.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/game_dynamics.gd -- mode scenario seed speed [hours]
##   mode: cpu (setting Off: advance(speed/60, 0)) | gpu (setting On: advance(speed/60, FRAME_BUDGET_USEC), a frame between calls)
##   scenario: A B C D E F as validate_dynamics.gd, L (D with a 300,000 cap, bloom 4.0, 16 h), M (90 mm, 1,000,000 cap, nutrient 32, feed 5, bloom 5.0, 12 h)
##   speed: playback speed (x100, x1000, x10000); a virtual frame is speed/60 sim seconds. A request is cut at the hour mark, so every
##   sample is taken exactly on it (the GPU path may do fewer steps than asked: the loop goes on until the mark).
## SAMPLE lines: population and gene means are read at the mark (cpu: Dish.population_stats; gpu: a full readback of the bups), energy
## from the bups' records, nutrient the grid plus the clouds. Other lines: SWITCH (sim time the dish began to run on the GPU), CHK (the
## readback against the dish's cached population_stats a few frames later and against the hourly history sample), PERF (per hour:
## sim seconds per real second, share of the asked sim time done, frames a real second), PERFTOTAL, OVERFLOWS.

const Tools := preload("res://tools/gpu/world_tools.gd")
const MainScript := preload("res://scripts/main.gd")
const HOUR := 3600.0
const MIN_REMAINDER := 2.0  ## a rest of less than this at a mark counts as the mark (a shorter step would be taken for a fine one)

var mode := ""
var scenario := ""
var seed_value := 0
var speed := 1000.0
var dish: Dish
var start: StartConditions
var hours := 0
var chk_pending := []  ## [hour, readback values] waiting for the hour's history sample
var wall_run := 0.0  ## µs spent advancing (not sampling)


func _start(sc_name: String) -> StartConditions:
	var sc := StartConditions.new()
	match sc_name:
		"A":
			sc.spread_founders()
		"B":
			sc.bups = 250; sc.bup_limit = 20000; sc.dish_radius = 3000.0; sc.nutrient_density = 32.0; sc.feed_density = 5.0
			sc.spread_founders()
		"C":
			sc.bups = 250; sc.bup_limit = 100000; sc.dish_radius = 90000.0; sc.nutrient_density = 32.0; sc.feed_density = 2.0
			sc.spread_founders()
		"D":  # a 90 mm dish living on plankton bursts (clouds) and a little starting nutrient
			sc.bups = 250; sc.bup_limit = 100000; sc.dish_radius = 90000.0; sc.nutrient_density = 4.0; sc.bloom_density = 2.0
			sc.spread_founders()
		"E":  # the same dish with three steady sources and a lighter bloom
			sc.bups = 250; sc.bup_limit = 50000; sc.dish_radius = 90000.0; sc.nutrient_density = 8.0; sc.bloom_density = 0.5
			sc.spread_founders()
		"F":  # a 10 mm dish with a bloom: the grid is fine enough to hold a burst, so bursts are deposits on it
			sc.bups = 250; sc.bup_limit = 20000; sc.dish_radius = 10000.0; sc.nutrient_density = 8.0; sc.bloom_density = 0.5
			sc.spread_founders()
		"L":  # D with a 300,000 cap and a heavier bloom
			sc.bups = 250; sc.bup_limit = 300000; sc.dish_radius = 90000.0; sc.nutrient_density = 4.0; sc.bloom_density = 4.0
			sc.spread_founders()
		"M":  # 90 mm dish, a million bups
			sc.bups = 250; sc.bup_limit = 1000000; sc.dish_radius = 90000.0; sc.nutrient_density = 32.0; sc.feed_density = 5.0; sc.bloom_density = 5.0
			sc.spread_founders()
	return sc


func _place_sources(d: Dish, sc_name: String) -> void:
	if sc_name == "E":
		d.place_source(d.global_position + Vector2(-30000.0, 0.0), 20.0)
		d.place_source(d.global_position + Vector2(20000.0, 25000.0), 20.0)
		d.place_source(d.global_position + Vector2(0.0, -40000.0), 20.0)


func _hours_default(sc_name: String) -> int:
	return {"A": 60, "B": 12, "C": 30, "D": 24, "E": 24, "F": 24, "L": 16, "M": 12}[sc_name]


func _line(hour: int, pop: int, means: Array, energy: float, nutrient: float) -> void:
	print("SAMPLE %s %s %d %.2f %d %.4f %.4f %.5f %.5f %.5f %.4f %.2f" % [mode, scenario, seed_value, float(hour), pop, means[0], means[1], means[2], means[3], means[4], energy, nutrient])


func _initialize() -> void:
	_run()


## The state of the GPU read now, in full (stalls): [pop, [speed, sense, metab, size, harm], mean energy, nutrient].
func _read_gpu() -> Array:
	var gpu := dish.gpu_world.gpu
	var out := []
	RenderingServer.call_on_render_thread(func() -> void:
		var bytes := gpu.read_bups()
		var conc := gpu.read_conc()
		var puffs := gpu.read_puffs()
		out.append([bytes, conc, puffs]))
	var bytes: PackedByteArray = out[0][0]
	var bups := bytes.to_float32_array()
	var np := bytes.size() / GpuSim.RECORD_BYTES
	var sums := [0.0, 0.0, 0.0, 0.0, 0.0]
	var energy := 0.0
	for i in np:
		var o := i * GpuSim.STRIDE
		sums[0] += bups[o + 8]; sums[1] += bups[o + 9]; sums[2] += bups[o + 10]; sums[3] += bups[o + 11]; sums[4] += 1.0 - exp(-bups[o + 15])
		energy += bups[o + 5]
	var area := dish.field.get_spacing() * dish.field.get_spacing()
	var total := 0.0
	for v: float in out[0][1]:
		total += v
	total *= area
	for pf in out[0][2]:
		total += pf[2]
	for k in 5:
		sums[k] /= maxf(np, 1)
	return [np, sums, energy / maxf(np, 1), total]


func _read_cpu() -> Array:
	var st: Dictionary = dish.population_stats()
	var energy := 0.0
	var ex: PackedFloat32Array = dish.sim.export_state()
	var np: int = ex.size() / GpuSim.STRIDE
	for i in np:
		energy += ex[i * GpuSim.STRIDE + 5]
	return [st["count"], [st["speed"], st["sense"], st["metabolism"], st["size"], st["harm"]], energy / maxf(np, 1), dish.field.total()]


func _history_values(index: int) -> Array:
	var h := dish.history
	return [h["pop"][index], h["speed"][index], h["sense"][index], h["metabolism"][index], h["size"][index], h["harm"][index] / 100.0]


## Prints the CHK lines of the hours whose history sample has come (the dish records the GPU's samples as they arrive).
func _flush_chk() -> void:
	if dish.gpu_world != null and dish.gpu_active:
		for sample: Dictionary in dish.gpu_world.take_history_samples():
			dish._record_history_from(sample["stats"])
	while not chk_pending.is_empty():
		var item: Array = chk_pending[0]
		var index: int = item[0] * 30 - 1
		if dish.history["pop"].size() <= index:
			return
		chk_pending.pop_front()
		var rb: Array = item[1]
		var hv := _history_values(index)
		var rel := []
		for k in 6:
			var r: float = rb[k]
			rel.append((hv[k] - r) / r if r != 0.0 else 0.0)
		print("CHK_HIST %s %s %d %d pop_readback %d pop_hist %d rel_diff(pop,speed,sense,metab,size,harm) %s" % [mode, scenario, seed_value, item[0], rb[0], hv[0], ", ".join(rel.map(func(x: float) -> String: return "%+.4f" % x))])


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	mode = a[0]; scenario = a[1]; seed_value = int(a[2]); speed = float(a[3])
	hours = int(a[4]) if a.size() > 4 and int(a[4]) > 0 else _hours_default(scenario)
	SimConstants.apply()
	dish = Dish.new()
	root.add_child(dish)
	dish.process_mode = Node.PROCESS_MODE_DISABLED  # (the game's _process draws: not what is measured here)
	dish.set_seed(seed_value)
	start = _start(scenario)
	dish.strike(start)
	_place_sources(dish, scenario)
	dish.set_backend_setting(StartConditions.BACKEND_GPU if mode == "gpu" else StartConditions.BACKEND_CPU)
	var budget: int = MainScript.FRAME_BUDGET_USEC if mode == "gpu" else 0
	print("RUN %s %s seed %d speed x%.0f hours %d limit %d radius %.0f budget %d device %s" % [mode, scenario, seed_value, speed, hours, dish.bup_limit, dish.radius, budget, RenderingServer.get_rendering_device().get_device_name() if RenderingServer.get_rendering_device() != null else "none"])
	var frame_sim := speed / 60.0
	var next_hour := 1
	var switched := mode != "gpu"
	# The game puts the GPU on only after Dish.COARSE_FRAMES_TO_GPU frames of coarse steps in a row (a speed pressed in passing does not
	# move the state), which at x10,000 is 5,000 sim seconds on the processor. So that the GPU runs from the start, both modes begin with
	# that many frames of one coarse 1 s step (30 sim seconds, on the processor in both: 250 founders), then the speed.
	for f in Dish.COARSE_FRAMES_TO_GPU:
		dish.advance(1.0, budget)
		if mode == "gpu":
			await process_frame
	if mode == "gpu" and dish.backend_running() == "gpu":
		switched = true
		print("SWITCH %s %s %d gpu_from_sim_s %.1f (warm-up of %d frames of 1 s)" % [mode, scenario, seed_value, dish.time, Dish.COARSE_FRAMES_TO_GPU])
	var frames := 0
	var hour_frames := 0
	var hour_asked := 0.0
	var hour_done := 0.0
	var hour_usec := 0
	var run_asked := 0.0
	var run_done := 0.0
	var run_usec := 0
	var run_frames := 0
	var gpu_asked := 0.0  # (from the moment the GPU path runs)
	var gpu_done := 0.0
	var gpu_usec := 0
	var gpu_frames := 0
	var idle := 0
	var last_time := -1.0
	var stalled_frames := 0
	var reached := false
	while next_hour <= hours:
		var mark := next_hour * HOUR
		var rest := mark - dish.time
		if rest < MIN_REMAINDER:
			# the mark: sample (these reads are not counted in the run's time)
			var values: Array
			if dish.backend_running() == "gpu":
				values = _read_gpu()
			else:
				values = _read_cpu()
			if mode == "gpu" and dish.backend_running() != "gpu":
				print("WARN hour %d: the dish is not running on the GPU" % next_hour)
			_line(next_hour, values[0], values[1], values[2], values[3])
			if mode == "gpu" and dish.backend_running() == "gpu":
				# the dish's cached stats a few frames after the mark (no steps run meanwhile), and the history sample when it comes
				for f in 5:
					await process_frame
					dish.gpu_world.poll()
				var cs: Dictionary = dish.population_stats()
				var cached := [cs["count"], cs["speed"], cs["sense"], cs["metabolism"], cs["size"], cs["harm"]]
				var rel := []
				for k in 6:
					var r: float = values[0] if k == 0 else values[1][k - 1]
					rel.append((cached[k] - r) / r if r != 0.0 else 0.0)
				print("CHK_CACHED %s %s %d %d pop_readback %d pop_cached %d rel_diff(pop,speed,sense,metab,size,harm) %s" % [mode, scenario, seed_value, next_hour, values[0], cached[0], ", ".join(rel.map(func(x: float) -> String: return "%+.4f" % x))])
				chk_pending.append([next_hour, [values[0], values[1][0], values[1][1], values[1][2], values[1][3], values[1][4]]])
			var secs := hour_usec / 1.0e6
			print("PERF %s %s %d %d pop %d speed %.0f wall_s %.2f sim_per_real %.0f completion %.3f frames %d frames_per_s %.1f" % [mode, scenario, seed_value, next_hour, values[0], speed, secs, HOUR / maxf(secs, 1e-9), hour_done / maxf(hour_asked, 1e-9), hour_frames, hour_frames / maxf(secs, 1e-9)])
			hour_frames = 0; hour_asked = 0.0; hour_done = 0.0; hour_usec = 0
			next_hour += 1
			if scenario == "A" and not reached and values[0] >= 1000:
				print("REACHED %s %s %d %.3f" % [mode, scenario, seed_value, dish.time / HOUR])
				break
			if values[0] == 0:
				break
			continue
		var ask := minf(frame_sim, rest)
		var t0 := Time.get_ticks_usec()
		var done := dish.advance(ask, budget)
		if mode == "gpu":
			await process_frame
		elif frames % 2000 == 1999:
			await process_frame
		var spent := Time.get_ticks_usec() - t0
		frames += 1
		hour_frames += 1
		run_frames += 1
		hour_asked += ask; hour_done += done
		run_asked += ask; run_done += done
		hour_usec += spent; run_usec += spent
		if done <= 0.0:
			idle += 1
		if mode == "gpu":
			_flush_chk()
			if not switched and dish.backend_running() == "gpu":
				switched = true
				print("SWITCH %s %s %d gpu_from_sim_s %.1f (frame %d)" % [mode, scenario, seed_value, dish.time, frames])
			if switched:
				gpu_asked += ask; gpu_done += done; gpu_usec += spent; gpu_frames += 1
		if dish.time == last_time:
			stalled_frames += 1
			if stalled_frames > 6000:
				print("STALL %s %s %d: sim time stuck at %.1f s for 6000 frames" % [mode, scenario, seed_value, dish.time])
				break
		else:
			stalled_frames = 0
			last_time = dish.time
	print("PERFTOTAL %s %s %d speed %.0f sim_h %.2f wall_s %.1f sim_per_real %.0f completion %.3f frames %d idle_frames %d | on_gpu: sim_s %.0f wall_s %.1f sim_per_real %.0f completion %.3f frames %d" % [mode, scenario, seed_value, speed, dish.time / HOUR, run_usec / 1.0e6, dish.time / maxf(run_usec / 1.0e6, 1e-9), run_done / maxf(run_asked, 1e-9), run_frames, idle, gpu_done, gpu_usec / 1.0e6, gpu_done / maxf(gpu_usec / 1.0e6, 1e-9), gpu_done / maxf(gpu_asked, 1e-9), gpu_frames])
	if mode == "gpu" and dish.gpu_world != null and dish.gpu_world.gpu != null:
		# the last hours' history samples may still be on their way
		for f in 120:
			if chk_pending.is_empty():
				break
			_flush_chk()
			dish.population_stats()  # (a getter: it has the end of the frame send the reads still owed)
			await process_frame
		if not chk_pending.is_empty():
			print("NOTE %d hourly history samples not checked (the last hour's fires on the step after the mark, which is not taken)" % chk_pending.size())
		print("OVERFLOWS %s %s %d %s" % [mode, scenario, seed_value, str(dish.gpu_world.overflows())])
		Tools.release(dish)
		for f in 3:
			await process_frame
	quit(0)
