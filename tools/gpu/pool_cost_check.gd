extends SceneTree
## What each pooled field, cloud and husk kernel costs at 2M bups, against the single-dish kernel on the same dish: one dish of
## 2,000,000 bups on a 90 mm dish (100 cells across, 20,000 clouds, 20,000 husks), each kernel dispatched `REPS` times in one submit
## and timed by the wall clock from the recording to the end of the sync (Metal's timestamps read 0), as dispatched in a step: the single-dish path's
## by its thread counts (the capacity, the cloud capacity), the pool's on its fixed grids (GpuKernels.bup_groups, scan_groups).
## Run (nothing else on the GPU): tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/pool_cost_check.gd
##
## Expected, written before the first run [derived, to be measured]: the per-bup kernels (swim, demand, apply, ac_apply) within 1.1x of
## the single-dish path's (a grid-stride loop at about two slots a thread was within 1.02x, plus a dish lookup per slot); the cell kernels
## within noise (the same cells); the cloud kernels at or below the single-dish path's (they run over the clouds in use, not the 262,144 slots); the
## grid scans below the single-dish path's three-level scans. The step's field-and-cloud part no dearer than the single-dish path's.

const Rig := preload("res://tools/gpu/pool_rig.gd")
const REPS := 20
const BUPS := 2000000
const CLOUDS := 20000
const HUSKS := 20000

var rows := []


## `target` bups: the founders' records repeated, spread over the dish, reserves from empty to full (ids are not set: no kernel timed
## here reads them).
static func tile_bups(founders: PackedByteArray, target: int, radius: float, seed_v: int, consts: Dictionary) -> PackedByteArray:
	var rb := GpuLayout.RECORD_BYTES
	var out := founders.duplicate()
	while out.size() < target * rb:
		out.append_array(out.slice(0, mini(out.size(), target * rb - out.size())))
	var f := out.to_float32_array()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var w := GpuLayout.RECORD_WORDS
	var reserve := float(consts["reserve_per_mass"])
	for i in target:
		var a := rng.randf() * TAU
		var r := radius * 0.95 * sqrt(rng.randf())
		f[i * w + GpuLayout.R_X] = r * cos(a)
		f[i * w + GpuLayout.R_Y] = r * sin(a)
		f[i * w + GpuLayout.R_ENERGY] = f[i * w + GpuLayout.R_MASS] * reserve * rng.randf()
	return f.to_byte_array()


func time_it(rd: RenderingDevice, record: Callable, reps := REPS) -> float:
	var t0 := Time.get_ticks_usec()
	var cl := rd.compute_list_begin()
	for r in reps:
		record.call(cl)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	return float(Time.get_ticks_usec() - t0) / reps


func _initialize() -> void:
	var sc := StartConditions.new()
	sc.bups = 8; sc.dish_radius = 90000.0; sc.nutrient_density = 32.0; sc.feed_density = 20.0; sc.bup_limit = BUPS
	var st := Rig.make_state(self, sc, 51, 8, 0.1, CLOUDS)
	st.bups = tile_bups(st.bups, BUPS, st.radius, 51, st.constants)
	st.limit = BUPS
	print("dish: %d cells across, %d bups, %d clouds" % [st.cells_across, st.bups.size() / GpuLayout.RECORD_BYTES, st.clouds.size() / 5])
	var old := measure_old(st)
	var pooled := measure_pool(st)
	print("\nkernel | the single-dish path's (µs) | pooled (µs) | ratio | per step")
	var total_old := 0.0
	var total_pool := 0.0
	for row: Array in rows:
		var o: float = old.get(row[0], -1.0)
		var p: float = pooled.get(row[1], -1.0)
		var times: int = row[2]
		if o >= 0.0:
			total_old += o * times
		if p >= 0.0:
			total_pool += p * times
		print("%s | %s | %s | %s | x%d" % [row[1], "%.1f" % o if o >= 0.0 else "-", "%.1f" % p if p >= 0.0 else "-", "%.2f" % (p / o) if o > 0.0 and p >= 0.0 else "-", times])
	print("step's field, cloud and death part: the single-dish path's %.0f µs, pooled %.0f µs (%.2f)" % [total_old, total_pool, total_pool / total_old])
	print("POOL COST CHECK DONE")
	quit(0)


