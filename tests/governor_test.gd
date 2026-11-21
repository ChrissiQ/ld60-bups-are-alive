extends SceneTree
## Run: godot --headless --path . -s tests/governor_test.gd
## The Governor with a fake clock: the step length from the speed alone, the time owed,
## the steps of an iteration within T_ITER and the caller's bounds, the duty, the history samples.
##
## Expected values [derived from the Governor's constants: MAX_STEP 20 s, 120 steps a simulated
## second, T_ITER 50 ms (placeholder), frames capped at 0.1 s, owed time at most 2 iterations, duty -10% after 3 frames over 1.15 x the
## display frame and +5% for a frame within 1.05 x, EMA weight 0.25]:
##  - step_length: x1 = 1/120 s, x600 = 5 s, x2,400 = 20 s, x10,000 = 20 s, x0 = 0; and the governor's delta() after a frame of 1/60 s
##    and after one of 1/120 s is the same value at x1, x600 and x10,000.
##  - owed: at x1, one frame of 1/120 s owes 1 step; one of 1/240 s owes 0, two owe 1. Fed (N + 0.5) steps' time (N = 240) as N frames of
##    1/120 s and a half frame, or as 2N + 1 frames of 1/240 s, stepping whatever is owed after each frame with a fast step (0.5 ms), both
##    run exactly N steps. A frame of 1 s counts as 0.1 s (with a 0.5 ms step, so the cap of 2 x 50 steps of 1/120 s is above it). Paused, nothing is owed.
##  - steps: a step of 5 ms gives 10 steps an iteration (10 x 5 = 50 ms = T_ITER) with 100 owed; 60 ms gives 1; 0.001 ms gives 1,024
##    (MAX_STEPS); with room 3 it is 3, with samples 2 it is 2; nothing owed gives 0.
##  - the cap: at x10,000 with a 5 ms step (10 steps an iteration of 20 s), frames of 0.1 s (1,000 s each) owe at most 2 x 10 x 20 = 400 s;
##    after 3 such frames 2,600 s were dropped.
##  - advanced: from the initial cost (T_ITER, 50 ms), an iteration of 10 steps in 50 ms makes it 50 + 0.25 x (5 - 50) = 38.75 ms; the clock moves
##    10 x delta.
##  - duty on a display of 8.333 ms: 2 frames of 10 ms leave it 1.0; a third makes it 0.9; a frame of 8.5 ms then makes it 0.945; rest
##    after 10 ms busy at 0.9 is 1.111 ms; at 1.0 it is 0; it never goes under 0.1.
##  - pacing, on a display of 1/120 s at x1: 1,200 frames whose ends sit 1/120 s apart plus a jitter drawn in +-1.5 ms (each frame's length
##    the difference of two ends) each run exactly one step, and the time owed in all is the real time within half a display frame
##    [derived: what is left over after a frame is its end's jitter less the first's, within 3 ms, under half a frame (4.17 ms)]; the
##    same frames with no display known leave some frames with no step [derived: the owed fraction starts on a whole step, so a frame
##    shorter than the one before steps 0]; 600 frames 0.8% longer than the display's run within one step of the real time's steps and
##    owe it within half a display frame [derived: a frame of two display frames every 63].
##  - the split, on a display of 8.333 ms (a frame owes 1 step at x1: round(120 x 0.008333)), step cost (slow mean) 6 ms: 1 owed gives 1; 2 owed
##    give 1 (the iteration takes one frame's worth); 3 give 1; 4 give 4 (past SPLIT_OWED_MOST = 3, merged: T_ITER / 6 ms = 4 allows 4);
##    a 9 ms step (a 9 ms mean, over 8.333 ms) with 2 owed gives 2 (merged); a 6 ms mean at duty 0.7 (6 / 0.7 = 8.6 ms, over a frame) gives 2; at x10,000
##    (steps of 20 s) 2 owed with 6 ms steps give 2; on a display of 16.667 ms (a frame owes 2) 4 owed give 2, 2 owed give 2, 7 owed give 7
##    (7 > 3 x 2: merged, within T_ITER / 6 = 8: 7); with no display known 2 owed give 2.
##  - a fixed cost in the iteration (an iteration takes 20 ms + k x 8 ms: the fixed cost of Direct3D 12 with a low GPU clock, a step of a 2M-bup dish, plus 23 ms an iteration
##    outside the steps), x10,000 at 60 fps, started as the game starts (step cost 50 ms, so k = 1): [derived: run(1) = 28 ms is what
##    the old rule charged a step, 50 / 28 = 1, and k = 1 reads 28 ms for ever (checked in the test); the new rule's probe, after PROBE_EVERY
##    iterations of one k, runs 2 x T / cost = 2 steps (50 / 28 is 1, one more), the slope between k = 1 and 2 is 8 ms (exact: no noise),
##    and k = floor(50 / 8) = 6 from then on]: the slope is 8 ms (+-5%), the fixed cost 20 ms (+-10%), k is 6, no run longer than
##    20 + 2 x 50 = 120 ms (the probe's own bound; a steady iteration is 20 + 6 x 8 = 68 ms), and with +-3 ms noise on the run time the step estimate stays within 2 ms of 8
##    ms and k within 2 to 12 (a probe halves k). The cost of a step rising from 2 to 8 ms (the dish growing), the estimate follows to 8 ms within
##    1 ms by the end; a 100k dish with a 20 ms fixed cost and a 1.5 ms step settles at the slope 1.5 ms and k of 10 or more; a cost taken
##    too high at k = 1 comes down, and noise does not hold k at 1 (`_latched_high`).
##  - history samples (interval 120 s): from 0 with 10 steps of 20 s, one sample after step index 5; from 100 s with 3 steps, after index 0;
##    at most 16 an iteration: from 0, steps of 20 s allow 101 steps (the 17th sample would fall after step index 101).

