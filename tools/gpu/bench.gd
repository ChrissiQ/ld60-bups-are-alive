extends SceneTree
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/bench.gd -- N radius_um res
## Time per step of the whole GPU step (diffusion, snapshot, swim and growth, uptake) with N bups in a dish of this size.
func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var n := int(a[0]); var rad := float(a[1]); var res := int(a[2]); var np := int(a[3]) if a.size() > 3 else 0  # (np: clouds there already)
	SimConstants.apply()
	var consts := SimConstants.build()
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(2)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 4200000; sc.dish_radius = rad; sc.nutrient_resolution = res; sc.nutrient_density = 32.0; sc.feed_density = 0.0
	sc.spread_founders()
	dish.strike(sc)
	var field := dish.field
	var template: PackedFloat32Array = dish.sim.export_state_bytes().to_float32_array().slice(0, GpuSim.STRIDE)
	var bups := PackedFloat32Array()
	bups.resize(n * GpuSim.STRIDE)
	var max_e := float(consts["reserve_per_mass"]) * template[6]
	for i in n:
		var r := rad * 0.95 * sqrt(randf())
		var t := randf() * TAU
		for k in GpuSim.STRIDE:
			bups[i * GpuSim.STRIDE + k] = template[k]
		bups[i * GpuSim.STRIDE] = 0.0; bups[i * GpuSim.STRIDE + 22] = GpuSim.NO_PICTURE; bups[i * GpuSim.STRIDE + 23] = GpuSim.NO_PICTURE  # (the id is set below, as integers)
		bups[i * GpuSim.STRIDE + 1] = r * cos(t)
		bups[i * GpuSim.STRIDE + 2] = r * sin(t)
		bups[i * GpuSim.STRIDE + 5] = max_e * randf_range(0.2, 0.8)
	var gpu := GpuSim.new()
	var dt := 20.0
	var pieces: int = dish.sim.diffuse_pieces(dt)
	var kp: float = field.get_diffusion() * (dt / pieces) / (field.get_spacing() * field.get_spacing())
	var puffs := []
	for i in np:
		var pr := rad * 0.95 * sqrt(randf()); var pt := randf() * TAU
		puffs.append([pr * cos(pt), pr * sin(pt), 4800.0, pow(randf_range(25.0, 0.45 * field.get_spacing()), 2.0), 0.001 if randf() < 0.1 else 1.0])
	var records := bups.to_byte_array()  # (the GPU's records: the ids as integers in words 0 and 21)
	for i in n:
		GpuSim.set_id(records, i, i + 1)
	gpu.load_state(field.get_size(), field.get_spacing(), dish.radius, field.values(), field.export_owner(), records, consts, n, field.export_fill_weights(), 0.0, dt, field.get_diffusion(), puffs, 2, 1.0, n + 1)
	gpu.run_many(3, dt, kp, pieces)  # (warm up)
	var best := 1e18
	for rep in 5:
		var t0 := Time.get_ticks_usec()
		gpu.run_many(10, dt, kp, pieces)
		best = minf(best, float(Time.get_ticks_usec() - t0) / 10.0)
	# the whole step: with feed, division, death, mutation and compaction (the bups also divide and die here, so the population moves a little)
	gpu.run_steps(3)
	var best_full := 1e18
	for rep in 5:
		var t1 := Time.get_ticks_usec()
		gpu.run_steps(10)
		best_full = minf(best_full, float(Time.get_ticks_usec() - t1) / 10.0)
	if np > 0:
		print("BINSTATS (entries, most in a square, squares used, squares): ", gpu.bin_stats())
	var prof := gpu.profile()
	var parts := []
	for k in prof:
		parts.append("%s %.0f" % [k, prof[k]])
	print("RESULT %s | clouds=%d | N=%d R=%d cells=%d moves=%d pieces=%d | core %.0f us/step | WHOLE STEP %.0f us (-> sustainable about x%.0f) | per kernel (us): %s" % [gpu.device_name(), np, n, rad, field.get_size(), gpu.moves_for(dt), pieces, best, best_full, 10.8e6 / best_full, ", ".join(parts)])
	quit(0)
