extends SceneTree
## The fine swim (run and tumble) on the GPU against the CPU's, from the same bups in the same fixed nutrient patch:
##   godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/validate_fine.gd -- mode seed [step_seconds] [minutes] [bups]
##   mode: cpu | gpu. Prints one FINE line per minute: mode seed minute mean_signal mean_radius tumbling_share
## The nutrient does not move or get eaten and the bups neither grow, die nor divide, so only the swimming is compared: a bup's
## signal is log(1 + c / floor) where it is, and chemotaxis shows as a rising mean signal and a falling mean distance from the patch's
## centre. Random numbers differ between the backends, so it is statistics: compare the means over several seeds. The step is
## rounded to the nearest that makes a minute a whole number of batches of 9 steps.

const RADIUS := 3000.0
const SIGMA := 600.0
const PEAK := 0.02
const BACKGROUND := 0.0005


static func _signal_at(eff: PackedFloat32Array, n: int, sp: float, org: float, floor_c: float, x: float, y: float) -> float:
	var fx := clampf((x + org) / sp - 0.5, 0.0, n - 1.001)
	var fy := clampf((y + org) / sp - 0.5, 0.0, n - 1.001)
	var x0 := int(fx); var y0 := int(fy)
	var tx := fx - x0; var ty := fy - y0
	var i0 := y0 * n + x0
	var top: float = eff[i0] + (eff[i0 + 1] - eff[i0]) * tx
	var bottom: float = eff[i0 + n] + (eff[i0 + n + 1] - eff[i0 + n]) * tx
	return log(1.0 + (top + (bottom - top) * ty) / floor_c)


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var mode := a[0]
	var seed_value := int(a[1])
	var step := float(a[2]) if a.size() > 2 else 0.25
	var minutes := int(a[3]) if a.size() > 3 else 20
	var count := int(a[4]) if a.size() > 4 else 3000
	seed(seed_value)
	SimConstants.apply()
	var consts := SimConstants.build()
	var frozen := consts.duplicate()
	for key in ["diffusion", "uptake_per_size", "death_rate", "base_upkeep", "maintenance_per_mass", "sense_upkeep", "growth_rate", "drag_upkeep", "trait_mutations", "harmful_mutations"]:
		frozen[key] = 0.0
	BupSim.configure(frozen)
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(seed_value)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 20000; sc.dish_radius = RADIUS; sc.nutrient_density = 0.0; sc.feed_density = 0.0
	sc.spread_founders()
	dish.strike(sc)
	dish.clear_bups()
	var sim := dish.sim
	var field := dish.field
	var n: int = field.get_size()
	var sp: float = field.get_spacing()
	var owner: PackedInt32Array = field.export_owner()
	var patch := []
	patch.resize(field.values().size())
	for i in patch.size():
		patch[i] = 0.0
	var conc := PackedFloat32Array()
	conc.resize(patch.size())
	for i in conc.size():
		var cx := ((i % n) + 0.5) * sp - RADIUS
		var cy := ((i / n) + 0.5) * sp - RADIUS
		conc[i] = BACKGROUND + PEAK * exp(-(cx * cx + cy * cy) / (2.0 * SIGMA * SIGMA))
		patch[i] = conc[i]
	field.load_values(patch)
	var eff := PackedFloat32Array()
	eff.resize(n * n)
	for i in n * n:
		eff[i] = conc[owner[i]] if owner[i] >= 0 else 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7  # (the same bups for both backends and every seed: only the swimming's random numbers differ)
	for i in count:
		var g := Genome.founder()
		var born := Cell.mass_to_add(g)
		var r := sqrt(rng.randf()) * (RADIUS - 100.0)
		var t := rng.randf() * TAU
		sim.add_bup(Vector2(r * cos(t), r * sin(t)), g, Dish.FOUNDER_ENERGY, sqrt(born * 1.5), born, 0, Vector2.from_angle(rng.randf() * TAU))
	var floor_c := float(consts["detection_floor"])
	var batches := maxi(1, roundi(60.0 / step / 9.0))  # (a minute is a whole number of batches of 9 steps: the step is the nearest that makes it so)
	var per_minute := batches * 9
	step = 60.0 / per_minute
	if mode == "cpu":
		for minute in range(1, minutes + 1):
			for k in per_minute:
				dish.step(step)
			var ex: PackedFloat32Array = sim.export_state_bytes().to_float32_array()
			var sum_signal := 0.0
			var sum_radius := 0.0
			var tumbling := 0
			for i in ex.size() / GpuSim.STRIDE:
				var o := i * GpuSim.STRIDE
				sum_signal += _signal_at(eff, n, sp, RADIUS, floor_c, ex[o + 1], ex[o + 2])
				sum_radius += sqrt(ex[o + 1] * ex[o + 1] + ex[o + 2] * ex[o + 2])
				if ex[o + 27] > 0.0:
					tumbling += 1
			var np: int = ex.size() / GpuSim.STRIDE
			print("FINE cpu %d %d %.5f %.2f %.4f" % [seed_value, minute, sum_signal / np, sum_radius / np, float(tumbling) / np])
	else:
		var gpu := GpuSim.new()
		gpu.load_state(n, sp, dish.radius, conc, owner, sim.export_state_bytes(), frozen, 20000, field.export_fill_weights(), 0.0, step, 0.0, [], seed_value, 1.0, sim.get_next_id())
		for minute in range(1, minutes + 1):
			for k in batches:
				gpu.run_steps(9)
			var bups := gpu.read_bups().to_float32_array()
			var np: int = gpu.counts()[0]
			var sum_signal := 0.0
			var sum_radius := 0.0
			var tumbling := 0
			for i in np:
				var o := i * GpuSim.STRIDE
				sum_signal += _signal_at(eff, n, sp, RADIUS, floor_c, bups[o + 1], bups[o + 2])
				sum_radius += sqrt(bups[o + 1] * bups[o + 1] + bups[o + 2] * bups[o + 2])
				if bups[o + 27] > 0.0:
					tumbling += 1
			print("FINE gpu %d %d %.5f %.2f %.4f" % [seed_value, minute, sum_signal / np, sum_radius / np, float(tumbling) / np])
	quit(0)
