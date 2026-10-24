extends SceneTree
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/validate_cloud_uptake.gd -- bups puffs mass_low mass_high reach_um
## One step from the same state with clouds around the bups (the nutrient frozen: no spreading): what the bups gain and what the clouds lose, CPU against GPU.
func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var n := int(a[0]); var np := int(a[1]); var m_lo := float(a[2]); var m_hi := float(a[3]); var reach := float(a[4])
	seed(31)
	SimConstants.apply()
	var consts := SimConstants.build()
	var frozen := consts.duplicate()
	frozen["diffusion"] = 0.0
	BupSim.configure(frozen)
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(5)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 2000000; sc.dish_radius = 90000.0; sc.nutrient_resolution = 100; sc.nutrient_density = 0.0
	sc.spread_founders()
	dish.strike(sc)
	var field = dish.field
	field.set_patchiness(0.0, 1000.0, 1)
	var sim = dish.sim
	var puffs := []
	for i in np:
		var r := randf_range(0.0, 3000.0); var t := randf() * TAU
		puffs.append([r * cos(t), r * sin(t), randf_range(m_lo, m_hi), pow(randf_range(20.0, 300.0), 2.0), 0.001 if randf() < 0.3 else 1.0])
	field.puffs_import(puffs)
	while dish.population() < n:
		var g := Genome.founder()
		var born := Cell.mass_to_add(g)
		var r := reach * sqrt(randf()); var t := randf() * TAU
		sim.add_bup(Vector2(r * cos(t) * 1.0, r * sin(t)), g, Dish.FOUNDER_ENERGY, sqrt(born * 1.5), born, 0, Vector2.RIGHT)
	for id in sim.bup_ids():
		sim.set_bup_energy(id, randf() * 0.5 * sim.bup_max_energy(id))
	var s0: PackedFloat32Array = sim.export_state()
	var b0: PackedByteArray = sim.export_state_bytes()  # (the same bups as s0, as the GPU's records)
	var conc0: PackedFloat32Array = field.values()
	var owner: PackedInt32Array = field.export_owner()
	var puffs0: Array = field.puffs_export()
	dish.step(20.0)
	var s1: PackedFloat32Array = sim.export_state()
	var puffs1: Array = field.puffs_export()
	var idx1 := {}
	for i in s1.size() / GpuSim.STRIDE:
		idx1[int(s1[i * GpuSim.STRIDE])] = i
	var in_state := b0.duplicate()
	for i in s0.size() / GpuSim.STRIDE:
		var j: int = idx1.get(int(s0[i * GpuSim.STRIDE]), -1)
		if j >= 0:
			in_state.encode_float((i * GpuSim.STRIDE + 1) * 4, s1[j * GpuSim.STRIDE + 1])
			in_state.encode_float((i * GpuSim.STRIDE + 2) * 4, s1[j * GpuSim.STRIDE + 2])
	var gpu := GpuSim.new()
	gpu.load_state(field.get_size(), field.get_spacing(), dish.radius, conc0, owner, in_state, consts, 2000000, field.export_fill_weights(), 0.0, 20.0, 0.0, puffs0)
	gpu.run(20.0, 0.0, 0, false)
	var out := gpu.read_bups().to_float32_array()
	var gp := gpu.read_puffs()
	var gain_c := 0.0; var gain_g := 0.0; var sum_abs := 0.0; var matched := 0; var skipped := 0
	for i in s0.size() / GpuSim.STRIDE:
		var j: int = idx1.get(int(s0[i * GpuSim.STRIDE]), -1)
		if j < 0 or s1[j * GpuSim.STRIDE + 6] < out[i * GpuSim.STRIDE + 6] * 0.9:
			skipped += 1
			continue
		var e0 := s0[i * GpuSim.STRIDE + 5]
		var gc := s1[j * GpuSim.STRIDE + 5] - e0
		var gg := out[i * GpuSim.STRIDE + 5] - e0
		gain_c += gc; gain_g += gg; sum_abs += absf(gc - gg); matched += 1
	var m0 := 0.0; var m1 := 0.0; var mg := 0.0; var worst := 0.0; var emptied_c := 0; var emptied_g := 0
	for k in puffs0.size():
		m0 += puffs0[k][2]
	for k in puffs1.size():
		m1 += puffs1[k][2]
	for k in gp.size():
		mg += gp[k][2]
	print("%d bups within %d um of %d clouds (mass %.0f-%.0f): matched %d, skipped %d" % [n, int(reach), np, m_lo, m_hi, matched, skipped])
	print("  net energy change summed: CPU %.4f GPU %.4f (rel diff %.5f); mean |per-bup diff| as share of mean |change|: %.5f" % [gain_c, gain_g, (gain_g - gain_c) / maxf(absf(gain_c), 1e-12), (sum_abs / maxf(matched, 1)) / maxf(absf(gain_c) / maxf(matched, 1), 1e-12)])
	print("  cloud mass: start %.4f, taken by CPU %.4f, by GPU %.4f (rel diff %.5f)" % [m0, m0 - m1, m0 - mg, ((m0 - mg) - (m0 - m1)) / maxf(m0 - m1, 1e-12)])
	quit(0)
