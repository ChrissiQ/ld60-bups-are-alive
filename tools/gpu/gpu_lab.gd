extends RefCounted
## What the windowed checks read from a `SimHarness` that a test does not: the figures of a SAMPLE line, a dish's nutrient by kind, its
## clouds, and the time of each kernel. Every function takes the harness and a dish's row.
##
## `submit`, `build_index`, `probe` and `puffs_of_gpu` work on a lone `GpuSim` on a local device (queries_check.gd and pool_chain_check.gd
## still hold one); they go with `GpuSim`.

const CLOUD_WORDS := 8  ## per cloud in a dump: x, y, mass, variance, ...


## A dish's figures for a SAMPLE line, from one dump: {count, means (speed, sense, metabolism, size, harm), energy (the mean reserve),
## nutrient (the grid and the deposits waiting, the clouds), acetate}. The means come from the stats pass, the mean reserve and the
## nutrient from the records and the field.
static func sample(h: SimHarness, row: int) -> Dictionary:
	var d := h.dump(row)
	var s: Scenario = h.scenarios[row]
	var stats: PackedByteArray = d["stats"]
	var n := int(stats.decode_float(GpuLayout.ST_COUNT * 4))
	var means := []
	for g in GpuLayout.GENE_NAMES.size():
		means.append(stats.decode_float((GpuLayout.ST_SPEED + g) * 4) / maxf(n, 1))
	means.append(stats.decode_float(GpuLayout.ST_HARM * 4) / maxf(n, 1))
	var recs: PackedByteArray = d["records"]
	var energy := 0.0
	for i in recs.size() / GpuLayout.RECORD_BYTES:
		energy += recs.decode_float(i * GpuLayout.RECORD_BYTES + GpuLayout.R_ENERGY * 4)
	var stocks := nutrient(d, s)
	return {"count": n, "means": means, "energy": energy / maxf(n, 1), "nutrient": stocks["glucose"], "acetate": stocks["acetate"]}


## The glucose (cells, deposits waiting, clouds) and the acetate of a dish in energy, from its dump and its scenario.
static func nutrient(d: Dictionary, s: Scenario) -> Dictionary:
	var n := DishGrid.cells_across(s.radius, s.resolution)
	var area := pow(2.0 * s.radius / n, 2.0)
	var f: PackedByteArray = d["field"]
	var n2 := n * n
	var glucose := 0.0
	var acetate := 0.0
	var waiting := 0.0
	for c in n2:
		glucose += f.decode_float(c * 4)
		acetate += f.decode_float((n2 + c) * 4)
		waiting += f.decode_u32((3 * n2 + c) * 4) * 4096.0 + f.decode_u32((2 * n2 + c) * 4) / 1048576.0
	var clouds := 0.0
	for p in puffs(d):
		clouds += p[2]
	return {"glucose": glucose * area + waiting + clouds, "acetate": acetate * area}


## The clouds of a dump: [x, y, mass, variance, ...] each (CLOUD_WORDS words).
static func puffs(d: Dictionary) -> Array:
	var cf: PackedFloat32Array = (d["clouds"] as PackedByteArray).to_float32_array()
	var out := []
	for k in cf.size() / CLOUD_WORDS:
		out.append(Array(cf.slice(k * CLOUD_WORDS, (k + 1) * CLOUD_WORDS)))
	return out


## Microseconds of each kernel over `steps` steps of `delta` seconds, each dispatch in a submit of its own (`SimCore.profile_steps`): kernel
## name -> the mean over the dispatches. The world is advanced by the steps.
static func profile(h: SimHarness, steps := 20, delta := SimHarness.DEFAULT_DELTA) -> Dictionary:
	var raw: Dictionary = h.core.profile_steps(steps, delta)
	var out := {}
	for k in raw:
		var total := 0.0
		for us in raw[k]:
			total += us
		out[k] = total / maxf(raw[k].size(), 1)
	return out


## Submits what was recorded on a lone `GpuSim` and waits for it.
static func submit(gpu: GpuSim) -> void:
	assert(not gpu.is_main, "submit/sync only on a local device: on the main device the frame submits what was recorded")
	gpu.rd.submit()
	gpu.rd.sync()


## Files the clouds of a lone `GpuSim` by place (as at the start of a step).
static func build_index(gpu: GpuSim) -> void:
	gpu._has_clouds = true
	var cl := gpu.rd.compute_list_begin()
	gpu._record_cloud_index(cl)
	gpu.rd.compute_list_end()
	submit(gpu)


## x, y of each point in, [concentration, gradient x, gradient y, smallest sigma] of the clouds there out (after build_index).
static func probe(gpu: GpuSim, points: PackedFloat32Array) -> PackedFloat32Array:
	var m := points.size() / 2
	var query_bytes := points.to_byte_array()
	query_bytes.resize(maxi(query_bytes.size(), 16))  # (a buffer is at least 16 bytes)
	var zeros := PackedByteArray()
	zeros.resize(maxi(m * 16, 16))
	var query := gpu.rd.storage_buffer_create(query_bytes.size(), query_bytes)
	var result := gpu.rd.storage_buffer_create(zeros.size(), zeros)
	gpu.make_external_kernel("probe", ["P", "ENTD", "BINS", "BINC", query, result])
	var cl := gpu.rd.compute_list_begin()
	gpu.dispatch(cl, "probe", m, float(m))
	gpu.rd.compute_list_end()
	submit(gpu)
	var out := gpu.rd.buffer_get_data(result).to_float32_array()
	gpu.rd.free_rid(query)
	gpu.rd.free_rid(result)
	return out


## The clouds a lone `GpuSim` holds: [x, y, mass, variance, cut] each.
static func puffs_of_gpu(gpu: GpuSim) -> Array:
	var clouds := gpu.read_clouds()
	var out := []
	for k in clouds.size() / 5:
		out.append(Array(clouds.slice(k * 5, k * 5 + 5)))
	return out
