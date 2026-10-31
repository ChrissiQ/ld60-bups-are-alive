extends RefCounted
## A pooled world on a local RenderingDevice for the windowed checks of the pooled field, cloud and husk kernels (pool_chain_check.gd,
## pool_isolation_check.gd, pool_cost_check.gd): dishes given as GpuSim.State, laid out as the pool lays them out (a 256-aligned segment
## of records and block of cells each, the squares of their cloud lists one after another, their clouds in the order the dishes are
## given), and the field-and-cloud part of a step recorded with the pooled kernels in the pool's order. The bups' life is the caller's:
## `record_fake_life` marks a share of each dish's bups dead every step (they stay, so the records keep changing) so that the deaths'
## clouds and husks run; pool_chain_check.gd runs the single dish's life kernels on a pool of one.
##
## The order of a step, which the pool's host keeps:
##   pool_ev_puffs and ev_deposits (pa: the step's place in EVR), pool_feed, the diffusion's passes, pool_puff_advance, pool_dep_apply,
##   pool_snapshot, the cloud lists (clear, count, scan, cut, cursor, scatter, sort), pool_clear, pool_puff_clear, pool_swim, pool_demand,
##   pool_cells, pool_puff_scale, pool_apply, pool_puff_commit, pool_ac_cells, pool_ac_apply; life up to its finalize (SURV, EXCS,
##   DS_SURVIVORS; DS_COUNT still the step's first count); pool_death_bases, pool_husk_spawn, pool_death_clouds, pool_death_count; the
##   husks' leak (pool_husk_age, scan hl, pool_husk_leak, pool_husk_leak_count); pool_cloud_live, pool_husk_live, pool_cloud_cadence;
##   then the rest of life, which advances DS_STEP; every 16 world steps the clouds' compaction, at the host's cadence the husks' cull.
##
## A rig is made on one thread and used on it (a local device belongs to its thread). Readbacks stall.

const D_MAX := GpuLayout.D_MAX
const POISON := 12345.678  ## what P's slots of a dish hold in a pool (a pooled kernel that read one would not match its dish alone)
const DISH_SLOTS_OF_P := ["count", "cells", "spacing", "origin", "radius", "limit", "feed", "capacity", "death_puff", "handover", "bin_size",
	"bins_across", "puff_capacity", "entry_capacity", "bins", "event_capacity", "upkeep_scale", "stationary"]
const SCAN_SCRATCH := 4096  ## words of each grid scan's group sums

const K_FAKE_DEATHS := """
void f(uint i, uint d, uint l) {
	if (d == NO_DISH || l >= DS(d, DS_COUNT)) { SURV[i] = 0u; return; }
	uint s = DISH_STREAM(d, l, 4242u);
	float a = u01(s), b = u01(s);
	bool dies = a < pcs.pa;
	SURV[i] = dies ? 0u : 1u;
	BUPS[i * RECORD_WORDS + R_PY] = (dies && b >= pcs.pb) ? -2.0 : 0.0;
	if (!dies) atomicAdd(DS(d, DS_SURVIVORS), 1u);
}
SLOT_LOOP(f)
"""

