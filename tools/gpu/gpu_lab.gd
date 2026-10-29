extends RefCounted
## What the windowed checks do with a GpuSim on a local RenderingDevice that the game never does: record by hand, submit and wait, time
## kernels, probe the clouds. It reaches into GpuSim's own recording helpers (`_set_step`, `_record_*`, `_delta`, `_bins` ...), which is why it
## lives here and not in the shipped class. Every function takes the GpuSim; none is for the main device (that frame submits itself).


## Submits what was recorded and waits for it.
static func submit(gpu: GpuSim) -> void:
	assert(not gpu.is_main, "submit/sync only on a local device: on the main device the frame submits what was recorded")
	gpu.rd.submit()
	gpu.rd.sync()


## Whole steps of the current length, as many as asked, in one submit, waiting for them.
static func run_steps(gpu: GpuSim, steps: int, events := {}) -> void:
	gpu.prepare_steps(steps, {"events": events})
	var cl := gpu.rd.compute_list_begin()
	gpu.record_steps(cl, steps)
	gpu.rd.compute_list_end()
	submit(gpu)


## The core of one step with the bups where they are (no feed, division or death): for comparing the pieces with the CPU's. The
## diffusion is `diffuse_pieces` pieces of k = `k_per_piece` (D dt / cell² each) here, not the coefficient given to load_state.
static func run(gpu: GpuSim, step_seconds: float, k_per_piece: float, diffuse_pieces: int, swim := true) -> void:
	gpu._set_step(step_seconds, swim)
	var cl := gpu.rd.compute_list_begin()
	gpu._record_diffusion(cl, k_per_piece * diffuse_pieces)
	gpu._record_after_diffusion(cl)
	gpu._record_bups(cl)
	gpu.rd.compute_list_end()
	submit(gpu)


## Time each kernel on its own (microseconds per dispatch, over `reps` dispatches in one submit; the state is not reset, so it is only for timing).
static func profile(gpu: GpuSim, reps := 20) -> Dictionary:
	gpu._set_step(gpu._delta)
	var n := gpu.n
	var capacity := gpu.capacity
	var puff_capacity := gpu.puff_capacity
	var out := {}
	var plan := {}
	if gpu._has_clouds:
		plan.merge({"puff_advance": puff_capacity, "dep_apply": n * n, "bin_clear": gpu._bins, "bin_count": puff_capacity, "bin_cursor": gpu._bins, "bin_scatter": puff_capacity, "bin_sort": gpu._bins, "puff_clear": puff_capacity, "puff_scale": puff_capacity, "puff_commit": puff_capacity})
	plan.merge({"feed": n * n, "diffuse_a": n * n, "snapshot": n * n, "clear": n * n, "swim": capacity, "demand": capacity, "cells": n * n, "apply": capacity, "ac_cells": n * n, "ac_apply": capacity, "life": capacity, "scan0_s": capacity, "compact": capacity * 7, "copy": capacity * 7})
	for kname in plan:
		var cl := gpu.rd.compute_list_begin()
		var t0 := Time.get_ticks_usec()
		for r in reps:
			gpu.dispatch(cl, kname, plan[kname], float(capacity), 0.1)
		gpu.rd.compute_list_end()
		submit(gpu)
		out[kname] = float(Time.get_ticks_usec() - t0) / reps
	out["diffuse_a"] = out["diffuse_a"] * maxi(2, 2 * ceili(gpu._k_total / 0.4))
	out["scans"] = out["scan0_s"] * 2.0 * 1.4  # (two scans: the first level is nearly all of each)
	return out


## Files the clouds by place (as at the start of a step).
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


## The clouds that are there: [x, y, mass, variance, cut] each.
static func puffs(gpu: GpuSim) -> Array:
	var clouds := gpu.read_clouds()
	var out := []
	for k in clouds.size() / 5:
		out.append(Array(clouds.slice(k * 5, k * 5 + 5)))
	return out
