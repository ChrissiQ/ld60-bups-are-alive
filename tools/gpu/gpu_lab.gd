extends RefCounted
## What the windowed checks read from a `SimHarness` that a test does not: the figures of a SAMPLE line, a dish's nutrient by kind, its
## clouds, and the time of each kernel. Every function takes the harness and a dish's row.

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