const EPS := 1e-9


func _init() -> void:
	_step_length()
	_owed()
	_steps()
	_cap()
	_split()
	_advanced()
	_duty()
	_samples()
	_pacing()
	_fixed_cost()
	_fill_spike()
	_latched_high()
	TestUtil.finish(self, "GOVERNOR TEST OK")


func _step_length() -> void:
	TestUtil.check(is_equal_approx(Governor.step_length(1.0), 1.0 / 120.0), "x1: 1/120 s (got %f)" % Governor.step_length(1.0))
	TestUtil.check(is_equal_approx(Governor.step_length(600.0), 5.0), "x600: 5 s")
	TestUtil.check(is_equal_approx(Governor.step_length(10000.0), 20.0), "x10,000: 20 s")
	TestUtil.check(is_equal_approx(Governor.step_length(2400.0), 20.0), "x2,400: 20 s")
	TestUtil.check(Governor.step_length(0.0) == 0.0, "x0: 0")
	for speed in [1.0, 600.0, 10000.0]:
		var a := Governor.new()
		a.set_time(speed, false, 1.0 / 60.0)
		var b := Governor.new()
		b.set_time(speed, false, 1.0 / 120.0)
		TestUtil.check(a.delta() == b.delta() and a.delta() == Governor.step_length(speed), "x%d: the same step with frames of 1/60 and 1/120 s" % int(speed))


