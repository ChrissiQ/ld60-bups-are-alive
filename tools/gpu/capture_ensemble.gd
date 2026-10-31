extends SceneTree
## One run of the processor's simulation for the ensemble: scenario B, D, E or F of tools/gpu/world_tools.gd, one seed, 6 sim-hours
## of 20 s steps (the processor is the reference; outcomes are deterministic for a seed).
## godot --headless --path . -s tools/gpu/capture_ensemble.gd -- <scenario> <seed> [hours]   (tools/gpu/capture_ensemble.sh runs the set)
##
## Output: lines on stdout, the file format of tools/gpu/golden/ensemble_cpu_<scenario>.txt (the script's other lines are not kept):
##   ENS <scenario> <seed> <hour> <count> <speed> <sense> <metabolism> <size> <mass> <nutrient>
##     one line per sim-hour, hours 1 to 6. count: bups alive. speed, sense, metabolism, size: the means over the living bups of the
##     four genes. mass: their mean mass (the record's R_MASS). nutrient: the glucose in the field, in the units of `Field.total()`
##     (every number is printed with %.6f; a dish that has died out prints count 0 and zeros, and the lines after it are not printed).
##   GENE <scenario> <seed> <speed> <sense> <metabolism> <size>
##     at the last hour only: at most 500 living bups, every k-th of the export's order (k = count / 500 rounded up), the
##     four genes of each. The KS test of the gene distributions pools these over the seeds.

const Tools := preload("res://tools/gpu/world_tools.gd")
const GENE_SAMPLE := 500


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var scenario: String = a[0]
	var seed_value := int(a[1])
	var hours := int(a[2]) if a.size() > 2 else 6
	SimConstants.apply()
	var dish := TestUtil.dish_from(self, Tools.start_conditions(scenario), seed_value)
	Tools.place_sources(dish, scenario)
	var step := 20.0
	var per_hour := roundi(3600.0 / step)
	for hour in range(1, hours + 1):
		for s in per_hour:
			dish.step(step)
		var st: Dictionary = dish.population_stats()
		var records: PackedFloat32Array = dish.sim.export_state_bytes().to_float32_array()
		var n: int = records.size() / GpuLayout.RECORD_WORDS
		var mass := 0.0
		for i in n:
			mass += records[i * GpuLayout.RECORD_WORDS + GpuLayout.R_MASS]
		print("ENS %s %d %d %d %.6f %.6f %.6f %.6f %.6f %.6f" % [scenario, seed_value, hour, n, st["speed"], st["sense"], st["metabolism"], st["size"], mass / maxf(n, 1), dish.field.total()])
		if n == 0:
			break
		if hour == hours:
			var k := (n + GENE_SAMPLE - 1) / GENE_SAMPLE  # (every k-th, so the sample spans the export's order)
			for i in range(0, n, k):
				var o := i * GpuLayout.RECORD_WORDS + GpuLayout.R_SPEED
				print("GENE %s %d %.6f %.6f %.6f %.6f" % [scenario, seed_value, records[o], records[o + 1], records[o + 2], records[o + 3]])
	quit(0)
