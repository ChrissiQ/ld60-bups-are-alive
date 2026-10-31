extends SceneTree
## The pooled bup pipeline (gpu/kernels_life.gd and kernels_game.gd, "the pooled world") on a local RenderingDevice, without SimCore:
## the dishes' records, tables and scratch buffers are made here, the kernels compiled from GpuKernels.all(). Windowed, through the lock:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/pool_life_check.gd -- [check | time N]
## The field, the clouds and the swimming are not part of it: a probe kernel (`grow`, keyed by the bup's place in its dish) grows and
## jitters the bups so that they divide, die at the limit and touch, step after step.
##
## Expected values, written before the first run:
## C1 one pooled dish (row 0, number 0, at slot 0) against the single-dish path's kernels (conj_clear/insert/apply, life, the scans, finalize, events,
##    compact, copy, ev_count, setcount, stats1/2) with the same `grow`, 60 steps in batches of 10: records, the counters (count,
##    survivors, newborn, next count, next id, step, growth, births, deaths, lost, donors, donor reach), every event word and every stats
##    word equal bit for bit, for five dishes: plain; stationary; donors sparse; donors packed close (transfers happen: it differs from
##    the same run with no transfers); a cap under survivors + newborns (newborns dropped). [derived: the same arithmetic with the dish's
##    words for CNT's and the place in the dish for the slot] The single-dish path's donor table drops donors past 4 a bucket (the pooled index drops
##    none), so the packed dish is compared with the single-dish path's kernels given a 32-slot table, and its most donors in a bucket is reported.
## C2 isolation: every dish of a pool of 2, 8 and 65 dishes (random rows, sizes, seeds, limits, caps, flags and donors; every dish
##    packed round 0, 0, so all of them overlap) equals its run alone (another row, at slot 0, another grid size), batch by batch:
##    records, every DSTATE word but the start, its events (births by the id's dish number, deaths by ED_STEP's), its stats. 0 words differ.
## C3 permutation: the 65 dishes with their rows reversed, then shuffled, with one dish removed after 40 steps (DPF_REMOVED for a step,
##    then its row cleared) and one added after 60 steps: every dish equals its run alone (the added one from its own step 0). 0 differ.
## C4 conjugation across dishes: in C2/C3 every dish lies over the others; a pool run with a dish-blind donors' index (no dish in the
##    bucket's hash, no dish check: the single-dish table) differs from the runs alone (so C2 can see a transfer across dishes), the
##    real kernels do not (0 transfers across).
## C5 retarget (a source of a few hundred bups, a new empty destination, two other dishes): the moved bups are those inside the disc
##    (float32, as the kernel) and keep every word but x, y, which are float32(x - cx), float32(y - cy); the source keeps the others in
##    their order, the destination holds the moved in their order; the other dishes are unchanged; DS_MOVED_OUT(source) =
##    DS_MOVED_IN(destination) = m > 0; counts n - m and m; the pass adds no birth, no death and writes no event; the stats after it
##    count m in the destination and n - m in the source; the destination's next counter is above every moved counter and keeps its
##    number; the block table is the segments. In the next batch every event of a moved bup or its descendants is the destination's
##    (deaths by ED_STEP's number, births by the id's) and none is the source's; count after - before = births - deaths + moved in -
##    moved out for every dish in both batches. The destination continued 20 steps equals it alone, loaded from its records and DSTATE.
## C6 (mode time N, default 2,000,000): each pooled kernel's cost on one dish of N bups (2% donors, 5% at division) against the single-dish path's
##    counterpart, median of 7 runs less a no-op [measured]; expected about the single-dish path's for life, events, the scans (+10%), compact
##    (compact + copy today: about 0.5 x) [derived from the 2M figures]; the donors' index (count, scan, scatter) about 0.5 ms more
##    than the single-dish path's insert [placeholder: a pass over the donor flags and a scan of N/4 buckets].

const L := preload("res://gpu/gpu_layout.gd")
const W := L.RECORD_WORDS
const RB := L.RECORD_BYTES
const EV_CAP := 262144
const SCAN_MAX_GROUPS := 4096

var rd: RenderingDevice
var made := {}
var consts := {}
var fails := 0
var max_x := 65535


class World:
	var bufs := {}
	var sets := {}
	var flipped := false
	var phys := 0
	var buckets := 0
	var today := false
	var wide := false  ## the single-dish path's, with the 32-slot donor table
	var cap := 0  ## the single-dish path's: the dish's capacity


func ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		fails += 1


# ---- the kernels -----------------------------------------------------------------------------------------------------------------------

func probe_defs() -> Dictionary:
	var all := GpuKernels.all()
	var defs := {}
	for k: String in all:
		if k.begins_with("pool_") or k in ["life", "scan0_s", "scan0_k", "scan1", "scan2", "add2", "add1_s", "add1_k", "finalize", "compact", "copy", "setcount", "conj_clear", "conj_insert", "conj_apply", "ev_begin", "events", "ev_count", "stats1", "stats2"]:
			defs[k] = all[k]
	var grow_body := """
	BUPS[b + R_MASS] *= 1.0 + 0.25 * u01(s);
	BUPS[b + R_ENERGY] += 1.0;
	BUPS[b + R_X] += gauss(s) * 1.5; BUPS[b + R_Y] += gauss(s) * 1.5;
}
"""
	GpuKernels.add(defs, "grow_pool", "void grow(uint i, uint d, uint l) {\n\tuint b = i * RECORD_WORDS;\n\tuint s = DISH_STREAM(d, l, 4242U);\n" + grow_body + "BUP_LOOP(grow)\n", ["BUPS", "WORLD", "BLKDISH", "DSTATE"])
	GpuKernels.add(defs, "grow_today", "void main() {\n\tBUP_RECORD_THREAD\n\tuint s = hash(hash(CNT[CNT_SEED] ^ (CNT[CNT_STEP] * 0x85EBCA6BU) ^ 4242U) + i * 0x9E3779B9U);\n" + grow_body, ["CNT", "BUPS"])
	# the dish-blind index: no dish in the bucket's hash and no dish check (as the single-dish table), for C4
	var blind := GpuKernelsLife.CONJ_FUNCS + GpuKernelsLife.dn_funcs() + "#define CONJ_BUCKETS (%s)\n" % GpuKernelsLife.CONJ_BUCKETS_EXPR + GpuKernelsLife.swapped(GpuKernelsLife.POOL_CONJ_FUNCS, " ^ d * 83492791u", "")
	GpuKernels.add(defs, "pool_conj_count_blind", GpuKernelsLife.K_POOL_CONJ_COUNT, ["P", "BUPS", "WORLD", "BLKDISH", "DSTATE", "CBKT", "DCNT"], blind, 64, GpuKernelsLife.POOL_TYPES)
	GpuKernels.add(defs, "pool_conj_apply_blind", GpuKernelsLife.swapped(GpuKernelsLife.K_POOL_CONJ_APPLY, "if (BLKDISH[j >> BLK_SHIFT] != d) continue;", ""), ["P", "BUPS", "WORLD", "BLKDISH", "DSTATE", "DCNT", "DOFF", "DLIST"], blind, 64, GpuKernelsLife.POOL_TYPES)
	# the single-dish path's donor table with 32 slots a bucket in place of 4 (no donor dropped below 33 a bucket), for C1's dense dish
	var wide := func(text: String) -> String: return text.replace("(DMASK + 1u) * 4u", "(DMASK + 1u) * WIDE").replace("s < 4u", "s < WIDE").replace("h * 4u + s", "h * WIDE + s")
	var wide_funcs := GpuKernelsLife.CONJ_FUNCS + "const uint WIDE = 32u;\n"
	GpuKernels.add(defs, "conj_clear_wide", wide.call(GpuKernelsLife.K_CONJ_CLEAR), ["CNT", "DTAB"], wide_funcs)
	GpuKernels.add(defs, "conj_insert_wide", wide.call(GpuKernelsLife.K_CONJ_INSERT), ["P", "CNT", "BUPS", "DTAB"], wide_funcs)
	GpuKernels.add(defs, "conj_apply_wide", wide.call(GpuKernelsLife.K_CONJ_APPLY), ["P", "CNT", "BUPS", "DTAB"], wide_funcs)
	GpuKernels.add(defs, "noop", "void main() { if (gl_GlobalInvocationID.x == 4000000u) WORLD[0] = 1u; }\n", ["WORLD"])
	return defs