func _owed() -> void:
	var g := Governor.new()
	g.set_time(1.0, false, 1.0 / 120.0)
	TestUtil.check(g.owed_steps() == 1, "x1: a frame of 1/120 s owes a step (got %d)" % g.owed_steps())
	g = Governor.new()
	g.set_time(1.0, false, 1.0 / 240.0)
	TestUtil.check(g.owed_steps() == 0, "x1: a frame of 1/240 s owes no whole step")
	g.set_time(1.0, false, 1.0 / 240.0)
	TestUtil.check(g.owed_steps() == 1, "x1: two frames of 1/240 s owe a step")
	const N := 240
	var at120 := _run_frames(1.0 / 120.0, N, 0.5)
	var at240 := _run_frames(1.0 / 240.0, 2 * N, 1.0)
	TestUtil.check(at120 == N and at240 == N, "(N + 0.5) steps' time in frames of 1/120 and of 1/240 s run N = %d steps (got %d, %d)" % [N, at120, at240])
	g = Governor.new()
	g.step_ms_ema = 0.5
	g.set_time(1.0, false, 1.0)
	TestUtil.check(is_equal_approx(g.owed(), 0.1), "a frame of 1 s counts as 0.1 s (owed %f)" % g.owed())
	g.set_time(1.0, true, 1.0 / 120.0)
	TestUtil.check(g.owed() == 0.0 and g.owed_steps() == 0, "paused: nothing owed")


## Feeds `frames` frames of `dt` and then one of `last_fraction` x dt at x1, running what is owed after each frame (a step of 0.5 ms):
## the steps run.
func _run_frames(dt: float, frames: int, last_fraction: float) -> int:
	var g := Governor.new()
	g.step_ms_ema = 0.5
	var ran := 0
	for f in frames + 1:
		g.set_time(1.0, false, dt if f < frames else dt * last_fraction)
		var k := g.steps()
		if k > 0:
			g.advanced(k, g.delta(), 0.5 * k)
			ran += k
	return ran


func _steps() -> void:
	var g := Governor.new()
	g.set_time(1.0, false, 0.0)
	TestUtil.check(g.steps() == 0, "nothing owed: 0 steps")
	g.target = 100.0 * g.delta() + 1e-6
	g.step_ms_ema = 5.0
	TestUtil.check(g.steps() == 10, "a 5 ms step: 10 steps hold T_ITER (got %d)" % g.steps())
	g.step_ms_ema = 60.0
	TestUtil.check(g.steps() == 1, "a 60 ms step: 1 step (got %d)" % g.steps())
	g.step_ms_ema = 0.001
	g.target = 5000.0 * g.delta()
	TestUtil.check(g.steps() == Governor.MAX_STEPS, "a step of 1 µs: MAX_STEPS (got %d)" % g.steps())
	TestUtil.check(g.steps(3) == 3, "room for 3 steps: 3")
	TestUtil.check(g.steps(Governor.MAX_STEPS, 2) == 2, "samples allow 2 steps: 2")


func _split() -> void:
	var g := Governor.new()
	g.display_ms = 1000.0 / 120.0
	g.step_ms_mean = 6.0
	g.step_ms_ema = 6.0
	g.speed = 1.0
	g.paused = false
	for pair in [[1, 1], [2, 1], [3, 1], [4, 4]]:
		g.target = float(pair[0]) * g.delta() + 1e-6
		TestUtil.check(g.steps() == pair[1], "split: %d owed at 6 ms give %d (got %d)" % [pair[0], pair[1], g.steps()])
	g.step_ms_mean = 9.0
	g.step_ms_ema = 9.0
	g.target = 2.0 * g.delta() + 1e-6
	TestUtil.check(g.steps() == 2, "split: 2 owed at 9 ms (not keeping up) merge (got %d)" % g.steps())
	g.step_ms_mean = 6.0
	g.step_ms_ema = 6.0
	g.duty = 0.7
	TestUtil.check(g.steps() == 2, "split: 2 owed at 6 ms and duty 0.7 merge (got %d)" % g.steps())
	var fast := Governor.new()
	fast.display_ms = 1000.0 / 120.0
	fast.step_ms_mean = 6.0
	fast.step_ms_ema = 6.0
	fast.speed = 10000.0
	fast.paused = false
	fast.target = 2.0 * fast.delta() + 1e-6
	TestUtil.check(fast.steps() == 2, "split: x10,000 is never split (got %d)" % fast.steps())
	var slow := Governor.new()
	slow.display_ms = 1000.0 / 60.0
	slow.step_ms_mean = 6.0
	slow.step_ms_ema = 6.0
	slow.speed = 1.0
	slow.paused = false
	for pair in [[2, 2], [4, 2], [7, 7]]:
		slow.target = float(pair[0]) * slow.delta() + 1e-6
		TestUtil.check(slow.steps() == pair[1], "split: 60 Hz, %d owed give %d (got %d)" % [pair[0], pair[1], slow.steps()])
	var none := Governor.new()
	none.step_ms_mean = 6.0
	none.step_ms_ema = 6.0
	none.speed = 1.0
	none.paused = false
	none.target = 2.0 * none.delta() + 1e-6
	TestUtil.check(none.steps() == 2, "split: no display known, 2 owed give 2 (got %d)" % none.steps())


