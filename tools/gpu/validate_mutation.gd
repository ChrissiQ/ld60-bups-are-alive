extends SceneTree
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/validate_mutation.gd -- M [parent mutator, default 1] [reach rate, default the game's: raises of a gene's ceiling per division]
## The GPU's division and mutation against the CPU's `mutate_genome`: M bups, all ready to divide, with one parent genome; what the
## daughters' genomes look like (mutations, per-gene change, harm, lethal share, colour) from each.
const Lab := preload("res://tools/gpu/gpu_lab.gd")

func _init() -> void:
	var m := int(OS.get_cmdline_user_args()[0])
	var parent_mutator := float(OS.get_cmdline_user_args()[1]) if OS.get_cmdline_user_args().size() > 1 else 1.0
	SimConstants.apply()
	var consts := SimConstants.build()
	var parent_key := int(OS.get_cmdline_user_args()[5]) if OS.get_cmdline_user_args().size() > 5 else 0
	if OS.get_cmdline_user_args().size() > 2:
		consts["reach_rate"] = float(OS.get_cmdline_user_args()[2])
		if OS.get_cmdline_user_args().size() > 4:
			consts["key_potentiation_rate"] = float(OS.get_cmdline_user_args()[3])
			consts["key_rate"] = float(OS.get_cmdline_user_args()[4])
		BupSim.configure(consts)  # (the processor's side too, after apply)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 2000000; sc.dish_radius = 10000.0
	sc.spread_founders()
	var dish := TestUtil.dish_from(self, sc, 1)
	var field := dish.field
	var template: PackedFloat32Array = dish.sim.export_state_bytes().to_float32_array().slice(0, GpuLayout.RECORD_WORDS)
	# a parent in the middle of every range, with a little harm already (so repairs can happen), the same for every bup
	var genome := {"speed": 20.0, "sense": 50.0, "metabolism": 1.0, "size": 4.0, "hue": 0.33, "sat": 0.7, "val": 1.0, "harm": 0.2, "mutations": 0, "mutator": parent_mutator, "reach": parent_key << 8}
	var bups := PackedFloat32Array()
	bups.resize(m * GpuLayout.RECORD_WORDS)
	for i in m:
		for k in GpuLayout.RECORD_WORDS:
			bups[i * GpuLayout.RECORD_WORDS + k] = template[k]
		var o := i * GpuLayout.RECORD_WORDS
		bups[o] = 0.0; bups[o + 21] = 0.0; bups[o + 22] = GpuLayout.NO_PICTURE; bups[o + 23] = GpuLayout.NO_PICTURE  # (the id is set below, as integers)
		bups[o + 1] = randf_range(-5000.0, 5000.0) * 0.5; bups[o + 2] = randf_range(-5000.0, 5000.0) * 0.5
		bups[o + 5] = 50.0; bups[o + 6] = 20.0; bups[o + 7] = 1.0; bups[o + 12] = float(parent_key << 8); bups[o + 13] = parent_mutator  # (mass 20 >= birth 1 + add 4: divides)
		bups[o + 8] = 20.0; bups[o + 9] = 50.0; bups[o + 10] = 1.0; bups[o + 11] = 4.0; bups[o + 15] = 0.2
		bups[o + 16] = 0.33; bups[o + 17] = 0.7; bups[o + 18] = 1.0; bups[o + 19] = 0.0; bups[o + 20] = 0.0
	var gpu := GpuSim.new()
	var zero := PackedFloat32Array(); zero.resize(field.get_size() * field.get_size())
	var c2 := consts.duplicate()
	c2["uptake_per_size"] = 0.0; c2["death_rate"] = 0.0; c2["base_upkeep"] = 0.0; c2["maintenance_per_mass"] = 0.0; c2["sense_upkeep"] = 0.0; c2["drag_upkeep"] = 0.0; c2["growth_rate"] = 0.0
	var records := bups.to_byte_array()  # (the GPU's records: the ids as integers in words 0 and 21)
	for i in m:
		GpuLayout.set_id(records, i, i + 1)
	var state := GpuSim.State.of_grid(field, dish.radius, records, c2)
	state.conc = zero
	state.limit = m * 2
	state.next_id = m + 1
	gpu.load_state(state)
	Lab.run_steps(gpu, 1)
	var raw := gpu.read_bups()
	var out := raw.to_float32_array()
	var np := out.size() / GpuLayout.RECORD_WORDS
	var gcount := {"n": 0, "lethal_free": 0}
	var gmut := 0.0
	var gmut_n := 0
	var greach := 0.0
	var gkey := [0, 0, 0]
	var gd := _acc()
	for i in np:
		var o := i * GpuLayout.RECORD_WORDS
		if GpuLayout.id_of(raw, i) <= m:
			continue  # a parent
		gmut += out[o + 13]; gmut_n += 1
		var rl := int(out[o + 12] + 0.5)
		gkey[(rl >> 8) & 3] += 1
		greach += (rl & 3) + ((rl >> 2) & 3) + ((rl >> 4) & 3) + ((rl >> 6) & 3)
		_add(gd, out[o + 8] - 20.0, out[o + 9] - 50.0, out[o + 10] - 1.0, out[o + 11] - 4.0, out[o + 15] - 0.2, out[o + 19], out[o + 16] - 0.33, out[o + 17] - 0.7, out[o + 18] - 1.0)
	var children: int = gd["n"]
	var cd := _acc()
	var lethal := 0
	var cmut := 0.0
	var cmut_n := 0
	var creach := 0.0
	var ckey := [0, 0, 0]
	for i in m:
		var r: Dictionary = dish.sim.mutate_genome(genome)
		if r["lethal"]:
			lethal += 1
			continue
		cmut += r["mutator"]; cmut_n += 1
		var rc := int(r["reach"])
		ckey[(rc >> 8) & 3] += 1
		creach += (rc & 3) + ((rc >> 2) & 3) + ((rc >> 4) & 3) + ((rc >> 6) & 3)
		_add(cd, r["speed"] - 20.0, r["sense"] - 50.0, r["metabolism"] - 1.0, r["size"] - 4.0, r["harm"] - 0.2, r["mutations"], fposmod(r["hue"] - 0.33 + 0.5, 1.0) - 0.5, r["sat"] - 0.7, r["val"] - 1.0)
	print("lethal share: GPU %.5f  CPU %.5f" % [1.0 - float(children) / m, float(lethal) / m])
	for k in ["speed", "sense", "metab", "size", "harm", "mutations", "hue", "sat", "val"]:
		print("  %-9s GPU mean %9.5f sd %8.5f share nonzero %.4f | CPU mean %9.5f sd %8.5f share nonzero %.4f" % [k, _mean(gd, k), _sd(gd, k), _nz(gd, k), _mean(cd, k), _sd(cd, k), _nz(cd, k)])
	# the three figures the comparison is judged by, each as the difference in standard errors (of the difference)
	var pg := 1.0 - float(children) / m
	var pc := float(lethal) / m
	print("Z lethal share: GPU %.5f CPU %.5f  %+.2f s.e." % [pg, pc, (pg - pc) / sqrt(pg * (1.0 - pg) / m + pc * (1.0 - pc) / m)])
	var tg := _mean(gd, "trait"); var tc := _mean(cd, "trait")
	print("Z trait-change share: GPU %.5f CPU %.5f  %+.2f s.e." % [tg, tc, (tg - tc) / sqrt(tg * (1.0 - tg) / maxf(gd["n"], 1) + tc * (1.0 - tc) / maxf(cd["n"], 1))])
	var mg := _mean(gd, "mutations"); var mc := _mean(cd, "mutations")
	print("Z mutation count mean: GPU %.5f CPU %.5f  %+.2f s.e." % [mg, mc, (mg - mc) / sqrt(pow(_sd(gd, "mutations"), 2) / maxf(gd["n"], 1) + pow(_sd(cd, "mutations"), 2) / maxf(cd["n"], 1))])
	print("raised ceilings per daughter: GPU %.5f  CPU %.5f" % [greach / maxf(gmut_n, 1), creach / maxf(cmut_n, 1)])
	print("key levels of the daughters (none, potentiated, key) from parent level %d: GPU %.5f %.5f %.5f  CPU %.5f %.5f %.5f" % [parent_key, gkey[0] / maxf(gmut_n, 1), gkey[1] / maxf(gmut_n, 1), gkey[2] / maxf(gmut_n, 1), ckey[0] / maxf(cmut_n, 1), ckey[1] / maxf(cmut_n, 1), ckey[2] / maxf(cmut_n, 1)])
	print("daughter mutator mean: GPU %.4f  CPU %.4f (parent %.1f)" % [gmut / maxf(gmut_n, 1), cmut / maxf(cmut_n, 1), parent_mutator])
	quit(0)