# ---- buffers -----------------------------------------------------------------------------------------------------------------------------

func zeros(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(maxi(16, n))
	return b


func make_world(phys: int, today := false, cap := 0) -> World:
	var w := World.new()
	w.phys = phys
	w.today = today
	w.cap = cap
	w.buckets = GpuKernelsLife.conj_buckets(phys)
	var p := PackedFloat32Array()
	p.resize(L.P_WORDS)
	for slot_name: String in L.P_SLOTS:
		var e: Array = L.P_SLOTS[slot_name]
		if e[1] == "const":
			p[e[0]] = float(consts[slot_name])
		elif e[1] == "array":
			for k: int in e[2]:
				p[e[0] + k] = float(consts[slot_name][k])
	p[L.p_slot("death_chance")] = 0.02
	p[L.p_slot("conj_chance")] = 0.3
	p[L.p_slot("event_capacity")] = EV_CAP
	p[L.p_slot("death_give")] = 0.5
	p[L.p_slot("delta")] = 20.0
	var sizes := {
		"P": p.to_byte_array(), "BUPS": phys * RB, "BUPS2": phys * RB, "CHILD": phys * RB, "SURV": phys * 4, "KID": phys * 4, "EXCS": phys * 4,
		"EXCK": phys * 4, "EVB": EV_CAP * L.BIRTH_WORDS * 4, "EVD": EV_CAP * L.DEATH_WORDS * 4, "SPART": (phys / 256 + 1) * L.STATS_SUMS * 4,
		"WORLD": L.WD_WORDS * 4,
	}
	if today:
		var s1 := (phys + 255) / 256
		sizes.merge({"CNT": L.CNT_WORDS * 4, "S1": s1 * 4, "S1X": s1 * 4, "S2": ((s1 + 255) / 256) * 4, "S2X": ((s1 + 255) / 256) * 4, "S3": 16,
			"DTAB": (65536 * 32 + 2048) * 4, "EVN": L.EVENT_SETS * 8, "OUT": L.OUT_WORDS * 4})
	else:
		sizes.merge({"CBKT": phys * 4, "DLIST": phys * 4, "PIPDST": phys * 4, "DCNT": w.buckets * 4, "DOFF": w.buckets * 4, "GSUM": SCAN_MAX_GROUPS * 4,
			"GOFF": SCAN_MAX_GROUPS * 4, "DISHP": L.D_MAX * L.DP_WORDS * 4, "DSTATE": L.D_MAX * L.DS_WORDS * 4, "BLKDISH": (phys / 256 + 1) * 4,
			"BLKDISH2": (phys / 256 + 1) * 4, "DNEXT": GpuKernelsLife.DNEXT_WORDS * 4, "STATS": L.D_MAX * L.STATS_DISH_WORDS * 4})
	for nm: String in sizes:
		var v: Variant = sizes[nm]
		var data: PackedByteArray = v if v is PackedByteArray else zeros(v)
		w.bufs[nm] = rd.storage_buffer_create(data.size(), data)
	if not today:
		var none := PackedByteArray()
		none.resize((phys / 256 + 1) * 4)
		none.fill(0xFF)
		put(w, "BLKDISH", none)
		put(w, "BLKDISH2", none)
	return w


func free_world(w: World) -> void:
	for k: String in w.sets:
		if rd.uniform_set_is_valid(w.sets[k]):
			rd.free_rid(w.sets[k])
	for nm: String in w.bufs:
		rd.free_rid(w.bufs[nm])


func put(w: World, nm: String, data: PackedByteArray, at := 0) -> void:
	rd.buffer_update(w.bufs[nm], at, data.size(), data)


func get_bytes(w: World, nm: String, at := 0, n := 0) -> PackedByteArray:
	return rd.buffer_get_data(w.bufs[nm], at, n)


## The physical name of a pooled world's records or block table now (the halves swap at every compaction).
func cur(w: World, nm: String) -> String:
	return GpuKernels.physical(nm, ["records"] if w.flipped else [])


func set_p(w: World, slot_name: String, v: float) -> void:
	put(w, "P", PackedFloat32Array([v]).to_byte_array(), L.p_slot(slot_name) * 4)


# ---- dishes ------------------------------------------------------------------------------------------------------------------------------

## A dish: number, n, seed, limit, cap, stationary, donors (share), pack (radius of the founders, µm), ready (share at division).
func spec(number: int, n: int, seed_v: int, limit: int, donors := 0.0, stationary := false, pack := 60.0, cap := -1, ready := 0.0) -> Dictionary:
	return {"number": number, "n": n, "seed": seed_v, "limit": limit, "cap": cap if cap > 0 else ((int(limit * 1.05) + 1024 + 255) / 256) * 256, "donors": donors, "stationary": stationary, "pack": pack, "ready": ready}


func records_of(s: Dictionary) -> PackedByteArray:
	var r := RandomNumberGenerator.new()
	r.seed = s["seed"] * 7919 + 11
	var add: float = consts["add_mass_factor"] * 16.0
	var out := PackedByteArray()
	out.resize(s["n"] * RB)
	for k: int in s["n"]:
		var o: int = k * RB
		var a := r.randf() * TAU
		var rad := sqrt(r.randf()) * float(s["pack"])
		var f := {L.R_X: cos(a) * rad, L.R_Y: sin(a) * rad, L.R_DX: 1.0, L.R_ENERGY: 50.0, L.R_MASS: add * (2.05 if r.randf() < float(s["ready"]) else 1.0 + r.randf()), L.R_BIRTH_MASS: add,
			L.R_SPEED: 20.0 + r.randf() * 10.0, L.R_SENSE: 50.0, L.R_METABOLISM: 1.0, L.R_SIZE: 4.0, L.R_MUTATOR: 1.0,
			L.R_DONOR: 1.0 if r.randf() < float(s["donors"]) else 0.0, L.R_HUE: 0.33, L.R_SAT: 0.7, L.R_VAL: 1.0, L.R_PX: 3e38, L.R_PY: 3e38, L.R_FAST: -1.0}
		for word: int in f:
			out.encode_float(o + word * 4, f[word])
		L.set_id(out, k, L.make_id(s["number"], k + 1))
	return out


func flags_of(s: Dictionary) -> int:
	return (1 << L.DPF_RUNNING) | ((1 << L.DPF_STATIONARY) if s["stationary"] else 0)


## Puts dish `s` in row `row` of a pooled world at slot `start` (its records into the half in use), with its tables; the slots in use
## become at least the end of its segment.
func put_dish(w: World, row: int, s: Dictionary, start: int, records := PackedByteArray(), dstate := PackedByteArray()) -> void:
	var recs := records if not records.is_empty() else records_of(s)
	var n := recs.size() / RB
	put(w, cur(w, "BUPS"), recs, start * RB)
	var dp := zeros(L.DP_WORDS * 4)
	dp.encode_u32(L.DP_LIMIT * 4, s["limit"])
	dp.encode_u32(L.DP_CAP * 4, s["cap"])
	dp.encode_u32(L.DP_FLAGS * 4, flags_of(s))
	dp.encode_u32(L.DP_NUMBER * 4, s["number"])
	put(w, "DISHP", dp, row * L.DP_WORDS * 4)
	var ds := dstate.duplicate() if not dstate.is_empty() else zeros(L.DS_WORDS * 4)
	if dstate.is_empty():
		var first := L.make_id(s["number"], n + 1)
		ds.encode_u32(L.DS_NEXT_ID_LO * 4, first & 0xFFFFFFFF)
		ds.encode_u32(L.DS_NEXT_ID_HI * 4, first >> 32)
		ds.encode_u32(L.DS_SEED * 4, s["seed"])
	ds.encode_u32(L.DS_START * 4, start)
	ds.encode_u32(L.DS_COUNT * 4, n)
	put(w, "DSTATE", ds, row * L.DS_WORDS * 4)
	var blocks := (n + 255) / 256
	var rows := PackedByteArray()
	rows.resize(blocks * 4)
	for k in blocks:
		rows.encode_u32(k * 4, row)
	if blocks > 0:
		put(w, cur(w, "BLKDISH"), rows, (start / 256) * 4)
	var slots := get_bytes(w, "WORLD").decode_u32(L.WD_SLOTS * 4)
	var wd := zeros(4)
	wd.encode_u32(0, maxi(slots, start + blocks * 256))
	put(w, "WORLD", wd, L.WD_SLOTS * 4)


func dstate_row(w: World, row: int) -> PackedByteArray:
	return get_bytes(w, "DSTATE", row * L.DS_WORDS * 4, L.DS_WORDS * 4)


func ds_word(w: World, row: int, word: int) -> int:
	return dstate_row(w, row).decode_u32(word * 4)


func segment(w: World, row: int) -> PackedByteArray:
	var ds := dstate_row(w, row)
	var n := ds.decode_u32(L.DS_COUNT * 4)
	if n == 0:
		return PackedByteArray()
	return get_bytes(w, cur(w, "BUPS"), ds.decode_u32(L.DS_START * 4) * RB, n * RB)


func set_flags(w: World, row: int, flags: int) -> void:
	var b := zeros(4)
	b.encode_u32(0, flags)
	put(w, "DISHP", b, (row * L.DP_WORDS + L.DP_FLAGS) * 4)


# ---- recording ----------------------------------------------------------------------------------------------------------------------------

func disp(cl: int, w: World, k: String, groups: int, pa := 0.0, pb := 0.0, pc := 0.0, pd := 0.0) -> void:
	var key := k + ("|f" if w.flipped else "")
	if not w.sets.has(key):
		w.sets[key] = ShaderSet.uniform_set(rd, made[k], w.bufs, ["records"] if w.flipped and not w.today else [])
	rd.compute_list_bind_compute_pipeline(cl, made[k]["pipeline"])
	rd.compute_list_bind_uniform_set(cl, w.sets[key], 0)
	rd.compute_list_set_push_constant(cl, PackedFloat32Array([pa, pb, pc, pd]).to_byte_array(), 16)
	groups = maxi(groups, 1)
	if groups > max_x:
		rd.compute_list_dispatch(cl, max_x, (groups + max_x - 1) / max_x, 1)
	else:
		rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func threads(k: String, n: int) -> int:
	var local: int = made[k]["local"]
	return (n + local - 1) / local


func run_list(rec: Callable) -> float:
	var cl := rd.compute_list_begin()
	rec.call(cl)
	rd.compute_list_end()
	var t0 := Time.get_ticks_usec()
	rd.submit()
	rd.sync()
	return float(Time.get_ticks_usec() - t0)


func gscan(cl: int, w: World, prefix: String, g: int) -> void:
	disp(cl, w, prefix + "_chunks", g)
	disp(cl, w, prefix + "_sums", 1, float(g))
	disp(cl, w, prefix + "_add", g)


## The pooled world's conjugation (`apply` "pool_conj_apply", or "pool_conj_apply_blind" for the dish-blind index of C4).
func pool_conj(cl: int, w: World, g: int, apply := "pool_conj_apply") -> void:
	disp(cl, w, "pool_conj_clear", maxi(g, (w.buckets + 63) / 64 / 4))
	disp(cl, w, "pool_conj_count_blind" if apply.ends_with("_blind") else "pool_conj_count", g)
	gscan(cl, w, "pool_conj_scan", GpuKernels.scan_groups(w.buckets))
	disp(cl, w, "pool_conj_scatter", g)
	disp(cl, w, apply, g)


## One pooled step from the conjugation to the swap of the halves, its events into step place `st` of the ring.
func pool_step(cl: int, w: World, st: int, g: int, gs: int, apply := "pool_conj_apply", grow := true) -> void:
	if grow:
		disp(cl, w, "grow_pool", g)
	pool_conj(cl, w, g, apply)
	pool_life_part(cl, w, st, g, gs)


func pool_life_part(cl: int, w: World, st: int, g: int, gs: int) -> void:
	disp(cl, w, "pool_life", g)
	gscan(cl, w, "pool_scan_s", gs)
	gscan(cl, w, "pool_scan_k", gs)
	disp(cl, w, "pool_finalize", 1)
	disp(cl, w, "pool_events", g, float(st), 0.0)
	disp(cl, w, "pool_blk_fill", maxi(1, g / 64))
	disp(cl, w, "pool_compact", g)
	disp(cl, w, "pool_setcount", L.D_MAX / 64, 1.0)
	w.flipped = not w.flipped


func pool_stats(cl: int, w: World, g: int, st: int) -> void:
	disp(cl, w, "pool_stats1", maxi(1, g / 4))
	disp(cl, w, "pool_stats2", 64, 0.0, 0.0, float(st))


## A batch of `steps` pooled steps (pool_ev_begin first; `pipette` [src, dst, cx, cy, r] a retarget pass before them), then the stats.
func pool_batch(w: World, steps: int, g: int, gs := -1, apply := "pool_conj_apply", pipette := []) -> void:
	var scan_g := gs if gs > 0 else GpuKernels.scan_groups(w.phys)
	run_list(func(cl: int) -> void:
		disp(cl, w, "pool_ev_begin", L.D_MAX / 64)
		if not pipette.is_empty():
			pip_pass(cl, w, pipette, g, scan_g)
		for st in steps:
			pool_step(cl, w, st, g, scan_g, apply)
		pool_stats(cl, w, g, maxi(steps - 1, 0)))


func pip_pass(cl: int, w: World, pip: Array, g: int, gs: int) -> void:
	var pd := float(pip[0] + pip[1] * L.D_MAX)
	disp(cl, w, "pool_pip_mark", g, pip[2], pip[3], pip[4], pd)
	disp(cl, w, "pool_pip_max", g, pip[2], pip[3], pip[4], pd)
	gscan(cl, w, "pool_scan_s", gs)
	disp(cl, w, "pool_pip_final", 1, pip[2], pip[3], pip[4], pd)
	disp(cl, w, "pool_pip_scatter", g, pip[2], pip[3], pip[4], pd)
	disp(cl, w, "pool_blk_fill", maxi(1, g / 64))
	disp(cl, w, "pool_setcount", L.D_MAX / 64, 0.0)
	w.flipped = not w.flipped


# ---- the single-dish path's single dish -------------------------------------------------------------------------------------------------------------

func today_world(s: Dictionary, phys: int, wide := false) -> World:
	var w := make_world(phys, true, s["cap"])
	w.wide = wide
	var recs := records_of(s)
	put(w, "BUPS", recs)
	var n := recs.size() / RB
	var cnt := zeros(L.CNT_WORDS * 4)
	cnt.encode_u32(L.CNT_BUPS * 4, n)
	var first := L.make_id(s["number"], n + 1)
	cnt.encode_u32(L.CNT_NEXT_ID_LO * 4, first & 0xFFFFFFFF)
	cnt.encode_u32(L.CNT_NEXT_ID_HI * 4, first >> 32)
	cnt.encode_u32(L.CNT_SEED * 4, s["seed"])
	put(w, "CNT", cnt)
	set_p(w, "capacity", s["cap"])
	set_p(w, "limit", s["limit"])
	set_p(w, "stationary", 1.0 if s["stationary"] else 0.0)
	return w


func today_scan(cl: int, w: World, which: String) -> void:
	var sz := [w.cap, (w.cap + 255) / 256, 0]
	sz[2] = (sz[1] + 255) / 256
	var names := ["scan0_" + which, "scan1", "scan2", "add2", "add1_" + which]
	var at := [0, 1, 2, 1, 0]
	for k in 5:
		disp(cl, w, names[k], threads(names[k], sz[at[k]]), float(sz[at[k]]))


func today_step(cl: int, w: World, st: int, grow := true) -> void:
	var c := w.cap
	if grow:
		disp(cl, w, "grow_today", threads("grow_today", c))
	var x := "_wide" if w.wide else ""
	disp(cl, w, "conj_clear" + x, threads("conj_clear", 65536 * (32 if w.wide else 4) + 2048))
	disp(cl, w, "conj_insert" + x, threads("conj_insert", c))
	disp(cl, w, "conj_apply" + x, threads("conj_apply", c))
	disp(cl, w, "life", threads("life", c))
	today_scan(cl, w, "s")
	today_scan(cl, w, "k")
	disp(cl, w, "finalize", 1)
	disp(cl, w, "events", threads("events", c), float(st), 0.0)
	disp(cl, w, "compact", threads("compact", c * 7))
	disp(cl, w, "copy", threads("copy", c * 7))
	disp(cl, w, "ev_count", 1, 0.0, 0.0)
	disp(cl, w, "setcount", 1)


func today_stats(cl: int, w: World, st: int) -> void:
	var groups := (w.cap + 255) / 256
	disp(cl, w, "stats1", groups)
	disp(cl, w, "stats2", 1, float(groups), float(L.OUT_STATS), float(st))


func today_batch(w: World, steps: int) -> void:
	run_list(func(cl: int) -> void:
		disp(cl, w, "ev_begin", 1)
		for st in steps:
			today_step(cl, w, st)
		today_stats(cl, w, steps - 1))


# ---- dumps -----------------------------------------------------------------------------------------------------------------------------

## The ring's events of dish `number` (births by the id's dish number, deaths by ED_STEP's), in ring order: [births, deaths].
func ring_events(w: World, births: int, deaths: int, number: int) -> Array:
	var bo := PackedByteArray()
	var dout := PackedByteArray()
	var bn := mini(births, EV_CAP)
	var dn := mini(deaths, EV_CAP)
	var eb := get_bytes(w, "EVB", 0, maxi(bn, 1) * L.BIRTH_WORDS * 4)
	for k in bn:
		var o := k * L.BIRTH_WORDS * 4
		if (eb.decode_u32(o + L.EB_ID_HI * 4) >> L.ID_HI_DISH_SHIFT) == number:
			bo.append_array(eb.slice(o, o + L.BIRTH_WORDS * 4))
	var ed := get_bytes(w, "EVD", 0, maxi(dn, 1) * L.DEATH_WORDS * 4)
	for k in dn:
		var o := k * L.DEATH_WORDS * 4
		if L.death_dish_number(ed.decode_u32(o + L.ED_STEP * 4)) == number:
			dout.append_array(ed.slice(o, o + L.DEATH_WORDS * 4))
	return [bo, dout]


## Every running dish's dump after a batch: number -> {step, records, dstate (start cleared), stats, births, deaths}.
func dump_pool(w: World, rows: Array) -> Dictionary:
	var all := get_bytes(w, "DSTATE")
	var tb := 0
	var td := 0
	for row: int in L.D_MAX:
		tb += all.decode_u32((row * L.DS_WORDS + L.DS_BIRTHS) * 4)
		td += all.decode_u32((row * L.DS_WORDS + L.DS_DEATHS) * 4)
	var out := {}
	var dp := get_bytes(w, "DISHP")
	var stats := get_bytes(w, "STATS")
	for row: int in rows:
		var number := dp.decode_u32((row * L.DP_WORDS + L.DP_NUMBER) * 4)
		var ds := all.slice(row * L.DS_WORDS * 4, (row + 1) * L.DS_WORDS * 4)
		var step := ds.decode_u32(L.DS_STEP * 4)
		var n := ds.decode_u32(L.DS_COUNT * 4)
		var recs := get_bytes(w, cur(w, "BUPS"), ds.decode_u32(L.DS_START * 4) * RB, n * RB) if n > 0 else PackedByteArray()
		ds.encode_u32(L.DS_START * 4, 0)
		var ev := ring_events(w, tb, td, number)
		out[number] = {"step": step, "records": recs, "dstate": ds, "stats": stats.slice(row * L.STATS_DISH_WORDS * 4, row * L.STATS_DISH_WORDS * 4 + L.STATS_WORDS * 4), "births": ev[0], "deaths": ev[1]}
	return out


func first_diff(a: Dictionary, b: Dictionary) -> String:
	for k: String in ["step", "records", "dstate", "stats", "births", "deaths"]:
		if a[k] != b[k]:
			if a[k] is PackedByteArray:
				var x: PackedByteArray = a[k]
				var y: PackedByteArray = b[k]
				if x.size() != y.size():
					return "%s: %d bytes against %d" % [k, x.size(), y.size()]
				for o in range(0, x.size(), 4):
					if x.decode_u32(o) != y.decode_u32(o):
						return "%s: word %d 0x%08x against 0x%08x" % [k, o / 4, x.decode_u32(o), y.decode_u32(o)]
			return "%s: %s against %s" % [k, a[k], b[k]]
	return ""


# ---- C1: one dish against the single-dish path's ------------------------------------------------------------------------------------------------------

func c1() -> void:
	var dishes := {
		"plain": spec(0, 60, 11, 400, 0.0, false, 300.0),
		"stationary": spec(0, 60, 12, 300, 0.0, true, 300.0),
		"donors sparse": spec(0, 60, 15, 300, 0.1, false, 300.0),
		"donors": spec(0, 80, 13, 500, 0.3, false, 60.0),
		"cap": spec(0, 120, 14, 2000, 0.0, false, 300.0, 256),
	}
	var against_wide := {"donors": true}
	var transfers_seen := false
	for name: String in dishes:
		var s: Dictionary = dishes[name]
		var phys := 4096
		var wide: bool = against_wide.has(name)
		var t := today_world(s, phys, wide)
		var p := make_world(phys)
		put_dish(p, 0, s, 0)
		var same := true
		var why := ""
		var most := 0
		for batch in 6:
			today_batch(t, 10)
			pool_batch(p, 10, 7, 3)
			var cnt := get_bytes(t, "CNT")
			var ds := dstate_row(p, 0)
			var n := cnt.decode_u32(L.CNT_BUPS * 4)
			var pairs := [[L.CNT_BUPS, L.DS_COUNT], [L.CNT_SURVIVORS, L.DS_SURVIVORS], [L.CNT_NEWBORN, L.DS_NEWBORN], [L.CNT_NEXT_COUNT, L.DS_NEXT_COUNT],
				[L.CNT_NEXT_ID_LO, L.DS_NEXT_ID_LO], [L.CNT_NEXT_ID_HI, L.DS_NEXT_ID_HI], [L.CNT_STEP, L.DS_STEP], [L.CNT_GROWTH, L.DS_GROWTH],
				[L.CNT_BIRTHS, L.DS_BIRTHS], [L.CNT_DEATHS, L.DS_DEATHS], [L.CNT_BIRTHS_LOST, L.DS_BIRTHS_LOST], [L.CNT_DEATHS_LOST, L.DS_DEATHS_LOST],
				[L.CNT_DONORS, L.DS_DONORS], [L.CNT_DONOR_REACH, L.DS_DONOR_REACH], [L.CNT_TRIMMED, L.DS_TRIMMED]]
			for pr: Array in pairs:
				if cnt.decode_u32(pr[0] * 4) != ds.decode_u32(pr[1] * 4) and same:
					same = false
					why = "batch %d counter %d: today %d, pooled %d" % [batch, pr[0], cnt.decode_u32(pr[0] * 4), ds.decode_u32(pr[1] * 4)]
			if same and (get_bytes(t, "BUPS", 0, n * RB) if n > 0 else PackedByteArray()) != segment(p, 0):
				same = false
				why = "batch %d records" % batch
			var nb := cnt.decode_u32(L.CNT_BIRTHS * 4)
			var nd := cnt.decode_u32(L.CNT_DEATHS * 4)
			if same and (get_bytes(t, "EVB", 0, maxi(nb, 1) * L.BIRTH_WORDS * 4) != get_bytes(p, "EVB", 0, maxi(nb, 1) * L.BIRTH_WORDS * 4) or get_bytes(t, "EVD", 0, maxi(nd, 1) * L.DEATH_WORDS * 4) != get_bytes(p, "EVD", 0, maxi(nd, 1) * L.DEATH_WORDS * 4)):
				same = false
				why = "batch %d events (%d births, %d deaths)" % [batch, nb, nd]
			if same and get_bytes(t, "OUT", L.OUT_STATS * 4, L.STATS_WORDS * 4) != get_bytes(p, "STATS", 0, L.STATS_WORDS * 4):
				same = false
				why = "batch %d stats" % batch
			if wide:  # (the most donors in one bucket of the last step's table: the single-dish path's 4-slot table drops those past 4)
				var tab := get_bytes(t, "DTAB", 0, 65536 * 32 * 4)
				for h in 65536:
					var used := 0
					for k in 32:
						if tab.decode_u32((h * 32 + k) * 4) != 0xFFFFFFFF:
							used += 1
					most = maxi(most, used)
		var n_end := ds_word(p, 0, L.DS_COUNT)
		print("C1 %s: %d bups after 60 steps, %d donors, births lost %d" % [name, n_end, ds_word(p, 0, L.DS_DONORS), ds_word(p, 0, L.DS_BIRTHS_LOST)])
		ok(same, "C1 %s: pooled equals the single-dish path's%s bit for bit (records, counters, events, stats) %s" % [name, " with a 32-slot donor table (at most %d donors in a bucket at a batch's end; the single-dish path's 4-slot table drops those past 4)" % most if wide else "", why])
		if name == "donors":
			var q := make_world(phys)
			put_dish(q, 0, s, 0)
			set_p(q, "conj_chance", 0.0)
			for batch in 6:
				pool_batch(q, 10, 7, 3)
			transfers_seen = segment(q, 0) != segment(p, 0)
			free_world(q)
		free_world(t)
		free_world(p)
	ok(transfers_seen, "C1 donors: transfers happen (the run differs from one with no transfers)")


# ---- C2-C4: isolation and permutation --------------------------------------------------------------------------------------------------

func random_specs(count: int, first_number: int, r: RandomNumberGenerator) -> Array:
	var out := []
	for k in count:
		var limit := r.randi_range(40, 600)
		var cap := -1 if r.randf() < 0.8 else r.randi_range(1, 3) * 256
		out.append(spec(first_number + k, r.randi_range(0, 90), r.randi_range(1, 1 << 30), limit, [0.0, 0.0, 0.1, 0.4][r.randi() % 4], r.randf() < 0.3, [30.0, 60.0][r.randi() % 2], cap))
	return out


## Dish `s` alone for `batches` batches of 10 steps (row 3, slot 0, 13 groups): its dumps by its step.
func alone(s: Dictionary, batches: int) -> Dictionary:
	var w := make_world(8192)
	put_dish(w, 3, s, 0)
	var out := {}
	for k in batches:
		pool_batch(w, 10, 13, 5)
		var d: Dictionary = dump_pool(w, [3])[s["number"]]
		out[d["step"]] = d
	free_world(w)
	return out




## A pool of `specs` in `rows` (rows[k] for specs[k]) for `batches` batches of 10 steps, each dish compared after every batch with its
## run alone (`alone_runs`: number -> step -> dump). `remove` [batch, index]: that dish is removed in that batch (DPF_REMOVED, then its
## row cleared); `add` [batch, spec, row]: that dish joins before that batch, at the end of the slots in use. Returns the dishes that differ.
func pool_run(specs: Array, rows: Array, batches: int, alone_runs: Dictionary, apply := "pool_conj_apply", remove := [], add := []) -> Array:
	var phys := 0
	for s: Dictionary in specs:
		phys += int(s["cap"]) + 256
	if not add.is_empty():
		phys += int(add[1]["cap"])
	var w := make_world(phys + 1024)
	var start := 0
	for k in specs.size():
		put_dish(w, rows[k], specs[k], start)
		start += (int(specs[k]["n"]) + 255) / 256 * 256 + (256 if k % 3 == 1 else 0)  # (a gap of no dish now and then)
	var live := rows.duplicate()
	var bad := []
	var g := GpuKernels.bup_groups(start)
	for bt in batches:
		var removed_row := -1
		if not remove.is_empty() and bt == remove[0]:
			removed_row = rows[remove[1]]
			set_flags(w, removed_row, flags_of(specs[remove[1]]) | (1 << L.DPF_REMOVED))
			live.erase(removed_row)
		if not add.is_empty() and bt == add[0]:
			put_dish(w, add[2], add[1], get_bytes(w, "WORLD").decode_u32(L.WD_SLOTS * 4))
			live.append(add[2])
		pool_batch(w, 10, g, -1, apply)
		if removed_row >= 0:
			var number: int = specs[remove[1]]["number"]
			var tb := 0
			var td := 0
			for row: int in live:
				tb += ds_word(w, row, L.DS_BIRTHS)
				td += ds_word(w, row, L.DS_DEATHS)
			var gone := ring_events(w, tb, td, number)
			ok(ds_word(w, removed_row, L.DS_COUNT) == 0 and ds_word(w, removed_row, L.DS_DEATHS) == 0 and ds_word(w, removed_row, L.DS_BIRTHS) == 0 and (gone[0] as PackedByteArray).is_empty() and (gone[1] as PackedByteArray).is_empty(), "the removed dish %d leaves with no bups, no births, no deaths and no events" % number)
			set_flags(w, removed_row, 0)
		var dumps := dump_pool(w, live)
		for number: int in dumps:
			var d: Dictionary = dumps[number]
			var mine: Dictionary = alone_runs[number]
			var step: int = d["step"]
			if not mine.has(step):
				if not bad.has(number):
					bad.append(number)
					print("  dish %d: no run alone at its step %d" % [number, step])
				continue
			var line := first_diff(mine[step], d)
			if line != "" and not bad.has(number):
				bad.append(number)
				if bad.size() <= 3:
					print("  dish %d at its step %d: %s" % [number, step, line])
	free_world(w)
	return bad


func c2_c4() -> void:
	var r := RandomNumberGenerator.new()
	r.seed = 2026
	var x := spec(1, 50, 4242, 300, 0.2, false, 40.0)
	var others := random_specs(64, 100, r)
	var extra := spec(500, 40, 999, 200, 0.2, false, 40.0)
	var runs := {}
	for s: Dictionary in [x, extra] + others:
		runs[s["number"]] = alone(s, 20)
	var total := 0
	for s: Dictionary in others:
		total += ds_word_last(runs[s["number"]])
	print("C2 the 64 others hold %d bups after 200 steps alone" % total)
	var rows_all := []
	for k in L.D_MAX:
		rows_all.append(k)
	for count: int in [1, 7, 64]:
		var specs := [x] + others.slice(0, count)
		rows_all.shuffle()
		var bad := pool_run(specs, rows_all.slice(0, specs.size()), 20, runs)
		ok(bad.is_empty(), "C2 isolation: each of %d dishes equals its run alone over 200 steps (differing: %s)" % [specs.size(), bad])
	var specs := [x] + others
	var rows := []
	for k in specs.size():
		rows.append(L.D_MAX - 1 - k * 7)
	var bad := pool_run(specs, rows, 20, runs)
	ok(bad.is_empty(), "C3 permutation: rows reversed, every dish equals its run alone (differing: %s)" % [bad])
	rows.shuffle()
	bad = pool_run(specs, rows, 20, runs, "pool_conj_apply", [4, 9], [6, extra, 2])
	ok(bad.is_empty(), "C3 permutation: rows shuffled, dish %d removed in batch 4, dish 500 added before batch 6: the rest and the added dish equal their runs alone (differing: %s)" % [others[8]["number"], bad])
	bad = pool_run(specs, rows, 20, runs, "pool_conj_apply_blind")
	ok(not bad.is_empty(), "C4 the pool with a dish-blind donors' index (no dish in the hash, no dish check) differs from the runs alone (%d dishes differ): C2 sees a transfer across dishes" % bad.size())


func ds_word_last(dumps: Dictionary) -> int:
	var last := -1
	for step: int in dumps:
		last = maxi(last, step)
	var d: Dictionary = dumps[last]
	return (d["dstate"] as PackedByteArray).decode_u32(L.DS_COUNT * 4)


# ---- C5: the retarget ---------------------------------------------------------------------------------------------------------------

func f32(v: float) -> float:
	return PackedFloat32Array([v])[0]


func c5() -> void:
	var src_s := spec(21, 120, 77, 400, 0.15, false, 60.0)
	var a_s := spec(22, 80, 78, 300, 0.1, false, 60.0)
	var b_s := spec(23, 90, 79, 300, 0.0, true, 60.0)
	var dst_s := spec(77, 0, 80, 400, 0.0, false, 60.0)
	var w := make_world(8192)
	put_dish(w, 4, src_s, 0)
	put_dish(w, 0, a_s, 1024)
	put_dish(w, 9, b_s, 2048)
	for k in 3:
		pool_batch(w, 10, 9)
	put_dish(w, 6, dst_s, get_bytes(w, "WORLD").decode_u32(L.WD_SLOTS * 4))
	var rows := [0, 4, 6, 9]
	var before := {}
	var counts := {}
	for row: int in rows:
		before[row] = segment(w, row)
		counts[row] = ds_word(w, row, L.DS_COUNT)
	var cx := 10.0
	var cy := -5.0
	var rad := 30.0
	var moved := PackedByteArray()
	var stay := PackedByteArray()
	var moved_ids := {}
	var max_counter := 0
	var src_recs: PackedByteArray = before[4]
	for k in src_recs.size() / RB:
		var rec := src_recs.slice(k * RB, (k + 1) * RB)
		var dx := f32(rec.decode_float(L.R_X * 4) - cx)
		var dy := f32(rec.decode_float(L.R_Y * 4) - cy)
		if f32(f32(dx * dx) + f32(dy * dy)) <= f32(rad * rad):
			rec.encode_float(L.R_X * 4, dx)
			rec.encode_float(L.R_Y * 4, dy)
			moved.append_array(rec)
			var id := L.id_of(rec, 0)
			moved_ids[id] = true
			max_counter = maxi(max_counter, L.id_counter(id))
		else:
			stay.append_array(rec)
	var m := moved.size() / RB
	var sentinel := PackedByteArray()
	sentinel.resize(64)
	sentinel.fill(0xAB)
	put(w, "EVB", sentinel)
	put(w, "EVD", sentinel)
	pool_batch(w, 0, 9, -1, "pool_conj_apply", [4, 6, cx, cy, rad])
	print("C5 the source held %d, the disc %d" % [counts[4], m])
	ok(m > 0 and ds_word(w, 4, L.DS_MOVED_OUT) == m and ds_word(w, 6, L.DS_MOVED_IN) == m, "C5 DS_MOVED_OUT %d and DS_MOVED_IN %d equal the bups in the disc (%d)" % [ds_word(w, 4, L.DS_MOVED_OUT), ds_word(w, 6, L.DS_MOVED_IN), m])
	ok(segment(w, 6) == moved, "C5 the destination holds the moved bups in order, every word kept but x, y shifted by the centre exactly")
	ok(segment(w, 4) == stay, "C5 the source keeps the others in order, unchanged")
	ok(segment(w, 0) == before[0] and segment(w, 9) == before[9], "C5 the other dishes are unchanged")
	ok(ds_word(w, 4, L.DS_COUNT) == counts[4] - m and ds_word(w, 6, L.DS_COUNT) == m, "C5 counts: the source %d - %d, the destination %d" % [counts[4], m, m])
	var no_events := true
	for row: int in rows:
		no_events = no_events and ds_word(w, row, L.DS_BIRTHS) == 0 and ds_word(w, row, L.DS_DEATHS) == 0 and ds_word(w, row, L.DS_MOVED_IN) + ds_word(w, row, L.DS_MOVED_OUT) == (m if row == 4 or row == 6 else 0)
	ok(no_events and get_bytes(w, "EVB", 0, 64) == sentinel and get_bytes(w, "EVD", 0, 64) == sentinel, "C5 the pass counts no birth or death and writes no event")
	var st_src := get_bytes(w, "STATS", 4 * L.STATS_DISH_WORDS * 4, 4).decode_float(0)
	var st_dst := get_bytes(w, "STATS", 6 * L.STATS_DISH_WORDS * 4, 4).decode_float(0)
	ok(int(st_src) == counts[4] - m and int(st_dst) == m, "C5 the stats after the pass count %d in the source and %d in the destination" % [int(st_src), int(st_dst)])
	var ds6 := dstate_row(w, 6)
	var next_id := ds6.decode_u32(L.DS_NEXT_ID_LO * 4) | (ds6.decode_u32(L.DS_NEXT_ID_HI * 4) << 32)
	ok(L.id_dish_number(next_id) == 77 and L.id_counter(next_id) == max_counter + 1, "C5 the destination's next id: number %d, counter %d (largest moved %d)" % [L.id_dish_number(next_id), L.id_counter(next_id), max_counter])
	var blk := get_bytes(w, cur(w, "BLKDISH"))
	var slots := get_bytes(w, "WORLD").decode_u32(L.WD_SLOTS * 4)
	var table_ok := true
	var expect_slots := 0
	for row: int in rows:
		var st := ds_word(w, row, L.DS_START)
		var n := ds_word(w, row, L.DS_COUNT)
		expect_slots += (n + 255) / 256 * 256
		for k in (n + 255) / 256:
			table_ok = table_ok and blk.decode_u32((st / 256 + k) * 4) == row and st % 256 == 0
	ok(table_ok and slots == expect_slots, "C5 the block table is the segments (%d slots in use)" % slots)
	# the next batch: the moved bups' births and deaths are the destination's
	var count0 := {}
	for row: int in rows:
		count0[row] = ds_word(w, row, L.DS_COUNT)
	pool_batch(w, 5, 9)
	var tb := 0
	var td := 0
	for row: int in rows:
		tb += ds_word(w, row, L.DS_BIRTHS)
		td += ds_word(w, row, L.DS_DEATHS)
	var eb := get_bytes(w, "EVB", 0, tb * L.BIRTH_WORDS * 4)
	var ed := get_bytes(w, "EVD", 0, td * L.DEATH_WORDS * 4)
	var family := moved_ids.duplicate()
	var events_ok := true
	var seen := 0
	for k in tb:
		var o := k * L.BIRTH_WORDS * 4
		var parent := eb.decode_u32(o + L.EB_PARENT_LO * 4) | (eb.decode_u32(o + L.EB_PARENT_HI * 4) << 32)
		var id := eb.decode_u32(o + L.EB_ID_LO * 4) | (eb.decode_u32(o + L.EB_ID_HI * 4) << 32)
		if family.has(parent):
			family[id] = true
			seen += 1
		events_ok = events_ok and (family.has(parent) == (L.id_dish_number(id) == 77))
	for k in td:
		var o := k * L.DEATH_WORDS * 4
		var id := ed.decode_u32(o + L.ED_ID_LO * 4) | (ed.decode_u32(o + L.ED_ID_HI * 4) << 32)
		var number := L.death_dish_number(ed.decode_u32(o + L.ED_STEP * 4))
		if family.has(id):
			seen += 1
		events_ok = events_ok and (family.has(id) == (number == 77))
	ok(events_ok and seen > 0, "C5 the next 5 steps: all %d events of the moved bups and their young are the destination's, none the source's" % seen)
	var balance := true
	for row: int in rows:
		balance = balance and ds_word(w, row, L.DS_COUNT) - count0[row] == ds_word(w, row, L.DS_BIRTHS) - ds_word(w, row, L.DS_DEATHS) + ds_word(w, row, L.DS_MOVED_IN) - ds_word(w, row, L.DS_MOVED_OUT)
		balance = balance and count0[row] - counts[row] == (m if row == 6 else (-m if row == 4 else 0))
	ok(balance, "C5: count after - before = births - deaths + moved in - moved out, every dish, the pass's batch and the next")
	# the destination alone, loaded from its records and DSTATE
	var w2 := make_world(8192)
	put_dish(w2, 3, dst_s, 0, segment(w, 6), dstate_row(w, 6))
	var same := true
	for k in 2:
		pool_batch(w, 10, 9)
		pool_batch(w2, 10, 13, 5)
		var a: Dictionary = dump_pool(w, rows)[77]
		var b: Dictionary = dump_pool(w2, [3])[77]
		var line := first_diff(a, b)
		if line != "" and same:
			same = false
			print("  the destination at step %d: %s" % [a["step"], line])
	ok(same, "C5 the destination continued 20 steps equals it alone, loaded from its records and DSTATE after the pass")
	free_world(w2)
	free_world(w)


# ---- C6: timing --------------------------------------------------------------------------------------------------------------------

func snapshot(w: World, names: Array) -> Dictionary:
	var out := {}
	for nm: String in names:
		out[nm] = get_bytes(w, nm)
	return out


func restore(w: World, state: Dictionary) -> void:
	for nm: String in state:
		put(w, nm, state[nm])
	rd.submit()
	rd.sync()


func median(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2]


func bench(w: World, state: Dictionary, rec: Callable, reps: int) -> float:
	var t := []
	for r in reps:
		restore(w, state)
		w.flipped = false
		t.append(run_list(rec))
	return median(t)


## records_of for a big dish, faster: the same words, laid out from a template.
func records_fast(s: Dictionary) -> PackedByteArray:
	var r := RandomNumberGenerator.new()
	r.seed = s["seed"]
	var n: int = s["n"]
	var add: float = consts["add_mass_factor"] * 16.0
	var tmpl := records_of(spec(0, 1, 1, 1)).to_float32_array()
	var f := PackedFloat32Array()
	f.resize(n * W)
	for k in n:
		var o := k * W
		for word in W:
			f[o + word] = tmpl[word]
		var a := r.randf() * TAU
		var rad := sqrt(r.randf()) * float(s["pack"])
		f[o + L.R_X] = cos(a) * rad
		f[o + L.R_Y] = sin(a) * rad
		f[o + L.R_MASS] = add * (2.05 if r.randf() < float(s["ready"]) else 1.0 + r.randf())
		f[o + L.R_SPEED] = 20.0 + r.randf() * 10.0
		f[o + L.R_DONOR] = 1.0 if r.randf() < float(s["donors"]) else 0.0
	var out := f.to_byte_array()
	for k in n:
		L.set_id(out, k, k + 1)
	return out


func timing(n: int) -> void:
	var reps := 7
	var s := spec(0, n, 5, n, 0.02, false, 80000.0, -1, 0.05)
	var phys := int(s["cap"])
	print("C6 %d bups in one dish, capacity %d, bup_groups %d, scan_groups %d, conj buckets %d" % [n, phys, GpuKernels.bup_groups(n), GpuKernels.scan_groups(n), GpuKernelsLife.conj_buckets(n)])
	var recs := records_fast(s)
	var t := make_world(phys, true, s["cap"])
	put(t, "BUPS", recs)
	var cnt := zeros(L.CNT_WORDS * 4)
	cnt.encode_u32(L.CNT_BUPS * 4, n)
	cnt.encode_u32(L.CNT_NEXT_ID_LO * 4, n + 1)
	cnt.encode_u32(L.CNT_SEED * 4, s["seed"])
	put(t, "CNT", cnt)
	set_p(t, "capacity", s["cap"])
	set_p(t, "limit", s["limit"])
	var p := make_world(phys)
	put(p, "BUPS", recs)
	var dp := zeros(L.DP_WORDS * 4)
	dp.encode_u32(L.DP_LIMIT * 4, s["limit"])
	dp.encode_u32(L.DP_CAP * 4, s["cap"])
	dp.encode_u32(L.DP_FLAGS * 4, flags_of(s))
	put(p, "DISHP", dp)
	var ds := zeros(L.DS_WORDS * 4)
	ds.encode_u32(L.DS_COUNT * 4, n)
	ds.encode_u32(L.DS_NEXT_ID_LO * 4, n + 1)
	ds.encode_u32(L.DS_SEED * 4, s["seed"])
	put(p, "DSTATE", ds)
	var rows := PackedByteArray()
	rows.resize(((n + 255) / 256) * 4)
	put(p, "BLKDISH", rows)
	var wd := zeros(4)
	wd.encode_u32(0, (n + 255) / 256 * 256)
	put(p, "WORLD", wd, L.WD_SLOTS * 4)
	var g := GpuKernels.bup_groups(n)
	var gs := GpuKernels.scan_groups(n)
	var small_p := ["DSTATE", "DNEXT", "WORLD", "BLKDISH"]
	var tsm0 := snapshot(t, ["CNT"])
	var psm0 := snapshot(p, small_p)
	var noop := bench(p, {}, func(cl: int) -> void: disp(cl, p, "noop", 1), reps)
	print("noop list %.0f us" % noop)
	var sums := [0.0, 0.0]
	var row := func(name: String, today_us: float, pool_us: float) -> void:
		var a := today_us - noop
		var b := pool_us - noop
		sums[0] += a
		sums[1] += b
		print("TIME %s: today %.0f us, pooled %.0f us%s" % [name, a, b, (", ratio %.3f" % (b / a)) if a > 0.0 else ""])
	var with_bups := func(st: Dictionary) -> Dictionary:
		var d := st.duplicate()
		d["BUPS"] = recs
		return d
	row.call("conj (2% donors)", bench(t, tsm0, func(cl: int) -> void:
		disp(cl, t, "conj_clear", threads("conj_clear", 65536 * 4 + 2048))
		disp(cl, t, "conj_insert", threads("conj_insert", t.cap))
		disp(cl, t, "conj_apply", threads("conj_apply", t.cap)), reps), bench(p, psm0, func(cl: int) -> void: pool_conj(cl, p, g), reps))
	row.call("life", bench(t, with_bups.call(tsm0), func(cl: int) -> void: disp(cl, t, "life", threads("life", t.cap)), reps), bench(p, with_bups.call(psm0), func(cl: int) -> void: disp(cl, p, "pool_life", g), reps))
	restore(t, with_bups.call(tsm0))
	restore(p, with_bups.call(psm0))
	run_list(func(cl: int) -> void: disp(cl, t, "life", threads("life", t.cap)))
	run_list(func(cl: int) -> void: disp(cl, p, "pool_life", g))
	row.call("scans (2)", bench(t, {}, func(cl: int) -> void:
		today_scan(cl, t, "s")
		today_scan(cl, t, "k"), reps), bench(p, {}, func(cl: int) -> void:
		gscan(cl, p, "pool_scan_s", gs)
		gscan(cl, p, "pool_scan_k", gs), reps))
	var tsm1 := snapshot(t, ["CNT"])
	var psm1 := snapshot(p, small_p)
	row.call("finalize", bench(t, tsm1, func(cl: int) -> void: disp(cl, t, "finalize", 1), reps), bench(p, psm1, func(cl: int) -> void: disp(cl, p, "pool_finalize", 1), reps))
	restore(t, tsm1)
	restore(p, psm1)
	run_list(func(cl: int) -> void: disp(cl, t, "finalize", 1))
	run_list(func(cl: int) -> void: disp(cl, p, "pool_finalize", 1))
	var tsm2 := snapshot(t, ["CNT"])
	var psm2 := snapshot(p, small_p)
	print("after life: %d kept, %d newborn" % [ds_word(p, 0, L.DS_SURVIVORS), ds_word(p, 0, L.DS_NEWBORN)])
	row.call("events", bench(t, tsm2, func(cl: int) -> void: disp(cl, t, "events", threads("events", t.cap)), reps), bench(p, psm2, func(cl: int) -> void: disp(cl, p, "pool_events", g), reps))
	row.call("blk_fill", noop, bench(p, psm2, func(cl: int) -> void: disp(cl, p, "pool_blk_fill", maxi(1, g / 64)), reps))
	row.call("compact (+ copy today)", bench(t, tsm2, func(cl: int) -> void:
		disp(cl, t, "compact", threads("compact", t.cap * 7))
		disp(cl, t, "copy", threads("copy", t.cap * 7)), reps), bench(p, psm2, func(cl: int) -> void: disp(cl, p, "pool_compact", g), reps))
	row.call("setcount", bench(t, tsm2, func(cl: int) -> void: disp(cl, t, "setcount", 1), reps), bench(p, psm2, func(cl: int) -> void: disp(cl, p, "pool_setcount", L.D_MAX / 64, 1.0), reps))
	row.call("stats (1 + 2)", bench(t, tsm2, func(cl: int) -> void: today_stats(cl, t, 0), reps), bench(p, psm2, func(cl: int) -> void: pool_stats(cl, p, g, 0), reps))
	print("SUM of the parts: today %.0f us, pooled %.0f us" % [sums[0], sums[1]])
	row.call("bup step (conj to setcount, one list)", bench(t, with_bups.call(tsm0), func(cl: int) -> void: today_step(cl, t, 0, false), reps), bench(p, with_bups.call(psm0), func(cl: int) -> void: pool_step(cl, p, 0, g, gs, "pool_conj_apply", false), reps))
	# no donors: the conjugation's cost with nothing to transfer
	var nod := recs.duplicate()
	for k in n:
		nod.encode_float(k * RB + L.R_DONOR * 4, 0.0)
	put(t, "BUPS", nod)
	put(p, "BUPS", nod)
	row.call("conj (no donors)", bench(t, tsm0, func(cl: int) -> void:
		disp(cl, t, "conj_clear", threads("conj_clear", 65536 * 4 + 2048))
		disp(cl, t, "conj_insert", threads("conj_insert", t.cap))
		disp(cl, t, "conj_apply", threads("conj_apply", t.cap)), reps), bench(p, psm0, func(cl: int) -> void: pool_conj(cl, p, g), reps))
	# the pipette: a new empty dish in row 1, about half of the dish moved
	put(p, "BUPS", recs)
	restore(p, psm0)
	var dp1 := zeros(L.DP_WORDS * 4)
	dp1.encode_u32(L.DP_LIMIT * 4, s["limit"])
	dp1.encode_u32(L.DP_CAP * 4, s["cap"])
	dp1.encode_u32(L.DP_FLAGS * 4, 1 << L.DPF_RUNNING)
	dp1.encode_u32(L.DP_NUMBER * 4, 1)
	put(p, "DISHP", dp1, L.DP_WORDS * 4)
	var ds1 := zeros(L.DS_WORDS * 4)
	ds1.encode_u32(L.DS_START * 4, (n + 255) / 256 * 256)
	put(p, "DSTATE", ds1, L.DS_WORDS * 4)
	var psm4 := snapshot(p, small_p)
	row.call("retarget pass (half moved)", noop, bench(p, psm4, func(cl: int) -> void: pip_pass(cl, p, [0, 1, 0.0, 0.0, 80000.0 * 0.7071], g, gs), reps))
	print("moved %d" % ds_word(p, 1, L.DS_COUNT))
	ok(true, "C6 timing done")
	free_world(t)
	free_world(p)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else "check"
	consts = SimConstants.build()
	seed(2026)
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		print("SKIP pool_life_check: no local rendering device (run windowed)")
		quit(0)
		return
	max_x = rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X)
	var shaders := ShaderSet.from_source(probe_defs())
	made = shaders.create(rd)
	ok(shaders.errors.is_empty(), "the pooled kernels compile: %s" % [shaders.errors])
	print("device %s" % rd.get_device_name())
	if mode == "time":
		timing(int(args[1]) if args.size() > 1 else 2000000)
	else:
		c1()
		c5()
		c2_c4()
	print("POOL LIFE CHECK DONE fails=%d" % fails)
	ShaderSet.free_all(rd, made)
	rd.free()
	quit(0 if fails == 0 else 1)
