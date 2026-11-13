extends SceneTree
## Padded diffusion check (the pooled pool_diffuse_a/b and pool_diffuse2_a/b against the single-dish diffuse_a/b run on each dish alone).
## Run: tools/run_windowed.sh <out> -- --path <worktree> --rendering-driver metal --position 6000,6000 -s tools/gpu/pool_diffuse_check.gd
##
## Expected, written before the first run:
## D1 Two dishes in one pool, 20 across at k 0.15 for 2 iterations and 12 across at k 0.19 for 10, each field the same as the dish
##    diffused alone by diffuse_a/b (the single-dish kernels, P_CELLS = its cells across, pcs.pb = its k), bitwise, in both dish orders,
##    for the glucose field (CONC) and the acetate field (CONC2, with the flag on). [derived: the same stencil in the same order per cell;
##    a dish past its iterations returns before touching its cells, so the pass count of the longest one does not reach it]
## D2 The padding cells between the dishes' grids (and past the last) and a dish with the acetate flag off keep the values they had
##    in CONC2 and CONC2B (not diffused). [derived: CELLDISH is NO_DISH there; the flag skips the pass]

var rd: RenderingDevice
var made := {}
var fails := 0


func ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		fails += 1


func fbuf(values: PackedFloat32Array) -> RID:
	var b := values.to_byte_array()
	return rd.storage_buffer_create(maxi(16, b.size()), b)


func ubuf(values: PackedInt32Array) -> RID:
	var b := values.to_byte_array()
	return rd.storage_buffer_create(maxi(16, b.size()), b)


