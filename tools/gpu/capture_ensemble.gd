extends SceneTree
## One run of the pooled world for the ensemble: scenario B, D, E or F of tools/gpu/world_tools.gd, one seed, one dish, 6 sim-hours of
## 20 s steps (outcomes are deterministic per seed on one machine, not across machines).
## Windowed, through the lock: tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/capture_ensemble.gd -- <scenario> <seed> [hours]
## (tools/gpu/capture_ensemble.sh runs the set)
##
## Output: lines on stdout, the file format of tools/gpu/golden/ensemble_pooled_<scenario>.txt (the script's other lines are not kept) and
## of ensemble_cpu_<scenario>.txt, the earlier ensemble that tests/sim/ensemble_test.gd compares it with:
##   ENS <scenario> <seed> <hour> <count> <speed> <sense> <metabolism> <size> <mass> <nutrient>
##     one line per sim-hour, hours 1 to 6. count: bups alive. speed, sense, metabolism, size: the means over the living bups of the
##     four genes. mass: their mean mass (the record's R_MASS). nutrient: the glucose of the dish in energy (grid, deposits waiting and
##     clouds). Every number is printed with %.6f; a dish that has died out prints count 0, zero means and mass and the nutrient left, and the lines after it are not printed.
##   GENE <scenario> <seed> <speed> <sense> <metabolism> <size>
##     at the last hour only: at most 500 living bups, every k-th of the dump's order (k = count / 500 rounded up), the four genes of
##     each. The KS test of the gene distributions pools these over the seeds.

const Tools := preload("res://tools/gpu/world_tools.gd")
const Lab := preload("res://tools/gpu/gpu_lab.gd")
const GENE_SAMPLE := 500
const BATCH := 9


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 2:
		print("usage: ... -s tools/gpu/capture_ensemble.gd -- scenario seed [hours]")
		quit(1)
		return
	if not SimHarness.begin(self, "capture_ensemble", "SimCore"):
		return
	var scenario: String = a[0]
	var seed_value := int(a[1])
	var hours := int(a[2]) if a.size() > 2 else 6
	SimConstants.apply()
	var step := 20.0
	var per_hour := roundi(3600.0 / step)
	var h := SimHarness.make([Tools.scenario(scenario, seed_value)], {"delta": step})
	var done := 0
	for hour in range(1, hours + 1):
		while done < hour * per_hour:
			var n := mini(BATCH, hour * per_hour - done)
			h.step(n)
			done += n
		var got := Lab.sample(h, 0)
		var recs: PackedByteArray = h.dump(0)["records"]
		var count: int = recs.size() / GpuLayout.RECORD_BYTES
		var mass := 0.0
		for i in count:
			mass += recs.decode_float(i * GpuLayout.RECORD_BYTES + GpuLayout.R_MASS * 4)
		var m: Array = got["means"]
		print("ENS %s %d %d %d %.6f %.6f %.6f %.6f %.6f %.6f" % [scenario, seed_value, hour, count, m[0], m[1], m[2], m[3], mass / maxf(count, 1), got["nutrient"]])
		if count == 0:
			break
		if hour == hours:
			var k := (count + GENE_SAMPLE - 1) / GENE_SAMPLE
			for i in range(0, count, k):
				var o := i * GpuLayout.RECORD_BYTES + GpuLayout.R_SPEED * 4
				print("GENE %s %d %.6f %.6f %.6f %.6f" % [scenario, seed_value, recs.decode_float(o), recs.decode_float(o + 4), recs.decode_float(o + 8), recs.decode_float(o + 12)])
	var overflow := int(h.core.overflow())
	print("OVERFLOWS %s %d %d" % [scenario, seed_value, overflow])
	h.core.release()
	quit(1 if overflow != 0 or not TestUtil.failures.is_empty() else 0)
