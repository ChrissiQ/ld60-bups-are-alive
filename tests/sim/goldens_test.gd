extends SceneTree
## The pooled world reproduces its own goldens.
##
## Expected values, written before the first run:
## - For every `tools/gpu/golden/dynamics_pooled_<scenario>_seed1_6h.txt`, one dish of that scenario at seed 1 run for 6 sim-hours in steps
##   of 20 s (what `tools/gpu/validate_dynamics.gd gpu <scenario> 1 6` does) gives the same six SAMPLE lines, byte for byte [derived: the
##   run is deterministic per seed on one machine; the check asks for equality at one dish and one seed].
## - The goldens were made on Apple Silicon with Metal. On another GPU or driver the comparison is against a golden made there before the
##   change, so a mismatch on a new machine is a reason to regenerate the goldens there, not a failure of the code.
## Windowed only (GPU).

const Tools := preload("res://tools/gpu/world_tools.gd")
const Lab := preload("res://tools/gpu/gpu_lab.gd")
const GOLDEN_DIR := "res://tools/gpu/golden/"
const PREFIX := "dynamics_pooled_"
const BATCH := 9  ## steps a call of the core runs, as validate_dynamics.gd does
const STEP := 20.0
const HOURS := 6


func _init() -> void:
	if not SimHarness.begin(self, "goldens_test", "the pooled goldens"):
		return
	var files: Array = Array(DirAccess.get_files_at(GOLDEN_DIR)).filter(func(f): return f.begins_with(PREFIX) and f.ends_with(".txt"))
	files.sort()
	if files.is_empty():
		SimHarness.skip(self, "goldens_test", "no %s*.txt in %s" % [PREFIX, GOLDEN_DIR], "the pooled goldens")
		return
	SimConstants.apply()
	for f in files:
		var scenario: String = f.get_basename().split("_")[2]
		var golden := FileAccess.get_file_as_string(GOLDEN_DIR + f)
		var got := _run(scenario)
		TestUtil.show(not golden.is_empty() and got == golden,"scenario %s: the run equals %s byte for byte" % [scenario, f])
	TestUtil.finish(self, "OK goldens_test")


## The SAMPLE lines of a run, as validate_dynamics.gd prints them.
func _run(scenario: String) -> String:
	var per_hour := roundi(3600.0 / STEP)
	var h := SimHarness.make([Tools.scenario(scenario, 1)], {"delta": STEP})
	var text := ""
	var done := 0
	for hour in range(1, HOURS + 1):
		while done < hour * per_hour:
			var n := mini(BATCH, hour * per_hour - done)
			h.step(n)
			done += n
		var got := Lab.sample(h, 0)
		text += Tools.sample_text("gpu", scenario, 1, hour, got["count"], got["means"], got["energy"], got["nutrient"]) + "\n"
		if got["count"] == 0:
			break
	h.core.release()
	return text