func dispatch(cl: int, name: String, rids: Dictionary, groups: int, pa: float, pb: float) -> void:
	var set_rid := ShaderSet.uniform_set(rd, made[name], rids)
	rd.compute_list_bind_compute_pipeline(cl, made[name]["pipeline"])
	rd.compute_list_bind_uniform_set(cl, set_rid, 0)
	rd.compute_list_set_push_constant(cl, PackedFloat32Array([pa, pb, 0.0, 0.0]).to_byte_array(), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func run(rec: Callable) -> void:
	var cl := rd.compute_list_begin()
	rec.call(cl)
	rd.compute_list_end()
	rd.submit()
	rd.sync()


func floats(rid: RID) -> PackedFloat32Array:
	return rd.buffer_get_data(rid).to_float32_array()


## A disc of INSIDE cells with values from the dish's own seed.
func make_field(n: int, seed_v: int) -> Dictionary:
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	var inside := PackedInt32Array()
	var conc := PackedFloat32Array()
	var conc2 := PackedFloat32Array()
	for y in n:
		for x in n:
			var dx := x - (n - 1) / 2.0
			var dy := y - (n - 1) / 2.0
			var is_in := dx * dx + dy * dy <= (n / 2.0) * (n / 2.0)
			inside.append(1 if is_in else 0)
			conc.append(r.randf() * 3.0 if is_in else 0.0)
			conc2.append(r.randf() * 0.5 if is_in else 0.0)
	return {"inside": inside, "conc": conc, "conc2": conc2}


## The dish alone: the single-dish kernels, `iterations / 2` times (a, b), with k in pcs.pb and P_CELLS the cells across.
func alone(f: Dictionary, n: int, k: float, iterations: int, acetate: bool) -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(256)
	p[1] = float(n)
	var cells := n * n
	var rids := {"P": fbuf(p), "INSIDE": ubuf(f["inside"]), "CONC": fbuf(f["conc"]), "EFF": fbuf(PackedFloat32Array(f["conc"])),
		"CONC2": fbuf(f["conc2"]), "CONC2B": fbuf(PackedFloat32Array(f["conc2"]))}
	var groups := (cells + 63) / 64
	run(func(cl: int) -> void:
		for _i in iterations / 2:
			dispatch(cl, "diffuse_a", rids, groups, 0.0, k)
			dispatch(cl, "diffuse_b", rids, groups, 0.0, k)
			if acetate:
				dispatch(cl, "diffuse2_a", rids, groups, 0.0, k)
				dispatch(cl, "diffuse2_b", rids, groups, 0.0, k))
	return {"conc": floats(rids["CONC"]), "conc2": floats(rids["CONC2"])}


func pooled(order: Array, dishes: Dictionary) -> Dictionary:
	var dp := PackedInt32Array()
	dp.resize(GpuLayout.D_MAX * GpuLayout.DP_WORDS)
	var celldish := PackedInt32Array()
	var base := 0
	var max_iter := 0
	var bases := {}
	for row in order.size():
		var name: String = order[row]
		var dd: Dictionary = dishes[name]
		var n: int = dd["n"]
		var o := row * GpuLayout.DP_WORDS
		dp[o + GpuLayout.DP_FIELD_BASE] = base
		dp[o + GpuLayout.DP_CELLS] = n
		dp[o + GpuLayout.DP_K] = (PackedFloat32Array([dd["k"]]).to_byte_array().to_int32_array())[0]
		dp[o + GpuLayout.DP_ITERATIONS] = dd["iterations"]
		dp[o + GpuLayout.DP_FLAGS] = (1 << GpuLayout.DPF_ACETATE) if dd["acetate"] else 0
		bases[name] = base
		var span := ((n * n + 255) / 256) * 256
		for c in span:
			celldish.append(row if c < n * n else -1)
		base += span
		max_iter = maxi(max_iter, dd["iterations"])
	# a guard block of no dish at the end, filled with markers
	for c in 256:
		celldish.append(-1)
	var total := base + 256
	var inside := PackedInt32Array()
	var conc := PackedFloat32Array()
	var conc2 := PackedFloat32Array()
	inside.resize(total)
	conc.resize(total)
	conc2.resize(total)
	conc.fill(-7.0)
	conc2.fill(-9.0)
	for name: String in order:
		var f: Dictionary = dishes[name]["field"]
		for c in f["inside"].size():
			inside[bases[name] + c] = f["inside"][c]
			conc[bases[name] + c] = f["conc"][c]
			conc2[bases[name] + c] = f["conc2"][c]
	var p := PackedFloat32Array()
	p.resize(256)
	var rids := {"CELLDISH": ubuf(celldish), "DISHP": ubuf(dp), "INSIDE": ubuf(inside), "CONC": fbuf(conc), "EFF": fbuf(PackedFloat32Array(conc)),
		"CONC2": fbuf(conc2), "CONC2B": fbuf(PackedFloat32Array(conc2))}
	var groups := (base + 63) / 64
	run(func(cl: int) -> void:
		for it in max_iter:
			var a := "pool_diffuse_a" if it % 2 == 0 else "pool_diffuse_b"
			var b := "pool_diffuse2_a" if it % 2 == 0 else "pool_diffuse2_b"
			dispatch(cl, a, rids, groups, float(it), float(base))
			dispatch(cl, b, rids, groups, float(it), float(base)))
	return {"conc": floats(rids["CONC"]), "conc2": floats(rids["CONC2"]), "bases": bases, "total": total, "conc_in": conc, "conc2_in": conc2}


func _initialize() -> void:
	rd = RenderingServer.create_local_rendering_device()
	var shaders := ShaderSet.from_source(GpuKernels.all())
	made = shaders.create(rd)
	ok(shaders.errors.is_empty(), "kernels compile: %s" % [shaders.errors])
	var dishes := {
		"A": {"n": 20, "k": 0.15, "iterations": 2, "acetate": true, "field": make_field(20, 11)},
		"B": {"n": 12, "k": 0.19, "iterations": 10, "acetate": false, "field": make_field(12, 12)},
		"C": {"n": 17, "k": 0.1, "iterations": 4, "acetate": true, "field": make_field(17, 13)},
	}
	var refs := {}
	for name: String in dishes:
		var d: Dictionary = dishes[name]
		refs[name] = alone(d["field"], d["n"], d["k"], d["iterations"], d["acetate"])
	for order in [["A", "B", "C"], ["B", "A", "C"], ["C", "B", "A"], ["A"], ["B"]]:
		var r := pooled(order, dishes)
		for name: String in order:
			var n: int = dishes[name]["n"]
			var at: int = r["bases"][name]
			var got: PackedFloat32Array = r["conc"].slice(at, at + n * n)
			ok(got == refs[name]["conc"], "D1 %s glucose equals alone, pool %s" % [name, order])
			var got2: PackedFloat32Array = r["conc2"].slice(at, at + n * n)
			if dishes[name]["acetate"]:
				ok(got2 == refs[name]["conc2"], "D1 %s acetate equals alone, pool %s" % [name, order])
			else:
				ok(got2 == PackedFloat32Array(dishes[name]["field"]["conc2"]), "D2 %s acetate untouched (flag off), pool %s" % [name, order])
		var pad_ok := true
		var claimed := {}
		for name: String in order:
			var n: int = dishes[name]["n"]
			for c in n * n:
				claimed[r["bases"][name] + c] = true
		for c in r["total"]:
			if not claimed.has(c) and (r["conc"][c] != r["conc_in"][c] or r["conc2"][c] != r["conc2_in"][c]):
				pad_ok = false
		ok(pad_ok, "D2 padding cells untouched, pool %s" % [order])
	print("POOL DIFFUSE CHECK %s" % ("OK" if fails == 0 else "FAILED (%d)" % fails))
	quit(0 if fails == 0 else 1)