func _cap() -> void:
	var g := Governor.new()
	g.step_ms_ema = 5.0
	for i in 3:
		g.set_time(10000.0, false, 0.1)
	TestUtil.check(is_equal_approx(g.owed(), 400.0), "x10,000 with 10 steps an iteration: at most 400 s owed (got %f)" % g.owed())
	TestUtil.check(is_equal_approx(g.dropped, 2600.0), "x10,000: 2,600 s dropped over 3 frames of 0.1 s (got %f)" % g.dropped)


func _advanced() -> void:
	var g := Governor.new()
	g.set_time(10000.0, false, 0.1)
	var d := g.delta()
	g.advanced(10, d, 50.0)
	TestUtil.check(is_equal_approx(g.step_ms_ema, 38.75), "the step's cost: 50 + 0.25 x (5 - 50) = 38.75 ms (got %f)" % g.step_ms_ema)
	TestUtil.check(is_equal_approx(g.clock, 10.0 * d) and g.steps_total == 10, "the clock moved 10 steps")


func _duty() -> void:
	var g := Governor.new()
	var display := 8.333
	g.frame(10.0, display)
	g.frame(10.0, display)
	TestUtil.check(g.duty == 1.0, "two slow frames leave the duty at 1.0")
	g.frame(10.0, display)
	TestUtil.check(is_equal_approx(g.duty, 0.9), "a third slow frame: 0.9 (got %f)" % g.duty)
	TestUtil.check(is_equal_approx(g.rest_ms(10.0), 10.0 * (1.0 / 0.9 - 1.0)), "rest after 10 ms busy at 0.9: 1.111 ms (got %f)" % g.rest_ms(10.0))
	g.frame(8.5, display)
	TestUtil.check(is_equal_approx(g.duty, 0.945), "a frame within 1.05: x1.05 (got %f)" % g.duty)
	var h := Governor.new()
	TestUtil.check(h.rest_ms(10.0) == 0.0, "no rest at duty 1.0")
	for i in 300:
		h.frame(100.0, display)
	TestUtil.check(is_equal_approx(h.duty, Governor.DUTY_MIN), "the duty stops at 0.1 (got %f)" % h.duty)


func _samples() -> void:
	var a := Governor.sample_steps(0.0, 10, 20.0, 120.0, 16)
	TestUtil.check(a == PackedInt32Array([5]), "from 0, 10 steps of 20 s: a sample after step index 5 (got %s)" % [a])
	var b := Governor.sample_steps(100.0, 3, 20.0, 120.0, 16)
	TestUtil.check(b == PackedInt32Array([0]), "from 100 s: after step index 0 (got %s)" % [b])
	var most := Governor.steps_for_samples(0.0, 20.0, 120.0, 16, Governor.MAX_STEPS)
	TestUtil.check(most == 101, "16 samples allow 101 steps of 20 s from 0 (got %d)" % most)
	TestUtil.check(Governor.sample_steps(0.0, most, 20.0, 120.0, 16).size() == 16, "and those steps hold 16 samples")


