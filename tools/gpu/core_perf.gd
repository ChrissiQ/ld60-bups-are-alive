extends SceneTree
## The step cost: one 2M dish stepped by SimCore, against the single-dish GpuSim on the same state in
## the same sitting, each on a local device, wall clock around submit and sync. Windowed, through the lock:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/core_perf.gd -- [donors=0.0003] [bups=2000000] [clouds=0] [steps=10] [bloom=10]
##
## The state is the settings (feed 20, bloom 10, nutrient 32, radius 90 mm, 100 cells,
## a 2M limit, 18 s steps): 2M bups spread over the dish with the founder's genes, reserves from none to full,
## masses 0.8 to 1.6 of the birth mass, a share `donors` of donors (0.0003; `donors=0.02` for the conjugation's sensitivity),
## the dish's world after two hours of its bloom (`bloom`, 10: its bursts land during the run, so the clouds grow in number
## from iteration to iteration and both chains slow alike; `bloom=0` keeps the state steady), and `clouds` plankton clouds at the start (variance
## 15,625 to 810,000 µm², a burst's 4,800 units). The 22.75 ms had swim at 4.55 ms, a bup's one sub-step with no
## cloud near it, so its state had next to no clouds where the bups were: `clouds=0` is the like-for-like state, `clouds=62549` a large
## cloud count (a far heavier step: every bup reads tens of cloud entries a sub-step), measured with fewer `steps` a submit.
##
## Expected values, written before the first run:
## - the pooled step at 2M <= 0.85 x the single-dish path's = 19.3 ms [placeholder: the single-dish path's 22.75 ms, measured on its own state];
##   The estimate of the pooled step 15.4 to 20.7 ms [derived]. The single-dish path's on this state is measured here too, so the ratio is the gate's
##   like for like.
## - per kernel: swim, demand, apply about the single-dish path's (the same arithmetic, a grid-stride loop with a block lookup a bup); life's part less by
##   the single-dish path's copy (about 2 ms at 2M) [derived from the subsets].
## The two chains take turns, an iteration each, both loaded at once: a device may run at one of two speeds, mostly the same one for a
## whole process but sometimes switching within it (on an M1 Pro, the single-dish path's 19.5 or 22.4 ms, the pooled 18.2 or 20.5 [measured], in the
## pooled table swim and apply slower, the rest not), both chains alike, so only iterations next to each other compare like for like; the
## ratio is the median of each pair's.
## Reports: PERF lines (median, min, max of 8 iterations of 10 steps, per step, the iteration's stats sample included), the per-kernel
## table (each dispatch its own submit, less a one-thread kernel's round trip, median over 5 steps), and the memory the pool holds.

const RADIUS := 90000.0
const STEP := 18.0
const REPS := 8