func measure_old(st: GpuSim.State) -> Dictionary:
	var a := GpuSim.new()
	a.load_state(st)
	a.prepare_steps(1, {"delta": 20.0})
	var cells := a.n * a.n
	var pc := a.puff_capacity
	var out := {}
	var one := func(kname: String, threads: int) -> Callable: return func(cl: int) -> void: a.dispatch(cl, kname, threads)
	var plan := [["feed", cells], ["diffuse_a", cells], ["diffuse2_a", cells], ["puff_advance", pc], ["dep_apply", cells], ["snapshot", cells],
		["bin_clear", a._bins], ["bin_count", pc], ["bin_cursor", a._bins], ["bin_scatter", pc], ["bin_sort", a._bins], ["clear", cells], ["puff_clear", pc],
		["swim", a.capacity], ["demand", a.capacity], ["cells", cells], ["puff_scale", pc], ["apply", a.capacity], ["puff_commit", pc], ["ac_cells", cells],
		["ac_apply", a.capacity], ["pmark", pc], ["pcompact", pc * 2], ["pcopy", pc * 2]]
	time_it(a.rd, func(cl: int) -> void: a._record_cloud_index(cl), 1)  # (the lists, so that the reads find their clouds)
	for item: Array in plan:
		out[item[0]] = time_it(a.rd, one.call(item[0], item[1]))
	out["bn scan"] = time_it(a.rd, func(cl: int) -> void: a._record_scan_chain(cl, "bn", a._bin_sizes))
	out["pf scan"] = time_it(a.rd, func(cl: int) -> void: a._record_scan_chain(cl, "pf", a._puff_sizes))
	# the deaths: 1% of the bups dead this step (SURV, EXCS as `life` and its scan leave them)
	var surv := PackedInt32Array()
	surv.resize(a.capacity)
	var excs := PackedInt32Array()
	excs.resize(a.capacity)
	var dead := 0
	for i in BUPS:
		var s := 0 if i % 100 == 37 else 1
		surv[i] = s
		excs[i] = i - dead
		dead += 1 - s
	var sb := surv.to_byte_array()
	var eb := excs.to_byte_array()
	a.rd.buffer_update(a._bufs["SURV"], 0, sb.size(), sb)
	a.rd.buffer_update(a._bufs["EXCS"], 0, eb.size(), eb)
	var c := a.rd.buffer_get_data(a._bufs["CNT"])
	c.encode_u32(GpuLayout.CNT_SURVIVORS * 4, BUPS - dead)
	a.rd.buffer_update(a._bufs["CNT"], 0, c.size(), c)
	out["death_clouds"] = time_it(a.rd, one.call("death_clouds", a.capacity))
	a.release()
	return out


