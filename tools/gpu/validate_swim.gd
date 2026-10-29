extends SceneTree
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/validate_swim.gd -- N radius_um res
## The coarse swim on the GPU against the CPU's, from the same bups in the same (patchy) field: how far they move along and across
## the local gradient, by how steep a slope they face (s = speed * |grad| / (floor + c)). Random numbers differ, so it is statistics.

static func _grad(eff: PackedFloat32Array, n: int, sp: float, org: float, x: float, y: float) -> Vector3:
	var fx := clampf((x + org) / sp - 0.5, 0.0, n - 1.001)
	var fy := clampf((y + org) / sp - 0.5, 0.0, n - 1.001)
	var x0 := int(fx); var y0 := int(fy)
	var tx := fx - x0; var ty := fy - y0
	var i0 := y0 * n + x0
	var c00 := eff[i0]; var c10 := eff[i0 + 1]; var c01 := eff[i0 + n]; var c11 := eff[i0 + n + 1]
	var top := c00 + (c10 - c00) * tx
	var bottom := c01 + (c11 - c01) * tx
	return Vector3(top + (bottom - top) * ty, ((c10 - c00) + ((c11 - c01) - (c10 - c00)) * ty) / sp, (bottom - top) / sp)


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var n := int(a[0]); var rad := float(a[1]); var res := int(a[2]); var blob := float(a[3]) if a.size() > 3 else 0.0
	seed(11)
	SimConstants.apply()
	var consts := SimConstants.build()
	var frozen := consts.duplicate()
	frozen["diffusion"] = 0.0
	frozen["uptake_per_size"] = 0.0
	BupSim.configure(frozen)
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(9)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 2000000; sc.dish_radius = rad; sc.nutrient_resolution = res; sc.nutrient_density = 32.0
	sc.spread_founders()
	dish.strike(sc)
	var sim := dish.sim
	var field := dish.field
	if blob > 0.0:
		field.deposit_disc(Vector2.ZERO, rad * 0.15, blob)
	while dish.population() < n:
		var g := Genome.founder()
		var born := Cell.mass_to_add(g)
		sim.add_bup(sim.random_point(rad * 0.5), g, Dish.FOUNDER_ENERGY, sqrt(born * 1.5), born, 0, Vector2.RIGHT)
	for id in sim.bup_ids():  # a spread of speeds and senses, so that the bins fill
		pass
	var s0: PackedFloat32Array = sim.export_state_bytes().to_float32_array()
	for i in s0.size() / GpuLayout.RECORD_WORDS:
		s0[i * GpuLayout.RECORD_WORDS + 8] = randf_range(10.0, 60.0)   # speed
		s0[i * GpuLayout.RECORD_WORDS + 9] = randf_range(15.0, 150.0)  # sense
	# the CPU needs the same bups: set their genes through the sim (a bup's genes are what it is built from)
	var ids: PackedInt64Array = sim.bup_ids()
	for i in ids.size():
		var info: Dictionary = sim.bup_info(ids[i])
	dish.clear_bups()
	for i in s0.size() / GpuLayout.RECORD_WORDS:
		var g := {"speed": s0[i * GpuLayout.RECORD_WORDS + 8], "sense": s0[i * GpuLayout.RECORD_WORDS + 9], "metabolism": s0[i * GpuLayout.RECORD_WORDS + 10], "size": s0[i * GpuLayout.RECORD_WORDS + 11]}
		var genome := Genome.founder()
		genome["speed"] = g["speed"]; genome["sense"] = g["sense"]
		sim.add_bup(Vector2(s0[i * GpuLayout.RECORD_WORDS + 1], s0[i * GpuLayout.RECORD_WORDS + 2]), genome, Dish.FOUNDER_ENERGY, sqrt(s0[i * GpuLayout.RECORD_WORDS + 6]), s0[i * GpuLayout.RECORD_WORDS + 7], 0, Vector2.RIGHT)
	var b0: PackedByteArray = sim.export_state_bytes()  # (the bups as the GPU's records; s0 their words as floats, the ids through GpuLayout.id_of)
	s0 = b0.to_float32_array()
	var conc0: PackedFloat32Array = field.values()
	var owner: PackedInt32Array = field.export_owner()
	var nn: int = field.get_size()
	var eff := PackedFloat32Array(); eff.resize(nn * nn)
	for i in nn * nn:
		eff[i] = conc0[owner[i]] if owner[i] >= 0 else 0.0
	dish.step(20.0)
	var b1: PackedByteArray = sim.export_state_bytes()
	var s1: PackedFloat32Array = b1.to_float32_array()
	var gpu := GpuSim.new()
	print("GPU: ", gpu.device_name(), "  bups ", s0.size() / GpuLayout.RECORD_WORDS, "  cells across ", nn, "  spacing ", field.get_spacing(), "  moves ", gpu.moves_for(20.0) if false else "")
	var state := GpuSim.State.of_grid(field, dish.radius, b0, consts)
	state.conc = conc0  # (the field before the CPU's step)
	gpu.load_state(state)
	gpu.run(20.0, 0.0, 0, true)
	var out := gpu.read_bups().to_float32_array()
	var idx1 := {}
	for i in s1.size() / GpuLayout.RECORD_WORDS:
		idx1[GpuLayout.id_of(b1, i)] = i
	var bins := {}
	for i in s0.size() / GpuLayout.RECORD_WORDS:
		var j: int = idx1.get(GpuLayout.id_of(b0, i), -1)
		if j < 0:
			continue
		var gr := _grad(eff, nn, field.get_spacing(), dish.radius, s0[i * GpuLayout.RECORD_WORDS + 1], s0[i * GpuLayout.RECORD_WORDS + 2])
		var glen := sqrt(gr.y * gr.y + gr.z * gr.z) / (float(consts["detection_floor"]) + gr.x)
		if glen < 1e-9:
			continue
		var s_val := s0[i * GpuLayout.RECORD_WORDS + 8] * glen
		var bin := clampi(int(floor(log(s_val) / log(10.0) * 2.0)), -8, 2)
		var ux := gr.y / sqrt(gr.y * gr.y + gr.z * gr.z); var uy := gr.z / sqrt(gr.y * gr.y + gr.z * gr.z)
		var dc := Vector2(s1[j * GpuLayout.RECORD_WORDS + 1] - s0[i * GpuLayout.RECORD_WORDS + 1], s1[j * GpuLayout.RECORD_WORDS + 2] - s0[i * GpuLayout.RECORD_WORDS + 2])
		var dg := Vector2(out[i * GpuLayout.RECORD_WORDS + 1] - s0[i * GpuLayout.RECORD_WORDS + 1], out[i * GpuLayout.RECORD_WORDS + 2] - s0[i * GpuLayout.RECORD_WORDS + 2])
		if not bins.has(bin):
			bins[bin] = {"n": 0, "cu": 0.0, "cu2": 0.0, "cs2": 0.0, "gu": 0.0, "gu2": 0.0, "gs2": 0.0}
		var b: Dictionary = bins[bin]
		b["n"] += 1
		var cu := dc.x * ux + dc.y * uy; var cs := -dc.x * uy + dc.y * ux
		var gu := dg.x * ux + dg.y * uy; var gs := -dg.x * uy + dg.y * ux
		b["cu"] += cu; b["cu2"] += cu * cu; b["cs2"] += cs * cs
		b["gu"] += gu; b["gu2"] += gu * gu; b["gs2"] += gs * gs
	var keys := bins.keys(); keys.sort()
	print("bin = floor(2 log10 s); per bin: CPU | GPU: mean along-slope displacement (um), SD along, SD across")
	for k in keys:
		var b: Dictionary = bins[k]
		if b["n"] < 200:
			continue
		var m := float(b["n"])
		print("  log10 s in [%.1f, %.1f)  n=%5d | CPU mean %7.3f sd_along %7.3f sd_across %7.3f | GPU mean %7.3f sd_along %7.3f sd_across %7.3f" % [k / 2.0, k / 2.0 + 0.5, b["n"], b["cu"] / m, sqrt(b["cu2"] / m - pow(b["cu"] / m, 2)), sqrt(b["cs2"] / m), b["gu"] / m, sqrt(b["gu2"] / m - pow(b["gu"] / m, 2)), sqrt(b["gs2"] / m)])
	quit(0)
