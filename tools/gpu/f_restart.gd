extends SceneTree
## Scenario F restarted from ONE state on both backends, with the SAME bursts on both: the CPU dish of `seed` is run to `start` hours,
## then for each stream j the run goes on for `hours` more, on the CPU or the GPU. The plankton (where they appear and when they burst)
## come from a bup-free world dish whose random stream is set by (seed, j) alone, so stream j of the CPU and stream j of the GPU get
## exactly the same deposits at the same steps; the bups' own random numbers differ (set from (seed, j) on each backend). A paired
## comparison by stream then sees only what the backends do with the same food.
## godot --path . [--rendering-driver metal --position 6000,6000] -s tools/gpu/f_restart.gd -- mode seed start hours first_stream last_stream [variant]
##   mode cpu | gpu (gpu needs a window). variant (optional, the same on both backends): "base", "nodeath" (no chance death),
##   "nodiv" (no division: the mass to add is made huge), "noeat" (no uptake).
## Prints SAMPLE lines as tools/gpu/validate_dynamics.gd: SAMPLE mode R<seed><variant> stream hour pop speed sense metab size harm energy nutrient,
## and first a STATE line (digests of the start's bup records and grid, next id, bups) to check both backends start alike. The records'
## digests differ between a windowed and a headless run only by the founders' hue (word 16), which no dynamics read; DUMP_STATE=<path>
## writes the records to compare. Compare the two backends' outputs pair by pair (by tag and stream).

const Tools := preload("res://tools/gpu/world_tools.gd")
const STEP := 20.0
var SCENARIO: String = OS.get_environment("F_SCENARIO") if OS.get_environment("F_SCENARIO") != "" else "F"  ## the validate_dynamics.gd scenario (default F)


func _consts(variant: String) -> Dictionary:
	var c := SimConstants.build()
	match variant:
		"nodeath":
			c["death_rate"] = 0.0
		"nodiv":
			c["add_mass_factor"] = 1.0e9
		"noeat":
			c["uptake_per_size"] = 0.0
	return c


## A bup-free dish with the plankton, the clock and the bloom schedule of `from`, its random stream set by `world_seed`: its steps
## record (do not apply) the deposits the bursts make.
func _world(from: Dish, world_seed: int) -> Dish:
	var w := Dish.new()
	root.add_child(w)
	w.process_mode = Node.PROCESS_MODE_DISABLED
	w.set_seed(world_seed)
	w.strike(Tools.start_conditions(SCENARIO))
	w.clear_bups()
	w.feed_density = 0.0
	var zeros := []
	zeros.resize(w.field.get_size() * w.field.get_size())
	zeros.fill(0.0)
	w.field.load_values(zeros)
	w.field.set_recording(true)
	w.time = from.time
	w._bloom_due = from._bloom_due
	w._burst_clock = from._burst_clock
	w.plankton.clear()
	for p in from.plankton:
		w.plankton.append(Plankton.new(p.pos, p.born_at, p.burst_at, p.units, p.shape))
	return w


