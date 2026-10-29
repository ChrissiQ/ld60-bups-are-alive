extends SceneTree
## The acetate key on the GPU against the CPU: 400 bups with half a reserve and no glucose in a dish full of acetate, for one 20 s step, at key level 0, 1 and 2: how much acetate is taken
## and how much the bups gain, from each backend. The gain at level 2 should be KEY_FACTOR times that at level 0 on both.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/validate_key.gd

const COUNT := 400


func _initialize() -> void:
	SimConstants.apply()
	var failures := 0
	var cpu_gain := {}
	var gpu_gain := {}
	for level in [0, 1, 2]:
		var dish := Dish.new()
		root.add_child(dish)
		dish.set_seed(1)
		var sc := StartConditions.new()
		sc.bups = 1; sc.bup_limit = 100000; sc.dish_radius = 20000.0; sc.nutrient_density = 0.0
		dish.strike(sc)
		dish.clear_bups()
		var mass := 12.0
		var genome := Genome.founder()
		genome["reach"] = level << 8
		for i in COUNT:
			dish.sim.add_bup(Vector2(float(i % 20 - 10) * 1500.0, float(i / 20 - 10) * 1500.0), genome, 0.3 * Cell.COST_PER_MASS * mass, sqrt(mass), mass, 0, Vector2.RIGHT)
		var field: NutrientField = dish.field
		var n := field.get_size()
		var acetate := PackedFloat32Array()
		acetate.resize(n * n)
		acetate.fill(Cell.HALF_SATURATION * 4.0)
		dish.acetate.import_packed(acetate, PackedFloat32Array())
		var records := dish.sim.export_state_bytes()
		var zero := PackedFloat32Array()
		zero.resize(n * n)
		var gpu := GpuSim.new()
		var consts := SimConstants.build()
		consts["death_rate"] = 0.0
		var state := GpuSim.State.of_grid(field, dish.radius, records, consts)
		state.conc = zero
		state.acetate = acetate
		state.limit = COUNT * 2
		state.next_id = COUNT + 1
		gpu.load_state(state)
		var before := 0.0
		for v in acetate:
			before += v
		var energy_before := 0.0
		var ex0 := dish.sim.export_state_bytes().to_float32_array()
		for i in COUNT:
			energy_before += ex0[i * GpuSim.STRIDE + 5]
		gpu.run_steps(1)
		var after := 0.0
		for v in gpu.rd.buffer_get_data(gpu.buffer("CONC2")).to_float32_array():
			after += v
		var out := gpu.read_bups().to_float32_array()
		var gpu_body := 0.0
		for i in out.size() / GpuSim.STRIDE:
			gpu_body += out[i * GpuSim.STRIDE + 5] + out[i * GpuSim.STRIDE + 6] * Cell.COST_PER_MASS
		var body0 := 0.0
		for i in COUNT:
			body0 += ex0[i * GpuSim.STRIDE + 5] + ex0[i * GpuSim.STRIDE + 6] * Cell.COST_PER_MASS
		gpu_gain[level] = [before - after, gpu_body - body0]
		var cpu_before: float = dish.acetate.total()
		dish.sim.step(20.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 0.0)
		var ex1 := dish.sim.export_state_bytes().to_float32_array()
		var cpu_body := 0.0
		for i in ex1.size() / GpuSim.STRIDE:
			cpu_body += ex1[i * GpuSim.STRIDE + 5] + ex1[i * GpuSim.STRIDE + 6] * Cell.COST_PER_MASS
		cpu_gain[level] = [(cpu_before - dish.acetate.total()) * 1.0, cpu_body - body0]
		gpu.release()
		dish.free()
	for level in [0, 1, 2]:
		print("level %d: acetate taken GPU %.3f CPU %.3f (per area units) | body gained GPU %.3f CPU %.3f" % [level, gpu_gain[level][0], cpu_gain[level][0], gpu_gain[level][1], cpu_gain[level][1]])
	var rg: float = gpu_gain[2][0] / gpu_gain[0][0]
	var rc: float = cpu_gain[2][0] / cpu_gain[0][0]
	print("key / none, acetate taken: GPU %.3f CPU %.3f (expected %.2f)" % [rg, rc, Genome.KEY_FACTOR])
	if absf(rg - Genome.KEY_FACTOR) > 0.1 or absf(rc - Genome.KEY_FACTOR) > 0.1:
		failures += 1
	print("VALIDATE KEY %s" % ("OK" if failures == 0 else "FAILED"))
	quit(failures)
