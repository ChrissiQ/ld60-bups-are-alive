extends SceneTree
## A whole run of the pooled world, one dish, one seed: the SAMPLE line of every sim-hour, to compare with tools/gpu/golden/ or with another
## run. Windowed, through the lock:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/validate_dynamics.gd -- gpu scenario seed [hours [step]]
##   mode: gpu (the only one; the processor's simulation is gone)   scenario: A (default dish until 1,000 bups) | B (3 mm dish, 20k cap, feed) |
##   C (90 mm dish, 100k cap, feed) | D-F, L, S, M (tools/gpu/world_tools.gd holds the table)
## An optional fourth argument is the number of sim-hours to run (0 or absent: the scenario's own), and an optional fifth the step's
## length in seconds, a number or a fraction ("100/60": the game's step at x100 and 60 frames a second; default 20). An hour must be a
## whole number of steps. Prints one SAMPLE line per sim-hour: mode scenario seed hour pop speed sense metabolism size harm energy nutrient,
## then OVERFLOWS and "VALIDATE DYNAMICS OK".
##   GPU_FROM_SOURCE=1 compiles the kernels from GpuKernels.all() at run time instead of using the imported shaders. NO_BUPS=1 runs the
##   dish without bups (what goes into the field: feed, bursts, sources).
##
## Expected values, written before the first run [derived]: scenario B for 6 hours at seed 1 prints six SAMPLE lines (hours 1-6) whose
## populations grow from 250 towards the limit 20,000 and stay at or under it, and OVERFLOWS 0; two runs of the same arguments print the
## same lines byte for byte (the run is deterministic per seed on one machine).

const Tools := preload("res://tools/gpu/world_tools.gd")
const Lab := preload("res://tools/gpu/gpu_lab.gd")
const BATCH := 9  ## steps a call of the core runs, as the game's batches did

var failed := false


func _hours(scenario: String) -> int:
	var extra := OS.get_cmdline_user_args()
	if extra.size() > 3 and int(extra[3]) > 0:
		return int(extra[3])
	return Tools.default_hours(scenario)


## The step's length (s): the optional fifth argument, a number or a fraction such as "1000/60".
func _step_seconds() -> float:
	var extra := OS.get_cmdline_user_args()
	if extra.size() <= 4:
		return SimHarness.DEFAULT_DELTA
	var text: String = extra[4]
	if text.contains("/"):
		return float(text.get_slice("/", 0)) / float(text.get_slice("/", 1))
	return float(text)


## DUMP_FIELD=<path>: the grid at each sample, appended as raw floats (n*n each), to compare the fields of two runs.
func _dump(d: Dictionary, s: Scenario) -> void:
	var path := OS.get_environment("DUMP_FIELD")
	if path == "":
		return
	var cells := int(pow(DishGrid.cells_across(s.radius, s.resolution), 2.0))
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	f.seek_end()
	f.store_buffer((d["field"] as PackedByteArray).slice(0, cells * 4))
	f.close()


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3 or a[0] != "gpu":
		print("usage: ... -s tools/gpu/validate_dynamics.gd -- gpu scenario seed [hours [step]]")
		quit(1)
		return
	if not SimHarness.begin(self, "validate_dynamics", "the pooled core (SimCore)"):
		return
	var mode := a[0]
	var scenario := a[1]
	var seed_value := int(a[2])
	SimConstants.apply()
	var s := Tools.scenario(scenario, seed_value)
	if OS.get_environment("NO_BUPS") == "1":
		s.bups = 0
	var step := _step_seconds()
	var hours := _hours(scenario)
	var per_hour := roundi(3600.0 / step)
	if absf(per_hour * step - 3600.0) > 1e-6 * 3600.0:
		print("FAIL an hour must be a whole number of steps (step %s s)" % str(step))
		quit(1)
		return
	var h := SimHarness.make([s], {"delta": step, "from_source": OS.get_environment("GPU_FROM_SOURCE") == "1"})
	var steps_done := 0
	var next_hour := 1
	while steps_done < hours * per_hour:
		var n := mini(BATCH, hours * per_hour - steps_done)
		h.step(n)
		steps_done += n
		if scenario == "A" and h.core.count(0) >= 1000:
			print("REACHED %s %s %d %.3f" % [mode, scenario, seed_value, steps_done * step / 3600.0])
			break
		if steps_done >= next_hour * per_hour:
			var got := Lab.sample(h, 0)
			Tools.sample_line(mode, scenario, seed_value, next_hour, got["count"], got["means"], got["energy"], got["nutrient"])
			_dump(h.dump(0), s)
			next_hour += 1
			if got["count"] == 0 and OS.get_environment("NO_BUPS") != "1":
				break
	var overflow := int(h.core.overflow())
	print("OVERFLOWS %s %s %d %d" % [mode, scenario, seed_value, overflow])
	failed = overflow != 0 or not TestUtil.failures.is_empty()
	print("VALIDATE DYNAMICS %s" % ("FAILED" if failed else "OK"))
	h.core.release()
	quit(1 if failed else 0)
