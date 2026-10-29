extends SceneTree
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/validate_clouds.gd -- radius_um res
## (1) reading clouds: the lists by place and the sums, against the CPU's `read` and `min_cloud_sigma`;
## (2) clouds spreading, handed to the grid and eaten (no bups): totals, the grid and what is left, against the CPU, over several steps;
## (3) clouds and deposits that come from plankton bursts and sources as events: the same dish on the CPU (clouds kept there) and on the GPU
##     (clouds kept there, the CPU recording what it would have done).
const Lab := preload("res://tools/gpu/gpu_lab.gd")


func _dish(rad: float, res: int, seed_value: int, bloom: float, nutrient: float) -> Dish:
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 2000; sc.dish_radius = rad; sc.nutrient_resolution = res; sc.nutrient_density = nutrient; sc.bloom_density = bloom
	sc.spread_founders()
	var dish := TestUtil.dish_from(self, sc, seed_value)
	dish.clear_bups()
	return dish


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var rad := float(a[0]); var res := int(a[1])
	seed(21)
	SimConstants.apply()
	var consts := SimConstants.build()
	var gpu := GpuSim.new()
	print("GPU: ", gpu.device_name(), "   dish radius ", rad, " cells ", res)

	# ---- (1) reading
	var dish := _dish(rad, res, 1, 0.0, 0.0)
	var field := dish.field
	field.set_patchiness(0.0, 1000.0, 1)
	var spacing: float = field.get_spacing()
	var puffs := []
	for i in 400:
		var r := rad * 0.9 * sqrt(randf()); var t := randf() * TAU
		var var_v := pow(randf_range(20.0, 0.45 * spacing), 2.0)
		puffs.append([r * cos(t), r * sin(t), randf_range(50.0, 5000.0), var_v, 0.001 if randf() < 0.3 else 1.0])
	field.puffs_import(puffs)
	var state := GpuSim.State.of_grid(field, dish.radius, PackedByteArray(), consts)
	state.clouds = puffs  # (as made, not as the field took them)
	state.limit = 1000
	state.fill_weights = field.export_fill_weights()
	state.diffusion = field.get_diffusion()
	gpu.load_state(state)
	Lab.build_index(gpu)
	var pts := PackedFloat32Array()
	var probes := 20000
	for i in probes:
		var pick: Array = puffs[randi() % puffs.size()]  # (places near clouds, where there is something to read)
		var r := randf_range(0.0, 3.0 * sqrt(pick[3])); var t := randf() * TAU
		pts.append(clampf(pick[0] + r * cos(t), -rad * 0.98, rad * 0.98)); pts.append(clampf(pick[1] + r * sin(t), -rad * 0.98, rad * 0.98))
	var out := Lab.probe(gpu, pts)
	var worst_c := 0.0; var worst_g := 0.0; var worst_s := 0.0; var scale_c := 0.0; var scale_g := 0.0; var nonzero := 0
	for i in probes:
		var cpu_v: Vector3 = field.read(Vector2(pts[i * 2], pts[i * 2 + 1]))
		var cpu_sigma: float = field.min_cloud_sigma(pts[i * 2], pts[i * 2 + 1])
		scale_c = maxf(scale_c, absf(cpu_v.x)); scale_g = maxf(scale_g, absf(cpu_v.y) + absf(cpu_v.z))
		worst_c = maxf(worst_c, absf(cpu_v.x - out[i * 4]))
		worst_g = maxf(worst_g, absf(cpu_v.y - out[i * 4 + 1]) + absf(cpu_v.z - out[i * 4 + 2]))
		if cpu_sigma < 1.0e17:
			nonzero += 1
			worst_s = maxf(worst_s, absf(cpu_sigma - out[i * 4 + 3]) / cpu_sigma)
		elif out[i * 4 + 3] < 1.0e17:
			worst_s = 1.0
	print("(1) reading %d points near clouds (%d reached by some cloud): largest difference in concentration %.6f of the largest (%.4f), in gradient %.6f of the largest, in sigma %.6f (relative)" % [probes, nonzero, worst_c / scale_c, scale_c, worst_g / scale_g, worst_s])

	# ---- (2) spreading, handover and being eaten: no bups, 6 steps
	var dish2 := _dish(rad, res, 2, 0.0, 0.0)
	var f2 := dish2.field
	f2.set_patchiness(0.0, 1000.0, 1)
	var sp2: float = f2.get_spacing()
	var puffs2 := []
	for i in 300:
		var r := rad * 0.9 * sqrt(randf()); var t := randf() * TAU
		puffs2.append([r * cos(t), r * sin(t), randf_range(50.0, 5000.0), pow(randf_range(0.2, 0.55) * sp2, 2.0), 0.001 if randf() < 0.3 else 1.0])  # (some near the size at which they go to the grid)
	f2.puffs_import(puffs2)
	var total0: float = f2.total()
	var g2 := GpuSim.new()
	var state2 := GpuSim.State.of_grid(f2, dish2.radius, PackedByteArray(), consts)
	state2.clouds = puffs2
	state2.limit = 1000
	state2.fill_weights = f2.export_fill_weights()
	state2.diffusion = f2.get_diffusion()
	g2.load_state(state2)
	for step in 6:
		dish2.step(20.0)
	Lab.run_steps(g2, 6)
	var conc_gpu := g2.read_conc()
	var conc_cpu: PackedFloat32Array = f2.values()
	var area := sp2 * sp2
	var grid_cpu := 0.0; var grid_gpu := 0.0; var worst := 0.0; var peak := 0.0
	for i in conc_cpu.size():
		grid_cpu += conc_cpu[i]; grid_gpu += conc_gpu[i]; peak = maxf(peak, conc_cpu[i])
	for i in conc_cpu.size():
		worst = maxf(worst, absf(conc_cpu[i] - conc_gpu[i]) / peak)
	var left_gpu := Lab.puffs(g2)
	var mass_gpu := 0.0
	for pf in left_gpu:
		mass_gpu += pf[2]
	var left_cpu: Array = f2.puffs_export()
	var mass_cpu := 0.0
	for pf in left_cpu:
		mass_cpu += pf[2]
	print("(2) after 6 steps from %d clouds (total %.2f): clouds left CPU %d GPU %d (mass %.2f / %.2f); grid holds CPU %.2f GPU %.2f; total CPU %.4f GPU %.4f (start %.4f); largest cell difference %.6f of the peak" % [puffs2.size(), total0, left_cpu.size(), left_gpu.size(), mass_cpu, mass_gpu, grid_cpu * area, grid_gpu * area, grid_cpu * area + mass_cpu, grid_gpu * area + mass_gpu, total0, worst])
	quit(0)
