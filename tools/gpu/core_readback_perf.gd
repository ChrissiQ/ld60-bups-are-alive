extends SceneTree
## What a trash, a freeze and a pipette of a 1M dish cost the sim thread: SimCore's remove_dish, gather, freeze and
## pipette on a dish of 1,000,000 bups (90 mm, a 2M limit, one 18 s step run first so the record slots are sized for the limit, as in the
## game), each on a fresh load of the same state, wall clock around the call. Windowed, through the lock:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/core_readback_perf.gd -- [bups=1000000] [reps=3]
##
## Expected values, written before the first run [derived]: after one step at the 2M limit the record buffers hold about 2.33M slots
## (the cap 2.1M over the 0.9 fill), 261 MB each. A part of a big buffer read straight back stages the whole buffer: 5.0 ms measured for
## 1 MB of a 128 MB buffer against 0.74 ms copied out first, so, scaling with the buffer's size (an assumption), about 10 ms for any read
## of the records, however small. Before: the pipette's moved ids (a 2 mm disc, about 600 bups) about 10 ms of staging; a trash reads every
## record (112 MB) and turns each id into an int in script (1M calls: hundreds of ms); a freeze does both twice (gather, then remove_dish).
## After: the moved ids and a trash's ids come from a kernel that writes only the ids (8 bytes a bup) and are read through a right-sized
## copy, so the pipette's read is under 1 ms and a trash about the copy of 8 MB; a freeze reads the records once.
## Measured [M1 Pro, 1M bups, 356 MB record buffers, medians of 3]: before, trash 158.6 ms, gather 24.4, freeze 187.3, pipette 2 mm 161.6,
## pipette 30 mm 180.8; after, 4.2, 23.1, 29.0, 148.9, 149.3. What the pipette has left is its new dish's grid (DishGrid.make for a 90 mm
## dish of 100 cells, 140 ms in script), not a read.

const RADIUS := 90000.0

var bups := 1000000
var reps := 3


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("bups="):
			bups = int(a.substr(5))
		if a.begins_with("reps="):
			reps = int(a.substr(5))
	var blob := _blob()
	var core := SimCore.new()
	print("SimCore kernels' errors: %s" % [core.errors])
	var times := {"remove_dish (trash)": [], "gather": [], "freeze": [], "pipette 2 mm": [], "pipette 30 mm": []}
	var moved := {}
	for r in reps:
		for op: String in times:
			var row := core.load_dish(blob)
			core.run(1, 18.0)
			var t0 := Time.get_ticks_usec()
			match op:
				"remove_dish (trash)":
					var ids: PackedInt64Array = core.remove_dish(row)
					moved[op] = ids.size()
				"gather":
					var g: DishBlob = core.gather(row)
					moved[op] = g.count()
				"freeze":
					var g: DishBlob = core.freeze(row)
					moved[op] = g.count()
				"pipette 2 mm":
					var res: Dictionary = core.pipette(row, Vector2.ZERO, 2000.0)
					moved[op] = res.get("moved", -1)
				"pipette 30 mm":
					var res: Dictionary = core.pipette(row, Vector2.ZERO, 30000.0)
					moved[op] = res.get("moved", -1)
			times[op].append((Time.get_ticks_usec() - t0) / 1000.0)
			for rr: int in core.running_rows():
				core.remove_dish(rr)
		print("rep %d: record slots %d (%.0f MB a record buffer), overflow %d" % [r, core.arena.slot_cap, core.arena.slot_cap * GpuLayout.RECORD_BYTES / 1048576.0, core.overflow()])
	for op: String in times:
		var a: Array = times[op]
		a.sort()
		print("PERF %s: median %.1f ms, min %.1f, max %.1f (%d bups)" % [op, a[a.size() / 2], a[0], a[-1], moved[op]])
	core.release()
	quit(0)


func _blob() -> DishBlob:
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = RADIUS
	spec.resolution = 100
	spec.limit = 2000000
	spec.seed = 412556622
	spec.patch_seed = 412556622
	spec.nutrient_density = 32.0
	spec.feed_density = 20.0
	var grid := DishGrid.make(spec.radius, spec.resolution, spec.patchiness, spec.patch_seed)
	var founder := Scenario.small(1, RADIUS).founder_records(1).to_float32_array()
	var f := PackedFloat32Array(founder)
	while f.size() < bups * GpuLayout.RECORD_WORDS:
		f.append_array(f.slice(0, mini(f.size(), bups * GpuLayout.RECORD_WORDS - f.size())))
	var rng := RandomNumberGenerator.new()
	rng.seed = bups
	for i in bups:
		var o := i * GpuLayout.RECORD_WORDS
		var a := rng.randf() * TAU
		var r := RADIUS * 0.9 * sqrt(rng.randf())
		f[o + GpuLayout.R_X] = r * cos(a)
		f[o + GpuLayout.R_Y] = r * sin(a)
	var recs := f.to_byte_array()
	for i in bups:
		GpuLayout.set_id(recs, i, GpuLayout.make_id(1, i + 1))
	var blob := DishBlob.new()
	blob.spec = spec.to_dict()
	blob.records = recs
	blob.conc = grid.filled(spec.nutrient_density * Dish.CONCENTRATION_PER_DENSITY)
	blob.conc2 = PackedFloat32Array()
	blob.conc2.resize(grid.n * grid.n)
	blob.dplo = SimArena.zeros(grid.n * grid.n * 4)
	blob.dphi = SimArena.zeros(grid.n * grid.n * 4)
	var ds := SimArena.zeros(GpuLayout.DS_WORDS * 4)
	ds.encode_u32(GpuLayout.DS_NEXT_ID_LO * 4, GpuLayout.make_id(1, bups + 1) & 0xFFFFFFFF)
	ds.encode_u32(GpuLayout.DS_NEXT_ID_HI * 4, GpuLayout.make_id(1, bups + 1) >> 32)
	ds.encode_u32(GpuLayout.DS_SEED * 4, (spec.seed ^ (spec.seed >> 32)) & 0xFFFFFFFF)
	blob.dstate = ds
	return blob
