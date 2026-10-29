extends SceneTree
## Run: godot --headless --path . -s tests/gpu_step_budget_test.gd
## GpuStepBudget (how many steps a frame of the GPU path may take), headless, at 60 frames a second (a frame is 16,667 µs: slow past
## 19,167, fast under 17,500): the first call is held to what is asked; three slow frames in a row cut it by a fifth; a fast frame
## raises it by a tenth, at least one; a frame that does not follow the last call (a pause) changes nothing; a smaller ask is held to
## the most asked lately, decayed (0.97 a call).


func _init() -> void:
	var b := GpuStepBudget.new()
	var got := [b.allow(10, 1000, 1, 60.0)]
	for f in [2, 3, 4]:  # (30 ms frames)
		got.append(b.allow(10, 1000 + 30000 * (f - 1), f, 60.0))
	got.append(b.allow(10, 100000, 5, 60.0))  # (10 ms after the last: fast)
	got.append(b.allow(10, 105000, 7, 60.0))  # (a frame skipped)
	got.append(b.allow(3, 115000, 8, 60.0))  # (fast; 3 asked, the most asked lately 9.7)
	TestUtil.check(got == [10, 10, 10, 8, 9, 9, 9], "the budget's steps were %s, not [10, 10, 10, 8, 9, 9, 9]" % str(got))
	TestUtil.finish(self, "GPU STEP BUDGET TEST OK")