var bups := 2000000
var donors := 0.0003
var clouds_at_start := 0
var bloom := 10.0
var STEPS := 10


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("donors="):
			donors = float(a.substr(7))
		if a.begins_with("bups="):
			bups = int(a.substr(5))
		if a.begins_with("clouds="):
			clouds_at_start = int(a.substr(7))
		if a.begins_with("bloom="):
			bloom = float(a.substr(6))
		if a.begins_with("steps="):
			STEPS = int(a.substr(6))
	var t0 := Time.get_ticks_msec()
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = RADIUS
	spec.resolution = 100
	spec.limit = 2000000
	spec.seed = 412556622
	spec.patch_seed = 412556622
	spec.nutrient_density = 32.0
	spec.feed_density = 20.0
	spec.bloom_density = bloom
	var grid := DishGrid.make(spec.radius, spec.resolution, spec.patchiness, spec.patch_seed)
	var recs := _records(bups, donors)
	var clouds := _clouds(clouds_at_start, grid)
	var world := DishWorld.new(RADIUS, 7)
	world.set_medium(spec.diffusion(), grid.spacing, Dish.CLOUD_HANDOVER, Dish.NUTRIENT_ENERGY)
	world.set_bloom(spec.bloom_density)
	world.events(0.0, 400, STEP)  # (two hours: the bloom's plankton float an hour, so bursts are steady from here)
	print("bloom %.1f; state made in %.1f s: %d bups (%d donors), %d clouds, %d plankton floating, grid %d, spacing %.0f um" % [bloom, (Time.get_ticks_msec() - t0) / 1000.0, bups, int(donors * bups), clouds_at_start, world.plankton_count(), grid.n, grid.spacing])
	var windows: Array = []
	for r in REPS + 7:
		windows.append(world.events(world.time, STEPS, STEP))

	var core := SimCore.new()
	print("SimCore kernels' errors: %s" % [core.errors])
	var blob := DishBlob.new()
	blob.spec = spec.to_dict()
	blob.records = recs
	blob.conc = grid.filled(spec.nutrient_density * Dish.CONCENTRATION_PER_DENSITY)
	blob.conc2 = PackedFloat32Array()
	blob.conc2.resize(grid.n * grid.n)
	blob.dplo = SimArena.zeros(grid.n * grid.n * 4)
	blob.dphi = SimArena.zeros(grid.n * grid.n * 4)
	blob.clouds = clouds
	var ds := SimArena.zeros(GpuLayout.DS_WORDS * 4)
	ds.encode_u32(GpuLayout.DS_NEXT_ID_LO * 4, (GpuLayout.make_id(1, bups + 1)) & 0xFFFFFFFF)
	ds.encode_u32(GpuLayout.DS_NEXT_ID_HI * 4, GpuLayout.make_id(1, bups + 1) >> 32)
	ds.encode_u32(GpuLayout.DS_SEED * 4, (spec.seed ^ (spec.seed >> 32)) & 0xFFFFFFFF)
	ds.encode_u32(GpuLayout.DS_CLOUD_SLOTS * 4, clouds_at_start)
	blob.dstate = ds
	var row := core.load_dish(blob)
	var today_sim := _today_load(spec, grid, recs, clouds)
	var plan := IterationPlan.new()
	var w := 0
	var pooled: Array = []
	var recorded: Array = []
	var today: Array = []
	var ratios: Array = []
	for r in REPS + 2:
		plan.events = {row: windows[w]}
		var res := core.run(STEPS, STEP, plan)
		var t := _today_iteration(today_sim, windows[w])
		w += 1
		if r >= 2:
			pooled.append(float(res["gpu_usec"]) / STEPS)
			recorded.append(float(res["record_usec"]) / STEPS)
			today.append(t)
			ratios.append(pooled[-1] / t)
	var prof: Dictionary = {}
	var calls: Dictionary = {}
	for r in 5:
		plan.events = {row: windows[w]}
		w += 1
		var one := core.profile_steps(1, STEP, plan)
		for k: String in one:
			if not prof.has(k):
				prof[k] = []
			prof[k].append(_median(one[k]) if k == "_noop" else _sum(one[k]))
			calls[k] = one[k].size()
	var stats_note := "the profiled steps include one stats sample (pool_stats1, pool_stats2), as an iteration of `run` does"
	print(stats_note)
	print("pool after %d iterations: count %d, cloud slots %d, husks %d, overflow %d, record slots %d of %d, cloud capacity %d, memory %.0f MB" % [REPS + 7, core.count(row), core.world_word(GpuLayout.WD_CLOUD_SLOTS), core.world_word(GpuLayout.WD_HUSK_SLOTS), core.overflow(), core.world_word(GpuLayout.WD_SLOTS), core.arena.slot_cap, core.arena.cloud_cap, core.arena.bytes_now() / 1048576.0])
	var binc := core.rd.buffer_get_data(core.arena.buf("BINC"), 0, core.arena.bin_top * 4).to_int32_array()
	var entries := 0
	for v in binc:
		entries += v
	print("pooled lists: %d entries over %d squares; per iteration (ms a step): %s" % [entries, binc.size(), ", ".join(pooled.map(func(v: float) -> String: return "%.2f" % (v / 1000.0)))])
	var births := core.dstate_row(row).decode_u32(GpuLayout.DS_BIRTHS * 4)
	var deaths := core.dstate_row(row).decode_u32(GpuLayout.DS_DEATHS * 4)
	print("last profiled step: %d births, %d deaths" % [births, deaths])
	core = null
	_today_report(today_sim, today)
	print("PERF pooled step (SimCore.run, %d steps a submit, stats sample included): median %.2f ms, min %.2f, max %.2f; recording %.3f ms a step" % [STEPS, _median(pooled) / 1000.0, pooled.min() / 1000.0, pooled.max() / 1000.0, _median(recorded) / 1000.0])
	print("PERF the single-dish path's step (GpuSim, %d steps a submit, stats sample included): median %.2f ms, min %.2f, max %.2f" % [STEPS, _median(today) / 1000.0, today.min() / 1000.0, today.max() / 1000.0])
	print("PERF ratio pooled / the single-dish path's: %.3f, the median of each iteration's pooled over the single-dish path's iteration right after it (the medians' ratio %.3f; gate 0.85; against the 22.75 ms: %.3f)" % [_median(ratios), _median(pooled) / _median(today), _median(pooled) / 22750.0])
	var noop := _median(prof["_noop"])
	var total := 0.0
	var names: Array = prof.keys()
	names.erase("_noop")
	names.sort_custom(func(a: String, b: String) -> bool: return _median(prof[a]) > _median(prof[b]))
	print("KERNEL table (ms a step; each dispatch a submit, less the round trip %.3f ms; median of 5 steps):" % (noop / 1000.0))
	for k: String in names:
		var v := maxf(_median(prof[k]) - noop * int(calls[k]), 0.0)
		total += v
		print("KERNEL %-24s %8.3f" % [k, v / 1000.0])
	print("KERNEL sum %.2f ms" % (total / 1000.0))
	print("CORE PERF DONE (%.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
	quit()


## The single-dish chain on the same state: GpuSim (imported shaders) loaded from it, and a SimCore that only turns the world's rows
## into events (a dish of the same grid at row 0, base 0). Returns [GpuSim, that SimCore, its row].
func _today_load(spec: DishSpec, grid: DishGrid, recs: PackedByteArray, clouds: PackedFloat32Array) -> Array:
	var st := GpuSim.State.new()
	st.cells_across = grid.n
	st.spacing = grid.spacing
	st.conc = grid.filled(spec.nutrient_density * Dish.CONCENTRATION_PER_DENSITY)
	st.owner = grid.owner
	st.fill_weights = grid.weights
	st.diffusion = spec.diffusion()
	var five := PackedFloat32Array()
	for k in clouds.size() / 8:
		five.append_array(clouds.slice(k * 8, k * 8 + 5))
	st.clouds = five
	st.radius = spec.radius
	st.bups = recs
	st.constants = SimConstants.build()
	st.limit = spec.limit
	st.feed = Dish.feed_per_second(spec.feed_density)
	st.step = STEP
	st.dish_seed = spec.seed
	var g := GpuSim.new()
	g.load_state(st)
	var conv := SimCore.new()
	var dspec := spec.copy()
	dspec.founders = PackedByteArray()
	var row0 := conv.add_dish(dspec)
	assert(row0 == 0)
	return [g, conv, row0]


## One iteration of the single-dish path's chain (STEPS steps and a stats sample, one submit) on the world's `window`: µs a step.
func _today_iteration(today_sim: Array, window: Variant) -> float:
	var g: GpuSim = today_sim[0]
	var conv: SimCore = today_sim[1]
	var ev: Dictionary = conv._world_events(STEPS, {today_sim[2]: window})
	g.prepare_steps(STEPS, {"delta": STEP, "events": ev})
	var cl := g.rd.compute_list_begin()
	g.record_steps(cl, STEPS, {})
	g.record_stats(cl, 0)
	g.rd.compute_list_end()
	var t := Time.get_ticks_usec()
	g.rd.submit()
	g.rd.sync()
	return float(Time.get_ticks_usec() - t) / STEPS


## The single-dish path's lists, its iterations and its kernels one submit each; then frees it.
func _today_report(today_sim: Array, out: Array) -> void:
	var g: GpuSim = today_sim[0]
	var binc := g.rd.buffer_get_data(g.buffer("BINC")).to_int32_array()
	var entries := 0
	for v in binc:
		entries += v
	print("the single-dish path's lists: %d entries over %d squares, %d cloud slots; per iteration (ms a step): %s" % [entries, binc.size(), g.rd.buffer_get_data(g.buffer("PCNT")).decode_u32(0), ", ".join(out.map(func(v: float) -> String: return "%.2f" % (v / 1000.0)))])
	for kname in ["swim", "demand", "apply", "ac_apply", "life", "compact", "copy"]:
		var t: Array = []
		for r in 3:
			var cl := g.rd.compute_list_begin()
			g.dispatch(cl, kname, g.capacity * (7 if kname in ["compact", "copy"] else 1))
			g.rd.compute_list_end()
			var t1 := Time.get_ticks_usec()
			g.rd.submit()
			g.rd.sync()
			t.append(Time.get_ticks_usec() - t1)
		print("TODAY KERNEL %-10s %.3f ms (a submit, round trip included)" % [kname, _median(t) / 1000.0])
	g.release()
	g.rd.free()


## `n` records with the founder's genes over 0.9 of the dish, reserves from none to full, masses 0.8 to 1.6 of the birth mass, a share
## `share` of them donors.
func _records(n: int, share: float) -> PackedByteArray:
	var founder := Scenario.small(1, RADIUS).founder_records(1).to_float32_array()
	var consts := SimConstants.build()
	var f := PackedFloat32Array(founder)
	while f.size() < n * GpuLayout.RECORD_WORDS:
		f.append_array(f.slice(0, mini(f.size(), n * GpuLayout.RECORD_WORDS - f.size())))
	var rng := RandomNumberGenerator.new()
	rng.seed = 2000000
	var born := founder[GpuLayout.R_BIRTH_MASS]
	var per := float(consts["reserve_per_mass"])
	for i in n:
		var o := i * GpuLayout.RECORD_WORDS
		var a := rng.randf() * TAU
		var r := RADIUS * 0.9 * sqrt(rng.randf())
		f[o + GpuLayout.R_X] = r * cos(a)
		f[o + GpuLayout.R_Y] = r * sin(a)
		var h := rng.randf() * TAU
		f[o + GpuLayout.R_DX] = cos(h)
		f[o + GpuLayout.R_DY] = sin(h)
		var mass := born * rng.randf_range(0.8, 1.6)
		f[o + GpuLayout.R_MASS] = mass
		f[o + GpuLayout.R_ENERGY] = mass * per * rng.randf()
		f[o + GpuLayout.R_DONOR] = 1.0 if rng.randf() < share else 0.0
	var out := f.to_byte_array()
	for i in n:
		GpuLayout.set_id(out, i, GpuLayout.make_id(1, i + 1))
	return out


## `n` plankton clouds (8 floats each, word 5 1.0) inside 0.85 of the dish, a burst's energy, spread from just made to near the hand-over.
func _clouds(n: int, grid: DishGrid) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 62549
	var handover := Dish.CLOUD_HANDOVER * grid.spacing
	var out := PackedFloat32Array()
	out.resize(n * 8)
	for k in n:
		var a := rng.randf() * TAU
		var r := RADIUS * 0.85 * sqrt(rng.randf())
		out[k * 8] = r * cos(a)
		out[k * 8 + 1] = r * sin(a)
		out[k * 8 + 2] = Dish.PLANKTON_UNITS * Dish.NUTRIENT_ENERGY
		out[k * 8 + 3] = rng.randf_range(0.25 * Dish.PLANKTON_PATCH_RADIUS * Dish.PLANKTON_PATCH_RADIUS, handover * handover)
		out[k * 8 + 4] = 1.0
		out[k * 8 + 5] = 1.0
	return out


static func _median(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	return float(b[b.size() / 2])


static func _sum(a: Array) -> float:
	var t := 0.0
	for v in a:
		t += float(v)
	return t