func _acc() -> Dictionary:
	var d := {"n": 0}
	for k in ["speed", "sense", "metab", "size", "harm", "mutations", "hue", "sat", "val", "trait"]:
		d[k] = [0.0, 0.0, 0]
	return d

func _add(d: Dictionary, speed: float, sense: float, metab: float, size: float, harm: float, muts: float, hue: float, sat: float, val: float) -> void:
	d["n"] += 1
	var changed := 1.0 if absf(speed) > 1e-7 or absf(sense) > 1e-7 or absf(metab) > 1e-7 or absf(size) > 1e-7 else 0.0  # (a daughter with any trait changed)
	var vals := {"speed": speed, "sense": sense, "metab": metab, "size": size, "harm": harm, "mutations": muts, "hue": hue, "sat": sat, "val": val, "trait": changed}
	for k in vals:
		var a: Array = d[k]
		a[0] += vals[k]; a[1] += vals[k] * vals[k]
		if absf(vals[k]) > 1e-7:
			a[2] += 1

func _mean(d: Dictionary, k: String) -> float:
	return d[k][0] / maxf(d["n"], 1)

func _sd(d: Dictionary, k: String) -> float:
	var m := _mean(d, k)
	return sqrt(maxf(d[k][1] / maxf(d["n"], 1) - m * m, 0.0))

func _nz(d: Dictionary, k: String) -> float:
	return float(d[k][2]) / maxf(d["n"], 1)
