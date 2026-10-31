extends SceneTree
## The pooled world reproduces the old path's goldens.
##
## Expected values, written before the first run:
## - `tools/gpu/validate_dynamics.gd gpu <scenario> 1 6` run on the pooled world matches `tools/gpu/golden/` byte for byte, for the
##   scenarios that have a golden on this machine [derived: equality at one dish and one seed]. The goldens were
##   made on Apple Silicon with Metal: on another GPU the comparison is against a golden made there before the change.
## - this file compares only; it makes no golden. The goldens of the pooled path are made separately, and until then the test is a
##   stub. Enabled by a later change.
## Windowed only (GPU).

const GOLDEN_DIR := "res://tools/gpu/golden/"


func _init() -> void:
	if not SimHarness.begin(self, "goldens_test", "pooled goldens"):
		return
	var pooled: Array = Array(DirAccess.get_files_at(GOLDEN_DIR)).filter(func(f): return f.begins_with("dynamics_pooled_"))
	if pooled.is_empty():
		SimHarness.skip(self, "goldens_test", "no pooled goldens in %s yet" % GOLDEN_DIR, "a later change")
		return
	for f in pooled:
		var scenario: String = f.get_basename().split("_")[2]
		var old_name: String = f.replace("dynamics_pooled_", "dynamics_gpu_")
		var a := FileAccess.get_file_as_bytes(GOLDEN_DIR + old_name)
		var b := FileAccess.get_file_as_bytes(GOLDEN_DIR + f)
		TestUtil.show(not a.is_empty() and a == b, "scenario %s: the pooled golden equals the old golden byte for byte" % scenario)
	TestUtil.finish(self, "OK goldens_test")
