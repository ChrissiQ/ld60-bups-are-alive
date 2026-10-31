extends SceneTree
## The performance gates against the pre-pool baseline `tools/gpu/baseline/perf_pre_pool.json`.
##
## Expected values, written before the first run:
## - Static part (runs headless): the baseline holds every key the gates read, so a missing key fails with its path [derived from the
##   gates]: scenarios A, B, C100, C48, D, E, F each with frame_ms_p95_mean_of_runs and achieved_speed_mean_of_runs; G "50", "200",
##   "1000" each with cpu and gpu and best_of_the_two; x1 by_bups "1000" and "100000" with runs[].share_frames_picture_changed.
## - The gate functions (`gate_*`), checked on synthetic numbers [derived from the gate text]:
##   E: p95 <= min(baseline E p95, 1.15 x display frame) and speed >= 9,500 (measured baseline: p95 10.18 ms, speed 9,994; display frame
##   8.33 ms [measured] so the cap is 9.58 ms). F: p95 and speed no worse than the baseline's (p95 64.66 ms, speed 309 [measured]) and
##   per-step cost at 2M <= 0.85 x the single-dish path's. A and B: p95 <= the baseline's (A: 32.0 ms [measured]). G: frame mean <= the best of the
##   two backends' + 1 SD, and speed >= 10,000. x1: payload advances in >= 99% of display frames.
## - The measurement bodies are stubs: gates E, F, G and x1, the 1M pipette, gates C and D and the 1,000-dish
##   interface are filled in by a later change. Gates A and B have no measurement yet.

const BASELINE := "res://tools/gpu/baseline/perf_pre_pool.json"
const DISPLAY_FRAME_MS := 8.333  ## ms [measured]: a frame of the 120 Hz display of the one machine the baseline was measured on (`environment.machine` in BASELINE)
const E_SPEED_FLOOR := 9500.0
const E_FRAME_SHARE := 1.15
const F_STEP_COST_SHARE := 0.85
const G_SPEED_FLOOR := 10000.0
const X1_SHARE := 0.99
const REQUIRED := [
	["scenarios", "A", "frame_ms_p95_mean_of_runs"], ["scenarios", "A", "achieved_speed_mean_of_runs"],
	["scenarios", "B", "frame_ms_p95_mean_of_runs"], ["scenarios", "B", "achieved_speed_mean_of_runs"],
	["scenarios", "C100", "frame_ms_p95_mean_of_runs"], ["scenarios", "C48", "frame_ms_p95_mean_of_runs"],
	["scenarios", "D", "frame_ms_p95_mean_of_runs"], ["scenarios", "E", "frame_ms_p95_mean_of_runs"],
	["scenarios", "E", "achieved_speed_mean_of_runs"], ["scenarios", "F", "frame_ms_p95_mean_of_runs"],
	["scenarios", "F", "achieved_speed_mean_of_runs"],
	["scenarios", "G", "50", "cpu", "frame_ms_mean_of_runs"], ["scenarios", "G", "50", "gpu", "frame_ms_mean_of_runs"],
	["scenarios", "G", "50", "best_of_the_two", "cpu_frame_ms_mean"], ["scenarios", "G", "50", "best_of_the_two", "gpu_frame_ms_mean"],
	["scenarios", "G", "200", "best_of_the_two", "cpu_frame_ms_mean"], ["scenarios", "G", "1000", "best_of_the_two", "gpu_frame_ms_mean"],
	["scenarios", "x1", "by_bups", "1000", "runs"], ["scenarios", "x1", "by_bups", "100000", "runs"],
]


func _init() -> void:
	var baseline := load_baseline()
	for path: Array in REQUIRED:
		TestUtil.show(lookup(baseline, path) != null, "baseline has %s" % "/".join(path))
	_gate_checks()
	for stub in [["gates E, F, G, x1 measurements", "a later change"], ["the 1M pipette measurement", "a later change"], ["gates C, D and the 1,000-dish interface", "a later change"]]:
		print("SKIP perf_gates_test: %s, enabled by %s" % stub)
	TestUtil.finish(self, "OK perf_gates_test (static part; measurements skipped)")


static func load_baseline() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE))
	return parsed if parsed is Dictionary else {}


## The value at `path` (keys down the dictionaries), or null when a key is missing.
static func lookup(d: Variant, path: Array) -> Variant:
	var at: Variant = d
	for k in path:
		if not (at is Dictionary) or not (at as Dictionary).has(k):
			return null
		at = at[k]
	return at


static func gate_e(p95_ms: float, speed: float, baseline_p95_ms: float) -> bool:
	return p95_ms <= minf(baseline_p95_ms, E_FRAME_SHARE * DISPLAY_FRAME_MS) and speed >= E_SPEED_FLOOR


static func gate_f(p95_ms: float, speed: float, step_cost: float, baseline_p95_ms: float, baseline_speed: float, baseline_step_cost: float) -> bool:
	return p95_ms <= baseline_p95_ms and speed >= baseline_speed and step_cost <= F_STEP_COST_SHARE * baseline_step_cost


static func gate_ab(p95_ms: float, baseline_p95_ms: float) -> bool:
	return p95_ms <= baseline_p95_ms


static func gate_g(frame_ms_mean: float, speed: float, best_cpu_ms: float, best_gpu_ms: float, sd_ms: float) -> bool:
	return frame_ms_mean <= minf(best_cpu_ms, best_gpu_ms) + sd_ms and speed >= G_SPEED_FLOOR


static func gate_x1(share_advanced: float) -> bool:
	return share_advanced >= X1_SHARE


func _gate_checks() -> void:
	var cap := minf(10.18, E_FRAME_SHARE * DISPLAY_FRAME_MS)
	TestUtil.show(gate_e(cap, 9500.0, 10.18), "gate E passes at its limits")
	TestUtil.show(not gate_e(cap + 0.01, 9994.0, 10.18), "gate E fails a p95 over the cap")
	TestUtil.show(not gate_e(9.0, 9499.0, 10.18), "gate E fails a speed under x9,500")
	TestUtil.show(gate_f(64.66, 309.0, 0.85, 64.66, 309.0, 1.0), "gate F passes at its limits")
	TestUtil.show(not gate_f(64.66, 309.0, 0.86, 64.66, 309.0, 1.0), "gate F fails a step cost over 0.85")
	TestUtil.show(not gate_f(64.7, 400.0, 0.5, 64.66, 309.0, 1.0), "gate F fails a p95 regression")
	TestUtil.show(gate_ab(32.0, 32.0) and not gate_ab(32.1, 32.0), "gates A and B: p95 against the baseline")
	TestUtil.show(gate_g(8.4, 10000.0, 8.33, 8.33, 0.1) and not gate_g(8.6, 10000.0, 8.33, 8.33, 0.1), "gate G: the best of the two plus 1 SD")
	TestUtil.show(not gate_g(8.3, 9999.0, 8.33, 8.33, 0.1), "gate G fails a speed under x10,000")
	TestUtil.show(gate_x1(0.99) and not gate_x1(0.9899), "gate x1: 99% of frames")