func _digest(bytes: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(bytes)
	return h.finish().hex_encode().substr(0, 16)


func _sample(mode: String, tag: String, stream: int, hour: float, recs: PackedFloat32Array, np: int, nutrient: float) -> void:
	var sums := [0.0, 0.0, 0.0, 0.0, 0.0]
	var energy := 0.0
	var gen := 0.0
	for i in np:
		gen += recs[i * GpuSim.STRIDE + 20]
		var o := i * GpuSim.STRIDE
		sums[0] += recs[o + 8]; sums[1] += recs[o + 9]; sums[2] += recs[o + 10]; sums[3] += recs[o + 11]; sums[4] += 1.0 - exp(-recs[o + 15])
		energy += recs[o + 5]
	for k in 5:
		sums[k] /= maxf(np, 1)
	print("GEN %s %s %d %.2f %.4f" % [mode, tag, stream, hour, gen / maxf(np, 1)])
	print("SAMPLE %s %s %d %.2f %d %.4f %.4f %.5f %.5f %.5f %.4f %.2f" % [mode, tag, stream, hour, np, sums[0], sums[1], sums[2], sums[3], sums[4], energy / maxf(np, 1), nutrient])


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var mode := a[0]
	var seed_value := int(a[1])
	var start := float(a[2])
	var hours := int(a[3])
	var first := int(a[4])
	var last := int(a[5])
	var variant: String = a[6] if a.size() > 6 else "base"
	SimConstants.apply()
	var base := Tools.make_dish(self, SCENARIO, seed_value)
	while base.time < start * 3600.0 - 1e-6:
		base.step(STEP)
	var consts := _consts(variant)
	BupSim.configure(consts)
	var state0: PackedByteArray = base.sim.export_state_bytes()
	var conc0: PackedFloat32Array = base.field.values()
	var next_id: int = base.sim.get_next_id()
	var n := base.field.get_size()
	var spacing := base.field.get_spacing()
	var area := spacing * spacing
	var tag := "R%d%s" % [seed_value, variant]
	if OS.get_environment("DUMP_STATE") != "":
		var df := FileAccess.open(OS.get_environment("DUMP_STATE"), FileAccess.WRITE)
		df.store_buffer(state0)
		df.close()
	print("STATE %s %s %s %d %d" % [tag, _digest(state0), _digest(conc0.to_byte_array()), next_id, state0.size() / GpuSim.RECORD_BYTES])  # (both backends must start from this same state)
	var per_hour := roundi(3600.0 / STEP)
	for stream in range(first, last + 1):
		var world_seed := seed_value * 1000003 + stream * 7919 + 17
		var bup_seed := seed_value * 1000033 + stream * 104729 + 5
		var w := _world(base, world_seed)
		if mode == "cpu":
			var d := Tools.make_dish(self, SCENARIO, bup_seed)
			d.clear_bups()
			d.sim.import_state_bytes(state0)  # (re-derives each bup's add_mass, yield, drag from the variant's constants)
			d.sim.set_next_id(next_id)
			d.field.load_values(Array(conc0))
			d.sim.set_seed(bup_seed)
			var t := base.time
			for s in hours * per_hour:
				w.step(STEP)
				var cells: PackedInt32Array = w.field.take_recorded_cells()
				var amounts: PackedFloat32Array = w.field.take_recorded_amounts()
				var pf: PackedFloat32Array = w.field.take_recorded_puffs()  # (x, y, mass, variance, cut: as clouds on the CPU field, whose handover test is the same)
				for j in pf.size() / 5:
					d.field.add_cloud(Vector2(pf[j * 5], pf[j * 5 + 1]), 2.0 * sqrt(pf[j * 5 + 3]), pf[j * 5 + 2])
				if cells.size() > 0:
					var vals: PackedFloat32Array = d.field.values()
					for k in cells.size():
						vals[cells[k]] += amounts[k]
					d.field.load_values(Array(vals))
				t += STEP
				d.sim.step(STEP, PackedVector2Array(), PackedFloat32Array(), 0.0, t)
				if (s + 1) % per_hour == 0:
					var recs: PackedFloat32Array = d.sim.export_state()
					_sample(mode, tag, stream, start + (s + 1) / per_hour, recs, recs.size() / GpuSim.STRIDE, d.field.total())
			d.queue_free()
		else:
			# (the records as the CPU holds them under the variant's constants: add_mass etc. re-derived)
			var holder := Tools.make_dish(self, SCENARIO, bup_seed)
			holder.clear_bups()
			holder.sim.import_state_bytes(state0)
			var recs0: PackedByteArray = holder.sim.export_state_bytes()
			holder.queue_free()
			var gpu := GpuSim.new(null, OS.get_environment("GPU_FROM_SOURCE") == "1")
			gpu.load_state(n, spacing, base.radius, conc0, base.field.export_owner(), recs0, consts, base.bup_limit, base.field.export_fill_weights(), 0.0, STEP, base.field.get_diffusion(), [], bup_seed, 1.0, next_id)
			var done := 0
			while done < hours * per_hour:
				var ranges := PackedInt32Array(); var puffs_all := PackedFloat32Array(); var cells_all := PackedInt32Array(); var amts_all := PackedFloat32Array()
				for st in 9:
					w.step(STEP)
					var pf: PackedFloat32Array = w.field.take_recorded_puffs()
					var cc: PackedInt32Array = w.field.take_recorded_cells()
					var aa: PackedFloat32Array = w.field.take_recorded_amounts()
					ranges.append_array(PackedInt32Array([puffs_all.size() / 6, pf.size() / 5, cells_all.size(), cc.size()]))
					for j in pf.size() / 5:
						puffs_all.append_array(PackedFloat32Array([pf[j * 5], pf[j * 5 + 1], pf[j * 5 + 2], pf[j * 5 + 3], pf[j * 5 + 4], 0.0]))
					cells_all.append_array(cc)
					amts_all.append_array(aa)
				gpu.run_steps(9, {"ranges": ranges, "puffs": puffs_all, "cells": cells_all, "amounts": amts_all})
				done += 9
				if done % per_hour == 0:
					var cnt := gpu.counts()
					var recs := gpu.read_bups().to_float32_array()
					var total := 0.0
					for v in gpu.read_conc():
						total += v
					total *= area
					for pf in gpu.read_puffs():
						total += pf[2]
					_sample(mode, tag, stream, start + done / per_hour, recs, cnt[0], total)
			gpu.release()
		w.queue_free()
	quit(0)
