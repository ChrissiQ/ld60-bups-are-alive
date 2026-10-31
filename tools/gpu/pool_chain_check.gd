extends SceneTree
## One dish run by the pooled field, cloud and death kernels against the same dish run by the single-dish chain (GpuSim.record_steps),
## each on its own local device, step for step. The pooled side is a GpuSim of its own whose buffers are the pool's (one dish at row 0,
## its segment, cells and squares at 0: the pool's indices are the dish's), with the pool's tables added, and life is the single-dish path's kernels on
## it (conj_clear ... finalize, events ... setcount), with DSTATE kept up from CNT by a bridge kernel. tools/gpu/pool_rig.gd has the order.
## Run: tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/pool_chain_check.gd
##
## Expected, written before the first run [derived]: each kernel, run on the same inputs on both sides (the single-dish path's chain's buffers copied to
## the pool's before it), gives the same bits (the records, the cells, the sums, the scales, the lists, the live clouds and the clouds'
## counters), at the first step and after 3, 16 and 37 steps, in each variant:
## C1 20 s steps, 160 steps, a 3 mm dish of 3,000 bups at their limit (the trim displaces, so some deaths give nothing back), scarce food
##    (deaths by starvation give clouds), a third with the acetate key, clouds and deposits from the dish's world every step;
## C2 as C1 with the stationary phase, 64 steps;
## C3 the cloud quota 48 (the single dish's puff_capacity 48, the pool's DP_CLOUD_QUOTA 48 with 262,144 physical slots), 96 steps: the
##    live clouds in order, the counters and the lists' contents equal (the slots past the quota are the pool's own, empty); valid only
##    while the single-dish path's chain cuts no list entry (its PCNT_CUT stays 0: its cut is by thread order, the pool's by whole squares);
## C4 0.25 s steps (the fine path of swimming), 40 steps, where no cloud is handed over: the whole chains equal, step for step;
## C5 puffs_at (the single-dish path's `probe`) and puffs_at_d (`pool_probe`) at 500 points of C1's dish as loaded: equal bit for bit.
## The pooled kernels' arithmetic is the single dish's term for term (the feed of a step is worked out on the host for both: DP_FEED is
## P_FEED); the compiler is allowed to contract it differently, and the one place it does is ALLOWED_ULP's. In C1-C3 the
## whole chains part from that first hand-over on (a bup reads the cells), so they are printed, not judged.

const Rig := preload("res://tools/gpu/pool_rig.gd")
const Lab := preload("res://tools/gpu/gpu_lab.gd")