const K_ROWS := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;
	for (uint d = 0u; d < D_MAX; d++) {
		if (((DPU(d, DP_FLAGS) >> DPF_RUNNING) & 1u) == 0u) continue;
		if (pcs.pa < 0.5) DS(d, DS_SURVIVORS) = 0u; else DS(d, DS_STEP) += 1u;
	}
}
"""

var rd: RenderingDevice
var own_device := false
var made := {}
var errors: Array[String] = []
var bufs := {}
var _sets := {}
var dishes: Array = []  ## per dish, in pool order: {"state", "row", "flags", "cloud_quota", "husk_quota", "n", "count", "start", "seg", "base", "cells", "bin_base", "bins_across", "iterations", "k", "feed_step", "seed", "spacing", "radius", "handover", "events_rng_seed"}
var slots := 0
var cells := 0
var bins := 0
var puff_capacity := 0
var husk_capacity := 0
var delta := 120.0
var diffusion := 0.0
var p := PackedFloat32Array()
var world_step := 0
var poison := true


## `device` null: a local device of the rig's own.
func _init(device: RenderingDevice = null) -> void:
	rd = device if device != null else RenderingServer.create_local_rendering_device()
	own_device = device == null
	assert(rd != null, "no local rendering device (run with a window)")


## The kernels: the pool's (imported SPIR-V, as the game loads them) and this rig's (from source). `extra`: more kernel definitions
## (GpuKernels.add's form) of the caller's, from source.
func make_kernels(extra := {}) -> void:
	var all := GpuKernels.all()
	var pooled := {}
	for kname: String in all:
		if kname.begins_with("pool_") or kname in ["ev_deposits"]:
			pooled[kname] = all[kname]
	var imported := ShaderSet.imported(pooled)
	made = imported.create(rd)
	errors.append_array(imported.errors)
	var own := {}
	GpuKernels.add(own, "rig_fake_deaths", K_FAKE_DEATHS, ["WORLD", "BLKDISH", "DSTATE", "DISHP", "BUPS", "SURV"])
	GpuKernels.add(own, "rig_rows", K_ROWS, ["DSTATE", "DISHP"])
	GpuKernels.add_grid_scan(own, "rig_ex", "SURV", "EXCS", "RSUM", "ROFF", "WORLD[WD_SLOTS]", ["WORLD"])
	own.merge(extra)
	var src := ShaderSet.from_source(own)
	made.merge(src.create(rd))
	errors.append_array(src.errors)


static func align256(v: int) -> int:
	return ((v + 255) / 256) * 256


static func f32(v: float) -> float:
	var a := PackedFloat32Array([v])
	return a[0]


static func fbits(v: float) -> int:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b.decode_u32(0)


## Lays the dishes out and makes every buffer. `specs`: per dish (pool order) {"state": GpuSim.State, "row": int, "flags": DPF bits
## (RUNNING is added unless "running" is false), "cloud_quota", "husk_quota", "spare_slots": records of room past the count}. `opts`:
## "puff_capacity" (physical cloud slots), "husk_capacity", "delta" (s), "poison" (P's dish slots: POISON, or the first dish's own).
func build(specs: Array, opts := {}) -> void:
	delta = float(opts.get("delta", 120.0))
	poison = bool(opts.get("poison", true))
	puff_capacity = int(opts.get("puff_capacity", 262144))
	husk_capacity = int(opts.get("husk_capacity", 65536))
	dishes.clear()
	slots = 0
	cells = 0
	bins = 0
	for spec: Dictionary in specs:
		var st: GpuSim.State = spec["state"]
		var dd := spec.duplicate()
		var n := st.cells_across
		dd["n"] = n
		dd["count"] = st.bups.size() / GpuLayout.RECORD_BYTES
		dd["start"] = slots
		dd["seg"] = align256(maxi(dd["count"] + int(spec.get("spare_slots", 0)), 1))
		slots += dd["seg"]
		dd["base"] = cells
		dd["cells"] = align256(n * n)
		cells += dd["cells"]
		dd["spacing"] = st.spacing
		dd["radius"] = st.radius
		dd["handover"] = float(st.constants["cloud_handover"]) * st.spacing
		dd["bins_across"] = maxi(1, ceili(2.0 * st.radius / (0.5 * st.spacing)) + 1)
		dd["bin_base"] = bins
		bins += dd["bins_across"] * dd["bins_across"]
		dd["seed"] = (st.dish_seed ^ (st.dish_seed >> 32)) & 0xFFFFFFFF
		dd["cloud_quota"] = int(spec.get("cloud_quota", 262144))
		dd["husk_quota"] = int(spec.get("husk_quota", 200000))
		dd["flags"] = int(spec.get("flags", 0)) | ((1 << GpuLayout.DPF_RUNNING) if spec.get("running", true) else 0)
		if diffusion == 0.0:
			diffusion = st.diffusion
		assert(is_equal_approx(diffusion, st.diffusion), "the dishes of a pool share the medium")
		dishes.append(dd)
	_make_buffers()
	set_step(delta)


func _zeros(n_bytes: int) -> PackedByteArray:
	var z := PackedByteArray()
	z.resize(maxi(n_bytes, 16))
	return z


func _buf(nm: String, bytes: PackedByteArray) -> void:
	if bytes.size() < 16:
		bytes.resize(16)
	if bufs.has(nm):
		rd.free_rid(bufs[nm])
	bufs[nm] = rd.storage_buffer_create(bytes.size(), bytes)


func _make_buffers() -> void:
	var rb := GpuLayout.RECORD_BYTES
	var bups := PackedByteArray()
	for d: Dictionary in dishes:  # (the segments are in pool order, each its records and then room)
		bups.append_array(d["state"].bups)
		bups.resize((d["start"] + d["seg"]) * rb)
	var blk := PackedInt32Array()
	blk.resize(slots / GpuLayout.BLK_SLOTS)
	blk.fill(-1)
	var celldish := PackedInt32Array()
	celldish.resize(cells)
	celldish.fill(-1)
	var conc := PackedFloat32Array()
	conc.resize(cells)
	var conc2 := PackedFloat32Array()
	conc2.resize(cells)
	var owner := PackedInt32Array()
	owner.resize(cells)
	owner.fill(-1)
	var inside := PackedInt32Array()
	inside.resize(cells)
	var wgt := PackedFloat32Array()
	wgt.resize(cells)
	var puff := PackedFloat32Array()
	puff.resize(puff_capacity * 8)
	var top := 0
	for d: Dictionary in dishes:
		var st: GpuSim.State = d["state"]
		var row: int = d["row"]
		var n: int = d["n"]
		if d["flags"] & (1 << GpuLayout.DPF_RUNNING):
			for b in d["seg"] / GpuLayout.BLK_SLOTS:
				blk[d["start"] / GpuLayout.BLK_SLOTS + b] = row
			for c in n * n:
				celldish[d["base"] + c] = row
		for c in n * n:
			var o: int = d["base"] + c
			conc[o] = st.conc[c]
			conc2[o] = st.acetate[c] if st.acetate.size() == n * n else 0.0
			owner[o] = st.owner[c] + d["base"] if st.owner[c] >= 0 else -1
			inside[o] = 1 if st.owner[c] == c else 0
			wgt[o] = st.fill_weights[c] if st.fill_weights.size() == n * n else 0.0
		var clouds := _clouds_of(st) if d["flags"] & (1 << GpuLayout.DPF_RUNNING) else PackedFloat32Array()  # (a dish's clouds enter the pool when it runs: the cloud kernels do not look at a dish's flags)
		d["clouds"] = clouds.size() / 5
		for k in clouds.size() / 5:
			for j in 5:
				puff[top * 8 + j] = clouds[k * 5 + j]
			puff[top * 8 + 5] = row_word(row)
			top += 1
	var consts: Dictionary = dishes[0]["state"].constants
	var table := PackedFloat32Array()
	for nm in ["motion_drift", "motion_d_along", "motion_d_across", "motion_d_flat"]:
		table.append_array(PackedFloat32Array(consts[nm]))
	_buf("P", _zeros(GpuLayout.P_WORDS * 4))
	_buf("BUPS", bups)
	_buf("BUPS2", _zeros(slots * rb))
	_buf("BLKDISH", blk.to_byte_array())
	_buf("BLKDISH2", blk.to_byte_array())
	for nm in ["WANT", "CELLOF", "WANTC", "WANT2", "CELL2", "SURV", "EXCS"]:
		_buf(nm, _zeros(slots * 4))
	_buf("CELLDISH", celldish.to_byte_array())
	_buf("CONC", conc.to_byte_array())
	_buf("EFF", _zeros(cells * 4))
	_buf("CONC2", conc2.to_byte_array())
	_buf("CONC2B", _zeros(cells * 4))
	_buf("OWNER", owner.to_byte_array())
	_buf("INSIDE", inside.to_byte_array())
	_buf("WGT", wgt.to_byte_array())
	for nm in ["DLO", "DHI", "RLO", "RHI", "ALO", "AHI", "SCALE", "SCALE2", "AWLO", "AWHI", "ADLO", "ADHI", "DPLO", "DPHI"]:
		_buf(nm, _zeros(cells * 4))
	_buf("TABLE", table.to_byte_array())
	for nm in ["BINC", "BINS", "BCUR"]:
		_buf(nm, _zeros(bins * 4))
	_buf("PUFF", puff.to_byte_array())
	_buf("PUFF2", _zeros(puff_capacity * 32))
	for nm in ["PDLO", "PDHI", "PSCALE", "PAL", "PEXC"]:
		_buf(nm, _zeros(puff_capacity * 4))
	_buf("ENT", _zeros(puff_capacity * GpuKernelsClouds.ENTRIES_PER_SLOT * 4))
	_buf("ENTD", _zeros(puff_capacity * GpuKernelsClouds.ENTRIES_PER_SLOT * 32))
	_buf("EVR", _zeros(GpuLayout.MAX_STEPS_PER_BATCH * 16))
	_buf("EVP", _zeros(GpuLayout.EV_PUFFS_CAPACITY * GpuLayout.EV_PUFF_FLOATS * 4))
	_buf("EVCC", _zeros(GpuLayout.EV_CELLS_CAPACITY * 4))
	_buf("EVCA", _zeros(GpuLayout.EV_CELLS_CAPACITY * 4))
	_buf("CBASE", _zeros((2 * D_MAX + 2) * 4))
	_buf("CLIVE", _zeros(2 * D_MAX * 4))
	_buf("HUSK", _zeros(husk_capacity * 32))
	_buf("HUSK2", _zeros(husk_capacity * 32))
	for nm in ["HDUE", "HEXC", "HAL", "HKEEP"]:
		_buf(nm, _zeros(husk_capacity * 4))
	for nm in ["BSUM", "BOFF", "PSUM", "POFF", "HSUM", "HOFF", "RSUM", "ROFF"]:
		_buf(nm, _zeros(SCAN_SCRATCH * 4))
	var world := _zeros(GpuLayout.WD_WORDS * 4)
	world.encode_u32(GpuLayout.WD_SLOTS * 4, slots)
	world.encode_u32(GpuLayout.WD_CLOUD_SLOTS * 4, top)
	world.encode_u32(GpuLayout.WD_CELLS * 4, cells)
	world.encode_u32(GpuLayout.WD_BINS * 4, bins)
	world.encode_u32(GpuLayout.WD_PUFF_CAPACITY * 4, puff_capacity)
	world.encode_u32(GpuLayout.WD_HUSK_CAPACITY * 4, husk_capacity)
	_buf("WORLD", world)
	var ds := _zeros(D_MAX * GpuLayout.DS_WORDS * 4)
	for d: Dictionary in dishes:
		var o: int = d["row"] * GpuLayout.DS_WORDS * 4
		ds.encode_u32(o + GpuLayout.DS_START * 4, d["start"])
		ds.encode_u32(o + GpuLayout.DS_COUNT * 4, d["count"])
		ds.encode_u32(o + GpuLayout.DS_SEED * 4, d["seed"])
		ds.encode_u32(o + GpuLayout.DS_CLOUD_SLOTS * 4, d["clouds"])
	_buf("DSTATE", ds)
	_buf("DISHP", _zeros(D_MAX * GpuLayout.DP_WORDS * 4))
	_sets.clear()


## The float whose bits are a cloud's (or a husk's) word 5 for dish row `row`.
static func row_word(row: int) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, GpuLayout.PUFF_ROW_BASE + row)
	return b.decode_float(0)


static func _clouds_of(st: GpuSim.State) -> PackedFloat32Array:
	if st.clouds is PackedFloat32Array:
		return st.clouds
	var out := PackedFloat32Array()
	for one: Array in st.clouds:
		for j in 5:
			out.append(float(one[j]))
	return out


## P as the single dish `d` would have it for steps of `delta` s (GpuSim's _fill_params and _set_step, without a device).
func single_p(d: Dictionary, step_seconds: float) -> PackedFloat32Array:
	var st: GpuSim.State = d["state"]
	var g := GpuSim.new(rd)
	g.consts = st.constants
	g.count = d["count"]
	g.n = d["n"]
	g.spacing = st.spacing
	g.origin = st.radius
	g.radius = st.radius
	g.capacity = d["seg"]
	g.puff_capacity = puff_capacity
	g._bins_across = d["bins_across"]
	g._bins = d["bins_across"] * d["bins_across"]
	g._entry_capacity = puff_capacity * GpuKernelsClouds.ENTRIES_PER_SLOT
	g.event_capacity = 32768
	g._fill_params()
	var out := g._p.duplicate()
	var c := st.constants
	var moves := g.moves_for(step_seconds)
	var put := func(nm: String, v: float) -> void: out[GpuLayout.p_slot(nm)] = v
	put.call("delta", step_seconds)
	put.call("moves", moves)
	put.call("sub", step_seconds / maxf(moves, 1))
	put.call("death_chance", minf(float(c["death_rate"]) * step_seconds, 1.0))
	put.call("limit", st.limit if st.limit > 0 else d["count"])
	put.call("feed", st.feed * step_seconds)
	put.call("cloud_spread", 2.0 * st.diffusion * step_seconds)
	put.call("death_puff", g._death_puff)
	put.call("conj_chance", 1.0 - exp(-float(c["conj_rate"]) * step_seconds))
	put.call("stationary", 1.0 if d["flags"] & (1 << GpuLayout.DPF_STATIONARY) else 0.0)
	put.call("upkeep_scale", st.upkeep)
	return out


## The step's length: P and every dish's DISHP row (the diffusion's k and iterations, the feed of a step) for steps of `seconds`.
func set_step(seconds: float) -> void:
	delta = seconds
	p = single_p(dishes[0], seconds)
	if poison:
		for nm: String in DISH_SLOTS_OF_P:
			p[GpuLayout.p_slot(nm)] = POISON
	var pb := p.to_byte_array()
	rd.buffer_update(bufs["P"], 0, pb.size(), pb)
	upload_dishp()


func upload_dishp() -> void:
	var dp := _zeros(D_MAX * GpuLayout.DP_WORDS * 4)
	for d: Dictionary in dishes:
		var st: GpuSim.State = d["state"]
		var o: int = d["row"] * GpuLayout.DP_WORDS * 4
		var k_total := st.diffusion * delta / (st.spacing * st.spacing)
		var iterations := maxi(2, 2 * ceili(k_total / 0.4))
		d["iterations"] = iterations
		var u := func(w: int, v: int) -> void: dp.encode_u32(o + w * 4, v)
		var fl := func(w: int, v: float) -> void: dp.encode_float(o + w * 4, v)
		u.call(GpuLayout.DP_FIELD_BASE, d["base"])
		u.call(GpuLayout.DP_CELLS, d["n"])
		fl.call(GpuLayout.DP_SPACING, st.spacing)
		fl.call(GpuLayout.DP_RADIUS, st.radius)
		fl.call(GpuLayout.DP_HANDOVER, d["handover"])
		u.call(GpuLayout.DP_BIN_BASE, d["bin_base"])
		u.call(GpuLayout.DP_BINS_ACROSS, d["bins_across"])
		fl.call(GpuLayout.DP_BIN_SIZE, 0.5 * st.spacing)
		fl.call(GpuLayout.DP_FEED, st.feed * delta)
		fl.call(GpuLayout.DP_UPKEEP_SCALE, st.upkeep)
		u.call(GpuLayout.DP_LIMIT, st.limit)
		u.call(GpuLayout.DP_CAP, d["seg"])
		u.call(GpuLayout.DP_FLAGS, d["flags"])
		fl.call(GpuLayout.DP_K_TOTAL, k_total)
		fl.call(GpuLayout.DP_K, k_total / iterations)
		u.call(GpuLayout.DP_ITERATIONS, iterations)
		u.call(GpuLayout.DP_CLOUD_QUOTA, d["cloud_quota"])
		u.call(GpuLayout.DP_HUSK_QUOTA, d["husk_quota"])
		u.call(GpuLayout.DP_NUMBER, d["row"] + 1)
		u.call(GpuLayout.DP_SEED, d["seed"])
		fl.call(GpuLayout.DP_NOISE_REFERENCE, float(st.constants["noise_reference"]))
	rd.buffer_update(bufs["DISHP"], 0, dp.size(), dp)


# ---- recording ----------------------------------------------------------------------------------------------------------------

static func groups_for(items: int) -> int:
	return clampi(ceili(items / 128.0), 1, 16384)


func dispatch(cl: int, kname: String, groups: int, pa := 0.0, pb := 0.0) -> void:
	assert(made.has(kname), "no kernel %s" % kname)
	var k: Dictionary = made[kname]
	if not _sets.has(kname):
		_sets[kname] = ShaderSet.uniform_set(rd, k, bufs)
	rd.compute_list_bind_compute_pipeline(cl, k["pipeline"])
	rd.compute_list_bind_uniform_set(cl, _sets[kname], 0)
	rd.compute_list_set_push_constant(cl, PackedFloat32Array([pa, pb, 0.0, 0.0]).to_byte_array(), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


## A grid scan of `prefix` (GpuKernels.add_grid_scan) over about `elements` elements.
func scan(cl: int, prefix: String, elements: int) -> void:
	var g := GpuKernels.scan_groups(elements)
	dispatch(cl, prefix + "_chunks", g)
	dispatch(cl, prefix + "_sums", 1, float(g))
	dispatch(cl, prefix + "_add", g)


## The cloud slots in use now, as the host would know it from its last readback (only the speed depends on it).
var cloud_hint := 4096
var husk_hint := 1024


func record_events(cl: int, step_in_batch: int) -> void:
	dispatch(cl, "pool_ev_puffs", 1, float(step_in_batch))
	dispatch(cl, "ev_deposits", 1, float(step_in_batch))


func record_field(cl: int) -> void:
	var cg := ceili(cells / 64.0)
	dispatch(cl, "pool_feed", cg)
	var most := 0
	for d: Dictionary in dishes:
		most = maxi(most, d["iterations"])
	for pass_i in most:
		var bound := 0
		for d: Dictionary in dishes:
			if d["iterations"] > pass_i:
				bound = maxi(bound, d["base"] + d["cells"])
		var ab := "a" if pass_i % 2 == 0 else "b"
		dispatch(cl, "pool_diffuse_" + ab, ceili(bound / 64.0), float(pass_i), float(bound))
		dispatch(cl, "pool_diffuse2_" + ab, ceili(bound / 64.0), float(pass_i), float(bound))
	dispatch(cl, "pool_puff_advance", groups_for(cloud_hint))
	dispatch(cl, "pool_dep_apply", cg)
	dispatch(cl, "pool_snapshot", cg)
	record_index(cl)
	dispatch(cl, "pool_clear", cg)
	dispatch(cl, "pool_puff_clear", groups_for(cloud_hint))


func record_index(cl: int, cut := true) -> void:
	dispatch(cl, "pool_bin_clear", groups_for(bins))
	dispatch(cl, "pool_bin_count", groups_for(cloud_hint))
	scan(cl, "pool_bn", bins)
	if not cut:
		return
	record_index_rest(cl)


func record_index_rest(cl: int) -> void:
	dispatch(cl, "pool_bin_cut", D_MAX / 64)
	dispatch(cl, "pool_bin_cursor", groups_for(bins))
	dispatch(cl, "pool_bin_scatter", groups_for(cloud_hint))
	dispatch(cl, "pool_bin_sort", groups_for(bins))


func record_bups(cl: int) -> void:
	var bg := GpuKernels.bup_groups(slots)
	var cg := ceili(cells / 64.0)
	dispatch(cl, "pool_swim", bg)
	dispatch(cl, "pool_demand", bg)
	dispatch(cl, "pool_cells", cg)
	dispatch(cl, "pool_puff_scale", groups_for(cloud_hint))
	dispatch(cl, "pool_apply", bg)
	dispatch(cl, "pool_puff_commit", groups_for(cloud_hint))
	dispatch(cl, "pool_ac_cells", cg)
	dispatch(cl, "pool_ac_apply", bg)


## A share `rate` of each dish's bups dies this step (of them a share `trimmed` is displaced at the limit and gives nothing back):
## SURV, EXCS and DS_SURVIVORS as `life` and the scans leave them, R_PY -2 on the deaths that give back.
func record_fake_life(cl: int, rate: float, trimmed: float) -> void:
	dispatch(cl, "rig_rows", 1, 0.0)
	dispatch(cl, "rig_fake_deaths", GpuKernels.bup_groups(slots), rate, trimmed)
	scan(cl, "rig_ex", slots)


func record_deaths(cl: int) -> void:
	var bg := GpuKernels.bup_groups(slots)
	dispatch(cl, "pool_death_bases", 1)
	dispatch(cl, "pool_husk_spawn", bg)
	dispatch(cl, "pool_death_clouds", bg)
	dispatch(cl, "pool_death_count", D_MAX / 64)


func record_husk_leak(cl: int) -> void:
	dispatch(cl, "pool_husk_age", groups_for(husk_hint))
	scan(cl, "pool_hl", husk_hint)
	dispatch(cl, "pool_husk_leak", groups_for(husk_hint))
	dispatch(cl, "pool_husk_leak_count", 1)


func record_cadence(cl: int) -> void:
	dispatch(cl, "pool_cloud_live", groups_for(cloud_hint))
	dispatch(cl, "pool_husk_live", groups_for(husk_hint))
	dispatch(cl, "pool_cloud_cadence", D_MAX / 64)


func record_compaction(cl: int) -> void:
	dispatch(cl, "pool_pmark", groups_for(cloud_hint))
	scan(cl, "pool_pf", cloud_hint)
	dispatch(cl, "pool_pcompact", groups_for(cloud_hint * 2))
	dispatch(cl, "pool_pcopy", groups_for(cloud_hint * 2))
	dispatch(cl, "pool_psetcount", 1)


func record_cull(cl: int) -> void:
	dispatch(cl, "pool_husk_mark", groups_for(husk_hint))
	scan(cl, "pool_hc", husk_hint)
	dispatch(cl, "pool_husk_compact", groups_for(husk_hint))
	dispatch(cl, "pool_husk_copy", groups_for(husk_hint * 8))
	dispatch(cl, "pool_husk_set_count", 1)


## Whole steps of the rig's own (fake life), `steps` of them in one submit, with each dish's events from `events_for` (a Callable
## (dish: Dictionary, dish_step: int) -> {"puffs": PackedFloat32Array of 6 a cloud, word 5 any, "cells": local cells, "amounts"}).
## `cull_every`: the husks' cull every so many world steps (0: never).
func run_fake_steps(steps: int, events_for: Callable, rate := 0.1, trimmed := 0.25, cull_every := 32) -> void:
	upload_events(steps, events_for)
	var cl := rd.compute_list_begin()
	for s in steps:
		record_events(cl, s)
		record_field(cl)
		record_bups(cl)
		record_fake_life(cl, rate, trimmed)
		record_deaths(cl)
		record_husk_leak(cl)
		record_cadence(cl)
		dispatch(cl, "rig_rows", 1, 1.0)
		if world_step % 16 == 15:
			record_compaction(cl)
		if cull_every > 0 and world_step % cull_every == cull_every - 1:
			record_cull(cl)
		world_step += 1
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	for d: Dictionary in dishes:
		if d["flags"] & (1 << GpuLayout.DPF_RUNNING):
			d["dish_step"] = int(d.get("dish_step", 0)) + steps
	cloud_hint = maxi(word("WORLD", GpuLayout.WD_CLOUD_SLOTS), 64)
	husk_hint = maxi(word("WORLD", GpuLayout.WD_HUSK_SLOTS), 64)


## EVR, EVP, EVCC, EVCA for the next `steps` steps: each running dish's events in pool order, a step at a time.
func upload_events(steps: int, events_for: Callable) -> void:
	var ranges := PackedInt32Array()
	var puffs := PackedFloat32Array()
	var ev_cells := PackedInt32Array()
	var amounts := PackedFloat32Array()
	for s in steps:
		var first := puffs.size() / GpuLayout.EV_PUFF_FLOATS
		var first_cell := ev_cells.size()
		for d: Dictionary in dishes:
			if not (d["flags"] & (1 << GpuLayout.DPF_RUNNING)):
				continue
			var ev: Dictionary = events_for.call(d, int(d.get("dish_step", 0)) + s)
			var pf: PackedFloat32Array = ev.get("puffs", PackedFloat32Array())
			for k in pf.size() / GpuLayout.EV_PUFF_FLOATS:
				for j in 5:
					puffs.append(pf[k * GpuLayout.EV_PUFF_FLOATS + j])
				puffs.append(row_word(d["row"]))
			var cc: PackedInt32Array = ev.get("cells", PackedInt32Array())
			for k in cc.size():
				ev_cells.append(cc[k] + d["base"])
			amounts.append_array(ev.get("amounts", PackedFloat32Array()))
		ranges.append_array(PackedInt32Array([first, puffs.size() / GpuLayout.EV_PUFF_FLOATS - first, first_cell, ev_cells.size() - first_cell]))
	for pair in [["EVR", ranges.to_byte_array()], ["EVP", puffs.to_byte_array()], ["EVCC", ev_cells.to_byte_array()], ["EVCA", amounts.to_byte_array()]]:
		var bytes: PackedByteArray = pair[1]
		if bytes.size() > 0:
			rd.buffer_update(bufs[pair[0]], 0, bytes.size(), bytes)


# ---- dishes for the checks ---------------------------------------------------------------------------------------------------

## A dish's state: struck from `sc` (its field, owners, feed weights, founders), its founders copied to `bups` bups spread over the dish
## with reserves from a fifth to full, a share `key` with the acetate key, some acetate, and `clouds` clouds.
static func make_state(tree: SceneTree, sc: StartConditions, seed_v: int, bups: int, key: float, clouds: int) -> GpuSim.State:
	sc.spread_founders()
	var dish := Dish.new()
	tree.root.add_child(dish)
	dish.process_mode = Node.PROCESS_MODE_DISABLED
	dish.set_seed(seed_v)
	dish.strike(sc)
	var st := GpuSim.State.of_field(dish.field, dish.radius, dish.sim.export_state_bytes(), SimConstants.build())
	st.dish_seed = seed_v * 7919 + 13
	st.limit = maxi(bups, 1)
	st.feed = Dish.feed_per_second(sc.feed_density)
	st.upkeep = dish.upkeep_factor
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	st.bups = spread_bups(st.bups, bups, dish.radius, rng, key, st.constants)
	var n := st.cells_across
	st.acetate = PackedFloat32Array()
	st.acetate.resize(n * n)
	for c in n * n:
		if st.owner[c] == c and rng.randf() < 0.3:
			st.acetate[c] = rng.randf() * 0.002
	var pf := PackedFloat32Array()
	for k in clouds:
		pf.append_array(random_cloud(rng, dish.radius, st.spacing, 1.0 if k % 2 == 0 else 0.001, st.constants))
	st.clouds = pf
	tree.root.remove_child(dish)
	dish.free()
	return st


static func spread_bups(founders: PackedByteArray, target: int, radius: float, rng: RandomNumberGenerator, key: float, consts: Dictionary) -> PackedByteArray:
	var rb := GpuLayout.RECORD_BYTES
	var f := founders.size() / rb
	var out := PackedByteArray()
	out.resize(target * rb)
	for i in target:
		var src := (i % f) * rb
		for k in rb:
			out[i * rb + k] = founders[src + k]
		var a := rng.randf() * TAU
		var r := radius * 0.9 * sqrt(rng.randf())
		var o := i * rb
		out.encode_float(o + GpuLayout.R_X * 4, r * cos(a))
		out.encode_float(o + GpuLayout.R_Y * 4, r * sin(a))
		var h := rng.randf() * TAU
		out.encode_float(o + GpuLayout.R_DX * 4, cos(h))
		out.encode_float(o + GpuLayout.R_DY * 4, sin(h))
		var mass := out.decode_float(o + GpuLayout.R_MASS * 4) * rng.randf_range(0.8, 1.6)
		out.encode_float(o + GpuLayout.R_MASS * 4, mass)
		out.encode_float(o + GpuLayout.R_ENERGY * 4, mass * float(consts["reserve_per_mass"]) * rng.randf_range(0.0, 1.0))
		if rng.randf() < key:
			out.encode_float(o + GpuLayout.R_REACH * 4, float(int(out.decode_float(o + GpuLayout.R_REACH * 4)) | (2 << 8)))
		GpuLayout.set_id(out, i, 1000 + i)
	return out


## A cloud (x, y, mass, variance, cut) inside 0.85 of the radius, its peak 30 to 3000 times its cut level.
static func random_cloud(rng: RandomNumberGenerator, radius: float, spacing: float, cut: float, consts: Dictionary) -> PackedFloat32Array:
	var a := rng.randf() * TAU
	var r := radius * 0.85 * sqrt(rng.randf())
	var sigma := rng.randf_range(5.0, maxf(6.0, 0.2 * spacing))
	var v := sigma * sigma
	var level := float(consts["cloud_cut"]) * cut * float(consts["detection_floor"])
	var mass := TAU * v * level * exp(rng.randf_range(log(30.0), log(3000.0)))
	return PackedFloat32Array([r * cos(a), r * sin(a), mass, v, cut])


# ---- readbacks ----------------------------------------------------------------------------------------------------------------

func read(nm: String, offset := 0, size := 0) -> PackedByteArray:
	if size <= 0 and offset > 0:
		return PackedByteArray()
	return rd.buffer_get_data(bufs[nm], offset, size)


func word(nm: String, w: int) -> int:
	return read(nm, w * 4, 4).decode_u32(0)


func ds(row: int, w: int) -> int:
	return word("DSTATE", row * GpuLayout.DS_WORDS + w)


## Dish `i` (pool order) in its own terms, for comparing with the same dish in another pool: its records, its cells (the nutrient, the
## acetate, the deposits waiting), its live clouds and husks in pool order with the row word made 1.0, its cloud lists square by square (the
## count, then each entry's x, y, mass, variance, reach² and sigma), and its counters.
func dump(i: int) -> Dictionary:
	var d: Dictionary = dishes[i]
	var row: int = d["row"]
	var out := {}
	var rb := GpuLayout.RECORD_BYTES
	var count := ds(row, GpuLayout.DS_COUNT)
	out["records"] = read("BUPS", d["start"] * rb, count * rb) if count > 0 else PackedByteArray()
	var n2: int = d["n"] * d["n"]
	for nm in ["CONC", "CONC2", "DPLO", "DPHI"]:
		out[nm] = read(nm, d["base"] * 4, n2 * 4)
	var top := word("WORLD", GpuLayout.WD_CLOUD_SLOTS)
	out["clouds"] = _of_row(read("PUFF", 0, maxi(top, 1) * 32).to_float32_array(), top, row)
	var htop := word("WORLD", GpuLayout.WD_HUSK_SLOTS)
	out["husks"] = _of_row(read("HUSK", 0, maxi(htop, 1) * 32).to_float32_array(), htop, row, true) if htop > 0 else PackedFloat32Array()
	var nb: int = d["bins_across"] * d["bins_across"]
	var binc := read("BINC", d["bin_base"] * 4, nb * 4).to_int32_array()
	var bstart := read("BINS", d["bin_base"] * 4, nb * 4).to_int32_array()
	var lists := PackedFloat32Array()
	var lo := bstart[0]
	var hi := bstart[nb - 1] + binc[nb - 1]
	var entd := read("ENTD", lo * 32, (hi - lo) * 32).to_float32_array() if hi > lo else PackedFloat32Array()
	for b in nb:
		lists.append(float(binc[b]))
		for e in range(bstart[b], bstart[b] + binc[b]):
			var o: int = (e - lo) * 8
			for j in 6:
				lists.append(entd[o + j])
	out["lists"] = lists
	var words := PackedInt32Array()
	for w in [GpuLayout.DS_COUNT, GpuLayout.DS_SURVIVORS, GpuLayout.DS_STEP, GpuLayout.DS_CLOUD_SLOTS, GpuLayout.DS_CLOUDS_TO_GRID, GpuLayout.DS_ENTRIES_CUT, GpuLayout.DS_HUSKS, GpuLayout.DS_OVERFLOW]:
		words.append(ds(row, w))
	out["counters"] = words
	return out


## The slots of dish row `row` among the first `top` of a pool of clouds or (`husks`) husks, the live ones (a husk is live while it holds a
## piece not yet let go): which dead slots are still there depends on when the pool was last compacted, not on the dish.
static func _of_row(raw: PackedFloat32Array, top: int, row: int, husks := false) -> PackedFloat32Array:
	var want := row_word(row)
	var out := PackedFloat32Array()
	for k in top:
		if raw[k * 8 + 5] == want and (not husks or (raw[k * 8 + 6] > 0.5 and int(raw[k * 8 + 4]) < GpuKernelsHusks.HUSK_PIECES)):
			for j in 8:
				out.append(1.0 if j == 5 else raw[k * 8 + j])
	return out


## "" when the two dumps are the same bit for bit, else the first item and place that differs.
static func diff(a: Dictionary, b: Dictionary) -> String:
	for key: String in a:
		var x: Variant = a[key]
		var y: Variant = b[key]
		var xb: PackedByteArray = x if x is PackedByteArray else (x.to_byte_array())
		var yb: PackedByteArray = y if y is PackedByteArray else (y.to_byte_array())
		if xb == yb:
			continue
		if xb.size() != yb.size():
			return "%s: %d bytes against %d" % [key, xb.size(), yb.size()]
		for k in xb.size() / 4:
			if xb.decode_u32(k * 4) != yb.decode_u32(k * 4):
				return "%s: word %d differs (%s against %s)" % [key, k, xb.decode_float(k * 4), yb.decode_float(k * 4)]
	return ""


func release() -> void:
	ShaderSet.free_all(rd, made)
	for nm: String in bufs:
		rd.free_rid(bufs[nm])
	bufs.clear()
	made.clear()
	if own_device:
		rd.free()