func _pacing() -> void:
	const FRAMES := 1200
	var period := 1.0 / 120.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var g := Governor.new()
	g.step_ms_ema = 0.5
	var plain := Governor.new()
	plain.step_ms_ema = 0.5
	var last_jitter := 0.0
	var real := 0.0
	var single := 0
	var plain_none := 0
	for f in FRAMES:
		var jitter := rng.randf_range(-0.0015, 0.0015)
		var dt := period + jitter - last_jitter
		last_jitter = jitter
		real += dt
		if _paced_frame(g, dt, period) == 1:
			single += 1
		plain.set_time(1.0, false, dt)
		var kp := plain.steps()
		if kp == 0:
			plain_none += 1
		plain.advanced(kp, plain.delta(), 0.5 * kp)
	TestUtil.check(single == FRAMES, "pacing: %d jittered frames of a 1/120 s display each run one step (%d did)" % [FRAMES, single])
	TestUtil.check(absf(g.target - real) <= 0.5 * period, "pacing: the time owed is the real time within half a frame (off by %.3f ms)" % ((g.target - real) * 1000.0))
	TestUtil.check(plain_none > 0, "without a display known, some of the same frames run no step (%d)" % plain_none)
	var slow := Governor.new()
	slow.step_ms_ema = 0.5
	var ran := 0
	real = 0.0
	for f in 600:
		var dt := 1.008 * period
		real += dt
		ran += _paced_frame(slow, dt, period)
	TestUtil.check(absf(slow.target - real) <= 0.5 * period and absi(ran - int(floor(real / period))) <= 1, "pacing: frames 0.8%% long owe the real time within half a frame (off by %.3f ms; %d steps for %.2f)" % [(slow.target - real) * 1000.0, ran, real / period])


## One frame of `dt` on a display of `period` (s) at x1, as the sim thread hands it to the governor; runs what is owed and returns the steps.
func _paced_frame(g: Governor, dt: float, period: float) -> int:
	g.frame(dt * 1000.0, period * 1000.0)
	g.set_time(1.0, false, dt)
	var k := g.steps()
	g.advanced(k, g.delta(), 0.5 * k)
	return k


