extends SceneTree
## The population at the bup limit, on the pooled world (the tool form of tests/sim/cap_test.gd, with the scenario and the limit given): a
## scenario (B by default) with a low limit, stepped as the game steps at x10,000 and 60 frames a second (166.7 s a frame: 8 steps of 20 s).
## Once the colony first comes within 2% of the limit, the count is read after every frame and compared with the limit: the pool trims a
## random share each step by the births it expects plus a margin (CAP_SIGMAS standard deviations), so the count stops a little short of the
## limit and is over it in very few frames.
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/cap_check.gd -- [limit] [hours] [max_share_over] [scenario]
## Prints the frames measured, the count minus the limit (mean, most over, most under), the share of frames over the limit, and whether that
## share is within max_share_over (default 0.01: under the limit in 99% of the frames).
##
## Expected, written before the first run [derived, as tests/sim/cap_test.gd]: "cap" with limit 600 for 8 hours: 20 founders reach 98% of
## 600 in about 3.3 h if food is not short (tests/sim/cap_test.gd's 200 units/mm2 held the colony at 159 bups, so this uses ten times as much); then the share of frames over the limit is at most 0.01.

const Tools := preload("res://tools/gpu/world_tools.gd")
const STEPS_PER_FRAME := 8


func _init() -> void:
	if not SimHarness.begin(self, "cap_check", "SimCore"):
		return
	var a := OS.get_cmdline_user_args()
	var limit := int(a[0]) if a.size() > 0 else 600
	var hours := float(a[1]) if a.size() > 1 else 8.0
	var max_share_over := float(a[2]) if a.size() > 2 else 0.01
	var scenario := a[3] if a.size() > 3 else "cap"
	SimConstants.apply()
	var s: Scenario
	if scenario == "cap":
		s = Scenario.small(20, 800.0).seed(71)
		s.limit = limit
		s.nutrient_density = 2000.0
	else:
		s = Tools.scenario(scenario, 1, limit)
	var h := SimHarness.make([s])
	var frames := int(hours * 3600.0 / (STEPS_PER_FRAME * SimHarness.DEFAULT_DELTA))
	var reached_frame := -1
	var over: Array[int] = []
	var peak := 0
	for f in frames:
		h.step(STEPS_PER_FRAME)
		var count: int = h.core.count(0)
		peak = maxi(peak, count)
		if reached_frame < 0 and count >= 0.98 * limit:
			reached_frame = f + 1
		if reached_frame >= 0:
			over.append(count - limit)
	var most := -1000000000
	var least := 1000000000
	var sum := 0
	var frames_over := 0
	for v in over:
		most = maxi(most, v)
		least = mini(least, v)
		sum += v
		frames_over += 1 if v > 0 else 0
	var share := float(frames_over) / maxf(over.size(), 1)
	var ok := over.size() > 0 and share <= max_share_over
	print("%s limit %d: peak count %d, reached at frame %d, %d frames measured; count - limit: mean %.1f, most over %d, most under %d; over the limit in %.2f%% of the frames (at most %.2f%%)" % [scenario, limit, peak, reached_frame, over.size(), float(sum) / maxf(over.size(), 1), most, least, 100.0 * share, 100.0 * max_share_over])
	print("CAP CHECK " + ("OK" if ok else "FAILED"))
	h.core.release()
	quit(0 if ok else 1)