func measure_pool(st: GpuSim.State) -> Dictionary:
	var rig := Rig.new()
	rig.make_kernels()
	assert(rig.errors.is_empty(), str(rig.errors))
	rig.build([{"state": st, "row": 0, "flags": (1 << GpuLayout.DPF_ACETATE) | (1 << GpuLayout.DPF_DEATH_HUSKS), "husk_quota": 200000}], {"poison": false, "delta": 20.0, "husk_capacity": HUSKS * 2})
	# husks: 20,000 spread over the dish, of every age
	var hf := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for k in HUSKS:
		var a := rng.randf() * TAU
		var r := st.radius * 0.9 * sqrt(rng.randf())
		hf.append_array(PackedFloat32Array([r * cos(a), r * sin(a), 1.0, rng.randf() * Biology.HUSK_SECONDS * 2.0, 0.0, Rig.row_word(0), 1.0, 0.0]))
	var hb := hf.to_byte_array()
	rig.rd.buffer_update(rig.bufs["HUSK"], 0, hb.size(), hb)
	var w := rig.read("WORLD")
	w.encode_u32(GpuLayout.WD_HUSK_SLOTS * 4, HUSKS)
	rig.rd.buffer_update(rig.bufs["WORLD"], 0, w.size(), w)
	rig.cloud_hint = CLOUDS
	rig.husk_hint = HUSKS
	var cells := rig.cells
	var cg := ceili(cells / 64.0)
	var bg := GpuKernels.bup_groups(rig.slots)
	var hg := Rig.groups_for(CLOUDS)
	var out := {}
	var one := func(kname: String, groups: int, pa := 0.0, pb := 0.0) -> Callable: return func(cl: int) -> void: rig.dispatch(cl, kname, groups, pa, pb)
	time_it(rig.rd, func(cl: int) -> void: rig.record_index(cl), 1)
	var plan := [["pool_feed", cg], ["pool_diffuse_a", cg], ["pool_diffuse2_a", cg], ["pool_puff_advance", hg], ["pool_dep_apply", cg], ["pool_snapshot", cg],
		["pool_bin_clear", Rig.groups_for(rig.bins)], ["pool_bin_count", hg], ["pool_bin_cut", GpuLayout.D_MAX / 64], ["pool_bin_room", GpuLayout.D_MAX / 64], ["pool_bin_cursor", Rig.groups_for(rig.bins)],
		["pool_bin_scatter", ceili(CLOUDS / 64.0)], ["pool_bin_sort", ceili(rig.bins / 64.0)], ["pool_clear", cg], ["pool_puff_clear", hg], ["pool_swim", bg], ["pool_demand", bg],
		["pool_cells", cg], ["pool_puff_scale", hg], ["pool_apply", bg], ["pool_puff_commit", hg], ["pool_ac_cells", cg], ["pool_ac_apply", bg],
		["pool_pmark", hg], ["pool_pcompact", Rig.groups_for(CLOUDS * 2)], ["pool_pcopy", Rig.groups_for(CLOUDS * 2)], ["pool_cloud_live", hg],
		["pool_cloud_cadence", GpuLayout.D_MAX / 64], ["pool_husk_live", Rig.groups_for(HUSKS)], ["pool_husk_age", Rig.groups_for(HUSKS)], ["pool_husk_leak", Rig.groups_for(HUSKS)],
		["pool_husk_mark", Rig.groups_for(HUSKS)], ["pool_husk_compact", Rig.groups_for(HUSKS)], ["pool_ev_puffs", 1]]
	for item: Array in plan:
		var pb := float(cells) if item[0].begins_with("pool_diffuse") else 0.0
		out[item[0]] = time_it(rig.rd, one.call(item[0], item[1], 0.0, pb))
	out["pool_bn scan"] = time_it(rig.rd, func(cl: int) -> void: rig.scan(cl, "pool_bn", rig.bins))
	out["pool_pf scan"] = time_it(rig.rd, func(cl: int) -> void: rig.scan(cl, "pool_pf", CLOUDS))
	out["pool_hl scan"] = time_it(rig.rd, func(cl: int) -> void: rig.scan(cl, "pool_hl", HUSKS))
	# the deaths: 1% of the bups dead this step
	var surv := PackedInt32Array()
	surv.resize(rig.slots)
	var excs := PackedInt32Array()
	excs.resize(rig.slots)
	var dead := 0
	for i in BUPS:
		var s := 0 if i % 100 == 37 else 1
		surv[i] = s
		excs[i] = i - dead
		dead += 1 - s
	var sb := surv.to_byte_array()
	var eb := excs.to_byte_array()
	rig.rd.buffer_update(rig.bufs["SURV"], 0, sb.size(), sb)
	rig.rd.buffer_update(rig.bufs["EXCS"], 0, eb.size(), eb)
	var ds := rig.read("DSTATE", 0, GpuLayout.DS_WORDS * 4)
	ds.encode_u32(GpuLayout.DS_SURVIVORS * 4, BUPS - dead)
	rig.rd.buffer_update(rig.bufs["DSTATE"], 0, ds.size(), ds)
	out["pool_death_clouds"] = time_it(rig.rd, one.call("pool_death_clouds", bg))
	out["pool_husk_spawn"] = time_it(rig.rd, one.call("pool_husk_spawn", bg))
	out["pool_death_bases"] = time_it(rig.rd, one.call("pool_death_bases", 1))
	out["pool_death_count"] = time_it(rig.rd, one.call("pool_death_count", GpuLayout.D_MAX / 64))
	var iterations: int = rig.dishes[0]["iterations"]
	# the single-dish path's name, the pool's, how many times a step runs it (the diffusion's passes: `iterations` of each field's, half a and half b)
	rows = [["feed", "pool_feed", 1], ["diffuse_a", "pool_diffuse_a", iterations], ["diffuse2_a", "pool_diffuse2_a", iterations],
		["puff_advance", "pool_puff_advance", 1], ["dep_apply", "pool_dep_apply", 1], ["snapshot", "pool_snapshot", 1], ["bin_clear", "pool_bin_clear", 1],
		["bin_count", "pool_bin_count", 1], ["bn scan", "pool_bn scan", 1], ["-", "pool_bin_cut", 1], ["bin_cursor", "pool_bin_cursor", 1],
		["bin_scatter", "pool_bin_scatter", 1], ["bin_sort", "pool_bin_sort", 1], ["clear", "pool_clear", 1], ["puff_clear", "pool_puff_clear", 1],
		["swim", "pool_swim", 1], ["demand", "pool_demand", 1], ["cells", "pool_cells", 1], ["puff_scale", "pool_puff_scale", 1], ["apply", "pool_apply", 1],
		["puff_commit", "pool_puff_commit", 1], ["ac_cells", "pool_ac_cells", 1], ["ac_apply", "pool_ac_apply", 1], ["death_clouds", "pool_death_clouds", 1],
		["-", "pool_death_bases", 1], ["-", "pool_death_count", 1], ["-", "pool_husk_spawn", 1], ["-", "pool_husk_age", 1], ["-", "pool_hl scan", 1], ["-", "pool_husk_leak", 1],
		["-", "pool_cloud_live", 1], ["-", "pool_husk_live", 1], ["-", "pool_cloud_cadence", 1], ["-", "pool_ev_puffs", 1],
		["pmark", "pool_pmark", 0], ["pf scan", "pool_pf scan", 0], ["pcompact", "pool_pcompact", 0], ["pcopy", "pool_pcopy", 0],
		["-", "pool_husk_mark", 0], ["-", "pool_husk_compact", 0]]
	rig.release()
	return out