const K_BRIDGE := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;
	DSTATE[DS_COUNT] = CNT[CNT_BUPS]; DSTATE[DS_SURVIVORS] = CNT[CNT_SURVIVORS]; DSTATE[DS_STEP] = CNT[CNT_STEP]; DSTATE[DS_SEED] = CNT[CNT_SEED];
}
"""

var fails := 0


func ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		fails += 1


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	var sc := StartConditions.new()
	sc.bups = 8; sc.dish_radius = 3000.0; sc.nutrient_density = 2.0; sc.feed_density = 1.0
	var state := Rig.make_state(self, sc, 41, 3000, 0.33, 120)
	state.limit = 3000
	state.step = 20.0
	var variants := [
		{"name": "C1 coarse", "delta": 20.0, "steps": 160, "stationary": false, "quota": 0, "probe": true},
		{"name": "C2 stationary", "delta": 20.0, "steps": 64, "stationary": true, "quota": 0},
		{"name": "C3 quota 48", "delta": 20.0, "steps": 96, "stationary": false, "quota": 48},
		{"name": "C4 fine", "delta": 0.25, "steps": 40, "stationary": false, "quota": 0, "whole": true},
	]
	var few := Rig.make_state(self, sc, 41, 3000, 0.33, 40)  # (as many clouds as the quota variant's slots hold at the start)
	few.limit = 3000
	few.step = 20.0
	for v: Dictionary in variants:
		run_variant(few if v["quota"] > 0 else state, v)
	print("POOL CHAIN CHECK %s (%.1f s)" % ["OK" if fails == 0 else "FAILED (%d)" % fails, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if fails == 0 else 1)


## The pool's tables and scratch, added to `b`'s buffers before its load_state (so its pooled kernels are bound with the rest).
func add_pool_buffers(b: GpuSim, state: GpuSim.State) -> void:
	var count := state.bups.size() / GpuLayout.RECORD_BYTES
	var limit := state.limit if state.limit > 0 else count
	var capacity := ((int(limit * 1.05) + 1024 + 255) / 256) * 256
	var n := state.cells_across
	var z := func(nm: String, size: int) -> void:
		var bytes := PackedByteArray()
		bytes.resize(maxi(size, 16))
		b._bufs[nm] = b.rd.storage_buffer_create(bytes.size(), bytes)
	z.call("WORLD", GpuLayout.WD_WORDS * 4)
	z.call("DISHP", GpuLayout.D_MAX * GpuLayout.DP_WORDS * 4)
	z.call("DSTATE", GpuLayout.D_MAX * GpuLayout.DS_WORDS * 4)
	z.call("BLKDISH", capacity / GpuLayout.BLK_SLOTS * 4)
	z.call("BLKDISH2", capacity / GpuLayout.BLK_SLOTS * 4)
	z.call("CELLDISH", n * n * 4)
	z.call("CBASE", (2 * GpuLayout.D_MAX + 2) * 4)
	z.call("CLIVE", 2 * GpuLayout.D_MAX * 4)
	z.call("HUSK", 1024 * 32)
	z.call("HUSK2", 1024 * 32)
	for nm in ["HDUE", "HEXC", "HAL", "HKEEP"]:
		z.call(nm, 1024 * 4)
	for nm in ["HSUM", "HOFF", "BSUM", "BOFF", "PSUM", "POFF"]:
		z.call(nm, Rig.SCAN_SCRATCH * 4)


## DISHP, DSTATE and WORLD of the pool of one dish, from `b`'s P as its batch set it (the feed of a step, k, the handover, ...).
func upload_tables(b: GpuSim, quota: int, stationary: bool) -> void:
	var pv := func(nm: String) -> float: return b._p[GpuLayout.p_slot(nm)]
	var iterations := maxi(2, 2 * ceili(b._k_total / 0.4))
	var dp := PackedByteArray()
	dp.resize(GpuLayout.D_MAX * GpuLayout.DP_WORDS * 4)
	var u := func(w: int, v: int) -> void: dp.encode_u32(w * 4, v)
	var fl := func(w: int, v: float) -> void: dp.encode_float(w * 4, v)
	u.call(GpuLayout.DP_FIELD_BASE, 0)
	u.call(GpuLayout.DP_CELLS, b.n)
	fl.call(GpuLayout.DP_SPACING, pv.call("spacing"))
	fl.call(GpuLayout.DP_RADIUS, pv.call("radius"))
	fl.call(GpuLayout.DP_HANDOVER, pv.call("handover"))
	u.call(GpuLayout.DP_BIN_BASE, 0)
	u.call(GpuLayout.DP_BINS_ACROSS, b._bins_across)
	fl.call(GpuLayout.DP_BIN_SIZE, pv.call("bin_size"))
	fl.call(GpuLayout.DP_FEED, pv.call("feed"))
	fl.call(GpuLayout.DP_UPKEEP_SCALE, pv.call("upkeep_scale"))
	u.call(GpuLayout.DP_LIMIT, b.limit)
	u.call(GpuLayout.DP_CAP, b.capacity)
	u.call(GpuLayout.DP_FLAGS, (1 << GpuLayout.DPF_RUNNING) | (1 << GpuLayout.DPF_ACETATE) | ((1 << GpuLayout.DPF_STATIONARY) if stationary else 0))
	fl.call(GpuLayout.DP_K_TOTAL, b._k_total)
	fl.call(GpuLayout.DP_K, b._k_total / iterations)
	u.call(GpuLayout.DP_ITERATIONS, iterations)
	u.call(GpuLayout.DP_CLOUD_QUOTA, quota if quota > 0 else b.puff_capacity)
	u.call(GpuLayout.DP_HUSK_QUOTA, 200000)
	u.call(GpuLayout.DP_NUMBER, 1)
	fl.call(GpuLayout.DP_NOISE_REFERENCE, pv.call("noise_reference"))
	b.rd.buffer_update(b._bufs["DISHP"], 0, dp.size(), dp)


func upload_counts(b: GpuSim) -> void:
	var clouds := b.rd.buffer_get_data(b._bufs["PCNT"]).decode_u32(GpuLayout.PCNT_SLOTS * 4)
	var ds := PackedByteArray()
	ds.resize(GpuLayout.DS_WORDS * 4)
	ds.encode_u32(GpuLayout.DS_CLOUD_SLOTS * 4, clouds)
	b.rd.buffer_update(b._bufs["DSTATE"], 0, ds.size(), ds)
	var w := PackedByteArray()
	w.resize(GpuLayout.WD_WORDS * 4)
	w.encode_u32(GpuLayout.WD_SLOTS * 4, b.capacity)
	w.encode_u32(GpuLayout.WD_CLOUD_SLOTS * 4, clouds)
	w.encode_u32(GpuLayout.WD_CELLS * 4, b.n * b.n)
	w.encode_u32(GpuLayout.WD_BINS * 4, b._bins)
	w.encode_u32(GpuLayout.WD_PUFF_CAPACITY * 4, b.puff_capacity)
	w.encode_u32(GpuLayout.WD_HUSK_CAPACITY * 4, 1024)
	b.rd.buffer_update(b._bufs["WORLD"], 0, w.size(), w)


## A pooled kernel on `b` with `groups` groups.
func pd(b: GpuSim, cl: int, kname: String, groups: int, pa := 0.0, pb := 0.0) -> void:
	b.dispatch3(cl, kname, groups * int(b._kernels[kname]["local"]), pa, pb, 0.0)


func scan(b: GpuSim, cl: int, prefix: String, elements: int) -> void:
	var g := GpuKernels.scan_groups(elements)
	pd(b, cl, prefix + "_chunks", g)
	pd(b, cl, prefix + "_sums", 1, float(g))
	pd(b, cl, prefix + "_add", g)


var bridge := {}


func run_bridge(b: GpuSim, cl: int) -> void:
	b.rd.compute_list_bind_compute_pipeline(cl, bridge["pipeline"])
	b.rd.compute_list_bind_uniform_set(cl, bridge["set"], 0)
	b.rd.compute_list_set_push_constant(cl, PackedFloat32Array([0, 0, 0, 0]).to_byte_array(), 16)
	b.rd.compute_list_dispatch(cl, 1, 1, 1)
	b.rd.compute_list_add_barrier(cl)


## One step of the pooled chain on `b` (step `s` of the batch, world step `w`).
func record_pool_step(b: GpuSim, cl: int, s: int, w: int, hint: int) -> void:
	var cells := b.n * b.n
	var cg := ceili(cells / 64.0)
	var bg := GpuKernels.bup_groups(b.capacity)
	var hg := Rig.groups_for(hint)
	run_bridge(b, cl)
	pd(b, cl, "pool_ev_puffs", 1, float(s))
	b.dispatch(cl, "ev_deposits", 1, float(s))
	pd(b, cl, "pool_feed", cg)
	var iterations := maxi(2, 2 * ceili(b._k_total / 0.4))
	for it in iterations:
		var ab := "a" if it % 2 == 0 else "b"
		pd(b, cl, "pool_diffuse_" + ab, cg, float(it), float(cells))
		pd(b, cl, "pool_diffuse2_" + ab, cg, float(it), float(cells))
	pd(b, cl, "pool_puff_advance", hg)
	pd(b, cl, "pool_dep_apply", cg)
	pd(b, cl, "pool_snapshot", cg)
	record_pool_index(b, cl, hint)
	pd(b, cl, "pool_clear", cg)
	pd(b, cl, "pool_puff_clear", hg)
	pd(b, cl, "pool_swim", bg)
	pd(b, cl, "pool_demand", bg)
	pd(b, cl, "pool_cells", cg)
	pd(b, cl, "pool_puff_scale", hg)
	pd(b, cl, "pool_apply", bg)
	pd(b, cl, "pool_puff_commit", hg)
	pd(b, cl, "pool_ac_cells", cg)
	pd(b, cl, "pool_ac_apply", bg)
	b.dispatch(cl, "conj_clear", 65536 * 4 + 2048)
	b.dispatch(cl, "conj_insert", b.capacity)
	b.dispatch(cl, "conj_apply", b.capacity)
	b.dispatch(cl, "life", b.capacity)
	for which in ["s", "k"]:
		b._record_scan(cl, ["scan0_" + which, "scan1", "scan2", "add2", "add1_" + which], b._scan_sizes)
	b.dispatch(cl, "finalize", 1)
	run_bridge(b, cl)
	pd(b, cl, "pool_death_bases", 1)
	pd(b, cl, "pool_husk_spawn", bg)
	pd(b, cl, "pool_death_clouds", bg)
	pd(b, cl, "pool_death_count", GpuLayout.D_MAX / 64)
	pd(b, cl, "pool_husk_age", 1)
	scan(b, cl, "pool_hl", 64)
	pd(b, cl, "pool_husk_leak", 1)
	pd(b, cl, "pool_husk_leak_count", 1)
	pd(b, cl, "pool_cloud_live", hg)
	pd(b, cl, "pool_husk_live", 1)
	pd(b, cl, "pool_cloud_cadence", GpuLayout.D_MAX / 64)
	b.dispatch(cl, "events", b.capacity, float(s), 0.0)
	b.dispatch(cl, "compact", b.capacity * 7)
	b.dispatch(cl, "copy", b.capacity * 7)
	b.dispatch(cl, "ev_count", 1, 0.0, 0.0)
	b.dispatch(cl, "setcount", 1)
	if w % 16 == 15:
		pd(b, cl, "pool_pmark", hg)
		scan(b, cl, "pool_pf", hint)
		pd(b, cl, "pool_pcompact", Rig.groups_for(hint * 2))
		pd(b, cl, "pool_pcopy", Rig.groups_for(hint * 2))
		pd(b, cl, "pool_psetcount", 1)


func record_pool_index(b: GpuSim, cl: int, hint: int) -> void:
	var hg := Rig.groups_for(hint)
	pd(b, cl, "pool_bin_clear", Rig.groups_for(b._bins))
	pd(b, cl, "pool_bin_count", hg)
	scan(b, cl, "pool_bn", b._bins)
	pd(b, cl, "pool_bin_cut", GpuLayout.D_MAX / 64)
	pd(b, cl, "pool_bin_cursor", Rig.groups_for(b._bins))
	pd(b, cl, "pool_bin_scatter", ceili(hint / 64.0))
	pd(b, cl, "pool_bin_sort", ceili(b._bins / 64.0))


## The dish's world sends, at its step `s`: two clouds (one with cut 0.001) and three deposits; every fifth step none.
func events_for(state: GpuSim.State, first: int, steps: int) -> Dictionary:
	var ev := GpuSim.WorldEvents.new()
	for s in steps:
		var rng := RandomNumberGenerator.new()
		rng.seed = 9001 + first + s
		var start := ev.puffs.size() / GpuLayout.EV_PUFF_FLOATS
		var cstart := ev.cells.size()
		var k := 0 if (first + s) % 5 == 4 else 2
		for j in k:
			var c := Rig.random_cloud(rng, state.radius, state.spacing, 1.0 if j == 0 else 0.001, state.constants)
			ev.puffs.append_array(c)
			ev.puffs.append(Rig.row_word(0))
		for j in (0 if k == 0 else 3):
			var c := rng.randi_range(0, state.cells_across * state.cells_across - 1)
			if state.owner[c] == c:
				ev.cells.append(c)
				ev.amounts.append(rng.randf() * 0.0005)
		ev.ranges.append_array(PackedInt32Array([start, k, cstart, ev.cells.size() - cstart]))
	return ev.as_dict()


func run_variant(state: GpuSim.State, v: Dictionary) -> void:
	var name: String = v["name"]
	var quota: int = v["quota"]
	var a := GpuSim.new()
	if quota > 0:
		a.puff_capacity = quota
	a.load_state(state)
	var b := GpuSim.new()
	add_pool_buffers(b, state)
	b.load_state(state)
	var defs := {}
	GpuKernels.add(defs, "chain_bridge", K_BRIDGE, ["CNT", "DSTATE"])
	var src := ShaderSet.from_source(defs)
	var made := src.create(b.rd)
	ok(src.errors.is_empty(), "%s: the bridge compiles %s" % [name, src.errors])
	bridge = made["chain_bridge"]
	bridge["set"] = ShaderSet.uniform_set(b.rd, bridge, b._bufs)
	var missing := []
	for kname: String in b._kernels:
		if kname.begins_with("pool_") and not b._kernels[kname]["set"].is_valid() and kname != "pool_probe":
			missing.append(kname)
	ok(missing.is_empty(), "%s: every pooled kernel is bound on the pool's buffers %s" % [name, missing])
	upload_counts(b)
	var plan := {"delta": v["delta"], "stationary": v["stationary"]}
	var done := 0
	var first_bad := ""
	var cut_seen := false
	var hint := 4096
	if v.get("probe", false):
		upload_tables(b, quota, v["stationary"])
		probe_compare(a, b, name)
	while done < int(v["steps"]):
		var k := mini(8, int(v["steps"]) - done)
		var ev := events_for(state, done, k)
		plan["events"] = ev
		a.prepare_steps(k, plan)
		var cl := a.rd.compute_list_begin()
		a.record_steps(cl, k)
		a.rd.compute_list_end()
		Lab.submit(a)
		b.prepare_steps(k, plan)
		upload_tables(b, quota, v["stationary"])
		cl = b.rd.compute_list_begin()
		b.dispatch(cl, "ev_begin", 1)
		for s in k:
			record_pool_step(b, cl, s, done + s, hint)
		b.rd.compute_list_end()
		Lab.submit(b)
		done += k
		hint = maxi(64, b.rd.buffer_get_data(b._bufs["WORLD"]).decode_u32(GpuLayout.WD_CLOUD_SLOTS * 4))
		var line := compare(a, b, quota > 0)
		if a.overflows()["list_entries_cut"] > 0:
			cut_seen = true
			break
		if line != "" and first_bad == "":
			first_bad = "after step %d: %s" % [done, line]
			break
	var c := a.counts()
	var pc := a.overflows()
	print("%s: %d bups at the end, %d deaths and %d births in the last batch, clouds to the grid %d, list entries cut %d" % [name, c[GpuLayout.CNT_BUPS], c[GpuLayout.CNT_DEATHS], c[GpuLayout.CNT_BIRTHS], pc["clouds_to_grid"], pc["list_entries_cut"]])
	if cut_seen:
		ok(false, "%s: the single-dish path's chain cut list entries (by thread order), so the comparison stops being valid at step %d" % [name, done])
	elif v.get("whole", false):
		ok(first_bad == "", "%s: the pooled chain equals the single-dish path's chain bit for bit over %d steps%s" % [name, done, ": " + first_bad if first_bad != "" else ""])
	else:
		print("%s: the whole chains %s" % [name, "agree over %d steps" % done if first_bad == "" else "part " + first_bad + " (a cloud's hand-over: see ALLOWED below)"])
	if quota > 0:
		ok(pc["clouds_to_grid"] > 0, "%s: the quota binds (%d clouds to the grid)" % [name, pc["clouds_to_grid"]])
	ShaderSet.free_all(b.rd, made)
	a.release()
	b.release()
	for warm in [0, 3, 16, 37]:
		per_kernel(state, v, warm)


## The one difference allowed here: the hand-over of a cloud to the grid (puff_advance) weighs the cells by
## exp(-(dx² + dy²) / 2v), which the Metal compiler contracts (fma) one way in the single-dish path's kernel and another in the pooled one; the weights
## then differ in their last bits, the fixed-point deposit by a few of its units, and a cell by up to this many units in the last place.
const ALLOWED_ULP := 64

## The stages of a step, the single-dish path's kernels and the pooled ones.
const STAGES := ["events", "feed", "diffusion", "clouds spread", "snapshot", "lists", "clear", "swim", "demand", "cells", "puff_scale", "apply",
	"puff_commit", "ac_cells", "ac_apply", "life", "deaths", "compaction"]
## What a stage reads or writes, copied from the single-dish path's chain to the pool's before the stage.
const COPIED := ["BUPS", "CONC", "EFF", "CONC2", "CONC2B", "DLO", "DHI", "RLO", "RHI", "ALO", "AHI", "SCALE", "SCALE2", "AWLO", "AWHI", "ADLO", "ADHI",
	"WANT", "WANTC", "CELLOF", "WANT2", "CELL2", "PDLO", "PDHI", "PSCALE", "BINC", "BINS", "ENT", "ENTD", "DPLO", "DPHI", "CNT", "SURV", "EXCS", "KID",
	"EXCK", "CHILD", "PUFF"]


func stage_a(a: GpuSim, cl: int, st: String) -> void:
	var cells := a.n * a.n
	match st:
		"events":
			a.dispatch(cl, "ev_puffs", 1, 0.0); a.dispatch(cl, "ev_deposits", 1, 0.0)
		"feed":
			a.dispatch(cl, "feed", cells)
		"diffusion":
			a._record_diffusion(cl, a._k_total)
		"clouds spread":
			a.dispatch(cl, "puff_advance", a.puff_capacity); a.dispatch(cl, "dep_apply", cells)
		"snapshot":
			a.dispatch(cl, "snapshot", cells)
		"lists":
			a._record_cloud_index(cl)
		"clear":
			a.dispatch(cl, "clear", cells); a.dispatch(cl, "puff_clear", a.puff_capacity)
		"swim", "demand", "apply", "ac_apply":
			a.dispatch(cl, st, a.capacity)
		"cells", "ac_cells":
			a.dispatch(cl, st, cells)
		"puff_scale", "puff_commit":
			a.dispatch(cl, st, a.puff_capacity)
		"life":
			a.dispatch(cl, "conj_clear", 65536 * 4 + 2048)
			a.dispatch(cl, "conj_insert", a.capacity)
			a.dispatch(cl, "conj_apply", a.capacity)
			a.dispatch(cl, "life", a.capacity)
			for which in ["s", "k"]:
				a._record_scan(cl, ["scan0_" + which, "scan1", "scan2", "add2", "add1_" + which], a._scan_sizes)
			a.dispatch(cl, "finalize", 1)
		"deaths":
			a.dispatch(cl, "death_clouds", a.capacity); a.dispatch(cl, "death_count", 1)
		"compaction":
			a._record_puff_compaction(cl)


func stage_b(b: GpuSim, cl: int, st: String) -> void:
	var cells := b.n * b.n
	var cg := ceili(cells / 64.0)
	var bg := GpuKernels.bup_groups(b.capacity)
	match st:
		"events":
			pd(b, cl, "pool_ev_puffs", 1, 0.0); b.dispatch(cl, "ev_deposits", 1, 0.0)
		"feed":
			pd(b, cl, "pool_feed", cg)
		"diffusion":
			for it in maxi(2, 2 * ceili(b._k_total / 0.4)):
				var ab := "a" if it % 2 == 0 else "b"
				pd(b, cl, "pool_diffuse_" + ab, cg, float(it), float(cells))
				pd(b, cl, "pool_diffuse2_" + ab, cg, float(it), float(cells))
		"clouds spread":
			pd(b, cl, "pool_puff_advance", 64); pd(b, cl, "pool_dep_apply", cg)
		"snapshot":
			pd(b, cl, "pool_snapshot", cg)
		"lists":
			record_pool_index(b, cl, 4096)
		"clear":
			pd(b, cl, "pool_clear", cg); pd(b, cl, "pool_puff_clear", 64)
		"swim", "demand", "apply", "ac_apply":
			pd(b, cl, "pool_" + st, bg)
		"cells", "ac_cells":
			pd(b, cl, "pool_" + st, cg)
		"puff_scale", "puff_commit":
			pd(b, cl, "pool_" + st, 64)
		"life":
			stage_a(b, cl, "life")
		"deaths":
			pd(b, cl, "pool_death_bases", 1); pd(b, cl, "pool_husk_spawn", bg); pd(b, cl, "pool_death_clouds", bg); pd(b, cl, "pool_death_count", GpuLayout.D_MAX / 64)
		"compaction":
			pd(b, cl, "pool_cloud_live", 64); pd(b, cl, "pool_husk_live", 1); pd(b, cl, "pool_cloud_cadence", GpuLayout.D_MAX / 64)
			pd(b, cl, "pool_pmark", 64)
			scan(b, cl, "pool_pf", 4096)
			pd(b, cl, "pool_pcompact", 128); pd(b, cl, "pool_pcopy", 128); pd(b, cl, "pool_psetcount", 1)


## Each kernel on the same inputs: for every stage, a fresh load of both, the single-dish path's chain up to the stage (a few steps in, `warm` whole
## steps first, so that there are deaths and clouds handed over), its buffers copied to the pool's, then the stage on each and the
## outputs compared. Prints the stages that differ and by how much (the largest difference in units in the last place).
func per_kernel(state: GpuSim.State, v: Dictionary, warm: int) -> void:
	var differ := []
	for si in STAGES.size():
		var a := GpuSim.new()
		if v["quota"] > 0:
			a.puff_capacity = v["quota"]
		a.load_state(state)
		var b := GpuSim.new()
		add_pool_buffers(b, state)
		b.load_state(state)
		var plan := {"delta": v["delta"], "stationary": v["stationary"], "events": events_for(state, 0, warm + 1)}
		a.prepare_steps(warm + 1, plan)
		b.prepare_steps(warm + 1, plan)
		upload_tables(b, v["quota"], v["stationary"])
		var cl := a.rd.compute_list_begin()
		a.record_steps(cl, warm)
		a.rd.compute_list_end()
		Lab.submit(a)
		a._steps_recorded = 0
		var events_step := warm
		cl = a.rd.compute_list_begin()
		for k in si:
			if STAGES[k] == "events":
				a.dispatch(cl, "ev_puffs", 1, float(events_step)); a.dispatch(cl, "ev_deposits", 1, float(events_step))
			else:
				stage_a(a, cl, STAGES[k])
		a.rd.compute_list_end()
		Lab.submit(a)
		for nm: String in COPIED:
			var data := a.rd.buffer_get_data(a._bufs[nm])
			var room := b.rd.buffer_get_data(b._bufs[nm]).size()
			b.rd.buffer_update(b._bufs[nm], 0, mini(data.size(), room), data.slice(0, mini(data.size(), room)))
		var cnt := a.counts()
		var top := a.rd.buffer_get_data(a._bufs["PCNT"]).decode_u32(GpuLayout.PCNT_SLOTS * 4)
		var ds := PackedByteArray()
		ds.resize(GpuLayout.DS_WORDS * 4)
		var step_word: int = 15 if STAGES[si] == "compaction" else cnt[GpuLayout.CNT_STEP]  # (the compaction: at the dish's cadence, as the single-dish path runs it)
		for pair in [[GpuLayout.DS_COUNT, cnt[GpuLayout.CNT_BUPS]], [GpuLayout.DS_SURVIVORS, cnt[GpuLayout.CNT_SURVIVORS]], [GpuLayout.DS_STEP, step_word],
				[GpuLayout.DS_SEED, cnt[GpuLayout.CNT_SEED]], [GpuLayout.DS_CLOUD_SLOTS, top]]:
			ds.encode_u32(pair[0] * 4, pair[1])
		b.rd.buffer_update(b._bufs["DSTATE"], 0, ds.size(), ds)
		var w := b.rd.buffer_get_data(b._bufs["WORLD"])
		w.encode_u32(GpuLayout.WD_CLOUD_SLOTS * 4, top)
		w.encode_u32(GpuLayout.WD_SLOTS * 4, b.capacity)
		w.encode_u32(GpuLayout.WD_CELLS * 4, b.n * b.n)
		w.encode_u32(GpuLayout.WD_BINS * 4, b._bins)
		w.encode_u32(GpuLayout.WD_PUFF_CAPACITY * 4, b.puff_capacity)
		w.encode_u32(GpuLayout.WD_HUSK_CAPACITY * 4, 1024)
		b.rd.buffer_update(b._bufs["WORLD"], 0, w.size(), w)
		var cla := a.rd.compute_list_begin()
		var clb := b.rd.compute_list_begin()
		if STAGES[si] == "events":
			a.dispatch(cla, "ev_puffs", 1, float(events_step)); a.dispatch(cla, "ev_deposits", 1, float(events_step))
			pd(b, clb, "pool_ev_puffs", 1, float(events_step)); b.dispatch(clb, "ev_deposits", 1, float(events_step))
		else:
			stage_a(a, cla, STAGES[si])
			stage_b(b, clb, STAGES[si])
		a.rd.compute_list_end()
		b.rd.compute_list_end()
		Lab.submit(a)
		Lab.submit(b)
		var worst := {}
		var top_now := mini(a.rd.buffer_get_data(a._bufs["PCNT"]).decode_u32(GpuLayout.PCNT_SLOTS * 4), b.rd.buffer_get_data(b._bufs["WORLD"]).decode_u32(GpuLayout.WD_CLOUD_SLOTS * 4))
		for nm: String in COPIED:
			if nm == "PUFF" or nm == "CNT":
				continue
			var x := a.rd.buffer_get_data(a._bufs[nm])
			var y := b.rd.buffer_get_data(b._bufs[nm])
			if nm in ["PDLO", "PDHI", "PSCALE"]:  # (a cloud's sums: the pool clears them up to its top, the single-dish path's chain all its slots)
				x = x.slice(0, top_now * 4)
				y = y.slice(0, top_now * 4)
			if x.size() != y.size():  # (the quota variant: the single-dish path's buffers by its slots, the pool's by its own)
				var m := mini(x.size(), y.size())
				x = x.slice(0, m)
				y = y.slice(0, m)
			if x != y:
				worst[nm] = _ulps(x, y)
		var top_a := a.rd.buffer_get_data(a._bufs["PCNT"]).decode_u32(GpuLayout.PCNT_SLOTS * 4)
		var wb := b.rd.buffer_get_data(b._bufs["WORLD"])
		var top_b := wb.decode_u32(GpuLayout.WD_CLOUD_SLOTS * 4)
		var dsb := b.rd.buffer_get_data(b._bufs["DSTATE"], 0, GpuLayout.DS_WORDS * 4)
		if top_a != dsb.decode_u32(GpuLayout.DS_CLOUD_SLOTS * 4):
			worst["cloud counter"] = "%d against %d" % [top_a, dsb.decode_u32(GpuLayout.DS_CLOUD_SLOTS * 4)]
		var pa := Rig._of_row(a.rd.buffer_get_data(a._bufs["PUFF"], 0, maxi(top_a, 1) * 32).to_float32_array(), top_a, 0)
		var pb := Rig._of_row(b.rd.buffer_get_data(b._bufs["PUFF"], 0, maxi(top_b, 1) * 32).to_float32_array(), top_b, 0)
		if pa != pb:
			worst["live clouds"] = _ulps(pa.to_byte_array(), pb.to_byte_array())
		if a.counts() != b.counts():
			worst["CNT"] = "differs"
		a.release()
		b.release()
		if worst.keys() == ["CONC"] and STAGES[si] == "clouds spread" and int(worst["CONC"].get_slice("up to ", 1).to_int()) <= ALLOWED_ULP:
			print("ALLOWED %s after %d steps: clouds spread (pool_puff_advance's hand-over to the grid) %s" % [v["name"], warm, worst])
		elif not worst.is_empty():
			differ.append("%s %s" % [STAGES[si], worst])
	ok(differ.is_empty(), "%s: each kernel on the same inputs (after %d steps) gives the same bits as the single-dish path's%s" % [v["name"], warm, (": " + "; ".join(differ)) if not differ.is_empty() else ""])


## The words that differ between two arrays of floats, and the largest difference in units in the last place.
func _ulps(x: PackedByteArray, y: PackedByteArray) -> String:
	if x.size() != y.size():
		return "%d bytes against %d" % [x.size(), y.size()]
	var count := 0
	var most := 0
	for k in x.size() / 4:
		var u := x.decode_u32(k * 4)
		var t := y.decode_u32(k * 4)
		if u != t:
			count += 1
			most = maxi(most, absi(u - t))
	return "%d words, up to %d ulp" % [count, most]


## "" when a and b agree, else the first thing that differs.
func compare(a: GpuSim, b: GpuSim, quota: bool) -> String:
	var ca := a.rd.buffer_get_data(a._bufs["CNT"])
	var cb := b.rd.buffer_get_data(b._bufs["CNT"])
	if ca != cb:
		return "CNT %s against %s" % [ca.to_int32_array(), cb.to_int32_array()]
	var n := ca.decode_u32(GpuLayout.CNT_BUPS * 4)
	var rb := GpuLayout.RECORD_BYTES
	var line := Rig.diff({"records": a.rd.buffer_get_data(a._bufs["BUPS"], 0, n * rb), "CONC": a.read_conc(), "CONC2": a.read_acetate(),
		"DPLO": a.rd.buffer_get_data(a._bufs["DPLO"]), "DPHI": a.rd.buffer_get_data(a._bufs["DPHI"])},
		{"records": b.rd.buffer_get_data(b._bufs["BUPS"], 0, n * rb), "CONC": b.read_conc(), "CONC2": b.read_acetate(),
		"DPLO": b.rd.buffer_get_data(b._bufs["DPLO"]), "DPHI": b.rd.buffer_get_data(b._bufs["DPHI"])})
	if line != "":
		return line
	var pa := a.rd.buffer_get_data(a._bufs["PCNT"])
	var top_a := pa.decode_u32(GpuLayout.PCNT_SLOTS * 4)
	var ds := b.rd.buffer_get_data(b._bufs["DSTATE"], 0, GpuLayout.DS_WORDS * 4)
	var world := b.rd.buffer_get_data(b._bufs["WORLD"])
	var top_b := world.decode_u32(GpuLayout.WD_CLOUD_SLOTS * 4)
	if top_a != ds.decode_u32(GpuLayout.DS_CLOUD_SLOTS * 4):
		return "cloud slots: the single-dish path's %d, the dish's virtual counter %d" % [top_a, ds.decode_u32(GpuLayout.DS_CLOUD_SLOTS * 4)]
	if pa.decode_u32(GpuLayout.PCNT_TO_GRID * 4) != ds.decode_u32(GpuLayout.DS_CLOUDS_TO_GRID * 4):
		return "clouds to the grid: %d against %d" % [pa.decode_u32(GpuLayout.PCNT_TO_GRID * 4), ds.decode_u32(GpuLayout.DS_CLOUDS_TO_GRID * 4)]
	if ds.decode_u32(GpuLayout.DS_OVERFLOW * 4) != 0 or world.decode_u32(GpuLayout.WD_OVERFLOW * 4) != 0:
		return "the pool's overflow flag is up"
	var puff_a := a.rd.buffer_get_data(a._bufs["PUFF"], 0, maxi(top_a, 1) * 32).to_float32_array()
	var puff_b := b.rd.buffer_get_data(b._bufs["PUFF"], 0, maxi(top_b, 1) * 32).to_float32_array()
	if not quota:
		if top_a != top_b:
			return "the clouds' top: %d against %d" % [top_a, top_b]
		line = Rig.diff({"clouds": puff_a.slice(0, top_a * 8)}, {"clouds": puff_b.slice(0, top_b * 8)})
	else:
		line = Rig.diff({"live clouds": Rig._of_row(puff_a, top_a, 0)}, {"live clouds": Rig._of_row(puff_b, top_b, 0)})
	if line != "":
		return line
	line = Rig.diff({"BINC": a.rd.buffer_get_data(a._bufs["BINC"]), "BINS": a.rd.buffer_get_data(a._bufs["BINS"])},
		{"BINC": b.rd.buffer_get_data(b._bufs["BINC"]), "BINS": b.rd.buffer_get_data(b._bufs["BINS"])})
	if line != "":
		return line
	var nb := a._bins
	var bc := a.rd.buffer_get_data(a._bufs["BINC"]).to_int32_array()
	var bs := a.rd.buffer_get_data(a._bufs["BINS"]).to_int32_array()
	var entries := bs[nb - 1] + bc[nb - 1]
	if entries > 0:
		var ea := a.rd.buffer_get_data(a._bufs["ENTD"], 0, entries * 32).to_float32_array()
		var eb := b.rd.buffer_get_data(b._bufs["ENTD"], 0, entries * 32).to_float32_array()
		var keep_a := PackedFloat32Array()
		var keep_b := PackedFloat32Array()
		for e in entries:
			for j in 6:
				keep_a.append(ea[e * 8 + j])
				keep_b.append(eb[e * 8 + j])
		line = Rig.diff({"list entries": keep_a}, {"list entries": keep_b})
		if line == "" and not quota:
			line = Rig.diff({"ENT": a.rd.buffer_get_data(a._bufs["ENT"], 0, entries * 4)}, {"ENT": b.rd.buffer_get_data(b._bufs["ENT"], 0, entries * 4)})
	return line


## C5: the single-dish path's `probe` on a, `pool_probe` on b, at 500 points (the lists rebuilt first on both, as at a step's start).
func probe_compare(a: GpuSim, b: GpuSim, name: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var pts := PackedFloat32Array()
	var clouds := a.read_clouds()
	for k in 500:
		if k % 2 == 1 and clouds.size() > 0:  # (near a cloud, within about three of its sigmas)
			var j := (k / 2) % (clouds.size() / 5)
			var sg := sqrt(clouds[j * 5 + 3])
			pts.append(clouds[j * 5] + rng.randfn(0.0, 1.5 * sg))
			pts.append(clouds[j * 5 + 1] + rng.randfn(0.0, 1.5 * sg))
			continue
		var ang := rng.randf() * TAU
		var r := a.radius * 1.02 * sqrt(rng.randf())
		pts.append(r * cos(ang))
		pts.append(r * sin(ang))
	Lab.build_index(a)
	var got_a := Lab.probe(a, pts)
	var cl := b.rd.compute_list_begin()
	record_pool_index(b, cl, 4096)
	b.rd.compute_list_end()
	Lab.submit(b)
	var qb := pts.to_byte_array()
	var zeros := PackedByteArray()
	zeros.resize(500 * 16)
	var q := b.rd.storage_buffer_create(qb.size(), qb)
	var r_buf := b.rd.storage_buffer_create(zeros.size(), zeros)
	b.make_external_kernel("pool_probe", ["DISHP", "ENTD", "BINS", "BINC", q, r_buf])
	cl = b.rd.compute_list_begin()
	pd(b, cl, "pool_probe", 8, 500.0, 0.0)
	b.rd.compute_list_end()
	Lab.submit(b)
	var got_b := b.rd.buffer_get_data(r_buf).to_float32_array()
	var nonzero := 0
	for k in 500:
		if got_a[k * 4] > 0.0:
			nonzero += 1
	var parts := []
	for comp in 4:
		var xa := PackedFloat32Array()
		var xb := PackedFloat32Array()
		for k in 500:
			xa.append(got_a[k * 4 + comp])
			xb.append(got_b[k * 4 + comp])
		parts.append("%s %s" % [["c", "gx", "gy", "sigma"][comp], _ulps(xa.to_byte_array(), xb.to_byte_array())])
	ok(got_a == got_b and nonzero > 100, "%s C5: puffs_at and puffs_at_d agree bit for bit at 500 points (%d of them in a cloud; %s)" % [name, nonzero, ", ".join(parts)])
	b.rd.free_rid(q)
	b.rd.free_rid(r_buf)