## An iteration that costs `fixed + k x per_step` ms (plus `outside` ms the governor does not see), x10,000 at 60 fps, from the start's state. Runs
## `iterations` iterations on a fake clock and returns {ks, runs, g}. `step_at` gives the per-step cost by iteration; `noise` is the half-width
## of a uniform error on the run time.
func _simulate(iterations: int, fixed: float, step_at: Callable, outside: float, noise: float, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var g := Governor.new()
	g.frame(1000.0 / 60.0, 1000.0 / 60.0)
	var ks: Array[int] = []
	var runs: Array[float] = []
	var pending := 0.0  ## ms of real time not yet given to the governor as frames
	for i in iterations:
		while pending >= 1000.0 / 60.0:
			g.set_time(10000.0, false, 1.0 / 60.0)
			pending -= 1000.0 / 60.0
		var k := g.steps()
		if k == 0:
			pending += 1000.0 / 60.0
			continue
		var run: float = fixed + k * float(step_at.call(i)) + rng.randf_range(-noise, noise)
		g.advanced(k, g.delta(), run)
		ks.append(k)
		runs.append(run)
		pending += run + outside
	return {"ks": ks, "runs": runs, "g": g}


func _fixed_cost() -> void:
	var flat := func(_i: int) -> float: return 8.0
	# the rule that charged the fixed cost to the steps (cost of a step = an iteration's time over its steps), here with fixed 20 ms and 8 ms a step:
	# T_ITER / 28 = 1, and k = 1 reads 28 ms a step for ever
	var old_ema := Governor.T_ITER_MS
	var old_k := 1
	for i in 100:
		old_k = maxi(1, int(floor(Governor.T_ITER_MS / old_ema)))
		old_ema += Governor.EMA_WEIGHT * ((20.0 + old_k * 8.0) / old_k - old_ema)
	TestUtil.check(old_k == 1, "the old rule locks at one step with a 20 ms fixed cost and 8 ms a step (k %d)" % old_k)
	var r := _simulate(400, 20.0, flat, 23.0, 0.0, 1)
	var g: Governor = r["g"]
	var ks: Array = r["ks"]
	var runs: Array = r["runs"]
	TestUtil.check(absf(g.step_ms_ema - 8.0) <= 0.4 and absf(g.fixed_ms - 20.0) <= 2.0, "fixed cost: slope %.2f ms, fixed %.2f ms (8 and 20)" % [g.step_ms_ema, g.fixed_ms])
	var settled := ks.slice(60)
	var most := 0
	var longest := 0.0
	for k: int in settled:
		most = maxi(most, k)
	for t: float in runs.slice(60):
		longest = maxf(longest, t)
	TestUtil.check(ks[ks.size() / 2] == 6 and ks[ks.size() - 1] == 6, "fixed cost: k = floor(T_ITER / 8 ms) = 6 once learned (got %d, %d)" % [ks[ks.size() / 2], ks[ks.size() - 1]])
	TestUtil.check(longest <= 20.0 + 2.0 * Governor.T_ITER_MS + 1e-6, "fixed cost: no iteration's run longer than fixed + 2 x T_ITER (got %.1f ms)" % longest)
	var noisy := _simulate(500, 20.0, flat, 23.0, 3.0, 2)
	var gn: Governor = noisy["g"]
	var lo := 99
	var hi := 0
	for k: int in (noisy["ks"] as Array).slice(100):
		lo = mini(lo, k)
		hi = maxi(hi, k)
	TestUtil.check(absf(gn.step_ms_ema - 8.0) <= 2.0 and lo >= 2 and hi <= 12, "fixed cost with +-3 ms noise: slope %.2f ms, k in %d to %d" % [gn.step_ms_ema, lo, hi])
	var grow := func(i: int) -> float: return 2.0 + 6.0 * clampf(float(i) / 100.0, 0.0, 1.0)
	var rg := _simulate(300, 20.0, grow, 23.0, 0.0, 3)
	var gg: Governor = rg["g"]
	TestUtil.check(absf(gg.step_ms_ema - 8.0) <= 1.0, "fixed cost, a step growing from 2 to 8 ms: slope %.2f ms" % gg.step_ms_ema)
	# a probe is one iteration: from a known slope (8.69 ms, from a noisy first pair) with k at 2 for a long time (the probe's own k), the next
	# iteration after the probe runs floor(T_ITER / slope) = 5 again [derived: 50 / 8.69 = 5.75]
	var stuck := Governor.new()
	stuck.slope_known = true
	stuck.step_ms_ema = 8.69
	stuck.fixed_ms = 20.0
	stuck._ref_k = 2
	stuck._ref_run = 36.0
	stuck._since_pair = Governor.PROBE_EVERY
	stuck.speed = 10000.0
	stuck.paused = false
	var seen: Array[int] = []
	for i in 40:
		stuck.target = stuck.clock + 100.0 * stuck.delta()
		var k := stuck.steps()
		seen.append(k)
		stuck.advanced(k, stuck.delta(), 20.0 + 8.0 * k)
	TestUtil.check(seen[0] == 2 and seen[1] == 5 and seen.slice(2).count(2) <= 3, "a probe is one iteration, not a state: k %s" % [seen])
	var cheap := func(_i: int) -> float: return 1.5
	var rc := _simulate(300, 20.0, cheap, 10.0, 0.0, 4)
	var gc: Governor = rc["g"]
	TestUtil.check(absf(gc.step_ms_ema - 1.5) <= 0.2 and _mean_tail(rc["ks"], 60) >= 10.0, "fixed cost 20 ms, step 1.5 ms (100k bups, Direct3D 12): slope %.2f, mean k %.1f" % [gc.step_ms_ema, _mean_tail(rc["ks"], 60)])


## A dish filling: the cost of a step rises from 0.5 to 14 ms over 40 iterations (the population growing) while k is at what the cheap steps allowed.
## The cost known between two pairs is stale while the dish fills; an iteration must not run at it for as long as the next pair takes (up to 16
## iterations).
func _fill_spike() -> void:
	var fill := func(i: int) -> float: return 0.5 + 13.5 * clampf(float(i - 30) / 40.0, 0.0, 1.0)
	var r := _simulate(160, 15.0, fill, 0.0, 0.0, 5)
	var runs: Array = r["runs"]
	var longest := 0.0
	for t: float in runs.slice(30):
		longest = maxf(longest, t)
	var bound := 15.0 + 2.0 * Governor.T_ITER_MS
	TestUtil.check(longest <= bound, "a dish filling (a step from 0.5 to 14 ms in 40 iterations): no iteration longer than fixed + 2 x T_ITER = %.0f ms (got %.0f ms)" % [bound, longest])
	var g: Governor = r["g"]
	TestUtil.check(absf(g.step_ms_ema - 14.0) <= 2.0, "after a dish has filled the cost of a step is the full one: %.2f ms (14)" % g.step_ms_ema)



## A cost taken too high (one slow iteration while a dish filled set it to 57 ms a step, so k = floor(50 / 57) = 1) while a step really costs
## 22 ms over a fixed 12 ms. At k = 1 the probe runs 2 steps, the pair (1, 2) gives the slope 22 ms exactly, and the cost moves a quarter of
## the way to it (SLOPE_WEIGHT 0.5 x the relative difference 0.5) once a pair, every PROBE_EVERY + 1 iterations [derived: 35 x 0.75^n is
## under 0.5 ms after 15 pairs, 255 iterations; from 25 ms down k is 2 and the probes go to 1, with the same weight]: after 300 iterations
## the cost is within 0.5 ms of 22, the fixed cost within 1 ms of 12, and k is floor(50 / 22) = 2.
func _latched_high() -> void:
	var g := Governor.new()
	g.slope_known = true
	g.step_ms_ema = 57.0
	g.fixed_ms = 0.0
	g._ref_k = 1
	g._ref_run = 34.0
	g.speed = 10000.0
	g.paused = false
	var k := 0
	for i in 300:
		g.target = g.clock + 100.0 * g.delta()
		k = g.steps()
		g.advanced(k, g.delta(), 12.0 + 22.0 * k)
	g.target = g.clock + 100.0 * g.delta()
	TestUtil.check(absf(g.step_ms_ema - 22.0) <= 0.5 and absf(g.fixed_ms - 12.0) <= 1.0 and g.steps_by_cost() == 2,
		"a cost taken too high at k = 1 comes down: slope %.2f ms (22), fixed %.2f ms (12), k %d (2)" % [g.step_ms_ema, g.fixed_ms, g.steps_by_cost()])
	# a 2M-bup dish on Apple Silicon: 22 ms a step, 14 ms fixed, +-6 ms noise; k = floor(50 / 22) = 2. An iteration of one step (36 ms, under
	# T_ITER) is no rise however low the fixed cost was learned, and at k = 1 the probe goes up, so noise does not hold k at 1 [measured, mean k
	# over the last 300 of 8 seeds: 1.77; without either rule 1.00 to 1.15 (k held at 1); a pair's slope is off by up to 12 ms, so k is 1 for a
	# share of the time]: the mean k is at least 1.5
	var mac := func(_i: int) -> float: return 22.0
	var rm := _simulate(600, 14.0, mac, 10.0, 6.0, 6)
	var mean_k := _mean_tail(rm["ks"], 300)
	TestUtil.check(mean_k >= 1.5, "a 22 ms step with a 14 ms fixed cost and +-6 ms noise does not hold k at 1 (mean k %.2f over the last 300)" % mean_k)


func _mean_tail(values: Array, n: int) -> float:
	var sum := 0.0
	for v: int in values.slice(values.size() - n):
		sum += v
	return sum / n
